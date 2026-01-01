# Conduit Test Plan

## Current Coverage

**218 tests across 13 suites**

### Test Suites

| Suite | Tests | Description |
|-------|-------|-------------|
| ChannelTests | 11 | Basic channel operations |
| CombinatorTests | 35 | map, filter, merge, drain, forEach, pipe |
| SelectTests | 4 | Basic select/poll |
| TypeTests | 30 | SendResult, TryResult operations |
| TrySendTests | 12 | Non-blocking send, len |
| SelectAdvancedTests | 31 | Select with send cases, timeout, wait, withDefault |
| ConcurrencyTests | 20 | Concurrent operations, race conditions |
| TimeoutTests | 11 | sendTimeout, recvTimeout |
| BroadcastTests | 15 | Broadcast, Hub, subscriberCount |
| EdgeCaseTests | 17 | Edge cases |
| StressTests | 18 | High-volume, large buffers, sustained patterns |
| ResourceTests | 14 | Allocation tracking, finalizers, memory leak detection |

### Coverage by Area

| Area | Status | Notes |
|------|--------|-------|
| Basic ops (send/recv/close) | Complete | All operations tested |
| Combinators | Complete | map, filter, merge, drain, forEach, pipe, pipeFilter |
| TryResult/SendResult types | Complete | All type operations and instances |
| Select with timeout | Complete | poll, selectTimeout, selectWait, withDefault |
| Non-blocking ops | Complete | trySend, tryRecv |
| Timeout ops | Complete | sendTimeout, recvTimeout |
| Broadcast/Hub | Complete | Broadcast, Hub, subscriberCount |
| Basic concurrency | Complete | Producer-consumer, multiple senders/receivers, race conditions |
| Edge cases | Complete | Capacity 1, empty arrays, rapid close |
| Stress tests | Complete | High-volume, large buffers, sustained patterns |
| Resource management | Complete | Allocation tracking, finalizers, leak detection |

## Missing Coverage

### Untested API Functions

- [x] `Select.wait` - Blocking select without timeout *(added 5 tests)*
- [x] `Select.withDefault` - Select with default case (non-blocking) *(added 5 tests)*
- [x] `Hub.subscriberCount` - Get number of active subscribers *(added 3 tests)*

### Stress Tests Needed

- [x] High-volume concurrent producers (multiple tasks sending 1000+ values) *(added)*
- [x] High-volume concurrent consumers (multiple tasks receiving from one channel) *(added)*
- [x] Large buffer sizes (1000+ capacity) *(added: 1000, 5000, 10000)*
- [x] Many channels lifecycle (create/close 100+ channels rapidly) *(added: 100-200 channels)*
- [x] Sustained producer-consumer (running for several seconds) *(added: 500ms tests)*
- [x] Memory pressure (channels with large values) *(added: 1KB strings, 1000-element arrays)*

### Race Condition Tests Needed

- [x] Close while send is blocked on full buffer *(added)*
- [x] Close while recv is blocked on empty channel *(added)*
- [x] Concurrent close from multiple tasks *(added)*
- [x] Select waiting when channel closes *(added)*
- [x] Multiple concurrent drains on same channel *(added)*
- [x] Close during active forEach iteration *(added)*
- [x] Concurrent send and close race *(added)*
- [x] Concurrent recv and close race *(added)*
- [x] Rapid send-recv-close cycle *(added)*

### Resource Tests Needed

- [x] Channel with large values (big arrays/strings) *(added in StressTests)*
- [x] Channel finalizer works correctly *(added in ResourceTests - allocation tracking via atomic counters)*
- [x] No memory leaks under sustained load *(added in ResourceTests - leak detection tests)*

## Test Guidelines

### Using Dedicated Threads

Tests that block on channel operations should use dedicated threads:

```lean
test "blocking operation" := do
  let task ← IO.asTask (prio := .dedicated) do
    -- blocking code here
  IO.wait task
```

### Drain Requires Close

The `drain` function blocks until the channel is closed:

```lean
-- WRONG: hangs forever
let arr ← ch.drain

-- CORRECT: close first
ch.close
let arr ← ch.drain
```

### Timeout for Safety

Long-running tests should have timeouts to prevent hangs:

```lean
test "potentially slow test" (timeout := 10000) := do
  -- test code
```
