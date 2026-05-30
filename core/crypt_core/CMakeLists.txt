set(CRYPT_CORE_SOURCES
    src/api.c
    src/common_header.c
    src/folder_meta.c
    src/file_container.c
)

add_library(crypt_core SHARED ${CRYPT_CORE_SOURCES})
target_compile_features(crypt_core PRIVATE c_std_17)
target_include_directories(crypt_core
    PUBLIC
        ${CMAKE_CURRENT_SOURCE_DIR}/include
    PRIVATE
        ${CMAKE_CURRENT_SOURCE_DIR}/src
)
target_compile_definitions(crypt_core PRIVATE CRYPT_CORE_BUILD)

if (BUILD_TESTING AND NOT ANDROID)
    add_executable(crypt_core_tests
        tests/test_roundtrip.c
        ${CRYPT_CORE_SOURCES}
    )
    target_compile_features(crypt_core_tests PRIVATE c_std_17)
    target_include_directories(crypt_core_tests
        PRIVATE
            ${CMAKE_CURRENT_SOURCE_DIR}/include
            ${CMAKE_CURRENT_SOURCE_DIR}/src
    )
    target_compile_definitions(crypt_core_tests PRIVATE CRYPT_CORE_BUILD)

    add_test(NAME crypt_core_tests COMMAND crypt_core_tests)
endif()
