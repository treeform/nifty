## Selects an installed C compiler for the reference backend and its tests.
import std/os
import common

proc cCompileCommand*(source, output: string,
    libraries: openArray[string] = [],
    options: openArray[string] = []): string =
  ## Builds a shell-quoted GCC or Clang command with the language's C flags.
  var compiler = getEnv("CC")
  if compiler.len == 0:
    for name in ["cc", "gcc", "clang"]:
      compiler = findExe(name)
      if compiler.len > 0:
        break
  if compiler.len == 0:
    raise newException(NiftyError, "C backend requires cc, gcc, or clang; set CC")
  result = quoteShell(compiler) &
    " -O2 -pthread -fno-strict-aliasing -ffp-contract=off"
  when defined(windows):
    # Keep the reference executable independent of MinGW runtime DLLs.
    result.add " -static"
  for option in options:
    result.add " " & quoteShell(option)
  result.add " -o " & quoteShell(output) & " " & quoteShell(source)
  for library in libraries:
    if library != "libc":
      result.add " " & quoteShell("-l" & library)
