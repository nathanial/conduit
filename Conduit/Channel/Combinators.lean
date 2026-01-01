/-
  Conduit.Channel.Combinators

  Higher-level operations built on core channel primitives.
-/

import Conduit.Core
import Conduit.Channel

namespace Conduit.Channel

variable {α β : Type}

/-- Send a value, throwing an error if the channel is closed. -/
def send! (ch : Channel α) (value : α) : IO Unit := do
  let success ← ch.send value
  unless success do
    throw (IO.userError "send on closed channel")

/-- Receive a value, throwing an error if the channel is closed. -/
def recv! (ch : Channel α) : IO α := do
  match ← ch.recv with
  | some v => pure v
  | none => throw (IO.userError "receive on closed channel")

/-- Iterate over all values from a channel until it is closed.
    The function f is called for each received value. -/
partial def forEach (ch : Channel α) (f : α → IO Unit) : IO Unit := do
  match ← ch.recv with
  | some v =>
    f v
    forEach ch f
  | none => pure ()

/-- Helper for ForIn instance - loops until channel closed or early exit. -/
private partial def forInLoop {α β : Type} (ch : Channel α)
    (f : α → β → IO (ForInStep β)) (acc : β) : IO β := do
  match ← ch.recv with
  | some v =>
    match ← f v acc with
    | .done acc' => pure acc'
    | .yield acc' => forInLoop ch f acc'
  | none => pure acc

/-- ForIn instance enabling `for v in ch do ...` syntax.
    Iterates until channel is closed or early exit (break). -/
instance : ForIn IO (Channel α) α where
  forIn ch init f := forInLoop ch f init

/-- Collect all remaining values from a channel into an array.
    Blocks until the channel is closed. -/
partial def drain (ch : Channel α) : IO (Array α) := do
  let rec loop (acc : Array α) : IO (Array α) := do
    match ← ch.recv with
    | some v => loop (acc.push v)
    | none => pure acc
  loop #[]

/-- Create a buffered channel pre-filled with values from an array.
    The channel is closed after all values are added. -/
def fromArray (arr : Array α) : IO (Channel α) := do
  let ch ← Channel.newBuffered α arr.size
  for v in arr do
    let _ ← ch.send v
  ch.close
  pure ch

/-- Create a buffered channel pre-filled with values from a list.
    The channel is closed after all values are added. -/
def fromList (lst : List α) : IO (Channel α) := do
  let ch ← Channel.newBuffered α lst.length
  for v in lst do
    let _ ← ch.send v
  ch.close
  pure ch

/-- Default buffer size for combinator output channels. -/
private def defaultBufferSize : Nat := 16

/-- Map a function over values received from a channel, sending results to a new channel.
    Spawns a background task to perform the mapping.
    The output channel is closed when the input channel is exhausted. -/
def map (ch : Channel α) (f : α → β) (bufferSize : Nat := defaultBufferSize) : IO (Channel β) := do
  let out ← Channel.newBuffered β bufferSize
  let _ ← IO.asTask (prio := .dedicated) do
    ch.forEach fun v => do
      let _ ← out.send (f v)
    out.close
  pure out

/-- Filter values from a channel based on a predicate.
    Spawns a background task to perform the filtering.
    The output channel is closed when the input channel is exhausted. -/
def filter (ch : Channel α) (p : α → Bool) (bufferSize : Nat := defaultBufferSize) : IO (Channel α) := do
  let out ← Channel.newBuffered α bufferSize
  let _ ← IO.asTask (prio := .dedicated) do
    ch.forEach fun v => do
      if p v then
        let _ ← out.send v
    out.close
  pure out

/-- Merge multiple channels into one.
    Values are received from all channels and sent to the output.
    Spawns a task for each input channel.
    The output channel is closed when all input channels are exhausted. -/
def merge (channels : Array (Channel α)) (bufferSize : Nat := defaultBufferSize) : IO (Channel α) := do
  let out ← Channel.newBuffered α bufferSize
  let remaining ← IO.mkRef channels.size

  if channels.isEmpty then
    out.close
    return out

  for ch in channels do
    let _ ← IO.asTask (prio := .dedicated) do
      ch.forEach fun v => do
        let _ ← out.send v
      let count ← remaining.modifyGet fun n => (n - 1, n - 1)
      if count == 0 then
        out.close

  pure out

/-- Create a channel that receives a single value and then closes. -/
def singleton (value : α) : IO (Channel α) := do
  let ch ← Channel.newBuffered α 1
  let _ ← ch.send value
  ch.close
  pure ch

/-- Create an already-closed empty channel. -/
def empty (α : Type) : IO (Channel α) := do
  let ch ← Channel.new α
  ch.close
  pure ch

/-- Pipeline operator for map. Equivalent to `ch.map f`. -/
def pipe (ch : Channel α) (f : α → β) (bufferSize : Nat := defaultBufferSize)
    : IO (Channel β) := ch.map f bufferSize

/-- Pipeline operator for filter. Equivalent to `ch.filter p`. -/
def pipeFilter (ch : Channel α) (p : α → Bool) (bufferSize : Nat := defaultBufferSize)
    : IO (Channel α) := ch.filter p bufferSize

infixl:55 " |>> " => pipe
infixl:55 " |>? " => pipeFilter

end Conduit.Channel
