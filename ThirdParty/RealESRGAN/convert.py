#!/usr/bin/env python3
"""Convert only the pinned, data-only official RealESRGAN_x4plus checkpoint.

Run in the build-local environment documented in UPSTREAM.md. No download,
package installation, arbitrary pickle loading or media upload occurs here.
"""
import argparse
import hashlib
import json
from pathlib import Path
import sys

sys.dont_write_bytecode = True

import coremltools as ct
import torch

from rrdbnet import RGBImageModel, RRDBNet

WEIGHT_SHA256 = "4fa0d38905f75ac06eb49a7951b426670021be3018265fd191d2125df9d682f1"


def load_network(checkpoint):
    digest = hashlib.sha256(checkpoint.read_bytes()).hexdigest()
    if digest != WEIGHT_SHA256:
        raise ValueError("Checkpoint does not match the pinned official asset")
    payload = torch.load(checkpoint, map_location="cpu", weights_only=True)
    state = payload["params_ema"]
    if any(not isinstance(v, torch.Tensor) or not torch.isfinite(v).all() for v in state.values()):
        raise ValueError("Checkpoint must contain finite tensors only")
    network = RRDBNet().eval()
    network.load_state_dict(state, strict=True)
    return network


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("checkpoint", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--precision", choices=("fp32", "fp16"), default="fp32")
    parser.add_argument("--halo", type=int, choices=(16, 32, 48, 64), default=64)
    args = parser.parse_args()
    if args.output.exists():
        raise ValueError("Refusing to replace an existing output")
    torch.set_num_threads(2)
    torch.manual_seed(0)
    network = load_network(args.checkpoint)
    wrapper = RGBImageModel(network).eval()
    tile_size = 128 + 2 * args.halo
    example = torch.zeros((1, 3, tile_size, tile_size), dtype=torch.float32)
    with torch.inference_mode():
        traced = torch.jit.trace(wrapper, example, check_trace=False)
    model = ct.convert(
        traced,
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.macOS15,
        inputs=[ct.ImageType(name="image", shape=example.shape, scale=1.0 / 255.0,
                             color_layout=ct.colorlayout.RGB)],
        outputs=[ct.ImageType(name="upscaled", color_layout=ct.colorlayout.RGB)],
        compute_precision=ct.precision.FLOAT32 if args.precision == "fp32" else ct.precision.FLOAT16,
        compute_units=ct.ComputeUnit.CPU_AND_GPU,
        skip_model_load=True,
    )
    model.short_description = f"Real-ESRGAN x4plus. Fixed {tile_size}px RGB tile to {tile_size * 4}px RGB tile."
    model.author = "Xintao Wang et al. (Real-ESRGAN); Core ML conversion for Swivel"
    model.license = "BSD-3-Clause model; Apache-2.0 conversion architecture. See shipped licenses."
    model.input_description["image"] = f"{tile_size}x{tile_size} opaque sRGB image; byte values are normalized by 1/255."
    model.output_description["upscaled"] = f"{tile_size * 4}x{tile_size * 4} RGB image; network output clamped to [0,1] then multiplied by 255."
    model.user_defined_metadata.update({
        "source": "https://github.com/xinntao/Real-ESRGAN/releases/tag/v0.1.0",
        "checkpoint_sha256": WEIGHT_SHA256,
        "tile_core": "128",
        "tile_halo": str(args.halo),
        "precision": args.precision,
        "processing": "On-device only; no custom layers or model download code",
    })
    model.save(str(args.output))
    files = {str(path.relative_to(args.output)): hashlib.sha256(path.read_bytes()).hexdigest()
             for path in sorted(args.output.rglob("*")) if path.is_file()}
    print(json.dumps({"output": str(args.output), "files": files}, indent=2), flush=True)


if __name__ == "__main__":
    main()
