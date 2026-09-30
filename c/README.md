# FileFS (C)

Original C implementation of FileFS: a virtual filesystem stored in a single file.

## Layout

```
c/
  FileFS.h     # public FileFS API
  FileFS.c     # FileFS library implementation
  FileGit.h    # FileGit API (git-like VCS inside FileFS)
  FileGit.c    # FileGit implementation
  FileXfer.h   # host <-> FileFS binary import/export API
  FileXfer.c   # FileXfer implementation
  main.c       # interactive browsing shell (+ git / xfer commands)
  test_git.sh  # FileGit smoke test
  test_xfer.sh # binary import/export smoke test
  Makefile
```

## Build

```bash
cd c
make
```

## Run

```bash
./demo
```

Example session:

```
$>mkfs test.ffs
$>mount test.ffs
$>mkdir foo
$>echo hello.txt hello world
$>ls
$>cat hello.txt
$>q
```

## FileXfer (host <-> FileFS binary bridge)

FileFS already stores arbitrary bytes; the old shell only made text easy via
`echo`/`cat`. FileXfer fills the agent-netdisk gap: pull binary assets from the
host into the volume, and push them back out.

```
import <host_path> <ffs_path>
export <ffs_path> <host_path>
importtree <host_dir> <ffs_dir>
exporttree <ffs_dir> <host_dir>
```

Notes:

- Transfers are raw byte copies (NUL / high bytes preserved).
- Each FileFS path component must still be ≤ 14 bytes.
- `importtree` skips host names that are too long (with a warning).
- `exporttree / ...` skips `/.git` so repo metadata is not spilled to the host.

Example:

```
$>mkfs pack.ffs
$>mount pack.ffs
$>import ./photo.png photo.png
$>importtree ./assets assets
$>export photo.png /tmp/photo.png
$>exporttree assets /tmp/assets
$>git init
$>git add photo.png
$>git commit add photo
```

Automated tests:

```bash
make test          # git + xfer
make test-git
make test-xfer
```

## FileGit (git inside the single-file volume)

FileGit stores a miniature git repository **inside** the mounted FileFS image at
`/.git` (same convention as normal Git). The working tree is the rest of the
volume (everything except `/.git/**`).

Constraints adapted to FileFS:

| Git concept | FileGit adaptation |
|-------------|--------------------|
| `.git/` on disk | `/.git/` inside the FileFS volume |
| 40-hex SHA-1 object id | first **12** hex digits of SHA-1 |
| zlib object packing | uncompressed `type size\0payload` |
| long path components | each FileFS name ≤ 14 bytes |

On-disk layout:

```
/.git/
  HEAD            # ref: refs/heads/main  or detached OID
  cfg             # version / author
  idx             # staging index
  objs/<oid>      # blob / tree / commit objects
  refs/heads/<b>  # branch tips
```

Shell commands:

```
git init
git add <path>
git rm <path>
git status
git commit <message>
git log
git branch [name]
git checkout <branch|oid>
git show <branch|oid>
git cat-file <oid>
```

Example:

```
$>mkfs repo.ffs
$>mount repo.ffs
$>git init
$>echo readme.txt hello FileGit
$>git add readme.txt
$>git commit first commit
$>git status
$>git log
$>git branch feature
$>echo readme.txt hello again
$>git add readme.txt
$>git commit second
$>git checkout main
$>cat readme.txt
$>q
```

Automated smoke test:

```bash
make test-git
```

## Clean

```bash
make clean
```
