package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"time"

	"github.com/cyantree/filefs/go/filefs"
)

const payloadSize = 4096

func median(samples []float64) float64 {
	if len(samples) == 0 {
		return 0
	}
	cp := append([]float64(nil), samples...)
	sort.Float64s(cp)
	mid := len(cp) / 2
	if len(cp)%2 == 0 {
		return (cp[mid-1] + cp[mid]) / 2
	}
	return cp[mid]
}

func timeOp(iters, warmup int, prep func(), body func()) map[string]any {
	for i := 0; i < warmup; i++ {
		if prep != nil {
			prep()
		}
		body()
	}
	samples := make([]float64, 0, iters)
	for i := 0; i < iters; i++ {
		if prep != nil {
			prep()
		}
		start := time.Now()
		body()
		samples = append(samples, float64(time.Since(start).Nanoseconds()))
	}
	return map[string]any{"ns_per_op": median(samples), "iters": iters}
}

func must(ok bool, msg string) {
	if !ok {
		panic(msg)
	}
}

func main() {
	iters := 40
	warmup := 2
	if len(os.Args) > 1 {
		fmt.Sscanf(os.Args[1], "%d", &iters)
	}
	if len(os.Args) > 2 {
		fmt.Sscanf(os.Args[2], "%d", &warmup)
	}

	dir, err := os.MkdirTemp("", "filefs-bench-go-*")
	if err != nil {
		panic(err)
	}
	defer os.RemoveAll(dir)
	image := filepath.Join(dir, "bench.ffs")

	payload := make([]byte, payloadSize)
	for i := range payload {
		payload[i] = byte(i)
	}
	buf := make([]byte, payloadSize)

	ops := map[string]any{}

	ops["mkfs"] = timeOp(iters, warmup, nil, func() {
		path := filepath.Join(dir, fmt.Sprintf("mkfs-%d.ffs", time.Now().UnixNano()))
		must(filefs.Mkfs(path), "mkfs")
		os.Remove(path)
		os.Remove(path + "-j")
	})

	must(filefs.Mkfs(image), "mkfs base")
	ffs := filefs.Create()
	must(ffs.Mount(image), "mount")

	ops["mount_umount"] = timeOp(iters, warmup, func() {
		ffs.Umount()
	}, func() {
		must(ffs.Mount(image), "mount")
		ffs.Umount()
	})
	must(ffs.Mount(image), "remount")

	ops["mkdir"] = timeOp(iters, warmup, nil, func() {
		name := fmt.Sprintf("d%d", time.Now().UnixNano()%1_000_000_000)
		if ffs.Mkdir(name) != 0 {
			panic("mkdir")
		}
	})

	must(ffs.Mkdir("cwdbench") == 0, "mkdir cwd")
	ops["chdir_getcwd"] = timeOp(iters, warmup, nil, func() {
		must(ffs.Chdir("cwdbench"), "chdir")
		_ = ffs.Getcwd()
		must(ffs.Chdir("/"), "chdir root")
	})

	ops["open_write_close"] = timeOp(iters, warmup, nil, func() {
		name := fmt.Sprintf("o%d.txt", time.Now().UnixNano()%1_000_000_000)
		f := ffs.Fopen(name, "w")
		if f == nil {
			panic("fopen")
		}
		ffs.Fclose(f)
	})

	seed := ffs.Fopen("seed.bin", "w")
	if seed == nil || ffs.Fwrite(payload, 1, len(payload), seed) != len(payload) {
		panic("seed write")
	}
	ffs.Fclose(seed)

	ops["write_4kib"] = timeOp(iters, warmup, nil, func() {
		f := ffs.Fopen("wbench.bin", "w")
		if f == nil {
			panic("fopen write")
		}
		if ffs.Fwrite(payload, 1, len(payload), f) != len(payload) {
			panic("fwrite")
		}
		ffs.Fclose(f)
	})

	ops["read_4kib"] = timeOp(iters, warmup, nil, func() {
		f := ffs.Fopen("seed.bin", "r")
		if f == nil {
			panic("fopen read")
		}
		if ffs.Fread(buf, 1, len(buf), f) != len(buf) {
			panic("fread")
		}
		ffs.Fclose(f)
	})

	ops["seek_tell_rewind"] = timeOp(iters, warmup, nil, func() {
		f := ffs.Fopen("seed.bin", "r")
		if f == nil {
			panic("fopen seek")
		}
		must(ffs.Fseek(f, 0, filefs.SeekEnd), "seek end")
		_ = ffs.Ftell(f)
		ffs.Rewind(f)
		ffs.Fclose(f)
	})

	ops["copy_file"] = timeOp(iters, warmup, nil, func() {
		to := "copy_dst.bin"
		_ = ffs.Remove(to)
		if ffs.Copy("seed.bin", to) != 0 {
			panic("copy")
		}
	})

	ops["rename"] = timeOp(iters, warmup, nil, func() {
		src := fmt.Sprintf("r%d.txt", time.Now().UnixNano()%1_000_000_000)
		dst := fmt.Sprintf("s%d.txt", time.Now().UnixNano()%1_000_000_000)
		f := ffs.Fopen(src, "w")
		if f == nil {
			panic("fopen rename prep")
		}
		ffs.Fclose(f)
		if ffs.Rename(src, dst) != 0 {
			panic("rename")
		}
		_ = ffs.Remove(dst)
	})

	ops["remove_file"] = timeOp(iters, warmup, nil, func() {
		name := fmt.Sprintf("m%d.txt", time.Now().UnixNano()%1_000_000_000)
		f := ffs.Fopen(name, "w")
		if f == nil {
			panic("fopen remove prep")
		}
		ffs.Fclose(f)
		if ffs.Remove(name) != 0 {
			panic("remove")
		}
	})

	ops["readdir"] = timeOp(iters, warmup, nil, func() {
		d, _ := ffs.Opendir("/")
		if d == nil {
			panic("opendir")
		}
		for ffs.Readdir(d) != nil {
		}
		ffs.Closedir(d)
	})

	ops["exists"] = timeOp(iters, warmup, nil, func() {
		_ = ffs.FileExist("seed.bin")
		_ = ffs.DirExist("cwdbench")
	})

	ops["txn_commit"] = timeOp(iters, warmup, nil, func() {
		must(ffs.Begin(), "begin")
		name := fmt.Sprintf("t%d.txt", time.Now().UnixNano()%1_000_000_000)
		f := ffs.Fopen(name, "w")
		if f == nil {
			panic("txn fopen")
		}
		if ffs.Fwrite([]byte{'x'}, 1, 1, f) != 1 {
			panic("txn write")
		}
		ffs.Fclose(f)
		must(ffs.Commit(), "commit")
	})

	ffs.Umount()

	out := map[string]any{
		"language": "go",
		"runtime":  runtime.Version(),
		"ops":      ops,
	}
	enc := json.NewEncoder(os.Stdout)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(out); err != nil {
		panic(err)
	}
}
