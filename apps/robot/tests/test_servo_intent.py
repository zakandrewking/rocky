import ast
import pathlib
import unittest


class FakeMbot2:
    def __init__(self, error=None):
        self.calls = []
        self.error = error

    def servo_set(self, angle, port):
        self.calls.append((angle, port))
        if self.error:
            raise self.error


def load_apply_intent(mbot2):
    source = pathlib.Path(__file__).parents[1] / "device" / "rocky_agent.py"
    tree = ast.parse(source.read_text())
    function = next(node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name == "_apply_intent")
    emitted = []
    errors = []
    namespace = {
        "mbot2": mbot2,
        "_emit": emitted.append,
        "_report_error_once": lambda name, error: errors.append((name, str(error))),
    }
    exec(compile(ast.Module(body=[function], type_ignores=[]), str(source), "exec"), namespace)
    return namespace["_apply_intent"], emitted, errors


class ServoIntentTests(unittest.TestCase):
    def test_s3_and_s4_are_bounded_and_acknowledged(self):
        mbot2 = FakeMbot2()
        apply_intent, emitted, errors = load_apply_intent(mbot2)

        apply_intent({"type": "servo", "port": "s3", "angle": -9, "id": "a"}, 123)
        apply_intent({"type": "servo", "port": "S4", "angle": 900, "id": "b"}, 124)

        self.assertEqual(mbot2.calls, [(0, "S3"), (180, "S4")])
        self.assertEqual(
            emitted,
            [
                {"type": "ack", "t": 123, "of": "servo", "id": "a", "ok": True, "port": "S3", "angle": 0},
                {"type": "ack", "t": 124, "of": "servo", "id": "b", "ok": True, "port": "S4", "angle": 180},
            ],
        )
        self.assertEqual(errors, [])

    def test_other_ports_are_never_touched(self):
        mbot2 = FakeMbot2()
        apply_intent, emitted, _errors = load_apply_intent(mbot2)

        apply_intent({"type": "servo", "port": "S2", "angle": 90}, 123)

        self.assertEqual(mbot2.calls, [])
        self.assertEqual(emitted, [])

    def test_hardware_failure_returns_correlated_diagnostic(self):
        mbot2 = FakeMbot2(RuntimeError("servo bus unavailable"))
        apply_intent, emitted, errors = load_apply_intent(mbot2)

        apply_intent({"type": "servo", "port": "S3", "angle": 42, "id": "failed"}, 125)

        self.assertEqual(mbot2.calls, [(42, "S3")])
        self.assertEqual(emitted[0]["ok"], False)
        self.assertEqual(emitted[0]["id"], "failed")
        self.assertEqual(emitted[0]["error"], "servo bus unavailable")
        self.assertEqual(errors, [("servo_failed", "servo bus unavailable")])


if __name__ == "__main__":
    unittest.main()
