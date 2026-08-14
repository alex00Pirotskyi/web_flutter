#!/usr/bin/env python3
"""Generate repeatable CSV/ZIP stress data for Signal Analysis Studio V4."""
import argparse
import csv
import math
import os
import random
import zipfile
from pathlib import Path


def write_csv(path: Path, samples: int, features: int, logical: int, seed: int) -> None:
    rng = random.Random(seed)
    headers = [f"signal_{i:03d}" for i in range(features)] + [f"state_{i:02d}" for i in range(logical)]
    with path.open("w", newline="", encoding="utf-8") as f:
        writer = csv.writer(f)
        writer.writerow(headers)
        spike_at = max(1, samples // 2)
        for i in range(samples):
            row = []
            for j in range(features):
                base = math.sin(i * (0.002 + j * 0.00007)) + 0.15 * math.cos(i * 0.0009 * (j + 1))
                noise = (rng.random() - 0.5) * 0.02
                # Deterministic narrow extrema verify min/max downsampling.
                spike = (25.0 + j * 0.1) if i == spike_at and j % 5 == 0 else 0.0
                row.append(f"{base + noise + spike:.7f}")
            for j in range(logical):
                period = 200 + j * 37
                row.append(1 if (i // period) % 2 else 0)
            writer.writerow(row)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="benchmark_corpus")
    ap.add_argument("--files", type=int, default=10)
    ap.add_argument("--samples", type=int, default=10000)
    ap.add_argument("--features", type=int, default=16)
    ap.add_argument("--logical", type=int, default=4)
    ap.add_argument("--zip", action="store_true", dest="make_zip")
    args = ap.parse_args()

    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    for n in range(args.files):
        path = out / f"dataset_{n:04d}.csv"
        write_csv(path, args.samples, args.features, args.logical, seed=1000 + n)
        print(path)

    if args.make_zip:
        zip_path = out.with_suffix(".zip")
        with zipfile.ZipFile(zip_path, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6) as zf:
            for path in sorted(out.glob("*.csv")):
                zf.write(path, arcname=f"data/{path.name}")
        print(zip_path)


if __name__ == "__main__":
    main()
