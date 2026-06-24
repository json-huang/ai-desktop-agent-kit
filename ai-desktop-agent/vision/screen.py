# vision/screen.py
"""屏幕截图管理"""

import io
import logging
from typing import Optional

import mss
from PIL import Image

logger = logging.getLogger(__name__)


class ScreenManager:
    """屏幕截图管理器

    支持全屏截图、区域截图、指定窗口截图。
    """

    def __init__(self, config: dict = None):
        config = config or {}
        self.display_index = config.get("display", 0)
        self.format = config.get("format", "png")
        self.quality = config.get("quality", 95)

    def take_screenshot(
        self,
        region: tuple[int, int, int, int] | None = None,
    ) -> bytes:
        """截取屏幕

        Args:
            region: (x, y, width, height) 区域截图，None 为全屏

        Returns:
            PNG 图片 bytes
        """
        with mss.mss() as sct:
            if region:
                x, y, w, h = region
                monitor = {"left": x, "top": y, "width": w, "height": h}
            else:
                monitor = sct.monitors[self.display_index + 1]  # 0 是全部屏幕

            screenshot = sct.grab(monitor)
            img = Image.frombytes("RGB", screenshot.size, screenshot.bgra, "raw", "BGRX")

            buffer = io.BytesIO()
            img.save(buffer, format="PNG", quality=self.quality)
            return buffer.getvalue()

    def take_screenshot_pil(self, region=None) -> Image.Image:
        """截取屏幕，返回 PIL Image"""
        data = self.take_screenshot(region)
        return Image.open(io.BytesIO(data))

    def get_screen_size(self) -> tuple[int, int]:
        """获取屏幕分辨率"""
        with mss.mss() as sct:
            monitor = sct.monitors[self.display_index + 1]
            return monitor["width"], monitor["height"]

    def save_screenshot(self, path: str, region=None) -> str:
        """截图并保存到文件"""
        data = self.take_screenshot(region)
        with open(path, "wb") as f:
            f.write(data)
        return path
