#ifndef CRYPT_INTERNAL_MEMORY_H
#define CRYPT_INTERNAL_MEMORY_H

#include <stddef.h>
#include <stdint.h>
#include <string.h>

static inline void crypt_zero_struct(void* ptr, size_t size) {
    memset(ptr, 0, size);
}

#endif

