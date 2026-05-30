#include "crypt/api.h"

#include <string.h>

static void crypt_zero_bytes(void* ptr, size_t size) {
    memset(ptr, 0, size);
}

crypt_status_t crypt_get_runtime_info(crypt_runtime_info_t* out_info) {
    if (out_info == NULL) {
        return CRYPT_STATUS_INVALID_ARGUMENT;
    }

    crypt_zero_bytes(out_info, sizeof(*out_info));
    out_info->api_major = 1;
    out_info->api_minor = 0;
    out_info->format_major = CRYPT_FORMAT_MAJOR_V1;
    out_info->format_minor = CRYPT_FORMAT_MINOR_V1_0;
    out_info->android_min_sdk = 24;
    out_info->capabilities = CRYPT_CAP_COMMON_HEADER |
                             CRYPT_CAP_FOLDER_META |
                             CRYPT_CAP_FILE_CONTAINER |
                             CRYPT_CAP_STRICT_VALIDATION |
                             CRYPT_CAP_TLV_EXTENSIONS;
    return CRYPT_STATUS_OK;
}

crypt_status_t crypt_probe_container(const uint8_t* buffer,
                                     size_t buffer_size,
                                     crypt_probe_result_t* out_result) {
    crypt_common_header_t header;
    size_t consumed = 0;
    crypt_status_t st;

    if (buffer == NULL || out_result == NULL) {
        return CRYPT_STATUS_INVALID_ARGUMENT;
    }

    crypt_zero_bytes(out_result, sizeof(*out_result));
    st = crypt_common_header_read(buffer, buffer_size, &header, &consumed);
    out_result->status_code = (uint16_t)st;
    if (st != CRYPT_STATUS_OK) {
        return st;
    }

    out_result->container_type = header.container_type;
    out_result->format_major = header.format_major;
    out_result->format_minor = header.format_minor;
    out_result->header_size = header.header_size;
    out_result->extension_count = header.extension_count;
    out_result->flags = header.flags;

    switch (header.container_type) {
        case CRYPT_CONTAINER_FILE:
            st = crypt_common_header_validate(&header,
                                              CRYPT_CONTAINER_FILE,
                                              CRYPT_FILE_CONTAINER_FIXED_SIZE);
            break;
        case CRYPT_CONTAINER_FOLDER_META:
            st = crypt_common_header_validate(&header,
                                              CRYPT_CONTAINER_FOLDER_META,
                                              CRYPT_FOLDER_META_FIXED_SIZE);
            break;
        default:
            st = CRYPT_STATUS_UNSUPPORTED_CONTAINER;
            break;
    }

    out_result->status_code = (uint16_t)st;
    return st;
}

crypt_status_t crypt_read_folder_meta_summary(const uint8_t* buffer,
                                              size_t buffer_size,
                                              crypt_folder_meta_summary_t* out_summary) {
    crypt_folder_meta_t meta;
    size_t consumed = 0;
    crypt_status_t st;

    if (buffer == NULL || out_summary == NULL) {
        return CRYPT_STATUS_INVALID_ARGUMENT;
    }

    crypt_zero_bytes(out_summary, sizeof(*out_summary));
    st = crypt_folder_meta_read(buffer, buffer_size, &meta, &consumed);
    out_summary->status_code = (uint16_t)st;
    if (st != CRYPT_STATUS_OK) {
        return st;
    }

    out_summary->preview_type = meta.preview_type;
    out_summary->name_kdf_id = meta.name_kdf_id;
    out_summary->name_cipher_id = meta.name_cipher_id;
    out_summary->created_at_utc_ms = meta.created_at_utc_ms;
    out_summary->updated_at_utc_ms = meta.updated_at_utc_ms;
    out_summary->encrypted_name_len = meta.encrypted_name_len;
    out_summary->encrypted_preview_len = meta.encrypted_preview_len;
    memcpy(out_summary->folder_id, meta.folder_id, CRYPT_ID_SIZE);
    memcpy(out_summary->parent_folder_id, meta.parent_folder_id, CRYPT_ID_SIZE);
    return CRYPT_STATUS_OK;
}

crypt_status_t crypt_read_file_container_summary(const uint8_t* buffer,
                                                 size_t buffer_size,
                                                 crypt_file_container_summary_t* out_summary) {
    crypt_file_container_t container;
    size_t consumed = 0;
    crypt_status_t st;

    if (buffer == NULL || out_summary == NULL) {
        return CRYPT_STATUS_INVALID_ARGUMENT;
    }

    crypt_zero_bytes(out_summary, sizeof(*out_summary));
    st = crypt_file_container_read(buffer, buffer_size, &container, &consumed);
    out_summary->status_code = (uint16_t)st;
    if (st != CRYPT_STATUS_OK) {
        return st;
    }

    out_summary->preview_type = container.preview_type;
    out_summary->header_kdf_id = container.header_kdf_id;
    out_summary->header_cipher_id = container.header_cipher_id;
    out_summary->payload_cipher_id = container.payload_cipher_id;
    out_summary->reserved_align0 = 0;
    out_summary->reserved_align1 = 0;
    out_summary->created_at_utc_ms = container.created_at_utc_ms;
    out_summary->updated_at_utc_ms = container.updated_at_utc_ms;
    out_summary->original_size = container.original_size;
    out_summary->stored_size = container.stored_size;
    out_summary->chunk_size = container.chunk_size;
    out_summary->encrypted_header_len = container.encrypted_header_len;
    out_summary->encrypted_payload_len = (uint32_t)container.encrypted_payload_len;
    memcpy(out_summary->file_id, container.file_id, CRYPT_ID_SIZE);
    memcpy(out_summary->parent_folder_id, container.parent_folder_id, CRYPT_ID_SIZE);
    return CRYPT_STATUS_OK;
}
