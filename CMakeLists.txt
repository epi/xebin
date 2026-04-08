cmake_minimum_required(VERSION 3.20)

project(xebin LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# ---------------------------------------------------------------------------
# Library
# ---------------------------------------------------------------------------
add_library(libxebin STATIC
    lib/xex.cpp
    lib/compress.cpp
    lib/rle.cpp
    lib/lz77.cpp
)
set_target_properties(libxebin PROPERTIES OUTPUT_NAME xebin)
target_include_directories(libxebin PUBLIC include)
target_compile_options(libxebin PRIVATE -Wall -Wextra -Wpedantic)

# ---------------------------------------------------------------------------
# CLI tool
# ---------------------------------------------------------------------------
add_executable(xebin tools/xebin.cpp)
set_target_properties(xebin PROPERTIES OUTPUT_NAME xebin)
target_link_libraries(xebin PRIVATE libxebin)
target_compile_options(xebin PRIVATE -Wall -Wextra -Wpedantic)

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------
find_package(Catch2 3 REQUIRED)
enable_testing()

add_executable(test_rle tests/test_rle.cpp)
target_link_libraries(test_rle PRIVATE libxebin Catch2::Catch2WithMain)
target_compile_options(test_rle PRIVATE -Wall -Wextra -Wpedantic)
add_test(NAME rle COMMAND test_rle)

add_executable(test_lz77 tests/test_lz77.cpp)
target_link_libraries(test_lz77 PRIVATE libxebin Catch2::Catch2WithMain)
target_compile_options(test_lz77 PRIVATE -Wall -Wextra -Wpedantic)
add_test(NAME lz77 COMMAND test_lz77)
