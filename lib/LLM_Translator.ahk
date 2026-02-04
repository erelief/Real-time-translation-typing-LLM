#Requires AutoHotkey v2.0

; ========== 通用OpenAI兼容LLM翻译类 ==========
; 支持所有提供OpenAI兼容API的服务
class OpenAI_Compat_LLM
{
    __New(name, config, callback)
    {
        this.name := name                ; 配置名称（如"service1"）
        this.api_key := config["api_key"]   ; API密钥
        this.base_url := config["base_url"] ; API地址（必须包含/v1路径）
        this.model := config["model"]       ; 模型名称
        this.callback := callback        ; 翻译完成回调函数
        this.debounce_delay := config.Has("debounce_delay") ? config["debounce_delay"] : 500
        this.temperature := config.Has("temperature") ? config["temperature"] : 0.3
        this.max_tokens := config.Has("max_tokens") ? config["max_tokens"] : 2000
    }

    ; 翻译文本
    translate(text, target_lang := "en", persona := "")
    {
        try
        {
            ; 构建请求URL（确保格式正确）
            url := this.base_url
            if !InStr(url, "/chat/completions")
                url := RTrim(url, "/") "/chat/completions"

            ; 构建提示词
            prompt := this.build_prompt(text, target_lang, persona)

            ; 构建请求头
            headers := Map(
                "Authorization", "Bearer " this.api_key,
                "Content-Type", "application/json"
            )

            ; 构建请求体（OpenAI标准格式）
            ; 注意：使用字符串拼接确保布尔值正确序列化为true/false
            messages_json := JSON.Stringify([
                Map("role", "user", "content", prompt)
            ])

            ; 手动构建JSON字符串，确保stream是false而不是0
            body_json := '{"model":"' . this.model . '","messages":' . messages_json . ',"temperature":' . this.temperature . ',"max_tokens":' . this.max_tokens . ',"stream":false}'

            ; 发送HTTP请求
            whr := ComObject("WinHttp.WinHttpRequest.5.1")
            whr.Open("POST", url, true)
            for key, value in headers
                whr.SetRequestHeader(key, value)
            whr.Send(body_json)
            whr.WaitForResponse(5)  ; 5秒超时（缩短阻塞时间）

            ; 记录响应状态
            status := whr.Status

            ; 解析响应（使用 ADODB.Stream 强制 UTF-8 解码，避免乱码）
            ; 方法：获取 ResponseBody 的字节数组，通过 Stream 转换为 UTF-8 字符串
            stream := ComObject("ADODB.Stream")
            stream.Type := 1  ; adTypeBinary (二进制模式)
            stream.Open()
            stream.Write(whr.ResponseBody)
            stream.Position := 0
            stream.Type := 2  ; adTypeText (文本模式)
            stream.Charset := "utf-8"
            response := stream.ReadText()
            stream.Close()

            ; 检查HTTP状态码
            if (status != 200)
            {
                error_msg := "API错误 (HTTP " status "): " response
                logger.err("[" this.name "] " error_msg)
                if this.callback
                    this.callback.Call(this.name, "[错误: " error_msg "]")
                return ""
            }

            result := JSON.Parse(response)

            ; 安全地访问JSON字段
            if (!result.Has("choices"))
            {
                error_msg := "API返回格式错误：缺少choices字段"
                logger.err("[" this.name "] " error_msg)
                if this.callback
                    this.callback.Call(this.name, "[错误: " error_msg "]")
                return ""
            }

            choices := result["choices"]
            if (choices.Length == 0)
            {
                error_msg := "API返回格式错误：choices为空"
                logger.err("[" this.name "] " error_msg)
                if this.callback
                    this.callback.Call(this.name, "[错误: " error_msg "]")
                return ""
            }

            choice := choices[1]
            if (!choice.Has("message") || !choice["message"].Has("content"))
            {
                error_msg := "API返回格式错误：缺少message.content字段"
                logger.err("[" this.name "] " error_msg)
                if this.callback
                    this.callback.Call(this.name, "[错误: " error_msg "]")
                return ""
            }

            translated := choice["message"]["content"]

            ; 触发回调
            if this.callback
                this.callback.Call(this.name, translated)

            return translated
        }
        catch as e
        {
            error_msg := "翻译失败: " e.Message
            logger.err("[" this.name "] " error_msg)
            logger.err("[" this.name "] 错误详情: " e.What)
            if this.callback
                this.callback.Call(this.name, "[错误: " error_msg "]")
            return ""
        }
    }

    ; 读取用户字典文件，返回指定目标语言的词条
    get_user_dictionary_content(target_lang)
    {
        local dict_file := A_ScriptDir "\dictionary.md"

        ; 检查文件是否存在
        if !FileExist(dict_file)
        {
            ; 文件不存在，返回空字符串（不报错）
            return ""
        }

        ; 读取文件
        local file_lines := []
        local line_count := 0
        local entries := []

        try
        {
            file_lines := StrSplit(FileRead(dict_file, "UTF-8"), "`n")
        }
        catch as e
        {
            logger.err("读取字典文件失败: " e.Message)
            return ""
        }

        ; 查找目标语言对应的词条（渐进式披露）
        local in_target_section := false

        for line in file_lines
        {
            ; 跳过空行
            line := Trim(line)
            if (line = "")
                continue

            ; 检查是否为一级标题（# Language）
            if (SubStr(line, 1, 1) = "#")
            {
                ; 检查是否为一级标题（只有一个 #）
                local second_char := SubStr(line, 2, 1)
                if (second_char = " " || second_char = "")
                {
                    ; 这是一级标题
                    local section_lang := Trim(SubStr(line, 2))
                    if (section_lang = target_lang)
                    {
                        ; 找到目标语言标题，开始记录词条
                        in_target_section := true
                    }
                    else if (in_target_section)
                    {
                        ; 已经在目标语言段落中，遇到其他一级标题则停止
                        break
                    }
                    continue
                }
                ; 否则是二级标题（##），在目标段落中继续处理
            }

            ; 如果在目标语言段落中，解析词条
            if (in_target_section)
            {
                ; 跳过二级标题（## 分类）
                if (SubStr(line, 1, 2) = "##")
                    continue

                ; 解析格式：原文 translation（用空格或 Tab 分隔）
                ; 找到第一个空格或 Tab
                local separator_pos := RegExMatch(line, "[ 	]", &match)
                if (separator_pos > 0)
                {
                    local source_text := Trim(SubStr(line, 1, separator_pos))
                    local translation := Trim(SubStr(line, separator_pos + 1))

                    ; 确保译文不为空
                    if (translation != "")
                    {
                        entries.Push(source_text " → " translation)
                        line_count++
                    }
                }
            }
        }

        ; 如果没有有效词条，返回空字符串
        if (line_count = 0)
            return ""

        ; 格式化为字符串
        local dict_content := "用户自定义词典（" target_lang "）：`n"
        for entry in entries
        {
            dict_content .= "  - " entry "`n"
        }

        return dict_content
    }

    ; 构建翻译提示词
    build_prompt(text, target_lang, persona := "")
    {
        ; 如果有个性提示词，添加到翻译指令前面
        prompt := ""
        if (persona != "")
        {
            prompt .= persona . ". "
        }

        ; 附加用户字典内容（渐进式披露）
        local dict_content := this.get_user_dictionary_content(target_lang)
        if (dict_content != "")
        {
            prompt .= dict_content "`n"
            prompt .= "请优先参考上述词典进行翻译。如果词典中有匹配的词条，请使用词典中的翻译。`n`n"
        }

        prompt := "Translate the following text to " . target_lang . ". Only output the translated result without any explanation.`n`n"
        prompt .= "Punctuation Rule: Match the source text's ending punctuation style:`n"
        prompt .= "- If source ends with punctuation (。.！!？?，,、), add corresponding punctuation in " . target_lang . "`n"
        prompt .= "- If source has NO ending punctuation, do NOT add any punctuation and do NOT capitalize the first letter`n`n"
        prompt .= "Source text:`n" . text
        return prompt
    }

    ; 发送原始 prompt（不经过 build_prompt，用于自定义功能如 /lang 命令）
    send_raw_prompt(prompt)
    {
        try
        {
            ; 构建请求URL（确保格式正确）
            url := this.base_url
            if !InStr(url, "/chat/completions")
                url := RTrim(url, "/") "/chat/completions"

            ; 构建请求头
            headers := Map(
                "Authorization", "Bearer " this.api_key,
                "Content-Type", "application/json"
            )

            ; 构建请求体（OpenAI标准格式）
            ; 注意：使用字符串拼接确保布尔值正确序列化为true/false
            messages_json := JSON.Stringify([
                Map("role", "user", "content", prompt)
            ])

            ; 手动构建JSON字符串，确保stream是false而不是0
            body_json := '{"model":"' . this.model . '","messages":' . messages_json . ',"temperature":' . this.temperature . ',"max_tokens":' . this.max_tokens . ',"stream":false}'

            ; 发送HTTP请求
            whr := ComObject("WinHttp.WinHttpRequest.5.1")
            whr.Open("POST", url, true)
            for key, value in headers
                whr.SetRequestHeader(key, value)
            whr.Send(body_json)
            whr.WaitForResponse(5)  ; 5秒超时

            ; 记录响应状态
            status := whr.Status

            ; 解析响应（使用 ADODB.Stream 强制 UTF-8 解码，避免乱码）
            ; 方法：获取 ResponseBody 的字节数组，通过 Stream 转换为 UTF-8 字符串
            stream := ComObject("ADODB.Stream")
            stream.Type := 1  ; adTypeBinary (二进制模式)
            stream.Open()
            stream.Write(whr.ResponseBody)
            stream.Position := 0
            stream.Type := 2  ; adTypeText (文本模式)
            stream.Charset := "utf-8"
            response := stream.ReadText()
            stream.Close()

            ; 检查HTTP状态码
            if (status != 200)
            {
                error_msg := "API错误 (HTTP " status "): " response
                logger.err("[" this.name "] " error_msg)
                if this.callback
                    this.callback.Call(this.name, "[错误: " error_msg "]")
                return ""
            }

            result := JSON.Parse(response)

            ; 安全地访问JSON字段
            if (!result.Has("choices"))
            {
                error_msg := "API返回格式错误：缺少choices字段"
                logger.err("[" this.name "] " error_msg)
                if this.callback
                    this.callback.Call(this.name, "[错误: " error_msg "]")
                return ""
            }

            choices := result["choices"]
            if (choices.Length == 0)
            {
                error_msg := "API返回格式错误：choices为空"
                logger.err("[" this.name "] " error_msg)
                if this.callback
                    this.callback.Call(this.name, "[错误: " error_msg "]")
                return ""
            }

            choice := choices[1]
            if (!choice.Has("message") || !choice["message"].Has("content"))
            {
                error_msg := "API返回格式错误：缺少message.content字段"
                logger.err("[" this.name "] " error_msg)
                if this.callback
                    this.callback.Call(this.name, "[错误: " error_msg "]")
                return ""
            }

            translated := choice["message"]["content"]

            ; 触发回调
            if this.callback
                this.callback.Call(this.name, translated)

            return translated
        }
        catch as e
        {
            error_msg := "请求失败: " e.Message
            logger.err("[" this.name "] " error_msg)
            logger.err("[" this.name "] 错误详情: " e.What)
            if this.callback
                this.callback.Call(this.name, "[错误: " error_msg "]")
            return ""
        }
    }

    ; 设置回调函数
    set_callback(cb)
    {
        this.callback := cb
    }
}
