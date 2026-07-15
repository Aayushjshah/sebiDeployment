#!/usr/bin/env python3
import argparse
import json
import math
from pathlib import Path


def load_embedding(path: Path, index: int) -> list[float]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    data = payload.get("data")
    if not isinstance(data, list) or len(data) <= index:
        raise SystemExit(f"{path}: missing data[{index}]")
    embedding = data[index].get("embedding")
    if not isinstance(embedding, list):
        raise SystemExit(f"{path}: missing data[{index}].embedding")
    return [float(x) for x in embedding]


def norm(values: list[float]) -> float:
    return math.sqrt(sum(x * x for x in values))


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Compare two OpenAI-compatible E5 embedding JSON responses."
    )
    parser.add_argument("left", type=Path, help="First embedding response JSON")
    parser.add_argument("right", type=Path, help="Second embedding response JSON")
    parser.add_argument("--index", type=int, default=0, help="data[] index to compare")
    parser.add_argument("--top", type=int, default=10, help="top absolute differences to print")
    args = parser.parse_args()

    left = load_embedding(args.left, args.index)
    right = load_embedding(args.right, args.index)
    if len(left) != len(right):
        raise SystemExit(f"dimension mismatch: {len(left)} != {len(right)}")

    dot = sum(a * b for a, b in zip(left, right))
    left_norm = norm(left)
    right_norm = norm(right)
    cosine = dot / (left_norm * right_norm)
    diffs = [a - b for a, b in zip(left, right)]
    abs_diffs = [abs(x) for x in diffs]
    l2 = norm(diffs)
    mean_abs = sum(abs_diffs) / len(abs_diffs)
    max_abs = max(abs_diffs)
    max_index = abs_diffs.index(max_abs)

    print(f"dimensions={len(left)}")
    print(f"left_norm={left_norm:.12f}")
    print(f"right_norm={right_norm:.12f}")
    print(f"dot={dot:.12f}")
    print(f"cosine={cosine:.12f}")
    print(f"l2_distance={l2:.12f}")
    print(f"mean_abs_diff={mean_abs:.12f}")
    print(f"max_abs_diff={max_abs:.12f}")
    print(f"max_abs_diff_index={max_index}")

    print()
    print(f"top_{args.top}_absolute_diffs:")
    ranked = sorted(
        enumerate(zip(left, right, diffs, abs_diffs)),
        key=lambda item: item[1][3],
        reverse=True,
    )
    for idx, (a, b, diff, abs_diff) in ranked[: args.top]:
        print(
            f"{idx}: left={a:.12f} right={b:.12f} "
            f"diff={diff:.12f} abs_diff={abs_diff:.12f}"
        )

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
