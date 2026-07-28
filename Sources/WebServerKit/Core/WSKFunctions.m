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

#import <TargetConditionals.h>
#if !TARGET_OS_IPHONE
#import <SystemConfiguration/SystemConfiguration.h>
#endif
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <CommonCrypto/CommonDigest.h>
#import <ifaddrs.h>
#import <os/lock.h>
#import <net/if.h>
#import <netdb.h>

#import "WSKPrivate.h"

// Guards every field below. Contended only when a buffer grows, never per byte.
static os_unfair_lock _memoryLock = OS_UNFAIR_LOCK_INIT;
static NSUInteger _memoryReserved = 0;
static NSUInteger _memoryCapacity = kWSKMaxTotalInMemoryLength;
static NSUInteger _memoryPerRequestLimit = kWSKMaxInMemoryBodyLength;
static NSUInteger _memoryDecompressedLimit = kWSKMaxDecompressedBodyLength;

NSUInteger WSKMaxInMemoryBodyLength(void) {
    os_unfair_lock_lock(&_memoryLock);
    NSUInteger value = _memoryPerRequestLimit;
    os_unfair_lock_unlock(&_memoryLock);
    return value;
}

NSUInteger WSKMaxDecompressedBodyLength(void) {
    os_unfair_lock_lock(&_memoryLock);
    NSUInteger value = _memoryDecompressedLimit;
    os_unfair_lock_unlock(&_memoryLock);
    return value;
}

void WSKSetMemoryLimitsForTesting(NSUInteger perRequest, NSUInteger decompressed, NSUInteger total) {
    os_unfair_lock_lock(&_memoryLock);
    _memoryPerRequestLimit = perRequest ? perRequest : (NSUInteger)kWSKMaxInMemoryBodyLength;
    _memoryDecompressedLimit = decompressed ? decompressed : (NSUInteger)kWSKMaxDecompressedBodyLength;
    _memoryCapacity = total ? total : (NSUInteger)kWSKMaxTotalInMemoryLength;
    os_unfair_lock_unlock(&_memoryLock);
}

NSUInteger WSKReservedMemoryLength(void) {
    os_unfair_lock_lock(&_memoryLock);
    NSUInteger value = _memoryReserved;
    os_unfair_lock_unlock(&_memoryLock);
    return value;
}

@implementation WSKMemoryReservation {
    NSUInteger _bytes;
}

- (BOOL)reserveBytes:(NSUInteger)bytes {
    BOOL granted = YES;
    os_unfair_lock_lock(&_memoryLock);

    if (bytes > _bytes) {
        NSUInteger increase = bytes - _bytes;

        // Refuse rather than partially grant: the caller fails the request cleanly, which
        // is the whole point — the alternative is every connection buffering a little more
        // until the process is killed.
        if (_memoryReserved + increase > _memoryCapacity) {
            granted = NO;
        } else {
            _memoryReserved += increase;
            _bytes = bytes;
        }
    } else {
        _memoryReserved -= (_bytes - bytes);
        _bytes = bytes;
    }

    os_unfair_lock_unlock(&_memoryLock);
    return granted;
}

- (void)dealloc {
    os_unfair_lock_lock(&_memoryLock);
    _memoryReserved -= _bytes;  // Cannot underflow: _bytes only ever moves through -reserveBytes:
    os_unfair_lock_unlock(&_memoryLock);
}

@end

static NSDateFormatter *_dateFormatterRFC822 = nil;
static NSDateFormatter *_dateFormatterISO8601 = nil;
static dispatch_queue_t _dateFormatterQueue = NULL;

// TODO: Handle RFC 850 and ANSI C's asctime() format
void WSKInitializeFunctions(void) {
    WSK_DCHECK([NSThread isMainThread]);  // NSDateFormatter should be initialized on main thread

    if (_dateFormatterRFC822 == nil) {
        _dateFormatterRFC822 = [[NSDateFormatter alloc] init];
        _dateFormatterRFC822.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"GMT"];
        _dateFormatterRFC822.dateFormat = @"EEE',' dd MMM yyyy HH':'mm':'ss 'GMT'";
        _dateFormatterRFC822.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US"];
        WSK_DCHECK(_dateFormatterRFC822);
    }

    if (_dateFormatterISO8601 == nil) {
        _dateFormatterISO8601 = [[NSDateFormatter alloc] init];
        _dateFormatterISO8601.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"GMT"];
        _dateFormatterISO8601.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss'+00:00'";
        _dateFormatterISO8601.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US"];
        WSK_DCHECK(_dateFormatterISO8601);
    }

    if (_dateFormatterQueue == NULL) {
        _dateFormatterQueue = dispatch_queue_create(NULL, DISPATCH_QUEUE_SERIAL);
        WSK_DCHECK(_dateFormatterQueue);
    }
}

NSString *WSKNormalizeHeaderValue(NSString *value) {
    if (value) {
        NSRange range = [value rangeOfString:@";"];  // Assume part before ";" separator is case-insensitive

        if (range.location != NSNotFound) {
            value = [[[value substringToIndex:range.location] lowercaseString] stringByAppendingString:[value substringFromIndex:range.location]];
        } else {
            value = [value lowercaseString];
        }
    }

    return value;
}

NSString *WSKTruncateHeaderValue(NSString *value) {
    if (value) {
        NSRange range = [value rangeOfString:@";"];

        if (range.location != NSNotFound) {
            return [value substringToIndex:range.location];
        }
    }

    return value;
}

NSString *WSKExtractHeaderValueParameter(NSString *value, NSString *name) {
    if ((value == nil) || (name.length == 0)) {
        return nil;
    }

    // The parameter name must match at a token boundary. A plain substring search finds
    // "name=" inside "filename=" and "nonce=" inside "cnonce=", returning the wrong
    // parameter whenever a client happens to order them that way — which RFC 2617 clients
    // sending "qop"/"cnonce" do routinely, and which a multipart body may choose freely.
    // Scanning up to the name also used to fail outright when it appeared first, since
    // -scanUpToString: reports failure if it has nothing to skip.
    NSCharacterSet *const boundaryCharacters = [NSCharacterSet characterSetWithCharactersInString:@" \t;,"];
    NSString *const token = [name stringByAppendingString:@"="];
    NSUInteger searchLocation = 0;

    while (searchLocation < value.length) {
        NSRange found = [value rangeOfString:token
                                     options:NSCaseInsensitiveSearch  // Parameter names are case-insensitive
                                       range:NSMakeRange(searchLocation, value.length - searchLocation)];

        if (found.location == NSNotFound) {
            return nil;
        }

        if ((found.location == 0) || [boundaryCharacters characterIsMember:[value characterAtIndex:(found.location - 1)]]) {
            NSScanner *const scanner = [[NSScanner alloc] initWithString:value];
            [scanner setScanLocation:(found.location + found.length)];
            NSString *parameter = nil;

            if ([scanner scanString:@"\"" intoString:NULL]) {
                [scanner scanUpToString:@"\"" intoString:&parameter];
            } else {
                // Unquoted values end at whitespace or ";", so "name=upload; filename=a.txt"
                // does not yield a trailing ";". Deliberately NOT at ",": RFC 2046 allows a
                // comma in a multipart boundary, and terminating there truncated
                // "boundary=ab,cd" to "ab" and broke every upload from such a client. The
                // comma still delimits when *preceding* a name (see boundaryCharacters), which
                // is all the comma-separated Authorization parameters need.
                [scanner scanUpToCharactersFromSet:[NSCharacterSet characterSetWithCharactersInString:@" \t;"] intoString:&parameter];
            }

            return parameter;
        }

        searchLocation = found.location + found.length;
    }

    return nil;
}

// http://www.w3schools.com/tags/ref_charactersets.asp
NSStringEncoding WSKStringEncodingFromCharset(NSString *charset) {
    NSStringEncoding encoding = kCFStringEncodingInvalidId;

    if (charset) {
        encoding = CFStringConvertEncodingToNSStringEncoding(CFStringConvertIANACharSetNameToEncoding((CFStringRef)charset));
    }

    return (encoding != kCFStringEncodingInvalidId ? encoding : NSUTF8StringEncoding);
}

NSString *WSKFormatRFC822(NSDate *date) {
    __block NSString *string;

    dispatch_sync(_dateFormatterQueue, ^{
        string = [_dateFormatterRFC822 stringFromDate:date];
    });
    return string;
}

NSDate *WSKParseRFC822(NSString *string) {
    __block NSDate *date;

    dispatch_sync(_dateFormatterQueue, ^{
        date = [_dateFormatterRFC822 dateFromString:string];
    });
    return date;
}

NSString *WSKFormatISO8601(NSDate *date) {
    __block NSString *string;

    dispatch_sync(_dateFormatterQueue, ^{
        string = [_dateFormatterISO8601 stringFromDate:date];
    });
    return string;
}

NSDate *WSKParseISO8601(NSString *string) {
    __block NSDate *date;

    dispatch_sync(_dateFormatterQueue, ^{
        date = [_dateFormatterISO8601 dateFromString:string];
    });
    return date;
}

BOOL WSKIsTextContentType(NSString *type) {
    return ([type hasPrefix:@"text/"] || [type hasPrefix:@"application/json"] || [type hasPrefix:@"application/xml"]);
}

NSString *WSKDescribeData(NSData *data, NSString *type) {
    if (WSKIsTextContentType(type)) {
        NSString *const charset = WSKExtractHeaderValueParameter(type, @"charset");
        NSString *const string = [[NSString alloc] initWithData:data encoding:WSKStringEncodingFromCharset(charset)];

        if (string) {
            return string;
        }
    }

    return [NSString stringWithFormat:@"<%lu bytes>", (unsigned long)data.length];
}

NSString *WSKGetMimeTypeForExtension(NSString *extension, NSDictionary<NSString *, NSString *> *overrides) {
    NSDictionary *const builtInOverrides = @{
        @"css": @"text/css"
    };
    NSString *mimeType = nil;

    extension = [extension lowercaseString];

    if (extension.length) {
        mimeType = overrides[extension];

        if (mimeType == nil) {
            mimeType = builtInOverrides[extension];
        }

        if (mimeType == nil) {
            // UniformTypeIdentifiers is available unconditionally at the deployment floors
            // this library ships against, so there is no availability check and no
            // CoreServices fallback. That fallback used the UTTypeCreatePreferredIdentifierForTag
            // family, which is deprecated on every current OS, and its @available clause had
            // to name each platform by hand — omitting tvOS there was a live bug once.
            UTType *const type = [UTType typeWithFilenameExtension:extension];
            mimeType = type.preferredMIMEType;
        }
    }

    return mimeType ? mimeType : kWSKDefaultMimeType;
}

NSString *WSKEscapeURLString(NSString *string) {
    NSMutableCharacterSet *const allowed = [[NSCharacterSet URLQueryAllowedCharacterSet] mutableCopy];
    [allowed removeCharactersInString:@":@/?&=+"];
    return [string stringByAddingPercentEncodingWithAllowedCharacters:allowed];
}

NSString *WSKUnescapeURLString(NSString *string) {
    return [string stringByRemovingPercentEncoding];
}

NSDictionary<NSString *, NSString *> *WSKParseURLEncodedForm(NSString *form) {
    NSMutableDictionary *const parameters = [NSMutableDictionary dictionary];
    NSScanner *const scanner = [[NSScanner alloc] initWithString:form];

    [scanner setCharactersToBeSkipped:nil];

    while (1) {
        NSString *key = nil;

        if (![scanner scanUpToString:@"=" intoString:&key] || [scanner isAtEnd]) {
            break;
        }

        [scanner setScanLocation:([scanner scanLocation] + 1)];

        NSString *value = nil;
        [scanner scanUpToString:@"&" intoString:&value];

        if (value == nil) {
            value = @"";
        }

        key = [key stringByReplacingOccurrencesOfString:@"+" withString:@" "];
        NSString *unescapedKey = key ? WSKUnescapeURLString(key) : nil;
        value = [value stringByReplacingOccurrencesOfString:@"+" withString:@" "];
        NSString *unescapedValue = value ? WSKUnescapeURLString(value) : nil;

        if (unescapedKey && unescapedValue) {
            [parameters setObject:unescapedValue forKey:unescapedKey];
        } else {
            // -stringByRemovingPercentEncoding returns nil for an invalid escape or a
            // sequence that is not valid UTF-8 ("?a=%FF"), which is ordinary remote input
            // rather than an unreachable state: drop the pair instead of aborting in debug.
            WSK_LOG_WARNING(@"Failed parsing URL encoded form for key \"%@\" and value \"%@\"", key, value);
        }

        if ([scanner isAtEnd]) {
            break;
        }

        [scanner setScanLocation:([scanner scanLocation] + 1)];
    }
    return parameters;
}

NSString *WSKStringFromSockAddr(const struct sockaddr *addr, BOOL includeService) {
    char hostBuffer[NI_MAXHOST];
    char serviceBuffer[NI_MAXSERV];

    // Always return on failure. Falling through would format two uninitialized stack
    // buffers into the result, leaking stack contents into logs — which is what happened
    // in debug builds whenever WSK_DNOT_REACHED did not actually abort (it is a no-op
    // under a custom or XLFacility logging facility).
    int result = getnameinfo(addr, addr->sa_len, hostBuffer, sizeof(hostBuffer), serviceBuffer, sizeof(serviceBuffer), NI_NUMERICHOST | NI_NUMERICSERV | NI_NOFQDN);

    if (result != 0) {
        WSK_LOG_ERROR(@"Failed converting socket address to string: %s", gai_strerror(result));
        return @"";
    }

    return includeService ? [NSString stringWithFormat:@"%s:%s", hostBuffer, serviceBuffer] : (NSString *)[NSString stringWithUTF8String:hostBuffer];
}

NSString *WSKGetPrimaryIPAddress(BOOL useIPv6) {
    NSString *address = nil;

#if TARGET_OS_IPHONE
#if !TARGET_IPHONE_SIMULATOR && !TARGET_OS_TV
    const char *primaryInterface = "en0";  // WiFi interface on iOS
#endif
#else
    const char *primaryInterface = NULL;
    SCDynamicStoreRef store = SCDynamicStoreCreate(kCFAllocatorDefault, CFSTR("WSKWebServer"), NULL, NULL);

    if (store) {
        CFPropertyListRef info = SCDynamicStoreCopyValue(store, CFSTR("State:/Network/Global/IPv4"));  // There is no equivalent for IPv6 but the primary interface should be the same

        if (info) {
            NSString *const interface = ((__bridge NSDictionary *)info)[@"PrimaryInterface"];

            if (interface) {
                primaryInterface = [[NSString stringWithString:interface] UTF8String];  // Copy string to auto-release pool
            }

            CFRelease(info);
        }

        CFRelease(store);
    }

    if (primaryInterface == NULL) {
        primaryInterface = "lo0";
    }

#endif /* if TARGET_OS_IPHONE */
    struct ifaddrs *list;

    if (getifaddrs(&list) >= 0) {
        for (struct ifaddrs *ifap = list; ifap; ifap = ifap->ifa_next) {
#if TARGET_IPHONE_SIMULATOR || TARGET_OS_TV

            // Assume en0 is Ethernet and en1 is WiFi since there is no way to use SystemConfiguration framework in iOS Simulator
            // Assumption holds for Apple TV running tvOS
            if (strcmp(ifap->ifa_name, "en0") && strcmp(ifap->ifa_name, "en1"))
#else

            if (strcmp(ifap->ifa_name, primaryInterface))
#endif
            {
                continue;
            }

            if ((ifap->ifa_flags & IFF_UP) && ifap->ifa_addr && ((!useIPv6 && (ifap->ifa_addr->sa_family == AF_INET)) || (useIPv6 && (ifap->ifa_addr->sa_family == AF_INET6)))) {  // getifaddrs can return entries with a NULL ifa_addr
                address = WSKStringFromSockAddr(ifap->ifa_addr, NO);
                break;
            }
        }

        freeifaddrs(list);
    }

    return address;
}

NSString *WSKComputeMD5Digest(NSString *format, ...) {
    va_list arguments;

    va_start(arguments, format);
    NSString *const string = [[NSString alloc] initWithFormat:format arguments:arguments];
    va_end(arguments);
    // Hash the whole byte string, not up to the first NUL. A NUL survives from the wire into
    // request.headers, so a -UTF8String/strlen pair let a client end the hashed input early:
    // for a Digest nonce of "<hex>\0X" the per-process secret never reached the digest, and
    // its integrity tag could be computed by anyone. Not an auth bypass on its own (the
    // response digest still needs HA1) but it defeats the "we minted this nonce" property.
    NSData *const bytes = [string dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char md5[CC_MD5_DIGEST_LENGTH];
    // MD5 is mandated by HTTP Digest Auth (RFC 2617). No non-deprecated replacement exists.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    CC_MD5(bytes.bytes, (CC_LONG)bytes.length, md5);
#pragma clang diagnostic pop
    char buffer[2 * CC_MD5_DIGEST_LENGTH + 1];

    for (int i = 0; i < CC_MD5_DIGEST_LENGTH; ++i) {
        unsigned char byte = md5[i];
        unsigned char byteHi = (byte & 0xF0) >> 4;
        buffer[2 * i + 0] = byteHi >= 10 ? 'a' + byteHi - 10 : '0' + byteHi;
        unsigned char byteLo = byte & 0x0F;
        buffer[2 * i + 1] = byteLo >= 10 ? 'a' + byteLo - 10 : '0' + byteLo;
    }

    buffer[2 * CC_MD5_DIGEST_LENGTH] = 0;
    return (NSString *)[NSString stringWithUTF8String:buffer];
}

NSString *WSKNormalizePath(NSString *path) {
    // Treat an embedded NUL as a path terminator, the way the filesystem's C-string APIs do.
    // Otherwise -pathExtension reads past the NUL while -fileSystemRepresentation truncates at
    // it, so "secret.dat\0.png" would pass an extension allow-list yet open "secret.dat".
    unichar nul = 0;
    NSRange nulRange = [path rangeOfString:[NSString stringWithCharacters:&nul length:1]];
    if (nulRange.location != NSNotFound) {
        path = [path substringToIndex:nulRange.location];
    }

    NSMutableArray *const components = [[NSMutableArray alloc] init];

    for (NSString *component in [path componentsSeparatedByString:@"/"]) {
        if ([component isEqualToString:@".."]) {
            if (components.count) {  // Guard: -removeLastObject on an empty array is documented to raise; surplus ".." are simply dropped.
                [components removeLastObject];
            }
        } else if (component.length && ![component isEqualToString:@"."]) {
            [components addObject:component];
        }
    }

    if (path.length && ([path characterAtIndex:0] == '/')) {
        return [@"/" stringByAppendingString:[components componentsJoinedByString:@"/"]];  // Preserve initial slash
    }

    return [components componentsJoinedByString:@"/"];
}

BOOL WSKPathIsInsideDirectory(NSString *path, NSString *directory) {
    if ((path.length == 0) || (directory.length == 0)) {
        return NO;
    }
    if ([path isEqualToString:directory]) {
        return NO;  // The directory itself is not "inside" it.
    }
    NSString *const prefix = [directory hasSuffix:@"/"] ? directory : [directory stringByAppendingString:@"/"];
    return [path hasPrefix:prefix];
}

// Fully resolve `path` with realpath(3). If the item does not exist yet — an upload or
// MKCOL destination — resolve its parent instead and re-attach the leaf, so intermediate
// symlinks are still resolved without requiring the target to exist. Returns nil when
// nothing along the path can be resolved.
static NSString *_RealPath(NSString *path) {
    if (path.length == 0) {
        return nil;
    }

    char buffer[PATH_MAX];
    NSFileManager *const fileManager = [NSFileManager defaultManager];

    if (realpath([path fileSystemRepresentation], buffer)) {
        return [fileManager stringWithFileSystemRepresentation:buffer length:strlen(buffer)];
    }

    NSString *const parent = [path stringByDeletingLastPathComponent];

    if ((parent.length == 0) || [parent isEqualToString:path]) {
        return nil;
    }

    if (realpath([parent fileSystemRepresentation], buffer)) {
        NSString *const resolvedParent = [fileManager stringWithFileSystemRepresentation:buffer length:strlen(buffer)];
        return resolvedParent ? [resolvedParent stringByAppendingPathComponent:[path lastPathComponent]] : nil;
    }

    return nil;
}

NSString *WSKResolveWithinDirectory(NSString *path, NSString *directory, NSString *__autoreleasing *outRelativePath) {
    NSString *const resolvedPath = _RealPath(path);
    NSString *const resolvedDirectory = _RealPath(directory);

    if (outRelativePath) {
        *outRelativePath = nil;
    }

    if ((resolvedPath == nil) || (resolvedDirectory == nil)) {
        return nil;  // Fail closed rather than acting on a path we could not verify.
    }

    if (![resolvedPath isEqualToString:resolvedDirectory] && !WSKPathIsInsideDirectory(resolvedPath, resolvedDirectory)) {
        return nil;
    }

    if (outRelativePath) {
        *outRelativePath = [resolvedPath isEqualToString:resolvedDirectory]
                               ? @""
                               : [resolvedPath substringFromIndex:(resolvedDirectory.length + ([resolvedDirectory hasSuffix:@"/"] ? 0 : 1))];
    }

    return resolvedPath;
}

NSString *WSKResolvedPathRelativeToDirectory(NSString *path, NSString *directory) {
    NSString *const resolvedPath = _RealPath(path);
    // Resolve the directory too: /var is itself a symlink to /private/var on Apple
    // platforms, so a resolved path compared against an unresolved root never matches.
    NSString *const resolvedDirectory = _RealPath(directory);

    if ((resolvedPath == nil) || (resolvedDirectory == nil)) {
        return nil;  // Fail closed rather than serving a path we could not verify.
    }

    if ([resolvedPath isEqualToString:resolvedDirectory]) {
        return @"";  // The root itself, which is inside itself but has no relative part.
    }

    if (!WSKPathIsInsideDirectory(resolvedPath, resolvedDirectory)) {
        return nil;
    }

    // Relative to the *resolved* root, which is the whole point: the root itself may sit under
    // a dot-directory — NSTemporaryDirectory() under a sandboxed app routinely does — and
    // testing the absolute resolved path for hidden components would then refuse every file
    // it serves.
    return [resolvedPath substringFromIndex:(resolvedDirectory.length + ([resolvedDirectory hasSuffix:@"/"] ? 0 : 1))];
}

BOOL WSKResolvedPathIsWithinDirectory(NSString *path, NSString *directory) {
    return (WSKResolvedPathRelativeToDirectory(path, directory) != nil);
}

BOOL WSKResolvedPathHasHiddenComponent(NSString *path, NSString *directory) {
    NSString *const relativePath = WSKResolvedPathRelativeToDirectory(path, directory);

    if (relativePath == nil) {
        // Outside the root, or unresolvable. Containment is a separate check and reports that
        // separately; answering YES here would mislabel an escape as a hidden item, so say no
        // and let containment refuse it.
        return NO;
    }

    // Resolved, so this catches what a textual test on the request path cannot: a symlink whose
    // own name carries no dot but whose target lives inside a dot-directory. Both tests are
    // needed — this one alone would miss nothing here, but it costs a realpath, so callers keep
    // their cheap textual walk in front of it.
    for (NSString *component in [relativePath pathComponents]) {
        if ([component hasPrefix:@"."]) {
            return YES;
        }
    }

    return NO;
}
