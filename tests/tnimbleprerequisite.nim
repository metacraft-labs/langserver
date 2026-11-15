## Tests for the probe that tells the suite whether its `nimble` prerequisite
## is met.
##
## The nimble-dependent cases (project setup, `extension/tasks`, the test
## runner) need a working `nimble` on the PATH. Without one they used to
## cascade into timeouts, KeyError, IOError and IndexDefect, and never said
## what was missing. `nimbleProblem` turns that into one message.
##
## Nothing is mocked: the first case points the real PATH at an empty folder,
## so the real `findExe` finds no `nimble`; the second probes whatever `nimble`
## the suite is running with, and so fails when the prerequisite is not met.
import std/[os, strutils]
import testhelpers
import unittest2

suite "Nimble prerequisite probe":
  test "names nimble and the dev shell to use when PATH holds no nimble":
    let emptyDir = getTempDir() / "nls-no-nimble-" & $getCurrentProcessId()
    createDir(emptyDir)
    let oldPath = getEnv("PATH")
    putEnv("PATH", emptyDir)
    defer:
      putEnv("PATH", oldPath)
      removeDir(emptyDir)
    let problem = nimbleProblem()
    checkpoint problem
    check "nimble" in problem
    check "dev-setup/nix" in problem

  test "is empty when a working nimble is on PATH":
    let problem = nimbleProblem()
    checkpoint problem
    check problem == ""
