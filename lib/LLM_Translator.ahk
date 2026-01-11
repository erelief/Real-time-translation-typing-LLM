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
    translate(text, target_lang := "en")
    {
        try
        {
            ; 构建请求URL（确保格式正确）
            url := this.base_url
            if !InStr(url, "/chat/completions")
                url := RTrim(url, "/") "/chat/completions"

            ; 构建提示词
            prompt := this.build_prompt(text, target_lang)

            ; 构建请求头
            headers := Map(
                "Authorization", "Bearer " this.api_key,
                "Content-Type", "application/json"
            )

            ; 构建请求体（OpenAI标准格式）
            body := Map(
                "model", this.model,
                "messages", [
                    Map("role", "user", "content", prompt)
                ],
                "temperature", this.temperature,
                "max_tokens", this.max_tokens,
                "stream", false
            )

            ; 发送HTTP请求
            whr := ComObject("WinHttp.WinHttpRequest.5.1")
            whr.Open("POST", url, true)
            for key, value in headers
                whr.SetRequestHeader(key, value)
            whr.Send(JSON.Stringify(body))
            whr.WaitForResponse(5)  ; 5秒超时（缩短阻塞时间）

            ; 记录响应状态
            status := whr.Status
            logger.err("[" this.name "] API响应状态: " status)

            ; 解析响应
            response := whr.ResponseText
            logger.err("[" this.name "] API响应内容: " response)

            result := JSON.Parse(response)
            translated := result["choices"][1]["message"]["content"]

            ; 触发回调
            if this.callback
                this.callback.Call(this.name, translated)

            return translated
        }
        catch as e
        {
            logger.err("[" this.name "] 翻译失败: " e.Message)
            logger.err("[" this.name "] 错误详情: " e.What)
            if this.callback
                this.callback.Call(this.name, "[错误: " e.Message "]")
            return ""
        }
    }

    ; 构建翻译提示词
    build_prompt(text, target_lang)
    {
        return Format("Translate the following text to {1}. Only output the translated result without any explanation:`n`n{2}", target_lang, text)
    }

    ; 设置回调函数
    set_callback(cb)
    {
        this.callback := cb
    }
}
