## Builds the compiler and native runtime templates once for distribution.
import std/[os, osproc]

let root = currentSourcePath().parentDir.parentDir
let nim = findExe("nim")
if nim.len == 0:
  quit("Nim is required to build the Nifty compiler", 1)

proc build(output: string, options: seq[string]) =
  ## Builds one compiler binary, which also serves as a native runtime.
  var args = @["c", "-d:release", "--out:" & root / output]
  args.add(options)
  args.add(root / "src/nifty.nim")
  let command = quoteShell(nim) & " " & args.quoteShellCommand()
  if execCmd(command) != 0:
    quit("Nifty build failed: " & output, 1)

build("nifty", @[])
when defined(macosx) and defined(arm64):
  build("nifty-runtime-amd64", @[
    "--cpu:amd64", "--passC:-arch", "--passC:x86_64",
    "--passL:-arch", "--passL:x86_64"
  ])
echo "Built Nifty and available native runtime templates in ", root
