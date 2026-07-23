#include "util.hpp"

#include <fcntl.h>

#include <algorithm>
#include <vector>

namespace filefs::detail {

CFile::~CFile() { reset(); }

CFile::CFile(CFile&& other) noexcept : handle(other.handle) { other.handle = nullptr; }

CFile& CFile::operator=(CFile&& other) noexcept {
  if (this != &other) {
    reset();
    handle = other.handle;
    other.handle = nullptr;
  }
  return *this;
}

void CFile::reset(std::FILE* fp) noexcept {
  if (handle != nullptr) {
    std::fclose(handle);
  }
  handle = fp;
}

int CFile::fd() const noexcept {
  if (handle == nullptr) {
    return -1;
  }
  return ::fileno(handle);
}

void FileSystemState::reset() noexcept {
  fp.reset();
  fn.clear();
  if (!fnj.empty()) {
    remove_if_exists(fnj);
  }
  fnj.clear();
  tmpstop();
  tmp.pwd.clear();
  pwd.clear();
  pwd_blockindex = 0;
  pwd_tmp.clear();
}

std::string fixed_cstr(std::span<const std::uint8_t> bytes) {
  std::size_t len = 0;
  while (len < bytes.size() && bytes[len] != 0U) {
    ++len;
  }
  return std::string(reinterpret_cast<const char*>(bytes.data()), len);
}

void copy_name_into(std::span<std::uint8_t> dst, std::string_view name) noexcept {
  std::fill(dst.begin(), dst.end(), 0U);
  const std::size_t copy_size = std::min(dst.size(), name.size());
  std::memcpy(dst.data(), name.data(), copy_size);
}

bool create_temp_file(std::string_view prefix, CFile& out, std::string& out_path) {
  std::string tmpl = std::filesystem::temp_directory_path().string();
  if (!tmpl.empty() && tmpl.back() != '/') {
    tmpl.push_back('/');
  }
  tmpl.append(prefix.data(), prefix.size());
  tmpl.append("XXXXXX");

  std::vector<char> path(tmpl.begin(), tmpl.end());
  path.push_back('\0');

  const int fd = ::mkstemp(path.data());
  if (fd < 0) {
    return false;
  }

  std::FILE* fp = ::fdopen(fd, "w+b");
  if (fp == nullptr) {
    ::close(fd);
    return false;
  }

  out.reset(fp);
  out_path.assign(path.data());
  return true;
}

void remove_if_exists(const std::string& path) noexcept {
  if (!path.empty()) {
    (void)std::filesystem::remove(path);
  }
}

}  // namespace filefs::detail
