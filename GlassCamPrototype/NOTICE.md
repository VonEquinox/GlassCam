# Provenance and distribution boundary

HNCS reference source and numerical assets originate from the user's private repository `VonEquinox/GlassCam`, branch `hncs-technical-delivery-20261011`, commit `c3595d776fe07ceda4c06793618bbe7456e02f04`, under `HNCS技术交付/`.

Original color implementation: `hncs_pipeline.py` (colour path revision 2, render path revision 6). Independent original implementation: `tools/reference_color_core.py`. Asset provenance: `work/hncs-pipeline/assets/provenance.json`. NPZ SHA256: `3291628ef8787a20082eaebb7e50fccac0a89bbce14dc5619ecf1277d816c1b9`.

The new portable C++ implementation is derived from these sources and uses a lossless generated representation of supplied numeric tables. Source order, quantization and domain semantics are retained deliberately. Original code/assets stay available on the parent branch and are not replaced.

The supplied provenance identifies recovered Phocus 4.2.2 data. No blanket license or proof of commercial redistribution rights for these factory data was supplied. Permission to work in the private repository is not a finding that App Store distribution is cleared. Do not publish the factory data in a public repository or commercial application without rights review. No licensing statement in this prototype grants rights to Hasselblad/Phocus materials. The unrelated license elsewhere in the technical delivery must not be treated as licensing these tables.

Only user-authorized private repository development is performed here. This prototype is not affiliated with or endorsed by Hasselblad or Apple.
