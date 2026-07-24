#define _POSIX_C_SOURCE 200809L
#define _DEFAULT_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <stdint.h>
#include "FileFS.h"

#define PAYLOAD 4096
#define MAX_SAMPLES 512

static double now_ns(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (double)ts.tv_sec * 1e9 + (double)ts.tv_nsec;
}

static int cmp_double(const void *a, const void *b) {
  double da = *(const double *)a;
  double db = *(const double *)b;
  return (da > db) - (da < db);
}

static double median(double *samples, int n) {
  qsort(samples, (size_t)n, sizeof(double), cmp_double);
  if (n % 2 == 0) {
    return (samples[n / 2 - 1] + samples[n / 2]) / 2.0;
  }
  return samples[n / 2];
}

typedef void (*fn_t)(void *);

static void time_op(const char *name, int iters, int warmup, fn_t prep, fn_t body, void *ctx, char *out, size_t out_sz) {
  double samples[MAX_SAMPLES];
  if (iters > MAX_SAMPLES) iters = MAX_SAMPLES;
  for (int i = 0; i < warmup; i++) {
    if (prep) prep(ctx);
    body(ctx);
  }
  for (int i = 0; i < iters; i++) {
    if (prep) prep(ctx);
    double t0 = now_ns();
    body(ctx);
    samples[i] = now_ns() - t0;
  }
  snprintf(out, out_sz, "\"%s\":{\"ns_per_op\":%.3f,\"iters\":%d}", name, median(samples, iters), iters);
}

typedef struct {
  FileFS *ffs;
  char dir[512];
  char image[576];
  unsigned char payload[PAYLOAD];
  unsigned char buf[PAYLOAD];
  int counter;
  char tmpname[64];
} Ctx;

static char *uniq(Ctx *ctx, const char *prefix) {
  snprintf(ctx->tmpname, sizeof(ctx->tmpname), "%s%d", prefix, ctx->counter++);
  return ctx->tmpname;
}

static void op_mkfs(void *p) {
  Ctx *ctx = p;
  char path[640];
  snprintf(path, sizeof(path), "%s/%s.ffs", ctx->dir, uniq(ctx, "mkfs"));
  FileFS_mkfs(path);
  unlink(path);
  char j[650];
  snprintf(j, sizeof(j), "%s-j", path);
  unlink(j);
}

static void prep_umount(void *p) {
  FileFS_umount(((Ctx *)p)->ffs);
}

static void op_mount_umount(void *p) {
  Ctx *ctx = p;
  FileFS_mount(ctx->ffs, ctx->image);
  FileFS_umount(ctx->ffs);
}

static void op_mkdir(void *p) {
  Ctx *ctx = p;
  FileFS_mkdir(ctx->ffs, uniq(ctx, "d"));
}

static void op_chdir(void *p) {
  Ctx *ctx = p;
  FileFS_chdir(ctx->ffs, "cwdbench");
  (void)FileFS_getcwd(ctx->ffs);
  FileFS_chdir(ctx->ffs, "/");
}

static void op_open_close(void *p) {
  Ctx *ctx = p;
  char name[80];
  snprintf(name, sizeof(name), "%s.txt", uniq(ctx, "o"));
  FFS_FILE *f = FileFS_fopen(ctx->ffs, name, "w");
  FileFS_fclose(ctx->ffs, f);
}

static void op_write(void *p) {
  Ctx *ctx = p;
  FFS_FILE *f = FileFS_fopen(ctx->ffs, "wbench.bin", "w");
  FileFS_fwrite(ctx->ffs, ctx->payload, 1, PAYLOAD, f);
  FileFS_fclose(ctx->ffs, f);
}

static void op_read(void *p) {
  Ctx *ctx = p;
  FFS_FILE *f = FileFS_fopen(ctx->ffs, "seed.bin", "r");
  FileFS_fread(ctx->ffs, ctx->buf, 1, PAYLOAD, f);
  FileFS_fclose(ctx->ffs, f);
}

static void op_seek(void *p) {
  Ctx *ctx = p;
  FFS_FILE *f = FileFS_fopen(ctx->ffs, "seed.bin", "r");
  FileFS_fseek(ctx->ffs, f, 0, FFS_SEEK_END);
  (void)FileFS_ftell(ctx->ffs, f);
  FileFS_rewind(ctx->ffs, f);
  FileFS_fclose(ctx->ffs, f);
}

static void op_copy(void *p) {
  Ctx *ctx = p;
  FileFS_remove(ctx->ffs, "copy_dst.bin");
  FileFS_copy(ctx->ffs, "seed.bin", "copy_dst.bin");
}

static void prep_rename(void *p) {
  Ctx *ctx = p;
  FFS_FILE *f = FileFS_fopen(ctx->ffs, "ren_src.txt", "w");
  FileFS_fclose(ctx->ffs, f);
}

static void op_rename(void *p) {
  Ctx *ctx = p;
  FileFS_rename(ctx->ffs, "ren_src.txt", "ren_dst.txt");
  FileFS_remove(ctx->ffs, "ren_dst.txt");
}

static void prep_remove(void *p) {
  Ctx *ctx = p;
  FFS_FILE *f = FileFS_fopen(ctx->ffs, "rm_me.txt", "w");
  FileFS_fclose(ctx->ffs, f);
}

static void op_remove(void *p) {
  FileFS_remove(((Ctx *)p)->ffs, "rm_me.txt");
}

static void op_readdir(void *p) {
  Ctx *ctx = p;
  char *absolute = NULL;
  FFS_DIR *d = FileFS_opendir(ctx->ffs, "/", &absolute);
  while (FileFS_readdir(ctx->ffs, d)) {
  }
  FileFS_closedir(ctx->ffs, d);
}

static void op_exists(void *p) {
  Ctx *ctx = p;
  (void)FileFS_file_exist(ctx->ffs, "seed.bin");
  (void)FileFS_dir_exist(ctx->ffs, "cwdbench");
}

static void op_txn(void *p) {
  Ctx *ctx = p;
  FileFS_begin(ctx->ffs);
  char name[80];
  snprintf(name, sizeof(name), "%s.txt", uniq(ctx, "t"));
  FFS_FILE *f = FileFS_fopen(ctx->ffs, name, "w");
  unsigned char x = 'x';
  FileFS_fwrite(ctx->ffs, &x, 1, 1, f);
  FileFS_fclose(ctx->ffs, f);
  FileFS_commit(ctx->ffs);
}

int main(int argc, char **argv) {
  int iters = 40;
  int warmup = 2;
  if (argc > 1) iters = atoi(argv[1]);
  if (argc > 2) warmup = atoi(argv[2]);

  Ctx ctx;
  memset(&ctx, 0, sizeof(ctx));
  snprintf(ctx.dir, sizeof(ctx.dir), "/tmp/filefs-bench-c-%d", (int)getpid());
  char cmd[640];
  snprintf(cmd, sizeof(cmd), "mkdir -p %s", ctx.dir);
  system(cmd);
  snprintf(ctx.image, sizeof(ctx.image), "%s/bench.ffs", ctx.dir);
  for (int i = 0; i < PAYLOAD; i++) ctx.payload[i] = (unsigned char)i;

  char parts[16][192];
  int nparts = 0;

  time_op("mkfs", iters, warmup, NULL, op_mkfs, &ctx, parts[nparts], sizeof(parts[0]));
  nparts++;

  FileFS_mkfs(ctx.image);
  ctx.ffs = FileFS_create();
  FileFS_mount(ctx.ffs, ctx.image);

  time_op("mount_umount", iters, warmup, prep_umount, op_mount_umount, &ctx, parts[nparts], sizeof(parts[0]));
  nparts++;
  FileFS_mount(ctx.ffs, ctx.image);

  time_op("mkdir", iters, warmup, NULL, op_mkdir, &ctx, parts[nparts], sizeof(parts[0]));
  nparts++;
  FileFS_mkdir(ctx.ffs, "cwdbench");
  time_op("chdir_getcwd", iters, warmup, NULL, op_chdir, &ctx, parts[nparts], sizeof(parts[0]));
  nparts++;
  time_op("open_write_close", iters, warmup, NULL, op_open_close, &ctx, parts[nparts], sizeof(parts[0]));
  nparts++;

  FFS_FILE *seed = FileFS_fopen(ctx.ffs, "seed.bin", "w");
  FileFS_fwrite(ctx.ffs, ctx.payload, 1, PAYLOAD, seed);
  FileFS_fclose(ctx.ffs, seed);

  time_op("write_4kib", iters, warmup, NULL, op_write, &ctx, parts[nparts], sizeof(parts[0]));
  nparts++;
  time_op("read_4kib", iters, warmup, NULL, op_read, &ctx, parts[nparts], sizeof(parts[0]));
  nparts++;
  time_op("seek_tell_rewind", iters, warmup, NULL, op_seek, &ctx, parts[nparts], sizeof(parts[0]));
  nparts++;
  time_op("copy_file", iters, warmup, NULL, op_copy, &ctx, parts[nparts], sizeof(parts[0]));
  nparts++;
  time_op("rename", iters, warmup, prep_rename, op_rename, &ctx, parts[nparts], sizeof(parts[0]));
  nparts++;
  time_op("remove_file", iters, warmup, prep_remove, op_remove, &ctx, parts[nparts], sizeof(parts[0]));
  nparts++;
  time_op("readdir", iters, warmup, NULL, op_readdir, &ctx, parts[nparts], sizeof(parts[0]));
  nparts++;
  time_op("exists", iters, warmup, NULL, op_exists, &ctx, parts[nparts], sizeof(parts[0]));
  nparts++;
  time_op("txn_commit", iters, warmup, NULL, op_txn, &ctx, parts[nparts], sizeof(parts[0]));
  nparts++;

  FileFS_umount(ctx.ffs);
  FileFS_destroy(ctx.ffs);
  snprintf(cmd, sizeof(cmd), "rm -rf %s", ctx.dir);
  system(cmd);

  printf("{\"language\":\"c\",\"runtime\":\"c11\",\"ops\":{");
  for (int i = 0; i < nparts; i++) {
    if (i) putchar(',');
    fputs(parts[i], stdout);
  }
  printf("}}\n");
  return 0;
}
