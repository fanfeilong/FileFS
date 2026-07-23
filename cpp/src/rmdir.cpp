#include "types.hpp"

#include "util.hpp"

#include <algorithm>

namespace filefs {

int FileSystem::rmdir(const std::string_view pathname) {
  if (!state_ || !state_->mounted() || pathname.empty()) {
    return 1;
  }

  std::uint32_t blockindex = 0U;
  int start = 0;
  if (pathname.front() == '/') {
    blockindex = 1U;
    start = 1;
  } else if (state_->tmp.state == 0U) {
    blockindex = state_->pwd_blockindex;
  } else {
    blockindex = state_->tmp.pwd_blockindex;
  }

  std::array<char, BlockNameMaxSize + 2> s{};
  int slen = 0;
  for (int i = start; i < static_cast<int>(pathname.size()); ++i) {
    if (pathname[static_cast<std::size_t>(i)] == '/') {
      if (slen == 0) {
        continue;
      }
      if (i == static_cast<int>(pathname.size()) - 1) {
        break;
      }
      const std::uint32_t index =
          state_->find_path_blockindex(blockindex, std::string_view{s.data(), static_cast<std::size_t>(slen)});
      if (index < 1U) {
        return 3;
      }
      blockindex = index;
      slen = 0;
      continue;
    }
    s[static_cast<std::size_t>(slen++)] = pathname[static_cast<std::size_t>(i)];
    if (slen > static_cast<int>(BlockNameMaxSize)) {
      return 4;
    }
  }
  if (slen > static_cast<int>(BlockNameMaxSize)) {
    return 4;
  }
  const std::string_view lastname{s.data(), static_cast<std::size_t>(slen)};
  if (lastname == "." || lastname == "..") {
    return 1;
  }

  std::array<detail::BlockArray, 4> ba{};
  int ba_used = 0;
  detail::Block* block_head = nullptr;
  detail::Block* block_last = nullptr;
  detail::Block* block_item = nullptr;
  detail::Block* block_prev = nullptr;
  std::uint32_t block_item_index = 0U;
  std::uint32_t block_last_index = 0U;
  std::uint32_t block_prev_index = 0U;
  std::uint32_t block_head_index = 0U;

  detail::Block block{};
  if (!state_->readblock(blockindex, block)) {
    return 1;
  }
  ba[0].block = block;
  ba[0].blockindex = blockindex;
  ba[0].active = 1U;
  block_head = &ba[0].block;
  block_head_index = blockindex;
  ba_used = 1;

  const std::uint32_t stop_blockindex =
      detail::b4_to_u32(std::span<const std::uint8_t, 4>(block_head->data() + 12 + 1 + 14 + 4, 4));
  std::uint16_t offset =
      detail::b2_to_u16(std::span<const std::uint8_t, 2>(block_head->data() + 12 + 1 + 14 + 4 + 4, 2));

  if (stop_blockindex == block_head_index) {
    block_last = block_head;
    block_last_index = block_head_index;
  } else {
    if (!state_->readblock(stop_blockindex, ba[1].block)) {
      return 1;
    }
    ba[1].blockindex = stop_blockindex;
    ba[1].active = 1U;
    block_last = &ba[1].block;
    block_last_index = stop_blockindex;
    ++ba_used;
  }

  std::uint32_t subdir_blockindex = 0U;
  detail::Block subdir_block{};
  std::uint16_t item_offset = 0U;
  bool flag = false;
  std::uint32_t index = block_head_index;
  for (;;) {
    int k = detail::BlockHead;
    for (int i = 0; i < detail::BlockItemMaxCount; ++i) {
      const std::uint8_t state = block[static_cast<std::size_t>(k)];
      ++k;
      const bool name_match =
          detail::fixed_cstr(std::span<const std::uint8_t>(block.data() + k, BlockNameMaxSize)) == lastname;
      k += static_cast<int>(BlockNameMaxSize);
      if (!name_match) {
        k += 10;
        if (index == stop_blockindex && k + 1 >= static_cast<int>(offset)) {
          return 3;
        }
        continue;
      }
      if ((state & 0x01U) == 1U) {
        return 3;
      }
      subdir_blockindex = detail::b4_to_u32(std::span<const std::uint8_t, 4>(block.data() + k, 4));
      if (!state_->readblock(subdir_blockindex, subdir_block)) {
        return 1;
      }
      const std::uint32_t subdir_start =
          detail::b4_to_u32(std::span<const std::uint8_t, 4>(subdir_block.data() + detail::BlockStartBlockindex, 4));
      const std::uint32_t subdir_stop =
          detail::b4_to_u32(std::span<const std::uint8_t, 4>(subdir_block.data() + detail::BlockStopBlockindex, 4));
      const std::uint16_t subdir_offset =
          detail::b2_to_u16(std::span<const std::uint8_t, 2>(subdir_block.data() + detail::BlockOffset, 2));
      if (subdir_stop != subdir_start || subdir_offset > 62U) {
        return 2;
      }

      item_offset = static_cast<std::uint16_t>(k + 10);
      bool reused = false;
      for (int j = 0; j < ba_used; ++j) {
        if (ba[j].blockindex == index) {
          block_item = &ba[j].block;
          block_item_index = index;
          reused = true;
          break;
        }
      }
      if (!reused) {
        ba[ba_used].block = block;
        ba[ba_used].blockindex = index;
        ba[ba_used].active = 1U;
        block_item = &ba[ba_used].block;
        block_item_index = index;
        ++ba_used;
      }
      flag = true;
      break;
    }
    if (flag) {
      break;
    }
    index = detail::b4_to_u32(std::span<const std::uint8_t, 4>(block.data() + 4, 4));
    if (index == 0U || !state_->readblock(index, block)) {
      return 1;
    }
  }

  if (state_->tmp.state == 0U && !state_->tmpstart(1U)) {
    return 1;
  }
  if (!state_->removeblock(subdir_blockindex)) {
    if (state_->tmp.state == 1U) {
      state_->tmpstop();
    }
    return 1;
  }

  if (block_item_index != stop_blockindex || item_offset != offset) {
    std::copy_n(block_last->data() + offset - 25, 25, block_item->data() + item_offset - 25);
  }
  offset = static_cast<std::uint16_t>(offset - 25);
  std::array<std::uint8_t, 2> b2{};
  detail::u16_to_b2(offset, b2);
  std::copy(b2.begin(), b2.end(), block_head->begin() + detail::BlockOffset);

  if (offset < 25U) {
    block_prev_index = detail::b4_to_u32(std::span<const std::uint8_t, 4>(block_last->data() + 8, 4));
    if (!state_->removeblock(block_last_index)) {
      if (state_->tmp.state == 1U) {
        state_->tmpstop();
      }
      return 1;
    }
    int slot = -1;
    for (int i = 0; i < ba_used; ++i) {
      if (ba[i].blockindex == block_last_index) {
        ba[i].active = 0U;
        slot = i;
        break;
      }
    }
    if (slot < 0) {
      if (state_->tmp.state == 1U) {
        state_->tmpstop();
      }
      return 1;
    }
    bool reused = false;
    for (int i = 0; i < ba_used; ++i) {
      if (ba[i].blockindex == block_prev_index) {
        block_prev = &ba[i].block;
        reused = true;
        break;
      }
    }
    if (!reused) {
      if (!state_->readblock(block_prev_index, block)) {
        if (state_->tmp.state == 1U) {
          state_->tmpstop();
        }
        return 1;
      }
      ba[slot].block = block;
      ba[slot].blockindex = block_prev_index;
      ba[slot].active = 1U;
      block_prev = &ba[slot].block;
    }
    std::fill_n(block_prev->data() + 4, 4, 0U);
    detail::u32_to_b4(block_prev_index, std::span<std::uint8_t, 4>(block_head->data() + detail::BlockStopBlockindex, 4));
    offset = BlockSize;
    detail::u16_to_b2(offset, b2);
    std::copy(b2.begin(), b2.end(), block_head->begin() + detail::BlockOffset);
  }

  for (int i = 0; i < ba_used; ++i) {
    if (ba[i].active != 0U && !state_->writeblock(ba[i].blockindex, ba[i].block)) {
      if (state_->tmp.state == 1U) {
        state_->tmpstop();
      }
      return 1;
    }
  }
  if (state_->tmp.state == 1U && !state_->commit()) {
    return 1;
  }
  return 0;
}

}  // namespace filefs
