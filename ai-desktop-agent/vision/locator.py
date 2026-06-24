# vision/locator.py
"""UI 元素定位器 - 使用 Agent-S 的 grounding 能力定位屏幕元素"""

import logging
from typing import Optional

from .screen import ScreenManager

logger = logging.getLogger(__name__)


class ElementLocator:
    """UI 元素定位器

    使用 Agent-S 的 grounding 模型精确定位屏幕上的 UI 元素。
    备选方案：使用视觉 LLM 进行粗略定位。
    """

    def __init__(self, vision_config: dict = None, llm_config: dict = None):
        vision_config = vision_config or {}
        llm_config = llm_config or {}
        self.screen = ScreenManager(vision_config.get("screen", {}))
        self.grounding_config = vision_config.get("grounding", {})
        self._grounding_model = None
        self._analyzer = None
        self._llm_config = llm_config

    async def locate(self, description: str) -> Optional[tuple[int, int]]:
        """定位目标元素

        Args:
            description: 目标描述，如 "记事本窗口的关闭按钮"

        Returns:
            (x, y) 坐标，或 None 表示未找到
        """
        # 优先使用 Agent-S grounding
        coords = await self._locate_with_grounding(description)
        if coords:
            return coords

        # 回退到视觉 LLM
        coords = await self._locate_with_vision(description)
        return coords

    async def _locate_with_grounding(self, description: str) -> Optional[tuple[int, int]]:
        """使用 Agent-S grounding 模型定位"""
        try:
            from gui_agents.s3.agents.grounding import OSWorldACI
            from gui_agents.s3.agents.agent_s import AgentS3

            # 懒加载 grounding agent
            if self._grounding_model is None:
                import os
                from dotenv import load_dotenv
                load_dotenv()

                engine_params = {
                    "engine_type": "openai",
                    "model": "gpt-4o-mini",  # 轻量模型做规划
                }

                ground_config = self.grounding_config
                engine_params_grounding = {
                    "engine_type": "huggingface",
                    "model": ground_config.get("model", "ui-tars-1.5-7b"),
                    "base_url": ground_config.get("base_url", "http://localhost:8080"),
                    "grounding_width": ground_config.get("width", 1920),
                    "grounding_height": ground_config.get("height", 1080),
                }

                self._grounding_model = OSWorldACI(
                    platform="windows",
                    engine_params_for_generation=engine_params,
                    engine_params_for_grounding=engine_params_grounding,
                )

            # 截图并定位
            screenshot = self.screen.take_screenshot()
            import io
            obs = {"screenshot": screenshot}
            info, action = self._grounding_model.predict(
                instruction=f"找到: {description}",
                observation=obs,
            )

            if info and "coordinates" in info:
                x, y = info["coordinates"]
                logger.info(f"Grounding 定位成功: ({x}, {y})")
                return (int(x), int(y))

        except ImportError:
            logger.warning("Agent-S 未安装，跳过 grounding 定位")
        except Exception as e:
            logger.warning(f"Grounding 定位失败: {e}")

        return None

    async def _locate_with_vision(self, description: str) -> Optional[tuple[int, int]]:
        """使用视觉 LLM 粗略定位（备选方案）"""
        try:
            if self._analyzer is None:
                from .analyzer import ScreenAnalyzer
                self._analyzer = ScreenAnalyzer(self.vision_config, self._llm_config)
            analyzer = self._analyzer

            result = await analyzer.see(
                f"找到 '{description}' 的精确像素坐标位置"
            )

            elements = result.get("elements", [])
            for elem in elements:
                if self._matches_description(elem, description):
                    x = elem.get("approx_x")
                    y = elem.get("approx_y")
                    if x is not None and y is not None:
                        logger.info(f"视觉定位成功: ({x}, {y})")
                        return (int(x), int(y))

        except Exception as e:
            logger.warning(f"视觉定位失败: {e}")

        return None

    def _matches_description(self, element: dict, description: str) -> bool:
        """检查元素是否匹配描述"""
        desc_lower = description.lower()
        text = (element.get("text", "") or "").lower()
        elem_type = (element.get("type", "") or "").lower()
        location = (element.get("location", "") or "").lower()

        # 简单关键词匹配
        keywords = desc_lower.split()
        for kw in keywords:
            if kw in text or kw in elem_type or kw in location:
                return True
        return False


