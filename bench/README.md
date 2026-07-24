# FileFS cross-language benchmark harness

Measures the shared public API surface across language ports and renders a
color heatmap matrix into the root `README.md`.

## Quick start

```bash
# From repo root — runs every language runner
python3 bench/run_all.py

# Only selected languages
python3 bench/run_all.py --only go,lua,nodejs,rust

# Re-render README/SVG from existing results (no re-run)
python3 bench/render_matrix.py
```

Results land in:

- `bench/results/latest.json` — machine-readable timings (`ns_per_op`)
- `bench/matrix.png` — heatmap image embedded in the root README
- `bench/matrix.svg` — vector source of the same heatmap
- Root `README.md` section between `<!-- BENCH_MATRIX_BEGIN -->` markers

Rendering the PNG requires Pillow (`pip install pillow`). Without it, the
harness still writes the SVG and falls back to that image link.

## Workload

See [`workload.json`](workload.json). Each op is timed alone (with a short
warmup). Lower `ns_per_op` is better. Cell colors are relative **within each
row** (green = faster ports for that API, red = slower).

## Implemented runners

All 14 language ports are wired:

`c`, `cpp`, `dotnet`, `go`, `java`, `kotlin`, `lua`, `moonbit`, `nodejs`,
`python`, `rust`, `swift`, `wasm`, `zig`

Notes:

- **Swift** bench executable lives in `swift/Sources/FileFsBench` (SwiftPM
  cannot depend on sources outside a package root).
- **MoonBit** runs on the JS target (`moon run --target js`) for high-resolution
  `performance.now` timing.
- **Wasm** is an in-memory port: some ops (`mount_umount`, `seek_tell_rewind`)
  use the closest available API equivalents.

## Adding / extending a runner

1. Emit a single JSON object on stdout:

```json
{
  "language": "go",
  "runtime": "go1.22",
  "ops": {
    "mkfs": {"ns_per_op": 12345, "iters": 40},
    "write_4kib": {"ns_per_op": 99999, "iters": 40}
  }
}
```

2. Register a command in `bench/run_all.py` (`RUNNERS` map).

3. Re-run `python3 bench/run_all.py --only <lang>`.
