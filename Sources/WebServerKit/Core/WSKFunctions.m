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
#import <sys/mount.h>
#import <sys/param.h>
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
// RFC 9110 s5.6.7 requires a recipient to accept all three HTTP-date formats — a spelling
// that parses to nil makes the precondition ABSENT, a validator failing open. The two
// obsolete forms are only ever parsed with, never formatted: senders must emit IMF-fixdate.
static NSDateFormatter *_dateFormatterRFC850 = nil;
static NSDateFormatter *_dateFormatterAsctime = nil;
static NSDateFormatter *_dateFormatterISO8601 = nil;
static dispatch_queue_t _dateFormatterQueue = NULL;
// Anything earlier than this is not a date any HTTP client meant to send; see _EnsureDateFormatters.
static NSTimeInterval _earliestPlausibleDate = 0.0;

// The longest legal HTTP-date is the RFC 850 form with the longest weekday:
// "Wednesday, 06-Nov-94 08:49:37 GMT" — 33 characters. The cap is deliberately loose; its job is
// only to keep rejection CONSTANT-TIME, not to validate.
static const NSUInteger kMaxHTTPDateLength = 64;

// Idempotent and safe from any thread: everything here is built exactly once, under
// dispatch_once, and read-only thereafter (all use is serialized on _dateFormatterQueue).
//
// It MUST be called lazily from every function that touches a formatter, not only from
// +[WSKWebServer initialize]: initialized only from there, the four public date functions
// dispatch_sync on a NULL queue — an immediate crash — for a host app that calls one before
// touching the server class. (No in-suite test can pin this; the suite has always
// initialized the class by the time any test runs. The oracle is out-of-process.)
// There is no main-thread requirement: NSDateFormatter is safe to construct off the main
// thread, and dispatch_once removes the race the old assertion stood in for.
static void _EnsureDateFormatters(void) {
    static dispatch_once_t onceToken;

    dispatch_once(&onceToken, ^{
        _dateFormatterRFC822 = [[NSDateFormatter alloc] init];
        _dateFormatterRFC822.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"GMT"];
        _dateFormatterRFC822.dateFormat = @"EEE',' dd MMM yyyy HH':'mm':'ss 'GMT'";
        _dateFormatterRFC822.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US"];

        _dateFormatterRFC850 = [[NSDateFormatter alloc] init];
        _dateFormatterRFC850.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"GMT"];
        _dateFormatterRFC850.dateFormat = @"EEEE',' dd'-'MMM'-'yy HH':'mm':'ss 'GMT'";
        _dateFormatterRFC850.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US"];
        // RFC 9110 s5.6.7: a two-digit year more than 50 years in the future means the most
        // recent past year with those digits. A window opening 50 years ago is exactly that
        // rule. Sampled once, which is right for a formatter built once — the boundary moves
        // by a year annually and no HTTP client is sending dates near it.
        _dateFormatterRFC850.twoDigitStartDate = [NSDate dateWithTimeIntervalSinceNow:-50.0 * 365.2425 * 24.0 * 60.0 * 60.0];

        _dateFormatterAsctime = [[NSDateFormatter alloc] init];
        _dateFormatterAsctime.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"GMT"];
        _dateFormatterAsctime.dateFormat = @"EEE MMM d HH':'mm':'ss yyyy";
        _dateFormatterAsctime.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US"];

        _dateFormatterISO8601 = [[NSDateFormatter alloc] init];
        _dateFormatterISO8601.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"GMT"];
        _dateFormatterISO8601.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss'+00:00'";
        _dateFormatterISO8601.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US"];

        _dateFormatterQueue = dispatch_queue_create(NULL, DISPATCH_QUEUE_SERIAL);

        // ICU is lenient about digit COUNT: it accepts 1-3 digits for a "yyyy" field and 1
        // for "yy", so "…94" parses to the year 94 AD instead of failing — a date preceding
        // every real mtime, turning If-Unmodified-Since into a permanent 412 no retry can
        // satisfy. RFC 9110 §13.1.4 requires an unparseable date to be IGNORED (fail open).
        // Anchoring the calendar year is cheaper and less brittle than tightening three ICU
        // patterns, and it covers all three spellings.
        NSDateComponents *const earliest = [[NSDateComponents alloc] init];
        earliest.year = 1000;
        earliest.month = 1;
        earliest.day = 1;
        NSCalendar *const gregorian = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
        gregorian.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];  // Non-null, unlike +timeZoneWithAbbreviation:, and NSCalendar.timeZone is non-null.
        _earliestPlausibleDate = [[gregorian dateFromComponents:earliest] timeIntervalSinceReferenceDate];
    });
}

void WSKInitializeFunctions(void) {
    _EnsureDateFormatters();
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

    // The parameter name must match at a token boundary: a plain substring search finds
    // "name=" inside "filename=" and "nonce=" inside "cnonce=", returning the wrong
    // parameter whenever the client orders them that way — which RFC 2617 clients sending
    // "qop"/"cnonce" do routinely, and which a multipart body may choose freely.
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
                // Unquoted values end at whitespace or ";" — deliberately NOT at ",":
                // RFC 2046 allows a comma in a multipart boundary, so terminating there
                // truncates "boundary=ab,cd" to "ab". The comma still delimits when
                // *preceding* a name (see boundaryCharacters), which is all the
                // comma-separated Authorization parameters need.
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

    _EnsureDateFormatters();
    dispatch_sync(_dateFormatterQueue, ^{
        string = [_dateFormatterRFC822 stringFromDate:date];
    });
    return string;
}

NSDate *WSKParseRFC822(NSString *string) {
    // Length is checked BEFORE any formatter runs, and this is load-bearing: rejecting a
    // non-date is otherwise linear in its length (three ICU passes plus a double-space
    // collapse), all inside the single process-wide serial queue that also serializes every
    // response's Date header — and If-Modified-Since is parsed for every request, before any
    // handler or authentication. No legal HTTP-date exceeds 33 characters.
    if ((string.length == 0) || (string.length > kMaxHTTPDateLength)) {
        return nil;
    }

    __block NSDate *date;

    _EnsureDateFormatters();
    dispatch_sync(_dateFormatterQueue, ^{
        date = [_dateFormatterRFC822 dateFromString:string];

        if (date == nil) {
            date = [_dateFormatterRFC850 dateFromString:string];
        }

        if (date == nil) {
            // asctime() pads a single-digit day to width two ("Sun Nov  6 ..."), which the
            // "d" specifier does not absorb. Collapsing runs of spaces makes the one legal
            // variant parse without loosening the pattern itself.
            NSString *const collapsed = [string stringByReplacingOccurrencesOfString:@"  " withString:@" "];
            date = [_dateFormatterAsctime dateFromString:collapsed];
        }

        // ICU's tolerance of short year fields turns malformed input into a first- or
        // second-century date rather than nil. Applied to all three spellings, never a subset.
        if ((date != nil) && ([date timeIntervalSinceReferenceDate] < _earliestPlausibleDate)) {
            date = nil;
        }
    });
    return date;
}

NSString *WSKFormatISO8601(NSDate *date) {
    __block NSString *string;

    _EnsureDateFormatters();
    dispatch_sync(_dateFormatterQueue, ^{
        string = [_dateFormatterISO8601 stringFromDate:date];
    });
    return string;
}

NSDate *WSKParseISO8601(NSString *string) {
    __block NSDate *date;

    _EnsureDateFormatters();
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
            // this library ships against: no availability check, no CoreServices fallback —
            // a fallback's @available clause has to name each platform by hand, and omitting
            // one is a silent per-platform bug.
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

    // sa_len is read below before getnameinfo can fail, so a NULL address is a SEGV rather
    // than an error return — and it is reachable: a WSKRequest built by a WSKMatchBlock has
    // no address data until the connection populates it AFTER the block returns. Same "" the
    // getnameinfo failure below returns, so callers need no new case.
    if (addr == NULL) {
        return @"";
    }

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

BOOL WSKNamePassesExtensionAllowList(NSString *name, NSArray<NSString *> *allowedExtensions) {
    return (allowedExtensions == nil) || [allowedExtensions containsObject:[[name pathExtension] lowercaseString]];
}

BOOL WSKEntryPassesExtensionAllowList(NSString *namedName, NSString *resolvedName, NSArray<NSString *> *allowedExtensions) {
    if (!WSKNamePassesExtensionAllowList(namedName, allowedExtensions)) {
        return NO;
    }

    // Only a link presents a second name, and only a differing one is worth asking about.
    if ((resolvedName != nil) && ![resolvedName isEqualToString:namedName]) {
        return WSKNamePassesExtensionAllowList(resolvedName, allowedExtensions);
    }

    return YES;
}

NSString *WSKHostNameWithoutRootLabel(NSString *host) {
    // Only one dot is stripped; "name.local.." remains malformed and is refused.
    return [host hasSuffix:@"."] ? [host substringToIndex:(host.length - 1)] : host;
}

BOOL WSKIsHeaderTokenCharacter(unsigned char character) {
    if (((character >= 'a') && (character <= 'z')) || ((character >= 'A') && (character <= 'Z')) || ((character >= '0') && (character <= '9'))) {
        return YES;
    }

    switch (character) {
        case '!':
        case '#':
        case '$':
        case '%':
        case '&':
        case '\'':
        case '*':
        case '+':
        case '-':
        case '.':
        case '^':
        case '_':
        case '`':
        case '|':
        case '~':
            return YES;
        default:
            return NO;
    }
}

BOOL WSKIsHeaderTokenString(NSString *string) {
    // 1*tchar: at least one character, every one of them a tchar. Compared over UTF-8 bytes so a
    // non-ASCII name fails on its lead byte rather than being silently truncated somewhere later.
    NSData *const bytes = [string dataUsingEncoding:NSUTF8StringEncoding];

    if (bytes.length == 0) {
        return NO;
    }

    unsigned char const *const buffer = bytes.bytes;

    for (NSUInteger i = 0; i < bytes.length; i++) {
        if (!WSKIsHeaderTokenCharacter(buffer[i])) {
            return NO;
        }
    }

    return YES;
}

WSKServerErrorHTTPStatusCode WSKServerErrorStatusCodeForError(NSError *error) {
    if (error == nil) {
        return kWSKHTTPStatusCode_InternalServerError;
    }

    // NSFileManager reports a full volume as a Cocoa error, but the POSIX errno survives under
    // NSUnderlyingError for the calls that go through it, and EDQUOT never gets a Cocoa code of
    // its own. Both spellings have to be read or the mapping closes only half the class.
    for (NSError *candidate = error; candidate != nil; candidate = candidate.userInfo[NSUnderlyingErrorKey]) {
        if ([candidate.domain isEqualToString:NSCocoaErrorDomain] && (candidate.code == NSFileWriteOutOfSpaceError)) {
            return kWSKHTTPStatusCode_InsufficientStorage;
        }

        if ([candidate.domain isEqualToString:NSPOSIXErrorDomain] && ((candidate.code == ENOSPC) || (candidate.code == EDQUOT))) {
            return kWSKHTTPStatusCode_InsufficientStorage;
        }
    }

    return kWSKHTTPStatusCode_InternalServerError;
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

BOOL WSKPathContainsNULByte(NSString *path) {
    unichar nul = 0;
    return (path != nil) && ([path rangeOfString:[NSString stringWithCharacters:&nul length:1]].location != NSNotFound);
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
    char const *const representation = [path fileSystemRepresentation];

    // Nothing at or beyond PATH_MAX can name a filesystem entry: realpath(3), lstat(2) and every
    // other path call answer ENAMETOOLONG, so such a path can neither exist nor be created. Refuse
    // it here rather than letting the walk below discover it one component at a time.
    //
    // This is a BOUND, not an optimization: the walk below does work per missing component and is
    // driven by client input capped only by the header block, so without this guard a deep path is
    // a CPU amplifier — a denial of service on a server with a 128-connection cap and no rate
    // limiting. Fail CLOSED (nil, so callers answer 403). It reveals nothing: the verdict depends
    // only on the length the client sent, never on what the filesystem holds.
    if (strlen(representation) >= PATH_MAX) {
        return nil;
    }

    if (realpath(representation, buffer)) {
        return [fileManager stringWithFileSystemRepresentation:buffer length:strlen(buffer)];
    }

    // realpath(3) failed. Normally that means the path does not exist YET — a PUT or MKCOL to a new
    // name — and resolving the parent then appending the leaf is exactly right for it. That branch
    // is why this function has a fallback at all, so it must keep working.
    //
    // An entry that EXISTS and still fails realpath is a different thing: a dangling symlink, a
    // loop, or a component that cannot be traversed. Treating one as "a new path inside the share"
    // makes the answer depend on whether the link's target exists — 403 when it does, 404 when it
    // does not — an existence oracle for the filesystem OUTSIDE the share, reachable through any
    // escaping link in the served content. Fail closed: the entry is there and cannot be resolved,
    // so it cannot be acted on. A dangling link and a symlink loop answer 403 rather than 404;
    // neither was ever served, so no working operation is lost.
    //
    // The walk climbs until an ancestor resolves rather than trying the immediate parent ONCE:
    // tolerating exactly one missing component makes "absent" and "refused" the same answer as
    // soon as a client names a path two levels past anything real — 403 where 404 is owed, which
    // clients like `rclone copy` treat as fatal.
    //
    // This does NOT reopen the existence oracle the lstat above closes, and the distinction is the
    // whole reason the fix lives here rather than in the verbs. The rejected alternative — a
    // -fileExistsAtPath: parent precheck in each read verb — answers YES/NO for paths OUTSIDE the
    // share, which is precisely the oracle. Here, an escaping path still resolves to a location
    // outside the root and is then refused by the CONTAINMENT test in the caller, whether or not
    // anything exists there; and a component that exists but will not resolve still fails closed
    // at the top of each iteration.
    //
    // The write verbs are deliberately untouched by this. PUT, MKCOL and a MOVE/COPY destination
    // answer 409 Conflict for a missing ancestor — RFC 4918 §9.7.1 — from their own parent
    // precheck, which this only lets them reach. 409 is correct there and must not become 404.
    NSMutableArray<NSString *> *const missingComponents = [NSMutableArray array];
    NSString *cursor = path;

    while (YES) {
        struct stat entryInfo;

        if (lstat([cursor fileSystemRepresentation], &entryInfo) == 0) {
            return nil;
        }

        NSString *const parent = [cursor stringByDeletingLastPathComponent];
        NSString *const leaf = [cursor lastPathComponent];

        // Terminates: every iteration strictly shortens the path, and "/" is its own parent.
        if ((parent.length == 0) || (leaf.length == 0) || [parent isEqualToString:cursor]) {
            return nil;
        }

        // APPENDED, not inserted at index 0, and joined in a single pass below. Both spellings of
        // the obvious version are quadratic in the component count — -insertObject:atIndex:0
        // shifts the whole array on every component, and -stringByAppendingPathComponent: in a
        // loop copies the whole prefix on every component. Bounded by PATH_MAX above AND linear
        // here; if that ever matters, the lever is a component cap well below PATH_MAX.
        [missingComponents addObject:leaf];

        if (realpath([parent fileSystemRepresentation], buffer)) {
            NSString *const resolvedParent = [fileManager stringWithFileSystemRepresentation:buffer length:strlen(buffer)];

            if (resolvedParent == nil) {
                return nil;
            }

            NSMutableString *const resolved = [resolvedParent mutableCopy];

            // Collected leaf-first, so walk back out. "/" is the one parent that already ends in a
            // separator, hence the suffix test rather than an unconditional append.
            for (NSString *const component in [missingComponents reverseObjectEnumerator]) {
                if (![resolved hasSuffix:@"/"]) {
                    [resolved appendString:@"/"];
                }

                [resolved appendString:component];
            }

            return resolved;
        }

        cursor = parent;
    }
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

NSString *WSKServableFileTypeAtPath(NSString *path, NSString *directory, BOOL allowHiddenItems, NSString *__autoreleasing *outResolvedName) {
    if (outResolvedName) {
        *outResolvedName = nil;
    }

    NSDictionary *const attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:NULL];
    NSString *const type = attributes[NSFileType];

    if (![type isEqualToString:NSFileTypeSymbolicLink]) {
        return type;
    }

    // Judge the link by what it points at, and only when that is something this server would
    // actually serve: inside the directory, and a regular file or a directory itself.
    if (!WSKResolvedPathIsWithinDirectory(path, directory)) {
        return nil;
    }

    // Hiddenness as well as containment: a link whose own name carries no dot but which resolves
    // inside a dot-directory would otherwise be ADVERTISED by all three listings and then refused
    // 403 by every handler. "Advertise iff served" is the rule, in both directions.
    if (!allowHiddenItems && WSKResolvedPathHasHiddenComponent(path, directory)) {
        return nil;
    }

    struct stat info;

    if (stat([path fileSystemRepresentation], &info) != 0) {
        return nil;  // Dangling, or a loop: there is nothing to advertise.
    }

    // Derived here and handed out precisely so no caller resolves a second time: two observations
    // of a filesystem that need not agree is the class behind the retargeted-symlink escapes.
    if (outResolvedName) {
        char resolvedBuffer[PATH_MAX];

        if (realpath([path fileSystemRepresentation], resolvedBuffer) != NULL) {
            NSString *const resolved = [[NSFileManager defaultManager] stringWithFileSystemRepresentation:resolvedBuffer length:strlen(resolvedBuffer)];
            *outResolvedName = [resolved lastPathComponent];
        }
    }

    if ((info.st_mode & S_IFMT) == S_IFDIR) {
        return NSFileTypeDirectory;
    }

    if ((info.st_mode & S_IFMT) == S_IFREG) {
        return NSFileTypeRegular;
    }

    return nil;
}

// The two path resolvers every path-taking verb in this library goes through. ONE implementation,
// deliberately: these were four near-verbatim copies, and copies drifting — a rule closed in one
// server and left open in another — is this codebase's single most reliable defect class. Each
// server keeps a three-line method wrapping these so every call site binds the result to the
// variable it already used, which makes "I missed one" structurally impossible. Do not inline
// the wrappers away, and do not add a resolver copy.

BOOL WSKPathsNameTheSameFile(NSString *path1, NSString *path2) {
    if ([path1 isEqualToString:path2]) {
        return YES;
    }

    id identifier1 = nil;
    id identifier2 = nil;
    return [[NSURL fileURLWithPath:path1] getResourceValue:&identifier1 forKey:NSURLFileResourceIdentifierKey error:NULL] &&
           [[NSURL fileURLWithPath:path2] getResourceValue:&identifier2 forKey:NSURLFileResourceIdentifierKey error:NULL] &&
           identifier1 && [(NSObject *)identifier1 isEqual:identifier2];
}

NSString *WSKFirstUnvettableItemAtPath(NSString *absolutePath, BOOL isDirectory, NSArray<NSString *> *allowedExtensions) {
    if (allowedExtensions == nil) {
        return nil;  // No restriction configured: nothing to vet against.
    }

    if (!isDirectory) {
        NSString *const itemName = [absolutePath lastPathComponent];
        return WSKNamePassesExtensionAllowList(itemName, allowedExtensions) ? nil : itemName;
    }

    NSDirectoryEnumerator<NSString *> *const enumerator = [[NSFileManager defaultManager] enumeratorAtPath:absolutePath];

    for (NSString *subpath in enumerator) {
        NSString *const subpathType = [enumerator fileAttributes][NSFileType];

        if ([[subpath lastPathComponent] hasPrefix:@"."]) {
            // -skipDescendants is defined for the most recently returned SUBDIRECTORY. Calling it
            // for a dot-named FILE pops the enclosing level instead, switching the allow-list off
            // for everything after the first dot-name in readdir order — and a ".DS_Store" sits
            // in every Finder-touched folder, sorting early. Only a dot-named DIRECTORY may be
            // skipped wholesale.
            if ([subpathType isEqualToString:NSFileTypeDirectory]) {
                [enumerator skipDescendants];
            }

            continue;
        }

        // An extensionless file ("README", "LICENSE") is vetted like any other: a direct DELETE of
        // it is already refused, so letting a recursive delete destroy it would make the same
        // request mean two different things.
        if ([subpathType isEqualToString:NSFileTypeRegular] && !WSKNamePassesExtensionAllowList(subpath, allowedExtensions)) {
            return subpath;
        }
    }

    return nil;
}

NSString *WSKNamedEntryPathForRelativePath(NSString *relativePath, NSString *directory, BOOL allowHiddenItems, BOOL *outHidden) {
    if (WSKPathContainsNULByte(relativePath)) {
        return nil;
    }

    NSString *const normalizedPath = WSKNormalizePath(relativePath);

    if (outHidden) {
        *outHidden = NO;
    }

    // Naming the root itself is not something a destructive verb may act on, and there is no
    // final component to preserve either.
    if ((normalizedPath.length == 0) || [normalizedPath isEqualToString:@"/"]) {
        return nil;
    }

    NSString *namedRelativePath = nil;
    NSString *const namedPath = WSKResolveNamedEntryWithinDirectory([directory stringByAppendingPathComponent:normalizedPath], directory, &namedRelativePath);

    if (namedPath == nil) {
        return nil;
    }

    if (outHidden && !allowHiddenItems) {
        for (NSString *component in [normalizedPath pathComponents]) {
            if ([component hasPrefix:@"."]) {
                *outHidden = YES;
                return namedPath;
            }
        }

        for (NSString *component in [namedRelativePath pathComponents]) {
            if ([component hasPrefix:@"."]) {
                *outHidden = YES;
                return namedPath;
            }
        }
    }

    return namedPath;
}

NSString *WSKResolvedPathForRelativePath(NSString *relativePath, NSString *directory, BOOL allowHiddenItems, BOOL *outHidden) {
    // Refusal is the FIRST line against an embedded NUL, and it lives here — the one point every
    // path-taking verb goes through — so a verb added later cannot forget it (acting on the
    // truncated prefix is how "DELETE /Victim\0/x" destroys /Victim). WSKNormalizePath keeps
    // truncating as the second line, so the "secret.dat\0.png" allow-list bypass stays closed.
    if (WSKPathContainsNULByte(relativePath)) {
        return nil;
    }

    NSString *const normalizedPath = WSKNormalizePath(relativePath);
    NSString *resolvedRelativePath = nil;
    NSString *const resolvedPath = WSKResolveWithinDirectory([directory stringByAppendingPathComponent:normalizedPath], directory, &resolvedRelativePath);

    if (outHidden) {
        *outHidden = NO;
    }

    if (resolvedPath == nil) {
        return nil;
    }

    // A symlink that resolves to the share root itself is never what the client meant, and
    // acting on it is catastrophic: every "not the root directory" guard is evaluated on the
    // path the client *typed*, then this resolved path is substituted for it — so "DELETE /self"
    // passes a guard about "/self" and then removes the whole share. Refused here, in the
    // resolver, so a destructive call site added later cannot forget it. Asking for the root
    // *directly* is still allowed — that is the client naming the root, not a link quietly
    // landing on it.
    BOOL const askedForRoot = (normalizedPath.length == 0) || [normalizedPath isEqualToString:@"/"];

    if ((resolvedRelativePath.length == 0) && !askedForRoot) {
        return nil;
    }

    if (outHidden && !allowHiddenItems) {
        for (NSString *component in [normalizedPath pathComponents]) {
            if ([component hasPrefix:@"."]) {
                *outHidden = YES;
                return resolvedPath;
            }
        }

        for (NSString *component in [resolvedRelativePath pathComponents]) {
            if ([component hasPrefix:@"."]) {
                *outHidden = YES;
                return resolvedPath;
            }
        }
    }

    return resolvedPath;
}

NSString *WSKResolveNamedEntryWithinDirectory(NSString *path, NSString *directory, NSString *__autoreleasing *outRelativePath) {
    if (outRelativePath) {
        *outRelativePath = nil;
    }

    NSString *const leaf = [path lastPathComponent];
    NSString *const parent = [path stringByDeletingLastPathComponent];

    // No final component to preserve — "/" and the directory itself. Every destructive verb
    // refuses the root separately, so returning nil here is the same answer by a shorter route.
    if ((leaf.length == 0) || [leaf isEqualToString:@"/"] || (parent.length == 0)) {
        return nil;
    }

    NSString *const resolvedParent = _RealPath(parent);
    NSString *const resolvedDirectory = _RealPath(directory);

    if ((resolvedParent == nil) || (resolvedDirectory == nil)) {
        return nil;  // Fail closed rather than acting on a path we could not verify.
    }

    if (![resolvedParent isEqualToString:resolvedDirectory] && !WSKPathIsInsideDirectory(resolvedParent, resolvedDirectory)) {
        return nil;
    }

    NSString *const namedPath = [resolvedParent stringByAppendingPathComponent:leaf];

    if (outRelativePath) {
        NSString *const parentRelative = [resolvedParent isEqualToString:resolvedDirectory]
                                             ? @""
                                             : [resolvedParent substringFromIndex:(resolvedDirectory.length + ([resolvedDirectory hasSuffix:@"/"] ? 0 : 1))];
        *outRelativePath = (parentRelative.length == 0) ? leaf : [parentRelative stringByAppendingPathComponent:leaf];
    }

    return namedPath;
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

NSString *WSKEntityTagForFileInfo(const struct stat *info) {
    return [NSString stringWithFormat:@"\"%llu/%lld/%li/%li\"", info->st_ino, (long long)info->st_size, info->st_mtimespec.tv_sec, info->st_mtimespec.tv_nsec];
}

// "*" matches any existing representation. Otherwise the list is compared entry by entry.
// If-Match requires the STRONG comparison (RFC 9110 §13.1.1), where a "W/" tag can never match;
// If-None-Match uses the weak one, where the prefix is stripped from the client's side. Tags
// this server issues are always strong. Hoisted here from the WebDAV write-verb preconditions
// when the connection's read verbs gained the same evaluation, so both sides judge the tag a
// GET hands out by one rule.
BOOL WSKEntityTagMatchesList(BOOL resourceExists, NSString *currentTag, NSString *list, BOOL strong) {
    NSString *const trimmed = [list stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];

    // "*" asks whether the origin has a current representation AT ALL (RFC 9110 §13.1.1), which is
    // not the same question as "does it have an entity tag". Keying it on the tag made `If-Match: *`
    // always FAIL for a collection, since no tag is minted for a directory — so a conditional
    // DELETE, MOVE or COPY of a folder could never succeed.
    if ([trimmed isEqualToString:@"*"]) {
        return resourceExists;
    }

    if (currentTag == nil) {
        return NO;
    }

    for (NSString *candidate in [trimmed componentsSeparatedByString:@","]) {
        NSString *value = [candidate stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];

        if ([value hasPrefix:@"W/"]) {
            if (strong) {
                continue;
            }

            value = [value substringFromIndex:2];
        }

        if ([value isEqualToString:currentTag]) {
            return YES;
        }
    }

    return NO;
}

// FAT truncates mtime into two-second buckets, so a timestamp one second old there can still take
// another write without moving. Unrecognised types fail CLOSED at two seconds — smbfs and nfs can
// be backed by FAT and cannot be probed from here, and the cost of being wrong that way is one
// extra second of caching rather than a spliced representation. Do not "optimize" this to one.
static time_t _ModificationTimeGranularity(int descriptor) {
    struct statfs info;

    if (fstatfs(descriptor, &info) != 0) {
        return 2;
    }

    if ((strcmp(info.f_fstypename, "apfs") == 0) || (strcmp(info.f_fstypename, "hfs") == 0) ||
        (strcmp(info.f_fstypename, "exfat") == 0)) {
        return 1;
    }

    return 2;
}

BOOL WSKLastModifiedDateIsSealed(int descriptor, const struct stat *info) {
    // A future mtime — clock skew, or an archive restored with tomorrow's timestamp — is unsealed
    // by the same comparison, which is the safe direction and also stops the server advertising a
    // Last-Modified newer than its own Date header.
    return (time(NULL) - info->st_mtimespec.tv_sec) >= _ModificationTimeGranularity(descriptor);
}

// Immutable or append-only defeats unlink(2) whatever the permissions say; an unreadable directory
// cannot be walked and an unwritable one cannot have its children removed. Checked with lstat so a
// symlink is judged as the entry it is — removing one never touches its target.
static BOOL _ItemIsRemovable(NSString *path) {
    struct stat info;

    if (lstat([path fileSystemRepresentation], &info) != 0) {
        return YES;  // Gone already, or unstattable; the removal will agree either way.
    }

    if (info.st_flags & (UF_IMMUTABLE | SF_IMMUTABLE | UF_APPEND | SF_APPEND)) {
        return NO;
    }

    if ((info.st_mode & S_IFMT) == S_IFDIR) {
        // A directory's own write permission is only needed to unlink its CHILDREN. Removing the
        // directory itself is rmdir(2), which needs write permission on its PARENT — so an EMPTY
        // directory is removable whatever its own mode says. Requiring W_OK unconditionally makes
        // a 0555 directory render its ancestry permanently undeletable, and unzip and `ditto -x`
        // both preserve 0555, so that arrives through ordinary archive extraction.
        //
        // A directory that cannot be listed at all is refused: its children cannot be unlinked,
        // and whether it has any cannot be established.
        if (access([path fileSystemRepresentation], R_OK | X_OK) != 0) {
            return NO;
        }

        NSArray<NSString *> *const contents = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:path error:NULL];

        if (contents.count == 0) {
            return YES;
        }

        return access([path fileSystemRepresentation], W_OK) == 0;
    }

    return YES;
}

NSString *WSKFirstUnremovableItemAtPath(NSString *absolutePath) {
    if (!_ItemIsRemovable(absolutePath)) {
        return [absolutePath lastPathComponent];
    }

    NSDirectoryEnumerator<NSString *> *const enumerator = [[NSFileManager defaultManager] enumeratorAtPath:absolutePath];

    for (NSString *subpath in enumerator) {
        if (!_ItemIsRemovable([absolutePath stringByAppendingPathComponent:subpath])) {
            return subpath;
        }
    }

    return nil;
}
