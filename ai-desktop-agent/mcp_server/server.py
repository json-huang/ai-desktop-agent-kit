# mcp_server/server.py
"""MCP Server - 给 Claude Code 提供工具接口"""

import asyncio
import json
import logging
from typing import Any

from mcp.server import Server
from mcp import types

from orchestrator.agent import DesktopAgent
from vision import ScreenManager, ScreenAnalyzer, ElementLocator
from executor import AHKBridge

logger = logging.getLogger(__name__)

# 工具定义
TOOLS = [
    types.Tool(
        name="see_screen",
        description="截图并分析当前屏幕状态",
        inputSchema={
            "type": "object",
            "properties": {
                "instruction": {"type": "string", "default": "描述当前屏幕内容", "description": "分析指令"}
            },
        },
    ),
    types.Tool(
        name="locate_element",
        description="在屏幕上定位 UI 元素的位置",
        inputSchema={
            "type": "object",
            "properties": {
                "description": {"type": "string", "description": "目标描述，如'记事本窗口的文件菜单'"}
            },
            "required": ["description"],
        },
    ),
    types.Tool(
        name="click",
        description="点击屏幕上的指定位置或目标",
        inputSchema={
            "type": "object",
            "properties": {
                "x": {"type": "integer", "description": "X 坐标"},
                "y": {"type": "integer", "description": "Y 坐标"},
                "target": {"type": "string", "description": "目标描述，如'开始按钮'（会自动定位）"},
                "button": {"type": "string", "enum": ["left", "right"], "default": "left"},
            },
        },
    ),
    types.Tool(
        name="double_click",
        description="双击指定位置",
        inputSchema={
            "type": "object",
            "properties": {
                "x": {"type": "integer", "description": "X 坐标"},
                "y": {"type": "integer", "description": "Y 坐标"},
            },
            "required": ["x", "y"],
        },
    ),
    types.Tool(
        name="right_click",
        description="右键点击指定位置",
        inputSchema={
            "type": "object",
            "properties": {
                "x": {"type": "integer", "description": "X 坐标"},
                "y": {"type": "integer", "description": "Y 坐标"},
            },
            "required": ["x", "y"],
        },
    ),
    types.Tool(
        name="type_text",
        description="输入文字",
        inputSchema={
            "type": "object",
            "properties": {
                "text": {"type": "string", "description": "要输入的文字"},
            },
            "required": ["text"],
        },
    ),
    types.Tool(
        name="press_keys",
        description="发送快捷键",
        inputSchema={
            "type": "object",
            "properties": {
                "keys": {"type": "string", "description": "快捷键组合，如 ctrl+c, alt+f4, enter"},
            },
            "required": ["keys"],
        },
    ),
    types.Tool(
        name="open_app",
        description="打开应用程序",
        inputSchema={
            "type": "object",
            "properties": {
                "app": {"type": "string", "description": "应用名或路径，如 notepad.exe, calc"},
            },
            "required": ["app"],
        },
    ),
    types.Tool(
        name="close_app",
        description="关闭应用程序",
        inputSchema={
            "type": "object",
            "properties": {
                "app": {"type": "string", "description": "应用窗口标题或进程名"},
            },
            "required": ["app"],
        },
    ),
    types.Tool(
        name="manage_window",
        description="管理窗口（最大化/最小化/关闭/移动/调整大小）",
        inputSchema={
            "type": "object",
            "properties": {
                "action": {"type": "string", "enum": ["maximize", "minimize", "restore", "activate", "close", "move", "resize"]},
                "target": {"type": "string", "description": "窗口标题"},
                "x": {"type": "integer", "description": "X 坐标（move 操作）"},
                "y": {"type": "integer", "description": "Y 坐标（move 操作）"},
                "w": {"type": "integer", "description": "宽度（resize/move 操作）"},
                "h": {"type": "integer", "description": "高度（resize/move 操作）"},
            },
            "required": ["action", "target"],
        },
    ),
    types.Tool(
        name="file_operation",
        description="文件操作（copy/move/delete/rename/mkdir/exists/list）",
        inputSchema={
            "type": "object",
            "properties": {
                "action": {"type": "string", "enum": ["copy", "move", "delete", "rename", "mkdir", "exists", "list"]},
                "src": {"type": "string", "description": "源路径"},
                "dst": {"type": "string", "description": "目标路径（copy/move/rename 需要）"},
            },
            "required": ["action", "src"],
        },
    ),
    types.Tool(
        name="clipboard_get",
        description="获取剪贴板内容",
        inputSchema={"type": "object", "properties": {}},
    ),
    types.Tool(
        name="clipboard_set",
        description="设置剪贴板内容",
        inputSchema={
            "type": "object",
            "properties": {
                "text": {"type": "string", "description": "要设置的文字"},
            },
            "required": ["text"],
        },
    ),
    types.Tool(
        name="run_command",
        description="执行系统命令",
        inputSchema={
            "type": "object",
            "properties": {
                "command": {"type": "string", "description": "CMD 命令，如 dir, ipconfig"},
            },
            "required": ["command"],
        },
    ),
    types.Tool(
        name="verify_action",
        description="验证当前屏幕状态是否符合预期",
        inputSchema={
            "type": "object",
            "properties": {
                "expected": {"type": "string", "description": "预期状态描述，如'记事本已经打开并显示了文字'"},
            },
            "required": ["expected"],
        },
    ),
    types.Tool(
        name="execute_task",
        description="执行复杂的多步骤任务（自然语言指令）",
        inputSchema={
            "type": "object",
            "properties": {
                "instruction": {"type": "string", "description": "自然语言指令，如'打开记事本，输入今天的日期'"},
            },
            "required": ["instruction"],
        },
    ),
    types.Tool(
        name="wait",
        description="等待指定毫秒",
        inputSchema={
            "type": "object",
            "properties": {
                "ms": {"type": "integer", "default": 1000, "description": "等待时间（毫秒）"},
            },
        },
    ),
]


def create_mcp_server(config: dict = None) -> Server:
    """创建 MCP Server"""
    config = config or {}
    server = Server("ai-desktop-agent")

    # 初始化组件
    agent = DesktopAgent(config)
    screen = ScreenManager(config.get("vision", {}).get("screen", {}))
    analyzer = ScreenAnalyzer(config.get("vision", {}), config.get("llm", {}))
    locator = ElementLocator(config.get("vision", {}), config.get("llm", {}))
    executor = AHKBridge(config.get("executor", {}))

    @server.list_tools()
    async def list_tools() -> list[types.Tool]:
        return TOOLS

    @server.call_tool()
    async def call_tool(name: str, arguments: dict) -> list[types.TextContent]:
        try:
            result = await _handle_tool(name, arguments, agent, analyzer, locator, executor)
            return [types.TextContent(type="text", text=json.dumps(result, ensure_ascii=False))]
        except Exception as e:
            logger.exception(f"工具执行失败: {name}")
            return [types.TextContent(type="text", text=json.dumps({"error": str(e)}))]

    return server


async def _handle_tool(
    name: str,
    args: dict,
    agent: DesktopAgent,
    analyzer: ScreenAnalyzer,
    locator: ElementLocator,
    executor: AHKBridge,
) -> Any:
    """分发工具调用"""

    if name == "see_screen":
        instruction = args.get("instruction", "描述当前屏幕内容")
        return await analyzer.see(instruction)

    elif name == "locate_element":
        coords = await locator.locate(args["description"])
        if coords:
            return {"found": True, "x": coords[0], "y": coords[1]}
        return {"found": False, "error": "未找到目标元素"}

    elif name == "click":
        x, y = args.get("x"), args.get("y")
        target = args.get("target")
        button = args.get("button", "left")

        if target:
            coords = await locator.locate(target)
            if coords:
                x, y = coords
            else:
                return {"success": False, "error": f"无法定位: {target}"}

        if x is None or y is None:
            return {"success": False, "error": "需要提供坐标或目标描述"}

        return await executor.click(x, y, button)

    elif name == "double_click":
        return await executor.double_click(args["x"], args["y"])

    elif name == "right_click":
        return await executor.click(args["x"], args["y"], "right")

    elif name == "type_text":
        return await executor.type_text(args["text"])

    elif name == "press_keys":
        return await executor.press_keys(args["keys"])

    elif name == "open_app":
        return await executor.open_app(args["app"])

    elif name == "close_app":
        return await executor.close_app(args["app"])

    elif name == "manage_window":
        kwargs = {}
        for opt in ("x", "y", "w", "h"):
            if opt in args:
                kwargs[opt] = args[opt]
        return await executor.manage_window(args["action"], args["target"], **kwargs)

    elif name == "file_operation":
        return await executor.execute_action("file_operation", {
            "action": args["action"],
            "src": args["src"],
            "dst": args.get("dst", ""),
        })

    elif name == "clipboard_get":
        return await executor.execute_action("clipboard_get", {})

    elif name == "clipboard_set":
        return await executor.execute_action("clipboard_set", {"text": args["text"]})

    elif name == "run_command":
        return await executor.execute_action("run_command", {"command": args["command"]})

    elif name == "verify_action":
        screenshot = await analyzer.take_screenshot()
        verified = await analyzer.verify(screenshot, args["expected"])
        return {"verified": verified, "expected": args["expected"]}

    elif name == "execute_task":
        result = await agent.execute(args["instruction"])
        return {
            "success": result.overall_success,
            "summary": result.summary,
            "steps_completed": len(result.steps),
            "steps_failed": len(result.failed_steps),
        }

    elif name == "wait":
        ms = args.get("ms", 1000)
        await asyncio.sleep(ms / 1000)
        return {"success": True, "waited_ms": ms}

    else:
        return {"error": f"未知工具: {name}"}
