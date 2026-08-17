"""Board-free safety tests for the live MicroPython payload."""

import runpy
import sys
import types
import unittest
from pathlib import Path


PAYLOAD = Path(__file__).parents[1] / "device" / "rocky_agent.py"


class DeviceDouble(types.ModuleType):
    def __init__(self, name):
        super().__init__(name)
        self.drive_calls = []
        self.loudness_reads = 0
        self.distance_reads = 0
        self.reflect_reads = 0
        self.now = 1000
        self.display = types.SimpleNamespace(clear=lambda: None, show_label=lambda *args, **kwargs: None)
        self.led = types.SimpleNamespace(on=lambda *args, **kwargs: None)

    def drive_speed(self, left, right):
        self.drive_calls.append((left, right))

    def get_loudness(self):
        self.loudness_reads += 1
        return 10

    def get_distance(self):
        self.distance_reads += 1
        return 5

    def get_all_data(self):
        self.reflect_reads += 1
        return [100, 100, 100, 100]

    def ticks_ms(self):
        return self.now

    @staticmethod
    def ticks_diff(left, right):
        return left - right

    @staticmethod
    def ticks_add(value, delta):
        return value + delta

    @staticmethod
    def sleep_ms(_milliseconds):
        return None


def load_payload():
    cyberpi = DeviceDouble("cyberpi")
    mbot2 = DeviceDouble("mbot2")
    utime = DeviceDouble("utime")
    ultrasonic = DeviceDouble("ultrasonic2")
    line_sensor = DeviceDouble("quad_rgb_sensor")
    mbuild = types.ModuleType("mbuild")
    mbuild.ultrasonic2 = ultrasonic
    mbuild.quad_rgb_sensor = line_sensor

    modules = {
        "cyberpi": cyberpi,
        "mbot2": mbot2,
        "utime": utime,
        "mbuild": mbuild,
    }
    previous = {name: sys.modules.get(name) for name in modules}
    sys.modules.update(modules)
    try:
        payload = runpy.run_path(str(PAYLOAD), run_name="rocky_test_payload")
    finally:
        for name, old_module in previous.items():
            if old_module is None:
                sys.modules.pop(name, None)
            else:
                sys.modules[name] = old_module
    payload["_pump_observers"] = lambda _now: None
    return payload, cyberpi, mbot2, ultrasonic, line_sensor


class StillInterlockTests(unittest.TestCase):
    def test_robot_boots_still_but_awake_default_is_exploring(self):
        payload, *_ = load_payload()

        self.assertEqual(payload["BOOT_MOOD"], "still")
        self.assertEqual(payload["DEFAULT_MOOD"], "exploring")
        self.assertEqual(payload["EXCITABLE_DECAY_MOOD"], "calm")
        self.assertEqual(payload["_state"]["mood"], "still")

    def test_excitement_cools_down_to_calm(self):
        payload, *_ = load_payload()
        state = payload["_state"]
        state.update(mood="excitable", mood_since=1000)

        payload["_decay_mood"](1000 + payload["EXCITABLE_COOLDOWN_MS"])

        self.assertEqual(state["mood"], "calm")

    def test_still_tick_stops_motors_without_polling_movement_sensors(self):
        payload, cyberpi, mbot2, ultrasonic, line_sensor = load_payload()
        state = payload["_state"]
        state.update(
            booted=True,
            floor=0,
            mode="startled",
            rpm=165,
            drive_started=500,
            gesture_queue=[("spin", 5000, "act_test", 1, 2), ("wiggle", 8500, "act_test", 2, 2)],
        )

        payload["tick"]()

        self.assertEqual(mbot2.drive_calls[-1], (0, 0))
        self.assertEqual(state["mode"], "listening")
        self.assertEqual(state["rpm"], 0)
        self.assertIsNone(state["drive_started"])
        self.assertEqual(state["gesture_queue"], [])
        self.assertEqual(cyberpi.loudness_reads, 0, "loudness cannot trigger a jump while still")
        self.assertEqual(ultrasonic.distance_reads, 0, "proximity cannot trigger a jump while still")
        self.assertEqual(line_sensor.reflect_reads, 0, "a jolt/floor change cannot trigger a spin while still")

    def test_going_still_interrupts_current_motion_immediately(self):
        payload, _cyberpi, mbot2, _ultrasonic, _line_sensor = load_payload()
        state = payload["_state"]
        state.update(mood="exploring", mode="driving", rpm=90, drive_started=500)

        payload["_apply_intent"]({"type": "mood", "mood": "still", "id": "sleep"}, 1000)

        self.assertEqual(mbot2.drive_calls[-1], (0, 0))
        self.assertEqual(state["mood"], "still")
        self.assertEqual(state["mode"], "listening")

    def test_only_an_awake_mood_releases_the_interlock(self):
        payload, _cyberpi, mbot2, _ultrasonic, _line_sensor = load_payload()
        state = payload["_state"]
        state.update(booted=True, floor=0)

        payload["_apply_intent"]({"type": "gesture", "gesture": "spin", "id": "asleep"}, 1000)
        payload["tick"]()
        self.assertFalse(any(left or right for left, right in mbot2.drive_calls))

        payload["_apply_intent"]({"type": "mood", "mood": "exploring", "id": "wake"}, 1001)
        payload["tick"]()
        payload["tick"]()  # first awake tick notices the 5 cm obstacle; second performs the jolt
        self.assertTrue(any(left or right for left, right in mbot2.drive_calls))

    def test_mixed_routine_keeps_every_step_and_correlation_id(self):
        payload, *_ = load_payload()

        payload["_apply_intent"](
            {"type": "routine", "moves": ["spin", "wiggle", "spin"], "id": "act_story"}, 1000
        )

        first = payload["_take_gesture"](1001)
        second = payload["_take_gesture"](1002)
        third = payload["_take_gesture"](1003)
        self.assertEqual((first[0], first[2], first[3:]), ("spin", "act_story", (1, 3)))
        self.assertEqual((second[0], second[2], second[3:]), ("wiggle", "act_story", (2, 3)))
        self.assertEqual((third[0], third[2], third[3:]), ("spin", "act_story", (3, 3)))
        self.assertIsNone(payload["_take_gesture"](1004))

    def test_a_new_routine_replaces_only_steps_that_have_not_started(self):
        payload, *_ = load_payload()
        payload["_apply_intent"](
            {"type": "routine", "moves": ["spin", "wiggle"], "id": "act_old"}, 1000
        )
        already_started = payload["_take_gesture"](1001)

        payload["_apply_intent"](
            {"type": "routine", "moves": ["wiggle", "spin"], "id": "act_new"}, 1002
        )

        self.assertEqual((already_started[0], already_started[2]), ("spin", "act_old"))
        replacement = payload["_take_gesture"](1003)
        self.assertEqual((replacement[0], replacement[2]), ("wiggle", "act_new"))
        final_move = payload["_take_gesture"](1004)
        self.assertEqual((final_move[0], final_move[2]), ("spin", "act_new"))
        self.assertIsNone(payload["_take_gesture"](1005))


if __name__ == "__main__":
    unittest.main()
