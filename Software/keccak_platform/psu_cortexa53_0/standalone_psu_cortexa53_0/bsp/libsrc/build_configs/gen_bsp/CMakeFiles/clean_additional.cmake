# Additional clean files
cmake_minimum_required(VERSION 3.16)

if("${CONFIG}" STREQUAL "" OR "${CONFIG}" STREQUAL "")
  file(REMOVE_RECURSE
  "/run/media/quan/Samsung/01_HocTap_NghienCuu/ML-KEM_FULL/keccak-mlkem/Software/keccak_platform/psu_cortexa53_0/standalone_psu_cortexa53_0/bsp/include/sleep.h"
  "/run/media/quan/Samsung/01_HocTap_NghienCuu/ML-KEM_FULL/keccak-mlkem/Software/keccak_platform/psu_cortexa53_0/standalone_psu_cortexa53_0/bsp/include/xiltimer.h"
  "/run/media/quan/Samsung/01_HocTap_NghienCuu/ML-KEM_FULL/keccak-mlkem/Software/keccak_platform/psu_cortexa53_0/standalone_psu_cortexa53_0/bsp/include/xtimer_config.h"
  "/run/media/quan/Samsung/01_HocTap_NghienCuu/ML-KEM_FULL/keccak-mlkem/Software/keccak_platform/psu_cortexa53_0/standalone_psu_cortexa53_0/bsp/lib/libxiltimer.a"
  )
endif()
