import test from "node:test";
import assert from "node:assert/strict";

import { FileSystem } from "../js/filefs.mjs";

await FileSystem.load();

function withFs(run) {
  const fs = new FileSystem();
  try {
    return run(fs);
  } finally {
    fs.destroy();
  }
}

test("mkfs + mount + cwd", () =>
  withFs((fs) => {
    fs.mkfs().mount();
    assert.equal(fs.getcwd(), "/");
    assert.equal(fs.getImage().length, 1024);
  }));

test("mkdir + chdir", () =>
  withFs((fs) => {
    fs.mkfs().mount();
    fs.mkdir("docs").chdir("docs");
    assert.equal(fs.getcwd(), "/docs/");
  }));

test("write + read roundtrip", () =>
  withFs((fs) => {
    fs.mkfs().mount();
    fs.mkdir("docs").chdir("docs");
    fs.writeFile("note.txt", "hello filefs");
    assert.equal(fs.readFile("note.txt"), "hello filefs");
  }));

test("copy + rename + remove", () =>
  withFs((fs) => {
    fs.mkfs().mount();
    fs.mkdir("docs").chdir("docs");
    fs.writeFile("note.txt", "payload");
    fs.chdir("/");
    fs.copyFile("/docs/note.txt", "/copy.txt");
    assert.equal(fs.readFile("/copy.txt"), "payload");
    fs.rename("/copy.txt", "/renamed.txt");
    assert.equal(fs.readFile("/renamed.txt"), "payload");
    fs.removeFile("/renamed.txt");
    assert.throws(() => fs.readFile("/renamed.txt"), /PathNotFound/);
  }));

test("listDir includes docs", () =>
  withFs((fs) => {
    fs.mkfs().mount();
    fs.mkdir("docs");
    const entries = fs.listDir("/");
    assert.ok(entries.some((entry) => entry.name === "docs" && entry.type === "dir"));
  }));

test("begin + commit persists transaction changes", () =>
  withFs((fs) => {
    fs.mkfs().mount();
    fs.begin();
    fs.mkdir("docs").chdir("docs").writeFile("txn.txt", "x");
    fs.commit();
    assert.equal(fs.getcwd(), "/docs/");
    assert.equal(fs.readFile("/docs/txn.txt"), "x");
  }));
