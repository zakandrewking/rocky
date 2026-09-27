import assert from 'node:assert/strict';
import test from 'node:test';
import { summarize } from './analyze-navigation-probe.mjs';

test('segments a marked trace and reports tracking, depth, and planar motion', () => {
  const report = summarize([
    { type: 'start', mode: 'scene-depth' },
    { type: 'pose', frame_time_s: 0, x_m: 0, z_m: 0, forward_x: 0, forward_z: 1, tracking: 'normal', scene_depth_available: true },
    { type: 'pose', frame_time_s: 0.1, x_m: 0, z_m: 1, forward_x: 1, forward_z: 0, tracking: 'limited:excessiveMotion', scene_depth_available: false },
    { type: 'mark', label: 'trial' },
    { type: 'drive', active: true },
    { type: 'pose', frame_time_s: 0.2, x_m: 1, z_m: 1, forward_x: 1, forward_z: 0, tracking: 'normal', scene_depth_available: true },
    { type: 'stop' },
  ]);
  assert.equal(report.mode, 'scene-depth');
  assert.equal(report.segments.length, 2);
  assert.equal(report.segments[0].normal_pct, 50);
  assert.equal(report.segments[0].depth_pct, 50);
  assert.equal(report.segments[0].endpoint_m, 1);
  assert.equal(report.segments[0].heading_change_deg, 90);
  assert.equal(report.segments[1].drives, 1);
  assert.equal(report.segments[1].poses, 1);
});
