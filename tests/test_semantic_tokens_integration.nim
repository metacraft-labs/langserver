## End-to-end tests for `textDocument/semanticTokens/range`.
##
## Boots a real nimlangserver subprocess (via `nimlangserver.main`) over a
## socket transport, opens the fixture in `tests/projects/semantic_tokens_fixture`,
## and asserts the on-wire payload matches our SymKind → token-type
## mapping.
##
## These tests depend on a nimsuggest binary that supports the
## `highlightRange` ide-command introduced in codetracer-nim.  When the
## binary on `$PATH` does not, the response is empty and the per-symbol
## assertions skip with a checkpoint so the suite stays green on machines
## without our fork installed.

import ../[nimlangserver, ls, lstransports, utils, semantic_tokens]
import ../protocol/types
import std/[options, json, os, strformat, sets]
import chronos
import lspsocketclient
import unittest2

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
  let nsReady = waitFor client.waitForNotificationMessage(
    fmt "Nimsuggest initialized for {absFile}"
  )

  proc requestTokens(rangeJson: JsonNode): seq[DecodedTok] =
    let params = %*{
      "textDocument": {"uri": fixtureUri(fixture)},
      "range": rangeJson,
    }
    let raw = waitFor client.call("textDocument/semanticTokens/range", params)
    check raw.kind == JObject
    check raw.hasKey("data")
    var data = newSeq[uint32]()
    for v in raw["data"].items:
      data.add(uint32(v.getInt))
    return decodeWire(data)

  test "wide range returns a token sequence sorted by (line, char)":
    if not nsReady:
      skip()
      return
    let toks = requestTokens(%*{
      "start": {"line": 0, "character": 0},
      "end":   {"line": 999, "character": 0},
    })
    if toks.len == 0:
      checkpoint "no tokens received — nimsuggest may lack highlightRange"
      skip()
      return
    for i in 1 ..< toks.len:
      check (toks[i - 1].line < toks[i].line) or
            (toks[i - 1].line == toks[i].line and
             toks[i - 1].startChar <= toks[i].startChar)

  test "determinism: same request twice yields byte-identical payload":
    if not nsReady:
      skip()
      return
    let params = %*{
      "textDocument": {"uri": fixtureUri(fixture)},
      "range": {
        "start": {"line": 0, "character": 0},
        "end":   {"line": 999, "character": 0},
      },
    }
    let a = waitFor client.call("textDocument/semanticTokens/range", params)
    let b = waitFor client.call("textDocument/semanticTokens/range", params)
    check a == b

  test "range narrowing returns only tokens inside the requested interval":
    if not nsReady:
      skip()
      return
    # Lines 10–13 contain the `greet` definition + body.
    let narrow = requestTokens(%*{
      "start": {"line": 10, "character": 0},
      "end":   {"line": 13, "character": 0},
    })
    if narrow.len == 0:
      checkpoint "narrow request returned no tokens"
      skip()
      return
    for t in narrow:
      # nimsuggest is 1-based; LSP range is 0-based.  Allow ±1 slack for
      # closing positions that nimsuggest may report at the edge.
      check t.line >= 10
      check t.line <= 14

  test "malformed range produces an empty (non-crashing) response":
    if not nsReady:
      skip()
      return
    # end < start — encoder should still return a well-formed payload.
    let raw = waitFor client.call("textDocument/semanticTokens/range", %*{
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
    let raw = waitFor client.call("textDocument/semanticTokens/range", %*{
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
    if not nsReady:
      skip()
      return
    let toks = requestTokens(%*{
      "start": {"line": 0, "character": 0},
      "end":   {"line": 999, "character": 0},
    })
    if toks.len == 0:
      checkpoint "no tokens received from nimsuggest"
      skip()
      return

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
