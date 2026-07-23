#include "types.hpp"

#include "util.hpp"

#include <algorithm>

namespace filefs::detail {

std::uint32_t FileSystemState::genblockindex() {
  Block block{};

  if (tmp.new_unused_blockhead > 0U) {
    const std::uint32_t blockindex = tmp.new_unused_blockhead;
    if (!readblock(blockindex, block)) {
      return 0U;
    }
    tmp.new_unused_blockhead = b4_to_u32(std::span<const std::uint8_t, 4>(block.data() + 4, 4));
    return blockindex;
  }

  const std::uint32_t blockindex = tmp.new_total_blocksize;
  const std::uint32_t addindex = blockindex - tmp.total_blocksize;
  const std::uint64_t pos = static_cast<std::uint64_t>(addindex) * static_cast<std::uint64_t>(4 + BlockSize);
  if (!set_pos(tmp.fp_add.get(), pos)) {
    return 0U;
  }

  std::array<std::uint8_t, 4> b4{};
  u32_to_b4(blockindex, b4);
  if (!write_exact(tmp.fp_add.get(), b4.data(), b4.size()) ||
      !write_exact(tmp.fp_add.get(), block.data(), block.size())) {
    return 0U;
  }
  ++tmp.new_total_blocksize;
  return blockindex;
}

bool FileSystemState::readblock(const std::uint32_t blockindex, Block& block) {
  std::uint64_t pos = static_cast<std::uint64_t>(blockindex) * BlockSize;
  if (!set_pos(fp.get(), pos)) {
    return false;
  }

  std::array<std::uint8_t, 4> buf{};
  if (!read_exact(fp.get(), buf.data(), buf.size())) {
    if (tmp.state == 0U || blockindex < tmp.total_blocksize) {
      return false;
    }
    const std::uint32_t addindex = blockindex - tmp.total_blocksize;
    pos = static_cast<std::uint64_t>(addindex) * static_cast<std::uint64_t>(BlockSize + 4) + 4U;
    if (!set_pos(tmp.fp_add.get(), pos)) {
      return false;
    }
    return read_exact(tmp.fp_add.get(), block.data(), block.size());
  }

  if (tmp.state == 0U) {
    std::copy(buf.begin(), buf.end(), block.begin());
    return read_exact(fp.get(), block.data() + 4, block.size() - 4);
  }

  std::uint32_t cpindex = b4_to_u32(buf);
  pos = static_cast<std::uint64_t>(cpindex) * static_cast<std::uint64_t>(BlockSize + 4);
  if (!set_pos(tmp.fp_cp.get(), pos)) {
    return false;
  }

  std::array<std::uint8_t, 4> b4{};
  if (!read_exact(tmp.fp_cp.get(), b4.data(), b4.size())) {
    std::copy(buf.begin(), buf.end(), block.begin());
    return read_exact(fp.get(), block.data() + 4, block.size() - 4);
  }
  if (b4_to_u32(b4) != blockindex) {
    std::copy(buf.begin(), buf.end(), block.begin());
    return read_exact(fp.get(), block.data() + 4, block.size() - 4);
  }
  return read_exact(tmp.fp_cp.get(), block.data(), block.size());
}

bool FileSystemState::writeblock(const std::uint32_t blockindex, const Block& block) {
  if (tmp.state == 0U) {
    return false;
  }

  std::uint64_t pos = static_cast<std::uint64_t>(blockindex) * BlockSize;
  if (!set_pos(fp.get(), pos)) {
    return false;
  }

  std::array<std::uint8_t, 4> buf{};
  if (!read_exact(fp.get(), buf.data(), buf.size())) {
    if (blockindex < tmp.total_blocksize) {
      return false;
    }
    const std::uint32_t addindex = blockindex - tmp.total_blocksize;
    pos = static_cast<std::uint64_t>(addindex) * static_cast<std::uint64_t>(BlockSize + 4) + 4U;
    if (!set_pos(tmp.fp_add.get(), pos)) {
      return false;
    }
    return write_exact(tmp.fp_add.get(), block.data(), block.size());
  }

  std::array<std::uint8_t, 4> b4{};
  std::uint32_t cpindex = b4_to_u32(buf);
  pos = static_cast<std::uint64_t>(cpindex) * static_cast<std::uint64_t>(BlockSize + 4);
  if (!set_pos(tmp.fp_cp.get(), pos)) {
    return false;
  }

  if (!read_exact(tmp.fp_cp.get(), b4.data(), b4.size())) {
    cpindex = tmp.cp_size;
    pos = static_cast<std::uint64_t>(cpindex) * static_cast<std::uint64_t>(BlockSize + 4);
    if (!set_pos(tmp.fp_cp.get(), pos)) {
      return false;
    }
    u32_to_b4(blockindex, b4);
    if (!write_exact(tmp.fp_cp.get(), b4.data(), b4.size()) ||
        !write_exact(tmp.fp_cp.get(), block.data(), block.size())) {
      return false;
    }

    pos = static_cast<std::uint64_t>(blockindex) * BlockSize;
    if (!set_pos(fp.get(), pos)) {
      return false;
    }
    u32_to_b4(cpindex, b4);
    if (!write_exact(fp.get(), b4.data(), b4.size())) {
      return false;
    }
    ++tmp.cp_size;
    return true;
  }

  if (b4_to_u32(b4) != blockindex) {
    cpindex = tmp.cp_size;
    pos = static_cast<std::uint64_t>(cpindex) * static_cast<std::uint64_t>(BlockSize + 4);
    if (!set_pos(tmp.fp_cp.get(), pos)) {
      return false;
    }
    u32_to_b4(blockindex, b4);
    if (!write_exact(tmp.fp_cp.get(), b4.data(), b4.size()) ||
        !write_exact(tmp.fp_cp.get(), block.data(), block.size())) {
      return false;
    }

    pos = static_cast<std::uint64_t>(blockindex) * BlockSize;
    if (!set_pos(fp.get(), pos)) {
      return false;
    }
    u32_to_b4(cpindex, b4);
    if (!write_exact(fp.get(), b4.data(), b4.size())) {
      return false;
    }
    ++tmp.cp_size;
    return true;
  }

  pos = static_cast<std::uint64_t>(cpindex) * static_cast<std::uint64_t>(BlockSize + 4) + 4U;
  if (!set_pos(tmp.fp_cp.get(), pos)) {
    return false;
  }
  return write_exact(tmp.fp_cp.get(), block.data(), block.size());
}

bool FileSystemState::removeblock(const std::uint32_t blockindex) {
  if (tmp.state == 0U) {
    return false;
  }

  std::uint64_t pos = static_cast<std::uint64_t>(blockindex) * BlockSize;
  if (!set_pos(fp.get(), pos)) {
    return false;
  }

  std::array<std::uint8_t, 4> buf{};
  if (!read_exact(fp.get(), buf.data(), buf.size())) {
    if (blockindex < tmp.total_blocksize) {
      return false;
    }
    const std::uint32_t addindex = blockindex - tmp.total_blocksize;
    pos = static_cast<std::uint64_t>(addindex) * static_cast<std::uint64_t>(BlockSize + 4) + 8U;
    if (!set_pos(tmp.fp_add.get(), pos)) {
      return false;
    }
    std::array<std::uint8_t, 4> b4{};
    u32_to_b4(tmp.new_unused_blockhead, b4);
    if (!write_exact(tmp.fp_add.get(), b4.data(), b4.size())) {
      return false;
    }
    tmp.new_unused_blockhead = blockindex;
    return true;
  }

  std::array<std::uint8_t, 4> b4{};
  std::uint32_t cpindex = b4_to_u32(buf);
  pos = static_cast<std::uint64_t>(cpindex) * static_cast<std::uint64_t>(BlockSize + 4);
  if (!set_pos(tmp.fp_cp.get(), pos)) {
    return false;
  }

  if (!read_exact(tmp.fp_cp.get(), b4.data(), b4.size())) {
    cpindex = tmp.cp_size;
    pos = static_cast<std::uint64_t>(cpindex) * static_cast<std::uint64_t>(BlockSize + 4);
    if (!set_pos(tmp.fp_cp.get(), pos)) {
      return false;
    }
    u32_to_b4(blockindex, b4);
    if (!write_exact(tmp.fp_cp.get(), b4.data(), b4.size())) {
      return false;
    }
    Block block{};
    u32_to_b4(tmp.new_unused_blockhead, std::span<std::uint8_t, 4>(block.data(), 4));
    if (!write_exact(tmp.fp_cp.get(), block.data(), block.size())) {
      return false;
    }

    pos = static_cast<std::uint64_t>(blockindex) * BlockSize;
    if (!set_pos(fp.get(), pos)) {
      return false;
    }
    u32_to_b4(cpindex, b4);
    if (!write_exact(fp.get(), b4.data(), b4.size())) {
      return false;
    }
    ++tmp.cp_size;
    tmp.new_unused_blockhead = blockindex;
    return true;
  }

  if (b4_to_u32(b4) != blockindex) {
    cpindex = tmp.cp_size;
    pos = static_cast<std::uint64_t>(cpindex) * static_cast<std::uint64_t>(BlockSize + 4);
    if (!set_pos(tmp.fp_cp.get(), pos)) {
      return false;
    }
    u32_to_b4(blockindex, b4);
    if (!write_exact(tmp.fp_cp.get(), b4.data(), b4.size())) {
      return false;
    }
    Block block{};
    u32_to_b4(tmp.new_unused_blockhead, std::span<std::uint8_t, 4>(block.data(), 4));
    if (!write_exact(tmp.fp_cp.get(), block.data(), block.size())) {
      return false;
    }

    pos = static_cast<std::uint64_t>(blockindex) * BlockSize;
    if (!set_pos(fp.get(), pos)) {
      return false;
    }
    u32_to_b4(cpindex, b4);
    if (!write_exact(fp.get(), b4.data(), b4.size())) {
      return false;
    }
    ++tmp.cp_size;
    tmp.new_unused_blockhead = blockindex;
    return true;
  }

  pos += 8U;
  if (!set_pos(tmp.fp_cp.get(), pos)) {
    return false;
  }
  u32_to_b4(tmp.new_unused_blockhead, b4);
  if (!write_exact(tmp.fp_cp.get(), b4.data(), b4.size())) {
    return false;
  }
  tmp.new_unused_blockhead = blockindex;
  return true;
}

std::uint32_t FileSystemState::find_path_blockindex(std::uint32_t blockindex, const std::string_view pathname) {
  Block block{};
  std::uint32_t index = blockindex;
  std::array<std::uint8_t, 15> s{};

  if (!readblock(index, block)) {
    return 0U;
  }
  const std::uint32_t stop_blockindex =
      b4_to_u32(std::span<const std::uint8_t, 4>(block.data() + 12 + 1 + 14 + 4, 4));
  const std::uint16_t offset =
      b2_to_u16(std::span<const std::uint8_t, 2>(block.data() + 12 + 1 + 14 + 4 + 4, 2));

  for (;;) {
    int k = BlockHead;
    for (int i = 0; i < BlockItemMaxCount; ++i) {
      const std::uint8_t state = block[static_cast<std::size_t>(k)];
      ++k;
      const std::uint8_t dir_file = state & 0x01U;
      if (dir_file == 1U) {
        k += 24;
        if (index == stop_blockindex && k + 1 >= static_cast<int>(offset)) {
          return 0U;
        }
        continue;
      }

      std::copy_n(block.data() + k, BlockNameMaxSize, s.data());
      k += static_cast<int>(BlockNameMaxSize);
      if (fixed_cstr(s) != pathname) {
        k += 10;
        if (index == stop_blockindex && k + 1 >= static_cast<int>(offset)) {
          return 0U;
        }
        continue;
      }
      return b4_to_u32(std::span<const std::uint8_t, 4>(block.data() + k, 4));
    }

    index = b4_to_u32(std::span<const std::uint8_t, 4>(block.data() + 4, 4));
    if (index == 0U) {
      return 0U;
    }
    if (!readblock(index, block)) {
      return 0U;
    }
  }
}

}  // namespace filefs::detail
