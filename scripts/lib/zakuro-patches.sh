#!/usr/bin/env bash
# zakuro-patches.sh — apply the repository's local Zakuro patches to a checkout.
#
# Sourced by:
#   scripts/build-zakuro-ios.sh
#   scripts/build-linked-ios-lib.sh
#
# The patches in ios/zakuro-ios/patches/ are small, text-only changes to the
# upstream Zakuro checkout (which is gitignored and never committed):
#
#   0001-vulkan-on-ios.patch             MoltenVK lookup on iOS (A0/A1 builds)
#   0002-pipeline-cache-save-every.patch keep the pipeline cache every 5 s
#
# Application is idempotent: a patch already in the tree is reported and
# skipped, so re-running a build script is safe even when the checkout was
# patched by hand (the documented manual step).
#
# Compatibility: system bash 3.2 on macOS. No bash-4 features.
#
# Failure policy: a patch that neither applies nor is already applied is a
# warning, not a build failure (upstream `main` can drift; the build still
# produces a working library, only without that local change). Set
# ZAKURO_STRICT_PATCHES=1 to make it fatal for reproducible release builds.

declare -a ZAKURO_PATCHES_APPLIED=()
declare -a ZAKURO_PATCHES_SKIPPED=()
declare -a ZAKURO_PATCHES_FAILED=()

# Applies every ios/zakuro-ios/patches/*.patch under <zakuro_dir>.
# Prints one line per patch and a summary; sets ZAKURO_PATCHES_* arrays and
# ZAKURO_PATCH_FAILURES. Returns 1 only with ZAKURO_STRICT_PATCHES=1 and a
# failed patch; 0 otherwise (including "no patches/no checkout").
apply_zakuro_patches() {
  local zakuro_dir="$1"
  local root
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  local patch_dir="${root}/ios/zakuro-ios/patches"

  ZAKURO_PATCHES_APPLIED=()
  ZAKURO_PATCHES_SKIPPED=()
  ZAKURO_PATCHES_FAILED=()
  ZAKURO_PATCH_FAILURES=0

  if [[ ! -d "$zakuro_dir/.git" ]]; then
    printf '[patches] no Zakuro checkout at %s, patches not applied\n' "$zakuro_dir"
    return 0
  fi
  if [[ ! -d "$patch_dir" ]]; then
    printf '[patches] no patch directory at %s\n' "$patch_dir"
    return 0
  fi

  local patch name
  for patch in "$patch_dir"/*.patch; do
    [[ -e "$patch" ]] || continue
    name="$(basename "$patch")"
    if git -C "$zakuro_dir" apply --reverse --check "$patch" >/dev/null 2>&1; then
      ZAKURO_PATCHES_SKIPPED+=("$name")
      printf '[patches] already applied: %s\n' "$name"
    elif git -C "$zakuro_dir" apply --check "$patch" >/dev/null 2>&1; then
      if git -C "$zakuro_dir" apply "$patch"; then
        ZAKURO_PATCHES_APPLIED+=("$name")
        printf '[patches] applied: %s\n' "$name"
      else
        ZAKURO_PATCHES_FAILED+=("$name")
        printf '[patches] warning: %s did not apply (git apply failed)\n' "$name" >&2
      fi
    else
      ZAKURO_PATCHES_FAILED+=("$name")
      printf '[patches] warning: %s does not apply to this checkout; upstream main may have moved\n' \
        "$name" >&2
      printf '[patches]   the build continues without that local change; re-pin or update the patch\n' >&2
    fi
  done

  ZAKURO_PATCH_FAILURES=${#ZAKURO_PATCHES_FAILED[@]}
  printf '[patches] %d applied, %d already applied, %d failed\n' \
    "${#ZAKURO_PATCHES_APPLIED[@]}" "${#ZAKURO_PATCHES_SKIPPED[@]}" "$ZAKURO_PATCH_FAILURES"

  if [[ "$ZAKURO_PATCH_FAILURES" -gt 0 && "${ZAKURO_STRICT_PATCHES:-0}" == "1" ]]; then
    printf '[patches] error: %d patch(es) failed and ZAKURO_STRICT_PATCHES=1\n' \
      "$ZAKURO_PATCH_FAILURES" >&2
    return 1
  fi
  return 0
}
