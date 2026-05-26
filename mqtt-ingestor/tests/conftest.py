"""讓 pytest 從 tests/ 跑時能 import 上一層的 ingestor.py（沒包成 package）。"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
