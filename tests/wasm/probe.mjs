import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { createInstance } from '../../tools/wasm/host.mjs';

// Adds an independent high-address load to the actual compiler output.
const bytes = new Uint8Array(await readFile(process.argv[2]));
const original = await WebAssembly.compile(bytes);
const imports = WebAssembly.Module.imports(original);
assert.ok(imports.every(entry => entry.module === 'wasi_snapshot_preview1' &&
  ['fd_write', 'proc_exit', 'clock_time_get'].includes(entry.name)));

if (process.argv[3] === '--io-boundary') {
  // Runs the real C staging bridge with deliberately partial WASI replies.
  function exercise(zeroProgress) {
    let memory;
    let calls = 0;
    const output = [];
    const instance = new WebAssembly.Instance(original, {
      wasi_snapshot_preview1: {
        fd_write(fd, vectors, count, written) {
          calls++;
          assert.ok(fd === 1 || fd === 2);
          const view = new DataView(memory.buffer);
          let sent = 0;
          for (let i = 0; i < (count >>> 0) && !sent; i++) {
            const start = view.getUint32((vectors >>> 0) + i * 8, true);
            const size = view.getUint32((vectors >>> 0) + i * 8 + 4, true);
            if (size && !zeroProgress) {
              if (fd === 1) output.push(view.getUint8(start));
              sent = 1;
            }
          }
          view.setUint32(written >>> 0, sent, true);
          return 0;
        },
        proc_exit(status) {
          const error = new Error('WASI exit');
          error.wasiExit = true;
          error.status = status;
          throw error;
        },
        clock_time_get() { return 52; }
      }
    });
    memory = instance.exports.memory;
    let status = 0;
    try {
      instance.exports._start();
    } catch (error) {
      if (!error.wasiExit) throw error;
      status = error.status;
    }
    assert.ok(calls > 0, 'Program must exercise the C-to-WASI bridge');
    if (zeroProgress) {
      assert.notEqual(status, 0, 'Zero progress must exit with an error');
      assert.ok(calls <= 4, 'Zero progress must not retry indefinitely');
    } else {
      assert.equal(status, 0);
      assert.deepEqual(Buffer.from(output), Buffer.from('a\0b\r\nc\nd\n'));
      assert.ok(calls >= output.length, 'Every reply writes at most one byte');
    }
  }
  exercise(false);
  exercise(true);
  console.log('partial and zero-progress WASI writes verified');
  process.exit(0);
}

if (process.argv[3] === '--cleanup') {
  const instance = createInstance(original, () => {});
  const initial = instance.exports.memory.buffer.byteLength;
  instance.exports._start();
  const growth = instance.exports.memory.buffer.byteLength - initial;
  assert.ok(growth <= 4 * 1024 * 1024,
    `Scoped owners leaked storage: linear memory grew by ${growth} bytes`);
  console.log('managed owner reuse verified');
  process.exit(0);
}

// Decodes an unsigned section length or vector count.
function readLeb(bytes, cursor) {
  let value = 0;
  let shift = 0;
  while (true) {
    const byte = bytes[cursor.offset++];
    value += (byte & 127) * 2 ** shift;
    if (!(byte & 128)) return value;
    shift += 7;
  }
}

// Encodes a section length without narrowing it through bitwise operations.
function leb(value) {
  const bytes = [];
  do {
    const part = value % 128;
    value = Math.floor(value / 128);
    bytes.push(part | (value ? 128 : 0));
  } while (value);
  return bytes;
}

// Appends one entry to an existing WebAssembly vector.
function appendEntry(payload, entry) {
  const cursor = { offset: 0 };
  const count = readLeb(payload, cursor);
  return [...leb(count + 1), ...payload.slice(cursor.offset), ...entry];
}

const sections = [];
const cursor = { offset: 8 };
while (cursor.offset < bytes.length) {
  const id = bytes[cursor.offset++];
  const size = readLeb(bytes, cursor);
  sections.push({ id, payload: bytes.slice(cursor.offset, cursor.offset + size) });
  cursor.offset += size;
}
const memory = sections.find(section => section.id === 5);
assert.ok(memory, 'Compiler output has no linear memory');
const limits = { offset: 0 };
assert.equal(readLeb(memory.payload, limits), 1, 'Expected one memory');
assert.ok(readLeb(memory.payload, limits) & 4, 'Memory must declare memory64');
const types = sections.find(section => section.id === 1);
const functions = sections.find(section => section.id === 3);
const exports = sections.find(section => section.id === 7);
const code = sections.find(section => section.id === 10);
const typeIndex = readLeb(types.payload, { offset: 0 });
const functionIndex = imports.filter(entry => entry.kind === 'function').length +
  readLeb(functions.payload, { offset: 0 });
types.payload = appendEntry(types.payload, [0x60, 0, 1, 0x7f]);
functions.payload = appendEntry(functions.payload, leb(typeIndex));
const name = new TextEncoder().encode('__memory64_probe');
exports.payload = appendEntry(exports.payload,
  [...leb(name.length), ...name, 0, ...leb(functionIndex)]);
// i64.const 2^32; i32.load align=2 offset=0; end.
const body = [0, 0x42, 0x80, 0x80, 0x80, 0x80, 0x10, 0x28, 2, 0, 0x0b];
code.payload = appendEntry(code.payload, [...leb(body.length), ...body]);
const patched = [...bytes.slice(0, 8)];
for (const section of sections) {
  patched.push(section.id, ...leb(section.payload.length));
  for (const byte of section.payload) patched.push(byte);
}
const module = await WebAssembly.compile(new Uint8Array(patched));
const instance = createInstance(module, () => {});
new Uint8Array(instance.exports.memory.buffer)[0] = 93;
assert.throws(() => instance.exports.__memory64_probe(), WebAssembly.RuntimeError,
  'A load at 2^32 must trap instead of wrapping onto address zero');
console.log('memory64 high-address trap verified');
