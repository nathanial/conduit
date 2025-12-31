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

def isOk : SendResult → Bool
  | .ok => true
  | .closed => false

def isClosed : SendResult → Bool
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

def isOk : TrySendResult → Bool
  | .ok => true
  | _ => false

def isFull : TrySendResult → Bool
  | .full => true
  | _ => false

def isClosed : TrySendResult → Bool
  | .closed => true
  | _ => false

end TrySendResult

namespace TryResult

def isOk {α : Type} : TryResult α → Bool
  | .ok _ => true
  | _ => false

def isEmpty {α : Type} : TryResult α → Bool
  | .empty => true
  | _ => false

def isClosed {α : Type} : TryResult α → Bool
  | .closed => true
  | _ => false

def toOption {α : Type} : TryResult α → Option α
  | .ok v => some v
  | _ => none

def map {α β : Type} (f : α → β) : TryResult α → TryResult β
  | .ok v => .ok (f v)
  | .empty => .empty
  | .closed => .closed

end TryResult

end Conduit
