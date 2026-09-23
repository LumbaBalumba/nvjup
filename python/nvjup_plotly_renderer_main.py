#!/usr/bin/env python3
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))

from nvjup_plotly_renderer.server import main

if __name__ == "__main__":
    main()
