#!/usr/bin/env python3
"""本地 OpenAI 兼容 SSE 服务，供 Stream Check 在模拟器里伪装大段生成。"""

from __future__ import annotations

import json
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CHUNKS = [
    (
        f"第{i}段：林昭把梯子挪到最里侧的书架前，灰尘在手电的光柱里浮着，像静止的雪。"
        "她抽出第三本的时候，有什么东西从书页间滑了出来，轻飘飘地落在脚边。"
        "是一封信，信封上写着地址，邮票还在，却从来没有盖过邮戳。"
        "窗外的雨声突然变得很远，整间书店像是被谁按下了静音键。"
    )
    for i in range(1, 91)
]


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"

    def do_GET(self) -> None:  # noqa: N802
        if self.path == "/health":
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            self.wfile.write(b"ok")
            return
        self.send_error(404)

    def do_POST(self) -> None:  # noqa: N802
        length = int(self.headers.get("Content-Length", "0"))
        if length:
            self.rfile.read(length)

        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()

        for text in CHUNKS:
            payload = json.dumps(
                {"choices": [{"delta": {"content": text}}]},
                ensure_ascii=False,
            )
            self.wfile.write(f"data: {payload}\n\n".encode())
            self.wfile.flush()
            time.sleep(0.03)

        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()

    def log_message(self, *args: object) -> None:
        return


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", 8765), Handler).serve_forever()
