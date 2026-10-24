#!/usr/bin/env python3
"""Bounded on-device Core ML / PyTorch parity check, without network access.

The reference is the same checkpoint and same padded tile, not ground truth
photo quality. The script writes comparison PNGs and JSON only to --output.
"""
import argparse
import json
import time
from pathlib import Path
import sys

sys.dont_write_bytecode = True

import coremltools as ct
import numpy as np
from PIL import Image
import torch

from convert import load_network


def difference(a, b):
    delta = np.abs(np.asarray(a, dtype=np.float64) - np.asarray(b, dtype=np.float64))
    return {"mae_byte": float(delta.mean()), "max_byte": float(delta.max()),
            "p99_byte": float(np.percentile(delta, 99)),
            "fraction_over_one_byte": float((delta > 1).mean())}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("checkpoint", type=Path)
    parser.add_argument("package", type=Path)
    parser.add_argument("--fixture", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--cpu-only", action="store_true")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    torch.set_num_threads(2)
    network = load_network(args.checkpoint)
    units = ct.ComputeUnit.CPU_ONLY if args.cpu_only else ct.ComputeUnit.CPU_AND_GPU
    start = time.monotonic()
    model = ct.models.MLModel(str(args.package), compute_units=units)
    tile_size = model.get_spec().description.input[0].type.imageType.width
    halo = (tile_size - 128) // 2
    if tile_size != 128 + 2 * halo or halo not in (16, 32, 48, 64):
        raise ValueError("Unexpected model geometry")
    report = {"load_seconds": time.monotonic() - start, "compute_units": str(units),
              "padding": f"{halo}px reflection at outer image boundary; crop {halo * 4} output pixels on every side",
              "cases": {}}
    photo = np.asarray(Image.open(args.fixture).convert("RGB").resize((128, 128), Image.Resampling.LANCZOS))
    yy, xx = np.mgrid[:128, :128]
    cases = {
        "photo": photo,
        "constant": np.full((128, 128, 3), (51, 127, 203), dtype=np.uint8),
        "landmarks": np.stack(((xx * 2) % 256, (yy * 2) % 256, ((xx // 8 + yy // 8) % 2) * 255), axis=2).astype(np.uint8),
    }
    for name, source in cases.items():
        padded = np.pad(source, ((halo, halo), (halo, halo), (0, 0)), mode="reflect")
        tensor = torch.from_numpy(padded.transpose(2, 0, 1).copy()).float().unsqueeze(0) / 255.0
        start = time.monotonic()
        with torch.inference_mode():
            reference = network(tensor).clamp(0, 1)[0].permute(1, 2, 0).numpy() * 255.0
        torch_seconds = time.monotonic() - start
        start = time.monotonic()
        prediction = model.predict({"image": Image.fromarray(padded)})["upscaled"]
        coreml_seconds = time.monotonic() - start
        actual = np.asarray(prediction.convert("RGB"))
        if actual.shape != (tile_size * 4, tile_size * 4, 3) or not np.isfinite(actual).all():
            raise AssertionError("Invalid Core ML output")
        offset = halo * 4
        crop = np.s_[offset:offset + 512, offset:offset + 512, :]
        data = {"torch_seconds": torch_seconds, "coreml_seconds": coreml_seconds,
                "full": difference(reference, actual),
                "core": difference(reference[crop], actual[crop])}
        if data["full"]["max_byte"] > 2:
            raise AssertionError("Core ML conversion differs by more than two byte levels")
        report["cases"][name] = data
        Image.fromarray(np.rint(reference[crop]).astype(np.uint8)).save(args.output / f"{name}-torch.png")
        Image.fromarray(actual[crop]).save(args.output / f"{name}-coreml.png")
        print(json.dumps({name: data}), flush=True)
    (args.output / "parity.json").write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    main()
