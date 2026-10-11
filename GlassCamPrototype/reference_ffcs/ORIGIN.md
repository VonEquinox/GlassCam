# Original FFCS source and asset materialization

Source: user-supplied `FFCS_技术实现完整交付.zip` on private `VonEquinox/GlassCam`, branch `ffcs-technical-delivery-20261011`, commit `3c0a85eeb3893764ae92fc0fe52ebb62fd9f6ac5`.

- Archive Git blob: `ecc0ebc69b94d10f8b3f63cac5659d58886efeea`
- Size: 82,996,719 bytes
- SHA256: `bc8c9b4d7691f3ecef03a79e3b1a7ddd8364647e97877ee02ceefa8e50e2ea02`

`source.zip` references that existing Git object; it is an ordinary Git ZIP, not an LFS pointer. No binary archive was invented or re-packed. The original research branch remains unchanged. All 92 delivered files, all 48 LUTs and both ICCs were checked against the original manifest after download.

Readable source, tests, examples, documents and numerical evidence are retained unmodified here. To materialize all original binary assets and the mobile subset, run from the prototype root:

```sh
python tools/materialize_ffcs_reference.py
```

The iOS build phase independently verifies the archive SHA256, extracts only the 19 XH2S `.lutz` files with fixed path flattening, verifies all 19 per-file SHA256 values, and bundles those original resources. It does not need Python, a package manager or network access. The generated resource folder is ignored by Git; the full pinned archive is tracked.

REALA ACE is absent from the supplied XH2S reference tables and is not exposed as a table-backed mobile look. The preserved Python reference retains its analytic fallback for original reproduction tests; the mobile C++ renderer never silently selects it. Supplied RAW development and other camera families are retained for research, not claimed as implemented mobile RAW decoders.

Reproducing this research pipeline is not proof of exact Fujifilm camera JPEG rendering. The original documents disclose approximations and measured residuals. Factory/vendor data rights still require review before public/App Store distribution; this private development copy grants no new rights.
