#include "types.hpp"

#include "util.hpp"

namespace filefs::detail {

bool FileSystemState::init_pwdtmp(const std::string_view s) {
  pwd_tmp.assign(s.data(), s.size());
  return true;
}

bool FileSystemState::add_to_pwdtmp(const std::size_t /*pathsize*/, const std::string_view s) {
  if (s == ".") {
    return true;
  }

  if (s == "..") {
    for (std::size_t i = 1; i < pwd_tmp.size(); ++i) {
      if (pwd_tmp[pwd_tmp.size() - i - 1] == '/') {
        pwd_tmp.resize(pwd_tmp.size() - i);
        return true;
      }
    }
    return false;
  }

  pwd_tmp.append(s.data(), s.size());
  pwd_tmp.push_back('/');
  return true;
}

}  // namespace filefs::detail

namespace filefs {

bool FileSystem::chdir(const std::string_view pathname) {
  if (!state_ || !state_->mounted()) {
    return false;
  }

  const int len_n = static_cast<int>(pathname.size());
  std::uint32_t blockindex = 0U;
  int start = 0;
  if (!pathname.empty() && pathname.front() == '/') {
    blockindex = 1U;
    start = 1;
    if (!state_->init_pwdtmp("/")) {
      return false;
    }
  } else {
    if (state_->tmp.state == 0U) {
      blockindex = state_->pwd_blockindex;
      if (!state_->init_pwdtmp(state_->pwd)) {
        return false;
      }
    } else {
      blockindex = state_->tmp.pwd_blockindex;
      if (!state_->init_pwdtmp(state_->tmp.pwd)) {
        return false;
      }
    }
  }

  std::array<char, BlockNameMaxSize + 2> s{};
  int slen = 0;
  for (int i = start; i < len_n; ++i) {
    if (pathname[static_cast<std::size_t>(i)] == '/') {
      if (slen == 0) {
        continue;
      }
      const std::string_view comp{s.data(), static_cast<std::size_t>(slen)};
      const std::uint32_t index = state_->find_path_blockindex(blockindex, comp);
      if (index < 1U) {
        return false;
      }
      blockindex = index;
      if (!state_->add_to_pwdtmp(pathname.size(), comp)) {
        return false;
      }
      slen = 0;
      continue;
    }
    s[static_cast<std::size_t>(slen++)] = pathname[static_cast<std::size_t>(i)];
    if (slen > static_cast<int>(BlockNameMaxSize)) {
      return false;
    }
  }

  if (slen > 0) {
    const std::string_view comp{s.data(), static_cast<std::size_t>(slen)};
    const std::uint32_t index = state_->find_path_blockindex(blockindex, comp);
    if (index < 1U) {
      return false;
    }
    blockindex = index;
    if (!state_->add_to_pwdtmp(pathname.size(), comp)) {
      return false;
    }
  }

  if (state_->tmp.state == 0U) {
    state_->pwd = state_->pwd_tmp;
    state_->pwd_blockindex = blockindex;
  } else {
    state_->tmp.pwd = state_->pwd_tmp;
    state_->tmp.pwd_blockindex = blockindex;
  }
  return true;
}

std::string_view FileSystem::getcwd() const {
  if (!state_) {
    return {};
  }
  if (state_->tmp.state == 0U) {
    return state_->pwd;
  }
  return state_->tmp.pwd;
}

}  // namespace filefs
