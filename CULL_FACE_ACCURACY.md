# Face grouping and cull accuracy — implementation notes

## Face grouping v2

- More detailed 1600px thumbnails for grouping; face bounding boxes from Apple Vision.
- Two crops per detected face (tight face + wider context) generate comparable Vision image-feature embeddings.
- First pass ranks representative distances, with per-cluster consensus rather than first matching any prior face.
- A second, guarded pass attempts to merge pose/lighting split clusters when multiple independent photo comparisons support them.
- Prevents identities that co-occur in one photograph from being automatically merged.
- Preserves stable group names and IDs on rebuild when groups have at least two overlapping photo IDs; user can manually merge remaining split folders.
- Face samples stay local. No client face images or embedding data are sent to a third-party server.

**Limitations:** `VNGenerateImageFeaturePrintRequest` produces a general image-similarity embedding, not a trained identity-verification vector. Multi-crop and clustering improves consistency but is not equivalent to ArcFace/FaceNet. Similar-looking people can be confused, and hard side profiles may stay split. The thresholds must be validated on mixed group photos before treating grouping as reliable. Manual merges are corrections, not proof of identity.

## Stronger portrait culling

- Keeps existing thumbnail technical metrics and duplicate-stack logic.
- Adds native trained **Apple Vision `VNDetectFaceCaptureQualityRequest`** (portrait quality) and **`VNCalculateImageAestheticsScoresRequest`** (scene aesthetic score, -1...+1) for two extra learned signals. They are combined with the existing technical metrics, with a modest weight to avoid silently rejecting creative photos. The values are saved as optional backward-compatible fields in `CullAnalysisRecord`.
- Reuses cached metrics for filtering: sharp faces, possible blinks, soft/back focus, aesthetic quality, exposure issues, noise, duplicate bursts and unreviewed images.
- `Pick Best in Folder` chooses up to the requested fraction from analyzed eligible photos, ranked by technical score, face sharpness, face capture quality, possible blink and clipping penalties, with burst deduplication. It never deletes originals or overrides a rejected photo. Choosing All Folders applies the fraction independently to each folder.
- If the folder has missing cull records it runs the existing bounded background analysis first, then applies picks.

## Open-source alternatives reviewed

- [OpenPhotoCull](https://github.com/zwoodard/OpenPhotoCull) — MIT-licensed subject-aware focus, face/eye checks, exposure, duplicate/burst and configurable filters, documented publicly. Useful architecture without importing its React/Tauri UI into SwiftUI.
- [OpenCV Zoo SFace](https://github.com/opencv/opencv_zoo/tree/main/models/face_recognition_sface) — stronger identity-specific embedding option, model directory declares Apache-2.0. However, face model training data/weight commercial provenance has a live clarification issue; cannot responsibly claim all distribution/inference rights from code license alone. Not bundled in this patch.
- [InsightFace](https://github.com/deepinsight/insightface) — excellent recognition technology, but bundled/automatically fetched pretrained models are generally non-commercial research use without additional licensing. Not bundled.
- Apple's bundled Vision framework works natively on Intel and requires no extra model redistribution, so this release uses its image-feature and face-quality requests for immediate improvements while leaving room for a later appropriately licensed biometric model.

## Before shipping

On the Intel Mac, test real multi-person wedding/portrait sets for false merges, split identities, face occlusion and alternate lighting; compare before/after grouping; validate the culling threshold by selecting and manually reviewing 500+ diverse photos. Confirm the actual macOS Swift type-check and `VNDetectFaceCaptureQualityRequest` behavior. Source/parser tests alone do not prove identity accuracy.
