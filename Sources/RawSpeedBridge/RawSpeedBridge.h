#pragma once
#include <stdint.h>
#include <stdbool.h>
#ifdef __cplusplus
extern "C" {
#endif

// RawSpeed error codes
typedef enum RawSpeedError {
    RawSpeedError_None = 0,
    RawSpeedError_UnsupportedFormat = 1,
    RawSpeedError_LoadFailed = 2,
    RawSpeedError_UnsupportedFeature = 3,
    RawSpeedError_FileCorrupted = 4,
    RawSpeedError_Memory = 5,
    RawSpeedError_CameraNotSupported = 6,
    RawSpeedError_Internal = 7
} RawSpeedError;

// RAW image metadata
typedef struct RawSpeedMetadata {
    // Camera identification
    char camera_maker[64];
    char camera_model[64];
    char camera_alias[64];
    
    // Black/white levels
    float raw_black_level;
    float raw_white_point;
    float raw_black_level_separate[4];
    
    // Crop information (optically black areas removed)
    int32_t crop_x;
    int32_t crop_y;
    int32_t crop_right;
    int32_t crop_bottom;
    
    // Image dimensions (after crop)
    int32_t width;
    int32_t height;
    
    // CFA pattern (dcraw format)
    uint32_t filters;
    
    // For X-Trans sensors
    uint8_t xtrans[6][6];
    
    // Orientation (EXIF)
    int32_t orientation;
    
    // Color matrix (3x4, from camera database)
    float color_matrix[12];
    
    // White balance coefficients (as shot)
    float wb_coeffs[4];
    
    // ISO speed
    float iso_speed;
    
    // Exposure time
    float exposure_time;
    
    // Aperture
    float aperture;
    
    // Focal length
    float focal_length;
    
    // Whether this is a 4-channel Bayer (RGGB vs RGBG etc)
    bool is_4bayer;
    
    // Whether the camera is supported with samples
    bool camera_supported;
    
    // Error message (if any)
    char error_message[512];
} RawSpeedMetadata;

// RAW image buffer (linear, scene-referred, camera RGB)
typedef struct RawSpeedImage {
    // Single channel for Bayer (raw values), 3-4 channels for sRAW
    float *data;
    int32_t width;
    int32_t height;
    int32_t channels;  // 1 for Bayer, 3-4 for sRAW
    int32_t row_stride;
} RawSpeedImage;

// Opaque decoder handle
typedef struct RawSpeedDecoder *RawSpeedDecoderRef;

// Create a decoder for a file
RawSpeedDecoderRef RawSpeedDecoderCreate(const char *path, RawSpeedError *out_error);

// Get metadata without fully decoding
RawSpeedError RawSpeedDecoderGetMetadata(RawSpeedDecoderRef decoder, RawSpeedMetadata *out_metadata);

// Decode RAW to linear float buffer (camera RGB space)
// The output buffer must be pre-allocated with sufficient size
// For Bayer: width * height * sizeof(float)
// For sRAW: width * height * channels * sizeof(float)
RawSpeedError RawSpeedDecoderDecode(RawSpeedDecoderRef decoder, RawSpeedImage *out_image);

// Apply camera-space white balance (multiplies channels by wb_coeffs)
// This modifies the image buffer in place
RawSpeedError RawSpeedDecoderApplyWhiteBalance(RawSpeedDecoderRef decoder, RawSpeedImage *image);

// Destroy decoder and free resources
void RawSpeedDecoderDestroy(RawSpeedDecoderRef decoder);

// Check if a file extension is supported by RawSpeed
bool RawSpeedIsExtensionSupported(const char *extension);

// Get the list of supported extensions (comma-separated)
const char *RawSpeedGetSupportedExtensions(void);

#ifdef __cplusplus
}
#endif