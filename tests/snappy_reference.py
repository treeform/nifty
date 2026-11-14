"""Small independent raw Snappy oracle; deliberately favors clarity over speed."""


def varint(value):
  """Encode a nonnegative uint32 length."""
  assert 0 <= value <= 0xffffffff
  result = bytearray()
  while value >= 128:
    result.append((value & 127) | 128)
    value >>= 7
  result.append(value)
  return bytes(result)


def literal(data, width=None):
  """Encode one literal, optionally forcing a legal extended length width."""
  assert data
  length = len(data) - 1
  if width is None and length < 60:
    return bytes([length << 2]) + data
  width = width or max(1, (length.bit_length() + 7) // 8)
  assert 1 <= width <= 4 and length < 1 << (8 * width)
  return bytes([(59 + width) << 2]) + length.to_bytes(width, 'little') + data


def literalBlock(data):
  """Encode a complete raw block without using copy instructions."""
  return varint(len(data)) + (literal(data) if data else b'')


def decode(data, maxOutput=16 * 1024 * 1024):
  """Decode raw Snappy, rejecting truncated, overflowing, or invalid blocks."""
  cursor = 0
  size = 0
  for index in range(5):
    if cursor == len(data):
      raise ValueError('Truncated length')
    byte = data[cursor]
    cursor += 1
    if index == 4 and byte > 15:
      raise ValueError('Overflowing length')
    size |= (byte & 127) << (7 * index)
    if byte < 128:
      break
  else:
    raise ValueError('Overflowing length')
  if size > maxOutput or maxOutput < 0:
    raise ValueError('Output limit')
  result = bytearray()
  while cursor < len(data):
    tag = data[cursor]
    cursor += 1
    kind = tag & 3
    if kind == 0:
      count = tag >> 2
      if count >= 60:
        width = count - 59
        if cursor + width > len(data):
          raise ValueError('Truncated literal length')
        count = int.from_bytes(data[cursor:cursor + width], 'little')
        cursor += width
      count += 1
      if count > size - len(result) or cursor + count > len(data):
        raise ValueError('Invalid literal length')
      result.extend(data[cursor:cursor + count])
      cursor += count
    else:
      width = (1, 2, 4)[kind - 1]
      if cursor + width > len(data):
        raise ValueError('Truncated copy offset')
      offset = int.from_bytes(data[cursor:cursor + width], 'little')
      cursor += width
      if kind == 1:
        offset |= (tag & 224) << 3
        count = 4 + ((tag >> 2) & 7)
      else:
        count = 1 + (tag >> 2)
      if not 0 < offset <= len(result) or count > size - len(result):
        raise ValueError('Invalid copy')
      for unused in range(count):
        result.append(result[-offset])
  if len(result) != size:
    raise ValueError('Length mismatch')
  return bytes(result)
