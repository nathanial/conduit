/-
  Conduit.Channel

  Core channel operations with FFI bindings.
-/

import Conduit.Core

namespace Conduit.Channel

variable {α : Type}

/-- Create an unbuffered channel (capacity 0).
    Send blocks until a receiver is ready (synchronous handoff). -/
@[extern "conduit_channel_new"]
opaque new (α : Type) : IO (Channel α)

/-- Create a buffered channel with given capacity.
    Capacity 0 is equivalent to unbuffered.
    Send blocks only when buffer is full. -/
@[extern "conduit_channel_new_buffered"]
opaque newBuffered (α : Type) (capacity : Nat) : IO (Channel α)

/-- Blocking send. Returns true if sent, false if channel is closed. -/
@[extern "conduit_channel_send"]
opaque send (ch : @& Channel α) (value : α) : IO Bool

/-- Blocking receive. Returns none if channel is closed and empty. -/
@[extern "conduit_channel_recv"]
opaque recv (ch : @& Channel α) : IO (Option α)

/-- Non-blocking send attempt.
    Returns 0 = success, 1 = would block, 2 = closed. -/
@[extern "conduit_channel_try_send"]
private opaque trySendRaw (ch : @& Channel α) (value : α) : IO UInt8

/-- Non-blocking send. Returns the result status. -/
def trySend (ch : Channel α) (value : α) : IO SendResult := do
  let result ← trySendRaw ch value
  match result with
  | 0 => pure .ok
  | _ => pure .closed  -- 1 (would block) or 2 (closed) both mean failed

/-- Non-blocking receive. Returns the result with value or status. -/
@[extern "conduit_channel_try_recv"]
opaque tryRecv (ch : @& Channel α) : IO (TryResult α)

/-- Close the channel.
    After closing:
    - All pending and future sends return false
    - Receives drain remaining buffered values, then return none
    - Waiting senders/receivers are woken up -/
@[extern "conduit_channel_close"]
opaque close (ch : @& Channel α) : IO Unit

/-- Check if the channel is closed (non-blocking). -/
@[extern "conduit_channel_is_closed"]
opaque isClosed (ch : @& Channel α) : IO Bool

/-- Get current number of items in buffer (0 for unbuffered channels). -/
@[extern "conduit_channel_len"]
opaque len (ch : @& Channel α) : IO Nat

/-- Get buffer capacity (0 for unbuffered channels). -/
@[extern "conduit_channel_capacity"]
opaque capacity (ch : @& Channel α) : IO Nat

end Conduit.Channel
