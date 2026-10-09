// GPL-3.0. Helpers and exact exception kernel adapted from chaert-s/spektrafilm-ofx
// shaders/SpektraFilm.metal at 8f6651858f439a99b7202b4b8dea59e344dadf5d.
// Local adaptation adds a cached density-domain GPU export lookup.
#pragma once
static const char *kDensityLutMetalSource=R"SPEKTRALUT(
#include <metal_stdlib>
using namespace metal;

constant int kSpektraOutputRoleDisplayHdr = 1;
constant int kSpektraOutputRoleRcm = 2;
constant int kSpektraColorSpaceBmdFilmWideGamutGen5 = 2;
constant int kSpektraColorSpaceDavinciIntermediateWideGamut = 3;
constant int kSpektraColorSpaceAces2065_1 = 10;
constant int kSpektraColorSpaceAcesCg = 11;
constant int kSpektraColorSpaceAcesCct = 12;
constant int kSpektraColorSpaceAcesCc = 13;
constant int kSpektraColorSpaceLinearRec2020 = 14;
constant int kSpektraColorSpaceLinearRec709 = 15;
constant int kSpektraColorSpaceLinearP3D65 = 16;
constant int kSpektraColorSpaceSrgb = 17;
constant int kSpektraColorSpaceDisplayP3 = 18;
constant int kSpektraColorSpaceDciP3 = 21;
constant int kSpektraColorSpaceP3D65Gamma22 = 22;
constant int kSpektraColorSpaceP3D65Gamma26 = 23;
constant int kSpektraColorSpaceRec709Gamma22 = 24;
constant int kSpektraColorSpaceRec709Gamma24 = 25;
constant uint kSpektraColorAdaptationInputCompression = 1u << 0u;
constant uint kSpektraColorAdaptationCurveSmoothing = 1u << 1u;
constant uint kSpektraColorAdaptationOutputLightnessCompression = 1u << 2u;
constant uint kSpektraColorAdaptationOutputChromaCompression = 1u << 3u;

struct SpektraKernelParams {
  int process;
  int rgbToRawMethod;
  int inputColorSpace;
  int outputColorSpace;
  int outputRole;
  int hdrPreset;
  int hdrTransfer;
  float hdrReferenceWhiteNits;
  float hdrPeakNits;
  float hdrExposureEv;
  int hdrToneMapping;
  uint colorAdaptationFlags;
  int film;
  int paper;
  int printTiming;
  float filmExposureEv;
  uint autoExposureEnabled;
  int autoExposureMethod;
  float autoExposureEv;
  float _padAutoExposure0;
  float printExposureEv;
  float filmGamma;
  float printGamma;
  float printShadowShape;
  float printHighlightShape;
  int filmPushPullMode;
  float filmPushPullStops;
  int printPushPullMode;
  float printPushPullStops;
  float negativeBleachBypassAmount;
  float negativeLeucoCyanCoupling;
  float printBleachBypassAmount;
  uint scanNegativeInvert;
  float filterC;
  float filterMShift;
  float filterYShift;
  float enlargerScale;
  float enlargerOffsetXPercent;
  float enlargerOffsetYPercent;
  float _padEnlarger0;
  float preflashExposure;
  float preflashMFilterShift;
  float preflashYFilterShift;
  float printerLightsR;
  float printerLightsG;
  float printerLightsB;
  uint printerLightsGang;
  uint printerLightCalibration;
  float dirCouplersAmount;
  float dirCouplersDiffusionUm;
  float dirCouplersDiffusionTailUm;
  float dirCouplersDiffusionTailWeight;
  uint grainEnabled;
  int grainModel;
  int filmFormat;
  float grainAmount;
  float grainSaturation;
  uint grainSublayersEnabled;
  int grainSubLayerCount;
  float grainParticleAreaUm2;
  float grainParticleScaleR;
  float grainParticleScaleG;
  float grainParticleScaleB;
  float grainParticleScaleLayer0;
  float grainParticleScaleLayer1;
  float grainParticleScaleLayer2;
  float grainDensityMinR;
  float grainDensityMinG;
  float grainDensityMinB;
  float grainUniformityR;
  float grainUniformityG;
  float grainUniformityB;
  float grainFinalBlurUm;
  float grainBlurDyeCloudsUm;
  float grainMicroStructureScale;
  float grainMicroStructureSigmaNm;
  uint grainSeed;
  uint grainAnimate;
  float filmPixelSizeUm;
  float _padGrain0;
  int grainSynthesisSamples;
  float grainSynthesisAmount;
  float grainSynthesisMeanRadiusUm;
  float grainSynthesisRadiusStdDevRatio;
  float grainSynthesisObservationSigmaUm;
  float grainSynthesisCellSizeRatio;
  float grainSynthesisMaxRadiusQuantile;
  float grainSynthesisCoverageEpsilon;
  int grainSynthesisMaxGrainsPerCell;
  float grainSynthesisRadiusScaleR;
  float grainSynthesisRadiusScaleG;
  float grainSynthesisRadiusScaleB;
  float grainSynthesisLayerScale0;
  float grainSynthesisLayerScale1;
  float grainSynthesisLayerScale2;
  uint grainSynthesisLayered;
  uint _padGrainSynthesis0;
  uint halationEnabled;
  float scatterAmount;
  float scatterScale;
  float halationAmount;
  float halationScale;
  float halationStrengthR;
  float halationStrengthG;
  float halationStrengthB;
  float halationFirstSigmaUmR;
  float halationFirstSigmaUmG;
  float halationFirstSigmaUmB;
  float halationBoostEv;
  float halationBoostRange;
  float halationProtectEv;
  float _padHalation0;
  uint cameraDiffusionEnabled;
  int cameraDiffusionFamily;
  float cameraDiffusionStrength;
  float cameraDiffusionSpatialScale;
  float cameraDiffusionHaloWarmth;
  float cameraDiffusionCoreIntensity;
  float cameraDiffusionCoreSize;
  float cameraDiffusionHaloIntensity;
  float cameraDiffusionHaloSize;
  float cameraDiffusionBloomIntensity;
  float cameraDiffusionBloomSize;
  uint printDiffusionEnabled;
  int printDiffusionFamily;
  float printDiffusionStrength;
  float printDiffusionSpatialScale;
  float printDiffusionHaloWarmth;
  float printDiffusionCoreIntensity;
  float printDiffusionCoreSize;
  float printDiffusionHaloIntensity;
  float printDiffusionHaloSize;
  float printDiffusionBloomIntensity;
  float printDiffusionBloomSize;
  uint scannerEnabled;
  uint scannerWhiteCorrection;
  uint scannerBlackCorrection;
  float scannerWhiteLevel;
  float scannerBlackLevel;
  float glarePercent;
  float glareRoughness;
  float glareBlur;
  float scannerBlurSigmaPx;
  float scannerUnsharpSigmaPx;
  float scannerUnsharpAmount;
  uint densityCurveLookupMode;
  uint spectralTransmittanceMode;
  uint _padPerf0;
  float time;
};

static bool spektra_color_adaptation_enabled(constant SpektraKernelParams &params, uint flag) {
  return (params.colorAdaptationFlags & flag) != 0u;
}

constant uint kSpektraGrainSynthesisMaxSamples = 1024u;

struct SpektraGrainSynthesisComponentInfo {
  float scaledMeanRadius;
  float maxRadius;
  float maxRadiusSquared;
  float cellSize;
  float invCellSize;
  float meanArea;
  float cellArea;
  float densityToLambda;
  float logMean;
  float logSigma;
  uint grainCap;
  uint cellScanRadius;
  uint sampleCount;
  uint active;
  uint radiusLutOffset;
  uint radiusLutSize;
  uint cellOffsetStart;
  uint cellOffsetCount;
  uint samplerMode;
  uint _pad0;
};

struct SpektraCurveInfo {
  uint exposureCount;
  uint _pad0;
  uint _pad1;
  uint _pad2;
};

struct SpektraSpectralInfo {
  uint filmWavelengthCount;
  uint hanatosWidth;
  uint hanatosHeight;
  uint hanatosWavelengthCount;
  uint filmCount;
  uint paperCount;
  uint filmPositive;
  uint _padCount1;
  float mallettRawMidgrayGreen;
  float filmDensityCurveMinimum0;
  float filmDensityCurveMinimum1;
  float filmDensityCurveMinimum2;
  float filmDensityCurveMaximum0;
  float filmDensityCurveMaximum1;
  float filmDensityCurveMaximum2;
  float _padDensityCurveMaximum0;
  float paperDensityCurveMaximum0;
  float paperDensityCurveMaximum1;
  float paperDensityCurveMaximum2;
  float _padPaperDensityCurveMaximum0;
};

struct SpektraColorInfo {
  uint colorSpaceCount;
  uint transferLutSize;
  float decodeMin;
  float decodeMax;
  float encodeMin;
  float encodeMax;
  float _pad0;
  float _pad1;
};

struct SpektraDirInfo {
  float matrix00;
  float matrix01;
  float matrix02;
  float matrix10;
  float matrix11;
  float matrix12;
  float matrix20;
  float matrix21;
  float matrix22;
  float densityMax0;
  float densityMax1;
  float densityMax2;
};

struct SpektraDiffusionInfo {
  uint componentCount;
  float scatterFraction;
  uint _pad0;
  uint _pad1;
};

struct SpektraDiffusionComponent {
  float sigmaPx;
  float weightR;
  float weightG;
  float weightB;
};

struct SpektraGaussianBlurInfo {
  float firstWeight;
  float firstRatio;
  float ratioStep;
  float invWeightSum;
  uint radius;
  uint active;
  uint _pad0;
  uint _pad1;
};

struct SpektraFrameConstants {
  float4 print; // x: exposure factor, y: reference black Y, z: reference white Y
  float4 film;  // x: reference black Y, y: reference white Y
  float4 glare; // rgb: print scan illuminant in output RGB
  float4 preflash; // rgb: constant paper raw preflash exposure
  float4 filmDmaxScan; // rgb: film D-max scan in output RGB, a: scan Y
  float4 filmDminScan; // rgb: clear-film scan in output RGB, a: scan Y
};

struct SpektraScanResult {
  float3 rgb;
  float y;
};





















static uint spektra_color_space_index(int colorSpace, constant SpektraColorInfo &colorInfo) {
  if (colorSpace < 0 || colorSpace >= int(colorInfo.colorSpaceCount)) {
    return 0u;
  }
  return uint(colorSpace);
}

static bool spektra_rcm_enabled(constant SpektraKernelParams &params) {
  return params.outputRole == kSpektraOutputRoleRcm;
}

static uint spektra_final_output_color_space(constant SpektraKernelParams &params, constant SpektraColorInfo &colorInfo) {
  constexpr int kLinearRec2020ColorSpace = 14;
  if (params.outputRole == kSpektraOutputRoleDisplayHdr) {
    return spektra_color_space_index(kLinearRec2020ColorSpace, colorInfo);
  }
  return spektra_color_space_index(params.outputColorSpace, colorInfo);
}



static float spektra_sample_lut_range(
  float value,
  uint colorSpace,
  float minimum,
  float maximum,
  constant SpektraColorInfo &colorInfo,
  device const float *luts
) {
  const uint lutSize = colorInfo.transferLutSize;
  if (lutSize <= 1u) {
    return value;
  }
  const float range = max(maximum - minimum, 1.0e-6);
  const float step = range / float(lutSize - 1u);
  const uint offset = colorSpace * lutSize;
  if (value <= minimum) {
    const float y0 = luts[offset];
    const float y1 = luts[offset + 1u];
    return y0 + (value - minimum) * ((y1 - y0) / max(step, 1.0e-12));
  }
  if (value >= maximum) {
    const float y0 = luts[offset + lutSize - 2u];
    const float y1 = luts[offset + lutSize - 1u];
    return y1 + (value - maximum) * ((y1 - y0) / max(step, 1.0e-12));
  }
  const float t = (value - minimum) / range;
  const float position = t * float(lutSize - 1u);
  const uint lo = uint(floor(position));
  const uint hi = min(lo + 1u, lutSize - 1u);
  const float f = position - float(lo);
  return mix(luts[offset + lo], luts[offset + hi], f);
}

constant uint kSpektraTransferLinear = 0u;
constant uint kSpektraTransferSrgb = 2u;
constant uint kSpektraTransferGamma = 3u;
constant uint kSpektraTransferProPhoto = 4u;

static float spektra_signed_srgb_encode(float value) {
  const float x = abs(value);
  const float y = x <= 0.0031308
    ? 12.92 * x
    : 1.055 * pow(x, 1.0 / 2.4) - 0.055;
  return value < 0.0 ? -y : y;
}

static float spektra_signed_gamma_encode(float value, float gamma) {
  const float y = pow(abs(value), 1.0 / max(gamma, 1.0e-6));
  return value < 0.0 ? -y : y;
}

static float spektra_signed_prophoto_encode(float value) {
  const float x = abs(value);
  const float y = x < (1.0 / 512.0) ? 16.0 * x : pow(x, 1.0 / 1.8);
  return value < 0.0 ? -y : y;
}

static float3 spektra_signed_srgb_encode(float3 rgb) {
  return float3(
    spektra_signed_srgb_encode(rgb.r),
    spektra_signed_srgb_encode(rgb.g),
    spektra_signed_srgb_encode(rgb.b)
  );
}

static float3 spektra_signed_gamma_encode(float3 rgb, float gamma) {
  return float3(
    spektra_signed_gamma_encode(rgb.r, gamma),
    spektra_signed_gamma_encode(rgb.g, gamma),
    spektra_signed_gamma_encode(rgb.b, gamma)
  );
}

static float3 spektra_signed_prophoto_encode(float3 rgb) {
  return float3(
    spektra_signed_prophoto_encode(rgb.r),
    spektra_signed_prophoto_encode(rgb.g),
    spektra_signed_prophoto_encode(rgb.b)
  );
}

static float3 spektra_encode_output_rgb(
  float3 rgb,
  uint colorSpace,
  constant SpektraKernelParams &params,
  constant SpektraColorInfo &colorInfo,
  device const float *encodeLuts,
  device const uint *transferKinds,
  device const float *transferParams
) {
  (void)params;
  const uint transferKind = transferKinds[colorSpace];
  if (transferKind == kSpektraTransferLinear) {
    return rgb;
  }
  if (transferKind == kSpektraTransferSrgb) {
    return spektra_signed_srgb_encode(rgb);
  }
  if (transferKind == kSpektraTransferGamma) {
    return spektra_signed_gamma_encode(rgb, transferParams[colorSpace]);
  }
  if (transferKind == kSpektraTransferProPhoto) {
    return spektra_signed_prophoto_encode(rgb);
  }
  return float3(
    spektra_sample_lut_range(rgb.r, colorSpace, colorInfo.encodeMin, colorInfo.encodeMax, colorInfo, encodeLuts),
    spektra_sample_lut_range(rgb.g, colorSpace, colorInfo.encodeMin, colorInfo.encodeMax, colorInfo, encodeLuts),
    spektra_sample_lut_range(rgb.b, colorSpace, colorInfo.encodeMin, colorInfo.encodeMax, colorInfo, encodeLuts)
  );
}

static float3 spektra_encode_output_rgb(
  float3 rgb,
  constant SpektraKernelParams &params,
  constant SpektraColorInfo &colorInfo,
  device const float *encodeLuts,
  device const uint *transferKinds,
  device const float *transferParams
) {
  const uint colorSpace = spektra_color_space_index(params.outputColorSpace, colorInfo);
  return spektra_encode_output_rgb(rgb, colorSpace, params, colorInfo, encodeLuts, transferKinds, transferParams);
}

static float spektra_rec2020_luminance(float3 rgb) {
  return dot(rgb, float3(0.2627, 0.6780, 0.0593));
}

static bool spektra_rcm_inverse_ootf_enabled(uint colorSpace) {
  switch (int(colorSpace)) {
    case kSpektraColorSpaceBmdFilmWideGamutGen5:
    case kSpektraColorSpaceDavinciIntermediateWideGamut:
    case kSpektraColorSpaceAces2065_1:
    case kSpektraColorSpaceAcesCg:
    case kSpektraColorSpaceAcesCct:
    case kSpektraColorSpaceAcesCc:
    case kSpektraColorSpaceLinearRec2020:
    case kSpektraColorSpaceLinearRec709:
    case kSpektraColorSpaceLinearP3D65:
    case kSpektraColorSpaceSrgb:
    case kSpektraColorSpaceDisplayP3:
    case kSpektraColorSpaceDciP3:
    case kSpektraColorSpaceP3D65Gamma22:
    case kSpektraColorSpaceP3D65Gamma26:
    case kSpektraColorSpaceRec709Gamma22:
    case kSpektraColorSpaceRec709Gamma24:
      return true;
    default:
      return false;
  }
}

static float spektra_apply_inverse_rcm_ootf_channel(float value) {
  // Resolve CST inverse OOTF: inverse BT.1886 EOTF, then inverse BT.709 OETF.
  const float x = abs(value);
  const float signal = pow(x, 1.0 / 2.4);
  const float sceneLinear = signal < 0.081
    ? signal / 4.5
    : pow((signal + 0.099) / 1.099, 1.0 / 0.45);
  return value < 0.0 ? -sceneLinear : sceneLinear;
}

static float3 spektra_apply_inverse_rcm_ootf(float3 displayLinear) {
  return float3(
    spektra_apply_inverse_rcm_ootf_channel(displayLinear.r),
    spektra_apply_inverse_rcm_ootf_channel(displayLinear.g),
    spektra_apply_inverse_rcm_ootf_channel(displayLinear.b)
  );
}

static float3 spektra_hdr_apply_luminance_tone_map(float3 rgb, constant SpektraKernelParams &params) {
  const float referenceWhite = max(params.hdrReferenceWhiteNits, 1.0);
  const float peak = max(params.hdrPeakNits, referenceWhite + 1.0);
  float3 nits = rgb * (referenceWhite * exp2(params.hdrExposureEv));
  const float sourceY = spektra_rec2020_luminance(nits);
  if (!(sourceY > 1.0e-6) || !isfinite(sourceY)) {
    return float3(0.0);
  }
  float mappedY = sourceY;
  if (params.hdrToneMapping == 1) {
    mappedY = min(sourceY, peak);
  } else if (sourceY > referenceWhite) {
    const float shoulder = max(peak - referenceWhite, 1.0);
    mappedY = referenceWhite + shoulder * (1.0 - exp(-(sourceY - referenceWhite) / shoulder));
  }
  return nits * (mappedY / sourceY);
}

static float spektra_encode_pq(float nits) {
  constexpr float m1 = 2610.0 / 16384.0;
  constexpr float m2 = 2523.0 / 32.0;
  constexpr float c1 = 3424.0 / 4096.0;
  constexpr float c2 = 2413.0 / 128.0;
  constexpr float c3 = 2392.0 / 128.0;
  const float y = pow(max(nits, 0.0) / 10000.0, m1);
  return pow((c1 + c2 * y) / (1.0 + c3 * y), m2);
}

static float spektra_encode_hlg(float sceneLinear) {
  constexpr float a = 0.17883277;
  constexpr float b = 1.0 - 4.0 * a;
  constexpr float c = 0.55991073;
  const float e = max(sceneLinear, 0.0);
  return e <= (1.0 / 12.0) ? sqrt(3.0 * e) : a * log(12.0 * e - b) + c;
}

static float spektra_hlg_system_gamma(float peakNits) {
  return max(1.0 + 0.42 * log10(max(peakNits, 1.0) / 1000.0), 1.0e-6);
}

static float spektra_hlg_channel_to_signal(float nits, float peakNits, bool clampToPeak) {
  const float normalized = max(nits, 0.0) / peakNits;
  return clampToPeak ? clamp(normalized, 0.0, 1.0) : normalized;
}

static float3 spektra_hlg_display_nits_to_signal(float3 nits, float peakNits, bool clampToPeak) {
  const float gamma = spektra_hlg_system_gamma(peakNits);
  return float3(
    spektra_encode_hlg(pow(spektra_hlg_channel_to_signal(nits.r, peakNits, clampToPeak), 1.0 / gamma)),
    spektra_encode_hlg(pow(spektra_hlg_channel_to_signal(nits.g, peakNits, clampToPeak), 1.0 / gamma)),
    spektra_encode_hlg(pow(spektra_hlg_channel_to_signal(nits.b, peakNits, clampToPeak), 1.0 / gamma))
  );
}

constant uint kSpektraOutputGamutCompressionStride = 18u;

static float spektra_reinhard_knee(float value, float threshold, float limit, float power) {
  if (!isfinite(value) || value <= threshold) {
    return value;
  }
  const float scale = max(limit - threshold, 1.0e-12);
  const float x = (value - threshold) / scale;
  const float y = x / pow(1.0 + pow(x, power), 1.0 / power);
  return threshold + scale * y;
}

static float spektra_signed_cuberoot(float value) {
  return value < 0.0 ? -pow(-value, 1.0 / 3.0) : pow(value, 1.0 / 3.0);
}

static float3 spektra_mul_packed_matrix(device const float *data, uint offset, float3 value) {
  return float3(
    data[offset] * value.r + data[offset + 1u] * value.g + data[offset + 2u] * value.b,
    data[offset + 3u] * value.r + data[offset + 4u] * value.g + data[offset + 5u] * value.b,
    data[offset + 6u] * value.r + data[offset + 7u] * value.g + data[offset + 8u] * value.b
  );
}

static float3 spektra_oklab_from_output_rgb(float3 rgb, device const float *outputGamutCompressionData, uint dataOffset) {
  const float3 lms = spektra_mul_packed_matrix(outputGamutCompressionData, dataOffset, rgb);
  const float3 lmsPrime = float3(
    spektra_signed_cuberoot(lms.r),
    spektra_signed_cuberoot(lms.g),
    spektra_signed_cuberoot(lms.b)
  );
  const float3 row0 = float3(0.2104542553, 0.7936177850, -0.0040720468);
  const float3 row1 = float3(1.9779984951, -2.4285922050, 0.4505937099);
  const float3 row2 = float3(0.0259040371, 0.7827717662, -0.8086757660);
  return float3(dot(row0, lmsPrime), dot(row1, lmsPrime), dot(row2, lmsPrime));
}

static float3 spektra_output_rgb_from_oklab(float3 lab, device const float *outputGamutCompressionData, uint dataOffset) {
  const float3 invRow0 = float3(1.0, 0.3963377774, 0.2158037573);
  const float3 invRow1 = float3(1.0, -0.1055613458, -0.0638541728);
  const float3 invRow2 = float3(1.0, -0.0894841775, -1.2914855480);
  const float3 lmsPrime = float3(dot(invRow0, lab), dot(invRow1, lab), dot(invRow2, lab));
  const float3 lms = lmsPrime * lmsPrime * lmsPrime;
  return spektra_mul_packed_matrix(outputGamutCompressionData, dataOffset + 9u, lms);
}

static bool spektra_rgb_in_bounds(float3 rgb, float lowerBound, float upperBound) {
  constexpr float epsilon = 1.0e-6;
  return all(isfinite(rgb)) &&
    all(rgb >= float3(lowerBound - epsilon)) &&
    all(rgb <= float3(upperBound + epsilon));
}

static float spektra_solve_oklch_cmax(
  float3 lab,
  float chroma,
  float2 hueUnit,
  device const float *outputGamutCompressionData,
  uint dataOffset,
  float lowerBound,
  float upperBound
) {
  float lo = 0.0;
  float hi = max(chroma, 1.0e-6);
  const float maxHi = 4.0 * max(upperBound, 1.0);
  for (uint expansion = 0u; expansion < 12u; ++expansion) {
    const float3 candidate = spektra_output_rgb_from_oklab(
      float3(lab.x, hueUnit.x * hi, hueUnit.y * hi),
      outputGamutCompressionData,
      dataOffset
    );
    if (!spektra_rgb_in_bounds(candidate, lowerBound, upperBound)) {
      break;
    }
    lo = hi;
    hi = min(hi * 2.0, maxHi);
    if (hi >= maxHi) {
      break;
    }
  }
  for (uint iteration = 0u; iteration < 16u; ++iteration) {
    const float mid = 0.5 * (lo + hi);
    const float3 candidate = spektra_output_rgb_from_oklab(
      float3(lab.x, hueUnit.x * mid, hueUnit.y * mid),
      outputGamutCompressionData,
      dataOffset
    );
    if (spektra_rgb_in_bounds(candidate, lowerBound, upperBound)) {
      lo = mid;
    } else {
      hi = mid;
    }
  }
  return lo;
}

static float3 spektra_output_gamut_compress_oklch(
  float3 rgb,
  uint colorSpace,
  device const float *outputGamutCompressionData,
  float lowerBound,
  float upperBound,
  bool softenInGamut,
  bool compressLightness,
  bool compressChroma
) {
  if (outputGamutCompressionData == nullptr) {
    return rgb;
  }
  if (!all(isfinite(rgb))) {
    return float3(lowerBound);
  }
  const bool inBounds = spektra_rgb_in_bounds(rgb, lowerBound, upperBound);
  if (inBounds && !softenInGamut) {
    return rgb;
  }
  const uint dataOffset = colorSpace * kSpektraOutputGamutCompressionStride;
  float3 lab = spektra_oklab_from_output_rgb(rgb, outputGamutCompressionData, dataOffset);
  if (compressLightness) {
    lab.x = softenInGamut
      ? spektra_reinhard_knee(max(lab.x, 0.0), 0.7, 1.0, 2.2)
      : clamp(lab.x, 0.0, pow(max(upperBound, 0.0), 1.0 / 3.0));
  }
  const float chroma = length(lab.yz);
  if (!(chroma > 1.0e-10) || !isfinite(chroma)) {
    if (inBounds) {
      return rgb;
    }
    const float3 neutral = spektra_output_rgb_from_oklab(float3(lab.x, 0.0, 0.0), outputGamutCompressionData, dataOffset);
    return clamp(neutral, float3(lowerBound), float3(upperBound));
  }
  if (!compressChroma) {
    const float3 lightnessCompressed = spektra_output_rgb_from_oklab(lab, outputGamutCompressionData, dataOffset);
    return spektra_rgb_in_bounds(lightnessCompressed, lowerBound, upperBound)
      ? lightnessCompressed
      : clamp(lightnessCompressed, float3(lowerBound), float3(upperBound));
  }
  const float2 hueUnit = lab.yz / chroma;
  const float cmax = max(
    spektra_solve_oklch_cmax(lab, chroma, hueUnit, outputGamutCompressionData, dataOffset, lowerBound, upperBound),
    1.0e-9
  );
  const float normalizedChroma = chroma / cmax;
  const float compressedNormalized = softenInGamut
    ? spektra_reinhard_knee(normalizedChroma, 0.0, 1.0, 6.0)
    : (normalizedChroma <= 1.0 ? normalizedChroma : spektra_reinhard_knee(normalizedChroma, 0.85, 1.0, 4.0));
  const float compressedChroma = min(compressedNormalized * cmax, cmax);
  const float3 compressed = spektra_output_rgb_from_oklab(
    float3(lab.x, hueUnit.x * compressedChroma, hueUnit.y * compressedChroma),
    outputGamutCompressionData,
    dataOffset
  );
  return spektra_rgb_in_bounds(compressed, lowerBound, upperBound)
    ? compressed
    : clamp(compressed, float3(lowerBound), float3(upperBound));
}

static float3 spektra_finalize_display_hdr_rgb(
  float3 rgb,
  constant SpektraKernelParams &params,
  constant SpektraColorInfo &colorInfo,
  device const float *encodeLuts
) {
  const float peak = max(params.hdrPeakNits, max(params.hdrReferenceWhiteNits, 1.0) + 1.0);
  device const float *outputGamutCompressionData =
    encodeLuts + colorInfo.colorSpaceCount * colorInfo.transferLutSize;
  const uint colorSpace = spektra_final_output_color_space(params, colorInfo);
  const bool compressLightness =
    spektra_color_adaptation_enabled(params, kSpektraColorAdaptationOutputLightnessCompression);
  const bool compressChroma =
    spektra_color_adaptation_enabled(params, kSpektraColorAdaptationOutputChromaCompression);
  const bool compressOutputGamut = compressLightness || compressChroma;
  float3 nits = spektra_hdr_apply_luminance_tone_map(compressOutputGamut ? rgb : max(rgb, float3(0.0)), params);
  if (compressOutputGamut) {
    nits = spektra_output_gamut_compress_oklch(
      nits / peak,
      colorSpace,
      outputGamutCompressionData,
      0.0,
      1.0,
      false,
      compressLightness,
      compressChroma
    ) * peak;
    nits = clamp(nits, float3(0.0), float3(peak));
  } else {
    nits = max(nits, float3(0.0));
  }
  return params.hdrTransfer == 1
    ? spektra_hlg_display_nits_to_signal(nits, peak, compressOutputGamut)
    : float3(
        spektra_encode_pq(nits.r),
        spektra_encode_pq(nits.g),
        spektra_encode_pq(nits.b)
      );
}

static float3 spektra_finalize_display_sdr_rgb(
  float3 rgb,
  constant SpektraKernelParams &params,
  constant SpektraColorInfo &colorInfo,
  device const float *encodeLuts,
  device const uint *transferKinds
) {
  device const float *outputGamutCompressionData =
    encodeLuts + colorInfo.colorSpaceCount * colorInfo.transferLutSize;
  device const float *transferParams =
    encodeLuts + colorInfo.colorSpaceCount * (colorInfo.transferLutSize + kSpektraOutputGamutCompressionStride);
  const bool compressLightness =
    spektra_color_adaptation_enabled(params, kSpektraColorAdaptationOutputLightnessCompression);
  const bool compressChroma =
    spektra_color_adaptation_enabled(params, kSpektraColorAdaptationOutputChromaCompression);
  if (compressLightness || compressChroma) {
    const uint colorSpace = spektra_final_output_color_space(params, colorInfo);
    rgb = spektra_output_gamut_compress_oklch(
      rgb,
      colorSpace,
      outputGamutCompressionData,
      0.0,
      1.0,
      true,
      compressLightness,
      compressChroma
    );
  }
  return spektra_encode_output_rgb(rgb, params, colorInfo, encodeLuts, transferKinds, transferParams);
}

static float3 spektra_finalize_rcm_rgb(
  float3 timelineLinear,
  constant SpektraKernelParams &params,
  constant SpektraColorInfo &colorInfo,
  device const float *encodeLuts,
  device const uint *transferKinds
) {
  device const float *transferParams =
    encodeLuts + colorInfo.colorSpaceCount * (colorInfo.transferLutSize + kSpektraOutputGamutCompressionStride);
  const uint colorSpace = spektra_color_space_index(params.outputColorSpace, colorInfo);
  if (spektra_rcm_inverse_ootf_enabled(colorSpace)) {
    timelineLinear = spektra_apply_inverse_rcm_ootf(timelineLinear);
  }
  return spektra_encode_output_rgb(timelineLinear, colorSpace, params, colorInfo, encodeLuts, transferKinds, transferParams);
}

static float3 spektra_finalize_output_rgb(
  float3 rgb,
  constant SpektraKernelParams &params,
  constant SpektraColorInfo &colorInfo,
  device const float *encodeLuts,
  device const uint *transferKinds
) {
  if (params.outputRole == kSpektraOutputRoleDisplayHdr) {
    return spektra_finalize_display_hdr_rgb(rgb, params, colorInfo, encodeLuts);
  }
  if (params.outputRole == kSpektraOutputRoleRcm) {
    // RCM returns the selected timeline color space with the same inverse
    // OOTF the user would otherwise apply in a matching CST before Resolve's
    // normal timeline-to-display transform.
    return spektra_finalize_rcm_rgb(rgb, params, colorInfo, encodeLuts, transferKinds);
  }
  return spektra_finalize_display_sdr_rgb(rgb, params, colorInfo, encodeLuts, transferKinds);
}

static float spektra_decode_srgb_scalar(float value) {
  value = clamp(value, 0.0, 1.0);
  return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4);
}



static float3 spektra_mul_color_matrix(float3 rgb, int colorSpace, constant SpektraColorInfo &colorInfo, device const float *matrices) {
  const uint matrixOffset = spektra_color_space_index(colorSpace, colorInfo) * 9u;
  return float3(
    matrices[matrixOffset] * rgb.r + matrices[matrixOffset + 1u] * rgb.g + matrices[matrixOffset + 2u] * rgb.b,
    matrices[matrixOffset + 3u] * rgb.r + matrices[matrixOffset + 4u] * rgb.g + matrices[matrixOffset + 5u] * rgb.b,
    matrices[matrixOffset + 6u] * rgb.r + matrices[matrixOffset + 7u] * rgb.g + matrices[matrixOffset + 8u] * rgb.b
  );
}







































static float spektra_interp_density_curve(
  float logRaw,
  uint channel,
  float gammaFactor,
  constant SpektraCurveInfo &curveInfo,
  device const float *logExposure,
  device const float *densityCurves,
  uint lookupMode,
  uint smoothInterpolation
) {
  const uint count = curveInfo.exposureCount;
  if (count == 0u) {
    return 0.0;
  }

  device const float2 *curveExposure = (device const float2 *)logExposure;
  const float gamma = max(gammaFactor, 1.0e-6);
  const float lookupRaw = gammaFactor == 1.0 ? logRaw : logRaw * gamma;
  const float firstX = curveExposure[0].x;
  const float lastX = curveExposure[count - 1u].x;
  if (lookupRaw <= firstX) {
    return densityCurves[channel];
  }
  if (lookupRaw >= lastX) {
    return densityCurves[(count - 1u) * 3u + channel];
  }

  if (smoothInterpolation == 0u && lookupMode != 0u && count > 1u) {
    const float indexF = clamp(
      (lookupRaw - firstX) * float(count - 1u) / max(lastX - firstX, 1.0e-9),
      0.0,
      float(count - 1u)
    );
    if (lookupMode == 2u) {
      const uint idx = uint(clamp(floor(indexF + 0.5), 0.0, float(count - 1u)));
      return densityCurves[idx * 3u + channel];
    }
    const uint loUniform = uint(floor(indexF));
    const uint hiUniform = min(loUniform + 1u, count - 1u);
    const float y0Uniform = densityCurves[loUniform * 3u + channel];
    const float y1Uniform = densityCurves[hiUniform * 3u + channel];
    return mix(y0Uniform, y1Uniform, indexF - float(loUniform));
  }

  uint lo = 0u;
  uint hi = count - 1u;
  while (hi - lo > 1u) {
    const uint mid = (lo + hi) >> 1u;
    if (curveExposure[mid].x <= lookupRaw) {
      lo = mid;
    } else {
      hi = mid;
    }
  }

  const float x0 = curveExposure[lo].x;
  const float x1 = curveExposure[hi].x;
  const float inverseDx0 = curveExposure[lo].y;
  const float y0 = densityCurves[lo * 3u + channel];
  const float y1 = densityCurves[hi * 3u + channel];
  const float t = clamp((lookupRaw - x0) * inverseDx0, 0.0, 1.0);
  if (smoothInterpolation != 0u && count > 2u) {
    const float dx0 = max(x1 - x0, 1.0e-9);
    const float d0 = (y1 - y0) * inverseDx0;
    float m0 = d0;
    float m1 = d0;
    if (lo > 0u) {
      const float yPrev = densityCurves[(lo - 1u) * 3u + channel];
      const float dPrev = (y0 - yPrev) * curveExposure[lo - 1u].y;
      m0 = dPrev * d0 > 0.0 ? 0.5 * (dPrev + d0) : 0.0;
    }
    if (hi + 1u < count) {
      const float yNext = densityCurves[(hi + 1u) * 3u + channel];
      const float dNext = (yNext - y1) * curveExposure[hi].y;
      m1 = dNext * d0 > 0.0 ? 0.5 * (dNext + d0) : 0.0;
    }
    if (abs(d0) <= 1.0e-9) {
      m0 = 0.0;
      m1 = 0.0;
    } else {
      const float limit = 3.0 * abs(d0);
      m0 = d0 * m0 > 0.0 ? clamp(m0, -limit, limit) : 0.0;
      m1 = d0 * m1 > 0.0 ? clamp(m1, -limit, limit) : 0.0;
    }
    const float t2 = t * t;
    const float t3 = t2 * t;
    return (2.0 * t3 - 3.0 * t2 + 1.0) * y0 +
      (t3 - 2.0 * t2 + t) * dx0 * m0 +
      (-2.0 * t3 + 3.0 * t2) * y1 +
      (t3 - t2) * dx0 * m1;
  }
  return mix(y0, y1, t);
}



















static float spektra_spectral_transmittance(float density, constant SpektraKernelParams &params) {
  constexpr float kLog2Ten = 3.3219280948873623;
  constexpr float kLnTen = 2.302585092994046;
  if (params.spectralTransmittanceMode == 1u) {
    return exp2(-density * kLog2Ten);
  }
  if (params.spectralTransmittanceMode == 2u) {
    return fast::exp(-density * kLnTen);
  }
  return pow(10.0, -density);
}

static float spektra_spectral_transmittance_pow(float density) {
  const float transmittance = pow(10.0, -density);
  return isfinite(transmittance) ? transmittance : 0.0;
}



static float3 spektra_film_silver_density(float3 densityCmy, constant SpektraSpectralInfo &info) {
  if (info.filmPositive != 0u) {
    return max(
      float3(
        info.filmDensityCurveMaximum0,
        info.filmDensityCurveMaximum1,
        info.filmDensityCurveMaximum2
      ) - densityCmy,
      float3(0.0)
    );
  }
  return max(densityCmy, float3(0.0));
}

static float3 spektra_bleach_bypass_silver_layers(
  float3 densityCmy,
  bool printStage,
  constant SpektraSpectralInfo &info
) {
  return printStage ? max(densityCmy, float3(0.0)) : spektra_film_silver_density(densityCmy, info);
}

static float spektra_bleach_bypass_retained_silver_image(
  float3 densityCmy,
  bool printStage,
  constant SpektraSpectralInfo &info
) {
  const float3 silverLayers = spektra_bleach_bypass_silver_layers(densityCmy, printStage, info);
  const float layerShoulder = printStage ? 0.65 : 0.85;
  const float3 retainedSilverByLayer = silverLayers / (silverLayers + float3(layerShoulder));
  return (retainedSilverByLayer.r + retainedSilverByLayer.g + retainedSilverByLayer.b) / 3.0;
}

static float spektra_bleach_bypass_retained_silver_density(
  float3 densityCmy,
  float amount,
  bool printStage,
  constant SpektraSpectralInfo &info
) {
  const float retainedSilverImage = spektra_bleach_bypass_retained_silver_image(densityCmy, printStage, info);
  const float silverDensityScale = printStage ? 0.36 : 0.22;
  return clamp(amount, 0.0, 1.0) * silverDensityScale * retainedSilverImage;
}

static float3 spektra_bleach_bypass_dye_density(
  float3 densityCmy,
  float amount,
  bool printStage,
  constant SpektraSpectralInfo &info
) {
  const float retainedSilverImage = spektra_bleach_bypass_retained_silver_image(densityCmy, printStage, info);
  const float blackImageAmount = clamp(clamp(amount, 0.0, 1.0) * retainedSilverImage, 0.0, 1.0);
  const float blackDensity = max(densityCmy.r, max(densityCmy.g, densityCmy.b));
  return mix(densityCmy, float3(blackDensity), blackImageAmount);
}

static float spektra_negative_leuco_cyan_density_loss(
  float3 densityCmy,
  float amount,
  constant SpektraKernelParams &params,
  constant SpektraSpectralInfo &info
) {
  if (info.filmPositive != 0u) {
    return 0.0;
  }
  const float cyanDensityMax = max(info.filmDensityCurveMaximum0, 1.0e-6);
  const float cyanDensityDrive = clamp(max(densityCmy.r, 0.0) / cyanDensityMax, 0.0, 1.0);
  const float coupling = clamp(params.negativeLeucoCyanCoupling, 0.0, 2.0);
  const float documentedLeucoCyanMaxLoss = 0.30;
  return min(
    clamp(amount, 0.0, 1.0) * coupling * documentedLeucoCyanMaxLoss * cyanDensityDrive,
    documentedLeucoCyanMaxLoss * coupling
  );
}

static float3 spektra_negative_bleach_bypass_dye_density(
  float3 densityCmy,
  float amount,
  constant SpektraKernelParams &params,
  constant SpektraSpectralInfo &info
) {
  float3 bypassedDensityCmy = spektra_bleach_bypass_dye_density(densityCmy, amount, false, info);
  bypassedDensityCmy.r = max(
    bypassedDensityCmy.r - spektra_negative_leuco_cyan_density_loss(densityCmy, amount, params, info),
    0.0
  );
  return bypassedDensityCmy;
}

static float spektra_bleach_bypass_silver_spectral_density(
  float retainedSilverDensity
) {
  return retainedSilverDensity;
}



static float3 spektra_print_raw_from_film_density_cached(
  float3 filmDensityCmy,
  constant SpektraKernelParams &params,
  constant SpektraSpectralInfo &info,
  device const float *filmChannelDensity,
  device const float4 *filmSpectralDensity,
  device const float4 *filteredEnlargerResponse,
  device const float *academyPrinterDensityData
) {
  if (params.printTiming != 1 &&
      params.spectralTransmittanceMode == 0u &&
      params.negativeBleachBypassAmount == 0.0 &&
      info.filmWavelengthCount == 81u) {
    float3 raw0 = float3(0.0);
    float3 raw1 = float3(0.0);
    float3 raw2 = float3(0.0);
    for (uint wavelength = 0u; wavelength < 81u; wavelength += 3u) {
      const float4 spectral0 = filmSpectralDensity[wavelength];
      const float4 spectral1 = filmSpectralDensity[wavelength + 1u];
      const float4 spectral2 = filmSpectralDensity[wavelength + 2u];
      raw0 += spektra_spectral_transmittance_pow(dot(filmDensityCmy, spectral0.xyz)) *
        filteredEnlargerResponse[wavelength].xyz;
      raw1 += spektra_spectral_transmittance_pow(dot(filmDensityCmy, spectral1.xyz)) *
        filteredEnlargerResponse[wavelength + 1u].xyz;
      raw2 += spektra_spectral_transmittance_pow(dot(filmDensityCmy, spectral2.xyz)) *
        filteredEnlargerResponse[wavelength + 2u].xyz;
    }
    return raw0 + raw1 + raw2;
  }
  float3 raw = float3(0.0);
  const float3 bypassedFilmDensityCmy = spektra_negative_bleach_bypass_dye_density(
    filmDensityCmy,
    params.negativeBleachBypassAmount,
    params,
    info
  );
  const float retainedSilverDensity = spektra_bleach_bypass_retained_silver_density(
    filmDensityCmy,
    params.negativeBleachBypassAmount,
    false,
    info
  );
  if (params.printTiming == 1) {
    float3 normalization = float3(0.0);
    for (uint wavelength = 0u; wavelength < info.filmWavelengthCount; ++wavelength) {
      const uint channelOffset = wavelength * 3u;
      const float4 spectral = filmSpectralDensity[wavelength];
      const float densitySpectral =
        dot(bypassedFilmDensityCmy, spectral.xyz) +
        spectral.w +
        spektra_bleach_bypass_silver_spectral_density(retainedSilverDensity);
      const float transmittance = spektra_spectral_transmittance(densitySpectral, params);
      const float3 apd = max(float3(
        academyPrinterDensityData[channelOffset],
        academyPrinterDensityData[channelOffset + 1u],
        academyPrinterDensityData[channelOffset + 2u]
      ), float3(0.0));
      raw += (isfinite(transmittance) ? transmittance : 0.0) * apd;
      normalization += apd;
    }
    return raw / max(normalization, float3(1.0e-10));
  }
  for (uint wavelength = 0u; wavelength < info.filmWavelengthCount; ++wavelength) {
    const float4 spectral = filmSpectralDensity[wavelength];
    const float densitySpectral =
      dot(bypassedFilmDensityCmy, spectral.xyz) +
      spectral.w +
      spektra_bleach_bypass_silver_spectral_density(retainedSilverDensity);
    const float transmittance = spektra_spectral_transmittance(densitySpectral, params);
    const float3 response = filteredEnlargerResponse[info.filmWavelengthCount + wavelength].xyz;
    raw += (isfinite(transmittance) ? transmittance : 0.0) * response;
  }
  return raw;
}

static float3 spektra_printer_light_exposure_scale(
  constant SpektraKernelParams &params,
  constant SpektraSpectralInfo &info,
  device const float *academyPrinterDensityData
) {
  const float3 points = float3(
    params.printerLightsR,
    params.printerLightsG,
    params.printerLightsB
  );
  const float linkedPoint = (params.printerLightsR + params.printerLightsG + params.printerLightsB) / 3.0;
  const float3 resolvedPoints = params.printerLightsGang != 0u
    ? float3(linkedPoint)
    : points;
  float3 internalPoints = float3(0.0);
  if (params.printTiming == 1 && params.printerLightCalibration != 0u) {
    const uint film = uint(clamp(params.film, 0, int(max(info.filmCount, 1u) - 1u)));
    const uint paper = uint(clamp(params.paper, 0, int(max(info.paperCount, 1u) - 1u)));
    const uint offset = info.filmWavelengthCount * 3u + (paper * info.filmCount + film) * 3u;
    internalPoints = float3(
      academyPrinterDensityData[offset],
      academyPrinterDensityData[offset + 1u],
      academyPrinterDensityData[offset + 2u]
    );
  }
  return exp2((internalPoints + resolvedPoints) / 12.0);
}

static float3 spektra_apd_printer_timing_exposure_scale(
  constant SpektraKernelParams &params,
  constant SpektraSpectralInfo &info,
  device const float *academyPrinterDensityData
) {
  if (params.printTiming != 1) {
    return float3(1.0);
  }
  return spektra_printer_light_exposure_scale(params, info, academyPrinterDensityData);
}









static float3 spektra_print_log_raw_with_cached_response(
  float3 filmDensityCmy,
  constant SpektraKernelParams &params,
  constant SpektraSpectralInfo &info,
  device const float *filmChannelDensity,
  device const float4 *filmSpectralDensity,
  device const float4 *filteredEnlargerResponse,
  device const float *academyPrinterDensityData,
  float exposureFactor,
  float3 rawPreflash
) {
  const float3 raw = spektra_print_raw_from_film_density_cached(
    filmDensityCmy,
    params,
    info,
    filmChannelDensity,
    filmSpectralDensity,
    filteredEnlargerResponse,
    academyPrinterDensityData
  );
  const float3 rawTimed = raw * spektra_apd_printer_timing_exposure_scale(params, info, academyPrinterDensityData) *
    exposureFactor + rawPreflash;
  return log10(max(rawTimed * exp2(params.printExposureEv), float3(0.0)) + float3(1.0e-10));
}





static float3 spektra_develop_print_density(
  float3 logRaw,
  constant SpektraKernelParams &params,
  constant SpektraSpectralInfo &info,
  constant SpektraCurveInfo &paperCurveInfo,
  device const float *paperLogExposure,
  device const float *paperDensityCurves
) {
  const uint smoothInterpolation =
    spektra_color_adaptation_enabled(params, kSpektraColorAdaptationCurveSmoothing) ? 1u : 0u;
  const float3 density = float3(
    spektra_interp_density_curve(logRaw.r, 0u, params.printGamma, paperCurveInfo, paperLogExposure, paperDensityCurves, params.densityCurveLookupMode, smoothInterpolation),
    spektra_interp_density_curve(logRaw.g, 1u, params.printGamma, paperCurveInfo, paperLogExposure, paperDensityCurves, params.densityCurveLookupMode, smoothInterpolation),
    spektra_interp_density_curve(logRaw.b, 2u, params.printGamma, paperCurveInfo, paperLogExposure, paperDensityCurves, params.densityCurveLookupMode, smoothInterpolation)
  );
  if (params.printShadowShape == 0.0 && params.printHighlightShape == 0.0) {
    return density;
  }
  const float3 densityMaximum = max(
    float3(
      info.paperDensityCurveMaximum0,
      info.paperDensityCurveMaximum1,
      info.paperDensityCurveMaximum2
    ),
    float3(1.0e-6)
  );
  const float3 normalizedDensity = clamp(density / densityMaximum, float3(0.0), float3(1.0));
  const float3 shadowBasis = normalizedDensity * normalizedDensity * (1.0 - normalizedDensity);
  const float3 highlightBasis = normalizedDensity * (1.0 - normalizedDensity) * (1.0 - normalizedDensity);
  constexpr float kPrintCurveShapeStrength = 0.5;
  const float3 shapedNormalizedDensity = clamp(
    normalizedDensity -
      kPrintCurveShapeStrength * clamp(params.printShadowShape, -1.0, 1.0) * shadowBasis -
      kPrintCurveShapeStrength * clamp(params.printHighlightShape, -1.0, 1.0) * highlightBasis,
    float3(0.0),
    float3(1.0)
  );
  return shapedNormalizedDensity * densityMaximum;
}



static SpektraScanResult spektra_scan_density_to_output_rgb_linear_y_cached(
  float3 densityCmy,
  float retainedSilverDensity,
  constant SpektraKernelParams &params,
  constant SpektraColorInfo &colorInfo,
  constant SpektraSpectralInfo &info,
  device const float4 *spectralDensity,
  device const float *scanCmfProducts,
  float inverseNormalization,
  device const float *scanToOutputRgb
) {
  float3 xyz0 = float3(0.0);
  float3 xyz1 = float3(0.0);
  float3 xyz2 = float3(0.0);
  uint wavelength = 0u;
  for (; wavelength + 2u < info.filmWavelengthCount; wavelength += 3u) {
    const uint offset0 = wavelength * 3u;
    const uint offset1 = offset0 + 3u;
    const uint offset2 = offset0 + 6u;
    const float4 spectral0 = spectralDensity[wavelength];
    const float4 spectral1 = spectralDensity[wavelength + 1u];
    const float4 spectral2 = spectralDensity[wavelength + 2u];
    const float density0 = dot(densityCmy, spectral0.xyz) + spectral0.w + retainedSilverDensity;
    const float density1 = dot(densityCmy, spectral1.xyz) + spectral1.w + retainedSilverDensity;
    const float density2 = dot(densityCmy, spectral2.xyz) + spectral2.w + retainedSilverDensity;
    const float transmittance0 = spektra_spectral_transmittance(density0, params);
    const float transmittance1 = spektra_spectral_transmittance(density1, params);
    const float transmittance2 = spektra_spectral_transmittance(density2, params);
    xyz0 += (isfinite(transmittance0) ? transmittance0 : 0.0) * float3(
      scanCmfProducts[offset0],
      scanCmfProducts[offset0 + 1u],
      scanCmfProducts[offset0 + 2u]
    );
    xyz1 += (isfinite(transmittance1) ? transmittance1 : 0.0) * float3(
      scanCmfProducts[offset1],
      scanCmfProducts[offset1 + 1u],
      scanCmfProducts[offset1 + 2u]
    );
    xyz2 += (isfinite(transmittance2) ? transmittance2 : 0.0) * float3(
      scanCmfProducts[offset2],
      scanCmfProducts[offset2 + 1u],
      scanCmfProducts[offset2 + 2u]
    );
  }
  float3 xyz = xyz0 + xyz1 + xyz2;
  for (; wavelength < info.filmWavelengthCount; ++wavelength) {
    const uint offset = wavelength * 3u;
    const float4 spectral = spectralDensity[wavelength];
    const float density = dot(densityCmy, spectral.xyz) + spectral.w + retainedSilverDensity;
    const float transmittance = spektra_spectral_transmittance(density, params);
    xyz += (isfinite(transmittance) ? transmittance : 0.0) * float3(
      scanCmfProducts[offset],
      scanCmfProducts[offset + 1u],
      scanCmfProducts[offset + 2u]
    );
  }
  xyz *= inverseNormalization;
  return {spektra_mul_color_matrix(xyz, int(spektra_final_output_color_space(params, colorInfo)), colorInfo, scanToOutputRgb), xyz.y};
}

static SpektraScanResult spektra_scan_density_to_output_rgb_linear_y_cached_common(
  float3 densityCmy,
  bool printStage,
  constant SpektraKernelParams &params,
  constant SpektraColorInfo &colorInfo,
  constant SpektraSpectralInfo &info,
  device const float4 *spectralDensity,
  device const float4 *packedScanCmfProducts,
  device const float *legacyScanCmfProducts,
  float inverseNormalization,
  device const float *scanToOutputRgb
) {
  const float bleachBypassAmount = printStage
    ? params.printBleachBypassAmount
    : params.negativeBleachBypassAmount;
  if (bleachBypassAmount == 0.0 &&
      params.spectralTransmittanceMode == 0u &&
      info.filmWavelengthCount == 81u) {
    float3 xyz0 = float3(0.0);
    float3 xyz1 = float3(0.0);
    float3 xyz2 = float3(0.0);
    for (uint wavelength = 0u; wavelength < 81u; wavelength += 3u) {
      const float4 spectral0 = spectralDensity[wavelength];
      const float4 spectral1 = spectralDensity[wavelength + 1u];
      const float4 spectral2 = spectralDensity[wavelength + 2u];
      xyz0 += spektra_spectral_transmittance_pow(dot(densityCmy, spectral0.xyz)) *
        packedScanCmfProducts[wavelength].xyz;
      xyz1 += spektra_spectral_transmittance_pow(dot(densityCmy, spectral1.xyz)) *
        packedScanCmfProducts[wavelength + 1u].xyz;
      xyz2 += spektra_spectral_transmittance_pow(dot(densityCmy, spectral2.xyz)) *
        packedScanCmfProducts[wavelength + 2u].xyz;
    }
    const float3 xyz = (xyz0 + xyz1 + xyz2) * inverseNormalization;
    return {spektra_mul_color_matrix(xyz, int(spektra_final_output_color_space(params, colorInfo)), colorInfo, scanToOutputRgb), xyz.y};
  }
  const float3 bypassedDensityCmy = printStage
    ? spektra_bleach_bypass_dye_density(densityCmy, bleachBypassAmount, true, info)
    : spektra_negative_bleach_bypass_dye_density(densityCmy, bleachBypassAmount, params, info);
  return spektra_scan_density_to_output_rgb_linear_y_cached(
    bypassedDensityCmy,
    spektra_bleach_bypass_retained_silver_density(densityCmy, bleachBypassAmount, printStage, info),
    params,
    colorInfo,
    info,
    spectralDensity,
    legacyScanCmfProducts,
    inverseNormalization,
    scanToOutputRgb
  );
}









static float spektra_scanner_target_level(bool correctionEnabled, float level, float referenceY) {
  return correctionEnabled ? spektra_decode_srgb_scalar(level) : referenceY;
}

static float3 spektra_apply_scanner_black_white_correction(
  float3 rgb,
  float sourceY,
  float referenceBlackY,
  float referenceWhiteY,
  constant SpektraKernelParams &params
) {
  if (params.scannerEnabled == 0u || (params.scannerBlackCorrection == 0u && params.scannerWhiteCorrection == 0u)) {
    return rgb;
  }
  const float blackLevel = spektra_scanner_target_level(params.scannerBlackCorrection != 0u, params.scannerBlackLevel, referenceBlackY);
  const float whiteLevel = spektra_scanner_target_level(params.scannerWhiteCorrection != 0u, params.scannerWhiteLevel, referenceWhiteY);
  const float m = (whiteLevel - blackLevel) / max(referenceWhiteY - referenceBlackY, 1.0e-10);
  const float q = blackLevel - m * referenceBlackY;
  const float correctedY = clamp(m * sourceY + q, 0.0, 1.0);
  return rgb * (correctedY / max(sourceY, 1.0e-10));
}

static float3 spektra_apply_print_scan_output_contract(
  SpektraScanResult scan,
  constant SpektraFrameConstants &frameConstants,
  constant SpektraKernelParams &params
) {
  if (spektra_rcm_enabled(params)) {
    return scan.rgb;
  }
  return spektra_apply_scanner_black_white_correction(
    scan.rgb,
    scan.y,
    frameConstants.print.y,
    frameConstants.print.z,
    params
  );
}

static float4 spektra_normalize_film_scan_rgb_y(
  SpektraScanResult scan,
  SpektraScanResult filmDmaxScan,
  SpektraScanResult filmDminScan,
  bool positiveFilm
) {
  const float3 rawScanRange = filmDminScan.rgb - filmDmaxScan.rgb;
  const float3 scanRangeSign = select(float3(-1.0), float3(1.0), rawScanRange >= float3(0.0));
  const float3 scanRange = scanRangeSign * max(abs(rawScanRange), float3(1.0e-6));
  const float yRange = max(filmDminScan.y - filmDmaxScan.y, 1.0e-10);
  const float3 normalizedRgb = positiveFilm
    ? (scan.rgb - filmDmaxScan.rgb) / scanRange
    : (filmDminScan.rgb - scan.rgb) / scanRange;
  const float normalizedY = positiveFilm
    ? (scan.y - filmDmaxScan.y) / yRange
    : (filmDminScan.y - scan.y) / yRange;
  return float4(normalizedRgb, normalizedY);
}

static float3 spektra_apply_film_scan_output_contract(
  SpektraScanResult scan,
  constant SpektraFrameConstants &frameConstants,
  constant SpektraKernelParams &params,
  constant SpektraSpectralInfo &info
) {
  if (params.scanNegativeInvert == 0u) {
    return scan.rgb;
  }
  const SpektraScanResult filmDmaxScan = {frameConstants.filmDmaxScan.rgb, frameConstants.filmDmaxScan.a};
  const SpektraScanResult filmDminScan = {frameConstants.filmDminScan.rgb, frameConstants.filmDminScan.a};
  const float4 normalized = spektra_normalize_film_scan_rgb_y(
    scan,
    filmDmaxScan,
    filmDminScan,
    info.filmPositive != 0u
  );
  if (spektra_rcm_enabled(params)) {
    return normalized.rgb;
  }
  return spektra_apply_scanner_black_white_correction(
    normalized.rgb,
    normalized.a,
    0.0,
    1.0,
    params
  );
}































struct SpektraGrainSynthesisEval {
  float scaledMeanRadius;
  float maxRadius;
  float maxRadiusSquared;
  float cellSize;
  float meanArea;
  float cellArea;
  float densityToLambda;
  uint grainCap;
};
































































































































struct SpektraHostBufferLayout {
  uint width;
  uint height;
  uint rowBytes;
  uint startByteOffset;
};















































































































































































































































static float3 densityLutCubic(texture3d<float, access::sample> table,float3 p) {
 constexpr sampler linearSampler(coord::normalized,address::clamp_to_edge,filter::linear);
 const float3 q=(p+.25f)*32.f,base=floor(q),t=q-base;
 const float3 w0=(1.f-t)*(1.f-t)*(1.f-t)/6.f;
 const float3 w1=(3.f*t*t*t-6.f*t*t+4.f)/6.f;
 const float3 w2=(-3.f*t*t*t+3.f*t*t+3.f*t+1.f)/6.f;
 const float3 w3=t*t*t/6.f,g0=w0+w1,g1=w2+w3;
 const float3 h0=(base-1.f+w1/g0+.5f)/129.f,h1=(base+1.f+w3/g1+.5f)/129.f;
 float3 value=0;
 for(uint z=0;z<2;z++)for(uint y=0;y<2;y++)for(uint x=0;x<2;x++) {
  const float3 coord=float3(x?h1.x:h0.x,y?h1.y:h0.y,z?h1.z:h0.z);
  value+=table.sample(linearSampler,coord).rgb*(x?g1.x:g0.x)*(y?g1.y:g0.y)*(z?g1.z:g0.z);
 }
 return value;
}
kernel void spektrafilm_lut_prefilter(device float4 *table [[buffer(0)]],
 constant uint &axis [[buffer(1)]],uint line [[thread_position_in_grid]]) {
 if(line>=129u*129u)return;
 uint start,stride;
 if(axis==0){start=line*129u;stride=1;}
 else if(axis==1){start=(line/129u)*16641u+line%129u;stride=129u;}
 else{start=line;stride=16641u;}
 float c[129];float4 d[129];c[0]=.5f;d[0]=table[start]*1.5f;
 for(uint i=1;i<129;i++) {
  const float lower=i==128?2.f:1.f,denom=4.f-lower*c[i-1];
  c[i]=i==128?0.f:1.f/denom;d[i]=(table[start+i*stride]*6.f-lower*d[i-1])/denom;
 }
 float4 next=d[128];table[start+128u*stride]=next;
 for(int i=127;i>=0;i--){next=d[i]-c[i]*next;table[start+uint(i)*stride]=next;}
}
kernel void spektrafilm_final_from_film_density_lut(
  device const float4 *filmDensity [[buffer(0)]],
  device float4 *destination [[buffer(1)]],
  constant SpektraKernelParams &params [[buffer(2)]],
  constant uint2 &dims [[buffer(3)]],
  constant SpektraCurveInfo &filmCurveInfo [[buffer(4)]],
  device const float *filmLogExposure [[buffer(5)]],
  device const float *filmDensityCurves [[buffer(6)]],
  constant SpektraSpectralInfo &spectralInfo [[buffer(7)]],
  constant SpektraColorInfo &colorInfo [[buffer(8)]],
  device const uint *transferKinds [[buffer(9)]],
  constant SpektraCurveInfo &paperCurveInfo [[buffer(10)]],
  device const float *paperLogExposure [[buffer(11)]],
  device const float *paperDensityCurves [[buffer(12)]],
  device const float *filmLogSensitivity [[buffer(13)]],
  device const float *bandpassHanatos2025 [[buffer(14)]],
  device const float *hanatosSpectraLut [[buffer(15)]],
  device const float *mallettBasisIlluminant [[buffer(16)]],
  device const float *inputToReferenceXyz [[buffer(17)]],
  device const float *filmChannelDensity [[buffer(18)]],
  device const float4 *filmSpectralDensity [[buffer(19)]],
  device const float4 *filteredEnlargerResponse [[buffer(20)]],
  device const float *thKg3Illuminant [[buffer(21)]],
  device const float *customEnlargerFilters [[buffer(22)]],
  device const float *neutralPrintFilters [[buffer(23)]],
  device const float *academyPrinterDensityData [[buffer(24)]],
  device const float4 *paperSpectralDensity [[buffer(25)]],
  device const float *scanProducts [[buffer(26)]],
  device const float *scanToOutputRgbData [[buffer(27)]],
  device const float *encodeLuts [[buffer(28)]],
  constant SpektraFrameConstants &frameConstants [[buffer(29)]],
  constant uint &encodeOutput [[buffer(30)]],
  texture3d<float, access::sample> densityLut [[texture(0)]],
  uint2 gid [[thread_position_in_grid]]
) {
  if (gid.x >= dims.x || gid.y >= dims.y) {
    return;
  }
  const uint index = gid.y * dims.x + gid.x;
  float4 pixel = filmDensity[index];
  const uint3 bits=as_type<uint3>(pixel.rgb);
  if(all((bits&uint3(0x7f800000u))!=uint3(0x7f800000u)) &&
     all(pixel.rgb>=float3(0)) && all(pixel.rgb<=float3(3.5))) {
    constexpr sampler sampleLut(coord::normalized,address::clamp_to_edge,filter::linear);
    float3 color=densityLutCubic(densityLut,pixel.rgb);
    if(all(abs(color)>float3(.05))) {
      if(encodeOutput!=0) color=spektra_finalize_output_rgb(color,params,colorInfo,encodeLuts,transferKinds);
      destination[index]=float4(color,pixel.a);return;
    }
  }

  device const float4 *packedScanProducts = (device const float4 *)scanProducts;
  device const float4 *filmPackedScanProducts = packedScanProducts;
  device const float4 *paperPackedScanProducts = packedScanProducts + spectralInfo.filmWavelengthCount;
  device const float *legacyScanProducts = scanProducts + spectralInfo.filmWavelengthCount * 8u;
  device const float *filmLegacyScanProducts = legacyScanProducts;
  device const float *paperLegacyScanProducts = legacyScanProducts + spectralInfo.filmWavelengthCount * 3u;
  device const float *scanInverseNormalizations = legacyScanProducts + spectralInfo.filmWavelengthCount * 6u;
  device const float *filmScanToOutputRgb = scanToOutputRgbData;
  device const float *paperScanToOutputRgb = scanToOutputRgbData + colorInfo.colorSpaceCount * 9u;

  const bool finalPrintSimulation = params.process == 0;
  const bool finalScanNegative = params.process == 1;
  if (finalPrintSimulation) {
    pixel.rgb = spektra_print_log_raw_with_cached_response(
        pixel.rgb,
        params,
        spectralInfo,
        filmChannelDensity,
        filmSpectralDensity,
        filteredEnlargerResponse,
        academyPrinterDensityData,
        frameConstants.print.x,
        frameConstants.preflash.rgb
      );
  }
  if (finalPrintSimulation) {
    pixel.rgb = spektra_develop_print_density(
      pixel.rgb,
      params,
      spectralInfo,
      paperCurveInfo,
      paperLogExposure,
      paperDensityCurves
    );
  }
  if (finalPrintSimulation) {
    const float3 printDensityCmy = pixel.rgb;
    SpektraScanResult scan = spektra_scan_density_to_output_rgb_linear_y_cached_common(
      printDensityCmy,
      true,
      params,
      colorInfo,
      spectralInfo,
      paperSpectralDensity,
      paperPackedScanProducts,
      paperLegacyScanProducts,
      scanInverseNormalizations[1],
      paperScanToOutputRgb
    );
    pixel.rgb = spektra_apply_print_scan_output_contract(scan, frameConstants, params);
  } else if (finalScanNegative) {
    const float3 filmDensityCmy = pixel.rgb;
    SpektraScanResult scan = spektra_scan_density_to_output_rgb_linear_y_cached_common(
      filmDensityCmy,
      false,
      params,
      colorInfo,
      spectralInfo,
      filmSpectralDensity,
      filmPackedScanProducts,
      filmLegacyScanProducts,
      scanInverseNormalizations[0],
      filmScanToOutputRgb
    );
    pixel.rgb = spektra_apply_film_scan_output_contract(scan, frameConstants, params, spectralInfo);
  }
  if (encodeOutput != 0u && (finalPrintSimulation || finalScanNegative)) {
    pixel.rgb = spektra_finalize_output_rgb(pixel.rgb, params, colorInfo, encodeLuts, transferKinds);
  }
  destination[index] = pixel;
}
kernel void spektrafilm_lut_to_texture(device const float4 *table [[buffer(0)]],
 texture3d<float, access::write> destination [[texture(0)]],uint2 gid [[thread_position_in_grid]]) {
 if(gid.x>=129u||gid.y>=16641u)return;
 destination.write(table[gid.y*129u+gid.x],uint3(gid.x,gid.y%129u,gid.y/129u));
}

)SPEKTRALUT";
