#!/usr/bin/env python3
"""启动 LightRAG 知识图谱服务器

通过环境变量 (.env) 配置:
  LLM_BINDING=openai       → 使用 DeepSeek (OpenAI 兼容)
  EMBEDDING_BINDING=ollama → 使用本地 Ollama
  LIGHTRAG_API_KEY=xxx     → API 鉴权密钥

启动方式:
  python scripts/start_lightrag.py

也可以直接运行:
  python -m lightrag.api.lightrag_server --llm-binding openai --key lrag-secure-key-2026
"""

import os
import sys
from pathlib import Path

# 加载 .env 文件 (LightRAG 内置也会加载，这里先加载确保 PATH 等生效)
project_dir = Path(__file__).parent.parent
env_file = project_dir / ".env"
if env_file.exists():
    with open(env_file, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                key, _, val = line.partition("=")
                key, val = key.strip(), val.strip()
                if key and key not in os.environ:
                    os.environ[key] = val

if __name__ == "__main__":
    # 切换到项目目录 (LightRAG 相对路径基于 CWD)
    os.chdir(str(project_dir))

    # 导入并运行 LightRAG 内置 main
    from lightrag.api.lightrag_server import main

    # 覆盖 sys.argv 以传递参数
    sys.argv = [
        "lightrag_server",
        "--working-dir", os.environ.get("WORKING_DIR", str(project_dir / "lightrag_data")),
        "--input-dir", os.environ.get("INPUT_DIR", str(project_dir / "lightrag_inputs")),
        "--host", os.environ.get("HOST", "127.0.0.1"),
        "--port", os.environ.get("PORT", "9621"),
        "--key", os.environ.get("LIGHTRAG_API_KEY", "lrag-secure-key-2026"),
        "--llm-binding", "openai",
        "--log-level", os.environ.get("LOG_LEVEL", "INFO"),
    ]

    main()
