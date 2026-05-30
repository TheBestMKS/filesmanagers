#ifndef CRYPT_FILE_CONTAINER_H
#define CRYPT_FILE_CONTAINER_H

#include <stddef.h>
#include <stdint.h>

#include "crypt/common_header.h"

typedef struct crypt_file_container_s {
    crypt_common_header_t common;
    uint8_t file_id[CRYPT_ID_SIZE];
    uint8_t parent_folder_id[CRYPT_ID_SIZE];
    uint64_t created_at_utc_ms;
    uint64_t updated_at_utc_ms;
    uint64_t original_size;
    uint64_t stored_size;
    uint16_t header_kdf_id;
    uint16_t header_cipher_id;
    uint16_t payload_cipher_id;
    uint16_t preview_type;
    uint32_t chunk_size;
    uint32_t encrypted_header_len;
    const crypt_tlv_t* tlvs;
    size_t tlv_count;
    crypt_tlv_t parsed_tlvs[CRYPT_MAX_TLVS];
    const uint8_t* encrypted_header;
    const uint8_t* encrypted_payload;
    size_t encrypted_payload_len;
} crypt_file_container_t;

crypt_status_t crypt_file_container_init(crypt_file_container_t* container);
crypt_status_t crypt_file_container_validate(const crypt_file_container_t* container);
crypt_status_t crypt_file_container_write(const crypt_file_container_t* container,
                                          uint8_t* out_buffer,
                                          size_t out_buffer_size,
                                          size_t* out_written);
crypt_status_t crypt_file_container_read(const uint8_t* buffer,
                                         size_t buffer_size,
                                         crypt_file_container_t* out_container,
                                         size_t* out_consumed);

#endif
