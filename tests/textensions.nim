## End-to-end tests for the `extension/*` requests, through a real server on
## a socket and the real `nimble`, `nim` and nimsuggest. Nothing is mocked; the
## failure cases use a fixture whose .nimble file really does not evaluate
## (tests/projects/brokentasks) and a PATH that really holds no `nimble`.
## The nimble-dependent cases need a working `nimble` on PATH and fail with
## `nimbleProblem`'s message when there is none (see testhelpers.nim).
import ../[nimlangserver, ls, lstransports, utils]
import ../protocol/[enums, types]
import
  std/[options, json, os, jsonutils, sequtils, strutils, sugar, strformat]
import json_rpc/[rpcclient]
import chronicles
import lspsocketclient
import chronos/asyncproc
import testhelpers
import unittest2

suite "Nimlangserver extensions":
  let cmdParams = CommandLineParams(transport: some socket, port: getNextFreePort())
  let ls = main(cmdParams) #we could accesss to the ls here to test against its state
  let client = newLspSocketClient()
  waitFor client.connect("localhost", cmdParams.port)
  client.registerNotification(
    "window/showMessage", "window/workDoneProgress/create", "workspace/configuration",
    "extension/statusUpdate", "textDocument/publishDiagnostics", "$/progress",
  )

  test "calling extension/suggest with restart in the project uri should restart nimsuggest":
    let initParams =
      InitializeParams %* {
        "processId": %getCurrentProcessId(),
        "rootUri": fixtureUri("projects/hw/"),
        "capabilities":
          {"window": {"workDoneProgress": true}, "workspace": {"configuration": true}},
      }
    let initializeResult = waitFor client.initialize(initParams)

    check initializeResult.capabilities.textDocumentSync.isSome

    let helloWorldUri = fixtureUri("projects/hw/hw.nim")
    let helloWorldFile = "projects/hw/hw.nim"
    let hwAbsFile = uriToPath(helloWorldFile.fixtureUri())
    client.notify("textDocument/didOpen", %createDidOpenParams(helloWorldFile))
    
    check waitFor client.waitForNotificationMessage(
      fmt"Nimsuggest initialized for {hwAbsFile}",
    )

    client.notify(
      "textDocument/didOpen", %createDidOpenParams("projects/hw/useRoot.nim")
    )

    let prevSuggestPid = ls.projectFiles[hwAbsFile].process.pid
    let suggestParams = SuggestParams(action: saRestart, projectFile: hwAbsFile)
    let suggestRes = client.call("extension/suggest", %suggestParams).waitFor
    let suggestPid = ls.projectFiles[hwAbsFile].process.pid

    check prevSuggestPid != suggestPid

  test "calling extension/tasks should return all existing tasks":
    requireNimble()
    let initParams =
      InitializeParams %* {
        "processId": %getCurrentProcessId(),
        "rootUri": fixtureUri("projects/tasks/"),
        "capabilities":
          {"window": {"workDoneProgress": true}, "workspace": {"configuration": true}},
      }
    let initializeResult = waitFor client.initialize(initParams)

    let tasksFile = "projects/tasks/src/tasks.nim"
    let taskAbsFile = uriToPath(tasksFile.fixtureUri())
    client.notify("textDocument/didOpen", %createDidOpenParams(tasksFile))

    let tasks = client.call("extension/tasks", jsonutils.toJson(())).waitFor().jsonTo(
        seq[NimbleTask]
      )

    check tasks.len == 3
    check tasks[0].name == "helloWorld"
    check tasks[0].description == "hello world"

  test "calling extension/tasks when nimble fails should return nimble's error":
    requireNimble()
    # brokentasks.nimble calls an undeclared identifier, so the real
    # `nimble tasks` fails to evaluate it and exits non-zero. The server must
    # report that as a JSON-RPC error carrying nimble's own message rather
    # than answer with an empty task list.
    let initParams =
      InitializeParams %* {
        "processId": %getCurrentProcessId(),
        "rootUri": fixtureUri("projects/brokentasks/"),
        "capabilities":
          {"window": {"workDoneProgress": true}, "workspace": {"configuration": true}},
      }
    discard waitFor client.initialize(initParams)

    var errorMessage = ""
    try:
      let res = client.call("extension/tasks", jsonutils.toJson(())).waitFor()
      checkpoint "extension/tasks answered instead of failing: " & $res
    except JsonRpcError as e:
      errorMessage = e.msg
    checkpoint errorMessage
    check "thisProcDoesNotExistInNimScript" in errorMessage

  test "calling extension/tasks without nimble on PATH should return an error":
    # The server runs in this process, so emptying PATH here leaves it no
    # `nimble` to start. Starting the process then fails; the client must get
    # an error naming the command instead of an empty list or a crash.
    let initParams =
      InitializeParams %* {
        "processId": %getCurrentProcessId(),
        "rootUri": fixtureUri("projects/tasks/"),
        "capabilities":
          {"window": {"workDoneProgress": true}, "workspace": {"configuration": true}},
      }
    discard waitFor client.initialize(initParams)

    let emptyDir = getTempDir() / "nls-no-nimble-tasks-" & $getCurrentProcessId()
    createDir(emptyDir)
    let oldPath = getEnv("PATH")
    putEnv("PATH", emptyDir)
    defer:
      putEnv("PATH", oldPath)
      removeDir(emptyDir)
    var errorMessage = ""
    try:
      let res = client.call("extension/tasks", jsonutils.toJson(())).waitFor()
      checkpoint "extension/tasks answered instead of failing: " & $res
    except JsonRpcError as e:
      errorMessage = e.msg
    checkpoint errorMessage
    check "Could not run `nimble tasks`" in errorMessage

  test "calling extension/listTests should return all existing tests":
    requireNimble()
    #We first need to initialize the nimble project
    let projectDir = getCurrentDir() / "tests" / "projects" / "testrunner"
    cd projectDir:
      let (installOutput, installExit) = execNimbleYes("install", "-l")
      checkpoint installOutput
      if installExit != 0:
        failTest("`nimble install -l` exited with code " & $installExit)
      let (setupOutput, setupExit) = execNimbleYes("setup", "-l")
      checkpoint setupOutput
      if setupExit != 0:
        failTest("`nimble setup -l` exited with code " & $setupExit)

    let initParams =
      InitializeParams %* {
        "processId": %getCurrentProcessId(),
        "rootUri": fixtureUri("projects/testrunner/"),
        "capabilities":
          {"window": {"workDoneProgress": true}, "workspace": {"configuration": true}},
      }
    let initializeResult = waitFor client.initialize(initParams)

    let listTestsParams = ListTestsParams(entryPoint: "tests/projects/testrunner/tests/sampletests.nim".absolutePath)
    let tests = client.call("extension/listTests", jsonutils.toJson(listTestsParams)).waitFor().jsonTo(
        ListTestsResult
      )
    let testProjectInfo = tests.projectInfo
    check testProjectInfo.suites.len == 3
    check testProjectInfo.suites["Sample Tests"].tests.len == 1
    check testProjectInfo.suites["Sample Tests"].tests[0].name == "Sample Test alone"
    check testProjectInfo.suites["Sample Tests"].tests[0].file == "sampletests.nim"
    check testProjectInfo.suites["Sample Tests"].tests[0].line == 4

  test "calling extension/runTests should run the tests and return the results":
    requireNimble() # needs the dependencies listTests installs
    let initParams =
      InitializeParams %* {
        "processId": %getCurrentProcessId(),
        "rootUri": fixtureUri("projects/testrunner/"),
        "capabilities":
          {"window": {"workDoneProgress": true}, "workspace": {"configuration": true}},
      }
    let initializeResult = waitFor client.initialize(initParams)

    let runTestsParams = RunTestParams(entryPoint: "tests/projects/testrunner/tests/sampletests.nim".absolutePath)
    let runTestsRes = client.call("extension/runTests", jsonutils.toJson(runTestsParams)).waitFor().jsonTo(
        RunTestProjectResult
      )
    check runTestsRes.suites.len == 4
    check runTestsRes.suites[0].name == "Sample Tests"
    check runTestsRes.suites[0].tests == 1
    check runTestsRes.suites[0].failures == 0
    check runTestsRes.suites[0].errors == 0
    check runTestsRes.suites[0].skipped == 0
    check runTestsRes.suites[0].time > 0.0 and runTestsRes.suites[0].time < 1.0

  test "calling extension/runTest with a suite name should run the tests in the suite":
    requireNimble() # needs the dependencies listTests installs
    let initParams =
      InitializeParams %* {
        "processId": %getCurrentProcessId(),
        "rootUri": fixtureUri("projects/testrunner/"),
        "capabilities":
          {"window": {"workDoneProgress": true}, "workspace": {"configuration": true}},
      }
    let initializeResult = waitFor client.initialize(initParams)

    let suiteName = "Sample Suite"
    let runTestsParams = RunTestParams(entryPoint: "tests/projects/testrunner/tests/sampletests.nim".absolutePath, suiteName: some suiteName)
    let runTestsRes = client.call("extension/runTests", jsonutils.toJson(runTestsParams)).waitFor().jsonTo(
        RunTestProjectResult
      )
    check runTestsRes.suites.len == 1
    check runTestsRes.suites[0].name == suiteName
    check runTestsRes.suites[0].tests == 3

  test "calling extension/runTest with a test name should run the tests in the suite":
    requireNimble() # needs the dependencies listTests installs
    let initParams =
      InitializeParams %* {
        "processId": %getCurrentProcessId(),
        "rootUri": fixtureUri("projects/testrunner/"),
        "capabilities":
          {"window": {"workDoneProgress": true}, "workspace": {"configuration": true}},
      }
    
    let initializeResult = waitFor client.initialize(initParams)

    let testName = "Sample Test"
    let runTestsParams = RunTestParams(entryPoint: "tests/projects/testrunner/tests/sampletests.nim".absolutePath, testNames: some @[testName])
    let runTestsRes = client.call("extension/runTests", jsonutils.toJson(runTestsParams)).waitFor().jsonTo(RunTestProjectResult)

    check runTestsRes.suites.len == 1
    check runTestsRes.suites[0].tests == 1
    check runTestsRes.suites[0].testResults[0].name == testName

    test "calling extension/runTest with multiple test names should run the tests in the suite":
      requireNimble() # needs the dependencies listTests installs
      let initParams =
        InitializeParams %* {
          "processId": %getCurrentProcessId(),
          "rootUri": fixtureUri("projects/testrunner/"),
          "capabilities":
            {"window": {"workDoneProgress": true}, "workspace": {"configuration": true}},
        }
      let initializeResult = waitFor client.initialize(initParams)

      let testNames = @["Sample Test", "Sample Test 2"]
      let runTestsParams = RunTestParams(entryPoint: "tests/projects/testrunner/tests/sampletests.nim".absolutePath, testNames: some testNames)
      let runTestsRes = client.call("extension/runTests", jsonutils.toJson(runTestsParams)).waitFor().jsonTo(RunTestProjectResult)

    check runTestsRes.suites.len == 1
  #   check runTestsRes.suites[0].tests == 2

  test "calling extension/runTest with a failing test should return the failure":
    requireNimble() # needs the dependencies listTests installs
    let initParams =
      InitializeParams %* {
        "processId": %getCurrentProcessId(),
        "rootUri": fixtureUri("projects/testrunner/"),
        "capabilities":
          {"window": {"workDoneProgress": true}, "workspace": {"configuration": true}},
      }
      
    let initializeResult = waitFor client.initialize(initParams)

    let runTestsParams = RunTestParams(entryPoint: "tests/projects/testrunner/tests/failingtest.nim".absolutePath)
    let runTestsRes = client.call("extension/runTests", jsonutils.toJson(runTestsParams)).waitFor().jsonTo(RunTestProjectResult)

    check runTestsRes.suites.len == 1
    check runTestsRes.suites[0].name == "Failing Tests"
    check runTestsRes.suites[0].tests == 2
    check runTestsRes.suites[0].failures == 1
    check runTestsRes.suites[0].testResults[0].name == "Failing Test"
    check runTestsRes.suites[0].testResults[0].failure.isSome
