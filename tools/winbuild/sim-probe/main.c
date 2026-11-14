/*
 * main.c - dlopen probe for a cross-built GamePack dylib inside the iOS Simulator.
 *
 * Part of 3ds2apple (Apache-2.0). This is ONLY a reference host built with
 * Xcode on the macOS build VM (the "VM only for reference" allowance): it proves
 * that a GamePack Mach-O produced by the open-source LLVM/LLD path on
 * Linux/Windows dlopen()s in the iOS Simulator and that its GamePack ABI hooks
 * run and forward the recomp tables to a host registration function.
 *
 * It defines zk_register_gamepack itself (the C ABI the real libzakuro_ios_sim.a
 * provides) and asserts:
 *   - dlopen(path) succeeds
 *   - zk_gamepack_title_id() == the title ID the pack was built for
 *   - zk_gamepack_abi_version() == ZK_GAMEPACK_ABI_VERSION (1)
 *   - zk_gamepack_register(1) == 0 and forwards exactly one registration
 *   - the forwarded recomp_abi / generation / entries / modules are non-zero
 *
 * Print lines with result: prefix; write the log to stdout for
 * "xcrun simctl launch --console-pty"; exit 0 only if every check passes.
 */
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef uint64_t (*title_fn_t)(void);
typedef uint32_t (*abi_fn_t)(void);
typedef int32_t (*register_fn_t)(uint32_t);

static int g_failures = 0;
static int g_calls = 0;
static uint64_t g_seen_title = 0;
static uint32_t g_seen_abi = 0;
static uint32_t g_seen_generation = 0;
static uint32_t g_seen_entries = 0;
static uint32_t g_seen_modules = 0;
static const void *g_seen_entries_ptr = 0;
static const void *g_seen_origins_ptr = 0;

#define CHECK(cond, label) do { \
    if (cond) { printf("result: ok   %s\n", label); } \
    else { printf("result: FAIL %s\n", label); g_failures++; } \
} while (0)

/* The host-side registration API the real app/runtime exports. The pack keeps
 * this symbol undefined (-undefined dynamic_lookup), so dyld resolves it here. */
int32_t zk_register_gamepack(uint64_t title_id, uint32_t recomp_abi,
                             uint32_t generation, const void *entries,
                             uint32_t entry_count, const void *modules,
                             uint32_t module_count, const void *origins) {
    g_calls++;
    g_seen_title = title_id;
    g_seen_abi = recomp_abi;
    g_seen_generation = generation;
    g_seen_entries = entry_count;
    g_seen_modules = module_count;
    g_seen_entries_ptr = entries;
    g_seen_origins_ptr = origins;
    (void)modules;
    printf("result: info register title=%016llx recomp_abi=%u generation=%u "
           "entries=%u modules=%u entries_ptr=%p origins_ptr=%p\n",
           (unsigned long long)title_id, recomp_abi, generation, entry_count,
           module_count, entries, origins);
    return 0;
}

int main(void) {
    const char *path = getenv("GAMEPACK_PATH");
    printf("result: info GamePack probe starting\n");
    if (path == NULL || *path == '\0') {
        printf("result: FAIL GAMEPACK_PATH is not set (pass SIMCTL_CHILD_GAMEPACK_PATH)\n");
        return 1;
    }
    printf("result: info dlopen %s\n", path);
    fflush(stdout);

    void *handle = dlopen(path, RTLD_NOW);
    if (handle == NULL) {
        printf("result: FAIL dlopen: %s\n", dlerror());
        return 1;
    }
    printf("result: ok   dlopen\n");

    title_fn_t title = (title_fn_t)dlsym(handle, "zk_gamepack_title_id");
    abi_fn_t abi = (abi_fn_t)dlsym(handle, "zk_gamepack_abi_version");
    register_fn_t reg = (register_fn_t)dlsym(handle, "zk_gamepack_register");
    CHECK(title != NULL, "dlsym zk_gamepack_title_id");
    CHECK(abi != NULL, "dlsym zk_gamepack_abi_version");
    CHECK(reg != NULL, "dlsym zk_gamepack_register");
    if (title == NULL || abi == NULL || reg == NULL) return 1;

    uint64_t title_id = title();
    uint32_t abi_version = abi();
    printf("result: info pack title_id=%016llx pack_abi=%u\n",
           (unsigned long long)title_id, abi_version);
    CHECK(title_id == 0x0004000000055E00ULL, "pack reports the Pokemon Y title ID");
    CHECK(abi_version == 1u, "pack reports GamePack ABI 1");

    int32_t rc = reg(1u);
    printf("result: info zk_gamepack_register(1) = %d\n", rc);
    CHECK(rc == 0, "registration accepted");
    CHECK(g_calls == 1, "host zk_register_gamepack called exactly once");
    CHECK(g_seen_title == title_id, "host saw the pack title ID");
    CHECK(g_seen_abi != 0, "host saw a non-zero recomp ABI");
    CHECK(g_seen_generation != 0, "host saw a non-zero recomp generation");
    CHECK(g_seen_entries > 0, "host saw a non-zero entry count");
    CHECK(g_seen_modules > 0, "host saw a non-zero module count");
    CHECK(g_seen_entries_ptr != 0, "host saw a non-null entries table");
    CHECK(g_seen_origins_ptr != 0, "host saw a non-null origins table");

    int32_t rc2 = reg(2u);
    CHECK(rc2 != 0, "a mismatched host ABI is rejected");

    printf("result: summary failures=%d\n", g_failures);
    fflush(stdout);
    return g_failures == 0 ? 0 : 1;
}
