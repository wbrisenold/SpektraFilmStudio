# Practical photo workflow in SpektraFilm Studio

## 1. Import with intent

Open **Library → Import Photos…**. Choose images, a shoot folder/camera card, a Lightroom Classic catalog, or a previously created iCloud library. Review the destination and backup choice before starting. A reference import indexes local originals without moving them; verified ingest intentionally creates a working copy and backup. If importing `.lrcat`, review the migration report for missing originals and unmapped settings before treating the transfer as finished.

**Do not put the only copy of a wedding or client session into an untested cloud migration.** Keep your original media, original Lightroom catalog, and an independent backup until you have checked multiple full-res renders and a second Mac.

## 2. Cull the session

Choose **Cull**. Start with **Analyze** to compute subject/facial sharpness, Apple Vision facial-capture quality and aesthetic-scoring models, highlight and shadow clipping, noise, possible blinks and similarity/burst candidates. Filter by characteristic using the toolbar's **Filter** menu. Use **Best Picks** to choose a folder or **All Folders**, and a suggested keep percentage (e.g., 25%). It will analyze missing files, select strong non-redundant frames, and mark them as picked. It **never deletes originals** or overrides a manual reject. Compare visually before delivery; metrics do not understand every creative intention.

## 3. Organize people

In **Library**, select **People → Rescan** to group faces found in photos. The engine checks multiple crops and may consolidate separate clusters when multiple photo examples agree. People detection is an organizational suggestion, not personal identity verification. When one person still appears in two groups, right-click one of them and choose **Merge Into Person…** to correct it. In mixed group pictures, use extra care: two people can appear together and should not be merged based on hairstyle/clothing.

## 4. Build a film look

Start **Edit** with **Adjust → RAW / White Balance**. Choose **As Shot** or **Auto**, or a customized preset that offsets the selected image's own WB. Set Apple RAW exposure, RAW Global Tone and recovery/headroom without clipping important information. This is technically distinct from **Film → Exposure EV** and **Film → Auto Exposure**: those controls act at the film stage.

Then move into **Film**. Choose a film stock and print-paper response. Work through the controls from the original [spektrafilm](https://github.com/andreavolpato/spektrafilm) logic: virtual negative characteristics, film exposure/development and density, printing/enlarger/paper, and scan behavior. Use the original stock and print controls to shape palette and tonality instead of looking for an independent generic color-grading page.

The **ME deSatch** Color Density group supports controlled `0 → -1` reductions in global or six hue sectors. If a look feels too heavy, use stock exposure/print and scene-white-balance adjustments before reaching for arbitrary saturation.

Select **Masks** for a subject/background/skin or a geometric mask. When a mask is selected, compatible adjustments target that mask until **Main Image** is chosen again. Use the common mask overlay to verify you're changing the intended region. Use **Lens Character** for optional optical falloff; drag the on-image center to line it up with the portrait composition.

Check **False Color, clipping warnings, histogram/waveform/vectorscope, and skin diagnostics**. Some monitors are proxies while dragging; verify the settled frame. Diagnostics are not a substitute for a 100% zoom check.

## 5. Deliver or retouch in Photoshop

For a quick individual image, right-click the Edit filmstrip photo or use the **Export** button, and set quality, destination, crop and resize in its compact dialog. For batch delivery, go to **Export**, check the queue, fit/crop, metadata, color space and filename pattern, and render the selected photos.

**My portrait workflow:** use SpektraFilm for the film base, export a full-resolution high-quality TIFF (16-bit when available), open that file in Adobe Photoshop, and do detailed portrait retouching there—skin cleanup, stray hair, distractions and any final pixel-level finishing. Save/deliver from Photoshop. This app does not ship Photoshop or automate its licensing.

## When renders feel slow

- Keep **interactive/idle preview** smaller while adjusting; let the exact settled frame finish.
- For diagnosis, export one picture without costly denoise/masks/halation/optical effects, then enable them individually to find the heavy stage.
- Check RAM and free disk/cache space before large Intel Mac batch exports.
- A full spectral/photographic negative → print → scan path is materially more work than one baked look-up. There *can* be internal spectral-reconstruction LUTs; it is **not** accurate to claim the entire application is LUT-free.
- A crash, export image mismatch or mysteriously frozen slider is a bug: preserve the diagnostic logs/RAW file and report it rather than rationalizing it as film fidelity.
