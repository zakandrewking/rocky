import unittest

from server import MAX_TEXT_CHARACTERS, validate_text


class ValidateTextTest(unittest.TestCase):
    def test_normalizes_spoken_text(self) -> None:
        self.assertEqual(validate_text("  Can hear.\nRocky listens.  "), "Can hear. Rocky listens.")

    def test_rejects_missing_or_oversized_text(self) -> None:
        for value in (None, "", "   ", "x" * (MAX_TEXT_CHARACTERS + 1)):
            with self.subTest(value_type=type(value).__name__):
                with self.assertRaises(ValueError):
                    validate_text(value)


if __name__ == "__main__":
    unittest.main()
