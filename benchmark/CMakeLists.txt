add_library(bench_common INTERFACE)
target_link_libraries(bench_common INTERFACE libfp::fp nanobench)
target_compile_definitions(bench_common INTERFACE -DBENCHMARK_PATH="${CMAKE_CURRENT_SOURCE_DIR}")
set_property(TARGET bench_common PROPERTY CXX_STANDARD 23)
set_property(TARGET bench_common PROPERTY C_STANDARD 23)

add_executable(bench_simpsons_impl simpsons.cpp)
target_link_libraries(bench_simpsons_impl PUBLIC bench_common)

add_executable(bench_simpsons simpsons.bench.cpp)
target_link_libraries(bench_simpsons PUBLIC bench_common)

add_executable(bench_list_impl list.cpp)
target_link_libraries(bench_list_impl PUBLIC bench_common)

add_executable(bench_list list.bench.cpp)
target_link_libraries(bench_list PUBLIC bench_common)

add_executable(bench_typecheck_impl type_check.cpp)
target_link_libraries(bench_typecheck_impl PUBLIC bench_common)

add_executable(bench_typecheck type_check.bench.cpp)
target_link_libraries(bench_typecheck PUBLIC bench_common)

add_executable(bench_typeinfer_impl type_infer.cpp)
target_link_libraries(bench_typeinfer_impl PUBLIC bench_common)

add_executable(bench_typeinfer type_infer.bench.cpp)
target_link_libraries(bench_typeinfer PUBLIC bench_common)

set(GRAPH_NODE_COUNT 5)
configure_file(graph.cpp.in graph5.cpp)
add_executable(graph5.ecs graph5.cpp)
target_link_libraries(graph5.ecs PUBLIC bench_common)

set(GRAPH_NODE_COUNT 10)
configure_file(graph.cpp.in graph10.cpp)
add_executable(graph10.ecs graph10.cpp)
target_link_libraries(graph10.ecs PUBLIC bench_common)

set(GRAPH_NODE_COUNT 15)
configure_file(graph.cpp.in graph15.cpp)
add_executable(graph15.ecs graph15.cpp)
target_link_libraries(graph15.ecs PUBLIC bench_common)

set(GRAPH_NODE_COUNT 20)
configure_file(graph.cpp.in graph20.cpp)
add_executable(graph20.ecs graph20.cpp)
target_link_libraries(graph20.ecs PUBLIC bench_common)

set(GRAPH_NODE_COUNT 25)
configure_file(graph.cpp.in graph25.cpp)
add_executable(graph25.ecs graph25.cpp)
target_link_libraries(graph25.ecs PUBLIC bench_common)

set(GRAPH_NODE_COUNT 50)
configure_file(graph.cpp.in graph50.cpp)
add_executable(graph50.ecs graph50.cpp)
target_link_libraries(graph50.ecs PUBLIC bench_common)

set(GRAPH_NODE_COUNT 100)
configure_file(graph.cpp.in graph100.cpp)
add_executable(graph100.ecs graph100.cpp)
target_link_libraries(graph100.ecs PUBLIC bench_common)

set(GRAPH_NODE_COUNT 500)
configure_file(graph.cpp.in graph500.cpp)
add_executable(graph500.ecs graph500.cpp)
target_link_libraries(graph500.ecs PUBLIC bench_common)

set(GRAPH_NODE_COUNT 1000)
configure_file(graph.cpp.in graph1000.cpp)
add_executable(graph1000.ecs graph1000.cpp)
target_link_libraries(graph1000.ecs PUBLIC bench_common)

add_executable(bench_graph graph.cpp)
target_link_libraries(bench_graph PUBLIC bench_common)