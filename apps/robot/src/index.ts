// ⚠️ DEPRECATED with apps/robot/deprecated/motion_agent.py, the commanded-motion payload this
// protocol speaks to. Nothing live uses it: the one payload that runs
// (apps/robot/device/rocky_agent.py) has its own newline-JSON event stream, and the iOS app talks
// to that directly. Kept as the protocol's reference implementation and, in its tests, the record
// of the wire format -- but do not build anything new on it.
export { Robot, RobotCommandError, RobotTimeoutError, type RobotOptions } from "./robot.ts";
export {
  boundCommand,
  DEFAULT_SPEED,
  DRIVE_DISTANCE_MAX_CM,
  PROTOCOL_VERSION,
  SPEED_MAX,
  SPEED_MIN,
  TURN_DEGREES_MAX,
  type CommandMessage,
  type FaceState,
  type TelemetryMessage,
} from "./protocol.ts";
export { MockTransport, TcpTransport, type Transport, type TcpTransportOptions } from "./transport.ts";
