# mcp_server/server.py
"""MCP Server - 给 Claude Code 提供工具接口"""

import asyncio
import json
import logging
from typing import Any

from mcp.server import Server
from mcp import types
import os
import subprocess
import tempfile
import re as _re
from pathlib import Path

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
        description="执行桌面自动化任务。提供自然语言指令（会生成执行计划）或直接提供 DAG JSON 步骤数组",
        inputSchema={
            "type": "object",
            "properties": {
                "instruction": {"type": "string", "description": "自然语言指令，如'打开记事本，输入今天的日期'"},
                "dag": {"type": "array", "description": "DAG 步骤数组 (JSON)。提供此参数可跳过规划阶段直接执行"},
                "output_dir": {"type": "string", "description": "输出目录（可选，默认临时目录）"},
                "dry_run": {"type": "boolean", "default": False, "description": "模拟执行（不实际操作鼠标键盘）"},
            },
            "required": [],
        },
    ),
    types.Tool(
        name="resume_task",
        description="从 checkpoint 恢复中断的任务",
        inputSchema={
            "type": "object",
            "properties": {
                "output_dir": {"type": "string", "description": "之前任务的输出目录（含 checkpoint.json）"},
            },
            "required": ["output_dir"],
        },
    ),
    types.Tool(
        name="task_status",
        description="查询之前任务的状态",
        inputSchema={
            "type": "object",
            "properties": {
                "output_dir": {"type": "string", "description": "任务的输出目录"},
            },
            "required": ["output_dir"],
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


# ============================================================
# PowerShell Executor Bridge (Phase 03)
# Bridges MCP execute_task -> executor.ps1 via subprocess
# ============================================================

_execlog = logging.getLogger(__name__)

_SCRIPTS_DIR = os.path.expanduser(os.environ.get(
    "AGENT_SCRIPTS_DIR",
    os.path.join(os.environ.get("USERPROFILE", "~"), ".claude", "scripts")
))
_EXECUTOR_PS1 = os.path.join(_SCRIPTS_DIR, "executor.ps1")
_POWERSHELL = "powershell.exe"


async def _executor_execute(goal: str = "", output_dir: str = "", dag: list = None, dry_run: bool = False) -> dict:
    """Call executor.ps1 via subprocess to execute a task.

    Args:
        goal: Natural language instruction (triggers auto-planning via planner.ps1)
        output_dir: Output directory for results/checkpoints
        dag: Pre-built DAG steps list (bypasses planning phase)
        dry_run: Simulate without real mouse/keyboard actions
    """
    if not goal and not dag:
        return {"success": False, "error": "instruction or dag is required"}

    if not output_dir:
        output_dir = os.path.join(tempfile.gettempdir(), f"agent_task_{os.urandom(4).hex()}")

    os.makedirs(output_dir, exist_ok=True)

    cmd = [
        _POWERSHELL, "-NoProfile", "-ExecutionPolicy", "Bypass",
        "-File", _EXECUTOR_PS1,
    ]

    # If dag is provided, write it to file and use -DagPath
    if dag:
        dag_path = os.path.join(output_dir, "dag.json")
        with open(dag_path, "w", encoding="utf-8") as f:
            json.dump(dag, f, ensure_ascii=False, indent=2)
        cmd += ["-execDagPath", dag_path]
    else:
        cmd += ["-execGoal", goal]

    cmd += ["-execOutputDir", output_dir]
    if dry_run:
        cmd += ["-DryRun"]

    _execlog.info(f"executor: launching for goal='{goal[:60]}...'")
    try:
        proc = await asyncio.create_subprocess_exec(
            *cmd,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        stdout, stderr = await asyncio.wait_for(
            proc.communicate(), timeout=300
        )
    except asyncio.TimeoutError:
        return {"success": False, "error": "executor timed out (300s)", "output_dir": output_dir}

    output = stdout.decode("utf-8", errors="replace") + stderr.decode("utf-8", errors="replace")

    # Parse result
    completed = "EXECUTOR_COMPLETE" in output
    task_id = "unknown"
    steps_completed = 0
    steps_total = 0

    for line in output.splitlines():
        if "EXECUTOR_COMPLETE" in line:
            import re
            m = _re.search(r"(\d+)/(\d+)", line)
            if m:
                steps_completed, steps_total = int(m[1]), int(m[2])
        if "task_id=" in line:
            task_id = line.split("task_id=")[-1].split()[0].strip()

    # Read task_result.json
    result_path = os.path.join(output_dir, "task_result.json")
    if not os.path.exists(result_path):
        # executor may have written to Desktop
        alt_path = os.path.join(os.environ.get("USERPROFILE", ""), "Desktop", "task_result.json")
        if os.path.exists(alt_path):
            result_path = alt_path

    task_result = {}
    if os.path.exists(result_path):
        try:
            with open(result_path, encoding="utf-8") as f:
                task_result = json.load(f)
        except Exception:
            pass

    return {
        "success": completed,
        "task_id": task_id,
        "steps_completed": steps_completed or task_result.get("steps_completed", 0),
        "steps_total": steps_total or task_result.get("steps_total", 0),
        "final_state": task_result.get("final_state", "UNKNOWN"),
        "output_dir": output_dir,
        "checkpoint": os.path.join(output_dir, "checkpoint.json"),
        "result_file": result_path,
    }


async def _executor_resume(output_dir: str) -> dict:
    """Resume a task from checkpoint."""
    checkpoint = os.path.join(output_dir, "checkpoint.json")
    if not os.path.exists(checkpoint):
        return {"success": False, "error": f"checkpoint not found: {checkpoint}"}

    cmd = [
        _POWERSHELL, "-NoProfile", "-ExecutionPolicy", "Bypass",
        "-File", _EXECUTOR_PS1,
        "-execOutputDir", output_dir,
    ]
    # Note: executor auto-detects checkpoint.json in output dir

    try:
        proc = await asyncio.create_subprocess_exec(
            *cmd,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        stdout, stderr = await asyncio.wait_for(
            proc.communicate(), timeout=300
        )
    except asyncio.TimeoutError:
        return {"success": False, "error": "executor timed out", "output_dir": output_dir}

    output = stdout.decode("utf-8", errors="replace") + stderr.decode("utf-8", errors="replace")
    return {
        "success": "EXECUTOR_COMPLETE" in output,
        "output_dir": output_dir,
        "raw_output": output[-500:],
    }


def _task_status(output_dir: str) -> dict:
    """Read task status from output directory."""
    result_path = os.path.join(output_dir, "task_result.json")
    checkpoint_path = os.path.join(output_dir, "checkpoint.json")

    status = {"output_dir": output_dir}

    if os.path.exists(result_path):
        try:
            with open(result_path, encoding="utf-8") as f:
                status["result"] = json.load(f)
        except Exception as e:
            status["result_error"] = str(e)
    else:
        status["result"] = None

    if os.path.exists(checkpoint_path):
        try:
            with open(checkpoint_path, encoding="utf-8") as f:
                cp = json.load(f)
                status["checkpoint"] = {
                    "step": cp.get("current_step_index", -1),
                    "retry": cp.get("retry_count", 0),
                    "strategy": cp.get("strategy_index", 0),
                }
        except Exception as e:
            status["checkpoint_error"] = str(e)
    else:
        status["checkpoint"] = None

    return status




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
        dag = args.get("dag")
        instruction = args.get("instruction", "")
        output_dir = args.get("output_dir", "")
        dry_run = args.get("dry_run", False)
        return await _executor_execute(instruction, output_dir, dag, dry_run)

    elif name == "resume_task":
        return await _executor_resume(args["output_dir"])

    elif name == "task_status":
        return _task_status(args["output_dir"])

    elif name == "wait":
        ms = args.get("ms", 1000)
        await asyncio.sleep(ms / 1000)
        return {"success": True, "waited_ms": ms}

    else:
        return {"error": f"未知工具: {name}"}
