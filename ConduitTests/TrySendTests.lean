/-
  ConduitTests.TrySendTests

  Tests for non-blocking send operations.
-/

import Conduit
import Crucible

namespace ConduitTests.TrySendTests

open Crucible
open Conduit

testSuite "TrySend"

test "trySend on buffered with space returns ok" := do
  let ch ← Channel.newBuffered Nat 3
  let result ← ch.trySend 42
  result.isOk ≡ true

test "trySend multiple values with space" := do
  let ch ← Channel.newBuffered Nat 3
  let r1 ← ch.trySend 1
  let r2 ← ch.trySend 2
  let r3 ← ch.trySend 3
  r1.isOk ≡ true
  r2.isOk ≡ true
  r3.isOk ≡ true

test "trySend on full buffered returns full" := do
  let ch ← Channel.newBuffered Nat 2
  let _ ← ch.trySend 1
  let _ ← ch.trySend 2
  -- Buffer is now full
  let result ← ch.trySend 3
  result.isFull ≡ true

test "trySend on closed channel returns closed" := do
  let ch ← Channel.newBuffered Nat 3
  ch.close
  let result ← ch.trySend 42
  result.isClosed ≡ true

test "trySend on unbuffered with no receiver returns full" := do
  -- Unbuffered channel with no receiver waiting returns "would block" (full)
  let ch ← Channel.new Nat
  let result ← ch.trySend 42
  result.isFull ≡ true

test "trySend on unbuffered with waiting receiver succeeds" := do
  let ch ← Channel.new Nat
  -- Spawn receiver first - it will block waiting for data
  let receiver ← IO.asTask (prio := .dedicated) ch.recv
  -- Small delay to ensure receiver is blocked
  IO.sleep 10
  -- Now trySend should succeed because receiver is waiting
  let result ← ch.trySend 42
  result.isOk ≡ true
  -- Verify receiver got the value
  let v ← IO.wait receiver >>= IO.ofExcept
  v ≡? 42

test "trySend values are received in order" := do
  let ch ← Channel.newBuffered Nat 3
  let _ ← ch.trySend 10
  let _ ← ch.trySend 20
  let _ ← ch.trySend 30
  let v1 ← ch.recv
  let v2 ← ch.recv
  let v3 ← ch.recv
  v1 ≡? 10
  v2 ≡? 20
  v3 ≡? 30

test "trySend after partial drain succeeds" := do
  let ch ← Channel.newBuffered Nat 2
  let _ ← ch.trySend 1
  let _ ← ch.trySend 2
  -- Full, trySend would fail
  let r1 ← ch.trySend 3
  r1.isFull ≡ true
  -- Drain one
  let _ ← ch.recv
  -- Now trySend should succeed
  let r2 ← ch.trySend 3
  r2.isOk ≡ true

testSuite "Channel.len"

test "len returns 0 for empty buffered channel" := do
  let ch ← Channel.newBuffered Nat 5
  let len ← ch.len
  len ≡ 0

test "len returns correct count after sends" := do
  let ch ← Channel.newBuffered Nat 5
  let _ ← ch.send 1
  let _ ← ch.send 2
  let _ ← ch.send 3
  let len ← ch.len
  len ≡ 3

test "len decreases after recv" := do
  let ch ← Channel.newBuffered Nat 5
  let _ ← ch.send 1
  let _ ← ch.send 2
  let _ ← ch.recv
  let len ← ch.len
  len ≡ 1

test "len returns 0 for unbuffered channel" := do
  let ch ← Channel.new Nat
  let len ← ch.len
  len ≡ 0



end ConduitTests.TrySendTests
