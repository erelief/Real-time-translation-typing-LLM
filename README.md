```
 ____ _____ _____ _____     _     _     __  __ 
|  _ \_   _|_   _|_   _|   | |   | |   |  \/  |
| |_) || |   | |   | |_____| |   | |   | |\/| |
|  _ < | |   | |   | |_____| |___| |___| |  | |
|_| \_\|_|   |_|   |_|     |_____|_____|_|  |_|
                                               
```

# Real-time Translation Typing - LLM Edition


![图 0](images/16771b28ffa808f0c407a1248a0c8a1775923cd97135443f8899d0adb9a668bc.png)

## 项目说明
- 本项目 fork 自 [sxzxs/Real-time Translation Typing](https://github.com/sxzxs/Real-time-translation-typing)，只是将项目改成了由大语言模型驱动的版本，主要功能归功于于原开发者
- 所有的更改通过在 Claude Code 中配置了 GLM-4.7 后 Vibe Coding 而成，我自己不会编程
- 所有的 LOL 功能原项目本身存在，我自己不玩所以***无法确认效果***
- 绝大部分技术说明也由 AI 直接生成，请仔细甄别
- 请注意隐私，如有需求请自行配置本地大模型

查看详细的版本更新历史，请参阅 [CHANGELOG.md](CHANGELOG.md)

## 原功能

* 实时打字翻译（转为大语言模型驱动）
* 编程命名转换

## 功能变化
- `+` 增加了目标语言切换功能，可自行输入想要翻译成的目标语言

- `+` 可以拖动输入窗口

- `+` 更直观的操作设计

- `-` 从完全实时改成了默认手动发送翻译请求，减少 Token 消耗（有需求可切回实时模式）

- `-` 去掉了原来传统翻译服务的功能（包括网页和 API）

- `-` 去掉了对应的语音相关功能，现在已有更好用的 AI 方式

- `?` LOL 内部功能未修改，但不确定可行性
 

## ⚠️ 重要提示

**本版本需要配置 OpenAI 兼容 API 才能使用！**
**本软件基于 Widnows 下的 AutoHotKey 实现，不兼容其他平台**

### 快速配置（仅需 2 步）

**步骤 1**: 获取 API Key
- 选择任何提供 OpenAI 兼容 API 的服务（如 OpenAI、DeepSeek、智谱 AI 等）
- 注册并获取 API Key

**步骤 2**: 填写配置文件
- 运行程序后会自动创建 `config.json`
- 编辑 `config.json`，填写你的 API Key 和 base_url
- 重新运行程序

详细配置说明请参考下方的"配置说明"章节。

## 使用方法

### 🟦 方式一：使用编译版（推荐普通用户）

**适用场景**：没有安装 AutoHotkey，只想使用程序

1. 下载最新版本的发布包（包含 `实时打字翻译.exe` 和 `实时打字翻译.ahk`）
2. 解压到任意目录
3. 双击 `实时打字翻译.exe` 运行
4. 首次运行会自动创建 `config.json` 配置文件
5. 编辑配置文件，填入你的 API Key
6. 重新运行程序

**优点**：
- 无需安装 AutoHotkey
- 开箱即用
- 适合大多数用户

**注意**：
- `实时打字翻译.exe` 是预编译的解释器，会自动运行同目录下的 `.ahk` 文件
- 当新版本发布后，只需替换 `.ahk` 文件

---

### 🟩 方式二：直接使用 AutoHotkey

**适用场景**：
- 了解 AutoHotkey 的用户
- 推荐使用 [AutoHotkey v2+](https://github.com/thqby/AutoHotkey_H/releases)


## 命令模式

本工具支持以 `/` 开头的斜杠命令，用于快速执行特定操作。

### 可用命令

| 命令 | 功能 | 示例 |
|------|------|------|
| `/status` | 显示当前配置状态 | 查看当前使用的模型、目标语言、翻译模式等 |
| `/lang <语言名称>` | 切换目标翻译语言 | `/lang 英语`、`/lang Japanese` |
| `/help` | 显示命令帮助信息 | 查看所有可用命令列表 |

### 使用方法

1. 按 `ALT Y` 打开翻译器
2. 直接输入命令（例如 `/status`）
3. 按 `ENTER` 执行命令
4. 查看命令执行结果

**注意**：
- 命令执行后，输入框会自动清空
- 命令结果显示在翻译结果区域（tooltip 中）
- 命令结果不会被发送，仅用于显示信息
- 输入错误命令时，会提示使用 `/help` 查看帮助

### 命令示例

```bash
# 查看当前配置
/status

# 切换目标语言为日语
/lang 日语

# 查看帮助信息
/help
```

## 快捷键

### 通用快捷键
* `ALT Y`: 打开翻译器
* `ENTER`: 输出翻译文本（第一次翻译，第二次发送）
* `CTRL ENTER`: 输出原始文本
* `CTRL C`: 复制翻译结果
* `CTRL V`: 粘贴剪贴板内容
* `CTRL ALT ENTER`: 转换为Snake命名 (`variable_name`)
* `SHIFT ALT ENTER`: 转换为驼峰命名 (`VariableName`)
* `ESC`: 退出
* `TAB`: 切换翻译模型
* `CTRL F8`: 切换翻译模式（默认/实时）

## 环境要求

| 环境 | 版本 |
|------|------|
| 系统 | Windows 10 或更高版本 |
| 网络连接 | 需要稳定的网络连接访问 LLM API |


## 配置说明

通过配置文件配置 `config.json`

### 基本结构

```json
{
    "translation_mode": "manual",
    "cd": "Model1",
    "target_lang": "English",
    "ui_font": {
        "family": "Segoe UI",
        "tooltip_size": 16,
        "input_size": 25
    },
    "Model1": {
        "display_name": "OpenAI GPT",
        "is_open": 1,
        "api_key": "sk-你的API密钥",
        "base_url": "https://api.openai.com/v1",
        "model": "gpt-4o-mini",
        "debounce_delay": 500,
        "temperature": 0.5,
        "max_tokens": 2000
    }
}
```

**首次运行**：程序会自动从 `config.example.json` 复制创建 `config.json`，无需手动创建。

### 配置项说明

| 配置项 | 说明 | 示例 | 必填 |
|--------|------|------|------|
| `translation_mode` | 翻译模式（全局） | `"manual"` 或 `"realtime"` | ❌（默认 manual） |
| `cd` | 当前使用的模型配置名 | `"Model1"` | ❌（默认第一个启用的） |
| `family` | 字体家族 | `"Segoe UI"` | ❌（默认 Segoe UI） |
| `tooltip_size` | 翻译结果字体大小 | `16` | ❌（默认 16） |
| `input_size` | 输入框字体大小 | `25` | ❌（默认 25） |
| `target_lang` | 目标翻译语言 | `"en"`（英语）, `"ja"`（日语）等 | ❌（默认 English） |
| `display_name` | 模型显示名称（界面显示用） | `"OpenAI GPT"`, `"智谱 AI"` | ❌（默认使用配置名） |
| `is_open` | 是否启用该模型（Tab 切换时会跳过） | `1` 或 `0` | ✅ |
| `api_key` | API 密钥 | 从服务获取 | ✅* |
| `base_url` | API 地址（必须为 OpenAI 兼容格式） | 必须包含 `/v1` | ✅ |
| `model` | 模型名称 | 按服务文档填写 | ✅ |
| `debounce_delay` | 防抖延迟（毫秒） | `500` = 停止 0.5 秒后翻译 | ❌（默认 500） |
| `temperature` | 温度参数，参考供应商文档 | `0.5` = 平衡的设置 | ❌（默认 0.5） |
| `max_tokens` | 最大 token 数 | `2000` | ❌（默认 2000） |

*注：部分本地服务可能不需要 API Key，可填任意值

### 添加新模型（只需 2 步，无需改代码！）

**前提条件**: 该服务必须提供 OpenAI 兼容的 API 接口

**步骤 1**: 添加模型配置块
```json
"Model2": {
    "display_name": "新模型名称",
    "is_open": 1,
    "api_key": "从服务获取的密钥",
    "base_url": "https://api.service-name.com/v1",
    "model": "model-name",
    "debounce_delay": 500,
    "temperature": 0.5, 
    "max_tokens": 2000
}
```

**步骤 2**: 设置为默认模型（可选）
```json
"cd": "Model2"
```

**完成！** 无需修改任何代码，程序会自动识别并加载所有 `is_open: 1` 的模型。

**Tab切换**：按 `TAB` 键会循环切换所有启用的模型（`is_open: 1`），禁用的模型会被跳过。

### 常见模型配置示例

| 服务类型 | base_url 示例 | 获取方式 |
|---------|--------------|----------|
| **OpenAI 官方** | `https://api.openai.com/v1` | https://platform.openai.com |
| **其他 OpenAI 兼容服务** | 按服务商文档填写 | 查看该服务文档的"OpenAI 兼容"说明 |
| **本地部署** | `http://localhost:11434/v1` | 本地安装 Ollama 等 |

**重要提示**：
- 配置前请先确认该服务是否提供 OpenAI 兼容接口
- 具体 base_url 和 model 名称请参考各服务官方文档
- 本项目不对任何第三方服务做兼容性保证

### 切换模型

按 `TAB` 键循环切换配置中已启用的模型。

### 修改目标翻译语言

修改配置文件：
- 在 `config.json` 中修改 `target_lang` 字段
- 支持任意语言名称（LLM 能够理解）
- 重启程序生效

**示例**：
- `"en"` 或 `"English"` - 英语
- `"ja"` 或 `"Japanese"` 或 `"日本語"` - 日语
- `"ko"` 或 `"Korean"` 或 `"한국어"` - 韩语
- `"fr"` 或 `"French"` 或 `"法语"` - 法语

### 编程命名转换（程序员专用）

将翻译结果自动转换为编程语言常用的变量命名格式。

**使用场景**：
- 翻译技术文档时快速提取变量名
- 创建符合规范的类名和函数名
- 跨语言开发时的命名风格转换

**Snake 命名**（`CTRL ALT ENTER`）
- 格式: `variable_name`
- 适用: Python、Ruby、Go 等
- 示例:
  - 输入: "用户名" → 翻译: "user name" → 转换: `user_name`
  - 输入: "订单管理器" → 翻译: "order manager" → 转换: `order_manager`

**驼峰命名**（`SHIFT ALT ENTER`）
- 格式: `VariableName`（大驼峰 / PascalCase）
- 适用: Java、C#、C++ 类名
- 示例:
  - 输入: "用户名" → 翻译: "user name" → 转换: `UserName`
  - 输入: "订单管理器" → 翻译: "order manager" → 转换: `OrderManager`

**转换规则**：
- 自动转为小写
- 空格替换为下划线（snake）或移除（驼峰）
- 移除所有特殊字符，只保留字母、数字和下划线
- 驼峰命名：每个单词首字母大写

### LOL 支持（原版本含有，未知可行性）

在 LOL 游戏内使用翻译功能，方便与国际队友交流。

**前提条件**：
- 需要运行 LOL 游戏客户端
- 需要安装第三方工具（如 LCU API）用于游戏内通信
- zmq 服务器需要在 `localhost:5555` 运行

**使用流程**：
1. 在游戏中按 `XButton1`（鼠标侧键 1）打开翻译器
2. 输入要说的话（中文或其他语言）
3. LLM 实时翻译成目标语言
4. 按鼠标侧键发送到游戏聊天

**发送模式**（按 `CTRL F8` 切换）：
1. **Simulacrum Code 模式**（默认）
   - 使用 Unicode 编码逐字符输入
   - 兼容性更好，适合大多数系统
   - 速度稍慢

2. **直接发送模式**
   - 通过 zmq 直接发送到游戏
   - 需要第三方 LCU 工具支持
   - 速度更快

**快捷键说明**：
- `XButton1`: 打开翻译器输入
- `XButton2`: 发送原始文本（不翻译）
- `ALT XButton2`: 发送所有人聊天 `/all` + 原始文本
- `CTRL XButton2`: 发送所有人聊天 `/all` + 翻译结果
- `SHIFT XButton2`: 发送翻译结果到队伍聊天
- `ALT F8`: 切换发送模式（Simulacrum Code/直接发送）

**注意事项**：
- LOL 功能仅在游戏窗口 `ahk_class RiotWindowClass` 生效
- 需要先配置目标翻译语言（默认为英语）
- 建议使用快速模型（如 `glm-4-flash`）以提高翻译速度

## 切换翻译模式
按 `CTRL F8` 可在**默认模式**和**实时模式**之间切换：

- **默认模式**（默认）：按 `Enter` 触发翻译请求，等待结果返回后再按 `Enter` 发送
  - 更符合 LLM 特性，可避免频繁 API 调用
  - Token 消耗显著低于实时模式
  - 适合大多数使用场景，推荐默认使用

- **实时模式**：输入时自动触发翻译，翻译完成后按 `Enter` 发送
  - 类似传统翻译软件的体验
  - 会产生更多 API 调用，适合需要即时预览的场景
  - 需要确认 API 的供应商是否支持高频次请求

**注意**：具体费用请查看所选 LLM 服务的官方价格表。

## API Key 安全

- API Key 存储在本地配置文件中
- 不会上传到任何服务器
- 建议不要分享你的 config 文件

## 常见问题

### Q: 为什么只支持 OpenAI 兼容 API？
A: OpenAI 格式已成为事实标准，绝大多数 LLM 服务都提供兼容接口。单一格式大大简化了代码和维护成本。

### Q: 我想用的服务不提供 OpenAI 兼容接口怎么办？
A:
1. 使用第三方中转服务转换格式
2. 或等待该服务商提供兼容接口
3. 或等待本项目未来扩展支持更多原生格式

### Q: 响应速度会变慢吗？
A: LLM 响应通常 1-2 秒。已添加防抖机制优化体验，也可选择快速模型或关闭实时翻译。

### Q: 可以离线使用吗？
A: 需要网络连接。可配置本地服务（如 Ollama）实现较低延迟。

## 故障排除

### 问题 1: 翻译失败
**原因**: API Key 错误或网络问题
**解决**:
1. 检查 API Key 是否正确
2. 检查网络连接
3. 检查 base_url 是否正确
4. 按 `CTRL F7` 查看当前配置信息

### 问题 2: 响应速度慢
**原因**: LLM API 响应通常需要 1-2 秒
**解决**:
1. 调整 `debounce_delay` 减少请求频率
2. 选择更快的模型（如 gpt-4o-mini、deepseek-chat、glm-4-flash）
3. 确认使用默认模式（默认）按需触发翻译，避免实时模式的频繁调用



