/-
  Conduit.Core.Types

  Result types for channel operations.
-/

namespace Conduit

/-- Result of a send operation -/
inductive SendResult where
  | ok      -- Successfully sent
  | closed  -- Channel is closed
  deriving Repr, BEq, Inhabited

/-- Result of a non-blocking receive operation -/
inductive TryResult (α : Type) where
  | ok (value : α)  -- Successfully received
  | empty           -- Channel is empty (would block)
  | closed          -- Channel is closed, no more values
  deriving Repr

instance {α : Type} : Inhabited (TryResult α) where
  default := .closed

namespace SendResult

@[inline] def isOk : SendResult → Bool
  | .ok => true
  | .closed => false

@[inline] def isClosed : SendResult → Bool
  | .ok => false
  | .closed => true

end SendResult

/-- Result of a non-blocking send operation -/
inductive TrySendResult where
  | ok       -- Successfully sent
  | full     -- Buffer full / no waiting receiver (would block)
  | closed   -- Channel is closed
  deriving Repr, BEq, Inhabited

namespace TrySendResult

@[inline] def isOk : TrySendResult → Bool
  | .ok => true
  | _ => false

@[inline] def isFull : TrySendResult → Bool
  | .full => true
  | _ => false

@[inline] def isClosed : TrySendResult → Bool
  | .closed => true
  | _ => false

end TrySendResult

namespace TryResult

@[inline] def isOk {α : Type} : TryResult α → Bool
  | .ok _ => true
  | _ => false

@[inline] def isEmpty {α : Type} : TryResult α → Bool
  | .empty => true
  | _ => false

@[inline] def isClosed {α : Type} : TryResult α → Bool
  | .closed => true
  | _ => false

@[inline] def toOption {α : Type} : TryResult α → Option α
  | .ok v => some v
  | _ => none

@[inline] def map {α β : Type} (f : α → β) : TryResult α → TryResult β
  | .ok v => .ok (f v)
  | .empty => .empty
  | .closed => .closed

@[inline] def bind {α β : Type} (ma : TryResult α) (f : α → TryResult β) : TryResult β :=
  match ma with
  | .ok a => f a
  | .empty => .empty
  | .closed => .closed

@[inline] def pure {α : Type} (a : α) : TryResult α := .ok a

end TryResult

instance : Functor TryResult where
  map := TryResult.map

instance : Applicative TryResult where
  pure := TryResult.pure
  seq f x := match f with
    | .ok f' => TryResult.map f' (x ())
    | .empty => .empty
    | .closed => .closed

instance : Monad TryResult where
  bind := TryResult.bind

end Conduit
