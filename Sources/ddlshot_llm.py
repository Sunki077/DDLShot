#!/usr/bin/env python3
"""
ddlshot_llm.py — DDLShot 的大模型抽取器

从「屏幕文本」或「截图」中抽出所有待办事项（任务名 + 截止时间），输出 JSON 数组。

设计要点
--------
* 双协议：OpenAI 兼容（DeepSeek / 智谱 / 通义 / 豆包 / MiniMax / Ollama…）与
  Anthropic 兼容（MiniMax / Kimi 的 Anthropic 端点）。默认 auto 探测。
* 纯文本输入时走本地 Vision OCR 的结果（隐私优先，只发文字）；
  传图片时直接把截图交给视觉模型（像 Todoo 那样"看图理解"）。
* 输出严格是 JSON 数组；模型返回带 ```json 包裹或有前后废话时自动抠出来。
* 只依赖标准库即可运行；httpx / requests 存在时优先使用（更快、支持代理）。

用法
----
  ddlshot_llm.py --text "明天交报告"
  ddlshot_llm.py --image /tmp/shot.png
  ddlshot_llm.py --image /tmp/shot.png --model gpt-4o --base-url https://api.openai.com/v1
  ddlshot_llm.py --config ~/.config/ddlshot/config.json --text "..."

配置优先级：命令行参数 > 环境变量 > 配置文件 > 内置默认值
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import re
import sys
import urllib.error
import urllib.request
from datetime import datetime
from pathlib import Path
from typing import Any

DEFAULT_CONFIG = Path.home() / ".config" / "ddlshot" / "config.json"

# ---------------------------------------------------------------------------
# 默认配置
# ---------------------------------------------------------------------------

DEFAULTS: dict[str, Any] = {
    "protocol": "auto",          # auto | openai | anthropic
    "provider": "",              # minimax / deepseek / openai / qwen / ... 见 PROVIDERS
    "base_url": "",
    "api_key": "",
    "model": "",
    "timeout": 90,
    "max_tokens": 8192,          # 思考块 + 正文，M3 系列思考默认开启要留够
    "temperature": 0.1,         # 低随机性，输出更稳定
    "effort": "low",             # low|medium|high|xhigh|max；抽取任务用 low 又快又省
    "default_hour": 9,           # 只识别出日期、没识别出时间时用这个点
    "max_items": 12,
    "verify_tls": True,
}

SYSTEM_PROMPT = """你是一个「截止日期抽取器」。你的任务是从给定的屏幕内容（聊天记录、邮件、通知、公告的 OCR 文本或截图）里，找出**所有需要用户本人完成、且带有截止时间线索的任务**，并给出每条任务的截止时间。

规则：
1. 只抽取「待办/需要做/要交/要回/要去/记得/别忘」这类**用户需要行动**的事项。
2. **一条任务必须能指出它的截止时间线索**（如「截止 / 前 / 之前 / 要 / 得 / 记得 / 别忘 /
   deadline / 关上 / 报名截止 / 交材料」之类表示时限的词或具体日期时间）。
   找不到时限线索的 → **不要输出这条**。
3. **以下内容一律不要输出**（它们是噪音，不是待办）：
   · 吃饭、约饭、点外卖、喝奶茶、加个鸡腿之类
   · 闲聊、玩笑、表情包、风景、心情、赞美、吐槽
   · 别人已经完成的事、纯陈述、新闻转发、广告、系统提示
   · 「明天见」「回头聊」「有空再约」这类没有时限的客套话
4. title 写**要做的事本身**，用简短动宾短语（不超过 30 字）。
   - 不要包含日期
   - 不要包含「截止 / DDL / deadline / 之前 / 前 / 抓紧」这类标记词
   - 如果原文写的是「周三前交材料」，title 写「交材料」
5. due 是**绝对日期时间**，格式 "YYYY-MM-DDTHH:MM:SS"（不带时区偏移）。
   - 相对表述（明天/下周三/本周五）都换算成绝对日期，换算基准是下面给出的「当前时间」。
   - 只说了日期没说时间 → 当天 default_hour 点（通常是 09:00）。
   - 说了具体时刻（下午三点 / 15:00 / 晚上8点）→ 用该时刻，12 小时制要换算成 24 小时制。
   - **只写了日号没写月份**（如「28号」「5号」）→ 一律按**当前月份**算。
     只有当这个日号在当前月份已经过去了，才理解为下个月。
     例：当前是 10月24日，「28号」→ 10-28；「3号」→ 下个月的 3 号。
   - **写了月份和日期但没写年份** → 按**当前年份**算；若该日期已经过去，则理解为明年。
   - 完全无法确定截止时间 → due 设为 null，due_text 也可为 null。
6. 不要把句子里的普通时间词（早上的「晚上」这种）当成截止时间。
   截止时间必须来自明确的时限表述或具体日期。
7. due_text 填**原文里描述时间的那个短语**，方便人工核对，例如「11月5日 18:00」「本周五前」「明天下午三点」。
8. confidence 填 high / medium / low：
   - high：日期明确且直接对应某个任务
   - medium：日期明确但归属需要推断（例如整段文字共用一个日期）
   - low：日期模糊或靠上下文猜测
9. notes 填该任务的**原文上下文**（一到两行原话，可为空字符串）。
10. 最多输出 {max_items} 条。**没有符合以上全部条件的任务就输出空数组 []**（不要为了凑数硬凑）。
11. **只输出 JSON 数组**，不要任何解释、前言、markdown 代码块。"""

USER_TEMPLATE = """当前时间：{now}
（今天：{today}；本月：{month}；本周：{weekday}）

以下是屏幕内容：

---
{content}
---

请输出 JSON 数组。"""

# ---------------------------------------------------------------------------
# 配置装载
# ---------------------------------------------------------------------------


# 供应商预设：选好 provider，base_url / model / protocol 自动补全；
# 配置里显式写过的项优先。协议只有两种：openai（绝大多数）与 anthropic。
PROVIDERS: dict[str, dict[str, str]] = {
    "minimax":        {"protocol": "anthropic", "base_url": "https://api.minimax.cn/anthropic/v1",           "model": "MiniMax-M3.1-Flash"},
    "minimax-openai": {"protocol": "openai",    "base_url": "https://api.minimax.cn/v1",                    "model": "MiniMax-M3.1-Flash"},
    "deepseek":       {"protocol": "openai",    "base_url": "https://api.deepseek.com/v1",                  "model": "deepseek-chat"},
    "openai":         {"protocol": "openai",    "base_url": "https://api.openai.com/v1",                    "model": "gpt-4o-mini"},
    "qwen":           {"protocol": "openai",    "base_url": "https://dashscope.aliyuncs.com/compatible-mode/v1", "model": "qwen-vl-max"},
    "zhipu":          {"protocol": "openai",    "base_url": "https://open.bigmodel.cn/api/paas/v4",        "model": "glm-4v-plus"},
    "moonshot":       {"protocol": "openai",    "base_url": "https://api.moonshot.cn/v1",                   "model": "kimi-k2-0905-preview"},
    "doubao":         {"protocol": "openai",    "base_url": "https://ark.cn-beijing.volces.com/api/v3",     "model": ""},
    "siliconflow":    {"protocol": "openai",    "base_url": "https://api.siliconflow.cn/v1",               "model": "Qwen/Qwen2.5-VL-72B-Instruct"},
    "gemini":         {"protocol": "openai",    "base_url": "https://generativelanguage.googleapis.com/v1beta/openai", "model": "gemini-2.5-flash"},
    "ollama":         {"protocol": "openai",    "base_url": "http://localhost:11434/v1",                   "model": "qwen2.5vl"},
    "custom":         {},
}


def load_config(path: str | None) -> dict[str, Any]:
    cfg = dict(DEFAULTS)
    explicit: set[str] = set()
    p = Path(path) if path else DEFAULT_CONFIG
    if p.exists():
        try:
            raw = json.loads(p.read_text(encoding="utf-8"))
        except Exception as e:
            die(f"配置文件解析失败 {p}: {e}")
        raw = raw.get("llm", raw) if isinstance(raw, dict) else {}
        explicit = set(raw.keys())
        for k, v in raw.items():
            if k in cfg and v is not None:
                cfg[k] = v
    # 环境变量覆盖
    env_map = {
        "DDLSHOT_LLM_BASE_URL": "base_url",
        "DDLSHOT_LLM_API_KEY": "api_key",
        "DDLSHOT_LLM_MODEL": "model",
        "DDLSHOT_LLM_PROTOCOL": "protocol",
        "DDLSHOT_LLM_PROVIDER": "provider",
    }
    for ek, ck in env_map.items():
        if os.environ.get(ek):
            cfg[ck] = os.environ[ek]
    # 供应商预设补全（配置里显式写过的项优先）
    prov = str(cfg.get("provider") or "").strip().lower()
    if prov in PROVIDERS:
        pre = PROVIDERS[prov]
        if "base_url" not in explicit and not os.environ.get("DDLSHOT_LLM_BASE_URL"):
            cfg["base_url"] = pre.get("base_url", "")
        if "model" not in explicit and not os.environ.get("DDLSHOT_LLM_MODEL"):
            cfg["model"] = pre.get("model", "")
        if "protocol" not in explicit and not os.environ.get("DDLSHOT_LLM_PROTOCOL"):
            cfg["protocol"] = pre.get("protocol", cfg["protocol"])
    return cfg


def die(msg: str, code: int = 2) -> None:
    sys.stderr.write(f"ddlshot_llm: {msg}\n")
    sys.exit(code)


# ---------------------------------------------------------------------------
# HTTP
# ---------------------------------------------------------------------------


def _post(url: str, headers: dict[str, str], body: dict[str, Any],
          timeout: int, verify: bool) -> dict[str, Any]:
    data = json.dumps(body, ensure_ascii=False).encode("utf-8")
    req = urllib.request.Request(url, data=data, method="POST")
    req.add_header("Content-Type", "application/json")
    for k, v in headers.items():
        req.add_header(k, v)

    ctx = None
    if not verify:
        import ssl
        ctx = ssl._create_unverified_context()  # noqa: SLF001
    else:
        # 优先用 certifi 的 CA 集合（macOS 自带 Python 的默认 CA 可能为空）
        try:
            import ssl as _ssl
            try:
                import certifi
                ctx = _ssl.create_default_context(cafile=certifi.where())
            except Exception:
                ctx = _ssl.create_default_context()
        except Exception:
            ctx = None
    try:
        with urllib.request.urlopen(req, timeout=timeout, context=ctx) as resp:
            raw = resp.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        detail = e.read().decode("utf-8", "replace")[:600]
        die(f"HTTP {e.code} {e.reason}\n{detail}")
    except Exception as e:
        die(f"请求失败: {type(e).__name__}: {e}")
    try:
        return json.loads(raw)
    except Exception:
        die(f"响应不是合法 JSON: {raw[:600]}")


def _post_httpx(url: str, headers: dict[str, str], body: dict[str, Any],
                timeout: int, verify: bool) -> dict[str, Any]:
    import httpx
    with httpx.Client(timeout=timeout, verify=verify) as c:
        r = c.post(url, headers=headers, json=body)
        if r.status_code >= 400:
            die(f"HTTP {r.status_code}\n{r.text[:600]}")
        return r.json()


# ---------------------------------------------------------------------------
# 协议实现
# ---------------------------------------------------------------------------


def detect_protocol(base_url: str, model: str, explicit: str) -> str:
    if explicit and explicit != "auto":
        return explicit
    u = (base_url or "").lower()
    # Anthropic 兼容端点特征
    if "/anthropic" in u or u.rstrip("/").endswith("/messages") or "agent.minimax.cn" in u:
        return "anthropic"
    return "openai"


def call_openai(cfg: dict[str, Any], system: str, user_text: str,
                image_path: str | None) -> str:
    base = cfg["base_url"].rstrip("/")
    url = f"{base}/chat/completions"
    headers = {"Authorization": f"Bearer {cfg['api_key']}"}
    if image_path:
        headers["Content-Type"] = "application/json"

    content: list[dict[str, Any]] = [{"type": "text", "text": user_text}]
    if image_path:
        b64 = base64.b64encode(Path(image_path).read_bytes()).decode("ascii")
        content.insert(0, {
            "type": "image_url",
            "image_url": {"url": f"data:image/png;base64,{b64}"},
        })
    body = {
        "model": cfg["model"],
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": content},
        ],
        "max_tokens": cfg["max_tokens"],
    }
    if cfg.get("temperature") is not None:
        body["temperature"] = cfg["temperature"]
    # MiniMax：思考深度（M3.1-Flash 强制开启 thinking，effort 决定思考量）
    effort = cfg.get("effort")
    if effort:
        body["reasoning_effort"] = effort
    data = _post_httpx(url, headers, body, cfg["timeout"], cfg["verify_tls"]) \
        if _has("httpx") else _post(url, headers, body, cfg["timeout"], cfg["verify_tls"])
    try:
        msg = data["choices"][0]["message"]
        text = msg.get("content") or ""
        if not text and msg.get("reasoning_content"):
            text = msg["reasoning_content"]
        # MiniMax 在不拆分 reasoning 时会把 <think>...</think> 直接放在 content 里
        text = re.sub(r"<think>.*?</think>", "", text, flags=re.S)
        return text
    except Exception:
        die(f"响应结构异常: {json.dumps(data, ensure_ascii=False)[:600]}")


def call_anthropic(cfg: dict[str, Any], system: str, user_text: str,
                    image_path: str | None) -> str:
    base = cfg["base_url"].rstrip("/")
    url = f"{base}/messages"
    headers = {
        "x-api-key": cfg["api_key"],
        "anthropic-version": "2023-06-01",
        "Content-Type": "application/json",
    }
    content: list[dict[str, Any]] = [{"type": "text", "text": user_text}]
    if image_path:
        b64 = base64.b64encode(Path(image_path).read_bytes()).decode("ascii")
        content.insert(0, {
            "type": "image",
            "source": {"type": "base64", "media_type": "image/png", "data": b64},
        })
    body = {
        "model": cfg["model"],
        "max_tokens": cfg["max_tokens"],
        "system": system,
        "messages": [{"role": "user", "content": content}],
    }
    if cfg.get("temperature") is not None:
        body["temperature"] = cfg["temperature"]
    effort = cfg.get("effort")
    if effort:
        # Anthropic 兼容协议下用 output_config.effort
        body["output_config"] = {"effort": effort}
    data = _post_httpx(url, headers, body, cfg["timeout"], cfg["verify_tls"]) \
        if _has("httpx") else _post(url, headers, body, cfg["timeout"], cfg["verify_tls"])
    # Anthropic 可能先返回 thinking 块，再返回 text 块
    out = []
    for block in data.get("content", []):
        if block.get("type") == "text":
            out.append(block.get("text", ""))
    if not out:
        die(f"响应里没有文本块: {json.dumps(data, ensure_ascii=False)[:600]}")
    return "".join(out)


def _has(mod: str) -> bool:
    try:
        __import__(mod)
        return True
    except Exception:
        return False


# ---------------------------------------------------------------------------
# JSON 抽取
# ---------------------------------------------------------------------------


def extract_json_array(raw: str) -> list[dict[str, Any]]:
    s = raw.strip()
    # 去掉 ```json ... ``` 包裹
    m = re.search(r"```(?:json)?\s*(.+?)\s*```", s, re.S)
    if m:
        s = m.group(1).strip()
    # 直接就是数组
    try:
        v = json.loads(s)
        if isinstance(v, list):
            return [x for x in v if isinstance(x, dict)]
        # 有些模型返回的 content 本身是一段 JSON 字符串（双重编码）
        if isinstance(v, str):
            return extract_json_array(v)
    except Exception:
        pass
    # 找第一个平衡的 [...] 片段
    start = s.find("[")
    if start < 0:
        start = s.find("{")
    if start < 0:
        die(f"模型没返回 JSON: {raw[:400]}")
    depth = 0
    in_str = False
    esc = False
    for i in range(start, len(s)):
        ch = s[i]
        if in_str:
            if esc:
                esc = False
            elif ch == "\\":
                esc = True
            elif ch == '"':
                in_str = False
            continue
        if ch == '"':
            in_str = True
        elif ch in "[{":
            depth += 1
        elif ch in "]}":
            depth -= 1
            if depth == 0:
                frag = s[start:i + 1]
                try:
                    v = json.loads(frag)
                    if isinstance(v, dict):
                        for key in ("items", "tasks", "results", "data"):
                            if isinstance(v.get(key), list):
                                return [x for x in v[key] if isinstance(x, dict)]
                        return [v]
                except Exception:
                    pass
    die(f"无法从模型输出里解析出 JSON 数组: {raw[:400]}")


# ---------------------------------------------------------------------------
# 结果规整
# ---------------------------------------------------------------------------


def normalize_due(s: Any, default_hour: int) -> str | None:
    """把模型给的各种日期写法规整成 'YYYY-MM-DDTHH:MM:SS'。"""
    if s is None:
        return None
    if isinstance(s, (int, float)):
        s = str(int(s))
    s = str(s).strip()
    if not s or s.lower() in ("null", "none", "n/a", "na", "-"):
        return None
    s = s.replace("/", "-").replace("Z", "").replace("T", " ").strip()
    m = re.match(r"(\d{4})-(\d{1,2})-(\d{1,2})(?:[ ]+(\d{1,2}):(\d{2})(?::(\d{2}))?)?", s)
    if m:
        y, mo, d = int(m.group(1)), int(m.group(2)), int(m.group(3))
        hh = int(m.group(4)) if m.group(4) else default_hour
        mi = int(m.group(5)) if m.group(5) else 0
        ss = int(m.group(6)) if m.group(6) else 0
        try:
            return datetime(y, mo, d, hh, mi, ss).strftime("%Y-%m-%dT%H:%M:%S")
        except ValueError:
            return None
    # 只给了 "MM-DD" 或 "M月D日" → 用当前年份补
    m = re.match(r"(\d{1,2})-(\d{1,2})", s)
    if m:
        now = datetime.now()
        try:
            return datetime(now.year, int(m.group(1)), int(m.group(2)),
                           default_hour, 0, 0).strftime("%Y-%m-%dT%H:%M:%S")
        except ValueError:
            return None
    return None


def _norm_title(s: str) -> str:
    """归一化标题用于去重：去掉空白与标点"""
    return re.sub(r"[\s\u3000·•\-—–:：,，.。;；|、\"'“”‘’()（）\[\]【】]", "", s or "")


def _is_same_task(a: dict[str, Any], b: dict[str, Any]) -> bool:
    """
    判断两条是不是同一件事。
    模型偶尔会把同一条任务吐两遍，甚至两条给的日期还不一样，
    所以这里不比较 due，只比标题：
      · 归一化后标题完全相同 → 同一件
      · 标题尾部 3 个字互相包含（"交实验报告" vs "提交实验报告"）→ 视为同一件
    """
    ta, tb = _norm_title(a.get("title", "")), _norm_title(b.get("title", ""))
    if not ta or not tb:
        return False
    if ta == tb:
        return True
    return len(ta) >= 3 and len(tb) >= 3 and (ta[-3:] in tb or tb[-3:] in ta)


def _prefer(a: dict[str, Any], b: dict[str, Any]) -> dict[str, Any]:
    """同一件事的两份结果里挑信息更全的那份（dueText 越具体越好）"""
    da, db = len(a.get("dueText") or ""), len(b.get("dueText") or "")
    if da != db:
        return a if da > db else b
    if a.get("confidence") == "high" and b.get("confidence") != "high":
        return a
    return b


def normalize_items(raw_items: list[dict[str, Any]], cfg: dict[str, Any]) -> list[dict[str, Any]]:
    out: list[dict[str, Any]] = []
    default_hour = int(cfg.get("default_hour", 9) or 9)
    for it in raw_items:
        title = str(it.get("title") or it.get("task") or it.get("summary") or "").strip()
        if not title:
            continue
        due = normalize_due(it.get("due", it.get("due_date", it.get("deadline"))), default_hour)
        due_text = it.get("due_text") or it.get("dueText") or it.get("date_text") or ""
        conf = str(it.get("confidence") or "medium").lower()
        if conf not in ("high", "medium", "low"):
            conf = "medium"
        item = {
            "title": title[:120],
            "due": due,
            "dueText": str(due_text)[:60],
            "notes": str(it.get("notes") or it.get("context") or "")[:500],
            "confidence": conf,
        }
        # 去重：同一件事只留一条，取信息最全的那次
        dup_at = None
        for i, o in enumerate(out):
            if _is_same_task(item, o):
                dup_at = i
                break
        if dup_at is not None:
            out[dup_at] = _prefer(item, out[dup_at])
            continue
        out.append(item)
    return out[:int(cfg.get("max_items", 12) or 12)]


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------


def main() -> int:
    ap = argparse.ArgumentParser(description="DDLShot 大模型 DDL 抽取器")
    ap.add_argument("--text")
    ap.add_argument("--image")
    ap.add_argument("--config")
    ap.add_argument("--base-url")
    ap.add_argument("--api-key")
    ap.add_argument("--model")
    ap.add_argument("--protocol")
    ap.add_argument("--provider", help="供应商预设：minimax / deepseek / openai / qwen / zhipu / moonshot / "
                                       "doubao / siliconflow / gemini / ollama / custom")
    ap.add_argument("--timeout", type=int)
    ap.add_argument("--default-hour", type=int)
    ap.add_argument("--now", help="覆盖「当前时间」，用于测试")
    ap.add_argument("--prompt-only", action="store_true", help="只打印将要发送的 prompt，不调 API")
    ap.add_argument("--indent", type=int, default=2)
    args = ap.parse_args()

    cfg = load_config(args.config)
    for k in ("base_url", "api_key", "model", "protocol", "provider"):
        v = getattr(args, k, None)
        if v:
            cfg[k] = v
    if args.timeout:
        cfg["timeout"] = args.timeout
    if args.default_hour is not None:
        cfg["default_hour"] = args.default_hour

    if args.text is None and args.image is None:
        die("必须给 --text 或 --image")
    if args.image and not Path(args.image).exists():
        die(f"图片不存在: {args.image}")

    now_str = args.now or datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    system = SYSTEM_PROMPT.replace("{max_items}", str(cfg["max_items"]))

    now_dt = datetime.strptime(args.now, "%Y-%m-%d %H:%M:%S") if args.now else datetime.now()
    if args.image:
        user_text = (f"当前时间：{now_str}\n"
                     f"（今天：{now_dt.strftime('%Y-%m-%d')}；本月：{now_dt.strftime('%Y-%m')}；"
                     f"本周：{'一二三四五六日'[now_dt.weekday()] if now_dt.weekday() < 6 else '日'}）\n\n"
                     f"这是屏幕截图。请识别其中的待办事项与截止时间，输出 JSON 数组。")
    else:
        user_text = (USER_TEMPLATE
                     .replace("{now}", now_str)
                     .replace("{today}", now_dt.strftime("%Y-%m-%d"))
                     .replace("{month}", now_dt.strftime("%Y-%m"))
                     .replace("{weekday}", "一二三四五六日"[now_dt.weekday()])
                     .replace("{content}", args.text or ""))

    if args.prompt_only:
        print(json.dumps({"system": system, "user": user_text,
                          "config": {k: v for k, v in cfg.items() if k != "api_key"}},
                         ensure_ascii=False, indent=2))
        return 0

    if not cfg["base_url"]:
        die("没配置 base_url（用 --base-url 或写进 ~/.config/ddlshot/config.json）")
    if not cfg["api_key"]:
        die("没配置 api_key（用 --api-key、DDLSHOT_LLM_API_KEY 环境变量，"
            "或写进 ~/.config/ddlshot/config.json）")
    if not cfg["model"]:
        die("没配置 model（用 --model 或写进 ~/.config/ddlshot/config.json）")

    protocol = detect_protocol(cfg["base_url"], cfg["model"], cfg["protocol"])
    try:
        if protocol == "anthropic":
            raw = call_anthropic(cfg, system, user_text, args.image)
        else:
            raw = call_openai(cfg, system, user_text, args.image)
    except SystemExit:
        raise
    except Exception as e:
        die(f"调用模型失败: {type(e).__name__}: {e}")

    items = normalize_items(extract_json_array(raw), cfg)
    print(json.dumps(items, ensure_ascii=False, indent=args.indent))
    return 0


if __name__ == "__main__":
    sys.exit(main())
