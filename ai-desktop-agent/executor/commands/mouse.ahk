; executor/commands/mouse.ahk
; 鼠标操作命令

#Requires AutoHotkey v2.0

; 点击
Mouse_Click(params) {
    x := params.Has("x") ? params["x"] : 0
    y := params.Has("y") ? params["y"] : 0

    if (x = 0 && y = 0)
        return '{"success": false, "error": "invalid coordinates"}'

    Click(x, y)
    return '{"success": true, "action": "click", "x": ' x ', "y": ' y '}'
}

; 双击
Mouse_DoubleClick(params) {
    x := params.Has("x") ? params["x"] : 0
    y := params.Has("y") ? params["y"] : 0

    Click(x, y, 2)
    return '{"success": true, "action": "double_click", "x": ' x ', "y": ' y '}'
}

; 右键点击
Mouse_RightClick(params) {
    x := params.Has("x") ? params["x"] : 0
    y := params.Has("y") ? params["y"] : 0

    Click("Right", x, y)
    return '{"success": true, "action": "right_click", "x": ' x ', "y": ' y '}'
}

; 拖拽
Mouse_Drag(params) {
    x1 := params.Has("x1") ? params["x1"] : 0
    y1 := params.Has("y1") ? params["y1"] : 0
    x2 := params.Has("x2") ? params["x2"] : 0
    y2 := params.Has("y2") ? params["y2"] : 0

    MouseMove(x1, y1)
    Sleep(100)
    Click("Down", x1, y1)
    Sleep(100)
    MouseMove(x2, y2, 10)
    Sleep(100)
    Click("Up", x2, y2)

    return '{"success": true, "action": "drag", "from": [' x1 ',' y1 '], "to": [' x2 ',' y2 ']}'
}

; 滚动
Mouse_Scroll(params) {
    x := params.Has("x") ? params["x"] : 0
    y := params.Has("y") ? params["y"] : 0
    direction := params.Has("direction") ? params["direction"] : "up"
    amount := params.Has("amount") ? params["amount"] : 3

    MouseMove(x, y)
    Sleep(50)

    if (direction = "up")
        Click("WheelUp", x, y, amount)
    else
        Click("WheelDown", x, y, amount)

    return '{"success": true, "action": "scroll", "direction": "' direction '", "amount": ' amount '}'
}
