/*
 * string.h - minimal C string declarations for the winbuild cross toolchain.
 *
 * Part of 3ds2apple (Apache-2.0). Hand-written from the ISO C standard; it is
 * NOT copied from Apple's SDK (which must not be redistributed). The compiler
 * cross-compiles 3dsrecomp-generated C for arm64-apple-ios with -nostdinc and
 * this directory as the only system include path. Every function below is
 * declared but not defined: the GamePack dylib links with
 * -undefined dynamic_lookup, so these calls resolve from libSystem when the
 * pack is dlopen()ed inside the app.
 *
 * Keep declarations ABI-correct (return types and parameters matter: a wrong
 * implicit declaration silently corrupts 64-bit pointers).
 */
#ifndef WINBUILD_DARWIN_STUB_STRING_H
#define WINBUILD_DARWIN_STUB_STRING_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

void *memcpy(void *__dst, const void *__src, size_t __n);
void *memmove(void *__dst, const void *__src, size_t __n);
void *memset(void *__dst, int __c, size_t __n);
int memcmp(const void *__a, const void *__b, size_t __n);
void *memchr(const void *__s, int __c, size_t __n);
void *memrchr(const void *__s, int __c, size_t __n);

size_t strlen(const char *__s);
size_t strnlen(const char *__s, size_t __max);
int strcmp(const char *__a, const char *__b);
int strncmp(const char *__a, const char *__b, size_t __n);
char *strcpy(char *__dst, const char *__src);
char *strncpy(char *__dst, const char *__src, size_t __n);
char *strcat(char *__dst, const char *__src);
char *strncat(char *__dst, const char *__src, size_t __n);
char *strchr(const char *__s, int __c);
char *strrchr(const char *__s, int __c);
char *strstr(const char *__haystack, const char *__needle);
char *strdup(const char *__s);
char *strndup(const char *__s, size_t __n);
char *strtok(char *__s, const char *__delim);
char *strtok_r(char *__s, const char *__delim, char **__save);
char *strerror(int __errnum);
char *strsep(char **__stringp, const char *__delim);

#ifdef __cplusplus
}
#endif

#endif /* WINBUILD_DARWIN_STUB_STRING_H */
