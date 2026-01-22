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

testSuite "TryResult Functor/Monad"

test "Functor map via <$>" := do
  let r : TryResult Nat := .ok 10
  let mapped := (· + 5) <$> r
  match mapped with
  | .ok v => v ≡ 15
  | _ => throw (IO.userError "expected .ok")

test "Applicative pure creates ok" := do
  let r : TryResult Nat := pure 42
  match r with
  | .ok v => v ≡ 42
  | _ => throw (IO.userError "expected .ok")

test "Applicative seq applies function" := do
  let f : TryResult (Nat → Nat) := .ok (· * 2)
  let x : TryResult Nat := .ok 21
  let result := f <*> x
  match result with
  | .ok v => v ≡ 42
  | _ => throw (IO.userError "expected .ok")

test "Applicative seq with empty function returns empty" := do
  let f : TryResult (Nat → Nat) := .empty
  let x : TryResult Nat := .ok 21
  let result := f <*> x
  result.isEmpty ≡ true

test "Applicative seq with closed function returns closed" := do
  let f : TryResult (Nat → Nat) := .closed
  let x : TryResult Nat := .ok 21
  let result := f <*> x
  result.isClosed ≡ true

test "Monad bind chains ok values" := do
  let r : TryResult Nat := .ok 10
  let result := r >>= fun n => TryResult.ok (n * 2)
  match result with
  | .ok v => v ≡ 20
  | _ => throw (IO.userError "expected .ok")

test "Monad bind propagates empty" := do
  let r : TryResult Nat := .empty
  let result := r >>= fun n => TryResult.ok (n * 2)
  result.isEmpty ≡ true

test "Monad bind propagates closed" := do
  let r : TryResult Nat := .closed
  let result := r >>= fun n => TryResult.ok (n * 2)
  result.isClosed ≡ true

test "Monad do-notation works" := do
  let result : TryResult Nat := do
    let a ← TryResult.ok 10
    let b ← TryResult.ok 20
    pure (a + b)
  match result with
  | .ok v => v ≡ 30
  | _ => throw (IO.userError "expected .ok")

test "Monad do-notation short-circuits on empty" := do
  let result : TryResult Nat := do
    let a ← TryResult.ok 10
    let _ ← (TryResult.empty : TryResult Nat)
    pure a
  result.isEmpty ≡ true



end ConduitTests.TypeTests
