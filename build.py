"""独立构建 Hub 公共资源包，不读取游戏脚本或相邻仓库。"""
import argparse
import hashlib
import json
import re
import shutil
import subprocess
import tempfile
from pathlib import Path
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parent
DEFAULT_API_URL = "https://www.zldelf.cloud/api"
DEFAULT_FALLBACK_API_URL = "https://zs-hub-api.zs-hub-edge.workers.dev"
PROMETHEUS_COMMIT = "a98c50165f2a53f6d765a82eee60dfea53803445"
PUBLIC_ASSETS = ("loader.lua", "keys.html", "keys.js", "keys.css")


def lua_literal(text):
    equals = ""
    while "]" + equals + "]" in text:
        equals += "="
    return "[" + equals + "[" + text + "]" + equals + "]"


def api_url(value):
    parsed = urlsplit(value)
    port = parsed.port
    if (parsed.scheme != "https" or not parsed.hostname or parsed.username
            or parsed.password or parsed.query or parsed.fragment
            or port == 0 or any(c.isspace() for c in value)):
        raise ValueError("API 地址应为不含凭据、查询参数的 HTTPS 地址")
    if parsed.path.rstrip("/") not in ("", "/api"):
        raise ValueError("API 地址仅支持域名根地址或 /api 前缀")
    return f"{parsed.scheme}://{parsed.netloc}"


def obfuscate(loader, tool, lua):
    tool = Path(tool).resolve()
    revision = subprocess.check_output(["git", "-C", str(tool), "rev-parse", "HEAD"], text=True).strip()
    dirty = subprocess.check_output(["git", "-C", str(tool), "status", "--porcelain"], text=True).strip()
    if revision != PROMETHEUS_COMMIT or dirty:
        raise ValueError("混淆器须为指定提交且工作区保持干净")
    generated = loader.with_name(".loader.obfuscated.lua")
    subprocess.run([
        lua, str(tool / "cli.lua"), "--config", str(ROOT / "obfuscate.lua"),
        "--out", str(generated), str(loader),
    ], check=True, capture_output=True, timeout=120)
    if not generated.is_file() or not 1 <= generated.stat().st_size <= 2 * 1024 * 1024:
        raise ValueError("混淆产物缺失或大小异常")
    generated.replace(loader)


def build(api, output, prometheus_dir=None, lua="lua5.1", fallback_api=DEFAULT_FALLBACK_API_URL):
    api = api_url(api)
    fallback = api_url(fallback_api) if fallback_api else ""
    if fallback == api:
        fallback = ""
    output = Path(output).resolve()
    if output.exists():
        raise ValueError("发布目录已存在，请使用新目录，保留旧版本用于回滚")
    version = (ROOT / "VERSION").read_text(encoding="utf-8").strip()
    if not re.fullmatch(r"[A-Za-z0-9._-]{1,40}", version):
        raise ValueError("Hub 版本格式错误")
    output.parent.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix=".zp-hub-", dir=output.parent))
    try:
        runtime = (ROOT / "src/runtime.lua").read_text(encoding="utf-8")
        client = (ROOT / "src/client.lua").read_text(encoding="utf-8")
        fallback_line = ("\nlocal FALLBACK_API = " + lua_literal(fallback)) if fallback else ""
        loader = ("-- 国内 Hub，构建版本 " + version + "\nlocal API = " + lua_literal(api)
                  + fallback_line
                  + "\nlocal Runtime = (function()\n" + runtime + "\nend)()\n" + client)
        (staging / "loader.lua").write_text(loader, encoding="utf-8")
        if prometheus_dir is not None:
            obfuscate(staging / "loader.lua", prometheus_dir, lua)
        for asset in PUBLIC_ASSETS[1:]:
            shutil.copyfile(ROOT / "src" / asset, staging / asset)
        metadata = {"version": version, "api": api, "files": {}}
        if fallback:
            metadata["fallbackApi"] = fallback
        for asset in PUBLIC_ASSETS:
            body = (staging / asset).read_bytes()
            limit = 2 * 1024 * 1024 if asset == "loader.lua" else 100 * 1024
            if not body or len(body) > limit:
                raise ValueError("Hub 公共资源大小异常")
            body.decode("utf-8")
            metadata["files"][asset] = hashlib.sha256(body).hexdigest()
        (staging / "hub.json").write_text(json.dumps(metadata, ensure_ascii=False, indent=2), encoding="utf-8")
        staging.rename(output)
        return metadata
    except BaseException:
        shutil.rmtree(staging, ignore_errors=True)
        raise


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--api-url", default=DEFAULT_API_URL)
    parser.add_argument("--fallback-api-url", default=DEFAULT_FALLBACK_API_URL)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--prometheus-dir", type=Path)
    parser.add_argument("--lua-bin", default="lua5.1")
    args = parser.parse_args()
    try:
        metadata = build(args.api_url, args.output, args.prometheus_dir, args.lua_bin, args.fallback_api_url)
        print(f"Hub {metadata['version']} 已构建：{args.output.resolve()}")
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        parser.exit(1, f"构建失败：{error}\n")
