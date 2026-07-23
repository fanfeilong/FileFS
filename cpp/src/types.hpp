#pragma once

#include "filefs/filefs.hpp"

#include <array>
#include <cstdio>
#include <cstdint>
#include <string>
#include <string_view>

namespace filefs::detail {

inline constexpr int BlockItemMaxCount = 20;
inline constexpr int BlockHead = 12;
inline constexpr int BlockStartBlockindex = 27;
inline constexpr int BlockStopBlockindex = 31;
inline constexpr int BlockOffset = 35;

inline constexpr std::array<std::uint8_t, 4> MagicNumber{0x78, 0x11, 0x45, 0x14};

using Block = std::array<std::uint8_t, BlockSize>;

struct CFile {
  std::FILE* handle{nullptr};

  CFile() = default;
  ~CFile();

  CFile(CFile&& other) noexcept;
  CFile& operator=(CFile&& other) noexcept;

  CFile(const CFile&) = delete;
  CFile& operator=(const CFile&) = delete;

  void reset(std::FILE* fp = nullptr) noexcept;
  [[nodiscard]] std::FILE* get() const noexcept { return handle; }
  [[nodiscard]] int fd() const noexcept;
  [[nodiscard]] explicit operator bool() const noexcept { return handle != nullptr; }
};

struct BlockArray {
  std::uint8_t active{0};
  Block block{};
  std::uint32_t blockindex{0};
};

struct TempState {
  std::uint8_t state{0};

  std::string pwd{};
  std::uint32_t pwd_blockindex{0};

  CFile fp_cp{};
  CFile fp_add{};
  std::string cp_path{};
  std::string add_path{};

  std::uint8_t cp_size{0};

  std::uint32_t total_blocksize{0};
  std::uint32_t unused_blockhead{0};
  std::uint32_t new_total_blocksize{0};
  std::uint32_t new_unused_blockhead{0};
};

struct FileSystemState {
  std::string fn{};
  CFile fp{};
  std::string fnj{};

  TempState tmp{};

  std::string pwd{};
  std::uint32_t pwd_blockindex{0};
  std::string pwd_tmp{};

  [[nodiscard]] bool mounted() const noexcept { return static_cast<bool>(fp); }
  void reset() noexcept;

  [[nodiscard]] bool tmpstart(std::uint8_t state);
  void tmpstop() noexcept;
  [[nodiscard]] bool commit();
  void rollback() noexcept;
  void j2ffs();

  [[nodiscard]] std::uint32_t genblockindex();
  [[nodiscard]] bool readblock(std::uint32_t blockindex, Block& block);
  [[nodiscard]] bool writeblock(std::uint32_t blockindex, const Block& block);
  [[nodiscard]] bool removeblock(std::uint32_t blockindex);
  [[nodiscard]] std::uint32_t find_path_blockindex(std::uint32_t blockindex, std::string_view pathname);

  [[nodiscard]] std::uint8_t stat(std::string_view name);
  [[nodiscard]] bool init_pwdtmp(std::string_view s);
  [[nodiscard]] bool add_to_pwdtmp(std::size_t pathsize, std::string_view s);

  [[nodiscard]] std::optional<File> do_fopen_r(std::string_view lastname, std::uint8_t mode,
                                               std::uint32_t block_head_index);
  [[nodiscard]] bool do_fopen_createfileitem(std::string_view lastname, std::uint32_t org_start_blockindex,
                                             std::uint32_t org_stop_blockindex, std::uint16_t org_offset,
                                             Block& dir_block, std::uint32_t& dir_blockindex,
                                             std::uint16_t& dir_offset);
  [[nodiscard]] bool do_fopen_cleanfilecontent(Block& dir_block, std::uint32_t dir_blockindex,
                                               std::uint16_t dir_offset);
  [[nodiscard]] std::optional<File> do_fopen_w(std::string_view lastname, std::uint8_t mode,
                                               std::uint32_t block_head_index);
  [[nodiscard]] std::optional<File> do_fopen_a(std::string_view lastname, std::uint8_t mode,
                                               std::uint32_t block_head_index);
};

}  // namespace filefs::detail
