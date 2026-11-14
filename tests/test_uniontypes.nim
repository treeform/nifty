## Verifies tagged layouts and type identity independently of code emission.
import ../src/nifty/[common, types]

let
  small = Typ(kind: ObjectType, name: "Small",
    fields: @[Field(name: "flag", typ: Typ(kind: BoolType))])
  number = Typ(kind: ObjectType, name: "Number",
    fields: @[Field(name: "value", typ: intType())])
  value = Typ(kind: UnionType, name: "Value", members: @[small, number])

doAssert typeSize(value) == 16
doAssert typeAlign(value) == 8
doAssert unionPayloadOffset(value) == 8
doAssert unionMember(value, number)
doAssert not unionMember(value, Typ(kind: ObjectType, name: "Other"))
doAssert needsDefaultInit(value)
doAssert needsDefaultInit(Typ(kind: ArrayType, len: 3, elem: value))
doAssert not needsDefaultInit(Typ(kind: SeqType, len: 3, elem: value))
doAssert not needsDefaultInit(optOf(value))

let
  children = Typ(kind: SeqType, dynamic: true, elem: value)
  array = Typ(kind: ObjectType, name: "Array",
    fields: @[Field(name: "items", typ: children)])
value.members.add(array)
doAssert typeSize(value) == 32
doAssert typeSize(array) == 24
doAssert hasOwned(value)
doAssert hasOwned(array)

let module = Module(types: @[
  TypeDef(name: "Value", typ: value),
  TypeDef(name: "Alias", typ: number)])
module.assignTypeIds()
doAssert value.typeId > 0 and number.typeId > 0 and array.typeId > 0
doAssert value.typeId != number.typeId
doAssert number.typeId != array.typeId
doAssert module.ensureTypeId(Typ(kind: ObjectType, name: "Number")) ==
  number.typeId
doAssert module.ensureTypeId(children) == module.ensureTypeId(
  Typ(kind: SeqType, dynamic: true,
    elem: Typ(kind: UnionType, name: "Value")))
doAssert module.ensureTypeId(intType()) ==
  module.ensureTypeId(intType())
doAssert module.ensureTypeId(optOf(number)) != number.typeId

let recursive = Typ(kind: ObjectType, name: "Recursive")
recursive.fields.add(Field(name: "self", typ: recursive))
var rejected = false
try:
  discard typeSize(recursive)
except NiftyError:
  rejected = true
doAssert rejected, "Inline recursive objects need a finite-layout diagnostic"

echo "Union layouts and identities passed"
