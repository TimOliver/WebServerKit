# Bounded Lingering Close Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop `close(2)` from destroying a response the server already sent, by half-closing and draining bounded amounts of unread inbound data before the descriptor is released.

**Architecture:** One new terminal step on `WSKConnection`. When the response's write chain ends and the connection will not be reused, check whether unread inbound data exists; if it does, `shutdown(SHUT_WR)` and then read-and-discard on the existing connection queue until EOF or a bound trips. The async read block retains `self`, so `-dealloc` — and therefore `close(_socket)` — is naturally deferred until draining finishes. No file descriptor ever escapes the connection object.

**Tech Stack:** Objective-C, GCD (`dispatch_read`, `dispatch_source_timer`), BSD sockets (`ioctl(FIONREAD)`, `shutdown(2)`), XCTest.

## Global Constraints

- Design spec: `docs/superpowers/specs/2026-08-18-lingering-close-design.md`. Read it first.
- Bounds are **fixed constants, not options**: 2 s total, 500 ms no-bytes gap, 64 KB discard cap.
- No public API additions. Lingering is always on.
- Ordinary responses must be **byte-identical** to today. All eight trace suites are a gate on every task that touches `Sources/`.
- Verification bar per task: `./Run-Tests.sh` green (192+ tests, 8 trace suites, `EXIT=0`).
- Warning bar: zero warnings whose path is under the repo, across **Sources AND Framework**:
  `xcodebuild ... 2>&1 | grep "warning:" | grep "/Users/TiM/Developer/WebServerKit" | wc -l` must print `0`.
  (Checking only `/Sources/` has hidden real warnings before.)
- Commit trailer on every commit: `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`.
- Never open a pull request. Push the branch only if asked.
- Branch: `fix/lingering-close`, created from `main`.

**Architectural fact discovered while planning, which the spec's `-stop` section assumed otherwise:**
`-[WSKWebServer stop]` does **not** wait on live connections — it waits on `_sourceGroup`, which covers only the *listening* sources' cancel handlers. So a lingering connection **cannot** delay `-stop`. The abandon rule in Task 4 therefore exists so a stopping server stops draining sockets and releases descriptors promptly, not to protect `-stop` latency. Do not add any waiting to `-stop`.

---

### Task 1: Detect unread inbound data

The cheap guard that keeps the ordinary path free. Everything else is gated on it.

**Files:**
- Modify: `Sources/WebServerKit/Core/WSKPrivate.h` (declare beside the other audit-shaped helpers)
- Modify: `Sources/WebServerKit/Core/WSKFunctions.m` (implement)
- Test: `Framework/WSKConnectionTests.m`

**Interfaces:**
- Consumes: nothing.
- Produces: `BOOL WSKSocketHasUnreadInboundData(int socket)` — YES iff the socket's receive queue holds at least one byte. Returns NO when it cannot tell.

- [ ] **Step 1: Write the failing test**

Add to `Framework/WSKConnectionTests.m`, before the final `@end`:

```objc
// close(2) on a socket with unread inbound data makes the kernel send RST instead of FIN, and an
// RST destroys bytes already handed to TCP — including a response already delivered into the
// client's buffer. This predicate is the cheap guard that decides whether a connection needs to
// linger at all, so the ordinary case (nothing unread) keeps closing exactly as it always has.
- (void)testUnreadInboundDataIsDetected {
    int fds[2] = { -1, -1 };
    XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, fds), 0);

    XCTAssertFalse(WSKSocketHasUnreadInboundData(fds[0]), @"an idle socket has nothing unread");

    XCTAssertEqual(write(fds[1], "x", 1), (ssize_t)1);

    // Delivery through the socket layer is not instantaneous; poll briefly rather than sleeping a
    // fixed amount, so this cannot flake on a loaded machine.
    BOOL sawData = NO;
    for (int i = 0; (i < 200) && !sawData; i++) {
        sawData = WSKSocketHasUnreadInboundData(fds[0]);
        if (!sawData) {
            usleep(1000);
        }
    }
    XCTAssertTrue(sawData, @"a byte sitting in the receive queue must be reported");

    char scratch = 0;
    XCTAssertEqual(read(fds[0], &scratch, 1), (ssize_t)1);
    XCTAssertFalse(WSKSocketHasUnreadInboundData(fds[0]), @"draining the byte clears the condition");

    // A closed descriptor must answer NO rather than assert or report garbage: the caller uses this
    // to decide whether to do MORE work, so "cannot tell" has to mean "behave exactly as before".
    close(fds[0]);
    close(fds[1]);
    XCTAssertFalse(WSKSocketHasUnreadInboundData(fds[0]), @"an unusable descriptor must fail to NO");
}
```

- [ ] **Step 2: Run it and watch it fail to compile**

```bash
xcodebuild test -project WebServerKit.xcodeproj -scheme "WebServerKit (Mac)" -configuration Debug -only-testing:"Tests (Mac)/WSKConnectionTests/testUnreadInboundDataIsDetected" CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER= 2>&1 | grep -E "error:|Executed [0-9]+ test"
```

Expected: a compile error, `use of undeclared identifier 'WSKSocketHasUnreadInboundData'`.

- [ ] **Step 3: Declare it**

In `Sources/WebServerKit/Core/WSKPrivate.h`, in the block of audit-shaped helpers (the section whose comment begins "The audit-shaped half of what used to be WSKFunctions.h"), add:

```objc
/**
 *  Does this socket have inbound data that has been received but not yet read?
 *
 *  close(2) on a socket in that state makes the kernel send RST rather than FIN, and an RST
 *  discards bytes already handed to TCP — including a response already sitting in the client's
 *  receive buffer, unread. This is the guard that decides whether a connection must linger before
 *  closing; when it answers NO the close is exactly the one this server has always performed.
 *
 *  Answers NO when it cannot tell (a closed or non-socket descriptor), because the caller uses it
 *  to decide whether to do EXTRA work, and "unknown" must not mean "do the new thing".
 */
BOOL WSKSocketHasUnreadInboundData(int socket);
```

- [ ] **Step 4: Implement it**

In `Sources/WebServerKit/Core/WSKFunctions.m`, add near the other socket helpers. Confirm `#import <sys/ioctl.h>` is present at the top of the file and add it if not:

```objc
BOOL WSKSocketHasUnreadInboundData(int socket) {
    int pending = 0;

    if (ioctl(socket, FIONREAD, &pending) != 0) {
        return NO;
    }

    return (pending > 0);
}
```

- [ ] **Step 5: Run the test and watch it pass**

```bash
xcodebuild test -project WebServerKit.xcodeproj -scheme "WebServerKit (Mac)" -configuration Debug -only-testing:"Tests (Mac)/WSKConnectionTests/testUnreadInboundDataIsDetected" CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER= 2>&1 | grep -E "error:|Executed [0-9]+ test"
```

Expected: `Executed 1 test, with 0 failures`.

- [ ] **Step 6: Commit**

```bash
git add Sources/WebServerKit/Core/WSKPrivate.h Sources/WebServerKit/Core/WSKFunctions.m Framework/WSKConnectionTests.m
git commit -m "$(cat <<'EOF'
Add the predicate that decides whether a close needs to linger

close(2) with unread inbound data makes the kernel send RST instead of FIN, and the RST destroys
bytes already handed to TCP. This is the cheap guard for the fix that follows: when it answers NO —
the overwhelmingly common case — the connection closes exactly as it always has.

Answers NO when ioctl cannot tell, because the caller uses it to decide whether to do EXTRA work and
"unknown" must not select the new behaviour.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Half-close and drain to EOF

The fix itself, with only the total deadline as a bound. The remaining two bounds arrive in Task 3.

**Files:**
- Modify: `Sources/WebServerKit/Core/WSKConnection.m` (constants near line 49; new ivars in the `@implementation` ivar block; new methods; two call sites)
- Test: `Framework/WSKConnectionTests.m`

**Interfaces:**
- Consumes: `WSKSocketHasUnreadInboundData(int)` from Task 1.
- Produces: `-[WSKConnection _beginLingeringCloseIfNeeded]` — call at any terminal point after the response's write chain has completed and the connection will not be reused. Safe to call more than once; the second call is a no-op.

- [ ] **Step 1: Write the failing test**

Add to `Framework/WSKConnectionTests.m` before the final `@end`. This is the statistical layer: the defect is a race, so one trial proves nothing.

```objc
// A header-time refusal answered while the client is still uploading is the measured case: the
// server writes a complete 400 and closes, but the client is still sending, so the receive queue is
// non-empty and close(2) emits RST — which destroys the response the client has not read yet.
// Measured on unfixed source: 391 bytes complete on one run, 167 bytes truncated mid-headers on the
// next. Because it is a race, this runs K trials and requires ALL of them to be clean.
- (void)testRefusalSurvivesWhileClientIsStillSending {
    NSString* directory = MakeTempDirectory();
    WSKWebDAVServer* server = [[WSKWebDAVServer alloc] initWithUploadDirectory:directory];
    NSDictionary* options = @{WSKOption_Port : @0, WSKOption_BindToLocalhost : @YES};
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    NSUInteger const trials = 20;
    NSUInteger clean = 0;
    NSMutableArray<NSString*>* failures = [NSMutableArray array];

    for (NSUInteger trial = 0; trial < trials; trial++) {
        int fd = ConnectToLocalhostPort(server.port);
        XCTAssertGreaterThan(fd, 0);

        // Content-Range on PUT is refused 400 in the connection layer, before any body is spooled,
        // so the server answers immediately while the body is still arriving. WebDAV is used
        // because it HANDLES PUT — on a server with no PUT handler this is a bodiless 501 abort
        // instead, which has no error page to lose and would make this test prove nothing.
        NSString* header = @"PUT /x.bin HTTP/1.1\r\nHost: localhost\r\nContent-Range: bytes 0-2/10\r\nContent-Length: 67108864\r\n\r\n";
        const char* headerBytes = [header UTF8String];
        XCTAssertEqual(send(fd, headerBytes, strlen(headerBytes), 0), (ssize_t)strlen(headerBytes));

        // Keep pushing body from another thread so the receive queue stays non-empty while the
        // server refuses and closes. SIGPIPE is disabled on this socket so a send after the peer
        // goes away fails rather than killing the test process.
        int const noSignal = 1;
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, sizeof(noSignal));
        dispatch_semaphore_t pumpDone = dispatch_semaphore_create(0);
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            char* chunk = malloc(65536);
            memset(chunk, 'Z', 65536);
            for (int i = 0; i < 1024; i++) {
                if (send(fd, chunk, 65536, 0) < 0) {
                    break;
                }
            }
            free(chunk);
            dispatch_semaphore_signal(pumpDone);
        });

        BOOL sawEOF = NO;
        NSData* reply = ReadToEOF(fd, &sawEOF);
        dispatch_semaphore_wait(pumpDone, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
        close(fd);

        NSString* text = [[NSString alloc] initWithData:reply encoding:NSUTF8StringEncoding];
        NSRange const separator = (text != nil) ? [text rangeOfString:@"\r\n\r\n"] : NSMakeRange(NSNotFound, 0);
        BOOL const rightStatus = (text != nil) && [text hasPrefix:@"HTTP/1.1 400"];

        // The ORACLE IS THE BODY, and this is the whole subtlety of this test. When the RST lands,
        // the reply truncates to exactly its 167 bytes of headers and loses the 224-byte error
        // page. A truncated reply therefore STILL starts "HTTP/1.1 400" and STILL contains the
        // header terminator — asserting on those two passes 80/80 against unfixed source and
        // detects nothing. Measured: 391 bytes with the body, 167 without, never anything between.
        NSUInteger const bodyLength = (separator.location == NSNotFound) ? 0 : (text.length - NSMaxRange(separator));

        if (rightStatus && (separator.location != NSNotFound) && (bodyLength > 0)) {
            clean += 1;
        } else if (failures.count < 3) {
            [failures addObject:[NSString stringWithFormat:@"trial %lu: %lu bytes, body=%lu, sawEOF=%@",
                                 (unsigned long)trial, (unsigned long)reply.length,
                                 (unsigned long)bodyLength, sawEOF ? @"YES" : @"NO"]];
        }
    }

    XCTAssertEqual(clean, trials, @"a refusal must reach the client intact every time: %@",
                   [failures componentsJoinedByString:@"; "]);

    [server stop];
    [[NSFileManager defaultManager] removeItemAtPath:directory error:NULL];
}
```

- [ ] **Step 2: Run it against unfixed source and confirm it FAILS**

```bash
xcodebuild test -project WebServerKit.xcodeproj -scheme "WebServerKit (Mac)" -configuration Debug -only-testing:"Tests (Mac)/WSKConnectionTests/testRefusalSurvivesWhileClientIsStillSending" CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER= 2>&1 | grep -E "error: -\[|Executed [0-9]+ test"
```

Expected: FAIL, with `clean` below 20 and at least one failure line showing `body=0`. **If it passes, stop and investigate before writing any implementation** — either the race is not reproducing on this machine or the test is not exercising the refusal path, and an implementation validated by a test that never failed is worth nothing. Re-run up to 3 times before concluding it passes.

- [ ] **Step 3: Add the constants**

In `Sources/WebServerKit/Core/WSKConnection.m`, beside `kMaxHeaderPhaseTicks` (~line 47):

```objc
// Lingering close. close(2) with unread inbound data makes the kernel send RST instead of FIN, and
// the RST destroys bytes already handed to TCP — a response the client has not read yet. So when
// data is still arriving, half-close (which tells the client to stop) and drain briefly first.
//
// Bounded because draining holds one of the kWSKMaxConnections slots. The cost is negligible
// against what is already tolerated: kMaxHeaderPhaseTicks ticks of the idle timer is 60-90s at the
// 30s default, so a 2s linger cannot become the cheapest way to occupy a slot. Fixed constants
// rather than options, like kWSKMaxConnections and the in-memory budget.
#define kLingerTotalSeconds 2.0            // Absolute deadline for the whole drain
#define kLingerDiscardCap (64 * 1024)      // Early exit: a client mid-upload will never reach EOF
#define kLingerReadChunk (16 * 1024)       // Discard buffer size
```

- [ ] **Step 4: Add the ivars**

In the `@implementation WSKConnection { ... }` ivar block, beside the other per-connection state:

```objc
    BOOL _lingering;                    // On _connectionQueue only
    NSUInteger _lingerDiscarded;        // Bytes read and thrown away while lingering
    CFAbsoluteTime _lingerDeadline;     // Absolute time the drain must stop
```

- [ ] **Step 5: Implement the linger**

Add to `Sources/WebServerKit/Core/WSKConnection.m`, next to `-_finishConnectionOrReadNextRequest`:

```objc
// The terminal step for a connection that will not be reused. Called once the response's write
// chain has completed, so everything this connection intends to send is already queued.
//
// Does NOTHING when the receive queue is empty, which is the overwhelmingly common case: an
// ordinary GET, and every request in the trace corpus, closes byte-identically to before.
//
// When data IS still arriving, shutdown(SHUT_WR) first. That flushes the response and tells the
// client we are done writing, so a well-behaved client stops sending and closes, and the drain
// below ends at EOF within a round trip. Draining WITHOUT the half-close — nginx's lingering_close
// shape — was rejected: a client uploading 64 MB never reaches EOF inside any sane bound, so the
// drain would hit its cap with data still unread and close, reproducing the exact RST this exists
// to prevent.
//
// The dispatch_read block retains self, so -dealloc — and with it close(_socket) — is deferred
// until draining finishes. No descriptor escapes this object and slot accounting is unchanged.
- (void)_beginLingeringCloseIfNeeded {
    if (_lingering) {
        return;
    }

    if (!WSKSocketHasUnreadInboundData(_socket)) {
        return;
    }

    _lingering = YES;
    _lingerDiscarded = 0;
    _lingerDeadline = CFAbsoluteTimeGetCurrent() + kLingerTotalSeconds;
    shutdown(_socket, SHUT_WR);
    WSK_LOG_DEBUG(@"Lingering before close on socket %i", _socket);
    [self _lingerDrain];
}

- (void)_lingerDrain {
    dispatch_read(_socket, kLingerReadChunk, _connectionQueue, ^(dispatch_data_t data, int error) {
        size_t const received = data ? dispatch_data_get_size(data) : 0;

        if ((error != 0) || (received == 0)) {
            WSK_LOG_DEBUG(@"Lingering close drained to EOF on socket %i", self->_socket);
            return;  // Done: the block's reference to self goes away and -dealloc closes the socket
        }

        self->_lingerDiscarded += received;

        if (self->_lingerDiscarded >= (NSUInteger)kLingerDiscardCap) {
            WSK_LOG_DEBUG(@"Lingering close hit its discard cap on socket %i", self->_socket);
            return;
        }

        if (CFAbsoluteTimeGetCurrent() >= self->_lingerDeadline) {
            WSK_LOG_DEBUG(@"Lingering close hit its deadline on socket %i", self->_socket);
            return;
        }

        [self _lingerDrain];
    });
}
```

- [ ] **Step 6: Call it from the two terminal paths**

First, in `-_finishConnectionOrReadNextRequest`, replace the early return:

```objc
- (void)_finishConnectionOrReadNextRequest {
    if (!_willKeepAlive) {
        [self _beginLingeringCloseIfNeeded];
        return;
    }
```

Second, in `-abortRequest:withStatusCode:`, replace the empty write completion block so a refusal
lingers too — these are bodiless-by-construction responses sent while a body is still arriving, and
are the main beneficiaries:

```objc
    [self writeHeadersWithCompletionBlock:^(BOOL success){
        if (success) {
            [self _beginLingeringCloseIfNeeded];
        }
    }];
```

- [ ] **Step 7: Run the test and watch it pass**

```bash
xcodebuild test -project WebServerKit.xcodeproj -scheme "WebServerKit (Mac)" -configuration Debug -only-testing:"Tests (Mac)/WSKConnectionTests/testRefusalSurvivesWhileClientIsStillSending" CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER= 2>&1 | grep -E "error: -\[|Executed [0-9]+ test"
```

Expected: `Executed 1 test, with 0 failures`. Run it 3 times; all 3 must pass, since a fix that is
itself racy would show up here.

- [ ] **Step 8: Run the full bar**

```bash
./Run-Tests.sh 2>&1 | tail -40
```

Expected: `** TEST SUCCEEDED **`, 8 `--- Tests/` lines, and the trace corpus green — the corpus is the proof that ordinary responses are byte-identical.

- [ ] **Step 9: Commit**

```bash
git add Sources/WebServerKit/Core/WSKConnection.m Framework/WSKConnectionTests.m
git commit -m "$(cat <<'EOF'
Half-close and drain before closing, so a refusal is not destroyed by its own RST

A response the server considered sent could be destroyed by the act of closing: close(2) with unread
inbound data makes the kernel send RST, and the RST discards bytes already handed to TCP. Measured
on a WebDAV PUT refused for Content-Range while the client kept uploading -- 391 bytes complete on
one run, 167 bytes truncated mid-headers on the next.

When the receive queue is non-empty the connection now shuts down its write side, which flushes the
response and tells the client to stop, then drains briefly before closing. Draining alone -- nginx's
lingering_close shape -- was rejected: a client uploading 64 MB never reaches EOF within any sane
bound, so the drain would hit its cap with data unread and close, reproducing the same RST.

When the receive queue is empty nothing happens at all, so an ordinary GET and the whole trace
corpus close byte-identically to before.

The test runs 20 trials and requires all of them clean, because the defect is a race; a single trial
passes on unfixed source about half the time.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: The remaining two bounds

The deadline in Task 2 only trips when data keeps arriving. A client that stops sending without
closing would otherwise pin the connection until the idle timer notices.

**Files:**
- Modify: `Sources/WebServerKit/Core/WSKConnection.m`
- Test: `Framework/WSKConnectionTests.m`

**Interfaces:**
- Consumes: `-_beginLingeringCloseIfNeeded`, `-_lingerDrain` from Task 2.
- Produces: no new symbols. A gap timer bounds the wait between reads.

- [ ] **Step 1: Write the failing test**

```objc
// A client that stops sending but never closes must not pin a connection slot for the whole idle
// timeout. Asserted through the SLOT returning, not wall-clock: this suite already has two timing
// tests that flake under load and must not gain a third. Descriptor count is the observable proxy —
// it returns to baseline only once the connection object is gone, which is what releases the slot.
- (void)testLingeringCloseReleasesItsSlotWhenTheClientGoesQuiet {
    NSString* directory = MakeTempDirectory();
    WSKWebDAVServer* server = [[WSKWebDAVServer alloc] initWithUploadDirectory:directory];
    NSDictionary* options = @{WSKOption_Port : @0, WSKOption_BindToLocalhost : @YES};
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    NSUInteger const baseline = OpenFileDescriptorCount();

    int fd = ConnectToLocalhostPort(server.port);
    XCTAssertGreaterThan(fd, 0);

    // Declare a huge body, send a little of it, then go silent WITHOUT closing. The refusal is
    // written immediately, the receive queue is non-empty, so the connection lingers — and then
    // nothing more ever arrives.
    NSString* header = @"PUT /x.bin HTTP/1.1\r\nHost: localhost\r\nContent-Range: bytes 0-2/10\r\nContent-Length: 67108864\r\n\r\n";
    const char* headerBytes = [header UTF8String];
    XCTAssertEqual(send(fd, headerBytes, strlen(headerBytes), 0), (ssize_t)strlen(headerBytes));
    char filler[4096];
    memset(filler, 'Z', sizeof(filler));
    send(fd, filler, sizeof(filler), 0);

    // Well inside the 30s idle timeout, so passing this cannot be the idle timer doing the work.
    BOOL released = NO;
    for (int i = 0; (i < 100) && !released; i++) {
        usleep(50 * 1000);
        released = (OpenFileDescriptorCount() <= baseline);
    }

    XCTAssertTrue(released, @"a lingering connection must release its slot once the client goes quiet");

    close(fd);
    [server stop];
    [[NSFileManager defaultManager] removeItemAtPath:directory error:NULL];
}
```

- [ ] **Step 2: Run it and confirm it FAILS**

```bash
xcodebuild test -project WebServerKit.xcodeproj -scheme "WebServerKit (Mac)" -configuration Debug -only-testing:"Tests (Mac)/WSKConnectionTests/testLingeringCloseReleasesItsSlotWhenTheClientGoesQuiet" CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER= 2>&1 | grep -E "error: -\[|Executed [0-9]+ test"
```

Expected: FAIL — the `dispatch_read` from Task 2 is still outstanding, so nothing releases within 5 s.

- [ ] **Step 3: Add the gap constant and the timer ivar**

Beside the other linger constants:

```objc
#define kLingerGapSeconds 0.5              // No bytes for this long: the client is done, stop waiting
```

In the ivar block, beside the linger ivars from Task 2:

```objc
    dispatch_source_t _lingerTimer;     // Nil unless lingering; on _connectionQueue only
```

- [ ] **Step 4: Arm the gap timer**

Replace `-_beginLingeringCloseIfNeeded`'s final `[self _lingerDrain];` with an armed timer, and add
the two helpers. The timer forces the outstanding `dispatch_read` to complete by shutting the read
side down, which is the same mechanism the idle timer already uses:

```objc
    [self _armLingerTimer];
    [self _lingerDrain];
}

// Bounds the wait BETWEEN reads. dispatch_read has no timeout of its own, so a client that stops
// sending without closing would leave the read outstanding until the idle timer noticed. Firing
// shuts the read side down, which completes that read with EOF and ends the drain through its
// normal path — the same technique the idle timer uses, rather than a second way to tear down.
- (void)_armLingerTimer {
    if (_lingerTimer == nil) {
        _lingerTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _connectionQueue);
        __weak WSKConnection* weakSelf = self;
        dispatch_source_set_event_handler(_lingerTimer, ^{
            WSKConnection* strongSelf = weakSelf;

            if (strongSelf == nil) {
                return;
            }

            WSK_LOG_DEBUG(@"Lingering close went quiet on socket %i", strongSelf->_socket);
            [strongSelf _cancelLingerTimer];
            shutdown(strongSelf->_socket, SHUT_RD);
        });
        dispatch_resume(_lingerTimer);
    }

    dispatch_source_set_timer(_lingerTimer,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kLingerGapSeconds * NSEC_PER_SEC)),
                              DISPATCH_TIME_FOREVER,
                              (uint64_t)(0.05 * NSEC_PER_SEC));
}

- (void)_cancelLingerTimer {
    if (_lingerTimer) {
        dispatch_source_cancel(_lingerTimer);
        _lingerTimer = nil;
    }
}
```

- [ ] **Step 5: Re-arm on progress, cancel on every exit**

In `-_lingerDrain`, cancel the timer on each terminating branch and re-arm it after a successful
read. The three `return` branches become:

```objc
        if ((error != 0) || (received == 0)) {
            WSK_LOG_DEBUG(@"Lingering close drained to EOF on socket %i", self->_socket);
            [self _cancelLingerTimer];
            return;
        }

        self->_lingerDiscarded += received;

        if (self->_lingerDiscarded >= (NSUInteger)kLingerDiscardCap) {
            WSK_LOG_DEBUG(@"Lingering close hit its discard cap on socket %i", self->_socket);
            [self _cancelLingerTimer];
            return;
        }

        if (CFAbsoluteTimeGetCurrent() >= self->_lingerDeadline) {
            WSK_LOG_DEBUG(@"Lingering close hit its deadline on socket %i", self->_socket);
            [self _cancelLingerTimer];
            return;
        }

        [self _armLingerTimer];
        [self _lingerDrain];
```

Also cancel it in `-dealloc`, beside the existing `_idleTimer` cancellation, so a timer can never
outlive its connection:

```objc
    if (_lingerTimer) {
        dispatch_source_cancel(_lingerTimer);
    }
```

- [ ] **Step 6: Run both linger tests and watch them pass**

```bash
xcodebuild test -project WebServerKit.xcodeproj -scheme "WebServerKit (Mac)" -configuration Debug -only-testing:"Tests (Mac)/WSKConnectionTests/testLingeringCloseReleasesItsSlotWhenTheClientGoesQuiet" -only-testing:"Tests (Mac)/WSKConnectionTests/testRefusalSurvivesWhileClientIsStillSending" CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER= 2>&1 | grep -E "error: -\[|Executed [0-9]+ test"
```

Expected: `Executed 2 tests, with 0 failures`.

- [ ] **Step 7: Run the full bar**

```bash
./Run-Tests.sh 2>&1 | tail -40
```

Expected: `** TEST SUCCEEDED **` and 8 trace suites.

- [ ] **Step 8: Commit**

```bash
git add Sources/WebServerKit/Core/WSKConnection.m Framework/WSKConnectionTests.m
git commit -m "$(cat <<'EOF'
Bound the drain on silence, not just on data

The deadline added with the drain only trips while bytes keep arriving. A client that stops sending
without closing left the read outstanding, so the connection held its slot until the idle timer
noticed -- up to 30s for a case that should cost half a second.

A gap timer now bounds the wait BETWEEN reads. Firing shuts the read side down, which completes the
outstanding read with EOF and ends the drain through its normal path, rather than introducing a
second way to tear a connection down. It is re-armed on progress and cancelled on every exit,
including -dealloc, so it can never outlive its connection.

Asserted through the descriptor count returning to baseline rather than wall-clock: this suite has
two timing tests that flake under load already and does not need a third.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Abandon lingering when the server stops

**Files:**
- Modify: `Sources/WebServerKit/Core/WSKWebServer.m` (stopping flag), `Sources/WebServerKit/Core/WSKPrivate.h` (expose it to connections), `Sources/WebServerKit/Core/WSKConnection.m` (check it)
- Test: `Framework/WSKServerLifecycleTests.m`

**Interfaces:**
- Consumes: the linger machinery from Tasks 2 and 3.
- Produces: `-[WSKWebServer isStopping]` — readable from any thread WITHOUT `_stateQueue`.

**Read before starting:** `-stop` does **not** wait on live connections, so lingering cannot delay it. This task exists so a stopping server stops draining and releases descriptors promptly. Do not add waiting to `-stop`.

- [ ] **Step 1: Write the failing test**

```objc
// Lingering must not outlive the server. -stop does not wait on live connections (it waits on
// _sourceGroup, the listening sources only), so a drain cannot delay shutdown — but a connection
// still draining after -stop holds a descriptor the host app believes it has released.
- (void)testStopAbandonsLingeringConnections {
    NSString* directory = MakeTempDirectory();
    WSKWebDAVServer* server = [[WSKWebDAVServer alloc] initWithUploadDirectory:directory];
    NSDictionary* options = @{WSKOption_Port : @0, WSKOption_BindToLocalhost : @YES};
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    NSUInteger const baseline = OpenFileDescriptorCount();

    int fd = ConnectToLocalhostPort(server.port);
    XCTAssertGreaterThan(fd, 0);
    NSString* header = @"PUT /x.bin HTTP/1.1\r\nHost: localhost\r\nContent-Range: bytes 0-2/10\r\nContent-Length: 67108864\r\n\r\n";
    const char* headerBytes = [header UTF8String];
    XCTAssertEqual(send(fd, headerBytes, strlen(headerBytes), 0), (ssize_t)strlen(headerBytes));

    int const noSignal = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, sizeof(noSignal));
    __block BOOL keepSending = YES;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        char* chunk = malloc(65536);
        memset(chunk, 'Z', 65536);
        while (keepSending) {
            if (send(fd, chunk, 65536, 0) < 0) {
                break;
            }
        }
        free(chunk);
    });

    usleep(200 * 1000);  // Let the refusal go out and the drain begin
    [server stop];

    BOOL released = NO;
    for (int i = 0; (i < 60) && !released; i++) {
        usleep(50 * 1000);
        released = (OpenFileDescriptorCount() <= baseline);
    }
    keepSending = NO;

    XCTAssertTrue(released, @"a connection still draining when the server stops must be abandoned");

    close(fd);
    [[NSFileManager defaultManager] removeItemAtPath:directory error:NULL];
}
```

- [ ] **Step 2: Run it and confirm it FAILS**

```bash
xcodebuild test -project WebServerKit.xcodeproj -scheme "WebServerKit (Mac)" -configuration Debug -only-testing:"Tests (Mac)/WSKServerLifecycleTests/testStopAbandonsLingeringConnections" CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER= 2>&1 | grep -E "error: -\[|Executed [0-9]+ test"
```

Expected: FAIL — the drain keeps running for the full 2 s deadline after `-stop`, exceeding the 3 s poll only marginally, so if it passes, raise the send rate rather than assuming the feature exists.

- [ ] **Step 3: Add the flag to the server**

In `Sources/WebServerKit/Core/WSKWebServer.m`, add to the ivar block:

```objc
    atomic_bool _stopping;               // Read from connection queues WITHOUT _stateQueue
```

Ensure `#import <stdatomic.h>` is at the top of the file. Set it in `-_stopWithOptions`, as its
first statement:

```objc
    atomic_store(&_stopping, true);
```

and clear it in `-_startWithOptions:error:` on success, so a restarted server lingers again:

```objc
    atomic_store(&_stopping, false);
```

Add the accessor:

```objc
// Deliberately does NOT go through _stateQueue. A connection reads this from its own queue while
// -stop is running ON _stateQueue, and routing it through that queue would deadlock — the same
// hazard as reading -serverURL inside a delegate callback.
- (BOOL)isStopping {
    return atomic_load(&_stopping);
}
```

- [ ] **Step 4: Declare it for connections**

In `Sources/WebServerKit/Core/WSKPrivate.h`, in the `WSKWebServer` private category that connections already use:

```objc
/**
 *  YES once -stop has begun. Safe to read from any thread and deliberately NOT serialized on the
 *  server's state queue, because connections read it from their own queues while -stop runs.
 */
@property (nonatomic, readonly, getter=isStopping) BOOL stopping;
```

- [ ] **Step 5: Check it in the drain**

In `-_lingerDrain`, add as the first test inside the block, before the EOF check:

```objc
        if (self->_server.isStopping) {
            WSK_LOG_DEBUG(@"Abandoning lingering close on socket %i: server is stopping", self->_socket);
            [self _cancelLingerTimer];
            return;
        }
```

And in `-_beginLingeringCloseIfNeeded`, refuse to start one at all:

```objc
    if (_server.isStopping) {
        return;
    }
```

- [ ] **Step 6: Run the test and watch it pass**

```bash
xcodebuild test -project WebServerKit.xcodeproj -scheme "WebServerKit (Mac)" -configuration Debug -only-testing:"Tests (Mac)/WSKServerLifecycleTests/testStopAbandonsLingeringConnections" CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER= 2>&1 | grep -E "error: -\[|Executed [0-9]+ test"
```

Expected: `Executed 1 test, with 0 failures`.

- [ ] **Step 7: Run the full bar plus the lifecycle suite three times**

```bash
./Run-Tests.sh 2>&1 | tail -40
for i in 1 2 3; do xcodebuild test -project WebServerKit.xcodeproj -scheme "WebServerKit (Mac)" -configuration Debug -only-testing:"Tests (Mac)/WSKServerLifecycleTests" CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER= 2>&1 | grep -E "Executed [0-9]+ test" | head -1; done
```

Expected: `** TEST SUCCEEDED **`, and 3 clean lifecycle runs — start/stop is the area with four historical races, so one green run is not enough.

- [ ] **Step 8: Commit**

```bash
git add Sources/WebServerKit/Core/WSKWebServer.m Sources/WebServerKit/Core/WSKPrivate.h Sources/WebServerKit/Core/WSKConnection.m Framework/WSKServerLifecycleTests.m
git commit -m "$(cat <<'EOF'
Abandon a lingering close when the server stops

A connection draining when -stop is called held a descriptor the host app believed it had released,
for up to the 2s linger deadline.

Note what this is NOT: -stop does not wait on live connections -- it waits on _sourceGroup, which
covers only the listening sources -- so lingering never delayed shutdown. This is about not draining
a socket for a server that is gone.

The flag is atomic and deliberately not serialized on _stateQueue: connections read it from their own
queues while -stop runs ON that queue, and routing it through would deadlock, the same hazard as
reading -serverURL inside a delegate callback.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Real clients, and record what was learned

Half-close is the novel part of this design: telling a client "I am done writing" while it is still uploading is exactly what a kernel client can react badly to. The corpus cannot catch that.

**Files:**
- Modify: `Sources/WebServerKit/include/WebServerKit/WSKWebServer.h` (document the guarantee)
- Modify: `CLAUDE.md`

**Interfaces:**
- Consumes: everything from Tasks 1-4.
- Produces: no code symbols.

- [ ] **Step 1: Verify with curl**

```bash
xcodebuild build -project WebServerKit.xcodeproj -sdk macosx -target "WebServerKit Example (Mac)" -configuration Release SYMROOT=$(pwd)/build CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER=
mkdir -p /tmp/wsk-linger && (logLevel=1 ./build/Release/WebServerKitExample -mode webDAV -root /tmp/wsk-linger --localhost &)
sleep 2
mkfile 256m /tmp/wsk-big.bin
curl -sv -T /tmp/wsk-big.bin -H "Content-Range: bytes 0-2/10" http://localhost:8080/big.bin 2>&1 | tail -20
```

Expected: curl reports the 400 and its error page, not a connection reset. Record the exact output.

- [ ] **Step 2: Verify with a real kernel WebDAV client**

```bash
mkdir -p ~/wsk-linger-mnt
mount_webdav -S -v wsk-linger http://localhost:8080/ ~/wsk-linger-mnt
sleep 3
cp /tmp/wsk-big.bin ~/wsk-linger-mnt/copied.bin && cmp /tmp/wsk-big.bin ~/wsk-linger-mnt/copied.bin && echo "BYTE-IDENTICAL"
ls ~/wsk-linger-mnt
umount ~/wsk-linger-mnt
```

Expected: mount succeeds, a 256 MB write round-trips byte-identically, clean unmount. This is the check that half-close has not upset a picky client. If it fails, **stop** — the design's stated risk has materialised and needs a decision, not a workaround.

- [ ] **Step 3: Verify with rclone**

```bash
rclone --webdav-url=http://localhost:8080 --webdav-vendor=other --retries=1 copy /tmp/wsk-big.bin :webdav:
rclone --webdav-url=http://localhost:8080 --webdav-vendor=other --retries=1 check /tmp/ :webdav: --include "wsk-big.bin" 2>&1 | tail -3
pkill -f WebServerKitExample; rm -rf /tmp/wsk-linger /tmp/wsk-big.bin ~/wsk-linger-mnt
```

Expected: 0 differences.

- [ ] **Step 4: Document the guarantee in the public header**

In `Sources/WebServerKit/include/WebServerKit/WSKWebServer.h`, in the class documentation, add:

```objc
 *  Responses are delivered whole. When a client is still sending as its request is answered, the
 *  server half-closes and briefly drains before closing, because close(2) with unread inbound data
 *  makes the kernel send RST and an RST destroys bytes the client has not read yet. The one
 *  exception is -stop: a connection still draining when the server shuts down is abandoned, so a
 *  client may lose that last response.
```

- [ ] **Step 5: Update CLAUDE.md**

Replace the "No lingering close" entry under **Still open at tip** with a Core-invariants entry, and correct the two claims measurement overturned:

```markdown
- **Lingering close.** `close(2)` with unread inbound data makes the kernel send RST, and the RST
  destroys bytes already handed to TCP — a response the client has not read yet. Measured before the
  fix on a WebDAV PUT refused for `Content-Range` while the client kept uploading: 391 B complete on
  one run, **167 B truncated mid-headers** on the next. So the old record's "the status never is
  [lost]" was WRONG, and its "last pipelined response" framing was a special case — plain pipelining
  never reproduced, because the server consumes pipelined bytes in the same read. The rule is unread
  inbound data at close time, whatever produced it.
  Fixed by `shutdown(SHUT_WR)` then a bounded drain, and ONLY when the receive queue is non-empty, so
  an ordinary GET and the whole trace corpus close byte-identically. Half-close rather than a
  drain-only `lingering_close`: draining alone still ends in RST, because a client uploading 64 MB
  never reaches EOF inside any sane bound. Bounds are 2 s total, a 500 ms silence gap, and a 64 KB
  discard cap — fixed constants. The slot cost that kept this open is negligible: the header-phase
  deadline is `kMaxHeaderPhaseTicks` (2) ticks of the 30 s idle timer, i.e. **60–90 s**, so a 2 s
  linger cannot be the cheapest way to occupy a slot. `-stop` abandons lingering; note that `-stop`
  never waited on connections anyway, so this was never about shutdown latency.
```

- [ ] **Step 6: Final verification**

```bash
./Run-Tests.sh 2>&1 | tail -40
```

and the warning bar across all platforms:

```bash
for S in "WebServerKit (Mac)|" "WebServerKit (iOS)|generic/platform=iOS Simulator" "WebServerKit (tvOS)|generic/platform=tvOS Simulator"; do
  NAME="${S%%|*}"; DEST="${S#*|}"
  if [ -z "$DEST" ]; then ARGS=""; else ARGS="-destination $DEST"; fi
  echo "$NAME: $(xcodebuild build -project WebServerKit.xcodeproj -scheme "$NAME" -configuration Debug $ARGS CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER= 2>&1 | grep "warning:" | grep -c "/Users/TiM/Developer/WebServerKit") repo warnings"
done
swift build
```

Expected: `** TEST SUCCEEDED **`, 8 trace suites, `0 repo warnings` on all three, SPM builds.

- [ ] **Step 7: Commit**

```bash
git add CLAUDE.md Sources/WebServerKit/include/WebServerKit/WSKWebServer.h
git commit -m "$(cat <<'EOF'
Record the lingering close, and correct two claims the measurement overturned

The recorded finding said a client could lose the last PIPELINED response and that the status was
never lost. Both were wrong. Plain pipelining does not reproduce at all -- the server consumes
pipelined bytes in the same read -- and a refusal measured 167 bytes TRUNCATED MID-HEADERS on one
run, so the status is not safe either. The rule is unread inbound data at close time, whatever
produced it.

Also corrected: the slot-cost objection that kept this open. The header-phase deadline is
kMaxHeaderPhaseTicks (2) ticks of the 30s idle timer, so a slowloris already holds a slot for 60-90s,
not the 30s an earlier draft of the argument claimed. A 2s linger is over an order of magnitude
cheaper.

Verified against real clients, because half-close is the novel part and the corpus cannot see it:
curl -T against a refusing endpoint, a mount_webdav 256 MB round trip, and rclone check.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

## Notes for the implementer

- **If a test passes before you write the implementation, stop.** The whole value of this plan is
  that each test is shown to fail first. The Task 2 test is statistical; re-run it up to 3 times
  before concluding it genuinely passes on unfixed source.
- **Read the executed count, not the failure count.** A crashed runner reports "Executed 0 tests,
  with 0 failures". Use a fresh log filename each run; a stale log has been read as a passing run
  before.
- **Do not overlap `Run-Tests.sh` with anything else heavy.** Two idle-timeout tests flake under
  load; re-run a failure in isolation before believing it.
- **The trace corpus is the proof that ordinary responses did not change.** If any of the eight
  suites goes red, the guard in Task 1 is being bypassed somewhere — do not re-record the corpus.
