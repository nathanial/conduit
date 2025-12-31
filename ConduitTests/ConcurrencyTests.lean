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

#generate_tests

end ConduitTests.ConcurrencyTests
