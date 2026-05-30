#ifndef CRYPT_INTERNAL_LE_IO_H
#define CRYPT_INTERNAL_LE_IO_H

#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include "crypt/status.h"

static inline crypt_status_t crypt_check_bounds(size_t offset, size_t need, size_t size) {
    if (offset > size || need > (size - offset)) {
        return CRYPT_STATUS_TRUNCATED;
    }
    return CRYPT_STATUS_OK;
}

static inline void crypt_write_u16_le(uint8_t* p, uint16_t value) {
    p[0] = (uint8_t)(value & 0xffu);
    p[1] = (uint8_t)((value >> 8) & 0xffu);
}

static inline void crypt_write_u32_le(uint8_t* p, uint32_t value) {
    p[0] = (uint8_t)(value & 0xffu);
    p[1] = (uint8_t)((value >> 8) & 0xffu);
    p[2] = (uint8_t)((value >> 16) & 0xffu);
    p[3] = (uint8_t)((value >> 24) & 0xffu);
}

static inline void crypt_write_u64_le(uint8_t* p, uint64_t value) {
    for (size_t i = 0; i < 8; ++i) {
        p[i] = (uint8_t)((value >> (8u * i)) & 0xffu);
    }
}

static inline uint16_t crypt_read_u16_le(const uint8_t* p) {
    return (uint16_t)p[0] | ((uint16_t)p[1] << 8u);
}

static inline uint32_t crypt_read_u32_le(const uint8_t* p) {
    return (uint32_t)p[0] |
           ((uint32_t)p[1] << 8u) |
           ((uint32_t)p[2] << 16u) |
           ((uint32_t)p[3] << 24u);
}

static inline uint64_t crypt_read_u64_le(const uint8_t* p) {
    uint64_t value = 0;
    for (size_t i = 0; i < 8; ++i) {
        value |= ((uint64_t)p[i]) << (8u * i);
    }
    return value;
}

static inline crypt_status_t crypt_copy_bytes(uint8_t* dst,
                                              size_t dst_size,
                                              size_t* offset,
                                              const uint8_t* src,
                                              size_t len) {
    crypt_status_t st = crypt_check_bounds(*offset, len, dst_size);
    if (st != CRYPT_STATUS_OK) {
        return st;
    }
    if (len != 0) {
        memcpy(dst + *offset, src, len);
    }
    *offset += len;
    return CRYPT_STATUS_OK;
}

#endif

