## The nimsuggest request queue keeps answering after a request whose answer
## cannot be parsed.
##
## `Nimsuggest.call` queues every request to one nimsuggest and a single
## `processQueue` loop sends them one at a time. A parse error in one answer
## (`parseEnum` on an unknown section, `parseSuggestInlayHint` on a malformed
## hint row) used to escape that loop: the request's future was never
## finished and `processing` stayed set, so every later request to that
## nimsuggest waited forever. That is how one `textDocument/semanticTokens/range`
## request stopped hover, definition and completion for the whole editor.
##
## Why a stand-in peer instead of a real nimsuggest: the stand-in is a plain
## TCP listener on 127.0.0.1 that answers each connection with a fixed text,
## the same wire contract `processQueue` uses with nimsuggest's `--autobind`
## port (one command line in, rows until the socket closes). No real
## nimsuggest emits an unparsable row for a verb the server supports any more
## (`test_semantic_tokens_integration.nim` covers the real `highlightRange`
## path end to end), so a fixed answer is the only way to drive the queue's
## failure path. Everything above the socket -- the queue, the parsers, the
## futures -- is the production code.
import ../suggestapi
import std/[options, strutils]
import chronos
import unittest2

const AnswerTimeout = chronos.seconds(10)

proc serveAnswers(answers: seq[string]): StreamServer =
  ## Answer the n-th connection with `answers[n]` (the last one repeats),
  ## after reading the command line, then close it.
  var served = 0
  proc handle(server: StreamServer, conn: StreamTransport) {.async: (raises: []).} =
    let answer = answers[min(served, answers.high)]
    inc served
    try:
      discard await conn.readLine()
      discard await conn.write(answer)
    except CatchableError:
      discard
    await conn.closeWait()
  result = createStreamServer(initTAddress("127.0.0.1:0"), handle, {ReuseAddr})
  result.start()

proc stopServing(server: StreamServer) =
  ## Stop listening without waiting for open connections: a queue that died
  ## mid-request leaves its connection open, and waiting on it would hang the
  ## run instead of reporting the failed checks.
  server.stop()
  server.close()

proc nimsuggestAt(server: StreamServer): Nimsuggest =
  Nimsuggest(port: int(server.localAddress.port), project: Project())

const
  ValidDefRow = "def\tskProc\thw.a\tproc ()\t/hw.nim\t1\t5\t\"\"\n"
  MalformedHintRow = "Type\tnot-a-line\t5\tint\tfalse\tfalse\tfalse\t\"\"\n"

suite "the nimsuggest request queue":
  test "a request whose answer cannot be parsed fails, and the next is answered":
    let server = serveAnswers(@[MalformedHintRow, ValidDefRow])
    let ns = nimsuggestAt(server)
    let broken = ns.call("inlayHints", "/hw.nim", "", 1, 0, ":2:0")
    let next = ns.call("def", "/hw.nim", "", 1, 5)

    check waitFor broken.withTimeout(AnswerTimeout)
    check broken.failed
    if broken.failed:
      check broken.error.msg.contains("not-a-line")

    check waitFor next.withTimeout(AnswerTimeout)
    check next.completed
    if next.completed:
      let rows = next.read()
      check rows.len == 1
      check rows.len == 1 and rows[0].qualifiedPath == @["hw", "a"]

    stopServing(server)

  test "a row with an unknown section is dropped and the queue keeps going":
    let unknownRow = "someFutureVerb\tskProc\thw.b\tproc ()\t/hw.nim\t2\t5\t\"\"\n"
    let server = serveAnswers(@[unknownRow & ValidDefRow, ValidDefRow])
    let ns = nimsuggestAt(server)
    let first = ns.call("def", "/hw.nim", "", 1, 5)
    let second = ns.call("def", "/hw.nim", "", 1, 5)

    check waitFor first.withTimeout(AnswerTimeout)
    check first.completed
    if first.completed:
      check first.read().len == 1
    check waitFor second.withTimeout(AnswerTimeout)
    check second.completed

    stopServing(server)
