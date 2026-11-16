## Prepares checked native IR while keeping runtime function indices stable.
import nativeplans, nativemaths, backend/[irchecks, irinlines, iroptimizations]

type NativeOptimization* = enum
  NoOptimization, SpeedOptimization

proc optimizeNative*(plan: NativePlan,
    optimization = SpeedOptimization,
    specializeMath = true, fastMultiplyHigh = false): NativePlan =
  ## Simplifies storage, expands bounded calls, then cleans the resulting CFG.
  result = plan
  verifyIr(result.module)
  if optimization == SpeedOptimization:
    if specializeMath:
      discard result.specializeNativeMaths()
    optimizeIr(result.module, fastMultiplyHigh = fastMultiplyHigh)
    var config = defaultInlineConfig()
    for round in 0 ..< 3:
      let stats = inlineIr(result.module, config)
      if stats.callsInlined == 0:
        break
      config.maxModuleGrowth -= stats.instructionsAdded
      config.maxCalls -= stats.callsInlined
      optimizeIr(result.module, fastMultiplyHigh = fastMultiplyHigh)
  verifyIr(result.module)
