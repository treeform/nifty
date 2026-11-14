## Packages native images into a reusable standalone runtime executable.
import std/[os, osproc, strutils, tempfiles]
import common, nativefiles

const EmbeddedMagic = "NIFTY_EMBED_V001!"

proc number(data: string, offset, bytes: int): uint64 =
  ## Reads a little endian field from an executable header.
  if offset < 0 or offset > data.len - bytes:
    raise newException(NiftyError, "truncated native executable header")
  for i in 0 ..< bytes:
    result = result or (uint64(byte(data[offset + i])) shl (8 * i))

proc setNumber(data: var string, offset, bytes: int, value: uint64) =
  ## Updates one little endian executable field.
  if offset < 0 or offset > data.len - bytes:
    raise newException(NiftyError, "invalid native executable header")
  for i in 0 ..< bytes:
    data[offset + i] = char((value shr (8 * i)) and 255)

proc appendNumber(data: var string, value: uint64) =
  ## Appends an unsigned little endian footer field.
  for i in 0 ..< 8:
    data.add char((value shr (8 * i)) and 255)

proc embeddedImage*(data: string): string =
  ## Finds a validated embedded payload before a possible code signature.
  var position = data.rfind(EmbeddedMagic)
  while position >= 0:
    if position <= data.len - EmbeddedMagic.len - 16:
      let
        start = data.number(position + EmbeddedMagic.len, 8)
        size = data.number(position + EmbeddedMagic.len + 8, 8)
      if start <= uint64(position) and size == uint64(position) - start and
          size >= 40 and size <= 128 * 1024 * 1024 and
          data[int(start) ..< int(start) + 8] == "NIFTYN01":
        return data[int(start) ..< position]
    if position == 0:
      break
    position = data.rfind(EmbeddedMagic, 0, position - 1)

proc signing(command, path: string) =
  ## Uses the platform signing tool without compiling user programs.
  let response = execCmdEx("/usr/bin/codesign " & command & " " &
    quoteShell(path))
  if response.exitCode != 0:
    raise newException(NiftyError, "native executable signing failed: " &
      response.output.strip())

proc extendMachO(data: var string) =
  ## Includes the appended image in the MachO link edit segment for signing.
  if data.number(0, 4) != 0xfeedfacf'u64:
    raise newException(NiftyError,
      "standalone runtime template must be a thin 64-bit MachO executable")
  let commands = int(data.number(16, 4))
  var position = 32
  for i in 0 ..< commands:
    let
      command = data.number(position, 4)
      size = int(data.number(position + 4, 4))
    if size < 8 or position > data.len - size:
      raise newException(NiftyError, "invalid MachO load command")
    if command == 0x19 and size >= 72 and
        data[position + 8 ..< position + 18] == "__LINKEDIT":
      let
        fileOffset = data.number(position + 40, 8)
        fileSize = uint64(data.len) - fileOffset
        virtualSize = (fileSize + 16383) div 16384 * 16384
      data.setNumber(position + 32, 8, virtualSize)
      data.setNumber(position + 48, 8, fileSize)
      return
    position += size
  raise newException(NiftyError, "MachO runtime has no link edit segment")

proc runtimeTemplate(target: NativeTarget): string =
  ## Selects a matching prebuilt runtime without invoking a compiler.
  when defined(arm64):
    if target == Arm64Target:
      return getAppFilename()
  elif defined(amd64):
    if target == Amd64Target:
      return getAppFilename()
  let name = if target == Arm64Target: "arm64" else: "amd64"
  let configured = getEnv("NIFTY_RUNTIME_" & name.toUpperAscii())
  result = if configured.len > 0: configured
    else: getAppFilename().parentDir / "nifty-runtime-" & name
  if not fileExists(result):
    raise newException(NiftyError, "missing " & name &
      " runtime template; set NIFTY_RUNTIME_" & name.toUpperAscii())

proc validateTemplate(path: string, target: NativeTarget,
    platform: NativePlatform) =
  ## Rejects a template whose executable header disagrees with the image ABI.
  var file: File
  if not open(file, path, fmRead):
    raise newException(NiftyError, "cannot open standalone runtime template")
  defer: close(file)
  var header = newString(64)
  let read = file.readBuffer(addr header[0], header.len)
  header.setLen(read)
  var valid = false
  if platform == MacosPlatform and header.len >= 32 and
      header.number(0, 4) == 0xfeedfacf'u64:
    let expected = if target == Arm64Target: 0x100000c'u64 else: 0x1000007'u64
    valid = header.number(4, 4) == expected
  elif platform == LinuxPlatform and header.len >= 20 and
      header[0 ..< 4] == "\x7fELF" and header[4] == '\x02' and
      header[5] == '\x01':
    let expected = if target == Arm64Target: 183'u64 else: 62'u64
    valid = header.number(18, 2) == expected
  if not valid:
    raise newException(NiftyError,
      "standalone runtime template CPU or operating system ABI mismatch")

proc writeStandalone*(program: NativeProgram, path: string) =
  ## Copies a prebuilt runtime and embeds machine code with no compiler step.
  if program.platform != NativeHostPlatform:
    raise newException(NiftyError,
      "standalone packaging requires the host operating system ABI")
  let
    payload = program.encodeNative()
    source = runtimeTemplate(program.image.target)
    destination = absolutePath(path)
  if absolutePath(source) == destination:
    raise newException(NiftyError, "standalone output would replace its runtime")
  validateTemplate(source, program.image.target, program.platform)
  let temporary = createTempFile(".nifty-native-", "", destination.parentDir)
  close(temporary.cfile)
  let staging = temporary.path
  try:
    copyFile(source, staging)
    when defined(macosx):
      signing("--remove-signature", staging)
    var data = readFile(staging)
    let existing = data.embeddedImage()
    if existing.len > 0:
      raise newException(NiftyError,
        "standalone template already contains a native program")
    let start = uint64(data.len)
    data.add payload
    data.add EmbeddedMagic
    data.appendNumber(start)
    data.appendNumber(uint64(payload.len))
    when defined(macosx):
      data.extendMachO()
    writeFile(staging, data)
    setFilePermissions(staging,
      getFilePermissions(source) + {fpUserExec, fpGroupExec, fpOthersExec})
    when defined(macosx):
      signing("--force --sign -", staging)
      signing("--verify --strict", staging)
    if embeddedImage(readFile(staging)) != payload:
      raise newException(NiftyError, "native executable payload was not preserved")
    moveFile(staging, destination)
  finally:
    if fileExists(staging):
      removeFile(staging)
