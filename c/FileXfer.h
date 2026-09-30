/*----------------------------------------------------------------------------/
/  FileXfer - Host <-> FileFS binary import/export                            /
/-----------------------------------------------------------------------------/
/
/ Bridges the host filesystem and a mounted FileFS volume with raw byte I/O
/ (not limited to text). Intended for agent "netdisk" style workflows.
/
/----------------------------------------------------------------------------*/

#ifndef FileXfer_H_
#define FileXfer_H_

#include "FileFS.h"

#ifdef __cplusplus
extern "C" {
#endif

#define FXFER_OK 0
#define FXFER_ERR 1
#define FXFER_BAD_ARG 2
#define FXFER_NOT_FOUND 3
#define FXFER_NAME_TOO_LONG 4
#define FXFER_EXISTS 5
#define FXFER_IO 6

/* Copy one host file into FileFS (creates/overwrites ffs_path). Binary-safe. */
int FileXfer_import_file(FileFS *ffs, const char *host_path, const char *ffs_path);

/* Copy one FileFS file out to the host (creates/overwrites host_path). */
int FileXfer_export_file(FileFS *ffs, const char *ffs_path, const char *host_path);

/*
 * Recursively import a host directory tree into FileFS under ffs_dir.
 * Each FileFS path component must be <= 14 bytes. Skips "." / "..".
 * Returns FXFER_OK even if some entries are skipped due to name length when
 * skip_long_names is non-zero; otherwise aborts on first bad name.
 */
int FileXfer_import_tree(FileFS *ffs, const char *host_dir, const char *ffs_dir,
	int skip_long_names);

/* Recursively export a FileFS directory tree to the host under host_dir. */
int FileXfer_export_tree(FileFS *ffs, const char *ffs_dir, const char *host_dir);

#ifdef __cplusplus
}
#endif

#endif
