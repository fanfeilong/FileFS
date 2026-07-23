package filefs_test

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/cyantree/filefs/go/filefs"
)

func TestBasicLifecycle(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "test.ffs")

	if !filefs.Mkfs(path) {
		t.Fatal("Mkfs failed")
	}

	ffs := filefs.Create()
	defer ffs.Destroy()

	if !ffs.Mount(path) {
		t.Fatal("Mount failed")
	}
	if !ffs.IsMount() {
		t.Fatal("expected mounted")
	}
	if ffs.Getcwd() != "/" {
		t.Fatalf("cwd=%q", ffs.Getcwd())
	}

	if r := ffs.Mkdir("docs"); r != 0 {
		t.Fatalf("Mkdir docs: %d", r)
	}
	if !ffs.Chdir("docs") {
		t.Fatal("Chdir docs failed")
	}

	fp := ffs.Fopen("note.txt", "w")
	if fp == nil {
		t.Fatal("Fopen w failed")
	}
	msg := []byte("hello filefs")
	if n := ffs.Fwrite(msg, 1, len(msg), fp); n != len(msg) {
		t.Fatalf("Fwrite got %d", n)
	}
	ffs.Fclose(fp)

	fp = ffs.Fopen("note.txt", "r")
	if fp == nil {
		t.Fatal("Fopen r failed")
	}
	buf := make([]byte, 64)
	n := ffs.Fread(buf, 1, len(buf), fp)
	ffs.Fclose(fp)
	if string(buf[:n]) != string(msg) {
		t.Fatalf("read %q want %q", buf[:n], msg)
	}

	if !ffs.Chdir("/") {
		t.Fatal("Chdir / failed")
	}
	if r := ffs.Copy("/docs/note.txt", "/copy.txt"); r != 0 {
		t.Fatalf("Copy: %d", r)
	}
	if r := ffs.Rename("copy.txt", "renamed.txt"); r != 0 {
		t.Fatalf("Rename: %d", r)
	}
	if r := ffs.Remove("renamed.txt"); r != 0 {
		t.Fatalf("Remove: %d", r)
	}

	d, abs := ffs.Opendir("/")
	if d == nil {
		t.Fatal("Opendir failed")
	}
	if abs == "" {
		t.Fatal("empty abs path")
	}
	found := false
	for {
		ent := ffs.Readdir(d)
		if ent == nil {
			break
		}
		name := ""
		for i, b := range ent.DName[:] {
			if b == 0 {
				name = string(ent.DName[:i])
				break
			}
		}
		if name == "docs" && ent.DType == filefs.DTDir {
			found = true
		}
	}
	ffs.Closedir(d)
	if !found {
		t.Fatal("docs not listed")
	}

	if !ffs.Begin() {
		t.Fatal("Begin failed")
	}
	fp = ffs.Fopen("txn.txt", "w")
	if fp == nil {
		t.Fatal("Fopen txn failed")
	}
	ffs.Fwrite([]byte("x"), 1, 1, fp)
	ffs.Fclose(fp)
	if !ffs.Commit() {
		t.Fatal("Commit failed")
	}
	if !ffs.FileExist("txn.txt") {
		t.Fatal("txn.txt missing after commit")
	}

	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if info.Size() < filefs.BlockSize*2 {
		t.Fatalf("unexpected size %d", info.Size())
	}
}
