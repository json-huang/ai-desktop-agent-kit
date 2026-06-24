#!/usr/bin/env python3
"""AHK HTTP 服务 - Python 端提供 HTTP 接口，通过 subprocess 调用 AHK 执行操作"""

import asyncio
import json
import logging
import subprocess
import tempfile
from pathlib import Path

import uvicorn
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# AHK 配置
AHK_PATH = "C:/Program Files/AutoHotkey/v2/AutoHotkey64.exe"
PROJECT_DIR = Path(__file__).parent.parent
COMMANDS_DIR = PROJECT_DIR / "executor" / "commands"

app = FastAPI(title="AHK Executor Service")


class ExecuteRequest(BaseModel):
    action: str
    params: dict = {}


class ExecuteResponse(BaseModel):
    success: bool
    action: str = ""
    output: str = ""
    error: str = ""


# AHK 命令模板
AHK_TEMPLATES = {
    "click": 'Click {x}, {y}',
    "double_click": 'Click {x}, {y}, 2',
    "right_click": 'Click "Right", {x}, {y}',
    "drag": 'MouseMove {x1}, {y1}\nSleep 100\nClick "Down", {x1}, {y1}\nSleep 100\nMouseMove {x2}, {y2}, 10\nSleep 100\nClick "Up", {x2}, {y2}',
    "scroll": 'MouseMove {x}, {y}\nSleep 50\nClick "Wheel{direction}", {x}, {y}, {amount}',
    "type_text": 'SendText "{text}"',
    "press_keys": 'Send "{keys}"',
    "open_app": 'Run "{target}"',
    "close_app": 'WinClose "{target}"',
    "manage_window_maximize": 'WinMaximize "{target}"',
    "manage_window_minimize": 'WinMinimize "{target}"',
    "manage_window_restore": 'WinRestore "{target}"',
    "manage_window_activate": 'WinActivate "{target}"',
    "manage_window_close": 'WinClose "{target}"',
    "manage_window_move": 'WinMove {x}, {y}, {w}, {h}, "{target}"',
    "manage_window_resize": 'WinMove , , {w}, {h}, "{target}"',
    "clipboard_get": '',
    "clipboard_set": 'A_Clipboard := "{text}"',
    "wait": 'Sleep {ms}',
}


def generate_ahk_script(action: str, params: dict) -> str:
    """生成 AHK v2 脚本"""
    # 处理 manage_window 的子操作
    if action == "manage_window":
        sub_action = params.get("action", "activate")
        template_key = f"manage_window_{sub_action}"
        params = {**params, "target": params.get("target", "")}
    else:
        template_key = action

    template = AHK_TEMPLATES.get(template_key)
    if template is None:
        return None

    # 填充参数
    try:
        # 处理特殊字符
        safe_params = {}
        for k, v in params.items():
            if isinstance(v, str):
                v = v.replace('"', '""').replace('\n', '`n')
            safe_params[k] = v

        cmd = template.format(**safe_params)
    except KeyError as e:
        return None

    return f"""#Requires AutoHotkey v2.0
#SingleInstance Force
{cmd}
Exit 0
"""


async def execute_ahk(action: str, params: dict) -> dict:
    """通过 subprocess 执行 AHK 脚本"""
    # 特殊处理 clipboard_get
    if action == "clipboard_get":
        script = """#Requires AutoHotkey v2.0
#SingleInstance Force
text := A_Clipboard
FileAppend text, "*"
Exit 0
"""
    elif action == "run_command":
        cmd = params.get("command", "")
        # 直接用 Python subprocess 执行系统命令
        try:
            proc = await asyncio.create_subprocess_shell(
                cmd,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )
            stdout, stderr = await proc.communicate()
            return {
                "success": proc.returncode == 0,
                "output": stdout.decode("utf-8", errors="replace"),
                "error": stderr.decode("utf-8", errors="replace") if proc.returncode != 0 else "",
            }
        except Exception as e:
            return {"success": False, "error": str(e)}

    elif action == "screenshot":
        # 用 Python 的 mss 截图
        import mss
        from PIL import Image
        import io
        import base64

        with mss.mss() as sct:
            monitor = sct.monitors[1]
            screenshot = sct.grab(monitor)
            img = Image.frombytes("RGB", screenshot.size, screenshot.bgra, "raw", "BGRX")
            buffer = io.BytesIO()
            img.save(buffer, format="PNG")
            b64 = base64.b64encode(buffer.getvalue()).decode()
            return {"success": True, "screenshot_base64": b64[:100] + "...(truncated)"}

    else:
        script = generate_ahk_script(action, params)
        if script is None:
            return {"success": False, "error": f"未知操作: {action}"}

    # 写入临时文件并执行
    try:
        with tempfile.NamedTemporaryFile(mode="w", suffix=".ahk", delete=False, encoding="utf-8") as f:
            f.write(script)
            script_path = f.name

        proc = await asyncio.create_subprocess_exec(
            AHK_PATH, "/script", script_path,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        stdout, stderr = await asyncio.wait_for(proc.communicate(), timeout=10)

        if proc.returncode == 0:
            result = {"success": True, "action": action}
            if stdout:
                result["output"] = stdout.decode("utf-8", errors="replace").strip()
            return result
        else:
            return {
                "success": False,
                "error": stderr.decode("utf-8", errors="replace").strip() or f"AHK 退出码: {proc.returncode}",
            }

    except asyncio.TimeoutError:
        return {"success": False, "error": "AHK 执行超时"}
    except Exception as e:
        return {"success": False, "error": str(e)}
    finally:
        try:
            Path(script_path).unlink(missing_ok=True)
        except Exception:
            pass


@app.get("/health")
async def health():
    return {"status": "ok"}


@app.post("/execute")
async def execute(req: ExecuteRequest) -> ExecuteResponse:
    """执行 AHK 操作"""
    logger.info(f"执行: {req.action} {req.params}")
    result = await execute_ahk(req.action, req.params)
    return ExecuteResponse(
        success=result.get("success", False),
        action=req.action,
        output=result.get("output", ""),
        error=result.get("error", ""),
    )


if __name__ == "__main__":
    uvicorn.run(app, host="127.0.0.1", port=18600, log_level="info")
