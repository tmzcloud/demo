;#Requires AutoHotkey v2.0
;#NoTrayIcon
;#SingleInstance Force
;
;#HotIf (MouseIsOver("ahk_exe goland64.exe") or MouseIsOver("ahk_exe datagrip64.exe") or MouseIsOver("ahk_wm_class ^(sun-awt-X11-XFramePeer|SunAwtFrame)$"))
;      and !MouseIsOver("ahk_class AutoHotkeyGUI")
;      and !MouseIsOver("clipboard_v1.ahk")
;
;; 按住 Ctrl 单击鼠标左键
;^LButton:: {
;    Send "{Ctrl Up}"   ; 1. 临时释放 Ctrl 键，避免触发 GoLand 的 Ctrl+Click 跳转
;    Send "{LButton}"   ; 2. 发送普通左键单击，仅移动光标
;    Sleep 30
;    Send "^w"        ; 3. 连发两次 Ctrl+W 展开选区
;    Sleep 50
;    Send "^w"        ; 3. 连发两次 Ctrl+W 展开选区
;
;}
;
;#HotIf
;
;MouseIsOver(winTitle) {
;    MouseGetPos ,, &winHandle
;    return WinExist(winTitle " ahk_id " winHandle)
;}