#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <iostream>
#include <sstream>
#include <string>
#include <unistd.h>
#include <vector>

#include <filefs/filefs.hpp>

namespace fs = std::filesystem;
using clock_type = std::chrono::steady_clock;

static constexpr int PAYLOAD = 4096;

static double median(std::vector<double> samples) {
  if (samples.empty()) return 0;
  std::sort(samples.begin(), samples.end());
  const auto n = samples.size();
  if (n % 2 == 0) return (samples[n / 2 - 1] + samples[n / 2]) / 2.0;
  return samples[n / 2];
}

template <typename Body>
static std::pair<double, int> time_body(int iters, int warmup, Body body) {
  for (int i = 0; i < warmup; ++i) body();
  std::vector<double> samples;
  samples.reserve(iters);
  for (int i = 0; i < iters; ++i) {
    const auto t0 = clock_type::now();
    body();
    samples.push_back(std::chrono::duration<double, std::nano>(clock_type::now() - t0).count());
  }
  return {median(std::move(samples)), iters};
}

int main(int argc, char** argv) {
  int iters = 40;
  int warmup = 2;
  if (argc > 1) iters = std::atoi(argv[1]);
  if (argc > 2) warmup = std::atoi(argv[2]);

  const auto dir = fs::temp_directory_path() / ("filefs-bench-cpp-" + std::to_string(::getpid()));
  fs::create_directories(dir);
  const auto image = dir / "bench.ffs";
  int counter = 0;
  auto uniq = [&](const char* prefix) {
    return std::string(prefix) + std::to_string(++counter);
  };

  std::vector<std::byte> payload(PAYLOAD);
  for (int i = 0; i < PAYLOAD; ++i) payload[i] = static_cast<std::byte>(i);
  std::vector<std::byte> buf(PAYLOAD);

  std::ostringstream out;
  out << "{\"language\":\"cpp\",\"runtime\":\"c++20\",\"ops\":{";
  bool first = true;
  auto emit = [&](const char* name, double ns, int n) {
    if (!first) out << ',';
    first = false;
    out << '"' << name << "\":{\"ns_per_op\":" << ns << ",\"iters\":" << n << '}';
  };

  {
    auto [ns, n] = time_body(iters, warmup, [&] {
      auto p = dir / (uniq("mkfs") + ".ffs");
      filefs::FileSystem::mkfs(p.string());
      fs::remove(p);
      fs::remove(p.string() + "-j");
    });
    emit("mkfs", ns, n);
  }

  filefs::FileSystem::mkfs(image.string());
  filefs::FileSystem fsys;
  if (!fsys.mount(image.string())) return 1;

  {
    auto [ns, n] = time_body(iters, warmup, [&] {
      fsys.umount();
      if (!fsys.mount(image.string())) std::abort();
    });
    emit("mount_umount", ns, n);
  }

  {
    auto [ns, n] = time_body(iters, warmup, [&] {
      if (fsys.mkdir(uniq("d")) != 0) std::abort();
    });
    emit("mkdir", ns, n);
  }

  fsys.mkdir("cwdbench");
  {
    auto [ns, n] = time_body(iters, warmup, [&] {
      if (!fsys.chdir("cwdbench")) std::abort();
      (void)fsys.getcwd();
      if (!fsys.chdir("/")) std::abort();
    });
    emit("chdir_getcwd", ns, n);
  }

  {
    auto [ns, n] = time_body(iters, warmup, [&] {
      auto f = fsys.fopen(uniq("o") + ".txt", "w");
      if (!f) std::abort();
      fsys.fclose(*f);
    });
    emit("open_write_close", ns, n);
  }

  {
    auto seed = fsys.fopen("seed.bin", "w");
    if (!seed || fsys.fwrite(*seed, payload) != payload.size()) return 1;
    fsys.fclose(*seed);
  }

  {
    auto [ns, n] = time_body(iters, warmup, [&] {
      auto f = fsys.fopen("wbench.bin", "w");
      if (!f || fsys.fwrite(*f, payload) != payload.size()) std::abort();
      fsys.fclose(*f);
    });
    emit("write_4kib", ns, n);
  }

  {
    auto [ns, n] = time_body(iters, warmup, [&] {
      auto f = fsys.fopen("seed.bin", "r");
      if (!f || fsys.fread(*f, buf) != buf.size()) std::abort();
      fsys.fclose(*f);
    });
    emit("read_4kib", ns, n);
  }

  {
    auto [ns, n] = time_body(iters, warmup, [&] {
      auto f = fsys.fopen("seed.bin", "r");
      if (!f || !fsys.fseek(*f, 0, filefs::Seek::End)) std::abort();
      (void)fsys.ftell(*f);
      fsys.rewind(*f);
      fsys.fclose(*f);
    });
    emit("seek_tell_rewind", ns, n);
  }

  {
    auto [ns, n] = time_body(iters, warmup, [&] {
      fsys.remove("copy_dst.bin");
      if (fsys.copy("seed.bin", "copy_dst.bin") != 0) std::abort();
    });
    emit("copy_file", ns, n);
  }

  {
    auto [ns, n] = time_body(iters, warmup, [&] {
      auto src = uniq("r") + ".txt";
      auto dst = uniq("s") + ".txt";
      auto f = fsys.fopen(src, "w");
      if (!f) std::abort();
      fsys.fclose(*f);
      if (fsys.rename(src, dst) != 0) std::abort();
      fsys.remove(dst);
    });
    emit("rename", ns, n);
  }

  {
    auto [ns, n] = time_body(iters, warmup, [&] {
      auto name = uniq("m") + ".txt";
      auto f = fsys.fopen(name, "w");
      if (!f) std::abort();
      fsys.fclose(*f);
      if (fsys.remove(name) != 0) std::abort();
    });
    emit("remove_file", ns, n);
  }

  {
    auto [ns, n] = time_body(iters, warmup, [&] {
      auto d = fsys.opendir("/");
      if (!d) std::abort();
      while (fsys.readdir(*d)) {
      }
      fsys.closedir(*d);
    });
    emit("readdir", ns, n);
  }

  {
    auto [ns, n] = time_body(iters, warmup, [&] {
      (void)fsys.file_exist("seed.bin");
      (void)fsys.dir_exist("cwdbench");
    });
    emit("exists", ns, n);
  }

  {
    auto [ns, n] = time_body(iters, warmup, [&] {
      if (!fsys.begin()) std::abort();
      auto f = fsys.fopen(uniq("t") + ".txt", "w");
      if (!f) std::abort();
      const std::byte x{static_cast<std::byte>('x')};
      if (fsys.fwrite(*f, std::span<const std::byte>(&x, 1)) != 1) std::abort();
      fsys.fclose(*f);
      if (!fsys.commit()) std::abort();
    });
    emit("txn_commit", ns, n);
  }

  fsys.umount();
  out << "}}\n";
  std::cout << out.str();
  fs::remove_all(dir);
  return 0;
}
