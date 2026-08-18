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
#import <TargetConditionals.h>

NS_ASSUME_NONNULL_BEGIN

/**
 *  The port used by the WSKWebServer (NSNumber / NSUInteger).
 *
 *  The default value is 0 i.e. let the OS pick a random port.
 */
extern NSString *const WSKOption_Port;

/**
 *  The Bonjour name used by the WSKWebServer (NSString). If set to an empty string,
 *  the name will automatically take the value of the WSKOption_ServerName
 *  option. If this option is set to nil, Bonjour will be disabled.
 *
 *  The default value is nil.
 */
extern NSString *const WSKOption_BonjourName;

/**
 *  The Bonjour TXT Data used by the WSKWebServer (NSDictionary<NSString, NSString>).
 *
 *  The default value is nil.
 */
extern NSString *const WSKOption_BonjourTXTData;

/**
 *  The Bonjour service type used by the WSKWebServer (NSString).
 *
 *  The default value is "_http._tcp", the service type for HTTP web servers.
 */
extern NSString *const WSKOption_BonjourType;

/**
 *  Request a port mapping in the NAT gateway (NSNumber / BOOL).
 *
 *  This uses the DNSService API under the hood which supports IPv4 mappings only.
 *
 *  The default value is NO.
 *
 *  @warning The external port set up by the NAT gateway may be different than
 *  the one used by the WSKWebServer.
 */
extern NSString *const WSKOption_RequestNATPortMapping;

/**
 *  Only accept HTTP requests coming from localhost i.e. not from the outside
 *  network (NSNumber / BOOL).
 *
 *  The default value is NO.
 *
 *  @warning Bonjour and NAT port mapping should be disabled if using this option
 *  since the server will not be reachable from the outside network anyway.
 */
extern NSString *const WSKOption_BindToLocalhost;

/**
 *  Additional host names this server will answer to, beyond the ones it accepts
 *  automatically (NSArray of NSString).
 *
 *  Every request's "Host" header is checked against an allow-list, and anything
 *  else is refused with 421. This is what stops DNS rebinding: a browser sends the
 *  *name* the page was loaded from, so a page on evil.example that has repointed
 *  its DNS at this server still sends "Host: evil.example" — and an attacker
 *  cannot make a browser send a raw IP address in Host while scripting from a
 *  domain. Without this check, every same-origin protection (CORS, Origin
 *  comparison, CSRF tokens) is bypassed, because after rebinding the attacker
 *  genuinely *is* same-origin.
 *
 *  Accepted without configuration: any IP address literal, "localhost", this
 *  machine's own host name, and the Bonjour name being advertised. Supply this
 *  option only if the server is reached under some other name — behind a reverse
 *  proxy, or via a custom DNS entry. Entries are compared case-insensitively and
 *  may include a port ("files.example:8080"); without one, any port matches.
 *
 *  A request carrying no "Host" header at all is allowed: HTTP/1.0 and many
 *  non-browser clients omit it, and rebinding requires a browser, which never does.
 *
 *  Rejections are logged with the offending name and the full accepted set, so an
 *  unanticipated deployment reports itself rather than failing mysteriously.
 */
extern NSString *const WSKOption_AllowedHostNames;

/**
 *  The maximum number of incoming HTTP requests that can be queued waiting to
 *  be handled before new ones are dropped (NSNumber / NSUInteger).
 *
 *  The default value is 16.
 */
extern NSString *const WSKOption_MaxPendingConnections;

/**
 *  The value for "Server" HTTP header used by the WSKWebServer (NSString).
 *
 *  The default value is "WebServerKit".
 */
extern NSString *const WSKOption_ServerName;

/**
 *  The authentication method used by the WSKWebServer
 *  (one of "WSKAuthenticationMethod_...").
 *
 *  The default value is nil i.e. authentication is disabled.
 */
extern NSString *const WSKOption_AuthenticationMethod;

/**
 *  The authentication realm used by the WSKWebServer (NSString).
 *
 *  The default value is the same as the WSKOption_ServerName option.
 */
extern NSString *const WSKOption_AuthenticationRealm;

/**
 *  The authentication accounts used by the WSKWebServer
 *  (NSDictionary of username / password pairs).
 *
 *  The default value is nil i.e. no accounts.
 */
extern NSString *const WSKOption_AuthenticationAccounts;

/**
 *  The class used by the WSKWebServer when instantiating WSKConnection
 *  (subclass of WSKConnection).
 *
 *  The default value is the WSKConnection class.
 */
extern NSString *const WSKOption_ConnectionClass;

/**
 *  Allow the WSKWebServer to pretend "HEAD" requests are actually "GET" ones
 *  and automatically discard the HTTP body of the response (NSNumber / BOOL).
 *
 *  The default value is YES.
 */
extern NSString *const WSKOption_AutomaticallyMapHEADToGET;

/**
 *  The interval expressed in seconds used by the WSKWebServer to decide how to
 *  coalesce calls to -webServerDidConnect: and -webServerDidDisconnect:
 *  (NSNumber / double). Coalescing will be disabled if the interval is <= 0.0.
 *
 *  The default value is 1.0 second.
 */
extern NSString *const WSKOption_ConnectedStateCoalescingInterval;

/**
 *  Set the dispatch queue priority on which server connection will be
 *  run (NSNumber / long).
 *
 *
 *  The default value is DISPATCH_QUEUE_PRIORITY_DEFAULT.
 */
extern NSString *const WSKOption_DispatchQueuePriority;

/**
 *  The timeout expressed in seconds after which a connection that is waiting on
 *  socket I/O without any bytes moving in either direction is forcibly closed
 *  (NSNumber / double). This protects against clients that connect and then go
 *  silent (or stop reading a response), which would otherwise hold their
 *  connection — and a file descriptor — forever. The timeout only applies while
 *  a socket read or write is actually pending: time spent waiting for a handler
 *  to produce a response does not count, and a connection is closed no sooner
 *  than one timeout interval and no later than two after going idle.
 *
 *  Set to 0.0 to disable idle timeouts entirely.
 *
 *  The default value is 30.0 seconds.
 */
extern NSString *const WSKOption_ConnectionIdleTimeout;

/**
 *  Allows a connection to carry more than one request, so a client does not pay
 *  a TCP handshake per request (NSNumber / double, in seconds). The value is how
 *  long an otherwise idle connection is held open waiting for the next request.
 *
 *  Reuse is deliberately restricted to requests that carry NO BODY — no
 *  "Content-Length" and no "Transfer-Encoding" header at all. Request smuggling
 *  is a disagreement about where one request's body ends and the next begins, so
 *  a connection on which no body is ever read cannot be desynchronized: the
 *  property is structural rather than a matter of parsing carefully. Anything
 *  with a body is answered and the connection is closed, exactly as before, as is
 *  any request that was refused, any HTTP/1.0 client, and any response whose
 *  length the server cannot state up front.
 *
 *  This matters most for an interface that fetches many small resources — icons,
 *  thumbnails, stylesheets — where the handshake dominates the transfer.
 *
 *  Set to 0.0 to serve exactly one request per connection.
 *
 *  The default value is 0.0.
 */
extern NSString *const WSKOption_ConnectionKeepAliveTimeout;

#if TARGET_OS_IPHONE

/**
 *  Enables the WSKWebServer to automatically suspend itself (as if -stop was
 *  called) when the iOS app goes into the background and the last
 *  WSKConnection is closed, then resume itself (as if -start was called)
 *  when the iOS app comes back to the foreground (NSNumber / BOOL).
 *
 *  See the README.md file for more information about this option.
 *
 *  The default value is YES.
 *
 *  @warning The running property will be NO while the WSKWebServer is suspended.
 */
extern NSString *const WSKOption_AutomaticallySuspendInBackground;

#endif

/**
 *  HTTP Basic Authentication scheme (see https://tools.ietf.org/html/rfc2617).
 *
 *  @warning Use of this authentication scheme is not recommended as the
 *  passwords are sent in clear.
 */
extern NSString *const WSKAuthenticationMethod_Basic;

/**
 *  HTTP Digest Access Authentication scheme (see https://tools.ietf.org/html/rfc2617).
 */
extern NSString *const WSKAuthenticationMethod_DigestAccess;

NS_ASSUME_NONNULL_END
