cmake_minimum_required(VERSION 3.21)
project(OGrafFlameOFX LANGUAGES C CXX OBJC OBJCXX)

set(CMAKE_OSX_ARCHITECTURES arm64)
set(CMAKE_OSX_DEPLOYMENT_TARGET 13.0)
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_OBJCXX_STANDARD 20)
if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release)
endif()

set(TP ${CMAKE_CURRENT_SOURCE_DIR}/third_party)
set(CEF_ROOT ${TP}/cef)

add_library(cef_wrapper STATIC IMPORTED)
set_target_properties(cef_wrapper PROPERTIES
  IMPORTED_LOCATION ${CEF_ROOT}/build/libcef_dll_wrapper/libcef_dll_wrapper.a)

# --- the OFX plugin (loaded by Flame) ---
add_library(OGrafFlame MODULE
  src/Plugin.cpp
  src/Package.cpp
  src/Renderer.mm
  src/TestRender.mm)
target_include_directories(OGrafFlame PRIVATE ${CEF_ROOT} ${TP}/openfx/include ${TP}/json)
target_compile_options(OGrafFlame PRIVATE -fvisibility=hidden -fvisibility-inlines-hidden)
# Code that subclasses CEF types must match the wrapper's no-RTTI build.
set_source_files_properties(src/Renderer.mm PROPERTIES COMPILE_OPTIONS "-fno-rtti;-fobjc-arc")
set_source_files_properties(src/TestRender.mm PROPERTIES COMPILE_OPTIONS "-fobjc-arc")
target_link_libraries(OGrafFlame PRIVATE cef_wrapper
  "-framework Cocoa" "-framework ImageIO" "-framework CoreGraphics" "-framework UniformTypeIdentifiers")
set_target_properties(OGrafFlame PROPERTIES PREFIX "" SUFFIX ".ofx" OUTPUT_NAME OGrafFlame)

# --- Chromium helper process ---
add_executable(ograf_helper src/Helper.cpp)
target_include_directories(ograf_helper PRIVATE ${CEF_ROOT})
target_compile_options(ograf_helper PRIVATE -fno-rtti)
target_link_libraries(ograf_helper PRIVATE cef_wrapper)

# --- stand-alone test host ---
add_executable(ograf_harness tests/Harness.mm)
target_compile_options(ograf_harness PRIVATE -fobjc-arc)
target_link_libraries(ograf_harness PRIVATE "-framework Cocoa")

# --- minimal OFX host for automated tests ---
add_executable(ograf_mockhost tests/MockHost.mm)
target_include_directories(ograf_mockhost PRIVATE ${TP}/openfx/include)
target_compile_options(ograf_mockhost PRIVATE -fobjc-arc)
target_link_libraries(ograf_mockhost PRIVATE "-framework Cocoa" "-framework ImageIO" "-framework UniformTypeIdentifiers")

# --- unit test for the clip-to-template timing ---
add_executable(ograf_timing_test tests/TimingTest.cpp)
target_include_directories(ograf_timing_test PRIVATE src)
