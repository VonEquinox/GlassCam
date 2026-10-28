"""Build an isolated Adobe DNG SDK 1.7.1 color oracle; never link it into the app."""
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import argparse
import hashlib
import json
import os
import shutil
import subprocess
import urllib.request
import zipfile

URL = "https://download.adobe.com/pub/adobe/dng/dng_sdk_1_7_1.zip"
SHA = "5366d9abd0e623858573bfaf0291b5e352d704f51b322753a22f82af3ae6e0c2"
ROOT = Path(__file__).resolve().parents[1]


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--cache", type=Path, default=Path("/tmp/GlassCam-F5-SDK"))
    ap.add_argument("--sdk-zip", type=Path)
    ap.add_argument("--cmake", default=shutil.which("cmake"))
    ap.add_argument("--jobs", type=int, default=4)
    args = ap.parse_args()
    if not args.cmake:
        ap.error("Supply --cmake with an installed CMake executable.")
    work = args.cache.resolve(); work.mkdir(parents=True, exist_ok=True)
    archive = args.sdk_zip or work / "dng_sdk_1_7_1.zip"
    if not archive.exists():
        urllib.request.urlretrieve(URL, archive)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != SHA:
        raise SystemExit("The Adobe SDK archive checksum does not match the pinned release.")
    with zipfile.ZipFile(archive) as z:
        for entry in z.infolist():
            relative = Path(entry.filename)
            if relative.is_absolute() or ".." in relative.parts:
                raise SystemExit("Unsafe SDK archive path")
            if entry.filename.startswith(("dng_sdk_1_7_1/dng_sdk/source/", "dng_sdk_1_7_1/libjxl/")):
                z.extract(entry, work)
    source = work / "dng_sdk_1_7_1/dng_sdk/source"
    jxl = work / "dng_sdk_1_7_1/libjxl/libjxl"
    build = work / "jxl-build"; objects = work / "objects"; objects.mkdir(exist_ok=True)
    env = dict(os.environ, DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer")

    def run(name, command):
        with (work / f"{name}.log").open("w") as log:
            result = subprocess.run(list(map(str, command)), stdout=log, stderr=subprocess.STDOUT, env=env)
        if result.returncode:
            raise RuntimeError(f"{name}: " + (work / f"{name}.log").read_text()[-4000:])

    run("configure", [args.cmake, "-S", jxl, "-B", build, "-DCMAKE_BUILD_TYPE=Release", "-DCMAKE_POLICY_VERSION_MINIMUM=3.5",
        "-DBUILD_TESTING=OFF", "-DBUILD_SHARED_LIBS=OFF", "-DJPEGXL_ENABLE_TOOLS=OFF", "-DJPEGXL_ENABLE_DOXYGEN=OFF",
        "-DJPEGXL_ENABLE_MANPAGES=OFF", "-DJPEGXL_ENABLE_BENCHMARK=OFF", "-DJPEGXL_ENABLE_EXAMPLES=OFF",
        "-DJPEGXL_ENABLE_JPEGLI=OFF", "-DJPEGXL_ENABLE_SJPEG=OFF", "-DJPEGXL_ENABLE_SKCMS=ON"])
    run("codecs", [args.cmake, "--build", build, "-j", str(max(1, min(args.jobs, 8))), "--target", "jxl-static", "jxl_threads-static"])

    # SDK 1.7.1's JXL file has two unguarded XMP-only branches. Disable these
    # branches for its documented qDNGUseXMP=0 build. Color code is untouched.
    text = (source / "dng_jxl.cpp").read_text()
    starts = [text.index("if (includeXMP && metadata->GetXMP ())"), text.rfind("if (fInfo)", 0, text.index("dng_xmp xmp"))]
    for start in sorted(starts, reverse=True):
        end = text.index("{", start) + 1; depth = 1
        while depth:
            depth += (text[end] == "{") - (text[end] == "}"); end += 1
        text = text[:start] + "\n#if qDNGUseXMP\n" + text[start:end] + "\n#endif\n" + text[end:]
    patched = work / "dng_jxl_no_xmp.cpp"; patched.write_text(text)
    flags = ["-std=c++17", "-O2", "-DqMacOS=1", "-DqDNGUseXMP=0", "-DqDNGXMPFiles=0", "-DqDNGXMPDocOps=0",
        "-DqDNGUseLibJPEG=0", "-DqDNGSupportVC5=0", "-I", source, "-I", jxl / "lib/include", "-I", build / "lib/include"]
    excluded = {"dng_validate", "dng_xmp", "dng_xmp_sdk", "dng_update_meta", "dng_jxl"}
    files = [p for p in sorted(source.glob("*.cpp")) if p.stem not in excluded] + [patched]

    def compile_one(path):
        output = objects / (path.stem + ".o")
        run(path.stem, ["xcrun", "clang++", *flags, "-c", path, "-o", output])
        return output

    with ThreadPoolExecutor(max_workers=max(1, min(args.jobs, 8))) as pool:
        compiled = list(pool.map(compile_one, files))
    libraries = sorted(build.rglob("*.a"))
    executable = work / "f5-sdk-color-oracle"
    run("link", ["xcrun", "clang++", *flags, ROOT / "tools/f5_sdk_color_oracle.cpp", *compiled, *libraries,
        "-lz", "-framework", "CoreFoundation", "-framework", "CoreServices", "-framework", "Accelerate",
        "-Wl,-dead_strip", "-o", executable])
    report = {"sdk_url": URL, "sdk_sha256": SHA, "oracle_sha256": hashlib.sha256(executable.read_bytes()).hexdigest(),
        "color_source_modified": False, "disabled_unused_features": ["XMP", "VC5", "libJPEG"],
        "jxl_no_xmp_source_sha256": hashlib.sha256(patched.read_bytes()).hexdigest()}
    (work / "build-report.json").write_text(json.dumps(report, indent=2))
    print(executable)


if __name__ == "__main__":
    main()
