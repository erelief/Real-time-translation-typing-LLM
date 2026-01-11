#Requires AutoHotkey v2.0
#include <Direct2DRender>
#include <zmq>
#include <log>
#include <ComVar>
#include <btt>
#include <WinHttpRequest>
#include <LLM_Translator>
#include ./utility/lol_game.ah2

logger.is_log_open := false
logger.is_use_editor := true
logger.level := 4

CoordMode('ToolTip', 'Screen')
CoordMode('Mouse', 'Screen')
OnMessage(WM_CHAR := 0x0102, ON_MESSAGE_WM_CHAR)
OnMessage(WM_IME_CHAR := 0x0286, ON_MESSAGE_WM_IME_CHAR)

OnMessage(0x0100, ON_WM_KEYDOWN)  ; 0x0100 是 WM_KEYDOWN

; 鼠标消息监听（用于拖拽）
OnMessage(0x0201, ON_WM_LBUTTONDOWN)   ; WM_LBUTTONDOWN
OnMessage(0x0231, ON_WM_ENTERSIZEMOVE) ; WM_ENTERSIZEMOVE
OnMessage(0x0232, ON_WM_EXITSIZEMOVE)  ; WM_EXITSIZEMOVE

; 获取当前服务的显示名称（优先使用 display_name，否则使用配置名）
get_current_service_display_name()
{
    global g_config, g_current_api
    api_config := g_config[g_current_api]
    return api_config.Has("display_name") ? api_config["display_name"] : g_current_api
}

; ESC 退出翻译器（等待按键释放，避免按键传递给其他窗口）
close_translator(*)
{
    global g_eb, g_dh
    g_eb.hide()
    g_dh.hide()
    KeyWait("Esc")  ; 等待 ESC 释放，阻止按键传递
}

; 检查焦点并自动退出（由定时器调用）
check_focus_and_close()
{
    global g_eb, g_dh, g_focus_check_timer

    ; 如果翻译器已隐藏，停止检查
    if (!g_eb.show_status)
    {
        if (g_focus_check_timer)
            SetTimer(g_focus_check_timer, 0)
        g_focus_check_timer := 0
        return
    }

    ; 检查是否正在拖拽
    if (g_dh.is_dragging)
        return  ; 拖拽时不检查焦点

    ; 检查输入框是否是激活窗口
    input_hwnd := g_eb.ui.gui.Hwnd
    active_hwnd := WinGetID("A")

    ; 如果输入框不激活，说明用户点击了其他地方 → 自动退出
    if (active_hwnd != input_hwnd)
    {
        logger.info(">>> 输入框失去焦点，自动退出")
        g_eb.hide()
        g_dh.hide()
    }
}

; ========== 光标闪烁定时器 ==========
toggle_cursor_blink()
{
    global g_cursor_visible, g_eb, g_cursor_blink_timer

    ; 如果输入框已隐藏，停止闪烁
    if (!g_eb.show_status)
    {
        if (g_cursor_blink_timer)
            SetTimer(g_cursor_blink_timer, 0)
        g_cursor_blink_timer := 0
        return
    }

    ; 切换光标可见状态
    g_cursor_visible := !g_cursor_visible

    ; 重绘输入框以显示/隐藏光标（不触发翻译）
    g_eb.draw(0, false)
}

main()
main()
{
    btt('加载中。。。',0, 0,,OwnzztooltipStyle1,{Transparent:180,DistanceBetweenMouseXAndToolTip:-100,DistanceBetweenMouseYAndToolTip:-20})

    ; 自动检测并创建配置文件
    config_path := A_ScriptDir "\config.json"
    example_config_path := A_ScriptDir "\config.example.json"
    if !FileExist(config_path)
    {
        if FileExist(example_config_path)
        {
            FileCopy(example_config_path, config_path, 1)
            btt('已自动创建配置文件：' config_path '`n请编辑填入你的API密钥',0, 0,5000,OwnzztooltipStyle1,{Transparent:180,DistanceBetweenMouseXAndToolTip:-100,DistanceBetweenMouseYAndToolTip:-20})
            Sleep(1000)
        }
        else
        {
            MsgBox('错误：找不到配置文件模板 ' example_config_path)
            ExitApp
        }
    }

    ; 加载配置
    global g_config := Map()
    loadconfig(&g_config, config_path)

    ; 初始化API列表
    global g_all_api := g_config["all_api"]
    global g_current_api := g_config["cd"]
    global g_target_lang := g_config.Has("target_lang") ? g_config["target_lang"] : "en"
    global g_translators := Map()  ; 存储所有LLM实例

    ; 初始化所有启用的LLM翻译器
    for api_name in g_all_api
    {
        api_config := g_config[api_name]
        if (api_config["is_open"] && api_config["api_key"])
        {
            ; 所有平台使用同一个类，只是配置不同！
            g_translators[api_name] := OpenAI_Compat_LLM(
                api_name,
                api_config,
                ObjBindMethod(Edit_box, "on_change_stub")
            )
        }
    }

    global g_eb := Edit_box(0, 0, 1000, 100)
    global g_dh := DragHandle()  ; 拖拽手柄
    global g_is_ime_char := false
    global g_cursor_x := 0
    global g_cursor_y := 0
    global g_window_hwnd := 0
    global g_is_input_mode := true
    global g_lol_api := Lcu()

    ; 位置记忆相关变量（会话级，按进程名）
    global g_manual_positions := Map()

    ; 保存最后一次翻译结果（用于拖拽时显示）
    global g_last_translation := ""

    ; 翻译状态标志（用于防止翻译未完成时发送）
    global g_is_translating := false

    ; 焦点检查定时器（用于检测点击其他地方自动退出）
    global g_focus_check_timer := 0

    ; 光标闪烁相关变量
    global g_cursor_visible := true  ; 光标可见状态
    global g_cursor_blink_timer := 0  ; 光标闪烁定时器

    zmq_version(&a := 0, &b := 0, &c := 0)
    logger.info("版本: ", a, b, c)
    ctx := zmq_ctx_new()
    global g_requester := zmq_socket(ctx, ZMQ_REQ)
    ;设置超时时间 -1无限等待, 0立即返回
    buf := Buffer(4), NumPut("int", 1000, buf)
    zmq_setsockopt(g_requester, ZMQ_RCVTIMEO, buf, buf.Size)
    rtn := zmq_connect(g_requester, "tcp://localhost:5555")

    g_eb.hide()
    g_dh.hide()

	HotIfWinExist("ahk_class RiotWindowClass")
        Hotkey('XButton1', (key) => fanyi()) ;打开翻译器
        Hotkey('XButton2', (key) => send_command('Primitive')) ;打开翻译器
        Hotkey('!XButton2', (key) => (g_eb.text := '/all ' g_eb.text, send_command('Primitive'))) ;打开翻译器
        Hotkey('^XButton2', (key) => (g_eb.text := '/all ' g_eb.text, g_eb.fanyi_result := '/all ' g_eb.fanyi_result, send_command(''))) ;打开翻译器
        Hotkey('+XButton2', (key) => send_command('')) ;打开翻译器
        Hotkey('^f8', (key) => switch_lol_send_mode())
    HotIf()
    Hotkey('!y', (key) => fanyi()) ;打开翻译器
    Hotkey('^!y', (key) => fanyi_clipboard()) ;翻译粘贴板文本
    Hotkey('^f7', (key) => g_eb.debug()) ;调试
    Hotkey('!l', (key) => change_target_language()) ;切换目标语言
    Hotkey('~Esc', close_translator) ;退出
	HotIfWinExist("ahk_id " g_eb.ui.hwnd)
        Hotkey("enter", (key) => send_command('translate')) ;发送文本
        Hotkey("^enter", (key) => send_command('Primitive')) ;发送原始文本
        Hotkey("~tab", tab_send) ;切换API
        Hotkey("^v", paste) ;粘贴
        Hotkey("^c", copy) ;复制
        Hotkey("+!enter", (key) => serpentine_naming('hump')) ;驼峰命名
        Hotkey("^!enter", (key) => serpentine_naming('snake')) ;snake命名
    HotIf()

    help_text := '
    (
        欢迎使用实时打字翻译工具
        ALT Y : 打开翻译器
        ALT L : 修改目标语言
        ENTER : 发送结果
        CTRL ENTER : 发送原始文本
        CTRL F7 : 展示当前API配置
        TAB : 切换API服务
        ESC : 退出
    )'
    btt(help_text,0, 0,,OwnzztooltipStyle1,{Transparent:180,DistanceBetweenMouseXAndToolTip:-100,DistanceBetweenMouseYAndToolTip:-20})
}

fanyi_clipboard(*)
{
    fanyi()
    g_eb.text := A_Clipboard
    g_eb.draw()
}

change_target_language(*)
{
    global g_target_lang, g_config

    ; 获取鼠标位置用于显示tooltip
    MouseGetPos(&x, &y)

    ; 显示当前语言提示
    btt('当前目标语言: ' g_target_lang '`n请输入新的目标语言', x, y,,OwnzztooltipStyle1,{Transparent:180,DistanceBetweenMouseXAndToolTip:-100,DistanceBetweenMouseYAndToolTip:-20})

    ; 弹出输入框让用户输入新语言
    ib := InputBox('当前目标语言: ' g_target_lang, '设置目标语言', , 'English')

    if (ib.Result == "OK")
    {
        new_lang := ib.Value
        if (new_lang != "")
        {
            g_target_lang := new_lang
            g_config["target_lang"] := new_lang

            ; 保存到配置文件
            saveconfig(g_config, A_ScriptDir "\config.json")

            ; 显示确认提示
            btt('已切换到: ' g_target_lang, x, y,,OwnzztooltipStyle1,{Transparent:180,DistanceBetweenMouseXAndToolTip:-100,DistanceBetweenMouseYAndToolTip:-20})
            logger.info('目标语言已切换到: ' g_target_lang)
        }
    }
}


serpentine_naming(key := 'snake')
{
    global g_window_hwnd
    old := A_Clipboard
    cd_str := g_eb.fanyi_result
    g_eb.hide()
    cd_str := StrLower(cd_str)
    cd_str := RegExReplace(cd_str, 'i)\s+', '_')
    cd_str := RegExReplace(cd_str, "[^A-Za-z0-9_]", "")
    cd_str := Trim(cd_str, '_')

    if(key == 'hump')
    {
        ar := StrSplit(cd_str, '_')
        cd_str := ''
        for k,v in ar
            cd_str .= StrTitle(v)
    }

    A_Clipboard := cd_str
    if(g_window_hwnd)
    {
        try
        {
            WinActivate(g_window_hwnd)
            WinWaitActive(g_window_hwnd,, 1)
        }
    }
    SendInput('{RShift Down}{Insert}{RShift Up}')
    Sleep(200)
}

copy(*)
{
    A_Clipboard := g_eb.fanyi_result
}

paste(*)
{
    g_eb.text := A_Clipboard
    g_eb.draw()
}

switch_lol_send_mode(p*)
{
    global g_is_input_mode
    g_is_input_mode := !g_is_input_mode
}

send_command(p*)
{
    global g_window_hwnd, g_dh, g_is_translating

    ; 如果正在翻译中，直接返回（不发送）
    if (g_is_translating)
        return
    static before_txt := g_eb.text
    try
    {
        data := g_eb.text
        g_eb.hide()
        g_dh.hide()  ; 隐藏拖拽框
        old := A_Clipboard
        if(p[1] == 'Primitive')
            A_Clipboard := data
        else
            A_Clipboard := g_eb.fanyi_result, data := g_eb.fanyi_result
        if(g_window_hwnd)
        {
            try
            {
                WinActivate(g_window_hwnd)
                WinWaitActive(g_window_hwnd,, 1)
            }
        }

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
        A_Clipboard := old
    }
    catch as e
    {
        logger.err(e.Message)
    }
}

tab_send(*)
{
    global g_current_api
    global g_all_api
    ;找到当前index
    current_index := 1
    for k,v in g_all_api
    {
        if(v = g_current_api)
        {
            current_index := k
            break
        }
    }
    current_index++
    if(current_index > g_all_api.Length)
        current_index := 1
    g_current_api := g_all_api[current_index]
    display_name := get_current_service_display_name()
    logger.info('=========' display_name)
    btt('[' display_name ']', Integer(g_cursor_x), Integer(g_cursor_y) - 45,,OwnzztooltipStyle1,{Transparent:180,DistanceBetweenMouseXAndToolTip:-100,DistanceBetweenMouseYAndToolTip:-20})
    g_eb.draw('tab')
}

fanyi(*)
{
    global g_cursor_x, g_cursor_y
    global g_window_hwnd, g_eb, g_dh
    global g_manual_positions, g_last_translation, g_is_translating

    ; 清除上一次的翻译结果和状态
    g_last_translation := ""
    g_is_translating := false

    ; 尝试获取光标位置
    if(!(g_window_hwnd := GetCaretPosEx(&x, &y, &w, &h)))
    {
        g_window_hwnd := WinExist("A")
        MouseGetPos(&x, &y)
    }

    ; 获取进程名，用于位置记忆
    process_name := WinGetProcessName("ahk_id " g_window_hwnd)

    ; 检查当前会话是否有该进程的记忆位置
    if (g_manual_positions.Has(process_name))
    {
        pos := g_manual_positions[process_name]
        x := pos.x
        y := pos.y
        logger.info("使用记忆位置: " process_name, x, y)
    }
    else
    {
        logger.info("使用默认光标位置: " process_name, x, y)
    }

    g_cursor_x := x
    g_cursor_y := y

    ; 计算布局位置
    ; 手柄宽度30px，tooltip在y-45高度
    ; 新布局：手柄和tooltip在同一行（y-45），输入框在tooltip下方（y）
    handle_width := 30  ; 手柄宽度
    tooltip_y := y - 45

    ; 显示 Tooltip（在手柄右侧，同一行）并获取实际高度
    display_name := get_current_service_display_name()
    tooltip_info := btt('[' display_name ']', Integer(x + handle_width), Integer(tooltip_y),,OwnzztooltipStyle1,{Transparent:180,DistanceBetweenMouseXAndToolTip:-100,DistanceBetweenMouseYAndToolTip:-20})

    ; 获取tooltip的实际高度
    tooltip_height := tooltip_info.H

    ; 显示拖拽手柄（高度自适应tooltip）
    g_dh.show_with_height(x, tooltip_y, handle_width, tooltip_height)

    ; 显示输入框（在tooltip下方，左对齐tooltip）
    g_eb.show(x + handle_width, y)
}
ON_WM_KEYDOWN(a*)
{
    if(a[1] == 37)
        g_eb.left()
    else if(a[1] == 39)
        g_eb.right()
}

; ========== 鼠标拖拽相关函数 ==========

; 拖拽定时器回调：持续更新输入框和 Tooltip 位置
DragUpdateTimer()
{
    global g_dh, g_eb, g_last_translation

    if (!g_dh.is_dragging)
        return

    ; 获取手柄当前位置
    local x, y
    g_dh.ui.gui.GetPos(&x, &y)

    ; 手柄宽度
    handle_width := 30

    ; 移动输入框（在tooltip下方，左对齐tooltip）
    ; 手柄在y，tooltip也在y（同一行），输入框在y+45（tooltip下方）
    g_eb.move(x + handle_width, y + 45)

    ; 更新 Tooltip 位置和内容（在手柄右侧，同一行）
    display_name := get_current_service_display_name()
    if (g_last_translation != "")
    {
        btt('[' display_name ']: ' g_last_translation, Integer(x + handle_width), Integer(y),,OwnzztooltipStyle1,{Transparent:180,DistanceBetweenMouseXAndToolTip:-100,DistanceBetweenMouseYAndToolTip:-20})
    }
    else
    {
        btt('[' display_name ']', Integer(x + handle_width), Integer(y),,OwnzztooltipStyle1,{Transparent:180,DistanceBetweenMouseXAndToolTip:-100,DistanceBetweenMouseYAndToolTip:-20})
    }
}

; 鼠标左键按下：开始拖拽手柄
ON_WM_LBUTTONDOWN(wParam, lParam, msg, hwnd)
{
    global g_dh

    ; 只处理手柄窗口的消息
    if (hwnd != g_dh.ui.Hwnd)
        return

    ; 标记正在拖拽
    g_dh.is_dragging := true

    ; 使用 PostMessage 0xA1 让 Windows 系统处理拖拽（像拖动桌面图标一样）
    PostMessage(0xA1, 2, 0, , "ahk_id " hwnd)

    logger.info(">>> 开始拖拽")
    return 0  ; 拦截消息
}

; 进入拖拽模式：启动定时器更新输入框位置
ON_WM_ENTERSIZEMOVE(wParam, lParam, msg, hwnd)
{
    global g_dh, g_cursor_blink_timer, g_cursor_visible, g_eb

    ; 只处理手柄窗口的消息
    if (hwnd != g_dh.ui.Hwnd)
        return

    logger.info(">>> 进入拖拽模式，启动定时器")

    ; 停止光标闪烁并隐藏光标
    if (g_cursor_blink_timer)
        SetTimer(g_cursor_blink_timer, 0)
    g_cursor_visible := false

    ; 立即重绘以隐藏光标（使用简化绘制）
    g_eb.draw_fast()

    ; 每 16ms 更新一次（约 60fps）
    SetTimer(DragUpdateTimer, 16)
}

; 退出拖拽模式：停止定时器并保存位置
ON_WM_EXITSIZEMOVE(wParam, lParam, msg, hwnd)
{
    global g_dh, g_eb, g_window_hwnd, g_cursor_x, g_cursor_y
    global g_manual_positions, g_cursor_blink_timer, g_cursor_visible

    ; 只处理手柄窗口的消息
    if (hwnd != g_dh.ui.Hwnd)
        return

    ; 停止定时器
    SetTimer(DragUpdateTimer, 0)

    ; 标记拖拽结束
    g_dh.is_dragging := false

    ; 恢复光标闪烁
    g_cursor_visible := true
    g_cursor_blink_timer := SetTimer(toggle_cursor_blink, 530)

    ; 保存位置
    local x, y
    g_dh.ui.gui.GetPos(&x, &y)
    process_name := WinGetProcessName("ahk_id " g_window_hwnd)
    g_manual_positions[process_name] := {x: x, y: y}

    ; 更新全局坐标
    g_cursor_x := x
    g_cursor_y := y

    ; 激活翻译输入框，确保拖动后焦点回到输入框
    WinActivate("ahk_id " g_eb.ui.gui.Hwnd)

    logger.info(">>> 拖拽结束，保存位置:", process_name, x, y)
}

ON_MESSAGE_WM_CHAR(a*)
{
    logger.info(a*)
    logger.info(num2utf16(a[1]))
    if(a[2] != 1)
        g_eb.set_imm(a[1])
}
ON_MESSAGE_WM_IME_CHAR(a*)
{
    global g_is_ime_char
    g_is_ime_char := true
    logger.info(a*)
    logger.info(num2utf16(a[1]))
    g_eb.set_imm(a[1])
}

; ========== 拖拽手柄类 ==========
class DragHandle
{
    __New()
    {
        ; 使用 Direct2DRender 创建窗口（与输入框一致）
        ; 调整高度为34px以匹配tooltip高度（FontSize:16 + Margin:8×2 + Border:1×2 = 34）
        this.ui := Direct2DRender(0, 0, 30, 34,,, false)  ; 30x34，clickThrough=false
        this.x := 0
        this.y := 0
        this.show_status := false

        ; 拖拽状态
        this.is_dragging := false
    }

    show(x, y)
    {
        this.x := x
        this.y := y
        this.ui.gui.show('x' x ' y' y)
        this.show_status := true
        this.draw()
    }

    ; 使用指定高度显示手柄（用于匹配tooltip实际高度）
    show_with_height(x, y, width, height)
    {
        ; 重新创建Direct2D窗口以适应新的高度
        this.ui := Direct2DRender(0, 0, width, height,,, false)
        this.x := x
        this.y := y
        this.ui.gui.show('x' x ' y' y)
        this.show_status := true
        this.draw()
    }

    hide()
    {
        this.ui.gui.hide()
        this.show_status := false
        this.is_dragging := false  ; 重置拖拽状态
    }

    move(x, y)
    {
        this.x := x
        this.y := y
        this.ui.SetPosition(x, y)
    }

    get_pos()
    {
        return {x: this.x, y: this.y}
    }

    draw()
    {
        ui := this.ui
        if(ui.BeginDraw())
        {
            ; 获取窗口实际尺寸
            width := this.ui.width
            height := this.ui.height

            ; 绘制半透明背景（使用实际尺寸）
            ui.FillRoundedRectangle(0, 0, width, height, 4, 4, 0xcc2A2A2A)
            ui.DrawRoundedRectangle(0, 0, width, height, 4, 4, 0xFF40C1FF, 1)

            ; 绘制 ≡ 符号（居中，使用实际字体大小24）
            ui.DrawText('≡', 3, 4, 24, 0xFF40C1FF)

            ui.EndDraw()
        }
    }
}

class Edit_box
{
    __New(x, y, w, h)
    {
        this.x := 0
        this.y := 0
        this.w := w
        this.h := h
        this.ui := Direct2DRender(x, y, w, h,,, true)  ; 保持原来的 clickThrough=true，避免白框
        this.text := ''
        this.fanyi_result := ''
        this.insert_pos := 0 ;距离txt最后边的距离

        ; 防抖机制相关
        this.debounce_timer := 0
        this.debounce_delay := 500  ; 停止输入500ms后触发翻译

        this.show_status := false

        ; 重入保护：防止同时调用 draw() 导致 Direct2D 状态冲突
        this.is_drawing := false
    }

    ; 静态回调方法
    static on_change_stub(name, text)
    {
        global g_eb
        if g_eb
            g_eb.on_change(name, text)
    }
    debug()
    {
        ; 显示当前LLM配置信息
        global g_config, g_current_api, g_target_lang
        try
        {
            api_info := g_config[g_current_api]
            MsgBox(
                "当前服务: " g_current_api "`n"
                "模型: " api_info["model"] "`n"
                "API地址: " api_info["base_url"] "`n"
                "目标语言: " g_target_lang "`n"
                "实时翻译: " (api_info["is_real_time_translate"] ? "启用" : "禁用") "`n`n"
                "按 ALT L 可修改目标语言"
            )
        }
        catch as e
        {
            logger.err(e.Message)
        }
    }
    on_change(cd ,text)
    {
        global g_is_translating, g_dh

        ; 翻译完成（成功或失败），清除翻译状态
        g_is_translating := false

        logger.info(cd ,text)
        logger.info()
        if(this.show_status && cd = g_current_api)
        {
            this.fanyi_result := text
            global g_last_translation

            ; 获取手柄位置（tooltip在手柄右侧，同一行）
            g_dh.ui.gui.GetPos(&x, &y)
            handle_width := 30
            display_name := get_current_service_display_name()

            ; 如果翻译结果为空，只显示服务名
            if (text = "")
            {
                g_last_translation := ""
                btt('[' display_name ']', Integer(x + handle_width), Integer(y),,OwnzztooltipStyle1,{Transparent:180,DistanceBetweenMouseXAndToolTip:-100,DistanceBetweenMouseYAndToolTip:-20})
            }
            else
            {
                g_last_translation := text  ; 保存翻译结果
                btt('[' display_name ']: ' text, Integer(x + handle_width), Integer(y),,OwnzztooltipStyle1,{Transparent:180,DistanceBetweenMouseXAndToolTip:-100,DistanceBetweenMouseYAndToolTip:-20})
            }
        }
    }
    show(x := 0, y := 0)
    {
        global g_focus_check_timer, g_cursor_blink_timer, g_cursor_visible
        this.ui.gui.show('x' x ' y' y)
        this.show_status := true

        ; 重置光标状态并启动闪烁
        g_cursor_visible := true
        g_cursor_blink_timer := SetTimer(toggle_cursor_blink, 530)

        this.draw()  ; 立即绘制，避免白框

        ; 启动焦点检查定时器（每200ms检查一次）
        g_focus_check_timer := SetTimer(check_focus_and_close, 200)
    }
    hide()
    {
        global g_is_ime_char, g_is_translating, g_focus_check_timer, g_cursor_blink_timer
        this.clear()
        this.ui.gui.hide()
        g_is_ime_char := false
        this.show_status := false
        g_is_translating := false  ; 关闭翻译器时重置翻译状态
        OwnzztooltipEnd()

        ; 停止焦点检查定时器
        if (g_focus_check_timer)
            SetTimer(g_focus_check_timer, 0)
        g_focus_check_timer := 0

        ; 停止光标闪烁定时器
        if (g_cursor_blink_timer)
            SetTimer(g_cursor_blink_timer, 0)
        g_cursor_blink_timer := 0
    }
    move(x, y, w := 0, h := 0)
    {
        this.ui.SetPosition(x, y, w, h)
    }

    ; 快速绘制：只绘制文本，不绘制光标，不执行复杂操作（用于拖拽时）
    draw_fast()
    {
        ; 重入保护
        if (this.is_drawing)
            return

        ui := this.ui
        this.is_drawing := true

        try
        {
            ; 计算文本宽度
            wh := this.ui.GetTextWidthHeight(this.text, 30)

            if(ui.BeginDraw())
            {
                ui.FillRoundedRectangle(0, 0, wh.width, wh.height, 5, 5, 0xcc1E1E1E)
                ui.DrawRoundedRectangle(0, 0, wh.width, wh.height, 5, 5, 0xffff0000, 1)

                ; 只绘制文本，不绘制光标
                draw_x := 0
                for char_index, char in StrSplit(this.text, "")
                {
                    if (char == " ")
                    {
                        space_wh := this.ui.GetTextWidthHeight("␣", 30)
                        ui.DrawText("␣", draw_x, 0, 30, 0x80FFFFFF)
                        draw_x += space_wh.width
                    }
                    else
                    {
                        char_wh := this.ui.GetTextWidthHeight(char, 30)
                        ui.DrawText(char, draw_x, 0, 30, 0xFFC9E47E)
                        draw_x += char_wh.width
                    }
                }
                ui.EndDraw()
            }
        }
        finally
        {
            this.is_drawing := false
        }
    }

    draw(flag := 0, trigger_translation := true)
    {
        ; 重入保护：如果正在绘制，直接返回避免 Direct2D 状态冲突
        if (this.is_drawing)
            return

        global g_current_api, g_translators, g_config, g_last_translation, g_dh, g_cursor_visible
        ui := this.ui
        ui.gui.GetPos(&x, &y, &w, &h)
        logger.info(x, y, w, h)

        ; 标记开始绘制
        this.is_drawing := true

        try
        {
            ; 拖拽时简化绘制，不执行复杂操作
            if (g_dh.is_dragging)
        {
            ; 只绘制内容，不执行翻译和 tooltip 更新
            wh := this.ui.GetTextWidthHeight(this.text, 30)
            if(ui.BeginDraw())
            {
                ui.FillRoundedRectangle(0, 0, wh.width, wh.height, 5, 5, 0xcc1E1E1E)
                ui.DrawRoundedRectangle(0, 0, wh.width, wh.height, 5, 5, 0xffff0000, 1)

                ; 分段绘制字符（不绘制光标）
                draw_x := 0
                for char_index, char in StrSplit(this.text, "")
                {
                    if (char == " ")
                    {
                        space_wh := this.ui.GetTextWidthHeight("␣", 30)
                        ui.DrawText("␣", draw_x, 0, 30, 0x80FFFFFF)
                        draw_x += space_wh.width
                    }
                    else
                    {
                        char_wh := this.ui.GetTextWidthHeight(char, 30)
                        ui.DrawText(char, draw_x, 0, 30, 0xFFC9E47E)
                        draw_x += char_wh.width
                    }
                }
                ui.EndDraw()
            }
            return  ; 拖拽时直接返回，不执行后续的翻译等复杂操作
        }

        ;计算文字的大小
        wh := this.ui.GetTextWidthHeight(this.text, 30)
        last_txt_wh := this.ui.GetTextWidthHeight(SubStr(this.text, -this.insert_pos), 30)
        logger.info(wh)
        this.move(x, y, wh.width + 100, wh.height + 100)

        ; 只在输入为空时显示服务名 Tooltip（避免频繁更新）
        if (this.text = "")
        {
            g_last_translation := ""
            ; 获取手柄位置（tooltip在手柄右侧，同一行）
            g_dh.ui.gui.GetPos(&handle_x, &handle_y)
            handle_width := 30
            display_name := get_current_service_display_name()
            btt('[' display_name ']', Integer(handle_x + handle_width), Integer(handle_y),,OwnzztooltipStyle1,{Transparent:180,DistanceBetweenMouseXAndToolTip:-100,DistanceBetweenMouseYAndToolTip:-20})
        }
        if(ui.BeginDraw())
        {
            ui.FillRoundedRectangle(0, 0, wh.width, wh.height, 5, 5, 0xcc1E1E1E)
            ui.DrawRoundedRectangle(0, 0, wh.width, wh.height, 5, 5, 0xffff0000, 1)

            ; 分段绘制：空格显示为淡色 ␣，其他字符正常颜色
            draw_x := 0
            for char_index, char in StrSplit(this.text, "")
            {
                if (char == " ")
                {
                    ; 空格显示为淡色 ␣ (50% 透明度)
                    space_wh := this.ui.GetTextWidthHeight("␣", 30)
                    ui.DrawText("␣", draw_x, 0, 30, 0x80FFFFFF)
                    draw_x += space_wh.width
                }
                else
                {
                    ; 正常字符
                    char_wh := this.ui.GetTextWidthHeight(char, 30)
                    ui.DrawText(char, draw_x, 0, 30, 0xFFC9E47E)
                    draw_x += char_wh.width
                }
            }

            ; 绘制光标（只在有焦点且可见状态时显示）
            if (g_cursor_visible)
            {
                ; 计算末尾 insert_pos 个字符的实际绘制宽度（考虑空格替换为 ␣）
                tail_width := 0
                if (this.insert_pos > 0 && this.text != "")
                {
                    ; 从末尾取 insert_pos 个字符
                    ; insert_pos=0: 光标在最右，tail_text="" (不进入此分支)
                    ; insert_pos=1: 光标在最后1字符前，tail_text=最后1个字符
                    ; insert_pos=2: 光标在最后2字符前，tail_text=最后2个字符
                    tail_text := SubStr(this.text, -this.insert_pos)
                    ; 计算这些字符的实际绘制宽度
                    for char_index, char in StrSplit(tail_text, "")
                    {
                        if (char == " ")
                            tail_width += this.ui.GetTextWidthHeight("␣", 30).width
                        else
                            tail_width += this.ui.GetTextWidthHeight(char, 30).width
                    }
                }

                ; 光标位置：实际绘制总宽度 - 末尾字符的实际宽度
                cursor_x := draw_x - tail_width
                ; 绘制闪烁的竖线光标（2px宽，白色）
                ui.DrawLine(cursor_x, 2, cursor_x, wh.height - 2, 0xFFFFFFFF, 2)
            }

            logger.err(this.text)
            ui.EndDraw()
        }

        ; 使用LLM翻译（只有当 trigger_translation 为 true 时才触发）
        if (!trigger_translation)
            return  ; 光标闪烁等场景不需要触发翻译

        input_text := this.text
        api_config := g_config[g_current_api]

        ; 检查是否启用实时翻译
        if (api_config["is_real_time_translate"] && input_text != "")
        {
            ; 防抖处理：取消之前的定时器，重新计时
            if (this.debounce_timer)
                SetTimer(this.debounce_timer, 0)

            this.debounce_timer := SetTimer(() => this.trigger_translate(), -this.debounce_delay)
        }
        }
        finally
        {
            ; 清除绘制标志，允许下次绘制
            this.is_drawing := false
        }
    }

    ; 触发翻译
    trigger_translate()
    {
        global g_translators, g_current_api, g_target_lang, g_is_translating
        input_text := this.text
        if (input_text != "" && g_translators.Has(g_current_api))
        {
            ; 标记正在翻译
            g_is_translating := true

            ; 设置回调为当前实例
            g_translators[g_current_api].set_callback(this.on_change.bind(this))
            g_translators[g_current_api].translate(input_text, g_target_lang)
        }
    }
    clear()
    {
        this.text := ''
        this.insert_pos := 0
    }
    push(char)
    {
        logger.info(char)
        logger.err(this.text)
        left_txt := SubStr(this.text, 1, StrLen(this.text) - this.insert_pos)
        right_txt := SubStr(this.text, -this.insert_pos)
        logger.err(left_txt, right_txt)
        if(char == '`b')
        {
            this.text := SubStr(left_txt, 1, -1) right_txt
        }
        else
        {
            this.text := left_txt char right_txt
        }
        logger.err(this.text, this.insert_pos)
    }
    set_text(text)
    {
        this.text := text
    }
    left()
    {
        if(this.insert_pos < StrLen(this.text))
            this.insert_pos += 1
        this.draw(0, false)  ; 只重绘光标位置，不触发翻译
    }
    right()
    {
        if(this.insert_pos > 0)
            this.insert_pos -= 1
        this.draw(0, false)  ; 只重绘光标位置，不触发翻译
    }
    set_imm(char)
    {
        himc := ImmGetContext(this.ui.Hwnd)
        composition_form := COMPOSITIONFORM()
        composition_form.ptCurrentPos.x := 0
        composition_form.ptCurrentPos.y := 10
        composition_form.rcArea.left :=  0
        composition_form.rcArea.top :=  0
        composition_form.rcArea.right :=  100
        composition_form.rcArea.bottom := 100
        composition_form.dwStyle := 0x0020 ;CFS_FORCE_POSITION
        rtn := ImmSetCompositionWindow(himc, composition_form)

        candidate_form := CANDIDATEFORM()
        candidate_form.dwStyle := 0x0040 ;CFS_CANDIDATEPOS 
        candidate_form.ptCurrentPos.x := 0
        candidate_form.ptCurrentPos.y := 20

        rtn := ImmSetCandidateWindow(himc, candidate_form)
        ImmReleaseContext(this.ui.Hwnd, himc)
        logger.info(num2utf16(char))
        this.push(num2utf16(char))
        this.draw()
    }
}

class RECT extends ctypes.struct
{
	static fields := [['int', 'left'], ['int', 'top'], ['int', 'right'], ['int', 'bottom']]
}

class POINT extends ctypes.struct
{
    static  fields := [['int', 'x'], ['int', 'y']]
}

class COMPOSITIONFORM extends ctypes.struct
{
    static  fields := [['uint', 'dwStyle'], ['POINT', 'ptCurrentPos'], ['RECT', 'rcArea']]
}

class CANDIDATEFORM extends ctypes.struct
{
    static  fields := [['uint', 'dwIndex'], ['uint', 'dwStyle'], ['POINT', 'ptCurrentPos'], ['RECT', 'rcArea']]
}

ImmGetContext(hwnd)
{
    return DllCall('imm32\ImmGetContext', 'int', hwnd, 'int')
}
ImmSetCompositionWindow(HIMC, lpCompForm) ;COMPOSITIONFORM
{
    return DllCall('imm32\ImmSetCompositionWindow', 'int', HIMC, 'ptr', lpCompForm, 'int')
}
ImmSetCandidateWindow(HIMC, lpCandidate) ;CANDIDATEFORM
{
    return DllCall('imm32\ImmSetCandidateWindow', 'int', HIMC, 'ptr', lpCandidate, 'int')
}
ImmReleaseContext(hwnd, HIMC)
{
    return DllCall('imm32\ImmReleaseContext', 'int', hwnd, 'int', HIMC, 'int')
}
ImmSetOpenStatus(HIMC, status) ; HIMC, bool 
{
    return DllCall('imm32\ImmSetOpenStatus', 'int', HIMC, 'int', status, 'int')
}
ImmGetOpenStatus(HIMC)
{
    return DllCall('imm32\ImmGetOpenStatus', 'int', HIMC, 'int')
}
ImmAssociateContext(hwnd, HIMC)
{
    return DllCall('imm32\ImmAssociateContext', 'int', hwnd, 'int', HIMC, "int")
}

num2utf16(code)
{
    bf := Buffer(2, 0)
    NumPut('short', code, bf)
    return StrGet(bf, 1, 'UTF-16')
}

GetCaretPosEx(&x?, &y?, &w?, &h?) 
{
    x := h := w := h := 0
    static iUIAutomation := 0, hOleacc := 0, IID_IAccessible, guiThreadInfo, _ := init()
    if !iUIAutomation || ComCall(8, iUIAutomation, "ptr*", eleFocus := ComValue(13, 0), "int") || !eleFocus.Ptr
        goto useAccLocation
    if !ComCall(16, eleFocus, "int", 10002, "ptr*", valuePattern := ComValue(13, 0), "int") && valuePattern.Ptr
        if !ComCall(5, valuePattern, "int*", &isReadOnly := 0) && isReadOnly
            return 0
    useAccLocation:
    ; use IAccessible::accLocation
    hwndFocus := DllCall("GetGUIThreadInfo", "uint", DllCall("GetWindowThreadProcessId", "ptr", WinExist("A"), "ptr", 0, "uint"), "ptr", guiThreadInfo) && NumGet(guiThreadInfo, A_PtrSize == 8 ? 16 : 12, "ptr") || WinExist()
    if hOleacc && !DllCall("Oleacc\AccessibleObjectFromWindow", "ptr", hwndFocus, "uint", 0xFFFFFFF8, "ptr", IID_IAccessible, "ptr*", accCaret := ComValue(13, 0), "int") && accCaret.Ptr {
        NumPut("ushort", 3, varChild := Buffer(24, 0))
        if !ComCall(22, accCaret, "int*", &x := 0, "int*", &y := 0, "int*", &w := 0, "int*", &h := 0, "ptr", varChild, "int")
            return hwndFocus
    }
    if iUIAutomation && eleFocus {
        ; use IUIAutomationTextPattern2::GetCaretRange
        if ComCall(16, eleFocus, "int", 10024, "ptr*", textPattern2 := ComValue(13, 0), "int") || !textPattern2.Ptr
            goto useGetSelection
        if ComCall(10, textPattern2, "int*", &isActive := 0, "ptr*", caretTextRange := ComValue(13, 0), "int") || !caretTextRange.Ptr || !isActive
            goto useGetSelection
        if !ComCall(10, caretTextRange, "ptr*", &rects := 0, "int") && rects && (rects := ComValue(0x2005, rects, 1)).MaxIndex() >= 3 {
            x := rects[0], y := rects[1], w := rects[2], h := rects[3]
            return hwndFocus
        }
        useGetSelection:
        ; use IUIAutomationTextPattern::GetSelection
        if textPattern2.Ptr
            textPattern := textPattern2
        else if ComCall(16, eleFocus, "int", 10014, "ptr*", textPattern := ComValue(13, 0), "int") || !textPattern.Ptr
            goto useGUITHREADINFO
        if ComCall(5, textPattern, "ptr*", selectionRangeArray := ComValue(13, 0), "int") || !selectionRangeArray.Ptr
            goto useGUITHREADINFO
        if ComCall(3, selectionRangeArray, "int*", &length := 0, "int") || length <= 0
            goto useGUITHREADINFO
        if ComCall(4, selectionRangeArray, "int", 0, "ptr*", selectionRange := ComValue(13, 0), "int") || !selectionRange.Ptr
            goto useGUITHREADINFO
        if ComCall(10, selectionRange, "ptr*", &rects := 0, "int") || !rects
            goto useGUITHREADINFO
        rects := ComValue(0x2005, rects, 1)
        if rects.MaxIndex() < 3 {
            if ComCall(6, selectionRange, "int", 0, "int") || ComCall(10, selectionRange, "ptr*", &rects := 0, "int") || !rects
                goto useGUITHREADINFO
            rects := ComValue(0x2005, rects, 1)
            if rects.MaxIndex() < 3
                goto useGUITHREADINFO
        }
        x := rects[0], y := rects[1], w := rects[2], h := rects[3]
        return hwndFocus
    }
    useGUITHREADINFO:
    if hwndCaret := NumGet(guiThreadInfo, A_PtrSize == 8 ? 48 : 28, "ptr") {
        if DllCall("GetWindowRect", "ptr", hwndCaret, "ptr", clientRect := Buffer(16)) {
            w := NumGet(guiThreadInfo, 64, "int") - NumGet(guiThreadInfo, 56, "int")
            h := NumGet(guiThreadInfo, 68, "int") - NumGet(guiThreadInfo, 60, "int")
            DllCall("ClientToScreen", "ptr", hwndCaret, "ptr", guiThreadInfo.Ptr + 56)
            x := NumGet(guiThreadInfo, 56, "int")
            y := NumGet(guiThreadInfo, 60, "int")
            return hwndCaret
        }
    }
    return 0
    static init() {
        try
            iUIAutomation := ComObject("{E22AD333-B25F-460C-83D0-0581107395C9}", "{30CBE57D-D9D0-452A-AB13-7AC5AC4825EE}")
        hOleacc := DllCall("LoadLibraryW", "str", "Oleacc.dll", "ptr")
        NumPut("int64", 0x11CF3C3D618736E0, "int64", 0x719B3800AA000C81, IID_IAccessible := Buffer(16))
        guiThreadInfo := Buffer(A_PtrSize == 8 ? 72 : 48), NumPut("uint", guiThreadInfo.Size, guiThreadInfo)
    }
}

;by tebayaki
;PlayMedia("https://dict.youdao.com/dictvoice?audio=apple")

PlayMedia(uri, time_out := 5000)
{
    DllCall("Combase\RoActivateInstance", "ptr", CreateHString("Windows.Media.Playback.MediaPlayer"), "ptr*", iMediaPlayer := ComValue(13, 0), "HRESULT")
    iUri := CreateUri(uri)
    ComCall(47, iMediaPlayer, "ptr", iUri) ; SetUriSource
    ComCall(45, iMediaPlayer) ; Play
    index := 1
    loop {
        ComCall(12, iMediaPlayer, "uint*", &state := 0) ; CurrentState
        if(index != 1)
            Sleep(20)
        index++
    } until (state == 3 || index > (time_out / 20))

    index := 1
    loop {
        ComCall(12, iMediaPlayer, "uint*", &state := 0) ; CurrentState
        if(index != 1)
            Sleep(20)
        index++
        Sleep(20)
    } until (state == 4 || index > (time_out / 20))
}

CreateUri(str)
{
    DllCall("ole32\IIDFromString", "str", "{44A9796F-723E-4FDF-A218-033E75B0C084}", "ptr", iid := Buffer(16), "HRESULT")
    DllCall("Combase\RoGetActivationFactory", "ptr", CreateHString("Windows.Foundation.Uri"), "ptr", iid, "ptr*", factory := ComValue(13, 0), "HRESULT")
    ComCall(6, factory, "ptr", CreateHString(str), "ptr*", uri := ComValue(13, 0))
    return uri
}

CreateHString(str)
{
    DllCall("Combase\WindowsCreateString", "wstr", str, "uint", StrLen(str), "ptr*", &hString := 0, "HRESULT")
    return { Ptr: hString, __Delete: (_) => DllCall("Combase\WindowsDeleteString", "ptr", _, "HRESULT") }
}

loadconfig(&config, json_path)
{
    outputvar := FileRead(json_path)
    config := JSON.parse(outputvar)
}
;保存配置函数
saveconfig(config, json_path)
{
    str := JSON.stringify(config, 4)
    FileDelete(json_path)
    FileAppend(str, json_path, 'UTF-8')
}

EncodeDecodeURI(str, encode := true, component := true) {
    ; Adapted from teadrinker: https://www.autohotkey.com/boards/viewtopic.php?p=372134#p372134
    static Doc, JS
    if !IsSet(Doc) {
        Doc := ComObject("htmlfile")
        Doc.write('<meta http-equiv="X-UA-Compatible" content="IE=9">')
        JS := Doc.parentWindow
        ( Doc.documentMode < 9 && JS.execScript() )
    }
    Return JS.%( (encode ? "en" : "de") . "codeURI" . (component ? "Component" : "") )%(str)
}

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
