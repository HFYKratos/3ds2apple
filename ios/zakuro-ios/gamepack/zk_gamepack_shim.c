/*
 * zk_gamepack_shim.c - the C side of a per-game AOT GamePack dylib.
 *
 * Part of 3ds2apple (Apache-2.0). scripts/build-game-pack.sh compiles this file
 * together with one game's 3dsrecomp-generated archive into
 * Frameworks/GamePack-<TITLE_ID>.dylib:
 *
 *     clang -dynamiclib -target arm64-apple-ios16.0 \
 *       zk_gamepack_shim.o libgame.a -Wl,-undefined,dynamic_lookup
 *
 * The shim exports the GamePack ABI (zakuro_gamepack.h) and forwards the
 * registration call to the runtime linked into the host app. The pack contains
 * NO copy of the runtime: zk_register_gamepack is an undefined symbol resolved
 * from the app at dlopen() time (the "-undefined dynamic_lookup" above), so the
 * pack's code and the app's runtime share one process-wide state.
 *
 * Build-time defines (scripts/build-game-pack.sh passes them):
 *   -DZK_GAMEPACK_TITLE_ID=0x0004000000055E00ULL
 *       required: the 3DS title ID the generated code was recompiled for.
 *   -DZK_GAMEPACK_ABI_VERSION=1
 *       optional: defaults to the header's version.
 */
#include <stdint.h>

#include "zakuro_gamepack.h"

#ifndef ZK_GAMEPACK_TITLE_ID
#error "compile zk_gamepack_shim.c with -DZK_GAMEPACK_TITLE_ID=0x<16 hex title id>"
#endif

#ifndef ZK_GAMEPACK_PACK_ABI_VERSION
#define ZK_GAMEPACK_PACK_ABI_VERSION ZK_GAMEPACK_ABI_VERSION
#endif

/* The tables 3dsrecomp's generated C exports (recomp.h, "Exported symbols").
 * Only the addresses and u32 counts are needed here; the runtime interprets
 * their layout (recomp-abi). Declaring them as byte arrays keeps the shim
 * independent of the generated header, so a pack can be linked from an archive
 * alone (scripts/build-game-pack.sh --from-libs). */
extern const uint32_t recomp_abi;
extern const uint32_t recomp_generation;
extern const uint32_t recomp_entry_count;
extern const unsigned char recomp_entries[];
extern const uint32_t recomp_module_count;
extern const unsigned char recomp_modules[];
extern const unsigned char recomp_origins[];

uint64_t zk_gamepack_title_id(void) {
    return (uint64_t)ZK_GAMEPACK_TITLE_ID;
}

uint32_t zk_gamepack_abi_version(void) {
    return (uint32_t)ZK_GAMEPACK_PACK_ABI_VERSION;
}

int32_t zk_gamepack_register(uint32_t host_abi_version) {
    if (host_abi_version != (uint32_t)ZK_GAMEPACK_PACK_ABI_VERSION) {
        return 1;
    }
    if (zk_register_gamepack((uint64_t)ZK_GAMEPACK_TITLE_ID, recomp_abi, recomp_generation,
                             (const void *)recomp_entries, recomp_entry_count,
                             (const void *)recomp_modules, recomp_module_count,
                             (const void *)recomp_origins) != 0) {
        return 2;
    }
    return 0;
}
