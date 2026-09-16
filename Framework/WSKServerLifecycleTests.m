// Starting, stopping, delegates, and NAT port mapping.
//
// Split out of the single Tests.m that held all 159 tests; the grouping is by subject, not by
// the pass that added each test.

#import <float.h>
#import <limits.h>
#import <math.h>
#import <stdatomic.h>

#import "TestsSupport.h"

@interface WSKWebServer (WSKTimeoutOptionProbe)
- (int)_createListeningSocket:(BOOL)useIPv6
                 localAddress:(const void *)address
                       length:(socklen_t)length
        maxPendingConnections:(NSUInteger)maxPendingConnections
                        error:(NSError **)error;
@end

// Count the listener entry point instead of connecting to an invalid configuration: accepting
// a client would exercise the very floating-point-to-integer conversions these tests guard.
@interface WSKTimeoutOptionProbeServer : WSKWebServer
@property (nonatomic) NSUInteger listeningSocketAttempts;
@end

@implementation WSKTimeoutOptionProbeServer
- (int)_createListeningSocket:(BOOL)useIPv6
                 localAddress:(const void *)address
                       length:(socklen_t)length
        maxPendingConnections:(NSUInteger)maxPendingConnections
                        error:(NSError **)error {
    self.listeningSocketAttempts += 1;
    return [super _createListeningSocket:useIPv6 localAddress:address length:length maxPendingConnections:maxPendingConnections error:error];
}
@end

@interface WSKServerLifecycleTests : XCTestCase
@end

@implementation WSKServerLifecycleTests

- (void)testWebServer {
    WSKWebServer *server = [[WSKWebServer alloc] init];

    XCTAssertNotNil(server);
}

- (void)_drainMainQueueForTimeoutOptionCallbacks {
    XCTestExpectation *const drained = [self expectationWithDescription:@"queued startup callbacks have run"];
    dispatch_async(dispatch_get_main_queue(), ^{
        [drained fulfill];
    });
    [self waitForExpectations:@[drained] timeout:2.0];
}

- (void)_assertTimeoutOption:(NSString *)option rejectsValues:(NSArray<NSNumber *> *)values {
    for (NSNumber *const value in values) {
        @autoreleasepool {
            WSKTimeoutOptionProbeServer *const server = [[WSKTimeoutOptionProbeServer alloc] init];
            WSKFullDelegate *const delegate = [[WSKFullDelegate alloc] init];
            server.delegate = delegate;
            [server addDefaultHandlerForMethod:@"GET"
                                  requestClass:[WSKRequest class]
                                  processBlock:^WSKResponse *(WSKRequest *request) {
                                      return [WSKDataResponse responseWithText:@"recovered"];
                                  }];
            NSTimeInterval const previousIdleTimeout = server.connectionIdleTimeout;
            NSTimeInterval const previousKeepAliveTimeout = server.connectionKeepAliveTimeout;
            NSDictionary *const invalidOptions = @{
                WSKOption_Port: @0,
                WSKOption_BindToLocalhost: @YES,
                option: value
            };
            NSError *error = nil;
            BOOL const started = [server startWithOptions:invalidOptions error:&error];
            XCTAssertFalse(started, @"%@ must reject %@", option, value);
            XCTAssertNotNil(error, @"%@ = %@ must explain the failed start", option, value);
            XCTAssertTrue([error.localizedDescription containsString:option], @"%@", error);
            XCTAssertFalse(server.isRunning, @"%@ = %@ must leave the server stopped", option, value);
            XCTAssertEqual(server.port, (NSUInteger)0);
            XCTAssertNil(server.serverURL);
            XCTAssertEqual(server.listeningSocketAttempts, (NSUInteger)0, @"reject before opening either listener");
            XCTAssertEqualWithAccuracy(server.connectionIdleTimeout, previousIdleTimeout, 0.0, @"rejection must not apply configuration");
            XCTAssertEqualWithAccuracy(server.connectionKeepAliveTimeout, previousKeepAliveTimeout, 0.0, @"rejection must not apply configuration");
            [self _drainMainQueueForTimeoutOptionCallbacks];
            XCTAssertFalse(delegate.sawStart, @"%@ = %@ must not announce a start", option, value);

            // Baseline accepts these values. Clean up that unexpected startup without ever
            // opening a client; after a proper refusal, recovery needs no intervening stop.
            if (started) {
                [server stop];
            }
            delegate.sawStart = NO;
            NSDictionary *const validOptions = @{
                WSKOption_Port: @0,
                WSKOption_BindToLocalhost: @YES,
                WSKOption_ConnectionIdleTimeout: @2.5,
                WSKOption_ConnectionKeepAliveTimeout: @0.0
            };
            error = nil;
            XCTAssertTrue([server startWithOptions:validOptions error:&error], @"must recover after %@ = %@: %@", option, value, error);
            XCTAssertNil(error);
            XCTAssertTrue(server.isRunning);
            XCTAssertGreaterThan(server.listeningSocketAttempts, (NSUInteger)0, @"the probe must also observe a real startup");
            XCTAssertEqualWithAccuracy(server.connectionIdleTimeout, 2.5, 0.0);
            XCTAssertEqualWithAccuracy(server.connectionKeepAliveTimeout, 0.0, 0.0);
            [self _drainMainQueueForTimeoutOptionCallbacks];
            XCTAssertTrue(delegate.sawStart, @"valid recovery must still announce its start");
            NSString *const reply = SendRawRequest(server.port, @"GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
            XCTAssertTrue(ReplyHasStatus(reply, 200), @"%@", reply);
            XCTAssertTrue([reply hasSuffix:@"recovered"], @"%@", reply);
            [server stop];
        }
    }
}

- (void)testInvalidIdleTimeoutsFailBeforeListeningAndAllowRecovery {
    NSArray<NSNumber *> *const values = @[@(-1.0), @(NAN), @(INFINITY), @(-INFINITY), @(DBL_MAX), @(nextafter((double)INT_MAX, HUGE_VAL)), @(nextafter(1e-9, 0.0))];
    [self _assertTimeoutOption:WSKOption_ConnectionIdleTimeout rejectsValues:values];
}

- (void)testInvalidKeepAliveTimeoutsFailBeforeListeningAndAllowRecovery {
    NSArray<NSNumber *> *const values = @[@(-1.0), @(NAN), @(INFINITY), @(-INFINITY), @(DBL_MAX), @(nextafter((double)INT_MAX, HUGE_VAL))];
    [self _assertTimeoutOption:WSKOption_ConnectionKeepAliveTimeout rejectsValues:values];
}

- (void)testTimeoutOptionsAcceptZeroFractionsAndRepresentableBoundaries {
    NSArray<NSArray<NSNumber *> *> *const values = @[
        @[@0.0, @0.0],
        @[@(-0.0), @(-0.0)],
        @[@2.5, @1.25],
        @[@1.25, @2.5],
        @[@0.0, @2.5],
        @[@1e-9, @0.0],
        @[@2.5, @(nextafter(0.0, 1.0))],
        @[@(INT_MAX), @(INT_MAX)]
    ];
    WSKTimeoutOptionProbeServer *const server = [[WSKTimeoutOptionProbeServer alloc] init];
    for (NSArray<NSNumber *> *const pair in values) {
        NSDictionary *const options = @{
            WSKOption_Port: @0,
            WSKOption_BindToLocalhost: @YES,
            WSKOption_ConnectionIdleTimeout: pair[0],
            WSKOption_ConnectionKeepAliveTimeout: pair[1]
        };
        NSUInteger const previousAttempts = server.listeningSocketAttempts;
        NSError *error = nil;
        XCTAssertTrue([server startWithOptions:options error:&error], @"idle %@, keep-alive %@: %@", pair[0], pair[1], error);
        XCTAssertNil(error);
        XCTAssertTrue(server.isRunning);
        XCTAssertGreaterThan(server.port, (NSUInteger)0);
        XCTAssertNotNil(server.serverURL);
        XCTAssertGreaterThan(server.listeningSocketAttempts, previousAttempts);
        XCTAssertEqualWithAccuracy(server.connectionIdleTimeout, pair[0].doubleValue, 0.0);
        XCTAssertEqualWithAccuracy(server.connectionKeepAliveTimeout, pair[1].doubleValue, 0.0);
        // Startup-only at the representable extremes: a 1ns idle timer on an accepted
        // connection would spin, and these assertions concern admission of the option.
        [server stop];
    }
}

// Every delegate callback checks -respondsToSelector: and then hops to the main queue, where it
// reads the delegate AGAIN. The property is weak AND mutable, so those can be different objects —
// and an @optional protocol makes partial implementations the designed-for case. A host app that
// swaps one live delegate for another implementing a different subset therefore raises
// unrecognized-selector, and nothing in Sources/ catches an NSException: the process dies.
//
// ⚠️ Two oracles that look right and are worthless, both measured: setting the delegate to NIL and
// letting it DEALLOCATE are already safe, because the weak read yields nil and messaging nil is a
// no-op. The test has to swap in a second LIVE object that conforms and omits the selector.
//
// ⚠️ Against the unfixed tree this does not fail — it TERMINATES the runner, which reports
// "Executed 0 tests, with 0 failures". Read the executed count, as this project has had to four
// times before.
//
// -startWithOptions: dispatch_syncs onto the state queue, so the respondsToSelector: check runs
// while this thread is blocked and the block lands on a LATER main-queue turn. No concurrency is
// needed to hit the window: straight-line code suffices.
- (void)testDelegateSwappedBetweenCheckAndCallbackDoesNotRaise {
    WSKFullDelegate *full = [[WSKFullDelegate alloc] init];
    WSKPartialDelegate *partial = [[WSKPartialDelegate alloc] init];

    WSKWebServer *server = [[WSKWebServer alloc] init];
    [server addHandlerForMethod:@"GET"
                           path:@"/ok"
                   requestClass:[WSKRequest class]
                   processBlock:^WSKResponse *(WSKRequest *request) {
                       return [WSKDataResponse responseWithText:@"ok"];
                   }];
    server.delegate = full;

    NSDictionary *options = @{WSKOption_Port: @0, WSKOption_BindToLocalhost: @YES};
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    // The check has run against `full` and the block is queued; swap before it lands.
    server.delegate = partial;

    // Let the queued callback run. Unfixed, this is where the process dies.
    for (int i = 0; i < 20; i++) {
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    }

    XCTAssertFalse(full.sawStart, @"the callback must not reach the delegate that was replaced");
    XCTAssertTrue([server isRunning], @"the server is unaffected");

    // And what must keep working: an UNCHANGED delegate still receives its callback. This is the
    // half a re-check could silently break.
    [server stop];

    for (int i = 0; i < 20; i++) {
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    }

    WSKFullDelegate *stable = [[WSKFullDelegate alloc] init];
    WSKWebServer *second = [[WSKWebServer alloc] init];
    [second addHandlerForMethod:@"GET"
                           path:@"/ok"
                   requestClass:[WSKRequest class]
                   processBlock:^WSKResponse *(WSKRequest *request) {
                       return [WSKDataResponse responseWithText:@"ok"];
                   }];
    second.delegate = stable;
    XCTAssertTrue([second startWithOptions:options error:NULL]);

    for (int i = 0; i < 20 && !stable.sawStart; i++) {
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    }

    XCTAssertTrue(stable.sawStart, @"an unchanged delegate must still be called");
    [second stop];
}

// The NAT-PMP callbacks arrive on the main run loop and used to mutate _dnsService /
// _dnsAddress / _dnsPort with no confinement, racing -_stop's DNSServiceRefDeallocate and
// every -publicServerURL read. They now take _stateQueue, which introduces a dispatch_sync
// from the main thread into the lifecycle queue — so the thing to prove is that repeated
// start/stop cycles still complete rather than deadlocking.
- (void)testNATPortMappingStartStopCyclesDoNotDeadlock {
    for (int i = 0; i < 5; i++) {
        @autoreleasepool {
            WSKWebServer *server = [[WSKWebServer alloc] init];
            [server addDefaultHandlerForMethod:@"GET"
                                  requestClass:[WSKRequest class]
                                  processBlock:^WSKResponse *(WSKRequest *request) {
                                      return [WSKDataResponse responseWithText:@"ok"];
                                  }];
            NSDictionary *options = @{
                WSKOption_Port: @0,
                WSKOption_BindToLocalhost: @YES,
                WSKOption_RequestNATPortMapping: @YES
            };
            XCTAssertTrue([server startWithOptions:options error:NULL], @"cycle %i failed to start", i);

            // Reading publicServerURL takes _stateQueue, the same queue the callbacks now
            // take; doing it while the mapping request is in flight is the interesting case.
            (void)server.publicServerURL;
            XCTAssertTrue(ReplyHasStatus(SendRawRequest(server.port, @"GET / HTTP/1.1\r\nHost: localhost\r\n\r\n"), 200));

            [server stop];
            XCTAssertFalse(server.isRunning, @"cycle %i did not stop", i);
        }
    }
}

// -stop on a server whose start FAILED asserted _source4 != NULL, so the tidy-up an
// error path would naturally do aborted a Debug build. Stopping something that never
// started must be a no-op.
- (void)testStopAfterAFailedStartIsANoOp {
    WSKWebServer *server = [[WSKWebServer alloc] init];
    [server addDefaultHandlerForMethod:@"GET"
                          requestClass:[WSKRequest class]
                          processBlock:^WSKResponse *(WSKRequest *request) {
                              return [WSKDataResponse responseWithText:@"hi"];
                          }];

    // Port 1 is privileged, so bind(2) fails for an unprivileged test process.
    NSDictionary *privileged = @{WSKOption_Port: @1, WSKOption_BindToLocalhost: @YES};
    XCTAssertFalse([server startWithOptions:privileged error:NULL]);
    XCTAssertFalse(server.isRunning);
    XCTAssertNoThrow([server stop]);
    XCTAssertNoThrow([server stop]);
}

// -startWithOptions:error: returns NO for an already-running server but left *error nil, so a
// host app doing the documented thing had nothing to report. It also aborted a Debug build.
- (void)testStartingAnAlreadyStartedServerReportsAnError {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dir = MakeTempDirectory();
    WSKWebServer *server = [[WSKWebServer alloc] init];
    [server addGETHandlerForBasePath:@"/" directoryPath:dir indexFilename:nil cacheAge:0 allowRangeRequests:YES];

    NSDictionary *options = @{WSKOption_Port: @0, WSKOption_BindToLocalhost: @YES};
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    NSError *error = nil;
    BOOL started = NO;
    XCTAssertNoThrow(started = [server startWithOptions:options error:&error]);
    XCTAssertFalse(started, @"starting twice must fail");
    XCTAssertNotNil(error, @"a failed start must set *error");

    [server stop];
    [fm removeItemAtPath:dir error:NULL];
}

// A path with no leading slash aborted in Debug with no diagnostic and registered NOTHING in
// Release -- so a host app got either a crash it could not read or a server that 404'd everything
// with no clue why. This is the identical shape -addGETHandlerForBasePath: was given normalization
// for one method away; leaving it here is recurring defect shape #2, a class closed at one of the
// sites it occurs at.
//
// Like the other host-app process-kills, the unfixed signal is a DEAD RUNNER reporting
// "Executed 0 tests, with 0 failures", not a red assertion.
- (void)testHandlerRegistrationNormalizesAMissingLeadingSlashInsteadOfAborting {
    WSKWebServer *server = [[WSKWebServer alloc] init];
    [server addHandlerForMethod:@"GET"
                           path:@"noslash"
                   requestClass:[WSKRequest class]
                   processBlock:^WSKResponse *(WSKRequest *request) {
                       return [WSKDataResponse responseWithText:@"REACHED"];
                   }];
    // An unusable path must be refused loudly rather than aborting -- and must not register a
    // handler that then shadows everything, which is why this is asserted rather than assumed.
    [server addHandlerForMethod:@"GET"
                           path:@""
                   requestClass:[WSKRequest class]
                   processBlock:^WSKResponse *(WSKRequest *request) {
                       return [WSKDataResponse responseWithText:@"EMPTY"];
                   }];
    // A regex that cannot compile is the same shape: an unusable string argument, not a
    // programming error worth killing the process over.
    [server addHandlerForMethod:@"GET"
                      pathRegex:@"[unterminated"
                   requestClass:[WSKRequest class]
                   processBlock:^WSKResponse *(WSKRequest *request) {
                       return [WSKDataResponse responseWithText:@"REGEX"];
                   }];

    NSDictionary *options = @{WSKOption_Port: @0, WSKOption_BindToLocalhost: @YES};  // Hoisted: commas split the macro
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    NSString *reply = SendRawRequest(server.port, @"GET /noslash HTTP/1.1\r\nHost: localhost\r\n\r\n");
    XCTAssertTrue([reply containsString:@"REACHED"], @"a missing leading slash is a spelling, not an error: %@", reply);

    // And the refused registrations really did register nothing, rather than claiming some path.
    NSString *other = SendRawRequest(server.port, @"GET /anything-else HTTP/1.1\r\nHost: localhost\r\n\r\n");
    XCTAssertTrue([other hasPrefix:@"HTTP/1.1 404"], @"a refused registration must not shadow other paths: %@", other);

    [server stop];
}

// Lingering must not outlive the server. -stop does not wait on live connections (it waits on
// _sourceGroup, the listening sources only), so a drain cannot delay shutdown — but a connection
// still draining after -stop holds a descriptor the host app believes it has released.
//
// This test's plan brief specified an unthrottled sender (one big malloc'd chunk, resent as fast
// as send(2) allows) and a 60 x 50ms = 3s poll. Run verbatim against this exact source (Task 1-3
// committed, Task 4 not yet written), it PASSED in 0.290s -- the opposite of the brief's own "the
// drain keeps running for the full 2s deadline" expectation, and a false green by this project's
// own standard of proving an oracle sensitive before trusting it. The debug log showed why:
// "Connection received 155275 bytes" -- an unthrottled loopback sender fills the kernel receive
// buffer far past kLingerDiscardCap (64KB) within the 200ms before -stop is even called, so once
// draining starts it satisfies the discard cap in one or two reads and closes in well under
// 100ms, regardless of what -stop does. Raising the send rate, the brief's suggested remedy, makes
// this WORSE, not better: more data buffered sooner reaches the cap sooner. There is a second,
// independent way this test could pass for the wrong reason even with the cap avoided: the drain's
// own absolute deadline (kLingerTotalSeconds, 2s from when lingering begins, which is before
// -stop is even called here) falls inside a 3s poll that starts at -stop, so a poll that generous
// would also catch an UNFIXED server's natural, unrelated deadline completion -- proving nothing
// about -stop. Both are fixed below by pacing the sender (proven techniques from
// -testLingeringCloseReleasesItsSlotWhenTheClientGoesQuiet, see its comment) and by shortening the
// poll window to safely under 2s.
//
// A THIRD correction, found only once the first two were in place and this still passed for the
// wrong reason: -stop tears down BOTH listening sockets (IPv4 and IPv6 -- "Did close IPv4/IPv6
// listening socket" is logged on every run), and baseline was captured while they were still open.
// "baseline + 1" (this test's own client fd, the correction
// -testLingeringCloseReleasesItsSlotWhenTheClientGoesQuiet's comment records and this test copied)
// is right for THAT test, where -stop runs after the assertion and the listening sockets never
// move during the poll. Here -stop runs BEFORE the poll, so by the time polling starts the count
// has already dropped by 2 for a reason that has nothing to do with the connection under test --
// confirmed by instrumenting -_lingerDrain's EOF branch with the read count and errno during
// diagnosis: the drain was still mid-burst (26,560 bytes discarded, no cap, no deadline, nowhere
// near kLingerGapSeconds) when the assertion declared victory. "baseline - 1" is the correct
// floor: -2 for the listening sockets -stop always closes, +1 for this test's own fd, which stays
// open until the assertion is done.
- (void)testStopAbandonsLingeringConnections {
    NSString *directory = MakeTempDirectory();
    WSKWebDAVServer *server = [[WSKWebDAVServer alloc] initWithUploadDirectory:directory];
    NSDictionary *options = @{WSKOption_Port: @0, WSKOption_BindToLocalhost: @YES};
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    // Warm up and settle exactly as -testLingeringCloseReleasesItsSlotWhenTheClientGoesQuiet does
    // (see its comment for the full account): run solo, XCTest's own process-startup descriptor
    // churn can otherwise read as "released" before the connection under test has done anything.
    XCTAssertNotNil(SendRawRequest(server.port, @"GET / HTTP/1.1\r\nHost: localhost\r\n\r\n"));

    NSUInteger baseline = OpenFileDescriptorCount();
    NSUInteger stableStreak = 0;
    for (int i = 0; (i < 200) && (stableStreak < 5); i++) {
        usleep(10 * 1000);
        NSUInteger const current = OpenFileDescriptorCount();
        if (current == baseline) {
            stableStreak += 1;
        } else {
            baseline = current;
            stableStreak = 0;
        }
    }

    int fd = ConnectToLocalhostPort(server.port);
    XCTAssertGreaterThan(fd, 0);
    NSString *header = @"PUT /x.bin HTTP/1.1\r\nHost: localhost\r\nContent-Range: bytes 0-2/10\r\nContent-Length: 67108864\r\n\r\n";
    const char *headerBytes = [header UTF8String];
    XCTAssertEqual(send(fd, headerBytes, strlen(headerBytes), 0), (ssize_t)strlen(headerBytes));

    int const noSignal = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, sizeof(noSignal));
    __block atomic_bool keepSending = true;
    dispatch_group_t senderGroup = dispatch_group_create();
    dispatch_group_async(senderGroup, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        // Phase 1: many small sends in a tight loop, the exact shape
        // -testLingeringCloseReleasesItsSlotWhenTheClientGoesQuiet already relies on to let the
        // header read fire and complete on the header alone, so this filler stays genuinely
        // unread rather than being scooped up as extraData alongside it. 400 x 64 = 25,600 bytes,
        // comfortably under kLingerDiscardCap on its own.
        char burst[64];
        memset(burst, 'Z', sizeof(burst));
        for (int i = 0; (i < 400) && atomic_load(&keepSending); i++) {
            if (send(fd, burst, sizeof(burst), 0) < 0) {
                break;
            }
        }

        // Phase 2: a paced trickle so the receive queue never empties (never handing this to the
        // kLingerGapSeconds gap timer -- a 100ms gap is well under its 500ms threshold, so this
        // keeps proving abandonment despite an ACTIVELY SENDING client, not a quiet one) while
        // adding only ~10KB/s. Even added to phase 1, reaching the 64KB discard cap this way is
        // several seconds out -- comfortably outside the poll window below -- so an unfixed
        // server is bound only by kLingerTotalSeconds (2s), the thing this test is actually about.
        char drip[1024];
        memset(drip, 'Z', sizeof(drip));
        while (atomic_load(&keepSending)) {
            usleep(100 * 1000);
            if (send(fd, drip, sizeof(drip), 0) < 0) {
                break;
            }
        }
    });

    usleep(200 * 1000);  // Let the refusal go out and the drain begin
    [server stop];

    // Deliberately shorter than kLingerTotalSeconds (2s), not the brief's original 3s: this must
    // observe -stop's abandonment specifically, not an unfixed drain's own natural deadline
    // completing inside an over-long poll window (2s < 3s, so a 3s poll cannot tell the two
    // apart). 1.2s leaves a comfortable margin below the 2s deadline while remaining generous
    // against the sub-200ms release this project's fixed connections have measured elsewhere.
    //
    // baseline - 1, not baseline + 1: see the comment above this method for why. -stop, called
    // before this loop starts (unlike -testLingeringCloseReleasesItsSlotWhenTheClientGoesQuiet,
    // which calls it after), closes both listening sockets and permanently drops the count by 2;
    // this test's own fd stays open through the assertion and adds back 1.
    BOOL released = NO;
    for (int i = 0; (i < 24) && !released; i++) {
        usleep(50 * 1000);
        released = (OpenFileDescriptorCount() <= baseline - 1);
    }
    atomic_store(&keepSending, false);

    // Join before touching fd again: phase 2 checks the flag, then sleeps up to 100ms, then sends --
    // so the sender can still be inside send(fd, ...) for a moment after the flag flips, and closing
    // underneath it would be a stray write to what may already be a recycled descriptor. Bounded
    // (not DISPATCH_TIME_FOREVER) so a genuine hang fails this test instead of wedging the suite.
    long const joined = dispatch_group_wait(senderGroup, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)));
    XCTAssertEqual(joined, 0, @"sender did not join before close(fd)");

    XCTAssertTrue(released, @"a connection still draining when the server stops must be abandoned");

    close(fd);
    [[NSFileManager defaultManager] removeItemAtPath:directory error:NULL];
}

// Reads one reply: the header block plus whatever length it declares. A receive timeout bounds it,
// because a kept-alive connection sends nothing more until the next request and reading to EOF
// would wait out the whole keep-alive timeout.
static NSString *ReadOneReply(int fd) {
    struct timeval tv = {3, 0};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    NSMutableData *buffered = [NSMutableData data];

    while (1) {
        NSString *const soFar = [[NSString alloc] initWithData:buffered encoding:NSUTF8StringEncoding];
        NSRange const headerEnd = soFar ? [soFar rangeOfString:@"\r\n\r\n"] : NSMakeRange(NSNotFound, 0);

        if (headerEnd.location != NSNotFound) {
            NSRange const label = [soFar rangeOfString:@"Content-Length: " options:NSCaseInsensitiveSearch];
            NSInteger const expected = (label.location != NSNotFound) ? [[soFar substringFromIndex:NSMaxRange(label)] integerValue] : 0;

            if ((NSInteger)(soFar.length - NSMaxRange(headerEnd)) >= expected) {
                break;
            }
        }

        char chunk[4096];
        ssize_t const got = recv(fd, chunk, sizeof(chunk), 0);

        if (got <= 0) {
            break;
        }

        [buffered appendBytes:chunk length:(NSUInteger)got];
    }

    NSString *const reply = [[NSString alloc] initWithData:buffered encoding:NSUTF8StringEncoding];
    return reply ? reply : @"";
}

// A connection reads the server's handler array LIVE, at match time, for every request it serves —
// the one piece of server configuration missing from the accept-time snapshot that the ivar block
// exists for. Handlers may be re-registered once the server is stopped (the header forbids it only
// "while the server is running", and -stop nils the options the assertion guards on), but -stop
// does not wait on connections, so a kept-alive connection outlives that stop and keeps reading the
// array while another thread rewrites it. The deterministic half is pinned here: the second request
// on a connection accepted under one handler set was answered by a set registered afterwards. The
// same live read is also a data race, and reproduced as a SIGSEGV under concurrent mutation; a
// crash cannot be asserted on, so this pins the observable that shares its cause.
- (void)testConnectionServesTheHandlersItWasAcceptedUnder {
    WSKWebServer *server = [[WSKWebServer alloc] init];
    [server addHandlerForMethod:@"GET"
                           path:@"/which"
                   requestClass:[WSKRequest class]
                   processBlock:^WSKResponse *(WSKRequest *request) {
                       return [WSKDataResponse responseWithText:@"SESSION-ONE"];
                   }];

    NSDictionary *options = @{WSKOption_Port: @0, WSKOption_BindToLocalhost: @YES, WSKOption_ConnectionKeepAliveTimeout: @10.0};
    XCTAssertTrue([server startWithOptions:options error:NULL]);
    NSUInteger const port = server.port;

    int fd = ConnectToLocalhostPort(port);
    XCTAssertGreaterThan(fd, 0);
    NSString *const request = @"GET /which HTTP/1.1\r\nHost: localhost\r\n\r\n";
    const char *bytes = [request UTF8String];
    XCTAssertEqual(send(fd, bytes, strlen(bytes), 0), (ssize_t)strlen(bytes));

    NSString *const firstReply = ReadOneReply(fd);
    XCTAssertTrue([firstReply containsString:@"SESSION-ONE"], @"the connection is serving under the first handler set: %@", firstReply);
    XCTAssertTrue([firstReply rangeOfString:@"keep-alive" options:NSCaseInsensitiveSearch].location != NSNotFound, @"…and was offered for reuse: %@", firstReply);

    // Contract-legal: the server is stopped, so -isRunning is NO and the mutation assertion passes.
    [server stop];
    [server removeAllHandlers];
    [server addHandlerForMethod:@"GET"
                           path:@"/which"
                   requestClass:[WSKRequest class]
                   processBlock:^WSKResponse *(WSKRequest *request) {
                       return [WSKDataResponse responseWithText:@"SESSION-TWO"];
                   }];

    XCTAssertEqual(send(fd, bytes, strlen(bytes), 0), (ssize_t)strlen(bytes));
    NSString *const secondReply = ReadOneReply(fd);
    close(fd);

    XCTAssertFalse([secondReply containsString:@"SESSION-TWO"],
                   @"a connection accepted under one handler set must never be answered by handlers registered after it: %@",
                   secondReply);
}

@end
