/*----------------------------------------------------------------------------/
/  FileGit - Git-like version control inside a FileFS volume                  /
/----------------------------------------------------------------------------*/

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <ctype.h>

#include "FileGit.h"

#define FGIT_ROOT "/.git"
#define FGIT_HEAD "/.git/HEAD"
#define FGIT_CFG "/.git/cfg"
#define FGIT_IDX "/.git/idx"
#define FGIT_OBJS "/.git/objs"
#define FGIT_REFS "/.git/refs"
#define FGIT_HEADS "/.git/refs/heads"
#define FGIT_BRANCH_MAIN "main"
#define FGIT_IDX_MAGIC "FGITIDX1\n"

/* ======================== Minimal SHA-1 (public domain style) ============== */

typedef struct {
	unsigned int state[5];
	unsigned int count[2];
	unsigned char buffer[64];
} SHA1_CTX;

static void SHA1_Transform(unsigned int state[5], const unsigned char buffer[64]);

static void SHA1_Init(SHA1_CTX *ctx)
{
	ctx->state[0] = 0x67452301;
	ctx->state[1] = 0xEFCDAB89;
	ctx->state[2] = 0x98BADCFE;
	ctx->state[3] = 0x10325476;
	ctx->state[4] = 0xC3D2E1F0;
	ctx->count[0] = ctx->count[1] = 0;
}

static void SHA1_Update(SHA1_CTX *ctx, const unsigned char *data, unsigned int len)
{
	unsigned int i, j;
	j = (ctx->count[0] >> 3) & 63;
	if ((ctx->count[0] += len << 3) < (len << 3)) ctx->count[1]++;
	ctx->count[1] += (len >> 29);
	if ((j + len) > 63) {
		memcpy(&ctx->buffer[j], data, (i = 64 - j));
		SHA1_Transform(ctx->state, ctx->buffer);
		for (; i + 63 < len; i += 64)
			SHA1_Transform(ctx->state, &data[i]);
		j = 0;
	} else {
		i = 0;
	}
	memcpy(&ctx->buffer[j], &data[i], len - i);
}

static void SHA1_Final(unsigned char digest[20], SHA1_CTX *ctx)
{
	unsigned int i;
	unsigned char finalcount[8];
	for (i = 0; i < 8; i++)
		finalcount[i] = (unsigned char)((ctx->count[(i >= 4) ? 0 : 1] >>
			((3 - (i & 3)) * 8)) & 255);
	SHA1_Update(ctx, (const unsigned char *)"\200", 1);
	while ((ctx->count[0] & 504) != 448)
		SHA1_Update(ctx, (const unsigned char *)"\0", 1);
	SHA1_Update(ctx, finalcount, 8);
	for (i = 0; i < 20; i++)
		digest[i] = (unsigned char)((ctx->state[i >> 2] >> ((3 - (i & 3)) * 8)) & 255);
}

#define rol(value, bits) (((value) << (bits)) | ((value) >> (32 - (bits))))
#define blk0(i) (block->l[i] = (rol(block->l[i], 24) & 0xFF00FF00) | \
	(rol(block->l[i], 8) & 0x00FF00FF))
#define blk(i) (block->l[i & 15] = rol(block->l[(i + 13) & 15] ^ \
	block->l[(i + 8) & 15] ^ block->l[(i + 2) & 15] ^ block->l[i & 15], 1))

#define R0(v, w, x, y, z, i) z += ((w & (x ^ y)) ^ y) + blk0(i) + 0x5A827999 + rol(v, 5); w = rol(w, 30);
#define R1(v, w, x, y, z, i) z += ((w & (x ^ y)) ^ y) + blk(i) + 0x5A827999 + rol(v, 5); w = rol(w, 30);
#define R2(v, w, x, y, z, i) z += (w ^ x ^ y) + blk(i) + 0x6ED9EBA1 + rol(v, 5); w = rol(w, 30);
#define R3(v, w, x, y, z, i) z += (((w | x) & y) | (w & x)) + blk(i) + 0x8F1BBCDC + rol(v, 5); w = rol(w, 30);
#define R4(v, w, x, y, z, i) z += (w ^ x ^ y) + blk(i) + 0xCA62C1D6 + rol(v, 5); w = rol(w, 30);

static void SHA1_Transform(unsigned int state[5], const unsigned char buffer[64])
{
	typedef union {
		unsigned char c[64];
		unsigned int l[16];
	} CHAR64LONG16;
	CHAR64LONG16 block[1];
	memcpy(block, buffer, 64);
	unsigned int a = state[0], b = state[1], c = state[2], d = state[3], e = state[4];
	R0(a, b, c, d, e, 0); R0(e, a, b, c, d, 1); R0(d, e, a, b, c, 2); R0(c, d, e, a, b, 3);
	R0(b, c, d, e, a, 4); R0(a, b, c, d, e, 5); R0(e, a, b, c, d, 6); R0(d, e, a, b, c, 7);
	R0(c, d, e, a, b, 8); R0(b, c, d, e, a, 9); R0(a, b, c, d, e, 10); R0(e, a, b, c, d, 11);
	R0(d, e, a, b, c, 12); R0(c, d, e, a, b, 13); R0(b, c, d, e, a, 14); R0(a, b, c, d, e, 15);
	R1(e, a, b, c, d, 16); R1(d, e, a, b, c, 17); R1(c, d, e, a, b, 18); R1(b, c, d, e, a, 19);
	R2(a, b, c, d, e, 20); R2(e, a, b, c, d, 21); R2(d, e, a, b, c, 22); R2(c, d, e, a, b, 23);
	R2(b, c, d, e, a, 24); R2(a, b, c, d, e, 25); R2(e, a, b, c, d, 26); R2(d, e, a, b, c, 27);
	R2(c, d, e, a, b, 28); R2(b, c, d, e, a, 29); R2(a, b, c, d, e, 30); R2(e, a, b, c, d, 31);
	R2(d, e, a, b, c, 32); R2(c, d, e, a, b, 33); R2(b, c, d, e, a, 34); R2(a, b, c, d, e, 35);
	R2(e, a, b, c, d, 36); R2(d, e, a, b, c, 37); R2(c, d, e, a, b, 38); R2(b, c, d, e, a, 39);
	R3(a, b, c, d, e, 40); R3(e, a, b, c, d, 41); R3(d, e, a, b, c, 42); R3(c, d, e, a, b, 43);
	R3(b, c, d, e, a, 44); R3(a, b, c, d, e, 45); R3(e, a, b, c, d, 46); R3(d, e, a, b, c, 47);
	R3(c, d, e, a, b, 48); R3(b, c, d, e, a, 49); R3(a, b, c, d, e, 50); R3(e, a, b, c, d, 51);
	R3(d, e, a, b, c, 52); R3(c, d, e, a, b, 53); R3(b, c, d, e, a, 54); R3(a, b, c, d, e, 55);
	R3(e, a, b, c, d, 56); R3(d, e, a, b, c, 57); R3(c, d, e, a, b, 58); R3(b, c, d, e, a, 59);
	R4(a, b, c, d, e, 60); R4(e, a, b, c, d, 61); R4(d, e, a, b, c, 62); R4(c, d, e, a, b, 63);
	R4(b, c, d, e, a, 64); R4(a, b, c, d, e, 65); R4(e, a, b, c, d, 66); R4(d, e, a, b, c, 67);
	R4(c, d, e, a, b, 68); R4(b, c, d, e, a, 69); R4(a, b, c, d, e, 70); R4(e, a, b, c, d, 71);
	R4(d, e, a, b, c, 72); R4(c, d, e, a, b, 73); R4(b, c, d, e, a, 74); R4(a, b, c, d, e, 75);
	R4(e, a, b, c, d, 76); R4(d, e, a, b, c, 77); R4(c, d, e, a, b, 78); R4(b, c, d, e, a, 79);
	state[0] += a; state[1] += b; state[2] += c; state[3] += d; state[4] += e;
}

static void sha1_hex12(const unsigned char *data, size_t len, char out[FGIT_OID_HEX])
{
	SHA1_CTX ctx;
	unsigned char dig[20];
	int i;
	SHA1_Init(&ctx);
	SHA1_Update(&ctx, data, (unsigned int)len);
	SHA1_Final(dig, &ctx);
	for (i = 0; i < 6; i++)
		sprintf(out + i * 2, "%02x", dig[i]);
	out[FGIT_OID_LEN] = 0;
}

/* ======================== Path / IO helpers ================================ */

static int path_is_gitdir(const char *abs)
{
	return abs && (strncmp(abs, "/.git", 5) == 0) &&
		(abs[5] == 0 || abs[5] == '/');
}

static int component_ok(const char *name)
{
	size_t n;
	if (!name || !*name) return 0;
	if (strcmp(name, ".") == 0 || strcmp(name, "..") == 0) return 0;
	n = strlen(name);
	return n > 0 && n <= FGIT_NAME_MAX;
}

/* Normalize path relative to cwd into absolute path in out (size FGIT_PATH_MAX). */
static int normalize_path(FileFS *ffs, const char *path, char *out)
{
	char cwd[FGIT_PATH_MAX];
	char tmp[FGIT_PATH_MAX];
	char *parts[64];
	int nparts = 0;
	char *p, *save;
	size_t i;

	if (!path || !*path) return FGIT_BAD_ARG;

	if (path[0] == '/') {
		strncpy(tmp, path, FGIT_PATH_MAX - 1);
		tmp[FGIT_PATH_MAX - 1] = 0;
	} else {
		const char *g = FileFS_getcwd(ffs);
		if (!g) return FGIT_ERR;
		strncpy(cwd, g, FGIT_PATH_MAX - 1);
		cwd[FGIT_PATH_MAX - 1] = 0;
		if (strcmp(cwd, "/") == 0)
			snprintf(tmp, sizeof(tmp), "/%s", path);
		else
			snprintf(tmp, sizeof(tmp), "%s/%s", cwd, path);
	}

	/* Collapse . and .. */
	p = strtok_r(tmp, "/", &save);
	while (p) {
		if (strcmp(p, ".") == 0) {
			/* skip */
		} else if (strcmp(p, "..") == 0) {
			if (nparts > 0) nparts--;
		} else {
			if (!component_ok(p)) return FGIT_NAME_TOO_LONG;
			if (nparts >= 64) return FGIT_ERR;
			parts[nparts++] = p;
		}
		p = strtok_r(NULL, "/", &save);
	}

	out[0] = 0;
	if (nparts == 0) {
		strcpy(out, "/");
		return FGIT_OK;
	}
	for (i = 0; i < (size_t)nparts; i++) {
		size_t used = strlen(out);
		if (used + 1 + strlen(parts[i]) >= FGIT_PATH_MAX) return FGIT_ERR;
		strcat(out, "/");
		strcat(out, parts[i]);
	}
	return FGIT_OK;
}

static int read_all(FileFS *ffs, const char *path, unsigned char **data, size_t *len)
{
	FFS_FILE *fp;
	unsigned char *buf = NULL;
	size_t cap = 0, n = 0;
	unsigned char chunk[512];
	size_t r;

	*data = NULL;
	*len = 0;
	fp = FileFS_fopen(ffs, path, "r");
	if (!fp) return FGIT_NOT_FOUND;
	while (1) {
		r = FileFS_fread(ffs, chunk, 1, sizeof(chunk), fp);
		if (r == 0) break;
		if (n + r > cap) {
			size_t ncap = cap ? cap * 2 : 1024;
			unsigned char *nb;
			while (ncap < n + r) ncap *= 2;
			nb = (unsigned char *)realloc(buf, ncap);
			if (!nb) {
				free(buf);
				FileFS_fclose(ffs, fp);
				return FGIT_ERR;
			}
			buf = nb;
			cap = ncap;
		}
		memcpy(buf + n, chunk, r);
		n += r;
	}
	FileFS_fclose(ffs, fp);
	*data = buf ? buf : (unsigned char *)calloc(1, 1);
	*len = n;
	return *data ? FGIT_OK : FGIT_ERR;
}

static int write_all(FileFS *ffs, const char *path, const void *data, size_t len)
{
	FFS_FILE *fp = FileFS_fopen(ffs, path, "w");
	size_t w;
	if (!fp) return FGIT_ERR;
	if (len > 0) {
		w = FileFS_fwrite(ffs, data, 1, len, fp);
		if (w != len) {
			FileFS_fclose(ffs, fp);
			return FGIT_ERR;
		}
	}
	FileFS_fclose(ffs, fp);
	return FGIT_OK;
}

static int ensure_dir(FileFS *ffs, const char *path)
{
	int r;
	if (FileFS_dir_exist(ffs, path)) return FGIT_OK;
	r = FileFS_mkdir(ffs, path);
	if (r == 0 || r == 3) return FGIT_OK;
	return FGIT_ERR;
}

static int mkdir_p_leaf(FileFS *ffs, const char *abs_dir)
{
	/* Create each component under / for abs_dir like /a/b/c */
	char tmp[FGIT_PATH_MAX];
	char built[FGIT_PATH_MAX];
	char *p, *save;

	if (!abs_dir || abs_dir[0] != '/') return FGIT_BAD_ARG;
	strncpy(tmp, abs_dir, sizeof(tmp) - 1);
	tmp[sizeof(tmp) - 1] = 0;
	built[0] = 0;
	p = strtok_r(tmp, "/", &save);
	while (p) {
		if (!component_ok(p)) return FGIT_NAME_TOO_LONG;
		strcat(built, "/");
		strcat(built, p);
		if (ensure_dir(ffs, built) != FGIT_OK) return FGIT_ERR;
		p = strtok_r(NULL, "/", &save);
	}
	return FGIT_OK;
}

/* Ensure parent directories of an absolute file path exist. */
static int ensure_parent_dirs(FileFS *ffs, const char *abs_file)
{
	char parent[FGIT_PATH_MAX];
	char *slash;
	strncpy(parent, abs_file, sizeof(parent) - 1);
	parent[sizeof(parent) - 1] = 0;
	slash = strrchr(parent, '/');
	if (!slash || slash == parent) return FGIT_OK; /* under root */
	*slash = 0;
	return mkdir_p_leaf(ffs, parent);
}

/* ======================== Index ================================================= */

typedef struct {
	char path[FGIT_PATH_MAX];
	char oid[FGIT_OID_HEX];
	size_t size;
} IdxEntry;

typedef struct {
	IdxEntry *items;
	int count;
	int cap;
} Index;

static void index_free(Index *idx)
{
	free(idx->items);
	idx->items = NULL;
	idx->count = idx->cap = 0;
}

static int index_grow(Index *idx)
{
	int ncap = idx->cap ? idx->cap * 2 : 16;
	IdxEntry *n = (IdxEntry *)realloc(idx->items, (size_t)ncap * sizeof(IdxEntry));
	if (!n) return FGIT_ERR;
	idx->items = n;
	idx->cap = ncap;
	return FGIT_OK;
}

static int index_find(Index *idx, const char *path)
{
	int i;
	for (i = 0; i < idx->count; i++)
		if (strcmp(idx->items[i].path, path) == 0) return i;
	return -1;
}

static int index_set(Index *idx, const char *path, const char *oid, size_t size)
{
	int i = index_find(idx, path);
	if (i < 0) {
		if (idx->count >= idx->cap && index_grow(idx) != FGIT_OK) return FGIT_ERR;
		i = idx->count++;
		strncpy(idx->items[i].path, path, FGIT_PATH_MAX - 1);
		idx->items[i].path[FGIT_PATH_MAX - 1] = 0;
	}
	strncpy(idx->items[i].oid, oid, FGIT_OID_LEN);
	idx->items[i].oid[FGIT_OID_LEN] = 0;
	idx->items[i].size = size;
	return FGIT_OK;
}

static void index_remove_at(Index *idx, int i)
{
	if (i < 0 || i >= idx->count) return;
	memmove(&idx->items[i], &idx->items[i + 1],
		(size_t)(idx->count - i - 1) * sizeof(IdxEntry));
	idx->count--;
}

static int index_load(FileFS *ffs, Index *idx)
{
	unsigned char *data = NULL;
	size_t len = 0;
	char *text, *line, *save;
	int rc;

	memset(idx, 0, sizeof(*idx));
	if (!FileFS_file_exist(ffs, FGIT_IDX)) return FGIT_OK;
	rc = read_all(ffs, FGIT_IDX, &data, &len);
	if (rc != FGIT_OK) return rc;
	text = (char *)malloc(len + 1);
	if (!text) {
		free(data);
		return FGIT_ERR;
	}
	memcpy(text, data, len);
	text[len] = 0;
	free(data);

	line = strtok_r(text, "\n", &save);
	if (!line || strncmp(line, "FGITIDX1", 8) != 0) {
		free(text);
		return FGIT_ERR;
	}
	while ((line = strtok_r(NULL, "\n", &save)) != NULL) {
		char path[FGIT_PATH_MAX], oid[FGIT_OID_HEX];
		unsigned long size = 0;
		if (line[0] == 0 || line[0] == '#') continue;
		if (sscanf(line, "%511s %12s %lu", path, oid, &size) != 3) continue;
		if (index_set(idx, path, oid, (size_t)size) != FGIT_OK) {
			free(text);
			index_free(idx);
			return FGIT_ERR;
		}
	}
	free(text);
	return FGIT_OK;
}

static int index_save(FileFS *ffs, Index *idx)
{
	char *buf;
	size_t cap = 64 + (size_t)idx->count * (FGIT_PATH_MAX + 32);
	size_t used = 0;
	int i;

	buf = (char *)malloc(cap);
	if (!buf) return FGIT_ERR;
	used = (size_t)snprintf(buf, cap, "%s", FGIT_IDX_MAGIC);
	for (i = 0; i < idx->count; i++) {
		int n = snprintf(buf + used, cap - used, "%s %s %lu\n",
			idx->items[i].path, idx->items[i].oid,
			(unsigned long)idx->items[i].size);
		if (n < 0 || (size_t)n >= cap - used) {
			free(buf);
			return FGIT_ERR;
		}
		used += (size_t)n;
	}
	i = write_all(ffs, FGIT_IDX, buf, used);
	free(buf);
	return i;
}

/* ======================== Objects / refs =================================== */

static int obj_path(const char *oid, char *out)
{
	if (!oid || strlen(oid) != FGIT_OID_LEN) return FGIT_BAD_ARG;
	snprintf(out, FGIT_PATH_MAX, "%s/%s", FGIT_OBJS, oid);
	return FGIT_OK;
}

static int store_object(FileFS *ffs, const char *type, const void *payload,
	size_t payload_len, char oid_out[FGIT_OID_HEX])
{
	char header[64];
	int hlen;
	size_t total;
	unsigned char *buf;
	char path[FGIT_PATH_MAX];
	int rc;

	hlen = snprintf(header, sizeof(header), "%s %lu", type, (unsigned long)payload_len);
	if (hlen < 0 || (size_t)hlen >= sizeof(header)) return FGIT_ERR;
	total = (size_t)hlen + 1 + payload_len;
	buf = (unsigned char *)malloc(total);
	if (!buf) return FGIT_ERR;
	memcpy(buf, header, (size_t)hlen);
	buf[hlen] = 0;
	if (payload_len)
		memcpy(buf + hlen + 1, payload, payload_len);

	sha1_hex12(buf, total, oid_out);
	if (obj_path(oid_out, path) != FGIT_OK) {
		free(buf);
		return FGIT_ERR;
	}
	if (!FileFS_file_exist(ffs, path)) {
		rc = write_all(ffs, path, buf, total);
		if (rc != FGIT_OK) {
			free(buf);
			return rc;
		}
	}
	free(buf);
	return FGIT_OK;
}

static int load_object(FileFS *ffs, const char *oid, char *type_out, size_t type_sz,
	unsigned char **payload, size_t *payload_len)
{
	char path[FGIT_PATH_MAX];
	unsigned char *data = NULL;
	size_t len = 0;
	size_t i;
	int rc;

	*payload = NULL;
	*payload_len = 0;
	if (type_out && type_sz) type_out[0] = 0;
	if (obj_path(oid, path) != FGIT_OK) return FGIT_BAD_ARG;
	rc = read_all(ffs, path, &data, &len);
	if (rc != FGIT_OK) return rc;
	/* header: type SP size \0 */
	for (i = 0; i < len; i++) {
		if (data[i] == 0) break;
	}
	if (i >= len) {
		free(data);
		return FGIT_ERR;
	}
	{
		char type[32];
		unsigned long sz = 0;
		if (sscanf((char *)data, "%31s %lu", type, &sz) != 2) {
			free(data);
			return FGIT_ERR;
		}
		if (type_out) {
			strncpy(type_out, type, type_sz - 1);
			type_out[type_sz - 1] = 0;
		}
		if (i + 1 + sz > len) {
			free(data);
			return FGIT_ERR;
		}
		*payload_len = (size_t)sz;
		*payload = (unsigned char *)malloc(sz ? sz : 1);
		if (!*payload) {
			free(data);
			return FGIT_ERR;
		}
		if (sz) memcpy(*payload, data + i + 1, sz);
	}
	free(data);
	return FGIT_OK;
}

static int write_ref(FileFS *ffs, const char *refpath, const char *oid)
{
	char line[64];
	int n = snprintf(line, sizeof(line), "%s\n", oid);
	return write_all(ffs, refpath, line, (size_t)n);
}

static int read_ref_file(FileFS *ffs, const char *refpath, char oid[FGIT_OID_HEX])
{
	unsigned char *data = NULL;
	size_t len = 0;
	size_t i;
	int rc = read_all(ffs, refpath, &data, &len);
	if (rc != FGIT_OK) return rc;
	i = 0;
	while (i < len && i < FGIT_OID_LEN && isxdigit(data[i])) {
		oid[i] = (char)tolower(data[i]);
		i++;
	}
	oid[i] = 0;
	free(data);
	if (i != FGIT_OID_LEN) return FGIT_ERR;
	return FGIT_OK;
}

static int resolve_head(FileFS *ffs, char oid[FGIT_OID_HEX], char *branch_out, size_t branch_sz)
{
	unsigned char *data = NULL;
	size_t len = 0;
	char buf[FGIT_PATH_MAX];
	int rc;

	oid[0] = 0;
	if (branch_out && branch_sz) branch_out[0] = 0;
	if (!FileFS_file_exist(ffs, FGIT_HEAD)) return FGIT_NOT_REPO;
	rc = read_all(ffs, FGIT_HEAD, &data, &len);
	if (rc != FGIT_OK) return rc;
	memcpy(buf, data, len < sizeof(buf) - 1 ? len : sizeof(buf) - 1);
	buf[len < sizeof(buf) - 1 ? len : sizeof(buf) - 1] = 0;
	free(data);
	/* trim */
	{
		char *nl = strchr(buf, '\n');
		if (nl) *nl = 0;
	}
	if (strncmp(buf, "ref: ", 5) == 0) {
		char *ref = buf + 5;
		char path[FGIT_PATH_MAX];
		const char *name;
		snprintf(path, sizeof(path), "/.git/%s", ref);
		name = strrchr(ref, '/');
		name = name ? name + 1 : ref;
		if (branch_out && branch_sz) {
			strncpy(branch_out, name, branch_sz - 1);
			branch_out[branch_sz - 1] = 0;
		}
		if (!FileFS_file_exist(ffs, path)) {
			oid[0] = 0; /* unborn branch */
			return FGIT_OK;
		}
		return read_ref_file(ffs, path, oid);
	}
	if (strlen(buf) == FGIT_OID_LEN) {
		strncpy(oid, buf, FGIT_OID_LEN);
		oid[FGIT_OID_LEN] = 0;
		return FGIT_OK;
	}
	return FGIT_ERR;
}

static int update_current_ref(FileFS *ffs, const char *oid)
{
	unsigned char *data = NULL;
	size_t len = 0;
	char buf[FGIT_PATH_MAX];
	int rc;

	rc = read_all(ffs, FGIT_HEAD, &data, &len);
	if (rc != FGIT_OK) return rc;
	memcpy(buf, data, len < sizeof(buf) - 1 ? len : sizeof(buf) - 1);
	buf[len < sizeof(buf) - 1 ? len : sizeof(buf) - 1] = 0;
	free(data);
	{
		char *nl = strchr(buf, '\n');
		if (nl) *nl = 0;
	}
	if (strncmp(buf, "ref: ", 5) == 0) {
		char path[FGIT_PATH_MAX];
		snprintf(path, sizeof(path), "/.git/%s", buf + 5);
		return write_ref(ffs, path, oid);
	}
	return write_ref(ffs, FGIT_HEAD, oid);
}

/* ======================== Tree build / parse =============================== */

typedef struct {
	char mode[8]; /* "100644" or "040000" */
	char name[FGIT_NAME_MAX + 1];
	char oid[FGIT_OID_HEX];
} TreeEnt;

typedef struct {
	TreeEnt *items;
	int count;
	int cap;
} TreeList;

static void tree_free(TreeList *t)
{
	free(t->items);
	t->items = NULL;
	t->count = t->cap = 0;
}

static int tree_add(TreeList *t, const char *mode, const char *name, const char *oid)
{
	if (t->count >= t->cap) {
		int ncap = t->cap ? t->cap * 2 : 8;
		TreeEnt *n = (TreeEnt *)realloc(t->items, (size_t)ncap * sizeof(TreeEnt));
		if (!n) return FGIT_ERR;
		t->items = n;
		t->cap = ncap;
	}
	strncpy(t->items[t->count].mode, mode, sizeof(t->items[t->count].mode) - 1);
	t->items[t->count].mode[sizeof(t->items[t->count].mode) - 1] = 0;
	strncpy(t->items[t->count].name, name, FGIT_NAME_MAX);
	t->items[t->count].name[FGIT_NAME_MAX] = 0;
	strncpy(t->items[t->count].oid, oid, FGIT_OID_LEN);
	t->items[t->count].oid[FGIT_OID_LEN] = 0;
	t->count++;
	return FGIT_OK;
}

static int tree_cmp(const void *a, const void *b)
{
	const TreeEnt *ea = (const TreeEnt *)a;
	const TreeEnt *eb = (const TreeEnt *)b;
	return strcmp(ea->name, eb->name);
}

static int tree_serialize_store(FileFS *ffs, TreeList *t, char oid_out[FGIT_OID_HEX])
{
	char *payload;
	size_t cap, used = 0;
	int i;

	qsort(t->items, (size_t)t->count, sizeof(TreeEnt), tree_cmp);
	cap = (size_t)t->count * 64 + 8;
	payload = (char *)malloc(cap);
	if (!payload) return FGIT_ERR;
	for (i = 0; i < t->count; i++) {
		int n = snprintf(payload + used, cap - used, "%s %s %s\n",
			t->items[i].mode, t->items[i].oid, t->items[i].name);
		if (n < 0 || (size_t)n >= cap - used) {
			free(payload);
			return FGIT_ERR;
		}
		used += (size_t)n;
	}
	i = store_object(ffs, "tree", payload, used, oid_out);
	free(payload);
	return i;
}

static int tree_parse(const unsigned char *payload, size_t len, TreeList *t)
{
	char *text, *line, *save;
	memset(t, 0, sizeof(*t));
	text = (char *)malloc(len + 1);
	if (!text) return FGIT_ERR;
	memcpy(text, payload, len);
	text[len] = 0;
	line = strtok_r(text, "\n", &save);
	while (line) {
		char mode[8], oid[FGIT_OID_HEX], name[FGIT_NAME_MAX + 1];
		if (sscanf(line, "%7s %12s %14s", mode, oid, name) == 3) {
			if (tree_add(t, mode, name, oid) != FGIT_OK) {
				free(text);
				tree_free(t);
				return FGIT_ERR;
			}
		}
		line = strtok_r(NULL, "\n", &save);
	}
	free(text);
	return FGIT_OK;
}

/* Build tree OID from flat index paths (absolute paths starting with /). */
static int build_tree_from_index(FileFS *ffs, Index *idx, const char *prefix,
	char oid_out[FGIT_OID_HEX])
{
	/* Collect unique child names under prefix */
	TreeList tree;
	int i, rc;
	size_t plen = strlen(prefix);

	memset(&tree, 0, sizeof(tree));
	oid_out[0] = 0;

	for (i = 0; i < idx->count; i++) {
		const char *path = idx->items[i].path;
		const char *rest;
		char name[FGIT_NAME_MAX + 1];
		const char *slash;
		int is_dir;
		int j, exists;

		if (plen == 1 && prefix[0] == '/') {
			if (path[0] != '/') continue;
			rest = path + 1;
		} else {
			if (strncmp(path, prefix, plen) != 0) continue;
			if (path[plen] != '/') continue;
			rest = path + plen + 1;
		}
		if (!*rest) continue;
		slash = strchr(rest, '/');
		is_dir = slash != NULL;
		if (is_dir) {
			size_t nlen = (size_t)(slash - rest);
			if (nlen == 0 || nlen > FGIT_NAME_MAX) continue;
			memcpy(name, rest, nlen);
			name[nlen] = 0;
		} else {
			strncpy(name, rest, FGIT_NAME_MAX);
			name[FGIT_NAME_MAX] = 0;
		}

		exists = 0;
		for (j = 0; j < tree.count; j++) {
			if (strcmp(tree.items[j].name, name) == 0) {
				exists = 1;
				break;
			}
		}
		if (exists) continue;

		if (is_dir) {
			char child_prefix[FGIT_PATH_MAX];
			char child_oid[FGIT_OID_HEX];
			if (plen == 1 && prefix[0] == '/')
				snprintf(child_prefix, sizeof(child_prefix), "/%s", name);
			else
				snprintf(child_prefix, sizeof(child_prefix), "%s/%s", prefix, name);
			rc = build_tree_from_index(ffs, idx, child_prefix, child_oid);
			if (rc != FGIT_OK) {
				tree_free(&tree);
				return rc;
			}
			if (tree_add(&tree, "040000", name, child_oid) != FGIT_OK) {
				tree_free(&tree);
				return FGIT_ERR;
			}
		} else {
			if (tree_add(&tree, "100644", name, idx->items[i].oid) != FGIT_OK) {
				tree_free(&tree);
				return FGIT_ERR;
			}
		}
	}

	if (tree.count == 0 && !(plen == 1 && prefix[0] == '/')) {
		tree_free(&tree);
		return FGIT_EMPTY;
	}
	rc = tree_serialize_store(ffs, &tree, oid_out);
	tree_free(&tree);
	return rc;
}

/* Flatten tree OID into Index-like entries with absolute paths. */
static int flatten_tree(FileFS *ffs, const char *tree_oid, const char *prefix, Index *out)
{
	unsigned char *payload = NULL;
	size_t plen = 0;
	char type[16];
	TreeList tree;
	int i, rc;

	rc = load_object(ffs, tree_oid, type, sizeof(type), &payload, &plen);
	if (rc != FGIT_OK) return rc;
	if (strcmp(type, "tree") != 0) {
		free(payload);
		return FGIT_ERR;
	}
	rc = tree_parse(payload, plen, &tree);
	free(payload);
	if (rc != FGIT_OK) return rc;

	for (i = 0; i < tree.count; i++) {
		char child_path[FGIT_PATH_MAX];
		if (strcmp(prefix, "/") == 0)
			snprintf(child_path, sizeof(child_path), "/%s", tree.items[i].name);
		else
			snprintf(child_path, sizeof(child_path), "%s/%s", prefix, tree.items[i].name);

		if (strcmp(tree.items[i].mode, "040000") == 0) {
			rc = flatten_tree(ffs, tree.items[i].oid, child_path, out);
			if (rc != FGIT_OK) {
				tree_free(&tree);
				return rc;
			}
		} else {
			if (index_set(out, child_path, tree.items[i].oid, 0) != FGIT_OK) {
				tree_free(&tree);
				return FGIT_ERR;
			}
		}
	}
	tree_free(&tree);
	return FGIT_OK;
}

static int commit_tree_oid(FileFS *ffs, const char *commit_oid, char tree_oid[FGIT_OID_HEX])
{
	unsigned char *payload = NULL;
	size_t len = 0;
	char type[16];
	char *text, *line, *save;
	int rc;

	tree_oid[0] = 0;
	rc = load_object(ffs, commit_oid, type, sizeof(type), &payload, &len);
	if (rc != FGIT_OK) return rc;
	if (strcmp(type, "commit") != 0) {
		free(payload);
		return FGIT_ERR;
	}
	text = (char *)malloc(len + 1);
	if (!text) {
		free(payload);
		return FGIT_ERR;
	}
	memcpy(text, payload, len);
	text[len] = 0;
	free(payload);
	line = strtok_r(text, "\n", &save);
	while (line) {
		if (strncmp(line, "tree ", 5) == 0) {
			strncpy(tree_oid, line + 5, FGIT_OID_LEN);
			tree_oid[FGIT_OID_LEN] = 0;
			free(text);
			return FGIT_OK;
		}
		if (line[0] == 0) break;
		line = strtok_r(NULL, "\n", &save);
	}
	free(text);
	return FGIT_ERR;
}

/* ======================== Public API ======================================= */

int FileGit_is_repo(FileFS *ffs)
{
	return ffs && FileFS_ismount(ffs) && FileFS_dir_exist(ffs, FGIT_ROOT) &&
		FileFS_file_exist(ffs, FGIT_HEAD);
}

int FileGit_init(FileFS *ffs)
{
	const char *head_content = "ref: refs/heads/main\n";
	const char *cfg =
		"version=1\n"
		"oid_len=12\n"
		"author=FileGit <filegit@filefs>\n";

	if (!ffs || !FileFS_ismount(ffs)) return FGIT_ERR;
	if (FileGit_is_repo(ffs)) return FGIT_EXISTS;

	if (ensure_dir(ffs, FGIT_ROOT) != FGIT_OK) return FGIT_ERR;
	if (ensure_dir(ffs, FGIT_OBJS) != FGIT_OK) return FGIT_ERR;
	if (ensure_dir(ffs, FGIT_REFS) != FGIT_OK) return FGIT_ERR;
	if (ensure_dir(ffs, FGIT_HEADS) != FGIT_OK) return FGIT_ERR;

	if (write_all(ffs, FGIT_HEAD, head_content, strlen(head_content)) != FGIT_OK)
		return FGIT_ERR;
	if (write_all(ffs, FGIT_CFG, cfg, strlen(cfg)) != FGIT_OK)
		return FGIT_ERR;
	if (write_all(ffs, FGIT_IDX, FGIT_IDX_MAGIC, strlen(FGIT_IDX_MAGIC)) != FGIT_OK)
		return FGIT_ERR;

	printf("Initialized empty FileGit repository in /.git/\n");
	return FGIT_OK;
}

int FileGit_add(FileFS *ffs, const char *path)
{
	char abs[FGIT_PATH_MAX];
	unsigned char *data = NULL;
	size_t len = 0;
	char oid[FGIT_OID_HEX];
	Index idx;
	int rc;

	if (!FileGit_is_repo(ffs)) return FGIT_NOT_REPO;
	rc = normalize_path(ffs, path, abs);
	if (rc != FGIT_OK) return rc;
	if (path_is_gitdir(abs)) {
		printf("ERR: refuse to add repository metadata path\n");
		return FGIT_BAD_ARG;
	}
	if (!FileFS_file_exist(ffs, abs)) return FGIT_NOT_FOUND;

	rc = read_all(ffs, abs, &data, &len);
	if (rc != FGIT_OK) return rc;
	rc = store_object(ffs, "blob", data, len, oid);
	free(data);
	if (rc != FGIT_OK) return rc;

	memset(&idx, 0, sizeof(idx));
	rc = index_load(ffs, &idx);
	if (rc != FGIT_OK) return rc;
	rc = index_set(&idx, abs, oid, len);
	if (rc == FGIT_OK) rc = index_save(ffs, &idx);
	index_free(&idx);
	if (rc == FGIT_OK)
		printf("add %s (%s)\n", abs, oid);
	return rc;
}

int FileGit_rm(FileFS *ffs, const char *path)
{
	char abs[FGIT_PATH_MAX];
	Index idx;
	int rc, i;

	if (!FileGit_is_repo(ffs)) return FGIT_NOT_REPO;
	rc = normalize_path(ffs, path, abs);
	if (rc != FGIT_OK) return rc;
	memset(&idx, 0, sizeof(idx));
	rc = index_load(ffs, &idx);
	if (rc != FGIT_OK) return rc;
	i = index_find(&idx, abs);
	if (i < 0) {
		index_free(&idx);
		return FGIT_NOT_FOUND;
	}
	index_remove_at(&idx, i);
	rc = index_save(ffs, &idx);
	index_free(&idx);
	if (rc == FGIT_OK) printf("rm (index) %s\n", abs);
	return rc;
}

int FileGit_commit(FileFS *ffs, const char *message)
{
	Index idx;
	char tree_oid[FGIT_OID_HEX], parent[FGIT_OID_HEX], commit_oid[FGIT_OID_HEX];
	char branch[FGIT_NAME_MAX + 1];
	char *payload;
	size_t cap, used;
	time_t now;
	int rc;

	if (!FileGit_is_repo(ffs)) return FGIT_NOT_REPO;
	if (!message || !*message) return FGIT_BAD_ARG;

	memset(&idx, 0, sizeof(idx));
	rc = index_load(ffs, &idx);
	if (rc != FGIT_OK) return rc;
	if (idx.count == 0) {
		index_free(&idx);
		printf("nothing to commit (index empty)\n");
		return FGIT_EMPTY;
	}

	rc = build_tree_from_index(ffs, &idx, "/", tree_oid);
	index_free(&idx);
	if (rc != FGIT_OK) return rc;

	parent[0] = 0;
	branch[0] = 0;
	rc = resolve_head(ffs, parent, branch, sizeof(branch));
	if (rc != FGIT_OK) return rc;

	now = time(NULL);
	cap = strlen(message) + 256;
	payload = (char *)malloc(cap);
	if (!payload) return FGIT_ERR;
	used = (size_t)snprintf(payload, cap, "tree %s\n", tree_oid);
	if (parent[0])
		used += (size_t)snprintf(payload + used, cap - used, "parent %s\n", parent);
	used += (size_t)snprintf(payload + used, cap - used,
		"author FileGit <filegit@filefs> %ld +0000\n"
		"committer FileGit <filegit@filefs> %ld +0000\n"
		"\n"
		"%s\n",
		(long)now, (long)now, message);

	rc = store_object(ffs, "commit", payload, used, commit_oid);
	free(payload);
	if (rc != FGIT_OK) return rc;

	rc = update_current_ref(ffs, commit_oid);
	if (rc != FGIT_OK) return rc;
	printf("[%s %s] %s\n", branch[0] ? branch : "detached", commit_oid, message);
	return FGIT_OK;
}

/* Collect working-tree files (absolute paths), skip /.git. */
static int collect_work_files(FileFS *ffs, const char *dir, Index *out)
{
	FFS_DIR *dp;
	FFS_dirent *ent;
	char *abs_shown = NULL;

	dp = FileFS_opendir(ffs, dir, &abs_shown);
	if (!dp) return FGIT_ERR;
	while ((ent = FileFS_readdir(ffs, dp)) != NULL) {
		char child[FGIT_PATH_MAX];
		if (strcmp(ent->d_name, ".") == 0 || strcmp(ent->d_name, "..") == 0)
			continue;
		if (strcmp(dir, "/") == 0)
			snprintf(child, sizeof(child), "/%s", ent->d_name);
		else
			snprintf(child, sizeof(child), "%s/%s", dir, ent->d_name);
		if (path_is_gitdir(child)) continue;

		if (ent->d_type == FFS_DT_DIR) {
			if (collect_work_files(ffs, child, out) != FGIT_OK) {
				FileFS_closedir(ffs, dp);
				return FGIT_ERR;
			}
		} else if (ent->d_type == FFS_DT_FILE) {
			if (index_set(out, child, "-", 0) != FGIT_OK) {
				FileFS_closedir(ffs, dp);
				return FGIT_ERR;
			}
		}
	}
	FileFS_closedir(ffs, dp);
	return FGIT_OK;
}

static int blob_oid_of_file(FileFS *ffs, const char *path, char oid[FGIT_OID_HEX])
{
	unsigned char *data = NULL;
	size_t len = 0;
	char header[64];
	int hlen;
	size_t total;
	unsigned char *buf;
	int rc;

	rc = read_all(ffs, path, &data, &len);
	if (rc != FGIT_OK) return rc;
	hlen = snprintf(header, sizeof(header), "blob %lu", (unsigned long)len);
	total = (size_t)hlen + 1 + len;
	buf = (unsigned char *)malloc(total);
	if (!buf) {
		free(data);
		return FGIT_ERR;
	}
	memcpy(buf, header, (size_t)hlen);
	buf[hlen] = 0;
	if (len) memcpy(buf + hlen + 1, data, len);
	free(data);
	sha1_hex12(buf, total, oid);
	free(buf);
	return FGIT_OK;
}

int FileGit_status(FileFS *ffs)
{
	Index idx, head, work;
	char head_oid[FGIT_OID_HEX], tree_oid[FGIT_OID_HEX], branch[FGIT_NAME_MAX + 1];
	int i, rc;
	int staged = 0, modified = 0, untracked = 0;

	if (!FileGit_is_repo(ffs)) return FGIT_NOT_REPO;

	branch[0] = 0;
	head_oid[0] = 0;
	rc = resolve_head(ffs, head_oid, branch, sizeof(branch));
	if (rc != FGIT_OK) return rc;

	printf("On branch %s\n", branch[0] ? branch : "(detached)");
	if (!head_oid[0])
		printf("No commits yet\n");

	memset(&idx, 0, sizeof(idx));
	memset(&head, 0, sizeof(head));
	memset(&work, 0, sizeof(work));

	rc = index_load(ffs, &idx);
	if (rc != FGIT_OK) return rc;

	if (head_oid[0]) {
		rc = commit_tree_oid(ffs, head_oid, tree_oid);
		if (rc == FGIT_OK)
			rc = flatten_tree(ffs, tree_oid, "/", &head);
		if (rc != FGIT_OK) {
			index_free(&idx);
			return rc;
		}
	}

	rc = collect_work_files(ffs, "/", &work);
	if (rc != FGIT_OK) {
		index_free(&idx);
		index_free(&head);
		return rc;
	}

	printf("\nChanges to be committed:\n");
	for (i = 0; i < idx.count; i++) {
		int hi = index_find(&head, idx.items[i].path);
		if (hi < 0) {
			printf("  new file:   %s\n", idx.items[i].path);
			staged++;
		} else if (strcmp(head.items[hi].oid, idx.items[i].oid) != 0) {
			printf("  modified:   %s\n", idx.items[i].path);
			staged++;
		}
	}
	for (i = 0; i < head.count; i++) {
		if (index_find(&idx, head.items[i].path) < 0) {
			printf("  deleted:    %s\n", head.items[i].path);
			staged++;
		}
	}
	if (!staged) printf("  (none)\n");

	printf("\nChanges not staged for commit:\n");
	for (i = 0; i < idx.count; i++) {
		char woid[FGIT_OID_HEX];
		if (!FileFS_file_exist(ffs, idx.items[i].path)) {
			printf("  deleted:    %s\n", idx.items[i].path);
			modified++;
			continue;
		}
		if (blob_oid_of_file(ffs, idx.items[i].path, woid) != FGIT_OK) continue;
		if (strcmp(woid, idx.items[i].oid) != 0) {
			printf("  modified:   %s\n", idx.items[i].path);
			modified++;
		}
	}
	if (!modified) printf("  (none)\n");

	printf("\nUntracked files:\n");
	for (i = 0; i < work.count; i++) {
		if (index_find(&idx, work.items[i].path) < 0 &&
			index_find(&head, work.items[i].path) < 0) {
			printf("  %s\n", work.items[i].path);
			untracked++;
		}
	}
	if (!untracked) printf("  (none)\n");

	index_free(&idx);
	index_free(&head);
	index_free(&work);
	return FGIT_OK;
}

int FileGit_log(FileFS *ffs, int max_count)
{
	char oid[FGIT_OID_HEX], branch[FGIT_NAME_MAX + 1];
	int n = 0, rc;

	if (!FileGit_is_repo(ffs)) return FGIT_NOT_REPO;
	if (max_count <= 0) max_count = 20;

	rc = resolve_head(ffs, oid, branch, sizeof(branch));
	if (rc != FGIT_OK) return rc;
	if (!oid[0]) {
		printf("No commits yet\n");
		return FGIT_OK;
	}

	while (oid[0] && n < max_count) {
		unsigned char *payload = NULL;
		size_t len = 0;
		char type[16];
		char parent[FGIT_OID_HEX];
		char *text, *line, *save;
		const char *msg = NULL;

		rc = load_object(ffs, oid, type, sizeof(type), &payload, &len);
		if (rc != FGIT_OK) return rc;
		if (strcmp(type, "commit") != 0) {
			free(payload);
			return FGIT_ERR;
		}
		text = (char *)malloc(len + 1);
		if (!text) {
			free(payload);
			return FGIT_ERR;
		}
		memcpy(text, payload, len);
		text[len] = 0;
		free(payload);

		parent[0] = 0;
		line = strtok_r(text, "\n", &save);
		while (line) {
			if (strncmp(line, "parent ", 7) == 0) {
				strncpy(parent, line + 7, FGIT_OID_LEN);
				parent[FGIT_OID_LEN] = 0;
			} else if (line[0] == 0) {
				msg = strtok_r(NULL, "\n", &save);
				break;
			}
			line = strtok_r(NULL, "\n", &save);
		}
		printf("commit %s\n", oid);
		if (msg) printf("    %s\n\n", msg);
		else printf("\n");
		free(text);
		strncpy(oid, parent, FGIT_OID_HEX);
		n++;
	}
	return FGIT_OK;
}

int FileGit_cat_file(FileFS *ffs, const char *oid)
{
	unsigned char *payload = NULL;
	size_t len = 0;
	char type[16];
	int rc;

	if (!FileGit_is_repo(ffs)) return FGIT_NOT_REPO;
	if (!oid || strlen(oid) != FGIT_OID_LEN) return FGIT_BAD_ARG;
	rc = load_object(ffs, oid, type, sizeof(type), &payload, &len);
	if (rc != FGIT_OK) return rc;
	printf("type: %s\nsize: %lu\n", type, (unsigned long)len);
	fwrite(payload, 1, len, stdout);
	if (len == 0 || payload[len - 1] != '\n') printf("\n");
	free(payload);
	return FGIT_OK;
}

int FileGit_show(FileFS *ffs, const char *rev)
{
	char oid[FGIT_OID_HEX], tree[FGIT_OID_HEX];
	char type[16];
	unsigned char *payload = NULL;
	size_t len = 0;
	int rc;

	if (!FileGit_is_repo(ffs)) return FGIT_NOT_REPO;
	if (!rev || !*rev) return FGIT_BAD_ARG;

	if (strlen(rev) == FGIT_OID_LEN && strspn(rev, "0123456789abcdef") == FGIT_OID_LEN) {
		strncpy(oid, rev, FGIT_OID_HEX);
	} else {
		/* treat as branch */
		char path[FGIT_PATH_MAX];
		if (!component_ok(rev)) return FGIT_NAME_TOO_LONG;
		snprintf(path, sizeof(path), "%s/%s", FGIT_HEADS, rev);
		rc = read_ref_file(ffs, path, oid);
		if (rc != FGIT_OK) return rc;
	}

	rc = load_object(ffs, oid, type, sizeof(type), &payload, &len);
	if (rc != FGIT_OK) return rc;

	if (strcmp(type, "commit") == 0) {
		fwrite(payload, 1, len, stdout);
		if (len == 0 || payload[len - 1] != '\n') printf("\n");
		free(payload);
		if (commit_tree_oid(ffs, oid, tree) == FGIT_OK) {
			Index flat;
			int i;
			memset(&flat, 0, sizeof(flat));
			if (flatten_tree(ffs, tree, "/", &flat) == FGIT_OK) {
				printf("---- tree ----\n");
				for (i = 0; i < flat.count; i++)
					printf("%s %s\n", flat.items[i].oid, flat.items[i].path);
				index_free(&flat);
			}
		}
		return FGIT_OK;
	}
	printf("type: %s\n", type);
	fwrite(payload, 1, len, stdout);
	printf("\n");
	free(payload);
	return FGIT_OK;
}

int FileGit_branch(FileFS *ffs, const char *name)
{
	char head_oid[FGIT_OID_HEX], cur[FGIT_NAME_MAX + 1];
	int rc;

	if (!FileGit_is_repo(ffs)) return FGIT_NOT_REPO;

	if (!name || !*name) {
		/* list */
		FFS_DIR *dp;
		FFS_dirent *ent;
		char *shown = NULL;
		rc = resolve_head(ffs, head_oid, cur, sizeof(cur));
		if (rc != FGIT_OK) return rc;
		dp = FileFS_opendir(ffs, FGIT_HEADS, &shown);
		if (!dp) {
			printf("(no branches)\n");
			return FGIT_OK;
		}
		while ((ent = FileFS_readdir(ffs, dp)) != NULL) {
			if (ent->d_type != FFS_DT_FILE) continue;
			if (strcmp(ent->d_name, ".") == 0 || strcmp(ent->d_name, "..") == 0)
				continue;
			printf("%s %s\n", (cur[0] && strcmp(cur, ent->d_name) == 0) ? "*" : " ",
				ent->d_name);
		}
		FileFS_closedir(ffs, dp);
		return FGIT_OK;
	}

	if (!component_ok(name)) return FGIT_NAME_TOO_LONG;
	rc = resolve_head(ffs, head_oid, cur, sizeof(cur));
	if (rc != FGIT_OK) return rc;
	if (!head_oid[0]) {
		printf("ERR: no commit to branch from\n");
		return FGIT_EMPTY;
	}
	{
		char path[FGIT_PATH_MAX];
		snprintf(path, sizeof(path), "%s/%s", FGIT_HEADS, name);
		if (FileFS_file_exist(ffs, path)) return FGIT_EXISTS;
		rc = write_ref(ffs, path, head_oid);
		if (rc == FGIT_OK) printf("branch %s -> %s\n", name, head_oid);
		return rc;
	}
}

static int checkout_tree_files(FileFS *ffs, const char *tree_oid)
{
	Index want, cur;
	int i, rc;

	memset(&want, 0, sizeof(want));
	memset(&cur, 0, sizeof(cur));
	rc = flatten_tree(ffs, tree_oid, "/", &want);
	if (rc != FGIT_OK) return rc;
	rc = collect_work_files(ffs, "/", &cur);
	if (rc != FGIT_OK) {
		index_free(&want);
		return rc;
	}

	/* Remove tracked files not in target (only those currently in index or want). */
	for (i = 0; i < cur.count; i++) {
		if (index_find(&want, cur.items[i].path) < 0) {
			/* leave untracked alone; only delete if was in previous HEAD.
			   Simplified: do not auto-delete. */
		}
	}

	for (i = 0; i < want.count; i++) {
		unsigned char *payload = NULL;
		size_t len = 0;
		char type[16];
		rc = load_object(ffs, want.items[i].oid, type, sizeof(type), &payload, &len);
		if (rc != FGIT_OK) {
			index_free(&want);
			index_free(&cur);
			return rc;
		}
		if (strcmp(type, "blob") != 0) {
			free(payload);
			index_free(&want);
			index_free(&cur);
			return FGIT_ERR;
		}
		if (ensure_parent_dirs(ffs, want.items[i].path) != FGIT_OK) {
			free(payload);
			index_free(&want);
			index_free(&cur);
			return FGIT_ERR;
		}
		rc = write_all(ffs, want.items[i].path, payload, len);
		free(payload);
		if (rc != FGIT_OK) {
			index_free(&want);
			index_free(&cur);
			return rc;
		}
	}

	/* Reset index to match want */
	{
		Index idx;
		memset(&idx, 0, sizeof(idx));
		for (i = 0; i < want.count; i++) {
			if (index_set(&idx, want.items[i].path, want.items[i].oid, 0) != FGIT_OK) {
				index_free(&idx);
				index_free(&want);
				index_free(&cur);
				return FGIT_ERR;
			}
		}
		rc = index_save(ffs, &idx);
		index_free(&idx);
	}

	index_free(&want);
	index_free(&cur);
	return rc;
}

int FileGit_checkout(FileFS *ffs, const char *target)
{
	char oid[FGIT_OID_HEX], tree[FGIT_OID_HEX];
	char path[FGIT_PATH_MAX];
	char head_content[64];
	int rc, is_branch = 0;

	if (!FileGit_is_repo(ffs)) return FGIT_NOT_REPO;
	if (!target || !*target) return FGIT_BAD_ARG;

	if (strlen(target) == FGIT_OID_LEN &&
		strspn(target, "0123456789abcdef") == FGIT_OID_LEN) {
		strncpy(oid, target, FGIT_OID_HEX);
	} else {
		if (!component_ok(target)) return FGIT_NAME_TOO_LONG;
		snprintf(path, sizeof(path), "%s/%s", FGIT_HEADS, target);
		rc = read_ref_file(ffs, path, oid);
		if (rc != FGIT_OK) return rc;
		is_branch = 1;
	}

	rc = commit_tree_oid(ffs, oid, tree);
	if (rc != FGIT_OK) return rc;
	rc = checkout_tree_files(ffs, tree);
	if (rc != FGIT_OK) return rc;

	if (is_branch)
		snprintf(head_content, sizeof(head_content), "ref: refs/heads/%s\n", target);
	else
		snprintf(head_content, sizeof(head_content), "%s\n", oid);
	rc = write_all(ffs, FGIT_HEAD, head_content, strlen(head_content));
	if (rc == FGIT_OK)
		printf("checkout %s (%s)\n", target, oid);
	return rc;
}

int FileGit_head_oid(FileFS *ffs, char *out)
{
	char branch[FGIT_NAME_MAX + 1];
	if (!out) return FGIT_BAD_ARG;
	out[0] = 0;
	if (!FileGit_is_repo(ffs)) return FGIT_NOT_REPO;
	return resolve_head(ffs, out, branch, sizeof(branch));
}
