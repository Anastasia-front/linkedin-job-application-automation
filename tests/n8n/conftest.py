import sys
from pathlib import Path

SCRIPTS_DIR = Path(__file__).resolve().parents[2] / "scripts" / "n8n"
sys.path.insert(0, str(SCRIPTS_DIR))
