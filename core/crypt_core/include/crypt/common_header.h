#ifndef CRYPT_COMMON_HEADER_H
#define CRYPT_COMMON_HEADER_H

#include <stddef.h>
#include <stdint.h>

#include "crypt/constants.h"
#include "crypt/export.h"
#include "crypt/status.h"

typedef struct crypt_common_header_s {
    uint8_t magic[CRYPT_MAGIC_SIZE];
    uint16_t container_type;
    uint16_t format_major;
    uint16_t format_minor;
    uint16_t header_size;
    uint16_t extension_count;
    uint32_t flags;
    uint32_t reserved0;
} crypt_common_header_t;

crypt_status_t crypt_common_header_init(crypt_common_header_t* header,
                                        uint16_t container_type,
                                        uint16_t header_size,
                                        uint16_t extension_count);

crypt_status_t crypt_common_header_validate(const crypt_common_header_t* header,
                                            uint16_t expected_container_type,
                                            uint16_t min_header_size);

crypt_status_t crypt_common_header_write(const crypt_common_header_t* header,
                                         uint8_t* out_buffer,
                                         size_t out_buffer_size,
                                         size_t* out_written);

crypt_status_t crypt_common_header_read(const uint8_t* buffer,
                                        size_t buffer_size,
                                        crypt_common_header_t* out_header,
                                        size_t* out_consumed);

CRYPT_API const char* crypt_core_version(void);

#endif
