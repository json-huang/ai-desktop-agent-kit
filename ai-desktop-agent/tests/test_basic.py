#!/usr/bin/env python3
"""基础测试 - 验证各模块可导入"""

import sys
from pathlib import Path

# 添加项目根目录
sys.path.insert(0, str(Path(__file__).parent.parent))


def test_imports():
    """测试所有模块可以导入"""
    print("测试模块导入...")

    try:
        from vision.screen import ScreenManager
        print("  ✅ vision.screen")
    except ImportError as e:
        print(f"  ❌ vision.screen: {e}")

    try:
        from vision.analyzer import ScreenAnalyzer
        print("  ✅ vision.analyzer")
    except ImportError as e:
        print(f"  ❌ vision.analyzer: {e}")

    try:
        from vision.locator import ElementLocator
        print("  ✅ vision.locator")
    except ImportError as e:
        print(f"  ❌ vision.locator: {e}")

    try:
        from executor.bridge import AHKBridge
        print("  ✅ executor.bridge")
    except ImportError as e:
        print(f"  ❌ executor.bridge: {e}")

    try:
        from orchestrator.agent import DesktopAgent
        print("  ✅ orchestrator.agent")
    except ImportError as e:
        print(f"  ❌ orchestrator.agent: {e}")

    try:
        from orchestrator.planner import Planner
        print("  ✅ orchestrator.planner")
    except ImportError as e:
        print(f"  ❌ orchestrator.planner: {e}")

    try:
        from mcp_server.server import create_mcp_server
        print("  ✅ mcp_server.server")
    except ImportError as e:
        print(f"  ❌ mcp_server.server: {e}")


def test_screen():
    """测试截图功能"""
    print("\n测试截图功能...")
    try:
        from vision.screen import ScreenManager
        sm = ScreenManager()
        w, h = sm.get_screen_size()
        print(f"  屏幕分辨率: {w}x{h}")

        data = sm.take_screenshot()
        print(f"  截图大小: {len(data)} bytes")
        print("  ✅ 截图功能正常")
    except Exception as e:
        print(f"  ❌ 截图失败: {e}")


def test_config():
    """测试配置加载"""
    print("\n测试配置加载...")
    try:
        import yaml
        config_path = Path(__file__).parent.parent / "config.yaml"
        with open(config_path, "r", encoding="utf-8") as f:
            config = yaml.safe_load(f)

        print(f"  LLM 提供商: {config.get('llm', {}).get('provider', 'N/A')}")
        print(f"  AHK 端口: {config.get('executor', {}).get('http', {}).get('port', 'N/A')}")
        print("  ✅ 配置加载正常")
    except Exception as e:
        print(f"  ❌ 配置加载失败: {e}")


if __name__ == "__main__":
    print("=" * 50)
    print("  AI Desktop Agent - 基础测试")
    print("=" * 50)

    test_imports()
    test_config()
    test_screen()

    print("\n" + "=" * 50)
    print("  测试完成！")
    print("=" * 50)
