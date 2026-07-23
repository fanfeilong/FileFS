#include "types.hpp"

#include "util.hpp"

namespace {

int do_mkdir(filefs::detail::FileSystemState& ffs, const std::string_view lastname,
             const std::uint32_t start_blockindex, filefs::detail::Block& start_block,
             const std::uint32_t cur_blockindex, filefs::detail::Block& cur_block,
             const std::uint32_t /*stop_blockindex*/, const std::uint16_t offset) {
  using namespace filefs;

  if (ffs.tmp.state == 0U && !ffs.tmpstart(1U)) {
    return 1;
  }

  detail::Block new_block{};
  detail::Block block2{};

  if (offset < BlockSize) {
    const std::uint32_t new_blockindex = ffs.genblockindex();
    if (new_blockindex == 0U) {
      if (ffs.tmp.state == 1U) {
        ffs.tmpstop();
      }
      return 1;
    }
    new_block.fill(0U);
    int k = detail::BlockHead;
    new_block[static_cast<std::size_t>(k)] = 0U;
    ++k;
    new_block[static_cast<std::size_t>(k)] = static_cast<std::uint8_t>('.');
    k += static_cast<int>(BlockNameMaxSize);
    detail::u32_to_b4(new_blockindex, std::span<std::uint8_t, 4>(new_block.data() + k, 4));
    k += 4;
    detail::u32_to_b4(new_blockindex, std::span<std::uint8_t, 4>(new_block.data() + k, 4));
    k += 4;
    detail::u16_to_b2(static_cast<std::uint16_t>(4 + 4 + 4 + 25 + 25),
                      std::span<std::uint8_t, 2>(new_block.data() + k, 2));
    k += 2;

    new_block[static_cast<std::size_t>(k)] = 0U;
    ++k;
    new_block[static_cast<std::size_t>(k)] = static_cast<std::uint8_t>('.');
    new_block[static_cast<std::size_t>(k + 1)] = static_cast<std::uint8_t>('.');
    k += static_cast<int>(BlockNameMaxSize);
    detail::u32_to_b4(start_blockindex, std::span<std::uint8_t, 4>(new_block.data() + k, 4));
    if (!ffs.writeblock(new_blockindex, new_block)) {
      if (ffs.tmp.state == 1U) {
        ffs.tmpstop();
      }
      return 1;
    }

    k = static_cast<int>(offset);
    cur_block[static_cast<std::size_t>(k)] = 0U;
    ++k;
    std::fill_n(cur_block.data() + k, BlockNameMaxSize, 0U);
    std::memcpy(cur_block.data() + k, lastname.data(), lastname.size());
    k += static_cast<int>(BlockNameMaxSize);
    detail::u32_to_b4(new_blockindex, std::span<std::uint8_t, 4>(cur_block.data() + k, 4));
    k += 4 + 4 + 2;
    const std::uint16_t new_offset = static_cast<std::uint16_t>(k);
    std::array<std::uint8_t, 2> b2{};
    detail::u16_to_b2(new_offset, b2);

    if (cur_blockindex == start_blockindex) {
      std::copy(b2.begin(), b2.end(), cur_block.begin() + detail::BlockOffset);
      if (!ffs.writeblock(cur_blockindex, cur_block)) {
        if (ffs.tmp.state == 1U) {
          ffs.tmpstop();
        }
        return 1;
      }
      if (ffs.tmp.state == 1U && !ffs.commit()) {
        return 1;
      }
    } else {
      if (!ffs.writeblock(cur_blockindex, cur_block)) {
        if (ffs.tmp.state == 1U) {
          ffs.tmpstop();
        }
        return 1;
      }
      std::copy(b2.begin(), b2.end(), start_block.begin() + detail::BlockOffset);
      if (!ffs.writeblock(start_blockindex, start_block)) {
        if (ffs.tmp.state == 1U) {
          ffs.tmpstop();
        }
        return 1;
      }
      if (ffs.tmp.state == 1U && !ffs.commit()) {
        return 1;
      }
    }
    return 0;
  }

  const std::uint32_t new_blockindex = ffs.genblockindex();
  if (new_blockindex == 0U) {
    if (ffs.tmp.state == 1U) {
      ffs.tmpstop();
    }
    return 1;
  }
  const std::uint32_t blockindex2 = ffs.genblockindex();
  if (blockindex2 == 0U) {
    if (ffs.tmp.state == 1U) {
      ffs.tmpstop();
    }
    return 1;
  }

  block2.fill(0U);
  int k = 8;
  detail::u32_to_b4(cur_blockindex, std::span<std::uint8_t, 4>(block2.data() + k, 4));
  k += 4;
  block2[static_cast<std::size_t>(k)] = 0U;
  ++k;
  std::fill_n(block2.data() + k, BlockNameMaxSize, 0U);
  std::memcpy(block2.data() + k, lastname.data(), lastname.size());
  k += static_cast<int>(BlockNameMaxSize);
  detail::u32_to_b4(new_blockindex, std::span<std::uint8_t, 4>(block2.data() + k, 4));
  k += 4 + 4 + 2;
  const std::uint16_t new_offset = static_cast<std::uint16_t>(k);
  if (!ffs.writeblock(blockindex2, block2)) {
    if (ffs.tmp.state == 1U) {
      ffs.tmpstop();
    }
    return 1;
  }

  new_block.fill(0U);
  k = detail::BlockHead;
  new_block[static_cast<std::size_t>(k)] = 0U;
  ++k;
  new_block[static_cast<std::size_t>(k)] = static_cast<std::uint8_t>('.');
  k += static_cast<int>(BlockNameMaxSize);
  detail::u32_to_b4(new_blockindex, std::span<std::uint8_t, 4>(new_block.data() + k, 4));
  k += 4;
  detail::u32_to_b4(new_blockindex, std::span<std::uint8_t, 4>(new_block.data() + k, 4));
  k += 4;
  detail::u16_to_b2(static_cast<std::uint16_t>(4 + 4 + 4 + 25 + 25),
                    std::span<std::uint8_t, 2>(new_block.data() + k, 2));
  k += 2;
  new_block[static_cast<std::size_t>(k)] = 0U;
  ++k;
  new_block[static_cast<std::size_t>(k)] = static_cast<std::uint8_t>('.');
  new_block[static_cast<std::size_t>(k + 1)] = static_cast<std::uint8_t>('.');
  k += static_cast<int>(BlockNameMaxSize);
  detail::u32_to_b4(start_blockindex, std::span<std::uint8_t, 4>(new_block.data() + k, 4));
  if (!ffs.writeblock(new_blockindex, new_block)) {
    if (ffs.tmp.state == 1U) {
      ffs.tmpstop();
    }
    return 1;
  }

  std::array<std::uint8_t, 2> b2{};
  detail::u16_to_b2(new_offset, b2);
  detail::u32_to_b4(blockindex2, std::span<std::uint8_t, 4>(cur_block.data() + 4, 4));

  if (cur_blockindex == start_blockindex) {
    detail::u32_to_b4(blockindex2, std::span<std::uint8_t, 4>(cur_block.data() + detail::BlockStopBlockindex, 4));
    std::copy(b2.begin(), b2.end(), cur_block.begin() + detail::BlockOffset);
    if (!ffs.writeblock(cur_blockindex, cur_block)) {
      if (ffs.tmp.state == 1U) {
        ffs.tmpstop();
      }
      return 1;
    }
    if (ffs.tmp.state == 1U && !ffs.commit()) {
      return 1;
    }
  } else {
    if (!ffs.writeblock(cur_blockindex, cur_block)) {
      if (ffs.tmp.state == 1U) {
        ffs.tmpstop();
      }
      return 1;
    }
    detail::u32_to_b4(blockindex2, std::span<std::uint8_t, 4>(start_block.data() + detail::BlockStopBlockindex, 4));
    std::copy(b2.begin(), b2.end(), start_block.begin() + detail::BlockOffset);
    if (!ffs.writeblock(start_blockindex, start_block)) {
      if (ffs.tmp.state == 1U) {
        ffs.tmpstop();
      }
      return 1;
    }
    if (ffs.tmp.state == 1U && !ffs.commit()) {
      return 1;
    }
  }

  return 0;
}

}  // namespace

namespace filefs {

int FileSystem::mkdir(const std::string_view pathname) {
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
      const std::uint32_t index =
          state_->find_path_blockindex(blockindex, std::string_view{s.data(), static_cast<std::size_t>(slen)});
      if (index < 1U) {
        if (i == static_cast<int>(pathname.size()) - 1) {
          break;
        }
        return 1;
      }
      blockindex = index;
      slen = 0;
      continue;
    }
    s[static_cast<std::size_t>(slen++)] = pathname[static_cast<std::size_t>(i)];
    if (slen > static_cast<int>(BlockNameMaxSize)) {
      return 2;
    }
  }
  if (slen == 0) {
    return 3;
  }
  const std::string_view lastname{s.data(), static_cast<std::size_t>(slen)};
  if (lastname.size() > BlockNameMaxSize) {
    return 2;
  }

  detail::Block start_block{};
  detail::Block block{};
  if (!state_->readblock(blockindex, block)) {
    return 1;
  }
  start_block = block;
  const std::uint32_t start_blockindex = blockindex;

  const std::uint32_t stop_blockindex =
      detail::b4_to_u32(std::span<const std::uint8_t, 4>(block.data() + 12 + 1 + 14 + 4, 4));
  const std::uint16_t offset =
      detail::b2_to_u16(std::span<const std::uint8_t, 2>(block.data() + 12 + 1 + 14 + 4 + 4, 2));

  bool flag = false;
  std::uint32_t index = start_blockindex;
  for (;;) {
    int k = detail::BlockHead;
    for (int i = 0; i < detail::BlockItemMaxCount; ++i) {
      const std::uint8_t state = block[static_cast<std::size_t>(k)];
      ++k;
      if (detail::fixed_cstr(std::span<const std::uint8_t>(block.data() + k, BlockNameMaxSize)) != lastname) {
        k += static_cast<int>(BlockNameMaxSize) + 10;
        if (index == stop_blockindex && k + 1 >= static_cast<int>(offset)) {
          flag = true;
          break;
        }
        continue;
      }
      if ((state & 0x01U) == 0U) {
        return 3;
      }
      return 4;
    }
    if (flag) {
      break;
    }
    index = detail::b4_to_u32(std::span<const std::uint8_t, 4>(block.data() + 4, 4));
    if (index == 0U || !state_->readblock(index, block)) {
      return 1;
    }
  }

  return do_mkdir(*state_, lastname, start_blockindex, start_block, index, block, stop_blockindex, offset);
}

}  // namespace filefs
