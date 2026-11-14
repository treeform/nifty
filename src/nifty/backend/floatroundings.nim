proc roundSingle*(value: float32): float32 {.raises: [].} =
  ## Rounds float32 ties away from zero without a platform math dependency.
  let
    bits = cast[uint32](value)
    sign = bits and 0x80000000'u32
    magnitude = bits and 0x7fffffff'u32
  if magnitude < 0x3f000000'u32:
    return cast[float32](sign)
  if magnitude < 0x3f800000'u32:
    return cast[float32](sign or 0x3f800000'u32)
  if magnitude >= 0x4b000000'u32:
    return cast[float32](
      if magnitude > 0x7f800000'u32: bits or 0x00400000'u32
      else: bits)
  let
    shift = 150 - int(magnitude shr 23)
    fraction = (1'u32 shl shift) - 1
    half = 1'u32 shl (shift - 1)
  cast[float32](sign or ((magnitude + half) and not fraction))
