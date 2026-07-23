#include "types.hpp"

#include "util.hpp"

#include <cstring>

namespace filefs {

std::size_t FileSystem::fread(File& f, const std::span<std::byte> out) {
  return fread(out.data(), 1U, out.size(), f);
}

std::size_t FileSystem::fread(void* ptr, const std::size_t size, const std::size_t nmemb, File& stream) {
  if (!state_ || !state_->mounted() || ptr == nullptr || !stream.open_) {
    return 0U;
  }
  if (stream.mode_ == 1U || stream.mode_ == 2U || stream.pos_blockindex_ == 0U) {
    return 0U;
  }

  const std::size_t wannasize = size * nmemb;
  std::size_t k = 0U;
  detail::Block block{};
  std::uint32_t blockindex = stream.pos_blockindex_;

  auto* out = static_cast<std::uint8_t*>(ptr);
  while (true) {
    if (!state_->readblock(blockindex, block)) {
      return 0U;
    }
    const std::uint32_t nextindex =
        detail::b4_to_u32(std::span<const std::uint8_t, 4>(block.data() + 4, 4));

    if (stream.pos_offset_ == BlockSize) {
      stream.pos_blockindex_ = blockindex;
      stream.pos_offset_ = static_cast<std::uint16_t>(detail::BlockHead);
    }

    if (blockindex == stream.file_stop_blockindex_) {
      int n = static_cast<int>(stream.file_offset_) - static_cast<int>(stream.pos_offset_);
      if (n <= 0) {
        return k;
      }
      if (wannasize - k < static_cast<std::size_t>(n)) {
        n = static_cast<int>(wannasize - k);
      }
      std::memcpy(out + k, block.data() + stream.pos_offset_, static_cast<std::size_t>(n));
      k += static_cast<std::size_t>(n);
      stream.pos_blockindex_ = blockindex;
      stream.pos_offset_ = static_cast<std::uint16_t>(stream.pos_offset_ + n);
      stream.pos_ += static_cast<std::uint64_t>(n);
      return k;
    }

    int n = static_cast<int>(BlockSize) - static_cast<int>(stream.pos_offset_);
    if (n <= 0) {
      return k;
    }
    if (wannasize - k < static_cast<std::size_t>(n)) {
      n = static_cast<int>(wannasize - k);
    }
    std::memcpy(out + k, block.data() + stream.pos_offset_, static_cast<std::size_t>(n));
    k += static_cast<std::size_t>(n);
    stream.pos_blockindex_ = blockindex;
    stream.pos_offset_ = static_cast<std::uint16_t>(stream.pos_offset_ + n);
    stream.pos_ += static_cast<std::uint64_t>(n);
    if (k >= wannasize) {
      return k;
    }

    blockindex = nextindex;
    if (nextindex == 0U) {
      return k;
    }
  }
}

std::size_t FileSystem::fwrite(File& f, const std::span<const std::byte> in) {
  return fwrite(in.data(), 1U, in.size(), f);
}

std::size_t FileSystem::fwrite(const void* ptr, const std::size_t size, const std::size_t nmemb, File& stream) {
  if (!state_ || !state_->mounted() || ptr == nullptr || !stream.open_) {
    return 0U;
  }
  if (stream.mode_ == 0U) {
    return 0U;
  }

  const std::size_t wannasize = size * nmemb;
  if (wannasize == 0U) {
    return 0U;
  }

  std::size_t cut = 0U;
  detail::Block new_block{};
  detail::Block pos_block{};
  detail::Block dir_block{};
  std::array<std::uint8_t, 4> b4{};
  std::array<std::uint8_t, 2> b2{};
  std::uint32_t next_blockindex = 0U;

  if (state_->tmp.state == 0U && !state_->tmpstart(1U)) {
    return 0U;
  }

  const auto* in = static_cast<const std::uint8_t*>(ptr);
  if (stream.pos_blockindex_ == 0U) {
    const std::uint32_t new_blockindex = state_->genblockindex();
    if (new_blockindex == 0U) {
      if (state_->tmp.state == 1U) {
        state_->tmpstop();
      }
      return 0U;
    }
    pos_block.fill(0U);
    if (!state_->writeblock(new_blockindex, pos_block)) {
      if (state_->tmp.state == 1U) {
        state_->tmpstop();
      }
      return 0U;
    }
    if (!state_->readblock(stream.dir_blockindex_, dir_block)) {
      if (state_->tmp.state == 1U) {
        state_->tmpstop();
      }
      return 0U;
    }
    detail::u32_to_b4(new_blockindex, b4);
    std::copy(b4.begin(), b4.end(), dir_block.begin() + stream.dir_offset_ - 10);
    std::copy(b4.begin(), b4.end(), dir_block.begin() + stream.dir_offset_ - 6);
    detail::u16_to_b2(static_cast<std::uint16_t>(detail::BlockHead), b2);
    std::copy(b2.begin(), b2.end(), dir_block.begin() + stream.dir_offset_ - 2);

    stream.file_start_blockindex_ = new_blockindex;
    stream.file_stop_blockindex_ = new_blockindex;
    stream.file_offset_ = 0U;
    stream.pos_blockindex_ = new_blockindex;
    stream.pos_offset_ = static_cast<std::uint16_t>(detail::BlockHead);
    stream.pos_ = 0U;
    if (!state_->writeblock(stream.dir_blockindex_, dir_block)) {
      if (state_->tmp.state == 1U) {
        state_->tmpstop();
      }
      return 0U;
    }
    next_blockindex = 0U;
  } else {
    if (!state_->readblock(stream.pos_blockindex_, pos_block)) {
      if (state_->tmp.state == 1U) {
        state_->tmpstop();
      }
      return 0U;
    }
    next_blockindex = detail::b4_to_u32(std::span<const std::uint8_t, 4>(pos_block.data() + 4, 4));
  }

  while (true) {
    if (stream.pos_offset_ == BlockSize) {
      if (next_blockindex == 0U) {
        const std::uint32_t new_blockindex = state_->genblockindex();
        if (new_blockindex == 0U) {
          if (state_->tmp.state == 1U) {
            state_->tmpstop();
          }
          return 0U;
        }
        new_block.fill(0U);
        detail::u32_to_b4(stream.pos_blockindex_, std::span<std::uint8_t, 4>(new_block.data() + 8, 4));
        detail::u32_to_b4(new_blockindex, std::span<std::uint8_t, 4>(pos_block.data() + 4, 4));
        if (!state_->writeblock(stream.pos_blockindex_, pos_block)) {
          if (state_->tmp.state == 1U) {
            state_->tmpstop();
          }
          return 0U;
        }
        stream.pos_blockindex_ = new_blockindex;
        stream.pos_offset_ = static_cast<std::uint16_t>(detail::BlockHead);
        pos_block = new_block;
        next_blockindex = 0U;
      } else {
        if (!state_->readblock(next_blockindex, pos_block)) {
          if (state_->tmp.state == 1U) {
            state_->tmpstop();
          }
          return 0U;
        }
        const std::uint32_t original_next =
            detail::b4_to_u32(std::span<const std::uint8_t, 4>(pos_block.data() + 4, 4));
        stream.pos_blockindex_ = next_blockindex;
        stream.pos_offset_ = static_cast<std::uint16_t>(detail::BlockHead);
        next_blockindex = original_next;
      }
    }

    const std::size_t avail = BlockSize - stream.pos_offset_;
    if (wannasize - cut <= avail) {
      const std::size_t n = wannasize - cut;
      std::memcpy(pos_block.data() + stream.pos_offset_, in + cut, n);
      cut += n;
      if (!state_->writeblock(stream.pos_blockindex_, pos_block)) {
        if (state_->tmp.state == 1U) {
          state_->tmpstop();
        }
        return 0U;
      }
      stream.pos_offset_ = static_cast<std::uint16_t>(stream.pos_offset_ + n);
      stream.pos_ += n;

      bool update_size = false;
      if (stream.pos_blockindex_ > stream.file_stop_blockindex_) {
        update_size = true;
      } else if (stream.pos_blockindex_ == stream.file_stop_blockindex_ &&
                 stream.pos_offset_ > stream.file_offset_) {
        update_size = true;
      }

      if (update_size) {
        if (!state_->readblock(stream.dir_blockindex_, dir_block)) {
          if (state_->tmp.state == 1U) {
            state_->tmpstop();
          }
          return 0U;
        }
        stream.file_stop_blockindex_ = stream.pos_blockindex_;
        stream.file_offset_ = stream.pos_offset_;
        detail::u32_to_b4(stream.pos_blockindex_, b4);
        std::copy(b4.begin(), b4.end(), dir_block.begin() + stream.dir_offset_ - 6);
        detail::u16_to_b2(stream.pos_offset_, b2);
        std::copy(b2.begin(), b2.end(), dir_block.begin() + stream.dir_offset_ - 2);
        if (!state_->writeblock(stream.dir_blockindex_, dir_block)) {
          if (state_->tmp.state == 1U) {
            state_->tmpstop();
          }
          return 0U;
        }
      }
      if (state_->tmp.state == 1U && !state_->commit()) {
        return 0U;
      }
      return wannasize;
    }

    const std::size_t n = avail;
    std::memcpy(pos_block.data() + stream.pos_offset_, in + cut, n);
    cut += n;
    if (!state_->writeblock(stream.pos_blockindex_, pos_block)) {
      if (state_->tmp.state == 1U) {
        state_->tmpstop();
      }
      return 0U;
    }
    stream.pos_offset_ = static_cast<std::uint16_t>(stream.pos_offset_ + n);
    stream.pos_ += n;

    if (wannasize - cut == 0U) {
      bool update_size = false;
      if (stream.pos_blockindex_ > stream.file_stop_blockindex_) {
        update_size = true;
      } else if (stream.pos_blockindex_ == stream.file_stop_blockindex_ &&
                 stream.pos_offset_ > stream.file_offset_) {
        update_size = true;
      }
      if (update_size) {
        if (!state_->readblock(stream.dir_blockindex_, dir_block)) {
          if (state_->tmp.state == 1U) {
            state_->tmpstop();
          }
          return 0U;
        }
        stream.file_stop_blockindex_ = stream.pos_blockindex_;
        stream.file_offset_ = stream.pos_offset_;
        detail::u32_to_b4(stream.pos_blockindex_, b4);
        std::copy(b4.begin(), b4.end(), dir_block.begin() + stream.dir_offset_ - 6);
        detail::u16_to_b2(stream.pos_offset_, b2);
        std::copy(b2.begin(), b2.end(), dir_block.begin() + stream.dir_offset_ - 2);
        if (!state_->writeblock(stream.dir_blockindex_, dir_block)) {
          if (state_->tmp.state == 1U) {
            state_->tmpstop();
          }
          return 0U;
        }
      }
      if (state_->tmp.state == 1U && !state_->commit()) {
        return 0U;
      }
      return wannasize;
    }
  }
}

void FileSystem::fclose(File& f) noexcept { f.open_ = false; }

}  // namespace filefs
