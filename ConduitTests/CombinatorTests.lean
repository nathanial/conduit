/-
  ConduitTests.CombinatorTests

  Tests for channel combinators.
-/

import Conduit
import Crucible

namespace ConduitTests.CombinatorTests

open Crucible
open Conduit

testSuite "Channel Combinators"

test "fromArray creates closed channel with values" := do
  let ch ← Channel.fromArray #[1, 2, 3]
  let closed ← ch.isClosed
  closed ≡ true
  let v1 ← ch.recv
  let v2 ← ch.recv
  let v3 ← ch.recv
  let v4 ← ch.recv
  v1 ≡? 1
  v2 ≡? 2
  v3 ≡? 3
  shouldBeNone v4

test "singleton creates single-value channel" := do
  let ch ← Channel.singleton "hello"
  let v1 ← ch.recv
  let v2 ← ch.recv
  v1 ≡? "hello"
  shouldBeNone v2

test "empty creates closed empty channel" := do
  let ch ← Channel.empty Nat
  let closed ← ch.isClosed
  closed ≡ true
  let v ← ch.recv
  shouldBeNone v

test "send! throws on closed channel" := do
  let ch ← Channel.new Nat
  ch.close
  shouldThrow (ch.send! 42)

test "recv! throws on closed channel" := do
  let ch ← Channel.new Nat
  ch.close
  shouldThrow ch.recv!

testSuite "forEach"

test "forEach processes all values in order" := do
  let ch ← Channel.fromArray #[1, 2, 3]
  let results ← IO.mkRef #[]
  ch.forEach fun v => do
    results.modify (·.push v)
  let arr ← results.get
  arr ≡ #[1, 2, 3]

test "forEach stops when channel closes" := do
  let ch ← Channel.fromArray #[10, 20]
  let sum ← IO.mkRef 0
  ch.forEach fun v => do
    sum.modify (· + v)
  let total ← sum.get
  total ≡ 30

test "forEach on empty closed channel does nothing" := do
  let ch ← Channel.empty Nat
  let count ← IO.mkRef 0
  ch.forEach fun _ => do
    count.modify (· + 1)
  let c ← count.get
  c ≡ 0

testSuite "ForIn"

test "ForIn iterates until channel closed" := do
  let ch ← Channel.fromArray #[1, 2, 3]
  let mut sum := 0
  for v in ch do
    sum := sum + v
  sum ≡ 6

test "ForIn supports early exit with break" := do
  let ch ← Channel.fromArray #[1, 2, 3, 4, 5]
  let mut sum := 0
  for v in ch do
    sum := sum + v
    if sum >= 6 then break  -- 1+2+3=6, should exit here
  sum ≡ 6

test "ForIn collects into array" := do
  let ch ← Channel.fromArray #[10, 20, 30]
  let mut arr : Array Nat := #[]
  for v in ch do
    arr := arr.push v
  arr ≡ #[10, 20, 30]

test "ForIn on empty channel does nothing" := do
  let ch ← Channel.empty Nat
  let mut count := 0
  for _ in ch do
    count := count + 1
  count ≡ 0

test "ForIn accumulator works correctly" := do
  let ch ← Channel.fromArray #["a", "b", "c"]
  let mut result := ""
  for s in ch do
    result := result ++ s
  result ≡ "abc"

testSuite "drain"

test "drain collects all values into array" := do
  let ch ← Channel.fromArray #[1, 2, 3, 4, 5]
  let arr ← ch.drain
  arr ≡ #[1, 2, 3, 4, 5]

test "drain on empty closed channel returns empty array" := do
  let ch ← Channel.empty Nat
  let arr ← ch.drain
  arr ≡ #[]

test "drain preserves order" := do
  let ch ← Channel.fromArray #["a", "b", "c"]
  let arr ← ch.drain
  arr ≡ #["a", "b", "c"]

testSuite "fromList"

test "fromList creates closed channel with list values" := do
  let ch ← Channel.fromList [1, 2, 3]
  let closed ← ch.isClosed
  closed ≡ true
  let arr ← ch.drain
  arr ≡ #[1, 2, 3]

test "fromList with empty list creates closed empty channel" := do
  let ch ← Channel.fromList ([] : List Nat)
  let closed ← ch.isClosed
  closed ≡ true
  let v ← ch.recv
  shouldBeNone v

testSuite "map"

test "map transforms values correctly" := do
  let input ← Channel.fromArray #[1, 2, 3]
  let output ← input.map (· * 2)
  let results ← output.drain
  results ≡ #[2, 4, 6]

test "map with identity returns same values" := do
  let input ← Channel.fromArray #[10, 20, 30]
  let output ← input.map id
  let results ← output.drain
  results ≡ #[10, 20, 30]

test "map closes output when input closes" := do
  let input ← Channel.fromArray #[1]
  let output ← input.map (· + 1)
  let _ ← output.drain
  let closed ← output.isClosed
  closed ≡ true

test "map with type change" := do
  let input ← Channel.fromArray #[1, 2, 3]
  let output ← input.map toString
  let results ← output.drain
  results ≡ #["1", "2", "3"]

testSuite "filter"

test "filter keeps matching values" := do
  let input ← Channel.fromArray #[1, 2, 3, 4, 5]
  let output ← input.filter (· % 2 == 0)
  let results ← output.drain
  results ≡ #[2, 4]

test "filter removes non-matching values" := do
  let input ← Channel.fromArray #[1, 3, 5, 7]
  let output ← input.filter (· % 2 == 0)
  let results ← output.drain
  results ≡ #[]

test "filter with all matching" := do
  let input ← Channel.fromArray #[2, 4, 6]
  let output ← input.filter (· % 2 == 0)
  let results ← output.drain
  results ≡ #[2, 4, 6]

test "filter closes output when input closes" := do
  let input ← Channel.fromArray #[1, 2]
  let output ← input.filter (· > 0)
  let _ ← output.drain
  let closed ← output.isClosed
  closed ≡ true

testSuite "merge"

test "merge combines values from multiple channels" := do
  let ch1 ← Channel.fromArray #[1, 2]
  let ch2 ← Channel.fromArray #[3, 4]
  let merged ← Channel.merge #[ch1, ch2]
  let results ← merged.drain
  -- Order may vary due to concurrent tasks, but all values should be present
  shouldHaveLength results.toList 4
  shouldContain results.toList 1
  shouldContain results.toList 2
  shouldContain results.toList 3
  shouldContain results.toList 4

test "merge closes when all inputs close" := do
  let ch1 ← Channel.fromArray #[1]
  let ch2 ← Channel.fromArray #[2]
  let merged ← Channel.merge #[ch1, ch2]
  let _ ← merged.drain
  let closed ← merged.isClosed
  closed ≡ true

test "merge with single channel" := do
  let ch ← Channel.fromArray #[1, 2, 3]
  let merged ← Channel.merge #[ch]
  let results ← merged.drain
  results ≡ #[1, 2, 3]

test "merge with empty array" := do
  let merged ← Channel.merge (#[] : Array (Channel Nat))
  let closed ← merged.isClosed
  closed ≡ true

testSuite "Pipeline Operators"

test "pipe operator maps values" := do
  let ch ← Channel.fromArray #[1, 2, 3]
  let mapped ← ch |>> (· * 2)
  let result ← mapped.drain
  result ≡ #[2, 4, 6]

test "pipeFilter operator filters values" := do
  let ch ← Channel.fromArray #[1, 2, 3, 4, 5]
  let filtered ← ch |>? (· % 2 == 0)
  let result ← filtered.drain
  result ≡ #[2, 4]

test "pipeline operators chain" := do
  let ch ← Channel.fromArray #[1, 2, 3, 4, 5]
  let step1 ← ch |>? (· > 2)
  let step2 ← step1 |>> (· * 10)
  let result ← step2.drain
  result ≡ #[30, 40, 50]

test "pipe with type change" := do
  let ch ← Channel.fromArray #[1, 2, 3]
  let mapped ← ch |>> toString
  let result ← mapped.drain
  result ≡ #["1", "2", "3"]

test "pipeFilter keeps all when predicate always true" := do
  let ch ← Channel.fromArray #[1, 2, 3]
  let filtered ← ch |>? (fun _ => true)
  let result ← filtered.drain
  result ≡ #[1, 2, 3]



end ConduitTests.CombinatorTests
