#Requires AutoHotkey v2.0
#SingleInstance Force

; ===================================================
; 实现 TranslucentTB 同款全透明（图标保留，背景清空）
; ===================================================

SetTaskbarTranslucent()

; 监听系统任务栏重建事件（例如资源管理器重启时重新应用透明）
WM_TASKBARCREATED := DllCall("RegisterWindowMessage", "Str", "TaskbarCreated", "UInt")
OnMessage(WM_TASKBARCREATED, (*) => SetTaskbarTranslucent())

SetTaskbarTranslucent() {
    ; 1. 获取主任务栏句柄
    hTrayWnd := DllCall("user32\FindWindow", "Str", "Shell_TrayWnd", "Ptr", 0, "Ptr")
    if (!hTrayWnd)
        return

    ; 2. 构造 ACCENT_POLICY 结构体
    ; ACCENT_ENABLE_TRANSPARENTBLURBEHIND = 2 (透明模式)
    ; ACCENT_ENABLE_HOSTBACKDROP = 5 (Win11 原生透明亚克力背景)
    accentState := 2
    accentFlags := 2  ; 开启 DrawLeft/Top/Right/Bottom Border 标识
    gradientColor := 0x00000000 ; Alpha 设为 0 (完全全透明)

    ACCENT_POLICY := Buffer(16, 0)
    NumPut("Int", accentState,   ACCENT_POLICY, 0)
    NumPut("Int", accentFlags,   ACCENT_POLICY, 4)
    NumPut("Int", gradientColor, ACCENT_POLICY, 8)
    NumPut("Int", 0,             ACCENT_POLICY, 12)

    ; 3. 构造 WINCOMPATTRDATA 结构体 (WCA_ACCENT_POLICY = 19)
    pad := A_PtrSize == 8 ? 4 : 0
    WINCOMPATTRDATA := Buffer(4 + pad + A_PtrSize + 4 + pad, 0)
    NumPut("Int", 19,                  WINCOMPATTRDATA, 0)
    NumPut("Ptr", ACCENT_POLICY.Ptr,   WINCOMPATTRDATA, 4 + pad)
    NumPut("UInt", ACCENT_POLICY.Size, WINCOMPATTRDATA, 4 + pad + A_PtrSize)

    ; 4. 设置主显示器任务栏透明
    DllCall("user32\SetWindowCompositionAttribute", "Ptr", hTrayWnd, "Ptr", WINCOMPATTRDATA)

    ; 5. 设置副显示器任务栏透明（如果有双屏/多屏）
    hSecondary := 0
    while (hSecondary := DllCall("user32\FindWindowEx", "Ptr", 0, "Ptr", hSecondary, "Str", "Shell_SecondaryTrayWnd", "Ptr", 0, "Ptr")) {
        DllCall("user32\SetWindowCompositionAttribute", "Ptr", hSecondary, "Ptr", WINCOMPATTRDATA)
    }

    ; 6. 关键步骤：强制重绘任务栏（刷新 Win11 的 XAML 图层，消除背景色残影）
    DllCall("user32\RedrawWindow", "Ptr", hTrayWnd, "Ptr", 0, "Ptr", 0, "UInt", 0x81) ; RDW_INVALIDATE | RDW_UPDATENOW
}