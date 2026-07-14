#Requires AutoHotkey v2.0
#SingleInstance Force

; ==================== 🔑 本地部署配置 ====================
global LocalMem0Url := "http://localhost:8000"  ; 本地 Docker 的 FastAPI 端口
global UserId := "tsz"

global SentHistory := []
global MaxHistoryCount := 100
; =======================================================

IsMouseOverClipboardHistory() {
    MouseGetPos(,, &MouseHwnd)
    try {
        TopParent := MouseHwnd
        Loop {
            Parent := DllCall("GetParent", "Ptr", TopParent, "Ptr")
            if !Parent
                break
            TopParent := Parent
        }
        if (WinGetClass(TopParent) = "ApplicationFrameWindow" and WinGetProcessName(TopParent) = "explorer.exe") {
            return true
        }
    }
    return false
}

; 🎯 【右键监听】：封存记忆
~RButton:: {
    global LocalMem0Url, UserId, SentHistory, MaxHistoryCount

    if IsMouseOverClipboardHistory() {
        Sleep 60

        textData := A_Clipboard
        if (textData = "") {
            ShowRightEdgeCenterToolTip("❌ 剪贴板为空", 2500)
            return
        }

        for index, pastText in SentHistory {
            if (textData == pastText) {
                ShowRightEdgeCenterToolTip("⚠️ 该记忆在历史中已存在！", 2500)
                return
            }
        }

        ShowRightEdgeCenterToolTip("⏳ 正在封存记忆到本地Qween2.5 7B `n大脑中...", 0)
        jsonData := '{"text": "' . EscapeJson(textData) . '", "user_id": "' . UserId . '"}'

        whr := ComObject("WinHttp.WinHttpRequest.5.1")
        try {
            whr.Open("POST", LocalMem0Url . "/add", false)
            whr.SetTimeouts(30000, 30000, 30000, 30000) ; 👈 给本地推理加上30秒宽限期
            whr.SetRequestHeader("Content-Type", "application/json; charset=utf-8")
            whr.Send(jsonData)

            if (whr.Status == 200 || whr.Status == 201) {
                SentHistory.InsertAt(1, textData)
                if (SentHistory.Length > MaxHistoryCount) {
                    SentHistory.Pop()
                }
                ShowRightEdgeCenterToolTip("🧠 【本地 7B 记忆】键盘流已封存！`n内容：" . SubStr(textData, 1, 30) . "...", 2500)
            } else {
                serverErr := GetUtf8Text(whr)
                ShowRightEdgeCenterToolTip("❌ 写入本地失败，状态码: " . whr.Status, 3000)
                MsgBox("服务器返回错误明细:`n" . serverErr, "错误")
            }
        } catch Error as err {
            ShowRightEdgeCenterToolTip("❌ 异常: " . err.Message, 3000)
        }
    }
}

; 🎯 【Alt + Q】：纯本地 7B 智能问答
!q:: {
    global LocalMem0Url, UserId

    ib := InputBox("向本地 7B 大脑提问（结合你的记忆）：", "本地记忆智能问答")
    if ib.Result = "Cancel" || ib.Value = ""
        return

    userQuery := ib.Value
    ShowRightEdgeCenterToolTip("🧠 正在唤醒本地 7B 大脑检索并思考...", 0)

    whr := ComObject("WinHttp.WinHttpRequest.5.1")
    try {
        askUrl := LocalMem0Url . "/ask?user_id=" . UserId . "&query=" . UriEncode(userQuery)
        whr.Open("GET", askUrl, false)
        whr.SetTimeouts(45000, 45000, 45000, 45000) ; 👈 LLM 检索+生成很慢，给予45秒超长超时限制
        whr.Send()

        ShowRightEdgeCenterToolTip("", -1) ; 消除提示

        if (whr.Status == 200) {
            ; 👈 使用重新封装的、免疫一切乱码的转码函数
            responseText := GetUtf8Text(whr)

            ; 👈 改进正则：因为大模型的答案里经常包含双引号、换行等，用更加宽容的模式匹配
            if RegExMatch(responseText, 'i)"answer"\s*:\s*"(.*?)(?<!\\)"', &aiMatch) {
                finalAnswer := aiMatch[1]
                ; 还原 JSON 转义字符
                finalAnswer := StrReplace(finalAnswer, "\n", "`n")
                finalAnswer := StrReplace(finalAnswer, "\r", "`r")
                finalAnswer := StrReplace(finalAnswer, '\"', '"')
                finalAnswer := StrReplace(finalAnswer, '\\', '\')

                MsgBox(finalAnswer, "本地 7B 大脑回答")
            } else {
                MsgBox("解析答案失败，纯净报文:`n" . responseText)
            }
        } else {
            responseText := GetUtf8Text(whr)
            MsgBox("本地服务响应失败状态码: " . whr.Status . "`n明细: " . responseText)
        }
    } catch Error as err {
        ShowRightEdgeCenterToolTip("", -1)
        MsgBox("本地调用发生异常: " . err.Message)
    }
}

; 🆕 重新实现的、绝对安全的 SafeArray 到 UTF-8 转换函数
GetUtf8Text(whrObj) {
    try {
        ; 获取 WinHttp 原始返回的 SafeArray 字节流
        rawBody := whrObj.ResponseBody

        ; 使用 Windows API 锁定 SafeArray 并获取内存数据指针
        dataPtr := 0
        DllCall("OleAut32\SafeArrayAccessData", "Ptr", ComObjValue(rawBody), "Ptr*", &dataPtr)

        ; 获取字节流的总长度
        dataSize := rawBody.MaxIndex() + 1

        ; 从内存指针中直接按 UTF-8 转换文本
        resText := StrGet(dataPtr, dataSize, "UTF-8")

        ; 解锁内存（好习惯）
        DllCall("OleAut32\SafeArrayUnaccessData", "Ptr", ComObjValue(rawBody))

        return resText
    } catch {
        ; 万一发生不可控异常，回退到原文本
        return whrObj.ResponseText
    }
}

ShowRightEdgeCenterToolTip(text, dismissTime := 2500) {
    if (text == "" || dismissTime < 0) {
        ToolTip()
        return
    }
    CoordMode("ToolTip", "Screen")
    MonitorWidth := SysGet(16)
    MonitorHeight := SysGet(17)
    ToolTip(text, MonitorWidth, MonitorHeight / 2)
    if toolTipHwnd := WinExist("ahk_class #32774") {
        WinGetPos(,, &TipWidth, &TipHeight, "ahk_id " . toolTipHwnd)
        WinMove(MonitorWidth - TipWidth - 5, (MonitorHeight / 2) - (TipHeight / 2),,, "ahk_id " . toolTipHwnd)
    }
    SetTimer(() => ToolTip(), 0)
    if (dismissTime > 0) {
        SetTimer(() => ToolTip(), -dismissTime)
    }
}

EscapeJson(str) {
    str := StrReplace(str, "\", "\\")
    str := StrReplace(str, '"', '\"')
    str := StrReplace(str, "`n", "\n")
    str := StrReplace(str, "`r", "\r")
    str := StrReplace(str, "`t", "\t")
    return str
}

UriEncode(str) {
    Hex := "0123456789ABCDEF"
    encoded := ""
    buf := Buffer(StrPut(str, "UTF-8"))
    StrPut(str, buf, "UTF-8")
    Loop buf.Size - 1 {
        byte := NumGet(buf, A_Index - 1, "UChar")
        if ((byte >= 48 && byte <= 57) || (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122) || InStr("-._~", Chr(byte)))
            encoded .= Chr(byte)
        else
            encoded .= "%" . SubStr(Hex, (byte >> 4) + 1, 1) . SubStr(Hex, (byte & 15) + 1, 1)
    }
    return encoded
}