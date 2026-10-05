#pragma once

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct SpektraRendererHandle *SpektraRendererRef;

typedef enum SpektraAppFlavor {
  SpektraAppFlavorFlow = 0,
  SpektraAppFlavorPro = 1,
  SpektraAppFlavorDev = 2,
} SpektraAppFlavor;

typedef enum SpektraAppParamKind {
  SpektraAppParamKindInt = 0,
  SpektraAppParamKindBool = 1,
  SpektraAppParamKindDouble = 2,
  SpektraAppParamKindDouble2 = 3,
  SpektraAppParamKindDouble3 = 4,
  SpektraAppParamKindChoice = 5,
  SpektraAppParamKindFilmStock = 6,
  SpektraAppParamKindPrintPaper = 7,
} SpektraAppParamKind;

typedef enum SpektraAppVisibilityTier {
  SpektraAppVisibilityTierFlow = 0,
  SpektraAppVisibilityTierPro = 1,
  SpektraAppVisibilityTierDev = 2,
} SpektraAppVisibilityTier;

typedef struct SpektraImageBuffer {
  void *data;
  int32_t width;
  int32_t height;
  int32_t rowBytes;
  int32_t components;
  int32_t bytesPerComponent;
} SpektraImageBuffer;

typedef struct SpektraAppDiagnostics {
  double cpuSetupMs;
  double sourceCopyMs;
  double commandBufferMs;
  double outputCopyMs;
  uint64_t staticAllocationBytes;
  uint64_t scratchAllocationBytes;
  uint64_t uploadBytes;
  uint32_t passCount;
  int32_t sourceNoCopy;
  int32_t destinationNoCopy;
  int32_t halationPath;
  int32_t cameraDiffusionPath;
  int32_t printDiffusionPath;
  int32_t dirPath;
  int32_t productionGrainPath;
  int32_t grainSynthesisPath;
  int32_t finalPostProcessPath;
} SpektraAppDiagnostics;

typedef struct SpektraAppRenderParams {
  int32_t process;
  int32_t renderOutput;
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
  int32_t colorAdaptation;
  int32_t colorAdaptationInputCompression;
  int32_t colorAdaptationCurveSmoothing;
  int32_t colorAdaptationOutputLightnessCompression;
  int32_t colorAdaptationOutputChromaCompression;
  int32_t film;
  int32_t paper;
  int32_t printTiming;

  int32_t cameraUvFilterEnabled;
  float cameraUvCutNm;
  int32_t cameraIrFilterEnabled;
  float cameraIrCutNm;

  float filmExposureEv;
  int32_t autoExposure;
  int32_t autoExposureMethod;
  float printExposureEv;
  int32_t filmPushPullMode;
  float filmPushPullStops;
  float printPushPullStops;
  float negativeBleachBypassAmount;
  float negativeLeucoCyanCoupling;
  float printBleachBypassAmount;
  float filmGamma;
  float printGamma;
  float printShadowShape;
  float printHighlightShape;

  float filterC;
  float filterMShift;
  float filterYShift;
  float enlargerScale;
  float enlargerOffsetXPercent;
  float enlargerOffsetYPercent;
  float preflashExposure;
  float preflashMFilterShift;
  float preflashYFilterShift;
  float printerLightsR;
  float printerLightsG;
  float printerLightsB;
  int32_t printerLightsGang;
  int32_t printerLightCalibration;

  float dirCouplersAmount;
  float dirCouplersDiffusionUm;
  float dirCouplersDiffusionTailUm;
  float dirCouplersDiffusionTailWeight;
  float dirCouplersInhibitionSameLayer;
  float dirCouplersInhibitionInterlayer;
  float dirCouplersGammaSameLayerR;
  float dirCouplersGammaSameLayerG;
  float dirCouplersGammaSameLayerB;
  float dirCouplersGammaRToG;
  float dirCouplersGammaRToB;
  float dirCouplersGammaGToR;
  float dirCouplersGammaGToB;
  float dirCouplersGammaBToR;
  float dirCouplersGammaBToG;

  int32_t grainEnabled;
  int32_t grainModel;
  int32_t filmFormat;
  float grainAmount;
  float grainSaturation;
  int32_t grainSublayersEnabled;
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
  int32_t grainAnimate;
  float grainSynthesisSize;
  float grainSynthesisAmount;
  float grainSynthesisSharpness;
  float grainSynthesisQuality;
  int32_t grainSynthesisSamples;
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
  int32_t grainSynthesisLayered;

  int32_t halationEnabled;
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

  int32_t cameraDiffusionEnabled;
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

  int32_t printDiffusionEnabled;
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

  int32_t scannerEnabled;
  int32_t scannerWhiteCorrection;
  int32_t scannerBlackCorrection;
  float scannerWhiteLevel;
  float scannerBlackLevel;
  float glarePercent;
  float glareRoughness;
  float glareBlur;
  float scannerMtf50LpMm;
  float scannerUnsharpRadiusUm;
  float scannerUnsharpAmount;
  int32_t scanNegativeInvert;
} SpektraAppRenderParams;

typedef struct SpektraAppGroupDescriptor {
  const char *id;
  const char *label;
} SpektraAppGroupDescriptor;

typedef struct SpektraAppParamDescriptor {
  const char *name;
  const char *label;
  const char *group;
  const char *optionSet;
  int32_t kind;
  int32_t visibilityTier;
  int32_t defaultInt;
  double defaultValue[3];
  double minimum;
  double maximum;
} SpektraAppParamDescriptor;

SpektraRendererRef SpektraRendererCreate(void);
void SpektraRendererDestroy(SpektraRendererRef renderer);
int32_t SpektraRendererIsAvailable(SpektraRendererRef renderer);
const char *SpektraRendererLastError(SpektraRendererRef renderer);
SpektraAppDiagnostics SpektraRendererLastDiagnostics(SpektraRendererRef renderer);
int32_t SpektraRendererRender(
  SpektraRendererRef renderer,
  const SpektraImageBuffer *source,
  SpektraImageBuffer *destination,
  const SpektraAppRenderParams *params,
  double time
);

SpektraAppRenderParams SpektraAppMakeDefaultRenderParams(void);
int32_t SpektraAppSetIntParam(SpektraAppRenderParams *params, const char *name, int32_t value);
int32_t SpektraAppSetBoolParam(SpektraAppRenderParams *params, const char *name, int32_t value);
int32_t SpektraAppSetDoubleParam(SpektraAppRenderParams *params, const char *name, double value);
int32_t SpektraAppSetDouble3Param(SpektraAppRenderParams *params, const char *name, double x, double y, double z);

uint32_t SpektraAppGroupCount(void);
const SpektraAppGroupDescriptor *SpektraAppGroupAt(uint32_t index);
uint32_t SpektraAppParamCount(void);
const SpektraAppParamDescriptor *SpektraAppParamAt(uint32_t index);
int32_t SpektraAppParamVisibleInFlavor(const SpektraAppParamDescriptor *descriptor, int32_t flavor);
uint32_t SpektraAppOptionCount(const char *optionSet);
const char *SpektraAppOptionLabel(const char *optionSet, uint32_t index);
int32_t SpektraAppLinearRec2020ColorSpace(void);
int32_t SpektraAppLinearRec709ColorSpace(void);
int32_t SpektraAppLinearP3D65ColorSpace(void);
int32_t SpektraAppSrgbColorSpace(void);
int32_t SpektraAppDisplayP3ColorSpace(void);

uint32_t SpektraAppFilmCount(void);
const char *SpektraAppFilmName(uint32_t index);
uint32_t SpektraAppPaperCount(void);
const char *SpektraAppPaperName(uint32_t index);

#ifdef __cplusplus
}
#endif
