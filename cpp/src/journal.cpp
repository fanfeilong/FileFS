#include "types.hpp"

#include "util.hpp"

namespace filefs::detail {

void FileSystemState::j2ffs() {
  CFile journal_fp;
  journal_fp.reset(std::fopen(fnj.c_str(), "rb"));
  if (!journal_fp) {
    return;
  }

  const auto cleanup = [this, &journal_fp]() noexcept {
    journal_fp.reset();
    remove_if_exists(fnj);
  };

  std::uint8_t state = 0U;
  if (!read_exact(journal_fp.get(), &state, 1U) || state != 0xffU) {
    cleanup();
    return;
  }

  std::array<std::uint8_t, BlockSize + 4> index_block{};
  while (read_exact(journal_fp.get(), index_block.data(), index_block.size())) {
    const std::uint32_t index = b4_to_u32(std::span<const std::uint8_t, 4>(index_block.data(), 4));
    const std::uint64_t pos = static_cast<std::uint64_t>(index) * BlockSize;
    if (!set_pos(fp.get(), pos) || !write_exact(fp.get(), index_block.data() + 4, BlockSize)) {
      break;
    }
  }
  flush_file(fp.get());
  cleanup();
}

}  // namespace filefs::detail
