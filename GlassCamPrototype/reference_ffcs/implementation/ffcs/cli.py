"""Command line interface for FFCS."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from .io import load_pixels
from .metrics import colorchecker24_delta_e2000, compare_stage_directories
from .models import get_simulation, list_cameras, list_simulations
from .pipeline import FFCS, PipelineConfig


def _common(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--sim", "--simulation", default="PROVIA", help="Film simulation name")
    parser.add_argument("--camera", default="GENERIC", help="Camera body profile, e.g. XH2S")
    parser.add_argument("--filter", dest="filter_colour", choices=("G", "R", "Ye"), help="ACROS/MONOCHROME colour filter")
    parser.add_argument("--out", required=True, help="Output image path (.tif/.tiff/.jpg/.png)")
    parser.add_argument("--bits", type=int, choices=(8, 16), default=16, help="TIFF output bit depth")
    parser.add_argument("--space", choices=("sRGB", "AdobeRGB"), default="sRGB", help="Output ICC space")
    parser.add_argument("--seed", type=int, default=0, help="Deterministic grain seed")
    parser.add_argument("--lut", dest="lut_path", metavar="FILE", help="Measured 3D .cube LUT")
    parser.add_argument("--lut-domain", choices=("linear", "encoded"), help="Input domain of --lut (.cube): linear working RGB or encoded sRGB")
    parser.add_argument("--sigma", type=float, help="LUT sigma transition parameter")
    parser.add_argument("--analytic", action="store_true", help="Disable bundled camera reference LUTs")
    parser.add_argument("--stages", metavar="DIR", help="Export every intermediate stage to DIR")
    parser.add_argument("--json", action="store_true", help="Print pipeline metadata as JSON")


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="ffcs", description="Fujifilm film simulation colour pipeline")
    sub = p.add_subparsers(dest="command", required=True)
    apply = sub.add_parser("apply", help="Apply a simulation to an RGB image")
    apply.add_argument("image")
    _common(apply)
    develop = sub.add_parser("develop", help="Develop a RAF and apply a simulation")
    develop.add_argument("raw")
    _common(develop)
    ls = sub.add_parser("list", help="List simulations and camera profiles")
    ls.add_argument("what", choices=("simulations", "cameras"), nargs="?", default="simulations")
    compare = sub.add_parser("compare", help="Compare exported stage directories")
    compare.add_argument("candidate", help="Candidate stage directory")
    compare.add_argument("reference", help="Reference stage directory")
    compare.add_argument("--stride", type=int, default=1, help="Compare every Nth pixel")
    compare.add_argument("--out", help="Write JSON report to this path")
    checker = sub.add_parser("colorchecker", help="Compare 24 ColorChecker swatches")
    checker.add_argument("candidate", help="Candidate rendered image")
    checker.add_argument("reference", help="Reference rendered image")
    checker.add_argument("--boxes", required=True, help="JSON file containing 24 [x0,y0,x1,y1] boxes")
    checker.add_argument("--out", help="Write JSON report to this path")
    return p


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    if args.command == "list":
        for item in list_simulations() if args.what == "simulations" else list_cameras():
            print(item)
        return 0
    if args.command == "compare":
        try:
            report = compare_stage_directories(args.candidate, args.reference, stride=args.stride)
            encoded = json.dumps(report, indent=2)
            if args.out:
                Path(args.out).write_text(encoded + "\n", encoding="utf-8")
            print(encoded)
            return 0
        except (OSError, ValueError) as exc:
            print(f"ffcs: error: {exc}", file=sys.stderr)
            return 2
    if args.command == "colorchecker":
        try:
            boxes = json.loads(Path(args.boxes).read_text(encoding="utf-8"))
            candidate = load_pixels(args.candidate)
            reference = load_pixels(args.reference)
            report = colorchecker24_delta_e2000(candidate, reference, [tuple(map(int, box)) for box in boxes])
            report["target_mean_delta_e2000"] = 2.0
            report["status"] = "pass" if not report.get("shape_mismatch") and report["mean"] < 2.0 else "fail"
            encoded = json.dumps(report, indent=2)
            if args.out:
                Path(args.out).write_text(encoded + "\n", encoding="utf-8")
            print(encoded)
            return 0 if report["status"] == "pass" else 1
        except (OSError, ValueError, TypeError, json.JSONDecodeError) as exc:
            print(f"ffcs: error: {exc}", file=sys.stderr)
            return 2
    try:
        # Resolve before opening a large file so typos return a useful error.
        get_simulation(args.sim, args.filter_colour)
        config = PipelineConfig(
            simulation=args.sim, camera=args.camera, output_space=args.space,
            output_bits=args.bits, seed=args.seed, filter_colour=args.filter_colour,
            stage_dir=args.stages, lut_path=args.lut_path, lut_domain=args.lut_domain, sigma=args.sigma,
            use_reference_luts=not args.analytic,
        )
        source = args.image if args.command == "apply" else args.raw
        renderer = FFCS(config)
        result = renderer.apply_path(source)
        result.save(args.out, bits=args.bits, output_space=args.space)
        if args.json:
            print(json.dumps(result.metadata, indent=2, default=str))
        else:
            effective_bits = args.bits if Path(args.out).suffix.lower() in {".tif", ".tiff"} else 8
            print(f"Wrote {args.out} ({result.image.width}x{result.image.height}, {effective_bits}-bit {args.space})")
            print("Stages: " + ", ".join(result.metadata.get("stage_order", [])))
        return 0
    except (OSError, ValueError, RuntimeError) as exc:
        print(f"ffcs: error: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
