#include "crypt/common_header.h"

#include <string.h>

#include "internal/le_io.h"
#include "internal/memory.h"

static const uint8_t k_crypt_magic[CRYPT_MAGIC_SIZE] = {'C', 'R', 'Y', 'P', 'T', 'F', 'M', 'T'};

static crypt_status_t crypt_validate_algorithm_id(uint16_t algorithm_id, int allow_zero) {
    if (algorithm_id > CRYPT_MAX_ALGORITHM_ID) {
        return CRYPT_STATUS_INVALID_ALGORITHM_ID;
    }
    if (!allow_zero && algorithm_id == 0) {
        return CRYPT_STATUS_INVALID_ALGORITHM_ID;
    }
    return CRYPT_STATUS_OK;
}

const char* crypt_status_string(crypt_status_t status) {
    switch (status) {
        case CRYPT_STATUS_OK: return "ok";
        case CRYPT_STATUS_INVALID_ARGUMENT: return "invalid_argument";
        case CRYPT_STATUS_BUFFER_TOO_SMALL: return "buffer_too_small";
        case CRYPT_STATUS_INVALID_MAGIC: return "invalid_magic";
        case CRYPT_STATUS_UNSUPPORTED_CONTAINER: return "unsupported_container";
        case CRYPT_STATUS_UNSUPPORTED_VERSION: return "unsupported_version";
        case CRYPT_STATUS_INVALID_HEADER_SIZE: return "invalid_header_size";
        case CRYPT_STATUS_INVALID_RESERVED: return "invalid_reserved";
        case CRYPT_STATUS_INVALID_FLAGS: return "invalid_flags";
        case CRYPT_STATUS_INVALID_ALGORITHM_ID: return "invalid_algorithm_id";
        case CRYPT_STATUS_INVALID_PREVIEW_TYPE: return "invalid_preview_type";
        case CRYPT_STATUS_INVALID_TLV: return "invalid_tlv";
        case CRYPT_STATUS_TRUNCATED: return "truncated";
        case CRYPT_STATUS_OVERFLOW: return "overflow";
        default: return "unknown";
    }
}

CRYPT_API const char* crypt_core_version(void) {
    return "crypt_core starter v0.1 / format 1.0";
}

crypt_status_t crypt_common_header_init(crypt_common_header_t* header,
                                        uint16_t container_type,
                                        uint16_t header_size,
                                        uint16_t extension_count) {
    if (header == NULL) {
        return CRYPT_STATUS_INVALID_ARGUMENT;
    }
    crypt_zero_struct(header, sizeof(*header));
    memcpy(header->magic, k_crypt_magic, sizeof(k_crypt_magic));
    header->container_type = container_type;
    header->format_major = CRYPT_FORMAT_MAJOR_V1;
    header->format_minor = CRYPT_FORMAT_MINOR_V1_0;
    header->header_size = header_size;
    header->extension_count = extension_count;
    return CRYPT_STATUS_OK;
}

crypt_status_t crypt_common_header_validate(const crypt_common_header_t* header,
                                            uint16_t expected_container_type,
                                            uint16_t min_header_size) {
    if (header == NULL) {
        return CRYPT_STATUS_INVALID_ARGUMENT;
    }
    if (memcmp(header->magic, k_crypt_magic, sizeof(k_crypt_magic)) != 0) {
        return CRYPT_STATUS_INVALID_MAGIC;
    }
    if (header->container_type != expected_container_type) {
        return CRYPT_STATUS_UNSUPPORTED_CONTAINER;
    }
    if (header->format_major != CRYPT_FORMAT_MAJOR_V1 ||
        header->format_minor != CRYPT_FORMAT_MINOR_V1_0) {
        return CRYPT_STATUS_UNSUPPORTED_VERSION;
    }
    if (header->header_size != min_header_size) {
        return CRYPT_STATUS_INVALID_HEADER_SIZE;
    }
    if (header->flags != 0) {
        return CRYPT_STATUS_INVALID_FLAGS;
    }
    if (header->reserved0 != 0) {
        return CRYPT_STATUS_INVALID_RESERVED;
    }
    return CRYPT_STATUS_OK;
}

crypt_status_t crypt_common_header_write(const crypt_common_header_t* header,
                                         uint8_t* out_buffer,
                                         size_t out_buffer_size,
                                         size_t* out_written) {
    if (header == NULL || out_buffer == NULL || out_written == NULL) {
        return CRYPT_STATUS_INVALID_ARGUMENT;
    }
    if (out_buffer_size < CRYPT_COMMON_HEADER_SIZE) {
        return CRYPT_STATUS_BUFFER_TOO_SMALL;
    }
    memcpy(out_buffer, header->magic, CRYPT_MAGIC_SIZE);
    crypt_write_u16_le(out_buffer + 8, header->container_type);
    crypt_write_u16_le(out_buffer + 10, header->format_major);
    crypt_write_u16_le(out_buffer + 12, header->format_minor);
    crypt_write_u16_le(out_buffer + 14, header->header_size);
    crypt_write_u16_le(out_buffer + 16, header->extension_count);
    crypt_write_u32_le(out_buffer + 18, header->flags);
    crypt_write_u32_le(out_buffer + 22, header->reserved0);
    *out_written = CRYPT_COMMON_HEADER_SIZE;
    return CRYPT_STATUS_OK;
}

crypt_status_t crypt_common_header_read(const uint8_t* buffer,
                                        size_t buffer_size,
                                        crypt_common_header_t* out_header,
                                        size_t* out_consumed) {
    if (buffer == NULL || out_header == NULL || out_consumed == NULL) {
        return CRYPT_STATUS_INVALID_ARGUMENT;
    }
    if (buffer_size < CRYPT_COMMON_HEADER_SIZE) {
        return CRYPT_STATUS_TRUNCATED;
    }

    crypt_zero_struct(out_header, sizeof(*out_header));
    memcpy(out_header->magic, buffer, CRYPT_MAGIC_SIZE);
    out_header->container_type = crypt_read_u16_le(buffer + 8);
    out_header->format_major = crypt_read_u16_le(buffer + 10);
    out_header->format_minor = crypt_read_u16_le(buffer + 12);
    out_header->header_size = crypt_read_u16_le(buffer + 14);
    out_header->extension_count = crypt_read_u16_le(buffer + 16);
    out_header->flags = crypt_read_u32_le(buffer + 18);
    out_header->reserved0 = crypt_read_u32_le(buffer + 22);
    *out_consumed = CRYPT_COMMON_HEADER_SIZE;
    return CRYPT_STATUS_OK;
}

crypt_status_t crypt_validate_preview_type(uint16_t preview_type) {
    switch (preview_type) {
        case CRYPT_PREVIEW_NONE:
        case CRYPT_PREVIEW_JPEG:
        case CRYPT_PREVIEW_WEBP:
        case CRYPT_PREVIEW_PNG:
            return CRYPT_STATUS_OK;
        default:
            return CRYPT_STATUS_INVALID_PREVIEW_TYPE;
    }
}

crypt_status_t crypt_validate_required_algorithm(uint16_t algorithm_id) {
    return crypt_validate_algorithm_id(algorithm_id, 0);
}

crypt_status_t crypt_validate_optional_algorithm(uint16_t algorithm_id) {
    return crypt_validate_algorithm_id(algorithm_id, 1);
}
