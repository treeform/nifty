## Capability-based embedding of checked Nifty source in a Nim application.
## No filesystem, network, native library loading, or OS workers are implicit.
import std/[tables, sets, strutils]
import common, lexer, loader, parser, checker, types, lowering, nativefiles,
  nativecontainers, interpreterffi
import backend/[irs, context, irinterpreters]

export ExecutionLimitError, IrType

type
  ScriptError* = object of NiftyError
  ValueKind* = enum
    VoidValue, IntValue, FloatValue, BoolValue, StringValue
  Value* = object
    case kind*: ValueKind
    of IntValue: integer*: int64
    of FloatValue: number*: float64
    of BoolValue: boolean*: bool
    of StringValue: text*: string
    of VoidValue: discard
  HostProc* = proc(args: openArray[Value]): Value {.closure.}
  IntHostProc* = proc(args: openArray[int64]): int64 {.closure.}
  PrintProc* = proc(text: string) {.closure.}
  Limits* = object
    maxSourceBytes*, maxWork*, maxMemoryBytes*, maxOutputBytes*: int64
    maxCallDepth*, maxAllocations*, maxSyntaxDepth*, maxCodeInstructions*: int
  HostFunction = object
    name: string
    parameters: seq[ValueKind]
    returns: ValueKind
    callback: HostProc
    query: bool
    workUnits: int64
  HostData = object
    name: string
    value: Value
  UnsafeFfi = object
    library, symbol: string
    address: pointer
    parameters: seq[IrType]
    returns: seq[IrType]
  Host* = object
    functions: seq[HostFunction]
    data: seq[HostData]
    modules: Table[string, string]
    foreign: seq[UnsafeFfi]
    allowImports, allowExterns: bool
  Global = object
    offset, layout: int
    readonly: bool
  Program* = ref object
    plan: NativePlan
    interpreter: IrInterpreterPlan
    host: Host
    globals: Table[string, Global]
    inputs: Table[string, Global]
    limits: Limits
  Allocation = object
    address: pointer
    bytes: int64
  MemoryPool = object
    allocations: seq[Allocation]
    budget: ptr ExecutionBudget
    liveBytes: int64
    failed: bool
    meterWork: bool
  RunStats* = object
    work*, peakMemoryBytes*, outputBytes*: int64
  Runtime* = ref object
    program: Program
    host: Host
    budget: ExecutionBudget
    pool: MemoryPool
    globals, arena: seq[byte]
    prefix: RuntimeContext
    foreign: seq[ForeignCall]
    running, failed, finished: bool
    outputBytes: int64
    print: PrintProc

proc defaultLimits*(): Limits =
  Limits(maxSourceBytes: 1024 * 1024, maxWork: 10_000_000,
    maxMemoryBytes: 64 * 1024 * 1024, maxOutputBytes: 1024 * 1024,
    maxCallDepth: 64, maxAllocations: 4096, maxSyntaxDepth: 64,
    maxCodeInstructions: 200_000)

proc value*(number: SomeInteger): Value =
  Value(kind: IntValue, integer: int64(number))
proc value*(number: SomeFloat): Value =
  Value(kind: FloatValue, number: float64(number))
proc value*(boolean: bool): Value = Value(kind: BoolValue, boolean: boolean)
proc value*(text: string): Value = Value(kind: StringValue, text: text)
proc asInt*(v: Value): int64 =
  if v.kind != IntValue: raise newException(ScriptError, "expected an integer")
  v.integer
proc asFloat*(v: Value): float64 =
  if v.kind != FloatValue: raise newException(ScriptError, "expected a float")
  v.number
proc asBool*(v: Value): bool =
  if v.kind != BoolValue: raise newException(ScriptError, "expected a bool")
  v.boolean
proc asString*(v: Value): string =
  if v.kind != StringValue: raise newException(ScriptError, "expected a string")
  v.text

proc fail(message: string) {.noreturn.} = raise newException(ScriptError, message)

proc validate(limits: Limits) =
  if limits.maxSourceBytes <= 0 or limits.maxSourceBytes > 16 * 1024 * 1024 or
      limits.maxWork <= 0 or limits.maxMemoryBytes <= 0 or
      limits.maxMemoryBytes > 1024 * 1024 * 1024 or
      limits.maxOutputBytes < 0 or limits.maxCallDepth <= 0 or
      limits.maxCallDepth > 1024 or limits.maxAllocations <= 0 or
      limits.maxAllocations > 65536 or limits.maxSyntaxDepth <= 0 or
      limits.maxSyntaxDepth > 128 or limits.maxCodeInstructions <= 0:
    fail("invalid scripting limits")

proc validName(name: string) =
  if name.len == 0 or not (name[0].isAlphaAscii or name[0] == '_'):
    fail("invalid host name: " & name)
  for c in name:
    if not (c.isAlphaNumeric or c == '_'): fail("invalid host name: " & name)
  if name in ["const", "var", "let", "type", "opaque", "object", "extern",
      "func", "proc", "thread", "return", "break", "echo", "discard", "if",
      "elif", "else", "while", "for", "in", "loop", "block", "with", "and",
      "or", "not", "true", "false", "none", "host", "import", "as", "int",
      "bool", "string", "float64", "seq", "array", "map", "set"]:
    fail("reserved host name: " & name)

proc ensureFree(host: Host, name: string) =
  validName(name)
  for f in host.functions:
    if f.name == name: fail("duplicate host name: " & name)
  for d in host.data:
    if d.name == name: fail("duplicate host name: " & name)

proc initHost*(allowImports = false, allowExterns = false): Host =
  ## Creates an isolated host. Imports and externs are off by default.
  Host(allowImports: allowImports, allowExterns: allowExterns)

proc addData*(host: var Host, name: string, v: Value) =
  host.ensureFree(name)
  if v.kind == VoidValue: fail("host data cannot be void")
  host.data.add(HostData(name: name, value: v))

proc addData*(host: var Host, name: string, v: SomeInteger) = host.addData(name, value(v))
proc addData*(host: var Host, name: string, v: SomeFloat) = host.addData(name, value(v))
proc addData*(host: var Host, name: string, v: bool) = host.addData(name, value(v))
proc addData*(host: var Host, name, v: string) = host.addData(name, value(v))

proc addCallable(host: var Host, name: string, parameters: openArray[ValueKind],
    returns: ValueKind, callback: HostProc, query: bool, workUnits: int64) =
  host.ensureFree(name)
  if callback == nil or workUnits < 1 or parameters.len > 64:
    fail("invalid host callback")
  for kind in parameters:
    if kind == VoidValue: fail("host parameters cannot be void")
  host.functions.add(HostFunction(name: name, parameters: @parameters,
    returns: returns, callback: callback, query: query, workUnits: workUnits))

proc addFunction*(host: var Host, name: string, parameters: openArray[ValueKind],
    returns: ValueKind, callback: HostProc, workUnits = 1'i64) =
  host.addCallable(name, parameters, returns, callback, false, workUnits)

proc addQuery*(host: var Host, name: string, parameters: openArray[ValueKind],
    returns: ValueKind, callback: HostProc, workUnits = 1'i64) =
  host.addCallable(name, parameters, returns, callback, true, workUnits)

proc integerCallback(callback: IntHostProc): HostProc =
  if callback == nil: fail("nil host callback")
  result = proc(args: openArray[Value]): Value =
    var numbers = newSeq[int64](args.len)
    for i, arg in args: numbers[i] = arg.asInt()
    value(callback(numbers))

proc addFunction*(host: var Host, name: string, arity: int,
    callback: IntHostProc, workUnits = 1'i64) =
  if arity < 0 or arity > 64: fail("invalid host arity")
  var params = newSeq[ValueKind](arity)
  for p in params.mitems: p = IntValue
  host.addFunction(name, params, IntValue, integerCallback(callback), workUnits)

proc addQuery*(host: var Host, name: string, arity: int,
    callback: IntHostProc, workUnits = 1'i64) =
  if arity < 0 or arity > 64: fail("invalid host arity")
  var params = newSeq[ValueKind](arity)
  for p in params.mitems: p = IntValue
  host.addQuery(name, params, IntValue, integerCallback(callback), workUnits)

proc modulePath(parent, request: string, bare: bool): string =
  ## Virtual POSIX paths; never consult the filesystem or environment.
  var path = request.replace('\\', '/')
  if bare: path.add ".nifty"
  if path == "host.nifty": return path
  if not path.contains("://") and not path.startsWith("/"):
    let slash = parent.rfind('/')
    if slash >= 0: path = parent[0 .. slash] & path
  var parts: seq[string]
  if path.contains("://"): return path
  for part in path.split('/'):
    if part in ["", "."]: continue
    if part == "..":
      if parts.len == 0: return ""
      parts.setLen(parts.len - 1)
    else: parts.add part
  parts.join("/")

proc addModule*(host: var Host, name, source: string) =
  ## Adds a virtual module. Requires a host created with allowImports.
  if not host.allowImports:
    fail("imports are disabled for this host: use initHost(allowImports = true)")
  let path = modulePath("", name, not name.endsWith(".nifty") and not name.contains('/'))
  if path.len == 0 or path == "host.nifty": fail("reserved or invalid module path")
  if path in host.modules: fail("duplicate host module: " & path)
  host.modules[path] = source

proc allowUnsafeFfi*(host: var Host, library, symbol: string, address: pointer,
    parameters: openArray[IrType], returns: openArray[IrType]) =
  ## Explicit escape hatch. The host resolves and keeps this address alive.
  ## This grants native code the full powers of the embedding process.
  ## Requires a host created with allowExterns.
  if not host.allowExterns:
    fail("externs are disabled for this host: use initHost(allowExterns = true)")
  if address == nil or library.len == 0 or symbol.len == 0:
    fail("unsafe FFI requires a named, non-null host-provided address")
  for previous in host.foreign:
    if previous.library == library and previous.symbol == symbol:
      fail("duplicate unsafe FFI permission")
  host.foreign.add(UnsafeFfi(library: library, symbol: symbol, address: address,
    parameters: @parameters, returns: @returns))

proc niftyType(kind: ValueKind): string =
  case kind
  of VoidValue: ""
  of IntValue: "int"
  of FloatValue: "float64"
  of BoolValue: "bool"
  of StringValue: "string"

proc prelude(host: Host): string =
  for data in host.data:
    result.add "var " & data.name & ": " & niftyType(data.value.kind) & "\n"
  for f in host.functions:
    result.add (if f.query: "func " else: "proc ") & f.name & "("
    for i, p in f.parameters:
      if i > 0: result.add ", "
      result.add "arg" & $i & ": " & niftyType(p)
    result.add ")"
    if f.returns != VoidValue: result.add ": " & niftyType(f.returns)
    result.add " =\n  discard 0\n"

const echoSource = """
proc echoStart() =
  discard 0
proc echoFinish() =
  discard 0
proc echoText(value: string) =
  discard 0
proc echoInt(value: int) =
  discard 0
proc echoChar(value: char) =
  discard 0
proc echoBool(value: bool) =
  discard 0
proc echoFloat(value: float64) =
  discard 0
"""

proc checkSource(source: string, limits: Limits, filename: string) =
  if int64(source.len) > limits.maxSourceBytes: fail("script source limit exceeded")
  # Source positions encode file identity in the high digits. Do not allow
  # a long file to impersonate the trusted host module's source positions.
  if source.count('\n') + source.count('\r') >= fileLineBase - 2:
    fail("script source line limit exceeded")
  let previousFiles = srcFiles
  let previousNames = symbolNames
  srcFiles = @[filename]
  symbolNames = initTable[string, string]()
  defer:
    srcFiles = previousFiles
    symbolNames = previousNames
  var depth, expressionDepth, lineTokens: int
  for token in lexer.tokenize(source):
    case token.kind
    of IndentToken:
      inc depth
      if depth > limits.maxSyntaxDepth: fail("script syntax depth limit exceeded")
    of DedentToken: dec depth
    of NewlineToken: lineTokens = 0
    else:
      inc lineTokens
      if lineTokens > 256: fail("script expression size limit exceeded")
      if token.text in ["(", "["]:
        inc expressionDepth
        if expressionDepth > limits.maxSyntaxDepth: fail("script syntax depth limit exceeded")
      elif token.text in [")", "]"]: dec expressionDepth

proc compileSource(source: string, host: Host,
    limits = defaultLimits(), filename = "script.nifty"): Program =
  ## Compiles checked source using only the modules and capabilities supplied.
  limits.validate()
  checkSource(source, limits, filename)
  var totalSource = int64(source.len)
  let hostSource = host.prelude()
  checkSource(hostSource, limits, "host.nifty")
  totalSource += int64(hostSource.len)
  if totalSource > limits.maxSourceBytes: fail("script source limit exceeded")
  var seen = initHashSet[string]()
  let resolver: ImportResolver = proc(parent, request: string, bare: bool): ImportSource =
    var path = modulePath(parent, request, bare)
    if path == "host.nifty": return ImportSource(identity: path, source: hostSource)
    if not host.allowImports: fail("imports are disabled for scripts: " & request)
    if bare and path notin host.modules: path = modulePath("", request, true)
    if path notin host.modules: return
    if path notin seen:
      seen.incl path
      totalSource += int64(host.modules[path].len)
      if totalSource > limits.maxSourceBytes: fail("script source limit exceeded")
      checkSource(host.modules[path], limits, path)
      if seen.len > 128: fail("script module limit exceeded")
    ImportSource(identity: path, source: host.modules[path])
  let mainName = if filename == "host.nifty": "script.nifty" else: filename
  let m = parse(loadTokens("import host\n" & source, mainName, "",
    resolver = resolver, mainLineOffset = -1))
  if not host.allowExterns and m.externLibs.len > 0:
    fail("externs are disabled for scripts: " & m.externLibs[0])
  var dataNames: Table[string, string]
  for r in m.routines:
    if r.line div fileLineBase < m.files.len and m.files[r.line div fileLineBase] == "host.nifty":
      r.hostBinding = true
      r.externLib = "nifty.host"
      r.cname = m.sourceNames.getOrDefault(r.name, r.name)
    elif r.externLib != "":
      var allowed = false
      for f in host.foreign:
        if f.library == r.externLib and f.symbol == (if r.cname == "": r.name else: r.cname):
          allowed = true
      if not allowed: fail("FFI is disabled for scripts: " & r.externLib & "." & r.name)
  for g in m.globals:
    if g.line div fileLineBase < m.files.len and m.files[g.line div fileLineBase] == "host.nifty":
      dataNames[g.name] = m.sourceNames.getOrDefault(g.name, g.name)
  # Embedding makes globals observable across invocations. A private observer
  # expresses that additional use to the ordinary smallest-scope checker.
  var observer = "niftyScriptObserve"
  var occupied: HashSet[string]
  for token in lexer.tokenize(source): occupied.incl token.text
  for r in m.routines: occupied.incl r.name
  for g in m.globals: occupied.incl g.name
  while observer in occupied: observer.add "_"
  var body: seq[Stmt]
  for g in m.globals:
    body.add Stmt(kind: DiscardStmt, line: g.line,
      value: Expr(kind: IdentExpr, sval: g.name, line: g.line))
  if body.len > 0:
    m.routines.add Routine(kind: ProcRoutine, name: observer, line: 1, body: body)
  var roots = 0
  for r in m.routines:
    if r.kind == ThreadRoutine:
      roots += r.instances
  if roots != 1: fail("scripts require exactly one thread entry (run on the host thread)")
  check(m)
  var routineTab: Table[string, Routine]
  for r in m.routines: routineTab[r.name] = r
  proc dataRoot(e: Expr): bool =
    if e == nil: return false
    if e.kind == IdentExpr: return e.sval in dataNames
    if e.kind in {FieldExpr, IndexExpr, UnionProjectExpr} and e.kids.len > 0:
      return dataRoot(e.kids[0])
  proc auditExpr(e: Expr) =
    if e == nil: return
    if e.kind == CallExpr and e.sval in routineTab:
      let callee = routineTab[e.sval]
      for i, param in callee.params:
        if param.isVar and i < e.kids.len and dataRoot(e.kids[i]):
          fail("host data is read-only")
    if e.kind == MethodExpr and e.sval in mutMethods and e.kids.len > 0 and
        dataRoot(e.kids[0]): fail("host data is read-only")
    for kid in e.kids: auditExpr(kid)
  var auditedTypes: HashSet[pointer]
  proc auditType(t: Typ, depth = 0) =
    if t == nil: return
    if cast[pointer](t) in auditedTypes: return
    if depth > limits.maxSyntaxDepth: fail("script type depth limit exceeded")
    auditedTypes.incl cast[pointer](t)
    if t.kind in {LockType, ChannelType}: fail("scripts cannot create OS locks or channels")
    auditType(t.elem, depth + 1)
    auditType(t.val, depth + 1)
    for field in t.fields: auditType(field.typ, depth + 1)
    for member in t.members: auditType(member, depth + 1)
    if t.kind != TypeVarType and typeSize(t) > limits.maxMemoryBytes:
      fail("script static storage exceeds memory limit")
  proc auditBody(body: seq[Stmt]) =
    for s in body:
      if s.kind in {AssignStmt, WithStmt} and dataRoot(s.lhs): fail("host data is read-only")
      auditType(s.typ)
      for e in [s.init, s.lhs, s.rhs, s.value, s.cond, s.lo, s.hi]: auditExpr(e)
      for e in s.args: auditExpr(e)
      auditBody(s.body)
      auditBody(s.elseBody)
      for branch in s.elifs:
        auditExpr(branch.cond)
        auditBody(branch.body)
  var globalSize = 0'i64
  for g in m.globals:
    auditType(g.typ)
    globalSize += typeSize(g.typ) + 16
    if globalSize > limits.maxMemoryBytes: fail("script globals exceed memory limit")
  for r in m.routines:
    for p in r.params: auditType(p.typ)
    auditType(r.ret)
    auditBody(r.body)
  let echoLibrary = parse(lexer.tokenize(echoSource &
    "thread niftyEchoBootstrap() =\n  discard 0\n"))
  for r in echoLibrary.routines:
    if r.kind != ThreadRoutine:
      r.hostBinding = true
      r.externLib = "nifty.host"
      r.cname = "$" & r.name
  check(echoLibrary)
  for i in countdown(echoLibrary.routines.high, 0):
    if echoLibrary.routines[i].kind == ThreadRoutine: echoLibrary.routines.delete(i)
  # lowerEcho consumes these already-typed callback declarations and generates
  # the same capture/order semantics as the command-line compiler.
  new(result)
  result.plan = lowerNative(m, mainName, echoLibrary = echoLibrary)
  result.host = host
  result.limits = limits
  validateNativePlan(result.plan, result.plan.module.functions.len, allowEmbedded = true)
  var instructions = 0
  for f in result.plan.module.functions:
    instructions += f.instructions.len + f.blocks.len
  if instructions > limits.maxCodeInstructions: fail("script code size limit exceeded")
  if result.plan.lockOffsets.len > 0 or result.plan.channelOffsets.len > 0:
    fail("scripts cannot create OS synchronization")
  for g in m.globals:
    for irGlobal in result.plan.module.globals:
      if irGlobal.name == g.name:
        var layout = -1
        # All host/global layouts are canonicalized by the lowering pass.
        for i, l in result.plan.layouts:
          if l.kind == g.typ.kind and
              l.bytes == typeSize(g.typ) and l.dynamic == g.typ.dynamic and
              l.capacity == g.typ.len and l.optional == g.typ.opt and
              l.lower == g.typ.rlo and l.upper == g.typ.rhi:
            layout = i
        if layout >= 0:
          let descriptor = Global(offset: int(irGlobal.offset),
            layout: layout, readonly: g.name in dataNames)
          if g.name in dataNames: result.inputs[dataNames[g.name]] = descriptor
          else: result.globals[g.name] = descriptor
  result.interpreter = prepareInterpreter(result.plan.module)

proc compile*(source: string, host: Host = initHost(),
    limits = defaultLimits(), filename = "script.nifty"): Program =
  try:
    result = compileSource(source, host, limits, filename)
  except ScriptError:
    raise
  except NiftyError as error:
    raise newException(ScriptError, error.msg)

proc cRealloc(address: pointer, bytes: csize_t): pointer
    {.importc: "realloc", header: "<stdlib.h>", raises: [].}
proc cFree(address: pointer)
    {.importc: "free", header: "<stdlib.h>", raises: [].}
proc snprintf(buffer: pointer, count: csize_t, format: cstring): cint
    {.importc, varargs, header: "<stdio.h>".}

proc echoFloat(number: float64): string =
  ## The same bounded %g presentation as the command-line echo library.
  var buffer: array[64, char]
  let count = int(snprintf(addr buffer[0], csize_t(buffer.len), "%g", number))
  if count < 0 or count >= buffer.len: fail("script float formatting failed")
  result = newString(count)
  if count > 0: copyMem(addr result[0], addr buffer[0], count)

proc `=destroy`(pool: var MemoryPool) =
  for allocation in pool.allocations:
    if allocation.address != nil: cFree(allocation.address)
  `=destroy`(pool.allocations)

var activePool {.threadvar.}: ptr MemoryPool

{.push checks: off.}
proc trackedReallocate(address: pointer, bytes: csize_t): pointer
    {.cdecl, raises: [].} =
  ## NativeMemory has no user pointer; save/restore this thread-local scope
  ## around execution, including when a callback runs a different runtime.
  let pool = activePool
  if pool == nil: return nil
  var slot = -1
  var scanned = 0'i64
  for i, allocation in pool.allocations:
    inc scanned
    if allocation.address == address and (address != nil or slot < 0):
      slot = i
      break
  if slot < 0 or bytes > csize_t(pool.budget.maxMemory):
    pool.failed = true
    return nil
  let old = pool.allocations[slot].bytes
  let size = int64(bytes)
  let growth = size - old
  if growth > pool.budget.maxMemory - pool.budget.memory or
      (pool.meterWork and (scanned > pool.budget.maxWork - pool.budget.work or
      size > pool.budget.maxWork - pool.budget.work - scanned)):
    pool.failed = true
    return nil
  result = cRealloc(address, bytes)
  if result == nil and bytes != 0:
    pool.failed = true
    return
  pool.allocations[slot] = Allocation(address: result, bytes: size)
  pool.liveBytes += growth
  pool.budget.memory += growth
  pool.budget.peakMemory = max(pool.budget.peakMemory, pool.budget.memory)
  if pool.meterWork: pool.budget.work += size + scanned

proc trackedRelease(address: pointer) {.cdecl, raises: [].} =
  if activePool == nil or address == nil: return
  for allocation in activePool.allocations.mitems:
    if activePool.meterWork:
      if activePool.budget.work < activePool.budget.maxWork:
        inc activePool.budget.work
      else: activePool.failed = true
    if allocation.address == address:
      cFree(address)
      activePool.liveBytes -= allocation.bytes
      activePool.budget.memory -= allocation.bytes
      allocation = Allocation()
      return
{.pop.}

const scriptMemory = NativeMemory(reallocate: trackedReallocate, release: trackedRelease)

proc checkAllocation(runtime: Runtime) =
  if runtime.pool.failed:
    runtime.failed = true
    raise newException(ExecutionLimitError, "script allocation or resource limit exceeded")

proc idle(runtime: Runtime) =
  if runtime == nil: fail("nil scripting runtime")
  if runtime.running: fail("runtime is already executing")

proc readValue(runtime: Runtime, address: pointer, layout: NativeLayout): Value =
  if layout.optional: fail("optional globals require a script accessor")
  case layout.kind
  of IntType: value(integer(address, layout))
  of FloatType:
    if layout.bytes == 4: value(cast[ptr float32](address)[])
    else: value(cast[ptr float64](address)[])
  of BoolType: value(cast[ptr uint8](address)[] != 0)
  of StringType:
    let count = cast[ptr int64](address)[]
    if count < 0 or count > runtime.budget.maxMemory:
      fail("invalid script string length")
    var text = newString(int(count))
    if count > 0:
      let source = if layout.dynamic: cast[ptr pointer](at(address, 16))[]
        else: at(address, layout.dataOffset)
      if source == nil: fail("invalid script string storage")
      copyMem(addr text[0], source, int(count))
    value(text)
  else: fail("aggregate globals require a script accessor")

proc writeValue(runtime: Runtime, address: pointer, layout: NativeLayout, v: Value) =
  if layout.optional: fail("optional globals require a script accessor")
  case layout.kind
  of IntType:
    let number = v.asInt()
    if number < layout.lower or number > layout.upper:
      fail("host integer is outside the script type's range")
    writeInteger(address, layout, number)
  of FloatType:
    let number = v.asFloat()
    if layout.bytes == 4: cast[ptr float32](address)[] = float32(number)
    else: cast[ptr float64](address)[] = number
  of BoolType: cast[ptr uint8](address)[] = uint8(v.asBool())
  of StringType:
    let text = v.asString()
    if int64(text.len) > runtime.budget.maxMemory: fail("host string exceeds memory limit")
    if layout.dynamic:
      let previousPool = activePool
      activePool = addr runtime.pool
      defer: activePool = previousPool
      let previous = cast[ptr pointer](at(address, 16))[]
      let allocated = trackedReallocate(previous, csize_t(text.len + 24))
      runtime.checkAllocation()
      cast[ptr int64](at(address, 8))[] = int64(text.len)
      cast[ptr pointer](at(address, 16))[] = allocated
      if text.len > 0: copyMem(allocated, unsafeAddr text[0], text.len)
    else:
      if int64(text.len) > layout.capacity: fail("host string exceeds fixed string capacity")
      if text.len > 0: copyMem(at(address, layout.dataOffset), unsafeAddr text[0], text.len)
    cast[ptr int64](address)[] = int64(text.len)
  else: fail("aggregate globals require a script accessor")

proc global(runtime: Runtime, name: string): Global =
  if name in runtime.program.globals: return runtime.program.globals[name]
  if name in runtime.program.inputs: return runtime.program.inputs[name]
  if name.startsWith("host.") and name[5 .. ^1] in runtime.program.inputs:
    return runtime.program.inputs[name[5 .. ^1]]
  fail("unknown script global: " & name)

proc input(runtime: Runtime, name: string): Global =
  if name notin runtime.program.inputs: fail("unknown host data: " & name)
  runtime.program.inputs[name]

proc getGlobal*(runtime: Runtime, name: string): Value =
  runtime.idle()
  if runtime.failed: fail("reset the runtime after a failed invocation")
  let g = runtime.global(name)
  runtime.readValue(at(runtime.prefix.globals, g.offset), runtime.program.plan.layouts[g.layout])

proc setGlobal*(runtime: Runtime, name: string, v: Value) =
  runtime.idle()
  if runtime.failed: fail("reset the runtime after a failed invocation")
  let g = runtime.global(name)
  if g.readonly: fail("host data is read-only; use setData")
  runtime.writeValue(at(runtime.prefix.globals, g.offset), runtime.program.plan.layouts[g.layout], v)

proc setData*(runtime: Runtime, name: string, v: Value) =
  runtime.idle()
  if runtime.failed: fail("reset the runtime after a failed invocation")
  let g = runtime.input(name)
  runtime.writeValue(at(runtime.prefix.globals, g.offset), runtime.program.plan.layouts[g.layout], v)
  for data in runtime.host.data.mitems:
    if data.name == name: data.value = v

proc reset*(runtime: Runtime) =
  ## Clears globals and abandoned allocations, preserving host data/callbacks.
  runtime.idle()
  for allocation in runtime.pool.allocations.mitems:
    if allocation.address != nil: cFree(allocation.address)
    allocation = Allocation()
  runtime.budget.memory -= runtime.pool.liveBytes
  runtime.pool.liveBytes = 0
  runtime.pool.failed = false
  runtime.budget.work = 0
  runtime.budget.peakMemory = runtime.budget.memory
  runtime.outputBytes = 0
  runtime.failed = false
  runtime.finished = false
  zeroMem(runtime.prefix.globals, runtime.program.plan.globalBytes)
  if runtime.program.plan.initialData.len > 0:
    copyMem(runtime.prefix.globals, unsafeAddr runtime.program.plan.initialData[0],
      runtime.program.plan.initialData.len)
  for data in runtime.host.data:
    let g = runtime.input(data.name)
    runtime.writeValue(at(runtime.prefix.globals, g.offset), runtime.program.plan.layouts[g.layout], data.value)
  runtime.budget.work = 0

proc restart*(runtime: Runtime) =
  ## Replenishes invocation budgets and preserves persistent script globals.
  runtime.idle()
  if runtime.failed: fail("reset the runtime after a failed invocation")
  runtime.budget.work = 0
  runtime.budget.peakMemory = runtime.budget.memory
  runtime.outputBytes = 0
  runtime.finished = false

proc alignedAddress(bytes: var seq[byte]): pointer =
  cast[pointer]((cast[uint](addr bytes[0]) + 15'u) and not 15'u)

proc initRuntimeWithHost(program: Program, host: Host): Runtime =
  if program == nil: fail("nil scripting program")
  new(result)
  result.program = program
  result.host = host
  let limits = program.limits
  result.budget = ExecutionBudget(maxWork: limits.maxWork,
    maxMemory: limits.maxMemoryBytes, maxDepth: limits.maxCallDepth)
  result.pool.budget = addr result.budget
  # Account for both backing storage and allocation records before allocating.
  let fixed = int64(program.plan.globalBytes) +
    int64(program.plan.threads[0].arenaBytes) + int64(limits.maxAllocations) * 16 + 1056
  (addr result.budget).acquire(fixed)
  result.globals = newSeq[byte](program.plan.globalBytes + 16)
  result.arena = newSeq[byte](program.plan.threads[0].arenaBytes + 16)
  result.pool.allocations = newSeq[Allocation](limits.maxAllocations)
  result.prefix.globals = alignedAddress(result.globals)
  for i, irHost in program.plan.module.hosts:
    let host = program.plan.hosts[int(irHost.binding)]
    if host.kind == ExternHost:
      if result.foreign.len == 0:
        result.foreign = newSeq[ForeignCall](program.plan.module.hosts.len)
      var allowed = false
      for permission in result.host.foreign:
        if permission.library == host.library and permission.symbol == host.symbol and
            permission.parameters == irHost.signature.parameters and
            permission.returns == irHost.signature.returns:
          result.foreign[i] = prepareForeign(irHost.signature, permission.address)
          allowed = true
      if not allowed: fail("FFI signature is not enabled by the host: " & host.library & "." & host.symbol)
  result.reset()

proc initRuntime*(program: Program): Runtime =
  if program == nil: fail("nil scripting program")
  initRuntimeWithHost(program, program.host)

proc initRuntime*(program: Program, host: Host): Runtime =
  ## A compiled program may be shared by independent, schema-compatible hosts.
  if program == nil: fail("nil scripting program")
  if host.functions.len != program.host.functions.len or
      host.data.len != program.host.data.len:
    fail("host schema does not match the compiled program")
  for expected in program.host.functions:
    var found = false
    for actual in host.functions:
      if actual.name == expected.name and actual.parameters == expected.parameters and
          actual.returns == expected.returns and actual.query == expected.query and
          actual.workUnits == expected.workUnits:
        found = true
    if not found: fail("host function schema mismatch: " & expected.name)
  for expected in program.host.data:
    var found = false
    for actual in host.data:
      if actual.name == expected.name and actual.value.kind == expected.value.kind: found = true
    if not found: fail("host data schema mismatch: " & expected.name)
  initRuntimeWithHost(program, host)

proc newContext*(source: string, host: Host = initHost(),
    limits = defaultLimits()): Runtime =
  ## Convenience form for applications that do not need to share a Program.
  initRuntime(compile(source, host, limits))

proc setData*(host: var Host, name: string, v: Value) =
  for data in host.data.mitems:
    if data.name == name:
      if data.value.kind != v.kind: fail("host data type cannot change")
      data.value = v
      return
  fail("unknown host data: " & name)

proc setData*[T: SomeInteger | SomeFloat | bool | string](runtime: Runtime, name: string, v: T) =
  runtime.setData(name, value(v))
proc setGlobal*[T: SomeInteger | SomeFloat | bool | string](runtime: Runtime, name: string, v: T) =
  runtime.setGlobal(name, value(v))
proc setData*[T: SomeInteger | SomeFloat | bool | string](host: var Host, name: string, v: T) =
  host.setData(name, value(v))

proc emit(runtime: Runtime, text: string) =
  if int64(text.len) > runtime.program.limits.maxOutputBytes - runtime.outputBytes:
    raise newException(ExecutionLimitError, "script output limit exceeded")
  (addr runtime.budget).spend(int64(text.len))
  runtime.outputBytes += int64(text.len)
  if runtime.print != nil: runtime.print(text)

proc executeHost(context: pointer, hostIndex: int, arguments: openArray[uint64],
    returns: var openArray[uint64]) {.nimcall, gcsafe.} =
  {.cast(gcsafe).}:
    let runtime = cast[Runtime](context)
    let host = runtime.program.plan.hosts[int(runtime.program.plan.module.hosts[hostIndex].binding)]
    case host.kind
    of ExternHost:
      (addr runtime.budget).spend()
      callForeign(addr runtime.foreign[hostIndex], arguments, returns)
    of ContainerHost:
      # Conservative charge covers traversal/copy/destruction of nested owners.
      # Allocation callbacks additionally charge requested allocation bytes.
      let cost = runtime.program.plan.layouts[host.receiverType].bytes + runtime.pool.liveBytes
      (addr runtime.budget).spend(max(1'i64, cost))
      executeContainer(host, runtime.program.plan.layouts, cast[pointer](arguments[2]),
        cast[pointer](arguments[3]), cast[pointer](arguments[4]), scriptMemory)
      runtime.checkAllocation()
    of EmbeddedHost:
      let args = cast[pointer](arguments[3])
      var values: seq[Value]
      var bridgeBytes = 0'i64
      defer: (addr runtime.budget).release(bridgeBytes)
      for i, typ in host.paramTypes:
        var address = at(args, host.paramOffsets[i])
        if host.paramVars[i]: address = cast[ptr pointer](address)[]
        let layout = runtime.program.plan.layouts[typ]
        if layout.kind == StringType:
          let length = cast[ptr int64](address)[]
          (addr runtime.budget).spend(length)
          (addr runtime.budget).acquire(length)
          bridgeBytes += length
        values.add runtime.readValue(address, runtime.program.plan.layouts[typ])
      if host.operation.startsWith("$"):
        case host.operation
        of "$echoStart": discard
        of "$echoFinish": runtime.emit("\n")
        of "$echoText": runtime.emit(values[0].asString())
        of "$echoInt": runtime.emit($values[0].asInt())
        of "$echoFloat": runtime.emit(echoFloat(values[0].asFloat()))
        of "$echoBool": runtime.emit(if values[0].asBool(): "true" else: "false")
        of "$echoChar": runtime.emit($char(values[0].asInt()))
        else: fail("invalid internal script callback")
      else:
        var found = false
        for f in runtime.host.functions:
          if f.name == host.operation:
            found = true
            (addr runtime.budget).spend(f.workUnits)
            let returned = f.callback(values)
            if returned.kind != f.returns: fail("host callback returned the wrong type: " & f.name)
            if host.resultType >= 0:
              runtime.writeValue(cast[pointer](arguments[4]),
                runtime.program.plan.layouts[host.resultType], returned)
            break
        if not found: fail("host callback is not registered: " & host.operation)
    of ReservedHost, LockHost:
      fail("unsupported service in a script")

proc run*(runtime: Runtime, print: PrintProc = nil): RunStats =
  ## Runs one invocation. Callback exceptions return to the Nim caller.
  runtime.idle()
  if runtime.failed: fail("reset the runtime after a failed invocation")
  if runtime.finished: fail("restart the runtime before another invocation")
  runtime.running = true
  runtime.pool.meterWork = true
  runtime.print = print
  let previousPool = activePool
  activePool = addr runtime.pool
  defer:
    activePool = previousPool
    runtime.running = false
    runtime.pool.meterWork = false
    runtime.print = nil
  try:
    discard interpret(addr runtime.program.interpreter,
      runtime.program.plan.threads[0].functionIndex,
      [cast[uint64](addr runtime.prefix), 0'u64, 0'u64,
        cast[uint64](alignedAddress(runtime.arena))], executeHost,
      cast[pointer](runtime), addr runtime.budget)
    runtime.checkAllocation()
    runtime.finished = true
  except CatchableError:
    runtime.failed = true
    raise
  RunStats(work: runtime.budget.work, peakMemoryBytes: runtime.budget.peakMemory,
    outputBytes: runtime.outputBytes)

