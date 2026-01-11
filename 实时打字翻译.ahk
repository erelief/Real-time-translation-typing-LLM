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
;OnMessage(0x0101, ON_WM_KEYUP)    ; 0x0101 是 WM_KEYUP

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
    ; A_Clipboard := old
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
    global g_window_hwnd, g_dh
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
    global g_manual_positions, g_last_translation

    ; 清除上一次的翻译结果
    g_last_translation := ""

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

    ; 显示拖拽手柄（在 x 位置）
    g_dh.show(x, y)

    ; 显示输入框（在手柄右侧 30px）
    g_eb.show(x + 30, y)

    ; 显示 Tooltip（在上方 45px）
    display_name := get_current_service_display_name()
    btt('[' display_name ']', Integer(x), Integer(y) - 45,,OwnzztooltipStyle1,{Transparent:180,DistanceBetweenMouseXAndToolTip:-100,DistanceBetweenMouseYAndToolTip:-20})
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

    ; 获取手柄当前位置并移动输入框
    local x, y
    g_dh.ui.gui.GetPos(&x, &y)
    g_eb.move(x + 30, y)

    ; 更新 Tooltip 位置和内容（在手柄上方 45px）
    display_name := get_current_service_display_name()
    if (g_last_translation != "")
    {
        btt(display_name ':' g_last_translation, Integer(x), Integer(y) - 45,,OwnzztooltipStyle1,{Transparent:180,DistanceBetweenMouseXAndToolTip:-100,DistanceBetweenMouseYAndToolTip:-20})
    }
    else
    {
        btt('[' display_name ']', Integer(x), Integer(y) - 45,,OwnzztooltipStyle1,{Transparent:180,DistanceBetweenMouseXAndToolTip:-100,DistanceBetweenMouseYAndToolTip:-20})
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
    global g_dh

    ; 只处理手柄窗口的消息
    if (hwnd != g_dh.ui.Hwnd)
        return

    logger.info(">>> 进入拖拽模式，启动定时器")
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

    ; 保存位置
    local x, y
    g_dh.ui.gui.GetPos(&x, &y)
    process_name := WinGetProcessName("ahk_id " g_window_hwnd)
    g_manual_positions[process_name] := {x: x, y: y}

    ; 更新全局坐标
    g_cursor_x := x
    g_cursor_y := y

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
        this.ui := Direct2DRender(0, 0, 30, 35,,, false)  ; 30x35，clickThrough=false
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
            ; 绘制半透明背景
            ui.FillRoundedRectangle(0, 0, 30, 35, 4, 4, 0xcc2A2A2A)
            ui.DrawRoundedRectangle(0, 0, 30, 35, 4, 4, 0xFF40C1FF, 1)

            ; 绘制 ≡ 符号（居中）
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
        logger.info(cd ,text)
        logger.info()
        if(this.show_status && cd = g_current_api)
        {
            this.fanyi_result := text
            global g_last_translation
            g_last_translation := text  ; 保存翻译结果
            this.ui.gui.GetPos(&x, &y, &w, &h)
            display_name := get_current_service_display_name()
            btt(display_name ':' text, Integer(x), Integer(y) - 45,,OwnzztooltipStyle1,{Transparent:180,DistanceBetweenMouseXAndToolTip:-100,DistanceBetweenMouseYAndToolTip:-20})
        }
    }
    show(x := 0, y := 0)
    {
        this.ui.gui.show('x' x ' y' y)
        this.show_status := true
        this.draw()  ; 立即绘制，避免白框
    }
    hide()
    {
        global g_is_ime_char
        this.clear()
        this.ui.gui.hide()
        g_is_ime_char := false
        this.show_status := false
        OwnzztooltipEnd()
    }
    move(x, y, w := 0, h := 0)
    {
        this.ui.SetPosition(x, y, w, h)
    }
    draw(flag := 0)
    {
        global g_current_api, g_translators, g_config
        ui := this.ui
        ui.gui.GetPos(&x, &y, &w, &h)
        logger.info(x, y, w, h)
        ;计算文字的大小
        wh := this.ui.GetTextWidthHeight(this.text, 30)
        last_txt_wh := this.ui.GetTextWidthHeight(SubStr(this.text, -this.insert_pos), 30)
        logger.info(wh)
        this.move(x, y, wh.width + 100, wh.height + 100)
        if(ui.BeginDraw())
        {
            ui.FillRoundedRectangle(0, 0, wh.width, wh.height, 5, 5, 0xcc1E1E1E)
            ui.DrawRoundedRectangle(0, 0, wh.width, wh.height, 5, 5, 0xffff0000, 1)
            ui.DrawText(this.text, 0, 0, 30, 0xFFC9E47E)
            ui.DrawLine(wh.width - last_txt_wh.width, 0, wh.width - last_txt_wh.width, wh.height, 0xAA00FF00)
            logger.err(this.text)
            ui.EndDraw()
        }

        ; 使用LLM翻译
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

    ; 触发翻译
    trigger_translate()
    {
        global g_translators, g_current_api, g_target_lang
        input_text := this.text
        if (input_text != "" && g_translators.Has(g_current_api))
        {
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
            ;this.text := SubStr(this.text, 1, -1)
            this.text := SubStr(left_txt, 1, -1) right_txt
        }
        else
        {
            ;this.text .= char
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
        this.draw()
    }
    right()
    {
        if(this.insert_pos > 0)
            this.insert_pos -= 1
        this.draw()
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
