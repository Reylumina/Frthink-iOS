#!/usr/bin/env python3
"""检查模拟器截图里是否真的出现大段正文，而不是空白页。"""

from __future__ import annotations

import sys

from PIL import Image


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: check_stream_shot.py <screenshot.png>")
        return 2
    image = Image.open(sys.argv[1]).convert("L")
    width, height = image.size
    # 避开状态栏和底部输入条，只检查聊天正文区。
    body = image.crop((0, int(height * 0.10), width, int(height * 0.78)))
    histogram = body.histogram()
    dark_pixels = sum(histogram[:100])
    total = body.width * body.height
    ratio = dark_pixels / max(total, 1)
    print(f"{sys.argv[1]}: {width}x{height} dark={dark_pixels} ratio={ratio:.4f}")
    if dark_pixels < 5_000 or ratio < 0.01:
        print("FAIL: 正文区几乎是空白")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
