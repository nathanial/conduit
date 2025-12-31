/-
  Conduit.Core.Channel

  Opaque channel handle definition.
-/

namespace Conduit

/-- Opaque channel handle wrapping pthread primitives.
    The type parameter α is phantom at the FFI level -
    values are passed as lean_object* pointers. -/
opaque ChannelPointed : NonemptyType

/-- A typed channel for sending values of type α between concurrent tasks.

    Channels can be unbuffered (capacity 0) or buffered (capacity > 0):
    - Unbuffered: send blocks until a receiver is ready (synchronous handoff)
    - Buffered: send only blocks when the buffer is full

    Channels are thread-safe and can be shared across multiple tasks. -/
def Channel (_α : Type) : Type := ChannelPointed.type

instance {α : Type} : Nonempty (Channel α) := ChannelPointed.property

end Conduit
