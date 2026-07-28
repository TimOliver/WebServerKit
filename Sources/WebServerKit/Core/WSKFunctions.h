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

#ifdef __cplusplus
extern "C" {
#endif

/**
 *  Converts a file extension to the corresponding MIME type.
 *  If there is no match, "application/octet-stream" is returned.
 *
 *  Overrides allow to customize the built-in mapping from extensions to MIME
 *  types. Keys of the dictionary must be lowercased file extensions without
 *  the period, and the values must be the corresponding MIME types.
 */
NSString *WSKGetMimeTypeForExtension(NSString *extension, NSDictionary<NSString *, NSString *> *_Nullable overrides);

/**
 *  Add percent-escapes to a string so it can be used in a URL.
 *  The legal characters ":@/?&=+" are also escaped to ensure compatibility
 *  with URL encoded forms and URL queries.
 */
NSString *_Nullable WSKEscapeURLString(NSString *string);

/**
 *  Unescapes a URL percent-encoded string.
 */
NSString *_Nullable WSKUnescapeURLString(NSString *string);

/**
 *  Extracts the unescaped names and values from an
 *  "application/x-www-form-urlencoded" form.
 *  http://www.w3.org/TR/html401/interact/forms.html#h-17.13.4.1
 */
NSDictionary<NSString *, NSString *> *WSKParseURLEncodedForm(NSString *form);

/**
 *  On OS X, returns the IPv4 or IPv6 address as a string of the primary
 *  connected service or nil if not available.
 *
 *  On iOS, returns the IPv4 or IPv6 address as a string of the WiFi
 *  interface if connected or nil otherwise.
 */
NSString *_Nullable WSKGetPrimaryIPAddress(BOOL useIPv6);

/**
 *  Converts a date into a string using RFC822 formatting.
 *  https://tools.ietf.org/html/rfc822#section-5
 *  https://tools.ietf.org/html/rfc1123#section-5.2.14
 */
NSString *WSKFormatRFC822(NSDate *date);

/**
 *  Converts a RFC822 formatted string into a date.
 *  https://tools.ietf.org/html/rfc822#section-5
 *  https://tools.ietf.org/html/rfc1123#section-5.2.14
 *
 *  @warning Timezones other than GMT are not supported by this function.
 */
NSDate *_Nullable WSKParseRFC822(NSString *string);

/**
 *  Converts a date into a string using IOS 8601 formatting.
 *  http://tools.ietf.org/html/rfc3339#section-5.6
 */
NSString *WSKFormatISO8601(NSDate *date);

/**
 *  Converts a ISO 8601 formatted string into a date.
 *  http://tools.ietf.org/html/rfc3339#section-5.6
 *
 *  @warning Only "calendar" variant is supported at this time and timezones
 *  other than GMT are not supported either.
 */
NSDate *_Nullable WSKParseISO8601(NSString *string);

/**
 *  Removes "//", "/./" and "/../" components from path as well as any trailing slash.
 */
NSString *WSKNormalizePath(NSString *path);

/**
 *  Returns YES only if `path` resolves to a location strictly inside `directory`
 *  (i.e. neither the directory itself nor outside it). Used to keep destructive
 *  file operations from ever targeting the served root directory, e.g. when a
 *  client-supplied relative path collapses to the empty string.
 *
 *  @warning This is a purely textual comparison and does not resolve symlinks. Pair
 *  it with WSKResolvedPathIsWithinDirectory() before acting on a path that
 *  came from a client.
 */
BOOL WSKPathIsInsideDirectory(NSString *path, NSString *directory);

/**
 *  Returns YES if `path`, with all symlinks resolved, is `directory` itself or a
 *  location inside it. Resolves intermediate path components, and works for a path
 *  that does not exist yet (e.g. an upload destination) by resolving its parent.
 *
 *  Symlinks are invisible to the textual checks: WSKNormalizePath() strips
 *  ".." before any file is touched, and WSKPathIsInsideDirectory() compares
 *  path text, but lstat(), open() and NSFileManager all follow symlinks found in
 *  intermediate components. A symlink placed inside the served directory by some other
 *  means — another app, a restored backup, a synced volume — could therefore be
 *  traversed out of it. A symlink whose target stays inside the directory still
 *  resolves inside and remains usable.
 *
 *  Returns NO if either path cannot be resolved, so callers fail closed.
 */
BOOL WSKResolvedPathIsWithinDirectory(NSString *path, NSString *directory);

/**
 *  Returns `path` resolved and expressed relative to `directory` resolved, or nil if it does
 *  not resolve inside `directory` — which is exactly the condition
 *  WSKResolvedPathIsWithinDirectory() reports, so that function is now a wrapper around this
 *  one and the two cannot drift apart.
 *
 *  Relative to the *resolved* root, deliberately: the root itself may live under a hidden
 *  directory (NSTemporaryDirectory() under a sandboxed app commonly does), and a caller
 *  examining the absolute resolved path would then judge every file it serves to be hidden.
 */
NSString *_Nullable WSKResolvedPathRelativeToDirectory(NSString *path, NSString *directory);

/**
 *  Returns YES if `path`, once symlinks are resolved, lies under a component starting with "."
 *  relative to `directory`.
 *
 *  A textual test on the path a client sent cannot see this: a symlink named `pub` pointing at
 *  `.git` yields the request path "/pub/config", which carries no dot, while containment passes
 *  too because the target is inside the served root. Both servers' hidden-item rules were
 *  therefore satisfied by a path whose bytes live inside a dot-directory.
 *
 *  Returns NO for a path that does not resolve inside `directory` at all — that is containment's
 *  business, and reporting it as "hidden" here would mislabel an escape attempt.
 */
BOOL WSKResolvedPathHasHiddenComponent(NSString *path, NSString *directory);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
