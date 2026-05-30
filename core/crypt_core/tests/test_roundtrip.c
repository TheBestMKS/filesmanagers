#include <stdio.h>
#include <string.h>

#include "crypt/api.h"

static int expect_status(const char* label, crypt_status_t actual, crypt_status_t expected) {
    if (actual != expected) {
        fprintf(stderr, "%s: expected %s, got %s\n",
                label,
                crypt_status_string(expected),
                crypt_status_string(actual));
        return 1;
    }
    return 0;
}

static int test_common_header_roundtrip(void) {
    crypt_common_header_t header;
    uint8_t buffer[CRYPT_COMMON_HEADER_SIZE];
    size_t written = 0;
    size_t consumed = 0;
    crypt_common_header_t parsed;

    if (expect_status("common_init",
                      crypt_common_header_init(&header, CRYPT_CONTAINER_FILE, CRYPT_FILE_CONTAINER_FIXED_SIZE, 0),
                      CRYPT_STATUS_OK)) {
        return 1;
    }
    if (expect_status("common_write",
                      crypt_common_header_write(&header, buffer, sizeof(buffer), &written),
                      CRYPT_STATUS_OK)) {
        return 1;
    }
    if (written != CRYPT_COMMON_HEADER_SIZE) {
        fprintf(stderr, "common_write: unexpected size %zu\n", written);
        return 1;
    }
    if (expect_status("common_read",
                      crypt_common_header_read(buffer, sizeof(buffer), &parsed, &consumed),
                      CRYPT_STATUS_OK)) {
        return 1;
    }
    if (consumed != CRYPT_COMMON_HEADER_SIZE) {
        fprintf(stderr, "common_read: unexpected consumed %zu\n", consumed);
        return 1;
    }
    if (expect_status("common_validate",
                      crypt_common_header_validate(&parsed, CRYPT_CONTAINER_FILE, CRYPT_FILE_CONTAINER_FIXED_SIZE),
                      CRYPT_STATUS_OK)) {
        return 1;
    }
    return 0;
}

static int test_folder_meta_roundtrip(void) {
    crypt_folder_meta_t meta;
    crypt_tlv_t tlvs[1];
    uint8_t tlv_value[3] = {0xAA, 0xBB, 0xCC};
    uint8_t encrypted_name[5] = {1, 2, 3, 4, 5};
    uint8_t encrypted_preview[2] = {9, 8};
    uint8_t buffer[256];
    size_t written = 0;
    size_t consumed = 0;
    crypt_folder_meta_t parsed;

    memset(&meta, 0, sizeof(meta));
    crypt_folder_meta_init(&meta);
    meta.common.extension_count = 1;
    meta.name_kdf_id = CRYPT_ALG_ARGON2ID;
    meta.name_cipher_id = CRYPT_ALG_XCHACHA20_POLY1305;
    meta.preview_type = CRYPT_PREVIEW_NONE;
    meta.created_at_utc_ms = 1000;
    meta.updated_at_utc_ms = 2000;
    meta.encrypted_name = encrypted_name;
    meta.encrypted_name_len = sizeof(encrypted_name);
    meta.encrypted_preview = encrypted_preview;
    meta.encrypted_preview_len = sizeof(encrypted_preview);
    meta.tlvs = tlvs;
    meta.tlv_count = 1;
    tlvs[0].tag = 7;
    tlvs[0].length = sizeof(tlv_value);
    tlvs[0].value = tlv_value;
    meta.folder_id[0] = 0x11;
    meta.parent_folder_id[0] = 0x22;

    if (expect_status("folder_write",
                      crypt_folder_meta_write(&meta, buffer, sizeof(buffer), &written),
                      CRYPT_STATUS_OK)) {
        return 1;
    }
    if (expect_status("folder_read",
                      crypt_folder_meta_read(buffer, written, &parsed, &consumed),
                      CRYPT_STATUS_OK)) {
        return 1;
    }
    if (consumed != written) {
        fprintf(stderr, "folder_read: consumed %zu != written %zu\n", consumed, written);
        return 1;
    }
    if (parsed.encrypted_name_len != sizeof(encrypted_name) ||
        parsed.encrypted_preview_len != sizeof(encrypted_preview) ||
        parsed.tlv_count != 1 ||
        parsed.tlvs[0].tag != 7 ||
        parsed.folder_id[0] != 0x11 ||
        parsed.parent_folder_id[0] != 0x22) {
        fprintf(stderr, "folder_roundtrip: content mismatch\n");
        return 1;
    }
    return 0;
}

static int test_file_container_roundtrip(void) {
    crypt_file_container_t container;
    crypt_tlv_t tlvs[1];
    uint8_t tlv_value[2] = {0x01, 0x02};
    uint8_t encrypted_header[4] = {3, 3, 3, 3};
    uint8_t encrypted_payload[6] = {4, 4, 4, 4, 4, 4};
    uint8_t buffer[512];
    size_t written = 0;
    size_t consumed = 0;
    crypt_file_container_t parsed;

    memset(&container, 0, sizeof(container));
    crypt_file_container_init(&container);
    container.common.extension_count = 1;
    container.header_kdf_id = CRYPT_ALG_ARGON2ID;
    container.header_cipher_id = CRYPT_ALG_XCHACHA20_POLY1305;
    container.payload_cipher_id = CRYPT_ALG_XCHACHA20_POLY1305_CHUNKED_V1;
    container.preview_type = CRYPT_PREVIEW_JPEG;
    container.created_at_utc_ms = 111;
    container.updated_at_utc_ms = 222;
    container.original_size = 12345;
    container.stored_size = sizeof(encrypted_payload);
    container.chunk_size = 65536;
    container.encrypted_header = encrypted_header;
    container.encrypted_header_len = sizeof(encrypted_header);
    container.encrypted_payload = encrypted_payload;
    container.encrypted_payload_len = sizeof(encrypted_payload);
    container.tlvs = tlvs;
    container.tlv_count = 1;
    tlvs[0].tag = 9;
    tlvs[0].length = sizeof(tlv_value);
    tlvs[0].value = tlv_value;
    container.file_id[0] = 0x33;
    container.parent_folder_id[0] = 0x44;

    if (expect_status("file_write",
                      crypt_file_container_write(&container, buffer, sizeof(buffer), &written),
                      CRYPT_STATUS_OK)) {
        return 1;
    }
    if (expect_status("file_read",
                      crypt_file_container_read(buffer, written, &parsed, &consumed),
                      CRYPT_STATUS_OK)) {
        return 1;
    }
    if (consumed != written) {
        fprintf(stderr, "file_read: consumed %zu != written %zu\n", consumed, written);
        return 1;
    }
    if (parsed.file_id[0] != 0x33 ||
        parsed.parent_folder_id[0] != 0x44 ||
        parsed.chunk_size != 65536 ||
        parsed.encrypted_header_len != sizeof(encrypted_header) ||
        parsed.encrypted_payload_len != sizeof(encrypted_payload) ||
        parsed.tlv_count != 1 ||
        parsed.tlvs[0].tag != 9) {
        fprintf(stderr, "file_roundtrip: content mismatch\n");
        return 1;
    }
    return 0;
}

static int test_invalid_reserved_rejected(void) {
    crypt_folder_meta_t meta;
    memset(&meta, 0, sizeof(meta));
    crypt_folder_meta_init(&meta);
    meta.name_kdf_id = CRYPT_ALG_ARGON2ID;
    meta.name_cipher_id = CRYPT_ALG_XCHACHA20_POLY1305;
    meta.reserved1 = 1;
    return expect_status("invalid_reserved",
                         crypt_folder_meta_validate(&meta),
                         CRYPT_STATUS_INVALID_RESERVED);
}

int main(void) {
    int failed = 0;
    failed |= test_common_header_roundtrip();
    failed |= test_folder_meta_roundtrip();
    failed |= test_file_container_roundtrip();
    failed |= test_invalid_reserved_rejected();
    if (failed) {
        return 1;
    }
    printf("crypt_core tests passed\n");
    return 0;
}
