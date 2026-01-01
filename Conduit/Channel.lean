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

/-- Non-blocking send. Returns the result status:
    - ok: Successfully sent
    - full: Buffer full or no waiting receiver (would block)
    - closed: Channel is closed -/
def trySend (ch : Channel α) (value : α) : IO TrySendResult := do
  let result ← trySendRaw ch value
  match result with
  | 0 => pure .ok
  | 1 => pure .full
  | _ => pure .closed

/-- Non-blocking receive. Returns the result with value or status. -/
@[extern "conduit_channel_try_recv"]
opaque tryRecv (ch : @& Channel α) : IO (TryResult α)

/-- Send with timeout. Returns 0=ok, 1=timeout, 2=closed. -/
@[extern "conduit_channel_send_timeout"]
private opaque sendTimeoutRaw (ch : @& Channel α) (value : α) (timeoutMs : @& Nat) : IO UInt8

/-- Send with timeout.
    - some true: sent successfully
    - some false: channel closed
    - none: timeout expired -/
def sendTimeout (ch : Channel α) (value : α) (timeoutMs : Nat) : IO (Option Bool) := do
  let result ← sendTimeoutRaw ch value timeoutMs
  match result with
  | 0 => pure (some true)   -- ok
  | 1 => pure none          -- timeout
  | _ => pure (some false)  -- closed

/-- Receive with timeout.
    - some (some v): received value
    - some none: channel closed
    - none: timeout expired -/
@[extern "conduit_channel_recv_timeout"]
opaque recvTimeout (ch : @& Channel α) (timeoutMs : @& Nat) : IO (Option (Option α))

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

namespace Conduit.Channel.Debug

/-- Get allocation statistics for testing finalizers.
    Returns (alloc_count, free_count).
    Used to verify that channel finalizers run correctly. -/
@[extern "conduit_get_alloc_stats"]
opaque getAllocStats : IO (Nat × Nat)

/-- Reset allocation statistics counters to zero.
    Useful for isolating stats between tests. -/
@[extern "conduit_reset_alloc_stats"]
opaque resetAllocStats : IO Unit

end Conduit.Channel.Debug
