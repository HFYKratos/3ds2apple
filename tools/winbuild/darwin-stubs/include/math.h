/*
 * math.h - minimal C math declarations for the winbuild cross toolchain.
 *
 * Part of 3ds2apple (Apache-2.0). Hand-written from the ISO C standard (C99 /
 * C11 section 7.12) and the C99 float/long-double variants; NOT copied from
 * Apple's SDK, which must not be redistributed. Functions are undefined and
 * resolve from libSystem at dlopen() time through -undefined dynamic_lookup.
 *
 * 3dsrecomp's generated C includes <math.h> for the VFP sqrt emulation
 * (sqrtf), and other games may call more of the C99 set, so declare the whole
 * set with ABI-correct return types. Many of these lower to ARM64 hardware
 * instructions and never become calls; the rest are dynamic_lookup imports.
 */
#ifndef WINBUILD_DARWIN_STUB_MATH_H
#define WINBUILD_DARWIN_STUB_MATH_H

/* Compiler builtins supply the classification macros and the limits; keep
 * this header usable without any other SDK header. */
#define HUGE_VAL (__builtin_huge_val())
#define HUGE_VALF (__builtin_huge_valf())
#define HUGE_VALL (__builtin_huge_vall())
#define INFINITY (__builtin_inff())
#define NAN (__builtin_nanf(""))
#define M_E 2.7182818284590452354
#define M_LOG2E 1.4426950408889634074
#define M_LOG10E 0.43429448190325182765
#define M_LN2 0.69314718055994530942
#define M_LN10 2.30258509299404568402
#define M_PI 3.14159265358979323846
#define M_PI_2 1.57079632679489661923
#define M_PI_4 0.78539816339744830962
#define M_1_PI 0.31830988618379067154
#define M_2_PI 0.63661977236758134308
#define M_2_SQRTPI 1.12837916709551257390
#define M_SQRT2 1.41421356237309504880
#define M_SQRT1_2 0.70710678118654752440

#define isnan(x) __builtin_isnan(x)
#define isinf(x) __builtin_isinf(x)
#define isfinite(x) __builtin_isfinite(x)
#define isnormal(x) __builtin_isnormal(x)
#define signbit(x) __builtin_signbit(x)
#define isgreater(x, y) __builtin_isgreater((x), (y))
#define isgreaterequal(x, y) __builtin_isgreaterequal((x), (y))
#define isless(x, y) __builtin_isless((x), (y))
#define islessequal(x, y) __builtin_islessequal((x), (y))
#define islessgreater(x, y) __builtin_islessgreater((x), (y))
#define isunordered(x, y) __builtin_isunordered((x), (y))
#define fpclassify(x) __builtin_fpclassify(0, 1, 4, 3, 2, (x))

#define FP_NAN 0
#define FP_INFINITE 1
#define FP_ZERO 2
#define FP_SUBNORMAL 3
#define FP_NORMAL 4

#ifdef __cplusplus
extern "C" {
#endif

/* trigonometric */
double acos(double __x);
float acosf(float __x);
long double acosl(long double __x);
double asin(double __x);
float asinf(float __x);
long double asinl(long double __x);
double atan(double __x);
float atanf(float __x);
long double atanl(long double __x);
double atan2(double __y, double __x);
float atan2f(float __y, float __x);
long double atan2l(long double __y, long double __x);
double cos(double __x);
float cosf(float __x);
long double cosl(long double __x);
double sin(double __x);
float sinf(float __x);
long double sinl(long double __x);
double tan(double __x);
float tanf(float __x);
long double tanl(long double __x);

/* hyperbolic */
double acosh(double __x);
float acoshf(float __x);
long double acoshl(long double __x);
double asinh(double __x);
float asinhf(float __x);
long double asinhl(long double __x);
double atanh(double __x);
float atanhf(float __x);
long double atanhl(long double __x);
double cosh(double __x);
float coshf(float __x);
long double coshl(long double __x);
double sinh(double __x);
float sinhf(float __x);
long double sinhl(long double __x);
double tanh(double __x);
float tanhf(float __x);
long double tanhl(long double __x);

/* exponential and logarithmic */
double exp(double __x);
float expf(float __x);
long double expl(long double __x);
double exp2(double __x);
float exp2f(float __x);
long double exp2l(long double __x);
double expm1(double __x);
float expm1f(float __x);
long double expm1l(long double __x);
double frexp(double __x, int *__exp);
float frexpf(float __x, int *__exp);
long double frexpl(long double __x, int *__exp);
int ilogb(double __x);
int ilogbf(float __x);
int ilogbl(long double __x);
double ldexp(double __x, int __exp);
float ldexpf(float __x, int __exp);
long double ldexpl(long double __x, int __exp);
double log(double __x);
float logf(float __x);
long double logl(long double __x);
double log10(double __x);
float log10f(float __x);
long double log10l(long double __x);
double log1p(double __x);
float log1pf(float __x);
long double log1pl(long double __x);
double log2(double __x);
float log2f(float __x);
long double log2l(long double __x);
double logb(double __x);
float logbf(float __x);
long double logbl(long double __x);
double modf(double __x, double *__iptr);
float modff(float __x, float *__iptr);
long double modfl(long double __x, long double *__iptr);
double scalbn(double __x, int __exp);
float scalbnf(float __x, int __exp);
long double scalbnl(long double __x, int __exp);
double scalbln(double __x, long __exp);
float scalblnf(float __x, long __exp);
long double scalblnl(long double __x, long __exp);

/* power and absolute value */
double cbrt(double __x);
float cbrtf(float __x);
long double cbrtl(long double __x);
double fabs(double __x);
float fabsf(float __x);
long double fabsl(long double __x);
double hypot(double __x, double __y);
float hypotf(float __x, float __y);
long double hypotl(long double __x, long double __y);
double pow(double __x, double __y);
float powf(float __x, float __y);
long double powl(long double __x, long double __y);
double sqrt(double __x);
float sqrtf(float __x);
long double sqrtl(long double __x);

/* error and gamma */
double erf(double __x);
float erff(float __x);
long double erfl(long double __x);
double erfc(double __x);
float erfcf(float __x);
long double erfcl(long double __x);
double lgamma(double __x);
float lgammaf(float __x);
long double lgammal(long double __x);
double tgamma(double __x);
float tgammaf(float __x);
long double tgammal(long double __x);

/* rounding and remainder */
double ceil(double __x);
float ceilf(float __x);
long double ceill(long double __x);
double floor(double __x);
float floorf(float __x);
long double floorl(long double __x);
double nearbyint(double __x);
float nearbyintf(float __x);
long double nearbyintl(long double __x);
double rint(double __x);
float rintf(float __x);
long double rintl(long double __x);
long lrint(double __x);
long lrintf(float __x);
long lrintl(long double __x);
long long llrint(double __x);
long long llrintf(float __x);
long long llrintl(long double __x);
double round(double __x);
float roundf(float __x);
long double roundl(long double __x);
long lround(double __x);
long lroundf(float __x);
long lroundl(long double __x);
long long llround(double __x);
long long llroundf(float __x);
long long llroundl(long double __x);
double trunc(double __x);
float truncf(float __x);
long double truncl(long double __x);
double fmod(double __x, double __y);
float fmodf(float __x, float __y);
long double fmodl(long double __x, long double __y);
double remainder(double __x, double __y);
float remainderf(float __x, float __y);
long double remainderl(long double __x, long double __y);
double remquo(double __x, double __y, int *__quo);
float remquof(float __x, float __y, int *__quo);
long double remquol(long double __x, long double __y, int *__quo);

/* manipulation */
double copysign(double __x, double __y);
float copysignf(float __x, float __y);
long double copysignl(long double __x, long double __y);
double nan(const char *__tagb);
float nanf(const char *__tagb);
long double nanl(const char *__tagb);
double nextafter(double __x, double __y);
float nextafterf(float __x, float __y);
long double nextafterl(long double __x, long double __y);
double nexttoward(double __x, long double __y);
float nexttowardf(float __x, long double __y);
long double nexttowardl(long double __x, long double __y);

/* minimum, maximum, difference, fused multiply-add */
double fdim(double __x, double __y);
float fdimf(float __x, float __y);
long double fdiml(long double __x, long double __y);
double fmax(double __x, double __y);
float fmaxf(float __x, float __y);
long double fmaxl(long double __x, long double __y);
double fmin(double __x, double __y);
float fminf(float __x, float __y);
long double fminl(long double __x, long double __y);
double fma(double __x, double __y, double __z);
float fmaf(float __x, float __y, float __z);
long double fmal(long double __x, long double __y, long double __z);

#ifdef __cplusplus
}
#endif

#endif /* WINBUILD_DARWIN_STUB_MATH_H */
