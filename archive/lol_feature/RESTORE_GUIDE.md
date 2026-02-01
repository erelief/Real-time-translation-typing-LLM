# LOL 功能恢复指南

## 功能概述

LOL 功能提供 League of Legends 游戏内翻译和聊天功能，包括：
1. 通过 LCU API 获取游戏状态和英雄信息
2. 两种发送模式：Simulacrum Code（模拟按键）和 zmq 直连
3. 游戏内快捷键支持（XButton1, XButton2 组合键）

## 归档信息

- **归档日期**: 2025-02-01
- **归档原因**: LOL 功能不再使用，移除以简化代码库
- **原始位置**:
  - `utility/lol_game.ah2`
  - `lib/zmq.ahk`（参考）
  - `实时打字翻译.ahk` 多处集成代码

## 依赖关系

### 外部依赖
- **zmq 库**: `lib/zmq.ahk`（需恢复）
- **zmq 服务器**: 需在 `localhost:5555` 运行（第三方工具）
- **LOL 客户端**: 需要管理员权限运行脚本

### 文件依赖
- `utility/lol_game.ah2` - LCU API 封装类
- `lib/zmq.ahk` - ZeroMQ 库

## 恢复步骤

### 步骤 1：恢复文件

```bash
# 将 lol_game.ah2 移回 utility 目录
mv archive/lol_feature/lol_game.ah2 utility/

# 确认 zmq 库存在
# lib/zmq.ahk 应该已存在
```

### 步骤 2：恢复 include 语句

在 `实时打字翻译.ahk` 文件开头：

**第 3 行**（在 `#include <Direct2DRender>` 之后）：
```ahk
#include <zmq>
```

**第 9 行**（在 `#include <LLM_Translator>` 之后）：
```ahk
#include ./utility/lol_game.ah2
```

### 步骤 3：恢复全局变量

在 `main()` 函数中（约第 739-740 行）：
```ahk
global g_is_input_mode := true
global g_lol_api := Lcu()
```

### 步骤 4：恢复 zmq 初始化

在 `main()` 函数中（约第 772-779 行）：
```ahk
zmq_version(&a := 0, &b := 0, &c := 0)
logger.info("版本: ", a, b, c)
ctx := zmq_ctx_new()
global g_requester := zmq_socket(ctx, ZMQ_REQ)
;设置超时时间 -1无限等待, 0立即返回
buf := Buffer(4), NumPut("int", 1000, buf)
zmq_setsockopt(g_requester, ZMQ_RCVTIMEO, buf, buf.Size)
rtn := zmq_connect(g_requester, "tcp://localhost:5555")
```

### 步骤 5：恢复 LOL 快捷键

在 `main()` 函数中（约第 784-791 行）：
```ahk
HotIfWinExist("ahk_class RiotWindowClass")
    Hotkey('XButton1', (key) => open_translator()) ;打开翻译器
    Hotkey('XButton2', (key) => send_command('Primitive')) ;打开翻译器
    Hotkey('!XButton2', (key) => (g_eb.text := '/all ' g_eb.text, send_command('Primitive'))) ;打开翻译器
    Hotkey('^XButton2', (key) => (g_eb.text := '/all ' g_eb.text, g_eb.translation_result := '/all ' g_eb.translation_result, send_command(''))) ;打开翻译器
    Hotkey('+XButton2', (key) => send_command('')) ;打开翻译器
    Hotkey('!f8', (key) => switch_lol_send_mode())
HotIf()
```

### 步骤 6：恢复 switch_lol_send_mode() 函数

在 `send_command()` 函数之前（约第 879-883 行）：
```ahk
switch_lol_send_mode(p*)
{
    global g_is_input_mode
    g_is_input_mode := !g_is_input_mode
}
```

### 步骤 7：恢复 send_command() 中的 LOL 逻辑

在 `send_command()` 函数中：

1. 在函数开头恢复静态变量（约第 892 行）：
```ahk
static before_txt := g_eb.text
```

2. 在粘贴逻辑之后添加 LOL 检测逻辑（约第 913-936 行）：
```ahk
if(WinActive('ahk_class RiotWindowClass'))
{
    if(g_is_input_mode)
    {
        if(data == '' || data == '/all ')
            SendCn(data before_txt)
        else
        {
            SendCn(data)
            before_txt := data
        }
    }
    else
    {
        if(data == '' || data == '/all ')
            sendcmd2game(data before_txt)
        else
        {
            sendcmd2game(data)
            before_txt := data
        }
    }
}
```

### 步骤 8：恢复 LOL 发送函数

在文件末尾（约第 2372-2403 行）：
```ahk
sendcmd2game(str)
{
    logger.info("sendcn")
    g_lol_api.get_hero_name_and_id(&name, &id)
    ;<font color="#40C1FF">[队伍] 玩家名 (英雄名): </font><font color="#FFFFFF">喊话内容</font>
    if(InStr(str, '/all '))
    {
        str := LTrim(str, '/all ')
        zmq_send_string(g_requester,'<font color="#ff0000">[所有人] ' id  '(' name '): </font><font color="#FFFFFF">' str '</font>')
    }
    else
    {
        zmq_send_string(g_requester,'<font color="#40C1FF">[队伍] ' id  '(' name '): </font><font color="#FFFFFF">' str '</font>')
    }

    rtn := zmq_recv_string(g_requester, &recv_string := '')
    logger.info("sendcn ok")
}

SendCn(str)
{
    SendInput("{Enter}")
    Sleep(200)
    charList:=StrSplit(str)
    for key,val in charList{
        ; 转换每个字符为{U+16进制Unicode编码}
        out.="{U+" . Format("{:X}",ord(val)) . "}"
    }
    SendInput(out)
    Sleep(400)
    SendInput("{Enter}")
}
```

### 步骤 9：更新 README.md

在 README.md 中恢复 LOL 功能说明（参考原第 300-335 行），或参考 `archive/lol_feature/removed_code.ahk`

## 测试验证步骤

### 1. 基础功能测试
1. 启动 LOL 客户端
2. 管理员权限运行 `实时打字翻译.ahk`
3. 进入游戏内
4. 验证无 zmq 连接错误

### 2. 快捷键测试
- `XButton1`: 打开翻译器
- `XButton2`: 发送原始文本
- `!XButton2`: 发送 `/all` 原始文本
- `^XButton2`: 发送 `/all` 翻译结果
- `+XButton2`: 发送翻译结果到队伍
- `!f8`: 切换发送模式

### 3. 发送模式测试
1. 默认模式（Simulacrum Code）：
   - 输入文本并发送
   - 验证游戏内聊天显示

2. 直接发送模式（zmq）：
   - 按 `!f8` 切换模式
   - 输入文本并发送
   - 验证 zmq 通信正常

### 4. LCU API 测试
1. 检查英雄名称获取
2. 验证 HTML 颜色标签显示

## 快捷键说明

| 快捷键 | 功能 | 说明 |
|--------|------|------|
| XButton1 | 打开翻译器 | 仅 LOL 窗口 |
| XButton2 | 发送原始文本 | 不翻译 |
| ALT XButton2 | 发送 /all 原始文本 | 所有人聊天 |
| CTRL XButton2 | 发送 /all 翻译 | 所有人聊天 |
| SHIFT XButton2 | 发送翻译结果 | 队伍聊天 |
| ALT F8 | 切换发送模式 | Simulacrum/zmq |

## 发送模式

### Simulacrum Code 模式（默认）
- 使用 Unicode 编码逐字符输入
- 兼容性更好，适合大多数系统
- 速度稍慢
- 通过 `SendCn()` 函数实现

### 直接发送模式
- 通过 zmq 直接发送到游戏
- 需要第三方 LCU 工具支持
- 速度更快
- 通过 `sendcmd2game()` 函数实现

## 消息格式

- **队伍聊天**: `<font color="#40C1FF">[队伍] ID(英雄名): 消息</font>`
- **所有人聊天**: `<font color="#ff0000">[所有人] ID(英雄名): 消息</font>`

## 常见问题

### Q: zmq 连接失败？
**A**: 确保 zmq 服务器在 `localhost:5555` 运行

### Q: 无法获取英雄信息？
**A**:
1. 确保管理员权限运行脚本
2. 确保 LOL 客户端正在运行
3. 检查 LCU API 端口 2999 是否可访问

### Q: 发送模式不工作？
**A**:
1. 检查 zmq 服务器是否运行
2. 按 `!f8` 切换发送模式
3. 查看日志输出

## AHK v2 语法注意事项

⚠️ **重要**: 本恢复指南中的所有注释都使用分号 `;`，符合 AHK v2 语法规范。

### 禁止的语法
```ahk
; ❌ 错误：不要使用双斜杠注释
; this.move(x, y)  // 这会导致语法错误！

; ✅ 正确：使用分号注释
this.move(x, y)  ; 移动窗口
```

### Map vs Object
```ahk
; ✅ 正确：普通对象使用 HasProp()
if (obj.HasProp("X"))
    value := obj.X

; ✅ 正确：Map 对象使用 Has()
if (map.Has("key"))
    value := map["key"]
```

## 参考文档

- `archive/lol_feature/lol_game.ah2` - LCU API 完整实现
- `archive/lol_feature/removed_code.ahk` - 被移除的代码片段
- `archive/lol_feature/zmq.ahk` - ZeroMQ 库参考
- `.claude/AutoHotkeyDocs-2/` - AHK v2 官方文档

---

**归档维护**: 如需修改归档代码，请同步更新此恢复指南。
