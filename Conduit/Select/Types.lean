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

/-- Erase the type parameter from a channel handle.
    Safe because Channel α is an opaque pointer regardless of α (phantom type). -/
private unsafe def eraseChannelTypeImpl {α : Type} (ch : Channel α) : Channel Unit :=
  unsafeCast ch

/-- Safe wrapper for type erasure. -/
@[implemented_by eraseChannelTypeImpl]
private def eraseChannelType {α : Type} (ch : Channel α) : Channel Unit := ch

/-- Add a receive case -/
@[inline] def addRecv {α : Type} (b : Builder) (ch : Channel α) : Builder :=
  { cases := b.cases.push { channel := eraseChannelType ch, isSend := false } }

/-- Add a send case -/
@[inline] def addSend {α : Type} (b : Builder) (ch : Channel α) (_value : α) : Builder :=
  { cases := b.cases.push { channel := eraseChannelType ch, isSend := true } }

/-- Number of cases -/
@[inline] def size (b : Builder) : Nat := b.cases.size

/-- Check if empty -/
@[inline] def isEmpty (b : Builder) : Bool := b.cases.isEmpty

end Builder

end Conduit.Select
