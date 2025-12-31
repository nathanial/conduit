/-
  Conduit.Select

  Select mechanism for waiting on multiple channels.
-/

import Conduit.Core
import Conduit.Channel
import Conduit.Select.Types

namespace Conduit.Select

/-- Poll an array of (channel, isSend) pairs.
    Returns the index of the first ready channel, or none if none are ready. -/
@[extern "conduit_select_poll"]
private opaque pollRaw (cases : @& Array (Channel Unit × Bool)) : IO (Option Nat)

/-- Wait for any channel to become ready.
    timeout is in milliseconds (0 = wait forever).
    Returns the index of the ready channel, or none on timeout. -/
@[extern "conduit_select_wait"]
private opaque waitRaw (cases : @& Array (Channel Unit × Bool)) (timeout : @& Nat) : IO (Option Nat)

/-- Convert Builder to the raw array format for FFI -/
private def toRawCases (b : Builder) : Array (Channel Unit × Bool) :=
  b.cases.map fun info => (info.channel, info.isSend)

/-- Poll all cases, returning the index of the first ready one.
    Non-blocking: returns none immediately if no case is ready. -/
def poll (b : Builder) : IO (Option Nat) :=
  pollRaw (toRawCases b)

/-- Wait for any case to become ready.
    Blocking: waits until at least one case is ready.
    Returns the index of the ready case. -/
def wait (b : Builder) : IO (Option Nat) :=
  waitRaw (toRawCases b) 0

/-- Wait for any case to become ready, with timeout.
    timeout is in milliseconds.
    Returns none if timeout expires before any case is ready. -/
def waitTimeout (b : Builder) (timeoutMs : Nat) : IO (Option Nat) :=
  waitRaw (toRawCases b) timeoutMs

/-- Run a select with the default case.
    If any case is ready, execute it. Otherwise execute the default.
    Returns the index of the executed case, or none if default was used. -/
def withDefault (b : Builder) : IO (Option Nat) :=
  poll b

end Conduit.Select
