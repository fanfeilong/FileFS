#include "types.hpp"

#include "util.hpp"

#include <algorithm>

namespace {

int do_rename(filefs::detail::FileSystemState& ffs, const std::string_view old_lastname,
              const std::uint32_t old_blockindex, const std::uint8_t old_type_dir,
              const std::string_view new_lastname, const std::uint32_t new_blockindex,
              const std::uint8_t new_type_dir) {
  using namespace filefs;

  std::array<detail::BlockArray, 4> old_ba{};
  int old_ba_used = 0;
  detail::Block* old_block_head = nullptr;
  detail::Block* old_block_last = nullptr;
  detail::Block* old_block_item = nullptr;
  detail::Block* old_block_prev = nullptr;
  std::uint32_t old_block_item_index = 0U;
  std::uint32_t old_block_last_index = 0U;
  std::uint32_t old_block_prev_index = 0U;
  std::uint32_t old_block_head_index = 0U;

  detail::Block old_block{};
  if (!ffs.readblock(old_blockindex, old_block)) {
    return 1;
  }
  old_ba[0].block = old_block;
  old_ba[0].blockindex = old_blockindex;
  old_ba[0].active = 1U;
  old_block_head = &old_ba[0].block;
  old_block_head_index = old_blockindex;
  old_ba_used = 1;

  const std::uint32_t old_stop_blockindex =
      detail::b4_to_u32(std::span<const std::uint8_t, 4>(old_block_head->data() + 12 + 1 + 14 + 4, 4));
  std::uint16_t old_offset =
      detail::b2_to_u16(std::span<const std::uint8_t, 2>(old_block_head->data() + 12 + 1 + 14 + 4 + 4, 2));

  if (old_stop_blockindex == old_block_head_index) {
    old_block_last = old_block_head;
    old_block_last_index = old_block_head_index;
  } else {
    if (!ffs.readblock(old_stop_blockindex, old_ba[1].block)) {
      return 1;
    }
    old_ba[1].blockindex = old_stop_blockindex;
    old_ba[1].active = 1U;
    old_block_last = &old_ba[1].block;
    old_block_last_index = old_stop_blockindex;
    ++old_ba_used;
  }

  std::uint16_t old_item_offset = 0U;
  std::uint8_t old_dir_file = 0U;
  bool flag = false;
  std::uint32_t index = old_block_head_index;
  for (;;) {
    int k = detail::BlockHead;
    for (int i = 0; i < detail::BlockItemMaxCount; ++i) {
      const std::uint8_t state = old_block[static_cast<std::size_t>(k)];
      ++k;
      const bool name_match =
          detail::fixed_cstr(std::span<const std::uint8_t>(old_block.data() + k, BlockNameMaxSize)) ==
          old_lastname;
      k += static_cast<int>(BlockNameMaxSize);
      if (!name_match) {
        k += 10;
        if (index == old_stop_blockindex && k + 1 >= static_cast<int>(old_offset)) {
          return 4;
        }
        continue;
      }
      old_dir_file = state & 0x01U;
      if (old_type_dir == 1U && old_dir_file == 1U) {
        return 2;
      }
      if (new_type_dir == 1U && old_dir_file == 1U) {
        return 6;
      }
      old_item_offset = static_cast<std::uint16_t>(k + 10);

      bool reused = false;
      for (int j = 0; j < old_ba_used; ++j) {
        if (old_ba[j].blockindex == index) {
          old_block_item = &old_ba[j].block;
          old_block_item_index = index;
          reused = true;
          break;
        }
      }
      if (!reused) {
        old_ba[old_ba_used].block = old_block;
        old_ba[old_ba_used].blockindex = index;
        old_ba[old_ba_used].active = 1U;
        old_block_item = &old_ba[old_ba_used].block;
        old_block_item_index = index;
        ++old_ba_used;
      }
      flag = true;
      break;
    }
    if (flag) {
      break;
    }
    index = detail::b4_to_u32(std::span<const std::uint8_t, 4>(old_block.data() + 4, 4));
    if (index == 0U || !ffs.readblock(index, old_block)) {
      return 1;
    }
  }

  std::array<detail::BlockArray, 2> new_ba{};
  int new_ba_used = 0;
  detail::Block* new_block_head = nullptr;
  detail::Block* new_block_last = nullptr;
  std::uint32_t new_block_head_index = 0U;
  std::uint32_t new_block_last_index = 0U;

  detail::Block new_block{};
  if (!ffs.readblock(new_blockindex, new_block)) {
    return 1;
  }
  new_ba[0].block = new_block;
  new_ba[0].blockindex = new_blockindex;
  new_ba[0].active = 1U;
  new_block_head = &new_ba[0].block;
  new_block_head_index = new_blockindex;
  new_ba_used = 1;

  const std::uint32_t new_stop_blockindex =
      detail::b4_to_u32(std::span<const std::uint8_t, 4>(new_block_head->data() + 12 + 1 + 14 + 4, 4));
  std::uint16_t new_offset =
      detail::b2_to_u16(std::span<const std::uint8_t, 2>(new_block_head->data() + 12 + 1 + 14 + 4 + 4, 2));

  if (new_stop_blockindex == new_block_head_index) {
    new_block_last = new_block_head;
    new_block_last_index = new_block_head_index;
  } else {
    if (!ffs.readblock(new_stop_blockindex, new_ba[1].block)) {
      return 1;
    }
    new_ba[1].blockindex = new_stop_blockindex;
    new_ba[1].active = 1U;
    new_block_last = &new_ba[1].block;
    new_block_last_index = new_stop_blockindex;
    ++new_ba_used;
  }

  flag = false;
  index = new_block_head_index;
  for (;;) {
    int k = detail::BlockHead;
    for (int i = 0; i < detail::BlockItemMaxCount; ++i) {
      ++k;
      const bool name_match =
          detail::fixed_cstr(std::span<const std::uint8_t>(new_block.data() + k, BlockNameMaxSize)) ==
          new_lastname;
      k += static_cast<int>(BlockNameMaxSize);
      if (!name_match) {
        k += 10;
        if (index == new_stop_blockindex && k + 1 >= static_cast<int>(new_offset)) {
          flag = true;
          break;
        }
        continue;
      }
      return 5;
    }
    if (flag) {
      break;
    }
    index = detail::b4_to_u32(std::span<const std::uint8_t, 4>(new_block.data() + 4, 4));
    if (index == 0U || !ffs.readblock(index, new_block)) {
      return 1;
    }
  }

  if (old_block_head_index == new_block_head_index) {
    std::fill_n(old_block_item->data() + old_item_offset - 10 - 14, BlockNameMaxSize, 0U);
    std::memcpy(old_block_item->data() + old_item_offset - 10 - 14, new_lastname.data(), new_lastname.size());
    if (ffs.tmp.state == 0U && !ffs.tmpstart(1U)) {
      return 1;
    }
    if (!ffs.writeblock(old_block_item_index, *old_block_item)) {
      if (ffs.tmp.state == 1U) {
        ffs.tmpstop();
      }
      return 1;
    }
    if (ffs.tmp.state == 1U && !ffs.commit()) {
      return 1;
    }
    return 0;
  }

  if (ffs.tmp.state == 0U && !ffs.tmpstart(1U)) {
    return 1;
  }

  if (old_dir_file == 0U) {
    const std::uint32_t path_blockindex =
        detail::b4_to_u32(std::span<const std::uint8_t, 4>(old_block_item->data() + old_item_offset - 10, 4));
    detail::Block path_block{};
    if (!ffs.readblock(path_blockindex, path_block)) {
      if (ffs.tmp.state == 1U) {
        ffs.tmpstop();
      }
      return 1;
    }
    detail::u32_to_b4(new_block_head_index,
                      std::span<std::uint8_t, 4>(path_block.data() + detail::BlockHead + 25 + 1 + 14, 4));
    if (!ffs.writeblock(path_blockindex, path_block)) {
      if (ffs.tmp.state == 1U) {
        ffs.tmpstop();
      }
      return 1;
    }
  }

  detail::Block block2{};
  std::uint32_t blockindex2 = 0U;
  if (new_offset < BlockSize) {
    std::copy_n(old_block_item->data() + old_item_offset - 25, 25, new_block_last->data() + new_offset);
    new_offset = static_cast<std::uint16_t>(new_offset + 25);
    std::array<std::uint8_t, 2> b2{};
    detail::u16_to_b2(new_offset, b2);
    std::copy(b2.begin(), b2.end(), new_block_head->begin() + detail::BlockOffset);
  } else {
    blockindex2 = ffs.genblockindex();
    if (blockindex2 == 0U) {
      if (ffs.tmp.state == 1U) {
        ffs.tmpstop();
      }
      return 1;
    }
    block2.fill(0U);
    detail::u32_to_b4(new_block_last_index, std::span<std::uint8_t, 4>(block2.data() + 8, 4));
    std::copy_n(old_block_item->data() + old_item_offset - 25, 25, block2.data() + detail::BlockHead);
    if (!ffs.writeblock(blockindex2, block2)) {
      if (ffs.tmp.state == 1U) {
        ffs.tmpstop();
      }
      return 1;
    }
    detail::u32_to_b4(blockindex2, std::span<std::uint8_t, 4>(new_block_last->data() + 4, 4));
    new_offset = static_cast<std::uint16_t>(detail::BlockHead + 25);
    std::array<std::uint8_t, 2> b2{};
    detail::u16_to_b2(new_offset, b2);
    std::copy(b2.begin(), b2.end(), new_block_head->begin() + detail::BlockOffset);
    detail::u32_to_b4(blockindex2, std::span<std::uint8_t, 4>(new_block_head->data() + detail::BlockStopBlockindex, 4));
  }
  for (int i = 0; i < new_ba_used; ++i) {
    if (new_ba[i].active != 0U && !ffs.writeblock(new_ba[i].blockindex, new_ba[i].block)) {
      if (ffs.tmp.state == 1U) {
        ffs.tmpstop();
      }
      return 1;
    }
  }

  if (old_block_item_index != old_stop_blockindex || old_item_offset != old_offset) {
    std::copy_n(old_block_last->data() + old_offset - 25, 25, old_block_item->data() + old_item_offset - 25);
  }
  old_offset = static_cast<std::uint16_t>(old_offset - 25);
  std::array<std::uint8_t, 2> b2{};
  detail::u16_to_b2(old_offset, b2);
  std::copy(b2.begin(), b2.end(), old_block_head->begin() + detail::BlockOffset);

  if (old_offset < 25U) {
    old_block_prev_index = detail::b4_to_u32(std::span<const std::uint8_t, 4>(old_block_last->data() + 8, 4));
    if (!ffs.removeblock(old_block_last_index)) {
      if (ffs.tmp.state == 1U) {
        ffs.tmpstop();
      }
      return 1;
    }
    int slot = -1;
    for (int i = 0; i < old_ba_used; ++i) {
      if (old_ba[i].blockindex == old_block_last_index) {
        old_ba[i].active = 0U;
        slot = i;
        break;
      }
    }
    if (slot < 0) {
      if (ffs.tmp.state == 1U) {
        ffs.tmpstop();
      }
      return 1;
    }
    bool reused = false;
    for (int i = 0; i < old_ba_used; ++i) {
      if (old_ba[i].blockindex == old_block_prev_index) {
        old_block_prev = &old_ba[i].block;
        reused = true;
        break;
      }
    }
    if (!reused) {
      if (!ffs.readblock(old_block_prev_index, old_block)) {
        if (ffs.tmp.state == 1U) {
          ffs.tmpstop();
        }
        return 1;
      }
      old_ba[slot].block = old_block;
      old_ba[slot].blockindex = old_block_prev_index;
      old_ba[slot].active = 1U;
      old_block_prev = &old_ba[slot].block;
    }
    std::fill_n(old_block_prev->data() + 4, 4, 0U);
    detail::u32_to_b4(old_block_prev_index,
                      std::span<std::uint8_t, 4>(old_block_head->data() + detail::BlockStopBlockindex, 4));
    old_offset = BlockSize;
    detail::u16_to_b2(old_offset, b2);
    std::copy(b2.begin(), b2.end(), old_block_head->begin() + detail::BlockOffset);
  }

  for (int i = 0; i < old_ba_used; ++i) {
    if (old_ba[i].active != 0U && !ffs.writeblock(old_ba[i].blockindex, old_ba[i].block)) {
      if (ffs.tmp.state == 1U) {
        ffs.tmpstop();
      }
      return 1;
    }
  }
  if (ffs.tmp.state == 1U && !ffs.commit()) {
    return 1;
  }
  return 0;
}

}  // namespace

namespace filefs {

int FileSystem::rename(const std::string_view old_name, const std::string_view new_name) {
  if (!state_ || !state_->mounted() || old_name.empty() || new_name.empty()) {
    return 1;
  }

  int len_n = static_cast<int>(old_name.size());
  std::uint32_t blockindex = 0U;
  int start = 0;
  if (old_name.front() == '/') {
    blockindex = 1U;
    start = 1;
  } else if (state_->tmp.state == 0U) {
    blockindex = state_->pwd_blockindex;
  } else {
    blockindex = state_->tmp.pwd_blockindex;
  }

  std::array<char, BlockNameMaxSize + 2> s{};
  int slen = 0;
  for (int i = start; i < len_n; ++i) {
    if (old_name[static_cast<std::size_t>(i)] == '/') {
      if (slen == 0) {
        continue;
      }
      if (i == len_n - 1) {
        break;
      }
      const std::uint32_t index =
          state_->find_path_blockindex(blockindex, std::string_view{s.data(), static_cast<std::size_t>(slen)});
      if (index < 1U) {
        return 2;
      }
      blockindex = index;
      slen = 0;
      continue;
    }
    s[static_cast<std::size_t>(slen++)] = old_name[static_cast<std::size_t>(i)];
    if (slen > static_cast<int>(BlockNameMaxSize)) {
      return 2;
    }
  }
  if (slen > static_cast<int>(BlockNameMaxSize)) {
    return 2;
  }
  const std::string old_lastname{s.data(), static_cast<std::size_t>(slen)};
  if (old_lastname == "." || old_lastname == "..") {
    return 2;
  }
  const std::uint32_t old_blockindex = blockindex;
  std::uint8_t old_type_dir = old_name.back() == '/' ? 1U : 0U;

  len_n = static_cast<int>(new_name.size());
  if (new_name.front() == '/') {
    blockindex = 1U;
    start = 1;
  } else if (state_->tmp.state == 0U) {
    blockindex = state_->pwd_blockindex;
  } else {
    blockindex = state_->tmp.pwd_blockindex;
  }
  slen = 0;
  for (int i = start; i < len_n; ++i) {
    if (new_name[static_cast<std::size_t>(i)] == '/') {
      if (slen == 0) {
        continue;
      }
      if (i == len_n - 1) {
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
    s[static_cast<std::size_t>(slen++)] = new_name[static_cast<std::size_t>(i)];
    if (slen > static_cast<int>(BlockNameMaxSize)) {
      return 3;
    }
  }
  if (slen > static_cast<int>(BlockNameMaxSize)) {
    return 3;
  }
  const std::string new_lastname{s.data(), static_cast<std::size_t>(slen)};
  if (new_lastname == "." || new_lastname == "..") {
    return 3;
  }
  const std::uint32_t new_blockindex = blockindex;
  std::uint8_t new_type_dir = new_name.back() == '/' ? 1U : 0U;

  return do_rename(*state_, old_lastname, old_blockindex, old_type_dir, new_lastname, new_blockindex, new_type_dir);
}

}  // namespace filefs
