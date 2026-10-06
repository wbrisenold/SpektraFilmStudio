#pragma once
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

typedef enum SFSemanticProfile { SF_SEMANTIC_FACE19=1, SF_SEMANTIC_SCHP_LIP20=2, SF_SEMANTIC_MODNET=3 } SFSemanticProfile;
int sf_semantic_labels_run(const char *model_path,int profile,const uint8_t *rgba,int width,int height,uint8_t *out_labels,char *error_buffer,int error_buffer_size);
int sf_semantic_matte_run(const char *model_path,const uint8_t *rgba,int width,int height,uint8_t *out_alpha,char *error_buffer,int error_buffer_size);
const char *sf_semantic_runtime_version(void);
#ifdef __cplusplus
}
#endif
