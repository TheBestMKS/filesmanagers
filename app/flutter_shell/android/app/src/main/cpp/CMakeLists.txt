cmake_minimum_required(VERSION 3.22.1)
project(secure_vault_android LANGUAGES C)

set(CMAKE_LIBRARY_OUTPUT_DIRECTORY ${CMAKE_CURRENT_BINARY_DIR}/../jniLibs/${ANDROID_ABI})

add_subdirectory(
    "${CMAKE_CURRENT_SOURCE_DIR}/../../../../../../../core/crypt_core"
    "${CMAKE_CURRENT_BINARY_DIR}/crypt_core_build"
)
