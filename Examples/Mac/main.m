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

#import <libgen.h>

#import "SRVDAVServer.h"
#import "SRVServer.h"
#import "SRVDataRequest.h"
#import "SRVDataResponse.h"
#import "SRVMultiPartFormRequest.h"
#import "SRVStreamedResponse.h"
#import "SRVURLEncodedFormRequest.h"
#import "SRVUploader.h"

#ifndef __SERVE_ENABLE_TESTING__
#error __SERVE_ENABLE_TESTING__ must be defined
#endif

typedef enum {
    kMode_WebServer = 0,
    kMode_HTMLPage,
    kMode_HTMLForm,
    kMode_HTMLFileUpload,
    kMode_WebDAV,
    kMode_WebUploader,
    kMode_StreamingResponse,
    kMode_AsyncResponse
} Mode;

@interface Delegate : NSObject <SRVDelegate, SRVDAVServerDelegate, SRVUploaderDelegate>
@end

@implementation Delegate

- (void)_logDelegateCall:(SEL)selector {
    fprintf(stdout, "<DELEGATE METHOD \"%s\" CALLED>\n", [NSStringFromSelector(selector) UTF8String]);
}

- (void)webServerDidStart:(SRVServer *)server {
    [self _logDelegateCall:_cmd];
}

- (void)webServerDidCompleteBonjourRegistration:(SRVServer *)server {
    [self _logDelegateCall:_cmd];
}

- (void)webServerDidUpdateNATPortMapping:(SRVServer *)server {
    [self _logDelegateCall:_cmd];
}

- (void)webServerDidConnect:(SRVServer *)server {
    [self _logDelegateCall:_cmd];
}

- (void)webServerDidDisconnect:(SRVServer *)server {
    [self _logDelegateCall:_cmd];
}

- (void)webServerDidStop:(SRVServer *)server {
    [self _logDelegateCall:_cmd];
}

- (void)davServer:(SRVDAVServer *)server didDownloadFileAtPath:(NSString *)path {
    [self _logDelegateCall:_cmd];
}

- (void)davServer:(SRVDAVServer *)server didUploadFileAtPath:(NSString *)path {
    [self _logDelegateCall:_cmd];
}

- (void)davServer:(SRVDAVServer *)server didMoveItemFromPath:(NSString *)fromPath toPath:(NSString *)toPath {
    [self _logDelegateCall:_cmd];
}

- (void)davServer:(SRVDAVServer *)server didCopyItemFromPath:(NSString *)fromPath toPath:(NSString *)toPath {
    [self _logDelegateCall:_cmd];
}

- (void)davServer:(SRVDAVServer *)server didDeleteItemAtPath:(NSString *)path {
    [self _logDelegateCall:_cmd];
}

- (void)davServer:(SRVDAVServer *)server didCreateDirectoryAtPath:(NSString *)path {
    [self _logDelegateCall:_cmd];
}

- (void)webUploader:(SRVUploader *)uploader didDownloadFileAtPath:(NSString *)path {
    [self _logDelegateCall:_cmd];
}

- (void)webUploader:(SRVUploader *)uploader didUploadFileAtPath:(NSString *)path {
    [self _logDelegateCall:_cmd];
}

- (void)webUploader:(SRVUploader *)uploader didMoveItemFromPath:(NSString *)fromPath toPath:(NSString *)toPath {
    [self _logDelegateCall:_cmd];
}

- (void)webUploader:(SRVUploader *)uploader didDeleteItemAtPath:(NSString *)path {
    [self _logDelegateCall:_cmd];
}

- (void)webUploader:(SRVUploader *)uploader didCreateDirectoryAtPath:(NSString *)path {
    [self _logDelegateCall:_cmd];
}

@end

int main(int argc, const char *argv[]) {
    int result = -1;

    @autoreleasepool {
        Mode mode = kMode_WebServer;
        BOOL recording = NO;
        NSString *rootDirectory = NSHomeDirectory();
        NSString *testDirectory = nil;
        NSString *authenticationMethod = nil;
        NSString *authenticationRealm = nil;
        NSString *authenticationUser = nil;
        NSString *authenticationPassword = nil;
        BOOL bindToLocalhost = NO;
        BOOL requestNATPortMapping = NO;

        if (argc == 1) {
            fprintf(stdout, "Usage: %s [-mode webServer | htmlPage | htmlForm | htmlFileUpload | webDAV | webUploader | streamingResponse | asyncResponse] [-record] [-root directory] [-tests directory] [-authenticationMethod Basic | Digest] [-authenticationRealm realm] [-authenticationUser user] [-authenticationPassword password] [--localhost]\n\n", basename((char *)argv[0]));
        } else {
            for (int i = 1; i < argc; ++i) {
                if (argv[i][0] != '-') {
                    continue;
                }

                if (!strcmp(argv[i], "-mode") && (i + 1 < argc)) {
                    ++i;

                    if (!strcmp(argv[i], "webServer")) {
                        mode = kMode_WebServer;
                    } else if (!strcmp(argv[i], "htmlPage")) {
                        mode = kMode_HTMLPage;
                    } else if (!strcmp(argv[i], "htmlForm")) {
                        mode = kMode_HTMLForm;
                    } else if (!strcmp(argv[i], "htmlFileUpload")) {
                        mode = kMode_HTMLFileUpload;
                    } else if (!strcmp(argv[i], "webDAV")) {
                        mode = kMode_WebDAV;
                    } else if (!strcmp(argv[i], "webUploader")) {
                        mode = kMode_WebUploader;
                    } else if (!strcmp(argv[i], "streamingResponse")) {
                        mode = kMode_StreamingResponse;
                    } else if (!strcmp(argv[i], "asyncResponse")) {
                        mode = kMode_AsyncResponse;
                    }
                } else if (!strcmp(argv[i], "-record")) {
                    recording = YES;
                } else if (!strcmp(argv[i], "-root") && (i + 1 < argc)) {
                    ++i;
                    rootDirectory = [[NSFileManager defaultManager] stringWithFileSystemRepresentation:argv[i] length:strlen(argv[i])];
                } else if (!strcmp(argv[i], "-tests") && (i + 1 < argc)) {
                    ++i;
                    testDirectory = [[NSFileManager defaultManager] stringWithFileSystemRepresentation:argv[i] length:strlen(argv[i])];
                } else if (!strcmp(argv[i], "-authenticationMethod") && (i + 1 < argc)) {
                    ++i;
                    authenticationMethod = [NSString stringWithUTF8String:argv[i]];
                } else if (!strcmp(argv[i], "-authenticationRealm") && (i + 1 < argc)) {
                    ++i;
                    authenticationRealm = [NSString stringWithUTF8String:argv[i]];
                } else if (!strcmp(argv[i], "-authenticationUser") && (i + 1 < argc)) {
                    ++i;
                    authenticationUser = [NSString stringWithUTF8String:argv[i]];
                } else if (!strcmp(argv[i], "-authenticationPassword") && (i + 1 < argc)) {
                    ++i;
                    authenticationPassword = [NSString stringWithUTF8String:argv[i]];
                } else if (!strcmp(argv[i], "--localhost")) {
                    bindToLocalhost = YES;
                } else if (!strcmp(argv[i], "--nat")) {
                    requestNATPortMapping = YES;
                }
            }
        }

        SRVServer *webServer = nil;
        switch (mode) {
        // Simply serve contents of home directory
        case kMode_WebServer: {
            fprintf(stdout, "Running in Web Server mode from \"%s\"\n", [rootDirectory UTF8String]);
            webServer = [[SRVServer alloc] init];
            [webServer addGETHandlerForBasePath:@"/" directoryPath:rootDirectory indexFilename:nil cacheAge:0 allowRangeRequests:YES];
            break;
        }

        // Renders a HTML page
        case kMode_HTMLPage: {
            fprintf(stdout, "Running in HTML Page mode\n");
            webServer = [[SRVServer alloc] init];
            [webServer addDefaultHandlerForMethod:@"GET"
                                     requestClass:[SRVRequest class]
                                     processBlock:^SRVResponse *(SRVRequest *request) {
                                         return [SRVDataResponse responseWithHTML:@"<html><body><p>Hello World</p></body></html>"];
                                     }];
            break;
        }

        // Implements an HTML form
        case kMode_HTMLForm: {
            fprintf(stdout, "Running in HTML Form mode\n");
            webServer = [[SRVServer alloc] init];
            [webServer addHandlerForMethod:@"GET"
                                      path:@"/"
                              requestClass:[SRVRequest class]
                              processBlock:^SRVResponse *(SRVRequest *request) {
                                  NSString *html = @" \
            <html><body> \
              <form name=\"input\" action=\"/\" method=\"post\" enctype=\"application/x-www-form-urlencoded\"> \
              Value: <input type=\"text\" name=\"value\"> \
              <input type=\"submit\" value=\"Submit\"> \
              </form> \
            </body></html> \
          ";
                                  return [SRVDataResponse responseWithHTML:html];
                              }];
            [webServer addHandlerForMethod:@"POST"
                                      path:@"/"
                              requestClass:[SRVURLEncodedFormRequest class]
                              processBlock:^SRVResponse *(SRVRequest *request) {
                                  NSString *value = [[(SRVURLEncodedFormRequest *)request arguments] objectForKey:@"value"];
                                  NSString *html = [NSString stringWithFormat:@"<html><body><p>%@</p></body></html>", value];
                                  return [SRVDataResponse responseWithHTML:html];
                              }];
            break;
        }

        // Implements HTML file upload
        case kMode_HTMLFileUpload: {
            fprintf(stdout, "Running in HTML File Upload mode\n");
            webServer = [[SRVServer alloc] init];
            NSString *formHTML = @" \
          <form name=\"input\" action=\"/\" method=\"post\" enctype=\"multipart/form-data\"> \
          <input type=\"hidden\" name=\"secret\" value=\"42\"> \
          <input type=\"file\" name=\"files\" multiple><br/> \
          <input type=\"submit\" value=\"Submit\"> \
          </form> \
        ";
            [webServer addHandlerForMethod:@"GET"
                                      path:@"/"
                              requestClass:[SRVRequest class]
                              processBlock:^SRVResponse *(SRVRequest *request) {
                                  NSString *html = [NSString stringWithFormat:@"<html><body>%@</body></html>", formHTML];
                                  return [SRVDataResponse responseWithHTML:html];
                              }];
            [webServer addHandlerForMethod:@"POST"
                                      path:@"/"
                              requestClass:[SRVMultiPartFormRequest class]
                              processBlock:^SRVResponse *(SRVRequest *request) {
                                  NSMutableString *string = [NSMutableString string];

                                  for (SRVMultiPartArgument *argument in [(SRVMultiPartFormRequest *)request arguments]) {
                                      [string appendFormat:@"%@ = %@<br>", argument.controlName, argument.string];
                                  }

                                  for (SRVMultiPartFile *file in [(SRVMultiPartFormRequest *)request files]) {
                                      NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:file.temporaryPath error:NULL];
                                      [string appendFormat:@"%@ = &quot;%@&quot; (%@ | %llu %@)<br>", file.controlName, file.fileName, file.mimeType, attributes.fileSize >= 1000 ? attributes.fileSize / 1000 : attributes.fileSize, attributes.fileSize >= 1000 ? @"KB" : @"Bytes"];
                                  }

                                  NSString *html = [NSString stringWithFormat:@"<html><body><p>%@</p><hr>%@</body></html>", string, formHTML];
                                  return [SRVDataResponse responseWithHTML:html];
                              }];
            break;
        }

        // Serve home directory through WebDAV
        case kMode_WebDAV: {
            fprintf(stdout, "Running in WebDAV mode from \"%s\"\n", [rootDirectory UTF8String]);
            webServer = [[SRVDAVServer alloc] initWithUploadDirectory:rootDirectory];
            break;
        }

        // Serve home directory through web uploader
        case kMode_WebUploader: {
            fprintf(stdout, "Running in Web Uploader mode from \"%s\"\n", [rootDirectory UTF8String]);
            webServer = [[SRVUploader alloc] initWithUploadDirectory:rootDirectory];
            break;
        }

        // Test streaming responses
        case kMode_StreamingResponse: {
            fprintf(stdout, "Running in Streaming Response mode\n");
            webServer = [[SRVServer alloc] init];
            [webServer addHandlerForMethod:@"GET"
                                      path:@"/sync"
                              requestClass:[SRVRequest class]
                              processBlock:^SRVResponse *(SRVRequest *request) {
                                  __block int countDown = 10;
                                  return [SRVStreamedResponse responseWithContentType:@"text/plain"
                                                                                   streamBlock:^NSData *(NSError **error) {
                                                                                       usleep(100 * 1000);

                                                                                       if (countDown) {
                                                                                           return [[NSString stringWithFormat:@"%i\n", countDown--] dataUsingEncoding:NSUTF8StringEncoding];
                                                                                       } else {
                                                                                           return [NSData data];
                                                                                       }
                                                                                   }];
                              }];
            [webServer addHandlerForMethod:@"GET"
                                      path:@"/async"
                              requestClass:[SRVRequest class]
                              processBlock:^SRVResponse *(SRVRequest *request) {
                                  __block int countDown = 10;
                                  return [SRVStreamedResponse responseWithContentType:@"text/plain"
                                                                              asyncStreamBlock:^(SRVBodyReaderCompletionBlock completionBlock) {
                                                                                  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                                                                                      NSData *data = countDown ? [[NSString stringWithFormat:@"%i\n", countDown--] dataUsingEncoding:NSUTF8StringEncoding] : [NSData data];
                                                                                      completionBlock(data, nil);
                                                                                  });
                                                                              }];
                              }];
            break;
        }

        // Test async responses
        case kMode_AsyncResponse: {
            fprintf(stdout, "Running in Async Response mode\n");
            webServer = [[SRVServer alloc] init];
            [webServer addHandlerForMethod:@"GET"
                                      path:@"/async"
                              requestClass:[SRVRequest class]
                         asyncProcessBlock:^(SRVRequest *request, SRVCompletionBlock completionBlock) {
                             dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                                 SRVDataResponse *response = [SRVDataResponse responseWithData:(NSData *)[@"Hello World!" dataUsingEncoding:NSUTF8StringEncoding] contentType:@"text/plain"];
                                 completionBlock(response);
                             });
                         }];
            [webServer addHandlerForMethod:@"GET"
                                      path:@"/async2"
                              requestClass:[SRVRequest class]
                         asyncProcessBlock:^(SRVRequest *request, SRVCompletionBlock handlerCompletionBlock) {
                             dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                                 __block int countDown = 10;
                                 SRVStreamedResponse *response = [SRVStreamedResponse responseWithContentType:@"text/plain"
                                                                                                               asyncStreamBlock:^(SRVBodyReaderCompletionBlock readerCompletionBlock) {
                                                                                                                   dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                                                                                                                       NSData *data = countDown ? [[NSString stringWithFormat:@"%i\n", countDown--] dataUsingEncoding:NSUTF8StringEncoding] : [NSData data];
                                                                                                                       readerCompletionBlock(data, nil);
                                                                                                                   });
                                                                                                               }];
                                 handlerCompletionBlock(response);
                             });
                         }];
            break;
        }
        }

        if (webServer) {
            Delegate *delegate = [[Delegate alloc] init];

            if (testDirectory) {
#if DEBUG
                webServer.delegate = delegate;
#endif
                fprintf(stdout, "<RUNNING TESTS FROM \"%s\">\n\n", [testDirectory UTF8String]);
                result = (int)[webServer runTestsWithOptions:@{SRVOption_Port: @8080} inDirectory:testDirectory];
            } else {
                webServer.delegate = delegate;

                if (recording) {
                    fprintf(stdout, "<RECORDING ENABLED>\n");
                    webServer.recordingEnabled = YES;
                }

                fprintf(stdout, "\n");
                NSMutableDictionary *options = [NSMutableDictionary dictionary];
                [options setObject:@8080 forKey:SRVOption_Port];
                [options setObject:@(requestNATPortMapping) forKey:SRVOption_RequestNATPortMapping];
                [options setObject:@(bindToLocalhost) forKey:SRVOption_BindToLocalhost];
                [options setObject:@"" forKey:SRVOption_BonjourName];

                if (authenticationUser && authenticationPassword) {
                    [options setValue:authenticationRealm forKey:SRVOption_AuthenticationRealm];
                    [options setObject:@{authenticationUser: authenticationPassword} forKey:SRVOption_AuthenticationAccounts];

                    if ([authenticationMethod isEqualToString:@"Basic"]) {
                        [options setObject:SRVAuthenticationMethod_Basic forKey:SRVOption_AuthenticationMethod];
                    } else if ([authenticationMethod isEqualToString:@"Digest"]) {
                        [options setObject:SRVAuthenticationMethod_DigestAccess forKey:SRVOption_AuthenticationMethod];
                    }
                }

                if ([webServer runWithOptions:options error:NULL]) {
                    result = 0;
                }
            }

            webServer.delegate = nil;
        }
    }
    return result;
}
