import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import com.filefs.DirectoryHandle;
import com.filefs.FileHandle;
import com.filefs.FileSystem;
import com.filefs.SeekWhence;

public final class Bench {
  private static final int PAYLOAD = 4096;
  private static int counter;

  private Bench() {}

  private static String uniq(String prefix) {
    return prefix + (++counter);
  }

  private static double median(List<Double> samples) {
    samples.sort(Comparator.naturalOrder());
    int n = samples.size();
    if (n == 0) return 0;
    if (n % 2 == 0) return (samples.get(n / 2 - 1) + samples.get(n / 2)) / 2.0;
    return samples.get(n / 2);
  }

  private static ThrowingRunnable wrap(ThrowingRunnable body) {
    return body;
  }

  @FunctionalInterface
  private interface ThrowingRunnable {
    void run() throws Exception;
  }

  private static void runChecked(ThrowingRunnable body) {
    try {
      body.run();
    } catch (Exception e) {
      throw new RuntimeException(e);
    }
  }

  private static Map<String, Object> timeOp(int iters, int warmup, ThrowingRunnable body) {
    for (int i = 0; i < warmup; i++) runChecked(body);
    List<Double> samples = new ArrayList<>(iters);
    for (int i = 0; i < iters; i++) {
      long t0 = System.nanoTime();
      runChecked(body);
      samples.add((double) (System.nanoTime() - t0));
    }
    Map<String, Object> out = new LinkedHashMap<>();
    out.put("ns_per_op", median(samples));
    out.put("iters", iters);
    return out;
  }

  private static void emit(Map<String, Map<String, Object>> ops) {
    StringBuilder sb = new StringBuilder();
    sb.append("{\"language\":\"java\",\"runtime\":\"")
        .append(System.getProperty("java.version"))
        .append("\",\"ops\":{");
    boolean first = true;
    for (Map.Entry<String, Map<String, Object>> e : ops.entrySet()) {
      if (!first) sb.append(',');
      first = false;
      sb.append('"').append(e.getKey()).append("\":{\"ns_per_op\":")
          .append(e.getValue().get("ns_per_op"))
          .append(",\"iters\":")
          .append(e.getValue().get("iters"))
          .append('}');
    }
    sb.append("}}");
    System.out.println(sb);
  }

  public static void main(String[] args) throws Exception {
    int iters = args.length > 0 ? Integer.parseInt(args[0]) : 40;
    int warmup = args.length > 1 ? Integer.parseInt(args[1]) : 2;
    Path dir = Files.createTempDirectory("filefs-bench-java-");
    Path image = dir.resolve("bench.ffs");
    byte[] payload = new byte[PAYLOAD];
    for (int i = 0; i < PAYLOAD; i++) payload[i] = (byte) i;
    byte[] buf = new byte[PAYLOAD];
    Map<String, Map<String, Object>> ops = new LinkedHashMap<>();

    ops.put("mkfs", timeOp(iters, warmup, wrap(() -> {
      Path p = dir.resolve(uniq("mkfs") + ".ffs");
      FileSystem.mkfs(p);
      Files.deleteIfExists(p);
      Files.deleteIfExists(Path.of(p + "-j"));
    })));

    FileSystem.mkfs(image);
    FileSystem fsys = new FileSystem();
    fsys.mount(image);

    ops.put("mount_umount", timeOp(iters, warmup, wrap(() -> {
      fsys.umount();
      fsys.mount(image);
    })));

    ops.put("mkdir", timeOp(iters, warmup, wrap(() -> fsys.mkdir(uniq("d")))));
    fsys.mkdir("cwdbench");
    ops.put("chdir_getcwd", timeOp(iters, warmup, wrap(() -> {
      fsys.chdir("cwdbench");
      fsys.getcwd();
      fsys.chdir("/");
    })));

    ops.put("open_write_close", timeOp(iters, warmup, wrap(() -> {
      FileHandle f = fsys.open(uniq("o") + ".txt", "w");
      fsys.close(f);
    })));

    FileHandle seed = fsys.open("seed.bin", "w");
    fsys.write(seed, payload, 0, payload.length);
    fsys.close(seed);

    ops.put("write_4kib", timeOp(iters, warmup, wrap(() -> {
      FileHandle f = fsys.open("wbench.bin", "w");
      fsys.write(f, payload, 0, payload.length);
      fsys.close(f);
    })));

    ops.put("read_4kib", timeOp(iters, warmup, wrap(() -> {
      FileHandle f = fsys.open("seed.bin", "r");
      fsys.read(f, buf, 0, buf.length);
      fsys.close(f);
    })));

    ops.put("seek_tell_rewind", timeOp(iters, warmup, wrap(() -> {
      FileHandle f = fsys.open("seed.bin", "r");
      fsys.seek(f, 0, SeekWhence.END);
      fsys.tell(f);
      fsys.rewind(f);
      fsys.close(f);
    })));

    ops.put("copy_file", timeOp(iters, warmup, wrap(() -> {
      if (fsys.fileExists("copy_dst.bin")) fsys.removeFile("copy_dst.bin");
      fsys.copyFile("seed.bin", "copy_dst.bin");
    })));

    ops.put("rename", timeOp(iters, warmup, wrap(() -> {
      String src = uniq("r") + ".txt";
      String dst = uniq("s") + ".txt";
      FileHandle f = fsys.open(src, "w");
      fsys.close(f);
      fsys.rename(src, dst);
      fsys.removeFile(dst);
    })));

    ops.put("remove_file", timeOp(iters, warmup, wrap(() -> {
      String name = uniq("m") + ".txt";
      FileHandle f = fsys.open(name, "w");
      fsys.close(f);
      fsys.removeFile(name);
    })));

    ops.put("readdir", timeOp(iters, warmup, wrap(() -> {
      DirectoryHandle d = fsys.openDir("/");
      while (fsys.readDir(d) != null) {}
      fsys.closeDir(d);
    })));

    ops.put("exists", timeOp(iters, warmup, wrap(() -> {
      fsys.fileExists("seed.bin");
      fsys.dirExists("cwdbench");
    })));

    ops.put("txn_commit", timeOp(iters, warmup, wrap(() -> {
      fsys.begin();
      FileHandle f = fsys.open(uniq("t") + ".txt", "w");
      byte[] x = new byte[] {'x'};
      fsys.write(f, x, 0, 1);
      fsys.close(f);
      fsys.commit();
    })));

    fsys.umount();
    emit(ops);
  }
}
