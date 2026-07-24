#!/usr/bin/env python3
"""FileFS Python (CPython C-extension) bench runner."""

from __future__ import annotations

import json
import sys
import tempfile
import time
from pathlib import Path

import filefs

ITERS = int(sys.argv[1]) if len(sys.argv) > 1 else 40
WARMUP = int(sys.argv[2]) if len(sys.argv) > 2 else 2
PAYLOAD = 4096


def median(samples: list[float]) -> float:
    samples = sorted(samples)
    n = len(samples)
    if n == 0:
        return 0.0
    if n % 2 == 0:
        return (samples[n // 2 - 1] + samples[n // 2]) / 2
    return samples[n // 2]


def time_op(prep, body):
    for _ in range(WARMUP):
        if prep:
            prep()
        body()
    samples = []
    for _ in range(ITERS):
        if prep:
            prep()
        t0 = time.perf_counter_ns()
        body()
        samples.append(float(time.perf_counter_ns() - t0))
    return {"ns_per_op": median(samples), "iters": ITERS}


def main() -> None:
    root = Path(tempfile.mkdtemp(prefix="filefs-bench-py-"))
    image = root / "bench.ffs"
    counter = {"n": 0}

    def uniq(prefix: str) -> str:
        counter["n"] += 1
        return f"{prefix}{counter['n']}"

    payload = bytes(i & 0xFF for i in range(PAYLOAD))
    ops = {}

    def mkfs_once():
        p = root / f"{uniq('mkfs')}.ffs"
        filefs.mkfs(str(p))
        p.unlink(missing_ok=True)
        Path(str(p) + "-j").unlink(missing_ok=True)

    ops["mkfs"] = time_op(None, mkfs_once)

    filefs.mkfs(str(image))
    ffs = filefs.create()
    filefs.mount(ffs, str(image))

    def prep_umount():
        filefs.umount(ffs)

    def mount_umount():
        filefs.mount(ffs, str(image))
        filefs.umount(ffs)

    ops["mount_umount"] = time_op(prep_umount, mount_umount)
    filefs.mount(ffs, str(image))

    ops["mkdir"] = time_op(None, lambda: filefs.mkdir(ffs, uniq("d")))
    filefs.mkdir(ffs, "cwdbench")
    ops["chdir_getcwd"] = time_op(
        None,
        lambda: (filefs.chdir(ffs, "cwdbench"), filefs.getcwd(ffs), filefs.chdir(ffs, "/")),
    )

    def open_close():
        f = filefs.fopen(ffs, f"{uniq('o')}.txt", "w")
        filefs.fclose(ffs, f)

    ops["open_write_close"] = time_op(None, open_close)

    seed = filefs.fopen(ffs, "seed.bin", "w")
    filefs.fwrite(ffs, payload, 1, len(payload), seed)
    filefs.fclose(ffs, seed)

    def write4():
        f = filefs.fopen(ffs, "wbench.bin", "w")
        filefs.fwrite(ffs, payload, 1, len(payload), f)
        filefs.fclose(ffs, f)

    ops["write_4kib"] = time_op(None, write4)

    def read4():
        f = filefs.fopen(ffs, "seed.bin", "r")
        filefs.fread(ffs, 1, PAYLOAD, f)
        filefs.fclose(ffs, f)

    ops["read_4kib"] = time_op(None, read4)

    def seek_ops():
        f = filefs.fopen(ffs, "seed.bin", "r")
        filefs.fseek(ffs, f, 0, filefs.SEEK_END)
        filefs.ftell(ffs, f)
        filefs.rewind(ffs, f)
        filefs.fclose(ffs, f)

    ops["seek_tell_rewind"] = time_op(None, seek_ops)
    ops["copy_file"] = time_op(
        None,
        lambda: (
            filefs.remove(ffs, "copy_dst.bin") if filefs.file_exist(ffs, "copy_dst.bin") else None,
            filefs.copy(ffs, "seed.bin", "copy_dst.bin"),
        ),
    )

    def do_rename():
        src = f"{uniq('r')}.txt"
        dst = f"{uniq('s')}.txt"
        f = filefs.fopen(ffs, src, "w")
        filefs.fclose(ffs, f)
        filefs.rename(ffs, src, dst)
        filefs.remove(ffs, dst)

    ops["rename"] = time_op(None, do_rename)

    def do_remove():
        name = f"{uniq('m')}.txt"
        f = filefs.fopen(ffs, name, "w")
        filefs.fclose(ffs, f)
        filefs.remove(ffs, name)

    ops["remove_file"] = time_op(None, do_remove)

    def readdir():
        handle = filefs.opendir(ffs, "/")
        dir_handle = handle[0] if isinstance(handle, tuple) else handle
        while filefs.readdir(ffs, dir_handle) is not None:
            pass
        filefs.closedir(ffs, dir_handle)

    ops["readdir"] = time_op(None, readdir)
    ops["exists"] = time_op(
        None,
        lambda: (filefs.file_exist(ffs, "seed.bin"), filefs.dir_exist(ffs, "cwdbench")),
    )

    def txn():
        filefs.begin(ffs)
        f = filefs.fopen(ffs, f"{uniq('t')}.txt", "w")
        filefs.fwrite(ffs, b"x", 1, 1, f)
        filefs.fclose(ffs, f)
        filefs.commit(ffs)

    ops["txn_commit"] = time_op(None, txn)

    filefs.umount(ffs)
    filefs.destroy(ffs)
    for p in root.glob("*"):
        p.unlink(missing_ok=True)
    root.rmdir()

    print(
        json.dumps(
            {
                "language": "python",
                "runtime": f"python {sys.version.split()[0]}",
                "ops": ops,
            }
        )
    )


if __name__ == "__main__":
    main()
