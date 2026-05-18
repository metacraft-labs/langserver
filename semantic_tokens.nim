## Semantic-token plumbing for `textDocument/semanticTokens/range`.
##
## Two layers live here:
##
## 1. *Pure encoding helpers* (`mapSymKindToTokenType`, `mapSymKindToModifiers`,
##    `encodeSemanticTokens`).  These are deliberately free of any LSP /
##    nimsuggest dependency so that the test suite (and microbenchmark
##    rig) can exercise them in isolation.
##
## 2. *The LSP route* (`semanticTokensRange`) in `routes.nim` glues those
##    helpers to the nimsuggest `highlightRange` command we added in
##    `codetracer-nim` (see `nimsuggest/nimsuggest.nim` near
##    `of ideHighlightRange:`).
##
## See LSP §3.17:
##   https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#textDocument_semanticTokens

import std/algorithm

# ---------------------------------------------------------------------------
# Legend.  These constants are the contract with the Monaco client; do not
# reorder without updating `codetracer/src/frontend/languages/nimSemanticTokens.js`.
# ---------------------------------------------------------------------------

const
  SemanticTokenTypes* = @[
    "namespace", "type", "class", "enum", "interface", "struct",
    "typeParameter", "parameter", "variable", "property", "enumMember",
    "function", "method", "macro", "keyword", "modifier", "comment",
    "string", "number", "regexp", "operator", "decorator", "label",
  ]
  SemanticTokenModifiers* = @[
    "declaration", "definition", "readonly", "static", "deprecated",
    "abstract", "async", "modification", "documentation", "defaultLibrary",
  ]

  # Sentinel value emitted by `mapSymKindToTokenType` when a Nim symbol kind
  # is not part of the user-visible semantic-token surface.  The encoder
  # silently drops these so the wire payload stays compact.
  SkipToken* = -1'i32

type
  TokenInput* = object
    ## In-memory shape used by the encoder.  Lines are 1-based (matching
    ## nimsuggest), starts are 0-based UTF-8 byte offsets, lengths are in
    ## UTF-8 bytes.  Conversion to the LSP 0-based-line wire format happens
    ## inside `encodeSemanticTokens`.
    line*: int
    startChar*: int
    length*: int
    tokenType*: int32
    tokenModifiers*: uint32

# ---------------------------------------------------------------------------
# SymKind → token type mapping.
# ---------------------------------------------------------------------------

func indexOfTokenType*(name: string): int32 =
  ## Return the wire-index of `name` in `SemanticTokenTypes`, or `SkipToken`
  ## if it isn't present.  Used by tests that want to express expectations
  ## by name rather than index.
  for i, t in SemanticTokenTypes:
    if t == name:
      return i.int32
  return SkipToken

func indexOfTokenModifier*(name: string): int32 =
  for i, m in SemanticTokenModifiers:
    if m == name:
      return i.int32
  return -1'i32

func mapSymKindToTokenType*(symKind: string): int32 =
  ## Map a nimsuggest `symKind` string (e.g. `"skProc"`) to a wire-index
  ## into `SemanticTokenTypes`.  Returns `SkipToken` for kinds that have
  ## no useful representation in the editor (`skTemp`, unknown values).
  case symKind
  of "skProc": indexOfTokenType("function")
  of "skFunc": indexOfTokenType("function")
  of "skMethod": indexOfTokenType("method")
  of "skIterator": indexOfTokenType("function")
  of "skConverter": indexOfTokenType("function")
  of "skMacro": indexOfTokenType("macro")
  of "skTemplate": indexOfTokenType("macro")
  of "skType": indexOfTokenType("type")
  of "skVar": indexOfTokenType("variable")
  of "skLet": indexOfTokenType("variable")
  of "skConst": indexOfTokenType("variable")
  of "skResult": indexOfTokenType("variable")
  of "skParam": indexOfTokenType("parameter")
  of "skField": indexOfTokenType("property")
  of "skEnumField": indexOfTokenType("enumMember")
  of "skModule": indexOfTokenType("namespace")
  of "skPackage": indexOfTokenType("namespace")
  of "skLabel": indexOfTokenType("label")
  of "skGenericParam": indexOfTokenType("typeParameter")
  of "skForVar": indexOfTokenType("variable")
  else: SkipToken # skTemp, skUnknown, future kinds

func mapSymKindToModifiers*(symKind: string): uint32 =
  ## Derive the modifier bitmask for a symbol.  `skLet` and `skConst` are
  ## the only kinds that imply a modifier without further context
  ## (`readonly`).  The `declaration` modifier is left to the caller of
  ## `encodeSemanticTokens` because it depends on whether the symbol
  ## position is the definition site, which only the LSP route knows.
  case symKind
  of "skLet", "skConst": (1'u32 shl indexOfTokenModifier("readonly").uint32)
  else: 0'u32

func setModifier*(bits: var uint32, name: string) =
  ## Helper for code that already has a bitmask and wants to add one
  ## modifier by name.  Silently ignores unknown names so callers can stay
  ## defensive when the legend changes.
  let idx = indexOfTokenModifier(name)
  if idx >= 0:
    bits = bits or (1'u32 shl idx.uint32)

func nameLength*(name: string): int =
  ## UTF-8 byte length of a symbol identifier as it appears in source.
  ## Nimsuggest returns identifiers including the trailing backtick markers
  ## (e.g. `` `==` ``); we strip them so the wire `length` matches what the
  ## editor sees on screen.
  if name.len >= 2 and name[0] == '`' and name[^1] == '`':
    return name.len - 2
  name.len

# ---------------------------------------------------------------------------
# Delta encoder.
# ---------------------------------------------------------------------------

proc cmpTokens(a, b: TokenInput): int =
  if a.line != b.line:
    return cmp(a.line, b.line)
  cmp(a.startChar, b.startChar)

proc encodeSemanticTokens*(tokens: openArray[TokenInput]): seq[uint32] =
  ## Sort `tokens` by `(line, startChar)` and emit the LSP delta-encoded
  ## wire format: a flat array of 5-uint groups
  ## `[deltaLine, deltaStartChar, length, tokenType, tokenModifiers]`.
  ## Tokens with `tokenType == SkipToken` or non-positive `length` are
  ## dropped — both are reachable from real input (`skTemp` symbols and
  ## empty identifiers after backtick stripping).
  result = newSeqOfCap[uint32](tokens.len * 5)
  if tokens.len == 0:
    return

  var working = newSeqOfCap[TokenInput](tokens.len)
  for tok in tokens:
    if tok.tokenType < 0 or tok.length <= 0:
      continue
    working.add(tok)
  if working.len == 0:
    return

  working.sort(cmpTokens)

  var prevLine = 0
  var prevChar = 0
  var first = true
  for tok in working:
    # LSP wire format expects 0-based line numbers; the encoder accepts the
    # 1-based form that nimsuggest emits so callers don't have to translate.
    let lineZero = tok.line - 1
    let deltaLine =
      if first: lineZero
      else: lineZero - prevLine
    let deltaStart =
      if first or deltaLine != 0: tok.startChar
      else: tok.startChar - prevChar
    if deltaLine < 0 or deltaStart < 0:
      # Defensive: after stable-sort this should be unreachable, but
      # encoding a negative delta would silently corrupt the editor.
      continue
    result.add(uint32(deltaLine))
    result.add(uint32(deltaStart))
    result.add(uint32(tok.length))
    result.add(uint32(tok.tokenType))
    result.add(tok.tokenModifiers)
    prevLine = lineZero
    prevChar = tok.startChar
    first = false

proc decodeSemanticTokens*(data: openArray[uint32]): seq[TokenInput] =
  ## Inverse of `encodeSemanticTokens`, used by tests.  Returns tokens in
  ## the order they appeared on the wire (which the encoder guarantees is
  ## `(line, startChar)`-sorted).  Lines are restored to 1-based.
  doAssert data.len mod 5 == 0,
    "semantic-token payload must be a multiple of 5 uint32 (got " &
    $data.len & ")"
  var prevLine = 0
  var prevChar = 0
  var i = 0
  while i < data.len:
    let dLine = int(data[i + 0])
    let dStart = int(data[i + 1])
    let length = int(data[i + 2])
    let tokType = int32(data[i + 3])
    let tokMods = data[i + 4]
    let line = prevLine + dLine
    let startChar =
      if dLine == 0: prevChar + dStart
      else: dStart
    result.add(TokenInput(
      line: line + 1,
      startChar: startChar,
      length: length,
      tokenType: tokType,
      tokenModifiers: tokMods,
    ))
    prevLine = line
    prevChar = startChar
    i += 5

# ---------------------------------------------------------------------------
# Convenience: produce the `legend` payload for the `initialize` response.
# ---------------------------------------------------------------------------

# Implemented inline rather than via `protocol/types` to avoid a circular
# dependency between this module and the wire schema; the route handler
# constructs the legend through the typed constructor in `routes.nim`.
