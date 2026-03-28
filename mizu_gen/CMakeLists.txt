
add_executable(gen gen.cpp)
target_link_libraries(gen PUBLIC mizu_vm doir)

add_executable(bin2header bin2header.cpp)
target_link_libraries(bin2header PUBLIC mizu_vm doir)
