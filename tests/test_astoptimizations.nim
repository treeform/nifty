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
echo "Checked AST literal, branch, scope and effect folding passed"
