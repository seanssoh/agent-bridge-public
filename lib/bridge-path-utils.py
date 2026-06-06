#!/usr/bin/env python3
import os
import sys


mode = sys.argv[1]
path = os.path.realpath(sys.argv[2])
root = os.path.realpath(sys.argv[3])

if mode == "relative":
    try:
        print(os.path.relpath(path, root))
    except Exception:
        print(".")
elif mode == "within":
    try:
        common = os.path.commonpath([path, root])
    except ValueError:
        print("0")
    else:
        print("1" if common == root else "0")
else:
    raise SystemExit(f"unknown mode: {mode}")
