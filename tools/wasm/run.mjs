import { readFile } from 'node:fs/promises';
import { writeSync } from 'node:fs';
import { runWasm, WasiExit } from './host.mjs';

if (process.argv.length !== 3) {
  console.error('Usage: node tools/wasm/run.mjs PROGRAM.wasm');
  process.exitCode = 1;
} else {
  try {
    await runWasm(await readFile(process.argv[2]), (bytes, fd) => {
      let offset = 0;
      while (offset < bytes.length) {
        const written = writeSync(fd, bytes, offset, bytes.length - offset);
        if (written <= 0) throw new Error('Output write made no progress');
        offset += written;
      }
    });
  } catch (error) {
    if (!(error instanceof WasiExit)) console.error(error.message);
    process.exitCode = error instanceof WasiExit ? error.status : 1;
  }
}
