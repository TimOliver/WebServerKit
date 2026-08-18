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

NS_ASSUME_NONNULL_BEGIN

/**
 *  Convenience constants for "informational" HTTP status codes.
 */
typedef NS_ENUM(NSInteger, WSKInformationalHTTPStatusCode) {
    kWSKHTTPStatusCode_Continue = 100,
    kWSKHTTPStatusCode_SwitchingProtocols = 101,
    kWSKHTTPStatusCode_Processing = 102
};

/**
 *  Convenience constants for "successful" HTTP status codes.
 */
typedef NS_ENUM(NSInteger, WSKSuccessfulHTTPStatusCode) {
    kWSKHTTPStatusCode_OK = 200,
    kWSKHTTPStatusCode_Created = 201,
    kWSKHTTPStatusCode_Accepted = 202,
    kWSKHTTPStatusCode_NonAuthoritativeInformation = 203,
    kWSKHTTPStatusCode_NoContent = 204,
    kWSKHTTPStatusCode_ResetContent = 205,
    kWSKHTTPStatusCode_PartialContent = 206,
    kWSKHTTPStatusCode_MultiStatus = 207,
    kWSKHTTPStatusCode_AlreadyReported = 208
};

/**
 *  Convenience constants for "redirection" HTTP status codes.
 */
typedef NS_ENUM(NSInteger, WSKRedirectionHTTPStatusCode) {
    kWSKHTTPStatusCode_MultipleChoices = 300,
    kWSKHTTPStatusCode_MovedPermanently = 301,
    kWSKHTTPStatusCode_Found = 302,
    kWSKHTTPStatusCode_SeeOther = 303,
    kWSKHTTPStatusCode_NotModified = 304,
    kWSKHTTPStatusCode_UseProxy = 305,
    kWSKHTTPStatusCode_TemporaryRedirect = 307,
    kWSKHTTPStatusCode_PermanentRedirect = 308
};

/**
 *  Convenience constants for "client error" HTTP status codes.
 */
typedef NS_ENUM(NSInteger, WSKClientErrorHTTPStatusCode) {
    kWSKHTTPStatusCode_BadRequest = 400,
    kWSKHTTPStatusCode_Unauthorized = 401,
    kWSKHTTPStatusCode_PaymentRequired = 402,
    kWSKHTTPStatusCode_Forbidden = 403,
    kWSKHTTPStatusCode_NotFound = 404,
    kWSKHTTPStatusCode_MethodNotAllowed = 405,
    kWSKHTTPStatusCode_NotAcceptable = 406,
    kWSKHTTPStatusCode_ProxyAuthenticationRequired = 407,
    kWSKHTTPStatusCode_RequestTimeout = 408,
    kWSKHTTPStatusCode_Conflict = 409,
    kWSKHTTPStatusCode_Gone = 410,
    kWSKHTTPStatusCode_LengthRequired = 411,
    kWSKHTTPStatusCode_PreconditionFailed = 412,
    kWSKHTTPStatusCode_RequestEntityTooLarge = 413,
    kWSKHTTPStatusCode_RequestURITooLong = 414,
    kWSKHTTPStatusCode_UnsupportedMediaType = 415,
    kWSKHTTPStatusCode_RequestedRangeNotSatisfiable = 416,
    kWSKHTTPStatusCode_ExpectationFailed = 417,
    kWSKHTTPStatusCode_MisdirectedRequest = 421,
    kWSKHTTPStatusCode_UnprocessableEntity = 422,
    kWSKHTTPStatusCode_Locked = 423,
    kWSKHTTPStatusCode_FailedDependency = 424,
    kWSKHTTPStatusCode_UpgradeRequired = 426,
    kWSKHTTPStatusCode_PreconditionRequired = 428,
    kWSKHTTPStatusCode_TooManyRequests = 429,
    kWSKHTTPStatusCode_RequestHeaderFieldsTooLarge = 431
};

/**
 *  Convenience constants for "server error" HTTP status codes.
 */
typedef NS_ENUM(NSInteger, WSKServerErrorHTTPStatusCode) {
    kWSKHTTPStatusCode_InternalServerError = 500,
    kWSKHTTPStatusCode_NotImplemented = 501,
    kWSKHTTPStatusCode_BadGateway = 502,
    kWSKHTTPStatusCode_ServiceUnavailable = 503,
    kWSKHTTPStatusCode_GatewayTimeout = 504,
    kWSKHTTPStatusCode_HTTPVersionNotSupported = 505,
    kWSKHTTPStatusCode_InsufficientStorage = 507,
    kWSKHTTPStatusCode_LoopDetected = 508,
    kWSKHTTPStatusCode_NotExtended = 510,
    kWSKHTTPStatusCode_NetworkAuthenticationRequired = 511
};

NS_ASSUME_NONNULL_END
