# Real-ESRGAN x4plus for Swivel

This is a narrowly approved third-party exception for Swivel's Upscale feature.
The application ships the fixed Core ML **model data**, not Python, PyTorch,
Core ML Tools, ncnn, Vulkan, a helper executable, a dynamic library or a downloader.
All inference runs on the Mac with Apple's Core ML framework. There is no model
registration, account, remote inference, media upload or runtime network request.

## Sources and licenses

- Official model repository: https://github.com/xinntao/Real-ESRGAN
- Repository/license revision: `a4abfb2979a7bbff3f69f58f58ae324608821e27`.
- Official release asset: https://github.com/xinntao/Real-ESRGAN/releases/download/v0.1.0/RealESRGAN_x4plus.pth
- Asset SHA256: `4fa0d38905f75ac06eb49a7951b426670021be3018265fd191d2125df9d682f1`.
- Model/project license: BSD-3-Clause, preserved verbatim in `LICENSE`.
- Conversion-only architecture: https://github.com/XPixelGroup/BasicSR/blob/8d56e3a045f9fb3e1d8872f92ee4a4f07f886b0a/basicsr/archs/rrdbnet_arch.py
- Architecture revision: `8d56e3a045f9fb3e1d8872f92ee4a4f07f886b0a`.
- Original architecture source SHA256: `6aa8eb3f77e918b90eeff4ebfaf8745abe0c40eb8fcc03abbc1928693d70ab58`.
- Architecture license: Apache-2.0, preserved verbatim in `LICENSE-BasicSR.txt`.
  Upstream has no NOTICE file; this folder's `NOTICE` records provenance and changes.
  BasicSR's other `LICENSE/` files concern unrelated architectures not taken here.

`rrdbnet.py` is an adapted subset of the pinned BasicSR source. It retains only
the x4 RRDBNet (64 features, 23 RRDB blocks, 32 growth channels), removes the
registry, random initialization helpers and x1/x2 branches, and uses non-in-place
activations. Strict loading supplies every parameter from `params_ema` of the
official checkpoint. `RGBImageModel` adds clipping to [0, 1] and multiplication by
255 for the Core ML RGB image output. No face restoration or synthetic face model
is included. This generative super-resolution model may invent small textures;
it is not lossless restoration or a claim that PSNR beats ordinary interpolation.

## Reproduce the conversion

Conversion was performed on macOS arm64 with CPython 3.12.4, PyTorch 2.7.0,
coremltools 9.0, NumPy 2.2.6 and Pillow 11.3.0. All direct and transitive wheel
versions and the platform wheel SHA256 values are in
`requirements-conversion-lock.txt`; the shorter version list is in
`requirements-conversion.txt`. These are development-only tools in `build/`.

From the repository root, create an isolated environment and download the official
asset explicitly. Never execute a downloaded installation script or use an
unrestricted pickle loader:

```sh
python3 -m venv build/realesrgan-conversion-venv
build/realesrgan-conversion-venv/bin/python -m pip install --only-binary=:all: --require-hashes -r ThirdParty/RealESRGAN/requirements-conversion-lock.txt
curl --fail --location --proto '=https' --tlsv1.2 https://github.com/xinntao/Real-ESRGAN/releases/download/v0.1.0/RealESRGAN_x4plus.pth -o build/RealESRGAN_x4plus.pth
build/realesrgan-conversion-venv/bin/python ThirdParty/RealESRGAN/convert.py build/RealESRGAN_x4plus.pth build/RealESRGAN-reproduced.mlpackage --halo 64 --precision fp32
```

`convert.py` refuses an existing output, verifies the exact checkpoint SHA256,
uses `torch.load(..., weights_only=True, map_location="cpu")`, checks that every
state value is a finite tensor and loads the expected keys/shapes strictly.
It never downloads anything. Core ML conversion uses the traced static graph,
`mlprogram`, FP32 computation and a macOS 15 deployment target. No custom layer,
custom model, control-flow callback or third-party executable is embedded.
Core ML's package UUIDs can vary on regeneration; independently verify numerical
parity, then deliberately update trusted file hashes when replacing a resource.

## Runtime contract and verification

The selected geometry is a fixed 256x256 RGB input and 1024x1024 RGB output:
128x128 useful source pixels plus a 64px halo on each side. The runtime consumes
one fixed opaque RGB image tile through feature `image`, and returns an RGB image through `upscaled`. Input
byte samples are scaled by 1/255 in the model; output is clipped and scaled to
byte levels in the graph. The app handles sRGB conversion, alpha separately,
outer-image reflection padding, trimming the tile context, final resizing and
exclusive output publication. Halo is real neighboring image context at internal
tile boundaries, not a separately reflected copy of each 128px core.

The app verifies the closed set of package files against `ModelResources.swift`,
then compiles a private verified snapshot using the system framework. Only the
pinned packaged data is accepted; user-supplied models or paths are unsupported.
The raw `.pth`, isolated conversion environment, wheel cache, compiled models and
fixture outputs remain ignored development artifacts in `build/`.

`verify_conversion.py` checks three bounded cases (photo, constant RGB, spatial
landmarks) against same-checkpoint PyTorch, with a two-byte maximum tolerance.
`verify_tiling.py` independently compares two fixed tiles against a larger untiled
PyTorch prediction. They report measured pixel differences rather than assuming
that finite context is identical to an untiled neural network. Verification runs
were additionally wrapped in an outer `sandbox-exec` profile denying `network*`.
These checks do not certify all inputs, all macOS hardware, photo authenticity,
HDR behavior or perceptual quality.

The bounded halo probe used a 256x128 central crop of the existing Parrot photo,
compared two Core ML tiles to one larger untiled PyTorch prediction, and measured
the 16 output columns straddling the internal seam. Differences below are byte
levels (0..255), including Core ML's output-image rounding:

| Halo | Input tile | Parrot seam mean | Parrot seam max | Whole-image mean |
| --- | --- | --- | --- | --- |
| 16 | 160x160 | 2.529 | 30.174 | 0.457 |
| 32 | 192x192 | 1.163 | 17.193 | 0.321 |
| 64 | 256x256 | 0.234 | 1.225 | 0.227 |

A second Zebra photo crop at halo64 measured seam mean 0.250, maximum 0.861 and
whole-image mean 0.243. These two small photographs support the larger context;
they do not prove that arbitrary texture or adversarial inputs have no seams.
The model's weight count and packaged size are independent of tile geometry,
but larger tiles require more activation memory and computation. Development
measurements and images are in ignored `build/realesrgan-coreml-tiling-*` folders.

Final production conversion verification on this Mac (2026-10-23), Core ML
`.cpuAndGPU`, compared the same 256x256 padded inputs to the original FP32
PyTorch checkpoint. All three outputs were finite 1024x1024 RGB images:

| Input | Mean byte difference, full output | Maximum byte difference | Core ML prediction |
| --- | --- | --- | --- |
| Parrot photo | 0.227 | 0.501 | 0.455 s |
| Constant RGB (51,127,203) | 0.222 | 0.518 | 0.351 s |
| RGB ramps/checker landmarks | 0.186 | 0.503 | 0.381 s |

Package load/compile through coremltools took 0.704 s in that run; compiler caches
may already have been warm. Timings include neither app tile preparation nor
final image encoding, and are measurements on one Mac rather than guarantees.
The mean includes unavoidable 8-bit output-image rounding; no channel differed
from the floating reference by more than one byte level. The earlier 160px
prototype was also verified through CPU-only Core ML; production Intel hardware,
macOS 15 execution and ANE execution were not available for direct validation.
Full result: ignored `build/realesrgan-coreml-parity-halo64/parity.json`.

The final package contains exactly these three ordinary files, totaling
67,441,119 bytes. `ModelResources.swift` embeds the same closed set and hashes:

| Package-relative path | SHA256 |
| --- | --- |
| `Data/com.apple.CoreML/model.mlmodel` | `b4b692e2faa4d7608b4bcac2f5ac5f0a506bd9956675a24d852e9d7e038b59e8` |
| `Data/com.apple.CoreML/weights/weight.bin` | `e1a6e725cbcde351873697efbdd3e6d228c9c6c193bc441a3a6c527c8e078d5f` |
| `Manifest.json` | `83e4c35c8a1f5038309cd9f57722f5e9eb6c7aecf6dcbed1196998c1b08bff85` |
