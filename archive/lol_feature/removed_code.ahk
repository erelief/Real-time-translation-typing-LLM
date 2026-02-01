; ========================================
; LOL 功能被移除的代码片段备份
; ========================================
; 归档日期: 2025-02-01
; 原始文件: 实时打字翻译.ahk
; ========================================

; ----- 1. Include 语句（文件开头）-----

; 第 3 行：zmq 库 include
; 在 #include <Direct2DRender> 之后添加：
#include <zmq>

; 第 9 行：LOL 模块 include
; 在 #include <LLM_Translator> 之后添加：
#include ./utility/lol_game.ah2

; ----- 2. 全局变量声明（main 函数中）-----

; 第 739-740 行：LOL 全局变量
; 在 global g_window_hwnd := 0 之后添加：
global g_is_input_mode := true
global g_lol_api := Lcu()

; ----- 3. zmq 初始化（main 函数中）-----

; 第 772-779 行：zmq 初始化
; 在 global MAX_INPUT_WIDTH := 800 之后，g_eb.hide() 之前添加：
zmq_version(&a := 0, &b := 0, &c := 0)
logger.info("版本: ", a, b, c)
ctx := zmq_ctx_new()
global g_requester := zmq_socket(ctx, ZMQ_REQ)
;设置超时时间 -1无限等待, 0立即返回
buf := Buffer(4), NumPut("int", 1000, buf)
zmq_setsockopt(g_requester, ZMQ_RCVTIMEO, buf, buf.Size)
rtn := zmq_connect(g_requester, "tcp://localhost:5555")

; ----- 4. LOL 快捷键注册（main 函数中）-----

; 第 784-791 行：LOL 游戏内快捷键
; 在 g_eb.hide() 和 g_dh.hide() 之后，Hotkey('!y'...) 之前添加：
HotIfWinExist("ahk_class RiotWindowClass")
    Hotkey('XButton1', (key) => open_translator()) ;打开翻译器
    Hotkey('XButton2', (key) => send_command('Primitive')) ;打开翻译器
    Hotkey('!XButton2', (key) => (g_eb.text := '/all ' g_eb.text, send_command('Primitive'))) ;打开翻译器
    Hotkey('^XButton2', (key) => (g_eb.text := '/all ' g_eb.text, g_eb.translation_result := '/all ' g_eb.translation_result, send_command(''))) ;打开翻译器
    Hotkey('+XButton2', (key) => send_command('')) ;打开翻译器
    Hotkey('!f8', (key) => switch_lol_send_mode())
HotIf()

; ----- 5. 辅助函数（paste 函数之后）-----

; 第 879-883 行：切换 LOL 发送模式
; 在 paste() 函数之后，send_command() 函数之前添加：
switch_lol_send_mode(p*)
{
    global g_is_input_mode
    g_is_input_mode := !g_is_input_mode
}

; ----- 6. send_command 函数修改-----

; 第 892 行：添加静态变量
; 在 if (g_is_translating) 之后添加：
static before_txt := g_eb.text

; 第 913-936 行：LOL 检测逻辑
; 在 WinActivate/WinWaitActive 块之后，SendInput 之前添加：
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
else
{
    SendInput('{RShift Down}{Insert}{RShift Up}')
    sleep(200)
}

; ----- 7. LOL 发送函数（文件末尾）-----

; 第 2372-2403 行：zmq 和 Simulacrum Code 发送函数
; 在 EncodeDecodeURI 函数之后添加：
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

; ========================================
; 恢复步骤
; ========================================
;
; 1. 将 archive/lol_feature/lol_game.ah2 移回 utility/
; 2. 按照上述注释中的位置，逐步恢复代码
; 3. 更新 README.md 恢复 LOL 功能说明
; 4. 管理员权限运行脚本测试
;
; 详细恢复指南请参考: RESTORE_GUIDE.md
; ========================================
