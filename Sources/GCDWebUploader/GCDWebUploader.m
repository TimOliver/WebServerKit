/*
   Copyright (c) 2012-2019, Pierre-Olivier Latour
   All rights reserved.

   Redistribution and use in source and binary forms, with or without
   modification, are permitted provided that the following conditions are met:
 * Redistributions of source code must retain the above copyright
   notice, this list of conditions and the following disclaimer.
 * Redistributions in binary form must reproduce the above copyright
   notice, this list of conditions and the following disclaimer in the
   documentation and/or other materials provided with the distribution.
 * The name of Pierre-Olivier Latour may not be used to endorse
   or promote products derived from this software without specific
   prior written permission.

   THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
   ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
   WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
   DISCLAIMED. IN NO EVENT SHALL PIERRE-OLIVIER LATOUR BE LIABLE FOR ANY
   DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
   (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
   LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
   ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
   (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
   SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#if !__has_feature(objc_arc)
#error GCDWebUploader requires ARC
#endif

#import <TargetConditionals.h>
#if TARGET_OS_IPHONE
#import <UIKit/UIKit.h>
#endif

#import "GCDWebServerDataRequest.h"
#import "GCDWebServerDataResponse.h"
#import "GCDWebServerErrorResponse.h"
#import "GCDWebServerFileResponse.h"
#import "GCDWebServerFunctions.h"
#import "GCDWebServerMultiPartFormRequest.h"
#import "GCDWebServerStreamedResponse.h"
#import "GCDWebServerURLEncodedFormRequest.h"
#import "GCDWebUploader.h"

NS_ASSUME_NONNULL_BEGIN

@interface GCDWebUploader (Methods)
- (nullable GCDWebServerResponse *)listDirectory:(GCDWebServerRequest *)request;
- (nullable GCDWebServerResponse *)downloadFile:(GCDWebServerRequest *)request;
- (nullable GCDWebServerResponse *)uploadFile:(GCDWebServerMultiPartFormRequest *)request;
- (nullable GCDWebServerResponse *)moveItem:(GCDWebServerURLEncodedFormRequest *)request;
- (nullable GCDWebServerResponse *)deleteItem:(GCDWebServerURLEncodedFormRequest *)request;
- (nullable GCDWebServerResponse *)createDirectory:(GCDWebServerURLEncodedFormRequest *)request;
@end

NS_ASSUME_NONNULL_END

@interface GCDWebUploader () <NSFilePresenter>
@end

@implementation GCDWebUploader {
    NSMutableArray<GCDWebServerBodyReaderCompletionBlock> *_sseClients;
    dispatch_queue_t _sseQueue;
    dispatch_source_t _heartbeatTimer;
    NSOperationQueue *_filePresenterQueue;
    NSMutableSet<NSString *> *_pendingChangedPaths;
    NSTimer *_changeCoalescingTimer;
}

@dynamic delegate;

- (instancetype)initWithUploadDirectory:(NSString *)path {
    if ((self = [super init])) {
        NSString *const bundlePath = [[NSBundle bundleForClass:[GCDWebUploader class]] pathForResource:@"GCDWebUploader" ofType:@"bundle"];

        if (bundlePath == nil) {
            return nil;
        }

        NSBundle *const siteBundle = [NSBundle bundleWithPath:bundlePath];

        if (siteBundle == nil) {
            return nil;
        }

        _uploadDirectory = [path copy];
        _serverSentEventsEnabled = YES;
        _sseClients = [NSMutableArray array];
        _sseQueue = dispatch_queue_create("com.gcdwebuploader.sse", DISPATCH_QUEUE_SERIAL);
        _pendingChangedPaths = [NSMutableSet set];
        _filePresenterQueue = [[NSOperationQueue alloc] init];
        _filePresenterQueue.maxConcurrentOperationCount = 1;
        [self _startHeartbeatTimer];
        [NSFileCoordinator addFilePresenter:self];
        GCDWebUploader *const __unsafe_unretained server = self;

        // Resource files
        [self addGETHandlerForBasePath:@"/" directoryPath:(NSString *)[siteBundle resourcePath] indexFilename:nil cacheAge:3600 allowRangeRequests:NO];

        // Web page
        [self addHandlerForMethod:@"GET"
                             path:@"/"
                     requestClass:[GCDWebServerRequest class]
                     processBlock:^GCDWebServerResponse *(GCDWebServerRequest *request) {
#if TARGET_OS_IPHONE
                         NSString *device = [[UIDevice currentDevice] name];
#else
                NSString *device = [[NSHost currentHost] localizedName];
#endif
                         NSString *title = server.title;

                         if (title == nil) {
                             title = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleDisplayName"];

                             if (title == nil) {
                                 title = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleName"];
                             }

#if !TARGET_OS_IPHONE

                             if (title == nil) {
                                 title = [[NSProcessInfo processInfo] processName];
                             }

#endif
                         }

                         NSString *header = server.header;

                         if (header == nil) {
                             header = title;
                         }

                         NSString *prologue = server.prologue;

                         if (prologue == nil) {
                             prologue = [siteBundle localizedStringForKey:@"PROLOGUE" value:@"" table:nil];
                         }

                         NSString *epilogue = server.epilogue;

                         if (epilogue == nil) {
                             epilogue = [siteBundle localizedStringForKey:@"EPILOGUE" value:@"" table:nil];
                         }

                         NSString *footer = server.footer;

                         if (footer == nil) {
                             NSString *name = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleDisplayName"];

                             if (name == nil) {
                                 name = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleName"];
                             }

                             NSString *version = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
#if !TARGET_OS_IPHONE

                             if (!name && !version) {
                                 name = @"OS X";
                                 version = [[NSProcessInfo processInfo] operatingSystemVersionString];
                             }

#endif
                             footer = [NSString stringWithFormat:[siteBundle localizedStringForKey:@"FOOTER_FORMAT" value:@"" table:nil], name, version];
                         }

                         return [GCDWebServerDataResponse responseWithHTMLTemplate:(NSString *)[siteBundle pathForResource:@"index" ofType:@"html"]
                                                                         variables:@{
                                                                             @"device": device,
                                                                             @"title": title,
                                                                             @"header": header,
                                                                             @"prologue": prologue,
                                                                             @"epilogue": epilogue,
                                                                             @"footer": footer
                                                                         }];
                     }];

        // File listing
        [self addHandlerForMethod:@"GET"
                             path:@"/list"
                     requestClass:[GCDWebServerRequest class]
                     processBlock:^GCDWebServerResponse *(GCDWebServerRequest *request) {
                         return [server listDirectory:request];
                     }];

        // File download
        [self addHandlerForMethod:@"GET"
                             path:@"/download"
                     requestClass:[GCDWebServerRequest class]
                     processBlock:^GCDWebServerResponse *(GCDWebServerRequest *request) {
                         return [server downloadFile:request];
                     }];

        // File upload
        [self addHandlerForMethod:@"POST"
                             path:@"/upload"
                     requestClass:[GCDWebServerMultiPartFormRequest class]
                     processBlock:^GCDWebServerResponse *(GCDWebServerRequest *request) {
                         return [server uploadFile:(GCDWebServerMultiPartFormRequest *)request];
                     }];

        // File and folder moving
        [self addHandlerForMethod:@"POST"
                             path:@"/move"
                     requestClass:[GCDWebServerURLEncodedFormRequest class]
                     processBlock:^GCDWebServerResponse *(GCDWebServerRequest *request) {
                         return [server moveItem:(GCDWebServerURLEncodedFormRequest *)request];
                     }];

        // File and folder deletion
        [self addHandlerForMethod:@"POST"
                             path:@"/delete"
                     requestClass:[GCDWebServerURLEncodedFormRequest class]
                     processBlock:^GCDWebServerResponse *(GCDWebServerRequest *request) {
                         return [server deleteItem:(GCDWebServerURLEncodedFormRequest *)request];
                     }];

        // Directory creation
        [self addHandlerForMethod:@"POST"
                             path:@"/create"
                     requestClass:[GCDWebServerURLEncodedFormRequest class]
                     processBlock:^GCDWebServerResponse *(GCDWebServerRequest *request) {
                         return [server createDirectory:(GCDWebServerURLEncodedFormRequest *)request];
                     }];

        // Server-Sent Events endpoint
        [self addHandlerForMethod:@"GET"
                             path:@"/events"
                     requestClass:[GCDWebServerRequest class]
             asyncProcessBlock:^(GCDWebServerRequest *request, GCDWebServerCompletionBlock completionBlock) {
                         if (!server.serverSentEventsEnabled) {
                             completionBlock([GCDWebServerErrorResponse responseWithClientError:kGCDWebServerHTTPStatusCode_NotFound message:@"SSE not enabled"]);
                             return;
                         }
                         GCDWebServerStreamedResponse *response =
                             [GCDWebServerStreamedResponse responseWithContentType:@"text/event-stream"
                                                                  asyncStreamBlock:^(GCDWebServerBodyReaderCompletionBlock dataBlock) {
                                 dispatch_async(server->_sseQueue, ^{
                                     [server->_sseClients addObject:[dataBlock copy]];
                                 });
                             }];
                         response.cacheControlMaxAge = 0;
                         [response setValue:@"no-cache" forAdditionalHeader:@"Cache-Control"];
                         [response setValue:@"keep-alive" forAdditionalHeader:@"Connection"];
                         completionBlock(response);
                     }];
    }

    return self;
}

- (void)_startHeartbeatTimer {
    _heartbeatTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _sseQueue);
    dispatch_source_set_timer(_heartbeatTimer,
                              dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC),
                              15 * NSEC_PER_SEC,
                              1 * NSEC_PER_SEC);
    __weak GCDWebUploader *weakSelf = self;
    dispatch_source_set_event_handler(_heartbeatTimer, ^{
        [weakSelf _sendHeartbeat];
    });
    dispatch_resume(_heartbeatTimer);
}

#pragma mark - NSFilePresenter

- (NSURL *)presentedItemURL {
    return [NSURL fileURLWithPath:_uploadDirectory];
}

- (NSOperationQueue *)presentedItemOperationQueue {
    return _filePresenterQueue;
}

- (void)presentedSubitemDidChangeAtURL:(NSURL *)url {
    if (!_serverSentEventsEnabled) {
        return;
    }

    // Convert to relative path
    NSString *absolutePath = url.path;
    NSString *relativePath = @"/";
    if ([absolutePath hasPrefix:_uploadDirectory]) {
        relativePath = [absolutePath substringFromIndex:_uploadDirectory.length];
        if (relativePath.length == 0) {
            relativePath = @"/";
        }
    }

    // Get the directory containing the changed item
    NSString *changedDirectory = [relativePath stringByDeletingLastPathComponent];
    if (changedDirectory.length == 0 || ![changedDirectory hasPrefix:@"/"]) {
        changedDirectory = @"/";
    }
    if (![changedDirectory hasSuffix:@"/"]) {
        changedDirectory = [changedDirectory stringByAppendingString:@"/"];
    }

    @synchronized(_pendingChangedPaths) {
        [_pendingChangedPaths addObject:changedDirectory];
    }

    // Coalesce rapid changes with a short timer
    dispatch_async(dispatch_get_main_queue(), ^{
        [self->_changeCoalescingTimer invalidate];
        self->_changeCoalescingTimer = [NSTimer scheduledTimerWithTimeInterval:0.1
                                                                        target:self
                                                                      selector:@selector(_flushPendingChanges)
                                                                      userInfo:nil
                                                                       repeats:NO];
    });
}

- (void)_flushPendingChanges {
    NSSet *paths;
    @synchronized(_pendingChangedPaths) {
        paths = [_pendingChangedPaths copy];
        [_pendingChangedPaths removeAllObjects];
    }

    for (NSString *path in paths) {
        [self _broadcastSSEEvent:@"change" data:@{@"type": @"external", @"path": path}];
    }
}

- (void)_sendHeartbeat {
    if (!_serverSentEventsEnabled) {
        return;
    }
    NSData *heartbeat = [@":heartbeat\n\n" dataUsingEncoding:NSUTF8StringEncoding];
    NSArray *clients = [_sseClients copy];
    [_sseClients removeAllObjects];
    for (GCDWebServerBodyReaderCompletionBlock client in clients) {
        client(heartbeat, nil);
    }
}

- (void)_broadcastSSEEvent:(NSString *)eventType data:(NSDictionary *)data {
    if (!_serverSentEventsEnabled) {
        return;
    }
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:data options:0 error:nil];
    NSString *json = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
    NSString *sseMessage = [NSString stringWithFormat:@"event: %@\ndata: %@\n\n", eventType, json];
    NSData *messageData = [sseMessage dataUsingEncoding:NSUTF8StringEncoding];

    dispatch_async(_sseQueue, ^{
        NSArray *clients = [self->_sseClients copy];
        [self->_sseClients removeAllObjects];
        for (GCDWebServerBodyReaderCompletionBlock client in clients) {
            client(messageData, nil);
        }
    });
}

- (void)dealloc {
    if (_heartbeatTimer) {
        dispatch_source_cancel(_heartbeatTimer);
    }
    [NSFileCoordinator removeFilePresenter:self];
    [_changeCoalescingTimer invalidate];
}

@end

@implementation GCDWebUploader (Methods)

- (BOOL)_checkFileExtension:(NSString *)fileName {
    if (_allowedFileExtensions && ![_allowedFileExtensions containsObject:[[fileName pathExtension] lowercaseString]]) {
        return NO;
    }

    return YES;
}

- (NSString *)_uniquePathForPath:(NSString *)path {
    if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
        NSString *const directory = [path stringByDeletingLastPathComponent];
        NSString *const file = [path lastPathComponent];
        NSString *const base = [file stringByDeletingPathExtension];
        NSString *const extension = [file pathExtension];
        int retries = 0;
        do {
            if (extension.length) {
                path = [directory stringByAppendingPathComponent:(NSString *)[[base stringByAppendingFormat:@" (%i)", ++retries] stringByAppendingPathExtension:extension]];
            } else {
                path = [directory stringByAppendingPathComponent:[base stringByAppendingFormat:@" (%i)", ++retries]];
            }
        } while ([[NSFileManager defaultManager] fileExistsAtPath:path]);
    }

    return path;
}

- (GCDWebServerResponse *)listDirectory:(GCDWebServerRequest *)request {
    NSString *const relativePath = [request query][@"path"];
    NSString *const absolutePath = [_uploadDirectory stringByAppendingPathComponent:GCDWebServerNormalizePath(relativePath)];
    BOOL isDirectory = NO;

    if (!absolutePath || ![[NSFileManager defaultManager] fileExistsAtPath:absolutePath isDirectory:&isDirectory]) {
        return [GCDWebServerErrorResponse responseWithClientError:kGCDWebServerHTTPStatusCode_NotFound message:@"\"%@\" does not exist", relativePath];
    }

    if (!isDirectory) {
        return [GCDWebServerErrorResponse responseWithClientError:kGCDWebServerHTTPStatusCode_BadRequest message:@"\"%@\" is not a directory", relativePath];
    }

    NSString *const directoryName = [absolutePath lastPathComponent];

    if (!_allowHiddenItems && [directoryName hasPrefix:@"."]) {
        return [GCDWebServerErrorResponse responseWithClientError:kGCDWebServerHTTPStatusCode_Forbidden message:@"Listing directory name \"%@\" is not allowed", directoryName];
    }

    NSError *error = nil;
    NSArray *const contents = [[[NSFileManager defaultManager] contentsOfDirectoryAtPath:absolutePath error:&error] sortedArrayUsingSelector:@selector(localizedStandardCompare:)];

    if (contents == nil) {
        return [GCDWebServerErrorResponse responseWithServerError:kGCDWebServerHTTPStatusCode_InternalServerError underlyingError:error message:@"Failed listing directory \"%@\"", relativePath];
    }

    NSMutableArray *const array = [NSMutableArray array];

    for (NSString *item in [contents sortedArrayUsingSelector:@selector(localizedStandardCompare:)]) {
        if (_allowHiddenItems || ![item hasPrefix:@"."]) {
            NSDictionary *const attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:[absolutePath stringByAppendingPathComponent:item] error:NULL];
            NSString *const type = attributes[NSFileType];

            if ([type isEqualToString:NSFileTypeRegular] && [self _checkFileExtension:item]) {
                [array addObject:@{
                    @"path": [relativePath stringByAppendingPathComponent:item],
                    @"name": item,
                    @"size": (NSNumber *)attributes[NSFileSize]
                }];
            } else if ([type isEqualToString:NSFileTypeDirectory]) {
                [array addObject:@{
                    @"path": [[relativePath stringByAppendingPathComponent:item] stringByAppendingString:@"/"],
                    @"name": item
                }];
            }
        }
    }

    return [GCDWebServerDataResponse responseWithJSONObject:array];
}

- (GCDWebServerResponse *)downloadFile:(GCDWebServerRequest *)request {
    NSString *const relativePath = [request query][@"path"];
    NSString *const absolutePath = [_uploadDirectory stringByAppendingPathComponent:GCDWebServerNormalizePath(relativePath)];
    BOOL isDirectory = NO;

    if (![[NSFileManager defaultManager] fileExistsAtPath:absolutePath isDirectory:&isDirectory]) {
        return [GCDWebServerErrorResponse responseWithClientError:kGCDWebServerHTTPStatusCode_NotFound message:@"\"%@\" does not exist", relativePath];
    }

    if (isDirectory) {
        return [GCDWebServerErrorResponse responseWithClientError:kGCDWebServerHTTPStatusCode_BadRequest message:@"\"%@\" is a directory", relativePath];
    }

    NSString *const fileName = [absolutePath lastPathComponent];

    if (([fileName hasPrefix:@"."] && !_allowHiddenItems) || ![self _checkFileExtension:fileName]) {
        return [GCDWebServerErrorResponse responseWithClientError:kGCDWebServerHTTPStatusCode_Forbidden message:@"Downlading file name \"%@\" is not allowed", fileName];
    }

    if ([self.delegate respondsToSelector:@selector(webUploader:didDownloadFileAtPath:)]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.delegate webUploader:self didDownloadFileAtPath:absolutePath];
        });
    }

    return [GCDWebServerFileResponse responseWithFile:absolutePath isAttachment:YES];
}

- (GCDWebServerResponse *)uploadFile:(GCDWebServerMultiPartFormRequest *)request {
    NSRange range = [request.headers[@"Accept"] rangeOfString:@"application/json" options:NSCaseInsensitiveSearch];
    NSString *const contentType = (range.location != NSNotFound ? @"application/json" : @"text/plain; charset=utf-8");  // Required when using iFrame transport (see https://github.com/blueimp/jQuery-File-Upload/wiki/Setup)

    GCDWebServerMultiPartFile *const file = [request firstFileForControlName:@"files[]"];

    if ((!_allowHiddenItems && [file.fileName hasPrefix:@"."]) || ![self _checkFileExtension:file.fileName]) {
        return [GCDWebServerErrorResponse responseWithClientError:kGCDWebServerHTTPStatusCode_Forbidden message:@"Uploaded file name \"%@\" is not allowed", file.fileName];
    }

    NSString *const relativePath = [[request firstArgumentForControlName:@"path"] string];
    NSString *const absolutePath = [self _uniquePathForPath:[[_uploadDirectory stringByAppendingPathComponent:GCDWebServerNormalizePath(relativePath)] stringByAppendingPathComponent:file.fileName]];

    if (![self shouldUploadFileAtPath:absolutePath withTemporaryFile:file.temporaryPath]) {
        return [GCDWebServerErrorResponse responseWithClientError:kGCDWebServerHTTPStatusCode_Forbidden message:@"Uploading file \"%@\" to \"%@\" is not permitted", file.fileName, relativePath];
    }

    NSError *error = nil;

    if (![[NSFileManager defaultManager] moveItemAtPath:file.temporaryPath toPath:absolutePath error:&error]) {
        return [GCDWebServerErrorResponse responseWithServerError:kGCDWebServerHTTPStatusCode_InternalServerError underlyingError:error message:@"Failed moving uploaded file to \"%@\"", relativePath];
    }

    if ([self.delegate respondsToSelector:@selector(webUploader:didUploadFileAtPath:)]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.delegate webUploader:self didUploadFileAtPath:absolutePath];
        });
    }

    NSString *const uploadedRelativePath = [absolutePath substringFromIndex:_uploadDirectory.length];
    [self _broadcastSSEEvent:@"change" data:@{@"type": @"upload", @"path": uploadedRelativePath}];

    return [GCDWebServerDataResponse responseWithJSONObject:@{} contentType:contentType];
}

- (GCDWebServerResponse *)moveItem:(GCDWebServerURLEncodedFormRequest *)request {
    NSString *const oldRelativePath = request.arguments[@"oldPath"];
    NSString *const oldAbsolutePath = [_uploadDirectory stringByAppendingPathComponent:GCDWebServerNormalizePath(oldRelativePath)];
    BOOL isDirectory = NO;

    if (![[NSFileManager defaultManager] fileExistsAtPath:oldAbsolutePath isDirectory:&isDirectory]) {
        return [GCDWebServerErrorResponse responseWithClientError:kGCDWebServerHTTPStatusCode_NotFound message:@"\"%@\" does not exist", oldRelativePath];
    }

    NSString *const oldItemName = [oldAbsolutePath lastPathComponent];

    if ((!_allowHiddenItems && [oldItemName hasPrefix:@"."]) || (!isDirectory && ![self _checkFileExtension:oldItemName])) {
        return [GCDWebServerErrorResponse responseWithClientError:kGCDWebServerHTTPStatusCode_Forbidden message:@"Moving from item name \"%@\" is not allowed", oldItemName];
    }

    NSString *const newRelativePath = request.arguments[@"newPath"];
    NSString *const newAbsolutePath = [self _uniquePathForPath:[_uploadDirectory stringByAppendingPathComponent:GCDWebServerNormalizePath(newRelativePath)]];

    NSString *const newItemName = [newAbsolutePath lastPathComponent];

    if ((!_allowHiddenItems && [newItemName hasPrefix:@"."]) || (!isDirectory && ![self _checkFileExtension:newItemName])) {
        return [GCDWebServerErrorResponse responseWithClientError:kGCDWebServerHTTPStatusCode_Forbidden message:@"Moving to item name \"%@\" is not allowed", newItemName];
    }

    if (![self shouldMoveItemFromPath:oldAbsolutePath toPath:newAbsolutePath]) {
        return [GCDWebServerErrorResponse responseWithClientError:kGCDWebServerHTTPStatusCode_Forbidden message:@"Moving \"%@\" to \"%@\" is not permitted", oldRelativePath, newRelativePath];
    }

    NSError *error = nil;

    if (![[NSFileManager defaultManager] moveItemAtPath:oldAbsolutePath toPath:newAbsolutePath error:&error]) {
        return [GCDWebServerErrorResponse responseWithServerError:kGCDWebServerHTTPStatusCode_InternalServerError underlyingError:error message:@"Failed moving \"%@\" to \"%@\"", oldRelativePath, newRelativePath];
    }

    if ([self.delegate respondsToSelector:@selector(webUploader:didMoveItemFromPath:toPath:)]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.delegate webUploader:self didMoveItemFromPath:oldAbsolutePath toPath:newAbsolutePath];
        });
    }

    NSString *const movedOldRelativePath = [oldAbsolutePath substringFromIndex:_uploadDirectory.length];
    NSString *const movedNewRelativePath = [newAbsolutePath substringFromIndex:_uploadDirectory.length];
    [self _broadcastSSEEvent:@"change" data:@{@"type": @"move", @"oldPath": movedOldRelativePath, @"newPath": movedNewRelativePath}];

    return [GCDWebServerDataResponse responseWithJSONObject:@{}];
}

- (GCDWebServerResponse *)deleteItem:(GCDWebServerURLEncodedFormRequest *)request {
    NSString *const relativePath = request.arguments[@"path"];
    NSString *const absolutePath = [_uploadDirectory stringByAppendingPathComponent:GCDWebServerNormalizePath(relativePath)];
    BOOL isDirectory = NO;

    if (![[NSFileManager defaultManager] fileExistsAtPath:absolutePath isDirectory:&isDirectory]) {
        return [GCDWebServerErrorResponse responseWithClientError:kGCDWebServerHTTPStatusCode_NotFound message:@"\"%@\" does not exist", relativePath];
    }

    NSString *const itemName = [absolutePath lastPathComponent];

    if (([itemName hasPrefix:@"."] && !_allowHiddenItems) || (!isDirectory && ![self _checkFileExtension:itemName])) {
        return [GCDWebServerErrorResponse responseWithClientError:kGCDWebServerHTTPStatusCode_Forbidden message:@"Deleting item name \"%@\" is not allowed", itemName];
    }

    if (![self shouldDeleteItemAtPath:absolutePath]) {
        return [GCDWebServerErrorResponse responseWithClientError:kGCDWebServerHTTPStatusCode_Forbidden message:@"Deleting \"%@\" is not permitted", relativePath];
    }

    NSError *error = nil;

    if (![[NSFileManager defaultManager] removeItemAtPath:absolutePath error:&error]) {
        return [GCDWebServerErrorResponse responseWithServerError:kGCDWebServerHTTPStatusCode_InternalServerError underlyingError:error message:@"Failed deleting \"%@\"", relativePath];
    }

    if ([self.delegate respondsToSelector:@selector(webUploader:didDeleteItemAtPath:)]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.delegate webUploader:self didDeleteItemAtPath:absolutePath];
        });
    }

    [self _broadcastSSEEvent:@"change" data:@{@"type": @"delete", @"path": relativePath}];

    return [GCDWebServerDataResponse responseWithJSONObject:@{}];
}

- (GCDWebServerResponse *)createDirectory:(GCDWebServerURLEncodedFormRequest *)request {
    NSString *const relativePath = request.arguments[@"path"];
    NSString *const absolutePath = [self _uniquePathForPath:[_uploadDirectory stringByAppendingPathComponent:GCDWebServerNormalizePath(relativePath)]];

    NSString *const directoryName = [absolutePath lastPathComponent];

    if (!_allowHiddenItems && [directoryName hasPrefix:@"."]) {
        return [GCDWebServerErrorResponse responseWithClientError:kGCDWebServerHTTPStatusCode_Forbidden message:@"Creating directory name \"%@\" is not allowed", directoryName];
    }

    if (![self shouldCreateDirectoryAtPath:absolutePath]) {
        return [GCDWebServerErrorResponse responseWithClientError:kGCDWebServerHTTPStatusCode_Forbidden message:@"Creating directory \"%@\" is not permitted", relativePath];
    }

    NSError *error = nil;

    if (![[NSFileManager defaultManager] createDirectoryAtPath:absolutePath withIntermediateDirectories:NO attributes:nil error:&error]) {
        return [GCDWebServerErrorResponse responseWithServerError:kGCDWebServerHTTPStatusCode_InternalServerError underlyingError:error message:@"Failed creating directory \"%@\"", relativePath];
    }

    if ([self.delegate respondsToSelector:@selector(webUploader:didCreateDirectoryAtPath:)]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.delegate webUploader:self didCreateDirectoryAtPath:absolutePath];
        });
    }

    NSString *const createdRelativePath = [[absolutePath substringFromIndex:_uploadDirectory.length] stringByAppendingString:@"/"];
    [self _broadcastSSEEvent:@"change" data:@{@"type": @"create", @"path": createdRelativePath}];

    return [GCDWebServerDataResponse responseWithJSONObject:@{}];
}

@end

@implementation GCDWebUploader (Subclassing)

- (BOOL)shouldUploadFileAtPath:(NSString *)path withTemporaryFile:(NSString *)tempPath {
    return YES;
}

- (BOOL)shouldMoveItemFromPath:(NSString *)fromPath toPath:(NSString *)toPath {
    return YES;
}

- (BOOL)shouldDeleteItemAtPath:(NSString *)path {
    return YES;
}

- (BOOL)shouldCreateDirectoryAtPath:(NSString *)path {
    return YES;
}

@end
