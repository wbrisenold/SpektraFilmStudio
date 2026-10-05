# Vendored native core

`Native/` contains the third-party native core that `SpektraFilmFast` statically
links into its app executable.

## Provenance

- upstream: <https://github.com/chaert-s/spektrafilm-ofx.git>
- upstream commit: `8f6651858f439a99b7202b4b8dea59e344dadf5d`
- license: GNU GPL v3 (`Native/LICENSE.txt`)

These files are vendored **unmodified**, copied byte-for-byte from that commit.
This project is GPLv3 (see the root `LICENSE`), and the native core is GPLv3, so
vendoring it is license-compatible.

## Why it is vendored

The build previously fetched this repository at build time. That made every build
depend on a third party's GitHub account staying up, so a vanished or moved
upstream repository silently broke the build for everyone. Vendoring makes a fresh
clone self-contained: no network, no external repository, no Git.

## What is vendored, and why

`Native/src/` — the two translation units the app actually compiles, plus the
headers they include:

| File | Role |
| --- | --- |
| `SpektraAppBridge.mm` | Objective-C++ bridge called from Swift |
| `SpektraMetalRenderer.mm` | Metal renderer implementation |
| `SpektraAppBridge.h`, `SpektraMetalRenderer.h`, `SpektraProfileCurves.h`, `SpektraParameters.h`, `SpektraRenderer.h` | headers included by the above |

Deliberately **not** vendored, because the app build does not compile them:

- `SpektraFilmPlugin.cpp`, `SpektraVulkanRenderer.cpp/.h` — plugin and Vulkan
  backends, unused by this app
- `SpektraTooltips.h` — not referenced by any vendored translation unit
- `tools/` and `Resources/data/` (~21 MB) — the profile-curve generator and its
  input data, no longer needed (see below)

## Generated profile curves

`Native/generated/SpektraGeneratedProfileCurves.cpp` and
`Native/generated/SpektraGeneratedProfileCounts.h` are **generated** output,
committed so the build needs no Python and no numeric libraries.

They were produced by the upstream `tools/generate_profile_curves.py` from
`Resources/data` at the upstream commit above, using exactly:

- numpy 2.5.3
- scipy 1.18.1
- colour-science 0.4.7
- matplotlib 3.11.2

The committed `.f32` runtime data in `Resources/` (`SpektraHanatos2025Spectra.f32`,
`SpektraOutputGamutCompression.f32`) hashes identically to what that same generator
run emitted, so the committed generated code and the committed data agree.

### Regenerating the curves

Requires the upstream repository plus the four pinned packages above. Commit the
regenerated `Native/generated/*` files together with the regenerated
`Resources/*.f32`, and re-run `./scripts/verify_source.sh` and
`./BUILD_ON_MAC.command`.

## Updating to a newer upstream commit

1. Clone upstream, check out the new commit.
2. Copy the seven files in the table above into `Native/src/`.
3. Recreate the two files in `Native/generated/` (previous section).
4. Update the upstream commit recorded at the top of this file, and the STAMP
   constant in `scripts/bootstrap_native.sh` if you use one.
5. Re-run the full source gate and a clean-clone build.