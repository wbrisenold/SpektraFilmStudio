#include "SpektraAppBridge.h"

#include "SpektraMetalRenderer.h"
#include "SpektraProfileCurves.h"

#include <algorithm>
#include <cstring>
#include <memory>
#include <string>

struct SpektraRendererHandle {
  std::unique_ptr<spektrafilm::Renderer> renderer;
  std::string lastError;
};

namespace {

enum ParamTag : uint32_t {
  kParamTagNone = 0u,
  kParamTagFlow = 1u << 0u,
  kParamTagDevelopment = 1u << 1u,
};

struct ChoiceOption {
  const char *optionSet;
  const char *label;
};

constexpr ChoiceOption kStaticOptions[] = {
  {"process", "Print simulation"},
  {"process", "Scan negative"},
  {"process", "Process negative"},
  {"rgbToRawMethod", "Hanatos 2026"},
  {"rgbToRawMethod", "Hanatos 2025"},
  {"rgbToRawMethod", "Mallett 2019"},
  {"colorSpace", "ARRI LogC4"},
  {"colorSpace", "ARRI LogC3 EI800"},
  {"colorSpace", "BMDFilm WideGamut Gen5"},
  {"colorSpace", "DaVinci Intermediate WideGamut"},
  {"colorSpace", "RED Log3G10 REDWideGamutRGB"},
  {"colorSpace", "Sony S-Log3 S-Gamut3"},
  {"colorSpace", "Sony S-Log3 S-Gamut3.Cine"},
  {"colorSpace", "Canon Log2 CinemaGamut D55"},
  {"colorSpace", "Canon Log3 CinemaGamut D55"},
  {"colorSpace", "Panasonic V-Log V-Gamut"},
  {"colorSpace", "ACES2065-1"},
  {"colorSpace", "ACEScg"},
  {"colorSpace", "ACEScct"},
  {"colorSpace", "ACEScc"},
  {"colorSpace", "Linear Rec.2020"},
  {"colorSpace", "Linear Rec.709"},
  {"colorSpace", "Linear P3-D65"},
  {"colorSpace", "sRGB"},
  {"colorSpace", "Display P3"},
  {"colorSpace", "ProPhoto RGB"},
  {"colorSpace", "Adobe RGB (1998)"},
  {"colorSpace", "DCI-P3"},
  {"colorSpace", "P3-D65 Gamma 2.2"},
  {"colorSpace", "P3-D65 Gamma 2.6"},
  {"colorSpace", "Rec.709 Gamma 2.2"},
  {"colorSpace", "Rec.709 Gamma 2.4"},
  {"outputRole", "Display Out SDR"},
  {"outputRole", "Display Out HDR"},
  {"outputRole", "RCM/ACES (Beta)"},
  {"hdrPreset", "PQ 1000"},
  {"hdrPreset", "PQ 4000"},
  {"hdrPreset", "HLG 1000"},
  {"hdrPreset", "Custom"},
  {"hdrTransfer", "Rec.2100 ST2084 (PQ)"},
  {"hdrTransfer", "Rec.2100 HLG"},
  {"hdrToneMapping", "Soft Rolloff"},
  {"hdrToneMapping", "Hard Clip"},
  {"autoExposureMethod", "Center weighted"},
  {"autoExposureMethod", "Median"},
  {"pushPullMode", "Standard"},
  {"pushPullMode", "Experimental"},
  {"printTiming", "Filtered enlarger"},
  {"printTiming", "APD printer density"},
  {"grainModel", "Preview"},
  {"grainModel", "Production"},
  {"grainModel", "Grain Synthesis"},
  {"filmFormat", "Standard 8"},
  {"filmFormat", "Super 8"},
  {"filmFormat", "Standard 16"},
  {"filmFormat", "Super 16"},
  {"filmFormat", "Standard 35"},
  {"filmFormat", "Super 35"},
  {"filmFormat", "Standard 65"},
  {"filmFormat", "IMAX 70"},
  {"diffusionFamily", "Glimmerglass"},
  {"diffusionFamily", "Black Pro-Mist"},
  {"diffusionFamily", "Pro-Mist"},
  {"diffusionFamily", "CineBloom"},
};

constexpr SpektraAppGroupDescriptor kGroups[] = {
  {"color", "Color"},
  {"raw", "RAW"},
  {"filtering", "Filtering"},
  {"film", "Film"},
  {"print", "Print"},
  {"filmPlane", "Film Plane"},
  {"dir", "DIR Couplers"},
  {"grain", "Grain"},
  {"grainSynthesis", "Grain Synthesis"},
  {"halation", "Halation"},
  {"diffusion", "Diffusion"},
  {"scanner", "Scanner"},
  {"manage", "Manage"},
};

constexpr SpektraAppParamDescriptor param(
  const char *name,
  const char *label,
  const char *group,
  int32_t kind,
  uint32_t tags,
  int32_t defaultInt,
  double default0,
  double default1,
  double default2,
  double minimum,
  double maximum,
  const char *optionSet = ""
) {
  const int32_t tier = (tags & kParamTagDevelopment) != 0u ? SpektraAppVisibilityTierDev :
    ((tags & kParamTagFlow) != 0u ? SpektraAppVisibilityTierFlow : SpektraAppVisibilityTierPro);
  return {name, label, group, optionSet, kind, tier, defaultInt, {default0, default1, default2}, minimum, maximum};
}

constexpr SpektraAppParamDescriptor kParams[] = {
  param("process", "Mode", "color", SpektraAppParamKindChoice, kParamTagFlow, 0, 0.0, 0.0, 0.0, 0.0, 2.0, "process"),
  param("scanNegativeInvert", "Invert Negative Scan", "color", SpektraAppParamKindBool, kParamTagFlow, 0, 0.0, 0.0, 0.0, 0.0, 1.0),
  param("inputColorSpace", "Input Color Space", "color", SpektraAppParamKindChoice, kParamTagFlow, 14, 0.0, 0.0, 0.0, 0.0, 25.0, "colorSpace"),
  param("outputColorSpace", "Output Color Space", "color", SpektraAppParamKindChoice, kParamTagFlow, 25, 0.0, 0.0, 0.0, 0.0, 25.0, "colorSpace"),
  param("outputRole", "Output Role", "color", SpektraAppParamKindChoice, kParamTagFlow, 0, 0.0, 0.0, 0.0, 0.0, 2.0, "outputRole"),
  param("hdrPreset", "HDR Preset", "color", SpektraAppParamKindChoice, kParamTagFlow, 0, 0.0, 0.0, 0.0, 0.0, 3.0, "hdrPreset"),
  param("hdrTransfer", "HDR Transfer", "color", SpektraAppParamKindChoice, kParamTagFlow, 0, 0.0, 0.0, 0.0, 0.0, 1.0, "hdrTransfer"),
  param("hdrReferenceWhiteNits", "Reference White Nits", "color", SpektraAppParamKindDouble, kParamTagFlow, 0, 203.0, 0.0, 0.0, 48.0, 1000.0),
  param("hdrPeakNits", "Peak Nits", "color", SpektraAppParamKindDouble, kParamTagFlow, 0, 1000.0, 0.0, 0.0, 100.0, 10000.0),
  param("hdrExposureEv", "HDR Exposure EV", "color", SpektraAppParamKindDouble, kParamTagFlow, 0, 0.0, 0.0, 0.0, -8.0, 8.0),
  param("hdrToneMapping", "HDR Tone Mapping", "color", SpektraAppParamKindChoice, kParamTagFlow, 1, 0.0, 0.0, 0.0, 0.0, 1.0, "hdrToneMapping"),
  param("colorAdaptation", "Color Adaptation", "color", SpektraAppParamKindBool, kParamTagFlow, 0, 0.0, 0.0, 0.0, 0.0, 1.0),
  param("colorAdaptationInputCompression", "Input Compression", "color", SpektraAppParamKindBool, kParamTagNone, 1, 0.0, 0.0, 0.0, 0.0, 1.0),
  param("colorAdaptationCurveSmoothing", "Curve Smoothing", "color", SpektraAppParamKindBool, kParamTagNone, 1, 0.0, 0.0, 0.0, 0.0, 1.0),
  param("colorAdaptationOutputLightnessCompression", "Output Lightness Compression", "color", SpektraAppParamKindBool, kParamTagNone, 1, 0.0, 0.0, 0.0, 0.0, 1.0),
  param("colorAdaptationOutputChromaCompression", "Output Chroma Compression", "color", SpektraAppParamKindBool, kParamTagNone, 1, 0.0, 0.0, 0.0, 0.0, 1.0),

  param("rawWhiteBalanceMode", "White Balance", "raw", SpektraAppParamKindChoice, kParamTagFlow, 0, 0.0, 0.0, 0.0, 0.0, 2.0, "rawWhiteBalance"),
  param("rawTemperature", "Temperature", "raw", SpektraAppParamKindDouble, kParamTagFlow, 0, 5500.0, 0.0, 0.0, 2000.0, 50000.0),
  param("rawTint", "Tint", "raw", SpektraAppParamKindDouble, kParamTagFlow, 0, 0.0, 0.0, 0.0, -150.0, 150.0),
  param("rawLensCorrection", "Vendor Lens Correction", "raw", SpektraAppParamKindBool, kParamTagFlow, 0, 0.0, 0.0, 0.0, 0.0, 1.0),

  param("cameraUvFilterEnabled", "Filter UV", "filtering", SpektraAppParamKindBool, kParamTagNone, 0, 0.0, 0.0, 0.0, 0.0, 1.0),
  param("cameraUvCutNm", "UV Cut nm", "filtering", SpektraAppParamKindDouble, kParamTagNone, 0, 410.0, 0.0, 0.0, 380.0, 450.0),
  param("cameraIrFilterEnabled", "Filter IR", "filtering", SpektraAppParamKindBool, kParamTagNone, 0, 0.0, 0.0, 0.0, 0.0, 1.0),
  param("cameraIrCutNm", "IR Cut nm", "filtering", SpektraAppParamKindDouble, kParamTagNone, 0, 675.0, 0.0, 0.0, 600.0, 780.0),

  param("rgbToRawMethod", "RGB to Raw", "film", SpektraAppParamKindChoice, kParamTagFlow, 0, 0.0, 0.0, 0.0, 0.0, 2.0, "rgbToRawMethod"),
  param("film", "Stock", "film", SpektraAppParamKindFilmStock, kParamTagFlow, static_cast<int32_t>(spektrafilm::kSpektraDefaultFilmIndex), 0.0, 0.0, 0.0, 0.0, 1000.0, "film"),
  param("filmFormat", "Film Format", "film", SpektraAppParamKindChoice, kParamTagFlow, 4, 0.0, 0.0, 0.0, 0.0, 7.0, "filmFormat"),
  param("filmExposureEv", "Exposure EV", "film", SpektraAppParamKindDouble, kParamTagFlow, 0, 0.0, 0.0, 0.0, -8.0, 8.0),
  param("autoExposure", "Auto Exposure", "film", SpektraAppParamKindBool, kParamTagNone, 0, 0.0, 0.0, 0.0, 0.0, 1.0),
  param("autoExposureMethod", "Auto Exposure Meter", "film", SpektraAppParamKindChoice, kParamTagNone, 0, 0.0, 0.0, 0.0, 0.0, 1.0, "autoExposureMethod"),
  param("filmPushPullMode", "Push / Pull Mode", "film", SpektraAppParamKindChoice, kParamTagFlow, 0, 0.0, 0.0, 0.0, 0.0, 1.0, "pushPullMode"),
  param("filmPushPullStops", "Film Push / Pull Stops", "film", SpektraAppParamKindDouble, kParamTagFlow, 0, 0.0, 0.0, 0.0, -2.0, 2.0),
  param("negativeBleachBypassAmount", "Negative Bleach Bypass", "film", SpektraAppParamKindDouble, kParamTagDevelopment, 0, 0.0, 0.0, 0.0, 0.0, 1.0),
  param("negativeLeucoCyanCoupling", "Leuco-Cyan Coupling", "film", SpektraAppParamKindDouble, kParamTagDevelopment, 0, 1.0, 0.0, 0.0, 0.0, 2.0),
  param("filmGamma", "Gamma", "film", SpektraAppParamKindDouble, kParamTagDevelopment, 0, 1.0, 0.0, 0.0, 0.1, 2.0),

  param("paper", "Paper", "print", SpektraAppParamKindPrintPaper, kParamTagFlow, static_cast<int32_t>(spektrafilm::kSpektraDefaultPaperIndex), 0.0, 0.0, 0.0, 0.0, 1000.0, "paper"),
  param("printTiming", "Print Timing", "print", SpektraAppParamKindChoice, kParamTagFlow, 0, 0.0, 0.0, 0.0, 0.0, 1.0, "printTiming"),
  param("printExposureEv", "Exposure EV", "print", SpektraAppParamKindDouble, kParamTagFlow, 0, 0.0, 0.0, 0.0, -5.0, 5.0),
  param("printPushPullStops", "Print Push / Pull Stops", "print", SpektraAppParamKindDouble, kParamTagFlow, 0, 0.0, 0.0, 0.0, -2.0, 2.0),
  param("printBleachBypassAmount", "Print Bleach Bypass", "print", SpektraAppParamKindDouble, kParamTagDevelopment, 0, 0.0, 0.0, 0.0, 0.0, 1.0),
  param("printGamma", "Gamma", "print", SpektraAppParamKindDouble, kParamTagDevelopment, 0, 1.0, 0.0, 0.0, 0.1, 2.0),
  param("printShadowShape", "Shadow Shape", "print", SpektraAppParamKindDouble, kParamTagFlow, 0, 0.0, 0.0, 0.0, -1.0, 1.0),
  param("printHighlightShape", "Highlight Shape", "print", SpektraAppParamKindDouble, kParamTagFlow, 0, 0.0, 0.0, 0.0, -1.0, 1.0),
  param("filterC", "C Filter", "print", SpektraAppParamKindDouble, kParamTagFlow, 0, 0.0, 0.0, 0.0, 0.0, 120.0),
  param("filterMShift", "M Filter Shift", "print", SpektraAppParamKindDouble, kParamTagFlow, 0, 0.0, 0.0, 0.0, -60.0, 60.0),
  param("filterYShift", "Y Filter Shift", "print", SpektraAppParamKindDouble, kParamTagFlow, 0, 0.0, 0.0, 0.0, -60.0, 60.0),
  param("preflashExposure", "Preflash Exposure", "print", SpektraAppParamKindDouble, kParamTagNone, 0, 0.0, 0.0, 0.0, 0.0, 1.0),
  param("preflashMFilterShift", "Preflash M Filter Shift", "print", SpektraAppParamKindDouble, kParamTagNone, 0, 0.0, 0.0, 0.0, -60.0, 60.0),
  param("preflashYFilterShift", "Preflash Y Filter Shift", "print", SpektraAppParamKindDouble, kParamTagNone, 0, 0.0, 0.0, 0.0, -60.0, 60.0),
  param("printerLightsGang", "Gang Printer Points", "print", SpektraAppParamKindBool, kParamTagFlow, 0, 0.0, 0.0, 0.0, 0.0, 1.0),
  param("printerLightR", "Printer Point R", "print", SpektraAppParamKindDouble, kParamTagFlow, 0, 0.0, 0.0, 0.0, -24.0, 24.0),
  param("printerLightG", "Printer Point G", "print", SpektraAppParamKindDouble, kParamTagFlow, 0, 0.0, 0.0, 0.0, -24.0, 24.0),
  param("printerLightB", "Printer Point B", "print", SpektraAppParamKindDouble, kParamTagFlow, 0, 0.0, 0.0, 0.0, -24.0, 24.0),
  param("printerLightCalibration", "Printer Point Calibration", "print", SpektraAppParamKindBool, kParamTagNone, 1, 0.0, 0.0, 0.0, 0.0, 1.0),

  param("enlargerScale", "Scale", "filmPlane", SpektraAppParamKindDouble, kParamTagNone, 0, 1.0, 0.0, 0.0, 1.0, 32.0),
  param("enlargerOffsetXPercent", "Offset X %", "filmPlane", SpektraAppParamKindDouble, kParamTagNone, 0, 0.0, 0.0, 0.0, -100.0, 100.0),
  param("enlargerOffsetYPercent", "Offset Y %", "filmPlane", SpektraAppParamKindDouble, kParamTagNone, 0, 0.0, 0.0, 0.0, -100.0, 100.0),

  param("dirCouplersAmount", "Amount", "dir", SpektraAppParamKindDouble, kParamTagFlow, 0, 1.0, 0.0, 0.0, 0.0, 2.0),
  param("dirCouplersDiffusionUm", "Diffusion um", "dir", SpektraAppParamKindDouble, kParamTagFlow, 0, 20.0, 0.0, 0.0, 0.0, 100.0),
  param("dirCouplersDiffusionTailUm", "Tail um", "dir", SpektraAppParamKindDouble, kParamTagNone, 0, 200.0, 0.0, 0.0, 0.0, 1000.0),
  param("dirCouplersDiffusionTailWeight", "Tail Weight", "dir", SpektraAppParamKindDouble, kParamTagNone, 0, 0.06, 0.0, 0.0, 0.0, 1.0),
  param("dirCouplersInhibitionSameLayer", "Same-Layer Inhibition", "dir", SpektraAppParamKindDouble, kParamTagFlow, 0, 1.0, 0.0, 0.0, 0.0, 2.0),
  param("dirCouplersInhibitionInterlayer", "Interlayer Inhibition", "dir", SpektraAppParamKindDouble, kParamTagFlow, 0, 1.0, 0.0, 0.0, 0.0, 2.0),
  param("dirGammaSameLayerRgb", "Same-Layer Gamma RGB", "dir", SpektraAppParamKindDouble3, kParamTagNone, 0, 0.336, 0.319, 0.273, 0.0, 1.0),
  param("dirGammaRToGb", "R -> G/B Gamma", "dir", SpektraAppParamKindDouble2, kParamTagNone, 0, 0.353, 0.302, 0.0, 0.0, 1.0),
  param("dirGammaGToRb", "G -> R/B Gamma", "dir", SpektraAppParamKindDouble2, kParamTagNone, 0, 0.154, 0.353, 0.0, 0.0, 1.0),
  param("dirGammaBToRg", "B -> R/G Gamma", "dir", SpektraAppParamKindDouble2, kParamTagNone, 0, 0.168, 0.226, 0.0, 0.0, 1.0),

  param("grainEnabled", "Enabled", "grain", SpektraAppParamKindBool, kParamTagFlow, 0, 0.0, 0.0, 0.0, 0.0, 1.0),
  param("grainModel", "Model", "grain", SpektraAppParamKindChoice, kParamTagFlow, 0, 0.0, 0.0, 0.0, 0.0, 2.0, "grainModel"),
  param("grainAmount", "Amount", "grain", SpektraAppParamKindDouble, kParamTagFlow, 0, 1.0, 0.0, 0.0, 0.0, 2.0),
  param("grainSaturation", "Saturation", "grain", SpektraAppParamKindDouble, kParamTagFlow, 0, 1.0, 0.0, 0.0, 0.0, 1.0),
  param("grainParticleAreaUm2", "Particle Area um2", "grain", SpektraAppParamKindDouble, kParamTagFlow, 0, 0.1, 0.0, 0.0, 0.01, 5.0),
  param("grainSublayersEnabled", "Sublayers", "grain", SpektraAppParamKindBool, kParamTagNone, 1, 0.0, 0.0, 0.0, 0.0, 1.0),
  param("grainSubLayerCount", "Sub Layer Count", "grain", SpektraAppParamKindInt, kParamTagNone, 1, 0.0, 0.0, 0.0, 1.0, 8.0),
  param("grainParticleScale", "Particle Scale RGB", "grain", SpektraAppParamKindDouble3, kParamTagNone, 0, 1.2, 1.0, 2.5, 0.0, 8.0),
  param("grainParticleScaleLayers", "Layer Scale", "grain", SpektraAppParamKindDouble3, kParamTagNone, 0, 6.0, 1.0, 0.4, 0.0, 8.0),
  param("grainDensityMin", "Density Min", "grain", SpektraAppParamKindDouble3, kParamTagNone, 0, 0.04, 0.05, 0.06, 0.0, 1.0),
  param("grainUniformity", "Uniformity RGB", "grain", SpektraAppParamKindDouble3, kParamTagNone, 0, 0.99, 0.97, 0.98, 0.0, 1.0),
  param("grainFinalBlurUm", "Final Grain Blur", "grain", SpektraAppParamKindDouble, kParamTagNone, 0, 7.17, 0.0, 0.0, 0.0, 25.0),
  param("grainBlurDyeCloudsUm", "Dye Cloud Blur um", "grain", SpektraAppParamKindDouble, kParamTagNone, 0, 1.0, 0.0, 0.0, 0.0, 10.0),
  param("grainMicroStructure", "Micro Structure", "grain", SpektraAppParamKindDouble2, kParamTagNone, 0, 0.2, 30.0, 0.0, 0.0, 100.0),
  param("grainSeed", "Seed", "grain", SpektraAppParamKindInt, kParamTagNone, 1, 0.0, 0.0, 0.0, 0.0, 1000000.0),
  param("grainAnimate", "Animate", "grain", SpektraAppParamKindBool, kParamTagNone, 0, 0.0, 0.0, 0.0, 0.0, 1.0),
  param("grainSynthesisSize", "Synthesis Size", "grain", SpektraAppParamKindDouble, kParamTagDevelopment, 0, 1.0, 0.0, 0.0, 0.25, 4.0),
  param("grainSynthesisAmount", "Synthesis Amount", "grain", SpektraAppParamKindDouble, kParamTagDevelopment, 0, 1.0, 0.0, 0.0, 0.0, 3.0),
  param("grainSynthesisSharpness", "Synthesis Sharpness", "grain", SpektraAppParamKindDouble, kParamTagDevelopment, 0, 1.0, 0.0, 0.0, 0.25, 4.0),
  param("grainSynthesisQuality", "Synthesis Quality", "grain", SpektraAppParamKindDouble, kParamTagDevelopment, 0, 1.0, 0.0, 0.0, 0.25, 4.0),

  param("grainSynthesisSamples", "Samples", "grainSynthesis", SpektraAppParamKindInt, kParamTagDevelopment, 128, 0.0, 0.0, 0.0, 1.0, 2048.0),
  param("grainSynthesisMeanRadiusUm", "Mean Radius um", "grainSynthesis", SpektraAppParamKindDouble, kParamTagDevelopment, 0, 0.25, 0.0, 0.0, 0.05, 10.0),
  param("grainSynthesisRadiusStdDevRatio", "Radius StdDev Ratio", "grainSynthesis", SpektraAppParamKindDouble, kParamTagDevelopment, 0, 0.0, 0.0, 0.0, 0.0, 1.0),
  param("grainSynthesisObservationSigmaUm", "Observation Aperture Sigma um", "grainSynthesis", SpektraAppParamKindDouble, kParamTagDevelopment, 0, 1.0, 0.0, 0.0, 0.0, 20.0),
  param("grainSynthesisCellSizeRatio", "Cell Size Ratio", "grainSynthesis", SpektraAppParamKindDouble, kParamTagDevelopment, 0, 1.0, 0.0, 0.0, 0.25, 2.0),
  param("grainSynthesisMaxRadiusQuantile", "Max Radius Quantile", "grainSynthesis", SpektraAppParamKindDouble, kParamTagDevelopment, 0, 0.999, 0.0, 0.0, 0.95, 0.9999),
  param("grainSynthesisCoverageEpsilon", "Coverage Epsilon", "grainSynthesis", SpektraAppParamKindDouble, kParamTagDevelopment, 0, 0.0001, 0.0, 0.0, 0.000001, 0.01),
  param("grainSynthesisMaxGrainsPerCell", "Max Grains Per Cell", "grainSynthesis", SpektraAppParamKindInt, kParamTagDevelopment, 32, 0.0, 0.0, 0.0, 1.0, 128.0),
  param("grainSynthesisRadiusScale", "Radius Scale RGB", "grainSynthesis", SpektraAppParamKindDouble3, kParamTagDevelopment, 0, 1.2, 1.0, 2.5, 0.0, 8.0),
  param("grainSynthesisLayerScale", "Layer Scale", "grainSynthesis", SpektraAppParamKindDouble3, kParamTagDevelopment, 0, 6.0, 1.0, 0.4, 0.0, 8.0),
  param("grainSynthesisLayered", "Layered", "grainSynthesis", SpektraAppParamKindBool, kParamTagDevelopment, 1, 0.0, 0.0, 0.0, 0.0, 1.0),

  param("halationEnabled", "Enabled", "halation", SpektraAppParamKindBool, kParamTagFlow, 0, 0.0, 0.0, 0.0, 0.0, 1.0),
  param("scatterAmount", "Scatter Amount", "halation", SpektraAppParamKindDouble, kParamTagNone, 0, 1.0, 0.0, 0.0, 0.0, 2.0),
  param("scatterScale", "Scatter Scale", "halation", SpektraAppParamKindDouble, kParamTagNone, 0, 1.0, 0.0, 0.0, 0.0, 4.0),
  param("halationAmount", "Amount", "halation", SpektraAppParamKindDouble, kParamTagFlow, 0, 1.0, 0.0, 0.0, 0.0, 4.0),
  param("halationScale", "Scale", "halation", SpektraAppParamKindDouble, kParamTagFlow, 0, 1.0, 0.0, 0.0, 0.0, 4.0),
  param("halationBoostEv", "Boost EV", "halation", SpektraAppParamKindDouble, kParamTagFlow, 0, 0.0, 0.0, 0.0, 0.0, 20.0),
  param("halationBoostRange", "Boost Range", "halation", SpektraAppParamKindDouble, kParamTagNone, 0, 0.3, 0.0, 0.0, 0.0, 1.0),
  param("halationProtectEv", "Protect EV", "halation", SpektraAppParamKindDouble, kParamTagNone, 0, 4.0, 0.0, 0.0, 0.0, 10.0),
  param("halationStrength", "Strength RGB", "halation", SpektraAppParamKindDouble3, kParamTagFlow, 0, 0.05, 0.015, 0.0, 0.0, 1.0),

  param("cameraDiffusionEnabled", "Camera Enabled", "diffusion", SpektraAppParamKindBool, kParamTagFlow, 0, 0.0, 0.0, 0.0, 0.0, 1.0),
  param("cameraDiffusionFamily", "Camera Family", "diffusion", SpektraAppParamKindChoice, kParamTagFlow, 1, 0.0, 0.0, 0.0, 0.0, 3.0, "diffusionFamily"),
  param("cameraDiffusionStrength", "Camera Strength", "diffusion", SpektraAppParamKindDouble, kParamTagFlow, 0, 0.5, 0.0, 0.0, 0.0, 2.0),
  param("cameraDiffusionSpatialScale", "Camera Spatial Scale", "diffusion", SpektraAppParamKindDouble, kParamTagNone, 0, 1.0, 0.0, 0.0, 0.0, 4.0),
  param("cameraDiffusionHaloWarmth", "Camera Halo Warmth", "diffusion", SpektraAppParamKindDouble, kParamTagFlow, 0, 0.0, 0.0, 0.0, -1.5, 1.5),
  param("cameraDiffusionCoreIntensity", "Camera Core Intensity", "diffusion", SpektraAppParamKindDouble, kParamTagNone, 0, 1.0, 0.0, 0.0, 0.0, 4.0),
  param("cameraDiffusionCoreSize", "Camera Core Size", "diffusion", SpektraAppParamKindDouble, kParamTagNone, 0, 1.0, 0.0, 0.0, 0.1, 4.0),
  param("cameraDiffusionHaloIntensity", "Camera Halo Intensity", "diffusion", SpektraAppParamKindDouble, kParamTagNone, 0, 1.0, 0.0, 0.0, 0.0, 4.0),
  param("cameraDiffusionHaloSize", "Camera Halo Size", "diffusion", SpektraAppParamKindDouble, kParamTagNone, 0, 1.0, 0.0, 0.0, 0.1, 4.0),
  param("cameraDiffusionBloomIntensity", "Camera Bloom Intensity", "diffusion", SpektraAppParamKindDouble, kParamTagNone, 0, 1.0, 0.0, 0.0, 0.0, 4.0),
  param("cameraDiffusionBloomSize", "Camera Bloom Size", "diffusion", SpektraAppParamKindDouble, kParamTagNone, 0, 1.0, 0.0, 0.0, 0.1, 4.0),
  param("printDiffusionEnabled", "Print Enabled", "diffusion", SpektraAppParamKindBool, kParamTagFlow, 0, 0.0, 0.0, 0.0, 0.0, 1.0),
  param("printDiffusionFamily", "Print Family", "diffusion", SpektraAppParamKindChoice, kParamTagFlow, 1, 0.0, 0.0, 0.0, 0.0, 3.0, "diffusionFamily"),
  param("printDiffusionStrength", "Print Strength", "diffusion", SpektraAppParamKindDouble, kParamTagFlow, 0, 0.5, 0.0, 0.0, 0.0, 2.0),
  param("printDiffusionSpatialScale", "Print Spatial Scale", "diffusion", SpektraAppParamKindDouble, kParamTagNone, 0, 1.0, 0.0, 0.0, 0.0, 4.0),
  param("printDiffusionHaloWarmth", "Print Halo Warmth", "diffusion", SpektraAppParamKindDouble, kParamTagFlow, 0, 0.0, 0.0, 0.0, -1.5, 1.5),
  param("printDiffusionCoreIntensity", "Print Core Intensity", "diffusion", SpektraAppParamKindDouble, kParamTagNone, 0, 1.0, 0.0, 0.0, 0.0, 4.0),
  param("printDiffusionCoreSize", "Print Core Size", "diffusion", SpektraAppParamKindDouble, kParamTagNone, 0, 1.0, 0.0, 0.0, 0.1, 4.0),
  param("printDiffusionHaloIntensity", "Print Halo Intensity", "diffusion", SpektraAppParamKindDouble, kParamTagNone, 0, 1.0, 0.0, 0.0, 0.0, 4.0),
  param("printDiffusionHaloSize", "Print Halo Size", "diffusion", SpektraAppParamKindDouble, kParamTagNone, 0, 1.0, 0.0, 0.0, 0.1, 4.0),
  param("printDiffusionBloomIntensity", "Print Bloom Intensity", "diffusion", SpektraAppParamKindDouble, kParamTagNone, 0, 1.0, 0.0, 0.0, 0.0, 4.0),
  param("printDiffusionBloomSize", "Print Bloom Size", "diffusion", SpektraAppParamKindDouble, kParamTagNone, 0, 1.0, 0.0, 0.0, 0.1, 4.0),

  param("scannerEnabled", "Enabled", "scanner", SpektraAppParamKindBool, kParamTagFlow, 0, 0.0, 0.0, 0.0, 0.0, 1.0),
  param("scannerWhiteCorrection", "White Correction", "scanner", SpektraAppParamKindBool, kParamTagFlow, 0, 0.0, 0.0, 0.0, 0.0, 1.0),
  param("scannerBlackCorrection", "Black Correction", "scanner", SpektraAppParamKindBool, kParamTagFlow, 0, 0.0, 0.0, 0.0, 0.0, 1.0),
  param("scannerWhiteLevel", "White Level", "scanner", SpektraAppParamKindDouble, kParamTagFlow, 0, 0.98, 0.0, 0.0, 0.0, 1.0),
  param("scannerBlackLevel", "Black Level", "scanner", SpektraAppParamKindDouble, kParamTagFlow, 0, 0.01, 0.0, 0.0, 0.0, 1.0),
  param("glarePercent", "Glare Percent", "scanner", SpektraAppParamKindDouble, kParamTagNone, 0, 0.03, 0.0, 0.0, 0.0, 0.2),
  param("glareRoughness", "Glare Roughness", "scanner", SpektraAppParamKindDouble, kParamTagNone, 0, 0.7, 0.0, 0.0, 0.0, 4.0),
  param("glareBlur", "Glare Blur", "scanner", SpektraAppParamKindDouble, kParamTagNone, 0, 0.5, 0.0, 0.0, 0.0, 32.0),
  param("scannerMtf50LpMm", "MTF50 lp/mm", "scanner", SpektraAppParamKindDouble, kParamTagNone, 0, 60.0, 0.0, 0.0, 0.0, 300.0),
  param("scannerUnsharpRadiusUm", "Unsharp Radius um", "scanner", SpektraAppParamKindDouble, kParamTagNone, 0, 5.0, 0.0, 0.0, 0.0, 100.0),
  param("scannerUnsharpAmount", "Unsharp Amount", "scanner", SpektraAppParamKindDouble, kParamTagNone, 0, 0.7, 0.0, 0.0, 0.0, 4.0),
};

bool sameName(const char *a, const char *b) {
  return a && b && std::strcmp(a, b) == 0;
}

spektrafilm::RenderParams toRendererParams(const SpektraAppRenderParams &p) {
  spektrafilm::RenderParams out{};
  out.process = static_cast<spektrafilm::ProcessMode>(p.process);
  out.scanNegativeInvert = p.scanNegativeInvert != 0;
  out.renderOutput = static_cast<spektrafilm::RenderOutputMode>(p.renderOutput);
  out.rgbToRawMethod = static_cast<spektrafilm::RgbToRawMethod>(p.rgbToRawMethod);
  out.inputColorSpace = static_cast<spektrafilm::ColorSpace>(p.inputColorSpace);
  out.outputColorSpace = static_cast<spektrafilm::ColorSpace>(p.outputColorSpace);
  out.outputRole = static_cast<spektrafilm::OutputRole>(p.outputRole);
  out.hdrPreset = static_cast<spektrafilm::HdrPreset>(p.hdrPreset);
  out.hdrTransfer = static_cast<spektrafilm::HdrTransfer>(p.hdrTransfer);
  out.hdrReferenceWhiteNits = p.hdrReferenceWhiteNits;
  out.hdrPeakNits = p.hdrPeakNits;
  out.hdrExposureEv = p.hdrExposureEv;
  out.hdrToneMapping = static_cast<spektrafilm::HdrToneMapping>(p.hdrToneMapping);
  out.colorAdaptation = p.colorAdaptation != 0;
  out.colorAdaptationInputCompression = p.colorAdaptationInputCompression != 0;
  out.colorAdaptationCurveSmoothing = p.colorAdaptationCurveSmoothing != 0;
  out.colorAdaptationOutputLightnessCompression = p.colorAdaptationOutputLightnessCompression != 0;
  out.colorAdaptationOutputChromaCompression = p.colorAdaptationOutputChromaCompression != 0;
  out.film = p.film;
  out.paper = p.paper;
  out.printTiming = static_cast<spektrafilm::PrintTimingMode>(p.printTiming);
  out.cameraUvFilterEnabled = p.cameraUvFilterEnabled != 0;
  out.cameraUvCutNm = p.cameraUvCutNm;
  out.cameraIrFilterEnabled = p.cameraIrFilterEnabled != 0;
  out.cameraIrCutNm = p.cameraIrCutNm;
  out.filmExposureEv = p.filmExposureEv;
  out.autoExposure = p.autoExposure != 0;
  out.autoExposureMethod = static_cast<spektrafilm::AutoExposureMethod>(p.autoExposureMethod);
  out.printExposureEv = p.printExposureEv;
  out.filmPushPullMode = static_cast<spektrafilm::PushPullMode>(p.filmPushPullMode);
  out.filmPushPullStops = p.filmPushPullStops;
  out.printPushPullStops = p.printPushPullStops;
  out.negativeBleachBypassAmount = p.negativeBleachBypassAmount;
  out.negativeLeucoCyanCoupling = p.negativeLeucoCyanCoupling;
  out.printBleachBypassAmount = p.printBleachBypassAmount;
  out.filmGamma = p.filmGamma;
  out.printGamma = p.printGamma;
  out.printShadowShape = p.printShadowShape;
  out.printHighlightShape = p.printHighlightShape;
  out.filterC = p.filterC;
  out.filterMShift = p.filterMShift;
  out.filterYShift = p.filterYShift;
  out.enlargerScale = p.enlargerScale;
  out.enlargerOffsetXPercent = p.enlargerOffsetXPercent;
  out.enlargerOffsetYPercent = p.enlargerOffsetYPercent;
  out.preflashExposure = p.preflashExposure;
  out.preflashMFilterShift = p.preflashMFilterShift;
  out.preflashYFilterShift = p.preflashYFilterShift;
  out.printerLightsR = p.printerLightsR;
  out.printerLightsG = p.printerLightsG;
  out.printerLightsB = p.printerLightsB;
  out.printerLightsGang = p.printerLightsGang != 0;
  out.printerLightCalibration = p.printerLightCalibration != 0;
  out.dirCouplersAmount = p.dirCouplersAmount;
  out.dirCouplersDiffusionUm = p.dirCouplersDiffusionUm;
  out.dirCouplersDiffusionTailUm = p.dirCouplersDiffusionTailUm;
  out.dirCouplersDiffusionTailWeight = p.dirCouplersDiffusionTailWeight;
  out.dirCouplersInhibitionSameLayer = p.dirCouplersInhibitionSameLayer;
  out.dirCouplersInhibitionInterlayer = p.dirCouplersInhibitionInterlayer;
  out.dirCouplersGammaSameLayerR = p.dirCouplersGammaSameLayerR;
  out.dirCouplersGammaSameLayerG = p.dirCouplersGammaSameLayerG;
  out.dirCouplersGammaSameLayerB = p.dirCouplersGammaSameLayerB;
  out.dirCouplersGammaRToG = p.dirCouplersGammaRToG;
  out.dirCouplersGammaRToB = p.dirCouplersGammaRToB;
  out.dirCouplersGammaGToR = p.dirCouplersGammaGToR;
  out.dirCouplersGammaGToB = p.dirCouplersGammaGToB;
  out.dirCouplersGammaBToR = p.dirCouplersGammaBToR;
  out.dirCouplersGammaBToG = p.dirCouplersGammaBToG;
  out.grainEnabled = p.grainEnabled != 0;
  out.grainModel = static_cast<spektrafilm::GrainModel>(p.grainModel);
  out.filmFormat = static_cast<spektrafilm::FilmFormat>(p.filmFormat);
  out.grainAmount = p.grainAmount;
  out.grainSaturation = p.grainSaturation;
  out.grainSublayersEnabled = p.grainSublayersEnabled != 0;
  out.grainSubLayerCount = p.grainSubLayerCount;
  out.grainParticleAreaUm2 = p.grainParticleAreaUm2;
  out.grainParticleScaleR = p.grainParticleScaleR;
  out.grainParticleScaleG = p.grainParticleScaleG;
  out.grainParticleScaleB = p.grainParticleScaleB;
  out.grainParticleScaleLayer0 = p.grainParticleScaleLayer0;
  out.grainParticleScaleLayer1 = p.grainParticleScaleLayer1;
  out.grainParticleScaleLayer2 = p.grainParticleScaleLayer2;
  out.grainDensityMinR = p.grainDensityMinR;
  out.grainDensityMinG = p.grainDensityMinG;
  out.grainDensityMinB = p.grainDensityMinB;
  out.grainUniformityR = p.grainUniformityR;
  out.grainUniformityG = p.grainUniformityG;
  out.grainUniformityB = p.grainUniformityB;
  out.grainFinalBlurUm = p.grainFinalBlurUm;
  out.grainBlurDyeCloudsUm = p.grainBlurDyeCloudsUm;
  out.grainMicroStructureScale = p.grainMicroStructureScale;
  out.grainMicroStructureSigmaNm = p.grainMicroStructureSigmaNm;
  out.grainSeed = p.grainSeed;
  out.grainAnimate = p.grainAnimate != 0;
  out.grainSynthesisSize = p.grainSynthesisSize;
  out.grainSynthesisAmount = p.grainSynthesisAmount;
  out.grainSynthesisSharpness = p.grainSynthesisSharpness;
  out.grainSynthesisQuality = p.grainSynthesisQuality;
  out.grainSynthesisSamples = p.grainSynthesisSamples;
  out.grainSynthesisMeanRadiusUm = p.grainSynthesisMeanRadiusUm;
  out.grainSynthesisRadiusStdDevRatio = p.grainSynthesisRadiusStdDevRatio;
  out.grainSynthesisObservationSigmaUm = p.grainSynthesisObservationSigmaUm;
  out.grainSynthesisCellSizeRatio = p.grainSynthesisCellSizeRatio;
  out.grainSynthesisMaxRadiusQuantile = p.grainSynthesisMaxRadiusQuantile;
  out.grainSynthesisCoverageEpsilon = p.grainSynthesisCoverageEpsilon;
  out.grainSynthesisMaxGrainsPerCell = p.grainSynthesisMaxGrainsPerCell;
  out.grainSynthesisRadiusScaleR = p.grainSynthesisRadiusScaleR;
  out.grainSynthesisRadiusScaleG = p.grainSynthesisRadiusScaleG;
  out.grainSynthesisRadiusScaleB = p.grainSynthesisRadiusScaleB;
  out.grainSynthesisLayerScale0 = p.grainSynthesisLayerScale0;
  out.grainSynthesisLayerScale1 = p.grainSynthesisLayerScale1;
  out.grainSynthesisLayerScale2 = p.grainSynthesisLayerScale2;
  out.grainSynthesisLayered = p.grainSynthesisLayered != 0;
  out.halationEnabled = p.halationEnabled != 0;
  out.scatterAmount = p.scatterAmount;
  out.scatterScale = p.scatterScale;
  out.halationAmount = p.halationAmount;
  out.halationScale = p.halationScale;
  out.halationStrengthR = p.halationStrengthR;
  out.halationStrengthG = p.halationStrengthG;
  out.halationStrengthB = p.halationStrengthB;
  out.halationFirstSigmaUmR = p.halationFirstSigmaUmR;
  out.halationFirstSigmaUmG = p.halationFirstSigmaUmG;
  out.halationFirstSigmaUmB = p.halationFirstSigmaUmB;
  out.halationBoostEv = p.halationBoostEv;
  out.halationBoostRange = p.halationBoostRange;
  out.halationProtectEv = p.halationProtectEv;
  out.cameraDiffusionEnabled = p.cameraDiffusionEnabled != 0;
  out.cameraDiffusionFamily = static_cast<spektrafilm::DiffusionFilterFamily>(p.cameraDiffusionFamily);
  out.cameraDiffusionStrength = p.cameraDiffusionStrength;
  out.cameraDiffusionSpatialScale = p.cameraDiffusionSpatialScale;
  out.cameraDiffusionHaloWarmth = p.cameraDiffusionHaloWarmth;
  out.cameraDiffusionCoreIntensity = p.cameraDiffusionCoreIntensity;
  out.cameraDiffusionCoreSize = p.cameraDiffusionCoreSize;
  out.cameraDiffusionHaloIntensity = p.cameraDiffusionHaloIntensity;
  out.cameraDiffusionHaloSize = p.cameraDiffusionHaloSize;
  out.cameraDiffusionBloomIntensity = p.cameraDiffusionBloomIntensity;
  out.cameraDiffusionBloomSize = p.cameraDiffusionBloomSize;
  out.printDiffusionEnabled = p.printDiffusionEnabled != 0;
  out.printDiffusionFamily = static_cast<spektrafilm::DiffusionFilterFamily>(p.printDiffusionFamily);
  out.printDiffusionStrength = p.printDiffusionStrength;
  out.printDiffusionSpatialScale = p.printDiffusionSpatialScale;
  out.printDiffusionHaloWarmth = p.printDiffusionHaloWarmth;
  out.printDiffusionCoreIntensity = p.printDiffusionCoreIntensity;
  out.printDiffusionCoreSize = p.printDiffusionCoreSize;
  out.printDiffusionHaloIntensity = p.printDiffusionHaloIntensity;
  out.printDiffusionHaloSize = p.printDiffusionHaloSize;
  out.printDiffusionBloomIntensity = p.printDiffusionBloomIntensity;
  out.printDiffusionBloomSize = p.printDiffusionBloomSize;
  out.scannerEnabled = p.scannerEnabled != 0;
  out.scannerWhiteCorrection = p.scannerWhiteCorrection != 0;
  out.scannerBlackCorrection = p.scannerBlackCorrection != 0;
  out.scannerWhiteLevel = p.scannerWhiteLevel;
  out.scannerBlackLevel = p.scannerBlackLevel;
  out.glarePercent = p.glarePercent;
  out.glareRoughness = p.glareRoughness;
  out.glareBlur = p.glareBlur;
  out.scannerMtf50LpMm = p.scannerMtf50LpMm;
  out.scannerUnsharpRadiusUm = p.scannerUnsharpRadiusUm;
  out.scannerUnsharpAmount = p.scannerUnsharpAmount;
  if (out.process == spektrafilm::ProcessMode::ProcessNegative) {
    out.rgbToRawMethod = spektrafilm::RgbToRawMethod::Hanatos2026;
    out.film = static_cast<int32_t>(spektrafilm::kSpektraDefaultFilmIndex);
    out.filmFormat = spektrafilm::FilmFormat::Standard35;
    out.cameraUvFilterEnabled = false;
    out.cameraIrFilterEnabled = false;
    out.filmExposureEv = 0.0f;
    out.autoExposure = false;
    out.filmPushPullMode = spektrafilm::PushPullMode::Standard;
    out.filmPushPullStops = 0.0f;
    out.negativeBleachBypassAmount = 0.0f;
    out.negativeLeucoCyanCoupling = 1.0f;
    out.filmGamma = 1.0f;
    out.enlargerScale = 1.0f;
    out.enlargerOffsetXPercent = 0.0f;
    out.enlargerOffsetYPercent = 0.0f;
    out.dirCouplersAmount = 0.0f;
    out.grainEnabled = false;
    out.halationEnabled = false;
    out.cameraDiffusionEnabled = false;
  }
  return out;
}

} // namespace

SpektraRendererRef SpektraRendererCreate(void) {
  auto *handle = new SpektraRendererHandle;
  handle->renderer = spektrafilm::createNativeRenderer();
  if (!handle->renderer) {
    handle->lastError = "Unable to create SpektraFilm renderer.";
  } else if (!handle->renderer->isAvailable()) {
    handle->lastError = handle->renderer->lastError();
  }
  return handle;
}

void SpektraRendererDestroy(SpektraRendererRef renderer) {
  delete renderer;
}

int32_t SpektraRendererIsAvailable(SpektraRendererRef renderer) {
  return renderer && renderer->renderer && renderer->renderer->isAvailable();
}

const char *SpektraRendererLastError(SpektraRendererRef renderer) {
  if (!renderer) {
    return "Renderer handle is null.";
  }
  if (renderer->renderer && !renderer->renderer->lastError().empty()) {
    return renderer->renderer->lastError().c_str();
  }
  return renderer->lastError.c_str();
}

SpektraAppDiagnostics SpektraRendererLastDiagnostics(SpektraRendererRef renderer) {
  SpektraAppDiagnostics out{};
  if (!renderer || !renderer->renderer) {
    return out;
  }
  const spektrafilm::RendererDiagnostics &diagnostics = renderer->renderer->lastDiagnostics();
  out.cpuSetupMs = diagnostics.cpuSetupMs;
  out.sourceCopyMs = diagnostics.sourceCopyMs;
  out.commandBufferMs = diagnostics.commandBufferMs;
  out.outputCopyMs = diagnostics.outputCopyMs;
  out.staticAllocationBytes = diagnostics.staticAllocationBytes;
  out.scratchAllocationBytes = diagnostics.scratchAllocationBytes;
  out.uploadBytes = diagnostics.uploadBytes;
  out.passCount = diagnostics.passCount;
  out.sourceNoCopy = diagnostics.sourceNoCopy;
  out.destinationNoCopy = diagnostics.destinationNoCopy;
  out.halationPath = diagnostics.halationPath;
  out.cameraDiffusionPath = diagnostics.cameraDiffusionPath;
  out.printDiffusionPath = diagnostics.printDiffusionPath;
  out.dirPath = diagnostics.dirPath;
  out.productionGrainPath = diagnostics.productionGrainPath;
  out.grainSynthesisPath = diagnostics.grainSynthesisPath;
  out.finalPostProcessPath = diagnostics.finalPostProcessPath;
  return out;
}

int32_t SpektraRendererRender(
  SpektraRendererRef renderer,
  const SpektraImageBuffer *source,
  SpektraImageBuffer *destination,
  const SpektraAppRenderParams *params,
  double time
) {
  if (!renderer || !renderer->renderer || !source || !destination || !params) {
    if (renderer) {
      renderer->lastError = "Render called with a null argument.";
    }
    return 0;
  }
  spektrafilm::ImageView sourceView{};
  sourceView.data = source->data;
  sourceView.width = source->width;
  sourceView.height = source->height;
  sourceView.rowBytes = source->rowBytes;
  sourceView.components = source->components;
  sourceView.bytesPerComponent = source->bytesPerComponent;

  spektrafilm::MutableImageView destinationView{};
  destinationView.data = destination->data;
  destinationView.width = destination->width;
  destinationView.height = destination->height;
  destinationView.rowBytes = destination->rowBytes;
  destinationView.components = destination->components;
  destinationView.bytesPerComponent = destination->bytesPerComponent;

  spektrafilm::RenderWindow window{};
  window.x1 = 0;
  window.y1 = 0;
  window.x2 = std::min(source->width, destination->width);
  window.y2 = std::min(source->height, destination->height);
  const spektrafilm::RenderParams nativeParams = toRendererParams(*params);
  const bool ok = renderer->renderer->render(sourceView, destinationView, window, nativeParams, time);
  if (!ok) {
    renderer->lastError = renderer->renderer->lastError();
  }
  return ok ? 1 : 0;
}

SpektraAppRenderParams SpektraAppMakeDefaultRenderParams(void) {
  SpektraAppRenderParams p{};
  p.process = static_cast<int32_t>(spektrafilm::ProcessMode::PrintSimulation);
  p.renderOutput = static_cast<int32_t>(spektrafilm::RenderOutputMode::FinalPreview);
  p.rgbToRawMethod = static_cast<int32_t>(spektrafilm::RgbToRawMethod::Hanatos2026);
  p.inputColorSpace = static_cast<int32_t>(spektrafilm::ColorSpace::LinearRec2020);
  p.outputColorSpace = static_cast<int32_t>(spektrafilm::ColorSpace::Rec709Gamma24);
  p.outputRole = static_cast<int32_t>(spektrafilm::OutputRole::DisplaySdr);
  p.hdrPreset = static_cast<int32_t>(spektrafilm::HdrPreset::Pq1000);
  p.hdrTransfer = static_cast<int32_t>(spektrafilm::HdrTransfer::Pq);
  p.hdrReferenceWhiteNits = 203.0f;
  p.hdrPeakNits = 1000.0f;
  p.hdrToneMapping = static_cast<int32_t>(spektrafilm::HdrToneMapping::HardClip);
  p.colorAdaptation = 0;
  p.colorAdaptationInputCompression = 1;
  p.colorAdaptationCurveSmoothing = 1;
  p.colorAdaptationOutputLightnessCompression = 1;
  p.colorAdaptationOutputChromaCompression = 1;
  p.film = static_cast<int32_t>(spektrafilm::kSpektraDefaultFilmIndex);
  p.paper = static_cast<int32_t>(spektrafilm::kSpektraDefaultPaperIndex);
  p.printTiming = static_cast<int32_t>(spektrafilm::PrintTimingMode::FilteredEnlarger);
  p.cameraUvCutNm = 410.0f;
  p.cameraIrCutNm = 675.0f;
  p.autoExposureMethod = static_cast<int32_t>(spektrafilm::AutoExposureMethod::CenterWeighted);
  p.filmPushPullMode = static_cast<int32_t>(spektrafilm::PushPullMode::Standard);
  p.negativeLeucoCyanCoupling = 1.0f;
  p.filmGamma = 1.0f;
  p.printGamma = 1.0f;
  p.enlargerScale = 1.0f;
  p.printerLightCalibration = 1;
  p.dirCouplersAmount = 1.0f;
  p.dirCouplersDiffusionUm = 20.0f;
  p.dirCouplersDiffusionTailUm = 200.0f;
  p.dirCouplersDiffusionTailWeight = 0.06f;
  p.dirCouplersInhibitionSameLayer = 1.0f;
  p.dirCouplersInhibitionInterlayer = 1.0f;
  p.dirCouplersGammaSameLayerR = 0.336f;
  p.dirCouplersGammaSameLayerG = 0.319f;
  p.dirCouplersGammaSameLayerB = 0.273f;
  p.dirCouplersGammaRToG = 0.353f;
  p.dirCouplersGammaRToB = 0.302f;
  p.dirCouplersGammaGToR = 0.154f;
  p.dirCouplersGammaGToB = 0.353f;
  p.dirCouplersGammaBToR = 0.168f;
  p.dirCouplersGammaBToG = 0.226f;
  p.grainModel = static_cast<int32_t>(spektrafilm::GrainModel::Preview);
  p.filmFormat = static_cast<int32_t>(spektrafilm::FilmFormat::Standard35);
  p.grainAmount = 1.0f;
  p.grainSaturation = 1.0f;
  p.grainSublayersEnabled = 1;
  p.grainSubLayerCount = 1;
  p.grainParticleAreaUm2 = 0.1f;
  p.grainParticleScaleR = 1.2f;
  p.grainParticleScaleG = 1.0f;
  p.grainParticleScaleB = 2.5f;
  p.grainParticleScaleLayer0 = 6.0f;
  p.grainParticleScaleLayer1 = 1.0f;
  p.grainParticleScaleLayer2 = 0.4f;
  p.grainDensityMinR = 0.04f;
  p.grainDensityMinG = 0.05f;
  p.grainDensityMinB = 0.06f;
  p.grainUniformityR = 0.99f;
  p.grainUniformityG = 0.97f;
  p.grainUniformityB = 0.98f;
  p.grainFinalBlurUm = 7.17f;
  p.grainBlurDyeCloudsUm = 1.0f;
  p.grainMicroStructureScale = 0.2f;
  p.grainMicroStructureSigmaNm = 30.0f;
  p.grainSeed = 1u;
  p.grainSynthesisSize = 1.0f;
  p.grainSynthesisAmount = 1.0f;
  p.grainSynthesisSharpness = 1.0f;
  p.grainSynthesisQuality = 1.0f;
  p.grainSynthesisSamples = 128;
  p.grainSynthesisMeanRadiusUm = 0.25f;
  p.grainSynthesisObservationSigmaUm = 1.0f;
  p.grainSynthesisCellSizeRatio = 1.0f;
  p.grainSynthesisMaxRadiusQuantile = 0.999f;
  p.grainSynthesisCoverageEpsilon = 0.0001f;
  p.grainSynthesisMaxGrainsPerCell = 32;
  p.grainSynthesisRadiusScaleR = 1.2f;
  p.grainSynthesisRadiusScaleG = 1.0f;
  p.grainSynthesisRadiusScaleB = 2.5f;
  p.grainSynthesisLayerScale0 = 6.0f;
  p.grainSynthesisLayerScale1 = 1.0f;
  p.grainSynthesisLayerScale2 = 0.4f;
  p.grainSynthesisLayered = 1;
  p.scatterAmount = 1.0f;
  p.scatterScale = 1.0f;
  p.halationAmount = 1.0f;
  p.halationScale = 1.0f;
  p.halationStrengthR = 0.05f;
  p.halationStrengthG = 0.015f;
  p.halationFirstSigmaUmR = 65.0f;
  p.halationFirstSigmaUmG = 65.0f;
  p.halationFirstSigmaUmB = 65.0f;
  p.halationBoostRange = 0.3f;
  p.halationProtectEv = 4.0f;
  p.cameraDiffusionFamily = static_cast<int32_t>(spektrafilm::DiffusionFilterFamily::BlackProMist);
  p.cameraDiffusionStrength = 0.5f;
  p.cameraDiffusionSpatialScale = 1.0f;
  p.cameraDiffusionCoreIntensity = 1.0f;
  p.cameraDiffusionCoreSize = 1.0f;
  p.cameraDiffusionHaloIntensity = 1.0f;
  p.cameraDiffusionHaloSize = 1.0f;
  p.cameraDiffusionBloomIntensity = 1.0f;
  p.cameraDiffusionBloomSize = 1.0f;
  p.printDiffusionFamily = static_cast<int32_t>(spektrafilm::DiffusionFilterFamily::BlackProMist);
  p.printDiffusionStrength = 0.5f;
  p.printDiffusionSpatialScale = 1.0f;
  p.printDiffusionCoreIntensity = 1.0f;
  p.printDiffusionCoreSize = 1.0f;
  p.printDiffusionHaloIntensity = 1.0f;
  p.printDiffusionHaloSize = 1.0f;
  p.printDiffusionBloomIntensity = 1.0f;
  p.printDiffusionBloomSize = 1.0f;
  p.scannerWhiteLevel = 0.98f;
  p.scannerBlackLevel = 0.01f;
  p.glarePercent = 0.03f;
  p.glareRoughness = 0.7f;
  p.glareBlur = 0.5f;
  p.scannerMtf50LpMm = 60.0f;
  p.scannerUnsharpRadiusUm = 5.0f;
  p.scannerUnsharpAmount = 0.7f;
  return p;
}

int32_t SpektraAppSetIntParam(SpektraAppRenderParams *p, const char *name, int32_t value) {
  if (!p || !name) return 0;
  if (sameName(name, "process")) p->process = value;
  else if (sameName(name, "renderOutput")) p->renderOutput = value;
  else if (sameName(name, "rgbToRawMethod")) p->rgbToRawMethod = value;
  else if (sameName(name, "inputColorSpace")) p->inputColorSpace = value;
  else if (sameName(name, "outputColorSpace")) p->outputColorSpace = value;
  else if (sameName(name, "outputRole")) p->outputRole = value;
  else if (sameName(name, "hdrPreset")) p->hdrPreset = value;
  else if (sameName(name, "hdrTransfer")) p->hdrTransfer = value;
  else if (sameName(name, "hdrToneMapping")) p->hdrToneMapping = value;
  else if (sameName(name, "film")) p->film = value;
  else if (sameName(name, "paper")) p->paper = value;
  else if (sameName(name, "printTiming")) p->printTiming = value;
  else if (sameName(name, "autoExposureMethod")) p->autoExposureMethod = value;
  else if (sameName(name, "filmPushPullMode")) p->filmPushPullMode = value;
  else if (sameName(name, "grainModel")) p->grainModel = value;
  else if (sameName(name, "filmFormat")) p->filmFormat = value;
  else if (sameName(name, "grainSubLayerCount")) p->grainSubLayerCount = value;
  else if (sameName(name, "grainSeed")) p->grainSeed = static_cast<uint32_t>(std::max(value, 0));
  else if (sameName(name, "grainSynthesisSamples")) p->grainSynthesisSamples = value;
  else if (sameName(name, "grainSynthesisMaxGrainsPerCell")) p->grainSynthesisMaxGrainsPerCell = value;
  else if (sameName(name, "cameraDiffusionFamily")) p->cameraDiffusionFamily = value;
  else if (sameName(name, "printDiffusionFamily")) p->printDiffusionFamily = value;
  else return SpektraAppSetBoolParam(p, name, value);
  return 1;
}

int32_t SpektraAppSetBoolParam(SpektraAppRenderParams *p, const char *name, int32_t value) {
  if (!p || !name) return 0;
  const int32_t flag = value ? 1 : 0;
  if (sameName(name, "cameraUvFilterEnabled")) p->cameraUvFilterEnabled = flag;
  else if (sameName(name, "scanNegativeInvert")) p->scanNegativeInvert = flag;
  else if (sameName(name, "colorAdaptation")) p->colorAdaptation = flag;
  else if (sameName(name, "colorAdaptationInputCompression")) p->colorAdaptationInputCompression = flag;
  else if (sameName(name, "colorAdaptationCurveSmoothing")) p->colorAdaptationCurveSmoothing = flag;
  else if (sameName(name, "colorAdaptationOutputLightnessCompression")) p->colorAdaptationOutputLightnessCompression = flag;
  else if (sameName(name, "colorAdaptationOutputChromaCompression")) p->colorAdaptationOutputChromaCompression = flag;
  else if (sameName(name, "cameraIrFilterEnabled")) p->cameraIrFilterEnabled = flag;
  else if (sameName(name, "autoExposure")) p->autoExposure = flag;
  else if (sameName(name, "printerLightsGang")) p->printerLightsGang = flag;
  else if (sameName(name, "printerLightCalibration")) p->printerLightCalibration = flag;
  else if (sameName(name, "grainEnabled")) p->grainEnabled = flag;
  else if (sameName(name, "grainSublayersEnabled")) p->grainSublayersEnabled = flag;
  else if (sameName(name, "grainAnimate")) p->grainAnimate = flag;
  else if (sameName(name, "grainSynthesisLayered")) p->grainSynthesisLayered = flag;
  else if (sameName(name, "halationEnabled")) p->halationEnabled = flag;
  else if (sameName(name, "cameraDiffusionEnabled")) p->cameraDiffusionEnabled = flag;
  else if (sameName(name, "printDiffusionEnabled")) p->printDiffusionEnabled = flag;
  else if (sameName(name, "scannerEnabled")) p->scannerEnabled = flag;
  else if (sameName(name, "scannerWhiteCorrection")) p->scannerWhiteCorrection = flag;
  else if (sameName(name, "scannerBlackCorrection")) p->scannerBlackCorrection = flag;
  else return 0;
  return 1;
}

int32_t SpektraAppSetDoubleParam(SpektraAppRenderParams *p, const char *name, double value) {
  if (!p || !name) return 0;
  const float v = static_cast<float>(value);
  if (sameName(name, "hdrReferenceWhiteNits")) p->hdrReferenceWhiteNits = v;
  else if (sameName(name, "hdrPeakNits")) p->hdrPeakNits = v;
  else if (sameName(name, "hdrExposureEv")) p->hdrExposureEv = v;
  else if (sameName(name, "cameraUvCutNm")) p->cameraUvCutNm = v;
  else if (sameName(name, "cameraIrCutNm")) p->cameraIrCutNm = v;
  else if (sameName(name, "filmExposureEv")) p->filmExposureEv = v;
  else if (sameName(name, "printExposureEv")) p->printExposureEv = v;
  else if (sameName(name, "filmPushPullStops")) p->filmPushPullStops = v;
  else if (sameName(name, "printPushPullStops")) p->printPushPullStops = v;
  else if (sameName(name, "negativeBleachBypassAmount")) p->negativeBleachBypassAmount = v;
  else if (sameName(name, "negativeLeucoCyanCoupling")) p->negativeLeucoCyanCoupling = v;
  else if (sameName(name, "printBleachBypassAmount")) p->printBleachBypassAmount = v;
  else if (sameName(name, "filmGamma")) p->filmGamma = v;
  else if (sameName(name, "printGamma")) p->printGamma = v;
  else if (sameName(name, "printShadowShape")) p->printShadowShape = v;
  else if (sameName(name, "printHighlightShape")) p->printHighlightShape = v;
  else if (sameName(name, "filterC")) p->filterC = v;
  else if (sameName(name, "filterMShift")) p->filterMShift = v;
  else if (sameName(name, "filterYShift")) p->filterYShift = v;
  else if (sameName(name, "enlargerScale")) p->enlargerScale = v;
  else if (sameName(name, "enlargerOffsetXPercent")) p->enlargerOffsetXPercent = v;
  else if (sameName(name, "enlargerOffsetYPercent")) p->enlargerOffsetYPercent = v;
  else if (sameName(name, "preflashExposure")) p->preflashExposure = v;
  else if (sameName(name, "preflashMFilterShift")) p->preflashMFilterShift = v;
  else if (sameName(name, "preflashYFilterShift")) p->preflashYFilterShift = v;
  else if (sameName(name, "printerLightR")) p->printerLightsR = v;
  else if (sameName(name, "printerLightG")) p->printerLightsG = v;
  else if (sameName(name, "printerLightB")) p->printerLightsB = v;
  else if (sameName(name, "dirCouplersAmount")) p->dirCouplersAmount = v;
  else if (sameName(name, "dirCouplersDiffusionUm")) p->dirCouplersDiffusionUm = v;
  else if (sameName(name, "dirCouplersDiffusionTailUm")) p->dirCouplersDiffusionTailUm = v;
  else if (sameName(name, "dirCouplersDiffusionTailWeight")) p->dirCouplersDiffusionTailWeight = v;
  else if (sameName(name, "dirCouplersInhibitionSameLayer")) p->dirCouplersInhibitionSameLayer = v;
  else if (sameName(name, "dirCouplersInhibitionInterlayer")) p->dirCouplersInhibitionInterlayer = v;
  else if (sameName(name, "grainAmount")) p->grainAmount = v;
  else if (sameName(name, "grainSaturation")) p->grainSaturation = v;
  else if (sameName(name, "grainParticleAreaUm2")) p->grainParticleAreaUm2 = v;
  else if (sameName(name, "grainFinalBlurUm")) p->grainFinalBlurUm = v;
  else if (sameName(name, "grainBlurDyeCloudsUm")) p->grainBlurDyeCloudsUm = v;
  else if (sameName(name, "grainSynthesisSize")) p->grainSynthesisSize = v;
  else if (sameName(name, "grainSynthesisAmount")) p->grainSynthesisAmount = v;
  else if (sameName(name, "grainSynthesisSharpness")) p->grainSynthesisSharpness = v;
  else if (sameName(name, "grainSynthesisQuality")) p->grainSynthesisQuality = v;
  else if (sameName(name, "grainSynthesisMeanRadiusUm")) p->grainSynthesisMeanRadiusUm = v;
  else if (sameName(name, "grainSynthesisRadiusStdDevRatio")) p->grainSynthesisRadiusStdDevRatio = v;
  else if (sameName(name, "grainSynthesisObservationSigmaUm")) p->grainSynthesisObservationSigmaUm = v;
  else if (sameName(name, "grainSynthesisCellSizeRatio")) p->grainSynthesisCellSizeRatio = v;
  else if (sameName(name, "grainSynthesisMaxRadiusQuantile")) p->grainSynthesisMaxRadiusQuantile = v;
  else if (sameName(name, "grainSynthesisCoverageEpsilon")) p->grainSynthesisCoverageEpsilon = v;
  else if (sameName(name, "scatterAmount")) p->scatterAmount = v;
  else if (sameName(name, "scatterScale")) p->scatterScale = v;
  else if (sameName(name, "halationAmount")) p->halationAmount = v;
  else if (sameName(name, "halationScale")) p->halationScale = v;
  else if (sameName(name, "halationBoostEv")) p->halationBoostEv = v;
  else if (sameName(name, "halationBoostRange")) p->halationBoostRange = v;
  else if (sameName(name, "halationProtectEv")) p->halationProtectEv = v;
  else if (sameName(name, "cameraDiffusionStrength")) p->cameraDiffusionStrength = v;
  else if (sameName(name, "cameraDiffusionSpatialScale")) p->cameraDiffusionSpatialScale = v;
  else if (sameName(name, "cameraDiffusionHaloWarmth")) p->cameraDiffusionHaloWarmth = v;
  else if (sameName(name, "cameraDiffusionCoreIntensity")) p->cameraDiffusionCoreIntensity = v;
  else if (sameName(name, "cameraDiffusionCoreSize")) p->cameraDiffusionCoreSize = v;
  else if (sameName(name, "cameraDiffusionHaloIntensity")) p->cameraDiffusionHaloIntensity = v;
  else if (sameName(name, "cameraDiffusionHaloSize")) p->cameraDiffusionHaloSize = v;
  else if (sameName(name, "cameraDiffusionBloomIntensity")) p->cameraDiffusionBloomIntensity = v;
  else if (sameName(name, "cameraDiffusionBloomSize")) p->cameraDiffusionBloomSize = v;
  else if (sameName(name, "printDiffusionStrength")) p->printDiffusionStrength = v;
  else if (sameName(name, "printDiffusionSpatialScale")) p->printDiffusionSpatialScale = v;
  else if (sameName(name, "printDiffusionHaloWarmth")) p->printDiffusionHaloWarmth = v;
  else if (sameName(name, "printDiffusionCoreIntensity")) p->printDiffusionCoreIntensity = v;
  else if (sameName(name, "printDiffusionCoreSize")) p->printDiffusionCoreSize = v;
  else if (sameName(name, "printDiffusionHaloIntensity")) p->printDiffusionHaloIntensity = v;
  else if (sameName(name, "printDiffusionHaloSize")) p->printDiffusionHaloSize = v;
  else if (sameName(name, "printDiffusionBloomIntensity")) p->printDiffusionBloomIntensity = v;
  else if (sameName(name, "printDiffusionBloomSize")) p->printDiffusionBloomSize = v;
  else if (sameName(name, "scannerWhiteLevel")) p->scannerWhiteLevel = v;
  else if (sameName(name, "scannerBlackLevel")) p->scannerBlackLevel = v;
  else if (sameName(name, "glarePercent")) p->glarePercent = v;
  else if (sameName(name, "glareRoughness")) p->glareRoughness = v;
  else if (sameName(name, "glareBlur")) p->glareBlur = v;
  else if (sameName(name, "scannerMtf50LpMm")) p->scannerMtf50LpMm = v;
  else if (sameName(name, "scannerUnsharpRadiusUm")) p->scannerUnsharpRadiusUm = v;
  else if (sameName(name, "scannerUnsharpAmount")) p->scannerUnsharpAmount = v;
  else return 0;
  return 1;
}

int32_t SpektraAppSetDouble3Param(SpektraAppRenderParams *p, const char *name, double x, double y, double z) {
  if (!p || !name) return 0;
  if (sameName(name, "dirGammaSameLayerRgb")) {
    p->dirCouplersGammaSameLayerR = static_cast<float>(x);
    p->dirCouplersGammaSameLayerG = static_cast<float>(y);
    p->dirCouplersGammaSameLayerB = static_cast<float>(z);
  } else if (sameName(name, "dirGammaRToGb")) {
    p->dirCouplersGammaRToG = static_cast<float>(x);
    p->dirCouplersGammaRToB = static_cast<float>(y);
  } else if (sameName(name, "dirGammaGToRb")) {
    p->dirCouplersGammaGToR = static_cast<float>(x);
    p->dirCouplersGammaGToB = static_cast<float>(y);
  } else if (sameName(name, "dirGammaBToRg")) {
    p->dirCouplersGammaBToR = static_cast<float>(x);
    p->dirCouplersGammaBToG = static_cast<float>(y);
  } else if (sameName(name, "grainParticleScale")) {
    p->grainParticleScaleR = static_cast<float>(x);
    p->grainParticleScaleG = static_cast<float>(y);
    p->grainParticleScaleB = static_cast<float>(z);
  } else if (sameName(name, "grainParticleScaleLayers")) {
    p->grainParticleScaleLayer0 = static_cast<float>(x);
    p->grainParticleScaleLayer1 = static_cast<float>(y);
    p->grainParticleScaleLayer2 = static_cast<float>(z);
  } else if (sameName(name, "grainDensityMin")) {
    p->grainDensityMinR = static_cast<float>(x);
    p->grainDensityMinG = static_cast<float>(y);
    p->grainDensityMinB = static_cast<float>(z);
  } else if (sameName(name, "grainUniformity")) {
    p->grainUniformityR = static_cast<float>(x);
    p->grainUniformityG = static_cast<float>(y);
    p->grainUniformityB = static_cast<float>(z);
  } else if (sameName(name, "grainMicroStructure")) {
    p->grainMicroStructureScale = static_cast<float>(x);
    p->grainMicroStructureSigmaNm = static_cast<float>(y);
  } else if (sameName(name, "grainSynthesisRadiusScale")) {
    p->grainSynthesisRadiusScaleR = static_cast<float>(x);
    p->grainSynthesisRadiusScaleG = static_cast<float>(y);
    p->grainSynthesisRadiusScaleB = static_cast<float>(z);
  } else if (sameName(name, "grainSynthesisLayerScale")) {
    p->grainSynthesisLayerScale0 = static_cast<float>(x);
    p->grainSynthesisLayerScale1 = static_cast<float>(y);
    p->grainSynthesisLayerScale2 = static_cast<float>(z);
  } else if (sameName(name, "halationStrength")) {
    p->halationStrengthR = static_cast<float>(x);
    p->halationStrengthG = static_cast<float>(y);
    p->halationStrengthB = static_cast<float>(z);
  } else {
    return 0;
  }
  return 1;
}

uint32_t SpektraAppGroupCount(void) {
  return static_cast<uint32_t>(sizeof(kGroups) / sizeof(kGroups[0]));
}

const SpektraAppGroupDescriptor *SpektraAppGroupAt(uint32_t index) {
  return index < SpektraAppGroupCount() ? &kGroups[index] : nullptr;
}

uint32_t SpektraAppParamCount(void) {
  return static_cast<uint32_t>(sizeof(kParams) / sizeof(kParams[0]));
}

const SpektraAppParamDescriptor *SpektraAppParamAt(uint32_t index) {
  return index < SpektraAppParamCount() ? &kParams[index] : nullptr;
}

int32_t SpektraAppParamVisibleInFlavor(const SpektraAppParamDescriptor *descriptor, int32_t flavor) {
  if (!descriptor) return 0;
  if (flavor >= SpektraAppFlavorDev) return 1;
  if (flavor == SpektraAppFlavorPro) return descriptor->visibilityTier <= SpektraAppVisibilityTierPro;
  return descriptor->visibilityTier == SpektraAppVisibilityTierFlow;
}

uint32_t SpektraAppOptionCount(const char *optionSet) {
  if (!optionSet) return 0u;
  if (sameName(optionSet, "film")) return SpektraAppFilmCount();
  if (sameName(optionSet, "paper")) return SpektraAppPaperCount();
  uint32_t count = 0u;
  for (const ChoiceOption &option : kStaticOptions) {
    if (sameName(option.optionSet, optionSet)) ++count;
  }
  if (sameName(optionSet, "rawWhiteBalance")) return 3u;
  return count;
}

const char *SpektraAppOptionLabel(const char *optionSet, uint32_t index) {
  if (!optionSet) return "";
  if (sameName(optionSet, "film")) return SpektraAppFilmName(index);
  if (sameName(optionSet, "paper")) return SpektraAppPaperName(index);
  if (sameName(optionSet, "rawWhiteBalance")) {
    static constexpr const char *kRawWhiteBalance[] = {"As Shot", "Daylight", "Custom"};
    return index < 3u ? kRawWhiteBalance[index] : "";
  }
  uint32_t current = 0u;
  for (const ChoiceOption &option : kStaticOptions) {
    if (sameName(option.optionSet, optionSet)) {
      if (current == index) return option.label;
      ++current;
    }
  }
  return "";
}

int32_t SpektraAppLinearRec2020ColorSpace(void) {
  return static_cast<int32_t>(spektrafilm::ColorSpace::LinearRec2020);
}

int32_t SpektraAppLinearRec709ColorSpace(void) {
  return static_cast<int32_t>(spektrafilm::ColorSpace::LinearRec709);
}

int32_t SpektraAppLinearP3D65ColorSpace(void) {
  return static_cast<int32_t>(spektrafilm::ColorSpace::LinearP3D65);
}

int32_t SpektraAppSrgbColorSpace(void) {
  return static_cast<int32_t>(spektrafilm::ColorSpace::Srgb);
}

int32_t SpektraAppDisplayP3ColorSpace(void) {
  return static_cast<int32_t>(spektrafilm::ColorSpace::DisplayP3);
}

uint32_t SpektraAppFilmCount(void) {
  return spektrafilm::kSpektraFilmCount;
}

const char *SpektraAppFilmName(uint32_t index) {
  const spektrafilm::ProfileCurveSet *curves = spektrafilm::filmProfileCurves(static_cast<int32_t>(index));
  return curves && curves->stock ? curves->stock : "";
}

uint32_t SpektraAppPaperCount(void) {
  return spektrafilm::kSpektraPaperCount;
}

const char *SpektraAppPaperName(uint32_t index) {
  const spektrafilm::ProfileCurveSet *curves = spektrafilm::paperProfileCurves(static_cast<int32_t>(index));
  return curves && curves->stock ? curves->stock : "";
}
