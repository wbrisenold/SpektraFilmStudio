#![allow(unsafe_code)]

use std::ffi::CStr;
use std::os::raw::c_char;

const ABI_VERSION: u32 = 3;

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
pub extern "C" fn sf_core_capabilities() -> u64 { 0x000F_0FFF }

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
    if !value.is_finite() { return -7; }
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
            "hostContrast","hostMidtones","hostHighlights","hostShadows",
            "hostWhites","hostBlacks","highlightRecovery","shadowRecovery",
            "creativeRawToneCurve","curvePresets"
        ],
        "masks": [
            "canonicalAiMasks","subject","skin","person","background","hair","eyes",
            "lips","body","upperClothes","lowerClothes","arms","legs","shoes",
            "objectPick","radial","linearGradient","rasterPaint",
            "addSubtractIntersect","invert","feather","overlay"
        ],
        "workflow": [
            "library","cull","proofs","edit","export","ratings","flags",
            "projectFiles","undoRedo","lightroomCatalogImport","icloudLibrary"
        ]
    });
    write_json(&features.to_string(), out, cap)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::CString;

    #[test]
    fn json_capacity_and_null_contract() {
        assert_eq!(write_json("{}", std::ptr::null_mut(), 10), -1);
        let mut short = [0xAAu8; 2];
        assert_eq!(write_json("{}", short.as_mut_ptr(), short.len()), 3);
        assert_eq!(short, [0xAA; 2]);
        let mut enough = [0u8; 3];
        assert_eq!(write_json("{}", enough.as_mut_ptr(), enough.len()), 0);
        assert_eq!(&enough, b"{}\0");
    }

    #[test]
    fn descriptors_are_valid_json() {
        for function in [sf_core_lc_controls_json, sf_core_lc_default_settings_json,
                         sf_core_spektra_feature_manifest_json] {
            let mut out = vec![0u8; 65536];
            assert_eq!(function(out.as_mut_ptr(), out.len()), 0);
            let end = out.iter().position(|b| *b == 0).unwrap();
            assert!(serde_json::from_slice::<serde_json::Value>(&out[..end]).is_ok());
        }
        assert_eq!(sf_core_abi_version(), ABI_VERSION);
    }

    #[test]
    fn rejects_invalid_json_and_nonfinite_controls() {
        let bad = CString::new("not-json").unwrap();
        let id = CString::new("exposure").unwrap();
        let mut out = [0u8; 128];
        unsafe {
            assert_eq!(sf_core_lc_set_control_json(bad.as_ptr(), id.as_ptr(), 0.0, out.as_mut_ptr(), out.len()), -4);
            assert_eq!(sf_core_lc_set_control_json(bad.as_ptr(), id.as_ptr(), f64::INFINITY, out.as_mut_ptr(), out.len()), -7);
        }
    }
}
