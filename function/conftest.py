"""Put the function app root on sys.path for tests.

The Azure Functions Python app root is `function/`, where `shared.py` is a
sibling module of `function_app.py` (imported as `from shared import shape`).
This makes `pytest function/tests/` resolve that import whether pytest is run
from inside `function/` or from the repo root.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
