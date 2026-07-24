using System.Diagnostics;
using System.Text.Json;
using FileFS;

const int PayloadSize = 4096;
var iters = args.Length > 0 && int.TryParse(args[0], out var i) ? i : 40;
var warmup = args.Length > 1 && int.TryParse(args[1], out var w) ? w : 2;

var dir = Directory.CreateTempSubdirectory("filefs-bench-dotnet-");
var image = Path.Combine(dir.FullName, "bench.ffs");
var counter = 0;
string Uniq(string prefix) => $"{prefix}{++counter}";

var payload = new byte[PayloadSize];
for (var n = 0; n < PayloadSize; n++) payload[n] = (byte)n;
var buf = new byte[PayloadSize];

static double Median(List<double> samples)
{
    samples.Sort();
    var n = samples.Count;
    if (n == 0) return 0;
    return n % 2 == 0 ? (samples[n / 2 - 1] + samples[n / 2]) / 2.0 : samples[n / 2];
}

Dictionary<string, object> TimeBody(int it, int wu, Action body)
{
    for (var n = 0; n < wu; n++) body();
    var samples = new List<double>(it);
    for (var n = 0; n < it; n++)
    {
        var sw = Stopwatch.StartNew();
        body();
        sw.Stop();
        samples.Add(sw.Elapsed.TotalNanoseconds);
    }
    return new Dictionary<string, object> { ["ns_per_op"] = Median(samples), ["iters"] = it };
}

var ops = new Dictionary<string, object>();

ops["mkfs"] = TimeBody(iters, warmup, () =>
{
    var p = Path.Combine(dir.FullName, $"{Uniq("mkfs")}.ffs");
    FileSystem.Mkfs(p);
    File.Delete(p);
    File.Delete(p + "-j");
});

FileSystem.Mkfs(image);
using var fsys = new FileSystem();
fsys.Mount(image);

ops["mount_umount"] = TimeBody(iters, warmup, () =>
{
    fsys.Umount();
    fsys.Mount(image);
});

ops["mkdir"] = TimeBody(iters, warmup, () => fsys.Mkdir(Uniq("d")));
fsys.Mkdir("cwdbench");
ops["chdir_getcwd"] = TimeBody(iters, warmup, () =>
{
    fsys.Chdir("cwdbench");
    _ = fsys.Getcwd();
    fsys.Chdir("/");
});

ops["open_write_close"] = TimeBody(iters, warmup, () =>
{
    var f = fsys.Open($"{Uniq("o")}.txt", "w");
    fsys.Close(f);
});

{
    var seed = fsys.Open("seed.bin", "w");
    fsys.Write(seed, payload);
    fsys.Close(seed);
}

ops["write_4kib"] = TimeBody(iters, warmup, () =>
{
    var f = fsys.Open("wbench.bin", "w");
    fsys.Write(f, payload);
    fsys.Close(f);
});

ops["read_4kib"] = TimeBody(iters, warmup, () =>
{
    var f = fsys.Open("seed.bin", "r");
    fsys.Read(f, buf);
    fsys.Close(f);
});

ops["seek_tell_rewind"] = TimeBody(iters, warmup, () =>
{
    var f = fsys.Open("seed.bin", "r");
    fsys.Seek(f, 0, SeekWhence.End);
    _ = fsys.Tell(f);
    fsys.Rewind(f);
    fsys.Close(f);
});

ops["copy_file"] = TimeBody(iters, warmup, () =>
{
    if (fsys.FileExists("copy_dst.bin")) fsys.RemoveFile("copy_dst.bin");
    fsys.CopyFile("seed.bin", "copy_dst.bin");
});

ops["rename"] = TimeBody(iters, warmup, () =>
{
    var src = $"{Uniq("r")}.txt";
    var dst = $"{Uniq("s")}.txt";
    var f = fsys.Open(src, "w");
    fsys.Close(f);
    fsys.Rename(src, dst);
    fsys.RemoveFile(dst);
});

ops["remove_file"] = TimeBody(iters, warmup, () =>
{
    var name = $"{Uniq("m")}.txt";
    var f = fsys.Open(name, "w");
    fsys.Close(f);
    fsys.RemoveFile(name);
});

ops["readdir"] = TimeBody(iters, warmup, () =>
{
    var d = fsys.OpenDir("/");
    while (fsys.ReadDir(d) is not null) { }
    fsys.CloseDir(d);
});

ops["exists"] = TimeBody(iters, warmup, () =>
{
    _ = fsys.FileExists("seed.bin");
    _ = fsys.DirExists("cwdbench");
});

ops["txn_commit"] = TimeBody(iters, warmup, () =>
{
    fsys.Begin();
    var f = fsys.Open($"{Uniq("t")}.txt", "w");
    fsys.Write(f, "x"u8);
    fsys.Close(f);
    fsys.Commit();
});

fsys.Umount();

var payload_out = new Dictionary<string, object>
{
    ["language"] = "dotnet",
    ["runtime"] = System.Runtime.InteropServices.RuntimeInformation.FrameworkDescription,
    ["ops"] = ops,
};
Console.WriteLine(JsonSerializer.Serialize(payload_out));
dir.Delete(true);
