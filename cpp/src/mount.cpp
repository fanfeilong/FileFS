#include "types.hpp"

#include "util.hpp"

#include <algorithm>
#include <filesystem>

namespace filefs {

FileSystem::FileSystem() : state_(std::make_unique<detail::FileSystemState>()) {}

FileSystem::~FileSystem() = default;
FileSystem::FileSystem(FileSystem&&) noexcept = default;
FileSystem& FileSystem::operator=(FileSystem&&) noexcept = default;

bool FileSystem::mkfs(std::string_view path) {
  const auto filename = detail::to_string(path);
  detail::CFile fp;
  fp.reset(std::fopen(filename.c_str(), "w+b"));
  if (!fp) {
    return false;
  }

  detail::Block block{};

  int k = 0;
  std::copy(detail::MagicNumber.begin(), detail::MagicNumber.end(), block.begin() + k);
  k += 4;
  detail::u32_to_b4(2U, std::span<std::uint8_t, 4>(block.data() + k, 4));

  if (!detail::write_exact(fp.get(), block.data(), block.size())) {
    return false;
  }

  block.fill(0U);
  k = 12;

  block[k] = 0U;
  ++k;
  block[k] = static_cast<std::uint8_t>('.');
  k += static_cast<int>(BlockNameMaxSize);
  detail::u32_to_b4(1U, std::span<std::uint8_t, 4>(block.data() + k, 4));
  k += 4;
  detail::u32_to_b4(1U, std::span<std::uint8_t, 4>(block.data() + k, 4));
  k += 4;
  detail::u16_to_b2(static_cast<std::uint16_t>(4 + 4 + 4 + 25 + 25),
                    std::span<std::uint8_t, 2>(block.data() + k, 2));
  k += 2;

  block[k] = 0U;
  ++k;
  block[k] = static_cast<std::uint8_t>('.');
  block[k + 1] = static_cast<std::uint8_t>('.');

  if (!detail::write_exact(fp.get(), block.data(), block.size())) {
    return false;
  }

  detail::flush_file(fp.get());
  detail::remove_if_exists(filename + "-j");
  return true;
}

bool FileSystem::mount(std::string_view path) {
  if (!state_) {
    state_ = std::make_unique<detail::FileSystemState>();
  }

  const auto filename = detail::to_string(path);
  detail::CFile fp;
  fp.reset(std::fopen(filename.c_str(), "r+b"));
  if (!fp) {
    return false;
  }

  detail::Block block{};
  if (!detail::read_exact(fp.get(), block.data(), block.size())) {
    return false;
  }

  if (!std::equal(detail::MagicNumber.begin(), detail::MagicNumber.end(), block.begin())) {
    return false;
  }
  if (detail::b4_to_u32(std::span<const std::uint8_t, 4>(block.data() + 4, 4)) < 2U) {
    return false;
  }

  if (!detail::read_exact(fp.get(), block.data(), block.size())) {
    return false;
  }

  int k = 12;
  if (block[k] != 0U) {
    return false;
  }
  ++k;
  if (detail::fixed_cstr(std::span<const std::uint8_t>(block.data() + k, BlockNameMaxSize)) != ".") {
    return false;
  }
  k += static_cast<int>(BlockNameMaxSize) + 4 + 4 + 2;
  if (block[k] != 0U) {
    return false;
  }
  ++k;
  if (detail::fixed_cstr(std::span<const std::uint8_t>(block.data() + k, BlockNameMaxSize)) != "..") {
    return false;
  }

  state_->reset();
  state_->fp = std::move(fp);
  state_->fn = filename;
  state_->fnj = filename + "-j";
  state_->pwd = "/";
  state_->pwd_blockindex = 1U;
  state_->j2ffs();
  return true;
}

void FileSystem::umount() noexcept {
  if (state_) {
    state_->reset();
  }
}

bool FileSystem::is_mounted() const noexcept { return state_ && state_->mounted(); }

}  // namespace filefs
