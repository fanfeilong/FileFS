use std::env;
use std::fs;
use std::io::SeekFrom;
use std::path::PathBuf;
use std::time::Instant;

use filefs::FileSystem;

const PAYLOAD: usize = 4096;

fn median(mut samples: Vec<f64>) -> f64 {
    samples.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let n = samples.len();
    if n == 0 {
        return 0.0;
    }
    if n % 2 == 0 {
        (samples[n / 2 - 1] + samples[n / 2]) / 2.0
    } else {
        samples[n / 2]
    }
}

fn fmt_op(ns: f64, iters: usize) -> String {
    format!("{{\"ns_per_op\":{ns:.3},\"iters\":{iters}}}")
}

fn time_body(iters: usize, warmup: usize, mut body: impl FnMut()) -> (f64, usize) {
    for _ in 0..warmup {
        body();
    }
    let mut samples = Vec::with_capacity(iters);
    for _ in 0..iters {
        let t0 = Instant::now();
        body();
        samples.push(t0.elapsed().as_nanos() as f64);
    }
    (median(samples), iters)
}

fn main() {
    let iters: usize = env::args().nth(1).and_then(|s| s.parse().ok()).unwrap_or(40);
    let warmup: usize = env::args().nth(2).and_then(|s| s.parse().ok()).unwrap_or(2);

    let dir = tempfile_dir();
    let image = dir.join("bench.ffs");
    let mut counter = 0usize;
    let mut uniq = |prefix: &str| {
        counter += 1;
        format!("{prefix}{counter}")
    };

    let payload: Vec<u8> = (0..PAYLOAD).map(|i| (i & 0xff) as u8).collect();
    let mut buf = vec![0u8; PAYLOAD];
    let mut ops = Vec::new();

    let (ns, n) = time_body(iters, warmup, || {
        let p = dir.join(format!("{}.ffs", uniq("mkfs")));
        FileSystem::mkfs(&p).unwrap();
        let _ = fs::remove_file(&p);
        let _ = fs::remove_file(format!("{}-j", p.display()));
    });
    ops.push(("mkfs", fmt_op(ns, n)));

    FileSystem::mkfs(&image).unwrap();
    let mut fsys = FileSystem::new();
    fsys.mount(&image).unwrap();

    let (ns, n) = time_body(iters, warmup, || {
        fsys.umount();
        fsys.mount(&image).unwrap();
    });
    ops.push(("mount_umount", fmt_op(ns, n)));

    let (ns, n) = time_body(iters, warmup, || {
        fsys.create_dir(&uniq("d")).unwrap();
    });
    ops.push(("mkdir", fmt_op(ns, n)));

    fsys.create_dir("cwdbench").unwrap();
    let (ns, n) = time_body(iters, warmup, || {
        fsys.chdir("cwdbench").unwrap();
        let _ = fsys.cwd();
        fsys.chdir("/").unwrap();
    });
    ops.push(("chdir_getcwd", fmt_op(ns, n)));

    let (ns, n) = time_body(iters, warmup, || {
        let mut f = fsys.open(&format!("{}.txt", uniq("o")), "w").unwrap();
        fsys.close(&mut f);
    });
    ops.push(("open_write_close", fmt_op(ns, n)));

    {
        let mut seed = fsys.open("seed.bin", "w").unwrap();
        fsys.write(&mut seed, &payload).unwrap();
        fsys.close(&mut seed);
    }

    let (ns, n) = time_body(iters, warmup, || {
        let mut f = fsys.open("wbench.bin", "w").unwrap();
        fsys.write(&mut f, &payload).unwrap();
        fsys.close(&mut f);
    });
    ops.push(("write_4kib", fmt_op(ns, n)));

    let (ns, n) = time_body(iters, warmup, || {
        let mut f = fsys.open("seed.bin", "r").unwrap();
        fsys.read(&mut f, &mut buf).unwrap();
        fsys.close(&mut f);
    });
    ops.push(("read_4kib", fmt_op(ns, n)));

    let (ns, n) = time_body(iters, warmup, || {
        let mut f = fsys.open("seed.bin", "r").unwrap();
        fsys.seek(&mut f, SeekFrom::End(0)).unwrap();
        let _ = fsys.stream_position(&f).unwrap();
        fsys.rewind(&mut f).unwrap();
        fsys.close(&mut f);
    });
    ops.push(("seek_tell_rewind", fmt_op(ns, n)));

    let (ns, n) = time_body(iters, warmup, || {
        let _ = fsys.remove_file("copy_dst.bin");
        fsys.copy_file("seed.bin", "copy_dst.bin").unwrap();
    });
    ops.push(("copy_file", fmt_op(ns, n)));

    let (ns, n) = time_body(iters, warmup, || {
        let mut f = fsys.open("ren_src.txt", "w").unwrap();
        fsys.close(&mut f);
        fsys.rename("ren_src.txt", "ren_dst.txt").unwrap();
        fsys.remove_file("ren_dst.txt").unwrap();
    });
    ops.push(("rename", fmt_op(ns, n)));

    let (ns, n) = time_body(iters, warmup, || {
        let mut f = fsys.open("rm_me.txt", "w").unwrap();
        fsys.close(&mut f);
        fsys.remove_file("rm_me.txt").unwrap();
    });
    ops.push(("remove_file", fmt_op(ns, n)));

    let (ns, n) = time_body(iters, warmup, || {
        let mut d = fsys.read_dir("/").unwrap();
        while d.next().is_some() {}
    });
    ops.push(("readdir", fmt_op(ns, n)));

    let (ns, n) = time_body(iters, warmup, || {
        let _ = fsys.file_exists("seed.bin");
        let _ = fsys.dir_exists("cwdbench");
    });
    ops.push(("exists", fmt_op(ns, n)));

    let (ns, n) = time_body(iters, warmup, || {
        fsys.begin().unwrap();
        let mut f = fsys.open(&format!("{}.txt", uniq("t")), "w").unwrap();
        fsys.write(&mut f, b"x").unwrap();
        fsys.close(&mut f);
        fsys.commit().unwrap();
    });
    ops.push(("txn_commit", fmt_op(ns, n)));

    fsys.umount();
    let _ = fs::remove_dir_all(&dir);

    print!(
        "{{\"language\":\"rust\",\"runtime\":\"{}\",\"ops\":{{",
        rustc_version()
    );
    for (i, (k, v)) in ops.iter().enumerate() {
        if i > 0 {
            print!(",");
        }
        print!("\"{k}\":{v}");
    }
    println!("}}}}");
}

fn tempfile_dir() -> PathBuf {
    let mut p = std::env::temp_dir();
    p.push(format!("filefs-bench-rust-{}", std::process::id()));
    fs::create_dir_all(&p).unwrap();
    p
}

fn rustc_version() -> String {
    std::process::Command::new("rustc")
        .arg("--version")
        .output()
        .ok()
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .map(|s| s.trim().to_string())
        .unwrap_or_else(|| "rustc".into())
}
