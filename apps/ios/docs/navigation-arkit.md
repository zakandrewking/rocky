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

## Phone-only environment scouting (first)

No robot or mount is needed for this pass. With voice paused, expand the state chip and tap
**ARKit probe**. The live rear-camera view opens with ARKit's feature-point dots, tracking state,
normal-tracking percentage, and sample count. Nothing in the image is saved. **Keep logging**
closes the view without ending the probe; **Stop** ends the probe. The screen remains awake only
while the app is foregrounded, so do not lock the phone during a trial.

Hold the phone in portrait near the *intended* camera height and angle. Point it at static,
well-lit room features at several distances: furniture edges, door frames, wall art, shelving,
and some textured floor. Avoid a frame dominated by a blank wall, dark floor, close-up robot
body, mirror, or moving people. Start with 20–30 seconds still, then **Mark trial** and walk
about 1 m smoothly, then turn 90° right and pause. Retrace to the start mark if you want to
measure loop closure. Repeat the same motion in a less textured or dimmer area, marking the
boundary. Watch for `limited:insufficientFeatures` or
`limited:excessiveMotion`; after the test, compare normal-tracking fraction and path closure in
the trace. A large number of dots alone is not a calibrated quality measure—Apple says the point
cloud can vary between frames and software releases.

This scouts whether *environments and camera viewpoints* work for ARKit. It does **not** qualify
the rigid phone-to-robot transform, actual mounted camera occlusion/vibration, or motor response.
Those are the following trials.

## Mounted observational probe

1. Mount the iPhone rigidly on Rocky with the rear camera unobstructed and able to see textured
   room features. Note lens height, yaw relative to robot-forward, and whether the screen/face
   is still usable. Keep voice paused. For Stage A, the robot may remain powered off: carry the
   rigidly mounted phone/base by hand over a clear, level floor.
2. Open Rocky, expand the lower-left state chip, then tap **ARKit probe**. A robot connection is
   needed only for Stage B/C motor trials; the standard drive controls appear when connected.
   Camera permission is requested if needed. The live camera/feature-point view opens; tap
   **Keep logging** to dismiss it and regain the existing spring-return drive/steer controls.
3. Place tape marks and record each trial's measured ground truth in a notebook. Expand the chip
   and tap **mark trial** at each trial boundary; the mark is written to the JSONL trace. For
   Stage A, carry the mounted base by hand. For motor trials, drive with the existing sliders,
   releasing them and verifying physical stop after each motion. Tap **stop ARKit probe** at
   the end. App inactivity, voice camera startup, and ARKit failure also stop the probe; robot
   link changes are recorded without stopping a phone-only trial.
4. The app shows the `Documents/navigation-probe-<timestamp>.jsonl` filename. Pull it with
   `xcrun devicectl device copy from --device <id> --domain-type appDataContainer
   --domain-identifier family.rocky.ios --source Documents/<filename>
   --destination /private/tmp/<filename>`. Each line is a timestamped `start`, `pose`, `drive`,
   `mark`, `robot_link`, or `stop` record. Pose is sampled at 10 Hz from ARKit; frame timestamps, wall clock,
   and system uptime are all retained. `x_m/y_m/z_m` are camera position in ARKit world space;
   `forward_x/z` are its horizontal forward vector; `camera_matrix_col_major` retains the full
   6-DoF transform for fitting a tilted/sideways phone mount later. The trace also counts ARKit
   callbacks and visible feature-point count between logged samples. No images or video are saved.
   Run `pnpm ios:nav:analyze <path-to-pulled-jsonl>` for per-mark tracking coverage, sample
   rate/gaps, trajectory length, endpoint displacement, and heading change. Compare those ARKit
   quantities with tape measurements; the script cannot infer ground-truth error by itself.

The probe logs **commands passed to the existing manual-drive path**, not proof of motor
application. The normal session log contains correlated board acceptance reports. Compare those
timelines before attributing delay to either ARKit or motors.

On the iPhone 14 Pro, run matched trials with **+ depth**. This requests ARKit's LiDAR scene-depth
stream and logs whether depth was available; it does not change motor control. The live view opens
on a false-colour depth image (red near, blue far, dark for low-confidence or missing data), with
**Camera** and **Depth** buttons to switch displays. The colour scale clips at 0.2–4 m, so it is
a visual diagnostic, not an obstacle or free-space judgment; no depth frames are saved. The
standard mode does not request depth, but ARKit may still use the phone's hardware internally
for tracking.

For the first powered baseline, the depth view has **FORWARD TEST · 0.6s** and **STOP ROBOT**.
This is one operator-started, 22%-throttle pulse using the existing newest-state manual-drive
path, not autonomous navigation. The phone targets a stop after 0.6 s, or sooner if its
camera moves 0.2 m, tracking/depth becomes stale or limited, the robot link drops, or the board
leaves still mode. The board's lost-stream watchdog is a separate backstop. The test requires a
clear floor, a rigid phone mount, voice paused/board still, and someone at the physical power
switch. It does not classify obstacles or cliffs; do not run it near people, pets, edges, or stairs.
The trace marks pulse start/stop and records the sent drive state for comparison with board ACKs
and tape-measured displacement. **STOP ROBOT** sends both a zero drive state and the board stop
imperative. Ending the probe stops the robot first.

The first mounted run gave five repeatable forward pulses: ARKit summed about 35.5 cm and floor
marks showed about 14 in (35.6 cm). All five forward starts were board-acknowledged; tracking and
depth stayed normal. Physical stopping looked prompt, but the trace does not yet distinguish pose
settling from command timing after Stop, and board stop-ACK timing remains unverified. This is a
straight-line baseline on one floor, not a navigation safety qualification.

The next baseline is **RIGHT TURN TEST · 0.5s** in the same depth view. It sends 22% right
steering with zero throttle through the existing manual-drive path, requesting a stop after 0.5 s
or earlier at 35° ARKit heading change, 0.1 m camera travel, or any existing link/tracking/depth
failure. These are stop triggers, **not final-angle caps**: the first four taps ended at roughly
78°, 70°, 38°, and 40° according to ARKit. The operator saw no coasting; variable command timing
and pose settling have not yet been separated. Mark the chassis heading
on the floor, run only one tap initially with a spotter and clear space, and compare physical
direction/angle with the recorded ARKit trace before attempting repeated turns or a 90° turn.
The view shows the live ARKit angle relative to the most recent turn start, including after the
motors stop; use the settled reading rather than the value at the instant Stop is sent.
The navigation trace now records `control_sent` and `control_applied` events with matching sequence
numbers, including reported repeated-stop frames. `control_applied` is timestamped when the phone
receives the board's report, so its round-trip latency is an upper bound on application time, not
the exact instant the motors stopped. Until a marked single-turn test correlates those events with
physical motion, avoid repeated turn taps.

For the next *isolated* timing test, load the disposable
`apps/robot/steps/step19_navigation_sensor_qualification.py` payload instead of Rocky's normal
robot payload. The depth view's **BOARD CLOCK TURN · 0.2s** button handshakes with that payload
on TCP 8770 and allows one 33 RPM right spin per view. The board itself stops after 200 ms; a
disconnect or the screen's Stop button asks it to stop sooner. The `clock_only` handshake bypasses
CyberPi yaw and ultrasonic reads during the motor-deadline path. The normal drive buttons are
unavailable while this disposable payload is loaded. Mark the chassis heading, keep someone at
the power switch, and compare the settled ARKit angle with a floor mark. Restore
`apps/robot/device/rocky_agent.py` afterward; this is not yet a production navigation command.
In the first mounted run, two 33 RPM / 200 ms requests produced settled ARKit turns of 28.4° and
29.0°; the floor estimate was about 29°. The board reported local `complete` after 312 and
313 ms measured from *before* the start motor call to *after* the stop motor call, not 200 ms.
That interval includes motor API time and loop scheduling, so it does not establish how long the
wheels were physically turning. Its outcome was consistent across these two trials, but the
actual deadline lateness must be measured and bounded before this becomes a navigation stop
limit. A third mounted turn with the timing-instrumented payload settled at 29.6° in ARKit
versus about 30° from the floor mark, with normal tracking and depth. Its board report showed
`complete`, a 309 ms pre-start-call-to-report span, and a stop call begun 107 ms after the 200 ms
deadline. About 2 ms remained for the stop call and report timestamp. The trace did not retain
the raw `start_return_t`, `stop_call_t`, and `stop_return_t` fields, so this run cannot split
motor-start-call time from tick scheduling. The iOS trace now records them for the next run.
Rocky's normal payload was restored and its still/listening hello verified afterward.

Therefore this A/B measures the **incremental benefit and cost of explicitly requesting scene
depth**, not a strict camera-only-versus-LiDAR comparison. Keep depth optional unless it
materially improves an actual task (especially traversability/obstacle detection) enough to
justify power, compute, and device restrictions. Use feature detection, not an iPhone-model check.

## Experiment matrix and decisions

| Stage | Trial | Measure | Decision |
| --- | --- | --- | --- |
| A — bench | Hand-carry mounted, robot powered off: 0.5 m, 1 m, 90° turn, square loop, return to start; repeat on textured floor, low-texture floor, and dim room. Repeat matched runs with explicit scene depth on the 14 Pro. | endpoint/heading error vs tape marks, loop closure error, normal-tracking fraction, limited/unavailable spans, relocalization behavior, depth availability and pose rate | Determine whether this mount/lens produces a stable pose before introducing motor or Wi-Fi uncertainty, and whether requesting depth adds value. |
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
[tracking quality and interruptions](https://developer.apple.com/documentation/arkit/managing-session-life-cycle-and-tracking-quality),
and [feature-point debugging](https://developer.apple.com/documentation/arkit/arframe/rawfeaturepoints).
