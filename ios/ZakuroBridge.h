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
 * Presentation: zk_presenter_create() takes a UIView whose layer is a
 * CAMetalLayer and makes Zakuro's Vulkan presenter draw into it (on iOS that is
 * MoltenVK over Metal). zk_create_presented() then loads a ROM on the device
 * the renderer shares with the presenter, and zk_present() shows each frame
 * without the zk_read_screen() GPU→CPU copy. The presenter is a main-queue
 * object (UIView); zk_present() belongs on the runtime serial queue. Without a
 * loadable MoltenVK zk_presenter_create() returns NULL and the app keeps the
 * zk_create + zk_read_screen + CGImage path.
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

/**
 * Opaque handle to a presenter drawing into the app's CAMetalLayer.
 *
 * Created by zk_presenter_create(); release with zk_presenter_destroy(). NULL is
 * never valid.
 */
typedef void *zk_presenter_t;

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

/**
 * Releases a handle returned by zk_create(). Safe to call with NULL.
 *
 * Also releases a saved state the handle measured and did not copy yet (see
 * zk_save_state_discard()), so an abandoned save does not outlive the runtime.
 */
void zk_destroy(zk_system_t system);

/* ------------------------------------------------- saved states (instant) -- */

/**
 * The largest one saved state may be, in bytes, in either direction. Mirrors
 * ZK_SAVE_STATE_MAX_BYTES in ios/zakuro-ios/src/savestate.rs; keep both in
 * step. The raw console memories are at most a New3DS's 256 MiB FCRAM plus
 * 6 MiB VRAM and 1 MiB DSP RAM/AXI WRAM, so a bigger length is a bug or a
 * damaged file, and the library refuses it instead of asking for the memory.
 */
#define ZK_SAVE_STATE_MAX_BYTES (512u * 1024u * 1024u)

/** zk_load_state() results. */
enum {
    ZK_LOAD_STATE_LOADED = 0,        /**< The state was applied. */
    ZK_LOAD_STATE_BAD_HANDLE = -1,   /**< NULL system handle. */
    ZK_LOAD_STATE_BAD_ARGUMENT = -2, /**< NULL data with a length, or a length
                                          past ZK_SAVE_STATE_MAX_BYTES. */
    ZK_LOAD_STATE_REFUSED = -3       /**< Not a state this console can take
                                          (another game, another Zakuro
                                          version, another console model, or
                                          damaged/truncated bytes). Nothing was
                                          applied. */
};

/**
 * Bytes a saved state of `system` takes, 0 on failure.
 *
 * Serializes the whole console once (tens of milliseconds up to about a
 * second) and keeps the blob inside the library, so the following
 * zk_save_state_copy() copies that exact snapshot instead of serializing
 * again. Call it between frames on the runtime's serial queue with the frame
 * loop paused: the blob is the console as it was at this call.
 *
 * A success clears the calling thread's last error; a failure returns 0 and
 * writes the reason to zk_last_error() on that thread.
 */
size_t zk_save_state_size(zk_system_t system);

/**
 * Copies the measured saved state into `out`; returns its full length, 0 on
 * failure (reason in zk_last_error()).
 *
 * `out == NULL` (or `capacity == 0`) only reports the length and keeps the
 * blob, like zk_save_state_size(). Otherwise it copies
 * `min(capacity, length)` bytes: a short buffer is logged and the blob stays
 * for a retry with the full length, while a complete copy releases it. When no
 * blob is kept for the handle (no zk_save_state_size() call, or the kept one
 * belongs to another handle) the console is serialized here first, so a copy
 * into an already large enough buffer works on its own.
 *
 * `out` must point to `capacity` writable bytes (the zk_read_screen() contract);
 * a real state is never 0 bytes long.
 */
size_t zk_save_state_copy(zk_system_t system, uint8_t *out, size_t capacity);

/**
 * Releases the state zk_save_state_size()/zk_save_state_copy() kept for
 * `system`, without copying it, when a measured save is abandoned.
 *
 * The kept blob is the size of the state (tens of MiB). A complete copy, a
 * load, a destroy and the next measurement release it too. Safe with NULL.
 */
void zk_save_state_discard(zk_system_t system);

/**
 * Loads a saved state back into `system`: 0 (ZK_LOAD_STATE_LOADED) on success,
 * a negative ZK_LOAD_STATE_* code otherwise, with the reason in
 * zk_last_error() on the calling thread. A success clears that error.
 *
 * The container is checked before Zakuro reads it (magic, truncation, section
 * lengths and the four memory sizes), so a truncated or damaged file is
 * refused without a many-gigabyte allocation request and without touching the
 * running console. Zakuro then checks the format version and title ID and
 * applies nothing unless the whole state was read and accepted.
 *
 * Call it between frames on the runtime's serial queue. After a successful
 * load, drop audio buffered before the load (the DSP state went back too) and
 * let the next frame redraw; the GPU's guest-side state is part of the state.
 */
int32_t zk_load_state(zk_system_t system, const uint8_t *data, size_t length);

/* ------------------------------- presentation on the app's CAMetalLayer -- */

/**
 * Creates a presenter for the app's UIView: Zakuro's Vulkan presenter makes a
 * surface, swapchain and present pipeline over the view's CAMetalLayer, and
 * keeps a Vulkan device the renderer can share. On iOS the Vulkan
 * implementation is MoltenVK over Metal.
 *
 * @param ui_view  Pointer to a UIView whose `layerClass` is CAMetalLayer; pass
 *                 Unmanaged.passUnretained(view).toOpaque() in Swift. The view
 *                 must outlive the presenter and stay on the main thread.
 * @param width    Drawable width in pixels.
 * @param height   Drawable height in pixels.
 * @return         Presenter handle, or NULL when no surface/device can be made
 *                 (usually: no MoltenVK in the app, or a zero size). The reason
 *                 is in zk_last_error() on the calling thread.
 *
 * Call on the main queue before zk_create_presented(). If this returns NULL the
 * app is expected to keep the readback path (zk_create + zk_read_screen).
 */
zk_presenter_t zk_presenter_create(void *ui_view, uint32_t width, uint32_t height);

/**
 * Resizes the swapchain to a new drawable size in pixels.
 *
 * Call on the main queue when the view is laid out again (rotation, split view).
 * The swapchain is rebuilt on the next zk_present(), which returns 1 (out of
 * date) once; following frames present normally. Returns 0, or -1 for a NULL
 * presenter or a zero size.
 */
int32_t zk_presenter_resize(zk_presenter_t presenter, uint32_t width, uint32_t height);

/**
 * Releases a presenter and everything it made. Release the systems loaded with
 * zk_create_presented() first. Safe to call with NULL.
 */
void zk_presenter_destroy(zk_presenter_t presenter);

/**
 * 1 when the presenter has a Vulkan device it can share with the renderer (the
 * screens can go straight to the layer), 0 when it owns a plain device and
 * pixels are uploaded, -1 for a NULL presenter.
 */
int32_t zk_presenter_shared_device(zk_presenter_t presenter);

/**
 * Loads a decrypted ROM with presentation on the app's CAMetalLayer.
 *
 * Same as zk_create(), but the 3D draws on the presenter's Vulkan device and
 * zk_present() shows the screens without zk_read_screen(). The loader falls
 * back to the software renderer (whose pixels the presenter uploads) when the
 * GPU renderer cannot start; the app still never needs zk_read_screen().
 *
 * Returns NULL on failure; the reason is in zk_last_error() on the calling
 * thread. The app should then fall back to zk_create() (the readback path).
 * Call it on the runtime serial queue, after zk_presenter_create().
 */
zk_system_t zk_create_presented(const char *rom_path, const char *data_dir,
                                zk_presenter_t presenter);

/**
 * Presents the frame zk_run_frame() just drew on the CAMetalLayer.
 *
 * Call once per completed frame, on the same serial queue as zk_run_frame(),
 * while the presenter and the system are both alive.
 *
 * @return 0  presented (including a rebuilt swapchain),
 *         1  the swapchain was out of date and rebuilt; continue presenting,
 *        -1  a NULL/unusable handle,
 *        -2  presenting failed (reason in zk_last_error() and the log).
 */
int32_t zk_present(zk_system_t system, zk_presenter_t presenter);

/**
 * How a loaded system puts its screens on the display:
 * 0 = no presenter, the app reads them back (zk_read_screen);
 * 1 = presenter shows the renderer's GPU images directly;
 * 2 = presenter uploads CPU pixels (renderer in software, or no shared device).
 *
 * Pass the presenter given to zk_create_presented(), or NULL for a zk_create
 * system. Returns 0 for a NULL system or NULL presenter.
 */
int32_t zk_present_mode(zk_system_t system, zk_presenter_t presenter);

/**
 * How the two screens are arranged on the presented layer. Pass these numbers to
 * zk_presenter_set_layout() and zk_present_layout_size(); the same number also
 * selects the lower screen in zk_present_touch_map().
 */
enum {
    ZK_LAYOUT_STACKED = 0,      /**< Upper screen above the lower one (console). */
    ZK_LAYOUT_SIDE_BY_SIDE = 1, /**< Upper screen left, lower screen right. */
    ZK_LAYOUT_TOP_ONLY = 2,     /**< Upper screen only. */
    ZK_LAYOUT_BOTTOM_ONLY = 3,  /**< Lower screen only. */
    ZK_LAYOUT_LARGE_TOP = 4     /**< Large upper screen, lower one small at its lower right. */
};

/**
 * Which way the screens are turned inside the presented layer. North is the
 * console's upright orientation; the other values rotate the picture clockwise,
 * so a stacked console held sideways becomes two columns. A rotation is not a
 * property of the device's interface orientation: iOS rotates the app's view
 * with the device already.
 */
enum {
    ZK_ORIENTATION_NORTH = 0,
    ZK_ORIENTATION_EAST = 1,
    ZK_ORIENTATION_SOUTH = 2,
    ZK_ORIENTATION_WEST = 3
};

/**
 * Sets how the screens are arranged on the layer, from the next zk_present() on.
 *
 * The app normally gives the CAMetalLayer the drawable size that
 * zk_present_layout_size() reports for the same layout/orientation, so the
 * screens fill the layer instead of being letterboxed. This is a presenter call
 * like zk_present(): change it on the runtime serial queue while a system is
 * presenting (the next frame uses it), or on the main queue before a load
 * starts. Returns 0, or -1 for a NULL presenter or an unknown layout.
 */
int32_t zk_presenter_set_layout(zk_presenter_t presenter, uint32_t layout);

/**
 * Sets which way the screens are turned on the layer, from the next
 * zk_present() on (see ZK_ORIENTATION_*). Called the same way as
 * zk_presenter_set_layout(). Returns 0, or -1 for a NULL presenter or an
 * unknown orientation.
 */
int32_t zk_presenter_set_orientation(zk_presenter_t presenter, uint32_t orientation);

/**
 * Reports the drawable size, in pixels, that shows a layout without
 * letterboxing: both 3DS screens at their own resolution, arranged and turned as
 * asked. The app sets its CAMetalLayer (and the presenter, through
 * zk_presenter_create / zk_presenter_resize) to this size.
 *
 * Returns 1 and writes both outputs, or 0 for an unknown layout/orientation or a
 * NULL output. What it returns for the common combinations:
 *
 * | layout                         | north   | east/west |
 * |--------------------------------|---------|-----------|
 * | ZK_LAYOUT_STACKED              | 400x480 | 480x400   |
 * | ZK_LAYOUT_SIDE_BY_SIDE         | 720x240 | 240x720   |
 * | ZK_LAYOUT_TOP_ONLY             | 400x240 | 240x400   |
 * | ZK_LAYOUT_BOTTOM_ONLY          | 320x240 | 240x320   |
 */
int32_t zk_present_layout_size(uint32_t layout, uint32_t orientation,
                               uint32_t *out_width, uint32_t *out_height);

/**
 * Maps a touch on the presented layer to lower-screen pixels.
 *
 * @param width       Drawable width in pixels (as passed to zk_presenter_create /
 *                    zk_presenter_resize).
 * @param height      Drawable height in pixels.
 * @param layout      ZK_LAYOUT_* the presenter is configured with.
 * @param orientation ZK_ORIENTATION_* the presenter is configured with.
 * @param x           Touch X normalised to 0.0 ... 1.0 from the view's left edge.
 * @param y           Touch Y normalised to 0.0 ... 1.0 from the view's top edge.
 * @param out_x       Receives the lower-screen X in pixels (0 ... 320).
 * @param out_y       Receives the lower-screen Y in pixels (0 ... 240).
 * @return            1 when the touch is on the lower screen (outputs written),
 *                    0 when it is not (the touch releases) or an argument is
 *                    NULL/unknown.
 *
 * The layout decides where the lower screen is: nowhere for the upper-only
 * layout, and turned back into the screen's own upright pixels when the
 * orientation is not north.
 */
int32_t zk_present_touch_map(uint32_t width, uint32_t height,
                             uint32_t layout, uint32_t orientation,
                             float x, float y,
                             uint16_t *out_x, uint16_t *out_y);

/* --------------------------------------------------- hardware diagnostics -- */

/**
 * Sets the internal resolution the 3D renderer draws at: 1 is the 3DS's own
 * 400x240 (the default) and 4 is 1600x960. Values in between are the same
 * multiple of both screens.
 *
 * The loader builds the renderer while it loads a system, so a new scale takes
 * effect on the next zk_create()/zk_create_presented() call. A system that is
 * already loaded keeps the scale it was created with; there is no run-time
 * renderer rebuild, so destroy it and load again to change the scale. The
 * setting is process-wide and independent of zk_set_hardware_renderer(), but
 * only the host-GPU renderer uses it: the software PICA200 always draws at 1x.
 * The presenter scales the larger screens down to its layer.
 *
 * Call it on the runtime serial queue before a load, or from the main queue
 * while no load is running.
 *
 * @param scale Internal render scale, 1 through 4.
 * @return 0 on success; -1 when scale is outside 1..4 (the setting is left
 *         unchanged and the reason is in zk_last_error() on the calling
 *         thread).
 */
int32_t zk_set_render_scale(uint32_t scale);

/**
 * What a loaded system ended up drawing the 3D on: the host GPU through Vulkan
 * (MoltenVK over Metal on iOS) with the resolution scale, whether the screens
 * go straight to the CAMetalLayer or are read back, a request that fell back to
 * software, or software by choice.
 *
 * The pointer is owned by the library and stays valid until the next status
 * call on the same thread; copy it (String(cString:) in Swift). NULL is not
 * expected, but treat it as "no text". Other build/probe switches
 * (zk_hardware_probe, zk_set_hardware_renderer, zk_set_vulkan_library,
 * zk_set_hardware_option) are declared in ios/zakuro-ios/src/lib.rs and
 * documented in ios/zakuro-ios/README.md; this header only carries what the app
 * calls today.
 */
const char *zk_hardware_status(zk_system_t system);

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
