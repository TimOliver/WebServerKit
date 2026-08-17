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

#define kMultiPartBufferSize (256 * 1024)

// A part whose Content-Type is "multipart/mixed" spawns a nested sub-parser that is
// fed synchronously (appendBytes: -> _parseData -> sub-parser appendBytes: -> ...),
// so the parse recursion depth equals the client-chosen nesting depth. Cap it: a
// crafted body of thousands of nested multipart/mixed parts (each only tens of bytes,
// so they fit well within the in-memory buffer cap) would otherwise overflow the
// worker-thread stack and crash the process. Real forms never nest beyond one level.
#define kMultiPartMaxDepth 8

// Upper bound on how many parts a single body may contain. Each completed part costs
// either a retained NSData (an argument) or a temporary file (a file part), and both
// live until the request is deallocated, so an otherwise-legal body made of millions of
// tiny parts would exhaust memory or the temporary directory's inodes. Real forms send
// a handful.
#define kMultiPartMaxParts 1024

// Upper bound on a single part's header block. See -_parseData: the strings parsed out of
// these headers are retained per part, so they need bounding just as the content does.
#define kMultiPartMaxHeadersLength (8 * 1024)

// The in-memory budget is shared between a parser and every sub-parser it spawns: a
// nested "multipart/mixed" part appends into the same argument and file arrays as its
// parent, so a per-parser counter would let nesting multiply the real ceiling.
@interface WSKMIMEStreamBudget : NSObject {
@public
    NSUInteger argumentBytes;  // Total bytes retained by argument parts so far
    NSUInteger partCount;      // Total completed parts (arguments and files) so far
}
// This body's share of the process-wide in-memory ceiling, covering the argument parts it
// retains. Per-request limits do not compose, so without this a flood of individually-legal
// bodies still exhausts the process. Working buffers are charged separately, per parser,
// because they shrink again as parts are consumed.
@property (nonatomic, readonly) WSKMemoryReservation *reservation;
@end

@implementation WSKMIMEStreamBudget

- (instancetype)init {
    if ((self = [super init])) {
        _reservation = [[WSKMemoryReservation alloc] init];
    }

    return self;
}

@end

typedef enum {
    kParserState_Undefined = 0,
    kParserState_Start,
    kParserState_Headers,
    kParserState_Content,
    kParserState_End
} ParserState;

@interface WSKMIMEStreamParser : NSObject
// Why the last -appendBytes:length: or -close returned NO.
//
// The parser fails for seven unrelated reasons; reporting them all as a bare NO leaves the
// request guessing — and guessing "the client's data is malformed" turns a full temp
// directory or a momentarily exhausted budget into 400, telling a client never to try again.
@property (nonatomic, readonly) WSKRequestBodyErrorCode failureCode;
@property (nonatomic, readonly, nullable) NSError *failureError;  // Set instead when an errno is the truth (a full disk)
@end

static NSData *_newlineData = nil;
static NSData *_newlinesData = nil;
static NSData *_dashNewlineData = nil;

@implementation WSKMultiPart

- (instancetype)initWithControlName:(NSString *_Nonnull)name contentType:(NSString *_Nonnull)type {
    if ((self = [super init])) {
        _controlName = [name copy];
        _contentType = [type copy];
        _mimeType = (NSString *)WSKTruncateHeaderValue(_contentType);
    }

    return self;
}

@end

@implementation WSKMultiPartArgument

- (instancetype)initWithControlName:(NSString *_Nonnull)name contentType:(NSString *_Nonnull)type data:(NSData *_Nonnull)data {
    if ((self = [super initWithControlName:name contentType:type])) {
        _data = data;

        if ([self.contentType hasPrefix:@"text/"]) {
            NSString *const charset = WSKExtractHeaderValueParameter(self.contentType, @"charset");
            _string = [[NSString alloc] initWithData:_data encoding:WSKStringEncodingFromCharset(charset)];
        }
    }

    return self;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<%@ | '%@' | %lu bytes>", [self class], self.mimeType, (unsigned long)_data.length];
}

@end

@implementation WSKMultiPartFile

- (instancetype)initWithControlName:(NSString *_Nonnull)name contentType:(NSString *_Nonnull)type fileName:(NSString *_Nonnull)fileName temporaryPath:(NSString *_Nonnull)temporaryPath {
    if ((self = [super initWithControlName:name contentType:type])) {
        _fileName = [fileName copy];
        _temporaryPath = [temporaryPath copy];
    }

    return self;
}

- (void)dealloc {
    unlink([_temporaryPath fileSystemRepresentation]);
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<%@ | '%@' | '%@>'", [self class], self.mimeType, _fileName];
}

@end

@implementation WSKMIMEStreamParser {
    NSData *_boundary;
    NSString *_defaultcontrolName;
    ParserState _state;
    NSMutableData *_data;
    NSMutableArray<WSKMultiPartArgument *> *_arguments;
    NSMutableArray<WSKMultiPartFile *> *_files;

    NSString *_controlName;
    NSString *_fileName;
    NSString *_contentType;
    NSString *_tmpPath;
    int _tmpFile;
    WSKMIMEStreamParser *_subParser;
    NSUInteger _depth;  // Nesting level; 0 for the top-level parser, +1 per multipart/mixed
    WSKMIMEStreamBudget *_budget;              // Shared with every sub-parser
    WSKMemoryReservation *_workingReservation;  // This parser's own working buffer
    WSKRequestBodyErrorCode _failureCode;
    NSError *_failureError;
}

// A sub-parser's failure is the whole body's failure, so the reason has to travel up with it.
- (WSKRequestBodyErrorCode)failureCode {
    if (_subParser && (_subParser.failureCode != kWSKRequestBodyError_Malformed)) {
        return _subParser.failureCode;
    }

    return _failureCode ? _failureCode : kWSKRequestBodyError_Malformed;
}

- (NSError *)failureError {
    return _failureError ? _failureError : _subParser.failureError;
}

+ (void)initialize {
    if (_newlineData == nil) {
        _newlineData = [[NSData alloc] initWithBytes:"\r\n" length:2];
        WSK_DCHECK(_newlineData);
    }

    if (_newlinesData == nil) {
        _newlinesData = [[NSData alloc] initWithBytes:"\r\n\r\n" length:4];
        WSK_DCHECK(_newlinesData);
    }

    if (_dashNewlineData == nil) {
        _dashNewlineData = [[NSData alloc] initWithBytes:"--\r\n" length:4];
        WSK_DCHECK(_dashNewlineData);
    }
}

- (instancetype)initWithBoundary:(NSString *_Nonnull)boundary defaultControlName:(NSString *_Nullable)name arguments:(NSMutableArray<WSKMultiPartArgument *> *_Nonnull)arguments files:(NSMutableArray<WSKMultiPartFile *> *_Nonnull)files depth:(NSUInteger)depth budget:(WSKMIMEStreamBudget *_Nonnull)budget {
    // [super init] and the fd sentinel are established BEFORE any failure return. Under ARC a
    // nil-returning initializer still deallocates its receiver, so -dealloc runs — and on a
    // zeroed object `_tmpFile` is 0, making its `close(_tmpFile)` a close(0) of a descriptor
    // this object never owned, tearing down whatever live connection was recycled onto it.
    if (!(self = [super init])) {
        return nil;
    }

    _tmpFile = -1;  // fd 0 is legal, so -1 (not 0) is the "no temporary file" sentinel

    NSData *data = boundary.length ? [[NSString stringWithFormat:@"--%@", boundary] dataUsingEncoding:NSASCIIStringEncoding] : nil;

    if (data == nil) {
        // A missing or non-ASCII "boundary" parameter is ordinary malformed client input
        // (the caller passes the value straight from the Content-Type header), so reject
        // it rather than abort in debug.
        WSK_LOG_ERROR(@"Missing or invalid 'boundary' parameter for 'multipart/form-data'");
        return nil;
    }

    // Refuse to nest deeper than the cap: returning nil here surfaces as a parse
    // failure at the sub-parser creation site, so a malicious deeply-nested
    // multipart/mixed body is rejected before it can overflow the stack.
    if (depth > kMultiPartMaxDepth) {
        WSK_LOG_ERROR(@"Rejecting 'multipart/mixed' nested deeper than %i levels", (int)kMultiPartMaxDepth);
        return nil;
    }

    _boundary = data;
    _defaultcontrolName = name;
    _arguments = arguments;
    _files = files;
    _data = [[NSMutableData alloc] initWithCapacity:kMultiPartBufferSize];
    _state = kParserState_Start;
    _depth = depth;
    _budget = budget;
    _workingReservation = [[WSKMemoryReservation alloc] init];

    return self;
}

- (void)dealloc {
    if (_tmpFile >= 0) {
        close(_tmpFile);
        unlink([_tmpPath fileSystemRepresentation]);
    }
}

// http://www.w3.org/TR/html401/interact/forms.html#h-17.13.4.2
- (BOOL)_parseData {
    BOOL success = YES;

    // Iterate over the parts rather than recursing once per part: a body made of
    // many tiny parts delivered in a single read would otherwise recurse thousands
    // of frames deep and overflow the worker-thread stack.
    while (1) {
    if (_state == kParserState_Headers) {
        NSRange range = [_data rangeOfData:_newlinesData options:0 range:NSMakeRange(0, _data.length)];

        if (range.location != NSNotFound) {
            // Bound the part's header block. The budget below charges only part *content*,
            // but the control name, file name and content type parsed out of these headers
            // are retained for the life of the request too — so without this a body of parts
            // each carrying a multi-megabyte name=".…" grows memory without limit while the
            // budget still reads zero. Real part headers are a few hundred bytes.
            if (range.location > kMultiPartMaxHeadersLength) {
                WSK_LOG_ERROR(@"Headers of a part of 'multipart/form-data' exceed the %i byte limit", (int)kMultiPartMaxHeadersLength);
                _failureCode = kWSKRequestBodyError_TooLarge;
                return NO;
            }

            _controlName = nil;
            _fileName = nil;
            _contentType = nil;
            _tmpPath = nil;
            _subParser = nil;
            NSString *const headers = [[NSString alloc] initWithData:[_data subdataWithRange:NSMakeRange(0, range.location)] encoding:NSUTF8StringEncoding];

            if (headers) {
                for (NSString *header in [headers componentsSeparatedByString:@"\r\n"]) {
                    NSRange subRange = [header rangeOfString:@":"];

                    if (subRange.location != NSNotFound) {
                        NSString *const name = [header substringToIndex:subRange.location];
                        NSString *const value = [[header substringFromIndex:(subRange.location + subRange.length)] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];

                        if ([name caseInsensitiveCompare:@"Content-Type"] == NSOrderedSame) {
                            _contentType = WSKNormalizeHeaderValue(value);
                        } else if ([name caseInsensitiveCompare:@"Content-Disposition"] == NSOrderedSame) {
                            NSString *const contentDisposition = WSKNormalizeHeaderValue(value);

                            if ([WSKTruncateHeaderValue(contentDisposition) isEqualToString:@"form-data"]) {
                                _controlName = WSKExtractHeaderValueParameter(contentDisposition, @"name");
                                _fileName = WSKExtractHeaderValueParameter(contentDisposition, @"filename");
                            } else if ([WSKTruncateHeaderValue(contentDisposition) isEqualToString:@"file"]) {
                                _controlName = _defaultcontrolName;
                                _fileName = WSKExtractHeaderValueParameter(contentDisposition, @"filename");
                            }
                        }
                    }  // A header line without a colon is malformed client input: skip it
                }

                if (_contentType == nil) {
                    _contentType = @"text/plain";
                }
            } else {
                // Part headers that are not valid UTF-8 are ordinary malformed input, not an
                // unreachable state; leaving _controlName nil fails the parse just below.
                WSK_LOG_ERROR(@"Failed decoding headers in part of 'multipart/form-data'");
            }

            if (_controlName) {
                if ([WSKTruncateHeaderValue(_contentType) isEqualToString:@"multipart/mixed"]) {
                    NSString *const boundary = WSKExtractHeaderValueParameter(_contentType, @"boundary");
                    _subParser = [[WSKMIMEStreamParser alloc] initWithBoundary:boundary defaultControlName:_controlName arguments:_arguments files:_files depth:(_depth + 1) budget:_budget];

                    if (_subParser == nil) {
                        // A nil sub-parser is now an expected rejection (nesting past the
                        // depth cap, or a missing/invalid child boundary), not an
                        // unreachable state — so fail the parse rather than WSK_DNOT_REACHED
                        // (which aborts in debug builds).
                        success = NO;
                    }
                } else if (_fileName) {
                    NSString *const path = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSProcessInfo processInfo] globallyUniqueString]];
                    _tmpFile = open([path fileSystemRepresentation], O_CREAT | O_TRUNC | O_WRONLY, S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH);

                    if (_tmpFile >= 0) {
                        _tmpPath = [path copy];
                    } else {
                        // A full or unwritable temporary directory is an environment condition
                        // rather than an unreachable state.
                        WSK_LOG_ERROR(@"Failed creating temporary file for part of 'multipart/form-data': %s (%i)", strerror(errno), errno);
                        // The environment, not the client. Carrying the errno is what lets a full
                        // volume reach WSKServerErrorStatusCodeForError's 507 rather than being
                        // reported as malformed input the client must never send again.
                        _failureError = WSKMakePosixError(errno);
                        success = NO;
                    }
                }
            } else {
                // A part with no usable Content-Disposition "name" parameter — malformed
                // client input, so fail the parse rather than abort in debug.
                WSK_LOG_ERROR(@"Missing control name in part of 'multipart/form-data'");
                success = NO;
            }

            [_data replaceBytesInRange:NSMakeRange(0, range.location + range.length) withBytes:NULL length:0];
            _state = kParserState_Content;
        }
    }

    if ((_state == kParserState_Start) || (_state == kParserState_Content)) {
        NSRange range = [_data rangeOfData:_boundary options:0 range:NSMakeRange(0, _data.length)];

        if (range.location != NSNotFound) {
            NSRange subRange = NSMakeRange(range.location + range.length, _data.length - range.location - range.length);
            NSRange subRange1 = [_data rangeOfData:_newlineData options:NSDataSearchAnchored range:subRange];
            NSRange subRange2 = [_data rangeOfData:_dashNewlineData options:NSDataSearchAnchored range:subRange];

            if ((subRange1.location != NSNotFound) || (subRange2.location != NSNotFound)) {
                if (_state == kParserState_Content) {
                    const void *dataBytes = _data.bytes;
                    // range.location is the offset of the boundary delimiter; the part's
                    // content (including its trailing CRLF) is everything before it. Guard
                    // the "- 2" that strips that CRLF, so a delimiter at offset 0/1 (a part
                    // with no content, e.g. a closing "--boundary--" placed with no leading
                    // CRLF) cannot underflow NSUInteger into a ~18-exabyte length and crash.
                    NSUInteger contentLength = range.location;
                    NSUInteger dataLength = (contentLength >= 2) ? (contentLength - 2) : 0;

                    if (_controlName == nil) {
                        // The Headers state refuses a nameless part before the Content state is
                        // ever entered, so this cannot fire today — but that invariant lives a
                        // whole state-machine iteration away (the analyzer flags the argument
                        // constructor below without it), the constructors' nonnull contracts
                        // depend on it, and every byte here is remote input: log-and-fail,
                        // never assert.
                        WSK_LOG_ERROR(@"Multipart part reached the content state without a control name");
                        success = NO;
                    } else if (_subParser) {
                        if (![_subParser appendBytes:dataBytes length:contentLength] || ![_subParser isAtEnd]) {
                            // Reachable on malicious/malformed nested content — the sub-parser
                            // rejected it (depth cap or in-memory buffer cap) or the nested
                            // part never closed. Fail the parse rather than abort in debug.
                            success = NO;
                        }

                        _subParser = nil;
                    } else if (_budget->partCount >= kMultiPartMaxParts) {
                        WSK_LOG_ERROR(@"'multipart/form-data' body exceeds the %i part limit", (int)kMultiPartMaxParts);
                        _failureCode = kWSKRequestBodyError_TooLarge;
                        success = NO;

                        if (_tmpPath) {  // Drop the part already staged on disk rather than orphaning it
                            close(_tmpFile);
                            _tmpFile = -1;
                            unlink([_tmpPath fileSystemRepresentation]);
                            _tmpPath = nil;
                        }
                    } else if (_tmpPath) {
                        ssize_t result = write(_tmpFile, dataBytes, dataLength);
                        // errno is only defined after a FAILING call, and a SHORT write is not a
                        // failing call — it sets nothing. Capture each call's errno at the call,
                        // or the read in the failure branch below picks up whatever stale value
                        // the last unrelated syscall left there (and close() clobbers write()'s).
                        int const writeErrno = (result < 0) ? errno : 0;
                        int closeResult = close(_tmpFile);  // Always close (no short-circuit) so the fd never leaks on a write failure.
                        int const closeErrno = (closeResult != 0) ? errno : 0;
                        _tmpFile = -1;

                        if ((result == (ssize_t)dataLength) && (closeResult == 0)) {
                            _budget->partCount += 1;
                            WSKMultiPartFile *const file = [[WSKMultiPartFile alloc] initWithControlName:_controlName contentType:_contentType fileName:_fileName temporaryPath:_tmpPath];
                            [_files addObject:file];
                        } else {
                            // A short write means the temporary directory filled up — an ordinary
                            // environment condition, not an unreachable state, so fail the parse
                            // rather than abort in debug. It also sets no errno, hence the
                            // ENOSPC default — which is what a short write means here anyway.
                            WSK_LOG_ERROR(@"Failed writing part of 'multipart/form-data' to disk");
                            int const failureErrno = writeErrno ? writeErrno : (closeErrno ? closeErrno : ENOSPC);
                            _failureError = WSKMakePosixError(failureErrno);
                            success = NO;
                            unlink([_tmpPath fileSystemRepresentation]);  // Remove the orphaned temp file; -dealloc can't (we clear _tmpPath below).
                        }

                        _tmpPath = nil;
                    } else if (_budget->argumentBytes + dataLength > WSKMaxInMemoryBodyLength()) {
                        // Every argument part stays in memory for the life of the request, so the
                        // working-buffer cap in -appendBytes: does not bound them: a body of many
                        // individually-legal parts would otherwise grow without limit. File parts
                        // are drained to disk and so are governed by the part count instead.
                        WSK_LOG_ERROR(@"Multipart form arguments retained in memory exceed the %lu byte limit", (unsigned long)WSKMaxInMemoryBodyLength());
                        _failureCode = kWSKRequestBodyError_TooLarge;
                        success = NO;
                    } else if (![_budget.reservation reserveBytes:(_budget->argumentBytes + dataLength)]) {
                        WSK_LOG_ERROR(@"Refusing multipart argument: the server is already holding its %lu byte in-memory limit across all connections", (unsigned long)kWSKMaxTotalInMemoryLength);
                        _failureCode = kWSKRequestBodyError_ServerAtCapacity;
                        success = NO;
                    } else {
                        _budget->partCount += 1;
                        _budget->argumentBytes += dataLength;
                        // -subdataWithRange: rather than -initWithBytes:length: over the raw
                        // pointer: same copy of the same bytes, but bounds-checked, and with no
                        // pointer for an empty argument value (an ordinary blank form field) to
                        // turn into the recurring nil-into-Foundation class — .bytes is nullable
                        // and -initWithBytes: declares its pointer non-null, which is what the
                        // analyzer's nullability checker flagged.
                        NSData *const data = [_data subdataWithRange:NSMakeRange(0, dataLength)];
                        WSKMultiPartArgument *const argument = [[WSKMultiPartArgument alloc] initWithControlName:_controlName contentType:_contentType data:data];
                        [_arguments addObject:argument];
                    }
                }

                if (subRange1.location != NSNotFound) {
                    [_data replaceBytesInRange:NSMakeRange(0, subRange1.location + subRange1.length) withBytes:NULL length:0];
                    _state = kParserState_Headers;
                    continue;  // Parse the next part on the next loop iteration (was a recursive -_parseData call).
                } else {
                    _state = kParserState_End;
                }
            }
        } else {
            NSUInteger margin = 2 * _boundary.length;

            if (_data.length > margin) {
                NSUInteger length = _data.length - margin;

                if (_subParser) {
                    if ([_subParser appendBytes:_data.bytes length:length]) {
                        [_data replaceBytesInRange:NSMakeRange(0, length) withBytes:NULL length:0];
                    } else {
                        // The sub-parser rejected the streamed nested content (depth or
                        // buffer cap) — expected on malicious input, so fail without abort.
                        success = NO;
                    }
                } else if (_tmpPath) {
                    ssize_t result = write(_tmpFile, _data.bytes, length);

                    if (result == (ssize_t)length) {
                        [_data replaceBytesInRange:NSMakeRange(0, length) withBytes:NULL length:0];
                    } else {
                        // As above: a short write means the temporary directory filled up.
                        WSK_LOG_ERROR(@"Failed streaming part of 'multipart/form-data' to disk: %s (%i)", strerror(errno), errno);
                        _failureError = WSKMakePosixError(errno);
                        success = NO;
                    }
                }
            }
        }
    }
    break;  // No further complete part was found in this pass: wait for more data.
    }

    return success;
}

- (BOOL)appendBytes:(const void *)bytes length:(NSUInteger)length {
    // Bound the parser's working buffer. File-part content is drained to disk as it
    // arrives, so this only limits data genuinely held in memory: an oversized
    // argument part, or a malformed stream whose content contains the boundary token
    // without the trailing CRLF (which otherwise wedges the parser and grows the
    // buffer without bound).
    if (_data.length + length > WSKMaxInMemoryBodyLength()) {
        WSK_LOG_ERROR(@"Multipart form data buffered in memory exceeds the %lu byte limit", (unsigned long)WSKMaxInMemoryBodyLength());
        _failureCode = kWSKRequestBodyError_TooLarge;
        return NO;
    }

    if (![_workingReservation reserveBytes:(_data.length + length)]) {
        WSK_LOG_ERROR(@"Refusing multipart data: the server is already holding its %lu byte in-memory limit across all connections", (unsigned long)kWSKMaxTotalInMemoryLength);
        _failureCode = kWSKRequestBodyError_ServerAtCapacity;
        return NO;
    }

    [_data appendBytes:bytes length:length];
    BOOL success = [self _parseData];
    // -_parseData drains whatever it consumed, so give the difference straight back rather
    // than letting this parser's reservation ratchet upward across a long body.
    [_workingReservation reserveBytes:_data.length];
    return success;
}

- (BOOL)isAtEnd {
    return (_state == kParserState_End);
}

@end

@interface WSKMultiPartFormRequest ()
@property (nonatomic) NSMutableArray<WSKMultiPartArgument *> *arguments;
@property (nonatomic) NSMutableArray<WSKMultiPartFile *> *files;
@end

@implementation WSKMultiPartFormRequest {
    WSKMIMEStreamParser *_parser;
}

+ (NSString *)mimeType {
    return @"multipart/form-data";
}

- (instancetype)initWithMethod:(NSString *)method url:(NSURL *)url headers:(NSDictionary<NSString *, NSString *> *)headers path:(NSString *)path query:(NSDictionary<NSString *, NSString *> *)query {
    if ((self = [super initWithMethod:method url:url headers:headers path:path query:query])) {
        _arguments = [[NSMutableArray alloc] init];
        _files = [[NSMutableArray alloc] init];
    }

    return self;
}

// Builds the error from the parser's own verdict rather than assuming the client's data was
// malformed. Seven unrelated conditions come out of -appendBytes: as a bare NO — two per-request
// size caps, two process-wide reservations, a part-count cap, a header cap, and a temp file that
// could not be written. Reporting the last three as 400 tells a client never to retry something a
// little free disk space or a moment's wait would fix.
- (NSError *)_errorForParserFailure:(NSString *)description {
    if (_parser == nil) {
        // No parser to ask: either the boundary parameter was missing or unusable, or the body
        // ended mid-part. Both are the client's data. Stated explicitly because messaging a nil
        // parser would return a ZEROED code that matches no case and silently degrade to 500.
        return [NSError errorWithDomain:kWSKErrorDomain code:kWSKRequestBodyError_Malformed userInfo:@{NSLocalizedDescriptionKey: description}];
    }

    NSError *const underlying = _parser.failureError;

    if (underlying) {
        return underlying;  // An errno is the truth; WSKServerErrorStatusCodeForError maps a full volume to 507.
    }

    return [NSError errorWithDomain:kWSKErrorDomain code:_parser.failureCode userInfo:@{NSLocalizedDescriptionKey: description}];
}

- (BOOL)open:(NSError **)error {
    NSString *const boundary = WSKExtractHeaderValueParameter(self.contentType, @"boundary");

    _parser = [[WSKMIMEStreamParser alloc] initWithBoundary:boundary defaultControlName:nil arguments:_arguments files:_files depth:0 budget:[[WSKMIMEStreamBudget alloc] init]];

    if (_parser == nil) {
        if (error) {
            *error = [self _errorForParserFailure:@"Failed starting to parse multipart form data"];
        }

        return NO;
    }

    return YES;
}

- (BOOL)writeData:(NSData *)data error:(NSError **)error {
    if (![_parser appendBytes:data.bytes length:data.length]) {
        if (error) {
            *error = [self _errorForParserFailure:@"Failed continuing to parse multipart form data"];
        }

        return NO;
    }

    return YES;
}

- (BOOL)close:(NSError **)error {
    BOOL const atEnd = [_parser isAtEnd];

    if (!atEnd) {
        // Built BEFORE _parser is released: it is the only thing that knows why. Releasing first
        // left the helper messaging nil and reporting every truncated body as generically
        // malformed, losing a disk-full or capacity reason recorded during the parse.
        NSError *const failure = [self _errorForParserFailure:@"Failed finishing to parse multipart form data"];
        _parser = nil;

        if (error) {
            *error = failure;
        }

        return NO;
    }

    _parser = nil;

    return YES;
}

- (WSKMultiPartArgument *)firstArgumentForControlName:(NSString *)name {
    for (WSKMultiPartArgument *argument in _arguments) {
        if ([argument.controlName isEqualToString:name]) {
            return argument;
        }
    }

    return nil;
}

- (WSKMultiPartFile *)firstFileForControlName:(NSString *)name {
    for (WSKMultiPartFile *file in _files) {
        if ([file.controlName isEqualToString:name]) {
            return file;
        }
    }

    return nil;
}

- (NSString *)description {
    NSMutableString *description = [NSMutableString stringWithString:[super description]];

    if (_arguments.count) {
        [description appendString:@"\n"];

        for (WSKMultiPartArgument *argument in _arguments) {
            [description appendFormat:@"\n%@ (%@)\n", argument.controlName, argument.contentType];
            [description appendString:WSKDescribeData(argument.data, argument.contentType)];
        }
    }

    if (_files.count) {
        [description appendString:@"\n"];

        for (WSKMultiPartFile *file in _files) {
            [description appendFormat:@"\n%@ (%@): %@\n{%@}", file.controlName, file.contentType, file.fileName, file.temporaryPath];
        }
    }

    return description;
}

@end
