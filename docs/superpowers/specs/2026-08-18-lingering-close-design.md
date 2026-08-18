# Bounded lingering close

**Status:** design approved, not yet implemented
**Date:** 2026-08-18

## The defect

Calling `close(2)` on a socket that still has **unread inbound data** makes the kernel send RST
instead of FIN. An RST destroys bytes the server already handed to TCP — including bytes already
delivered into the client's receive buffer but not yet read by the client application. So a response
the server considers sent can be partly or wholly destroyed by the act of closing.

Measured at tip (`5ec413e`), WebDAV `PUT` with `Content-Range` — a header-time refusal that answers
400 before any body is spooled — while the client keeps uploading:

| case | received | body | outcome |
|---|---|---|---|
| refusal, client sends no body (**control**) | 391 B | 224 B | clean FIN |
| refusal, 64 MB still inbound, run 1 | 391 B | 224 B | complete, then RST |
| refusal, 64 MB still inbound, run 2 | **167 B** | **0 B** | **truncated mid-headers** |

It is a **race**, which is why the record phrased it as "can lose". Two corrections to what
CLAUDE.md carried:

- The status line is **not** always safe. Run 2 lost the response mid-headers, not merely its body.
  The recorded claim "the status never is [lost]" is wrong.
- The "last pipelined response" framing is a special case, not the rule. Plain pipelining did **not**
  reproduce: the server consumes pipelined bytes in the same read, so nothing is left unread. The
  general rule is *unread inbound data at close time*, whatever produced it.

`curl -C -` (upload resume) puts `Content-Range` on the wire, so an everyday client reaches this.

## Guarantee

**Any response the server chose to send arrives intact — unless the server is shutting down.**

Stated at the connection layer so every response path inherits it from one place: header-time
refusals, error pages, keep-alive teardown, WebDAV, and the uploader.

## Mechanism

A terminal step on the connection, after the response's write chain completes and before the
descriptor is released:

1. **If the receive queue is empty** — close exactly as today. This is the overwhelmingly common
   path; an ordinary GET, and every request in the trace corpus, is byte-identical to current
   behaviour and pays nothing. "Empty" means `ioctl(FIONREAD)` reports 0 bytes buffered AND the
   connection has no read outstanding; both because a pending read means bytes may land between the
   check and the close.
2. **Otherwise `shutdown(SHUT_WR)`** — flushes the response and signals completion. A well-behaved
   client sees EOF, knows the response is complete, stops sending and closes.
3. **Read and discard** on the existing connection queue until EOF or a bound trips.
4. **Close.** In the common case the receive queue is now empty, so the kernel sends FIN, not RST.

### Why half-close rather than drain-only

The rejected alternative is nginx's `lingering_close` shape: no half-close, just read and discard
until EOF or a bound. **It can still end in an RST.** A client uploading 256 MB will not reach EOF
within any sane bound, so the drain hits its cap with data still unread and closes — reproducing the
exact failure. Drain-only works only probabilistically, by buying enough time for the client to have
*already read* the response before the reset lands.

Half-close attacks the cause: it tells the client to stop. The common case then terminates via EOF,
quickly, instead of running to the cap.

## Bounds

Whichever trips first. Fixed constants, not options — consistent with `kWSKMaxConnections` and the
in-memory budget being limits rather than knobs.

| bound | value | what it stops |
|---|---|---|
| total linger deadline | 2 s | a client that never stops sending |
| no-bytes gap | 500 ms | a client that stopped sending but did not close |
| discard cap | 64 KB | a fast sender making us burn the full 2 s on syscalls |

**Why 2 s is safe on a 128-slot server.** The concern recorded against this fix was that lingering
holds connection slots. It does — but by a margin that is negligible against what the server already
tolerates. The header-phase deadline is `kMaxHeaderPhaseTicks` (2) ticks of the idle timer, which
defaults to 30 s, so a client dribbling headers holds a slot for **60–90 s** before being cut. A 2 s
linger is over an order of magnitude cheaper and cannot become the cheapest way to occupy the 128.
Combined with step 1, the cost is paid only when unread data actually exists.

(Verified against the source rather than assumed: an earlier draft of this argument said "30 s",
which understated the existing tolerance and therefore understated the safety margin.)

The discard cap earns its place as an **early exit**: if a client is mid-256 MB upload we will not
reach EOF, and recognising that in 64 KB beats waiting 2 s to learn the same thing.

Uses its own short-lived timer, **not** `_idleTimer`. That timer is tick-based against a 30 s
default — an order of magnitude too coarse for 500 ms decisions — and overloading it would entangle
two very different deadlines in the machinery where the `-stop`/`-close` races have lived.

## Interactions

- **`-stop` abandons lingering at the next read completion or gap-timer fire, not immediately.**
  `isStopping` is consulted only inside the drain's read-completion handler: an actively sending
  client's next read completes almost at once, but a silent client's outstanding read only completes
  once the 500 ms no-bytes gap fires `SHUT_RD`, so `didEndConnection:`/`webServerDidStop:` can trail
  `-stop` by up to that gap. This is not about `-stop` latency — the call itself still never blocks,
  waiting only on `_sourceGroup` and never on a connection's drain, which is what matters most for
  iComics' start/stop correctness — and it avoids adding waiting to a path with four historical
  races. The shutdown caveat belongs in the public header docs.
- **SSE and streamed responses** are unaffected: the client sent one bodiless GET, so the receive
  queue is empty and step 1 short-circuits. No change to the channel or reaper machinery.
- **Keep-alive teardown** likewise — `_carryOverData` holds already-read bytes and does not make the
  receive queue non-empty.
- **`-abortRequest:` refusals** are the main beneficiaries. They are bodiless by construction today
  and are precisely the responses sent while a body is still arriving.
- **Descriptor ownership is unchanged**: `close()` stays in `-dealloc`, slot release stays
  `didEndConnection:`. Deliberate — the rejected "separate draining pool" design would have moved fd
  ownership out of the connection object, adding state to the teardown path.
- **Trace corpus must be byte-identical.** No response bytes change. All eight suites are a gate.

## Testing

Three layers, because the defect is a race and a single outcome assertion would be flaky.

1. **Deterministic, on the decision.** With unread data pending, the linger path is entered; with an
   empty queue it is skipped and the close is byte-identical to today. Tests the mechanism rather
   than the race, and cannot flake.
2. **Statistical, on the outcome.** K trials of "refusal while a large body is inbound" must *all*
   yield the complete response and a clean EOF, never `ECONNRESET`. With the fix this is
   deterministic; against unfixed source the observed sample was roughly 50/50, so K = 20 puts a
   false pass near 10⁻⁶. Discrimination validated by running against unfixed source, per the
   project's standing rule.
3. **Bounded cost.** A client that never stops sending must still be closed and its slot returned.
   Asserted via slot count with generous slack rather than tight wall-clock — this suite already has
   two timing tests that flake under load and must not gain a third.

**Real clients**, because this changes TCP-level behaviour and half-close is the kind of thing a
kernel client can be picky about:

- `curl -T` of a large file against a refusing endpoint.
- A real `mount_webdav` exercise (the record requires WebDAV changes be driven against a real
  client, not only the corpus).
- `rclone` round trip, to confirm no regression on the ordinary path.

## Risks

- **Half-close is the novel part.** A client that reacts badly to FIN-while-uploading would surface
  as a behaviour change on the upload path. This is why real-client verification is part of the
  work rather than optional.
- **Every close path now has a branch.** Step 1 must be cheap and correct, or ordinary responses pay
  for a case they never hit. The deterministic test exists to pin exactly that.
- **The measured defect is a race**, so any regression test for it is statistical. Layer 1 is what
  keeps the suite honest if the timing of layers 2 and 3 ever drifts.

## Out of scope

- The pipelined-keep-alive framing of the original finding, which did not reproduce and is subsumed
  by the general rule.
- `SO_LINGER`. It governs flushing of the send buffer on close and does not prevent the
  RST-on-unread-data behaviour this design is about.
