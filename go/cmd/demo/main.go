/*----------------------------------------------------------------------------/
/  FileFS - Implement a virtual file system within a single file R1.0         /
/-----------------------------------------------------------------------------/
/
/ Copyright (C) 2025, cyantree, all right reserved.
/
/ mail: cyantree.guo@gmail.com
/ QQ: 9234933
/
/----------------------------------------------------------------------------*/

package main

import (
	"bufio"
	"fmt"
	"os"
	"strings"

	"github.com/cyantree/filefs/go/filefs"
)

func usage() {
	fmt.Println("  Supported commands:")
	fmt.Println("\t?/h/help")
	fmt.Println("\tq/quit")
	fmt.Println("\tmkfs fs_filename")
	fmt.Println("\tmount fs_filename")
	fmt.Println("\tunmount")
	fmt.Println("\tpwd")
	fmt.Println("\tls (path)")
	fmt.Println("\tcd path")
	fmt.Println("\tmkdir path")
	fmt.Println("\trm path")
	fmt.Println("\techo filename content")
	fmt.Println("\tadd filename content")
	fmt.Println("\tow filename content (overwrite file)")
	fmt.Println("\tcat filename")
	fmt.Println("\tfilesize filename")
	fmt.Println("\tseek")
	fmt.Println("\tdel filename")
	fmt.Println("\trename from to")
	fmt.Println("\tmv from to (file or path)")
	fmt.Println("\tcp from_filename to_filename")
	fmt.Println("\tbegin")
	fmt.Println("\tcommit")
	fmt.Println("\trollback")
}

func direntName(d *filefs.Dirent) string {
	n := d.DName[:]
	for i, b := range n {
		if b == 0 {
			return string(n[:i])
		}
	}
	return string(n)
}

func funLS(ffs *filefs.FileFS, path string) {
	if path == "" {
		return
	}
	dirp, solPath := ffs.Opendir(path)
	if dirp == nil {
		fmt.Println("path ERR")
		return
	}
	nDir, nFile := 0, 0
	fmt.Printf("  [dir]: %s\n", solPath)
	for {
		dir := ffs.Readdir(dirp)
		if dir == nil {
			break
		}
		name := direntName(dir)
		if name == "." {
			if dir.DType == filefs.DTDir {
				fmt.Println("\t<DIR>\t.")
			}
			continue
		}
		if name == ".." {
			if dir.DType == filefs.DTDir {
				fmt.Println("\t<DIR>\t..")
			}
			continue
		}
		if dir.DType == filefs.DTDir {
			fmt.Printf("\t<DIR>\t%s\n", name)
			nDir++
			continue
		}
		fmt.Printf("\t\t%s\n", name)
		nFile++
	}
	ffs.Closedir(dirp)
	fmt.Printf("  dir:%d, file:%d\n", nDir, nFile)
}

func funFwrite(ffs *filefs.FileFS, filename, content, mode string) {
	fp := ffs.Fopen(filename, mode)
	if fp == nil {
		fmt.Printf("fopen %s err\n", filename)
		return
	}
	data := []byte(content)
	r := ffs.Fwrite(data, 1, len(data), fp)
	fmt.Printf("write %d to %s\n", r, filename)
	ffs.Fclose(fp)
}

func funCat(ffs *filefs.FileFS, filename string) {
	fp := ffs.Fopen(filename, "r")
	if fp == nil {
		fmt.Printf("fopen %s err, not exist\n", filename)
		return
	}
	txt := make([]byte, 1024)
	n := 0
	for {
		for i := range txt {
			txt[i] = 0
		}
		r := ffs.Fread(txt, 1, 1023, fp)
		n += r
		if r > 0 {
			fmt.Print(string(txt[:r]))
		} else {
			break
		}
	}
	fmt.Printf("\nread %d from %s\n", n, filename)
	ffs.Fclose(fp)
}

func funFilesize(ffs *filefs.FileFS, filename string) {
	fp := ffs.Fopen(filename, "a+")
	if fp == nil {
		fmt.Printf("fopen %s err, not exist\n", filename)
		return
	}
	size := ffs.Ftell(fp)
	ffs.Fclose(fp)
	fmt.Printf("file (%s) size:%d\n", filename, size)
}

func funSeek(ffs *filefs.FileFS, filename string) {
	fp := ffs.Fopen(filename, "r+")
	if fp == nil {
		fmt.Printf("seek fopen %s err, not exist\n", filename)
		return
	}
	ffs.Fseek(fp, 10, filefs.SeekCur)
	if !ffs.Fseek(fp, 15, filefs.SeekSet) {
		fmt.Println("seek err")
	}
	txt := []byte(".....insert.....")
	ffs.Fwrite(txt, 1, len(txt), fp)
	pos := ffs.Ftell(fp)
	fmt.Printf("pos:%d\n", pos)
	ffs.Fclose(fp)
}

func splitTwo(rest string) (a, b string, ok bool) {
	rest = strings.TrimSpace(rest)
	if rest == "" {
		return "", "", false
	}
	i := strings.IndexByte(rest, ' ')
	if i < 0 {
		return "", "", false
	}
	a = rest[:i]
	b = strings.TrimLeft(rest[i+1:], " ")
	if a == "" || b == "" {
		return "", "", false
	}
	return a, b, true
}

func main() {
	ffs := filefs.Create()
	if ffs == nil {
		fmt.Println("FileFS create ERR")
		return
	}
	defer ffs.Destroy()

	scanner := bufio.NewScanner(os.Stdin)
	fmt.Println("Welcome to FileFS Browsing Shell v1.0")
	for {
		fmt.Print("$>")
		if !scanner.Scan() {
			fmt.Println()
			break
		}
		cmd := scanner.Text()
		if cmd == "" {
			continue
		}

		switch {
		case cmd == "?" || cmd == "help" || cmd == "h":
			usage()
		case cmd == "q" || cmd == "quit":
			return
		case strings.HasPrefix(cmd, "mkfs"):
			if len(cmd) > 4 && cmd[4] == ' ' {
				fn := strings.TrimLeft(cmd[5:], " ")
				if fn != "" {
					if filefs.Mkfs(fn) {
						fmt.Printf("OK, mkfs %s\n", fn)
					} else {
						fmt.Printf("ERR, mkfs %s\n", fn)
					}
					continue
				}
			}
			fmt.Printf("  Unknown/Incorrect command: %s\n", cmd)
			usage()
		case strings.HasPrefix(cmd, "mount"):
			if len(cmd) > 5 && cmd[5] == ' ' {
				fn := strings.TrimLeft(cmd[6:], " ")
				if fn != "" {
					if ffs.Mount(fn) {
						fmt.Printf("OK, mount %s\n", fn)
					} else {
						fmt.Printf("ERR, mount %s\n", fn)
					}
					continue
				}
			}
			fmt.Printf("  Unknown/Incorrect command: %s\n", cmd)
			usage()
		case cmd == "umount":
			ffs.Umount()
		case cmd == "pwd":
			if !ffs.IsMount() {
				fmt.Println("ERR: not mount data file.")
			} else {
				fmt.Println(ffs.Getcwd())
			}
		case strings.HasPrefix(cmd, "ls"):
			if !ffs.IsMount() {
				fmt.Println("ERR: not mount data file.")
				continue
			}
			if len(cmd) > 2 && cmd[2] == ' ' {
				path := strings.TrimLeft(cmd[3:], " ")
				if path != "" {
					funLS(ffs, path)
					continue
				}
			} else if len(cmd) == 2 {
				funLS(ffs, ".")
				continue
			}
			continue
		case strings.HasPrefix(cmd, "cd"):
			if !ffs.IsMount() {
				fmt.Println("ERR: not mount data file.")
				continue
			}
			if len(cmd) > 2 && cmd[2] == ' ' {
				path := strings.TrimLeft(cmd[3:], " ")
				if path != "" {
					if !ffs.Chdir(path) {
						fmt.Printf("cd %s ERR\n", path)
					}
					continue
				}
			} else {
				if !ffs.Chdir("/") {
					fmt.Println("cd / ERR")
				}
				continue
			}
		case strings.HasPrefix(cmd, "mkdir"):
			if len(cmd) > 5 && cmd[5] == ' ' {
				path := strings.TrimLeft(cmd[6:], " ")
				if path != "" {
					if !ffs.IsMount() {
						fmt.Println("ERR: not mount data file.")
					} else {
						r := ffs.Mkdir(path)
						switch r {
						case 1:
							fmt.Printf("mkdir %s ERR\n", path)
						case 2:
							fmt.Printf("ERR: name too long [%s].\n", path)
						case 3:
							fmt.Printf("directory %s is existed.\n", path)
						case 4:
							fmt.Printf("exist same name file [%s].\n", path)
						}
					}
					continue
				}
			}
			fmt.Printf("  Unknown/Incorrect command: %s\n", cmd)
			usage()
		case strings.HasPrefix(cmd, "rm"):
			if len(cmd) > 2 && cmd[2] == ' ' {
				path := strings.TrimLeft(cmd[3:], " ")
				if path != "" {
					if !ffs.IsMount() {
						fmt.Println("ERR: not mount data file.")
					} else {
						r := ffs.Rmdir(path)
						switch r {
						case 1:
							fmt.Printf("rmdir %s ERR\n", path)
						case 2:
							fmt.Printf("ERR: sub path not empty [%s].\n", path)
						case 3:
							fmt.Printf("ERR: path not exist [%s].\n", path)
						case 4:
							fmt.Printf("ERR: name to long [%s].\n", path)
						}
					}
					continue
				}
			}
			fmt.Printf("  Unknown/Incorrect command: %s\n", cmd)
			usage()
		case strings.HasPrefix(cmd, "echo"):
			if len(cmd) > 4 && cmd[4] == ' ' {
				fn, txt, ok := splitTwo(cmd[5:])
				if ok {
					if !ffs.IsMount() {
						fmt.Println("ERR: not mount data file.")
					} else {
						funFwrite(ffs, fn, txt, "w")
					}
					continue
				}
			}
			fmt.Printf("  Unknown/Incorrect command: %s\n", cmd)
			usage()
		case strings.HasPrefix(cmd, "add"):
			if len(cmd) > 3 && cmd[3] == ' ' {
				fn, txt, ok := splitTwo(cmd[4:])
				if ok {
					if !ffs.IsMount() {
						fmt.Println("ERR: not mount data file.")
					} else {
						funFwrite(ffs, fn, txt, "a")
					}
					continue
				}
			}
			fmt.Printf("  Unknown/Incorrect command: %s\n", cmd)
			usage()
		case strings.HasPrefix(cmd, "ow"):
			if len(cmd) > 2 && cmd[2] == ' ' {
				fn, txt, ok := splitTwo(cmd[3:])
				if ok {
					if !ffs.IsMount() {
						fmt.Println("ERR: not mount data file.")
					} else {
						funFwrite(ffs, fn, txt, "r+")
					}
					continue
				}
			}
			fmt.Printf("  Unknown/Incorrect command: %s\n", cmd)
			usage()
		case strings.HasPrefix(cmd, "cat"):
			if len(cmd) > 3 && cmd[3] == ' ' {
				fn := strings.TrimLeft(cmd[4:], " ")
				if fn != "" {
					if !ffs.IsMount() {
						fmt.Println("ERR: not mount data file.")
					} else {
						funCat(ffs, fn)
					}
					continue
				}
			}
			fmt.Printf("  Unknown/Incorrect command: %s\n", cmd)
			usage()
		case strings.HasPrefix(cmd, "filesize"):
			if len(cmd) > 8 && cmd[8] == ' ' {
				fn := strings.TrimLeft(cmd[9:], " ")
				if fn != "" {
					if !ffs.IsMount() {
						fmt.Println("ERR: not mount data file.")
					} else {
						funFilesize(ffs, fn)
					}
					continue
				}
			}
			fmt.Printf("  Unknown/Incorrect command: %s\n", cmd)
			usage()
		case strings.HasPrefix(cmd, "seek"):
			if len(cmd) > 4 && cmd[4] == ' ' {
				fn := strings.TrimLeft(cmd[5:], " ")
				if fn != "" {
					if !ffs.IsMount() {
						fmt.Println("ERR: not mount data file.")
					} else {
						funSeek(ffs, fn)
					}
					continue
				}
			}
			continue
		case strings.HasPrefix(cmd, "del"):
			if len(cmd) > 3 && cmd[3] == ' ' {
				fn := strings.TrimLeft(cmd[4:], " ")
				if fn != "" {
					if !ffs.IsMount() {
						fmt.Println("ERR: not mount data file.")
					} else {
						r := ffs.Remove(fn)
						switch r {
						case 1:
							fmt.Printf("remove %s ERR\n", fn)
						case 2:
							fmt.Printf("ERR: file not exist [%s].\n", fn)
						case 3:
							fmt.Printf("ERR: dir not exist [%s].\n", fn)
						case 4:
							fmt.Printf("ERR: name to long [%s].\n", fn)
						case 5:
							fmt.Printf("ERR: name format err [%s].\n", fn)
						}
					}
					continue
				}
			}
			fmt.Printf("  Unknown/Incorrect command: %s\n", cmd)
			usage()
		case strings.HasPrefix(cmd, "rename"):
			if len(cmd) > 6 && cmd[6] == ' ' {
				fn, txt, ok := splitTwo(cmd[7:])
				if ok {
					if !ffs.IsMount() {
						fmt.Println("ERR: not mount data file.")
					} else {
						r := ffs.Rename(fn, txt)
						switch r {
						case 1:
							fmt.Printf("rename %s ERR\n", fn)
						case 2:
							fmt.Printf("ERR: old name format err [%s].\n", fn)
						case 3:
							fmt.Printf("ERR: new name format err [%s].\n", txt)
						case 4:
							fmt.Printf("ERR: old name not exist [%s].\n", fn)
						case 5:
							fmt.Printf("ERR: new name exist [%s].\n", txt)
						case 6:
							fmt.Printf("ERR: old new format not match [%s].\n", fn)
						}
					}
					continue
				}
			}
			fmt.Printf("  Unknown/Incorrect command: %s\n", cmd)
			usage()
		case strings.HasPrefix(cmd, "mv"):
			if len(cmd) > 2 && cmd[2] == ' ' {
				fn, txt, ok := splitTwo(cmd[3:])
				if ok {
					if !ffs.IsMount() {
						fmt.Println("ERR: not mount data file.")
					} else {
						r := ffs.Move(fn, txt)
						switch r {
						case 1:
							fmt.Printf("mv %s ERR\n", fn)
						case 2:
							fmt.Printf("ERR: from name format err [%s].\n", fn)
						case 3:
							fmt.Printf("ERR: to path format err [%s].\n", txt)
						case 4:
							fmt.Printf("ERR: from name not exist [%s].\n", fn)
						case 5:
							fmt.Printf("ERR: to file exist [%s].\n", txt)
						case 6:
							fmt.Printf("ERR: from to format not match [%s].\n", fn)
						}
					}
					continue
				}
			}
			fmt.Printf("  Unknown/Incorrect command: %s\n", cmd)
			usage()
		case strings.HasPrefix(cmd, "cp"):
			if len(cmd) > 2 && cmd[2] == ' ' {
				fn, txt, ok := splitTwo(cmd[3:])
				if ok {
					if !ffs.IsMount() {
						fmt.Println("ERR: not mount data file.")
					} else {
						r := ffs.Copy(fn, txt)
						switch r {
						case 1:
							fmt.Printf("copy %s ERR\n", fn)
						case 2:
							fmt.Printf("ERR: from name format err [%s].\n", fn)
						case 3:
							fmt.Printf("ERR: to path format err [%s].\n", txt)
						case 4:
							fmt.Printf("ERR: from name not exist [%s].\n", fn)
						case 5:
							fmt.Printf("ERR: to file exist [%s].\n", txt)
						}
					}
					continue
				}
			}
			fmt.Printf("  Unknown/Incorrect command: %s\n", cmd)
			usage()
		case cmd == "begin":
			if !ffs.IsMount() {
				fmt.Println("ERR: not mount data file.")
			} else if !ffs.Begin() {
				fmt.Println("begin err")
			}
		case cmd == "commit":
			if !ffs.IsMount() {
				fmt.Println("ERR: not mount data file.")
			} else if !ffs.Commit() {
				fmt.Println("commit err")
			}
		case cmd == "rollback":
			if !ffs.IsMount() {
				fmt.Println("ERR: not mount data file.")
			} else {
				ffs.Rollback()
			}
		default:
			fmt.Printf("  Unknown/Incorrect command: %s\n", cmd)
			usage()
		}
	}
}
