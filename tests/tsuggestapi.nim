import
  ../suggestapi, os, std/asyncnet, strutils, chronos, options
import unittest2

const inputLine = "def	skProc	hw.a	proc (){.noSideEffect, gcsafe.}	hw/hw.nim	1	5	\"\"	100"
const inputLineWithEndLine = "outline	skEnumField	system.bool.true	bool	basic_types.nim	46	15	\"\"	100	4	11"

suite "Nimsuggest tests":
  let
    helloWorldFile = getCurrentDir() / "tests/projects/hw/hw.nim"
    nimSuggest = createNimsuggest(helloWorldFile).waitFor.ns.waitFor

  test "Parsing qualified path":
    doAssert parseQualifiedPath("a.b.c") == @["a", "b", "c"]
    doAssert parseQualifiedPath("system.`..<`") == @["system", "`..<`"]

  test "Parsing suggest":
    doAssert parseSuggestDef(inputLine).get[] == Suggest(
      filePath: "hw/hw.nim",
      qualifiedPath: @["hw", "a"],
      symKind: "skProc",
      line: 1,
      column: 5,
      doc: "",
      forth: "proc (){.noSideEffect, gcsafe.}",
      section: ideDef)[]

  test "Parsing suggest with endLine":
    let res = parseSuggestDef(inputLineWithEndLine).get
    doAssert res[] == Suggest(
      filePath: "basic_types.nim",
      qualifiedPath: @["system", "bool", "true"],
      symKind: "skEnumField",
      line: 46,
      column: 15,
      doc: "",
      forth: "bool",
      section: ideOutline,
      endLine: 4,
      endCol: 11
    )[]

  test "Parsing every section the trace-enabled nimsuggest answers with":
    # codetracer-nim's `compiler/options.nim` `$`(IdeCmd) names the section
    # each answer row starts with. `highlightRange` (the semantic-tokens
    # route) and `declaration` rows used to raise from `parseEnum`.
    for (name, section) in [
        ("highlightRange", ideHighlightRange), ("declaration", ideDeclaration),
        ("globalSymbols", ideGlobalSymbols), ("chkFile", ideChkFile),
        ("traceExpand", ideTraceExpand), ("traceStatic", ideTraceStatic)]:
      let row = name & "\tskProc\thw.a\tproc ()\thw/hw.nim\t1\t5\t\"\""
      let res = parseSuggestDef(row)
      check res.isSome
      if res.isSome:
        check res.get.section == section

  test "A row the parser does not understand is dropped, not raised":
    # An unknown section or a non-numeric position must not raise: the
    # exception used to escape the request queue and strand every request
    # behind the one that received the row.
    check parseSuggestDef(
      "someFutureVerb\tskProc\thw.a\tproc ()\thw/hw.nim\t1\t5\t\"\"").isNone
    check parseSuggestDef(
      "def\tskProc\thw.a\tproc ()\thw/hw.nim\tone\t5\t\"\"").isNone

  test "test Nimsuggest.call":
    let res = waitFor nimSuggest.call("def", helloWorldFile, helloWorldFile, 2, 10)
    doAssert res.len == 1
    doAssert res[0].forth.contains("noSideEffect")

  test "test Nimsuggest.def":
    let res = waitFor nimSuggest.def(helloWorldFile, helloWorldFile, 2, 10)
    doAssert res.len == 1
    doAssert res[0].forth.contains("proc")

  test "test Nimsuggest.sug":
    let res = waitFor nimSuggest.sug(helloWorldFile, helloWorldFile, 2, 0)
    doAssert res.len > 1
    doAssert res[0].forth == "proc ()"

  test "test Nimsuggest.known":
    let res = waitFor nimSuggest.known(helloWorldFile)
    doAssert res[0].forth == "true"

  # test "test Nimsuggest.chk cancel more than one":
  #   let
  #     res1 = nimSuggest.chk(helloWorldFile, helloWorldFile)
  #     res2 = nimSuggest.chk(helloWorldFile, helloWorldFile)
  #   doAssert res1.waitFor.len == 2
  #   doAssert res2.waitFor.len == 0
