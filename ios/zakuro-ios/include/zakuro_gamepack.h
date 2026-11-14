/*
 * zakuro_gamepack.h - per-game AOT GamePack C ABI, version 1.
 *
 * Part of 3ds2apple (Apache-2.0). The AOT-first desktop pipeline builds one
 * dylib per game ("GamePack-<TITLE_ID>.dylib") that carries the game's
 * 3dsrecomp-generated AOT code. The shipping shell dlopen()s it from the app
 * bundle and calls the pack's registration hook; the pack hands the generated
 * tables to the Zakuro runtime through the host API below.
 *
 * Pack side (exported by the pack; found with dlsym by ios/app/Sources/AOTPackageLoader.swift)
 * ---------------------------------------------------------------------------------------------
 *   uint64_t zk_gamepack_title_id(void);
 *       The 16-hex-digit 3DS title ID the pack was built for. The shell compares
 *       it with the catalog entry and refuses a pack built for another game.
 *
 *   uint32_t zk_gamepack_abi_version(void);
 *       The GamePack ABI version the pack implements; must equal
 *       ZK_GAMEPACK_ABI_VERSION (the shell's host ABI is 1).
 *
 *   int32_t zk_gamepack_register(uint32_t host_abi_version);
 *       Registration hook, called once on the main thread right after dlopen.
 *       0 = the pack accepted the host and registered its code; non-zero = the
 *       pack refused this host (the shell unloads the pack and reports the game
 *       as unavailable). The shim shipped in ios/zakuro-ios/gamepack/ calls
 *       zk_register_gamepack() below and returns 0 / 2.
 *
 * Host side (exported by libzakuro_ios.a / libzakuro_ios_sim.a, implemented in
 * ios/zakuro-ios/src/gamepack.rs)
 * ---------------------------------------------------------------------------------------------
 *   int32_t zk_register_gamepack(uint64_t title_id, uint32_t recomp_abi,
 *                                uint32_t generation,
 *                                const void *entries, uint32_t entry_count,
 *                                const void *modules, uint32_t module_count,
 *                                const void *origins);
 *       Registers the pack's generated tables so the next zk_create() runs them
 *       as AOT code. Returns 0 on success, -1 for invalid arguments, -2 when
 *       the tables' recomp interface version is not one this runtime accepts.
 *       The pointers must stay valid for the whole process: they are constants
 *       inside the loaded pack, which the shell never unloads.
 *
 *   int32_t zk_unregister_gamepack(void);       forget the registered pack (0)
 *   int32_t zk_gamepack_registered(void);      1 when a pack is registered
 *   uint64_t zk_registered_gamepack_title_id(void);  the registered pack's title (0 = none)
 *
 * The table layout and interface version are declared by the 3dsrecomp
 * generated recomp.h ("Exported symbols"): recomp_abi, recomp_generation,
 * recomp_entry_count, recomp_entries, recomp_module_count, recomp_modules and
 * recomp_origins. A pack links one game's generated archive and no copy of the
 * runtime; the host symbols are resolved from the app at dlopen time.
 */
#ifndef ZAKURO_GAMEPACK_H
#define ZAKURO_GAMEPACK_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* The GamePack contract version this header describes: the pack's exports, the
 * registration signature and the host API. Bump together with
 * AOTPackageLoader.hostABIVersion and the desktop pack pipeline. */
#define ZK_GAMEPACK_ABI_VERSION 1u

/* --- pack side ---------------------------------------------------------- */

uint64_t zk_gamepack_title_id(void);
uint32_t zk_gamepack_abi_version(void);
int32_t zk_gamepack_register(uint32_t host_abi_version);

/* --- host side ---------------------------------------------------------- */

int32_t zk_register_gamepack(uint64_t title_id,
                             uint32_t recomp_abi,
                             uint32_t generation,
                             const void *entries,
                             uint32_t entry_count,
                             const void *modules,
                             uint32_t module_count,
                             const void *origins);
int32_t zk_unregister_gamepack(void);
int32_t zk_gamepack_registered(void);
uint64_t zk_registered_gamepack_title_id(void);

#ifdef __cplusplus
}
#endif

#endif /* ZAKURO_GAMEPACK_H */
