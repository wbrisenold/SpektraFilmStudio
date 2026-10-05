# SpektraFilmFast v0.5.3 performance changes

- Continuous slider/WB/density motion no longer queues the exact spectral renderer.
- Pointer motion uses the existing 1080p display proxy; one exact preview runs after settle.
- Static filename templates receive a sequence suffix so batch files cannot overwrite each other.
- Duplicate expanded names are disambiguated inside the batch.
- Export pre-decodes one image ahead when the pair is <= 60 MP total; large files fall back to serial decode to protect RAM.
- JPEG/HEIC/8-bit TIFF validation uses ImageIO properties instead of decoding pixels.
- 16-bit TIFF keeps one real decode to verify actual bit depth.
- The final moved file is checked by byte count rather than decoded a second time.
- Build is x86_64 only.
- SwiftPM incremental state is retained.
- The pinned native core/profile generation is cached between normal builds.
- Release executable symbols are stripped.
- Runtime spectral/Metal resources are kept because the renderer loads them at runtime.

A true end-to-end GPU-resident viewer still requires changing the native renderer interface so it can hand an MTLTexture directly to the viewer. This patch removes the largest interaction stall without pretending that CPU PixelBuffer/CGImage presentation has already been eliminated.
