#pragma once

#include "types.hpp"

#include <cerrno>
#include <cstring>
#include <filesystem>
#include <span>
#include <string>
#include <string_view>

#include <unistd.h>

namespace filefs::detail {

[[nodiscard]] constexpr std::uint32_t b4_to_u32(const std::span<const std::uint8_t, 4> bytes) noexcept {
  return static_cast<std::uint32_t>(bytes[0]) |
         (static_cast<std::uint32_t>(bytes[1]) << 8U) |
         (static_cast<std::uint32_t>(bytes[2]) << 16U) |
         (static_cast<std::uint32_t>(bytes[3]) << 24U);
}

[[nodiscard]] constexpr std::uint16_t b2_to_u16(const std::span<const std::uint8_t, 2> bytes) noexcept {
  return static_cast<std::uint16_t>(bytes[0]) | (static_cast<std::uint16_t>(bytes[1]) << 8U);
}

constexpr void u32_to_b4(std::uint32_t value, const std::span<std::uint8_t, 4> bytes) noexcept {
  bytes[0] = static_cast<std::uint8_t>(value & 0x000000FFU);
  bytes[1] = static_cast<std::uint8_t>((value & 0x0000FF00U) >> 8U);
  bytes[2] = static_cast<std::uint8_t>((value & 0x00FF0000U) >> 16U);
  bytes[3] = static_cast<std::uint8_t>((value & 0xFF000000U) >> 24U);
}

constexpr void u16_to_b2(std::uint16_t value, const std::span<std::uint8_t, 2> bytes) noexcept {
  bytes[0] = static_cast<std::uint8_t>(value & 0x00FFU);
  bytes[1] = static_cast<std::uint8_t>((value & 0xFF00U) >> 8U);
}

[[nodiscard]] inline bool set_pos(std::FILE* fp, std::uint64_t pos) noexcept {
  return fp != nullptr && ::fseeko(fp, static_cast<off_t>(pos), SEEK_SET) == 0;
}

inline void rewind_file(std::FILE* fp) noexcept {
  if (fp != nullptr) {
    (void)::fseeko(fp, 0, SEEK_SET);
  }
}

inline void flush_file(std::FILE* fp) noexcept {
  if (fp == nullptr) {
    return;
  }
  (void)::fflush(fp);
  (void)::fsync(::fileno(fp));
}

[[nodiscard]] inline bool read_exact(std::FILE* fp, void* buffer, std::size_t size) noexcept {
  return fp != nullptr && std::fread(buffer, 1, size, fp) == size;
}

[[nodiscard]] inline bool write_exact(std::FILE* fp, const void* buffer, std::size_t size) noexcept {
  return fp != nullptr && std::fwrite(buffer, 1, size, fp) == size;
}

[[nodiscard]] std::string fixed_cstr(std::span<const std::uint8_t> bytes);
void copy_name_into(std::span<std::uint8_t> dst, std::string_view name) noexcept;
[[nodiscard]] bool create_temp_file(std::string_view prefix, CFile& out, std::string& out_path);
void remove_if_exists(const std::string& path) noexcept;

[[nodiscard]] inline std::string to_string(std::string_view value) {
  return std::string(value.data(), value.size());
}

}  // namespace filefs::detail
