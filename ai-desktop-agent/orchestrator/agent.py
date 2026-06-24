# orchestrator/agent.py
"""主控 Agent - 编排视觉、执行、规划三大模块"""

import asyncio
import json
import logging
from dataclasses import dataclass, field
from typing import Any

from openai import AsyncOpenAI

from .planner import Planner, PlanStep
from vision import ScreenAnalyzer, ElementLocator
from executor import AHKBridge

logger = logging.getLogger(__name__)


@dataclass
class ExecutionResult:
    """单步执行结果"""
    step: PlanStep
    success: bool
    output: Any = None
    error: str | None = None
    screenshot_after: bytes | None = None


@dataclass
class TaskResult:
    """完整任务结果"""
    instruction: str
    steps: list[ExecutionResult] = field(default_factory=list)
    overall_success: bool = False
    summary: str = ""

    @property
    def failed_steps(self) -> list[ExecutionResult]:
        return [s for s in self.steps if not s.success]


class DesktopAgent:
    """桌面自动化智能体

    协调 Agent-S (视觉) 和 AHK (执行) 完成用户指令。

    用法:
        agent = DesktopAgent(config)
        result = await agent.execute("打开记事本，输入 Hello World")
    """

    def __init__(self, config: dict):
        self.config = config
        self.llm_config = config["llm"]

        # 初始化 LLM 客户端
        self.client = self._init_llm_client()

        # 初始化子模块
        self.planner = Planner(self.client, self.llm_config)
        self.analyzer = ScreenAnalyzer(config.get("vision", {}))
        self.locator = ElementLocator(config.get("vision", {}))
        self.executor = AHKBridge(config.get("executor", {}))

        # 执行参数
        self.max_retries = 3
        self.max_steps = 20

    def _init_llm_client(self) -> AsyncOpenAI:
        """根据配置初始化 LLM 客户端"""
        import os
        from dotenv import load_dotenv
        load_dotenv()

        provider = self.llm_config.get("provider", "deepseek")
        provider_config = self.llm_config.get("providers", {}).get(provider, {})

        api_key = os.getenv(provider_config.get("api_key_env", ""), "")
        base_url = provider_config.get("base_url", "")

        logger.info(f"初始化 LLM: {provider} @ {base_url}")
        return AsyncOpenAI(api_key=api_key, base_url=base_url)

    async def execute(self, instruction: str) -> TaskResult:
        """执行用户指令

        Args:
            instruction: 自然语言指令，如 "打开记事本，输入 Hello"

        Returns:
            TaskResult: 执行结果
        """
        logger.info(f"收到指令: {instruction}")
        result = TaskResult(instruction=instruction)

        try:
            # Step 1: 感知当前屏幕状态
            screen_state = await self.analyzer.see("描述当前桌面状态")

            # Step 2: 规划执行步骤
            steps = await self.planner.plan(instruction, screen_state)
            logger.info(f"规划了 {len(steps)} 个步骤")

            if len(steps) > self.max_steps:
                logger.warning(f"步骤数 {len(steps)} 超过上限 {self.max_steps}，截断")
                steps = steps[:self.max_steps]

            # Step 3: 逐步执行
            for i, step in enumerate(steps):
                logger.info(f"执行步骤 {i+1}/{len(steps)}: {step.description}")
                step_result = await self._execute_step(step)
                result.steps.append(step_result)

                if not step_result.success:
                    # 尝试恢复
                    recovered = await self._try_recover(step, step_result)
                    if recovered:
                        step_result.success = True
                        step_result.error = None
                    else:
                        logger.error(f"步骤 {i+1} 失败且无法恢复: {step_result.error}")
                        break

            # Step 4: 最终验证
            result.overall_success = all(s.success for s in result.steps)
            result.summary = await self._generate_summary(result)

        except Exception as e:
            logger.exception(f"执行异常: {e}")
            result.summary = f"执行失败: {e}"

        return result

    async def _execute_step(self, step: PlanStep) -> ExecutionResult:
        """执行单个步骤"""
        result = ExecutionResult(step=step, success=False)

        try:
            # 如果需要视觉定位
            if step.needs_target and step.target_description:
                coords = await self.locator.locate(step.target_description)
                if coords:
                    step.x, step.y = coords
                else:
                    result.error = f"无法定位目标: {step.target_description}"
                    return result

            # 执行动作
            output = await self.executor.execute_action(step.action, {
                "x": step.x,
                "y": step.y,
                "text": step.text,
                "keys": step.keys,
                "target": step.target_description,
                "params": step.params,
            })

            # 等待操作生效
            if step.wait_ms:
                await asyncio.sleep(step.wait_ms / 1000)

            # 截图验证
            if step.verify_after:
                screenshot = await self.analyzer.take_screenshot()
                verified = await self.analyzer.verify(
                    screenshot, step.expected_outcome
                )
                if not verified:
                    result.error = f"验证失败: 操作执行后状态不符合预期"
                    result.screenshot_after = screenshot
                    return result

            result.success = True
            result.output = output

        except Exception as e:
            result.error = str(e)
            logger.exception(f"步骤执行异常: {e}")

        return result

    async def _try_recover(self, step: PlanStep, result: ExecutionResult) -> bool:
        """尝试从失败中恢复"""
        for attempt in range(self.max_retries):
            logger.info(f"恢复尝试 {attempt + 1}/{self.max_retries}")

            # 让 LLM 分析失败原因并给出修正建议
            recovery = await self.planner.suggest_recovery(
                step, result.error, result.screenshot_after
            )

            if recovery:
                recovery_result = await self._execute_step(recovery)
                if recovery_result.success:
                    return True

        return False

    async def _generate_summary(self, result: TaskResult) -> str:
        """生成执行总结"""
        completed = sum(1 for s in result.steps if s.success)
        total = len(result.steps)

        if result.overall_success:
            return f"✅ 任务完成！共执行 {total} 个步骤，全部成功。"
        else:
            failed = result.failed_steps
            return (
                f"⚠️ 任务部分完成：{completed}/{total} 个步骤成功。\n"
                f"失败步骤: {', '.join(s.step.description for s in failed)}"
            )

    async def see_screen(self, instruction: str = "描述当前屏幕") -> dict:
        """查看并分析屏幕"""
        return await self.analyzer.see(instruction)

    async def close(self):
        """清理资源"""
        await self.executor.close()
