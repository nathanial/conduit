import Lake
open Lake DSL System

package conduit where
  version := v!"0.1.0"
  leanOptions := #[
    ⟨`autoImplicit, false⟩,
    ⟨`relaxedAutoImplicit, false⟩
  ]

require crucible from git "https://github.com/nathanial/crucible" @ "v0.0.8"

@[default_target]
lean_lib Conduit where
  roots := #[`Conduit]

lean_lib ConduitTests where
  roots := #[`ConduitTests]

@[test_driver]
lean_exe conduit_tests where
  root := `ConduitTests.Main

-- FFI: Build C code with pthread
target conduit_ffi_o pkg : FilePath := do
  let oFile := pkg.buildDir / "native" / "conduit_ffi.o"
  let srcJob ← inputTextFile <| pkg.dir / "native" / "src" / "conduit_ffi.c"
  let leanIncludeDir ← getLeanIncludeDir
  let weakArgs := #["-I", leanIncludeDir.toString]
  buildO oFile srcJob weakArgs #["-fPIC", "-O2", "-pthread"] "cc" getLeanTrace

extern_lib conduit_native pkg := do
  let name := nameToStaticLib "conduit_native"
  let ffiO ← conduit_ffi_o.fetch
  buildStaticLib (pkg.buildDir / "lib" / name) #[ffiO]
