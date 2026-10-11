"""Run the independent constructor-level Phocus 4.2.2 native audit.

The earlier parameter-injection test is archived in hncs-phocus-audit/before.
This test lets the original binary select all matrices, LUTs and curves.
"""
import sys
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/"work/hncs-phocus-audit"))
from native_chain_probe import main
if __name__=="__main__":main()
