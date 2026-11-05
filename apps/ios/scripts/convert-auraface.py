#!/usr/bin/env python3
"""Convert only fal's explicitly licensed recognition checkpoint, with numerical parity gates.

Run in the pinned environment documented in docs/face-identity-model-audit.md. No user images,
detector models, network inference, or unrelated InsightFace weights are used here.
"""
import argparse
import hashlib
import json
from pathlib import Path

import coremltools as ct
import numpy as np
import onnx
import onnxruntime as ort
from onnx2torch import convert
import torch
from PIL import Image

SOURCE_SHA256 = "a7933ea5330113b01c9b60351d8f4c33003f145d8470ac5f0e52ee2effe25c60"
REVISION = "af6d057c9b0ec4071d4c49c80e3539258798b609"


def cosine(a, b):
    a, b = np.asarray(a).reshape(-1), np.asarray(b).reshape(-1)
    return float(np.dot(a, b) / (np.linalg.norm(a) * np.linalg.norm(b)))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--fixtures", type=Path, help="Export synthetic-only model parity fixtures")
    args = parser.parse_args()
    assert hashlib.sha256(args.source.read_bytes()).hexdigest() == SOURCE_SHA256, "Unapproved weights"
    torch.set_num_threads(4)
    graph = onnx.load(str(args.source))
    print("ONNX operators:", sorted({node.op_type for node in graph.graph.node}), flush=True)
    model = convert(graph).eval()
    rng = np.random.default_rng(4815)
    pixels = [np.full((112, 112, 3), 128, dtype=np.uint8)]
    pixels += [rng.integers(0, 256, size=(112, 112, 3), dtype=np.uint8) for _ in range(3)]
    samples = [((image.astype(np.float32) - 127.5) / 127.5).transpose(2, 0, 1)[None] for image in pixels]
    session = ort.InferenceSession(str(args.source), providers=["CPUExecutionProvider"])
    input_name = session.get_inputs()[0].name
    references = [session.run(None, {input_name: sample})[0] for sample in samples]
    with torch.no_grad():
        torch_parity = [cosine(model(torch.from_numpy(sample)).numpy(), reference)
                        for sample, reference in zip(samples, references)]
        print("ONNX/PyTorch cosine:", torch_parity, flush=True)
        assert min(torch_parity) > 0.99999
        traced = torch.jit.trace(model, torch.from_numpy(samples[0]), check_trace=True)
    converted = ct.convert(
        traced, source="pytorch", convert_to="mlprogram",
        inputs=[ct.ImageType(name="face", shape=(1, 3, 112, 112), color_layout=ct.colorlayout.RGB,
                             scale=1 / 127.5, bias=[-1, -1, -1])],
        outputs=[ct.TensorType(name="embedding")],
        minimum_deployment_target=ct.target.iOS17,
        compute_units=ct.ComputeUnit.CPU_AND_NE,
        compute_precision=ct.precision.FLOAT32,
    )
    # Weight-only int8; retain FP32 activation math, which was necessary for the parity gate.
    from coremltools.optimize.coreml import (
        OpLinearQuantizerConfig, OptimizationConfig, linear_quantize_weights,
    )
    converted = linear_quantize_weights(converted, OptimizationConfig(
        global_config=OpLinearQuantizerConfig(mode="linear_symmetric", dtype="int8", granularity="per_channel"),
    ))
    converted.short_description = "AuraFace v1 face identity embedding; fal Apache-2.0 weights; int8 weight-only Core ML conversion"
    converted.license = "Apache-2.0; https://huggingface.co/fal/AuraFace-v1"
    converted.user_defined_metadata.update({
        "source_revision": REVISION, "source_sha256": SOURCE_SHA256,
        "input_contract": "RGB NCHW 112x112, (pixel-127.5)/127.5; ArcFace five-point alignment",
        "output_contract": "512 floats; L2-normalize before cosine comparison",
    })
    args.output.parent.mkdir(parents=True, exist_ok=True)
    converted.save(str(args.output))
    # Run the actual compressed Core ML artifact, not just the pre-conversion torch graph.
    executable = ct.models.MLModel(str(args.output), compute_units=ct.ComputeUnit.CPU_ONLY)
    parity = [cosine(executable.predict({"face": Image.fromarray(image)})["embedding"], reference)
              for image, reference in zip(pixels, references)]
    print("ONNX/compressed Core ML cosine:", parity, flush=True)
    assert min(parity) > 0.999, "Conversion changes embedding direction too much"
    if args.fixtures:
        args.fixtures.mkdir(parents=True, exist_ok=True)
        fixture_root = Path(__file__).resolve().parents[1] / "Rocky/Tests/Fixtures/FaceFeaturePrint"
        for name in ["synthetic-a-1", "synthetic-b-1", "synthetic-c-1"]:
            image = Image.open(fixture_root / (name + ".png")).convert("RGB").resize((112, 112), Image.Resampling.BILINEAR)
            image.save(args.fixtures / (name + "-112.png"))
            sample = ((np.asarray(image).astype(np.float32) - 127.5) / 127.5).transpose(2, 0, 1)[None]
            embedding = session.run(None, {input_name: sample})[0].reshape(-1)
            embedding /= np.linalg.norm(embedding)
            (args.fixtures / (name + "-112.json")).write_text(json.dumps(embedding.tolist()) + "\n")
    report = {"source_revision": REVISION, "source_sha256": SOURCE_SHA256,
              "torch_cosine": torch_parity, "coreml_cosine": parity,
              "coremltools": ct.__version__, "torch": torch.__version__}
    args.output.with_suffix(".parity.json").write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    main()
