import std/[os, osproc, sequtils, strutils, sugar]
import unittest2

template cd*(dir: string, body: untyped) =
  ## Sets the current dir to ``dir``, executes ``body`` and restores the
  ## previous working dir.
  let lastDir = getCurrentDir()
  setCurrentDir(dir)
  block:
    defer:
      setCurrentDir(lastDir)
    body

template createNewDir*(dir: string) =
  removeDir dir
  createDir dir

template cdNewDir*(dir: string, body: untyped) =
  createNewDir dir
  cd dir:
    body

let
  rootDir = getCurrentDir()
  nimblePath* = findExe "nimble"
  installDir* = rootDir / "tests" / "nimbleDir"

type ProcessOutput* = tuple[output: string, exitCode: int]

const nimbleRequirement* =
  "The nimble-dependent tests need a working `nimble` on PATH: the one " &
  "dev-setup/nix pins (nim-lang/nimble b2f9acc, 0.15.0-dev). Enter it with " &
  "`nix develop ./dev-setup/nix` and run `nimble test` or ./tests/all inside " &
  "it; nimble 0.20.1 is also verified to work."

proc nimbleProblem*(): string =
  ## Returns "" when `nimble` resolves on PATH and `nimble --version` exits 0.
  ## Otherwise returns what was found (the path or none, the exit code and the
  ## output) followed by `nimbleRequirement`, so a failing case says which
  ## nimble the suite needs instead of failing further down.
  ## The lookup is done on every call (not cached in `nimblePath`) so it
  ## reflects the PATH at the time of the call.
  let exe = findExe("nimble")
  if exe.len == 0:
    return "No `nimble` found on PATH (" & getEnv("PATH") & "). " &
      nimbleRequirement
  let (output, exitCode) =
    try:
      execCmdEx(quoteShell(exe) & " --version")
    except CatchableError as e:
      (e.msg, -1)
  if exitCode != 0:
    return "`" & exe & " --version` exited with code " & $exitCode & ":\n" &
      output & "\n" & nimbleRequirement

template failTest*(reason: string) =
  ## Fails the current unittest2 case with `reason` and leaves it, while the
  ## run goes on. `require` is not used for this because it sets
  ## `abortOnError` and quits the program: the case is not even reported and
  ## no later case runs. The test body becomes the body of the proc unittest2
  ## generates, whose result is the reported status, so a bare `return` would
  ## report OK; hence the explicit FAILED.
  checkpoint(reason)
  fail()
  return TestStatus.FAILED

template requireNimble*() =
  ## Guard for cases that need a working `nimble`: fails the case at once with
  ## the `nimbleProblem` message rather than letting it cascade into
  ## timeouts and unrelated exceptions. A missing prerequisite stays FAILED,
  ## never SKIPPED.
  let problem = nimbleProblem()
  if problem.len > 0:
    failTest(problem)

proc execNimble*(args: varargs[string]): ProcessOutput =
  var quotedArgs = @args
  if not args.anyIt("--nimbleDir:" in it or "-l" == it or "--local" == it):
    quotedArgs.insert("--nimbleDir:" & installDir)
  quotedArgs.insert(nimblePath)
  quotedArgs = quotedArgs.map((x: string) => x.quoteShell)

  let path {.used.} = getCurrentDir().parentDir() / "src"

  var cmd =
    when not defined(windows):
      "PATH=" & path & ":$PATH " & quotedArgs.join(" ")
    else:
      quotedArgs.join(" ")
  when defined(macosx):
    # TODO: Yeah, this is really specific to my machine but for my own sanity...
    cmd = "DYLD_LIBRARY_PATH=/usr/local/opt/openssl@1.1/lib " & cmd

  result = execCmdEx(cmd)
  if result.exitCode != 0:
    echo "Nimble fixture command failed: ", cmd, "\n", result.output
  checkpoint(cmd)
  checkpoint(result.output)

proc execNimbleYes*(args: varargs[string]): ProcessOutput =
  execNimble(@args & "-y")

proc createNimbleProject*(projectDir: string): bool =
  ## Runs `nimble init` in a fresh `projectDir`; returns whether it succeeded
  ## so the caller can stop instead of testing a project that does not exist.
  cdNewDir projectDir:
    let (output, exitCode) = execNimbleYes("init")
    check exitCode == 0
    result = exitCode == 0
