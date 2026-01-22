/-
  ConduitTests.SelectAdvancedTests

  Tests for select with send cases, timeouts, and Builder utilities.
-/

import Conduit
import Crucible

namespace ConduitTests.SelectAdvancedTests

open Crucible
open Conduit

testSuite "Select with sendCase"

test "poll with sendCase on buffered with space returns ready" := do
  let ch ← Channel.newBuffered Nat 3
  let result ← selectPoll do
    sendCase ch 42
  result ≡? 0

test "poll with sendCase on full buffered returns none" := do
  let ch ← Channel.newBuffered Nat 1
  let _ ← ch.send 1  -- Fill the buffer
  let result ← selectPoll do
    sendCase ch 42
  shouldBeNone result

test "poll with sendCase on closed channel returns none" := do
  -- Closed channels are NOT ready for send (can't send to closed channel)
  let ch ← Channel.newBuffered Nat 3
  ch.close
  let result ← selectPoll do
    sendCase ch 42
  shouldBeNone result

test "poll with mixed recv and send cases" := do
  let recvCh ← Channel.newBuffered Nat 3
  let sendCh ← Channel.newBuffered Nat 3
  -- Only sendCh has space, recvCh is empty
  let result ← selectPoll do
    recvCase recvCh
    sendCase sendCh 42
  result ≡? 1

test "poll prefers first ready case" := do
  let ch1 ← Channel.newBuffered Nat 3
  let ch2 ← Channel.newBuffered Nat 3
  -- Both have space for send
  let result ← selectPoll do
    sendCase ch1 1
    sendCase ch2 2
  result ≡? 0

test "poll with sendCase on unbuffered with no receiver returns none" := do
  let ch ← Channel.new Nat
  let result ← selectPoll do
    sendCase ch 42
  shouldBeNone result

test "poll with sendCase on unbuffered with waiting receiver returns ready" := do
  let ch ← Channel.new Nat
  -- Spawn receiver first - it will block waiting for data
  let receiver ← IO.asTask (prio := .dedicated) ch.recv
  -- Small delay to ensure receiver is blocked
  IO.sleep 10
  -- Now poll should detect the channel is ready for send
  let result ← selectPoll do
    sendCase ch 42
  result ≡? 0
  -- Clean up: close channel so receiver wakes up
  ch.close
  let _ ← IO.wait receiver

testSuite "selectTimeout"

test "selectTimeout returns none when timeout expires" := do
  let ch ← Channel.newBuffered Nat 3
  -- No data, so recv would block
  let result ← selectTimeout (recvCase ch) 10
  shouldBeNone result

test "selectTimeout returns index when channel ready before timeout" := do
  let ch ← Channel.newBuffered Nat 3
  let _ ← ch.send 42
  let result ← selectTimeout (recvCase ch) 1000
  result ≡? 0

test "selectTimeout with send case on channel with space" := do
  let ch ← Channel.newBuffered Nat 3
  let result ← selectTimeout (sendCase ch 42) 1000
  result ≡? 0

test "selectTimeout with multiple cases returns first ready" := do
  let ch1 ← Channel.newBuffered Nat 3
  let ch2 ← Channel.newBuffered Nat 3
  let _ ← ch2.send 99  -- Only ch2 has data
  let result ← selectTimeout (do recvCase ch1; recvCase ch2) 100
  result ≡? 1

testSuite "Select.Builder"

test "Builder.empty has size 0" := do
  let b := Select.Builder.empty
  b.size ≡ 0

test "Builder.isEmpty returns true for empty builder" := do
  let b := Select.Builder.empty
  b.isEmpty ≡ true

test "Builder.size returns correct count after addRecv" := do
  let ch1 ← Channel.new Nat
  let ch2 ← Channel.new Nat
  let b := Select.Builder.empty
    |>.addRecv ch1
    |>.addRecv ch2
  b.size ≡ 2

test "Builder.isEmpty returns false after adding case" := do
  let ch ← Channel.new Nat
  let b := Select.Builder.empty.addRecv ch
  b.isEmpty ≡ false

test "Builder.size counts send cases" := do
  let ch ← Channel.newBuffered Nat 3
  let b := Select.Builder.empty
    |>.addSend ch 1
    |>.addSend ch 2
  b.size ≡ 2

test "Builder.size counts mixed cases" := do
  let ch1 ← Channel.new Nat
  let ch2 ← Channel.newBuffered Nat 3
  let b := Select.Builder.empty
    |>.addRecv ch1
    |>.addSend ch2 42
    |>.addRecv ch1
  b.size ≡ 3

testSuite "selectWait (blocking)"

test "selectWait returns immediately when channel ready" := do
  let ch ← Channel.newBuffered Nat 1
  let _ ← ch.send 42
  let start ← IO.monoMsNow
  let result ← selectWait (recvCase ch)
  let elapsed ← IO.monoMsNow
  result ≡? 0
  -- Should complete almost instantly (< 50ms)
  if elapsed - start >= 50 then
    throw (IO.userError s!"Too slow: {elapsed - start}ms")

test "selectWait blocks until channel ready" := do
  let ch ← Channel.newBuffered Nat 1
  let start ← IO.monoMsNow
  -- Spawn task that sends after 50ms
  let _ ← IO.asTask (prio := .dedicated) do
    IO.sleep 50
    let _ ← ch.send 42
    pure ()
  let result ← selectWait (recvCase ch)
  let elapsed ← IO.monoMsNow
  result ≡? 0
  -- Should complete in ~50-150ms
  if elapsed - start < 40 then
    throw (IO.userError s!"Too fast: {elapsed - start}ms")
  if elapsed - start >= 300 then
    throw (IO.userError s!"Too slow: {elapsed - start}ms")

test "selectWait with multiple channels returns first ready" := do
  let ch1 ← Channel.newBuffered Nat 1
  let ch2 ← Channel.newBuffered Nat 1
  let _ ← IO.asTask (prio := .dedicated) do
    IO.sleep 30
    let _ ← ch2.send 99
    pure ()
  let result ← selectWait (do recvCase ch1; recvCase ch2)
  result ≡? 1  -- ch2 was ready first

test "selectWait wakes on channel close" := do
  let ch ← Channel.newBuffered Nat 1
  let _ ← IO.asTask (prio := .dedicated) do
    IO.sleep 30
    ch.close
    pure ()
  let result ← selectWait (recvCase ch)
  -- Closed channel is ready for recv (returns none)
  result ≡? 0

test "selectWait with send case blocks until space" := do
  let ch ← Channel.newBuffered Nat 1
  let _ ← ch.send 1  -- Fill buffer
  let start ← IO.monoMsNow
  -- Spawn task that receives after 50ms
  let _ ← IO.asTask (prio := .dedicated) do
    IO.sleep 50
    let _ ← ch.recv
    pure ()
  let result ← selectWait (sendCase ch 42)
  let elapsed ← IO.monoMsNow
  result ≡? 0
  -- Should complete in ~50-150ms
  if elapsed - start < 40 then
    throw (IO.userError s!"Too fast: {elapsed - start}ms")
  if elapsed - start >= 300 then
    throw (IO.userError s!"Too slow: {elapsed - start}ms")

testSuite "Select.withDefault"

test "withDefault returns index when case ready" := do
  let ch ← Channel.newBuffered Nat 1
  let _ ← ch.send 42
  let builder := Select.Builder.empty.addRecv ch
  let result ← Select.withDefault builder
  result ≡? 0

test "withDefault returns none when no case ready (default branch)" := do
  let ch ← Channel.newBuffered Nat 1
  -- Channel empty, recv would block
  let builder := Select.Builder.empty.addRecv ch
  let result ← Select.withDefault builder
  shouldBeNone result

test "withDefault with send case returns ready when space" := do
  let ch ← Channel.newBuffered Nat 3
  let builder := Select.Builder.empty.addSend ch 42
  let result ← Select.withDefault builder
  result ≡? 0

test "withDefault with send case returns none when full" := do
  let ch ← Channel.newBuffered Nat 1
  let _ ← ch.send 1  -- Fill buffer
  let builder := Select.Builder.empty.addSend ch 42
  let result ← Select.withDefault builder
  shouldBeNone result

test "withDefault with mixed cases returns first ready" := do
  let ch1 ← Channel.newBuffered Nat 1
  let ch2 ← Channel.newBuffered Nat 1
  let _ ← ch2.send 99  -- Only ch2 has data
  let builder := Select.Builder.empty.addRecv ch1 |>.addRecv ch2
  let result ← Select.withDefault builder
  result ≡? 1

testSuite "selectTimeout Immediate Wake-up"

test "selectTimeout wakes immediately when channel becomes ready" := do
  let ch ← Channel.newBuffered Nat 1
  let start ← IO.monoMsNow
  -- Spawn task that sends after 50ms
  let _ ← IO.asTask (prio := .dedicated) do
    IO.sleep 50
    let _ ← ch.send 42
    pure ()
  -- selectTimeout should wake at ~50ms, not poll at 1ms intervals
  let result ← selectTimeout (recvCase ch) 5000
  let elapsed ← IO.monoMsNow
  result ≡? 0
  -- Should complete in ~50-150ms (allowing for scheduling jitter)
  if elapsed - start < 40 then
    throw (IO.userError s!"Too fast: {elapsed - start}ms")
  if elapsed - start >= 300 then
    throw (IO.userError s!"Too slow: {elapsed - start}ms")

test "selectTimeout with multiple channels wakes on first ready" := do
  let ch1 ← Channel.newBuffered Nat 1
  let ch2 ← Channel.newBuffered Nat 1
  let start ← IO.monoMsNow
  let _ ← IO.asTask (prio := .dedicated) do
    IO.sleep 30
    let _ ← ch2.send 99
    pure ()
  let result ← selectTimeout (do recvCase ch1; recvCase ch2) 5000
  let elapsed ← IO.monoMsNow
  result ≡? 1  -- ch2 was ready first
  -- Should complete in ~30-150ms
  if elapsed - start < 20 then
    throw (IO.userError s!"Too fast: {elapsed - start}ms")
  if elapsed - start >= 300 then
    throw (IO.userError s!"Too slow: {elapsed - start}ms")

test "selectTimeout returns immediately if already ready" := do
  let ch ← Channel.newBuffered Nat 1
  let _ ← ch.send 42
  let start ← IO.monoMsNow
  let result ← selectTimeout (recvCase ch) 5000
  let elapsed ← IO.monoMsNow
  result ≡? 0
  -- Should complete almost instantly (< 50ms)
  if elapsed - start >= 50 then
    throw (IO.userError s!"Too slow: {elapsed - start}ms")

test "selectTimeout respects timeout" := do
  let ch ← Channel.newBuffered Nat 1
  let start ← IO.monoMsNow
  let result ← selectTimeout (recvCase ch) 100  -- 100ms timeout
  let elapsed ← IO.monoMsNow
  shouldBeNone result
  -- Should timeout around 100ms (within 50-200ms range)
  if elapsed - start < 80 then
    throw (IO.userError s!"Timeout too fast: {elapsed - start}ms")
  if elapsed - start >= 300 then
    throw (IO.userError s!"Timeout too slow: {elapsed - start}ms")



end ConduitTests.SelectAdvancedTests
