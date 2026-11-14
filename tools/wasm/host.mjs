// Supplies the preview1 output and exit imports used by Nifty WASM64 modules.
export class WasiExit extends Error {
  constructor(status) {
    super(`WASM program exited with status ${status}`);
    this.status = status;
  }
}

// The WASI preview1 boundary uses 32-bit pointers, even with memory64 storage.
export function createInstance(module, write) {
  let memory;
  const instance = new WebAssembly.Instance(module, {
    wasi_snapshot_preview1: {
      proc_exit(status) {
        throw new WasiExit(status >>> 0);
      },
      clock_time_get(clock, precision, address) {
        address >>>= 0;
        const view = new DataView(memory.buffer);
        if (address + 8 > view.byteLength) return 21;
        let timestamp;
        switch (clock) {
          case 0:
            timestamp = BigInt(Date.now()) * 1000000n;
            break;
          case 1:
            timestamp = process.hrtime.bigint();
            break;
          case 2:
          case 3: {
            const usage = process.cpuUsage();
            timestamp = BigInt(usage.user + usage.system) * 1000n;
            break;
          }
          default:
            return 28;
        }
        view.setBigUint64(address, timestamp, true);
        return 0;
      },
      fd_write(fd, vectors, count, written) {
        if (fd !== 1 && fd !== 2) return 8;
        vectors >>>= 0;
        count >>>= 0;
        written >>>= 0;
        const view = new DataView(memory.buffer);
        if (vectors + count * 8 > view.byteLength ||
            written + 4 > view.byteLength) return 21;
        const spans = [];
        let total = 0;
        for (let i = 0; i < count; i++) {
          const start = view.getUint32(vectors + i * 8, true);
          const size = view.getUint32(vectors + i * 8 + 4, true);
          if (start + size > view.byteLength) return 21;
          total += size;
          if (total > 0xffffffff) return 61;
          spans.push(new Uint8Array(memory.buffer, start, size));
        }
        for (const span of spans) write(span, fd);
        view.setUint32(written, total, true);
        return 0;
      }
    }
  });
  memory = instance.exports.memory;
  if (!(memory instanceof WebAssembly.Memory)) {
    throw new Error('WASM module must export its linear memory as memory');
  }
  return instance;
}

// Compilation can be completed separately from execution and instantiation.
export async function runWasm(bytes, write) {
  const module = await WebAssembly.compile(bytes);
  const instance = createInstance(module, write);
  try {
    instance.exports._start();
  } catch (error) {
    if (!(error instanceof WasiExit) || error.status !== 0) throw error;
  }
  return instance;
}
