#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <optional>
#include <span>
#include <string>
#include <string_view>

namespace filefs {

inline constexpr std::size_t BlockSize = 512;
inline constexpr std::size_t BlockNameMaxSize = 14;

enum class Seek : int { Set = 0, Cur = 1, End = 2 };
enum class DirType : int { File = 0, Dir = 1, Root = 2 };

namespace detail {
struct FileSystemState;
}

class FileSystem;

struct Dirent {
  DirType type{DirType::File};
  std::size_t namelen{0};
  std::array<char, BlockNameMaxSize + 1> name{};

  [[nodiscard]] std::string_view name_view() const noexcept {
    std::size_t len = 0;
    while (len < name.size() && name[len] != '\0') {
      ++len;
    }
    return std::string_view{name.data(), len};
  }
};

class File {
public:
  File() = default;
  ~File() { open_ = false; }

  File(File&& other) noexcept { *this = std::move(other); }
  File& operator=(File&& other) noexcept {
    if (this != &other) {
      mode_ = other.mode_;
      dir_blockindex_ = other.dir_blockindex_;
      dir_offset_ = other.dir_offset_;
      file_start_blockindex_ = other.file_start_blockindex_;
      file_stop_blockindex_ = other.file_stop_blockindex_;
      file_offset_ = other.file_offset_;
      pos_blockindex_ = other.pos_blockindex_;
      pos_offset_ = other.pos_offset_;
      pos_ = other.pos_;
      open_ = other.open_;
      other.open_ = false;
    }
    return *this;
  }

  File(const File&) = delete;
  File& operator=(const File&) = delete;

  [[nodiscard]] bool is_open() const noexcept { return open_; }

private:
  friend class FileSystem;
  friend struct detail::FileSystemState;

  std::uint8_t mode_{0};
  std::uint32_t dir_blockindex_{0};
  std::uint16_t dir_offset_{0};
  std::uint32_t file_start_blockindex_{0};
  std::uint32_t file_stop_blockindex_{0};
  std::uint16_t file_offset_{0};
  std::uint32_t pos_blockindex_{0};
  std::uint16_t pos_offset_{0};
  std::uint64_t pos_{0};
  bool open_{false};
};

class Directory {
public:
  Directory() = default;
  ~Directory() { open_ = false; }

  Directory(Directory&& other) noexcept { *this = std::move(other); }
  Directory& operator=(Directory&& other) noexcept {
    if (this != &other) {
      blockindex_ = other.blockindex_;
      block_ = other.block_;
      searchindex_ = other.searchindex_;
      stop_blockindex_ = other.stop_blockindex_;
      offset_ = other.offset_;
      dirent_ = other.dirent_;
      absolute_path_ = std::move(other.absolute_path_);
      open_ = other.open_;
      other.open_ = false;
    }
    return *this;
  }

  Directory(const Directory&) = delete;
  Directory& operator=(const Directory&) = delete;

  [[nodiscard]] bool is_open() const noexcept { return open_; }
  [[nodiscard]] std::string_view absolute_path() const noexcept { return absolute_path_; }

private:
  friend class FileSystem;
  friend struct detail::FileSystemState;

  std::uint32_t blockindex_{0};
  std::array<std::uint8_t, BlockSize> block_{};
  int searchindex_{0};
  std::uint32_t stop_blockindex_{0};
  std::uint16_t offset_{0};
  Dirent dirent_{};
  std::string absolute_path_{};
  bool open_{false};
};

class FileSystem {
public:
  FileSystem();
  ~FileSystem();
  FileSystem(FileSystem&&) noexcept;
  FileSystem& operator=(FileSystem&&) noexcept;
  FileSystem(const FileSystem&) = delete;
  FileSystem& operator=(const FileSystem&) = delete;

  static bool mkfs(std::string_view path);

  [[nodiscard]] bool mount(std::string_view path);
  void umount() noexcept;
  [[nodiscard]] bool is_mounted() const noexcept;

  [[nodiscard]] std::optional<File> fopen(std::string_view path, std::string_view mode);
  std::size_t fread(File& f, std::span<std::byte> out);
  std::size_t fread(void* ptr, std::size_t size, std::size_t nmemb, File& f);
  std::size_t fwrite(File& f, std::span<const std::byte> in);
  std::size_t fwrite(const void* ptr, std::size_t size, std::size_t nmemb, File& f);
  void fclose(File& f) noexcept;

  [[nodiscard]] bool fseek(File& f, std::int64_t off, Seek whence);
  [[nodiscard]] std::uint64_t ftell(const File& f) const noexcept;
  void rewind(File& f);

  [[nodiscard]] bool file_exist(std::string_view path) const;
  [[nodiscard]] bool dir_exist(std::string_view path) const;
  int remove(std::string_view path);
  int rename(std::string_view old_name, std::string_view new_name);
  int move(std::string_view from_name, std::string_view to_path);
  int copy(std::string_view from_filename, std::string_view to_filename);
  bool chdir(std::string_view path);
  [[nodiscard]] std::string_view getcwd() const;
  int mkdir(std::string_view path);
  int rmdir(std::string_view path);

  [[nodiscard]] std::optional<Directory> opendir(std::string_view path);
  [[nodiscard]] std::optional<Dirent> readdir(Directory& d);
  void closedir(Directory& d) noexcept;

  [[nodiscard]] bool begin();
  [[nodiscard]] bool commit();
  void rollback() noexcept;

private:
  std::unique_ptr<detail::FileSystemState> state_;
};

}  // namespace filefs
