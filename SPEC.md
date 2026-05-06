# VoiceScribe - 项目规格

## 1. 项目概述

**名称:** VoiceScribe
**Bundle Identifier:** com.voicescribe.app
**Core Functionality:** 本地音频转写工具，支持 FunASR / VibeVoice MLX 双引擎、自动说话人分离、LLM 摘要
**Target Users:** 需要转录会议、访谈、播客的用户
**macOS Version:** macOS 13.0+
**Architecture:** SwiftUI (View) + Python (Backend via Process)

---

## 2. UI/UX 规格

### Window 结构
- **Main Window**: 单窗口工具，800×600，最小 700×500
- **Window Style**: NSWindow 带标题栏，可缩放
- **Navigation**: 无 Tab，纯单页布局，垂直堆叠

### 视觉设计

**配色方案:**
- Background: `#1E1E2E` (深色主背景)
- Surface: `#2A2A3C` (卡片/面板)
- Primary: `#7C6FE3` (主色调，按钮高亮)
- Secondary: `#4EC9B0` (成功/进度)
- Accent: `#F5A623` (警告/下载)
- Text Primary: `#FFFFFF`
- Text Secondary: `#A0A0B0`
- Border: `#3A3A4C`

**字体:**
- 标题: SF Pro Display Bold 18pt
- 正文: SF Pro Text Regular 13pt
- 代码/路径: SF Mono Regular 12pt

**间距:**
- 页面边距: 24pt
- 卡片内边距: 16pt
- 元素间距: 12pt
- 圆角: 12pt (卡片), 8pt (按钮)

### 视图层级 (从上到下)

```
┌─────────────────────────────────────────┐
│  Title: "VoiceScribe"              │  ← 标题栏
├─────────────────────────────────────────┤
│  [状态卡片] 环境检测面板                  │
│  - 检测 ffmpeg ✓ / funasr ✓ / 模型     │
│  - 缺失项显示 ⚠️ + 下载按钮             │
├─────────────────────────────────────────┤
│  [选择文件区]                           │
│  - 拖拽区域 (虚线框)                    │
│  - "选择音频文件" 按钮                  │
│  - 已选文件路径 (trunc)                │
├─────────────────────────────────────────┤
│  [设置面板]                             │
│  - 输出目录: [路径输入] [浏览]          │
│  - LLM 模型: [下拉选择] + [添加]       │
├─────────────────────────────────────────┤
│  [转写按钮]  [总结按钮]                 │
│  - 进度条 (转写/总结中显示)            │
│  - 日志输出区 (滚动)                    │
└─────────────────────────────────────────┘
```

---

## 3. 功能规格

### 3.1 环境检测
- 启动时自动检测: `ffmpeg`, `python3`, `funasr`
- 检测 FunASR 模型是否存在: `paraformer-zh`, `fsmn-vad`, `ct-punc`, `cam++`
- 缺失时显示警告 + 引导手动下载
- 提供一键复制下载命令

### 3.2 文件选择
- 支持拖拽音频文件到窗口
- 支持点击按钮打开文件选择框
- 支持格式: m4a, mp3, wav, mp4, mov, aac, flac
- 显示选中文件路径和时长

### 3.3 转写功能
- 调用 Python 脚本 `/Scripts/transcribe.py`
- 传入: 音频路径, 输出目录, LLM 模型名
- 实时读取 stdout 展示日志
- 转写完成后自动打开输出目录 (可选)
- 输出两个文件: `{原文件名}_funasr.json`, `{原文件名}_通话记录.md`

### 3.4 总结功能
- 转写完成后可点击「总结」
- 使用用户指定的 LLM API 模型
- 读取 Markdown 文件内容，调用 LLM 生成摘要
- 摘要写入 `{原文件名}_摘要.md`

### 3.5 LLM 模型管理
- 默认模型列表: `qwen-plus`, `qwen-max`, `qwen-turbo`, `claude-3-haiku`
- 支持用户自定义添加模型 (输入 API Base URL + Model Name)
- 保存到 UserDefaults

---

## 4. 技术规格

### 前端 (SwiftUI)
- 入口: `VoiceScribeApp.swift` (@main)
- 主视图: `ContentView.swift`
- 组件: `StatusCard.swift`, `FileDropZone.swift`, `SettingsPanel.swift`, `LogView.swift`
- Python 调用: `Process` (Foundation)
- 日志流: `Pipe` + `Publisher`

### 后端脚本 (Python)
- `Scripts/transcribe.py` - 转写核心逻辑
- `Scripts/summarize.py` - LLM 总结逻辑
- 依赖: `funasr`, `openai` (或其他兼容 API)

### 数据流
1. 用户选择音频 → Swift 传路径给 Python
2. Python 执行 FunASR 转写 → stdout 实时回传
3. Swift 解析日志 → 更新进度条
4. 转写完成 → 写 JSON + MD 文件
5. 用户点总结 → 调用 LLM API → 生成摘要

---

## 5. 验收标准

- [ ] 启动后自动检测环境，缺失项明确提示
- [ ] 拖拽音频文件到窗口能正确识别
- [ ] 转写过程有实时进度日志输出
- [ ] 转写结果保存为 JSON + Markdown 文件
- [ ] 总结功能使用自定义 LLM 模型
- [ ] UI 符合深色主题规格
- [ ] 可打包为 .app 分发
