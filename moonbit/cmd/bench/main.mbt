///|
extern "js" fn js_now_ms() -> Double =
  #| () => (typeof performance !== "undefined" ? performance.now() : Date.now())

///|
fn now_ns() -> Double {
  js_now_ms() * 1_000_000.0
}

///|
fn median(samples : Array[Double]) -> Double {
  let sorted = samples.copy()
  sorted.sort()
  let n = sorted.length()
  if n == 0 {
    return 0.0
  }
  if n % 2 == 0 {
    (sorted[n / 2 - 1] + sorted[n / 2]) / 2.0
  } else {
    sorted[n / 2]
  }
}

///|
fn time_body(iters : Int, warmup : Int, body : () -> Unit raise) -> (Double, Int) raise {
  for _ in 0..<warmup {
    body()
  }
  let samples : Array[Double] = []
  for _ in 0..<iters {
    let t0 = now_ns()
    body()
    samples.push(now_ns() - t0)
  }
  (median(samples), iters)
}

///|
fn remove_quiet(path : String) -> Unit {
  if @fs.path_exists(path) {
    @fs.remove_file(path) catch {
      _ => ()
    }
  }
}

///|
fn run(iters : Int, warmup : Int) -> Unit raise {
  let dir = "tmp-filefs-bench-moonbit"
  if !@fs.path_exists(dir) {
    @fs.create_dir(dir)
  }
  let image = dir + "/bench.ffs"
  let mut counter = 0
  fn uniq(prefix : String) -> String {
    counter = counter + 1
    prefix + counter.to_string()
  }

  let payload = Array::make(4096, b'\x00')
  for i = 0; i < 4096; i = i + 1 {
    payload[i] = (i % 256).to_byte()
  }
  let buf = Array::make(4096, b'\x00')
  let ops : Array[(String, Double, Int)] = []

  let (a, b) = time_body(iters, warmup, () => {
    let path = dir + "/" + uniq("mkfs") + ".ffs"
    @filefs.mkfs(path)
    remove_quiet(path)
    remove_quiet(path + "-j")
  })
  ops.push(("mkfs", a, b))

  @filefs.mkfs(image)
  let fsys = @filefs.FileSystem::new()
  fsys.mount(image)

  let (a2, b2) = time_body(iters, warmup, () => {
    fsys.umount()
    fsys.mount(image)
  })
  ops.push(("mount_umount", a2, b2))

  let (a3, b3) = time_body(iters, warmup, () => { fsys.mkdir(uniq("d")) })
  ops.push(("mkdir", a3, b3))

  fsys.mkdir("cwdbench")
  let (a4, b4) = time_body(iters, warmup, () => {
    fsys.chdir("cwdbench")
    ignore(fsys.getcwd())
    fsys.chdir("/")
  })
  ops.push(("chdir_getcwd", a4, b4))

  let (a5, b5) = time_body(iters, warmup, () => {
    let f = fsys.open(uniq("o") + ".txt", "w")
    fsys.close(f)
  })
  ops.push(("open_write_close", a5, b5))

  let seed = fsys.open("seed.bin", "w")
  ignore(fsys.write(seed, payload))
  fsys.close(seed)

  let (a6, b6) = time_body(iters, warmup, () => {
    let f = fsys.open("wbench.bin", "w")
    ignore(fsys.write(f, payload))
    fsys.close(f)
  })
  ops.push(("write_4kib", a6, b6))

  let (a7, b7) = time_body(iters, warmup, () => {
    let f = fsys.open("seed.bin", "r")
    ignore(fsys.read(f, buf))
    fsys.close(f)
  })
  ops.push(("read_4kib", a7, b7))

  let (a8, b8) = time_body(iters, warmup, () => {
    let f = fsys.open("seed.bin", "r")
    ignore(fsys.seek(f, 0, @filefs.SeekWhence::End))
    ignore(fsys.tell(f))
    fsys.rewind(f)
    fsys.close(f)
  })
  ops.push(("seek_tell_rewind", a8, b8))

  let (a9, b9) = time_body(iters, warmup, () => {
    if fsys.file_exists("copy_dst.bin") {
      fsys.remove_file("copy_dst.bin")
    }
    fsys.copy_file("seed.bin", "copy_dst.bin")
  })
  ops.push(("copy_file", a9, b9))

  let (a10, b10) = time_body(iters, warmup, () => {
    let src = uniq("r") + ".txt"
    let dst = uniq("s") + ".txt"
    let f = fsys.open(src, "w")
    fsys.close(f)
    fsys.rename(src, dst)
    fsys.remove_file(dst)
  })
  ops.push(("rename", a10, b10))

  let (a11, b11) = time_body(iters, warmup, () => {
    let name = uniq("m") + ".txt"
    let f = fsys.open(name, "w")
    fsys.close(f)
    fsys.remove_file(name)
  })
  ops.push(("remove_file", a11, b11))

  let (a12, b12) = time_body(iters, warmup, () => {
    let d = fsys.open_dir("/")
    while true {
      match fsys.read_dir(d) {
        None => break
        Some(_) => ()
      }
    }
    fsys.close_dir(d)
  })
  ops.push(("readdir", a12, b12))

  let (a13, b13) = time_body(iters, warmup, () => {
    ignore(fsys.file_exists("seed.bin"))
    ignore(fsys.dir_exists("cwdbench"))
  })
  ops.push(("exists", a13, b13))

  let (a14, b14) = time_body(iters, warmup, () => {
    ignore(fsys.begin())
    let f = fsys.open(uniq("t") + ".txt", "w")
    ignore(fsys.write(f, [b'x']))
    fsys.close(f)
    ignore(fsys.commit())
  })
  ops.push(("txn_commit", a14, b14))

  fsys.umount()
  remove_quiet(image)
  remove_quiet(image + "-j")

  let mut first = true
  let builder = StringBuilder::new()
  builder.write_string("{\"language\":\"moonbit\",\"runtime\":\"moonbit\",\"ops\":{")
  for op in ops {
    if !first {
      builder.write_char(',')
    }
    first = false
    builder.write_string("\"")
    builder.write_string(op.0)
    builder.write_string("\":{\"ns_per_op\":")
    builder.write_string(op.1.to_string())
    builder.write_string(",\"iters\":")
    builder.write_string(op.2.to_string())
    builder.write_string("}")
  }
  builder.write_string("}}\n")
  println(builder.to_string())
}

///|
fn main {
  let args = @sys.get_cli_args()
  let mut iters = 40
  let mut warmup = 2
  if args.length() > 0 {
    iters = @strconv.parse_int(args[0]) catch { _ => 40 }
  }
  if args.length() > 1 {
    warmup = @strconv.parse_int(args[1]) catch { _ => 2 }
  }
  try {
    run(iters, warmup)
  } catch {
    err => {
      println("moonbit bench failed: \{err}")
      abort("bench failed")
    }
  }
}
