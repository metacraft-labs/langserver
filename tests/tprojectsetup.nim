## Tests for how the server maps files to projects, against a real server on
## a socket. "nimble setup" creates its project with the real `nimble init`,
## so it needs a working `nimble` on PATH (see `requireNimble` in
## testhelpers.nim). Nothing is mocked.
import ../[nimlangserver, ls, lstransports, utils]
import ../protocol/[enums, types]
import
  std/
    [
      options, json, os, jsonutils, sequtils, strutils, sugar, strformat
    ]
import json_rpc/[rpcclient]
import chronicles
import lspsocketclient
import testhelpers
import unittest2

suite "nimble setup":
  let cmdParams = CommandLineParams(transport: some socket, port: getNextFreePort())
  let ls = main(cmdParams) #we could accesss to the ls here to test against its state
  let client = newLspSocketClient()
  waitFor client.connect("localhost", cmdParams.port)
  client.registerNotification(
    "window/showMessage", "window/workDoneProgress/create", "workspace/configuration",
    "extension/statusUpdate", "extension/statusUpdate",
    "textDocument/publishDiagnostics", "$/progress",
  )
  let testProjectDir = absolutePath "tests" / "projects" / "testproject"
  # Set by the first case once it has created the project and initialized the
  # server with it; the second case builds on both.
  var projectReady = false

  test "should pick `testproject.nim` as the main file and provide suggestions":
    requireNimble()
    let entryPoint = testProjectDir / "src" / "testproject.nim"
    if not createNimbleProject(testProjectDir):
      failTest("`nimble init` did not create " & testProjectDir)
    let initParams =
      InitializeParams %* {
        "processId": %getCurrentProcessId(),
        "rootUri": fixtureUri("projects/testproject"),
        "capabilities":
          {"window": {"workDoneProgress": true}, "workspace": {"configuration": true}},
      }
    discard waitFor client.initialize(initParams)
    projectReady = true
   
    check waitFor client.waitForNotificationMessage(
      fmt"Nimsuggest initialized for {entryPoint}",
    )

    let completionParams =
      CompletionParams %* {
        "position": {"line": 7, "character": 0},
        "textDocument": {"uri": pathToUri(entryPoint)},
      }
    let ns = waitFor ls.projectFiles[entryPoint].ns
    client.notify(
      "textDocument/didOpen",
      %createDidOpenParams("projects/testproject/src/testproject.nim"),
    )
    check waitFor client.waitForNotification(
      "window/showMessage",
      (json: JsonNode) =>
        json["message"].to(string) == &"Opening {pathToUri(entryPoint)}",
    )

    #We need to make two calls (ns issue)
    discard client.call("textDocument/completion", %completionParams).waitFor
    let completionList = client
      .call("textDocument/completion", %completionParams).waitFor
      .to(seq[CompletionItem])
      .mapIt(it.label)
    check completionList.len > 0

  test "`submodule.nim` should not be part of the nimble project file":
    let submodule = testProjectDir / "src" / "testproject" / "submodule.nim"
    # This case opens a file of the project the previous case creates with
    # `nimble init`, on the server that case initialized. Without both, say so
    # instead of failing with an IOError (or, with a stale project left by an
    # earlier run, sending didOpen to a server that was never initialized).
    if not projectReady:
      failTest(
        "The previous case did not create and open " & testProjectDir &
          " (see its failure)."
      )
    client.notify(
      "textDocument/didOpen",
      %createDidOpenParams("projects/testproject/src/testproject/submodule.nim"),
    )

    check waitFor client.waitForNotification(
      "window/showMessage",
      (json: JsonNode) => json["message"].to(string) == &"Opening {pathToUri(submodule)}",
    )

    check ls.projectFiles.len == 1

suite "Project Mapping":
  let cmdParams = CommandLineParams(transport: some socket, port: getNextFreePort())
  let ls = main(cmdParams) #we could accesss to the ls here to test against its state
  let client = newLspSocketClient()
  waitFor client.connect("localhost", cmdParams.port)
  client.registerNotification(
    "window/showMessage", "window/workDoneProgress/create", "workspace/configuration",
    "extension/statusUpdate", "extension/statusUpdate",
    "textDocument/publishDiagnostics", "$/progress",
  )
  let projectsDir = absolutePath "tests" / "projects"

  test "should use projectMapping fileRegex to find project file":
    let initParams =
      InitializeParams %* {
        "processId": %getCurrentProcessId(),
        "rootUri": fixtureUri("projects"),
        "capabilities":
          {"window": {"workDoneProgress": true}, "workspace": {"configuration": true}},
      }
    discard waitFor client.initialize(initParams)
    let configurationParams =
      @[NlsConfig(projectMapping: some @[NlsNimsuggestConfig(fileRegex: ".nonimble*")])]
    let nonimbleProject = projectsDir / "nonimbleproject.nim"
    ls.workspaceConfiguration.complete(%configurationParams)

    let projectFile = waitFor getProjectFile(pathToUri(nonimbleProject), ls)
    let matchingMsg =
      fmt"RegEx matched `.nonimble*` for file `{nonimbleProject.pathToUri}`"

    check waitFor client.waitForNotification(
      "window/showMessage",
      proc(json: JsonNode): bool =
        json["message"].getStr == matchingMsg,
    )
    let expectedProjectFile = nonimbleProject.pathToUri

    check projectFile == expectedProjectFile
