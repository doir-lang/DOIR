add_library(bench_common INTERFACE)
target_link_libraries(bench_common INTERFACE libfp::fp nanobench)
target_compile_definitions(bench_common INTERFACE -DBENCHMARK_PATH="${CMAKE_CURRENT_SOURCE_DIR}")
set_property(TARGET bench_common PROPERTY CXX_STANDARD 23)
set_property(TARGET bench_common PROPERTY C_STANDARD 23)

add_executable(bench_simpsons simpsons.cpp)
target_link_libraries(bench_simpsons PUBLIC bench_common)

add_executable(bench_list list.cpp)
target_link_libraries(bench_list PUBLIC bench_common)

add_executable(bench_typecheck type_check.cpp)
target_link_libraries(bench_typecheck PUBLIC bench_common)

add_executable(bench_graph graph.cpp)
target_link_libraries(bench_graph PUBLIC bench_common)