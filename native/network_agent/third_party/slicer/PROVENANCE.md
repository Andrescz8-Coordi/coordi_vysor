# slicer (vendored)

Origin: AOSP `platform/tools/dexter`, subdir `slicer/`
https://android.googlesource.com/platform/tools/dexter

Commit: d992a222ec28b56efa29f9104db060379298049c

License: Apache 2.0 (per-file headers preserved).

Vendored files: `*.cc` + `export/slicer/*.h`. Build requires RTTI and
exceptions enabled (uses `dynamic_cast` and `throw`) and links against zlib
(`-lz`, for the DEX Adler-32 checksum). Do NOT compile these with
`-fno-rtti` / `-fno-exceptions`.

Used by `../../src/dex_instrument.cpp` to rewrite Volley/okhttp class DEX in
the JVMTI `ClassFileLoadHook` — the capture path for Samsung One UI, where
MethodEntry/MethodExit tracing is unreliable but RetransformClasses works.
