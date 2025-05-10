cmake_minimum_required(VERSION 3.21)
project(DOIR LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_C_STANDARD 23)

if(CMAKE_BUILD_TYPE MATCHES Debug)
	set(DOIR_PROFILE_DEFAULT false)
else()
	set(CMAKE_INTERPROCEDURAL_OPTIMIZATION true)
	set(DOIR_PROFILE_DEFAULT ${PROJECT_IS_TOP_LEVEL})
endif()

option(DOIR_ENABLE_TESTS "Weather or not Unit Tests should be built." ${PROJECT_IS_TOP_LEVEL})
option(DOIR_ENABLE_PROFILING "Weather or not profiling instrumentation will be added." ${DOIR_PROFILE_DEFAULT})
option(DOIR_ENABLE_CODE_COVERAGE "Weather or not targets to generated a code coverage report should be created." false)

# set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -fsanitize=address")

include(scripts/flex-bison.cmake)
fetch_flex_bison()
add_subdirectory(thirdparty/libfp)

add_library(nowide thirdparty/nowide-standalone/src/iostream.cpp)
target_include_directories(nowide PUBLIC thirdparty/nowide-standalone/include) #NOTE: Anything using libfp also gets nowide
target_link_libraries(libfp INTERFACE nowide)

add_executable(hello hello.cpp)
target_link_libraries(hello PUBLIC libfp::fp)

add_subdirectory(src/Calculator)
add_subdirectory(src/JSON)
add_subdirectory(src/Lox)

if(${DOIR_ENABLE_TESTS})
	include(FetchContent) # once in the project to include the module

	# FetchContent_Declare(fetch_lox GIT_REPOSITORY https://github.com/munificent/craftinginterpreters GIT_SHALLOW true)
	# FetchContent_MakeAvailable(fetch_lox)

	if(TARGET doctest)
	else()
		FetchContent_Declare(fetch_doctest GIT_REPOSITORY https://github.com/doctest/doctest.git GIT_SHALLOW true)
		FetchContent_MakeAvailable(fetch_doctest)
	endif()

	if(TARGET nanobench)
	else()
		FetchContent_Declare(fetch_nanobench GIT_REPOSITORY https://github.com/martinus/nanobench.git GIT_SHALLOW true)
		FetchContent_MakeAvailable(fetch_nanobench)
	endif()

	file(GLOB sources "tests/*.cpp")
	add_executable(tst ${sources})
	target_link_libraries(tst PUBLIC libfp::fp calculator json lox doctest nanobench)
	set_property(TARGET tst PROPERTY CXX_STANDARD 23)
	set_property(TARGET tst PROPERTY C_STANDARD 23)

	if(${DOIR_ENABLE_CODE_COVERAGE})
		include(${CMAKE_SOURCE_DIR}/cmake/CodeCoverage.cmake)
		append_coverage_compiler_flags_to_target(tst)
		target_compile_definitions(tst PUBLIC DOIR_DISABLE_FLEX_BISON)
		setup_target_for_coverage_gcovr_html(
			NAME coverage
			EXECUTABLE "tst"
			# BASE_DIRECTORY "${PROJECT_SOURCE_DIR}"
			EXCLUDE "olddoir/*" "build/*"
		)
		setup_target_for_coverage_gcovr_xml(
			NAME coverage_xml
			EXECUTABLE "tst"
			# BASE_DIRECTORY "${PROJECT_SOURCE_DIR}"
			EXCLUDE "olddoir/*" "build/*"
		)
	endif()
else()
	target_compile_definitions(tst PRIVATE DOCTEST_CONFIG_DISABLE)
endif()

if(${DOIR_ENABLE_PROFILING})
	option(DOIR_BUILD_TRACY_PROFILER "Weather or not to build the server needed to view trace results." ON)

	set(TRACY_NO_EXIT ON CACHE BOOL "Client executable does not exit until all profile data is sent to server")

	FetchContent_Declare(fetch_tracy GIT_REPOSITORY https://github.com/wolfpld/tracy GIT_SHALLOW true)
	FetchContent_MakeAvailable(fetch_tracy)

	target_link_libraries(calculator PUBLIC TracyClient)
	target_compile_definitions(calculator PUBLIC DOIR_ENABLE_PROFILING)
	target_link_libraries(tst PUBLIC TracyClient)
	target_compile_definitions(tst PUBLIC DOIR_ENABLE_PROFILING)

	if(${DOIR_BUILD_TRACY_PROFILER})
		set(LEGACY ON CACHE BOOL "Instead of Wayland, use the legacy X11 backend on Linux")
		add_subdirectory(${CMAKE_BINARY_DIR}/_deps/fetch_tracy-src/profiler/)
	endif()
else()
	target_include_directories(tst PUBLIC thirdparty/stubs)
	target_compile_definitions(tst PRIVATE DOIR_ENABLE_BENCHMARKING)
endif()