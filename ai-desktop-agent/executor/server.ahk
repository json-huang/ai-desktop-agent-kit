; AI Desktop Agent - AHK HTTP Server
; 接收 Python 端发来的操作指令并执行
; 需要 AutoHotkey v2

#Requires AutoHotkey v2.0
#SingleInstance Force
#Include "commands\mouse.ahk"
#Include "commands\keyboard.ahk"
#Include "commands\window.ahk"
#Include "commands\file.ahk"

; 配置
LISTEN_HOST := "127.0.0.1"
LISTEN_PORT := 18600

; 启动 HTTP 服务
Main() {
    global LISTEN_HOST, LISTEN_PORT

    ; 创建 TCP 监听
    try {
        server := SocketServer(LISTEN_HOST, LISTEN_PORT)
        OutputDebug("AHK HTTP Server 启动于 " LISTEN_HOST ":" LISTEN_PORT)

        ; 主循环
        loop {
            client := server.Accept()
            if client {
                HandleRequest(client)
            }
            Sleep(10)
        }
    } catch as e {
        MsgBox("服务启动失败: " e.Message)
    }
}

; 处理 HTTP 请求
HandleRequest(client) {
    try {
        ; 读取请求
        request := client.Receive()

        ; 解析 HTTP 请求
        method := ""
        path := ""
        body := ""

        lines := StrSplit(request, "`n")
        if lines.Length > 0 {
            firstLine := StrSplit(lines[1], " ")
            if firstLine.Length >= 2 {
                method := firstLine[1]
                path := firstLine[2]
            }
        }

        ; 提取 body (JSON)
        bodyStart := InStr(request, "`r`n`r`n")
        if bodyStart {
            body := SubStr(request, bodyStart + 4)
        }

        ; 路由处理
        response := ""

        if (path = "/execute" && method = "POST") {
            response := HandleExecute(body)
        } else if (path = "/health" && method = "GET") {
            response := JsonResponse(200, '{"status": "ok"}')
        } else if (path = "/ping") {
            response := JsonResponse(200, '{"pong": true}')
        } else {
            response := JsonResponse(404, '{"error": "not found"}')
        }

        ; 发送响应
        client.Send(response)
        client.Close()

    } catch as e {
        try {
            client.Send(JsonResponse(500, '{"error": "' e.Message '"}'))
            client.Close()
        }
    }
}

; 执行操作
HandleExecute(body) {
    try {
        ; 解析 JSON
        data := Jxon_Load(&body)
        action := data["action"]
        params := data.Has("params") ? data["params"] : Map()

        result := ""

        ; 分发到对应的命令处理
        switch action {
            case "click":
                result := Mouse_Click(params)
            case "double_click":
                result := Mouse_DoubleClick(params)
            case "right_click":
                result := Mouse_RightClick(params)
            case "drag":
                result := Mouse_Drag(params)
            case "scroll":
                result := Mouse_Scroll(params)
            case "type_text":
                result := Keyboard_Type(params)
            case "press_keys":
                result := Keyboard_Press(params)
            case "open_app":
                result := Window_Open(params)
            case "close_app":
                result := Window_Close(params)
            case "manage_window":
                result := Window_Manage(params)
            case "clipboard_get":
                result := Keyboard_ClipboardGet()
            case "clipboard_set":
                result := Keyboard_ClipboardSet(params)
            case "file_operation":
                result := File_Operate(params)
            case "run_command":
                result := RunCommand(params)
            case "wait":
                Sleep(params.Has("ms") ? params["ms"] : 500)
                result := '{"success": true}'
            case "screenshot":
                result := TakeScreenshot(params)
            default:
                result := '{"success": false, "error": "unknown action: ' action '"}'
        }

        return JsonResponse(200, result)

    } catch as e {
        return JsonResponse(500, '{"success": false, "error": "' e.Message '"}')
    }
}

; 运行系统命令
RunCommand(params) {
    cmd := params.Has("command") ? params["command"] : ""
    if !cmd {
        return '{"success": false, "error": "no command"}'
    }

    try {
        shell := ComObject("WScript.Shell")
        exec := shell.Exec("cmd /c " cmd)
        output := exec.StdOut.ReadAll()
        return '{"success": true, "output": "' EscapeJson(output) '"}'
    } catch as e {
        return '{"success": false, "error": "' EscapeJson(e.Message) '"}'
    }
}

; 截图
TakeScreenshot(params) {
    ; 需要用 Python 端处理，AHK 端返回成功
    return '{"success": true, "note": "use python for screenshot"}'
}

; JSON 响应
JsonResponse(statusCode, body) {
    headers := "Content-Type: application/json; charset=utf-8`r`n"
    return "HTTP/1.1 " statusCode " OK`r`n" headers "Content-Length: " StrLen(body) "`r`n`r`n" body
}

; JSON 转义
EscapeJson(str) {
    str := StrReplace(str, '\', '\\')
    str := StrReplace(str, '"', '\"')
    str := StrReplace(str, '`n', '\n')
    str := StrReplace(str, '`r', '\r')
    str := StrReplace(str, '`t', '\t')
    return str
}

; === 简易 JSON 解析 (Jxon) ===
; 来源: https://github.com/TheArkive/Jxon_v2
Jxon_Load(&src, args*) {
    static q := Chr(34)
    key := "", is_key := false
    stack := [tree := []]
    is_arr := Map(tree, 1)
    next := q . "{[01telefonTRUEFALSEnullNULL"

    pos := 0
    while (pos := RegExMatch(src, "(?(DEFINE)(?<json>[^{[01telefonTRUEFALSEnull]*(?:{(?&json)}|[(?&json)]|(?&string)|[01telefonTRUEFALSEnull])*(?:,(?&json))*)|(?<string>" q "(?:[^\\\\" q "]|\\\\.)*" q "))(*MARK:A)(?({DEFINE})(?C1)|{)|[)|""|-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?|true|false|null)(?C2)", &m, pos + 1)) {
        if (m.Mark = "A") {
            obj := Map()
            stack.Push(obj)
            is_arr[obj] := 0
            is_key := true
        } else if (m[0] = "[") {
            obj := []
            stack.Push(obj)
            is_arr[obj] := 1
        } else if (InStr("}]", m[0])) {
            val := stack.Pop()
            if (stack.Length) {
                parent := stack[stack.Length]
                if IsObject(parent) {
                    if is_arr[parent]
                        parent.Push(val)
                    else
                        parent[key] := val
                }
            }
        } else if (m[0] = q) {
            val := SubStr(m[0], 2, -1)
            val := StrReplace(val, "\\" , "\")
            val := StrReplace(val, "\n" , "`n")
            val := StrReplace(val, "\r" , "`r")
            val := StrReplace(val, "\t" , "`t")

            if is_key {
                key := val
                is_key := false
            } else {
                parent := stack[stack.Length]
                if is_arr[parent]
                    parent.Push(val)
                else
                    parent[key] := val
            }
        } else if (RegExMatch(m[0], "^-?\d")) {
            val := Number(m[0])
            parent := stack[stack.Length]
            if is_arr[parent]
                parent.Push(val)
            else
                parent[key] := val
        } else {
            val := (m[0] = "true") ? 1 : (m[0] = "false") ? 0 : ""
            parent := stack[stack.Length]
            if is_arr[parent]
                parent.Push(val)
            else
                parent[key] := val
        }

        if (m[0] = "," || m[0] = ":")
            is_key := (m[0] = ":")
    }

    return tree.Length ? tree[1] : tree
}

; === Socket Server ===
class SocketServer {
    __New(host, port) {
        this.sock := -1
        this._listen(host, port)
    }

    _listen(host, port) {
        ; 使用 TCP 监听
        this.sock := DllCall("ws2_32\socket", "int", 2, "int", 1, "int", 6, "ptr")

        addr := Buffer(16, 0)
        NumPut("ushort", 2, addr, 0)          ; AF_INET
        NumPut("ushort", DllCall("ws2_32\htons", "ushort", port), addr, 2)
        NumPut("uint", DllCall("ws2_32\inet_addr", "str", host), addr, 4)

        result := DllCall("ws2_32\bind", "ptr", this.sock, "ptr", addr, "int", 16, "int")
        if (result != 0)
            throw Error("bind failed: " DllCall("ws2_32\WSAGetLastError"))

        result := DllCall("ws2_32\listen", "ptr", this.sock, "int", 5, "int")
        if (result != 0)
            throw Error("listen failed: " DllCall("ws2_32\WSAGetLastError"))

        ; 设置非阻塞
        mode := Buffer(4, 0)
        NumPut("uint", 1, mode, 0)
        DllCall("ws2_32\ioctlsocket", "ptr", this.sock, "uint", 0x8004667E, "ptr", mode)
    }

    Accept() {
        client := DllCall("ws2_32\accept", "ptr", this.sock, "ptr", 0, "ptr", 0, "ptr")
        if (client > 0)
            return SocketClient(client)
        return 0
    }
}

class SocketClient {
    __New(sock) {
        this.sock := sock
    }

    Receive() {
        buf := Buffer(4096, 0)
        data := ""
        loop {
            len := DllCall("ws2_32\recv", "ptr", this.sock, "ptr", buf, "int", 4096, "int", 0, "int")
            if (len <= 0)
                break
            data .= StrGet(buf, len, "utf-8")
            if (len < 4096)
                break
        }
        return data
    }

    Send(data) {
        buf := Buffer(StrPut(data, "utf-8"), 0)
        StrPut(data, buf, "utf-8")
        DllCall("ws2_32\send", "ptr", this.sock, "ptr", buf, "int", buf.Size - 1, "int", 0, "int")
    }

    Close() {
        DllCall("ws2_32\closesocket", "ptr", this.sock)
    }
}

; === 初始化 ===
Main()
