cmake_minimum_required(VERSION 3.24)

project(tpf2mp_native VERSION 0.1.0 LANGUAGES C CXX)

if(NOT WIN32 OR NOT CMAKE_SIZEOF_VOID_P EQUAL 8)
  message(FATAL_ERROR "The TPF2MP native probe only supports 64-bit Windows.")
endif()

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(BUILD_SHARED_LIBS OFF CACHE BOOL "Build static dependencies" FORCE)

add_subdirectory(third_party/minhook EXCLUDE_FROM_ALL)

add_library(tpf2mp_native_common STATIC
  src/native_common.cpp
)
target_include_directories(tpf2mp_native_common PUBLIC include)
target_compile_definitions(tpf2mp_native_common PUBLIC UNICODE _UNICODE WIN32_LEAN_AND_MEAN NOMINMAX)
target_link_libraries(tpf2mp_native_common PUBLIC bcrypt)

add_library(tpf2mp_hook_support STATIC
  src/native_command_codec.cpp
  src/native_vehicle_command_codec.cpp
  src/native_hook_status.cpp
  src/native_launcher_barrier.cpp
)
target_link_libraries(tpf2mp_hook_support PUBLIC tpf2mp_native_common)
target_include_directories(tpf2mp_hook_support PUBLIC include)
target_compile_definitions(tpf2mp_hook_support PUBLIC UNICODE _UNICODE WIN32_LEAN_AND_MEAN NOMINMAX)

add_library(tpf2mp_hook SHARED
  src/hook_dll.cpp
)
target_include_directories(tpf2mp_hook PRIVATE include)
target_compile_definitions(tpf2mp_hook PRIVATE TPF2MP_HOOK_EXPORTS)
target_link_libraries(tpf2mp_hook PRIVATE tpf2mp_native_common tpf2mp_hook_support minhook)
set_target_properties(tpf2mp_hook PROPERTIES OUTPUT_NAME "tpf2mp_hook_build35924")

add_executable(tpf2mp_injector
  src/injector.cpp
)
target_include_directories(tpf2mp_injector PRIVATE include)
target_link_libraries(tpf2mp_injector PRIVATE tpf2mp_native_common)

add_executable(tpf2mp_native_tests
  tests/native_tests.cpp
)
target_include_directories(tpf2mp_native_tests PRIVATE include)
target_link_libraries(tpf2mp_native_tests PRIVATE tpf2mp_native_common tpf2mp_hook_support)

add_executable(tpf2mp_dll_load_test
  tests/dll_load_test.cpp
)
target_include_directories(tpf2mp_dll_load_test PRIVATE include)
target_link_libraries(tpf2mp_dll_load_test PRIVATE tpf2mp_native_common)

foreach(target tpf2mp_native_common tpf2mp_hook_support tpf2mp_hook tpf2mp_injector tpf2mp_native_tests tpf2mp_dll_load_test)
  target_compile_options(${target} PRIVATE /W4 /permissive- /EHsc /utf-8)
endforeach()

enable_testing()
add_test(NAME pinned_profile_usage COMMAND tpf2mp_native_tests)
add_test(NAME dll_rejects_unpinned_process
  COMMAND tpf2mp_dll_load_test $<TARGET_FILE:tpf2mp_hook>
)
