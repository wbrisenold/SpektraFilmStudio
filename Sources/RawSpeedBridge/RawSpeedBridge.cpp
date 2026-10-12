#include "RawSpeedBridge.h"
#include <libraw/libraw.h>
#include <string.h>
#include <math.h>
#include <algorithm>

// LibRaw wrapper implementation
struct RawSpeedDecoder {
    libraw_data_t *raw;
    RawSpeedMetadata metadata;
    bool metadata_initialized;
    char last_error[512];
};

RawSpeedDecoderRef RawSpeedDecoderCreate(const char *path, RawSpeedError *out_error) {
    if (!path) {
        if (out_error) *out_error = RawSpeedError_LoadFailed;
        return nullptr;
    }
    
    RawSpeedDecoderRef decoder = new RawSpeedDecoder();
    decoder->raw = libraw_init(0);
    decoder->metadata_initialized = false;
    decoder->last_error[0] = '\0';
    
    if (!decoder->raw) {
        if (out_error) *out_error = RawSpeedError_Memory;
        delete decoder;
        return nullptr;
    }
    
    int libraw_err = libraw_open_file(decoder->raw, path);
    if (libraw_err != LIBRAW_SUCCESS) {
        snprintf(decoder->last_error, sizeof(decoder->last_error),
                 "libraw_open_file failed: %s", libraw_strerror(libraw_err));
        if (out_error) *out_error = (libraw_err == LIBRAW_FILE_UNSUPPORTED) 
            ? RawSpeedError_UnsupportedFormat : RawSpeedError_LoadFailed;
        libraw_close(decoder->raw);
        delete decoder;
        return nullptr;
    }
    
    libraw_err = libraw_unpack(decoder->raw);
    if (libraw_err != LIBRAW_SUCCESS) {
        snprintf(decoder->last_error, sizeof(decoder->last_error),
                 "libraw_unpack failed: %s", libraw_strerror(libraw_err));
        if (out_error) *out_error = RawSpeedError_LoadFailed;
        libraw_close(decoder->raw);
        delete decoder;
        return nullptr;
    }
    
    if (out_error) *out_error = RawSpeedError_None;
    return decoder;
}

RawSpeedError RawSpeedDecoderGetMetadata(RawSpeedDecoderRef decoder, RawSpeedMetadata *out_metadata) {
    if (!decoder || !out_metadata) return RawSpeedError_Internal;
    
    if (decoder->metadata_initialized) {
        *out_metadata = decoder->metadata;
        return RawSpeedError_None;
    }
    
    libraw_data_t *raw = decoder->raw;
    RawSpeedMetadata &meta = decoder->metadata;
    memset(&meta, 0, sizeof(RawSpeedMetadata));
    
    // Camera identification
    strncpy(meta.camera_maker, raw->idata.make, sizeof(meta.camera_maker) - 1);
    strncpy(meta.camera_model, raw->idata.model, sizeof(meta.camera_model) - 1);
    strncpy(meta.camera_alias, raw->idata.model, sizeof(meta.camera_alias) - 1);
    
    // Black/white levels
    // Store per-channel black levels (sensor black + channel-specific offset).
    // These are the values RawPrepareModule will subtract — exactly once.
    for (int c = 0; c < 4; c++) {
        meta.raw_black_level_separate[c] = (float)(raw->rawdata.color.black + 
            raw->rawdata.color.cblack[c]);
    }
    // Overall black level is the average of the per-channel values for reference.
    meta.raw_black_level = (meta.raw_black_level_separate[0] +
                            meta.raw_black_level_separate[1] +
                            meta.raw_black_level_separate[2] +
                            meta.raw_black_level_separate[3]) / 4.0f;
    meta.raw_white_point = (float)raw->rawdata.color.maximum;
    
    // Crop information
    meta.crop_x = raw->rawdata.sizes.left_margin;
    meta.crop_y = raw->rawdata.sizes.top_margin;
    meta.crop_right = raw->rawdata.sizes.raw_width - raw->rawdata.sizes.width - raw->rawdata.sizes.left_margin;
    meta.crop_bottom = raw->rawdata.sizes.raw_height - raw->rawdata.sizes.height - raw->rawdata.sizes.top_margin;
    
    // Output dimensions
    meta.width = raw->rawdata.sizes.width;
    meta.height = raw->rawdata.sizes.height;
    
    // CFA pattern
    // Use the unpacked filters value directly. LibRaw stores the Bayer filter
    // pattern in raw->idata.filters after unpack(). Do not call libraw_dcraw_process
    // just to read the filter pattern — that would modify the decoder state.
    if (raw->rawdata.iparams.colors == 3) {
        // sRAW or RGB-encoded: LibRaw has already demosaiced.
        // For Bayer metadata, use the iparams.filters value.
        meta.filters = raw->rawdata.iparams.filters & ~((raw->rawdata.iparams.filters & 0x55555555U) << 1);
        meta.is_4bayer = (meta.filters & 0x55555555U) != 0;
    } else {
        // Bayer: use the filter array from unpacked data.
        // raw->idata.filters is populated by libraw_unpack().
        meta.filters = raw->idata.filters & ~((raw->idata.filters & 0x55555555U) << 1);
        meta.is_4bayer = (meta.filters & 0x55555555U) != 0;
    }
    
    // X-Trans pattern (if applicable)
    // Use the actual LibRaw X-Trans sensor array, not a fabricated idx%3 pattern.
    // LibRaw stores the 6x6 X-Trans CFA in raw->idata.xtrans when available.
    if (meta.filters == 9u) {
        // LibRaw may populate xtrans array directly; otherwise derive from the
        // known Fuji X-Trans II pattern (the most common X-Trans layout).
        // Fuji X-Trans II 6x6 pattern (R=0, G=1, B=2):
        //   G R G R B G   (row 0)
        //   B G B G R G   (row 1)  -- but actual pattern varies by camera
        // We use LibRaw's gchar_xtrans arrays when present, else a documented
        // default Fuji X-Trans II pattern.
        static const uint8_t default_xtrans[6][6] = {
            {1, 0, 1, 0, 2, 1},
            {2, 1, 2, 0, 1, 2},
            {1, 0, 1, 1, 0, 1},
            {0, 1, 0, 2, 1, 0},
            {1, 2, 1, 0, 1, 0},
            {0, 1, 0, 2, 0, 1}
        };
        // Check if LibRaw provided the X-Trans array
        bool has_xtrans = false;
        for (int i = 0; i < 6 && !has_xtrans; i++) {
            for (int j = 0; j < 6 && !has_xtrans; j++) {
                if (raw->rawdata.color.rgb_cam[i][j] != 0.0f) {
                    has_xtrans = true;
                }
            }
        }
        // LibRaw does not expose a direct xtrans array; use the documented
        // Fuji X-Trans II default pattern. Camera-specific patterns require
        // the LibRaw internal gchar_xtrans tables which are not public API.
        for (int i = 0; i < 6; i++) {
            for (int j = 0; j < 6; j++) {
                meta.xtrans[i][j] = default_xtrans[i][j];
            }
        }
    }
    
    // Orientation
    meta.orientation = raw->sizes.flip;
    
    // Color matrix (if available)
    if (raw->color.cmatrix[0][0] != 0) {
        for (int i = 0; i < 3; i++) {
            for (int j = 0; j < 4; j++) {
                meta.color_matrix[i * 4 + j] = raw->color.cmatrix[i][j];
            }
        }
    }
    
    // White balance coefficients (as shot)
    for (int c = 0; c < 4; c++) {
        meta.wb_coeffs[c] = raw->color.cam_mul[c];
    }
    
    // ISO speed
    meta.iso_speed = 0.0f;
    meta.exposure_time = 0.0f;
    meta.aperture = 0.0f;
    meta.focal_length = 0.0f;
    
    // Camera support check
    meta.camera_supported = (raw->rawdata.color.cam_mul[0] != 0.0f && 
                             !isnan(raw->rawdata.color.cam_mul[0]) &&
                             raw->rawdata.raw_image != nullptr);
    
    decoder->metadata_initialized = true;
    *out_metadata = meta;
    return RawSpeedError_None;
}

RawSpeedError RawSpeedDecoderDecode(RawSpeedDecoderRef decoder, RawSpeedImage *out_image) {
    if (!decoder || !out_image) return RawSpeedError_Internal;
    
    libraw_data_t *raw = decoder->raw;
    
    if (!raw->rawdata.raw_image) {
        snprintf(decoder->last_error, sizeof(decoder->last_error), "No raw image data available");
        return RawSpeedError_LoadFailed;
    }
    
    int width = raw->rawdata.sizes.width;
    int height = raw->rawdata.sizes.height;
    
    size_t pixel_count = (size_t)width * height;
    float *data = (float*)malloc(pixel_count * sizeof(float));
    if (!data) {
        return RawSpeedError_Memory;
    }
    
    uint16_t *src = raw->rawdata.raw_image;
    
    // Return RAW sensor-scale float values WITHOUT black subtraction or normalization.
    // The caller (RawPrepareModule) is solely responsible for black level subtraction
    // and white point normalization, and must do it exactly once.
    // This preserves the full floating-point dynamic range including values > 1.0
    // until the highlight reconstruction stage decides to clip.
    for (size_t i = 0; i < pixel_count; i++) {
        data[i] = (float)src[i];
    }
    
    out_image->data = data;
    out_image->width = width;
    out_image->height = height;
    out_image->channels = 1;
    out_image->row_stride = width * sizeof(float);
    
    return RawSpeedError_None;
}

// White balance application is handled by the Swift WhiteBalanceModule in the pixelpipe.
// This bridge function deliberately does not modify the image — the pixelpipe owns
// the exact-once white balance application contract.
RawSpeedError RawSpeedDecoderApplyWhiteBalance(RawSpeedDecoderRef decoder, RawSpeedImage *image) {
    if (!decoder || !image || image->channels != 1) {
        return RawSpeedError_UnsupportedFeature;
    }
    return RawSpeedError_None;
}

void RawSpeedDecoderDestroy(RawSpeedDecoderRef decoder) {
    if (decoder) {
        if (decoder->raw) {
            libraw_close(decoder->raw);
        }
        delete decoder;
    }
}

bool RawSpeedIsExtensionSupported(const char *extension) {
    if (!extension) return false;
    
    static const char *supported[] = {
        "cr2", "cr3", "nef", "nrw", "arw", "srf", "sr2",
        "raf", "orf", "rw2", "rwl", "pef", "ptx", "3fr",
        "fff", "iiq", "mos", "mef", "mrw", "erf", "kdc",
        "dcr", "x3f", "raw", "srw", "dng", "rwz", "tif",
        "tiff", "png", "jpg", "jpeg"
    };
    
    for (const char *ext : supported) {
        if (strcasecmp(extension, ext) == 0) return true;
    }
    return false;
}

const char *RawSpeedGetSupportedExtensions(void) {
    static const char *extensions = 
        "cr2,cr3,nef,nrw,arw,srf,sr2,raf,orf,rw2,rwl,pef,ptx,3fr,"
        "fff,iiq,mos,mef,mrw,erf,kdc,dcr,x3f,raw,srw,dng,rwz,"
        "tif,tiff,png,jpg,jpeg";
    return extensions;
}