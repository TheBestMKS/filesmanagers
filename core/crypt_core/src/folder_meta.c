#include "crypt/folder_meta.h"

#include <string.h>

#include "internal/le_io.h"
#include "internal/memory.h"

crypt_status_t crypt_validate_preview_type(uint16_t preview_type);
crypt_status_t crypt_validate_required_algorithm(uint16_t algorithm_id);

static crypt_status_t crypt_write_tlvs(const crypt_tlv_t* tlvs,
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

static crypt_status_t crypt_read_tlvs(const uint8_t* buffer,
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

crypt_status_t crypt_folder_meta_init(crypt_folder_meta_t* meta) {
    if (meta == NULL) {
        return CRYPT_STATUS_INVALID_ARGUMENT;
    }
    crypt_zero_struct(meta, sizeof(*meta));
    meta->tlvs = meta->parsed_tlvs;
    return crypt_common_header_init(&meta->common,
                                    CRYPT_CONTAINER_FOLDER_META,
                                    CRYPT_FOLDER_META_FIXED_SIZE,
                                    0);
}

crypt_status_t crypt_folder_meta_validate(const crypt_folder_meta_t* meta) {
    if (meta == NULL) {
        return CRYPT_STATUS_INVALID_ARGUMENT;
    }
    crypt_status_t st = crypt_common_header_validate(&meta->common,
                                                     CRYPT_CONTAINER_FOLDER_META,
                                                     CRYPT_FOLDER_META_FIXED_SIZE);
    if (st != CRYPT_STATUS_OK) {
        return st;
    }
    st = crypt_validate_required_algorithm(meta->name_kdf_id);
    if (st != CRYPT_STATUS_OK) {
        return st;
    }
    st = crypt_validate_required_algorithm(meta->name_cipher_id);
    if (st != CRYPT_STATUS_OK) {
        return st;
    }
    st = crypt_validate_preview_type(meta->preview_type);
    if (st != CRYPT_STATUS_OK) {
        return st;
    }
    if (meta->reserved1 != 0) {
        return CRYPT_STATUS_INVALID_RESERVED;
    }
    if (meta->tlv_count > CRYPT_MAX_TLVS) {
        return CRYPT_STATUS_INVALID_TLV;
    }
    if (meta->tlv_count != meta->common.extension_count) {
        return CRYPT_STATUS_INVALID_TLV;
    }
    if (meta->encrypted_name_len != 0 && meta->encrypted_name == NULL) {
        return CRYPT_STATUS_INVALID_ARGUMENT;
    }
    if (meta->encrypted_preview_len != 0 && meta->encrypted_preview == NULL) {
        return CRYPT_STATUS_INVALID_ARGUMENT;
    }
    if (meta->tlv_count != 0 && meta->tlvs == NULL) {
        return CRYPT_STATUS_INVALID_ARGUMENT;
    }
    for (size_t i = 0; i < meta->tlv_count; ++i) {
        if (meta->tlvs[i].tag == 0) {
            return CRYPT_STATUS_INVALID_TLV;
        }
    }
    return CRYPT_STATUS_OK;
}

crypt_status_t crypt_folder_meta_write(const crypt_folder_meta_t* meta,
                                       uint8_t* out_buffer,
                                       size_t out_buffer_size,
                                       size_t* out_written) {
    if (meta == NULL || out_buffer == NULL || out_written == NULL) {
        return CRYPT_STATUS_INVALID_ARGUMENT;
    }

    crypt_status_t st = crypt_folder_meta_validate(meta);
    if (st != CRYPT_STATUS_OK) {
        return st;
    }

    size_t offset = 0;
    st = crypt_common_header_write(&meta->common, out_buffer, out_buffer_size, &offset);
    if (st != CRYPT_STATUS_OK) {
        return st;
    }
    st = crypt_copy_bytes(out_buffer, out_buffer_size, &offset, meta->folder_id, CRYPT_ID_SIZE);
    if (st != CRYPT_STATUS_OK) {
        return st;
    }
    st = crypt_copy_bytes(out_buffer, out_buffer_size, &offset, meta->parent_folder_id, CRYPT_ID_SIZE);
    if (st != CRYPT_STATUS_OK) {
        return st;
    }
    st = crypt_check_bounds(offset, 24, out_buffer_size);
    if (st != CRYPT_STATUS_OK) {
        return st;
    }
    crypt_write_u64_le(out_buffer + offset, meta->created_at_utc_ms);
    crypt_write_u64_le(out_buffer + offset + 8, meta->updated_at_utc_ms);
    crypt_write_u16_le(out_buffer + offset + 16, meta->name_kdf_id);
    crypt_write_u16_le(out_buffer + offset + 18, meta->name_cipher_id);
    crypt_write_u16_le(out_buffer + offset + 20, meta->preview_type);
    crypt_write_u16_le(out_buffer + offset + 22, meta->reserved1);
    offset += 24;
    st = crypt_check_bounds(offset, 8, out_buffer_size);
    if (st != CRYPT_STATUS_OK) {
        return st;
    }
    crypt_write_u32_le(out_buffer + offset, meta->encrypted_name_len);
    crypt_write_u32_le(out_buffer + offset + 4, meta->encrypted_preview_len);
    offset += 8;
    st = crypt_write_tlvs(meta->tlvs, meta->tlv_count, out_buffer, out_buffer_size, &offset);
    if (st != CRYPT_STATUS_OK) {
        return st;
    }
    st = crypt_copy_bytes(out_buffer, out_buffer_size, &offset, meta->encrypted_name, meta->encrypted_name_len);
    if (st != CRYPT_STATUS_OK) {
        return st;
    }
    st = crypt_copy_bytes(out_buffer, out_buffer_size, &offset, meta->encrypted_preview, meta->encrypted_preview_len);
    if (st != CRYPT_STATUS_OK) {
        return st;
    }
    *out_written = offset;
    return CRYPT_STATUS_OK;
}

crypt_status_t crypt_folder_meta_read(const uint8_t* buffer,
                                      size_t buffer_size,
                                      crypt_folder_meta_t* out_meta,
                                      size_t* out_consumed) {
    if (buffer == NULL || out_meta == NULL || out_consumed == NULL) {
        return CRYPT_STATUS_INVALID_ARGUMENT;
    }

    crypt_zero_struct(out_meta, sizeof(*out_meta));
    out_meta->tlvs = out_meta->parsed_tlvs;
    size_t offset = 0;
    crypt_status_t st = crypt_common_header_read(buffer, buffer_size, &out_meta->common, &offset);
    if (st != CRYPT_STATUS_OK) {
        return st;
    }
    st = crypt_common_header_validate(&out_meta->common,
                                      CRYPT_CONTAINER_FOLDER_META,
                                      CRYPT_FOLDER_META_FIXED_SIZE);
    if (st != CRYPT_STATUS_OK) {
        return st;
    }
    st = crypt_check_bounds(offset, 56, buffer_size);
    if (st != CRYPT_STATUS_OK) {
        return st;
    }
    memcpy(out_meta->folder_id, buffer + offset, CRYPT_ID_SIZE);
    memcpy(out_meta->parent_folder_id, buffer + offset + 16, CRYPT_ID_SIZE);
    out_meta->created_at_utc_ms = crypt_read_u64_le(buffer + offset + 32);
    out_meta->updated_at_utc_ms = crypt_read_u64_le(buffer + offset + 40);
    out_meta->name_kdf_id = crypt_read_u16_le(buffer + offset + 48);
    out_meta->name_cipher_id = crypt_read_u16_le(buffer + offset + 50);
    out_meta->preview_type = crypt_read_u16_le(buffer + offset + 52);
    out_meta->reserved1 = crypt_read_u16_le(buffer + offset + 54);
    offset += 56;
    out_meta->encrypted_name_len = crypt_read_u32_le(buffer + offset);
    out_meta->encrypted_preview_len = crypt_read_u32_le(buffer + offset + 4);
    offset += 8;
    st = crypt_read_tlvs(buffer,
                         buffer_size,
                         out_meta->common.extension_count,
                         out_meta->parsed_tlvs,
                         &out_meta->tlvs,
                         &out_meta->tlv_count,
                         &offset);
    if (st != CRYPT_STATUS_OK) {
        return st;
    }
    st = crypt_check_bounds(offset, out_meta->encrypted_name_len, buffer_size);
    if (st != CRYPT_STATUS_OK) {
        return st;
    }
    out_meta->encrypted_name = buffer + offset;
    offset += out_meta->encrypted_name_len;
    st = crypt_check_bounds(offset, out_meta->encrypted_preview_len, buffer_size);
    if (st != CRYPT_STATUS_OK) {
        return st;
    }
    out_meta->encrypted_preview = buffer + offset;
    offset += out_meta->encrypted_preview_len;
    *out_consumed = offset;
    return crypt_folder_meta_validate(out_meta);
}
