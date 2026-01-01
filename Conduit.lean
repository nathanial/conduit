/-
  Conduit

  Go-style channels for Lean 4.

  Provides typed, thread-safe communication between concurrent tasks
  with support for unbuffered (synchronous) and buffered (async) channels.

  ## Quick Start

  ```lean
  import Conduit

  -- Create an unbuffered channel
  let ch ← Conduit.Channel.new Nat

  -- Send in a background task
  let _ ← IO.asTask (prio := .dedicated) do
    let _ ← ch.send 42

  -- Receive (blocks until value is available)
  match ← ch.recv with
  | some v => IO.println s!"Received: {v}"
  | none => IO.println "Channel closed"
  ```

  ## Buffered Channels

  ```lean
  -- Create a buffered channel with capacity 10
  let ch ← Conduit.Channel.newBuffered String 10

  -- Send doesn't block until buffer is full
  let _ ← ch.send "hello"
  let _ ← ch.send "world"

  -- Close and drain
  ch.close
  let values ← ch.drain
  ```

  ## Select

  ```lean
  let ch1 ← Conduit.Channel.new Int
  let ch2 ← Conduit.Channel.new String

  -- Wait for either channel
  let idx ← Conduit.select do
    Conduit.recvCase ch1
    Conduit.recvCase ch2

  match idx with
  | some 0 => IO.println "ch1 ready"
  | some 1 => IO.println "ch2 ready"
  | none => IO.println "timeout or all closed"
  ```
-/

import Conduit.Core
import Conduit.Channel
import Conduit.Channel.Combinators
import Conduit.Select.Types
import Conduit.Select
import Conduit.Select.DSL
import Conduit.Broadcast
