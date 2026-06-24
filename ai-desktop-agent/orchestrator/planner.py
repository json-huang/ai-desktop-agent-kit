# orchestrator/planner.py
"""任务规划器 - 将自然语言指令分解为可执行步骤"""

import json
import logging
from dataclasses import dataclass, field
from typing import Any

from openai import AsyncOpenAI

logger = logging.getLogger(__name__)

PLAN_SYSTEM_PROMPT = """你是一个 Windows 桌面自动化任务规划器。
你的任务是将用户的自然语言指令分解为一系列可执行的操作步骤。

## 可用操作

1. click(x, y) - 点击指定坐标
2. double_click(x, y) - 双击
3. right_click(x, y) - 右键点击
4. type_text(text) - 输入文字
5. press_keys(keys) - 发送快捷键，如 "ctrl+c", "alt+f4"
6. open_app(app) - 打开应用，如 "notepad.exe", "calc.exe"
7. close_app(app) - 关闭应用
8. manage_window(action, target) - 窗口操作: maximize/minimize/close/activate
9. file_operation(action, src, dst) - 文件操作: copy/move/delete/rename
10. wait(ms) - 等待指定毫秒
11. see_screen(instruction) - 查看屏幕
12. verify_action(expected) - 验证操作结果

## 输出格式

返回 JSON 数组，每个元素包含:
- action: 操作类型
- description: 这一步要做什么（中文）
- target_description: 需要点击/操作的目标描述（用于视觉定位）
- params: 操作参数
- verify_after: 是否需要验证
- expected_outcome: 预期结果描述
- wait_ms: 执行后等待时间（毫秒）

## 注意事项
- 每一步都要有清晰的描述
- 涉及点击的操作，用 target_description 描述目标，不要猜测坐标
- 复杂任务要拆分成小步骤
- 考虑等待时间（应用启动、文件复制等）
- 每个关键操作后设置 verify_after: true
"""


@dataclass
class PlanStep:
    """执行步骤"""
    action: str
    description: str
    target_description: str | None = None
    x: int | None = None
    y: int | None = None
    text: str | None = None
    keys: str | None = None
    params: dict = field(default_factory=dict)
    needs_target: bool = False
    verify_after: bool = False
    expected_outcome: str = ""
    wait_ms: int = 0

    @classmethod
    def from_dict(cls, data: dict) -> "PlanStep":
        action = data.get("action", "")
        needs_target = action in ("click", "double_click", "right_click")

        return cls(
            action=action,
            description=data.get("description", ""),
            target_description=data.get("target_description"),
            text=data.get("params", {}).get("text") or data.get("text"),
            keys=data.get("params", {}).get("keys") or data.get("keys"),
            params=data.get("params", {}),
            needs_target=needs_target,
            verify_after=data.get("verify_after", False),
            expected_outcome=data.get("expected_outcome", ""),
            wait_ms=data.get("wait_ms", 500),
        )


class Planner:
    """任务规划器"""

    def __init__(self, client: AsyncOpenAI, llm_config: dict):
        self.client = client
        self.provider = llm_config.get("provider", "deepseek")
        self.provider_config = llm_config.get("providers", {}).get(self.provider, {})
        self.model = self.provider_config.get("model", "deepseek-chat")

    async def plan(self, instruction: str, screen_state: dict | None = None) -> list[PlanStep]:
        """将指令分解为执行步骤

        Args:
            instruction: 用户指令
            screen_state: 当前屏幕状态（可选）

        Returns:
            执行步骤列表
        """
        user_msg = f"用户指令: {instruction}"
        if screen_state:
            user_msg += f"\n\n当前屏幕状态:\n{json.dumps(screen_state, ensure_ascii=False, indent=2)}"

        try:
            response = await self.client.chat.completions.create(
                model=self.model,
                messages=[
                    {"role": "system", "content": PLAN_SYSTEM_PROMPT},
                    {"role": "user", "content": user_msg},
                ],
                response_format={"type": "json_object"},
                temperature=0.2,
            )

            content = response.choices[0].message.content
            data = json.loads(content)

            # 兼容 {"steps": [...]} 或直接 [...]
            if isinstance(data, list):
                steps_data = data
            elif isinstance(data, dict) and "steps" in data:
                steps_data = data["steps"]
            else:
                steps_data = [data]

            steps = [PlanStep.from_dict(s) for s in steps_data]
            logger.info(f"规划了 {len(steps)} 个步骤")
            return steps

        except Exception as e:
            logger.exception(f"规划失败: {e}")
            # 返回一个简单的回退步骤
            return [PlanStep(
                action="see_screen",
                description="查看当前屏幕状态",
                verify_after=True,
                expected_outcome="能看到屏幕内容",
            )]

    async def suggest_recovery(
        self,
        failed_step: PlanStep,
        error: str | None,
        screenshot: bytes | None = None,
    ) -> PlanStep | None:
        """根据失败信息建议恢复步骤

        Args:
            failed_step: 失败的步骤
            error: 错误信息
            screenshot: 失败后的截图

        Returns:
            恢复步骤，或 None 表示无法恢复
        """
        prompt = f"""操作失败了，请分析原因并建议一个修正步骤。

失败的操作: {failed_step.description}
动作类型: {failed_step.action}
目标: {failed_step.target_description}
错误信息: {error or '无'}

请返回一个修正步骤的 JSON，格式同规划步骤。
如果无法修正，返回 {{"action": "none", "description": "无法修正"}}"""

        try:
            response = await self.client.chat.completions.create(
                model=self.model,
                messages=[
                    {"role": "system", "content": PLAN_SYSTEM_PROMPT},
                    {"role": "user", "content": prompt},
                ],
                response_format={"type": "json_object"},
                temperature=0.3,
            )

            content = response.choices[0].message.content
            data = json.loads(content)

            if data.get("action") == "none":
                return None

            return PlanStep.from_dict(data)

        except Exception as e:
            logger.exception(f"恢复建议生成失败: {e}")
            return None
