/-
  Conduit.Select.DSL

  High-level DSL for select operations.
-/

import Conduit.Core
import Conduit.Channel
import Conduit.Select.Types
import Conduit.Select

namespace Conduit

/-- Monad for building select cases -/
structure SelectM (α : Type) where
  run : Select.Builder → Select.Builder × α

instance : Monad SelectM where
  pure a := ⟨fun b => (b, a)⟩
  bind ma f := ⟨fun b =>
    let (b', a) := ma.run b
    (f a).run b'⟩

instance : Functor SelectM where
  map f ma := ⟨fun b =>
    let (b', a) := ma.run b
    (b', f a)⟩

instance : Applicative SelectM where
  pure := pure
  seq f x := ⟨fun b =>
    let (b', f') := f.run b
    let (b'', x') := (x ()).run b'
    (b'', f' x')⟩

/-- Add a receive case to the select -/
def recvCase {α : Type} (ch : Channel α) : SelectM Unit :=
  ⟨fun b => (b.addRecv ch, ())⟩

/-- Add a send case to the select -/
def sendCase {α : Type} (ch : Channel α) (value : α) : SelectM Unit :=
  ⟨fun b => (b.addSend ch value, ())⟩

/-- Build a select from cases and poll (non-blocking).
    Returns the index of the ready case, or none if none ready. -/
def selectPoll (cases : SelectM Unit) : IO (Option Nat) := do
  let (builder, _) := cases.run Select.Builder.empty
  Select.poll builder

/-- Build a select from cases and wait (blocking).
    Returns the index of the ready case. -/
def selectWait (cases : SelectM Unit) : IO (Option Nat) := do
  let (builder, _) := cases.run Select.Builder.empty
  Select.wait builder

/-- Build a select from cases and wait with timeout.
    Returns the index of the ready case, or none on timeout. -/
def selectTimeout (cases : SelectM Unit) (timeoutMs : Nat) : IO (Option Nat) := do
  let (builder, _) := cases.run Select.Builder.empty
  Select.waitTimeout builder timeoutMs

/-- Alias for selectWait -/
abbrev select := selectWait

end Conduit
