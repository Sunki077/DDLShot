#!/usr/bin/env python3
"""mockapi.py — 本地假 LLM 服务，用来在没有真实 API key 时测通 DDLShot 全链路。

用法: python3 mockapi.py <port> [响应文件]
它会把收到的请求（不含图片 base64 全文）写到 /tmp/mockapi_request.json，
并把配置的响应原样返回。响应文件里可以用 {{COUNT}} 占位。
"""
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8899
RESP_FILE = sys.argv[2] if len(sys.argv) > 2 else "/tmp/mockapi_response.json"

DEFAULT = [{
    "title": "提交实验报告", "due": "2026-11-05T18:00:00", "due_text": "11月5日 18:00",
    "notes": "截止 11月5日 18:00 交实验报告", "confidence": "high",
}]


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(n).decode("utf-8", "replace")
        try:
            body = json.loads(raw)
        except Exception:
            body = {"_raw": raw[:2000]}

        # 记录请求（图片只留长度，不留 base64 全文）
        rec = json.loads(raw) if isinstance(body, dict) else {}
        img_info = None
        try:
            msgs = rec.get("messages", [])
            for m in msgs:
                c = m.get("content")
                if isinstance(c, list):
                    for blk in c:
                        if blk.get("type") in ("image", "image_url"):
                            s = json.dumps(blk)
                            img_info = {"type": blk["type"], "payload_len": len(s),
                                        "head": s[:120]}
        except Exception:
            pass
        with open("/tmp/mockapi_request.json", "w", encoding="utf-8") as f:
            json.dump({"path": self.path, "headers": dict(self.headers),
                       "body": {**rec, "_image": img_info}}, f, ensure_ascii=False, indent=2)

        try:
            resp = json.load(open(RESP_FILE, encoding="utf-8"))
        except Exception:
            resp = DEFAULT
        content = resp if isinstance(resp, str) else json.dumps(resp, ensure_ascii=False)

        if "/messages" in self.path:
            # Anthropic Messages 协议：先给一个 thinking 块，再给 text 块
            out = {
                "id": "msg_mock", "type": "message", "role": "assistant",
                "model": "mock-model",
                "content": [
                    {"type": "thinking", "thinking": "先分析有哪些待办……"},
                    {"type": "text", "text": content},
                ],
                "stop_reason": "end_turn",
                "usage": {"input_tokens": 100, "output_tokens": 50},
            }
        else:
            # OpenAI Chat Completions 协议：把 think 标签塞进 content，测剥离逻辑
            out = {
                "choices": [{"message": {"role": "assistant",
                                         "content": "<think>先想想</think>\n" + content},
                             "finish_reason": "stop"}],
                "usage": {"prompt_tokens": 100, "completion_tokens": 50},
            }
        data = json.dumps(out, ensure_ascii=False).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


if __name__ == "__main__":
    print(f"mockapi on :{PORT}, response file = {RESP_FILE}", flush=True)
    HTTPServer(("127.0.0.1", PORT), H).serve_forever()
