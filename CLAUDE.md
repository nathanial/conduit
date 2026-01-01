# CLAUDE.md - conduit

## Overview

Go-style channels library for Lean 4 providing typed, thread-safe communication between concurrent tasks. Supports unbuffered (synchronous) and buffered (async) channels with a runtime select mechanism.

## Build Commands

```bash
lake build           # Build library
lake test            # Run tests
```

## Architecture

### Core Types

- `Channel α` - Opaque typed channel handle (wraps pthread primitives)
- `SendResult` - Result of send operation (ok | closed)
- `TryResult α` - Result of non-blocking operation (ok value | empty | closed)

### Channel Operations

| Function | Description |
|----------|-------------|
| `Channel.new` | Create unbuffered channel |
| `Channel.newBuffered n` | Create buffered channel with capacity n |
| `Channel.send ch v` | Blocking send, returns false if closed |
| `Channel.recv ch` | Blocking receive, returns none if closed |
| `Channel.trySend ch v` | Non-blocking send |
| `Channel.tryRecv ch` | Non-blocking receive |
| `Channel.close ch` | Close channel |

### Select

The select mechanism waits on multiple channel operations:

```lean
let idx ← Conduit.Select.run do
  Conduit.Select.onRecv ch1
  Conduit.Select.onRecv ch2
  Conduit.Select.onSend ch3 value
-- idx is the 0-based index of the ready operation
```

### FFI

Uses POSIX pthread for thread safety:
- `pthread_mutex_t` - Protects channel state
- `pthread_cond_t` - Signals for blocking operations
- Supports both macOS and Linux

### File Structure

```
Conduit/
├── Core/
│   ├── Types.lean      # SendResult, TryResult
│   └── Channel.lean    # Opaque handle
├── Channel.lean        # Core operations
├── Channel/
│   └── Combinators.lean # forEach, drain, fromArray
├── Select/
│   ├── Types.lean      # SelectCase, SelectBuilder
│   └── DSL.lean        # High-level syntax
└── Select.lean         # Select operations
native/
└── src/
    └── conduit_ffi.c   # pthread implementation
```

## Dependencies

- **crucible** - Test framework

## Semantics

### Unbuffered Channels (capacity 0)
- `send` blocks until a receiver is ready
- `recv` blocks until a sender is ready
- Direct handoff between sender and receiver

### Buffered Channels (capacity > 0)
- `send` blocks only when buffer is full
- `recv` blocks only when buffer is empty
- FIFO ordering of values

### Closed Channels
- `send` on closed channel returns `false` immediately
- `recv` on closed channel drains remaining values, then returns `none`
- Closing is idempotent

### Task Priority for Blocking Operations

When spawning tasks that block on channel operations (`recv`, `send`, `for v in ch do`), use `IO.asTask (prio := .dedicated)` to create real OS threads:

```lean
-- CORRECT: dedicated threads can block independently
let task ← IO.asTask (prio := .dedicated) do
  for v in ch do
    process v

-- WRONG: default priority uses thread pool, can deadlock
let task ← IO.asTask do
  for v in ch do  -- may hang if pool threads are exhausted
    process v
```

The default thread pool has limited workers. If all workers block on channel operations, no progress can be made. `.dedicated` creates a new OS thread that can block without affecting the pool.
