# Stage 3 — AI / Canonical Semantic Masks

Implemented:
- MODNet subject/background matte;
- SCHP LIP-20 person, clothing, arms, legs, shoes and hair masks;
- CelebAMask-HQ BiSeNet facial skin, hair, eyes, lips and neck/body-skin masks;
- one cached CanonicalSemanticMaskSet per source image;
- canonical Skin Only subtracts hair, eyes, lips, clothes and shoes, then intersects person;
- Skin Overlay, Skin Vectorscope, skin statistics and Auto Skin WB receive the same canonical raster mask;
- semantic masks are inserted into the Stage 2 RasterMaskPayload path and therefore inherit Add/Subtract/Intersect, invert, opacity, feather and project persistence;
- ONNX Runtime universal2 keeps the inference path Intel-safe and Apple-Silicon-capable.

Object selection:
- Select Object / Add Object / Subtract Object use macOS Vision foreground-instance masks from a click point and write the result into the same Stage 2 raster stack.
- MobileSAM remains documented as the open-source prompted-object backend candidate; Stage 3 does not falsely claim it is the active runtime provider.
