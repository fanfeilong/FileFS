/*----------------------------------------------------------------------------/
/  FileXfer - Host <-> FileFS binary import/export                            /
/----------------------------------------------------------------------------*/

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <dirent.h>
#include <errno.h>

#include "FileXfer.h"

#define FXFER_NAME_MAX 14
#define FXFER_PATH_MAX 512
#define FXFER_CHUNK 4096

static int component_ok(const char *name)
{
	size_t n;
	if (!name || !*name) return 0;
	if (strcmp(name, ".") == 0 || strcmp(name, "..") == 0) return 0;
	n = strlen(name);
	return n > 0 && n <= FXFER_NAME_MAX;
}

/* Ensure absolute-or-relative ffs directory path exists (mkdir -p). */
static int ensure_ffs_dir(FileFS *ffs, const char *ffs_dir)
{
	char tmp[FXFER_PATH_MAX];
	char built[FXFER_PATH_MAX];
	char *p, *save;
	int absolute;

	if (!ffs_dir || !*ffs_dir) return FXFER_BAD_ARG;
	if (strcmp(ffs_dir, "/") == 0 || strcmp(ffs_dir, ".") == 0) return FXFER_OK;

	strncpy(tmp, ffs_dir, sizeof(tmp) - 1);
	tmp[sizeof(tmp) - 1] = 0;
	absolute = (tmp[0] == '/');
	built[0] = 0;

	p = strtok_r(tmp, "/", &save);
	while (p) {
		int r;
		if (!component_ok(p)) return FXFER_NAME_TOO_LONG;
		if (built[0] == 0) {
			if (absolute)
				snprintf(built, sizeof(built), "/%s", p);
			else
				snprintf(built, sizeof(built), "%s", p);
		} else {
			size_t used = strlen(built);
			if (used + 1 + strlen(p) >= sizeof(built)) return FXFER_ERR;
			strcat(built, "/");
			strcat(built, p);
		}
		if (!FileFS_dir_exist(ffs, built)) {
			r = FileFS_mkdir(ffs, built);
			if (r != 0 && r != 3) return FXFER_ERR;
		}
		p = strtok_r(NULL, "/", &save);
	}
	return FXFER_OK;
}

static int ensure_ffs_parent(FileFS *ffs, const char *ffs_path)
{
	char parent[FXFER_PATH_MAX];
	char *slash;

	strncpy(parent, ffs_path, sizeof(parent) - 1);
	parent[sizeof(parent) - 1] = 0;
	slash = strrchr(parent, '/');
	if (!slash) return FXFER_OK; /* relative single component in cwd */
	if (slash == parent) {
		/* "/name" -> parent is root */
		return FXFER_OK;
	}
	*slash = 0;
	if (parent[0] == 0) return FXFER_OK;
	return ensure_ffs_dir(ffs, parent);
}

static int validate_ffs_file_path(const char *ffs_path)
{
	char tmp[FXFER_PATH_MAX];
	char *p, *save;

	if (!ffs_path || !*ffs_path) return FXFER_BAD_ARG;
	strncpy(tmp, ffs_path, sizeof(tmp) - 1);
	tmp[sizeof(tmp) - 1] = 0;
	p = strtok_r(tmp, "/", &save);
	while (p) {
		if (!component_ok(p)) return FXFER_NAME_TOO_LONG;
		p = strtok_r(NULL, "/", &save);
	}
	return FXFER_OK;
}

int FileXfer_import_file(FileFS *ffs, const char *host_path, const char *ffs_path)
{
	FILE *hf;
	FFS_FILE *ff;
	unsigned char buf[FXFER_CHUNK];
	size_t n, w, total = 0;
	int rc;

	if (!ffs || !FileFS_ismount(ffs) || !host_path || !ffs_path) return FXFER_BAD_ARG;
	rc = validate_ffs_file_path(ffs_path);
	if (rc != FXFER_OK) return rc;

	hf = fopen(host_path, "rb");
	if (!hf) return FXFER_NOT_FOUND;

	rc = ensure_ffs_parent(ffs, ffs_path);
	if (rc != FXFER_OK) {
		fclose(hf);
		return rc;
	}

	ff = FileFS_fopen(ffs, ffs_path, "w");
	if (!ff) {
		fclose(hf);
		return FXFER_ERR;
	}

	while ((n = fread(buf, 1, sizeof(buf), hf)) > 0) {
		w = FileFS_fwrite(ffs, buf, 1, n, ff);
		if (w != n) {
			FileFS_fclose(ffs, ff);
			fclose(hf);
			return FXFER_IO;
		}
		total += w;
	}
	if (ferror(hf)) {
		FileFS_fclose(ffs, ff);
		fclose(hf);
		return FXFER_IO;
	}

	FileFS_fclose(ffs, ff);
	fclose(hf);
	printf("import %s -> %s (%lu bytes)\n", host_path, ffs_path, (unsigned long)total);
	return FXFER_OK;
}

int FileXfer_export_file(FileFS *ffs, const char *ffs_path, const char *host_path)
{
	FFS_FILE *ff;
	FILE *hf;
	unsigned char buf[FXFER_CHUNK];
	size_t n, w, total = 0;

	if (!ffs || !FileFS_ismount(ffs) || !host_path || !ffs_path) return FXFER_BAD_ARG;
	if (!FileFS_file_exist(ffs, ffs_path)) return FXFER_NOT_FOUND;

	ff = FileFS_fopen(ffs, ffs_path, "r");
	if (!ff) return FXFER_ERR;

	hf = fopen(host_path, "wb");
	if (!hf) {
		FileFS_fclose(ffs, ff);
		return FXFER_IO;
	}

	while ((n = FileFS_fread(ffs, buf, 1, sizeof(buf), ff)) > 0) {
		w = fwrite(buf, 1, n, hf);
		if (w != n) {
			fclose(hf);
			FileFS_fclose(ffs, ff);
			return FXFER_IO;
		}
		total += w;
	}

	fclose(hf);
	FileFS_fclose(ffs, ff);
	printf("export %s -> %s (%lu bytes)\n", ffs_path, host_path, (unsigned long)total);
	return FXFER_OK;
}

static int join_path(char *out, size_t out_sz, const char *dir, const char *name)
{
	if (!dir || !*dir || strcmp(dir, ".") == 0)
		return snprintf(out, out_sz, "%s", name) >= (int)out_sz ? -1 : 0;
	if (strcmp(dir, "/") == 0)
		return snprintf(out, out_sz, "/%s", name) >= (int)out_sz ? -1 : 0;
	return snprintf(out, out_sz, "%s/%s", dir, name) >= (int)out_sz ? -1 : 0;
}

static int host_mkdir_p(const char *path)
{
	char tmp[FXFER_PATH_MAX];
	char *p;
	size_t len;

	if (!path || !*path) return FXFER_BAD_ARG;
	strncpy(tmp, path, sizeof(tmp) - 1);
	tmp[sizeof(tmp) - 1] = 0;
	len = strlen(tmp);
	if (len == 0) return FXFER_BAD_ARG;

	for (p = tmp + 1; *p; p++) {
		if (*p == '/') {
			*p = 0;
			if (mkdir(tmp, 0755) != 0 && errno != EEXIST) return FXFER_IO;
			*p = '/';
		}
	}
	if (mkdir(tmp, 0755) != 0 && errno != EEXIST) return FXFER_IO;
	return FXFER_OK;
}

int FileXfer_import_tree(FileFS *ffs, const char *host_dir, const char *ffs_dir,
	int skip_long_names)
{
	DIR *dp;
	struct dirent *ent;
	struct stat st;
	int rc;
	unsigned long files = 0, dirs = 0, skipped = 0;

	if (!ffs || !FileFS_ismount(ffs) || !host_dir || !ffs_dir) return FXFER_BAD_ARG;

	if (stat(host_dir, &st) != 0 || !S_ISDIR(st.st_mode)) return FXFER_NOT_FOUND;

	rc = ensure_ffs_dir(ffs, ffs_dir);
	if (rc != FXFER_OK) return rc;

	dp = opendir(host_dir);
	if (!dp) return FXFER_IO;

	while ((ent = readdir(dp)) != NULL) {
		char host_child[FXFER_PATH_MAX];
		char ffs_child[FXFER_PATH_MAX];

		if (strcmp(ent->d_name, ".") == 0 || strcmp(ent->d_name, "..") == 0)
			continue;
		if (!component_ok(ent->d_name)) {
			if (skip_long_names) {
				printf("skip (name too long): %s/%s\n", host_dir, ent->d_name);
				skipped++;
				continue;
			}
			closedir(dp);
			return FXFER_NAME_TOO_LONG;
		}
		if (join_path(host_child, sizeof(host_child), host_dir, ent->d_name) != 0 ||
			join_path(ffs_child, sizeof(ffs_child), ffs_dir, ent->d_name) != 0) {
			closedir(dp);
			return FXFER_ERR;
		}
		if (stat(host_child, &st) != 0) continue;
		if (S_ISDIR(st.st_mode)) {
			rc = FileXfer_import_tree(ffs, host_child, ffs_child, skip_long_names);
			if (rc != FXFER_OK) {
				closedir(dp);
				return rc;
			}
			dirs++;
		} else if (S_ISREG(st.st_mode)) {
			rc = FileXfer_import_file(ffs, host_child, ffs_child);
			if (rc != FXFER_OK) {
				closedir(dp);
				return rc;
			}
			files++;
		} else {
			printf("skip (not regular file): %s\n", host_child);
			skipped++;
		}
	}
	closedir(dp);
	printf("import-tree %s -> %s (files=%lu, dirs=%lu, skipped=%lu)\n",
		host_dir, ffs_dir, files, dirs, skipped);
	return FXFER_OK;
}

int FileXfer_export_tree(FileFS *ffs, const char *ffs_dir, const char *host_dir)
{
	FFS_DIR *dp;
	FFS_dirent *ent;
	char *shown = NULL;
	int rc;
	unsigned long files = 0, dirs = 0;

	if (!ffs || !FileFS_ismount(ffs) || !host_dir || !ffs_dir) return FXFER_BAD_ARG;
	if (!FileFS_dir_exist(ffs, ffs_dir) && strcmp(ffs_dir, "/") != 0 &&
		strcmp(ffs_dir, ".") != 0)
		return FXFER_NOT_FOUND;

	rc = host_mkdir_p(host_dir);
	if (rc != FXFER_OK) return rc;

	dp = FileFS_opendir(ffs, ffs_dir, &shown);
	if (!dp) return FXFER_ERR;

	while ((ent = FileFS_readdir(ffs, dp)) != NULL) {
		char host_child[FXFER_PATH_MAX];
		char ffs_child[FXFER_PATH_MAX];

		if (strcmp(ent->d_name, ".") == 0 || strcmp(ent->d_name, "..") == 0)
			continue;
		/* Skip git metadata when exporting from volume root */
		if ((strcmp(ffs_dir, "/") == 0 || strcmp(ffs_dir, ".") == 0) &&
			strcmp(ent->d_name, ".git") == 0)
			continue;

		if (join_path(host_child, sizeof(host_child), host_dir, ent->d_name) != 0 ||
			join_path(ffs_child, sizeof(ffs_child), ffs_dir, ent->d_name) != 0) {
			FileFS_closedir(ffs, dp);
			return FXFER_ERR;
		}
		if (ent->d_type == FFS_DT_DIR) {
			rc = FileXfer_export_tree(ffs, ffs_child, host_child);
			if (rc != FXFER_OK) {
				FileFS_closedir(ffs, dp);
				return rc;
			}
			dirs++;
		} else if (ent->d_type == FFS_DT_FILE) {
			rc = FileXfer_export_file(ffs, ffs_child, host_child);
			if (rc != FXFER_OK) {
				FileFS_closedir(ffs, dp);
				return rc;
			}
			files++;
		}
	}
	FileFS_closedir(ffs, dp);
	printf("export-tree %s -> %s (files=%lu, dirs=%lu)\n",
		ffs_dir, host_dir, files, dirs);
	return FXFER_OK;
}
