#Requires AutoHotkey v2.0

SetChromeDefault() {
    ; 1. 打开默认应用主页
    Run("ms-settings:defaultapps")
    ; 2. 等待设置页面加载
    if WinWaitActive("ahk_class ApplicationFrameWindow", , 5) {
        Sleep(500)
        ; 3. 直接在当前焦点的搜索框里输入 http 并按回车
        Send("http")
        Sleep(300)
        Send("{Enter}")
        Sleep(500)
        ; 4. 按 Tab 切换到结果项并回车展开选择框
        Send("{Tab}{Enter}")
    }
}

SetChromeDefault()