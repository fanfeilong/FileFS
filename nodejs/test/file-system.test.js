import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

import { FileSystem, FileType } from "../src/index.js";

function createMountedFs(t) {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "filefs-nodejs-"));
  const imagePath = path.join(tempDir, "test.ffs");

  t.after(() => {
    fs.rmSync(tempDir, { recursive: true, force: true });
  });

  FileSystem.mkfs(imagePath);
  const fileSystem = new FileSystem();
  fileSystem.mount(imagePath);

  t.after(() => {
    fileSystem.umount();
  });

  return { fileSystem, imagePath };
}

test("mkfs + mount + getcwd returns root", (t) => {
  const { fileSystem } = createMountedFs(t);
  assert.equal(fileSystem.isMounted, true);
  assert.equal(fileSystem.getcwd(), "/");
});

test("mkdir + chdir updates current directory", (t) => {
  const { fileSystem } = createMountedFs(t);
  fileSystem.mkdir("docs");
  fileSystem.chdir("docs");
  assert.equal(fileSystem.getcwd(), "/docs/");
  assert.equal(fileSystem.dirExists("/docs"), true);
});

test("open write/read roundtrip", (t) => {
  const { fileSystem } = createMountedFs(t);
  const message = Buffer.from("hello filefs");

  const writer = fileSystem.open("/note.txt", "w");
  fileSystem.write(writer, message);
  writer.close();

  const reader = fileSystem.open("/note.txt", "r");
  const buffer = Buffer.alloc(64);
  const bytesRead = fileSystem.read(reader, buffer);
  reader.close();

  assert.equal(buffer.subarray(0, bytesRead).toString("utf8"), "hello filefs");
});

test("copy + rename + remove file", (t) => {
  const { fileSystem } = createMountedFs(t);
  const writer = fileSystem.open("/source.txt", "w");
  fileSystem.write(writer, Buffer.from("copy me"));
  writer.close();

  fileSystem.copyFile("/source.txt", "/copy.txt");
  assert.equal(fileSystem.fileExists("/copy.txt"), true);

  fileSystem.rename("/copy.txt", "/renamed.txt");
  assert.equal(fileSystem.fileExists("/copy.txt"), false);
  assert.equal(fileSystem.fileExists("/renamed.txt"), true);

  fileSystem.removeFile("/renamed.txt");
  assert.equal(fileSystem.fileExists("/renamed.txt"), false);
});

test("openDir lists docs directory", (t) => {
  const { fileSystem } = createMountedFs(t);
  fileSystem.mkdir("/docs");

  const dir = fileSystem.openDir("/");
  const names = [];
  for (;;) {
    const entry = fileSystem.readDir(dir);
    if (entry === null) {
      break;
    }
    names.push(entry);
  }
  dir.close();

  assert.equal(
    names.some((entry) => entry.name === "docs" && entry.type === FileType.Directory),
    true,
  );
});

test("begin/commit persists created file", (t) => {
  const { fileSystem, imagePath } = createMountedFs(t);

  fileSystem.begin();
  const writer = fileSystem.open("/txn.txt", "w");
  fileSystem.write(writer, Buffer.from("x"));
  writer.close();
  fileSystem.commit();

  assert.equal(fileSystem.fileExists("/txn.txt"), true);
  assert.ok(fs.statSync(imagePath).size >= 2 * 512);
});
