## Configuration for integration tests against the real CodeTracer compiler.
## No compiler or transport is mocked: this answers the client's normal LSP
## configuration request with the sibling compiler's built nimsuggest path.
import std/[json, os, options]
import ../ls
import chronos

const resolvedTraceNimsuggestPath* = normalizedPath(
  currentSourcePath().parentDir().parentDir().parentDir() /
  "codetracer-nim" / "bin" / "nimsuggest")

proc traceConfigHandler*(params: JsonNode): Future[JsonNode] {.async, gcsafe.} =
  {.cast(gcsafe).}:
    return %*[{"nimsuggestPath": resolvedTraceNimsuggestPath}]

proc awaitTraceConfiguration*(server: LanguageServer): Future[void] {.async.} =
  ## Let the real configuration round trip finish before opening a document.
  ## The server otherwise starts nimsuggest with its default configuration.
  for attempt in 0 ..< 500:
    let config = await server.getWorkspaceConfiguration()
    if config.nimsuggestPath.get("") == resolvedTraceNimsuggestPath:
      return
    await sleepAsync(10.milliseconds)
  raise newException(IOError, "trace nimsuggest configuration was not received")
