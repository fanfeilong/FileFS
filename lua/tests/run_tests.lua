#!/usr/bin/env lua5.4
-- Run from the lua/ directory: lua5.4 tests/run_tests.lua

local function script_dir()
  local source = debug.getinfo(1, "S").source
  if source:sub(1, 1) == "@" then
    local path = source:sub(2)
    return path:match("^(.*)/[^/]+$") or "."
  end
  return "."
end

local tests_dir = script_dir()
local lua_root = tests_dir:match("^(.*)/[^/]+$") or ".."
package.path = lua_root .. "/?.lua;" .. lua_root .. "/?/init.lua;" .. package.path

local filefs = require("filefs")
local FileSystem = filefs.FileSystem
local FileType = filefs.FileType
local SeekWhence = filefs.SeekWhence

local passed = 0
local failed = 0

local function assert_true(cond, msg)
  if not cond then
    error(msg or "assert_true failed", 2)
  end
end

local function assert_eq(expected, actual, msg)
  if expected ~= actual then
    error(
      string.format(
        "%s expected=<%s> actual=<%s>",
        msg or "assert_eq failed",
        tostring(expected),
        tostring(actual)
      ),
      2
    )
  end
end

local function with_fixture(name, body)
  local path = os.tmpname() .. "-" .. name .. ".ffs"
  local journal = path .. "-j"
  os.remove(path)
  os.remove(journal)
  FileSystem.mkfs(path)
  local fsys = FileSystem.new()
  fsys:mount(path)
  local ok, err = pcall(body, fsys, path)
  fsys:umount()
  os.remove(path)
  os.remove(journal)
  if not ok then
    error(err, 0)
  end
end

local tests = {
  {
    name = "mkfs_mount_and_getcwd",
    fn = function()
      with_fixture("lifecycle", function(fsys)
        assert_true(fsys:is_mounted(), "filesystem should be mounted")
        assert_eq("/", fsys:getcwd(), "cwd should be root")
      end)
    end,
  },
  {
    name = "mkdir_and_chdir",
    fn = function()
      with_fixture("mkdir", function(fsys)
        fsys:mkdir("docs")
        fsys:chdir("docs")
        assert_eq("/docs/", fsys:getcwd(), "cwd should change to docs")
      end)
    end,
  },
  {
    name = "open_write_read_roundtrip",
    fn = function()
      with_fixture("roundtrip", function(fsys)
        fsys:mkdir("docs")
        fsys:chdir("docs")
        local payload = FileSystem.bytes_from_string("hello filefs")
        local out = fsys:open("note.txt", "w")
        assert_eq(#payload, fsys:write(out, payload), "write should persist payload")
        fsys:close(out)

        local input = fsys:open("note.txt", "r")
        assert_true(fsys:seek(input, 0, SeekWhence.END), "seek to end should succeed")
        assert_eq(#payload, fsys:tell(input), "tell should report payload length")
        fsys:rewind(input)
        local buffer = {}
        for i = 1, 64 do
          buffer[i] = 0
        end
        local count = fsys:read(input, buffer)
        fsys:close(input)
        assert_eq(
          "hello filefs",
          FileSystem.string_from_bytes(buffer, 1, count),
          "roundtrip should match"
        )
      end)
    end,
  },
  {
    name = "copy_rename_and_remove",
    fn = function()
      with_fixture("copy", function(fsys)
        local payload = FileSystem.bytes_from_string("copy me")
        local out = fsys:open("orig.txt", "w")
        assert_eq(#payload, fsys:write(out, payload), "write should persist source file")
        fsys:close(out)
        fsys:copy_file("orig.txt", "copy.txt")
        fsys:rename("copy.txt", "renamed.txt")
        assert_true(fsys:file_exists("renamed.txt"), "renamed file should exist")
        fsys:remove_file("renamed.txt")
        assert_true(not fsys:file_exists("renamed.txt"), "removed file should not exist")
      end)
    end,
  },
  {
    name = "open_dir_lists_docs",
    fn = function()
      with_fixture("readdir", function(fsys)
        fsys:mkdir("docs")
        local dir = fsys:open_dir("/")
        assert_eq("/", dir:absolute_path(), "absolute path should be root")
        local found_docs = false
        while true do
          local entry = fsys:read_dir(dir)
          if entry == nil then
            break
          end
          if entry.name == "docs" and entry.type == FileType.DIR then
            found_docs = true
          end
        end
        fsys:close_dir(dir)
        assert_true(found_docs, "docs directory should be listed")
      end)
    end,
  },
  {
    name = "begin_commit_creates_file",
    fn = function()
      with_fixture("txn", function(fsys)
        assert_true(fsys:begin(), "begin should succeed")
        local out = fsys:open("txn.txt", "w")
        assert_eq(1, fsys:write(out, { string.byte("x") }), "transactional write should succeed")
        fsys:close(out)
        assert_true(fsys:commit(), "commit should succeed")
        assert_true(fsys:file_exists("txn.txt"), "committed file should exist")
      end)
    end,
  },
}

for _, test in ipairs(tests) do
  local ok, err = pcall(test.fn)
  if ok then
    passed = passed + 1
    print("PASS " .. test.name)
  else
    failed = failed + 1
    print("FAIL " .. test.name .. ": " .. tostring(err))
  end
end

print(string.format("PASS %d tests, FAIL %d", passed, failed))
if failed > 0 then
  os.exit(1)
end
