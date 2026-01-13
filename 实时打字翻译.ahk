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
    if (!g_config.Has(g_current_api))
        return g_current_api
    api_config := g_config[g_current_api]
    return api_config.Has("display_name") ? api_config["display_name"] : g_current_api
}

; 获取带状态标识的服务名（实时模式添加⚡）
get_service_display_with_status()
{
    global g_is_realtime_mode
    display_name := get_current_service_display_name()

    ; 实时模式：添加⚡标识
    if (g_is_realtime_mode)
    {
        return display_name "⚡"
    }

    return display_name
}

; 显示tooltip并自动更新手柄和输入框位置（避免tooltip盖住手柄）
show_tooltip_and_update_handle(text, x, y)
{
    global g_dh, g_eb, g_drag_handle_height
    handle_width := 30

    ; 显示tooltip并获取实际位置（经过边界调整）
    tooltip_info := btt(text, Integer(x), Integer(y),,OwnzztooltipStyle1,{Transparent:180,DistanceBetweenMouseXAndToolTip:-100,DistanceBetweenMouseYAndToolTip:-20})

    ; 边缘检测：tooltip的固有行为
    ; 唯一排除：拖拽进行中时不检测（避免闪烁）
    if (!g_dh.is_dragging)
    {
        original_x := x + handle_width
        original_y := y
        x_adjusted := Abs(tooltip_info.X - original_x) > 5
        y_adjusted := Abs(tooltip_info.Y - original_y) > 5

        if (x_adjusted or y_adjusted)  ; X或Y方向被调整，说明贴边
        {
            OwnzztooltipEnd()  ; 清除当前tooltip

            ; 根据调整方向，基于BTT调整后的位置再向内缩5px
            new_x := tooltip_info.X
            new_y := tooltip_info.Y

            if (x_adjusted)
            {
                if (tooltip_info.X < original_x)  ; 向左调整了（右边贴边）
                    new_x := tooltip_info.X - 5  ; 基于调整后的位置再向左缩5px
                else  ; 向右调整了（左边贴边）
                    new_x := tooltip_info.X + 5  ; 基于调整后的位置再向右缩5px
            }

            if (y_adjusted)
            {
                if (tooltip_info.Y < original_y)  ; 向上调整了（下边贴边）
                    new_y := tooltip_info.Y - 5  ; 基于调整后的位置再向上缩5px
                else  ; 向下调整了（上边贴边）
                    new_y := tooltip_info.Y + 5  ; 基于调整后的位置再向下缩5px
            }

            ; 重新显示tooltip（使用新的安全位置）
            tooltip_info := btt(text, Integer(new_x), Integer(new_y),,OwnzztooltipStyle1,{Transparent:180,DistanceBetweenMouseXAndToolTip:-100,DistanceBetweenMouseYAndToolTip:-20})
        }
    }

    ; 根据tooltip的实际位置更新手柄位置（手柄在tooltip左侧）
    ; 只更新X坐标，Y坐标保持不变（避免垂直方向跳动）
    g_dh.ui.gui.GetPos(&current_handle_x, &current_handle_y)
    new_handle_x := tooltip_info.X - handle_width

    ; 只有当位置真正改变时才移动手柄
    if (current_handle_x != new_handle_x)
    {
        g_dh.ui.gui.Move(new_handle_x, current_handle_y)
    }

    ; 同时更新输入框位置：在tooltip下方，左对齐tooltip
    ; 输入框X = tooltip.X，输入框Y = tooltip.Y + 固化高度（即使tooltip换行增高也不改变）
    g_eb.move(tooltip_info.X, tooltip_info.Y + g_drag_handle_height)

    return tooltip_info
}

; ESC 退出翻译器（等待按键释放，避免按键传递给其他窗口）
close_translator(*)
{
    global g_eb, g_dh
    g_eb.hide()
    g_dh.hide()
    KeyWait("Esc")  ; 等待 ESC 释放，阻止按键传递
}

; 全局鼠标点击检测（用于失焦退出）
on_global_mouse_click(*)
{
    global g_eb, g_dh

    ; 只在翻译器显示时处理
    if (!g_eb.show_status)
        return

    ; 检查是否正在拖拽
    if (g_dh.is_dragging)
        return

    ; 获取点击的窗口句柄
    MouseGetPos(, , &clicked_window, &control)

    ; 如果点击的不是手柄 → 退出
    ; 点击手柄不退出（用户在拖拽），点击其他任何地方都退出
    if (clicked_window != g_dh.ui.Hwnd)
    {
        logger.info(">>> 点击非翻译器区域，自动退出")
        g_eb.hide()
        g_dh.hide()
    }
}

; 处理Enter键（默认模式：触发翻译/发送；实时模式：直接发送）
handle_enter_key(*)
{
    global g_is_realtime_mode, g_translation_completed, g_eb, g_is_translating

    ; 如果正在翻译中，不允许发送
    if (g_is_translating)
        return

    if (g_is_realtime_mode)
    {
        ; 实时模式：直接发送结果（当前行为）
        send_command('translate')
    }
    else
    {
        ; 默认模式：
        if (!g_translation_completed)
        {
            ; 第一次Enter：触发翻译
            g_eb.trigger_translate()
        }
        else
        {
            ; 第二次Enter：发送结果
            send_command('translate')
        }
    }
}

; 切换翻译模式（默认/实时）
switch_translation_mode(*)
{
    global g_is_realtime_mode, g_config, g_current_api, g_eb, g_dh, g_translation_completed

    ; 切换模式
    g_is_realtime_mode := !g_is_realtime_mode

    ; 重置翻译状态
    g_translation_completed := false

    ; 更新配置
    g_config["translation_mode"] := g_is_realtime_mode ? "realtime" : "manual"

    ; 保存配置
    saveconfig(g_config, A_ScriptDir "\config.json")

    ; 重新绘制tooltip以更新⚡标识
    if (g_eb.show_status)
    {
        g_eb.draw(0, false)  ; 不触发翻译，只重绘
    }

    logger.info('已切换到:', g_is_realtime_mode ? "实时翻译模式" : "默认发送模式")
}

; 统一的翻译器清理函数（由 Edit_box.hide() 调用）
cleanup_translator()
{
    global g_eb, g_dh, g_is_ime_char, g_is_translating, g_translation_completed

    ; 清除输入框内容
    g_eb.clear()
    g_eb.translation_result := ""

    ; 重置所有状态标志
    g_is_ime_char := false
    g_is_translating := false
    g_translation_completed := false

    ; 清除tooltip
    OwnzztooltipEnd()

    ; 停止防抖定时器（Edit_box 的定时器）
    if (g_eb.debounce_timer)
        SetTimer(g_eb.debounce_timer, 0)
    g_eb.debounce_timer := 0
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
    global config_path := A_ScriptDir "\config.json"
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

    ; 收集所有启用的模型（is_open=1 且有 api_key）
    global g_all_api := []
    for key, value in g_config
    {
        ; 跳过系统配置字段和数组类型字段（如 all_api）
        if (key = "translation_mode" || key = "cd" || key = "target_lang" || key = "ui_font")
            continue

        ; 检查是否是模型配置（必须是 Map 且有 is_open 字段）
        if (value is Map && value.Has("is_open") && value["is_open"] && value.Has("api_key") && value["api_key"])
        {
            g_all_api.Push(key)
        }
    }

    ; 确定当前API（优先使用配置的cd，否则使用第一个启用的）
    global g_current_api
    if (g_all_api.Length == 0)
    {
        MsgBox("错误：没有找到任何启用的翻译模型！请检查 config.json 中至少有一个模型的 is_open=1 且配置了 api_key")
        ExitApp
    }

    ; 检查配置的cd是否在启用的模型列表中
    cd_in_list := false
    if (g_config.Has("cd"))
    {
        for k,v in g_all_api
        {
            if (v = g_config["cd"])
            {
                cd_in_list := true
                break
            }
        }
    }

    if (cd_in_list)
    {
        g_current_api := g_config["cd"]
    }
    else
    {
        g_current_api := g_all_api[1]
        logger.info("cd配置无效，使用默认API: " g_current_api)
    }

    global g_target_lang := g_config.Has("target_lang") ? g_config["target_lang"] : "en"
    global g_translators := Map()  ; 存储所有LLM实例

    ; 初始化所有启用的LLM翻译器
    for api_name in g_all_api
    {
        api_config := g_config[api_name]
        g_translators[api_name] := OpenAI_Compat_LLM(
            api_name,
            api_config,
            ObjBindMethod(Edit_box, "on_change_stub")
        )
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

    ; 翻译状态标志（用于防止翻译未完成时发送）
    global g_is_translating := false
    global g_cancel_translation := false  ; 标记当前翻译是否被取消（Tab切换模型时）

    ; 翻译模式控制（默认/实时）
    global g_is_realtime_mode := (g_config.Has("translation_mode") && g_config["translation_mode"] == "realtime")
    global g_translation_completed := false  ; 标记当前翻译是否已完成（默认模式）

    ; UI字体配置
    global g_ui_font_family := g_config.Has("ui_font") && g_config["ui_font"].Has("family") ? g_config["ui_font"]["family"] : "Arial"
    global g_ui_font_tooltip_size := g_config.Has("ui_font") && g_config["ui_font"].Has("tooltip_size") ? g_config["ui_font"]["tooltip_size"] : 16
    global g_ui_font_input_size := g_config.Has("ui_font") && g_config["ui_font"].Has("input_size") ? g_config["ui_font"]["input_size"] : 30

    ; 更新 tooltip 样式字体大小
    OwnzztooltipStyle1.FontSize := g_ui_font_tooltip_size

    ; 光标闪烁相关变量
    global g_cursor_visible := true  ; 光标可见状态
    global g_cursor_blink_timer := 0  ; 光标闪烁定时器

    ; 拖拽把手高度（首次打开翻译器时固化tooltip首行高度）
    global g_drag_handle_height := 0

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
        Hotkey('XButton1', (key) => open_translator()) ;打开翻译器
        Hotkey('XButton2', (key) => send_command('Primitive')) ;打开翻译器
        Hotkey('!XButton2', (key) => (g_eb.text := '/all ' g_eb.text, send_command('Primitive'))) ;打开翻译器
        Hotkey('^XButton2', (key) => (g_eb.text := '/all ' g_eb.text, g_eb.translation_result := '/all ' g_eb.translation_result, send_command(''))) ;打开翻译器
        Hotkey('+XButton2', (key) => send_command('')) ;打开翻译器
        Hotkey('!f8', (key) => switch_lol_send_mode())
    HotIf()
    Hotkey('!y', (key) => open_translator()) ;打开翻译器
    Hotkey('^!y', (key) => translate_clipboard()) ;翻译粘贴板文本
    Hotkey('^f7', (key) => g_eb.debug()) ;调试
    Hotkey('^f8', (key) => switch_translation_mode()) ;切换翻译模式
    Hotkey('!l', (key) => change_target_language()) ;切换目标语言
    Hotkey('~Esc', close_translator) ;退出
    Hotkey('~LButton', on_global_mouse_click) ;全局鼠标点击检测（用于失焦退出）
	HotIfWinExist("ahk_id " g_eb.ui.hwnd)
        Hotkey("enter", handle_enter_key) ;默认模式：翻译/发送；实时模式：发送
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
        ENTER (默认模式): 发送翻译请求，再按一次发送
        ENTER (实时模式):直接发送
        CTRL ENTER : 发送原始文本
        CTRL F7 : 展示当前API配置
        CTRL F8 : 切换默认/实时翻译模式
        TAB : 切换翻译模型
        ESC : 退出
    )'
    btt(help_text,0, 0,,OwnzztooltipStyle1,{Transparent:180,DistanceBetweenMouseXAndToolTip:-100,DistanceBetweenMouseYAndToolTip:-20})
}

translate_clipboard(*)
{
    open_translator()
    g_eb.text := A_Clipboard
    g_eb.draw()
}

change_target_language(*)
{
    global g_target_lang, g_config

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

            logger.info('目标语言已切换到: ' g_target_lang)
        }
    }
}


serpentine_naming(key := 'snake')
{
    global g_eb

    ; 获取翻译结果进行格式转换
    cd_str := g_eb.translation_result

    ; 转换为小写
    cd_str := StrLower(cd_str)

    ; 空格替换为下划线
    cd_str := RegExReplace(cd_str, 'i)\s+', '_')

    ; 删除非字母数字下划线字符
    cd_str := RegExReplace(cd_str, "[^A-Za-z0-9_]", "")

    ; 删除首尾下划线
    cd_str := Trim(cd_str, '_')

    ; 驼峰命名转换
    if(key == 'hump')
    {
        ar := StrSplit(cd_str, '_')
        cd_str := ''
        for k,v in ar
            cd_str .= StrTitle(v)
    }

    ; 将转换后的结果设置为翻译结果
    g_eb.translation_result := cd_str

    ; 使用统一的发送命令逻辑（和普通Enter一样）
    send_command('translate')
}

copy(*)
{
    A_Clipboard := g_eb.translation_result
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
        translation_result := g_eb.translation_result  ; 先保存翻译结果
        g_eb.hide()
        g_dh.hide()  ; 隐藏拖拽框
        old := A_Clipboard
        if(p[1] == 'Primitive')
            A_Clipboard := data
        else
            A_Clipboard := translation_result, data := translation_result
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
    global g_current_api, g_eb, g_dh, g_config
    global g_all_api, g_cursor_x, g_cursor_y, g_is_translating, g_translation_completed, g_cancel_translation

    ; 如果正在翻译，取消当前翻译
    if (g_is_translating)
    {
        g_cancel_translation := true
        logger.info(">>> 取消当前翻译，切换模型")
    }

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

    ; 保存当前模型到配置（下次启动时恢复）
    g_config["cd"] := g_current_api
    saveconfig(g_config, A_ScriptDir "\config.json")

    ; 清空翻译状态和结果（切换模型后重新开始）
    g_eb.translation_result := ""
    g_translation_completed := false

    display_name := get_service_display_with_status()
    logger.info('=========' display_name)

    ; 获取手柄当前位置
    g_dh.ui.gui.GetPos(&handle_x, &handle_y)
    handle_width := 30

    ; 使用手柄位置显示tooltip（在手柄右侧，同一行）
    btt('[' display_name ']', Integer(handle_x + handle_width), Integer(handle_y),,OwnzztooltipStyle1,{Transparent:180,DistanceBetweenMouseXAndToolTip:-100,DistanceBetweenMouseYAndToolTip:-20})

    ; 确保手柄显示（防止在输入过程中丢失）
    if (!g_dh.show_status)
    {
        ; 如果手柄被隐藏了，使用保存的位置重新显示
        g_dh.show(g_cursor_x, g_cursor_y - 45)
    }

    g_eb.draw('tab')
}

open_translator(*)
{
    global g_cursor_x, g_cursor_y
    global g_window_hwnd, g_eb, g_dh
    global g_manual_positions, g_drag_handle_height

    ; 如果翻译器已经显示，先隐藏（防止重复创建窗口）
    if (g_eb.show_status)
    {
        g_eb.hide()
        g_dh.hide()
    }

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

    ; 显示 Tooltip（在手柄右侧，同一行）并获取实际位置和高度
    display_name := get_service_display_with_status()

    ; 使用统一的函数处理边缘检测和位置更新
    tooltip_info := show_tooltip_and_update_handle('[' display_name ']', x + handle_width, tooltip_y)

    ; tooltip_info 包含 X, Y（经过边界调整后的实际位置）和 H（高度）
    ; 只在水平方向使用调整后的位置，垂直方向保持原值（避免顶部时位置下移）
    handle_x := tooltip_info.X - handle_width
    handle_y := tooltip_y  ; 保持原值，不使用调整后的 Y
    tooltip_height := tooltip_info.H

    ; 首次记录tooltip高度（只在第一次打开时固化首行高度）
    if (g_drag_handle_height = 0) {
        g_drag_handle_height := tooltip_info.H
    }

    ; 显示拖拽手柄（使用固化高度，即使后续tooltip换行增高也不改变）
    g_dh.show_with_height(handle_x, handle_y, handle_width, g_drag_handle_height)

    ; 显示输入框（在tooltip下方，左对齐tooltip）
    g_eb.show(tooltip_info.X, y)
}
ON_WM_KEYDOWN(wParam, lParam, msg, hwnd)
{
    ; 只处理输入框的消息
    if (hwnd != g_eb.ui.Hwnd)
        return

    ; VK_LEFT = 37, VK_RIGHT = 39
    if (wParam == 37)
    {
        g_eb.left()
    }
    else if (wParam == 39)
    {
        g_eb.right()
    }
}

; ========== 鼠标拖拽相关函数 ==========

; 拖拽定时器回调：持续更新输入框和 Tooltip 位置
DragUpdateTimer()
{
    global g_dh, g_eb, g_drag_handle_height

    if (!g_dh.is_dragging)
        return

    ; 获取手柄当前位置
    local x, y
    g_dh.ui.gui.GetPos(&x, &y)

    ; 手柄宽度
    handle_width := 30

    ; 移动输入框（在tooltip下方，左对齐tooltip）
    ; 手柄在y，tooltip也在y（同一行），输入框在y+固化高度（tooltip下方）
    g_eb.move(x + handle_width, y + g_drag_handle_height)

    ; 更新 Tooltip 位置和内容（在手柄右侧，同一行）
    display_name := get_service_display_with_status()
    if (g_eb.translation_result != "")
    {
        show_tooltip_and_update_handle('[' display_name ']: ' g_eb.translation_result, x + handle_width, y)
    }
    else
    {
        show_tooltip_and_update_handle('[' display_name ']', x + handle_width, y)
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

    ; 拖拽结束后，tooltip可能因为贴边被BTT调整了位置
    ; 此时需要根据tooltip的实际位置重新调整手柄位置（和翻译结果过长时的行为一致）
    handle_width := 30
    display_name := get_service_display_with_status()

    ; 根据翻译结果显示不同的tooltip
    if (g_eb.translation_result != "")
    {
        show_tooltip_and_update_handle('[' display_name ']: ' g_eb.translation_result, x + handle_width, y)
    }
    else
    {
        show_tooltip_and_update_handle('[' display_name ']', x + handle_width, y)
    }

    ; 激活翻译输入框，确保拖动后焦点回到输入框
    WinActivate("ahk_id " g_eb.ui.gui.Hwnd)

    logger.info(">>> 拖拽结束，保存位置:", process_name, x, y)
}

ON_MESSAGE_WM_CHAR(wParam, lParam, msg, hwnd)
{
    global g_is_realtime_mode, g_translation_completed, g_dh, g_eb

    ; 只处理输入框的消息
    if (hwnd != g_eb.ui.Hwnd)
        return

    logger.info(wParam, lParam, num2utf16(wParam))

    ; 默认模式下：字符输入重置翻译状态并更新tooltip
    if (!g_is_realtime_mode && g_translation_completed)
    {
        g_translation_completed := false

        ; 重新显示tooltip，去掉[↵]
        if (g_eb.translation_result != "" && g_dh.show_status)
        {
            g_dh.ui.gui.GetPos(&x, &y)
            handle_width := 30
            display_name := get_service_display_with_status()

            ; 重新显示tooltip（不带[↵]）
            show_tooltip_and_update_handle('[' display_name ']: ' g_eb.translation_result, x + handle_width, y)
        }
    }

    if (lParam != 1)
        g_eb.set_imm(wParam)
}
ON_MESSAGE_WM_IME_CHAR(wParam, lParam, msg, hwnd)
{
    global g_is_realtime_mode, g_translation_completed, g_is_ime_char, g_dh, g_eb

    ; 只处理输入框的消息
    if (hwnd != g_eb.ui.Hwnd)
        return

    g_is_ime_char := true

    ; 默认模式下：中文输入重置翻译状态并更新tooltip
    if (!g_is_realtime_mode && g_translation_completed)
    {
        g_translation_completed := false

        ; 重新显示tooltip，去掉[↵]
        if (g_eb.translation_result != "" && g_dh.show_status)
        {
            g_dh.ui.gui.GetPos(&x, &y)
            handle_width := 30
            display_name := get_service_display_with_status()

            ; 重新显示tooltip（不带[↵]）
            show_tooltip_and_update_handle('[' display_name ']: ' g_eb.translation_result, x + handle_width, y)
        }
    }

    logger.info(wParam, lParam, num2utf16(wParam))
    g_eb.set_imm(wParam)
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
        global g_ui_font_tooltip_size
        ui := this.ui
        if(ui.BeginDraw())
        {
            ; 获取窗口实际尺寸
            width := this.ui.width
            height := this.ui.height

            ; 绘制半透明背景（使用实际尺寸）
            ui.FillRoundedRectangle(0, 0, width, height, 4, 4, 0xcc2A2A2A)
            ui.DrawRoundedRectangle(0, 0, width, height, 4, 4, 0xFF40C1FF, 1)

            ; 图标大小基于tooltip字体大小（稍大一点以保持视觉平衡）
            icon_size := g_ui_font_tooltip_size + 2
            icon_wh := ui.GetTextWidthHeight("≡", icon_size, "Arial")

            ; 居中定位
            icon_x := Integer((width - icon_wh.width) / 2)
            icon_y := Integer((height - icon_wh.height) / 2)

            ; 绘制 ≡ 符号（Arial字体）
            ui.DrawText('≡', icon_x, icon_y, icon_size, 0xFF40C1FF, "Arial")

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
        this.translation_result := ''
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
        global g_config, g_current_api, g_target_lang, g_is_realtime_mode
        try
        {
            api_info := g_config[g_current_api]
            display_name := get_current_service_display_name()
            MsgBox(
                "当前服务: " display_name " (" g_current_api ")`n"
                "模型: " api_info["model"] "`n"
                "API地址: " api_info["base_url"] "`n"
                "目标语言: " g_target_lang "`n"
                "翻译模式: " (g_is_realtime_mode ? "实时模式" : "默认模式") "`n`n"
                "按 ALT L 可修改目标语言`n"
                "按 Ctrl F8 可切换翻译模式"
            )
        }
        catch as e
        {
            logger.err(e.Message)
        }
    }
    ; 获取显示文本（将空格替换为␣）
    get_display_text(text := "")
    {
        if (text == "")
            text := this.text
        return StrReplace(text, " ", "␣")
    }

    ; 显示翻译中提示（默认模式触发翻译时）
    show_translating_tooltip()
    {
        global g_dh
        ; 获取手柄位置（tooltip在手柄右侧，同一行）
        g_dh.ui.gui.GetPos(&x, &y)
        handle_width := 30
        display_name := get_service_display_with_status()

        ; 显示 [✈] 提示
        show_tooltip_and_update_handle('[' display_name ']: [✈]', x + handle_width, y)
    }

    on_change(cd ,text)
    {
        global g_is_translating, g_dh, g_is_realtime_mode, g_translation_completed, g_cancel_translation, g_current_api

        ; 翻译完成（成功或失败），清除翻译状态
        g_is_translating := false

        ; 检查是否被取消（Tab切换模型时）
        if (g_cancel_translation)
        {
            g_cancel_translation := false
            logger.info(">>> 翻译结果已丢弃（模型已切换）")
            return  ; 不显示结果，直接返回
        }

        ; 默认模式：标记翻译已完成
        if (!g_is_realtime_mode)
        {
            g_translation_completed := true
        }

        logger.info(cd ,text)
        logger.info()
        if(this.show_status && cd = g_current_api)
        {
            this.translation_result := text

            ; 获取手柄位置（tooltip在手柄右侧，同一行）
            g_dh.ui.gui.GetPos(&x, &y)
            handle_width := 30
            display_name := get_service_display_with_status()

            ; 如果翻译结果为空，只显示服务名
            if (text = "")
            {
                show_tooltip_and_update_handle('[' display_name ']', x + handle_width, y)
            }
            else
            {
                tooltip_text := '[' display_name ']: ' text

                ; 默认模式 + 翻译完成：添加[↵]
                if (!g_is_realtime_mode && g_translation_completed)
                {
                    tooltip_text .= '[↵]'
                }

                show_tooltip_and_update_handle(tooltip_text, x + handle_width, y)
            }
        }
    }
    show(x := 0, y := 0)
    {
        global g_cursor_blink_timer, g_cursor_visible
        this.ui.gui.show('x' x ' y' y)
        this.show_status := true

        ; 重置光标状态并启动闪烁
        g_cursor_visible := true
        g_cursor_blink_timer := SetTimer(toggle_cursor_blink, 530)

        this.draw()  ; 立即绘制，避免白框
    }
    hide()
    {
        global g_cursor_blink_timer

        ; 隐藏窗口
        this.ui.gui.hide()
        this.show_status := false

        ; 停止光标闪烁定时器
        if (g_cursor_blink_timer)
            SetTimer(g_cursor_blink_timer, 0)
        g_cursor_blink_timer := 0

        ; 调用统一清理函数（清除内容、状态、tooltip、防抖定时器）
        cleanup_translator()
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

        global g_ui_font_family, g_ui_font_input_size

        try
        {
            ; 获取显示文本（空格替换为␣）
            display_text := this.get_display_text()

            ; 计算文本宽度
            wh := this.ui.GetTextWidthHeight(display_text, g_ui_font_input_size, g_ui_font_family)

            if(ui.BeginDraw())
            {
                ui.FillRoundedRectangle(0, 0, wh.width, wh.height, 5, 5, 0xcc1E1E1E)
                ; ui.DrawRoundedRectangle(0, 0, wh.width, wh.height, 5, 5, 0xffff0000, 1)  ; 红色边框已注释

                ; 统一绘制文本（空格显示为␣，统一颜色）
                ui.DrawText(display_text, 0, 0, g_ui_font_input_size, 0xFFC9E47E, g_ui_font_family)
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

        global g_current_api, g_translators, g_config, g_dh, g_cursor_visible
        global g_ui_font_family, g_ui_font_input_size
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
                display_text := this.get_display_text()
                wh := this.ui.GetTextWidthHeight(display_text, g_ui_font_input_size, g_ui_font_family)
                if(ui.BeginDraw())
                {
                    ui.FillRoundedRectangle(0, 0, wh.width, wh.height, 5, 5, 0xcc1E1E1E)
                    ; ui.DrawRoundedRectangle(0, 0, wh.width, wh.height, 5, 5, 0xffff0000, 1)  ; 红色边框已注释

                    ; 统一绘制文本（空格显示为␣，统一颜色）
                    ui.DrawText(display_text, 0, 0, g_ui_font_input_size, 0xFFC9E47E, g_ui_font_family)
                    ui.EndDraw()
                }
                return  ; 拖拽时直接返回，不执行后续的翻译等复杂操作
            }

            ; 获取显示文本（空格替换为␣）
            display_text := this.get_display_text()

            ; 计算文字的大小
            wh := this.ui.GetTextWidthHeight(display_text, g_ui_font_input_size, g_ui_font_family)
            logger.info(wh)
            this.move(x, y, wh.width + 100, wh.height + 100)

            ; 只在输入为空时显示服务名 Tooltip（避免频繁更新）
            if (this.text = "")
            {
                this.translation_result := ""
                ; 获取手柄位置（tooltip在手柄右侧，同一行）
                g_dh.ui.gui.GetPos(&handle_x, &handle_y)
                handle_width := 30
                display_name := get_service_display_with_status()
                btt('[' display_name ']', Integer(handle_x + handle_width), Integer(handle_y),,OwnzztooltipStyle1,{Transparent:180,DistanceBetweenMouseXAndToolTip:-100,DistanceBetweenMouseYAndToolTip:-20})
            }
            if(ui.BeginDraw())
            {
                ui.FillRoundedRectangle(0, 0, wh.width, wh.height, 5, 5, 0xcc1E1E1E)
                ; ui.DrawRoundedRectangle(0, 0, wh.width, wh.height, 5, 5, 0xffff0000, 1)  ; 红色边框已注释

                ; 统一绘制文本（空格显示为␣，统一颜色）
                ui.DrawText(display_text, 0, 0, g_ui_font_input_size, 0xFFC9E47E, g_ui_font_family, "h" wh.height)

                ; 绘制光标（只在有焦点且可见状态时显示）
                if (g_cursor_visible)
                {
                    ; 计算末尾 insert_pos 个字符的实际绘制宽度（使用替换后的文本）
                    tail_width := 0
                    if (this.insert_pos > 0 && this.text != "")
                    {
                        ; 从末尾取 insert_pos 个字符并替换空格
                        tail_text := this.get_display_text(SubStr(this.text, -this.insert_pos))
                        tail_wh := this.ui.GetTextWidthHeight(tail_text, g_ui_font_input_size, g_ui_font_family)
                        tail_width := tail_wh.width
                    }

                    ; 光标位置：实际绘制总宽度 - 末尾字符的实际宽度
                    cursor_x := wh.width - tail_width
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

        ; 检查是否启用实时翻译（使用全局模式变量）
        global g_is_realtime_mode
        if (g_is_realtime_mode && input_text != "")
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
        global g_translators, g_current_api, g_target_lang, g_is_translating, g_dh
        input_text := this.text
        if (input_text != "" && g_translators.Has(g_current_api))
        {
            ; 标记正在翻译
            g_is_translating := true

            ; 显示翻译中提示
            this.show_translating_tooltip()

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
    try
    {
        outputvar := FileRead(json_path, "UTF-8")
        ; 移除BOM标记（如果存在）
        if (SubStr(outputvar, 1, 3) == "﻿")
            outputvar := SubStr(outputvar, 4)

        config := JSON.parse(outputvar)
    }
    catch as e
    {
        MsgBox("配置文件加载失败: " e.Message "`n`n请检查 config.json 格式是否正确")
        ExitApp
    }
}
;保存配置函数
saveconfig(config, json_path)
{
    try
    {
        str := JSON.stringify(config, 4)
        FileDelete(json_path)
        FileAppend(str, json_path, 'UTF-8')
        return true
    }
    catch as e
    {
        MsgBox("保存配置失败: " e.Message)
        return false
    }
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
