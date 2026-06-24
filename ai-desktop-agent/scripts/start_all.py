#!/usr/bin/env python3
"""启动所有服务"""

import subprocess
import sys
import time
from pathlib import Path

import yaml
import httpx


def load_config() -> dict:
    config_path = Path(__file__).parent.parent / "config.yaml"
    with open(config_path, "r", encoding="utf-8") as f:
        return yaml.safe_load(f)


def check_port(host: str, port: int) -> bool:
    try:
        resp = httpx.get(f"http://{host}:{port}/health", timeout=2)
        return resp.status_code == 200
    except Exception:
        return False


def main():
    config = load_config()
    executor_config = config.get("executor", {})
    http_config = executor_config.get("http", {})
    host = http_config.get("host", "127.0.0.1")
    port = http_config.get("port", 18600)

    project_dir = Path(__file__).parent.parent

    print("=" * 50)
    print("  🤖 AI Desktop Agent - 启动所有服务")
    print("=" * 50)

    # 1. 启动 AHK 服务
    print("\n[1/2] 启动 AHK 执行服务...")
    if check_port(host, port):
        print(f"  ✅ AHK 服务已在运行 ({host}:{port})")
    else:
        ahk_proc = subprocess.Popen(
            [sys.executable, str(project_dir / "scripts" / "start_ahk.py")],
            creationflags=subprocess.CREATE_NEW_CONSOLE if sys.platform == "win32" else 0,
        )
        time.sleep(3)
        if check_port(host, port):
            print(f"  ✅ AHK 服务启动成功")
        else:
            print(f"  ⚠️  AHK 服务可能未启动，请检查")

    # 2. 启动 MCP Server
    print("\n[2/2] 启动 MCP Server...")
    print("  ℹ️  MCP Server 使用 stdio 传输，需要由 Claude Code 启动")
    print("  配置 Claude Code 的 MCP Server:")
    print(f'  命令: python {project_dir / "scripts" / "start_mcp.py"}')

    print("\n" + "=" * 50)
    print("  服务就绪！在 Claude Code 中使用以下工具:")
    print("  - see_screen: 查看屏幕")
    print("  - click: 点击")
    print("  - type_text: 输入文字")
    print("  - open_app: 打开应用")
    print("  - execute_task: 执行复杂任务")
    print("=" * 50)


if __name__ == "__main__":
    main()
