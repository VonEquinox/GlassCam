"""Verify original frame bytes and summarize manually recorded glass decisions.

Accepts a copied GlassCamStateRecords directory or its exported ZIP. Never alters
the input. Alpha describes the submitted Metal layer, not final compositor pixels.
"""
from pathlib import Path, PurePosixPath
import argparse
import collections
import hashlib
import json
import math
import struct
import zipfile
import zlib


def finite(value):
    return isinstance(value, (int, float)) and math.isfinite(value)


def png_rgba(data, width, height):
    if not 0 < width <= 1024 or not 0 < height <= 1024 or len(data) != width * height * 4:
        raise ValueError("Analysis raster dimensions do not match its exact bytes")

    def chunk(kind, payload):
        return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", zlib.crc32(kind + payload))

    rows = b"".join(b"\0" + data[y * width * 4:(y + 1) * width * 4] for y in range(height))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">2I5B", width, height, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))


def analyze(source: Path, output: Path):
    output.mkdir(parents=True, exist_ok=True)
    archive = zipfile.ZipFile(source) if source.is_file() else None
    try:
        if archive:
            manifests = sorted(name for name in archive.namelist() if name.endswith("/manifest.json"))
        else:
            manifests = sorted(str(path.relative_to(source)) for path in source.rglob("manifest.json")
                               if not any(part.startswith(".") for part in path.relative_to(source).parts))
        records = []
        for manifest_name in manifests:
            parent = PurePosixPath(manifest_name).parent

            def location(name):
                relative = PurePosixPath(name)
                if relative.is_absolute() or ".." in relative.parts:
                    raise ValueError("Invalid relative path in recording")
                path = parent / relative
                if archive:
                    return archive.open(str(path))
                actual = (source / str(path)).resolve()
                if not actual.is_relative_to(source.resolve()):
                    raise ValueError("Recording path escapes input directory")
                return actual.open("rb")

            if archive:
                manifest = json.loads(archive.read(manifest_name))
            else:
                manifest = json.loads((source / manifest_name).read_text())
            failures = []
            for entry in manifest.get("files", []):
                try:
                    digest, size = hashlib.sha256(), 0
                    with location(entry["path"]) as stream:
                        while chunk := stream.read(1024 * 1024):
                            digest.update(chunk)
                            size += len(chunk)
                    if size != entry["bytes"] or digest.hexdigest() != entry["sha256"]:
                        failures.append(entry["path"] + ": byte count or SHA256 mismatch")
                except (OSError, ValueError, KeyError) as exc:
                    failures.append(entry["path"] + ": " + str(exc))
            renderer = manifest.get("renderer", {})
            camera = manifest.get("camera", {})
            analysis = manifest.get("analysis", {})
            alpha = renderer.get("effectiveBlackOpacity")
            if renderer.get("phase") != "submitted" or not finite(alpha):
                state = "no-current-submission"
            elif alpha >= 0.999:
                state = "black"
            elif alpha <= 0.001:
                state = "transparent"
            else:
                state = "partial"
            opacity_range = renderer.get("effectiveBlackOpacityRange")
            if renderer.get("opacityMode") == "per-edge" and isinstance(opacity_range, list) and len(opacity_range) == 2 and all(finite(v) for v in opacity_range):
                state = "black" if min(opacity_range) >= 0.999 else "transparent" if max(opacity_range) <= 0.001 else "partial"
            history = manifest.get("renderHistory", [])
            reasons = collections.Counter(str(row.get("policyReason", row.get("reason", "unknown"))) for row in history)
            age = manifest.get("tapHostTime", 0) - renderer.get("hostTime", 0)
            if not history and not renderer.get("hostTime"):
                age = None
            roles = manifest.get("roles", {})
            diagnosis = []
            if finite(age) and age > 0.25:
                diagnosis.append("Renderer telemetry is stale; do not interpret it as the current screen.")
            if not camera.get("isReady", False):
                diagnosis.append("Camera was not ready: " + str(camera.get("status", "unknown")))
            if renderer.get("forcedBlack"):
                diagnosis.append("Renderer policy forced black (source/resource failure).")
            diagnosis.extend(str(reason) for reason in renderer.get("rejectionReasons", []))
            if not analysis.get("published", False):
                diagnosis.append("Last analysis was not published: " + str(analysis.get("reason", "not available")))
            evidence = analysis.get("evidence", analysis.get("measurementEvidence", {}))
            segment_states = collections.Counter(row.get("status", "unknown") for row in analysis.get("segments", []))
            row = {
                "id": manifest.get("id", str(parent)), "wallTime": manifest.get("wallTime"),
                "integrity": "FAILED" if failures else "verified", "integrityFailures": failures,
                "verifiedFileCount": len(manifest.get("files", [])), "submittedGlassState": state,
                "effectiveBlackOpacity": alpha, "rendererAgeSeconds": age,
                "selectedTolerance": manifest.get("camera", {}).get("tolerance"),
                "analysisTolerance": analysis.get("tolerance"),
                "rendererTolerance": renderer.get("tolerance"),
                "textureTolerance": renderer.get("textureTolerance"),
                "policyReason": renderer.get("policyReason"), "rejectionReasons": renderer.get("rejectionReasons", []),
                "analysisReason": analysis.get("reason"), "analysisPublished": analysis.get("published"),
                "analysisElapsedMS": analysis.get("elapsedMS"), "analysisEvidence": evidence,
                "segmentStatuses": dict(segment_states), "recentPolicyReasons": dict(reasons),
                "roles": roles, "pairCount": len(manifest.get("pairs", {})), "observations": diagnosis,
                "qualityOpacity": renderer.get("qualityOpacity", renderer.get("policyOpacity")),
                "readinessOpacity": renderer.get("readinessOpacity"),
                "policyMode": renderer.get("policyMode", "legacy-strict-geometry"),
                "evidenceBasis": renderer.get("evidenceBasis"),
                "effectiveBlackOpacityRange": opacity_range,
                "edgeBlackOpacities": renderer.get("edgeBlackOpacities"),
                "edgePolicyReasons": renderer.get("edgePolicyReasons"),
                "opacityCoupling": renderer.get("opacityCoupling"),
                "presentationMode":renderer.get("presentationMode"),
                "cameraExposureSkew":renderer.get("cameraExposureSkew"),
                "applicationAddedFrameSkew":renderer.get("applicationAddedFrameSkew"),
                "centerTexturePairID":renderer.get("centerTexturePairID"),
                "captureMode":renderer.get("captureMode"),
                "edgeAssessments": renderer.get("edgeAssessments"),
                "directStitch": renderer.get("directStitch", False),
                "analysisGateReasons": renderer.get("analysisGateReasons", analysis.get("gateReasons", [])),
                "visibleSeam": evidence.get("visibleSeam"),
                "nativeTileFailures": [tile for tile in analysis.get("nativeSeamTiles", []) if not tile.get("passed")],
                "nativeDataMeaning": manifest.get("pixelContract"),
                "renderModel": manifest.get("renderModel"),
                "textureAgeSeconds": renderer.get("textureAge"),
                "textureAnalysisPairID": renderer.get("textureAnalysisPairID"),
                "mappingBasis": renderer.get("textureMappingBasis"),
                "worker": renderer.get("worker"),
            }
            # Visual derivatives are separate files; the input bytes stay intact.
            raster_dir = output / str(manifest.get("id", parent.name))
            if raster_dir.parent.resolve() != output.resolve():
                raise ValueError("Invalid record id")
            for key, padded in [("referenceFile", False), ("warpedFile", True)]:
                if key not in analysis:
                    continue
                width, height = int(analysis["width"]), int(analysis["height"])
                if padded:
                    width += 2 * int(analysis["padding"])
                    height += 2 * int(analysis["padding"])
                try:
                    with location(analysis[key]) as stream:
                        data = stream.read(4 * 1024 * 1024)
                    raster_dir.mkdir(exist_ok=True)
                    (raster_dir / (key + ".png")).write_bytes(png_rgba(data, width, height))
                except (OSError, ValueError, KeyError) as exc:
                    row.setdefault("previewErrors", []).append(str(exc))
            records.append(row)
        summary = {"schemaVersion": 1, "source": str(source.resolve()), "recordCount": len(records),
                   "integrityFailures": sum(row["integrity"] != "verified" for row in records), "records": records}
        (output / "analysis.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n")
        lines = ["# GlassCam 状态记录分析", "", "透明度是提交给 Metal 的值；不等同于对系统玻璃最终像素的测量。", ""]
        for row in records:
            lines += [f"## {row['id']}", "", f"- 时间：{row['wallTime']}",
                      f"- 原始文件校验：{row['integrity']}（{row['verifiedFileCount']} 个文件）",
                      f"- 提交状态：{row['submittedGlassState']}，黑色覆盖率：{row['effectiveBlackOpacity']}",
                      f"- 容差：选择 {row['selectedTolerance']}；分析 {row['analysisTolerance']}；显示纹理 {row['textureTolerance']}",
                      f"- 策略原因：{row['policyReason']}；渲染数据年龄：{row['rendererAgeSeconds']} 秒",
                      f"- 显示依据：{row['evidenceBasis']}；映射来源：{row['mappingBasis']}；纹理年龄：{row['textureAgeSeconds']} 秒",
                      f"- 分析结果：{row['analysisReason']}；已发布：{row['analysisPublished']}",
                      f"- 阻止透明的条件：{', '.join(row['rejectionReasons']) or '未记录到'}",
                      f"- 分段匹配状态：{json.dumps(row['segmentStatuses'], ensure_ascii=False)}",
                      f"- 保留 {row['pairCount']} 组原始双路输入；角色：{json.dumps(row['roles'], ensure_ascii=False)}", ""]
            lines += ["- " + observation for observation in row["observations"] + row["integrityFailures"]] + [""]
        (output / "analysis.md").write_text("\n".join(lines))
        return summary
    finally:
        if archive:
            archive.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    report = analyze(args.source, args.output)
    print(json.dumps({key: report[key] for key in ("recordCount", "integrityFailures")}, ensure_ascii=False))
    if not report["recordCount"] or report["integrityFailures"]:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
