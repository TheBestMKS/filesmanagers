#ifndef CRYPT_FOLDER_META_H
#define CRYPT_FOLDER_META_H

#include <stddef.h>
#include <stdint.h>

#include "crypt/common_header.h"

typedef struct crypt_folder_meta_s {
    crypt_common_header_t common;
    uint8_t folder_id[CRYPT_ID_SIZE];
    uint8_t parent_folder_id[CRYPT_ID_SIZE];
    uint64_t created_at_utc_ms;
    uint64_t updated_at_utc_ms;
    uint16_t name_kdf_id;
    uint16_t name_cipher_id;
    uint16_t preview_type;
    uint16_t reserved1;
    uint32_t encrypted_name_len;
    uint32_t encrypted_preview_len;
    const crypt_tlv_t* tlvs;
    size_t tlv_count;
    crypt_tlv_t parsed_tlvs[CRYPT_MAX_TLVS];
    const uint8_t* encrypted_name;
    const uint8_t* encrypted_preview;
} crypt_folder_meta_t;

crypt_status_t crypt_folder_meta_init(crypt_folder_meta_t* meta);
crypt_status_t crypt_folder_meta_validate(const crypt_folder_meta_t* meta);
crypt_status_t crypt_folder_meta_write(const crypt_folder_meta_t* meta,
                                       uint8_t* out_buffer,
                                       size_t out_buffer_size,
                                       size_t* out_written);
crypt_status_t crypt_folder_meta_read(const uint8_t* buffer,
                                      size_t buffer_size,
                                      crypt_folder_meta_t* out_meta,
                                      size_t* out_consumed);

#endif
