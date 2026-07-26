___In January 2023, [SRVServer](https://github.com/swisspol/GCDWebServer) was archived by its author. Since I was planning to eventually use this library in my own side projects, I've decided to fork SRVServer and continue development of it under a new name. I plan to slowly add updates to this repo as I get the time. -Tim___

Overview
========

[![Build Status](https://travis-ci.org/swisspol/GCDWebServer.svg?branch=master)](https://travis-ci.org/swisspol/GCDWebServer)
[![Version](http://cocoapod-badges.herokuapp.com/v/SRVServer/badge.png)](https://cocoapods.org/pods/SRVServer)
[![Platform](http://cocoapod-badges.herokuapp.com/p/SRVServer/badge.png)](https://github.com/swisspol/GCDWebServer)
[![License](http://img.shields.io/cocoapods/l/SRVServer.svg)](LICENSE)

SRVServer is a modern and lightweight GCD based HTTP 1.1 server designed to be embedded in iOS, macOS & tvOS apps. It was written from scratch with the following goals in mind:
* Elegant and easy to use architecture with only 4 core classes: server, connection, request and response (see "Understanding SRVServer's Architecture" below)
* Well designed API with fully documented headers for easy integration and customization
* Entirely built with an event-driven design using [Grand Central Dispatch](http://en.wikipedia.org/wiki/Grand_Central_Dispatch) for best performance and concurrency
* No dependencies on third-party source code
* Available under a friendly [New BSD License](LICENSE)

Extra built-in features:
* Allow implementation of fully asynchronous handlers of incoming HTTP requests
* Minimize memory usage with disk streaming of large HTTP request or response bodies
* Parser for [web forms](http://www.w3.org/TR/html401/interact/forms.html#h-17.13.4) submitted using "application/x-www-form-urlencoded" or "multipart/form-data" encodings (including file uploads)
* [JSON](http://www.json.org/) parsing and serialization for request and response HTTP bodies
* [Chunked transfer encoding](https://en.wikipedia.org/wiki/Chunked_transfer_encoding) for request and response HTTP bodies
* [HTTP compression](https://en.wikipedia.org/wiki/HTTP_compression) with gzip for request and response HTTP bodies
* [HTTP range](https://en.wikipedia.org/wiki/Byte_serving) support for requests of local files
* [Basic](https://en.wikipedia.org/wiki/Basic_access_authentication) and [Digest Access](https://en.wikipedia.org/wiki/Digest_access_authentication) authentications for password protection
* Automatically handle transitions between foreground, background and suspended modes in iOS apps
* Full support for both IPv4 and IPv6
* NAT port mapping (IPv4 only)

Included extensions:
* [SRVUploader](SRVUploader/SRVUploader.h): subclass of ```SRVServer``` that implements an interface for uploading and downloading files using a web browser
* [SRVDAVServer](SRVDAVServer/SRVDAVServer.h): subclass of ```SRVServer``` that implements a class 1 [WebDAV](https://en.wikipedia.org/wiki/WebDAV) server (with partial class 2 support for macOS Finder)

What's not supported (but not really required from an embedded HTTP server):
* Keep-alive connections
* HTTPS

Requirements:
* macOS 12.0 or later (x86_64, arm64)
* iOS 15.0 or later (arm64)
* tvOS 15.0 or later (arm64)
* ARC memory management only (if you need MRC support use SRVServer 3.1 or earlier)

Getting Started
===============

Download or check out the [latest release](https://github.com/swisspol/GCDWebServer/releases) of SRVServer then add the entire "SRVServer" subfolder to your Xcode project. If you intend to use one of the extensions like SRVDAVServer or SRVUploader, add these subfolders as well. Finally link to `libz` (via Target > Build Phases > Link Binary With Libraries) and add `$(SDKROOT)/usr/include/libxml2` to your header search paths (via Target > Build Settings > HEADER_SEARCH_PATHS).

Alternatively, add it with the [Swift Package Manager](https://swift.org/package-manager/) by pointing Xcode at this repository, or by adding it to your `Package.swift`:

```swift
.package(url: "https://github.com/TimOliver/Serve.git", from: "3.5.5")
```

The `Serve` product provides everything. If you would rather not link libxml2 or ship the uploader's web assets, depend on `SRVCore`, `SRVDAVServer` or `SRVUploader` individually — they mirror the CocoaPods subspecs.

Or install using [CocoaPods](http://cocoapods.org/) by simply adding this line to your Podfile:
```
pod "SRVServer", "~> 3.0"
```
If you want to use SRVUploader, use this line instead:
```
pod "SRVServer/WebUploader", "~> 3.0"
```
Or this line for SRVDAVServer:
```
pod "SRVServer/WebDAV", "~> 3.0"
```

And finally run `$ pod install`.

You can also use [Carthage](https://github.com/Carthage/Carthage) by adding this line to your Cartfile (3.2.5 is the first release with Carthage support):
```
github "swisspol/GCDWebServer" ~> 3.2.5
```

Then run `$ carthage update` and add the generated frameworks to your Xcode projects (see [Carthage instructions](https://github.com/Carthage/Carthage#adding-frameworks-to-an-application)).

Help & Support
==============

For help with using SRVServer, it's best to ask your question on Stack Overflow with the [`gcdwebserver`](http://stackoverflow.com/questions/tagged/gcdwebserver) tag. For bug reports and enhancement requests you can use [issues](https://github.com/swisspol/GCDWebServer/issues) in this project.

Be sure to read this entire README first though!

Hello World
===========

These code snippets show how to implement a custom HTTP server that runs on port 8080 and returns a "Hello World" HTML page to any request. Since SRVServer uses GCD blocks to handle requests, no subclassing or delegates are needed, which results in very clean code.

**IMPORTANT:** If not using CocoaPods, be sure to add the `libz` shared system library to the Xcode target for your app.

**macOS version (command line tool):**
```objectivec
#import "SRVServer.h"
#import "SRVDataResponse.h"

int main(int argc, const char* argv[]) {
  @autoreleasepool {
    
    // Create server
    SRVServer* webServer = [[SRVServer alloc] init];
    
    // Add a handler to respond to GET requests on any URL
    [webServer addDefaultHandlerForMethod:@"GET"
                             requestClass:[SRVRequest class]
                             processBlock:^SRVResponse *(SRVRequest* request) {
      
      return [SRVDataResponse responseWithHTML:@"<html><body><p>Hello World</p></body></html>"];
      
    }];
    
    // Use convenience method that runs server on port 8080
    // until SIGINT (Ctrl-C in Terminal) or SIGTERM is received
    [webServer runWithPort:8080 bonjourName:nil];
    NSLog(@"Visit %@ in your web browser", webServer.serverURL);
    
  }
  return 0;
}
```

**iOS version:**
```objectivec
#import "SRVServer.h"
#import "SRVDataResponse.h"

@interface AppDelegate : NSObject <UIApplicationDelegate> {
  SRVServer* _webServer;
}
@end

@implementation AppDelegate

- (BOOL)application:(UIApplication*)application didFinishLaunchingWithOptions:(NSDictionary*)launchOptions {
  
  // Create server
  _webServer = [[SRVServer alloc] init];
  
  // Add a handler to respond to GET requests on any URL
  [_webServer addDefaultHandlerForMethod:@"GET"
                            requestClass:[SRVRequest class]
                            processBlock:^SRVResponse *(SRVRequest* request) {
    
    return [SRVDataResponse responseWithHTML:@"<html><body><p>Hello World</p></body></html>"];
    
  }];
  
  // Start server on port 8080
  [_webServer startWithPort:8080 bonjourName:nil];
  NSLog(@"Visit %@ in your web browser", _webServer.serverURL);
  
  return YES;
}

@end
```

**macOS Swift version (command line tool):**

***webServer.swift***
```swift
import Foundation
import SRVServer

func initWebServer() {

    let webServer = SRVServer()

    webServer.addDefaultHandler(forMethod: "GET", request: SRVRequest.self, processBlock: {request in
            return SRVDataResponse(html:"<html><body><p>Hello World</p></body></html>")
            
        })
        
    webServer.start(withPort: 8080, bonjourName: "GCD Web Server")
    
    print("Visit \(webServer.serverURL) in your web browser")
}
```

***WebServer-Bridging-Header.h***
```objectivec
#import <SRVServer/SRVServer.h>
#import <SRVServer/SRVDataResponse.h>
```

Web Based Uploads in iOS Apps
=============================

SRVUploader is a subclass of ```SRVServer``` that provides a ready-to-use HTML 5 file uploader & downloader. This lets users upload, download, delete files and create directories from a directory inside your iOS app's sandbox using a clean user interface in their web browser.

Simply instantiate and run a ```SRVUploader``` instance then visit ```http://{YOUR-IOS-DEVICE-IP-ADDRESS}/``` from your web browser:

```objectivec
#import "SRVUploader.h"

@interface AppDelegate : NSObject <UIApplicationDelegate> {
  SRVUploader* _webUploader;
}
@end

@implementation AppDelegate

- (BOOL)application:(UIApplication*)application didFinishLaunchingWithOptions:(NSDictionary*)launchOptions {
  NSString* documentsPath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
  _webUploader = [[SRVUploader alloc] initWithUploadDirectory:documentsPath];
  [_webUploader start];
  NSLog(@"Visit %@ in your web browser", _webUploader.serverURL);
  return YES;
}

@end
```

WebDAV Server in iOS Apps
=========================

SRVDAVServer is a subclass of ```SRVServer``` that provides a class 1 compliant [WebDAV](https://en.wikipedia.org/wiki/WebDAV) server. This lets users upload, download, delete files and create directories from a directory inside your iOS app's sandbox using any WebDAV client like [Transmit](https://panic.com/transmit/) (Mac), [ForkLift](http://binarynights.com/forklift/) (Mac) or [CyberDuck](http://cyberduck.io/) (Mac / Windows).

SRVDAVServer should also work with the [macOS Finder](http://support.apple.com/kb/PH13859) as it is partially class 2 compliant (but only when the client is the macOS WebDAV implementation).

Simply instantiate and run a ```SRVDAVServer``` instance then connect to ```http://{YOUR-IOS-DEVICE-IP-ADDRESS}/``` using a WebDAV client:

```objectivec
#import "SRVDAVServer.h"

@interface AppDelegate : NSObject <UIApplicationDelegate> {
  SRVDAVServer* _davServer;
}
@end

@implementation AppDelegate

- (BOOL)application:(UIApplication*)application didFinishLaunchingWithOptions:(NSDictionary*)launchOptions {
  NSString* documentsPath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
  _davServer = [[SRVDAVServer alloc] initWithUploadDirectory:documentsPath];
  [_davServer start];
  NSLog(@"Visit %@ in your WebDAV client", _davServer.serverURL);
  return YES;
}

@end
```

Serving a Static Website
========================

SRVServer includes a built-in handler that can recursively serve a directory (it also lets you control how the ["Cache-Control"](http://www.w3.org/Protocols/rfc2616/rfc2616-sec14.html#sec14.9) header should be set):

**macOS version (command line tool):**
```objectivec
#import "SRVServer.h"

int main(int argc, const char* argv[]) {
  @autoreleasepool {
    
    SRVServer* webServer = [[SRVServer alloc] init];
    [webServer addGETHandlerForBasePath:@"/" directoryPath:NSHomeDirectory() indexFilename:nil cacheAge:3600 allowRangeRequests:YES];
    [webServer runWithPort:8080];
    
  }
  return 0;
}
```

Using SRVServer
==================

You start by creating an instance of the ```SRVServer``` class. Note that you can have multiple web servers running in the same app as long as they listen on different ports.

Then you add one or more "handlers" to the server: each handler gets a chance to handle an incoming web request and provide a response. Handlers are called in a LIFO queue, so the latest added handler overrides any previously added ones.

Finally you start the server on a given port.

Understanding SRVServer's Architecture
=========================================

SRVServer's architecture consists of only 4 core classes:
* [SRVServer](SRVServer/Core/SRVServer.h) manages the socket that listens for new HTTP connections and the list of handlers used by the server.
* [SRVConnection](SRVServer/Core/SRVConnection.h) is instantiated by ```SRVServer``` to handle each new HTTP connection. Each instance stays alive until the connection is closed. You cannot use this class directly, but it is exposed so you can subclass it to override some hooks.
* [SRVRequest](SRVServer/Core/SRVRequest.h) is created by the ```SRVConnection``` instance after HTTP headers have been received. It wraps the request and handles the HTTP body if any. SRVServer comes with [several subclasses](SRVServer/Requests) of ```SRVRequest``` to handle common cases like storing the body in memory or stream it to a file on disk.
* [SRVResponse](SRVServer/Core/SRVResponse.h) is created by the request handler and wraps the response HTTP headers and optional body. SRVServer comes with [several subclasses](SRVServer/Responses) of ```SRVResponse``` to handle common cases like HTML text in memory or streaming a file from disk.

Implementing Handlers
=====================

SRVServer relies on "handlers" to process incoming web requests and generating responses. Handlers are implemented with GCD blocks which makes it very easy to provide your own. However, they are executed on arbitrary threads within GCD so __special attention must be paid to thread-safety and re-entrancy__.

Handlers require 2 GCD blocks:
* The ```SRVMatchBlock``` is called on every handler added to the ```SRVServer``` instance whenever a web request has started (i.e. HTTP headers have been received). It is passed the basic info for the web request (HTTP method, URL, headers...) and must decide if it wants to handle it or not. If yes, it must return a new ```SRVRequest``` instance (see above) created with this info. Otherwise, it simply returns nil.
* The ```SRVProcessBlock``` or ```SRVAsyncProcessBlock``` is called after the web request has been fully received and is passed the ```SRVRequest``` instance created at the previous step. It must return synchronously (if using ```SRVProcessBlock```) or asynchronously (if using ```SRVAsyncProcessBlock```) a ```SRVResponse``` instance (see above) or nil on error, which will result in a 500 HTTP status code returned to the client. It's however recommended to return an instance of [SRVErrorResponse](SRVServer/Responses/SRVErrorResponse.h) on error so more useful information can be returned to the client.

Note that most methods on ```SRVServer``` to add handlers only require the ```SRVProcessBlock``` or ```SRVAsyncProcessBlock``` as they already provide a built-in ```SRVMatchBlock``` e.g. to match a URL path with a Regex.

Asynchronous HTTP Responses
===========================

New in SRVServer 3.0 is the ability to process HTTP requests asynchronously i.e. add handlers to the server which generate their ```SRVResponse``` asynchronously. This is achieved by adding handlers that use a ```SRVAsyncProcessBlock``` instead of a ```SRVProcessBlock```. Here's an example:

**(Synchronous version)** The handler blocks while generating the HTTP response:
```objectivec
[webServer addDefaultHandlerForMethod:@"GET"
                         requestClass:[SRVRequest class]
                         processBlock:^SRVResponse *(SRVRequest* request) {
  
  SRVDataResponse* response = [SRVDataResponse responseWithHTML:@"<html><body><p>Hello World</p></body></html>"];
  return response;
  
}];
```

**(Asynchronous version)** The handler returns immediately and calls back SRVServer later with the generated HTTP response:
```objectivec
[webServer addDefaultHandlerForMethod:@"GET"
                         requestClass:[SRVRequest class]
                    asyncProcessBlock:^(SRVRequest* request, SRVCompletionBlock completionBlock) {
  
  // Do some async operation like network access or file I/O (simulated here using dispatch_after())
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
    SRVDataResponse* response = [SRVDataResponse responseWithHTML:@"<html><body><p>Hello World</p></body></html>"];
    completionBlock(response);
  });

}];
```

**(Advanced asynchronous version)** The handler returns immediately a streamed HTTP response which itself generates its contents asynchronously:
```objectivec
[webServer addDefaultHandlerForMethod:@"GET"
                         requestClass:[SRVRequest class]
                         processBlock:^SRVResponse *(SRVRequest* request) {
  
  NSMutableArray* contents = [NSMutableArray arrayWithObjects:@"<html><body><p>\n", @"Hello World!\n", @"</p></body></html>\n", nil];  // Fake data source we are reading from
  SRVStreamedResponse* response = [SRVStreamedResponse responseWithContentType:@"text/html" asyncStreamBlock:^(SRVBodyReaderCompletionBlock completionBlock) {
    
    // Simulate a delay reading from the fake data source
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
      NSString* string = contents.firstObject;
      if (string) {
        [contents removeObjectAtIndex:0];
        completionBlock([string dataUsingEncoding:NSUTF8StringEncoding], nil);  // Generate the 2nd part of the stream data
      } else {
        completionBlock([NSData data], nil);  // Must pass an empty NSData to signal the end of the stream
      }
    });
    
  }];
  return response;
  
}];
```

*Note that you can even combine both the asynchronous and advanced asynchronous versions to return asynchronously an asynchronous HTTP response!*

SRVServer & Background Mode for iOS Apps
===========================================

When doing networking operations in iOS apps, you must handle carefully [what happens when iOS puts the app in the background](https://developer.apple.com/library/ios/technotes/tn2277/_index.html). Typically you must stop any network servers while the app is in the background and restart them when the app comes back to the foreground. This can become quite complex considering servers might have ongoing connections when they need to be stopped.

Fortunately, SRVServer does all of this automatically for you:
- SRVServer begins a [background task](https://developer.apple.com/library/archive/documentation/iPhone/Conceptual/iPhoneOSProgrammingGuide/BackgroundExecution/BackgroundExecution.html) whenever the first HTTP connection is opened and ends it only when the last one is closed. This prevents iOS from suspending the app after it goes in the background, which would immediately kill HTTP connections to the client.
 - While the app is in the background, as long as new HTTP connections keep being initiated, the background task will continue to exist and iOS will not suspend the app **for up to 10 minutes** (unless under sudden and unexpected memory pressure).
 - If the app is still in the background when the last HTTP connection is closed, SRVServer will suspend itself and stop accepting new connections as if you had called ```-stop``` (this behavior can be disabled with the ```SRVOption_AutomaticallySuspendInBackground``` option).
- If the app goes in the background while no HTTP connections are opened, SRVServer will immediately suspend itself and stop accepting new connections as if you had called ```-stop``` (this behavior can be disabled with the ```SRVOption_AutomaticallySuspendInBackground``` option).
- If the app comes back to the foreground and SRVServer had been suspended, it will automatically resume itself and start accepting again new HTTP connections as if you had called ```-start```.

HTTP connections are often initiated in batches (or bursts), for instance when loading a web page with multiple resources. This makes it difficult to accurately detect when the *very last* HTTP connection has been closed: it's possible 2 consecutive HTTP connections part of the same batch would be separated by a small delay instead of overlapping. It would be bad for the client if SRVServer suspended itself right in between. The ```SRVOption_ConnectedStateCoalescingInterval``` option solves this problem elegantly by forcing SRVServer to wait some extra delay before performing any action after the last HTTP connection has been closed, just in case a new HTTP connection is initiated within this delay.

Logging in SRVServer
=======================

Both for debugging and informational purpose, SRVServer logs messages extensively whenever something happens. Furthermore, when building SRVServer in "Debug" mode versus "Release" mode, it logs even more information but also performs a number of internal consistency checks. To enable this behavior, define the preprocessor constant ```DEBUG=1``` when compiling SRVServer. In Xcode target settings, this can be done by adding ```DEBUG=1``` to the build setting ```GCC_PREPROCESSOR_DEFINITIONS``` when building in "Debug" configuration. Finally, you can also control the logging verbosity at run time by calling ```+[SRVServer setLogLevel:]```.

By default, all messages logged by SRVServer are sent to its built-in logging facility, which simply outputs to ```stderr``` (assuming a terminal type device is connected). In order to better integrate with the rest of your app or because of the amount of information logged, you might want to use another logging facility.

SRVServer has automatic support for [XLFacility](https://github.com/swisspol/XLFacility) (by the same author as SRVServer and also open-source): if it is in the same Xcode project, SRVServer should use it automatically instead of the built-in logging facility (see [SRVPrivate.h](SRVServer/Core/SRVPrivate.h) for the implementation details).

It's also possible to use a custom logging facility - see [SRVServer.h](SRVServer/Core/SRVServer.h) for more information.

Advanced Example 1: Implementing HTTP Redirects
===============================================

Here's an example handler that redirects "/" to "/index.html" using the convenience method on ```SRVResponse``` (it sets the HTTP status code and "Location" header automatically):

```objectivec
[self addHandlerForMethod:@"GET"
                     path:@"/"
             requestClass:[SRVRequest class]
             processBlock:^SRVResponse *(SRVRequest* request) {
    
  return [SRVResponse responseWithRedirect:[NSURL URLWithString:@"index.html" relativeToURL:request.URL]
                                          permanent:NO];
    
}];
```

Advanced Example 2: Implementing Forms
======================================

To implement an HTTP form, you need a pair of handlers:
* The GET handler does not expect any body in the HTTP request and therefore uses the ```SRVRequest``` class. The handler generates a response containing a simple HTML form.
* The POST handler expects the form values to be in the body of the HTTP request and percent-encoded. Fortunately, SRVServer provides the request class ```SRVURLEncodedFormRequest``` which can automatically parse such bodies. The handler simply echoes back the value from the user submitted form.

```objectivec
[webServer addHandlerForMethod:@"GET"
                          path:@"/"
                  requestClass:[SRVRequest class]
                  processBlock:^SRVResponse *(SRVRequest* request) {
  
  NSString* html = @" \
    <html><body> \
      <form name=\"input\" action=\"/\" method=\"post\" enctype=\"application/x-www-form-urlencoded\"> \
      Value: <input type=\"text\" name=\"value\"> \
      <input type=\"submit\" value=\"Submit\"> \
      </form> \
    </body></html> \
  ";
  return [SRVDataResponse responseWithHTML:html];
  
}];

[webServer addHandlerForMethod:@"POST"
                          path:@"/"
                  requestClass:[SRVURLEncodedFormRequest class]
                  processBlock:^SRVResponse *(SRVRequest* request) {
  
  NSString* value = [[(SRVURLEncodedFormRequest*)request arguments] objectForKey:@"value"];
  NSString* html = [NSString stringWithFormat:@"<html><body><p>%@</p></body></html>", value];
  return [SRVDataResponse responseWithHTML:html];
  
}];
```

Advanced Example 3: Serving a Dynamic Website
=============================================

SRVServer provides an extension to the ```SRVDataResponse``` class that can return HTML content generated from a template and a set of variables (using the format ```%variable%```). It is a very basic template system and is really intended as a starting point to building more advanced template systems by subclassing ```SRVResponse```.

Assuming you have a website directory in your app containing HTML template files along with the corresponding CSS, scripts and images, it's pretty easy to turn it into a dynamic website:

```objectivec
// Get the path to the website directory
NSString* websitePath = [[NSBundle mainBundle] pathForResource:@"Website" ofType:nil];

// Add a default handler to serve static files (i.e. anything other than HTML files)
[self addGETHandlerForBasePath:@"/" directoryPath:websitePath indexFilename:nil cacheAge:3600 allowRangeRequests:YES];

// Add an override handler for all requests to "*.html" URLs to do the special HTML templatization
[self addHandlerForMethod:@"GET"
                pathRegex:@"/.*\.html"
             requestClass:[SRVRequest class]
             processBlock:^SRVResponse *(SRVRequest* request) {
    
    NSDictionary* variables = [NSDictionary dictionaryWithObjectsAndKeys:@"value", @"variable", nil];
    return [SRVDataResponse responseWithHTMLTemplate:[websitePath stringByAppendingPathComponent:request.path]
                                                    variables:variables];
    
}];

// Add an override handler to redirect "/" URL to "/index.html"
[self addHandlerForMethod:@"GET"
                     path:@"/"
             requestClass:[SRVRequest class]
             processBlock:^SRVResponse *(SRVRequest* request) {
    
    return [SRVResponse responseWithRedirect:[NSURL URLWithString:@"index.html" relativeToURL:request.URL]
                                            permanent:NO];
    
];

```

Final Example: File Downloads and Uploads From iOS App
======================================================

SRVServer was originally written for the [ComicFlow](http://itunes.apple.com/us/app/comicflow/id409290355?mt=8) comic reader app for iPad. It allow users to connect to their iPad with their web browser over WiFi and then upload, download and organize comic files inside the app.

ComicFlow is [entirely open-source](https://github.com/swisspol/ComicFlow) and you can see how it uses SRVServer in the [WebServer.h](https://github.com/swisspol/ComicFlow/blob/master/Classes/WebServer.h) and [WebServer.m](https://github.com/swisspol/ComicFlow/blob/master/Classes/WebServer.m) files.
