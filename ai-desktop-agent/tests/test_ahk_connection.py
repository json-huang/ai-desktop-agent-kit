#!/usr/bin/env python3
"""测试 AHK 服务连接"""

import asyncio
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

import httpx


async def test_ahk_connection():
    """测试与 AHK 服务的连接"""
    base_url = "http://127.0.0.1:18600"

    print("测试 AHK 服务连接...")

    async with httpx.AsyncClient(timeout=5.0) as client:
        # 1. 健康检查
        try:
            resp = await client.get(f"{base_url}/health")
            print(f"  ✅ 健康检查: {resp.json()}")
        except Exception as e:
            print(f"  ❌ 无法连接到 AHK 服务: {e}")
            print("  请先运行: python scripts/start_ahk.py")
            return

        # 2. 测试鼠标点击
        try:
            resp = await client.post(f"{base_url}/execute", json={
                "action": "click",
                "params": {"x": 100, "y": 100}
            })
            print(f"  ✅ 鼠标点击测试: {resp.json()}")
        except Exception as e:
            print(f"  ❌ 鼠标点击失败: {e}")

        # 3. 测试键盘输入
        try:
            resp = await client.post(f"{base_url}/execute", json={
                "action": "type_text",
                "params": {"text": "Hello from AI Agent!"}
            })
            print(f"  ✅ 键盘输入测试: {resp.json()}")
        except Exception as e:
            print(f"  ❌ 键盘输入失败: {e}")

        # 4. 测试快捷键
        try:
            resp = await client.post(f"{base_url}/execute", json={
                "action": "press_keys",
                "params": {"keys": "ctrl+a"}
            })
            print(f"  ✅ 快捷键测试: {resp.json()}")
        except Exception as e:
            print(f"  ❌ 快捷键失败: {e}")


if __name__ == "__main__":
    asyncio.run(test_ahk_connection())
