cmake_minimum_required(VERSION 3.18.1)
project(coordi_net_agent LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

file(GLOB SLICER_SOURCES third_party/slicer/*.cc)

add_library(coordi_net_agent SHARED
    src/agent.cpp
    src/socket_emitter.cpp
    src/url_connection_hooks.cpp
    src/dex_instrument.cpp
    src/probe_loader.cpp
    ${SLICER_SOURCES}
)

target_include_directories(coordi_net_agent PRIVATE
    third_party/slicer
    third_party/slicer/export
)

# slicer (AOSP dexter) usa RTTI (dynamic_cast) y excepciones: no deshabilitarlas.
target_compile_options(coordi_net_agent PRIVATE
    -Wall -Wextra
)

# JVMTI headers ship with the Android NDK under the ART runtime.
if(DEFINED ENV{ANDROID_NDK_HOME})
    set(_NDK $ENV{ANDROID_NDK_HOME})
elseif(DEFINED ENV{NDK})
    set(_NDK $ENV{NDK})
else()
    set(_NDK "${CMAKE_ANDROID_NDK}")
endif()

find_path(JVMTI_INCLUDE jvmti.h
    PATHS
        "${_NDK}/toolchains/llvm/prebuilt/*/sysroot/usr/include/art/runtime"
        "${_NDK}/toolchains/llvm/prebuilt/darwin-x86_64/sysroot/usr/include/art/runtime"
        "${_NDK}/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/include/art/runtime"
    NO_DEFAULT_PATH
)

if(JVMTI_INCLUDE)
    target_include_directories(coordi_net_agent PRIVATE "${JVMTI_INCLUDE}")
else()
    message(WARNING "jvmti.h not found — set ANDROID_NDK_HOME before building")
endif()

target_link_options(coordi_net_agent PRIVATE -static-libstdc++)
target_link_libraries(coordi_net_agent log z)
