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

#if __has_include(<WebServerKit/WSKWebServer.h>)

// WSKWebServer Core
#import <WebServerKit/WSKWebServer.h>
#import <WebServerKit/WSKConnection.h>
#import <WebServerKit/WSKFunctions.h>
#import <WebServerKit/WSKHTTPStatusCodes.h>
#import <WebServerKit/WSKRequest.h>
#import <WebServerKit/WSKResponse.h>

// WSKWebServer Requests
#import <WebServerKit/WSKDataRequest.h>
#import <WebServerKit/WSKFileRequest.h>
#import <WebServerKit/WSKMultiPartFormRequest.h>
#import <WebServerKit/WSKURLEncodedFormRequest.h>

// WSKWebServer Responses
#import <WebServerKit/WSKDataResponse.h>
#import <WebServerKit/WSKErrorResponse.h>
#import <WebServerKit/WSKFileResponse.h>
#import <WebServerKit/WSKStreamedResponse.h>

// WSKWebUploader
#import <WebServerKit/WSKWebUploader.h>

// WSKWebDAVServer
#import <WebServerKit/WSKWebDAVServer.h>

#else

// WSKWebServer Core
#import "WSKWebServer.h"
#import "WSKConnection.h"
#import "WSKFunctions.h"
#import "WSKHTTPStatusCodes.h"
#import "WSKRequest.h"
#import "WSKResponse.h"

// WSKWebServer Requests
#import "WSKDataRequest.h"
#import "WSKFileRequest.h"
#import "WSKMultiPartFormRequest.h"
#import "WSKURLEncodedFormRequest.h"

// WSKWebServer Responses
#import "WSKDataResponse.h"
#import "WSKErrorResponse.h"
#import "WSKFileResponse.h"
#import "WSKStreamedResponse.h"

// WSKWebUploader
#import "WSKWebUploader.h"

// WSKWebDAVServer
#import "WSKWebDAVServer.h"

#endif
