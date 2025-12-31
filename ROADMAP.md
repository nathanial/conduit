# Conduit Roadmap

This document tracks potential improvements, new features, and code cleanup opportunities for the Conduit library (Go-style typed channels for Lean 4).

---

## Feature Proposals

### [Priority: High] Proper Select Wait Implementation with Condition Variables

**Description:** Replace the current polling-based select wait with proper condition variable signaling. The current implementation in `conduit_select_wait` polls at 1ms intervals, which is inefficient and introduces latency.

**Rationale:**
- Current polling wastes CPU cycles
- 1ms minimum latency is unacceptable for low-latency applications
- Go's select uses proper waiting on channel condition variables

**Affected Files:**
- `/Users/Shared/Projects/lean-workspace/util/conduit/native/src/conduit_ffi.c` (lines 619-683)

**Proposed Change:**
- Create a shared condition variable for select operations
- Have channels signal this condition when they become ready
- Register select waiters on each channel being monitored

**Estimated Effort:** Large

**Dependencies:** None

---

### [COMPLETED] Unbuffered Channel trySend Implementation

**Status:** ✅ Implemented

**Solution:**
- Added `waiting_receivers` counter to channel structure
- Receivers increment counter before `pthread_cond_wait`, decrement after
- `trySend` checks `waiting_receivers > 0 && !pending_ready` to determine readiness
- When ready, performs immediate handoff with waiting receiver

---

### [Priority: Medium] Timeout Variants for Blocking Operations

**Description:** Add timeout versions of `send` and `recv` operations.

**Rationale:**
- Prevents indefinite blocking
- Essential for robust concurrent programming
- Matches Go's `select` with timeout pattern

**Affected Files:**
- `/Users/Shared/Projects/lean-workspace/util/conduit/Conduit/Channel.lean`
- `/Users/Shared/Projects/lean-workspace/util/conduit/native/src/conduit_ffi.c`

**Proposed API:**
```lean
opaque sendTimeout (ch : Channel α) (value : α) (timeoutMs : Nat) : IO (Option Bool)
opaque recvTimeout (ch : Channel α) (timeoutMs : Nat) : IO (Option (Option α))
```

**Estimated Effort:** Medium

**Dependencies:** None

---

### [Priority: Medium] Broadcast Channels (Fan-out)

**Description:** Add a broadcast channel type where multiple receivers each get a copy of every sent value.

**Rationale:**
- Common pattern for event distribution
- Useful for pub/sub scenarios
- Would complement existing merge (fan-in) combinator

**Affected Files:**
- New file: `/Users/Shared/Projects/lean-workspace/util/conduit/Conduit/Broadcast.lean`
- `/Users/Shared/Projects/lean-workspace/util/conduit/native/src/conduit_ffi.c`

**Estimated Effort:** Large

**Dependencies:** None

---

### [Priority: Medium] Channel Range/Iterator Protocol

**Description:** Add Lean 4 `ForIn` instance for channels to enable `for` loop iteration.

**Rationale:**
- More idiomatic Lean code
- Cleaner than explicit `forEach` calls
- Matches Go's `range` over channels

**Affected Files:**
- `/Users/Shared/Projects/lean-workspace/util/conduit/Conduit/Channel/Combinators.lean`

**Proposed API:**
```lean
instance : ForIn IO (Channel α) α where
  forIn ch init f := ...
```

**Estimated Effort:** Small

**Dependencies:** None

---

### [Priority: Medium] Pipeline Combinator

**Description:** Add a pipeline combinator for chaining channel transformations.

**Rationale:**
- Cleaner composition of map/filter/etc
- Avoids deep nesting of combinator calls
- Common pattern in stream processing

**Affected Files:**
- `/Users/Shared/Projects/lean-workspace/util/conduit/Conduit/Channel/Combinators.lean`

**Proposed API:**
```lean
def pipeline (ch : Channel α) (stages : List (Channel α → IO (Channel β))) : IO (Channel β)
-- Or operator syntax:
def (|>>) (ch : Channel α) (f : α → β) : IO (Channel β) := ch.map f
```

**Estimated Effort:** Small

**Dependencies:** None

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

### [Priority: Medium] Add TrySendResult Type for Better trySend Semantics

**Current State:** The `trySend` function returns `SendResult` which only has `ok` and `closed`, but the FFI returns three states: ok (0), would_block (1), and closed (2). The current Lean code conflates would_block with closed.

**Proposed Change:**
```lean
inductive TrySendResult where
  | ok       -- Successfully sent
  | full     -- Buffer full, would block
  | closed   -- Channel is closed
```

**Benefits:**
- Accurate representation of non-blocking send results
- Allows caller to distinguish between full buffer and closed channel
- Matches the FFI behavior

**Affected Files:**
- `/Users/Shared/Projects/lean-workspace/util/conduit/Conduit/Core/Types.lean`
- `/Users/Shared/Projects/lean-workspace/util/conduit/Conduit/Channel.lean` (lines 38-43)

**Estimated Effort:** Small

---

### [Priority: Medium] Use pthread_cond_timedwait for Select Timeout

**Current State:** The select wait with timeout uses a sleep-poll loop (lines 672-678 in conduit_ffi.c).

**Proposed Change:**
- Use `pthread_cond_timedwait` for more efficient waiting
- This requires the proper select implementation mentioned above

**Benefits:**
- More CPU-efficient waiting
- Lower latency responses
- Standard pthread pattern

**Affected Files:**
- `/Users/Shared/Projects/lean-workspace/util/conduit/native/src/conduit_ffi.c` (lines 629-683)

**Estimated Effort:** Medium

**Dependencies:** Proper Select Wait Implementation

---

### [Priority: Medium] Add Functor/Monad Instances for TryResult

**Current State:** `TryResult` has a `map` function but no typeclass instances.

**Proposed Change:**
```lean
instance : Functor TryResult where
  map := TryResult.map

instance : Applicative TryResult where
  pure := TryResult.ok
  seq f x := match f with
    | .ok f' => TryResult.map f' (x ())
    | .empty => .empty
    | .closed => .closed

instance : Monad TryResult where
  bind ma f := match ma with
    | .ok a => f a
    | .empty => .empty
    | .closed => .closed
```

**Benefits:**
- More idiomatic Lean code
- Enables do-notation for chained tryRecv operations
- Better composability

**Affected Files:**
- `/Users/Shared/Projects/lean-workspace/util/conduit/Conduit/Core/Types.lean`

**Estimated Effort:** Small

---

### [Priority: Medium] Make Combinators Use Buffered Output Channels

**Current State:** The `map`, `filter`, and `merge` combinators create unbuffered output channels.

**Proposed Change:**
- Use buffered output channels for better throughput
- Optionally accept buffer size parameter

**Benefits:**
- Better performance when producer is faster than consumer
- Reduces blocking in transformation pipelines

**Affected Files:**
- `/Users/Shared/Projects/lean-workspace/util/conduit/Conduit/Channel/Combinators.lean` (lines 65-101)

**Estimated Effort:** Small

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

| Category | High Priority | Medium Priority | Low Priority |
|----------|---------------|-----------------|--------------|
| Features | 2 | 4 | 4 |
| Improvements | 1 | 4 | 2 |
| Cleanup | 0 | 3 | 4 |

**Recommended Next Steps:**
1. Fix the select send case readiness for unbuffered channels
2. Implement proper condition variable-based select wait
3. Add `TrySendResult` type for accurate non-blocking send semantics
4. Expand test coverage for concurrency scenarios
