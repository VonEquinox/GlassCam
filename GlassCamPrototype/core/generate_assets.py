#!/usr/bin/env python3
"""Export original numerical arrays as lossless C++ literals; no fitted 3-D LUT."""
from pathlib import Path
import numpy as np
import hashlib
root=Path(__file__).resolve().parents[1]
reference=root/'reference'
if not reference.exists(): reference=root.parent/'HNCS技术交付'
source=reference/'work/hncs-pipeline/assets/x2dii_phocus_422.npz'
a=np.load(source,allow_pickle=False)
keys=['matrix_temperatures','camera_to_xyz','wb_temperatures','grid','xyz_to_legacy_rgb','legacy_rgb_to_xyz','rgb_to_ycbcr','gray_thresholds','shadow_desaturation','legacy_icc_gamma','lut_std','v1_gamma','working_rgb_to_xyz','lut_expansion','lut_repro','v1_lstar','pure_lstar','pure_gamma']
with (root/'core/hncs_assets.inc').open('w') as f:
 f.write('// Generated from original x2dii_phocus_422.npz. Do not edit.\n')
 f.write('// Source SHA-256: '+hashlib.sha256(source.read_bytes()).hexdigest()+'\nnamespace assets {\n')
 for k in keys:
  v=a[k].flatten(); typ='std::uint16_t' if k in ('v1_gamma','v1_lstar','pure_lstar','pure_gamma') else 'double'
  f.write(f'static constexpr {typ} {k}[{v.size}] = {{\n')
  for i in range(0,v.size,12):f.write(','.join(str(int(x)) if typ!='double' else repr(float(x)) for x in v[i:i+12])+',\n')
  f.write('};\n')
 f.write('}\n')
