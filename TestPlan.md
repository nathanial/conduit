# Conduit Test Plan

## Current Coverage

**163 tests across 10 suites**

### Test Suites

| Suite | Tests | Description |
|-------|-------|-------------|
| ChannelTests | 11 | Basic channel operations |
| CombinatorTests | 35 | map, filter, merge, drain, forEach, pipe |
| SelectTests | 4 | Basic select/poll |
| TypeTests | 30 | SendResult, TryResult operations |
| TrySendTests | 12 | Non-blocking send, len |
| SelectAdvancedTests | 21 | Select with send cases, timeout |
| ConcurrencyTests | 10 | Concurrent operations |
| TimeoutTests | 11 | sendTimeout, recvTimeout |
| BroadcastTests | 12 | Broadcast and Hub |
| EdgeCaseTests | 17 | Edge cases, stress tests |

### Coverage by Area

| Area | Status | Notes |
|------|--------|-------|
| Basic ops (send/recv/close) | Complete | All operations tested |
| Combinators | Complete | map, filter, merge, drain, forEach, pipe, pipeFilter |
| TryResult/SendResult types | Complete | All type operations and instances |
| Select with timeout | Good | poll, selectTimeout tested |
| Non-blocking ops | Complete | trySend, tryRecv |
| Timeout ops | Complete | sendTimeout, recvTimeout |
| Broadcast/Hub | Good | Basic patterns covered |
| Basic concurrency | Moderate | Producer-consumer, multiple senders/receivers |
| Edge cases | Good | Capacity 1, empty arrays, rapid close |

## Missing Coverage

### Untested API Functions

- [ ] `Select.wait` - Blocking select without timeout
- [ ] `Select.withDefault` - Select with default case (non-blocking)
- [ ] `Hub.subscriberCount` - Get number of active subscribers

### Stress Tests Needed

- [ ] High-volume concurrent producers (multiple tasks sending 1000+ values)
- [ ] High-volume concurrent consumers (multiple tasks receiving from one channel)
- [ ] Large buffer sizes (1000+ capacity)
- [ ] Many channels lifecycle (create/close 100+ channels rapidly)
- [ ] Sustained producer-consumer (running for several seconds)
- [ ] Memory pressure (channels with large values)

### Race Condition Tests Needed

- [ ] Close while send is blocked on full buffer
- [ ] Close while recv is blocked on empty channel
- [ ] Concurrent close from multiple tasks
- [ ] Select waiting when channel closes
- [ ] Multiple concurrent drains on same channel
- [ ] Close during active forEach iteration

### Resource Tests Needed

- [ ] Channel with large values (big arrays/strings)
- [ ] Channel finalizer works correctly (channel GC'd without explicit close)
- [ ] No memory leaks under sustained load

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
