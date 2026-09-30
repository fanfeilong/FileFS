/*----------------------------------------------------------------------------/
/  FileGit - Git-like version control inside a FileFS volume                  /
/-----------------------------------------------------------------------------/
/
/ Designed for FileFS name limits (each path component <= 14 bytes).
/ Repository metadata lives at /.git inside the mounted FileFS image.
/
/----------------------------------------------------------------------------*/

#ifndef FileGit_H_
#define FileGit_H_

#include "FileFS.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Object id is first 12 hex digits of SHA-1 (fits FileFS 14-byte name limit). */
#define FGIT_OID_LEN 12
#define FGIT_OID_HEX (FGIT_OID_LEN + 1)
#define FGIT_PATH_MAX 512
#define FGIT_MSG_MAX 256
#define FGIT_NAME_MAX 14

/* Return codes */
#define FGIT_OK 0
#define FGIT_ERR 1
#define FGIT_NOT_REPO 2
#define FGIT_EXISTS 3
#define FGIT_NOT_FOUND 4
#define FGIT_BAD_ARG 5
#define FGIT_NAME_TOO_LONG 6
#define FGIT_CONFLICT 7
#define FGIT_EMPTY 8

/*
 * Layout inside FileFS (one volume = one repo):
 *   /.git/
 *     HEAD          -> "ref: refs/heads/main" or raw OID
 *     cfg           -> simple key=value config
 *     idx           -> staging index
 *     objs/<oid>    -> objects (blob/tree/commit), uncompressed
 *     refs/heads/<branch>
 *
 * Working tree = entire FileFS volume except paths under /.git
 */

int FileGit_init(FileFS *ffs);
int FileGit_is_repo(FileFS *ffs);

/* Stage / unstage working-tree files (paths relative to cwd or absolute). */
int FileGit_add(FileFS *ffs, const char *path);
int FileGit_rm(FileFS *ffs, const char *path);

/* Create a commit from the current index. message must be non-empty. */
int FileGit_commit(FileFS *ffs, const char *message);

/* Print status / history / object to stdout. */
int FileGit_status(FileFS *ffs);
int FileGit_log(FileFS *ffs, int max_count);
int FileGit_show(FileFS *ffs, const char *rev);
int FileGit_cat_file(FileFS *ffs, const char *oid);

/* Branch: name==NULL lists branches; otherwise creates branch at HEAD. */
int FileGit_branch(FileFS *ffs, const char *name);

/* Checkout branch name or commit OID; restores tracked files from tree. */
int FileGit_checkout(FileFS *ffs, const char *target);

/* Resolve HEAD to commit OID (hex). out must be FGIT_OID_HEX bytes. */
int FileGit_head_oid(FileFS *ffs, char *out);

#ifdef __cplusplus
}
#endif

#endif
