/-
  ConduitTests.ChannelTests

  Tests for basic channel operations.
-/

import Conduit
import Crucible

namespace ConduitTests.ChannelTests

open Crucible
open Conduit

testSuite "Unbuffered Channel"

test "create unbuffered channel" := do
  let ch ← Channel.new Nat
  let cap ← ch.capacity
  cap ≡ 0

test "close unbuffered channel" := do
  let ch ← Channel.new String
  ch.close
  let closed ← ch.isClosed
  closed ≡ true

test "recv on closed unbuffered returns none" := do
  let ch ← Channel.new Int
  ch.close
  let result ← ch.recv
  shouldBeNone result

test "send on closed unbuffered returns false" := do
  let ch ← Channel.new Int
  ch.close
  let result ← ch.send 123
  result ≡ false

testSuite "Buffered Channel"

test "create buffered channel" := do
  let ch ← Channel.newBuffered Nat 5
  let cap ← ch.capacity
  cap ≡ 5

test "buffered send does not block when space" := do
  let ch ← Channel.newBuffered Nat 3
  let r1 ← ch.send 1
  let r2 ← ch.send 2
  let r3 ← ch.send 3
  r1 ≡ true
  r2 ≡ true
  r3 ≡ true
  let len ← ch.len
  len ≡ 3

test "buffered recv gets values in order" := do
  let ch ← Channel.newBuffered Nat 3
  let _ ← ch.send 10
  let _ ← ch.send 20
  let _ ← ch.send 30
  let v1 ← ch.recv
  let v2 ← ch.recv
  let v3 ← ch.recv
  v1 ≡? 10
  v2 ≡? 20
  v3 ≡? 30

test "close buffered channel allows drain" := do
  let ch ← Channel.newBuffered String 5
  let _ ← ch.send "a"
  let _ ← ch.send "b"
  ch.close
  let v1 ← ch.recv
  let v2 ← ch.recv
  let v3 ← ch.recv
  v1 ≡? "a"
  v2 ≡? "b"
  shouldBeNone v3

testSuite "TryRecv"

test "tryRecv on empty buffered returns empty" := do
  let ch ← Channel.newBuffered Int 5
  let result ← ch.tryRecv
  result.isEmpty ≡ true

test "tryRecv on closed returns closed" := do
  let ch ← Channel.newBuffered Int 5
  ch.close
  let result ← ch.tryRecv
  result.isClosed ≡ true

test "tryRecv on buffered with data returns value" := do
  let ch ← Channel.newBuffered Int 5
  let _ ← ch.send 42
  let result ← ch.tryRecv
  match result with
  | .ok v => v ≡ 42
  | _ => throw (IO.userError "expected .ok 42")



end ConduitTests.ChannelTests
