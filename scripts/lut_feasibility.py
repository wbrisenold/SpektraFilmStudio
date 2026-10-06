#!/usr/bin/env python3
from __future__ import annotations
import argparse
import math
import statistics
import struct
from pathlib import Path

def cube_points(size: int):
    for b in range(size):
        for g in range(size):
            for r in range(size):
                yield r/(size-1), g/(size-1), b/(size-1)

def write_identity(path: Path, size: int):
    with path.open("w") as f:
        f.write(f'TITLE "SpektraFilmFast Identity {size}"\n')
        f.write(f"LUT_3D_SIZE {size}\n")
        f.write("DOMAIN_MIN 0.0 0.0 0.0\n")
        f.write("DOMAIN_MAX 1.0 1.0 1.0\n")
        for r, g, b in cube_points(size):
            f.write(f"{r:.9f} {g:.9f} {b:.9f}\n")

def read_f32(path: Path, channels: int):
    raw = path.read_bytes()
    stride = 4 * channels
    if len(raw) % stride:
        raise ValueError(
            f"{path}: byte count must be divisible by {stride}"
        )
    values = struct.unpack("<" + "f" * (len(raw) // 4), raw)
    return [
        values[i:i+3]
        for i in range(0, len(values), channels)
    ]

def srgb_to_linear(x: float) -> float:
    x = max(0.0, min(1.0, x))
    if x <= 0.04045:
        return x / 12.92
    return ((x + 0.055) / 1.055) ** 2.4

def rgb_to_lab(rgb):
    r, g, b = [srgb_to_linear(v) for v in rgb]
    x = 0.4124564*r + 0.3575761*g + 0.1804375*b
    y = 0.2126729*r + 0.7151522*g + 0.0721750*b
    z = 0.0193339*r + 0.1191920*g + 0.9503041*b
    x /= 0.95047
    z /= 1.08883

    def f(t):
        d = 6/29
        if t > d**3:
            return t**(1/3)
        return t/(3*d*d) + 4/29

    fx, fy, fz = f(x), f(y), f(z)
    return 116*fy - 16, 500*(fx-fy), 200*(fy-fz)

def delta_e_2000(lab1, lab2):
    l1, a1, b1 = lab1
    l2, a2, b2 = lab2
    c1 = math.hypot(a1, b1)
    c2 = math.hypot(a2, b2)
    cbar = (c1 + c2) / 2
    g = (
        0.5 * (
            1 - math.sqrt(cbar**7 / (cbar**7 + 25**7))
        )
        if cbar else 0
    )

    ap1 = (1 + g) * a1
    ap2 = (1 + g) * a2
    cp1 = math.hypot(ap1, b1)
    cp2 = math.hypot(ap2, b2)

    hp1 = math.degrees(math.atan2(b1, ap1)) % 360 if cp1 else 0
    hp2 = math.degrees(math.atan2(b2, ap2)) % 360 if cp2 else 0

    dlp = l2 - l1
    dcp = cp2 - cp1
    dh = hp2 - hp1

    if cp1 * cp2 == 0:
        dh = 0
    elif dh > 180:
        dh -= 360
    elif dh < -180:
        dh += 360

    dhp = 2 * math.sqrt(cp1 * cp2) * math.sin(math.radians(dh / 2))
    lbar = (l1 + l2) / 2
    cpbar = (cp1 + cp2) / 2

    if cp1 * cp2 == 0:
        hpbar = hp1 + hp2
    elif abs(hp1 - hp2) <= 180:
        hpbar = (hp1 + hp2) / 2
    elif hp1 + hp2 < 360:
        hpbar = (hp1 + hp2 + 360) / 2
    else:
        hpbar = (hp1 + hp2 - 360) / 2

    t = (
        1
        - 0.17 * math.cos(math.radians(hpbar - 30))
        + 0.24 * math.cos(math.radians(2 * hpbar))
        + 0.32 * math.cos(math.radians(3 * hpbar + 6))
        - 0.20 * math.cos(math.radians(4 * hpbar - 63))
    )
    dtheta = 30 * math.exp(-((hpbar - 275) / 25) ** 2)
    rc = (
        2 * math.sqrt(cpbar**7 / (cpbar**7 + 25**7))
        if cpbar else 0
    )
    sl = 1 + 0.015 * (lbar - 50)**2 / math.sqrt(
        20 + (lbar - 50)**2
    )
    sc = 1 + 0.045 * cpbar
    sh = 1 + 0.015 * cpbar * t
    rt = -math.sin(math.radians(2 * dtheta)) * rc

    x = dlp / sl
    y = dcp / sc
    z = dhp / sh
    return math.sqrt(x*x + y*y + z*z + rt*y*z)

def percentile(values, p):
    if not values:
        return 0.0
    ordered = sorted(values)
    position = (len(ordered) - 1) * p
    lo = int(math.floor(position))
    hi = int(math.ceil(position))
    if lo == hi:
        return ordered[lo]
    return (
        ordered[lo] * (hi - position) +
        ordered[hi] * (position - lo)
    )

def compare(exact: Path, candidate: Path, channels: int) -> int:
    a = read_f32(exact, channels)
    b = read_f32(candidate, channels)
    if len(a) != len(b):
        raise ValueError(
            f"pixel count differs: {len(a)} vs {len(b)}"
        )

    channel_errors = [[], [], []]
    squared = 0.0
    delta_es = []

    for left, right in zip(a, b):
        for c in range(3):
            error = abs(left[c] - right[c])
            channel_errors[c].append(error)
            squared += error * error
        delta_es.append(
            delta_e_2000(rgb_to_lab(left), rgb_to_lab(right))
        )

    print(f"pixels: {len(a)}")
    for c, name in enumerate("RGB"):
        values = channel_errors[c]
        print(
            f"{name}: "
            f"mean_abs={statistics.fmean(values):.8g} "
            f"p95={percentile(values, .95):.8g} "
            f"max={max(values):.8g}"
        )

    rmse = math.sqrt(squared / max(1, len(a) * 3))
    print(f"RMSE: {rmse:.8g}")
    print(
        "DeltaE2000: "
        f"mean={statistics.fmean(delta_es):.5f} "
        f"p95={percentile(delta_es, .95):.5f} "
        f"max={max(delta_es):.5f}"
    )

    passed = (
        percentile(delta_es, .95) < 0.5 and
        max(delta_es) < 1.5
    )
    print("suggested_gate:", "PASS" if passed else "FAIL")
    return 0 if passed else 2

def ordering_self_test() -> int:
    points = list(cube_points(3))
    first, second = points[0], points[1]
    ok = (
        first[1:] == second[1:] and
        first[0] != second[0]
    )
    print(
        "cube_axis_order_r_fastest:",
        "PASS" if ok else "FAIL"
    )
    return 0 if ok else 3

def main() -> int:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)

    generate = sub.add_parser("generate")
    generate.add_argument(
        "--size",
        type=int,
        choices=(17, 33, 65),
        default=33
    )
    generate.add_argument("--out", type=Path, required=True)

    compare_parser = sub.add_parser("compare")
    compare_parser.add_argument("exact", type=Path)
    compare_parser.add_argument("candidate", type=Path)
    compare_parser.add_argument(
        "--channels",
        type=int,
        choices=(3, 4),
        default=4
    )

    sub.add_parser("self-test")
    args = parser.parse_args()

    if args.command == "generate":
        write_identity(args.out, args.size)
        print(args.out)
        return 0
    if args.command == "compare":
        return compare(
            args.exact,
            args.candidate,
            args.channels
        )
    return ordering_self_test()

if __name__ == "__main__":
    raise SystemExit(main())
