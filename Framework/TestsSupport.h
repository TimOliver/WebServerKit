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
extern NSData* UTF8Data(NSString* string);
extern NSURL* LiteralURL(NSString* string);
extern int ConnectToLocalhostPort(NSUInteger port);
extern NSData* ReadToEOF(int fd, BOOL* sawEOF);
extern NSUInteger DrainToEOFAtPace(int fd, NSUInteger chunkSize, useconds_t pauseMicroseconds);
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

// Observes the documented -open/-close subclassing pair, plus every -abortRequest: status. Both
// hooks are declared once-per-CONNECTION ("called when the connection is opened", and -open may
// return NO to reject it), so a host app that allocates in one and releases in the other is
// following the header. Connection reuse has to leave that pairing intact, and it must not
// manufacture a response when a persistent connection simply ends — the events are recorded in
// order so a test can assert on the whole sequence rather than a count.
extern NSMutableArray<NSString*>* gConnectionEvents;

@interface LifecycleProbeConnection : WSKConnection
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
