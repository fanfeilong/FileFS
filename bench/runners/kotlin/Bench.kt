package filefs.bench

import filefs.DirectoryHandle
import filefs.FileHandle
import filefs.FileSystem
import filefs.SeekWhence
import java.nio.file.Files
import java.nio.file.Path
import kotlin.system.measureNanoTime

private const val PAYLOAD = 4096
private var counter = 0

private fun uniq(prefix: String): String {
    counter += 1
    return "$prefix$counter"
}

private fun median(samples: MutableList<Double>): Double {
    samples.sort()
    val n = samples.size
    if (n == 0) return 0.0
    return if (n % 2 == 0) (samples[n / 2 - 1] + samples[n / 2]) / 2.0 else samples[n / 2]
}

private fun timeOp(iters: Int, warmup: Int, body: () -> Unit): Map<String, Any> {
    repeat(warmup) { body() }
    val samples = MutableList(0) { 0.0 }
    repeat(iters) {
        samples += measureNanoTime(body).toDouble()
    }
    return mapOf("ns_per_op" to median(samples), "iters" to iters)
}

fun main(args: Array<String>) {
    val iters = args.getOrNull(0)?.toIntOrNull() ?: 40
    val warmup = args.getOrNull(1)?.toIntOrNull() ?: 2
    val dir = Files.createTempDirectory("filefs-bench-kotlin-")
    val image = dir.resolve("bench.ffs")
    val payload = ByteArray(PAYLOAD) { it.toByte() }
    val buf = ByteArray(PAYLOAD)
    val ops = linkedMapOf<String, Map<String, Any>>()

    ops["mkfs"] = timeOp(iters, warmup) {
        val p = dir.resolve("${uniq("mkfs")}.ffs")
        FileSystem.mkfs(p)
        Files.deleteIfExists(p)
        Files.deleteIfExists(Path.of("$p-j"))
    }

    FileSystem.mkfs(image)
    val fsys = FileSystem()
    fsys.mount(image)

    ops["mount_umount"] = timeOp(iters, warmup) {
        fsys.umount()
        fsys.mount(image)
    }

    ops["mkdir"] = timeOp(iters, warmup) { fsys.mkdir(uniq("d")) }
    fsys.mkdir("cwdbench")
    ops["chdir_getcwd"] = timeOp(iters, warmup) {
        fsys.chdir("cwdbench")
        fsys.getcwd()
        fsys.chdir("/")
    }

    ops["open_write_close"] = timeOp(iters, warmup) {
        val f: FileHandle = fsys.open("${uniq("o")}.txt", "w")
        fsys.close(f)
    }

    run {
        val seed = fsys.open("seed.bin", "w")
        fsys.write(seed, payload)
        fsys.close(seed)
    }

    ops["write_4kib"] = timeOp(iters, warmup) {
        val f = fsys.open("wbench.bin", "w")
        fsys.write(f, payload)
        fsys.close(f)
    }

    ops["read_4kib"] = timeOp(iters, warmup) {
        val f = fsys.open("seed.bin", "r")
        fsys.read(f, buf)
        fsys.close(f)
    }

    ops["seek_tell_rewind"] = timeOp(iters, warmup) {
        val f = fsys.open("seed.bin", "r")
        fsys.seek(f, 0, SeekWhence.END)
        fsys.tell(f)
        fsys.rewind(f)
        fsys.close(f)
    }

    ops["copy_file"] = timeOp(iters, warmup) {
        if (fsys.fileExists("copy_dst.bin")) fsys.removeFile("copy_dst.bin")
        fsys.copyFile("seed.bin", "copy_dst.bin")
    }

    ops["rename"] = timeOp(iters, warmup) {
        val src = "${uniq("r")}.txt"
        val dst = "${uniq("s")}.txt"
        val f = fsys.open(src, "w")
        fsys.close(f)
        fsys.rename(src, dst)
        fsys.removeFile(dst)
    }

    ops["remove_file"] = timeOp(iters, warmup) {
        val name = "${uniq("m")}.txt"
        val f = fsys.open(name, "w")
        fsys.close(f)
        fsys.removeFile(name)
    }

    ops["readdir"] = timeOp(iters, warmup) {
        val d: DirectoryHandle = fsys.openDir("/")
        while (fsys.readDir(d) != null) {
        }
        fsys.closeDir(d)
    }

    ops["exists"] = timeOp(iters, warmup) {
        fsys.fileExists("seed.bin")
        fsys.dirExists("cwdbench")
    }

    ops["txn_commit"] = timeOp(iters, warmup) {
        check(fsys.begin())
        val f = fsys.open("${uniq("t")}.txt", "w")
        fsys.write(f, byteArrayOf('x'.code.toByte()))
        fsys.close(f)
        check(fsys.commit())
    }

    fsys.umount()

    val sb = StringBuilder()
    sb.append("{\"language\":\"kotlin\",\"runtime\":\"kotlinc\",\"ops\":{")
    var first = true
    for ((k, v) in ops) {
        if (!first) sb.append(',')
        first = false
        sb.append("\"$k\":{\"ns_per_op\":${v["ns_per_op"]},\"iters\":${v["iters"]}}")
    }
    sb.append("}}")
    println(sb.toString())
}
