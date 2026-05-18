## Microbenchmark suite for `semantic_tokens.nim`.
##
## Asserts P95 latency for each measured operation against a hard target.
## A regression that drives one operation past its budget fails the
## process — keep targets sized for cold CI; if a benchmark fails on a
## developer laptop, investigate before bumping.
##
## Results are also emitted in CSV form to stdout so we can graph them
## in CI dashboards (`benchmark,p50_ms,p95_ms,p95_target_ms,verdict`).

import ../semantic_tokens
import std/[algorithm, monotimes, strformat, strutils, times]

# Wall-clock with monotonic source.  We use `monotimes` rather than
# `epochTime` so that NTP slews don't introduce false regressions during
# overnight runs.
proc nowMs(): float =
  float(ticks(getMonoTime()).int64) / 1_000_000.0

# ---------------------------------------------------------------------------
# Stat helpers
# ---------------------------------------------------------------------------

type
  BenchResult = object
    name: string
    p50, p95: float
    p95Target: float

proc percentile(xs: seq[float], p: float): float =
  doAssert xs.len > 0
  var sorted = xs
  sort(sorted, system.cmp[float])
  let idx = min(int(float(sorted.len - 1) * p), sorted.len - 1)
  sorted[idx]

template measure(benchName, iterations, body: untyped): BenchResult =
  ## Run `body` `iterations` times, returning a `BenchResult` populated
  ## with name + percentiles.  Caller must set `p95Target` afterwards.
  block:
    var samples = newSeq[float](iterations)
    for sampleIdx in 0 ..< iterations:
      let t0 = nowMs()
      body
      samples[sampleIdx] = nowMs() - t0
    BenchResult(name: benchName,
                p50: percentile(samples, 0.50),
                p95: percentile(samples, 0.95))

proc report(r: BenchResult) =
  let verdict = if r.p95 <= r.p95Target: "PASS" else: "FAIL"
  echo &"{r.name},{r.p50:.3f},{r.p95:.3f},{r.p95Target:.3f},{verdict}"

proc assertBudget(r: BenchResult) =
  if r.p95 > r.p95Target:
    quit("BUDGET VIOLATION: " & r.name &
         " p95=" & r.p95.formatFloat(ffDecimal, 3) & "ms > target=" &
         r.p95Target.formatFloat(ffDecimal, 3) & "ms", 2)

# ---------------------------------------------------------------------------
# Workloads
# ---------------------------------------------------------------------------

const SymKinds = [
  "skProc", "skFunc", "skMethod", "skIterator", "skConverter",
  "skMacro", "skTemplate", "skType", "skVar", "skLet", "skConst",
  "skResult", "skParam", "skField", "skEnumField", "skModule",
  "skLabel", "skGenericParam", "skForVar",
]

proc buildTokens(n: int): seq[TokenInput] =
  ## Synthetic but realistic workload: column-step 4, line every 8 tokens,
  ## token type cycling across the legend.  Includes a few SkipToken
  ## entries to exercise the filter path.
  result = newSeqOfCap[TokenInput](n)
  let fnIdx = indexOfTokenType("function")
  for i in 0 ..< n:
    let lin = (i div 8) + 1
    let col = (i mod 8) * 4
    let tt = if i mod 50 == 49: SkipToken else: ((fnIdx + int32(i mod 8)) mod
                                                  int32(SemanticTokenTypes.len))
    result.add(TokenInput(
      line: lin, startChar: col, length: 3,
      tokenType: tt,
      tokenModifiers: if i mod 5 == 0: 1'u32 shl 2 else: 0'u32,
    ))

# ---------------------------------------------------------------------------
# Benchmarks
# ---------------------------------------------------------------------------

proc main() =
  echo "benchmark,p50_ms,p95_ms,p95_target_ms,verdict"

  var results: seq[BenchResult]

  # 1. SymKind → token type — 1M lookups per sample.
  block:
    var r = measure("mapSymKindToTokenType_1M", 100):
      var sum: int64 = 0
      for i in 0 ..< 1_000_000:
        sum += mapSymKindToTokenType(SymKinds[i mod SymKinds.len]).int64
      doAssert sum != 0 # keep optimiser honest
    r.p95Target = 100.0
    report(r)
    results.add(r)

  # 2/3/4. Delta-encode 1k / 10k / 100k tokens.
  for (n, p95Target) in [(1_000, 3.0), (10_000, 30.0), (100_000, 300.0)]:
    let tokens = buildTokens(n)
    var r = measure("encodeSemanticTokens_" & $n, 100):
      let data = encodeSemanticTokens(tokens)
      doAssert data.len mod 5 == 0
    r.p95Target = p95Target
    report(r)
    results.add(r)

  # Enforce budgets.  Run AFTER printing all rows so the CSV is complete
  # in CI logs even when one row regressed.
  for r in results:
    assertBudget(r)

  echo "ALL BUDGETS PASSED"

when isMainModule:
  main()
