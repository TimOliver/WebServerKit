// Test-only storage failure injection for the owned endurance host. The sole
// eligible directory is that child's canonical TMPDIR. No request, control
// message, descriptor number or external process can widen that scope.
// Keep this in a separate image: dyld leaves calls from this image to write()
// and close() uninterposed, so those calls always perform the real operation.
#import <Foundation/Foundation.h>

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

typedef enum {
    StorageFaultNone,
    StorageFaultWriteNoSpace,
    StorageFaultWriteIO,
    StorageFaultCloseIO,
} StorageFaultMode;

typedef struct {
    StorageFaultMode mode;
    bool armed;
    bool released;
    bool target_closed;
    bool real_closed;
    int selected_fd;
    dev_t device;
    ino_t inode;
    uint64_t bytes_written;
    uint64_t write_calls;
    uint64_t hits;
    uint64_t close_calls;
    int real_close_result;
    int real_close_errno;
    int close_result;
    int close_errno;
    char root[PATH_MAX];
} StorageFaultState;

static const uint64_t StorageFaultMinimumPrefix = 65536;
static pthread_mutex_t storageFaultLock = PTHREAD_MUTEX_INITIALIZER;
static StorageFaultState storageFault = {
    .selected_fd = -1,
    .real_close_result = -2,
    .close_result = -2,
};

// Call only while holding storageFaultLock. Identity, not a reused descriptor
// number, decides whether an operation belongs to the selected temporary file.
static bool StorageFaultMatchesTarget(int descriptor) {
    if (storageFault.target_closed || descriptor != storageFault.selected_fd || descriptor < 0) {
        return false;
    }
    struct stat info;
    return fstat(descriptor, &info) == 0 && S_ISREG(info.st_mode) &&
           info.st_dev == storageFault.device && info.st_ino == storageFault.inode;
}

static bool StorageFaultCandidate(int descriptor, struct stat *info) {
    char path[PATH_MAX];
    char canonicalPath[PATH_MAX];
    if (fstat(descriptor, info) != 0 || !S_ISREG(info->st_mode) ||
        fcntl(descriptor, F_GETPATH, path) != 0 || !realpath(path, canonicalPath)) {
        return false;
    }
    size_t rootLength = strlen(storageFault.root);
    return rootLength > 1 && strncmp(canonicalPath, storageFault.root, rootLength) == 0 &&
           canonicalPath[rootLength] == '/';
}

static ssize_t StorageFaultWrite(int descriptor, const void *buffer, size_t length) {
    int incomingErrno = errno;
    pthread_mutex_lock(&storageFaultLock);
    bool target = StorageFaultMatchesTarget(descriptor);
    struct stat candidateInfo;
    bool candidate = !target && storageFault.armed && storageFault.selected_fd < 0 && length > 0 &&
                     StorageFaultCandidate(descriptor, &candidateInfo);
    if (!target && !candidate) {
        pthread_mutex_unlock(&storageFaultLock);
        errno = incomingErrno;
        return write(descriptor, buffer, length);
    }

    if (target && length > 0) {
        storageFault.write_calls++;
        if (storageFault.armed && storageFault.released && storageFault.hits == 0 &&
            (storageFault.mode == StorageFaultWriteNoSpace || storageFault.mode == StorageFaultWriteIO)) {
            int failure = storageFault.mode == StorageFaultWriteNoSpace ? ENOSPC : EIO;
            storageFault.hits++;
            pthread_mutex_unlock(&storageFaultLock);
            errno = failure;
            return -1;
        }
    }

    errno = incomingErrno;
    ssize_t result = write(descriptor, buffer, length);
    int resultErrno = errno;
    if (result > 0) {
        // Failed first writes never select a target. The prefix is real data
        // accepted by the filesystem before the harness releases the fault.
        if (candidate) {
            storageFault.selected_fd = descriptor;
            storageFault.device = candidateInfo.st_dev;
            storageFault.inode = candidateInfo.st_ino;
            storageFault.write_calls = 1;
        }
        uint64_t bytes = (uint64_t)result;
        storageFault.bytes_written = UINT64_MAX - storageFault.bytes_written < bytes
                                         ? UINT64_MAX
                                         : storageFault.bytes_written + bytes;
    }
    pthread_mutex_unlock(&storageFaultLock);
    errno = resultErrno;
    return result;
}

static int StorageFaultClose(int descriptor) {
    int incomingErrno = errno;
    pthread_mutex_lock(&storageFaultLock);
    if (!StorageFaultMatchesTarget(descriptor)) {
        pthread_mutex_unlock(&storageFaultLock);
        errno = incomingErrno;
        return close(descriptor);
    }

    storageFault.close_calls++;
    errno = incomingErrno;
    int result = close(descriptor);
    int resultErrno = errno;
    storageFault.real_close_result = result;
    storageFault.real_close_errno = result < 0 ? resultErrno : 0;
    if (result == 0) {
        storageFault.target_closed = true;
        storageFault.real_closed = true;
        if (storageFault.armed && storageFault.released && storageFault.hits == 0 &&
            storageFault.mode == StorageFaultCloseIO) {
            storageFault.hits++;
            result = -1;
            resultErrno = EIO;
        }
    }
    storageFault.close_result = result;
    storageFault.close_errno = result < 0 ? resultErrno : 0;
    pthread_mutex_unlock(&storageFaultLock);
    errno = resultErrno;
    return result;
}

static NSDictionary *StorageFaultSnapshot(StorageFaultState state, NSString *error) {
    NSString *mode = @"none";
    switch (state.mode) {
    case StorageFaultWriteNoSpace:
        mode = @"write-enospc";
        break;
    case StorageFaultWriteIO:
        mode = @"write-eio";
        break;
    case StorageFaultCloseIO:
        mode = @"close-eio";
        break;
    case StorageFaultNone:
        break;
    }
    NSMutableDictionary *result = [@{
        @"mode" : mode,
        @"armed" : @(state.armed),
        @"released" : @(state.released),
        @"bytes_written" : @(state.bytes_written),
        @"write_calls" : @(state.write_calls),
        @"hits" : @(state.hits),
        @"target_closed" : @(state.target_closed),
        @"target_fd" : @(state.target_closed ? -1 : state.selected_fd),
        @"selected_fd" : @(state.selected_fd),
        @"target_device" : @((uint64_t)state.device),
        @"target_inode" : @((uint64_t)state.inode),
        @"close_calls" : @(state.close_calls),
        @"real_closed" : @(state.real_closed),
        @"real_close_result" : @(state.real_close_result),
        @"real_close_errno" : @(state.real_close_errno),
        @"close_result" : @(state.close_result),
        @"close_errno" : @(state.close_errno),
        @"minimum_prefix_bytes" : @(StorageFaultMinimumPrefix),
    } mutableCopy];
    if (error) {
        result[@"error"] = error;
    }
    return result;
}

// The host resolves this entry point only in the opt-in injected child. The
// commands arrive on its owned stdin pipe, never through an HTTP endpoint.
__attribute__((visibility("default"))) NSDictionary *WSKStorageFaultControl(NSDictionary *message) {
    NSString *error = nil;
    NSString *command = [message isKindOfClass:[NSDictionary class]] ? message[@"command"] : nil;
    if (![command isKindOfClass:[NSString class]]) {
        command = nil;
    }
    StorageFaultMode mode = StorageFaultNone;
    char canonicalRoot[PATH_MAX] = {0};
    if ([command isEqualToString:@"fault-arm"]) {
        id requestedMode = message[@"mode"];
        if ([requestedMode isEqual:@"write-enospc"]) {
            mode = StorageFaultWriteNoSpace;
        } else if ([requestedMode isEqual:@"write-eio"]) {
            mode = StorageFaultWriteIO;
        } else if ([requestedMode isEqual:@"close-eio"]) {
            mode = StorageFaultCloseIO;
        } else {
            error = @"fault-arm requires write-enospc, write-eio or close-eio mode";
        }
        const char *root = getenv("TMPDIR");
        struct stat info;
        if (!error && (!root || root[0] != '/' || !realpath(root, canonicalRoot) ||
                       strlen(canonicalRoot) <= 1 || stat(canonicalRoot, &info) != 0 || !S_ISDIR(info.st_mode))) {
            error = @"fault-arm requires an existing, non-root absolute TMPDIR";
        }
    }

    pthread_mutex_lock(&storageFaultLock);
    if (!error && [command isEqualToString:@"fault-arm"]) {
        if (StorageFaultMatchesTarget(storageFault.selected_fd)) {
            error = @"cannot rearm while the selected temporary file is open";
        } else {
            storageFault = (StorageFaultState){
                .mode = mode,
                .armed = true,
                .selected_fd = -1,
                .real_close_result = -2,
                .close_result = -2,
            };
            memcpy(storageFault.root, canonicalRoot, strlen(canonicalRoot) + 1);
        }
    } else if (!error && [command isEqualToString:@"fault-release"]) {
        if (!storageFault.armed || !StorageFaultMatchesTarget(storageFault.selected_fd) ||
            storageFault.bytes_written < StorageFaultMinimumPrefix) {
            error = @"fault-release requires an armed, open target with at least 65536 bytes written";
        } else {
            storageFault.released = true;
        }
    } else if (!error && [command isEqualToString:@"fault-clear"]) {
        // Preserve evidence and keep observing the selected file's real close.
        storageFault.armed = false;
    } else if (!error && ![command isEqualToString:@"fault-stats"]) {
        error = @"unknown storage fault control command";
    }
    StorageFaultState snapshot = storageFault;
    pthread_mutex_unlock(&storageFaultLock);
    return StorageFaultSnapshot(snapshot, error);
}

__attribute__((used, section("__DATA,__interpose"))) static const struct {
    const void *replacement;
    const void *original;
} storageFaultOverrides[] = {
    {(const void *)&StorageFaultWrite, (const void *)&write},
    {(const void *)&StorageFaultClose, (const void *)&close},
};
