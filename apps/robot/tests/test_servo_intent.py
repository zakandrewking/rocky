import ast
import pathlib
import unittest


class FakeMbot2:
    def __init__(self, error=None):
        self.servo_calls = []
        self.drive_calls = []
        self.error = error

    def servo_set(self, angle, port):
        self.servo_calls.append((angle, port))
        if self.error:
            raise self.error

    def drive_speed(self, left, right):
        self.drive_calls.append((left, right))
        if self.error:
            raise self.error


class FakeTime:
    @staticmethod
    def ticks_add(now, delta):
        return now + delta


def load_apply_intent(mbot2, distance_cm=100):
    source = pathlib.Path(__file__).parents[1] / "device" / "rocky_agent.py"
    tree = ast.parse(source.read_text())
    function = next(
        node
        for node in tree.body
        if isinstance(node, ast.FunctionDef) and node.name == "_apply_intent"
    )
    emitted = []
    errors = []
    state = {
        "gesture_queue": ["spin"],
        "intentional_motion": True,
        "manual_drive_active": False,
        "manual_drive_until": 0,
        "manual_handoff_until": 0,
        "manual_left_rpm": 0,
        "manual_right_rpm": 0,
        "level": 1.0,
        "rpm": 100,
        "drive_started": 1,
        "return_to": "exploring",
    }
    namespace = {
        "mbot2": mbot2,
        "utime": FakeTime,
        "_state": state,
        "_emit": emitted.append,
        "_report_error_once": lambda name, error: errors.append((name, str(error))),
        "_distance_cm": lambda: distance_cm,
        "_enter": lambda *_args: None,
        "HAS_ULTRASONIC": True,
        "OBSTACLE_STOP_CM": 15,
        "MANUAL_DRIVE_MAX_RPM": 150,
        "MANUAL_DRIVE_WATCHDOG_MS": 650,
        "MANUAL_DRIVE_HANDOFF_MS": 700,
    }
    exec(compile(ast.Module(body=[function], type_ignores=[]), str(source), "exec"), namespace)
    return namespace["_apply_intent"], emitted, errors, state


class ServoIntentTests(unittest.TestCase):
    def test_s3_and_s4_are_bounded_and_acknowledged(self):
        mbot2 = FakeMbot2()
        apply_intent, emitted, errors, _state = load_apply_intent(mbot2)

        apply_intent({"type": "servo", "port": "s3", "angle": -9, "id": "a"}, 123)
        apply_intent({"type": "servo", "port": "S4", "angle": 900, "id": "b"}, 124)

        self.assertEqual(mbot2.servo_calls, [(0, "S3"), (180, "S4")])
        self.assertEqual([reply["angle"] for reply in emitted], [0, 180])
        self.assertEqual(errors, [])

    def test_other_ports_are_never_touched(self):
        mbot2 = FakeMbot2()
        apply_intent, emitted, _errors, _state = load_apply_intent(mbot2)

        apply_intent({"type": "servo", "port": "S2", "angle": 90}, 123)

        self.assertEqual(mbot2.servo_calls, [])
        self.assertEqual(emitted, [])

    def test_hardware_failure_returns_correlated_diagnostic(self):
        mbot2 = FakeMbot2(RuntimeError("servo bus unavailable"))
        apply_intent, emitted, errors, _state = load_apply_intent(mbot2)

        apply_intent({"type": "servo", "port": "S3", "angle": 42, "id": "failed"}, 125)

        self.assertEqual(mbot2.servo_calls, [(42, "S3")])
        self.assertFalse(emitted[0]["ok"])
        self.assertEqual(emitted[0]["id"], "failed")
        self.assertEqual(errors, [("servo_failed", "servo bus unavailable")])


class ManualDriveIntentTests(unittest.TestCase):
    def test_drive_mix_preempts_autonomy(self):
        mbot2 = FakeMbot2()
        apply_intent, emitted, _errors, state = load_apply_intent(mbot2)

        apply_intent(
            {"type": "manual_drive", "throttle": 1, "active": True, "id": "forward"},
            1_000,
        )
        apply_intent(
            {"type": "manual_drive", "steering": 1, "active": True, "id": "turn"},
            1_100,
        )

        self.assertEqual(mbot2.drive_calls, [(150, -150), (150, 150)])
        self.assertEqual(state["gesture_queue"], [])
        self.assertFalse(state["intentional_motion"])
        self.assertTrue(state["manual_drive_active"])
        self.assertEqual(state["manual_drive_until"], 1_750)
        self.assertEqual([reply["id"] for reply in emitted], ["forward", "turn"])

    def test_release_stops_immediately_then_delays_handoff(self):
        mbot2 = FakeMbot2()
        apply_intent, emitted, _errors, state = load_apply_intent(mbot2)

        apply_intent({"type": "manual_drive", "active": False, "id": "released"}, 2_000)

        self.assertEqual(mbot2.drive_calls, [(0, 0)])
        self.assertFalse(state["manual_drive_active"])
        self.assertEqual(state["manual_handoff_until"], 2_700)
        self.assertEqual(emitted[0]["handoff_ms"], 700)

    def test_forward_obstacle_stop_still_allows_reverse(self):
        mbot2 = FakeMbot2()
        apply_intent, emitted, _errors, _state = load_apply_intent(mbot2, distance_cm=8)

        apply_intent({"type": "manual_drive", "throttle": 1, "active": True}, 10)
        apply_intent({"type": "manual_drive", "throttle": -1, "active": True}, 20)

        self.assertEqual(mbot2.drive_calls, [(0, 0), (-150, 150)])
        self.assertEqual(emitted, [])

    def test_uncorrelated_heartbeat_renews_watchdog_without_ack(self):
        mbot2 = FakeMbot2()
        apply_intent, emitted, _errors, state = load_apply_intent(mbot2)

        apply_intent({"type": "manual_drive", "throttle": 0.4, "active": True}, 100)

        self.assertEqual(state["manual_drive_until"], 750)
        self.assertEqual(emitted, [])

    def test_stop_clears_manual_ownership(self):
        mbot2 = FakeMbot2()
        apply_intent, _emitted, _errors, state = load_apply_intent(mbot2)
        state["manual_drive_active"] = True
        state["manual_handoff_until"] = 9_999

        apply_intent({"type": "stop"}, 30)

        self.assertEqual(mbot2.drive_calls, [(0, 0)])
        self.assertFalse(state["manual_drive_active"])
        self.assertEqual(state["manual_handoff_until"], 0)


if __name__ == "__main__":
    unittest.main()
