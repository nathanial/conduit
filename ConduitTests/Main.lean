/-
  ConduitTests.Main

  Test runner for Conduit tests.
-/

import Crucible
import ConduitTests.ChannelTests
import ConduitTests.CombinatorTests
import ConduitTests.SelectTests
import ConduitTests.TypeTests
import ConduitTests.TrySendTests
import ConduitTests.SelectAdvancedTests
import ConduitTests.ConcurrencyTests
import ConduitTests.TimeoutTests
import ConduitTests.BroadcastTests
import ConduitTests.EdgeCaseTests
import ConduitTests.StressTests
import ConduitTests.ResourceTests

open Crucible

def main : IO UInt32 := runAllSuites (timeout := 10000)
