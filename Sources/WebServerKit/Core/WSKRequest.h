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

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/**
 *  Attribute key to retrieve an NSArray containing NSStrings from a WSKRequest
 *  with the contents of any regular expression captures done on the request path.
 *
 *  @warning This attribute will only be set on the request if adding a handler using
 *  -addHandlerForMethod:pathRegex:requestClass:processBlock:.
 */
extern NSString *const WSKRequestAttribute_RegexCaptures;

/**
 *  This protocol is used by the WSKConnection to communicate with
 *  the WSKRequest and write the received HTTP body data.
 *
 *  Note that multiple WSKBodyWriter objects can be chained together
 *  internally e.g. to automatically decode gzip encoded content before
 *  passing it on to the WSKRequest.
 *
 *  @warning These methods can be called on any GCD thread.
 */
@protocol WSKBodyWriter <NSObject>

/**
 *  This method is called before any body data is received.
 *
 *  It should return YES on success or NO on failure and set the "error" argument
 *  which is guaranteed to be non-NULL.
 */
- (BOOL)open:(NSError **)error;

/**
 *  This method is called whenever body data has been received.
 *
 *  It should return YES on success or NO on failure and set the "error" argument
 *  which is guaranteed to be non-NULL.
 */
- (BOOL)writeData:(NSData *)data error:(NSError **)error;

/**
 *  This method is called after all body data has been received.
 *
 *  It should return YES on success or NO on failure and set the "error" argument
 *  which is guaranteed to be non-NULL.
 */
- (BOOL)close:(NSError **)error;

@end

/**
 *  The WSKRequest class is instantiated by the WSKConnection
 *  after the HTTP headers have been received. Each instance wraps a single HTTP
 *  request. If a body is present, the methods from the WSKBodyWriter
 *  protocol will be called by the WSKConnection to receive it.
 *
 *  The default implementation of the WSKBodyWriter protocol on the class
 *  simply ignores the body data.
 *
 *  @warning WSKRequest instances can be created and used on any GCD thread.
 */
@interface WSKRequest : NSObject <WSKBodyWriter>

/**
 *  Returns the HTTP method for the request.
 */
@property (nonatomic, readonly) NSString *method;

/**
 *  Returns YES if the client actually sent HEAD and the server rewrote the method to GET
 *  because -shouldAutomaticallyMapHEADToGET is enabled. In that case `method` reads "GET",
 *  the handler runs as if for a GET, and the response body is then discarded unsent.
 *
 *  Handlers that merely return bytes can ignore this. It matters to a handler whose response
 *  *is* a long-lived resource — a stream that registers a channel, holds a slot, or otherwise
 *  costs something for as long as the client reads it — because for a mapped HEAD nothing
 *  will ever read it: the body block is never invoked, so whatever the handler allocated is
 *  left to be cleaned up by a timeout instead of by the client going away. Such a handler
 *  should return a bodiless response (correct for HEAD anyway) rather than allocate.
 */
@property (nonatomic, readonly, getter=isVirtualHEAD) BOOL virtualHEAD;

/**
 *  Returns the URL for the request.
 */
@property (nonatomic, readonly) NSURL *URL;

/**
 *  Returns the HTTP headers for the request.
 */
@property (nonatomic, readonly) NSDictionary<NSString *, NSString *> *headers;

/**
 *  Returns the path component of the URL for the request.
 */
@property (nonatomic, readonly) NSString *path;

/**
 *  Returns the parsed and unescaped query component of the URL for the request.
 *
 *  @warning This property will be nil if there is no query in the URL.
 */
@property (nonatomic, readonly, nullable) NSDictionary<NSString *, NSString *> *query;

/**
 *  Returns the content type for the body of the request parsed from the
 *  "Content-Type" header.
 *
 *  This property will be nil if the request has no body or set to
 *  "application/octet-stream" if a body is present but there was no
 *  "Content-Type" header.
 */
@property (nonatomic, readonly, nullable) NSString *contentType;

/**
 *  Returns the content length for the body of the request parsed from the
 *  "Content-Length" header.
 *
 *  This property will be set to "NSUIntegerMax" if the request has no body or
 *  if there is a body but no "Content-Length" header, typically because
 *  chunked transfer encoding is used.
 */
@property (nonatomic, readonly) NSUInteger contentLength;

/**
 *  Returns the parsed "If-Modified-Since" header or nil if absent or malformed.
 */
@property (nonatomic, readonly, nullable) NSDate *ifModifiedSince;

/**
 *  Returns the parsed "If-None-Match" header or nil if absent or malformed.
 */
@property (nonatomic, readonly, nullable) NSString *ifNoneMatch;

/**
 *  Returns the raw "If-Range" header or nil if absent.
 *
 *  A client resuming a download sends this alongside "Range" to say "send me that range
 *  only if the representation is still the one I already have". Pass it to
 *  -[WSKFileResponse initWithFile:byteRange:isAttachment:ifRange:mimeTypeOverrides:]
 *  so a changed file is served whole rather than as a range spliced onto a stale prefix.
 */
@property (nonatomic, readonly, nullable) NSString *ifRange;

/**
 *  Returns the parsed "Range" header or (NSUIntegerMax, 0) if absent or malformed.
 *  The range will be set to (offset, length) if expressed from the beginning
 *  of the entity body, or (NSUIntegerMax, length) if expressed from its end.
 */
@property (nonatomic, readonly) NSRange byteRange;

/**
 *  Returns YES if the client supports gzip content encoding according to the
 *  "Accept-Encoding" header.
 */
@property (nonatomic, readonly) BOOL acceptsGzipContentEncoding;

/**
 *  Returns the address of the local peer (i.e. server) for the request
 *  as a raw "struct sockaddr".
 */
@property (nonatomic, readonly) NSData *localAddressData;

/**
 *  Returns the address of the local peer (i.e. server) for the request
 *  as a string.
 */
@property (nonatomic, readonly) NSString *localAddressString;

/**
 *  Returns the address of the remote peer (i.e. client) for the request
 *  as a raw "struct sockaddr".
 */
@property (nonatomic, readonly) NSData *remoteAddressData;

/**
 *  Returns the address of the remote peer (i.e. client) for the request
 *  as a string.
 */
@property (nonatomic, readonly) NSString *remoteAddressString;

/**
 *  This method is the designated initializer for the class.
 */
- (instancetype)initWithMethod:(NSString *)method url:(NSURL *)url headers:(NSDictionary<NSString *, NSString *> *)headers path:(NSString *)path query:(nullable NSDictionary<NSString *, NSString *> *)query;

/**
 *  Convenience method that checks if the contentType property is defined.
 */
- (BOOL)hasBody;

/**
 *  Convenience method that checks if the byteRange property is defined.
 */
- (BOOL)hasByteRange;

/**
 *  Retrieves an attribute associated with this request using the given key.
 *
 *  @return The attribute value for the key.
 */
- (nullable id)attributeForKey:(NSString *)key;

@end

NS_ASSUME_NONNULL_END
