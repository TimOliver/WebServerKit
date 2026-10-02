// The upload interface: its endpoints, its page, and its cross-origin defences.
//
// Split out of the single Tests.m that held all 159 tests; the grouping is by subject, not by
// the pass that added each test.

#import <CommonCrypto/CommonDigest.h>
#import <fcntl.h>
#import <limits.h>
#import <objc/runtime.h>
#import <sys/socket.h>
#import <sys/stat.h>

#import "TestsSupport.h"
#import "WSKResumableUploadStore.h"

// A full volume or exhausted quota must reach the client as 507, not 500 — a 5xx server-fault code
// invites the client to retry an upload that cannot succeed until space is freed. The mapping
// function WSKServerErrorStatusCodeForError was always correct and is unit-tested separately; what
// this pins is that the uploader's write ENDPOINTS actually ROUTE their moveItem failures through
// it. They hardcoded 500, so the mapping existed but /upload, /move and /create never consulted it.
//
// The error is INJECTED rather than reproduced with a real small volume: hdiutil in a unit test is
// slow and fragile on CI, and the thing under test is the call-site routing, not the filesystem.
// Only -moveItemAtPath:toPath:error: is swizzled and only while armed, so the multipart temp write
// (raw open/write/close) and all test setup are untouched.
static BOOL gWSKInjectOutOfSpace = NO;
static IMP gWSKOriginalMoveIMP = NULL;

static BOOL WSKInjectingMove(id self, SEL _cmd, NSString *src, NSString *dst, NSError **err) {
    if (gWSKInjectOutOfSpace) {
        if (err) {
            *err = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileWriteOutOfSpaceError userInfo:nil];
        }
        return NO;
    }
    // Cast through void * : -Wcast-function-type-strict rejects a direct IMP-to-prototype cast,
    // which is unavoidable for a swizzle that must call the original.
    return ((BOOL (*)(id, SEL, NSString *, NSString *, NSError **))(void *)gWSKOriginalMoveIMP)(self, _cmd, src, dst, err);
}

static NSString *WSKUploadReplyHeader(NSString *reply, NSString *name) {
    if (reply == nil) return nil;
    NSRange const end = [reply rangeOfString:@"\r\n\r\n"];
    if (end.location == NSNotFound) return nil;
    NSString *const headers = [reply substringToIndex:end.location];
    for (NSString *const line in [headers componentsSeparatedByString:@"\r\n"]) {
        NSRange const colon = [line rangeOfString:@":"];
        if (colon.location == NSNotFound) continue;
        if ([[line substringToIndex:colon.location] caseInsensitiveCompare:name] == NSOrderedSame) {
            return [[line substringFromIndex:NSMaxRange(colon)] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        }
    }
    return nil;
}

static NSString *WSKUploadSessionRequest(NSUInteger port, NSString *method, NSString *path, NSDictionary<NSString *, NSString *> *headers, NSString *body) {
    NSMutableString *const request = [NSMutableString stringWithFormat:@"%@ %@ HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\nTus-Resumable: 1.0.0\r\n", method, path];
    for (NSString *const name in headers) {
        [request appendFormat:@"%@: %@\r\n", name, headers[name]];
    }
    if (body != nil) {
        [request appendFormat:@"Content-Length: %lu\r\n", (unsigned long)UTF8Data(body).length];
    }
    [request appendString:@"\r\n"];
    if (body != nil) [request appendString:body];
    return SendRawRequest(port, request);
}

static NSString *WSKUploadSHA256(NSString *body) {
    NSData *const data = UTF8Data(body);
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *const hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (NSUInteger i = 0; i < sizeof(digest); i++) {
        [hex appendFormat:@"%02x", digest[i]];
    }
    return hex;
}

static NSDictionary<NSString *, NSString *> *WSKUploadCreationHeaders(NSString *key, NSString *name, NSString *body) {
    NSString *const metadata = [NSString stringWithFormat:@"filename %@,path %@,sha256 %@",
                                                          [UTF8Data(name) base64EncodedStringWithOptions:0],
                                                          [UTF8Data(@"/") base64EncodedStringWithOptions:0],
                                                          [UTF8Data(WSKUploadSHA256(body)) base64EncodedStringWithOptions:0]];
    return @{@"Upload-Key": key, @"Upload-Length": [NSString stringWithFormat:@"%lu", (unsigned long)UTF8Data(body).length], @"Upload-Metadata": metadata};
}

static NSString *WSKCreateUpload(NSUInteger port, NSString *key, NSString *name, NSString *body) {
    return WSKUploadSessionRequest(port, @"POST", @"/uploads", WSKUploadCreationHeaders(key, name, body), @"");
}

static NSString *WSKPatchUpload(NSUInteger port, NSString *location, NSUInteger offset, NSString *body) {
    NSDictionary *const headers = @{@"Content-Type": @"application/offset+octet-stream", @"Upload-Offset": [NSString stringWithFormat:@"%lu", (unsigned long)offset]};
    return WSKUploadSessionRequest(port, @"PATCH", location, headers, body);
}

@interface WSKResumableHookUploader : WSKWebUploader
@property (nonatomic, copy) BOOL (^uploadAuthorization)(NSString *path, NSString *temporaryPath);
@end

@implementation WSKResumableHookUploader
- (BOOL)shouldUploadFileAtPath:(NSString *)path withTemporaryFile:(NSString *)tempPath {
    return self.uploadAuthorization ? self.uploadAuthorization(path, tempPath) : [super shouldUploadFileAtPath:path withTemporaryFile:tempPath];
}
@end

@interface WSKUploadImportDelegate : NSObject <WSKWebUploaderDelegate>
@property (nonatomic, copy) void (^onUpload)(NSString *path);
@end

@implementation WSKUploadImportDelegate
- (void)webUploader:(WSKWebUploader *)uploader didUploadFileAtPath:(NSString *)path {
    (void)uploader;
    if (self.onUpload) self.onUpload(path);
}
@end

static WSKResumableHookUploader *WSKUploadServerAtRoot(NSString *root) {
    NSString *const share = [root stringByAppendingPathComponent:@"share"];
    [[NSFileManager defaultManager] createDirectoryAtPath:share withIntermediateDirectories:YES attributes:nil error:NULL];
    WSKResumableHookUploader *const server = [[WSKResumableHookUploader alloc] initWithUploadDirectory:share];
    server.resumableUploadDirectory = [root stringByAppendingPathComponent:@"sessions"];
    return server;
}

@interface WSKResumableUploadStore (WSKProtectedDataTesting)
- (NSMutableDictionary *)_load:(NSString *)path error:(NSError **)error;
- (int)_statPath:(NSString *)path result:(struct stat *)info;
@end

@interface WSKUnavailableFinalIdentityStore : WSKResumableUploadStore
@property (nonatomic, copy) NSString *unavailablePath;
@property (nonatomic) int identityReadError;
@property (nonatomic) NSUInteger injectedIdentityErrors;
@end

@implementation WSKUnavailableFinalIdentityStore
- (int)_statPath:(NSString *)path result:(struct stat *)info {
    if (self.identityReadError && [path isEqualToString:self.unavailablePath]) {
        self.injectedIdentityErrors++;
        errno = self.identityReadError;
        return -1;
    }
    return [super _statPath:path result:info];
}
@end

@interface WSKUnavailableManifestStore : WSKResumableUploadStore
@property (nonatomic) int manifestReadError;
@end

@implementation WSKUnavailableManifestStore
- (NSMutableDictionary *)_load:(NSString *)path error:(NSError **)error {
    if (self.manifestReadError) {
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:self.manifestReadError userInfo:nil];
        return nil;
    }
    return [super _load:path error:error];
}
@end

static NSUInteger WSKUploadStoredFileCount(NSString *root) {
    NSFileManager *const fm = [NSFileManager defaultManager];
    NSString *const directory = [root stringByAppendingPathComponent:@"sessions"];
    NSUInteger count = 0;
    for (NSString *const relativePath in [fm subpathsOfDirectoryAtPath:directory error:NULL]) {
        if ([relativePath isEqualToString:@".lock"]) continue;  // The store's coordination inode is not session data.
        NSDictionary *const attributes = [fm attributesOfItemAtPath:[directory stringByAppendingPathComponent:relativePath] error:NULL];
        if ([attributes[NSFileType] isEqual:NSFileTypeRegular]) count++;
    }
    return count;
}

static NSString *WSKUploadCanonicalTempDirectory(void) {
    NSFileManager *const fm = [NSFileManager defaultManager];
    NSString *const temporary = MakeTempDirectory();
    char canonical[PATH_MAX];
    if (realpath(temporary.fileSystemRepresentation, canonical) == NULL) {
        [fm removeItemAtPath:temporary error:NULL];
        return nil;
    }
    // Preserve the actual filesystem spelling. Foundation path standardization
    // can collapse /private/var back to /var, invalidating recorded journal paths.
    return [fm stringWithFileSystemRepresentation:canonical length:strlen(canonical)];
}

@interface WSKUploaderTests : XCTestCase
@end

@implementation WSKUploaderTests

- (void)testCrossVolumeStagingDirectoryIsPrivateStableAndOutsideShare {
    NSString *const directory = MakeTempDirectory();
    NSFileManager *const manager = NSFileManager.defaultManager;
    [self addTeardownBlock:^{ [manager removeItemAtPath:directory error:NULL]; }];
    NSString *const share = [directory stringByAppendingPathComponent:@"share"];
    XCTAssertTrue([manager createDirectoryAtPath:share withIntermediateDirectories:NO attributes:nil error:NULL]);
    char canonicalDirectory[PATH_MAX];
    XCTAssertNotEqual(realpath(directory.fileSystemRepresentation, canonicalDirectory), NULL);
    NSString *const expected = [@(canonicalDirectory) stringByAppendingPathComponent:@".WebServerKit-ResumableStaging-v1"];
    NSError *error = nil;
    XCTAssertNil(WSKResumableStagingDirectory(share, NO, &error));
    XCTAssertEqual(error.code, ENOENT);
    NSString *const staging = WSKResumableStagingDirectory(share, YES, &error);
    XCTAssertEqualObjects(staging, expected);
    XCTAssertEqualObjects(WSKResumableStagingDirectory(share, NO, &error), staging);
    XCTAssertFalse(WSKPathIsInsideDirectory(staging, share));
    struct stat info;
    XCTAssertEqual(lstat(staging.fileSystemRepresentation, &info), 0);
    XCTAssertEqual(info.st_mode & 0777, 0700);
    XCTAssertEqual(info.st_uid, geteuid());
    // Existing broad permissions must not be silently adopted or changed.
    XCTAssertEqual(chmod(staging.fileSystemRepresentation, 0755), 0);
    XCTAssertNil(WSKResumableStagingDirectory(share, YES, &error));
    XCTAssertEqual(error.code, EACCES);
    XCTAssertEqual(lstat(staging.fileSystemRepresentation, &info), 0);
    XCTAssertEqual(info.st_mode & 0777, 0755);
    XCTAssertEqual(rmdir(staging.fileSystemRepresentation), 0);
    XCTAssertEqual(symlink(share.fileSystemRepresentation, staging.fileSystemRepresentation), 0);
    XCTAssertNil(WSKResumableStagingDirectory(share, YES, &error));
    XCTAssertEqual(error.code, EACCES);
    XCTAssertEqual(lstat(staging.fileSystemRepresentation, &info), 0);
    XCTAssertTrue(S_ISLNK(info.st_mode));
    XCTAssertEqualObjects([manager contentsOfDirectoryAtPath:share error:NULL], @[]);
}

- (NSDictionary<NSString *, NSString *> *)_publishingFixtureAtRoot:(NSString *)root renamed:(BOOL)renamed {
    NSFileManager *const fm = NSFileManager.defaultManager;
    NSString *const share = [root stringByAppendingPathComponent:@"share"];
    NSString *const sessions = [root stringByAppendingPathComponent:@"sessions"];
    XCTAssertTrue([fm createDirectoryAtPath:share withIntermediateDirectories:NO attributes:nil error:NULL]);
    NSString *const key = NSUUID.UUID.UUIDString.lowercaseString;
    NSString *const location = [@"/uploads/" stringByAppendingString:key];
    WSKResumableUploadStore *const store = [[WSKResumableUploadStore alloc] initWithDirectory:sessions uploadDirectory:share expirationInterval:3600];
    NSMutableDictionary *const headers = [WSKUploadCreationHeaders(key, @"journaled.txt", @"abcdefghi") mutableCopy];
    headers[@"Content-Length"] = @"0";
    headers[@"Tus-Resumable"] = @"1.0.0";
    WSKRequest *const create = [[WSKRequest alloc] initWithMethod:@"POST" url:LiteralURL(@"http://localhost/uploads") headers:headers path:@"/uploads" query:@{}];
    WSKResponse *const created = [store processRequest:create
        validate:^WSKResponse *(NSDictionary *metadata) {
            (void)metadata;
            return nil;
        }
        publish:^WSKResponse *(NSString *payload, NSDictionary *metadata, WSKResumableUploadJournalBlock journal) {
            (void)payload;
            (void)metadata;
            (void)journal;
            XCTFail(@"Nonempty creation must not publish before receiving bytes");
            return [WSKResponse responseWithStatusCode:500];
        }];
    XCTAssertEqual(created.statusCode, (NSInteger)201);
    NSString *const session = [sessions stringByAppendingPathComponent:key];
    NSString *const payload = [session stringByAppendingPathComponent:@"payload"];
    NSString *const manifestPath = [session stringByAppendingPathComponent:@"manifest.json"];
    NSData *const original = [NSData dataWithContentsOfFile:manifestPath];
    if (!original) return nil;
    NSMutableDictionary *const manifest = [NSJSONSerialization JSONObjectWithData:original options:NSJSONReadingMutableContainers error:NULL];
    if (!manifest) return nil;
    NSString *const stage = [session stringByAppendingPathComponent:[@".stage-" stringByAppendingString:NSUUID.UUID.UUIDString.lowercaseString]];
    NSData *const body = UTF8Data(@"abcdefghi");
    XCTAssertTrue([body writeToFile:payload atomically:NO]);
    XCTAssertTrue([body writeToFile:stage atomically:NO]);
    struct stat info = {0};
    int const observed = lstat(stage.fileSystemRepresentation, &info);
    XCTAssertEqual(observed, 0);
    if (observed) return nil;
    NSString *const destination = [share stringByAppendingPathComponent:@"journaled.txt"];
    manifest[@"offset"] = @3;
    manifest[@"state"] = @"publishing";
    manifest[@"journal"] = @{@"finalPath": destination, @"stagingPath": stage, @"device": @((unsigned long long)info.st_dev), @"inode": @((unsigned long long)info.st_ino)};
    NSData *const pending = [NSJSONSerialization dataWithJSONObject:manifest options:0 error:NULL];
    XCTAssertNotNil(pending);
    if (!pending) return nil;
    XCTAssertTrue([pending writeToFile:manifestPath atomically:YES]);
    if (renamed) XCTAssertEqual(rename(stage.fileSystemRepresentation, destination.fileSystemRepresentation), 0);
    return @{@"share": share, @"sessions": sessions, @"session": session, @"payload": payload, @"manifest": manifestPath, @"stage": stage, @"destination": destination, @"location": location};
}

- (void)testResumablePublicationIdentityReadErrorsPreserveThePendingJournal {
    for (NSNumber *const injected in @[@(EIO), @(EACCES)]) {
        NSFileManager *const fm = NSFileManager.defaultManager;
        NSString *const root = WSKUploadCanonicalTempDirectory();
        XCTAssertNotNil(root);
        if (!root) return;
        @try {
            NSDictionary<NSString *, NSString *> *const fixture = [self _publishingFixtureAtRoot:root renamed:YES];
            XCTAssertNotNil(fixture);
            if (!fixture) return;
            NSString *const manifestPath = fixture[@"manifest"];
            NSString *const sessions = fixture[@"sessions"];
            NSString *const share = fixture[@"share"];
            NSString *const destination = fixture[@"destination"];
            NSString *const payload = fixture[@"payload"];
            NSString *const location = fixture[@"location"];
            if (!manifestPath || !sessions || !share || !destination || !payload || !location) {
                XCTFail(@"Publication fixture is incomplete");
                return;
            }
            NSData *const pending = [NSData dataWithContentsOfFile:manifestPath];
            WSKUnavailableFinalIdentityStore *const store = [[WSKUnavailableFinalIdentityStore alloc] initWithDirectory:sessions uploadDirectory:share expirationInterval:3600];
            store.unavailablePath = destination;
            store.identityReadError = injected.intValue;
            WSKRequest *const head = [[WSKRequest alloc] initWithMethod:@"HEAD" url:LiteralURL(@"http://localhost/session") headers:@{@"Tus-Resumable": @"1.0.0"} path:location query:@{}];
            __block NSUInteger publications = 0;
            WSKResumableUploadValidationBlock const validate = ^WSKResponse *(NSDictionary *metadata) { (void)metadata; return nil; };
            WSKResumableUploadPublicationBlock const publish = ^WSKResponse *(NSString *callbackPayload, NSDictionary *metadata, WSKResumableUploadJournalBlock journal) {
                (void)callbackPayload;
                (void)metadata;
                (void)journal;
                publications++;
                return [WSKResponse responseWithStatusCode:500];
            };
            WSKResponse *const unavailable = [store processRequest:head validate:validate publish:publish];
            XCTAssertEqual(unavailable.statusCode, (NSInteger)500, @"A transient identity read error is not evidence that publication failed");
            XCTAssertEqual(store.injectedIdentityErrors, (NSUInteger)1, @"The actual publication-identity probe must encounter the fault");
            XCTAssertEqualObjects([NSData dataWithContentsOfFile:manifestPath], pending, @"Inspection failure must retain the exact pending journal");
            XCTAssertEqualObjects([NSData dataWithContentsOfFile:payload], UTF8Data(@"abcdefghi"), @"Do not truncate an uncertain publication back to the prior offset");
            XCTAssertEqualObjects([NSData dataWithContentsOfFile:destination], UTF8Data(@"abcdefghi"));
            store.identityReadError = 0;
            WSKResponse *const recovered = [store processRequest:head validate:validate publish:publish];
            XCTAssertEqual(recovered.statusCode, (NSInteger)200);
            XCTAssertEqualObjects(recovered.additionalHeaders[@"Upload-Offset"], @"9");
            XCTAssertFalse([fm fileExistsAtPath:payload]);
            XCTAssertEqual(publications, (NSUInteger)0, @"Readable storage must reveal the existing file, never publish another copy");
            XCTAssertEqualObjects([fm contentsOfDirectoryAtPath:share error:NULL], @[@"journaled.txt"]);
        } @finally {
            [fm removeItemAtPath:root error:NULL];
        }
    }
}

- (void)testResumablePublicationKnownMissingAndMismatchedFilesStillRollBack {
    for (NSNumber *const mismatched in @[@NO, @YES]) {
        NSFileManager *const fm = NSFileManager.defaultManager;
        NSString *const root = WSKUploadCanonicalTempDirectory();
        XCTAssertNotNil(root);
        if (!root) return;
        @try {
            NSDictionary<NSString *, NSString *> *const fixture = [self _publishingFixtureAtRoot:root renamed:NO];
            XCTAssertNotNil(fixture);
            if (!fixture) return;
            NSString *const sessions = fixture[@"sessions"];
            NSString *const share = fixture[@"share"];
            NSString *const destination = fixture[@"destination"];
            NSString *const payload = fixture[@"payload"];
            NSString *const stage = fixture[@"stage"];
            NSString *const location = fixture[@"location"];
            if (!sessions || !share || !destination || !payload || !stage || !location) {
                XCTFail(@"Publication fixture is incomplete");
                return;
            }
            if (mismatched.boolValue) XCTAssertTrue([UTF8Data(@"unrelated") writeToFile:destination atomically:NO]);
            WSKResumableUploadStore *const store = [[WSKResumableUploadStore alloc] initWithDirectory:sessions uploadDirectory:share expirationInterval:3600];
            WSKRequest *const head = [[WSKRequest alloc] initWithMethod:@"HEAD" url:LiteralURL(@"http://localhost/session") headers:@{@"Tus-Resumable": @"1.0.0"} path:location query:@{}];
            WSKResponse *const recovered = [store processRequest:head
                validate:^WSKResponse *(NSDictionary *metadata) { (void)metadata; return nil; }
                publish:^WSKResponse *(NSString *callbackPayload, NSDictionary *metadata, WSKResumableUploadJournalBlock journal) {
                    (void)callbackPayload;
                    (void)metadata;
                    (void)journal;
                    XCTFail(@"HEAD recovery must not publish");
                    return [WSKResponse responseWithStatusCode:500];
                }];
            XCTAssertEqual(recovered.statusCode, (NSInteger)200);
            XCTAssertEqualObjects(recovered.additionalHeaders[@"Upload-Offset"], @"3");
            XCTAssertEqualObjects([NSData dataWithContentsOfFile:payload], UTF8Data(@"abc"));
            XCTAssertFalse([fm fileExistsAtPath:stage]);
            if (mismatched.boolValue) XCTAssertEqualObjects([NSData dataWithContentsOfFile:destination], UTF8Data(@"unrelated"));
        } @finally {
            [fm removeItemAtPath:root error:NULL];
        }
    }
}

- (void)testResumableEmptyCreationRetainsAnUncertainPublicationJournal {
    NSFileManager *const fm = NSFileManager.defaultManager;
    NSString *const root = WSKUploadCanonicalTempDirectory();
    XCTAssertNotNil(root);
    if (!root) return;
    @try {
        NSString *const share = [root stringByAppendingPathComponent:@"share"];
        NSString *const sessions = [root stringByAppendingPathComponent:@"sessions"];
        XCTAssertTrue([fm createDirectoryAtPath:share withIntermediateDirectories:NO attributes:nil error:NULL]);
        NSString *const destination = [share stringByAppendingPathComponent:@"empty.txt"];
        NSString *const key = NSUUID.UUID.UUIDString.lowercaseString;
        NSString *const manifestPath = [[sessions stringByAppendingPathComponent:key] stringByAppendingPathComponent:@"manifest.json"];
        WSKUnavailableFinalIdentityStore *const store = [[WSKUnavailableFinalIdentityStore alloc] initWithDirectory:sessions uploadDirectory:share expirationInterval:3600];
        store.unavailablePath = destination;
        store.identityReadError = EIO;
        NSMutableDictionary *const headers = [WSKUploadCreationHeaders(key, @"empty.txt", @"") mutableCopy];
        headers[@"Content-Length"] = @"0";
        headers[@"Tus-Resumable"] = @"1.0.0";
        WSKRequest *const create = [[WSKRequest alloc] initWithMethod:@"POST" url:LiteralURL(@"http://localhost/uploads") headers:headers path:@"/uploads" query:@{}];
        WSKResumableUploadValidationBlock const validate = ^WSKResponse *(NSDictionary *metadata) {
            (void)metadata;
            return nil;
        };
        __block NSUInteger publications = 0;
        WSKResumableUploadPublicationBlock const publish = ^WSKResponse *(NSString *payload, NSDictionary *metadata, WSKResumableUploadJournalBlock journal) {
            (void)metadata;
            publications++;
            if (publications != 1) {
                XCTFail(@"An uncertain creation must not publish the empty file twice");
                return [WSKResponse responseWithStatusCode:500];
            }
            NSString *const stage = [payload.stringByDeletingLastPathComponent stringByAppendingPathComponent:[@".stage-" stringByAppendingString:NSUUID.UUID.UUIDString.lowercaseString]];
            XCTAssertTrue([NSData.data writeToFile:stage atomically:NO]);
            struct stat info = {0};
            int const observed = lstat(stage.fileSystemRepresentation, &info);
            XCTAssertEqual(observed, 0);
            if (observed) return [WSKResponse responseWithStatusCode:500];
            BOOL const recorded = journal(destination, stage, (unsigned long long)info.st_dev, (unsigned long long)info.st_ino, NULL);
            XCTAssertTrue(recorded);
            if (!recorded) return [WSKResponse responseWithStatusCode:500];
            XCTAssertEqual(rename(stage.fileSystemRepresentation, destination.fileSystemRepresentation), 0);
            // Model a post-rename error; recovery must inspect the persisted journal.
            return [WSKResponse responseWithStatusCode:500];
        };
        WSKResponse *const unavailable = [store processRequest:create validate:validate publish:publish];
        XCTAssertEqual(unavailable.statusCode, (NSInteger)500);
        XCTAssertEqual(store.injectedIdentityErrors, (NSUInteger)1);
        NSData *const pending = [NSData dataWithContentsOfFile:manifestPath];
        XCTAssertNotNil(pending, @"Creation failure must retain an uncertain publication journal");
        if (pending) {
            NSDictionary *const manifest = [NSJSONSerialization JSONObjectWithData:pending options:0 error:NULL];
            XCTAssertEqualObjects(manifest[@"state"], @"publishing");
            XCTAssertNotNil(manifest[@"journal"]);
        }
        XCTAssertEqualObjects([NSData dataWithContentsOfFile:destination], NSData.data);
        store.identityReadError = 0;
        WSKResponse *const recovered = [store processRequest:create validate:validate publish:publish];
        XCTAssertEqual(recovered.statusCode, (NSInteger)201);
        XCTAssertEqualObjects(recovered.additionalHeaders[@"Upload-Offset"], @"0");
        XCTAssertEqual(publications, (NSUInteger)1);
        XCTAssertEqualObjects([fm contentsOfDirectoryAtPath:share error:NULL], @[@"empty.txt"]);
    } @finally {
        [fm removeItemAtPath:root error:NULL];
    }
}

- (void)testResumableZeroLengthRecoveryPublishesBeforeAdvertisingCompletion {
    for (NSString *const method in @[@"POST", @"HEAD", @"PATCH", @"PATCH-spooled"]) {
        NSFileManager *const fm = NSFileManager.defaultManager;
        NSString *const root = WSKUploadCanonicalTempDirectory();
        XCTAssertNotNil(root);
        if (!root) return;
        @try {
            NSString *const share = [root stringByAppendingPathComponent:@"share"];
            NSString *const sessions = [root stringByAppendingPathComponent:@"sessions"];
            XCTAssertTrue([fm createDirectoryAtPath:share withIntermediateDirectories:NO attributes:nil error:NULL]);
            NSString *const destination = [share stringByAppendingPathComponent:@"empty.txt"];
            NSString *const key = NSUUID.UUID.UUIDString.lowercaseString;
            NSString *const manifestPath = [[sessions stringByAppendingPathComponent:key] stringByAppendingPathComponent:@"manifest.json"];
            WSKUnavailableFinalIdentityStore *const unavailable = [[WSKUnavailableFinalIdentityStore alloc] initWithDirectory:sessions uploadDirectory:share expirationInterval:3600];
            unavailable.unavailablePath = destination;
            unavailable.identityReadError = EIO;
            NSMutableDictionary *const headers = [WSKUploadCreationHeaders(key, @"empty.txt", @"") mutableCopy];
            headers[@"Content-Length"] = @"0";
            headers[@"Tus-Resumable"] = @"1.0.0";
            WSKRequest *const create = [[WSKRequest alloc] initWithMethod:@"POST" url:LiteralURL(@"http://localhost/uploads") headers:headers path:@"/uploads" query:@{}];
            __block BOOL allowPublication = YES;
            WSKResumableUploadValidationBlock const validate = ^WSKResponse *(NSDictionary *metadata) {
                (void)metadata;
                return allowPublication ? nil : [WSKResponse responseWithStatusCode:403];
            };
            __block NSUInteger publications = 0;
            __block NSUInteger successfulPublications = 0;
            WSKResumableUploadPublicationBlock const publish = ^WSKResponse *(NSString *payload, NSDictionary *metadata, WSKResumableUploadJournalBlock journal) {
                (void)metadata;
                publications++;
                NSString *const stage = [payload.stringByDeletingLastPathComponent stringByAppendingPathComponent:[@".stage-" stringByAppendingString:NSUUID.UUID.UUIDString.lowercaseString]];
                XCTAssertTrue([NSData.data writeToFile:stage atomically:NO]);
                struct stat info = {0};
                int const observed = lstat(stage.fileSystemRepresentation, &info);
                XCTAssertEqual(observed, 0);
                if (observed) return [WSKResponse responseWithStatusCode:500];
                BOOL const recorded = journal(destination, stage, (unsigned long long)info.st_dev, (unsigned long long)info.st_ino, NULL);
                XCTAssertTrue(recorded);
                if (!recorded) return [WSKResponse responseWithStatusCode:500];
                // The first attempt fails after persisting the actual journal but
                // before renaming. No test code manufactures or edits a manifest.
                if (publications == 1) return [WSKResponse responseWithStatusCode:500];
                int const renamed = rename(stage.fileSystemRepresentation, destination.fileSystemRepresentation);
                XCTAssertEqual(renamed, 0);
                if (renamed == 0) successfulPublications++;
                return renamed ? [WSKResponse responseWithStatusCode:500] : nil;
            };
            WSKResponse *const first = [unavailable processRequest:create validate:validate publish:publish];
            XCTAssertEqual(first.statusCode, (NSInteger)500);
            XCTAssertEqual(unavailable.injectedIdentityErrors, (NSUInteger)1);
            XCTAssertFalse([fm fileExistsAtPath:destination]);
            NSData *const pending = [NSData dataWithContentsOfFile:manifestPath];
            XCTAssertNotNil(pending);
            if (!pending) return;
            NSDictionary *const saved = [NSJSONSerialization JSONObjectWithData:pending options:0 error:NULL];
            XCTAssertEqualObjects(saved[@"state"], @"publishing");
            XCTAssertNotNil(saved[@"journal"]);
            WSKResumableUploadStore *const recoveredStore = [[WSKResumableUploadStore alloc] initWithDirectory:sessions uploadDirectory:share expirationInterval:3600];
            BOOL const patching = [method hasPrefix:@"PATCH"];
            NSString *const location = [@"/uploads/" stringByAppendingString:key];
            NSDictionary *const patchHeaders = @{@"Tus-Resumable": @"1.0.0", @"Content-Type": @"application/offset+octet-stream", @"Content-Length": @"0", @"Upload-Offset": @"0"};
            WSKRequest *request = create;
            if (patching) {
                request = [[WSKResumableFileRequest alloc] initWithMethod:@"PATCH" url:LiteralURL(@"http://localhost/session") headers:patchHeaders path:location query:@{}];
            } else if ([method isEqualToString:@"HEAD"]) {
                request = [[WSKRequest alloc] initWithMethod:@"HEAD" url:LiteralURL(@"http://localhost/session") headers:@{@"Tus-Resumable": @"1.0.0"} path:location query:@{}];
            }
            allowPublication = NO;
            WSKResponse *const refused = [recoveredStore processRequest:request validate:validate publish:publish];
            XCTAssertEqual(refused.statusCode, (NSInteger)403, @"Recovery must apply the current upload policy before claiming completion");
            XCTAssertNil(refused.additionalHeaders[@"Upload-Offset"]);
            XCTAssertFalse([fm fileExistsAtPath:destination]);
            XCTAssertEqual(publications, (NSUInteger)1);
            allowPublication = YES;
            if (patching) {
                NSData *const beforeInvalid = [NSData dataWithContentsOfFile:manifestPath];
                NSArray<NSDictionary *> *const invalidHeaders = @[@{@"Content-Type": @"text/plain"}, @{@"Content-Encoding": @"gzip"}, @{@"Upload-Offset": @"invalid"}, @{@"Upload-Offset": @"1"}, @{@"Content-Length": @"1"}];
                NSArray<NSNumber *> *const expectedStatuses = @[@415, @415, @400, @409, @413];
                for (NSUInteger index = 0; index < invalidHeaders.count; index++) {
                    NSMutableDictionary *const invalid = [patchHeaders mutableCopy];
                    [invalid addEntriesFromDictionary:invalidHeaders[index]];
                    WSKResumableFileRequest *const rejectedRequest = [[WSKResumableFileRequest alloc] initWithMethod:@"PATCH" url:LiteralURL(@"http://localhost/session") headers:invalid path:location query:@{}];
                    if (rejectedRequest.contentLength == 1) {
                        XCTAssertTrue([rejectedRequest open:NULL]);
                        XCTAssertTrue([rejectedRequest writeData:UTF8Data(@"x") error:NULL]);
                        XCTAssertTrue([rejectedRequest close:NULL]);
                    }
                    WSKResponse *const rejected = [recoveredStore processRequest:rejectedRequest validate:validate publish:publish];
                    XCTAssertEqual(rejected.statusCode, expectedStatuses[index].integerValue);
                    XCTAssertNil(rejected.additionalHeaders[@"Upload-Offset"]);
                    XCTAssertFalse([fm fileExistsAtPath:destination], @"Invalid PATCH must never publish");
                    XCTAssertEqual(publications, (NSUInteger)1);
                    XCTAssertEqualObjects([NSData dataWithContentsOfFile:manifestPath], beforeInvalid, @"Invalid PATCH must not commit recovery progress");
                }
                if ([method isEqualToString:@"PATCH-spooled"]) {
                    XCTAssertTrue([request open:NULL]);
                    XCTAssertTrue([request close:NULL]);
                }
            }
            WSKResponse *const recovered = [recoveredStore processRequest:request validate:validate publish:publish];
            NSInteger const expectedSuccess = patching ? 204 : ([method isEqualToString:@"POST"] ? 201 : 200);
            XCTAssertEqual(recovered.statusCode, expectedSuccess);
            XCTAssertEqualObjects(recovered.additionalHeaders[@"Upload-Offset"], @"0");
            XCTAssertEqualObjects(recovered.additionalHeaders[@"Upload-Length"], @"0");
            XCTAssertEqualObjects([NSData dataWithContentsOfFile:destination], NSData.data, @"An acknowledged zero-byte completion must correspond to a published file");
            XCTAssertEqual(publications, (NSUInteger)2, @"Recovery must finish the uncommitted publication before reporting 0/0");
            XCTAssertEqual(successfulPublications, (NSUInteger)1);
            WSKResponse *const repeated = [recoveredStore processRequest:request validate:validate publish:publish];
            XCTAssertEqual(repeated.statusCode, patching ? (NSInteger)409 : expectedSuccess);
            XCTAssertEqual(publications, (NSUInteger)2, @"A repeated request must not republish the completed empty file");
            NSData *const completeData = [NSData dataWithContentsOfFile:manifestPath];
            XCTAssertNotNil(completeData);
            if (!completeData) return;
            NSDictionary *const complete = [NSJSONSerialization JSONObjectWithData:completeData options:0 error:NULL];
            XCTAssertEqualObjects(complete[@"state"], @"complete");
        } @finally {
            [fm removeItemAtPath:root error:NULL];
        }
    }
}

- (void)testResumableUploadAdvertisesProtocolAndCreationIsIdempotent {
    NSFileManager *const fm = [NSFileManager defaultManager];
    NSString *const root = MakeTempDirectory();
    WSKResumableHookUploader *const server = WSKUploadServerAtRoot(root);
    NSDictionary *const options = @{WSKOption_Port: @0, WSKOption_BindToLocalhost: @YES};
    XCTAssertTrue([server startWithOptions:options error:NULL]);
    @try {
        NSString *const discovery = SendRawRequest(server.port, @"OPTIONS /uploads HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
        XCTAssertTrue(ReplyHasStatus(discovery, 204), @"%@", discovery);
        XCTAssertEqualObjects(WSKUploadReplyHeader(discovery, @"Tus-Resumable"), @"1.0.0");
        XCTAssertEqualObjects(WSKUploadReplyHeader(discovery, @"Tus-Version"), @"1.0.0");
        NSString *const extensions = WSKUploadReplyHeader(discovery, @"Tus-Extension");
        XCTAssertTrue([extensions containsString:@"creation"]);
        XCTAssertTrue([extensions containsString:@"termination"]);

        NSString *const unsupported = SendRawRequest(server.port, @"POST /uploads HTTP/1.1\r\nHost: localhost\r\nTus-Resumable: 0.2.0\r\nContent-Length: 0\r\n\r\n");
        XCTAssertTrue(ReplyHasStatus(unsupported, 412), @"%@", unsupported);

        NSString *const key = [NSUUID UUID].UUIDString;
        NSString *const first = WSKCreateUpload(server.port, key, @"Résumé 日本語.txt", @"abcdef");
        XCTAssertTrue(ReplyHasStatus(first, 201), @"%@", first);
        NSString *const location = WSKUploadReplyHeader(first, @"Location");
        XCTAssertTrue([location hasPrefix:@"/uploads/"], @"%@", first);
        XCTAssertEqualObjects(WSKUploadReplyHeader(first, @"Upload-Offset"), @"0");
        XCTAssertEqualObjects(WSKUploadReplyHeader(first, @"Upload-Length"), @"6");
        XCTAssertNotNil(WSKUploadReplyHeader(first, @"Upload-Expires"));
        if (location == nil) return;

        NSString *const repeated = WSKCreateUpload(server.port, key, @"Résumé 日本語.txt", @"abcdef");
        XCTAssertTrue(ReplyHasStatus(repeated, 201), @"%@", repeated);
        XCTAssertEqualObjects(WSKUploadReplyHeader(repeated, @"Location"), location);
        NSString *const conflict = WSKCreateUpload(server.port, key, @"different.txt", @"abcdef");
        XCTAssertTrue(ReplyHasStatus(conflict, 409), @"a lost creation reply must recover the original session, never overwrite its identity: %@", conflict);

        // HEAD is ordinarily mapped to GET before routing. Both configurations must address the
        // same stored session and must return metadata without file bytes.
        for (NSNumber *const mapHEAD in @[@YES, @NO]) {
            [server stop];
            NSDictionary *const headOptions = @{WSKOption_Port: @0, WSKOption_BindToLocalhost: @YES, WSKOption_AutomaticallyMapHEADToGET: mapHEAD};
            XCTAssertTrue([server startWithOptions:headOptions error:NULL]);
            NSString *const head = WSKUploadSessionRequest(server.port, @"HEAD", location, @{}, nil);
            XCTAssertTrue(ReplyHasStatus(head, 200), @"mapped=%@: %@", mapHEAD, head);
            XCTAssertEqualObjects(WSKUploadReplyHeader(head, @"Upload-Offset"), @"0");
            XCTAssertEqualObjects(WSKUploadReplyHeader(head, @"Upload-Length"), @"6");
            XCTAssertEqualObjects(WSKUploadReplyHeader(head, @"Cache-Control"), @"no-store");
            XCTAssertTrue([head hasSuffix:@"\r\n\r\n"]);
        }
    } @finally {
        [server stop];
        [fm removeItemAtPath:root error:NULL];
    }
}

- (void)testResumableUploadPersistsOffsetAndCompletedReceiptAcrossServerRecreation {
    NSFileManager *const fm = [NSFileManager defaultManager];
    NSString *const root = MakeTempDirectory();
    NSString *const share = [root stringByAppendingPathComponent:@"share"];
    NSDictionary *const options = @{WSKOption_Port: @0, WSKOption_BindToLocalhost: @YES};
    WSKResumableHookUploader *server = WSKUploadServerAtRoot(root);
    NSMutableArray<NSData *> *const approvedBodies = [NSMutableArray array];
    BOOL (^const authorization)(NSString *, NSString *) = ^BOOL(NSString *path, NSString *temporaryPath) {
        (void)path;
        @synchronized(approvedBodies) {
            [approvedBodies addObject:[NSData dataWithContentsOfFile:temporaryPath] ?: [NSData data]];
        }
        return YES;
    };
    server.uploadAuthorization = authorization;
    XCTAssertTrue([server startWithOptions:options error:NULL]);
    @try {
        NSString *const key = [NSUUID UUID].UUIDString;
        NSString *const created = WSKCreateUpload(server.port, key, @"resumed.txt", @"abcdefghi");
        XCTAssertTrue(ReplyHasStatus(created, 201), @"%@", created);
        NSString *const location = WSKUploadReplyHeader(created, @"Location");
        if (location == nil) return;
        NSString *const partial = WSKPatchUpload(server.port, location, 0, @"abc");
        XCTAssertTrue(ReplyHasStatus(partial, 204), @"%@", partial);
        XCTAssertEqualObjects(WSKUploadReplyHeader(partial, @"Upload-Offset"), @"3");
        XCTAssertEqual(approvedBodies.count, (NSUInteger)0, @"the completion hook must never inspect a partial file");
        XCTAssertEqualObjects([fm contentsOfDirectoryAtPath:share error:NULL], @[]);

        [server stop];
        server = WSKUploadServerAtRoot(root);
        server.uploadAuthorization = authorization;
        server.allowHiddenItems = YES;
        XCTAssertTrue([server startWithOptions:options error:NULL]);
        NSString *const resumed = WSKUploadSessionRequest(server.port, @"HEAD", location, @{}, nil);
        XCTAssertTrue(ReplyHasStatus(resumed, 200), @"%@", resumed);
        XCTAssertEqualObjects(WSKUploadReplyHeader(resumed, @"Upload-Offset"), @"3");
        NSString *const listing = SendRawRequest(server.port, @"GET /list?path=%2F HTTP/1.1\r\nHost: localhost\r\n\r\n");
        XCTAssertTrue(ReplyHasStatus(listing, 200));
        XCTAssertTrue([listing hasSuffix:@"[]"], @"session state stays outside the share even when hidden files are allowed: %@", listing);
        NSString *const stale = WSKPatchUpload(server.port, location, 0, @"abc");
        XCTAssertTrue(ReplyHasStatus(stale, 409), @"%@", stale);
        NSString *const finished = WSKPatchUpload(server.port, location, 3, @"defghi");
        XCTAssertTrue(ReplyHasStatus(finished, 204), @"%@", finished);
        XCTAssertEqualObjects(WSKUploadReplyHeader(finished, @"Upload-Offset"), @"9");
        XCTAssertEqualObjects([NSData dataWithContentsOfFile:[share stringByAppendingPathComponent:@"resumed.txt"]], UTF8Data(@"abcdefghi"));
        XCTAssertEqualObjects(approvedBodies, @[UTF8Data(@"abcdefghi")]);

        // Lose the final acknowledgement, discard the whole server, and ask again. A receipt
        // must survive alongside the published file so recovery cannot create "resumed (1).txt".
        [server stop];
        server = WSKUploadServerAtRoot(root);
        server.uploadAuthorization = authorization;
        XCTAssertTrue([server startWithOptions:options error:NULL]);
        NSString *const complete = WSKUploadSessionRequest(server.port, @"HEAD", location, @{}, nil);
        XCTAssertTrue(ReplyHasStatus(complete, 200), @"%@", complete);
        XCTAssertEqualObjects(WSKUploadReplyHeader(complete, @"Upload-Offset"), @"9");
        NSString *const repeated = WSKCreateUpload(server.port, key, @"resumed.txt", @"abcdefghi");
        XCTAssertTrue(ReplyHasStatus(repeated, 201), @"%@", repeated);
        XCTAssertEqualObjects(WSKUploadReplyHeader(repeated, @"Location"), location);
        XCTAssertEqualObjects(WSKUploadReplyHeader(repeated, @"Upload-Offset"), @"9");
        NSString *const duplicate = WSKPatchUpload(server.port, location, 3, @"defghi");
        XCTAssertTrue(ReplyHasStatus(duplicate, 409), @"%@", duplicate);
        XCTAssertEqualObjects([fm contentsOfDirectoryAtPath:share error:NULL], @[@"resumed.txt"]);
        XCTAssertEqualObjects(approvedBodies, @[UTF8Data(@"abcdefghi")]);
    } @finally {
        [server stop];
        [fm removeItemAtPath:root error:NULL];
    }
}

- (void)testResumableUploadRecoveryTruncatesPayloadToTheLastPersistedOffset {
    NSFileManager *const fm = [NSFileManager defaultManager];
    NSString *const root = WSKUploadCanonicalTempDirectory();
    XCTAssertNotNil(root);
    if (root == nil) return;
    NSDictionary *const options = @{WSKOption_Port: @0, WSKOption_BindToLocalhost: @YES};
    WSKResumableHookUploader *server = WSKUploadServerAtRoot(root);
    XCTAssertTrue([server startWithOptions:options error:NULL]);
    @try {
        NSString *const created = WSKCreateUpload(server.port, [NSUUID UUID].UUIDString, @"recovered.txt", @"abcdefghi");
        XCTAssertTrue(ReplyHasStatus(created, 201), @"%@", created);
        NSString *const location = WSKUploadReplyHeader(created, @"Location");
        if (location == nil) return;
        XCTAssertTrue(ReplyHasStatus(WSKPatchUpload(server.port, location, 0, @"abc"), 204));
        [server stop];

        NSString *const sessionDirectory = [[root stringByAppendingPathComponent:@"sessions"] stringByAppendingPathComponent:location.lastPathComponent.lowercaseString];
        NSString *const payloadPath = [sessionDirectory stringByAppendingPathComponent:@"payload"];
        NSString *const manifestPath = [sessionDirectory stringByAppendingPathComponent:@"manifest.json"];
        NSData *const manifestData = [NSData dataWithContentsOfFile:manifestPath];
        XCTAssertNotNil(manifestData);
        if (manifestData == nil) return;
        NSDictionary *const manifest = [NSJSONSerialization JSONObjectWithData:manifestData options:0 error:NULL];
        XCTAssertEqualObjects(manifest[@"offset"], @3);
        XCTAssertEqualObjects([NSData dataWithContentsOfFile:payloadPath], UTF8Data(@"abc"));

        // Model a process exit after the next body was appended but before its new offset was
        // saved. Preserve the actual payload inode and all metadata from the ordinary upload.
        int const fd = open(payloadPath.fileSystemRepresentation, O_WRONLY | O_APPEND);
        XCTAssertGreaterThanOrEqual(fd, 0);
        if (fd < 0) return;
        NSData *const unacknowledged = UTF8Data(@"defghi");
        ssize_t const written = write(fd, unacknowledged.bytes, unacknowledged.length);
        int const closed = close(fd);
        XCTAssertEqual(written, (ssize_t)unacknowledged.length);
        XCTAssertEqual(closed, 0);
        XCTAssertEqualObjects([NSData dataWithContentsOfFile:payloadPath], UTF8Data(@"abcdefghi"));
        XCTAssertEqualObjects([NSData dataWithContentsOfFile:manifestPath], manifestData);

        server = WSKUploadServerAtRoot(root);
        XCTAssertTrue([server startWithOptions:options error:NULL]);
        NSString *const recovered = WSKUploadSessionRequest(server.port, @"HEAD", location, @{}, nil);
        XCTAssertTrue(ReplyHasStatus(recovered, 200), @"%@", recovered);
        XCTAssertEqualObjects(WSKUploadReplyHeader(recovered, @"Upload-Offset"), @"3");
        XCTAssertEqualObjects([NSData dataWithContentsOfFile:payloadPath], UTF8Data(@"abc"), @"Unacknowledged tail bytes must be truncated, not silently adopted or appended twice");
        NSString *const finished = WSKPatchUpload(server.port, location, 3, @"defghi");
        XCTAssertTrue(ReplyHasStatus(finished, 204), @"%@", finished);
        NSString *const publishedPath = [[root stringByAppendingPathComponent:@"share"] stringByAppendingPathComponent:@"recovered.txt"];
        XCTAssertEqualObjects([NSData dataWithContentsOfFile:publishedPath], UTF8Data(@"abcdefghi"));
        XCTAssertFalse([fm fileExistsAtPath:payloadPath]);
        XCTAssertTrue(ReplyHasStatus(WSKUploadSessionRequest(server.port, @"DELETE", location, @{}, nil), 204));
        XCTAssertEqual(WSKUploadStoredFileCount(root), (NSUInteger)0);
        XCTAssertEqualObjects([NSData dataWithContentsOfFile:publishedPath], UTF8Data(@"abcdefghi"));
    } @finally {
        [server stop];
        [fm removeItemAtPath:root error:NULL];
    }
}

- (void)testResumableUploadRecoveryRecognizesJournaledPublicationWithoutPublishingAgain {
    NSFileManager *const fm = [NSFileManager defaultManager];
    NSString *const root = WSKUploadCanonicalTempDirectory();
    XCTAssertNotNil(root);
    if (root == nil) return;
    NSString *const share = [root stringByAppendingPathComponent:@"share"];
    NSDictionary *const options = @{WSKOption_Port: @0, WSKOption_BindToLocalhost: @YES};
    WSKResumableHookUploader *server = WSKUploadServerAtRoot(root);
    XCTAssertTrue([server startWithOptions:options error:NULL]);
    @try {
        NSString *const key = [NSUUID UUID].UUIDString;
        NSString *const created = WSKCreateUpload(server.port, key, @"journaled.txt", @"abcdefghi");
        XCTAssertTrue(ReplyHasStatus(created, 201), @"%@", created);
        NSString *const location = WSKUploadReplyHeader(created, @"Location");
        if (location == nil) return;
        XCTAssertTrue(ReplyHasStatus(WSKPatchUpload(server.port, location, 0, @"abc"), 204));
        [server stop];

        NSString *const sessionDirectory = [[root stringByAppendingPathComponent:@"sessions"] stringByAppendingPathComponent:location.lastPathComponent.lowercaseString];
        NSString *const payloadPath = [sessionDirectory stringByAppendingPathComponent:@"payload"];
        NSString *const manifestPath = [sessionDirectory stringByAppendingPathComponent:@"manifest.json"];
        NSData *const oldManifest = [NSData dataWithContentsOfFile:manifestPath];
        XCTAssertNotNil(oldManifest);
        if (oldManifest == nil) return;
        NSMutableDictionary *const manifest = [NSJSONSerialization JSONObjectWithData:oldManifest options:NSJSONReadingMutableContainers error:NULL];
        XCTAssertNotNil(manifest);
        if (manifest == nil) return;
        XCTAssertEqualObjects(manifest[@"offset"], @3);
        XCTAssertEqualObjects(manifest[@"state"], @"active");

        // The publisher records the destination and staging inode before it copies and renames.
        // Model the interval after that rename but before the completed receipt is saved. The
        // original request's real metadata/binding remain intact; every artifact is test-owned.
        NSData *const completeBody = UTF8Data(@"abcdefghi");
        XCTAssertTrue([completeBody writeToFile:payloadPath options:0 error:NULL]);
        NSString *const stagingDirectory = [root stringByAppendingPathComponent:@"NSIRD_wsk-publication"];
        XCTAssertTrue([fm createDirectoryAtPath:stagingDirectory withIntermediateDirectories:NO attributes:nil error:NULL]);
        NSString *const stagingPath = [stagingDirectory stringByAppendingPathComponent:[@"wsk-upload-" stringByAppendingString:NSUUID.UUID.UUIDString]];
        XCTAssertTrue([completeBody writeToFile:stagingPath options:0 error:NULL]);
        struct stat stagedInfo;
        int const observed = lstat(stagingPath.fileSystemRepresentation, &stagedInfo);
        XCTAssertEqual(observed, 0);
        if (observed != 0) return;
        NSString *const publishedPath = [share stringByAppendingPathComponent:@"journaled.txt"];
        manifest[@"state"] = @"publishing";
        manifest[@"journal"] = @{@"finalPath": publishedPath, @"stagingPath": stagingPath, @"device": @((unsigned long long)stagedInfo.st_dev), @"inode": @((unsigned long long)stagedInfo.st_ino)};
        NSData *const publishingManifest = [NSJSONSerialization dataWithJSONObject:manifest options:0 error:NULL];
        XCTAssertNotNil(publishingManifest);
        if (publishingManifest == nil) return;
        XCTAssertTrue([publishingManifest writeToFile:manifestPath options:NSDataWritingAtomic error:NULL]);
        XCTAssertEqual(rename(stagingPath.fileSystemRepresentation, publishedPath.fileSystemRepresentation), 0);
        XCTAssertFalse([fm fileExistsAtPath:stagingPath]);

        __block NSUInteger hookCalls = 0;
        server = WSKUploadServerAtRoot(root);
        server.uploadAuthorization = ^BOOL(NSString *path, NSString *temporaryPath) {
            (void)path;
            (void)temporaryPath;
            hookCalls++;
            return YES;
        };
        XCTAssertTrue([server startWithOptions:options error:NULL]);
        NSString *const recovered = WSKUploadSessionRequest(server.port, @"HEAD", location, @{}, nil);
        XCTAssertTrue(ReplyHasStatus(recovered, 200), @"%@", recovered);
        XCTAssertEqualObjects(WSKUploadReplyHeader(recovered, @"Upload-Offset"), @"9");
        XCTAssertEqualObjects(WSKUploadReplyHeader(recovered, @"Upload-Length"), @"9");
        XCTAssertEqualObjects([NSData dataWithContentsOfFile:publishedPath], completeBody);
        XCTAssertFalse([fm fileExistsAtPath:payloadPath], @"Recovery must reclaim the redundant private payload");
        XCTAssertFalse([fm fileExistsAtPath:stagingDirectory], @"The renamed staging file leaves an empty replacement directory that recovery must reclaim");
        NSData *const recoveredData = [NSData dataWithContentsOfFile:manifestPath];
        XCTAssertNotNil(recoveredData);
        if (recoveredData == nil) return;
        NSDictionary *const recoveredManifest = [NSJSONSerialization JSONObjectWithData:recoveredData options:0 error:NULL];
        XCTAssertEqualObjects(recoveredManifest[@"state"], @"complete");

        NSString *const repeated = WSKCreateUpload(server.port, key, @"journaled.txt", @"abcdefghi");
        XCTAssertTrue(ReplyHasStatus(repeated, 201), @"%@", repeated);
        XCTAssertEqualObjects(WSKUploadReplyHeader(repeated, @"Location"), location);
        XCTAssertEqualObjects(WSKUploadReplyHeader(repeated, @"Upload-Offset"), @"9");
        NSString *const duplicate = WSKPatchUpload(server.port, location, 3, @"defghi");
        XCTAssertTrue(ReplyHasStatus(duplicate, 409), @"%@", duplicate);
        XCTAssertEqual(hookCalls, (NSUInteger)0, @"Recovery must recognize an already published inode instead of invoking publication again");
        XCTAssertEqualObjects([fm contentsOfDirectoryAtPath:share error:NULL], @[@"journaled.txt"]);
        XCTAssertTrue(ReplyHasStatus(WSKUploadSessionRequest(server.port, @"DELETE", location, @{}, nil), 204));
        XCTAssertEqual(WSKUploadStoredFileCount(root), (NSUInteger)0);
        XCTAssertEqualObjects([NSData dataWithContentsOfFile:publishedPath], completeBody);
    } @finally {
        [server stop];
        [fm removeItemAtPath:root error:NULL];
    }
}

- (void)testResumableUploadDelegateCanImportTheCompletedFile {
    NSFileManager *const fm = [NSFileManager defaultManager];
    NSString *const root = MakeTempDirectory();
    NSString *const imported = [root stringByAppendingPathComponent:@"imported.txt"];
    WSKResumableHookUploader *const server = WSKUploadServerAtRoot(root);
    WSKUploadImportDelegate *const delegate = [[WSKUploadImportDelegate alloc] init];
    __block NSUInteger callbacks = 0;
    XCTestExpectation *const uploaded = [self expectationWithDescription:@"Delegate imports the committed file"];
    delegate.onUpload = ^(NSString *path) {
        callbacks++;
        XCTAssertTrue([fm moveItemAtPath:path toPath:imported error:NULL]);
        [uploaded fulfill];
    };
    server.delegate = delegate;
    NSDictionary *const options = @{WSKOption_Port: @0, WSKOption_BindToLocalhost: @YES};
    XCTAssertTrue([server startWithOptions:options error:NULL]);
    @try {
        NSString *const key = [NSUUID UUID].UUIDString;
        NSString *const created = WSKCreateUpload(server.port, key, @"incoming.txt", @"abcdefghi");
        NSString *const location = WSKUploadReplyHeader(created, @"Location");
        XCTAssertTrue(ReplyHasStatus(created, 201), @"%@", created);
        if (location == nil) return;
        XCTAssertTrue(ReplyHasStatus(WSKPatchUpload(server.port, location, 0, @"abc"), 204));
        XCTestExpectation *const finished = [self expectationWithDescription:@"Final PATCH is acknowledged"];
        __block NSString *reply = nil;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
            reply = WSKPatchUpload(server.port, location, 3, @"defghi");
            [finished fulfill];
        });
        [self waitForExpectations:@[uploaded, finished] timeout:10.0];
        XCTAssertTrue(ReplyHasStatus(reply, 204), @"%@", reply);
        XCTAssertEqual(callbacks, (NSUInteger)1);
        XCTAssertEqualObjects([NSData dataWithContentsOfFile:imported], UTF8Data(@"abcdefghi"));
        XCTAssertEqualObjects([fm contentsOfDirectoryAtPath:server.uploadDirectory error:NULL], @[]);
        NSString *const receipt = WSKUploadSessionRequest(server.port, @"HEAD", location, @{}, nil);
        XCTAssertTrue(ReplyHasStatus(receipt, 200), @"%@", receipt);
        XCTAssertEqualObjects(WSKUploadReplyHeader(receipt, @"Upload-Offset"), @"9");
        NSString *const repeated = WSKCreateUpload(server.port, key, @"incoming.txt", @"abcdefghi");
        XCTAssertTrue(ReplyHasStatus(repeated, 201), @"%@", repeated);
        XCTAssertEqualObjects(WSKUploadReplyHeader(repeated, @"Upload-Offset"), @"9");
        XCTAssertEqual(callbacks, (NSUInteger)1, @"Recovering a receipt must not import the file twice");
    } @finally {
        delegate.onUpload = nil;
        [server stop];
        [fm removeItemAtPath:root error:NULL];
    }
}

- (void)testResumableUploadSuccessfulPublicationRemainsCompleteAfterAnImmediateMove {
    NSFileManager *const fm = [NSFileManager defaultManager];
    NSString *const root = WSKUploadCanonicalTempDirectory();
    XCTAssertNotNil(root);
    if (root == nil) return;
    NSString *const share = [root stringByAppendingPathComponent:@"share"];
    XCTAssertTrue([fm createDirectoryAtPath:share withIntermediateDirectories:NO attributes:nil error:NULL]);
    NSString *const finalPath = [share stringByAppendingPathComponent:@"incoming.txt"];
    NSString *const imported = [root stringByAppendingPathComponent:@"imported.txt"];
    NSString *const staged = [root stringByAppendingPathComponent:@"wsk-upload-staged"];
    WSKResumableUploadStore *const store = [[WSKResumableUploadStore alloc] initWithDirectory:[root stringByAppendingPathComponent:@"sessions"] uploadDirectory:share expirationInterval:3600];
    NSMutableDictionary *const headers = [WSKUploadCreationHeaders([NSUUID UUID].UUIDString, @"incoming.txt", @"") mutableCopy];
    headers[@"Content-Length"] = @"0";
    headers[@"Tus-Resumable"] = @"1.0.0";
    WSKRequest *const create = [[WSKRequest alloc] initWithMethod:@"POST" url:LiteralURL(@"http://localhost/uploads") headers:headers path:@"/uploads" query:@{}];
    __block NSUInteger publications = 0;
    WSKResumableUploadValidationBlock const validate = ^WSKResponse *(NSDictionary *metadata) {
        (void)metadata;
        return nil;
    };
    WSKResumableUploadPublicationBlock const publish = ^WSKResponse *(NSString *payload, NSDictionary *metadata, WSKResumableUploadJournalBlock journal) {
        (void)metadata;
        publications++;
        BOOL const copied = [fm copyItemAtPath:payload toPath:staged error:NULL];
        XCTAssertTrue(copied);
        if (!copied) return [WSKResponse responseWithStatusCode:500];
        struct stat info;
        int const observed = lstat(staged.fileSystemRepresentation, &info);
        XCTAssertEqual(observed, 0);
        if (observed != 0) return [WSKResponse responseWithStatusCode:500];
        BOOL const recorded = journal(finalPath, staged, (unsigned long long)info.st_dev, (unsigned long long)info.st_ino, NULL);
        XCTAssertTrue(recorded);
        if (!recorded) return [WSKResponse responseWithStatusCode:500];
        int const renamed = rename(staged.fileSystemRepresentation, finalPath.fileSystemRepresentation);
        XCTAssertEqual(renamed, 0);
        if (renamed != 0) return [WSKResponse responseWithStatusCode:500];
        // Model a consuming delegate or another filesystem client moving the file
        // after a successful publication but before the store observes the path.
        BOOL const moved = [fm moveItemAtPath:finalPath toPath:imported error:NULL];
        XCTAssertTrue(moved);
        return moved ? nil : [WSKResponse responseWithStatusCode:500];
    };
    @try {
        WSKResponse *const first = [store processRequest:create validate:validate publish:publish];
        XCTAssertEqual(first.statusCode, (NSInteger)201);
        XCTAssertEqualObjects(first.additionalHeaders[@"Upload-Offset"], @"0");
        XCTAssertEqualObjects([NSData dataWithContentsOfFile:imported], [NSData data]);
        XCTAssertFalse([fm fileExistsAtPath:finalPath]);
        WSKResponse *const repeated = [store processRequest:create validate:validate publish:publish];
        XCTAssertEqual(repeated.statusCode, (NSInteger)201);
        XCTAssertEqual(publications, (NSUInteger)1, @"A confirmed publication is complete even if its file was immediately imported elsewhere");
    } @finally {
        [fm removeItemAtPath:root error:NULL];
    }
}

- (void)testResumableUploadIncompleteChunkDoesNotAdvanceConfirmedOffset {
    NSFileManager *const fm = [NSFileManager defaultManager];
    NSString *const root = MakeTempDirectory();
    WSKResumableHookUploader *const server = WSKUploadServerAtRoot(root);
    NSDictionary *const options = @{WSKOption_Port: @0, WSKOption_BindToLocalhost: @YES};
    XCTAssertTrue([server startWithOptions:options error:NULL]);
    @try {
        NSString *const created = WSKCreateUpload(server.port, [NSUUID UUID].UUIDString, @"cancelled.txt", @"abcdefghi");
        XCTAssertTrue(ReplyHasStatus(created, 201), @"%@", created);
        NSString *const location = WSKUploadReplyHeader(created, @"Location");
        if (location == nil) return;
        XCTAssertTrue(ReplyHasStatus(WSKPatchUpload(server.port, location, 0, @"abc"), 204));

        int const fd = ConnectToLocalhostPort(server.port);
        XCTAssertGreaterThanOrEqual(fd, 0);
        if (fd < 0) return;
        NSString *const request = [NSString stringWithFormat:@"PATCH %@ HTTP/1.1\r\nHost: localhost\r\nTus-Resumable: 1.0.0\r\nUpload-Offset: 3\r\nContent-Type: application/offset+octet-stream\r\nContent-Length: 6\r\n\r\nde", location];
        NSData *const bytes = UTF8Data(request);
        XCTAssertEqual(send(fd, bytes.bytes, bytes.length, 0), (ssize_t)bytes.length);
        shutdown(fd, SHUT_WR);
        BOOL sawEOF = NO;
        ReadToEOF(fd, &sawEOF);
        close(fd);
        XCTAssertTrue(sawEOF, @"an interrupted body must release its socket");

        NSString *const head = WSKUploadSessionRequest(server.port, @"HEAD", location, @{}, nil);
        XCTAssertTrue(ReplyHasStatus(head, 200), @"%@", head);
        XCTAssertEqualObjects(WSKUploadReplyHeader(head, @"Upload-Offset"), @"3");
        NSString *const completed = WSKPatchUpload(server.port, location, 3, @"defghi");
        XCTAssertTrue(ReplyHasStatus(completed, 204), @"%@", completed);
        NSString *const path = [[root stringByAppendingPathComponent:@"share"] stringByAppendingPathComponent:@"cancelled.txt"];
        XCTAssertEqualObjects([NSData dataWithContentsOfFile:path], UTF8Data(@"abcdefghi"));
    } @finally {
        [server stop];
        [fm removeItemAtPath:root error:NULL];
    }
}

- (void)testFourResumableUploadsKeepIndependentOffsetsAndUniqueNames {
    NSFileManager *const fm = [NSFileManager defaultManager];
    NSString *const root = MakeTempDirectory();
    NSString *const share = [root stringByAppendingPathComponent:@"share"];
    WSKResumableHookUploader *const server = WSKUploadServerAtRoot(root);
    NSDictionary *const options = @{WSKOption_Port: @0, WSKOption_BindToLocalhost: @YES};
    XCTAssertTrue([server startWithOptions:options error:NULL]);
    @try {
        NSMutableArray<NSString *> *const locations = [NSMutableArray array];
        NSMutableArray<NSString *> *const bodies = [NSMutableArray array];
        for (NSUInteger i = 0; i < 4; i++) {
            NSString *const body = [NSString stringWithFormat:@"file-%lu:%@", (unsigned long)i, [@"x" stringByPaddingToLength:16384 + i withString:@"xyz" startingAtIndex:0]];
            [bodies addObject:body];
            NSString *const created = WSKCreateUpload(server.port, [NSUUID UUID].UUIDString, @"same.txt", body);
            XCTAssertTrue(ReplyHasStatus(created, 201), @"%@", created);
            NSString *const location = WSKUploadReplyHeader(created, @"Location");
            XCTAssertNotNil(location);
            if (location == nil) return;
            [locations addObject:location];
            NSString *const partial = WSKPatchUpload(server.port, location, 0, [body substringToIndex:i + 1]);
            XCTAssertTrue(ReplyHasStatus(partial, 204), @"%@", partial);
        }
        XCTAssertEqualObjects([fm contentsOfDirectoryAtPath:share error:NULL], @[]);

        dispatch_group_t const group = dispatch_group_create();
        NSMutableArray<NSString *> *const replies = [NSMutableArray array];
        for (NSUInteger i = 0; i < locations.count; i++) {
            dispatch_group_async(group, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                NSString *const reply = WSKPatchUpload(server.port, locations[i], i + 1, [bodies[i] substringFromIndex:i + 1]);
                @synchronized(replies) {
                    [replies addObject:reply ?: @"missing reply"];
                }
            });
        }
        long const waited = dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_SEC)));
        XCTAssertEqual(waited, 0L);
        if (waited != 0) return;
        XCTAssertEqual(replies.count, (NSUInteger)4);
        for (NSString *const reply in replies) {
            XCTAssertTrue(ReplyHasStatus(reply, 204), @"%@", reply);
        }
        NSArray<NSString *> *const names = [fm contentsOfDirectoryAtPath:share error:NULL];
        XCTAssertEqual(names.count, (NSUInteger)4);
        NSMutableSet<NSData *> *const published = [NSMutableSet set];
        for (NSString *const name in names) {
            NSData *const bytes = [NSData dataWithContentsOfFile:[share stringByAppendingPathComponent:name]];
            XCTAssertNotNil(bytes);
            if (bytes != nil) [published addObject:bytes];
        }
        NSMutableSet<NSData *> *const expected = [NSMutableSet set];
        for (NSString *const body in bodies)
            [expected addObject:UTF8Data(body)];
        XCTAssertEqualObjects(published, expected, @"same-name publication must preserve all four complete files");
        for (NSUInteger i = 0; i < locations.count; i++) {
            NSString *const head = WSKUploadSessionRequest(server.port, @"HEAD", locations[i], @{}, nil);
            NSString *const length = [NSString stringWithFormat:@"%lu", (unsigned long)UTF8Data(bodies[i]).length];
            XCTAssertEqualObjects(WSKUploadReplyHeader(head, @"Upload-Offset"), length);
        }
    } @finally {
        [server stop];
        [fm removeItemAtPath:root error:NULL];
    }
}

- (void)testResumableUploadChecksumAndCompletionHookPreventFalseSuccess {
    NSFileManager *const fm = [NSFileManager defaultManager];
    NSString *const root = MakeTempDirectory();
    NSString *const share = [root stringByAppendingPathComponent:@"share"];
    WSKResumableHookUploader *const server = WSKUploadServerAtRoot(root);
    __block NSUInteger hookCalls = 0;
    server.uploadAuthorization = ^BOOL(NSString *path, NSString *temporaryPath) {
        (void)path;
        XCTAssertEqualObjects([NSData dataWithContentsOfFile:temporaryPath], UTF8Data(@"abcdef"));
        hookCalls++;
        return NO;
    };
    NSDictionary *const options = @{WSKOption_Port: @0, WSKOption_BindToLocalhost: @YES};
    XCTAssertTrue([server startWithOptions:options error:NULL]);
    @try {
        NSString *const created = WSKCreateUpload(server.port, [NSUUID UUID].UUIDString, @"verified.txt", @"abcdef");
        XCTAssertTrue(ReplyHasStatus(created, 201), @"%@", created);
        NSString *const location = WSKUploadReplyHeader(created, @"Location");
        if (location == nil) return;
        XCTAssertTrue(ReplyHasStatus(WSKPatchUpload(server.port, location, 0, @"abc"), 204));
        NSString *const wrong = WSKPatchUpload(server.port, location, 3, @"XYZ");
        XCTAssertTrue(ReplyHasStatus(wrong, 422), @"a complete byte count is not proof that the reselected file matches: %@", wrong);
        XCTAssertEqual(hookCalls, (NSUInteger)0);
        NSString *const afterMismatch = WSKUploadSessionRequest(server.port, @"HEAD", location, @{}, nil);
        XCTAssertFalse([WSKUploadReplyHeader(afterMismatch, @"Upload-Offset") isEqualToString:@"6"], @"checksum failure must not look completed: %@", afterMismatch);
        XCTAssertEqualObjects([fm contentsOfDirectoryAtPath:share error:NULL], @[]);

        NSString *const deniedCreation = WSKCreateUpload(server.port, [NSUUID UUID].UUIDString, @"denied.txt", @"abcdef");
        NSString *const deniedLocation = WSKUploadReplyHeader(deniedCreation, @"Location");
        XCTAssertTrue(ReplyHasStatus(deniedCreation, 201), @"%@", deniedCreation);
        if (deniedLocation == nil) return;
        NSString *const denied = WSKPatchUpload(server.port, deniedLocation, 0, @"abcdef");
        XCTAssertTrue(ReplyHasStatus(denied, 403), @"%@", denied);
        XCTAssertEqual(hookCalls, (NSUInteger)1);
        NSString *const afterDenial = WSKUploadSessionRequest(server.port, @"HEAD", deniedLocation, @{}, nil);
        XCTAssertFalse([WSKUploadReplyHeader(afterDenial, @"Upload-Offset") isEqualToString:@"6"], @"a refused publication must not look completed: %@", afterDenial);
        XCTAssertEqualObjects([fm contentsOfDirectoryAtPath:share error:NULL], @[]);
    } @finally {
        [server stop];
        [fm removeItemAtPath:root error:NULL];
    }
}

- (void)testResumableUploadEmptyCreationPublishesOnce {
    NSFileManager *const fm = [NSFileManager defaultManager];
    NSString *const root = MakeTempDirectory();
    NSString *const share = [root stringByAppendingPathComponent:@"share"];
    WSKResumableHookUploader *const server = WSKUploadServerAtRoot(root);
    __block NSUInteger hookCalls = 0;
    server.uploadAuthorization = ^BOOL(NSString *path, NSString *temporaryPath) {
        (void)path;
        XCTAssertEqualObjects([NSData dataWithContentsOfFile:temporaryPath], [NSData data]);
        hookCalls++;
        return YES;
    };
    NSDictionary *const options = @{WSKOption_Port: @0, WSKOption_BindToLocalhost: @YES};
    XCTAssertTrue([server startWithOptions:options error:NULL]);
    @try {
        NSString *const key = [NSUUID UUID].UUIDString;
        NSString *const created = WSKCreateUpload(server.port, key, @"empty.txt", @"");
        XCTAssertTrue(ReplyHasStatus(created, 201), @"%@", created);
        XCTAssertEqualObjects(WSKUploadReplyHeader(created, @"Upload-Offset"), @"0");
        XCTAssertEqualObjects(WSKUploadReplyHeader(created, @"Upload-Length"), @"0");
        XCTAssertEqualObjects([NSData dataWithContentsOfFile:[share stringByAppendingPathComponent:@"empty.txt"]], [NSData data]);
        NSString *const repeated = WSKCreateUpload(server.port, key, @"empty.txt", @"");
        XCTAssertTrue(ReplyHasStatus(repeated, 201), @"%@", repeated);
        XCTAssertEqualObjects(WSKUploadReplyHeader(repeated, @"Location"), WSKUploadReplyHeader(created, @"Location"));
        XCTAssertEqual(hookCalls, (NSUInteger)1);
        XCTAssertEqualObjects([fm contentsOfDirectoryAtPath:share error:NULL], @[@"empty.txt"]);
    } @finally {
        [server stop];
        [fm removeItemAtPath:root error:NULL];
    }
}

- (void)testResumableUploadRechecksDestinationPolicyBeforePublication {
    NSFileManager *const fm = [NSFileManager defaultManager];
    NSString *const root = MakeTempDirectory();
    WSKResumableHookUploader *const server = WSKUploadServerAtRoot(root);
    server.allowedFileExtensions = @[@"txt"];
    NSDictionary *const options = @{WSKOption_Port: @0, WSKOption_BindToLocalhost: @YES};
    XCTAssertTrue([server startWithOptions:options error:NULL]);
    @try {
        NSString *const created = WSKCreateUpload(server.port, [NSUUID UUID].UUIDString, @"policy.txt", @"abcdef");
        XCTAssertTrue(ReplyHasStatus(created, 201), @"%@", created);
        NSString *const location = WSKUploadReplyHeader(created, @"Location");
        if (location == nil) return;
        XCTAssertTrue(ReplyHasStatus(WSKPatchUpload(server.port, location, 0, @"abc"), 204));
        server.allowedFileExtensions = @[@"jpg"];
        NSString *const refused = WSKPatchUpload(server.port, location, 3, @"def");
        XCTAssertTrue(ReplyHasStatus(refused, 403), @"the current publication policy must apply after a paused transfer resumes: %@", refused);
        NSString *const head = WSKUploadSessionRequest(server.port, @"HEAD", location, @{}, nil);
        XCTAssertTrue(ReplyHasStatus(head, 200), @"%@", head);
        XCTAssertEqualObjects(WSKUploadReplyHeader(head, @"Upload-Offset"), @"3");
        NSString *const share = [root stringByAppendingPathComponent:@"share"];
        XCTAssertEqualObjects([fm contentsOfDirectoryAtPath:share error:NULL], @[]);
        server.allowedFileExtensions = @[@"txt"];
        NSString *const retried = WSKPatchUpload(server.port, location, 3, @"def");
        XCTAssertTrue(ReplyHasStatus(retried, 204), @"%@", retried);
        XCTAssertEqualObjects([NSData dataWithContentsOfFile:[share stringByAppendingPathComponent:@"policy.txt"]], UTF8Data(@"abcdef"));
    } @finally {
        [server stop];
        [fm removeItemAtPath:root error:NULL];
    }
}

- (void)testResumableUploadPublicationKeepsItsAcceptedShareWhenTheAliasChangesInTheHook {
    NSFileManager *const fm = [NSFileManager defaultManager];
    NSString *const root = WSKUploadCanonicalTempDirectory();
    XCTAssertNotNil(root);
    if (root == nil) return;
    NSString *const firstShare = [root stringByAppendingPathComponent:@"first-share"];
    NSString *const secondShare = [root stringByAppendingPathComponent:@"second-share"];
    NSString *const alias = [root stringByAppendingPathComponent:@"share"];
    XCTAssertTrue([fm createDirectoryAtPath:firstShare withIntermediateDirectories:NO attributes:nil error:NULL]);
    XCTAssertTrue([fm createDirectoryAtPath:secondShare withIntermediateDirectories:NO attributes:nil error:NULL]);
    XCTAssertTrue([fm createSymbolicLinkAtPath:alias withDestinationPath:firstShare error:NULL]);
    WSKResumableHookUploader *const server = WSKUploadServerAtRoot(root);
    __block NSUInteger hookCalls = 0;
    server.uploadAuthorization = ^BOOL(NSString *path, NSString *temporaryPath) {
        XCTAssertEqualObjects(path, [firstShare stringByAppendingPathComponent:@"stable.txt"]);
        XCTAssertEqualObjects([NSData dataWithContentsOfFile:temporaryPath], UTF8Data(@"abcdef"));
        hookCalls++;
        BOOL const removed = [fm removeItemAtPath:alias error:NULL];
        BOOL const replaced = removed && [fm createSymbolicLinkAtPath:alias withDestinationPath:secondShare error:NULL];
        XCTAssertTrue(replaced);
        return replaced;
    };
    NSDictionary *const options = @{WSKOption_Port: @0, WSKOption_BindToLocalhost: @YES};
    XCTAssertTrue([server startWithOptions:options error:NULL]);
    @try {
        NSString *const created = WSKCreateUpload(server.port, [NSUUID UUID].UUIDString, @"stable.txt", @"abcdef");
        XCTAssertTrue(ReplyHasStatus(created, 201), @"%@", created);
        NSString *const location = WSKUploadReplyHeader(created, @"Location");
        if (location == nil) return;
        XCTAssertTrue(ReplyHasStatus(WSKPatchUpload(server.port, location, 0, @"abc"), 204));
        XCTAssertEqual(hookCalls, (NSUInteger)0);

        // Host applications use shared-directory aliases for live updates. An accepted final
        // chunk belongs to its captured root even if the host retargets that alias in its hook.
        NSString *const finished = WSKPatchUpload(server.port, location, 3, @"def");
        XCTAssertTrue(ReplyHasStatus(finished, 204), @"%@", finished);
        XCTAssertEqual(hookCalls, (NSUInteger)1);
        XCTAssertEqualObjects([fm destinationOfSymbolicLinkAtPath:alias error:NULL], secondShare);
        NSString *const publishedPath = [firstShare stringByAppendingPathComponent:@"stable.txt"];
        XCTAssertEqualObjects([NSData dataWithContentsOfFile:publishedPath], UTF8Data(@"abcdef"));
        XCTAssertEqualObjects([fm contentsOfDirectoryAtPath:firstShare error:NULL], @[@"stable.txt"]);
        XCTAssertEqualObjects([fm contentsOfDirectoryAtPath:secondShare error:NULL], @[], @"The in-flight session must never publish into the newly selected share");

        XCTAssertTrue([fm removeItemAtPath:alias error:NULL]);
        XCTAssertTrue([fm createSymbolicLinkAtPath:alias withDestinationPath:firstShare error:NULL]);
        NSString *const receipt = WSKUploadSessionRequest(server.port, @"HEAD", location, @{}, nil);
        XCTAssertTrue(ReplyHasStatus(receipt, 200), @"%@", receipt);
        XCTAssertEqualObjects(WSKUploadReplyHeader(receipt, @"Upload-Offset"), @"6");
        XCTAssertTrue(ReplyHasStatus(WSKUploadSessionRequest(server.port, @"DELETE", location, @{}, nil), 204));
        XCTAssertEqual(WSKUploadStoredFileCount(root), (NSUInteger)0);
        XCTAssertEqualObjects([NSData dataWithContentsOfFile:publishedPath], UTF8Data(@"abcdef"));
    } @finally {
        [server stop];
        [fm removeItemAtPath:root error:NULL];
    }
}

- (void)testResumableUploadTerminationAndExpiryRemoveOnlySessionState {
    NSFileManager *const fm = [NSFileManager defaultManager];
    NSString *const root = MakeTempDirectory();
    NSString *const share = [root stringByAppendingPathComponent:@"share"];
    WSKResumableHookUploader *const server = WSKUploadServerAtRoot(root);
    server.resumableUploadTimeout = 1.0;
    NSDictionary *const options = @{WSKOption_Port: @0, WSKOption_BindToLocalhost: @YES};
    XCTAssertTrue([server startWithOptions:options error:NULL]);
    @try {
        NSString *const created = WSKCreateUpload(server.port, [NSUUID UUID].UUIDString, @"abandoned.txt", @"abcdef");
        NSString *const location = WSKUploadReplyHeader(created, @"Location");
        XCTAssertTrue(ReplyHasStatus(created, 201), @"%@", created);
        if (location == nil) return;
        XCTAssertTrue(ReplyHasStatus(WSKPatchUpload(server.port, location, 0, @"abc"), 204));
        XCTAssertGreaterThan(WSKUploadStoredFileCount(root), (NSUInteger)0);
        NSString *const deleted = WSKUploadSessionRequest(server.port, @"DELETE", location, @{}, nil);
        XCTAssertTrue(ReplyHasStatus(deleted, 204), @"%@", deleted);
        XCTAssertTrue(ReplyHasStatus(WSKUploadSessionRequest(server.port, @"HEAD", location, @{}, nil), 404));
        XCTAssertEqual(WSKUploadStoredFileCount(root), (NSUInteger)0);
        XCTAssertEqualObjects([fm contentsOfDirectoryAtPath:share error:NULL], @[]);

        NSString *const completed = WSKCreateUpload(server.port, [NSUUID UUID].UUIDString, @"keep.txt", @"");
        NSString *const completedLocation = WSKUploadReplyHeader(completed, @"Location");
        XCTAssertTrue(ReplyHasStatus(completed, 201), @"%@", completed);
        if (completedLocation == nil) return;
        NSString *const unfinished = WSKCreateUpload(server.port, [NSUUID UUID].UUIDString, @"expire.txt", @"abc");
        NSString *const unfinishedLocation = WSKUploadReplyHeader(unfinished, @"Location");
        XCTAssertTrue(ReplyHasStatus(unfinished, 201), @"%@", unfinished);
        if (unfinishedLocation == nil) return;
        XCTAssertTrue(ReplyHasStatus(WSKPatchUpload(server.port, unfinishedLocation, 0, @"a"), 204));
        [NSThread sleepForTimeInterval:1.2];
        XCTAssertTrue(ReplyHasStatus(WSKUploadSessionRequest(server.port, @"HEAD", unfinishedLocation, @{}, nil), 404));
        XCTAssertTrue(ReplyHasStatus(WSKUploadSessionRequest(server.port, @"HEAD", completedLocation, @{}, nil), 404));
        XCTAssertEqual(WSKUploadStoredFileCount(root), (NSUInteger)0);
        XCTAssertEqualObjects([fm contentsOfDirectoryAtPath:share error:NULL], @[@"keep.txt"]);
        XCTAssertEqualObjects([NSData dataWithContentsOfFile:[share stringByAppendingPathComponent:@"keep.txt"]], [NSData data]);
    } @finally {
        [server stop];
        [fm removeItemAtPath:root error:NULL];
    }
}

- (void)testResumableUploadTerminationReportsStorageFailureAndRetainsCleanupOwnership {
    XCTSkipIf(geteuid() == 0, @"Permission refusal requires an ordinary user rather than root");
    NSFileManager *const fm = [NSFileManager defaultManager];
    NSString *const root = [MakeTempDirectory() stringByResolvingSymlinksInPath];
    WSKResumableHookUploader *const server = WSKUploadServerAtRoot(root);
    server.resumableUploadTimeout = 3600;
    NSDictionary *const options = @{WSKOption_Port: @0, WSKOption_BindToLocalhost: @YES};
    NSString *sessionDirectory = nil;
    XCTAssertTrue([server startWithOptions:options error:NULL]);
    @try {
        NSString *const created = WSKCreateUpload(server.port, [NSUUID UUID].UUIDString, @"cancel-retry.txt", @"abcdef");
        XCTAssertTrue(ReplyHasStatus(created, 201), @"%@", created);
        NSString *const location = WSKUploadReplyHeader(created, @"Location");
        if (location == nil) return;
        XCTAssertTrue(ReplyHasStatus(WSKPatchUpload(server.port, location, 0, @"abc"), 204));
        [server stop];

        sessionDirectory = [[root stringByAppendingPathComponent:@"sessions"] stringByAppendingPathComponent:location.lastPathComponent.lowercaseString];
        NSString *const manifestPath = [sessionDirectory stringByAppendingPathComponent:@"manifest.json"];
        NSString *const payloadPath = [sessionDirectory stringByAppendingPathComponent:@"payload"];
        NSData *const manifest = [NSData dataWithContentsOfFile:manifestPath];
        XCTAssertNotNil(manifest);
        XCTAssertEqual(chmod(sessionDirectory.fileSystemRepresentation, 0500), 0);
        int const writable = access(sessionDirectory.fileSystemRepresentation, W_OK);
        XCTAssertNotEqual(writable, 0, @"The fixture must actually deny removal of directory entries");
        if (writable == 0) return;

        XCTAssertTrue([server startWithOptions:options error:NULL]);
        NSString *const refused = WSKUploadSessionRequest(server.port, @"DELETE", location, @{}, nil);
        XCTAssertTrue(ReplyHasStatus(refused, 500), @"Cancellation cannot report success while its files remain: %@", refused);
        XCTAssertEqualObjects([NSData dataWithContentsOfFile:manifestPath], manifest, @"A failed deletion must retain the manifest that owns cleanup");
        XCTAssertEqualObjects([NSData dataWithContentsOfFile:payloadPath], UTF8Data(@"abc"));

        XCTAssertEqual(chmod(sessionDirectory.fileSystemRepresentation, 0700), 0);
        NSString *const retained = WSKUploadSessionRequest(server.port, @"HEAD", location, @{}, nil);
        XCTAssertTrue(ReplyHasStatus(retained, 200), @"%@", retained);
        XCTAssertEqualObjects(WSKUploadReplyHeader(retained, @"Upload-Offset"), @"3");
        NSString *const retried = WSKUploadSessionRequest(server.port, @"DELETE", location, @{}, nil);
        XCTAssertTrue(ReplyHasStatus(retried, 204), @"%@", retried);
        XCTAssertFalse([fm fileExistsAtPath:sessionDirectory]);
        XCTAssertEqual(WSKUploadStoredFileCount(root), (NSUInteger)0);
        XCTAssertEqualObjects([fm contentsOfDirectoryAtPath:[root stringByAppendingPathComponent:@"share"] error:NULL], @[]);
    } @finally {
        [server stop];
        if (sessionDirectory != nil) chmod(sessionDirectory.fileSystemRepresentation, 0700);
        [fm removeItemAtPath:root error:NULL];
    }
}

- (void)testResumableUploadRecreationReapsExpiredSessionsWithoutUploadRequests {
    NSFileManager *const fm = [NSFileManager defaultManager];
    NSString *const root = MakeTempDirectory();
    NSString *const share = [root stringByAppendingPathComponent:@"share"];
    NSDictionary *const options = @{WSKOption_Port: @0, WSKOption_BindToLocalhost: @YES};
    WSKResumableHookUploader *server = WSKUploadServerAtRoot(root);
    server.resumableUploadTimeout = 0.2;
    NSString *const servedFile = [share stringByAppendingPathComponent:@"keep.txt"];
    XCTAssertTrue([UTF8Data(@"kept published bytes") writeToFile:servedFile atomically:YES]);
    XCTAssertTrue([server startWithOptions:options error:NULL]);
    @try {
        NSString *const created = WSKCreateUpload(server.port, [NSUUID UUID].UUIDString, @"abandoned.txt", @"unfinished");
        XCTAssertTrue(ReplyHasStatus(created, 201), @"%@", created);
        XCTAssertGreaterThan(WSKUploadStoredFileCount(root), (NSUInteger)0);
        [server stop];
        server = nil;
        [NSThread sleepForTimeInterval:0.3];
        XCTAssertGreaterThan(WSKUploadStoredFileCount(root), (NSUInteger)0, @"Stopped servers must not be what makes this cleanup test pass");

        server = WSKUploadServerAtRoot(root);
        XCTAssertTrue([server startWithOptions:options error:NULL]);
        // No /uploads request and no private-store call: a long-lived download
        // server must discover and reap abandoned sessions from its predecessor.
        NSDate *const deadline = [NSDate dateWithTimeIntervalSinceNow:3.0];
        while (WSKUploadStoredFileCount(root) > 0 && deadline.timeIntervalSinceNow > 0) {
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        }
        XCTAssertEqual(WSKUploadStoredFileCount(root), (NSUInteger)0);
        XCTAssertEqualObjects([NSData dataWithContentsOfFile:servedFile], UTF8Data(@"kept published bytes"));
        XCTAssertEqualObjects([fm contentsOfDirectoryAtPath:share error:NULL], @[@"keep.txt"]);
        NSString *const download = SendRawRequest(server.port, @"GET /download?path=%2Fkeep.txt HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
        XCTAssertTrue(ReplyHasStatus(download, 200), @"%@", download);
        XCTAssertTrue([download hasSuffix:@"kept published bytes"]);
    } @finally {
        [server stop];
        [fm removeItemAtPath:root error:NULL];
    }
}

- (void)testResumableUploadMalformedManifestRemainsGoneAndReapsAfterGrace {
    NSFileManager *const fm = [NSFileManager defaultManager];
    NSString *const root = MakeTempDirectory();
    WSKResumableHookUploader *const server = WSKUploadServerAtRoot(root);
    server.resumableUploadTimeout = 3600;
    NSDictionary *const options = @{WSKOption_Port: @0, WSKOption_BindToLocalhost: @YES};
    XCTAssertTrue([server startWithOptions:options error:NULL]);
    @try {
        for (id damaged in @[@"[]", @"{", NSNull.null]) {
            NSString *const key = NSUUID.UUID.UUIDString.lowercaseString;
            NSString *const creation = WSKCreateUpload(server.port, key, @"incomplete.txt", @"abcdef");
            XCTAssertTrue(ReplyHasStatus(creation, 201), @"%@", creation);
            NSString *const location = WSKUploadReplyHeader(creation, @"Location");
            if (!location) return;
            NSString *const session = [[root stringByAppendingPathComponent:@"sessions"] stringByAppendingPathComponent:key];
            NSString *const manifest = [session stringByAppendingPathComponent:@"manifest.json"];
            if ([damaged isKindOfClass:NSString.class]) {
                XCTAssertTrue([damaged writeToFile:manifest atomically:NO encoding:NSUTF8StringEncoding error:NULL]);
            } else {
                XCTAssertTrue([fm removeItemAtPath:manifest error:NULL]);
            }
            XCTAssertTrue(ReplyHasStatus(WSKUploadSessionRequest(server.port, @"HEAD", location, @{}, nil), 410));
            XCTAssertTrue([fm fileExistsAtPath:session], @"Fresh malformed state retains its cleanup grace period");
            XCTAssertTrue([fm setAttributes:@{NSFileModificationDate: [NSDate dateWithTimeIntervalSinceNow:-7200]} ofItemAtPath:session error:NULL]);
            XCTAssertTrue(ReplyHasStatus(WSKUploadSessionRequest(server.port, @"HEAD", location, @{}, nil), 404));
            XCTAssertFalse([fm fileExistsAtPath:session], @"Known invalid state must still be reclaimed after its grace period");
        }
    } @finally {
        [server stop];
        [fm removeItemAtPath:root error:NULL];
    }
}

- (void)testResumableUploadUnreadableManifestRetainsAcknowledgedOffsetAndCapacity {
    NSFileManager *const fm = [NSFileManager defaultManager];
    NSString *const root = MakeTempDirectory();
    WSKResumableHookUploader *const server = WSKUploadServerAtRoot(root);
    server.resumableUploadTimeout = 3600;
    NSString *const key = NSUUID.UUID.UUIDString.lowercaseString;
    NSString *const session = [[root stringByAppendingPathComponent:@"sessions"] stringByAppendingPathComponent:key];
    NSString *const manifest = [session stringByAppendingPathComponent:@"manifest.json"];
    NSString *const nextKey = NSUUID.UUID.UUIDString.lowercaseString;
    NSDictionary *const options = @{WSKOption_Port: @0, WSKOption_BindToLocalhost: @YES};
    XCTAssertTrue([server startWithOptions:options error:NULL]);
    @try {
        NSString *const creation = WSKCreateUpload(server.port, key, @"protected.txt", @"abcdef");
        XCTAssertTrue(ReplyHasStatus(creation, 201), @"%@", creation);
        NSString *const location = WSKUploadReplyHeader(creation, @"Location");
        if (!location) return;
        XCTAssertTrue(ReplyHasStatus(WSKPatchUpload(server.port, location, 0, @"abc"), 204));
        XCTAssertEqual(chmod(manifest.fileSystemRepresentation, 0000), 0);
        // Session-directory age is not proof of expiry when its manifest cannot
        // be read. Its actual expiry is still an hour in the future.
        XCTAssertTrue([fm setAttributes:@{NSFileModificationDate: [NSDate dateWithTimeIntervalSinceNow:-7200]} ofItemAtPath:session error:NULL]);
        int const unreadable = open(manifest.fileSystemRepresentation, O_RDONLY);
        XCTAssertEqual(unreadable, -1, @"This regression needs ordinary unprivileged file permissions");
        if (unreadable >= 0) {
            close(unreadable);
            return;
        }
        XCTAssertEqual(errno, EACCES);
        XCTAssertTrue(ReplyHasStatus(WSKUploadSessionRequest(server.port, @"HEAD", location, @{}, nil), 500));
        XCTAssertTrue(ReplyHasStatus(WSKCreateUpload(server.port, key, @"protected.txt", @"abcdef"), 500));
        XCTAssertTrue(ReplyHasStatus(WSKPatchUpload(server.port, location, 3, @"def"), 500));
        XCTAssertTrue(ReplyHasStatus(WSKUploadSessionRequest(server.port, @"DELETE", location, @{}, nil), 500));
        XCTAssertTrue(ReplyHasStatus(WSKCreateUpload(server.port, nextKey, @"next.txt", @"next"), 500), @"Unknown capacity must block new admission until readable");
        XCTAssertFalse([fm fileExistsAtPath:[[root stringByAppendingPathComponent:@"sessions"] stringByAppendingPathComponent:nextKey]]);
        XCTAssertEqual(chmod(manifest.fileSystemRepresentation, 0600), 0, @"Unreadable state must survive request cleanup");
        NSString *const resumed = WSKUploadSessionRequest(server.port, @"HEAD", location, @{}, nil);
        XCTAssertTrue(ReplyHasStatus(resumed, 200), @"%@", resumed);
        XCTAssertEqualObjects(WSKUploadReplyHeader(resumed, @"Upload-Offset"), @"3");
        XCTAssertEqualObjects([NSData dataWithContentsOfFile:[session stringByAppendingPathComponent:@"payload"]], UTF8Data(@"abc"));
        XCTAssertTrue(ReplyHasStatus(WSKPatchUpload(server.port, location, 3, @"def"), 204));
        XCTAssertEqualObjects([NSData dataWithContentsOfFile:[[root stringByAppendingPathComponent:@"share"] stringByAppendingPathComponent:@"protected.txt"]], UTF8Data(@"abcdef"));
    } @finally {
        chmod(manifest.fileSystemRepresentation, 0600);
        [server stop];
        [fm removeItemAtPath:root error:NULL];
    }
}

- (void)testResumableUploadTransientManifestReadErrorsDoNotExpireOrReplaceSessions {
    NSFileManager *const fm = [NSFileManager defaultManager];
    NSString *const root = WSKUploadCanonicalTempDirectory();
    XCTAssertNotNil(root);
    if (!root) return;
    NSString *const share = [root stringByAppendingPathComponent:@"share"];
    XCTAssertTrue([fm createDirectoryAtPath:share withIntermediateDirectories:NO attributes:nil error:NULL]);
    NSString *const directory = [root stringByAppendingPathComponent:@"sessions"];
    WSKUnavailableManifestStore *const store = [[WSKUnavailableManifestStore alloc] initWithDirectory:directory uploadDirectory:share expirationInterval:3600];
    NSString *const key = NSUUID.UUID.UUIDString.lowercaseString;
    NSString *const session = [directory stringByAppendingPathComponent:key];
    NSMutableDictionary *const headers = [WSKUploadCreationHeaders(key, @"recover.txt", @"abcdef") mutableCopy];
    headers[@"Tus-Resumable"] = @"1.0.0";
    headers[@"Content-Length"] = @"0";
    WSKRequest *const create = [[WSKRequest alloc] initWithMethod:@"POST" url:LiteralURL(@"http://localhost/uploads") headers:headers path:@"/uploads" query:@{}];
    NSString *const path = [@"/uploads/" stringByAppendingString:key];
    WSKRequest *const head = [[WSKRequest alloc] initWithMethod:@"HEAD" url:LiteralURL([@"http://localhost" stringByAppendingString:path]) headers:@{@"Tus-Resumable": @"1.0.0"} path:path query:@{}];
    WSKResumableUploadValidationBlock const validate = ^WSKResponse *(NSDictionary *metadata) { (void)metadata; return nil; };
    WSKResumableUploadPublicationBlock const publish = ^WSKResponse *(NSString *payload, NSDictionary *metadata, WSKResumableUploadJournalBlock journal) {
        (void)payload;
        (void)metadata;
        (void)journal;
        XCTFail(@"An incomplete session must never publish");
        return [WSKResponse responseWithStatusCode:500];
    };
    @try {
        XCTAssertEqual([store processRequest:create validate:validate publish:publish].statusCode, (NSInteger)201);
        NSData *const original = [NSData dataWithContentsOfFile:[session stringByAppendingPathComponent:@"manifest.json"]];
        XCTAssertNotNil(original);
        XCTAssertTrue([fm setAttributes:@{NSFileModificationDate: [NSDate dateWithTimeIntervalSinceNow:-7200]} ofItemAtPath:session error:NULL]);
        for (NSNumber *code in @[@EACCES, @EIO, @EMFILE, @ENFILE]) {
            store.manifestReadError = code.intValue;
            [store cleanupExpiredUploads];
            XCTAssertEqualObjects([NSData dataWithContentsOfFile:[session stringByAppendingPathComponent:@"manifest.json"]], original);
            XCTAssertEqual([store processRequest:head validate:validate publish:publish].statusCode, (NSInteger)500, @"%@", code);
            XCTAssertEqual([store processRequest:create validate:validate publish:publish].statusCode, (NSInteger)500, @"%@", code);
        }
        store.manifestReadError = 0;
        WSKResponse *const resumed = [store processRequest:head validate:validate publish:publish];
        XCTAssertEqual(resumed.statusCode, (NSInteger)200);
        XCTAssertEqualObjects(resumed.additionalHeaders[@"Upload-Offset"], @"0");
    } @finally {
        [fm removeItemAtPath:root error:NULL];
    }
}

- (void)testResumableUploadMaintenanceReclaimsOnlyUnjournaledPrivateStages {
    NSFileManager *const fm = NSFileManager.defaultManager;
    NSString *const root = WSKUploadCanonicalTempDirectory();
    XCTAssertNotNil(root);
    if (!root) return;
    WSKResumableHookUploader *const server = WSKUploadServerAtRoot(root);
    NSString *const key = NSUUID.UUID.UUIDString.lowercaseString;
    NSString *const sessions = [root stringByAppendingPathComponent:@"sessions"];
    NSString *const session = [sessions stringByAppendingPathComponent:key];
    NSString *const share = [root stringByAppendingPathComponent:@"share"];
    NSDictionary *const options = @{WSKOption_Port: @0, WSKOption_BindToLocalhost: @YES};
    XCTAssertTrue([server startWithOptions:options error:NULL]);
    @try {
        NSString *const creation = WSKCreateUpload(server.port, key, @"stage-recovery.txt", @"abcdef");
        XCTAssertTrue(ReplyHasStatus(creation, 201), @"%@", creation);
        NSString *const location = WSKUploadReplyHeader(creation, @"Location");
        if (!location) return;
        XCTAssertTrue(ReplyHasStatus(WSKPatchUpload(server.port, location, 0, @"abc"), 204));
        [server stop];
        NSString *const orphan = [session stringByAppendingPathComponent:[@".stage-" stringByAppendingString:NSUUID.UUID.UUIDString.lowercaseString]];
        NSString *const unknown = [session stringByAppendingPathComponent:@".stage-not-an-upload"];
        NSString *const sentinel = [root stringByAppendingPathComponent:@"retained.txt"];
        NSString *const link = [session stringByAppendingPathComponent:[@".stage-" stringByAppendingString:NSUUID.UUID.UUIDString.lowercaseString]];
        XCTAssertTrue([UTF8Data(@"partial stage") writeToFile:orphan atomically:NO]);
        XCTAssertTrue([UTF8Data(@"not a stage") writeToFile:unknown atomically:NO]);
        XCTAssertTrue([UTF8Data(@"retained") writeToFile:sentinel atomically:NO]);
        XCTAssertEqual(symlink(sentinel.fileSystemRepresentation, link.fileSystemRepresentation), 0);
        WSKResumableUploadStore *const store = [[WSKResumableUploadStore alloc] initWithDirectory:sessions uploadDirectory:share expirationInterval:3600];
        // Exercise maintenance directly: no HEAD or upload request may perform
        // recovery on its behalf, and this active session has not expired.
        [store cleanupExpiredUploads];
        XCTAssertFalse([fm fileExistsAtPath:orphan]);
        XCTAssertEqualObjects([NSData dataWithContentsOfFile:unknown], UTF8Data(@"not a stage"));
        XCTAssertEqualObjects([NSData dataWithContentsOfFile:sentinel], UTF8Data(@"retained"));
        struct stat info = {0};
        XCTAssertEqual(lstat(link.fileSystemRepresentation, &info), 0);
        XCTAssertTrue(S_ISLNK(info.st_mode));
        XCTAssertEqualObjects([NSData dataWithContentsOfFile:[session stringByAppendingPathComponent:@"payload"]], UTF8Data(@"abc"));
        XCTAssertTrue([server startWithOptions:options error:NULL]);
        NSString *const resumed = WSKUploadSessionRequest(server.port, @"HEAD", location, @{}, nil);
        XCTAssertTrue(ReplyHasStatus(resumed, 200), @"%@", resumed);
        XCTAssertEqualObjects(WSKUploadReplyHeader(resumed, @"Upload-Offset"), @"3");
        XCTAssertTrue(ReplyHasStatus(WSKPatchUpload(server.port, location, 3, @"def"), 204));
        XCTAssertEqualObjects([NSData dataWithContentsOfFile:[share stringByAppendingPathComponent:@"stage-recovery.txt"]], UTF8Data(@"abcdef"));
    } @finally {
        [server stop];
        [fm removeItemAtPath:root error:NULL];
    }
}

- (void)testResumableUploadDirectoryChangesTakeEffectAfterStopping {
    NSFileManager *const fm = [NSFileManager defaultManager];
    NSString *const root = MakeTempDirectory();
    NSString *const otherRoot = [root stringByAppendingPathComponent:@"other-storage"];
    NSDictionary *const options = @{WSKOption_Port: @0, WSKOption_BindToLocalhost: @YES};
    WSKResumableHookUploader *const server = WSKUploadServerAtRoot(root);
    NSString *const firstDirectory = server.resumableUploadDirectory;
    XCTAssertTrue([server startWithOptions:options error:NULL]);
    @try {
        NSString *const first = WSKCreateUpload(server.port, [NSUUID UUID].UUIDString, @"first.txt", @"first body");
        NSString *const firstLocation = WSKUploadReplyHeader(first, @"Location");
        XCTAssertTrue(ReplyHasStatus(first, 201), @"%@", first);
        if (firstLocation == nil) return;
        NSUInteger const firstStoredCount = WSKUploadStoredFileCount(root);
        XCTAssertGreaterThan(firstStoredCount, (NSUInteger)0);
        [server stop];

        server.resumableUploadDirectory = [otherRoot stringByAppendingPathComponent:@"sessions"];
        XCTAssertTrue([server startWithOptions:options error:NULL]);
        NSString *const oldSessionInNewStore = WSKUploadSessionRequest(server.port, @"HEAD", firstLocation, @{}, nil);
        XCTAssertTrue(ReplyHasStatus(oldSessionInNewStore, 404), @"The configured new directory must not retain the cached old store: %@", oldSessionInNewStore);
        NSString *const second = WSKCreateUpload(server.port, [NSUUID UUID].UUIDString, @"second.txt", @"second body");
        NSString *const secondLocation = WSKUploadReplyHeader(second, @"Location");
        XCTAssertTrue(ReplyHasStatus(second, 201), @"%@", second);
        if (secondLocation == nil) return;
        XCTAssertGreaterThan(WSKUploadStoredFileCount(otherRoot), (NSUInteger)0);
        XCTAssertEqual(WSKUploadStoredFileCount(root), firstStoredCount, @"Changing stores must not discard the old store's progress");
        [server stop];

        server.resumableUploadDirectory = firstDirectory;
        XCTAssertTrue([server startWithOptions:options error:NULL]);
        NSString *const restored = WSKUploadSessionRequest(server.port, @"HEAD", firstLocation, @{}, nil);
        XCTAssertTrue(ReplyHasStatus(restored, 200), @"%@", restored);
        XCTAssertEqualObjects(WSKUploadReplyHeader(restored, @"Upload-Offset"), @"0");
        XCTAssertTrue(ReplyHasStatus(WSKUploadSessionRequest(server.port, @"HEAD", secondLocation, @{}, nil), 404));
    } @finally {
        [server stop];
        [fm removeItemAtPath:root error:NULL];
    }
}

- (void)testResumableUploadTimeoutChangesTakeEffectAfterStopping {
    NSFileManager *const fm = [NSFileManager defaultManager];
    NSString *const root = MakeTempDirectory();
    NSDictionary *const options = @{WSKOption_Port: @0, WSKOption_BindToLocalhost: @YES};
    WSKResumableHookUploader *const server = WSKUploadServerAtRoot(root);
    server.resumableUploadTimeout = 3600;
    XCTAssertTrue([server startWithOptions:options error:NULL]);
    @try {
        NSString *const first = WSKCreateUpload(server.port, [NSUUID UUID].UUIDString, @"long.txt", @"first body");
        NSString *const firstLocation = WSKUploadReplyHeader(first, @"Location");
        XCTAssertTrue(ReplyHasStatus(first, 201), @"%@", first);
        if (firstLocation == nil) return;
        [server stop];

        server.resumableUploadTimeout = 0.2;
        XCTAssertTrue([server startWithOptions:options error:NULL]);
        NSString *const second = WSKCreateUpload(server.port, [NSUUID UUID].UUIDString, @"short.txt", @"second body");
        NSString *const secondLocation = WSKUploadReplyHeader(second, @"Location");
        XCTAssertTrue(ReplyHasStatus(second, 201), @"%@", second);
        if (secondLocation == nil) return;
        [NSThread sleepForTimeInterval:0.3];
        NSString *const expired = WSKUploadSessionRequest(server.port, @"HEAD", secondLocation, @{}, nil);
        XCTAssertTrue(ReplyHasStatus(expired, 404), @"New uploads must use the updated timeout instead of the cached one: %@", expired);
        NSString *const retained = WSKUploadSessionRequest(server.port, @"HEAD", firstLocation, @{}, nil);
        XCTAssertTrue(ReplyHasStatus(retained, 200), @"Changing the timeout must preserve the expiry already granted to an existing session: %@", retained);
        XCTAssertEqualObjects(WSKUploadReplyHeader(retained, @"Upload-Offset"), @"0");
    } @finally {
        [server stop];
        [fm removeItemAtPath:root error:NULL];
    }
}

- (void)testResumableUploadAdmissionBoundsDeclaredLengthAndActiveSessions {
    NSFileManager *const fm = [NSFileManager defaultManager];
    NSString *const root = MakeTempDirectory();
    WSKResumableHookUploader *const server = WSKUploadServerAtRoot(root);
    NSDictionary *const options = @{WSKOption_Port: @0, WSKOption_BindToLocalhost: @YES};
    XCTAssertTrue([server startWithOptions:options error:NULL]);
    @try {
        NSMutableDictionary *const tooLargeHeaders = [WSKUploadCreationHeaders([NSUUID UUID].UUIDString, @"large.bin", @"x") mutableCopy];
        tooLargeHeaders[@"Upload-Length"] = @"8589934593";
        NSString *const tooLarge = WSKUploadSessionRequest(server.port, @"POST", @"/uploads", tooLargeHeaders, @"");
        XCTAssertTrue(ReplyHasStatus(tooLarge, 413), @"%@", tooLarge);
        XCTAssertEqual(WSKUploadStoredFileCount(root), (NSUInteger)0);

        NSMutableArray<NSString *> *const locations = [NSMutableArray array];
        for (NSUInteger i = 0; i < 32; i++) {
            NSString *const created = WSKCreateUpload(server.port, [NSUUID UUID].UUIDString, @"bounded.txt", @"x");
            XCTAssertTrue(ReplyHasStatus(created, 201), @"session %lu: %@", (unsigned long)i, created);
            NSString *const location = WSKUploadReplyHeader(created, @"Location");
            if (location == nil) return;
            [locations addObject:location];
        }
        NSString *const full = WSKCreateUpload(server.port, [NSUUID UUID].UUIDString, @"overflow.txt", @"x");
        XCTAssertTrue(ReplyHasStatus(full, 413), @"%@", full);
        NSString *const cancelled = WSKUploadSessionRequest(server.port, @"DELETE", locations[0], @{}, nil);
        XCTAssertTrue(ReplyHasStatus(cancelled, 204), @"%@", cancelled);
        NSString *const replacement = WSKCreateUpload(server.port, [NSUUID UUID].UUIDString, @"retry.txt", @"x");
        XCTAssertTrue(ReplyHasStatus(replacement, 201), @"termination must release admission immediately: %@", replacement);

        // A completed receipt does not consume an active slot: acknowledge completion, then
        // create another transfer without deleting its receipt first.
        NSString *const completed = WSKPatchUpload(server.port, locations[1], 0, @"x");
        XCTAssertTrue(ReplyHasStatus(completed, 204), @"%@", completed);
        NSString *const afterComplete = WSKCreateUpload(server.port, [NSUUID UUID].UUIDString, @"next.txt", @"x");
        XCTAssertTrue(ReplyHasStatus(afterComplete, 201), @"%@", afterComplete);
    } @finally {
        [server stop];
        [fm removeItemAtPath:root error:NULL];
    }
}

- (void)testResumableUploadDeclaredCapacityIsReleasedByTermination {
    NSFileManager *const fm = [NSFileManager defaultManager];
    NSString *const root = MakeTempDirectory();
    WSKResumableHookUploader *const server = WSKUploadServerAtRoot(root);
    NSDictionary *const options = @{WSKOption_Port: @0, WSKOption_BindToLocalhost: @YES};
    XCTAssertTrue([server startWithOptions:options error:NULL]);
    @try {
        NSMutableArray<NSString *> *const locations = [NSMutableArray array];
        for (NSUInteger i = 0; i < 4; i++) {
            NSMutableDictionary *const headers = [WSKUploadCreationHeaders([NSUUID UUID].UUIDString, @"large.bin", @"x") mutableCopy];
            headers[@"Upload-Length"] = @"8589934592";
            NSString *const created = WSKUploadSessionRequest(server.port, @"POST", @"/uploads", headers, @"");
            XCTAssertTrue(ReplyHasStatus(created, 201), @"reservation %lu: %@", (unsigned long)i, created);
            NSString *const location = WSKUploadReplyHeader(created, @"Location");
            if (location == nil) return;
            [locations addObject:location];
        }
        // Only headers were sent: reserving declared capacity must not allocate the file bodies.
        NSString *const full = WSKCreateUpload(server.port, [NSUUID UUID].UUIDString, @"small.txt", @"x");
        XCTAssertTrue(ReplyHasStatus(full, 413), @"%@", full);
        XCTAssertTrue(ReplyHasStatus(WSKUploadSessionRequest(server.port, @"DELETE", locations[0], @{}, nil), 204));
        NSString *const retried = WSKCreateUpload(server.port, [NSUUID UUID].UUIDString, @"small.txt", @"x");
        XCTAssertTrue(ReplyHasStatus(retried, 201), @"deleting a session must release its declared capacity: %@", retried);
        NSString *const smallLocation = WSKUploadReplyHeader(retried, @"Location");
        if (smallLocation == nil) return;
        XCTAssertTrue(ReplyHasStatus(WSKPatchUpload(server.port, smallLocation, 0, @"x"), 204));
        NSString *const path = [[root stringByAppendingPathComponent:@"share"] stringByAppendingPathComponent:@"small.txt"];
        XCTAssertEqualObjects([NSData dataWithContentsOfFile:path], UTF8Data(@"x"));
    } @finally {
        [server stop];
        [fm removeItemAtPath:root error:NULL];
    }
}

- (void)testWebUploader {
    NSString *const dir = MakeTempDirectory();
    WSKWebUploader *const server = [[WSKWebUploader alloc] initWithUploadDirectory:dir];

    XCTAssertNotNil(server);
    [[NSFileManager defaultManager] removeItemAtPath:dir error:NULL];
}

// The uploader's /download built its response with +responseWithFile:isAttachment:, which passes
// NSMakeRange(NSUIntegerMax, 0) — no range at all — so a "Range" header was ignored and the whole
// file came back 200. The base-path handler and DAV's GET have both passed request.byteRange and
// request.ifRange for several passes; this endpoint never did. For Shape A that means an
// interrupted download of a multi-hundred-megabyte build cannot resume, and it is also why a
// <video> cannot seek. Going through the ifRange: variant is what brings the If-Range protection
// with it, so a resume against a REPLACED file is refused rather than spliced.
- (void)testUploaderDownloadHonoursRangeRequests {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dir = MakeTempDirectory();
    XCTAssertTrue([@"0123456789" writeToFile:[dir stringByAppendingPathComponent:@"a.txt"] atomically:YES encoding:NSUTF8StringEncoding error:NULL]);

    WSKWebUploader *server = [[WSKWebUploader alloc] initWithUploadDirectory:dir];
    NSDictionary *options = @{WSKOption_Port: @0, WSKOption_BindToLocalhost: @YES};
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    NSString *partial = SendRawRequest(server.port, @"GET /download?path=%2Fa.txt HTTP/1.1\r\nHost: localhost\r\nRange: bytes=2-5\r\n\r\n");
    XCTAssertTrue([partial hasPrefix:@"HTTP/1.1 206"], @"a Range request must be answered with 206: %@", [partial substringToIndex:MIN((NSUInteger)40, partial.length)]);
    XCTAssertTrue([partial containsString:@"Content-Range: bytes 2-5/10"], @"the 206 must describe which bytes it carries: %@", partial);
    XCTAssertTrue([partial hasSuffix:@"2345"], @"the 206 must carry exactly the requested bytes: %@", partial);

    // An open-ended range is how a resume is actually spelled.
    NSString *resume = SendRawRequest(server.port, @"GET /download?path=%2Fa.txt HTTP/1.1\r\nHost: localhost\r\nRange: bytes=7-\r\n\r\n");
    XCTAssertTrue([resume hasPrefix:@"HTTP/1.1 206"], @"an open-ended resume must be 206: %@", [resume substringToIndex:MIN((NSUInteger)40, resume.length)]);
    XCTAssertTrue([resume hasSuffix:@"789"], @"the resume must carry the tail: %@", resume);

    // Unsatisfiable is 416 with the total, not a silent whole-file 200.
    NSString *beyond = SendRawRequest(server.port, @"GET /download?path=%2Fa.txt HTTP/1.1\r\nHost: localhost\r\nRange: bytes=999-\r\n\r\n");
    XCTAssertTrue([beyond hasPrefix:@"HTTP/1.1 416"], @"an unsatisfiable range is 416: %@", [beyond substringToIndex:MIN((NSUInteger)40, beyond.length)]);

    // And what must keep working: no Range header still serves the whole file as an attachment.
    NSString *whole = SendRawRequest(server.port, @"GET /download?path=%2Fa.txt HTTP/1.1\r\nHost: localhost\r\n\r\n");
    XCTAssertTrue([whole hasPrefix:@"HTTP/1.1 200"], @"an ordinary download is unchanged: %@", [whole substringToIndex:MIN((NSUInteger)40, whole.length)]);
    XCTAssertTrue([whole containsString:@"attachment"], @"an ordinary download is still an attachment");
    XCTAssertTrue([whole hasSuffix:@"0123456789"], @"an ordinary download still carries the whole file");

    [server stop];
    [fm removeItemAtPath:dir error:NULL];
}

// Rendering a shared file INLINE puts it in the server's own origin, and this UI's one-click
// buttons delete and move files — so an uploaded .html or .svg served inline is stored XSS against
// the share itself. That is the whole reason /download forces "attachment", and it is also why a
// media-rich UI cannot simply drop the flag: <img src="/download?..."> triggers a save dialog
// rather than rendering.
//
// /preview is the narrow, inert-only alternative: an allow-list of types a browser cannot execute,
// plus nosniff so a .png full of markup cannot be sniffed into active content, plus a CSP that
// denies everything even if a type ever slips through. SVG is deliberately excluded despite being
// an image — it carries script, and it is the exact trap an "images are safe" allow-list springs.
- (void)testUploaderPreviewServesInertMediaInlineAndRefusesActiveContent {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dir = MakeTempDirectory();
    // Deliberately ASCII rather than real PNG bytes: the type is derived from the EXTENSION, so
    // the content is irrelevant to what is being tested, and binary would make the reply
    // undecodable as a string and every assertion below read "(null)".
    XCTAssertTrue([@"PIXELS" writeToFile:[dir stringByAppendingPathComponent:@"pic.png"] atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
    XCTAssertTrue([@"<script>alert(1)</script>" writeToFile:[dir stringByAppendingPathComponent:@"evil.html"] atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
    XCTAssertTrue([@"<svg xmlns=\"http://www.w3.org/2000/svg\"><script>alert(1)</script></svg>" writeToFile:[dir stringByAppendingPathComponent:@"evil.svg"] atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
    XCTAssertTrue([fm createDirectoryAtPath:[dir stringByAppendingPathComponent:@".hidden"] withIntermediateDirectories:YES attributes:nil error:NULL]);
    XCTAssertTrue([@"SECRET" writeToFile:[dir stringByAppendingPathComponent:@".hidden/secret.png"] atomically:YES encoding:NSUTF8StringEncoding error:NULL]);

    WSKWebUploader *server = [[WSKWebUploader alloc] initWithUploadDirectory:dir];
    NSDictionary *options = @{WSKOption_Port: @0, WSKOption_BindToLocalhost: @YES};
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    NSString *image = SendRawRequest(server.port, @"GET /preview?path=%2Fpic.png HTTP/1.1\r\nHost: localhost\r\n\r\n");
    XCTAssertTrue([image hasPrefix:@"HTTP/1.1 200"], @"an inert image must render: %@", [image substringToIndex:MIN((NSUInteger)40, image.length)]);
    XCTAssertTrue([image containsString:@"Content-Disposition: inline"], @"the whole point is inline disposition: %@", image);
    XCTAssertFalse([image containsString:@"attachment"], @"an inline preview must not also say attachment");
    XCTAssertTrue([image containsString:@"X-Content-Type-Options: nosniff"], @"inline content must never be sniffable");
    XCTAssertTrue([image containsString:@"Content-Type: image/png"], @"the type must be stated so nosniff has something to pin: %@", image);
    XCTAssertTrue([image containsString:@"Content-Security-Policy:"], @"inline content gets a policy that denies everything");

    // Active content is refused outright — including SVG, which is an image and is NOT inert.
    for (NSString *active in @[@"%2Fevil.html", @"%2Fevil.svg"]) {
        NSString *reply = SendRawRequest(server.port, [NSString stringWithFormat:@"GET /preview?path=%@ HTTP/1.1\r\nHost: localhost\r\n\r\n", active]);
        XCTAssertTrue([reply hasPrefix:@"HTTP/1.1 403"], @"%@ must not be served inline: %@", active, [reply substringToIndex:MIN((NSUInteger)40, reply.length)]);
        XCTAssertFalse([reply containsString:@"alert(1)"], @"%@ must not have its body reflected either", active);
    }

    // But /download still serves them, as attachments — refusing inline must not remove the file
    // from the share, only from the inline surface.
    NSString *downloaded = SendRawRequest(server.port, @"GET /download?path=%2Fevil.svg HTTP/1.1\r\nHost: localhost\r\n\r\n");
    XCTAssertTrue([downloaded hasPrefix:@"HTTP/1.1 200"], @"the file is still downloadable: %@", [downloaded substringToIndex:MIN((NSUInteger)40, downloaded.length)]);
    XCTAssertTrue([downloaded containsString:@"attachment"], @"…as an attachment");

    // Every refusal /download makes, /preview makes too: it is a second door to the same files.
    XCTAssertTrue([SendRawRequest(server.port, @"GET /preview?path=%2F.hidden%2Fsecret.png HTTP/1.1\r\nHost: localhost\r\n\r\n") hasPrefix:@"HTTP/1.1 403"], @"a hidden path is refused on the preview surface too");
    XCTAssertTrue([SendRawRequest(server.port, @"GET /preview?path=%2Fnope.png HTTP/1.1\r\nHost: localhost\r\n\r\n") hasPrefix:@"HTTP/1.1 404"], @"a missing file is still 404");

    // Range works here too, because that is what a <video> needs to seek.
    NSString *ranged = SendRawRequest(server.port, @"GET /preview?path=%2Fpic.png HTTP/1.1\r\nHost: localhost\r\nRange: bytes=1-3\r\n\r\n");
    XCTAssertTrue([ranged hasPrefix:@"HTTP/1.1 206"], @"preview must honour Range: %@", [ranged substringToIndex:MIN((NSUInteger)40, ranged.length)]);

    [server stop];
    [fm removeItemAtPath:dir error:NULL];
}

// Caching is opt-in, and the default must stay as it was. A share is mutable — files are uploaded,
// moved and deleted through this very UI — so a max-age the caller did not ask for would hand a
// browser a window in which it serves content the share no longer holds, with no request to notice
// it. Left at 0, every response still says no-cache, which does NOT mean "do not store": the
// browser keeps the body and revalidates with If-None-Match, so a thumbnail grid already costs 304s
// rather than bodies. What max-age buys is removing the request itself, which is the caller's call.
- (void)testUploaderFileCacheControlMaxAgeIsOptIn {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dir = MakeTempDirectory();
    XCTAssertTrue([@"PIXELS" writeToFile:[dir stringByAppendingPathComponent:@"pic.png"] atomically:YES encoding:NSUTF8StringEncoding error:NULL]);

    WSKWebUploader *server = [[WSKWebUploader alloc] initWithUploadDirectory:dir];
    NSDictionary *options = @{WSKOption_Port: @0, WSKOption_BindToLocalhost: @YES};
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    XCTAssertEqual(server.fileCacheControlMaxAge, (NSUInteger)0, @"the default must be no caching directive");

    for (NSString *endpoint in @[@"download", @"preview"]) {
        NSString *reply = SendRawRequest(server.port, [NSString stringWithFormat:@"GET /%@?path=%%2Fpic.png HTTP/1.1\r\nHost: localhost\r\n\r\n", endpoint]);
        XCTAssertTrue([reply containsString:@"Cache-Control: no-cache"], @"/%@ must revalidate by default: %@", endpoint, reply);
    }

    [server stop];

    server.fileCacheControlMaxAge = 3600;
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    for (NSString *endpoint in @[@"download", @"preview"]) {
        NSString *reply = SendRawRequest(server.port, [NSString stringWithFormat:@"GET /%@?path=%%2Fpic.png HTTP/1.1\r\nHost: localhost\r\n\r\n", endpoint]);
        XCTAssertTrue([reply containsString:@"max-age=3600"], @"/%@ must honour the configured age: %@", endpoint, reply);
    }

    // A revalidation still works and still answers 304, so a client that asks anyway is told the
    // truth rather than handed the body again.
    // CFHTTPMessage standardizes the field name, so it goes out as "Etag" rather than the "ETag"
    // the source spells — match case-insensitively rather than pinning CF's choice.
    NSString *first = SendRawRequest(server.port, @"GET /preview?path=%2Fpic.png HTTP/1.1\r\nHost: localhost\r\n\r\n");
    NSRange const tagRange = [first rangeOfString:@"etag: " options:NSCaseInsensitiveSearch];
    XCTAssertNotEqual(tagRange.location, (NSUInteger)NSNotFound, @"a file response carries an entity tag: %@", first);

    if (tagRange.location != NSNotFound) {
        NSString *tail = [first substringFromIndex:NSMaxRange(tagRange)];
        NSString *tag = [tail substringToIndex:[tail rangeOfString:@"\r\n"].location];
        NSString *revalidated = SendRawRequest(server.port, [NSString stringWithFormat:@"GET /preview?path=%%2Fpic.png HTTP/1.1\r\nHost: localhost\r\nIf-None-Match: %@\r\n\r\n", tag]);
        XCTAssertTrue([revalidated hasPrefix:@"HTTP/1.1 304"], @"an unchanged preview revalidates to 304: %@", [revalidated substringToIndex:MIN((NSUInteger)40, revalidated.length)]);
    }

    [server stop];
    [fm removeItemAtPath:dir error:NULL];
}

// Scoping the asset handlers removed the catch-all that used to serve the bundle root, and with
// it the incidental 404 every unmatched GET fell through to — so "/favicon.ico", which browsers
// request unprompted, started answering 501 Not Implemented. 501 is a statement about the
// method, which the server implements perfectly well.
- (void)testUploaderAnswersNotFoundRatherThanNotImplemented {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dir = MakeTempDirectory();

    WSKWebUploader *server = [[WSKWebUploader alloc] initWithUploadDirectory:dir];
    NSDictionary *options = @{WSKOption_Port: @0, WSKOption_BindToLocalhost: @YES};
    XCTAssertTrue([server startWithOptions:options error:NULL]);
    NSString *host = [NSString stringWithFormat:@"localhost:%lu", (unsigned long)server.port];

    for (NSString *path in @[@"/favicon.ico", @"/apple-touch-icon.png", @"/nope.txt", @"/css/missing.css"]) {
        NSString *reply = SendRawRequest(server.port, [NSString stringWithFormat:@"GET %@ HTTP/1.1\r\nHost: %@\r\n\r\n", path, host]);
        XCTAssertTrue([reply hasPrefix:@"HTTP/1.1 404"], @"\"%@\" should be Not Found: %@", path, [reply substringToIndex:MIN((NSUInteger)40, reply.length)]);
    }

    // The catch-all matches GET only, exactly as the base path handler it replaces did, so no
    // other method's status is affected by it.
    //
    // This used to assert "not 404", which worked only while an unmatched request answered 501.
    // Now that an unmatched request answers 404 when the method exists elsewhere — and the
    // uploader does register POST handlers — that proxy cannot tell "the catch-all declined" from
    // "the catch-all claimed it". Assert the property directly instead: a POST to a path the
    // catch-all WOULD serve for a GET must not come back with that path's contents.
    NSString *postedToRealAsset = SendRawRequest(server.port, [NSString stringWithFormat:@"POST /css/index.css HTTP/1.1\r\nHost: %@\r\nContent-Length: 0\r\n\r\n", host]);
    XCTAssertFalse([postedToRealAsset hasPrefix:@"HTTP/1.1 200"], @"the catch-all must not serve a non-GET method: %@", [postedToRealAsset substringToIndex:MIN((NSUInteger)40, postedToRealAsset.length)]);

    // And it must sit behind every real handler, not in front of them.
    NSString *page = SendRawRequest(server.port, [NSString stringWithFormat:@"GET / HTTP/1.1\r\nHost: %@\r\n\r\n", host]);
    XCTAssertTrue([page hasPrefix:@"HTTP/1.1 200"], @"the catch-all shadowed the page handler: %@", [page substringToIndex:MIN((NSUInteger)40, page.length)]);
    NSString *asset = SendRawRequest(server.port, [NSString stringWithFormat:@"GET /css/index.css HTTP/1.1\r\nHost: %@\r\n\r\n", host]);
    XCTAssertTrue([asset hasPrefix:@"HTTP/1.1 200"], @"the catch-all shadowed the asset handlers: %@", [asset substringToIndex:MIN((NSUInteger)40, asset.length)]);

    [server stop];
    [fm removeItemAtPath:dir error:NULL];
}

// The uploader's bundle contains index.html, and the base-path handler serves that bundle at
// "/", so "/index.html" returned the raw template — the same UI, with none of the framing
// headers the "/" handler sets. Framing that path instead of "/" therefore defeated the
// clickjacking defence outright, on a UI whose one-click buttons delete and move files.
- (void)testUploaderTemplatePathCannotBypassFramingHeaders {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dir = MakeTempDirectory();

    WSKWebUploader *server = [[WSKWebUploader alloc] initWithUploadDirectory:dir];
    NSDictionary *options = @{WSKOption_Port: @0, WSKOption_BindToLocalhost: @YES};
    XCTAssertTrue([server startWithOptions:options error:NULL]);
    NSString *host = [NSString stringWithFormat:@"localhost:%lu", (unsigned long)server.port];

    NSString * (^get)(NSString *) = ^(NSString *path) {
        return SendRawRequest(server.port, [NSString stringWithFormat:@"GET %@ HTTP/1.1\r\nHost: %@\r\n\r\n", path, host]);
    };

    for (NSString *path in @[@"/", @"/index.html"]) {
        NSString *reply = get(path);
        XCTAssertTrue([reply containsString:@"X-Frame-Options: DENY"], @"\"%@\" is framable: %@", path, reply);
        XCTAssertTrue([reply containsString:@"frame-ancestors 'none'"], @"\"%@\" has no frame-ancestors: %@", path, reply);
        XCTAssertTrue([reply containsString:@"X-Content-Type-Options: nosniff"], @"\"%@\" may be sniffed: %@", path, reply);
    }

    // No spelling may reach the template. Excluding it by path is not enough — the base path
    // handler normalizes, so the last two here still reached the raw file when the fix was an
    // exact-path alias sitting in front of it. The unsubstituted placeholder is what identifies
    // the template, independently of which headers happen to be on the reply.
    for (NSString *path in @[@"/", @"/index.html", @"/INDEX.HTML", @"/./index.html", @"/x/../index.html"]) {
        XCTAssertFalse([get(path) containsString:@"%device%"], @"\"%@\" served the raw template", path);
    }

    // ...and the page's own assets must still be served, or this has merely broken the UI.
    // Asked for with HEAD: a font body is not UTF-8, so a GET would come back as a nil string
    // here and read as a failure whether or not the asset was served.
    for (NSString *asset in @[@"/css/index.css", @"/js/index.js", @"/fonts/glyphicons-halflings-regular.ttf"]) {
        NSString *reply = SendRawRequest(server.port, [NSString stringWithFormat:@"HEAD %@ HTTP/1.1\r\nHost: %@\r\n\r\n", asset, host]);
        XCTAssertTrue([reply hasPrefix:@"HTTP/1.1 200"], @"asset \"%@\" is no longer served: %@", asset, [reply substringToIndex:MIN((NSUInteger)40, reply.length)]);
    }

    [server stop];
    [fm removeItemAtPath:dir error:NULL];
}

- (void)testUploaderRejectsCrossOriginMutation {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dir = MakeTempDirectory();

    WSKWebUploader *server = [[WSKWebUploader alloc] initWithUploadDirectory:dir];
    NSDictionary *options = @{WSKOption_Port: @0, WSKOption_BindToLocalhost: @YES};
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    NSString *host = [NSString stringWithFormat:@"localhost:%lu", (unsigned long)server.port];

    // Cross-origin Origin -> rejected with 403; the directory must not be created.
    NSString *body = @"path=/EvilFolder";
    NSString *crossOrigin = SendRawRequest(server.port, [NSString stringWithFormat:@"POST /create HTTP/1.1\r\nHost: %@\r\nOrigin: http://evil.example\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: %lu\r\n\r\n%@", host, (unsigned long)body.length, body]);
    XCTAssertTrue(ReplyHasStatus(crossOrigin, 403), @"cross-origin mutation must be rejected, got: %@", crossOrigin);
    XCTAssertFalse([fm fileExistsAtPath:[dir stringByAppendingPathComponent:@"EvilFolder"]], @"cross-origin request created the folder");

    // No Origin header (non-browser client) -> allowed.
    NSString *body2 = @"path=/GoodFolder";
    NSString *noOrigin = SendRawRequest(server.port, [NSString stringWithFormat:@"POST /create HTTP/1.1\r\nHost: %@\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: %lu\r\n\r\n%@", host, (unsigned long)body2.length, body2]);
    XCTAssertFalse(ReplyHasStatus(noOrigin, 403), @"a request with no Origin should be allowed, got: %@", noOrigin);
    XCTAssertTrue([fm fileExistsAtPath:[dir stringByAppendingPathComponent:@"GoodFolder"]], @"the legitimate request did not create the folder: %@", noOrigin);

    [server stop];
    [fm removeItemAtPath:dir error:NULL];
}

// NOTE (2026-08-19): a test was written here asserting that a same-origin Referer whose path
// begins with a combining mark is allowed, and it PASSED against the unfixed code — the origin
// parse never had the composed-sequence bug in practice. CFHTTPMessage decodes header values as
// Latin-1, so the UTF-8 bytes of U+030C arrive as two ordinary characters (U+00CC, U+008C) and
// no combining mark can reach a header-parsing search at all. The test was deleted rather than
// kept green: it could not fail for the reason it claimed to test. The NSLiteralSearch in
// _OriginAuthority stays as a statement of intent, not as a fix for a reachable defect.

// "GET /list" with no "path" query parameter must be answered, not crash the process.
// A nil path survived every guard (WSKNormalizePath(nil) is @"", so the
// absolute path collapsed to the upload directory, which exists and is a directory) and
// then reached the per-entry dictionary literal, where -stringByAppendingPathComponent:
// on nil yields nil — inserting nil raises NSInvalidArgumentException, which nothing
// catches, so a single unauthenticated GET terminated the whole app. The listing must be
// non-empty for the loop to be entered at all, so seed both a file and a subdirectory.
- (void)testUploaderListWithoutPathParameterDoesNotCrash {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dir = MakeTempDirectory();
    XCTAssertTrue([@"data" writeToFile:[dir stringByAppendingPathComponent:@"a.txt"] atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
    XCTAssertTrue([fm createDirectoryAtPath:[dir stringByAppendingPathComponent:@"Sub"] withIntermediateDirectories:NO attributes:nil error:NULL]);

    WSKWebUploader *server = [[WSKWebUploader alloc] initWithUploadDirectory:dir];
    NSDictionary *options = @{WSKOption_Port: @0, WSKOption_BindToLocalhost: @YES};
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    NSString *reply = SendRawRequest(server.port, @"GET /list HTTP/1.1\r\nHost: localhost\r\n\r\n");
    XCTAssertNotNil(reply, @"server appears to have crashed handling /list with no path parameter");
    XCTAssertTrue(ReplyHasStatus(reply, 200), @"a missing path should list the root, got: %@", reply);
    // The entries must be rooted at "/", i.e. the default was applied rather than a nil
    // path silently producing bare names. NSJSONSerialization escapes "/" as "\/".
    XCTAssertTrue([reply containsString:@"\"\\/a.txt\""], @"file entry not rooted at the default path: %@", reply);
    XCTAssertTrue([reply containsString:@"\"\\/Sub\\/\""], @"directory entry not rooted at the default path: %@", reply);

    // The process must still be alive and serving.
    NSString *reply2 = SendRawRequest(server.port, @"GET /list?path=/ HTTP/1.1\r\nHost: localhost\r\n\r\n");
    XCTAssertNotNil(reply2, @"server appears to have crashed after the parameterless request");
    XCTAssertTrue(ReplyHasStatus(reply2, 200), @"server did not respond normally afterwards: %@", reply2);

    [server stop];
    [fm removeItemAtPath:dir error:NULL];
}

// The CORS-preflight exemption from authentication must require BOTH "Origin" and
// "Access-Control-Request-Method", as a real browser preflight always sends both.
// Otherwise setting a single header reaches the application's OPTIONS handler with no
// credentials at all.
- (void)testPreflightAuthExemptionRequiresOrigin {
    WSKWebServer *server = [[WSKWebServer alloc] init];
    [server addDefaultHandlerForMethod:@"OPTIONS"
                          requestClass:[WSKRequest class]
                          processBlock:^WSKResponse *(WSKRequest *request) {
                              return [WSKDataResponse responseWithText:@"handler-reached"];
                          }];
    NSDictionary *options = @{
        WSKOption_Port: @0,
        WSKOption_BindToLocalhost: @YES,
        WSKOption_AuthenticationMethod: WSKAuthenticationMethod_Basic,
        WSKOption_AuthenticationAccounts: @{@"user": @"pass"}
    };
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    // A genuine preflight (both headers) is exempt and reaches the handler.
    NSString *preflight = SendRawRequest(server.port, @"OPTIONS / HTTP/1.1\r\nHost: localhost\r\nOrigin: http://example.test\r\nAccess-Control-Request-Method: POST\r\n\r\n");
    XCTAssertTrue([preflight containsString:@"handler-reached"], @"a real CORS preflight must stay exempt from auth, got: %@", preflight);

    // Access-Control-Request-Method alone is not a preflight and must still need auth.
    NSString *forged = SendRawRequest(server.port, @"OPTIONS / HTTP/1.1\r\nHost: localhost\r\nAccess-Control-Request-Method: POST\r\n\r\n");
    XCTAssertTrue(ReplyHasStatus(forged, 401), @"expected 401 without Origin, got: %@", forged);
    XCTAssertFalse([forged containsString:@"handler-reached"], @"the OPTIONS handler ran unauthenticated: %@", forged);

    // A plain OPTIONS request is unaffected and still requires auth.
    NSString *plain = SendRawRequest(server.port, @"OPTIONS / HTTP/1.1\r\nHost: localhost\r\n\r\n");
    XCTAssertTrue(ReplyHasStatus(plain, 401), @"expected 401 for a plain OPTIONS, got: %@", plain);

    [server stop];
}

// The device name is substituted into a JavaScript string literal in index.html, so it
// must be escaped for that context. A name containing a quote would otherwise break the
// literal and a name containing "</script>" would end the script block outright.
- (void)testUploaderIndexEscapesDeviceNameForJavaScript {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dir = MakeTempDirectory();

    WSKWebUploader *server = [[WSKWebUploader alloc] initWithUploadDirectory:dir];
    NSDictionary *options = @{WSKOption_Port: @0, WSKOption_BindToLocalhost: @YES};
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    NSString *page = SendRawRequest(server.port, @"GET / HTTP/1.1\r\nHost: localhost\r\n\r\n");
    XCTAssertNotNil(page);
    XCTAssertTrue(ReplyHasStatus(page, 200), @"index page did not load: %@", page);
    // Whatever this host is called, the assignment must be a syntactically closed literal
    // and must not have left a raw "%device%" placeholder behind.
    XCTAssertTrue([page containsString:@"var _device = \""], @"device name is not emitted as a quoted literal");
    XCTAssertFalse([page containsString:@"%device%"], @"the device placeholder was not substituted");

    [server stop];
    [fm removeItemAtPath:dir error:NULL];
}

// Batch C added realpath([_uploadDirectory fileSystemRepresentation], ...) to the initializer with
// no guard — and -fileSystemRepresentation RAISES for an empty or NUL-bearing receiver. That is
// precisely the class batch A existed to close, re-opened three files from the comment explaining
// it. Fifth recurrence of this codebase's most repeated defect, and the first self-inflicted one.
- (void)testUploaderInitDoesNotRaiseForAnUnusablePath {
    XCTAssertNoThrow([[WSKWebUploader alloc] initWithUploadDirectory:@""]);

    unichar const nulBearing[] = {'/', 't', 'm', 'p', '/', 0, 'x'};
    NSString *nulPath = [NSString stringWithCharacters:nulBearing length:(sizeof(nulBearing) / sizeof(nulBearing[0]))];
    XCTAssertNoThrow([[WSKWebUploader alloc] initWithUploadDirectory:nulPath]);

    // An ordinary share must still resolve, or this could pass by refusing everything.
    NSString *dir = MakeTempDirectory();
    WSKWebUploader *ok = [[WSKWebUploader alloc] initWithUploadDirectory:dir];
    XCTAssertNotNil(ok);
    [[NSFileManager defaultManager] removeItemAtPath:dir error:NULL];
}

- (void)testUploadOntoAFullVolumeIs507NotServerError {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dir = MakeTempDirectory();
    WSKWebUploader *server = [[WSKWebUploader alloc] initWithUploadDirectory:dir];
    NSDictionary *options = @{WSKOption_Port: @0, WSKOption_BindToLocalhost: @YES};
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    Method move = class_getInstanceMethod([NSFileManager class], @selector(moveItemAtPath:toPath:error:));
    gWSKOriginalMoveIMP = method_getImplementation(move);
    method_setImplementation(move, (IMP)(void *)WSKInjectingMove);

    NSString *boundary = @"----wskfulltest";
    NSString *head = [NSString stringWithFormat:
                                   @"--%@\r\nContent-Disposition: form-data; name=\"files[]\"; filename=\"x.bin\"\r\nContent-Type: application/octet-stream\r\n\r\n", boundary];
    NSString *tail = [NSString stringWithFormat:@"\r\n--%@--\r\n", boundary];
    NSString *payload = @"some bytes that cannot land";
    NSString *body = [NSString stringWithFormat:@"%@%@%@", head, payload, tail];
    NSString *request = [NSString stringWithFormat:
                                      @"POST /upload HTTP/1.1\r\nHost: localhost\r\nContent-Type: multipart/form-data; boundary=%@\r\nContent-Length: %lu\r\n\r\n%@",
                                      boundary,
                                      (unsigned long)strlen(body.UTF8String),
                                      body];

    gWSKInjectOutOfSpace = YES;
    NSString *reply = SendRawRequest(server.port, request);
    gWSKInjectOutOfSpace = NO;

    // Restore before any assertion can bail, or a failure leaves the whole suite swizzled.
    method_setImplementation(move, gWSKOriginalMoveIMP);

    XCTAssertTrue([reply hasPrefix:@"HTTP/1.1 507"], @"a full volume must be 507 Insufficient Storage, not a server fault: %@", [reply substringToIndex:MIN((NSUInteger)50, reply.length)]);
    // Nothing may have landed, and the injected failure must not have left the temp behind — the
    // reliability half of the same guarantee.
    XCTAssertEqualObjects([fm contentsOfDirectoryAtPath:dir error:NULL], @[], @"a refused upload left residue in the share");

    // And the endpoint still works once space is available, so the routing change did not break the
    // success path.
    NSString *ok = SendRawRequest(server.port, request);
    XCTAssertTrue([ok hasPrefix:@"HTTP/1.1 200"], @"an ordinary upload must still succeed: %@", [ok substringToIndex:MIN((NSUInteger)50, ok.length)]);

    [server stop];
    [fm removeItemAtPath:dir error:NULL];
}

// -hasPrefix: is REPRESENTATION-dependent, and the hidden-name rule was asked with it. Three
// NSStrings with byte-identical UTF-16 content — "." then U+0301 then a name — answer differently:
// an ordinary __NSCFString says YES, and the NSPathStore2 that -lastPathComponent returns says NO.
// Measured on this OS, not inferred; the default search honours composed character sequences, so
// the dot is read as part of the grapheme cluster the combining mark forms.
//
// /upload asks exactly that question about exactly that string: fileName is
// [file.fileName lastPathComponent]. So a share configured to refuse hidden items accepted a name
// the filesystem then wrote as a real dot-file — invisible to ls, to Finder, and to the uploader's
// own listing, which cannot show it and therefore cannot delete it either. One-way litter, created
// remotely, in a share whose owner has said "no hidden items".
//
// The predicate now reads the first character, which no representation can disagree about.
- (void)testUploadRefusesADotNameHiddenBehindACombiningMark {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dir = MakeTempDirectory();
    WSKWebUploader *server = [[WSKWebUploader alloc] initWithUploadDirectory:dir];
    NSDictionary *options = @{WSKOption_Port: @0, WSKOption_BindToLocalhost: @YES};
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    unichar markedChars[] = {'.', 0x0301, 'u', 'p', '.', 't', 'x', 't'};  // "." + combining acute + "up.txt"
    NSString *marked = [NSString stringWithCharacters:markedChars length:8];

    NSString * (^upload)(NSString *) = ^(NSString *name) {
        NSString *boundary = @"----wskdotmark";
        NSString *body = [NSString stringWithFormat:
                                       @"--%@\r\nContent-Disposition: form-data; name=\"files[]\"; filename=\"%@\"\r\nContent-Type: text/plain\r\n\r\nPAYLOAD\r\n--%@--\r\n", boundary, name, boundary];
        return SendRawRequest(server.port, [NSString stringWithFormat:@"POST /upload HTTP/1.1\r\nHost: localhost\r\nContent-Type: multipart/form-data; boundary=%@\r\nContent-Length: %lu\r\n\r\n%@", boundary, (unsigned long)strlen(body.UTF8String), body]);
    };

    // The control: a plain dot-name is refused, which is the rule this share is running under.
    XCTAssertTrue([upload(@".plain.txt") hasPrefix:@"HTTP/1.1 403"], @"a plain dot-name must be refused");

    NSString *reply = upload(marked);
    XCTAssertTrue([reply hasPrefix:@"HTTP/1.1 403"], @"a dot-name carrying a combining mark must be refused too: %@", [reply substringToIndex:MIN((NSUInteger)50, reply.length)]);

    // What the refusal is FOR: nothing dot-prefixed may appear on disk.
    for (NSString *entry in [fm contentsOfDirectoryAtPath:dir error:NULL]) {
        XCTAssertNotEqual([entry characterAtIndex:0], (unichar)'.', @"a hidden file was created in a share that refuses them: %@", entry);
    }

    // And an ordinary name still uploads, so the tightened predicate refuses nothing it should not.
    XCTAssertTrue([upload(@"ordinary.txt") hasPrefix:@"HTTP/1.1 200"], @"an ordinary upload must still be accepted");
    XCTAssertTrue([fm fileExistsAtPath:[dir stringByAppendingPathComponent:@"ordinary.txt"]]);

    [server stop];
    [fm removeItemAtPath:dir error:NULL];
}

// The other half of the Accept-Ranges gap: /download and /preview honour Range and never said so.
// /download is the endpoint a browser or download manager pulls a multi-hundred-MB build through,
// which is exactly where a client decides whether an interrupted transfer can be resumed.
- (void)testDownloadAndPreviewAdvertiseByteRangeSupport {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dir = MakeTempDirectory();
    XCTAssertTrue([@"0123456789" writeToFile:[dir stringByAppendingPathComponent:@"f.txt"] atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
    XCTAssertTrue([[NSData dataWithBytes:"\x89PNG\r\n\x1a\n" length:8] writeToFile:[dir stringByAppendingPathComponent:@"i.png"] atomically:YES]);

    WSKWebUploader *server = [[WSKWebUploader alloc] initWithUploadDirectory:dir];
    NSDictionary *options = @{WSKOption_Port: @0, WSKOption_BindToLocalhost: @YES};
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    NSString *download = SendRawRequest(server.port, @"GET /download?path=%2Ff.txt HTTP/1.1\r\nHost: localhost\r\n\r\n");
    XCTAssertTrue([download hasPrefix:@"HTTP/1.1 200"], @"%@", [download substringToIndex:MIN((NSUInteger)40, download.length)]);
    XCTAssertTrue([download rangeOfString:@"Accept-Ranges: bytes" options:NSCaseInsensitiveSearch].location != NSNotFound, @"/download must advertise range support: %@", download);
    XCTAssertTrue([download rangeOfString:@"attachment" options:NSCaseInsensitiveSearch].location != NSNotFound, @"…and stay an attachment: %@", download);

    // HEAD, not GET: a PNG body is not valid UTF-8, so SendRawRequest's string decode would return
    // nil and the assertion would read as a failure that has nothing to do with the header.
    NSString *preview = SendRawRequest(server.port, @"HEAD /preview?path=%2Fi.png HTTP/1.1\r\nHost: localhost\r\n\r\n");
    XCTAssertTrue([preview hasPrefix:@"HTTP/1.1 200"], @"%@", [preview substringToIndex:MIN((NSUInteger)40, preview.length)]);
    XCTAssertTrue([preview rangeOfString:@"Accept-Ranges: bytes" options:NSCaseInsensitiveSearch].location != NSNotFound, @"/preview must advertise range support: %@", preview);

    NSString *ranged = SendRawRequest(server.port, @"GET /download?path=%2Ff.txt HTTP/1.1\r\nHost: localhost\r\nRange: bytes=3-5\r\n\r\n");
    XCTAssertTrue([ranged hasPrefix:@"HTTP/1.1 206"], @"%@", [ranged substringToIndex:MIN((NSUInteger)40, ranged.length)]);
    XCTAssertTrue([ranged hasSuffix:@"345"], @"the ranged body must still be the requested bytes: %@", ranged);

    [server stop];
    [fm removeItemAtPath:dir error:NULL];
}

// WSKNormalizeHeaderValue lowercases the part of a header value BEFORE the first ";", leaving
// parameters alone — that is what keeps an uploaded filename's case. The ";" search was not
// literal, so a combining mark straight after each ";" hides every one of them from it, the whole
// value is lowercased instead of just its prefix, and the file lands under a case-mangled name.
// Measured before the fix: filename="MixedFour.TXT" stored as "mixedfour.txt".
//
// This is the one member of the non-literal-search list that reaches client input: multipart PART
// headers are decoded as UTF-8 (WSKMultiPartFormRequest.m), unlike top-level headers, which
// CFHTTPMessage decodes as Latin-1 so no composed sequence can form.
- (void)testUploadPreservesFilenameCaseWhenSemicolonsCarryCombiningMarks {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dir = MakeTempDirectory();

    WSKWebUploader *server = [[WSKWebUploader alloc] initWithUploadDirectory:dir];
    NSDictionary *options = @{WSKOption_Port: @0, WSKOption_BindToLocalhost: @YES};
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    unichar markChars[] = {0x0301};  // combining acute, directly after a ";"
    NSString *mark = [NSString stringWithCharacters:markChars length:1];
    NSString * (^upload)(NSString *) = ^(NSString *disposition) {
        NSString *boundary = @"----wskmark";
        NSString *body = [NSString stringWithFormat:@"--%@\r\n%@\r\nContent-Type: text/plain\r\n\r\nDATA\r\n--%@--\r\n", boundary, disposition, boundary];
        NSString *request = [NSString stringWithFormat:
                                          @"POST /upload HTTP/1.1\r\nHost: localhost:%lu\r\nOrigin: http://localhost:%lu\r\nContent-Type: multipart/form-data; boundary=%@\r\nContent-Length: %lu\r\n\r\n%@",
                                          (unsigned long)server.port,
                                          (unsigned long)server.port,
                                          boundary,
                                          (unsigned long)strlen(body.UTF8String),
                                          body];
        return SendRawRequest(server.port, request);
    };

    // Control: no marks, mixed-case name preserved. This is the property under test, stated twice.
    XCTAssertTrue([upload(@"Content-Disposition: form-data; name=\"files[]\"; filename=\"Plain.TXT\"") hasPrefix:@"HTTP/1.1 200"]);
    XCTAssertTrue([fm fileExistsAtPath:[dir stringByAppendingPathComponent:@"Plain.TXT"]], @"the control upload lost its case");

    NSString *marked = [NSString stringWithFormat:@"Content-Disposition: form-data;%@ name=\"files[]\";%@ filename=\"MixedFour.TXT\"", mark, mark];
    XCTAssertTrue([upload(marked) hasPrefix:@"HTTP/1.1 200"], @"the marked upload must still be accepted");

    // The directory LISTING, never -fileExistsAtPath:. The temp volume is case-insensitive, so
    // fileExistsAtPath: answers YES for "mixedfour.txt" whatever case is actually stored — an
    // oracle that cannot see the defect it is meant to catch.
    NSArray<NSString *> *entries = [fm contentsOfDirectoryAtPath:dir error:NULL];
    XCTAssertTrue([entries containsObject:@"MixedFour.TXT"],
                  @"a combining mark after each \";\" case-mangled the stored name; share holds: %@",
                  entries);

    [server stop];
    [fm removeItemAtPath:dir error:NULL];
}

// The host-settable object properties are read on connection threads while the server runs. They
// were plain nonatomic ivars read directly, so a host app flipping one — a Shape B settings screen
// is the realistic shape — could free an array out from under a listing walking it.
//
// **This test does NOT prove the fix**, and is kept only because nothing else exercises concurrent
// mutation at all: it passes against the unfixed build too. The race would not manifest here —
// roughly a million allow-list walks against forty thousand frees, under MallocScribble and then
// under guard malloc, never faulted, because a freed pointer that is merely read usually reads
// fine. What DOES prove it is the shipped Release disassembly: the read was
//     movq  (%rdi,%rdx), %rdx      ; bare ivar load
//     jmp   _WSKEntryPassesExtensionAllowList
// with no retain anywhere, tail-calling into a walk over an array another thread can free. After
// the change the same method calls objc_getProperty/objc_retain (0 → 5 such calls). Verify any
// future change the same way, not by waiting for a crash that may never come.
- (void)testHostSettablePropertiesSurviveMutationWhileServing {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dir = MakeTempDirectory();
    for (NSUInteger i = 0; i < 120; i++) {
        NSString *name = [NSString stringWithFormat:@"f%03lu.txt", (unsigned long)i];
        [@"x" writeToFile:[dir stringByAppendingPathComponent:name] atomically:NO encoding:NSUTF8StringEncoding error:NULL];
        NSString *other = [NSString stringWithFormat:@"g%03lu.bin", (unsigned long)i];
        [@"y" writeToFile:[dir stringByAppendingPathComponent:other] atomically:NO encoding:NSUTF8StringEncoding error:NULL];
    }

    WSKWebUploader *server = [[WSKWebUploader alloc] initWithUploadDirectory:dir];
    server.allowedFileExtensions = @[@"txt"];
    NSDictionary *options = @{WSKOption_Port: @0, WSKOption_BindToLocalhost: @YES};
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    __block BOOL finished = NO;
    NSLock *const lock = [[NSLock alloc] init];
    BOOL (^done)(void) = ^{
        [lock lock];
        BOOL const value = finished;
        [lock unlock];
        return value;
    };

    // The host app, changing its mind as fast as it can.
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        for (NSUInteger i = 0; !done(); i++) {
            @autoreleasepool {
                // Large lists, so the walk a reader is inside lasts long enough for the swap to land
                // in the middle of it. With three-element arrays the window is a few microseconds
                // and thousands of listings never caught it.
                NSMutableArray *list = [NSMutableArray arrayWithCapacity:4000];
                [list addObject:@"txt"];
                for (NSUInteger k = 0; k < 4000; k++) {
                    [list addObject:[NSString stringWithFormat:@"e%lu-%lu", (unsigned long)i, (unsigned long)k]];
                }
                server.allowedFileExtensions = list;
                server.allowHiddenItems = ((i % 3) == 0);
                server.title = [NSString stringWithFormat:@"share-%lu", (unsigned long)i];
                server.footer = [NSString stringWithFormat:@"footer-%lu", (unsigned long)i];
            }
        }
    });

    // Eight clients listing the share, which is what walks the allow-list.
    dispatch_group_t const group = dispatch_group_create();
    __block NSUInteger listings = 0;
    for (NSUInteger i = 0; i < 8; i++) {
        dispatch_group_async(group, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            while (!done()) {
                @autoreleasepool {
                    NSString *reply = SendRawRequest(server.port, @"GET /list?path=%2F HTTP/1.1\r\nHost: localhost\r\n\r\n");
                    if (reply.length > 0) {
                        [lock lock];
                        listings += 1;
                        [lock unlock];
                    }
                }
            }
        });
    }

    [NSThread sleepForTimeInterval:3.0];
    [lock lock];
    finished = YES;
    [lock unlock];
    dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20 * NSEC_PER_SEC)));

    [server stop];
    [fm removeItemAtPath:dir error:NULL];

    XCTAssertGreaterThan(listings, (NSUInteger)100, @"only %lu listings completed, so the race was barely exercised", (unsigned long)listings);
}

@end
