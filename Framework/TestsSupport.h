// Shared support for the test suites.
//
// The suite used to be one 6,000-line Tests.m holding every test in a single XCTestCase. It is now
// one file per subject, and everything they share lives here: the socket and HTTP helpers, the gzip
// pair, the temp-directory helper, and the probe classes that exist only to observe the server from
// the inside.
//
// These were `static` in the old single file. They are external now because more than one suite
// needs them; nothing else changed.

#import <WebServerKit/WebServerKit.h>
#import <XCTest/XCTest.h>

#import "WSKPrivate.h"
#import "WSKWebUploaderSSEChannel.h"

extern NSData* SSEData(NSString* string);
extern int ConnectToLocalhostPort(NSUInteger port);
extern NSData* ReadToEOF(int fd, BOOL* sawEOF);
extern NSData* GZipDecompress(NSData* input);
extern NSData* DrainResponseBody(WSKResponse* response);
extern NSData* GZipCompress(NSData* input);
extern __kindof WSKRequest* OpenBodyRequest(Class requestClass, NSDictionary* extraHeaders);
extern NSString* SendRawRequest(NSUInteger port, NSString* request);
extern NSArray<NSString*>* SendRawRequestsOnOneConnection(NSUInteger port, NSArray<NSString*>* requests);
extern NSString* SendRawDataRequestSplit(NSUInteger port, NSData* request, NSUInteger splitAt);
extern NSString* SendRawDataRequest(NSUInteger port, NSData* request);
extern NSString* SendRawRequestUntilMarker(NSUInteger port, NSString* request, NSString* marker, NSTimeInterval seconds);
extern NSUInteger OpenFileDescriptorCount(void);
extern NSString* MakeTempDirectory(void);
extern NSData* NestedMultipartMixedBody(NSString* top, NSUInteger levels);
extern NSString* QuotedParam(NSString* header, NSString* name);

extern NSString* gAbortRequestPeer;
extern BOOL gAbortRequestSawVirtualHEAD;

@interface AbortProbeConnection : WSKConnection
@end

// Two delegates for the weak-delegate swap test. What matters is that BOTH conform and BOTH are
// alive: WSKFullDelegate implements the optional callback, WSKPartialDelegate does not. Every
// method in these protocols is @optional, so an object implementing a subset is the designed-for
// case, not an abuse.
@interface WSKFullDelegate : NSObject <WSKDelegate>
@property (nonatomic) BOOL sawStart;
@end

@interface WSKPartialDelegate : NSObject <WSKDelegate>
@property (nonatomic) BOOL sawConnect;
@end
