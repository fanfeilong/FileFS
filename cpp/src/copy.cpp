#include "filefs/filefs.hpp"

#include "types.hpp"

#include <array>

namespace filefs {

int FileSystem::copy(const std::string_view from_filename, const std::string_view to_filename) {
  if (!state_ || !state_->mounted() || from_filename.empty() || to_filename.empty()) {
    return 1;
  }
  if (from_filename.back() == '/') {
    return 2;
  }
  if (to_filename.back() == '/') {
    return 3;
  }

  auto validate_parent = [this](const std::string_view path, const int error_code) -> int {
    std::uint32_t blockindex = 0U;
    int start = 0;
    if (path.front() == '/') {
      blockindex = 1U;
      start = 1;
    } else if (state_->tmp.state == 0U) {
      blockindex = state_->pwd_blockindex;
    } else {
      blockindex = state_->tmp.pwd_blockindex;
    }

    std::array<char, BlockNameMaxSize + 2> s{};
    int slen = 0;
    for (int i = start; i < static_cast<int>(path.size()); ++i) {
      if (path[static_cast<std::size_t>(i)] == '/') {
        if (slen == 0) {
          continue;
        }
        if (i == static_cast<int>(path.size()) - 1) {
          break;
        }
        const std::uint32_t index =
            state_->find_path_blockindex(blockindex, std::string_view{s.data(), static_cast<std::size_t>(slen)});
        if (index < 1U) {
          return error_code;
        }
        blockindex = index;
        slen = 0;
        continue;
      }
      s[static_cast<std::size_t>(slen++)] = path[static_cast<std::size_t>(i)];
      if (slen > static_cast<int>(BlockNameMaxSize)) {
        return error_code;
      }
    }
    if (slen > static_cast<int>(BlockNameMaxSize)) {
      return error_code;
    }
    const std::string_view lastname{s.data(), static_cast<std::size_t>(slen)};
    if (lastname == "." || lastname == "..") {
      return error_code;
    }
    return 0;
  };

  if (const int rc = validate_parent(from_filename, 2); rc != 0) {
    return rc;
  }
  if (const int rc = validate_parent(to_filename, 3); rc != 0) {
    return rc;
  }

  const std::uint8_t src_type = state_->stat(from_filename);
  if (src_type == 0U) {
    return 4;
  }
  if (src_type != 1U) {
    return 2;
  }
  if (state_->stat(to_filename) != 0U) {
    return 5;
  }

  const bool started_txn = state_->tmp.state == 0U;
  if (started_txn && !begin()) {
    return 1;
  }

  auto src = fopen(from_filename, "r");
  auto dst = fopen(to_filename, "w");
  if (!src || !dst) {
    if (started_txn) {
      rollback();
    }
    return 1;
  }

  std::array<std::byte, 4096> buffer{};
  while (true) {
    const std::size_t n = fread(*src, buffer);
    if (n == 0U) {
      break;
    }
    if (fwrite(*dst, std::span<const std::byte>(buffer.data(), n)) != n) {
      if (started_txn) {
        rollback();
      }
      return 1;
    }
  }
  fclose(*src);
  fclose(*dst);

  if (started_txn && !commit()) {
    return 1;
  }
  return 0;
}

}  // namespace filefs
