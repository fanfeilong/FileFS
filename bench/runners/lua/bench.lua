#!/usr/bin/env lua5.4
-- FileFS Lua bench runner. Run via bench/run_all.py (sets package.path via cwd=lua/).

local iters = tonumber(arg[1]) or 40
local warmup = tonumber(arg[2]) or 2
local payload_size = 4096

package.path = "./?.lua;./?/init.lua;" .. package.path
local filefs = require("filefs")
local FileSystem = filefs.FileSystem
local SeekWhence = filefs.SeekWhence

local function now_ns()
  -- Lua 5.4 has no native ns clock; use socket if present, else os.clock (seconds)
  return os.clock() * 1e9
end

local function median(samples)
  table.sort(samples)
  local n = #samples
  if n == 0 then
    return 0
  end
  if n % 2 == 0 then
    return (samples[n / 2] + samples[n / 2 + 1]) / 2
  end
  return samples[math.floor(n / 2) + 1]
end

local function time_op(prep, body)
  for _ = 1, warmup do
    if prep then
      prep()
    end
    body()
  end
  local samples = {}
  for _ = 1, iters do
    if prep then
      prep()
    end
    local t0 = now_ns()
    body()
    samples[#samples + 1] = now_ns() - t0
  end
  return { ns_per_op = median(samples), iters = iters }
end

local dir = os.tmpname() .. "-filefs-lua-bench"
os.execute('mkdir -p "' .. dir .. '"')
local image = dir .. "/bench.ffs"
local counter = 0
local function uniq(prefix)
  counter = counter + 1
  return string.format("%s%d", prefix, counter)
end

local payload = {}
for i = 1, payload_size do
  payload[i] = i % 256
end
local buf = {}
for i = 1, payload_size do
  buf[i] = 0
end

local ops = {}

ops.mkfs = time_op(nil, function()
  local path = dir .. "/" .. uniq("mkfs") .. ".ffs"
  FileSystem.mkfs(path)
  os.remove(path)
  os.remove(path .. "-j")
end)

FileSystem.mkfs(image)
local fsys = FileSystem.new()
fsys:mount(image)

ops.mount_umount = time_op(function()
  fsys:umount()
end, function()
  fsys:mount(image)
  fsys:umount()
end)
fsys:mount(image)

ops.mkdir = time_op(nil, function()
  fsys:mkdir(uniq("d"))
end)

fsys:mkdir("cwdbench")
ops.chdir_getcwd = time_op(nil, function()
  fsys:chdir("cwdbench")
  local _ = fsys:getcwd()
  fsys:chdir("/")
end)

ops.open_write_close = time_op(nil, function()
  local f = fsys:open(uniq("o") .. ".txt", "w")
  fsys:close(f)
end)

do
  local seed = fsys:open("seed.bin", "w")
  assert(fsys:write(seed, payload) == payload_size)
  fsys:close(seed)
end

ops.write_4kib = time_op(nil, function()
  local f = fsys:open("wbench.bin", "w")
  assert(fsys:write(f, payload) == payload_size)
  fsys:close(f)
end)

ops.read_4kib = time_op(nil, function()
  local f = fsys:open("seed.bin", "r")
  assert(fsys:read(f, buf) == payload_size)
  fsys:close(f)
end)

ops.seek_tell_rewind = time_op(nil, function()
  local f = fsys:open("seed.bin", "r")
  assert(fsys:seek(f, 0, SeekWhence.END))
  local _ = fsys:tell(f)
  fsys:rewind(f)
  fsys:close(f)
end)

ops.copy_file = time_op(nil, function()
  if fsys:file_exists("copy_dst.bin") then fsys:remove_file("copy_dst.bin") end
  fsys:copy_file("seed.bin", "copy_dst.bin")
end)

ops.rename = time_op(nil, function()
  local src = uniq("r") .. ".txt"
  local dst = uniq("s") .. ".txt"
  local f = fsys:open(src, "w")
  fsys:close(f)
  fsys:rename(src, dst)
  fsys:remove_file(dst)
end)

ops.remove_file = time_op(nil, function()
  local name = uniq("m") .. ".txt"
  local f = fsys:open(name, "w")
  fsys:close(f)
  fsys:remove_file(name)
end)

ops.readdir = time_op(nil, function()
  local d = fsys:open_dir("/")
  while true do
    local entry = fsys:read_dir(d)
    if entry == nil then
      break
    end
  end
  fsys:close_dir(d)
end)

ops.exists = time_op(nil, function()
  local _ = fsys:file_exists("seed.bin")
  local __ = fsys:dir_exists("cwdbench")
end)

ops.txn_commit = time_op(nil, function()
  assert(fsys:begin())
  local f = fsys:open(uniq("t") .. ".txt", "w")
  assert(fsys:write(f, { string.byte("x") }) == 1)
  fsys:close(f)
  assert(fsys:commit())
end)

fsys:umount()
os.execute('rm -rf "' .. dir .. '"')

local function json_escape(s)
  return s:gsub("\\", "\\\\"):gsub('"', '\\"')
end

local parts = { '{"language":"lua","runtime":"' .. json_escape(_VERSION) .. '","ops":{' }
local first = true
local keys = {
  "mkfs",
  "mount_umount",
  "mkdir",
  "chdir_getcwd",
  "open_write_close",
  "write_4kib",
  "read_4kib",
  "seek_tell_rewind",
  "copy_file",
  "rename",
  "remove_file",
  "readdir",
  "exists",
  "txn_commit",
}
for _, key in ipairs(keys) do
  local op = ops[key]
  if not first then
    parts[#parts + 1] = ","
  end
  first = false
  parts[#parts + 1] = string.format(
    '"%s":{"ns_per_op":%.3f,"iters":%d}',
    key,
    op.ns_per_op,
    op.iters
  )
end
parts[#parts + 1] = "}}"
io.write(table.concat(parts))
io.write("\n")
