#!/usr/bin/env python3
"""启动 AHK HTTP 服务 (Python 版)"""

import subprocess
import sys
import time
from pathlib import Path

import httpx


def check_running(host: str, port: int) -> bool:
    try:
        resp = httpx.get(f"http://{host}:{port}/health", timeout=2)
        return resp.status_code == 200
    except Exception:
        return False


def main():
    host = "127.0.0.1"
    port = 18600
    project_dir = Path(__file__).parent.parent

    if check_running(host, port):
        print(f"✅ AHK 服务已在运行 ({host}:{port})")
        return

    # 检查 AHK 是否安装
    ahk_path = "C:/Program Files/AutoHotkey/v2/AutoHotkey64.exe"
    if not Path(ahk_path).exists():
        print(f"❌ 未找到 AutoHotkey: {ahk_path}")
        print("请从 https://www.autohotkey.com/ 下载安装 AutoHotkey v2")
        sys.exit(1)

    print(f"🚀 正在启动 AHK 执行服务...")
    print(f"   地址: http://{host}:{port}")

    proc = subprocess.Popen(
        [sys.executable, str(project_dir / "executor" / "http_server.py")],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )

    for i in range(10):
        time.sleep(1)
        if check_running(host, port):
            print(f"✅ AHK 服务启动成功 ({host}:{port})")
            print(f"   PID: {proc.pid}")
            return

    print("❌ AHK 服务启动超时")
    proc.terminate()
    sys.exit(1)


if __name__ == "__main__":
    main()
