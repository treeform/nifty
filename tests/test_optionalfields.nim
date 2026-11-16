## A proven optional field must retain its representation when used by or().
import std/os
import ../src/nifty/[parser, lexer, checker, types]

const Source = staticRead(currentSourcePath.parentDir / "native/optional_fields.nifty")

let module = parse(tokenize(Source))
check(module)
let guard = module.routines[0].body[3]
let branch = guard.elifs[0].body
let fallback = branch[0].args[0]
doAssert fallback.kind == MethodExpr and fallback.sval == "or"
doAssert fallback.kids[0].typ.opt
doAssert not fallback.kids[0].unwrapOpt
doAssert branch[1].args[0].unwrapOpt
let reset = module.routines[0].body[4]
doAssert reset.lhs.typ.opt
doAssert not reset.lhs.unwrapOpt
doAssert reset.rhs.typ.opt
echo "Optional field fallback after a presence proof passed"
