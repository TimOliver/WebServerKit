// Test-only syscall failures for the owned loopback recovery child. Controls
// choose a UUID and a fixed mode, never an arbitrary path or descriptor.
#import <Foundation/Foundation.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <sys/stat.h>
#include <unistd.h>

static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static __thread BOOL insideFixture;
static atomic_bool enabled;
static NSString *mode, *session, *evidence;
static BOOL armed;
static NSUInteger hits, calls;
static unsigned long long written;
static NSDictionary *lastHit;

static NSString *Canonical(const char *path) {
    char resolved[PATH_MAX];
    return path && realpath(path, resolved) ? @(resolved) : nil;
}
static NSString *DescriptorPath(int fd) {
    char path[PATH_MAX];
    struct stat info;
    return fstat(fd, &info) == 0 && S_ISREG(info.st_mode) && fcntl(fd, F_GETPATH, path) == 0 ? Canonical(path) : nil;
}
static BOOL UUID(NSString *name) {
    return name.length == 36 && [[[NSUUID alloc] initWithUUIDString:name].UUIDString.lowercaseString isEqual:name.lowercaseString];
}
static NSString *Kind(NSString *path) {
    if (!path || ![path.stringByDeletingLastPathComponent isEqual:session]) return nil;
    NSString *name = path.lastPathComponent;
    if ([name isEqual:@"payload"]) return @"payload";
    if ([name hasPrefix:@".stage-"] && UUID([name substringFromIndex:7])) return @"stage";
    if ([name hasPrefix:@".manifest-"] && UUID([name substringFromIndex:10])) return @"manifest";
    return nil;
}
static NSString *ManifestState(NSString *path, const void *bytes, size_t length) {
    NSData *data = bytes ? [NSData dataWithBytes:bytes length:length] : [NSData dataWithContentsOfFile:path];
    if (!data || data.length > 32768) return nil;
    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    return [object isKindOfClass:NSDictionary.class] ? object[@"state"] : nil;
}
static NSDictionary *Snapshot(void) {
    return @{@"armed": @(armed), @"mode": mode ?: @"none", @"hits": @(hits), @"calls": @(calls),
             @"bytes_written": @(written), @"event": lastHit ?: @{}};
}
// Own image calls bypass this image's dyld interposition. Persist proof before
// deterministic exit, including the successful operation's file identity/size.
static void Hit(NSString *operation, NSString *path, int failure) {
    hits++;
    struct stat info = {0};
    BOOL exists = lstat(path.fileSystemRepresentation, &info) == 0;
    lastHit = @{@"operation": operation, @"path": path, @"errno": @(failure),
                @"exists": @(exists), @"device": @((unsigned long long)info.st_dev),
                @"inode": @((unsigned long long)info.st_ino), @"size": @((long long)info.st_size)};
    NSData *data = [NSJSONSerialization dataWithJSONObject:Snapshot() options:0 error:NULL];
    int fd = open(evidence.fileSystemRepresentation, O_CREAT | O_TRUNC | O_WRONLY | O_NOFOLLOW, 0600);
    if (fd < 0) _exit(87);
    const uint8_t *cursor = data.bytes;
    size_t remaining = data.length;
    while (remaining) {
        ssize_t count = write(fd, cursor, remaining);
        if (count <= 0) _exit(87);
        cursor += count; remaining -= (size_t)count;
    }
    if (fsync(fd) != 0 || close(fd) != 0) _exit(87);
    if ([mode hasPrefix:@"exit-"]) _exit(86);
}
static BOOL Matches(NSString *suffix) { return armed && hits == 0 && [mode isEqual:suffix]; }

static ssize_t InjectWrite(int fd, const void *bytes, size_t length) {
    if (!atomic_load(&enabled) || insideFixture) return write(fd, bytes, length);
    int savedErrno = errno;
    insideFixture = YES; pthread_mutex_lock(&lock);
    NSString *path = DescriptorPath(fd), *kind = Kind(path);
    if (armed && hits == 0 && ([kind isEqual:@"payload"] || [kind isEqual:@"stage"])) {
        calls++;
        NSString *prefix = [kind stringByAppendingString:@"-write-"];
        if (written >= 65536 && ([mode isEqual:[prefix stringByAppendingString:@"enospc"]] || [mode isEqual:[prefix stringByAppendingString:@"eio"]])) {
            int failure = [mode hasSuffix:@"enospc"] ? ENOSPC : EIO;
            Hit(@"write", path, failure); pthread_mutex_unlock(&lock); insideFixture = NO; errno = failure; return -1;
        }
    }
    if ([kind isEqual:@"manifest"]) {
        NSString *state = ManifestState(path, bytes, length);
        if (Matches([NSString stringWithFormat:@"manifest-%@-write-enospc", state])) {
            Hit(@"write", path, ENOSPC); pthread_mutex_unlock(&lock); insideFixture = NO; errno = ENOSPC; return -1;
        }
    }
    errno = savedErrno;
    ssize_t result = write(fd, bytes, length);
    int resultErrno = errno;
    if (result > 0 && ([kind isEqual:@"payload"] || [kind isEqual:@"stage"])) {
        // Count only the selected mode's data writer; payload bytes must not
        // satisfy the staging prefix required by a staging fault.
        if ([mode containsString:kind]) written += (unsigned long long)result;
        if (Matches([@"exit-" stringByAppendingString:[kind stringByAppendingString:@"-write"]])) Hit(@"write-after", path, 0);
    }
    pthread_mutex_unlock(&lock); insideFixture = NO; errno = resultErrno; return result;
}
static int InjectFsync(int fd) {
    if (!atomic_load(&enabled) || insideFixture) return fsync(fd);
    int savedErrno = errno;
    insideFixture = YES; pthread_mutex_lock(&lock);
    NSString *path = DescriptorPath(fd), *kind = Kind(path);
    NSString *state = [kind isEqual:@"manifest"] ? ManifestState(path, NULL, 0) : nil;
    if ((kind && Matches([kind stringByAppendingString:@"-fsync-eio"])) || (state && Matches([NSString stringWithFormat:@"manifest-%@-fsync-eio", state]))) {
        Hit(@"fsync", path, EIO); pthread_mutex_unlock(&lock); insideFixture = NO; errno = EIO; return -1;
    }
    errno = savedErrno;
    int result = fsync(fd), resultErrno = errno;
    if (result == 0 && kind && Matches([@"exit-" stringByAppendingString:[kind stringByAppendingString:@"-fsync"]])) Hit(@"fsync-after", path, 0);
    pthread_mutex_unlock(&lock); insideFixture = NO; errno = resultErrno; return result;
}
static int InjectClose(int fd) {
    if (!atomic_load(&enabled) || insideFixture) return close(fd);
    int savedErrno = errno;
    insideFixture = YES; pthread_mutex_lock(&lock);
    NSString *path = DescriptorPath(fd), *kind = Kind(path);
    NSString *state = [kind isEqual:@"manifest"] ? ManifestState(path, NULL, 0) : nil;
    BOOL selected = (written > 0 && kind && Matches([kind stringByAppendingString:@"-close-eio"])) ||
                    (state && Matches([NSString stringWithFormat:@"manifest-%@-close-eio", state]));
    errno = savedErrno;
    int result = close(fd), resultErrno = errno;
    if (result == 0 && selected) {
        Hit(@"close-after-success", path, EIO);
        pthread_mutex_unlock(&lock); insideFixture = NO; errno = EIO; return -1;
    }
    pthread_mutex_unlock(&lock); insideFixture = NO; errno = resultErrno; return result;
}
static int InjectOpen(const char *path, int flags, ...) {
    mode_t permissions = 0;
    if (flags & O_CREAT) { va_list values; va_start(values, flags); permissions = va_arg(values, int); va_end(values); }
    int result = open(path, flags, permissions), resultErrno = errno;
    if (!atomic_load(&enabled) || insideFixture) return result;
    if (result >= 0 && (flags & O_CREAT) && (flags & O_EXCL)) {
        insideFixture = YES; pthread_mutex_lock(&lock);
        NSString *actual = DescriptorPath(result);
        if ([Kind(actual) isEqual:@"stage"] && Matches(@"exit-stage-open")) Hit(@"open-after", actual, 0);
        pthread_mutex_unlock(&lock); insideFixture = NO;
    }
    errno = resultErrno; return result;
}
static int InjectRename(const char *source, const char *destination) {
    if (!atomic_load(&enabled) || insideFixture) return rename(source, destination);
    int savedErrno = errno;
    insideFixture = YES; pthread_mutex_lock(&lock);
    NSString *path = Canonical(source), *state = nil;
    if ([Kind(path) isEqual:@"manifest"] && [@(destination) isEqual:[session stringByAppendingPathComponent:@"manifest.json"]]) state = ManifestState(path, NULL, 0);
    if (state && Matches([NSString stringWithFormat:@"manifest-%@-rename-eio", state])) {
        Hit(@"manifest-rename", path, EIO); pthread_mutex_unlock(&lock); insideFixture = NO; errno = EIO; return -1;
    }
    errno = savedErrno;
    int result = rename(source, destination), resultErrno = errno;
    if (result == 0 && state && Matches([NSString stringWithFormat:@"exit-%@-save", state])) Hit(@"manifest-rename-after", @(destination), 0);
    pthread_mutex_unlock(&lock); insideFixture = NO; errno = resultErrno; return result;
}
static int InjectRenameExclusive(const char *source, const char *destination, unsigned int flags) {
    if (!atomic_load(&enabled) || insideFixture) return renamex_np(source, destination, flags);
    int savedErrno = errno;
    insideFixture = YES; pthread_mutex_lock(&lock);
    NSString *path = Canonical(source);
    BOOL stage = [Kind(path) isEqual:@"stage"];
    if (stage && Matches(@"publication-rename-eio")) {
        Hit(@"publication-rename", path, EIO); pthread_mutex_unlock(&lock); insideFixture = NO; errno = EIO; return -1;
    }
    if (stage && Matches(@"exit-publication-before")) Hit(@"publication-rename-before", path, 0);
    errno = savedErrno;
    int result = renamex_np(source, destination, flags), resultErrno = errno;
    if (result == 0 && stage && Matches(@"exit-publication-after")) Hit(@"publication-rename-after", @(destination), 0);
    pthread_mutex_unlock(&lock); insideFixture = NO; errno = resultErrno; return result;
}

__attribute__((visibility("default"))) NSDictionary *WSKStorageFaultControl(NSDictionary *message) {
    NSString *command = message[@"command"];
    insideFixture = YES; pthread_mutex_lock(&lock);
    NSString *error = nil;
    if ([command isEqual:@"fault-arm"]) {
        NSArray *modes = @[@"payload-write-enospc", @"payload-write-eio", @"payload-fsync-eio", @"payload-close-eio", @"stage-close-eio", @"manifest-active-fsync-eio", @"manifest-active-close-eio", @"manifest-publishing-fsync-eio", @"manifest-complete-close-eio", @"manifest-active-write-enospc", @"manifest-active-rename-eio", @"manifest-publishing-rename-eio", @"manifest-complete-rename-eio", @"stage-write-enospc", @"stage-fsync-eio", @"publication-rename-eio", @"exit-payload-write", @"exit-payload-fsync", @"exit-active-save", @"exit-stage-open", @"exit-publishing-save", @"exit-stage-write", @"exit-stage-fsync", @"exit-publication-before", @"exit-publication-after", @"exit-complete-save"];
        NSString *root = Canonical(getenv("TMPDIR"));
        NSString *store = Canonical(getenv("WSK_ENDURANCE_RESUMABLE_DIRECTORY"));
        NSString *identifier = message[@"key"];
        if (![modes containsObject:message[@"mode"]] || ![identifier isKindOfClass:NSString.class] || !UUID(identifier) || !root || !store || ![store.stringByDeletingLastPathComponent isEqual:root.stringByDeletingLastPathComponent] || ![store.lastPathComponent isEqual:@"sessions"]) {
            error = @"Invalid fixed mode, UUID, or owned sibling session directory";
        } else {
            NSString *candidate = [store stringByAppendingPathComponent:identifier];
            if (![Canonical(candidate.fileSystemRepresentation) isEqual:candidate]) error = @"Session must be an existing canonical child";
            else {
                session = candidate; mode = message[@"mode"]; armed = YES; hits = calls = 0; written = 0; lastHit = nil;
                evidence = [root.stringByDeletingLastPathComponent stringByAppendingPathComponent:@"fault-event.json"];
                unlink(evidence.fileSystemRepresentation);
                atomic_store(&enabled, true);
            }
        }
    } else if ([command isEqual:@"fault-clear"]) armed = NO;
    else if (![command isEqual:@"fault-stats"]) error = @"Unknown recovery fault command";
    NSMutableDictionary *snapshot = [Snapshot() mutableCopy];
    if (error) snapshot[@"error"] = error;
    pthread_mutex_unlock(&lock); insideFixture = NO; return snapshot;
}
__attribute__((used, section("__DATA,__interpose"))) static const struct { const void *replacement; const void *original; } overrides[] = {
    {(void *)&InjectClose, (void *)&close}, {(void *)&InjectWrite, (void *)&write}, {(void *)&InjectFsync, (void *)&fsync}, {(void *)&InjectOpen, (void *)&open},
    {(void *)&InjectRename, (void *)&rename}, {(void *)&InjectRenameExclusive, (void *)&renamex_np},
};
