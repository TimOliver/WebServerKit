// Starting, stopping, delegates, and NAT port mapping.
//
// Split out of the single Tests.m that held all 159 tests; the grouping is by subject, not by
// the pass that added each test.

#import "TestsSupport.h"

@interface WSKServerLifecycleTests : XCTestCase
@end

@implementation WSKServerLifecycleTests

- (void)testWebServer {
    WSKWebServer *server = [[WSKWebServer alloc] init];

    XCTAssertNotNil(server);
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
    WSKFullDelegate* full = [[WSKFullDelegate alloc] init];
    WSKPartialDelegate* partial = [[WSKPartialDelegate alloc] init];

    WSKWebServer* server = [[WSKWebServer alloc] init];
    [server addHandlerForMethod:@"GET"
                           path:@"/ok"
                   requestClass:[WSKRequest class]
                   processBlock:^WSKResponse*(WSKRequest* request) {
                       return [WSKDataResponse responseWithText:@"ok"];
                   }];
    server.delegate = full;

    NSDictionary* options = @{WSKOption_Port : @0, WSKOption_BindToLocalhost : @YES};
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

    WSKFullDelegate* stable = [[WSKFullDelegate alloc] init];
    WSKWebServer* second = [[WSKWebServer alloc] init];
    [second addHandlerForMethod:@"GET"
                           path:@"/ok"
                   requestClass:[WSKRequest class]
                   processBlock:^WSKResponse*(WSKRequest* request) {
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
            WSKWebServer* server = [[WSKWebServer alloc] init];
            [server addDefaultHandlerForMethod:@"GET"
                                  requestClass:[WSKRequest class]
                                  processBlock:^WSKResponse*(WSKRequest* request) {
                                      return [WSKDataResponse responseWithText:@"ok"];
                                  }];
            NSDictionary* options = @{
                WSKOption_Port : @0,
                WSKOption_BindToLocalhost : @YES,
                WSKOption_RequestNATPortMapping : @YES
            };
            XCTAssertTrue([server startWithOptions:options error:NULL], @"cycle %i failed to start", i);

            // Reading publicServerURL takes _stateQueue, the same queue the callbacks now
            // take; doing it while the mapping request is in flight is the interesting case.
            (void)server.publicServerURL;
            XCTAssertTrue([SendRawRequest(server.port, @"GET / HTTP/1.1\r\nHost: localhost\r\n\r\n") containsString:@"200"]);

            [server stop];
            XCTAssertFalse(server.isRunning, @"cycle %i did not stop", i);
        }
    }
}

// -stop on a server whose start FAILED asserted _source4 != NULL, so the tidy-up an
// error path would naturally do aborted a Debug build. Stopping something that never
// started must be a no-op.
- (void)testStopAfterAFailedStartIsANoOp {
    WSKWebServer* server = [[WSKWebServer alloc] init];
    [server addDefaultHandlerForMethod:@"GET" requestClass:[WSKRequest class] processBlock:^WSKResponse*(WSKRequest* request) {
        return [WSKDataResponse responseWithText:@"hi"];
    }];

    // Port 1 is privileged, so bind(2) fails for an unprivileged test process.
    NSDictionary* privileged = @{WSKOption_Port : @1, WSKOption_BindToLocalhost : @YES};
    XCTAssertFalse([server startWithOptions:privileged error:NULL]);
    XCTAssertFalse(server.isRunning);
    XCTAssertNoThrow([server stop]);
    XCTAssertNoThrow([server stop]);
}

// -startWithOptions:error: returns NO for an already-running server but left *error nil, so a
// host app doing the documented thing had nothing to report. It also aborted a Debug build.
- (void)testStartingAnAlreadyStartedServerReportsAnError {
    NSFileManager* fm = [NSFileManager defaultManager];
    NSString* dir = MakeTempDirectory();
    WSKWebServer* server = [[WSKWebServer alloc] init];
    [server addGETHandlerForBasePath:@"/" directoryPath:dir indexFilename:nil cacheAge:0 allowRangeRequests:YES];

    NSDictionary* options = @{WSKOption_Port : @0, WSKOption_BindToLocalhost : @YES};
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    NSError* error = nil;
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
    WSKWebServer* server = [[WSKWebServer alloc] init];
    [server addHandlerForMethod:@"GET"
                           path:@"noslash"
                   requestClass:[WSKRequest class]
                   processBlock:^WSKResponse*(WSKRequest* request) {
                       return [WSKDataResponse responseWithText:@"REACHED"];
                   }];
    // An unusable path must be refused loudly rather than aborting -- and must not register a
    // handler that then shadows everything, which is why this is asserted rather than assumed.
    [server addHandlerForMethod:@"GET"
                           path:@""
                   requestClass:[WSKRequest class]
                   processBlock:^WSKResponse*(WSKRequest* request) {
                       return [WSKDataResponse responseWithText:@"EMPTY"];
                   }];
    // A regex that cannot compile is the same shape: an unusable string argument, not a
    // programming error worth killing the process over.
    [server addHandlerForMethod:@"GET"
                      pathRegex:@"[unterminated"
                   requestClass:[WSKRequest class]
                   processBlock:^WSKResponse*(WSKRequest* request) {
                       return [WSKDataResponse responseWithText:@"REGEX"];
                   }];

    NSDictionary* options = @{WSKOption_Port : @0, WSKOption_BindToLocalhost : @YES};  // Hoisted: commas split the macro
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    NSString* reply = SendRawRequest(server.port, @"GET /noslash HTTP/1.1\r\nHost: localhost\r\n\r\n");
    XCTAssertTrue([reply containsString:@"REACHED"], @"a missing leading slash is a spelling, not an error: %@", reply);

    // And the refused registrations really did register nothing, rather than claiming some path.
    NSString* other = SendRawRequest(server.port, @"GET /anything-else HTTP/1.1\r\nHost: localhost\r\n\r\n");
    XCTAssertTrue([other hasPrefix:@"HTTP/1.1 404"], @"a refused registration must not shadow other paths: %@", other);

    [server stop];
}

@end
