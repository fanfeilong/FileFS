#include "types.hpp"

#include "util.hpp"

namespace filefs {

std::optional<File> FileSystem::fopen(const std::string_view filename, const std::string_view mode) {
  if (!state_ || !state_->mounted() || filename.empty() || mode.empty()) {
    return std::nullopt;
  }

  std::uint8_t bmode = 0U;
  if (mode == "r") {
    bmode = 0U;
  } else if (mode == "w") {
    bmode = 1U;
  } else if (mode == "a") {
    bmode = 2U;
  } else if (mode == "r+") {
    bmode = 3U;
  } else if (mode == "w+") {
    bmode = 4U;
  } else if (mode == "a+") {
    bmode = 5U;
  } else {
    return std::nullopt;
  }

  std::uint32_t blockindex = 0U;
  int start = 0;
  if (filename.front() == '/') {
    blockindex = 1U;
    start = 1;
  } else if (state_->tmp.state == 0U) {
    blockindex = state_->pwd_blockindex;
  } else {
    blockindex = state_->tmp.pwd_blockindex;
  }

  std::array<char, BlockNameMaxSize + 2> s{};
  int slen = 0;
  for (int i = start; i < static_cast<int>(filename.size()); ++i) {
    if (filename[static_cast<std::size_t>(i)] == '/') {
      if (slen == 0) {
        continue;
      }
      const auto name = std::string_view{s.data(), static_cast<std::size_t>(slen)};
      const std::uint32_t index = state_->find_path_blockindex(blockindex, name);
      if (index < 1U) {
        return std::nullopt;
      }
      blockindex = index;
      slen = 0;
      continue;
    }
    s[static_cast<std::size_t>(slen++)] = filename[static_cast<std::size_t>(i)];
    if (slen > static_cast<int>(BlockNameMaxSize)) {
      return std::nullopt;
    }
  }
  if (slen == 0) {
    return std::nullopt;
  }

  const std::string_view lastname{s.data(), static_cast<std::size_t>(slen)};
  if (lastname == "." || lastname == "..") {
    return std::nullopt;
  }

  switch (bmode) {
    case 0U:
    case 3U:
      return state_->do_fopen_r(lastname, bmode, blockindex);
    case 1U:
    case 4U:
      return state_->do_fopen_w(lastname, bmode, blockindex);
    case 2U:
    case 5U:
      return state_->do_fopen_a(lastname, bmode, blockindex);
    default:
      return std::nullopt;
  }
}

}  // namespace filefs
