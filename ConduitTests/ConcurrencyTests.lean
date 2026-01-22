/-
  ConduitTests.ConcurrencyTests

  Tests for concurrent channel operations using IO.asTask.
-/

import Conduit
import Crucible

namespace ConduitTests.ConcurrencyTests

open Crucible
open Conduit

testSuite "Concurrent Unbuffered"

test "concurrent send and recv on unbuffered channel complete" := do
  let ch ← Channel.new Nat
  -- Sender task
  let sender ← IO.asTask (prio := .dedicated) do
    let _ ← ch.send 42
    pure ()
  -- Receive on main thread
  let v ← ch.recv
  let _ ← IO.wait sender
  v ≡? 42

test "concurrent unbuffered sends deliver all values" := do
  let ch ← Channel.new Nat
  let sender1 ← IO.asTask (prio := .dedicated) do
    let _ ← ch.send 1
  let sender2 ← IO.asTask (prio := .dedicated) do
    let _ ← ch.send 2
  -- Give both senders time to block on the unbuffered channel
  IO.sleep 10
  let r1 ← ch.recvTimeout 500
  let r2 ← ch.recvTimeout 500
  let mut received : Array Nat := #[]
  for r in [r1, r2] do
    match r with
    | some (some v) => received := received.push v
    | _ => pure ()
  if received.size != 2 then
    ch.close
    let _ ← IO.wait sender1 >>= IO.ofExcept
    let _ ← IO.wait sender2 >>= IO.ofExcept
    throw (IO.userError s!"Expected 2 values, got {received.size}")
  let _ ← IO.wait sender1 >>= IO.ofExcept
  let _ ← IO.wait sender2 >>= IO.ofExcept
  ch.close
  shouldContain received.toList 1
  shouldContain received.toList 2

test "multiple sequential sends with concurrent receiver" := do
  -- Test unbuffered channel with dedicated threads
  let ch ← Channel.new Nat
  let results ← IO.mkRef #[]
  -- Spawn receiver first on dedicated thread - it will block waiting for values
  let receiver ← IO.asTask (prio := .dedicated) do
    ch.forEach fun v => results.modify (·.push v)
  -- Small delay to ensure receiver task is scheduled and blocking on recv
  IO.sleep 5
  -- Now send values - each send will synchronize with receiver
  let _ ← ch.send 1
  let _ ← ch.send 2
  let _ ← ch.send 3
  ch.close
  let _ ← IO.wait receiver
  let arr ← results.get
  arr ≡ #[1, 2, 3]

testSuite "Concurrent Buffered"

test "multiple senders to buffered channel all succeed" := do
  let ch ← Channel.newBuffered Nat 10
  -- Spawn 3 sender tasks
  let t1 ← IO.asTask (prio := .dedicated) do
    for i in [0:3] do
      let _ ← ch.send (i + 1)
  let t2 ← IO.asTask (prio := .dedicated) do
    for i in [0:3] do
      let _ ← ch.send (i + 10)
  let t3 ← IO.asTask (prio := .dedicated) do
    for i in [0:3] do
      let _ ← ch.send (i + 100)
  -- Wait for all senders
  let _ ← IO.wait t1
  let _ ← IO.wait t2
  let _ ← IO.wait t3
  ch.close
  -- Drain and check count
  let results ← ch.drain
  shouldHaveLength results.toList 9

test "multiple receivers from buffered channel each get unique value" := do
  let ch ← Channel.newBuffered Nat 5
  -- Fill the channel
  for i in [1:6] do
    let _ ← ch.send i
  ch.close
  -- Spawn receivers
  let r1 ← IO.asTask (prio := .dedicated) (ch.drain)
  let r2 ← IO.asTask (prio := .dedicated) (ch.drain)
  let res1 ← IO.wait r1
  let res2 ← IO.wait r2
  -- Extract arrays from Except results
  let arr1 ← IO.ofExcept res1
  let arr2 ← IO.ofExcept res2
  -- Combined results should have all 5 values, no duplicates
  let combined := arr1.toList ++ arr2.toList
  combined.length ≡ 5
  shouldContain combined 1
  shouldContain combined 2
  shouldContain combined 3
  shouldContain combined 4
  shouldContain combined 5

testSuite "Producer-Consumer Patterns"

test "producer-consumer with map combinator" := do
  let input ← Channel.newBuffered Nat 5
  let output ← input.map (· * 2)
  -- Producer task
  let producer ← IO.asTask (prio := .dedicated) do
    for i in [1:4] do
      let _ ← input.send i
    input.close
  -- Consume results
  let results ← output.drain
  let _ ← IO.wait producer
  -- Values should be doubled
  shouldContain results.toList 2
  shouldContain results.toList 4
  shouldContain results.toList 6

test "chained map operations" := do
  let input ← Channel.fromArray #[1, 2, 3]
  let step1 ← input.map (· + 10)
  let step2 ← step1.map (· * 2)
  let results ← step2.drain
  results ≡ #[22, 24, 26]

test "filter then map pipeline" := do
  let input ← Channel.fromArray #[1, 2, 3, 4, 5, 6]
  let evens ← input.filter (· % 2 == 0)
  let doubled ← evens.map (· * 2)
  let results ← doubled.drain
  results ≡ #[4, 8, 12]

testSuite "Merge Concurrency"

test "merge with concurrent producers" := do
  let ch1 ← Channel.newBuffered Nat 5
  let ch2 ← Channel.newBuffered Nat 5
  let merged ← Channel.merge #[ch1, ch2]
  -- Producer tasks
  let p1 ← IO.asTask (prio := .dedicated) do
    for i in [1:4] do
      let _ ← ch1.send i
    ch1.close
  let p2 ← IO.asTask (prio := .dedicated) do
    for i in [10:13] do
      let _ ← ch2.send i
    ch2.close
  -- Consume merged
  let results ← merged.drain
  let _ ← IO.wait p1
  let _ ← IO.wait p2
  -- Should have all 6 values
  shouldHaveLength results.toList 6
  shouldContain results.toList 1
  shouldContain results.toList 2
  shouldContain results.toList 3
  shouldContain results.toList 10
  shouldContain results.toList 11
  shouldContain results.toList 12

testSuite "Close Behavior"

test "close wakes blocked sender" := do
  let ch ← Channel.new Nat
  let sendResult ← IO.mkRef true
  -- Sender will block on unbuffered channel
  let sender ← IO.asTask (prio := .dedicated) do
    let r ← ch.send 42
    sendResult.set r
  -- Give sender time to block
  IO.sleep 10
  -- Close should wake the sender
  ch.close
  let _ ← IO.wait sender
  let r ← sendResult.get
  r ≡ false  -- Send should return false on closed channel

test "close wakes blocked receiver" := do
  let ch ← Channel.new Nat
  let recvResult ← IO.mkRef (some 999)
  -- Receiver will block
  let receiver ← IO.asTask (prio := .dedicated) do
    let r ← ch.recv
    recvResult.set r
  -- Give receiver time to block
  IO.sleep 10
  -- Close should wake the receiver
  ch.close
  let _ ← IO.wait receiver
  let r ← recvResult.get
  shouldBeNone r

testSuite "Race Conditions"

test "close while send blocked on full buffer" := do
  let ch ← Channel.newBuffered Nat 1
  let _ ← ch.send 1  -- Fill the buffer
  let sendResult ← IO.mkRef true
  -- Sender will block because buffer is full
  let sender ← IO.asTask (prio := .dedicated) do
    let r ← ch.send 2
    sendResult.set r
  -- Give sender time to block
  IO.sleep 20
  -- Close should wake the blocked sender
  ch.close
  let _ ← IO.wait sender
  let r ← sendResult.get
  r ≡ false  -- Send should return false on closed channel

test "close while recv blocked on empty buffered" := do
  let ch ← Channel.newBuffered Nat 5
  -- Channel is empty, recv will block
  let recvResult ← IO.mkRef (some 999)
  let receiver ← IO.asTask (prio := .dedicated) do
    let r ← ch.recv
    recvResult.set r
  -- Give receiver time to block
  IO.sleep 20
  -- Close should wake the blocked receiver
  ch.close
  let _ ← IO.wait receiver
  let r ← recvResult.get
  shouldBeNone r

test "concurrent close from multiple tasks" := do
  let ch ← Channel.newBuffered Nat 10
  let _ ← ch.send 1
  let _ ← ch.send 2
  -- Spawn multiple tasks that all try to close
  let t1 ← IO.asTask (prio := .dedicated) ch.close
  let t2 ← IO.asTask (prio := .dedicated) ch.close
  let t3 ← IO.asTask (prio := .dedicated) ch.close
  -- All should complete without error
  let _ ← IO.wait t1
  let _ ← IO.wait t2
  let _ ← IO.wait t3
  -- Channel should be closed
  let closed ← ch.isClosed
  closed ≡ true
  -- Should still be able to drain remaining values
  let arr ← ch.drain
  arr ≡ #[1, 2]

test "select waiting when channel closes" := do
  let ch1 ← Channel.newBuffered Nat 1
  let ch2 ← Channel.newBuffered Nat 1
  -- Both channels empty, select will block
  let selectResult ← IO.mkRef (some 999 : Option Nat)
  let waiter ← IO.asTask (prio := .dedicated) do
    let r ← selectWait do
      recvCase ch1
      recvCase ch2
    selectResult.set r
  -- Give select time to block
  IO.sleep 20
  -- Close ch2 - should wake the select
  ch2.close
  let _ ← IO.wait waiter
  let r ← selectResult.get
  -- ch2 (index 1) should be ready because it's closed
  r ≡? 1

test "select with send case when channel closes" := do
  let ch ← Channel.newBuffered Nat 1
  let _ ← ch.send 1  -- Fill buffer
  -- Send case will block because buffer is full
  let selectResult ← IO.mkRef (some 999 : Option Nat)
  let waiter ← IO.asTask (prio := .dedicated) do
    let r ← selectWait (sendCase ch 2)
    selectResult.set r
  -- Give select time to block
  IO.sleep 20
  -- Close channel - should wake the select
  ch.close
  let _ ← IO.wait waiter
  -- Select should return (closed channels are "ready" for the purpose of waking)
  let _ ← selectResult.get
  -- Result depends on implementation - either none or index 0
  -- The important thing is it doesn't hang
  pure ()

test "multiple concurrent drains on same channel" := do
  let ch ← Channel.newBuffered Nat 100
  -- Fill with values
  for i in [:50] do
    let _ ← ch.send i
  ch.close
  -- Spawn multiple concurrent drains
  let d1 ← IO.asTask (prio := .dedicated) ch.drain
  let d2 ← IO.asTask (prio := .dedicated) ch.drain
  let d3 ← IO.asTask (prio := .dedicated) ch.drain
  let arr1 ← IO.wait d1 >>= IO.ofExcept
  let arr2 ← IO.wait d2 >>= IO.ofExcept
  let arr3 ← IO.wait d3 >>= IO.ofExcept
  -- Combined should have exactly 50 unique values, no duplicates
  let combined := arr1.toList ++ arr2.toList ++ arr3.toList
  combined.length ≡ 50
  -- Check no value appears more than once
  let sorted := combined.toArray.qsort (· < ·)
  for i in [:50] do
    sorted[i]! ≡ i

test "close during active forEach iteration" := do
  let ch ← Channel.newBuffered Nat 10
  -- Add some values
  for i in [:5] do
    let _ ← ch.send i
  let count ← IO.mkRef 0
  let completed ← IO.mkRef false
  -- Start forEach iteration
  let iterator ← IO.asTask (prio := .dedicated) do
    ch.forEach fun _ => do
      count.modify (· + 1)
      IO.sleep 10  -- Slow processing to give time for close
    completed.set true
  -- Give iterator time to start processing
  IO.sleep 30
  -- Close channel while forEach is running
  ch.close
  -- Wait for forEach to complete
  let _ ← IO.wait iterator
  let done ← completed.get
  done ≡ true
  -- Should have processed some values (at least 1, maybe all 5)
  let n ← count.get
  if n < 1 then
    throw (IO.userError s!"Expected at least 1 value processed, got {n}")

test "concurrent send and close race" := do
  let ch ← Channel.newBuffered Nat 10
  let sendResults ← IO.mkRef #[]
  -- Spawn multiple senders
  let senders ← (List.range 5).mapM fun i =>
    IO.asTask (prio := .dedicated) do
      let r ← ch.send i
      sendResults.modify (·.push r)
  -- Simultaneously close
  let closer ← IO.asTask (prio := .dedicated) do
    IO.sleep 5  -- Small delay
    ch.close
  -- Wait for all
  for s in senders do
    let _ ← IO.wait s
  let _ ← IO.wait closer
  -- Some sends may succeed (true), some may fail (false after close)
  let results ← sendResults.get
  results.size ≡ 5
  -- Channel should be closed
  let closed ← ch.isClosed
  closed ≡ true

test "concurrent recv and close race" := do
  let ch ← Channel.newBuffered Nat 10
  -- Add some values
  for i in [:3] do
    let _ ← ch.send i
  let recvResults ← IO.mkRef #[]
  -- Spawn multiple receivers
  let receivers ← (List.range 5).mapM fun _ =>
    IO.asTask (prio := .dedicated) do
      let r ← ch.recv
      recvResults.modify (·.push r)
  -- Simultaneously close
  let closer ← IO.asTask (prio := .dedicated) do
    IO.sleep 5
    ch.close
  -- Wait for all
  for r in receivers do
    let _ ← IO.wait r
  let _ ← IO.wait closer
  -- Should have received values + nones
  let results ← recvResults.get
  results.size ≡ 5
  -- Count successful recvs (should be at most 3, the number of values)
  let successes := results.filter Option.isSome
  if successes.size > 3 then
    throw (IO.userError s!"Too many successful recvs: {successes.size}")

test "rapid send-recv-close cycle" := do
  -- Stress test: rapid cycles of send/recv/close on fresh channels
  for _ in [:20] do
    let ch ← Channel.newBuffered Nat 5
    let sender ← IO.asTask (prio := .dedicated) do
      for i in [:3] do
        let _ ← ch.send i
    let receiver ← IO.asTask (prio := .dedicated) do
      let _ ← ch.recv
      let _ ← ch.recv
    IO.sleep 5
    ch.close
    let _ ← IO.wait sender
    let _ ← IO.wait receiver
  -- If we get here without hanging or crashing, test passes
  pure ()



end ConduitTests.ConcurrencyTests
