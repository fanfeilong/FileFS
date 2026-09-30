CFLAGS ?= -g -Wall -Wextra -Wno-unused-parameter
OBJS = main.o FileFS.o FileGit.o

all: demo

demo: $(OBJS)
	gcc $(CFLAGS) -o demo $(OBJS)

%.o: %.c
	gcc $(CFLAGS) -c -o $@ $<

main.o: main.c FileFS.h FileGit.h
FileFS.o: FileFS.c FileFS.h
FileGit.o: FileGit.c FileGit.h FileFS.h

test-git: demo
	./test_git.sh

clean:
	rm -f demo $(OBJS) *.ffs test_git.ffs
