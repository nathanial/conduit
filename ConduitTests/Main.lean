/-
  ConduitTests.Main

  Test runner for Conduit tests.
-/

import Crucible
import ConduitTests.ChannelTests
import ConduitTests.CombinatorTests
import ConduitTests.SelectTests

open Crucible

def main : IO UInt32 := runAllSuites
