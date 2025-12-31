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

open Crucible

def main : IO UInt32 := runAllSuites
