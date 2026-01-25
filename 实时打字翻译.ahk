#Requires AutoHotkey v2.0
#include <Direct2DRender>
#include <zmq>
#include <log>
#include <ComVar>
#include <btt>
#include <WinHttpRequest>
#include <LLM_Translator>
#include ./utility/lol_game.ah2

logger.is_log_open := false  ; 关闭日志
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

; 智能文本换行函数（记事本式：单词作为整体）
wrap_text_word_aware(text, max_width, font_size, font_family, renderer)
{
    delimiters := " ,.!?;:，。！？；："
    result_lines := []
    current_line := ""

    words := split_keep_delimiters(text, delimiters)

    for word in words
    {
        test_line := (current_line = "") ? word : current_line . " " . word
        wh := renderer.GetTextWidthHeight(test_line, font_size, font_family)

        if (wh.width <= max_width)
            current_line := test_line
        else
        {
            if (current_line = "")
                current_line := word
            else
            {
                result_lines.Push(current_line)
                current_line := word
            }
        }
    }

    if (current_line != "")
        result_lines.Push(current_line)

    return RTrim(result_lines.Join("`n"))
}

; 辅助函数：分割文本但保留分隔符
split_keep_delimiters(text, delimiters)
{
    result := []
    current := ""

    loop Parse, text
    {
        char := A_LoopField
        if (InStr(delimiters, char))
        {
            if (current != "")
                result.Push(current)
            result.Push(char)
            current := ""
        }
        else
            current .= char
    }
    if (current != "")
        result.Push(current)

    return result
}

; 显示tooltip并自动更新手柄和输入框位置（避免tooltip盖住手柄）
show_tooltip_and_update_handle(text, x, y)
{
    global g_dh, g_eb, g_drag_handle_height
    handle_width := 30

    ; 显示tooltip并获取实际位置（不使用换行预处理，让BTT自己处理）
    tooltip_info := btt(text, Integer(x), Integer(y),, OwnzztooltipStyle1, {Transparent:180, DistanceBetweenMouseXAndToolTip:-100, DistanceBetweenMouseYAndToolTip:-20})

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
            tooltip_info := btt(text, Integer(new_x), Integer(new_y),, OwnzztooltipStyle1, {Transparent:180, DistanceBetweenMouseXAndToolTip:-100, DistanceBetweenMouseYAndToolTip:-20})
        }
    }

    ; 根据tooltip的实际位置更新手柄位置（手柄在tooltip左侧）
    ; 只更新X坐标，Y坐标保持不变（避免垂直方向跳动）
    pos := g_dh.get_gui_pos()
    current_handle_x := pos.x
    current_handle_y := pos.y
    new_handle_x := tooltip_info.X - handle_width

    ; 只有当位置真正改变时才移动手柄
    if (current_handle_x != new_handle_x)
    {
        g_dh.ui.gui.Move(new_handle_x, current_handle_y)
    }

    ; 同时更新输入框位置：在tooltip下方，左对齐tooltip
    ; 输入框X = tooltip.X，输入框Y = tooltip.Y + tooltip实际高度（考虑换行后的高度）
    g_eb.move(tooltip_info.X, tooltip_info.Y + tooltip_info.H)

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
    global g_is_realtime_mode, g_translation_completed, g_eb, g_is_translating, g_is_info_only, g_dh, g_config

    ; 如果正在翻译中，不允许发送
    if (g_is_translating)
        return

    ; 检测是否为斜杠命令
    input_text := g_eb.text
    if (SubStr(input_text, 1, 1) == "/")
    {
        ; 处理命令
        if (input_text == "/status")
        {
            handle_status_command()
            return
        }
        else if (SubStr(input_text, 1, 6) == "/lang ")
        {
            handle_lang_command()
            return
        }
        else
        {
            ; 未知命令提示
            btt("未知命令: " input_text "`n目前只支持 /status 和 /lang", 0, 0,, OwnzztooltipStyle1, {Transparent:180, DistanceBetweenMouseXAndToolTip:-100, DistanceBetweenMouseYAndToolTip:-20})
            SetTimer(() => OwnzztooltipEnd(), -3000)
            g_eb.hide()
            return
        }
    }

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
            ; 第二次Enter：根据结果类型决定发送或重置
            if (g_is_info_only)
            {
                ; 不可发送的结果（如 /status）：重置为初始状态
                g_eb.clear()
                g_eb.translation_result := ""
                g_translation_completed := false
                g_is_info_only := false

                ; 重新绘制输入框
                g_eb.draw(0, false)

                ; 重新显示服务名 tooltip（和刚打开 Alt+Y 一样）
                pos := g_dh.get_gui_pos()
                handle_width := 30
                display_name := get_service_display_with_status()
                show_tooltip_and_update_handle('[' display_name ']', Integer(pos.x + handle_width), Integer(pos.y))
            }
            else
            {
                ; 可发送的结果（翻译结果）：发送
                send_command('translate')
            }
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

; 处理 /status 命令
handle_status_command(*)
{
    global g_eb, g_config, g_current_api, g_target_lang, g_is_realtime_mode, g_translation_completed, g_is_info_only

    ; 构建配置信息
    api_info := g_config[g_current_api]
    display_name := get_current_service_display_name()
    status_text := "`n模型： " api_info["model"] "`n目标语言： " g_target_lang "`n模式： " (g_is_realtime_mode ? "实时" : "默认")
    g_eb.translation_result := status_text
    g_translation_completed := true
    g_is_info_only := true  ; 标记为信息，不可发送

    ; 直接调用 on_change 显示结果（完全复用翻译流程）
    g_eb.on_change(g_current_api, status_text)

    ; 清空输入框
    g_eb.clear()
}

; 开始翻译语言名称（通过 LLM 异步回调）
translate_lang_name(user_lang_input)
{
    global g_current_api, g_translators

    ; 构建完整的 prompt（英文，避免 LLM 翻译指令）
    prompt := "Translate the following language name into standard English language code (e.g. Japanese, French, Korean). Only output the translation result without any explanation.`n`nLanguage name: " user_lang_input

    ; 创建临时回调来处理语言名称翻译完成
    lang_name_callback := (translator_name, translated_lang) => (
        on_lang_name_translation_completed(translated_lang)
    )

    ; 设置临时回调
    g_translators[g_current_api].set_callback(lang_name_callback)

    ; 发送原始 prompt（不经过 build_prompt 包装）
    g_translators[g_current_api].send_raw_prompt(prompt)
}

; 语言名称翻译完成回调
on_lang_name_translation_completed(translated_lang)
{
    global g_eb, g_config, g_current_api, g_target_lang, g_translation_completed, g_is_info_only, g_is_translating

    ; 翻译完成，清除翻译状态
    g_is_translating := false

    if (translated_lang != "")
    {
        ; 保存翻译后的标准语言名
        g_target_lang := translated_lang
        g_config["target_lang"] := translated_lang

        ; 保存到配置文件
        saveconfig(g_config, A_ScriptDir "\config.json")

        ; 显示切换成功信息
        result_text := "目标语言已切换到: " g_target_lang
        g_eb.translation_result := result_text
        g_translation_completed := true
        g_is_info_only := true  ; 标记为信息，不可发送

        ; 完全复用翻译流程显示结果（自动显示 [↵]）
        g_eb.on_change(g_current_api, result_text)

        ; 清空输入框
        g_eb.clear()

        logger.info('目标语言已切换到: ' g_target_lang)
    }
    else
    {
        ; 翻译失败提示
        btt("语言翻译失败，请重试", 0, 0,, OwnzztooltipStyle1, {Transparent:180, DistanceBetweenMouseXAndToolTip:-100, DistanceBetweenMouseYAndToolTip:-20})
        SetTimer(() => OwnzztooltipEnd(), -3000)
        g_eb.clear()
    }

    ; 恢复原始回调
    g_translators[g_current_api].set_callback(ObjBindMethod(g_eb, "on_change"))
}

; 处理 /lang 命令
handle_lang_command(*)
{
    global g_eb, g_config, g_current_api, g_target_lang, g_translation_completed, g_is_info_only, g_is_translating

    ; 解析语言参数
    input_text := g_eb.text
    new_lang := Trim(SubStr(input_text, 7))

    if (new_lang == "")
    {
        btt("请指定目标语言`n用法: /lang 目标语言", 0, 0,, OwnzztooltipStyle1, {Transparent:180, DistanceBetweenMouseXAndToolTip:-100, DistanceBetweenMouseYAndToolTip:-20})
        SetTimer(() => OwnzztooltipEnd(), -3000)
        g_eb.clear()
        return
    }

    ; 标记正在翻译（阻止按回车）
    g_is_translating := true

    ; 重置翻译完成状态
    g_translation_completed := false

    ; 开始翻译语言名称（异步）
    translate_lang_name(new_lang)
}

; 统一的翻译器清理函数（由 Edit_box.hide() 调用）
cleanup_translator()
{
    global g_eb, g_dh, g_is_ime_char, g_is_translating, g_translation_completed, g_is_info_only

    ; 清除输入框内容
    g_eb.clear()
    g_eb.translation_result := ""

    ; 重置所有状态标志
    g_is_ime_char := false
    g_is_translating := false
    g_translation_completed := false
    g_is_info_only := false

    ; 清除tooltip
    OwnzztooltipEnd()

    ; 停止防抖定时器（Edit_box 的定时器）
    if (g_eb.debounce_timer)
        SetTimer(g_eb.debounce_timer, 0)
    g_eb.debounce_timer := 0
}

; ========== 光标闪烁定时器（已弃用 - 方案A：光标常亮）==========
; toggle_cursor_blink()
; {
;     global g_cursor_visible, g_eb, g_cursor_blink_timer
;
;     ; 如果输入框已隐藏，停止闪烁
;     if (!g_eb.show_status)
;     {
;         if (g_cursor_blink_timer)
;             SetTimer(g_cursor_blink_timer, 0)
;         g_cursor_blink_timer := 0
;         return
;     }
;
;     ; 切换光标可见状态
;     g_cursor_visible := !g_cursor_visible
;
;     ; 重绘输入框以显示/隐藏光标（不触发翻译）
;     g_eb.draw(0, false)
; }

main()
main()
{
    btt('加载中。。。',0, 0,,OwnzztooltipStyle1,{Transparent:180,DistanceBetweenMouseXAndToolTip:-100,DistanceBetweenMouseYAndToolTip:-20})

    ; 配置文件路径
    global config_path := A_ScriptDir "\config.json"
    if !FileExist(config_path)
    {
        MsgBox('错误：找不到配置文件 config.json`n`n请确保你下载了完整的发布包。')
        ExitApp
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

    ; 位置记忆相关变量（会话级，按控件句柄）
    global g_manual_positions := Map()

    ; 翻译状态标志（用于防止翻译未完成时发送）
    global g_is_translating := false
    global g_cancel_translation := false  ; 标记当前翻译是否被取消（Tab切换模型时）

    ; 翻译模式控制（默认/实时）
    global g_is_realtime_mode := (g_config.Has("translation_mode") && g_config["translation_mode"] == "realtime")
    global g_translation_completed := false  ; 标记当前翻译是否已完成（默认模式）
    global g_is_info_only := false  ; 标记当前结果是否为不可发送的信息（如命令状态信息）

    ; UI字体配置
    global g_ui_font_family := g_config.Has("ui_font") && g_config["ui_font"].Has("family") ? g_config["ui_font"]["family"] : "Arial"
    global g_ui_font_tooltip_size := g_config.Has("ui_font") && g_config["ui_font"].Has("tooltip_size") ? g_config["ui_font"]["tooltip_size"] : 16
    global g_ui_font_input_size := g_config.Has("ui_font") && g_config["ui_font"].Has("input_size") ? g_config["ui_font"]["input_size"] : 30

    ; 更新 tooltip 样式字体大小
    OwnzztooltipStyle1.FontSize := g_ui_font_tooltip_size

    ; 【方案A：光标常亮】光标闪烁相关变量（已弃用）
    ; global g_cursor_visible := true  ; 光标可见状态
    ; global g_cursor_blink_timer := 0  ; 光标闪烁定时器

    ; 拖拽把手高度（首次打开翻译器时固化tooltip首行高度）
    global g_drag_handle_height := 0

    ; 输入框宽度限制（测试800px）
    global MAX_INPUT_WIDTH := 800

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
    Hotkey('^f8', (key) => switch_translation_mode()) ;切换翻译模式
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
        ENTER (默认模式): 发送翻译请求，再按一次发送
        ENTER (实时模式):直接发送
        CTRL ENTER : 发送原始文本
        CTRL F8 : 切换默认/实时翻译模式
        TAB : 切换翻译模型
        ESC : 退出
    )'
    btt(help_text, 0, 0, , OwnzztooltipStyle1, {Transparent:180, DistanceBetweenMouseXAndToolTip:-100, DistanceBetweenMouseYAndToolTip:-20})

    ; 设置60秒后自动关闭 HelpText
    SetTimer(() => OwnzztooltipEnd(), -60000)
}

translate_clipboard(*)
{
    open_translator()
    g_eb.text := A_Clipboard
    g_eb.draw()
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
    g_eb.set_text(A_Clipboard)
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

    ; 获取手柄当前位置
    pos := g_dh.get_gui_pos()
    handle_width := 30

    ; 使用手柄位置显示tooltip（在手柄右侧，同一行）
    display_name := get_service_display_with_status()
    btt('[' display_name ']', Integer(pos.x + handle_width), Integer(pos.y),,OwnzztooltipStyle1,{Transparent:180,DistanceBetweenMouseXAndToolTip:-100,DistanceBetweenMouseYAndToolTip:-20})

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

    ; 声明局部变量，避免 #Warn 警告
    local x := 0, y := 0, w := 0, h := 0

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

    ; 检查窗口句柄是否有效
    if (!g_window_hwnd)
    {
        logger.info("错误：无法获取有效窗口句柄")
        return
    }

    ; 使用控件句柄作为位置记忆的键（支持同一软件内的多个输入框）
    control_hwnd := g_window_hwnd
    local class_name := ""  ; 声明局部变量，避免 #Warn 警告

    ; 检查当前会话是否有该控件的记忆位置
    if (g_manual_positions.Has(control_hwnd))
    {
        pos := g_manual_positions[control_hwnd]
        x := pos.x
        y := pos.y

        ; 验证控件句柄是否仍然有效
        try {
            WinGetClass(class_name, "ahk_id " control_hwnd)
            logger.info("使用记忆位置 [控件]: " class_name, x, y)
        } catch {
            logger.info("记忆位置的控件句柄已失效，使用默认位置")
            ; 移除失效的记录
            g_manual_positions.Delete(control_hwnd)
        }
    }
    else
    {
        try {
            WinGetClass(class_name, "ahk_id " control_hwnd)
            logger.info("使用默认光标位置: " class_name, x, y)
        } catch {
            logger.info("使用默认光标位置")
        }
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

    ; 显示输入框（在tooltip下方，左对齐tooltip，考虑tooltip换行后的高度）
    g_eb.show(tooltip_info.X, tooltip_info.Y + tooltip_info.H)
}
ON_WM_KEYDOWN(wParam, lParam, msg, hwnd)
{
    ; 只处理输入框的消息
    if (hwnd != g_eb.ui.Hwnd)
        return

    ; VK_LEFT = 37, VK_RIGHT = 39, VK_UP = 38, VK_DOWN = 40, VK_DELETE = 46
    if (wParam == 37)
    {
        g_eb.left()
    }
    else if (wParam == 39)
    {
        g_eb.right()
    }
    else if (wParam == 38)
    {
        g_eb.up()
    }
    else if (wParam == 40)
    {
        g_eb.down()
    }
    else if (wParam == 46)  ; VK_DELETE
    {
        g_eb.delete()
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
    pos := g_dh.get_gui_pos()

    ; 手柄宽度
    handle_width := 30

    ; 更新 Tooltip 位置和内容（在手柄右侧，同一行）
    ; 注意：show_tooltip_and_update_handle() 会自动更新输入框位置到tooltip下方
    display_name := get_service_display_with_status()
    if (g_eb.translation_result != "")
    {
        show_tooltip_and_update_handle('[' display_name ']: ' g_eb.translation_result, Integer(pos.x + handle_width), Integer(pos.y))
    }
    else
    {
        show_tooltip_and_update_handle('[' display_name ']', Integer(pos.x + handle_width), Integer(pos.y))
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
    global g_dh, g_eb

    ; 只处理手柄窗口的消息
    if (hwnd != g_dh.ui.Hwnd)
        return

    logger.info(">>> 进入拖拽模式，启动定时器")

    ; 【方案A：光标常亮】拖拽时保持光标显示，不需要停止闪烁

    ; 立即重绘（光标仍然显示）
    g_eb.draw_fast()

    ; 每 16ms 更新一次（约 60fps）
    SetTimer(DragUpdateTimer, 16)
}

; 退出拖拽模式：停止定时器并保存位置
ON_WM_EXITSIZEMOVE(wParam, lParam, msg, hwnd)
{
    global g_dh, g_eb, g_window_hwnd, g_cursor_x, g_cursor_y
    global g_manual_positions

    ; 只处理手柄窗口的消息
    if (hwnd != g_dh.ui.Hwnd)
        return

    ; 停止定时器
    SetTimer(DragUpdateTimer, 0)

    ; 标记拖拽结束
    g_dh.is_dragging := false

    ; 【方案A：光标常亮】不需要恢复闪烁定时器

    ; 保存位置（使用控件句柄作为键）
    pos := g_dh.get_gui_pos()
    control_hwnd := g_window_hwnd
    g_manual_positions[control_hwnd] := {x: pos.x, y: pos.y}

    ; 更新全局坐标
    g_cursor_x := pos.x
    g_cursor_y := pos.y

    ; 拖拽结束后，tooltip可能因为贴边被BTT调整了位置
    ; 此时需要根据tooltip的实际位置重新调整手柄位置（和翻译结果过长时的行为一致）
    handle_width := 30
    display_name := get_service_display_with_status()

    ; 根据翻译结果显示不同的tooltip
    if (g_eb.translation_result != "")
    {
        show_tooltip_and_update_handle('[' display_name ']: ' g_eb.translation_result, pos.x + handle_width, pos.y)
    }
    else
    {
        show_tooltip_and_update_handle('[' display_name ']', pos.x + handle_width, pos.y)
    }

    ; 激活翻译输入框，确保拖动后焦点回到输入框
    if (WinExist("ahk_id " g_eb.ui.gui.Hwnd))
        WinActivate("ahk_id " g_eb.ui.gui.Hwnd)

    ; 记录调试信息（使用控件类名标识）
    local class_name := ""  ; 声明局部变量，避免 #Warn 警告
    try {
        WinGetClass(class_name, "ahk_id " control_hwnd)
        logger.info(">>> 拖拽结束，保存位置 [控件]: " class_name, pos.x, pos.y)
    } catch {
        logger.info(">>> 拖拽结束，保存位置", pos.x, pos.y)
    }
}

ON_MESSAGE_WM_CHAR(wParam, lParam, msg, hwnd)
{
    global g_is_realtime_mode, g_translation_completed, g_dh, g_eb

    ; 只处理输入框的消息
    if (hwnd != g_eb.ui.Hwnd)
        return

    ; logger.info(wParam, lParam, num2utf16(wParam))  ; 性能优化：移除热路径日志

    ; 默认模式下：字符输入重置翻译状态并更新tooltip
    if (!g_is_realtime_mode && g_translation_completed)
    {
        g_translation_completed := false

        ; 重新显示tooltip，去掉[↵]
        if (g_eb.translation_result != "" && g_dh.show_status)
        {
            pos := g_dh.get_gui_pos()
            handle_width := 30
            display_name := get_service_display_with_status()

            ; 重新显示tooltip（不带[↵]）
            show_tooltip_and_update_handle('[' display_name ']: ' g_eb.translation_result, Integer(pos.x + handle_width), Integer(pos.y))
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
            pos := g_dh.get_gui_pos()
            handle_width := 30
            display_name := get_service_display_with_status()

            ; 重新显示tooltip（不带[↵]）
            show_tooltip_and_update_handle('[' display_name ']: ' g_eb.translation_result, Integer(pos.x + handle_width), Integer(pos.y))
        }
    }

    ; logger.info(wParam, lParam, num2utf16(wParam))  ; 性能优化：移除热路径日志
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

    ; 获取手柄的实际屏幕位置（从GUI获取实时位置）
    get_gui_pos()
    {
        local x, y
        this.ui.gui.GetPos(&x, &y)
        return {x: x, y: y}
    }

    get_pos()
    {
        return {x: this.x, y: this.y}
    }

    ; 重新创建 Direct2D 资源（用于处理设备丢失错误）
    recreate_resources()
    {
        ; 重新创建 Direct2D 窗口（保持原有尺寸）
        this.ui := Direct2DRender(0, 0, 30, 34,,, false)

        ; 如果窗口正在显示，重新显示
        if (this.show_status)
        {
            this.ui.gui.show('x' this.x ' y' this.y)
        }
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

            ; 检查 EndDraw 返回值，处理设备丢失错误
            hr := ui.EndDraw()
            if (hr = 0x8899000C)  ; D2DERR_RECREATE_TARGET
            {
                this.recreate_resources()
            }
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

    ; 重新创建 Direct2D 资源（用于处理设备丢失错误）
    recreate_resources()
    {
        ; 获取当前位置和尺寸
        this.ui.gui.GetPos(&x, &y, &w, &h)

        ; 重新创建 Direct2D 窗口
        this.ui := Direct2DRender(x, y, w, h,,, true)

        ; 标记需要重绘
        this.show_status := false
    }

    ; 静态回调方法
    static on_change_stub(name, text)
    {
        global g_eb
        if g_eb
            g_eb.on_change(name, text)
    }

    ; 【新方案】插入光标字符到文本中（使用 ▌ 作为光标）
    insert_cursor_char(text, insert_pos, cursor_char := "▌")
    {
        text_len := StrLen(text)

        ; 特殊情况：光标在末尾 (insert_pos = 0)
        if (insert_pos <= 0)
            return text . cursor_char

        ; 特殊情况：光标在开头 (insert_pos >= text_len)
        if (insert_pos >= text_len)
            return cursor_char . text

        ; 正常情况：光标在中间
        ; insert_pos 是距离末尾的距离，转换为从开头的位置
        cursor_index := text_len - insert_pos
        part1 := SubStr(text, 1, cursor_index)
        part2 := SubStr(text, cursor_index + 1)

        return part1 . cursor_char . part2
    }

    ; 获取显示文本

    ; 显示翻译中提示（默认模式触发翻译时）
    show_translating_tooltip()
    {
        global g_dh
        ; 获取手柄位置（tooltip在手柄右侧，同一行）
        pos := g_dh.get_gui_pos()
        handle_width := 30
        display_name := get_service_display_with_status()

        ; 显示 [✈] 提示
        show_tooltip_and_update_handle('[' display_name ']: [✈]', Integer(pos.x + handle_width), Integer(pos.y))
    }

    on_change(cd ,text)
    {
        global g_is_translating, g_dh, g_is_realtime_mode, g_translation_completed, g_cancel_translation, g_current_api, g_is_info_only

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

        ; logger.info(cd ,text)  ; 性能优化：移除频繁日志
        ; logger.info()  ; 性能优化：移除空日志调用
        if(this.show_status && cd = g_current_api && g_dh.show_status)
        {
            this.translation_result := text

            ; 获取手柄位置（tooltip在手柄右侧，同一行）
            pos := g_dh.get_gui_pos()
            handle_width := 30
            display_name := get_service_display_with_status()

            ; 如果翻译结果为空，只显示服务名
            if (text = "")
            {
                show_tooltip_and_update_handle('[' display_name ']', Integer(pos.x + handle_width), Integer(pos.y))
            }
            else
            {
                tooltip_text := '[' display_name ']: ' text

                ; 默认模式 + 翻译完成 + 非信息模式：添加[↵]
                if (!g_is_realtime_mode && g_translation_completed && !g_is_info_only)
                {
                    tooltip_text .= '[↵]'
                }

                show_tooltip_and_update_handle(tooltip_text, Integer(pos.x + handle_width), Integer(pos.y))
            }
        }
    }
    show(x := 0, y := 0)
    {
        this.ui.gui.show('x' x ' y' y)
        this.show_status := true

        ; 【方案A：光标常亮】不使用闪烁定时器

        this.draw()  ; 立即绘制，避免白框
    }
    hide()
    {
        ; 隐藏窗口
        this.ui.gui.hide()
        this.show_status := false

        ; 【方案A：光标常亮】不需要停止闪烁定时器

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

        global g_ui_font_family, g_ui_font_input_size, MAX_INPUT_WIDTH

        try
        {
            ; 统一渲染：光标始终存在，直接测量带光标的完整文本
            ; 1. 插入光标字符
            text_with_cursor := this.insert_cursor_char(this.text, this.insert_pos, "▌")
            display_text := text_with_cursor

            ; 2. 测量带光标的完整文本尺寸（一次性获取宽度和高度）
            wh := this.ui.GetTextWidthHeight(display_text, g_ui_font_input_size, g_ui_font_family)
            draw_width := wh.width
            draw_height := wh.height

            ; 3. 应用宽度限制
            if (draw_width > MAX_INPUT_WIDTH)
                draw_width := MAX_INPUT_WIDTH

            if(ui.BeginDraw())
            {
                ; 4. 绘制背景
                ui.FillRoundedRectangle(0, 0, draw_width, draw_height, 5, 5, 0xcc1E1E1E)

                ; 5. 统一绘制文本（总是传递完整尺寸参数）
                if (wh.width > MAX_INPUT_WIDTH)
                {
                    ui.DrawText(display_text, 0, 0, g_ui_font_input_size, 0xFFC9E47E, g_ui_font_family, "w" . draw_width . " h" . draw_height)
                }
                else
                {
                    ui.DrawText(display_text, 0, 0, g_ui_font_input_size, 0xFFC9E47E, g_ui_font_family, "h" . draw_height)
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

        global g_current_api, g_translators, g_config, g_dh
        global g_ui_font_family, g_ui_font_input_size
        ui := this.ui
        ui.gui.GetPos(&x, &y, &w, &h)
        ; logger.info(x, y, w, h)  ; 性能优化：移除绘制函数中的日志

        ; 标记开始绘制
        this.is_drawing := true

        try
        {
            ; 拖拽时简化绘制，不执行复杂操作
            if (g_dh.is_dragging)
            {
                ; 统一渲染：光标始终存在，直接测量带光标的完整文本
                ; 1. 插入光标字符
                text_with_cursor := this.insert_cursor_char(this.text, this.insert_pos, "▌")
                display_text := text_with_cursor

                ; 2. 测量带光标的完整文本尺寸
                wh := this.ui.GetTextWidthHeight(display_text, g_ui_font_input_size, g_ui_font_family)
                draw_width := wh.width
                draw_height := wh.height

                ; 3. 应用宽度限制
                if (draw_width > MAX_INPUT_WIDTH)
                    draw_width := MAX_INPUT_WIDTH

                if(ui.BeginDraw())
                {
                    ; 4. 绘制背景
                    ui.FillRoundedRectangle(0, 0, draw_width, draw_height, 5, 5, 0xcc1E1E1E)

                    ; 5. 统一绘制文本
                    if (wh.width > MAX_INPUT_WIDTH)
                    {
                        ui.DrawText(display_text, 0, 0, g_ui_font_input_size, 0xFFC9E47E, g_ui_font_family, "w" . draw_width . " h" . draw_height)
                    }
                    else
                    {
                        ui.DrawText(display_text, 0, 0, g_ui_font_input_size, 0xFFC9E47E, g_ui_font_family, "h" . draw_height)
                    }

                    ; 检查 EndDraw 返回值，处理设备丢失错误
                    hr := ui.EndDraw()
                    if (hr = 0x8899000C)  ; D2DERR_RECREATE_TARGET
                    {
                        this.recreate_resources()
                    }
                }
                return  ; 拖拽时直接返回，不执行后续的翻译等复杂操作
            }

            ; 只在输入为空时显示服务名 Tooltip（避免频繁更新）
            if (this.text = "")
            {
                this.translation_result := ""
                ; 获取手柄位置（tooltip在手柄右侧，同一行）
                pos := g_dh.get_gui_pos()
                handle_width := 30
                display_name := get_service_display_with_status()
                btt('[' display_name ']', Integer(pos.x + handle_width), Integer(pos.y),,OwnzztooltipStyle1,{Transparent:180,DistanceBetweenMouseXAndToolTip:-100,DistanceBetweenMouseYAndToolTip:-20})
            }

            ; 统一渲染：光标始终存在，直接测量带光标的完整文本
            ; 1. 插入光标字符
            text_with_cursor := this.insert_cursor_char(this.text, this.insert_pos, "▌")
            display_text := text_with_cursor

            ; 2. 测量带光标的完整文本尺寸
            wh := this.ui.GetTextWidthHeight(display_text, g_ui_font_input_size, g_ui_font_family)
            draw_width := wh.width
            draw_height := wh.height

            ; 3. 应用宽度限制
            if (draw_width > MAX_INPUT_WIDTH)
                draw_width := MAX_INPUT_WIDTH

            ; 4. 使用限制后的宽度移动窗口
            this.move(x, y, draw_width + 100, draw_height + 100)

            if(ui.BeginDraw())
            {
                ; 5. 绘制背景
                ui.FillRoundedRectangle(0, 0, draw_width, draw_height, 5, 5, 0xcc1E1E1E)

                ; 6. 统一绘制文本（总是传递完整尺寸参数）
                if (wh.width > MAX_INPUT_WIDTH)
                {
                    ui.DrawText(display_text, 0, 0, g_ui_font_input_size, 0xFFC9E47E, g_ui_font_family, "w" . draw_width . " h" . draw_height)
                }
                else
                {
                    ui.DrawText(display_text, 0, 0, g_ui_font_input_size, 0xFFC9E47E, g_ui_font_family, "h" . draw_height)
                }

                ; 检查 EndDraw 返回值，处理设备丢失错误
                hr := ui.EndDraw()
                if (hr = 0x8899000C)  ; D2DERR_RECREATE_TARGET
                {
                    this.recreate_resources()
                }
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
        ; logger.info(char)  ; 性能优化：移除热路径日志
        ; logger.err(this.text)  ; 性能优化：移除热路径日志
        local left_txt := SubStr(this.text, 1, StrLen(this.text) - this.insert_pos)
        local right_txt := SubStr(this.text, -this.insert_pos)
        ; logger.err(left_txt, right_txt)  ; 性能优化：移除热路径日志
        if(char == '`b')
        {
            this.text := SubStr(left_txt, 1, -1) right_txt
        }
        else
        {
            this.text := left_txt char right_txt
        }
        ; logger.err(this.text, this.insert_pos)  ; 性能优化：移除热路径日志
    }
    set_text(text)
    {
        this.text := text
        this.insert_pos := 0
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
    ; 删除光标后的字符（Del键）
    delete()
    {
        local left_txt := SubStr(this.text, 1, StrLen(this.text) - this.insert_pos)
        local right_txt := SubStr(this.text, -this.insert_pos)
        ; 如果右边有字符，删除第一个字符
        if (StrLen(right_txt) > 0)
        {
            right_txt := SubStr(right_txt, 2)
            this.text := left_txt . right_txt
            ; 调整 insert_pos 以保持光标相对于文本开头的位置
            if (this.insert_pos > 0)
                this.insert_pos -= 1
        }
        this.draw(0, false)  ; 只重绘光标位置，不触发翻译
    }
    up()
    {
        ; 【新增】向上移动光标（到上一行的相同列位置）
        global MAX_INPUT_WIDTH, g_ui_font_input_size, g_ui_font_family

        ; 只在多行文本时支持上下移动
        text_len := StrLen(this.text)
        if (text_len = 0)
            return

        ; 测量总宽度
        display_text := this.text
        wh := this.ui.GetTextWidthHeight(display_text, g_ui_font_input_size, g_ui_font_family)

        ; 判断是否需要多行处理：自动换行 OR 手动回车
        has_newline := InStr(this.text, "`n") || InStr(this.text, "`r")
        needs_multiline := (wh.width > MAX_INPUT_WIDTH) || has_newline

        if (!needs_multiline)
            return  ; 单行文本，不处理

        ; 【重要】获取单行高度
        single_line_wh := this.ui.GetTextWidthHeight("A", g_ui_font_input_size, g_ui_font_family)
        single_line_height := single_line_wh.height

        ; 构建行结构：每一行的起始字符索引（1-based）
        lines := []  ; [{start: 1, chars_before: 0}, {start: 10, chars_before: 9}, ...]

        current_line_width := 0
        current_line_start := 1  ; 当前行起始字符位置（1-based）

        for char_index, char in StrSplit(this.text)
        {
            ; 【修复】处理回车换行符（避免 \r\n 被处理成两次换行）
            if (char = "`r")
            {
                ; 检查下一个字符是否是 `\n`，如果是则跳过 `\r`
                next_char := SubStr(this.text, char_index + 1, 1)
                if (next_char = "`n")
                {
                    ; 遇到 `\r\n`，记录换行并跳过 `\r`
                    lines.Push({start: current_line_start, chars_before: current_line_start - 1})
                    current_line_start := char_index + 1  ; 注意：+1 是跳过 `\r`，`\n` 会再处理
                    current_line_width := 0
                    continue
                }

                ; 单独的 `\r`（Mac 风格），正常处理换行
                lines.Push({start: current_line_start, chars_before: current_line_start - 1})
                current_line_start := char_index + 1
                current_line_width := 0
                continue
            }

            if (char = "`n")
            {
                ; 【修复】处理换行符
                lines.Push({start: current_line_start, chars_before: current_line_start - 1})
                current_line_start := char_index + 1
                current_line_width := 0
                continue
            }

            display_char := char
            char_wh := this.ui.GetTextWidthHeight(display_char, g_ui_font_input_size, g_ui_font_family)
            char_width := char_wh.width

            ; 如果加上这个字符会超过宽度，换行
            if (current_line_width + char_width > MAX_INPUT_WIDTH && current_line_width > 0)
            {
                ; 保存上一行的信息
                lines.Push({start: current_line_start, chars_before: current_line_start - 1})

                ; 开始新行
                current_line_start := char_index
                current_line_width := 0
            }

            current_line_width += char_width
        }

        ; 保存最后一行
        lines.Push({start: current_line_start, chars_before: current_line_start - 1})

        ; 找到当前光标所在行
        cursor_from_end := this.insert_pos
        cursor_abs_pos := text_len - cursor_from_end

        current_line_index := 1  ; 默认第一行
        for line_index, line_info in lines
        {
            if (line_info.start <= cursor_abs_pos)
            {
                current_line_index := line_index
            }
            else
            {
                break
            }
        }

        ; 边界检查：如果行号无效，不处理
        if (current_line_index < 1 || current_line_index > lines.Length)
            return

        ; 如果已经在第一行，不能向上移动
        if (current_line_index <= 1)
            return

        ; 计算当前光标在当前行中的列位置（从行首开始的字符数）
        current_line_info := lines[current_line_index]
        chars_before_cursor_in_line := cursor_abs_pos - current_line_info.chars_before - 1

        ; 移动到上一行的相同列位置
        target_line_index := current_line_index - 1
        target_line_info := lines[target_line_index]

        ; 找到上一行的末尾位置
        if (target_line_index < lines.Length)
        {
            next_line_start := lines[target_line_index + 1].start
            target_line_length := next_line_start - target_line_info.start - 1
        }
        else
        {
            target_line_length := text_len - target_line_info.chars_before - 1
        }

        ; 如果上一行较短，移到上一行末尾
        if (chars_before_cursor_in_line > target_line_length)
        {
            chars_before_cursor_in_line := target_line_length
        }

        ; 计算新的 insert_pos
        new_cursor_abs_pos := target_line_info.start + chars_before_cursor_in_line
        this.insert_pos := text_len - new_cursor_abs_pos

        this.draw(0, false)
    }
    down()
    {
        ; 【新增】向下移动光标（到下一行的相同列位置）
        global MAX_INPUT_WIDTH, g_ui_font_input_size, g_ui_font_family

        ; 只在多行文本时支持上下移动
        text_len := StrLen(this.text)
        if (text_len = 0)
            return

        ; 测量总宽度
        display_text := this.text
        wh := this.ui.GetTextWidthHeight(display_text, g_ui_font_input_size, g_ui_font_family)

        ; 判断是否需要多行处理：自动换行 OR 手动回车
        has_newline := InStr(this.text, "`n") || InStr(this.text, "`r")
        needs_multiline := (wh.width > MAX_INPUT_WIDTH) || has_newline

        if (!needs_multiline)
            return  ; 单行文本，不处理

        ; 【重要】获取单行高度
        single_line_wh := this.ui.GetTextWidthHeight("A", g_ui_font_input_size, g_ui_font_family)
        single_line_height := single_line_wh.height

        ; 构建行结构：每一行的起始字符索引（1-based）
        lines := []  ; [{start: 1, chars_before: 0}, {start: 10, chars_before: 9}, ...]

        current_line_width := 0
        current_line_start := 1  ; 当前行起始字符位置（1-based）

        for char_index, char in StrSplit(this.text)
        {
            ; 【修复】处理回车换行符（避免 \r\n 被处理成两次换行）
            if (char = "`r")
            {
                ; 检查下一个字符是否是 `\n`，如果是则跳过 `\r`
                next_char := SubStr(this.text, char_index + 1, 1)
                if (next_char = "`n")
                {
                    ; 遇到 `\r\n`，记录换行并跳过 `\r`
                    lines.Push({start: current_line_start, chars_before: current_line_start - 1})
                    current_line_start := char_index + 1  ; 注意：+1 是跳过 `\r`，`\n` 会再处理
                    current_line_width := 0
                    continue
                }

                ; 单独的 `\r`（Mac 风格），正常处理换行
                lines.Push({start: current_line_start, chars_before: current_line_start - 1})
                current_line_start := char_index + 1
                current_line_width := 0
                continue
            }

            if (char = "`n")
            {
                ; 【修复】处理换行符
                lines.Push({start: current_line_start, chars_before: current_line_start - 1})
                current_line_start := char_index + 1
                current_line_width := 0
                continue
            }

            display_char := char
            char_wh := this.ui.GetTextWidthHeight(display_char, g_ui_font_input_size, g_ui_font_family)
            char_width := char_wh.width

            ; 如果加上这个字符会超过宽度，换行
            if (current_line_width + char_width > MAX_INPUT_WIDTH && current_line_width > 0)
            {
                ; 保存上一行的信息
                lines.Push({start: current_line_start, chars_before: current_line_start - 1})

                ; 开始新行
                current_line_start := char_index
                current_line_width := 0
            }

            current_line_width += char_width
        }

        ; 保存最后一行
        lines.Push({start: current_line_start, chars_before: current_line_start - 1})

        ; 找到当前光标所在行
        cursor_from_end := this.insert_pos
        cursor_abs_pos := text_len - cursor_from_end

        current_line_index := 1  ; 默认第一行
        for line_index, line_info in lines
        {
            if (line_info.start <= cursor_abs_pos)
            {
                current_line_index := line_index
            }
            else
            {
                break
            }
        }

        ; 边界检查：如果行号无效，不处理
        if (current_line_index < 1 || current_line_index > lines.Length)
            return

        ; 如果已经在最后一行，不能向下移动
        if (current_line_index >= lines.Length)
            return

        ; 计算当前光标在当前行中的列位置（从行首开始的字符数）
        current_line_info := lines[current_line_index]
        chars_before_cursor_in_line := cursor_abs_pos - current_line_info.chars_before - 1

        ; 移动到下一行的相同列位置
        target_line_index := current_line_index + 1
        target_line_info := lines[target_line_index]

        ; 找到下一行的末尾位置
        if (target_line_index < lines.Length)
        {
            next_line_start := lines[target_line_index + 1].start
            target_line_length := next_line_start - target_line_info.start - 1
        }
        else
        {
            target_line_length := text_len - target_line_info.chars_before - 1
        }

        ; 如果下一行较短，移到下一行末尾
        if (chars_before_cursor_in_line > target_line_length)
        {
            chars_before_cursor_in_line := target_line_length
        }

        ; 计算新的 insert_pos
        new_cursor_abs_pos := target_line_info.start + chars_before_cursor_in_line
        this.insert_pos := text_len - new_cursor_abs_pos

        this.draw(0, false)
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
        ; logger.info(num2utf16(char))  ; 性能优化：移除热路径日志
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
