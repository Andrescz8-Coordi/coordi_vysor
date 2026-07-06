cmake_minimum_required(VERSION 3.18.1)
project(coordi_net_agent LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

add_library(coordi_net_agent SHARED
    src/agent.cpp
    src/socket_emitter.cpp
    src/url_connection_hooks.cpp
)

target_compile_options(coordi_net_agent PRIVATE
    -Wall -Wextra -fno-exceptions -fno-rtti
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

target_link_libraries(coordi_net_agent log)
