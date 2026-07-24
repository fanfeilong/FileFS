import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { performance } from "node:perf_hooks";
import { fileURLToPath } from "node:url";

import { FileSystem, SeekWhence } from "../../../nodejs/src/index.js";

const iters = Number(process.argv[2] || 40);
const warmup = Number(process.argv[3] || 2);
const payloadSize = 4096;

function median(samples) {
  const cp = [...samples].sort((a, b) => a - b);
  const mid = Math.floor(cp.length / 2);
  if (cp.length % 2 === 0) {
    return (cp[mid - 1] + cp[mid]) / 2;
  }
  return cp[mid];
}

function timeOp(prep, body) {
  for (let i = 0; i < warmup; i += 1) {
    if (prep) prep();
    body();
  }
  const samples = [];
  for (let i = 0; i < iters; i += 1) {
    if (prep) prep();
    const t0 = performance.now();
    body();
    samples.push((performance.now() - t0) * 1e6);
  }
  return { ns_per_op: median(samples), iters };
}

const dir = fs.mkdtempSync(path.join(os.tmpdir(), "filefs-bench-node-"));
const image = path.join(dir, "bench.ffs");
let counter = 0;
const uniq = (prefix) => `${prefix}${counter++}`;

const payload = Buffer.alloc(payloadSize);
for (let i = 0; i < payloadSize; i += 1) payload[i] = i & 0xff;
const buf = Buffer.alloc(payloadSize);

const ops = {};

ops.mkfs = timeOp(null, () => {
  const p = path.join(dir, `${uniq("mkfs")}.ffs`);
  FileSystem.mkfs(p);
  fs.rmSync(p, { force: true });
  fs.rmSync(`${p}-j`, { force: true });
});

FileSystem.mkfs(image);
const fsys = new FileSystem();
fsys.mount(image);

ops.mount_umount = timeOp(
  () => fsys.umount(),
  () => {
    fsys.mount(image);
    fsys.umount();
  },
);
fsys.mount(image);

ops.mkdir = timeOp(null, () => {
  fsys.mkdir(uniq("d"));
});

fsys.mkdir("cwdbench");
ops.chdir_getcwd = timeOp(null, () => {
  fsys.chdir("cwdbench");
  fsys.getcwd();
  fsys.chdir("/");
});

ops.open_write_close = timeOp(null, () => {
  const f = fsys.open(`${uniq("o")}.txt`, "w");
  fsys.close(f);
});

{
  const seed = fsys.open("seed.bin", "w");
  fsys.write(seed, payload);
  fsys.close(seed);
}

ops.write_4kib = timeOp(null, () => {
  const f = fsys.open("wbench.bin", "w");
  fsys.write(f, payload);
  fsys.close(f);
});

ops.read_4kib = timeOp(null, () => {
  const f = fsys.open("seed.bin", "r");
  fsys.read(f, buf);
  fsys.close(f);
});

ops.seek_tell_rewind = timeOp(null, () => {
  const f = fsys.open("seed.bin", "r");
  fsys.seek(f, 0, SeekWhence.End);
  fsys.tell(f);
  fsys.rewind(f);
  fsys.close(f);
});

ops.copy_file = timeOp(null, () => {
  if (fsys.fileExists("copy_dst.bin")) fsys.removeFile("copy_dst.bin");
  fsys.copyFile("seed.bin", "copy_dst.bin");
});

ops.rename = timeOp(null, () => {
  const src = `${uniq("r")}.txt`;
  const dst = `${uniq("s")}.txt`;
  const f = fsys.open(src, "w");
  fsys.close(f);
  fsys.rename(src, dst);
  fsys.removeFile(dst);
});

ops.remove_file = timeOp(null, () => {
  const name = `${uniq("m")}.txt`;
  const f = fsys.open(name, "w");
  fsys.close(f);
  fsys.removeFile(name);
});

ops.readdir = timeOp(null, () => {
  const d = fsys.openDir("/");
  while (fsys.readDir(d) !== null) {
    // drain
  }
  fsys.closeDir(d);
});

ops.exists = timeOp(null, () => {
  fsys.fileExists("seed.bin");
  fsys.dirExists("cwdbench");
});

ops.txn_commit = timeOp(null, () => {
  fsys.begin();
  const f = fsys.open(`${uniq("t")}.txt`, "w");
  fsys.write(f, Buffer.from("x"));
  fsys.close(f);
  fsys.commit();
});

fsys.umount();
fs.rmSync(dir, { recursive: true, force: true });

const out = {
  language: "nodejs",
  runtime: `node ${process.version}`,
  ops,
};
process.stdout.write(`${JSON.stringify(out)}\n`);
