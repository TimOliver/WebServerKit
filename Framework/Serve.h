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

#if __has_include(<Serve/SRVServer.h>)

// SRVServer Core
#import <Serve/SRVServer.h>
#import <Serve/SRVConnection.h>
#import <Serve/SRVFunctions.h>
#import <Serve/SRVHTTPStatusCodes.h>
#import <Serve/SRVRequest.h>
#import <Serve/SRVResponse.h>

// SRVServer Requests
#import <Serve/SRVDataRequest.h>
#import <Serve/SRVFileRequest.h>
#import <Serve/SRVMultiPartFormRequest.h>
#import <Serve/SRVURLEncodedFormRequest.h>

// SRVServer Responses
#import <Serve/SRVDataResponse.h>
#import <Serve/SRVErrorResponse.h>
#import <Serve/SRVFileResponse.h>
#import <Serve/SRVStreamedResponse.h>

// SRVUploader
#import <Serve/SRVUploader.h>

// SRVDAVServer
#import <Serve/SRVDAVServer.h>

#else

// SRVServer Core
#import "SRVServer.h"
#import "SRVConnection.h"
#import "SRVFunctions.h"
#import "SRVHTTPStatusCodes.h"
#import "SRVRequest.h"
#import "SRVResponse.h"

// SRVServer Requests
#import "SRVDataRequest.h"
#import "SRVFileRequest.h"
#import "SRVMultiPartFormRequest.h"
#import "SRVURLEncodedFormRequest.h"

// SRVServer Responses
#import "SRVDataResponse.h"
#import "SRVErrorResponse.h"
#import "SRVFileResponse.h"
#import "SRVStreamedResponse.h"

// SRVUploader
#import "SRVUploader.h"

// SRVDAVServer
#import "SRVDAVServer.h"

#endif
