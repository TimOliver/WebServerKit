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
#error WSKWebServer requires ARC
#endif

#import "WSKPrivate.h"

@implementation WSKErrorResponse

+ (instancetype)responseWithClientError:(WSKClientErrorHTTPStatusCode)errorCode message:(NSString *)format, ... {
    WSK_DCHECK(((NSInteger)errorCode >= 400) && ((NSInteger)errorCode < 500));
    va_list arguments;
    va_start(arguments, format);
    WSKErrorResponse *const response = [(WSKErrorResponse *)[self alloc] initWithStatusCode:errorCode underlyingError:nil messageFormat:format arguments:arguments];
    va_end(arguments);
    return response;
}

+ (instancetype)responseWithServerError:(WSKServerErrorHTTPStatusCode)errorCode message:(NSString *)format, ... {
    WSK_DCHECK(((NSInteger)errorCode >= 500) && ((NSInteger)errorCode < 600));
    va_list arguments;
    va_start(arguments, format);
    WSKErrorResponse *const response = [(WSKErrorResponse *)[self alloc] initWithStatusCode:errorCode underlyingError:nil messageFormat:format arguments:arguments];
    va_end(arguments);
    return response;
}

+ (instancetype)responseWithClientError:(WSKClientErrorHTTPStatusCode)errorCode underlyingError:(NSError *)underlyingError message:(NSString *)format, ... {
    WSK_DCHECK(((NSInteger)errorCode >= 400) && ((NSInteger)errorCode < 500));
    va_list arguments;
    va_start(arguments, format);
    WSKErrorResponse *const response = [(WSKErrorResponse *)[self alloc] initWithStatusCode:errorCode underlyingError:underlyingError messageFormat:format arguments:arguments];
    va_end(arguments);
    return response;
}

+ (instancetype)responseWithServerError:(WSKServerErrorHTTPStatusCode)errorCode underlyingError:(NSError *)underlyingError message:(NSString *)format, ... {
    WSK_DCHECK(((NSInteger)errorCode >= 500) && ((NSInteger)errorCode < 600));
    va_list arguments;
    va_start(arguments, format);
    WSKErrorResponse *const response = [(WSKErrorResponse *)[self alloc] initWithStatusCode:errorCode underlyingError:underlyingError messageFormat:format arguments:arguments];
    va_end(arguments);
    return response;
}

static inline NSString *_EscapeHTMLString(NSString *string) {
    // The (attacker-influenced) message and underlying-error text are reflected into
    // an HTML body served as text/html, so every HTML metacharacter must be escaped —
    // not just quotes. Mirrors the directory-listing escaper in WSKWebServer.m; "&"
    // must be replaced first so the entities we introduce are not re-escaped.
    NSMutableString *const escaped = [string mutableCopy];
    [escaped replaceOccurrencesOfString:@"&" withString:@"&amp;" options:0 range:NSMakeRange(0, escaped.length)];
    [escaped replaceOccurrencesOfString:@"<" withString:@"&lt;" options:0 range:NSMakeRange(0, escaped.length)];
    [escaped replaceOccurrencesOfString:@">" withString:@"&gt;" options:0 range:NSMakeRange(0, escaped.length)];
    [escaped replaceOccurrencesOfString:@"\"" withString:@"&quot;" options:0 range:NSMakeRange(0, escaped.length)];
    [escaped replaceOccurrencesOfString:@"'" withString:@"&#39;" options:0 range:NSMakeRange(0, escaped.length)];
    return escaped;
}

// An error page is a diagnostic, not a data channel — nothing a client can act on
// lives past the first line. Callers do reflect request-controlled text into it
// (WebDAV echoes an unparseable request body verbatim), and _EscapeHTMLString expands
// each `"` sixfold through UTF-16 NSMutableString passes, so an unbounded message
// turned a single 16 MB request into a 96 MB response and ~540 MB of transient
// memory. Clamp every reflected string here, at the one place they all pass through.
#define kMaxReflectedMessageLength 1024

static inline NSString *_ClampReflectedString(NSString *string) {
    if (string.length <= kMaxReflectedMessageLength) {
        return string;
    }

    // Cut on a composed-character boundary so a truncated string can never end in
    // half a surrogate pair.
    NSRange const boundary = [string rangeOfComposedCharacterSequenceAtIndex:kMaxReflectedMessageLength];
    return [[string substringToIndex:boundary.location] stringByAppendingString:@"…"];
}

- (instancetype)initWithStatusCode:(NSInteger)statusCode underlyingError:(NSError *)underlyingError messageFormat:(NSString *)format arguments:(va_list)arguments {
    NSString *const message = _ClampReflectedString([[NSString alloc] initWithFormat:format arguments:arguments]);
    NSString *const title = [NSString stringWithFormat:@"HTTP Error %i", (int)statusCode];
    NSString *const error = underlyingError ? [NSString stringWithFormat:@"[%@] %@ (%li)", _EscapeHTMLString(_ClampReflectedString(underlyingError.domain)), _EscapeHTMLString(_ClampReflectedString(underlyingError.localizedDescription)), (long)underlyingError.code] : @"";
    NSString *const html = [NSString stringWithFormat:@"<!DOCTYPE html><html lang=\"en\"><head><meta charset=\"utf-8\"><title>%@</title></head><body><h1>%@: %@</h1><h3>%@</h3></body></html>",
                                                      title,
                                                      title,
                                                      _EscapeHTMLString(message),
                                                      error];

    if ((self = [self initWithHTML:html])) {
        self.statusCode = statusCode;
    }

    return self;
}

- (instancetype)initWithClientError:(WSKClientErrorHTTPStatusCode)errorCode message:(NSString *)format, ... {
    WSK_DCHECK(((NSInteger)errorCode >= 400) && ((NSInteger)errorCode < 500));
    va_list arguments;
    va_start(arguments, format);
    self = [self initWithStatusCode:errorCode underlyingError:nil messageFormat:format arguments:arguments];
    va_end(arguments);
    return self;
}

- (instancetype)initWithServerError:(WSKServerErrorHTTPStatusCode)errorCode message:(NSString *)format, ... {
    WSK_DCHECK(((NSInteger)errorCode >= 500) && ((NSInteger)errorCode < 600));
    va_list arguments;
    va_start(arguments, format);
    self = [self initWithStatusCode:errorCode underlyingError:nil messageFormat:format arguments:arguments];
    va_end(arguments);
    return self;
}

- (instancetype)initWithClientError:(WSKClientErrorHTTPStatusCode)errorCode underlyingError:(NSError *)underlyingError message:(NSString *)format, ... {
    WSK_DCHECK(((NSInteger)errorCode >= 400) && ((NSInteger)errorCode < 500));
    va_list arguments;
    va_start(arguments, format);
    self = [self initWithStatusCode:errorCode underlyingError:underlyingError messageFormat:format arguments:arguments];
    va_end(arguments);
    return self;
}

- (instancetype)initWithServerError:(WSKServerErrorHTTPStatusCode)errorCode underlyingError:(NSError *)underlyingError message:(NSString *)format, ... {
    WSK_DCHECK(((NSInteger)errorCode >= 500) && ((NSInteger)errorCode < 600));
    va_list arguments;
    va_start(arguments, format);
    self = [self initWithStatusCode:errorCode underlyingError:underlyingError messageFormat:format arguments:arguments];
    va_end(arguments);
    return self;
}

@end
