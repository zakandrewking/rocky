# Shadows the real stdlib `time` module -- see README.md for why, and the tradeoff this accepts.
from typing import Any

def __getattr__(name: str) -> Any: ...
