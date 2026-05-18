## Fixture for `textDocument/semanticTokens/range` integration tests.
## Each symbol is positioned at a known line/column so the test suite can
## make line-based assertions without re-parsing the file.

import std/strutils

type
  Foo* = object
    bar*: int

proc greet*(name: string): string =
  let prefix = "hi "
  result = prefix & name

template withFoo*(x: int, body: untyped) =
  body

macro myMacro*(x: int): untyped =
  discard

const PI* = 3.14
var counter* = 0

# A non-trivial use of greet so nimsuggest actually sees a reference.
discard greet("world")
discard counter
discard PI
discard repeat("ab", 2)
