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
structure Hub (α : Type) where
  private mk ::
  private subscribers : IO.Ref (Array (Channel α))
  private bufferSize : Nat
  private closed : IO.Ref Bool

/-- Create a broadcast hub from a source channel.
    Subscribers can be added dynamically with `Hub.subscribe`.
    New subscribers will receive all future values from the point of subscription. -/
def hub (source : Channel α) (bufferSize : Nat := 16) : IO (Hub α) := do
  let subs ← IO.mkRef (α := Array (Channel α)) #[]
  let closed ← IO.mkRef false
  let h : Hub α := ⟨subs, bufferSize, closed⟩
  -- Spawn distributor task
  let _ ← IO.asTask (prio := .dedicated) do
    Channel.forEach source fun v => do
      let currentSubs ← subs.get
      for sub in currentSubs do
        let _ ← sub.send v
    -- Mark closed and close all current subscribers
    closed.set true
    let currentSubs ← subs.get
    for sub in currentSubs do
      sub.close
  pure h

/-- Subscribe to the hub, receiving all future values.
    Returns none if the hub is already closed. -/
def Hub.subscribe (h : Hub α) : IO (Option (Channel α)) := do
  let isClosed ← h.closed.get
  if isClosed then
    return none
  let ch ← Channel.newBuffered α h.bufferSize
  h.subscribers.modify (·.push ch)
  return some ch

/-- Check if the hub is closed. -/
def Hub.isClosed (h : Hub α) : IO Bool :=
  h.closed.get

/-- Get the current number of subscribers. -/
def Hub.subscriberCount (h : Hub α) : IO Nat := do
  let subs ← h.subscribers.get
  return subs.size

end Broadcast
end Conduit
