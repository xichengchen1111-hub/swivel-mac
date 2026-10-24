#!/usr/bin/env python3
"""Compare two fixed Core ML tiles with the untiled PyTorch checkpoint.

This measures finite-halo approximation, independently of conversion parity.
It is a small development fixture check, not a proof of all-photo equivalence.
"""
import argparse
import json
from pathlib import Path
import sys

sys.dont_write_bytecode = True

import coremltools as ct
import numpy as np
from PIL import Image
import torch

from convert import load_network
from verify_conversion import difference


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("checkpoint", type=Path)
    parser.add_argument("package", type=Path)
    parser.add_argument("--fixture", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    torch.set_num_threads(2)
    network = load_network(args.checkpoint)
    model = ct.models.MLModel(str(args.package), compute_units=ct.ComputeUnit.CPU_AND_GPU)
    tile_size = model.get_spec().description.input[0].type.imageType.width
    halo = (tile_size - 128) // 2
    if tile_size != 128 + 2 * halo or halo not in (16, 32, 48, 64):
        raise ValueError("Unexpected model geometry")
    photo = np.asarray(Image.open(args.fixture).convert("RGB").resize((256, 256), Image.Resampling.LANCZOS))[64:192]
    padded = np.pad(photo, ((halo, halo), (halo, halo), (0, 0)), mode="reflect")
    tensor = torch.from_numpy(padded.transpose(2, 0, 1).copy()).float().unsqueeze(0) / 255.0
    with torch.inference_mode():
        full = network(tensor).clamp(0, 1)[0].permute(1, 2, 0).numpy() * 255.0
    offset = halo * 4
    full = full[offset:offset + 512, offset:offset + 1024]
    pieces = []
    for x in (0, 128):
        tile = padded[:, x:x + tile_size]
        result = model.predict({"image": Image.fromarray(tile)})["upscaled"]
        pieces.append(np.asarray(result.convert("RGB"))[offset:offset + 512, offset:offset + 512])
    tiled = np.concatenate(pieces, axis=1)
    report = {"input": "256x128 central photo crop", "core": 128, "halo": halo,
              "whole": difference(full, tiled),
              "seam_16_output_pixels": difference(full[:, 504:520], tiled[:, 504:520]),
              "away_from_seam": difference(full[:, 64:448], tiled[:, 64:448])}
    Image.fromarray(np.rint(full).astype(np.uint8)).save(args.output / "untiled-torch.png")
    Image.fromarray(tiled).save(args.output / "tiled-coreml.png")
    (args.output / "tiling.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2), flush=True)


if __name__ == "__main__":
    main()
