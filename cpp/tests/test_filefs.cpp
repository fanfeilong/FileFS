#include "filefs/filefs.hpp"

#include <array>
#include <chrono>
#include <filesystem>
#include <iostream>
#include <optional>
#include <stdexcept>
#include <string>
#include <string_view>

namespace {

using filefs::DirType;
using filefs::FileSystem;

struct TestFailure : std::runtime_error {
  using std::runtime_error::runtime_error;
};

void check(const bool condition, const std::string& message) {
  if (!condition) {
    throw TestFailure(message);
  }
}

std::filesystem::path make_image_path(const std::string_view suffix) {
  const auto base = std::filesystem::temp_directory_path();
  const auto now = std::chrono::steady_clock::now().time_since_epoch().count();
  return base / ("filefs-cpp-" + std::to_string(now) + "-" + std::string(suffix) + ".ffs");
}

struct ImageFixture {
  std::filesystem::path path;
  FileSystem fs;

  explicit ImageFixture(const std::string_view name) : path(make_image_path(name)) {
    check(FileSystem::mkfs(path.string()), "mkfs failed");
    check(fs.mount(path.string()), "mount failed");
  }

  ~ImageFixture() {
    fs.umount();
    std::error_code ec;
    std::filesystem::remove(path, ec);
    std::filesystem::remove(path.string() + "-j", ec);
  }
};

void test_mkfs_mount_getcwd() {
  ImageFixture fixture("lifecycle");
  check(fixture.fs.is_mounted(), "filesystem should be mounted");
  check(fixture.fs.getcwd() == "/", "cwd should start at /");
}

void test_mkdir_chdir() {
  ImageFixture fixture("mkdir");
  check(fixture.fs.mkdir("docs") == 0, "mkdir docs failed");
  check(fixture.fs.chdir("docs"), "chdir docs failed");
  check(fixture.fs.getcwd() == "/docs/", "cwd should be /docs/");
}

void test_fopen_roundtrip() {
  ImageFixture fixture("roundtrip");
  check(fixture.fs.mkdir("docs") == 0, "mkdir docs failed");
  check(fixture.fs.chdir("docs"), "chdir docs failed");

  auto out = fixture.fs.fopen("note.txt", "w");
  check(out.has_value(), "fopen write failed");
  const std::string payload = "hello filefs";
  const auto wrote = fixture.fs.fwrite(*out, std::as_bytes(std::span(payload)));
  check(wrote == payload.size(), "fwrite size mismatch");
  fixture.fs.fclose(*out);

  auto in = fixture.fs.fopen("note.txt", "r");
  check(in.has_value(), "fopen read failed");
  check(fixture.fs.fseek(*in, 0, filefs::Seek::End), "seek end failed");
  const auto end_pos = fixture.fs.ftell(*in);
  fixture.fs.rewind(*in);
  std::array<std::byte, 64> buffer{};
  const auto read = fixture.fs.fread(*in, buffer);
  fixture.fs.fclose(*in);
  const std::string roundtrip(reinterpret_cast<const char*>(buffer.data()), read);
  check(roundtrip == payload,
        "roundtrip data mismatch on " + fixture.path.string() + ": size=" + std::to_string(end_pos) +
            " got \"" + roundtrip + "\" expected \"" + payload + "\"");
}

void test_copy_rename_remove() {
  ImageFixture fixture("copy");

  auto out = fixture.fs.fopen("orig.txt", "w");
  check(out.has_value(), "fopen orig failed");
  const std::string payload = "copy me";
  check(fixture.fs.fwrite(*out, std::as_bytes(std::span(payload))) == payload.size(), "write orig failed");
  fixture.fs.fclose(*out);

  const int copy_rc = fixture.fs.copy("orig.txt", "copy.txt");
  check(copy_rc == 0, "copy failed rc=" + std::to_string(copy_rc));
  const int rename_rc = fixture.fs.rename("copy.txt", "renamed.txt");
  check(rename_rc == 0, "rename failed rc=" + std::to_string(rename_rc));
  check(fixture.fs.file_exist("renamed.txt"), "renamed file missing");
  check(fixture.fs.remove("renamed.txt") == 0, "remove failed");
  check(!fixture.fs.file_exist("renamed.txt"), "renamed file should be removed");
}

void test_opendir_lists_docs() {
  ImageFixture fixture("readdir");
  check(fixture.fs.mkdir("docs") == 0, "mkdir docs failed");
  auto dir = fixture.fs.opendir("/");
  check(dir.has_value(), "opendir failed");

  bool found_docs = false;
  while (true) {
    auto ent = fixture.fs.readdir(*dir);
    if (!ent.has_value()) {
      break;
    }
    if (ent->name_view() == "docs" && ent->type == DirType::Dir) {
      found_docs = true;
    }
  }
  fixture.fs.closedir(*dir);
  check(found_docs, "docs should be listed");
}

void test_begin_commit_creates_file() {
  ImageFixture fixture("txn");
  check(fixture.fs.begin(), "begin failed");
  auto out = fixture.fs.fopen("txn.txt", "w");
  check(out.has_value(), "fopen txn failed");
  std::array<std::byte, 1> data{std::byte{'x'}};
  check(fixture.fs.fwrite(*out, data) == 1U, "write txn failed");
  fixture.fs.fclose(*out);
  check(fixture.fs.commit(), "commit failed");
  check(fixture.fs.file_exist("txn.txt"), "txn file missing after commit");
}

}  // namespace

int main() {
  try {
    test_mkfs_mount_getcwd();
    test_mkdir_chdir();
    test_fopen_roundtrip();
    test_copy_rename_remove();
    test_opendir_lists_docs();
    test_begin_commit_creates_file();
    std::cout << "All FileFS C++ tests passed\n";
    return 0;
  } catch (const TestFailure& failure) {
    std::cerr << "TEST FAILURE: " << failure.what() << '\n';
    return 1;
  } catch (const std::exception& ex) {
    std::cerr << "UNEXPECTED ERROR: " << ex.what() << '\n';
    return 1;
  }
}
