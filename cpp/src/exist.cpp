#include "types.hpp"

#include "util.hpp"

namespace filefs::detail {

std::uint8_t FileSystemState::stat(const std::string_view name) {
  if (name.empty() || !mounted()) {
    return 0U;
  }

  Block block{};
  const int len_n = static_cast<int>(name.size());
  std::uint32_t blockindex = 0U;
  int start = 0;
  if (name.front() == '/') {
    blockindex = 1U;
    start = 1;
  } else if (tmp.state == 0U) {
    blockindex = pwd_blockindex;
  } else {
    blockindex = tmp.pwd_blockindex;
  }

  std::array<char, BlockNameMaxSize + 2> s{};
  int slen = 0;
  for (int i = start; i < len_n; ++i) {
    if (name[static_cast<std::size_t>(i)] == '/') {
      if (slen == 0) {
        continue;
      }
      const std::uint32_t index = find_path_blockindex(
          blockindex, std::string_view{s.data(), static_cast<std::size_t>(slen)});
      if (index < 1U) {
        return 0U;
      }
      blockindex = index;
      slen = 0;
      continue;
    }
    s[static_cast<std::size_t>(slen++)] = name[static_cast<std::size_t>(i)];
    if (slen > static_cast<int>(BlockNameMaxSize)) {
      return 0U;
    }
  }
  if (slen == 0) {
    return 2U;
  }

  const std::string_view lastname{s.data(), static_cast<std::size_t>(slen)};
  if (!readblock(blockindex, block)) {
    return 0U;
  }

  const std::uint32_t stop_blockindex =
      b4_to_u32(std::span<const std::uint8_t, 4>(block.data() + 12 + 1 + 14 + 4, 4));
  const std::uint16_t offset =
      b2_to_u16(std::span<const std::uint8_t, 2>(block.data() + 12 + 1 + 14 + 4 + 4, 2));

  std::uint32_t index = blockindex;
  for (;;) {
    int k = BlockHead;
    for (int i = 0; i < BlockItemMaxCount; ++i) {
      const std::uint8_t state = block[static_cast<std::size_t>(k)];
      ++k;
      if (fixed_cstr(std::span<const std::uint8_t>(block.data() + k, BlockNameMaxSize)) != lastname) {
        k += static_cast<int>(BlockNameMaxSize) + 10;
        if (index == stop_blockindex && k + 1 >= static_cast<int>(offset)) {
          return 0U;
        }
        continue;
      }
      return (state & 0x01U) == 0U ? 2U : 1U;
    }

    index = b4_to_u32(std::span<const std::uint8_t, 4>(block.data() + 4, 4));
    if (index == 0U || !readblock(index, block)) {
      return 0U;
    }
  }
}

}  // namespace filefs::detail

namespace filefs {

bool FileSystem::file_exist(const std::string_view path) const {
  return state_ && state_->stat(path) == 1U;
}

bool FileSystem::dir_exist(const std::string_view path) const {
  return state_ && state_->stat(path) == 2U;
}

}  // namespace filefs
