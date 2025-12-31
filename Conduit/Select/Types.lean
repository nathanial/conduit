/-
  Conduit.Select.Types

  Types for the select mechanism.
-/

import Conduit.Core

namespace Conduit.Select

/-- A case in a select statement -/
inductive Case where
  /-- Receive from a channel -/
  | recv {α : Type} (ch : Channel α) : Case
  /-- Send a value to a channel -/
  | send {α : Type} (ch : Channel α) (value : α) : Case

/-- Internal representation of a select case for FFI.
    Stores channel reference and whether it's a send operation. -/
structure CaseInfo where
  /-- The channel (type-erased) -/
  channel : Channel Unit  -- Type-erased at FFI level
  /-- True if this is a send operation, false for receive -/
  isSend : Bool

/-- Builder for constructing select cases -/
structure Builder where
  /-- The cases to select on -/
  cases : Array CaseInfo

namespace Builder

/-- Create an empty select builder -/
def empty : Builder := { cases := #[] }

/-- Add a receive case -/
def addRecv {α : Type} (b : Builder) (ch : Channel α) : Builder :=
  -- Safe cast since Channel α = Channel Unit at runtime (phantom type)
  let ch' : Channel Unit := cast (by rfl) ch
  { cases := b.cases.push { channel := ch', isSend := false } }

/-- Add a send case -/
def addSend {α : Type} (b : Builder) (ch : Channel α) (_value : α) : Builder :=
  -- Note: value is stored separately for actual send
  let ch' : Channel Unit := cast (by rfl) ch
  { cases := b.cases.push { channel := ch', isSend := true } }

/-- Number of cases -/
def size (b : Builder) : Nat := b.cases.size

/-- Check if empty -/
def isEmpty (b : Builder) : Bool := b.cases.isEmpty

end Builder

end Conduit.Select
