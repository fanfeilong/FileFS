#include "types.hpp"

#include "util.hpp"

#include <algorithm>

namespace filefs::detail {

std::optional<File> FileSystemState::do_fopen_r(const std::string_view lastname, const std::uint8_t mode,
                                                const std::uint32_t block_head_index) {
  Block block{};
  if (!readblock(block_head_index, block)) {
    return std::nullopt;
  }

  const std::uint32_t stop_blockindex =
      b4_to_u32(std::span<const std::uint8_t, 4>(block.data() + 12 + 1 + 14 + 4, 4));
  const std::uint16_t offset =
      b2_to_u16(std::span<const std::uint8_t, 2>(block.data() + 12 + 1 + 14 + 4 + 4, 2));

  bool found = false;
  std::uint32_t dir_blockindex = 0U;
  std::uint16_t dir_offset = 0U;
  std::uint32_t index = block_head_index;

  for (;;) {
    int k = BlockHead;
    for (int i = 0; i < BlockItemMaxCount; ++i) {
      const std::uint8_t state = block[static_cast<std::size_t>(k)];
      ++k;
      const bool name_match =
          fixed_cstr(std::span<const std::uint8_t>(block.data() + k, BlockNameMaxSize)) == lastname;
      k += static_cast<int>(BlockNameMaxSize);
      if (!name_match) {
        k += 10;
        if (index == stop_blockindex && k + 1 >= static_cast<int>(offset)) {
          return std::nullopt;
        }
        continue;
      }
      if ((state & 0x01U) == 0U) {
        return std::nullopt;
      }
      dir_blockindex = index;
      dir_offset = static_cast<std::uint16_t>(k + 10);
      found = true;
      break;
    }
    if (found) {
      break;
    }
    index = b4_to_u32(std::span<const std::uint8_t, 4>(block.data() + 4, 4));
    if (index == 0U || !readblock(index, block)) {
      return std::nullopt;
    }
  }

  File file;
  file.mode_ = mode;
  file.dir_blockindex_ = dir_blockindex;
  file.dir_offset_ = dir_offset;
  file.file_start_blockindex_ =
      b4_to_u32(std::span<const std::uint8_t, 4>(block.data() + dir_offset - 10, 4));
  file.file_stop_blockindex_ =
      b4_to_u32(std::span<const std::uint8_t, 4>(block.data() + dir_offset - 6, 4));
  file.file_offset_ = b2_to_u16(std::span<const std::uint8_t, 2>(block.data() + dir_offset - 2, 2));
  file.pos_blockindex_ = file.file_start_blockindex_;
  file.pos_offset_ = static_cast<std::uint16_t>(BlockHead);
  file.pos_ = 0U;
  file.open_ = true;
  return file;
}

bool FileSystemState::do_fopen_createfileitem(const std::string_view lastname,
                                              const std::uint32_t org_start_blockindex,
                                              const std::uint32_t org_stop_blockindex,
                                              const std::uint16_t org_offset, Block& dir_block,
                                              std::uint32_t& dir_blockindex, std::uint16_t& dir_offset) {
  std::array<std::uint8_t, 2> b2{};
  std::array<BlockArray, 2> ba{};
  Block* block_start = nullptr;
  Block* block_stop = nullptr;
  std::uint32_t block_start_index = 0U;
  std::uint32_t block_stop_index = 0U;

  if (!readblock(org_start_blockindex, ba[0].block)) {
    return false;
  }
  ba[0].blockindex = org_start_blockindex;
  ba[0].active = 1U;
  block_start = &ba[0].block;
  block_start_index = ba[0].blockindex;

  if (org_stop_blockindex == org_start_blockindex) {
    block_stop = block_start;
    block_stop_index = block_start_index;
  } else {
    if (!readblock(org_stop_blockindex, ba[1].block)) {
      return false;
    }
    ba[1].blockindex = org_stop_blockindex;
    ba[1].active = 1U;
    block_stop = &ba[1].block;
    block_stop_index = ba[1].blockindex;
  }

  if (tmp.state == 0U && !tmpstart(1U)) {
    return false;
  }

  if (org_offset < BlockSize) {
    int k = static_cast<int>(org_offset);
    (*block_stop)[static_cast<std::size_t>(k)] = 1U;
    ++k;
    std::fill_n(block_stop->data() + k, BlockNameMaxSize, 0U);
    std::memcpy(block_stop->data() + k, lastname.data(), lastname.size());
    k += static_cast<int>(BlockNameMaxSize);
    k += 4 + 4 + 2;
    const std::uint16_t new_offset = static_cast<std::uint16_t>(k);
    u16_to_b2(new_offset, b2);
    std::copy(b2.begin(), b2.end(), block_start->begin() + BlockOffset);

    for (auto& entry : ba) {
      if (entry.active != 0U && !writeblock(entry.blockindex, entry.block)) {
        if (tmp.state == 1U) {
          tmpstop();
        }
        return false;
      }
    }
    if (tmp.state == 1U && !commit()) {
      return false;
    }

    dir_block = *block_stop;
    dir_blockindex = block_stop_index;
    dir_offset = new_offset;
    return true;
  }

  const std::uint32_t blockindex2 = genblockindex();
  if (blockindex2 == 0U) {
    if (tmp.state == 1U) {
      tmpstop();
    }
    return false;
  }

  Block block2{};
  int k = 8;
  u32_to_b4(org_stop_blockindex, std::span<std::uint8_t, 4>(block2.data() + k, 4));
  k += 4;
  block2[static_cast<std::size_t>(k)] = 1U;
  ++k;
  std::fill_n(block2.data() + k, BlockNameMaxSize, 0U);
  std::memcpy(block2.data() + k, lastname.data(), lastname.size());
  k += static_cast<int>(BlockNameMaxSize);
  k += 4 + 4 + 2;
  const std::uint16_t new_offset = static_cast<std::uint16_t>(k);
  u16_to_b2(new_offset, b2);
  std::copy(b2.begin(), b2.end(), block_start->begin() + BlockOffset);
  u32_to_b4(blockindex2, std::span<std::uint8_t, 4>(block_start->data() + BlockStopBlockindex, 4));
  u32_to_b4(blockindex2, std::span<std::uint8_t, 4>(block_stop->data() + 4, 4));

  for (auto& entry : ba) {
    if (entry.active != 0U && !writeblock(entry.blockindex, entry.block)) {
      if (tmp.state == 1U) {
        tmpstop();
      }
      return false;
    }
  }
  if (tmp.state == 1U && !commit()) {
    return false;
  }

  dir_block = block2;
  dir_blockindex = blockindex2;
  dir_offset = new_offset;
  return true;
}

bool FileSystemState::do_fopen_cleanfilecontent(Block& dir_block, const std::uint32_t dir_blockindex,
                                                const std::uint16_t dir_offset) {
  const std::uint32_t file_start =
      b4_to_u32(std::span<const std::uint8_t, 4>(dir_block.data() + dir_offset - 10, 4));
  const std::uint32_t file_stop =
      b4_to_u32(std::span<const std::uint8_t, 4>(dir_block.data() + dir_offset - 6, 4));
  if (file_start == 0U) {
    return true;
  }

  if (tmp.state == 0U && !tmpstart(1U)) {
    return false;
  }

  Block file_block_stop{};
  if (!readblock(file_stop, file_block_stop)) {
    if (tmp.state == 1U) {
      tmpstop();
    }
    return false;
  }

  u32_to_b4(tmp.new_unused_blockhead, std::span<std::uint8_t, 4>(file_block_stop.data() + 4, 4));
  tmp.new_unused_blockhead = file_start;
  std::fill_n(dir_block.data() + dir_offset - 10, 10, 0U);

  if (!writeblock(dir_blockindex, dir_block) || !writeblock(file_stop, file_block_stop)) {
    if (tmp.state == 1U) {
      tmpstop();
    }
    return false;
  }
  if (tmp.state == 1U && !commit()) {
    return false;
  }
  return true;
}

std::optional<File> FileSystemState::do_fopen_w(const std::string_view lastname, const std::uint8_t mode,
                                                const std::uint32_t block_head_index) {
  Block block{};
  if (!readblock(block_head_index, block)) {
    return std::nullopt;
  }

  const std::uint32_t stop_blockindex =
      b4_to_u32(std::span<const std::uint8_t, 4>(block.data() + 12 + 1 + 14 + 4, 4));
  const std::uint16_t offset =
      b2_to_u16(std::span<const std::uint8_t, 2>(block.data() + 12 + 1 + 14 + 4 + 4, 2));

  bool found = false;
  bool dir_exists = false;
  std::uint32_t dir_blockindex = 0U;
  std::uint16_t dir_offset = 0U;
  std::uint32_t index = block_head_index;

  for (;;) {
    int k = BlockHead;
    for (int i = 0; i < BlockItemMaxCount; ++i) {
      const std::uint8_t state = block[static_cast<std::size_t>(k)];
      ++k;
      const bool name_match =
          fixed_cstr(std::span<const std::uint8_t>(block.data() + k, BlockNameMaxSize)) == lastname;
      k += static_cast<int>(BlockNameMaxSize);
      if (!name_match) {
        k += 10;
        if (index == stop_blockindex && k + 1 >= static_cast<int>(offset)) {
          found = true;
          break;
        }
        continue;
      }
      if ((state & 0x01U) == 0U) {
        return std::nullopt;
      }
      dir_blockindex = index;
      dir_offset = static_cast<std::uint16_t>(k + 10);
      dir_exists = true;
      found = true;
      break;
    }
    if (found) {
      break;
    }
    index = b4_to_u32(std::span<const std::uint8_t, 4>(block.data() + 4, 4));
    if (index == 0U || !readblock(index, block)) {
      return std::nullopt;
    }
  }

  if (!dir_exists) {
    if (!do_fopen_createfileitem(lastname, block_head_index, stop_blockindex, offset, block, dir_blockindex,
                                 dir_offset)) {
      return std::nullopt;
    }
  } else if (!do_fopen_cleanfilecontent(block, dir_blockindex, dir_offset)) {
    return std::nullopt;
  }

  File file;
  file.mode_ = mode;
  file.dir_blockindex_ = dir_blockindex;
  file.dir_offset_ = dir_offset;
  file.open_ = true;
  return file;
}

std::optional<File> FileSystemState::do_fopen_a(const std::string_view lastname, const std::uint8_t mode,
                                                const std::uint32_t block_head_index) {
  Block block{};
  if (!readblock(block_head_index, block)) {
    return std::nullopt;
  }

  const std::uint32_t stop_blockindex =
      b4_to_u32(std::span<const std::uint8_t, 4>(block.data() + 12 + 1 + 14 + 4, 4));
  const std::uint16_t offset =
      b2_to_u16(std::span<const std::uint8_t, 2>(block.data() + 12 + 1 + 14 + 4 + 4, 2));

  bool found = false;
  bool dir_exists = false;
  std::uint32_t dir_blockindex = 0U;
  std::uint16_t dir_offset = 0U;
  std::uint32_t index = block_head_index;

  for (;;) {
    int k = BlockHead;
    for (int i = 0; i < BlockItemMaxCount; ++i) {
      const std::uint8_t state = block[static_cast<std::size_t>(k)];
      ++k;
      const bool name_match =
          fixed_cstr(std::span<const std::uint8_t>(block.data() + k, BlockNameMaxSize)) == lastname;
      k += static_cast<int>(BlockNameMaxSize);
      if (!name_match) {
        k += 10;
        if (index == stop_blockindex && k + 1 >= static_cast<int>(offset)) {
          found = true;
          break;
        }
        continue;
      }
      if ((state & 0x01U) == 0U) {
        return std::nullopt;
      }
      dir_blockindex = index;
      dir_offset = static_cast<std::uint16_t>(k + 10);
      dir_exists = true;
      found = true;
      break;
    }
    if (found) {
      break;
    }
    index = b4_to_u32(std::span<const std::uint8_t, 4>(block.data() + 4, 4));
    if (index == 0U || !readblock(index, block)) {
      return std::nullopt;
    }
  }

  if (!dir_exists) {
    if (!do_fopen_createfileitem(lastname, block_head_index, stop_blockindex, offset, block, dir_blockindex,
                                 dir_offset)) {
      return std::nullopt;
    }
    File file;
    file.mode_ = mode;
    file.dir_blockindex_ = dir_blockindex;
    file.dir_offset_ = dir_offset;
    file.open_ = true;
    return file;
  }

  const std::uint32_t file_start =
      b4_to_u32(std::span<const std::uint8_t, 4>(block.data() + dir_offset - 10, 4));
  const std::uint32_t file_stop =
      b4_to_u32(std::span<const std::uint8_t, 4>(block.data() + dir_offset - 6, 4));
  const std::uint16_t file_offset =
      b2_to_u16(std::span<const std::uint8_t, 2>(block.data() + dir_offset - 2, 2));

  std::uint64_t pos = 0U;
  index = file_start;
  for (;;) {
    if (index == file_stop) {
      pos += static_cast<std::uint64_t>(file_offset - BlockHead);
      break;
    }
    if (!readblock(index, block)) {
      return std::nullopt;
    }
    pos += BlockSize - BlockHead;
    index = b4_to_u32(std::span<const std::uint8_t, 4>(block.data() + 4, 4));
  }

  File file;
  file.mode_ = mode;
  file.dir_blockindex_ = dir_blockindex;
  file.dir_offset_ = dir_offset;
  file.file_start_blockindex_ = file_start;
  file.file_stop_blockindex_ = file_stop;
  file.file_offset_ = file_offset;
  file.pos_blockindex_ = file_stop;
  file.pos_offset_ = file_offset;
  file.pos_ = pos;
  file.open_ = true;
  return file;
}

}  // namespace filefs::detail
