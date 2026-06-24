# executor/bridge.py
"""Python ↔ AutoHotkey 通信桥接"""

import asyncio
import json
import logging
import subprocess
from pathlib import Path
from typing import Any, Optional

import httpx

logger = logging.getLogger(__name__)


class AHKBridge:
    """AHK 执行桥接器

    支持三种通信方式:
    1. http - AHK 常驻 HTTP 服务（推荐）
    2. pipe - Windows Named Pipe
    3. subprocess - 每次调用启动新进程
    """

    def __init__(self, config: dict = None):
        config = config or {}
        self.ahk_path = config.get("ahk_path", "C:/Program Files/AutoHotkey/v2/AutoHotkey64.exe")
        self.method = config.get("method", "http")

        # HTTP 模式配置
        http_config = config.get("http", {})
        self.http_host = http_config.get("host", "127.0.0.1")
        self.http_port = http_config.get("port", 18600)
        self.http_base = f"http://{self.http_host}:{self.http_port}"

        # 项目根目录
        self.project_dir = Path(__file__).parent.parent
        self.ahk_scripts_dir = self.project_dir / "executor" / "commands"

        self._http_client: Optional[httpx.AsyncClient] = None

    async def _get_client(self) -> httpx.AsyncClient:
        """获取 HTTP 客户端"""
        if self._http_client is None:
            self._http_client = httpx.AsyncClient(timeout=30.0)
        return self._http_client

    async def execute_action(self, action: str, params: dict = None) -> dict:
        """执行操作

        Args:
            action: 操作类型 (click, type_text, press_keys, etc.)
            params: 操作参数

        Returns:
            执行结果
        """
        params = params or {}

        if self.method == "http":
            try:
                return await self._execute_http(action, params)
            except (httpx.ConnectError, httpx.TimeoutException) as e:
                logger.warning(f"HTTP 不可用，自动降级到 subprocess: {e}")
                self.method = "subprocess"
        
        if self.method == "subprocess":
            return await self._execute_subprocess(action, params)
        
        raise ValueError(f"不支持的通信方式: {self.method}")

    async def _execute_http(self, action: str, params: dict) -> dict:
        """通过 HTTP 执行"""
        client = await self._get_client()

        try:
            response = await client.post(
                f"{self.http_base}/execute",
                json={"action": action, "params": params},
            )
            response.raise_for_status()
            return response.json()
        except httpx.ConnectError:
            logger.error("无法连接到 AHK HTTP 服务，请确认服务已启动")
            raise
        except Exception as e:
            logger.exception(f"HTTP 执行失败: {e}")
            raise

    async def _execute_subprocess(self, action: str, params: dict) -> dict:
        """通过 subprocess 执行"""
        script = self._generate_ahk_command(action, params)

        try:
            proc = await asyncio.create_subprocess_exec(
                self.ahk_path, "/script", script,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )
            stdout, stderr = await proc.communicate()

            if proc.returncode != 0:
                return {"success": False, "error": stderr.decode()}

            try:
                return json.loads(stdout.decode())
            except json.JSONDecodeError:
                return {"success": True, "output": stdout.decode()}

        except Exception as e:
            logger.exception(f"Subprocess 执行失败: {e}")
            return {"success": False, "error": str(e)}

    def _generate_ahk_command(self, action: str, params: dict) -> str:
        """生成 AHK 命令脚本"""
        # 基础 AHK v2 命令映射
        commands = {
            "click": f'Click {params.get("x", 0)}, {params.get("y", 0)}',
            "double_click": f'Click {params.get("x", 0)}, {params.get("y", 0)}, 2',
            "right_click": f'Click Right {params.get("x", 0)}, {params.get("y", 0)}',
            "type_text": f'SendText "{params.get("text", "")}"',
            "press_keys": f'Send "{params.get("keys", "")}"',
            "open_app": f'Run "{params.get("target", "")}"',
            "close_app": f'WinClose "{params.get("target", "")}"',
            "wait": f'Sleep {params.get("ms", 500)}',
            "move": f'MouseMove ' + str(params.get("x", 0)) + ', ' + str(params.get("y", 0)),
            "manage_window": self._gen_window_command(params),
            "drag": self._gen_drag_command(params),
            "scroll": self._gen_scroll_command(params),
        }

        ahk_cmd = commands.get(action)
        if ahk_cmd is None:
            return f'Exit 1'

        return f"""
#Requires AutoHotkey v2.0
#SingleInstance Force
{ahk_cmd}
Exit 0
"""

    def _gen_window_command(self, params: dict) -> str:
        sub = params.get("action", "activate")
        t = str(params.get("target", "")).replace('"', '""')
        x, y = params.get("x", 0), params.get("y", 0)
        w, h = params.get("w", 800), params.get("h", 600)
        cmds = {
            "maximize": 'WinMaximize "' + t + '"',
            "minimize": 'WinMinimize "' + t + '"',
            "restore": 'WinRestore "' + t + '"',
            "activate": 'WinActivate "' + t + '"',
            "close": 'WinClose "' + t + '"',
            "move": 'WinMove ' + str(x) + ', ' + str(y) + ', ' + str(w) + ', ' + str(h) + ', "' + t + '"',
            "resize": 'WinMove , , ' + str(w) + ', ' + str(h) + ', "' + t + '"',
        }
        return cmds.get(sub, 'WinActivate "' + t + '"')

    def _gen_drag_command(self, params: dict) -> str:
        x1, y1 = params.get("x1", 0), params.get("y1", 0)
        x2, y2 = params.get("x2", 0), params.get("y2", 0)
        return ("MouseMove " + str(x1) + ", " + str(y1) + chr(10) +
                "Sleep 100" + chr(10) +
                "Click Down " + str(x1) + ", " + str(y1) + chr(10) +
                "Sleep 100" + chr(10) +
                "MouseMove " + str(x2) + ", " + str(y2) + ", 10" + chr(10) +
                "Sleep 100" + chr(10) +
                "Click Up " + str(x2) + ", " + str(y2))

    def _gen_scroll_command(self, params: dict) -> str:
        x, y = params.get("x", 0), params.get("y", 0)
        direction = "WheelUp" if params.get("direction", "up") == "up" else "WheelDown"
        amount = params.get("amount", 3)
        return ("MouseMove " + str(x) + ", " + str(y) + chr(10) +
                "Sleep 50" + chr(10) +
                "Click " + direction + " " + str(x) + ", " + str(y) + ", " + str(amount))

    # === 便捷方法 ===

    async def click(self, x: int, y: int, button: str = "left") -> dict:
        """点击"""
        action = "right_click" if button == "right" else "click"
        return await self.execute_action(action, {"x": x, "y": y})

    async def double_click(self, x: int, y: int) -> dict:
        """双击"""
        return await self.execute_action("double_click", {"x": x, "y": y})

    async def type_text(self, text: str) -> dict:
        """输入文字"""
        return await self.execute_action("type_text", {"text": text})

    async def press_keys(self, keys: str) -> dict:
        """发送快捷键"""
        return await self.execute_action("press_keys", {"keys": keys})

    async def open_app(self, app: str) -> dict:
        """打开应用"""
        return await self.execute_action("open_app", {"target": app})

    async def close_app(self, app: str) -> dict:
        """关闭应用"""
        return await self.execute_action("close_app", {"target": app})

    async def manage_window(self, action: str, target: str, **kwargs) -> dict:
        """窗口管理，支持 move/resize 需要的 x, y, w, h"""
        return await self.execute_action("manage_window", {
            "action": action, "target": target, **kwargs
        })

    async def drag(self, x1: int, y1: int, x2: int, y2: int) -> dict:
        """拖拽"""
        return await self.execute_action("drag", {
            "x1": x1, "y1": y1, "x2": x2, "y2": y2
        })

    async def scroll(self, x: int, y: int, direction: str = "up", amount: int = 3) -> dict:
        """滚动"""
        return await self.execute_action("scroll", {
            "x": x, "y": y, "direction": direction, "amount": amount
        })

    async def close(self):
        """清理资源"""
        if self._http_client:
            await self._http_client.aclose()
            self._http_client = None
