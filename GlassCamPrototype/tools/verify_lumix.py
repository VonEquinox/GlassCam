"""Compare the portable core against independent SILKYPIX Pana_LUT vectors."""
from pathlib import Path
import concurrent.futures
import ctypes as C
import hashlib
import json
import math
import os
import shutil
import struct
import subprocess
import tempfile
import time

from prepare_lumix_resources import prepare

ROOT = Path(__file__).resolve().parents[1]
REPORT = ROOT / "validation/lumix-integration-20261026"


def main():
    started = time.perf_counter()
    with tempfile.TemporaryDirectory(prefix="glasscam-lumix-verify-") as temporary:
        work = Path(temporary)
        resources = work / "LUMIX"
        prepare(ROOT / "reference_lumix/source.zip", resources)
        env = os.environ.copy()
        env.setdefault("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer")
        library = work / "liblumix.dylib"
        subprocess.run(["xcrun", "clang++", "-std=c++17", "-O2", "-fno-fast-math", "-ffp-contract=off",
                        "-Wall", "-Wextra", "-Wpedantic", "-dynamiclib", str(ROOT / "core/lumix.cpp"),
                        "-lz", "-o", str(library)], env=env, check=True)
        lib = C.CDLL(str(library))
        lib.lumix_look_count.restype = C.c_size_t
        lib.lumix_look_key.argtypes = [C.c_size_t]; lib.lumix_look_key.restype = C.c_char_p
        lib.lumix_create.argtypes = [C.c_char_p, C.c_size_t, C.c_char_p, C.c_size_t]; lib.lumix_create.restype = C.c_void_p
        lib.lumix_destroy.argtypes = [C.c_void_p]
        lib.lumix_process_rgb12.argtypes = [C.c_void_p, C.POINTER(C.c_uint16), C.c_size_t, C.POINTER(C.c_uint16), C.c_char_p, C.c_size_t]
        lib.lumix_process_linear_rgba.argtypes = [C.c_void_p, C.POINTER(C.c_float), C.c_size_t, C.c_size_t, C.c_double, C.POINTER(C.c_float), C.c_size_t, C.c_char_p, C.c_size_t]
        error = C.create_string_buffer(1024)
        manifest = json.loads((resources / "manifest.json").read_text())
        assert lib.lumix_look_count() == len(manifest["looks"]) == 16
        assert lib.lumix_look_key(16) is None
        rows = []
        for index, look in enumerate(manifest["looks"]):
            context = lib.lumix_create(os.fsencode(resources), index, error, len(error))
            assert context, error.value
            try:
                data = (REPORT / "native-vectors" / (Path(look["asset"]).stem + ".rgb12")).read_bytes()
                assert hashlib.sha256(data).hexdigest() == look["goldenSHA256"]
                probes = list(struct.iter_unpack("<6H", data))
                n = len(probes)
                rgb = (C.c_uint16 * (n*3))(*(value for row in probes for value in row[:3]))
                result = (C.c_uint16 * (n*3))()
                assert lib.lumix_process_rgb12(context, rgb, n, result, error, len(error)) == 1, error.value
                maximum = max(abs(result[i*3+c] - row[3+c]) for i, row in enumerate(probes) for c in range(3))
                assert maximum == 0, (index, "native interpolation mismatch", maximum)
                f = (C.c_float * (n*3))(*(value/4095 for row in probes for value in row[:3]))
                out = (C.c_float * (n*4))()
                assert lib.lumix_process_linear_rgba(context, f, len(f), n, 0, out, len(out), error, len(error)) == 1, error.value
                expected = []
                for row in probes:
                    for value in row[3:]:
                        x = min(1, max(0, value/4095))
                        expected.append(x/12.92 if x <= .04045 else ((x+.055)/1.055)**2.4)
                    expected.append(1)
                float_error = max(abs(a-b) for a,b in zip(out, expected))
                assert float_error < 3e-8, float_error
                # Independent strip partitions must produce the identical Float32 raster.
                def strip(begin, count):
                    dest = (C.c_float * (count*4))()
                    message = C.create_string_buffer(1024)
                    source = C.cast(C.byref(f, begin*3*4), C.POINTER(C.c_float))
                    assert lib.lumix_process_linear_rgba(context, source, count*3, count, 0, dest, len(dest), message, len(message)) == 1
                    return bytes(dest)
                split = [0, 1, 64, 131, 4096, n]
                with concurrent.futures.ThreadPoolExecutor(max_workers=4) as executor:
                    chunks = list(executor.map(lambda pair: strip(pair[0], pair[1]-pair[0]), zip(split, split[1:])))
                assert b"".join(chunks) == bytes(out), "Concurrent strip output changed pixels"
                assert lib.lumix_process_linear_rgba(context, f, len(f), n, float("nan"), out, len(out), error, len(error)) == 0
                f[0] = float("nan")
                assert lib.lumix_process_linear_rgba(context, f, len(f), n, 0, out, len(out), error, len(error)) == 0
                rgb[0] = 4096
                assert lib.lumix_process_rgb12(context, rgb, n, result, error, len(error)) == 0
                rows.append({"look": lib.lumix_look_key(index).decode(), "nativeVectors": n,
                             "maximumRGB12Error": maximum, "maximumLinearFloatError": float_error,
                             "concurrentStripsIdentical": True})
            finally:
                lib.lumix_destroy(context)
        assert not lib.lumix_create(os.fsencode(resources), 16, error, len(error))
        broken = work / "broken"; broken.mkdir()
        assert not lib.lumix_create(os.fsencode(broken), 0, error, len(error))
        source = (resources / "L00801.lmx").read_bytes()
        for label, data in [("truncated", source[:-100]), ("corrupt", source[:50] + bytes([source[50]^1]) + source[51:]),
                            ("wrong-grid", source[:8]+struct.pack("<I",257)+source[12:])]:
            (broken / "L00801.lmx").write_bytes(data)
            assert not lib.lumix_create(os.fsencode(broken), 0, error, len(error)), label
        report = {"passed": True, "looks": rows, "totalNativeVectors": sum(r["nativeVectors"] for r in rows),
                  "missingAndCorruptResourcesRejected": True, "invalidInputsRejected": True,
                  "elapsedSeconds": time.perf_counter()-started,
                  "scope": "Exact original Pana_LUT RGB12 interpolation plus independently checked iPhone linear-sRGB adapter; not full RW2/ICC equivalence"}
        (REPORT / "native-verification.json").write_text(json.dumps(report, indent=2)+"\n")
        print(f"PASS: {len(rows)} looks, {report['totalNativeVectors']:,} native vectors; exact RGB12 agreement.")


if __name__ == "__main__":
    main()
