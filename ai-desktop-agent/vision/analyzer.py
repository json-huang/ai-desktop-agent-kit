# vision/analyzer.py
"""屏幕分析器 - 使用 Agent-S 分析屏幕内容"""

import io
import json
import logging

from openai import AsyncOpenAI

from .screen import ScreenManager

logger = logging.getLogger(__name__)


class ScreenAnalyzer:
    """屏幕分析器

    使用视觉模型分析屏幕截图，理解 UI 内容。
    可选集成 Agent-S 进行更精确的 UI 元素识别。
    """

    def __init__(self, vision_config: dict = None, llm_config: dict = None):
        vision_config = vision_config or {}
        llm_config = llm_config or {}
        self.screen = ScreenManager(vision_config.get("screen", {}))
        self.vision_config = vision_config.get("grounding", {})
        self._agent_s = None

        # 视觉分析用的 LLM -- 接收独立的 LLM 配置
        self._init_vision_llm(llm_config)

    def _init_vision_llm(self, llm_config: dict = None):
        """初始化视觉分析 LLM"""
        import os
        from dotenv import load_dotenv
        load_dotenv()

        llm_config = llm_config or {}
        provider = llm_config.get("provider", "openai")
        providers = llm_config.get("providers", {})
        provider_config = providers.get(provider, {})

        api_key = os.getenv(provider_config.get("api_key_env", "OPENAI_API_KEY"), "")
        base_url = provider_config.get("base_url", "https://api.openai.com/v1")

        self.vision_client = AsyncOpenAI(api_key=api_key, base_url=base_url)
        self.vision_model = provider_config.get("model", "gpt-4o")

    async def see(self, instruction: str = "描述当前屏幕内容") -> dict:
        """截图并分析

        Args:
            instruction: 分析指令

        Returns:
            分析结果 dict
        """
        screenshot = self.screen.take_screenshot()

        try:
            import base64
            b64_image = base64.b64encode(screenshot).decode("utf-8")

            response = await self.vision_client.chat.completions.create(
                model=self.vision_model,
                messages=[
                    {
                        "role": "system",
                        "content": (
                            "你是一个屏幕分析助手。分析截图内容，返回 JSON 格式:\n"
                            '{"description": "屏幕描述", '
                            '"elements": [{"type": "按钮/文本框/图标...", '
                            '"text": "元素文字", "location": "位置描述", '
                            '"approx_x": 500, "approx_y": 300}], '
                            '"apps_visible": ["应用名"]}'
                        ),
                    },
                    {
                        "role": "user",
                        "content": [
                            {"type": "text", "text": instruction},
                            {
                                "type": "image_url",
                                "image_url": {
                                    "url": f"data:image/png;base64,{b64_image}",
                                },
                            },
                        ],
                    },
                ],
                response_format={"type": "json_object"},
                max_tokens=2000,
            )

            content = response.choices[0].message.content
            return json.loads(content)

        except Exception as e:
            logger.exception(f"屏幕分析失败: {e}")
            return {"description": f"分析失败: {e}", "elements": [], "apps_visible": []}

    async def verify(self, screenshot: bytes, expected: str) -> bool:
        """验证截图是否符合预期

        Args:
            screenshot: 截图 bytes
            expected: 预期状态描述

        Returns:
            是否符合预期
        """
        if not expected:
            return True

        try:
            import base64
            b64_image = base64.b64encode(screenshot).decode("utf-8")

            response = await self.vision_client.chat.completions.create(
                model=self.vision_model,
                messages=[
                    {
                        "role": "system",
                        "content": (
                            "你是验证助手。根据截图判断是否达到了预期状态。\n"
                            "返回 JSON: {\"verified\": true/false, \"reason\": \"原因\"}"
                        ),
                    },
                    {
                        "role": "user",
                        "content": [
                            {"type": "text", "text": f"预期状态: {expected}\n请验证截图是否符合预期。"},
                            {
                                "type": "image_url",
                                "image_url": {
                                    "url": f"data:image/png;base64,{b64_image}",
                                },
                            },
                        ],
                    },
                ],
                response_format={"type": "json_object"},
                max_tokens=500,
            )

            content = response.choices[0].message.content
            result = json.loads(content)
            return result.get("verified", False)

        except Exception as e:
            logger.exception(f"验证失败: {e}")
            return False

    async def take_screenshot(self) -> bytes:
        """截图（供外部调用）"""
        return self.screen.take_screenshot()
