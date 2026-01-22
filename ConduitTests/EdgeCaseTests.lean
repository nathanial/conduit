/-
  ConduitTests.EdgeCaseTests

  Tests for edge cases and stress scenarios.
-/

import Conduit
import Crucible

namespace ConduitTests.EdgeCaseTests

open Crucible
open Conduit

testSuite "Edge Cases"

testSuite "Capacity 1 Channels"

test "capacity 1 channel behaves like bounded buffer" := do
  let ch ← Channel.newBuffered Nat 1
  -- First send should succeed immediately
  let r1 ← ch.trySend 42
  r1.isOk ≡ true
  -- Second send should fail (buffer full)
  let r2 ← ch.trySend 99
  r2.isFull ≡ true
  -- Receive should work
  let v ← ch.recv
  v ≡? 42
  -- Now buffer has space
  let r3 ← ch.trySend 99
  r3.isOk ≡ true
  let v2 ← ch.recv
  v2 ≡? 99

test "capacity 1 closes correctly" := do
  let ch ← Channel.newBuffered Nat 1
  let _ ← ch.send 42
  ch.close
  let v ← ch.recv
  v ≡? 42
  let v2 ← ch.recv
  shouldBeNone v2

testSuite "Empty Array/List Edge Cases"

test "fromArray with empty array creates closed empty channel" := do
  let ch ← Channel.fromArray (#[] : Array Nat)
  let closed ← ch.isClosed
  closed ≡ true
  let v ← ch.recv
  shouldBeNone v

test "fromList with empty list creates closed empty channel" := do
  let ch ← Channel.fromList ([] : List Nat)
  let closed ← ch.isClosed
  closed ≡ true
  let v ← ch.recv
  shouldBeNone v

test "drain on already-drained channel returns empty" := do
  let ch ← Channel.fromArray #[1, 2, 3]
  let arr1 ← ch.drain
  arr1 ≡ #[1, 2, 3]
  let arr2 ← ch.drain
  arr2 ≡ #[]

test "merge with empty array creates closed channel" := do
  let ch ← Channel.merge (#[] : Array (Channel Nat))
  let closed ← ch.isClosed
  closed ≡ true
  let v ← ch.recv
  shouldBeNone v

testSuite "Rapid Open/Close Cycles"

test "rapid close after create" := do
  for _ in [:10] do
    let ch ← Channel.new Nat
    ch.close
    let closed ← ch.isClosed
    closed ≡ true

test "rapid close on buffered channel" := do
  for _ in [:10] do
    let ch ← Channel.newBuffered Nat 5
    let _ ← ch.send 1
    let _ ← ch.send 2
    ch.close
    let arr ← ch.drain
    arr ≡ #[1, 2]

testSuite "Stress Tests"

test "100 sends to buffered channel" := do
  let ch ← Channel.newBuffered Nat 100
  for i in [:100] do
    let _ ← ch.send i
  ch.close  -- Must close before drain since drain waits for channel to close
  let arr ← ch.drain
  arr.size ≡ 100

test "many small sends and receives" := do
  let ch ← Channel.newBuffered Nat 10
  let mut sum := 0
  for i in [:50] do
    let _ ← ch.send i
    match ← ch.recv with
    | some v => sum := sum + v
    | none => throw (IO.userError "unexpected closed")
  sum ≡ 1225

test "close is idempotent" := do
  let ch ← Channel.newBuffered Nat 5
  ch.close
  ch.close
  ch.close
  let closed ← ch.isClosed
  closed ≡ true

testSuite "tryRecv/trySend Edge Cases"

test "tryRecv on empty unbuffered returns empty" := do
  let ch ← Channel.new Nat
  let r ← ch.tryRecv
  r.isEmpty ≡ true

test "tryRecv on closed empty returns closed" := do
  let ch ← Channel.new Nat
  ch.close
  let r ← ch.tryRecv
  r.isClosed ≡ true

test "trySend on closed returns closed" := do
  let ch ← Channel.new Nat
  ch.close
  let r ← ch.trySend 42
  r.isClosed ≡ true

test "trySend on full buffer returns full" := do
  let ch ← Channel.newBuffered Nat 2
  let _ ← ch.send 1
  let _ ← ch.send 2
  let r ← ch.trySend 3
  r.isFull ≡ true

testSuite "Channel Properties"

test "capacity returns correct value" := do
  let ch0 ← Channel.new Nat
  let cap0 ← ch0.capacity
  cap0 ≡ 0
  let ch10 ← Channel.newBuffered Nat 10
  let cap10 ← ch10.capacity
  cap10 ≡ 10

test "len reflects current buffer state" := do
  let ch ← Channel.newBuffered Nat 10
  let len0 ← ch.len
  len0 ≡ 0
  let _ ← ch.send 1
  let len1 ← ch.len
  len1 ≡ 1
  let _ ← ch.send 2
  let len2 ← ch.len
  len2 ≡ 2
  let _ ← ch.recv
  let len1' ← ch.len
  len1' ≡ 1



end ConduitTests.EdgeCaseTests
