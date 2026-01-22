/-
  ConduitTests.StressTests

  Stress tests for high-volume and sustained channel operations.
-/

import Conduit
import Crucible

namespace ConduitTests.StressTests

open Crucible
open Conduit

testSuite "High-Volume Producers"

test "1000 sends from single producer" := do
  let ch ← Channel.newBuffered Nat 1000
  for i in [:1000] do
    let _ ← ch.send i
  ch.close
  let arr ← ch.drain
  arr.size ≡ 1000

test "1000 sends from 10 concurrent producers" := do
  let ch ← Channel.newBuffered Nat 1000
  -- Spawn 10 producers, each sending 100 values
  let producers ← (List.range 10).mapM fun batch =>
    IO.asTask (prio := .dedicated) do
      for i in [:100] do
        let _ ← ch.send (batch * 100 + i)
  -- Wait for all producers
  for p in producers do
    let _ ← IO.wait p
  ch.close
  let arr ← ch.drain
  arr.size ≡ 1000

test "5000 sends from 50 concurrent producers" := do
  let ch ← Channel.newBuffered Nat 5000
  -- Spawn 50 producers, each sending 100 values
  let producers ← (List.range 50).mapM fun batch =>
    IO.asTask (prio := .dedicated) do
      for i in [:100] do
        let _ ← ch.send (batch * 100 + i)
  -- Wait for all producers
  for p in producers do
    let _ ← IO.wait p
  ch.close
  let arr ← ch.drain
  arr.size ≡ 5000

testSuite "High-Volume Consumers"

test "1000 values consumed by single receiver" := do
  let ch ← Channel.newBuffered Nat 1000
  -- Fill channel
  for i in [:1000] do
    let _ ← ch.send i
  ch.close
  -- Single consumer drains all
  let mut count := 0
  for _ in ch do
    count := count + 1
  count ≡ 1000

test "1000 values consumed by 10 concurrent receivers" := do
  let ch ← Channel.newBuffered Nat 1000
  -- Fill channel
  for i in [:1000] do
    let _ ← ch.send i
  ch.close
  -- Spawn 10 consumers
  let counts ← IO.mkRef #[]
  let consumers ← (List.range 10).mapM fun _ =>
    IO.asTask (prio := .dedicated) do
      let mut count := 0
      for _ in ch do
        count := count + 1
      counts.modify (·.push count)
  -- Wait for all consumers
  for c in consumers do
    let _ ← IO.wait c
  -- Total should be 1000
  let allCounts ← counts.get
  let total := allCounts.foldl (· + ·) 0
  total ≡ 1000

test "concurrent producer-consumer with 1000 values" := do
  let ch ← Channel.newBuffered Nat 100  -- Small buffer forces synchronization
  let received ← IO.mkRef 0
  -- Start consumer first
  let consumer ← IO.asTask (prio := .dedicated) do
    for _ in ch do
      received.modify (· + 1)
  -- Producer sends 1000 values
  let producer ← IO.asTask (prio := .dedicated) do
    for i in [:1000] do
      let _ ← ch.send i
    ch.close
  let _ ← IO.wait producer
  let _ ← IO.wait consumer
  let count ← received.get
  count ≡ 1000

testSuite "Large Buffer Sizes"

test "buffer capacity 1000" := do
  let ch ← Channel.newBuffered Nat 1000
  let cap ← ch.capacity
  cap ≡ 1000
  -- Fill to capacity
  for i in [:1000] do
    let _ ← ch.send i
  let len ← ch.len
  len ≡ 1000
  ch.close
  let arr ← ch.drain
  arr.size ≡ 1000

test "buffer capacity 5000" := do
  let ch ← Channel.newBuffered Nat 5000
  let cap ← ch.capacity
  cap ≡ 5000
  -- Fill to capacity
  for i in [:5000] do
    let _ ← ch.send i
  let len ← ch.len
  len ≡ 5000
  ch.close
  let arr ← ch.drain
  arr.size ≡ 5000

test "buffer capacity 10000" := do
  let ch ← Channel.newBuffered Nat 10000
  let cap ← ch.capacity
  cap ≡ 10000
  -- Fill to capacity
  for i in [:10000] do
    let _ ← ch.send i
  let len ← ch.len
  len ≡ 10000
  ch.close
  let arr ← ch.drain
  arr.size ≡ 10000

testSuite "Many Channels Lifecycle"

test "create and close 100 channels" := do
  for _ in [:100] do
    let ch ← Channel.newBuffered Nat 10
    ch.close

test "create, use, and close 100 channels" := do
  for i in [:100] do
    let ch ← Channel.newBuffered Nat 5
    let _ ← ch.send i
    let v ← ch.recv
    v ≡? i
    ch.close

test "create 50 channels, use concurrently, close" := do
  let channels ← (List.range 50).mapM fun _ =>
    Channel.newBuffered Nat 10
  -- Send to all concurrently
  let senders ← channels.toArray.mapIdxM fun idx ch =>
    IO.asTask (prio := .dedicated) do
      let _ ← ch.send idx
  for s in senders do
    let _ ← IO.wait s
  -- Receive from all
  for ch in channels do
    let v ← ch.recv
    v.isSome ≡ true
    ch.close

test "rapid create-send-recv-close cycles" := do
  for i in [:200] do
    let ch ← Channel.newBuffered Nat 1
    let _ ← ch.send i
    let v ← ch.recv
    v ≡? i
    ch.close

testSuite "Sustained Producer-Consumer"

test "sustained producer-consumer for 500ms" := do
  let ch ← Channel.newBuffered Nat 50
  let produced ← IO.mkRef 0
  let consumed ← IO.mkRef 0
  let running ← IO.mkRef true
  -- Producer: send as fast as possible
  let producer ← IO.asTask (prio := .dedicated) do
    while ← running.get do
      let sent ← ch.trySend 42
      if sent.isOk then
        produced.modify (· + 1)
      else
        IO.sleep 1  -- Back off if full
  -- Consumer: receive as fast as possible
  let consumer ← IO.asTask (prio := .dedicated) do
    while ← running.get do
      let result ← ch.tryRecv
      if result.isOk then
        consumed.modify (· + 1)
      else
        IO.sleep 1  -- Back off if empty
  -- Run for 500ms
  IO.sleep 500
  running.set false
  ch.close
  let _ ← IO.wait producer
  let _ ← IO.wait consumer
  -- Should have processed many values
  let p ← produced.get
  let c ← consumed.get
  if p < 100 then
    throw (IO.userError s!"Too few produced: {p}")
  if c < 100 then
    throw (IO.userError s!"Too few consumed: {c}")

test "multiple producer-consumer pairs sustained" := do
  let ch ← Channel.newBuffered Nat 100
  let totalSent ← IO.mkRef 0
  let totalRecv ← IO.mkRef 0
  let running ← IO.mkRef true
  -- 3 producers
  let producers ← (List.range 3).mapM fun _ =>
    IO.asTask (prio := .dedicated) do
      while ← running.get do
        let sent ← ch.trySend 1
        if sent.isOk then
          totalSent.modify (· + 1)
        else
          IO.sleep 1
  -- 3 consumers
  let consumers ← (List.range 3).mapM fun _ =>
    IO.asTask (prio := .dedicated) do
      while ← running.get do
        let result ← ch.tryRecv
        if result.isOk then
          totalRecv.modify (· + 1)
        else
          IO.sleep 1
  -- Run for 300ms
  IO.sleep 300
  running.set false
  ch.close
  for p in producers do
    let _ ← IO.wait p
  for c in consumers do
    let _ ← IO.wait c
  -- Should have transferred many values
  let sent ← totalSent.get
  let recv ← totalRecv.get
  if sent < 50 then
    throw (IO.userError s!"Too few sent: {sent}")
  if recv < 50 then
    throw (IO.userError s!"Too few received: {recv}")

testSuite "Memory Pressure"

test "channel with large string values" := do
  let ch ← Channel.newBuffered String 100
  -- Create large strings (1KB each)
  let largeStr := String.ofList (List.replicate 1024 'x')
  for _ in [:100] do
    let _ ← ch.send largeStr
  ch.close
  let arr ← ch.drain
  arr.size ≡ 100
  -- Verify content
  for s in arr do
    s.length ≡ 1024

test "channel with large array values" := do
  let ch ← Channel.newBuffered (Array Nat) 50
  -- Create arrays with 1000 elements each
  let largeArr := Array.range 1000
  for _ in [:50] do
    let _ ← ch.send largeArr
  ch.close
  let arr ← ch.drain
  arr.size ≡ 50
  -- Verify content
  for a in arr do
    a.size ≡ 1000

test "many small channels with data" := do
  -- Create 100 channels, each with some data
  let mut total := 0
  for i in [:100] do
    let ch ← Channel.newBuffered Nat 10
    for j in [:10] do
      let _ ← ch.send (i * 10 + j)
    ch.close
    let arr ← ch.drain
    total := total + arr.size
  total ≡ 1000



end ConduitTests.StressTests
