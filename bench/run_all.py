#!/usr/bin/env python3
"""Orchestrate FileFS cross-language benchmarks and refresh the README matrix."""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BENCH = Path(__file__).resolve().parent
RESULTS = BENCH / "results"
WORKLOAD = json.loads((BENCH / "workload.json").read_text(encoding="utf-8"))


def env_with_path() -> dict[str, str]:
    env = os.environ.copy()
    extras = [
        str(Path.home() / ".moon" / "bin"),
        str(Path.home() / ".dotnet"),
        str(Path.home() / ".dotnet" / "tools"),
        "/usr/local/bin",
        "/usr/local/cargo/bin",
        str(Path.home() / ".nvm" / "versions" / "node" / "v22.22.2" / "bin"),
    ]
    env["PATH"] = os.pathsep.join(extras + [env.get("PATH", "")])
    env.setdefault("DOTNET_ROOT", str(Path.home() / ".dotnet"))
    env.setdefault("DOTNET_CLI_HOME", str(Path.home() / ".dotnet"))
    return env


def which(cmd: str) -> str | None:
    return shutil.which(cmd, path=env_with_path()["PATH"])


def run_cmd(
    argv: list[str],
    *,
    cwd: Path | None = None,
    timeout: int = 300,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        argv,
        cwd=str(cwd or ROOT),
        env=env_with_path(),
        text=True,
        capture_output=True,
        timeout=timeout,
        check=False,
    )


def parse_json_stdout(proc: subprocess.CompletedProcess[str], language: str) -> dict:
    if proc.returncode != 0:
        raise RuntimeError(
            f"{language} runner failed ({proc.returncode}):\n"
            f"stdout:\n{proc.stdout[-2000:]}\n"
            f"stderr:\n{proc.stderr[-2000:]}"
        )
    text = proc.stdout.strip()
    start = text.find("{")
    if start < 0:
        raise RuntimeError(f"{language}: no JSON object in stdout:\n{text[-2000:]}")
    payload, _ = json.JSONDecoder().raw_decode(text[start:])
    payload["language"] = language
    return payload


# --- language runners -------------------------------------------------------


def run_go() -> dict:
    if not which("go"):
        raise RuntimeError("go not found")
    out = BENCH / "runners" / "go"
    proc = run_cmd(["go", "run", ".", str(WORKLOAD["iterations"]), str(WORKLOAD["warmup"])], cwd=out)
    return parse_json_stdout(proc, "go")


def run_lua() -> dict:
    lua = which("lua5.4") or which("lua")
    if not lua:
        raise RuntimeError("lua not found")
    script = BENCH / "runners" / "lua" / "bench.lua"
    proc = run_cmd(
        [lua, str(script), str(WORKLOAD["iterations"]), str(WORKLOAD["warmup"])],
        cwd=ROOT / "lua",
    )
    return parse_json_stdout(proc, "lua")


def run_nodejs() -> dict:
    node = which("node")
    if not node:
        raise RuntimeError("node not found")
    script = BENCH / "runners" / "nodejs" / "bench.mjs"
    proc = run_cmd(
        [node, str(script), str(WORKLOAD["iterations"]), str(WORKLOAD["warmup"])],
        cwd=ROOT / "nodejs",
    )
    return parse_json_stdout(proc, "nodejs")


def run_rust() -> dict:
    if not which("cargo"):
        raise RuntimeError("cargo not found")
    runner = BENCH / "runners" / "rust"
    build = run_cmd(["cargo", "build", "--release", "--quiet"], cwd=runner, timeout=600)
    if build.returncode != 0:
        raise RuntimeError(build.stderr[-2000:])
    bin_path = runner / "target" / "release" / "filefs-bench"
    proc = run_cmd([str(bin_path), str(WORKLOAD["iterations"]), str(WORKLOAD["warmup"])])
    return parse_json_stdout(proc, "rust")


def run_c() -> dict:
    cc = which("cc") or which("gcc") or which("clang")
    if not cc:
        raise RuntimeError("C compiler not found")
    out_dir = BENCH / "runners" / "c" / "build"
    out_dir.mkdir(parents=True, exist_ok=True)
    binary = out_dir / "bench"
    compile_cmd = [
        cc,
        "-O2",
        "-std=gnu11",
        str(BENCH / "runners" / "c" / "bench.c"),
        str(ROOT / "c" / "FileFS.c"),
        "-I",
        str(ROOT / "c"),
        "-o",
        str(binary),
    ]
    built = run_cmd(compile_cmd)
    if built.returncode != 0:
        raise RuntimeError(built.stderr[-2000:])
    proc = run_cmd([str(binary), str(WORKLOAD["iterations"]), str(WORKLOAD["warmup"])])
    return parse_json_stdout(proc, "c")


def run_zig() -> dict:
    raise NotImplementedError("zig bench runner pending — see bench/README.md")


def run_java() -> dict:
    raise NotImplementedError("java bench runner pending — see bench/README.md")


def run_kotlin() -> dict:
    raise NotImplementedError("kotlin bench runner pending — see bench/README.md")


def run_python() -> dict:
    if not which("python3"):
        raise RuntimeError("python3 not found")
    script = BENCH / "runners" / "python" / "bench.py"
    py_root = ROOT / "python"
    venv = BENCH / "runners" / "python" / ".venv"
    py = venv / "bin" / "python"
    if not py.exists():
        created = run_cmd([sys.executable, "-m", "venv", str(venv)])
        if created.returncode != 0:
            raise RuntimeError(created.stderr[-2000:] or created.stdout[-2000:])
    install = run_cmd([str(py), "-m", "pip", "install", "-e", str(py_root), "-q"], timeout=600)
    if install.returncode != 0:
        raise RuntimeError(install.stderr[-2000:] or install.stdout[-2000:])
    proc = run_cmd([str(py), str(script), str(WORKLOAD["iterations"]), str(WORKLOAD["warmup"])])
    return parse_json_stdout(proc, "python")


def run_dotnet() -> dict:
    raise NotImplementedError("dotnet bench runner pending — see bench/README.md")


def run_swift() -> dict:
    raise NotImplementedError("swift bench runner pending — see bench/README.md")


def run_moonbit() -> dict:
    raise NotImplementedError("moonbit bench runner pending — see bench/README.md")


def run_cpp() -> dict:
    raise NotImplementedError("cpp bench runner pending — see bench/README.md")


def run_wasm() -> dict:
    raise NotImplementedError("wasm bench runner pending — see bench/README.md")


RUNNERS = {
    "c": run_c,
    "cpp": run_cpp,
    "dotnet": run_dotnet,
    "go": run_go,
    "java": run_java,
    "kotlin": run_kotlin,
    "lua": run_lua,
    "moonbit": run_moonbit,
    "nodejs": run_nodejs,
    "python": run_python,
    "rust": run_rust,
    "swift": run_swift,
    "wasm": run_wasm,
    "zig": run_zig,
}


IMPLEMENTED = ("c", "go", "lua", "nodejs", "python", "rust")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--only",
        default="",
        help="Comma-separated language ids to run (default: implemented runners)",
    )
    parser.add_argument(
        "--all",
        action="store_true",
        help="Attempt every registered language (pending runners are recorded as errors)",
    )
    parser.add_argument(
        "--skip-render",
        action="store_true",
        help="Do not refresh README/SVG after collecting results",
    )
    args = parser.parse_args()

    if args.only:
        selected = [s.strip() for s in args.only.split(",") if s.strip()]
    elif args.all:
        selected = list(RUNNERS)
    else:
        selected = list(IMPLEMENTED)
    unknown = [s for s in selected if s not in RUNNERS]
    if unknown:
        print(f"unknown languages: {unknown}", file=sys.stderr)
        return 2

    RESULTS.mkdir(parents=True, exist_ok=True)
    existing = {}
    latest_path = RESULTS / "latest.json"
    if latest_path.exists():
        try:
            existing = json.loads(latest_path.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            existing = {}

    languages = existing.get("languages", {})
    errors: dict[str, str] = existing.get("errors", {})

    for lang in selected:
        print(f"==> bench {lang}", flush=True)
        t0 = time.time()
        try:
            payload = RUNNERS[lang]()
            languages[lang] = payload
            errors.pop(lang, None)
            elapsed = time.time() - t0
            print(f"    ok in {elapsed:.1f}s ({len(payload.get('ops', {}))} ops)", flush=True)
        except Exception as exc:  # noqa: BLE001 — surface per-language failures
            errors[lang] = str(exc)
            print(f"    SKIP/FAIL: {exc}", flush=True)

    doc = {
        "generated_at_unix": int(time.time()),
        "workload": {
            "name": WORKLOAD["name"],
            "iterations": WORKLOAD["iterations"],
            "warmup": WORKLOAD["warmup"],
            "payload_bytes": WORKLOAD["payload_bytes"],
            "ops": [op["id"] for op in WORKLOAD["ops"]],
        },
        "languages": languages,
        "errors": errors,
    }
    latest_path.write_text(json.dumps(doc, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    stamp = RESULTS / f"results-{doc['generated_at_unix']}.json"
    stamp.write_text(latest_path.read_text(encoding="utf-8"), encoding="utf-8")
    print(f"wrote {latest_path}", flush=True)

    if not args.skip_render:
        render = run_cmd([sys.executable, str(BENCH / "render_matrix.py")])
        sys.stdout.write(render.stdout)
        sys.stderr.write(render.stderr)
        if render.returncode != 0:
            return render.returncode
    return 0 if languages else 1


if __name__ == "__main__":
    raise SystemExit(main())
