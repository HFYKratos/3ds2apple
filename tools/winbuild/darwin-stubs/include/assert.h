/*
 * assert.h - minimal C assert for the winbuild cross toolchain.
 * Part of 3ds2apple (Apache-2.0); hand-written from ISO C.
 * __assert_rtn is libSystem's Darwin assert hook (dynamic_lookup import).
 */
#ifndef WINBUILD_DARWIN_STUB_ASSERT_H
#define WINBUILD_DARWIN_STUB_ASSERT_H

#ifdef __cplusplus
extern "C" {
#endif
void __assert_rtn(const char *__func, const char *__file, int __line,
                  const char *__expr) __attribute__((__noreturn__));
#ifdef __cplusplus
}
#endif

#if defined(NDEBUG)
#define assert(expr) ((void)0)
#else
#define assert(expr) \
    ((expr) ? (void)0 : __assert_rtn(__func__, __FILE__, __LINE__, #expr))
#endif

#endif /* WINBUILD_DARWIN_STUB_ASSERT_H */
