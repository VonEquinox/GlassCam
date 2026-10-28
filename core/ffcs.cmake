# Include from core/CMakeLists.txt. HNCS is an independent, unchanged target.
find_package(ZLIB REQUIRED)
find_package(Threads REQUIRED)
add_library(glasscam_ffcs STATIC ${CMAKE_CURRENT_LIST_DIR}/ffcs.cpp)
target_link_libraries(glasscam_ffcs PUBLIC ZLIB::ZLIB Threads::Threads)
target_compile_features(glasscam_ffcs PUBLIC cxx_std_17)
target_include_directories(glasscam_ffcs PUBLIC ${CMAKE_CURRENT_LIST_DIR})
if(CMAKE_CXX_COMPILER_ID MATCHES "Clang|GNU")
  target_compile_options(glasscam_ffcs PRIVATE -O3 -fno-fast-math -ffp-contract=off -Wall -Wextra -Wpedantic)
elseif(MSVC)
  target_compile_options(glasscam_ffcs PRIVATE /O2 /fp:strict)
endif()

# Override for installed/external LUT assets; the default uses the delivery subset.
set(FFCS_RESOURCE_DIRECTORY "${CMAKE_CURRENT_LIST_DIR}/../vendor/ffcs/implementation/ffcs/data/xh2s"
    CACHE PATH "Directory containing the 19 original XH2S FFCS .lutz resources")
add_executable(ffcs_smoke ${CMAKE_CURRENT_LIST_DIR}/ffcs_smoke.cpp)
target_link_libraries(ffcs_smoke PRIVATE glasscam_ffcs)
add_test(NAME ffcs_smoke COMMAND ffcs_smoke "${FFCS_RESOURCE_DIRECTORY}")
