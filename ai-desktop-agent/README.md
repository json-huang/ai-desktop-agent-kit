# 🤖 AI Desktop Agent

基于 **Claude Code + Agent-S + AutoHotkey** 的 Windows 桌面自动化智能体。

## 架构

```
用户指令 → Claude Code (编排) → Agent-S (视觉) + AHK (执行) → Windows 桌面
```

### 三大组件

| 组件 | 角色 | 说明 |
|------|------|------|
| **Claude Code** | 🧠 大脑 | 任务理解、规划、决策、异常处理 |
| **Agent-S** | 👁️ 眼睛 | 截图分析、UI 识别、元素定位 |
| **AutoHotkey** | 🖐️ 双手 | 鼠标键盘、窗口管理、系统操作 |

## 支持的 LLM

| 模型 | 作为主推理模型 | 说明 |
|------|---------------|------|
| DeepSeek | ✅ | `base_url=https://api.deepseek.com` |
| MiMo | ✅ | 本地部署 (Ollama/vLLM)，OpenAI 兼容接口 |
| Claude | ✅ | 原生支持 |
| GPT | ✅ | 原生支持 |

## 快速开始

### 1. 安装依赖

```bash
# 创建 Python 3.12 虚拟环境
py -3.12 -m venv venv
venv\Scripts\activate

# 安装依赖
pip install -r requirements.txt

# 安装 Tesseract OCR (Windows)
# 下载: https://github.com/UB-Mannheim/tesseract/wiki
# 安装后添加到 PATH
```

### 2. 安装 AutoHotkey v2

下载: https://www.autohotkey.com/

### 3. 配置

```bash
# 复制环境变量模板
copy .env.example .env
# 编辑 .env 填入 API Key

# 编辑 config.yaml 选择你的 LLM 提供商
```

### 4. 下载 Grounding 模型

```bash
# UI-TARS 模型会自动从 HuggingFace 下载
# 或手动下载到 D:/ai-desktop-agent/models/grounding/
```

### 5. 启动

```bash
# 启动 AHK 执行服务
python scripts/start_ahk.py

# 启动 MCP Server (给 Claude Code 用)
python scripts/start_mcp.py

# 或启动完整服务
python scripts/start_all.py
```

## 项目结构

```
ai-desktop-agent/
├── orchestrator/          # Claude Code 编排层
├── vision/                # Agent-S 视觉层
├── executor/              # AHK 执行层
├── mcp_server/            # MCP Server
├── api/                   # REST API (可选)
├── scripts/               # 启动脚本
├── tests/                 # 测试
├── models/                # 模型存储 (D盘)
└── config.yaml            # 配置文件
```

## 使用示例

### 通过 Claude Code

```
> 帮我打开记事本，输入今天的日期，然后保存到桌面
> 把桌面上所有 PDF 文件移到 D 盘 Backup 文件夹
> 打开浏览器，搜索 "AutoHotkey v2 教程"，打开第一个结果
```

### 通过 Python API

```python
from orchestrator.agent import DesktopAgent

agent = DesktopAgent()
await agent.execute("打开计算器，计算 123 * 456")
```

## License

MIT
