/-
  Conduit.Broadcast

  Broadcast channels for fan-out distribution.
  Each subscriber receives a copy of every value sent to the source.
-/

import Conduit.Channel
import Conduit.Channel.Combinators

namespace Conduit
namespace Broadcast

variable {α : Type}

/-- Create a broadcast from a source channel with a fixed number of subscribers.
    Each subscriber channel receives all values from the source.
    When the source closes, all subscriber channels close. -/
def create (source : Channel α) (numSubscribers : Nat)
    (bufferSize : Nat := 16) : IO (Array (Channel α)) := do
  if numSubscribers == 0 then
    return #[]
  -- Create subscriber channels
  let mut subscribers : Array (Channel α) := #[]
  for _ in [:numSubscribers] do
    let ch ← Channel.newBuffered α bufferSize
    subscribers := subscribers.push ch
  -- Spawn distributor task
  let subs := subscribers
  let _ ← IO.asTask (prio := .dedicated) do
    Channel.forEach source fun v => do
      for sub in subs do
        let _ ← sub.send v
    -- Close all subscribers when source exhausted
    for sub in subs do
      sub.close
  pure subscribers

/-- A broadcast hub allowing dynamic subscriber addition.
    Subscribers added after values are sent will only receive future values. -/
structure HubState (α : Type) where
  subscribers : Array (Channel α)
  closed : Bool

structure Hub (α : Type) where
  private mk ::
  private state : IO.Ref (HubState α)
  private bufferSize : Nat

/-- Create a broadcast hub from a source channel.
    Subscribers can be added dynamically with `Hub.subscribe`.
    New subscribers will receive all future values from the point of subscription. -/
def hub (source : Channel α) (bufferSize : Nat := 16) : IO (Hub α) := do
  let state ← IO.mkRef { subscribers := (#[] : Array (Channel α)), closed := false }
  let h : Hub α := ⟨state, bufferSize⟩
  -- Spawn distributor task
  let _ ← IO.asTask (prio := .dedicated) do
    Channel.forEach source fun v => do
      let currentSubs := (← state.get).subscribers
      for sub in currentSubs do
        let _ ← sub.send v
    -- Mark closed and close all current subscribers
    let currentSubs ← state.modifyGet fun st =>
      (st.subscribers, { st with closed := true })
    for sub in currentSubs do
      sub.close
  pure h

/-- Subscribe to the hub, receiving all future values.
    Returns none if the hub is already closed. -/
def Hub.subscribe (h : Hub α) : IO (Option (Channel α)) := do
  let ch ← Channel.newBuffered α h.bufferSize
  let added ← h.state.modifyGet fun st =>
    if st.closed then
      (false, st)
    else
      (true, { st with subscribers := st.subscribers.push ch })
  if added then
    return some ch
  ch.close
  return none

/-- Check if the hub is closed. -/
def Hub.isClosed (h : Hub α) : IO Bool :=
  return (← h.state.get).closed

/-- Get the current number of subscribers. -/
def Hub.subscriberCount (h : Hub α) : IO Nat := do
  let st ← h.state.get
  return st.subscribers.size

end Broadcast
end Conduit
