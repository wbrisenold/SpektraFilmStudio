#pragma once
#include <stdint.h>
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
uint32_t sf_core_abi_version(void);
uint64_t sf_core_capabilities(void);
int32_t sf_core_pc_select_subject_rgba8(const uint8_t*,uint32_t,uint32_t,uint8_t*);
int32_t sf_core_pc_quick_select_rgba8(const uint8_t*,uint32_t,uint32_t,const float*,uint32_t,float,uint8_t*);
int32_t sf_core_pc_magic_wand_rgba8(const uint8_t*,uint32_t,uint32_t,int32_t,int32_t,float,uint8_t*);
int32_t sf_core_pc_feather_mask_u8(const uint8_t*,uint32_t,uint32_t,float,uint8_t*);
int32_t sf_core_lc_controls_json(uint8_t*,size_t);
int32_t sf_core_lc_default_settings_json(uint8_t*,size_t);
int32_t sf_core_lc_set_control_json(const char*,const char*,double,uint8_t*,size_t);
int32_t sf_core_spektra_feature_manifest_json(uint8_t*,size_t);
#ifdef __cplusplus
}
#endif
