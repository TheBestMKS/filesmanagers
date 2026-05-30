#ifndef CRYPT_EXPORT_H
#define CRYPT_EXPORT_H

#if defined(_WIN32)
  #if defined(CRYPT_CORE_BUILD)
    #define CRYPT_API __declspec(dllexport)
  #else
    #define CRYPT_API __declspec(dllimport)
  #endif
#else
  #define CRYPT_API __attribute__((visibility("default")))
#endif

#endif

