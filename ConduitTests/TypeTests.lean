/-
  ConduitTests.TypeTests

  Tests for TryResult and SendResult utility functions.
-/

import Conduit
import Crucible

namespace ConduitTests.TypeTests

open Crucible
open Conduit

testSuite "SendResult"

test "isOk returns true for ok" := do
  let r : SendResult := .ok
  r.isOk ≡ true

test "isOk returns false for closed" := do
  let r : SendResult := .closed
  r.isOk ≡ false

test "isClosed returns true for closed" := do
  let r : SendResult := .closed
  r.isClosed ≡ true

test "isClosed returns false for ok" := do
  let r : SendResult := .ok
  r.isClosed ≡ false

test "isOk and isClosed are mutually exclusive" := do
  let okResult : SendResult := .ok
  let closedResult : SendResult := .closed
  (okResult.isOk && okResult.isClosed) ≡ false
  (closedResult.isOk && closedResult.isClosed) ≡ false
  (okResult.isOk || okResult.isClosed) ≡ true
  (closedResult.isOk || closedResult.isClosed) ≡ true

testSuite "TryResult"

test "TryResult isOk returns true for ok variant" := do
  let r : TryResult Nat := .ok 42
  r.isOk ≡ true

test "TryResult isOk returns false for empty" := do
  let r : TryResult Nat := .empty
  r.isOk ≡ false

test "TryResult isOk returns false for closed" := do
  let r : TryResult Nat := .closed
  r.isOk ≡ false

test "TryResult isEmpty returns true for empty" := do
  let r : TryResult Nat := .empty
  r.isEmpty ≡ true

test "TryResult isEmpty returns false for ok" := do
  let r : TryResult Nat := .ok 42
  r.isEmpty ≡ false

test "TryResult isEmpty returns false for closed" := do
  let r : TryResult Nat := .closed
  r.isEmpty ≡ false

test "TryResult isClosed returns true for closed" := do
  let r : TryResult Nat := .closed
  r.isClosed ≡ true

test "TryResult isClosed returns false for ok" := do
  let r : TryResult Nat := .ok 42
  r.isClosed ≡ false

test "TryResult isClosed returns false for empty" := do
  let r : TryResult Nat := .empty
  r.isClosed ≡ false

test "toOption returns some for ok" := do
  let r : TryResult Nat := .ok 42
  r.toOption ≡? 42

test "toOption returns none for empty" := do
  let r : TryResult Nat := .empty
  shouldBeNone r.toOption

test "toOption returns none for closed" := do
  let r : TryResult Nat := .closed
  shouldBeNone r.toOption

test "map transforms ok value" := do
  let r : TryResult Nat := .ok 21
  let mapped := r.map (· * 2)
  match mapped with
  | .ok v => v ≡ 42
  | _ => throw (IO.userError "expected .ok")

test "map preserves empty" := do
  let r : TryResult Nat := .empty
  let mapped := r.map (· * 2)
  mapped.isEmpty ≡ true

test "map preserves closed" := do
  let r : TryResult Nat := .closed
  let mapped := r.map (· * 2)
  mapped.isClosed ≡ true

#generate_tests

end ConduitTests.TypeTests
