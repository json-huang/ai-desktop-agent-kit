#!/usr/bin/env python3
"""启动 MCP Server - 给 Claude Code 提供工具接口"""

import asyncio
import logging
import sys
from pathlib import Path

import yaml
from dotenv import load_dotenv

# 添加项目根目录到 path
sys.path.insert(0, str(Path(__file__).parent.parent))

from mcp_server.server import create_mcp_server


def load_config() -> dict:
    """加载配置"""
    config_path = Path(__file__).parent.parent / "config.yaml"
    with open(config_path, "r", encoding="utf-8") as f:
        return yaml.safe_load(f)


async def main():
    """启动 MCP Server"""
    # 加载环境变量
    env_path = Path(__file__).parent.parent / ".env"
    load_dotenv(env_path)

    # 加载配置
    config = load_config()

    # 设置日志
    log_config = config.get("logging", {})
    logging.basicConfig(
        level=getattr(logging, log_config.get("level", "INFO")),
        format="%(asctime)s [%(name)s] %(levelname)s: %(message)s",
    )

    logger = logging.getLogger(__name__)
    logger.info("正在启动 AI Desktop Agent MCP Server...")

    # 创建并运行 MCP Server
    server = create_mcp_server(config)

    # 使用 stdio 传输（Claude Code 标准方式）
    from mcp.server.stdio import stdio_server
    async with stdio_server() as (read_stream, write_stream):
        logger.info("MCP Server 已启动，等待 Claude Code 连接...")
        await server.run(read_stream, write_stream, server.create_initialization_options())


if __name__ == "__main__":
    asyncio.run(main())
