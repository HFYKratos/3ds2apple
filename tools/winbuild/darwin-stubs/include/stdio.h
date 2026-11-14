/*
 * stdio.h - minimal C stdio declarations for the winbuild cross toolchain.
 * Part of 3ds2apple (Apache-2.0); hand-written from ISO C, not copied from
 * Apple's SDK. FILE stays opaque: the GamePack ABI never passes it across a
 * dylib boundary except to libSystem's own functions, which are
 * dynamic_lookup imports, so the struct layout is irrelevant here.
 */
#ifndef WINBUILD_DARWIN_STUB_STDIO_H
#define WINBUILD_DARWIN_STUB_STDIO_H

#include <stddef.h>
#include <stdarg.h>

typedef struct __sFILE FILE;
extern FILE *stdin;
extern FILE *stdout;
extern FILE *stderr;

#define EOF (-1)
#define SEEK_SET 0
#define SEEK_CUR 1
#define SEEK_END 2

int printf(const char *__format, ...);
int fprintf(FILE *__stream, const char *__format, ...);
int sprintf(char *__str, const char *__format, ...);
int snprintf(char *__str, size_t __size, const char *__format, ...);
int vprintf(const char *__format, va_list __ap);
int vfprintf(FILE *__stream, const char *__format, va_list __ap);
int vsprintf(char *__str, const char *__format, va_list __ap);
int vsnprintf(char *__str, size_t __size, const char *__format, va_list __ap);
int puts(const char *__s);
int fputs(const char *__s, FILE *__stream);
int putchar(int __c);
int fputc(int __c, FILE *__stream);
int fflush(FILE *__stream);
FILE *fopen(const char *__path, const char *__mode);
FILE *freopen(const char *__path, const char *__mode, FILE *__stream);
int fclose(FILE *__stream);
size_t fread(void *__ptr, size_t __size, size_t __nmemb, FILE *__stream);
size_t fwrite(const void *__ptr, size_t __size, size_t __nmemb, FILE *__stream);
int fseek(FILE *__stream, long __offset, int __whence);
long ftell(FILE *__stream);
void rewind(FILE *__stream);
int fgetc(FILE *__stream);
char *fgets(char *__s, int __size, FILE *__stream);
int fputc_dummy_unused(int __c, FILE *__stream);

#ifdef __cplusplus
}
#endif

#endif /* WINBUILD_DARWIN_STUB_STDIO_H */
