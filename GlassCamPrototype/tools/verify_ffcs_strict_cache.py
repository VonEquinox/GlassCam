"""Compare frozen old/new FFCS libraries bit-for-bit across all 50 resources."""
import argparse
import ctypes as c
import json
from pathlib import Path

import numpy as np

from audit_x2d_identity import sha
from verify_x2d_color_gain import bind


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", type=Path, required=True)
    parser.add_argument("--candidate", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.output.exists():
        raise FileExistsError("Preserve previous cross-version results")
    root = Path(__file__).resolve().parents[1]
    apis = []
    for path in [args.baseline, args.candidate]:
        lib = c.CDLL(str(path.resolve()))
        apis.append({"library": lib,
            "create": bind(lib, "ffcs_create", [c.c_char_p, c.c_size_t, c.c_void_p, c.c_size_t], c.c_void_p),
            "destroy": bind(lib, "ffcs_destroy", [c.c_void_p], None),
            "encoded": bind(lib, "ffcs_process_encoded_double", [c.c_void_p, c.c_void_p, c.c_size_t,
                c.c_size_t, c.c_size_t, c.c_uint32, c.c_void_p, c.c_size_t, c.c_void_p, c.c_void_p, c.c_void_p, c.c_size_t]),
            "linear": bind(lib, "ffcs_process_linear_rgb_optimized", [c.c_void_p, c.c_void_p, c.c_size_t,
                c.c_size_t, c.c_size_t, c.c_float, c.c_uint32, c.c_void_p, c.c_size_t, c.c_void_p,
                c.c_size_t, c.c_uint, c.c_void_p, c.c_size_t])})
    lib = apis[0]["library"]
    count = bind(lib, "ffcs_simulation_count", [], c.c_size_t)()
    asset = bind(lib, "ffcs_simulation_asset", [c.c_size_t], c.c_char_p)
    indices = {asset(i).decode(): i for i in range(count)}
    grid = np.stack(np.meshgrid(*([np.linspace(0, 1, 17)] * 3), indexing="ij"), axis=-1).reshape(-1, 3)
    encoded = np.ascontiguousarray(np.concatenate([np.repeat(np.linspace(0, 1, 20001)[:, None], 3, axis=1),
              grid, np.random.default_rng(20261018).random((4096, 3))]).reshape(30, 967, 3))
    linear = np.where(encoded <= .04045, encoded / 12.92, ((encoded + .055) / 1.055) ** 2.4).astype(np.float32)
    double_outputs = [np.empty_like(encoded) for _ in apis]
    float_outputs = [np.empty_like(linear) for _ in apis]
    previews = [np.empty((30, 967, 4), np.uint8) for _ in apis]
    error = c.create_string_buffer(1024)
    rows = []
    for path in sorted((root / "reference_ffcs/implementation/ffcs/data").glob("*/*.lutz")):
        contexts = []
        try:
            for api in apis:
                context = api["create"](str(path.parent).encode(), indices[path.name], error, len(error))
                assert context, error.value
                contexts.append(context)
            for api, ctx, output in zip(apis, contexts, double_outputs):
                assert api["encoded"](ctx, encoded.ctypes.data, encoded.size, 967, 30, 0,
                       output.ctypes.data, output.size, None, None, error, len(error)), error.value
            np.testing.assert_array_equal(double_outputs[0].view(np.uint64), double_outputs[1].view(np.uint64))
            for ev in [-2., .7, 2.]:
                # Four workers actually run: 30 image rows, not a one-row corpus.
                for api, ctx, output, preview in zip(apis, contexts, float_outputs, previews):
                    assert api["linear"](ctx, linear.ctypes.data, linear.size, 967, 30, ev, 0xffffffff,
                           output.ctypes.data, output.size, preview.ctypes.data, preview.size, 4, error, len(error)), error.value
                np.testing.assert_array_equal(float_outputs[0].view(np.uint32), float_outputs[1].view(np.uint32))
                np.testing.assert_array_equal(previews[0], previews[1])
            rows.append({"asset": str(path.relative_to(root / "reference_ffcs/implementation/ffcs/data")),
                         "asset_sha256": sha(path), "pixels": 29010, "double_bits_different": 0,
                         "float_and_preview_bits_different": 0, "linear_exposures": [-2., .7, 2.], "workers": 4})
        finally:
            for api, context in zip(apis, contexts):
                api["destroy"](context)
    assert len(rows) == 50
    report = {"status": "passed", "cases": rows,
              "libraries_sha256": {"baseline": sha(args.baseline), "candidate": sha(args.candidate)},
              "tool_sha256": sha(Path(__file__)),
              "scope": "Default neutral FFCS 0.2 recipes, same Double/Float32/preview inputs and four workers; frozen old C++ vs strict cache/GCD C++. Not vendor equivalence or performance timing."}
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    print("50 resources: 4,351,500 Double channels, 13,054,500 Float32 channels and matching RGBA previews; zero changed bits.")


if __name__ == "__main__":
    main()
