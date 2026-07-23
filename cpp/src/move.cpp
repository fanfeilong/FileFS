#include "filefs/filefs.hpp"

namespace filefs {

int FileSystem::move(const std::string_view from_name, const std::string_view to_path) {
  if (from_name.empty() || to_path.empty()) {
    return 1;
  }

  std::string_view trimmed_from = from_name;
  const bool is_dir = trimmed_from.back() == '/';
  while (!trimmed_from.empty() && trimmed_from.back() == '/') {
    trimmed_from.remove_suffix(1);
  }
  const std::size_t slash = trimmed_from.find_last_of('/');
  const std::string_view basename =
      slash == std::string_view::npos ? trimmed_from : trimmed_from.substr(slash + 1);

  std::string target(to_path);
  while (target.size() > 1 && target.back() == '/') {
    target.pop_back();
  }
  if (!target.empty() && target.back() != '/') {
    target.push_back('/');
  }
  target.append(basename.data(), basename.size());
  if (is_dir) {
    target.push_back('/');
  }
  return rename(from_name, target);
}

}  // namespace filefs
