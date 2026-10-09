# Notices and upstream components

SpektraFilmFast is a macOS application host around the Spektrafilm native core and is intentionally transparent about outside references.

## Spektrafilm native core

- Upstream: https://github.com/chaert-s/spektrafilm-ofx
- Pinned revision: `8f6651858f439a99b7202b4b8dea59e344dadf5d`
- Upstream license: GNU GPL v3.0 (`Native/LICENSE.txt`)

The native core's source files are **vendored in-tree** under `Native/`, based on the
pinned revision. It is GPLv3 and this project is GPLv3, so this is license-compatible, and
the full upstream terms and copyright notices are preserved. Vendoring makes a fresh clone
build with no network access, no external repository and no Python; see `Native/NOTICE.md`.

The bundled renderer resources (`SpektraFilm.metallib`, spectral data, gamut-compression data) are retained for renderer parity. Preserve applicable upstream copyright/license notices.

## Referenced open-source projects

Behavior, algorithms, workflow patterns, or factual preset data were studied from RapidRAW, Alcedo Studio, darktable, RawTherapee, Primera Suite, DeoTime/vectorscope, filmr, and OpenPost. Exact repositories, revisions where recorded, funding links, and the parts studied are documented in `IMPLEMENTATION_SOURCES.md`.

RapidRAW and OpenPost are AGPL-3.0 projects; Alcedo/darktable/Spektrafilm are GPL-family projects; Primera Suite is MIT. Do not copy new upstream source into this project without re-checking compatibility and preserving the upstream terms. Apart from the GPLv3 Spektrafilm native core vendored under `Native/`, existing host implementations are written in Swift and the package does not vendor those other projects' source trees.

## Vibe-coded disclosure

The project was developed interactively with AI assistance under human product direction/testing. This is disclosed in the README rather than hidden. Contributors should keep implementation provenance and third-party attribution visible.

## Project support

`.github/FUNDING.yml` identifies the project support account as `buy_me_a_coffee: /kbvisualz`:
https://www.buymeacoffee.com/kbvisualz

## Code signing

Local builds are ad-hoc signed by default. Public distribution requires Developer ID Application hardened-runtime signing, Apple notarization, stapling, and Gatekeeper verification. Credentials are local-only and must never be committed.

## Redlamp masking source and models

Selected masking, matting, inference and math files are adapted from pdcgomes/redlamp at `0ed3a59211e4128111f2c8ba11bc5d249b0cb8dd`, under MPL-2.0. Their upstream copyright headers and source availability are preserved. See `Resources/Redlamp-MPL-2.0.txt` and IMPLEMENTATION_SOURCES.md. The model catalog in Resources/MaskModels records separate model licenses and exact weights; SAM 3's Meta SAM License and snow-prompt notice ship in Resources/SAM3. Apple Vision is a platform dependency.

Local native host adaptation: choose the discrete Metal device when available. Spectral shader equations and generated curves are unchanged.
