#!/usr/bin/env python3
"""检查模拟器截图里是否真的出现大段正文，而不是空白页。

只统计「整行都有文字」的行数与段落块数，比整块像素占比更能区分
「正文上屏」和「随便一块深色 UI」。空白页、只显示占位省略号、只剩输入条
都会被判失败。

标定（1206×2622 模拟器截图，正文区 10%–78%）：正常的流式截图约 380 行文字、
25 段；空白页 0 行 0 段。
"""

from __future__ import annotations

import sys

from PIL import Image

# 正文区：避开状态栏与底部输入条。
BODY_TOP = 0.10
BODY_BOTTOM = 0.78
# 一行里至少这么多比例的像素是深色，才算「这一行有字」。
ROW_DARK_RATIO = 0.02
# 一行深色像素的下限，避免把分割线、圆角当成文字。
ROW_DARK_MIN = 2
# 文字行总数下限：mock 回复约 1.1 万字，正常有几百行。
TOTAL_TEXT_ROWS_MIN = 120
# 段落块数下限：连续文字行算一段，中文段间距会把它切开。
PARAGRAPH_BLOCKS_MIN = 8
# 少于这么多连续行就算噪声，不计为一段。
PARAGRAPH_ROWS_MIN = 2


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: check_stream_shot.py <screenshot.png>")
        return 2
    path = sys.argv[1]
    image = Image.open(path).convert("L")
    width, height = image.size

    top = int(height * BODY_TOP)
    bottom = int(height * BODY_BOTTOM)
    body = image.crop((0, top, width, bottom))

    # 缩到 402 宽：行级统计够用，逐行直方图快一个数量级。
    scale = 402 / max(body.width, 1)
    sample = body.resize((402, max(int(body.height * scale), 1)))

    text_rows = 0
    blocks = 0
    current_block = 0
    for y in range(sample.height):
        row = sample.crop((0, y, sample.width, y + 1))
        histogram = row.histogram()
        dark = sum(histogram[:100])
        if dark >= max(ROW_DARK_MIN, sample.width * ROW_DARK_RATIO):
            text_rows += 1
            current_block += 1
        else:
            if current_block >= PARAGRAPH_ROWS_MIN:
                blocks += 1
            current_block = 0
    if current_block >= PARAGRAPH_ROWS_MIN:
        blocks += 1

    print(f"{path}: {width}x{height} text_rows={text_rows} blocks={blocks}")

    problems = []
    if text_rows < TOTAL_TEXT_ROWS_MIN:
        problems.append(f"正文行数只有 {text_rows}（< {TOTAL_TEXT_ROWS_MIN}）")
    if blocks < PARAGRAPH_BLOCKS_MIN:
        problems.append(f"正文段落只有 {blocks} 段（< {PARAGRAPH_BLOCKS_MIN}）")
    if problems:
        print("FAIL: 正文区几乎是空白：" + "；".join(problems))
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
