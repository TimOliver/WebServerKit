// The endurance runner owns this process and its directories. Control uses stdio,
// never HTTP, so taking a measurement cannot itself keep a connection alive.
@import Foundation;
@import WebServerKit;
@import WebServerKitDAV;
@import WebServerKitUploader;

#include <dirent.h>
#include <dlfcn.h>
#include <errno.h>
#include <mach/mach.h>
#include <malloc/malloc.h>
#include <sys/resource.h>
#include <unistd.h>

static NSUInteger liveConnections, acceptedConnections, closedConnections, activeUploads, activeDownloads;

@interface EnduranceConnection : WSKConnection
@property(nonatomic) BOOL counted;
@property(nonatomic) BOOL uploading;
@property(nonatomic) BOOL downloading;
@end

@implementation EnduranceConnection
- (BOOL)open {
    if (![super open]) {
        return NO;
    }
    @synchronized([EnduranceConnection class]) {
        self.counted = YES;
        liveConnections++;
        acceptedConnections++;
    }
    return YES;
}
- (WSKResponse *)preflightRequest:(WSKRequest *)request {
    @synchronized([EnduranceConnection class]) {
        // Only count once per connection, including reused GET connections.
        if (!self.uploading && ([request.method isEqualToString:@"PUT"] || [request.method isEqualToString:@"POST"])) {
            self.uploading = YES;
            activeUploads++;
        }
        if (!self.downloading && [request.method isEqualToString:@"GET"]) {
            self.downloading = YES;
            activeDownloads++;
        }
    }
    return [super preflightRequest:request];
}
- (void)close {
    @synchronized([EnduranceConnection class]) {
        if (self.counted) {
            self.counted = NO;
            liveConnections--;
            closedConnections++;
            if (self.uploading) activeUploads--;
            if (self.downloading) activeDownloads--;
        }
    }
    [super close];
}
@end

static NSDictionary *Resources(BOOL includeAllocations) {
    // Count entries, not the allocation size of a proc_pidinfo buffer. Exclude
    // our own directory descriptor, which is closed before returning.
    DIR *directory = opendir("/dev/fd");
    if (!directory) {
        return @{@"error": @"Cannot enumerate process descriptors"};
    }
    NSUInteger descriptors = 0;
    struct dirent *entry;
    while ((entry = readdir(directory))) {
        if (entry->d_name[0] >= '0' && entry->d_name[0] <= '9' && atoi(entry->d_name) != dirfd(directory)) {
            descriptors++;
        }
    }
    closedir(directory);
    task_vm_info_data_t memory;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    kern_return_t result = task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&memory, &count);
    if (result != KERN_SUCCESS) {
        return @{@"error": @"Cannot read process memory footprint"};
    }
    NSMutableDictionary *resources;
    @synchronized([EnduranceConnection class]) {
        resources = [@{
            @"connections": @(liveConnections), @"accepted": @(acceptedConnections),
            @"closed": @(closedConnections), @"uploads": @(activeUploads), @"downloads": @(activeDownloads),
            @"reserved_bytes": @([WSKWebServer reservedInMemoryByteCount]),
            @"descriptors": @(descriptors), @"footprint_bytes": @(memory.phys_footprint)
        } mutableCopy];
    }
    if (includeAllocations) {
        struct rusage usage;
        if (getrusage(RUSAGE_SELF, &usage) != 0) {
            return @{@"error": @"Cannot read process CPU usage"};
        }
        // NULL sums every malloc zone. Reserved allocator capacity is distinct
        // from bytes in live blocks and from the process's phys_footprint.
        malloc_statistics_t allocations;
        malloc_zone_statistics(NULL, &allocations);
        resources[@"cpu_user_seconds"] = @(usage.ru_utime.tv_sec + usage.ru_utime.tv_usec / 1000000.0);
        resources[@"cpu_system_seconds"] = @(usage.ru_stime.tv_sec + usage.ru_stime.tv_usec / 1000000.0);
        resources[@"allocator_live_bytes"] = @(allocations.size_in_use);
        resources[@"allocator_live_blocks"] = @(allocations.blocks_in_use);
        resources[@"allocator_reserved_bytes"] = @(allocations.size_allocated);
    }
    return resources;
}

static void Reply(NSDictionary *value) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:0 error:NULL];
    if (!data || fwrite(data.bytes, 1, data.length, stdout) != data.length || fputc('\n', stdout) == EOF || fflush(stdout)) {
        exit(2);
    }
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 3) {
            fprintf(stderr, "Usage: EnduranceHost UPLOADER_DIRECTORY DAV_DIRECTORY\n");
            return 2;
        }
        [WSKWebServer setLogLevel:4];
        if (dlsym(RTLD_DEFAULT, "WSKStorageFaultControl")) {
            // A legal application logger may perform syscalls and change errno.
            // Make that deterministic in this fixture instead of depending on
            // whether the built-in logger's first isatty() call has already run.
            [WSKWebServer setBuiltInLogger:^(int level, NSString *message) {
                (void)level;
                (void)message;
                errno = EIO;
            }];
        }
        WSKWebUploader *uploader = [[WSKWebUploader alloc] initWithUploadDirectory:@(argv[1])];
        WSKWebDAVServer *dav = [[WSKWebDAVServer alloc] initWithUploadDirectory:@(argv[2])];
        // SSE and directory monitoring are server resources too. Leave their defaults
        // intact even though this runner never loads or changes the browser UI.
        __block NSUInteger uploaderPort = 0, davPort = 0;
        BOOL (^start)(NSError **) = ^BOOL(NSError **error) {
            NSMutableDictionary *options = [@{
                WSKOption_Port: @(uploaderPort), WSKOption_BindToLocalhost: @YES,
                WSKOption_ConnectionClass: [EnduranceConnection class],
                WSKOption_ConnectionIdleTimeout: @5.0, WSKOption_ConnectionKeepAliveTimeout: @2.0
                // Omit BonjourName to disable advertising; this is loopback-only.
            } mutableCopy];
            if (![uploader startWithOptions:options error:error]) return NO;
            uploaderPort = uploader.port;
            options[WSKOption_Port] = @(davPort);
            if (![dav startWithOptions:options error:error]) {
                [uploader stop];
                return NO;
            }
            davPort = dav.port;
            return YES;
        };
        NSError *error = nil;
        if (!start(&error)) {
            Reply(@{@"error": error.description ?: @"Cannot start servers"});
            return 1;
        }
        Reply(@{@"ready": @YES, @"pid": @(getpid()), @"uploader_port": @(uploaderPort), @"dav_port": @(davPort),
                @"temporary_directory": NSTemporaryDirectory(), @"resources": Resources(NO)});
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            char *line = NULL;
            size_t capacity = 0;
            ssize_t length;
            while ((length = getline(&line, &capacity, stdin)) != -1) {
                @autoreleasepool {
                    NSData *data = [NSData dataWithBytes:line length:(NSUInteger)length];
                    NSDictionary *message = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
                    dispatch_async(dispatch_get_main_queue(), ^{
                        @autoreleasepool {
                            NSString *command = [message isKindOfClass:[NSDictionary class]] ? message[@"command"] : nil;
                            if ([command hasPrefix:@"fault-"]) {
                                // Available only when the dedicated fixture image is
                                // explicitly loaded into this disposable test host.
                                NSDictionary *(*control)(NSDictionary *) = dlsym(RTLD_DEFAULT, "WSKStorageFaultControl");
                                Reply(control ? control(message) : @{@"error": @"Storage fault fixture is not loaded"});
                                return;
                            }
                            size_t relieved = 0;
                            if ([command isEqualToString:@"stop"] || [command isEqualToString:@"shutdown"]) {
                                [uploader stop];
                                [dav stop];
                            } else if ([command isEqualToString:@"start"]) {
                                NSError *startError = nil;
                                if (!start(&startError)) {
                                    Reply(@{@"error": startError.description ?: @"Cannot restart servers"});
                                    return;
                                }
                            } else if ([command isEqualToString:@"relieve-allocator"]) {
                                // Explicit diagnostic control, used only after all
                                // measured cycles and the final idle window.
                                relieved = malloc_zone_pressure_relief(NULL, 0);
                            } else if (![command isEqualToString:@"stats"] && ![command isEqualToString:@"profile-stats"]) {
                                Reply(@{@"error": @"Unknown command"});
                                return;
                            }
                            Reply(@{@"resources": Resources(![command isEqualToString:@"stats"]), @"running": @(uploader.isRunning && dav.isRunning),
                                    @"allocator_relieved_bytes": @(relieved),
                                    @"uploader_port": @(uploaderPort), @"dav_port": @(davPort)});
                            if ([command isEqualToString:@"shutdown"]) exit(0);
                        }
                    });
                }
            }
            free(line);
            dispatch_async(dispatch_get_main_queue(), ^{ [uploader stop]; [dav stop]; exit(0); });
        });
        [[NSRunLoop mainRunLoop] run];
    }
    return 0;
}
