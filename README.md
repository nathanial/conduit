# Conduit

Go-style typed channels for Lean 4 with unbuffered and buffered modes.

## Features

- **Unbuffered channels** - Synchronous handoff between sender and receiver
- **Buffered channels** - Asynchronous with configurable capacity
- **Thread-safe** - POSIX pthread primitives (mutex, condition variables)
- **Select mechanism** - Poll multiple channels for readiness
- **Combinators** - Higher-level operations like `forEach`, `map`, `filter`

## Installation

Add to your `lakefile.lean`:

```lean
require conduit from git "https://github.com/nathanial/conduit" @ "v0.0.1"
```

## Quick Start

```lean
import Conduit

open Conduit

def main : IO Unit := do
  -- Create a buffered channel with capacity 3
  let ch ← Channel.newBuffered Nat 3

  -- Send values (non-blocking while buffer has space)
  let _ ← ch.send 1
  let _ ← ch.send 2
  let _ ← ch.send 3

  -- Receive values in FIFO order
  let v1 ← ch.recv  -- some 1
  let v2 ← ch.recv  -- some 2
  let v3 ← ch.recv  -- some 3

  -- Close the channel
  ch.close

  -- Recv on closed channel returns none
  let v4 ← ch.recv  -- none
```

## API Reference

### Channel Creation

```lean
-- Unbuffered channel (capacity 0)
-- Send blocks until a receiver is ready
Channel.new (α : Type) : IO (Channel α)

-- Buffered channel with given capacity
-- Send blocks only when buffer is full
Channel.newBuffered (α : Type) (capacity : Nat) : IO (Channel α)
```

### Core Operations

```lean
-- Blocking send. Returns false if channel is closed.
Channel.send (ch : Channel α) (value : α) : IO Bool

-- Blocking receive. Returns none if channel is closed and empty.
Channel.recv (ch : Channel α) : IO (Option α)

-- Close the channel. Wakes all waiting senders/receivers.
Channel.close (ch : Channel α) : IO Unit

-- Check if channel is closed.
Channel.isClosed (ch : Channel α) : IO Bool

-- Get current buffer length.
Channel.len (ch : Channel α) : IO Nat

-- Get buffer capacity (0 for unbuffered).
Channel.capacity (ch : Channel α) : IO Nat
```

### Non-blocking Operations

```lean
-- Non-blocking send. Returns SendResult (.ok or .closed).
Channel.trySend (ch : Channel α) (value : α) : IO SendResult

-- Non-blocking receive. Returns TryResult (.ok value, .empty, or .closed).
Channel.tryRecv (ch : Channel α) : IO (TryResult α)
```

### Throwing Variants

```lean
-- Send that throws on closed channel.
Channel.send! (ch : Channel α) (value : α) : IO Unit

-- Receive that throws on closed/empty channel.
Channel.recv! (ch : Channel α) : IO α
```

### Combinators

```lean
-- Create channel pre-filled with array values (closed after creation).
Channel.fromArray (arr : Array α) : IO (Channel α)

-- Create single-value channel.
Channel.singleton (value : α) : IO (Channel α)

-- Create empty closed channel.
Channel.empty (α : Type) : IO (Channel α)

-- Process each value until channel closes.
Channel.forEach (ch : Channel α) (f : α → IO Unit) : IO Unit

-- Collect all remaining values into array.
Channel.drain (ch : Channel α) : IO (Array α)

-- Transform values through a function.
Channel.map (ch : Channel α) (f : α → β) : IO (Channel β)

-- Filter values by predicate.
Channel.filter (ch : Channel α) (p : α → Bool) : IO (Channel α)
```

### Select

Poll multiple channels for readiness:

```lean
open Conduit.Select

-- Poll returns index of first ready channel, or none
let result ← selectPoll do
  recvCase ch1
  recvCase ch2
  sendCase ch3 value

match result with
| some 0 => -- ch1 ready for recv
| some 1 => -- ch2 ready for recv
| some 2 => -- ch3 ready for send
| none   => -- no channels ready
```

## Channel Semantics

### Unbuffered Channels (capacity = 0)

- `send` blocks until a receiver calls `recv`
- `recv` blocks until a sender calls `send`
- Direct synchronous handoff between sender and receiver

### Buffered Channels (capacity > 0)

- `send` adds to buffer immediately if space available
- `send` blocks only when buffer is full
- `recv` takes from buffer immediately if data available
- `recv` blocks only when buffer is empty
- FIFO ordering guaranteed

### Closed Channels

- `send` on closed channel returns `false` immediately
- `recv` on closed channel drains remaining buffered values first
- `recv` returns `none` only when closed AND empty
- Closing is idempotent (safe to call multiple times)
- All blocked senders/receivers are woken on close

## Build

```bash
lake build    # Build library
lake test     # Run tests
```

## Dependencies

- **crucible** - Test framework (test only)

## License

MIT License - see [LICENSE](LICENSE)
