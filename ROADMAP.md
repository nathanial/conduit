# Conduit Roadmap

This document tracks potential improvements, new features, and code cleanup opportunities for the Conduit library (Go-style typed channels for Lean 4).

---

## Feature Proposals

### [COMPLETED] Proper Select Wait Implementation with Condition Variables

**Status:** ✅ Implemented

**Solution:**
- Added `select_waiters` linked list to channel structure
- Each select waiter has its own condition variable and mutex
- Channels notify all registered waiters on state changes (send/recv/close)
- `select_wait` registers waiter on all channels, waits on condition, then unregisters
- Channels locked in address order to prevent deadlock
- Uses `pthread_cond_timedwait` for timeout support

**Benefits:**
- Zero polling overhead - sleeps until channel ready
- Immediate wake-up when any channel becomes ready
- Proper timeout handling with `pthread_cond_timedwait`

---

### [COMPLETED] Unbuffered Channel trySend Implementation

**Status:** ✅ Implemented

**Solution:**
- Added `waiting_receivers` counter to channel structure
- Receivers increment counter before `pthread_cond_wait`, decrement after
- `trySend` checks `waiting_receivers > 0 && !pending_ready` to determine readiness
- When ready, performs immediate handoff with waiting receiver

---

### [COMPLETED] Timeout Variants for Blocking Operations

**Status:** ✅ Implemented

**Solution:**
- Added `conduit_channel_send_timeout` and `conduit_channel_recv_timeout` FFI functions
- Uses `pthread_cond_timedwait` for proper timeout handling
- `sendTimeout` returns `Option Bool`: some true = ok, some false = closed, none = timeout
- `recvTimeout` returns `Option (Option α)`: some (some v) = value, some none = closed, none = timeout

---

### [COMPLETED] Broadcast Channels (Fan-out)

**Status:** ✅ Implemented

**Solution:**
- Added `Conduit/Broadcast.lean` with pure Lean implementation
- Static broadcast: `Broadcast.create source n` creates n subscriber channels
- Dynamic hub: `Broadcast.hub source` allows runtime subscription
- Each subscriber gets an independent buffered channel
- Distributor task forwards values from source to all subscribers
- Subscribers close when source closes

**API:**
```lean
def Broadcast.create (source : Channel α) (numSubscribers : Nat)
    (bufferSize : Nat := 16) : IO (Array (Channel α))
def Broadcast.hub (source : Channel α) (bufferSize : Nat := 16) : IO (Hub α)
def Hub.subscribe (h : Hub α) : IO (Option (Channel α))
```

---

### [COMPLETED] Channel Range/Iterator Protocol

**Status:** ✅ Implemented

**Solution:**
- Added `ForIn IO (Channel α) α` instance in Combinators.lean
- Enables `for v in ch do ...` syntax
- Supports early exit with `break`
- Uses partial helper function `forInLoop` for recursion

---

### [COMPLETED] Pipeline Combinator

**Status:** ✅ Implemented

**Solution:**
- Added `pipe` and `pipeFilter` functions with operator syntax
- `|>>` for map: `ch |>> f` equivalent to `ch.map f`
- `|>?` for filter: `ch |>? p` equivalent to `ch.filter p`

**Usage:**
```lean
let step1 ← ch |>? (· > 2)      -- filter
let step2 ← step1 |>> (· * 10)  -- map
-- Or with bind:
let result ← ch |>? (· > 2) >>= (· |>> (· * 10))
```

---

### [Priority: Low] Worker Pool Pattern

**Description:** Add a worker pool abstraction for processing channel values in parallel.

**Rationale:**
- Common concurrency pattern
- Provides controlled parallelism
- Useful for CPU-bound work distribution

**Affected Files:**
- New file: `/Users/Shared/Projects/lean-workspace/util/conduit/Conduit/WorkerPool.lean`

**Proposed API:**
```lean
def workerPool (input : Channel α) (workers : Nat) (f : α → IO β) : IO (Channel β)
```

**Estimated Effort:** Medium

**Dependencies:** None

---

### [Priority: Low] Batch Receive Operation

**Description:** Add ability to receive multiple values at once from a buffered channel.

**Rationale:**
- More efficient for bulk processing
- Reduces lock contention
- Useful for batched I/O operations

**Affected Files:**
- `/Users/Shared/Projects/lean-workspace/util/conduit/Conduit/Channel.lean`
- `/Users/Shared/Projects/lean-workspace/util/conduit/native/src/conduit_ffi.c`

**Proposed API:**
```lean
opaque recvBatch (ch : Channel α) (maxCount : Nat) : IO (Array α)
opaque tryRecvBatch (ch : Channel α) (maxCount : Nat) : IO (Array α)
```

**Estimated Effort:** Medium

**Dependencies:** None

---

### [Priority: Low] Channel Statistics/Metrics

**Description:** Add ability to query channel statistics for debugging and monitoring.

**Rationale:**
- Useful for debugging deadlocks
- Helps with performance tuning
- Aids in capacity planning

**Affected Files:**
- `/Users/Shared/Projects/lean-workspace/util/conduit/Conduit/Channel.lean`
- `/Users/Shared/Projects/lean-workspace/util/conduit/native/src/conduit_ffi.c`

**Proposed API:**
```lean
structure ChannelStats where
  capacity : Nat
  currentLen : Nat
  totalSent : Nat
  totalReceived : Nat
  isClosed : Bool

opaque stats (ch : Channel α) : IO ChannelStats
```

**Estimated Effort:** Medium

**Dependencies:** None

---

## Code Improvements

### [COMPLETED] Fix Select Send Case Readiness Check for Unbuffered Channels

**Status:** ✅ Implemented

**Solution:**
- Uses same `waiting_receivers` counter added for trySend fix
- `select_poll` now checks `ch->capacity == 0 && ch->waiting_receivers > 0 && !ch->pending_ready`
- Unbuffered send cases now correctly report readiness when receiver is waiting

---

### [COMPLETED] Add TrySendResult Type for Better trySend Semantics

**Status:** ✅ Implemented

**Solution:**
- Added `TrySendResult` type with `ok`, `full`, and `closed` variants
- Updated `trySend` to return `TrySendResult` instead of `SendResult`
- Now correctly distinguishes between full buffer and closed channel

---

### [COMPLETED] Use pthread_cond_timedwait for Select Timeout

**Status:** ✅ Implemented (part of Proper Select Wait Implementation)

**Solution:**
- Select wait now uses proper condition variable signaling with `pthread_cond_timedwait`
- Immediate wake-up on channel state changes, no polling

---

### [COMPLETED] Add Functor/Monad Instances for TryResult

**Status:** ✅ Implemented

**Solution:**
- Added `Functor`, `Applicative`, and `Monad` instances for `TryResult`
- Added `bind` and `pure` helper functions
- Enables do-notation: `do let a ← tryRecv ch1; let b ← tryRecv ch2; pure (a, b)`

---

### [COMPLETED] Make Combinators Use Buffered Output Channels

**Status:** ✅ Implemented

**Solution:**
- Combinators `map`, `filter`, and `merge` use buffered output channels
- Default buffer size of 16, configurable via optional `bufferSize` parameter
- Example: `ch.map f 32` uses buffer size 32

---

### [Priority: Low] Add Error Handling Combinator

**Current State:** The `map` combinator does not handle errors in the transformation function.

**Proposed Change:**
```lean
def mapM (ch : Channel α) (f : α → IO β) : IO (Channel (Except IO.Error β))
def filterM (ch : Channel α) (p : α → IO Bool) : IO (Channel α)
```

**Benefits:**
- Proper error propagation in pipelines
- Does not silently drop errors

**Affected Files:**
- `/Users/Shared/Projects/lean-workspace/util/conduit/Conduit/Channel/Combinators.lean`

**Estimated Effort:** Small

---

### [Priority: Low] Consider Using Atomic Operations for Simple Checks

**Current State:** `isClosed` and `capacity` lock the mutex for simple reads.

**Proposed Change:**
- Use atomic loads for `closed` flag check
- Capacity is immutable, no lock needed (already correct for capacity)

**Benefits:**
- Reduced lock contention
- Better performance for status checks

**Affected Files:**
- `/Users/Shared/Projects/lean-workspace/util/conduit/native/src/conduit_ffi.c` (lines 504-516)

**Estimated Effort:** Small

---

## Code Cleanup

### [Priority: Medium] Remove Redundant Cast in Select Types

**Issue:** The cast `cast (by rfl) ch` in `Builder.addRecv` and `Builder.addSend` is awkward and the `by rfl` proof is suspicious.

**Location:** `/Users/Shared/Projects/lean-workspace/util/conduit/Conduit/Select/Types.lean` (lines 39, 45)

**Action Required:**
- Investigate if the cast is actually needed
- If Channel is truly a phantom type, consider using `unsafeCast` with documentation
- Or restructure to avoid the cast entirely

**Estimated Effort:** Small

---

### [Priority: Medium] Add Documentation Comments

**Issue:** Many public functions lack documentation strings.

**Location:** Multiple files

**Action Required:**
- Add doc strings to all public functions in `Conduit/Channel/Combinators.lean`
- Add doc strings to select DSL functions in `Conduit/Select/DSL.lean`
- Document the `SelectM` monad

**Estimated Effort:** Small

---

### [Priority: Medium] Expand Test Coverage

**Issue:** Tests are limited to basic functionality. Missing tests for:
- Concurrent send/recv with multiple tasks
- Select with send cases
- Map/filter/merge combinators with actual data transformation
- Edge cases (empty arrays, capacity 1, etc.)
- Stress tests for race conditions

**Location:** `/Users/Shared/Projects/lean-workspace/util/conduit/ConduitTests/`

**Action Required:**
- Add concurrency tests using IO.asTask
- Add tests for the map/filter combinators
- Add edge case tests
- Consider property-based testing with plausible

**Estimated Effort:** Medium

---

### [Priority: Low] Consistent Naming for Result Types

**Issue:** `SendResult` uses simple naming but `TryResult` is generic. Consider consistency.

**Location:** `/Users/Shared/Projects/lean-workspace/util/conduit/Conduit/Core/Types.lean`

**Action Required:**
- Consider renaming `SendResult` to `SendStatus` to differentiate from value-carrying results
- Or add type alias `TrySendResult := TryResult Unit`

**Estimated Effort:** Small

---

### [Priority: Low] Add Inline Pragmas for Performance

**Issue:** Small helper functions could benefit from inlining.

**Location:**
- `/Users/Shared/Projects/lean-workspace/util/conduit/Conduit/Core/Types.lean`
- `/Users/Shared/Projects/lean-workspace/util/conduit/Conduit/Select/Types.lean`

**Action Required:**
- Add `@[inline]` to `SendResult.isOk`, `SendResult.isClosed`
- Add `@[inline]` to `TryResult.isOk`, `TryResult.isEmpty`, etc.
- Add `@[inline]` to `Builder.addRecv`, `Builder.addSend`

**Estimated Effort:** Small

---

### [Priority: Low] SelectM Could Derive LawfulMonad

**Issue:** The `SelectM` monad has manual instances but no proofs of laws.

**Location:** `/Users/Shared/Projects/lean-workspace/util/conduit/Conduit/Select/DSL.lean`

**Action Required:**
- Consider if LawfulMonad/LawfulApplicative instances are needed
- The current implementation appears correct but could benefit from verification

**Estimated Effort:** Small

---

### [Priority: Low] Add README.md

**Issue:** No README file in the project root.

**Location:** `/Users/Shared/Projects/lean-workspace/util/conduit/`

**Action Required:**
- Create README.md with:
  - Quick start examples
  - API overview
  - Build instructions
  - Link to CLAUDE.md for detailed docs

**Estimated Effort:** Small

---

## Architecture Considerations

### Select Value Retrieval

The current select implementation only returns the index of the ready channel. To actually receive the value, you must call `recv` separately, which could be racy. Consider a design where select returns both the index and the value.

### Task Handle Management

The `map`, `filter`, and `merge` combinators spawn background tasks but discard the task handles. Consider:
- Returning the task handle for cancellation
- Or providing a way to await completion
- Or documenting the lifecycle clearly

### Cross-Platform Support

The FFI uses POSIX pthreads. For Windows support:
- Consider using C11 threads or
- Add Windows-specific implementations with CRITICAL_SECTION and CONDITION_VARIABLE

---

## Summary

| Category | Completed | Medium Priority | Low Priority |
|----------|-----------|-----------------|--------------|
| Features | 6 | 0 | 4 |
| Improvements | 5 | 0 | 2 |
| Cleanup | 0 | 3 | 4 |

**Completed:**
- ✅ Proper Select Wait with Condition Variables
- ✅ Unbuffered Channel trySend
- ✅ Fix Select Send Readiness for Unbuffered Channels
- ✅ TrySendResult Type (distinguishes full vs closed)
- ✅ Timeout Variants (sendTimeout, recvTimeout)
- ✅ Channel ForIn Instance
- ✅ pthread_cond_timedwait for Select
- ✅ Functor/Monad instances for TryResult
- ✅ Buffered output channels for combinators
- ✅ Broadcast Channels (fan-out with static and dynamic subscription)
- ✅ Pipeline Combinator (`|>>` for map, `|>?` for filter)

**Recommended Next Steps:**
1. Add Worker Pool pattern for parallel processing
2. Expand test coverage for concurrency scenarios
3. Add Batch Receive for bulk processing
