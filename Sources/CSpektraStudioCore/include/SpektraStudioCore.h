#pragma once
#include <stdint.h>
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
uint32_t sf_core_abi_version(void);
uint64_t sf_core_capabilities(void);
int32_t sf_core_lc_controls_json(uint8_t*,size_t);
int32_t sf_core_lc_default_settings_json(uint8_t*,size_t);
int32_t sf_core_lc_set_control_json(const char*,const char*,double,uint8_t*,size_t);
int32_t sf_core_spektra_feature_manifest_json(uint8_t*,size_t);
#ifdef __cplusplus
}
#endif
