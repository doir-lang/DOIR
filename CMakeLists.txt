cmake_minimum_required(VERSION 3.21)
project(DOIR CXX)

set(CMAKE_CXX_STANDARD 23)

add_subdirectory(cpp-peglib)
add_subdirectory(libecrs)

add_executable(doir driver.cpp)
target_link_libraries(doir PUBLIC libecrs peglib)