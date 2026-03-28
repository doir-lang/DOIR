cmake_minimum_required(VERSION 3.21)
project(DOIR CXX)

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

add_subdirectory(cpp-peglib)
add_subdirectory(Mizu)
add_subdirectory(libecrs)
ADD_SUBDIRECTORY(libdiagnose)

add_library(doir
	diagnostics.cpp interface.cpp interface.copy.cpp interface.global_block.cpp interface.verify.cpp
	module.cpp print.cpp parser.cpp
	sema/canonicalize/sort.cpp sema/lookup.cpp
	opt/inline_functions.cpp opt/compute_compiler_namespace.cpp
)
target_link_libraries(doir PUBLIC libecrs diagnose peglib)
target_include_directories(doir PUBLIC ${CMAKE_CURRENT_SOURCE_DIR})
if(MSVC)
	target_compile_options(doir PUBLIC /std:c++latest)
endif()

add_executable(doirEXE driver.cpp)
target_link_libraries(doirEXE PUBLIC doir)
set_target_properties(doirEXE PROPERTIES OUTPUT_NAME "doir")

add_subdirectory(mizu_gen)
