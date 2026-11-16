## Checked AST folding preserves types, effects, scopes and the source tree.
import std/[os, strutils]
import ../src/nifty
import nifty/[nativeunroll, nativeoptimizations, types, codegen]

const Source = staticRead(currentSourcePath.parentDir / "native/ast_optimizations.nifty")
let original = checkedModule(Source, "ast_optimizations.nifty")
let before = generate(original, "ast_optimizations.nifty")
let folded = unrollNative(original)
doAssert generate(original, "ast_optimizations.nifty") == before

let main = folded.routines[^1]
doAssert main.body[0].args[0].kind == IntExpr
doAssert main.body[0].args[0].ival == 35
doAssert main.body[1].args[0].ival == -2
let choice = folded.routines[1].body[0]
doAssert choice.kind == IfStmt and choice.elifs.len == 1
doAssert choice.elifs[0].cond.kind == IdentExpr
doAssert choice.elifs[0].body[0].value.ival == 12
doAssert choice.elseBody[0].value.ival == -3
let expanded = main.body[4]
doAssert expanded.kind == BlockStmt and expanded.body.len == 3
for index, expected in [12'i64, 99, 14]:
  let selected = expanded.body[index].body[0]
  doAssert selected.kind == BlockStmt
  doAssert selected.body[0].args[0].ival == expected
# The false RHS does not make the effectful LHS disappear.
let effect = main.body[6].elifs[0].cond
doAssert effect.kind == BinExpr and effect.kids[0].kind == CallExpr
# Selected owning bodies retain a scope; semantics is rebuilt after rewriting.
doAssert main.body[8].kind == BlockStmt
doAssert folded.semantics.scopes[main.body[8].bodyScope].drops.len == 1
let optimizedC = compileToC(Source, "ast_optimizations.nifty")
doAssert "\"unused\"" notin optimizedC
doAssert "\"unused\"" in compileToC(Source, "ast_optimizations.nifty",
  optimization = NoOptimization)
var rejected = false
try:
  discard compileToC("thread main() =\n  if false:\n    echo 1 / 0\n", "invalid.nifty")
except NiftyError:
  rejected = true
doAssert rejected, "Source checking must happen before dead-branch removal"
block:
  const text = staticRead(currentSourcePath.parentDir / "native/ast_locals.nifty")
  let original = checkedModule(text, "ast_locals.nifty")
  let before = generate(original, "ast_locals.nifty")
  let folded = unrollNative(original)
  doAssert generate(original, "ast_locals.nifty") == before
  let body = folded.routines[^1].body
  doAssert body[1].init.kind == IntExpr and body[1].init.ival == 3
  doAssert body[2].kind == BlockStmt and body[2].body.len == 3
  for index, iteration in body[2].body:
    doAssert iteration.body[1].args[0].kind == IntExpr
    doAssert iteration.body[1].args[0].ival == int64(index * 2)
  doAssert body[4].kind == BlockStmt
  doAssert body[4].body[0].args[0].ival == 3
  doAssert body[5].body[1].args[0].ival == 5
  doAssert body[6].body[1].args[0].ival == 9
  # Mutable reads and evaluated initializers are not constant bindings.
  doAssert body[8].init.kind == IdentExpr
  doAssert body[10].args[0].kind == IdentExpr
  doAssert body[13].init.kind == CallExpr
  doAssert body[14].args[0].kind == IdentExpr
  doAssert body[18].args[0].kids[0].kind == IntExpr
  doAssert body[18].args[0].kids[0].typ.width == 1
  doAssert body[19].init.wrapOpt

block:
  const text = staticRead(currentSourcePath.parentDir / "native/ast_ranges.nifty")
  let original = checkedModule(text, "ast_ranges.nifty")
  let before = generate(original, "ast_ranges.nifty")
  let folded = unrollNative(original)
  doAssert generate(original, "ast_ranges.nifty") == before
  let classified = folded.routines[1].body[0]
  doAssert classified.kind == BlockStmt
  doAssert classified.body[0].value.ival == 3
  for index in [2, 3, 4]:
    let returned = folded.routines[index].body[0].value
    doAssert returned.kind == BoolExpr and returned.bval
  # Overlapping ranges remain conditional; zero exclusion and nested guards fold.
  doAssert folded.routines[5].body[0].kind == IfStmt
  let nonzero = folded.routines[6].body[0].elifs[0].body[0].value
  doAssert nonzero.kind == BoolExpr and not nonzero.bval
  let narrowed = folded.routines[7].body[0].elifs[0].body[0].value
  doAssert narrowed.kind == BoolExpr and narrowed.bval
  let main = folded.routines[^1].body
  # A known result cannot discard the call that produces it.
  let sampled = main[7].elifs[0].cond
  doAssert sampled.kind == BinExpr and sampled.kids[0].kind == CallExpr
  doAssert main[9].kind == BlockStmt and main[11].kind == BlockStmt
  let loop = main[13]
  doAssert loop.kind == WhileStmt and loop.cond.kind == BinExpr
  doAssert loop.body[0].kind == BlockStmt

echo "Checked AST literals, locals, ranges, scopes and effects passed"
