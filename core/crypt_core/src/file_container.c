#include "crypt/file_container.h"

#include <string.h>

#include "internal/le_io.h"
#include "internal/memory.h"

crypt_status_t crypt_validate_preview_type(uint16_t preview_type);
crypt_status_t crypt_validate_required_algorithm(uint16_t algorithm_id);

static crypt_status_t crypt_write_tlvs_file(const crypt_tlv_t* tlvs,
                                            size_t tlv_count,
                                            uint8_t* out_buffer,
                                            size_t out_buffer_size,
                                            size_t* offset) {
    for (size_t i = 0; i < tlv_count; ++i) {
        const crypt_tlv_t* tlv = &tlvs[i];
        if (tlv->tag == 0) {
            return CRYPT_STATUS_INVALID_TLV;
        }
        crypt_status_t st = crypt_check_bounds(*offset, 4u + tlv->length, out_buffer_size);
        if (st != CRYPT_STATUS_OK) {
            return st;
        }
        crypt_write_u16_le(out_buffer + *offset, tlv->tag);
        crypt_write_u16_le(out_buffer + *offset + 2, tlv->length);
        *offset += 4;
        if (tlv->length != 0 && tlv->value == NULL) {
            return CRYPT_STATUS_INVALID_ARGUMENT;
        }
        st = crypt_copy_bytes(out_buffer, out_buffer_size, offset, tlv->value, tlv->length);
        if (st != CRYPT_STATUS_OK) {
            return st;
        }
    }
    return CRYPT_STATUS_OK;
}

static crypt_status_t crypt_read_tlvs_file(const uint8_t* buffer,
                                           size_t buffer_size,
                                           uint16_t extension_count,
                                           crypt_tlv_t* parsed_tlvs,
                                           const crypt_tlv_t** out_tlvs,
                                           size_t* out_tlv_count,
                                           size_t* offset) {
    if (extension_count > CRYPT_MAX_TLVS) {
        return CRYPT_STATUS_INVALID_TLV;
    }
    for (uint16_t i = 0; i < extension_count; ++i) {
        crypt_status_t st = crypt_check_bounds(*offset, 4, buffer_size);
        if (st != CRYPT_STATUS_OK) {
            return st;
        }
        const uint16_t tag = crypt_read_u16_le(buffer + *offset);
        const uint16_t len = crypt_read_u16_le(buffer + *offset + 2);
        *offset += 4;
        if (tag == 0) {
            return CRYPT_STATUS_INVALID_TLV;
        }
        st = crypt_check_bounds(*offset, len, buffer_size);
        if (st != CRYPT_STATUS_OK) {
            return st;
        }
        parsed_tlvs[i].tag = tag;
        parsed_tlvs[i].length = len;
        parsed_tlvs[i].value = buffer + *offset;
        *offset += len;
    }
    *out_tlvs = parsed_tlvs;
    *out_tlv_count = extension_count;
    return CRYPT_STATUS_OK;
}

crypt_status_t crypt_file_container_init(crypt_file_container_t* container) {
    if (container == NULL) {
        return CRYPT_STATUS_INVALID_ARGUMENT;
    }
    crypt_zero_struct(container, sizeof(*container));
    container->tlvs = container->parsed_tlvs;
    return crypt_common_header_init(&container->common,
                                    CRYPT_CONTAINER_FILE,
                                    CRYPT_FILE_CONTAINER_FIXED_SIZE,
                                    0);
}

crypt_status_t crypt_file_container_validate(const crypt_file_container_t* container) {
    if (container == NULL) {
        return CRYPT_STATUS_INVALID_ARGUMENT;
    }
    crypt_status_t st = crypt_common_header_validate(&container->common,
                                                     CRYPT_CONTAINER_FILE,
                                                     CRYPT_FILE_CONTAINER_FIXED_SIZE);
    if (st != CRYPT_STATUS_OK) {
        return st;
    }
    st = crypt_validate_required_algorithm(container->header_kdf_id);
    if (st != CRYPT_STATUS_OK) {
        return st;
    }
    st = crypt_validate_required_algorithm(container->header_cipher_id);
    if (st != CRYPT_STATUS_OK) {
        return st;
    }
    st = crypt_validate_required_algorithm(container->payload_cipher_id);
    if (st != CRYPT_STATUS_OK) {
        return st;
    }
    st = crypt_validate_preview_type(container->preview_type);
    if (st != CRYPT_STATUS_OK) {
        return st;
    }
    if (container->tlv_count > CRYPT_MAX_TLVS) {
        return CRYPT_STATUS_INVALID_TLV;
    }
    if (container->tlv_count != container->common.extension_count) {
        return CRYPT_STATUS_INVALID_TLV;
    }
    if (container->encrypted_header_len != 0 && container->encrypted_header == NULL) {
        return CRYPT_STATUS_INVALID_ARGUMENT;
    }
    if (container->encrypted_payload_len != 0 && container->encrypted_payload == NULL) {
        return CRYPT_STATUS_INVALID_ARGUMENT;
    }
    if (container->tlv_count != 0 && container->tlvs == NULL) {
        return CRYPT_STATUS_INVALID_ARGUMENT;
    }
    for (size_t i = 0; i < container->tlv_count; ++i) {
        if (container->tlvs[i].tag == 0) {
            return CRYPT_STATUS_INVALID_TLV;
        }
    }
    return CRYPT_STATUS_OK;
}

crypt_status_t crypt_file_container_write(const crypt_file_container_t* container,
                                          uint8_t* out_buffer,
                                          size_t out_buffer_size,
                                          size_t* out_written) {
    if (container == NULL || out_buffer == NULL || out_written == NULL) {
        return CRYPT_STATUS_INVALID_ARGUMENT;
    }
    crypt_status_t st = crypt_file_container_validate(container);
    if (st != CRYPT_STATUS_OK) {
        return st;
    }
    size_t offset = 0;
    st = crypt_common_header_write(&container->common, out_buffer, out_buffer_size, &offset);
    if (st != CRYPT_STATUS_OK) {
        return st;
    }
    st = crypt_copy_bytes(out_buffer, out_buffer_size, &offset, container->file_id, CRYPT_ID_SIZE);
    if (st != CRYPT_STATUS_OK) {
        return st;
    }
    st = crypt_copy_bytes(out_buffer, out_buffer_size, &offset, container->parent_folder_id, CRYPT_ID_SIZE);
    if (st != CRYPT_STATUS_OK) {
        return st;
    }
    st = crypt_check_bounds(offset, 40, out_buffer_size);
    if (st != CRYPT_STATUS_OK) {
        return st;
    }
    crypt_write_u64_le(out_buffer + offset, container->created_at_utc_ms);
    crypt_write_u64_le(out_buffer + offset + 8, container->updated_at_utc_ms);
    crypt_write_u64_le(out_buffer + offset + 16, container->original_size);
    crypt_write_u64_le(out_buffer + offset + 24, container->stored_size);
    crypt_write_u16_le(out_buffer + offset + 32, container->header_kdf_id);
    crypt_write_u16_le(out_buffer + offset + 34, container->header_cipher_id);
    crypt_write_u16_le(out_buffer + offset + 36, container->payload_cipher_id);
    crypt_write_u16_le(out_buffer + offset + 38, container->preview_type);
    offset += 40;
    st = crypt_check_bounds(offset, 8, out_buffer_size);
    if (st != CRYPT_STATUS_OK) {
        return st;
    }
    crypt_write_u32_le(out_buffer + offset, container->chunk_size);
    crypt_write_u32_le(out_buffer + offset + 4, container->encrypted_header_len);
    offset += 8;
    st = crypt_write_tlvs_file(container->tlvs, container->tlv_count, out_buffer, out_buffer_size, &offset);
    if (st != CRYPT_STATUS_OK) {
        return st;
    }
    st = crypt_copy_bytes(out_buffer, out_buffer_size, &offset, container->encrypted_header, container->encrypted_header_len);
    if (st != CRYPT_STATUS_OK) {
        return st;
    }
    st = crypt_copy_bytes(out_buffer, out_buffer_size, &offset, container->encrypted_payload, container->encrypted_payload_len);
    if (st != CRYPT_STATUS_OK) {
        return st;
    }
    *out_written = offset;
    return CRYPT_STATUS_OK;
}

crypt_status_t crypt_file_container_read(const uint8_t* buffer,
                                         size_t buffer_size,
                                         crypt_file_container_t* out_container,
                                         size_t* out_consumed) {
    if (buffer == NULL || out_container == NULL || out_consumed == NULL) {
        return CRYPT_STATUS_INVALID_ARGUMENT;
    }
    crypt_zero_struct(out_container, sizeof(*out_container));
    out_container->tlvs = out_container->parsed_tlvs;
    size_t offset = 0;
    crypt_status_t st = crypt_common_header_read(buffer, buffer_size, &out_container->common, &offset);
    if (st != CRYPT_STATUS_OK) {
        return st;
    }
    st = crypt_common_header_validate(&out_container->common,
                                      CRYPT_CONTAINER_FILE,
                                      CRYPT_FILE_CONTAINER_FIXED_SIZE);
    if (st != CRYPT_STATUS_OK) {
        return st;
    }
    st = crypt_check_bounds(offset, 80, buffer_size);
    if (st != CRYPT_STATUS_OK) {
        return st;
    }
    memcpy(out_container->file_id, buffer + offset, CRYPT_ID_SIZE);
    memcpy(out_container->parent_folder_id, buffer + offset + 16, CRYPT_ID_SIZE);
    out_container->created_at_utc_ms = crypt_read_u64_le(buffer + offset + 32);
    out_container->updated_at_utc_ms = crypt_read_u64_le(buffer + offset + 40);
    out_container->original_size = crypt_read_u64_le(buffer + offset + 48);
    out_container->stored_size = crypt_read_u64_le(buffer + offset + 56);
    out_container->header_kdf_id = crypt_read_u16_le(buffer + offset + 64);
    out_container->header_cipher_id = crypt_read_u16_le(buffer + offset + 66);
    out_container->payload_cipher_id = crypt_read_u16_le(buffer + offset + 68);
    out_container->preview_type = crypt_read_u16_le(buffer + offset + 70);
    offset += 72;
    out_container->chunk_size = crypt_read_u32_le(buffer + offset);
    out_container->encrypted_header_len = crypt_read_u32_le(buffer + offset + 4);
    offset += 8;
    st = crypt_read_tlvs_file(buffer,
                              buffer_size,
                              out_container->common.extension_count,
                              out_container->parsed_tlvs,
                              &out_container->tlvs,
                              &out_container->tlv_count,
                              &offset);
    if (st != CRYPT_STATUS_OK) {
        return st;
    }
    st = crypt_check_bounds(offset, out_container->encrypted_header_len, buffer_size);
    if (st != CRYPT_STATUS_OK) {
        return st;
    }
    out_container->encrypted_header = buffer + offset;
    offset += out_container->encrypted_header_len;
    out_container->encrypted_payload_len = buffer_size - offset;
    out_container->encrypted_payload = buffer + offset;
    offset = buffer_size;
    *out_consumed = offset;
    return crypt_file_container_validate(out_container);
}
