#ifndef CRYPT_API_H
#define CRYPT_API_H

#include <stddef.h>
#include <stdint.h>

#include "crypt/common_header.h"
#include "crypt/constants.h"
#include "crypt/export.h"
#include "crypt/file_container.h"
#include "crypt/folder_meta.h"
#include "crypt/status.h"

typedef struct crypt_runtime_info_s {
    uint16_t api_major;
    uint16_t api_minor;
    uint16_t format_major;
    uint16_t format_minor;
    uint16_t android_min_sdk;
    uint16_t reserved0;
    uint32_t capabilities;
} crypt_runtime_info_t;

typedef struct crypt_probe_result_s {
    uint16_t status_code;
    uint16_t container_type;
    uint16_t format_major;
    uint16_t format_minor;
    uint16_t header_size;
    uint16_t extension_count;
    uint32_t flags;
} crypt_probe_result_t;

typedef struct crypt_folder_meta_summary_s {
    uint16_t status_code;
    uint16_t preview_type;
    uint16_t name_kdf_id;
    uint16_t name_cipher_id;
    uint64_t created_at_utc_ms;
    uint64_t updated_at_utc_ms;
    uint32_t encrypted_name_len;
    uint32_t encrypted_preview_len;
    uint8_t folder_id[CRYPT_ID_SIZE];
    uint8_t parent_folder_id[CRYPT_ID_SIZE];
} crypt_folder_meta_summary_t;

typedef struct crypt_file_container_summary_s {
    uint16_t status_code;
    uint16_t preview_type;
    uint16_t header_kdf_id;
    uint16_t header_cipher_id;
    uint16_t payload_cipher_id;
    uint16_t reserved_align0;
    uint32_t reserved_align1;
    uint64_t created_at_utc_ms;
    uint64_t updated_at_utc_ms;
    uint64_t original_size;
    uint64_t stored_size;
    uint32_t chunk_size;
    uint32_t encrypted_header_len;
    uint32_t encrypted_payload_len;
    uint8_t file_id[CRYPT_ID_SIZE];
    uint8_t parent_folder_id[CRYPT_ID_SIZE];
} crypt_file_container_summary_t;

enum {
    CRYPT_CAP_COMMON_HEADER = 1u << 0,
    CRYPT_CAP_FOLDER_META = 1u << 1,
    CRYPT_CAP_FILE_CONTAINER = 1u << 2,
    CRYPT_CAP_STRICT_VALIDATION = 1u << 3,
    CRYPT_CAP_TLV_EXTENSIONS = 1u << 4
};

CRYPT_API crypt_status_t crypt_get_runtime_info(crypt_runtime_info_t* out_info);
CRYPT_API crypt_status_t crypt_probe_container(const uint8_t* buffer,
                                               size_t buffer_size,
                                               crypt_probe_result_t* out_result);
CRYPT_API crypt_status_t crypt_read_folder_meta_summary(const uint8_t* buffer,
                                                        size_t buffer_size,
                                                        crypt_folder_meta_summary_t* out_summary);
CRYPT_API crypt_status_t crypt_read_file_container_summary(const uint8_t* buffer,
                                                           size_t buffer_size,
                                                           crypt_file_container_summary_t* out_summary);

#endif
