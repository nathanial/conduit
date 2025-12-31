/-
  ConduitTests.SelectAdvancedTests

  Tests for select with send cases, timeouts, and Builder utilities.
-/

import Conduit
import Crucible

namespace ConduitTests.SelectAdvancedTests

open Crucible
open Conduit

testSuite "Select with sendCase"

test "poll with sendCase on buffered with space returns ready" := do
  let ch ← Channel.newBuffered Nat 3
  let result ← selectPoll do
    sendCase ch 42
  result ≡? 0

test "poll with sendCase on full buffered returns none" := do
  let ch ← Channel.newBuffered Nat 1
  let _ ← ch.send 1  -- Fill the buffer
  let result ← selectPoll do
    sendCase ch 42
  shouldBeNone result

test "poll with sendCase on closed channel returns none" := do
  -- Closed channels are NOT ready for send (can't send to closed channel)
  let ch ← Channel.newBuffered Nat 3
  ch.close
  let result ← selectPoll do
    sendCase ch 42
  shouldBeNone result

test "poll with mixed recv and send cases" := do
  let recvCh ← Channel.newBuffered Nat 3
  let sendCh ← Channel.newBuffered Nat 3
  -- Only sendCh has space, recvCh is empty
  let result ← selectPoll do
    recvCase recvCh
    sendCase sendCh 42
  result ≡? 1

test "poll prefers first ready case" := do
  let ch1 ← Channel.newBuffered Nat 3
  let ch2 ← Channel.newBuffered Nat 3
  -- Both have space for send
  let result ← selectPoll do
    sendCase ch1 1
    sendCase ch2 2
  result ≡? 0

testSuite "selectTimeout"

test "selectTimeout returns none when timeout expires" := do
  let ch ← Channel.newBuffered Nat 3
  -- No data, so recv would block
  let result ← selectTimeout (recvCase ch) 10
  shouldBeNone result

test "selectTimeout returns index when channel ready before timeout" := do
  let ch ← Channel.newBuffered Nat 3
  let _ ← ch.send 42
  let result ← selectTimeout (recvCase ch) 1000
  result ≡? 0

test "selectTimeout with send case on channel with space" := do
  let ch ← Channel.newBuffered Nat 3
  let result ← selectTimeout (sendCase ch 42) 1000
  result ≡? 0

test "selectTimeout with multiple cases returns first ready" := do
  let ch1 ← Channel.newBuffered Nat 3
  let ch2 ← Channel.newBuffered Nat 3
  let _ ← ch2.send 99  -- Only ch2 has data
  let result ← selectTimeout (do recvCase ch1; recvCase ch2) 100
  result ≡? 1

testSuite "Select.Builder"

test "Builder.empty has size 0" := do
  let b := Select.Builder.empty
  b.size ≡ 0

test "Builder.isEmpty returns true for empty builder" := do
  let b := Select.Builder.empty
  b.isEmpty ≡ true

test "Builder.size returns correct count after addRecv" := do
  let ch1 ← Channel.new Nat
  let ch2 ← Channel.new Nat
  let b := Select.Builder.empty
    |>.addRecv ch1
    |>.addRecv ch2
  b.size ≡ 2

test "Builder.isEmpty returns false after adding case" := do
  let ch ← Channel.new Nat
  let b := Select.Builder.empty.addRecv ch
  b.isEmpty ≡ false

test "Builder.size counts send cases" := do
  let ch ← Channel.newBuffered Nat 3
  let b := Select.Builder.empty
    |>.addSend ch 1
    |>.addSend ch 2
  b.size ≡ 2

test "Builder.size counts mixed cases" := do
  let ch1 ← Channel.new Nat
  let ch2 ← Channel.newBuffered Nat 3
  let b := Select.Builder.empty
    |>.addRecv ch1
    |>.addSend ch2 42
    |>.addRecv ch1
  b.size ≡ 3

#generate_tests

end ConduitTests.SelectAdvancedTests
