#include "types.hpp"

#include "util.hpp"

#include <algorithm>

namespace filefs {

std::optional<Directory> FileSystem::opendir(const std::string_view path) {
  if (!state_ || !state_->mounted()) {
    return std::nullopt;
  }

  Directory dir;
  std::uint32_t blockindex = 0U;
  int start = 0;
  if (!path.empty() && path.front() == '/') {
    blockindex = 1U;
    start = 1;
    if (!state_->init_pwdtmp("/")) {
      return std::nullopt;
    }
  } else {
    if (state_->tmp.state == 0U) {
      blockindex = state_->pwd_blockindex;
      if (!state_->init_pwdtmp(state_->pwd)) {
        return std::nullopt;
      }
    } else {
      blockindex = state_->tmp.pwd_blockindex;
      if (!state_->init_pwdtmp(state_->tmp.pwd)) {
        return std::nullopt;
      }
    }
  }

  std::array<char, BlockNameMaxSize + 2> s{};
  int slen = 0;
  for (int i = start; i < static_cast<int>(path.size()); ++i) {
    if (path[static_cast<std::size_t>(i)] == '/') {
      if (slen == 0) {
        continue;
      }
      const std::string_view comp{s.data(), static_cast<std::size_t>(slen)};
      const std::uint32_t index = state_->find_path_blockindex(blockindex, comp);
      if (index < 1U) {
        return std::nullopt;
      }
      blockindex = index;
      slen = 0;
      if (!state_->add_to_pwdtmp(path.size(), comp)) {
        return std::nullopt;
      }
      continue;
    }
    s[static_cast<std::size_t>(slen++)] = path[static_cast<std::size_t>(i)];
    if (slen > static_cast<int>(BlockNameMaxSize)) {
      return std::nullopt;
    }
  }
  if (slen > 0) {
    const std::string_view comp{s.data(), static_cast<std::size_t>(slen)};
    const std::uint32_t index = state_->find_path_blockindex(blockindex, comp);
    if (index < 1U) {
      return std::nullopt;
    }
    blockindex = index;
    if (!state_->add_to_pwdtmp(path.size(), comp)) {
      return std::nullopt;
    }
  }

  if (!state_->readblock(blockindex, dir.block_)) {
    return std::nullopt;
  }
  dir.stop_blockindex_ =
      detail::b4_to_u32(std::span<const std::uint8_t, 4>(dir.block_.data() + 12 + 1 + 14 + 4, 4));
  dir.offset_ =
      detail::b2_to_u16(std::span<const std::uint8_t, 2>(dir.block_.data() + 12 + 1 + 14 + 4 + 4, 2));
  dir.blockindex_ = blockindex;
  dir.searchindex_ = 0;
  dir.absolute_path_ = state_->pwd_tmp;
  dir.open_ = true;
  return dir;
}

std::optional<Dirent> FileSystem::readdir(Directory& dir) {
  if (!state_ || !state_->mounted() || !dir.open_) {
    return std::nullopt;
  }

  auto* block = dir.block_.data();
  int k = detail::BlockHead + dir.searchindex_ * 25;
  if (dir.blockindex_ == dir.stop_blockindex_ && k + 1 >= static_cast<int>(dir.offset_)) {
    return std::nullopt;
  }

  for (;;) {
    if (dir.searchindex_ >= detail::BlockItemMaxCount) {
      const std::uint32_t nextindex = detail::b4_to_u32(std::span<const std::uint8_t, 4>(block + 4, 4));
      if (nextindex == 0U || !state_->readblock(nextindex, dir.block_)) {
        return std::nullopt;
      }
      block = dir.block_.data();
      dir.searchindex_ = 0;
      dir.blockindex_ = nextindex;
      k = detail::BlockHead;
      continue;
    }

    const std::uint8_t state = block[k];
    ++k;
    dir.dirent_.type = (state & 0x01U) == 1U ? DirType::File : DirType::Dir;
    std::fill(dir.dirent_.name.begin(), dir.dirent_.name.end(), '\0');
    std::memcpy(dir.dirent_.name.data(), block + k, BlockNameMaxSize);
    k += static_cast<int>(BlockNameMaxSize);
    const std::string_view name = dir.dirent_.name_view();
    dir.dirent_.namelen = name.size();
    if (name == ".") {
      const std::uint32_t dirblockindex = detail::b4_to_u32(std::span<const std::uint8_t, 4>(block + k, 4));
      if (dirblockindex == 1U) {
        dir.dirent_.type = DirType::Root;
      }
    } else if (name == "..") {
      const std::uint32_t dirblockindex = detail::b4_to_u32(std::span<const std::uint8_t, 4>(block + k, 4));
      if (dirblockindex == 0U) {
        dir.dirent_.type = DirType::Root;
      }
    }
    k += 10;
    ++dir.searchindex_;
    return dir.dirent_;
  }
}

void FileSystem::closedir(Directory& d) noexcept { d.open_ = false; }

}  // namespace filefs
