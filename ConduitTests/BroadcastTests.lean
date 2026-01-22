/-
  ConduitTests.BroadcastTests

  Tests for broadcast channel functionality.
-/

import Conduit
import Crucible

namespace ConduitTests.BroadcastTests

open Crucible
open Conduit

testSuite "Broadcast.create"

test "broadcast with zero subscribers returns empty array" := do
  let source ← Channel.newBuffered Nat 10
  let subs ← Broadcast.create source 0
  subs.size ≡ 0
  source.close

test "broadcast creates correct number of subscribers" := do
  let source ← Channel.newBuffered Nat 10
  let subs ← Broadcast.create source 3
  subs.size ≡ 3
  source.close

test "all subscribers receive sent values" := do
  let source ← Channel.newBuffered Nat 10
  let subs ← Broadcast.create source 3
  let _ ← source.send 42
  let _ ← source.send 99
  source.close
  IO.sleep 100
  -- Each subscriber should have both values
  for sub in subs do
    let v1 ← sub.recv
    let v2 ← sub.recv
    let v3 ← sub.recv
    v1 ≡? 42
    v2 ≡? 99
    shouldBeNone v3

test "subscribers close when source closes" := do
  let source ← Channel.newBuffered Nat 10
  let subs ← Broadcast.create source 2
  source.close
  IO.sleep 100
  for sub in subs do
    let v ← sub.recv
    shouldBeNone v

test "broadcast handles concurrent receivers" := do
  let source ← Channel.newBuffered Nat 10
  let subs ← Broadcast.create source 3
  -- Send values
  for i in [:5] do
    let _ ← source.send i
  source.close
  -- Spawn receivers that sum all values (use .dedicated for real threads)
  let tasks ← subs.mapM fun sub => IO.asTask (prio := .dedicated) do
    let mut sum := 0
    for v in sub do
      sum := sum + v
    pure sum
  -- All should sum to 0+1+2+3+4 = 10
  for task in tasks do
    let sum ← IO.wait task >>= IO.ofExcept
    sum ≡ 10

test "broadcast with single subscriber works" := do
  let source ← Channel.newBuffered String 10
  let subs ← Broadcast.create source 1
  subs.size ≡ 1
  let sub ← match subs[0]? with
    | some ch => pure ch
    | none => throw (IO.userError "expected subscriber")
  let _ ← source.send "hello"
  let _ ← source.send "world"
  source.close
  IO.sleep 100
  let v1 ← sub.recv
  let v2 ← sub.recv
  v1 ≡? "hello"
  v2 ≡? "world"

testSuite "Broadcast.Hub"

test "hub allows dynamic subscription" := do
  let source ← Channel.newBuffered Nat 10
  let h ← Broadcast.hub source
  let sub1 ← h.subscribe
  sub1.isSome ≡ true
  let sub2 ← h.subscribe
  sub2.isSome ≡ true
  let count ← h.subscriberCount
  count ≡ 2
  source.close

test "hub starts not closed" := do
  let source ← Channel.newBuffered Nat 10
  let h ← Broadcast.hub source
  let closed ← h.isClosed
  closed ≡ false
  source.close

test "hub subscribers receive values" := do
  let source ← Channel.newBuffered Nat 10
  let h ← Broadcast.hub source
  let sub1Opt ← h.subscribe
  let sub1 ← match sub1Opt with
    | some ch => pure ch
    | none => throw (IO.userError "subscribe failed")
  let _ ← source.send 42
  source.close
  IO.sleep 100
  let v ← sub1.recv
  v ≡? 42

test "hub late subscriber receives only future values" := do
  let source ← Channel.newBuffered Nat 10
  let h ← Broadcast.hub source
  -- Subscribe first subscriber
  let sub1Opt ← h.subscribe
  let sub1 ← match sub1Opt with
    | some ch => pure ch
    | none => throw (IO.userError "subscribe failed")
  -- Send first value and wait for it to be distributed
  let _ ← source.send 1
  IO.sleep 50
  -- Subscribe second subscriber after first value
  let sub2Opt ← h.subscribe
  let sub2 ← match sub2Opt with
    | some ch => pure ch
    | none => throw (IO.userError "subscribe failed")
  -- Send second value
  let _ ← source.send 2
  source.close
  IO.sleep 100
  -- sub1 gets both values
  let v1a ← sub1.recv
  let v1b ← sub1.recv
  v1a ≡? 1
  v1b ≡? 2
  -- sub2 only gets second value
  let v2 ← sub2.recv
  v2 ≡? 2

test "hub subscribe returns none after close" := do
  let source ← Channel.newBuffered Nat 10
  let h ← Broadcast.hub source
  source.close
  IO.sleep 100
  let closed ← h.isClosed
  closed ≡ true
  let result ← h.subscribe
  result.isNone ≡ true

test "hub closes all subscribers when source closes" := do
  let source ← Channel.newBuffered Nat 10
  let h ← Broadcast.hub source
  let sub1Opt ← h.subscribe
  let sub1 ← match sub1Opt with
    | some ch => pure ch
    | none => throw (IO.userError "subscribe failed")
  let sub2Opt ← h.subscribe
  let sub2 ← match sub2Opt with
    | some ch => pure ch
    | none => throw (IO.userError "subscribe failed")
  source.close
  IO.sleep 100
  let v1 ← sub1.recv
  let v2 ← sub2.recv
  shouldBeNone v1
  shouldBeNone v2

testSuite "Hub.subscriberCount"

test "subscriberCount starts at zero" := do
  let source ← Channel.newBuffered Nat 10
  let h ← Broadcast.hub source
  let count ← h.subscriberCount
  count ≡ 0
  source.close

test "subscriberCount increments on subscribe" := do
  let source ← Channel.newBuffered Nat 10
  let h ← Broadcast.hub source
  let _ ← h.subscribe
  let count1 ← h.subscriberCount
  count1 ≡ 1
  let _ ← h.subscribe
  let count2 ← h.subscriberCount
  count2 ≡ 2
  let _ ← h.subscribe
  let count3 ← h.subscriberCount
  count3 ≡ 3
  source.close

test "subscriberCount after source close" := do
  let source ← Channel.newBuffered Nat 10
  let h ← Broadcast.hub source
  let _ ← h.subscribe
  let _ ← h.subscribe
  let countBefore ← h.subscriberCount
  countBefore ≡ 2
  source.close
  IO.sleep 50
  -- Count may still be 2 (subscribers exist but are closed)
  let countAfter ← h.subscriberCount
  countAfter ≡ 2



end ConduitTests.BroadcastTests
