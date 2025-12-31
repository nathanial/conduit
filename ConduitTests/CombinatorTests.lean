/-
  ConduitTests.CombinatorTests

  Tests for channel combinators.
-/

import Conduit
import Crucible

namespace ConduitTests.CombinatorTests

open Crucible
open Conduit

testSuite "Channel Combinators"

test "fromArray creates closed channel with values" := do
  let ch ← Channel.fromArray #[1, 2, 3]
  let closed ← ch.isClosed
  closed ≡ true
  let v1 ← ch.recv
  let v2 ← ch.recv
  let v3 ← ch.recv
  let v4 ← ch.recv
  v1 ≡? 1
  v2 ≡? 2
  v3 ≡? 3
  shouldBeNone v4

test "singleton creates single-value channel" := do
  let ch ← Channel.singleton "hello"
  let v1 ← ch.recv
  let v2 ← ch.recv
  v1 ≡? "hello"
  shouldBeNone v2

test "empty creates closed empty channel" := do
  let ch ← Channel.empty Nat
  let closed ← ch.isClosed
  closed ≡ true
  let v ← ch.recv
  shouldBeNone v

test "send! throws on closed channel" := do
  let ch ← Channel.new Nat
  ch.close
  shouldThrow (ch.send! 42)

test "recv! throws on closed channel" := do
  let ch ← Channel.new Nat
  ch.close
  shouldThrow ch.recv!

#generate_tests

end ConduitTests.CombinatorTests
