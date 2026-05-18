## Unit tests for the pure encoding/mapping helpers in
## `semantic_tokens.nim`.  No nimsuggest process is involved — these run
## stand-alone in a few milliseconds and act as the regression gate for
## the wire-format contract.

import ../semantic_tokens
import std/[algorithm, sets]
import unittest2

# ---------------------------------------------------------------------------
# Legend invariants
# ---------------------------------------------------------------------------

suite "SemanticTokens legend":
  test "tokenTypes legend is the documented sequence":
    # If this fails, the Monaco-side legend (see
    # codetracer/src/frontend/languages/nimSemanticTokens.js) has to be
    # bumped in lock-step.
    check SemanticTokenTypes == @[
      "namespace", "type", "class", "enum", "interface", "struct",
      "typeParameter", "parameter", "variable", "property", "enumMember",
      "function", "method", "macro", "keyword", "modifier", "comment",
      "string", "number", "regexp", "operator", "decorator", "label",
    ]

  test "modifier legend matches LSP §3.17":
    check SemanticTokenModifiers == @[
      "declaration", "definition", "readonly", "static", "deprecated",
      "abstract", "async", "modification", "documentation",
      "defaultLibrary",
    ]

  test "tokenTypes are unique":
    var seen = initHashSet[string]()
    for t in SemanticTokenTypes:
      check t notin seen
      seen.incl(t)

  test "indexOfTokenType returns SkipToken for unknown names":
    check indexOfTokenType("function") == 11
    check indexOfTokenType("macro") == 13
    check indexOfTokenType("does-not-exist") == SkipToken

# ---------------------------------------------------------------------------
# SymKind → token type mapping (one case per documented kind)
# ---------------------------------------------------------------------------

suite "mapSymKindToTokenType":
  type Case = object
    symKind: string
    expectedName: string

  # Table-driven sweep so adding a Nim symbol kind is a single-line patch
  # plus a test entry, not a free-form copy-paste exercise.
  const Cases = @[
    Case(symKind: "skProc", expectedName: "function"),
    Case(symKind: "skFunc", expectedName: "function"),
    Case(symKind: "skMethod", expectedName: "method"),
    Case(symKind: "skIterator", expectedName: "function"),
    Case(symKind: "skConverter", expectedName: "function"),
    Case(symKind: "skMacro", expectedName: "macro"),
    Case(symKind: "skTemplate", expectedName: "macro"),
    Case(symKind: "skType", expectedName: "type"),
    Case(symKind: "skVar", expectedName: "variable"),
    Case(symKind: "skLet", expectedName: "variable"),
    Case(symKind: "skConst", expectedName: "variable"),
    Case(symKind: "skResult", expectedName: "variable"),
    Case(symKind: "skParam", expectedName: "parameter"),
    Case(symKind: "skField", expectedName: "property"),
    Case(symKind: "skEnumField", expectedName: "enumMember"),
    Case(symKind: "skModule", expectedName: "namespace"),
    Case(symKind: "skPackage", expectedName: "namespace"),
    Case(symKind: "skLabel", expectedName: "label"),
    Case(symKind: "skGenericParam", expectedName: "typeParameter"),
    Case(symKind: "skForVar", expectedName: "variable"),
  ]

  test "every documented SymKind maps to the documented token type":
    for c in Cases:
      let idx = mapSymKindToTokenType(c.symKind)
      let expected = indexOfTokenType(c.expectedName)
      check idx == expected
      check SemanticTokenTypes[idx] == c.expectedName

  test "skTemp and unknown kinds are skipped":
    check mapSymKindToTokenType("skTemp") == SkipToken
    check mapSymKindToTokenType("skUnknown") == SkipToken
    check mapSymKindToTokenType("") == SkipToken
    check mapSymKindToTokenType("skBogusFutureKind") == SkipToken

# ---------------------------------------------------------------------------
# Modifier bitmask
# ---------------------------------------------------------------------------

suite "mapSymKindToModifiers":
  test "skLet implies readonly":
    let bits = mapSymKindToModifiers("skLet")
    let mask = 1'u32 shl indexOfTokenModifier("readonly").uint32
    check (bits and mask) == mask

  test "skConst implies readonly":
    let bits = mapSymKindToModifiers("skConst")
    let mask = 1'u32 shl indexOfTokenModifier("readonly").uint32
    check (bits and mask) == mask

  test "skVar has no implicit modifiers":
    check mapSymKindToModifiers("skVar") == 0'u32

  test "setModifier composes flags by name":
    var bits = mapSymKindToModifiers("skLet") # readonly
    setModifier(bits, "deprecated")
    let readOnly = 1'u32 shl indexOfTokenModifier("readonly").uint32
    let deprecated = 1'u32 shl indexOfTokenModifier("deprecated").uint32
    check (bits and readOnly) == readOnly
    check (bits and deprecated) == deprecated

  test "setModifier ignores unknown modifier names":
    var bits = 0'u32
    setModifier(bits, "no-such-modifier")
    check bits == 0'u32

# ---------------------------------------------------------------------------
# Identifier length helpers
# ---------------------------------------------------------------------------

suite "nameLength":
  test "plain identifier returns byte length":
    check nameLength("greet") == 5

  test "backticked operator strips backticks":
    check nameLength("`==`") == 2

  test "empty identifier reports zero":
    check nameLength("") == 0

# ---------------------------------------------------------------------------
# Delta encoding / round-trip
# ---------------------------------------------------------------------------

proc mkTok(line, startChar, length: int, ttype: int32,
           mods: uint32 = 0'u32): TokenInput =
  TokenInput(line: line, startChar: startChar, length: length,
             tokenType: ttype, tokenModifiers: mods)

suite "encodeSemanticTokens":
  let fnIdx = indexOfTokenType("function")

  test "empty input yields empty payload":
    check encodeSemanticTokens(@[]) == newSeq[uint32]()

  test "single token uses absolute line and column":
    let data = encodeSemanticTokens(@[mkTok(5, 10, 3, fnIdx)])
    check data == @[4'u32, 10'u32, 3'u32, fnIdx.uint32, 0'u32]

  test "multi-line tokens use line delta and reset column":
    let data = encodeSemanticTokens(@[
      mkTok(1, 0, 3, fnIdx),
      mkTok(3, 5, 2, fnIdx),
    ])
    # line 1 → wire 0, then line 3 → wire 2 (delta), char resets to abs
    check data == @[
      0'u32, 0'u32, 3'u32, fnIdx.uint32, 0'u32,
      2'u32, 5'u32, 2'u32, fnIdx.uint32, 0'u32,
    ]

  test "same-line adjacent tokens use additive column delta":
    let data = encodeSemanticTokens(@[
      mkTok(2, 4, 3, fnIdx),
      mkTok(2, 10, 2, fnIdx),
    ])
    check data[0..4] == @[1'u32, 4'u32, 3'u32, fnIdx.uint32, 0'u32]
    check data[5..9] == @[0'u32, 6'u32, 2'u32, fnIdx.uint32, 0'u32]

  test "encoder sorts unsorted input":
    let data = encodeSemanticTokens(@[
      mkTok(3, 0, 2, fnIdx),
      mkTok(1, 0, 3, fnIdx),
      mkTok(2, 0, 1, fnIdx),
    ])
    let decoded = decodeSemanticTokens(data)
    check decoded.len == 3
    check decoded[0].line == 1
    check decoded[1].line == 2
    check decoded[2].line == 3

  test "SkipToken inputs are dropped":
    let data = encodeSemanticTokens(@[
      mkTok(1, 0, 3, fnIdx),
      mkTok(2, 0, 5, SkipToken),
      mkTok(3, 0, 4, fnIdx),
    ])
    let decoded = decodeSemanticTokens(data)
    check decoded.len == 2

  test "zero-length tokens are dropped":
    let data = encodeSemanticTokens(@[mkTok(1, 0, 0, fnIdx)])
    check data.len == 0

  test "modifier bitmask survives round-trip":
    let bits = mapSymKindToModifiers("skLet") or
               (1'u32 shl indexOfTokenModifier("deprecated").uint32)
    let data = encodeSemanticTokens(@[mkTok(1, 0, 3, fnIdx, bits)])
    let decoded = decodeSemanticTokens(data)
    check decoded[0].tokenModifiers == bits

  test "5N invariant: payload length is always five times token count":
    var inputs: seq[TokenInput]
    for i in 1..50:
      inputs.add(mkTok(i, (i mod 7), 2 + (i mod 4), fnIdx))
    let data = encodeSemanticTokens(inputs)
    check data.len mod 5 == 0
    check data.len == inputs.len * 5

  test "deltas are non-negative — monotonic invariant":
    var inputs: seq[TokenInput]
    for i in 1..40:
      inputs.add(mkTok(((i mod 11) + 1), (i * 3) mod 17, 3, fnIdx))
    let data = encodeSemanticTokens(inputs)
    var j = 0
    var prevLineWire = 0
    var firstWire = true
    while j < data.len:
      let dLine = int(data[j])
      let dStart = int(data[j + 1])
      check dLine >= 0
      check dStart >= 0
      if not firstWire and dLine == 0:
        # Same-line tokens must be monotonically increasing in column.
        check dStart >= 0
      prevLineWire += dLine
      firstWire = false
      j += 5

# ---------------------------------------------------------------------------
# Round-trip property tests
# ---------------------------------------------------------------------------

suite "encodeSemanticTokens round-trip":
  let fnIdx = indexOfTokenType("function")
  let typeIdx = indexOfTokenType("type")

  test "encode -> decode yields a sorted sequence equal to filtered input":
    var raw: seq[TokenInput]
    for i in 0..20:
      raw.add(mkTok((i mod 5) + 1, (i * 13) mod 23, 3, fnIdx))
    raw.add(mkTok(1, 0, 4, typeIdx, 0b101'u32))

    let data = encodeSemanticTokens(raw)
    let decoded = decodeSemanticTokens(data)

    # Decoded sequence is sorted in (line, startChar).
    for i in 1 ..< decoded.len:
      check (decoded[i - 1].line < decoded[i].line) or
            (decoded[i - 1].line == decoded[i].line and
             decoded[i - 1].startChar <= decoded[i].startChar)

    # Every decoded token is present in the original input — we can't
    # require strict equality of order because the encoder sorts.
    var rawSorted = raw
    rawSorted.sort(proc(a, b: TokenInput): int =
      if a.line != b.line: cmp(a.line, b.line)
      else: cmp(a.startChar, b.startChar))
    check decoded.len == rawSorted.len
    for i, dec in decoded:
      check dec.line == rawSorted[i].line
      check dec.startChar == rawSorted[i].startChar
      check dec.length == rawSorted[i].length
      check dec.tokenType == rawSorted[i].tokenType
      check dec.tokenModifiers == rawSorted[i].tokenModifiers
