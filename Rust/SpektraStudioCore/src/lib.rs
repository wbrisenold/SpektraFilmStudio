#![allow(unsafe_code)]

use std::ffi::CStr;
use std::os::raw::c_char;
use std::slice;

use photocraft_algo::{segment::{self, ImageSampler, RgbImage}, selection};
use photocraft_geom::Rect;

const ABI_VERSION: u32 = 3;

unsafe fn rgba8<'a>(ptr: *const u8, width: u32, height: u32) -> Option<&'a [u8]> {
    if ptr.is_null() || width == 0 || height == 0 { return None; }
    let n = (width as usize).checked_mul(height as usize)?.checked_mul(4)?;
    Some(unsafe { slice::from_raw_parts(ptr, n) })
}

unsafe fn mask_out<'a>(ptr: *mut u8, width: u32, height: u32) -> Option<&'a mut [u8]> {
    if ptr.is_null() || width == 0 || height == 0 { return None; }
    Some(unsafe { slice::from_raw_parts_mut(ptr, width as usize * height as usize) })
}

fn pc_rgb_image(src: &[u8], width: usize, height: usize) -> RgbImage {
    RgbImage::from_fn(width, height, |x, y| {
        let i = (y * width + x) * 4;
        [src[i] as f32 / 255.0, src[i + 1] as f32 / 255.0, src[i + 2] as f32 / 255.0]
    })
}

fn write_region(region: &selection::Region, dst: &mut [u8], width: usize, height: usize) {
    dst.fill(0);
    let bw = region.bbox.width() as usize;
    for y in region.bbox.y0.max(0)..region.bbox.y1.min(height as i32) {
        for x in region.bbox.x0.max(0)..region.bbox.x1.min(width as i32) {
            let sx = (x - region.bbox.x0) as usize;
            let sy = (y - region.bbox.y0) as usize;
            let si = sy * bw + sx;
            let di = y as usize * width + x as usize;
            if let (Some(s), Some(d)) = (region.mask.get(si), dst.get_mut(di)) { *d = *s; }
        }
    }
}

fn write_json(s: &str, out: *mut u8, cap: usize) -> i32 {
    if out.is_null() || cap == 0 { return -1; }
    let bytes = s.as_bytes();
    if bytes.len() + 1 > cap { return (bytes.len() + 1) as i32; }
    unsafe {
        std::ptr::copy_nonoverlapping(bytes.as_ptr(), out, bytes.len());
        *out.add(bytes.len()) = 0;
    }
    0
}

#[unsafe(no_mangle)]
pub extern "C" fn sf_core_abi_version() -> u32 { ABI_VERSION }

#[unsafe(no_mangle)]
pub extern "C" fn sf_core_capabilities() -> u64 { 0x000F_FFFF }

#[unsafe(no_mangle)]
pub unsafe extern "C" fn sf_core_pc_select_subject_rgba8(
    input: *const u8, width: u32, height: u32, output_mask: *mut u8
) -> i32 {
    let Some(src) = (unsafe { rgba8(input, width, height) }) else { return -1 };
    let Some(dst) = (unsafe { mask_out(output_mask, width, height) }) else { return -2 };
    let image = pc_rgb_image(src, width as usize, height as usize);
    let sampler = ImageSampler { img: &image, origin: (0, 0) };
    match segment::subject::select_subject(&sampler, Rect::from_xywh(0,0,width,height)) {
        Some(region) => { write_region(&region, dst, width as usize, height as usize); 0 }
        None => { dst.fill(0); 1 }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn sf_core_pc_quick_select_rgba8(
    input: *const u8, width: u32, height: u32,
    points_xy: *const f32, point_count: u32, brush_size: f32,
    output_mask: *mut u8
) -> i32 {
    let Some(src) = (unsafe { rgba8(input, width, height) }) else { return -1 };
    let Some(dst) = (unsafe { mask_out(output_mask, width, height) }) else { return -2 };
    if points_xy.is_null() || point_count == 0 { return -3; }

    let coords = unsafe { slice::from_raw_parts(points_xy, point_count as usize * 2) };
    let points: Vec<(f32,f32)> = coords.chunks_exact(2).map(|p| (p[0],p[1])).collect();
    let image = pc_rgb_image(src, width as usize, height as usize);
    let sampler = ImageSampler { img: &image, origin: (0,0) };
    match segment::quick::quick_select(
        &sampler, Rect::from_xywh(0,0,width,height),
        &points, brush_size.max(1.0), segment::quick::WORK_PX
    ) {
        Some(region) => { write_region(&region, dst, width as usize, height as usize); 0 }
        None => { dst.fill(0); 1 }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn sf_core_pc_magic_wand_rgba8(
    input: *const u8, width: u32, height: u32,
    x: i32, y: i32, tolerance: f32, output_mask: *mut u8
) -> i32 {
    let Some(src) = (unsafe { rgba8(input, width, height) }) else { return -1 };
    let Some(dst) = (unsafe { mask_out(output_mask, width, height) }) else { return -2 };
    if x < 0 || y < 0 || x >= width as i32 || y >= height as i32 { return -3; }

    let pixels: Vec<[f32;4]> = src.chunks_exact(4).map(|p| [
        p[0] as f32/255.0, p[1] as f32/255.0, p[2] as f32/255.0, p[3] as f32/255.0
    ]).collect();

    let mask = selection::magic_wand(
        &pixels, Rect::from_xywh(0,0,width,height),
        (x,y), tolerance.clamp(0.0,255.0), true, true
    );
    for (d,v) in dst.iter_mut().zip(mask) {
        *d = (v.clamp(0.0,1.0)*255.0 + 0.5) as u8;
    }
    0
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn sf_core_pc_feather_mask_u8(
    input_mask: *const u8, width: u32, height: u32,
    radius: f32, output_mask: *mut u8
) -> i32 {
    if input_mask.is_null() { return -1; }
    let Some(dst) = (unsafe { mask_out(output_mask, width, height) }) else { return -2 };
    let n = width as usize * height as usize;
    let src = unsafe { slice::from_raw_parts(input_mask, n) };
    let m: Vec<f32> = src.iter().map(|v| *v as f32/255.0).collect();
    let f = selection::feather(&m, width as usize, height as usize, radius.max(0.0));
    for (d,v) in dst.iter_mut().zip(f) {
        *d = (v.clamp(0.0,1.0)*255.0 + 0.5) as u8;
    }
    0
}

#[unsafe(no_mangle)]
pub extern "C" fn sf_core_lc_controls_json(out: *mut u8, cap: usize) -> i32 {
    match serde_json::to_string(lightcraft_develop::controls::CONTROLS) {
        Ok(s) => write_json(&s, out, cap),
        Err(_) => -2,
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn sf_core_lc_default_settings_json(out: *mut u8, cap: usize) -> i32 {
    match serde_json::to_string(&lightcraft_develop::DevelopSettings::default()) {
        Ok(s) => write_json(&s, out, cap),
        Err(_) => -2,
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn sf_core_lc_set_control_json(
    input_json: *const c_char,
    control_id: *const c_char,
    value: f64,
    out: *mut u8,
    cap: usize
) -> i32 {
    if input_json.is_null() || control_id.is_null() { return -1; }
    let Ok(json) = (unsafe { CStr::from_ptr(input_json) }).to_str() else { return -2; };
    let Ok(id) = (unsafe { CStr::from_ptr(control_id) }).to_str() else { return -3; };
    let Ok(mut settings) = serde_json::from_str::<lightcraft_develop::DevelopSettings>(json) else { return -4; };
    if !lightcraft_develop::controls::set(&mut settings, id, value) { return -5; }
    match serde_json::to_string(&settings) {
        Ok(s) => write_json(&s, out, cap),
        Err(_) => -6,
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn sf_core_spektra_feature_manifest_json(out: *mut u8, cap: usize) -> i32 {
    let features = serde_json::json!({
        "diagnostics": [
            "falseColor","clippingIndicator","clippingPercentages","histogram",
            "waveform","rgbParade","vectorscope","skinVectorscope",
            "saturationScope","skinOverlay","skinAnalysis"
        ],
        "whiteBalance": [
            "asShot","autoWB","autoSkinWB","temperature","tint","creativeWbPresets"
        ],
        "rawDevelop": [
            "rawExposure","rawTone","rawShadowBoost","highlightHeadroom",
            "creativeRawToneCurve","curvePresets"
        ],
        "filmStock": [
            "nativeFilmStockExposureEV","filmHighlights","filmShadows","filmWhites",
            "filmBlacks","filmContrast","filmBrightness","highlightRecovery",
            "shadowRecovery","filmStockPresets"
        ],
        "masks": [
            "canonicalAiMasks","subject","skin","person","background","hair","eyes",
            "lips","body","upperClothes","lowerClothes","arms","legs","shoes",
            "objectPick","quickSelect","magicWand","radial","linearGradient",
            "rasterPaint","addSubtractIntersect","invert","feather","overlay"
        ],
        "creative": [
            "presets","curvePresets","frames","filmFrames","whiteFrames","borders",
            "collages","doubleExposure","socialCarousel","textTemplates"
        ],
        "workflow": [
            "library","cull","edit","create","export","ratings","flags",
            "projectFiles","undoRedo"
        ]
    });
    write_json(&features.to_string(), out, cap)
}
