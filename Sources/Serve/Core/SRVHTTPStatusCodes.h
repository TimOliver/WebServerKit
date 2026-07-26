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

// http://www.w3.org/Protocols/rfc2616/rfc2616-sec10.html
// http://www.iana.org/assignments/http-status-codes/http-status-codes.xhtml

#import <Foundation/Foundation.h>

/**
 *  Convenience constants for "informational" HTTP status codes.
 */
typedef NS_ENUM(NSInteger, SRVInformationalHTTPStatusCode) {
    kSRVHTTPStatusCode_Continue = 100,
    kSRVHTTPStatusCode_SwitchingProtocols = 101,
    kSRVHTTPStatusCode_Processing = 102
};

/**
 *  Convenience constants for "successful" HTTP status codes.
 */
typedef NS_ENUM(NSInteger, SRVSuccessfulHTTPStatusCode) {
    kSRVHTTPStatusCode_OK = 200,
    kSRVHTTPStatusCode_Created = 201,
    kSRVHTTPStatusCode_Accepted = 202,
    kSRVHTTPStatusCode_NonAuthoritativeInformation = 203,
    kSRVHTTPStatusCode_NoContent = 204,
    kSRVHTTPStatusCode_ResetContent = 205,
    kSRVHTTPStatusCode_PartialContent = 206,
    kSRVHTTPStatusCode_MultiStatus = 207,
    kSRVHTTPStatusCode_AlreadyReported = 208
};

/**
 *  Convenience constants for "redirection" HTTP status codes.
 */
typedef NS_ENUM(NSInteger, SRVRedirectionHTTPStatusCode) {
    kSRVHTTPStatusCode_MultipleChoices = 300,
    kSRVHTTPStatusCode_MovedPermanently = 301,
    kSRVHTTPStatusCode_Found = 302,
    kSRVHTTPStatusCode_SeeOther = 303,
    kSRVHTTPStatusCode_NotModified = 304,
    kSRVHTTPStatusCode_UseProxy = 305,
    kSRVHTTPStatusCode_TemporaryRedirect = 307,
    kSRVHTTPStatusCode_PermanentRedirect = 308
};

/**
 *  Convenience constants for "client error" HTTP status codes.
 */
typedef NS_ENUM(NSInteger, SRVClientErrorHTTPStatusCode) {
    kSRVHTTPStatusCode_BadRequest = 400,
    kSRVHTTPStatusCode_Unauthorized = 401,
    kSRVHTTPStatusCode_PaymentRequired = 402,
    kSRVHTTPStatusCode_Forbidden = 403,
    kSRVHTTPStatusCode_NotFound = 404,
    kSRVHTTPStatusCode_MethodNotAllowed = 405,
    kSRVHTTPStatusCode_NotAcceptable = 406,
    kSRVHTTPStatusCode_ProxyAuthenticationRequired = 407,
    kSRVHTTPStatusCode_RequestTimeout = 408,
    kSRVHTTPStatusCode_Conflict = 409,
    kSRVHTTPStatusCode_Gone = 410,
    kSRVHTTPStatusCode_LengthRequired = 411,
    kSRVHTTPStatusCode_PreconditionFailed = 412,
    kSRVHTTPStatusCode_RequestEntityTooLarge = 413,
    kSRVHTTPStatusCode_RequestURITooLong = 414,
    kSRVHTTPStatusCode_UnsupportedMediaType = 415,
    kSRVHTTPStatusCode_RequestedRangeNotSatisfiable = 416,
    kSRVHTTPStatusCode_ExpectationFailed = 417,
    kSRVHTTPStatusCode_MisdirectedRequest = 421,
    kSRVHTTPStatusCode_UnprocessableEntity = 422,
    kSRVHTTPStatusCode_Locked = 423,
    kSRVHTTPStatusCode_FailedDependency = 424,
    kSRVHTTPStatusCode_UpgradeRequired = 426,
    kSRVHTTPStatusCode_PreconditionRequired = 428,
    kSRVHTTPStatusCode_TooManyRequests = 429,
    kSRVHTTPStatusCode_RequestHeaderFieldsTooLarge = 431
};

/**
 *  Convenience constants for "server error" HTTP status codes.
 */
typedef NS_ENUM(NSInteger, SRVServerErrorHTTPStatusCode) {
    kSRVHTTPStatusCode_InternalServerError = 500,
    kSRVHTTPStatusCode_NotImplemented = 501,
    kSRVHTTPStatusCode_BadGateway = 502,
    kSRVHTTPStatusCode_ServiceUnavailable = 503,
    kSRVHTTPStatusCode_GatewayTimeout = 504,
    kSRVHTTPStatusCode_HTTPVersionNotSupported = 505,
    kSRVHTTPStatusCode_InsufficientStorage = 507,
    kSRVHTTPStatusCode_LoopDetected = 508,
    kSRVHTTPStatusCode_NotExtended = 510,
    kSRVHTTPStatusCode_NetworkAuthenticationRequired = 511
};
