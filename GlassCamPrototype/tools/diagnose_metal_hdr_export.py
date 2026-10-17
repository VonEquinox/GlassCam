"""Capture the exact pre-HEIF image in an external copy of the Mac pipeline.

This is a quality diagnostic, never a timing measurement. The production Swift
source is unchanged. Reuses the frozen CPU/GPU study library and compares the
instrumented HEIF hashes with the prior uninstrumented run.
"""
import argparse
import ctypes as c
import json
from pathlib import Path
import subprocess

import numpy as np

from audit_x2d_identity import sha


CAPTURE = r'''
private func captureColorStudyInput(_ context: CIContext, _ image: CIImage,
                                    _ pq: CGColorSpace, _ destination: URL) throws {
    let path = destination.appendingPathExtension("preencode.pq-rgba-f32")
    guard !FileManager.default.fileExists(atPath: path.path),
          FileManager.default.createFile(atPath: path.path, contents: nil) else {
        throw PipelineError.encoding
    }
    let file = try FileHandle(forWritingTo: path)
    defer { try? file.close() }
    let width = Int(image.extent.width), height = Int(image.extent.height)
    for y in stride(from: 0, to: height, by: 64) {
        let rows = min(64, height - y)
        var pixels = [Float](repeating: 0, count: width * rows * 4)
        try pixels.withUnsafeMutableBytes { bytes in
            context.render(image, toBitmap: bytes.baseAddress!, rowBytes: width * 16,
                bounds: CGRect(x: 0, y: y, width: width, height: rows),
                format: .RGBAf, colorSpace: pq)
            try file.write(contentsOf: Data(bytes))
        }
    }
}
'''

KEYS = ["pixels", "different_rgb_pixels", "mean_deltaEITP", "p95_deltaEITP",
        "p99_deltaEITP", "maximum_deltaEITP", "reference_peak_rgb_nits",
        "actual_peak_rgb_nits", "additional_black_channels",
        "additional_white_channels", "worst_sequence_index", "outside_pq_channels"]


def compare_buffers(library, first, second):
    assert first.stat().st_size == second.stat().st_size
    assert first.stat().st_size % 16 == 0
    lib = c.CDLL(str(library))
    lib.hdr_metric_create.restype = c.c_void_p
    lib.hdr_metric_add.argtypes = [c.c_void_p, c.c_void_p, c.c_void_p, c.c_size_t]
    lib.hdr_metric_finish.argtypes = [c.c_void_p, c.c_void_p, c.c_size_t]
    lib.hdr_metric_destroy.argtypes = [c.c_void_p]
    state = lib.hdr_metric_create()
    assert state
    try:
        with first.open("rb") as a, second.open("rb") as b:
            while True:
                x = np.frombuffer(a.read(16 * 262144), dtype=np.float32)
                y = np.frombuffer(b.read(16 * 262144), dtype=np.float32)
                if not len(x):
                    assert not len(y)
                    break
                assert len(x) == len(y)
                assert lib.hdr_metric_add(state, x.ctypes.data, y.ctypes.data, len(x) // 4) == 0
        values = np.zeros(len(KEYS), np.float64)
        assert lib.hdr_metric_finish(state, values.ctypes.data, len(values)) == 0
        report = dict(zip(KEYS, values.tolist()))
        report["worst_rgba"] = []
        for path in [first, second]:
            with path.open("rb") as stream:
                stream.seek(int(report["worst_sequence_index"]) * 16)
                report["worst_rgba"].append(np.frombuffer(stream.read(16), np.float32).tolist())
        return report
    finally:
        lib.hdr_metric_destroy(state)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--raw-source", type=Path, required=True)
    parser.add_argument("--study-dir", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--collect-only", action="store_true")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    study, out = args.study_dir.resolve(), args.output_dir.resolve()
    build = out / "build"
    build.mkdir(parents=True, exist_ok=True)
    pipeline_path = root / "ios/GlassCam/ImagePipeline.swift"
    pipeline = pipeline_path.read_text()
    anchor = "if #available(iOS 26, macOS 26, *) { image = image.settingContentHeadroom(outputHeadroom) }"
    assert pipeline.count(anchor) == 1
    instrumented = pipeline.replace(anchor, anchor + "\n        try captureColorStudyInput(context, image, pq, url)") + CAPTURE
    harness_path = root / "tools/apple_color_performance.swift"
    harness = harness_path.read_text().replace("for round in 0...rounds {", "for round in 0..<1 {")
    harness = harness.replace("for megapixels in round % 2 == 0 ? [48, 24] : [24, 48] {", "for megapixels in [24] {")
    if not args.collect_only:
        (build / "ImagePipeline.swift").write_text(instrumented)
        (build / "main.swift").write_text(harness)
        sources = [root / "ios/GlassCam" / name for name in [
            "ExportSettings.swift", "SourceImageStore.swift", "PhotoWhiteBalance.swift",
            "HNCSEngine.swift", "FFCSEngine.swift", "PreviewRaster.swift", "CaptureWorkflow.swift"]]
        command = ["xcrun", "swiftc", "-swift-version", "5", "-O", "-parse-as-library",
                   "-module-cache-path", str(build / "modules"), "-I", str(root / "core"),
                   "-import-objc-header", str(root / "ios/GlassCam/GlassCam-Bridging-Header.h"),
                   *map(str, sources), str(build / "ImagePipeline.swift"), str(build / "main.swift"),
                   "-L", str(study / "build"), "-lstudy", "-Xlinker", "-rpath", "-Xlinker",
                   str(study / "build"), "-o", str(build / "capture")]
        with (build / "build.log").open("w") as log:
            subprocess.run(command, check=True, stdout=log, stderr=subprocess.STDOUT)
        manifest = {"command": command, "raw_sha256": sha(args.raw_source),
                    "library_sha256": sha(study / "build/libstudy.dylib"),
                    "original_source_sha256": {str(p.relative_to(root)): sha(p) for p in [pipeline_path, harness_path, *sources]},
                    "instrumented_source_sha256": sha(build / "ImagePipeline.swift"),
                    "capture": "Same context and image after resize, clamp and content headroom, before HEIF; bottom-up 64-row PQ RGBA Float32 bands."}
        (out / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
        for variant in ["baseline", "metal-color"]:
            directory = out / variant
            if directory.exists():
                raise FileExistsError("Refusing to replace a previous diagnostic")
            subprocess.run([str(build / "capture"), str(args.raw_source.resolve()), str(directory),
                            "hncs-standard", variant, "0"], check=True, timeout=900)
    buffers, hashes = [], []
    for variant in ["baseline", "metal-color"]:
        file = out / variant / "round-0-24mp.heic"
        previous = study / "hncs-standard" / variant / file.name
        hashes.append({"variant": variant, "instrumented_sha256": sha(file),
                       "original_sha256": sha(previous), "identical": sha(file) == sha(previous)})
        buffers.append(file.with_name(file.name + ".preencode.pq-rgba-f32"))
    report = {"encoded_hash_checks": hashes,
              "preencode": compare_buffers(study / "build/libmetrics.dylib", *buffers),
              "encoded": json.loads((study / "hncs-standard/hdr-24mp.json").read_text()),
              "scope": "Standard 24MP diagnostic. Timings include capture and are not performance evidence."}
    (out / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
