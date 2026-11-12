/*
 * ZakuroBridge.h — C ABI of libzakuro_ios.a for the 3ds2apple shell.
 *
 * Hand-written mirror of the `zakuro-ios` Rust crate
 * (ios/zakuro-ios/src/lib.rs); keep both in sync when the FFI changes.
 *
 * Swift sees these declarations through SWIFT_OBJC_BRIDGING_HEADER
 * (see ios/app/project.yml), so Swift code calls `zk_*` directly.
 *
 * Threading: a zk_system_t handle is not thread-safe. Every call that takes a
 * handle must run on the same serial queue (docs/integration.md).
 * Null handles are tolerated and turn calls into no-ops.
 *
 * No CPU JIT: iOS forbids executable memory. This is the AOT + interpreter
 * build, so nothing here creates executable pages.
 */

#ifndef ZAKURO_BRIDGE_H
#define ZAKURO_BRIDGE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ------------------------------------------------------------- typedefs -- */

/**
 * Opaque handle to a loaded 3DS system.
 *
 * Created by zk_create(); release with zk_destroy(). NULL is never valid.
 */
typedef void *zk_system_t;

/**
 * Screen selector used by zk_screen_width(), zk_screen_height() and
 * zk_read_screen(). See ZK_SCREEN_TOP / ZK_SCREEN_BOTTOM.
 */
typedef uint32_t zk_screen_t;

/** 3DS HID button bit mask passed to zk_set_input(). See ZK_BUTTON_*. */
typedef uint32_t zk_buttons_t;

/** Result of zk_run_frame(). See ZK_FRAME_*. */
typedef int32_t zk_frame_result_t;

/* ------------------------------------------------------------ constants -- */

/** Screen selectors. */
enum {
    ZK_SCREEN_TOP = 0,    /**< Upper screen: 400 x 240. */
    ZK_SCREEN_BOTTOM = 1  /**< Lower screen: 320 x 240. */
};

/** zk_run_frame() results. */
enum {
    ZK_FRAME_COMPLETED = 0,   /**< Frame advanced normally. */
    ZK_FRAME_EXITED = 1,      /**< Application requested exit. */
    ZK_FRAME_FAULTED = -1,    /**< CPU fault; details go to stderr. */
    ZK_FRAME_BAD_HANDLE = -2  /**< NULL/invalid zk_system_t. */
};

/** 3DS HID button bits (PadState bit layout, see docs/integration.md). */
enum {
    ZK_BUTTON_A = 1 << 0,
    ZK_BUTTON_B = 1 << 1,
    ZK_BUTTON_SELECT = 1 << 2,
    ZK_BUTTON_START = 1 << 3,
    ZK_BUTTON_RIGHT = 1 << 4,
    ZK_BUTTON_LEFT = 1 << 5,
    ZK_BUTTON_UP = 1 << 6,
    ZK_BUTTON_DOWN = 1 << 7,
    ZK_BUTTON_R = 1 << 8,
    ZK_BUTTON_L = 1 << 9,
    ZK_BUTTON_X = 1 << 10,
    ZK_BUTTON_Y = 1 << 11,
    ZK_BUTTON_ZL = 1 << 14,
    ZK_BUTTON_ZR = 1 << 15
};

/* ------------------------------------------------------------ functions -- */

/**
 * Loads a decrypted .3ds/.cci file and returns an opaque handle.
 *
 * @param rom_path  Absolute path to the ROM (UTF-8).
 * @param data_dir  Directory for saves/cache, or NULL for none.
 * @return          System handle, or NULL on failure.
 *
 * May take seconds on a cold cache: call it off the main thread.
 */
zk_system_t zk_create(const char *rom_path, const char *data_dir);

/**
 * Returns the last zk_create() failure message for the current thread, or
 * NULL when there is none.
 *
 * The pointer stays valid until the next zk_create()/zk_last_error() call on
 * the same thread; copy the text before crossing threads or queues.
 */
const char *zk_last_error(void);

/**
 * Runs one frame.
 *
 * @return ZK_FRAME_COMPLETED, ZK_FRAME_EXITED, ZK_FRAME_FAULTED or
 *         ZK_FRAME_BAD_HANDLE.
 */
zk_frame_result_t zk_run_frame(zk_system_t system);

/** Width in pixels of screen `which` (0/top = 400, 1/bottom = 320). */
uint32_t zk_screen_width(zk_screen_t which);

/** Height in pixels of screen `which` (240 for both screens). */
uint32_t zk_screen_height(zk_screen_t which);

/**
 * Copies RGBA8 pixels of screen `which` into `out`.
 *
 * @param out       Destination buffer (RGBA8, row-major, top-left origin).
 * @param capacity  Buffer size in bytes.
 * @return          Full byte length of the screen (may exceed capacity, in
 *                  which case the copy was truncated).
 */
size_t zk_read_screen(zk_system_t system, zk_screen_t which, uint8_t *out,
                      size_t capacity);

/**
 * Copies interleaved stereo i16 PCM into `out`.
 *
 * @param capacity  Buffer capacity in samples (not frames).
 * @return          Frames written (at most capacity / 2).
 */
size_t zk_take_audio(zk_system_t system, int16_t *out, size_t capacity);

/**
 * Pushes the current input state.
 *
 * @param buttons   ZK_BUTTON_* bit mask.
 * @param circle_x  Circle Pad X, -1.0 ... 1.0.
 * @param circle_y  Circle Pad Y, -1.0 ... 1.0.
 * @param touch     0 = not touching, non-zero = touching.
 * @param touch_x   Touch X in bottom-screen pixels.
 * @param touch_y   Touch Y in bottom-screen pixels.
 */
void zk_set_input(zk_system_t system, zk_buttons_t buttons, float circle_x,
                  float circle_y, int32_t touch, uint16_t touch_x,
                  uint16_t touch_y);

/** Releases a handle returned by zk_create(). Safe to call with NULL. */
void zk_destroy(zk_system_t system);

/* ------------------------------------------------ linked (AOT) diagnostics -- */

/**
 * 1 when this build was compiled with the `linked` feature and carries
 * 3dsrecomp-generated code, 0 for the plain interpreter shell.
 */
int32_t zk_linked_code(void);

/** Title ID (16 hex digits as u64) the linked build was compiled for; 0 = none. */
uint64_t zk_linked_program_id(void);

/**
 * 1 when the running System is actually executing the linked code, 0 when it
 * fell back to the interpreter (title ID / ABI / update mismatch).
 */
int32_t zk_recompiled(zk_system_t system);

#ifdef __cplusplus
}
#endif

#endif /* ZAKURO_BRIDGE_H */
