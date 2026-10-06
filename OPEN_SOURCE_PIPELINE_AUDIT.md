# Open-Source Pipeline Audit — SpektraFilmFast

Target revision: `8aa1b47a4fd744d69736adfdfc139be8ca9029dd`

This audit is stage-specific. No single open-source photo app is strongest at
every part of the workflow.

## Library / DAM

Primary reference: **darktable lighttable**.

SpektraFilmFast already has Albums, Smart Collections, People grouping, ratings,
flags, labels, XMP, managed ingest and batch edit/export selection. The useful
change is integration rather than duplicating Cull: Library remains the source
of truth for organization, filter, selection and batch operations, including a
new Export Queue filter.

## Cull

Primary workflow reference: **darktable culling / preview modes**.

Cull is now a decision workspace:
- Loupe;
- synchronized Compare;
- Survey;
- navigation across either the visible Library result or highlighted Library set;
- fast Pick / Reject / rating / color label;
- Smart Cull score, face/focus/exposure/blink detail;
- resizable no-crop filmstrip.

It does not become a second Library.

## Export

UX reference: **RapidRAW**.
Workflow reference: **darktable export**.

The page now separates:
1. export-set construction;
2. delivery/color intent;
3. destination;
4. file naming + preflight;
5. format/quality;
6. dimensions;
7. metadata/privacy;
8. queue/recovery.

## RAW / white balance

Primary implementation: **Apple CIRAWFilter**.

Settled RAW As-Shot/Auto relative offsets now remain in camera-space RAW
development whenever a reliable camera-space path exists. The working-space
Rec.2020 matrix remains a live-drag proxy and non-RAW/Auto-fallback mechanism.

WB-to-Skin probes the exact committed RAW path so it cannot choose a correction
from the approximate drag proxy and then settle to a different green/magenta cast.

Printer lights / print filtration remain creative printing controls; they do not
replace capture white balance.

## Skin diagnostics

References: **Primera Skin + Apple Vision isolation**.

The false-color overlay, skin percentages, centroid and skin vectorscope now
derive from the same refined final-output skin mask. A mixed-light state is
reported when meaningful green-side and magenta-side skin regions cancel in the
mean centroid.

## Film / print simulation

Source of truth: **current Spektrafilm**.

Current upstream Spektrafilm exposes named internal taps such as:
- `log_e_film`
- `cmy_film`
- `log_e_print`
- `cmy_print`
- `rgb_out`

Its LUT creator supports multiple topologies. That confirms the fast path should
be split around physical spatial stages rather than replaced by one end-to-end
LUT.

Spatial stages remain real:
- halation / light scattering;
- density-dependent grain;
- diffusion / bloom;
- scanner blur / unsharp;
- spatial DIR behavior.

## Color delivery

For web/phone/social delivery, the new `sRGB · Web / Phone` mode changes the
renderer output transform to actual sRGB before encoding. It does not merely
retag Rec.709 Gamma 2.4 pixels with an sRGB ICC profile.

`Match Renderer` remains available for controlled master workflows.

## Export performance

The new bounded conveyor is:

`decode N+1  ||  exact GPU render N  ||  encode/write N-1`

Decode-ahead is admitted from `os_proc_available_memory()` and an estimated byte
cost instead of the old 45 MP pair ceiling.

Float32 RGBA -> UInt8 / UInt16 conversion is vectorized with Accelerate/vDSP in
bounded chunks. The TIFF16 writer no longer re-decodes every just-written
full-resolution file merely to re-check bit depth.

The existing per-stage CSV timing log remains the measurement source.

## LUT fast path

The exact renderer remains the correctness and export reference.

The included `scripts/lut_feasibility.py` is the required stop gate before
enabling a LUT renderer:
- generate 33^3 / 65^3 identity cubes;
- verify R-fastest `.cube` ordering;
- compare exact vs candidate float outputs;
- report per-channel errors, RMSE and DeltaE2000;
- gate on measured fidelity.

No unmeasured LUT approximation is silently enabled.

## Architecture

The shipping architecture remains **Intel x86_64 only**.
No arm64 / Universal changes are made.
