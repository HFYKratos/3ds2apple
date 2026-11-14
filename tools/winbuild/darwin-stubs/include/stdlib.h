/*
 * stdlib.h - minimal C stdlib declarations for the winbuild cross toolchain.
 * Part of 3ds2apple (Apache-2.0); hand-written from ISO C, not copied from
 * Apple's SDK. All functions are dynamic_lookup imports resolved from
 * libSystem when the GamePack dylib is dlopen()ed.
 */
#ifndef WINBUILD_DARWIN_STUB_STDLIB_H
#define WINBUILD_DARWIN_STUB_STDLIB_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#define EXIT_SUCCESS 0
#define EXIT_FAILURE 1

typedef struct { int quot; int rem; } div_t;
typedef struct { long quot; long rem; } ldiv_t;
typedef struct { long long quot; long long rem; } lldiv_t;

void *malloc(size_t __size);
void *calloc(size_t __count, size_t __size);
void *realloc(void *__ptr, size_t __size);
void free(void *__ptr);
void abort(void) __attribute__((__noreturn__));
void exit(int __status) __attribute__((__noreturn__));
char *getenv(const char *__name);
int atoi(const char *__s);
long atol(const char *__s);
long long atoll(const char *__s);
double atof(const char *__s);
long strtol(const char *__s, char **__end, int __base);
unsigned long strtoul(const char *__s, char **__end, int __base);
long long strtoll(const char *__s, char **__end, int __base);
unsigned long long strtoull(const char *__s, char **__end, int __base);
double strtod(const char *__s, char **__end);
float strtof(const char *__s, char **__end);
long double strtold(const char *__s, char **__end);
int abs(int __x);
long labs(long __x);
long long llabs(long long __x);
div_t div(int __x, int __y);
ldiv_t ldiv(long __x, long __y);
lldiv_t lldiv(long long __x, long long __y);
void qsort(void *__base, size_t __nmemb, size_t __size,
           int (*__compar)(const void *, const void *));
void *bsearch(const void *__key, const void *__base, size_t __nmemb,
              size_t __size, int (*__compar)(const void *, const void *));
int rand(void);
void srand(unsigned int __seed);

#ifdef __cplusplus
}
#endif

#endif /* WINBUILD_DARWIN_STUB_STDLIB_H */
