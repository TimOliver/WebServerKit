#import "WSKResumableUploadStore.h"

#import <CommonCrypto/CommonDigest.h>
#include <fcntl.h>
#include <math.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>

#import "WSKFunctions.h"
#import "WSKPrivate.h"

static const unsigned long long WSKResumeChunkLimit = 1024ULL * 1024;
static const unsigned long long WSKResumeFileLimit = 8ULL * 1024 * 1024 * 1024;
static const unsigned long long WSKResumeAggregateLimit = 32ULL * 1024 * 1024 * 1024;
static const NSUInteger WSKResumeActiveLimit = 32;
static const NSUInteger WSKResumeReceiptLimit = 128;

static NSNumber *WSKResumeNumber(NSDictionary *dictionary, NSString *key) {
    NSNumber *const value = dictionary[key];
    return [value isKindOfClass:NSNumber.class] ? value : nil;
}

static NSString *WSKResumeString(NSDictionary *dictionary, NSString *key) {
    NSString *const value = dictionary[key];
    return [value isKindOfClass:NSString.class] ? value : nil;
}

static NSDictionary *WSKResumeDictionary(NSDictionary *dictionary, NSString *key) {
    NSDictionary *const value = dictionary[key];
    return [value isKindOfClass:NSDictionary.class] ? value : nil;
}

// Resolve existing ancestors before creating anything. A configured store may
// have a missing suffix, but a symlink in its parent must never redirect private
// upload state into the served directory.
static NSString *WSKResumeCanonicalFuturePath(NSString *path) {
    if (![path isAbsolutePath] || WSKPathContainsNULByte(path) || [path lengthOfBytesUsingEncoding:NSUTF8StringEncoding] >= PATH_MAX) {
        return nil;
    }
    NSString *cursor = path.stringByStandardizingPath;
    NSMutableArray<NSString *> *const suffix = [NSMutableArray array];
    char resolved[PATH_MAX];
    while (realpath(cursor.fileSystemRepresentation, resolved) == NULL) {
        if (errno != ENOENT || [cursor isEqualToString:@"/"] || cursor.length == 0) {
            return nil;
        }
        [suffix addObject:cursor.lastPathComponent];
        cursor = cursor.stringByDeletingLastPathComponent;
    }
    NSString *result = [[NSFileManager defaultManager] stringWithFileSystemRepresentation:resolved length:strlen(resolved)];
    for (NSString *component in suffix.reverseObjectEnumerator) {
        result = [result stringByAppendingPathComponent:component];
    }
    return result;
}

static NSString *WSKResumeHeader(WSKRequest *request, NSString *name) {
    for (NSString *key in request.headers) {
        if ([key caseInsensitiveCompare:name] == NSOrderedSame) {
            return request.headers[key];
        }
    }
    return nil;
}

static BOOL WSKResumeDecimal(NSString *value, unsigned long long *result) {
    if (![value isKindOfClass:[NSString class]] || value.length == 0 || value.length > 20) {
        return NO;
    }
    unsigned long long number = 0;
    for (NSUInteger index = 0; index < value.length; ++index) {
        unichar const c = [value characterAtIndex:index];
        if (c < '0' || c > '9' || number > (ULLONG_MAX - (c - '0')) / 10) {
            return NO;
        }
        number = number * 10 + (c - '0');
    }
    *result = number;
    return YES;
}

static NSString *WSKResumeUUID(NSString *value) {
    if (![value isKindOfClass:[NSString class]] || value.length != 36) {
        return nil;
    }
    NSUUID *const uuid = [[NSUUID alloc] initWithUUIDString:value];
    NSString *const canonical = uuid.UUIDString.lowercaseString;
    return [canonical isEqualToString:value.lowercaseString] ? canonical : nil;
}

static BOOL WSKResumeWrite(int file, const void *bytes, size_t length, NSError **error) {
    const uint8_t *cursor = bytes;
    while (length) {
        ssize_t const written = write(file, cursor, length);
        if (written < 0 && errno == EINTR) {
            continue;
        }
        if (written <= 0) {
            if (error) {
                *error = WSKMakePosixError(written < 0 ? errno : EIO);
            }
            return NO;
        }
        cursor += written;
        length -= (size_t)written;
    }
    return YES;
}

static BOOL WSKResumeClose(int file, NSError **error) {
    if (close(file) == 0) {
        return YES;
    }
    if (error) {
        *error = WSKMakePosixError(errno);
    }
    return NO;
}

static WSKResponse *WSKResumeResponse(NSInteger status) {
    WSKResponse *const response = [WSKResponse responseWithStatusCode:status];
    [response setValue:@"1.0.0" forAdditionalHeader:@"Tus-Resumable"];
    [response setValue:@"no-store" forAdditionalHeader:@"Cache-Control"];
    return response;
}

static WSKResponse *WSKResumeError(NSError *error) {
    return WSKResumeResponse(WSKServerErrorStatusCodeForError(error));
}

// Unreadable storage is not evidence that an upload has gone away. In
// particular, iOS complete-protection files temporarily fail with EACCES while
// locked. Only a missing or structurally invalid manifest is disposable.
static BOOL WSKResumeManifestIsInvalid(NSError *error) {
    return [error.domain isEqualToString:NSPOSIXErrorDomain] &&
           (error.code == ENOENT || error.code == ENOTDIR || error.code == EINVAL || error.code == ELOOP);
}

@implementation WSKResumableFileRequest {
    NSUInteger _receivedResumeBytes;
}
- (BOOL)open:(NSError **)error {
    if (self.contentLength != NSUIntegerMax && self.contentLength > WSKResumeChunkLimit) {
        if (error) {
            *error = [NSError errorWithDomain:kWSKErrorDomain code:kWSKRequestBodyError_TooLarge userInfo:nil];
        }
        return NO;
    }
    return [super open:error];
}
- (BOOL)writeData:(NSData *)data error:(NSError **)error {
    if (data.length > WSKResumeChunkLimit - _receivedResumeBytes) {
        if (error) {
            *error = [NSError errorWithDomain:kWSKErrorDomain code:kWSKRequestBodyError_TooLarge userInfo:nil];
        }
        return NO;
    }
    if (![super writeData:data error:error]) {
        return NO;
    }
    _receivedResumeBytes += data.length;
    return YES;
}
@end

@implementation WSKResumableUploadStore {
    NSString *_directory;
    NSString *_uploadDirectory;
    NSDictionary *_binding;
    NSTimeInterval _expirationInterval;
}

- (instancetype)initWithDirectory:(NSString *)directory uploadDirectory:(NSString *)uploadDirectory expirationInterval:(NSTimeInterval)expirationInterval {
    if ((self = [super init])) {
        _directory = [WSKResumeCanonicalFuturePath(directory) copy];
        _uploadDirectory = [WSKResumeCanonicalFuturePath(uploadDirectory) copy];
        _expirationInterval = isfinite(expirationInterval) && expirationInterval > 0 ? expirationInterval : 24 * 60 * 60;
        struct stat info;
        if (_uploadDirectory.length && !WSKPathContainsNULByte(_uploadDirectory) && lstat(_uploadDirectory.fileSystemRepresentation, &info) == 0 && S_ISDIR(info.st_mode)) {
            _binding = @{@"path": _uploadDirectory, @"device": @((unsigned long long)info.st_dev), @"inode": @((unsigned long long)info.st_ino)};
        }
    }
    return self;
}

- (NSString *)_sessionPath:(NSString *)identifier {
    return [_directory stringByAppendingPathComponent:identifier];
}

- (BOOL)_boundRootIsCurrent {
    struct stat info;
    return _binding && lstat(_uploadDirectory.fileSystemRepresentation, &info) == 0 && S_ISDIR(info.st_mode) && (unsigned long long)info.st_dev == WSKResumeNumber(_binding, @"device").unsignedLongLongValue && (unsigned long long)info.st_ino == WSKResumeNumber(_binding, @"inode").unsignedLongLongValue;
}

- (int)_lockDirectory:(int)operation create:(BOOL)create error:(NSError **)error {
    NSString *const canonical = WSKResumeCanonicalFuturePath(_directory);
    if (!_binding || !canonical || ![canonical isEqualToString:_directory] || WSKPathIsInsideDirectory(canonical, _uploadDirectory) || [canonical isEqualToString:_uploadDirectory]) {
        if (error) {
            *error = WSKMakePosixError(EINVAL);
        }
        return -1;
    }
    if (![self _boundRootIsCurrent]) {
        if (error) {
            *error = WSKMakePosixError(ESTALE);
        }
        return -1;
    }
    if (create && ![[NSFileManager defaultManager] createDirectoryAtPath:_directory withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions: @0700} error:error]) {
        return -1;
    }
    struct stat info;
    if (lstat(_directory.fileSystemRepresentation, &info) < 0 || !S_ISDIR(info.st_mode)) {
        if (error) {
            *error = WSKMakePosixError(errno ? errno : EINVAL);
        }
        return -1;
    }
    NSString *const lockPath = [_directory stringByAppendingPathComponent:@".lock"];
    int const file = open(lockPath.fileSystemRepresentation, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (file < 0) {
        if (error) {
            *error = WSKMakePosixError(errno);
        }
        return -1;
    }
    if (fstat(file, &info) < 0 || !S_ISREG(info.st_mode)) {
        int const code = errno ? errno : EINVAL;
        close(file);
        if (error) {
            *error = WSKMakePosixError(code);
        }
        return -1;
    }
    while (flock(file, operation) < 0) {
        if (errno == EINTR) {
            continue;
        }
        int const code = errno;
        close(file);
        if (error) {
            *error = WSKMakePosixError(code);
        }
        return -1;
    }
    return file;
}

- (int)_lockSession:(NSString *)path error:(NSError **)error {
    struct stat info;
    if (lstat(path.fileSystemRepresentation, &info) < 0 || !S_ISDIR(info.st_mode)) {
        if (error) {
            *error = WSKMakePosixError(errno ? errno : EINVAL);
        }
        return -1;
    }
    int const file = open([path stringByAppendingPathComponent:@".lock"].fileSystemRepresentation, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (file < 0) {
        if (error) {
            *error = WSKMakePosixError(errno);
        }
        return -1;
    }
    while (flock(file, LOCK_EX) < 0) {
        if (errno == EINTR) {
            continue;
        }
        int const code = errno;
        close(file);
        if (error) {
            *error = WSKMakePosixError(code);
        }
        return -1;
    }
    return file;
}

- (BOOL)_save:(NSDictionary *)manifest at:(NSString *)path error:(NSError **)error {
    NSData *const data = [NSJSONSerialization dataWithJSONObject:manifest options:0 error:error];
    if (!data) {
        return NO;
    }
    NSString *const temporary = [path stringByAppendingPathComponent:[@".manifest-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    int const file = open(temporary.fileSystemRepresentation, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (file < 0) {
        if (error) {
            *error = WSKMakePosixError(errno);
        }
        return NO;
    }
    BOOL success = WSKResumeWrite(file, data.bytes, data.length, error);
    if (success && fsync(file) < 0) {
        if (error) {
            *error = WSKMakePosixError(errno);
        }
        success = NO;
    }
    if (!WSKResumeClose(file, success ? error : NULL)) {
        success = NO;
    }
    if (success && rename(temporary.fileSystemRepresentation, [path stringByAppendingPathComponent:@"manifest.json"].fileSystemRepresentation) < 0) {
        if (error) {
            *error = WSKMakePosixError(errno);
        }
        success = NO;
    }
    if (!success) {
        unlink(temporary.fileSystemRepresentation);
    }
    return success;
}

- (NSDictionary *)_metadata:(NSString *)header {
    if (![header isKindOfClass:[NSString class]] || header.length > 16384) {
        return nil;
    }
    NSMutableDictionary<NSString *, NSString *> *const result = [NSMutableDictionary dictionary];
    for (NSString *part in [header componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@","]]) {
        NSString *const trimmed = [part stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        NSRange const separator = [trimmed rangeOfString:@" " options:NSLiteralSearch];
        if (separator.location == NSNotFound || separator.location == 0) {
            return nil;
        }
        NSString *const key = [trimmed substringToIndex:separator.location];
        NSString *const encoded = [trimmed substringFromIndex:separator.location + 1];
        if (result[key] || ![@[@"filename", @"path", @"sha256"] containsObject:key]) {
            return nil;
        }
        NSData *const bytes = [[NSData alloc] initWithBase64EncodedString:encoded options:0];
        NSString *const value = bytes ? [[NSString alloc] initWithData:bytes encoding:NSUTF8StringEncoding] : nil;
        if (!value || WSKPathContainsNULByte(value) || value.length > 4096) {
            return nil;
        }
        result[key] = value;
    }
    NSString *const hash = result[@"sha256"];
    if (result.count != 3 || [result[@"filename"] length] == 0 || [result[@"path"] length] == 0 || hash.length != 64) {
        return nil;
    }
    for (NSUInteger index = 0; index < hash.length; ++index) {
        unichar const c = [hash characterAtIndex:index];
        if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) {
            return nil;
        }
    }
    return result;
}

- (NSMutableDictionary *)_load:(NSString *)path error:(NSError **)error {
    NSString *const manifestPath = [path stringByAppendingPathComponent:@"manifest.json"];
    int const file = open(manifestPath.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (file < 0) {
        if (error) {
            *error = WSKMakePosixError(errno);
        }
        return nil;
    }
    struct stat info;
    int const observed = fstat(file, &info);
    if (observed < 0 || !S_ISREG(info.st_mode) || info.st_size <= 0 || info.st_size > 32768) {
        int const code = observed < 0 ? errno : EINVAL;
        close(file);
        if (error) {
            *error = WSKMakePosixError(code);
        }
        return nil;
    }
    NSMutableData *const bytes = [NSMutableData dataWithLength:(NSUInteger)info.st_size];
    NSUInteger received = 0;
    while (received < bytes.length) {
        ssize_t const count = read(file, (uint8_t *)bytes.mutableBytes + received, bytes.length - received);
        if (count < 0 && errno == EINTR) {
            continue;
        }
        if (count <= 0) {
            int const code = count < 0 ? errno : EIO;
            close(file);
            if (error) {
                *error = WSKMakePosixError(code);
            }
            return nil;
        }
        received += (NSUInteger)count;
    }
    close(file);
    NSObject *const object = [NSJSONSerialization JSONObjectWithData:bytes options:NSJSONReadingMutableContainers error:NULL];
    if (![object isKindOfClass:[NSMutableDictionary class]]) {
        if (error) {
            *error = WSKMakePosixError(EINVAL);
        }
        return nil;
    }
    NSMutableDictionary *const manifest = (NSMutableDictionary *)object;
    NSNumber *const length = manifest[@"length"];
    NSNumber *const offset = manifest[@"offset"];
    NSNumber *const expires = manifest[@"expires"];
    NSString *const state = manifest[@"state"];
    NSDictionary *const metadata = [self _metadata:manifest[@"metadataHeader"]];
    if (![length isKindOfClass:NSNumber.class] || ![offset isKindOfClass:NSNumber.class] || ![expires isKindOfClass:NSNumber.class] || !isfinite(expires.doubleValue) || length.longLongValue < 0 || offset.longLongValue < 0 || length.unsignedLongLongValue > WSKResumeFileLimit || offset.unsignedLongLongValue > length.unsignedLongLongValue || ![@[@"active", @"publishing", @"complete"] containsObject:state] || ![WSKResumeDictionary(manifest, @"binding") isEqual:_binding] || !metadata || ![metadata isEqual:manifest[@"metadata"]]) {
        if (error) {
            *error = WSKMakePosixError(EINVAL);
        }
        return nil;
    }
    if ([state isEqualToString:@"complete"] && ![length isEqual:offset]) {
        if (error) {
            *error = WSKMakePosixError(EINVAL);
        }
        return nil;
    }
    return manifest;
}

- (BOOL)_validJournal:(NSDictionary *)journal {
    if (![self _boundRootIsCurrent] || ![journal isKindOfClass:NSDictionary.class]) {
        return NO;
    }
    NSString *const finalPath = journal[@"finalPath"];
    NSString *const stagePath = journal[@"stagingPath"];
    if (![finalPath isKindOfClass:NSString.class] || ![stagePath isKindOfClass:NSString.class] || ![finalPath isAbsolutePath] || ![stagePath isAbsolutePath] || WSKPathContainsNULByte(finalPath) || WSKPathContainsNULByte(stagePath) || !WSKResumeNumber(journal, @"device") || !WSKResumeNumber(journal, @"inode")) {
        return NO;
    }
    NSString *const resolved = WSKResolveNamedEntryWithinDirectory(finalPath, _uploadDirectory, NULL);
    return resolved && [resolved isEqualToString:finalPath] && WSKPathIsInsideDirectory(finalPath, _uploadDirectory) && !WSKPathIsInsideDirectory(stagePath, _uploadDirectory) && ![stagePath isEqualToString:_uploadDirectory];
}

- (int)_statPath:(NSString *)path result:(struct stat *)info {
    return lstat(path.fileSystemRepresentation, info);
}

- (BOOL)_file:(NSString *)path matchesJournal:(NSDictionary *)journal length:(NSNumber *)length error:(NSError **)error {
    struct stat info;
    if ([self _statPath:path result:&info] < 0) {
        int const code = errno;
        // Inability to inspect the published file is not proof that the rename
        // did not happen. Retain the publishing journal until storage is readable.
        if (error && code != ENOENT && code != ENOTDIR) {
            *error = WSKMakePosixError(code);
        }
        return NO;
    }
    if (!S_ISREG(info.st_mode) || (unsigned long long)info.st_dev != WSKResumeNumber(journal, @"device").unsignedLongLongValue || (unsigned long long)info.st_ino != WSKResumeNumber(journal, @"inode").unsignedLongLongValue) {
        return NO;
    }
    return !length || (info.st_size >= 0 && (unsigned long long)info.st_size == length.unsignedLongLongValue);
}

- (BOOL)_removeJournalStage:(NSDictionary *)journal error:(NSError **)error {
    if (!journal) {
        return YES;
    }
    if (![self _validJournal:journal]) {
        if (error) {
            *error = WSKMakePosixError(EINVAL);
        }
        return NO;
    }
    NSString *const stage = journal[@"stagingPath"];
    struct stat info;
    if (lstat(stage.fileSystemRepresentation, &info) < 0) {
        int const code = errno;
        if (code == ENOENT || code == ENOTDIR) {
            return YES;
        }
        if (error) {
            *error = WSKMakePosixError(code);
        }
        return NO;
    }
    if (!S_ISREG(info.st_mode) || (unsigned long long)info.st_dev != WSKResumeNumber(journal, @"device").unsignedLongLongValue || (unsigned long long)info.st_ino != WSKResumeNumber(journal, @"inode").unsignedLongLongValue) {
        return YES;  // A different file at this name is never ours to remove.
    }
    if (unlink(stage.fileSystemRepresentation) < 0 && errno != ENOENT) {
        if (error) {
            *error = WSKMakePosixError(errno);
        }
        return NO;
    }
    return YES;
}

- (BOOL)_removeEmptyJournalDirectory:(NSDictionary *)journal error:(NSError **)error {
    if (!journal) {
        return YES;
    }
    if (![self _validJournal:journal]) {
        if (error) {
            *error = WSKMakePosixError(EINVAL);
        }
        return NO;
    }
    NSString *const stage = journal[@"stagingPath"];
    NSString *const parent = stage.stringByDeletingLastPathComponent;
    // Foundation owns this uniquely-created replacement directory. Only remove
    // it if empty; never recursively delete anything outside our session store.
    if ([parent.lastPathComponent hasPrefix:@"NSIRD_"] && [stage.lastPathComponent hasPrefix:@"wsk-upload-"]) {
        if (rmdir(parent.fileSystemRepresentation) < 0) {
            int const code = errno;
            if (code != ENOENT && code != ENOTDIR && code != ENOTEMPTY && code != EEXIST) {
                if (error) {
                    *error = WSKMakePosixError(code);
                }
                return NO;
            }
        }
    }
    return YES;
}

- (BOOL)_truncatePayload:(NSString *)path offset:(unsigned long long)offset error:(NSError **)error {
    int const file = open([path stringByAppendingPathComponent:@"payload"].fileSystemRepresentation, O_RDWR | O_NOFOLLOW | O_CLOEXEC);
    if (file < 0) {
        if (error) {
            *error = WSKMakePosixError(errno);
        }
        return NO;
    }
    struct stat info;
    BOOL success = fstat(file, &info) == 0 && S_ISREG(info.st_mode) && info.st_size >= 0 && (unsigned long long)info.st_size >= offset;
    if (!success) {
        if (error) {
            *error = WSKMakePosixError(EIO);
        }
    } else if ((unsigned long long)info.st_size != offset && (ftruncate(file, (off_t)offset) < 0 || fsync(file) < 0)) {
        if (error) {
            *error = WSKMakePosixError(errno);
        }
        success = NO;
    }
    if (!WSKResumeClose(file, success ? error : NULL)) {
        success = NO;
    }
    return success;
}

- (BOOL)_removeUnjournaledStages:(NSString *)path manifest:(NSDictionary *)manifest error:(NSError **)error {
    NSArray *const names = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:path error:error];
    if (!names) {
        return NO;
    }
    NSString *const recorded = WSKResumeString(WSKResumeDictionary(manifest, @"journal"), @"stagingPath");
    for (NSString *name in names) {
        if (![name hasPrefix:@".stage-"] || !WSKResumeUUID([name substringFromIndex:7])) {
            continue;
        }
        NSString *const stage = [path stringByAppendingPathComponent:name];
        if ([stage isEqualToString:recorded]) {
            continue;  // The journal's device/inode checks govern this file.
        }
        // Only this private session's reserved namespace is ours. Never follow a
        // symlink or walk a directory, including one placed here by the host app.
        struct stat info;
        if (lstat(stage.fileSystemRepresentation, &info) != 0) {
            if (errno == ENOENT) {
                continue;
            }
            if (error) *error = WSKMakePosixError(errno);
            return NO;
        }
        if (S_ISREG(info.st_mode) && unlink(stage.fileSystemRepresentation) != 0 && errno != ENOENT) {
            if (error) *error = WSKMakePosixError(errno);
            return NO;
        }
    }
    return YES;
}

- (BOOL)_recover:(NSMutableDictionary *)manifest at:(NSString *)path error:(NSError **)error {
    if (![self _removeUnjournaledStages:path manifest:manifest error:error]) {
        return NO;
    }
    for (NSString *name in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:path error:NULL]) {
        if ([name hasPrefix:@".manifest-"] && WSKResumeUUID([name substringFromIndex:10])) {
            unlink([path stringByAppendingPathComponent:name].fileSystemRepresentation);
        }
    }
    NSString *const state = manifest[@"state"];
    if ([state isEqualToString:@"complete"]) {
        unlink([path stringByAppendingPathComponent:@"payload"].fileSystemRepresentation);
        return YES;
    }
    if ([state isEqualToString:@"publishing"]) {
        NSDictionary *const journal = manifest[@"journal"];
        if (![self _validJournal:journal]) {
            if (error) {
                *error = WSKMakePosixError(EINVAL);
            }
            return NO;
        }
        NSError *inspectionError = nil;
        BOOL const published = [self _file:journal[@"finalPath"] matchesJournal:journal length:manifest[@"length"] error:&inspectionError];
        if (inspectionError) {
            if (error) *error = inspectionError;
            return NO;
        }
        if (published) {
            manifest[@"state"] = @"complete";
            manifest[@"offset"] = manifest[@"length"];
            manifest[@"expires"] = @(NSDate.date.timeIntervalSince1970 + _expirationInterval);
            if (![self _save:manifest at:path error:error]) {
                return NO;
            }
            unlink([path stringByAppendingPathComponent:@"payload"].fileSystemRepresentation);
            [self _removeEmptyJournalDirectory:journal error:NULL];
            return YES;
        }
        if (![self _removeJournalStage:journal error:error] || ![self _removeEmptyJournalDirectory:journal error:error]) {
            return NO;
        }
        manifest[@"state"] = @"active";
        [manifest removeObjectForKey:@"journal"];
        if (![self _truncatePayload:path offset:WSKResumeNumber(manifest, @"offset").unsignedLongLongValue error:error]) {
            return NO;
        }
        return [self _save:manifest at:path error:error];
    }
    return [self _truncatePayload:path offset:WSKResumeNumber(manifest, @"offset").unsignedLongLongValue error:error];
}

- (BOOL)_removeSession:(NSString *)path manifest:(NSDictionary *)manifest error:(NSError **)error {
    if (![self _removeJournalStage:manifest[@"journal"] error:error] || ![self _removeEmptyJournalDirectory:manifest[@"journal"] error:error]) {
        return NO;
    }
    // Session directories are private and contain only files produced here. The
    // file manager removes a symlink itself rather than following it recursively.
    return [[NSFileManager defaultManager] removeItemAtPath:path error:error];
}

- (void)_cleanupLocked {
    NSTimeInterval const now = NSDate.date.timeIntervalSince1970;
    NSMutableArray *const receipts = [NSMutableArray array];
    for (NSString *name in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:_directory error:NULL]) {
        if (![WSKResumeUUID(name) isEqualToString:name]) {
            continue;
        }
        NSString *const path = [self _sessionPath:name];
        NSError *error = nil;
        NSMutableDictionary *const manifest = [self _load:path error:&error];
        if (manifest && ![self _removeUnjournaledStages:path manifest:manifest error:&error]) {
            continue;
        }
        if (manifest && WSKResumeNumber(manifest, @"expires").doubleValue <= now) {
            [self _removeSession:path manifest:manifest error:NULL];
        } else if ([WSKResumeString(manifest, @"state") isEqualToString:@"complete"]) {
            [receipts addObject:@{@"path": path, @"manifest": manifest}];
        } else if (!manifest && WSKResumeManifestIsInvalid(error)) {
            struct stat info;
            if (lstat(path.fileSystemRepresentation, &info) == 0 && S_ISDIR(info.st_mode) && now - info.st_mtime >= _expirationInterval) {
                [self _removeSession:path manifest:nil error:NULL];
            }
        }
    }
    [receipts sortUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
        NSTimeInterval const leftExpiry = WSKResumeNumber(WSKResumeDictionary(left, @"manifest"), @"expires").doubleValue;
        NSTimeInterval const rightExpiry = WSKResumeNumber(WSKResumeDictionary(right, @"manifest"), @"expires").doubleValue;
        return leftExpiry < rightExpiry ? NSOrderedAscending : (leftExpiry > rightExpiry ? NSOrderedDescending : NSOrderedSame);
    }];
    while (receipts.count > WSKResumeReceiptLimit) {
        NSDictionary *const oldest = receipts.firstObject;
        [self _removeSession:oldest[@"path"] manifest:oldest[@"manifest"] error:NULL];
        [receipts removeObjectAtIndex:0];
    }
}

- (void)cleanupExpiredUploads {
    int const lock = [self _lockDirectory:LOCK_EX | LOCK_NB create:NO error:NULL];
    if (lock < 0) {
        return;
    }
    [self _cleanupLocked];
    close(lock);
}

- (WSKResponse *)_response:(NSInteger)status manifest:(NSDictionary *)manifest identifier:(NSString *)identifier {
    WSKResponse *const response = WSKResumeResponse(status);
    [response setValue:WSKResumeNumber(manifest, @"offset").stringValue forAdditionalHeader:@"Upload-Offset"];
    [response setValue:WSKResumeNumber(manifest, @"length").stringValue forAdditionalHeader:@"Upload-Length"];
    [response setValue:manifest[@"metadataHeader"] forAdditionalHeader:@"Upload-Metadata"];
    [response setValue:WSKFormatRFC822([NSDate dateWithTimeIntervalSince1970:WSKResumeNumber(manifest, @"expires").doubleValue]) forAdditionalHeader:@"Upload-Expires"];
    if (status == 201) {
        [response setValue:[@"/uploads/" stringByAppendingString:identifier] forAdditionalHeader:@"Location"];
    }
    return response;
}

- (NSString *)_digest:(NSString *)path error:(NSError **)error {
    int const file = open(path.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (file < 0) {
        if (error) {
            *error = WSKMakePosixError(errno);
        }
        return nil;
    }
    CC_SHA256_CTX context;
    CC_SHA256_Init(&context);
    uint8_t buffer[65536];
    BOOL success = YES;
    while (YES) {
        ssize_t const count = read(file, buffer, sizeof(buffer));
        if (count < 0 && errno == EINTR) {
            continue;
        }
        if (count < 0) {
            if (error) {
                *error = WSKMakePosixError(errno);
            }
            success = NO;
            break;
        }
        if (count == 0) {
            break;
        }
        CC_SHA256_Update(&context, buffer, (CC_LONG)count);
    }
    if (!WSKResumeClose(file, success ? error : NULL)) {
        success = NO;
    }
    if (!success) {
        return nil;
    }
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(digest, &context);
    NSMutableString *const result = [NSMutableString stringWithCapacity:64];
    for (NSUInteger index = 0; index < sizeof(digest); ++index) {
        [result appendFormat:@"%02x", digest[index]];
    }
    return result;
}

- (WSKResponse *)_publish:(NSMutableDictionary *)manifest at:(NSString *)path validate:(WSKResumableUploadValidationBlock)validate publish:(WSKResumableUploadPublicationBlock)publish {
    NSString *const payload = [path stringByAppendingPathComponent:@"payload"];
    NSDictionary<NSString *, NSString *> *const metadata = WSKResumeDictionary(manifest, @"metadata");
    NSString *const expectedDigest = metadata[@"sha256"];
    if (!metadata || !expectedDigest) {
        return WSKResumeResponse(500);
    }
    NSError *error = nil;
    NSString *const digest = [self _digest:payload error:&error];
    if (!digest) {
        [self _truncatePayload:path offset:WSKResumeNumber(manifest, @"offset").unsignedLongLongValue error:NULL];
        return WSKResumeError(error);
    }
    if (![digest isEqualToString:expectedDigest]) {
        [self _truncatePayload:path offset:WSKResumeNumber(manifest, @"offset").unsignedLongLongValue error:NULL];
        return WSKResumeResponse(422);
    }
    WSKResponse *const rejected = validate(metadata);
    if (rejected) {
        [self _truncatePayload:path offset:WSKResumeNumber(manifest, @"offset").unsignedLongLongValue error:NULL];
        return rejected;
    }
    __block BOOL journalWritten = NO;
    WSKResponse *const publicationError = publish(payload, metadata, ^BOOL(NSString *finalPath, NSString *stagingPath, unsigned long long device, unsigned long long inode, NSError **journalError) {
        NSDictionary *const journal = @{@"finalPath": finalPath,
                                        @"stagingPath": stagingPath,
                                        @"device": @(device),
                                        @"inode": @(inode)};
        if (journalWritten || ![self _validJournal:journal] || ![self _file:stagingPath matchesJournal:journal length:nil error:NULL]) {
            if (journalError) {
                *journalError = WSKMakePosixError(EINVAL);
            }
            return NO;
        }
        NSMutableDictionary *const pending = [manifest mutableCopy];
        pending[@"state"] = @"publishing";
        pending[@"journal"] = journal;
        if (![self _save:pending at:path error:journalError]) {
            return NO;
        }
        [manifest setDictionary:pending];
        journalWritten = YES;
        return YES;
    });
    if (!publicationError && journalWritten) {
        // The publisher's successful rename is authoritative. A delegate or a DAV
        // client may immediately move the published file, so checking its old path
        // again must not turn a completed upload back into an active session.
        manifest[@"state"] = @"complete";
        manifest[@"offset"] = manifest[@"length"];
        manifest[@"expires"] = @(NSDate.date.timeIntervalSince1970 + _expirationInterval);
        if (![self _save:manifest at:path error:&error]) {
            return WSKResumeError(error);
        }
        unlink(payload.fileSystemRepresentation);
        [self _removeEmptyJournalDirectory:manifest[@"journal"] error:NULL];
        return nil;
    }
    if (![self _recover:manifest at:path error:&error]) {
        return WSKResumeError(error);
    }
    if ([WSKResumeString(manifest, @"state") isEqualToString:@"complete"]) {
        // Recovery recognized the renamed inode despite a later publication error.
        return nil;
    }
    return publicationError ? publicationError : WSKResumeResponse(500);
}

- (WSKResponse *)_create:(WSKRequest *)request identifier:(NSString *)identifier validate:(WSKResumableUploadValidationBlock)validate publish:(WSKResumableUploadPublicationBlock)publish {
    unsigned long long length = 0;
    NSString *const metadataHeader = WSKResumeHeader(request, @"Upload-Metadata");
    NSDictionary *const metadata = [self _metadata:metadataHeader];
    if (!WSKResumeDecimal(WSKResumeHeader(request, @"Upload-Length"), &length) || !metadata || WSKResumeHeader(request, @"Upload-Defer-Length") || WSKResumeHeader(request, @"Upload-Concat")) {
        return WSKResumeResponse(400);
    }
    if (length > WSKResumeFileLimit) {
        return WSKResumeResponse(413);
    }
    if (request.usesChunkedTransferEncoding || (request.contentLength != NSUIntegerMax && request.contentLength != 0)) {
        return WSKResumeResponse(400);
    }
    WSKResponse *const rejected = validate(metadata);
    if (rejected) {
        return rejected;
    }
    NSString *const path = [self _sessionPath:identifier];
    NSError *error = nil;
    struct stat existing;
    if (lstat(path.fileSystemRepresentation, &existing) == 0) {
        NSMutableDictionary *const manifest = [self _load:path error:&error];
        if (!manifest) {
            return WSKResumeManifestIsInvalid(error) ? WSKResumeResponse(409) : WSKResumeError(error);
        }
        if (WSKResumeNumber(manifest, @"length").unsignedLongLongValue != length || ![WSKResumeDictionary(manifest, @"metadata") isEqual:metadata]) {
            return WSKResumeResponse(409);
        }
        if (![self _recover:manifest at:path error:&error]) {
            return WSKResumeError(error);
        }
        return [self _response:201 manifest:manifest identifier:identifier];
    }
    if (errno != ENOENT) {
        return WSKResumeError(WSKMakePosixError(errno));
    }
    NSUInteger active = 0;
    unsigned long long reserved = 0;
    NSArray *const names = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:_directory error:&error];
    if (!names) {
        return WSKResumeError(error);
    }
    for (NSString *name in names) {
        if (![WSKResumeUUID(name) isEqualToString:name]) {
            continue;
        }
        NSDictionary *const manifest = [self _load:[self _sessionPath:name] error:&error];
        if (!manifest && !WSKResumeManifestIsInvalid(error)) {
            // Its declared length is unknown until storage becomes available.
            // Do not admit more bytes against an underestimated reservation.
            return WSKResumeError(error);
        }
        if (![WSKResumeString(manifest, @"state") isEqualToString:@"complete"]) {
            ++active;
            reserved += manifest ? WSKResumeNumber(manifest, @"length").unsignedLongLongValue : WSKResumeFileLimit;
        }
    }
    if (active >= WSKResumeActiveLimit || length > WSKResumeAggregateLimit - MIN(reserved, WSKResumeAggregateLimit)) {
        return WSKResumeResponse(413);
    }
    if (mkdir(path.fileSystemRepresentation, 0700) < 0) {
        return WSKResumeError(WSKMakePosixError(errno));
    }
    NSString *const payload = [path stringByAppendingPathComponent:@"payload"];
    int const file = open(payload.fileSystemRepresentation, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (file < 0) {
        error = WSKMakePosixError(errno);
        [self _removeSession:path manifest:nil error:NULL];
        return WSKResumeError(error);
    }
    BOOL const closed = WSKResumeClose(file, &error);
    NSMutableDictionary *const manifest = [@{@"version": @1, @"length": @(length), @"offset": @0, @"expires": @(NSDate.date.timeIntervalSince1970 + _expirationInterval), @"state": @"active", @"metadata": metadata, @"metadataHeader": metadataHeader, @"binding": _binding} mutableCopy];
    if (!closed || ![self _save:manifest at:path error:&error]) {
        [self _removeSession:path manifest:manifest error:NULL];
        return WSKResumeError(error);
    }
    if (length == 0) {
        WSKResponse *const failure = [self _publish:manifest at:path validate:validate publish:publish];
        if (failure) {
            // A receipt-write or identity-inspection failure leaves publication
            // uncertain. Keep that journal, including for zero-byte creation.
            NSDictionary *const journal = manifest[@"journal"];
            if (!journal) {
                [self _removeSession:path manifest:manifest error:NULL];
            }
            return failure;
        }
    }
    return [self _response:201 manifest:manifest identifier:identifier];
}

- (WSKResponse *)_patch:(WSKRequest *)request manifest:(NSMutableDictionary *)manifest at:(NSString *)path identifier:(NSString *)identifier validate:(WSKResumableUploadValidationBlock)validate publish:(WSKResumableUploadPublicationBlock)publish {
    if (![WSKResumeHeader(request, @"Content-Type") isEqualToString:@"application/offset+octet-stream"]) {
        return WSKResumeResponse(415);
    }
    NSString *const encoding = WSKResumeHeader(request, @"Content-Encoding");
    if (encoding.length && [encoding caseInsensitiveCompare:@"identity"] != NSOrderedSame) {
        return WSKResumeResponse(415);
    }
    unsigned long long requestedOffset = 0;
    if (!WSKResumeDecimal(WSKResumeHeader(request, @"Upload-Offset"), &requestedOffset)) {
        return WSKResumeResponse(400);
    }
    unsigned long long const offset = WSKResumeNumber(manifest, @"offset").unsignedLongLongValue;
    unsigned long long const length = WSKResumeNumber(manifest, @"length").unsignedLongLongValue;
    if (requestedOffset != offset || [WSKResumeString(manifest, @"state") isEqualToString:@"complete"]) {
        return WSKResumeResponse(409);
    }
    if (![request isKindOfClass:WSKFileRequest.class]) {
        return WSKResumeResponse(400);
    }
    NSString *const incoming = [(WSKFileRequest *)request temporaryPath];
    int const source = open(incoming.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    struct stat info;
    if (source < 0) {
        if (request.contentLength == 0) {
            return [self _response:204 manifest:manifest identifier:identifier];
        }
        return WSKResumeError(WSKMakePosixError(errno));
    }
    if (fstat(source, &info) < 0 || !S_ISREG(info.st_mode) || info.st_size < 0) {
        close(source);
        return WSKResumeResponse(500);
    }
    // Reception has finished and this descriptor now owns the disposable body.
    // Remove its temporary name before touching persistent session state so a
    // process exit during append/publication cannot strand the request spool.
    // The request's eventual deallocation may harmlessly unlink it again.
    if (unlink(incoming.fileSystemRepresentation) != 0) {
        int const code = errno;
        close(source);
        return WSKResumeError(WSKMakePosixError(code));
    }
    unsigned long long const incomingLength = (unsigned long long)info.st_size;
    if (incomingLength > WSKResumeChunkLimit || incomingLength > length - offset) {
        close(source);
        return WSKResumeResponse(413);
    }
    if (incomingLength == 0) {
        close(source);
        return [self _response:204 manifest:manifest identifier:identifier];
    }
    int const destination = open([path stringByAppendingPathComponent:@"payload"].fileSystemRepresentation, O_WRONLY | O_NOFOLLOW | O_CLOEXEC);
    if (destination < 0) {
        int const code = errno;
        close(source);
        return WSKResumeError(WSKMakePosixError(code));
    }
    NSError *error = nil;
    BOOL success = lseek(destination, (off_t)offset, SEEK_SET) >= 0;
    if (!success) {
        error = WSKMakePosixError(errno);
    }
    uint8_t buffer[65536];
    unsigned long long remaining = incomingLength;
    while (success && remaining > 0) {
        ssize_t const count = read(source, buffer, (size_t)MIN(remaining, sizeof(buffer)));
        if (count < 0 && errno == EINTR) {
            continue;
        }
        if (count <= 0) {
            error = WSKMakePosixError(count < 0 ? errno : EIO);
            success = NO;
            break;
        }
        success = WSKResumeWrite(destination, buffer, (size_t)count, &error);
        remaining -= (unsigned long long)count;
    }
    close(source);
    if (success && fsync(destination) < 0) {
        error = WSKMakePosixError(errno);
        success = NO;
    }
    if (!WSKResumeClose(destination, success ? &error : NULL)) {
        success = NO;
    }
    if (!success) {
        [self _truncatePayload:path offset:offset error:NULL];
        return WSKResumeError(error);
    }
    if (offset + incomingLength == length) {
        WSKResponse *const failure = [self _publish:manifest at:path validate:validate publish:publish];
        if (failure) {
            return failure;
        }
    } else {
        NSMutableDictionary *const next = [manifest mutableCopy];
        next[@"offset"] = @(offset + incomingLength);
        next[@"expires"] = @(NSDate.date.timeIntervalSince1970 + _expirationInterval);
        if (![self _save:next at:path error:&error]) {
            [self _truncatePayload:path offset:offset error:NULL];
            return WSKResumeError(error);
        }
        [manifest setDictionary:next];
    }
    return [self _response:204 manifest:manifest identifier:identifier];
}

- (WSKResponse *)processRequest:(WSKRequest *)request validate:(WSKResumableUploadValidationBlock)validate publish:(WSKResumableUploadPublicationBlock)publish {
    NSString *const method = request.isVirtualHEAD ? @"HEAD" : request.method;
    if ([method isEqualToString:@"OPTIONS"]) {
        WSKResponse *const response = WSKResumeResponse(204);
        [response setValue:@"1.0.0" forAdditionalHeader:@"Tus-Version"];
        [response setValue:@"creation,expiration,termination" forAdditionalHeader:@"Tus-Extension"];
        [response setValue:[@(WSKResumeFileLimit) stringValue] forAdditionalHeader:@"Tus-Max-Size"];
        return response;
    }
    if (![WSKResumeHeader(request, @"Tus-Resumable") isEqualToString:@"1.0.0"]) {
        WSKResponse *const response = WSKResumeResponse(412);
        [response setValue:@"1.0.0" forAdditionalHeader:@"Tus-Version"];
        return response;
    }
    BOOL const creating = [method isEqualToString:@"POST"] && [request.path isEqualToString:@"/uploads"];
    BOOL const deleting = [method isEqualToString:@"DELETE"];
    NSString *identifier = creating ? WSKResumeUUID(WSKResumeHeader(request, @"Upload-Key")) : nil;
    if (!creating && [request.path hasPrefix:@"/uploads/"]) {
        identifier = WSKResumeUUID([request.path substringFromIndex:9]);
    }
    if (!identifier) {
        return WSKResumeResponse(creating ? 400 : 404);
    }
    if (!creating && !deleting && ![method isEqualToString:@"HEAD"] && ![method isEqualToString:@"PATCH"]) {
        return WSKResumeResponse(405);
    }
    [self cleanupExpiredUploads];
    NSError *error = nil;
    int const directoryLock = [self _lockDirectory:(creating || deleting) ? LOCK_EX : LOCK_SH create:creating error:&error];
    if (directoryLock < 0) {
        if (error.code == ESTALE) {
            return WSKResumeResponse(409);
        }
        return !creating && error.code == ENOENT ? WSKResumeResponse(404) : WSKResumeError(error);
    }
    WSKResponse *response = nil;
    if (creating) {
        [self _cleanupLocked];
        response = [self _create:request identifier:identifier validate:validate publish:publish];
    } else {
        NSString *const path = [self _sessionPath:identifier];
        int const sessionLock = [self _lockSession:path error:&error];
        if (sessionLock < 0) {
            response = error.code == ENOENT ? WSKResumeResponse(404) : WSKResumeError(error);
        } else {
            NSMutableDictionary *const manifest = [self _load:path error:&error];
            if (!manifest) {
                response = WSKResumeManifestIsInvalid(error) ? WSKResumeResponse(410) : WSKResumeError(error);
            } else if (WSKResumeNumber(manifest, @"expires").doubleValue <= NSDate.date.timeIntervalSince1970) {
                response = WSKResumeResponse(410);
            } else if (deleting) {
                response = [self _removeSession:path manifest:manifest error:&error] ? WSKResumeResponse(204) : WSKResumeError(error);
            } else if (![self _recover:manifest at:path error:&error]) {
                response = WSKResumeError(error);
            } else if ([method isEqualToString:@"HEAD"]) {
                response = [self _response:200 manifest:manifest identifier:identifier];
            } else {
                response = [self _patch:request manifest:manifest at:path identifier:identifier validate:validate publish:publish];
            }
            close(sessionLock);
        }
    }
    close(directoryLock);
    [self cleanupExpiredUploads];
    // Authorization and publication hooks return ordinary uploader errors. Ensure
    // those refusals still carry the protocol's version and cache contract.
    [response setValue:@"1.0.0" forAdditionalHeader:@"Tus-Resumable"];
    [response setValue:@"no-store" forAdditionalHeader:@"Cache-Control"];
    return response;
}
@end
