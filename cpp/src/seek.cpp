#include "types.hpp"

#include "util.hpp"

namespace filefs {

bool FileSystem::fseek(File& stream, const std::int64_t offset, const Seek whence) {
  if (!state_ || !state_->mounted() || !stream.open_ || stream.pos_blockindex_ == 0U) {
    return false;
  }

  detail::Block block{};

  if (whence == Seek::Cur) {
    if (offset == 0) {
      return true;
    }
    if (offset > 0) {
      std::uint32_t blockindex = stream.pos_blockindex_;
      std::int64_t new_offset = offset;
      std::uint16_t pos_offset = stream.pos_offset_;
      for (;;) {
        const std::uint16_t blocksize =
            blockindex == stream.file_stop_blockindex_ ? stream.file_offset_ : static_cast<std::uint16_t>(BlockSize);
        if (blockindex == stream.file_stop_blockindex_) {
          if (static_cast<std::int64_t>(blocksize) - static_cast<std::int64_t>(pos_offset) >= new_offset) {
            stream.pos_offset_ = static_cast<std::uint16_t>(stream.pos_offset_ + new_offset);
            stream.pos_ += static_cast<std::uint64_t>(new_offset);
          } else {
            stream.pos_offset_ = static_cast<std::uint16_t>(stream.pos_offset_ + blocksize - pos_offset);
            stream.pos_ += static_cast<std::uint64_t>(blocksize - pos_offset);
          }
          return true;
        }

        stream.pos_offset_ = static_cast<std::uint16_t>(BlockSize);
        stream.pos_ += static_cast<std::uint64_t>(BlockSize - pos_offset);
        new_offset -= static_cast<std::int64_t>(BlockSize - pos_offset);
        pos_offset = static_cast<std::uint16_t>(detail::BlockHead);

        if (!state_->readblock(blockindex, block)) {
          return true;
        }
        const std::uint32_t next_blockindex =
            detail::b4_to_u32(std::span<const std::uint8_t, 4>(block.data() + 8, 4));
        if (next_blockindex == 0U) {
          return true;
        }
        blockindex = next_blockindex;
        stream.pos_blockindex_ = blockindex;
      }
    }

    std::uint32_t blockindex = stream.pos_blockindex_;
    std::int64_t new_offset = -offset;
    std::uint16_t pos_offset = stream.pos_offset_;
    for (;;) {
      if (static_cast<std::int64_t>(pos_offset) - detail::BlockHead >= new_offset) {
        stream.pos_offset_ = static_cast<std::uint16_t>(stream.pos_offset_ - new_offset);
        stream.pos_ -= static_cast<std::uint64_t>(new_offset);
        return true;
      }
      stream.pos_offset_ = static_cast<std::uint16_t>(stream.pos_offset_ - pos_offset);
      stream.pos_ -= pos_offset;
      new_offset -= pos_offset;
      pos_offset = static_cast<std::uint16_t>(BlockSize);

      if (!state_->readblock(blockindex, block)) {
        return true;
      }
      const std::uint32_t prev_blockindex =
          detail::b4_to_u32(std::span<const std::uint8_t, 4>(block.data() + 4, 4));
      if (prev_blockindex == 0U) {
        return true;
      }
      blockindex = prev_blockindex;
      stream.pos_blockindex_ = blockindex;
    }
  }

  if (whence == Seek::End) {
    std::uint64_t pos = stream.pos_ - static_cast<std::uint64_t>(stream.pos_offset_ - detail::BlockHead);
    std::uint32_t index = stream.pos_blockindex_;
    for (;;) {
      if (index == stream.file_stop_blockindex_) {
        pos += static_cast<std::uint64_t>(stream.file_offset_ - detail::BlockHead);
        break;
      }
      if (!state_->readblock(index, block)) {
        return false;
      }
      pos += BlockSize - detail::BlockHead;
      index = detail::b4_to_u32(std::span<const std::uint8_t, 4>(block.data() + 4, 4));
    }
    stream.pos_blockindex_ = stream.file_stop_blockindex_;
    stream.pos_offset_ = stream.file_offset_;
    stream.pos_ = pos;

    if (offset == 0) {
      return true;
    }
    if (offset < 0) {
      std::uint32_t blockindex = stream.pos_blockindex_;
      std::int64_t new_offset = -offset;
      std::uint16_t pos_offset = stream.pos_offset_;
      for (;;) {
        if (static_cast<std::int64_t>(pos_offset) - detail::BlockHead >= new_offset) {
          stream.pos_offset_ = static_cast<std::uint16_t>(stream.pos_offset_ - new_offset);
          stream.pos_ -= static_cast<std::uint64_t>(new_offset);
          return true;
        }
        stream.pos_offset_ = static_cast<std::uint16_t>(stream.pos_offset_ - pos_offset);
        stream.pos_ -= pos_offset;
        new_offset -= pos_offset;
        pos_offset = static_cast<std::uint16_t>(BlockSize);

        if (!state_->readblock(blockindex, block)) {
          return true;
        }
        const std::uint32_t prev_blockindex =
            detail::b4_to_u32(std::span<const std::uint8_t, 4>(block.data() + 4, 4));
        if (prev_blockindex == 0U) {
          return true;
        }
        blockindex = prev_blockindex;
        stream.pos_blockindex_ = blockindex;
      }
    }
    return false;
  }

  if (whence == Seek::Set) {
    stream.pos_blockindex_ = stream.file_start_blockindex_;
    stream.pos_offset_ = static_cast<std::uint16_t>(detail::BlockHead);
    stream.pos_ = 0U;
    if (offset == 0) {
      return true;
    }
    if (offset > 0) {
      std::uint32_t blockindex = stream.pos_blockindex_;
      std::int64_t new_offset = offset;
      std::uint16_t pos_offset = stream.pos_offset_;
      for (;;) {
        const std::uint16_t blocksize =
            blockindex == stream.file_stop_blockindex_ ? stream.file_offset_ : static_cast<std::uint16_t>(BlockSize);
        if (blockindex == stream.file_stop_blockindex_) {
          if (static_cast<std::int64_t>(blocksize) - static_cast<std::int64_t>(pos_offset) >= new_offset) {
            stream.pos_offset_ = static_cast<std::uint16_t>(stream.pos_offset_ + new_offset);
            stream.pos_ += static_cast<std::uint64_t>(new_offset);
          } else {
            stream.pos_offset_ = static_cast<std::uint16_t>(stream.pos_offset_ + blocksize - pos_offset);
            stream.pos_ += static_cast<std::uint64_t>(blocksize - pos_offset);
          }
          return true;
        }

        stream.pos_offset_ = static_cast<std::uint16_t>(BlockSize);
        stream.pos_ += static_cast<std::uint64_t>(BlockSize - pos_offset);
        new_offset -= static_cast<std::int64_t>(BlockSize - pos_offset);
        pos_offset = static_cast<std::uint16_t>(detail::BlockHead);

        if (!state_->readblock(blockindex, block)) {
          return true;
        }
        const std::uint32_t next_blockindex =
            detail::b4_to_u32(std::span<const std::uint8_t, 4>(block.data() + 8, 4));
        if (next_blockindex == 0U) {
          return true;
        }
        blockindex = next_blockindex;
        stream.pos_blockindex_ = blockindex;
      }
    }
  }

  return false;
}

std::uint64_t FileSystem::ftell(const File& f) const noexcept {
  if (!state_ || !state_->mounted() || !f.open_) {
    return 0U;
  }
  return f.pos_;
}

void FileSystem::rewind(File& f) { (void)fseek(f, 0, Seek::Set); }

}  // namespace filefs
