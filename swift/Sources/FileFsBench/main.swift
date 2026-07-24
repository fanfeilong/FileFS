import Foundation
import FileFS

@main
enum FileFsBench {
  static func main() throws {
    let payloadSize = 4096
    let iters = CommandLine.arguments.dropFirst().first.flatMap(Int.init) ?? 40
    let warmup = CommandLine.arguments.dropFirst(2).first.flatMap(Int.init) ?? 2

    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "filefs-bench-swift-\(ProcessInfo.processInfo.processIdentifier)",
        isDirectory: true
      )
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let image = dir.appendingPathComponent("bench.ffs")
    var counter = 0
    func uniq(_ prefix: String) -> String {
      counter += 1
      return "\(prefix)\(counter)"
    }

    var payload = [UInt8](repeating: 0, count: payloadSize)
    for i in 0..<payloadSize { payload[i] = UInt8(i & 0xff) }
    var buf = [UInt8](repeating: 0, count: payloadSize)

    func median(_ samples: inout [Double]) -> Double {
      samples.sort()
      let n = samples.count
      if n == 0 { return 0 }
      if n % 2 == 0 { return (samples[n / 2 - 1] + samples[n / 2]) / 2 }
      return samples[n / 2]
    }

    func timeBody(_ body: () throws -> Void) throws -> [String: Any] {
      for _ in 0..<warmup { try body() }
      var samples: [Double] = []
      samples.reserveCapacity(iters)
      for _ in 0..<iters {
        let t0 = DispatchTime.now().uptimeNanoseconds
        try body()
        samples.append(Double(DispatchTime.now().uptimeNanoseconds - t0))
      }
      return ["ns_per_op": median(&samples), "iters": iters]
    }

    var ops: [String: [String: Any]] = [:]

    ops["mkfs"] = try timeBody {
      let p = dir.appendingPathComponent("\(uniq("mkfs")).ffs")
      try FileSystem.mkfs(at: p.path)
      try? FileManager.default.removeItem(at: p)
      try? FileManager.default.removeItem(atPath: p.path + "-j")
    }

    try FileSystem.mkfs(at: image.path)
    let fsys = FileSystem()
    try fsys.mount(at: image.path)

    ops["mount_umount"] = try timeBody {
      fsys.umount()
      try fsys.mount(at: image.path)
    }

    ops["mkdir"] = try timeBody { try fsys.mkdir(uniq("d")) }
    try fsys.mkdir("cwdbench")
    ops["chdir_getcwd"] = try timeBody {
      try fsys.chdir("cwdbench")
      _ = fsys.getcwd()
      try fsys.chdir("/")
    }

    ops["open_write_close"] = try timeBody {
      let f = try fsys.open("\(uniq("o")).txt", mode: "w")
      fsys.close(f)
    }

    do {
      let seed = try fsys.open("seed.bin", mode: "w")
      _ = try fsys.write(seed, from: payload)
      fsys.close(seed)
    }

    ops["write_4kib"] = try timeBody {
      let f = try fsys.open("wbench.bin", mode: "w")
      _ = try fsys.write(f, from: payload)
      fsys.close(f)
    }

    ops["read_4kib"] = try timeBody {
      let f = try fsys.open("seed.bin", mode: "r")
      _ = try fsys.read(f, into: &buf)
      fsys.close(f)
    }

    ops["seek_tell_rewind"] = try timeBody {
      let f = try fsys.open("seed.bin", mode: "r")
      _ = try fsys.seek(f, offset: 0, whence: .end)
      _ = fsys.tell(f)
      fsys.rewind(f)
      fsys.close(f)
    }

    ops["copy_file"] = try timeBody {
      if fsys.fileExists("copy_dst.bin") { try fsys.removeFile("copy_dst.bin") }
      try fsys.copyFile(from: "seed.bin", to: "copy_dst.bin")
    }

    ops["rename"] = try timeBody {
      let src = "\(uniq("r")).txt"
      let dst = "\(uniq("s")).txt"
      let f = try fsys.open(src, mode: "w")
      fsys.close(f)
      try fsys.rename(from: src, to: dst)
      try fsys.removeFile(dst)
    }

    ops["remove_file"] = try timeBody {
      let name = "\(uniq("m")).txt"
      let f = try fsys.open(name, mode: "w")
      fsys.close(f)
      try fsys.removeFile(name)
    }

    ops["readdir"] = try timeBody {
      let d = try fsys.openDir("/")
      while fsys.readDir(d) != nil {}
      fsys.closeDir(d)
    }

    ops["exists"] = try timeBody {
      _ = fsys.fileExists("seed.bin")
      _ = fsys.dirExists("cwdbench")
    }

    ops["txn_commit"] = try timeBody {
      _ = try fsys.begin()
      let f = try fsys.open("\(uniq("t")).txt", mode: "w")
      _ = try fsys.write(f, from: [UInt8(ascii: "x")])
      fsys.close(f)
      _ = try fsys.commit()
    }

    fsys.umount()

    var parts: [String] = []
    for key in [
      "mkfs", "mount_umount", "mkdir", "chdir_getcwd", "open_write_close", "write_4kib",
      "read_4kib", "seek_tell_rewind", "copy_file", "rename", "remove_file", "readdir", "exists",
      "txn_commit",
    ] {
      let op = ops[key]!
      parts.append("\"\(key)\":{\"ns_per_op\":\(op["ns_per_op"]!),\"iters\":\(op["iters"]!)}")
    }
    print("{\"language\":\"swift\",\"runtime\":\"swift\",\"ops\":{\(parts.joined(separator: ","))}}")
  }
}
