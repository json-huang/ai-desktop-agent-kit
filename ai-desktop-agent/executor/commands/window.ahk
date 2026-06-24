; executor/commands/window.ahk
; 窗口管理命令

#Requires AutoHotkey v2.0

; 打开应用
Window_Open(params) {
    target := params.Has("target") ? params["target"] : ""

    if !target
        return '{"success": false, "error": "no target"}'

    try {
        Run(target)
        Sleep(1000)  ; 等待启动
        return '{"success": true, "action": "open_app", "target": "' target '"}'
    } catch as e {
        return '{"success": false, "error": "' EscapeJsonContent(e.Message) '"}'
    }
}

; 关闭应用
Window_Close(params) {
    target := params.Has("target") ? params["target"] : ""

    if !target
        return '{"success": false, "error": "no target"}'

    try {
        WinClose(target)
        return '{"success": true, "action": "close_app", "target": "' target '"}'
    } catch as e {
        return '{"success": false, "error": "' EscapeJsonContent(e.Message) '"}'
    }
}

; 窗口管理
Window_Manage(params) {
    action := params.Has("action") ? params["action"] : ""
    target := params.Has("target") ? params["target"] : ""

    if !action
        return '{"success": false, "error": "no action"}'

    try {
        switch action {
            case "maximize":
                WinMaximize(target)
            case "minimize":
                WinMinimize(target)
            case "restore":
                WinRestore(target)
            case "activate":
                WinActivate(target)
            case "close":
                WinClose(target)
            case "move":
                x := params.Has("x") ? params["x"] : 0
                y := params.Has("y") ? params["y"] : 0
                w := params.Has("w") ? params["w"] : 800
                h := params.Has("h") ? params["h"] : 600
                WinMove(x, y, w, h, target)
            case "resize":
                w := params.Has("w") ? params["w"] : 800
                h := params.Has("h") ? params["h"] : 600
                WinMove(, , w, h, target)
            default:
                return '{"success": false, "error": "unknown window action: ' action '"}'
        }

        return '{"success": true, "action": "manage_window", "operation": "' action '"}'
    } catch as e {
        return '{"success": false, "error": "' EscapeJsonContent(e.Message) '"}'
    }
}

; 列出窗口
Window_List() {
    windows := []
    for hwnd in WinGetList() {
        title := WinGetTitle(hwnd)
        if title {
            exe := WinGetProcessName(hwnd)
            windows.Push('{"title": "' EscapeJsonContent(title) '", "exe": "' exe '", "hwnd": ' hwnd '}')
        }
    }
    return '{"success": true, "windows": [' JoinStr(windows, ",") ']}'
}

; 字符串连接
JoinStr(arr, sep) {
    result := ""
    for i, val in arr {
        if (i > 1)
            result .= sep
        result .= val
    }
    return result
}
