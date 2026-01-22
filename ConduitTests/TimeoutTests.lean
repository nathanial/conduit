/-
  ConduitTests.TimeoutTests

  Tests for timeout variants of send and recv operations.
-/

import Conduit
import Crucible

namespace ConduitTests.TimeoutTests

open Crucible
open Conduit

testSuite "sendTimeout"

test "sendTimeout on buffered with space returns ok" := do
  let ch ← Channel.newBuffered Nat 3
  let result ← ch.sendTimeout 42 1000
  result ≡ (some true : Option Bool)

test "sendTimeout on full buffered times out" := do
  let ch ← Channel.newBuffered Nat 1
  let _ ← ch.send 1  -- Fill the buffer
  let start ← IO.monoMsNow
  let result ← ch.sendTimeout 42 50
  let elapsed ← IO.monoMsNow
  shouldBeNone result
  -- Should timeout around 50ms
  if elapsed - start < 30 then
    throw (IO.userError s!"Timeout too fast: {elapsed - start}ms")
  if elapsed - start > 200 then
    throw (IO.userError s!"Timeout too slow: {elapsed - start}ms")

test "sendTimeout on closed channel returns closed" := do
  let ch ← Channel.newBuffered Nat 3
  ch.close
  let result ← ch.sendTimeout 42 1000
  result ≡ (some false : Option Bool)

test "sendTimeout on unbuffered times out without receiver" := do
  let ch ← Channel.new Nat
  let start ← IO.monoMsNow
  let result ← ch.sendTimeout 42 50
  let elapsed ← IO.monoMsNow
  shouldBeNone result
  if elapsed - start < 30 then
    throw (IO.userError s!"Timeout too fast: {elapsed - start}ms")
  if elapsed - start > 200 then
    throw (IO.userError s!"Timeout too slow: {elapsed - start}ms")

test "sendTimeout on unbuffered succeeds with waiting receiver" := do
  let ch ← Channel.new Nat
  -- Spawn receiver first
  let receiver ← IO.asTask (prio := .dedicated) ch.recv
  IO.sleep 10
  let result ← ch.sendTimeout 42 1000
  result ≡ (some true : Option Bool)
  -- Verify receiver got the value
  let v ← IO.wait receiver >>= IO.ofExcept
  v ≡ (some 42 : Option Nat)

testSuite "recvTimeout"

test "recvTimeout on buffered with data returns value" := do
  let ch ← Channel.newBuffered Nat 3
  let _ ← ch.send 42
  let result ← ch.recvTimeout 1000
  result ≡ (some (some 42) : Option (Option Nat))

test "recvTimeout on empty buffered times out" := do
  let ch ← Channel.newBuffered Nat 3
  let start ← IO.monoMsNow
  let result ← ch.recvTimeout 50
  let elapsed ← IO.monoMsNow
  shouldBeNone result
  if elapsed - start < 30 then
    throw (IO.userError s!"Timeout too fast: {elapsed - start}ms")
  if elapsed - start > 200 then
    throw (IO.userError s!"Timeout too slow: {elapsed - start}ms")

test "recvTimeout on closed channel returns closed" := do
  let ch ← Channel.newBuffered Nat 3
  ch.close
  let result ← ch.recvTimeout 1000
  result ≡ (some none : Option (Option Nat))

test "recvTimeout drains buffer before returning closed" := do
  let ch ← Channel.newBuffered Nat 3
  let _ ← ch.send 1
  let _ ← ch.send 2
  ch.close
  let v1 ← ch.recvTimeout 100
  let v2 ← ch.recvTimeout 100
  let v3 ← ch.recvTimeout 100
  v1 ≡ (some (some 1) : Option (Option Nat))
  v2 ≡ (some (some 2) : Option (Option Nat))
  v3 ≡ (some none : Option (Option Nat))

test "recvTimeout on unbuffered times out without sender" := do
  let ch ← Channel.new Nat
  let start ← IO.monoMsNow
  let result ← ch.recvTimeout 50
  let elapsed ← IO.monoMsNow
  shouldBeNone result
  if elapsed - start < 30 then
    throw (IO.userError s!"Timeout too fast: {elapsed - start}ms")
  if elapsed - start > 200 then
    throw (IO.userError s!"Timeout too slow: {elapsed - start}ms")

test "recvTimeout wakes when sender arrives" := do
  let ch ← Channel.newBuffered Nat 1
  let start ← IO.monoMsNow
  let _ ← IO.asTask (prio := .dedicated) do
    IO.sleep 30
    let _ ← ch.send 99
    pure ()
  let result ← ch.recvTimeout 1000
  let elapsed ← IO.monoMsNow
  result ≡ (some (some 99) : Option (Option Nat))
  -- Should complete in ~30-100ms
  if elapsed - start < 20 then
    throw (IO.userError s!"Too fast: {elapsed - start}ms")
  if elapsed - start > 300 then
    throw (IO.userError s!"Too slow: {elapsed - start}ms")



end ConduitTests.TimeoutTests
