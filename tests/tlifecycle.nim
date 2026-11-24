## Tests for what the server does with messages that arrive before
## `initialize`, against a real server on a socket. Nothing is mocked.
##
## LSP 3.17, "Initialize Request"
## (https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#initialize):
## until the server has answered `initialize`, it errors every request with
## `ServerNotInitialized` (-32002) and drops every notification except `exit`.
## The server used to run the handlers instead; `didOpen` then dereferenced the
## nil `initializeParams` and the process died with SIGSEGV. That crash takes
## the whole test process with it, so the first case fails by crashing.
import ../[nimlangserver, ls, utils]
import ../protocol/[enums, types]
import std/[options, json, os, tables]
import json_rpc/[rpcclient]
import chronicles
import lspsocketclient
import unittest2

suite "messages before initialize":
  let cmdParams = CommandLineParams(transport: some socket, port: getNextFreePort())
  let ls = main(cmdParams)
  let client = newLspSocketClient()
  waitFor client.connect("localhost", cmdParams.port)
  client.registerNotification(
    "window/showMessage", "window/workDoneProgress/create", "workspace/configuration",
    "extension/statusUpdate", "textDocument/publishDiagnostics", "$/progress",
  )
  let hwFile = "projects/hw/hw.nim"
  let hwUri = fixtureUri(hwFile)
  let hoverParams = %positionParams(hwUri, 0, 0)

  test "a didOpen notification before initialize is dropped":
    waitFor client.sendNotification("textDocument/didOpen", %createDidOpenParams(hwFile))
    # The server reads one socket in order, so once a later request has been
    # answered, the notification has been processed too.
    let error = waitFor client.callError("textDocument/hover", hoverParams)
    check error != nil
    check ls.openFiles.len == 0
    check ls.projectFiles.len == 0

  test "a request before initialize is answered with ServerNotInitialized":
    let error = waitFor client.callError("textDocument/hover", hoverParams)
    check error != nil
    if error != nil:
      check error["code"].getInt == ServerNotInitialized.int
    # An unknown method is a request all the same.
    let unknown = waitFor client.callError("extension/noSuchMethod", %*{})
    check unknown != nil
    if unknown != nil:
      check unknown["code"].getInt == ServerNotInitialized.int

  test "after initialize, the same notification is handled":
    let initParams =
      InitializeParams %* {
        "processId": %getCurrentProcessId(),
        "rootUri": fixtureUri("projects/hw/"),
        "capabilities":
          {"window": {"workDoneProgress": true}, "workspace": {"configuration": true}},
      }
    discard waitFor client.initialize(initParams)
    check not ls.initializeParams.isNil
    waitFor client.sendNotification("textDocument/didOpen", %createDidOpenParams(hwFile))
    # `didOpenFile` records the file before its first suspension point, so a
    # request answered after the notification proves it ran. `extension/status`
    # touches no nimsuggest, so it answers at once.
    discard waitFor client.call("extension/status", %*{})
    check hwUri in ls.openFiles
