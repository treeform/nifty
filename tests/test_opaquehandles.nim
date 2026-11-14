## Nominal pointer safety and consistent C/native foreign handle layouts.
import std/[os, strutils]
import ../src/nifty
import ../src/nifty/[types, lowering, nativefiles]

proc rejected(source, message: string) =
  var failure = ""
  try:
    discard checkedModule(source, "opaque_test.nifty")
  except NiftyError as error:
    failure = error.msg
  doAssert failure.contains(message), failure

const prefix = "type File = opaque\ntype Socket = opaque\n"

rejected(prefix & """
thread main() =
  let file: File = 1
  echo file.isNull
""", "type mismatch")
rejected(prefix & """
thread main() =
  let file = File(1)
  echo file.isNull
""", "unknown func or proc")
rejected(prefix & """
thread main() =
  var file: File
  var socket: Socket
  file = socket
  echo file.isNull
""", "cannot assign")
rejected(prefix & """
extern "libc":
  proc consume(file: File)
thread main() =
  var socket: Socket
  consume(socket)
""", "argument 1")
rejected(prefix & """
thread main() =
  var file: File
  let number: int = file
  echo number
""", "type mismatch")
rejected(prefix & """
func wrap(socket: Socket): File? =
  return socket
thread main() =
  discard 0
""", "return type mismatch")
for operation in ["+", "-", "*", "/", "%", "<", "<=", ">", ">="]:
  rejected(prefix & """
thread main() =
  var file: File
  echo file """ & operation & " file\n", "opaque handles support only")
for expression in ["file == socket", "file != socket", "file == 0"]:
  rejected(prefix & """
thread main() =
  var file: File
  var socket: Socket
  echo """ & expression & "\n", "opaque handles support only")
for expression in ["file[0]", "file.toInt", "file.value", "float64(file)"]:
  rejected(prefix & """
thread main() =
  var file: File
  echo """ & expression & "\n", "opaque_test.nifty:")
rejected(prefix & """
extern "libc":
  proc obtain(): File?
thread main() =
  discard obtain()
""", "optionals cannot cross the C boundary")
rejected(prefix & """
extern "libc":
  proc consume(file: File?)
thread main() =
  discard 0
""", "optionals cannot cross the C boundary")
rejected(prefix & """
thread main() =
  var file: File?
  echo file.isNull
""", "before proving it has a value")
rejected("type int = opaque\n", "reserved type name")
rejected("type File = opaque\ntype File = opaque\n", "duplicate")

let fixture = currentSourcePath().parentDir / "scripts" / "opaque_handles.nifty"
let source = readFile(fixture)
let checked = checkedModule(source, fixture)
let fileType = checked.types[0].typ
let charType = checked.types[1].typ
let slotType = checked.types[2].typ

doAssert fileType.kind == OpaqueType
doAssert not typeEq(fileType, charType)
doAssert not typeEq(fileType, intType())
doAssert typeEq(fileType, deOpt(optOf(fileType)))
doAssert typeSize(fileType) == 8 and typeAlign(fileType) == 8
doAssert typeSize(optOf(fileType)) == 16
doAssert typeSize(slotType) == 16
let generated = compileToC(source, fixture)
doAssert generated.contains("void * ni_extern_tmpfile")
doAssert generated.contains("void * *") # var handle is a pointer to a pointer.

let plan = lowerNative(checked, fixture)
var handleLayout = -1
for i, layout in plan.layouts:
  if layout.kind == OpaqueType:
    doAssert layout.align == 8
    doAssert layout.bytes == (if layout.optional: 16 else: 8)
    if not layout.optional:
      handleLayout = i
doAssert handleLayout >= 0
for target in [Amd64Target, Arm64Target]:
  let program = buildNativeProgram(plan, target)
  let encoded = encodeNative(program)
  doAssert encodeNative(decodeNative(encoded)) == encoded
  var invalid = decodeNative(encoded)
  invalid.plan.layouts[handleLayout].bytes = 4
  var failed = false
  try:
    validateNative(invalid)
  except NiftyError:
    failed = true
  doAssert failed

echo "opaque handle checks passed"
