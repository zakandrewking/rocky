#!/usr/bin/env node
import { readFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';

const distance = (a, b) => Math.hypot(a.x_m - b.x_m, a.z_m - b.z_m);
const degrees = (radians) => radians * 180 / Math.PI;
const wrappedDegrees = (angle) => ((angle + 180) % 360 + 360) % 360 - 180;
const heading = (pose) => degrees(Math.atan2(pose.forward_x, pose.forward_z));
const fixed = (number, digits = 2) => Number(number.toFixed(digits));

function summarizeSegment(label, records) {
  const poses = records.filter((record) => record.type === 'pose');
  const drives = records.filter((record) => record.type === 'drive');
  if (poses.length === 0) return { label, poses: 0, drives: drives.length };
  const first = poses[0];
  const last = poses.at(-1);
  let path = 0;
  let largestStep = 0;
  let largestGap = 0;
  for (let i = 1; i < poses.length; i++) {
    const step = distance(poses[i - 1], poses[i]);
    path += step;
    largestStep = Math.max(largestStep, step);
    largestGap = Math.max(largestGap, poses[i].frame_time_s - poses[i - 1].frame_time_s);
  }
  const span = Math.max(0, last.frame_time_s - first.frame_time_s);
  return {
    label,
    poses: poses.length,
    drives: drives.length,
    span_s: fixed(span),
    sampled_hz: span > 0 ? fixed((poses.length - 1) / span, 1) : null,
    arkit_callback_hz: span > 0
      ? fixed(poses.slice(1).reduce((total, pose) => total + (pose.frame_callbacks_since_last ?? 1), 0) / span, 1)
      : null,
    normal_pct: fixed(poses.filter((pose) => pose.tracking === 'normal').length * 100 / poses.length, 1),
    depth_pct: fixed(poses.filter((pose) => pose.scene_depth_available).length * 100 / poses.length, 1),
    path_m: fixed(path),
    endpoint_m: fixed(distance(first, last)),
    heading_change_deg: fixed(wrappedDegrees(heading(last) - heading(first)), 1),
    largest_step_m: fixed(largestStep),
    largest_gap_s: fixed(largestGap),
  };
}

export function summarize(records) {
  const start = records.find((record) => record.type === 'start');
  const segments = [];
  let current = [];
  let label = 'initial';
  let index = 0;
  for (const record of records) {
    if (record.type === 'mark' || record.type === 'stop') {
      segments.push(summarizeSegment(label, current));
      current = [];
      if (record.type === 'mark') label = `${record.label || 'trial'} ${++index}`;
    } else if (record.type !== 'start') {
      current.push(record);
    }
  }
  if (current.length) segments.push(summarizeSegment(label, current));
  return { mode: start?.mode ?? 'unknown', segments };
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const path = process.argv[2];
  if (!path) {
    console.error('Usage: node apps/ios/scripts/analyze-navigation-probe.mjs <navigation-probe.jsonl>');
    process.exitCode = 2;
  } else {
    try {
      const records = readFileSync(path, 'utf8').trim().split('\n').filter(Boolean).map(JSON.parse);
      const result = summarize(records);
      console.log(`mode: ${result.mode}`);
      console.table(result.segments);
      console.log('Endpoint/heading are ARKit-relative, not ground-truth error. Compare with tape marks.');
    } catch (error) {
      console.error(error.message);
      process.exitCode = 1;
    }
  }
}
