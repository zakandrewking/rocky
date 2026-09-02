"""Host-side safety tests for the disposable navigation qualification payload.

The physical results cannot be simulated, but the promises surrounding each trial can: commands
outside the deliberately tiny envelope never reach the motors, an already-close ultrasonic target
refuses forward motion, elapsed time stops a pulse locally, and disconnect always cuts power.
"""

import json
import pathlib
import sys
import types
import unittest


PAYLOAD = (
    pathlib.Path(__file__).parents[1]
    / "steps"
    / "step19_navigation_sensor_qualification.py"
)


class FakePart:
    def __getattr__(self, _name):
        return lambda *_args, **_kwargs: None


class FakeMotorModule(types.ModuleType):
    def __init__(self):
        super().__init__("mbot2")
        self.commands = []

    def drive_speed(self, left, right):
        self.commands.append((left, right))


class FakeUltrasonic:
    def __init__(self):
        self.distance = 100

    def get_distance(self):
        return self.distance


class FakeClient:
    def __init__(self):
        self.messages = []
        self.closed = False

    def sendall(self, data):
        self.messages.append(json.loads(data.decode().strip()))

    def close(self):
        self.closed = True


class NavigationQualificationPayloadTests(unittest.TestCase):
    def setUp(self):
        self.now = 1_000
        self.motor = FakeMotorModule()
        self.ultrasonic = FakeUltrasonic()

        cyberpi = types.ModuleType("cyberpi")
        cyberpi.get_yaw = lambda: 12.5
        cyberpi.display = FakePart()
        cyberpi.led = FakePart()

        utime = types.ModuleType("utime")
        utime.ticks_ms = lambda: self.now
        utime.ticks_diff = lambda left, right: left - right
        utime.ticks_add = lambda value, delta: value + delta

        mbuild = types.ModuleType("mbuild")
        mbuild.ultrasonic2 = self.ultrasonic

        fake_socket = types.ModuleType("usocket")
        fake_socket.AF_INET = 2
        fake_socket.SOCK_STREAM = 1
        fake_socket.SOL_SOCKET = 1
        fake_socket.SO_REUSEADDR = 2

        replacements = {
            "cyberpi": cyberpi,
            "mbot2": self.motor,
            "mbuild": mbuild,
            "utime": utime,
            "ujson": json,
            "usocket": fake_socket,
        }
        self.original_modules = {name: sys.modules.get(name) for name in replacements}
        sys.modules.update(replacements)

        self.namespace = {"__name__": "navigation_qualification_test"}
        exec(compile(PAYLOAD.read_text(), str(PAYLOAD), "exec"), self.namespace)
        self.client = FakeClient()
        self.namespace["_state"]["client"] = self.client

    def tearDown(self):
        for name, original in self.original_modules.items():
            if original is None:
                sys.modules.pop(name, None)
            else:
                sys.modules[name] = original

    def start(self, **overrides):
        command = {
            "type": "motion",
            "id": "trial-1",
            "kind": "drive",
            "rpm": 30,
            "duration_ms": 300,
            "direction": 1,
            **overrides,
        }
        self.namespace["_handle"](command)

    def test_module_load_stops_any_previous_motion(self):
        self.assertEqual(self.motor.commands, [(0, 0)])

    def test_motion_outside_bounds_is_refused_without_starting_motor(self):
        self.start(duration_ms=501)

        self.assertEqual(self.motor.commands, [(0, 0)])
        self.assertEqual(self.client.messages[-1]["event"], "refused")
        self.assertEqual(self.client.messages[-1]["reason"], "outside safe bounds")

    def test_close_obstacle_refuses_forward_motion(self):
        self.ultrasonic.distance = 20
        self.start()

        self.assertEqual(self.motor.commands, [(0, 0)])
        self.assertEqual(self.client.messages[-1]["reason"], "obstacle")

    def test_backward_pulse_is_not_claimed_safe_by_forward_sensor(self):
        self.ultrasonic.distance = 20
        self.start(direction=-1)

        self.assertEqual(self.motor.commands[-1], (-30, 30))
        self.assertEqual(self.client.messages[-1]["event"], "motion_start")

    def test_elapsed_duration_stops_pulse_locally(self):
        self.start()
        self.assertEqual(self.motor.commands[-1], (30, -30))

        self.now += 300
        self.namespace["_tick_motion"](self.now)

        self.assertEqual(self.motor.commands[-1], (0, 0))
        self.assertIsNone(self.namespace["_state"]["motion"])
        self.assertEqual(self.client.messages[-1]["event"], "motion_end")
        self.assertEqual(self.client.messages[-1]["reason"], "complete")

    def test_obstacle_crossing_threshold_stops_active_forward_pulse(self):
        self.start()
        self.ultrasonic.distance = 25

        self.namespace["_tick_motion"](self.now + 50)

        self.assertEqual(self.motor.commands[-1], (0, 0))
        self.assertEqual(self.client.messages[-1]["reason"], "obstacle")

    def test_disconnect_stops_active_motion_and_closes_client(self):
        self.start(kind="spin")

        self.namespace["_disconnect"]()

        self.assertEqual(self.motor.commands[-1], (0, 0))
        self.assertIsNone(self.namespace["_state"]["motion"])
        self.assertTrue(self.client.closed)


if __name__ == "__main__":
    unittest.main()
