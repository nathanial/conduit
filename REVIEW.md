# Conduit Review Findings

## Findings

- Critical: Unbuffered `send` can clobber an in-flight send because it never waits for `pending_ready` to clear. With two concurrent senders, the second overwrites `pending_value`, one value is dropped/leaked, and one sender can hang forever. This affects both `send` and `sendTimeout`. `util/conduit/native/src/conduit_ffi.c:291` `util/conduit/native/src/conduit_ffi.c:600`
  - Status: fixed by waiting for `pending_ready` to clear before installing a new pending send (and respecting close/timeout).
  - Regression: `concurrent unbuffered sends deliver all values` in `ConduitTests/ConcurrencyTests.lean`.
- High: `Broadcast.Hub.subscribe` has a race with hub shutdown: if `closed` flips between the `get` and `modify`, the new subscriber can be added after the broadcaster already closed existing subscribers, leaving it open forever and never receiving values. `util/conduit/Conduit/Broadcast.lean:61` `util/conduit/Conduit/Broadcast.lean:69`
  - Status: fixed by storing `closed` and subscribers in a single ref and updating them atomically.
- Medium: `conduit_select_wait` can return `none` even when `timeout_ms == 0` if it wakes and another thread consumes readiness before the final poll. That violates the “wait until ready” contract unless you explicitly allow spurious `none`. `util/conduit/native/src/conduit_ffi.c:1090` `util/conduit/native/src/conduit_ffi.c:1110`
  - Status: fixed by retrying the wait when timeout is 0 unless all cases are send-on-closed.

## Missing Tests

- Unbuffered `sendTimeout` with concurrent senders (or mixed `send`/`sendTimeout`) to confirm no value loss and no stuck sender under contention.
- Hub subscribe/close race: concurrently close source while subscribing; assert `subscribe` returns `none` or a channel that is immediately closed.
- `selectWait` robustness: loop many times with a competing receiver draining the channel and assert `selectWait` never returns `none` when cases are non-empty and timeout is 0.

## Checks

- `lake build` (util/conduit) — success
- `lake test` (util/conduit) — 219/219 passing

## Questions/Assumptions

- I assumed unbuffered channels are intended to support multiple concurrent senders (Go-style). If you intend single-sender semantics, the `pending_ready` behavior should be documented and the tests adjusted accordingly.
- Is `selectWait` allowed to return `none` without timeout? If not, it should loop until a ready case appears.
