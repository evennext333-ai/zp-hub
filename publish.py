"""生成 GitHub 公开发布目录，只输出混淆 Hub、说明与校验和。"""
import argparse
import hashlib
import os
import shutil
import subprocess
import tempfile
from pathlib import Path

from build import DEFAULT_API_URL, PROMETHEUS_COMMIT, api_url, build

PUBLIC_FILES = {"loader.lua", "NOTICE.txt", "SHA256SUMS"}
LOADER_URL = "https://github.com/evennext333-ai/zp-hub/releases/latest/download/loader.lua"


def prepare(api, output, prometheus_dir, lua="lua5.1"):
    output = Path(output).resolve()
    if output.exists():
        raise ValueError("公开发布目录已存在，请使用新目录")
    output.parent.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix=".hub-public-", dir=output.parent))
    try:
        manifest = build(api, staging / "hub-build", prometheus_dir, lua)
        public = staging / "public"
        public.mkdir()
        shutil.copyfile(staging / "hub-build/loader.lua", public / "loader.lua")
        loader = public / "loader.lua"
        if not loader.is_file() or not 1 <= loader.stat().st_size <= 2 * 1024 * 1024:
            raise ValueError("混淆产物缺失或大小异常")
        notice = (
            f"RSZH Hub {manifest['version']}\n"
            f"API: {api_url(api)}/api\n"
            f"Loader: {LOADER_URL}\n"
            f"Prometheus commit: {PROMETHEUS_COMMIT}\n"
            f"Hub source: {os.environ.get('HUB_SOURCE_REPOSITORY', 'local build')}\n"
            f"Hub source commit: {os.environ.get('HUB_SOURCE_COMMIT', 'local build')}\n"
            "Based on Prometheus by Elias Oelschner, https://github.com/prometheus-lua/Prometheus\n"
            "Only the public Hub loader is distributed here. Private game scripts remain behind API authorization.\n"
            "Obfuscation is not encryption, authorization, or protection for previously public source.\n"
        )
        (public / "NOTICE.txt").write_text(notice, encoding="utf-8")
        checksums = "".join(
            f"{hashlib.sha256((public / name).read_bytes()).hexdigest()}  {name}\n"
            for name in ("loader.lua", "NOTICE.txt")
        )
        (public / "SHA256SUMS").write_text(checksums, encoding="utf-8")
        if {file.name for file in public.iterdir()} != PUBLIC_FILES:
            raise ValueError("公开产物白名单校验失败")
        public.rename(output)
        return manifest["version"]
    finally:
        shutil.rmtree(staging, ignore_errors=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--api-url", default=DEFAULT_API_URL)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--prometheus-dir", type=Path, required=True)
    parser.add_argument("--lua-bin", default="lua5.1")
    args = parser.parse_args()
    try:
        version = prepare(args.api_url, args.output, args.prometheus_dir, args.lua_bin)
        print(f"公开 Hub {version} 已构建：{args.output.resolve()}")
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        parser.exit(1, f"公开构建失败：{error}\n")
