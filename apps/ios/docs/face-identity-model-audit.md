# Face identity model audit

Status: experimental live MVP enabled for explicitly saved friends; population accuracy and
sustained conversation/thermal qualification remain open.

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
with this one hardware-only inference test skipped.

The focused physical-device suite then passed both tests on the iPhone 14 Pro (iPhone15,2), iOS
27.0.1 build 24A446, using Xcode 26.2. Revision 2 produced 768 floats and exactly repeated the first
fixture vector. Same-identity distances were 0.1960, 0.1477, and 0.1472; cross-identity distances
were 0.5562, 0.5134, and 0.7052. The slowest of six extractions was 188.15 ms, including the first
cold extraction. This tiny synthetic-fixture run establishes neither warm p50/p95 nor real-person
recognition quality; the representative-device evaluation gate remains open.

Before this baseline can advance:

1. Capture explicitly consented, temporary real-device evaluation crops from several enrolled and
   unknown adults under pose, distance, and lighting variation; do not commit or retain them after
   aggregate measurements are recorded.
2. Record vector dimensions, same-person and different-person distributions, p50/p95 warm latency,
   phone model, iOS build, and thermal behavior.
3. Reject this baseline if identity separation is weak even when crops are aligned. General image
   similarity may over-weight hair, clothing, or background; a clean license does not make it a
   face recognizer.

## Temporary capture lab

The state-chip **face test lab** runs separately from conversation and `PersonCamera`. It pauses
voice, stops other camera probes, and uses Apple's still-camera UI for each deliberate capture.
Vision face-landmarks revision 3 requires exactly one face and two visible eye regions. Their
centers determine a similarity transform onto a 320×320 crop (eyes at 104/200 and 216/200), called
`eyes-320-v1`. Crops crossing the source boundary or eye separation below 24 source pixels are
rejected. This normalizes scale and roll; it does not reconstruct a frontal face from yaw.

The first capture becomes an in-memory reference. Subsequent captures are explicitly labeled by
the tester as the same or a different person; the UI shows distances and whether the observed
ranges overlap, without applying a recognition threshold. Raw captures are discarded after
processing. No lab images, embeddings or scores enter file storage, logs, network requests, or
backup. Reset, dismissal and backgrounding invalidate pending work and clear retained vectors and
results. A pending native Vision request may finish after cancellation, but its result is discarded.
At most 100 comparisons are retained.

The live MVP adds an explicit **Remember this face** action that persists the reference, name,
algorithm revision, preprocessing version and iOS major in the protected local friend vault.
Temporary lab reset never deletes saved friends; Forget/Clear do. See the README for portable
encrypted backup and restore. No raw images are saved. Unlike the temporary experiment, saved
templates deliberately survive application relaunch.

The displayed feature-print latency excludes camera interaction, landmark detection and image
normalization. User-paced capture percentiles are preliminary; they do not replace a sustained
warm p50/p95/thermal benchmark. The aligned lab's results are a separate experiment from the raw
synthetic-crop probe above. Any eventual identity vault must record both preprocessing and model
versions and reject comparisons across them.

The aligned synthetic-fixture pipeline passed on the iPhone 14 Pro, iOS 27.0.1 (24A446), on
2026-11-03. Same-identity distances were 0.2557, 0.2779 and 0.2642; cross-identity distances were
0.6122, 0.4894 and 0.7670. All six focused device tests passed, including comparison bookkeeping,
alignment geometry and invalidation of pending work on reset. These synthetic results validate
the capture-processing path, not camera UI behavior or real-person accuracy.

## Live MVP decision

The person confirmed the real-camera lab works and asked to incorporate it into live conversation.
Use the existing system baseline experimentally: threshold 0.32, margin 0.10 against the next
closest person, and three consecutive matches. These are conservative starting values informed
by the synthetic separation, not calibrated false-accept/false-reject rates. Unknown or multiple
faces never receive a guessed name. No adaptive enrollment occurs.

An independent local sampling lane reuses the continuous front-camera stream and the same upright,
unmirrored, eye-aligned preprocessing. It permits one in-flight request, drops rather than queues,
and pauses recognition at serious/critical thermal pressure. Only stable state transitions enter
conversation context, with explicit uncertainty replacing old identities. Face recognition does
not identify the speaker. A delayed, cooldown-limited greeting is allowed in a quiet moment; normal
conversation and stories keep priority. Face embeddings never enter the conversation or scene API.

## Camera-domain correction (2026-11-04)

Real conversation rejected the enrolled person, including near-identical reference attempts. The
original lab gate did not establish real live acceptance. A physical-device regression isolated a
transport mismatch: encoding the exact same synthetic source as a 480px JPEG scored
0.3925–0.4028 against the original, above the 0.32 cutoff. Equalizing input resolution alone still
scored 0.3400–0.3827 for JPEG; the corresponding lossless PNG scored exactly 0.0000 for all three
fixtures. This baseline is sensitive to JPEG artifacts as well as input sampling scale.

`camera-480-eyes-320-v2` therefore uses lossless memory-only PNG in both enrollment and the local
video lane, normalizes the maximum input edge to 480px, rasterizes to RGBA8 device RGB, then runs
the existing landmarks/alignment/feature request. Gemini retains its separate existing JPEG lane.
Per-descriptor preprocessing tags prohibit cross-pipeline comparisons. Legacy vaults remain
readable/exportable; saving a fresh capture under an existing name replaces only that friend's
obsolete templates while preserving identity and other profiles. No photos are available to
automatically regenerate legacy templates. The cutoff remains unchanged. Synthetic known/unknown
checks and exact-source lossless transport checks do not replace the pending real-person trial.
At the person's explicit request, live diagnostics now record a bounded five-second scalar trend
(latest/min/mean/max difference, cutoff, sample count, profile ordinal, decision) and configured
profile counts. No names, photos, or vectors are added to these diagnostics.
