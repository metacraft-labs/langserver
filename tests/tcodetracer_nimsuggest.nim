## Which nimsuggest serves a client that names none, and what happens when a
## client names one after a nimsuggest is already running.
##
## CodeTracer's desktop answers `workspace/configuration` without a
## `nimsuggestPath`. The server then ran the `PATH` nimsuggest, which in the
## CodeTracer dev shell is stock Nim's: it has no `traceStatic` /
## `traceExpand`, so every `nim/traceStaticBlock` answered "No trace result
## at this position" and no recording was written. The dev shell names its
## trace-enabled nimsuggest in `CODETRACER_NIMSUGGEST`; the server now uses
## that one when the configuration names none.
##
## Nothing is mocked. The first suite is the pure resolution. The second runs
## the real server over its real socket transport, with the real trace-enabled
## nimsuggest (`CODETRACER_NIMSUGGEST`, else the sibling codetracer-nim build
## `trace_test_config` names), and requires the recording to be written. It
## skips only when no trace-enabled nimsuggest exists on this machine, and
## says so; a "No trace result" answer FAILS here, unlike in
## `test_trace_static.nim`, whose skip on that answer hid this defect.
import ../[nimlangserver, ls, lstransports, utils]
import ../protocol/[enums, types]
import std/[options, json, os, strutils, strformat]
import json_rpc/[rpcclient]
import chronicles
import lspsocketclient
import unittest2
import trace_test_config

suite "the nimsuggest a configuration asks for":
  let saved = getEnv(CodetracerNimsuggestVar)
  let dir = getTempDir() / ("nls-ct-nimsuggest-" & $getCurrentProcessId())
  createDir(dir)
  let present = dir / "nimsuggest"
  writeFile(present, "")

  teardown:
    if saved.len > 0: putEnv(CodetracerNimsuggestVar, saved)
    else: delEnv(CodetracerNimsuggestVar)

  test "a configuration that names none gets CodeTracer's":
    putEnv(CodetracerNimsuggestVar, present)
    check configuredNimsuggestPath(NlsConfig()) == present

  test "a configuration that names one keeps it":
    putEnv(CodetracerNimsuggestVar, present)
    let conf = NlsConfig(nimsuggestPath: some("/opt/nim/bin/nimsuggest"))
    check configuredNimsuggestPath(conf) == "/opt/nim/bin/nimsuggest"

  test "a variable naming no file is ignored":
    putEnv(CodetracerNimsuggestVar, dir / "absent")
    check configuredNimsuggestPath(NlsConfig()) == ""
    delEnv(CodetracerNimsuggestVar)
    check configuredNimsuggestPath(NlsConfig()) == ""

  removeDir(dir)

suite "a client that names no nimsuggest traces a static block":
  let traceNs = traceNimsuggest()
  let saved = getEnv(CodetracerNimsuggestVar)
  if traceNs.len > 0:
    putEnv(CodetracerNimsuggestVar, traceNs)
  let cmdParams = CommandLineParams(transport: some socket, port: getNextFreePort())
  let ls = main(cmdParams)
  let client = newLspSocketClient()
  # What CodeTracer's desktop answers: a `nim` section with no nimsuggestPath.
  client.register(
    "workspace/configuration",
    proc(params: JsonNode): Future[JsonNode] {.async.} =
      return %*[{}],
  )
  client.registerNotification(
    "window/showMessage", "window/workDoneProgress/create",
    "extension/statusUpdate", "textDocument/publishDiagnostics", "$/progress",
  )
  waitFor client.connect("localhost", cmdParams.port)
  discard waitFor client.initialize(
    InitializeParams %* {
      "processId": %getCurrentProcessId(),
      "rootUri": fixtureUri("projects/statictest/"),
      "capabilities": {
        "window": {"workDoneProgress": true}, "workspace": {"configuration": true}
      },
    }
  )
  client.notify("initialized", newJObject())

  teardown:
    if saved.len > 0: putEnv(CodetracerNimsuggestVar, saved)
    else: delEnv(CodetracerNimsuggestVar)

  test "nim/traceStaticBlock writes the recording":
    if traceNs.len == 0:
      checkpoint "no trace-enabled nimsuggest: set " & CodetracerNimsuggestVar &
        " or build ../codetracer-nim/bin/nimsuggest"
      skip()
    else:
      let staticFile = "projects/statictest/statictest.nim"
      client.notify("textDocument/didOpen", %createDidOpenParams(staticFile))
      let absFile = staticFile.fixtureUri.uriToPath
      check waitFor client.waitForNotificationMessage(
        fmt "Nimsuggest initialized for {absFile}"
      )
      # The block's first statement, zero-based, as the desktop sends it.
      let res = waitFor client.call(
        "workspace/executeCommand",
        %*{
          "command": "nim/traceStaticBlock",
          "arguments": [{"uri": fixtureUri(staticFile), "line": 3, "character": 2}],
        },
      )
      checkpoint "answer: " & $res
      check res.kind == JObject and res.hasKey("tracePath")
      let tracePath = res{"tracePath"}.getStr
      check tracePath.endsWith(".ct")
      check fileExists(tracePath)
