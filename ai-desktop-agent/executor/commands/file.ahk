; executor/commands/file.ahk
; 文件操作命令

#Requires AutoHotkey v2.0

; 文件操作
File_Operate(params) {
    action := params.Has("action") ? params["action"] : ""
    src := params.Has("src") ? params["src"] : ""
    dst := params.Has("dst") ? params["dst"] : ""

    if !action
        return '{"success": false, "error": "no action"}'

    try {
        switch action {
            case "copy":
                if !src || !dst
                    return '{"success": false, "error": "need src and dst"}'
                FileCopy(src, dst, true)
                return '{"success": true, "action": "copy", "src": "' src '", "dst": "' dst '"}'

            case "move":
                if !src || !dst
                    return '{"success": false, "error": "need src and dst"}'
                FileMove(src, dst, true)
                return '{"success": true, "action": "move", "src": "' src '", "dst": "' dst '"}'

            case "delete":
                if !src
                    return '{"success": false, "error": "need src"}'
                FileDelete(src)
                return '{"success": true, "action": "delete", "src": "' src '"}'

            case "rename":
                if !src || !dst
                    return '{"success": false, "error": "need src and dst"}'
                FileMove(src, dst)
                return '{"success": true, "action": "rename", "src": "' src '", "dst": "' dst '"}'

            case "mkdir":
                if !src
                    return '{"success": false, "error": "need src"}'
                DirCreate(src)
                return '{"success": true, "action": "mkdir", "path": "' src '"}'

            case "exists":
                exists := FileExist(src) ? true : false
                return '{"success": true, "exists": ' (exists ? "true" : "false") ', "path": "' src '"}'

            case "list":
                if !src
                    return '{"success": false, "error": "need src"}'
                files := []
                loop files, src "\*", "FD" {
                    files.Push('{"name": "' A_LoopFileName '", "type": "' (A_LoopFileAttrib ~= "D" ? "dir" : "file") '"}')
                }
                return '{"success": true, "files": [' JoinStr(files, ",") ']}'

            default:
                return '{"success": false, "error": "unknown file action: ' action '"}'
        }
    } catch as e {
        return '{"success": false, "error": "' EscapeJsonContent(e.Message) '"}'
    }
}
