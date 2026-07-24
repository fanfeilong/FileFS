import { performance } from "node:perf_hooks";
import { fileURLToPath } from "node:url";
import path from "node:path";

import { FileSystem } from "../../../wasm/js/filefs.mjs";

const iters = Number(process.argv[2] || 40);
const warmup = Number(process.argv[3] || 2);
const payloadSize = 4096;

function median(samples) {
  const cp = [...samples].sort((a, b) => a - b);
  const mid = Math.floor(cp.length / 2);
  return cp.length % 2 === 0 ? (cp[mid - 1] + cp[mid]) / 2 : cp[mid];
}

function timeOp(body) {
  for (let i = 0; i < warmup; i += 1) body();
  const samples = [];
  for (let i = 0; i < iters; i += 1) {
    const t0 = performance.now();
    body();
    samples.push((performance.now() - t0) * 1e6);
  }
  return { ns_per_op: median(samples), iters };
}

await FileSystem.load({
  source: new URL("../../../wasm/zig-out/bin/filefs.wasm", import.meta.url),
});

let counter = 0;
const uniq = (prefix) => `${prefix}${++counter}`;
const payload = new Uint8Array(payloadSize);
for (let i = 0; i < payloadSize; i += 1) payload[i] = i & 0xff;

const ops = {};
let fsys = new FileSystem();

ops.mkfs = timeOp(() => {
  fsys.destroy();
  fsys = new FileSystem();
  fsys.mkfs();
});

fsys.mkfs();
fsys.mount();

ops.mount_umount = timeOp(() => {
  // Wasm port has no umount; recreate + mkfs + mount approximates remount cost.
  fsys.destroy();
  fsys = new FileSystem();
  fsys.mkfs();
  fsys.mount();
});

ops.mkdir = timeOp(() => {
  fsys.mkdir(uniq("d"));
});

fsys.mkdir("cwdbench");
ops.chdir_getcwd = timeOp(() => {
  fsys.chdir("cwdbench");
  fsys.getcwd();
  fsys.chdir("/");
});

ops.open_write_close = timeOp(() => {
  fsys.writeFile(`${uniq("o")}.txt`, new Uint8Array());
});

fsys.writeFile("seed.bin", payload);

ops.write_4kib = timeOp(() => {
  fsys.writeFile("wbench.bin", payload);
});

ops.read_4kib = timeOp(() => {
  fsys.readFile("seed.bin", { encoding: null });
});

// No seek/tell API — time a full read as a comparable stream-position proxy.
ops.seek_tell_rewind = timeOp(() => {
  const bytes = fsys.readFile("seed.bin", { encoding: null });
  if (bytes.length !== payloadSize) throw new Error("unexpected length");
});

ops.copy_file = timeOp(() => {
  try {
    fsys.removeFile("copy_dst.bin");
  } catch {
    // missing
  }
  fsys.copyFile("seed.bin", "copy_dst.bin");
});

ops.rename = timeOp(() => {
  const src = `${uniq("r")}.txt`;
  const dst = `${uniq("s")}.txt`;
  fsys.writeFile(src, new Uint8Array());
  fsys.rename(src, dst);
  fsys.removeFile(dst);
});

ops.remove_file = timeOp(() => {
  const name = `${uniq("m")}.txt`;
  fsys.writeFile(name, new Uint8Array());
  fsys.removeFile(name);
});

ops.readdir = timeOp(() => {
  fsys.listDir("/");
});

ops.exists = timeOp(() => {
  const names = new Set(fsys.listDir("/").map((e) => e.name));
  if (!names.has("seed.bin") || !names.has("cwdbench")) {
    throw new Error("exists probe failed");
  }
});

ops.txn_commit = timeOp(() => {
  fsys.begin();
  fsys.writeFile(`${uniq("t")}.txt`, new Uint8Array([120]));
  fsys.commit();
});

fsys.destroy();
process.stdout.write(
  `${JSON.stringify({ language: "wasm", runtime: `node ${process.version}`, ops })}\n`,
);
