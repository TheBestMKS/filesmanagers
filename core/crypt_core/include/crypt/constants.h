#ifndef CRYPT_CONSTANTS_H
#define CRYPT_CONSTANTS_H

#include <stdint.h>

enum {
    CRYPT_FORMAT_MAJOR_V1 = 1,
    CRYPT_FORMAT_MINOR_V1_0 = 0,
    CRYPT_MAGIC_SIZE = 8,
    CRYPT_MAX_ALGORITHM_ID = 511,
    CRYPT_ID_SIZE = 16,
    CRYPT_MAX_TLVS = 16,
    CRYPT_COMMON_HEADER_SIZE = 26,
    CRYPT_FOLDER_META_FIXED_SIZE = 90,
    CRYPT_FILE_CONTAINER_FIXED_SIZE = 106
};

typedef enum crypt_container_type_e {
    CRYPT_CONTAINER_FILE = 1,
    CRYPT_CONTAINER_FOLDER_META = 2
} crypt_container_type_t;

typedef enum crypt_algorithm_id_e {
    CRYPT_ALG_NONE = 0,
    CRYPT_ALG_ARGON2ID = 1,
    CRYPT_ALG_XCHACHA20_POLY1305 = 1,
    CRYPT_ALG_XCHACHA20_POLY1305_CHUNKED_V1 = 1
} crypt_algorithm_id_t;

typedef enum crypt_preview_type_e {
    CRYPT_PREVIEW_NONE = 0,
    CRYPT_PREVIEW_JPEG = 1,
    CRYPT_PREVIEW_WEBP = 2,
    CRYPT_PREVIEW_PNG = 3
} crypt_preview_type_t;

typedef struct crypt_tlv_s {
    uint16_t tag;
    uint16_t length;
    const uint8_t* value;
} crypt_tlv_t;

#endif
