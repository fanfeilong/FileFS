cmake_minimum_required(VERSION 3.16)

if(NOT DEFINED CMAKE_CXX_COMPILER AND EXISTS "/usr/bin/g++")
  set(CMAKE_CXX_COMPILER "/usr/bin/g++" CACHE FILEPATH "Preferred C++ compiler" FORCE)
endif()

project(filefs_cpp LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

add_library(filefs
  src/util.cpp
  src/mount.cpp
  src/block.cpp
  src/txn.cpp
  src/journal.cpp
  src/fopen.cpp
  src/fopen_helpers.cpp
  src/readwrite.cpp
  src/seek.cpp
  src/exist.cpp
  src/remove.cpp
  src/rename.cpp
  src/move.cpp
  src/copy.cpp
  src/pwd.cpp
  src/mkdir.cpp
  src/rmdir.cpp
  src/readdir.cpp
)

target_include_directories(filefs
  PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}/include
  PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/src
)

target_compile_options(filefs PRIVATE -O2 -Wall -Wextra)

add_executable(filefs_tests tests/test_filefs.cpp)
target_link_libraries(filefs_tests PRIVATE filefs)
target_compile_options(filefs_tests PRIVATE -O2 -Wall -Wextra)

enable_testing()
add_test(NAME filefs_tests COMMAND filefs_tests)
