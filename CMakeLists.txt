cmake_minimum_required(VERSION 3.21)
project(DOIR CXX)

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

add_subdirectory(cpp-peglib)
add_subdirectory(libecrs)
ADD_SUBDIRECTORY(libdiagnose)

add_executable(doir
	driver.cpp diagnostics.cpp interface.cpp interface.verify.cpp module.cpp print.cpp parser.cpp
	sema/canonicalize/sort.cpp
)
target_link_libraries(doir PUBLIC libecrs diagnose peglib)
if(MSVC)
	target_compile_options(doir PUBLIC /std:c++latest)
endif()
