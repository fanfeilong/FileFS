#include "types.hpp"

#include "util.hpp"

namespace filefs::detail {

bool FileSystemState::tmpstart(const std::uint8_t state) {
  if (state == 0U || !fp) {
    return false;
  }
  if (tmp.state != 0U) {
    tmpstop();
  }

  std::array<std::uint8_t, 12> block{};
  rewind_file(fp.get());
  if (!read_exact(fp.get(), block.data(), block.size())) {
    return false;
  }

  tmp.total_blocksize = b4_to_u32(std::span<const std::uint8_t, 4>(block.data() + 4, 4));
  tmp.unused_blockhead = b4_to_u32(std::span<const std::uint8_t, 4>(block.data() + 8, 4));
  tmp.new_total_blocksize = tmp.total_blocksize;
  tmp.new_unused_blockhead = tmp.unused_blockhead;

  if (!create_temp_file("filefs-cp-", tmp.fp_cp, tmp.cp_path)) {
    return false;
  }
  if (!create_temp_file("filefs-add-", tmp.fp_add, tmp.add_path)) {
    tmp.fp_cp.reset();
    remove_if_exists(tmp.cp_path);
    tmp.cp_path.clear();
    return false;
  }

  tmp.pwd = pwd;
  tmp.pwd_blockindex = pwd_blockindex;
  tmp.cp_size = 0U;
  tmp.state = state;
  return true;
}

void FileSystemState::tmpstop() noexcept {
  tmp.fp_cp.reset();
  remove_if_exists(tmp.cp_path);
  tmp.cp_path.clear();

  tmp.fp_add.reset();
  remove_if_exists(tmp.add_path);
  tmp.add_path.clear();

  tmp.cp_size = 0U;
  tmp.state = 0U;
}

void FileSystemState::rollback() noexcept {
  remove_if_exists(fnj);
  if (tmp.fp_cp) {
    tmpstop();
  }
}

bool FileSystemState::commit() {
  if (!fp || !tmp.fp_cp) {
    return true;
  }

  CFile journal_fp;
  journal_fp.reset(std::fopen(fnj.c_str(), "w+b"));
  if (!journal_fp) {
    tmpstop();
    return false;
  }

  std::uint8_t signal = 0U;
  if (!write_exact(journal_fp.get(), &signal, 1U)) {
    tmpstop();
    return false;
  }

  std::array<std::uint8_t, 4> b4{};
  std::array<std::uint8_t, BlockSize + 4> block{};

  if (tmp.total_blocksize != tmp.new_total_blocksize || tmp.unused_blockhead != tmp.new_unused_blockhead) {
    b4.fill(0U);
    if (!write_exact(journal_fp.get(), b4.data(), b4.size())) {
      tmpstop();
      return false;
    }

    block.fill(0U);
    int k = 0;
    std::copy(MagicNumber.begin(), MagicNumber.end(), block.begin() + k);
    k += 4;
    u32_to_b4(tmp.new_total_blocksize, std::span<std::uint8_t, 4>(block.data() + k, 4));
    k += 4;
    u32_to_b4(tmp.new_unused_blockhead, std::span<std::uint8_t, 4>(block.data() + k, 4));
    if (!write_exact(journal_fp.get(), block.data(), BlockSize)) {
      tmpstop();
      return false;
    }
  }

  rewind_file(tmp.fp_cp.get());
  while (read_exact(tmp.fp_cp.get(), block.data(), block.size())) {
    if (!write_exact(journal_fp.get(), block.data(), block.size())) {
      tmpstop();
      return false;
    }
  }

  rewind_file(tmp.fp_add.get());
  while (read_exact(tmp.fp_add.get(), block.data(), block.size())) {
    if (!write_exact(journal_fp.get(), block.data(), block.size())) {
      tmpstop();
      return false;
    }
  }

  rewind_file(journal_fp.get());
  signal = 0xffU;
  if (!write_exact(journal_fp.get(), &signal, 1U)) {
    tmpstop();
    return false;
  }
  flush_file(journal_fp.get());
  journal_fp.reset();

  journal_fp.reset(std::fopen(fnj.c_str(), "rb"));
  if (!journal_fp) {
    tmpstop();
    return false;
  }
  if (!read_exact(journal_fp.get(), &signal, 1U)) {
    tmpstop();
    return false;
  }

  while (read_exact(journal_fp.get(), block.data(), block.size())) {
    const std::uint32_t blockindex = b4_to_u32(std::span<const std::uint8_t, 4>(block.data(), 4));
    const std::uint64_t pos = static_cast<std::uint64_t>(blockindex) * BlockSize;
    if (!set_pos(fp.get(), pos) || !write_exact(fp.get(), block.data() + 4, BlockSize)) {
      tmpstop();
      return false;
    }
  }

  flush_file(fp.get());
  remove_if_exists(fnj);

  pwd = tmp.pwd;
  pwd_blockindex = tmp.pwd_blockindex;
  tmpstop();
  return true;
}

}  // namespace filefs::detail

namespace filefs {

bool FileSystem::begin() {
  if (!state_ || !state_->mounted()) {
    return false;
  }
  if (state_->tmp.fp_cp) {
    state_->rollback();
  }
  return state_->tmpstart(2U);
}

bool FileSystem::commit() {
  if (!state_ || !state_->mounted()) {
    return true;
  }
  return state_->commit();
}

void FileSystem::rollback() noexcept {
  if (state_ && state_->mounted()) {
    state_->rollback();
  }
}

}  // namespace filefs
