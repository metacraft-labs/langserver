## Trace queries around a nimsuggest restart.
##
## A configuration that names a different nimsuggest restarts the running one
## (`restartNimsuggestOnPathChange`). Two things went wrong around that
## restart:
##
## * A `nim/traceStaticBlock` that arrived while the restart was still
##   starting the new nimsuggest was served by the OLD one. When the old one is
##   the stock nimsuggest (no `traceStatic`), the answer was "No trace result
##   at this position" although the server was, at that moment, bringing up
##   the nimsuggest that can answer it. This is the desktop's own sequence
##   whenever its configuration answer arrives after a document is open.
## * Stopping the old process on purpose was reported as a crash: its stderr
##   closing marked the project failed, which recorded a project error and
##   restarted the project a SECOND time, replacing (and killing) the instance
##   the first restart had just started, including any query running on it.
##
## Nothing is mocked. The real server runs over its real socket transport with
## real nimsuggest processes: the stock one on `PATH` and the trace-enabled one
## (`CODETRACER_NIMSUGGEST`, else the sibling codetracer-nim build). The second
## case names the trace-enabled binary twice, through a symlink, so either
## instance can answer and only the restart itself can make the query fail.
## The server object is read in process to observe which instance served the
## query; every request and answer goes through the socket.
import ../[nimlangserver, ls, lstransports, suggestapi, utils]
import ../protocol/[enums, types]
import std/[options, json, os, strutils, strformat, tables]
import json_rpc/[rpcclient]
import chronicles
import lspsocketclient
import unittest2
import trace_test_config

const StaticFile = "projects/statictest/statictest.nim"

proc traceRequest(): JsonNode =
  ## The block's first statement, zero-based, as the desktop sends it.
  %*{
    "command": "nim/traceStaticBlock",
    "arguments": [{"uri": fixtureUri(StaticFile), "line": 3, "character": 2}],
  }

proc answerOf(fut: Future[JsonNode]): JsonNode =
  try:
    waitFor fut
  except CatchableError as e:
    %*{"error": e.msg}

template startServer(configured: untyped): untyped =
  ## A server over a socket, and a client answering `workspace/configuration`
  ## with whatever `configured` holds at the moment it is asked.
  let cmdParams = CommandLineParams(transport: some socket, port: getNextFreePort())
  let server = main(cmdParams)
  let client = newLspSocketClient()
  client.register(
    "workspace/configuration",
    proc(params: JsonNode): Future[JsonNode] {.async.} =
      {.cast(gcsafe).}:
        return %*[{"nimsuggestPath": configured}],
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
  (server, client)

proc openStaticFile(client: LspSocketClient): string =
  let absFile = StaticFile.fixtureUri.uriToPath
  client.notify("textDocument/didOpen", %createDidOpenParams(StaticFile))
  check waitFor client.waitForNotificationMessage(
    fmt "Nimsuggest initialized for {absFile}"
  )
  absFile

proc nameNimsuggest(client: LspSocketClient, path: string) =
  client.notify(
    "workspace/didChangeConfiguration",
    %*{"settings": {"nim": {"nimsuggestPath": path}}},
  )

let traceNs = traceNimsuggest()

var configurationGate = newFuture[void]("configurationGate")
  ## Held open by the first case until the document's nimsuggest is running,
  ## so the configuration answer arrives late, as the desktop's can.

suite "a trace query that arrives while nimsuggest restarts":
  # No CODETRACER_NIMSUGGEST: before the configuration arrives the server runs
  # the nimsuggest it finds itself, a stock one that answers no trace query.
  # The configuration then names the trace-enabled one.
  let savedVar = getEnv(CodetracerNimsuggestVar)
  delEnv(CodetracerNimsuggestVar)
  let cmdParams = CommandLineParams(transport: some socket, port: getNextFreePort())
  let server = main(cmdParams)
  let client = newLspSocketClient()
  client.register(
    "workspace/configuration",
    proc(params: JsonNode): Future[JsonNode] {.async.} =
      {.cast(gcsafe).}:
        await configurationGate
        return %*[{"nimsuggestPath": traceNs}],
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
    if savedVar.len > 0: putEnv(CodetracerNimsuggestVar, savedVar)

  test "waits for the restarted nimsuggest and is answered by it":
    if traceNs.len == 0:
      checkpoint "no trace-enabled nimsuggest: set " & CodetracerNimsuggestVar &
        " or build ../codetracer-nim/bin/nimsuggest"
      configurationGate.complete()
      skip()
    else:
      let absFile = client.openStaticFile()
      let first = waitFor server.projectFiles[absFile].ns
      checkpoint "running before the configuration: " & first.nimSuggestPath
      check first.nimSuggestPath != traceNs
      # The configuration answer and the query are sent back to back: the
      # query reaches the server while the restart the answer causes is still
      # starting the trace-enabled nimsuggest.
      configurationGate.complete()
      let res = answerOf client.call("workspace/executeCommand", traceRequest())
      checkpoint "answer: " & $res
      check res.kind == JObject and res.hasKey("tracePath")
      check fileExists(res{"tracePath"}.getStr)
      let current = waitFor server.projectFiles[absFile].ns
      check current.nimSuggestPath == traceNs

suite "a trace query in flight when its nimsuggest is restarted":
  let altDir = getTempDir() / ("nls-restart-" & $getCurrentProcessId())
  let altNs = altDir / "nimsuggest"
  if traceNs.len > 0:
    createDir(altDir)
    if symlinkExists(altNs): removeFile(altNs)
    createSymlink(traceNs, altNs)
  var configured = traceNs
  let (server, client) = startServer(configured)

  test "is answered, and the restart happens once and is not a crash":
    if traceNs.len == 0:
      checkpoint "no trace-enabled nimsuggest: set " & CodetracerNimsuggestVar &
        " or build ../codetracer-nim/bin/nimsuggest"
      skip()
    else:
      let absFile = client.openStaticFile()
      let first = waitFor server.projectFiles[absFile].ns
      check first.nimSuggestPath == traceNs

      let answer = client.call("workspace/executeCommand", traceRequest())
      # Wait until the query has reached the running nimsuggest, then name
      # another path to it.
      var waited = 0
      while not first.project.lastCmd.startsWith("traceStatic") and waited < 2000:
        waitFor sleepAsync(5.milliseconds)
        inc waited
      checkpoint "in flight on the first instance: " & first.project.lastCmd
      check first.project.lastCmd.startsWith("traceStatic")
      configured = altNs
      client.nameNimsuggest(altNs)

      let res = answerOf answer
      checkpoint "answer: " & $res
      check res.kind == JObject and res.hasKey("tracePath")
      check fileExists(res{"tracePath"}.getStr)

      let current = waitFor server.projectFiles[absFile].ns
      check current != first
      check current.nimSuggestPath == altNs
      # Long enough for the stopped process's exit to be noticed.
      waitFor sleepAsync(1500.milliseconds)
      check (waitFor server.projectFiles[absFile].ns) == current
      checkpoint "project errors: " & $server.projectErrors.len
      check server.projectErrors.len == 0

  if traceNs.len > 0:
    removeDir(altDir)
