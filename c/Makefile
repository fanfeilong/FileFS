CFLAGS ?= -g -Wall -Wextra -Wno-unused-parameter
OBJS = main.o FileFS.o FileGit.o FileXfer.o

all: demo

demo: $(OBJS)
	gcc $(CFLAGS) -o demo $(OBJS)

%.o: %.c
	gcc $(CFLAGS) -c -o $@ $<

main.o: main.c FileFS.h FileGit.h FileXfer.h
FileFS.o: FileFS.c FileFS.h
FileGit.o: FileGit.c FileGit.h FileFS.h
FileXfer.o: FileXfer.c FileXfer.h FileFS.h

test-git: demo
	./test_git.sh

test-xfer: demo
	./test_xfer.sh

test: test-git test-xfer

clean:
	rm -f demo $(OBJS) *.ffs test_git.ffs
	rm -rf test_xfer_host test_xfer_out
