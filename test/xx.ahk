#Requires AutoHotkey v2.0

; 改用 MouseIsOver 判定：只要鼠标悬停在 GoLand / DataGrip 窗口上方即生效（即使悬浮窗抢了焦点）
#HotIf MouseIsOver("ahk_exe goland64.exe")
      or MouseIsOver("ahk_exe datagrip64.exe")
      or MouseIsOver("ahk_wm_class ^(sun-awt-X11-XFramePeer|SunAwtFrame)$")

; 按住 Ctrl 单击鼠标左键，触发两次 Ctrl+W
^LButton:: {
    Send "{LButton}"  ; 定位光标
    Sleep 50
    Send "^w"
    Sleep 50
    Send "^w"
}

#HotIf  ; 恢复全局

; 辅助函数：判断鼠标指针当前悬停的窗口
MouseIsOver(winTitle) {
    MouseGetPos ,, &winHandle
    return WinExist(winTitle " ahk_id " winHandle)
}