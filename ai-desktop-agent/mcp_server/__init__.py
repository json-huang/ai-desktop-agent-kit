# mcp_server/__init__.py
"""MCP Server - 给 Claude Code 提供工具接口"""

from .server import create_mcp_server

__all__ = ["create_mcp_server"]
