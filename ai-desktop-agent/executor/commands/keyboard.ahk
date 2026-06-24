; executor/commands/keyboard.ahk
; 键盘操作命令

#Requires AutoHotkey v2.0

; 输入文字
Keyboard_Type(params) {
    text := params.Has("text") ? params["text"] : ""

    if !text
        return '{"success": false, "error": "no text"}'

    SendText(text)
    return '{"success": true, "action": "type_text", "length": ' StrLen(text) '}'
}

; 发送快捷键
Keyboard_Press(params) {
    keys := params.Has("keys") ? params["keys"] : ""

    if !keys
        return '{"success": false, "error": "no keys"}'

    Send(keys)
    Sleep(100)

    return '{"success": true, "action": "press_keys", "keys": "' keys '"}'
}

; 获取剪贴板内容
Keyboard_ClipboardGet() {
    text := A_Clipboard
    return '{"success": true, "content": "' EscapeJsonContent(text) '"}'
}

; 设置剪贴板内容
Keyboard_ClipboardSet(params) {
    text := params.Has("text") ? params["text"] : ""
    A_Clipboard := text
    return '{"success": true, "action": "clipboard_set"}'
}

; JSON 转义辅助
EscapeJsonContent(str) {
    str := StrReplace(str, '\', '\\')
    str := StrReplace(str, '"', '\"')
    str := StrReplace(str, '`n', '\n')
    str := StrReplace(str, '`r', '\r')
    str := StrReplace(str, '`t', '\t')
    return str
}
