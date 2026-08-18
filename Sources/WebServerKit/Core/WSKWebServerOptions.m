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

#import "WSKWebServerOptions.h"

// The string literals are the option-dictionary keys; each constant is documented where it is
// declared, in WSKWebServerOptions.h.
NSString *const WSKOption_Port = @"Port";
NSString *const WSKOption_BonjourName = @"BonjourName";
NSString *const WSKOption_BonjourType = @"BonjourType";
NSString *const WSKOption_BonjourTXTData = @"BonjourTXTData";
NSString *const WSKOption_RequestNATPortMapping = @"RequestNATPortMapping";
NSString *const WSKOption_BindToLocalhost = @"BindToLocalhost";
NSString *const WSKOption_AllowedHostNames = @"AllowedHostNames";
NSString *const WSKOption_MaxPendingConnections = @"MaxPendingConnections";
NSString *const WSKOption_ServerName = @"ServerName";
NSString *const WSKOption_AuthenticationMethod = @"AuthenticationMethod";
NSString *const WSKOption_AuthenticationRealm = @"AuthenticationRealm";
NSString *const WSKOption_AuthenticationAccounts = @"AuthenticationAccounts";
NSString *const WSKOption_ConnectionClass = @"ConnectionClass";
NSString *const WSKOption_AutomaticallyMapHEADToGET = @"AutomaticallyMapHEADToGET";
NSString *const WSKOption_ConnectedStateCoalescingInterval = @"ConnectedStateCoalescingInterval";
NSString *const WSKOption_DispatchQueuePriority = @"DispatchQueuePriority";
NSString *const WSKOption_ConnectionIdleTimeout = @"ConnectionIdleTimeout";
NSString *const WSKOption_ConnectionKeepAliveTimeout = @"ConnectionKeepAliveTimeout";
#if TARGET_OS_IPHONE
NSString *const WSKOption_AutomaticallySuspendInBackground = @"AutomaticallySuspendInBackground";
#endif

NSString *const WSKAuthenticationMethod_Basic = @"Basic";
NSString *const WSKAuthenticationMethod_DigestAccess = @"DigestAccess";
