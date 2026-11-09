## Regression tests for the two defects that made the desktop's Nim trace
## query (`nim/traceStaticBlock`, `nim/traceExpandMacro`) unusable.
##
## Nothing is mocked: the first test runs the real `getNimbleDumpInfo` with a
## real `PATH` that holds no `nimble`, the situation of a shell whose first
## entry is the patched compiler's folder; the second parses the line a real
## patched nimsuggest prints for `traceStatic`.
import ../[ls, suggestapi]
import std/[os, options]
import chronos
import unittest2

suite "Nimble dump without nimble on the PATH":
  test "getNimbleDumpInfo returns an empty result instead of crashing":
    let emptyDir = getTempDir() / "nls-empty-path-" & $getCurrentProcessId()
    createDir(emptyDir)
    let oldPath = getEnv("PATH")
    putEnv("PATH", emptyDir)
    defer:
      putEnv("PATH", oldPath)
      removeDir(emptyDir)
    let ls = LanguageServer()
    # Before the fix `process` stayed nil after `startProcess` failed and the
    # `finally` block dereferenced it: SIGSEGV, which ends the whole test run.
    let info = waitFor ls.getNimbleDumpInfo("")
    check info.nimDir.isNone
    check info.nimblePath.isNone
    check info.entryPoints.len == 0

suite "traceStatic answers":
  test "the line nimsuggest prints for a traceStatic query is parsed":
    # Verbatim from the patched nimsuggest (`--v4 --autobind`), query 5:2.
    const line =
      "traceStatic\tskUnknown\t\t\t\t5\t2\t" &
      "\"/home/u/.cache/nim/tracing_d/static_trace_5.ct\"\t0"
    let sug = parseSuggestDef(line)
    check sug.isSome
    check sug.get.section == ideTraceStatic
    check sug.get.doc == "/home/u/.cache/nim/tracing_d/static_trace_5.ct"
