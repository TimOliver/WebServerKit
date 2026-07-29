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

@implementation WSKDataResponse {
    NSData *_data;
    BOOL _done;
}

@dynamic contentType;

+ (instancetype)responseWithData:(NSData *)data contentType:(NSString *)type {
    return [(WSKDataResponse *)[[self class] alloc] initWithData:data contentType:type];
}

- (instancetype)initWithData:(NSData *)data contentType:(NSString *)type {
    if ((self = [super init])) {
        _data = data;

        self.contentType = type;
        self.contentLength = data.length;
    }

    return self;
}

- (NSData *)readData:(NSError **)error {
    NSData *data;

    if (_done) {
        data = [NSData data];
    } else {
        data = _data;
        _done = YES;
    }

    return data;
}

- (NSString *)description {
    NSMutableString *description = [NSMutableString stringWithString:[super description]];

    [description appendString:@"\n\n"];
    [description appendString:WSKDescribeData(_data, self.contentType)];
    return description;
}

@end

@implementation WSKDataResponse (Extensions)

+ (instancetype)responseWithText:(NSString *)text {
    return [(WSKDataResponse *)[self alloc] initWithText:text];
}

+ (instancetype)responseWithHTML:(NSString *)html {
    return [(WSKDataResponse *)[self alloc] initWithHTML:html];
}

+ (instancetype)responseWithHTMLTemplate:(NSString *)path variables:(NSDictionary<NSString *, NSString *> *)variables {
    return [(WSKDataResponse *)[self alloc] initWithHTMLTemplate:path variables:variables];
}

+ (instancetype)responseWithJSONObject:(id)object {
    return [(WSKDataResponse *)[self alloc] initWithJSONObject:object];
}

+ (instancetype)responseWithJSONObject:(id)object contentType:(NSString *)type {
    return [(WSKDataResponse *)[self alloc] initWithJSONObject:object contentType:type];
}

- (instancetype)initWithText:(NSString *)text {
    NSData *const data = [text dataUsingEncoding:NSUTF8StringEncoding];

    if (data == nil) {
        // Not WSK_DNOT_REACHED(): the text is whatever the caller reflected into the
        // response — often request-derived — and this method is already declared as
        // returning nil on failure, so a bad string must not abort a Debug build.
        WSK_LOG_ERROR(@"Failed encoding text response as UTF-8");
        return nil;
    }

    return [self initWithData:data contentType:@"text/plain; charset=utf-8"];
}

- (instancetype)initWithHTML:(NSString *)html {
    NSData *const data = [html dataUsingEncoding:NSUTF8StringEncoding];

    if (data == nil) {
        // As above, and reachable with a nil argument from -initWithHTMLTemplate: below
        // whenever the template cannot be read — an ordinary environment condition (a
        // missing or non-UTF-8 bundle resource) that any remote request would then hit.
        WSK_LOG_ERROR(@"Failed encoding HTML response as UTF-8");
        return nil;
    }

    return [self initWithData:data contentType:@"text/html; charset=utf-8"];
}

- (instancetype)initWithHTMLTemplate:(NSString *)path variables:(NSDictionary<NSString *, NSString *> *)variables {
    NSMutableString *const html = [[NSMutableString alloc] initWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];

    if (html == nil) {
        WSK_LOG_ERROR(@"Failed reading HTML template \"%@\"", path);
        return nil;
    }

    [variables enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *value, BOOL *stop) {
        [html replaceOccurrencesOfString:[NSString stringWithFormat:@"%%%@%%", key] withString:value options:0 range:NSMakeRange(0, html.length)];
    }];
    return [self initWithHTML:html];
}

- (instancetype)initWithJSONObject:(id)object {
    return [self initWithJSONObject:object contentType:@"application/json"];
}

- (instancetype)initWithJSONObject:(id)object contentType:(NSString *)type {
    // +dataWithJSONObject: RAISES NSInvalidArgumentException for an object it cannot serialise
    // rather than returning nil, so the nil check below could never fire and the exception
    // escaped instead — and nothing in Sources/ catches one, so a host-app handler returning
    // -responseWithJSONObject: for a dictionary holding an NSDate, an NSURL or a NAN terminated
    // the process. That factory is declared `nullable`, so a caller writing `resp ?: fallback`
    // reasonably believes it has handled the failure. Ask first, exactly as -initWithText: does
    // for a string it cannot encode.
    if (![NSJSONSerialization isValidJSONObject:object]) {
        WSK_LOG_ERROR(@"Failed encoding JSON response: not a valid JSON object");
        return nil;
    }

    NSData *const data = [NSJSONSerialization dataWithJSONObject:object options:0 error:NULL];

    if (data == nil) {
        WSK_LOG_ERROR(@"Failed encoding JSON response");
        return nil;
    }

    return [self initWithData:data contentType:type];
}

@end
