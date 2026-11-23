## End-to-end tests for `textDocument/semanticTokens/range`.
##
## Boots a real nimlangserver subprocess (via `nimlangserver.main`) over a
## socket transport, opens the fixture in `tests/projects/semantic_tokens_fixture`,
## and asserts the on-wire payload matches our SymKind → token-type
## mapping.
##
## Nothing is mocked. The route needs nimsuggest's `highlightRange` verb,
## which only the trace-enabled nimsuggest built from codetracer-nim has, so
## the suite runs against that one (`trace_test_config.traceNimsuggest`:
## `CODETRACER_NIMSUGGEST`, else the sibling build), exactly as CodeTracer's
## dev shell does. It skips only when this machine has no such nimsuggest,
## and says so. With one present, an empty or missing answer FAILS: the
## suite used to skip on "no tokens", and ran against the `PATH` nimsuggest,
## which hid that the server never answered a range request at all (it could
## not parse nimsuggest's `highlightRange` rows, and the failure stranded
## every request queued after it).
##
## Every call is bounded by `AnswerTimeout`, so a server that stops
## answering fails the case instead of hanging the run.

import ../[nimlangserver, ls, lstransports, utils, semantic_tokens]
import ../protocol/types
import std/[options, json, os, strformat, strutils, sets]
import chronos
import lspsocketclient
import unittest2
import trace_test_config

const AnswerTimeout = chronos.seconds(60)

proc callBounded(client: LspSocketClient, name: string, params: JsonNode): JsonNode =
  ## One request, answered within `AnswerTimeout` or failed with
  ## `AsyncTimeoutError` naming nothing more than the wait.
  waitFor client.call(name, params).wait(AnswerTimeout)

type
  DecodedTok = object
    line: int       # 1-based
    startChar: int
    length: int
    tokenType: string
    modifiers: HashSet[string]

proc decodeWire(data: seq[uint32]): seq[DecodedTok] =
  ## Helper: decode the flat uint32[] back into named token-type records,
  ## so the assertions read close to natural language.
  let decoded = decodeSemanticTokens(data)
  for t in decoded:
    var mods = initHashSet[string]()
    for i in 0 ..< SemanticTokenModifiers.len:
      if (t.tokenModifiers and (1'u32 shl i.uint32)) != 0'u32:
        mods.incl(SemanticTokenModifiers[i])
    result.add(DecodedTok(
      line: t.line,
      startChar: t.startChar,
      length: t.length,
      tokenType: SemanticTokenTypes[t.tokenType],
      modifiers: mods,
    ))

proc tokensOnLine(toks: seq[DecodedTok], line: int): seq[DecodedTok] =
  for t in toks:
    if t.line == line:
      result.add(t)

proc anyTokenMatches(toks: seq[DecodedTok], line: int, tokenType: string): bool =
  for t in toks:
    if t.line == line and t.tokenType == tokenType:
      return true
  false

suite "SemanticTokensRange":
  let traceNs = traceNimsuggest()
  let savedNs = getEnv(CodetracerNimsuggestVar)
  if traceNs.len > 0:
    putEnv(CodetracerNimsuggestVar, traceNs)
  let cmdParams = CommandLineParams(transport: some socket, port: getNextFreePort())
  let ls = main(cmdParams)
  let client = newLspSocketClient()
  client.registerNotification(
    "window/showMessage",
    "window/workDoneProgress/create",
    "workspace/configuration",
    "extension/statusUpdate",
    "textDocument/publishDiagnostics",
    "$/progress",
  )
  waitFor client.connect("localhost", cmdParams.port)

  let initParams =
    InitializeParams %* {
      "processId": %getCurrentProcessId(),
      "rootUri": fixtureUri("projects/semantic_tokens_fixture/"),
      "capabilities": {
        "window": {"workDoneProgress": true},
        "workspace": {"configuration": true},
      },
    }
  let initResult = waitFor client.initialize(initParams)
  client.notify("initialized", newJObject())

  # Restored once the suite is done, not after each case: the fixture's
  # nimsuggest is started between cases (on `didOpen` below) and must find
  # the trace-enabled one in the environment.
  suiteTeardown:
    if savedNs.len > 0: putEnv(CodetracerNimsuggestVar, savedNs)
    else: delEnv(CodetracerNimsuggestVar)

  template withTraceNimsuggest(body: untyped) =
    ## Run `body` against the fixture's trace-enabled nimsuggest. The case is
    ## reported SKIPPED only when this machine has no such nimsuggest, and
    ## FAILED when it has one that never started. (A `return` from a case
    ## would report it OK whatever its checks said.)
    if traceNs.len == 0:
      checkpoint "no trace-enabled nimsuggest (highlightRange): set " &
        CodetracerNimsuggestVar & " or build ../codetracer-nim/bin/nimsuggest"
      skip()
    elif not nsReady:
      checkpoint "nimsuggest never reported it initialized for the fixture"
      fail()
    else:
      body

  test "initialize advertises semanticTokensProvider with our legend":
    let prov = initResult.capabilities.semanticTokensProvider
    check prov.isSome
    let legend = prov.get.legend
    check legend.tokenTypes == SemanticTokenTypes
    check legend.tokenModifiers == SemanticTokenModifiers
    check prov.get.range.get(false) == true

  # Open the fixture and wait for nimsuggest to come up.  All
  # subsequent tests share this server state.
  let fixture = "projects/semantic_tokens_fixture/main.nim"
  client.notify("textDocument/didOpen", %createDidOpenParams(fixture))
  let absFile = fixture.fixtureUri.uriToPath
  let nsReady = traceNs.len > 0 and waitFor client.waitForNotificationMessage(
    fmt "Nimsuggest initialized for {absFile}"
  )

  proc requestTokens(rangeJson: JsonNode): seq[DecodedTok] =
    let params = %*{
      "textDocument": {"uri": fixtureUri(fixture)},
      "range": rangeJson,
    }
    let raw = client.callBounded("textDocument/semanticTokens/range", params)
    check raw.kind == JObject
    check raw.hasKey("data")
    var data = newSeq[uint32]()
    for v in raw["data"].items:
      data.add(uint32(v.getInt))
    return decodeWire(data)

  test "wide range returns a token sequence sorted by (line, char)":
    withTraceNimsuggest:
      let toks = requestTokens(%*{
        "start": {"line": 0, "character": 0},
        "end":   {"line": 999, "character": 0},
      })
      check toks.len > 0
      for i in 1 ..< toks.len:
        check (toks[i - 1].line < toks[i].line) or
              (toks[i - 1].line == toks[i].line and
               toks[i - 1].startChar <= toks[i].startChar)

  test "determinism: same request twice yields byte-identical payload":
    withTraceNimsuggest:
      let params = %*{
        "textDocument": {"uri": fixtureUri(fixture)},
        "range": {
          "start": {"line": 0, "character": 0},
          "end":   {"line": 999, "character": 0},
        },
      }
      let a = client.callBounded("textDocument/semanticTokens/range", params)
      let b = client.callBounded("textDocument/semanticTokens/range", params)
      check a == b

  test "range narrowing returns only tokens inside the requested interval":
    withTraceNimsuggest:
      # Lines 10–13 contain the `greet` definition + body.
      let narrow = requestTokens(%*{
        "start": {"line": 10, "character": 0},
        "end":   {"line": 13, "character": 0},
      })
      check narrow.len > 0
      for t in narrow:
        # nimsuggest is 1-based; LSP range is 0-based.  Allow ±1 slack for
        # closing positions that nimsuggest may report at the edge.
        check t.line >= 10
        check t.line <= 14

  test "malformed range produces an empty (non-crashing) response":
    withTraceNimsuggest:
      # end < start — encoder should still return a well-formed payload.
      let raw = client.callBounded("textDocument/semanticTokens/range", %*{
        "textDocument": {"uri": fixtureUri(fixture)},
        "range": {
          "start": {"line": 50, "character": 0},
          "end":   {"line": 10, "character": 0},
        },
      })
      check raw.kind == JObject
      check raw.hasKey("data")
      check raw["data"].len mod 5 == 0

  test "unknown URI returns an empty response rather than crashing":
    let raw = client.callBounded("textDocument/semanticTokens/range", %*{
      "textDocument": {"uri": "file:///nonexistent/sema_test.nim"},
      "range": {
        "start": {"line": 0, "character": 0},
        "end":   {"line": 10, "character": 0},
      },
    })
    check raw.kind == JObject
    check raw.hasKey("data")
    check raw["data"].len == 0

  test "fixture symbols map to the expected token types":
    withTraceNimsuggest:
      let toks = requestTokens(%*{
        "start": {"line": 0, "character": 0},
        "end":   {"line": 999, "character": 0},
      })
      check toks.len > 0

      # Layout reminder (1-based lines from the fixture):
      #  7: type
      #  8:   Foo* = object
      #  9:     bar*: int
      # 11: proc greet*(name: string): string =
      # 12:   let prefix = "hi "
      # 13:   result = prefix & name
      # 15: template withFoo*(x: int, body: untyped) =
      # 18: macro myMacro*(x: int): untyped =
      # 21: const PI* = 3.14
      # 22: var counter* = 0
      #
      # Each assertion is range-tolerant because nimsuggest can emit tokens
      # at definition site and (occasionally) at neighbouring positions.

      check anyTokenMatches(toks, 8, "type")          # Foo
      check anyTokenMatches(toks, 11, "function")     # greet
      check anyTokenMatches(toks, 15, "macro")        # withFoo (template)
      check anyTokenMatches(toks, 18, "macro")        # myMacro

      # `const PI = 3.14` — readonly modifier required.
      var sawReadonlyConst = false
      for t in tokensOnLine(toks, 21):
        if t.tokenType == "variable" and "readonly" in t.modifiers:
          sawReadonlyConst = true
      check sawReadonlyConst

      # `var counter = 0` — variable WITHOUT readonly.
      var sawMutableVar = false
      for t in tokensOnLine(toks, 22):
        if t.tokenType == "variable" and "readonly" notin t.modifiers:
          sawMutableVar = true
      check sawMutableVar

  test "hover and definition sent after a range request are answered":
    # What Monaco does whenever it draws a Nim file: a range request, with
    # the editor's hover and definition requests queued behind it on the same
    # nimsuggest. All three are in flight together; each must be answered.
    withTraceNimsuggest:
      let uri = fixtureUri(fixture)
      let rangeFut = client.call("textDocument/semanticTokens/range", %*{
        "textDocument": {"uri": uri},
        "range": {
          "start": {"line": 0, "character": 0},
          "end":   {"line": 999, "character": 0},
        },
      })
      # `greet` in `discard greet("world")` (0-based line 24, column 8).
      let hoverFut = client.call("textDocument/hover", %positionParams(uri, 24, 8))
      let defFut = client.call("textDocument/definition", %positionParams(uri, 24, 8))

      let tokens = waitFor rangeFut.wait(AnswerTimeout)
      checkpoint "range answer: " & $tokens
      check tokens.kind == JObject and tokens{"data"}.len > 0

      let hover = waitFor hoverFut.wait(AnswerTimeout)
      checkpoint "hover answer: " & $hover
      check hover.kind == JObject
      check ($hover).contains("greet")

      let definition = waitFor defFut.wait(AnswerTimeout)
      checkpoint "definition answer: " & $definition
      check definition.kind == JArray and definition.len > 0
      # The declaration on fixture line 11 (0-based 10).
      check definition.len > 0 and definition[0]{"range", "start", "line"}.getInt(-1) == 10
