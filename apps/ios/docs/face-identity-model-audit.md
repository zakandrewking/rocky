# Face identity model audit

Status: first baseline selected for measurement, not approved for production recognition.

## Requirements

Rocky needs an on-device vector for an already detected and aligned face crop. The artifact must
have redistributable weights with credible provenance, a version that can be pinned in every saved
profile, deterministic preprocessing, and practical latency on the mounted iPhone. A model is not
accepted merely because its source code has a permissive license; its weights and training-data
terms matter separately.

## 2026-11-03 audit

### Apple Vision Image Feature Print revision 2 — probe baseline

- Ships as part of iOS; Rocky redistributes no third-party weights.
- `VNGenerateImageFeaturePrintRequest` is available on the app's iOS 17 deployment target and
  exposes the feature print's float data directly. The synchronous Vision API avoids sending
  CreateMLComponents' explicitly non-Sendable extractor across an async Swift 6 boundary.
- Revision 2 is explicitly pinned rather than using `latestRevision`; stored vectors identify the
  algorithm as `apple.vision.image-feature-print` and the revision as `2`.
- Apple documents it as general semantic image similarity, not face verification. It is therefore
  only a cheap baseline until private real-device face trials show useful open-set separation.
- No model hash or compute-unit choice is exposed for this system model. The reproducibility key is
  the public request revision, and benchmark evidence must also record the iOS build and hardware.

Sources: [Apple ImageFeaturePrint](https://developer.apple.com/documentation/createmlcomponents/imagefeatureprint),
[Vision feature-print request](https://developer.apple.com/documentation/vision/vngenerateimagefeatureprintrequest),
and [Apple's image-similarity sample](https://developer.apple.com/documentation/vision/analyzing-image-similarity-with-feature-print).

### InsightFace / ArcFace pretrained packs — rejected

InsightFace's implementation is MIT, but its supplied pretrained models are explicitly restricted
to non-commercial research. Rocky must not make a future distribution decision depend on a
personal-project assumption, so `buffalo_*`, `antelopev2`, and other public InsightFace packs are
out unless a suitable separate model license is obtained and recorded.

Source: [InsightFace model licensing](https://github.com/deepinsight/insightface/blob/master/python-package/docs/model_zoo.md#model-licenses).

### OpenCV Zoo SFace — held, not approved

OpenCV Zoo places the SFace directory and ONNX artifact under Apache-2.0, which is much clearer than
most public face-recognition weights. However, as of this audit, maintainers have not resolved the
open questions about the shipped weights' training dataset and upstream authorization. Keep SFace
as a potential custom-Core-ML fallback, but do not download, convert, or commit it until that record
is resolved satisfactorily.

Sources: [OpenCV SFace model card](https://github.com/opencv/opencv_zoo/tree/main/models/face_recognition_sface)
and [open provenance/authorization question](https://github.com/opencv/opencv_zoo/issues/318).

## Probe contract

`FaceFeaturePrintProbe` accepts a pre-cropped `CIImage`, applies revision 2 with `.scaleFill`, and
returns a versioned float vector plus elapsed inference time. It never touches `PersonCamera`, the
network, enrollment, or persisted user data. Unit tests use generated fictional adults only and
cover deterministic extraction, vector serialization, compatibility rejection, and basic fixture
separation.

The iOS 26.2 simulator cannot create the Vision feature-print Espresso context. The vector and
fixture-separation test is therefore explicitly device-only; portable descriptor serialization and
compatibility tests still run in the simulator. A skipped simulator inference test is not evidence
for the model and does not satisfy the milestone's physical-device gate.

The complete iPhone 17 / iOS 26.2 simulator suite passed on 2026-11-03: 169 tests, zero failures,
with this one hardware-only inference test skipped. The first iPhone 14 Pro attempt reached the
device but was blocked by Xcode device preparation and test-target signing; those tooling failures
are not model results and the physical-device gate remains open.

Before this baseline can advance:

1. Capture explicitly consented, temporary real-device evaluation crops from several enrolled and
   unknown adults under pose, distance, and lighting variation; do not commit or retain them after
   aggregate measurements are recorded.
2. Record vector dimensions, same-person and different-person distributions, p50/p95 warm latency,
   phone model, iOS build, and thermal behavior.
3. Reject this baseline if identity separation is weak even when crops are aligned. General image
   similarity may over-weight hair, clothing, or background; a clean license does not make it a
   face recognizer.
