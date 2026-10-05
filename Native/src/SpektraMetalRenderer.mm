#include "SpektraMetalRenderer.h"
#include "SpektraProfileCurves.h"

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <MetalPerformanceShaders/MetalPerformanceShaders.h>

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstddef>
#include <cstdlib>
#include <cstring>
#include <dlfcn.h>
#include <mutex>
#include <unordered_map>
#include <vector>

#ifndef __has_feature
#  define __has_feature(x) 0
#endif

#if !__has_feature(objc_arc)
#  error "SpektraMetalRenderer.mm must be compiled with Objective-C ARC (-fobjc-arc)."
#endif

namespace spektrafilm {

namespace {

int bundleImageAnchor = 0;

NSURL *findBundleResourceURL(NSString *name, NSString *extension) {
  NSArray<NSString *> *bundleIdentifiers = @[
    @"org.spektrafilm",
    @"org.spektrafilm.flow",
    @"org.spektrafilm.dev"
  ];
  for (NSString *bundleIdentifier in bundleIdentifiers) {
    NSBundle *pluginBundle = [NSBundle bundleWithIdentifier:bundleIdentifier];
    if (pluginBundle) {
      NSURL *url = [pluginBundle URLForResource:name withExtension:extension];
      if (url) {
        return url;
      }
    }
  }
  for (NSBundle *candidate in [NSBundle allBundles]) {
    NSURL *url = [candidate URLForResource:name withExtension:extension];
    if (url) {
      return url;
    }
  }
  NSString *fallback = [[NSBundle mainBundle] pathForResource:name ofType:extension];
  if (fallback) {
    return [NSURL fileURLWithPath:fallback];
  }

  NSMutableArray<NSString *> *fallbackDirectories = [NSMutableArray array];
  NSString *resourceDir = [[[NSProcessInfo processInfo] environment] objectForKey:@"SPEKTRAFILM_RESOURCE_DIR"];
  if ([resourceDir length] > 0) {
    [fallbackDirectories addObject:resourceDir];
  }
  NSString *mainResourcePath = [[NSBundle mainBundle] resourcePath];
  if ([mainResourcePath length] > 0) {
    [fallbackDirectories addObject:mainResourcePath];
  }
  Dl_info imageInfo;
  if (dladdr(&bundleImageAnchor, &imageInfo) != 0 && imageInfo.dli_fname) {
    NSString *imagePath = [NSString stringWithUTF8String:imageInfo.dli_fname];
    NSString *imageDirectory = [imagePath stringByDeletingLastPathComponent];
    NSString *contentsDirectory = [imageDirectory stringByDeletingLastPathComponent];
    if ([contentsDirectory length] > 0) {
      [fallbackDirectories addObject:[contentsDirectory stringByAppendingPathComponent:@"Resources"]];
    }
    if ([imageDirectory length] > 0) {
      [fallbackDirectories addObject:imageDirectory];
    }
  }
  NSString *executablePath = [[NSBundle mainBundle] executablePath];
  NSString *executableDirectory = [executablePath stringByDeletingLastPathComponent];
  if ([executableDirectory length] > 0) {
    [fallbackDirectories addObject:executableDirectory];
  }
  NSString *currentDirectory = [[NSFileManager defaultManager] currentDirectoryPath];
  if ([currentDirectory length] > 0) {
    [fallbackDirectories addObject:currentDirectory];
  }

  NSFileManager *fileManager = [NSFileManager defaultManager];
  for (NSString *directory in fallbackDirectories) {
    NSString *path = [[directory stringByAppendingPathComponent:name] stringByAppendingPathExtension:extension];
    if ([fileManager fileExistsAtPath:path]) {
      return [NSURL fileURLWithPath:path];
    }
  }
  return nil;
}

using PerfClock = std::chrono::steady_clock;

double elapsedMilliseconds(PerfClock::time_point start, PerfClock::time_point end) {
  return std::chrono::duration<double, std::milli>(end - start).count();
}

bool envFlagEnabled(const char *name) {
  const char *value = std::getenv(name);
  if (!value) {
    return false;
  }
  return std::strcmp(value, "1") == 0 ||
         std::strcmp(value, "true") == 0 ||
         std::strcmp(value, "TRUE") == 0 ||
         std::strcmp(value, "yes") == 0 ||
         std::strcmp(value, "YES") == 0 ||
         std::strcmp(value, "on") == 0 ||
         std::strcmp(value, "ON") == 0;
}

bool envFlagEnabledOrDefault(const char *name, bool defaultValue) {
  const char *value = std::getenv(name);
  if (!value) {
    return defaultValue;
  }
  if (std::strcmp(value, "1") == 0 ||
      std::strcmp(value, "true") == 0 ||
      std::strcmp(value, "TRUE") == 0 ||
      std::strcmp(value, "yes") == 0 ||
      std::strcmp(value, "YES") == 0 ||
      std::strcmp(value, "on") == 0 ||
      std::strcmp(value, "ON") == 0) {
    return true;
  }
  if (std::strcmp(value, "0") == 0 ||
      std::strcmp(value, "false") == 0 ||
      std::strcmp(value, "FALSE") == 0 ||
      std::strcmp(value, "no") == 0 ||
      std::strcmp(value, "NO") == 0 ||
      std::strcmp(value, "off") == 0 ||
      std::strcmp(value, "OFF") == 0) {
    return false;
  }
  return defaultValue;
}

std::string envString(const char *name, const char *fallback = "") {
  const char *value = std::getenv(name);
  return value ? std::string(value) : std::string(fallback);
}

struct KernelParams {
  int32_t process;
  int32_t rgbToRawMethod;
  int32_t inputColorSpace;
  int32_t outputColorSpace;
  int32_t outputRole;
  int32_t hdrPreset;
  int32_t hdrTransfer;
  float hdrReferenceWhiteNits;
  float hdrPeakNits;
  float hdrExposureEv;
  int32_t hdrToneMapping;
  uint32_t colorAdaptationFlags;
  int32_t film;
  int32_t paper;
  int32_t printTiming;
  float filmExposureEv;
  uint32_t autoExposureEnabled;
  int32_t autoExposureMethod;
  float autoExposureEv;
  float _padAutoExposure0;
  float printExposureEv;
  float filmGamma;
  float printGamma;
  float printShadowShape;
  float printHighlightShape;
  int32_t filmPushPullMode;
  float filmPushPullStops;
  int32_t printPushPullMode;
  float printPushPullStops;
  float negativeBleachBypassAmount;
  float negativeLeucoCyanCoupling;
  float printBleachBypassAmount;
  uint32_t scanNegativeInvert;
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
  uint32_t printerLightsGang;
  uint32_t printerLightCalibration;
  float dirCouplersAmount;
  float dirCouplersDiffusionUm;
  float dirCouplersDiffusionTailUm;
  float dirCouplersDiffusionTailWeight;
  uint32_t grainEnabled;
  int32_t grainModel;
  int32_t filmFormat;
  float grainAmount;
  float grainSaturation;
  uint32_t grainSublayersEnabled;
  int32_t grainSubLayerCount;
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
  uint32_t grainSeed;
  uint32_t grainAnimate;
  float filmPixelSizeUm;
  float _padGrain0;
  int32_t grainSynthesisSamples;
  float grainSynthesisAmount;
  float grainSynthesisMeanRadiusUm;
  float grainSynthesisRadiusStdDevRatio;
  float grainSynthesisObservationSigmaUm;
  float grainSynthesisCellSizeRatio;
  float grainSynthesisMaxRadiusQuantile;
  float grainSynthesisCoverageEpsilon;
  int32_t grainSynthesisMaxGrainsPerCell;
  float grainSynthesisRadiusScaleR;
  float grainSynthesisRadiusScaleG;
  float grainSynthesisRadiusScaleB;
  float grainSynthesisLayerScale0;
  float grainSynthesisLayerScale1;
  float grainSynthesisLayerScale2;
  uint32_t grainSynthesisLayered;
  uint32_t _padGrainSynthesis0;
  uint32_t halationEnabled;
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
  uint32_t cameraDiffusionEnabled;
  int32_t cameraDiffusionFamily;
  float cameraDiffusionStrength;
  float cameraDiffusionSpatialScale;
  float cameraDiffusionHaloWarmth;
  float cameraDiffusionCoreIntensity;
  float cameraDiffusionCoreSize;
  float cameraDiffusionHaloIntensity;
  float cameraDiffusionHaloSize;
  float cameraDiffusionBloomIntensity;
  float cameraDiffusionBloomSize;
  uint32_t printDiffusionEnabled;
  int32_t printDiffusionFamily;
  float printDiffusionStrength;
  float printDiffusionSpatialScale;
  float printDiffusionHaloWarmth;
  float printDiffusionCoreIntensity;
  float printDiffusionCoreSize;
  float printDiffusionHaloIntensity;
  float printDiffusionHaloSize;
  float printDiffusionBloomIntensity;
  float printDiffusionBloomSize;
  uint32_t scannerEnabled;
  uint32_t scannerWhiteCorrection;
  uint32_t scannerBlackCorrection;
  float scannerWhiteLevel;
  float scannerBlackLevel;
  float glarePercent;
  float glareRoughness;
  float glareBlur;
  float scannerBlurSigmaPx;
  float scannerUnsharpSigmaPx;
  float scannerUnsharpAmount;
  uint32_t densityCurveLookupMode;
  uint32_t spectralTransmittanceMode;
  uint32_t _padPerf0;
  float time;
};

constexpr uint32_t kGrainSynthesisComponentCount = 9u;
constexpr uint32_t kGrainSynthesisMaxSamples = 1024u;
constexpr uint32_t kGrainSynthesisMaxRadiusLutSize = 512u;
constexpr uint32_t kGrainSynthesisMaxCellOffsetsPerComponent = 16384u;

struct KernelGrainSynthesisComponentInfo {
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
  uint32_t grainCap;
  uint32_t cellScanRadius;
  uint32_t sampleCount;
  uint32_t active;
  uint32_t radiusLutOffset;
  uint32_t radiusLutSize;
  uint32_t cellOffsetStart;
  uint32_t cellOffsetCount;
  uint32_t samplerMode;
  uint32_t _pad0;
};

struct KernelGrainSynthesisSampleOffset {
  float x;
  float y;
};

struct KernelGrainSynthesisCellOffset {
  int32_t x;
  int32_t y;
};

static_assert(sizeof(KernelGrainSynthesisComponentInfo) == 80u);
static_assert(sizeof(KernelGrainSynthesisSampleOffset) == 8u);
static_assert(sizeof(KernelGrainSynthesisCellOffset) == 8u);

enum class GrainSynthesisSamplerMode : uint32_t {
  R2 = 0u,
  Antithetic = 1u,
  SobolBlue = 2u,
};

enum class GrainSynthesisCellMode : uint32_t {
  Current = 0u,
  OffsetList = 1u,
  ThreadgroupCache = 2u,
};

enum class GrainSynthesisTargetStorageMode : uint32_t {
  FloatBuffer = 0u,
  HalfBuffer = 1u,
  R16TextureArray = 2u,
};

enum class DirTailBackend : uint32_t {
  Fused = 0u,
  Mps = 1u,
};

enum class DensityCurveLookupMode : uint32_t {
  Binary = 0u,
  UniformLinear = 1u,
  UniformNearest = 2u,
};

enum class SpectralTransmittanceMode : uint32_t {
  Pow = 0u,
  Exp2 = 1u,
  FastExp = 2u,
};

struct KernelCurveInfo {
  uint32_t exposureCount;
  uint32_t _pad0;
  uint32_t _pad1;
  uint32_t _pad2;
};

struct KernelSpectralInfo {
  uint32_t filmWavelengthCount;
  uint32_t hanatosWidth;
  uint32_t hanatosHeight;
  uint32_t hanatosWavelengthCount;
  uint32_t filmCount;
  uint32_t paperCount;
  uint32_t filmPositive;
  uint32_t _padCount1;
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

struct KernelColorInfo {
  uint32_t colorSpaceCount;
  uint32_t transferLutSize;
  float decodeMin;
  float decodeMax;
  float encodeMin;
  float encodeMax;
  float _pad0;
  float _pad1;
};

struct KernelDirInfo {
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

struct KernelDiffusionInfo {
  uint32_t componentCount;
  float scatterFraction;
  uint32_t _pad0;
  uint32_t _pad1;
};

struct KernelDiffusionComponent {
  float sigmaPx;
  float weightR;
  float weightG;
  float weightB;
};

struct KernelGaussianBlurInfo {
  float firstWeight = 0.0f;
  float firstRatio = 0.0f;
  float ratioStep = 0.0f;
  float invWeightSum = 1.0f;
  uint32_t radius = 0u;
  uint32_t active = 0u;
  uint32_t _pad0 = 0u;
  uint32_t _pad1 = 0u;
};
static_assert(sizeof(KernelGaussianBlurInfo) == 32u);

struct StaticProfileResources {
  int32_t film = -1;
  int32_t paper = -1;
  RgbToRawMethod rgbToRawMethod = RgbToRawMethod::Hanatos2026;
  bool cameraUvFilterEnabled = false;
  float cameraUvCutNm = 410.0f;
  bool cameraIrFilterEnabled = false;
  float cameraIrCutNm = 675.0f;
  PrintTimingMode processNegativePrintTiming = PrintTimingMode::FilteredEnlarger;
  float processNegativeFilterC = 0.0f;
  float processNegativeFilterMShift = 0.0f;
  float processNegativeFilterYShift = 0.0f;
  float processNegativePreflashMFilterShift = 0.0f;
  float processNegativePreflashYFilterShift = 0.0f;
  const ProfileCurveSet *filmCurves = nullptr;
  const ProfileCurveSet *paperCurves = nullptr;
  KernelCurveInfo curveInfo{};
  KernelCurveInfo paperCurveInfo{};
  KernelColorInfo colorInfo{};
  KernelSpectralInfo spectralInfo{};
  id<MTLBuffer> curveInfoBuffer = nil;
  id<MTLBuffer> logExposureBuffer = nil;
  id<MTLBuffer> densityCurvesBuffer = nil;
  id<MTLBuffer> spectralInfoBuffer = nil;
  id<MTLBuffer> wavelengthsBuffer = nil;
  id<MTLBuffer> logSensitivityBuffer = nil;
  id<MTLBuffer> bandpassHanatosBuffer = nil;
  id<MTLBuffer> hanatosRawResponseBuffer = nil;
  id<MTLBuffer> paperHanatosResponseBuffer = nil;
  id<MTLBuffer> preflashPaperHanatosResponseBuffer = nil;
  id<MTLBuffer> mallettBasisIlluminantBuffer = nil;
  id<MTLBuffer> inputToReferenceXyzBuffer = nil;
  id<MTLBuffer> inputToSrgbBuffer = nil;
  id<MTLBuffer> colorInfoBuffer = nil;
  id<MTLBuffer> colorDecodeLutBuffer = nil;
  id<MTLBuffer> colorTransferKindBuffer = nil;
  id<MTLBuffer> paperCurveInfoBuffer = nil;
  id<MTLBuffer> paperLogExposureBuffer = nil;
  id<MTLBuffer> paperDensityCurvesBuffer = nil;
  id<MTLBuffer> filmChannelDensityBuffer = nil;
  id<MTLBuffer> filmBaseDensityBuffer = nil;
  id<MTLBuffer> filmSpectralDensityBuffer = nil;
  id<MTLBuffer> paperLogSensitivityBuffer = nil;
  id<MTLBuffer> thKg3IlluminantBuffer = nil;
  id<MTLBuffer> customEnlargerFiltersBuffer = nil;
  id<MTLBuffer> neutralPrintFiltersBuffer = nil;
  id<MTLBuffer> academyPrinterDensityDataBuffer = nil;
  id<MTLBuffer> paperScanDensityDataBuffer = nil;
  id<MTLBuffer> paperSpectralDensityBuffer = nil;
  id<MTLBuffer> scanIlluminantsAndCmfsBuffer = nil;
  id<MTLBuffer> scanProductsBuffer = nil;
  id<MTLBuffer> scanToOutputRgbDataBuffer = nil;
  id<MTLBuffer> colorEncodeLutBuffer = nil;

  bool validFor(const RenderParams &params) const {
    const bool processNegativeResponseValid =
      params.process != ProcessMode::ProcessNegative ||
      (processNegativePrintTiming == params.printTiming &&
       processNegativeFilterC == params.filterC &&
       processNegativeFilterMShift == params.filterMShift &&
       processNegativeFilterYShift == params.filterYShift &&
       processNegativePreflashMFilterShift == params.preflashMFilterShift &&
       processNegativePreflashYFilterShift == params.preflashYFilterShift);
    return film == params.film &&
           paper == params.paper &&
           rgbToRawMethod == params.rgbToRawMethod &&
           cameraUvFilterEnabled == params.cameraUvFilterEnabled &&
           cameraUvCutNm == params.cameraUvCutNm &&
           cameraIrFilterEnabled == params.cameraIrFilterEnabled &&
           cameraIrCutNm == params.cameraIrCutNm &&
           processNegativeResponseValid &&
           filmCurves &&
           paperCurves &&
           curveInfoBuffer &&
           logExposureBuffer &&
           densityCurvesBuffer &&
           spectralInfoBuffer &&
           wavelengthsBuffer &&
           logSensitivityBuffer &&
           bandpassHanatosBuffer &&
           hanatosRawResponseBuffer &&
           paperHanatosResponseBuffer &&
           preflashPaperHanatosResponseBuffer &&
           mallettBasisIlluminantBuffer &&
           inputToReferenceXyzBuffer &&
           inputToSrgbBuffer &&
           colorInfoBuffer &&
           colorDecodeLutBuffer &&
           colorTransferKindBuffer &&
           paperCurveInfoBuffer &&
           paperLogExposureBuffer &&
           paperDensityCurvesBuffer &&
           filmChannelDensityBuffer &&
           filmBaseDensityBuffer &&
           filmSpectralDensityBuffer &&
           paperLogSensitivityBuffer &&
           thKg3IlluminantBuffer &&
           customEnlargerFiltersBuffer &&
           neutralPrintFiltersBuffer &&
           academyPrinterDensityDataBuffer &&
           paperScanDensityDataBuffer &&
           paperSpectralDensityBuffer &&
           scanIlluminantsAndCmfsBuffer &&
           scanProductsBuffer &&
           scanToOutputRgbDataBuffer &&
           colorEncodeLutBuffer;
  }

  void reset() {
    film = -1;
    paper = -1;
    cameraUvFilterEnabled = false;
    cameraUvCutNm = 410.0f;
    cameraIrFilterEnabled = false;
    cameraIrCutNm = 675.0f;
    filmCurves = nullptr;
    paperCurves = nullptr;
    curveInfo = {};
    paperCurveInfo = {};
    colorInfo = {};
    spectralInfo = {};
    curveInfoBuffer = nil;
    logExposureBuffer = nil;
    densityCurvesBuffer = nil;
    spectralInfoBuffer = nil;
    wavelengthsBuffer = nil;
    logSensitivityBuffer = nil;
    bandpassHanatosBuffer = nil;
    hanatosRawResponseBuffer = nil;
    paperHanatosResponseBuffer = nil;
    preflashPaperHanatosResponseBuffer = nil;
    mallettBasisIlluminantBuffer = nil;
    inputToReferenceXyzBuffer = nil;
    inputToSrgbBuffer = nil;
    colorInfoBuffer = nil;
    colorDecodeLutBuffer = nil;
    colorTransferKindBuffer = nil;
    paperCurveInfoBuffer = nil;
    paperLogExposureBuffer = nil;
    paperDensityCurvesBuffer = nil;
    filmChannelDensityBuffer = nil;
    filmBaseDensityBuffer = nil;
    filmSpectralDensityBuffer = nil;
    paperLogSensitivityBuffer = nil;
    thKg3IlluminantBuffer = nil;
    customEnlargerFiltersBuffer = nil;
    neutralPrintFiltersBuffer = nil;
    academyPrinterDensityDataBuffer = nil;
    paperScanDensityDataBuffer = nil;
    paperSpectralDensityBuffer = nil;
    scanIlluminantsAndCmfsBuffer = nil;
    scanProductsBuffer = nil;
    scanToOutputRgbDataBuffer = nil;
    colorEncodeLutBuffer = nil;
  }
};

float filmFormatMm(FilmFormat format) {
  switch (format) {
    case FilmFormat::Standard8:
      return 4.8f;
    case FilmFormat::Super8:
      return 5.79f;
    case FilmFormat::Standard16:
      return 10.26f;
    case FilmFormat::Super16:
      return 12.52f;
    case FilmFormat::Super35:
      return 24.89f;
    case FilmFormat::Standard65:
      return 52.48f;
    case FilmFormat::Imax70:
      return 70.41f;
    case FilmFormat::Standard35:
    default:
      return 35.0f;
  }
}

float effectiveGrainFinalBlurUm(const RenderParams &params) {
  const float formatScale = std::pow(std::max(filmFormatMm(params.filmFormat) / 35.0f, 1.0e-6f), 0.62f);
  return std::max(params.grainFinalBlurUm, 0.0f) * formatScale;
}

float scannerSigmaUmFromMtf50(float mtf50LpMm) {
  if (!std::isfinite(mtf50LpMm) || mtf50LpMm <= 0.0f) {
    return 0.0f;
  }
  constexpr float kPi = 3.14159265358979323846f;
  return 1000.0f * std::sqrt(std::log(2.0f) / (2.0f * kPi * kPi)) / mtf50LpMm;
}

uint32_t spektraHashCpu(uint32_t x) {
  x ^= x >> 16u;
  x *= 0x7feb352du;
  x ^= x >> 15u;
  x *= 0x846ca68bu;
  x ^= x >> 16u;
  return x;
}

float spektraRand01Cpu(uint32_t seed) {
  return (static_cast<float>(spektraHashCpu(seed) & 0x00ffffffu) + 0.5f) / 16777216.0f;
}

float wrapUnit(float value) {
  return value - std::floor(value);
}

float radicalInverseBase2(uint32_t bits) {
  bits = (bits << 16u) | (bits >> 16u);
  bits = ((bits & 0x55555555u) << 1u) | ((bits & 0xaaaaaaaau) >> 1u);
  bits = ((bits & 0x33333333u) << 2u) | ((bits & 0xccccccccu) >> 2u);
  bits = ((bits & 0x0f0f0f0fu) << 4u) | ((bits & 0xf0f0f0f0u) >> 4u);
  bits = ((bits & 0x00ff00ffu) << 8u) | ((bits & 0xff00ff00u) >> 8u);
  return static_cast<float>(bits) * 2.3283064365386963e-10f;
}

float sobol2Y(uint32_t index) {
  uint32_t x = 0u;
  for (uint32_t bit = 0u; index != 0u; index >>= 1u, ++bit) {
    if ((index & 1u) != 0u) {
      x ^= 0x80000000u >> bit;
      if (bit < 31u) {
        x ^= 0x40000000u >> (bit + 1u);
      }
    }
  }
  return static_cast<float>(x) * 2.3283064365386963e-10f;
}

float minDistanceFromCenterCellToOffset(int offset, float cellSize) {
  if (offset > 0) {
    return static_cast<float>(offset - 1) * cellSize;
  }
  if (offset < 0) {
    return static_cast<float>(-offset - 1) * cellSize;
  }
  return 0.0f;
}

float normalQuantile(float p) {
  p = std::clamp(p, 1.0e-6f, 1.0f - 1.0e-6f);
  constexpr float a1 = -3.969683028665376e+01f;
  constexpr float a2 = 2.209460984245205e+02f;
  constexpr float a3 = -2.759285104469687e+02f;
  constexpr float a4 = 1.383577518672690e+02f;
  constexpr float a5 = -3.066479806614716e+01f;
  constexpr float a6 = 2.506628277459239e+00f;
  constexpr float b1 = -5.447609879822406e+01f;
  constexpr float b2 = 1.615858368580409e+02f;
  constexpr float b3 = -1.556989798598866e+02f;
  constexpr float b4 = 6.680131188771972e+01f;
  constexpr float b5 = -1.328068155288572e+01f;
  constexpr float c1 = -7.784894002430293e-03f;
  constexpr float c2 = -3.223964580411365e-01f;
  constexpr float c3 = -2.400758277161838e+00f;
  constexpr float c4 = -2.549732539343734e+00f;
  constexpr float c5 = 4.374664141464968e+00f;
  constexpr float c6 = 2.938163982698783e+00f;
  constexpr float d1 = 7.784695709041462e-03f;
  constexpr float d2 = 3.224671290700398e-01f;
  constexpr float d3 = 2.445134137142996e+00f;
  constexpr float d4 = 3.754408661907416e+00f;
  constexpr float pLow = 0.02425f;
  constexpr float pHigh = 1.0f - pLow;
  if (p < pLow) {
    const float q = std::sqrt(-2.0f * std::log(p));
    return (((((c1 * q + c2) * q + c3) * q + c4) * q + c5) * q + c6) /
      ((((d1 * q + d2) * q + d3) * q + d4) * q + 1.0f);
  }
  if (p > pHigh) {
    const float q = std::sqrt(-2.0f * std::log(1.0f - p));
    return -(((((c1 * q + c2) * q + c3) * q + c4) * q + c5) * q + c6) /
      ((((d1 * q + d2) * q + d3) * q + d4) * q + 1.0f);
  }
  const float q = p - 0.5f;
  const float r = q * q;
  return (((((a1 * r + a2) * r + a3) * r + a4) * r + a5) * r + a6) * q /
    (((((b1 * r + b2) * r + b3) * r + b4) * r + b5) * r + 1.0f);
}

float grainSynthesisChannelScale(uint32_t channel, const KernelParams &params) {
  return std::max(
    channel == 0u ? params.grainSynthesisRadiusScaleR : (channel == 1u ? params.grainSynthesisRadiusScaleG : params.grainSynthesisRadiusScaleB),
    1.0e-6f
  );
}

float grainSynthesisLayerScale(uint32_t layer, const KernelParams &params) {
  if (params.grainSynthesisLayered == 0u) {
    return 1.0f;
  }
  return std::max(
    layer == 0u ? params.grainSynthesisLayerScale0 : (layer == 1u ? params.grainSynthesisLayerScale1 : params.grainSynthesisLayerScale2),
    1.0e-6f
  );
}

void buildGrainSynthesisTables(
  const KernelParams &params,
  GrainSynthesisSamplerMode samplerMode,
  uint32_t radiusLutSize,
  GrainSynthesisCellMode cellMode,
  std::array<KernelGrainSynthesisComponentInfo, kGrainSynthesisComponentCount> &componentInfo,
  std::array<KernelGrainSynthesisSampleOffset, kGrainSynthesisComponentCount * kGrainSynthesisMaxSamples> &sampleOffsets,
  std::vector<float> &radiusLut,
  std::vector<KernelGrainSynthesisCellOffset> &cellOffsets
) {
  componentInfo = {};
  sampleOffsets = {};
  radiusLut.clear();
  cellOffsets.clear();

  constexpr float kPi = 3.14159265359f;
  constexpr float kLn10 = 2.302585093f;
  constexpr float kR2AlphaX = 0.7548776662466927f;
  constexpr float kR2AlphaY = 0.5698402909980532f;
  const uint32_t requestedSamples = static_cast<uint32_t>(std::clamp(params.grainSynthesisSamples, 1, static_cast<int32_t>(kGrainSynthesisMaxSamples)));
  const float sigmaUm = std::max(params.grainSynthesisObservationSigmaUm, 0.0f);
  const uint32_t sampleCount = sigmaUm <= 1.0e-6f ? 1u : requestedSamples;
  const uint32_t frameSeed = params.grainAnimate != 0u
    ? static_cast<uint32_t>(std::floor(params.time * 24.0f + 0.5f))
    : 0u;

  for (uint32_t component = 0u; component < kGrainSynthesisComponentCount; ++component) {
    const uint32_t layer = component / 3u;
    const uint32_t channel = component - layer * 3u;
    KernelGrainSynthesisComponentInfo info{};
    info.active = (params.grainSynthesisLayered != 0u || layer == 0u) ? 1u : 0u;
    if (info.active == 0u) {
      componentInfo[component] = info;
      continue;
    }

    info.scaledMeanRadius = std::max(
      params.grainSynthesisMeanRadiusUm *
        grainSynthesisChannelScale(channel, params) *
        grainSynthesisLayerScale(layer, params),
      1.0e-6f
    );
    const float ratio = std::max(params.grainSynthesisRadiusStdDevRatio, 0.0f);
    if (ratio <= 1.0e-6f) {
      info.maxRadius = info.scaledMeanRadius;
      info.logMean = std::log(std::max(info.scaledMeanRadius, 1.0e-6f));
      info.logSigma = 0.0f;
    } else {
      info.logSigma = std::sqrt(std::log(1.0f + ratio * ratio));
      info.logMean = std::log(std::max(info.scaledMeanRadius, 1.0e-6f)) - 0.5f * info.logSigma * info.logSigma;
      info.maxRadius = std::max(
        std::exp(info.logMean + info.logSigma * normalQuantile(params.grainSynthesisMaxRadiusQuantile)),
        info.scaledMeanRadius
      );
    }
    info.maxRadiusSquared = info.maxRadius * info.maxRadius;
    info.cellSize = std::max(info.scaledMeanRadius * std::max(params.grainSynthesisCellSizeRatio, 0.05f), 1.0e-4f);
    info.invCellSize = 1.0f / info.cellSize;
    info.meanArea = kPi * info.scaledMeanRadius * info.scaledMeanRadius * (1.0f + ratio * ratio);
    info.cellArea = info.cellSize * info.cellSize;
    info.densityToLambda = kLn10 / std::max(info.meanArea, 1.0e-12f);
    info.grainCap = static_cast<uint32_t>(std::clamp(params.grainSynthesisMaxGrainsPerCell, 1, 128));
    info.cellScanRadius = std::max<uint32_t>(1u, static_cast<uint32_t>(std::ceil(info.maxRadius * info.invCellSize)));
    info.sampleCount = sampleCount;
    info.samplerMode = static_cast<uint32_t>(samplerMode);
    if (radiusLutSize > 0u && info.logSigma > 1.0e-6f) {
      info.radiusLutOffset = static_cast<uint32_t>(radiusLut.size());
      info.radiusLutSize = std::min<uint32_t>(radiusLutSize, 512u);
      radiusLut.reserve(radiusLut.size() + info.radiusLutSize);
      for (uint32_t i = 0u; i < info.radiusLutSize; ++i) {
        const float u = (static_cast<float>(i) + 0.5f) / static_cast<float>(info.radiusLutSize);
        radiusLut.push_back(std::min(std::exp(info.logMean + info.logSigma * normalQuantile(u)), info.maxRadius));
      }
    }
    if (cellMode != GrainSynthesisCellMode::Current) {
      const int scanRadius = static_cast<int>(info.cellScanRadius);
      const int side = scanRadius * 2 + 1;
      if (side * side <= static_cast<int>(kGrainSynthesisMaxCellOffsetsPerComponent)) {
        info.cellOffsetStart = static_cast<uint32_t>(cellOffsets.size());
        for (int dy = -scanRadius; dy <= scanRadius; ++dy) {
          for (int dx = -scanRadius; dx <= scanRadius; ++dx) {
            const float minDx = minDistanceFromCenterCellToOffset(dx, info.cellSize);
            const float minDy = minDistanceFromCenterCellToOffset(dy, info.cellSize);
            if (minDx * minDx + minDy * minDy <= info.maxRadiusSquared) {
              cellOffsets.push_back({dx, dy});
            }
          }
        }
        std::sort(cellOffsets.begin() + info.cellOffsetStart, cellOffsets.end(), [](const auto &a, const auto &b) {
          const int da = a.x * a.x + a.y * a.y;
          const int db = b.x * b.x + b.y * b.y;
          return da < db;
        });
        info.cellOffsetCount = static_cast<uint32_t>(cellOffsets.size()) - info.cellOffsetStart;
      }
    }
    componentInfo[component] = info;

    const uint32_t seedBase = spektraHashCpu(
      params.grainSeed ^ frameSeed ^ (channel * 0x85ebca6bu) ^ (layer * 0xc2b2ae35u)
    );
    const float shiftX = spektraRand01Cpu(seedBase ^ 0x23d3c1f1u);
    const float shiftY = spektraRand01Cpu(seedBase ^ 0xa349b329u);
    for (uint32_t sample = 0u; sample < sampleCount; ++sample) {
      float u = 0.5f;
      float v = 0.5f;
      if (samplerMode == GrainSynthesisSamplerMode::SobolBlue) {
        const uint32_t scrambleX = spektraHashCpu(seedBase ^ 0x68bc21ebu);
        const uint32_t scrambleY = spektraHashCpu(seedBase ^ 0x02e5be93u);
        u = wrapUnit(radicalInverseBase2(sample ^ scrambleX) + shiftX);
        v = wrapUnit(sobol2Y(sample ^ scrambleY) + shiftY);
      } else if (samplerMode == GrainSynthesisSamplerMode::Antithetic) {
        const uint32_t pairIndex = sample / 2u;
        u = wrapUnit(shiftX + (static_cast<float>(pairIndex) + 0.5f) * kR2AlphaX);
        v = wrapUnit(shiftY + (static_cast<float>(pairIndex) + 0.5f) * kR2AlphaY);
      } else {
        u = wrapUnit(shiftX + (static_cast<float>(sample) + 0.5f) * kR2AlphaX);
        v = wrapUnit(shiftY + (static_cast<float>(sample) + 0.5f) * kR2AlphaY);
      }
      KernelGrainSynthesisSampleOffset &offset = sampleOffsets[component * kGrainSynthesisMaxSamples + sample];
      offset.x = normalQuantile(u) * sigmaUm;
      offset.y = normalQuantile(v) * sigmaUm;
      if (samplerMode == GrainSynthesisSamplerMode::Antithetic && (sample & 1u) != 0u) {
        offset.x = -offset.x;
        offset.y = -offset.y;
      }
    }
  }
}

float filmPushPullGamma(float stops) {
  const float clampedStops = std::clamp(stops, -2.0f, 2.0f);
  constexpr float kNormalEcn2Seconds = 180.0f;
  constexpr float kPull1Seconds = 150.0f;
  constexpr float kPush1Seconds = 220.0f;
  constexpr float kPush2Seconds = 280.0f;
  if (clampedStops < 0.0f) {
    return std::pow(kPull1Seconds / kNormalEcn2Seconds, -clampedStops);
  }
  if (clampedStops <= 1.0f) {
    return std::exp(std::log(kPush1Seconds / kNormalEcn2Seconds) * clampedStops);
  }
  const float segment = clampedStops - 1.0f;
  return std::exp(
    std::log(kPush1Seconds / kNormalEcn2Seconds) +
    std::log(kPush2Seconds / kPush1Seconds) * segment
  );
}

float printPushPullGamma(float stops) {
  const float clampedStops = std::clamp(stops, -2.0f, 2.0f);
  return std::exp2(clampedStops * 0.25f);
}

float enlargerScale(const RenderParams &params) {
  return std::clamp(params.enlargerScale, 1.0f, 32.0f);
}

bool enlargerTransformActive(const RenderParams &params) {
  return std::abs(enlargerScale(params) - 1.0f) > 1.0e-6f;
}

KernelParams toKernelParams(const RenderParams &params, double time, int32_t width, int32_t height) {
  KernelParams out{};
  out.process = static_cast<int32_t>(params.process);
  out.rgbToRawMethod = static_cast<int32_t>(params.rgbToRawMethod);
  out.inputColorSpace = static_cast<int32_t>(params.inputColorSpace);
  out.outputColorSpace = static_cast<int32_t>(params.outputColorSpace);
  out.outputRole = static_cast<int32_t>(params.outputRole);
  out.hdrPreset = static_cast<int32_t>(params.hdrPreset);
  out.hdrTransfer = static_cast<int32_t>(params.hdrTransfer);
  out.hdrReferenceWhiteNits = params.hdrReferenceWhiteNits;
  out.hdrPeakNits = params.hdrPeakNits;
  out.hdrExposureEv = params.hdrExposureEv;
  out.hdrToneMapping = static_cast<int32_t>(params.hdrToneMapping);
  out.colorAdaptationFlags = colorAdaptationFlags(params);
  out.film = params.film;
  out.paper = params.paper;
  out.printTiming = static_cast<int32_t>(params.printTiming);
  out.filmExposureEv = params.filmExposureEv;
  out.autoExposureEnabled = params.autoExposure ? 1u : 0u;
  out.autoExposureMethod = static_cast<int32_t>(params.autoExposureMethod);
  out.autoExposureEv = 0.0f;
  out.printExposureEv = params.printExposureEv;
  out.filmPushPullMode = static_cast<int32_t>(params.filmPushPullMode);
  out.filmPushPullStops = params.filmPushPullStops;
  out.printPushPullMode = 0;
  out.printPushPullStops = params.printPushPullStops;
  out.negativeBleachBypassAmount = params.negativeBleachBypassAmount;
  out.negativeLeucoCyanCoupling = params.negativeLeucoCyanCoupling;
  out.printBleachBypassAmount = params.printBleachBypassAmount;
  out.scanNegativeInvert = params.scanNegativeInvert ? 1u : 0u;
  out.filmGamma = params.filmPushPullMode == PushPullMode::Experimental
    ? params.filmGamma
    : params.filmGamma * filmPushPullGamma(params.filmPushPullStops);
  out.printGamma = params.printGamma * printPushPullGamma(params.printPushPullStops);
  out.printShadowShape = params.printShadowShape;
  out.printHighlightShape = params.printHighlightShape;
  out.filterC = params.filterC;
  out.filterMShift = params.filterMShift;
  out.filterYShift = params.filterYShift;
  out.enlargerScale = enlargerScale(params);
  out.enlargerOffsetXPercent = params.enlargerOffsetXPercent;
  out.enlargerOffsetYPercent = params.enlargerOffsetYPercent;
  out.preflashExposure = params.preflashExposure;
  out.preflashMFilterShift = params.preflashMFilterShift;
  out.preflashYFilterShift = params.preflashYFilterShift;
  out.printerLightsR = params.printerLightsR;
  out.printerLightsG = params.printerLightsG;
  out.printerLightsB = params.printerLightsB;
  out.printerLightsGang = params.printerLightsGang ? 1u : 0u;
  out.printerLightCalibration = params.printerLightCalibration ? 1u : 0u;
  out.dirCouplersAmount = params.dirCouplersAmount;
  out.dirCouplersDiffusionUm = params.dirCouplersDiffusionUm;
  out.dirCouplersDiffusionTailUm = params.dirCouplersDiffusionTailUm;
  out.dirCouplersDiffusionTailWeight = params.dirCouplersDiffusionTailWeight;
  out.grainEnabled = params.grainEnabled ? 1u : 0u;
  out.grainModel = static_cast<int32_t>(params.grainModel);
  out.filmFormat = static_cast<int32_t>(params.filmFormat);
  out.grainAmount = params.grainAmount;
  out.grainSaturation = params.grainSaturation;
  out.grainSublayersEnabled = params.grainSublayersEnabled ? 1u : 0u;
  out.grainSubLayerCount = std::max(1, params.grainSubLayerCount);
  out.grainParticleAreaUm2 = params.grainParticleAreaUm2;
  out.grainParticleScaleR = params.grainParticleScaleR;
  out.grainParticleScaleG = params.grainParticleScaleG;
  out.grainParticleScaleB = params.grainParticleScaleB;
  out.grainParticleScaleLayer0 = params.grainParticleScaleLayer0;
  out.grainParticleScaleLayer1 = params.grainParticleScaleLayer1;
  out.grainParticleScaleLayer2 = params.grainParticleScaleLayer2;
  out.grainDensityMinR = params.grainDensityMinR;
  out.grainDensityMinG = params.grainDensityMinG;
  out.grainDensityMinB = params.grainDensityMinB;
  out.grainUniformityR = params.grainUniformityR;
  out.grainUniformityG = params.grainUniformityG;
  out.grainUniformityB = params.grainUniformityB;
  out.grainFinalBlurUm = params.grainFinalBlurUm;
  out.grainBlurDyeCloudsUm = params.grainBlurDyeCloudsUm;
  out.grainMicroStructureScale = params.grainMicroStructureScale;
  out.grainMicroStructureSigmaNm = params.grainMicroStructureSigmaNm;
  out.grainSeed = params.grainSeed;
  out.grainAnimate = params.grainAnimate ? 1u : 0u;
  const int32_t filmReferencePixels = std::max(width, height);
  out.filmPixelSizeUm = filmFormatMm(params.filmFormat) * 1000.0f /
    static_cast<float>(std::max(filmReferencePixels, 1)) / out.enlargerScale;
  const float grainSynthesisQuality = std::clamp(params.grainSynthesisQuality, 0.25f, 4.0f);
  const float grainSynthesisSize = std::clamp(params.grainSynthesisSize, 0.25f, 4.0f);
  const float grainSynthesisSharpness = std::max(params.grainSynthesisSharpness, 0.25f);
  out.grainSynthesisSamples = std::clamp(
    static_cast<int32_t>(std::lround(static_cast<float>(params.grainSynthesisSamples) * grainSynthesisQuality)),
    1,
    1024
  );
  out.grainSynthesisAmount = std::clamp(params.grainSynthesisAmount, 0.0f, 3.0f);
  out.grainSynthesisMeanRadiusUm = params.grainSynthesisMeanRadiusUm * grainSynthesisSize;
  out.grainSynthesisRadiusStdDevRatio = params.grainSynthesisRadiusStdDevRatio;
  out.grainSynthesisObservationSigmaUm = params.grainSynthesisObservationSigmaUm / grainSynthesisSharpness;
  out.grainSynthesisCellSizeRatio = params.grainSynthesisCellSizeRatio;
  out.grainSynthesisMaxRadiusQuantile = params.grainSynthesisMaxRadiusQuantile;
  out.grainSynthesisCoverageEpsilon = params.grainSynthesisCoverageEpsilon;
  out.grainSynthesisMaxGrainsPerCell = std::clamp(params.grainSynthesisMaxGrainsPerCell, 1, 128);
  out.grainSynthesisRadiusScaleR = params.grainSynthesisRadiusScaleR;
  out.grainSynthesisRadiusScaleG = params.grainSynthesisRadiusScaleG;
  out.grainSynthesisRadiusScaleB = params.grainSynthesisRadiusScaleB;
  out.grainSynthesisLayerScale0 = params.grainSynthesisLayerScale0;
  out.grainSynthesisLayerScale1 = params.grainSynthesisLayerScale1;
  out.grainSynthesisLayerScale2 = params.grainSynthesisLayerScale2;
  out.grainSynthesisLayered = params.grainSynthesisLayered ? 1u : 0u;
  out.halationEnabled = params.halationEnabled ? 1u : 0u;
  out.scatterAmount = params.scatterAmount;
  out.scatterScale = params.scatterScale;
  out.halationAmount = params.halationAmount;
  out.halationScale = params.halationScale;
  out.halationStrengthR = params.halationStrengthR;
  out.halationStrengthG = params.halationStrengthG;
  out.halationStrengthB = params.halationStrengthB;
  out.halationFirstSigmaUmR = params.halationFirstSigmaUmR;
  out.halationFirstSigmaUmG = params.halationFirstSigmaUmG;
  out.halationFirstSigmaUmB = params.halationFirstSigmaUmB;
  out.halationBoostEv = params.halationBoostEv;
  out.halationBoostRange = params.halationBoostRange;
  out.halationProtectEv = params.halationProtectEv;
  out.cameraDiffusionEnabled = params.cameraDiffusionEnabled ? 1u : 0u;
  out.cameraDiffusionFamily = static_cast<int32_t>(params.cameraDiffusionFamily);
  out.cameraDiffusionStrength = params.cameraDiffusionStrength;
  out.cameraDiffusionSpatialScale = params.cameraDiffusionSpatialScale;
  out.cameraDiffusionHaloWarmth = params.cameraDiffusionHaloWarmth;
  out.cameraDiffusionCoreIntensity = params.cameraDiffusionCoreIntensity;
  out.cameraDiffusionCoreSize = params.cameraDiffusionCoreSize;
  out.cameraDiffusionHaloIntensity = params.cameraDiffusionHaloIntensity;
  out.cameraDiffusionHaloSize = params.cameraDiffusionHaloSize;
  out.cameraDiffusionBloomIntensity = params.cameraDiffusionBloomIntensity;
  out.cameraDiffusionBloomSize = params.cameraDiffusionBloomSize;
  out.printDiffusionEnabled = params.printDiffusionEnabled ? 1u : 0u;
  out.printDiffusionFamily = static_cast<int32_t>(params.printDiffusionFamily);
  out.printDiffusionStrength = params.printDiffusionStrength;
  out.printDiffusionSpatialScale = params.printDiffusionSpatialScale;
  out.printDiffusionHaloWarmth = params.printDiffusionHaloWarmth;
  out.printDiffusionCoreIntensity = params.printDiffusionCoreIntensity;
  out.printDiffusionCoreSize = params.printDiffusionCoreSize;
  out.printDiffusionHaloIntensity = params.printDiffusionHaloIntensity;
  out.printDiffusionHaloSize = params.printDiffusionHaloSize;
  out.printDiffusionBloomIntensity = params.printDiffusionBloomIntensity;
  out.printDiffusionBloomSize = params.printDiffusionBloomSize;
  out.scannerEnabled = params.scannerEnabled ? 1u : 0u;
  out.scannerWhiteCorrection = params.scannerWhiteCorrection ? 1u : 0u;
  out.scannerBlackCorrection = params.scannerBlackCorrection ? 1u : 0u;
  out.scannerWhiteLevel = params.scannerWhiteLevel;
  out.scannerBlackLevel = params.scannerBlackLevel;
  out.glarePercent = params.glarePercent;
  out.glareRoughness = params.glareRoughness;
  out.glareBlur = params.glareBlur;
  out.scannerBlurSigmaPx = scannerSigmaUmFromMtf50(params.scannerMtf50LpMm) / std::max(out.filmPixelSizeUm, 1.0e-6f);
  out.scannerUnsharpSigmaPx = std::max(params.scannerUnsharpRadiusUm, 0.0f) / std::max(out.filmPixelSizeUm, 1.0e-6f);
  out.scannerUnsharpAmount = params.scannerUnsharpAmount;
  out.time = static_cast<float>(time);
  return out;
}

bool isDefaultHalationStrength(const RenderParams &params) {
  return std::abs(params.halationStrengthR - 0.05f) <= 1.0e-6f &&
         std::abs(params.halationStrengthG - 0.015f) <= 1.0e-6f &&
         std::abs(params.halationStrengthB) <= 1.0e-6f;
}

void applyProfileHalationDefaults(KernelParams &kernelParams, const RenderParams &params, const ProfileCurveSet &filmCurves) {
  if (filmCurves.halationFirstSigmaUm) {
    kernelParams.halationFirstSigmaUmR = filmCurves.halationFirstSigmaUm[0];
    kernelParams.halationFirstSigmaUmG = filmCurves.halationFirstSigmaUm[1];
    kernelParams.halationFirstSigmaUmB = filmCurves.halationFirstSigmaUm[2];
  }
  if (filmCurves.halationStrength && isDefaultHalationStrength(params)) {
    kernelParams.halationStrengthR = filmCurves.halationStrength[0];
    kernelParams.halationStrengthG = filmCurves.halationStrength[1];
    kernelParams.halationStrengthB = filmCurves.halationStrength[2];
  }
}

struct DiffusionGroup {
  float lambdaUm;
  float spread;
  uint32_t count;
  float alpha;
};

struct DiffusionFamilyShape {
  DiffusionGroup core;
  DiffusionGroup halo;
  DiffusionGroup bloom;
  float weightCore;
  float weightHalo;
  float weightBloom;
  float warmthBase;
  float totalGain;
};

struct DiffusionSettings {
  DiffusionFilterFamily family = DiffusionFilterFamily::BlackProMist;
  float strength = 0.5f;
  float spatialScale = 1.0f;
  float haloWarmth = 0.0f;
  float coreIntensity = 1.0f;
  float coreSize = 1.0f;
  float haloIntensity = 1.0f;
  float haloSize = 1.0f;
  float bloomIntensity = 1.0f;
  float bloomSize = 1.0f;
};

DiffusionFamilyShape diffusionShape(DiffusionFilterFamily family) {
  switch (family) {
    case DiffusionFilterFamily::Glimmerglass:
      return {{10.0f, 1.5f, 2u, 3.0f}, {50.0f, 2.0f, 3u, 3.0f}, {260.0f, 2.5f, 4u, 3.2f}, 0.60f, 0.30f, 0.10f, 0.0f, 0.65f};
    case DiffusionFilterFamily::ProMist:
      return {{14.0f, 1.5f, 2u, 3.0f}, {150.0f, 2.0f, 3u, 3.0f}, {650.0f, 2.5f, 4u, 2.9f}, 0.28f, 0.42f, 0.30f, 0.40f, 1.05f};
    case DiffusionFilterFamily::CineBloom:
      return {{20.0f, 1.5f, 2u, 3.0f}, {200.0f, 2.0f, 3u, 3.0f}, {1000.0f, 2.5f, 4u, 2.5f}, 0.22f, 0.30f, 0.48f, 0.85f, 1.00f};
    case DiffusionFilterFamily::BlackProMist:
    default:
      return {{16.0f, 1.5f, 2u, 3.0f}, {95.0f, 2.0f, 3u, 3.0f}, {380.0f, 2.5f, 4u, 3.5f}, 0.40f, 0.47f, 0.13f, 0.65f, 0.75f};
  }
}

float diffusionScatterFraction(float strength, float familyGain) {
  if (strength <= 0.0f) {
    return 0.0f;
  }
  constexpr std::array<float, 5> kBreaks = {0.125f, 0.25f, 0.5f, 1.0f, 2.0f};
  constexpr std::array<float, 5> kFractions = {0.10f, 0.20f, 0.35f, 0.55f, 0.75f};
  const float logStrength = std::log2(std::max(strength, 1.0e-6f));
  if (logStrength <= std::log2(kBreaks.front())) {
    return std::clamp(kFractions.front() * familyGain, 0.0f, 0.99f);
  }
  if (logStrength >= std::log2(kBreaks.back())) {
    return std::clamp(kFractions.back() * familyGain, 0.0f, 0.99f);
  }
  for (size_t i = 0; i + 1u < kBreaks.size(); ++i) {
    const float x0 = std::log2(kBreaks[i]);
    const float x1 = std::log2(kBreaks[i + 1u]);
    if (logStrength >= x0 && logStrength <= x1) {
      const float t = std::clamp((logStrength - x0) / std::max(x1 - x0, 1.0e-6f), 0.0f, 1.0f);
      return std::clamp((kFractions[i] + (kFractions[i + 1u] - kFractions[i]) * t) * familyGain, 0.0f, 0.99f);
    }
  }
  return 0.0f;
}

std::vector<float> diffusionLambdas(const DiffusionGroup &group) {
  std::vector<float> lambdas(group.count, group.lambdaUm);
  if (group.count <= 1u || group.spread <= 1.0f) {
    return lambdas;
  }
  const float logLo = std::log(group.lambdaUm / group.spread);
  const float logHi = std::log(group.lambdaUm * group.spread);
  for (uint32_t i = 0; i < group.count; ++i) {
    const float t = group.count == 1u ? 0.0f : static_cast<float>(i) / static_cast<float>(group.count - 1u);
    lambdas[i] = std::exp(logLo + (logHi - logLo) * t);
  }
  return lambdas;
}

std::vector<float> diffusionWeights(const DiffusionGroup &group, bool bloom) {
  const std::vector<float> lambdas = diffusionLambdas(group);
  std::vector<float> weights(lambdas.size(), 1.0f);
  if (bloom) {
    for (size_t i = 0; i < weights.size(); ++i) {
      weights[i] = std::pow(std::max(lambdas[i], 1.0e-6f), 2.0f - group.alpha);
    }
  }
  float sum = 0.0f;
  for (float weight : weights) {
    sum += weight;
  }
  for (float &weight : weights) {
    weight /= std::max(sum, 1.0e-6f);
  }
  return weights;
}

std::array<std::vector<float>, 3> haloChannelWeights(const std::vector<float> &weights, float warmth) {
  constexpr std::array<float, 3> kWarmthAxis = {1.30f, 0.15f, -1.45f};
  std::array<std::vector<float>, 3> out;
  const size_t count = weights.size();
  for (auto &channel : out) {
    channel = weights;
  }
  if (count < 2u) {
    return out;
  }
  warmth = std::clamp(warmth, -1.5f, 1.5f);
  std::vector<float> gradient(count, 0.0f);
  float totalWeight = 0.0f;
  float weightedGradient = 0.0f;
  for (size_t i = 0; i < count; ++i) {
    gradient[i] = -1.0f + 2.0f * static_cast<float>(i) / static_cast<float>(count - 1u);
    totalWeight += weights[i];
    weightedGradient += weights[i] * gradient[i];
  }
  const float gradientMean = weightedGradient / std::max(totalWeight, 1.0e-6f);
  for (size_t i = 0; i < count; ++i) {
    gradient[i] -= gradientMean;
  }
  for (size_t channel = 0; channel < 3u; ++channel) {
    float sum = 0.0f;
    for (size_t i = 0; i < count; ++i) {
      out[channel][i] = std::max(weights[i] * (1.0f + warmth * kWarmthAxis[channel] * gradient[i]), 0.0f);
      sum += out[channel][i];
    }
    for (size_t i = 0; i < count; ++i) {
      out[channel][i] *= totalWeight / std::max(sum, 1.0e-6f);
    }
  }
  return out;
}

void appendDiffusionGroupComponents(
  std::vector<KernelDiffusionComponent> &components,
  const DiffusionGroup &group,
  const std::vector<float> &weights,
  const std::array<float, 3> &channelScale,
  float groupWeight,
  float spatialScale,
  float pixelSizeUm
) {
  constexpr std::array<std::array<float, 2>, 3> kExpGaussianFit = {{
    {0.1633f, 0.5360f},
    {0.6496f, 1.5236f},
    {0.1870f, 2.7684f},
  }};
  const std::vector<float> lambdas = diffusionLambdas(group);
  for (size_t i = 0; i < lambdas.size(); ++i) {
    for (const auto &fit : kExpGaussianFit) {
      const float sigmaPx = std::max(lambdas[i] * fit[1] * spatialScale / std::max(pixelSizeUm, 1.0e-6f), 1.0e-6f);
      const float weight = groupWeight * weights[i] * fit[0];
      const float weightR = weight * channelScale[0];
      const float weightG = weight * channelScale[1];
      const float weightB = weight * channelScale[2];
      if (weightR == 0.0f && weightG == 0.0f && weightB == 0.0f) {
        continue;
      }
      components.push_back({
        sigmaPx,
        weightR,
        weightG,
        weightB,
      });
    }
  }
}

void clusterDiffusionComponents(std::vector<KernelDiffusionComponent> &components, float sigmaRatio) {
  if (components.size() < 2u || sigmaRatio <= 0.0f) {
    return;
  }
  std::sort(
    components.begin(),
    components.end(),
    [](const KernelDiffusionComponent &a, const KernelDiffusionComponent &b) {
      return a.sigmaPx < b.sigmaPx;
    }
  );
  std::vector<KernelDiffusionComponent> clustered;
  clustered.reserve(components.size());
  for (const KernelDiffusionComponent &component : components) {
    if (clustered.empty()) {
      clustered.push_back(component);
      continue;
    }
    KernelDiffusionComponent &last = clustered.back();
    const float denom = std::max(std::max(last.sigmaPx, component.sigmaPx), 1.0e-6f);
    if (std::abs(component.sigmaPx - last.sigmaPx) / denom <= sigmaRatio) {
      const float lastWeight = std::abs(last.weightR) + std::abs(last.weightG) + std::abs(last.weightB);
      const float componentWeight = std::abs(component.weightR) + std::abs(component.weightG) + std::abs(component.weightB);
      const float totalWeight = lastWeight + componentWeight;
      if (totalWeight > 1.0e-8f) {
        last.sigmaPx = (last.sigmaPx * lastWeight + component.sigmaPx * componentWeight) / totalWeight;
      }
      last.weightR += component.weightR;
      last.weightG += component.weightG;
      last.weightB += component.weightB;
    } else {
      clustered.push_back(component);
    }
  }
  components.swap(clustered);
}

uint32_t diffusionDownsampleScaleForSigma(const std::string &mode, float sigmaPx) {
  if (mode == "off") {
    return 1u;
  }
  if (mode == "auto") {
    if (sigmaPx >= 48.0f) {
      return 8u;
    }
    if (sigmaPx >= 24.0f) {
      return 4u;
    }
    if (sigmaPx >= 12.0f) {
      return 2u;
    }
    return 1u;
  }
  if (mode == "8") {
    return sigmaPx >= 48.0f ? 8u : 1u;
  }
  if (mode == "4") {
    return sigmaPx >= 24.0f ? 4u : 1u;
  }
  if (mode == "2") {
    return sigmaPx >= 12.0f ? 2u : 1u;
  }
  return 1u;
}

bool anyDiffusionComponentDownsamples(const std::vector<KernelDiffusionComponent> &components, const std::string &mode) {
  for (const KernelDiffusionComponent &component : components) {
    if (diffusionDownsampleScaleForSigma(mode, component.sigmaPx) > 1u) {
      return true;
    }
  }
  return false;
}

std::vector<KernelDiffusionComponent> makeDiffusionComponents(
  const DiffusionSettings &settings,
  float pixelSizeUm,
  KernelDiffusionInfo &info,
  float clusterSigmaRatio = 0.0f
) {
  DiffusionFamilyShape shape = diffusionShape(settings.family);
  const float coreIntensity = std::max(settings.coreIntensity, 0.0f);
  const float haloIntensity = std::max(settings.haloIntensity, 0.0f);
  const float bloomIntensity = std::max(settings.bloomIntensity, 0.0f);
  float wc = shape.weightCore * coreIntensity;
  float wh = shape.weightHalo * haloIntensity;
  float wb = shape.weightBloom * bloomIntensity;
  const float total = wc + wh + wb;
  if (total > 0.0f) {
    wc /= total;
    wh /= total;
    wb /= total;
  } else {
    info.scatterFraction = 0.0f;
    info.componentCount = 0u;
    return {};
  }
  shape.core.lambdaUm *= std::max(settings.coreSize, 1.0e-6f);
  shape.halo.lambdaUm *= std::max(settings.haloSize, 1.0e-6f);
  shape.bloom.lambdaUm *= std::max(settings.bloomSize, 1.0e-6f);

  info.scatterFraction = diffusionScatterFraction(settings.strength, shape.totalGain);
  std::vector<KernelDiffusionComponent> components;
  if (info.scatterFraction <= 0.0f || settings.spatialScale <= 0.0f) {
    info.componentCount = 0u;
    return components;
  }

  appendDiffusionGroupComponents(
    components,
    shape.core,
    diffusionWeights(shape.core, false),
    {1.0f, 1.0f, 1.0f},
    wc,
    settings.spatialScale,
    pixelSizeUm
  );

  const std::vector<float> haloWeights = diffusionWeights(shape.halo, false);
  const auto haloPerChannel = haloChannelWeights(haloWeights, shape.warmthBase + settings.haloWarmth);
  const std::vector<float> haloLambdas = diffusionLambdas(shape.halo);
  constexpr std::array<std::array<float, 2>, 3> kExpGaussianFit = {{
    {0.1633f, 0.5360f},
    {0.6496f, 1.5236f},
    {0.1870f, 2.7684f},
  }};
  for (size_t i = 0; i < haloLambdas.size(); ++i) {
    for (const auto &fit : kExpGaussianFit) {
      const float sigmaPx = std::max(haloLambdas[i] * fit[1] * settings.spatialScale / std::max(pixelSizeUm, 1.0e-6f), 1.0e-6f);
      const float weightR = wh * haloPerChannel[0][i] * fit[0];
      const float weightG = wh * haloPerChannel[1][i] * fit[0];
      const float weightB = wh * haloPerChannel[2][i] * fit[0];
      if (weightR == 0.0f && weightG == 0.0f && weightB == 0.0f) {
        continue;
      }
      components.push_back({
        sigmaPx,
        weightR,
        weightG,
        weightB,
      });
    }
  }

  appendDiffusionGroupComponents(
    components,
    shape.bloom,
    diffusionWeights(shape.bloom, true),
    {1.0f, 1.0f, 1.0f},
    wb,
    settings.spatialScale,
    pixelSizeUm
  );

  clusterDiffusionComponents(components, clusterSigmaRatio);
  info.componentCount = static_cast<uint32_t>(components.size());
  return components;
}

const ProfileCurveSet *selectedFilmCurves(const RenderParams &params) {
  const ProfileCurveSet *curves = filmProfileCurves(params.film);
  return curves ? curves : filmProfileCurves(static_cast<int32_t>(kSpektraDefaultFilmIndex));
}

const ProfileCurveSet *selectedPaperCurves(const RenderParams &params) {
  const ProfileCurveSet *curves = paperProfileCurves(params.paper);
  return curves ? curves : paperProfileCurves(static_cast<int32_t>(kSpektraDefaultPaperIndex));
}

std::vector<float> makeLinearSensitivity(const float *logSensitivity, uint32_t wavelengthCount) {
  std::vector<float> linear(static_cast<size_t>(wavelengthCount) * 3u, 0.0f);
  if (!logSensitivity) {
    return linear;
  }
  for (uint32_t i = 0; i < wavelengthCount * 3u; ++i) {
    const float value = std::pow(10.0f, logSensitivity[i]);
    linear[i] = std::isfinite(value) ? value : 0.0f;
  }
  return linear;
}

std::vector<float> makePackedSpectralDensity(
  const float *channelDensity,
  const float *baseDensity,
  uint32_t wavelengthCount
) {
  std::vector<float> packed(static_cast<size_t>(wavelengthCount) * 4u, 0.0f);
  for (uint32_t wavelength = 0u; wavelength < wavelengthCount; ++wavelength) {
    const size_t sourceOffset = static_cast<size_t>(wavelength) * 3u;
    const size_t packedOffset = static_cast<size_t>(wavelength) * 4u;
    packed[packedOffset] = channelDensity[sourceOffset];
    packed[packedOffset + 1u] = channelDensity[sourceOffset + 1u];
    packed[packedOffset + 2u] = channelDensity[sourceOffset + 2u];
    packed[packedOffset + 3u] = baseDensity[wavelength];
  }
  return packed;
}

std::vector<float> makePackedCurveExposure(const float *logExposure, uint32_t exposureCount) {
  std::vector<float> packed(static_cast<size_t>(exposureCount) * 2u, 0.0f);
  for (uint32_t index = 0u; index < exposureCount; ++index) {
    const size_t packedOffset = static_cast<size_t>(index) * 2u;
    packed[packedOffset] = logExposure[index];
    if (index + 1u < exposureCount) {
      packed[packedOffset + 1u] = 1.0f / std::max(logExposure[index + 1u] - logExposure[index], 1.0e-9f);
    }
  }
  return packed;
}

std::vector<float> makeScanProducts(
  const float *filmIlluminant,
  const float *paperIlluminant,
  const float *filmBaseDensity,
  const float *paperBaseDensity,
  const float *cmfs,
  uint32_t wavelengthCount
) {
  const size_t packedFloatCount = static_cast<size_t>(wavelengthCount) * 8u;
  const size_t legacyFloatCount = static_cast<size_t>(wavelengthCount) * 6u;
  std::vector<float> products(packedFloatCount + legacyFloatCount + 2u, 0.0f);
  const float *illuminants[] = {filmIlluminant, paperIlluminant};
  const float *baseDensities[] = {filmBaseDensity, paperBaseDensity};
  for (uint32_t stage = 0u; stage < 2u; ++stage) {
    float normalization = 0.0f;
    const size_t packedStageOffset = static_cast<size_t>(stage) * wavelengthCount * 4u;
    const size_t legacyStageOffset = packedFloatCount + static_cast<size_t>(stage) * wavelengthCount * 3u;
    for (uint32_t wavelength = 0u; wavelength < wavelengthCount; ++wavelength) {
      const size_t channelOffset = static_cast<size_t>(wavelength) * 3u;
      const size_t packedOffset = packedStageOffset + static_cast<size_t>(wavelength) * 4u;
      const size_t legacyOffset = legacyStageOffset + channelOffset;
      const float illuminant = illuminants[stage][wavelength];
      const float baseTransmittanceRaw = std::pow(10.0f, -baseDensities[stage][wavelength]);
      const float baseTransmittance = std::isfinite(baseTransmittanceRaw) ? baseTransmittanceRaw : 0.0f;
      for (uint32_t channel = 0u; channel < 3u; ++channel) {
        const float product = illuminant * cmfs[channelOffset + channel];
        products[packedOffset + channel] = baseTransmittance * product;
        products[legacyOffset + channel] = product;
      }
      normalization += products[legacyOffset + 1u];
    }
    products[packedFloatCount + legacyFloatCount + stage] =
      1.0f / std::max(normalization, 1.0e-10f);
  }
  return products;
}

float smoothErfEdge(float wavelength, float center, float width) {
  return std::erf((wavelength - center) / width) * 0.5f + 0.5f;
}

std::vector<float> applyCameraBandPass(
  const ProfileCurveSet &filmCurves,
  const std::vector<float> &linearSensitivity,
  const RenderParams &params
) {
  std::vector<float> filtered = linearSensitivity;
  if (!filmCurves.wavelengths ||
      filtered.size() < static_cast<size_t>(filmCurves.wavelengthCount) * 3u ||
      (!params.cameraUvFilterEnabled && !params.cameraIrFilterEnabled)) {
    return filtered;
  }

  constexpr float kPythonUvTransitionNm = 8.0f;
  constexpr float kPythonIrTransitionNm = 15.0f;
  std::array<float, 3> numerator = {0.0f, 0.0f, 0.0f};
  std::array<float, 3> denominator = {0.0f, 0.0f, 0.0f};
  std::vector<float> transmissionByWavelength(filmCurves.wavelengthCount, 1.0f);
  for (uint32_t wavelength = 0; wavelength < filmCurves.wavelengthCount; ++wavelength) {
    const float wl = filmCurves.wavelengths[wavelength];
    const float uvTransmission = params.cameraUvFilterEnabled
      ? smoothErfEdge(wl, params.cameraUvCutNm, kPythonUvTransitionNm)
      : 1.0f;
    const float irTransmission = params.cameraIrFilterEnabled
      ? smoothErfEdge(wl, params.cameraIrCutNm, -kPythonIrTransitionNm)
      : 1.0f;
    const float transmission = uvTransmission * irTransmission;
    transmissionByWavelength[wavelength] = transmission;
    const uint32_t offset = wavelength * 3u;
    const float illuminant = filmCurves.referenceIlluminantSpectrum ? filmCurves.referenceIlluminantSpectrum[wavelength] : 1.0f;
    for (uint32_t channel = 0; channel < 3u; ++channel) {
      const float response = linearSensitivity[offset + channel] * illuminant;
      denominator[channel] += response;
      numerator[channel] += response * transmission;
    }
  }

  std::array<float, 3> normalization = {1.0f, 1.0f, 1.0f};
  for (uint32_t channel = 0; channel < 3u; ++channel) {
    normalization[channel] = numerator[channel] / std::max(denominator[channel], 1.0e-10f);
    normalization[channel] = std::max(normalization[channel], 1.0e-10f);
  }
  for (uint32_t wavelength = 0; wavelength < filmCurves.wavelengthCount; ++wavelength) {
    const uint32_t offset = wavelength * 3u;
    for (uint32_t channel = 0; channel < 3u; ++channel) {
      filtered[offset + channel] *= transmissionByWavelength[wavelength] / normalization[channel];
    }
  }
  return filtered;
}

std::array<float, 9> makeMallettRawMatrixUnnormalized(
  const ProfileCurveSet &filmCurves,
  const std::vector<float> &linearSensitivity
) {
  std::array<float, 9> matrix{};
  const uint32_t wavelengthCount = filmCurves.wavelengthCount;
  if (!filmCurves.mallettBasisIlluminant || linearSensitivity.size() < static_cast<size_t>(wavelengthCount) * 3u) {
    return matrix;
  }
  for (uint32_t wavelength = 0; wavelength < wavelengthCount; ++wavelength) {
    const uint32_t offset = wavelength * 3u;
    for (uint32_t outChannel = 0; outChannel < 3u; ++outChannel) {
      for (uint32_t inChannel = 0; inChannel < 3u; ++inChannel) {
        matrix[outChannel * 3u + inChannel] +=
          linearSensitivity[offset + outChannel] * filmCurves.mallettBasisIlluminant[offset + inChannel];
      }
    }
  }
  return matrix;
}

std::array<float, 9> makeMallettRawMatrix(
  const ProfileCurveSet &filmCurves,
  const std::vector<float> &linearSensitivity
) {
  std::array<float, 9> matrix = makeMallettRawMatrixUnnormalized(filmCurves, linearSensitivity);
  float normalization = std::max(filmCurves.mallettRawMidgrayGreen, 1.0e-10f);
  normalization = std::max(normalization, 1.0e-10f);
  for (float &value : matrix) {
    value /= normalization;
  }
  return matrix;
}

std::vector<float> makeHanatosRawResponse(
  const ProfileCurveSet &filmCurves,
  const std::vector<float> &linearSensitivity,
  const std::vector<float> &hanatosSpectra,
  const HanatosSpectraLutInfo &hanatos,
  RgbToRawMethod method
) {
  const size_t responseCount = static_cast<size_t>(hanatos.width) * static_cast<size_t>(hanatos.height) * 3u;
  std::vector<float> response(responseCount, 0.0f);
  const size_t expectedSpectra = static_cast<size_t>(hanatos.width) * static_cast<size_t>(hanatos.height) * static_cast<size_t>(hanatos.wavelengthCount);
  if (hanatos.width == 0 ||
      hanatos.height == 0 ||
      hanatos.wavelengthCount == 0 ||
      hanatosSpectra.size() < expectedSpectra ||
      linearSensitivity.size() < static_cast<size_t>(hanatos.wavelengthCount) * 3u) {
    return response;
  }

  std::vector<float> hanatos2026Window(hanatos.wavelengthCount, 1.0f);
  std::array<float, 3> hanatos2026Normalization = {1.0f, 1.0f, 1.0f};
  const bool useHanatos2026 =
    method == RgbToRawMethod::Hanatos2026 &&
    filmCurves.hanatos2026WindowParams &&
    filmCurves.referenceIlluminantSpectrum;
  if (useHanatos2026) {
    constexpr float kSqrt2 = 1.4142135623730951f;
    const float cUv = filmCurves.hanatos2026WindowParams[0];
    const float sigmaUv = filmCurves.hanatos2026WindowParams[1];
    const float cIr = filmCurves.hanatos2026WindowParams[2];
    const float sigmaIr = filmCurves.hanatos2026WindowParams[3];
    if (sigmaUv > 0.0f && sigmaIr > 0.0f) {
      std::array<float, 3> numerator = {0.0f, 0.0f, 0.0f};
      std::array<float, 3> denominator = {0.0f, 0.0f, 0.0f};
      for (uint32_t wavelength = 0; wavelength < hanatos.wavelengthCount; ++wavelength) {
        const float wl = filmCurves.wavelengths ? filmCurves.wavelengths[wavelength] : 0.0f;
        const float edgeUv = smoothErfEdge(wl, cUv, sigmaUv * kSqrt2);
        const float edgeIr = smoothErfEdge(wl, cIr, -sigmaIr * kSqrt2);
        const float window = edgeUv * edgeIr;
        hanatos2026Window[wavelength] = window;
        const float illuminant = filmCurves.referenceIlluminantSpectrum[wavelength];
        const uint32_t sensitivityOffset = wavelength * 3u;
        for (uint32_t channel = 0; channel < 3u; ++channel) {
          const float referenceResponse = linearSensitivity[sensitivityOffset + channel] * illuminant;
          denominator[channel] += referenceResponse;
          numerator[channel] += referenceResponse * window;
        }
      }
      for (uint32_t channel = 0; channel < 3u; ++channel) {
        hanatos2026Normalization[channel] =
          numerator[channel] / std::max(denominator[channel], 1.0e-10f);
        hanatos2026Normalization[channel] = std::max(hanatos2026Normalization[channel], 1.0e-10f);
      }
    }
  }
  if (!useHanatos2026 && !filmCurves.bandpassHanatos2025) {
    return response;
  }

  for (uint32_t x = 0; x < hanatos.width; ++x) {
    for (uint32_t y = 0; y < hanatos.height; ++y) {
      float raw[3] = {0.0f, 0.0f, 0.0f};
      const size_t spectraOffset = (static_cast<size_t>(x) * hanatos.height + y) * hanatos.wavelengthCount;
      for (uint32_t wavelength = 0; wavelength < hanatos.wavelengthCount; ++wavelength) {
        const float spectrum = hanatosSpectra[spectraOffset + wavelength];
        const uint32_t sensitivityOffset = wavelength * 3u;
        if (useHanatos2026) {
          const float window = hanatos2026Window[wavelength];
          raw[0] += spectrum * linearSensitivity[sensitivityOffset] * window / hanatos2026Normalization[0];
          raw[1] += spectrum * linearSensitivity[sensitivityOffset + 1u] * window / hanatos2026Normalization[1];
          raw[2] += spectrum * linearSensitivity[sensitivityOffset + 2u] * window / hanatos2026Normalization[2];
        } else {
          raw[0] += spectrum * linearSensitivity[sensitivityOffset] * filmCurves.bandpassHanatos2025[sensitivityOffset];
          raw[1] += spectrum * linearSensitivity[sensitivityOffset + 1u] * filmCurves.bandpassHanatos2025[sensitivityOffset + 1u];
          raw[2] += spectrum * linearSensitivity[sensitivityOffset + 2u] * filmCurves.bandpassHanatos2025[sensitivityOffset + 2u];
        }
      }
      const size_t responseOffset = (static_cast<size_t>(x) * hanatos.height + y) * 3u;
      response[responseOffset] = raw[0];
      response[responseOffset + 1u] = raw[1];
      response[responseOffset + 2u] = raw[2];
    }
  }
  return response;
}

float reinhardKnee(float value, float threshold, float limit, float power) {
  if (!std::isfinite(value) || value <= threshold) {
    return value;
  }
  const float scale = std::max(limit - threshold, 1.0e-12f);
  const float x = (value - threshold) / scale;
  const float y = x / std::pow(1.0f + std::pow(x, power), 1.0f / power);
  return threshold + scale * y;
}

std::array<float, 2> filmReferenceIlluminantXy(const ProfileCurveSet &filmCurves) {
  const float *cmfs = standardObserverCmfs();
  if (!filmCurves.referenceIlluminantSpectrum || !cmfs || filmCurves.wavelengthCount == 0) {
    return {1.0f / 3.0f, 1.0f / 3.0f};
  }
  std::array<float, 3> xyz = {0.0f, 0.0f, 0.0f};
  for (uint32_t wavelength = 0; wavelength < filmCurves.wavelengthCount; ++wavelength) {
    const float illuminant = filmCurves.referenceIlluminantSpectrum[wavelength];
    const uint32_t offset = wavelength * 3u;
    xyz[0] += illuminant * cmfs[offset];
    xyz[1] += illuminant * cmfs[offset + 1u];
    xyz[2] += illuminant * cmfs[offset + 2u];
  }
  const float sum = xyz[0] + xyz[1] + xyz[2];
  if (!(sum > 1.0e-12f) || !std::isfinite(sum)) {
    return {1.0f / 3.0f, 1.0f / 3.0f};
  }
  return {xyz[0] / sum, xyz[1] / sum};
}

std::vector<std::array<float, 2>> spectralLocusXy(const ProfileCurveSet &filmCurves) {
  std::vector<std::array<float, 2>> locus;
  const float *cmfs = standardObserverCmfs();
  if (!filmCurves.wavelengths || !cmfs) {
    return locus;
  }
  for (uint32_t wavelength = 0; wavelength < filmCurves.wavelengthCount; ++wavelength) {
    if (filmCurves.wavelengths[wavelength] > 700.0f + 1.0e-4f) {
      continue;
    }
    const uint32_t offset = wavelength * 3u;
    const float x = cmfs[offset];
    const float y = cmfs[offset + 1u];
    const float z = cmfs[offset + 2u];
    const float sum = x + y + z;
    if (sum > 1.0e-12f && std::isfinite(sum)) {
      locus.push_back({x / sum, y / sum});
    }
  }
  if (!locus.empty()) {
    locus.push_back(locus.front());
  }
  return locus;
}

float rayPolygonDistance(
  std::array<float, 2> origin,
  std::array<float, 2> direction,
  const std::vector<std::array<float, 2>> &polygon
) {
  float tMin = INFINITY;
  for (size_t edgeIndex = 0; edgeIndex + 1u < polygon.size(); ++edgeIndex) {
    const float ax = polygon[edgeIndex][0];
    const float ay = polygon[edgeIndex][1];
    const float ex = polygon[edgeIndex + 1u][0] - ax;
    const float ey = polygon[edgeIndex + 1u][1] - ay;
    const float denom = direction[0] * ey - direction[1] * ex;
    if (std::abs(denom) <= 1.0e-12f) {
      continue;
    }
    const float ox = origin[0] - ax;
    const float oy = origin[1] - ay;
    const float t = (-ox * ey + oy * ex) / denom;
    const float s = (-ox * direction[1] + oy * direction[0]) / denom;
    if (t > 1.0e-9f && s >= 0.0f && s <= 1.0f && t < tMin) {
      tMin = t;
    }
  }
  return tMin;
}

std::array<float, 2> compressXyRadial(
  std::array<float, 2> xy,
  std::array<float, 2> whiteXy,
  const std::vector<std::array<float, 2>> &locus
) {
  const float dx = xy[0] - whiteXy[0];
  const float dy = xy[1] - whiteXy[1];
  const float distance = std::sqrt(dx * dx + dy * dy);
  if (!(distance > 1.0e-9f) || locus.size() < 4u) {
    return xy;
  }
  const std::array<float, 2> direction = {dx / distance, dy / distance};
  const float boundary = rayPolygonDistance(whiteXy, direction, locus);
  if (!(boundary > 1.0e-12f) || !std::isfinite(boundary)) {
    return xy;
  }
  const float normalized = distance / boundary;
  const float compressed = reinhardKnee(normalized, 0.0f, 1.0f, 6.0f);
  const float newDistance = compressed * boundary;
  return {whiteXy[0] + direction[0] * newDistance, whiteXy[1] + direction[1] * newDistance};
}

std::array<float, 3> sampleHanatosResponseBilinear(
  const std::vector<float> &response,
  const HanatosSpectraLutInfo &hanatos,
  float x,
  float y
) {
  x = std::clamp(x, 0.0f, static_cast<float>(hanatos.width - 1u));
  y = std::clamp(y, 0.0f, static_cast<float>(hanatos.height - 1u));
  const uint32_t x0 = static_cast<uint32_t>(std::floor(x));
  const uint32_t y0 = static_cast<uint32_t>(std::floor(y));
  const uint32_t x1 = std::min(x0 + 1u, hanatos.width - 1u);
  const uint32_t y1 = std::min(y0 + 1u, hanatos.height - 1u);
  const float tx = x - static_cast<float>(x0);
  const float ty = y - static_cast<float>(y0);
  const auto valueAt = [&](uint32_t xi, uint32_t yi) -> std::array<float, 3> {
    const size_t offset = (static_cast<size_t>(xi) * hanatos.height + yi) * 3u;
    return {response[offset], response[offset + 1u], response[offset + 2u]};
  };
  const std::array<float, 3> v00 = valueAt(x0, y0);
  const std::array<float, 3> v10 = valueAt(x1, y0);
  const std::array<float, 3> v01 = valueAt(x0, y1);
  const std::array<float, 3> v11 = valueAt(x1, y1);
  std::array<float, 3> out{};
  for (uint32_t channel = 0; channel < 3u; ++channel) {
    const float a = v00[channel] + (v10[channel] - v00[channel]) * tx;
    const float b = v01[channel] + (v11[channel] - v01[channel]) * tx;
    out[channel] = a + (b - a) * ty;
  }
  return out;
}

std::vector<float> remapHanatosResponseForInputGamutCompression(
  const ProfileCurveSet &filmCurves,
  const std::vector<float> &baseResponse,
  const HanatosSpectraLutInfo &hanatos
) {
  std::vector<float> remapped(baseResponse.size(), 0.0f);
  if (hanatos.width < 2u || hanatos.height < 2u || baseResponse.size() < static_cast<size_t>(hanatos.width) * hanatos.height * 3u) {
    return remapped;
  }
  const std::array<float, 2> whiteXy = filmReferenceIlluminantXy(filmCurves);
  const std::vector<std::array<float, 2>> locus = spectralLocusXy(filmCurves);
  if (locus.size() < 4u) {
    return baseResponse;
  }
  for (uint32_t x = 0; x < hanatos.width; ++x) {
    const float tx = static_cast<float>(x) / static_cast<float>(hanatos.width - 1u);
    const float rootTx = std::sqrt(std::max(tx, 0.0f));
    for (uint32_t y = 0; y < hanatos.height; ++y) {
      const float ty = static_cast<float>(y) / static_cast<float>(hanatos.height - 1u);
      const std::array<float, 2> xy = {1.0f - rootTx, ty * rootTx};
      const std::array<float, 2> compressedXy = compressXyRadial(xy, whiteXy, locus);
      const float oneMinusX = std::max(1.0f - compressedXy[0], 1.0e-10f);
      const float sampleTx = std::clamp(oneMinusX * oneMinusX, 0.0f, 1.0f);
      const float sampleTy = std::clamp(compressedXy[1] / oneMinusX, 0.0f, 1.0f);
      const std::array<float, 3> sampled = sampleHanatosResponseBilinear(
        baseResponse,
        hanatos,
        sampleTx * static_cast<float>(hanatos.width - 1u),
        sampleTy * static_cast<float>(hanatos.height - 1u)
      );
      const size_t offset = (static_cast<size_t>(x) * hanatos.height + y) * 3u;
      remapped[offset] = sampled[0];
      remapped[offset + 1u] = sampled[1];
      remapped[offset + 2u] = sampled[2];
    }
  }
  return remapped;
}

std::vector<float> makeHanatosRawResponsePair(
  const ProfileCurveSet &filmCurves,
  const std::vector<float> &linearSensitivity,
  const std::vector<float> &hanatosSpectra,
  const HanatosSpectraLutInfo &hanatos,
  RgbToRawMethod method
) {
  std::vector<float> response = makeHanatosRawResponse(filmCurves, linearSensitivity, hanatosSpectra, hanatos, method);
  std::vector<float> compressed = remapHanatosResponseForInputGamutCompression(filmCurves, response, hanatos);
  std::vector<float> packed;
  packed.reserve((response.size() + compressed.size()) / 3u * 4u);
  const auto appendPackedResponse = [&](const std::vector<float> &source) {
    for (size_t offset = 0u; offset + 2u < source.size(); offset += 3u) {
      packed.push_back(source[offset]);
      packed.push_back(source[offset + 1u]);
      packed.push_back(source[offset + 2u]);
      packed.push_back(0.0f);
    }
  };
  appendPackedResponse(response);
  appendPackedResponse(compressed);
  return packed;
}

std::vector<float> makeHanatosResponsePairFromWeights(
  const ProfileCurveSet &referenceCurves,
  const std::vector<float> &spectralWeights,
  const std::vector<float> &hanatosSpectra,
  const HanatosSpectraLutInfo &hanatos
) {
  const size_t responseCount = static_cast<size_t>(hanatos.width) * static_cast<size_t>(hanatos.height) * 3u;
  std::vector<float> response(responseCount, 0.0f);
  const size_t expectedSpectra = static_cast<size_t>(hanatos.width) * static_cast<size_t>(hanatos.height) * static_cast<size_t>(hanatos.wavelengthCount);
  if (hanatos.width == 0u ||
      hanatos.height == 0u ||
      hanatos.wavelengthCount == 0u ||
      hanatosSpectra.size() < expectedSpectra ||
      spectralWeights.size() < static_cast<size_t>(hanatos.wavelengthCount) * 3u) {
    return response;
  }
  for (uint32_t x = 0; x < hanatos.width; ++x) {
    for (uint32_t y = 0; y < hanatos.height; ++y) {
      float raw[3] = {0.0f, 0.0f, 0.0f};
      const size_t spectraOffset = (static_cast<size_t>(x) * hanatos.height + y) * hanatos.wavelengthCount;
      for (uint32_t wavelength = 0u; wavelength < hanatos.wavelengthCount; ++wavelength) {
        const float spectrum = hanatosSpectra[spectraOffset + wavelength];
        const uint32_t weightOffset = wavelength * 3u;
        raw[0] += spectrum * spectralWeights[weightOffset];
        raw[1] += spectrum * spectralWeights[weightOffset + 1u];
        raw[2] += spectrum * spectralWeights[weightOffset + 2u];
      }
      const size_t responseOffset = (static_cast<size_t>(x) * hanatos.height + y) * 3u;
      response[responseOffset] = raw[0];
      response[responseOffset + 1u] = raw[1];
      response[responseOffset + 2u] = raw[2];
    }
  }

  std::vector<float> compressed = remapHanatosResponseForInputGamutCompression(referenceCurves, response, hanatos);
  std::vector<float> packed;
  packed.reserve((response.size() + compressed.size()) / 3u * 4u);
  const auto appendPackedResponse = [&](const std::vector<float> &source) {
    for (size_t offset = 0u; offset + 2u < source.size(); offset += 3u) {
      packed.push_back(source[offset]);
      packed.push_back(source[offset + 1u]);
      packed.push_back(source[offset + 2u]);
      packed.push_back(0.0f);
    }
  };
  appendPackedResponse(response);
  appendPackedResponse(compressed);
  return packed;
}

float filteredEnlargerIlluminantCpu(
  uint32_t wavelength,
  const RenderParams &params,
  float cFilter,
  float mFilterShift,
  float yFilterShift
) {
  const uint32_t film = std::min<uint32_t>(
    static_cast<uint32_t>(std::max(params.film, 0)),
    std::max<uint32_t>(kSpektraFilmCount, 1u) - 1u
  );
  const uint32_t paper = std::min<uint32_t>(
    static_cast<uint32_t>(std::max(params.paper, 0)),
    std::max<uint32_t>(kSpektraPaperCount, 1u) - 1u
  );
  const uint32_t neutralOffset = (paper * kSpektraFilmCount + film) * 3u;
  const float *neutral = neutralPrintFilters();
  const float cc0 = std::max(neutral[neutralOffset] + cFilter, 0.0f);
  const float cc1 = std::max(neutral[neutralOffset + 1u] + mFilterShift, 0.0f);
  const float cc2 = std::max(neutral[neutralOffset + 2u] + yFilterShift, 0.0f);
  const float wheel0 = std::pow(10.0f, -cc0 / 100.0f);
  const float wheel1 = std::pow(10.0f, -cc1 / 100.0f);
  const float wheel2 = std::pow(10.0f, -cc2 / 100.0f);
  const uint32_t offset = wavelength * 3u;
  const float *filters = customEnlargerFilters();
  const float f0 = std::clamp(filters[offset], 0.0f, 1.0f);
  const float f1 = std::clamp(filters[offset + 1u], 0.0f, 1.0f);
  const float f2 = std::clamp(filters[offset + 2u], 0.0f, 1.0f);
  const float dim0 = 1.0f - (1.0f - f0) * (1.0f - wheel0);
  const float dim1 = 1.0f - (1.0f - f1) * (1.0f - wheel1);
  const float dim2 = 1.0f - (1.0f - f2) * (1.0f - wheel2);
  return thKg3Illuminant()[wavelength] * dim0 * dim1 * dim2;
}

std::vector<float> makeProcessNegativePaperWeights(
  const ProfileCurveSet &paperCurves,
  const std::vector<float> &paperSensitivityLinear,
  const RenderParams &params,
  bool preflash
) {
  std::vector<float> weights(static_cast<size_t>(paperCurves.wavelengthCount) * 3u, 0.0f);
  if (paperSensitivityLinear.size() < weights.size()) {
    return weights;
  }
  if (params.printTiming == PrintTimingMode::ApdPrinterDensity) {
    std::array<float, 3> normalization = {0.0f, 0.0f, 0.0f};
    for (uint32_t wavelength = 0u; wavelength < paperCurves.wavelengthCount; ++wavelength) {
      const uint32_t offset = wavelength * 3u;
      normalization[0] += std::max(academyPrinterDensityData()[offset], 0.0f);
      normalization[1] += std::max(academyPrinterDensityData()[offset + 1u], 0.0f);
      normalization[2] += std::max(academyPrinterDensityData()[offset + 2u], 0.0f);
    }
    const float preflashScale = preflash ? std::max(params.preflashExposure, 0.0f) : 1.0f;
    for (uint32_t wavelength = 0u; wavelength < paperCurves.wavelengthCount; ++wavelength) {
      const uint32_t offset = wavelength * 3u;
      weights[offset] = preflashScale * std::max(academyPrinterDensityData()[offset], 0.0f) / std::max(normalization[0], 1.0e-10f);
      weights[offset + 1u] = preflashScale * std::max(academyPrinterDensityData()[offset + 1u], 0.0f) / std::max(normalization[1], 1.0e-10f);
      weights[offset + 2u] = preflashScale * std::max(academyPrinterDensityData()[offset + 2u], 0.0f) / std::max(normalization[2], 1.0e-10f);
    }
    return weights;
  }

  const float cFilter = preflash ? 0.0f : params.filterC;
  const float mFilter = preflash ? params.preflashMFilterShift : params.filterMShift;
  const float yFilter = preflash ? params.preflashYFilterShift : params.filterYShift;
  const float preflashScale = preflash ? std::max(params.preflashExposure, 0.0f) : 1.0f;
  for (uint32_t wavelength = 0u; wavelength < paperCurves.wavelengthCount; ++wavelength) {
    const uint32_t offset = wavelength * 3u;
    const float illuminant = filteredEnlargerIlluminantCpu(wavelength, params, cFilter, mFilter, yFilter);
    weights[offset] = preflashScale * illuminant * paperSensitivityLinear[offset];
    weights[offset + 1u] = preflashScale * illuminant * paperSensitivityLinear[offset + 1u];
    weights[offset + 2u] = preflashScale * illuminant * paperSensitivityLinear[offset + 2u];
  }
  return weights;
}

float interpLinear(const std::vector<float> &x, const float *y, uint32_t channel, float target) {
  if (x.empty()) {
    return 0.0f;
  }
  const bool ascending = x.back() >= x.front();
  if ((ascending && target <= x.front()) || (!ascending && target >= x.front())) {
    const float value = y[channel];
    return value;
  }
  if ((ascending && target >= x.back()) || (!ascending && target <= x.back())) {
    const float value = y[(x.size() - 1u) * 3u + channel];
    return value;
  }
  uint32_t lo = 0;
  uint32_t hi = static_cast<uint32_t>(x.size() - 1u);
  while (hi - lo > 1u) {
    const uint32_t mid = (lo + hi) >> 1u;
    if ((ascending && x[mid] <= target) || (!ascending && x[mid] >= target)) {
      lo = mid;
    } else {
      hi = mid;
    }
  }
  const float denom = std::max(std::abs(x[hi] - x[lo]), 1.0e-9f);
  const float t = std::clamp((target - x[lo]) / denom, 0.0f, 1.0f);
  const float y0 = y[lo * 3u + channel];
  const float y1 = y[hi * 3u + channel];
  const float value = y0 + (y1 - y0) * t;
  return value;
}

KernelDirInfo makeDirInfo(const ProfileCurveSet &filmCurves, const RenderParams &params) {
  const float amount = std::max(params.dirCouplersAmount, 0.0f);
  const float sameLayer = std::max(params.dirCouplersInhibitionSameLayer, 0.0f);
  const float interlayer = std::max(params.dirCouplersInhibitionInterlayer, 0.0f);
  KernelDirInfo info{};
  info.matrix00 = params.dirCouplersGammaSameLayerR * sameLayer * amount;
  info.matrix11 = params.dirCouplersGammaSameLayerG * sameLayer * amount;
  info.matrix22 = params.dirCouplersGammaSameLayerB * sameLayer * amount;
  info.matrix01 = params.dirCouplersGammaRToG * interlayer * amount;
  info.matrix02 = params.dirCouplersGammaRToB * interlayer * amount;
  info.matrix10 = params.dirCouplersGammaGToR * interlayer * amount;
  info.matrix12 = params.dirCouplersGammaGToB * interlayer * amount;
  info.matrix20 = params.dirCouplersGammaBToR * interlayer * amount;
  info.matrix21 = params.dirCouplersGammaBToG * interlayer * amount;
  for (uint32_t channel = 0; channel < 3u; ++channel) {
    float maximum = 0.0f;
    for (uint32_t i = 0; i < filmCurves.exposureCount; ++i) {
      maximum = std::max(maximum, filmCurves.densityCurves[i * 3u + channel]);
    }
    if (channel == 0u) {
      info.densityMax0 = maximum;
    } else if (channel == 1u) {
      info.densityMax1 = maximum;
    } else {
      info.densityMax2 = maximum;
    }
  }
  return info;
}

KernelGaussianBlurInfo makeGaussianBlurInfo(float sigma, uint32_t radiusLimit) {
  KernelGaussianBlurInfo info{};
  if (sigma <= 1.0e-4f) {
    return info;
  }
  const uint32_t radius = std::min<uint32_t>(
    static_cast<uint32_t>(std::ceil(3.0f * sigma)),
    radiusLimit
  );
  info.radius = radius;
  info.active = 1u;
  const double sigmaDouble = static_cast<double>(std::max(sigma, 1.0e-6f));
  const double invSigma2 = 1.0 / std::max(sigmaDouble * sigmaDouble, 1.0e-8);
  info.firstWeight = static_cast<float>(std::exp(-0.5 * invSigma2));
  info.firstRatio = static_cast<float>(std::exp(-1.5 * invSigma2));
  info.ratioStep = static_cast<float>(std::exp(-invSigma2));
  double weight = info.firstWeight;
  double ratio = info.firstRatio;
  double weightSum = 1.0;
  for (uint32_t offset = 1u; offset <= radius; ++offset) {
    weightSum += 2.0 * weight;
    weight *= ratio;
    ratio *= info.ratioStep;
  }
  info.invWeightSum = static_cast<float>(1.0 / std::max(weightSum, 1.0e-8));
  return info;
}

std::array<KernelGaussianBlurInfo, 3> makeDirTailBlurInfos(const KernelParams &params) {
  constexpr std::array<float, 3> kTailSigmaScale = {0.5360f, 1.5236f, 2.7684f};
  std::array<KernelGaussianBlurInfo, 3> infos{};
  const float pixelSizeUm = std::max(params.filmPixelSizeUm, 1.0e-6f);
  const float tailUm = std::max(params.dirCouplersDiffusionTailUm, 0.0f);
  for (size_t component = 0; component < infos.size(); ++component) {
    infos[component] = makeGaussianBlurInfo(tailUm * kTailSigmaScale[component] / pixelSizeUm, 256u);
  }
  return infos;
}

std::array<float, 3> densityCurveMaximums(const ProfileCurveSet &curves) {
  std::array<float, 3> maxima = {0.0f, 0.0f, 0.0f};
  for (uint32_t channel = 0; channel < 3u; ++channel) {
    for (uint32_t i = 0; i < curves.exposureCount; ++i) {
      maxima[channel] = std::max(maxima[channel], curves.densityCurves[i * 3u + channel]);
    }
  }
  return maxima;
}

std::vector<float> makeDirCorrectedDensityCurves(
  const ProfileCurveSet &filmCurves,
  const KernelDirInfo &dirInfo
) {
  const bool positive = std::strcmp(filmCurves.type, "positive") == 0;
  std::vector<float> corrected(static_cast<size_t>(filmCurves.exposureCount) * 3u, 0.0f);
  for (uint32_t receiver = 0; receiver < 3u; ++receiver) {
    std::vector<float> logExposure0(filmCurves.exposureCount, 0.0f);
    for (uint32_t i = 0; i < filmCurves.exposureCount; ++i) {
      const float d0 = filmCurves.densityCurves[i * 3u];
      const float d1 = filmCurves.densityCurves[i * 3u + 1u];
      const float d2 = filmCurves.densityCurves[i * 3u + 2u];
      const float silver0 = positive ? dirInfo.densityMax0 - d0 : d0;
      const float silver1 = positive ? dirInfo.densityMax1 - d1 : d1;
      const float silver2 = positive ? dirInfo.densityMax2 - d2 : d2;
      float amount = 0.0f;
      if (receiver == 0u) {
        amount = silver0 * dirInfo.matrix00 + silver1 * dirInfo.matrix10 + silver2 * dirInfo.matrix20;
      } else if (receiver == 1u) {
        amount = silver0 * dirInfo.matrix01 + silver1 * dirInfo.matrix11 + silver2 * dirInfo.matrix21;
      } else {
        amount = silver0 * dirInfo.matrix02 + silver1 * dirInfo.matrix12 + silver2 * dirInfo.matrix22;
      }
      logExposure0[i] = filmCurves.logExposure[i] - amount;
    }
    for (uint32_t i = 0; i < filmCurves.exposureCount; ++i) {
      corrected[i * 3u + receiver] = interpLinear(
        logExposure0,
        filmCurves.densityCurves,
        receiver,
        filmCurves.logExposure[i]
      );
    }
  }
  return corrected;
}

uint32_t halfToFloatBits(uint16_t h) {
  const uint32_t sign = (static_cast<uint32_t>(h & 0x8000u)) << 16;
  uint32_t exponent = (h >> 10) & 0x1fu;
  uint32_t mantissa = h & 0x03ffu;

  if (exponent == 0) {
    if (mantissa == 0) {
      return sign;
    }
    exponent = 1;
    while ((mantissa & 0x0400u) == 0) {
      mantissa <<= 1;
      --exponent;
    }
    mantissa &= 0x03ffu;
  } else if (exponent == 31) {
    return sign | 0x7f800000u | (mantissa << 13);
  }

  exponent = exponent + (127 - 15);
  return sign | (exponent << 23) | (mantissa << 13);
}

float halfToFloat(uint16_t h) {
  const uint32_t bits = halfToFloatBits(h);
  float out = 0.0f;
  std::memcpy(&out, &bits, sizeof(out));
  return out;
}

uint16_t floatToHalf(float value) {
  uint32_t bits = 0;
  std::memcpy(&bits, &value, sizeof(bits));
  const uint32_t sign = (bits >> 16) & 0x8000u;
  int32_t exponent = static_cast<int32_t>((bits >> 23) & 0xffu) - 127 + 15;
  uint32_t mantissa = bits & 0x007fffffu;

  if (exponent <= 0) {
    if (exponent < -10) {
      return static_cast<uint16_t>(sign);
    }
    mantissa = (mantissa | 0x00800000u) >> static_cast<uint32_t>(1 - exponent);
    return static_cast<uint16_t>(sign | ((mantissa + 0x00001000u) >> 13));
  }
  if (exponent >= 31) {
    return static_cast<uint16_t>(sign | 0x7c00u);
  }
  return static_cast<uint16_t>(sign | (static_cast<uint32_t>(exponent) << 10) | ((mantissa + 0x00001000u) >> 13));
}

bool isSupportedRgba(const ImageView &source, const MutableImageView &destination) {
  return source.components == 4 &&
         destination.components == 4 &&
         (source.bytesPerComponent == 2 || source.bytesPerComponent == 4) &&
         (destination.bytesPerComponent == 2 || destination.bytesPerComponent == 4);
}

void copySourceToFloatStaging(
  const ImageView &source,
  const RenderWindow &window,
  int32_t width,
  int32_t height,
  float *staging
) {
  const auto *sourceBase = static_cast<const unsigned char *>(source.data);
  for (int32_t y = 0; y < height; ++y) {
    const int32_t sourceY = window.y1 + y - source.y1;
    const int32_t sourceX = window.x1 - source.x1;
    const auto *row = sourceBase + static_cast<size_t>(sourceY) * source.rowBytes + static_cast<size_t>(sourceX) * source.components * source.bytesPerComponent;
    for (int32_t x = 0; x < width; ++x) {
      float *dst = staging + (static_cast<size_t>(y) * width + x) * 4;
      if (source.bytesPerComponent == 4) {
        const auto *src = reinterpret_cast<const float *>(row + static_cast<size_t>(x) * 4 * sizeof(float));
        dst[0] = src[0];
        dst[1] = src[1];
        dst[2] = src[2];
        dst[3] = src[3];
      } else {
        const auto *src = reinterpret_cast<const uint16_t *>(row + static_cast<size_t>(x) * 4 * sizeof(uint16_t));
        dst[0] = halfToFloat(src[0]);
        dst[1] = halfToFloat(src[1]);
        dst[2] = halfToFloat(src[2]);
        dst[3] = halfToFloat(src[3]);
      }
    }
  }
}

void copyFloatStagingToDestination(
  const float *staging,
  const MutableImageView &destination,
  const RenderWindow &window,
  int32_t width,
  int32_t height
) {
  auto *destinationBase = static_cast<unsigned char *>(destination.data);
  for (int32_t y = 0; y < height; ++y) {
    const int32_t destinationY = window.y1 + y - destination.y1;
    const int32_t destinationX = window.x1 - destination.x1;
    auto *row = destinationBase + static_cast<size_t>(destinationY) * destination.rowBytes + static_cast<size_t>(destinationX) * destination.components * destination.bytesPerComponent;
    for (int32_t x = 0; x < width; ++x) {
      const float *src = staging + (static_cast<size_t>(y) * width + x) * 4;
      if (destination.bytesPerComponent == 4) {
        auto *dst = reinterpret_cast<float *>(row + static_cast<size_t>(x) * 4 * sizeof(float));
        dst[0] = src[0];
        dst[1] = src[1];
        dst[2] = src[2];
        dst[3] = src[3];
      } else {
        auto *dst = reinterpret_cast<uint16_t *>(row + static_cast<size_t>(x) * 4 * sizeof(uint16_t));
        dst[0] = floatToHalf(src[0]);
        dst[1] = floatToHalf(src[1]);
        dst[2] = floatToHalf(src[2]);
        dst[3] = floatToHalf(src[3]);
      }
    }
  }
}

float sampleTransferLut(
  float value,
  int32_t colorSpace,
  const float *luts
) {
  if (!luts || kSpektraColorTransferLutSize <= 1u) {
    return value;
  }
  const float decodeMin = colorDecodeLutMin();
  const float decodeMax = colorDecodeLutMax();
  const float range = std::max(decodeMax - decodeMin, 1.0e-6f);
  const float step = range / static_cast<float>(kSpektraColorTransferLutSize - 1u);
  const uint32_t offset = static_cast<uint32_t>(std::clamp<int32_t>(colorSpace, 0, static_cast<int32_t>(kSpektraColorSpaceCount - 1u))) *
    kSpektraColorTransferLutSize;
  if (value <= decodeMin) {
    const float y0 = luts[offset];
    const float y1 = luts[offset + 1u];
    return y0 + (value - decodeMin) * ((y1 - y0) / std::max(step, 1.0e-12f));
  }
  if (value >= decodeMax) {
    const float y0 = luts[offset + kSpektraColorTransferLutSize - 2u];
    const float y1 = luts[offset + kSpektraColorTransferLutSize - 1u];
    return y1 + (value - decodeMax) * ((y1 - y0) / std::max(step, 1.0e-12f));
  }
  const float t = (value - decodeMin) / range;
  const float position = t * static_cast<float>(kSpektraColorTransferLutSize - 1u);
  const uint32_t lo = static_cast<uint32_t>(std::floor(position));
  const uint32_t hi = std::min(lo + 1u, kSpektraColorTransferLutSize - 1u);
  const float f = position - static_cast<float>(lo);
  return luts[offset + lo] + (luts[offset + hi] - luts[offset + lo]) * f;
}

float autoExposureMeterY(float r, float g, float b, const RenderParams &params) {
  const int32_t colorSpace = std::clamp(
    static_cast<int32_t>(params.inputColorSpace),
    0,
    static_cast<int32_t>(kSpektraColorSpaceCount - 1u)
  );
  const uint32_t *transferKinds = colorTransferKinds();
  if (transferKinds && transferKinds[colorSpace] != 0u) {
    const float *decodeLuts = colorDecodeLuts();
    r = sampleTransferLut(r, colorSpace, decodeLuts);
    g = sampleTransferLut(g, colorSpace, decodeLuts);
    b = sampleTransferLut(b, colorSpace, decodeLuts);
  }
  const float *meterMatrices = inputMeterXyzMatrices();
  if (!meterMatrices) {
    return 0.2126f * r + 0.7152f * g + 0.0722f * b;
  }
  const float *matrix = meterMatrices + static_cast<size_t>(colorSpace) * 9u;
  return matrix[3] * r + matrix[4] * g + matrix[5] * b;
}

void autoExposurePreviewShape(int32_t width, int32_t height, int32_t &previewWidth, int32_t &previewHeight) {
  constexpr int32_t kPreviewMaxSize = 256;
  const int32_t longEdge = std::max(width, height);
  if (longEdge <= kPreviewMaxSize) {
    previewWidth = width;
    previewHeight = height;
    return;
  }
  const double scale = static_cast<double>(kPreviewMaxSize) / static_cast<double>(longEdge);
  previewWidth = std::max(1, static_cast<int32_t>(std::lround(static_cast<double>(width) * scale)));
  previewHeight = std::max(1, static_cast<int32_t>(std::lround(static_cast<double>(height) * scale)));
}

float measureAutoExposureEv(
  const float *source,
  int32_t width,
  int32_t height,
  const RenderParams &params,
  std::vector<float> &luminance
) {
  if (!source || width <= 0 || height <= 0) {
    return 0.0f;
  }

  int32_t previewWidth = width;
  int32_t previewHeight = height;
  autoExposurePreviewShape(width, height, previewWidth, previewHeight);
  luminance.clear();
  luminance.reserve(static_cast<size_t>(previewWidth) * static_cast<size_t>(previewHeight));

  for (int32_t y = 0; y < previewHeight; ++y) {
    const int32_t sourceY = std::min(
      height - 1,
      static_cast<int32_t>((static_cast<int64_t>(y) * height) / previewHeight)
    );
    for (int32_t x = 0; x < previewWidth; ++x) {
      const int32_t sourceX = std::min(
        width - 1,
        static_cast<int32_t>((static_cast<int64_t>(x) * width) / previewWidth)
      );
      const float *pixel = source + (static_cast<size_t>(sourceY) * width + sourceX) * 4u;
      luminance.push_back(autoExposureMeterY(pixel[0], pixel[1], pixel[2], params));
    }
  }
  if (luminance.empty()) {
    return 0.0f;
  }

  double meteredY = 0.0;
  if (params.autoExposureMethod == AutoExposureMethod::Median) {
    const size_t mid = luminance.size() / 2u;
    std::nth_element(luminance.begin(), luminance.begin() + static_cast<std::ptrdiff_t>(mid), luminance.end());
    meteredY = luminance[mid];
    if ((luminance.size() & 1u) == 0u) {
      const float upper = luminance[mid];
      std::nth_element(luminance.begin(), luminance.begin() + static_cast<std::ptrdiff_t>(mid - 1u), luminance.begin() + static_cast<std::ptrdiff_t>(mid));
      meteredY = 0.5 * (static_cast<double>(luminance[mid - 1u]) + static_cast<double>(upper));
    }
  } else {
    const double normX = static_cast<double>(previewWidth) / static_cast<double>(std::max(previewWidth, previewHeight));
    const double normY = static_cast<double>(previewHeight) / static_cast<double>(std::max(previewWidth, previewHeight));
    constexpr double kSigma = 0.2;
    double weightedSum = 0.0;
    double weightSum = 0.0;
    size_t index = 0;
    for (int32_t y = 0; y < previewHeight; ++y) {
      const double yf = (static_cast<double>(y) / static_cast<double>(previewHeight) - 0.5) * normY;
      for (int32_t x = 0; x < previewWidth; ++x, ++index) {
        const double xf = (static_cast<double>(x) / static_cast<double>(previewWidth) - 0.5) * normX;
        const double weight = std::exp(-(xf * xf + yf * yf) / (2.0 * kSigma * kSigma));
        weightedSum += static_cast<double>(luminance[index]) * weight;
        weightSum += weight;
      }
    }
    meteredY = weightedSum / std::max(weightSum, 1.0e-30);
  }

  const double exposure = meteredY / 0.184;
  if (!(exposure > 0.0) || !std::isfinite(exposure)) {
    return 0.0f;
  }
  const double ev = -std::log2(exposure);
  return std::isfinite(ev) ? static_cast<float>(ev) : 0.0f;
}

const void *contiguousFloatWindowPointer(
  const ImageView &view,
  const RenderWindow &window,
  int32_t width,
  int32_t height
) {
  if (view.bytesPerComponent != 4 ||
      view.components != 4 ||
      window.x1 != view.x1 ||
      width <= 0 ||
      height <= 0 ||
      view.rowBytes != width * static_cast<int32_t>(4 * sizeof(float))) {
    return nullptr;
  }
  const int32_t sourceY = window.y1 - view.y1;
  if (sourceY < 0 || sourceY + height > view.height) {
    return nullptr;
  }
  const auto *base = static_cast<const unsigned char *>(view.data);
  return base + static_cast<size_t>(sourceY) * view.rowBytes;
}

void *contiguousFloatWindowPointer(
  const MutableImageView &view,
  const RenderWindow &window,
  int32_t width,
  int32_t height
) {
  if (view.bytesPerComponent != 4 ||
      view.components != 4 ||
      window.x1 != view.x1 ||
      width <= 0 ||
      height <= 0 ||
      view.rowBytes != width * static_cast<int32_t>(4 * sizeof(float))) {
    return nullptr;
  }
  const int32_t destinationY = window.y1 - view.y1;
  if (destinationY < 0 || destinationY + height > view.height) {
    return nullptr;
  }
  auto *base = static_cast<unsigned char *>(view.data);
  return base + static_cast<size_t>(destinationY) * view.rowBytes;
}

const void *contiguousHalfWindowPointer(
  const ImageView &view,
  const RenderWindow &window,
  int32_t width,
  int32_t height
) {
  if (view.bytesPerComponent != 2 ||
      view.components != 4 ||
      window.x1 != view.x1 ||
      width <= 0 ||
      height <= 0 ||
      view.rowBytes != width * static_cast<int32_t>(4 * sizeof(uint16_t))) {
    return nullptr;
  }
  const int32_t sourceY = window.y1 - view.y1;
  if (sourceY < 0 || sourceY + height > view.height) {
    return nullptr;
  }
  const auto *base = static_cast<const unsigned char *>(view.data);
  return base + static_cast<size_t>(sourceY) * view.rowBytes;
}

void *contiguousHalfWindowPointer(
  const MutableImageView &view,
  const RenderWindow &window,
  int32_t width,
  int32_t height
) {
  if (view.bytesPerComponent != 2 ||
      view.components != 4 ||
      window.x1 != view.x1 ||
      width <= 0 ||
      height <= 0 ||
      view.rowBytes != width * static_cast<int32_t>(4 * sizeof(uint16_t))) {
    return nullptr;
  }
  const int32_t destinationY = window.y1 - view.y1;
  if (destinationY < 0 || destinationY + height > view.height) {
    return nullptr;
  }
  auto *base = static_cast<unsigned char *>(view.data);
  return base + static_cast<size_t>(destinationY) * view.rowBytes;
}

struct HostBufferLayout {
  uint32_t width = 0;
  uint32_t height = 0;
  uint32_t rowBytes = 0;
  uint32_t startByteOffset = 0;
};

struct ExternalMetalBufferContext {
  id<MTLBuffer> sourceBuffer = nil;
  id<MTLBuffer> destinationBuffer = nil;
  id<MTLCommandQueue> commandQueue = nil;
  MetalBufferImageView source{};
  MetalBufferImageView destination{};
  HostBufferLayout sourceLayout{};
  HostBufferLayout destinationLayout{};
  bool active = false;
  bool sourceCompactFloat = false;
  bool sourceCompactHalf = false;
  bool destinationCompactFloat = false;
  bool destinationCompactHalf = false;
  bool sourceStridedFloat = false;
  bool sourceStridedHalf = false;
  bool destinationStridedFloat = false;
  bool destinationStridedHalf = false;
};

thread_local ExternalMetalBufferContext *gExternalMetalBufferContext = nullptr;

bool configureExternalMetalBufferLayout(
  const MetalBufferImageView &view,
  const RenderWindow &window,
  int32_t width,
  int32_t height,
  HostBufferLayout &layout,
  bool &compactFloat,
  bool &compactHalf,
  bool &stridedFloat,
  bool &stridedHalf,
  std::string &error
) {
  compactFloat = false;
  compactHalf = false;
  stridedFloat = false;
  stridedHalf = false;
  if (!view.buffer || view.components != 4 || (view.bytesPerComponent != 2 && view.bytesPerComponent != 4)) {
    error = "OFX Metal buffers must be RGBA half or RGBA float.";
    return false;
  }
  const int32_t startX = window.x1 - view.x1;
  const int32_t startY = window.y1 - view.y1;
  if (width <= 0 || height <= 0 ||
      startX < 0 || startY < 0 ||
      startX + width > view.width ||
      startY + height > view.height) {
    error = "OFX Metal render window is outside the supplied image buffer bounds.";
    return false;
  }
  const int32_t pixelBytes = view.components * view.bytesPerComponent;
  const int64_t minimumRowBytes = static_cast<int64_t>(startX + width) * pixelBytes;
  if (view.rowBytes < minimumRowBytes) {
    error = "OFX Metal image row bytes are smaller than the requested render window.";
    return false;
  }
  const int64_t startByteOffset64 =
    static_cast<int64_t>(startY) * view.rowBytes +
    static_cast<int64_t>(startX) * pixelBytes;
  if (startByteOffset64 < 0 || startByteOffset64 > std::numeric_limits<uint32_t>::max()) {
    error = "OFX Metal image buffer layout exceeds the supported 32-bit staging offset range.";
    return false;
  }

  layout.width = static_cast<uint32_t>(width);
  layout.height = static_cast<uint32_t>(height);
  layout.rowBytes = static_cast<uint32_t>(view.rowBytes);
  layout.startByteOffset = static_cast<uint32_t>(startByteOffset64);

  const bool compact = layout.startByteOffset == 0u && view.rowBytes == width * pixelBytes;
  if (view.bytesPerComponent == 4) {
    compactFloat = compact;
    stridedFloat = !compact;
  } else {
    compactHalf = compact;
    stridedHalf = !compact;
  }
  return true;
}

} // namespace

struct MetalRenderer::Impl {
  id<MTLDevice> device = nil;
  id<MTLCommandQueue> commandQueue = nil;
  id<MTLComputePipelineState> enlargerResamplePipeline = nil;
  id<MTLComputePipelineState> grainPipeline = nil;
  id<MTLComputePipelineState> halationRawExposurePipeline = nil;
  id<MTLComputePipelineState> halationBoostMaxPipeline = nil;
  id<MTLComputePipelineState> halationBoostReduceMaxPipeline = nil;
  id<MTLComputePipelineState> halationBoostApplyPipeline = nil;
  id<MTLComputePipelineState> halationScatterCoreBlurXPipeline = nil;
  id<MTLComputePipelineState> halationScatterCoreBlurYPipeline = nil;
  id<MTLComputePipelineState> halationScatterTailBlurXPipeline = nil;
  id<MTLComputePipelineState> halationScatterTailBlurYPipeline = nil;
  id<MTLComputePipelineState> halationScatterTailGroupBlurXPipeline = nil;
  id<MTLComputePipelineState> halationScatterTailGroupBlurYPipeline = nil;
  id<MTLComputePipelineState> halationScatterResolvePipeline = nil;
  id<MTLComputePipelineState> halationClearPipeline = nil;
  id<MTLComputePipelineState> halationBounceBlurXPipeline = nil;
  id<MTLComputePipelineState> halationBounceBlurYAccumulatePipeline = nil;
  id<MTLComputePipelineState> halationResolveLogRawPipeline = nil;
  id<MTLComputePipelineState> halationResolveDensityPipeline = nil;
  id<MTLComputePipelineState> rawToLogRawPipeline = nil;
  id<MTLComputePipelineState> developFromRawPipeline = nil;
  id<MTLComputePipelineState> diffusionComponentBlurXPipeline = nil;
  id<MTLComputePipelineState> diffusionComponentBlurYAccumulatePipeline = nil;
  id<MTLComputePipelineState> diffusionGroupBlurXPipeline = nil;
  id<MTLComputePipelineState> diffusionGroupBlurYAccumulatePipeline = nil;
  id<MTLComputePipelineState> diffusionDownsamplePipeline = nil;
  id<MTLComputePipelineState> diffusionDownsampleBlurXPipeline = nil;
  id<MTLComputePipelineState> diffusionDownsampleBlurYPipeline = nil;
  id<MTLComputePipelineState> diffusionDownsampleUpsampleAccumulatePipeline = nil;
  id<MTLComputePipelineState> diffusionDownsampleGroupBlurXPipeline = nil;
  id<MTLComputePipelineState> diffusionDownsampleGroupBlurYPipeline = nil;
  id<MTLComputePipelineState> diffusionDownsampleGroupUpsampleAccumulatePipeline = nil;
  id<MTLComputePipelineState> diffusionDownsampleBlurXHalfPipeline = nil;
  id<MTLComputePipelineState> diffusionDownsampleBlurYHalfPipeline = nil;
  id<MTLComputePipelineState> diffusionDownsampleUpsampleAccumulateHalfPipeline = nil;
  id<MTLComputePipelineState> diffusionDownsampleGroupBlurXHalfPipeline = nil;
  id<MTLComputePipelineState> diffusionDownsampleGroupBlurYHalfPipeline = nil;
  id<MTLComputePipelineState> diffusionDownsampleGroupUpsampleAccumulateHalfPipeline = nil;
  id<MTLComputePipelineState> diffusionResolvePipeline = nil;
  id<MTLComputePipelineState> developFromLogRawPipeline = nil;
  id<MTLComputePipelineState> dirCorrectionFromDensityPipeline = nil;
  id<MTLComputePipelineState> copyBufferPipeline = nil;
  id<MTLComputePipelineState> halfToFloatBufferPipeline = nil;
  id<MTLComputePipelineState> floatToHalfBufferPipeline = nil;
  id<MTLComputePipelineState> stridedFloatToFloatBufferPipeline = nil;
  id<MTLComputePipelineState> stridedHalfToFloatBufferPipeline = nil;
  id<MTLComputePipelineState> floatToStridedFloatBufferPipeline = nil;
  id<MTLComputePipelineState> floatToStridedHalfBufferPipeline = nil;
  id<MTLComputePipelineState> dirBaselinePipeline = nil;
  id<MTLComputePipelineState> dirBlurXPipeline = nil;
  id<MTLComputePipelineState> dirBlurYPipeline = nil;
  id<MTLComputePipelineState> dirTailBlurXPipeline = nil;
  id<MTLComputePipelineState> dirTailBlurYAccumulatePipeline = nil;
  id<MTLComputePipelineState> dirTailMpsAccumulatePipeline = nil;
  id<MTLComputePipelineState> dirRedevelopPipeline = nil;
  id<MTLComputePipelineState> previewGrainFromDensityPipeline = nil;
  id<MTLComputePipelineState> productionGrainLayersFromDensityPipeline = nil;
  id<MTLComputePipelineState> grainLayerBlurXPipeline = nil;
  id<MTLComputePipelineState> grainLayerBlurYPipeline = nil;
  id<MTLComputePipelineState> grainMicroSourcePipeline = nil;
  id<MTLComputePipelineState> grainMicroBlurXPipeline = nil;
  id<MTLComputePipelineState> grainMicroBlurYPipeline = nil;
  id<MTLComputePipelineState> grainResolveDensityPipeline = nil;
  id<MTLComputePipelineState> grainDensityBlurXPipeline = nil;
  id<MTLComputePipelineState> grainDensityBlurYPipeline = nil;
  id<MTLComputePipelineState> grainApplyControlsPipeline = nil;
  id<MTLComputePipelineState> grainSynthesisLayersFromDensityPipeline = nil;
  id<MTLComputePipelineState> grainSynthesisLayersFromDensityFixedRadiusPipeline = nil;
  id<MTLComputePipelineState> grainSynthesisTargetDensityPipeline = nil;
  id<MTLComputePipelineState> grainSynthesisTargetDensityNonLayeredPipeline = nil;
  id<MTLComputePipelineState> grainSynthesisTargetDensityHalfPipeline = nil;
  id<MTLComputePipelineState> grainSynthesisTargetDensityNonLayeredHalfPipeline = nil;
  id<MTLComputePipelineState> grainSynthesisTargetDensityTexturePipeline = nil;
  id<MTLComputePipelineState> grainSynthesisTargetDensityNonLayeredTexturePipeline = nil;
  id<MTLComputePipelineState> grainSynthesisLayersFromTargetDensityPipeline = nil;
  id<MTLComputePipelineState> grainSynthesisLayersFromTargetDensityFixedRadiusPipeline = nil;
  id<MTLComputePipelineState> grainSynthesisLayersFromTargetDensityNonLayeredPipeline = nil;
  id<MTLComputePipelineState> grainSynthesisLayersFromTargetDensityNonLayeredFixedRadiusPipeline = nil;
  id<MTLComputePipelineState> grainSynthesisLayersFromTargetDensityHalfPipeline = nil;
  id<MTLComputePipelineState> grainSynthesisLayersFromTargetDensityHalfFixedRadiusPipeline = nil;
  id<MTLComputePipelineState> grainSynthesisLayersFromTargetDensityNonLayeredHalfPipeline = nil;
  id<MTLComputePipelineState> grainSynthesisLayersFromTargetDensityNonLayeredHalfFixedRadiusPipeline = nil;
  id<MTLComputePipelineState> grainSynthesisLayersFromTargetDensityTexturePipeline = nil;
  id<MTLComputePipelineState> grainSynthesisLayersFromTargetDensityTextureFixedRadiusPipeline = nil;
  id<MTLComputePipelineState> grainSynthesisLayersFromTargetDensityNonLayeredTexturePipeline = nil;
  id<MTLComputePipelineState> grainSynthesisLayersFromTargetDensityNonLayeredTextureFixedRadiusPipeline = nil;
  id<MTLComputePipelineState> grainSynthesisResolveDensityPipeline = nil;
  id<MTLComputePipelineState> filteredEnlargerResponsePipeline = nil;
  id<MTLComputePipelineState> frameConstantsPipeline = nil;
  id<MTLComputePipelineState> finalFromFilmDensityPipeline = nil;
  id<MTLComputePipelineState> printRawFromFilmDensityPipeline = nil;
  id<MTLComputePipelineState> printRawFromNegativeLightPipeline = nil;
  id<MTLComputePipelineState> printDensityFromPrintRawPipeline = nil;
  id<MTLComputePipelineState> profilePrintScanFromDensityPipeline = nil;
  id<MTLComputePipelineState> profileFinalizeOutputPipeline = nil;
  id<MTLComputePipelineState> finalFromPrintRawPipeline = nil;
  id<MTLComputePipelineState> printGlareGeneratePipeline = nil;
  id<MTLComputePipelineState> printGlareBlurXPipeline = nil;
  id<MTLComputePipelineState> printGlareBlurYPipeline = nil;
  id<MTLComputePipelineState> printGlareApplyPipeline = nil;
  id<MTLComputePipelineState> scannerBlurXPipeline = nil;
  id<MTLComputePipelineState> scannerBlurYPipeline = nil;
  id<MTLComputePipelineState> unsharpBlurXPipeline = nil;
  id<MTLComputePipelineState> unsharpBlurYPipeline = nil;
  id<MTLComputePipelineState> bufferToTexturePipeline = nil;
  id<MTLComputePipelineState> textureToBufferPipeline = nil;
  id<MTLComputePipelineState> scannerBlurXTexturePipeline = nil;
  id<MTLComputePipelineState> scannerBlurYTexturePipeline = nil;
  id<MTLComputePipelineState> unsharpBlurXTexturePipeline = nil;
  id<MTLComputePipelineState> unsharpBlurYTexturePipeline = nil;
  id<MTLComputePipelineState> scannerFinalizePipeline = nil;
  id<MTLComputePipelineState> scannerFinalizeTexturePipeline = nil;
  std::vector<float> hanatosSpectraData;
  std::vector<float> outputGamutCompressionData;
  StaticProfileResources staticResources;
  std::vector<id<MTLBuffer>> scratchBuffers;
  std::vector<id<MTLTexture>> scratchTextures;
  std::vector<float> autoExposureLuminance;
  size_t scratchCursor = 0;
  size_t textureScratchCursor = 0;
  KernelSpectralInfo spectralInfo{};
  MetalRenderDiagnostics diagnostics{};
  std::unordered_map<const void *, std::string> pipelineNames;
  std::mutex renderMutex;
  bool preferPrivateScratch = true;
  bool passGpuTimingEnabled = false;
  bool useScannerTextures = false;
  bool scannerMps = false;
  bool halationGroupedTail = false;
  bool grainBlurRecurrence = true;
  bool useLegacyGrainSynthesis = false;
  bool linearFinalOutput = false;
  GrainSynthesisSamplerMode grainSynthesisSamplerMode = GrainSynthesisSamplerMode::R2;
  GrainSynthesisCellMode grainSynthesisCellMode = GrainSynthesisCellMode::OffsetList;
  GrainSynthesisTargetStorageMode grainSynthesisTargetStorageMode = GrainSynthesisTargetStorageMode::FloatBuffer;
  DirTailBackend dirTailBackend = DirTailBackend::Mps;
  DensityCurveLookupMode densityCurveLookupMode = DensityCurveLookupMode::Binary;
  SpectralTransmittanceMode spectralTransmittanceMode = SpectralTransmittanceMode::Pow;
  uint32_t grainSynthesisRadiusLutSize = 512u;
  uint32_t diffusionGroupSize = 2;
  float diffusionClusterSigmaRatio = 0.10f;
  std::string passTimingMode = "off";
  std::string blurBackend = "custom";
  std::string blurDownsample = "auto";
  std::string intermediatePrecision = "float";
  std::string diffusionClusterSigma = "0.10";
  std::string densityCurveLookup = "binary";
  std::string spectralTransmittance = "pow";
  std::string finalCoreMode = "fused";
  std::unordered_map<int, MPSImageGaussianBlur *> mpsGaussianBlurCache;
  uint32_t forcedThreadgroupWidth = 0;
  uint32_t forcedThreadgroupHeight = 0;
  std::string threadgroupMode = "auto";
  std::string lastError;

  id<MTLBuffer> newSharedBuffer(const void *bytes, NSUInteger length, const char *name) {
    if (!bytes || length == 0) {
      lastError = std::string("Unable to create empty Metal buffer ") + name + ".";
      return nil;
    }
    id<MTLBuffer> buffer = [device newBufferWithBytes:bytes length:length options:MTLResourceStorageModeShared];
    if (!buffer) {
      lastError = std::string("Unable to create Metal buffer ") + name + ".";
    } else {
      diagnostics.staticAllocationBytes += length;
      diagnostics.staticAllocationCount += 1;
      diagnostics.uploadBytes += length;
    }
    return buffer;
  }

  id<MTLBuffer> newStaticBuffer(const void *bytes, NSUInteger length, const char *name) {
    if (!bytes || length == 0) {
      lastError = std::string("Unable to create empty Metal buffer ") + name + ".";
      return nil;
    }
    if (!commandQueue) {
      return newSharedBuffer(bytes, length, name);
    }
    id<MTLBuffer> privateBuffer = [device newBufferWithLength:length options:MTLResourceStorageModePrivate];
    id<MTLBuffer> uploadBuffer = [device newBufferWithBytes:bytes length:length options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> uploadCommandBuffer = [commandQueue commandBuffer];
    id<MTLBlitCommandEncoder> blitEncoder = [uploadCommandBuffer blitCommandEncoder];
    if (!privateBuffer || !uploadBuffer || !uploadCommandBuffer || !blitEncoder) {
      return newSharedBuffer(bytes, length, name);
    }
    [blitEncoder copyFromBuffer:uploadBuffer sourceOffset:0 toBuffer:privateBuffer destinationOffset:0 size:length];
    [blitEncoder endEncoding];
    [uploadCommandBuffer commit];
    [uploadCommandBuffer waitUntilCompleted];
    if ([uploadCommandBuffer status] == MTLCommandBufferStatusError) {
      return newSharedBuffer(bytes, length, name);
    }
    diagnostics.staticAllocationBytes += length;
    diagnostics.staticAllocationCount += 1;
    diagnostics.uploadBytes += length;
    return privateBuffer;
  }

  id<MTLBuffer> scratchBuffer(NSUInteger length, const char *name, MTLStorageMode storageMode) {
    length = std::max<NSUInteger>(length, 16);
    const size_t index = scratchCursor++;
    if (index >= scratchBuffers.size()) {
      scratchBuffers.resize(index + 1u);
    }
    id<MTLBuffer> buffer = scratchBuffers[index];
    if (!buffer || [buffer length] < length || [buffer storageMode] != storageMode) {
      const MTLResourceOptions options = storageMode == MTLStorageModePrivate
        ? MTLResourceStorageModePrivate
        : MTLResourceStorageModeShared;
      buffer = [device newBufferWithLength:length options:options];
      if (!buffer && storageMode == MTLStorageModePrivate) {
        preferPrivateScratch = false;
        diagnostics.privateScratchEnabled = false;
        storageMode = MTLStorageModeShared;
        buffer = [device newBufferWithLength:length options:MTLResourceStorageModeShared];
      }
      if (!buffer) {
        lastError = std::string("Unable to allocate Metal scratch buffer ") + name + ".";
        return nil;
      }
      scratchBuffers[index] = buffer;
      diagnostics.scratchAllocationBytes += length;
      diagnostics.scratchAllocationCount += 1;
      if (storageMode == MTLStorageModePrivate) {
        diagnostics.privateScratchAllocationBytes += length;
        diagnostics.privateScratchAllocationCount += 1;
      } else {
        diagnostics.sharedScratchAllocationBytes += length;
        diagnostics.sharedScratchAllocationCount += 1;
      }
    }
    return buffer;
  }

  id<MTLBuffer> sharedScratchBuffer(NSUInteger length, const char *name) {
    return scratchBuffer(length, name, MTLStorageModeShared);
  }

  id<MTLBuffer> gpuScratchBuffer(NSUInteger length, const char *name) {
    return scratchBuffer(length, name, preferPrivateScratch ? MTLStorageModePrivate : MTLStorageModeShared);
  }

  void retainScratchResourcesUntilCompleted(id<MTLCommandBuffer> commandBuffer) {
    if (!commandBuffer) {
      return;
    }
    NSMutableArray<id<MTLBuffer>> *buffers = [NSMutableArray array];
    const size_t usedBufferCount = std::min(scratchCursor, scratchBuffers.size());
    for (size_t i = 0; i < usedBufferCount; ++i) {
      id<MTLBuffer> buffer = scratchBuffers[i];
      if (buffer) {
        [buffers addObject:buffer];
        scratchBuffers[i] = nil;
      }
    }

    NSMutableArray<id<MTLTexture>> *textures = [NSMutableArray array];
    const size_t usedTextureCount = std::min(textureScratchCursor, scratchTextures.size());
    for (size_t i = 0; i < usedTextureCount; ++i) {
      id<MTLTexture> texture = scratchTextures[i];
      if (texture) {
        [textures addObject:texture];
        scratchTextures[i] = nil;
      }
    }

    [commandBuffer addCompletedHandler:^(__unused id<MTLCommandBuffer> completedCommandBuffer) {
      (void)buffers;
      (void)textures;
    }];
  }

  id<MTLTexture> gpuScratchTexture(
    NSUInteger width,
    NSUInteger height,
    const char *name,
    MTLPixelFormat pixelFormat = MTLPixelFormatRGBA32Float
  ) {
    const size_t index = textureScratchCursor++;
    if (index >= scratchTextures.size()) {
      scratchTextures.resize(index + 1u);
    }
    id<MTLTexture> texture = scratchTextures[index];
    if (!texture || [texture width] < width || [texture height] < height ||
        [texture textureType] != MTLTextureType2D || [texture pixelFormat] != pixelFormat) {
      MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:pixelFormat
                                                                                            width:width
                                                                                           height:height
                                                                                        mipmapped:NO];
      descriptor.storageMode = MTLStorageModePrivate;
      descriptor.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
      texture = [device newTextureWithDescriptor:descriptor];
      if (!texture) {
        lastError = std::string("Unable to allocate Metal scratch texture ") + name + ".";
        return nil;
      }
      scratchTextures[index] = texture;
      const uint64_t bytesPerPixel = pixelFormat == MTLPixelFormatRGBA16Float ? 4u * sizeof(uint16_t) : 4u * sizeof(float);
      const uint64_t bytes = static_cast<uint64_t>(width) * static_cast<uint64_t>(height) * bytesPerPixel;
      diagnostics.scratchAllocationBytes += bytes;
      diagnostics.scratchAllocationCount += 1;
      diagnostics.privateScratchAllocationBytes += bytes;
      diagnostics.privateScratchAllocationCount += 1;
    }
    return texture;
  }

  id<MTLTexture> gpuScratchTextureArray(NSUInteger width, NSUInteger height, NSUInteger depth, const char *name) {
    const size_t index = textureScratchCursor++;
    if (index >= scratchTextures.size()) {
      scratchTextures.resize(index + 1u);
    }
    id<MTLTexture> texture = scratchTextures[index];
    if (!texture || [texture width] < width || [texture height] < height ||
        [texture arrayLength] < depth || [texture textureType] != MTLTextureType2DArray ||
        [texture pixelFormat] != MTLPixelFormatR16Float) {
      MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR16Float
                                                                                            width:width
                                                                                           height:height
                                                                                        mipmapped:NO];
      descriptor.textureType = MTLTextureType2DArray;
      descriptor.arrayLength = depth;
      descriptor.storageMode = MTLStorageModePrivate;
      descriptor.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
      texture = [device newTextureWithDescriptor:descriptor];
      if (!texture) {
        lastError = std::string("Unable to allocate Metal scratch texture ") + name + ".";
        return nil;
      }
      scratchTextures[index] = texture;
      const uint64_t bytes = static_cast<uint64_t>(width) * static_cast<uint64_t>(height) *
        static_cast<uint64_t>(depth) * sizeof(uint16_t);
      diagnostics.scratchAllocationBytes += bytes;
      diagnostics.scratchAllocationCount += 1;
      diagnostics.privateScratchAllocationBytes += bytes;
      diagnostics.privateScratchAllocationCount += 1;
    }
    return texture;
  }

  MPSImageGaussianBlur *cachedMpsGaussianBlur(float sigma) {
    if (!(sigma > 1.0e-4f)) {
      return nil;
    }
    const int key = std::max(1, static_cast<int>(std::lround(sigma * 1024.0f)));
    auto existing = mpsGaussianBlurCache.find(key);
    if (existing != mpsGaussianBlurCache.end()) {
      return existing->second;
    }
    MPSImageGaussianBlur *blur = [[MPSImageGaussianBlur alloc] initWithDevice:device sigma:sigma];
    if (!blur) {
      lastError = "Unable to create MPS Gaussian blur.";
      return nil;
    }
    blur.edgeMode = MPSImageEdgeModeClamp;
    blur.options = MPSKernelOptionsSkipAPIValidation;
    mpsGaussianBlurCache.emplace(key, blur);
    return blur;
  }

  void beginScratchFrame() {
    scratchCursor = 0;
    textureScratchCursor = 0;
  }

  void releaseTransientResources() {
    scratchBuffers.clear();
    scratchBuffers.shrink_to_fit();
    scratchTextures.clear();
    scratchTextures.shrink_to_fit();
    autoExposureLuminance.clear();
    autoExposureLuminance.shrink_to_fit();
    scratchCursor = 0;
    textureScratchCursor = 0;
  }

  std::string pipelineName(id<MTLComputePipelineState> pipeline) const {
    const auto it = pipelineNames.find((__bridge const void *)pipeline);
    return it == pipelineNames.end() ? "unknown" : it->second;
  }

  id<MTLCounterSet> timestampCounterSet() const {
    if (!device || ![device respondsToSelector:@selector(counterSets)]) {
      return nil;
    }
    for (id<MTLCounterSet> counterSet in [device counterSets]) {
      if ([[counterSet name] isEqualToString:MTLCommonCounterSetTimestamp]) {
        return counterSet;
      }
    }
    return nil;
  }

  bool supportsDispatchCounterSampling() const {
    if (!device || ![device respondsToSelector:@selector(supportsCounterSampling:)]) {
      return false;
    }
    if (@available(macOS 11.0, *)) {
      return [device supportsCounterSampling:MTLCounterSamplingPointAtDispatchBoundary];
    }
    return false;
  }

  bool supportsStageCounterSampling() const {
    if (!device || ![device respondsToSelector:@selector(supportsCounterSampling:)]) {
      return false;
    }
    if (@available(macOS 11.0, *)) {
      return [device supportsCounterSampling:MTLCounterSamplingPointAtStageBoundary];
    }
    return false;
  }

  double commandBufferGpuMilliseconds(id<MTLCommandBuffer> buffer) const {
    if (!buffer) {
      return 0.0;
    }
    const CFTimeInterval gpuStart = [buffer GPUStartTime];
    const CFTimeInterval gpuEnd = [buffer GPUEndTime];
    if (!(gpuEnd > gpuStart) || gpuStart <= 0.0) {
      return 0.0;
    }
    return (gpuEnd - gpuStart) * 1000.0;
  }

  void populateDeviceDiagnostics() {
    diagnostics.metalDeviceName = device && [device name] ? [[device name] UTF8String] : "";
    diagnostics.passDispatchCounterSamplingSupported = supportsDispatchCounterSampling();
    diagnostics.passStageCounterSamplingSupported = supportsStageCounterSampling();
    if (!device) {
      return;
    }
    if ([device respondsToSelector:@selector(recommendedMaxWorkingSetSize)]) {
      diagnostics.metalRecommendedMaxWorkingSetSize = static_cast<uint64_t>([device recommendedMaxWorkingSetSize]);
    }
    if ([device respondsToSelector:@selector(currentAllocatedSize)]) {
      diagnostics.metalCurrentAllocatedSize = static_cast<uint64_t>([device currentAllocatedSize]);
    }
    if ([device respondsToSelector:@selector(maxBufferLength)]) {
      diagnostics.metalMaxBufferLength = static_cast<uint64_t>([device maxBufferLength]);
    }
  }

  double timestampTicksToMilliseconds(uint64_t ticks) const {
    if (ticks == MTLCounterErrorValue) {
      return 0.0;
    }
    uint64_t frequency = 1000000000ull;
    if (@available(macOS 26.0, *)) {
      if ([device respondsToSelector:@selector(queryTimestampFrequency)]) {
        const uint64_t queried = [device queryTimestampFrequency];
        if (queried > 0ull) {
          frequency = queried;
        }
      }
    }
    return static_cast<double>(ticks) * 1000.0 / static_cast<double>(frequency);
  }

  bool prepareStaticResources(const RenderParams &params) {
    if (staticResources.validFor(params)) {
      return true;
    }

    staticResources.reset();
    const ProfileCurveSet *filmCurves = selectedFilmCurves(params);
    const ProfileCurveSet *paperCurves = selectedPaperCurves(params);
    if (!filmCurves || filmCurves->exposureCount == 0 || !filmCurves->logExposure || !filmCurves->densityCurves) {
      lastError = "Unable to locate generated film density curves.";
      return false;
    }
    if (!paperCurves || paperCurves->exposureCount == 0 || !paperCurves->logExposure || !paperCurves->densityCurves) {
      lastError = "Unable to locate generated paper density curves.";
      return false;
    }
    if (filmCurves->wavelengthCount == 0 || !filmCurves->wavelengths || !filmCurves->logSensitivity) {
      lastError = "Unable to locate generated film spectral data.";
      return false;
    }
    if (params.rgbToRawMethod == RgbToRawMethod::Hanatos2025 && !filmCurves->bandpassHanatos2025) {
      lastError = "Unable to locate archived Hanatos 2025 film bandpass data.";
      return false;
    }
    if (params.rgbToRawMethod == RgbToRawMethod::Hanatos2026 &&
        (!filmCurves->hanatos2026WindowParams || !filmCurves->referenceIlluminantSpectrum)) {
      lastError = "Unable to locate generated Hanatos 2026 film adaptation data.";
      return false;
    }
    if (paperCurves->wavelengthCount != filmCurves->wavelengthCount || !paperCurves->logSensitivity) {
      lastError = "Unable to locate generated paper spectral data.";
      return false;
    }
    if (!filmCurves->channelDensity || !filmCurves->baseDensity || !filmCurves->densityCurveMinimum ||
        !filmCurves->densityCurveLayers || !filmCurves->densityCurveLayerMaxima) {
      lastError = "Unable to locate generated film spectral density data.";
      return false;
    }
    if (!filmCurves->halationStrength || !filmCurves->halationFirstSigmaUm) {
      lastError = "Unable to locate generated film halation data.";
      return false;
    }
    if (!filmCurves->scanIlluminant || !filmCurves->scanToOutputRgb || !standardObserverCmfs()) {
      lastError = "Unable to locate generated film scan data.";
      return false;
    }
    if (!filmCurves->inputToReferenceXyz || !filmCurves->inputToSrgb ||
        !filmCurves->mallettBasisIlluminant || filmCurves->mallettRawMidgrayGreen <= 0.0f) {
      lastError = "Unable to locate generated RGB-to-raw reference data.";
      return false;
    }
    if (!paperCurves->channelDensity || !paperCurves->baseDensity || !paperCurves->scanIlluminant || !paperCurves->scanToOutputRgb) {
      lastError = "Unable to locate generated paper scan data.";
      return false;
    }
    if (!thKg3Illuminant() || !customEnlargerFilters() || !neutralPrintFilters() || !academyPrinterDensityData()) {
      lastError = "Unable to locate generated print exposure data.";
      return false;
    }
    if (!colorDecodeLuts() || !colorEncodeLuts() || !colorTransferKinds() || !colorTransferParams() || !inputMeterXyzMatrices() ||
        outputGamutCompressionData.size() != kSpektraOutputGamutCompressionElementCount) {
      lastError = "Unable to locate generated color transform data.";
      return false;
    }

    StaticProfileResources next{};
    next.film = params.film;
    next.paper = params.paper;
    next.rgbToRawMethod = params.rgbToRawMethod;
    next.cameraUvFilterEnabled = params.cameraUvFilterEnabled;
    next.cameraUvCutNm = params.cameraUvCutNm;
    next.cameraIrFilterEnabled = params.cameraIrFilterEnabled;
    next.cameraIrCutNm = params.cameraIrCutNm;
    next.processNegativePrintTiming = params.printTiming;
    next.processNegativeFilterC = params.filterC;
    next.processNegativeFilterMShift = params.filterMShift;
    next.processNegativeFilterYShift = params.filterYShift;
    next.processNegativePreflashMFilterShift = params.preflashMFilterShift;
    next.processNegativePreflashYFilterShift = params.preflashYFilterShift;
    next.filmCurves = filmCurves;
    next.paperCurves = paperCurves;
    next.curveInfo = {filmCurves->exposureCount, 0u, 0u, 0u};
    next.paperCurveInfo = {paperCurves->exposureCount, 0u, 0u, 0u};
    next.colorInfo = {
      kSpektraColorSpaceCount,
      kSpektraColorTransferLutSize,
      colorDecodeLutMin(),
      colorDecodeLutMax(),
      colorEncodeLutMin(),
      colorEncodeLutMax(),
      0.0f,
      0.0f
    };
    next.spectralInfo = spectralInfo;
    next.spectralInfo.filmWavelengthCount = filmCurves->wavelengthCount;
    next.spectralInfo.filmCount = kSpektraFilmCount;
    next.spectralInfo.paperCount = kSpektraPaperCount;
    next.spectralInfo.filmPositive = std::strcmp(filmCurves->type, "positive") == 0 ? 1u : 0u;
    next.spectralInfo.mallettRawMidgrayGreen = filmCurves->mallettRawMidgrayGreen;
    next.spectralInfo.filmDensityCurveMinimum0 = filmCurves->densityCurveMinimum[0];
    next.spectralInfo.filmDensityCurveMinimum1 = filmCurves->densityCurveMinimum[1];
    next.spectralInfo.filmDensityCurveMinimum2 = filmCurves->densityCurveMinimum[2];
    const std::array<float, 3> filmDensityCurveMaximum = densityCurveMaximums(*filmCurves);
    next.spectralInfo.filmDensityCurveMaximum0 = filmDensityCurveMaximum[0];
    next.spectralInfo.filmDensityCurveMaximum1 = filmDensityCurveMaximum[1];
    next.spectralInfo.filmDensityCurveMaximum2 = filmDensityCurveMaximum[2];
    const std::array<float, 3> paperDensityCurveMaximum = densityCurveMaximums(*paperCurves);
    next.spectralInfo.paperDensityCurveMaximum0 = paperDensityCurveMaximum[0];
    next.spectralInfo.paperDensityCurveMaximum1 = paperDensityCurveMaximum[1];
    next.spectralInfo.paperDensityCurveMaximum2 = paperDensityCurveMaximum[2];

    const NSUInteger logExposureBytes = static_cast<NSUInteger>(filmCurves->exposureCount) * 2u * sizeof(float);
    const NSUInteger densityCurveBytes = static_cast<NSUInteger>(filmCurves->exposureCount) * 3u * sizeof(float);
    const NSUInteger densityLayerBytes = static_cast<NSUInteger>(filmCurves->exposureCount) * 9u * sizeof(float);
    const NSUInteger densityLayerMaxBytes = 9u * sizeof(float);
    const NSUInteger paperLogExposureBytes = static_cast<NSUInteger>(paperCurves->exposureCount) * 2u * sizeof(float);
    const NSUInteger paperDensityCurveBytes = static_cast<NSUInteger>(paperCurves->exposureCount) * 3u * sizeof(float);
    const NSUInteger wavelengthBytes = static_cast<NSUInteger>(filmCurves->wavelengthCount) * sizeof(float);
    const NSUInteger sensitivityBytes = static_cast<NSUInteger>(filmCurves->wavelengthCount) * 3u * sizeof(float);
    const NSUInteger baseDensityBytes = static_cast<NSUInteger>(filmCurves->wavelengthCount) * sizeof(float);
    const NSUInteger neutralPrintFilterBytes = static_cast<NSUInteger>(kSpektraPaperCount) * static_cast<NSUInteger>(kSpektraFilmCount) * 3u * sizeof(float);
    const NSUInteger inputMatrixBytes = static_cast<NSUInteger>(kSpektraColorSpaceCount) * 9u * sizeof(float);
    const NSUInteger transferLutBytes = static_cast<NSUInteger>(kSpektraColorSpaceCount) * static_cast<NSUInteger>(kSpektraColorTransferLutSize) * sizeof(float);
    const NSUInteger transferKindBytes = static_cast<NSUInteger>(kSpektraColorSpaceCount) * sizeof(uint32_t);
    std::vector<float> colorEncodeAndGamutData;
    colorEncodeAndGamutData.reserve(
      static_cast<size_t>(kSpektraColorSpaceCount) * static_cast<size_t>(kSpektraColorTransferLutSize) +
      outputGamutCompressionData.size() +
      static_cast<size_t>(kSpektraColorSpaceCount)
    );
    colorEncodeAndGamutData.insert(
      colorEncodeAndGamutData.end(),
      colorEncodeLuts(),
      colorEncodeLuts() + static_cast<size_t>(kSpektraColorSpaceCount) * static_cast<size_t>(kSpektraColorTransferLutSize)
    );
    colorEncodeAndGamutData.insert(
      colorEncodeAndGamutData.end(),
      outputGamutCompressionData.begin(),
      outputGamutCompressionData.end()
    );
    colorEncodeAndGamutData.insert(
      colorEncodeAndGamutData.end(),
      colorTransferParams(),
      colorTransferParams() + static_cast<size_t>(kSpektraColorSpaceCount)
    );

    const std::vector<float> baseFilmSensitivityLinear = makeLinearSensitivity(filmCurves->logSensitivity, filmCurves->wavelengthCount);
    const std::vector<float> filmSensitivityLinear = applyCameraBandPass(*filmCurves, baseFilmSensitivityLinear, params);
    const std::vector<float> paperSensitivityLinear = makeLinearSensitivity(paperCurves->logSensitivity, paperCurves->wavelengthCount);
    const std::vector<float> processNegativePaperWeights = makeProcessNegativePaperWeights(
      *paperCurves,
      paperSensitivityLinear,
      params,
      false
    );
    const std::vector<float> processNegativePreflashWeights = makeProcessNegativePaperWeights(
      *paperCurves,
      paperSensitivityLinear,
      params,
      true
    );
    const std::vector<float> filmCurveExposure = makePackedCurveExposure(filmCurves->logExposure, filmCurves->exposureCount);
    const std::vector<float> paperCurveExposure = makePackedCurveExposure(paperCurves->logExposure, paperCurves->exposureCount);
    const std::vector<float> filmSpectralDensity = makePackedSpectralDensity(
      filmCurves->channelDensity,
      filmCurves->baseDensity,
      filmCurves->wavelengthCount
    );
    const std::vector<float> paperSpectralDensity = makePackedSpectralDensity(
      paperCurves->channelDensity,
      paperCurves->baseDensity,
      paperCurves->wavelengthCount
    );
    const std::array<float, 9> mallettRawMatrix = makeMallettRawMatrix(
      *filmCurves,
      filmSensitivityLinear
    );
    const std::vector<float> hanatosRawResponse = makeHanatosRawResponsePair(
      *filmCurves,
      filmSensitivityLinear,
      hanatosSpectraData,
      hanatosSpectraLutInfo(),
      params.rgbToRawMethod
    );
    const std::vector<float> paperHanatosResponse = makeHanatosResponsePairFromWeights(
      *filmCurves,
      processNegativePaperWeights,
      hanatosSpectraData,
      hanatosSpectraLutInfo()
    );
    const std::vector<float> preflashPaperHanatosResponse = makeHanatosResponsePairFromWeights(
      *filmCurves,
      processNegativePreflashWeights,
      hanatosSpectraData,
      hanatosSpectraLutInfo()
    );

    std::vector<float> paperScanDensityData;
    paperScanDensityData.reserve(
      static_cast<size_t>(filmCurves->wavelengthCount) * 4u +
      static_cast<size_t>(filmCurves->exposureCount) * 9u +
      9u
    );
    paperScanDensityData.insert(paperScanDensityData.end(), paperCurves->channelDensity, paperCurves->channelDensity + filmCurves->wavelengthCount * 3u);
    paperScanDensityData.insert(paperScanDensityData.end(), paperCurves->baseDensity, paperCurves->baseDensity + filmCurves->wavelengthCount);
    paperScanDensityData.insert(paperScanDensityData.end(), filmCurves->densityCurveLayers, filmCurves->densityCurveLayers + filmCurves->exposureCount * 9u);
    paperScanDensityData.insert(paperScanDensityData.end(), filmCurves->densityCurveLayerMaxima, filmCurves->densityCurveLayerMaxima + 9u);

    std::vector<float> scanIlluminantsAndCmfs;
    scanIlluminantsAndCmfs.reserve(static_cast<size_t>(filmCurves->wavelengthCount) * 5u);
    scanIlluminantsAndCmfs.insert(scanIlluminantsAndCmfs.end(), filmCurves->scanIlluminant, filmCurves->scanIlluminant + filmCurves->wavelengthCount);
    scanIlluminantsAndCmfs.insert(scanIlluminantsAndCmfs.end(), paperCurves->scanIlluminant, paperCurves->scanIlluminant + filmCurves->wavelengthCount);
    scanIlluminantsAndCmfs.insert(scanIlluminantsAndCmfs.end(), standardObserverCmfs(), standardObserverCmfs() + filmCurves->wavelengthCount * 3u);
    const std::vector<float> scanProducts = makeScanProducts(
      filmCurves->scanIlluminant,
      paperCurves->scanIlluminant,
      filmCurves->baseDensity,
      paperCurves->baseDensity,
      standardObserverCmfs(),
      filmCurves->wavelengthCount
    );

    std::vector<float> scanToOutputRgbData;
    scanToOutputRgbData.reserve(static_cast<size_t>(kSpektraColorSpaceCount) * 18u);
    scanToOutputRgbData.insert(scanToOutputRgbData.end(), filmCurves->scanToOutputRgb, filmCurves->scanToOutputRgb + kSpektraColorSpaceCount * 9u);
    scanToOutputRgbData.insert(scanToOutputRgbData.end(), paperCurves->scanToOutputRgb, paperCurves->scanToOutputRgb + kSpektraColorSpaceCount * 9u);

    std::vector<float> unityHanatosBandpass;
    const float *bandpassHanatosData = filmCurves->bandpassHanatos2025;
    if (!bandpassHanatosData) {
      unityHanatosBandpass.assign(static_cast<size_t>(filmCurves->wavelengthCount) * 3u, 1.0f);
      bandpassHanatosData = unityHanatosBandpass.data();
    }

    next.curveInfoBuffer = newStaticBuffer(&next.curveInfo, sizeof(next.curveInfo), "film curve info");
    next.logExposureBuffer = newStaticBuffer(filmCurveExposure.data(), logExposureBytes, "film curve exposure");
    next.densityCurvesBuffer = newStaticBuffer(filmCurves->densityCurves, densityCurveBytes, "film density curves");
    next.spectralInfoBuffer = newStaticBuffer(&next.spectralInfo, sizeof(next.spectralInfo), "spectral info");
    next.wavelengthsBuffer = newStaticBuffer(filmCurves->wavelengths, wavelengthBytes, "film wavelengths");
    next.logSensitivityBuffer = newStaticBuffer(filmSensitivityLinear.data(), sensitivityBytes, "film linear sensitivity");
    next.bandpassHanatosBuffer = newStaticBuffer(bandpassHanatosData, sensitivityBytes, "film Hanatos bandpass");
    next.hanatosRawResponseBuffer = newStaticBuffer(hanatosRawResponse.data(), hanatosRawResponse.size() * sizeof(float), "film Hanatos raw response");
    next.paperHanatosResponseBuffer = newStaticBuffer(paperHanatosResponse.data(), paperHanatosResponse.size() * sizeof(float), "paper Hanatos response");
    next.preflashPaperHanatosResponseBuffer = newStaticBuffer(preflashPaperHanatosResponse.data(), preflashPaperHanatosResponse.size() * sizeof(float), "preflash paper Hanatos response");
    next.mallettBasisIlluminantBuffer = newStaticBuffer(mallettRawMatrix.data(), mallettRawMatrix.size() * sizeof(float), "film Mallett raw matrix");
    next.inputToReferenceXyzBuffer = newStaticBuffer(filmCurves->inputToReferenceXyz, inputMatrixBytes, "input to reference XYZ");
    next.inputToSrgbBuffer = newStaticBuffer(filmCurves->inputToSrgb, inputMatrixBytes, "input to sRGB");
    next.colorInfoBuffer = newStaticBuffer(&next.colorInfo, sizeof(next.colorInfo), "color info");
    next.colorDecodeLutBuffer = newStaticBuffer(colorDecodeLuts(), transferLutBytes, "color decode LUT");
    next.colorTransferKindBuffer = newStaticBuffer(colorTransferKinds(), transferKindBytes, "color transfer kind");
    next.paperCurveInfoBuffer = newStaticBuffer(&next.paperCurveInfo, sizeof(next.paperCurveInfo), "paper curve info");
    next.paperLogExposureBuffer = newStaticBuffer(paperCurveExposure.data(), paperLogExposureBytes, "paper curve exposure");
    next.paperDensityCurvesBuffer = newStaticBuffer(paperCurves->densityCurves, paperDensityCurveBytes, "paper density curves");
    next.filmChannelDensityBuffer = newStaticBuffer(filmCurves->channelDensity, sensitivityBytes, "film channel density");
    next.filmBaseDensityBuffer = newStaticBuffer(filmCurves->baseDensity, baseDensityBytes, "film base density");
    next.filmSpectralDensityBuffer = newStaticBuffer(filmSpectralDensity.data(), filmSpectralDensity.size() * sizeof(float), "packed film spectral density");
    next.paperLogSensitivityBuffer = newStaticBuffer(paperSensitivityLinear.data(), sensitivityBytes, "paper linear sensitivity");
    next.thKg3IlluminantBuffer = newStaticBuffer(thKg3Illuminant(), baseDensityBytes, "TH-KG3 illuminant");
    next.customEnlargerFiltersBuffer = newStaticBuffer(customEnlargerFilters(), sensitivityBytes, "custom enlarger filters");
    next.neutralPrintFiltersBuffer = newStaticBuffer(neutralPrintFilters(), neutralPrintFilterBytes, "neutral print filters");
    next.academyPrinterDensityDataBuffer = newStaticBuffer(
      academyPrinterDensityData(),
      sensitivityBytes + neutralPrintFilterBytes,
      "Academy printer density data"
    );
    next.paperScanDensityDataBuffer = newStaticBuffer(paperScanDensityData.data(), paperScanDensityData.size() * sizeof(float), "paper scan density data");
    next.paperSpectralDensityBuffer = newStaticBuffer(paperSpectralDensity.data(), paperSpectralDensity.size() * sizeof(float), "packed paper spectral density");
    next.scanIlluminantsAndCmfsBuffer = newStaticBuffer(scanIlluminantsAndCmfs.data(), scanIlluminantsAndCmfs.size() * sizeof(float), "scan illuminants and CMFs");
    next.scanProductsBuffer = newStaticBuffer(scanProducts.data(), scanProducts.size() * sizeof(float), "scan CMF products and inverse normalizations");
    next.scanToOutputRgbDataBuffer = newStaticBuffer(scanToOutputRgbData.data(), scanToOutputRgbData.size() * sizeof(float), "scan output matrices");
    next.colorEncodeLutBuffer = newStaticBuffer(colorEncodeAndGamutData.data(), colorEncodeAndGamutData.size() * sizeof(float), "color encode LUT and output gamut compression");

    if (!next.validFor(params)) {
      if (lastError.empty()) {
        lastError = "Unable to create static Metal resources.";
      }
      return false;
    }
    staticResources = next;
    lastError.clear();
    return true;
  }

  Impl() {
    @autoreleasepool {
      preferPrivateScratch = envString("SPEKTRAFILM_SCRATCH_STORAGE", "private") != "shared";
      useLegacyGrainSynthesis = envFlagEnabled("SPEKTRAFILM_GRAIN_SYNTHESIS_LEGACY");
      linearFinalOutput = envFlagEnabled("SPEKTRAFILM_LINEAR_FINAL_OUTPUT");
      const std::string grainSamplerText = envString("SPEKTRAFILM_GRAIN_SYNTHESIS_SAMPLER", "r2");
      if (grainSamplerText == "antithetic") {
        grainSynthesisSamplerMode = GrainSynthesisSamplerMode::Antithetic;
      } else if (grainSamplerText == "sobol-blue") {
        grainSynthesisSamplerMode = GrainSynthesisSamplerMode::SobolBlue;
      } else {
        grainSynthesisSamplerMode = GrainSynthesisSamplerMode::R2;
      }
      const std::string radiusLutText = envString("SPEKTRAFILM_GRAIN_SYNTHESIS_RADIUS_LUT", "512");
      if (radiusLutText == "off" || radiusLutText == "0") {
        grainSynthesisRadiusLutSize = 0u;
      } else if (radiusLutText == "256") {
        grainSynthesisRadiusLutSize = 256u;
      } else {
        grainSynthesisRadiusLutSize = 512u;
      }
      const std::string cellModeText = envString("SPEKTRAFILM_GRAIN_SYNTHESIS_CELL_MODE", "offset-list");
      if (cellModeText == "current") {
        grainSynthesisCellMode = GrainSynthesisCellMode::Current;
      } else if (cellModeText == "threadgroup-cache") {
        grainSynthesisCellMode = GrainSynthesisCellMode::ThreadgroupCache;
      } else {
        grainSynthesisCellMode = GrainSynthesisCellMode::OffsetList;
      }
      const std::string targetStorageText = envString("SPEKTRAFILM_GRAIN_SYNTHESIS_TARGET_STORAGE", "float-buffer");
      if (targetStorageText == "half-buffer") {
        grainSynthesisTargetStorageMode = GrainSynthesisTargetStorageMode::HalfBuffer;
      } else if (targetStorageText == "r16-texture-array") {
        grainSynthesisTargetStorageMode = GrainSynthesisTargetStorageMode::R16TextureArray;
      } else {
        grainSynthesisTargetStorageMode = GrainSynthesisTargetStorageMode::FloatBuffer;
      }
      passTimingMode = envString("SPEKTRAFILM_PASS_TIMING", "");
      if (passTimingMode.empty()) {
        passTimingMode = envFlagEnabled("SPEKTRAFILM_PASS_COUNTERS") ? "auto" : "off";
      }
      if (passTimingMode != "off" && passTimingMode != "auto" &&
          passTimingMode != "counter" && passTimingMode != "split") {
        passTimingMode = "off";
      }
      passGpuTimingEnabled = passTimingMode != "off";
      useScannerTextures = envString("SPEKTRAFILM_SCANNER_IMAGE_STORAGE", "buffer") == "texture";
      blurBackend = envString("SPEKTRAFILM_BLUR_BACKEND", "custom");
      if (blurBackend != "custom" && blurBackend != "mps" && blurBackend != "auto") {
        blurBackend = "custom";
      }
      blurDownsample = envString("SPEKTRAFILM_BLUR_DOWNSAMPLE", "auto");
      if (blurDownsample != "off" && blurDownsample != "2" && blurDownsample != "4" &&
          blurDownsample != "8" && blurDownsample != "auto") {
        blurDownsample = "off";
      }
      intermediatePrecision = envString("SPEKTRAFILM_INTERMEDIATE_PRECISION", "float");
      if (intermediatePrecision != "float" && intermediatePrecision != "half-blur") {
        intermediatePrecision = "float";
      }
      diffusionClusterSigma = envString("SPEKTRAFILM_DIFFUSION_CLUSTER_SIGMA", "0.10");
      if (diffusionClusterSigma == "0.05") {
        diffusionClusterSigmaRatio = 0.05f;
      } else if (diffusionClusterSigma == "0.10" || diffusionClusterSigma == "0.1") {
        diffusionClusterSigma = "0.10";
        diffusionClusterSigmaRatio = 0.10f;
      } else {
        diffusionClusterSigma = "off";
        diffusionClusterSigmaRatio = 0.0f;
      }
      halationGroupedTail = envFlagEnabled("SPEKTRAFILM_HALATION_GROUPED_TAIL");
      scannerMps = envFlagEnabled("SPEKTRAFILM_SCANNER_MPS");
      grainBlurRecurrence = envFlagEnabledOrDefault("SPEKTRAFILM_GRAIN_BLUR_RECURRENCE", true);
      dirTailBackend = envString("SPEKTRAFILM_DIR_TAIL_BACKEND", "mps") == "mps"
        ? DirTailBackend::Mps
        : DirTailBackend::Fused;
      densityCurveLookup = envString("SPEKTRAFILM_DENSITY_CURVE_LOOKUP", "binary");
      if (densityCurveLookup == "uniform" || densityCurveLookup == "uniform-linear" || densityCurveLookup == "linear") {
        densityCurveLookup = "uniform-linear";
        densityCurveLookupMode = DensityCurveLookupMode::UniformLinear;
      } else if (densityCurveLookup == "nearest" || densityCurveLookup == "uniform-nearest") {
        densityCurveLookup = "uniform-nearest";
        densityCurveLookupMode = DensityCurveLookupMode::UniformNearest;
      } else {
        densityCurveLookup = "binary";
        densityCurveLookupMode = DensityCurveLookupMode::Binary;
      }
      spectralTransmittance = envString("SPEKTRAFILM_SPECTRAL_TRANSMITTANCE", "pow");
      if (spectralTransmittance == "exp2") {
        spectralTransmittanceMode = SpectralTransmittanceMode::Exp2;
      } else if (spectralTransmittance == "fast-exp" || spectralTransmittance == "fast-exp2" || spectralTransmittance == "fast") {
        spectralTransmittance = "fast-exp";
        spectralTransmittanceMode = SpectralTransmittanceMode::FastExp;
      } else {
        spectralTransmittance = "pow";
        spectralTransmittanceMode = SpectralTransmittanceMode::Pow;
      }
      finalCoreMode = envString("SPEKTRAFILM_FINAL_CORE_MODE", "fused");
      if (finalCoreMode != "fused" && finalCoreMode != "staged") {
        finalCoreMode = "fused";
      }
      const std::string diffusionGroupSizeText = envString("SPEKTRAFILM_DIFFUSION_GROUP_SIZE", "2");
      if (diffusionGroupSizeText == "1") {
        diffusionGroupSize = 1u;
      } else if (diffusionGroupSizeText == "2") {
        diffusionGroupSize = 2u;
      } else {
        diffusionGroupSize = 4u;
      }
      threadgroupMode = envString("SPEKTRAFILM_THREADGROUP", "auto");
      if (threadgroupMode == "16x16") {
        forcedThreadgroupWidth = 16u;
        forcedThreadgroupHeight = 16u;
      } else if (threadgroupMode == "32x8") {
        forcedThreadgroupWidth = 32u;
        forcedThreadgroupHeight = 8u;
      } else if (threadgroupMode == "8x32") {
        forcedThreadgroupWidth = 8u;
        forcedThreadgroupHeight = 32u;
      } else if (threadgroupMode == "64x4") {
        forcedThreadgroupWidth = 64u;
        forcedThreadgroupHeight = 4u;
      } else {
        threadgroupMode = "auto";
      }

      device = MTLCreateSystemDefaultDevice();
      if (!device) {
        lastError = "Metal is not available on this system.";
        return;
      }
      commandQueue = [device newCommandQueue];
      if (!commandQueue) {
        lastError = "Unable to create Metal command queue.";
        return;
      }

      NSURL *libraryURL = findBundleResourceURL(@"SpektraFilm", @"metallib");
      if (!libraryURL) {
        lastError = "Unable to locate SpektraFilm.metallib in bundle resources.";
        return;
      }

      NSError *error = nil;
      id<MTLLibrary> library = [device newLibraryWithURL:libraryURL error:&error];
      if (!library) {
        lastError = error ? [[error localizedDescription] UTF8String] : "Unable to load Metal library.";
        return;
      }

      auto makePipeline = [&](NSString *name) -> id<MTLComputePipelineState> {
        id<MTLFunction> function = [library newFunctionWithName:name];
        if (!function) {
          lastError = std::string("Metal function ") + [name UTF8String] + " was not found.";
          return nil;
        }
        id<MTLComputePipelineState> pipeline = [device newComputePipelineStateWithFunction:function error:&error];
        if (!pipeline) {
          lastError = error ? [[error localizedDescription] UTF8String] : (std::string("Unable to create Metal pipeline ") + [name UTF8String] + ".");
          return nil;
        }
        pipelineNames[(__bridge const void *)pipeline] = [name UTF8String];
        return pipeline;
      };

      enlargerResamplePipeline = makePipeline(@"spektrafilm_enlarger_resample");
      grainPipeline = makePipeline(@"spektrafilm_grain_preview");
      halationRawExposurePipeline = makePipeline(@"spektrafilm_halation_raw_exposure");
      halationBoostMaxPipeline = makePipeline(@"spektrafilm_halation_boost_max");
      halationBoostReduceMaxPipeline = makePipeline(@"spektrafilm_halation_boost_reduce_max");
      halationBoostApplyPipeline = makePipeline(@"spektrafilm_halation_boost_apply");
      halationScatterCoreBlurXPipeline = makePipeline(@"spektrafilm_halation_scatter_core_blur_x");
      halationScatterCoreBlurYPipeline = makePipeline(@"spektrafilm_halation_scatter_core_blur_y");
      halationScatterTailBlurXPipeline = makePipeline(@"spektrafilm_halation_scatter_tail_blur_x");
      halationScatterTailBlurYPipeline = makePipeline(@"spektrafilm_halation_scatter_tail_blur_y");
      halationScatterTailGroupBlurXPipeline = makePipeline(@"spektrafilm_halation_scatter_tail_group_blur_x");
      halationScatterTailGroupBlurYPipeline = makePipeline(@"spektrafilm_halation_scatter_tail_group_blur_y");
      halationScatterResolvePipeline = makePipeline(@"spektrafilm_halation_scatter_resolve");
      halationClearPipeline = makePipeline(@"spektrafilm_halation_clear");
      halationBounceBlurXPipeline = makePipeline(@"spektrafilm_halation_bounce_blur_x");
      halationBounceBlurYAccumulatePipeline = makePipeline(@"spektrafilm_halation_bounce_blur_y_accumulate");
      halationResolveLogRawPipeline = makePipeline(@"spektrafilm_halation_resolve_log_raw");
      halationResolveDensityPipeline = makePipeline(@"spektrafilm_halation_resolve_density");
      rawToLogRawPipeline = makePipeline(@"spektrafilm_raw_to_log_raw");
      developFromRawPipeline = makePipeline(@"spektrafilm_develop_from_raw");
      diffusionComponentBlurXPipeline = makePipeline(@"spektrafilm_diffusion_component_blur_x");
      diffusionComponentBlurYAccumulatePipeline = makePipeline(@"spektrafilm_diffusion_component_blur_y_accumulate");
      diffusionGroupBlurXPipeline = makePipeline(@"spektrafilm_diffusion_group_blur_x");
      diffusionGroupBlurYAccumulatePipeline = makePipeline(@"spektrafilm_diffusion_group_blur_y_accumulate");
      diffusionDownsamplePipeline = makePipeline(@"spektrafilm_diffusion_downsample");
      diffusionDownsampleBlurXPipeline = makePipeline(@"spektrafilm_diffusion_downsample_blur_x");
      diffusionDownsampleBlurYPipeline = makePipeline(@"spektrafilm_diffusion_downsample_blur_y");
      diffusionDownsampleUpsampleAccumulatePipeline = makePipeline(@"spektrafilm_diffusion_downsample_upsample_accumulate");
      diffusionDownsampleGroupBlurXPipeline = makePipeline(@"spektrafilm_diffusion_downsample_group_blur_x");
      diffusionDownsampleGroupBlurYPipeline = makePipeline(@"spektrafilm_diffusion_downsample_group_blur_y");
      diffusionDownsampleGroupUpsampleAccumulatePipeline = makePipeline(@"spektrafilm_diffusion_downsample_group_upsample_accumulate");
      diffusionDownsampleBlurXHalfPipeline = makePipeline(@"spektrafilm_diffusion_downsample_blur_x_half");
      diffusionDownsampleBlurYHalfPipeline = makePipeline(@"spektrafilm_diffusion_downsample_blur_y_half");
      diffusionDownsampleUpsampleAccumulateHalfPipeline = makePipeline(@"spektrafilm_diffusion_downsample_upsample_accumulate_half");
      diffusionDownsampleGroupBlurXHalfPipeline = makePipeline(@"spektrafilm_diffusion_downsample_group_blur_x_half");
      diffusionDownsampleGroupBlurYHalfPipeline = makePipeline(@"spektrafilm_diffusion_downsample_group_blur_y_half");
      diffusionDownsampleGroupUpsampleAccumulateHalfPipeline = makePipeline(@"spektrafilm_diffusion_downsample_group_upsample_accumulate_half");
      diffusionResolvePipeline = makePipeline(@"spektrafilm_diffusion_resolve");
      developFromLogRawPipeline = makePipeline(@"spektrafilm_develop_from_log_raw");
      dirCorrectionFromDensityPipeline = makePipeline(@"spektrafilm_dir_correction_from_density");
      copyBufferPipeline = makePipeline(@"spektrafilm_copy_buffer");
      halfToFloatBufferPipeline = makePipeline(@"spektrafilm_half_to_float_buffer");
      floatToHalfBufferPipeline = makePipeline(@"spektrafilm_float_to_half_buffer");
      stridedFloatToFloatBufferPipeline = makePipeline(@"spektrafilm_strided_float_to_float_buffer");
      stridedHalfToFloatBufferPipeline = makePipeline(@"spektrafilm_strided_half_to_float_buffer");
      floatToStridedFloatBufferPipeline = makePipeline(@"spektrafilm_float_to_strided_float_buffer");
      floatToStridedHalfBufferPipeline = makePipeline(@"spektrafilm_float_to_strided_half_buffer");
      dirBaselinePipeline = makePipeline(@"spektrafilm_dir_baseline");
      dirBlurXPipeline = makePipeline(@"spektrafilm_dir_blur_x");
      dirBlurYPipeline = makePipeline(@"spektrafilm_dir_blur_y");
      dirTailBlurXPipeline = makePipeline(@"spektrafilm_dir_tail_blur_x");
      dirTailBlurYAccumulatePipeline = makePipeline(@"spektrafilm_dir_tail_blur_y_accumulate");
      dirTailMpsAccumulatePipeline = makePipeline(@"spektrafilm_dir_tail_mps_accumulate");
      dirRedevelopPipeline = makePipeline(@"spektrafilm_dir_redevelop");
      previewGrainFromDensityPipeline = makePipeline(@"spektrafilm_preview_grain_from_density");
      productionGrainLayersFromDensityPipeline = makePipeline(@"spektrafilm_production_grain_layers_from_density");
      grainLayerBlurXPipeline = makePipeline(@"spektrafilm_grain_layer_blur_x");
      grainLayerBlurYPipeline = makePipeline(@"spektrafilm_grain_layer_blur_y");
      grainMicroSourcePipeline = makePipeline(@"spektrafilm_grain_microstructure_source");
      grainMicroBlurXPipeline = makePipeline(@"spektrafilm_grain_micro_blur_x");
      grainMicroBlurYPipeline = makePipeline(@"spektrafilm_grain_micro_blur_y");
      grainResolveDensityPipeline = makePipeline(@"spektrafilm_grain_resolve_density");
      grainDensityBlurXPipeline = makePipeline(@"spektrafilm_grain_density_blur_x");
      grainDensityBlurYPipeline = makePipeline(@"spektrafilm_grain_density_blur_y");
      grainApplyControlsPipeline = makePipeline(@"spektrafilm_grain_apply_controls");
      grainSynthesisLayersFromDensityPipeline = makePipeline(@"spektrafilm_grain_synthesis_layers_from_density");
      grainSynthesisLayersFromDensityFixedRadiusPipeline = makePipeline(@"spektrafilm_grain_synthesis_layers_from_density_fixed_radius");
      grainSynthesisTargetDensityPipeline = makePipeline(@"spektrafilm_grain_synthesis_target_density");
      grainSynthesisTargetDensityNonLayeredPipeline = makePipeline(@"spektrafilm_grain_synthesis_target_density_nonlayered");
      grainSynthesisTargetDensityHalfPipeline = makePipeline(@"spektrafilm_grain_synthesis_target_density_half");
      grainSynthesisTargetDensityNonLayeredHalfPipeline = makePipeline(@"spektrafilm_grain_synthesis_target_density_nonlayered_half");
      grainSynthesisTargetDensityTexturePipeline = makePipeline(@"spektrafilm_grain_synthesis_target_density_r16_texture_array");
      grainSynthesisTargetDensityNonLayeredTexturePipeline = makePipeline(@"spektrafilm_grain_synthesis_target_density_nonlayered_r16_texture_array");
      grainSynthesisLayersFromTargetDensityPipeline = makePipeline(@"spektrafilm_grain_synthesis_layers_from_target_density");
      grainSynthesisLayersFromTargetDensityFixedRadiusPipeline = makePipeline(@"spektrafilm_grain_synthesis_layers_from_target_density_fixed_radius");
      grainSynthesisLayersFromTargetDensityNonLayeredPipeline = makePipeline(@"spektrafilm_grain_synthesis_layers_from_target_density_nonlayered");
      grainSynthesisLayersFromTargetDensityNonLayeredFixedRadiusPipeline = makePipeline(@"spektrafilm_grain_synthesis_layers_from_target_density_nonlayered_fixed_radius");
      grainSynthesisLayersFromTargetDensityHalfPipeline = makePipeline(@"spektrafilm_grain_synthesis_layers_from_target_density_half");
      grainSynthesisLayersFromTargetDensityHalfFixedRadiusPipeline = makePipeline(@"spektrafilm_grain_synthesis_layers_from_target_density_half_fixed_radius");
      grainSynthesisLayersFromTargetDensityNonLayeredHalfPipeline = makePipeline(@"spektrafilm_grain_synthesis_layers_from_target_density_nonlayered_half");
      grainSynthesisLayersFromTargetDensityNonLayeredHalfFixedRadiusPipeline = makePipeline(@"spektrafilm_grain_synthesis_layers_from_target_density_nonlayered_half_fixed_radius");
      grainSynthesisLayersFromTargetDensityTexturePipeline = makePipeline(@"spektrafilm_grain_synthesis_layers_from_target_density_r16_texture_array");
      grainSynthesisLayersFromTargetDensityTextureFixedRadiusPipeline = makePipeline(@"spektrafilm_grain_synthesis_layers_from_target_density_r16_texture_array_fixed_radius");
      grainSynthesisLayersFromTargetDensityNonLayeredTexturePipeline = makePipeline(@"spektrafilm_grain_synthesis_layers_from_target_density_nonlayered_r16_texture_array");
      grainSynthesisLayersFromTargetDensityNonLayeredTextureFixedRadiusPipeline = makePipeline(@"spektrafilm_grain_synthesis_layers_from_target_density_nonlayered_r16_texture_array_fixed_radius");
      grainSynthesisResolveDensityPipeline = makePipeline(@"spektrafilm_grain_synthesis_resolve_density");
      filteredEnlargerResponsePipeline = makePipeline(@"spektrafilm_filtered_enlarger_response");
      frameConstantsPipeline = makePipeline(@"spektrafilm_frame_constants");
      finalFromFilmDensityPipeline = makePipeline(@"spektrafilm_final_from_film_density");
      printRawFromFilmDensityPipeline = makePipeline(@"spektrafilm_print_raw_from_film_density");
      printRawFromNegativeLightPipeline = makePipeline(@"spektrafilm_print_raw_from_negative_light");
      printDensityFromPrintRawPipeline = makePipeline(@"spektrafilm_print_density_from_print_raw");
      profilePrintScanFromDensityPipeline = makePipeline(@"spektrafilm_profile_print_scan_from_density");
      profileFinalizeOutputPipeline = makePipeline(@"spektrafilm_profile_finalize_output");
      finalFromPrintRawPipeline = makePipeline(@"spektrafilm_final_from_print_raw");
      printGlareGeneratePipeline = makePipeline(@"spektrafilm_print_glare_generate");
      printGlareBlurXPipeline = makePipeline(@"spektrafilm_print_glare_blur_x");
      printGlareBlurYPipeline = makePipeline(@"spektrafilm_print_glare_blur_y");
      printGlareApplyPipeline = makePipeline(@"spektrafilm_print_glare_apply");
      scannerBlurXPipeline = makePipeline(@"spektrafilm_scanner_blur_x");
      scannerBlurYPipeline = makePipeline(@"spektrafilm_scanner_blur_y");
      unsharpBlurXPipeline = makePipeline(@"spektrafilm_unsharp_blur_x");
      unsharpBlurYPipeline = makePipeline(@"spektrafilm_unsharp_blur_y");
      bufferToTexturePipeline = makePipeline(@"spektrafilm_buffer_to_texture");
      textureToBufferPipeline = makePipeline(@"spektrafilm_texture_to_buffer");
      scannerBlurXTexturePipeline = makePipeline(@"spektrafilm_scanner_blur_x_texture");
      scannerBlurYTexturePipeline = makePipeline(@"spektrafilm_scanner_blur_y_texture");
      unsharpBlurXTexturePipeline = makePipeline(@"spektrafilm_unsharp_blur_x_texture");
      unsharpBlurYTexturePipeline = makePipeline(@"spektrafilm_unsharp_blur_y_texture");
      scannerFinalizePipeline = makePipeline(@"spektrafilm_scanner_finalize");
      scannerFinalizeTexturePipeline = makePipeline(@"spektrafilm_scanner_finalize_texture");
      if (!enlargerResamplePipeline ||
          !grainPipeline || !halationRawExposurePipeline || !halationBoostMaxPipeline ||
          !halationBoostReduceMaxPipeline || !halationBoostApplyPipeline || !halationScatterCoreBlurXPipeline ||
          !halationScatterCoreBlurYPipeline || !halationScatterTailBlurXPipeline || !halationScatterTailBlurYPipeline ||
          !halationScatterTailGroupBlurXPipeline || !halationScatterTailGroupBlurYPipeline ||
          !halationScatterResolvePipeline || !halationClearPipeline || !halationBounceBlurXPipeline ||
          !halationBounceBlurYAccumulatePipeline || !halationResolveLogRawPipeline || !halationResolveDensityPipeline ||
          !rawToLogRawPipeline || !developFromRawPipeline ||
          !diffusionComponentBlurXPipeline || !diffusionComponentBlurYAccumulatePipeline ||
          !diffusionGroupBlurXPipeline || !diffusionGroupBlurYAccumulatePipeline ||
          !diffusionDownsamplePipeline || !diffusionDownsampleBlurXPipeline || !diffusionDownsampleBlurYPipeline ||
          !diffusionDownsampleUpsampleAccumulatePipeline || !diffusionDownsampleGroupBlurXPipeline ||
          !diffusionDownsampleGroupBlurYPipeline || !diffusionDownsampleGroupUpsampleAccumulatePipeline ||
          !diffusionDownsampleBlurXHalfPipeline || !diffusionDownsampleBlurYHalfPipeline ||
          !diffusionDownsampleUpsampleAccumulateHalfPipeline || !diffusionDownsampleGroupBlurXHalfPipeline ||
          !diffusionDownsampleGroupBlurYHalfPipeline || !diffusionDownsampleGroupUpsampleAccumulateHalfPipeline ||
          !diffusionResolvePipeline ||
          !developFromLogRawPipeline ||
          !dirCorrectionFromDensityPipeline || !copyBufferPipeline ||
          !halfToFloatBufferPipeline || !floatToHalfBufferPipeline ||
          !stridedFloatToFloatBufferPipeline || !stridedHalfToFloatBufferPipeline ||
          !floatToStridedFloatBufferPipeline || !floatToStridedHalfBufferPipeline ||
          !dirBaselinePipeline || !dirBlurXPipeline || !dirBlurYPipeline ||
          !dirTailBlurXPipeline || !dirTailBlurYAccumulatePipeline || !dirTailMpsAccumulatePipeline ||
          !dirRedevelopPipeline ||
          !previewGrainFromDensityPipeline || !productionGrainLayersFromDensityPipeline ||
          !grainLayerBlurXPipeline || !grainLayerBlurYPipeline ||
          !grainMicroSourcePipeline || !grainMicroBlurXPipeline || !grainMicroBlurYPipeline || !grainResolveDensityPipeline ||
          !grainDensityBlurXPipeline || !grainDensityBlurYPipeline || !grainApplyControlsPipeline ||
          !grainSynthesisLayersFromDensityPipeline || !grainSynthesisLayersFromDensityFixedRadiusPipeline ||
          !grainSynthesisTargetDensityPipeline || !grainSynthesisTargetDensityNonLayeredPipeline ||
          !grainSynthesisTargetDensityHalfPipeline || !grainSynthesisTargetDensityNonLayeredHalfPipeline ||
          !grainSynthesisTargetDensityTexturePipeline || !grainSynthesisTargetDensityNonLayeredTexturePipeline ||
          !grainSynthesisLayersFromTargetDensityPipeline || !grainSynthesisLayersFromTargetDensityFixedRadiusPipeline ||
          !grainSynthesisLayersFromTargetDensityNonLayeredPipeline ||
          !grainSynthesisLayersFromTargetDensityNonLayeredFixedRadiusPipeline ||
          !grainSynthesisLayersFromTargetDensityHalfPipeline ||
          !grainSynthesisLayersFromTargetDensityHalfFixedRadiusPipeline ||
          !grainSynthesisLayersFromTargetDensityNonLayeredHalfPipeline ||
          !grainSynthesisLayersFromTargetDensityNonLayeredHalfFixedRadiusPipeline ||
          !grainSynthesisLayersFromTargetDensityTexturePipeline ||
          !grainSynthesisLayersFromTargetDensityTextureFixedRadiusPipeline ||
          !grainSynthesisLayersFromTargetDensityNonLayeredTexturePipeline ||
          !grainSynthesisLayersFromTargetDensityNonLayeredTextureFixedRadiusPipeline ||
          !grainSynthesisResolveDensityPipeline ||
          !filteredEnlargerResponsePipeline || !frameConstantsPipeline || !finalFromFilmDensityPipeline ||
          !printRawFromFilmDensityPipeline || !printRawFromNegativeLightPipeline || !printDensityFromPrintRawPipeline ||
          !profilePrintScanFromDensityPipeline || !profileFinalizeOutputPipeline || !finalFromPrintRawPipeline ||
          !printGlareGeneratePipeline || !printGlareBlurXPipeline || !printGlareBlurYPipeline ||
          !printGlareApplyPipeline ||
          !scannerBlurXPipeline || !scannerBlurYPipeline || !unsharpBlurXPipeline || !unsharpBlurYPipeline ||
          !bufferToTexturePipeline || !textureToBufferPipeline || !scannerBlurXTexturePipeline ||
          !scannerBlurYTexturePipeline || !unsharpBlurXTexturePipeline || !unsharpBlurYTexturePipeline ||
          !scannerFinalizePipeline || !scannerFinalizeTexturePipeline) {
        return;
      }

      const HanatosSpectraLutInfo &hanatos = hanatosSpectraLutInfo();
      NSURL *hanatosURL = findBundleResourceURL(@"SpektraHanatos2025Spectra", @"f32");
      if (!hanatosURL) {
        lastError = "Unable to locate SpektraHanatos2025Spectra.f32 in bundle resources.";
        return;
      }
      NSData *hanatosData = [NSData dataWithContentsOfURL:hanatosURL options:NSDataReadingMappedIfSafe error:&error];
      const NSUInteger expectedBytes = static_cast<NSUInteger>(hanatos.elementCount) * sizeof(float);
      if (!hanatosData || [hanatosData length] != expectedBytes) {
        lastError = error ? [[error localizedDescription] UTF8String] : "Unable to load Hanatos spectra LUT resource.";
        return;
      }
      const float *hanatosFloats = static_cast<const float *>([hanatosData bytes]);
      hanatosSpectraData.assign(hanatosFloats, hanatosFloats + hanatos.elementCount);
      spectralInfo.hanatosWidth = hanatos.width;
      spectralInfo.hanatosHeight = hanatos.height;
      spectralInfo.hanatosWavelengthCount = hanatos.wavelengthCount;

      NSURL *outputGamutURL = findBundleResourceURL(@"SpektraOutputGamutCompression", @"f32");
      if (!outputGamutURL) {
        lastError = "Unable to locate SpektraOutputGamutCompression.f32 in bundle resources.";
        return;
      }
      NSData *outputGamutData = [NSData dataWithContentsOfURL:outputGamutURL options:NSDataReadingMappedIfSafe error:&error];
      const NSUInteger expectedOutputGamutBytes =
        static_cast<NSUInteger>(kSpektraOutputGamutCompressionElementCount) * sizeof(float);
      if (!outputGamutData || [outputGamutData length] != expectedOutputGamutBytes) {
        lastError = error ? [[error localizedDescription] UTF8String] : "Unable to load output gamut compression resource.";
        return;
      }
      const float *outputGamutFloats = static_cast<const float *>([outputGamutData bytes]);
      outputGamutCompressionData.assign(
        outputGamutFloats,
        outputGamutFloats + kSpektraOutputGamutCompressionElementCount
      );
    }
  }
};

MetalRenderer::MetalRenderer() : impl_(std::make_unique<Impl>()) {}

MetalRenderer::~MetalRenderer() = default;

bool MetalRenderer::isAvailable() const {
  return impl_ && impl_->device && impl_->commandQueue && impl_->enlargerResamplePipeline && impl_->grainPipeline &&
    impl_->halationRawExposurePipeline && impl_->halationScatterCoreBlurXPipeline &&
    impl_->halationScatterCoreBlurYPipeline && impl_->halationScatterTailBlurXPipeline &&
    impl_->halationScatterTailBlurYPipeline && impl_->halationScatterTailGroupBlurXPipeline &&
    impl_->halationScatterTailGroupBlurYPipeline && impl_->halationScatterResolvePipeline &&
    impl_->halationClearPipeline && impl_->halationBounceBlurXPipeline &&
    impl_->halationBounceBlurYAccumulatePipeline && impl_->halationResolveLogRawPipeline &&
    impl_->halationResolveDensityPipeline && impl_->rawToLogRawPipeline && impl_->developFromRawPipeline &&
    impl_->diffusionComponentBlurXPipeline &&
    impl_->diffusionComponentBlurYAccumulatePipeline &&
    impl_->diffusionGroupBlurXPipeline && impl_->diffusionGroupBlurYAccumulatePipeline &&
    impl_->diffusionDownsamplePipeline && impl_->diffusionDownsampleBlurXPipeline &&
    impl_->diffusionDownsampleBlurYPipeline && impl_->diffusionDownsampleUpsampleAccumulatePipeline &&
    impl_->diffusionDownsampleGroupBlurXPipeline && impl_->diffusionDownsampleGroupBlurYPipeline &&
    impl_->diffusionDownsampleGroupUpsampleAccumulatePipeline &&
    impl_->diffusionDownsampleBlurXHalfPipeline && impl_->diffusionDownsampleBlurYHalfPipeline &&
    impl_->diffusionDownsampleUpsampleAccumulateHalfPipeline &&
    impl_->diffusionDownsampleGroupBlurXHalfPipeline && impl_->diffusionDownsampleGroupBlurYHalfPipeline &&
    impl_->diffusionDownsampleGroupUpsampleAccumulateHalfPipeline &&
    impl_->diffusionResolvePipeline &&
    impl_->developFromLogRawPipeline && impl_->dirCorrectionFromDensityPipeline && impl_->copyBufferPipeline &&
    impl_->halfToFloatBufferPipeline && impl_->floatToHalfBufferPipeline &&
    impl_->stridedFloatToFloatBufferPipeline && impl_->stridedHalfToFloatBufferPipeline &&
    impl_->floatToStridedFloatBufferPipeline && impl_->floatToStridedHalfBufferPipeline &&
    impl_->dirBaselinePipeline && impl_->dirBlurXPipeline && impl_->dirBlurYPipeline &&
    impl_->dirTailBlurXPipeline && impl_->dirTailBlurYAccumulatePipeline &&
    impl_->dirTailMpsAccumulatePipeline && impl_->dirRedevelopPipeline &&
    impl_->previewGrainFromDensityPipeline && impl_->productionGrainLayersFromDensityPipeline &&
    impl_->grainLayerBlurXPipeline && impl_->grainLayerBlurYPipeline &&
    impl_->grainMicroSourcePipeline && impl_->grainMicroBlurXPipeline && impl_->grainMicroBlurYPipeline &&
    impl_->grainResolveDensityPipeline && impl_->grainDensityBlurXPipeline && impl_->grainDensityBlurYPipeline &&
    impl_->grainApplyControlsPipeline &&
    impl_->grainSynthesisLayersFromDensityPipeline && impl_->grainSynthesisLayersFromDensityFixedRadiusPipeline &&
    impl_->grainSynthesisTargetDensityPipeline && impl_->grainSynthesisTargetDensityNonLayeredPipeline &&
    impl_->grainSynthesisTargetDensityHalfPipeline &&
    impl_->grainSynthesisTargetDensityNonLayeredHalfPipeline &&
    impl_->grainSynthesisTargetDensityTexturePipeline &&
    impl_->grainSynthesisTargetDensityNonLayeredTexturePipeline &&
    impl_->grainSynthesisLayersFromTargetDensityPipeline &&
    impl_->grainSynthesisLayersFromTargetDensityFixedRadiusPipeline &&
    impl_->grainSynthesisLayersFromTargetDensityNonLayeredPipeline &&
    impl_->grainSynthesisLayersFromTargetDensityNonLayeredFixedRadiusPipeline &&
    impl_->grainSynthesisLayersFromTargetDensityHalfPipeline &&
    impl_->grainSynthesisLayersFromTargetDensityHalfFixedRadiusPipeline &&
    impl_->grainSynthesisLayersFromTargetDensityNonLayeredHalfPipeline &&
    impl_->grainSynthesisLayersFromTargetDensityNonLayeredHalfFixedRadiusPipeline &&
    impl_->grainSynthesisLayersFromTargetDensityTexturePipeline &&
    impl_->grainSynthesisLayersFromTargetDensityTextureFixedRadiusPipeline &&
    impl_->grainSynthesisLayersFromTargetDensityNonLayeredTexturePipeline &&
    impl_->grainSynthesisLayersFromTargetDensityNonLayeredTextureFixedRadiusPipeline &&
    impl_->grainSynthesisResolveDensityPipeline &&
    impl_->filteredEnlargerResponsePipeline && impl_->frameConstantsPipeline &&
    impl_->finalFromFilmDensityPipeline && impl_->printRawFromFilmDensityPipeline && impl_->printRawFromNegativeLightPipeline &&
    impl_->printDensityFromPrintRawPipeline && impl_->profilePrintScanFromDensityPipeline &&
    impl_->profileFinalizeOutputPipeline && impl_->finalFromPrintRawPipeline &&
    impl_->scannerBlurXPipeline && impl_->scannerBlurYPipeline &&
    impl_->unsharpBlurXPipeline && impl_->unsharpBlurYPipeline &&
    impl_->bufferToTexturePipeline && impl_->textureToBufferPipeline &&
    impl_->scannerBlurXTexturePipeline && impl_->scannerBlurYTexturePipeline &&
    impl_->unsharpBlurXTexturePipeline && impl_->unsharpBlurYTexturePipeline &&
    impl_->scannerFinalizePipeline && impl_->scannerFinalizeTexturePipeline &&
    !impl_->hanatosSpectraData.empty();
}

const std::string &MetalRenderer::lastError() const {
  static const std::string empty;
  return impl_ ? impl_->lastError : empty;
}

const MetalRenderDiagnostics &MetalRenderer::lastDiagnostics() const {
  static const MetalRenderDiagnostics empty;
  return impl_ ? impl_->diagnostics : empty;
}

void MetalRenderer::releaseTransientResources() {
  if (!impl_) {
    return;
  }
  std::lock_guard<std::mutex> renderLock(impl_->renderMutex);
  @autoreleasepool {
    impl_->releaseTransientResources();
  }
}

bool MetalRenderer::startGpuTraceCapture(const std::string &path) {
  if (!isAvailable()) {
    return false;
  }
  if (path.empty()) {
    impl_->lastError = "GPU trace capture requires a non-empty output path.";
    return false;
  }
  if (@available(macOS 10.15, *)) {
    MTLCaptureManager *manager = [MTLCaptureManager sharedCaptureManager];
    if ([manager isCapturing]) {
      impl_->lastError = "A Metal GPU trace capture is already active.";
      return false;
    }
    if (![manager supportsDestination:MTLCaptureDestinationGPUTraceDocument]) {
      impl_->lastError = "This Metal runtime does not support writing GPU trace documents.";
      return false;
    }
    MTLCaptureDescriptor *descriptor = [MTLCaptureDescriptor new];
    descriptor.captureObject = impl_->commandQueue ? (id)impl_->commandQueue : (id)impl_->device;
    descriptor.destination = MTLCaptureDestinationGPUTraceDocument;
    NSString *capturePath = [NSString stringWithUTF8String:path.c_str()];
    descriptor.outputURL = [NSURL fileURLWithPath:capturePath];
    NSError *error = nil;
    if (![manager startCaptureWithDescriptor:descriptor error:&error]) {
      impl_->lastError = error ? [[error localizedDescription] UTF8String] : "Unable to start Metal GPU trace capture.";
      impl_->lastError += " Set MTL_CAPTURE_ENABLED=1 for command-line captures.";
      return false;
    }
    return true;
  }
  impl_->lastError = "Programmatic Metal GPU trace capture requires macOS 10.15 or newer.";
  return false;
}

void MetalRenderer::stopGpuTraceCapture() {
  if (!impl_) {
    return;
  }
  if (@available(macOS 10.15, *)) {
    MTLCaptureManager *manager = [MTLCaptureManager sharedCaptureManager];
    if ([manager isCapturing]) {
      [manager stopCapture];
    }
  }
}

std::unique_ptr<Renderer> createNativeRenderer() {
  return std::make_unique<MetalRenderer>();
}

bool MetalRenderer::render(
  const ImageView &source,
  const MutableImageView &destination,
  const RenderWindow &window,
  const RenderParams &params,
  double time
) {
  if (!isAvailable()) {
    return false;
  }
  if (!isSupportedRgba(source, destination)) {
    impl_->lastError = "Only RGBA 16-bit half and 32-bit float images are supported by the current Metal path.";
    return false;
  }

  const int32_t width = window.x2 - window.x1;
  const int32_t height = window.y2 - window.y1;
  if (width <= 0 || height <= 0) {
    return true;
  }

  std::lock_guard<std::mutex> renderLock(impl_->renderMutex);
  @autoreleasepool {
    const auto renderStart = PerfClock::now();
    impl_->diagnostics = {};
    impl_->diagnostics.renderSerialized = true;
    impl_->diagnostics.privateScratchEnabled = impl_->preferPrivateScratch;
    impl_->diagnostics.passGpuTimingEnabled = impl_->passGpuTimingEnabled;
    impl_->populateDeviceDiagnostics();
    impl_->diagnostics.diffusionGroupSize = impl_->diffusionGroupSize;
    impl_->diagnostics.threadgroupMode = impl_->threadgroupMode;
    impl_->diagnostics.blurBackend = impl_->blurBackend;
    impl_->diagnostics.blurDownsample = impl_->blurDownsample;
    impl_->diagnostics.intermediatePrecision = impl_->intermediatePrecision;
    impl_->diagnostics.diffusionClusterSigma = impl_->diffusionClusterSigma;
    impl_->diagnostics.densityCurveLookup = impl_->densityCurveLookup;
    impl_->diagnostics.spectralTransmittance = impl_->spectralTransmittance;
    impl_->diagnostics.finalCoreMode = "fused";
    impl_->diagnostics.halationGroupedTail = impl_->halationGroupedTail;
    impl_->diagnostics.scannerMps = impl_->scannerMps;
    impl_->diagnostics.grainBlurRecurrence = impl_->grainBlurRecurrence;
    impl_->diagnostics.dirTailBackend = impl_->dirTailBackend == DirTailBackend::Mps ? "mps" : "fused";
    impl_->diagnostics.scannerTextureIntermediates = false;
    impl_->diagnostics.passTimingMode = "off";
    const NSUInteger pixelBytes = sizeof(float) * 4;
    const NSUInteger bufferBytes = static_cast<NSUInteger>(width) * static_cast<NSUInteger>(height) * pixelBytes;
    ExternalMetalBufferContext *externalMetal = gExternalMetalBufferContext && gExternalMetalBufferContext->active
      ? gExternalMetalBufferContext
      : nullptr;
    if (externalMetal) {
      if (!externalMetal->commandQueue || !externalMetal->sourceBuffer || !externalMetal->destinationBuffer) {
        impl_->lastError = "OFX Metal render did not provide a command queue and source/destination buffers.";
        return false;
      }
      if ([externalMetal->commandQueue device] != impl_->device) {
        impl_->lastError = "OFX Metal command queue uses a different Metal device than the SpektraFilm renderer.";
        return false;
      }
      if (params.autoExposure) {
        impl_->lastError = "OFX Metal GPU buffers are not implemented for auto-exposure renders yet.";
        return false;
      }
    }
    impl_->beginScratchFrame();
    if (!impl_->prepareStaticResources(params)) {
      return false;
    }
    const StaticProfileResources &resources = impl_->staticResources;
    const ProfileCurveSet *filmCurves = resources.filmCurves;
    float effectiveHalationStrengthR = params.halationStrengthR;
    float effectiveHalationStrengthG = params.halationStrengthG;
    float effectiveHalationStrengthB = params.halationStrengthB;
    if (filmCurves && filmCurves->halationStrength && isDefaultHalationStrength(params)) {
      effectiveHalationStrengthR = filmCurves->halationStrength[0];
      effectiveHalationStrengthG = filmCurves->halationStrength[1];
      effectiveHalationStrengthB = filmCurves->halationStrength[2];
    }
    const NSUInteger densityCurveBytes = static_cast<NSUInteger>(filmCurves->exposureCount) * 3u * sizeof(float);
    const bool densityOutput = params.renderOutput == RenderOutputMode::FilmDensityCmy;
    const bool densityWithGrainOutput = params.renderOutput == RenderOutputMode::FilmDensityCmyWithGrain;
    const bool filmLogRawOutput = params.renderOutput == RenderOutputMode::FilmLogRaw;
    const bool printLogRawOutput = params.renderOutput == RenderOutputMode::PrintLogRaw;
    const bool printDensityOutput = params.renderOutput == RenderOutputMode::PrintDensityCmy;
    const bool printStageOutput = printLogRawOutput || printDensityOutput;
    const bool finalOutput = params.renderOutput == RenderOutputMode::FinalPreview;
    const bool rcmOutput = finalOutput && params.outputRole == OutputRole::Rcm;
    const bool finalPrintSimulation =
      finalOutput && params.process == ProcessMode::PrintSimulation;
    const bool finalScanNegative =
      finalOutput && params.process == ProcessMode::ScanNegative;
    const bool finalProcessNegative =
      finalOutput && params.process == ProcessMode::ProcessNegative;
    const bool printLikeFinalPath = finalPrintSimulation || finalProcessNegative;
    const bool printSimulationPath = finalPrintSimulation || printStageOutput;
    const bool finalPostProcessPath = finalPrintSimulation || finalScanNegative || finalProcessNegative;
    const bool cameraDiffusionRequested =
      params.cameraDiffusionEnabled &&
      params.cameraDiffusionStrength > 0.0f &&
      params.cameraDiffusionSpatialScale > 0.0f;
    const bool printDiffusionRequested =
      params.printDiffusionEnabled &&
      params.printDiffusionStrength > 0.0f &&
      params.printDiffusionSpatialScale > 0.0f &&
      (printSimulationPath || finalProcessNegative);
    const bool needsFilmDensityPath = densityOutput || densityWithGrainOutput || printStageOutput || finalPrintSimulation || finalScanNegative;
    const bool needsHalationLogRawPath = true;
    const bool halationScatterPath =
      params.halationEnabled &&
      needsHalationLogRawPath &&
      params.scatterAmount > 0.0f &&
      params.scatterScale > 0.0f;
    const bool halationBouncePath =
      params.halationEnabled &&
      needsHalationLogRawPath &&
      params.halationAmount > 0.0f &&
      params.halationScale > 0.0f &&
      (effectiveHalationStrengthR > 0.0f || effectiveHalationStrengthG > 0.0f || effectiveHalationStrengthB > 0.0f);
    const bool halationPath = halationScatterPath || halationBouncePath;
    const bool halationBoostPath =
      params.halationEnabled &&
      params.halationBoostEv > 0.0f &&
      needsFilmDensityPath;
    const bool dirPath = params.dirCouplersAmount > 0.0f && needsFilmDensityPath;
    const bool dirBlurPath = dirPath && params.dirCouplersDiffusionUm > 0.0f;
    const bool dirTailPath =
      dirPath &&
      dirBlurPath &&
      params.dirCouplersDiffusionTailUm > 0.0f &&
      params.dirCouplersDiffusionTailWeight > 0.0f;
    const bool dirTailMpsPath = dirTailPath && impl_->dirTailBackend == DirTailBackend::Mps;
    const bool productionGrainPath =
      params.grainEnabled &&
      params.grainModel == GrainModel::Production &&
      (densityWithGrainOutput || printStageOutput || finalPrintSimulation || finalScanNegative);
    const bool grainSynthesisPath =
      params.grainEnabled &&
      params.grainModel == GrainModel::GrainSynthesis &&
      (densityWithGrainOutput || printStageOutput || finalPrintSimulation || finalScanNegative);
    const bool grainControlsPath =
      (productionGrainPath || grainSynthesisPath) &&
      (std::abs(params.grainAmount - 1.0f) > 1.0e-6f || std::abs(params.grainSaturation - 1.0f) > 1.0e-6f);
    const NSUInteger grainLayerBytes = static_cast<NSUInteger>(width) * static_cast<NSUInteger>(height) * 9u * sizeof(float);
    const NSUInteger dirCorrectionBufferBBytes = dirTailPath && !dirTailMpsPath ? bufferBytes * 3u : bufferBytes;
    const float pixelSizeUm = filmFormatMm(params.filmFormat) * 1000.0f /
      static_cast<float>(std::max(width, height)) / enlargerScale(params);
    const bool grainLayerBlurPath =
      (productionGrainPath || grainSynthesisPath) &&
      params.grainSublayersEnabled &&
      params.grainBlurDyeCloudsUm > 0.0f;
    const float grainMicroBlurSigmaPx = std::max(params.grainMicroStructureScale, 0.0f) /
      std::max(pixelSizeUm, 1.0e-6f);
    const bool grainMicroBlurPath =
      (productionGrainPath || grainSynthesisPath) &&
      params.grainSublayersEnabled &&
      grainMicroBlurSigmaPx > 0.4f;
    const float grainFinalBlurSigmaPx = effectiveGrainFinalBlurUm(params) /
      std::max(pixelSizeUm, 1.0e-6f);
    const bool grainFinalBlurPath =
      (productionGrainPath || grainSynthesisPath) &&
      (grainFinalBlurSigmaPx > 0.0f && (params.grainSublayersEnabled || grainFinalBlurSigmaPx > 0.4f));
    KernelDiffusionInfo cameraDiffusionInfo{};
    KernelDiffusionInfo printDiffusionInfo{};
    const std::vector<KernelDiffusionComponent> cameraDiffusionComponents = cameraDiffusionRequested
      ? makeDiffusionComponents(
          {params.cameraDiffusionFamily, params.cameraDiffusionStrength, params.cameraDiffusionSpatialScale,
           params.cameraDiffusionHaloWarmth, params.cameraDiffusionCoreIntensity, params.cameraDiffusionCoreSize,
           params.cameraDiffusionHaloIntensity, params.cameraDiffusionHaloSize, params.cameraDiffusionBloomIntensity,
          params.cameraDiffusionBloomSize},
          pixelSizeUm,
          cameraDiffusionInfo,
          impl_->diffusionClusterSigmaRatio
        )
      : std::vector<KernelDiffusionComponent>{};
    const std::vector<KernelDiffusionComponent> printDiffusionComponents = printDiffusionRequested
      ? makeDiffusionComponents(
          {params.printDiffusionFamily, params.printDiffusionStrength, params.printDiffusionSpatialScale,
           params.printDiffusionHaloWarmth, params.printDiffusionCoreIntensity, params.printDiffusionCoreSize,
           params.printDiffusionHaloIntensity, params.printDiffusionHaloSize, params.printDiffusionBloomIntensity,
          params.printDiffusionBloomSize},
          pixelSizeUm,
          printDiffusionInfo,
          impl_->diffusionClusterSigmaRatio
        )
      : std::vector<KernelDiffusionComponent>{};
    const bool cameraDiffusionPath = cameraDiffusionRequested && cameraDiffusionInfo.componentCount > 0u && !cameraDiffusionComponents.empty();
    const bool printDiffusionPath = printDiffusionRequested && printDiffusionInfo.componentCount > 0u && !printDiffusionComponents.empty();
    const bool sourceTransformPath = !finalProcessNegative && enlargerTransformActive(params);
    const bool preExposurePath =
      halationBoostPath || cameraDiffusionPath || halationPath || (printDiffusionPath && !finalProcessNegative) || finalPrintSimulation || finalScanNegative ||
      densityOutput || densityWithGrainOutput || filmLogRawOutput || printStageOutput;
    const bool directDirBaselinePath = dirPath && !halationBoostPath && !cameraDiffusionPath && !halationPath && !filmLogRawOutput;
    const bool preExposureBranchPath = preExposurePath && !directDirBaselinePath;
    impl_->diagnostics.halationPath = halationPath;
    impl_->diagnostics.cameraDiffusionPath = cameraDiffusionPath;
    impl_->diagnostics.printDiffusionPath = printDiffusionPath;
    impl_->diagnostics.dirPath = dirPath;
    impl_->diagnostics.productionGrainPath = productionGrainPath;
    impl_->diagnostics.grainSynthesisPath = grainSynthesisPath;
    impl_->diagnostics.finalPostProcessPath = finalPostProcessPath;
    const bool previewGrainFromDensityPath =
      (dirPath || preExposurePath) &&
      params.grainEnabled &&
      params.grainModel == GrainModel::Preview &&
      (densityWithGrainOutput || printStageOutput || finalPrintSimulation || finalScanNegative);
    const KernelDirInfo dirInfo = makeDirInfo(*filmCurves, params);
    const std::vector<float> dirCorrectedDensityCurves = dirPath
      ? makeDirCorrectedDensityCurves(*filmCurves, dirInfo)
      : std::vector<float>{};
    id<MTLBuffer> curveInfoBuffer = resources.curveInfoBuffer;
    id<MTLBuffer> logExposureBuffer = resources.logExposureBuffer;
    id<MTLBuffer> densityCurvesBuffer = resources.densityCurvesBuffer;
    id<MTLBuffer> spectralInfoBuffer = resources.spectralInfoBuffer;
    id<MTLBuffer> wavelengthsBuffer = resources.wavelengthsBuffer;
    id<MTLBuffer> logSensitivityBuffer = resources.logSensitivityBuffer;
    id<MTLBuffer> bandpassHanatosBuffer = resources.bandpassHanatosBuffer;
    id<MTLBuffer> hanatosRawResponseBuffer = resources.hanatosRawResponseBuffer;
    id<MTLBuffer> paperHanatosResponseBuffer = resources.paperHanatosResponseBuffer;
    id<MTLBuffer> preflashPaperHanatosResponseBuffer = resources.preflashPaperHanatosResponseBuffer;
    id<MTLBuffer> mallettBasisIlluminantBuffer = resources.mallettBasisIlluminantBuffer;
    id<MTLBuffer> inputToReferenceXyzBuffer = resources.inputToReferenceXyzBuffer;
    id<MTLBuffer> inputToSrgbBuffer = resources.inputToSrgbBuffer;
    id<MTLBuffer> colorInfoBuffer = resources.colorInfoBuffer;
    id<MTLBuffer> colorDecodeLutBuffer = resources.colorDecodeLutBuffer;
    id<MTLBuffer> colorTransferKindBuffer = resources.colorTransferKindBuffer;
    id<MTLBuffer> paperCurveInfoBuffer = resources.paperCurveInfoBuffer;
    id<MTLBuffer> paperLogExposureBuffer = resources.paperLogExposureBuffer;
    id<MTLBuffer> paperDensityCurvesBuffer = resources.paperDensityCurvesBuffer;
    id<MTLBuffer> filmChannelDensityBuffer = resources.filmChannelDensityBuffer;
    id<MTLBuffer> filmBaseDensityBuffer = resources.filmBaseDensityBuffer;
    id<MTLBuffer> filmSpectralDensityBuffer = resources.filmSpectralDensityBuffer;
    id<MTLBuffer> paperLogSensitivityBuffer = resources.paperLogSensitivityBuffer;
    id<MTLBuffer> thKg3IlluminantBuffer = resources.thKg3IlluminantBuffer;
    id<MTLBuffer> customEnlargerFiltersBuffer = resources.customEnlargerFiltersBuffer;
    id<MTLBuffer> neutralPrintFiltersBuffer = resources.neutralPrintFiltersBuffer;
    id<MTLBuffer> academyPrinterDensityDataBuffer = resources.academyPrinterDensityDataBuffer;
    id<MTLBuffer> paperScanDensityDataBuffer = resources.paperScanDensityDataBuffer;
    id<MTLBuffer> paperSpectralDensityBuffer = resources.paperSpectralDensityBuffer;
    id<MTLBuffer> scanIlluminantsAndCmfsBuffer = resources.scanIlluminantsAndCmfsBuffer;
    id<MTLBuffer> scanProductsBuffer = resources.scanProductsBuffer;
    id<MTLBuffer> scanToOutputRgbDataBuffer = resources.scanToOutputRgbDataBuffer;
    id<MTLBuffer> colorEncodeLutBuffer = resources.colorEncodeLutBuffer;

    id<MTLBuffer> srcBuffer = nil;
    id<MTLBuffer> dstBuffer = nil;
    id<MTLBuffer> sourceHalfBuffer = nil;
    id<MTLBuffer> destinationHalfBuffer = nil;
    bool sourceWrappedDirectly = false;
    bool destinationWrappedDirectly = false;
    bool sourceHalfWrappedDirectly = false;
    bool destinationHalfWrappedDirectly = false;
    if (externalMetal) {
      if (externalMetal->sourceCompactFloat) {
        srcBuffer = externalMetal->sourceBuffer;
        sourceWrappedDirectly = true;
      } else if (externalMetal->sourceCompactHalf) {
        sourceHalfBuffer = externalMetal->sourceBuffer;
        sourceHalfWrappedDirectly = true;
      }
    } else if (const void *directSource = contiguousFloatWindowPointer(source, window, width, height)) {
      srcBuffer = [impl_->device newBufferWithBytesNoCopy:const_cast<void *>(directSource)
                                                   length:bufferBytes
                                                  options:MTLResourceStorageModeShared
                                              deallocator:nil];
      sourceWrappedDirectly = srcBuffer != nil;
    }
    if (!srcBuffer && !params.autoExposure) {
      if (const void *directHalfSource = contiguousHalfWindowPointer(source, window, width, height)) {
        const NSUInteger halfBufferBytes = static_cast<NSUInteger>(width) * static_cast<NSUInteger>(height) * 4u * sizeof(uint16_t);
        sourceHalfBuffer = [impl_->device newBufferWithBytesNoCopy:const_cast<void *>(directHalfSource)
                                                            length:halfBufferBytes
                                                           options:MTLResourceStorageModeShared
                                                       deallocator:nil];
        sourceHalfWrappedDirectly = sourceHalfBuffer != nil;
      }
    }
    if (!srcBuffer) {
      srcBuffer = (externalMetal || sourceHalfWrappedDirectly)
        ? impl_->gpuScratchBuffer(bufferBytes, "source float staging")
        : impl_->sharedScratchBuffer(bufferBytes, "source staging");
    }
    if (externalMetal) {
      if (externalMetal->destinationCompactFloat) {
        dstBuffer = externalMetal->destinationBuffer;
        destinationWrappedDirectly = true;
      } else if (externalMetal->destinationCompactHalf) {
        destinationHalfBuffer = externalMetal->destinationBuffer;
        destinationHalfWrappedDirectly = true;
      }
    } else if (void *directDestination = contiguousFloatWindowPointer(destination, window, width, height)) {
      dstBuffer = [impl_->device newBufferWithBytesNoCopy:directDestination
                                                   length:bufferBytes
                                                  options:MTLResourceStorageModeShared
                                              deallocator:nil];
      destinationWrappedDirectly = dstBuffer != nil;
    }
    if (!dstBuffer) {
      if (void *directHalfDestination = contiguousHalfWindowPointer(destination, window, width, height)) {
        const NSUInteger halfBufferBytes = static_cast<NSUInteger>(width) * static_cast<NSUInteger>(height) * 4u * sizeof(uint16_t);
        destinationHalfBuffer = [impl_->device newBufferWithBytesNoCopy:directHalfDestination
                                                                 length:halfBufferBytes
                                                                options:MTLResourceStorageModeShared
                                                            deallocator:nil];
        destinationHalfWrappedDirectly = destinationHalfBuffer != nil;
      }
    }
    impl_->diagnostics.sourceNoCopy = sourceWrappedDirectly || sourceHalfWrappedDirectly;
    impl_->diagnostics.destinationNoCopy = destinationWrappedDirectly || destinationHalfWrappedDirectly;
    if (!dstBuffer) {
      dstBuffer = (externalMetal || destinationHalfWrappedDirectly)
        ? impl_->gpuScratchBuffer(bufferBytes, "destination float staging")
        : impl_->sharedScratchBuffer(bufferBytes, "destination staging");
    }
    id<MTLBuffer> paramBuffer = impl_->sharedScratchBuffer(sizeof(KernelParams), "kernel params");
    id<MTLBuffer> enlargedSourceBuffer = sourceTransformPath ? impl_->gpuScratchBuffer(bufferBytes, "enlarger source") : nil;

    const bool printGlarePath =
      printLikeFinalPath && !rcmOutput && params.scannerEnabled && params.glarePercent > 0.0f;
    const bool scannerNeedsBlur =
      finalPostProcessPath && !rcmOutput && params.scannerEnabled && params.scannerMtf50LpMm > 0.0f;
    const bool scannerNeedsUnsharp =
      finalPostProcessPath && !rcmOutput && params.scannerEnabled &&
      params.scannerUnsharpRadiusUm > 0.0f && params.scannerUnsharpAmount > 0.0f;
    const bool scannerMpsPath = (impl_->scannerMps || impl_->blurBackend == "mps" ||
      (impl_->blurBackend == "auto" && impl_->useScannerTextures)) && (scannerNeedsBlur || scannerNeedsUnsharp);
    const bool scannerTexturePath = (impl_->useScannerTextures || scannerMpsPath) && (scannerNeedsBlur || scannerNeedsUnsharp);
    const MTLPixelFormat blurTextureFormat = impl_->intermediatePrecision == "half-blur"
      ? MTLPixelFormatRGBA16Float
      : MTLPixelFormatRGBA32Float;
    const bool directFinalEncodePath = finalPostProcessPath && !printGlarePath && !scannerNeedsBlur && !scannerNeedsUnsharp;
    const bool stagedFinalCorePath =
      impl_->finalCoreMode == "staged" &&
      finalPrintSimulation &&
      !printDiffusionPath &&
      directFinalEncodePath;
    impl_->diagnostics.finalCoreMode = stagedFinalCorePath ? "staged" : "fused";
    impl_->diagnostics.scannerTextureIntermediates = scannerTexturePath;
    const bool needsFrameConstants = needsFilmDensityPath || printDiffusionPath || finalProcessNegative;
    const NSUInteger filteredEnlargerResponseBytes =
      static_cast<NSUInteger>(filmCurves->wavelengthCount) * 8u * sizeof(float);
    const NSUInteger diffusionTempBytes = bufferBytes * static_cast<NSUInteger>(std::max(impl_->diffusionGroupSize, 1u));
    const bool diffusionDownsamplePath = impl_->blurDownsample != "off" &&
      (anyDiffusionComponentDownsamples(cameraDiffusionComponents, impl_->blurDownsample) ||
       anyDiffusionComponentDownsamples(printDiffusionComponents, impl_->blurDownsample));
    const bool diffusionDownsampleHalfPath = diffusionDownsamplePath && impl_->intermediatePrecision == "half-blur";
    const NSUInteger diffusionDownsampleBufferBytes = static_cast<NSUInteger>((width + 1) / 2) *
      static_cast<NSUInteger>((height + 1) / 2) * pixelBytes;
    const NSUInteger diffusionDownsampleIntermediatePlaneBytes = diffusionDownsampleHalfPath
      ? static_cast<NSUInteger>((width + 1) / 2) * static_cast<NSUInteger>((height + 1) / 2) * 4u * sizeof(uint16_t)
      : diffusionDownsampleBufferBytes;
    const NSUInteger diffusionDownsampleGroupBytes =
      diffusionDownsampleIntermediatePlaneBytes * static_cast<NSUInteger>(std::max(impl_->diffusionGroupSize, 1u));
    constexpr uint32_t kHalationBoostMaxChunkPixels = 256u;
    const uint32_t halationBoostMaxChunkCount = halationBoostPath
      ? static_cast<uint32_t>((static_cast<uint64_t>(width) * static_cast<uint64_t>(height) +
          kHalationBoostMaxChunkPixels - 1u) / kHalationBoostMaxChunkPixels)
      : 0u;
    id<MTLBuffer> frameConstantsBuffer = needsFrameConstants ? impl_->gpuScratchBuffer(sizeof(float) * 24u, "frame constants") : nil;
    id<MTLBuffer> filteredEnlargerResponseBuffer = printSimulationPath
      ? impl_->gpuScratchBuffer(filteredEnlargerResponseBytes, "filtered enlarger response")
      : nil;
    id<MTLBuffer> scannerRgbBufferA = ((finalPostProcessPath && !directFinalEncodePath) || stagedFinalCorePath)
      ? impl_->gpuScratchBuffer(bufferBytes, "scanner rgb A")
      : nil;
    id<MTLBuffer> scannerRgbBufferB = (!scannerTexturePath && (scannerNeedsBlur || scannerNeedsUnsharp)) ? impl_->gpuScratchBuffer(bufferBytes, "scanner rgb B") : nil;
    id<MTLBuffer> scannerRgbBufferC = (!scannerTexturePath && scannerNeedsUnsharp) ? impl_->gpuScratchBuffer(bufferBytes, "scanner rgb C") : nil;
    id<MTLTexture> scannerTextureA = scannerTexturePath ? impl_->gpuScratchTexture(width, height, "scanner texture A", blurTextureFormat) : nil;
    id<MTLTexture> scannerTextureB = scannerTexturePath ? impl_->gpuScratchTexture(width, height, "scanner texture B", blurTextureFormat) : nil;
    id<MTLTexture> scannerTextureC = (scannerTexturePath && scannerNeedsUnsharp) ? impl_->gpuScratchTexture(width, height, "scanner texture C", blurTextureFormat) : nil;
    id<MTLBuffer> printGlareBufferA = printGlarePath ? impl_->gpuScratchBuffer(bufferBytes, "print glare A") : nil;
    id<MTLBuffer> printGlareBufferB = printGlarePath ? impl_->gpuScratchBuffer(bufferBytes, "print glare B") : nil;
    id<MTLBuffer> halationRawBufferA = preExposureBranchPath ? impl_->gpuScratchBuffer(bufferBytes, "pre-exposure raw A") : nil;
    id<MTLBuffer> halationRawBufferB = preExposureBranchPath ? impl_->gpuScratchBuffer(bufferBytes, "pre-exposure raw B") : nil;
    id<MTLBuffer> halationRawBufferC = preExposureBranchPath ? impl_->gpuScratchBuffer(cameraDiffusionPath ? diffusionTempBytes : bufferBytes, "pre-exposure raw C") : nil;
    id<MTLBuffer> halationRawBufferD = preExposureBranchPath ? impl_->gpuScratchBuffer(bufferBytes, "pre-exposure raw D") : nil;
    id<MTLBuffer> halationLogRawBuffer = preExposureBranchPath ? impl_->gpuScratchBuffer(bufferBytes, "pre-exposure log raw") : nil;
    id<MTLBuffer> halationDensityBufferA = preExposureBranchPath ? impl_->gpuScratchBuffer(bufferBytes, "pre-exposure density A") : nil;
    id<MTLBuffer> halationDensityBufferB = (preExposureBranchPath && previewGrainFromDensityPath) ? impl_->gpuScratchBuffer(bufferBytes, "pre-exposure density B") : nil;
    id<MTLBuffer> halationBoostMaxBuffer = halationBoostPath
      ? impl_->gpuScratchBuffer(static_cast<NSUInteger>(std::max(halationBoostMaxChunkCount, 4u)) * sizeof(float), "halation boost max")
      : nil;
    id<MTLBuffer> halationScatterTailGroupBuffer = (halationScatterPath && impl_->halationGroupedTail)
      ? impl_->gpuScratchBuffer(bufferBytes * 3u, "halation scatter grouped tail")
      : nil;
    id<MTLBuffer> cameraDiffusionInfoBuffer = cameraDiffusionPath ? impl_->sharedScratchBuffer(sizeof(KernelDiffusionInfo), "camera diffusion info") : nil;
    id<MTLBuffer> cameraDiffusionComponentsBuffer = cameraDiffusionPath && !cameraDiffusionComponents.empty()
      ? impl_->sharedScratchBuffer(cameraDiffusionComponents.size() * sizeof(KernelDiffusionComponent), "camera diffusion components")
      : nil;
    id<MTLBuffer> printDiffusionInfoBuffer = printDiffusionPath ? impl_->sharedScratchBuffer(sizeof(KernelDiffusionInfo), "print diffusion info") : nil;
    id<MTLBuffer> printDiffusionComponentsBuffer = printDiffusionPath && !printDiffusionComponents.empty()
      ? impl_->sharedScratchBuffer(printDiffusionComponents.size() * sizeof(KernelDiffusionComponent), "print diffusion components")
      : nil;
    id<MTLBuffer> diffusionDownsampleSourceBuffer = diffusionDownsamplePath
      ? impl_->gpuScratchBuffer(diffusionDownsampleBufferBytes, "diffusion downsample source")
      : nil;
    id<MTLBuffer> diffusionDownsampleTempBuffer = diffusionDownsamplePath
      ? impl_->gpuScratchBuffer(diffusionDownsampleGroupBytes, "diffusion downsample temp")
      : nil;
    id<MTLBuffer> diffusionDownsampleBlurBuffer = diffusionDownsamplePath
      ? impl_->gpuScratchBuffer(diffusionDownsampleGroupBytes, "diffusion downsample blur")
      : nil;
    id<MTLBuffer> printRawBufferA = (printDiffusionPath || printStageOutput || stagedFinalCorePath || finalProcessNegative)
      ? impl_->gpuScratchBuffer(bufferBytes, "print raw A")
      : nil;
    id<MTLBuffer> printRawBufferB = (printDiffusionPath || stagedFinalCorePath)
      ? impl_->gpuScratchBuffer(printDiffusionPath ? diffusionTempBytes : bufferBytes, "print raw B")
      : nil;
    id<MTLBuffer> printRawBufferC = printDiffusionPath ? impl_->gpuScratchBuffer(bufferBytes, "print raw C") : nil;
    id<MTLBuffer> dirInfoBuffer = dirPath ? impl_->sharedScratchBuffer(sizeof(KernelDirInfo), "DIR info") : nil;
    id<MTLBuffer> dirCorrectedDensityCurvesBuffer = dirPath ? impl_->sharedScratchBuffer(densityCurveBytes, "DIR corrected curves") : nil;
    id<MTLBuffer> dirLogRawBuffer = dirPath ? impl_->gpuScratchBuffer(bufferBytes, "DIR log raw") : nil;
    id<MTLBuffer> dirDensityBufferA = dirPath ? impl_->gpuScratchBuffer(bufferBytes, "DIR density A") : nil;
    id<MTLBuffer> dirDensityBufferB = (dirPath && previewGrainFromDensityPath) ? impl_->gpuScratchBuffer(bufferBytes, "DIR density B") : nil;
    id<MTLBuffer> dirCorrectionBufferA = dirPath ? impl_->gpuScratchBuffer(bufferBytes, "DIR correction A") : nil;
    id<MTLBuffer> dirCorrectionBufferB = dirBlurPath ? impl_->gpuScratchBuffer(dirCorrectionBufferBBytes, "DIR correction B") : nil;
    id<MTLBuffer> dirCorrectionBufferC = dirTailPath ? impl_->gpuScratchBuffer(bufferBytes, "DIR correction C") : nil;
    id<MTLTexture> dirTailSourceTexture = dirTailMpsPath ? impl_->gpuScratchTexture(width, height, "DIR tail MPS source", blurTextureFormat) : nil;
    id<MTLTexture> dirTailBlurTexture = dirTailMpsPath ? impl_->gpuScratchTexture(width, height, "DIR tail MPS blur", blurTextureFormat) : nil;
    const bool optimizedGrainSynthesisPath = grainSynthesisPath && !impl_->useLegacyGrainSynthesis;
    const bool halfGrainSynthesisTargetPath = optimizedGrainSynthesisPath &&
      impl_->grainSynthesisTargetStorageMode == GrainSynthesisTargetStorageMode::HalfBuffer;
    const bool textureGrainSynthesisTargetPath = optimizedGrainSynthesisPath &&
      impl_->grainSynthesisTargetStorageMode == GrainSynthesisTargetStorageMode::R16TextureArray;
    const bool floatGrainSynthesisTargetPath = optimizedGrainSynthesisPath &&
      !halfGrainSynthesisTargetPath &&
      !textureGrainSynthesisTargetPath;
    id<MTLBuffer> grainLayerBufferA = (productionGrainPath || grainSynthesisPath) ? impl_->gpuScratchBuffer(grainLayerBytes, "grain layer A") : nil;
    id<MTLBuffer> grainLayerBufferB = (grainLayerBlurPath || floatGrainSynthesisTargetPath)
      ? impl_->gpuScratchBuffer(grainLayerBytes, "grain layer B")
      : nil;
    id<MTLBuffer> grainMicroBufferA = (productionGrainPath || grainSynthesisPath) ? impl_->gpuScratchBuffer(bufferBytes, "grain micro A") : nil;
    id<MTLBuffer> grainMicroBufferB = grainMicroBlurPath ? impl_->gpuScratchBuffer(bufferBytes, "grain micro B") : nil;
    id<MTLBuffer> grainDensityBufferA = (productionGrainPath || grainSynthesisPath) ? impl_->gpuScratchBuffer(bufferBytes, "grain density A") : nil;
    id<MTLBuffer> grainDensityBufferB = ((productionGrainPath || grainSynthesisPath) && (grainFinalBlurPath || grainControlsPath))
      ? impl_->gpuScratchBuffer(bufferBytes, "grain density B")
      : nil;
    id<MTLBuffer> grainBaseDensityBuffer = grainControlsPath ? impl_->gpuScratchBuffer(bufferBytes, "grain base density") : nil;
    id<MTLBuffer> grainSynthesisTargetHalfBuffer = halfGrainSynthesisTargetPath
      ? impl_->gpuScratchBuffer(static_cast<NSUInteger>(width) * static_cast<NSUInteger>(height) *
          kGrainSynthesisComponentCount * sizeof(uint16_t), "grain synthesis target half")
      : nil;
    id<MTLTexture> grainSynthesisTargetTexture = textureGrainSynthesisTargetPath
      ? impl_->gpuScratchTextureArray(static_cast<NSUInteger>(width), static_cast<NSUInteger>(height),
          kGrainSynthesisComponentCount, "grain synthesis target R16 array")
      : nil;
    id<MTLBuffer> grainSynthesisComponentInfoBuffer = optimizedGrainSynthesisPath
      ? impl_->sharedScratchBuffer(sizeof(KernelGrainSynthesisComponentInfo) * kGrainSynthesisComponentCount, "grain synthesis component info")
      : nil;
    id<MTLBuffer> grainSynthesisSampleOffsetBuffer = optimizedGrainSynthesisPath
      ? impl_->sharedScratchBuffer(sizeof(KernelGrainSynthesisSampleOffset) * kGrainSynthesisComponentCount * kGrainSynthesisMaxSamples, "grain synthesis sample offsets")
      : nil;
    id<MTLBuffer> grainSynthesisRadiusLutBuffer = optimizedGrainSynthesisPath
      ? impl_->sharedScratchBuffer(sizeof(float) * kGrainSynthesisComponentCount * kGrainSynthesisMaxRadiusLutSize, "grain synthesis radius LUT")
      : nil;
    id<MTLBuffer> grainSynthesisCellOffsetBuffer = optimizedGrainSynthesisPath
      ? impl_->sharedScratchBuffer(sizeof(KernelGrainSynthesisCellOffset) * kGrainSynthesisComponentCount * kGrainSynthesisMaxCellOffsetsPerComponent, "grain synthesis cell offsets")
      : nil;
    if (!srcBuffer || !dstBuffer || !paramBuffer || (needsFrameConstants && !frameConstantsBuffer) ||
        (printSimulationPath && !filteredEnlargerResponseBuffer) ||
        (sourceTransformPath && !enlargedSourceBuffer)) {
      impl_->lastError = "Unable to allocate Metal staging buffers.";
      return false;
    }
    if (productionGrainPath && (!grainLayerBufferA || (grainLayerBlurPath && !grainLayerBufferB) ||
        !grainMicroBufferA || (grainMicroBlurPath && !grainMicroBufferB) ||
        !grainDensityBufferA || ((grainFinalBlurPath || grainControlsPath) && !grainDensityBufferB))) {
      impl_->lastError = "Unable to allocate production grain Metal buffers.";
      return false;
    }
    if (grainSynthesisPath && (!grainLayerBufferA || ((grainLayerBlurPath || floatGrainSynthesisTargetPath) && !grainLayerBufferB) ||
        !grainMicroBufferA || (grainMicroBlurPath && !grainMicroBufferB) ||
        !grainDensityBufferA || ((grainFinalBlurPath || grainControlsPath) && !grainDensityBufferB))) {
      impl_->lastError = "Unable to allocate grain synthesis Metal buffers.";
      return false;
    }
    if (grainControlsPath && !grainBaseDensityBuffer) {
      impl_->lastError = "Unable to allocate grain controls Metal buffers.";
      return false;
    }
    if (optimizedGrainSynthesisPath && (!grainSynthesisComponentInfoBuffer || !grainSynthesisSampleOffsetBuffer ||
        !grainSynthesisRadiusLutBuffer || !grainSynthesisCellOffsetBuffer ||
        (halfGrainSynthesisTargetPath && !grainSynthesisTargetHalfBuffer) ||
        (textureGrainSynthesisTargetPath && !grainSynthesisTargetTexture))) {
      impl_->lastError = "Unable to allocate optimized grain synthesis Metal buffers.";
      return false;
    }
    if (dirPath && (!dirInfoBuffer || !dirCorrectedDensityCurvesBuffer || !dirLogRawBuffer || !dirDensityBufferA ||
        !dirCorrectionBufferA || (dirBlurPath && !dirCorrectionBufferB) || (dirTailPath && !dirCorrectionBufferC) ||
        (dirTailMpsPath && (!dirTailSourceTexture || !dirTailBlurTexture)) ||
        (previewGrainFromDensityPath && !dirDensityBufferB))) {
      impl_->lastError = "Unable to allocate DIR coupler Metal buffers.";
      return false;
    }
    if (preExposureBranchPath && (!halationRawBufferA || !halationRawBufferB || !halationRawBufferC || !halationRawBufferD ||
        !halationLogRawBuffer || !halationDensityBufferA || (previewGrainFromDensityPath && !halationDensityBufferB))) {
      impl_->lastError = "Unable to allocate pre-development Metal buffers.";
      return false;
    }
    if (cameraDiffusionPath && (!cameraDiffusionInfoBuffer || !cameraDiffusionComponentsBuffer)) {
      impl_->lastError = "Unable to allocate camera diffusion Metal buffers.";
      return false;
    }
    if (halationBoostPath && !halationBoostMaxBuffer) {
      impl_->lastError = "Unable to allocate halation highlight boost Metal buffers.";
      return false;
    }
    if (halationScatterPath && impl_->halationGroupedTail && !halationScatterTailGroupBuffer) {
      impl_->lastError = "Unable to allocate grouped halation tail Metal buffers.";
      return false;
    }
    if (diffusionDownsamplePath && (!diffusionDownsampleSourceBuffer || !diffusionDownsampleTempBuffer ||
        !diffusionDownsampleBlurBuffer)) {
      impl_->lastError = "Unable to allocate downsampled diffusion Metal buffers.";
      return false;
    }
    if ((printDiffusionPath || printStageOutput || finalProcessNegative) && !printRawBufferA) {
      impl_->lastError = "Unable to allocate print stage Metal buffers.";
      return false;
    }
    if (stagedFinalCorePath && (!printRawBufferA || !printRawBufferB || !scannerRgbBufferA)) {
      impl_->lastError = "Unable to allocate staged final-core profiling buffers.";
      return false;
    }
    if (printDiffusionPath && (!printDiffusionInfoBuffer || !printDiffusionComponentsBuffer ||
        !printRawBufferB || !printRawBufferC)) {
      impl_->lastError = "Unable to allocate print diffusion Metal buffers.";
      return false;
    }
    if (finalPostProcessPath && !directFinalEncodePath && !scannerRgbBufferA) {
      impl_->lastError = "Unable to allocate scanner post-process Metal buffers.";
      return false;
    }
    if (printGlarePath && (!printGlareBufferA || !printGlareBufferB)) {
      impl_->lastError = "Unable to allocate print glare Metal buffers.";
      return false;
    }
    if (!scannerTexturePath && (scannerNeedsBlur || scannerNeedsUnsharp) && !scannerRgbBufferB) {
      impl_->lastError = "Unable to allocate scanner post-process Metal buffers.";
      return false;
    }
    if (scannerTexturePath && (!scannerTextureA || !scannerTextureB || (scannerNeedsUnsharp && !scannerTextureC))) {
      impl_->lastError = "Unable to allocate scanner post-process Metal textures.";
      return false;
    }
    if (!scannerTexturePath && scannerNeedsUnsharp && !scannerRgbBufferC) {
      impl_->lastError = "Unable to allocate scanner post-process Metal buffers.";
      return false;
    }

    if (!externalMetal && !sourceWrappedDirectly && !sourceHalfWrappedDirectly) {
      const auto sourceCopyStart = PerfClock::now();
      copySourceToFloatStaging(source, window, width, height, static_cast<float *>([srcBuffer contents]));
      impl_->diagnostics.sourceCopyMs += elapsedMilliseconds(sourceCopyStart, PerfClock::now());
      impl_->diagnostics.uploadBytes += bufferBytes;
    }

    KernelParams kernelParams = toKernelParams(params, time, width, height);
    kernelParams.densityCurveLookupMode = static_cast<uint32_t>(impl_->densityCurveLookupMode);
    kernelParams.spectralTransmittanceMode = static_cast<uint32_t>(impl_->spectralTransmittanceMode);
    applyProfileHalationDefaults(kernelParams, params, *filmCurves);
    const KernelGaussianBlurInfo dirCoreBlurInfo = makeGaussianBlurInfo(
      std::max(kernelParams.dirCouplersDiffusionUm, 0.0f) / std::max(kernelParams.filmPixelSizeUm, 1.0e-6f),
      96u
    );
    const std::array<KernelGaussianBlurInfo, 3> dirTailBlurInfos = makeDirTailBlurInfos(kernelParams);
    if (params.autoExposure) {
      kernelParams.autoExposureEv = measureAutoExposureEv(
        static_cast<const float *>([srcBuffer contents]),
        width,
        height,
        params,
        impl_->autoExposureLuminance
      );
    }
    std::memcpy([paramBuffer contents], &kernelParams, sizeof(kernelParams));
    impl_->diagnostics.uploadBytes += sizeof(kernelParams);
    if (optimizedGrainSynthesisPath) {
      std::array<KernelGrainSynthesisComponentInfo, kGrainSynthesisComponentCount> componentInfo{};
      std::array<KernelGrainSynthesisSampleOffset, kGrainSynthesisComponentCount * kGrainSynthesisMaxSamples> sampleOffsets{};
      std::vector<float> radiusLut;
      std::vector<KernelGrainSynthesisCellOffset> cellOffsets;
      buildGrainSynthesisTables(
        kernelParams,
        impl_->grainSynthesisSamplerMode,
        impl_->grainSynthesisRadiusLutSize,
        impl_->grainSynthesisCellMode,
        componentInfo,
        sampleOffsets,
        radiusLut,
        cellOffsets
      );
      std::memcpy([grainSynthesisComponentInfoBuffer contents], componentInfo.data(), componentInfo.size() * sizeof(componentInfo[0]));
      std::memcpy([grainSynthesisSampleOffsetBuffer contents], sampleOffsets.data(), sampleOffsets.size() * sizeof(sampleOffsets[0]));
      if (!radiusLut.empty()) {
        std::memcpy([grainSynthesisRadiusLutBuffer contents], radiusLut.data(), radiusLut.size() * sizeof(radiusLut[0]));
      }
      if (!cellOffsets.empty()) {
        std::memcpy([grainSynthesisCellOffsetBuffer contents], cellOffsets.data(), cellOffsets.size() * sizeof(cellOffsets[0]));
      }
      impl_->diagnostics.uploadBytes += componentInfo.size() * sizeof(componentInfo[0]) +
        sampleOffsets.size() * sizeof(sampleOffsets[0]) +
        radiusLut.size() * sizeof(radiusLut[0]) +
        cellOffsets.size() * sizeof(cellOffsets[0]);
    }
    if (dirPath) {
      std::memcpy([dirInfoBuffer contents], &dirInfo, sizeof(dirInfo));
      std::memcpy([dirCorrectedDensityCurvesBuffer contents], dirCorrectedDensityCurves.data(), densityCurveBytes);
      impl_->diagnostics.uploadBytes += sizeof(dirInfo) + densityCurveBytes;
    }
    if (cameraDiffusionPath) {
      std::memcpy([cameraDiffusionInfoBuffer contents], &cameraDiffusionInfo, sizeof(cameraDiffusionInfo));
      std::memcpy([cameraDiffusionComponentsBuffer contents], cameraDiffusionComponents.data(), cameraDiffusionComponents.size() * sizeof(KernelDiffusionComponent));
      impl_->diagnostics.uploadBytes += sizeof(cameraDiffusionInfo) +
        cameraDiffusionComponents.size() * sizeof(KernelDiffusionComponent);
    }
    if (printDiffusionPath) {
      std::memcpy([printDiffusionInfoBuffer contents], &printDiffusionInfo, sizeof(printDiffusionInfo));
      std::memcpy([printDiffusionComponentsBuffer contents], printDiffusionComponents.data(), printDiffusionComponents.size() * sizeof(KernelDiffusionComponent));
      impl_->diagnostics.uploadBytes += sizeof(printDiffusionInfo) +
        printDiffusionComponents.size() * sizeof(KernelDiffusionComponent);
    }

    const auto commandEncodingStart = PerfClock::now();
    id<MTLCommandBuffer> commandBuffer = nil;
    id<MTLComputeCommandEncoder> encoder = nil;
    constexpr NSUInteger kMaxCounterSamples = 2048u;
    id<MTLCounterSampleBuffer> passCounterBuffer = nil;
    const std::string requestedPassTiming = externalMetal ? std::string("off") : impl_->passTimingMode;
    const bool counterTimingRequested =
      requestedPassTiming == "auto" || requestedPassTiming == "counter";
    bool useSplitPassTiming = requestedPassTiming == "split";
    if (impl_->passGpuTimingEnabled && counterTimingRequested && impl_->supportsDispatchCounterSampling()) {
      if (@available(macOS 10.15, *)) {
        id<MTLCounterSet> counterSet = impl_->timestampCounterSet();
        if (counterSet) {
          MTLCounterSampleBufferDescriptor *descriptor = [MTLCounterSampleBufferDescriptor new];
          descriptor.counterSet = counterSet;
          descriptor.storageMode = MTLStorageModeShared;
          descriptor.sampleCount = kMaxCounterSamples;
          descriptor.label = @"SpektraFilm per-pass timestamps";
          NSError *counterError = nil;
          passCounterBuffer = [impl_->device newCounterSampleBufferWithDescriptor:descriptor error:&counterError];
          impl_->diagnostics.passGpuTimingAvailable = passCounterBuffer != nil;
          if (passCounterBuffer) {
            impl_->diagnostics.passTimingMode = "counter";
          }
        }
      }
    }
    if (!passCounterBuffer && requestedPassTiming == "auto") {
      useSplitPassTiming = true;
    }
    if (useSplitPassTiming) {
      impl_->diagnostics.passGpuTimingAvailable = true;
      impl_->diagnostics.passTimingMode = "split-diagnostic";
    } else if (impl_->passGpuTimingEnabled && !passCounterBuffer) {
      impl_->diagnostics.passTimingMode = "unavailable";
    }
    bool encodeFailed = false;
    auto beginComputeEncoder = [&]() -> bool {
      if (passCounterBuffer) {
        if (@available(macOS 10.15, *)) {
          MTLComputePassDescriptor *descriptor = [MTLComputePassDescriptor computePassDescriptor];
          MTLComputePassSampleBufferAttachmentDescriptor *attachment =
            [descriptor.sampleBufferAttachments objectAtIndexedSubscript:0];
          attachment.sampleBuffer = passCounterBuffer;
          attachment.startOfEncoderSampleIndex = MTLCounterDontSample;
          attachment.endOfEncoderSampleIndex = MTLCounterDontSample;
          encoder = [commandBuffer computeCommandEncoderWithDescriptor:descriptor];
        }
      } else {
        encoder = [commandBuffer computeCommandEncoder];
      }
      if (!encoder) {
        impl_->lastError = "Unable to create Metal command encoder.";
        return false;
      }
      encoder.label = @"SpektraFilm compute";
      return true;
    };
    auto beginCommandEncoder = [&]() -> bool {
      id<MTLCommandQueue> queue = externalMetal ? externalMetal->commandQueue : impl_->commandQueue;
      commandBuffer = [queue commandBuffer];
      if (!commandBuffer) {
        impl_->lastError = "Unable to create Metal command buffer.";
        return false;
      }
      commandBuffer.label = @"SpektraFilm render";
      return beginComputeEncoder();
    };
    if (!beginCommandEncoder()) {
      return false;
    }
    uint32_t dims[2] = {static_cast<uint32_t>(width), static_cast<uint32_t>(height)};
    const uint32_t grainBlurRecurrenceFlag = impl_->grainBlurRecurrence ? 1u : 0u;
    double splitCommandMs = 0.0;

    auto recordPass = [&](
      id<MTLComputePipelineState> pipeline,
      uint32_t passWidth,
      uint32_t passHeight,
      uint32_t depth,
      NSUInteger tgWidth,
      NSUInteger tgHeight,
      uint64_t estimatedBytes
    ) -> size_t {
      MetalPassDiagnostics pass{};
      pass.name = impl_->pipelineName(pipeline);
      pass.width = passWidth;
      pass.height = passHeight;
      pass.depth = depth;
      pass.threadgroupWidth = static_cast<uint32_t>(tgWidth);
      pass.threadgroupHeight = static_cast<uint32_t>(tgHeight);
      pass.threadExecutionWidth = pipeline ? static_cast<uint32_t>(pipeline.threadExecutionWidth) : 0u;
      pass.maxTotalThreadsPerThreadgroup = pipeline ? static_cast<uint32_t>(pipeline.maxTotalThreadsPerThreadgroup) : 0u;
      pass.estimatedBytes = estimatedBytes;
      impl_->diagnostics.passes.push_back(pass);
      return impl_->diagnostics.passes.size() - 1u;
    };

    auto samplePassCounter = [&](NSUInteger sampleIndex) {
      if (passCounterBuffer && sampleIndex < kMaxCounterSamples) {
        [encoder sampleCountersInBuffer:passCounterBuffer atSampleIndex:sampleIndex withBarrier:YES];
      }
    };

    auto finishSplitTimedPass = [&](size_t passIndex, PerfClock::time_point passStart) {
      if (!useSplitPassTiming || encodeFailed) {
        return;
      }
      [encoder endEncoding];
      [commandBuffer commit];
      [commandBuffer waitUntilCompleted];
      const double passMs = elapsedMilliseconds(passStart, PerfClock::now());
      const double passGpuMs = impl_->commandBufferGpuMilliseconds(commandBuffer);
      splitCommandMs += passMs;
      impl_->diagnostics.gpuCommandBufferMs += passGpuMs;
      if ([commandBuffer status] == MTLCommandBufferStatusError) {
        NSError *error = [commandBuffer error];
        impl_->lastError = error ? [[error localizedDescription] UTF8String] : "Metal command buffer failed.";
        encodeFailed = true;
        return;
      }
      if (passIndex < impl_->diagnostics.passes.size()) {
        impl_->diagnostics.passes[passIndex].gpuMs = passGpuMs > 0.0 ? passGpuMs : passMs;
        impl_->diagnostics.passes[passIndex].gpuTimeAvailable = true;
      }
      if (!beginCommandEncoder()) {
        encodeFailed = true;
      }
    };

    auto dispatch2D = [&](id<MTLComputePipelineState> pipeline, uint64_t estimatedBytes = 0u) {
      if (encodeFailed) {
        return;
      }
      NSUInteger tw = 32;
      NSUInteger th = 8;
      if (impl_->forcedThreadgroupWidth > 0u && impl_->forcedThreadgroupHeight > 0u) {
        tw = impl_->forcedThreadgroupWidth;
        th = impl_->forcedThreadgroupHeight;
      }
      const NSUInteger maxThreadsPerGroup = std::max<NSUInteger>(1, pipeline.maxTotalThreadsPerThreadgroup);
      tw = std::min<NSUInteger>(tw, maxThreadsPerGroup);
      if (tw * th > maxThreadsPerGroup) {
        th = std::max<NSUInteger>(1, maxThreadsPerGroup / tw);
      }
      MTLSize threadsPerGroup = MTLSizeMake(tw, th, 1);
      MTLSize threads = MTLSizeMake(static_cast<NSUInteger>(width), static_cast<NSUInteger>(height), 1);
      const size_t passIndex = recordPass(
        pipeline,
        static_cast<uint32_t>(width),
        static_cast<uint32_t>(height),
        1u,
        threadsPerGroup.width,
        threadsPerGroup.height,
        estimatedBytes ? estimatedBytes : static_cast<uint64_t>(bufferBytes) * 2u
      );
      const NSUInteger startSample = static_cast<NSUInteger>(passIndex) * 2u;
      samplePassCounter(startSample);
      const auto splitPassStart = useSplitPassTiming ? PerfClock::now() : PerfClock::time_point{};
      NSString *passLabel = [NSString stringWithUTF8String:impl_->diagnostics.passes[passIndex].name.c_str()];
      [encoder pushDebugGroup:passLabel];
      [encoder dispatchThreads:threads threadsPerThreadgroup:threadsPerGroup];
      [encoder popDebugGroup];
      samplePassCounter(startSample + 1u);
      impl_->diagnostics.passCount += 1u;
      finishSplitTimedPass(passIndex, splitPassStart);
    };
    auto dispatch2DSize = [&](id<MTLComputePipelineState> pipeline, uint32_t dispatchWidth, uint32_t dispatchHeight, uint64_t estimatedBytes = 0u) {
      if (encodeFailed) {
        return;
      }
      NSUInteger tw = 32;
      NSUInteger th = 8;
      if (impl_->forcedThreadgroupWidth > 0u && impl_->forcedThreadgroupHeight > 0u) {
        tw = impl_->forcedThreadgroupWidth;
        th = impl_->forcedThreadgroupHeight;
      }
      const NSUInteger maxThreadsPerGroup = std::max<NSUInteger>(1, pipeline.maxTotalThreadsPerThreadgroup);
      tw = std::min<NSUInteger>(tw, maxThreadsPerGroup);
      if (tw * th > maxThreadsPerGroup) {
        th = std::max<NSUInteger>(1, maxThreadsPerGroup / tw);
      }
      MTLSize threadsPerGroup = MTLSizeMake(tw, th, 1);
      MTLSize threads = MTLSizeMake(static_cast<NSUInteger>(dispatchWidth), static_cast<NSUInteger>(dispatchHeight), 1);
      const size_t passIndex = recordPass(
        pipeline,
        dispatchWidth,
        dispatchHeight,
        1u,
        threadsPerGroup.width,
        threadsPerGroup.height,
        estimatedBytes ? estimatedBytes : static_cast<uint64_t>(dispatchWidth) * static_cast<uint64_t>(dispatchHeight) * pixelBytes * 2u
      );
      const NSUInteger startSample = static_cast<NSUInteger>(passIndex) * 2u;
      samplePassCounter(startSample);
      const auto splitPassStart = useSplitPassTiming ? PerfClock::now() : PerfClock::time_point{};
      NSString *passLabel = [NSString stringWithUTF8String:impl_->diagnostics.passes[passIndex].name.c_str()];
      [encoder pushDebugGroup:passLabel];
      [encoder dispatchThreads:threads threadsPerThreadgroup:threadsPerGroup];
      [encoder popDebugGroup];
      samplePassCounter(startSample + 1u);
      impl_->diagnostics.passCount += 1u;
      finishSplitTimedPass(passIndex, splitPassStart);
    };
    auto dispatch3DDepth = [&](id<MTLComputePipelineState> pipeline, uint32_t depth, uint64_t estimatedBytes = 0u) {
      if (encodeFailed) {
        return;
      }
      NSUInteger tgWidth = impl_->forcedThreadgroupWidth > 0u ? impl_->forcedThreadgroupWidth : 8;
      NSUInteger tgHeight = impl_->forcedThreadgroupHeight > 0u ? impl_->forcedThreadgroupHeight : 8;
      if (tgWidth * tgHeight > pipeline.maxTotalThreadsPerThreadgroup) {
        tgHeight = std::max<NSUInteger>(1, pipeline.maxTotalThreadsPerThreadgroup / tgWidth);
      }
      MTLSize threadsPerGroup = MTLSizeMake(tgWidth, tgHeight, 1);
      MTLSize threads = MTLSizeMake(static_cast<NSUInteger>(width), static_cast<NSUInteger>(height), depth);
      const uint64_t defaultBytes = static_cast<uint64_t>(width) * static_cast<uint64_t>(height) * depth * sizeof(float) * 2u;
      const size_t passIndex = recordPass(
        pipeline,
        static_cast<uint32_t>(width),
        static_cast<uint32_t>(height),
        depth,
        threadsPerGroup.width,
        threadsPerGroup.height,
        estimatedBytes ? estimatedBytes : defaultBytes
      );
      const NSUInteger startSample = static_cast<NSUInteger>(passIndex) * 2u;
      samplePassCounter(startSample);
      const auto splitPassStart = useSplitPassTiming ? PerfClock::now() : PerfClock::time_point{};
      NSString *passLabel = [NSString stringWithUTF8String:impl_->diagnostics.passes[passIndex].name.c_str()];
      [encoder pushDebugGroup:passLabel];
      [encoder dispatchThreads:threads threadsPerThreadgroup:threadsPerGroup];
      [encoder popDebugGroup];
      samplePassCounter(startSample + 1u);
      impl_->diagnostics.passCount += 1u;
      finishSplitTimedPass(passIndex, splitPassStart);
    };
    auto dispatch3D = [&](id<MTLComputePipelineState> pipeline, uint64_t estimatedBytes = 0u) {
      dispatch3DDepth(pipeline, 9u, estimatedBytes ? estimatedBytes : static_cast<uint64_t>(grainLayerBytes) * 2u);
    };
    auto dispatch1D = [&](id<MTLComputePipelineState> pipeline, NSUInteger threadCount, uint64_t estimatedBytes = 0u) {
      if (encodeFailed) {
        return;
      }
      const NSUInteger tgWidth = std::min<NSUInteger>(std::max<NSUInteger>(pipeline.threadExecutionWidth, 1u), threadCount);
      MTLSize threadsPerGroup = MTLSizeMake(tgWidth, 1, 1);
      MTLSize threads = MTLSizeMake(threadCount, 1, 1);
      const size_t passIndex = recordPass(
        pipeline,
        static_cast<uint32_t>(threadCount),
        1u,
        1u,
        threadsPerGroup.width,
        threadsPerGroup.height,
        estimatedBytes
      );
      const NSUInteger startSample = static_cast<NSUInteger>(passIndex) * 2u;
      samplePassCounter(startSample);
      const auto splitPassStart = useSplitPassTiming ? PerfClock::now() : PerfClock::time_point{};
      NSString *passLabel = [NSString stringWithUTF8String:impl_->diagnostics.passes[passIndex].name.c_str()];
      [encoder pushDebugGroup:passLabel];
      [encoder dispatchThreads:threads threadsPerThreadgroup:threadsPerGroup];
      [encoder popDebugGroup];
      samplePassCounter(startSample + 1u);
      impl_->diagnostics.passCount += 1u;
      finishSplitTimedPass(passIndex, splitPassStart);
    };

    auto encodeMpsTextureBlur = [&](id<MTLTexture> sourceTexture, id<MTLTexture> destinationTexture, float sigma, const char *passName) {
      if (encodeFailed) {
        return;
      }
      MPSImageGaussianBlur *blur = impl_->cachedMpsGaussianBlur(sigma);
      if (!blur) {
        encodeFailed = true;
        return;
      }
      [encoder endEncoding];
      encoder = nil;
      const size_t passIndex = impl_->diagnostics.passes.size();
      MetalPassDiagnostics pass{};
      pass.name = passName;
      pass.width = static_cast<uint32_t>(width);
      pass.height = static_cast<uint32_t>(height);
      pass.depth = 1u;
      pass.threadgroupWidth = 0u;
      pass.threadgroupHeight = 0u;
      pass.estimatedBytes = static_cast<uint64_t>(bufferBytes) * 2u;
      impl_->diagnostics.passes.push_back(pass);
      const auto splitPassStart = useSplitPassTiming ? PerfClock::now() : PerfClock::time_point{};
      [blur encodeToCommandBuffer:commandBuffer sourceTexture:sourceTexture destinationTexture:destinationTexture];
      impl_->diagnostics.passCount += 1u;
      if (useSplitPassTiming) {
        [commandBuffer commit];
        [commandBuffer waitUntilCompleted];
        const double passMs = elapsedMilliseconds(splitPassStart, PerfClock::now());
        const double passGpuMs = impl_->commandBufferGpuMilliseconds(commandBuffer);
        splitCommandMs += passMs;
        impl_->diagnostics.gpuCommandBufferMs += passGpuMs;
        if ([commandBuffer status] == MTLCommandBufferStatusError) {
          NSError *error = [commandBuffer error];
          impl_->lastError = error ? [[error localizedDescription] UTF8String] : "Metal command buffer failed.";
          encodeFailed = true;
          return;
        }
        if (passIndex < impl_->diagnostics.passes.size()) {
          impl_->diagnostics.passes[passIndex].gpuMs = passGpuMs > 0.0 ? passGpuMs : passMs;
          impl_->diagnostics.passes[passIndex].gpuTimeAvailable = true;
        }
        if (!beginCommandEncoder()) {
          encodeFailed = true;
        }
      } else if (!beginComputeEncoder()) {
        encodeFailed = true;
      }
    };

    if (externalMetal && externalMetal->sourceStridedFloat) {
      [encoder setComputePipelineState:impl_->stridedFloatToFloatBufferPipeline];
      [encoder setBuffer:externalMetal->sourceBuffer offset:0 atIndex:0];
      [encoder setBuffer:srcBuffer offset:0 atIndex:1];
      [encoder setBytes:&externalMetal->sourceLayout length:sizeof(externalMetal->sourceLayout) atIndex:2];
      dispatch2D(
        impl_->stridedFloatToFloatBufferPipeline,
        static_cast<uint64_t>(width) * static_cast<uint64_t>(height) * (sizeof(float) * 8u)
      );
    } else if (externalMetal && externalMetal->sourceStridedHalf) {
      [encoder setComputePipelineState:impl_->stridedHalfToFloatBufferPipeline];
      [encoder setBuffer:externalMetal->sourceBuffer offset:0 atIndex:0];
      [encoder setBuffer:srcBuffer offset:0 atIndex:1];
      [encoder setBytes:&externalMetal->sourceLayout length:sizeof(externalMetal->sourceLayout) atIndex:2];
      dispatch2D(
        impl_->stridedHalfToFloatBufferPipeline,
        static_cast<uint64_t>(width) * static_cast<uint64_t>(height) * (sizeof(uint16_t) * 4u + sizeof(float) * 4u)
      );
    }

    if (sourceHalfWrappedDirectly) {
      [encoder setComputePipelineState:impl_->halfToFloatBufferPipeline];
      [encoder setBuffer:sourceHalfBuffer offset:0 atIndex:0];
      [encoder setBuffer:srcBuffer offset:0 atIndex:1];
      [encoder setBytes:dims length:sizeof(dims) atIndex:2];
      dispatch2D(
        impl_->halfToFloatBufferPipeline,
        static_cast<uint64_t>(width) * static_cast<uint64_t>(height) * (sizeof(uint16_t) * 4u + sizeof(float) * 4u)
      );
    }

    id<MTLBuffer> renderSourceBuffer = srcBuffer;
    if (sourceTransformPath) {
      [encoder setComputePipelineState:impl_->enlargerResamplePipeline];
      [encoder setBuffer:srcBuffer offset:0 atIndex:0];
      [encoder setBuffer:enlargedSourceBuffer offset:0 atIndex:1];
      [encoder setBuffer:paramBuffer offset:0 atIndex:2];
      [encoder setBytes:dims length:sizeof(dims) atIndex:3];
      dispatch2D(impl_->enlargerResamplePipeline);
      renderSourceBuffer = enlargedSourceBuffer;
    }

    if (filteredEnlargerResponseBuffer) {
      [encoder setComputePipelineState:impl_->filteredEnlargerResponsePipeline];
      [encoder setBuffer:filteredEnlargerResponseBuffer offset:0 atIndex:0];
      [encoder setBuffer:paramBuffer offset:0 atIndex:1];
      [encoder setBuffer:spectralInfoBuffer offset:0 atIndex:2];
      [encoder setBuffer:paperLogSensitivityBuffer offset:0 atIndex:3];
      [encoder setBuffer:thKg3IlluminantBuffer offset:0 atIndex:4];
      [encoder setBuffer:customEnlargerFiltersBuffer offset:0 atIndex:5];
      [encoder setBuffer:neutralPrintFiltersBuffer offset:0 atIndex:6];
      [encoder setBuffer:filmSpectralDensityBuffer offset:0 atIndex:7];
      dispatch1D(
        impl_->filteredEnlargerResponsePipeline,
        filmCurves->wavelengthCount,
        filteredEnlargerResponseBytes
      );
    }

    if (needsFrameConstants) {
      [encoder setComputePipelineState:impl_->frameConstantsPipeline];
      [encoder setBuffer:frameConstantsBuffer offset:0 atIndex:0];
      [encoder setBuffer:paramBuffer offset:0 atIndex:1];
      [encoder setBuffer:curveInfoBuffer offset:0 atIndex:2];
      [encoder setBuffer:logExposureBuffer offset:0 atIndex:3];
      [encoder setBuffer:densityCurvesBuffer offset:0 atIndex:4];
      [encoder setBuffer:spectralInfoBuffer offset:0 atIndex:5];
      [encoder setBuffer:colorInfoBuffer offset:0 atIndex:6];
      [encoder setBuffer:paperCurveInfoBuffer offset:0 atIndex:7];
      [encoder setBuffer:paperLogExposureBuffer offset:0 atIndex:8];
      [encoder setBuffer:paperDensityCurvesBuffer offset:0 atIndex:9];
      [encoder setBuffer:logSensitivityBuffer offset:0 atIndex:10];
      [encoder setBuffer:bandpassHanatosBuffer offset:0 atIndex:11];
      [encoder setBuffer:hanatosRawResponseBuffer offset:0 atIndex:12];
      [encoder setBuffer:mallettBasisIlluminantBuffer offset:0 atIndex:13];
      [encoder setBuffer:inputToReferenceXyzBuffer offset:0 atIndex:14];
      [encoder setBuffer:filmChannelDensityBuffer offset:0 atIndex:15];
      [encoder setBuffer:filmBaseDensityBuffer offset:0 atIndex:16];
      [encoder setBuffer:paperLogSensitivityBuffer offset:0 atIndex:17];
      [encoder setBuffer:thKg3IlluminantBuffer offset:0 atIndex:18];
      [encoder setBuffer:customEnlargerFiltersBuffer offset:0 atIndex:19];
      [encoder setBuffer:neutralPrintFiltersBuffer offset:0 atIndex:20];
      [encoder setBuffer:academyPrinterDensityDataBuffer offset:0 atIndex:21];
      [encoder setBuffer:paperScanDensityDataBuffer offset:0 atIndex:22];
      [encoder setBuffer:scanIlluminantsAndCmfsBuffer offset:0 atIndex:23];
      [encoder setBuffer:scanToOutputRgbDataBuffer offset:0 atIndex:24];
      dispatch1D(impl_->frameConstantsPipeline, 1u, sizeof(float) * 24u);
    }

    auto encodePrintGlare = [&](id<MTLBuffer> linearRgbBuffer) -> id<MTLBuffer> {
      if (!printGlarePath) {
        return linearRgbBuffer;
      }
      [encoder setComputePipelineState:impl_->printGlareGeneratePipeline];
      [encoder setBuffer:printGlareBufferA offset:0 atIndex:0];
      [encoder setBuffer:paramBuffer offset:0 atIndex:1];
      [encoder setBytes:dims length:sizeof(dims) atIndex:2];
      dispatch2D(impl_->printGlareGeneratePipeline);

      id<MTLBuffer> amountBuffer = printGlareBufferA;
      if (params.glareBlur > 0.0f) {
        [encoder setComputePipelineState:impl_->printGlareBlurXPipeline];
        [encoder setBuffer:printGlareBufferA offset:0 atIndex:0];
        [encoder setBuffer:printGlareBufferB offset:0 atIndex:1];
        [encoder setBuffer:paramBuffer offset:0 atIndex:2];
        [encoder setBytes:dims length:sizeof(dims) atIndex:3];
        [encoder setBytes:&grainBlurRecurrenceFlag length:sizeof(grainBlurRecurrenceFlag) atIndex:4];
        dispatch2D(impl_->printGlareBlurXPipeline);

        [encoder setComputePipelineState:impl_->printGlareBlurYPipeline];
        [encoder setBuffer:printGlareBufferB offset:0 atIndex:0];
        [encoder setBuffer:printGlareBufferA offset:0 atIndex:1];
        [encoder setBuffer:paramBuffer offset:0 atIndex:2];
        [encoder setBytes:dims length:sizeof(dims) atIndex:3];
        [encoder setBytes:&grainBlurRecurrenceFlag length:sizeof(grainBlurRecurrenceFlag) atIndex:4];
        dispatch2D(impl_->printGlareBlurYPipeline);
        amountBuffer = printGlareBufferA;
      }

      [encoder setComputePipelineState:impl_->printGlareApplyPipeline];
      [encoder setBuffer:linearRgbBuffer offset:0 atIndex:0];
      [encoder setBuffer:amountBuffer offset:0 atIndex:1];
      [encoder setBuffer:printGlareBufferB offset:0 atIndex:2];
      [encoder setBuffer:frameConstantsBuffer offset:0 atIndex:3];
      [encoder setBytes:dims length:sizeof(dims) atIndex:4];
      dispatch2D(impl_->printGlareApplyPipeline);
      return printGlareBufferB;
    };

    auto encodeScannerPostProcess = [&](id<MTLBuffer> linearRgbBuffer) {
      const uint32_t encodeOutput = impl_->linearFinalOutput ? 0u : 1u;
      linearRgbBuffer = encodePrintGlare(linearRgbBuffer);
      if (scannerTexturePath) {
        [encoder setComputePipelineState:impl_->bufferToTexturePipeline];
        [encoder setBuffer:linearRgbBuffer offset:0 atIndex:0];
        [encoder setBytes:dims length:sizeof(dims) atIndex:1];
        [encoder setTexture:scannerTextureA atIndex:0];
        dispatch2D(impl_->bufferToTexturePipeline);

        id<MTLTexture> currentTexture = scannerTextureA;
        if (params.scannerEnabled && params.scannerMtf50LpMm > 0.0f) {
          if (scannerMpsPath) {
            const float sigma = std::max(kernelParams.scannerBlurSigmaPx, 0.0f);
            if (sigma > 1.0e-4f) {
              encodeMpsTextureBlur(
                currentTexture,
                scannerTextureB,
                sigma,
                "spektrafilm_scanner_mps_blur"
              );
              if (encodeFailed) {
                return;
              }
              currentTexture = scannerTextureB;
            }
          } else {
            [encoder setComputePipelineState:impl_->scannerBlurXTexturePipeline];
            [encoder setTexture:currentTexture atIndex:0];
            [encoder setTexture:scannerTextureB atIndex:1];
            [encoder setBuffer:paramBuffer offset:0 atIndex:0];
            [encoder setBytes:dims length:sizeof(dims) atIndex:1];
            [encoder setBytes:&grainBlurRecurrenceFlag length:sizeof(grainBlurRecurrenceFlag) atIndex:2];
            dispatch2D(impl_->scannerBlurXTexturePipeline);

            [encoder setComputePipelineState:impl_->scannerBlurYTexturePipeline];
            [encoder setTexture:scannerTextureB atIndex:0];
            [encoder setTexture:scannerTextureA atIndex:1];
            [encoder setBuffer:paramBuffer offset:0 atIndex:0];
            [encoder setBytes:dims length:sizeof(dims) atIndex:1];
            [encoder setBytes:&grainBlurRecurrenceFlag length:sizeof(grainBlurRecurrenceFlag) atIndex:2];
            dispatch2D(impl_->scannerBlurYTexturePipeline);
            currentTexture = scannerTextureA;
          }
        }

        id<MTLTexture> unsharpBlurTexture = currentTexture;
        if (params.scannerEnabled && params.scannerUnsharpRadiusUm > 0.0f && params.scannerUnsharpAmount > 0.0f) {
          if (scannerMpsPath) {
            const float sigma = std::max(kernelParams.scannerUnsharpSigmaPx, 0.0f);
            if (sigma > 1.0e-4f) {
              encodeMpsTextureBlur(
                currentTexture,
                scannerTextureC,
                sigma,
                "spektrafilm_scanner_mps_unsharp_blur"
              );
              if (encodeFailed) {
                return;
              }
              unsharpBlurTexture = scannerTextureC;
            }
          } else {
            [encoder setComputePipelineState:impl_->unsharpBlurXTexturePipeline];
            [encoder setTexture:currentTexture atIndex:0];
            [encoder setTexture:scannerTextureB atIndex:1];
            [encoder setBuffer:paramBuffer offset:0 atIndex:0];
            [encoder setBytes:dims length:sizeof(dims) atIndex:1];
            [encoder setBytes:&grainBlurRecurrenceFlag length:sizeof(grainBlurRecurrenceFlag) atIndex:2];
            dispatch2D(impl_->unsharpBlurXTexturePipeline);

            [encoder setComputePipelineState:impl_->unsharpBlurYTexturePipeline];
            [encoder setTexture:scannerTextureB atIndex:0];
            [encoder setTexture:scannerTextureC atIndex:1];
            [encoder setBuffer:paramBuffer offset:0 atIndex:0];
            [encoder setBytes:dims length:sizeof(dims) atIndex:1];
            [encoder setBytes:&grainBlurRecurrenceFlag length:sizeof(grainBlurRecurrenceFlag) atIndex:2];
            dispatch2D(impl_->unsharpBlurYTexturePipeline);
            unsharpBlurTexture = scannerTextureC;
          }
        }

        [encoder setComputePipelineState:impl_->scannerFinalizeTexturePipeline];
        [encoder setTexture:currentTexture atIndex:0];
        [encoder setTexture:unsharpBlurTexture atIndex:1];
        [encoder setBuffer:dstBuffer offset:0 atIndex:0];
        [encoder setBuffer:paramBuffer offset:0 atIndex:1];
        [encoder setBytes:dims length:sizeof(dims) atIndex:2];
        [encoder setBuffer:colorInfoBuffer offset:0 atIndex:3];
        [encoder setBuffer:colorTransferKindBuffer offset:0 atIndex:4];
        [encoder setBuffer:colorEncodeLutBuffer offset:0 atIndex:5];
        [encoder setBytes:&encodeOutput length:sizeof(encodeOutput) atIndex:6];
        dispatch2D(impl_->scannerFinalizeTexturePipeline);
        return;
      }

      id<MTLBuffer> currentBuffer = linearRgbBuffer;
      if (params.scannerEnabled && params.scannerMtf50LpMm > 0.0f) {
        [encoder setComputePipelineState:impl_->scannerBlurXPipeline];
        [encoder setBuffer:currentBuffer offset:0 atIndex:0];
        [encoder setBuffer:scannerRgbBufferB offset:0 atIndex:1];
        [encoder setBuffer:paramBuffer offset:0 atIndex:2];
        [encoder setBytes:dims length:sizeof(dims) atIndex:3];
        [encoder setBytes:&grainBlurRecurrenceFlag length:sizeof(grainBlurRecurrenceFlag) atIndex:4];
        dispatch2D(impl_->scannerBlurXPipeline);

        [encoder setComputePipelineState:impl_->scannerBlurYPipeline];
        [encoder setBuffer:scannerRgbBufferB offset:0 atIndex:0];
        [encoder setBuffer:scannerRgbBufferA offset:0 atIndex:1];
        [encoder setBuffer:paramBuffer offset:0 atIndex:2];
        [encoder setBytes:dims length:sizeof(dims) atIndex:3];
        [encoder setBytes:&grainBlurRecurrenceFlag length:sizeof(grainBlurRecurrenceFlag) atIndex:4];
        dispatch2D(impl_->scannerBlurYPipeline);
        currentBuffer = scannerRgbBufferA;
      }

      id<MTLBuffer> unsharpBlurBuffer = currentBuffer;
      if (params.scannerEnabled && params.scannerUnsharpRadiusUm > 0.0f && params.scannerUnsharpAmount > 0.0f) {
        [encoder setComputePipelineState:impl_->unsharpBlurXPipeline];
        [encoder setBuffer:currentBuffer offset:0 atIndex:0];
        [encoder setBuffer:scannerRgbBufferB offset:0 atIndex:1];
        [encoder setBuffer:paramBuffer offset:0 atIndex:2];
        [encoder setBytes:dims length:sizeof(dims) atIndex:3];
        [encoder setBytes:&grainBlurRecurrenceFlag length:sizeof(grainBlurRecurrenceFlag) atIndex:4];
        dispatch2D(impl_->unsharpBlurXPipeline);

        [encoder setComputePipelineState:impl_->unsharpBlurYPipeline];
        [encoder setBuffer:scannerRgbBufferB offset:0 atIndex:0];
        [encoder setBuffer:scannerRgbBufferC offset:0 atIndex:1];
        [encoder setBuffer:paramBuffer offset:0 atIndex:2];
        [encoder setBytes:dims length:sizeof(dims) atIndex:3];
        [encoder setBytes:&grainBlurRecurrenceFlag length:sizeof(grainBlurRecurrenceFlag) atIndex:4];
        dispatch2D(impl_->unsharpBlurYPipeline);
        unsharpBlurBuffer = scannerRgbBufferC;
      }

      [encoder setComputePipelineState:impl_->scannerFinalizePipeline];
      [encoder setBuffer:currentBuffer offset:0 atIndex:0];
      [encoder setBuffer:unsharpBlurBuffer offset:0 atIndex:1];
      [encoder setBuffer:dstBuffer offset:0 atIndex:2];
      [encoder setBuffer:paramBuffer offset:0 atIndex:3];
      [encoder setBytes:dims length:sizeof(dims) atIndex:4];
      [encoder setBuffer:colorInfoBuffer offset:0 atIndex:5];
      [encoder setBuffer:colorTransferKindBuffer offset:0 atIndex:6];
      [encoder setBuffer:colorEncodeLutBuffer offset:0 atIndex:7];
      [encoder setBytes:&encodeOutput length:sizeof(encodeOutput) atIndex:8];
      dispatch2D(impl_->scannerFinalizePipeline);
    };

    auto encodeFinalFromFilmDensity = [&](id<MTLBuffer> filmDensityBuffer) {
      const uint32_t encodeOutput =
        !impl_->linearFinalOutput && (directFinalEncodePath || !finalPostProcessPath) ? 1u : 0u;
      [encoder setComputePipelineState:impl_->finalFromFilmDensityPipeline];
      [encoder setBuffer:filmDensityBuffer offset:0 atIndex:0];
      [encoder setBuffer:(directFinalEncodePath || !finalPostProcessPath ? dstBuffer : scannerRgbBufferA) offset:0 atIndex:1];
      [encoder setBuffer:paramBuffer offset:0 atIndex:2];
      [encoder setBytes:dims length:sizeof(dims) atIndex:3];
      [encoder setBuffer:curveInfoBuffer offset:0 atIndex:4];
      [encoder setBuffer:logExposureBuffer offset:0 atIndex:5];
      [encoder setBuffer:densityCurvesBuffer offset:0 atIndex:6];
      [encoder setBuffer:spectralInfoBuffer offset:0 atIndex:7];
      [encoder setBuffer:colorInfoBuffer offset:0 atIndex:8];
      [encoder setBuffer:colorTransferKindBuffer offset:0 atIndex:9];
      [encoder setBuffer:paperCurveInfoBuffer offset:0 atIndex:10];
      [encoder setBuffer:paperLogExposureBuffer offset:0 atIndex:11];
      [encoder setBuffer:paperDensityCurvesBuffer offset:0 atIndex:12];
      [encoder setBuffer:logSensitivityBuffer offset:0 atIndex:13];
      [encoder setBuffer:bandpassHanatosBuffer offset:0 atIndex:14];
      [encoder setBuffer:hanatosRawResponseBuffer offset:0 atIndex:15];
      [encoder setBuffer:mallettBasisIlluminantBuffer offset:0 atIndex:16];
      [encoder setBuffer:inputToReferenceXyzBuffer offset:0 atIndex:17];
      [encoder setBuffer:filmChannelDensityBuffer offset:0 atIndex:18];
      [encoder setBuffer:filmSpectralDensityBuffer offset:0 atIndex:19];
      [encoder setBuffer:(filteredEnlargerResponseBuffer ?: paperLogSensitivityBuffer) offset:0 atIndex:20];
      [encoder setBuffer:thKg3IlluminantBuffer offset:0 atIndex:21];
      [encoder setBuffer:customEnlargerFiltersBuffer offset:0 atIndex:22];
      [encoder setBuffer:neutralPrintFiltersBuffer offset:0 atIndex:23];
      [encoder setBuffer:academyPrinterDensityDataBuffer offset:0 atIndex:24];
      [encoder setBuffer:paperSpectralDensityBuffer offset:0 atIndex:25];
      [encoder setBuffer:scanProductsBuffer offset:0 atIndex:26];
      [encoder setBuffer:scanToOutputRgbDataBuffer offset:0 atIndex:27];
      [encoder setBuffer:colorEncodeLutBuffer offset:0 atIndex:28];
      [encoder setBuffer:frameConstantsBuffer offset:0 atIndex:29];
      [encoder setBytes:&encodeOutput length:sizeof(encodeOutput) atIndex:30];
      dispatch2D(impl_->finalFromFilmDensityPipeline);
      if (finalPostProcessPath && !directFinalEncodePath) {
        encodeScannerPostProcess(scannerRgbBufferA);
      }
    };

    auto encodeCopyBuffer = [&](id<MTLBuffer> sourceBuffer, id<MTLBuffer> destinationBuffer) {
      [encoder setComputePipelineState:impl_->copyBufferPipeline];
      [encoder setBuffer:sourceBuffer offset:0 atIndex:0];
      [encoder setBuffer:destinationBuffer offset:0 atIndex:1];
      [encoder setBytes:dims length:sizeof(dims) atIndex:2];
      dispatch2D(impl_->copyBufferPipeline);
    };

    auto encodeCopyBufferToDestination = [&](id<MTLBuffer> sourceBuffer) {
      encodeCopyBuffer(sourceBuffer, dstBuffer);
    };

    auto encodeApplyGrainControls = [&](id<MTLBuffer> grainedDensityBuffer) -> id<MTLBuffer> {
      if (!grainControlsPath) {
        return grainedDensityBuffer;
      }
      [encoder setComputePipelineState:impl_->grainApplyControlsPipeline];
      [encoder setBuffer:grainBaseDensityBuffer offset:0 atIndex:0];
      [encoder setBuffer:grainedDensityBuffer offset:0 atIndex:1];
      [encoder setBuffer:grainDensityBufferB offset:0 atIndex:2];
      [encoder setBuffer:paramBuffer offset:0 atIndex:3];
      [encoder setBytes:dims length:sizeof(dims) atIndex:4];
      dispatch2D(impl_->grainApplyControlsPipeline);
      return grainDensityBufferB;
    };

    auto encodeSaveGrainBaseDensity = [&](id<MTLBuffer> baseDensityBuffer) {
      if (grainControlsPath) {
        encodeCopyBuffer(baseDensityBuffer, grainBaseDensityBuffer);
      }
    };

    auto encodeBlurGrainDensity = [&](id<MTLBuffer> densityBuffer) -> id<MTLBuffer> {
      id<MTLBuffer> blurSourceBuffer = encodeApplyGrainControls(densityBuffer);
      if (!grainFinalBlurPath) {
        return blurSourceBuffer;
      }
      id<MTLBuffer> blurXBuffer = blurSourceBuffer == grainDensityBufferA ? grainDensityBufferB : grainDensityBufferA;
      id<MTLBuffer> blurYBuffer = blurXBuffer == grainDensityBufferA ? grainDensityBufferB : grainDensityBufferA;

      [encoder setComputePipelineState:impl_->grainDensityBlurXPipeline];
      [encoder setBuffer:blurSourceBuffer offset:0 atIndex:0];
      [encoder setBuffer:blurXBuffer offset:0 atIndex:1];
      [encoder setBuffer:paramBuffer offset:0 atIndex:2];
      [encoder setBytes:dims length:sizeof(dims) atIndex:3];
      [encoder setBytes:&grainBlurRecurrenceFlag length:sizeof(grainBlurRecurrenceFlag) atIndex:4];
      dispatch2D(impl_->grainDensityBlurXPipeline);

      [encoder setComputePipelineState:impl_->grainDensityBlurYPipeline];
      [encoder setBuffer:blurXBuffer offset:0 atIndex:0];
      [encoder setBuffer:blurYBuffer offset:0 atIndex:1];
      [encoder setBuffer:paramBuffer offset:0 atIndex:2];
      [encoder setBytes:dims length:sizeof(dims) atIndex:3];
      [encoder setBytes:&grainBlurRecurrenceFlag length:sizeof(grainBlurRecurrenceFlag) atIndex:4];
      dispatch2D(impl_->grainDensityBlurYPipeline);

      return blurYBuffer;
    };

    auto encodeGrainLayerBlur = [&]() {
      if (grainLayerBlurPath) {
        [encoder setComputePipelineState:impl_->grainLayerBlurXPipeline];
        [encoder setBuffer:grainLayerBufferA offset:0 atIndex:0];
        [encoder setBuffer:grainLayerBufferB offset:0 atIndex:1];
        [encoder setBuffer:paramBuffer offset:0 atIndex:2];
        [encoder setBytes:dims length:sizeof(dims) atIndex:3];
        [encoder setBuffer:curveInfoBuffer offset:0 atIndex:4];
        [encoder setBuffer:spectralInfoBuffer offset:0 atIndex:5];
        [encoder setBuffer:paperScanDensityDataBuffer offset:0 atIndex:6];
        [encoder setBytes:&grainBlurRecurrenceFlag length:sizeof(grainBlurRecurrenceFlag) atIndex:7];
        dispatch3D(impl_->grainLayerBlurXPipeline);

        [encoder setComputePipelineState:impl_->grainLayerBlurYPipeline];
        [encoder setBuffer:grainLayerBufferB offset:0 atIndex:0];
        [encoder setBuffer:grainLayerBufferA offset:0 atIndex:1];
        [encoder setBuffer:paramBuffer offset:0 atIndex:2];
        [encoder setBytes:dims length:sizeof(dims) atIndex:3];
        [encoder setBuffer:curveInfoBuffer offset:0 atIndex:4];
        [encoder setBuffer:spectralInfoBuffer offset:0 atIndex:5];
        [encoder setBuffer:paperScanDensityDataBuffer offset:0 atIndex:6];
        [encoder setBytes:&grainBlurRecurrenceFlag length:sizeof(grainBlurRecurrenceFlag) atIndex:7];
        dispatch3D(impl_->grainLayerBlurYPipeline);
      }
    };

    auto encodeGrainMicrostructure = [&]() {
      [encoder setComputePipelineState:impl_->grainMicroSourcePipeline];
      [encoder setBuffer:grainMicroBufferA offset:0 atIndex:0];
      [encoder setBuffer:paramBuffer offset:0 atIndex:1];
      [encoder setBytes:dims length:sizeof(dims) atIndex:2];
      dispatch2D(impl_->grainMicroSourcePipeline);
      if (grainMicroBlurPath) {
        [encoder setComputePipelineState:impl_->grainMicroBlurXPipeline];
        [encoder setBuffer:grainMicroBufferA offset:0 atIndex:0];
        [encoder setBuffer:grainMicroBufferB offset:0 atIndex:1];
        [encoder setBuffer:paramBuffer offset:0 atIndex:2];
        [encoder setBytes:dims length:sizeof(dims) atIndex:3];
        [encoder setBytes:&grainBlurRecurrenceFlag length:sizeof(grainBlurRecurrenceFlag) atIndex:4];
        dispatch2D(impl_->grainMicroBlurXPipeline);

        [encoder setComputePipelineState:impl_->grainMicroBlurYPipeline];
        [encoder setBuffer:grainMicroBufferB offset:0 atIndex:0];
        [encoder setBuffer:grainMicroBufferA offset:0 atIndex:1];
        [encoder setBuffer:paramBuffer offset:0 atIndex:2];
        [encoder setBytes:dims length:sizeof(dims) atIndex:3];
        [encoder setBytes:&grainBlurRecurrenceFlag length:sizeof(grainBlurRecurrenceFlag) atIndex:4];
        dispatch2D(impl_->grainMicroBlurYPipeline);
      }
    };

    auto encodeDirCorrectionBlur = [&](id<MTLBuffer> correctionBuffer) -> id<MTLBuffer> {
      if (!dirBlurPath) {
        return correctionBuffer;
      }
      id<MTLBuffer> finalCorrectionBuffer = dirTailPath ? dirCorrectionBufferC : dirCorrectionBufferA;

      [encoder setComputePipelineState:impl_->dirBlurXPipeline];
      [encoder setBuffer:correctionBuffer offset:0 atIndex:0];
      [encoder setBuffer:dirCorrectionBufferB offset:0 atIndex:1];
      [encoder setBytes:&dirCoreBlurInfo length:sizeof(dirCoreBlurInfo) atIndex:2];
      [encoder setBytes:dims length:sizeof(dims) atIndex:3];
      dispatch2D(impl_->dirBlurXPipeline);

      [encoder setComputePipelineState:impl_->dirBlurYPipeline];
      [encoder setBuffer:dirCorrectionBufferB offset:0 atIndex:0];
      [encoder setBuffer:finalCorrectionBuffer offset:0 atIndex:1];
      [encoder setBytes:&dirCoreBlurInfo length:sizeof(dirCoreBlurInfo) atIndex:2];
      [encoder setBytes:dims length:sizeof(dims) atIndex:3];
      dispatch2D(impl_->dirBlurYPipeline);

      if (dirTailPath) {
        const float tailWeight = kernelParams.dirCouplersDiffusionTailWeight;
        if (dirTailMpsPath) {
          [encoder setComputePipelineState:impl_->bufferToTexturePipeline];
          [encoder setBuffer:correctionBuffer offset:0 atIndex:0];
          [encoder setBytes:dims length:sizeof(dims) atIndex:1];
          [encoder setTexture:dirTailSourceTexture atIndex:0];
          dispatch2D(impl_->bufferToTexturePipeline);

          auto encodeMpsTailBlur = [&](uint32_t component, float sigma) {
            if (encodeFailed) {
              return;
            }
            [encoder endEncoding];
            encoder = nil;
            const size_t passIndex = impl_->diagnostics.passes.size();
            MetalPassDiagnostics pass{};
            pass.name = "spektrafilm_dir_tail_mps_gaussian_blur";
            pass.width = static_cast<uint32_t>(width);
            pass.height = static_cast<uint32_t>(height);
            pass.depth = 1u;
            pass.threadgroupWidth = 0u;
            pass.threadgroupHeight = 0u;
            pass.estimatedBytes = static_cast<uint64_t>(bufferBytes) * 2u;
            impl_->diagnostics.passes.push_back(pass);
            const auto splitPassStart = useSplitPassTiming ? PerfClock::now() : PerfClock::time_point{};
            MPSImageGaussianBlur *blur = impl_->cachedMpsGaussianBlur(sigma);
            if (!blur) {
              impl_->lastError = "Unable to create MPS DIR tail Gaussian blur.";
              encodeFailed = true;
              return;
            }
            [blur encodeToCommandBuffer:commandBuffer sourceTexture:dirTailSourceTexture destinationTexture:dirTailBlurTexture];
            impl_->diagnostics.passCount += 1u;
            if (useSplitPassTiming) {
              [commandBuffer commit];
              [commandBuffer waitUntilCompleted];
              const double passMs = elapsedMilliseconds(splitPassStart, PerfClock::now());
              const double passGpuMs = impl_->commandBufferGpuMilliseconds(commandBuffer);
              splitCommandMs += passMs;
              impl_->diagnostics.gpuCommandBufferMs += passGpuMs;
              if ([commandBuffer status] == MTLCommandBufferStatusError) {
                NSError *error = [commandBuffer error];
                impl_->lastError = error ? [[error localizedDescription] UTF8String] : "Metal command buffer failed.";
                encodeFailed = true;
                return;
              }
              if (passIndex < impl_->diagnostics.passes.size()) {
                impl_->diagnostics.passes[passIndex].gpuMs = passGpuMs > 0.0 ? passGpuMs : passMs;
                impl_->diagnostics.passes[passIndex].gpuTimeAvailable = true;
              }
              if (!beginCommandEncoder()) {
                encodeFailed = true;
              }
            } else if (!beginComputeEncoder()) {
              encodeFailed = true;
            }
            (void)component;
          };

          for (uint32_t component = 0; component < 3u; ++component) {
            constexpr std::array<float, 3> kTailSigmaScale = {0.5360f, 1.5236f, 2.7684f};
            const float sigma = std::max(kernelParams.dirCouplersDiffusionTailUm, 0.0f) *
              kTailSigmaScale[component] / std::max(kernelParams.filmPixelSizeUm, 1.0e-6f);
            encodeMpsTailBlur(component, sigma);
            if (encodeFailed) {
              break;
            }
            [encoder setComputePipelineState:impl_->dirTailMpsAccumulatePipeline];
            [encoder setTexture:dirTailBlurTexture atIndex:0];
            [encoder setBuffer:finalCorrectionBuffer offset:0 atIndex:0];
            [encoder setBytes:&tailWeight length:sizeof(tailWeight) atIndex:1];
            [encoder setBytes:&component length:sizeof(component) atIndex:2];
            [encoder setBytes:dims length:sizeof(dims) atIndex:3];
            dispatch2D(impl_->dirTailMpsAccumulatePipeline);
          }
        } else {
          [encoder setComputePipelineState:impl_->dirTailBlurXPipeline];
          [encoder setBuffer:correctionBuffer offset:0 atIndex:0];
          [encoder setBuffer:dirCorrectionBufferB offset:0 atIndex:1];
          [encoder setBytes:dirTailBlurInfos.data()
                     length:dirTailBlurInfos.size() * sizeof(dirTailBlurInfos[0])
                    atIndex:2];
          [encoder setBytes:dims length:sizeof(dims) atIndex:3];
          dispatch2D(impl_->dirTailBlurXPipeline);

          [encoder setComputePipelineState:impl_->dirTailBlurYAccumulatePipeline];
          [encoder setBuffer:dirCorrectionBufferB offset:0 atIndex:0];
          [encoder setBuffer:finalCorrectionBuffer offset:0 atIndex:1];
          [encoder setBytes:dirTailBlurInfos.data()
                     length:dirTailBlurInfos.size() * sizeof(dirTailBlurInfos[0])
                    atIndex:2];
          [encoder setBytes:&tailWeight length:sizeof(tailWeight) atIndex:3];
          [encoder setBytes:dims length:sizeof(dims) atIndex:4];
          dispatch2D(impl_->dirTailBlurYAccumulatePipeline);
        }
      }

      return finalCorrectionBuffer;
    };

    auto encodeDevelopFromLogRaw = [&](id<MTLBuffer> logRawBuffer, id<MTLBuffer> densityBuffer) {
      [encoder setComputePipelineState:impl_->developFromLogRawPipeline];
      [encoder setBuffer:logRawBuffer offset:0 atIndex:0];
      [encoder setBuffer:densityBuffer offset:0 atIndex:1];
      [encoder setBuffer:paramBuffer offset:0 atIndex:2];
      [encoder setBytes:dims length:sizeof(dims) atIndex:3];
      [encoder setBuffer:curveInfoBuffer offset:0 atIndex:4];
      [encoder setBuffer:logExposureBuffer offset:0 atIndex:5];
      [encoder setBuffer:densityCurvesBuffer offset:0 atIndex:6];
      dispatch2D(impl_->developFromLogRawPipeline);
    };

    auto encodeDevelopFromRaw = [&](id<MTLBuffer> rawBuffer, id<MTLBuffer> densityBuffer) {
      [encoder setComputePipelineState:impl_->developFromRawPipeline];
      [encoder setBuffer:rawBuffer offset:0 atIndex:0];
      [encoder setBuffer:densityBuffer offset:0 atIndex:1];
      [encoder setBuffer:paramBuffer offset:0 atIndex:2];
      [encoder setBytes:dims length:sizeof(dims) atIndex:3];
      [encoder setBuffer:curveInfoBuffer offset:0 atIndex:4];
      [encoder setBuffer:logExposureBuffer offset:0 atIndex:5];
      [encoder setBuffer:densityCurvesBuffer offset:0 atIndex:6];
      dispatch2D(impl_->developFromRawPipeline);
    };

    auto encodeHalationResolveDensity = [&](id<MTLBuffer> rawBuffer, id<MTLBuffer> halationBuffer, id<MTLBuffer> densityBuffer) {
      [encoder setComputePipelineState:impl_->halationResolveDensityPipeline];
      [encoder setBuffer:rawBuffer offset:0 atIndex:0];
      [encoder setBuffer:halationBuffer offset:0 atIndex:1];
      [encoder setBuffer:densityBuffer offset:0 atIndex:2];
      [encoder setBuffer:paramBuffer offset:0 atIndex:3];
      [encoder setBytes:dims length:sizeof(dims) atIndex:4];
      [encoder setBuffer:curveInfoBuffer offset:0 atIndex:5];
      [encoder setBuffer:logExposureBuffer offset:0 atIndex:6];
      [encoder setBuffer:densityCurvesBuffer offset:0 atIndex:7];
      dispatch2D(impl_->halationResolveDensityPipeline);
    };

    auto encodeProductionGrainLayersFromDensity = [&](id<MTLBuffer> densityBuffer) {
      [encoder setComputePipelineState:impl_->productionGrainLayersFromDensityPipeline];
      [encoder setBuffer:densityBuffer offset:0 atIndex:0];
      [encoder setBuffer:grainLayerBufferA offset:0 atIndex:1];
      [encoder setBuffer:paramBuffer offset:0 atIndex:2];
      [encoder setBytes:dims length:sizeof(dims) atIndex:3];
      [encoder setBuffer:curveInfoBuffer offset:0 atIndex:4];
      [encoder setBuffer:densityCurvesBuffer offset:0 atIndex:5];
      [encoder setBuffer:spectralInfoBuffer offset:0 atIndex:6];
      [encoder setBuffer:paperScanDensityDataBuffer offset:0 atIndex:7];
      dispatch3D(impl_->productionGrainLayersFromDensityPipeline);
    };

    id<MTLBuffer> grainSynthesisDensitySource = nil;
    auto encodeGrainSynthesisLayersFromDensity = [&](id<MTLBuffer> densityBuffer) {
      grainSynthesisDensitySource = densityBuffer;
      id<MTLComputePipelineState> pipeline = params.grainSynthesisRadiusStdDevRatio <= 1.0e-6f
        ? impl_->grainSynthesisLayersFromDensityFixedRadiusPipeline
        : impl_->grainSynthesisLayersFromDensityPipeline;
      [encoder setComputePipelineState:pipeline];
      [encoder setBuffer:densityBuffer offset:0 atIndex:0];
      [encoder setBuffer:grainLayerBufferA offset:0 atIndex:1];
      [encoder setBuffer:paramBuffer offset:0 atIndex:2];
      [encoder setBytes:dims length:sizeof(dims) atIndex:3];
      [encoder setBuffer:curveInfoBuffer offset:0 atIndex:4];
      [encoder setBuffer:densityCurvesBuffer offset:0 atIndex:5];
      [encoder setBuffer:spectralInfoBuffer offset:0 atIndex:6];
      [encoder setBuffer:paperScanDensityDataBuffer offset:0 atIndex:7];
      dispatch3D(pipeline);
    };

    auto encodeOptimizedGrainSynthesisLayersFromDensity = [&](id<MTLBuffer> densityBuffer) {
      grainSynthesisDensitySource = densityBuffer;
      const bool layered = params.grainSynthesisLayered;
      const bool fixedRadius = params.grainSynthesisRadiusStdDevRatio <= 1.0e-6f;
      const bool halfTarget = impl_->grainSynthesisTargetStorageMode == GrainSynthesisTargetStorageMode::HalfBuffer;
      const bool textureTarget = impl_->grainSynthesisTargetStorageMode == GrainSynthesisTargetStorageMode::R16TextureArray;
      id<MTLBuffer> targetBuffer = halfTarget ? grainSynthesisTargetHalfBuffer : grainLayerBufferB;
      id<MTLComputePipelineState> targetPipeline = nil;
      if (textureTarget) {
        targetPipeline = layered
          ? impl_->grainSynthesisTargetDensityTexturePipeline
          : impl_->grainSynthesisTargetDensityNonLayeredTexturePipeline;
      } else if (halfTarget) {
        targetPipeline = layered
          ? impl_->grainSynthesisTargetDensityHalfPipeline
          : impl_->grainSynthesisTargetDensityNonLayeredHalfPipeline;
      } else {
        targetPipeline = layered
          ? impl_->grainSynthesisTargetDensityPipeline
          : impl_->grainSynthesisTargetDensityNonLayeredPipeline;
      }
      [encoder setComputePipelineState:targetPipeline];
      [encoder setBuffer:densityBuffer offset:0 atIndex:0];
      if (textureTarget) {
        [encoder setTexture:grainSynthesisTargetTexture atIndex:0];
      } else {
        [encoder setBuffer:targetBuffer offset:0 atIndex:1];
      }
      [encoder setBuffer:paramBuffer offset:0 atIndex:2];
      [encoder setBytes:dims length:sizeof(dims) atIndex:3];
      [encoder setBuffer:curveInfoBuffer offset:0 atIndex:4];
      [encoder setBuffer:densityCurvesBuffer offset:0 atIndex:5];
      [encoder setBuffer:spectralInfoBuffer offset:0 atIndex:6];
      [encoder setBuffer:paperScanDensityDataBuffer offset:0 atIndex:7];
      dispatch3DDepth(targetPipeline, layered ? 9u : 3u);
      if (textureTarget && !encodeFailed) {
        [encoder memoryBarrierWithScope:MTLBarrierScopeTextures];
      }

      id<MTLComputePipelineState> synthesisPipeline = nil;
      if (textureTarget) {
        if (layered) {
          synthesisPipeline = fixedRadius
            ? impl_->grainSynthesisLayersFromTargetDensityTextureFixedRadiusPipeline
            : impl_->grainSynthesisLayersFromTargetDensityTexturePipeline;
        } else {
          synthesisPipeline = fixedRadius
            ? impl_->grainSynthesisLayersFromTargetDensityNonLayeredTextureFixedRadiusPipeline
            : impl_->grainSynthesisLayersFromTargetDensityNonLayeredTexturePipeline;
        }
      } else if (halfTarget) {
        if (layered) {
          synthesisPipeline = fixedRadius
            ? impl_->grainSynthesisLayersFromTargetDensityHalfFixedRadiusPipeline
            : impl_->grainSynthesisLayersFromTargetDensityHalfPipeline;
        } else {
          synthesisPipeline = fixedRadius
            ? impl_->grainSynthesisLayersFromTargetDensityNonLayeredHalfFixedRadiusPipeline
            : impl_->grainSynthesisLayersFromTargetDensityNonLayeredHalfPipeline;
        }
      } else {
        if (layered) {
          synthesisPipeline = fixedRadius
            ? impl_->grainSynthesisLayersFromTargetDensityFixedRadiusPipeline
            : impl_->grainSynthesisLayersFromTargetDensityPipeline;
        } else {
          synthesisPipeline = fixedRadius
            ? impl_->grainSynthesisLayersFromTargetDensityNonLayeredFixedRadiusPipeline
            : impl_->grainSynthesisLayersFromTargetDensityNonLayeredPipeline;
        }
      }
      [encoder setComputePipelineState:synthesisPipeline];
      if (textureTarget) {
        [encoder setTexture:grainSynthesisTargetTexture atIndex:0];
      } else {
        [encoder setBuffer:targetBuffer offset:0 atIndex:0];
      }
      [encoder setBuffer:grainLayerBufferA offset:0 atIndex:1];
      [encoder setBuffer:paramBuffer offset:0 atIndex:2];
      [encoder setBytes:dims length:sizeof(dims) atIndex:3];
      [encoder setBuffer:grainSynthesisComponentInfoBuffer offset:0 atIndex:4];
      [encoder setBuffer:grainSynthesisSampleOffsetBuffer offset:0 atIndex:5];
      [encoder setBuffer:grainSynthesisRadiusLutBuffer offset:0 atIndex:6];
      [encoder setBuffer:grainSynthesisCellOffsetBuffer offset:0 atIndex:7];
      dispatch3DDepth(synthesisPipeline, layered ? 9u : 3u);
    };

    auto encodeSelectedGrainSynthesisLayersFromDensity = [&](id<MTLBuffer> densityBuffer) {
      if (optimizedGrainSynthesisPath) {
        encodeOptimizedGrainSynthesisLayersFromDensity(densityBuffer);
      } else {
        encodeGrainSynthesisLayersFromDensity(densityBuffer);
      }
    };

    auto encodeDiffusion = [&](id<MTLBuffer> sourceBuffer, id<MTLBuffer> destinationBuffer,
                               id<MTLBuffer> tempBuffer, id<MTLBuffer> accumBuffer,
                               id<MTLBuffer> infoBuffer, id<MTLBuffer> componentsBuffer,
                               const std::vector<KernelDiffusionComponent> &components) {
      [encoder setComputePipelineState:impl_->halationClearPipeline];
      [encoder setBuffer:sourceBuffer offset:0 atIndex:0];
      [encoder setBuffer:accumBuffer offset:0 atIndex:1];
      [encoder setBytes:dims length:sizeof(dims) atIndex:2];
      dispatch2D(impl_->halationClearPipeline);

      const uint32_t componentCount = static_cast<uint32_t>(components.size());
      const uint32_t maxDiffusionGroupSize = std::min(std::max(impl_->diffusionGroupSize, 1u), 4u);
      auto encodeFullResDiffusionRange = [&](uint32_t component, uint32_t groupCount) {
        if (groupCount <= 1u) {
          [encoder setComputePipelineState:impl_->diffusionComponentBlurXPipeline];
          [encoder setBuffer:sourceBuffer offset:0 atIndex:0];
          [encoder setBuffer:tempBuffer offset:0 atIndex:1];
          [encoder setBuffer:componentsBuffer offset:0 atIndex:2];
          [encoder setBytes:dims length:sizeof(dims) atIndex:3];
          [encoder setBytes:&component length:sizeof(component) atIndex:4];
          dispatch2D(impl_->diffusionComponentBlurXPipeline);

          [encoder setComputePipelineState:impl_->diffusionComponentBlurYAccumulatePipeline];
          [encoder setBuffer:tempBuffer offset:0 atIndex:0];
          [encoder setBuffer:accumBuffer offset:0 atIndex:1];
          [encoder setBuffer:componentsBuffer offset:0 atIndex:2];
          [encoder setBytes:dims length:sizeof(dims) atIndex:3];
          [encoder setBytes:&component length:sizeof(component) atIndex:4];
          dispatch2D(impl_->diffusionComponentBlurYAccumulatePipeline);
          return;
        }

        const uint32_t componentRange[2] = {component, groupCount};
        [encoder setComputePipelineState:impl_->diffusionGroupBlurXPipeline];
        [encoder setBuffer:sourceBuffer offset:0 atIndex:0];
        [encoder setBuffer:tempBuffer offset:0 atIndex:1];
        [encoder setBuffer:componentsBuffer offset:0 atIndex:2];
        [encoder setBytes:dims length:sizeof(dims) atIndex:3];
        [encoder setBytes:componentRange length:sizeof(componentRange) atIndex:4];
        dispatch2D(impl_->diffusionGroupBlurXPipeline, static_cast<uint64_t>(bufferBytes) * (groupCount + 1u));

        [encoder setComputePipelineState:impl_->diffusionGroupBlurYAccumulatePipeline];
        [encoder setBuffer:tempBuffer offset:0 atIndex:0];
        [encoder setBuffer:accumBuffer offset:0 atIndex:1];
        [encoder setBuffer:componentsBuffer offset:0 atIndex:2];
        [encoder setBytes:dims length:sizeof(dims) atIndex:3];
        [encoder setBytes:componentRange length:sizeof(componentRange) atIndex:4];
        dispatch2D(impl_->diffusionGroupBlurYAccumulatePipeline, static_cast<uint64_t>(bufferBytes) * (groupCount + 1u));
      };

      auto encodeDownsampleDiffusionRange = [&](uint32_t component, uint32_t groupCount, uint32_t downsampleScale) {
        const uint32_t reducedDims[2] = {
          static_cast<uint32_t>((width + static_cast<int32_t>(downsampleScale) - 1) / static_cast<int32_t>(downsampleScale)),
          static_cast<uint32_t>((height + static_cast<int32_t>(downsampleScale) - 1) / static_cast<int32_t>(downsampleScale)),
        };
        const uint64_t reducedBytes = static_cast<uint64_t>(reducedDims[0]) *
          static_cast<uint64_t>(reducedDims[1]) * pixelBytes;
        const uint64_t reducedIntermediateBytes = diffusionDownsampleHalfPath
          ? static_cast<uint64_t>(reducedDims[0]) * static_cast<uint64_t>(reducedDims[1]) * 4u * sizeof(uint16_t)
          : reducedBytes;
        const float sigmaScale = 1.0f / static_cast<float>(downsampleScale);

        [encoder setComputePipelineState:impl_->diffusionDownsamplePipeline];
        [encoder setBuffer:sourceBuffer offset:0 atIndex:0];
        [encoder setBuffer:diffusionDownsampleSourceBuffer offset:0 atIndex:1];
        [encoder setBytes:dims length:sizeof(dims) atIndex:2];
        [encoder setBytes:reducedDims length:sizeof(reducedDims) atIndex:3];
        [encoder setBytes:&downsampleScale length:sizeof(downsampleScale) atIndex:4];
        dispatch2DSize(
          impl_->diffusionDownsamplePipeline,
          reducedDims[0],
          reducedDims[1],
          static_cast<uint64_t>(width) * static_cast<uint64_t>(height) * pixelBytes + reducedBytes
        );

        if (groupCount <= 1u) {
          id<MTLComputePipelineState> blurXPipeline = diffusionDownsampleHalfPath
            ? impl_->diffusionDownsampleBlurXHalfPipeline
            : impl_->diffusionDownsampleBlurXPipeline;
          id<MTLComputePipelineState> blurYPipeline = diffusionDownsampleHalfPath
            ? impl_->diffusionDownsampleBlurYHalfPipeline
            : impl_->diffusionDownsampleBlurYPipeline;
          id<MTLComputePipelineState> upsamplePipeline = diffusionDownsampleHalfPath
            ? impl_->diffusionDownsampleUpsampleAccumulateHalfPipeline
            : impl_->diffusionDownsampleUpsampleAccumulatePipeline;

          [encoder setComputePipelineState:blurXPipeline];
          [encoder setBuffer:diffusionDownsampleSourceBuffer offset:0 atIndex:0];
          [encoder setBuffer:diffusionDownsampleTempBuffer offset:0 atIndex:1];
          [encoder setBuffer:componentsBuffer offset:0 atIndex:2];
          [encoder setBytes:reducedDims length:sizeof(reducedDims) atIndex:3];
          [encoder setBytes:&component length:sizeof(component) atIndex:4];
          [encoder setBytes:&sigmaScale length:sizeof(sigmaScale) atIndex:5];
          dispatch2DSize(blurXPipeline, reducedDims[0], reducedDims[1], reducedBytes + reducedIntermediateBytes);

          [encoder setComputePipelineState:blurYPipeline];
          [encoder setBuffer:diffusionDownsampleTempBuffer offset:0 atIndex:0];
          [encoder setBuffer:diffusionDownsampleBlurBuffer offset:0 atIndex:1];
          [encoder setBuffer:componentsBuffer offset:0 atIndex:2];
          [encoder setBytes:reducedDims length:sizeof(reducedDims) atIndex:3];
          [encoder setBytes:&component length:sizeof(component) atIndex:4];
          [encoder setBytes:&sigmaScale length:sizeof(sigmaScale) atIndex:5];
          dispatch2DSize(blurYPipeline, reducedDims[0], reducedDims[1], reducedIntermediateBytes * 2u);

          [encoder setComputePipelineState:upsamplePipeline];
          [encoder setBuffer:diffusionDownsampleBlurBuffer offset:0 atIndex:0];
          [encoder setBuffer:accumBuffer offset:0 atIndex:1];
          [encoder setBuffer:componentsBuffer offset:0 atIndex:2];
          [encoder setBytes:dims length:sizeof(dims) atIndex:3];
          [encoder setBytes:reducedDims length:sizeof(reducedDims) atIndex:4];
          [encoder setBytes:&component length:sizeof(component) atIndex:5];
          [encoder setBytes:&downsampleScale length:sizeof(downsampleScale) atIndex:6];
          dispatch2D(upsamplePipeline, static_cast<uint64_t>(bufferBytes) + reducedIntermediateBytes);
          return;
        }

        const uint32_t componentRange[2] = {component, groupCount};
        id<MTLComputePipelineState> groupBlurXPipeline = diffusionDownsampleHalfPath
          ? impl_->diffusionDownsampleGroupBlurXHalfPipeline
          : impl_->diffusionDownsampleGroupBlurXPipeline;
        id<MTLComputePipelineState> groupBlurYPipeline = diffusionDownsampleHalfPath
          ? impl_->diffusionDownsampleGroupBlurYHalfPipeline
          : impl_->diffusionDownsampleGroupBlurYPipeline;
        id<MTLComputePipelineState> groupUpsamplePipeline = diffusionDownsampleHalfPath
          ? impl_->diffusionDownsampleGroupUpsampleAccumulateHalfPipeline
          : impl_->diffusionDownsampleGroupUpsampleAccumulatePipeline;

        [encoder setComputePipelineState:groupBlurXPipeline];
        [encoder setBuffer:diffusionDownsampleSourceBuffer offset:0 atIndex:0];
        [encoder setBuffer:diffusionDownsampleTempBuffer offset:0 atIndex:1];
        [encoder setBuffer:componentsBuffer offset:0 atIndex:2];
        [encoder setBytes:reducedDims length:sizeof(reducedDims) atIndex:3];
        [encoder setBytes:componentRange length:sizeof(componentRange) atIndex:4];
        [encoder setBytes:&sigmaScale length:sizeof(sigmaScale) atIndex:5];
        dispatch2DSize(groupBlurXPipeline, reducedDims[0], reducedDims[1], reducedBytes + reducedIntermediateBytes * groupCount);

        [encoder setComputePipelineState:groupBlurYPipeline];
        [encoder setBuffer:diffusionDownsampleTempBuffer offset:0 atIndex:0];
        [encoder setBuffer:diffusionDownsampleBlurBuffer offset:0 atIndex:1];
        [encoder setBuffer:componentsBuffer offset:0 atIndex:2];
        [encoder setBytes:reducedDims length:sizeof(reducedDims) atIndex:3];
        [encoder setBytes:componentRange length:sizeof(componentRange) atIndex:4];
        [encoder setBytes:&sigmaScale length:sizeof(sigmaScale) atIndex:5];
        dispatch2DSize(groupBlurYPipeline, reducedDims[0], reducedDims[1], reducedIntermediateBytes * groupCount * 2u);

        [encoder setComputePipelineState:groupUpsamplePipeline];
        [encoder setBuffer:diffusionDownsampleBlurBuffer offset:0 atIndex:0];
        [encoder setBuffer:accumBuffer offset:0 atIndex:1];
        [encoder setBuffer:componentsBuffer offset:0 atIndex:2];
        [encoder setBytes:dims length:sizeof(dims) atIndex:3];
        [encoder setBytes:reducedDims length:sizeof(reducedDims) atIndex:4];
        [encoder setBytes:componentRange length:sizeof(componentRange) atIndex:5];
        [encoder setBytes:&downsampleScale length:sizeof(downsampleScale) atIndex:6];
        dispatch2D(groupUpsamplePipeline, static_cast<uint64_t>(bufferBytes) + reducedIntermediateBytes * groupCount);
      };

      if (diffusionDownsamplePath && diffusionDownsampleSourceBuffer && diffusionDownsampleTempBuffer && diffusionDownsampleBlurBuffer) {
        for (uint32_t component = 0; component < componentCount;) {
          const uint32_t downsampleScale = diffusionDownsampleScaleForSigma(impl_->blurDownsample, components[component].sigmaPx);
          uint32_t groupCount = 1u;
          while (component + groupCount < componentCount && groupCount < maxDiffusionGroupSize &&
                 diffusionDownsampleScaleForSigma(impl_->blurDownsample, components[component + groupCount].sigmaPx) == downsampleScale) {
            ++groupCount;
          }
          if (downsampleScale <= 1u) {
            encodeFullResDiffusionRange(component, groupCount);
            component += groupCount;
            continue;
          }

          encodeDownsampleDiffusionRange(component, groupCount, downsampleScale);
          component += groupCount;
        }
      } else {
        for (uint32_t component = 0; component < componentCount; component += maxDiffusionGroupSize) {
          const uint32_t groupCount = std::min(maxDiffusionGroupSize, componentCount - component);
          encodeFullResDiffusionRange(component, groupCount);
        }
      }

      [encoder setComputePipelineState:impl_->diffusionResolvePipeline];
      [encoder setBuffer:sourceBuffer offset:0 atIndex:0];
      [encoder setBuffer:accumBuffer offset:0 atIndex:1];
      [encoder setBuffer:destinationBuffer offset:0 atIndex:2];
      [encoder setBuffer:infoBuffer offset:0 atIndex:3];
      [encoder setBytes:dims length:sizeof(dims) atIndex:4];
      dispatch2D(impl_->diffusionResolvePipeline);
    };

    auto encodeFinalFromPrintRaw = [&](id<MTLBuffer> printRawBuffer) {
      const uint32_t encodeOutput = !impl_->linearFinalOutput && directFinalEncodePath ? 1u : 0u;
      [encoder setComputePipelineState:impl_->finalFromPrintRawPipeline];
      [encoder setBuffer:printRawBuffer offset:0 atIndex:0];
      [encoder setBuffer:(directFinalEncodePath || !finalPostProcessPath ? dstBuffer : scannerRgbBufferA) offset:0 atIndex:1];
      [encoder setBuffer:paramBuffer offset:0 atIndex:2];
      [encoder setBytes:dims length:sizeof(dims) atIndex:3];
      [encoder setBuffer:paperCurveInfoBuffer offset:0 atIndex:4];
      [encoder setBuffer:paperLogExposureBuffer offset:0 atIndex:5];
      [encoder setBuffer:paperDensityCurvesBuffer offset:0 atIndex:6];
      [encoder setBuffer:spectralInfoBuffer offset:0 atIndex:7];
      [encoder setBuffer:colorInfoBuffer offset:0 atIndex:8];
      [encoder setBuffer:colorTransferKindBuffer offset:0 atIndex:9];
      [encoder setBuffer:paperSpectralDensityBuffer offset:0 atIndex:10];
      [encoder setBuffer:scanProductsBuffer offset:0 atIndex:11];
      [encoder setBuffer:scanToOutputRgbDataBuffer offset:0 atIndex:12];
      [encoder setBuffer:colorEncodeLutBuffer offset:0 atIndex:13];
      [encoder setBuffer:curveInfoBuffer offset:0 atIndex:14];
      [encoder setBuffer:logExposureBuffer offset:0 atIndex:15];
      [encoder setBuffer:densityCurvesBuffer offset:0 atIndex:16];
      [encoder setBuffer:logSensitivityBuffer offset:0 atIndex:17];
      [encoder setBuffer:bandpassHanatosBuffer offset:0 atIndex:18];
      [encoder setBuffer:hanatosRawResponseBuffer offset:0 atIndex:19];
      [encoder setBuffer:mallettBasisIlluminantBuffer offset:0 atIndex:20];
      [encoder setBuffer:inputToReferenceXyzBuffer offset:0 atIndex:21];
      [encoder setBuffer:filmChannelDensityBuffer offset:0 atIndex:22];
      [encoder setBuffer:filmSpectralDensityBuffer offset:0 atIndex:23];
      [encoder setBuffer:paperLogSensitivityBuffer offset:0 atIndex:24];
      [encoder setBuffer:thKg3IlluminantBuffer offset:0 atIndex:25];
      [encoder setBuffer:customEnlargerFiltersBuffer offset:0 atIndex:26];
      [encoder setBuffer:neutralPrintFiltersBuffer offset:0 atIndex:27];
      [encoder setBuffer:academyPrinterDensityDataBuffer offset:0 atIndex:28];
      [encoder setBuffer:frameConstantsBuffer offset:0 atIndex:29];
      [encoder setBytes:&encodeOutput length:sizeof(encodeOutput) atIndex:30];
      dispatch2D(impl_->finalFromPrintRawPipeline);
      if (finalPostProcessPath && !directFinalEncodePath) {
        encodeScannerPostProcess(scannerRgbBufferA);
      }
    };

    auto encodePrintRawFromFilmDensity = [&](id<MTLBuffer> filmDensityBuffer, id<MTLBuffer> printRawBuffer) {
      [encoder setComputePipelineState:impl_->printRawFromFilmDensityPipeline];
      [encoder setBuffer:filmDensityBuffer offset:0 atIndex:0];
      [encoder setBuffer:printRawBuffer offset:0 atIndex:1];
      [encoder setBuffer:paramBuffer offset:0 atIndex:2];
      [encoder setBytes:dims length:sizeof(dims) atIndex:3];
      [encoder setBuffer:curveInfoBuffer offset:0 atIndex:4];
      [encoder setBuffer:logExposureBuffer offset:0 atIndex:5];
      [encoder setBuffer:densityCurvesBuffer offset:0 atIndex:6];
      [encoder setBuffer:spectralInfoBuffer offset:0 atIndex:7];
      [encoder setBuffer:colorInfoBuffer offset:0 atIndex:8];
      [encoder setBuffer:logSensitivityBuffer offset:0 atIndex:9];
      [encoder setBuffer:bandpassHanatosBuffer offset:0 atIndex:10];
      [encoder setBuffer:hanatosRawResponseBuffer offset:0 atIndex:11];
      [encoder setBuffer:mallettBasisIlluminantBuffer offset:0 atIndex:12];
      [encoder setBuffer:inputToReferenceXyzBuffer offset:0 atIndex:13];
      [encoder setBuffer:filmChannelDensityBuffer offset:0 atIndex:14];
      [encoder setBuffer:filmSpectralDensityBuffer offset:0 atIndex:15];
      [encoder setBuffer:filteredEnlargerResponseBuffer offset:0 atIndex:16];
      [encoder setBuffer:thKg3IlluminantBuffer offset:0 atIndex:17];
      [encoder setBuffer:customEnlargerFiltersBuffer offset:0 atIndex:18];
      [encoder setBuffer:neutralPrintFiltersBuffer offset:0 atIndex:19];
      [encoder setBuffer:academyPrinterDensityDataBuffer offset:0 atIndex:20];
      [encoder setBuffer:frameConstantsBuffer offset:0 atIndex:21];
      dispatch2D(impl_->printRawFromFilmDensityPipeline);
    };

    auto encodePrintRawFromNegativeLight = [&](id<MTLBuffer> sourceBuffer, id<MTLBuffer> printRawBuffer) {
      [encoder setComputePipelineState:impl_->printRawFromNegativeLightPipeline];
      [encoder setBuffer:sourceBuffer offset:0 atIndex:0];
      [encoder setBuffer:printRawBuffer offset:0 atIndex:1];
      [encoder setBuffer:paramBuffer offset:0 atIndex:2];
      [encoder setBytes:dims length:sizeof(dims) atIndex:3];
      [encoder setBuffer:spectralInfoBuffer offset:0 atIndex:4];
      [encoder setBuffer:colorInfoBuffer offset:0 atIndex:5];
      [encoder setBuffer:colorDecodeLutBuffer offset:0 atIndex:6];
      [encoder setBuffer:colorTransferKindBuffer offset:0 atIndex:7];
      [encoder setBuffer:inputToReferenceXyzBuffer offset:0 atIndex:8];
      [encoder setBuffer:paperHanatosResponseBuffer offset:0 atIndex:9];
      [encoder setBuffer:preflashPaperHanatosResponseBuffer offset:0 atIndex:10];
      [encoder setBuffer:academyPrinterDensityDataBuffer offset:0 atIndex:11];
      dispatch2D(impl_->printRawFromNegativeLightPipeline);
    };

    auto encodePrintDensityFromPrintRaw = [&](id<MTLBuffer> printRawBuffer, id<MTLBuffer> destinationBuffer) {
      [encoder setComputePipelineState:impl_->printDensityFromPrintRawPipeline];
      [encoder setBuffer:printRawBuffer offset:0 atIndex:0];
      [encoder setBuffer:destinationBuffer offset:0 atIndex:1];
      [encoder setBuffer:paramBuffer offset:0 atIndex:2];
      [encoder setBytes:dims length:sizeof(dims) atIndex:3];
      [encoder setBuffer:paperCurveInfoBuffer offset:0 atIndex:4];
      [encoder setBuffer:paperLogExposureBuffer offset:0 atIndex:5];
      [encoder setBuffer:paperDensityCurvesBuffer offset:0 atIndex:6];
      [encoder setBuffer:spectralInfoBuffer offset:0 atIndex:7];
      dispatch2D(impl_->printDensityFromPrintRawPipeline);
    };

    auto encodeProfilePrintScanFromDensity = [&](id<MTLBuffer> printDensityBuffer, id<MTLBuffer> linearRgbBuffer) {
      [encoder setComputePipelineState:impl_->profilePrintScanFromDensityPipeline];
      [encoder setBuffer:printDensityBuffer offset:0 atIndex:0];
      [encoder setBuffer:linearRgbBuffer offset:0 atIndex:1];
      [encoder setBuffer:paramBuffer offset:0 atIndex:2];
      [encoder setBytes:dims length:sizeof(dims) atIndex:3];
      [encoder setBuffer:spectralInfoBuffer offset:0 atIndex:4];
      [encoder setBuffer:colorInfoBuffer offset:0 atIndex:5];
      [encoder setBuffer:paperSpectralDensityBuffer offset:0 atIndex:6];
      [encoder setBuffer:scanProductsBuffer offset:0 atIndex:7];
      [encoder setBuffer:scanToOutputRgbDataBuffer offset:0 atIndex:8];
      [encoder setBuffer:frameConstantsBuffer offset:0 atIndex:9];
      dispatch2D(impl_->profilePrintScanFromDensityPipeline);
    };

    auto encodeProfileFinalizeOutput = [&](id<MTLBuffer> linearRgbBuffer) {
      const uint32_t encodeOutput = impl_->linearFinalOutput ? 0u : 1u;
      [encoder setComputePipelineState:impl_->profileFinalizeOutputPipeline];
      [encoder setBuffer:linearRgbBuffer offset:0 atIndex:0];
      [encoder setBuffer:dstBuffer offset:0 atIndex:1];
      [encoder setBuffer:paramBuffer offset:0 atIndex:2];
      [encoder setBytes:dims length:sizeof(dims) atIndex:3];
      [encoder setBuffer:colorInfoBuffer offset:0 atIndex:4];
      [encoder setBuffer:colorTransferKindBuffer offset:0 atIndex:5];
      [encoder setBuffer:colorEncodeLutBuffer offset:0 atIndex:6];
      [encoder setBytes:&encodeOutput length:sizeof(encodeOutput) atIndex:7];
      dispatch2D(impl_->profileFinalizeOutputPipeline);
    };

    auto encodeStagedFinalCore = [&](id<MTLBuffer> filmDensityBuffer) {
      encodePrintRawFromFilmDensity(filmDensityBuffer, printRawBufferA);
      encodePrintDensityFromPrintRaw(printRawBufferA, printRawBufferB);
      encodeProfilePrintScanFromDensity(printRawBufferB, scannerRgbBufferA);
      encodeProfileFinalizeOutput(scannerRgbBufferA);
    };

    auto encodePrintStageOutputFromRaw = [&](id<MTLBuffer> printRawBuffer) {
      if (printLogRawOutput) {
        [encoder setComputePipelineState:impl_->rawToLogRawPipeline];
        [encoder setBuffer:printRawBuffer offset:0 atIndex:0];
        [encoder setBuffer:dstBuffer offset:0 atIndex:1];
        [encoder setBytes:dims length:sizeof(dims) atIndex:2];
        dispatch2D(impl_->rawToLogRawPipeline);
      } else if (printDensityOutput) {
        encodePrintDensityFromPrintRaw(printRawBuffer, dstBuffer);
      } else {
        encodeFinalFromPrintRaw(printRawBuffer);
      }
    };

    auto encodePrintDiffusionFromFilmDensity = [&](id<MTLBuffer> filmDensityBuffer) {
      encodePrintRawFromFilmDensity(filmDensityBuffer, printRawBufferA);
      encodeDiffusion(
        printRawBufferA,
        printRawBufferB,
        printRawBufferB,
        printRawBufferC,
        printDiffusionInfoBuffer,
        printDiffusionComponentsBuffer,
        printDiffusionComponents
      );
      encodePrintStageOutputFromRaw(printRawBufferB);
    };

    auto encodePrintDiffusionFromNegativeLight = [&]() {
      encodePrintRawFromNegativeLight(renderSourceBuffer, printRawBufferA);
      encodeDiffusion(
        printRawBufferA,
        printRawBufferB,
        printRawBufferB,
        printRawBufferC,
        printDiffusionInfoBuffer,
        printDiffusionComponentsBuffer,
        printDiffusionComponents
      );
      encodeFinalFromPrintRaw(printRawBufferB);
    };

    auto encodeFinalFilmDensityOrPrintDiffusion = [&](id<MTLBuffer> filmDensityBuffer) {
      if (densityOutput || densityWithGrainOutput) {
        encodeCopyBufferToDestination(filmDensityBuffer);
      } else if (printDiffusionPath) {
        encodePrintDiffusionFromFilmDensity(filmDensityBuffer);
      } else if (printStageOutput) {
        encodePrintRawFromFilmDensity(filmDensityBuffer, printRawBufferA);
        encodePrintStageOutputFromRaw(printRawBufferA);
      } else if (stagedFinalCorePath) {
        encodeStagedFinalCore(filmDensityBuffer);
      } else {
        encodeFinalFromFilmDensity(filmDensityBuffer);
      }
    };

    if (finalProcessNegative) {
      if (printDiffusionPath) {
        encodePrintDiffusionFromNegativeLight();
      } else {
        encodePrintRawFromNegativeLight(renderSourceBuffer, printRawBufferA);
        encodeFinalFromPrintRaw(printRawBufferA);
      }
    } else if (preExposureBranchPath) {
      [encoder setComputePipelineState:impl_->halationRawExposurePipeline];
      [encoder setBuffer:renderSourceBuffer offset:0 atIndex:0];
      [encoder setBuffer:halationRawBufferA offset:0 atIndex:1];
      [encoder setBuffer:paramBuffer offset:0 atIndex:2];
      [encoder setBytes:dims length:sizeof(dims) atIndex:3];
      [encoder setBuffer:spectralInfoBuffer offset:0 atIndex:4];
      [encoder setBuffer:logSensitivityBuffer offset:0 atIndex:5];
      [encoder setBuffer:bandpassHanatosBuffer offset:0 atIndex:6];
      [encoder setBuffer:hanatosRawResponseBuffer offset:0 atIndex:7];
      [encoder setBuffer:mallettBasisIlluminantBuffer offset:0 atIndex:8];
      [encoder setBuffer:inputToReferenceXyzBuffer offset:0 atIndex:9];
      [encoder setBuffer:inputToSrgbBuffer offset:0 atIndex:10];
      [encoder setBuffer:colorInfoBuffer offset:0 atIndex:11];
      [encoder setBuffer:colorDecodeLutBuffer offset:0 atIndex:12];
      [encoder setBuffer:colorTransferKindBuffer offset:0 atIndex:13];
      dispatch2D(impl_->halationRawExposurePipeline);

      id<MTLBuffer> currentRawBuffer = halationRawBufferA;
      if (halationBoostPath) {
        [encoder setComputePipelineState:impl_->halationBoostMaxPipeline];
        [encoder setBuffer:currentRawBuffer offset:0 atIndex:0];
        [encoder setBuffer:halationBoostMaxBuffer offset:0 atIndex:1];
        [encoder setBytes:dims length:sizeof(dims) atIndex:2];
        [encoder setBytes:&kHalationBoostMaxChunkPixels length:sizeof(kHalationBoostMaxChunkPixels) atIndex:3];
        dispatch1D(impl_->halationBoostMaxPipeline, halationBoostMaxChunkCount, bufferBytes);

        [encoder setComputePipelineState:impl_->halationBoostReduceMaxPipeline];
        [encoder setBuffer:halationBoostMaxBuffer offset:0 atIndex:0];
        [encoder setBuffer:halationBoostMaxBuffer offset:0 atIndex:1];
        [encoder setBytes:&halationBoostMaxChunkCount length:sizeof(halationBoostMaxChunkCount) atIndex:2];
        [encoder setBuffer:paramBuffer offset:0 atIndex:3];
        dispatch1D(
          impl_->halationBoostReduceMaxPipeline,
          1u,
          static_cast<uint64_t>(std::max(halationBoostMaxChunkCount, 1u)) * sizeof(float)
        );

        [encoder setComputePipelineState:impl_->halationBoostApplyPipeline];
        [encoder setBuffer:currentRawBuffer offset:0 atIndex:0];
        [encoder setBuffer:halationRawBufferB offset:0 atIndex:1];
        [encoder setBuffer:halationBoostMaxBuffer offset:0 atIndex:2];
        [encoder setBuffer:paramBuffer offset:0 atIndex:3];
        [encoder setBytes:dims length:sizeof(dims) atIndex:4];
        dispatch2D(impl_->halationBoostApplyPipeline);
        currentRawBuffer = halationRawBufferB;
      }
      if (cameraDiffusionPath) {
        id<MTLBuffer> diffusionDestinationBuffer = currentRawBuffer == halationRawBufferA ? halationRawBufferB : halationRawBufferA;
        encodeDiffusion(
          currentRawBuffer,
          diffusionDestinationBuffer,
          halationRawBufferC,
          halationRawBufferD,
          cameraDiffusionInfoBuffer,
          cameraDiffusionComponentsBuffer,
          cameraDiffusionComponents
        );
        currentRawBuffer = diffusionDestinationBuffer;
      }

      if (halationScatterPath) {
        id<MTLBuffer> scatterTempBuffer = currentRawBuffer == halationRawBufferA ? halationRawBufferB : halationRawBufferA;
        id<MTLBuffer> scatterCoreBuffer = halationRawBufferC;
        id<MTLBuffer> scatterAccumBuffer = halationRawBufferD;
        id<MTLBuffer> scatterResolvedBuffer = scatterTempBuffer;

        [encoder setComputePipelineState:impl_->halationScatterCoreBlurXPipeline];
        [encoder setBuffer:currentRawBuffer offset:0 atIndex:0];
        [encoder setBuffer:scatterTempBuffer offset:0 atIndex:1];
        [encoder setBuffer:paramBuffer offset:0 atIndex:2];
        [encoder setBytes:dims length:sizeof(dims) atIndex:3];
        dispatch2D(impl_->halationScatterCoreBlurXPipeline);

        [encoder setComputePipelineState:impl_->halationScatterCoreBlurYPipeline];
        [encoder setBuffer:scatterTempBuffer offset:0 atIndex:0];
        [encoder setBuffer:scatterCoreBuffer offset:0 atIndex:1];
        [encoder setBuffer:paramBuffer offset:0 atIndex:2];
        [encoder setBytes:dims length:sizeof(dims) atIndex:3];
        dispatch2D(impl_->halationScatterCoreBlurYPipeline);

        [encoder setComputePipelineState:impl_->halationClearPipeline];
        [encoder setBuffer:currentRawBuffer offset:0 atIndex:0];
        [encoder setBuffer:scatterAccumBuffer offset:0 atIndex:1];
        [encoder setBytes:dims length:sizeof(dims) atIndex:2];
        dispatch2D(impl_->halationClearPipeline);

        if (impl_->halationGroupedTail && halationScatterTailGroupBuffer) {
          [encoder setComputePipelineState:impl_->halationScatterTailGroupBlurXPipeline];
          [encoder setBuffer:currentRawBuffer offset:0 atIndex:0];
          [encoder setBuffer:halationScatterTailGroupBuffer offset:0 atIndex:1];
          [encoder setBuffer:paramBuffer offset:0 atIndex:2];
          [encoder setBytes:dims length:sizeof(dims) atIndex:3];
          dispatch2D(impl_->halationScatterTailGroupBlurXPipeline, static_cast<uint64_t>(bufferBytes) * 4u);

          [encoder setComputePipelineState:impl_->halationScatterTailGroupBlurYPipeline];
          [encoder setBuffer:halationScatterTailGroupBuffer offset:0 atIndex:0];
          [encoder setBuffer:scatterAccumBuffer offset:0 atIndex:1];
          [encoder setBuffer:paramBuffer offset:0 atIndex:2];
          [encoder setBytes:dims length:sizeof(dims) atIndex:3];
          dispatch2D(impl_->halationScatterTailGroupBlurYPipeline, static_cast<uint64_t>(bufferBytes) * 4u);
        } else {
          for (uint32_t component = 0; component < 3u; ++component) {
            [encoder setComputePipelineState:impl_->halationScatterTailBlurXPipeline];
            [encoder setBuffer:currentRawBuffer offset:0 atIndex:0];
            [encoder setBuffer:scatterTempBuffer offset:0 atIndex:1];
            [encoder setBuffer:paramBuffer offset:0 atIndex:2];
            [encoder setBytes:dims length:sizeof(dims) atIndex:3];
            [encoder setBytes:&component length:sizeof(component) atIndex:4];
            dispatch2D(impl_->halationScatterTailBlurXPipeline);

            [encoder setComputePipelineState:impl_->halationScatterTailBlurYPipeline];
            [encoder setBuffer:scatterTempBuffer offset:0 atIndex:0];
            [encoder setBuffer:scatterAccumBuffer offset:0 atIndex:1];
            [encoder setBuffer:paramBuffer offset:0 atIndex:2];
            [encoder setBytes:dims length:sizeof(dims) atIndex:3];
            [encoder setBytes:&component length:sizeof(component) atIndex:4];
            dispatch2D(impl_->halationScatterTailBlurYPipeline);
          }
        }

        [encoder setComputePipelineState:impl_->halationScatterResolvePipeline];
        [encoder setBuffer:currentRawBuffer offset:0 atIndex:0];
        [encoder setBuffer:scatterCoreBuffer offset:0 atIndex:1];
        [encoder setBuffer:scatterAccumBuffer offset:0 atIndex:2];
        [encoder setBuffer:scatterResolvedBuffer offset:0 atIndex:3];
        [encoder setBuffer:paramBuffer offset:0 atIndex:4];
        [encoder setBytes:dims length:sizeof(dims) atIndex:5];
        dispatch2D(impl_->halationScatterResolvePipeline);
        currentRawBuffer = scatterResolvedBuffer;
      }

      const bool needsPreExposureLogRaw = dirPath || filmLogRawOutput;
      bool preExposureDensityReady = false;
      if (halationBouncePath) {
        id<MTLBuffer> bounceAccumBuffer = currentRawBuffer == halationRawBufferA ? halationRawBufferB : halationRawBufferA;
        [encoder setComputePipelineState:impl_->halationClearPipeline];
        [encoder setBuffer:currentRawBuffer offset:0 atIndex:0];
        [encoder setBuffer:bounceAccumBuffer offset:0 atIndex:1];
        [encoder setBytes:dims length:sizeof(dims) atIndex:2];
        dispatch2D(impl_->halationClearPipeline);

        for (uint32_t bounce = 0; bounce < 3u; ++bounce) {
          [encoder setComputePipelineState:impl_->halationBounceBlurXPipeline];
          [encoder setBuffer:currentRawBuffer offset:0 atIndex:0];
          [encoder setBuffer:halationRawBufferD offset:0 atIndex:1];
          [encoder setBuffer:paramBuffer offset:0 atIndex:2];
          [encoder setBytes:dims length:sizeof(dims) atIndex:3];
          [encoder setBytes:&bounce length:sizeof(bounce) atIndex:4];
          dispatch2D(impl_->halationBounceBlurXPipeline);

          [encoder setComputePipelineState:impl_->halationBounceBlurYAccumulatePipeline];
          [encoder setBuffer:halationRawBufferD offset:0 atIndex:0];
          [encoder setBuffer:bounceAccumBuffer offset:0 atIndex:1];
          [encoder setBuffer:paramBuffer offset:0 atIndex:2];
          [encoder setBytes:dims length:sizeof(dims) atIndex:3];
          [encoder setBytes:&bounce length:sizeof(bounce) atIndex:4];
          dispatch2D(impl_->halationBounceBlurYAccumulatePipeline);
        }

        if (needsPreExposureLogRaw) {
          [encoder setComputePipelineState:impl_->halationResolveLogRawPipeline];
          [encoder setBuffer:currentRawBuffer offset:0 atIndex:0];
          [encoder setBuffer:bounceAccumBuffer offset:0 atIndex:1];
          [encoder setBuffer:halationLogRawBuffer offset:0 atIndex:2];
          [encoder setBuffer:paramBuffer offset:0 atIndex:3];
          [encoder setBytes:dims length:sizeof(dims) atIndex:4];
          dispatch2D(impl_->halationResolveLogRawPipeline);
        } else {
          encodeHalationResolveDensity(currentRawBuffer, bounceAccumBuffer, halationDensityBufferA);
          preExposureDensityReady = true;
        }
      } else {
        if (needsPreExposureLogRaw) {
          [encoder setComputePipelineState:impl_->rawToLogRawPipeline];
          [encoder setBuffer:currentRawBuffer offset:0 atIndex:0];
          [encoder setBuffer:halationLogRawBuffer offset:0 atIndex:1];
          [encoder setBytes:dims length:sizeof(dims) atIndex:2];
          dispatch2D(impl_->rawToLogRawPipeline);
        } else {
          encodeDevelopFromRaw(currentRawBuffer, halationDensityBufferA);
          preExposureDensityReady = true;
        }
      }

      if (filmLogRawOutput) {
        encodeCopyBufferToDestination(halationLogRawBuffer);
      } else {
        if (!preExposureDensityReady) {
          encodeDevelopFromLogRaw(halationLogRawBuffer, halationDensityBufferA);
        }
        if (dirPath) {
          [encoder setComputePipelineState:impl_->dirCorrectionFromDensityPipeline];
          [encoder setBuffer:halationDensityBufferA offset:0 atIndex:0];
          [encoder setBuffer:dirCorrectionBufferA offset:0 atIndex:1];
          [encoder setBytes:dims length:sizeof(dims) atIndex:2];
          [encoder setBuffer:spectralInfoBuffer offset:0 atIndex:3];
          [encoder setBuffer:dirInfoBuffer offset:0 atIndex:4];
          dispatch2D(impl_->dirCorrectionFromDensityPipeline);

          id<MTLBuffer> blurredDirCorrectionBuffer = encodeDirCorrectionBlur(dirCorrectionBufferA);

          [encoder setComputePipelineState:impl_->dirRedevelopPipeline];
          [encoder setBuffer:halationLogRawBuffer offset:0 atIndex:0];
          [encoder setBuffer:blurredDirCorrectionBuffer offset:0 atIndex:1];
          [encoder setBuffer:halationDensityBufferA offset:0 atIndex:2];
          [encoder setBuffer:paramBuffer offset:0 atIndex:3];
          [encoder setBytes:dims length:sizeof(dims) atIndex:4];
          [encoder setBuffer:curveInfoBuffer offset:0 atIndex:5];
          [encoder setBuffer:logExposureBuffer offset:0 atIndex:6];
          [encoder setBuffer:dirCorrectedDensityCurvesBuffer offset:0 atIndex:7];
          dispatch2D(impl_->dirRedevelopPipeline);
        }

        if (productionGrainPath) {
          encodeProductionGrainLayersFromDensity(halationDensityBufferA);
          encodeSaveGrainBaseDensity(halationDensityBufferA);
        } else if (grainSynthesisPath) {
          encodeSelectedGrainSynthesisLayersFromDensity(halationDensityBufferA);
          encodeSaveGrainBaseDensity(halationDensityBufferA);
        } else if (previewGrainFromDensityPath) {
          [encoder setComputePipelineState:impl_->previewGrainFromDensityPipeline];
          [encoder setBuffer:halationDensityBufferA offset:0 atIndex:0];
          [encoder setBuffer:halationDensityBufferB offset:0 atIndex:1];
          [encoder setBuffer:paramBuffer offset:0 atIndex:2];
          [encoder setBytes:dims length:sizeof(dims) atIndex:3];
          [encoder setBuffer:curveInfoBuffer offset:0 atIndex:4];
          [encoder setBuffer:densityCurvesBuffer offset:0 atIndex:5];
          dispatch2D(impl_->previewGrainFromDensityPipeline);
          encodeFinalFilmDensityOrPrintDiffusion(halationDensityBufferB);
        } else {
          encodeFinalFilmDensityOrPrintDiffusion(halationDensityBufferA);
        }
      }
    } else if (dirPath) {
      [encoder setComputePipelineState:impl_->dirBaselinePipeline];
      [encoder setBuffer:renderSourceBuffer offset:0 atIndex:0];
      [encoder setBuffer:dirLogRawBuffer offset:0 atIndex:1];
      [encoder setBuffer:dirDensityBufferA offset:0 atIndex:2];
      [encoder setBuffer:dirCorrectionBufferA offset:0 atIndex:3];
      [encoder setBuffer:paramBuffer offset:0 atIndex:4];
      [encoder setBytes:dims length:sizeof(dims) atIndex:5];
      [encoder setBuffer:curveInfoBuffer offset:0 atIndex:6];
      [encoder setBuffer:logExposureBuffer offset:0 atIndex:7];
      [encoder setBuffer:densityCurvesBuffer offset:0 atIndex:8];
      [encoder setBuffer:spectralInfoBuffer offset:0 atIndex:9];
      [encoder setBuffer:logSensitivityBuffer offset:0 atIndex:10];
      [encoder setBuffer:bandpassHanatosBuffer offset:0 atIndex:11];
      [encoder setBuffer:hanatosRawResponseBuffer offset:0 atIndex:12];
      [encoder setBuffer:mallettBasisIlluminantBuffer offset:0 atIndex:13];
      [encoder setBuffer:inputToReferenceXyzBuffer offset:0 atIndex:14];
      [encoder setBuffer:inputToSrgbBuffer offset:0 atIndex:15];
      [encoder setBuffer:colorInfoBuffer offset:0 atIndex:16];
      [encoder setBuffer:colorDecodeLutBuffer offset:0 atIndex:17];
      [encoder setBuffer:colorTransferKindBuffer offset:0 atIndex:18];
      [encoder setBuffer:dirInfoBuffer offset:0 atIndex:19];
      dispatch2D(impl_->dirBaselinePipeline);

      id<MTLBuffer> blurredDirCorrectionBuffer = encodeDirCorrectionBlur(dirCorrectionBufferA);

      [encoder setComputePipelineState:impl_->dirRedevelopPipeline];
      [encoder setBuffer:dirLogRawBuffer offset:0 atIndex:0];
      [encoder setBuffer:blurredDirCorrectionBuffer offset:0 atIndex:1];
      [encoder setBuffer:dirDensityBufferA offset:0 atIndex:2];
      [encoder setBuffer:paramBuffer offset:0 atIndex:3];
      [encoder setBytes:dims length:sizeof(dims) atIndex:4];
      [encoder setBuffer:curveInfoBuffer offset:0 atIndex:5];
      [encoder setBuffer:logExposureBuffer offset:0 atIndex:6];
      [encoder setBuffer:dirCorrectedDensityCurvesBuffer offset:0 atIndex:7];
      dispatch2D(impl_->dirRedevelopPipeline);

      if (productionGrainPath) {
        encodeProductionGrainLayersFromDensity(dirDensityBufferA);
        encodeSaveGrainBaseDensity(dirDensityBufferA);
      } else if (grainSynthesisPath) {
        encodeSelectedGrainSynthesisLayersFromDensity(dirDensityBufferA);
        encodeSaveGrainBaseDensity(dirDensityBufferA);
      } else if (previewGrainFromDensityPath) {
        [encoder setComputePipelineState:impl_->previewGrainFromDensityPipeline];
        [encoder setBuffer:dirDensityBufferA offset:0 atIndex:0];
        [encoder setBuffer:dirDensityBufferB offset:0 atIndex:1];
        [encoder setBuffer:paramBuffer offset:0 atIndex:2];
        [encoder setBytes:dims length:sizeof(dims) atIndex:3];
        [encoder setBuffer:curveInfoBuffer offset:0 atIndex:4];
        [encoder setBuffer:densityCurvesBuffer offset:0 atIndex:5];
        dispatch2D(impl_->previewGrainFromDensityPipeline);
        encodeFinalFilmDensityOrPrintDiffusion(dirDensityBufferB);
      } else {
        encodeFinalFilmDensityOrPrintDiffusion(dirDensityBufferA);
      }
    }

    if (finalProcessNegative || ((dirPath || preExposurePath) && !productionGrainPath && !grainSynthesisPath)) {
      // Final output was encoded by the precomputed film-density branch.
    } else if (productionGrainPath) {
      if (!dirPath && !preExposurePath) {
        [encoder setComputePipelineState:impl_->halationRawExposurePipeline];
        [encoder setBuffer:renderSourceBuffer offset:0 atIndex:0];
        [encoder setBuffer:grainDensityBufferA offset:0 atIndex:1];
        [encoder setBuffer:paramBuffer offset:0 atIndex:2];
        [encoder setBytes:dims length:sizeof(dims) atIndex:3];
        [encoder setBuffer:spectralInfoBuffer offset:0 atIndex:4];
        [encoder setBuffer:logSensitivityBuffer offset:0 atIndex:5];
        [encoder setBuffer:bandpassHanatosBuffer offset:0 atIndex:6];
        [encoder setBuffer:hanatosRawResponseBuffer offset:0 atIndex:7];
        [encoder setBuffer:mallettBasisIlluminantBuffer offset:0 atIndex:8];
        [encoder setBuffer:inputToReferenceXyzBuffer offset:0 atIndex:9];
        [encoder setBuffer:inputToSrgbBuffer offset:0 atIndex:10];
        [encoder setBuffer:colorInfoBuffer offset:0 atIndex:11];
        [encoder setBuffer:colorDecodeLutBuffer offset:0 atIndex:12];
        [encoder setBuffer:colorTransferKindBuffer offset:0 atIndex:13];
        dispatch2D(impl_->halationRawExposurePipeline);

        encodeDevelopFromRaw(grainDensityBufferA, grainMicroBufferA);

        [encoder setComputePipelineState:impl_->productionGrainLayersFromDensityPipeline];
        [encoder setBuffer:grainMicroBufferA offset:0 atIndex:0];
        [encoder setBuffer:grainLayerBufferA offset:0 atIndex:1];
        [encoder setBuffer:paramBuffer offset:0 atIndex:2];
        [encoder setBytes:dims length:sizeof(dims) atIndex:3];
        [encoder setBuffer:curveInfoBuffer offset:0 atIndex:4];
        [encoder setBuffer:densityCurvesBuffer offset:0 atIndex:5];
        [encoder setBuffer:spectralInfoBuffer offset:0 atIndex:6];
        [encoder setBuffer:paperScanDensityDataBuffer offset:0 atIndex:7];
        dispatch3D(impl_->productionGrainLayersFromDensityPipeline);
        encodeSaveGrainBaseDensity(grainMicroBufferA);
      }

      encodeGrainLayerBlur();
      encodeGrainMicrostructure();

      [encoder setComputePipelineState:impl_->grainResolveDensityPipeline];
      [encoder setBuffer:grainLayerBufferA offset:0 atIndex:0];
      [encoder setBuffer:grainMicroBufferA offset:0 atIndex:1];
      [encoder setBuffer:renderSourceBuffer offset:0 atIndex:2];
      [encoder setBuffer:grainDensityBufferA offset:0 atIndex:3];
      [encoder setBuffer:paramBuffer offset:0 atIndex:4];
      [encoder setBytes:dims length:sizeof(dims) atIndex:5];
      dispatch2D(impl_->grainResolveDensityPipeline);

      encodeFinalFilmDensityOrPrintDiffusion(encodeBlurGrainDensity(grainDensityBufferA));
    } else if (grainSynthesisPath) {
      if (!dirPath && !preExposurePath) {
        [encoder setComputePipelineState:impl_->halationRawExposurePipeline];
        [encoder setBuffer:renderSourceBuffer offset:0 atIndex:0];
        [encoder setBuffer:grainDensityBufferA offset:0 atIndex:1];
        [encoder setBuffer:paramBuffer offset:0 atIndex:2];
        [encoder setBytes:dims length:sizeof(dims) atIndex:3];
        [encoder setBuffer:spectralInfoBuffer offset:0 atIndex:4];
        [encoder setBuffer:logSensitivityBuffer offset:0 atIndex:5];
        [encoder setBuffer:bandpassHanatosBuffer offset:0 atIndex:6];
        [encoder setBuffer:hanatosRawResponseBuffer offset:0 atIndex:7];
        [encoder setBuffer:mallettBasisIlluminantBuffer offset:0 atIndex:8];
        [encoder setBuffer:inputToReferenceXyzBuffer offset:0 atIndex:9];
        [encoder setBuffer:inputToSrgbBuffer offset:0 atIndex:10];
        [encoder setBuffer:colorInfoBuffer offset:0 atIndex:11];
        [encoder setBuffer:colorDecodeLutBuffer offset:0 atIndex:12];
        [encoder setBuffer:colorTransferKindBuffer offset:0 atIndex:13];
        dispatch2D(impl_->halationRawExposurePipeline);

        encodeDevelopFromRaw(grainDensityBufferA, grainDensityBufferB);
        encodeSelectedGrainSynthesisLayersFromDensity(grainDensityBufferB);
        encodeSaveGrainBaseDensity(grainDensityBufferB);
      }

      encodeGrainLayerBlur();
      encodeGrainMicrostructure();

      [encoder setComputePipelineState:impl_->grainSynthesisResolveDensityPipeline];
      [encoder setBuffer:grainLayerBufferA offset:0 atIndex:0];
      [encoder setBuffer:grainMicroBufferA offset:0 atIndex:1];
      [encoder setBuffer:grainSynthesisDensitySource offset:0 atIndex:2];
      [encoder setBuffer:grainDensityBufferA offset:0 atIndex:3];
      [encoder setBuffer:paramBuffer offset:0 atIndex:4];
      [encoder setBytes:dims length:sizeof(dims) atIndex:5];
      dispatch2D(impl_->grainSynthesisResolveDensityPipeline);

      encodeFinalFilmDensityOrPrintDiffusion(encodeBlurGrainDensity(grainDensityBufferA));
    } else {
      [encoder setComputePipelineState:impl_->grainPipeline];
      [encoder setBuffer:renderSourceBuffer offset:0 atIndex:0];
      [encoder setBuffer:dstBuffer offset:0 atIndex:1];
      [encoder setBuffer:paramBuffer offset:0 atIndex:2];
      [encoder setBytes:dims length:sizeof(dims) atIndex:3];
      [encoder setBuffer:curveInfoBuffer offset:0 atIndex:4];
      [encoder setBuffer:logExposureBuffer offset:0 atIndex:5];
      [encoder setBuffer:densityCurvesBuffer offset:0 atIndex:6];
      [encoder setBuffer:spectralInfoBuffer offset:0 atIndex:7];
      [encoder setBuffer:logSensitivityBuffer offset:0 atIndex:8];
      [encoder setBuffer:bandpassHanatosBuffer offset:0 atIndex:9];
      [encoder setBuffer:hanatosRawResponseBuffer offset:0 atIndex:10];
      [encoder setBuffer:mallettBasisIlluminantBuffer offset:0 atIndex:11];
      [encoder setBuffer:inputToReferenceXyzBuffer offset:0 atIndex:12];
      [encoder setBuffer:inputToSrgbBuffer offset:0 atIndex:13];
      [encoder setBuffer:colorInfoBuffer offset:0 atIndex:14];
      [encoder setBuffer:colorDecodeLutBuffer offset:0 atIndex:15];
      [encoder setBuffer:colorTransferKindBuffer offset:0 atIndex:16];
      [encoder setBuffer:paperCurveInfoBuffer offset:0 atIndex:17];
      [encoder setBuffer:paperLogExposureBuffer offset:0 atIndex:18];
      [encoder setBuffer:paperDensityCurvesBuffer offset:0 atIndex:19];
      [encoder setBuffer:filmChannelDensityBuffer offset:0 atIndex:20];
      [encoder setBuffer:filmBaseDensityBuffer offset:0 atIndex:21];
      [encoder setBuffer:paperLogSensitivityBuffer offset:0 atIndex:22];
      [encoder setBuffer:thKg3IlluminantBuffer offset:0 atIndex:23];
      [encoder setBuffer:customEnlargerFiltersBuffer offset:0 atIndex:24];
      [encoder setBuffer:neutralPrintFiltersBuffer offset:0 atIndex:25];
      [encoder setBuffer:academyPrinterDensityDataBuffer offset:0 atIndex:26];
      [encoder setBuffer:paperScanDensityDataBuffer offset:0 atIndex:27];
      [encoder setBuffer:scanIlluminantsAndCmfsBuffer offset:0 atIndex:28];
      [encoder setBuffer:scanToOutputRgbDataBuffer offset:0 atIndex:29];
      [encoder setBuffer:colorEncodeLutBuffer offset:0 atIndex:30];
      dispatch2D(impl_->grainPipeline);
    }
    if (externalMetal && externalMetal->destinationStridedFloat) {
      [encoder setComputePipelineState:impl_->floatToStridedFloatBufferPipeline];
      [encoder setBuffer:dstBuffer offset:0 atIndex:0];
      [encoder setBuffer:externalMetal->destinationBuffer offset:0 atIndex:1];
      [encoder setBytes:&externalMetal->destinationLayout length:sizeof(externalMetal->destinationLayout) atIndex:2];
      dispatch2D(
        impl_->floatToStridedFloatBufferPipeline,
        static_cast<uint64_t>(width) * static_cast<uint64_t>(height) * (sizeof(float) * 8u)
      );
    } else if (externalMetal && externalMetal->destinationStridedHalf) {
      [encoder setComputePipelineState:impl_->floatToStridedHalfBufferPipeline];
      [encoder setBuffer:dstBuffer offset:0 atIndex:0];
      [encoder setBuffer:externalMetal->destinationBuffer offset:0 atIndex:1];
      [encoder setBytes:&externalMetal->destinationLayout length:sizeof(externalMetal->destinationLayout) atIndex:2];
      dispatch2D(
        impl_->floatToStridedHalfBufferPipeline,
        static_cast<uint64_t>(width) * static_cast<uint64_t>(height) * (sizeof(float) * 4u + sizeof(uint16_t) * 4u)
      );
    }
    if (destinationHalfWrappedDirectly) {
      [encoder setComputePipelineState:impl_->floatToHalfBufferPipeline];
      [encoder setBuffer:dstBuffer offset:0 atIndex:0];
      [encoder setBuffer:destinationHalfBuffer offset:0 atIndex:1];
      [encoder setBytes:dims length:sizeof(dims) atIndex:2];
      dispatch2D(
        impl_->floatToHalfBufferPipeline,
        static_cast<uint64_t>(width) * static_cast<uint64_t>(height) * (sizeof(float) * 4u + sizeof(uint16_t) * 4u)
      );
    }
    if (encodeFailed) {
      return false;
    }
    if (useSplitPassTiming) {
      if (encoder) {
        [encoder endEncoding];
      }
      impl_->diagnostics.cpuSetupMs =
        std::max(0.0, elapsedMilliseconds(renderStart, commandEncodingStart) - impl_->diagnostics.sourceCopyMs);
      impl_->diagnostics.commandBufferMs = splitCommandMs;
    } else {
      const auto commandStart = PerfClock::now();
      impl_->diagnostics.commandEncodingMs = elapsedMilliseconds(commandEncodingStart, commandStart);
      impl_->diagnostics.cpuSetupMs = std::max(0.0, elapsedMilliseconds(renderStart, commandStart) - impl_->diagnostics.sourceCopyMs);
      [encoder endEncoding];
      if (externalMetal) {
        impl_->retainScratchResourcesUntilCompleted(commandBuffer);
      }
      [commandBuffer commit];
      if (externalMetal) {
        impl_->diagnostics.commandBufferMs = 0.0;
      } else {
        [commandBuffer waitUntilCompleted];
        impl_->diagnostics.commandBufferMs = elapsedMilliseconds(commandStart, PerfClock::now());
        impl_->diagnostics.gpuCommandBufferMs = impl_->commandBufferGpuMilliseconds(commandBuffer);

        if ([commandBuffer status] == MTLCommandBufferStatusError) {
          NSError *error = [commandBuffer error];
          impl_->lastError = error ? [[error localizedDescription] UTF8String] : "Metal command buffer failed.";
          return false;
        }
      }
    }

    if (passCounterBuffer && impl_->diagnostics.passGpuTimingAvailable) {
      NSData *counterData = [passCounterBuffer resolveCounterRange:NSMakeRange(0, std::min<NSUInteger>(kMaxCounterSamples, impl_->diagnostics.passes.size() * 2u))];
      const auto *timestamps = static_cast<const MTLCounterResultTimestamp *>([counterData bytes]);
      if (timestamps) {
        for (size_t i = 0; i < impl_->diagnostics.passes.size(); ++i) {
          const NSUInteger startIndex = static_cast<NSUInteger>(i) * 2u;
          const NSUInteger endIndex = startIndex + 1u;
          if (endIndex >= kMaxCounterSamples) {
            break;
          }
          const uint64_t start = timestamps[startIndex].timestamp;
          const uint64_t end = timestamps[endIndex].timestamp;
          if (start != MTLCounterErrorValue && end != MTLCounterErrorValue && end >= start) {
            impl_->diagnostics.passes[i].gpuMs = impl_->timestampTicksToMilliseconds(end - start);
            impl_->diagnostics.passes[i].gpuTimeAvailable = true;
          }
        }
      }
    }

    if (!externalMetal && !destinationWrappedDirectly && !destinationHalfWrappedDirectly) {
      const auto outputCopyStart = PerfClock::now();
      copyFloatStagingToDestination(static_cast<const float *>([dstBuffer contents]), destination, window, width, height);
      impl_->diagnostics.outputCopyMs += elapsedMilliseconds(outputCopyStart, PerfClock::now());
    }
  }
  return true;
}

bool MetalRenderer::renderMetalBuffers(
  const MetalBufferImageView &source,
  const MetalBufferImageView &destination,
  const RenderWindow &window,
  const RenderParams &params,
  double time,
  void *commandQueue
) {
  if (!isAvailable()) {
    return false;
  }
  const int32_t width = window.x2 - window.x1;
  const int32_t height = window.y2 - window.y1;
  if (width <= 0 || height <= 0) {
    return true;
  }
  if (!commandQueue) {
    impl_->lastError = "OFX Metal render did not provide a host command queue.";
    return false;
  }

  ExternalMetalBufferContext context{};
  context.active = true;
  context.source = source;
  context.destination = destination;
  context.sourceBuffer = (__bridge id<MTLBuffer>)source.buffer;
  context.destinationBuffer = (__bridge id<MTLBuffer>)destination.buffer;
  context.commandQueue = (__bridge id<MTLCommandQueue>)commandQueue;

  std::string layoutError;
  if (!configureExternalMetalBufferLayout(
        source,
        window,
        width,
        height,
        context.sourceLayout,
        context.sourceCompactFloat,
        context.sourceCompactHalf,
        context.sourceStridedFloat,
        context.sourceStridedHalf,
        layoutError)) {
    impl_->lastError = layoutError;
    return false;
  }
  if (!configureExternalMetalBufferLayout(
        destination,
        window,
        width,
        height,
        context.destinationLayout,
        context.destinationCompactFloat,
        context.destinationCompactHalf,
        context.destinationStridedFloat,
        context.destinationStridedHalf,
        layoutError)) {
    impl_->lastError = layoutError;
    return false;
  }

  ImageView sourceView{};
  sourceView.data = source.buffer;
  sourceView.x1 = source.x1;
  sourceView.y1 = source.y1;
  sourceView.width = source.width;
  sourceView.height = source.height;
  sourceView.rowBytes = source.rowBytes;
  sourceView.components = source.components;
  sourceView.bytesPerComponent = source.bytesPerComponent;

  MutableImageView destinationView{};
  destinationView.data = destination.buffer;
  destinationView.x1 = destination.x1;
  destinationView.y1 = destination.y1;
  destinationView.width = destination.width;
  destinationView.height = destination.height;
  destinationView.rowBytes = destination.rowBytes;
  destinationView.components = destination.components;
  destinationView.bytesPerComponent = destination.bytesPerComponent;

  gExternalMetalBufferContext = &context;
  const bool ok = render(sourceView, destinationView, window, params, time);
  gExternalMetalBufferContext = nullptr;
  return ok;
}

} // namespace spektrafilm
