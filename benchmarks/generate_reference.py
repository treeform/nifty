#!/usr/bin/env python3
"""Regenerate RGB oracles with Nimkey's interpreter, independently of Nifty."""

import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parent
UPSTREAM_REVISION = "adcacefce18748630dccde5943bd3314dfcb422b"


def render(compiler: Path, source: str, size: int, directory: Path) -> bytes:
    """Render bounded tiles with the original interpreter and validate RGB."""
    pixels = bytearray()
    for first in range(0, size * size, 32):
        count = min(32, size * size - first)
        tile = source.replace("ImageSize = 16", f"ImageSize = {size}")
        tile = tile.replace("TileStart = 0", f"TileStart = {first}")
        tile = tile.replace("TileCount = 16", f"TileCount = {count}")
        path = directory / "tile.nimkey"
        path.write_text(tile)
        result = subprocess.run(
            [str(compiler), "run", str(path)],
            text=True,
            capture_output=True,
            timeout=60,
            check=True,
        )
        values = [int(value) for value in result.stdout.split()]
        if len(values) != count * 3 or any(v < 0 or v > 255 for v in values):
            raise ValueError(f"Invalid Nimkey RGB output at pixel {first}")
        pixels.extend(values)
    return bytes(pixels)


def main() -> None:
    """Write reproducible fixtures without depending on Nifty's output."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--nimkey", type=Path, required=True,
                        help="Nimkey CLI built from the recorded revision")
    args = parser.parse_args()
    compiler = args.nimkey.resolve()
    source_path = ROOT / "reference" / "raytracer.nimkey"
    source_bytes = source_path.read_bytes()
    source = source_bytes.decode("utf-8")
    for token in ("ImageSize = 16", "TileStart = 0", "TileCount = 16"):
        if source.count(token) != 1:
            raise ValueError(f"Original source parameter is ambiguous: {token}")
    manifest = {
        "format": "row-major RGB8, no header",
        "precision": "float64",
        "max_depth": 5,
        "oracle": "Nimkey interpreter (nimkey run), 32-pixel tiles",
        "upstream": "https://github.com/treeform/nimkey",
        "upstream_revision": UPSTREAM_REVISION,
        "upstream_path": "tests/benchmarks/raytracer.nimkey",
        "source_sha256": hashlib.sha256(source_bytes).hexdigest(),
        "images": {},
    }
    with tempfile.TemporaryDirectory(prefix="nifty-ray-reference-") as work:
        directory = Path(work)
        for size in (4, 16, 64):
            pixels = render(compiler, source, size, directory)
            filename = f"{size}.rgb"
            (directory / filename).write_bytes(pixels)
            manifest["images"][str(size)] = {
                "file": filename,
                "width": size,
                "height": size,
                "bytes": len(pixels),
                "checksum": sum(pixels),
                "sha256": hashlib.sha256(pixels).hexdigest(),
            }
            print(f"Nimkey {size}x{size}: checksum {sum(pixels)}", flush=True)
        for size in (4, 16, 64):
            target = source_path.parent / f"{size}.rgb"
            target.write_bytes((directory / target.name).read_bytes())
        (source_path.parent / "manifest.json").write_text(
            json.dumps(manifest, indent=2) + "\n"
        )


if __name__ == "__main__":
    main()
