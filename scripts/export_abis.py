#!/usr/bin/env python3
"""Extract contract ABIs from forge build output into abis/.

Run from the repo root after ``forge build``::

    chmod +x scripts/export_abis.py
    scripts/export_abis.py
"""

import json
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
FORGE_OUT = REPO_ROOT / "contracts" / "out"
ABI_DIR = REPO_ROOT / "abis"

CONTRACTS = [
    "ChaosOracleRegistry",
    "PredictionSettlementLogic",
]


def main() -> None:
    ABI_DIR.mkdir(parents=True, exist_ok=True)

    for name in CONTRACTS:
        artifact = FORGE_OUT / f"{name}.sol" / f"{name}.json"
        if not artifact.exists():
            print(f"  SKIP  {name} (not found: {artifact})")
            continue

        abi = json.loads(artifact.read_text())["abi"]
        out_path = ABI_DIR / f"{name}.json"
        out_path.write_text(json.dumps(abi, indent=2) + "\n")
        print(f"  OK    {name} ({len(abi)} entries) -> {out_path.relative_to(REPO_ROOT)}")


if __name__ == "__main__":
    main()
