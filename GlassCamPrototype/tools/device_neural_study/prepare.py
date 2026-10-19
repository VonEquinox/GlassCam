"""Prepare fixed, untrained source-matrix models and an isolated iPhone study project."""
import argparse
import ctypes as c
import hashlib
import json
from pathlib import Path
import shutil
import sys

import coremltools as ct
from coremltools.converters.mil import Builder as mb
import numpy as np


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--reference-library", type=Path, required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    study = Path(__file__).resolve().parent
    out = args.output.resolve()
    payload = out / "payload"
    payload.mkdir(parents=True, exist_ok=True)
    # Reuse the already retained numerical corpus without importing unrelated
    # image-audit dependencies into the Core ML conversion environment.
    image = np.load(args.reference_library.parent / "standard-input.npy")
    assert image.shape == (256, 512, 3) and image.dtype == np.float32
    gains = np.ones((256, 512), np.float32)
    gains[232:] = np.linspace(1, 10000 / 203, 512, dtype=np.float32)
    image.tofile(payload / "synthetic-rgb.f32")
    gains.tofile(payload / "synthetic-gains.f32")
    previous = json.loads((root / "validation/iphone-performance-20261018.json").read_text())
    library = c.CDLL(str(args.reference_library))
    create = library.hncs_create_preset_whitepoint
    create.argtypes = [c.c_double] * 4 + [c.c_int] * 4 + [c.c_char_p, c.c_int]
    create.restype = c.c_void_p
    library.hncs_source_to_native_matrix.argtypes = [c.c_void_p, c.c_void_p]
    library.hncs_destroy.argtypes = [c.c_void_p]
    manifest = {"scope": "Untrained HNCS source matrix/exposure substitution; original color, gradation, spatial and HDR/output stages remain.",
                "coremltools": ct.__version__, "cases": [], "models": []}
    for preset in ["standard", "nature"]:
        recipe = json.loads(previous["raw_reports"]["hncs-" + preset]["samples"][0]["resolved_recipe"])
        white = recipe["photoWhiteBalance"]
        context = create(-0.05, white["x"], white["y"], 0, 1, 0, 4, 2, preset.encode(), 1)
        assert context
        matrix = np.empty((3, 3), np.float64)
        assert library.hncs_source_to_native_matrix(context, matrix.ctypes.data) == 0
        library.hncs_destroy(context)
        manifest["cases"].append({"preset": preset, "recipe": recipe, "matrix": matrix.tolist(),
                                  "exposure": 2.0 ** -0.05})
        for shape_name, shape in [("small", (1, 3, 256, 512)), ("strip", (1, 3, 64, 6048))]:
            for precision, precision_type in [("fp32", ct.precision.FLOAT32), ("fp16", ct.precision.FLOAT16)]:
                @mb.program(input_specs=[mb.TensorSpec(shape=shape)], opset_version=ct.target.iOS18)
                def program(source):
                    scaled = mb.mul(x=source, y=np.float32(2.0 ** -0.05))
                    return mb.conv(x=scaled, weight=matrix.astype(np.float32)[:, :, None, None], name="native")
                name = f"{preset}-{shape_name}-{precision}"
                model = ct.convert(program, convert_to="mlprogram", minimum_deployment_target=ct.target.iOS18,
                                   compute_precision=precision_type, skip_model_load=True)
                model.save(str(payload / (name + ".mlpackage")))
                manifest["models"].append({"name": name, "shape": shape, "precision": precision,
                                          "role": "source-matrix"})
            padded_shape = (1, 16, shape[2], shape[3])
            padded_weights = np.eye(16, dtype=np.float32)
            padded_weights[:3, :3] = matrix.astype(np.float32)
            @mb.program(input_specs=[mb.TensorSpec(shape=padded_shape)], opset_version=ct.target.iOS18)
            def padded(source):
                scaled = mb.mul(x=source, y=np.float32(2.0 ** -0.05))
                return mb.conv(x=scaled, weight=padded_weights[:, :, None, None], name="native")
            name = f"{preset}-{shape_name}-padded16"
            model = ct.convert(padded, convert_to="mlprogram", minimum_deployment_target=ct.target.iOS18,
                               compute_precision=ct.precision.FLOAT16, skip_model_load=True)
            model.save(str(payload / (name + ".mlpackage")))
            manifest["models"].append({"name": name, "shape": padded_shape, "precision": "fp16",
                                      "role": "Same RGB transform, 13 zero input channels for ANE layout; first three output channels used."})
    rng = np.random.default_rng(20261018)
    weights = [(rng.standard_normal((32, 32, 3, 3)) * .025).astype(np.float32) for _ in range(4)]
    @mb.program(input_specs=[mb.TensorSpec(shape=(1, 32, 128, 128))], opset_version=ct.target.iOS18)
    def dense(source):
        value = source
        for index, weight in enumerate(weights):
            value = mb.conv(x=value, weight=weight, pad_type="same", name=f"conv_{index}")
            value = mb.relu(x=value, name=f"relu_{index}")
        return value
    model = ct.convert(dense, convert_to="mlprogram", minimum_deployment_target=ct.target.iOS18,
                       compute_precision=ct.precision.FLOAT16, skip_model_load=True)
    model.save(str(payload / "dense-control-fp16.mlpackage"))
    manifest["models"].append({"name": "dense-control-fp16", "shape": [1, 32, 128, 128],
                              "role": "Synthetic convolution hardware control, never used to render a photo."})
    manifest["file_sha256"] = {str(p.relative_to(payload)): hashlib.sha256(p.read_bytes()).hexdigest()
                               for p in sorted(payload.rglob("*")) if p.is_file() and p.name != "manifest.json"}
    (payload / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    project = out / "project/GlassCam.xcodeproj"
    shutil.copytree(root / "ios/GlassCam.xcodeproj", project, dirs_exist_ok=True)
    path = project / "project.pbxproj"
    text = path.read_text()
    text = text.replace('path = GlassCam;\n\t\t\tsourceTree = "<group>";',
                        f'path = "{root / "ios/GlassCam"}";\n\t\t\tsourceTree = "<absolute>";')
    text = text.replace('path = ../core;', f'path = "{root / "core"}";')
    text = text.replace('path = GlassCamApp.swift; sourceTree = "<group>";',
                        f'path = "{study / "NeuralStudyApp.swift"}"; sourceTree = "<absolute>";')
    text = text.replace('lastKnownFileType = sourcecode.cpp.cpp; path = hncs.cpp; sourceTree = "<group>";',
                        f'lastKnownFileType = sourcecode.cpp.objcpp; path = "{study / "NeuralBridge.mm"}"; sourceTree = "<absolute>";')
    text = text.replace('"GlassCam/GlassCam-Bridging-Header.h"', f'"{study / "NeuralStudy.h"}"')
    text = text.replace('$(SRCROOT)/../core', str(root / "core"))
    text = text.replace('COMPILER_FLAGS = "-O3 -fno-fast-math -ffp-contract=off";',
                        'COMPILER_FLAGS = "-O3 -fno-fast-math -ffp-contract=off -fobjc-arc";', 1)
    # Existing FFCS resources were verified by the production build and remain
    # referenced in place; this isolated project does not regenerate assets.
    lines = text.splitlines()
    lines = [('\t\t\tshellScript = "true\\n";' if 'shellScript =' in line else line) for line in lines]
    path.write_text('\n'.join(lines) + '\n')
    print("Prepared", len(manifest["models"]), "models and", project)


if __name__ == "__main__":
    main()
