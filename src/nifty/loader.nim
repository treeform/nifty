## Resolve per-file namespaces, then flatten bound symbols for whole-program checks.
import std/[os, sets, tables, strutils, uri]
import common, lexer, importcache, parser

type
  SymbolKind = enum
    ConstantSymbol, TypeSymbol, GlobalSymbol, RoutineSymbol, NamespaceSymbol,
    AliasSymbol, ViewSymbol, AmbiguousSymbol
  Symbol = ref object
    kind: SymbolKind
    name, internal: string
    owner, namespace: SourceModule
    target: seq[string]
    candidates: seq[Symbol]
    line: int
    resolving: bool
  SourceModule = ref object
    path, directory, prefix: string
    index: int
    remote, main: bool
    namesReady: bool
    tokens: seq[Token]
    locals, direct, visible: Table[string, Symbol]
    dependencies: seq[SourceModule]
    names: HashSet[string]
    aliases: HashSet[int]
    declarations: Table[int, Symbol]
  Loader = ref object
    standardDirs: seq[string]
    modules: Table[string, SourceModule]
    order, stack: seq[SourceModule]
    portableIo: bool
    root: string
    cache: ImportCache
    lookups: Table[string, ModuleLookup]
    prefix: string

const keywords = ["const", "var", "let", "type", "opaque", "object",
  "extern", "func", "proc", "thread", "return", "break", "echo", "discard",
  "if", "elif", "else", "while", "max", "for", "in", "loop", "block",
  "with", "and", "or", "not", "true", "false", "none", "boundedBy"]
const builtins = ["int", "bool", "Lock", "array", "seq", "string", "cstring",
  "set", "queue", "channel", "map", "int8", "uint8", "char", "int16",
  "uint16", "int32", "uint32", "int64", "uint64", "float32", "float64"]
const methods = ["add", "push", "pop", "clear", "incl", "excl", "put",
  "remove", "setLen", "addByte", "addNum", "copyRange", "send", "recv",
  "reserve", "resize", "copyFrom", "or", "get", "contains", "startsWith",
  "endsWith", "find", "findByte", "toInt", "len", "ok", "lo", "hi",
  "isNull", "toCString"]

proc standardLibraryDirs(): seq[string] =
  let override = getEnv("NIFTY_STDLIB")
  if override.len > 0: result.add override
  let directory = getAppDir()
  result.add directory / "std"
  result.add directory / "lib" / "nifty"
  result.add directory.parentDir / "lib" / "nifty"
  result.add directory.parentDir / "std"
  result.add currentSourcePath().parentDir.parentDir.parentDir / "std"

proc isUrl(value: string): bool =
  value.startsWith("https://") or value.startsWith("http://")

proc identity(path: string): string =
  if path.isUrl: return path
  result = absolutePath(path).normalizedPath()
  when defined(windows): result = result.toLowerAscii()

proc at(tokens: seq[Token], index: int, value: string): bool =
  index < tokens.len and tokens[index].text == value

proc lineEnd(tokens: seq[Token], index: int): int =
  result = index
  while result < tokens.len and tokens[result].kind notin {NewlineToken, EofToken}:
    inc result

proc moduleName(path: string): string =
  let source = if path.isUrl: parseUri(path).path else: path
  result = source.replace('\\', '/').split('/')[^1].changeFileExt("")
  if result.len == 0 or not (result[0].isAlphaAscii or result[0] == '_'): return ""
  for c in result:
    if not (c.isAlphaNumeric or c == '_'): return ""

proc importPath(ld: Loader, parent: SourceModule, name: string, bare: bool,
    line: int): string =
  var source = name
  if bare:
    let rawDirectory = if parent.remote: ld.root else: parent.directory
    let rawLocal = rawDirectory / name & ".nifty"
    if fileExists(rawLocal): return rawLocal
    if source == "_io_platform":
      if ld.portableIo: source = "_io_posix"
      else:
        when defined(windows): source = "_io_windows"
        else: source = "_io_posix"
    source.add ".nifty"
  if source.isUrl: return source
  if source.contains("://"): err(line, "URL imports support only http:// and https://")
  let directory = if parent.remote: ld.root else: parent.directory
  let local = if source.isAbsolute: source else: directory / source
  if fileExists(local): return local
  if bare:
    for directory in ld.standardDirs:
      let candidate = directory / source
      if fileExists(candidate): return candidate
  let first = source.replace('\\', '/').split('/')[0]
  if not bare and not source.startsWith(".") and
      first.contains('.') and source.contains('/') and
      not first.endsWith(".nifty") and not source.isAbsolute:
    return "https://" & source
  if parent.remote and not source.isAbsolute:
    return $combine(parseUri(parent.path), parseUri(source.replace('\\', '/')))
  err(line, "cannot find import '" & name & "' (" & local & " does not exist)")

proc load(ld: Loader, source, path: string, main: bool,
    line: int): SourceModule =
  let key = identity(path)
  for cycleStart, active in ld.stack:
    if identity(active.path) == key:
      var chain: seq[string]
      for i in cycleStart ..< ld.stack.len: chain.add ld.stack[i].path
      chain.add path
      err(line, "import cycle: " & chain.join(" -> "))
  if key in ld.modules: return ld.modules[key]
  result = SourceModule(path: path, remote: path.isUrl, main: main,
    directory: (if main: ld.root elif path.isUrl: "" else: path.parentDir),
    index: srcFiles.len)
  srcFiles.add path
  ld.modules[key] = result
  ld.stack.add result
  let text = if main: source
    elif result.remote: ld.cache.readRemote(path, line)
    else: readFile(path)
  let tokens = tokenize(text, result.index * fileLineBase)
  var index = 0
  while index < tokens.len and tokens[index].kind == IdentToken and tokens[index].text == "import":
    let start = index
    inc index
    if index >= tokens.len or tokens[index].kind notin {IdentToken, StrToken}:
      err(tokens[start].line, "import needs a module name or quoted path")
    let request = tokens[index].text
    let bare = tokens[index].kind == IdentToken
    inc index
    var alias = ""
    if tokens.at(index, "as"):
      inc index
      if index >= tokens.len or tokens[index].kind != IdentToken:
        err(tokens[start].line, "import alias needs an identifier")
      alias = tokens[index].text
      inc index
    if index >= tokens.len or tokens[index].kind notin {NewlineToken, EofToken}:
      err(tokens[index].line, "one import is allowed per line")
    if tokens[index].kind == NewlineToken: inc index
    let path = ld.importPath(result, request, bare, tokens[start].line)
    let child = ld.load("", path, false, tokens[start].line)
    if alias.len == 0: alias = if bare: request else: moduleName(path)
    if alias.len == 0:
      err(tokens[start].line, "module filename needs an explicit 'as name' alias")
    if alias in keywords or alias in builtins or alias in ["import", "as"]:
      err(tokens[start].line, "module name '" & alias & "' is reserved; use 'as' to rename the import")
    if alias in result.direct and result.direct[alias].namespace != child:
      err(tokens[start].line, "module name '" & alias & "' is already bound; use 'as' to rename an import")
    result.direct[alias] = Symbol(kind: NamespaceSymbol, name: alias,
      namespace: child, owner: result, line: tokens[start].line)
    if child notin result.dependencies: result.dependencies.add child
  result.tokens = tokens[index .. ^1]
  var depth = 0
  var external = false
  var position = 0
  while position < result.tokens.len:
    let token = result.tokens[position]
    if token.kind == IndentToken: inc depth
    elif token.kind == DedentToken:
      dec depth
      if depth == 0: external = false
    elif token.kind == IdentToken and
        (depth == 0 or (external and depth == 1 and token.text == "proc")):
      let finish = result.tokens.lineEnd(position)
      var nameIndex = position + 1
      var kind = GlobalSymbol
      var declaration = true
      var alias = false
      case token.text
      of "extern":
        external = true
        declaration = false
      of "const": kind = ConstantSymbol
      of "var": kind = GlobalSymbol
      of "type":
        kind = TypeSymbol
        alias = not result.tokens.at(position + 3, "opaque")
      of "object": kind = TypeSymbol
      of "func", "proc", "thread":
        kind = RoutineSymbol
        if token.text == "thread":
          while nameIndex < finish and not result.tokens.at(nameIndex + 1, "("): inc nameIndex
      else:
        if result.tokens.at(position + 1, "="):
          kind = AliasSymbol
          alias = true
          nameIndex = position
        else: declaration = false
      if declaration and nameIndex < finish and result.tokens[nameIndex].kind == IdentToken:
        let name = result.tokens[nameIndex].text
        if name in result.direct:
          err(token.line, "module name '" & name & "' is reserved by an import; rename the import with 'as'")
        if name in result.locals and
            not (kind == RoutineSymbol and result.locals[name].kind == RoutineSymbol and
              name notin ["start", "end"]):
          err(token.line, "duplicate name: '" & name & "'")
        let symbol = if name in result.locals: result.locals[name]
          else: Symbol(kind: kind, name: name, owner: result, line: token.line)
        result.locals[name] = symbol
        result.declarations[nameIndex] = symbol
        if alias:
          symbol.kind = AliasSymbol
          var next = nameIndex + 2
          var expectName = true
          while next < finish:
            let part = result.tokens[next]
            if (expectName and part.kind != IdentToken) or
                (not expectName and part.text != "."):
              err(part.line, "an alias must name a symbol, such as name = module.name")
            if expectName: symbol.target.add part.text
            expectName = not expectName
            inc next
          if expectName or symbol.target.len == 0: err(token.line, "an alias must name a symbol")
          if token.text == "type": symbol.internal = "type"
          for removed in position ..< min(finish + 1, result.tokens.len): result.aliases.incl removed
      position = finish
    inc position
  discard ld.stack.pop()
  ld.order.add result

proc exportNames(module: SourceModule): HashSet[string] =
  if module.namesReady: return module.names
  for name in module.locals.keys: module.names.incl name
  for name in module.direct.keys: module.names.incl name
  for dependency in module.dependencies:
    for name in dependency.exportNames(): module.names.incl name
  module.namesReady = true
  module.names

proc lookup(ld: Loader, module: SourceModule, name: string): Symbol

proc qualifiedSymbol(symbol: Symbol): Symbol =
  ## A unique module binding remains usable as the left side of qualification,
  ## even when a cascaded value happens to share its basename.
  var modules: seq[Symbol]
  proc collect(value: Symbol) =
    if value == nil: return
    if value.kind == NamespaceSymbol:
      for previous in modules:
        if previous.namespace == value.namespace: return
      modules.add value
    elif value.kind == AmbiguousSymbol:
      for candidate in value.candidates: collect(candidate)
  if symbol != nil and symbol.kind == AmbiguousSymbol:
    collect(symbol)
    if modules.len == 1: return modules[0]
  symbol

proc pathLookup(ld: Loader, module: SourceModule, parts: seq[string],
    line: int): Symbol =
  var current = module
  for i, part in parts:
    result = ld.lookup(current, part)
    if i < parts.high: result = qualifiedSymbol(result)
    if result == nil: err(line, "unknown module symbol: '" & parts.join(".") & "'")
    if result.kind == AmbiguousSymbol:
      err(line, "ambiguous imported name '" & part & "'; qualify it with a module name or add an alias")
    if i < parts.high:
      if result.kind != NamespaceSymbol: err(line, "'" & part & "' is not a module")
      current = result.namespace

proc lookup(ld: Loader, module: SourceModule, name: string): Symbol =
  if name in module.visible: return module.visible[name]
  if name in module.direct: return module.direct[name]
  let local = module.locals.getOrDefault(name)
  if local != nil and local.kind == AliasSymbol:
    if local.resolving: err(local.line, "alias cycle involving '" & name & "'")
    local.resolving = true
    if local.target.len == 1 and local.target[0] in builtins:
      result = Symbol(kind: TypeSymbol, internal: local.target[0],
        name: local.target[0], owner: module)
    else: result = ld.pathLookup(module, local.target, local.line)
    local.resolving = false
    if local.internal == "type" and result.kind != TypeSymbol:
      err(local.line, "type alias '" & name & "' must name a type")
    module.visible[name] = result
    return
  if local != nil and local.kind != RoutineSymbol:
    module.visible[name] = local
    return local
  var imported: seq[Symbol]
  for dependency in module.dependencies:
    let symbol = ld.lookup(dependency, name)
    if symbol != nil:
      var duplicate = false
      for previous in imported:
        if previous == symbol or
            (previous.kind == NamespaceSymbol and symbol.kind == NamespaceSymbol and
              previous.namespace == symbol.namespace):
          duplicate = true
      if not duplicate: imported.add symbol
  if local != nil and imported.len == 0:
    module.visible[name] = local
    return local
  if local == nil and imported.len == 0:
    module.visible[name] = nil
    return nil
  if local == nil and imported.len == 1:
    module.visible[name] = imported[0]
    return imported[0]
  var routineOnly = true
  for symbol in imported:
    if symbol.kind notin {RoutineSymbol, ViewSymbol}: routineOnly = false
  if local != nil or routineOnly:
    let internal = module.prefix & "v_" & name
    var definition = ModuleLookup(name: internal, display: name)
    if local != nil: definition.local.add local.internal
    for symbol in imported:
      if symbol.kind in {RoutineSymbol, ViewSymbol} and symbol.internal notin definition.imports:
        definition.imports.add symbol.internal
    ld.lookups[internal] = definition
    result = Symbol(kind: ViewSymbol, name: name, internal: internal, owner: module)
  else:
    result = Symbol(kind: AmbiguousSymbol, name: name, owner: module, candidates: imported)
  module.visible[name] = result

proc rewrite(ld: Loader, module: SourceModule): seq[Token] =
  let tokens = module.tokens
  var scopes: seq[HashSet[string]]
  var pending: HashSet[string]
  var depth = 0
  var bodyDepth = -1
  var inObject = false
  var index = 0
  proc localName(name: string): string =
    if module.main: name else: module.prefix & "s_" & name
  proc isLocal(name: string): bool =
    for scope in scopes:
      if name in scope: return true
  proc checkLocal(name: string, line: int) =
    let symbol = ld.lookup(module, name)
    if symbol != nil and symbol.kind == NamespaceSymbol:
      err(line, "module name '" & name & "' is reserved by an import; rename the import with 'as'")
  while index < tokens.len:
    if index in module.aliases:
      inc index
      continue
    if tokens[index].kind in {IndentToken, DedentToken}:
      if tokens[index].kind == IndentToken:
        inc depth
        if bodyDepth >= 0:
          scopes.add pending
          pending = initHashSet[string]()
      else:
        dec depth
        if scopes.len > 0: discard scopes.pop()
        if bodyDepth >= 0 and depth < bodyDepth:
          bodyDepth = -1
          scopes.setLen(0)
        if depth == 0: inObject = false
      result.add tokens[index]
      inc index
      continue
    if tokens[index].kind in {NewlineToken, EofToken}:
      result.add tokens[index]
      inc index
      continue
    let finish = tokens.lineEnd(index)
    var forced: Table[int, string]
    var typePositions, labels: HashSet[int]
    var grammar: HashSet[int]
    var after: HashSet[string]
    var routineHeader = false
    let word = tokens[index].text
    if (bodyDepth >= 0 and word in ["var", "let", "if", "elif", "else",
        "while", "for", "loop", "block", "with", "return", "break", "echo", "discard"]) or
        (depth == 0 and word in ["const", "var", "type", "object", "func",
          "proc", "thread", "extern"]):
      grammar.incl index
    if bodyDepth >= 0 and word == "while":
      let clause = expressionEnd(tokens, index + 1)
      if tokens.at(clause, "max"): grammar.incl clause
    if depth == 0 and word == "object": inObject = true
    if word in ["func", "proc", "thread"] and (depth == 0 or bodyDepth < 0):
      routineHeader = true
      grammar.incl index
      var opening = index + 1
      while opening < finish and tokens[opening].text != "(": inc opening
      var p = opening + 1
      var inType = false
      var brackets = 0
      while p < finish and not (tokens[p].text == ")" and brackets == 0):
        let token = tokens[p]
        if token.text == "[": inc brackets
        elif token.text == "]": dec brackets
        elif token.text == ":" and brackets == 0: inType = true
        elif token.text == "," and brackets == 0 and inType: inType = false
        elif not inType and token.kind == IdentToken:
          checkLocal(token.text, token.line)
          pending.incl token.text
          forced[p] = localName(token.text)
        elif inType: typePositions.incl p
        inc p
      inc p
      if tokens.at(p, ":"):
        inc p
        while p < finish and tokens[p].text != "=":
          typePositions.incl p
          inc p
      if depth == 0 and tokens.at(p, "="): bodyDepth = depth + 1
    elif bodyDepth >= 0 and word in ["var", "let"]:
      if index + 1 < finish:
        let name = tokens[index + 1].text
        checkLocal(name, tokens[index + 1].line)
        forced[index + 1] = localName(name)
        after.incl name
        if tokens.at(index + 2, ":"):
          var p = index + 3
          while p < finish and tokens[p].text != "=":
            typePositions.incl p
            inc p
    elif bodyDepth >= 0 and word == "for":
      var p = index + 1
      while p < finish and tokens[p].text != "in":
        if tokens[p].kind == IdentToken:
          checkLocal(tokens[p].text, tokens[p].line)
          forced[p] = localName(tokens[p].text)
          pending.incl tokens[p].text
        inc p
      grammar.incl p
    elif (depth == 0 and word == "var") or (inObject and depth == 1):
      var p = index + 1
      if inObject and depth == 1: p = index
      while p < finish and tokens[p].text != ":":
        if inObject and depth == 1: labels.incl p
        inc p
      inc p
      while p < finish:
        typePositions.incl p
        inc p
    var position = index
    while position < finish:
      var token = tokens[position]
      if position == index and word == "with":
        for name in ["start", "end"]:
          let hook = ld.lookup(module, name)
          token.resourceHooks.add(if hook != nil: hook.internal else: localName(name))
      if position in module.declarations:
        let symbol = module.declarations[position]
        token.text = symbol.internal
        token.sourceName = symbol.name
        result.add token
        if routineHeader and word == "proc" and depth > 0 and
            tokens[position + 1].kind != StrToken and token.text != symbol.name:
          result.add Token(kind: StrToken, text: symbol.name, line: token.line)
      elif position in forced:
        token.sourceName = token.text
        token.text = forced[position]
        result.add token
      elif token.kind != IdentToken or position in labels or
          position in grammar or
          (position > 0 and tokens[position - 1].text == "$") or
          token.text in ["and", "or", "not", "true", "false", "none"] or
          (position in typePositions and token.text in ["var", "boundedBy"]) or
          (depth == 0 and word == "type" and token.text == "opaque"):
        result.add token
      else:
        let name = token.text
        let afterDot = position > index and tokens[position - 1].text == "."
        let methodCall = afterDot and tokens.at(position + 1, "(") and name notin methods
        let parameterCount = position > index and tokens[position - 1].text == "boundedBy"
        if (not afterDot and position notin typePositions and isLocal(name)) or
            (parameterCount and name in pending):
          token.text = localName(name)
          token.sourceName = name
          result.add token
        elif afterDot and not methodCall: result.add token
        elif name in builtins: result.add token
        else:
          var symbol = ld.lookup(module, name)
          var next = position + 1
          if tokens.at(next, "."): symbol = qualifiedSymbol(symbol)
          var qualified = false
          while symbol != nil and symbol.kind == NamespaceSymbol and
              tokens.at(next, ".") and next + 1 < finish and tokens[next + 1].kind == IdentToken:
            qualified = true
            let member = tokens[next + 1]
            symbol = ld.lookup(symbol.namespace, member.text)
            if symbol == nil: err(member.line, "unknown module member: '" & member.text & "'")
            next += 2
            if tokens.at(next, "."): symbol = qualifiedSymbol(symbol)
          if symbol != nil and symbol.kind == AmbiguousSymbol:
            err(token.line, "ambiguous imported name '" & name &
              "'; qualify it with a module name or add an alias")
          if symbol != nil and symbol.kind != NamespaceSymbol and
              (not methodCall or symbol.kind in {RoutineSymbol, ViewSymbol}):
            token.text = symbol.internal
            token.sourceName = symbol.name
            result.add token
            if qualified: position = next - 1
          else:
            if not module.main and symbol == nil:
              token.text = localName(name)
              token.sourceName = name
            result.add token
      inc position
    if scopes.len > 0:
      for name in after: scopes[^1].incl name
    if routineHeader and bodyDepth < 0: pending = initHashSet[string]()
    index = finish

proc finish(ld: Loader): seq[Token] =
  ld.prefix = "niftyModule"
  var occupied: HashSet[string]
  for module in ld.order:
    for token in module.tokens:
      if token.kind == IdentToken: occupied.incl token.text
  var serial = 0
  while true:
    var collision = false
    for name in occupied:
      if name.startsWith(ld.prefix): collision = true
    if not collision: break
    inc serial
    ld.prefix = "niftyModule" & $serial & "_"
  for module in ld.order:
    module.prefix = ld.prefix & $module.index & "_"
    for name, symbol in module.locals:
      if symbol.kind != AliasSymbol:
        symbol.internal = if module.main: name else: module.prefix & "s_" & name
  for module in ld.order:
    for name in module.exportNames(): discard ld.lookup(module, name)
  for module in ld.order:
    var rewritten = ld.rewrite(module)
    if rewritten.len > 0 and rewritten[^1].kind == EofToken: rewritten.setLen(rewritten.len - 1)
    result.add rewritten
  var definitions: seq[ModuleLookup]
  for definition in ld.lookups.values: definitions.add definition
  result.add Token(kind: EofToken, line: 1, moduleLookups: definitions)
  ld.cache.saveImportLock()

proc loadTokens*(mainSrc, mainName, dir: string, portableIo = false): seq[Token] =
  srcFiles = @[]
  symbolNames.clear()
  let root = if dir.len > 0: dir else: getCurrentDir()
  let ld = Loader(standardDirs: standardLibraryDirs(), portableIo: portableIo,
    root: root, cache: initImportCache(root))
  discard ld.load(mainSrc, mainName, true, 1)
  ld.finish()

proc loadStandardTokens*(name: string, portableIo = false): seq[Token] =
  let directories = standardLibraryDirs()
  for directory in directories:
    let path = directory / name & ".nifty"
    if fileExists(path):
      let ld = Loader(standardDirs: directories, portableIo: portableIo,
        root: directory, cache: initImportCache(directory))
      discard ld.load(readFile(path), path, true, 1)
      return ld.finish()
  err(1, "cannot find standard library support module '" & name & "'")
