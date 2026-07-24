# FileFS cross-language benchmark harness

Measures the shared public API surface across language ports and renders a
color heatmap matrix into the root `README.md`.

## Quick start

```bash
# From repo root — runs every available toolchain, skips the rest
python3 bench/run_all.py

# Only selected languages
python3 bench/run_all.py --only go,lua,nodejs,rust

# Re-render README/SVG from existing results (no re-run)
python3 bench/render_matrix.py
```

Results land in:

- `bench/results/latest.json` — machine-readable timings (`ns_per_op`)
- `bench/matrix.svg` — heatmap image
- Root `README.md` section between `<!-- BENCH_MATRIX_BEGIN -->` markers

## Workload

See [`workload.json`](workload.json). Each op is timed alone (with a short
warmup). Lower `ns_per_op` is better. Cell colors are relative **within each
row** (green = faster ports for that API, red = slower).

## Implemented runners

Currently measured end-to-end:

- `c`, `go`, `lua`, `nodejs`, `python`, `rust`

Pending hooks (registered, raise until filled in): `cpp`, `dotnet`, `java`,
`kotlin`, `moonbit`, `swift`, `wasm`, `zig`.

Default `python3 bench/run_all.py` runs the implemented set. Pass `--all` to
attempt every registered language.

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
