# ARKit + motors: navigation qualification

This is a separate experimental track from person recognition (`PersonCamera` / Gemini ER2)
and from the CyberPi sensor-qualification harness. The first deliverable is **measurement, not
autonomous motion**. `Rocky/Sources/Navigation/ARKitPoseProbe.swift` runs an ARKit world-tracking
session on the iPhone and records its pose/tracking state alongside commands from the existing
manual-drive UI. No new board firmware or transport is required for this stage.

## Working architecture

1. **Local pose loop:** ARKit rear-camera world tracking supplies metric 6-DoF phone
   pose and a tracking-state signal. Convert phone pose to a planar robot-base pose after measuring
   the rigid phone-to-base mounting transform. A camera looking sideways or backward is workable;
   that transform, not camera orientation alone, defines robot-forward.
2. **Action feedback:** a phone-side controller issues short, bounded drive commands using the
   existing `BehaviorMonitor` newest-state UDP protocol, compares observed pose to the predicted
   result, then updates its motor baseline. Commanded throttle/time is a prior, not proof of
   displacement. Keep command acceptance, visual observation, and ground truth separate.
3. **Semantic layer:** Gemini ER2 can recognize a taught destination or landmark and choose a
   nearby waypoint; it does not close the fast motor loop. GeminiER versus GeminiER +
   gpt-realtime changes conversation, not the pose/control boundary.
4. **Safety:** a future navigation owner must arbitrate with manual input and the board's autonomy.
   It must send fresh bounded commands, stop on lost tracking/link/app background, and retain the
   board's 650 ms lost-stream stop. Obstacle and cliff detection need their own qualification;
   ARKit pose alone does not establish traversability.

The existing person camera uses the front lens while ARKit world tracking uses the rear. The
probe requires voice to be paused; starting voice stops the probe. We will test physical phone
orientation/mounting before designing a multi-camera or camera-switching feature. ARKit pose is
relative to each session's arbitrary origin, so a saved destination also needs a relocalization
strategy before it can work across sessions.

## How to run the observational probe

1. Mount the iPhone rigidly on Rocky with the rear camera unobstructed and able to see textured
   room features. Note lens height, yaw relative to robot-forward, and whether the screen/face
   is still usable. Keep voice paused and the robot on a clear, level floor.
2. Open Rocky, connect the robot, expand the lower-left state chip, then tap **ARKit probe**.
   Camera permission is requested if needed. The status chip shows ARKit tracking state.
   The details panel closes so the existing spring-return drive/steer controls remain usable.
3. Place tape marks and record each trial's measured ground truth in a notebook. Expand the chip
   and tap **mark trial** at each trial boundary; the mark is written to the JSONL trace. Drive
   manually. Release the control and verify physical stop each time. Tap **stop ARKit probe** at
   the end. App inactivity, robot disconnect, voice camera startup, and ARKit failure also stop
   the probe.
4. The app shows the `Documents/navigation-probe-<timestamp>.jsonl` filename. Pull it with
   `xcrun devicectl device copy from --device <id> --domain-type appDataContainer
   --domain-identifier family.rocky.ios --source Documents/<filename>
   --destination /private/tmp/<filename>`. Each line is a timestamped `start`, `pose`, `drive`,
   `mark`, or `stop` record. Pose is sampled at 10 Hz from ARKit; frame timestamps, wall clock,
   and system uptime are all retained. `x_m/y_m/z_m` are camera position in ARKit world space;
   `forward_x/z` are its horizontal forward vector; `camera_matrix_col_major` retains the full
   6-DoF transform for fitting a tilted/sideways phone mount later. The trace also counts ARKit
   callbacks between logged samples. No images or video are saved.
   Run `pnpm ios:nav:analyze <path-to-pulled-jsonl>` for per-mark tracking coverage, sample
   rate/gaps, trajectory length, endpoint displacement, and heading change. Compare those ARKit
   quantities with tape measurements; the script cannot infer ground-truth error by itself.

The probe logs **commands passed to the existing manual-drive path**, not proof of motor
application. The normal session log contains correlated board acceptance reports. Compare those
timelines before attributing delay to either ARKit or motors.

On the iPhone 14 Pro, run matched trials with **+ depth**. This requests ARKit's LiDAR scene-depth
stream and logs whether depth was available; it does not change motor control. The standard mode
does not request depth, but ARKit may still use the phone's hardware internally for tracking.
Therefore this A/B measures the **incremental benefit and cost of explicitly requesting scene
depth**, not a strict camera-only-versus-LiDAR comparison. Keep depth optional unless it
materially improves an actual task (especially traversability/obstacle detection) enough to
justify power, compute, and device restrictions. Use feature detection, not an iPhone-model check.

## Experiment matrix and decisions

| Stage | Trial | Measure | Decision |
| --- | --- | --- | --- |
| A — bench | Hand-carry mounted, motors off: 0.5 m, 1 m, 90° turn, square loop, return to start; repeat on textured floor, low-texture floor, and dim room. Repeat matched runs with explicit scene depth on the 14 Pro. | endpoint/heading error vs tape marks, loop closure error, normal-tracking fraction, limited/unavailable spans, relocalization behavior, depth availability and pose rate | Determine whether this mount/lens produces a stable pose before introducing motor or Wi-Fi uncertainty, and whether requesting depth adds value. |
| B — motor baseline | Clear floor; 10 repeats each of short straight and in-place turn commands at two battery levels, then hard floor and carpet. Mark actual start/stop and tape-measured endpoint. | commanded vs observed distance/angle distribution, stop overshoot, initial deadband, slip, pose update age | Fit separate forward/turn response and uncertainty; do not assume left/right symmetry or constant RPM-to-distance. |
| C — feedback rehearsal | Human drives a taped path with several short corrections, then a square and a return-to-start. | how often visual correction would reverse/update a motor prediction; tracking failures during blur/turns; accumulated error | If ARKit remains normal and metric error stays within the waypoint margin, implement bounded closed-loop commands. |
| D — concurrent load | Repeat B/C with voice and Gemini visual work only after camera coexistence is explicitly designed; test heat and sustained runtime. | frame/pose rate, latency, thermal throttling, camera contention | Choose camera scheduling or separate capture only with actual measurements. |
| E — navigation | Teach one named place, revisit same-session, then after app restart; add small obstacle/cliff test with independent safety supervision. | goal arrival error, reacquisition time, false localization, stop distance | Decide whether ARKit local mapping is enough or place recognition / depth / other sensor is required. |

Provisional go/no-go targets for **Stage A/B only**: at least 95% normal tracking over a typical
short indoor route; no unreported jump >0.2 m while stationary; 1 m endpoint error ≤0.15 m and
90° turn error ≤10° at p95; stop overshoot measurable and bounded below the intended clearance.
These are engineering hypotheses, not ARKit guarantees. If the mount fails, first try a different
rear-camera orientation and scene texture, then compare a front-camera/custom-VIO route only if
the physical layout demands it. If tracking fails mainly on turns, slow the turn and retest. If
tracking is sound but motor variance is high, use shorter pulses and more frequent visual updates.

## Integration gate after measurements

The next code increment should define a `PoseEstimate` (position, heading, timestamp, tracking
quality), `MotionObservation` (command interval, board acknowledgment, pose delta), and a single
`DriveOwner` arbitration point. A bounded navigation controller may own the existing UDP drive
stream only after manual override, disconnect, backgrounding, low tracking confidence, stale
pose, and stop behavior have deterministic tests. Its first live run should be one operator-armed
short motion in an empty area, not a general destination request. Only then layer in taught
places, ER2 waypoint selection, and traversability sensing.

Apple reference: [ARWorldTrackingConfiguration](https://developer.apple.com/documentation/arkit/arworldtrackingconfiguration),
[ARSessionDelegate](https://developer.apple.com/documentation/arkit/arsessiondelegate),
[scene depth and device feature detection](https://developer.apple.com/documentation/arkit/arconfiguration/framesemantics-swift.struct/scenedepth),
[tracking quality and interruptions](https://developer.apple.com/documentation/arkit/managing-session-life-cycle-and-tracking-quality).
