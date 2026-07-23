# FileFS (C)

Original C implementation of FileFS: a virtual filesystem stored in a single file.

## Layout

```
c/
  FileFS.h    # public API
  FileFS.c    # library implementation
  main.c      # interactive browsing shell
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

## Clean

```bash
make clean
```
