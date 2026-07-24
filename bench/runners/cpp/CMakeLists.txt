cmake_minimum_required(VERSION 3.16)
project(filefs_bench_cpp LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(FILEFS_CPP_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../../../cpp")

add_library(filefs_lib
  ${FILEFS_CPP_ROOT}/src/util.cpp
  ${FILEFS_CPP_ROOT}/src/mount.cpp
  ${FILEFS_CPP_ROOT}/src/block.cpp
  ${FILEFS_CPP_ROOT}/src/txn.cpp
  ${FILEFS_CPP_ROOT}/src/journal.cpp
  ${FILEFS_CPP_ROOT}/src/fopen.cpp
  ${FILEFS_CPP_ROOT}/src/fopen_helpers.cpp
  ${FILEFS_CPP_ROOT}/src/readwrite.cpp
  ${FILEFS_CPP_ROOT}/src/seek.cpp
  ${FILEFS_CPP_ROOT}/src/exist.cpp
  ${FILEFS_CPP_ROOT}/src/remove.cpp
  ${FILEFS_CPP_ROOT}/src/rename.cpp
  ${FILEFS_CPP_ROOT}/src/move.cpp
  ${FILEFS_CPP_ROOT}/src/copy.cpp
  ${FILEFS_CPP_ROOT}/src/pwd.cpp
  ${FILEFS_CPP_ROOT}/src/mkdir.cpp
  ${FILEFS_CPP_ROOT}/src/rmdir.cpp
  ${FILEFS_CPP_ROOT}/src/readdir.cpp
)
target_include_directories(filefs_lib PUBLIC ${FILEFS_CPP_ROOT}/include PRIVATE ${FILEFS_CPP_ROOT}/src)
target_compile_options(filefs_lib PRIVATE -O2)

add_executable(filefs_bench bench.cpp)
target_link_libraries(filefs_bench PRIVATE filefs_lib)
target_compile_options(filefs_bench PRIVATE -O2)
