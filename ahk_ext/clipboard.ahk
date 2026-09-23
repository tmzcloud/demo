#Requires AutoHotkey v2.0
#SingleInstance Force
#NoTrayIcon
#UseHook
Persistent
; 独立启动：lib\webview2 已有则静默后台；缺失才弹下载进度窗，下完重启 #Include
; 相对路径 Include（勿用 "%A_ScriptDir%\..."，部分 AHK 会失败）
#Include *i lib\webview2\WebView2.ahk

; 勿在此强制 RunAs：UAC 取消会直接 ExitApp；与快捷键4共存请两边都以管理员启动（或都不提权）。
; 清掉残留的系统忙碌光标（其它脚本 / 长时间磁盘任务会留下转圈）
try DllCall("SystemParametersInfo", "UInt", 0x57, "UInt", 0, "Ptr", 0, "UInt", 0) ; SPI_SETCURSORS

; ── 独立运行托盘；快捷键4 传 hosted 则静默 ───────────────────────────
global clipboardHosted := ClipArgsHas("hosted")
global clipboardStandalone := !clipboardHosted
global clipboardTrayVisible := false
global clipBootGui := 0
global clipBootStatusCtrl := 0
global clipBootPctCtrl := 0
global clipBootExitOnClose := true
; 仅「正在下载 WebView2」时才弹进度窗；日常启动不弹
global clipBootAllowUi := false
; #HotIf 可能在中段全局初始化前求值，这些状态必须尽早赋值
global panelVisible := false
global uiPinned := false
global qqSearchOn := false
global guiWin := ""

ClipArgsHas(name) {
    name := StrLower(String(name))
    for a in A_Args {
        if StrLower(String(a)) = name
            return true
    }
    return false
}

ClipSetupStandaloneTray(*) {
    global clipboardStandalone, clipboardTrayVisible
    if !clipboardStandalone {
        clipboardTrayVisible := false
        return
    }
    try {
        A_IconHidden := false
        TraySetIcon("shell32.dll", 261)
        A_TrayMenu.Delete()
        A_TrayMenu.Add("显示剪贴板", (*) => ShowPanel())
        A_TrayMenu.Add("清空历史", (*) => ClearAll())
        A_TrayMenu.Add()
        A_TrayMenu.Add("退出", (*) => ExitApp())
        A_TrayMenu.Default := "显示剪贴板"
        A_IconTip := "剪贴板  (Win+V)"
        clipboardTrayVisible := !A_IconHidden
    } catch {
        clipboardTrayVisible := false
    }
    if !clipboardTrayVisible
        ClipEnsureNoTrayExitWindow()
}

ClipEnsureNoTrayExitWindow(*) {
    global clipBootGui, clipBootStatusCtrl, clipBootPctCtrl, clipBootExitOnClose
    if IsObject(clipBootGui)
        return
    clipBootExitOnClose := true
    g := Gui("+AlwaysOnTop -MinimizeBox", "剪贴板")
    g.SetFont("s10", "Segoe UI")
    g.Add("Text", "w360", "托盘图标未能显示。窗口关闭即退出进程。")
    clipBootStatusCtrl := g.Add("Text", "w360 vBootStatus", "运行中… Win+V 唤出")
    clipBootPctCtrl := g.Add("Progress", "w360 h16 Range0-100", 100)
    g.OnEvent("Close", ClipBootOnClose)
    g.Show("AutoSize Center")
    clipBootGui := g
}

ClipBootOnClose(*) {
    global clipBootExitOnClose
    if clipBootExitOnClose
        ExitApp
}

; 仅 clipBootAllowUi=true（缺组件下载中）才弹窗
ClipBootShow(msg, pct := 0) {
    global clipBootGui, clipBootStatusCtrl, clipBootPctCtrl, clipBootExitOnClose
    global clipboardStandalone, clipboardHosted, clipBootAllowUi
    if !clipBootAllowUi || clipboardHosted || !clipboardStandalone
        return
    pct := Max(0, Min(100, Integer(pct)))
    clipBootExitOnClose := true
    if !IsObject(clipBootGui) {
        g := Gui("+AlwaysOnTop -MinimizeBox +MinSize", "剪贴板 · 下载组件")
        g.SetFont("s11", "Segoe UI")
        g.Add("Text", "w400 Section", "首次运行需下载 WebView2")
        clipBootStatusCtrl := g.Add("Text", "w400 h40 vBootStatus", msg)
        clipBootPctCtrl := g.Add("Progress", "w400 h20 Range0-100", pct)
        g.Add("Text", "w400 c666666", "下载完成后会自动重启；之后日常启动不再弹此窗。`n点右上角 × 可退出。")
        g.OnEvent("Close", ClipBootOnClose)
        g.Show("Center w440")
        clipBootGui := g
        try WinSetAlwaysOnTop(true, "ahk_id " g.Hwnd)
        try WinActivate("ahk_id " g.Hwnd)
    } else {
        try clipBootStatusCtrl.Value := msg
        try clipBootPctCtrl.Value := pct
        try clipBootGui.Show("NA Center")
    }
    Sleep 40
}

ClipBootHide(*) {
    global clipBootGui, clipBootStatusCtrl, clipBootPctCtrl, clipBootExitOnClose
    global clipboardTrayVisible, clipboardStandalone, clipBootAllowUi
    clipBootAllowUi := false
    if !clipboardStandalone
        return
    if !clipboardTrayVisible {
        ClipEnsureNoTrayExitWindow()
        return
    }
    clipBootExitOnClose := false
    if IsObject(clipBootGui) {
        try clipBootGui.Destroy()
    }
    clipBootGui := 0
    clipBootStatusCtrl := 0
    clipBootPctCtrl := 0
}

ClipboardRelaunchSelf(*) {
    global clipboardHosted
    args := ""
    for a in A_Args {
        al := StrLower(String(a))
        if al = "show" || al = "hosted"
            continue
        args .= (args = "" ? "" : " ") '"' String(a) '"'
    }
    if clipboardHosted
        args := Trim(args " hosted")
    cmd := Format('"{1}" "{2}"{3}', A_AhkPath, A_ScriptFullPath, args = "" ? "" : " " args)
    Run(cmd)  ; 不要 Hide
}

ClipSetupStandaloneTray()

; 有 lib\webview2 则静默继续；没有才弹下载窗 → 重启
_wv2Ahk := A_ScriptDir "\lib\webview2\WebView2.ahk"
_wv2Dll := A_ScriptDir "\lib\webview2\WebView2Loader.dll"
_wv2NeedBoot := !FileExist(_wv2Ahk) || !FileExist(_wv2Dll) || !IsSet(WebView2)
if _wv2NeedBoot {
    clipBootAllowUi := true
    ClipBootShow("缺少 WebView2，准备下载…", 6)
    if !ClipboardBootstrapWebView2() {
        ClipBootShow("WebView2 下载失败，请检查网络后重试", 0)
        MsgBox "无法准备 WebView2 组件（lib\webview2）。`n请检查网络后重试。", "剪贴板", "Iconx"
        ExitApp
    }
    ClipBootShow("组件就绪，正在重启…", 95)
    Sleep 400
    ClipboardRelaunchSelf()
    ExitApp
}

ClipParentHotkey4Exists() {
    parent := ""
    SplitPath A_ScriptDir, , &parent
    if parent = ""
        return false
    return !!FileExist(parent "\快捷键4.ahk")
}

ClipboardBootstrapWebView2() {
    static ahkUrl := "https://raw.githubusercontent.com/thqby/ahk2_lib/master/WebView2/WebView2.ahk"
    static nupkgUrl := "https://api.nuget.org/v3-flatcontainer/microsoft.web.webview2/1.0.2903.40/microsoft.web.webview2.1.0.2903.40.nupkg"
    dir := A_ScriptDir "\lib\webview2"
    ahk := dir "\WebView2.ahk"
    dll := dir "\WebView2Loader.dll"
    try DirCreate(dir)
    for p in [
        A_ScriptDir "\lib\webview2_bak\WebView2.ahk",
        A_ScriptDir "\lib\WebView2.ahk",
        A_Temp "\WebView2.ahk"
    ] {
        if !FileExist(ahk) && FileExist(p) {
            ClipBootShow("复制 WebView2.ahk…", 10)
            try FileCopy(p, ahk, 1)
        }
    }
    for p in [
        A_ScriptDir "\lib\webview2_bak\WebView2Loader.dll",
        A_ScriptDir "\lib\WebView2Loader.dll",
        A_Temp "\WebView2Loader.dll"
    ] {
        if !FileExist(dll) && FileExist(p) {
            ClipBootShow("复制 WebView2Loader.dll…", 12)
            try FileCopy(p, dll, 1)
        }
    }
    needAhk := !FileExist(ahk)
    needDll := !FileExist(dll)
    if !needAhk && !needDll
        return true
    ok := true
    if needAhk {
        ClipBootShow("正在下载 WebView2.ahk…", 18)
        if !ClipboardDownloadFile(ahkUrl, ahk)
            ok := false
        else
            ClipBootShow("WebView2.ahk 下载完成", 35)
    }
    if needDll {
        ClipBootShow("正在下载 WebView2Loader.dll（NuGet）…", 45)
        if !ClipboardDownloadWebView2Dll(nupkgUrl, dll)
            ok := false
        else
            ClipBootShow("WebView2Loader.dll 就绪", 70)
    }
    return ok && FileExist(ahk) && FileExist(dll)
}

ClipJoinArgs(args) {
    out := ""
    for a in args
        out .= (out = "" ? "" : " ") '"' String(a) '"'
    return out
}

ClipboardDownloadFile(url, dest) {
    try {
        SplitPath dest, , &destDir
        if destDir != ""
            DirCreate destDir
        tmp := dest ".part"
        try FileDelete tmp
        curl := A_WinDir "\System32\curl.exe"
        if FileExist(curl) {
            ClipBootShow("下载中（curl）…", 22)
            rc := RunWait(Format('"{1}" -L --retry 3 --connect-timeout 20 -o "{2}" "{3}"', curl, tmp, url), , "Hide")
            if rc = 0 && FileExist(tmp) && FileGetSize(tmp) > 1000 {
                try FileMove tmp, dest, 1
                return FileExist(dest) && FileGetSize(dest) > 1000
            }
        }
        ClipBootShow("下载中（WinHttp）…", 25)
        whr := ComObject("WinHttp.WinHttpRequest.5.1")
        whr.Open("GET", url, false)
        whr.SetTimeouts(10000, 10000, 30000, 120000)
        whr.Send()
        if whr.Status != 200
            return false
        stream := ComObject("ADODB.Stream")
        stream.Type := 1
        stream.Open()
        stream.Write(whr.ResponseBody)
        stream.SaveToFile(tmp, 2)
        stream.Close()
        try FileMove tmp, dest, 1
        return FileExist(dest) && FileGetSize(dest) > 1000
    } catch {
        return false
    }
}

ClipboardDownloadWebView2Dll(nupkgUrl, destDll) {
    nupkg := A_Temp "\wv2_" A_TickCount ".nupkg"
    unzipDir := A_Temp "\wv2_extract_" A_TickCount
    try {
        ClipBootShow("下载 WebView2 NuGet 包…", 48)
        if !ClipboardDownloadFile(nupkgUrl, nupkg)
            return false
        ClipBootShow("解压 WebView2Loader.dll…", 60)
        try DirDelete unzipDir, 1
        DirCreate unzipDir
        zipPath := unzipDir "\pkg.zip"
        FileCopy nupkg, zipPath, 1
        shell := ComObject("Shell.Application")
        zipNs := shell.NameSpace(zipPath)
        destNs := shell.NameSpace(unzipDir)
        if !IsObject(zipNs) || !IsObject(destNs)
            return false
        destNs.CopyHere(zipNs.Items(), 4 | 16 | 1024)
        loop 80 {
            Sleep 100
            if FileExist(unzipDir "\runtimes\win-x64\native\WebView2Loader.dll")
                break
            if Mod(A_Index, 10) = 0
                ClipBootShow("解压中… " A_Index, 60 + Min(10, A_Index // 8))
        }
        src := ""
        prefer := (A_PtrSize = 8) ? "win-x64" : "win-x86"
        for arch in [prefer, "win-x64", "win-x86"] {
            cand := unzipDir "\runtimes\" arch "\native\WebView2Loader.dll"
            if FileExist(cand) {
                src := cand
                break
            }
        }
        if src = "" {
            loop files unzipDir "\WebView2Loader.dll", "FR" {
                src := A_LoopFileFullPath
                break
            }
        }
        if src = ""
            return false
        SplitPath destDll, , &d
        DirCreate d
        FileCopy src, destDll, 1
        return FileExist(destDll) && FileGetSize(destDll) > 1000
    } catch {
        return false
    } finally {
        try FileDelete nupkg
        try DirDelete unzipDir, 1
    }
}

; skipGui：浏览器/微信等自定义光标时，勿先信 GetGUIThreadInfo 假光标（否则 UIA/MSAA 到不了）
GetCaretPosEx(&left?, &top?, &right?, &bottom?, useHook := false, skipHeavy := false, skipGui := false) {
    hwnd := 0
    if !skipGui && getCaretPosFromGui(&hwnd)
        return true
    if !hwnd {
        ; 即使跳过 Gui，也要拿到 focus hwnd 供 MSAA/UIA
        x64 := A_PtrSize == 8
        gi := Buffer(x64 ? 72 : 48)
        NumPut("uint", gi.Size, gi)
        if DllCall("GetGUIThreadInfo", "uint", 0, "ptr", gi)
            hwnd := NumGet(gi, x64 ? 16 : 12, "ptr")
    }
    ; Acc/UIA from #UseHook hotkeys can deadlock OneNote / some Office hosts
    if skipHeavy
        return false
    try
        className := WinGetClass(hwnd)
    catch
        className := ""
    if className ~= "^(?:Windows|Microsoft)\.UI\..+"
        funcs := [getCaretPosFromUIA, getCaretPosFromHook, getCaretPosFromMSAA]
    else if className ~= "^HwndWrapper\[PowerShell_ISE\.exe;;[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\]"
        funcs := [getCaretPosFromHook, getCaretPosFromWpfCaret]
    else if className ~= "i)SunAwt" || IsJetBrainsApp()
        ; GoLand/IDEA：远程 Hook 最准；UIA 次之；勿先 MSAA（AWT 常失败或偏）
        funcs := useHook
            ? [getCaretPosFromHook, getCaretPosFromUIA, getCaretPosFromMSAA]
            : [getCaretPosFromUIA, getCaretPosFromHook, getCaretPosFromMSAA]
    else
        funcs := [getCaretPosFromMSAA, getCaretPosFromUIA, getCaretPosFromHook]
    for fn in funcs {
        if fn == getCaretPosFromHook && !useHook
            continue
        if fn()
            return true
    }
    return false

    getCaretPosFromGui(&hwnd) {
        x64 := A_PtrSize == 8
        guiThreadInfo := Buffer(x64 ? 72 : 48)
        NumPut("uint", guiThreadInfo.Size, guiThreadInfo)
        if DllCall("GetGUIThreadInfo", "uint", 0, "ptr", guiThreadInfo) {
            flags := NumGet(guiThreadInfo, 4, "uint")
            if hwnd := NumGet(guiThreadInfo, x64 ? 48 : 28, "ptr") {
                getRect(guiThreadInfo.Ptr + (x64 ? 56 : 32), &left, &top, &right, &bottom)
                ; 无 GUI_CARETBLINKING 的假矩形（Chrome/微信常见）直接丢弃
                if !(flags & 0x1) && ((right - left) < 1 || (bottom - top) < 1 || IsCustomCaretApp()) {
                    hwnd := NumGet(guiThreadInfo, x64 ? 16 : 12, "ptr")
                    return false
                }
                scaleRect(getWindowScale(hwnd), &left, &top, &right, &bottom)
                clientToScreenRect(hwnd, &left, &top, &right, &bottom)
                return true
            }
            hwnd := NumGet(guiThreadInfo, x64 ? 16 : 12, "ptr")
        }
        return false
    }

    getCaretPosFromMSAA() {
        if !hwnd
            return false
        if !hOleacc := DllCall("LoadLibraryW", "str", "oleacc.dll", "ptr")
            return false
        hOleacc := { Ptr: hOleacc, __Delete: (_) => DllCall("FreeLibrary", "ptr", _) }
        static IID_IAccessible := guidFromString("{618736e0-3c3d-11cf-810c-00aa00389b71}")
        if !DllCall("oleacc\AccessibleObjectFromWindow", "ptr", hwnd, "uint", 0xfffffff8, "ptr", IID_IAccessible, "ptr*", accCaret := ComValue(13, 0), "int") {
            if A_PtrSize == 8 {
                varChild := Buffer(24, 0)
                NumPut("ushort", 3, varChild)
                hr := ComCall(22, accCaret, "int*", &x := 0, "int*", &y := 0, "int*", &w := 0, "int*", &h := 0, "ptr", varChild, "int")
            }
            else {
                hr := ComCall(22, accCaret, "int*", &x := 0, "int*", &y := 0, "int*", &w := 0, "int*", &h := 0, "int64", 3, "int64", 0, "int")
            }
            if !hr {
                ; OBJID_CARET accLocation 已是屏幕坐标，勿再 ScreenToClient
                if w < 1 && h < 1 {
                    w := Max(w, 1)
                    h := Max(h, 16)
                }
                left := x
                top := y
                right := x + w
                bottom := y + h
                return true
            }
        }
        return false
    }

    getCaretPosFromUIA() {
        try {
            uia := ComObject("{E22AD333-B25F-460C-83D0-0581107395C9}", "{30CBE57D-D9D0-452A-AB13-7AC5AC4825EE}")
            ComCall(20, uia, "ptr*", cacheRequest := ComValue(13, 0))
            if !cacheRequest.Ptr
                return false
            ComCall(4, cacheRequest, "ptr", 10014)
            ComCall(4, cacheRequest, "ptr", 10024)

            ComCall(12, uia, "ptr", cacheRequest, "ptr*", focusedEle := ComValue(13, 0))
            if !focusedEle.Ptr
                return false

            static IID_IUIAutomationTextPattern2 := guidFromString("{506a921a-fcc9-409f-b23b-37eb74106872}")
            range := ComValue(13, 0)
            ComCall(15, focusedEle, "int", 10024, "ptr", IID_IUIAutomationTextPattern2, "ptr*", textPattern := ComValue(13, 0))
            if textPattern.Ptr {
                ComCall(10, textPattern, "int*", &isActive := 0, "ptr*", range)
                if range.Ptr
                    goto getRangeInfo
            }
            static IID_IUIAutomationTextPattern := guidFromString("{32eba289-3583-42c9-9c59-3b6d9a1e9b6a}")
            ComCall(15, focusedEle, "int", 10014, "ptr", IID_IUIAutomationTextPattern, "ptr*", textPattern)
            if textPattern.Ptr {
                ComCall(5, textPattern, "ptr*", ranges := ComValue(13, 0))
                if ranges.Ptr {
                    ComCall(3, ranges, "int*", &len := 0)
                    if len > 0
                        ComCall(4, ranges, "int", len - 1, "ptr*", range)
                }
            }
            if !range.Ptr
                return false
getRangeInfo:
            ; Try bounds without expand first (avoids scroll-into-view jitter).
            psa := 0
            ComCall(10, range, "ptr*", &psa)
            if psa {
                rects := ComValue(0x2005, psa, 1)
                if rects.MaxIndex() >= 3 {
                    left := Round(rects[0])
                    top := Round(rects[1])
                    w := Round(rects[2])
                    h := Round(rects[3])
                    if (w > 0 || h > 0 || left != 0 || top != 0) {
                        right := left + Max(w, 1)
                        bottom := top + Max(h, 1)
                        return true
                    }
                }
            }
            ; Fallback expand for IDEs (e.g. GoLand) when caret range has no rect yet.
            ; Only Character unit —Line expand was too aggressive on scroll.
            ComCall(6, range, "int", 0)
            psa := 0
            ComCall(10, range, "ptr*", &psa)
            if !psa
                return false
            rects := ComValue(0x2005, psa, 1)
            if rects.MaxIndex() < 3
                return false
            left := Round(rects[0])
            top := Round(rects[1])
            w := Round(rects[2])
            h := Round(rects[3])
            right := left + Max(w, 1)
            bottom := top + Max(h, 1)
            return true
        }
        return false
    }

    getCaretPosFromWpfCaret() {
        try {
            uia := ComObject("{E22AD333-B25F-460C-83D0-0581107395C9}", "{30CBE57D-D9D0-452A-AB13-7AC5AC4825EE}")
            ComCall(8, uia, "ptr*", focusedEle := ComValue(13, 0))
            if !focusedEle.Ptr
                return false

            ComCall(20, uia, "ptr*", cacheRequest := ComValue(13, 0))
            if !cacheRequest.Ptr
                return false

            ComCall(17, uia, "ptr*", rawViewCondition := ComValue(13, 0))
            if !rawViewCondition.Ptr
                return false

            ComCall(9, cacheRequest, "ptr", rawViewCondition)
            ComCall(3, cacheRequest, "int", 30001)

            var := Buffer(24, 0)
            ref := ComValue(0x400C, var.Ptr)
            ref[] := ComValue(8, "WpfCaret")
            ComCall(23, uia, "int", 30012, "ptr", var, "ptr*", condition := ComValue(13, 0))
            if !condition.Ptr
                return false

            ComCall(7, focusedEle, "int", 4, "ptr", condition, "ptr", cacheRequest, "ptr*", wpfCaret := ComValue(13, 0))
            if !wpfCaret.Ptr
                return false

            ComCall(75, wpfCaret, "ptr", rect := Buffer(16))
            getRect(rect, &left, &top, &right, &bottom)
            return true
        }
        return false
    }

    getCaretPosFromHook() {
        static WM_GET_CARET_POS := DllCall("RegisterWindowMessageW", "str", "WM_GET_CARET_POS", "uint")
        if !tid := DllCall("GetWindowThreadProcessId", "ptr", hwnd, "ptr*", &pid := 0, "uint")
            return false
        try {
            ; SMTO_ABORTIFHUNG —don't freeze if target ignores WM_IME_COMPOSITION
            DllCall("SendMessageTimeoutW", "Ptr", hwnd, "UInt", 0x010f, "Ptr", 0, "Ptr", 0
                , "UInt", 0x0002, "UInt", 50, "UPtr*", &ignored := 0)
        }
        if !hProcess := DllCall("OpenProcess", "uint", 1082, "int", false, "uint", pid, "ptr")
            return false
        hProcess := { Ptr: hProcess, __Delete: (_) => DllCall("CloseHandle", "ptr", _) }

        isX64 := isX64Process(hProcess)
        if isX64 && A_PtrSize == 4
            return false
        if !moduleBaseMap := getModulesBases(hProcess, ["kernel32.dll", "user32.dll", "combase.dll"])
            return false
        if isX64 {
            static shellcode64 := compile(true)
            shellcode := shellcode64
        }
        else {
            static shellcode32 := compile(false)
            shellcode := shellcode32
        }
        if !mem := DllCall("VirtualAllocEx", "ptr", hProcess, "ptr", 0, "ptr", shellcode.Size, "uint", 0x1000, "uint", 0x40, "ptr")
            return false
        mem := { Ptr: mem, __Delete: (_) => DllCall("VirtualFreeEx", "ptr", hProcess, "ptr", _, "uptr", 0, "uint", 0x8000) }
        link(isX64, shellcode, mem.Ptr, moduleBaseMap["user32.dll"], moduleBaseMap["combase.dll"], hwnd, tid, WM_GET_CARET_POS, &pThreadProc, &pRect)

        if !DllCall("WriteProcessMemory", "ptr", hProcess, "ptr", mem, "ptr", shellcode, "uptr", shellcode.Size, "ptr", 0)
            return false
        DllCall("FlushInstructionCache", "ptr", hProcess, "ptr", mem, "uptr", shellcode.Size)

        if !hThread := DllCall("CreateRemoteThread", "ptr", hProcess, "ptr", 0, "uptr", 0, "ptr", pThreadProc, "ptr", mem, "uint", 0, "uint*", &remoteTid := 0, "ptr")
            return false
        hThread := { Ptr: hThread, __Delete: (_) => DllCall("CloseHandle", "ptr", _) }

        if msgWaitForSingleObject(hThread)
            return false
        if !DllCall("GetExitCodeThread", "ptr", hThread, "uint*", exitCode := 0) || exitCode !== 0
            return false

        rect := Buffer(16)
        if !DllCall("ReadProcessMemory", "ptr", hProcess, "ptr", pRect, "ptr", rect, "uptr", rect.Size, "uptr*", &bytesRead := 0) || bytesRead !== rect.Size
            return false
        getRect(rect, &left, &top, &right, &bottom)
        ; JetBrains / AWT：hook 结果已是屏幕坐标；再乘 DPI 比例会整体偏移
        try {
            if (WinGetClass("ahk_id " hwnd) ~= "i)SunAwt") || IsJetBrainsApp()
                return true
        }
        scaleRect(getWindowScale(hwnd), &left, &top, &right, &bottom)
        return true

        static isX64Process(hProcess) {
            DllCall("IsWow64Process", "ptr", hProcess, "int*", &isWow64 := 0)
            if isWow64
                return false
            if A_PtrSize == 8
                return true
            DllCall("IsWow64Process", "ptr", DllCall("GetCurrentProcess", "ptr"), "int*", &isWow64)
            return isWow64
        }

        static getModulesBases(hProcess, modules) {
            hModules := Buffer(A_PtrSize * 350)
            if !DllCall("K32EnumProcessModulesEx", "ptr", hProcess, "ptr", hModules, "uint", hModules.Size, "uint*", &needed := 0, "uint", 3)
                return
            moduleBaseMap := Map()
            moduleBaseMap.CaseSense := false
            for v in modules
                moduleBaseMap[v] := 0
            cnt := modules.Length
            loop Min(350, needed) {
                hModule := NumGet(hModules, A_PtrSize * (A_Index - 1), "ptr")
                VarSetStrCapacity(&name, 12)
                if DllCall("K32GetModuleBaseNameW", "ptr", hProcess, "ptr", hModule, "str", &name, "uint", 13) {
                    if moduleBaseMap.Has(name) {
                        moduleInfo := Buffer(24)
                        if !DllCall("K32GetModuleInformation", "ptr", hProcess, "ptr", hModule, "ptr", moduleInfo, "uint", moduleInfo.Size)
                            return
                        if !base := NumGet(moduleInfo, "ptr")
                            return
                        moduleBaseMap[name] := base
                        cnt--
                    }
                }
            } until cnt == 0
            if cnt == 0
                return moduleBaseMap
        }

        static compile(x64) {
            if x64
                shellcodeBase64 := "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABrnppSh2UjT6uenH1oPjxQAeiAqiEg0hGT4ABgsGe4blNldFdpbmRvd3NIb29rRXhXAAAAVW5ob29rV2luZG93c0hvb2tFeABDYWxsTmV4dEhvb2tFeAAAAAAAAFNlbmRNZXNzYWdlVGltZW91dFcAQ29DcmVhdGVJbnN0YW5jZQAAAAAAAAAASIlcJAhIiXQkEFdIg+wgSYvYSIvyi/mFyXgjSIXbdB6LBQb///9BOUAQdRJIjQ3d/v//6JgBAACJBfL+//9Iiw3L/v//SI0VdP///+jnAgAASIXAdRBIi1wkMEiLdCQ4SIPEIF/DTIvLTIvGi9czyUiLXCQwSIt0JDhIg8QgX0j/4MzMzMzMzDPAw8zMzMzMQFNWSIPsSIvySIvZSIXJdQy4VwAHgEiDxEheW8NIi0kISI1UJGBIiVQkKEG4/////0iNVCQwSIl8JEAz/0iJVCQgiXwkYIvWSIsBRI1PAf9QKIXAeHJIOXwkMHRrOXwkYHRlSItLCEiNVCR4SIl8JHhIiwH/UEiL+IXAeDJIi0wkeEiFyXQoSIsBSI1UJHBMi0QkMEyNSxBIiVQkIIvW/1AgSItMJHiL+EiLAf9QEEiLTCQwSIsB/1AQi8dIi3wkQEiDxEheW8NIi3wkQLgBAAAASIPESF5bw8zMzMzMzMxIhcl0VEiF0nRPTYXAdEpIiwJIhcB1HUi4wAAAAAAAAEZIOUIIdCxJxwAAAAAAuAJAAIDDSbkD6ICqISDSEUk7wXXkSLiT4ABgsGe4bkg5Qgh11EmJCDPAw7hXAAeAw8xAU0iD7EBIi9lIjZHYAAAASItJCOhPAQAASIXAdQu4AQAAAEiDxEBbwzPJx0QkWAEAAABIjVQkaEiJTCRoSIlUJCBMjUt4M9JIiUwkYEiJTCQwiUwkUEiNS2hEjUIX/9CFwA+I7wAAAEiLTCRoSIXJD4ThAAAASIsBSI1UJFD/UBiFwA+IhQAAAEiLTCRoSI1UJGBIiwH/UDiFwHhxSItMJGBIhcl0bEiLAUiNVCQw/1AwhcB4WEiLTCQwSIXJdGZIjUNISIlLMEiJQyhMjUMoSI0Vyf7//0G5AwAAAEiJEEiNBdH9//9IiUNQSI1UJFhIiUNYSI0Fxf3//0iJQ2BIiwFIiVQkIItUJFD/UBhIi0wkYEiLVCQwSIXSdA5IiwJIi8r/UBBIi0wkYEiFyXQGSIsB/1AQSItMJGhIhcl0BkiLAf9QEItEJFj32BvAg+AESIPEQFvDuAQAAABIg8RAW8PMzMzMzMxIiVwkCEiJbCQQSIl0JBhIiXwkIEyL2kyL0UiFyXRwSIXSdGtIY0E8g7wIjAAAAAB0XYuMCIgAAACFyXRSRYtMCiBJjQQKi3AkTQPKi2gcSQPyi3gYSQPqD7YaRTPA/89BixFJA9I6GnUZD7bLSYvDSSvThMl0Lw+2SAFI/8A6DAJ08EH/wEmDwQREO8d20TPASItcJAhIi2wkEEiLdCQYSIt8JCDDSWPAD7cMRotEjQBJA8Lr28zMSIlcJAhIiWwkEEiJdCQYSIl8JCBBVkiD7EBIixlIjZGIAAAASIv5SIvL6Bn///9IjZfEAAAASIvLSIvw6Af///9IjZecAAAASIvLSIvo6PX+//9Mi/BIhfZ0ZUiF7XRgSIXAdFtEi08YSI0VoPv//0UzwEGNSAT/1kiL8EiFwHUFjUYC6z+LVxwzwEiLTxBFM8lIiUQkMEUzwMdEJCjIAAAAiUQkIP/VSIvOSIvYQf/WSIXbdQWNQwPrCotHIOsFuAEAAABIi1wkUEiLbCRYSIt0JGBIi3wkaEiDxEBBXsM="
            else
                shellcodeBase64 := "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAGuemlKHZSNPq56cfWg+PFAB6ICqISDSEZPgAGCwZ7huU2V0V2luZG93c0hvb2tFeFcAAABVbmhvb2tXaW5kb3dzSG9va0V4AENhbGxOZXh0SG9va0V4AAAAAAAAU2VuZE1lc3NhZ2VUaW1lb3V0VwBDb0NyZWF0ZUluc3RhbmNlAAAAAFZX6MkCAACDfCQMAIvwi3wkFHwYhf90FItPCDtOEHUMVuhqAQAAg8QEiUYUjYaIAAAAUP826J4CAACDxAiFwHUFX17CDABX/3QkFP90JBRqAP/QX17CDAAzwMIEAMzMzIPsFFaLdCQchfZ1DLhXAAeAXoPEFMIIAItOBI1UJARSjVQkEMdEJAgAAAAAUosBagFq//90JDBR/1AUhcB4bIN8JAwAdGWDfCQEAHRei04EjVQkHFfHRCQgAAAAAFKLAVH/UCSL+IX/eC2LVCQghdJ0JYsCi0gQjUQkDFCNRghQ/3QkGP90JDBS/9GL+ItEJCBQiwj/UQiLRCQQUIsI/1EIi8dfXoPEFMIIALgBAAAAXoPEFMIIAMyLTCQIVot0JAiF9nRfhcl0W4tUJBCF0nRTiwELQQR1IYF5CMAAAAB1CYF5DAAAAEZ0MscCAAAAALgCQACAXsIMAIE5A+iAqnXpgXkEISDSEXXggXkIk+AAYHXXgXkMsGe4bnXOiTIzwF7CDAC4VwAHgF7CDADMzMyD7BBWi3QkGI2GsAAAAFD/dgToMQEAAIvIg8QIhcl1CI1BAV6DxBDDjUQkBMdEJAQAAAAAUI1GUMdEJBwAAAAAUGoXagCNRkDHRCQYAAAAAFDHRCQgAAAAAMdEJCQBAAAA/9GFwA+IywAAAItMJASFyQ+EvwAAAIsBjVQkDFdSUf9QDIXAeHCLTCQIjVQkHFJRiwH/UByFwHhdi0wkHIXJdFmLAY1UJAxSUf9QGIXAeEaLfCQMhf90UI1OMIl+HLjcAQAAiU4YA8aNVhiJAYvGBRwBAACNTCQUUYlGNIlGOLgkAQAAagMDxlL/dCQciUY8iwdX/1AMi0wkHItUJAyF0nQKiwJS/1AIi0wkHF+FyXQGiwFR/1AIi0wkBIXJdAaLAVH/UAiLRCQQ99heG8CD4ASDxBDDuAQAAABeg8QQw7gAAAAAw8zMg+wIU1VWV4t8JByF/w+EgQAAAItcJCCF23R5i0c8g3w4fAB0b4tEOHiFwHRni0w4JDP2i1Q4IAPPi2w4GAPXiUwkEItMOBwDz4lUJByJTCQUTYorixSyA9c6KnUTis2LwyvThMl0FIpIAUA6DAJ080Y79Xcfi1QkHOvZi0QkEItMJBQPtwRwiwSBA8dfXl1bg8QIw19eXTPAW4PECMPMzFNVVleLfCQUizeNR2BQVuhM////iUQkHI2HnAAAAFBW6Dv///+L2I1HdFBW6C////+LTCQsg8QYi+iFyXRshdt0aIXtdGSLxwWUAwAAiXgBuMQAAAD/dwwDx2oAUGoE/9GJRCQUhcB1DF9eXbgCAAAAW8IEAGoAaMgAAABqAGoAagD/dxD/dwj/0/90JBSL8P/VhfZ1Cl+NRgNeXVvCBACLRxRfXl1bwgQAX15duAEAAABbwgQA"
            len := StrLen(shellcodeBase64)
            shellcode := Buffer(len * 0.75)
            if !DllCall("crypt32\CryptStringToBinary", "str", shellcodeBase64, "uint", len, "uint", 1, "ptr", shellcode, "uint*", shellcode.Size, "ptr", 0, "ptr", 0)
                return
            return shellcode
        }

        static link(x64, shellcode, shellcodeBase, user32Base, combaseBase, hwnd, tid, msg, &pThreadProc, &pRect) {
            if x64 {
                NumPut("uint64", user32Base, shellcode, 0)
                NumPut("uint64", combaseBase, shellcode, 8)
                NumPut("uint64", hwnd, shellcode, 16)
                NumPut("uint", tid, shellcode, 24)
                NumPut("uint", msg, shellcode, 28)
                pThreadProc := shellcodeBase + 0x4e0
                pRect := shellcodeBase + 56
            }
            else {
                NumPut("uint", user32Base, shellcode, 0)
                NumPut("uint", combaseBase, shellcode, 4)
                NumPut("uint", hwnd, shellcode, 8)
                NumPut("uint", tid, shellcode, 12)
                NumPut("uint", msg, shellcode, 16)
                pThreadProc := shellcodeBase + 0x43c
                pRect := shellcodeBase + 32
            }
        }

        static msgWaitForSingleObject(handle) {
            while 1 == res := DllCall("MsgWaitForMultipleObjects", "uint", 1, "ptr*", handle, "int", false, "uint", -1, "uint", 7423) {
                msg := Buffer(A_PtrSize == 8 ? 48 : 28)
                while DllCall("PeekMessageW", "ptr", msg, "ptr", 0, "uint", 0, "uint", 0, "uint", 1) {
                    DllCall("TranslateMessage", "ptr", msg)
                    DllCall("DispatchMessageW", "ptr", msg)
                }
            }
            return res
        }
    }

    static guidFromString(str) {
        DllCall("ole32\CLSIDFromString", "str", str, "ptr", buf := Buffer(16), "hresult")
        return buf
    }

    static getRect(buf, &left, &top, &right, &bottom) {
        left := NumGet(buf, 0, "int")
        top := NumGet(buf, 4, "int")
        right := NumGet(buf, 8, "int")
        bottom := NumGet(buf, 12, "int")
    }

    static getWindowScale(hwnd) {
        if winDpi := DllCall("GetDpiForWindow", "ptr", hwnd, "uint")
            return A_ScreenDPI / winDpi
        return 1
    }

    static scaleRect(scale, &left, &top, &right, &bottom) {
        left := Round(left * scale)
        top := Round(top * scale)
        right := Round(right * scale)
        bottom := Round(bottom * scale)
    }

    static clientToScreenRect(hwnd, &left, &top, &right, &bottom) {
        w := right - left
        h := bottom - top
        pt := left | top << 32
        DllCall("ClientToScreen", "ptr", hwnd, "int64*", &pt)
        left := pt & 0xffffffff
        top := pt >> 32
        right := left + w
        bottom := top + h
    }
}

; =================================================
;  Config
; =================================================
; 面板宽高（基准像素，可直接改；实际尺寸会按屏幕高度微调）
UI_W := 360
UI_H := 425   ; 原 485，减 60
; UI / disk page size: each NDJSON shard holds at most this many records
PAGE_SIZE    := 50
; First paint / load-more chunk shown in the panel (per tab)
VIEW_PAGE_SIZE := 40
; 进「全部」首屏只取这么多，其它 tab 不预热（按需 SetView）
FIRST_PAINT_SIZE := 20
; Clipboard screenshots (type=image) retention; file-copy thumbs (type=file / fimg_*) are permanent
MAX_SCREENSHOTS := 100
; Data root: prefer HELPME_HOME (synced runtime); else script-local data\clip_v1
CLIP_V1_DIR  := ResolveClipV1Dir()
HTML_FILE    := CLIP_V1_DIR "\index.html"
SAVE_FILE    := CLIP_V1_DIR "\clips.json"          ; legacy (migrated once)
PAGES_DIR    := CLIP_V1_DIR "\clips_pages"
MANIFEST_FILE := PAGES_DIR "\manifest.json"
STORE_DIR    := CLIP_V1_DIR "\clips_store"
PAYLOAD_DIR  := CLIP_V1_DIR "\clips_payloads"
PAYLOAD_INLINE_MAX := 4000   ; larger text/link bodies go to external files
STORE_HOST   := "clips.store"
; 禁止用 *.local —— Windows mDNS 会卡 ~2–3s（与 HTML 大小无关）
APP_HOST     := "clipui.app"
; Navigate cache key —固定版本；禁止每次启动用 mtime/A_Now 逼全量重载
UI_CACHE_VER := "20260922-emoji-enter"
DEBUG_LOG    := CLIP_V1_DIR "\debug.log"
ERROR_LOG    := CLIP_V1_DIR "\error.log"
QUEUE_STATE_FILE := CLIP_V1_DIR "\paste_queue.json"
QUEUE_META_FILE  := CLIP_V1_DIR "\queue_meta.tsv"   ; uid -> group/index (sync, survives restart)
RECENT_FOLDERS_FILE := CLIP_V1_DIR "\recent_folders.json"
MAX_RECENT_FOLDERS := 20
; HELPME_HOME set →%HELPME_HOME%\command_ext\ahk_ext\data\clip_v1
; otherwise →%A_ScriptDir%\data\clip_v1
; 兼容旧路径 ahk\clip_v1：新目录空时一次性迁入
ResolveAhkExtDataRoot() {
    home := ""
    try home := EnvGet("HELPME_HOME")
    home := Trim(String(home))
    if home != "" {
        home := RTrim(home, "\/")
        dir := home "\command_ext\ahk_ext\data"
        try DirCreate dir
        return dir
    }
    dir := A_ScriptDir "\data"
    try DirCreate dir
    return dir
}

ResolveClipV1Dir() {
    root := ResolveAhkExtDataRoot()
    dir := root "\clip_v1"
    try DirCreate dir
    legacy := ""
    home := ""
    try home := EnvGet("HELPME_HOME")
    home := Trim(String(home))
    if home != ""
        legacy := RTrim(home, "\/") "\command_ext\ahk_ext\ahk\clip_v1"
    else
        legacy := A_ScriptDir "\ahk\clip_v1"
    MigrateLegacyDataDir(legacy, dir)
    return dir
}

; 目标为空且旧目录有内容时，整体迁入（避免 HELPME 上旧数据丢失）
MigrateLegacyDataDir(legacy, preferred) {
    if legacy = "" || legacy = preferred || !DirExist(legacy)
        return
    if FileExist(preferred "\index.html")
        return
    hasLegacy := FileExist(legacy "\index.html")
    if !hasLegacy {
        try {
            loop files legacy "\*.*", "F" {
                hasLegacy := true
                break
            }
        }
    }
    if !hasLegacy
        return
    empty := true
    try {
        loop files preferred "\*.*", "FDR" {
            empty := false
            break
        }
    }
    if !empty
        return
    try DirMove(legacy, preferred, "R")
    catch {
        try {
            DirCopy(legacy, preferred, 1)
        }
    }
}

; ── Crash diagnostics: last line in debug.log  ≈ where it died ──
ClipLog(msg) {
    global DEBUG_LOG, CLIP_V1_DIR
    static seq := 0
    try {
        if !DirExist(CLIP_V1_DIR)
            DirCreate CLIP_V1_DIR
        seq += 1
        line := FormatTime(, "yyyy-MM-dd HH:mm:ss.") SubStr("000" Mod(A_TickCount, 1000), -2)
            . " [" A_TickCount "] #" seq " " String(msg) "`n"
        ; FileOpen+Write flushes better than FileAppend on hard kill
        f := FileOpen(DEBUG_LOG, "a", "UTF-8")
        if IsObject(f) {
            f.Write(line)
            f.Close()
        }
    } catch {
    }
}

ClipLogErr(where, e) {
    global ERROR_LOG
    msg := where ": " (IsObject(e) ? e.Message " @ " e.File ":" e.Line : String(e))
    ClipLog("ERR " msg)
    try FileAppend(FormatTime() " " msg "`n", ERROR_LOG, "UTF-8")
}

; First-open timeline: +Nms from first ShowPanel (or reset)
PerfMark(stage) {
    global firstOpenT0, DEBUG_LOG
    if !IsSet(firstOpenT0) || firstOpenT0 < 1
        firstOpenT0 := A_TickCount
    dt := A_TickCount - firstOpenT0
    ClipLog("PERF +" dt "ms " String(stage))
}

PerfReset(*) {
    global firstOpenT0
    firstOpenT0 := A_TickCount
    ClipLog("PERF RESET t0=" firstOpenT0)
}

; =================================================
;  内嵌 HTML（backtick 已转义为 ``）
; =================================================
HTML_B64 := "
(
PCFET0NUWVBFIGh0bWw+DQo8aHRtbCBsYW5nPSJ6aC1DTiI+DQo8aGVhZD4NCiAgICA8bWV0YSBj
aGFyc2V0PSJVVEYtOCI+DQogICAgPHRpdGxlPuWJqui0tOadvzwvdGl0bGU+DQogICAgPHN0eWxl
Pg0KICAgICAgICA6cm9vdCB7DQogICAgICAgICAgICAtLWJnOiAgICAgI2VlZjFmNjsNCiAgICAg
ICAgICAgIC0tYWNjOiAgICAjNWI3M2U4Ow0KICAgICAgICAgICAgLS10eHQ6ICAgICMyYzJlMzY7
DQogICAgICAgICAgICAtLXR4dDI6ICAgIzZiNzA4MDsNCiAgICAgICAgICAgIC0tdHh0MzogICAj
OWFhMGIwOw0KICAgICAgICAgICAgLS1jYXJkOiAgICNmZmZmZmY7DQogICAgICAgICAgICAtLWNh
cmQtaDogI2Y4ZjlmYzsNCiAgICAgICAgICAgIC0tcjogICAgICA0cHg7DQogICAgICAgICAgICAt
LXRyOiAgICAgMC4xMnMgZWFzZTsNCiAgICAgICAgfQ0KICAgICAgICAqLCAqOjpiZWZvcmUsICo6
OmFmdGVyIHsgYm94LXNpemluZzogYm9yZGVyLWJveDsgbWFyZ2luOiAwOyBwYWRkaW5nOiAwOyB9
DQogICAgICAgIGh0bWwsIGJvZHkgew0KICAgICAgICAgICAgd2lkdGg6IDEwMCU7IGhlaWdodDog
MTAwJTsgb3ZlcmZsb3c6IGhpZGRlbjsNCiAgICAgICAgICAgIGJhY2tncm91bmQ6IHZhcigtLWJn
KTsgY29sb3I6IHZhcigtLXR4dCk7DQogICAgICAgICAgICBmb250OiAxMnB4LzEuNDUgJ1NlZ29l
IFVJJywnTWljcm9zb2Z0IFlhSGVpIFVJJyxzeXN0ZW0tdWksc2Fucy1zZXJpZjsNCiAgICAgICAg
ICAgIHVzZXItc2VsZWN0OiBub25lOw0KICAgICAgICAgICAgem9vbTogMTsNCiAgICAgICAgICAg
IHRvdWNoLWFjdGlvbjogcGFuLXggcGFuLXk7DQogICAgICAgIH0NCiAgICAgICAgOjotd2Via2l0
LXNjcm9sbGJhciB7IHdpZHRoOiA1cHg7IH0NCiAgICAgICAgOjotd2Via2l0LXNjcm9sbGJhci10
aHVtYiB7IGJhY2tncm91bmQ6ICNjNWM5ZDQ7IGJvcmRlci1yYWRpdXM6IDNweDsgfQ0KICAgICAg
ICA6Oi13ZWJraXQtc2Nyb2xsYmFyLXRodW1iOmhvdmVyIHsgYmFja2dyb3VuZDogI2FlYjNjMDsg
fQ0KICAgICAgICA6Oi13ZWJraXQtc2Nyb2xsYmFyLXRyYWNrIHsgYmFja2dyb3VuZDogdHJhbnNw
YXJlbnQ7IH0NCg0KICAgICAgICAjYXBwIHsNCiAgICAgICAgICAgIGhlaWdodDogMTAwJTsgZGlz
cGxheTogZmxleDsgZmxleC1kaXJlY3Rpb246IGNvbHVtbjsNCiAgICAgICAgICAgIGJhY2tncm91
bmQ6IGxpbmVhci1ncmFkaWVudCgxODBkZWcsICNmN2Y5ZmMgMCUsICNlZWYxZjYgMTAwJSk7DQog
ICAgICAgICAgICAtd2Via2l0LWFwcC1yZWdpb246IGRyYWc7IGFwcC1yZWdpb246IGRyYWc7DQog
ICAgICAgICAgICBwb3NpdGlvbjogcmVsYXRpdmU7DQogICAgICAgICAgICBvdmVyZmxvdzogaGlk
ZGVuOw0KICAgICAgICB9DQoNCiAgICAgICAgLyog4pSA4pSAIFJvdyAxIOKUgOKUgOKUgOKUgOKU
gOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKU
gOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgCAqLw0KICAgICAg
ICAjaGRyIHsNCiAgICAgICAgICAgIGRpc3BsYXk6IGZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7
IGZsZXgtc2hyaW5rOiAwOw0KICAgICAgICAgICAgcGFkZGluZzogNXB4IDRweCA1cHggNnB4OyBn
YXA6IDRweDsNCiAgICAgICAgICAgIGJhY2tncm91bmQ6ICNmMmY0Zjk7DQogICAgICAgIH0NCiAg
ICAgICAgI2hlYXJ0IHsgZmxleC1zaHJpbms6IDA7IGxpbmUtaGVpZ2h0OiAxOyBkaXNwbGF5OmZs
ZXg7IGFsaWduLWl0ZW1zOmNlbnRlcjsgfQ0KICAgICAgICAjaGVhcnQgc3ZnIHsgd2lkdGg6MTdw
eDsgaGVpZ2h0OjE3cHg7IGNvbG9yOiB2YXIoLS10eHQyKTsgfQ0KICAgICAgICAjaGRyLWdyb3cg
eyBmbGV4OiAxOyBtaW4td2lkdGg6IDhweDsgfQ0KDQogICAgICAgIC8qIFNlYXJjaDogb3Zlcmxh
eSBleHBhbmQgKHRyYW5zZm9ybS9vcGFjaXR5IG9ubHkg4oCUIG5vIHdpZHRoIGxheW91dCB0aHJh
c2gpICovDQogICAgICAgICNzZWFyY2gtd3JhcCB7DQogICAgICAgICAgICBmbGV4OiAwIDAgMjhw
eDsNCiAgICAgICAgICAgIHdpZHRoOiAyOHB4Ow0KICAgICAgICAgICAgaGVpZ2h0OiAyOHB4Ow0K
ICAgICAgICAgICAgcG9zaXRpb246IHJlbGF0aXZlOw0KICAgICAgICAgICAgei1pbmRleDogNjsN
CiAgICAgICAgICAgIC13ZWJraXQtYXBwLXJlZ2lvbjogbm8tZHJhZzsgYXBwLXJlZ2lvbjogbm8t
ZHJhZzsNCiAgICAgICAgfQ0KICAgICAgICAjYnRuLXNlYXJjaCB7DQogICAgICAgICAgICBwb3Np
dGlvbjogYWJzb2x1dGU7IHJpZ2h0OiAwOyB0b3A6IDA7DQogICAgICAgICAgICB3aWR0aDogMjhw
eDsgaGVpZ2h0OiAyOHB4Ow0KICAgICAgICAgICAgZGlzcGxheTogZmxleDsgYWxpZ24taXRlbXM6
IGNlbnRlcjsganVzdGlmeS1jb250ZW50OiBjZW50ZXI7DQogICAgICAgICAgICBib3JkZXI6IG5v
bmU7IGJhY2tncm91bmQ6IG5vbmU7IGN1cnNvcjogcG9pbnRlcjsNCiAgICAgICAgICAgIGNvbG9y
OiB2YXIoLS10eHQzKTsgYm9yZGVyLXJhZGl1czogdmFyKC0tcik7DQogICAgICAgICAgICB6LWlu
ZGV4OiAyOw0KICAgICAgICAgICAgdHJhbnNpdGlvbjogY29sb3IgMC4xNXMgZWFzZSwgYmFja2dy
b3VuZCAwLjE1cyBlYXNlLCBvcGFjaXR5IDAuMTVzIGVhc2U7DQogICAgICAgIH0NCiAgICAgICAg
I2J0bi1zZWFyY2g6aG92ZXIgeyBjb2xvcjogdmFyKC0tYWNjKTsgYmFja2dyb3VuZDogcmdiYSg5
MSwxMTUsMjMyLC4xKTsgfQ0KICAgICAgICAjYnRuLXNlYXJjaCBzdmcgeyB3aWR0aDogMTVweDsg
aGVpZ2h0OiAxNXB4OyBkaXNwbGF5OiBibG9jazsgfQ0KICAgICAgICAjc2VhcmNoLXdyYXAub3Bl
biAjYnRuLXNlYXJjaCB7DQogICAgICAgICAgICBvcGFjaXR5OiAwOw0KICAgICAgICAgICAgcG9p
bnRlci1ldmVudHM6IG5vbmU7DQogICAgICAgIH0NCg0KICAgICAgICAjc2VhcmNoLWJveCB7DQog
ICAgICAgICAgICB0cmFuc2Zvcm0tb3JpZ2luOiByaWdodCBjZW50ZXI7DQogICAgICAgICAgICBw
b3NpdGlvbjogYWJzb2x1dGU7DQogICAgICAgICAgICByaWdodDogMDsNCiAgICAgICAgICAgIHRv
cDogMDsNCiAgICAgICAgICAgIHdpZHRoOiAxOTZweDsNCiAgICAgICAgICAgIGhlaWdodDogMjhw
eDsNCiAgICAgICAgICAgIGJveC1zaXppbmc6IGJvcmRlci1ib3g7DQogICAgICAgICAgICBwYWRk
aW5nOiAwIDJweCAwIDJweDsNCiAgICAgICAgICAgIGJhY2tncm91bmQ6IHRyYW5zcGFyZW50Ow0K
ICAgICAgICAgICAgYm9yZGVyOiBub25lOw0KICAgICAgICAgICAgYm9yZGVyLXJhZGl1czogMDsN
CiAgICAgICAgICAgIG9wYWNpdHk6IDA7DQogICAgICAgICAgICB0cmFuc2Zvcm06IHRyYW5zbGF0
ZTNkKDhweCwgMCwgMCkgc2NhbGUoMC45ODUpOw0KICAgICAgICAgICAgcG9pbnRlci1ldmVudHM6
IG5vbmU7DQogICAgICAgICAgICBkaXNwbGF5OiBmbGV4Ow0KICAgICAgICAgICAgYWxpZ24taXRl
bXM6IGNlbnRlcjsNCiAgICAgICAgICAgIGdhcDogNHB4Ow0KICAgICAgICAgICAgd2lsbC1jaGFu
Z2U6IHRyYW5zZm9ybSwgb3BhY2l0eTsNCiAgICAgICAgICAgIGJhY2tmYWNlLXZpc2liaWxpdHk6
IGhpZGRlbjsNCiAgICAgICAgICAgIHRyYW5zaXRpb246IG9wYWNpdHkgMC4xOHMgZWFzZSwgdHJh
bnNmb3JtIDAuMjRzIGN1YmljLWJlemllcigwLjE2LCAxLCAwLjMsIDEpOw0KICAgICAgICB9DQog
ICAgICAgICNzZWFyY2gtd3JhcC5vcGVuICNzZWFyY2gtYm94IHsNCiAgICAgICAgICAgIHRyYW5z
Zm9ybS1vcmlnaW46IHJpZ2h0IGNlbnRlcjsNCiAgICAgICAgICAgIHRyYW5zZm9ybS1vcmlnaW46
IHJpZ2h0IGNlbnRlcjsNCiAgICAgICAgICAgIG9wYWNpdHk6IDE7DQogICAgICAgICAgICB0cmFu
c2Zvcm06IHRyYW5zbGF0ZTNkKDAsIDAsIDApOw0KICAgICAgICAgICAgcG9pbnRlci1ldmVudHM6
IGF1dG87DQogICAgICAgIH0NCg0KICAgICAgICAjc2VhcmNoIHsNCiAgICAgICAgICAgIGZsZXg6
IDE7IG1pbi13aWR0aDogMDsgaGVpZ2h0OiAyOHB4OyBib3JkZXI6IG5vbmU7DQogICAgICAgICAg
ICBib3JkZXItYm90dG9tOiAxcHggc29saWQgdHJhbnNwYXJlbnQ7DQogICAgICAgICAgICBib3Jk
ZXItcmFkaXVzOiAwOyBiYWNrZ3JvdW5kOiB0cmFuc3BhcmVudDsgY29sb3I6IHZhcigtLXR4dCk7
IGZvbnQtc2l6ZTogMTJweDsNCiAgICAgICAgICAgIHBhZGRpbmc6IDAgMjJweCAwIDJweDsgb3V0
bGluZTogbm9uZTsNCiAgICAgICAgICAgIHRyYW5zaXRpb246IGJvcmRlci1ib3R0b20tY29sb3Ig
MC4xOHMgZWFzZTsNCiAgICAgICAgfQ0KICAgICAgICAjc2VhcmNoLXdyYXAub3BlbiAjc2VhcmNo
IHsNCiAgICAgICAgICAgIGJvcmRlci1ib3R0b20tY29sb3I6ICNjNWNhZDY7DQogICAgICAgIH0N
CiAgICAgICAgI3NlYXJjaC13cmFwLm9wZW4gI3NlYXJjaDpmb2N1cyB7DQogICAgICAgICAgICBi
b3JkZXItYm90dG9tLWNvbG9yOiB2YXIoLS1hY2MpOw0KICAgICAgICB9DQogICAgICAgIG1hcmsu
cS1obCB7DQogICAgICAgICAgICBiYWNrZ3JvdW5kOiByZ2JhKDI1NSwgMTk2LCAwLCAuNDIpOw0K
ICAgICAgICAgICAgY29sb3I6IGluaGVyaXQ7DQogICAgICAgICAgICBib3JkZXItcmFkaXVzOiAy
cHg7DQogICAgICAgICAgICBwYWRkaW5nOiAwIDFweDsNCiAgICAgICAgICAgIGRpc3BsYXk6IGlu
bGluZTsNCiAgICAgICAgICAgIGJveC1kZWNvcmF0aW9uLWJyZWFrOiBjbG9uZTsNCiAgICAgICAg
ICAgIC13ZWJraXQtYm94LWRlY29yYXRpb24tYnJlYWs6IGNsb25lOw0KICAgICAgICB9DQogICAg
ICAgIC8qIG1hcmsgYnJlYWtzIC13ZWJraXQtbGluZS1jbGFtcDsga2VlcCBmb2xkIHZpYSBtYXgt
aGVpZ2h0IHdoaWxlIHNlYXJjaGluZyAqLw0KICAgICAgICAuaS1wcmV2Lmhhcy1obCwgLmktbmFt
ZS5oYXMtaGwsIC5tZy1ib2R5Lmhhcy1obCwNCiAgICAgICAgLmktbGluay10aXRsZS5oYXMtaGws
IC5pLWxpbmstdXJsLmhhcy1obCwgLmktZmF2LXRpdGxlLmhhcy1obCB7DQogICAgICAgICAgICBk
aXNwbGF5OiBibG9jazsNCiAgICAgICAgICAgIC13ZWJraXQtbGluZS1jbGFtcDogdW5zZXQ7DQog
ICAgICAgICAgICBvdmVyZmxvdzogaGlkZGVuOw0KICAgICAgICB9DQogICAgICAgIC5pLXByZXYu
aGFzLWhsLCAubWctYm9keS5oYXMtaGwgeyBtYXgtaGVpZ2h0OiBjYWxjKDEuNDVlbSAqIDUpOyB9
DQogICAgICAgIC5pLW5hbWUuaGFzLWhsIHsgbWF4LWhlaWdodDogY2FsYygxLjQ1ZW0gKiAyKTsg
fQ0KICAgICAgICAuaS1saW5rLXVybC5oYXMtaGwgeyBtYXgtaGVpZ2h0OiBjYWxjKDEuNDVlbSAq
IDMpOyB9DQogICAgICAgIC5pLXByZXYuaGFzLWhsLmV4cGFuZGVkLCAuaS1uYW1lLmhhcy1obC5l
eHBhbmRlZCwNCiAgICAgICAgLm1nLWJvZHkuaGFzLWhsLmV4cGFuZGVkLCAuaS1saW5rLXVybC5o
YXMtaGwuZXhwYW5kZWQgew0KICAgICAgICAgICAgLyog5bGV5byA6auY5bqm55SxIEpTIOaOp+WI
tu+8m+S7jeijgeWIh+W5tuWcqOacq+WwvuWKoOOAjCAuLi7jgI0gKi8NCiAgICAgICAgICAgIG92
ZXJmbG93OiBoaWRkZW47DQogICAgICAgIH0NCiAgICAgICAgLmktZXhwYW5kLWJ0biwgLmktbWV0
YSB7IHVzZXItc2VsZWN0OiBub25lOyB9DQogICAgICAgICNzZWFyY2g6OnBsYWNlaG9sZGVyIHsg
Y29sb3I6IHZhcigtLXR4dDMpOyB9DQogICAgICAgICNzZWFyY2gtY2xyIHsNCiAgICAgICAgICAg
IHBvc2l0aW9uOiBhYnNvbHV0ZTsgcmlnaHQ6IDRweDsgdG9wOiA1MCU7IHRyYW5zZm9ybTogdHJh
bnNsYXRlWSgtNTAlKTsNCiAgICAgICAgICAgIGJvcmRlcjogbm9uZTsgYmFja2dyb3VuZDogbm9u
ZTsgY29sb3I6IHZhcigtLXR4dDMpOyBjdXJzb3I6IHBvaW50ZXI7DQogICAgICAgICAgICBmb250
LXNpemU6IDExcHg7IGRpc3BsYXk6IG5vbmU7IHBhZGRpbmc6IDJweDsNCiAgICAgICAgICAgIG9w
YWNpdHk6IDAuODU7DQogICAgICAgICAgICB0cmFuc2l0aW9uOiBjb2xvciAwLjEycyBlYXNlLCBv
cGFjaXR5IDAuMTJzIGVhc2U7DQogICAgICAgICAgICAtd2Via2l0LWFwcC1yZWdpb246IG5vLWRy
YWc7IGFwcC1yZWdpb246IG5vLWRyYWc7DQogICAgICAgIH0NCiAgICAgICAgI3NlYXJjaC1jbHI6
aG92ZXIgeyBjb2xvcjogdmFyKC0tYWNjKTsgb3BhY2l0eTogMTsgfQ0KDQogICAgICAgICNidG4t
dG9kYXkgew0KICAgICAgICAgICAgZGlzcGxheTogbm9uZTsNCiAgICAgICAgICAgIGhlaWdodDog
MThweDsgcGFkZGluZzogMCA3cHg7IGZsZXgtc2hyaW5rOiAwOw0KICAgICAgICAgICAgYWxpZ24t
aXRlbXM6IGNlbnRlcjsganVzdGlmeS1jb250ZW50OiBjZW50ZXI7DQogICAgICAgICAgICBib3Jk
ZXI6IDFweCBzb2xpZCByZ2JhKDkxLDExNSwyMzIsLjIyKTsgYmFja2dyb3VuZDogcmdiYSg5MSwx
MTUsMjMyLC4xMCk7DQogICAgICAgICAgICBjb2xvcjogIzZiODJlODsgYm9yZGVyLXJhZGl1czog
OTk5cHg7IGZvbnQtc2l6ZTogOXB4OyBmb250LXdlaWdodDogNjAwOw0KICAgICAgICAgICAgbGlu
ZS1oZWlnaHQ6IDE7IHdoaXRlLXNwYWNlOiBub3dyYXA7IGN1cnNvcjogcG9pbnRlcjsNCiAgICAg
ICAgICAgIC13ZWJraXQtYXBwLXJlZ2lvbjogbm8tZHJhZzsgYXBwLXJlZ2lvbjogbm8tZHJhZzsN
CiAgICAgICAgICAgIHRyYW5zaXRpb246IGNvbG9yIHZhcigtLXRyKSwgYmFja2dyb3VuZCB2YXIo
LS10ciksIGJvcmRlci1jb2xvciB2YXIoLS10ciksIG9wYWNpdHkgdmFyKC0tdHIpOw0KICAgICAg
ICB9DQogICAgICAgICNzZWFyY2gtd3JhcC5vcGVuICNidG4tdG9kYXkgeyBkaXNwbGF5OiBpbmxp
bmUtZmxleDsgfQ0KICAgICAgICAjYnRuLXRvZGF5OmhvdmVyIHsgY29sb3I6ICM0YTYyZDQ7IGJh
Y2tncm91bmQ6IHJnYmEoOTEsMTE1LDIzMiwuMTYpOyB9DQogICAgICAgICNidG4tdG9kYXkub24g
ew0KICAgICAgICAgICAgY29sb3I6ICM1YjczZTg7DQogICAgICAgICAgICBiYWNrZ3JvdW5kOiBy
Z2JhKDkxLDExNSwyMzIsLjE2KTsNCiAgICAgICAgICAgIGJvcmRlci1jb2xvcjogcmdiYSg5MSwx
MTUsMjMyLC4zMik7DQogICAgICAgIH0NCiAgICAgICAgI2J0bi10b2RheTpub3QoLm9uKSB7DQog
ICAgICAgICAgICBjb2xvcjogdmFyKC0tdHh0Myk7DQogICAgICAgICAgICBiYWNrZ3JvdW5kOiBy
Z2JhKDAsMCwwLC4wNCk7DQogICAgICAgICAgICBib3JkZXItY29sb3I6IHJnYmEoMCwwLDAsLjA2
KTsNCiAgICAgICAgfQ0KDQogICAgICAgICNidG4tcGluIHsNCiAgICAgICAgICAgIGRpc3BsYXk6
IGZsZXg7DQogICAgICAgICAgICB3aWR0aDogMjhweDsgaGVpZ2h0OiAyOHB4OyBmbGV4LXNocmlu
azogMDsNCiAgICAgICAgICAgIGFsaWduLWl0ZW1zOiBjZW50ZXI7IGp1c3RpZnktY29udGVudDog
Y2VudGVyOw0KICAgICAgICAgICAgYm9yZGVyOiAxLjVweCBzb2xpZCB0cmFuc3BhcmVudDsgYmFj
a2dyb3VuZDogbm9uZTsgY3Vyc29yOiBwb2ludGVyOw0KICAgICAgICAgICAgY29sb3I6IHZhcigt
LXR4dDMpOyBib3JkZXItcmFkaXVzOiB2YXIoLS1yKTsNCiAgICAgICAgICAgIC13ZWJraXQtYXBw
LXJlZ2lvbjogbm8tZHJhZzsgYXBwLXJlZ2lvbjogbm8tZHJhZzsNCiAgICAgICAgICAgIHRyYW5z
aXRpb246IGNvbG9yIHZhcigtLXRyKSwgYmFja2dyb3VuZCB2YXIoLS10ciksIGJvcmRlci1jb2xv
ciB2YXIoLS10cik7DQogICAgICAgIH0NCiAgICAgICAgI2J0bi1waW46aG92ZXIgeyBjb2xvcjog
dmFyKC0tYWNjKTsgYmFja2dyb3VuZDogcmdiYSg5MSwxMTUsMjMyLC4xKTsgfQ0KICAgICAgICAj
YnRuLXBpbi5vbiAgew0KICAgICAgICAgICAgY29sb3I6IHZhcigtLWFjYyk7DQogICAgICAgICAg
ICBiYWNrZ3JvdW5kOiByZ2JhKDkxLDExNSwyMzIsLjE4KTsNCiAgICAgICAgICAgIGJvcmRlci1j
b2xvcjogcmdiYSg5MSwxMTUsMjMyLC41NSk7DQogICAgICAgIH0NCiAgICAgICAgI2J0bi1waW4g
c3ZnIHsgd2lkdGg6IDE0cHg7IGhlaWdodDogMTRweDsgZGlzcGxheTogYmxvY2s7IH0NCg0KICAg
ICAgICAjYnRuLWxvY2F0ZSB7DQogICAgICAgICAgICB3aWR0aDogMjhweDsgaGVpZ2h0OiAyOHB4
OyBmbGV4LXNocmluazogMDsNCiAgICAgICAgICAgIGRpc3BsYXk6IGZsZXg7IGFsaWduLWl0ZW1z
OiBjZW50ZXI7IGp1c3RpZnktY29udGVudDogY2VudGVyOw0KICAgICAgICAgICAgYm9yZGVyOiBu
b25lOyBiYWNrZ3JvdW5kOiBub25lOyBjdXJzb3I6IHBvaW50ZXI7DQogICAgICAgICAgICBjb2xv
cjogdmFyKC0tdHh0Myk7IGJvcmRlci1yYWRpdXM6IHZhcigtLXIpOw0KICAgICAgICAgICAgLXdl
YmtpdC1hcHAtcmVnaW9uOiBuby1kcmFnOyBhcHAtcmVnaW9uOiBuby1kcmFnOw0KICAgICAgICAg
ICAgdHJhbnNpdGlvbjogY29sb3IgdmFyKC0tdHIpLCBiYWNrZ3JvdW5kIHZhcigtLXRyKSwgb3Bh
Y2l0eSB2YXIoLS10cik7DQogICAgICAgIH0NCiAgICAgICAgI2J0bi1sb2NhdGU6aG92ZXI6bm90
KDpkaXNhYmxlZCkgeyBjb2xvcjogdmFyKC0tYWNjKTsgYmFja2dyb3VuZDogcmdiYSg5MSwxMTUs
MjMyLC4xKTsgfQ0KICAgICAgICAjYnRuLWxvY2F0ZTpkaXNhYmxlZCB7IG9wYWNpdHk6IC4zNTsg
Y3Vyc29yOiBkZWZhdWx0OyB9DQogICAgICAgICNidG4tbG9jYXRlLmhhcy10YXJnZXQgeyBjb2xv
cjogdmFyKC0tYWNjKTsgfQ0KICAgICAgICAjYnRuLWxvY2F0ZS5vbiB7DQogICAgICAgICAgICBj
b2xvcjogdmFyKC0tYWNjKTsNCiAgICAgICAgICAgIGJhY2tncm91bmQ6IHJnYmEoOTEsMTE1LDIz
MiwuMTgpOw0KICAgICAgICB9DQogICAgICAgICNidG4tbG9jYXRlIHN2ZyB7IHdpZHRoOiAxNXB4
OyBoZWlnaHQ6IDE1cHg7IGRpc3BsYXk6IGJsb2NrOyB9DQogICAgICAgICNoZHI6aGFzKCNzZWFy
Y2gtd3JhcC5vcGVuKSAjYnRuLWxvY2F0ZSB7DQogICAgICAgICAgICBkaXNwbGF5OiBub25lOw0K
ICAgICAgICB9DQoNCiAgICAgICAgLyog4pSA4pSAIFJvdyAyIOKUgOKUgOKUgOKUgOKUgOKUgOKU
gOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKU
gOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgCAqLw0KICAgICAgICAjdGFi
cyB7DQogICAgICAgICAgICBwb3NpdGlvbjogcmVsYXRpdmU7DQogICAgICAgICAgICBkaXNwbGF5
OiBmbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBnYXA6IDJweDsgZmxleC13cmFwOiBub3dyYXA7
DQogICAgICAgICAgICBwYWRkaW5nOiA1cHggNHB4IDVweCA2cHg7IGZsZXgtc2hyaW5rOiAwOw0K
ICAgICAgICAgICAgYmFja2dyb3VuZDogI2YyZjRmOTsNCiAgICAgICAgICAgIG1pbi13aWR0aDog
MDsNCiAgICAgICAgfQ0KICAgICAgICAjdGFiLWluayB7DQogICAgICAgICAgICBwb3NpdGlvbjog
YWJzb2x1dGU7DQogICAgICAgICAgICBsZWZ0OiAwOyB0b3A6IDA7DQogICAgICAgICAgICBoZWln
aHQ6IDIycHg7DQogICAgICAgICAgICBib3JkZXItcmFkaXVzOiA5OTlweDsNCiAgICAgICAgICAg
IGJhY2tncm91bmQ6ICNmZmY7DQogICAgICAgICAgICBib3gtc2hhZG93OiAwIDFweCAzcHggcmdi
YSgwLDAsMCwuMDcpLCAwIDAgMCAxcHggcmdiYSg5MSwxMTUsMjMyLC4wNik7DQogICAgICAgICAg
ICBwb2ludGVyLWV2ZW50czogbm9uZTsNCiAgICAgICAgICAgIHotaW5kZXg6IDA7DQogICAgICAg
ICAgICB0cmFuc2Zvcm06IHRyYW5zbGF0ZTNkKDAsMCwwKSBzY2FsZVgoMSk7DQogICAgICAgICAg
ICB0cmFuc2Zvcm0tb3JpZ2luOiBjZW50ZXIgYm90dG9tOw0KICAgICAgICAgICAgdHJhbnNpdGlv
bjoNCiAgICAgICAgICAgICAgICB0cmFuc2Zvcm0gMC4zNHMgY3ViaWMtYmV6aWVyKDAuMjIsIDEu
MTgsIDAuMzIsIDEpLA0KICAgICAgICAgICAgICAgIGhlaWdodCAwLjI0cyBlYXNlOw0KICAgICAg
ICAgICAgd2lsbC1jaGFuZ2U6IHRyYW5zZm9ybSwgaGVpZ2h0Ow0KICAgICAgICB9DQogICAgICAg
ICN0YWItaW5rLnNxdWFzaCB7DQogICAgICAgICAgICB0cmFuc2l0aW9uOg0KICAgICAgICAgICAg
ICAgIHRyYW5zZm9ybSAwLjMwcyBjdWJpYy1iZXppZXIoMC4zNCwgMS4yOCwgMC40NCwgMSksDQog
ICAgICAgICAgICAgICAgaGVpZ2h0IDAuMjBzIGVhc2U7DQogICAgICAgIH0NCiAgICAgICAgLnRh
YiB7DQogICAgICAgICAgICBwb3NpdGlvbjogcmVsYXRpdmU7DQogICAgICAgICAgICB6LWluZGV4
OiAxOw0KICAgICAgICAgICAgcGFkZGluZzogM3B4IDlweDsgZm9udC1zaXplOiAxMXB4OyBjb2xv
cjogdmFyKC0tdHh0Mik7IGN1cnNvcjogcG9pbnRlcjsNCiAgICAgICAgICAgIGJvcmRlci1yYWRp
dXM6IDk5OXB4OyB3aGl0ZS1zcGFjZTogbm93cmFwOw0KICAgICAgICAgICAgYmFja2dyb3VuZDog
dHJhbnNwYXJlbnQ7DQogICAgICAgICAgICBmbGV4OiAwIDAgYXV0bzsNCiAgICAgICAgICAgIHRy
YW5zaXRpb246IGNvbG9yIDAuMjhzIGN1YmljLWJlemllcigwLjIyLCAxLCAwLjM2LCAxKSwNCiAg
ICAgICAgICAgICAgICAgICAgICAgIHRyYW5zZm9ybSAwLjI4cyBjdWJpYy1iZXppZXIoMC4yMiwg
MSwgMC4zNiwgMSk7DQogICAgICAgICAgICAtd2Via2l0LWFwcC1yZWdpb246IG5vLWRyYWc7IGFw
cC1yZWdpb246IG5vLWRyYWc7DQogICAgICAgIH0NCiAgICAgICAgLnRhYjpob3ZlciB7IGNvbG9y
OiB2YXIoLS10eHQpOyBiYWNrZ3JvdW5kOiB0cmFuc3BhcmVudDsgfQ0KICAgICAgICAudGFiOmFj
dGl2ZSB7IHRyYW5zZm9ybTogc2NhbGUoMC45Nik7IH0NCiAgICAgICAgLnRhYi5vbiB7IGNvbG9y
OiB2YXIoLS1hY2MpOyBiYWNrZ3JvdW5kOiB0cmFuc3BhcmVudDsgYm94LXNoYWRvdzogbm9uZTsg
Zm9udC13ZWlnaHQ6IDYwMDsgfQ0KICAgICAgICAuYmFkZ2Ugew0KICAgICAgICAgICAgZGlzcGxh
eTogaW5saW5lLWZsZXg7IG1pbi13aWR0aDogMTNweDsgaGVpZ2h0OiAxM3B4OyBwYWRkaW5nOiAw
IDJweDsNCiAgICAgICAgICAgIGFsaWduLWl0ZW1zOiBjZW50ZXI7IGp1c3RpZnktY29udGVudDog
Y2VudGVyOw0KICAgICAgICAgICAgYmFja2dyb3VuZDogdmFyKC0tYWNjKTsgY29sb3I6ICNmZmY7
IGZvbnQtc2l6ZTogOXB4OyBib3JkZXItcmFkaXVzOiA3cHg7IGZvbnQtd2VpZ2h0OiA3MDA7DQog
ICAgICAgICAgICBtYXJnaW4tbGVmdDogMXB4Ow0KICAgICAgICB9DQogICAgICAgICNwaW4tZG90
IHsNCiAgICAgICAgICAgIGRpc3BsYXk6IG5vbmU7DQogICAgICAgICAgICB3aWR0aDogN3B4OyBo
ZWlnaHQ6IDdweDsNCiAgICAgICAgICAgIG1hcmdpbi1sZWZ0OiA0cHg7DQogICAgICAgICAgICBi
b3JkZXItcmFkaXVzOiA1MCU7DQogICAgICAgICAgICBiYWNrZ3JvdW5kOiAjMjJjNTVlOw0KICAg
ICAgICAgICAgYm94LXNoYWRvdzogMCAwIDAgMnB4IHJnYmEoMzQsMTk3LDk0LC4xOCk7DQogICAg
ICAgICAgICBmbGV4LXNocmluazogMDsNCiAgICAgICAgICAgIHZlcnRpY2FsLWFsaWduOiBtaWRk
bGU7DQogICAgICAgIH0NCiAgICAgICAgI3Bpbi1kb3Qub24geyBkaXNwbGF5OiBpbmxpbmUtYmxv
Y2s7IH0NCiAgICAgICAgI3RhYi1hY3Rpb25zIHsNCiAgICAgICAgICAgIG1hcmdpbi1sZWZ0OiBh
dXRvOyBkaXNwbGF5OiBmbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBnYXA6IDNweDsNCiAgICAg
ICAgICAgIGNvbG9yOiB2YXIoLS10eHQzKTsgZm9udC1zaXplOiAxMHB4Ow0KICAgICAgICAgICAg
ZmxleDogMCAwIGF1dG87DQogICAgICAgICAgICBtaW4td2lkdGg6IDA7DQogICAgICAgICAgICAt
d2Via2l0LWFwcC1yZWdpb246IG5vLWRyYWc7IGFwcC1yZWdpb246IG5vLWRyYWc7DQogICAgICAg
IH0NCiAgICAgICAgI2Jhci10eHQgeyB3aGl0ZS1zcGFjZTogbm93cmFwOyBmb250LXNpemU6IDEw
cHg7IG1heC13aWR0aDogOC41ZW07IG92ZXJmbG93OiBoaWRkZW47IHRleHQtb3ZlcmZsb3c6IGVs
bGlwc2lzOyB9DQogICAgICAgICNidG4tY2xyIHsNCiAgICAgICAgICAgIGRpc3BsYXk6IGZsZXg7
IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGp1c3RpZnktY29udGVudDogY2VudGVyOw0KICAgICAgICAg
ICAgd2lkdGg6IDI2cHg7IGhlaWdodDogMjZweDsgYm9yZGVyOiBub25lOyBiYWNrZ3JvdW5kOiBu
b25lOyBjb2xvcjogdmFyKC0tdHh0Myk7DQogICAgICAgICAgICBjdXJzb3I6IHBvaW50ZXI7IGJv
cmRlci1yYWRpdXM6IHZhcigtLXIpOw0KICAgICAgICAgICAgLXdlYmtpdC1hcHAtcmVnaW9uOiBu
by1kcmFnOyBhcHAtcmVnaW9uOiBuby1kcmFnOw0KICAgICAgICAgICAgdHJhbnNpdGlvbjogY29s
b3IgdmFyKC0tdHIpLCBiYWNrZ3JvdW5kIHZhcigtLXRyKTsNCiAgICAgICAgfQ0KICAgICAgICAj
YnRuLWNscjpob3ZlciB7IGNvbG9yOiAjZmY3YjljOyBiYWNrZ3JvdW5kOiByZ2JhKDI1NSwxMjMs
MTU2LC4wOCk7IH0NCiAgICAgICAgI2J0bi1jbHIgc3ZnIHsgd2lkdGg6IDE0cHg7IGhlaWdodDog
MTRweDsgZGlzcGxheTogYmxvY2s7IH0NCg0KICAgICAgICAvKiDilIDilIAgTGlzdCDilIDilIDi
lIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDi
lIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIAg
Ki8NCiAgICAgICAgI2xpc3Qgew0KICAgICAgICAgICAgZmxleDogMTsgb3ZlcmZsb3cteTogYXV0
bzsgb3ZlcmZsb3cteDogaGlkZGVuOw0KICAgICAgICAgICAgLyog5bemIDEwIC8g5Y+zIDXvvJrl
j7Pkvqfmu5rliqjmnaHnuqbljaAgNXB477yM6KeG6KeJ5bem5Y+z5a+56b2QICovDQogICAgICAg
ICAgICBwYWRkaW5nOiA0cHggNXB4IDRweCAxMHB4Ow0KICAgICAgICAgICAgY3Vyc29yOiBkZWZh
dWx0Ow0KICAgICAgICAgICAgLyogTVVTVCBiZSBuby1kcmFnOiBkcmFnIHJlZ2lvbiBvbiB0aGUg
c2Nyb2xsZXIgbWFrZXMgV2ViVmlldzIgc2Nyb2xsYmFyL3doZWVsIGhpdGNoICovDQogICAgICAg
ICAgICAtd2Via2l0LWFwcC1yZWdpb246IG5vLWRyYWc7IGFwcC1yZWdpb246IG5vLWRyYWc7DQog
ICAgICAgICAgICBtaW4taGVpZ2h0OiAwOw0KICAgICAgICAgICAgb3ZlcmZsb3ctYW5jaG9yOiBu
b25lOw0KICAgICAgICB9DQogICAgICAgIC8qIFdoaWxlIHNjcm9sbGluZzoga2lsbCBob3ZlciBh
bmltYXRpb25zIHRoYXQgY2F1c2UgbGF5b3V0L3BhaW50IHRocmFzaCAqLw0KICAgICAgICAjbGlz
dC5pcy1zY3JvbGxpbmcgLml0bSB7DQogICAgICAgICAgICB0cmFuc2l0aW9uOiBub25lICFpbXBv
cnRhbnQ7DQogICAgICAgIH0NCiAgICAgICAgI2xpc3QuaXMtc2Nyb2xsaW5nIC5pdG06OmJlZm9y
ZSwNCiAgICAgICAgI2xpc3QuaXMtc2Nyb2xsaW5nIC5pdG06OmFmdGVyIHsNCiAgICAgICAgICAg
IHRyYW5zaXRpb246IG5vbmUgIWltcG9ydGFudDsNCiAgICAgICAgfQ0KICAgICAgICBAa2V5ZnJh
bWVzIHRhYlBhbmVJbkxyIHsNCiAgICAgICAgICAgIGZyb20geyBvcGFjaXR5OiAwOyB0cmFuc2Zv
cm06IHRyYW5zbGF0ZVgoLTQwcHgpOyB9DQogICAgICAgICAgICB0byB7IG9wYWNpdHk6IDE7IHRy
YW5zZm9ybTogdHJhbnNsYXRlWCgwKTsgfQ0KICAgICAgICB9DQogICAgICAgIEBrZXlmcmFtZXMg
dGFiUGFuZUluUmwgew0KICAgICAgICAgICAgZnJvbSB7IG9wYWNpdHk6IDA7IHRyYW5zZm9ybTog
dHJhbnNsYXRlWCg0MHB4KTsgfQ0KICAgICAgICAgICAgdG8geyBvcGFjaXR5OiAxOyB0cmFuc2Zv
cm06IHRyYW5zbGF0ZVgoMCk7IH0NCiAgICAgICAgfQ0KICAgICAgICAjbGlzdC50YWItaW4tbHIg
eyBhbmltYXRpb246IHRhYlBhbmVJbkxyIC4zNHMgY3ViaWMtYmV6aWVyKC4yMiwgMSwgLjM2LCAx
KSBib3RoOyB9DQogICAgICAgICNsaXN0LnRhYi1pbi1ybCB7IGFuaW1hdGlvbjogdGFiUGFuZUlu
UmwgLjM0cyBjdWJpYy1iZXppZXIoLjIyLCAxLCAuMzYsIDEpIGJvdGg7IH0NCiAgICAgICAgI2J0
bi10b3Agew0KICAgICAgICAgICAgcG9zaXRpb246IGFic29sdXRlOyByaWdodDogMTBweDsgYm90
dG9tOiAxMHB4OyB6LWluZGV4OiAyMDsNCiAgICAgICAgICAgIHdpZHRoOiAyOHB4OyBoZWlnaHQ6
IDI4cHg7IGJvcmRlcjogbm9uZTsgYm9yZGVyLXJhZGl1czogNTAlOw0KICAgICAgICAgICAgZGlz
cGxheTogbm9uZTsgYWxpZ24taXRlbXM6IGNlbnRlcjsganVzdGlmeS1jb250ZW50OiBjZW50ZXI7
DQogICAgICAgICAgICBiYWNrZ3JvdW5kOiAjZmZmOyBjb2xvcjogdmFyKC0tdHh0Mik7DQogICAg
ICAgICAgICBib3gtc2hhZG93OiAwIDJweCA4cHggcmdiYSgyNCwzMiw1NiwuMTYpOw0KICAgICAg
ICAgICAgY3Vyc29yOiBwb2ludGVyOw0KICAgICAgICAgICAgLXdlYmtpdC1hcHAtcmVnaW9uOiBu
by1kcmFnOyBhcHAtcmVnaW9uOiBuby1kcmFnOw0KICAgICAgICAgICAgdHJhbnNpdGlvbjogYmFj
a2dyb3VuZCB2YXIoLS10ciksIGNvbG9yIHZhcigtLXRyKSwgYm94LXNoYWRvdyB2YXIoLS10cik7
DQogICAgICAgIH0NCiAgICAgICAgI2J0bi10b3Aub24geyBkaXNwbGF5OiBmbGV4OyB9DQogICAg
ICAgICNidG4tdG9wOmhvdmVyIHsgY29sb3I6IHZhcigtLWFjYyk7IGJhY2tncm91bmQ6ICNlZGYx
ZmY7IGJveC1zaGFkb3c6IDAgM3B4IDEwcHggcmdiYSg5MSwxMTUsMjMyLC4yNSk7IH0NCiAgICAg
ICAgI2J0bi10b3Agc3ZnIHsgd2lkdGg6IDE0cHg7IGhlaWdodDogMTRweDsgZGlzcGxheTogYmxv
Y2s7IH0NCg0KICAgICAgICAjZW1wdHkgew0KICAgICAgICAgICAgZGlzcGxheTogbm9uZTsgZmxl
eC1kaXJlY3Rpb246IGNvbHVtbjsgYWxpZ24taXRlbXM6IGNlbnRlcjsganVzdGlmeS1jb250ZW50
OiBjZW50ZXI7DQogICAgICAgICAgICBwYWRkaW5nOiA0OHB4IDE2cHg7IGNvbG9yOiB2YXIoLS10
eHQzKTsgZ2FwOiA4cHg7DQogICAgICAgICAgICAtd2Via2l0LWFwcC1yZWdpb246IGRyYWc7IGFw
cC1yZWdpb246IGRyYWc7DQogICAgICAgIH0NCiAgICAgICAgI2VtcHR5Lm9uIHsgZGlzcGxheTog
ZmxleDsgfQ0KICAgICAgICAuZS10eHQgeyBmb250LXNpemU6IDEycHg7IHRleHQtYWxpZ246IGNl
bnRlcjsgbGV0dGVyLXNwYWNpbmc6IC4wMmVtOyB9DQogICAgICAgICNza2VsIHsNCiAgICAgICAg
ICAgIGRpc3BsYXk6IG5vbmUgIWltcG9ydGFudDsgLyog56eS5byA5ZCO5LiN5YaN5bGV56S66aqo
5p625Yqo55S7ICovDQogICAgICAgIH0NCiAgICAgICAgI3NrZWwub24geyBkaXNwbGF5OiBub25l
ICFpbXBvcnRhbnQ7IH0NCiAgICAgICAgI2FwcC5ib290LWxvYWRpbmcgI3NrZWwgew0KICAgICAg
ICAgICAgZGlzcGxheTogbm9uZSAhaW1wb3J0YW50Ow0KICAgICAgICB9DQogICAgICAgICNhcHAu
Ym9vdC1sb2FkaW5nICNlbXB0eSB7DQogICAgICAgICAgICBkaXNwbGF5OiBub25lICFpbXBvcnRh
bnQ7DQogICAgICAgIH0NCiAgICAgICAgLnNrLXJvdyB7DQogICAgICAgICAgICBkaXNwbGF5OiBm
bGV4OyBhbGlnbi1pdGVtczogZmxleC1zdGFydDsgZ2FwOiAxMHB4Ow0KICAgICAgICAgICAgcGFk
ZGluZzogMTBweCA4cHg7IGJvcmRlci1yYWRpdXM6IDhweDsNCiAgICAgICAgICAgIGJhY2tncm91
bmQ6IHJnYmEoMjU1LDI1NSwyNTUsLjcyKTsNCiAgICAgICAgICAgIGJvcmRlcjogMXB4IHNvbGlk
IHJnYmEoMTcwLDE4MCwyMDAsLjQ1KTsNCiAgICAgICAgICAgIHBvc2l0aW9uOiByZWxhdGl2ZTsN
CiAgICAgICAgICAgIG92ZXJmbG93OiBoaWRkZW47DQogICAgICAgIH0NCiAgICAgICAgLnNrLXJv
dzo6YWZ0ZXIgew0KICAgICAgICAgICAgY29udGVudDogJyc7DQogICAgICAgICAgICBwb3NpdGlv
bjogYWJzb2x1dGU7DQogICAgICAgICAgICBpbnNldDogMDsNCiAgICAgICAgICAgIGJhY2tncm91
bmQ6IGxpbmVhci1ncmFkaWVudCg5MGRlZywgdHJhbnNwYXJlbnQgMCUsIHJnYmEoMjU1LDI1NSwy
NTUsLjcyKSA0OCUsIHRyYW5zcGFyZW50IDEwMCUpOw0KICAgICAgICAgICAgdHJhbnNmb3JtOiB0
cmFuc2xhdGVYKC0xMjAlKTsNCiAgICAgICAgICAgIGFuaW1hdGlvbjogc2stc3dlZXAgMC45NXMg
ZWFzZS1pbi1vdXQgaW5maW5pdGU7DQogICAgICAgICAgICBwb2ludGVyLWV2ZW50czogbm9uZTsN
CiAgICAgICAgfQ0KICAgICAgICBAa2V5ZnJhbWVzIHNrLXN3ZWVwIHsNCiAgICAgICAgICAgIDEw
MCUgeyB0cmFuc2Zvcm06IHRyYW5zbGF0ZVgoMTIwJSk7IH0NCiAgICAgICAgfQ0KICAgICAgICAu
c2staWNvLCAuc2stbGluZSB7DQogICAgICAgICAgICBiYWNrZ3JvdW5kOiBsaW5lYXItZ3JhZGll
bnQoOTBkZWcsICNiOGMyZDggMCUsICNmMGY0ZmEgMzglLCAjZGNlM2YwIDUyJSwgI2I4YzJkOCAx
MDAlKTsNCiAgICAgICAgICAgIGJhY2tncm91bmQtc2l6ZTogMjQwJSAxMDAlOw0KICAgICAgICAg
ICAgYW5pbWF0aW9uOiBzay1zaGltbWVyIDAuNzJzIGVhc2UtaW4tb3V0IGluZmluaXRlOw0KICAg
ICAgICAgICAgd2lsbC1jaGFuZ2U6IGJhY2tncm91bmQtcG9zaXRpb247DQogICAgICAgICAgICBi
b3JkZXItcmFkaXVzOiA2cHg7DQogICAgICAgIH0NCiAgICAgICAgLnNrLWljbyB7IHdpZHRoOiAz
NHB4OyBoZWlnaHQ6IDM0cHg7IGZsZXgtc2hyaW5rOiAwOyBib3JkZXItcmFkaXVzOiA4cHg7IH0N
CiAgICAgICAgLnNrLWJvZHkgeyBmbGV4OiAxOyBtaW4td2lkdGg6IDA7IGRpc3BsYXk6IGZsZXg7
IGZsZXgtZGlyZWN0aW9uOiBjb2x1bW47IGdhcDogOHB4OyBwYWRkaW5nLXRvcDogMnB4OyB9DQog
ICAgICAgIC5zay1saW5lIHsgaGVpZ2h0OiAxMHB4OyB3aWR0aDogMTAwJTsgfQ0KICAgICAgICAu
c2stbGluZS5zaG9ydCB7IHdpZHRoOiA0MiU7IH0NCiAgICAgICAgLnNrLWxpbmUubWlkIHsgd2lk
dGg6IDY4JTsgfQ0KICAgICAgICAuc2stcm93Om50aC1jaGlsZCgyKTo6YWZ0ZXIgeyBhbmltYXRp
b24tZGVsYXk6IC4xMnM7IH0NCiAgICAgICAgLnNrLXJvdzpudGgtY2hpbGQoMyk6OmFmdGVyIHsg
YW5pbWF0aW9uLWRlbGF5OiAuMjRzOyB9DQogICAgICAgIC5zay1yb3c6bnRoLWNoaWxkKDQpOjph
ZnRlciB7IGFuaW1hdGlvbi1kZWxheTogLjM2czsgfQ0KICAgICAgICAuc2stcm93Om50aC1jaGls
ZCg1KTo6YWZ0ZXIgeyBhbmltYXRpb24tZGVsYXk6IC40OHM7IH0NCiAgICAgICAgLnNrLXJvdzpu
dGgtY2hpbGQoNik6OmFmdGVyIHsgYW5pbWF0aW9uLWRlbGF5OiAuNnM7IH0NCiAgICAgICAgQGtl
eWZyYW1lcyBzay1zaGltbWVyIHsNCiAgICAgICAgICAgIDAlIHsgYmFja2dyb3VuZC1wb3NpdGlv
bjogMTAwJSAwOyB9DQogICAgICAgICAgICAxMDAlIHsgYmFja2dyb3VuZC1wb3NpdGlvbjogLTEw
MCUgMDsgfQ0KICAgICAgICB9DQogICAgICAgIC5saXN0LW1vcmUgew0KICAgICAgICAgICAgdGV4
dC1hbGlnbjogY2VudGVyOyBwYWRkaW5nOiAxMHB4IDhweCAxNHB4OyBmb250LXNpemU6IDExcHg7
DQogICAgICAgICAgICBjb2xvcjogdmFyKC0tdHh0Myk7IC13ZWJraXQtYXBwLXJlZ2lvbjogbm8t
ZHJhZzsgYXBwLXJlZ2lvbjogbm8tZHJhZzsNCiAgICAgICAgfQ0KICAgICAgICAubGlzdC1tb3Jl
LmRvbmUgeyBkaXNwbGF5OiBub25lOyB9DQoNCiAgICAgICAgLml0bSB7DQogICAgICAgICAgICBk
aXNwbGF5OiBmbGV4OyBhbGlnbi1pdGVtczogZmxleC1zdGFydDsgZ2FwOiA4cHg7DQogICAgICAg
ICAgICBwYWRkaW5nOiA4cHg7IG1hcmdpbi1ib3R0b206IDVweDsNCiAgICAgICAgICAgIGJhY2tn
cm91bmQ6IHZhcigtLWNhcmQpOyBib3JkZXItcmFkaXVzOiA0cHg7IGN1cnNvcjogcG9pbnRlcjsN
CiAgICAgICAgICAgIGJvcmRlcjogbm9uZTsNCiAgICAgICAgICAgIGJveC1zaGFkb3c6DQogICAg
ICAgICAgICAgICAgMCAxcHggMnB4IHJnYmEoMjQsMzIsNTYsLjA1KSwNCiAgICAgICAgICAgICAg
ICAwIDNweCAxMHB4IHJnYmEoMjQsMzIsNTYsLjA4KTsNCiAgICAgICAgICAgIC8qIGhvdmVyLWxp
bmUgKi8NCiAgICAgICAgICAgIHBvc2l0aW9uOiByZWxhdGl2ZTsNCiAgICAgICAgICAgIHRyYW5z
aXRpb246IGJhY2tncm91bmQgLjJzIGVhc2UsIGJveC1zaGFkb3cgLjJzIGVhc2UsIHRyYW5zZm9y
bSAuMnMgZWFzZTsNCiAgICAgICAgICAgIC13ZWJraXQtYXBwLXJlZ2lvbjogbm8tZHJhZzsgYXBw
LXJlZ2lvbjogbm8tZHJhZzsNCiAgICAgICAgICAgIG92ZXJmbG93OiB2aXNpYmxlOw0KICAgICAg
ICB9DQogICAgICAgIC5pdG06OmJlZm9yZSB7DQogICAgICAgICAgICBjb250ZW50OiAiIjsNCiAg
ICAgICAgICAgIHBvc2l0aW9uOiBhYnNvbHV0ZTsNCiAgICAgICAgICAgIGxlZnQ6IDA7IHJpZ2h0
OiAwOyBib3R0b206IDA7DQogICAgICAgICAgICBoZWlnaHQ6IDA7DQogICAgICAgICAgICBwb2lu
dGVyLWV2ZW50czogbm9uZTsNCiAgICAgICAgICAgIHotaW5kZXg6IDA7DQogICAgICAgICAgICBi
b3JkZXItcmFkaXVzOiAwIDAgdmFyKC0tcikgdmFyKC0tcik7DQogICAgICAgICAgICBiYWNrZ3Jv
dW5kOiBsaW5lYXItZ3JhZGllbnQodG8gdG9wLCByZ2JhKDkxLDExNSwyMzIsLjMyKSwgcmdiYSg5
MSwxMTUsMjMyLC4xMikgNTUlLCB0cmFuc3BhcmVudCk7DQogICAgICAgICAgICB0cmFuc2l0aW9u
OiBoZWlnaHQgLjM0cyBjdWJpYy1iZXppZXIoLjIyLDEsLjM2LDEpOw0KICAgICAgICB9DQogICAg
ICAgIC5pdG06aG92ZXI6OmJlZm9yZSB7IGhlaWdodDogMzMuMzMzJTsgfQ0KICAgICAgICAuaXRt
OjphZnRlciB7DQogICAgICAgICAgICBjb250ZW50OiAiIjsNCiAgICAgICAgICAgIHBvc2l0aW9u
OiBhYnNvbHV0ZTsNCiAgICAgICAgICAgIGxlZnQ6IDA7IHJpZ2h0OiAwOyBib3R0b206IDA7DQog
ICAgICAgICAgICBoZWlnaHQ6IDJweDsNCiAgICAgICAgICAgIHBvaW50ZXItZXZlbnRzOiBub25l
Ow0KICAgICAgICAgICAgei1pbmRleDogMTsNCiAgICAgICAgICAgIGJhY2tncm91bmQ6IHJnYmEo
OTEsMTE1LDIzMiwuOTUpOw0KICAgICAgICAgICAgYm9yZGVyLXJhZGl1czogMXB4Ow0KICAgICAg
ICAgICAgdHJhbnNmb3JtOiBzY2FsZVgoMCk7DQogICAgICAgICAgICB0cmFuc2Zvcm0tb3JpZ2lu
OiBjZW50ZXI7DQogICAgICAgICAgICB0cmFuc2l0aW9uOiB0cmFuc2Zvcm0gLjNzIGN1YmljLWJl
emllciguMjIsMSwuMzYsMSk7DQogICAgICAgIH0NCiAgICAgICAgLml0bTpob3ZlciB7DQogICAg
ICAgICAgICBiYWNrZ3JvdW5kOiB2YXIoLS1jYXJkLWgpOw0KICAgICAgICAgICAgYm94LXNoYWRv
dzoNCiAgICAgICAgICAgICAgICAwIDJweCA0cHggcmdiYSgyNCwzMiw1NiwuMDcpLA0KICAgICAg
ICAgICAgICAgIDAgNnB4IDE2cHggcmdiYSgyNCwzMiw1NiwuMTIpOw0KICAgICAgICB9DQogICAg
ICAgIC5pdG06aG92ZXI6OmFmdGVyIHsNCiAgICAgICAgICAgIHRyYW5zZm9ybTogc2NhbGVYKDEp
Ow0KICAgICAgICB9DQogICAgICAgIC5pdG0uc2VsIHsNCiAgICAgICAgICAgIGJveC1zaGFkb3c6
DQogICAgICAgICAgICAgICAgMCAwIDAgMnB4IHJnYmEoOTEsMTE1LDIzMiwuNDIpLA0KICAgICAg
ICAgICAgICAgIDAgMnB4IDRweCByZ2JhKDkxLDExNSwyMzIsLjEwKSwNCiAgICAgICAgICAgICAg
ICAwIDZweCAxNHB4IHJnYmEoOTEsMTE1LDIzMiwuMTYpOw0KICAgICAgICAgICAgYmFja2dyb3Vu
ZDogI2VkZjFmZjsNCiAgICAgICAgfQ0KICAgICAgICAuaXRtLm11bHRpIHsNCiAgICAgICAgICAg
IGJveC1zaGFkb3c6IDAgMCAwIDEuNXB4IHJnYmEoOTEsMTE1LDIzMiwuNTUpLCAwIDJweCA2cHgg
cmdiYSg5MSwxMTUsMjMyLC4xOCk7DQogICAgICAgICAgICBiYWNrZ3JvdW5kOiAjZWVmMmZmOw0K
ICAgICAgICB9DQogICAgICAgIC5pdG0ubXVsdGkuc2VsIHsNCiAgICAgICAgICAgIGJveC1zaGFk
b3c6IDAgMCAwIDJweCByZ2JhKDkxLDExNSwyMzIsLjcpLCAwIDJweCA4cHggcmdiYSg5MSwxMTUs
MjMyLC4yMik7DQogICAgICAgIH0NCg0KICAgICAgICAjbXVsdGktYmFyIHsNCiAgICAgICAgICAg
IGRpc3BsYXk6IG5vbmU7DQogICAgICAgICAgICBhbGlnbi1pdGVtczogY2VudGVyOw0KICAgICAg
ICAgICAgZ2FwOiA0cHg7DQogICAgICAgICAgICBtYXJnaW46IDAgMnB4IDAgMDsNCiAgICAgICAg
ICAgIGZsZXgtc2hyaW5rOiAwOw0KICAgICAgICAgICAgLXdlYmtpdC1hcHAtcmVnaW9uOiBuby1k
cmFnOyBhcHAtcmVnaW9uOiBuby1kcmFnOw0KICAgICAgICB9DQogICAgICAgICNtdWx0aS1iYXIu
b24geyBkaXNwbGF5OiBpbmxpbmUtZmxleDsgfQ0KICAgICAgICAjbXVsdGktc2VsIHsNCiAgICAg
ICAgICAgIGRpc3BsYXk6IGlubGluZS1mbGV4Ow0KICAgICAgICAgICAgYWxpZ24taXRlbXM6IGNl
bnRlcjsNCiAgICAgICAgICAgIGdhcDogNHB4Ow0KICAgICAgICAgICAgaGVpZ2h0OiAyMnB4Ow0K
ICAgICAgICAgICAgcGFkZGluZzogMCA5cHg7DQogICAgICAgICAgICBmbGV4LXNocmluazogMDsN
CiAgICAgICAgICAgIGJvcmRlcjogbm9uZTsNCiAgICAgICAgICAgIGJvcmRlci1yYWRpdXM6IDEx
cHg7DQogICAgICAgICAgICBiYWNrZ3JvdW5kOiB2YXIoLS1hY2MpOw0KICAgICAgICAgICAgY29s
b3I6ICNmZmY7DQogICAgICAgICAgICBjdXJzb3I6IHBvaW50ZXI7DQogICAgICAgICAgICAtd2Vi
a2l0LWFwcC1yZWdpb246IG5vLWRyYWc7IGFwcC1yZWdpb246IG5vLWRyYWc7DQogICAgICAgICAg
ICB0cmFuc2l0aW9uOiBiYWNrZ3JvdW5kIHZhcigtLXRyKSwgb3BhY2l0eSB2YXIoLS10cik7DQog
ICAgICAgIH0NCiAgICAgICAgI211bHRpLXNlbDpob3ZlciB7IGJhY2tncm91bmQ6ICM0YTYyZDQ7
IH0NCiAgICAgICAgI211bHRpLXNlbC1sYWIgew0KICAgICAgICAgICAgZm9udC1zaXplOiAxMXB4
Ow0KICAgICAgICAgICAgZm9udC13ZWlnaHQ6IDYwMDsNCiAgICAgICAgICAgIGNvbG9yOiAjZmZm
Ow0KICAgICAgICAgICAgbGV0dGVyLXNwYWNpbmc6IC4wMmVtOw0KICAgICAgICAgICAgbGluZS1o
ZWlnaHQ6IDE7DQogICAgICAgICAgICB1c2VyLXNlbGVjdDogbm9uZTsNCiAgICAgICAgfQ0KICAg
ICAgICAjbXVsdGktY250IHsNCiAgICAgICAgICAgIGRpc3BsYXk6IGlubGluZS1mbGV4Ow0KICAg
ICAgICAgICAgYWxpZ24taXRlbXM6IGNlbnRlcjsNCiAgICAgICAgICAgIGp1c3RpZnktY29udGVu
dDogY2VudGVyOw0KICAgICAgICAgICAgbWluLXdpZHRoOiAxZW07DQogICAgICAgICAgICBmb250
LXNpemU6IDExcHg7DQogICAgICAgICAgICBmb250LXdlaWdodDogNzAwOw0KICAgICAgICAgICAg
Y29sb3I6ICNmZmY7DQogICAgICAgICAgICBsaW5lLWhlaWdodDogMTsNCiAgICAgICAgICAgIHVz
ZXItc2VsZWN0OiBub25lOw0KICAgICAgICB9DQoNCiAgICAgICAgI3Bhc3RlLXNlcC13cmFwIHsN
CiAgICAgICAgICAgIHBvc2l0aW9uOiByZWxhdGl2ZTsgZmxleC1zaHJpbms6IDA7DQogICAgICAg
IH0NCiAgICAgICAgI3Bhc3RlLXNlcC1idG4gew0KICAgICAgICAgICAgZGlzcGxheTogaW5saW5l
LWZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7DQogICAgICAgICAgICBoZWlnaHQ6IDIycHg7IHBh
ZGRpbmc6IDAgOHB4Ow0KICAgICAgICAgICAgYm9yZGVyOiBub25lOyBib3JkZXItcmFkaXVzOiAx
MXB4OyBjdXJzb3I6IHBvaW50ZXI7DQogICAgICAgICAgICBiYWNrZ3JvdW5kOiByZ2JhKDkxLDEx
NSwyMzIsLjEwKTsgY29sb3I6IHZhcigtLWFjYyk7DQogICAgICAgICAgICBmb250LXNpemU6IDEy
cHg7IGxpbmUtaGVpZ2h0OiAxOyBmb250LXdlaWdodDogNzAwOw0KICAgICAgICAgICAgZm9udC1m
YW1pbHk6IHVpLW1vbm9zcGFjZSwgQ29uc29sYXMsICJDYXNjYWRpYSBNb25vIiwgbW9ub3NwYWNl
Ow0KICAgICAgICAgICAgLXdlYmtpdC1hcHAtcmVnaW9uOiBuby1kcmFnOyBhcHAtcmVnaW9uOiBu
by1kcmFnOw0KICAgICAgICAgICAgdHJhbnNpdGlvbjogYmFja2dyb3VuZCB2YXIoLS10ciksIGNv
bG9yIHZhcigtLXRyKTsNCiAgICAgICAgfQ0KICAgICAgICAjcGFzdGUtc2VwLWJ0bjpob3Zlciwg
I3Bhc3RlLXNlcC1idG4ub3BlbiB7DQogICAgICAgICAgICBiYWNrZ3JvdW5kOiByZ2JhKDkxLDEx
NSwyMzIsLjE4KTsgY29sb3I6ICM0YTYyZDQ7DQogICAgICAgIH0NCiAgICAgICAgI3Bhc3RlLXNl
cC1tZW51IHsNCiAgICAgICAgICAgIGRpc3BsYXk6IG5vbmU7IHBvc2l0aW9uOiBhYnNvbHV0ZTsg
dG9wOiBjYWxjKDEwMCUgKyA1cHgpOyByaWdodDogMDsNCiAgICAgICAgICAgIHdpZHRoOiBtYXgt
Y29udGVudDsgbWF4LXdpZHRoOiAxNDBweDsgbWF4LWhlaWdodDogMjgwcHg7DQogICAgICAgICAg
ICBvdmVyZmxvdy15OiBhdXRvOyB6LWluZGV4OiAxMjA7DQogICAgICAgICAgICBiYWNrZ3JvdW5k
OiByZ2JhKDI1MCwyNTEsMjU0LC45Nyk7DQogICAgICAgICAgICBib3JkZXI6IDFweCBzb2xpZCBy
Z2JhKDAsMCwwLC4wNSk7DQogICAgICAgICAgICBib3JkZXItcmFkaXVzOiA4cHg7DQogICAgICAg
ICAgICBib3gtc2hhZG93OiAwIDZweCAyMHB4IHJnYmEoNDQsNDYsNTQsLjEpOw0KICAgICAgICAg
ICAgcGFkZGluZzogM3B4Ow0KICAgICAgICAgICAgYmFja2Ryb3AtZmlsdGVyOiBibHVyKDhweCk7
DQogICAgICAgIH0NCiAgICAgICAgI3Bhc3RlLXNlcC1tZW51Lm9uIHsNCiAgICAgICAgICAgIGRp
c3BsYXk6IGZsZXg7IGZsZXgtZGlyZWN0aW9uOiBjb2x1bW47IGFsaWduLWl0ZW1zOiBzdHJldGNo
Ow0KICAgICAgICB9DQogICAgICAgIC5wYXN0ZS1zZXAtaXRlbSB7DQogICAgICAgICAgICBkaXNw
bGF5OiBmbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBqdXN0aWZ5LWNvbnRlbnQ6IHNwYWNlLWJl
dHdlZW47IGdhcDogOHB4Ow0KICAgICAgICAgICAgd2lkdGg6IDEwMCU7IGJveC1zaXppbmc6IGJv
cmRlci1ib3g7IHRleHQtYWxpZ246IGxlZnQ7DQogICAgICAgICAgICBwYWRkaW5nOiA0cHggNnB4
OyBib3JkZXI6IG5vbmU7IGJvcmRlci1yYWRpdXM6IDZweDsNCiAgICAgICAgICAgIGJhY2tncm91
bmQ6IG5vbmU7IGNvbG9yOiB2YXIoLS10eHQyKTsNCiAgICAgICAgICAgIGZvbnQtc2l6ZTogMTBw
eDsgY3Vyc29yOiBwb2ludGVyOyB3aGl0ZS1zcGFjZTogbm93cmFwOw0KICAgICAgICAgICAgb3Zl
cmZsb3c6IGhpZGRlbjsNCiAgICAgICAgICAgIHRyYW5zaXRpb246IGJhY2tncm91bmQgdmFyKC0t
dHIpLCBjb2xvciB2YXIoLS10cik7DQogICAgICAgIH0NCiAgICAgICAgLnBhc3RlLXNlcC1zeW0g
ew0KICAgICAgICAgICAgZmxleC1zaHJpbms6IDA7DQogICAgICAgICAgICBmb250LWZhbWlseTog
dWktbW9ub3NwYWNlLCBDb25zb2xhcywgIkNhc2NhZGlhIE1vbm8iLCBtb25vc3BhY2U7DQogICAg
ICAgICAgICBmb250LXNpemU6IDEwcHg7IGZvbnQtd2VpZ2h0OiA3MDA7IGNvbG9yOiB2YXIoLS1h
Y2MpOw0KICAgICAgICAgICAgbGV0dGVyLXNwYWNpbmc6IC0wLjAzZW07DQogICAgICAgIH0NCiAg
ICAgICAgLnBhc3RlLXNlcC1zeW0ub25seSB7IG1pbi13aWR0aDogMDsgfQ0KICAgICAgICAucGFz
dGUtc2VwLW5hbWUgew0KICAgICAgICAgICAgZmxleDogMCAwIGF1dG87IG1hcmdpbi1sZWZ0OiBh
dXRvOw0KICAgICAgICAgICAgZm9udC1zaXplOiAxMHB4OyBjb2xvcjogdmFyKC0tdHh0Myk7DQog
ICAgICAgICAgICBvdmVyZmxvdzogaGlkZGVuOyB0ZXh0LW92ZXJmbG93OiBlbGxpcHNpczsNCiAg
ICAgICAgfQ0KICAgICAgICAucGFzdGUtc2VwLWl0ZW06aG92ZXIgeyBiYWNrZ3JvdW5kOiByZ2Jh
KDkxLDExNSwyMzIsLjA4KTsgfQ0KICAgICAgICAucGFzdGUtc2VwLWl0ZW06aG92ZXIgLnBhc3Rl
LXNlcC1uYW1lIHsgY29sb3I6IHZhcigtLXR4dDIpOyB9DQogICAgICAgIC5wYXN0ZS1zZXAtaXRl
bS5zZWwgeyBiYWNrZ3JvdW5kOiByZ2JhKDkxLDExNSwyMzIsLjEyKTsgfQ0KICAgICAgICAucGFz
dGUtc2VwLWl0ZW0uc2VsIC5wYXN0ZS1zZXAtbmFtZSB7IGNvbG9yOiB2YXIoLS1hY2MpOyBmb250
LXdlaWdodDogNjAwOyB9DQogICAgICAgIC5wYXN0ZS1zZXAtZm9vdCB7DQogICAgICAgICAgICBt
YXJnaW4tdG9wOiAzcHg7IHBhZGRpbmctdG9wOiAzcHg7DQogICAgICAgICAgICBib3JkZXItdG9w
OiAxcHggc29saWQgcmdiYSgwLDAsMCwuMDUpOw0KICAgICAgICAgICAgbWluLXdpZHRoOiAwOyBh
bGlnbi1zZWxmOiBzdHJldGNoOw0KICAgICAgICB9DQogICAgICAgICNwYXN0ZS1zZXAtY3VzdG9t
IHsNCiAgICAgICAgICAgIGRpc3BsYXk6IGJsb2NrOyB3aWR0aDogMTAwJTsgbWluLXdpZHRoOiAw
OyBtYXgtd2lkdGg6IDEwMCU7DQogICAgICAgICAgICBib3gtc2l6aW5nOiBib3JkZXItYm94Ow0K
ICAgICAgICAgICAgaGVpZ2h0OiAyMnB4OyBwYWRkaW5nOiAwIDZweDsNCiAgICAgICAgICAgIGJv
cmRlcjogbm9uZTsgYm9yZGVyLXJhZGl1czogNXB4Ow0KICAgICAgICAgICAgYmFja2dyb3VuZDog
cmdiYSg5MSwxMTUsMjMyLC4wNik7DQogICAgICAgICAgICBjb2xvcjogdmFyKC0tdHh0Mik7IGZv
bnQtc2l6ZTogMTBweDsNCiAgICAgICAgICAgIC13ZWJraXQtYXBwLXJlZ2lvbjogbm8tZHJhZzsg
YXBwLXJlZ2lvbjogbm8tZHJhZzsNCiAgICAgICAgfQ0KICAgICAgICAjcGFzdGUtc2VwLWN1c3Rv
bTpmb2N1cyB7DQogICAgICAgICAgICBvdXRsaW5lOiBub25lOyBiYWNrZ3JvdW5kOiByZ2JhKDkx
LDExNSwyMzIsLjEpOyBjb2xvcjogdmFyKC0tdHh0KTsNCiAgICAgICAgfQ0KICAgICAgICAjcGFz
dGUtc2VwLWN1c3RvbTo6cGxhY2Vob2xkZXIgeyBjb2xvcjogdmFyKC0tdHh0Myk7IH0NCg0KICAg
ICAgICAuaS1pY28gew0KICAgICAgICAgICAgd2lkdGg6IDI4cHg7IGhlaWdodDogMjhweDsgYm9y
ZGVyLXJhZGl1czogdmFyKC0tcik7IGRpc3BsYXk6IGZsZXg7DQogICAgICAgICAgICBhbGlnbi1p
dGVtczogY2VudGVyOyBqdXN0aWZ5LWNvbnRlbnQ6IGNlbnRlcjsgZmxleC1zaHJpbms6IDA7DQog
ICAgICAgICAgICBiYWNrZ3JvdW5kOiAjZWRmMmZmOyBjb2xvcjogdmFyKC0tYWNjKTsNCiAgICAg
ICAgICAgIHBvc2l0aW9uOiByZWxhdGl2ZTsgb3ZlcmZsb3c6IHZpc2libGU7DQogICAgICAgIH0N
CiAgICAgICAgLmktaWNvIHN2ZyB7IHdpZHRoOiAxNnB4OyBoZWlnaHQ6IDE2cHg7IGRpc3BsYXk6
IGJsb2NrOyB9DQogICAgICAgIC5pLWljby5mdC1pbWcgeyBjb2xvcjogIzdhZDdmZjsgfQ0KICAg
ICAgICAuaS1pY28uZnQtdmlkIHsgY29sb3I6ICNjMDg0ZmM7IH0NCiAgICAgICAgLmktaWNvLmZ0
LXppcCB7IGNvbG9yOiAjOGFiNGZmOyB9DQogICAgICAgIC5pLWljby5mdC1kaXIgeyBjb2xvcjog
I2ZmZDU2YTsgfQ0KICAgICAgICAuaS1pY28uZnQtYWhrIHsgY29sb3I6ICM2ZGZmOWE7IH0NCiAg
ICAgICAgLmktaWNvLm1kIHsgY29sb3I6ICM2YjhjZmY7IH0NCiAgICAgICAgLmktaWNvLm1kIHN2
ZyB7IHdpZHRoOiAyMHB4OyBoZWlnaHQ6IDIwcHg7IH0NCiAgICAgICAgLmktaWNvLmZ0LWxuaywg
LmktaWNvLmZ0LWRvYyB7IGNvbG9yOiAjYTliZGQwOyB9DQogICAgICAgIC5pLXVzZWQgew0KICAg
ICAgICAgICAgcG9zaXRpb246IGFic29sdXRlOyByaWdodDogMDsgYm90dG9tOiAwOw0KICAgICAg
ICAgICAgd2lkdGg6IDEzcHg7IGhlaWdodDogMTNweDsgYm9yZGVyLXJhZGl1czogNTAlOw0KICAg
ICAgICAgICAgYmFja2dyb3VuZDogIzIyYzU1ZTsgYm9yZGVyOiAxLjVweCBzb2xpZCAjZmZmOw0K
ICAgICAgICAgICAgZGlzcGxheTogZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsganVzdGlmeS1j
b250ZW50OiBjZW50ZXI7DQogICAgICAgICAgICBwb2ludGVyLWV2ZW50czogbm9uZTsgei1pbmRl
eDogMzsNCiAgICAgICAgICAgIGJveC1zaGFkb3c6IDAgMXB4IDJweCByZ2JhKDAsMCwwLC4xNik7
DQogICAgICAgICAgICB0cmFuc2Zvcm06IHRyYW5zbGF0ZSgzMCUsIDMwJSk7DQogICAgICAgIH0N
CiAgICAgICAgLmktdXNlZCBzdmcgeyB3aWR0aDogOXB4OyBoZWlnaHQ6IDlweDsgY29sb3I6ICNm
ZmY7IGRpc3BsYXk6IGJsb2NrOyB9DQogICAgICAgIC8qIOW3suaUtuiXj++8muexu+Wei+Wbvuag
h+WPs+S4iuinkue6ouW/g++8iOWOnyBTVkcg6KeS5qCH77yJICovDQogICAgICAgIC5pLWZhdiB7
DQogICAgICAgICAgICBwb3NpdGlvbjogYWJzb2x1dGU7IHJpZ2h0OiAwOyB0b3A6IDA7DQogICAg
ICAgICAgICB3aWR0aDogMTRweDsgaGVpZ2h0OiAxNHB4OyBib3JkZXItcmFkaXVzOiA1MCU7DQog
ICAgICAgICAgICBiYWNrZ3JvdW5kOiAjZmZmOyBib3JkZXI6IG5vbmU7DQogICAgICAgICAgICBk
aXNwbGF5OiBmbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBqdXN0aWZ5LWNvbnRlbnQ6IGNlbnRl
cjsNCiAgICAgICAgICAgIHBvaW50ZXItZXZlbnRzOiBub25lOyB6LWluZGV4OiAzOw0KICAgICAg
ICAgICAgYm94LXNoYWRvdzogMCAxcHggMnB4IHJnYmEoMCwwLDAsLjEyKTsNCiAgICAgICAgICAg
IHRyYW5zZm9ybTogdHJhbnNsYXRlKDI4JSwgLTI4JSk7DQogICAgICAgICAgICBmb250LXNpemU6
IDExcHg7IGxpbmUtaGVpZ2h0OiAxOw0KICAgICAgICAgICAgY29sb3I6ICNlMTFkNDg7DQogICAg
ICAgIH0NCiAgICAgICAgLmktZmF2IHN2ZyB7IHdpZHRoOiAxMHB4OyBoZWlnaHQ6IDEwcHg7IGNv
bG9yOiAjZTExZDQ4OyBkaXNwbGF5OiBibG9jazsgfQ0KICAgICAgICAjYXBwW2RhdGEtdGFiPSJw
aW5uZWQiXSAuaS1mYXYgeyBkaXNwbGF5OiBub25lOyB9DQoNCiAgICAgICAgLyogUGFzdGUtcXVl
dWUgdmlzdWFsIGNoYWluOiBncmF5ID0gaW4gcXVldWU7IGdyZWVuID0gZGVxdWV1ZWQgKHBhc3Rl
ZCkgY2hhaW4gKi8NCiAgICAgICAgLml0bS5xLW1lbWJlciB7DQogICAgICAgICAgICBwYWRkaW5n
LWxlZnQ6IDE0cHg7DQogICAgICAgICAgICAvKiBNVVNUIG92ZXJyaWRlIGdsb2JhbCAuaXRte292
ZXJmbG93OmhpZGRlbn0g4oCUIG90aGVyd2lzZSBib3R0b206LU4gcmFpbA0KICAgICAgICAgICAg
ICAgaXMgY2xpcHBlZCBhbmQgdGhlIGNoYWluIGxvb2tzIOKAnOaWree6v+KAnSBhY3Jvc3MgdGhl
IDVweCBjYXJkIGdhcCAqLw0KICAgICAgICAgICAgb3ZlcmZsb3c6IHZpc2libGUgIWltcG9ydGFu
dDsNCiAgICAgICAgfQ0KICAgICAgICAuaXRtLnEtbWVtYmVyIC5xLXJhaWwgew0KICAgICAgICAg
ICAgcG9zaXRpb246IGFic29sdXRlOw0KICAgICAgICAgICAgbGVmdDogNXB4Ow0KICAgICAgICAg
ICAgdG9wOiAwOw0KICAgICAgICAgICAgLyogQnJpZGdlIC5pdG0gbWFyZ2luLWJvdHRvbTo1cHgg
c28gY29uc2VjdXRpdmUgcmFpbHMgcmVhZCBhcyBvbmUgc3Ryb2tlICovDQogICAgICAgICAgICBi
b3R0b206IC01cHg7DQogICAgICAgICAgICB3aWR0aDogMnB4Ow0KICAgICAgICAgICAgYmFja2dy
b3VuZDogIzljYTNhZjsNCiAgICAgICAgICAgIG9wYWNpdHk6IC43MjsNCiAgICAgICAgICAgIHBv
aW50ZXItZXZlbnRzOiBub25lOw0KICAgICAgICAgICAgei1pbmRleDogNDsNCiAgICAgICAgfQ0K
ICAgICAgICAuaXRtLnEtbWVtYmVyLnEtZmlyc3QgLnEtcmFpbCB7IHRvcDogMTZweDsgYm9yZGVy
LXJhZGl1czogMnB4IDJweCAwIDA7IH0NCiAgICAgICAgLyogRW5kIGNoYWluIGF0IHRoZSBsYXN0
IGRvdCDigJQgZG8gbm90IGhhbmcgaW50byB0aGUgZ2FwIGJlbG93ICovDQogICAgICAgIC5pdG0u
cS1tZW1iZXIucS1sYXN0IC5xLXJhaWwgew0KICAgICAgICAgICAgYm90dG9tOiBhdXRvOw0KICAg
ICAgICAgICAgaGVpZ2h0OiAyMnB4Ow0KICAgICAgICAgICAgYm9yZGVyLXJhZGl1czogMCAwIDJw
eCAycHg7DQogICAgICAgIH0NCiAgICAgICAgLml0bS5xLW1lbWJlci5xLWZpcnN0LnEtbGFzdCAu
cS1yYWlsLA0KICAgICAgICAuaXRtLnEtbWVtYmVyLnEtb25seSAucS1yYWlsIHsgZGlzcGxheTog
bm9uZTsgfQ0KICAgICAgICAuaXRtLnEtbWVtYmVyIC5xLWRvdCB7DQogICAgICAgICAgICBwb3Np
dGlvbjogYWJzb2x1dGU7DQogICAgICAgICAgICBsZWZ0OiAycHg7DQogICAgICAgICAgICB0b3A6
IDE0cHg7DQogICAgICAgICAgICB3aWR0aDogOHB4Ow0KICAgICAgICAgICAgaGVpZ2h0OiA4cHg7
DQogICAgICAgICAgICBib3JkZXItcmFkaXVzOiA1MCU7DQogICAgICAgICAgICBiYWNrZ3JvdW5k
OiAjOWNhM2FmOw0KICAgICAgICAgICAgYm9yZGVyOiAxLjVweCBzb2xpZCAjZmZmOw0KICAgICAg
ICAgICAgYm94LXNoYWRvdzogMCAwIDAgMXB4IHJnYmEoMTU2LDE2MywxNzUsLjQ1KTsNCiAgICAg
ICAgICAgIHBvaW50ZXItZXZlbnRzOiBub25lOw0KICAgICAgICAgICAgei1pbmRleDogNTsNCiAg
ICAgICAgfQ0KICAgICAgICAvKiBEZXF1ZXVlZDogZ3JlZW4gZG90czsgZ3JlZW4gcmFpbCBmb3Ig
Y29uc2VjdXRpdmUgZG9uZSBydW4gKi8NCiAgICAgICAgLml0bS5xLW1lbWJlci5xLWRvbmUgLnEt
ZG90IHsNCiAgICAgICAgICAgIGJhY2tncm91bmQ6ICMyMmM1NWU7DQogICAgICAgICAgICBib3gt
c2hhZG93OiAwIDAgMCAxcHggcmdiYSgzNCwxOTcsOTQsLjQpOw0KICAgICAgICB9DQogICAgICAg
IC5pdG0ucS1tZW1iZXIucS1kb25lLWxpbmsgLnEtcmFpbCB7DQogICAgICAgICAgICBiYWNrZ3Jv
dW5kOiAjMjJjNTVlOw0KICAgICAgICAgICAgb3BhY2l0eTogLjkyOw0KICAgICAgICB9DQoNCiAg
ICAgICAgLml0bS5qdW1wLWZsYXNoIHsNCiAgICAgICAgICAgIGJveC1zaGFkb3c6IDAgMCAwIDJw
eCByZ2JhKDkxLDExNSwyMzIsLjU1KSwgMCAycHggMTBweCByZ2JhKDkxLDExNSwyMzIsLjIyKTsN
CiAgICAgICAgICAgIGJhY2tncm91bmQ6ICNlOGVkZmY7DQogICAgICAgICAgICB0cmFuc2l0aW9u
OiBiYWNrZ3JvdW5kIC4zNXMgZWFzZSwgYm94LXNoYWRvdyAuMzVzIGVhc2U7DQogICAgICAgIH0N
Cg0KICAgICAgICAuaS1ib2R5IHsgZmxleDogMTsgbWluLXdpZHRoOiAwOyBkaXNwbGF5OiBmbGV4
OyBmbGV4LWRpcmVjdGlvbjogY29sdW1uOyBwb3NpdGlvbjogcmVsYXRpdmU7IHotaW5kZXg6IDI7
IH0NCiAgICAgICAgLmktcHJldiwgLmktbmFtZSB7DQogICAgICAgICAgICBmb250LXNpemU6IDEz
cHg7IGZvbnQtd2VpZ2h0OiA1MDA7IGNvbG9yOiB2YXIoLS10eHQpOyB3b3JkLWJyZWFrOiBicmVh
ay1hbGw7DQogICAgICAgICAgICB3aGl0ZS1zcGFjZTogcHJlLXdyYXA7IC8qIOaUr+aMgeWkmuaW
h+S7ti/lpJrooYzmlofmnKzmjaLooYzmmL7npLogKi8NCiAgICAgICAgfQ0KICAgICAgICAuaS1w
cmV2IHsNCiAgICAgICAgICAgIGRpc3BsYXk6IC13ZWJraXQtYm94OyAtd2Via2l0LWJveC1vcmll
bnQ6IHZlcnRpY2FsOyAtd2Via2l0LWxpbmUtY2xhbXA6IDU7IG92ZXJmbG93OiBoaWRkZW47DQog
ICAgICAgICAgICB0ZXh0LW92ZXJmbG93OiBlbGxpcHNpczsNCiAgICAgICAgfQ0KICAgICAgICAu
aS1uYW1lIHsNCiAgICAgICAgICAgIGRpc3BsYXk6IC13ZWJraXQtYm94OyAtd2Via2l0LWJveC1v
cmllbnQ6IHZlcnRpY2FsOyAtd2Via2l0LWxpbmUtY2xhbXA6IDI7IG92ZXJmbG93OiBoaWRkZW47
DQogICAgICAgIH0NCiAgICAgICAgLyogRmlsZSBjbGlwIHdob3NlIHBhdGgocykgbm8gbG9uZ2Vy
IGV4aXN0IOKAlCBsaWdodCBib2xkIGdyYXkgc3RyaWtlICovDQogICAgICAgIC5pdG0uZ29uZSAu
aS1uYW1lIHsNCiAgICAgICAgICAgIGNvbG9yOiAjOWFhMGIwOw0KICAgICAgICAgICAgdGV4dC1k
ZWNvcmF0aW9uOiBsaW5lLXRocm91Z2g7DQogICAgICAgICAgICB0ZXh0LWRlY29yYXRpb24tdGhp
Y2tuZXNzOiAycHg7DQogICAgICAgICAgICB0ZXh0LWRlY29yYXRpb24tY29sb3I6IHJnYmEoMTU0
LCAxNjAsIDE3NiwgLjU1KTsNCiAgICAgICAgICAgIHRleHQtZGVjb3JhdGlvbi1za2lwLWluazog
bm9uZTsNCiAgICAgICAgfQ0KICAgICAgICAuaXRtLmdvbmUgLmktaWNvIHsgb3BhY2l0eTogLjU1
OyB9DQogICAgICAgIC5pdG0uZ29uZSAuaS10aHVtYi13cmFwIHsgb3BhY2l0eTogLjU1OyB9DQog
ICAgICAgIC5pLXByZXYudXJsIHsgY29sb3I6IHZhcigtLWFjYyk7IH0NCg0KICAgICAgICAucmYt
cGF0aCB7DQogICAgICAgICAgICBkaXNwbGF5OiBibG9jazsNCiAgICAgICAgICAgIHdpZHRoOiAx
MDAlOw0KICAgICAgICAgICAgbWF4LXdpZHRoOiAxMDAlOw0KICAgICAgICAgICAgYm94LXNpemlu
ZzogYm9yZGVyLWJveDsNCiAgICAgICAgICAgIGZvbnQtc2l6ZTogMTNweDsgZm9udC13ZWlnaHQ6
IDYwMDsgY29sb3I6IHZhcigtLXR4dCk7DQogICAgICAgICAgICBsaW5lLWhlaWdodDogMS40NTsN
CiAgICAgICAgICAgIC8qIOWFiOmTuua7oeS4gOihjOWGjeaWreWtl++8jOmBv+WFjeaVtOauteeb
ruW9leWQjeaPkOWJjeaKmOWIsOS4i+S4gOihjCAqLw0KICAgICAgICAgICAgd29yZC1icmVhazog
YnJlYWstYWxsOw0KICAgICAgICAgICAgb3ZlcmZsb3ctd3JhcDogYW55d2hlcmU7DQogICAgICAg
ICAgICBwb3NpdGlvbjogcmVsYXRpdmU7DQogICAgICAgICAgICB6LWluZGV4OiA2Ow0KICAgICAg
ICAgICAgLXdlYmtpdC1hcHAtcmVnaW9uOiBuby1kcmFnOyBhcHAtcmVnaW9uOiBuby1kcmFnOw0K
ICAgICAgICAgICAgcG9pbnRlci1ldmVudHM6IGF1dG87DQogICAgICAgIH0NCiAgICAgICAgLnJm
LXNlZyB7DQogICAgICAgICAgICBkaXNwbGF5OiBpbmxpbmU7DQogICAgICAgICAgICBjb2xvcjog
dmFyKC0tYWNjKTsNCiAgICAgICAgICAgIGN1cnNvcjogcG9pbnRlcjsNCiAgICAgICAgICAgIHBh
ZGRpbmc6IDAgMXB4Ow0KICAgICAgICAgICAgbWFyZ2luOiAwOw0KICAgICAgICAgICAgYm9yZGVy
OiBub25lOw0KICAgICAgICAgICAgYmFja2dyb3VuZDogdHJhbnNwYXJlbnQ7DQogICAgICAgICAg
ICBib3JkZXItcmFkaXVzOiAzcHg7DQogICAgICAgICAgICBmb250OiBpbmhlcml0Ow0KICAgICAg
ICAgICAgZm9udC1zaXplOiAxM3B4Ow0KICAgICAgICAgICAgZm9udC13ZWlnaHQ6IDYwMDsNCiAg
ICAgICAgICAgIGxpbmUtaGVpZ2h0OiAxLjQ1Ow0KICAgICAgICAgICAgd29yZC1icmVhazogYnJl
YWstYWxsOw0KICAgICAgICAgICAgb3ZlcmZsb3ctd3JhcDogYW55d2hlcmU7DQogICAgICAgICAg
ICAtd2Via2l0LWFwcC1yZWdpb246IG5vLWRyYWc7IGFwcC1yZWdpb246IG5vLWRyYWc7DQogICAg
ICAgICAgICBwb2ludGVyLWV2ZW50czogYXV0byAhaW1wb3J0YW50Ow0KICAgICAgICAgICAgcG9z
aXRpb246IHJlbGF0aXZlOw0KICAgICAgICAgICAgei1pbmRleDogODsNCiAgICAgICAgICAgIHRy
YW5zaXRpb246IGJhY2tncm91bmQgLjEycyBlYXNlLCBjb2xvciAuMTJzIGVhc2U7DQogICAgICAg
IH0NCiAgICAgICAgLnJmLXNlZzpob3ZlciB7DQogICAgICAgICAgICBiYWNrZ3JvdW5kOiByZ2Jh
KDkxLDExNSwyMzIsLjE0KTsNCiAgICAgICAgICAgIHRleHQtZGVjb3JhdGlvbjogdW5kZXJsaW5l
Ow0KICAgICAgICB9DQogICAgICAgIC5yZi1zZXAgew0KICAgICAgICAgICAgZGlzcGxheTogaW5s
aW5lOw0KICAgICAgICAgICAgY29sb3I6IHZhcigtLXR4dDMpOw0KICAgICAgICAgICAgcGFkZGlu
ZzogMCAxcHg7DQogICAgICAgICAgICBtYXJnaW46IDA7DQogICAgICAgICAgICB1c2VyLXNlbGVj
dDogbm9uZTsNCiAgICAgICAgICAgIG9wYWNpdHk6IC41NTsNCiAgICAgICAgICAgIHBvaW50ZXIt
ZXZlbnRzOiBub25lOw0KICAgICAgICAgICAgZm9udC1zaXplOiAxMnB4Ow0KICAgICAgICAgICAg
bGluZS1oZWlnaHQ6IDEuNDU7DQogICAgICAgIH0NCiAgICAgICAgLml0bS5yZi1maXhlZCAuaS1p
Y28gew0KICAgICAgICAgICAgYm94LXNoYWRvdzogMCAwIDAgMS41cHggcmdiYSg5MSwxMTUsMjMy
LC40NSk7DQogICAgICAgIH0NCiAgICAgICAgLnJmLXBpbi10YWcgew0KICAgICAgICAgICAgZGlz
cGxheTogaW5saW5lLWZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGp1c3RpZnktY29udGVudDog
Y2VudGVyOw0KICAgICAgICAgICAgZmxleC1zaHJpbms6IDA7DQogICAgICAgICAgICBoZWlnaHQ6
IDE2cHg7IHBhZGRpbmc6IDAgNnB4OyBtYXJnaW4tcmlnaHQ6IDA7DQogICAgICAgICAgICBib3Jk
ZXItcmFkaXVzOiA0cHg7DQogICAgICAgICAgICBmb250LXNpemU6IDEwcHg7IGZvbnQtd2VpZ2h0
OiA1MDA7DQogICAgICAgICAgICBjb2xvcjogIzdhODQ5OTsNCiAgICAgICAgICAgIGJhY2tncm91
bmQ6IHJnYmEoMTIyLDEzMiwxNTMsLjEyKTsNCiAgICAgICAgICAgIGJvcmRlcjogMXB4IHNvbGlk
IHJnYmEoMTIyLDEzMiwxNTMsLjIyKTsNCiAgICAgICAgICAgIGxldHRlci1zcGFjaW5nOiAuMDJl
bTsNCiAgICAgICAgICAgIHdoaXRlLXNwYWNlOiBub3dyYXA7DQogICAgICAgICAgICBwb2ludGVy
LWV2ZW50czogbm9uZTsNCiAgICAgICAgfQ0KICAgICAgICAuaS10aHVtYi13cmFwIHsNCiAgICAg
ICAgICAgIHdpZHRoOiAxMDAlOyBtaW4taGVpZ2h0OiA0OHB4OyBtYXgtaGVpZ2h0OiAxODBweDsg
bWFyZ2luLWJvdHRvbTogNHB4Ow0KICAgICAgICAgICAgZGlzcGxheTogZmxleDsgYWxpZ24taXRl
bXM6IGNlbnRlcjsganVzdGlmeS1jb250ZW50OiBjZW50ZXI7DQogICAgICAgICAgICBiYWNrZ3Jv
dW5kOiAjZjNmNWY5OyBib3JkZXItcmFkaXVzOiB2YXIoLS1yKTsgb3ZlcmZsb3c6IGhpZGRlbjsN
CiAgICAgICAgfQ0KICAgICAgICAuaS10aHVtYi13cmFwLndhaXRpbmcgew0KICAgICAgICAgICAg
bWluLWhlaWdodDogODhweDsNCiAgICAgICAgICAgIGJhY2tncm91bmQ6IGxpbmVhci1ncmFkaWVu
dCg5MGRlZywgI2U4ZWJmMiAwJSwgI2Y0ZjZmYSA0NSUsICNlOGViZjIgMTAwJSk7DQogICAgICAg
ICAgICBiYWNrZ3JvdW5kLXNpemU6IDIwMCUgMTAwJTsNCiAgICAgICAgICAgIGFuaW1hdGlvbjog
dGh1bWJTaGltbWVyIDEuMDVzIGVhc2UtaW4tb3V0IGluZmluaXRlOw0KICAgICAgICB9DQogICAg
ICAgIEBrZXlmcmFtZXMgdGh1bWJTaGltbWVyIHsNCiAgICAgICAgICAgIDAlIHsgYmFja2dyb3Vu
ZC1wb3NpdGlvbjogMTAwJSAwOyB9DQogICAgICAgICAgICAxMDAlIHsgYmFja2dyb3VuZC1wb3Np
dGlvbjogLTEwMCUgMDsgfQ0KICAgICAgICB9DQogICAgICAgIC5pLXRodW1iIHsgbWF4LXdpZHRo
OiAxMDAlOyBtYXgtaGVpZ2h0OiAxODBweDsgd2lkdGg6IGF1dG87IGhlaWdodDogYXV0bzsgb2Jq
ZWN0LWZpdDogY29udGFpbjsgZGlzcGxheTogYmxvY2s7IH0NCiAgICAgICAgLmktdGh1bWIudGh1
bWItbG9hZGluZyB7IG9wYWNpdHk6IDA7IHdpZHRoOiAxcHg7IGhlaWdodDogMXB4OyB9DQoNCiAg
ICAgICAgLyogTWV0YSBiYXI6IHRpbWUgbGVmdCB8IGV4cGFuZCBjZW50ZXIgfCB0YWdzIHJpZ2h0
ICovDQogICAgICAgIC5pLW1ldGEgew0KICAgICAgICAgICAgZGlzcGxheTogZ3JpZDsNCiAgICAg
ICAgICAgIGdyaWQtdGVtcGxhdGUtY29sdW1uczogMWZyIGF1dG8gMWZyOw0KICAgICAgICAgICAg
YWxpZ24taXRlbXM6IGNlbnRlcjsNCiAgICAgICAgICAgIGdhcDogNHB4Ow0KICAgICAgICAgICAg
bWFyZ2luLXRvcDogNHB4Ow0KICAgICAgICAgICAgd2lkdGg6IDEwMCU7DQogICAgICAgIH0NCiAg
ICAgICAgLmktbWV0YSAuaS10aW1lIHsganVzdGlmeS1zZWxmOiBzdGFydDsgfQ0KICAgICAgICAu
aS1tZXRhLWNlbnRlciB7DQogICAgICAgICAgICBqdXN0aWZ5LXNlbGY6IGNlbnRlcjsNCiAgICAg
ICAgICAgIGRpc3BsYXk6IGZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGp1c3RpZnktY29udGVu
dDogY2VudGVyOw0KICAgICAgICAgICAgZ2FwOiA0cHg7DQogICAgICAgICAgICBtaW4td2lkdGg6
IDFweDsgLyoga2VlcCBjZW50ZXIgY29sdW1uIGV2ZW4gd2hlbiBleHBhbmQgaXMgaGlkZGVuICov
DQogICAgICAgIH0NCiAgICAgICAgLmktbWV0YS1yaWdodCB7DQogICAgICAgICAgICBqdXN0aWZ5
LXNlbGY6IGVuZDsNCiAgICAgICAgICAgIGRpc3BsYXk6IGZsZXg7IGFsaWduLWl0ZW1zOiBjZW50
ZXI7IGdhcDogNXB4OyBmbGV4LXdyYXA6IG5vd3JhcDsNCiAgICAgICAgICAgIGp1c3RpZnktY29u
dGVudDogZmxleC1lbmQ7DQogICAgICAgICAgICBtaW4td2lkdGg6IDA7DQogICAgICAgIH0NCiAg
ICAgICAgLmktbWV0YS1yaWdodC50ZXh0LW1ldGEgew0KICAgICAgICAgICAgZmxleC13cmFwOiBu
b3dyYXA7DQogICAgICAgICAgICBnYXA6IDRweDsNCiAgICAgICAgfQ0KICAgICAgICAuaS1zcmMt
dGl0bGUgew0KICAgICAgICAgICAgZm9udC1zaXplOiAxMHB4Ow0KICAgICAgICAgICAgY29sb3I6
IHZhcigtLXR4dDMpOw0KICAgICAgICAgICAgbWF4LXdpZHRoOiAxMWVtOw0KICAgICAgICAgICAg
b3ZlcmZsb3c6IGhpZGRlbjsNCiAgICAgICAgICAgIHRleHQtb3ZlcmZsb3c6IGVsbGlwc2lzOw0K
ICAgICAgICAgICAgd2hpdGUtc3BhY2U6IG5vd3JhcDsNCiAgICAgICAgICAgIG1pbi13aWR0aDog
MDsNCiAgICAgICAgICAgIGxpbmUtaGVpZ2h0OiAxLjQ7DQogICAgICAgIH0NCiAgICAgICAgLmkt
dGltZSwgLmktdGFnIHsgZm9udC1zaXplOiAxMHB4OyBjb2xvcjogdmFyKC0tdHh0Myk7IH0NCiAg
ICAgICAgLmktdGFnIHsNCiAgICAgICAgICAgIGJhY2tncm91bmQ6ICNmMWYzZjg7IHBhZGRpbmc6
IDAgNXB4OyBib3JkZXItcmFkaXVzOiAzcHg7DQogICAgICAgICAgICB3aGl0ZS1zcGFjZTogbm93
cmFwOyBmbGV4LXNocmluazogMDsgbGluZS1oZWlnaHQ6IDEuNDsNCiAgICAgICAgfQ0KICAgICAg
ICAuaS1jaGFycyB7DQogICAgICAgICAgICBmb250LXNpemU6IDEwcHg7IGNvbG9yOiB2YXIoLS10
eHQzKTsNCiAgICAgICAgICAgIGJhY2tncm91bmQ6ICNmMWYzZjg7IHBhZGRpbmc6IDAgNXB4OyBi
b3JkZXItcmFkaXVzOiAzcHg7DQogICAgICAgICAgICBmb250LXZhcmlhbnQtbnVtZXJpYzogdGFi
dWxhci1udW1zOw0KICAgICAgICAgICAgd2hpdGUtc3BhY2U6IG5vd3JhcDsNCiAgICAgICAgICAg
IGRpc3BsYXk6IGlubGluZS1mbGV4OyBhbGlnbi1pdGVtczogYmFzZWxpbmU7IGdhcDogMnB4Ow0K
ICAgICAgICB9DQogICAgICAgIC5pLWNoYXJzIC5uIHsNCiAgICAgICAgICAgIGRpc3BsYXk6IGlu
bGluZS1ibG9jazsNCiAgICAgICAgICAgIG1pbi13aWR0aDogNGNoOw0KICAgICAgICAgICAgdGV4
dC1hbGlnbjogcmlnaHQ7DQogICAgICAgICAgICBmb250LWZhbWlseTogJ0Nhc2NhZGlhIE1vbm8n
LCAnQ29uc29sYXMnLCAnU2FyYXNhIE1vbm8gU0MnLCB1aS1tb25vc3BhY2UsIG1vbm9zcGFjZTsN
CiAgICAgICAgICAgIGZvbnQtd2VpZ2h0OiA2MDA7DQogICAgICAgICAgICBjb2xvcjogdmFyKC0t
dHh0Mik7DQogICAgICAgIH0NCiAgICAgICAgLyogc3JjLXRpdGxlLXRpcCAqLw0KICAgICAgICAu
aS1zcmMtaWNvLCAubWctc3JjIHsgY3Vyc29yOiBwb2ludGVyOyB9DQogICAgICAgICNzcmMtdGlw
IHsNCiAgICAgICAgICAgIHBvc2l0aW9uOiBmaXhlZDsgei1pbmRleDogOTk5OTk7DQogICAgICAg
ICAgICBtYXgtd2lkdGg6IG1pbigyODBweCwgY2FsYygxMDB2dyAtIDE2cHgpKTsNCiAgICAgICAg
ICAgIHBhZGRpbmc6IDZweCAxMHB4Ow0KICAgICAgICAgICAgYm9yZGVyLXJhZGl1czogOHB4Ow0K
ICAgICAgICAgICAgYmFja2dyb3VuZDogcmdiYSgzMiwzNiw0OCwuOTIpOyBjb2xvcjogI2ZmZjsN
CiAgICAgICAgICAgIGZvbnQtc2l6ZTogMTJweDsgbGluZS1oZWlnaHQ6IDEuMzU7DQogICAgICAg
ICAgICBib3gtc2hhZG93OiAwIDZweCAxOHB4IHJnYmEoMCwwLDAsLjIyKTsNCiAgICAgICAgICAg
IHBvaW50ZXItZXZlbnRzOiBub25lOw0KICAgICAgICAgICAgb3BhY2l0eTogMDsgdHJhbnNmb3Jt
OiB0cmFuc2xhdGVZKDRweCk7DQogICAgICAgICAgICB0cmFuc2l0aW9uOiBvcGFjaXR5IC4ycyBl
YXNlLCB0cmFuc2Zvcm0gLjIycyBjdWJpYy1iZXppZXIoLjIyLDEsLjM2LDEpOw0KICAgICAgICAg
ICAgd29yZC1icmVhazogYnJlYWstd29yZDsNCiAgICAgICAgfQ0KICAgICAgICAjc3JjLXRpcC5z
aG93IHsgb3BhY2l0eTogMTsgdHJhbnNmb3JtOiB0cmFuc2xhdGVZKDApOyB9DQogICAgICAgIC5p
LXNyYy1pY28gew0KICAgICAgICAgICAgd2lkdGg6IDE0cHg7IGhlaWdodDogMTRweDsgZmxleC1z
aHJpbms6IDA7DQogICAgICAgICAgICBib3JkZXItcmFkaXVzOiAycHg7IG9iamVjdC1maXQ6IGNv
bnRhaW47DQogICAgICAgICAgICBkaXNwbGF5OiBibG9jazsNCiAgICAgICAgfQ0KICAgICAgICAu
aS1udW0gew0KICAgICAgICAgICAgZGlzcGxheTogZmxleDsgZmxleC1kaXJlY3Rpb246IGNvbHVt
bjsgYWxpZ24taXRlbXM6IGZsZXgtZW5kOw0KICAgICAgICAgICAganVzdGlmeS1jb250ZW50OiBz
cGFjZS1iZXR3ZWVuOw0KICAgICAgICAgICAgYWxpZ24tc2VsZjogc3RyZXRjaDsNCiAgICAgICAg
ICAgIGZvbnQtc2l6ZTogMTBweDsgY29sb3I6IHZhcigtLXR4dDMpOyBtaW4td2lkdGg6IDE2cHg7
DQogICAgICAgICAgICB0ZXh0LWFsaWduOiByaWdodDsgZmxleC1zaHJpbms6IDA7DQogICAgICAg
ICAgICBwYWRkaW5nLXRvcDogMnB4Ow0KICAgICAgICB9DQogICAgICAgIC5pLW51bSAuaS1zcmMt
aWNvIHsgd2lkdGg6IDE2cHg7IGhlaWdodDogMTZweDsgbWFyZ2luLXRvcDogYXV0bzsgfQ0KDQog
ICAgICAgIC5pLWV4cGFuZC1idG4gew0KICAgICAgICAgICAgYm9yZGVyOiBub25lOyBiYWNrZ3Jv
dW5kOiBub25lOyBjdXJzb3I6IHBvaW50ZXI7DQogICAgICAgICAgICBjb2xvcjogdmFyKC0tdHh0
Myk7IGZvbnQtc2l6ZTogMTJweDsgcGFkZGluZzogM3B4IDEwcHg7DQogICAgICAgICAgICBib3Jk
ZXItcmFkaXVzOiA4cHg7IGRpc3BsYXk6IG5vbmU7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGdhcDog
NHB4Ow0KICAgICAgICAgICAgdHJhbnNpdGlvbjogY29sb3IgdmFyKC0tdHIpLCBiYWNrZ3JvdW5k
IHZhcigtLXRyKTsNCiAgICAgICAgICAgIC13ZWJraXQtYXBwLXJlZ2lvbjogbm8tZHJhZzsgYXBw
LXJlZ2lvbjogbm8tZHJhZzsNCiAgICAgICAgICAgIGxpbmUtaGVpZ2h0OiAxLjI7DQogICAgICAg
IH0NCiAgICAgICAgLmktZXhwYW5kLWJ0biBzdmcgeyB3aWR0aDogMTRweDsgaGVpZ2h0OiAxNHB4
OyBmbGV4LXNocmluazogMDsgfQ0KICAgICAgICAuaS1leHBhbmQtYnRuLm9uIHsgZGlzcGxheTog
aW5saW5lLWZsZXg7IH0NCiAgICAgICAgLmktZXhwYW5kLWJ0bjpob3ZlciB7IGNvbG9yOiB2YXIo
LS1hY2MpOyBiYWNrZ3JvdW5kOiByZ2JhKDkxLDExNSwyMzIsLjA4KTsgfQ0KICAgICAgICAuaS1w
cmV2LmV4cGFuZGVkLCAuaS1uYW1lLmV4cGFuZGVkIHsNCiAgICAgICAgICAgIC13ZWJraXQtbGlu
ZS1jbGFtcDogdW5zZXQ7DQogICAgICAgICAgICBkaXNwbGF5OiBibG9jazsNCiAgICAgICAgICAg
IG92ZXJmbG93OiBoaWRkZW47DQogICAgICAgICAgICAvKiDpq5jluqbnlLEgSlMg5oyJ5YiX6KGo
5Y+v6KeG5Yy66K6+5a6a77ya57qm5Y2g5pW06KGo5bCR5LiA6KGMICovDQogICAgICAgIH0NCiAg
ICAgICAgLmktc3JjLXRpdGxlIHsgZGlzcGxheTogbm9uZSAhaW1wb3J0YW50OyB9DQogICAgICAg
IC5pLWZpbGUtZGV0YWlsIHsNCiAgICAgICAgICAgIGRpc3BsYXk6IG5vbmU7DQogICAgICAgICAg
ICBtYXJnaW4tdG9wOiA0cHg7DQogICAgICAgICAgICBwYWRkaW5nOiAwOw0KICAgICAgICAgICAg
YmFja2dyb3VuZDogbm9uZTsNCiAgICAgICAgICAgIGJvcmRlcjogbm9uZTsNCiAgICAgICAgfQ0K
ICAgICAgICAuaS1maWxlLWRldGFpbC5vbiB7IGRpc3BsYXk6IGJsb2NrOyB9DQogICAgICAgIC5m
ZC1ibG9jayB7DQogICAgICAgICAgICBkaXNwbGF5OiBmbGV4OyBmbGV4LWRpcmVjdGlvbjogY29s
dW1uOyBnYXA6IDZweDsNCiAgICAgICAgfQ0KICAgICAgICAuZmQtYmxvY2sgKyAuZmQtYmxvY2sg
eyBtYXJnaW4tdG9wOiA4cHg7IH0NCiAgICAgICAgLmZkLXBhdGggew0KICAgICAgICAgICAgd2lk
dGg6IDEwMCU7DQogICAgICAgICAgICBmb250OiA2MDAgMTJweC8xLjU1ICdTZWdvZSBVSSBWYXJp
YWJsZSBUZXh0JywnU2Vnb2UgVUknLCdNaWNyb3NvZnQgWWFIZWkgVUknLHNhbnMtc2VyaWY7DQog
ICAgICAgICAgICBjb2xvcjogdmFyKC0tdHh0Mik7DQogICAgICAgICAgICBsZXR0ZXItc3BhY2lu
ZzogLjAxZW07DQogICAgICAgICAgICB3b3JkLWJyZWFrOiBicmVhay1hbGw7DQogICAgICAgICAg
ICB1c2VyLXNlbGVjdDogdGV4dDsNCiAgICAgICAgICAgIC13ZWJraXQtYXBwLXJlZ2lvbjogbm8t
ZHJhZzsgYXBwLXJlZ2lvbjogbm8tZHJhZzsNCiAgICAgICAgfQ0KICAgICAgICAuZmQtcGF0aC5s
aXZlIHsgY3Vyc29yOiBwb2ludGVyOyB9DQogICAgICAgIC5mZC1wYXRoLmxpdmU6aG92ZXIgeyBj
b2xvcjogdmFyKC0tYWNjKTsgfQ0KICAgICAgICAuZmQtcGF0aC5kZWFkIHsNCiAgICAgICAgICAg
IGNvbG9yOiAjOWFhMGIwOw0KICAgICAgICAgICAgdGV4dC1kZWNvcmF0aW9uOiBsaW5lLXRocm91
Z2g7DQogICAgICAgICAgICB0ZXh0LWRlY29yYXRpb24tdGhpY2tuZXNzOiAycHg7DQogICAgICAg
ICAgICB0ZXh0LWRlY29yYXRpb24tY29sb3I6IHJnYmEoMTU0LCAxNjAsIDE3NiwgLjU1KTsNCiAg
ICAgICAgICAgIHRleHQtZGVjb3JhdGlvbi1za2lwLWluazogbm9uZTsNCiAgICAgICAgICAgIGN1
cnNvcjogZGVmYXVsdDsNCiAgICAgICAgfQ0KICAgICAgICAuZmQtYWN0aW9ucyB7DQogICAgICAg
ICAgICBkaXNwbGF5OiBmbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBqdXN0aWZ5LWNvbnRlbnQ6
IGZsZXgtZW5kOw0KICAgICAgICAgICAgZ2FwOiA4cHg7IGZsZXgtd3JhcDogd3JhcDsNCiAgICAg
ICAgfQ0KICAgICAgICAuZmQtYnRuIHsNCiAgICAgICAgICAgIGJvcmRlcjogbm9uZTsgYmFja2dy
b3VuZDogbm9uZTsgY3Vyc29yOiBwb2ludGVyOw0KICAgICAgICAgICAgY29sb3I6IHZhcigtLXR4
dDMpOyBmb250LXNpemU6IDEwcHg7IGZvbnQtd2VpZ2h0OiA2MDA7DQogICAgICAgICAgICBwYWRk
aW5nOiAxcHggMnB4OyBkaXNwbGF5OiBpbmxpbmUtZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsg
Z2FwOiAycHg7DQogICAgICAgICAgICB3aGl0ZS1zcGFjZTogbm93cmFwOw0KICAgICAgICAgICAg
LXdlYmtpdC1hcHAtcmVnaW9uOiBuby1kcmFnOyBhcHAtcmVnaW9uOiBuby1kcmFnOw0KICAgICAg
ICAgICAgdHJhbnNpdGlvbjogY29sb3IgdmFyKC0tdHIpOw0KICAgICAgICB9DQogICAgICAgIC5m
ZC1idG46aG92ZXIgeyBjb2xvcjogdmFyKC0tYWNjKTsgfQ0KICAgICAgICAuZmQtYnRuLm9rIHsg
Y29sb3I6ICMxZjdhNTU7IH0NCg0KICAgICAgICAvKiDilIDilIAgQ29udGV4dCBtZW51IOKUgOKU
gOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKU
gOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgCAqLw0KICAgICAgICAjY3R4IHsNCiAg
ICAgICAgICAgIHBvc2l0aW9uOiBmaXhlZDsgei1pbmRleDogOTk5OTsgbWluLXdpZHRoOiAxMzJw
eDsgZGlzcGxheTogbm9uZTsgcGFkZGluZzogNHB4Ow0KICAgICAgICAgICAgYmFja2dyb3VuZDog
I2ZmZjsgYm9yZGVyLXJhZGl1czogdmFyKC0tcik7IGJveC1zaGFkb3c6IDAgNnB4IDE2cHggcmdi
YSgwLDAsMCwuMTQpOw0KICAgICAgICAgICAgLXdlYmtpdC1hcHAtcmVnaW9uOiBuby1kcmFnOyBh
cHAtcmVnaW9uOiBuby1kcmFnOw0KICAgICAgICB9DQogICAgICAgICNjdHgub24geyBkaXNwbGF5
OiBibG9jazsgfQ0KICAgICAgICAuYy1pdGVtIHsNCiAgICAgICAgICAgIGRpc3BsYXk6IGZsZXg7
IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGdhcDogN3B4OyBwYWRkaW5nOiA2cHggOXB4Ow0KICAgICAg
ICAgICAgYm9yZGVyLXJhZGl1czogdmFyKC0tcik7IGN1cnNvcjogcG9pbnRlcjsgZm9udC1zaXpl
OiAxMXB4OyBjb2xvcjogdmFyKC0tdHh0KTsNCiAgICAgICAgfQ0KICAgICAgICAuYy1pdGVtOmhv
dmVyIHsgYmFja2dyb3VuZDogI2YyZjRmOTsgfQ0KICAgICAgICAuYy1pdGVtLmRhbmdlciB7IGNv
bG9yOiAjZmY3YjljOyB9DQogICAgICAgIC5jLXNlcCB7IGhlaWdodDogMXB4OyBiYWNrZ3JvdW5k
OiAjZWNlZmY1OyBtYXJnaW46IDNweCAwOyB9DQogICAgICAgIC5jLWljbyB7IHdpZHRoOiAxNHB4
OyB0ZXh0LWFsaWduOiBjZW50ZXI7IH0NCiAgICAgICAgLmMtaWNvLnN0YXIgew0KICAgICAgICAg
ICAgd2lkdGg6IDE2cHg7IGZvbnQtc2l6ZTogMTNweDsgbGluZS1oZWlnaHQ6IDE7DQogICAgICAg
ICAgICBmaWx0ZXI6IG5vbmU7IGNvbG9yOiAjZjVhNjIzOw0KICAgICAgICB9DQogICAgICAgIC5j
LXN1YndyYXAgeyBwb3NpdGlvbjogcmVsYXRpdmU7IH0NCiAgICAgICAgLmMtc3Vid3JhcCA+IC5j
LWl0ZW0geyB3aWR0aDogMTAwJTsgYm94LXNpemluZzogYm9yZGVyLWJveDsgfQ0KICAgICAgICAu
Yy1jYXJldCB7IG1hcmdpbi1sZWZ0OiBhdXRvOyBjb2xvcjogdmFyKC0tdHh0Myk7IGZvbnQtc2l6
ZTogMTBweDsgfQ0KICAgICAgICAuYy1zdWIgew0KICAgICAgICAgICAgZGlzcGxheTogbm9uZTsg
cG9zaXRpb246IGFic29sdXRlOyBsZWZ0OiBjYWxjKDEwMCUgLSAycHgpOyB0b3A6IC0ycHg7IHot
aW5kZXg6IDE7DQogICAgICAgICAgICBtaW4td2lkdGg6IDA7IHdpZHRoOiBtYXgtY29udGVudDsg
cGFkZGluZzogMnB4Ow0KICAgICAgICAgICAgYmFja2dyb3VuZDogI2ZmZjsgYm9yZGVyLXJhZGl1
czogdmFyKC0tcik7DQogICAgICAgICAgICBib3gtc2hhZG93OiAwIDZweCAxNnB4IHJnYmEoMCww
LDAsLjE0KTsNCiAgICAgICAgfQ0KICAgICAgICAuYy1zdWIubGVmdCB7DQogICAgICAgICAgICBs
ZWZ0OiBhdXRvOyByaWdodDogY2FsYygxMDAlIC0gMnB4KTsNCiAgICAgICAgfQ0KICAgICAgICAu
Yy1zdWJ3cmFwOmhvdmVyID4gLmMtc3ViLA0KICAgICAgICAuYy1zdWJ3cmFwLm9wZW4gPiAuYy1z
dWIgeyBkaXNwbGF5OiBibG9jazsgfQ0KICAgICAgICAuYy1zdWIgLmMtaXRlbSB7DQogICAgICAg
ICAgICBmb250LWZhbWlseTogdWktbW9ub3NwYWNlLCBDb25zb2xhcywgIkNhc2NhZGlhIE1vbm8i
LCBtb25vc3BhY2U7DQogICAgICAgICAgICBmb250LXNpemU6IDEwcHg7IHdoaXRlLXNwYWNlOiBu
b3dyYXA7DQogICAgICAgICAgICBwYWRkaW5nOiA0cHggN3B4OyBnYXA6IDA7DQogICAgICAgIH0N
CiAgICAgICAgLmMtc3ViIC5jLWl0ZW0ucGljayB7DQogICAgICAgICAgICBiYWNrZ3JvdW5kOiBy
Z2JhKDkxLCAxMjQsIDI1MCwgLjE0KTsNCiAgICAgICAgICAgIGNvbG9yOiAjM2I1YmRiOw0KICAg
ICAgICAgICAgZm9udC13ZWlnaHQ6IDYwMDsNCiAgICAgICAgfQ0KICAgICAgICAuYy1zdWIgLmMt
aXRlbS5waWNrIC5jLW51bSwNCiAgICAgICAgLmMtc3ViIC5jLWl0ZW0ucGljayAuYy1hcnJvdyB7
IGNvbG9yOiAjNWI3Y2ZhOyB9DQogICAgICAgIC5jLXN1YiAuYy1udW0gew0KICAgICAgICAgICAg
d2lkdGg6IDEycHg7IGZsZXgtc2hyaW5rOiAwOyBjb2xvcjogdmFyKC0tdHh0Myk7IHRleHQtYWxp
Z246IGxlZnQ7DQogICAgICAgICAgICBtYXJnaW4tcmlnaHQ6IDRweDsNCiAgICAgICAgfQ0KICAg
ICAgICAuYy1zdWIgLmMtZnJvbSB7DQogICAgICAgICAgICBkaXNwbGF5OiBpbmxpbmUtYmxvY2s7
IG1pbi13aWR0aDogMDsgdGV4dC1hbGlnbjogbGVmdDsgZmxleC1zaHJpbms6IDA7DQogICAgICAg
IH0NCiAgICAgICAgLmMtc3ViIC5jLWFycm93IHsNCiAgICAgICAgICAgIGRpc3BsYXk6IGlubGlu
ZS1ibG9jazsgcGFkZGluZzogMCA0cHg7IGNvbG9yOiB2YXIoLS10eHQzKTsgZmxleC1zaHJpbms6
IDA7DQogICAgICAgIH0NCiAgICAgICAgLmMtc3ViIC5jLXRvIHsgZmxleC1zaHJpbms6IDA7IH0N
Cg0KICAgICAgICAvKiDilIDilIAgQ2xlYXIgY29uZmlybSDilIDilIDilIDilIDilIDilIDilIDi
lIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDi
lIDilIDilIDilIDilIAgKi8NCiAgICAgICAgI2Nsci1kbGcgew0KICAgICAgICAgICAgZGlzcGxh
eTogbm9uZTsgcG9zaXRpb246IGZpeGVkOyBpbnNldDogMDsgei1pbmRleDogMTAwMDA7DQogICAg
ICAgICAgICBiYWNrZ3JvdW5kOiByZ2JhKDIwLCAyMiwgMzUsIC40Mik7DQogICAgICAgICAgICBh
bGlnbi1pdGVtczogY2VudGVyOyBqdXN0aWZ5LWNvbnRlbnQ6IGNlbnRlcjsNCiAgICAgICAgICAg
IC13ZWJraXQtYXBwLXJlZ2lvbjogbm8tZHJhZzsgYXBwLXJlZ2lvbjogbm8tZHJhZzsNCiAgICAg
ICAgfQ0KICAgICAgICAjY2xyLWRsZy5vbiB7IGRpc3BsYXk6IGZsZXg7IH0NCiAgICAgICAgLmNs
ci1ib3ggew0KICAgICAgICAgICAgd2lkdGg6IG1pbigyODBweCwgY2FsYygxMDAlIC0gMzJweCkp
Ow0KICAgICAgICAgICAgYmFja2dyb3VuZDogI2ZmZjsgYm9yZGVyLXJhZGl1czogMTJweDsNCiAg
ICAgICAgICAgIGJveC1zaGFkb3c6IDAgMTJweCAzMnB4IHJnYmEoMCwwLDAsLjE4KTsNCiAgICAg
ICAgICAgIHBhZGRpbmc6IDE2cHggMTZweCAxNHB4OyBjb2xvcjogdmFyKC0tdHh0KTsNCiAgICAg
ICAgfQ0KICAgICAgICAuY2xyLXRpdGxlIHsgZm9udC1zaXplOiAxNHB4OyBmb250LXdlaWdodDog
NzAwOyBtYXJnaW4tYm90dG9tOiA2cHg7IH0NCiAgICAgICAgLmNsci1kZXNjIHsgZm9udC1zaXpl
OiAxMXB4OyBjb2xvcjogdmFyKC0tdHh0Myk7IGxpbmUtaGVpZ2h0OiAxLjU7IG1hcmdpbi1ib3R0
b206IDEycHg7IH0NCiAgICAgICAgLmNsci1jaGVjayB7DQogICAgICAgICAgICBkaXNwbGF5OiBm
bGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBnYXA6IDdweDsNCiAgICAgICAgICAgIGZvbnQtc2l6
ZTogMTJweDsgY29sb3I6IHZhcigtLXR4dCk7IGN1cnNvcjogcG9pbnRlcjsNCiAgICAgICAgICAg
IHVzZXItc2VsZWN0OiBub25lOyBtYXJnaW4tYm90dG9tOiAxNHB4Ow0KICAgICAgICB9DQogICAg
ICAgIC5jbHItY2hlY2sgaW5wdXQgew0KICAgICAgICAgICAgd2lkdGg6IDE0cHg7IGhlaWdodDog
MTRweDsgYWNjZW50LWNvbG9yOiB2YXIoLS1hY2MpOyBjdXJzb3I6IHBvaW50ZXI7DQogICAgICAg
IH0NCiAgICAgICAgLmNsci1idG5zIHsgZGlzcGxheTogZmxleDsgZ2FwOiA4cHg7IGp1c3RpZnkt
Y29udGVudDogZmxleC1lbmQ7IH0NCiAgICAgICAgLmNsci1idG5zIGJ1dHRvbiB7DQogICAgICAg
ICAgICBib3JkZXI6IG5vbmU7IGJvcmRlci1yYWRpdXM6IDhweDsgcGFkZGluZzogN3B4IDE0cHg7
DQogICAgICAgICAgICBmb250LXNpemU6IDEycHg7IGN1cnNvcjogcG9pbnRlcjsgZm9udC13ZWln
aHQ6IDYwMDsNCiAgICAgICAgICAgIHRyYW5zaXRpb246IGJhY2tncm91bmQgdmFyKC0tdHIpLCBj
b2xvciB2YXIoLS10cik7DQogICAgICAgIH0NCiAgICAgICAgI2Nsci1jYW5jZWwgeyBiYWNrZ3Jv
dW5kOiAjZjFmM2Y4OyBjb2xvcjogdmFyKC0tdHh0Mik7IH0NCiAgICAgICAgI2Nsci1jYW5jZWw6
aG92ZXIgeyBiYWNrZ3JvdW5kOiAjZTZlOWYyOyB9DQogICAgICAgICNjbHItb2sgeyBiYWNrZ3Jv
dW5kOiByZ2JhKDI1NSwxMjMsMTU2LC4xNCk7IGNvbG9yOiAjZTg1YTdhOyB9DQogICAgICAgICNj
bHItb2s6aG92ZXIgeyBiYWNrZ3JvdW5kOiByZ2JhKDI1NSwxMjMsMTU2LC4yNCk7IH0NCg0KICAg
ICAgICAvKiDilIDilIAgRmlsZSBwYXRoIHRpcCDilIDilIDilIDilIDilIDilIDilIDilIDilIDi
lIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDi
lIDilIDilIAgKi8NCiAgICAgICAgI3BhdGgtdGlwIHsNCiAgICAgICAgICAgIGRpc3BsYXk6IG5v
bmU7IHBvc2l0aW9uOiBmaXhlZDsgei1pbmRleDogMTAwMDE7DQogICAgICAgICAgICB3aWR0aDog
bWluKDMyMHB4LCBjYWxjKDEwMHZ3IC0gMTZweCkpOw0KICAgICAgICAgICAgbWF4LWhlaWdodDog
bWluKDI4MHB4LCBjYWxjKDEwMHZoIC0gMjRweCkpOw0KICAgICAgICAgICAgb3ZlcmZsb3c6IGF1
dG87DQogICAgICAgICAgICBwYWRkaW5nOiAwOw0KICAgICAgICAgICAgYmFja2dyb3VuZDogbGlu
ZWFyLWdyYWRpZW50KDE2NWRlZywgI2ZmZmZmZiAwJSwgI2Y2ZjhmYyAxMDAlKTsNCiAgICAgICAg
ICAgIGJvcmRlcjogMXB4IHNvbGlkIHJnYmEoNzAsIDg0LCAxMjAsIC4xKTsNCiAgICAgICAgICAg
IGJvcmRlci1yYWRpdXM6IDEycHg7DQogICAgICAgICAgICBib3gtc2hhZG93Og0KICAgICAgICAg
ICAgICAgIDAgNHB4IDZweCByZ2JhKDMwLCA0MCwgNzAsIC4wNCksDQogICAgICAgICAgICAgICAg
MCAxNHB4IDM2cHggcmdiYSgzMCwgNDAsIDcwLCAuMTYpOw0KICAgICAgICAgICAgY29sb3I6IHZh
cigtLXR4dCk7DQogICAgICAgICAgICBwb2ludGVyLWV2ZW50czogYXV0bzsNCiAgICAgICAgICAg
IG9wYWNpdHk6IDA7DQogICAgICAgICAgICB0cmFuc2Zvcm06IHRyYW5zbGF0ZVkoNHB4KSBzY2Fs
ZSguOTgpOw0KICAgICAgICAgICAgdHJhbnNpdGlvbjogb3BhY2l0eSAuMTRzIGVhc2UsIHRyYW5z
Zm9ybSAuMTRzIGVhc2U7DQogICAgICAgICAgICAtd2Via2l0LWFwcC1yZWdpb246IG5vLWRyYWc7
IGFwcC1yZWdpb246IG5vLWRyYWc7DQogICAgICAgIH0NCiAgICAgICAgI3BhdGgtdGlwLm9uIHsN
CiAgICAgICAgICAgIGRpc3BsYXk6IGJsb2NrOw0KICAgICAgICAgICAgb3BhY2l0eTogMTsNCiAg
ICAgICAgICAgIHRyYW5zZm9ybTogdHJhbnNsYXRlWSgwKSBzY2FsZSgxKTsNCiAgICAgICAgfQ0K
ICAgICAgICAucHQtaGVhZCB7DQogICAgICAgICAgICBkaXNwbGF5OiBmbGV4OyBhbGlnbi1pdGVt
czogY2VudGVyOyBqdXN0aWZ5LWNvbnRlbnQ6IHNwYWNlLWJldHdlZW47DQogICAgICAgICAgICBn
YXA6IDEwcHg7IHBhZGRpbmc6IDEwcHggMTJweCA4cHg7DQogICAgICAgICAgICBib3JkZXItYm90
dG9tOiAxcHggc29saWQgcmdiYSg3MCwgODQsIDEyMCwgLjA3KTsNCiAgICAgICAgfQ0KICAgICAg
ICAucHQtdGl0bGUgew0KICAgICAgICAgICAgZm9udC1zaXplOiAxMXB4OyBmb250LXdlaWdodDog
NzAwOyBsZXR0ZXItc3BhY2luZzogLjA0ZW07DQogICAgICAgICAgICBjb2xvcjogdmFyKC0tdHh0
Mik7IHRleHQtdHJhbnNmb3JtOiB1cHBlcmNhc2U7DQogICAgICAgICAgICBmbGV4LXNocmluazog
MDsNCiAgICAgICAgfQ0KICAgICAgICAucHQtaGVhZC1idG4gew0KICAgICAgICAgICAgZmxleC1z
aHJpbms6IDA7IG1hcmdpbi1sZWZ0OiBhdXRvOw0KICAgICAgICAgICAgaGVpZ2h0OiAyMnB4OyBw
YWRkaW5nOiAwIDhweDsgZGlzcGxheTogaW5saW5lLWZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7
IGdhcDogNHB4Ow0KICAgICAgICAgICAgYm9yZGVyOiAxcHggc29saWQgcmdiYSgxMDcsMTEyLDEy
OCwuMjIpOyBib3JkZXItcmFkaXVzOiA2cHg7IGN1cnNvcjogcG9pbnRlcjsNCiAgICAgICAgICAg
IGJhY2tncm91bmQ6IHJnYmEoMTA3LDExMiwxMjgsLjA2KTsgY29sb3I6ICM4YTkwYTA7IGZvbnQt
c2l6ZTogMTFweDsgZm9udC13ZWlnaHQ6IDYwMDsNCiAgICAgICAgICAgIHdoaXRlLXNwYWNlOiBu
b3dyYXA7DQogICAgICAgICAgICAtd2Via2l0LWFwcC1yZWdpb246IG5vLWRyYWc7IGFwcC1yZWdp
b246IG5vLWRyYWc7DQogICAgICAgICAgICB0cmFuc2l0aW9uOiBiYWNrZ3JvdW5kIHZhcigtLXRy
KSwgY29sb3IgdmFyKC0tdHIpLCBib3JkZXItY29sb3IgdmFyKC0tdHIpOw0KICAgICAgICB9DQog
ICAgICAgIC5wdC1oZWFkLWJ0bjpob3ZlciB7DQogICAgICAgICAgICBiYWNrZ3JvdW5kOiByZ2Jh
KDEwNywxMTIsMTI4LC4xMik7IGNvbG9yOiB2YXIoLS10eHQyKTsNCiAgICAgICAgICAgIGJvcmRl
ci1jb2xvcjogcmdiYSgxMDcsMTEyLDEyOCwuNCk7DQogICAgICAgIH0NCiAgICAgICAgLnB0LWxp
c3QgeyBwYWRkaW5nOiA2cHggOHB4IDhweDsgZGlzcGxheTogZmxleDsgZmxleC1kaXJlY3Rpb246
IGNvbHVtbjsgZ2FwOiA0cHg7IH0NCiAgICAgICAgLnB0LXJvdyB7DQogICAgICAgICAgICBkaXNw
bGF5OiBncmlkOyBncmlkLXRlbXBsYXRlLWNvbHVtbnM6IDhweCAxZnI7IGdhcDogOHB4Ow0KICAg
ICAgICAgICAgcGFkZGluZzogOHB4IDhweDsgYm9yZGVyLXJhZGl1czogOHB4Ow0KICAgICAgICAg
ICAgYmFja2dyb3VuZDogcmdiYSgyNTUsMjU1LDI1NSwuNyk7DQogICAgICAgIH0NCiAgICAgICAg
LnB0LXJvdy5kZWFkIHsgYmFja2dyb3VuZDogcmdiYSgyNTUsIDEyMywgMTU2LCAuMDYpOyB9DQog
ICAgICAgIC5wdC1kb3Qgew0KICAgICAgICAgICAgd2lkdGg6IDhweDsgaGVpZ2h0OiA4cHg7IGJv
cmRlci1yYWRpdXM6IDUwJTsgbWFyZ2luLXRvcDogNXB4Ow0KICAgICAgICAgICAgYmFja2dyb3Vu
ZDogIzJlYjQ3ODsgYm94LXNoYWRvdzogMCAwIDAgM3B4IHJnYmEoNDYsIDE4MCwgMTIwLCAuMTgp
Ow0KICAgICAgICB9DQogICAgICAgIC5wdC1yb3cuZGVhZCAucHQtZG90IHsNCiAgICAgICAgICAg
IGJhY2tncm91bmQ6ICNlODVhN2E7IGJveC1zaGFkb3c6IDAgMCAwIDNweCByZ2JhKDIzMiwgOTAs
IDEyMiwgLjE2KTsNCiAgICAgICAgfQ0KICAgICAgICAucHQtbmFtZSB7DQogICAgICAgICAgICBm
b250LXNpemU6IDEycHg7IGZvbnQtd2VpZ2h0OiA2NTA7IGNvbG9yOiB2YXIoLS10eHQpOw0KICAg
ICAgICAgICAgbGluZS1oZWlnaHQ6IDEuMzsgd29yZC1icmVhazogYnJlYWstYWxsOw0KICAgICAg
ICB9DQogICAgICAgIC5wdC1wYXRoIHsNCiAgICAgICAgICAgIG1hcmdpbi10b3A6IDNweDsNCiAg
ICAgICAgICAgIGZvbnQ6IDEwLjVweC8xLjQ1ICdDYXNjYWRpYSBNb25vJywnQ29uc29sYXMnLCdN
aWNyb3NvZnQgWWFIZWkgVUknLG1vbm9zcGFjZTsNCiAgICAgICAgICAgIGNvbG9yOiB2YXIoLS10
eHQyKTsgd29yZC1icmVhazogYnJlYWstYWxsOw0KICAgICAgICAgICAgdXNlci1zZWxlY3Q6IHRl
eHQ7DQogICAgICAgIH0NCiAgICAgICAgLnB0LXBhdGgubGl2ZSB7DQogICAgICAgICAgICBjb2xv
cjogdmFyKC0tYWNjKTsgY3Vyc29yOiBwb2ludGVyOw0KICAgICAgICB9DQogICAgICAgIC5wdC1w
YXRoLmxpdmU6aG92ZXIgeyB0ZXh0LWRlY29yYXRpb246IHVuZGVybGluZTsgfQ0KICAgICAgICAu
cHQtcGF0aC5kZWFkIHsNCiAgICAgICAgICAgIGNvbG9yOiAjYzQzZDVjOw0KICAgICAgICAgICAg
dGV4dC1kZWNvcmF0aW9uOiBsaW5lLXRocm91Z2g7DQogICAgICAgICAgICB0ZXh0LWRlY29yYXRp
b24tdGhpY2tuZXNzOiAycHg7DQogICAgICAgICAgICB0ZXh0LWRlY29yYXRpb24tY29sb3I6ICNl
MTFkNDg7DQogICAgICAgICAgICBjdXJzb3I6IGRlZmF1bHQ7DQogICAgICAgIH0NCiAgICAgICAg
LnB0LWFjdGlvbnMgew0KICAgICAgICAgICAgbWFyZ2luLXRvcDogNnB4Ow0KICAgICAgICAgICAg
ZGlzcGxheTogZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsgZ2FwOiA2cHg7IGZsZXgtd3JhcDog
d3JhcDsNCiAgICAgICAgfQ0KICAgICAgICAucHQtY29weS1idG4gew0KICAgICAgICAgICAgaGVp
Z2h0OiAyMnB4OyBwYWRkaW5nOiAwIDhweDsgZGlzcGxheTogaW5saW5lLWZsZXg7IGFsaWduLWl0
ZW1zOiBjZW50ZXI7DQogICAgICAgICAgICBib3JkZXI6IDFweCBzb2xpZCByZ2JhKDEwNywxMTIs
MTI4LC4yMik7IGJvcmRlci1yYWRpdXM6IDZweDsgY3Vyc29yOiBwb2ludGVyOw0KICAgICAgICAg
ICAgYmFja2dyb3VuZDogcmdiYSgxMDcsMTEyLDEyOCwuMDYpOyBjb2xvcjogIzhhOTBhMDsgZm9u
dC1zaXplOiAxMXB4OyBmb250LXdlaWdodDogNjAwOw0KICAgICAgICAgICAgLXdlYmtpdC1hcHAt
cmVnaW9uOiBuby1kcmFnOyBhcHAtcmVnaW9uOiBuby1kcmFnOw0KICAgICAgICAgICAgdHJhbnNp
dGlvbjogYmFja2dyb3VuZCB2YXIoLS10ciksIGNvbG9yIHZhcigtLXRyKSwgYm9yZGVyLWNvbG9y
IHZhcigtLXRyKTsNCiAgICAgICAgfQ0KICAgICAgICAucHQtY29weS1idG46aG92ZXIgew0KICAg
ICAgICAgICAgYmFja2dyb3VuZDogcmdiYSgxMDcsMTEyLDEyOCwuMTIpOyBjb2xvcjogdmFyKC0t
dHh0Mik7DQogICAgICAgICAgICBib3JkZXItY29sb3I6IHJnYmEoMTA3LDExMiwxMjgsLjQpOw0K
ICAgICAgICB9DQogICAgICAgIC5wdC1jb3B5LWJ0bi5vayB7DQogICAgICAgICAgICBjb2xvcjog
IzFmN2E1NTsgYm9yZGVyLWNvbG9yOiByZ2JhKDQ2LCAxODAsIDEyMCwgLjM1KTsNCiAgICAgICAg
ICAgIGJhY2tncm91bmQ6IHJnYmEoNDYsIDE4MCwgMTIwLCAuMSk7DQogICAgICAgIH0NCiAgICAg
ICAgLml0bS5pdC1ncm91cCB7DQogICAgICAgICAgICBmbGV4LWRpcmVjdGlvbjogY29sdW1uOw0K
ICAgICAgICAgICAgYWxpZ24taXRlbXM6IHN0cmV0Y2g7DQogICAgICAgICAgICBnYXA6IDA7DQog
ICAgICAgICAgICBwYWRkaW5nOiA2cHggOHB4IDRweDsNCiAgICAgICAgICAgIGN1cnNvcjogZGVm
YXVsdDsNCiAgICAgICAgfQ0KICAgICAgICAuaXRtLml0LWdyb3VwOmhvdmVyIHsgYmFja2dyb3Vu
ZDogdmFyKC0tY2FyZCk7IH0NCiAgICAgICAgLm1nLWhlYWQgew0KICAgICAgICAgICAgZGlzcGxh
eTogZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsgZ2FwOiA2cHg7DQogICAgICAgICAgICBmb250
LXNpemU6IDExcHg7IGNvbG9yOiB2YXIoLS10eHQzKTsgZm9udC13ZWlnaHQ6IDYwMDsNCiAgICAg
ICAgICAgIHBhZGRpbmc6IDJweCAycHggNnB4OyB1c2VyLXNlbGVjdDogbm9uZTsNCiAgICAgICAg
fQ0KICAgICAgICAubWctaGVhZCAubWctdGFnIHsNCiAgICAgICAgICAgIGRpc3BsYXk6IGlubGlu
ZS1mbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOw0KICAgICAgICAgICAgaGVpZ2h0OiAxNnB4OyBw
YWRkaW5nOiAwIDZweDsgYm9yZGVyLXJhZGl1czogOHB4Ow0KICAgICAgICAgICAgYmFja2dyb3Vu
ZDogcmdiYSg5MSwxMTUsMjMyLC4xMik7IGNvbG9yOiB2YXIoLS1hY2MpOyBmb250LXNpemU6IDEw
cHg7DQogICAgICAgIH0NCiAgICAgICAgLm1nLXJvdyB7DQogICAgICAgICAgICBwYWRkaW5nOiA3
cHggNnB4OyBtYXJnaW4tYm90dG9tOiAzcHg7DQogICAgICAgICAgICBib3JkZXItcmFkaXVzOiA1
cHg7IGN1cnNvcjogcG9pbnRlcjsNCiAgICAgICAgICAgIGJvcmRlcjogMXB4IHNvbGlkIHRyYW5z
cGFyZW50Ow0KICAgICAgICAgICAgdHJhbnNpdGlvbjogYmFja2dyb3VuZCAuMTJzIGVhc2UsIGJv
cmRlci1jb2xvciAuMTJzIGVhc2U7DQogICAgICAgIH0NCiAgICAgICAgLm1nLXJvdzpob3ZlciB7
IGJhY2tncm91bmQ6IHZhcigtLWNhcmQtaCk7IH0NCiAgICAgICAgLm1nLXJvdy5zZWwgew0KICAg
ICAgICAgICAgYmFja2dyb3VuZDogI2VkZjFmZjsNCiAgICAgICAgICAgIGJvcmRlci1jb2xvcjog
cmdiYSg5MSwxMTUsMjMyLC4zNSk7DQogICAgICAgICAgICBib3gtc2hhZG93OiAwIDAgMCAxcHgg
cmdiYSg5MSwxMTUsMjMyLC4yNSk7DQogICAgICAgIH0NCiAgICAgICAgLm1nLXJvdy5tdWx0aSB7
DQogICAgICAgICAgICBiYWNrZ3JvdW5kOiAjZWVmMmZmOw0KICAgICAgICAgICAgYm9yZGVyLWNv
bG9yOiByZ2JhKDkxLDExNSwyMzIsLjQ1KTsNCiAgICAgICAgfQ0KICAgICAgICAubWctdGl0bGUg
ew0KICAgICAgICAgICAgZm9udC1zaXplOiAxM3B4OyBmb250LXdlaWdodDogNjAwOyBjb2xvcjog
dmFyKC0tYWNjKTsNCiAgICAgICAgICAgIG1hcmdpbi1ib3R0b206IDJweDsgbGluZS1oZWlnaHQ6
IDEuMzU7DQogICAgICAgICAgICBkaXNwbGF5OiAtd2Via2l0LWJveDsgLXdlYmtpdC1ib3gtb3Jp
ZW50OiB2ZXJ0aWNhbDsgLXdlYmtpdC1saW5lLWNsYW1wOiAyOw0KICAgICAgICAgICAgb3ZlcmZs
b3c6IGhpZGRlbjsgd29yZC1icmVhazogYnJlYWstd29yZDsNCiAgICAgICAgfQ0KICAgICAgICAu
bWctYm9keSB7DQogICAgICAgICAgICBmb250LXNpemU6IDEyLjVweDsgZm9udC13ZWlnaHQ6IDUw
MDsgY29sb3I6IHZhcigtLXR4dCk7DQogICAgICAgICAgICB3aGl0ZS1zcGFjZTogcHJlLXdyYXA7
IHdvcmQtYnJlYWs6IGJyZWFrLWFsbDsNCiAgICAgICAgICAgIGRpc3BsYXk6IC13ZWJraXQtYm94
OyAtd2Via2l0LWJveC1vcmllbnQ6IHZlcnRpY2FsOyAtd2Via2l0LWxpbmUtY2xhbXA6IDQ7DQog
ICAgICAgICAgICBvdmVyZmxvdzogaGlkZGVuOyBsaW5lLWhlaWdodDogMS40Ow0KICAgICAgICB9
DQogICAgICAgIC5tZy1ib2R5LmltZyB7IGNvbG9yOiB2YXIoLS10eHQyKTsgfQ0KICAgICAgICAu
bWctcm93LXRvcCB7DQogICAgICAgICAgICBkaXNwbGF5OiBmbGV4OyBhbGlnbi1pdGVtczogZmxl
eC1zdGFydDsgZ2FwOiA4cHg7DQogICAgICAgIH0NCiAgICAgICAgLm1nLXJvdy1tYWluIHsgZmxl
eDogMTsgbWluLXdpZHRoOiAwOyB9DQogICAgICAgIC5tZy1zcmMgew0KICAgICAgICAgICAgd2lk
dGg6IDE4cHg7IGhlaWdodDogMThweDsgZmxleC1zaHJpbms6IDA7IG1hcmdpbi10b3A6IDJweDsN
CiAgICAgICAgICAgIGJvcmRlci1yYWRpdXM6IDNweDsgb2JqZWN0LWZpdDogY29udGFpbjsNCiAg
ICAgICAgICAgIGJhY2tncm91bmQ6IHJnYmEoMCwwLDAsLjA0KTsNCiAgICAgICAgfQ0KICAgICAg
ICAuaS1mYXYtdGl0bGUgew0KICAgICAgICAgICAgZm9udC1zaXplOiAxM3B4OyBmb250LXdlaWdo
dDogNjAwOyBjb2xvcjogdmFyKC0tYWNjKTsNCiAgICAgICAgICAgIG1hcmdpbjogMCAwIDNweDsg
bGluZS1oZWlnaHQ6IDEuMzU7DQogICAgICAgICAgICBkaXNwbGF5OiAtd2Via2l0LWJveDsgLXdl
YmtpdC1ib3gtb3JpZW50OiB2ZXJ0aWNhbDsgLXdlYmtpdC1saW5lLWNsYW1wOiAyOw0KICAgICAg
ICAgICAgb3ZlcmZsb3c6IGhpZGRlbjsgd29yZC1icmVhazogYnJlYWstd29yZDsNCiAgICAgICAg
fQ0KICAgICAgICAvKiDmnIDov5HvvJrmoIfpopjkuI7ok53oibLot6/lvoTmrrXljLrliIbvvIg6
aGFzIOWFnOW6le+8jOmBv+WFjeaXp+e8k+WtmOa8jyBjbGFzc++8iSAqLw0KICAgICAgICAuaS1m
YXYtdGl0bGUucmYtdGl0bGUsDQogICAgICAgIC5pdG06aGFzKC5yZi1wYXRoKSA+IC5pLWJvZHkg
PiAuaS1mYXYtdGl0bGUsDQogICAgICAgIC5pdG06aGFzKC5yZi1wYXRoKSAuaS1mYXYtdGl0bGUg
ew0KICAgICAgICAgICAgY29sb3I6ICNiNDUzMDkgIWltcG9ydGFudDsNCiAgICAgICAgICAgIGZv
bnQtd2VpZ2h0OiA3MDAgIWltcG9ydGFudDsNCiAgICAgICAgfQ0KICAgICAgICAjdGl0bGUtZGxn
IHsNCiAgICAgICAgICAgIGRpc3BsYXk6IG5vbmU7IHBvc2l0aW9uOiBmaXhlZDsgaW5zZXQ6IDA7
IHotaW5kZXg6IDEwMDsNCiAgICAgICAgICAgIGJhY2tncm91bmQ6IHJnYmEoMTUsMTgsMjgsLjM1
KTsNCiAgICAgICAgICAgIGFsaWduLWl0ZW1zOiBjZW50ZXI7IGp1c3RpZnktY29udGVudDogY2Vu
dGVyOw0KICAgICAgICAgICAgLXdlYmtpdC1hcHAtcmVnaW9uOiBuby1kcmFnOyBhcHAtcmVnaW9u
OiBuby1kcmFnOw0KICAgICAgICB9DQogICAgICAgICN0aXRsZS1kbGcub24geyBkaXNwbGF5OiBm
bGV4OyB9DQogICAgICAgICN0aXRsZS1kbGcgLnRpdGxlLWJveCB7DQogICAgICAgICAgICB3aWR0
aDogMjYwcHg7IHBhZGRpbmc6IDE2cHggMTZweCAxMnB4Ow0KICAgICAgICAgICAgYmFja2dyb3Vu
ZDogdmFyKC0tY2FyZCk7IGJvcmRlci1yYWRpdXM6IDEwcHg7DQogICAgICAgICAgICBib3gtc2hh
ZG93OiAwIDhweCAyOHB4IHJnYmEoMCwwLDAsLjE4KTsNCiAgICAgICAgICAgIC13ZWJraXQtYXBw
LXJlZ2lvbjogbm8tZHJhZzsgYXBwLXJlZ2lvbjogbm8tZHJhZzsNCiAgICAgICAgfQ0KICAgICAg
ICAjdGl0bGUtaW5wdXQgew0KICAgICAgICAgICAgd2lkdGg6IDEwMCU7IGJveC1zaXppbmc6IGJv
cmRlci1ib3g7IG1hcmdpbjogOHB4IDAgMTJweDsNCiAgICAgICAgICAgIGhlaWdodDogMzJweDsg
cGFkZGluZzogMCAxMHB4OyBib3JkZXItcmFkaXVzOiA2cHg7DQogICAgICAgICAgICBib3JkZXI6
IDFweCBzb2xpZCAjZDVkYWU2OyBiYWNrZ3JvdW5kOiAjZmZmOyBjb2xvcjogdmFyKC0tdHh0KTsN
CiAgICAgICAgICAgIGZvbnQtc2l6ZTogMTNweDsgb3V0bGluZTogbm9uZTsNCiAgICAgICAgICAg
IC13ZWJraXQtYXBwLXJlZ2lvbjogbm8tZHJhZzsgYXBwLXJlZ2lvbjogbm8tZHJhZzsNCiAgICAg
ICAgICAgIHVzZXItc2VsZWN0OiB0ZXh0Ow0KICAgICAgICB9DQogICAgICAgICN0aXRsZS1pbnB1
dDpmb2N1cyB7IGJvcmRlci1jb2xvcjogdmFyKC0tYWNjKTsgfQ0KDQogICAgDQogICAgICAgIC8q
IHVpLWdyYXktYmctdjEgKi8NCiAgICAgICAgOnJvb3Qgew0KICAgICAgICAgICAgLS1iZzogI2U0
ZTdlZSAhaW1wb3J0YW50Ow0KICAgICAgICB9DQogICAgICAgIGh0bWwsIGJvZHkgew0KICAgICAg
ICAgICAgYmFja2dyb3VuZDogI2U0ZTdlZSAhaW1wb3J0YW50Ow0KICAgICAgICB9DQogICAgICAg
ICNhcHAgew0KICAgICAgICAgICAgYmFja2dyb3VuZDogbGluZWFyLWdyYWRpZW50KDE4MGRlZywg
I2U5ZWNmMyAwJSwgI2UwZTRlYyAxMDAlKSAhaW1wb3J0YW50Ow0KICAgICAgICB9DQogICAgICAg
ICNoZHIgew0KICAgICAgICAgICAgYmFja2dyb3VuZDogI2UyZTZlZSAhaW1wb3J0YW50Ow0KICAg
ICAgICB9DQogICAgICAgICN0YWJzIHsNCiAgICAgICAgICAgIGJhY2tncm91bmQ6ICNlMmU2ZWUg
IWltcG9ydGFudDsNCiAgICAgICAgfQ0KICAgICAgICAjbGlzdCwgI2VtcHR5LCAjc2tlbCwgI2hk
ci1ncm93LCAjc2VhcmNoLXdyYXAgew0KICAgICAgICAgICAgYmFja2dyb3VuZDogdHJhbnNwYXJl
bnQgIWltcG9ydGFudDsNCiAgICAgICAgfQ0KICAgICAgICAjc2VhcmNoLWJveCB7DQogICAgICAg
ICAgICB0cmFuc2Zvcm0tb3JpZ2luOiByaWdodCBjZW50ZXI7DQogICAgICAgICAgICBiYWNrZ3Jv
dW5kOiB0cmFuc3BhcmVudCAhaW1wb3J0YW50Ow0KICAgICAgICB9DQogICAgICAgIC5pdG0sIC5t
ZywgLm1nLXJvdywgLm1lcmdlLWdyb3VwIHsNCiAgICAgICAgICAgIGJhY2tncm91bmQ6ICNmZmZm
ZmYgIWltcG9ydGFudDsNCiAgICAgICAgfQ0KICAgICAgICAuaXRtOmhvdmVyIHsNCiAgICAgICAg
ICAgIGJhY2tncm91bmQ6ICNmOGY5ZmMgIWltcG9ydGFudDsNCiAgICAgICAgfQ0KICAgIA0KICAg
ICAgICAvKiBzZWwtdGludC1ibHVlLXYxICovDQogICAgICAgIC5pdG0uc2VsLA0KICAgICAgICAu
bWctcm93LnNlbCwNCiAgICAgICAgLml0bS5tdWx0aSwNCiAgICAgICAgLm1nLXJvdy5tdWx0aSwN
CiAgICAgICAgLml0bS5tdWx0aS5zZWwsDQogICAgICAgIC5pdC1ncm91cC5zZWwsDQogICAgICAg
IC5pdC1ncm91cC5tdWx0aSB7DQogICAgICAgICAgICBiYWNrZ3JvdW5kOiAjZThlZmZmICFpbXBv
cnRhbnQ7DQogICAgICAgIH0NCiAgICAgICAgLml0bS5zZWw6aG92ZXIsDQogICAgICAgIC5pdG0u
bXVsdGk6aG92ZXIsDQogICAgICAgIC5tZy1yb3cuc2VsOmhvdmVyLA0KICAgICAgICAubWctcm93
Lm11bHRpOmhvdmVyIHsNCiAgICAgICAgICAgIGJhY2tncm91bmQ6ICNkZGU2ZmYgIWltcG9ydGFu
dDsNCiAgICAgICAgfQ0KICAgIA0KICAgICAgICAvKiBob3Zlci1ncmVlbi1yaXNlLXYyICovDQog
ICAgICAgIC8qIGhvdmVyLWFjY2VudC1yaXNlLXYzICovDQogICAgICAgIC5pdG06bm90KC5xLW1l
bWJlcikgeyBwb3NpdGlvbjogcmVsYXRpdmUgIWltcG9ydGFudDsgb3ZlcmZsb3c6IGhpZGRlbiAh
aW1wb3J0YW50OyB9DQogICAgICAgIC5pdG0ucS1tZW1iZXIgeyBwb3NpdGlvbjogcmVsYXRpdmUg
IWltcG9ydGFudDsgb3ZlcmZsb3c6IHZpc2libGUgIWltcG9ydGFudDsgfQ0KICAgICAgICAuaXRt
OjpiZWZvcmUgew0KICAgICAgICAgICAgY29udGVudDogIiIgIWltcG9ydGFudDsNCiAgICAgICAg
ICAgIHBvc2l0aW9uOiBhYnNvbHV0ZSAhaW1wb3J0YW50Ow0KICAgICAgICAgICAgbGVmdDogMCAh
aW1wb3J0YW50OyByaWdodDogMCAhaW1wb3J0YW50OyBib3R0b206IDAgIWltcG9ydGFudDsNCiAg
ICAgICAgICAgIGhlaWdodDogMCAhaW1wb3J0YW50Ow0KICAgICAgICAgICAgcG9pbnRlci1ldmVu
dHM6IG5vbmUgIWltcG9ydGFudDsNCiAgICAgICAgICAgIHotaW5kZXg6IDAgIWltcG9ydGFudDsN
CiAgICAgICAgICAgIGJvcmRlci1yYWRpdXM6IDAgMCB2YXIoLS1yLCA0cHgpIHZhcigtLXIsIDRw
eCkgIWltcG9ydGFudDsNCiAgICAgICAgICAgIGJhY2tncm91bmQ6IGxpbmVhci1ncmFkaWVudCh0
byB0b3AsDQogICAgICAgICAgICAgICAgcmdiYSg5MSwgMTE1LCAyMzIsIC4zMikgMCUsDQogICAg
ICAgICAgICAgICAgcmdiYSg5MSwgMTE1LCAyMzIsIC4xMikgNTUlLA0KICAgICAgICAgICAgICAg
IHJnYmEoOTEsIDExNSwgMjMyLCAwKSAxMDAlKSAhaW1wb3J0YW50Ow0KICAgICAgICAgICAgdHJh
bnNpdGlvbjogaGVpZ2h0IC4zNHMgY3ViaWMtYmV6aWVyKC4yMiwgMSwgLjM2LCAxKSAhaW1wb3J0
YW50Ow0KICAgICAgICB9DQogICAgICAgIC5pdG06aG92ZXI6OmJlZm9yZSB7IGhlaWdodDogMzMu
MzMzJSAhaW1wb3J0YW50OyB9DQogICAgICAgIC5pdG06OmFmdGVyIHsNCiAgICAgICAgICAgIGNv
bnRlbnQ6ICIiICFpbXBvcnRhbnQ7DQogICAgICAgICAgICBwb3NpdGlvbjogYWJzb2x1dGUgIWlt
cG9ydGFudDsNCiAgICAgICAgICAgIGxlZnQ6IDAgIWltcG9ydGFudDsgcmlnaHQ6IDAgIWltcG9y
dGFudDsgYm90dG9tOiAwICFpbXBvcnRhbnQ7DQogICAgICAgICAgICBoZWlnaHQ6IDJweCAhaW1w
b3J0YW50Ow0KICAgICAgICAgICAgcG9pbnRlci1ldmVudHM6IG5vbmUgIWltcG9ydGFudDsNCiAg
ICAgICAgICAgIHotaW5kZXg6IDEgIWltcG9ydGFudDsNCiAgICAgICAgICAgIGJhY2tncm91bmQ6
IHJnYmEoOTEsIDExNSwgMjMyLCAuOTIpICFpbXBvcnRhbnQ7DQogICAgICAgICAgICBib3JkZXIt
cmFkaXVzOiAxcHggIWltcG9ydGFudDsNCiAgICAgICAgICAgIHRyYW5zZm9ybTogc2NhbGVYKDAp
ICFpbXBvcnRhbnQ7DQogICAgICAgICAgICB0cmFuc2Zvcm0tb3JpZ2luOiBjZW50ZXIgIWltcG9y
dGFudDsNCiAgICAgICAgICAgIHRyYW5zaXRpb246IHRyYW5zZm9ybSAuM3MgY3ViaWMtYmV6aWVy
KC4yMiwgMSwgLjM2LCAxKSAhaW1wb3J0YW50Ow0KICAgICAgICB9DQogICAgICAgIC5pdG06aG92
ZXI6OmFmdGVyIHsNCiAgICAgICAgICAgIHRyYW5zZm9ybTogc2NhbGVYKDEpICFpbXBvcnRhbnQ7
DQogICAgICAgICAgICBiYWNrZ3JvdW5kOiByZ2JhKDkxLCAxMTUsIDIzMiwgLjk1KSAhaW1wb3J0
YW50Ow0KICAgICAgICB9DQogICAgICAgIC5pdG0gPiAqIHsgcG9zaXRpb246IHJlbGF0aXZlOyB6
LWluZGV4OiAyOyB9DQogICAgICAgIC5pdG0ucS1tZW1iZXIgPiAucS1yYWlsLA0KICAgICAgICAu
aXRtLnEtbWVtYmVyID4gLnEtZG90IHsNCiAgICAgICAgICAgIHBvc2l0aW9uOiBhYnNvbHV0ZSAh
aW1wb3J0YW50Ow0KICAgICAgICAgICAgei1pbmRleDogNiAhaW1wb3J0YW50Ow0KICAgICAgICB9
DQogICAgICAgIC8qIHJlY2VudCB0aXRsZS9wYXRoIOKAlCBsYXRlIG92ZXJyaWRlcyAqLw0KICAg
ICAgICAuaXRtOmhhcygucmYtcGF0aCkgLmktZmF2LXRpdGxlIHsNCiAgICAgICAgICAgIGNvbG9y
OiAjYjQ1MzA5ICFpbXBvcnRhbnQ7DQogICAgICAgICAgICBmb250LXdlaWdodDogNzAwICFpbXBv
cnRhbnQ7DQogICAgICAgIH0NCiAgICAgICAgLnJmLXBhdGggew0KICAgICAgICAgICAgZGlzcGxh
eTogYmxvY2sgIWltcG9ydGFudDsNCiAgICAgICAgICAgIHdpZHRoOiAxMDAlICFpbXBvcnRhbnQ7
DQogICAgICAgICAgICBtYXgtd2lkdGg6IDEwMCUgIWltcG9ydGFudDsNCiAgICAgICAgICAgIHdv
cmQtYnJlYWs6IGJyZWFrLWFsbCAhaW1wb3J0YW50Ow0KICAgICAgICAgICAgb3ZlcmZsb3ctd3Jh
cDogYW55d2hlcmUgIWltcG9ydGFudDsNCiAgICAgICAgfQ0KICAgICAgICAucmYtc2VnLCAucmYt
c2VwIHsgZGlzcGxheTogaW5saW5lICFpbXBvcnRhbnQ7IH0NCiAgICAgICAgLyog5aSW5qGG5pS5
55SxIFdpbjExIERXTSDmt6HngbDmj4/ovrnvvIjnm5bmu6HlnIbop5LvvInvvJvmraTlpITlj6ro
o4HliIflhoXlrrkgKi8NCiAgICAgICAgaHRtbCwgYm9keSB7DQogICAgICAgICAgICBib3JkZXI6
IG5vbmUgIWltcG9ydGFudDsNCiAgICAgICAgICAgIG91dGxpbmU6IG5vbmUgIWltcG9ydGFudDsN
CiAgICAgICAgICAgIGJveC1zaGFkb3c6IG5vbmUgIWltcG9ydGFudDsNCiAgICAgICAgICAgIGJv
cmRlci1yYWRpdXM6IDhweCAhaW1wb3J0YW50Ow0KICAgICAgICAgICAgb3ZlcmZsb3c6IGhpZGRl
biAhaW1wb3J0YW50Ow0KICAgICAgICB9DQogICAgICAgICNhcHAgew0KICAgICAgICAgICAgYm9y
ZGVyOiBub25lICFpbXBvcnRhbnQ7DQogICAgICAgICAgICBvdXRsaW5lOiBub25lICFpbXBvcnRh
bnQ7DQogICAgICAgICAgICBib3gtc2hhZG93OiBub25lICFpbXBvcnRhbnQ7DQogICAgICAgICAg
ICBib3JkZXItcmFkaXVzOiA4cHggIWltcG9ydGFudDsNCiAgICAgICAgICAgIGJveC1zaXppbmc6
IGJvcmRlci1ib3ggIWltcG9ydGFudDsNCiAgICAgICAgICAgIG92ZXJmbG93OiBoaWRkZW4gIWlt
cG9ydGFudDsNCiAgICAgICAgfQ0KICAgICAgICAuaXRtLCAubWcsIC5tZXJnZS1ncm91cCB7DQog
ICAgICAgICAgICBib3JkZXI6IG5vbmUgIWltcG9ydGFudDsNCiAgICAgICAgICAgIGJvcmRlci1y
YWRpdXM6IDRweCAhaW1wb3J0YW50Ow0KICAgICAgICAgICAgYm94LXNoYWRvdzoNCiAgICAgICAg
ICAgICAgICAwIDFweCAycHggcmdiYSgyNCwgMzIsIDU2LCAuMDUpLA0KICAgICAgICAgICAgICAg
IDAgM3B4IDEwcHggcmdiYSgyNCwgMzIsIDU2LCAuMDkpICFpbXBvcnRhbnQ7DQogICAgICAgIH0N
CiAgICAgICAgLml0bTpob3ZlciwgLm1nOmhvdmVyLCAubWVyZ2UtZ3JvdXA6aG92ZXIgew0KICAg
ICAgICAgICAgYm94LXNoYWRvdzoNCiAgICAgICAgICAgICAgICAwIDJweCA0cHggcmdiYSgyNCwg
MzIsIDU2LCAuMDcpLA0KICAgICAgICAgICAgICAgIDAgNnB4IDE2cHggcmdiYSgyNCwgMzIsIDU2
LCAuMTMpICFpbXBvcnRhbnQ7DQogICAgICAgIH0NCiAgICAgICAgLml0bS5zZWwsDQogICAgICAg
IC5tZy1yb3cuc2VsLA0KICAgICAgICAuaXRtLm11bHRpLA0KICAgICAgICAubWctcm93Lm11bHRp
LA0KICAgICAgICAuaXRtLm11bHRpLnNlbCwNCiAgICAgICAgLml0LWdyb3VwLnNlbCwNCiAgICAg
ICAgLml0LWdyb3VwLm11bHRpIHsNCiAgICAgICAgICAgIGJveC1zaGFkb3c6DQogICAgICAgICAg
ICAgICAgMCAwIDAgMnB4IHJnYmEoOTEsIDExNSwgMjMyLCAuNDIpLA0KICAgICAgICAgICAgICAg
IDAgMnB4IDRweCByZ2JhKDkxLCAxMTUsIDIzMiwgLjEwKSwNCiAgICAgICAgICAgICAgICAwIDZw
eCAxNHB4IHJnYmEoOTEsIDExNSwgMjMyLCAuMTYpICFpbXBvcnRhbnQ7DQogICAgICAgIH0NCg0K
ICAgIDwvc3R5bGU+DQo8L2hlYWQ+DQo8Ym9keSBkYXRhLXVpLWJ1aWxkPSIyMDI2MDkxNy1mMi10
aXRsZSI+DQo8ZGl2IGlkPSJhcHAiIGRhdGEtdWktdmVyPSIyMDI2MDkyMC1uby1lbW9qaSIgZGF0
YS10YWI9ImFsbCI+DQogICAgPGRpdiBpZD0iaGRyIj4NCiAgICAgICAgPGRpdiBpZD0iaGVhcnQi
Pg0KICAgICAgICAgICAgPHN2ZyB2aWV3Qm94PSIwIDAgMjQgMjQiIGZpbGw9Im5vbmUiIHN0cm9r
ZT0iY3VycmVudENvbG9yIiBzdHJva2Utd2lkdGg9IjEuOCINCiAgICAgICAgICAgICAgICAgc3Ry
b2tlLWxpbmVjYXA9InJvdW5kIiBzdHJva2UtbGluZWpvaW49InJvdW5kIj4NCiAgICAgICAgICAg
ICAgICA8cmVjdCB4PSI5IiB5PSIyIiB3aWR0aD0iNiIgaGVpZ2h0PSI0IiByeD0iMSIvPg0KICAg
ICAgICAgICAgICAgIDxwYXRoIGQ9Ik0xNiA0aDJhMiAyIDAgMCAxIDIgMnYxNGEyIDIgMCAwIDEt
MiAySDZhMiAyIDAgMCAxLTItMlY2YTIgMiAwIDAgMSAyLTJoMiIvPg0KICAgICAgICAgICAgICAg
IDxwYXRoIGQ9Ik05IDEyaDZNOSAxNmg0Ii8+DQogICAgICAgICAgICA8L3N2Zz4NCiAgICAgICAg
PC9kaXY+DQogICAgICAgIDxkaXYgaWQ9Imhkci1ncm93Ij48L2Rpdj4NCiAgICAgICAgPGRpdiBp
ZD0ibXVsdGktYmFyIj4NCiAgICAgICAgICAgIDxidXR0b24gaWQ9Im11bHRpLXNlbCIgdHlwZT0i
YnV0dG9uIiB0aXRsZT0i5Y+W5raI5aSa6YCJIj4NCiAgICAgICAgICAgICAgICA8c3BhbiBpZD0i
bXVsdGktc2VsLWxhYiI+5bey6YCJPC9zcGFuPg0KICAgICAgICAgICAgICAgIDxzcGFuIGlkPSJt
dWx0aS1jbnQiPjA8L3NwYW4+DQogICAgICAgICAgICA8L2J1dHRvbj4NCiAgICAgICAgICAgIDxk
aXYgaWQ9InBhc3RlLXNlcC13cmFwIj4NCiAgICAgICAgICAgICAgICA8YnV0dG9uIGlkPSJwYXN0
ZS1zZXAtYnRuIiB0eXBlPSJidXR0b24iIHRpdGxlPSLnspjotLTliIbpmpTnrKbvvIjngrnpgInn
lKjlubbnspjotLTvvIkiPg0KICAgICAgICAgICAgICAgICAgICA8c3BhbiBpZD0icGFzdGUtc2Vw
LWxhYmVsIj7ikKM8L3NwYW4+DQogICAgICAgICAgICAgICAgPC9idXR0b24+DQogICAgICAgICAg
ICAgICAgPGRpdiBpZD0icGFzdGUtc2VwLW1lbnUiPjwvZGl2Pg0KICAgICAgICAgICAgPC9kaXY+
DQogICAgICAgIDwvZGl2Pg0KICAgICAgICA8YnV0dG9uIGlkPSJidG4tbG9jYXRlIiB0eXBlPSJi
dXR0b24iIHRpdGxlPSLlrprkvY3liLDkuIrmrKHkvb/nlKjnmoTmnaHnm64iIGRpc2FibGVkPg0K
ICAgICAgICAgICAgPHN2ZyB2aWV3Qm94PSIwIDAgMjQgMjQiIGZpbGw9Im5vbmUiIHN0cm9rZT0i
Y3VycmVudENvbG9yIiBzdHJva2Utd2lkdGg9IjIiDQogICAgICAgICAgICAgICAgIHN0cm9rZS1s
aW5lY2FwPSJyb3VuZCIgc3Ryb2tlLWxpbmVqb2luPSJyb3VuZCI+DQogICAgICAgICAgICAgICAg
PGNpcmNsZSBjeD0iMTIiIGN5PSIxMiIgcj0iOCIvPg0KICAgICAgICAgICAgICAgIDxjaXJjbGUg
Y3g9IjEyIiBjeT0iMTIiIHI9IjMuNSIvPg0KICAgICAgICAgICAgPC9zdmc+DQogICAgICAgIDwv
YnV0dG9uPg0KICAgICAgICA8ZGl2IGlkPSJzZWFyY2gtd3JhcCI+DQogICAgICAgICAgICA8YnV0
dG9uIGlkPSJidG4tc2VhcmNoIiB0eXBlPSJidXR0b24iIHRpdGxlPSLmkJzntKIiPg0KICAgICAg
ICAgICAgICAgIDxzdmcgdmlld0JveD0iMCAwIDI0IDI0IiBmaWxsPSJub25lIiBzdHJva2U9ImN1
cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIyIg0KICAgICAgICAgICAgICAgICAgICAgc3Ryb2tl
LWxpbmVjYXA9InJvdW5kIiBzdHJva2UtbGluZWpvaW49InJvdW5kIj4NCiAgICAgICAgICAgICAg
ICAgICAgPGNpcmNsZSBjeD0iMTEiIGN5PSIxMSIgcj0iNyIvPg0KICAgICAgICAgICAgICAgICAg
ICA8cGF0aCBkPSJNMjAgMjBsLTMuNS0zLjUiLz4NCiAgICAgICAgICAgICAgICA8L3N2Zz4NCiAg
ICAgICAgICAgIDwvYnV0dG9uPg0KICAgICAgICAgICAgPGRpdiBpZD0ic2VhcmNoLWJveCI+DQog
ICAgICAgICAgICAgICAgPGJ1dHRvbiBpZD0iYnRuLXRvZGF5IiB0eXBlPSJidXR0b24iPuW9k+Wk
qTwvYnV0dG9uPg0KICAgICAgICAgICAgICAgIDxpbnB1dCBpZD0ic2VhcmNoIiB0eXBlPSJ0ZXh0
IiBwbGFjZWhvbGRlcj0i5pCc57Si4oCmIOepuuagvOWIhuivjemhu+WQjOaXtuWMheWQqyDCtyBh
fGIg5YiG5q61IiBhdXRvY29tcGxldGU9Im9mZiIgc3BlbGxjaGVjaz0iZmFsc2UiPg0KICAgICAg
ICAgICAgICAgIDxidXR0b24gaWQ9InNlYXJjaC1jbHIiIHR5cGU9ImJ1dHRvbiI+4pyVPC9idXR0
b24+DQogICAgICAgICAgICA8L2Rpdj4NCiAgICAgICAgPC9kaXY+DQogICAgICAgIDxidXR0b24g
aWQ9ImJ0bi1waW4iIHR5cGU9ImJ1dHRvbiIgdGl0bGU9IumSieWcqOWxj+W5leS4iiI+DQogICAg
ICAgICAgICA8c3ZnIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSJjdXJy
ZW50Q29sb3IiIHN0cm9rZS13aWR0aD0iMiINCiAgICAgICAgICAgICAgICAgc3Ryb2tlLWxpbmVq
b2luPSJyb3VuZCIgc3Ryb2tlLWxpbmVjYXA9InJvdW5kIj4NCiAgICAgICAgICAgICAgICA8bGlu
ZSB4MT0iMTIiIHkxPSIxNyIgeDI9IjEyIiB5Mj0iMjIiLz4NCiAgICAgICAgICAgICAgICA8cGF0
aCBkPSJNNSAxN2gxNHYtMS43NmEyIDIgMCAwIDAtMS4xMS0xLjc5bC0xLjc4LS45QTIgMiAwIDAg
MSAxNSAxMC43NlY2aDFhMiAyIDAgMCAwIDAtNEg4YTIgMiAwIDAgMCAwIDRoMXY0Ljc2YTIgMiAw
IDAgMS0xLjExIDEuNzlsLTEuNzguOUEyIDIgMCAwIDAgNSAxNS4yNFoiLz4NCiAgICAgICAgICAg
IDwvc3ZnPg0KICAgICAgICA8L2J1dHRvbj4NCiAgICA8L2Rpdj4NCg0KICAgIDxkaXYgaWQ9InRh
YnMiPg0KICAgICAgICA8ZGl2IGlkPSJ0YWItaW5rIiBhcmlhLWhpZGRlbj0idHJ1ZSI+PC9kaXY+
DQogICAgICAgIDxkaXYgY2xhc3M9InRhYiBvbiIgZGF0YS10YWI9ImFsbCI+5YWo6YOoPC9kaXY+
DQogICAgICAgIDxkaXYgY2xhc3M9InRhYiIgZGF0YS10YWI9InRleHQiPuaWh+acrDwvZGl2Pg0K
ICAgICAgICA8ZGl2IGNsYXNzPSJ0YWIiIGRhdGEtdGFiPSJpbWFnZSI+5Zu+5YOPPC9kaXY+DQog
ICAgICAgIDxkaXYgY2xhc3M9InRhYiIgZGF0YS10YWI9ImZpbGUiPuaWh+S7tjwvZGl2Pg0KICAg
ICAgICA8ZGl2IGNsYXNzPSJ0YWIiIGRhdGEtdGFiPSJyZWNlbnQiPuacgOi/kTwvZGl2Pg0KICAg
ICAgICA8ZGl2IGNsYXNzPSJ0YWIiIGRhdGEtdGFiPSJwaW5uZWQiPuaUtuiXjyA8c3BhbiBpZD0i
cGluLWRvdCIgdGl0bGU9IuacieaWsOaUtuiXjyI+PC9zcGFuPjwvZGl2Pg0KICAgICAgICA8ZGl2
IGlkPSJ0YWItYWN0aW9ucyI+DQogICAgICAgICAgICA8c3BhbiBpZD0iYmFyLXR4dCI+MDwvc3Bh
bj4NCiAgICAgICAgICAgIDxidXR0b24gaWQ9ImJ0bi1jbHIiIHR5cGU9ImJ1dHRvbiIgdGl0bGU9
Iua4heepuuWOhuWPsiI+DQogICAgICAgICAgICAgICAgPHN2ZyB2aWV3Qm94PSIwIDAgMjQgMjQi
IGZpbGw9Im5vbmUiIHN0cm9rZT0iY3VycmVudENvbG9yIiBzdHJva2Utd2lkdGg9IjIiDQogICAg
ICAgICAgICAgICAgICAgICBzdHJva2UtbGluZWNhcD0icm91bmQiIHN0cm9rZS1saW5lam9pbj0i
cm91bmQiPg0KICAgICAgICAgICAgICAgICAgICA8cG9seWxpbmUgcG9pbnRzPSIzIDYgNSA2IDIx
IDYiLz4NCiAgICAgICAgICAgICAgICAgICAgPHBhdGggZD0iTTE5IDZsLTEgMTRhMiAyIDAgMCAx
LTIgMkg4YTIgMiAwIDAgMS0yLTJMNSA2Ii8+DQogICAgICAgICAgICAgICAgICAgIDxwYXRoIGQ9
Ik0xMCAxMXY2TTE0IDExdjZNOSA2VjRoNnYyIi8+DQogICAgICAgICAgICAgICAgPC9zdmc+DQog
ICAgICAgICAgICA8L2J1dHRvbj4NCiAgICAgICAgPC9kaXY+DQogICAgPC9kaXY+DQoNCiAgICA8
ZGl2IGlkPSJsaXN0Ij4NCiAgICAgICAgPGRpdiBpZD0ic2tlbCIgYXJpYS1oaWRkZW49InRydWUi
Pg0KICAgICAgICAgICAgPGRpdiBjbGFzcz0ic2stcm93Ij48ZGl2IGNsYXNzPSJzay1pY28iPjwv
ZGl2PjxkaXYgY2xhc3M9InNrLWJvZHkiPjxkaXYgY2xhc3M9InNrLWxpbmUgbWlkIj48L2Rpdj48
ZGl2IGNsYXNzPSJzay1saW5lIHNob3J0Ij48L2Rpdj48L2Rpdj48L2Rpdj4NCiAgICAgICAgICAg
IDxkaXYgY2xhc3M9InNrLXJvdyI+PGRpdiBjbGFzcz0ic2staWNvIj48L2Rpdj48ZGl2IGNsYXNz
PSJzay1ib2R5Ij48ZGl2IGNsYXNzPSJzay1saW5lIj48L2Rpdj48ZGl2IGNsYXNzPSJzay1saW5l
IG1pZCI+PC9kaXY+PC9kaXY+PC9kaXY+DQogICAgICAgICAgICA8ZGl2IGNsYXNzPSJzay1yb3ci
PjxkaXYgY2xhc3M9InNrLWljbyI+PC9kaXY+PGRpdiBjbGFzcz0ic2stYm9keSI+PGRpdiBjbGFz
cz0ic2stbGluZSBtaWQiPjwvZGl2PjxkaXYgY2xhc3M9InNrLWxpbmUgc2hvcnQiPjwvZGl2Pjwv
ZGl2PjwvZGl2Pg0KICAgICAgICAgICAgPGRpdiBjbGFzcz0ic2stcm93Ij48ZGl2IGNsYXNzPSJz
ay1pY28iPjwvZGl2PjxkaXYgY2xhc3M9InNrLWJvZHkiPjxkaXYgY2xhc3M9InNrLWxpbmUiPjwv
ZGl2PjxkaXYgY2xhc3M9InNrLWxpbmUgbWlkIj48L2Rpdj48L2Rpdj48L2Rpdj4NCiAgICAgICAg
ICAgIDxkaXYgY2xhc3M9InNrLXJvdyI+PGRpdiBjbGFzcz0ic2staWNvIj48L2Rpdj48ZGl2IGNs
YXNzPSJzay1ib2R5Ij48ZGl2IGNsYXNzPSJzay1saW5lIG1pZCI+PC9kaXY+PGRpdiBjbGFzcz0i
c2stbGluZSBzaG9ydCI+PC9kaXY+PC9kaXY+PC9kaXY+DQogICAgICAgICAgICA8ZGl2IGNsYXNz
PSJzay1yb3ciPjxkaXYgY2xhc3M9InNrLWljbyI+PC9kaXY+PGRpdiBjbGFzcz0ic2stYm9keSI+
PGRpdiBjbGFzcz0ic2stbGluZSI+PC9kaXY+PGRpdiBjbGFzcz0ic2stbGluZSBzaG9ydCI+PC9k
aXY+PC9kaXY+PC9kaXY+DQogICAgICAgIDwvZGl2Pg0KICAgICAgICA8ZGl2IGlkPSJlbXB0eSI+
DQogICAgICAgICAgICA8ZGl2IGNsYXNzPSJlLXR4dCIgaWQ9ImVtcHR5LXR4dCI+5pqC5peg6K6w
5b2V77yM5aSN5Yi25ZCO6Ieq5Yqo5Ye6546wPC9kaXY+DQogICAgICAgIDwvZGl2Pg0KICAgIDwv
ZGl2Pg0KICAgIDxidXR0b24gaWQ9ImJ0bi10b3AiIHR5cGU9ImJ1dHRvbiIgdGl0bGU9IuWbnuWI
sOmhtumDqCIgYXJpYS1sYWJlbD0i5Zue5Yiw6aG26YOoIj4NCiAgICAgICAgPHN2ZyB2aWV3Qm94
PSIwIDAgMjQgMjQiIGZpbGw9Im5vbmUiIHN0cm9rZT0iY3VycmVudENvbG9yIiBzdHJva2Utd2lk
dGg9IjIuMiINCiAgICAgICAgICAgICBzdHJva2UtbGluZWNhcD0icm91bmQiIHN0cm9rZS1saW5l
am9pbj0icm91bmQiPg0KICAgICAgICAgICAgPHBhdGggZD0iTTEyIDE5VjUiLz4NCiAgICAgICAg
ICAgIDxwYXRoIGQ9Ik01IDEybDctNyA3IDciLz4NCiAgICAgICAgPC9zdmc+DQogICAgPC9idXR0
b24+DQo8L2Rpdj4NCg0KPGRpdiBpZD0iY3R4Ij4NCiAgICA8ZGl2IGNsYXNzPSJjLWl0ZW0iIGlk
PSJjLWNvcHkiPjxzcGFuIGNsYXNzPSJjLWljbyI+4o6YPC9zcGFuPuWkjeWItjwvZGl2Pg0KICAg
IDxkaXYgY2xhc3M9ImMtaXRlbSIgaWQ9ImMtcGFzdGUiPjxzcGFuIGNsYXNzPSJjLWljbyI+4o+O
PC9zcGFuPueymOi0tDwvZGl2Pg0KICAgIDxkaXYgY2xhc3M9ImMtc2VwIiBpZD0iYy1kYXRhLXNl
cCIgc3R5bGU9ImRpc3BsYXk6bm9uZSI+PC9kaXY+DQogICAgPGRpdiBjbGFzcz0iYy1zdWJ3cmFw
IiBpZD0iYy1kYXRhLXdyYXAiIHN0eWxlPSJkaXNwbGF5Om5vbmUiPg0KICAgICAgICA8ZGl2IGNs
YXNzPSJjLWl0ZW0iIGlkPSJjLWRhdGEiPjxzcGFuIGNsYXNzPSJjLWljbyI+zqM8L3NwYW4+5pWw
5o2u5aSE55CGPHNwYW4gY2xhc3M9ImMtY2FyZXQiPuKAujwvc3Bhbj48L2Rpdj4NCiAgICAgICAg
PGRpdiBjbGFzcz0iYy1zdWIiIGlkPSJjLWRhdGEtc3ViIj4NCiAgICAgICAgICAgIDxkaXYgY2xh
c3M9ImMtaXRlbSIgaWQ9ImMtZGF0YS1icmFjZSIgdGl0bGU9InthLGJ9IC8gYSxiIOKGkiBTUUwi
Pg0KICAgICAgICAgICAgICAgIDxzcGFuIGNsYXNzPSJjLW51bSI+MTwvc3Bhbj48c3BhbiBjbGFz
cz0iYy1mcm9tIj57YSxifTwvc3Bhbj48c3BhbiBjbGFzcz0iYy1hcnJvdyI+4oaSPC9zcGFuPjxz
cGFuIGNsYXNzPSJjLXRvIj4oJ2EnLCdiJyk8L3NwYW4+DQogICAgICAgICAgICA8L2Rpdj4NCiAg
ICAgICAgICAgIDxkaXYgY2xhc3M9ImMtaXRlbSIgaWQ9ImMtZGF0YS1saW5lcyIgdGl0bGU9IuaN
ouihjOWIhumalCDihpIgU1FMIj4NCiAgICAgICAgICAgICAgICA8c3BhbiBjbGFzcz0iYy1udW0i
PjI8L3NwYW4+PHNwYW4gY2xhc3M9ImMtZnJvbSI+YSBcbiBiPC9zcGFuPjxzcGFuIGNsYXNzPSJj
LWFycm93Ij7ihpI8L3NwYW4+PHNwYW4gY2xhc3M9ImMtdG8iPignYScsJ2InKTwvc3Bhbj4NCiAg
ICAgICAgICAgIDwvZGl2Pg0KICAgICAgICAgICAgPGRpdiBjbGFzcz0iYy1pdGVtIiBpZD0iYy1k
YXRhLWpzb24iIHRpdGxlPSJKU09OIOWOu+i9rOS5ie+8mlwmcXVvdDsg4oaSICZxdW90OyI+DQog
ICAgICAgICAgICAgICAgPHNwYW4gY2xhc3M9ImMtbnVtIj4zPC9zcGFuPjxzcGFuIGNsYXNzPSJj
LWZyb20iPmpzb24gICZxdW90O1wmcXVvdDs8L3NwYW4+PHNwYW4gY2xhc3M9ImMtYXJyb3ciPuKG
kjwvc3Bhbj48c3BhbiBjbGFzcz0iYy10byI+JnF1b3Q7ICZxdW90Ozwvc3Bhbj4NCiAgICAgICAg
ICAgIDwvZGl2Pg0KICAgICAgICA8L2Rpdj4NCiAgICA8L2Rpdj4NCiAgICA8ZGl2IGNsYXNzPSJj
LXNlcCI+PC9kaXY+DQogICAgPGRpdiBjbGFzcz0iYy1pdGVtIiBpZD0iYy1waW4iPjxzcGFuIGNs
YXNzPSJjLWljbyBzdGFyIj7irZA8L3NwYW4+5pS26JePPC9kaXY+DQogICAgPGRpdiBjbGFzcz0i
Yy1pdGVtIiBpZD0iYy10aXRsZSIgc3R5bGU9ImRpc3BsYXk6bm9uZSI+PHNwYW4gY2xhc3M9ImMt
aWNvIj7inI48L3NwYW4+6K6+572u5qCH6aKYPC9kaXY+DQogICAgPGRpdiBjbGFzcz0iYy1pdGVt
IiBpZD0iYy1tZXJnZSIgc3R5bGU9ImRpc3BsYXk6bm9uZSI+PHNwYW4gY2xhc3M9ImMtaWNvIj7i
p4k8L3NwYW4+5ZCI5bm2PC9kaXY+DQogICAgPGRpdiBjbGFzcz0iYy1pdGVtIiBpZD0iYy11bm1l
cmdlIiBzdHlsZT0iZGlzcGxheTpub25lIj48c3BhbiBjbGFzcz0iYy1pY28iPuKHhDwvc3Bhbj7l
j5bmtojlkIjlubY8L2Rpdj4NCiAgICA8ZGl2IGNsYXNzPSJjLWl0ZW0iIGlkPSJjLXRvcCI+PHNw
YW4gY2xhc3M9ImMtaWNvIj7ihpE8L3NwYW4+56e75Yiw6aG26YOoPC9kaXY+DQogICAgPGRpdiBj
bGFzcz0iYy1pdGVtIiBpZD0iYy1jbGVhci1wYXN0ZWQiIHN0eWxlPSJkaXNwbGF5Om5vbmUiPjxz
cGFuIGNsYXNzPSJjLWljbyI+4pyTPC9zcGFuPua4hemZpOeKtuaAgTwvZGl2Pg0KICAgIDxkaXYg
Y2xhc3M9ImMtaXRlbSIgaWQ9ImMtcXVldWUtZnJvbSIgc3R5bGU9ImRpc3BsYXk6bm9uZSI+PHNw
YW4gY2xhc3M9ImMtaWNvIj7ihrs8L3NwYW4+5LuO5q2k5aSE5byA5aeL6Zif5YiXPC9kaXY+DQog
ICAgPGRpdiBjbGFzcz0iYy1pdGVtIiBpZD0iYy1xdWV1ZS1pbiIgc3R5bGU9ImRpc3BsYXk6bm9u
ZSI+PHNwYW4gY2xhc3M9ImMtaWNvIj7ih4k8L3NwYW4+5Yqg5YWl57KY6LS06Zif5YiXPC9kaXY+
DQogICAgPGRpdiBjbGFzcz0iYy1pdGVtIiBpZD0iYy1xdWV1ZS1vdXQiIHN0eWxlPSJkaXNwbGF5
Om5vbmUiPjxzcGFuIGNsYXNzPSJjLWljbyI+4oeHPC9zcGFuPuenu+WHuueymOi0tOmYn+WIlzwv
ZGl2Pg0KICAgIDxkaXYgY2xhc3M9ImMtc2VwIj48L2Rpdj4NCiAgICA8ZGl2IGNsYXNzPSJjLWl0
ZW0gZGFuZ2VyIiBpZD0iYy1kZWwiPjxzcGFuIGNsYXNzPSJjLWljbyI+4pyVPC9zcGFuPuWIoOmZ
pDwvZGl2Pg0KPC9kaXY+DQoNCjxkaXYgaWQ9ImNsci1kbGciPg0KICAgIDxkaXYgY2xhc3M9ImNs
ci1ib3giIHJvbGU9ImRpYWxvZyIgYXJpYS1tb2RhbD0idHJ1ZSI+DQogICAgICAgIDxkaXYgY2xh
c3M9ImNsci10aXRsZSIgaWQ9ImNsci10aXRsZSI+56Gu6K6k5riF56m677yfPC9kaXY+DQogICAg
ICAgIDxkaXYgY2xhc3M9ImNsci1kZXNjIiBpZD0iY2xyLWRlc2MiPum7mOiupOS7hea4heepuuW9
k+WkqeWGheWuueOAgjwvZGl2Pg0KICAgICAgICA8bGFiZWwgY2xhc3M9ImNsci1jaGVjayIgZm9y
PSJjbHItYWxsIj4NCiAgICAgICAgICAgIDxpbnB1dCB0eXBlPSJjaGVja2JveCIgaWQ9ImNsci1h
bGwiPg0KICAgICAgICAgICAgPHNwYW4+5riF56m65omA5pyJPC9zcGFuPg0KICAgICAgICA8L2xh
YmVsPg0KICAgICAgICA8ZGl2IGNsYXNzPSJjbHItYnRucyI+DQogICAgICAgICAgICA8YnV0dG9u
IHR5cGU9ImJ1dHRvbiIgaWQ9ImNsci1jYW5jZWwiPuWPlua2iDwvYnV0dG9uPg0KICAgICAgICAg
ICAgPGJ1dHRvbiB0eXBlPSJidXR0b24iIGlkPSJjbHItb2siPua4heepujwvYnV0dG9uPg0KICAg
ICAgICA8L2Rpdj4NCiAgICA8L2Rpdj4NCjwvZGl2Pg0KDQo8ZGl2IGlkPSJ0aXRsZS1kbGciPg0K
ICAgIDxkaXYgY2xhc3M9InRpdGxlLWJveCIgcm9sZT0iZGlhbG9nIiBhcmlhLW1vZGFsPSJ0cnVl
Ij4NCiAgICAgICAgPGRpdiBjbGFzcz0iY2xyLXRpdGxlIj7orr7nva7moIfpopg8L2Rpdj4NCiAg
ICAgICAgPGRpdiBjbGFzcz0iY2xyLWRlc2MiPuagh+mimOWPr+iiq+aQnOe0ouaJvuWIsO+8m+ac
gOi/kei3r+W+hOS4juaUtuiXj+mDveWPr+eUqOOAgjwvZGl2Pg0KICAgICAgICA8aW5wdXQgaWQ9
InRpdGxlLWlucHV0IiB0eXBlPSJ0ZXh0IiBtYXhsZW5ndGg9IjgwIiBwbGFjZWhvbGRlcj0i57uZ
6L+Z5p2h5pS26JeP6LW35Liq5ZCN5a2X4oCmIiBhdXRvY29tcGxldGU9Im9mZiIgc3BlbGxjaGVj
az0iZmFsc2UiPg0KICAgICAgICA8ZGl2IGNsYXNzPSJjbHItYnRucyI+DQogICAgICAgICAgICA8
YnV0dG9uIHR5cGU9ImJ1dHRvbiIgaWQ9InRpdGxlLWNhbmNlbCI+5Y+W5raIPC9idXR0b24+DQog
ICAgICAgICAgICA8YnV0dG9uIHR5cGU9ImJ1dHRvbiIgaWQ9InRpdGxlLW9rIj7kv53lrZg8L2J1
dHRvbj4NCiAgICAgICAgPC9kaXY+DQogICAgPC9kaXY+DQo8L2Rpdj4NCjxkaXYgaWQ9InBhdGgt
dGlwIiBhcmlhLWhpZGRlbj0idHJ1ZSI+PC9kaXY+DQoNCjxzY3JpcHQ+DQovKiDnpoHmraIgQ3Ry
bCvmu5rova7nvKnmlL7vvIhXZWJWaWV3IOiuvue9riArIOmhtemdouWFnOW6le+8iSAqLw0KKGZ1
bmN0aW9uKCl7DQogIGNvbnN0IGJsb2NrWm9vbSA9IGUgPT4gew0KICAgIGlmIChlLmN0cmxLZXkg
fHwgZS5tZXRhS2V5KSB7DQogICAgICBlLnByZXZlbnREZWZhdWx0KCk7DQogICAgICBlLnN0b3BQ
cm9wYWdhdGlvbigpOw0KICAgIH0NCiAgfTsNCiAgd2luZG93LmFkZEV2ZW50TGlzdGVuZXIoJ3do
ZWVsJywgYmxvY2tab29tLCB7IHBhc3NpdmU6IGZhbHNlLCBjYXB0dXJlOiB0cnVlIH0pOw0KICB3
aW5kb3cuYWRkRXZlbnRMaXN0ZW5lcignZ2VzdHVyZXN0YXJ0JywgZSA9PiBlLnByZXZlbnREZWZh
dWx0KCksIHsgcGFzc2l2ZTogZmFsc2UsIGNhcHR1cmU6IHRydWUgfSk7DQogIGRvY3VtZW50LmFk
ZEV2ZW50TGlzdGVuZXIoJ2tleWRvd24nLCBlID0+IHsNCiAgICBpZiAoIShlLmN0cmxLZXkgfHwg
ZS5tZXRhS2V5KSkgcmV0dXJuOw0KICAgIGlmIChlLmtleSA9PT0gJysnIHx8IGUua2V5ID09PSAn
LScgfHwgZS5rZXkgPT09ICc9JyB8fCBlLmtleSA9PT0gJ18nDQogICAgICAgIHx8IGUuY29kZSA9
PT0gJ051bXBhZEFkZCcgfHwgZS5jb2RlID09PSAnTnVtcGFkU3VidHJhY3QnDQogICAgICAgIHx8
IGUua2V5ID09PSAnMCcpIHsNCiAgICAgIC8vIGFsbG93IG5vdGhpbmcgZm9yIHpvb207IEN0cmwr
MCAvIMKxDQogICAgICBpZiAoZS5rZXkgPT09ICcwJyB8fCBlLmtleSA9PT0gJysnIHx8IGUua2V5
ID09PSAnLScgfHwgZS5rZXkgPT09ICc9JyB8fCBlLmtleSA9PT0gJ18nDQogICAgICAgICAgfHwg
ZS5jb2RlID09PSAnTnVtcGFkQWRkJyB8fCBlLmNvZGUgPT09ICdOdW1wYWRTdWJ0cmFjdCcpIHsN
CiAgICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOw0KICAgICAgfQ0KICAgIH0NCiAgfSwgdHJ1ZSk7
DQp9KSgpOw0KPC9zY3JpcHQ+DQo8c2NyaXB0Pg0KLyogc2tlbC1mYWlsc2FmZTogb25seSBpZiBt
YWluIFVJIHNjcmlwdCBuZXZlciBib290ZWQg4oCUbmV2ZXIgaW52ZW50IGVtcHR5LXN0YXRlICov
DQooZnVuY3Rpb24oKXsNCiAgc2V0VGltZW91dCgoKSA9PiB7DQogICAgdHJ5IHsNCiAgICAgIGlm
ICh3aW5kb3cuX191aUJvb3RlZCkgcmV0dXJuOw0KICAgICAgdmFyIGFwcCA9IGRvY3VtZW50Lmdl
dEVsZW1lbnRCeUlkKCdhcHAnKTsNCiAgICAgIGlmIChhcHApIGFwcC5jbGFzc0xpc3QucmVtb3Zl
KCdib290LWxvYWRpbmcnKTsNCiAgICAgIHZhciBzID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQo
J3NrZWwnKTsNCiAgICAgIGlmIChzKSBzLmNsYXNzTGlzdC5yZW1vdmUoJ29uJyk7DQogICAgfSBj
YXRjaCAoZXJyKSB7fQ0KICB9LCAzMDAwKTsNCn0pKCk7DQo8L3NjcmlwdD4NCjxzY3JpcHQ+DQog
ICAgbGV0IGFsbENsaXBzID0gW10sIGN1clRhYiA9ICdhbGwnLCBxdWVyeSA9ICcnLCBjdHhDbGlw
ID0gbnVsbCwgc2VsZWN0ZWRJZCA9IDAsIHBpbm5lZFVJID0gZmFsc2U7DQogICAgY29uc3QgVEFC
X09SREVSID0gWydhbGwnLCAndGV4dCcsICdpbWFnZScsICdmaWxlJywgJ3JlY2VudCcsICdwaW5u
ZWQnXTsNCiAgICBjb25zdCB2aWV3TWVtID0gbmV3IE1hcCgpOw0KICAgIGZ1bmN0aW9uIHZpZXdN
ZW1LZXkodGFiLCBxLCB0b2RheSkgew0KICAgICAgICByZXR1cm4gU3RyaW5nKHRhYiB8fCAnYWxs
JykgKyAnXHQnICsgU3RyaW5nKHEgfHwgJycpICsgJ1x0JyArICh0b2RheSA/ICcxJyA6ICcwJyk7
DQogICAgfQ0KICAgIGxldCB0YWJTd2l0Y2hBbmltRGlyID0gMDsNCiAgICBsZXQgbXVsdGlJZHMg
PSBbXTsNCiAgICBsZXQgdG9kYXlPbmx5ID0gZmFsc2U7DQogICAgbGV0IGRpc2tUb3RhbCA9IDA7
DQogICAgbGV0IGxvYWRpbmdNb3JlID0gZmFsc2U7DQogICAgLy8gRG9uJ3Qgc2hvdyBza2VsZXRv
biBpbW1lZGlhdGVseSDigJRvbmx5IGFmdGVyIFNLRUxfREVMQVlfTVMgaWYgZGF0YSBzdGlsbCBt
aXNzaW5nDQogICAgbGV0IGJvb3RMb2FkaW5nID0gZmFsc2U7DQogICAgbGV0IHdhaXRpbmdEYXRh
ID0gZmFsc2U7DQogICAgbGV0IGhvc3RQdXNoZWRPbmNlID0gZmFsc2U7IC8vIG9ubHkgdGhlbiBt
YXkgc2hvd+OAjOaaguaXoOiusOW9leOAjQ0KICAgIGxldCBzYXdOb25FbXB0eSA9IGZhbHNlOyAg
ICAvLyBpZ25vcmUgYm9vdHN0cmFwIGVtcHR5IHB1c2hlcyBiZWZvcmUgZmlyc3QgcmVhbCBsaXN0
DQogICAgbGV0IHBpbm5lZFRvdGFsID0gMDsgICAgICAgIC8vIGF1dGhvcml0YXRpdmUg5pS26JeP
IGNvdW50IGZyb20gQUhLDQogICAgbGV0IHVuc2VlbkZhdklkcyA9IG5ldyBTZXQoKTsNCiAgICB0
cnkgew0KICAgICAgICBjb25zdCByYXcgPSBsb2NhbFN0b3JhZ2UuZ2V0SXRlbSgnY2xpcF91bnNl
ZW5fZmF2Jyk7DQogICAgICAgIGlmIChyYXcpIEpTT04ucGFyc2UocmF3KS5mb3JFYWNoKGlkID0+
IHsgaWQgPSAraWQ7IGlmIChpZCkgdW5zZWVuRmF2SWRzLmFkZChpZCk7IH0pOw0KICAgIH0gY2F0
Y2gge30NCiAgICBmdW5jdGlvbiBzYXZlVW5zZWVuRmF2KCkgew0KICAgICAgICB0cnkgeyBsb2Nh
bFN0b3JhZ2Uuc2V0SXRlbSgnY2xpcF91bnNlZW5fZmF2JywgSlNPTi5zdHJpbmdpZnkoWy4uLnVu
c2VlbkZhdklkc10pKTsgfSBjYXRjaCB7fQ0KICAgIH0NCiAgICBmdW5jdGlvbiB1cGRhdGVQaW5E
b3QoKSB7DQogICAgICAgIGNvbnN0IGVsID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3Bpbi1k
b3QnKTsNCiAgICAgICAgaWYgKCFlbCkgcmV0dXJuOw0KICAgICAgICBlbC5jbGFzc0xpc3QudG9n
Z2xlKCdvbicsIHVuc2VlbkZhdklkcy5zaXplID4gMCk7DQogICAgfQ0KICAgIGZ1bmN0aW9uIG1h
cmtGYXZVbnNlZW4oaWQpIHsNCiAgICAgICAgaWQgPSAraWQ7DQogICAgICAgIGlmICghaWQpIHJl
dHVybjsNCiAgICAgICAgdW5zZWVuRmF2SWRzLmFkZChpZCk7DQogICAgICAgIHNhdmVVbnNlZW5G
YXYoKTsNCiAgICAgICAgdXBkYXRlUGluRG90KCk7DQogICAgfQ0KICAgIGZ1bmN0aW9uIGNsZWFy
RmF2VW5zZWVuKCkgew0KICAgICAgICBpZiAoIXVuc2VlbkZhdklkcy5zaXplKSB7DQogICAgICAg
ICAgICB1cGRhdGVQaW5Eb3QoKTsNCiAgICAgICAgICAgIHJldHVybjsNCiAgICAgICAgfQ0KICAg
ICAgICB1bnNlZW5GYXZJZHMuY2xlYXIoKTsNCiAgICAgICAgc2F2ZVVuc2VlbkZhdigpOw0KICAg
ICAgICB1cGRhdGVQaW5Eb3QoKTsNCiAgICB9DQogICAgY29uc3QgU0tFTF9ERUxBWV9NUyA9IDYw
Ow0KICAgIHdpbmRvdy5fX2RhdGFSZWFkeSA9IGZhbHNlOw0KICAgIHdpbmRvdy5fX3VpQm9vdGVk
ID0gdHJ1ZTsNCiAgICAvLyBPcGVuIHBhbmVsIHdpdGhvdXQgcGFzdGluZyDihpIgYWx3YXlzIGxh
bmQgb24gZmlyc3QgaXRlbSAoYWZ0ZXIgZGF0YSBhcnJpdmVzKQ0KICAgIGxldCBzZWxlY3RGaXJz
dE9uU2hvdyA9IGZhbHNlOw0KICAgIGxldCBsYXN0UGFzdGVJZCA9IDA7DQogICAgbGV0IGxhc3RQ
YXN0ZVRhYiA9ICdhbGwnOw0KICAgIGxldCBsb2NhdGVBY3RpdmUgPSBmYWxzZTsNCiAgICB0cnkg
eyBsYXN0UGFzdGVJZCA9ICtsb2NhbFN0b3JhZ2UuZ2V0SXRlbSgnY2xpcExhc3RQYXN0ZUlkJykg
fHwgMDsgfSBjYXRjaCB7fQ0KICAgIHRyeSB7DQogICAgICAgIGNvbnN0IHQgPSBsb2NhbFN0b3Jh
Z2UuZ2V0SXRlbSgnY2xpcExhc3RQYXN0ZVRhYicpIHx8ICdhbGwnOw0KICAgICAgICBsYXN0UGFz
dGVUYWIgPSBbJ2FsbCcsJ3RleHQnLCdpbWFnZScsJ2ZpbGUnLCdwaW5uZWQnXS5pbmNsdWRlcyh0
KSA/IHQgOiAnYWxsJzsNCiAgICB9IGNhdGNoIHt9DQogICAgLy8gUHJlZmVyIHNhbWUtb3JpZ2lu
IHVuZGVyIGNsaXB1aS5hcHAgKEFQUF9IT1NUIOKGkiBDTElQX1YxX0RJUi9jbGlwc19zdG9yZSku
DQogICAgLy8g5Yu/55SoICoubG9jYWzvvJrns7vnu58gbUROUyDkvJrljaEgMuKAkzNz44CCY2xp
cHMuc3RvcmUg5LuF5L2cIGZhbGxiYWNr44CCDQogICAgY29uc3QgU1RPUkVfQkFTRSA9IChsb2Nh
dGlvbi5vcmlnaW4gJiYgbG9jYXRpb24ub3JpZ2luLmluZGV4T2YoJ2h0dHBzOi8vJykgPT09IDAp
DQogICAgICAgID8gKGxvY2F0aW9uLm9yaWdpbi5yZXBsYWNlKC9cLyQvLCAnJykgKyAnL2NsaXBz
X3N0b3JlLycpDQogICAgICAgIDogJ2h0dHBzOi8vY2xpcHVpLmFwcC9jbGlwc19zdG9yZS8nOw0K
ICAgIGNvbnN0IFNUT1JFX0JBU0VfRkFMTEJBQ0sgPSAnaHR0cHM6Ly9jbGlwcy5zdG9yZS8nOw0K
ICAgIGZ1bmN0aW9uIG1ldGFDZW50ZXJIdG1sKGV4cGFuZElubmVyKSB7DQogICAgICAgIGlmIChl
eHBhbmRJbm5lciA9PSBudWxsIHx8IGV4cGFuZElubmVyID09PSBmYWxzZSkNCiAgICAgICAgICAg
IHJldHVybiBgPHNwYW4gY2xhc3M9ImktbWV0YS1jZW50ZXIiPjwvc3Bhbj5gOw0KICAgICAgICBy
ZXR1cm4gYDxzcGFuIGNsYXNzPSJpLW1ldGEtY2VudGVyIj48YnV0dG9uIGNsYXNzPSJpLWV4cGFu
ZC1idG4ke2V4cGFuZElubmVyLm9uID8gJyBvbicgOiAnJ30iIHR5cGU9ImJ1dHRvbiIgdGl0bGU9
IuWxleW8gC/mlLbotbciPiR7ZXhwYW5kSW5uZXIuaHRtbH08L2J1dHRvbj48L3NwYW4+YDsNCiAg
ICB9DQoNCiAgICBmdW5jdGlvbiByZW1lbWJlckxhc3RQYXN0ZShpZCkgew0KICAgICAgICBsYXN0
UGFzdGVJZCA9ICtpZCB8fCAwOw0KICAgICAgICBsYXN0UGFzdGVUYWIgPSBjdXJUYWIgfHwgJ2Fs
bCc7DQogICAgICAgIHRyeSB7DQogICAgICAgICAgICBsb2NhbFN0b3JhZ2Uuc2V0SXRlbSgnY2xp
cExhc3RQYXN0ZUlkJywgU3RyaW5nKGxhc3RQYXN0ZUlkKSk7DQogICAgICAgICAgICBsb2NhbFN0
b3JhZ2Uuc2V0SXRlbSgnY2xpcExhc3RQYXN0ZVRhYicsIGxhc3RQYXN0ZVRhYik7DQogICAgICAg
IH0gY2F0Y2gge30NCiAgICAgICAgdXBkYXRlTG9jYXRlQnRuKCk7DQogICAgfQ0KICAgIGZ1bmN0
aW9uIHVwZGF0ZUxvY2F0ZUJ0bigpIHsNCiAgICAgICAgY29uc3QgYnRuID0gZG9jdW1lbnQuZ2V0
RWxlbWVudEJ5SWQoJ2J0bi1sb2NhdGUnKTsNCiAgICAgICAgaWYgKCFidG4pIHJldHVybjsNCiAg
ICAgICAgYnRuLmRpc2FibGVkID0gIWxhc3RQYXN0ZUlkOw0KICAgICAgICBidG4uY2xhc3NMaXN0
LnRvZ2dsZSgnaGFzLXRhcmdldCcsICEhbGFzdFBhc3RlSWQpOw0KICAgICAgICBidG4uY2xhc3NM
aXN0LnRvZ2dsZSgnb24nLCBsb2NhdGVBY3RpdmUgJiYgISFsYXN0UGFzdGVJZCk7DQogICAgICAg
IGJ0bi50aXRsZSA9ICFsYXN0UGFzdGVJZA0KICAgICAgICAgICAgPyAn5pqC5peg5LiK5qyh5L2/
55So5L2N572uJw0KICAgICAgICAgICAgOiAobG9jYXRlQWN0aXZlID8gJ+WPlua2iOWumuS9je+8
jOWbnuWIsOesrOS4gOadoScgOiAn5a6a5L2N5Yiw5LiK5qyh5L2/55So55qE5p2h55uuJyk7DQog
ICAgfQ0KICAgIGZ1bmN0aW9uIHNlbGVjdEZpcnN0SXRlbSgpIHsNCiAgICAgICAgbG9jYXRlQWN0
aXZlID0gZmFsc2U7DQogICAgICAgIHdpbmRvdy5fX3BlbmRpbmdKdW1wSWQgPSAwOw0KICAgICAg
ICB3aW5kb3cuX19qdW1wTG9hZFRyaWVzID0gMDsNCiAgICAgICAgc2VsZWN0Rmlyc3RPblNob3cg
PSBmYWxzZTsNCiAgICAgICAgY29uc3QgdmlzID0gdmlzaWJsZUxpc3QoKTsNCiAgICAgICAgaWYg
KCF2aXMubGVuZ3RoKSB7DQogICAgICAgICAgICBzZWxlY3RlZElkID0gMDsNCiAgICAgICAgICAg
IHN5bmNJdGVtSGlnaGxpZ2h0KCk7DQogICAgICAgICAgICB1cGRhdGVMb2NhdGVCdG4oKTsNCiAg
ICAgICAgICAgIHJldHVybjsNCiAgICAgICAgfQ0KICAgICAgICBzZWxlY3RlZElkID0gdmlzWzBd
LmlkOw0KICAgICAgICByYW5nZUFuY2hvcklkID0gc2VsZWN0ZWRJZDsNCiAgICAgICAgcmFuZ2VB
bmNob3JDbGlja2VkID0gZmFsc2U7DQogICAgICAgIGxpc3RFbC5zY3JvbGxUb3AgPSAwOw0KICAg
ICAgICBzeW5jSXRlbUhpZ2hsaWdodCgpOw0KICAgICAgICBjb25zdCBlbCA9IGxpc3RFbC5xdWVy
eVNlbGVjdG9yKCcuaXRtW2RhdGEtaWQ9IicgKyBzZWxlY3RlZElkICsgJyJdJyk7DQogICAgICAg
IGlmIChlbCkgZWwuc2Nyb2xsSW50b1ZpZXcoeyBibG9jazogJ25lYXJlc3QnIH0pOw0KICAgICAg
ICB1cGRhdGVMb2NhdGVCdG4oKTsNCiAgICB9DQogICAgZnVuY3Rpb24ganVtcFRvTGFzdFBhc3Rl
KCkgew0KICAgICAgICBpZiAoIWxhc3RQYXN0ZUlkKSByZXR1cm47DQogICAgICAgIC8vIEFscmVh
ZHkgbG9jYXRlZCBvbiBsYXN0IHBhc3RlIOKGkiBjYW5jZWwgYW5kIHNlbGVjdCBmaXJzdA0KICAg
ICAgICBpZiAobG9jYXRlQWN0aXZlICYmICtzZWxlY3RlZElkID09PSArbGFzdFBhc3RlSWQpIHsN
CiAgICAgICAgICAgIHNlbGVjdEZpcnN0SXRlbSgpOw0KICAgICAgICAgICAgcmV0dXJuOw0KICAg
ICAgICB9DQogICAgICAgIGxvY2F0ZUFjdGl2ZSA9IHRydWU7DQogICAgICAgIHNlbGVjdEZpcnN0
T25TaG93ID0gZmFsc2U7DQogICAgICAgIC8vIENsZWFyIGZpbHRlcnMgc28gdGhlIGl0ZW0gaXMg
ZmluZGFibGUgb24gdGhlIHRhYiB3aGVyZSBpdCB3YXMgdXNlZA0KICAgICAgICBxdWVyeSA9ICcn
Ow0KICAgICAgICB0b2RheU9ubHkgPSBmYWxzZTsNCiAgICAgICAgdHJ5IHsNCiAgICAgICAgICAg
IGNvbnN0IHNyY2ggPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc2VhcmNoJyk7DQogICAgICAg
ICAgICBjb25zdCBzY2xyID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NlYXJjaC1jbHInKTsN
CiAgICAgICAgICAgIGNvbnN0IHdyYXAgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc2VhcmNo
LXdyYXAnKTsNCiAgICAgICAgICAgIGNvbnN0IGJ0blRvZGF5ID0gZG9jdW1lbnQuZ2V0RWxlbWVu
dEJ5SWQoJ2J0bi10b2RheScpOw0KICAgICAgICAgICAgaWYgKHNyY2gpIHsgc3JjaC52YWx1ZSA9
ICcnOyBzcmNoLmNsYXNzTGlzdC5yZW1vdmUoJ2hhcy12YWwnKTsgfQ0KICAgICAgICAgICAgaWYg
KHNjbHIpIHNjbHIuc3R5bGUuZGlzcGxheSA9ICdub25lJzsNCiAgICAgICAgICAgIGlmICh3cmFw
KSB3cmFwLmNsYXNzTGlzdC5yZW1vdmUoJ29wZW4nKTsNCiAgICAgICAgICAgIGlmIChidG5Ub2Rh
eSkgYnRuVG9kYXkuY2xhc3NMaXN0LnJlbW92ZSgnb24nKTsNCiAgICAgICAgfSBjYXRjaCB7fQ0K
ICAgICAgICBjb25zdCB0YWIgPSBbJ2FsbCcsJ3RleHQnLCdpbWFnZScsJ2ZpbGUnLCdwaW5uZWQn
XS5pbmNsdWRlcyhsYXN0UGFzdGVUYWIpDQogICAgICAgICAgICA/IGxhc3RQYXN0ZVRhYiA6ICdh
bGwnOw0KICAgICAgICBjb25zdCBwcmV2VGFiID0gY3VyVGFiOw0KICAgICAgICBjdXJUYWIgPSB0
YWI7DQogICAgICAgIGxvYWRpbmdNb3JlID0gZmFsc2U7DQogICAgICAgIG1hcmtUYWIodGFiKTsN
CiAgICAgICAgY2xlYXJNdWx0aSgpOw0KICAgICAgICBzZWxlY3RlZElkID0gbGFzdFBhc3RlSWQ7
DQogICAgICAgIHdpbmRvdy5fX3BlbmRpbmdKdW1wSWQgPSBsYXN0UGFzdGVJZDsNCiAgICAgICAg
d2luZG93Ll9fanVtcExvYWRUcmllcyA9IDA7DQogICAgICAgIHdpbmRvdy5fX2p1bXBGZWxsQmFj
ayA9IGZhbHNlOw0KICAgICAgICB1cGRhdGVMb2NhdGVCdG4oKTsNCiAgICAgICAgcmVxdWVzdFZp
ZXcoKTsNCiAgICB9DQoNCiAgICBmdW5jdGlvbiByZXF1ZXN0VmlldygpIHsNCiAgICAgICAgY29u
c3QgdGFiID0gY3VyVGFiLCBxID0gcXVlcnksIHRvZGF5ID0gdG9kYXlPbmx5ID8gJzEnIDogJzAn
Ow0KICAgICAgICBpZiAod2luZG93Ll9fdmlld1JhZikgY2FuY2VsQW5pbWF0aW9uRnJhbWUod2lu
ZG93Ll9fdmlld1JhZik7DQogICAgICAgIHdpbmRvdy5fX3ZpZXdSYWYgPSByZXF1ZXN0QW5pbWF0
aW9uRnJhbWUoKCkgPT4gew0KICAgICAgICAgICAgd2luZG93Ll9fdmlld1JhZiA9IDA7DQogICAg
ICAgICAgICBzZXRUaW1lb3V0KCgpID0+IGFoaygnc2V0VmlldycsIHRhYiwgcSwgdG9kYXkpLCAw
KTsNCiAgICAgICAgfSk7DQogICAgfQ0KICAgIC8qKiBEZWJvdW5jZWQgQUhLIHN5bmMgYWZ0ZXIg
dmlld01lbSBpbnN0YW50IHBhaW50IOKAlGF2b2lkcyB0YWItc3dpdGNoIGRvdWJsZSBQdXNoQ2xp
cHMgKi8NCiAgICBmdW5jdGlvbiBzb2Z0UmVxdWVzdFZpZXcoKSB7DQogICAgICAgIGlmICh3aW5k
b3cuX19zb2Z0Vmlld1QpIGNsZWFyVGltZW91dCh3aW5kb3cuX19zb2Z0Vmlld1QpOw0KICAgICAg
ICB3aW5kb3cuX19zb2Z0Vmlld1QgPSBzZXRUaW1lb3V0KCgpID0+IHsNCiAgICAgICAgICAgIHdp
bmRvdy5fX3NvZnRWaWV3VCA9IDA7DQogICAgICAgICAgICByZXF1ZXN0VmlldygpOw0KICAgICAg
ICB9LCAzMjApOw0KICAgIH0NCiAgICBmdW5jdGlvbiByZXF1ZXN0TW9yZShmb3JjZSA9IGZhbHNl
KSB7DQogICAgICAgIGlmIChkaXNrVG90YWwgPiAwICYmIGFsbENsaXBzLmxlbmd0aCA+PSBkaXNr
VG90YWwpIHJldHVybjsNCiAgICAgICAgLy8gTG9jYXRlIC8ganVtcCBtdXN0IG5vdCB3YWl0IG9u
IHNjcm9sbC1pZGxlIG9yIGEgc3R1Y2sgbG9hZGluZ01vcmUgZmxhZw0KICAgICAgICBpZiAoIWZv
cmNlKSB7DQogICAgICAgICAgICBpZiAobG9hZGluZ01vcmUpIHJldHVybjsNCiAgICAgICAgICAg
IGlmICh3aW5kb3cuX19zY3JvbGxCdXN5IHx8IF9saXN0UHRyRG93bikgew0KICAgICAgICAgICAg
ICAgIHdpbmRvdy5fX3dhbnRNb3JlID0gdHJ1ZTsNCiAgICAgICAgICAgICAgICByZXR1cm47DQog
ICAgICAgICAgICB9DQogICAgICAgIH0gZWxzZSB7DQogICAgICAgICAgICBsb2FkaW5nTW9yZSA9
IGZhbHNlOw0KICAgICAgICAgICAgd2luZG93Ll9fc2Nyb2xsQnVzeSA9IGZhbHNlOw0KICAgICAg
ICAgICAgd2luZG93Ll9fd2FudE1vcmUgPSBmYWxzZTsNCiAgICAgICAgICAgIF9saXN0UHRyRG93
biA9IGZhbHNlOw0KICAgICAgICAgICAgdHJ5IHsgbGlzdEVsLmNsYXNzTGlzdC5yZW1vdmUoJ2lz
LXNjcm9sbGluZycpOyB9IGNhdGNoIHt9DQogICAgICAgIH0NCiAgICAgICAgaWYgKGxvYWRpbmdN
b3JlKSByZXR1cm47DQogICAgICAgIGxvYWRpbmdNb3JlID0gdHJ1ZTsNCiAgICAgICAgd2luZG93
Ll9fd2FudE1vcmUgPSBmYWxzZTsNCiAgICAgICAgaWYgKHdpbmRvdy5fX2xvYWRNb3JlV2F0Y2gp
IGNsZWFyVGltZW91dCh3aW5kb3cuX19sb2FkTW9yZVdhdGNoKTsNCiAgICAgICAgd2luZG93Ll9f
bG9hZE1vcmVXYXRjaCA9IHNldFRpbWVvdXQoKCkgPT4gew0KICAgICAgICAgICAgd2luZG93Ll9f
bG9hZE1vcmVXYXRjaCA9IDA7DQogICAgICAgICAgICBpZiAobG9hZGluZ01vcmUpIHsNCiAgICAg
ICAgICAgICAgICBsb2FkaW5nTW9yZSA9IGZhbHNlOw0KICAgICAgICAgICAgICAgIGlmICh3aW5k
b3cuX19wZW5kaW5nSnVtcElkKSB0cnlDb250aW51ZUp1bXAoKTsNCiAgICAgICAgICAgIH0NCiAg
ICAgICAgfSwgMTgwMCk7DQogICAgICAgIGFoaygnbG9hZE1vcmUnKTsNCiAgICB9DQoNCiAgICBm
dW5jdGlvbiB0cnlDb250aW51ZUp1bXAoKSB7DQogICAgICAgIGNvbnN0IGppZCA9ICt3aW5kb3cu
X19wZW5kaW5nSnVtcElkOw0KICAgICAgICBpZiAoIWppZCkgcmV0dXJuOw0KICAgICAgICBpZiAo
X3BlbmRpbmdBcHBlbmQpIHsNCiAgICAgICAgICAgIGNvbnN0IHBlbmRpbmcgPSBfcGVuZGluZ0Fw
cGVuZDsNCiAgICAgICAgICAgIF9wZW5kaW5nQXBwZW5kID0gbnVsbDsNCiAgICAgICAgICAgIGFw
cGx5QXBwZW5kUGF5bG9hZChwZW5kaW5nKTsNCiAgICAgICAgfQ0KICAgICAgICBjb25zdCBlbCA9
IGxpc3RFbC5xdWVyeVNlbGVjdG9yKCcubWctcm93W2RhdGEtaWQ9IicgKyBqaWQgKyAnIl0nKSB8
fCBsaXN0RWwucXVlcnlTZWxlY3RvcignLml0bVtkYXRhLWlkPSInICsgamlkICsgJyJdJyk7DQog
ICAgICAgIGlmIChlbCkgew0KICAgICAgICAgICAgd2luZG93Ll9fcGVuZGluZ0p1bXBJZCA9IDA7
DQogICAgICAgICAgICB3aW5kb3cuX19qdW1wTG9hZFRyaWVzID0gMDsNCiAgICAgICAgICAgIHNl
bGVjdGVkSWQgPSBqaWQ7DQogICAgICAgICAgICBsb2NhdGVBY3RpdmUgPSB0cnVlOw0KICAgICAg
ICAgICAgdXBkYXRlTG9jYXRlQnRuKCk7DQogICAgICAgICAgICByZXF1ZXN0QW5pbWF0aW9uRnJh
bWUoKCkgPT4gew0KICAgICAgICAgICAgICAgIGNvbnN0IG5vZGUgPSBsaXN0RWwucXVlcnlTZWxl
Y3RvcignLm1nLXJvd1tkYXRhLWlkPSInICsgamlkICsgJyJdJykgfHwgbGlzdEVsLnF1ZXJ5U2Vs
ZWN0b3IoJy5pdG1bZGF0YS1pZD0iJyArIGppZCArICciXScpOw0KICAgICAgICAgICAgICAgIGlm
ICghbm9kZSkgcmV0dXJuOw0KICAgICAgICAgICAgICAgIG5vZGUuc2Nyb2xsSW50b1ZpZXcoeyBi
bG9jazogJ2NlbnRlcicgfSk7DQogICAgICAgICAgICAgICAgbm9kZS5jbGFzc0xpc3QuYWRkKCdq
dW1wLWZsYXNoJyk7DQogICAgICAgICAgICAgICAgc2V0VGltZW91dCgoKSA9PiBub2RlLmNsYXNz
TGlzdC5yZW1vdmUoJ2p1bXAtZmxhc2gnKSwgOTAwKTsNCiAgICAgICAgICAgICAgICBzeW5jSXRl
bUhpZ2hsaWdodCgpOw0KICAgICAgICAgICAgfSk7DQogICAgICAgICAgICByZXR1cm47DQogICAg
ICAgIH0NCiAgICAgICAgaWYgKGFsbENsaXBzLnNvbWUoYyA9PiArYy5pZCA9PT0gamlkKSkgew0K
ICAgICAgICAgICAgcmVuZGVyKCk7DQogICAgICAgICAgICByZXF1ZXN0QW5pbWF0aW9uRnJhbWUo
KCkgPT4gdHJ5Q29udGludWVKdW1wKCkpOw0KICAgICAgICAgICAgcmV0dXJuOw0KICAgICAgICB9
DQogICAgICAgIGlmIChhbGxDbGlwcy5sZW5ndGggPCBkaXNrVG90YWwgJiYgKHdpbmRvdy5fX2p1
bXBMb2FkVHJpZXMgfHwgMCkgPCA4MCkgew0KICAgICAgICAgICAgd2luZG93Ll9fanVtcExvYWRU
cmllcyA9ICh3aW5kb3cuX19qdW1wTG9hZFRyaWVzIHx8IDApICsgMTsNCiAgICAgICAgICAgIHJl
cXVlc3RNb3JlKHRydWUpOw0KICAgICAgICAgICAgcmV0dXJuOw0KICAgICAgICB9DQogICAgICAg
IHdpbmRvdy5fX3BlbmRpbmdKdW1wSWQgPSAwOw0KICAgICAgICB3aW5kb3cuX19qdW1wTG9hZFRy
aWVzID0gMDsNCiAgICB9DQogICAgY29uc3QgRU1QVFlfTVNHID0gew0KICAgICAgICBhbGw6ICAg
ICfmmoLml6DorrDlvZXvvIzlpI3liLblkI7oh6rliqjlh7rnjrAnLA0KICAgICAgICB0ZXh0OiAg
ICfmmoLml6DmlofmnKwnLA0KICAgICAgICBpbWFnZTogICfmmoLml6Dlm77lg48nLA0KICAgICAg
ICBmaWxlOiAgICfmmoLml6Dmlofku7YnLA0KICAgICAgICBwaW5uZWQ6ICfmmoLml6DmlLbol48n
LA0KICAgICAgICByZWNlbnQ6ICfmmoLml6DmnIDov5HmiZPlvIDnmoTnm67lvZUnDQogICAgfTsN
Cg0KICAgIGZ1bmN0aW9uIGFoa0ludm9rZShtZXRob2QsIGFyZ3MpIHsNCiAgICAgICAgdHJ5IHsN
CiAgICAgICAgICAgIGNvbnN0IGhvc3QgPSBjaHJvbWUud2Vidmlldy5ob3N0T2JqZWN0cy5zeW5j
LmFoazsNCiAgICAgICAgICAgIGlmICghaG9zdCkgcmV0dXJuOw0KICAgICAgICAgICAgbGV0IGNh
bGxlZCA9IGZhbHNlOw0KICAgICAgICAgICAgLy8gV2ViVmlldzI6IGhvc3QuY2FsbChuYW1lLCDi
gKYpIGlzIHRoZSByZWxpYWJsZSBwYXRoLiBEaXJlY3QgaG9zdFttZXRob2RdKOKApikNCiAgICAg
ICAgICAgIC8vIGNhbiBtaXMtYmluZCBhcmdzIChzYXcgc2V0VmlldyB0YWIgYmVjb21lIDAg4oaS
IGZvcmV2ZXIgc2tlbGV0b24gLyB3cm9uZyB0YWIpLg0KICAgICAgICAgICAgaWYgKHR5cGVvZiBo
b3N0LmNhbGwgPT09ICdmdW5jdGlvbicpIHsNCiAgICAgICAgICAgICAgICB0cnkgeyBob3N0LmNh
bGwobWV0aG9kLCAuLi5hcmdzKTsgY2FsbGVkID0gdHJ1ZTsgfSBjYXRjaCB7fQ0KICAgICAgICAg
ICAgfQ0KICAgICAgICAgICAgaWYgKCFjYWxsZWQgJiYgdHlwZW9mIGhvc3RbbWV0aG9kXSA9PT0g
J2Z1bmN0aW9uJykgew0KICAgICAgICAgICAgICAgIHRyeSB7IGhvc3RbbWV0aG9kXSguLi5hcmdz
KTsgY2FsbGVkID0gdHJ1ZTsgfSBjYXRjaCAoZSkgeyBjb25zb2xlLndhcm4oJ2Foay4nICsgbWV0
aG9kLCBlKTsgfQ0KICAgICAgICAgICAgfQ0KICAgICAgICAgICAgaWYgKCFjYWxsZWQgJiYgaG9z
dFttZXRob2RdICE9IG51bGwgJiYgdHlwZW9mIGhvc3RbbWV0aG9kXSAhPT0gJ2Z1bmN0aW9uJykg
ew0KICAgICAgICAgICAgICAgIHRyeSB7IHZvaWQgaG9zdFttZXRob2RdOyB9IGNhdGNoIHt9DQog
ICAgICAgICAgICB9DQogICAgICAgIH0gY2F0Y2ggKGUpIHsgY29uc29sZS53YXJuKCdhaGsuJyAr
IG1ldGhvZCwgZSk7IH0NCiAgICB9DQogICAgZnVuY3Rpb24gYWhrKG1ldGhvZCwgLi4uYXJncykg
ew0KICAgICAgICBhaGtJbnZva2UobWV0aG9kLCBhcmdzKTsNCiAgICB9DQogICAgZnVuY3Rpb24g
YWhrUmV0KG1ldGhvZCwgLi4uYXJncykgew0KICAgICAgICB0cnkgew0KICAgICAgICAgICAgY29u
c3QgaG9zdCA9IGNocm9tZS53ZWJ2aWV3Lmhvc3RPYmplY3RzLnN5bmMuYWhrOw0KICAgICAgICAg
ICAgaWYgKCFob3N0KSByZXR1cm4gbnVsbDsNCiAgICAgICAgICAgIGxldCByZXQgPSBudWxsOw0K
ICAgICAgICAgICAgaWYgKHR5cGVvZiBob3N0LmNhbGwgPT09ICdmdW5jdGlvbicpIHsNCiAgICAg
ICAgICAgICAgICB0cnkgeyByZXQgPSBob3N0LmNhbGwobWV0aG9kLCAuLi5hcmdzKTsgfSBjYXRj
aCB7fQ0KICAgICAgICAgICAgfQ0KICAgICAgICAgICAgaWYgKHJldCA9PSBudWxsICYmIHR5cGVv
ZiBob3N0W21ldGhvZF0gPT09ICdmdW5jdGlvbicpIHsNCiAgICAgICAgICAgICAgICB0cnkgeyBy
ZXQgPSBob3N0W21ldGhvZF0oLi4uYXJncyk7IH0gY2F0Y2gge30NCiAgICAgICAgICAgICAgICBp
ZiAocmV0ID09IG51bGwpIHsNCiAgICAgICAgICAgICAgICAgICAgdHJ5IHsgcmV0ID0gaG9zdFtt
ZXRob2RdKC4uLmFyZ3MpOyB9IGNhdGNoIHt9DQogICAgICAgICAgICAgICAgfQ0KICAgICAgICAg
ICAgfQ0KICAgICAgICAgICAgaWYgKHJldCA9PSBudWxsICYmIGhvc3RbbWV0aG9kXSAhPSBudWxs
ICYmIHR5cGVvZiBob3N0W21ldGhvZF0gIT09ICdmdW5jdGlvbicpDQogICAgICAgICAgICAgICAg
cmV0ID0gaG9zdFttZXRob2RdOw0KICAgICAgICAgICAgaWYgKHJldCA9PSBudWxsKSByZXR1cm4g
bnVsbDsNCiAgICAgICAgICAgIGlmICh0eXBlb2YgcmV0ID09PSAnc3RyaW5nJyB8fCB0eXBlb2Yg
cmV0ID09PSAnbnVtYmVyJyB8fCB0eXBlb2YgcmV0ID09PSAnYm9vbGVhbicpDQogICAgICAgICAg
ICAgICAgcmV0dXJuIHJldDsNCiAgICAgICAgICAgIHRyeSB7IHJldHVybiBTdHJpbmcocmV0KTsg
fSBjYXRjaCB7IHJldHVybiByZXQ7IH0NCiAgICAgICAgfSBjYXRjaCAoZSkgeyBjb25zb2xlLndh
cm4oJ2Foa1JldC4nICsgbWV0aG9kLCBlKTsgfQ0KICAgICAgICByZXR1cm4gbnVsbDsNCiAgICB9
DQoNCiAgICAvLyBFYXJseSBBSEsgX19zZXRUaHVtYiBjYW4gYXJyaXZlIGJlZm9yZSBET00gbm9k
ZXMgZXhpc3Qg4oCUIGtlZXAgdW50aWwgYmluZA0KICAgIGNvbnN0IHRodW1iQ2FjaGUgPSBuZXcg
TWFwKCk7DQoNCiAgICAvKiogUHJlZmVyIGNhY2hlIC8gZGF0YS1VUkwsIHRoZW4gdGhfKi5qcGcg
dmlhIHZpcnR1YWwgaG9zdCwgdGhlbiBvcmlnaW5hbCAqLw0KICAgIGZ1bmN0aW9uIGJpbmRTdG9y
ZVRodW1iKGltZywgZmlsZSwgaWQsIGZhbGxiYWNrKSB7DQogICAgICAgIGltZy5kYXRhc2V0LnRo
dW1iSWQgPSBTdHJpbmcoaWQpOw0KICAgICAgICBpbWcuYWx0ID0gJyc7DQogICAgICAgIGltZy5j
bGFzc0xpc3QuYWRkKCd0aHVtYi1sb2FkaW5nJyk7DQogICAgICAgIGNvbnN0IHdyYXAgPSBpbWcu
cGFyZW50RWxlbWVudDsNCiAgICAgICAgaWYgKHdyYXAgJiYgd3JhcC5jbGFzc0xpc3QuY29udGFp
bnMoJ2ktdGh1bWItd3JhcCcpKQ0KICAgICAgICAgICAgd3JhcC5jbGFzc0xpc3QuYWRkKCd3YWl0
aW5nJyk7DQogICAgICAgIGNvbnN0IGNsZWFyV2FpdCA9ICgpID0+IHsNCiAgICAgICAgICAgIGlt
Zy5jbGFzc0xpc3QucmVtb3ZlKCd0aHVtYi1sb2FkaW5nJyk7DQogICAgICAgICAgICBpZiAod3Jh
cCkgd3JhcC5jbGFzc0xpc3QucmVtb3ZlKCd3YWl0aW5nJyk7DQogICAgICAgICAgICBpZiAoaW1n
Ll9mYWlsVGltZXIpIHRyeSB7IGNsZWFyVGltZW91dChpbWcuX2ZhaWxUaW1lcik7IH0gY2F0Y2gg
e30NCiAgICAgICAgfTsNCiAgICAgICAgY29uc3QgZmFpbFRpbWVyID0gc2V0VGltZW91dCgoKSA9
PiB7DQogICAgICAgICAgICBpZiAoIWltZy5zcmMgfHwgaW1nLm5hdHVyYWxXaWR0aCA8IDEpDQog
ICAgICAgICAgICAgICAgaW1nLmFsdCA9ICfml6Dms5XliqDovb0nOw0KICAgICAgICAgICAgY2xl
YXJXYWl0KCk7DQogICAgICAgIH0sIDEyMDAwKTsNCiAgICAgICAgaW1nLl9mYWlsVGltZXIgPSBm
YWlsVGltZXI7DQogICAgICAgIGNvbnN0IHByZXZMb2FkID0gaW1nLm9ubG9hZDsNCiAgICAgICAg
aW1nLm9ubG9hZCA9IGUgPT4gew0KICAgICAgICAgICAgY2xlYXJXYWl0KCk7DQogICAgICAgICAg
ICBpbWcuYWx0ID0gJyc7DQogICAgICAgICAgICBpZiAodHlwZW9mIHByZXZMb2FkID09PSAnZnVu
Y3Rpb24nKSBwcmV2TG9hZC5jYWxsKGltZywgZSk7DQogICAgICAgIH07DQogICAgICAgIGNvbnN0
IGJhcmUgPSBmaWxlID8gU3RyaW5nKGZpbGUpLnNwbGl0KC9bXFwvXS8pLnBvcCgpIDogJyc7DQog
ICAgICAgIGNvbnN0IHRoTmFtZSA9IGJhcmUgPyAoJ3RoXycgKyBiYXJlLnJlcGxhY2UoL1wuW14u
XSskLywgJycpICsgJy5qcGcnKSA6ICcnOw0KICAgICAgICBpbWcub25lcnJvciA9ICgpID0+IHsN
CiAgICAgICAgICAgIGNvbnN0IHN0ZXAgPSBOdW1iZXIoaW1nLmRhdGFzZXQuc3RlcCB8fCAwKTsN
CiAgICAgICAgICAgIGlmIChzdGVwIDwgMiAmJiBiYXJlKSB7DQogICAgICAgICAgICAgICAgaW1n
LmRhdGFzZXQuc3RlcCA9ICcyJzsNCiAgICAgICAgICAgICAgICBpbWcuc3JjID0gU1RPUkVfQkFT
RSArIGVuY29kZVVSSUNvbXBvbmVudChiYXJlKTsNCiAgICAgICAgICAgICAgICByZXR1cm47DQog
ICAgICAgICAgICB9DQogICAgICAgICAgICBpZiAoc3RlcCA8IDMgJiYgKHRoTmFtZSB8fCBiYXJl
KSkgew0KICAgICAgICAgICAgICAgIGltZy5kYXRhc2V0LnN0ZXAgPSAnMyc7DQogICAgICAgICAg
ICAgICAgaW1nLnNyYyA9IFNUT1JFX0JBU0VfRkFMTEJBQ0sgKyBlbmNvZGVVUklDb21wb25lbnQo
dGhOYW1lIHx8IGJhcmUpOw0KICAgICAgICAgICAgICAgIHJldHVybjsNCiAgICAgICAgICAgIH0N
CiAgICAgICAgICAgIGlmIChzdGVwIDwgNCAmJiBiYXJlICYmIHRoTmFtZSkgew0KICAgICAgICAg
ICAgICAgIGltZy5kYXRhc2V0LnN0ZXAgPSAnNCc7DQogICAgICAgICAgICAgICAgaW1nLnNyYyA9
IFNUT1JFX0JBU0VfRkFMTEJBQ0sgKyBlbmNvZGVVUklDb21wb25lbnQoYmFyZSk7DQogICAgICAg
ICAgICAgICAgcmV0dXJuOw0KICAgICAgICAgICAgfQ0KICAgICAgICAgICAgLy8gS2VlcCBzaGlt
bWVyOyBBSEsgX19zZXRUaHVtYiB3aWxsIGZpbGwgaW4NCiAgICAgICAgICAgIGltZy5yZW1vdmVB
dHRyaWJ1dGUoJ3NyYycpOw0KICAgICAgICAgICAgaW1nLmNsYXNzTGlzdC5hZGQoJ3RodW1iLWxv
YWRpbmcnKTsNCiAgICAgICAgICAgIGlmICh3cmFwKSB3cmFwLmNsYXNzTGlzdC5hZGQoJ3dhaXRp
bmcnKTsNCiAgICAgICAgfTsNCiAgICAgICAgY29uc3QgY2FjaGVkID0gdGh1bWJDYWNoZS5nZXQo
U3RyaW5nKGlkKSk7DQogICAgICAgIC8vIEFjY2VwdCBkYXRhLVVSTCBvciBob3N0IFVSTCBmcm9t
IHByaW9yIF9fc2V0VGh1bWIgKHJlLXJlbmRlciBtdXN0IG5vdCBkcm9wIGl0KQ0KICAgICAgICBp
ZiAoY2FjaGVkICYmIFN0cmluZyhjYWNoZWQpLmxlbmd0aCkgew0KICAgICAgICAgICAgaW1nLmRh
dGFzZXQuc3RlcCA9ICc5JzsNCiAgICAgICAgICAgIGltZy5zcmMgPSBTdHJpbmcoY2FjaGVkKTsN
CiAgICAgICAgICAgIHJldHVybjsNCiAgICAgICAgfQ0KICAgICAgICBjb25zdCBkYXRhVXJsID0g
KGZhbGxiYWNrICYmIFN0cmluZyhmYWxsYmFjaykuc3RhcnRzV2l0aCgnZGF0YTonKSkNCiAgICAg
ICAgICAgID8gU3RyaW5nKGZhbGxiYWNrKSA6ICcnOw0KICAgICAgICBpZiAoZGF0YVVybCkgew0K
ICAgICAgICAgICAgaW1nLmRhdGFzZXQuc3RlcCA9ICc5JzsNCiAgICAgICAgICAgIGltZy5zcmMg
PSBkYXRhVXJsOw0KICAgICAgICAgICAgcmV0dXJuOw0KICAgICAgICB9DQogICAgICAgIGlmIChi
YXJlKSB7DQogICAgICAgICAgICAvLyBQcmVmZXIgbGlzdCB0aHVtYiBKUEVHIChzbWFsbCkgb24g
ZGVkaWNhdGVkIHN0b3JlIGhvc3QNCiAgICAgICAgICAgIGltZy5kYXRhc2V0LnN0ZXAgPSAnMSc7
DQogICAgICAgICAgICBpbWcuc3JjID0gU1RPUkVfQkFTRSArIGVuY29kZVVSSUNvbXBvbmVudCh0
aE5hbWUgfHwgYmFyZSk7DQogICAgICAgIH0gZWxzZSB7DQogICAgICAgICAgICAvLyBObyBmaWxl
IHlldCAoanVzdCBjb3BpZWQpIOKAlGtlZXAgc2hpbW1lcjsgSW5qZWN0TGl2ZUltYWdlVGh1bWIg
LyBfX3NldFRodW1iIGZpbGxzIGluDQogICAgICAgICAgICBpbWcuY2xhc3NMaXN0LmFkZCgndGh1
bWItbG9hZGluZycpOw0KICAgICAgICAgICAgaWYgKHdyYXApIHdyYXAuY2xhc3NMaXN0LmFkZCgn
d2FpdGluZycpOw0KICAgICAgICB9DQogICAgfQ0KDQogICAgd2luZG93Ll9fc2V0VGh1bWIgPSAo
aWQsIHVybCkgPT4gew0KICAgICAgICBpZiAoIXVybCkgcmV0dXJuOw0KICAgICAgICBjb25zdCBr
ZXkgPSBTdHJpbmcoaWQpOw0KICAgICAgICB0aHVtYkNhY2hlLnNldChrZXksIHVybCk7DQogICAg
ICAgIGNvbnN0IGFwcGx5ID0gaW1nID0+IHsNCiAgICAgICAgICAgIGlmIChpbWcuX2ZhaWxUaW1l
cikgdHJ5IHsgY2xlYXJUaW1lb3V0KGltZy5fZmFpbFRpbWVyKTsgfSBjYXRjaCB7fQ0KICAgICAg
ICAgICAgaW1nLm9uZXJyb3IgPSBudWxsOw0KICAgICAgICAgICAgaW1nLmFsdCA9ICcnOw0KICAg
ICAgICAgICAgaW1nLmNsYXNzTGlzdC5yZW1vdmUoJ3RodW1iLWxvYWRpbmcnKTsNCiAgICAgICAg
ICAgIGNvbnN0IHdyYXAgPSBpbWcucGFyZW50RWxlbWVudDsNCiAgICAgICAgICAgIGlmICh3cmFw
KSB3cmFwLmNsYXNzTGlzdC5yZW1vdmUoJ3dhaXRpbmcnKTsNCiAgICAgICAgICAgIGltZy5zcmMg
PSB1cmw7DQogICAgICAgIH07DQogICAgICAgIGxldCBoaXQgPSAwOw0KICAgICAgICBkb2N1bWVu
dC5xdWVyeVNlbGVjdG9yQWxsKCcuaXRtW2RhdGEtaWQ9IicgKyBrZXkgKyAnIl0gaW1nLmktdGh1
bWInKS5mb3JFYWNoKGltZyA9PiB7DQogICAgICAgICAgICBhcHBseShpbWcpOyBoaXQrKzsNCiAg
ICAgICAgfSk7DQogICAgICAgIGlmICghaGl0KSB7DQogICAgICAgICAgICBkb2N1bWVudC5xdWVy
eVNlbGVjdG9yQWxsKCdpbWcuaS10aHVtYltkYXRhLXRodW1iLWlkPSInICsga2V5ICsgJyJdJyku
Zm9yRWFjaChhcHBseSk7DQogICAgICAgIH0NCiAgICB9Ow0KDQogICAgZnVuY3Rpb24gaXNEcmFn
RXhjbHVkZSh0KSB7DQogICAgICAgIHJldHVybiAhIXQuY2xvc2VzdCgnI3NlYXJjaC13cmFwLCAj
YnRuLXNlYXJjaCwgI2J0bi1sb2NhdGUsICNidG4tdG9kYXksICNidG4tcGluLCAjYnRuLWNsciwg
I211bHRpLWJhciwgI211bHRpLXNlbCwgI211bHRpLWNudCwgI3Bhc3RlLXNlcC13cmFwLCAudGFi
LCAuaXRtLCAjdGFiLWFjdGlvbnMsICNjdHgsICNjbHItZGxnLCAjdGl0bGUtZGxnLCAjcGF0aC10
aXAsIGJ1dHRvbiwgaW5wdXQsIGEsIHRleHRhcmVhJyk7DQogICAgfQ0KICAgIGRvY3VtZW50Lmdl
dEVsZW1lbnRCeUlkKCdhcHAnKS5hZGRFdmVudExpc3RlbmVyKCdtb3VzZWRvd24nLCBlID0+IHsN
CiAgICAgICAgaWYgKGUuYnV0dG9uICE9PSAwKSByZXR1cm47DQogICAgICAgIGlmIChpc0RyYWdF
eGNsdWRlKGUudGFyZ2V0KSkgcmV0dXJuOw0KICAgICAgICBlLnByZXZlbnREZWZhdWx0KCk7DQog
ICAgICAgIGFoaygnc3RhcnREcmFnJyk7DQogICAgfSwgdHJ1ZSk7DQoNCiAgICBjb25zdCBpc1Vy
bCAgPSBzID0+IC9eaHR0cHM/OlwvXC8vaS50ZXN0KChzIHx8ICcnKS50cmltKCkpOw0KDQogICAg
ZnVuY3Rpb24gYWdvKGRhdGVTdHIpIHsNCiAgICAgICAgdHJ5IHsNCiAgICAgICAgICAgIGNvbnN0
IGQgPSBuZXcgRGF0ZShTdHJpbmcoZGF0ZVN0cikucmVwbGFjZSgnICcsICdUJykpOw0KICAgICAg
ICAgICAgY29uc3QgcyA9IChEYXRlLm5vdygpIC0gZCkgLyAxMDAwIHwgMDsNCiAgICAgICAgICAg
IGlmIChzIDwgNjApIHJldHVybiAn5Yia5YiaJzsNCiAgICAgICAgICAgIGlmIChzIDwgMzYwMCkg
cmV0dXJuIChzIC8gNjAgfCAwKSArICcg5YiG6ZKf5YmNJzsNCiAgICAgICAgICAgIGlmIChzIDwg
ODY0MDApIHJldHVybiAocyAvIDM2MDAgfCAwKSArICcg5bCP5pe25YmNJzsNCiAgICAgICAgICAg
IHJldHVybiAocyAvIDg2NDAwIHwgMCkgKyAnIOWkqeWJjSc7DQogICAgICAgIH0gY2F0Y2ggeyBy
ZXR1cm4gZGF0ZVN0cjsgfQ0KICAgIH0NCg0KICAgIGZ1bmN0aW9uIG5vcm1UeXBlKHQpIHsNCiAg
ICAgICAgdCA9IFN0cmluZyh0IHx8ICcnKS50b0xvd2VyQ2FzZSgpOw0KICAgICAgICBpZiAodCA9
PT0gJ2ltYWdlJyB8fCB0ID09PSAnaW1nJyB8fCB0ID09PSAnYml0bWFwJykgcmV0dXJuICdpbWFn
ZSc7DQogICAgICAgIGlmICh0ID09PSAnZmlsZScgIHx8IHQgPT09ICdmaWxlcycpIHJldHVybiAn
ZmlsZSc7DQogICAgICAgIGlmICh0ID09PSAncmVjZW50JyB8fCB0ID09PSAnZm9sZGVyJyB8fCB0
ID09PSAnZGlyJykgcmV0dXJuICdyZWNlbnQnOw0KICAgICAgICBpZiAodCA9PT0gJ2xpbmsnIHx8
IHQgPT09ICd1cmwnKSByZXR1cm4gJ2xpbmsnOw0KICAgICAgICByZXR1cm4gJ3RleHQnOw0KICAg
IH0NCiAgICBmdW5jdGlvbiBpc1Bpbm5lZChjKSB7DQogICAgICAgIHJldHVybiBjLnBpbm5lZCA9
PT0gdHJ1ZSB8fCBjLnBpbm5lZCA9PT0gMSB8fCBjLnBpbm5lZCA9PT0gJ3RydWUnIHx8IGMucGlu
bmVkID09PSAnMSc7DQogICAgfQ0KICAgIC8qKiDlkIzmraXmiYDmnIkgdGFiIOe8k+WtmOmHjOea
hOaUtuiXj+agh+iusO+8jOmBv+WFjeaUtuiXj+mhteWPlua2iOWQjuWFtuWug+WIl+ihqOS7jeaY
vuekuuOAjOWPlua2iOaUtuiXj+OAjSAqLw0KICAgIGZ1bmN0aW9uIHBhdGNoUGlubmVkSW5DYWNo
ZXMoaWQsIHBpbm5lZCkgew0KICAgICAgICBpZCA9ICtpZDsNCiAgICAgICAgaWYgKCFpZCkgcmV0
dXJuOw0KICAgICAgICBjb25zdCBhcHBseSA9IChjKSA9PiB7DQogICAgICAgICAgICBpZiAoIWMg
fHwgK2MuaWQgIT09IGlkKSByZXR1cm47DQogICAgICAgICAgICBjLnBpbm5lZCA9ICEhcGlubmVk
Ow0KICAgICAgICAgICAgaWYgKCFwaW5uZWQpIGMucGluVGltZSA9ICcnOw0KICAgICAgICB9Ow0K
ICAgICAgICBmb3IgKGNvbnN0IHggb2YgYWxsQ2xpcHMpIGFwcGx5KHgpOw0KICAgICAgICB0cnkg
ew0KICAgICAgICAgICAgZm9yIChjb25zdCBba2V5LCBoaXRdIG9mIHZpZXdNZW0uZW50cmllcygp
KSB7DQogICAgICAgICAgICAgICAgaWYgKCFoaXQgfHwgIUFycmF5LmlzQXJyYXkoaGl0Lml0ZW1z
KSkgY29udGludWU7DQogICAgICAgICAgICAgICAgZm9yIChjb25zdCB4IG9mIGhpdC5pdGVtcykg
YXBwbHkoeCk7DQogICAgICAgICAgICAgICAgLy8g5pS26JePIHRhYiDnvJPlrZjvvJrlj5bmtojl
kI7nm7TmjqXnp7vlh7oNCiAgICAgICAgICAgICAgICBpZiAoIXBpbm5lZCAmJiBTdHJpbmcoa2V5
KS5zdGFydHNXaXRoKCdwaW5uZWRcdCcpKSB7DQogICAgICAgICAgICAgICAgICAgIGNvbnN0IGJl
Zm9yZSA9IGhpdC5pdGVtcy5sZW5ndGg7DQogICAgICAgICAgICAgICAgICAgIGhpdC5pdGVtcyA9
IGhpdC5pdGVtcy5maWx0ZXIoeCA9PiAreC5pZCAhPT0gaWQpOw0KICAgICAgICAgICAgICAgICAg
ICBpZiAoaGl0Lml0ZW1zLmxlbmd0aCAhPT0gYmVmb3JlKQ0KICAgICAgICAgICAgICAgICAgICAg
ICAgaGl0LnRvdGFsID0gTWF0aC5tYXgoMCwgKE51bWJlcihoaXQudG90YWwpIHx8IGJlZm9yZSkg
LSAoYmVmb3JlIC0gaGl0Lml0ZW1zLmxlbmd0aCkpOw0KICAgICAgICAgICAgICAgICAgICB2aWV3
TWVtLnNldChrZXksIGhpdCk7DQogICAgICAgICAgICAgICAgfQ0KICAgICAgICAgICAgfQ0KICAg
ICAgICB9IGNhdGNoIHt9DQogICAgfQ0KICAgIGZ1bmN0aW9uIGlzUGFzdGVkKGMpIHsNCiAgICAg
ICAgcmV0dXJuIGMucGFzdGVkID09PSB0cnVlIHx8IGMucGFzdGVkID09PSAxIHx8IGMucGFzdGVk
ID09PSAndHJ1ZScgfHwgYy5wYXN0ZWQgPT09ICcxJzsNCiAgICB9DQoNCiAgICBmdW5jdGlvbiBp
c01hcmtkb3duKHRleHQpIHsNCiAgICAgICAgaWYgKCF0ZXh0IHx8IHRleHQubGVuZ3RoIDwgNCkg
cmV0dXJuIGZhbHNlOw0KICAgICAgICByZXR1cm4gLyg/Ol58XG4pI3sxLDZ9IHxeWy0qK10gfFwq
XCpbXipcbl0rXCpcKnxfX1teX1xuXStfX3woPzpefFxuKT4gfGBgYHxgW15gXG5dK2B8XFtbXlxd
XStcXVwoW14pXStcKXxcfC4rXHwuK1x8L20udGVzdCh0ZXh0KTsNCiAgICB9DQogICAgZnVuY3Rp
b24gY2xpcFVzZXNNSWNvbihjKSB7DQogICAgICAgIGlmICghYykgcmV0dXJuIGZhbHNlOw0KICAg
ICAgICBpZiAoYy5pc01kID09PSB0cnVlIHx8IGMuaXNNZCA9PT0gMSB8fCBjLmlzTWQgPT09ICd0
cnVlJyB8fCBjLmlzTWQgPT09ICcxJykgcmV0dXJuIHRydWU7DQogICAgICAgIGlmIChjLmlzUmlj
aCA9PT0gdHJ1ZSB8fCBjLmlzUmljaCA9PT0gMSB8fCBjLmlzUmljaCA9PT0gJ3RydWUnIHx8IGMu
aXNSaWNoID09PSAnMScpIHJldHVybiB0cnVlOw0KICAgICAgICBjb25zdCB0ID0gU3RyaW5nKGMu
dHlwZSB8fCAnJykudG9Mb3dlckNhc2UoKTsNCiAgICAgICAgaWYgKHQgJiYgdCAhPT0gJ3RleHQn
ICYmIHQgIT09ICdsaW5rJykgcmV0dXJuIGZhbHNlOw0KICAgICAgICByZXR1cm4gaXNNYXJrZG93
bihjLmRhdGEgfHwgYy5wcmV2aWV3IHx8ICcnKTsNCiAgICB9DQogICAgZnVuY3Rpb24gZXNjQXR0
cihzKSB7DQogICAgICAgIHJldHVybiBTdHJpbmcocyB8fCAnJykNCiAgICAgICAgICAgIC5yZXBs
YWNlKC8mL2csICcmYW1wOycpDQogICAgICAgICAgICAucmVwbGFjZSgvIi9nLCAnJnF1b3Q7JykN
CiAgICAgICAgICAgIC5yZXBsYWNlKC88L2csICcmbHQ7JykNCiAgICAgICAgICAgIC5yZXBsYWNl
KC8+L2csICcmZ3Q7Jyk7DQogICAgfQ0KDQogICAgZnVuY3Rpb24gdG9kYXlQcmVmaXgoKSB7DQog
ICAgICAgIGNvbnN0IGQgPSBuZXcgRGF0ZSgpOw0KICAgICAgICBjb25zdCBwID0gbiA9PiBTdHJp
bmcobikucGFkU3RhcnQoMiwgJzAnKTsNCiAgICAgICAgcmV0dXJuIGQuZ2V0RnVsbFllYXIoKSAr
ICctJyArIHAoZC5nZXRNb250aCgpICsgMSkgKyAnLScgKyBwKGQuZ2V0RGF0ZSgpKTsNCiAgICB9
DQogICAgZnVuY3Rpb24gaXNUb2RheUNsaXAoYykgew0KICAgICAgICByZXR1cm4gU3RyaW5nKGMu
dGltZSB8fCAnJykuc3RhcnRzV2l0aCh0b2RheVByZWZpeCgpKTsNCiAgICB9DQoNCiAgICBmdW5j
dGlvbiBjbGlwSGF5KGMpIHsNCiAgICAgICAgcmV0dXJuIFN0cmluZyhjLnByZXZpZXcgfHwgJycp
ICsgJyAnICsgU3RyaW5nKGMuZGF0YSB8fCAnJykgKyAnICcNCiAgICAgICAgICAgICsgU3RyaW5n
KGMubGlua1RpdGxlIHx8ICcnKSArICcgJyArIFN0cmluZyhjLmZhdlRpdGxlIHx8ICcnKTsNCiAg
ICB9DQogICAgLyoqIE1hdGNoIEFISyBJdGVtTWF0Y2hlc1ZpZXcgbGlzdCBzZWFyY2gg4oCUIHBy
ZXZpZXcgKCsgc2hvcnQgYm9keSBmYWxsYmFjayksIG5vdCBmdWxsIGRhdGEgKi8NCiAgICBmdW5j
dGlvbiBjbGlwU2VhcmNoSGF5KGMpIHsNCiAgICAgICAgY29uc3QgdHlwZSA9IFN0cmluZyhjLnR5
cGUgfHwgJycpLnRvTG93ZXJDYXNlKCk7DQogICAgICAgIGlmICh0eXBlID09PSAnaW1hZ2UnKQ0K
ICAgICAgICAgICAgcmV0dXJuIFN0cmluZyhjLmZhdlRpdGxlIHx8ICcnKTsNCiAgICAgICAgaWYg
KHR5cGUgPT09ICdyZWNlbnQnKSB7DQogICAgICAgICAgICByZXR1cm4gU3RyaW5nKGMuZGF0YSB8
fCBjLnByZXZpZXcgfHwgJycpICsgJyAnICsgU3RyaW5nKGMuZmF2VGl0bGUgfHwgJycpOw0KICAg
ICAgICB9DQogICAgICAgIGlmICh0eXBlID09PSAnZmlsZScpIHsNCiAgICAgICAgICAgIHJldHVy
biBTdHJpbmcoYy5wcmV2aWV3IHx8ICcnKSArICcgJyArIFN0cmluZyhjLmRhdGEgfHwgJycpICsg
JyAnDQogICAgICAgICAgICAgICAgKyBTdHJpbmcoYy5mYXZUaXRsZSB8fCAnJyk7DQogICAgICAg
IH0NCiAgICAgICAgbGV0IHByZXYgPSBTdHJpbmcoYy5wcmV2aWV3IHx8ICcnKTsNCiAgICAgICAg
aWYgKCFwcmV2ICYmIGMuZGF0YSkNCiAgICAgICAgICAgIHByZXYgPSBTdHJpbmcoYy5kYXRhKS5z
bGljZSgwLCA1MDApOw0KICAgICAgICByZXR1cm4gcHJldiArICcgJyArIFN0cmluZyhjLmxpbmtU
aXRsZSB8fCAnJykgKyAnICcgKyBTdHJpbmcoYy5mYXZUaXRsZSB8fCAnJyk7DQogICAgfQ0KICAg
IGZ1bmN0aW9uIGNsaXBNYXRjaGVzU2VhcmNoKGMsIHRlcm1MKSB7DQogICAgICAgIGNvbnN0IHR5
cGUgPSBTdHJpbmcoYy50eXBlIHx8ICcnKS50b0xvd2VyQ2FzZSgpOw0KICAgICAgICBjb25zdCBo
YXkgPSAodHlwZSA9PT0gJ2ltYWdlJyA/IFN0cmluZyhjLmZhdlRpdGxlIHx8ICcnKSA6IGNsaXBT
ZWFyY2hIYXkoYykpLnRvTG93ZXJDYXNlKCk7DQogICAgICAgIHJldHVybiB0ZXJtTC5ldmVyeSh0
ID0+IGhheS5pbmNsdWRlcyh0KSk7DQogICAgfQ0KICAgIGZ1bmN0aW9uIGZpbHRlcihjbGlwcywg
dGFiLCBxKSB7DQogICAgICAgIC8vIOS4u+acuuW3sui/h+a7pOaXtuS7jeWBmuWJjeerr+WFnOW6
le+8mumBv+WFjeernuaAgeaOqOadpeacquWRveS4reihjA0KICAgICAgICBjb25zdCB0ZXJtcyA9
IHF1ZXJ5VGVybXMocSk7DQogICAgICAgIGlmICghdGVybXMubGVuZ3RoKSByZXR1cm4gY2xpcHM7
DQogICAgICAgIGNvbnN0IHRlcm1MID0gdGVybXMubWFwKHQgPT4gdC50b0xvd2VyQ2FzZSgpKTsN
CiAgICAgICAgY29uc3QgbWF0Y2hlZEdyb3VwcyA9IG5ldyBTZXQoKTsNCiAgICAgICAgZm9yIChj
b25zdCBjIG9mIGNsaXBzKSB7DQogICAgICAgICAgICBpZiAoIWNsaXBNYXRjaGVzU2VhcmNoKGMs
IHRlcm1MKSkgY29udGludWU7DQogICAgICAgICAgICBjb25zdCBnaWQgPSBTdHJpbmcoYyAmJiBj
LmZhdkdyb3VwIHx8ICcnKS50cmltKCk7DQogICAgICAgICAgICBpZiAoZ2lkKSBtYXRjaGVkR3Jv
dXBzLmFkZChnaWQpOw0KICAgICAgICB9DQogICAgICAgIC8vIOWQiOW5tue7hO+8muWFs+mUruWt
l+WPr+iDveWIhuaVo+WcqOS4jeWQjOihjO+8iOagh+mimC/mraPmlofvvIkNCiAgICAgICAgY29u
c3QgYnlHcm91cCA9IG5ldyBNYXAoKTsNCiAgICAgICAgZm9yIChjb25zdCBjIG9mIGNsaXBzKSB7
DQogICAgICAgICAgICBjb25zdCBnaWQgPSBTdHJpbmcoYyAmJiBjLmZhdkdyb3VwIHx8ICcnKS50
cmltKCk7DQogICAgICAgICAgICBpZiAoIWdpZCkgY29udGludWU7DQogICAgICAgICAgICBpZiAo
IWJ5R3JvdXAuaGFzKGdpZCkpIGJ5R3JvdXAuc2V0KGdpZCwgW10pOw0KICAgICAgICAgICAgYnlH
cm91cC5nZXQoZ2lkKS5wdXNoKGMpOw0KICAgICAgICB9DQogICAgICAgIGZvciAoY29uc3QgW2dp
ZCwgbWVtYmVyc10gb2YgYnlHcm91cCkgew0KICAgICAgICAgICAgaWYgKG1hdGNoZWRHcm91cHMu
aGFzKGdpZCkpIGNvbnRpbnVlOw0KICAgICAgICAgICAgY29uc3QgdW5pb24gPSBtZW1iZXJzLm1h
cChjID0+IHsNCiAgICAgICAgICAgICAgICBjb25zdCB0eXBlID0gU3RyaW5nKGMudHlwZSB8fCAn
JykudG9Mb3dlckNhc2UoKTsNCiAgICAgICAgICAgICAgICByZXR1cm4gKHR5cGUgPT09ICdpbWFn
ZScgPyBTdHJpbmcoYy5mYXZUaXRsZSB8fCAnJykgOiBjbGlwU2VhcmNoSGF5KGMpKS50b0xvd2Vy
Q2FzZSgpOw0KICAgICAgICAgICAgfSkuam9pbignICcpOw0KICAgICAgICAgICAgaWYgKHRlcm1M
LmV2ZXJ5KHQgPT4gdW5pb24uaW5jbHVkZXModCkpKQ0KICAgICAgICAgICAgICAgIG1hdGNoZWRH
cm91cHMuYWRkKGdpZCk7DQogICAgICAgIH0NCiAgICAgICAgbGV0IG91dCA9IGNsaXBzLmZpbHRl
cihjID0+IHsNCiAgICAgICAgICAgIGlmIChjbGlwTWF0Y2hlc1NlYXJjaChjLCB0ZXJtTCkpIHJl
dHVybiB0cnVlOw0KICAgICAgICAgICAgY29uc3QgZ2lkID0gU3RyaW5nKGMgJiYgYy5mYXZHcm91
cCB8fCAnJykudHJpbSgpOw0KICAgICAgICAgICAgcmV0dXJuIGdpZCAmJiBtYXRjaGVkR3JvdXBz
LmhhcyhnaWQpOw0KICAgICAgICB9KTsNCiAgICAgICAgLy8g5pyA6L+R6aG15pCc57Si77ya5ZG9
5Lit55qE5Zu65a6a6aG55o6S5YmN6Z2iDQogICAgICAgIGlmICh0YWIgPT09ICdyZWNlbnQnIHx8
IChvdXQubGVuZ3RoICYmIG91dC5ldmVyeShjID0+IG5vcm1UeXBlKGMudHlwZSkgPT09ICdyZWNl
bnQnKSkpIHsNCiAgICAgICAgICAgIGNvbnN0IHBpbm5lZCA9IFtdOw0KICAgICAgICAgICAgY29u
c3QgcmVzdCA9IFtdOw0KICAgICAgICAgICAgZm9yIChjb25zdCBjIG9mIG91dCkgew0KICAgICAg
ICAgICAgICAgIGlmIChpc1Bpbm5lZChjKSkgcGlubmVkLnB1c2goYyk7DQogICAgICAgICAgICAg
ICAgZWxzZSByZXN0LnB1c2goYyk7DQogICAgICAgICAgICB9DQogICAgICAgICAgICBvdXQgPSBw
aW5uZWQuY29uY2F0KHJlc3QpOw0KICAgICAgICB9DQogICAgICAgIHJldHVybiBvdXQ7DQogICAg
fQ0KDQogICAgZnVuY3Rpb24gbWFya1Bhc3RlZExvY2FsKGlkcykgew0KICAgICAgICBjb25zdCBs
aXN0ID0gQXJyYXkuaXNBcnJheShpZHMpID8gaWRzIDogW2lkc107DQogICAgICAgIGlmIChsaXN0
Lmxlbmd0aCkNCiAgICAgICAgICAgIHJlbWVtYmVyTGFzdFBhc3RlKGxpc3RbbGlzdC5sZW5ndGgg
LSAxXSk7DQogICAgICAgIGNvbnN0IGJhZGdlSHRtbCA9IGA8c3ZnIHZpZXdCb3g9IjAgMCAxNiAx
NiIgZmlsbD0ibm9uZSIgc3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0cm9rZS13aWR0aD0iMi40IiBz
dHJva2UtbGluZWNhcD0icm91bmQiIHN0cm9rZS1saW5lam9pbj0icm91bmQiPjxwb2x5bGluZSBw
b2ludHM9IjMuNSA4LjUgNi41IDExLjUgMTIuNSA0LjUiLz48L3N2Zz5gOw0KICAgICAgICBsaXN0
LmZvckVhY2gocmF3SWQgPT4gew0KICAgICAgICAgICAgY29uc3QgaWQgPSArcmF3SWQ7DQogICAg
ICAgICAgICBjb25zdCBjID0gYWxsQ2xpcHMuZmluZCh4ID0+ICt4LmlkID09PSBpZCk7DQogICAg
ICAgICAgICBpZiAoYykgYy5wYXN0ZWQgPSB0cnVlOw0KICAgICAgICAgICAgY29uc3Qgcm93ID0g
bGlzdEVsICYmICgNCiAgICAgICAgICAgICAgICBsaXN0RWwucXVlcnlTZWxlY3RvcignLml0bVtk
YXRhLWlkPSInICsgaWQgKyAnIl0nKQ0KICAgICAgICAgICAgICAgIHx8IGxpc3RFbC5xdWVyeVNl
bGVjdG9yKCcuaXRtW2RhdGEtaWQ9IicgKyBTdHJpbmcocmF3SWQpICsgJyJdJykNCiAgICAgICAg
ICAgICk7DQogICAgICAgICAgICBpZiAoIXJvdykgcmV0dXJuOw0KICAgICAgICAgICAgcm93LmNs
YXNzTGlzdC5hZGQoJ3Bhc3RlZCcsICdxLWRvbmUnKTsNCiAgICAgICAgICAgIGNvbnN0IGljbyA9
IHJvdy5xdWVyeVNlbGVjdG9yKCcuaS1pY28nKTsNCiAgICAgICAgICAgIGlmIChpY28gJiYgIWlj
by5xdWVyeVNlbGVjdG9yKCcuaS11c2VkJykpIHsNCiAgICAgICAgICAgICAgICBjb25zdCBiYWRn
ZSA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ3NwYW4nKTsNCiAgICAgICAgICAgICAgICBiYWRn
ZS5jbGFzc05hbWUgPSAnaS11c2VkJzsNCiAgICAgICAgICAgICAgICBiYWRnZS50aXRsZSA9ICfl
t7LnspjotLQnOw0KICAgICAgICAgICAgICAgIGJhZGdlLmlubmVySFRNTCA9IGJhZGdlSHRtbDsN
CiAgICAgICAgICAgICAgICBpY28uYXBwZW5kQ2hpbGQoYmFkZ2UpOw0KICAgICAgICAgICAgfQ0K
ICAgICAgICB9KTsNCiAgICAgICAgdHJ5IHsgbWFya1F1ZXVlUmFpbHMoKTsgfSBjYXRjaCAoZSkg
e30NCiAgICB9DQogICAgd2luZG93Ll9fbWFya1Bhc3RlZCA9IG1hcmtQYXN0ZWRMb2NhbDsNCg0K
ICAgIGZ1bmN0aW9uIG1hcmtVbnBhc3RlZExvY2FsKGlkcykgew0KICAgICAgICBjb25zdCBsaXN0
ID0gQXJyYXkuaXNBcnJheShpZHMpID8gaWRzIDogW2lkc107DQogICAgICAgIGxpc3QuZm9yRWFj
aChyYXdJZCA9PiB7DQogICAgICAgICAgICBjb25zdCBpZCA9ICtyYXdJZDsNCiAgICAgICAgICAg
IGNvbnN0IGMgPSBhbGxDbGlwcy5maW5kKHggPT4gK3guaWQgPT09IGlkKTsNCiAgICAgICAgICAg
IGlmIChjKSBjLnBhc3RlZCA9IGZhbHNlOw0KICAgICAgICAgICAgY29uc3Qgcm93ID0gbGlzdEVs
ICYmICgNCiAgICAgICAgICAgICAgICBsaXN0RWwucXVlcnlTZWxlY3RvcignLml0bVtkYXRhLWlk
PSInICsgaWQgKyAnIl0nKQ0KICAgICAgICAgICAgICAgIHx8IGxpc3RFbC5xdWVyeVNlbGVjdG9y
KCcuaXRtW2RhdGEtaWQ9IicgKyBTdHJpbmcocmF3SWQpICsgJyJdJykNCiAgICAgICAgICAgICk7
DQogICAgICAgICAgICBpZiAoIXJvdykgcmV0dXJuOw0KICAgICAgICAgICAgcm93LmNsYXNzTGlz
dC5yZW1vdmUoJ3Bhc3RlZCcsICdxLWRvbmUnLCAncS1kb25lLWxpbmsnKTsNCiAgICAgICAgICAg
IGNvbnN0IGJhZGdlID0gcm93LnF1ZXJ5U2VsZWN0b3IoJy5pLXVzZWQnKTsNCiAgICAgICAgICAg
IGlmIChiYWRnZSkgYmFkZ2UucmVtb3ZlKCk7DQogICAgICAgICAgICBjb25zdCBkb3QgPSByb3cu
cXVlcnlTZWxlY3RvcignLnEtZG90Jyk7DQogICAgICAgICAgICBpZiAoZG90KSBkb3QudGl0bGUg
PSAn57KY6LS06Zif5YiXJzsNCiAgICAgICAgfSk7DQogICAgICAgIHRyeSB7IG1hcmtRdWV1ZVJh
aWxzKCk7IH0gY2F0Y2ggKGUpIHt9DQogICAgfQ0KICAgIHdpbmRvdy5fX21hcmtVbnBhc3RlZCA9
IG1hcmtVbnBhc3RlZExvY2FsOw0KDQogICAgY29uc3QgbGlzdEVsICA9IGRvY3VtZW50LmdldEVs
ZW1lbnRCeUlkKCdsaXN0Jyk7DQogICAgY29uc3QgZW1wdHlFbCA9IGRvY3VtZW50LmdldEVsZW1l
bnRCeUlkKCdlbXB0eScpOw0KICAgIGNvbnN0IHNrZWxFbCAgPSBkb2N1bWVudC5nZXRFbGVtZW50
QnlJZCgnc2tlbCcpOw0KICAgIGNvbnN0IGJ0blRvcCAgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJ
ZCgnYnRuLXRvcCcpOw0KICAgIGZ1bmN0aW9uIHNldEJvb3RMb2FkaW5nKG9uKSB7DQogICAgICAg
IGJvb3RMb2FkaW5nID0gISFvbjsNCiAgICAgICAgLy8g56eS5byA77ya5LiN5YaN5omT5byA6aqo
5p626Zeq5Yqo77yb5Y+q5L+d55WZIHdhaXRpbmdEYXRhIOmAu+i+kemYsuepuuaAgeivr+mXqg0K
ICAgICAgICBpZiAoc2tlbEVsKSBza2VsRWwuY2xhc3NMaXN0LnJlbW92ZSgnb24nKTsNCiAgICAg
ICAgaWYgKG9uICYmIGVtcHR5RWwpIGVtcHR5RWwuY2xhc3NMaXN0LnJlbW92ZSgnb24nKTsNCiAg
ICAgICAgY29uc3QgYXBwID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2FwcCcpOw0KICAgICAg
ICBpZiAoYXBwKSBhcHAuY2xhc3NMaXN0LnJlbW92ZSgnYm9vdC1sb2FkaW5nJyk7DQogICAgfQ0K
ICAgIC8qKiBXYWl0IGZvciBob3N0IGRhdGEg4oCU5LiN5YaN56uL5Yi75by56aqo5p6277yM5pyJ
5YaF5a655pe25L+d5oyB5pen5YiX6KGoICovDQogICAgZnVuY3Rpb24gc2NoZWR1bGVEZWxheWVk
U2tlbCgpIHsNCiAgICAgICAgd2FpdGluZ0RhdGEgPSB0cnVlOw0KICAgICAgICB3aW5kb3cuX19k
YXRhUmVhZHkgPSBmYWxzZTsNCiAgICAgICAgaWYgKGVtcHR5RWwpIGVtcHR5RWwuY2xhc3NMaXN0
LnJlbW92ZSgnb24nKTsNCiAgICAgICAgaWYgKHdpbmRvdy5fX3BlbmRpbmdTa2VsVGltZXIpIHsN
CiAgICAgICAgICAgIGNsZWFyVGltZW91dCh3aW5kb3cuX19wZW5kaW5nU2tlbFRpbWVyKTsNCiAg
ICAgICAgICAgIHdpbmRvdy5fX3BlbmRpbmdTa2VsVGltZXIgPSAwOw0KICAgICAgICB9DQogICAg
ICAgIHdpbmRvdy5fX3BlbmRpbmdTa2VsU2luY2UgPSBEYXRlLm5vdygpOw0KICAgICAgICAvLyDm
nInml6fliJfooajlsLHkv53nlZnvvJvnqbrliJfooajkuZ/kuI3lho3mkq3pqqjmnrbliqjnlLsN
CiAgICB9DQogICAgZnVuY3Rpb24gY2xlYXJXYWl0aW5nRGF0YSgpIHsNCiAgICAgICAgd2FpdGlu
Z0RhdGEgPSBmYWxzZTsNCiAgICAgICAgaWYgKHdpbmRvdy5fX3BlbmRpbmdTa2VsVGltZXIpIHsN
CiAgICAgICAgICAgIGNsZWFyVGltZW91dCh3aW5kb3cuX19wZW5kaW5nU2tlbFRpbWVyKTsNCiAg
ICAgICAgICAgIHdpbmRvdy5fX3BlbmRpbmdTa2VsVGltZXIgPSAwOw0KICAgICAgICB9DQogICAg
ICAgIHdpbmRvdy5fX3BlbmRpbmdTa2VsU2luY2UgPSAwOw0KICAgICAgICBzZXRCb290TG9hZGlu
ZyhmYWxzZSk7DQogICAgfQ0KICAgIHdpbmRvdy5zZXRCb290TG9hZGluZyA9IHNldEJvb3RMb2Fk
aW5nOw0KICAgIHdpbmRvdy5mb3JjZUVuZEJvb3RMb2FkaW5nID0gZnVuY3Rpb24oKSB7DQogICAg
ICAgIGNsZWFyV2FpdGluZ0RhdGEoKTsNCiAgICAgICAgLy8gRG8gbm90IGZha2XjgIzmmoLml6Do
rrDlvZXjgI1pZiBob3N0IG5ldmVyIHB1c2hlZA0KICAgICAgICBpZiAoaG9zdFB1c2hlZE9uY2Up
DQogICAgICAgICAgICB3aW5kb3cuX19kYXRhUmVhZHkgPSB0cnVlOw0KICAgICAgICB0cnkgeyBy
ZW5kZXIoKTsgfSBjYXRjaCAoZSkge30NCiAgICB9Ow0KICAgIC8vIFNhZmV0eTogZHJvcCBzdHVj
ayBza2VsZXRvbjsgc3RpbGwgbmV2ZXIgaW52ZW50IGVtcHR5LXN0YXRlIHdpdGhvdXQgaG9zdCBw
dXNoDQogICAgc2V0VGltZW91dCgoKSA9PiB7DQogICAgICAgIGlmIChob3N0UHVzaGVkT25jZSB8
fCB3aW5kb3cuX19kYXRhUmVhZHkpIHJldHVybjsNCiAgICAgICAgaWYgKCFib290TG9hZGluZyAm
JiAhd2FpdGluZ0RhdGEpIHJldHVybjsNCiAgICAgICAgY2xlYXJXYWl0aW5nRGF0YSgpOw0KICAg
ICAgICB0cnkgeyByZW5kZXIoKTsgfSBjYXRjaCB7fQ0KICAgIH0sIDgwMDApOw0KDQogICAgZnVu
Y3Rpb24gdXBkYXRlVG9wQnRuKCkgew0KICAgICAgICBpZiAoIWJ0blRvcCB8fCAhbGlzdEVsKSBy
ZXR1cm47DQogICAgICAgIGJ0blRvcC5jbGFzc0xpc3QudG9nZ2xlKCdvbicsIGxpc3RFbC5zY3Jv
bGxUb3AgPiA0OCk7DQogICAgfQ0KICAgIGxldCBfc2Nyb2xsUmFmID0gMDsNCiAgICBsZXQgX3Nj
cm9sbElkbGVUID0gMDsNCiAgICBsZXQgX2xpc3RQdHJEb3duID0gZmFsc2U7DQogICAgbGV0IF9w
ZW5kaW5nQXBwZW5kID0gbnVsbDsgLy8geyBmcm9tTGVuIH0gcXVldWVkIHdoaWxlIHNjcm9sbGlu
Zw0KICAgIHdpbmRvdy5fX3Njcm9sbEJ1c3kgPSBmYWxzZTsNCiAgICB3aW5kb3cuX193YW50TW9y
ZSA9IGZhbHNlOw0KDQogICAgZnVuY3Rpb24gbWFya0xpc3RTY3JvbGxpbmcoKSB7DQogICAgICAg
IHdpbmRvdy5fX3Njcm9sbEJ1c3kgPSB0cnVlOw0KICAgICAgICB0cnkgeyBsaXN0RWwuY2xhc3NM
aXN0LmFkZCgnaXMtc2Nyb2xsaW5nJyk7IH0gY2F0Y2gge30NCiAgICAgICAgaWYgKF9zY3JvbGxJ
ZGxlVCkgY2xlYXJUaW1lb3V0KF9zY3JvbGxJZGxlVCk7DQogICAgICAgIF9zY3JvbGxJZGxlVCA9
IHNldFRpbWVvdXQoKCkgPT4gew0KICAgICAgICAgICAgX3Njcm9sbElkbGVUID0gMDsNCiAgICAg
ICAgICAgIGZsdXNoU2Nyb2xsSWRsZSgpOw0KICAgICAgICB9LCAyMjApOw0KICAgIH0NCg0KICAg
IGZ1bmN0aW9uIGZsdXNoU2Nyb2xsSWRsZSgpIHsNCiAgICAgICAgaWYgKF9saXN0UHRyRG93bikg
ew0KICAgICAgICAgICAgbWFya0xpc3RTY3JvbGxpbmcoKTsNCiAgICAgICAgICAgIHJldHVybjsN
CiAgICAgICAgfQ0KICAgICAgICB3aW5kb3cuX19zY3JvbGxCdXN5ID0gZmFsc2U7DQogICAgICAg
IHRyeSB7IGxpc3RFbC5jbGFzc0xpc3QucmVtb3ZlKCdpcy1zY3JvbGxpbmcnKTsgfSBjYXRjaCB7
fQ0KICAgICAgICBpZiAoX3BlbmRpbmdBcHBlbmQpIHsNCiAgICAgICAgICAgIGNvbnN0IHBlbmRp
bmcgPSBfcGVuZGluZ0FwcGVuZDsNCiAgICAgICAgICAgIF9wZW5kaW5nQXBwZW5kID0gbnVsbDsN
CiAgICAgICAgICAgIGFwcGx5QXBwZW5kUGF5bG9hZChwZW5kaW5nKTsNCiAgICAgICAgfQ0KICAg
ICAgICBpZiAod2luZG93Ll9fd2FudE1vcmUpDQogICAgICAgICAgICByZXF1ZXN0TW9yZSgpOw0K
ICAgICAgICBlbHNlIGlmICghbG9hZGluZ01vcmUNCiAgICAgICAgICAgICYmIGRpc2tUb3RhbCA+
IDANCiAgICAgICAgICAgICYmIGFsbENsaXBzLmxlbmd0aCA8IGRpc2tUb3RhbA0KICAgICAgICAg
ICAgJiYgbGlzdEVsLnNjcm9sbFRvcCArIGxpc3RFbC5jbGllbnRIZWlnaHQgPj0gbGlzdEVsLnNj
cm9sbEhlaWdodCAtIDQyMCkNCiAgICAgICAgICAgIHJlcXVlc3RNb3JlKCk7DQogICAgfQ0KDQog
ICAgZnVuY3Rpb24gb25MaXN0U2Nyb2xsKCkgew0KICAgICAgICBtYXJrTGlzdFNjcm9sbGluZygp
Ow0KICAgICAgICBpZiAoX3Njcm9sbFJhZikgcmV0dXJuOw0KICAgICAgICBfc2Nyb2xsUmFmID0g
cmVxdWVzdEFuaW1hdGlvbkZyYW1lKCgpID0+IHsNCiAgICAgICAgICAgIF9zY3JvbGxSYWYgPSAw
Ow0KICAgICAgICAgICAgdHJ5IHsgaGlkZVBhdGhUaXAoKTsgfSBjYXRjaCB7fQ0KICAgICAgICAg
ICAgdXBkYXRlVG9wQnRuKCk7DQogICAgICAgICAgICBpZiAoIWxvYWRpbmdNb3JlDQogICAgICAg
ICAgICAgICAgJiYgZGlza1RvdGFsID4gMA0KICAgICAgICAgICAgICAgICYmIGFsbENsaXBzLmxl
bmd0aCA8IGRpc2tUb3RhbA0KICAgICAgICAgICAgICAgICYmIGxpc3RFbC5zY3JvbGxUb3AgKyBs
aXN0RWwuY2xpZW50SGVpZ2h0ID49IGxpc3RFbC5zY3JvbGxIZWlnaHQgLSAyNDApDQogICAgICAg
ICAgICAgICAgd2luZG93Ll9fd2FudE1vcmUgPSB0cnVlOw0KICAgICAgICB9KTsNCiAgICB9DQog
ICAgbGlzdEVsLmFkZEV2ZW50TGlzdGVuZXIoJ3Njcm9sbCcsIG9uTGlzdFNjcm9sbCwgeyBwYXNz
aXZlOiB0cnVlIH0pOw0KICAgIGxpc3RFbC5hZGRFdmVudExpc3RlbmVyKCd3aGVlbCcsIG1hcmtM
aXN0U2Nyb2xsaW5nLCB7IHBhc3NpdmU6IHRydWUgfSk7DQogICAgbGlzdEVsLmFkZEV2ZW50TGlz
dGVuZXIoJ3BvaW50ZXJkb3duJywgZSA9PiB7DQogICAgICAgIGlmIChlLmJ1dHRvbiAhPT0gMCkg
cmV0dXJuOw0KICAgICAgICBfbGlzdFB0ckRvd24gPSB0cnVlOw0KICAgICAgICBtYXJrTGlzdFNj
cm9sbGluZygpOw0KICAgIH0sIHsgcGFzc2l2ZTogdHJ1ZSB9KTsNCiAgICB3aW5kb3cuYWRkRXZl
bnRMaXN0ZW5lcigncG9pbnRlcnVwJywgKCkgPT4gew0KICAgICAgICBpZiAoIV9saXN0UHRyRG93
bikgcmV0dXJuOw0KICAgICAgICBfbGlzdFB0ckRvd24gPSBmYWxzZTsNCiAgICAgICAgbWFya0xp
c3RTY3JvbGxpbmcoKTsNCiAgICB9LCB7IHBhc3NpdmU6IHRydWUgfSk7DQogICAgd2luZG93LmFk
ZEV2ZW50TGlzdGVuZXIoJ3BvaW50ZXJjYW5jZWwnLCAoKSA9PiB7DQogICAgICAgIGlmICghX2xp
c3RQdHJEb3duKSByZXR1cm47DQogICAgICAgIF9saXN0UHRyRG93biA9IGZhbHNlOw0KICAgICAg
ICBtYXJrTGlzdFNjcm9sbGluZygpOw0KICAgIH0sIHsgcGFzc2l2ZTogdHJ1ZSB9KTsNCiAgICBi
dG5Ub3AuYWRkRXZlbnRMaXN0ZW5lcignY2xpY2snLCBlID0+IHsNCiAgICAgICAgZS5zdG9wUHJv
cGFnYXRpb24oKTsNCiAgICAgICAgbGlzdEVsLnNjcm9sbFRvKHsgdG9wOiAwLCBiZWhhdmlvcjog
J3Ntb290aCcgfSk7DQogICAgfSk7DQoNCiAgICBmdW5jdGlvbiB2aXNpYmxlTGlzdCgpIHsNCiAg
ICAgICAgY29uc3QgcSA9IFN0cmluZyhxdWVyeSB8fCAnJykudHJpbSgpOw0KICAgICAgICAvLyBI
b3N0IGFscmVhZHkgZmlsdGVyZWQrZXhwYW5kZWQgZm9yIHRoaXMgZXhhY3QgcXVlcnkg4oCUIGRv
bid0IHJlLWZpbHRlciAoYXZvaWRzIGZsYXNoIC8gZHJvcHBlZCBmYXYgZ3JvdXBzKQ0KICAgICAg
ICBsZXQgbGlzdCA9IChxICYmIHdpbmRvdy5fX2hvc3RGaWx0ZXJlZCAmJiB3aW5kb3cuX19ob3N0
RmlsdGVyUSA9PT0gcSkNCiAgICAgICAgICAgID8gYWxsQ2xpcHMNCiAgICAgICAgICAgIDogZmls
dGVyKGFsbENsaXBzLCBjdXJUYWIsIHF1ZXJ5KTsNCiAgICAgICAgLy8g5pS26JeP6aG177ya5pys
5Zyw5YaN5ruk5LiA5qyh77yM5Y+W5raI5pS26JeP5Y+v56uL5Yi75raI5aSx77yM5LiN5b+F562J
IEFISyDph43lu7oNCiAgICAgICAgaWYgKGN1clRhYiA9PT0gJ3Bpbm5lZCcpDQogICAgICAgICAg
ICBsaXN0ID0gbGlzdC5maWx0ZXIoYyA9PiBpc1Bpbm5lZChjKSk7DQogICAgICAgIHJldHVybiBs
aXN0Ow0KICAgIH0NCiAgICBmdW5jdGlvbiBlc2NIdG1sKHMpIHsNCiAgICAgICAgcmV0dXJuIFN0
cmluZyhzID8/ICcnKS5yZXBsYWNlKC8mL2csJyZhbXA7JykucmVwbGFjZSgvPC9nLCcmbHQ7Jyku
cmVwbGFjZSgvPi9nLCcmZ3Q7JykucmVwbGFjZSgvIi9nLCcmcXVvdDsnKTsNCiAgICB9DQogICAg
ZnVuY3Rpb24gcXVlcnlUZXJtcyhxKSB7DQogICAgICAgIGNvbnN0IG91dCA9IFtdOw0KICAgICAg
ICBmb3IgKGNvbnN0IHNlZyBvZiBTdHJpbmcocSB8fCAnJykuc3BsaXQoJ3wnKSkgew0KICAgICAg
ICAgICAgY29uc3QgcyA9IHNlZy50cmltKCk7DQogICAgICAgICAgICBpZiAoIXMpIGNvbnRpbnVl
Ow0KICAgICAgICAgICAgY29uc3Qgd29yZHMgPSBzLnNwbGl0KC9ccysvKS5maWx0ZXIoQm9vbGVh
bik7DQogICAgICAgICAgICBpZiAod29yZHMubGVuZ3RoKSBvdXQucHVzaCguLi53b3Jkcyk7DQog
ICAgICAgIH0NCiAgICAgICAgcmV0dXJuIG91dDsNCiAgICB9DQogICAgZnVuY3Rpb24gaGxIdG1s
KHRleHQpIHsNCiAgICAgICAgY29uc3QgdGVybXMgPSBxdWVyeVRlcm1zKHF1ZXJ5KTsNCiAgICAg
ICAgY29uc3QgcyA9IFN0cmluZyh0ZXh0ID8/ICcnKTsNCiAgICAgICAgaWYgKCF0ZXJtcy5sZW5n
dGgpIHJldHVybiBlc2NIdG1sKHMpOw0KICAgICAgICBjb25zdCBsb3dlciA9IHMudG9Mb3dlckNh
c2UoKTsNCiAgICAgICAgY29uc3QgdGVybUwgPSB0ZXJtcy5tYXAodCA9PiB0LnRvTG93ZXJDYXNl
KCkpOw0KICAgICAgICBsZXQgb3V0ID0gJycsIGkgPSAwOw0KICAgICAgICB3aGlsZSAoaSA8IHMu
bGVuZ3RoKSB7DQogICAgICAgICAgICBsZXQgYmVzdEogPSAtMSwgYmVzdExlbiA9IDA7DQogICAg
ICAgICAgICBmb3IgKGxldCB0aSA9IDA7IHRpIDwgdGVybUwubGVuZ3RoOyB0aSsrKSB7DQogICAg
ICAgICAgICAgICAgY29uc3QgdCA9IHRlcm1MW3RpXTsNCiAgICAgICAgICAgICAgICBpZiAoIXQp
IGNvbnRpbnVlOw0KICAgICAgICAgICAgICAgIGNvbnN0IGogPSBsb3dlci5pbmRleE9mKHQsIGkp
Ow0KICAgICAgICAgICAgICAgIGlmIChqIDwgMCkgY29udGludWU7DQogICAgICAgICAgICAgICAg
aWYgKGJlc3RKIDwgMCB8fCBqIDwgYmVzdEogfHwgKGogPT09IGJlc3RKICYmIHQubGVuZ3RoID4g
YmVzdExlbikpIHsNCiAgICAgICAgICAgICAgICAgICAgYmVzdEogPSBqOyBiZXN0TGVuID0gdC5s
ZW5ndGg7DQogICAgICAgICAgICAgICAgfQ0KICAgICAgICAgICAgfQ0KICAgICAgICAgICAgaWYg
KGJlc3RKIDwgMCkgeyBvdXQgKz0gZXNjSHRtbChzLnNsaWNlKGkpKTsgYnJlYWs7IH0NCiAgICAg
ICAgICAgIG91dCArPSBlc2NIdG1sKHMuc2xpY2UoaSwgYmVzdEopKTsNCiAgICAgICAgICAgIG91
dCArPSAnPG1hcmsgY2xhc3M9InEtaGwiPicgKyBlc2NIdG1sKHMuc2xpY2UoYmVzdEosIGJlc3RK
ICsgYmVzdExlbikpICsgJzwvbWFyaz4nOw0KICAgICAgICAgICAgaSA9IGJlc3RKICsgTWF0aC5t
YXgoMSwgYmVzdExlbik7DQogICAgICAgIH0NCiAgICAgICAgcmV0dXJuIG91dDsNCiAgICB9DQog
ICAgZnVuY3Rpb24gc2V0SGxUZXh0KGVsLCB0ZXh0KSB7DQogICAgICAgIGlmICghZWwpIHJldHVy
bjsNCiAgICAgICAgY29uc3QgcSA9IFN0cmluZyhxdWVyeSB8fCAnJykudHJpbSgpOw0KICAgICAg
ICBpZiAoIXEpIHsNCiAgICAgICAgICAgIGVsLmNsYXNzTGlzdC5yZW1vdmUoJ2hhcy1obCcpOw0K
ICAgICAgICAgICAgZWwudGV4dENvbnRlbnQgPSB0ZXh0ID09IG51bGwgPyAnJyA6IFN0cmluZyh0
ZXh0KTsNCiAgICAgICAgICAgIHJldHVybjsNCiAgICAgICAgfQ0KICAgICAgICBlbC5jbGFzc0xp
c3QuYWRkKCdoYXMtaGwnKTsNCiAgICAgICAgZWwuaW5uZXJIVE1MID0gaGxIdG1sKHRleHQpOw0K
ICAgIH0NCg0KDQogICAgZnVuY3Rpb24gYXBwbHlUYWJTd2l0Y2hBbmltKCkgew0KICAgICAgICBp
ZiAoIXRhYlN3aXRjaEFuaW1EaXIgfHwgIWxpc3RFbCkgcmV0dXJuOw0KICAgICAgICBpZiAoIWxp
c3RFbC5xdWVyeVNlbGVjdG9yKCcuaXRtLCAjZW1wdHkub24sICNsaXN0LW1vcmUnKSkNCiAgICAg
ICAgICAgIHJldHVybjsNCiAgICAgICAgY29uc3QgZGlyID0gdGFiU3dpdGNoQW5pbURpcjsNCiAg
ICAgICAgdGFiU3dpdGNoQW5pbURpciA9IDA7DQogICAgICAgIGxpc3RFbC5jbGFzc0xpc3QucmVt
b3ZlKCd0YWItaW4tbHInLCAndGFiLWluLXJsJyk7DQogICAgICAgIHZvaWQgbGlzdEVsLm9mZnNl
dFdpZHRoOw0KICAgICAgICBsaXN0RWwuY2xhc3NMaXN0LmFkZChkaXIgPiAwID8gJ3RhYi1pbi1s
cicgOiAndGFiLWluLXJsJyk7DQogICAgICAgIGNsZWFyVGltZW91dChsaXN0RWwuX3RhYkFuaW1U
aW1lcik7DQogICAgICAgIGxpc3RFbC5fdGFiQW5pbVRpbWVyID0gc2V0VGltZW91dCgoKSA9PiB7
DQogICAgICAgICAgICBsaXN0RWwuY2xhc3NMaXN0LnJlbW92ZSgndGFiLWluLWxyJywgJ3RhYi1p
bi1ybCcpOw0KICAgICAgICB9LCA0MDApOw0KICAgIH0NCg0KICAgIGZ1bmN0aW9uIHRhYkluZGV4
KHRhYikgew0KICAgICAgICBjb25zdCBpID0gVEFCX09SREVSLmluZGV4T2YodGFiKTsNCiAgICAg
ICAgcmV0dXJuIGkgPj0gMCA/IGkgOiAwOw0KICAgIH0NCg0KICAgIGZ1bmN0aW9uIG1vdmVUYWJJ
bmsoaW5zdGFudCwgdGFyZ2V0RWwpIHsNCiAgICAgICAgY29uc3QgaW5rID0gZG9jdW1lbnQuZ2V0
RWxlbWVudEJ5SWQoJ3RhYi1pbmsnKTsNCiAgICAgICAgY29uc3QgdGFicyA9IGRvY3VtZW50Lmdl
dEVsZW1lbnRCeUlkKCd0YWJzJyk7DQogICAgICAgIGNvbnN0IGVsID0gdGFyZ2V0RWwgfHwgZG9j
dW1lbnQucXVlcnlTZWxlY3RvcignI3RhYnMgLnRhYi5vbicpOw0KICAgICAgICBpZiAoIWluayB8
fCAhdGFicyB8fCAhZWwpIHJldHVybjsNCiAgICAgICAgY29uc3QgdHIgPSB0YWJzLmdldEJvdW5k
aW5nQ2xpZW50UmVjdCgpOw0KICAgICAgICBjb25zdCByID0gZWwuZ2V0Qm91bmRpbmdDbGllbnRS
ZWN0KCk7DQogICAgICAgIGNvbnN0IHggPSByLmxlZnQgLSB0ci5sZWZ0Ow0KICAgICAgICBjb25z
dCBoID0gTWF0aC5tYXgoMjAsIE1hdGgucm91bmQoci5oZWlnaHQpKTsNCiAgICAgICAgY29uc3Qg
eSA9IHIudG9wIC0gdHIudG9wOw0KICAgICAgICBjb25zdCB3ID0gTWF0aC5tYXgoMjQsIHIud2lk
dGgpOw0KICAgICAgICBjb25zdCBwb3MgPSAndHJhbnNsYXRlM2QoJyArIHggKyAncHgsJyArIHkg
KyAncHgsMCknOw0KICAgICAgICBpbmsuc3R5bGUudHJhbnNmb3JtT3JpZ2luID0gJ2NlbnRlciBi
b3R0b20nOw0KICAgICAgICBpbmsuc3R5bGUud2lkdGggPSB3ICsgJ3B4JzsNCiAgICAgICAgaW5r
LnN0eWxlLmhlaWdodCA9IGggKyAncHgnOw0KICAgICAgICBpZiAoaW5zdGFudCkgew0KICAgICAg
ICAgICAgaW5rLnN0eWxlLnRyYW5zaXRpb24gPSAnbm9uZSc7DQogICAgICAgICAgICBpbmsuY2xh
c3NMaXN0LnJlbW92ZSgnc3F1YXNoJyk7DQogICAgICAgICAgICBpbmsuc3R5bGUudHJhbnNmb3Jt
ID0gcG9zICsgJyBzY2FsZVgoMSknOw0KICAgICAgICAgICAgaW5rLm9mZnNldEhlaWdodDsNCiAg
ICAgICAgICAgIGluay5zdHlsZS50cmFuc2l0aW9uID0gJyc7DQogICAgICAgICAgICByZXR1cm47
DQogICAgICAgIH0NCiAgICAgICAgLy8gU25hcCB0byBob3ZlcmVkIHRhYiwgZXhwYW5kIGZyb20g
Ym90dG9tLWNlbnRlciDigJQgbm8gc2xpZGluZyBiZXR3ZWVuIHRhYnMNCiAgICAgICAgaW5rLnN0
eWxlLnRyYW5zaXRpb24gPSAnbm9uZSc7DQogICAgICAgIGluay5zdHlsZS50cmFuc2Zvcm0gPSBw
b3MgKyAnIHNjYWxlWCgwLjAwMSknOw0KICAgICAgICBpbmsub2Zmc2V0SGVpZ2h0Ow0KICAgICAg
ICBpbmsuc3R5bGUudHJhbnNpdGlvbiA9ICcnOw0KICAgICAgICBpbmsuY2xhc3NMaXN0LmFkZCgn
c3F1YXNoJyk7DQogICAgICAgIGluay5zdHlsZS50cmFuc2Zvcm0gPSBwb3MgKyAnIHNjYWxlWCgx
KSc7DQogICAgICAgIGNsZWFyVGltZW91dChpbmsuX3NxdWFzaFRpbWVyKTsNCiAgICAgICAgaW5r
Ll9zcXVhc2hUaW1lciA9IHNldFRpbWVvdXQoKCkgPT4gaW5rLmNsYXNzTGlzdC5yZW1vdmUoJ3Nx
dWFzaCcpLCAzNDApOw0KICAgIH0NCiAgICBmdW5jdGlvbiBtYXJrVGFiKHRhYiwgaW5zdGFudCkg
ew0KICAgICAgICBkb2N1bWVudC5xdWVyeVNlbGVjdG9yQWxsKCcjdGFicyAudGFiJykuZm9yRWFj
aChlbCA9Pg0KICAgICAgICAgICAgZWwuY2xhc3NMaXN0LnRvZ2dsZSgnb24nLCBlbC5kYXRhc2V0
LnRhYiA9PT0gdGFiKSk7DQogICAgICAgIG1vdmVUYWJJbmsoISFpbnN0YW50KTsNCiAgICB9DQog
ICAgZnVuY3Rpb24gYmluZFRhYklua0hvdmVyKCkgew0KICAgICAgICBjb25zdCB0YWJzID0gZG9j
dW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3RhYnMnKTsNCiAgICAgICAgaWYgKCF0YWJzIHx8IHRhYnMu
X2lua0hvdmVyQm91bmQpIHJldHVybjsNCiAgICAgICAgdGFicy5faW5rSG92ZXJCb3VuZCA9IHRy
dWU7DQogICAgICAgIHRhYnMuYWRkRXZlbnRMaXN0ZW5lcigncG9pbnRlcm92ZXInLCBlID0+IHsN
CiAgICAgICAgICAgIGNvbnN0IHRhYiA9IGUudGFyZ2V0LmNsb3Nlc3QoJy50YWInKTsNCiAgICAg
ICAgICAgIGlmICghdGFiIHx8ICF0YWJzLmNvbnRhaW5zKHRhYikpIHJldHVybjsNCiAgICAgICAg
ICAgIG1vdmVUYWJJbmsoZmFsc2UsIHRhYik7DQogICAgICAgIH0pOw0KICAgICAgICB0YWJzLmFk
ZEV2ZW50TGlzdGVuZXIoJ3BvaW50ZXJsZWF2ZScsIGUgPT4gew0KICAgICAgICAgICAgaWYgKGUu
cmVsYXRlZFRhcmdldCAmJiB0YWJzLmNvbnRhaW5zKGUucmVsYXRlZFRhcmdldCkpIHJldHVybjsN
CiAgICAgICAgICAgIG1vdmVUYWJJbmsoZmFsc2UpOw0KICAgICAgICB9KTsNCiAgICB9DQpmdW5j
dGlvbiBzZXRUYWIodGFiKSB7DQogICAgICAgIGlmICh0YWIgPT09IGN1clRhYikgcmV0dXJuOw0K
ICAgICAgICBjb25zdCBmcm9tID0gdGFiSW5kZXgoY3VyVGFiKTsNCiAgICAgICAgY29uc3QgdG8g
PSB0YWJJbmRleCh0YWIpOw0KICAgICAgICB0YWJTd2l0Y2hBbmltRGlyID0gdG8gPiBmcm9tID8g
MSA6ICh0byA8IGZyb20gPyAtMSA6IDApOw0KICAgICAgICBjdXJUYWIgPSB0YWI7DQogICAgICAg
IGxvYWRpbmdNb3JlID0gZmFsc2U7DQogICAgICAgIG1hcmtUYWIodGFiKTsNCiAgICAgICAgdHJ5
IHsgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2FwcCcpLmRhdGFzZXQudGFiID0gdGFiOyB9IGNh
dGNoIHt9DQogICAgICAgIC8vIOaJk+W8gOaUtuiXj+W5tuafpeeci+WQju+8jOa4hemZpOOAjOaW
sOaUtuiXj+OAjee7v+eCuQ0KICAgICAgICBpZiAodGFiID09PSAncGlubmVkJykNCiAgICAgICAg
ICAgIGNsZWFyRmF2VW5zZWVuKCk7DQoNCiAgICAgICAgLy8gS2VlcCBzZWFyY2ggInRvZGF5IiBm
aWx0ZXIgaW4gc3luYyB3aGVuIHNlYXJjaCBpcyBvcGVuDQogICAgICAgIHRyeSB7DQogICAgICAg
ICAgICBjb25zdCB3cmFwID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NlYXJjaC13cmFwJyk7
DQogICAgICAgICAgICBjb25zdCBidG5Ub2RheSA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdi
dG4tdG9kYXknKTsNCiAgICAgICAgICAgIGlmICh3cmFwICYmIHdyYXAuY2xhc3NMaXN0LmNvbnRh
aW5zKCdvcGVuJykpIHsNCiAgICAgICAgICAgICAgICBjb25zdCB3YW50VG9kYXkgPSBmYWxzZTsN
CiAgICAgICAgICAgICAgICBpZiAodG9kYXlPbmx5ICE9PSB3YW50VG9kYXkpIHsNCiAgICAgICAg
ICAgICAgICAgICAgdG9kYXlPbmx5ID0gd2FudFRvZGF5Ow0KICAgICAgICAgICAgICAgICAgICBp
ZiAoYnRuVG9kYXkpIGJ0blRvZGF5LmNsYXNzTGlzdC50b2dnbGUoJ29uJywgdG9kYXlPbmx5KTsN
CiAgICAgICAgICAgICAgICB9DQogICAgICAgICAgICB9DQogICAgICAgIH0gY2F0Y2gge30NCg0K
ICAgICAgICBzZWxlY3RlZElkID0gbnVsbDsNCiAgICAgICAgbXVsdGlJZHMgPSBbXTsNCiAgICAg
ICAgbGlzdEVsLnNjcm9sbFRvcCA9IDA7DQogICAgICAgIGNvbnN0IGhpdCA9IHZpZXdNZW0uZ2V0
KHZpZXdNZW1LZXkodGFiLCBxdWVyeSwgdG9kYXlPbmx5KSk7DQogICAgICAgIGlmIChoaXQgJiYg
QXJyYXkuaXNBcnJheShoaXQuaXRlbXMpICYmIGhpdC5pdGVtcy5sZW5ndGgpIHsNCiAgICAgICAg
ICAgIGFsbENsaXBzID0gaGl0Lml0ZW1zLnNsaWNlKCk7DQogICAgICAgICAgICBkaXNrVG90YWwg
PSBOdW1iZXIoaGl0LnRvdGFsKSB8fCBoaXQuaXRlbXMubGVuZ3RoOw0KICAgICAgICAgICAgd2lu
ZG93Ll9fd2FpdGluZ1ZpZXcgPSBmYWxzZTsNCiAgICAgICAgICAgIGNsZWFyV2FpdGluZ0RhdGEo
KTsNCiAgICAgICAgICAgIHdpbmRvdy5fX2RhdGFSZWFkeSA9IHRydWU7DQogICAgICAgICAgICBo
b3N0UHVzaGVkT25jZSA9IHRydWU7DQogICAgICAgICAgICBzYXdOb25FbXB0eSA9IHRydWU7DQog
ICAgICAgICAgICByZW5kZXIoKTsNCiAgICAgICAgICAgIGFwcGx5VGFiU3dpdGNoQW5pbSgpOw0K
ICAgICAgICAgICAgLy8gTWVtb3J5IHBhaW50IGZpcnN0IOKAlGJhY2tncm91bmQgc29mdC1zeW5j
IGtlZXBzIEFISyBpbiBzdGVwIHdpdGhvdXQgZG91YmxlIHJlZHJhdw0KICAgICAgICAgICAgc29m
dFJlcXVlc3RWaWV3KCk7DQogICAgICAgICAgICByZXR1cm47DQogICAgICAgIH0NCiAgICAgICAg
Ly8gTm8gY2FjaGUgeWV0OiBrZWVwIGN1cnJlbnQgcm93cyDigJQgTkVWRVIgd2lwZSB0byBibGFu
ayB3aGl0ZQ0KICAgICAgICB3aW5kb3cuX193YWl0aW5nVmlldyA9IHRydWU7DQogICAgICAgIHNj
aGVkdWxlRGVsYXllZFNrZWwoKTsNCiAgICAgICAgaWYgKCFhbGxDbGlwcy5sZW5ndGgpDQogICAg
ICAgICAgICByZW5kZXIoKTsNCiAgICAgICAgcmVxdWVzdFZpZXcoKTsNCiAgICAgICAgYXBwbHlU
YWJTd2l0Y2hBbmltKCk7DQogICAgfQ0KDQogICAgbW92ZVRhYkluayh0cnVlKTsNCiAgICBiaW5k
VGFiSW5rSG92ZXIoKTsNCiAgICB0cnkgeyBuZXcgUmVzaXplT2JzZXJ2ZXIoKCkgPT4gbW92ZVRh
Ykluayh0cnVlKSkub2JzZXJ2ZShkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgndGFicycpKTsgfSBj
YXRjaCB7fQ0KICAgIHdpbmRvdy5hZGRFdmVudExpc3RlbmVyKCdyZXNpemUnLCAoKSA9PiBtb3Zl
VGFiSW5rKHRydWUpKTsNCg0KICAgIGZ1bmN0aW9uIHVwZGF0ZU1vcmVGb290ZXIodG90YWwpIHsN
CiAgICAgICAgbGV0IG1vcmVFbCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdsaXN0LW1vcmUn
KTsNCiAgICAgICAgY29uc3QgbG9hZGVkID0gYWxsQ2xpcHMubGVuZ3RoOw0KICAgICAgICBpZiAo
bG9hZGVkID49IHRvdGFsKSB7DQogICAgICAgICAgICBpZiAobW9yZUVsKSBtb3JlRWwucmVtb3Zl
KCk7DQogICAgICAgICAgICByZXR1cm47DQogICAgICAgIH0NCiAgICAgICAgaWYgKCFtb3JlRWwp
IHsNCiAgICAgICAgICAgIG1vcmVFbCA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOw0K
ICAgICAgICAgICAgbW9yZUVsLmlkID0gJ2xpc3QtbW9yZSc7DQogICAgICAgICAgICBtb3JlRWwu
Y2xhc3NOYW1lID0gJ2xpc3QtbW9yZSc7DQogICAgICAgICAgICBsaXN0RWwuYXBwZW5kQ2hpbGQo
bW9yZUVsKTsNCiAgICAgICAgfQ0KICAgICAgICBtb3JlRWwudGV4dENvbnRlbnQgPSAn57un57ut
5LiL5ruR5LuO56OB55uY5Yqg6L2977yIJyArIGxvYWRlZCArICcvJyArIHRvdGFsICsgJ++8iSc7
DQogICAgfQ0KDQogICAgLyoqIFVwZGF0ZSBiYXIgLyBwaW4gYmFkZ2Ugd2l0aG91dCB0b3VjaGlu
ZyB0aGUgbGlzdCBET00gKi8NCiAgICBmdW5jdGlvbiByZWZyZXNoTGlzdENocm9tZSgpIHsNCiAg
ICAgICAgY29uc3QgdmlzaWJsZSA9IHZpc2libGVMaXN0KCk7DQogICAgICAgIGNvbnN0IGxvYWRl
ZCA9IGFsbENsaXBzLmxlbmd0aDsNCiAgICAgICAgY29uc3Qgc2hvd25Db3VudCA9IHZpc2libGUu
bGVuZ3RoOw0KICAgICAgICBsZXQgcGlubmVkTiA9IE51bWJlcihwaW5uZWRUb3RhbCkgfHwgMDsN
CiAgICAgICAgaWYgKHBpbm5lZE4gPCAxKSB7DQogICAgICAgICAgICBpZiAoY3VyVGFiID09PSAn
cGlubmVkJykNCiAgICAgICAgICAgICAgICBwaW5uZWROID0gTWF0aC5tYXgoTnVtYmVyKGRpc2tU
b3RhbCkgfHwgMCwgbG9hZGVkKTsNCiAgICAgICAgICAgIGVsc2UNCiAgICAgICAgICAgICAgICBw
aW5uZWROID0gYWxsQ2xpcHMuZmlsdGVyKGMgPT4gaXNQaW5uZWQoYykpLmxlbmd0aDsNCiAgICAg
ICAgfQ0KICAgICAgICB1cGRhdGVQaW5Eb3QoKTsNCiAgICAgICAgbGV0IHNob3dUb3RhbCA9IGRp
c2tUb3RhbCA+IDAgPyBkaXNrVG90YWwgOiAobG9hZGVkIHx8IDApOw0KICAgICAgICBpZiAoY3Vy
VGFiID09PSAncGlubmVkJyAmJiBwaW5uZWROID4gc2hvd1RvdGFsKQ0KICAgICAgICAgICAgc2hv
d1RvdGFsID0gcGlubmVkTjsNCiAgICAgICAgY29uc3QgcU9uID0gU3RyaW5nKHF1ZXJ5IHx8ICcn
KS50cmltKCkubGVuZ3RoID4gMDsNCiAgICAgICAgY29uc3QgYmFyID0gZG9jdW1lbnQuZ2V0RWxl
bWVudEJ5SWQoJ2Jhci10eHQnKTsNCiAgICAgICAgaWYgKGJhcikgew0KICAgICAgICAgICAgYmFy
LnRleHRDb250ZW50ID0gcU9uDQogICAgICAgICAgICAgICAgPyAoc2hvd25Db3VudCArICcg5p2h
JykNCiAgICAgICAgICAgICAgICA6IChzaG93VG90YWwgPiBsb2FkZWQgPyAoc2hvd25Db3VudCAr
ICcgLyAnICsgc2hvd1RvdGFsICsgJyDmnaEnKSA6IChzaG93VG90YWwgKyAnIOadoScpKTsNCiAg
ICAgICAgfQ0KICAgICAgICB1cGRhdGVNb3JlRm9vdGVyKGRpc2tUb3RhbCk7DQogICAgICAgIHVw
ZGF0ZVRvcEJ0bigpOw0KICAgIH0NCg0KICAgIC8qKg0KICAgICAqIExvYWQtbW9yZTogYXBwZW5k
IG9ubHkgbmV3IERPTSBub2Rlcy4gRnVsbCByZW5kZXIoKSBudWtlcyBldmVyeSAuaXRtIGFuZA0K
ICAgICAqIHJlc3RvcmVzIHNjcm9sbFRvcCDigJQgdGhhdCBoaXRjaCBpcyB3aGF0IG1ha2VzIGRy
YWdnaW5nIHRoZSBzY3JvbGxiYXIgZmVlbCBzdGlja3kuDQogICAgICovDQogICAgZnVuY3Rpb24g
YXBwZW5kUmVuZGVyKHByZXZMZW4pIHsNCiAgICAgICAgY29uc3QgdmlzaWJsZSA9IHZpc2libGVM
aXN0KCk7DQogICAgICAgIGlmICghdmlzaWJsZS5sZW5ndGgpIHsNCiAgICAgICAgICAgIHJlbmRl
cigpOw0KICAgICAgICAgICAgcmV0dXJuIGZhbHNlOw0KICAgICAgICB9DQogICAgICAgIGlmIChw
cmV2TGVuID4gMCAmJiBwcmV2TGVuIDwgYWxsQ2xpcHMubGVuZ3RoKSB7DQogICAgICAgICAgICBj
b25zdCBzZWFtR2lkcyA9IG5ldyBTZXQoKTsNCiAgICAgICAgICAgIGZvciAobGV0IGkgPSBNYXRo
Lm1heCgwLCBwcmV2TGVuIC0gOCk7IGkgPCBNYXRoLm1pbihhbGxDbGlwcy5sZW5ndGgsIHByZXZM
ZW4gKyA4KTsgaSsrKSB7DQogICAgICAgICAgICAgICAgY29uc3QgZyA9IGZhdkdyb3VwT2YoYWxs
Q2xpcHNbaV0pOw0KICAgICAgICAgICAgICAgIGlmIChnKSBzZWFtR2lkcy5hZGQoZyk7DQogICAg
ICAgICAgICB9DQogICAgICAgICAgICBpZiAoc2VhbUdpZHMuc2l6ZSkgew0KICAgICAgICAgICAg
ICAgIGZvciAoY29uc3QgZyBvZiBzZWFtR2lkcykgew0KICAgICAgICAgICAgICAgICAgICBsZXQg
YmVmb3JlID0gMCwgYWZ0ZXIgPSAwOw0KICAgICAgICAgICAgICAgICAgICBmb3IgKGxldCBpID0g
MDsgaSA8IGFsbENsaXBzLmxlbmd0aDsgaSsrKSB7DQogICAgICAgICAgICAgICAgICAgICAgICBp
ZiAoZmF2R3JvdXBPZihhbGxDbGlwc1tpXSkgIT09IGcpIGNvbnRpbnVlOw0KICAgICAgICAgICAg
ICAgICAgICAgICAgaWYgKGkgPCBwcmV2TGVuKSBiZWZvcmUrKzsNCiAgICAgICAgICAgICAgICAg
ICAgICAgIGVsc2UgYWZ0ZXIrKzsNCiAgICAgICAgICAgICAgICAgICAgfQ0KICAgICAgICAgICAg
ICAgICAgICBpZiAoYmVmb3JlID4gMCAmJiBhZnRlciA+IDApIHsNCiAgICAgICAgICAgICAgICAg
ICAgICAgIHJlbmRlcigpOw0KICAgICAgICAgICAgICAgICAgICAgICAgcmV0dXJuIGZhbHNlOw0K
ICAgICAgICAgICAgICAgICAgICB9DQogICAgICAgICAgICAgICAgfQ0KICAgICAgICAgICAgfQ0K
ICAgICAgICB9DQogICAgICAgIGNvbnN0IGJsb2NrcyA9IGJ1aWxkUGlubmVkQmxvY2tzKHZpc2li
bGUpOw0KICAgICAgICBjb25zdCBleGlzdGluZyA9IGxpc3RFbC5xdWVyeVNlbGVjdG9yQWxsKCcu
aXRtJykubGVuZ3RoOw0KICAgICAgICBpZiAoZXhpc3RpbmcgPCAxKSB7DQogICAgICAgICAgICBy
ZW5kZXIoKTsNCiAgICAgICAgICAgIHJldHVybiBmYWxzZTsNCiAgICAgICAgfQ0KICAgICAgICBp
ZiAoYmxvY2tzLmxlbmd0aCA8PSBleGlzdGluZykgew0KICAgICAgICAgICAgcmVmcmVzaExpc3RD
aHJvbWUoKTsNCiAgICAgICAgICAgIHRyeSB7IG1hcmtRdWV1ZVJhaWxzKCk7IH0gY2F0Y2ggKGUp
IHt9DQogICAgICAgICAgICByZXR1cm4gdHJ1ZTsNCiAgICAgICAgfQ0KICAgICAgICBjb25zdCBm
cmFnID0gZG9jdW1lbnQuY3JlYXRlRG9jdW1lbnRGcmFnbWVudCgpOw0KICAgICAgICBsZXQgbnVt
ID0gMDsNCiAgICAgICAgYmxvY2tzLmZvckVhY2goYiA9PiB7DQogICAgICAgICAgICBudW0gKz0g
MTsNCiAgICAgICAgICAgIGlmIChudW0gPD0gZXhpc3RpbmcpIHJldHVybjsNCiAgICAgICAgICAg
IGlmIChiLmtpbmQgPT09ICdncm91cCcgJiYgYi5pdGVtcy5sZW5ndGggPiAxKQ0KICAgICAgICAg
ICAgICAgIGZyYWcuYXBwZW5kQ2hpbGQobWFrZUdyb3VwSXRlbShiLml0ZW1zLCBudW0pKTsNCiAg
ICAgICAgICAgIGVsc2UNCiAgICAgICAgICAgICAgICBmcmFnLmFwcGVuZENoaWxkKG1ha2VJdGVt
KGIuaXRlbXNbMF0sIG51bSkpOw0KICAgICAgICB9KTsNCiAgICAgICAgY29uc3QgbW9yZUVsID0g
ZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2xpc3QtbW9yZScpOw0KICAgICAgICBpZiAobW9yZUVs
KQ0KICAgICAgICAgICAgbGlzdEVsLmluc2VydEJlZm9yZShmcmFnLCBtb3JlRWwpOw0KICAgICAg
ICBlbHNlDQogICAgICAgICAgICBsaXN0RWwuYXBwZW5kQ2hpbGQoZnJhZyk7DQogICAgICAgIHRy
eSB7IG1hcmtRdWV1ZVJhaWxzKCk7IH0gY2F0Y2ggKGUpIHt9DQogICAgICAgIHJlZnJlc2hMaXN0
Q2hyb21lKCk7DQogICAgICAgIHJlcXVlc3RBbmltYXRpb25GcmFtZSgoKSA9PiB7DQogICAgICAg
ICAgICBpZiAoYWxsQ2xpcHMubGVuZ3RoIDwgZGlza1RvdGFsDQogICAgICAgICAgICAgICAgJiYg
bGlzdEVsLnNjcm9sbEhlaWdodCA8PSBsaXN0RWwuY2xpZW50SGVpZ2h0ICsgMjApDQogICAgICAg
ICAgICAgICAgcmVxdWVzdE1vcmUoKTsNCiAgICAgICAgICAgIHRyeSB7IHNjaGVkdWxlRmlsZUdv
bmVDaGVjaygpOyB9IGNhdGNoIHt9DQogICAgICAgIH0pOw0KICAgICAgICByZXR1cm4gdHJ1ZTsN
CiAgICB9DQoNCiAgICBmdW5jdGlvbiBhcHBseUFwcGVuZFBheWxvYWQocGVuZGluZykgew0KICAg
ICAgICBpZiAoIXBlbmRpbmcgfHwgcGVuZGluZy5mcm9tTGVuID09IG51bGwpIHJldHVybjsNCiAg
ICAgICAgY29uc3QgZnJvbUxlbiA9IE51bWJlcihwZW5kaW5nLmZyb21MZW4pIHx8IDA7DQogICAg
ICAgIGlmIChmcm9tTGVuIDwgMCB8fCBhbGxDbGlwcy5sZW5ndGggPD0gZnJvbUxlbikgew0KICAg
ICAgICAgICAgcmVmcmVzaExpc3RDaHJvbWUoKTsNCiAgICAgICAgICAgIHJldHVybjsNCiAgICAg
ICAgfQ0KICAgICAgICBhcHBlbmRSZW5kZXIoZnJvbUxlbik7DQogICAgfQ0KDQogICAgZnVuY3Rp
b24gbmF2TGlzdCgpIHsNCiAgICAgICAgY29uc3QgYmxvY2tzID0gYnVpbGRQaW5uZWRCbG9ja3Mo
dmlzaWJsZUxpc3QoKSk7DQogICAgICAgIGNvbnN0IG91dCA9IFtdOw0KICAgICAgICBmb3IgKGNv
bnN0IGIgb2YgYmxvY2tzKSB7DQogICAgICAgICAgICBpZiAoIWIgfHwgIWIuaXRlbXMpIGNvbnRp
bnVlOw0KICAgICAgICAgICAgZm9yIChjb25zdCBjIG9mIGIuaXRlbXMpIG91dC5wdXNoKGMpOw0K
ICAgICAgICB9DQogICAgICAgIHJldHVybiBvdXQ7DQogICAgfQ0KDQogICAgZnVuY3Rpb24gc2Vs
ZWN0QnlJbmRleChpZHgpIHsNCiAgICAgICAgY29uc3QgdmlzID0gbmF2TGlzdCgpOw0KICAgICAg
ICBpZiAoIXZpcy5sZW5ndGgpIHJldHVybjsNCiAgICAgICAgaWR4ID0gTWF0aC5tYXgoMCwgTWF0
aC5taW4odmlzLmxlbmd0aCAtIDEsIGlkeCkpOw0KICAgICAgICBpZiAoaWR4ID49IHZpcy5sZW5n
dGggLSAxICYmIGFsbENsaXBzLmxlbmd0aCA8IGRpc2tUb3RhbCkNCiAgICAgICAgICAgIHJlcXVl
c3RNb3JlKCk7DQogICAgICAgIHNlbGVjdGVkSWQgPSB2aXNbTWF0aC5taW4oaWR4LCB2aXMubGVu
Z3RoIC0gMSldLmlkOw0KICAgICAgICByYW5nZUFuY2hvcklkID0gc2VsZWN0ZWRJZDsNCiAgICAg
ICAgcmFuZ2VBbmNob3JDbGlja2VkID0gZmFsc2U7DQogICAgICAgIGlmICgrc2VsZWN0ZWRJZCAh
PT0gK2xhc3RQYXN0ZUlkKQ0KICAgICAgICAgICAgbG9jYXRlQWN0aXZlID0gZmFsc2U7DQogICAg
ICAgIHVwZGF0ZUxvY2F0ZUJ0bigpOw0KICAgICAgICBzeW5jSXRlbUhpZ2hsaWdodCgpOw0KICAg
ICAgICBjb25zdCBlbCA9IGxpc3RFbC5xdWVyeVNlbGVjdG9yKCcubWctcm93W2RhdGEtaWQ9Iicg
KyBzZWxlY3RlZElkICsgJyJdJykNCiAgICAgICAgICAgIHx8IGxpc3RFbC5xdWVyeVNlbGVjdG9y
KCcuaXRtW2RhdGEtaWQ9IicgKyBzZWxlY3RlZElkICsgJyJdJyk7DQogICAgICAgIGlmIChlbCkg
ZWwuc2Nyb2xsSW50b1ZpZXcoeyBibG9jazogJ25lYXJlc3QnIH0pOw0KICAgIH0NCg0KICAgIGZ1
bmN0aW9uIHNlbGVjdGVkSW5kZXgoKSB7DQogICAgICAgIHJldHVybiBuYXZMaXN0KCkuZmluZElu
ZGV4KGMgPT4gYy5pZCA9PSBzZWxlY3RlZElkKTsNCiAgICB9DQoNCiAgICBmdW5jdGlvbiBzeW5j
SXRlbUhpZ2hsaWdodCgpIHsNCiAgICAgICAgZG9jdW1lbnQucXVlcnlTZWxlY3RvckFsbCgnLml0
bScpLmZvckVhY2gobiA9PiB7DQogICAgICAgICAgICBpZiAobi5jbGFzc0xpc3QuY29udGFpbnMo
J2l0LWdyb3VwJykpIHsNCiAgICAgICAgICAgICAgICBjb25zdCByb3dzID0gWy4uLm4ucXVlcnlT
ZWxlY3RvckFsbCgnLm1nLXJvdycpXTsNCiAgICAgICAgICAgICAgICBjb25zdCBpZHMgPSByb3dz
Lm1hcChyID0+ICtyLmRhdGFzZXQuaWQpOw0KICAgICAgICAgICAgICAgIGNvbnN0IGFueVNlbCA9
IGlkcy5pbmNsdWRlcygrc2VsZWN0ZWRJZCkgfHwgaWRzLnNvbWUoaWQgPT4gbXVsdGlJZHMuaW5j
bHVkZXMoaWQpKTsNCiAgICAgICAgICAgICAgICBuLmNsYXNzTGlzdC50b2dnbGUoJ3NlbCcsIGFu
eVNlbCk7DQogICAgICAgICAgICAgICAgbi5jbGFzc0xpc3QudG9nZ2xlKCdtdWx0aScsIGlkcy5z
b21lKGlkID0+IG11bHRpSWRzLmluY2x1ZGVzKGlkKSkpOw0KICAgICAgICAgICAgICAgIHJvd3Mu
Zm9yRWFjaChyID0+IHsNCiAgICAgICAgICAgICAgICAgICAgY29uc3QgaWQgPSArci5kYXRhc2V0
LmlkOw0KICAgICAgICAgICAgICAgICAgICBjb25zdCBpbk11bHRpID0gbXVsdGlJZHMuaW5jbHVk
ZXMoaWQpOw0KICAgICAgICAgICAgICAgICAgICByLmNsYXNzTGlzdC50b2dnbGUoJ3NlbCcsIGlk
ID09IHNlbGVjdGVkSWQgfHwgaW5NdWx0aSk7DQogICAgICAgICAgICAgICAgICAgIHIuY2xhc3NM
aXN0LnRvZ2dsZSgnbXVsdGknLCBpbk11bHRpKTsNCiAgICAgICAgICAgICAgICB9KTsNCiAgICAg
ICAgICAgICAgICByZXR1cm47DQogICAgICAgICAgICB9DQogICAgICAgICAgICBjb25zdCBpZCA9
ICtuLmRhdGFzZXQuaWQ7DQogICAgICAgICAgICBjb25zdCBpbk11bHRpID0gbXVsdGlJZHMuaW5j
bHVkZXMoaWQpOw0KICAgICAgICAgICAgbi5jbGFzc0xpc3QudG9nZ2xlKCdzZWwnLCBpZCA9PSBz
ZWxlY3RlZElkIHx8IGluTXVsdGkpOw0KICAgICAgICAgICAgbi5jbGFzc0xpc3QudG9nZ2xlKCdt
dWx0aScsIGluTXVsdGkpOw0KICAgICAgICB9KTsNCiAgICB9DQogICAgZnVuY3Rpb24gdXBkYXRl
TXVsdGlCYWRnZSgpIHsNCiAgICAgICAgY29uc3QgYmFyID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5
SWQoJ211bHRpLWJhcicpOw0KICAgICAgICBjb25zdCBlbCA9IGRvY3VtZW50LmdldEVsZW1lbnRC
eUlkKCdtdWx0aS1jbnQnKTsNCiAgICAgICAgaWYgKG11bHRpSWRzLmxlbmd0aCA+IDApIHsNCiAg
ICAgICAgICAgIGlmIChlbCkgZWwudGV4dENvbnRlbnQgPSBTdHJpbmcobXVsdGlJZHMubGVuZ3Ro
KTsNCiAgICAgICAgICAgIGlmIChiYXIpIHsNCiAgICAgICAgICAgICAgICBjb25zdCB3YXNPZmYg
PSAhYmFyLmNsYXNzTGlzdC5jb250YWlucygnb24nKTsNCiAgICAgICAgICAgICAgICBiYXIuY2xh
c3NMaXN0LmFkZCgnb24nKTsNCiAgICAgICAgICAgICAgICBpZiAod2FzT2ZmKSByZXNldFBhc3Rl
U2VwRGVmYXVsdCgpOw0KICAgICAgICAgICAgfQ0KICAgICAgICB9IGVsc2Ugew0KICAgICAgICAg
ICAgaWYgKGJhcikgYmFyLmNsYXNzTGlzdC5yZW1vdmUoJ29uJyk7DQogICAgICAgICAgICBjbG9z
ZVNlcE1lbnUoKTsNCiAgICAgICAgfQ0KICAgICAgICBzeW5jSXRlbUhpZ2hsaWdodCgpOw0KICAg
IH0NCg0KICAgIGNvbnN0IFNFUF9ORVdMSU5FX1RPS0VOID0gJ1vmjaLooYxdJzsNCiAgICAvLyDl
m7rlrprluLjnlKjliIbpmpTnrKbvvJvoh6rlrprkuYnkuI3ov5vliJfooagNCiAgICBjb25zdCBT
RVBfTElTVCA9IFsnICcsIFNFUF9ORVdMSU5FX1RPS0VOLCAnLCcsICcsICcsICfjgIEnLCAnfCcs
ICdbIiIsIiJdJywgIignJywnJykiXTsNCiAgICBsZXQgcGFzdGVTZXBWYWx1ZSA9ICcgJzsNCg0K
ICAgIGZ1bmN0aW9uIG5vcm1hbGl6ZVNlcElucHV0KHJhdykgew0KICAgICAgICBsZXQgcyA9IFN0
cmluZyhyYXcgPz8gJycpOw0KICAgICAgICBpZiAocyA9PT0gJycpIHJldHVybiAnICc7DQogICAg
ICAgIGNvbnN0IHQgPSBzLnRyaW0oKTsNCiAgICAgICAgaWYgKHQgPT09IFNFUF9ORVdMSU5FX1RP
S0VOIHx8IHQgPT09ICfmjaLooYwnIHx8IHQgPT09ICdcXG4nIHx8IHQgPT09ICdcbicgfHwgdCA9
PT0gJ1xyXG4nKQ0KICAgICAgICAgICAgcmV0dXJuIFNFUF9ORVdMSU5FX1RPS0VOOw0KICAgICAg
ICBpZiAodCA9PT0gJ1xcdCcgfHwgdCA9PT0gJ1x0JykgcmV0dXJuICdcdCc7DQogICAgICAgIHJl
dHVybiBzOw0KICAgIH0NCiAgICBmdW5jdGlvbiBzZXBUb0FjdHVhbChyYXcpIHsNCiAgICAgICAg
Y29uc3QgcyA9IG5vcm1hbGl6ZVNlcElucHV0KHJhdyk7DQogICAgICAgIHJldHVybiBzID09PSBT
RVBfTkVXTElORV9UT0tFTiA/ICdcbicgOiBzOw0KICAgIH0NCiAgICBmdW5jdGlvbiBzZXBUb0Jy
aWRnZShyYXcpIHsNCiAgICAgICAgY29uc3QgcyA9IG5vcm1hbGl6ZVNlcElucHV0KHJhdyk7DQog
ICAgICAgIGlmIChzID09PSBTRVBfTkVXTElORV9UT0tFTiB8fCBzID09PSAnXG4nIHx8IHMgPT09
ICdcclxuJykgcmV0dXJuIFNFUF9ORVdMSU5FX1RPS0VOOw0KICAgICAgICBpZiAocyA9PT0gJ1x0
JykgcmV0dXJuICdb5Yi26KGo56ymXSc7DQogICAgICAgIHJldHVybiBzOw0KICAgIH0NCiAgICBm
dW5jdGlvbiBzZXBEaXNwbGF5U3ltYm9sKHJhdykgew0KICAgICAgICBjb25zdCBzID0gbm9ybWFs
aXplU2VwSW5wdXQocmF3KTsNCiAgICAgICAgaWYgKHMgPT09ICcgJykgcmV0dXJuICfikKMnOw0K
ICAgICAgICBpZiAocyA9PT0gU0VQX05FV0xJTkVfVE9LRU4gfHwgcyA9PT0gJ1xuJyB8fCBzID09
PSAnXHJcbicpIHJldHVybiAn4oa1JzsNCiAgICAgICAgaWYgKHMgPT09ICdcdCcpIHJldHVybiAn
4oelJzsNCiAgICAgICAgaWYgKHMgPT09ICcsJykgcmV0dXJuICcsJzsNCiAgICAgICAgaWYgKHMg
PT09ICcsICcpIHJldHVybiAnLOKQoyc7DQogICAgICAgIGlmIChzID09PSAn44CBJykgcmV0dXJu
ICfjgIEnOw0KICAgICAgICBpZiAocyA9PT0gJ3wnKSByZXR1cm4gJ3wnOw0KICAgICAgICBpZiAo
cyA9PT0gJ1siIiwiIl0nKSByZXR1cm4gJ1siIiwiIl0nOw0KICAgICAgICBpZiAocyA9PT0gIign
JywnJykiKSByZXR1cm4gIignJywnJykiOw0KICAgICAgICByZXR1cm4gcy5yZXBsYWNlKC9cclxu
L2csICfihrUnKS5yZXBsYWNlKC9cbi9nLCAn4oa1JykucmVwbGFjZSgvXHQvZywgJ+KHpScpLnJl
cGxhY2UoL1xyL2csICcnKTsNCiAgICB9DQogICAgZnVuY3Rpb24gc2VwRGlzcGxheU5hbWUocmF3
KSB7DQogICAgICAgIGNvbnN0IHMgPSBub3JtYWxpemVTZXBJbnB1dChyYXcpOw0KICAgICAgICBp
ZiAocyA9PT0gJyAnKSByZXR1cm4gJ+epuuagvCc7DQogICAgICAgIGlmIChzID09PSBTRVBfTkVX
TElORV9UT0tFTiB8fCBzID09PSAnXG4nIHx8IHMgPT09ICdcclxuJykgcmV0dXJuICfmjaLooYwn
Ow0KICAgICAgICBpZiAocyA9PT0gJ1x0JykgcmV0dXJuICfliLbooajnrKYnOw0KICAgICAgICBp
ZiAocyA9PT0gJywnKSByZXR1cm4gJ+mAl+WPtyc7DQogICAgICAgIGlmIChzID09PSAnLCAnKSBy
ZXR1cm4gJ+mAl+WPt+epuuagvCc7DQogICAgICAgIGlmIChzID09PSAn44CBJykgcmV0dXJuICfp
ob/lj7cnOw0KICAgICAgICBpZiAocyA9PT0gJ3wnKSByZXR1cm4gJ+erlue6vyc7DQogICAgICAg
IGlmIChzID09PSAnWyIiLCIiXScpIHJldHVybiAn5YiX6KGoMSc7DQogICAgICAgIGlmIChzID09
PSAiKCcnLCcnKSIpIHJldHVybiAn5YiX6KGoMic7DQogICAgICAgIHJldHVybiAnJzsNCiAgICB9
DQogICAgZnVuY3Rpb24gZmlsbFNlcE1lbnVJdGVtKGJ0biwgdikgew0KICAgICAgICBidG4uaW5u
ZXJIVE1MID0gJyc7DQogICAgICAgIGNvbnN0IHN5bSA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQo
J3NwYW4nKTsNCiAgICAgICAgc3ltLmNsYXNzTmFtZSA9ICdwYXN0ZS1zZXAtc3ltJyArIChzZXBE
aXNwbGF5TmFtZSh2KSA/ICcnIDogJyBvbmx5Jyk7DQogICAgICAgIHN5bS50ZXh0Q29udGVudCA9
IHNlcERpc3BsYXlTeW1ib2wodik7DQogICAgICAgIGJ0bi5hcHBlbmRDaGlsZChzeW0pOw0KICAg
ICAgICBjb25zdCBuYW1lID0gc2VwRGlzcGxheU5hbWUodik7DQogICAgICAgIGlmIChuYW1lKSB7
DQogICAgICAgICAgICBjb25zdCBsYWIgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdzcGFuJyk7
DQogICAgICAgICAgICBsYWIuY2xhc3NOYW1lID0gJ3Bhc3RlLXNlcC1uYW1lJzsNCiAgICAgICAg
ICAgIGxhYi50ZXh0Q29udGVudCA9IG5hbWU7DQogICAgICAgICAgICBidG4uYXBwZW5kQ2hpbGQo
bGFiKTsNCiAgICAgICAgfQ0KICAgIH0NCiAgICBmdW5jdGlvbiB1cGRhdGVTZXBMYWJlbCgpIHsN
CiAgICAgICAgY29uc3QgbGFiID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3Bhc3RlLXNlcC1s
YWJlbCcpOw0KICAgICAgICBpZiAobGFiKSBsYWIudGV4dENvbnRlbnQgPSBzZXBEaXNwbGF5U3lt
Ym9sKHBhc3RlU2VwVmFsdWUpOw0KICAgIH0NCiAgICBmdW5jdGlvbiBhcHBseVNlcGFyYXRvcihy
YXcsIG9wdHMgPSB7fSkgew0KICAgICAgICBjb25zdCBkb1Bhc3RlID0gb3B0cy5wYXN0ZSAhPSBu
dWxsID8gb3B0cy5wYXN0ZSA6IG11bHRpSWRzLmxlbmd0aCA+IDA7DQogICAgICAgIHBhc3RlU2Vw
VmFsdWUgPSBub3JtYWxpemVTZXBJbnB1dChyYXcpOw0KICAgICAgICB1cGRhdGVTZXBMYWJlbCgp
Ow0KICAgICAgICBjbG9zZVNlcE1lbnUoKTsNCiAgICAgICAgaWYgKGRvUGFzdGUpIHBhc3RlTXVs
dGlTZWxlY3Rpb24oKTsNCiAgICB9DQogICAgZnVuY3Rpb24gY2xvc2VTZXBNZW51KCkgew0KICAg
ICAgICBjb25zdCBtZW51ID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3Bhc3RlLXNlcC1tZW51
Jyk7DQogICAgICAgIGNvbnN0IGJ0biA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdwYXN0ZS1z
ZXAtYnRuJyk7DQogICAgICAgIGlmIChtZW51KSBtZW51LmNsYXNzTGlzdC5yZW1vdmUoJ29uJyk7
DQogICAgICAgIGlmIChidG4pIGJ0bi5jbGFzc0xpc3QucmVtb3ZlKCdvcGVuJyk7DQogICAgfQ0K
ICAgIGZ1bmN0aW9uIHJlbmRlclNlcE1lbnUoKSB7DQogICAgICAgIGNvbnN0IG1lbnUgPSBkb2N1
bWVudC5nZXRFbGVtZW50QnlJZCgncGFzdGUtc2VwLW1lbnUnKTsNCiAgICAgICAgaWYgKCFtZW51
KSByZXR1cm47DQogICAgICAgIG1lbnUuaW5uZXJIVE1MID0gJyc7DQogICAgICAgIGZvciAoY29u
c3QgdiBvZiBTRVBfTElTVCkgew0KICAgICAgICAgICAgY29uc3QgYiA9IGRvY3VtZW50LmNyZWF0
ZUVsZW1lbnQoJ2J1dHRvbicpOw0KICAgICAgICAgICAgYi50eXBlID0gJ2J1dHRvbic7DQogICAg
ICAgICAgICBiLmNsYXNzTmFtZSA9ICdwYXN0ZS1zZXAtaXRlbScgKyAodiA9PT0gcGFzdGVTZXBW
YWx1ZSA/ICcgc2VsJyA6ICcnKTsNCiAgICAgICAgICAgIGZpbGxTZXBNZW51SXRlbShiLCB2KTsN
CiAgICAgICAgICAgIGIub25jbGljayA9IGUgPT4gew0KICAgICAgICAgICAgICAgIGUuc3RvcFBy
b3BhZ2F0aW9uKCk7DQogICAgICAgICAgICAgICAgYXBwbHlTZXBhcmF0b3Iodik7DQogICAgICAg
ICAgICB9Ow0KICAgICAgICAgICAgbWVudS5hcHBlbmRDaGlsZChiKTsNCiAgICAgICAgfQ0KICAg
ICAgICBjb25zdCBmb290ID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnZGl2Jyk7DQogICAgICAg
IGZvb3QuY2xhc3NOYW1lID0gJ3Bhc3RlLXNlcC1mb290JzsNCiAgICAgICAgY29uc3QgaW5wID0g
ZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnaW5wdXQnKTsNCiAgICAgICAgaW5wLmlkID0gJ3Bhc3Rl
LXNlcC1jdXN0b20nOw0KICAgICAgICBpbnAudHlwZSA9ICd0ZXh0JzsNCiAgICAgICAgaW5wLnNp
emUgPSAxOw0KICAgICAgICBpbnAucGxhY2Vob2xkZXIgPSAn6Ieq5a6a5LmJJzsNCiAgICAgICAg
aW5wLmF1dG9jb21wbGV0ZSA9ICdvZmYnOw0KICAgICAgICBpbnAuc3BlbGxjaGVjayA9IGZhbHNl
Ow0KICAgICAgICBpbnAudmFsdWUgPSBTRVBfTElTVC5pbmNsdWRlcyhwYXN0ZVNlcFZhbHVlKSA/
ICcnIDogcGFzdGVTZXBWYWx1ZTsNCiAgICAgICAgaW5wLm9ubW91c2Vkb3duID0gZSA9PiB7DQog
ICAgICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOw0KICAgICAgICAgICAgZS5wcmV2ZW50RGVm
YXVsdCgpOw0KICAgICAgICAgICAgdHJ5IHsgYWhrKCdmb2N1c1BhbmVsJyk7IH0gY2F0Y2gge30N
CiAgICAgICAgICAgIGlucC5mb2N1cygpOw0KICAgICAgICB9Ow0KICAgICAgICBpbnAub25jbGlj
ayA9IGUgPT4gZS5zdG9wUHJvcGFnYXRpb24oKTsNCiAgICAgICAgaW5wLm9uZm9jdXMgPSAoKSA9
PiB7IHRyeSB7IGFoaygnZm9jdXNQYW5lbCcpOyB9IGNhdGNoIHt9IH07DQogICAgICAgIGlucC5v
bmlucHV0ID0gZSA9PiBlLnN0b3BQcm9wYWdhdGlvbigpOw0KICAgICAgICBpbnAub25rZXlkb3du
ID0gZSA9PiB7DQogICAgICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOw0KICAgICAgICAgICAg
aWYgKGUua2V5ID09PSAnRW50ZXInKSB7DQogICAgICAgICAgICAgICAgZS5wcmV2ZW50RGVmYXVs
dCgpOw0KICAgICAgICAgICAgICAgIGlmIChpbnAudmFsdWUgIT09ICcnKSBhcHBseVNlcGFyYXRv
cihpbnAudmFsdWUpOw0KICAgICAgICAgICAgICAgIGVsc2UgY2xvc2VTZXBNZW51KCk7DQogICAg
ICAgICAgICB9IGVsc2UgaWYgKGUua2V5ID09PSAnRXNjYXBlJykgew0KICAgICAgICAgICAgICAg
IGUucHJldmVudERlZmF1bHQoKTsNCiAgICAgICAgICAgICAgICBjbG9zZVNlcE1lbnUoKTsNCiAg
ICAgICAgICAgIH0NCiAgICAgICAgfTsNCiAgICAgICAgZm9vdC5hcHBlbmRDaGlsZChpbnApOw0K
ICAgICAgICBtZW51LmFwcGVuZENoaWxkKGZvb3QpOw0KICAgIH0NCiAgICBmdW5jdGlvbiByZXNl
dFBhc3RlU2VwRGVmYXVsdCgpIHsNCiAgICAgICAgcGFzdGVTZXBWYWx1ZSA9ICcgJzsNCiAgICAg
ICAgdXBkYXRlU2VwTGFiZWwoKTsNCiAgICAgICAgY2xvc2VTZXBNZW51KCk7DQogICAgfQ0KICAg
IGZ1bmN0aW9uIHBhc3RlTWFueVdpdGhTZXAoaWRzKSB7DQogICAgICAgIGFoaygncGFzdGVNYW55
JywgaWRzLmpvaW4oJywnKSwgc2VwVG9CcmlkZ2UocGFzdGVTZXBWYWx1ZSkpOw0KICAgIH0NCiAg
ICBmdW5jdGlvbiBwYXN0ZU11bHRpU2VsZWN0aW9uKCkgew0KICAgICAgICBpZiAoIW11bHRpSWRz
Lmxlbmd0aCkgcmV0dXJuOw0KICAgICAgICBjb25zdCBpZHMgPSBtdWx0aUlkcy5zbGljZSgpOw0K
ICAgICAgICBjbGVhck11bHRpKCk7DQogICAgICAgIGlmIChpZHMuc29tZShpZCA9PiB7DQogICAg
ICAgICAgICBjb25zdCBpdCA9IGFsbENsaXBzLmZpbmQoeCA9PiAreC5pZCA9PT0gK2lkKTsNCiAg
ICAgICAgICAgIHJldHVybiBpdCAmJiBub3JtVHlwZShpdC50eXBlKSA9PT0gJ3JlY2VudCc7DQog
ICAgICAgIH0pKSB7DQogICAgICAgICAgICBjb25zdCBmaXJzdCA9IGFsbENsaXBzLmZpbmQoeCA9
PiAreC5pZCA9PT0gK2lkc1swXSk7DQogICAgICAgICAgICBpZiAoZmlyc3QpIGFjdGl2YXRlQ2xp
cEl0ZW0oZmlyc3QpOw0KICAgICAgICAgICAgcmV0dXJuOw0KICAgICAgICB9DQogICAgICAgIG1h
cmtQYXN0ZWRMb2NhbChpZHMpOw0KICAgICAgICBwYXN0ZU1hbnlXaXRoU2VwKGlkcyk7DQogICAg
fQ0KICAgIGZ1bmN0aW9uIGluaXRTZXBVaSgpIHsNCiAgICAgICAgdXBkYXRlU2VwTGFiZWwoKTsN
CiAgICAgICAgY29uc3QgYnRuID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3Bhc3RlLXNlcC1i
dG4nKTsNCiAgICAgICAgaWYgKGJ0bikgew0KICAgICAgICAgICAgYnRuLmFkZEV2ZW50TGlzdGVu
ZXIoJ2NsaWNrJywgZSA9PiB7DQogICAgICAgICAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsN
CiAgICAgICAgICAgICAgICBjb25zdCBtZW51ID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3Bh
c3RlLXNlcC1tZW51Jyk7DQogICAgICAgICAgICAgICAgY29uc3Qgb3BlbiA9IG1lbnUgJiYgbWVu
dS5jbGFzc0xpc3QuY29udGFpbnMoJ29uJyk7DQogICAgICAgICAgICAgICAgaWYgKG9wZW4pIHsN
CiAgICAgICAgICAgICAgICAgICAgY29uc3QgaW5wID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQo
J3Bhc3RlLXNlcC1jdXN0b20nKTsNCiAgICAgICAgICAgICAgICAgICAgaWYgKGlucCAmJiBpbnAu
dmFsdWUgIT09ICcnKSBhcHBseVNlcGFyYXRvcihpbnAudmFsdWUsIHsgcGFzdGU6IG11bHRpSWRz
Lmxlbmd0aCA+IDAgfSk7DQogICAgICAgICAgICAgICAgICAgIGVsc2UgY2xvc2VTZXBNZW51KCk7
DQogICAgICAgICAgICAgICAgICAgIHJldHVybjsNCiAgICAgICAgICAgICAgICB9DQogICAgICAg
ICAgICAgICAgcmVuZGVyU2VwTWVudSgpOw0KICAgICAgICAgICAgICAgIG1lbnUuY2xhc3NMaXN0
LmFkZCgnb24nKTsNCiAgICAgICAgICAgICAgICBidG4uY2xhc3NMaXN0LmFkZCgnb3BlbicpOw0K
ICAgICAgICAgICAgfSk7DQogICAgICAgIH0NCiAgICAgICAgZG9jdW1lbnQuYWRkRXZlbnRMaXN0
ZW5lcignbW91c2Vkb3duJywgZSA9PiB7DQogICAgICAgICAgICBpZiAoZS50YXJnZXQuY2xvc2Vz
dCgnI3Bhc3RlLXNlcC13cmFwJykpIHJldHVybjsNCiAgICAgICAgICAgIGNvbnN0IG1lbnUgPSBk
b2N1bWVudC5nZXRFbGVtZW50QnlJZCgncGFzdGUtc2VwLW1lbnUnKTsNCiAgICAgICAgICAgIGlm
ICghbWVudSB8fCAhbWVudS5jbGFzc0xpc3QuY29udGFpbnMoJ29uJykpIHJldHVybjsNCiAgICAg
ICAgICAgIGNvbnN0IGlucCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdwYXN0ZS1zZXAtY3Vz
dG9tJyk7DQogICAgICAgICAgICBpZiAoaW5wICYmIGlucC52YWx1ZSAhPT0gJycpIHsNCiAgICAg
ICAgICAgICAgICBhcHBseVNlcGFyYXRvcihpbnAudmFsdWUpOw0KICAgICAgICAgICAgICAgIHJl
dHVybjsNCiAgICAgICAgICAgIH0NCiAgICAgICAgICAgIGNsb3NlU2VwTWVudSgpOw0KICAgICAg
ICB9LCB0cnVlKTsNCiAgICB9DQoNCiAgICBmdW5jdGlvbiBjbGVhck11bHRpKHJlc3RvcmVUb0Fu
Y2hvcikgew0KICAgICAgICBjb25zdCBiYWNrSWQgPSArcmFuZ2VBbmNob3JJZCB8fCAwOw0KICAg
ICAgICBtdWx0aUlkcyA9IFtdOw0KICAgICAgICBpZiAocmVzdG9yZVRvQW5jaG9yICYmIGJhY2tJ
ZCkNCiAgICAgICAgICAgIHNlbGVjdGVkSWQgPSBiYWNrSWQ7DQogICAgICAgIHJhbmdlQW5jaG9y
SWQgPSBzZWxlY3RlZElkIHx8IDA7DQogICAgICAgIHJhbmdlQW5jaG9yQ2xpY2tlZCA9IGZhbHNl
Ow0KICAgICAgICB1cGRhdGVNdWx0aUJhZGdlKCk7DQogICAgICAgIGlmIChyZXN0b3JlVG9BbmNo
b3IgJiYgc2VsZWN0ZWRJZCkgew0KICAgICAgICAgICAgY29uc3QgZWwgPSBsaXN0RWwucXVlcnlT
ZWxlY3RvcignLm1nLXJvd1tkYXRhLWlkPSInICsgc2VsZWN0ZWRJZCArICciXScpDQogICAgICAg
ICAgICAgICAgfHwgbGlzdEVsLnF1ZXJ5U2VsZWN0b3IoJy5pdG1bZGF0YS1pZD0iJyArIHNlbGVj
dGVkSWQgKyAnIl0nKTsNCiAgICAgICAgICAgIGlmIChlbCkgZWwuc2Nyb2xsSW50b1ZpZXcoeyBi
bG9jazogJ25lYXJlc3QnIH0pOw0KICAgICAgICB9DQogICAgfQ0KDQoNCiAgICAvKiBzaGlmdC9j
dHJsIG11bHRpLXNlbGVjdDoNCiAgICAgKiBTaGlmdO+8muaciemAieWMuuaXtuS7peOAjOacgOS4
ii/mnIDkuIvjgI3kuLrplJrvvIzkuI3ot5/pvKDmoIfkuIrmrKHngrnlh7votbANCiAgICAgKiAg
IC0g54K55Zyo6YCJ5Yy65LiL5pa5IOKGkiDku47kuIrpgInliLDlvZPliY0NCiAgICAgKiAgIC0g
54K55Zyo6YCJ5Yy65LiK5pa5IOKGkiDku47lvZPliY3liLDkuIvpgIkNCiAgICAgKiAgIC0g54K5
5Zyo6YCJ5Yy66Leo5bqm5YaFIOKGkiDloavmu6HmnIDkuIrliLDmnIDkuIvvvIjlkKvpnZ7ov57n
u63nqbrmtJ7vvIkNCiAgICAgKiBDdHJs77ya6aaW5qyh54K55Lu75oSP6aG577yI5ZCr6buY6K6k
6auY5Lqu77yJ6L+b5YWl5aSa6YCJ5bm26YCJ5Lit77yb5YaN54K55bey6YCJ6aG55Y+W5raI44CB
5pyq6YCJ6aG55Yqg5YWlDQogICAgICovDQogICAgbGV0IHJhbmdlQW5jaG9ySWQgPSAwOw0KICAg
IGxldCByYW5nZUFuY2hvckNsaWNrZWQgPSBmYWxzZTsNCiAgICBmdW5jdGlvbiBzZWxlY3RlZElu
ZGljZXNJbkxpc3QobGlzdCkgew0KICAgICAgICBjb25zdCBzZXQgPSBuZXcgU2V0KChtdWx0aUlk
cyB8fCBbXSkubWFwKE51bWJlcikuZmlsdGVyKEJvb2xlYW4pKTsNCiAgICAgICAgaWYgKCtzZWxl
Y3RlZElkKSBzZXQuYWRkKCtzZWxlY3RlZElkKTsNCiAgICAgICAgY29uc3QgaWR4cyA9IFtdOw0K
ICAgICAgICBsaXN0LmZvckVhY2goKGMsIGkpID0+IHsNCiAgICAgICAgICAgIGlmIChzZXQuaGFz
KCtjLmlkKSkgaWR4cy5wdXNoKGkpOw0KICAgICAgICB9KTsNCiAgICAgICAgcmV0dXJuIGlkeHM7
DQogICAgfQ0KICAgIGZ1bmN0aW9uIHNlbGVjdFJhbmdlVG8oaWQpIHsNCiAgICAgICAgaWQgPSAr
aWQ7DQogICAgICAgIGNvbnN0IGxpc3QgPSAodHlwZW9mIG5hdkxpc3QgPT09ICdmdW5jdGlvbicg
PyBuYXZMaXN0KCkgOiB2aXNpYmxlTGlzdCgpKTsNCiAgICAgICAgY29uc3QgYiA9IGxpc3QuZmlu
ZEluZGV4KGMgPT4gK2MuaWQgPT09IGlkKTsNCiAgICAgICAgaWYgKGIgPCAwKSByZXR1cm47DQog
ICAgICAgIGNvbnN0IGlkeHMgPSBzZWxlY3RlZEluZGljZXNJbkxpc3QobGlzdCk7DQogICAgICAg
IGxldCBsbywgaGk7DQogICAgICAgIGlmICghaWR4cy5sZW5ndGgpIHsNCiAgICAgICAgICAgIGxv
ID0gaGkgPSBiOw0KICAgICAgICB9IGVsc2Ugew0KICAgICAgICAgICAgY29uc3QgdG9wID0gTWF0
aC5taW4oLi4uaWR4cyk7DQogICAgICAgICAgICBjb25zdCBib3QgPSBNYXRoLm1heCguLi5pZHhz
KTsNCiAgICAgICAgICAgIGlmIChiID4gYm90KSB7DQogICAgICAgICAgICAgICAgLy8g6YCJ5Yy6
5LiL5pa577ya5pyA5LiKIOKGkiDlvZPliY0NCiAgICAgICAgICAgICAgICBsbyA9IHRvcDsNCiAg
ICAgICAgICAgICAgICBoaSA9IGI7DQogICAgICAgICAgICB9IGVsc2UgaWYgKGIgPCB0b3ApIHsN
CiAgICAgICAgICAgICAgICAvLyDpgInljLrkuIrmlrnvvJrlvZPliY0g4oaSIOacgOS4iw0KICAg
ICAgICAgICAgICAgIGxvID0gYjsNCiAgICAgICAgICAgICAgICBoaSA9IGJvdDsNCiAgICAgICAg
ICAgIH0gZWxzZSB7DQogICAgICAgICAgICAgICAgLy8g5Zyo6Leo5bqm5YaF77yI5ZCr6Z2e6L+e
57ut56m65rSe77yJ77ya5pW05q615pyA5LiK4oaS5pyA5LiLDQogICAgICAgICAgICAgICAgbG8g
PSB0b3A7DQogICAgICAgICAgICAgICAgaGkgPSBib3Q7DQogICAgICAgICAgICB9DQogICAgICAg
IH0NCiAgICAgICAgbXVsdGlJZHMgPSBbXTsNCiAgICAgICAgZm9yIChsZXQgaSA9IGxvOyBpIDw9
IGhpOyBpKyspDQogICAgICAgICAgICBtdWx0aUlkcy5wdXNoKCtsaXN0W2ldLmlkKTsNCiAgICAg
ICAgc2VsZWN0ZWRJZCA9IGlkOw0KICAgICAgICAvLyDkuI3lho3miorpvKDmoIfngrnlh7vlvZPm
iJDkuIvkuIDmrKEgU2hpZnQg6ZSa54K5DQogICAgICAgIHJhbmdlQW5jaG9ySWQgPSArbGlzdFts
b10uaWQ7DQogICAgICAgIHJhbmdlQW5jaG9yQ2xpY2tlZCA9IHRydWU7DQogICAgICAgIHVwZGF0
ZU11bHRpQmFkZ2UoKTsNCiAgICAgICAgY29uc3QgZWwgPSBsaXN0RWwucXVlcnlTZWxlY3Rvcign
Lm1nLXJvd1tkYXRhLWlkPSInICsgc2VsZWN0ZWRJZCArICciXScpDQogICAgICAgICAgICB8fCBs
aXN0RWwucXVlcnlTZWxlY3RvcignLml0bVtkYXRhLWlkPSInICsgc2VsZWN0ZWRJZCArICciXScp
Ow0KICAgICAgICBpZiAoZWwpIGVsLnNjcm9sbEludG9WaWV3KHsgYmxvY2s6ICduZWFyZXN0JyB9
KTsNCiAgICB9DQogICAgZnVuY3Rpb24gaGFuZGxlSXRlbUNsaWNrKGUsIGMpIHsNCiAgICAgICAg
aWYgKGUuc2hpZnRLZXkpIHsNCiAgICAgICAgICAgIGUucHJldmVudERlZmF1bHQoKTsgZS5zdG9w
UHJvcGFnYXRpb24oKTsNCiAgICAgICAgICAgIHNlbGVjdFJhbmdlVG8oYy5pZCk7DQogICAgICAg
ICAgICByZXR1cm4gdHJ1ZTsNCiAgICAgICAgfQ0KICAgICAgICBpZiAoZS5jdHJsS2V5IHx8IGUu
bWV0YUtleSkgew0KICAgICAgICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOyBlLnN0b3BQcm9wYWdh
dGlvbigpOw0KICAgICAgICAgICAgdG9nZ2xlTXVsdGkoYy5pZCk7DQogICAgICAgICAgICByZXR1
cm4gdHJ1ZTsNCiAgICAgICAgfQ0KICAgICAgICByYW5nZUFuY2hvcklkID0gYy5pZDsNCiAgICAg
ICAgcmFuZ2VBbmNob3JDbGlja2VkID0gdHJ1ZTsNCiAgICAgICAgcmV0dXJuIGZhbHNlOw0KICAg
IH0NCiAgICBmdW5jdGlvbiB0b2dnbGVNdWx0aShpZCkgew0KICAgICAgICBpZCA9ICtpZDsNCiAg
ICAgICAgLy8g6aaW5qyhIEN0cmzvvJrlj6rpgInkuK3lvZPliY3ngrnlh7vpobnvvIjlkKvpu5jo
rqTpq5jkuq7pobkg4oaSIOi/m+WFpeWkmumAie+8jOS4jeimgeWPlua2iO+8iQ0KICAgICAgICBp
ZiAoIW11bHRpSWRzLmxlbmd0aCkgew0KICAgICAgICAgICAgbXVsdGlJZHMgPSBbaWRdOw0KICAg
ICAgICAgICAgc2VsZWN0ZWRJZCA9IGlkOw0KICAgICAgICAgICAgdXBkYXRlTXVsdGlCYWRnZSgp
Ow0KICAgICAgICAgICAgcmV0dXJuOw0KICAgICAgICB9DQogICAgICAgIGNvbnN0IGkgPSBtdWx0
aUlkcy5pbmRleE9mKGlkKTsNCiAgICAgICAgaWYgKGkgPj0gMCkgew0KICAgICAgICAgICAgbXVs
dGlJZHMuc3BsaWNlKGksIDEpOw0KICAgICAgICAgICAgaWYgKCtzZWxlY3RlZElkID09PSBpZCkN
CiAgICAgICAgICAgICAgICBzZWxlY3RlZElkID0gbXVsdGlJZHMubGVuZ3RoID8gbXVsdGlJZHNb
bXVsdGlJZHMubGVuZ3RoIC0gMV0gOiAwOw0KICAgICAgICB9IGVsc2Ugew0KICAgICAgICAgICAg
bXVsdGlJZHMucHVzaChpZCk7DQogICAgICAgICAgICBzZWxlY3RlZElkID0gaWQ7DQogICAgICAg
IH0NCiAgICAgICAgdXBkYXRlTXVsdGlCYWRnZSgpOw0KICAgIH0NCiAgICBmdW5jdGlvbiBzaG93
U3JjVGlwKGFuY2hvciwgdGV4dCkgew0KICAgICAgICB0ZXh0ID0gU3RyaW5nKHRleHQgfHwgJycp
LnRyaW0oKTsNCiAgICAgICAgaWYgKCF0ZXh0KSByZXR1cm47DQogICAgICAgIGxldCB0aXAgPSBk
b2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3JjLXRpcCcpOw0KICAgICAgICBpZiAoIXRpcCkgew0K
ICAgICAgICAgICAgdGlwID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnZGl2Jyk7DQogICAgICAg
ICAgICB0aXAuaWQgPSAnc3JjLXRpcCc7DQogICAgICAgICAgICBkb2N1bWVudC5ib2R5LmFwcGVu
ZENoaWxkKHRpcCk7DQogICAgICAgIH0NCiAgICAgICAgdGlwLnRleHRDb250ZW50ID0gdGV4dDsN
CiAgICAgICAgdGlwLmNsYXNzTGlzdC5hZGQoJ3Nob3cnKTsNCiAgICAgICAgY29uc3QgciA9IGFu
Y2hvci5nZXRCb3VuZGluZ0NsaWVudFJlY3QoKTsNCiAgICAgICAgY29uc3QgdHcgPSB0aXAub2Zm
c2V0V2lkdGggfHwgMTYwOw0KICAgICAgICBjb25zdCB0aCA9IHRpcC5vZmZzZXRIZWlnaHQgfHwg
Mjg7DQogICAgICAgIGxldCBsZWZ0ID0gci5yaWdodCAtIHR3Ow0KICAgICAgICBsZXQgdG9wID0g
ci50b3AgLSB0aCAtIDg7DQogICAgICAgIGlmIChsZWZ0IDwgOCkgbGVmdCA9IDg7DQogICAgICAg
IGlmIChsZWZ0ICsgdHcgPiB3aW5kb3cuaW5uZXJXaWR0aCAtIDgpIGxlZnQgPSB3aW5kb3cuaW5u
ZXJXaWR0aCAtIHR3IC0gODsNCiAgICAgICAgaWYgKHRvcCA8IDgpIHRvcCA9IHIuYm90dG9tICsg
ODsNCiAgICAgICAgdGlwLnN0eWxlLmxlZnQgPSBsZWZ0ICsgJ3B4JzsNCiAgICAgICAgdGlwLnN0
eWxlLnRvcCA9IHRvcCArICdweCc7DQogICAgICAgIGNsZWFyVGltZW91dCh0aXAuX2hpZGVUKTsN
CiAgICAgICAgdGlwLl9oaWRlVCA9IHNldFRpbWVvdXQoKCkgPT4gdGlwLmNsYXNzTGlzdC5yZW1v
dmUoJ3Nob3cnKSwgMjIwMCk7DQogICAgfQ0KICAgIC8qIGltZy1ob3Zlci1wcmV2aWV3LXY4ICov
DQogICAgbGV0IF9faW1nSG92ZXJUaW1lciA9IDAsIF9faW1nSG92ZXJIaWRlVGltZXIgPSAwLCBf
X2ltZ0hvdmVyS2V5ID0gJyc7DQogICAgZnVuY3Rpb24gX19pbWdIb3ZlckVuc3VyZSgpIHsNCiAg
ICAgICAgbGV0IGJveCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdpbWctaG92ZXItc2lkZScp
Ow0KICAgICAgICBpZiAoIWJveCkgew0KICAgICAgICAgICAgYm94ID0gZG9jdW1lbnQuY3JlYXRl
RWxlbWVudCgnZGl2Jyk7IGJveC5pZCA9ICdpbWctaG92ZXItc2lkZSc7DQogICAgICAgICAgICBj
b25zdCBmcmFtZSA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOyBmcmFtZS5jbGFzc05h
bWUgPSAnaWhwLWZyYW1lJzsNCiAgICAgICAgICAgIGNvbnN0IGltID0gZG9jdW1lbnQuY3JlYXRl
RWxlbWVudCgnaW1nJyk7IGltLmFsdCA9ICcnOw0KICAgICAgICAgICAgZnJhbWUuYXBwZW5kQ2hp
bGQoaW0pOyBib3guYXBwZW5kQ2hpbGQoZnJhbWUpOyBkb2N1bWVudC5ib2R5LmFwcGVuZENoaWxk
KGJveCk7DQogICAgICAgIH0NCiAgICAgICAgbGV0IHN0ID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5
SWQoJ2ltZy1ob3Zlci1zaWRlLWNzcycpOw0KICAgICAgICBpZiAoIXN0KSB7IHN0ID0gZG9jdW1l
bnQuY3JlYXRlRWxlbWVudCgnc3R5bGUnKTsgc3QuaWQgPSAnaW1nLWhvdmVyLXNpZGUtY3NzJzsg
ZG9jdW1lbnQuaGVhZC5hcHBlbmRDaGlsZChzdCk7IH0NCiAgICAgICAgc3QudGV4dENvbnRlbnQg
PSAiI2ltZy1ob3Zlci1zaWRle3Bvc2l0aW9uOmZpeGVkO3otaW5kZXg6MTAwMDAwO3JpZ2h0OjZw
eDt0b3A6NTAlO3RyYW5zZm9ybTp0cmFuc2xhdGVZKC01MCUpO3BvaW50ZXItZXZlbnRzOm5vbmU7
b3BhY2l0eTowO3Zpc2liaWxpdHk6aGlkZGVuO21heC13aWR0aDptaW4oNjIwcHgsOTJ2dyk7bWF4
LWhlaWdodDptaW4oOTJ2aCw5MjBweCl9I2ltZy1ob3Zlci1zaWRlLnNob3d7b3BhY2l0eToxO3Zp
c2liaWxpdHk6dmlzaWJsZX0jaW1nLWhvdmVyLXNpZGUgLmlocC1mcmFtZXtwYWRkaW5nOjNweDti
YWNrZ3JvdW5kOiNmZmY7Ym9yZGVyOjFweCBzb2xpZCAjQzVDRERDO2JvcmRlci1yYWRpdXM6MnB4
O2JveC1zaGFkb3c6MCA2cHggMThweCByZ2JhKDQ0LDQ2LDU0LC4xMil9I2ltZy1ob3Zlci1zaWRl
IGltZ3tkaXNwbGF5OmJsb2NrO21heC13aWR0aDptaW4oNjEycHgsOTB2dyk7bWF4LWhlaWdodDpt
aW4oOTB2aCw5MDBweCk7d2lkdGg6YXV0bztoZWlnaHQ6YXV0bztvYmplY3QtZml0OmNvbnRhaW47
YmFja2dyb3VuZDojZmZmfSI7DQogICAgICAgIHJldHVybiBib3g7DQogICAgfQ0KICAgIHdpbmRv
dy5fX2ltZ0hvdmVyU2hvdyA9IGZ1bmN0aW9uKGZpbGUsIGlkKSB7DQogICAgICAgIGNvbnN0IGJh
cmUgPSBTdHJpbmcoZmlsZSB8fCAnJykuc3BsaXQoL1tcXFxcL10vKS5wb3AoKTsgaWYgKCFiYXJl
KSByZXR1cm47DQogICAgICAgIGNvbnN0IGJveCA9IF9faW1nSG92ZXJFbnN1cmUoKTsgY29uc3Qg
aW1nID0gYm94LnF1ZXJ5U2VsZWN0b3IoJ2ltZycpOyBpZiAoIWltZykgcmV0dXJuOw0KICAgICAg
ICBib3guY2xhc3NMaXN0LmFkZCgnc2hvdycpOw0KICAgICAgICBpbWcub25lcnJvciA9ICgpID0+
IHsNCiAgICAgICAgICAgIGltZy5vbmVycm9yID0gKCkgPT4geyBpbWcub25lcnJvciA9IG51bGw7
IHRyeSB7IGNvbnN0IGMgPSB0aHVtYkNhY2hlICYmIHRodW1iQ2FjaGUuZ2V0KFN0cmluZyhpZCkp
OyBpZiAoYykgaW1nLnNyYyA9IGM7IH0gY2F0Y2ggKGUpIHt9IH07DQogICAgICAgICAgICBpbWcu
c3JjID0gU1RPUkVfQkFTRSArICd0aF8nICsgYmFyZS5yZXBsYWNlKC9cLlteLl0rJC8sICcnKSAr
ICcuanBnJzsNCiAgICAgICAgfTsNCiAgICAgICAgaW1nLm9ubG9hZCA9ICgpID0+IHsgaW1nLm9u
ZXJyb3IgPSBudWxsOyB9Ow0KICAgICAgICBpbWcuZGF0YXNldC5iYXJlID0gYmFyZTsgaW1nLnNy
YyA9IFNUT1JFX0JBU0UgKyBiYXJlOw0KICAgIH07DQogICAgd2luZG93Ll9faW1nSG92ZXJDbGVh
clVpID0gZnVuY3Rpb24oKSB7DQogICAgICAgIF9faW1nSG92ZXJLZXkgPSAnJzsNCiAgICAgICAg
aWYgKF9faW1nSG92ZXJUaW1lcikgeyBjbGVhclRpbWVvdXQoX19pbWdIb3ZlclRpbWVyKTsgX19p
bWdIb3ZlclRpbWVyID0gMDsgfQ0KICAgICAgICBpZiAoX19pbWdIb3ZlckhpZGVUaW1lcikgeyBj
bGVhclRpbWVvdXQoX19pbWdIb3ZlckhpZGVUaW1lcik7IF9faW1nSG92ZXJIaWRlVGltZXIgPSAw
OyB9DQogICAgICAgIGNvbnN0IGJveCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdpbWctaG92
ZXItc2lkZScpOyBpZiAoYm94KSBib3guY2xhc3NMaXN0LnJlbW92ZSgnc2hvdycpOw0KICAgICAg
ICBjb25zdCBpbWcgPSBib3ggJiYgYm94LnF1ZXJ5U2VsZWN0b3IoJ2ltZycpOw0KICAgICAgICBp
ZiAoaW1nKSB7IGltZy5vbmxvYWQgPSBudWxsOyBpbWcub25lcnJvciA9IG51bGw7IGltZy5yZW1v
dmVBdHRyaWJ1dGUoJ3NyYycpOyBkZWxldGUgaW1nLmRhdGFzZXQuYmFyZTsgfQ0KICAgIH07DQog
ICAgd2luZG93Ll9faW1nSG92ZXJIaWRlID0gZnVuY3Rpb24oKSB7IHdpbmRvdy5fX2ltZ0hvdmVy
Q2xlYXJVaSgpOyB9Ow0KICAgIGZ1bmN0aW9uIGJpbmRJbWdIb3ZlclByZXZpZXcoZWwsIGlkLCBm
aWxlKSB7DQogICAgICAgIGlmICghZWwpIHJldHVybjsNCiAgICAgICAgY29uc3QgYmFyZSA9IFN0
cmluZyhmaWxlIHx8ICcnKS5zcGxpdCgvW1xcXFwvXS8pLnBvcCgpOyBpZiAoIWJhcmUpIHJldHVy
bjsNCiAgICAgICAgY29uc3Qga2V5ID0gU3RyaW5nKGlkKSArICd8JyArIGJhcmU7DQogICAgICAg
IGVsLnN0eWxlLmN1cnNvciA9ICd6b29tLWluJzsNCiAgICAgICAgZWwuYWRkRXZlbnRMaXN0ZW5l
cignbW91c2VlbnRlcicsICgpID0+IHsNCiAgICAgICAgICAgIGlmIChfX2ltZ0hvdmVySGlkZVRp
bWVyKSB7IGNsZWFyVGltZW91dChfX2ltZ0hvdmVySGlkZVRpbWVyKTsgX19pbWdIb3ZlckhpZGVU
aW1lciA9IDA7IH0NCiAgICAgICAgICAgIF9faW1nSG92ZXJLZXkgPSBrZXk7DQogICAgICAgICAg
ICBpZiAoX19pbWdIb3ZlclRpbWVyKSBjbGVhclRpbWVvdXQoX19pbWdIb3ZlclRpbWVyKTsNCiAg
ICAgICAgICAgIF9faW1nSG92ZXJUaW1lciA9IHNldFRpbWVvdXQoKCkgPT4geyBpZiAoX19pbWdI
b3ZlcktleSA9PT0ga2V5KSB0cnkgeyB3aW5kb3cuX19pbWdIb3ZlclNob3coYmFyZSwgaWQpOyB9
IGNhdGNoIChlKSB7fSB9LCA2MCk7DQogICAgICAgIH0pOw0KICAgICAgICBlbC5hZGRFdmVudExp
c3RlbmVyKCdtb3VzZWxlYXZlJywgKCkgPT4gew0KICAgICAgICAgICAgaWYgKF9faW1nSG92ZXJU
aW1lcikgeyBjbGVhclRpbWVvdXQoX19pbWdIb3ZlclRpbWVyKTsgX19pbWdIb3ZlclRpbWVyID0g
MDsgfQ0KICAgICAgICAgICAgX19pbWdIb3ZlckhpZGVUaW1lciA9IHNldFRpbWVvdXQoKCkgPT4g
eyBpZiAoIV9faW1nSG92ZXJLZXkgfHwgX19pbWdIb3ZlcktleSA9PT0ga2V5KSB3aW5kb3cuX19p
bWdIb3ZlckhpZGUoKTsgfSwgNzApOw0KICAgICAgICB9KTsNCiAgICB9DQoNCiAgICBmdW5jdGlv
biByZW5kZXIoKSB7DQogICAgICAgIGhpZGVQYXRoVGlwKCk7DQoNCiAgICAgICAgY29uc3Qgdmlz
aWJsZSA9IHZpc2libGVMaXN0KCk7DQogICAgICAgIGNvbnN0IGxvYWRlZCA9IGFsbENsaXBzLmxl
bmd0aDsNCiAgICAgICAgY29uc3Qgc2hvd25Db3VudCA9IHZpc2libGUubGVuZ3RoOw0KICAgICAg
ICAvLyDmlLbol4/op5LmoIfvvJrmlLnkuLrnu7/ngrnvvIjmnInmnKrmn6XnnIvnmoTmlrDmlLbo
l4/ml7bmmL7npLrvvIkNCiAgICAgICAgbGV0IHBpbm5lZE4gPSBOdW1iZXIocGlubmVkVG90YWwp
IHx8IDA7DQogICAgICAgIGlmIChwaW5uZWROIDwgMSkgew0KICAgICAgICAgICAgaWYgKGN1clRh
YiA9PT0gJ3Bpbm5lZCcpDQogICAgICAgICAgICAgICAgcGlubmVkTiA9IE1hdGgubWF4KE51bWJl
cihkaXNrVG90YWwpIHx8IDAsIGxvYWRlZCk7DQogICAgICAgICAgICBlbHNlDQogICAgICAgICAg
ICAgICAgcGlubmVkTiA9IGFsbENsaXBzLmZpbHRlcihjID0+IGlzUGlubmVkKGMpKS5sZW5ndGg7
DQogICAgICAgIH0NCiAgICAgICAgdXBkYXRlUGluRG90KCk7DQogICAgICAgIC8vIOaUtuiXjyB0
YWLvvJpiYXIg55So5oC75pWw77yb5pyq5ruh6aG15pe25pi+56S6IOW3suWKoOi9vS/mgLvmlbAN
CiAgICAgICAgbGV0IHNob3dUb3RhbCA9IGRpc2tUb3RhbCA+IDAgPyBkaXNrVG90YWwgOiAobG9h
ZGVkIHx8IDApOw0KICAgICAgICBpZiAoY3VyVGFiID09PSAncGlubmVkJyAmJiBwaW5uZWROID4g
c2hvd1RvdGFsKQ0KICAgICAgICAgICAgc2hvd1RvdGFsID0gcGlubmVkTjsNCiAgICAgICAgY29u
c3QgcU9uID0gU3RyaW5nKHF1ZXJ5IHx8ICcnKS50cmltKCkubGVuZ3RoID4gMDsNCiAgICAgICAg
ZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2Jhci10eHQnKS50ZXh0Q29udGVudCA9IHFPbg0KICAg
ICAgICAgICAgPyAoc2hvd25Db3VudCArICcg5p2hJykNCiAgICAgICAgICAgIDogKHNob3dUb3Rh
bCA+IGxvYWRlZCA/IChzaG93bkNvdW50ICsgJyAvICcgKyBzaG93VG90YWwgKyAnIOadoScpIDog
KHNob3dUb3RhbCArICcg5p2hJykpOw0KICAgICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgn
ZW1wdHktdHh0JykudGV4dENvbnRlbnQgPSBFTVBUWV9NU0dbY3VyVGFiXSB8fCBFTVBUWV9NU0cu
YWxsOw0KDQogICAgICAgIGNvbnN0IGlkU2V0ID0gbmV3IFNldChhbGxDbGlwcy5tYXAoYyA9PiAr
Yy5pZCkpOw0KICAgICAgICBtdWx0aUlkcyA9IG11bHRpSWRzLmZpbHRlcihpZCA9PiBpZFNldC5o
YXMoaWQpKTsNCiAgICAgICAgdXBkYXRlTXVsdGlCYWRnZSgpOw0KDQogICAgICAgIGNvbnN0IHNo
b3duID0gdmlzaWJsZTsNCg0KICAgICAgICBsaXN0RWwucXVlcnlTZWxlY3RvckFsbCgnLml0bSwg
I2xpc3QtbW9yZScpLmZvckVhY2goZSA9PiBlLnJlbW92ZSgpKTsNCiAgICAgICAgLy8g6aqo5p62
5bey5YWz6Zet77ya5Y2z5L2/IHdhaXRpbmcg5Lmf5LiNIHJldHVybu+8jOacieaVsOaNruWwseeb
tOaOpeeUuw0KICAgICAgICBpZiAoc2tlbEVsKSBza2VsRWwuY2xhc3NMaXN0LnJlbW92ZSgnb24n
KTsNCiAgICAgICAgY29uc3QgYXBwQm9vdCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdhcHAn
KTsNCiAgICAgICAgaWYgKGFwcEJvb3QpIGFwcEJvb3QuY2xhc3NMaXN0LnJlbW92ZSgnYm9vdC1s
b2FkaW5nJyk7DQogICAgICAgIGlmICgod2FpdGluZ0RhdGEgfHwgIWhvc3RQdXNoZWRPbmNlKSAm
JiAhdmlzaWJsZS5sZW5ndGgpIHsNCiAgICAgICAgICAgIGVtcHR5RWwuY2xhc3NMaXN0LnJlbW92
ZSgnb24nKTsNCiAgICAgICAgICAgIHVwZGF0ZVRvcEJ0bigpOw0KICAgICAgICAgICAgcmV0dXJu
Ow0KICAgICAgICB9DQogICAgICAgIGlmICghdmlzaWJsZS5sZW5ndGgpIHsNCiAgICAgICAgICAg
IC8vIE5ldmVyIHNob3fjgIzmmoLml6DorrDlvZXjgI11bnRpbCB3ZSBoYXZlIHNlZW4gYSByZWFs
IG5vbi1lbXB0eSBwdXNoLA0KICAgICAgICAgICAgLy8gb3IgYSBjb25maXJtZWQgZW1wdHkgYWZ0
ZXIgd2FybSAoc2F3Tm9uRW1wdHkgY2FuIGJlIHNldCBieSBlbXB0eS1mYWxsYmFjaykuDQogICAg
ICAgICAgICAvLyBGaWx0ZXJlZCBzZWFyY2ggd2l0aCAwIGhpdHMgaXMgYWxsb3dlZCBvbmNlIGhv
c3QgcHVzaGVkLg0KICAgICAgICAgICAgY29uc3QgcU9uID0gU3RyaW5nKHF1ZXJ5IHx8ICcnKS50
cmltKCkubGVuZ3RoID4gMDsNCiAgICAgICAgICAgIGNvbnN0IGFsbG93RW1wdHkgPSBob3N0UHVz
aGVkT25jZSAmJiBzYXdOb25FbXB0eSAmJiAhd2FpdGluZ0RhdGEgJiYgIWJvb3RMb2FkaW5nDQog
ICAgICAgICAgICAgICAgJiYgKHFPbiB8fCBkaXNrVG90YWwgPD0gMCk7DQogICAgICAgICAgICBp
ZiAoIWFsbG93RW1wdHkpIHsNCiAgICAgICAgICAgICAgICBlbXB0eUVsLmNsYXNzTGlzdC5yZW1v
dmUoJ29uJyk7DQogICAgICAgICAgICAgICAgdXBkYXRlVG9wQnRuKCk7DQogICAgICAgICAgICAg
ICAgcmV0dXJuOw0KICAgICAgICAgICAgfQ0KICAgICAgICAgICAgaWYgKHNlbGVjdEZpcnN0T25T
aG93KSB7DQogICAgICAgICAgICAgICAgc2VsZWN0Rmlyc3RPblNob3cgPSBmYWxzZTsNCiAgICAg
ICAgICAgICAgICBzZWxlY3RlZElkID0gMDsNCiAgICAgICAgICAgICAgICBjbGVhck11bHRpKCk7
DQogICAgICAgICAgICAgICAgbGlzdEVsLnNjcm9sbFRvcCA9IDA7DQogICAgICAgICAgICB9DQog
ICAgICAgICAgICBlbXB0eUVsLmNsYXNzTGlzdC5hZGQoJ29uJyk7DQogICAgICAgICAgICB1cGRh
dGVUb3BCdG4oKTsNCiAgICAgICAgICAgIHJldHVybjsNCiAgICAgICAgfQ0KICAgICAgICBlbXB0
eUVsLmNsYXNzTGlzdC5yZW1vdmUoJ29uJyk7DQogICAgICAgIGNvbnN0IGZyYWcgPSBkb2N1bWVu
dC5jcmVhdGVEb2N1bWVudEZyYWdtZW50KCk7DQogICAgICAgIGNvbnN0IGJsb2NrcyA9IGJ1aWxk
UGlubmVkQmxvY2tzKHNob3duKTsNCiAgICAgICAgbGV0IG51bSA9IDA7DQogICAgICAgIGJsb2Nr
cy5mb3JFYWNoKGIgPT4gew0KICAgICAgICAgICAgbnVtICs9IDE7DQogICAgICAgICAgICBpZiAo
Yi5raW5kID09PSAnZ3JvdXAnICYmIGIuaXRlbXMubGVuZ3RoID4gMSkNCiAgICAgICAgICAgICAg
ICBmcmFnLmFwcGVuZENoaWxkKG1ha2VHcm91cEl0ZW0oYi5pdGVtcywgbnVtKSk7DQogICAgICAg
ICAgICBlbHNlDQogICAgICAgICAgICAgICAgZnJhZy5hcHBlbmRDaGlsZChtYWtlSXRlbShiLml0
ZW1zWzBdLCBudW0pKTsNCiAgICAgICAgfSk7DQogICAgICAgIGxpc3RFbC5hcHBlbmRDaGlsZChm
cmFnKTsNCiAgICAgICAgbWFya1F1ZXVlUmFpbHMoKTsNCiAgICAgICAgdXBkYXRlTW9yZUZvb3Rl
cihkaXNrVG90YWwpOw0KICAgICAgICBpZiAoc2VsZWN0Rmlyc3RPblNob3cpIHsNCiAgICAgICAg
ICAgIHNlbGVjdEZpcnN0T25TaG93ID0gZmFsc2U7DQogICAgICAgICAgICBzZWxlY3RlZElkID0g
dmlzaWJsZVswXS5pZDsNCiAgICAgICAgICAgIGNsZWFyTXVsdGkoKTsNCiAgICAgICAgICAgIGxp
c3RFbC5zY3JvbGxUb3AgPSAwOw0KICAgICAgICB9IGVsc2UgaWYgKCF2aXNpYmxlLnNvbWUoYyA9
PiBjLmlkID09IHNlbGVjdGVkSWQpKSB7DQogICAgICAgICAgICBzZWxlY3RlZElkID0gdmlzaWJs
ZVswXS5pZDsNCiAgICAgICAgICAgIHJhbmdlQW5jaG9ySWQgPSBzZWxlY3RlZElkOw0KICAgICAg
ICAgICAgcmFuZ2VBbmNob3JDbGlja2VkID0gZmFsc2U7DQogICAgICAgIH0gZWxzZSBpZiAoIXJh
bmdlQW5jaG9ySWQpIHsNCiAgICAgICAgICAgIHJhbmdlQW5jaG9ySWQgPSBzZWxlY3RlZElkOw0K
ICAgICAgICB9DQogICAgICAgIHN5bmNJdGVtSGlnaGxpZ2h0KCk7DQogICAgICAgIHVwZGF0ZVRv
cEJ0bigpOw0KICAgICAgICBpZiAod2luZG93Ll9fcGVuZGluZ0p1bXBJZCkgew0KICAgICAgICAg
ICAgY29uc3QgamlkID0gK3dpbmRvdy5fX3BlbmRpbmdKdW1wSWQ7DQogICAgICAgICAgICBjb25z
dCBlbCA9IGxpc3RFbC5xdWVyeVNlbGVjdG9yKCcubWctcm93W2RhdGEtaWQ9IicgKyBqaWQgKyAn
Il0nKSB8fCBsaXN0RWwucXVlcnlTZWxlY3RvcignLml0bVtkYXRhLWlkPSInICsgamlkICsgJyJd
Jyk7DQogICAgICAgICAgICBpZiAoZWwpIHsNCiAgICAgICAgICAgICAgICB3aW5kb3cuX19wZW5k
aW5nSnVtcElkID0gMDsNCiAgICAgICAgICAgICAgICB3aW5kb3cuX19qdW1wTG9hZFRyaWVzID0g
MDsNCiAgICAgICAgICAgICAgICBzZWxlY3RlZElkID0gamlkOw0KICAgICAgICAgICAgICAgIHJl
cXVlc3RBbmltYXRpb25GcmFtZSgoKSA9PiB7DQogICAgICAgICAgICAgICAgICAgIGNvbnN0IG5v
ZGUgPSBsaXN0RWwucXVlcnlTZWxlY3RvcignLm1nLXJvd1tkYXRhLWlkPSInICsgamlkICsgJyJd
JykgfHwgbGlzdEVsLnF1ZXJ5U2VsZWN0b3IoJy5pdG1bZGF0YS1pZD0iJyArIGppZCArICciXScp
Ow0KICAgICAgICAgICAgICAgICAgICBpZiAoIW5vZGUpIHJldHVybjsNCiAgICAgICAgICAgICAg
ICAgICAgbm9kZS5zY3JvbGxJbnRvVmlldyh7IGJsb2NrOiAnY2VudGVyJyB9KTsNCiAgICAgICAg
ICAgICAgICAgICAgbm9kZS5jbGFzc0xpc3QuYWRkKCdqdW1wLWZsYXNoJyk7DQogICAgICAgICAg
ICAgICAgICAgIHNldFRpbWVvdXQoKCkgPT4gbm9kZS5jbGFzc0xpc3QucmVtb3ZlKCdqdW1wLWZs
YXNoJyksIDkwMCk7DQogICAgICAgICAgICAgICAgICAgIHN5bmNJdGVtSGlnaGxpZ2h0KCk7DQog
ICAgICAgICAgICAgICAgfSk7DQogICAgICAgICAgICB9IGVsc2UgaWYgKGFsbENsaXBzLmxlbmd0
aCA8IGRpc2tUb3RhbCAmJiAod2luZG93Ll9fanVtcExvYWRUcmllcyB8fCAwKSA8IDQwKSB7DQog
ICAgICAgICAgICAgICAgd2luZG93Ll9fanVtcExvYWRUcmllcyA9ICh3aW5kb3cuX19qdW1wTG9h
ZFRyaWVzIHx8IDApICsgMTsNCiAgICAgICAgICAgICAgICByZXF1ZXN0TW9yZSgpOw0KICAgICAg
ICAgICAgfSBlbHNlIGlmIChjdXJUYWIgIT09ICdhbGwnICYmICF3aW5kb3cuX19qdW1wRmVsbEJh
Y2spIHsNCiAgICAgICAgICAgICAgICAvLyBJdGVtIGdvbmUgZnJvbSB0aGlzIHRhYiAoZS5nLiB1
bnBpbm5lZCkg4oCUIGZhbGwgYmFjayB0byDlhajpg6ggb25jZQ0KICAgICAgICAgICAgICAgIHdp
bmRvdy5fX2p1bXBGZWxsQmFjayA9IHRydWU7DQogICAgICAgICAgICAgICAgd2luZG93Ll9fanVt
cExvYWRUcmllcyA9IDA7DQogICAgICAgICAgICAgICAgY3VyVGFiID0gJ2FsbCc7DQogICAgICAg
ICAgICAgICAgbWFya1RhYignYWxsJyk7DQogICAgICAgICAgICAgICAgcmVxdWVzdFZpZXcoKTsN
CiAgICAgICAgICAgIH0gZWxzZSB7DQogICAgICAgICAgICAgICAgd2luZG93Ll9fcGVuZGluZ0p1
bXBJZCA9IDA7DQogICAgICAgICAgICAgICAgd2luZG93Ll9fanVtcExvYWRUcmllcyA9IDA7DQog
ICAgICAgICAgICAgICAgaWYgKGFsbENsaXBzLnNvbWUoYyA9PiArYy5pZCA9PT0gamlkKSkNCiAg
ICAgICAgICAgICAgICAgICAgc2VsZWN0ZWRJZCA9IGppZDsNCiAgICAgICAgICAgICAgICBzeW5j
SXRlbUhpZ2hsaWdodCgpOw0KICAgICAgICAgICAgfQ0KICAgICAgICB9DQogICAgICAgIHJlcXVl
c3RBbmltYXRpb25GcmFtZSgoKSA9PiB7DQogICAgICAgICAgICBpZiAoYWxsQ2xpcHMubGVuZ3Ro
IDwgZGlza1RvdGFsDQogICAgICAgICAgICAgICAgJiYgbGlzdEVsLnNjcm9sbEhlaWdodCA8PSBs
aXN0RWwuY2xpZW50SGVpZ2h0ICsgMjApDQogICAgICAgICAgICAgICAgcmVxdWVzdE1vcmUoKTsN
CiAgICAgICAgICAgIHNjaGVkdWxlRmlsZUdvbmVDaGVjaygpOw0KICAgICAgICB9KTsNCiAgICB9
DQoNCiAgICBjb25zdCBTVkcgPSB7DQogICAgICAgIHRleHQ6ICAgYDxzdmcgdmlld0JveD0iMCAw
IDI0IDI0IiBmaWxsPSJub25lIiBzdHJva2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIy
Ij48cGF0aCBkPSJNNCA3VjRoMTZ2M005IDIwaDZNMTIgNHYxNiIvPjwvc3ZnPmAsDQogICAgICAg
IG1kOiAgICAgYDxzdmcgdmlld0JveD0iMCAwIDI0IDI0IiBmaWxsPSJjdXJyZW50Q29sb3IiPjx0
ZXh0IHg9IjEyIiB5PSIxNyIgdGV4dC1hbmNob3I9Im1pZGRsZSIgZm9udC1zaXplPSIxNSIgZm9u
dC13ZWlnaHQ9IjgwMCIgZm9udC1mYW1pbHk9IlNlZ29lIFVJLE1pY3Jvc29mdCBZYUhlaSxzYW5z
LXNlcmlmIj5NPC90ZXh0Pjwvc3ZnPmAsDQogICAgICAgIGltYWdlOiAgYDxzdmcgdmlld0JveD0i
MCAwIDI0IDI0IiBmaWxsPSJub25lIiBzdHJva2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRo
PSIxLjgiPjxyZWN0IHg9IjMiIHk9IjUiIHdpZHRoPSIxOCIgaGVpZ2h0PSIxNCIgcng9IjIiLz48
Y2lyY2xlIGN4PSI4LjUiIGN5PSIxMCIgcj0iMS41IiBmaWxsPSJjdXJyZW50Q29sb3IiIHN0cm9r
ZT0ibm9uZSIvPjxwYXRoIGQ9Ik0zIDE2bDUtNSA0IDQgMy0zIDYgNiIvPjwvc3ZnPmAsDQogICAg
ICAgIHZpZGVvOiAgYDxzdmcgdmlld0JveD0iMCAwIDI0IDI0IiBmaWxsPSJub25lIiBzdHJva2U9
ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIxLjgiPjxyZWN0IHg9IjMiIHk9IjYiIHdpZHRo
PSIxNCIgaGVpZ2h0PSIxMiIgcng9IjIiLz48cGF0aCBkPSJNMTcgOS41bDQtMi41djEwbC00LTIu
NVY5LjV6IiBmaWxsPSJjdXJyZW50Q29sb3IiIHN0cm9rZT0ibm9uZSIvPjxwYXRoIGQ9Ik04LjUg
MTAuMnYzLjZsMy4yLTEuOC0zLjItMS44eiIgZmlsbD0iY3VycmVudENvbG9yIiBzdHJva2U9Im5v
bmUiLz48L3N2Zz5gLA0KICAgICAgICBmb2xkZXI6IGA8c3ZnIHZpZXdCb3g9IjAgMCAyNCAyNCIg
ZmlsbD0iY3VycmVudENvbG9yIj48cGF0aCBkPSJNMTAgNEg0Yy0xLjEgMC0yIC45LTIgMnYxMmMw
IDEuMS45IDIgMiAyaDE2YzEuMSAwIDItLjkgMi0yVjhjMC0xLjEtLjktMi0yLTJoLThsLTItMnoi
Lz48L3N2Zz5gLA0KICAgICAgICB6aXA6ICAgIGA8c3ZnIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmls
bD0ibm9uZSIgc3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0cm9rZS13aWR0aD0iMS44Ij48cGF0aCBk
PSJNNiAzaDlsNSA1djEzYTEgMSAwIDAgMS0xIDFINmExIDEgMCAwIDEtMS0xVjRhMSAxIDAgMCAx
IDEtMXoiLz48cGF0aCBkPSJNMTQgM3Y2aDYiLz48L3N2Zz5gLA0KICAgICAgICBhaGs6ICAgIGA8
c3ZnIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0iY3VycmVudENvbG9yIj48dGV4dCB4PSIxMiIg
eT0iMTciIHRleHQtYW5jaG9yPSJtaWRkbGUiIGZvbnQtc2l6ZT0iMTQiIGZvbnQtd2VpZ2h0PSI3
MDAiPkg8L3RleHQ+PC9zdmc+YCwNCiAgICAgICAgbG5rOiAgICBgPHN2ZyB2aWV3Qm94PSIwIDAg
MjQgMjQiIGZpbGw9Im5vbmUiIHN0cm9rZT0iY3VycmVudENvbG9yIiBzdHJva2Utd2lkdGg9IjEu
OCI+PHBhdGggZD0iTTEwIDEzYTUgNSAwIDAgMCA3LjA3IDBsMi4xMi0yLjEyYTUgNSAwIDAgMC03
LjA3LTcuMDdMMTEgNSIvPjxwYXRoIGQ9Ik0xNCAxMWE1IDUgMCAwIDAtNy4wNyAwTDQuOCAxMy4x
MmE1IDUgMCAxIDAgNy4wNyA3LjA3TDEzIDE5Ii8+PC9zdmc+YCwNCiAgICAgICAgZG9jOiAgICBg
PHN2ZyB2aWV3Qm94PSIwIDAgMjQgMjQiIGZpbGw9Im5vbmUiIHN0cm9rZT0iY3VycmVudENvbG9y
IiBzdHJva2Utd2lkdGg9IjEuOCI+PHBhdGggZD0iTTcgM2g3bDUgNXYxM2ExIDEgMCAwIDEtMSAx
SDdhMSAxIDAgMCAxLTEtMVY0YTEgMSAwIDAgMSAxLTF6Ii8+PHBhdGggZD0iTTE0IDN2Nmg2Ii8+
PC9zdmc+YCwNCiAgICAgICAgbXVsdGk6ICBgPHN2ZyB2aWV3Qm94PSIwIDAgMjQgMjQiIGZpbGw9
Im5vbmUiIHN0cm9rZT0iY3VycmVudENvbG9yIiBzdHJva2Utd2lkdGg9IjEuOCI+PHJlY3QgeD0i
NyIgeT0iNyIgd2lkdGg9IjEyIiBoZWlnaHQ9IjE0IiByeD0iMS41Ii8+PHBhdGggZD0iTTUgMTdW
NWExIDEgMCAwIDEgMS0xaDEwIi8+PC9zdmc+YA0KICAgIH07DQoNCiAgICBmdW5jdGlvbiBmaWxl
RXh0KHBhdGgpIHsNCiAgICAgICAgY29uc3QgYmFzZSA9IFN0cmluZyhwYXRoIHx8ICcnKS5zcGxp
dCgvW1xcL10vKS5wb3AoKSB8fCAnJzsNCiAgICAgICAgY29uc3QgaSA9IGJhc2UubGFzdEluZGV4
T2YoJy4nKTsNCiAgICAgICAgcmV0dXJuIGkgPiAwID8gYmFzZS5zbGljZShpICsgMSkudG9Mb3dl
ckNhc2UoKSA6ICcnOw0KICAgIH0NCiAgICBjb25zdCBpc0ltYWdlRXh0ID0gZSA9PiBbJ3BuZycs
J2pwZycsJ2pwZWcnLCdnaWYnLCd3ZWJwJywnYm1wJywnaWNvJywndGlmJywndGlmZicsJ3N2Zydd
LmluY2x1ZGVzKGUpOw0KICAgIGNvbnN0IGlzVmlkZW9FeHQgPSBlID0+IFsnbXA0JywnbWt2Jywn
YXZpJywnbW92Jywnd212JywnZmx2Jywnd2VibScsJ200dicsJ21wZWcnLCdtcGcnLCd0cycsJ20y
dHMnLCczZ3AnLCdybScsJ3JtdmInXS5pbmNsdWRlcyhlKTsNCiAgICBjb25zdCBpc1ppcEV4dCAg
ID0gZSA9PiBbJ3ppcCcsJ3JhcicsJzd6JywndGFyJywnZ3onLCdiejInXS5pbmNsdWRlcyhlKTsN
Cg0KICAgIGZ1bmN0aW9uIGljb25Gb3JGaWxlcyhmaWxlcykgew0KICAgICAgICBpZiAoIWZpbGVz
Lmxlbmd0aCkgICAgcmV0dXJuIHsgY2xzOiAnZmlsZSBmdC1kb2MnLCBzdmc6IFNWRy5kb2MgfTsN
CiAgICAgICAgaWYgKGZpbGVzLmxlbmd0aCA+IDEpIHJldHVybiB7IGNsczogJ2ZpbGUgZnQtbG5r
Jywgc3ZnOiBTVkcubXVsdGkgfTsNCiAgICAgICAgY29uc3QgZXh0ID0gZmlsZUV4dChmaWxlc1sw
XSk7DQogICAgICAgIGlmICghZXh0KSAgICAgICAgICAgICAgcmV0dXJuIHsgY2xzOiAnZmlsZSBm
dC1kaXInLCBzdmc6IFNWRy5mb2xkZXIgfTsNCiAgICAgICAgaWYgKGlzSW1hZ2VFeHQoZXh0KSkg
ICByZXR1cm4geyBjbHM6ICdmaWxlIGZ0LWltZycsIHN2ZzogU1ZHLmltYWdlIH07DQogICAgICAg
IGlmIChpc1ZpZGVvRXh0KGV4dCkpICAgcmV0dXJuIHsgY2xzOiAnZmlsZSBmdC12aWQnLCBzdmc6
IChTVkcudmlkZW8gfHwgU1ZHLmRvYykgfTsNCiAgICAgICAgaWYgKGlzWmlwRXh0KGV4dCkpICAg
ICByZXR1cm4geyBjbHM6ICdmaWxlIGZ0LXppcCcsIHN2ZzogU1ZHLnppcCB9Ow0KICAgICAgICBp
ZiAoZXh0ID09PSAnYWhrJykgICAgIHJldHVybiB7IGNsczogJ2ZpbGUgZnQtYWhrJywgc3ZnOiBT
VkcuYWhrIH07DQogICAgICAgIGlmIChleHQgPT09ICdsbmsnKSAgICAgcmV0dXJuIHsgY2xzOiAn
ZmlsZSBmdC1sbmsnLCBzdmc6IFNWRy5sbmsgfTsNCiAgICAgICAgcmV0dXJuIHsgY2xzOiAnZmls
ZSBmdC1kb2MnLCBzdmc6IFNWRy5kb2MgfTsNCiAgICB9DQoNCiAgICBmdW5jdGlvbiBzcmNXaW5M
YWJlbChjKSB7DQogICAgICAgIGNvbnN0IHQgPSBTdHJpbmcoYyAmJiBjLnNyY1RpdGxlIHx8ICcn
KS50cmltKCk7DQogICAgICAgIGlmICh0KSByZXR1cm4gdDsNCiAgICAgICAgcmV0dXJuIFN0cmlu
ZyhjICYmIGMuc3JjRXhlIHx8ICcnKS5yZXBsYWNlKC9cLmV4ZSQvaSwgJycpOw0KICAgIH0NCiAg
ICBmdW5jdGlvbiBzcmNUaXRsZUh0bWwoYykgew0KICAgICAgICAvLyDliJfooajkuK3pl7Qv5Y+z
5L6n5LiN5YaN5pi+56S656qX5Y+j5qCH6aKY77yM5p2l5rqQ5Y+q5L+d55WZ5Y+z5L6n5Zu+5qCH
5oKs5YGc5o+Q56S6DQogICAgICAgIHJldHVybiAnJzsNCiAgICB9DQogICAgZnVuY3Rpb24gZXhw
YW5kQ2hldnJvbihvcGVuKSB7DQogICAgICAgIHJldHVybiBvcGVuDQogICAgICAgICAgICA/IGA8
c3ZnIHZpZXdCb3g9IjAgMCAxNiAxNiIgd2lkdGg9IjE0IiBoZWlnaHQ9IjE0IiBmaWxsPSJub25l
IiBzdHJva2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIxLjgiIHN0cm9rZS1saW5lY2Fw
PSJyb3VuZCI+PHBvbHlsaW5lIHBvaW50cz0iNCAxMCA4IDYgMTIgMTAiLz48L3N2Zz48c3Bhbj7m
lLbotbc8L3NwYW4+YA0KICAgICAgICAgICAgOiBgPHN2ZyB2aWV3Qm94PSIwIDAgMTYgMTYiIHdp
ZHRoPSIxNCIgaGVpZ2h0PSIxNCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0
cm9rZS13aWR0aD0iMS44IiBzdHJva2UtbGluZWNhcD0icm91bmQiPjxwb2x5bGluZSBwb2ludHM9
IjQgNiA4IDEwIDEyIDYiLz48L3N2Zz48c3Bhbj7lsZXlvIA8L3NwYW4+YDsNCiAgICB9DQogICAg
ZnVuY3Rpb24gbGlzdEV4cGFuZE1heFB4KCkgew0KICAgICAgICBjb25zdCBoID0gKGxpc3RFbCAm
JiBsaXN0RWwuY2xpZW50SGVpZ2h0KSB8fCAzNjA7DQogICAgICAgIC8vIOWHoOS5juWNoOa7oeWI
l+ihqO+8jOW6lemDqOeVmee6puS4gOihjA0KICAgICAgICByZXR1cm4gTWF0aC5tYXgoOTYsIGgg
LSAyOCk7DQogICAgfQ0KICAgIGZ1bmN0aW9uIGFwcGx5RXhwYW5kZWRQcmV2aWV3KHByZXYsIGZ1
bGxUZXh0KSB7DQogICAgICAgIGNvbnN0IG1heEggPSBsaXN0RXhwYW5kTWF4UHgoKTsNCiAgICAg
ICAgcHJldi5zdHlsZS5tYXhIZWlnaHQgPSBtYXhIICsgJ3B4JzsNCiAgICAgICAgcHJldi5jbGFz
c0xpc3QuYWRkKCdleHBhbmRlZCcpOw0KICAgICAgICBzZXRIbFRleHQocHJldiwgZnVsbFRleHQp
Ow0KICAgICAgICAvLyDku43muqLlh7rvvJrmiKrmlq3lubblnKjmnKvlsL7liqDjgIwgLi4u44CN
DQogICAgICAgIGlmIChwcmV2LnNjcm9sbEhlaWdodCA8PSBwcmV2LmNsaWVudEhlaWdodCArIDIp
DQogICAgICAgICAgICByZXR1cm47DQogICAgICAgIGxldCBsbyA9IDAsIGhpID0gZnVsbFRleHQu
bGVuZ3RoLCBiZXN0ID0gMDsNCiAgICAgICAgd2hpbGUgKGxvIDw9IGhpKSB7DQogICAgICAgICAg
ICBjb25zdCBtaWQgPSAobG8gKyBoaSkgPj4gMTsNCiAgICAgICAgICAgIHNldEhsVGV4dChwcmV2
LCBmdWxsVGV4dC5zbGljZSgwLCBtaWQpICsgJyAuLi4nKTsNCiAgICAgICAgICAgIGlmIChwcmV2
LnNjcm9sbEhlaWdodCA8PSBwcmV2LmNsaWVudEhlaWdodCArIDIpIHsNCiAgICAgICAgICAgICAg
ICBiZXN0ID0gbWlkOw0KICAgICAgICAgICAgICAgIGxvID0gbWlkICsgMTsNCiAgICAgICAgICAg
IH0gZWxzZSB7DQogICAgICAgICAgICAgICAgaGkgPSBtaWQgLSAxOw0KICAgICAgICAgICAgfQ0K
ICAgICAgICB9DQogICAgICAgIHNldEhsVGV4dChwcmV2LCBmdWxsVGV4dC5zbGljZSgwLCBiZXN0
KSArICcgLi4uJyk7DQogICAgfQ0KICAgIGZ1bmN0aW9uIGNvbGxhcHNlUHJldmlldyhwcmV2LCBm
dWxsVGV4dCkgew0KICAgICAgICBwcmV2LmNsYXNzTGlzdC5yZW1vdmUoJ2V4cGFuZGVkJyk7DQog
ICAgICAgIHByZXYuc3R5bGUubWF4SGVpZ2h0ID0gJyc7DQogICAgICAgIHNldEhsVGV4dChwcmV2
LCBmdWxsVGV4dCk7DQogICAgfQ0KDQogICAgZnVuY3Rpb24gZmF2R3JvdXBPZihjKSB7DQogICAg
ICAgIHJldHVybiBTdHJpbmcoYyAmJiBjLmZhdkdyb3VwIHx8ICcnKS50cmltKCk7DQogICAgfQ0K
ICAgIGZ1bmN0aW9uIGNsaXBDb250ZW50UHJldmlldyhjKSB7DQogICAgICAgIGNvbnN0IHR5cGUg
PSBub3JtVHlwZShjLnR5cGUpOw0KICAgICAgICBpZiAodHlwZSA9PT0gJ2ltYWdlJykgcmV0dXJu
ICdb5Zu+5YOPXScgKyAoYy53aWR0aCAmJiBjLmhlaWdodCA/ICgnICcgKyBjLndpZHRoICsgJ8OX
JyArIGMuaGVpZ2h0KSA6ICcnKTsNCiAgICAgICAgaWYgKHR5cGUgPT09ICdmaWxlJykgew0KICAg
ICAgICAgICAgY29uc3QgZmlsZXMgPSBTdHJpbmcoYy5wcmV2aWV3IHx8IGMuZGF0YSB8fCAnJyku
c3BsaXQoL1xyP1xuLykuZmlsdGVyKEJvb2xlYW4pOw0KICAgICAgICAgICAgcmV0dXJuIGZpbGVz
Lm1hcChmID0+IGYuc3BsaXQoL1tcXC9dLykucG9wKCkpLmpvaW4oJyDCtyAnKSB8fCAnW+aWh+S7
tl0nOw0KICAgICAgICB9DQogICAgICAgIGxldCBfcCA9IFN0cmluZyhjLnByZXZpZXcgfHwgYy5k
YXRhIHx8ICcnKTsNCiAgICAgICAgeyBjb25zdCBfbiA9IE51bWJlcihjLmNoYXJDb3VudCkgfHwg
MDsgaWYgKF9uID4gX3AubGVuZ3RoICYmIF9wLmxlbmd0aCkgX3AgKz0gJy4uLic7IH0NCiAgICAg
ICAgcmV0dXJuIF9wOw0KICAgIH0NCiAgICBmdW5jdGlvbiBidWlsZFBpbm5lZEJsb2NrcyhsaXN0
KSB7DQogICAgICAgIGNvbnN0IHVzZWQgPSBuZXcgU2V0KCk7DQogICAgICAgIGNvbnN0IG91dCA9
IFtdOw0KICAgICAgICBmb3IgKGNvbnN0IGMgb2YgbGlzdCkgew0KICAgICAgICAgICAgaWYgKHVz
ZWQuaGFzKCtjLmlkKSkgY29udGludWU7DQogICAgICAgICAgICBjb25zdCBnaWQgPSBmYXZHcm91
cE9mKGMpOw0KICAgICAgICAgICAgaWYgKCFnaWQpIHsNCiAgICAgICAgICAgICAgICB1c2VkLmFk
ZCgrYy5pZCk7DQogICAgICAgICAgICAgICAgb3V0LnB1c2goeyBraW5kOiAnc2luZ2xlJywgaXRl
bXM6IFtjXSB9KTsNCiAgICAgICAgICAgICAgICBjb250aW51ZTsNCiAgICAgICAgICAgIH0NCiAg
ICAgICAgICAgIGNvbnN0IG1lbWJlcnMgPSBsaXN0LmZpbHRlcih4ID0+IGZhdkdyb3VwT2YoeCkg
PT09IGdpZCk7DQogICAgICAgICAgICBtZW1iZXJzLmZvckVhY2gobSA9PiB1c2VkLmFkZCgrbS5p
ZCkpOw0KICAgICAgICAgICAgaWYgKG1lbWJlcnMubGVuZ3RoIDwgMikNCiAgICAgICAgICAgICAg
ICBvdXQucHVzaCh7IGtpbmQ6ICdzaW5nbGUnLCBpdGVtczogW21lbWJlcnNbMF0gfHwgY10gfSk7
DQogICAgICAgICAgICBlbHNlDQogICAgICAgICAgICAgICAgb3V0LnB1c2goeyBraW5kOiAnZ3Jv
dXAnLCBnaWQsIGl0ZW1zOiBtZW1iZXJzIH0pOw0KICAgICAgICB9DQogICAgICAgIHJldHVybiBv
dXQ7DQogICAgfQ0KICAgIGZ1bmN0aW9uIF9fcHJlcFBhc3RlKCkgew0KICAgICAgICB0cnkgew0K
ICAgICAgICAgICAgY29uc3QgcyA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzZWFyY2gnKTsN
CiAgICAgICAgICAgIGlmIChzICYmIGRvY3VtZW50LmFjdGl2ZUVsZW1lbnQgPT09IHMpIHRyeSB7
IHMuYmx1cigpOyB9IGNhdGNoIHt9DQogICAgICAgICAgICBpZiAod2luZG93LmdldFNlbGVjdGlv
bikgd2luZG93LmdldFNlbGVjdGlvbigpLnJlbW92ZUFsbFJhbmdlcygpOw0KICAgICAgICB9IGNh
dGNoIHt9DQogICAgfQ0KICAgIGZ1bmN0aW9uIHBhc3RlT25lKGMpIHsNCiAgICAgICAgX19wcmVw
UGFzdGUoKTsNCiAgICAgICAgc2VsZWN0ZWRJZCA9IGMuaWQ7DQogICAgICAgIGlmIChtdWx0aUlk
cy5sZW5ndGgpIGNsZWFyTXVsdGkoKTsNCiAgICAgICAgc3luY0l0ZW1IaWdobGlnaHQoKTsNCiAg
ICAgICAgbWFya1Bhc3RlZExvY2FsKGMuaWQpOw0KICAgICAgICBhaGsoJ3Bhc3RlJywgU3RyaW5n
KGMuaWQpKTsNCiAgICB9DQogICAgZnVuY3Rpb24gb3BlblJlY2VudERpcihwYXRoKSB7DQogICAg
ICAgIGxldCBwID0gU3RyaW5nKHBhdGggfHwgJycpLnRyaW0oKTsNCiAgICAgICAgaWYgKCFwKSBy
ZXR1cm47DQogICAgICAgIGlmICgvXlthLXpBLVpdOiQvLnRlc3QocCkpIHAgKz0gJ1xcJzsNCiAg
ICAgICAgLy8g57uf5LiAIC8g77ya6YG/5YWNIFdlYlZpZXcgaG9zdC9KU09OIOWQg+aOieWPjeaW
nOadoA0KICAgICAgICBjb25zdCB3aXJlID0gcC5yZXBsYWNlKC9cXC9nLCAnLycpOw0KICAgICAg
ICBjb25zdCBzZW5kID0gKCkgPT4gew0KICAgICAgICAgICAgLy8gMSkgcG9zdE1lc3NhZ2Ug5pyA
56iz77yI5LiN6L+bIHN5bmMgQ09N77yJDQogICAgICAgICAgICB0cnkgew0KICAgICAgICAgICAg
ICAgIGlmICh3aW5kb3cuY2hyb21lICYmIGNocm9tZS53ZWJ2aWV3ICYmIHR5cGVvZiBjaHJvbWUu
d2Vidmlldy5wb3N0TWVzc2FnZSA9PT0gJ2Z1bmN0aW9uJykgew0KICAgICAgICAgICAgICAgICAg
ICBjaHJvbWUud2Vidmlldy5wb3N0TWVzc2FnZSgnb3BlbkRpcnwnICsgd2lyZSk7DQogICAgICAg
ICAgICAgICAgICAgIHJldHVybiB0cnVlOw0KICAgICAgICAgICAgICAgIH0NCiAgICAgICAgICAg
IH0gY2F0Y2gge30NCiAgICAgICAgICAgIC8vIDIpIGFzeW5jIGhvc3TvvIjpnZ4gc3luY++8iQ0K
ICAgICAgICAgICAgdHJ5IHsNCiAgICAgICAgICAgICAgICBjb25zdCBob3N0ID0gY2hyb21lLndl
YnZpZXcuaG9zdE9iamVjdHMuYWhrOw0KICAgICAgICAgICAgICAgIGlmIChob3N0ICYmIGhvc3Qu
b3BlbkRpcikgew0KICAgICAgICAgICAgICAgICAgICBQcm9taXNlLnJlc29sdmUoaG9zdC5vcGVu
RGlyKHdpcmUpKS5jYXRjaCgoKSA9PiB7fSk7DQogICAgICAgICAgICAgICAgICAgIHJldHVybiB0
cnVlOw0KICAgICAgICAgICAgICAgIH0NCiAgICAgICAgICAgIH0gY2F0Y2gge30NCiAgICAgICAg
ICAgIC8vIDMpIOacgOWQjuaJjSBzeW5jDQogICAgICAgICAgICB0cnkgeyBhaGsoJ29wZW5EaXIn
LCB3aXJlKTsgcmV0dXJuIHRydWU7IH0gY2F0Y2gge30NCiAgICAgICAgICAgIHJldHVybiBmYWxz
ZTsNCiAgICAgICAgfTsNCiAgICAgICAgLy8g56a75byAIHBvaW50ZXIg5LqL5Lu25qCI5YaN6LCD
77yM6YG/5YWNIFdlYlZpZXcyIOWQjOatpeatu+mUgeWvvOiHtOKAnOeCueS6huayoeWPjeW6lOKA
nQ0KICAgICAgICBzZXRUaW1lb3V0KHNlbmQsIDApOw0KICAgIH0NCiAgICBmdW5jdGlvbiBpc0l0
ZW1DaHJvbWVUYXJnZXQodCkgew0KICAgICAgICByZXR1cm4gISEodCAmJiB0LmNsb3Nlc3QgJiYg
dC5jbG9zZXN0KCcuaS1leHBhbmQtYnRuLCAuaS1zcmMtaWNvLCAubWctc3JjLCAuZmQtYnRuLCAu
ZmQtcGF0aCwgLnJmLXNlZywgYnV0dG9uLCBhLCBpbnB1dCcpKTsNCiAgICB9DQogICAgZnVuY3Rp
b24gYmVnaW5QYXN0ZUZyb21JdGVtKGUsIGMpIHsNCiAgICAgICAgaWYgKGUuYnV0dG9uICE9IG51
bGwgJiYgZS5idXR0b24gIT09IDApIHJldHVybjsNCiAgICAgICAgY29uc3Qgc2VnID0gZS50YXJn
ZXQgJiYgZS50YXJnZXQuY2xvc2VzdCAmJiBlLnRhcmdldC5jbG9zZXN0KCcucmYtc2VnJyk7DQog
ICAgICAgIGlmIChzZWcpIHsNCiAgICAgICAgICAgIGNvbnN0IG9wZW5QYXRoID0gc2VnLl9vcGVu
UGF0aCB8fCBzZWcuZ2V0QXR0cmlidXRlKCdkYXRhLXBhdGgnKSB8fCBzZWcuZGF0YXNldC5vcGVu
UGF0aCB8fCAnJzsNCiAgICAgICAgICAgIGlmIChvcGVuUGF0aCkgew0KICAgICAgICAgICAgICAg
IGUucHJldmVudERlZmF1bHQoKTsNCiAgICAgICAgICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigp
Ow0KICAgICAgICAgICAgICAgIG9wZW5SZWNlbnREaXIob3BlblBhdGgpOw0KICAgICAgICAgICAg
ICAgIHJldHVybjsNCiAgICAgICAgICAgIH0NCiAgICAgICAgfQ0KICAgICAgICBpZiAoZS50YXJn
ZXQgJiYgZS50YXJnZXQuY2xvc2VzdCAmJiBlLnRhcmdldC5jbG9zZXN0KCcucmYtcGF0aCcpKQ0K
ICAgICAgICAgICAgcmV0dXJuOw0KICAgICAgICBpZiAoaXNJdGVtQ2hyb21lVGFyZ2V0KGUudGFy
Z2V0KSkgcmV0dXJuOw0KICAgICAgICBpZiAobm9ybVR5cGUoYy50eXBlKSA9PT0gJ3JlY2VudCcp
IHsNCiAgICAgICAgICAgIGFjdGl2YXRlQ2xpcEl0ZW0oYyk7DQogICAgICAgICAgICByZXR1cm47
DQogICAgICAgIH0NCiAgICAgICAgaWYgKGhhbmRsZUl0ZW1DbGljayhlLCBjKSkNCiAgICAgICAg
ICAgIHJldHVybjsNCiAgICAgICAgX19wcmVwUGFzdGUoKTsNCiAgICAgICAgc2VsZWN0ZWRJZCA9
IGMuaWQ7DQogICAgICAgIHJhbmdlQW5jaG9ySWQgPSBjLmlkOw0KICAgICAgICAgICAgaWYgKG11
bHRpSWRzLmxlbmd0aCA+IDAgJiYgbXVsdGlJZHMuaW5jbHVkZXMoK2MuaWQpKSB7DQogICAgICAg
ICAgICBjb25zdCBpZHMgPSBtdWx0aUlkcy5zbGljZSgpOw0KICAgICAgICAgICAgY2xlYXJNdWx0
aSgpOw0KICAgICAgICAgICAgbWFya1Bhc3RlZExvY2FsKGlkcyk7DQogICAgICAgICAgICBwYXN0
ZU1hbnlXaXRoU2VwKGlkcyk7DQogICAgICAgICAgICByZXR1cm47DQogICAgICAgIH0NCiAgICAg
ICAgaWYgKG11bHRpSWRzLmxlbmd0aCkgY2xlYXJNdWx0aSgpOw0KICAgICAgICBzeW5jSXRlbUhp
Z2hsaWdodCgpOw0KICAgICAgICBtYXJrUGFzdGVkTG9jYWwoYy5pZCk7DQogICAgICAgIGFoaygn
cGFzdGUnLCBTdHJpbmcoYy5pZCkpOw0KICAgIH0NCiAgICBmdW5jdGlvbiBtYWtlR3JvdXBJdGVt
KGl0ZW1zLCBpZHgpIHsNCiAgICAgICAgY29uc3QgZWwgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50
KCdkaXYnKTsNCiAgICAgICAgZWwuY2xhc3NOYW1lID0gJ2l0bSBpdC1ncm91cCcNCiAgICAgICAg
ICAgICsgKGl0ZW1zLnNvbWUoYyA9PiArYy5pZCA9PT0gK3NlbGVjdGVkSWQpID8gJyBzZWwnIDog
JycpDQogICAgICAgICAgICArIChpdGVtcy5zb21lKGMgPT4gbXVsdGlJZHMuaW5jbHVkZXMoK2Mu
aWQpKSA/ICcgbXVsdGknIDogJycpOw0KICAgICAgICBlbC5kYXRhc2V0Lmdyb3VwID0gZmF2R3Jv
dXBPZihpdGVtc1swXSkgfHwgJyc7DQogICAgICAgIGVsLmRhdGFzZXQuaWQgPSBpdGVtc1swXS5p
ZDsNCg0KICAgICAgICBjb25zdCBoZWFkID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnZGl2Jyk7
DQogICAgICAgIGhlYWQuY2xhc3NOYW1lID0gJ21nLWhlYWQnOw0KICAgICAgICBoZWFkLmlubmVy
SFRNTCA9ICc8c3BhbiBjbGFzcz0ibWctdGFnIj7lkIjlubY8L3NwYW4+PHNwYW4+JyArIGl0ZW1z
Lmxlbmd0aCArICcg5p2hIMK3IOeCueWHu+WNleadoeeymOi0tDwvc3Bhbj4nOw0KICAgICAgICBl
bC5hcHBlbmRDaGlsZChoZWFkKTsNCg0KICAgICAgICBpdGVtcy5mb3JFYWNoKGMgPT4gew0KICAg
ICAgICAgICAgY29uc3Qgcm93ID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnZGl2Jyk7DQogICAg
ICAgICAgICByb3cuY2xhc3NOYW1lID0gJ21nLXJvdycNCiAgICAgICAgICAgICAgICArICgrc2Vs
ZWN0ZWRJZCA9PT0gK2MuaWQgPyAnIHNlbCcgOiAnJykNCiAgICAgICAgICAgICAgICArIChtdWx0
aUlkcy5pbmNsdWRlcygrYy5pZCkgPyAnIG11bHRpJyA6ICcnKTsNCiAgICAgICAgICAgIHJvdy5k
YXRhc2V0LmlkID0gYy5pZDsNCg0KICAgICAgICAgICAgY29uc3QgdG9wID0gZG9jdW1lbnQuY3Jl
YXRlRWxlbWVudCgnZGl2Jyk7DQogICAgICAgICAgICB0b3AuY2xhc3NOYW1lID0gJ21nLXJvdy10
b3AnOw0KICAgICAgICAgICAgY29uc3QgbWFpbiA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2Rp
dicpOw0KICAgICAgICAgICAgbWFpbi5jbGFzc05hbWUgPSAnbWctcm93LW1haW4nOw0KDQogICAg
ICAgICAgICBjb25zdCB0aXRsZSA9IFN0cmluZyhjLmZhdlRpdGxlIHx8ICcnKS50cmltKCk7DQog
ICAgICAgICAgICBpZiAodGl0bGUpIHsNCiAgICAgICAgICAgICAgICBjb25zdCB0ID0gZG9jdW1l
bnQuY3JlYXRlRWxlbWVudCgnZGl2Jyk7DQogICAgICAgICAgICAgICAgdC5jbGFzc05hbWUgPSAn
bWctdGl0bGUnOw0KICAgICAgICAgICAgICAgIHNldEhsVGV4dCh0LCB0aXRsZSk7DQogICAgICAg
ICAgICAgICAgbWFpbi5hcHBlbmRDaGlsZCh0KTsNCiAgICAgICAgICAgIH0NCiAgICAgICAgICAg
IGNvbnN0IGJvZHkgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsNCiAgICAgICAgICAg
IGJvZHkuY2xhc3NOYW1lID0gJ21nLWJvZHknICsgKG5vcm1UeXBlKGMudHlwZSkgPT09ICdpbWFn
ZScgPyAnIGltZycgOiAnJyk7DQogICAgICAgICAgICBzZXRIbFRleHQoYm9keSwgY2xpcENvbnRl
bnRQcmV2aWV3KGMpKTsNCiAgICAgICAgICAgIG1haW4uYXBwZW5kQ2hpbGQoYm9keSk7DQogICAg
ICAgICAgICB0b3AuYXBwZW5kQ2hpbGQobWFpbik7DQoNCiAgICAgICAgICAgIGNvbnN0IHNyY0lj
byA9IFN0cmluZyhjLnNyY0ljb24gfHwgJycpOw0KICAgICAgICAgICAgY29uc3Qgc3JjRXhlID0g
U3RyaW5nKGMuc3JjRXhlIHx8ICcnKTsNCiAgICAgICAgICAgIGNvbnN0IHNyY1RpdGxlID0gU3Ry
aW5nKGMuc3JjVGl0bGUgfHwgJycpOw0KICAgICAgICAgICAgaWYgKHNyY0ljbykgew0KICAgICAg
ICAgICAgICAgIGNvbnN0IGltZyA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2ltZycpOw0KICAg
ICAgICAgICAgICAgIGltZy5jbGFzc05hbWUgPSAnbWctc3JjJzsNCiAgICAgICAgICAgICAgICBp
bWcuc3JjID0gU1RPUkVfQkFTRSArIGVuY29kZVVSSUNvbXBvbmVudChzcmNJY28pOw0KICAgICAg
ICAgICAgICAgIGltZy5hbHQgPSAnJzsNCiAgICAgICAgICAgICAgICBjb25zdCB0aXBUeHQgPSBz
cmNUaXRsZSB8fCBzcmNFeGUgfHwgJ+adpea6kCc7DQogICAgICAgICAgICAgICAgaW1nLnRpdGxl
ID0gdGlwVHh0Ow0KICAgICAgICAgICAgICAgIGltZy5vbmNsaWNrID0gZSA9PiB7IGUucHJldmVu
dERlZmF1bHQoKTsgZS5zdG9wUHJvcGFnYXRpb24oKTsgc2hvd1NyY1RpcChpbWcsIHRpcFR4dCk7
IH07DQogICAgICAgICAgICAgICAgdG9wLmFwcGVuZENoaWxkKGltZyk7DQogICAgICAgICAgICB9
DQogICAgICAgICAgICByb3cuYXBwZW5kQ2hpbGQodG9wKTsNCg0KICAgICAgICAgICAgcm93Lm9u
cG9pbnRlcmRvd24gPSBlID0+IHsNCiAgICAgICAgICAgICAgICBpZiAoZS5idXR0b24gIT09IDAp
IHJldHVybjsNCiAgICAgICAgICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOw0KICAgICAgICAg
ICAgICAgIGJlZ2luUGFzdGVGcm9tSXRlbShlLCBjKTsNCiAgICAgICAgICAgIH07DQogICAgICAg
ICAgICByb3cub25jb250ZXh0bWVudSA9IGUgPT4gew0KICAgICAgICAgICAgICAgIGUucHJldmVu
dERlZmF1bHQoKTsNCiAgICAgICAgICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOw0KICAgICAg
ICAgICAgICAgIHNlbGVjdGVkSWQgPSBjLmlkOw0KICAgICAgICAgICAgICAgIHNob3dDdHgoZS5j
bGllbnRYLCBlLmNsaWVudFksIGMpOw0KICAgICAgICAgICAgfTsNCiAgICAgICAgICAgIGVsLmFw
cGVuZENoaWxkKHJvdyk7DQogICAgICAgIH0pOw0KDQogICAgICAgIGVsLm9uY29udGV4dG1lbnUg
PSBlID0+IHsNCiAgICAgICAgICAgIGlmIChlLnRhcmdldC5jbG9zZXN0KCcubWctcm93JykpIHJl
dHVybjsNCiAgICAgICAgICAgIGUucHJldmVudERlZmF1bHQoKTsNCiAgICAgICAgICAgIHNlbGVj
dGVkSWQgPSBpdGVtc1swXS5pZDsNCiAgICAgICAgICAgIHNob3dDdHgoZS5jbGllbnRYLCBlLmNs
aWVudFksIGl0ZW1zWzBdKTsNCiAgICAgICAgfTsNCiAgICAgICAgcmV0dXJuIGVsOw0KICAgIH0N
Cg0KDQogICAgZnVuY3Rpb24gYnVpbGRSZWNlbnRQYXRoQ3J1bWJzKGNvbnRhaW5lciwgZnVsbFBh
dGgpIHsNCiAgICAgICAgaWYgKCFjb250YWluZXIpIHJldHVybjsNCiAgICAgICAgY29udGFpbmVy
LnF1ZXJ5U2VsZWN0b3JBbGwoJy5yZi1zZWcsIC5yZi1zZXAnKS5mb3JFYWNoKG4gPT4gbi5yZW1v
dmUoKSk7DQogICAgICAgIGNvbnN0IHJhdyA9IFN0cmluZyhmdWxsUGF0aCB8fCAnJykucmVwbGFj
ZSgvXC8vZywgJ1xcJykucmVwbGFjZSgvXFwrJC8sICcnKTsNCiAgICAgICAgaWYgKCFyYXcpIHJl
dHVybjsNCiAgICAgICAgY29uc3QgdW5jID0gcmF3LnN0YXJ0c1dpdGgoJ1xcXFwnKTsNCiAgICAg
ICAgbGV0IHJlc3QgPSB1bmMgPyByYXcuc2xpY2UoMikgOiByYXc7DQogICAgICAgIGNvbnN0IHBh
cnRzID0gcmVzdC5zcGxpdCgnXFwnKS5maWx0ZXIoQm9vbGVhbik7DQogICAgICAgIGNvbnN0IGFk
ZFNlZyA9IChsYWJlbCwgb3BlblBhdGgpID0+IHsNCiAgICAgICAgICAgIGlmIChjb250YWluZXIu
cXVlcnlTZWxlY3RvcignLnJmLXNlZywgLnJmLXNlcCcpKSB7DQogICAgICAgICAgICAgICAgY29u
c3Qgc2VwID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnc3BhbicpOw0KICAgICAgICAgICAgICAg
IHNlcC5jbGFzc05hbWUgPSAncmYtc2VwJzsNCiAgICAgICAgICAgICAgICBzZXAudGV4dENvbnRl
bnQgPSAnXFwnOw0KICAgICAgICAgICAgICAgIGNvbnRhaW5lci5hcHBlbmRDaGlsZChzZXApOw0K
ICAgICAgICAgICAgfQ0KICAgICAgICAgICAgLy8gYnV0dG9u77ya5ZG95Lit5pu056iz77yM5LiN
6KKrIGFwcC1yZWdpb24gLyDniLbnuqcgcG9pbnRlciDlkIPmjokNCiAgICAgICAgICAgIGNvbnN0
IHNlZyA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2J1dHRvbicpOw0KICAgICAgICAgICAgc2Vn
LnR5cGUgPSAnYnV0dG9uJzsNCiAgICAgICAgICAgIHNlZy5jbGFzc05hbWUgPSAncmYtc2VnJzsN
CiAgICAgICAgICAgIHNldEhsVGV4dChzZWcsIGxhYmVsKTsNCiAgICAgICAgICAgIHNlZy50aXRs
ZSA9ICfmiZPlvIA6ICcgKyBvcGVuUGF0aDsNCiAgICAgICAgICAgIHNlZy5zZXRBdHRyaWJ1dGUo
J2RhdGEtcGF0aCcsIG9wZW5QYXRoLnJlcGxhY2UoL1xcL2csICcvJykpOw0KICAgICAgICAgICAg
c2VnLl9vcGVuUGF0aCA9IG9wZW5QYXRoOw0KICAgICAgICAgICAgc2VnLmFkZEV2ZW50TGlzdGVu
ZXIoJ2NsaWNrJywgZSA9PiB7DQogICAgICAgICAgICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOw0K
ICAgICAgICAgICAgICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7DQogICAgICAgICAgICAgICAgb3Bl
blJlY2VudERpcihvcGVuUGF0aCk7DQogICAgICAgICAgICB9LCB0cnVlKTsNCiAgICAgICAgICAg
IHNlZy5hZGRFdmVudExpc3RlbmVyKCdwb2ludGVyZG93bicsIGUgPT4gew0KICAgICAgICAgICAg
ICAgIGlmIChlLmJ1dHRvbiAhPT0gMCkgcmV0dXJuOw0KICAgICAgICAgICAgICAgIGUucHJldmVu
dERlZmF1bHQoKTsNCiAgICAgICAgICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOw0KICAgICAg
ICAgICAgICAgIG9wZW5SZWNlbnREaXIob3BlblBhdGgpOw0KICAgICAgICAgICAgfSwgdHJ1ZSk7
DQogICAgICAgICAgICBjb250YWluZXIuYXBwZW5kQ2hpbGQoc2VnKTsNCiAgICAgICAgfTsNCiAg
ICAgICAgaWYgKCFwYXJ0cy5sZW5ndGgpIHsNCiAgICAgICAgICAgIGFkZFNlZyhyYXcsIHJhdyk7
DQogICAgICAgICAgICByZXR1cm47DQogICAgICAgIH0NCiAgICAgICAgbGV0IGFjYyA9IHVuYyA/
ICdcXFxcJyArIHBhcnRzWzBdIDogcGFydHNbMF07DQogICAgICAgIGlmICghdW5jICYmIC9eW2Et
ekEtWl06JC8udGVzdChwYXJ0c1swXSkpDQogICAgICAgICAgICBhY2MgPSBwYXJ0c1swXSArICdc
XCc7DQogICAgICAgIGFkZFNlZyhwYXJ0c1swXSwgYWNjKTsNCiAgICAgICAgZm9yIChsZXQgaSA9
IDE7IGkgPCBwYXJ0cy5sZW5ndGg7IGkrKykgew0KICAgICAgICAgICAgYWNjID0gYWNjLnJlcGxh
Y2UoL1xcKyQvLCAnJykgKyAnXFwnICsgcGFydHNbaV07DQogICAgICAgICAgICBhZGRTZWcocGFy
dHNbaV0sIGFjYyk7DQogICAgICAgIH0NCiAgICB9DQoNCiAgICBmdW5jdGlvbiBhY3RpdmF0ZUNs
aXBJdGVtKGMpIHsNCiAgICAgICAgaWYgKCFjKSByZXR1cm47DQogICAgICAgIGlmIChub3JtVHlw
ZShjLnR5cGUpID09PSAncmVjZW50Jykgew0KICAgICAgICAgICAgX19wcmVwUGFzdGUoKTsNCiAg
ICAgICAgICAgIHNlbGVjdGVkSWQgPSBjLmlkOw0KICAgICAgICAgICAgaWYgKG11bHRpSWRzLmxl
bmd0aCkgY2xlYXJNdWx0aSgpOw0KICAgICAgICAgICAgc3luY0l0ZW1IaWdobGlnaHQoKTsNCiAg
ICAgICAgICAgIGFoaygncGFzdGUnLCBTdHJpbmcoYy5pZCkpOw0KICAgICAgICAgICAgcmV0dXJu
Ow0KICAgICAgICB9DQogICAgICAgIHBhc3RlT25lKGMpOw0KICAgIH0NCiAgICBmdW5jdGlvbiBt
YWtlSXRlbShjLCBpZHgpIHsNCiAgICAgICAgY29uc3QgdHlwZSAgID0gbm9ybVR5cGUoYy50eXBl
KTsNCiAgICAgICAgY29uc3QgcGlubmVkID0gaXNQaW5uZWQoYyk7DQogICAgICAgIGNvbnN0IHBh
c3RlZCA9IGlzUGFzdGVkKGMpOw0KICAgICAgICBjb25zdCBlbCAgICAgPSBkb2N1bWVudC5jcmVh
dGVFbGVtZW50KCdkaXYnKTsNCiAgICAgICAgZWwuY2xhc3NOYW1lICA9ICdpdG0nDQogICAgICAg
ICAgICArIChzZWxlY3RlZElkID09IGMuaWQgPyAnIHNlbCcgOiAnJykNCiAgICAgICAgICAgICsg
KG11bHRpSWRzLmluY2x1ZGVzKCtjLmlkKSA/ICcgbXVsdGknIDogJycpOw0KICAgICAgICBlbC5k
YXRhc2V0LmlkID0gYy5pZDsNCiAgICAgICAgY29uc3QgcWcgPSBOdW1iZXIoYy5xdWV1ZUdyb3Vw
KSB8fCAwOw0KICAgICAgICBpZiAocWcgPiAwKSB7DQogICAgICAgICAgICBlbC5jbGFzc0xpc3Qu
YWRkKCdxLW1lbWJlcicpOw0KICAgICAgICAgICAgZWwuZGF0YXNldC5xZyA9IFN0cmluZyhxZyk7
DQogICAgICAgICAgICBlbC5kYXRhc2V0LnFpID0gU3RyaW5nKE51bWJlcihjLnF1ZXVlSW5kZXgp
IHx8IDApOw0KICAgICAgICAgICAgaWYgKHBhc3RlZCkgZWwuY2xhc3NMaXN0LmFkZCgncS1kb25l
Jyk7DQogICAgICAgICAgICBjb25zdCByYWlsID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnc3Bh
bicpOw0KICAgICAgICAgICAgcmFpbC5jbGFzc05hbWUgPSAncS1yYWlsJzsNCiAgICAgICAgICAg
IGNvbnN0IGRvdCA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ3NwYW4nKTsNCiAgICAgICAgICAg
IGRvdC5jbGFzc05hbWUgPSAncS1kb3QnOw0KICAgICAgICAgICAgZG90LnRpdGxlID0gcGFzdGVk
ID8gJ+mYn+WIl+W3sueymOi0tCcgOiAn57KY6LS06Zif5YiXJzsNCiAgICAgICAgICAgIGVsLmFw
cGVuZENoaWxkKHJhaWwpOw0KICAgICAgICAgICAgZWwuYXBwZW5kQ2hpbGQoZG90KTsNCiAgICAg
ICAgfQ0KDQogICAgICAgIGNvbnN0IGljbyAgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYn
KTsNCiAgICAgICAgY29uc3QgYm9keSA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOw0K
ICAgICAgICBib2R5LmNsYXNzTmFtZSA9ICdpLWJvZHknOw0KDQogICAgICAgIGlmICh0eXBlID09
PSAnaW1hZ2UnKSB7DQogICAgICAgICAgICBpY28uY2xhc3NOYW1lID0gJ2ktaWNvIGltYWdlJzsN
CiAgICAgICAgICAgIGljby5pbm5lckhUTUwgPSBTVkcuaW1hZ2U7DQogICAgICAgICAgICBiaW5k
SW1nSG92ZXJQcmV2aWV3KGljbywgYy5pZCwgYy5pbWdGaWxlKTsNCiAgICAgICAgICAgIGNvbnN0
IHdyYXAgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsNCiAgICAgICAgICAgIHdyYXAu
Y2xhc3NOYW1lID0gJ2ktdGh1bWItd3JhcCc7DQogICAgICAgICAgICBjb25zdCBpbWcgID0gZG9j
dW1lbnQuY3JlYXRlRWxlbWVudCgnaW1nJyk7DQogICAgICAgICAgICBpbWcuY2xhc3NOYW1lID0g
J2ktdGh1bWInOw0KICAgICAgICAgICAgaW1nLmFsdCA9ICcnOw0KICAgICAgICAgICAgY29uc3Qg
ZmlsZSA9IFN0cmluZyhjLmltZ0ZpbGUgfHwgJycpOw0KICAgICAgICAgICAgbGV0IGZhbGxiYWNr
ID0gU3RyaW5nKGMuZGF0YSB8fCAnJyk7DQogICAgICAgICAgICAvLyBOZXZlciBzeW5jLWNhbGwg
QUhLIHRodW1iIGhlcmUg4oCUIGZyZWV6ZXMgdGFiIHN3aXRjaGVzOyBQdXNoU3RvcmVUaHVtYnMg
ZmlsbHMgYXN5bmMNCiAgICAgICAgICAgIGlmICghZmFsbGJhY2suc3RhcnRzV2l0aCgnZGF0YTon
KSAmJiB0aHVtYkNhY2hlLmhhcyhTdHJpbmcoYy5pZCkpKQ0KICAgICAgICAgICAgICAgIGZhbGxi
YWNrID0gU3RyaW5nKHRodW1iQ2FjaGUuZ2V0KFN0cmluZyhjLmlkKSkpOw0KICAgICAgICAgICAg
aW1nLm9ubG9hZCA9ICgpID0+IHsNCiAgICAgICAgICAgICAgICBjb25zdCBtdyA9IHdyYXAuY2xp
ZW50V2lkdGggfHwgMzAwOw0KICAgICAgICAgICAgICAgIGNvbnN0IG53ID0gaW1nLm5hdHVyYWxX
aWR0aCAgfHwgMDsNCiAgICAgICAgICAgICAgICBjb25zdCBuaCA9IGltZy5uYXR1cmFsSGVpZ2h0
IHx8IDA7DQogICAgICAgICAgICAgICAgaWYgKCFudyB8fCAhbmgpIHJldHVybjsNCiAgICAgICAg
ICAgICAgICBjb25zdCBzY2FsZSA9IE1hdGgubWluKDEsIDE4MCAvIG5oLCBtdyAvIG53KTsNCiAg
ICAgICAgICAgICAgICBpbWcuc3R5bGUud2lkdGggID0gTWF0aC5yb3VuZChudyAqIHNjYWxlKSAr
ICdweCc7DQogICAgICAgICAgICAgICAgaW1nLnN0eWxlLmhlaWdodCA9IE1hdGgucm91bmQobmgg
KiBzY2FsZSkgKyAncHgnOw0KICAgICAgICAgICAgfTsNCiAgICAgICAgICAgIGJpbmRTdG9yZVRo
dW1iKGltZywgZmlsZSwgYy5pZCwgZmFsbGJhY2spOw0KICAgICAgICAgICAgd3JhcC5hcHBlbmRD
aGlsZChpbWcpOw0KICAgICAgICAgICAgY29uc3QgbWV0YSA9IGRvY3VtZW50LmNyZWF0ZUVsZW1l
bnQoJ2RpdicpOw0KICAgICAgICAgICAgbWV0YS5jbGFzc05hbWUgPSAnaS1tZXRhJzsNCiAgICAg
ICAgICAgIG1ldGEuaW5uZXJIVE1MICA9IGA8c3BhbiBjbGFzcz0iaS10aW1lIj4ke2FnbyhjLnRp
bWUpfTwvc3Bhbj4ke21ldGFDZW50ZXJIdG1sKGZhbHNlKX08ZGl2IGNsYXNzPSJpLW1ldGEtcmln
aHQiPiR7Yy53aWR0aCA/IGA8c3BhbiBjbGFzcz0iaS10YWciPiR7Yy53aWR0aH3DlyR7Yy5oZWln
aHR9IHB4PC9zcGFuPmAgOiAnJ308L2Rpdj5gOw0KICAgICAgICAgICAgYm9keS5hcHBlbmRDaGls
ZCh3cmFwKTsNCiAgICAgICAgICAgIGJvZHkuYXBwZW5kQ2hpbGQobWV0YSk7DQogICAgICAgIH0g
ZWxzZSBpZiAodHlwZSA9PT0gJ3JlY2VudCcpIHsNCiAgICAgICAgICAgIGljby5jbGFzc05hbWUg
PSAnaS1pY28gZmlsZSBmdC1kaXInOw0KICAgICAgICAgICAgaWNvLmlubmVySFRNTCA9IFNWRy5m
b2xkZXI7DQogICAgICAgICAgICBpZiAocGlubmVkKSBlbC5jbGFzc0xpc3QuYWRkKCdyZi1maXhl
ZCcpOw0KICAgICAgICAgICAgY29uc3QgcGF0aCA9IFN0cmluZyhjLmRhdGEgfHwgYy5wcmV2aWV3
IHx8ICcnKTsNCiAgICAgICAgICAgIGNvbnN0IGNydW1icyA9IGRvY3VtZW50LmNyZWF0ZUVsZW1l
bnQoJ2RpdicpOw0KICAgICAgICAgICAgY3J1bWJzLmNsYXNzTmFtZSA9ICdyZi1wYXRoJzsNCiAg
ICAgICAgICAgIGJ1aWxkUmVjZW50UGF0aENydW1icyhjcnVtYnMsIHBhdGgpOw0KICAgICAgICAg
ICAgLy8g5Zu65a6a5qCH6K6w5Y+q5pS+IG1ldGEg5Y+z5L6n77yM5LiN5oyh6Lev5b6EDQogICAg
ICAgICAgICBjb25zdCBtZXRhID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnZGl2Jyk7DQogICAg
ICAgICAgICBtZXRhLmNsYXNzTmFtZSA9ICdpLW1ldGEnOw0KICAgICAgICAgICAgbWV0YS5pbm5l
ckhUTUwgPQ0KICAgICAgICAgICAgICAgIGA8c3BhbiBjbGFzcz0iaS10aW1lIj4ke2FnbyhjLnRp
bWUpfTwvc3Bhbj5gICsNCiAgICAgICAgICAgICAgICBtZXRhQ2VudGVySHRtbChmYWxzZSkgKw0K
ICAgICAgICAgICAgICAgIGA8ZGl2IGNsYXNzPSJpLW1ldGEtcmlnaHQiPiR7cGlubmVkID8gJzxz
cGFuIGNsYXNzPSJyZi1waW4tdGFnIiB0aXRsZT0i5bey5Zu65a6a77yM5LiN5Lya6KKr5reY5rGw
Ij7lm7rlrpo8L3NwYW4+JyA6ICcnfTwvZGl2PmA7DQogICAgICAgICAgICBib2R5LmFwcGVuZENo
aWxkKGNydW1icyk7DQogICAgICAgICAgICBib2R5LmFwcGVuZENoaWxkKG1ldGEpOw0KICAgICAg
ICB9IGVsc2UgaWYgKHR5cGUgPT09ICdmaWxlJykgew0KICAgICAgICAgICAgY29uc3QgZmlsZXMg
PSBTdHJpbmcoYy5wcmV2aWV3IHx8IGMuZGF0YSB8fCAnJykuc3BsaXQoL1xyP1xuLykuZmlsdGVy
KEJvb2xlYW4pOw0KICAgICAgICAgICAgY29uc3QgaW1hZ2VQYXRocyA9IGZpbGVzLmZpbHRlcihm
ID0+IGlzSW1hZ2VFeHQoZmlsZUV4dChmKSkpOw0KICAgICAgICAgICAgY29uc3QgaWMgICAgPSBp
Y29uRm9yRmlsZXMoZmlsZXMpOw0KICAgICAgICAgICAgaWNvLmNsYXNzTmFtZSA9ICdpLWljbyAn
ICsgaWMuY2xzOw0KICAgICAgICAgICAgaWNvLmlubmVySFRNTCA9IGljLnN2ZzsNCg0KICAgICAg
ICAgICAgbGV0IHRodW1iRmlsZSA9IFN0cmluZyhjLmltZ0ZpbGUgfHwgJycpOw0KICAgICAgICAg
ICAgLyogZW5zdXJlRmlsZUltZyBkZWZlcnJlZDogYXZvaWQgc3luYyBmcmVlemUgb24gZmlsZSB0
YWIgKi8NCg0KICAgICAgICAgICAgLy8gSW1hZ2UtZm9ybWF0IGZpbGVzOiBzYW1lIHRodW1ibmFp
bCBydWxlcyBhcyBzY3JlZW5zaG90IGNsaXBzDQogICAgICAgICAgICBpZiAodGh1bWJGaWxlIHx8
IGltYWdlUGF0aHMubGVuZ3RoKSB7DQogICAgICAgICAgICAgICAgY29uc3Qgd3JhcCA9IGRvY3Vt
ZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOw0KICAgICAgICAgICAgICAgIHdyYXAuY2xhc3NOYW1l
ID0gJ2ktdGh1bWItd3JhcCc7DQogICAgICAgICAgICAgICAgY29uc3QgaW1nICA9IGRvY3VtZW50
LmNyZWF0ZUVsZW1lbnQoJ2ltZycpOw0KICAgICAgICAgICAgICAgIGltZy5jbGFzc05hbWUgPSAn
aS10aHVtYic7DQogICAgICAgICAgICAgICAgaW1nLmFsdCA9ICcnOw0KICAgICAgICAgICAgICAg
IGltZy5vbmxvYWQgPSAoKSA9PiB7DQogICAgICAgICAgICAgICAgICAgIGNvbnN0IG13ID0gd3Jh
cC5jbGllbnRXaWR0aCB8fCAzMDA7DQogICAgICAgICAgICAgICAgICAgIGNvbnN0IG53ID0gaW1n
Lm5hdHVyYWxXaWR0aCAgfHwgMDsNCiAgICAgICAgICAgICAgICAgICAgY29uc3QgbmggPSBpbWcu
bmF0dXJhbEhlaWdodCB8fCAwOw0KICAgICAgICAgICAgICAgICAgICBpZiAoIW53IHx8ICFuaCkg
cmV0dXJuOw0KICAgICAgICAgICAgICAgICAgICBjb25zdCBzY2FsZSA9IE1hdGgubWluKDEsIDE4
MCAvIG5oLCBtdyAvIG53KTsNCiAgICAgICAgICAgICAgICAgICAgaW1nLnN0eWxlLndpZHRoICA9
IE1hdGgucm91bmQobncgKiBzY2FsZSkgKyAncHgnOw0KICAgICAgICAgICAgICAgICAgICBpbWcu
c3R5bGUuaGVpZ2h0ID0gTWF0aC5yb3VuZChuaCAqIHNjYWxlKSArICdweCc7DQogICAgICAgICAg
ICAgICAgfTsNCiAgICAgICAgICAgIC8qIGVuc3VyZUZpbGVJbWcgZGVmZXJyZWQ6IGF2b2lkIHN5
bmMgZnJlZXplIG9uIGZpbGUgdGFiICovDQogICAgICAgICAgICAgICAgYmluZFN0b3JlVGh1bWIo
aW1nLCB0aHVtYkZpbGUsIGMuaWQsICcnKTsNCiAgICAgICAgICAgICAgICB3cmFwLmFwcGVuZENo
aWxkKGltZyk7DQogICAgICAgICAgICAgICAgYm9keS5hcHBlbmRDaGlsZCh3cmFwKTsNCiAgICAg
ICAgICAgIH0NCg0KICAgICAgICAgICAgY29uc3QgbmFtZSA9IGRvY3VtZW50LmNyZWF0ZUVsZW1l
bnQoJ2RpdicpOw0KICAgICAgICAgICAgbmFtZS5jbGFzc05hbWUgID0gJ2ktbmFtZSc7DQogICAg
ICAgICAgICBzZXRIbFRleHQobmFtZSwgZmlsZXMubWFwKGYgPT4gZi5zcGxpdCgvW1xcL10vKS5w
b3AoKSkuam9pbignXG4nKSB8fCAnKOaWh+S7tiknKTsNCg0KICAgICAgICAgICAgZWwuX2ZpbGVQ
YXRocyA9IGZpbGVzOw0KDQogICAgICAgICAgICBjb25zdCBkZXRhaWwgPSBkb2N1bWVudC5jcmVh
dGVFbGVtZW50KCdkaXYnKTsNCiAgICAgICAgICAgIGRldGFpbC5jbGFzc05hbWUgPSAnaS1maWxl
LWRldGFpbCc7DQoNCiAgICAgICAgICAgIGNvbnN0IG1ldGEgPSBkb2N1bWVudC5jcmVhdGVFbGVt
ZW50KCdkaXYnKTsNCiAgICAgICAgICAgIG1ldGEuY2xhc3NOYW1lID0gJ2ktbWV0YSc7DQogICAg
ICAgICAgICBsZXQgcmlnaHQgPSAnJzsNCiAgICAgICAgICAgIHJpZ2h0ICs9IGA8c3BhbiBjbGFz
cz0iaS10YWciPiR7Yy5maWxlQ291bnQgfHwgZmlsZXMubGVuZ3RoIHx8IDF9IOS4quaWh+S7tjwv
c3Bhbj5gOw0KICAgICAgICAgICAgaWYgKCh0aHVtYkZpbGUgfHwgaW1hZ2VQYXRocy5sZW5ndGgp
ICYmIGMud2lkdGgpDQogICAgICAgICAgICAgICAgcmlnaHQgKz0gYDxzcGFuIGNsYXNzPSJpLXRh
ZyI+JHtjLndpZHRofcOXJHtjLmhlaWdodH0gcHg8L3NwYW4+YDsNCiAgICAgICAgICAgIGNvbnN0
IGV4cGFuZEh0bWwgPSBleHBhbmRDaGV2cm9uKGZhbHNlKTsNCiAgICAgICAgICAgIGNvbnN0IGNv
bGxhcHNlSHRtbCA9IGV4cGFuZENoZXZyb24odHJ1ZSk7DQogICAgICAgICAgICBtZXRhLmlubmVy
SFRNTCA9DQogICAgICAgICAgICAgICAgYDxzcGFuIGNsYXNzPSJpLXRpbWUiPiR7YWdvKGMudGlt
ZSl9PC9zcGFuPmAgKw0KICAgICAgICAgICAgICAgIG1ldGFDZW50ZXJIdG1sKHsgb246IHRydWUs
IGh0bWw6IGV4cGFuZEh0bWwgfSkgKw0KICAgICAgICAgICAgICAgIGA8ZGl2IGNsYXNzPSJpLW1l
dGEtcmlnaHQiPiR7cmlnaHR9PC9kaXY+YDsNCg0KICAgICAgICAgICAgY29uc3QgZXhwQnRuID0g
bWV0YS5xdWVyeVNlbGVjdG9yKCcuaS1leHBhbmQtYnRuJyk7DQogICAgICAgICAgICBsZXQgZGV0
YWlsQnVpbHQgPSBmYWxzZTsNCiAgICAgICAgICAgIGV4cEJ0bi5vbmNsaWNrID0gZSA9PiB7DQog
ICAgICAgICAgICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOw0KICAgICAgICAgICAgICAgIGUuc3Rv
cFByb3BhZ2F0aW9uKCk7DQogICAgICAgICAgICAgICAgY29uc3Qgb3BlbiA9ICFkZXRhaWwuY2xh
c3NMaXN0LmNvbnRhaW5zKCdvbicpOw0KICAgICAgICAgICAgICAgIGlmIChvcGVuICYmICFkZXRh
aWxCdWlsdCkgew0KICAgICAgICAgICAgICAgICAgICBjb25zdCBwYXRoUm93cyA9IGVsLl9wYXRo
Um93cyB8fCBjaGVja0ZpbGVQYXRocyhlbC5fZmlsZVBhdGhzIHx8IGZpbGVzKTsNCiAgICAgICAg
ICAgICAgICAgICAgZmlsbEZpbGVEZXRhaWxQYW5lbChkZXRhaWwsIHBhdGhSb3dzKTsNCiAgICAg
ICAgICAgICAgICAgICAgZGV0YWlsQnVpbHQgPSB0cnVlOw0KICAgICAgICAgICAgICAgIH0NCiAg
ICAgICAgICAgICAgICBkZXRhaWwuY2xhc3NMaXN0LnRvZ2dsZSgnb24nLCBvcGVuKTsNCiAgICAg
ICAgICAgICAgICBpZiAob3Blbikgew0KICAgICAgICAgICAgICAgICAgICBkZXRhaWwuc3R5bGUu
bWF4SGVpZ2h0ID0gbGlzdEV4cGFuZE1heFB4KCkgKyAncHgnOw0KICAgICAgICAgICAgICAgICAg
ICBkZXRhaWwuc3R5bGUub3ZlcmZsb3cgPSAnYXV0byc7DQogICAgICAgICAgICAgICAgfSBlbHNl
IHsNCiAgICAgICAgICAgICAgICAgICAgZGV0YWlsLnN0eWxlLm1heEhlaWdodCA9ICcnOw0KICAg
ICAgICAgICAgICAgICAgICBkZXRhaWwuc3R5bGUub3ZlcmZsb3cgPSAnJzsNCiAgICAgICAgICAg
ICAgICB9DQogICAgICAgICAgICAgICAgZXhwQnRuLmlubmVySFRNTCA9IG9wZW4gPyBjb2xsYXBz
ZUh0bWwgOiBleHBhbmRIdG1sOw0KICAgICAgICAgICAgfTsNCg0KICAgICAgICAgICAgYm9keS5h
cHBlbmRDaGlsZChuYW1lKTsNCiAgICAgICAgICAgIGJvZHkuYXBwZW5kQ2hpbGQoZGV0YWlsKTsN
CiAgICAgICAgICAgIGJvZHkuYXBwZW5kQ2hpbGQobWV0YSk7DQogICAgICAgIH0gZWxzZSB7DQog
ICAgICAgICAgICBjb25zdCB1c2VNID0gY2xpcFVzZXNNSWNvbihjKTsNCiAgICAgICAgICAgIGlj
by5jbGFzc05hbWUgPSB1c2VNID8gJ2ktaWNvIG1kJyA6ICdpLWljbyB0ZXh0JzsNCiAgICAgICAg
ICAgIGljby5pbm5lckhUTUwgPSB1c2VNID8gKFNWRy5tZCB8fCBTVkcudGV4dCkgOiBTVkcudGV4
dDsNCiAgICAgICAgICAgIC8qIHBsYWluLWxpc3QtcHJldiAqLw0KICAgICAgICAgICAgLyogcHJl
dmlldy1lbGxpcHNpcyAqLw0KICAgICAgICAgICAgbGV0IHR4dCAgPSBjLnByZXZpZXcgfHwgYy5k
YXRhIHx8ICcnOw0KICAgICAgICAgICAgeyBjb25zdCBfbiA9IE51bWJlcihjLmNoYXJDb3VudCkg
fHwgMDsgaWYgKF9uID4gdHh0Lmxlbmd0aCAmJiB0eHQubGVuZ3RoKSB0eHQgKz0gJy4uLic7IH0N
CiAgICAgICAgICAgIGNvbnN0IHByZXYgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsN
CiAgICAgICAgICAgIHByZXYuY2xhc3NOYW1lICA9ICdpLXByZXYnICsgKGlzVXJsKHR4dCkgPyAn
IHVybCcgOiAnJyk7DQogICAgICAgICAgICBzZXRIbFRleHQocHJldiwgdHh0KTsNCg0KICAgICAg
ICAgICAgY29uc3QgbWV0YSA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOw0KICAgICAg
ICAgICAgbWV0YS5jbGFzc05hbWUgPSAnaS1tZXRhJzsNCg0KICAgICAgICAgICAgY29uc3QgY2hh
cnMgPSBOdW1iZXIoYy5jaGFyQ291bnQpIHx8IDA7DQogICAgICAgICAgICBjb25zdCByaWdodEhU
TUwgPSBgPHNwYW4gY2xhc3M9ImktY2hhcnMiPjxzcGFuIGNsYXNzPSJuIj4ke2NoYXJzfTwvc3Bh
bj4g5a2X56ymPC9zcGFuPmA7DQoNCiAgICAgICAgICAgIG1ldGEuaW5uZXJIVE1MID0NCiAgICAg
ICAgICAgICAgICBgPHNwYW4gY2xhc3M9ImktdGltZSI+JHthZ28oYy50aW1lKX08L3NwYW4+YCAr
DQogICAgICAgICAgICAgICAgbWV0YUNlbnRlckh0bWwoew0KICAgICAgICAgICAgICAgICAgICBv
bjogZmFsc2UsDQogICAgICAgICAgICAgICAgICAgIGh0bWw6IGV4cGFuZENoZXZyb24oZmFsc2Up
DQogICAgICAgICAgICAgICAgfSkgKw0KICAgICAgICAgICAgICAgIGA8ZGl2IGNsYXNzPSJpLW1l
dGEtcmlnaHQgdGV4dC1tZXRhIj4ke3JpZ2h0SFRNTH08L2Rpdj5gOw0KDQogICAgICAgICAgICBi
b2R5LmFwcGVuZENoaWxkKHByZXYpOw0KICAgICAgICAgICAgYm9keS5hcHBlbmRDaGlsZChtZXRh
KTsNCg0KICAgICAgICAgICAgY29uc3QgZXhwQnRuID0gbWV0YS5xdWVyeVNlbGVjdG9yKCcuaS1l
eHBhbmQtYnRuJyk7DQogICAgICAgICAgICBpZiAoZXhwQnRuKSB7DQogICAgICAgICAgICAgICAg
ZXhwQnRuLm9uY2xpY2sgPSBlID0+IHsNCiAgICAgICAgICAgICAgICAgICAgZS5zdG9wUHJvcGFn
YXRpb24oKTsNCiAgICAgICAgICAgICAgICAgICAgY29uc3Qgd2lsbEV4cGFuZCA9ICFwcmV2LmNs
YXNzTGlzdC5jb250YWlucygnZXhwYW5kZWQnKTsNCiAgICAgICAgICAgICAgICAgICAgaWYgKHdp
bGxFeHBhbmQpIHsNCiAgICAgICAgICAgICAgICAgICAgICAgIGFwcGx5RXhwYW5kZWRQcmV2aWV3
KHByZXYsIHR4dCk7DQogICAgICAgICAgICAgICAgICAgICAgICBleHBCdG4uaW5uZXJIVE1MID0g
ZXhwYW5kQ2hldnJvbih0cnVlKTsNCiAgICAgICAgICAgICAgICAgICAgICAgIHRyeSB7IGVsLnNj
cm9sbEludG9WaWV3KHsgYmxvY2s6ICduZWFyZXN0JyB9KTsgfSBjYXRjaCB7fQ0KICAgICAgICAg
ICAgICAgICAgICB9IGVsc2Ugew0KICAgICAgICAgICAgICAgICAgICAgICAgY29sbGFwc2VQcmV2
aWV3KHByZXYsIHR4dCk7DQogICAgICAgICAgICAgICAgICAgICAgICBleHBCdG4uaW5uZXJIVE1M
ID0gZXhwYW5kQ2hldnJvbihmYWxzZSk7DQogICAgICAgICAgICAgICAgICAgIH0NCiAgICAgICAg
ICAgICAgICB9Ow0KICAgICAgICAgICAgICAgIGNvbnN0IGNoZWNrT3ZlcmZsb3cgPSAoKSA9PiB7
DQogICAgICAgICAgICAgICAgICAgIGNvbnN0IHBsYWluTGVuID0gU3RyaW5nKGMucHJldmlldyB8
fCBjLmRhdGEgfHwgJycpLmxlbmd0aDsNCiAgICAgICAgICAgICAgICAgICAgY29uc3QgZnVsbE4g
PSBOdW1iZXIoYy5jaGFyQ291bnQpIHx8IDA7DQogICAgICAgICAgICAgICAgICAgIGNvbnN0IHRy
dW5jID0gZnVsbE4gPiBwbGFpbkxlbjsNCiAgICAgICAgICAgICAgICAgICAgaWYgKHByZXYuc2Ny
b2xsSGVpZ2h0ID4gcHJldi5jbGllbnRIZWlnaHQgKyAyIHx8IHRydW5jKQ0KICAgICAgICAgICAg
ICAgICAgICAgICAgZXhwQnRuLmNsYXNzTGlzdC5hZGQoJ29uJyk7DQogICAgICAgICAgICAgICAg
ICAgIGVsc2UNCiAgICAgICAgICAgICAgICAgICAgICAgIGV4cEJ0bi5jbGFzc0xpc3QucmVtb3Zl
KCdvbicpOw0KICAgICAgICAgICAgICAgIH07DQogICAgICAgICAgICAgICAgcmVxdWVzdEFuaW1h
dGlvbkZyYW1lKGNoZWNrT3ZlcmZsb3cpOw0KICAgICAgICAgICAgICAgIHNldFRpbWVvdXQoY2hl
Y2tPdmVyZmxvdywgODApOw0KICAgICAgICAgICAgfQ0KICAgICAgICB9DQoNCiAgICAgICAgaWYg
KHBpbm5lZCkgew0KICAgICAgICAgICAgZWwuY2xhc3NMaXN0LmFkZCgnaXMtcGlubmVkJyk7DQog
ICAgICAgICAgICAvLyDmnIDov5Hot6/lvoTnlKjjgIzlm7rlrprjgI3moIfnrb7vvJvlhbblroPm
naHnm67lnKjnsbvlnovlm77moIflj7PkuIrop5LmiZPnuqLlv4MNCiAgICAgICAgICAgIGlmICh0
eXBlICE9PSAncmVjZW50Jykgew0KICAgICAgICAgICAgICAgIGNvbnN0IGZhdkJhZGdlID0gZG9j
dW1lbnQuY3JlYXRlRWxlbWVudCgnc3BhbicpOw0KICAgICAgICAgICAgICAgIGZhdkJhZGdlLmNs
YXNzTmFtZSA9ICdpLWZhdic7DQogICAgICAgICAgICAgICAgZmF2QmFkZ2UudGl0bGUgPSAn5bey
5pS26JePJzsNCiAgICAgICAgICAgICAgICBmYXZCYWRnZS5pbm5lckhUTUwgPSBgPHN2ZyB2aWV3
Qm94PSIwIDAgMTYgMTYiIGZpbGw9ImN1cnJlbnRDb2xvciI+PHBhdGggZD0iTTggMTMuNlMyLjQg
MTAuMSAxLjIgNi43Qy40IDQuNSAxLjkgMi40IDQuMSAyLjRjMS4zIDAgMi40LjcgMyAxLjguNi0x
LjEgMS43LTEuOCAzLTEuOCAyLjIgMCAzLjcgMi4xIDIuOSA0LjNDMTMuNiAxMC4xIDggMTMuNiA4
IDEzLjZ6Ii8+PC9zdmc+YDsNCiAgICAgICAgICAgICAgICBpY28uYXBwZW5kQ2hpbGQoZmF2QmFk
Z2UpOw0KICAgICAgICAgICAgfQ0KICAgICAgICB9DQoNCiAgICAgICAgY29uc3QgZmF2VCA9IFN0
cmluZyhjLmZhdlRpdGxlIHx8ICcnKS50cmltKCk7DQogICAgICAgIGlmIChmYXZUKSB7DQogICAg
ICAgICAgICBjb25zdCBmdCA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOw0KICAgICAg
ICAgICAgZnQuY2xhc3NOYW1lID0gJ2ktZmF2LXRpdGxlJyArICh0eXBlID09PSAncmVjZW50JyA/
ICcgcmYtdGl0bGUnIDogJycpOw0KICAgICAgICAgICAgc2V0SGxUZXh0KGZ0LCBmYXZUKTsNCiAg
ICAgICAgICAgIGJvZHkuaW5zZXJ0QmVmb3JlKGZ0LCBib2R5LmZpcnN0Q2hpbGQpOw0KICAgICAg
ICB9DQoNCiAgICAgICAgaWYgKHBhc3RlZCkgew0KICAgICAgICAgICAgZWwuY2xhc3NMaXN0LmFk
ZCgncGFzdGVkJyk7DQogICAgICAgICAgICBjb25zdCBiYWRnZSA9IGRvY3VtZW50LmNyZWF0ZUVs
ZW1lbnQoJ3NwYW4nKTsNCiAgICAgICAgICAgIGJhZGdlLmNsYXNzTmFtZSA9ICdpLXVzZWQnOw0K
ICAgICAgICAgICAgYmFkZ2UudGl0bGUgPSAn5bey57KY6LS0JzsNCiAgICAgICAgICAgIGJhZGdl
LmlubmVySFRNTCA9IGA8c3ZnIHZpZXdCb3g9IjAgMCAxNiAxNiIgZmlsbD0ibm9uZSIgc3Ryb2tl
PSJjdXJyZW50Q29sb3IiIHN0cm9rZS13aWR0aD0iMi40IiBzdHJva2UtbGluZWNhcD0icm91bmQi
IHN0cm9rZS1saW5lam9pbj0icm91bmQiPjxwb2x5bGluZSBwb2ludHM9IjMuNSA4LjUgNi41IDEx
LjUgMTIuNSA0LjUiLz48L3N2Zz5gOw0KICAgICAgICAgICAgaWNvLmFwcGVuZENoaWxkKGJhZGdl
KTsNCiAgICAgICAgfQ0KDQogICAgICAgIGNvbnN0IG51bSA9IGRvY3VtZW50LmNyZWF0ZUVsZW1l
bnQoJ2RpdicpOw0KICAgICAgICBudW0uY2xhc3NOYW1lID0gJ2ktbnVtJzsNCiAgICAgICAgY29u
c3QgbnVtVHh0ID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnc3BhbicpOw0KICAgICAgICBudW1U
eHQudGV4dENvbnRlbnQgPSBpZHg7DQogICAgICAgIG51bS5hcHBlbmRDaGlsZChudW1UeHQpOw0K
ICAgICAgICBjb25zdCBzcmNJY28gPSBTdHJpbmcoYy5zcmNJY29uIHx8ICcnKTsNCiAgICAgICAg
Y29uc3Qgc3JjRXhlID0gU3RyaW5nKGMuc3JjRXhlIHx8ICcnKTsNCiAgICAgICAgY29uc3Qgc3Jj
VGl0bGUgPSBTdHJpbmcoYy5zcmNUaXRsZSB8fCAnJyk7DQogICAgICAgIGlmIChzcmNJY28pIHsN
CiAgICAgICAgICAgIGNvbnN0IGltZyA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2ltZycpOw0K
ICAgICAgICAgICAgaW1nLmNsYXNzTmFtZSA9ICdpLXNyYy1pY28nOw0KICAgICAgICAgICAgaW1n
LnNyYyA9IFNUT1JFX0JBU0UgKyBlbmNvZGVVUklDb21wb25lbnQoc3JjSWNvKTsNCiAgICAgICAg
ICAgIGltZy5hbHQgPSAnJzsNCiAgICAgICAgICAgIGNvbnN0IHRpcFR4dCA9IHNyY1RpdGxlIHx8
IHNyY0V4ZSB8fCAn5p2l5rqQJzsNCiAgICAgICAgICAgIGltZy50aXRsZSA9IHRpcFR4dDsNCiAg
ICAgICAgICAgIGltZy5vbmNsaWNrID0gZSA9PiB7IGUucHJldmVudERlZmF1bHQoKTsgZS5zdG9w
UHJvcGFnYXRpb24oKTsgc2hvd1NyY1RpcChpbWcsIHRpcFR4dCk7IH07DQogICAgICAgICAgICBu
dW0uYXBwZW5kQ2hpbGQoaW1nKTsNCiAgICAgICAgfQ0KDQogICAgICAgIGVsLmFwcGVuZENoaWxk
KGljbyk7DQogICAgICAgIGVsLmFwcGVuZENoaWxkKGJvZHkpOw0KICAgICAgICBlbC5hcHBlbmRD
aGlsZChudW0pOw0KDQogICAgICAgIGVsLm9ucG9pbnRlcmRvd24gPSBlID0+IHsNCiAgICAgICAg
ICAgIGJlZ2luUGFzdGVGcm9tSXRlbShlLCBjKTsNCiAgICAgICAgfTsNCiAgICAgICAgZWwub25j
b250ZXh0bWVudSA9IGUgPT4gew0KICAgICAgICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOw0KICAg
ICAgICAgICAgc2VsZWN0ZWRJZCA9IGMuaWQ7DQogICAgICAgICAgICBzaG93Q3R4KGUuY2xpZW50
WCwgZS5jbGllbnRZLCBjKTsNCiAgICAgICAgfTsNCg0KICAgICAgICByZXR1cm4gZWw7DQogICAg
fQ0KDQogICAgZnVuY3Rpb24gaXRlbUlzUXVldWVEb25lKHJvdykgew0KICAgICAgICBpZiAoIXJv
dykgcmV0dXJuIGZhbHNlOw0KICAgICAgICBpZiAocm93LmNsYXNzTGlzdC5jb250YWlucygncGFz
dGVkJykgfHwgcm93LmNsYXNzTGlzdC5jb250YWlucygncS1kb25lJykpDQogICAgICAgICAgICBy
ZXR1cm4gdHJ1ZTsNCiAgICAgICAgY29uc3QgaWQgPSArcm93LmRhdGFzZXQuaWQ7DQogICAgICAg
IGNvbnN0IGMgPSBhbGxDbGlwcy5maW5kKHggPT4gK3guaWQgPT09IGlkKTsNCiAgICAgICAgcmV0
dXJuICEhKGMgJiYgaXNQYXN0ZWQoYykpOw0KICAgIH0NCg0KICAgIGZ1bmN0aW9uIG1hcmtRdWV1
ZVJhaWxzKCkgew0KICAgICAgICBpZiAoIWxpc3RFbCkgcmV0dXJuOw0KICAgICAgICBjb25zdCBu
b2RlcyA9IFsuLi5saXN0RWwucXVlcnlTZWxlY3RvckFsbCgnLml0bS5xLW1lbWJlcicpXTsNCiAg
ICAgICAgbm9kZXMuZm9yRWFjaChuID0+IG4uY2xhc3NMaXN0LnJlbW92ZSgncS1maXJzdCcsICdx
LWxhc3QnLCAncS1vbmx5JywgJ3EtZG9uZS1saW5rJywgJ3EtcGFzdGVkLW5leHQnKSk7DQogICAg
ICAgIGlmICghbm9kZXMubGVuZ3RoKSByZXR1cm47DQogICAgICAgIC8vIE9ubHkgdmlzdWFsbHkg
YWRqYWNlbnQgcm93cyAoc2FtZSBncm91cCkuIFNraXAgZ2FwcyDigJQgcXVlcnlTZWxlY3RvckFs
bCB3b3VsZCBnbHVlIHRoZW0uDQogICAgICAgIGNvbnN0IHJvd3MgPSBbLi4ubGlzdEVsLmNoaWxk
cmVuXS5maWx0ZXIobiA9PiBuLmNsYXNzTGlzdCAmJiBuLmNsYXNzTGlzdC5jb250YWlucygnaXRt
JykpOw0KICAgICAgICBjb25zdCBydW5zID0gW107DQogICAgICAgIGxldCBydW4gPSBbXTsNCiAg
ICAgICAgY29uc3QgZmx1c2ggPSAoKSA9PiB7IGlmIChydW4ubGVuZ3RoKSB7IHJ1bnMucHVzaChy
dW4pOyBydW4gPSBbXTsgfSB9Ow0KICAgICAgICBmb3IgKGxldCByID0gMDsgciA8IHJvd3MubGVu
Z3RoOyByKyspIHsNCiAgICAgICAgICAgIGNvbnN0IG4gPSByb3dzW3JdOw0KICAgICAgICAgICAg
aWYgKCFuLmNsYXNzTGlzdC5jb250YWlucygncS1tZW1iZXInKSkgeyBmbHVzaCgpOyBjb250aW51
ZTsgfQ0KICAgICAgICAgICAgY29uc3QgZyA9IG4uZGF0YXNldC5xZyB8fCAnJzsNCiAgICAgICAg
ICAgIGlmICghcnVuLmxlbmd0aCB8fCBydW5bMF0uZGF0YXNldC5xZyA9PT0gZykNCiAgICAgICAg
ICAgICAgICBydW4ucHVzaChuKTsNCiAgICAgICAgICAgIGVsc2Ugew0KICAgICAgICAgICAgICAg
IGZsdXNoKCk7DQogICAgICAgICAgICAgICAgcnVuLnB1c2gobik7DQogICAgICAgICAgICB9DQog
ICAgICAgIH0NCiAgICAgICAgZmx1c2goKTsNCiAgICAgICAgZm9yIChjb25zdCBzbGljZSBvZiBy
dW5zKSB7DQogICAgICAgICAgICBpZiAoc2xpY2UubGVuZ3RoID09PSAxKSB7DQogICAgICAgICAg
ICAgICAgc2xpY2VbMF0uY2xhc3NMaXN0LmFkZCgncS1vbmx5Jyk7DQogICAgICAgICAgICB9IGVs
c2Ugew0KICAgICAgICAgICAgICAgIHNsaWNlWzBdLmNsYXNzTGlzdC5hZGQoJ3EtZmlyc3QnKTsN
CiAgICAgICAgICAgICAgICBzbGljZVtzbGljZS5sZW5ndGggLSAxXS5jbGFzc0xpc3QuYWRkKCdx
LWxhc3QnKTsNCiAgICAgICAgICAgIH0NCiAgICAgICAgICAgIGZvciAobGV0IGsgPSAwOyBrIDwg
c2xpY2UubGVuZ3RoOyBrKyspIHsNCiAgICAgICAgICAgICAgICBjb25zdCBkb25lID0gaXRlbUlz
UXVldWVEb25lKHNsaWNlW2tdKTsNCiAgICAgICAgICAgICAgICBzbGljZVtrXS5jbGFzc0xpc3Qu
dG9nZ2xlKCdxLWRvbmUnLCBkb25lKTsNCiAgICAgICAgICAgICAgICBjb25zdCBkb3QgPSBzbGlj
ZVtrXS5xdWVyeVNlbGVjdG9yKCcucS1kb3QnKTsNCiAgICAgICAgICAgICAgICBpZiAoZG90KSBk
b3QudGl0bGUgPSBkb25lID8gJ+mYn+WIl+W3sueymOi0tCcgOiAn57KY6LS06Zif5YiXJzsNCiAg
ICAgICAgICAgICAgICAvLyBHcmVlbiByYWlsIGZvciBldmVyeSBpdGVtIGluIGEgMisgZGVxdWV1
ZWQgcnVuIChpbmNsLiBmaXJzdC9sYXN0IHN0dWJzKQ0KICAgICAgICAgICAgICAgIGNvbnN0IHBy
ZXZEb25lID0gayA+IDAgJiYgaXRlbUlzUXVldWVEb25lKHNsaWNlW2sgLSAxXSk7DQogICAgICAg
ICAgICAgICAgY29uc3QgbmV4dERvbmUgPSBrIDwgc2xpY2UubGVuZ3RoIC0gMSAmJiBpdGVtSXNR
dWV1ZURvbmUoc2xpY2VbayArIDFdKTsNCiAgICAgICAgICAgICAgICBpZiAoZG9uZSAmJiAocHJl
dkRvbmUgfHwgbmV4dERvbmUpKQ0KICAgICAgICAgICAgICAgICAgICBzbGljZVtrXS5jbGFzc0xp
c3QuYWRkKCdxLWRvbmUtbGluaycpOw0KICAgICAgICAgICAgfQ0KICAgICAgICB9DQogICAgfQ0K
DQogICAgY29uc3QgcGF0aFRpcEVsID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3BhdGgtdGlw
Jyk7DQogICAgbGV0IHBhdGhUaXBUaW1lciA9IDA7DQogICAgbGV0IHBhdGhUaXBIaWRlVGltZXIg
PSAwOw0KICAgIGxldCBwYXRoVGlwVG9rZW4gPSAwOw0KICAgIGxldCBwYXRoVGlwQW5jaG9yQnRu
ID0gbnVsbDsNCg0KICAgIGZ1bmN0aW9uIGhpZGVQYXRoVGlwKCkgew0KICAgICAgICBjbGVhclRp
bWVvdXQocGF0aFRpcFRpbWVyKTsNCiAgICAgICAgY2xlYXJUaW1lb3V0KHBhdGhUaXBIaWRlVGlt
ZXIpOw0KICAgICAgICBwYXRoVGlwVG9rZW4rKzsNCiAgICAgICAgaWYgKHBhdGhUaXBBbmNob3JC
dG4pIHsNCiAgICAgICAgICAgIHBhdGhUaXBBbmNob3JCdG4uY2xhc3NMaXN0LnJlbW92ZSgnb24n
KTsNCiAgICAgICAgICAgIHBhdGhUaXBBbmNob3JCdG4gPSBudWxsOw0KICAgICAgICB9DQogICAg
ICAgIGlmIChwYXRoVGlwRWwpIHsNCiAgICAgICAgICAgIHBhdGhUaXBFbC5jbGFzc0xpc3QucmVt
b3ZlKCdvbicpOw0KICAgICAgICAgICAgcGF0aFRpcEVsLnNldEF0dHJpYnV0ZSgnYXJpYS1oaWRk
ZW4nLCAndHJ1ZScpOw0KICAgICAgICB9DQogICAgfQ0KICAgIGZ1bmN0aW9uIHBsYWNlUGF0aFRp
cChhbmNob3JFbCkgew0KICAgICAgICBpZiAoIXBhdGhUaXBFbCB8fCAhYW5jaG9yRWwpIHJldHVy
bjsNCiAgICAgICAgY29uc3QgdGlwID0gcGF0aFRpcEVsOw0KICAgICAgICBjb25zdCBhciA9IGFu
Y2hvckVsLmdldEJvdW5kaW5nQ2xpZW50UmVjdCgpOw0KICAgICAgICBjb25zdCBwYWQgPSA4Ow0K
ICAgICAgICB0aXAuc3R5bGUubGVmdCA9ICcwcHgnOw0KICAgICAgICB0aXAuc3R5bGUudG9wID0g
JzBweCc7DQogICAgICAgIHRpcC5jbGFzc0xpc3QuYWRkKCdvbicpOw0KICAgICAgICBjb25zdCB0
dyA9IHRpcC5vZmZzZXRXaWR0aDsNCiAgICAgICAgY29uc3QgdGggPSB0aXAub2Zmc2V0SGVpZ2h0
Ow0KICAgICAgICBsZXQgbGVmdCA9IGFyLmxlZnQ7DQogICAgICAgIGxldCB0b3AgPSBhci5ib3R0
b20gKyA2Ow0KICAgICAgICBpZiAobGVmdCArIHR3ID4gd2luZG93LmlubmVyV2lkdGggLSBwYWQp
DQogICAgICAgICAgICBsZWZ0ID0gTWF0aC5tYXgocGFkLCB3aW5kb3cuaW5uZXJXaWR0aCAtIHR3
IC0gcGFkKTsNCiAgICAgICAgaWYgKGxlZnQgPCBwYWQpIGxlZnQgPSBwYWQ7DQogICAgICAgIGlm
ICh0b3AgKyB0aCA+IHdpbmRvdy5pbm5lckhlaWdodCAtIHBhZCkNCiAgICAgICAgICAgIHRvcCA9
IE1hdGgubWF4KHBhZCwgYXIudG9wIC0gdGggLSA2KTsNCiAgICAgICAgdGlwLnN0eWxlLmxlZnQg
PSBsZWZ0ICsgJ3B4JzsNCiAgICAgICAgdGlwLnN0eWxlLnRvcCA9IHRvcCArICdweCc7DQogICAg
fQ0KICAgICAgICBmdW5jdGlvbiBjaGVja0ZpbGVQYXRocyhwYXRocykgew0KICAgICAgICBjb25z
dCBsaXN0ID0gKHBhdGhzIHx8IFtdKS5tYXAocCA9PiB7DQogICAgICAgICAgICBsZXQgcGF0aCA9
IFN0cmluZyhwIHx8ICcnKS50cmltKCk7DQogICAgICAgICAgICBpZiAoKHBhdGguc3RhcnRzV2l0
aCgnIicpICYmIHBhdGguZW5kc1dpdGgoJyInKSkgfHwgKHBhdGguc3RhcnRzV2l0aCgiJyIpICYm
IHBhdGguZW5kc1dpdGgoIiciKSkpDQogICAgICAgICAgICAgICAgcGF0aCA9IHBhdGguc2xpY2Uo
MSwgLTEpLnRyaW0oKTsNCiAgICAgICAgICAgIHJldHVybiBwYXRoOw0KICAgICAgICB9KTsNCiAg
ICAgICAgLy8gT25lIGhvc3Qgcm91bmQtdHJpcCBmb3IgdGhlIHdob2xlIGxpc3Qg4oCUIE7DlyBw
YXRoRXhpc3RzIGZyZWV6ZXMgZmlsZSB0YWINCiAgICAgICAgdHJ5IHsNCiAgICAgICAgICAgIGNv
bnN0IHJhdyA9IGFoa1JldCgnY2hlY2tQYXRocycsIGxpc3Quam9pbignXG4nKSk7DQogICAgICAg
ICAgICBpZiAocmF3KSB7DQogICAgICAgICAgICAgICAgY29uc3QgcGFyc2VkID0gdHlwZW9mIHJh
dyA9PT0gJ3N0cmluZycgPyBKU09OLnBhcnNlKHJhdykgOiByYXc7DQogICAgICAgICAgICAgICAg
aWYgKEFycmF5LmlzQXJyYXkocGFyc2VkKSAmJiBwYXJzZWQubGVuZ3RoKSB7DQogICAgICAgICAg
ICAgICAgICAgIHJldHVybiBsaXN0Lm1hcCgocGF0aCwgaSkgPT4gew0KICAgICAgICAgICAgICAg
ICAgICAgICAgY29uc3Qgcm93ID0gcGFyc2VkW2ldIHx8IHt9Ow0KICAgICAgICAgICAgICAgICAg
ICAgICAgcmV0dXJuIHsNCiAgICAgICAgICAgICAgICAgICAgICAgICAgICBwYXRoOiBwYXRoIHx8
IFN0cmluZyhyb3cucGF0aCB8fCAnJyksDQogICAgICAgICAgICAgICAgICAgICAgICAgICAgZXhp
c3RzOiByb3cuZXhpc3RzID09PSB0cnVlIHx8IHJvdy5leGlzdHMgPT09IDEgfHwgcm93LmV4aXN0
cyA9PT0gJzEnLA0KICAgICAgICAgICAgICAgICAgICAgICAgICAgIGlzRGlyOiAhIShyb3cuaXNE
aXIgPT09IHRydWUgfHwgcm93LmlzRGlyID09PSAxIHx8IHJvdy5pc0RpciA9PT0gJzEnKQ0KICAg
ICAgICAgICAgICAgICAgICAgICAgfTsNCiAgICAgICAgICAgICAgICAgICAgfSk7DQogICAgICAg
ICAgICAgICAgfQ0KICAgICAgICAgICAgfQ0KICAgICAgICB9IGNhdGNoIHt9DQogICAgICAgIHJl
dHVybiBsaXN0Lm1hcChwYXRoID0+IHsNCiAgICAgICAgICAgIGlmICghcGF0aCkgcmV0dXJuIHsg
cGF0aCwgZXhpc3RzOiBmYWxzZSwgaXNEaXI6IGZhbHNlIH07DQogICAgICAgICAgICBsZXQgZXhp
c3RzID0gZmFsc2U7DQogICAgICAgICAgICB0cnkgew0KICAgICAgICAgICAgICAgIGNvbnN0IGZs
YWcgPSBTdHJpbmcoYWhrUmV0KCdwYXRoRXhpc3RzJywgcGF0aCkgPz8gJycpLnRyaW0oKS50b0xv
d2VyQ2FzZSgpOw0KICAgICAgICAgICAgICAgIGV4aXN0cyA9IChmbGFnID09PSAnMScgfHwgZmxh
ZyA9PT0gJ3RydWUnKTsNCiAgICAgICAgICAgIH0gY2F0Y2gge30NCiAgICAgICAgICAgIHJldHVy
biB7IHBhdGgsIGV4aXN0cywgaXNEaXI6IGZhbHNlIH07DQogICAgICAgIH0pOw0KICAgIH0NCiAg
ICBsZXQgZ29uZUNoZWNrVGltZXIgPSAwOw0KICAgIGZ1bmN0aW9uIHNjaGVkdWxlRmlsZUdvbmVD
aGVjaygpIHsNCiAgICAgICAgaWYgKGdvbmVDaGVja1RpbWVyKSByZXR1cm47DQogICAgICAgIGdv
bmVDaGVja1RpbWVyID0gc2V0VGltZW91dCgoKSA9PiB7DQogICAgICAgICAgICBnb25lQ2hlY2tU
aW1lciA9IDA7DQogICAgICAgICAgICBjb25zdCBub2RlcyA9IFsuLi5saXN0RWwucXVlcnlTZWxl
Y3RvckFsbCgnLml0bScpXS5maWx0ZXIobiA9PiBuLl9maWxlUGF0aHMgJiYgbi5fZmlsZVBhdGhz
Lmxlbmd0aCk7DQogICAgICAgICAgICBpZiAoIW5vZGVzLmxlbmd0aCkgcmV0dXJuOw0KICAgICAg
ICAgICAgY29uc3QgdW5pcXVlID0gW107DQogICAgICAgICAgICBjb25zdCBzZWVuID0gbmV3IFNl
dCgpOw0KICAgICAgICAgICAgbm9kZXMuZm9yRWFjaChuID0+IHsNCiAgICAgICAgICAgICAgICBu
Ll9maWxlUGF0aHMuZm9yRWFjaChwID0+IHsNCiAgICAgICAgICAgICAgICAgICAgY29uc3QgcGF0
aCA9IFN0cmluZyhwIHx8ICcnKTsNCiAgICAgICAgICAgICAgICAgICAgaWYgKCFwYXRoIHx8IHNl
ZW4uaGFzKHBhdGgpKSByZXR1cm47DQogICAgICAgICAgICAgICAgICAgIHNlZW4uYWRkKHBhdGgp
Ow0KICAgICAgICAgICAgICAgICAgICB1bmlxdWUucHVzaChwYXRoKTsNCiAgICAgICAgICAgICAg
ICB9KTsNCiAgICAgICAgICAgIH0pOw0KICAgICAgICAgICAgY29uc3Qgcm93cyA9IGNoZWNrRmls
ZVBhdGhzKHVuaXF1ZSk7DQogICAgICAgICAgICBjb25zdCBieVBhdGggPSBuZXcgTWFwKCk7DQog
ICAgICAgICAgICByb3dzLmZvckVhY2gociA9PiBieVBhdGguc2V0KFN0cmluZyhyLnBhdGggfHwg
JycpLCByKSk7DQogICAgICAgICAgICBub2Rlcy5mb3JFYWNoKG4gPT4gew0KICAgICAgICAgICAg
ICAgIGNvbnN0IHBhdGhSb3dzID0gbi5fZmlsZVBhdGhzLm1hcChwID0+IHsNCiAgICAgICAgICAg
ICAgICAgICAgY29uc3QgaGl0ID0gYnlQYXRoLmdldChTdHJpbmcocCB8fCAnJykpOw0KICAgICAg
ICAgICAgICAgICAgICByZXR1cm4gaGl0IHx8IHsgcGF0aDogcCwgZXhpc3RzOiB0cnVlLCBpc0Rp
cjogZmFsc2UgfTsNCiAgICAgICAgICAgICAgICB9KTsNCiAgICAgICAgICAgICAgICBuLl9wYXRo
Um93cyA9IHBhdGhSb3dzOw0KICAgICAgICAgICAgICAgIGNvbnN0IGFsbEdvbmUgPSBwYXRoUm93
cy5sZW5ndGggPiAwICYmIHBhdGhSb3dzLmV2ZXJ5KHIgPT4gci5leGlzdHMgPT09IGZhbHNlKTsN
CiAgICAgICAgICAgICAgICBuLmNsYXNzTGlzdC50b2dnbGUoJ2dvbmUnLCBhbGxHb25lKTsNCiAg
ICAgICAgICAgIH0pOw0KICAgICAgICB9LCA0MDApOw0KICAgIH0NCiAgICBmdW5jdGlvbiBmaWxs
RmlsZURldGFpbFBhbmVsKGNvbnRhaW5lciwgcm93cykgew0KICAgICAgICBjb250YWluZXIuaW5u
ZXJIVE1MID0gJyc7DQogICAgICAgIGlmICghcm93cy5sZW5ndGgpIHsNCiAgICAgICAgICAgIGNv
bnN0IGVtcHR5ID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnZGl2Jyk7DQogICAgICAgICAgICBl
bXB0eS5jbGFzc05hbWUgPSAnZmQtcGF0aCc7DQogICAgICAgICAgICBlbXB0eS50ZXh0Q29udGVu
dCA9ICfml6Dot6/lvoQnOw0KICAgICAgICAgICAgY29udGFpbmVyLmFwcGVuZENoaWxkKGVtcHR5
KTsNCiAgICAgICAgICAgIHJldHVybjsNCiAgICAgICAgfQ0KICAgICAgICByb3dzLmZvckVhY2go
ciA9PiB7DQogICAgICAgICAgICBjb25zdCBwYXRoID0gU3RyaW5nKHIucGF0aCB8fCAnJyk7DQog
ICAgICAgICAgICBjb25zdCBtaXNzaW5nID0gci5leGlzdHMgPT09IGZhbHNlOw0KICAgICAgICAg
ICAgY29uc3QgYmxvY2sgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsNCiAgICAgICAg
ICAgIGJsb2NrLmNsYXNzTmFtZSA9ICdmZC1ibG9jayc7DQoNCiAgICAgICAgICAgIGNvbnN0IHBh
dGhFbCA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOw0KICAgICAgICAgICAgcGF0aEVs
LmNsYXNzTmFtZSA9ICdmZC1wYXRoJyArIChtaXNzaW5nID8gJyBkZWFkJyA6ICcgbGl2ZScpOw0K
ICAgICAgICAgICAgcGF0aEVsLnRleHRDb250ZW50ID0gcGF0aCB8fCAnKOepuui3r+W+hCknOw0K
ICAgICAgICAgICAgaWYgKCFtaXNzaW5nKSB7DQogICAgICAgICAgICAgICAgcGF0aEVsLm9uY2xp
Y2sgPSBlID0+IHsNCiAgICAgICAgICAgICAgICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOw0KICAg
ICAgICAgICAgICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOw0KICAgICAgICAgICAgICAgICAg
ICBhaGsoJ29wZW5QYXRoJywgcGF0aCk7DQogICAgICAgICAgICAgICAgfTsNCiAgICAgICAgICAg
IH0NCiAgICAgICAgICAgIGJsb2NrLmFwcGVuZENoaWxkKHBhdGhFbCk7DQoNCiAgICAgICAgICAg
IGNvbnN0IGFjdGlvbnMgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsNCiAgICAgICAg
ICAgIGFjdGlvbnMuY2xhc3NOYW1lID0gJ2ZkLWFjdGlvbnMnOw0KDQogICAgICAgICAgICBjb25z
dCBjb3B5QnRuID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnYnV0dG9uJyk7DQogICAgICAgICAg
ICBjb3B5QnRuLnR5cGUgPSAnYnV0dG9uJzsNCiAgICAgICAgICAgIGNvcHlCdG4uY2xhc3NOYW1l
ID0gJ2ZkLWJ0bic7DQogICAgICAgICAgICBjb3B5QnRuLmlubmVySFRNTCA9ICc8c3BhbiBjbGFz
cz0iZmQtaWNvIj7wn5SXPC9zcGFuPjxzcGFuIGNsYXNzPSJmZC10eHQiPuWkjeWItui3r+W+hDwv
c3Bhbj4nOw0KICAgICAgICAgICAgY29weUJ0bi5vbmNsaWNrID0gZSA9PiB7DQogICAgICAgICAg
ICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOw0KICAgICAgICAgICAgICAgIGUuc3RvcFByb3BhZ2F0
aW9uKCk7DQogICAgICAgICAgICAgICAgYWhrKCdjb3B5UGF0aCcsIHBhdGgpOw0KICAgICAgICAg
ICAgICAgIGNvcHlCdG4ucXVlcnlTZWxlY3RvcignLmZkLXR4dCcpLnRleHRDb250ZW50ID0gJ+W3
suWkjeWItic7DQogICAgICAgICAgICAgICAgY29weUJ0bi5jbGFzc0xpc3QuYWRkKCdvaycpOw0K
ICAgICAgICAgICAgICAgIHNldFRpbWVvdXQoKCkgPT4gew0KICAgICAgICAgICAgICAgICAgICBj
b3B5QnRuLnF1ZXJ5U2VsZWN0b3IoJy5mZC10eHQnKS50ZXh0Q29udGVudCA9ICflpI3liLbot6/l
voQnOw0KICAgICAgICAgICAgICAgICAgICBjb3B5QnRuLmNsYXNzTGlzdC5yZW1vdmUoJ29rJyk7
DQogICAgICAgICAgICAgICAgfSwgMTIwMCk7DQogICAgICAgICAgICB9Ow0KICAgICAgICAgICAg
YWN0aW9ucy5hcHBlbmRDaGlsZChjb3B5QnRuKTsNCg0KICAgICAgICAgICAgY29uc3QgZm9sZGVy
QnRuID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnYnV0dG9uJyk7DQogICAgICAgICAgICBmb2xk
ZXJCdG4udHlwZSA9ICdidXR0b24nOw0KICAgICAgICAgICAgZm9sZGVyQnRuLmNsYXNzTmFtZSA9
ICdmZC1idG4nOw0KICAgICAgICAgICAgZm9sZGVyQnRuLmlubmVySFRNTCA9ICc8c3BhbiBjbGFz
cz0iZmQtaWNvIj7wn5OCPC9zcGFuPjxzcGFuIGNsYXNzPSJmZC10eHQiPuaJk+W8gOaJgOWcqOaW
h+S7tuWkuTwvc3Bhbj4nOw0KICAgICAgICAgICAgZm9sZGVyQnRuLm9uY2xpY2sgPSBlID0+IHsN
CiAgICAgICAgICAgICAgICBlLnByZXZlbnREZWZhdWx0KCk7DQogICAgICAgICAgICAgICAgZS5z
dG9wUHJvcGFnYXRpb24oKTsNCiAgICAgICAgICAgICAgICBhaGsoJ29wZW5Gb2xkZXInLCBwYXRo
KTsNCiAgICAgICAgICAgIH07DQogICAgICAgICAgICBhY3Rpb25zLmFwcGVuZENoaWxkKGZvbGRl
ckJ0bik7DQoNCiAgICAgICAgICAgIGJsb2NrLmFwcGVuZENoaWxkKGFjdGlvbnMpOw0KICAgICAg
ICAgICAgY29udGFpbmVyLmFwcGVuZENoaWxkKGJsb2NrKTsNCiAgICAgICAgfSk7DQogICAgfQ0K
DQogICAgY29uc3QgY3R4RWwgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnY3R4Jyk7DQogICAg
ZnVuY3Rpb24gc2hvd0N0eCh4LCB5LCBjKSB7DQogICAgICAgIGN0eENsaXAgPSBjOw0KICAgICAg
ICBzZWxlY3RlZElkID0gYy5pZDsNCiAgICAgICAgcmFuZ2VBbmNob3JJZCA9IGMuaWQ7DQogICAg
ICAgIHJhbmdlQW5jaG9yQ2xpY2tlZCA9IHRydWU7DQogICAgICAgIGNvbnN0IGNsZWFyQnRuID0g
ZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2MtY2xlYXItcGFzdGVkJyk7DQogICAgICAgIGlmIChj
bGVhckJ0bikgY2xlYXJCdG4uc3R5bGUuZGlzcGxheSA9IGlzUGFzdGVkKGMpID8gJycgOiAnbm9u
ZSc7DQogICAgICAgIGNvbnN0IHBpbkJ0biA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjLXBp
bicpOw0KICAgICAgICBjb25zdCBjb3B5QnRuID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2Mt
Y29weScpOw0KICAgICAgICBjb25zdCBpc1JlY2VudCA9IG5vcm1UeXBlKGMudHlwZSkgPT09ICdy
ZWNlbnQnIHx8IGN1clRhYiA9PT0gJ3JlY2VudCc7DQoNCiAgICAgICAgY29uc3QgbXVsdGlTZWwg
PSBtdWx0aUlkcy5sZW5ndGggPj0gMSAmJiBtdWx0aUlkcy5pbmNsdWRlcygrYy5pZCk7DQogICAg
ICAgIGNvbnN0IHF1ZXVlSWRzID0gbXVsdGlTZWwgPyBtdWx0aUlkcy5zbGljZSgpIDogWytjLmlk
XTsNCiAgICAgICAgY29uc3QgcXVldWVkT2YgPSBpZCA9PiB7DQogICAgICAgICAgICBjb25zdCBp
dCA9ICgraWQgPT09ICtjLmlkKSA/IGMgOiBhbGxDbGlwcy5maW5kKHggPT4gK3guaWQgPT09ICtp
ZCk7DQogICAgICAgICAgICByZXR1cm4gISEoaXQgJiYgTnVtYmVyKGl0LnF1ZXVlR3JvdXApID4g
MCk7DQogICAgICAgIH07DQogICAgICAgIC8vIOWFqOmDqOW3suWcqOmYn+WIlyDihpIg5Y+q5pi+
56S656e75Ye677yb5ZCm5YiZ77yI5ZCr5re36YCJ77yJ5Y+q5pi+56S65Yqg5YWl44CC5Lik6ICF
5LqS5pal44CCDQogICAgICAgIGNvbnN0IGFsbFF1ZXVlZCA9IHF1ZXVlSWRzLmxlbmd0aCA+IDAg
JiYgcXVldWVJZHMuZXZlcnkocXVldWVkT2YpOw0KICAgICAgICBjb25zdCBxRnJvbSA9IGRvY3Vt
ZW50LmdldEVsZW1lbnRCeUlkKCdjLXF1ZXVlLWZyb20nKTsNCiAgICAgICAgaWYgKHFGcm9tKQ0K
ICAgICAgICAgICAgcUZyb20uc3R5bGUuZGlzcGxheSA9ICghaXNSZWNlbnQgJiYgYWxsUXVldWVk
ICYmIE51bWJlcihjLnF1ZXVlR3JvdXApID4gMCkgPyAnJyA6ICdub25lJzsNCiAgICAgICAgY29u
c3QgcUluID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2MtcXVldWUtaW4nKTsNCiAgICAgICAg
aWYgKHFJbikgew0KICAgICAgICAgICAgLy8g5aSa6YCJ77yI4omlMu+8ieS4lOacquWFqOmDqOWc
qOmYn+WIl+mHjOaJjeaYvuekuuOAjOWKoOWFpeOAjQ0KICAgICAgICAgICAgY29uc3Qgc2hvd0lu
ID0gIWlzUmVjZW50ICYmICFhbGxRdWV1ZWQgJiYgcXVldWVJZHMubGVuZ3RoID49IDI7DQogICAg
ICAgICAgICBxSW4uc3R5bGUuZGlzcGxheSA9IHNob3dJbiA/ICcnIDogJ25vbmUnOw0KICAgICAg
ICAgICAgaWYgKHNob3dJbikgew0KICAgICAgICAgICAgICAgIGNvbnN0IG4gPSBxdWV1ZUlkcy5s
ZW5ndGg7DQogICAgICAgICAgICAgICAgcUluLmlubmVySFRNTCA9ICc8c3BhbiBjbGFzcz0iYy1p
Y28iPuKHiTwvc3Bhbj7liqDlhaXnspjotLTpmJ/liJcgKCcgKyBuICsgJyknOw0KICAgICAgICAg
ICAgfQ0KICAgICAgICB9DQogICAgICAgIGNvbnN0IHFPdXQgPSBkb2N1bWVudC5nZXRFbGVtZW50
QnlJZCgnYy1xdWV1ZS1vdXQnKTsNCiAgICAgICAgaWYgKHFPdXQpIHsNCiAgICAgICAgICAgIGNv
bnN0IHNob3dPdXQgPSAhaXNSZWNlbnQgJiYgYWxsUXVldWVkOw0KICAgICAgICAgICAgcU91dC5z
dHlsZS5kaXNwbGF5ID0gc2hvd091dCA/ICcnIDogJ25vbmUnOw0KICAgICAgICAgICAgaWYgKHNo
b3dPdXQpIHsNCiAgICAgICAgICAgICAgICBjb25zdCBuID0gcXVldWVJZHMubGVuZ3RoOw0KICAg
ICAgICAgICAgICAgIHFPdXQuaW5uZXJIVE1MID0gbiA+IDENCiAgICAgICAgICAgICAgICAgICAg
PyAoJzxzcGFuIGNsYXNzPSJjLWljbyI+4oeHPC9zcGFuPuenu+WHuueymOi0tOmYn+WIlyAoJyAr
IG4gKyAnKScpDQogICAgICAgICAgICAgICAgICAgIDogJzxzcGFuIGNsYXNzPSJjLWljbyI+4oeH
PC9zcGFuPuenu+WHuueymOi0tOmYn+WIlyc7DQogICAgICAgICAgICB9DQogICAgICAgIH0NCg0K
ICAgICAgICBpZiAoY29weUJ0bikgew0KICAgICAgICAgICAgY29weUJ0bi5pbm5lckhUTUwgPSBp
c1JlY2VudA0KICAgICAgICAgICAgICAgID8gJzxzcGFuIGNsYXNzPSJjLWljbyI+8J+Ulzwvc3Bh
bj7lpI3liLbot6/lvoQnDQogICAgICAgICAgICAgICAgOiAnPHNwYW4gY2xhc3M9ImMtaWNvIj7i
jpg8L3NwYW4+5aSN5Yi2JzsNCiAgICAgICAgICAgIGNvcHlCdG4uc3R5bGUuZGlzcGxheSA9ICcn
Ow0KICAgICAgICB9DQogICAgICAgIGlmIChwaW5CdG4pIHsNCiAgICAgICAgICAgIGlmIChpc1Jl
Y2VudCkgew0KICAgICAgICAgICAgICAgIC8vIFJlY2VudCBmb2xkZXJzOiBwaW4gPSBrZWVwIHBh
dGggKG5vdCBjbGlwYm9hcmQg5pS26JePKQ0KICAgICAgICAgICAgICAgIHBpbkJ0bi5zdHlsZS5k
aXNwbGF5ID0gJyc7DQogICAgICAgICAgICAgICAgY29uc3Qgb24gPSBpc1Bpbm5lZChjKTsNCiAg
ICAgICAgICAgICAgICBwaW5CdG4uaW5uZXJIVE1MID0gb24NCiAgICAgICAgICAgICAgICAgICAg
PyAnPHNwYW4gY2xhc3M9ImMtaWNvIHN0YXIiPuKtkDwvc3Bhbj7lj5bmtojlm7rlrponDQogICAg
ICAgICAgICAgICAgICAgIDogJzxzcGFuIGNsYXNzPSJjLWljbyBzdGFyIj7irZA8L3NwYW4+5Zu6
5a6a6Lev5b6EJzsNCiAgICAgICAgICAgIH0gZWxzZSB7DQogICAgICAgICAgICAgICAgcGluQnRu
LnN0eWxlLmRpc3BsYXkgPSAnJzsNCiAgICAgICAgICAgICAgICBjb25zdCBvbiA9IGlzUGlubmVk
KGMpOw0KICAgICAgICAgICAgICAgIHBpbkJ0bi5pbm5lckhUTUwgPSBvbg0KICAgICAgICAgICAg
ICAgICAgICA/ICc8c3BhbiBjbGFzcz0iYy1pY28gc3RhciI+4q2QPC9zcGFuPuWPlua2iOaUtuiX
jycNCiAgICAgICAgICAgICAgICAgICAgOiAnPHNwYW4gY2xhc3M9ImMtaWNvIHN0YXIiPuKtkDwv
c3Bhbj7mlLbol48nOw0KICAgICAgICAgICAgfQ0KICAgICAgICB9DQogICAgICAgIGNvbnN0IHRp
dGxlQnRuID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2MtdGl0bGUnKTsNCiAgICAgICAgaWYg
KHRpdGxlQnRuKSB7DQogICAgICAgICAgICAvLyDmnIDov5Hot6/lvoTkuZ/lj6/orr7moIfpopjv
vIjlj4LkuI7mkJzntKLvvInvvJvmlLbol4/pobUv5bey5pS26JeP5p2h55uu5ZCM5YmNDQogICAg
ICAgICAgICBjb25zdCBzaG93VGl0bGUgPSBpc1JlY2VudCB8fCBpc1Bpbm5lZChjKSB8fCBjdXJU
YWIgPT09ICdwaW5uZWQnOw0KICAgICAgICAgICAgdGl0bGVCdG4uc3R5bGUuZGlzcGxheSA9IHNo
b3dUaXRsZSA/ICcnIDogJ25vbmUnOw0KICAgICAgICAgICAgaWYgKHNob3dUaXRsZSkNCiAgICAg
ICAgICAgICAgICB0aXRsZUJ0bi5pbm5lckhUTUwgPSAoU3RyaW5nKGMuZmF2VGl0bGUgfHwgJycp
LnRyaW0oKSA/ICc8c3BhbiBjbGFzcz0iYy1pY28iPuKcjjwvc3Bhbj7nvJbovpHmoIfpopgnIDog
JzxzcGFuIGNsYXNzPSJjLWljbyI+4pyOPC9zcGFuPuiuvue9ruagh+mimCcpOw0KICAgICAgICB9
DQogICAgICAgIGNvbnN0IG1lcmdlQnRuID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2MtbWVy
Z2UnKTsNCiAgICAgICAgY29uc3QgdW5tZXJnZUJ0biA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlk
KCdjLXVubWVyZ2UnKTsNCiAgICAgICAgY29uc3Qgb25QaW5uZWQgPSBjdXJUYWIgPT09ICdwaW5u
ZWQnOw0KICAgICAgICBpZiAobWVyZ2VCdG4pDQogICAgICAgICAgICBtZXJnZUJ0bi5zdHlsZS5k
aXNwbGF5ID0gKCFpc1JlY2VudCAmJiBvblBpbm5lZCAmJiBtdWx0aUlkcy5sZW5ndGggPj0gMikg
PyAnJyA6ICdub25lJzsNCiAgICAgICAgaWYgKHVubWVyZ2VCdG4pDQogICAgICAgICAgICB1bm1l
cmdlQnRuLnN0eWxlLmRpc3BsYXkgPSAoIWlzUmVjZW50ICYmIG9uUGlubmVkICYmIGZhdkdyb3Vw
T2YoYykpID8gJycgOiAnbm9uZSc7DQogICAgICAgIGNvbnN0IHRvcEJ0biA9IGRvY3VtZW50Lmdl
dEVsZW1lbnRCeUlkKCdjLXRvcCcpOw0KICAgICAgICBpZiAodG9wQnRuKQ0KICAgICAgICAgICAg
dG9wQnRuLnN0eWxlLmRpc3BsYXkgPSBpc1JlY2VudCA/ICdub25lJyA6ICcnOw0KICAgICAgICBj
b25zdCBjbGVhckJ0bjIgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYy1jbGVhci1wYXN0ZWQn
KTsNCiAgICAgICAgaWYgKGNsZWFyQnRuMiAmJiBpc1JlY2VudCkNCiAgICAgICAgICAgIGNsZWFy
QnRuMi5zdHlsZS5kaXNwbGF5ID0gJ25vbmUnOw0KICAgICAgICBjb25zdCBxRnJvbTIgPSBkb2N1
bWVudC5nZXRFbGVtZW50QnlJZCgnYy1xdWV1ZS1mcm9tJyk7DQogICAgICAgIGlmIChxRnJvbTIg
JiYgaXNSZWNlbnQpDQogICAgICAgICAgICBxRnJvbTIuc3R5bGUuZGlzcGxheSA9ICdub25lJzsN
CiAgICAgICAgY29uc3QgcUluMiA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjLXF1ZXVlLWlu
Jyk7DQogICAgICAgIGlmIChxSW4yICYmIGlzUmVjZW50KQ0KICAgICAgICAgICAgcUluMi5zdHls
ZS5kaXNwbGF5ID0gJ25vbmUnOw0KICAgICAgICBjb25zdCBxT3V0MiA9IGRvY3VtZW50LmdldEVs
ZW1lbnRCeUlkKCdjLXF1ZXVlLW91dCcpOw0KICAgICAgICBpZiAocU91dDIgJiYgaXNSZWNlbnQp
DQogICAgICAgICAgICBxT3V0Mi5zdHlsZS5kaXNwbGF5ID0gJ25vbmUnOw0KICAgICAgICBjb25z
dCBkZWxCdG4gPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYy1kZWwnKTsNCiAgICAgICAgaWYg
KGRlbEJ0bikgew0KICAgICAgICAgICAgY29uc3QgbXVsdGlEZWwgPSBtdWx0aUlkcy5sZW5ndGgg
PiAxICYmIG11bHRpSWRzLmluY2x1ZGVzKCtjLmlkKTsNCiAgICAgICAgICAgIGNvbnN0IG4gPSBt
dWx0aURlbCA/IG11bHRpSWRzLmxlbmd0aCA6IDE7DQogICAgICAgICAgICBkZWxCdG4uaW5uZXJI
VE1MID0gbiA+IDENCiAgICAgICAgICAgICAgICA/ICgnPHNwYW4gY2xhc3M9ImMtaWNvIj7inJU8
L3NwYW4+5Yig6ZmkICgnICsgbiArICcpJykNCiAgICAgICAgICAgICAgICA6ICc8c3BhbiBjbGFz
cz0iYy1pY28iPuKclTwvc3Bhbj7liKDpmaQnOw0KICAgICAgICB9DQogICAgICAgIGNvbnN0IGRh
dGFXcmFwID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2MtZGF0YS13cmFwJyk7DQogICAgICAg
IGNvbnN0IGRhdGFTZXAgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYy1kYXRhLXNlcCcpOw0K
ICAgICAgICBjb25zdCBzaG93RGF0YSA9ICFpc1JlY2VudCAmJiAobm9ybVR5cGUoYy50eXBlKSA9
PT0gJ3RleHQnIHx8IG5vcm1UeXBlKGMudHlwZSkgPT09ICdsaW5rJyk7DQogICAgICAgIGlmIChk
YXRhV3JhcCkgZGF0YVdyYXAuc3R5bGUuZGlzcGxheSA9IHNob3dEYXRhID8gJycgOiAnbm9uZSc7
DQogICAgICAgIGlmIChkYXRhU2VwKSBkYXRhU2VwLnN0eWxlLmRpc3BsYXkgPSBzaG93RGF0YSA/
ICcnIDogJ25vbmUnOw0KICAgICAgICBpZiAoZGF0YVdyYXApIGRhdGFXcmFwLmNsYXNzTGlzdC5y
ZW1vdmUoJ29wZW4nKTsNCiAgICAgICAgY3R4RWwuY2xhc3NMaXN0LmFkZCgnb24nKTsNCiAgICAg
ICAgY3R4RWwuc3R5bGUubGVmdCA9IHggKyAncHgnOw0KICAgICAgICBjdHhFbC5zdHlsZS50b3Ag
ID0geSArICdweCc7DQogICAgICAgIHJlcXVlc3RBbmltYXRpb25GcmFtZSgoKSA9PiB7DQogICAg
ICAgICAgICBjb25zdCByID0gY3R4RWwuZ2V0Qm91bmRpbmdDbGllbnRSZWN0KCk7DQogICAgICAg
ICAgICBpZiAoci5yaWdodCAgPiBpbm5lcldpZHRoKSAgY3R4RWwuc3R5bGUubGVmdCA9ICh4IC0g
ci53aWR0aCkgICsgJ3B4JzsNCiAgICAgICAgICAgIGlmIChyLmJvdHRvbSA+IGlubmVySGVpZ2h0
KSBjdHhFbC5zdHlsZS50b3AgID0gKHkgLSByLmhlaWdodCkgKyAncHgnOw0KICAgICAgICAgICAg
cGxhY2VEYXRhU3VibWVudSgpOw0KICAgICAgICB9KTsNCiAgICB9DQogICAgZnVuY3Rpb24gcGxh
Y2VEYXRhU3VibWVudSgpIHsNCiAgICAgICAgY29uc3Qgd3JhcCA9IGRvY3VtZW50LmdldEVsZW1l
bnRCeUlkKCdjLWRhdGEtd3JhcCcpOw0KICAgICAgICBjb25zdCBzdWIgPSBkb2N1bWVudC5nZXRF
bGVtZW50QnlJZCgnYy1kYXRhLXN1YicpOw0KICAgICAgICBpZiAoIXdyYXAgfHwgIXN1YiB8fCB3
cmFwLnN0eWxlLmRpc3BsYXkgPT09ICdub25lJykgcmV0dXJuOw0KICAgICAgICBjb25zdCBwYWQg
PSA0Ow0KICAgICAgICAvLyBNZWFzdXJlIHdoaWxlIHRlbXBvcmFyaWx5IHZpc2libGUgKHN1Ym1l
bnUgbWF5IHN0aWxsIGJlIGRpc3BsYXk6bm9uZSkNCiAgICAgICAgY29uc3QgcHJldkRpc3BsYXkg
PSBzdWIuc3R5bGUuZGlzcGxheTsNCiAgICAgICAgY29uc3QgcHJldlZpc2liaWxpdHkgPSBzdWIu
c3R5bGUudmlzaWJpbGl0eTsNCiAgICAgICAgY29uc3QgcHJldkxlZnQgPSBzdWIuc3R5bGUubGVm
dDsNCiAgICAgICAgY29uc3QgcHJldlJpZ2h0ID0gc3ViLnN0eWxlLnJpZ2h0Ow0KICAgICAgICBz
dWIuY2xhc3NMaXN0LnJlbW92ZSgnbGVmdCcpOw0KICAgICAgICBzdWIuc3R5bGUubGVmdCA9ICdj
YWxjKDEwMCUgLSAycHgpJzsNCiAgICAgICAgc3ViLnN0eWxlLnJpZ2h0ID0gJ2F1dG8nOw0KICAg
ICAgICBzdWIuc3R5bGUudmlzaWJpbGl0eSA9ICdoaWRkZW4nOw0KICAgICAgICBzdWIuc3R5bGUu
ZGlzcGxheSA9ICdibG9jayc7DQogICAgICAgIGNvbnN0IHN1YlcgPSBNYXRoLmNlaWwoc3ViLmdl
dEJvdW5kaW5nQ2xpZW50UmVjdCgpLndpZHRoIHx8IHN1Yi5vZmZzZXRXaWR0aCB8fCAwKTsNCiAg
ICAgICAgY29uc3Qgd3JhcFJlY3QgPSB3cmFwLmdldEJvdW5kaW5nQ2xpZW50UmVjdCgpOw0KICAg
ICAgICBzdWIuc3R5bGUuZGlzcGxheSA9IHByZXZEaXNwbGF5Ow0KICAgICAgICBzdWIuc3R5bGUu
dmlzaWJpbGl0eSA9IHByZXZWaXNpYmlsaXR5Ow0KICAgICAgICBzdWIuc3R5bGUubGVmdCA9IHBy
ZXZMZWZ0Ow0KICAgICAgICBzdWIuc3R5bGUucmlnaHQgPSBwcmV2UmlnaHQ7DQoNCiAgICAgICAg
aWYgKHN1YlcgPD0gMCkgcmV0dXJuOw0KICAgICAgICBjb25zdCBzcGFjZVJpZ2h0ID0gd2luZG93
LmlubmVyV2lkdGggLSB3cmFwUmVjdC5yaWdodCAtIHBhZDsNCiAgICAgICAgY29uc3Qgc3BhY2VM
ZWZ0ID0gd3JhcFJlY3QubGVmdCAtIHBhZDsNCiAgICAgICAgY29uc3QgZml0c1JpZ2h0ID0gc3Bh
Y2VSaWdodCA+PSBzdWJXOw0KICAgICAgICBjb25zdCBmaXRzTGVmdCA9IHNwYWNlTGVmdCA+PSBz
dWJXOw0KICAgICAgICBsZXQgb3BlbkxlZnQgPSBmYWxzZTsNCiAgICAgICAgaWYgKGZpdHNSaWdo
dCkgb3BlbkxlZnQgPSBmYWxzZTsNCiAgICAgICAgZWxzZSBpZiAoZml0c0xlZnQpIG9wZW5MZWZ0
ID0gdHJ1ZTsNCiAgICAgICAgZWxzZSBvcGVuTGVmdCA9IHNwYWNlTGVmdCA+IHNwYWNlUmlnaHQ7
IC8vIG5laXRoZXIgZml0cyDigJQgcGljayB0aGUgbGFyZ2VyIGdhcA0KDQogICAgICAgIGlmIChv
cGVuTGVmdCkgew0KICAgICAgICAgICAgc3ViLmNsYXNzTGlzdC5hZGQoJ2xlZnQnKTsNCiAgICAg
ICAgICAgIHN1Yi5zdHlsZS5sZWZ0ID0gJ2F1dG8nOw0KICAgICAgICAgICAgc3ViLnN0eWxlLnJp
Z2h0ID0gJ2NhbGMoMTAwJSAtIDJweCknOw0KICAgICAgICB9IGVsc2Ugew0KICAgICAgICAgICAg
c3ViLmNsYXNzTGlzdC5yZW1vdmUoJ2xlZnQnKTsNCiAgICAgICAgICAgIHN1Yi5zdHlsZS5sZWZ0
ID0gJ2NhbGMoMTAwJSAtIDJweCknOw0KICAgICAgICAgICAgc3ViLnN0eWxlLnJpZ2h0ID0gJ2F1
dG8nOw0KICAgICAgICB9DQogICAgfQ0KICAgIGZ1bmN0aW9uIGhpZGVDdHgoKSB7DQogICAgICAg
IGN0eEVsLmNsYXNzTGlzdC5yZW1vdmUoJ29uJyk7DQogICAgICAgIGN0eENsaXAgPSBudWxsOw0K
ICAgICAgICB0cnkgew0KICAgICAgICAgICAgY29uc3Qgd3JhcCA9IGRvY3VtZW50LmdldEVsZW1l
bnRCeUlkKCdjLWRhdGEtd3JhcCcpOw0KICAgICAgICAgICAgaWYgKHdyYXApIHdyYXAuY2xhc3NM
aXN0LnJlbW92ZSgnb3BlbicpOw0KICAgICAgICAgICAgY2xlYXJEYXRhU3VibWVudVBpY2soKTsN
CiAgICAgICAgICAgIHByZXZpZXdEYXRhVHJhbnNmb3JtU2VxKys7DQogICAgICAgIH0gY2F0Y2gg
e30NCiAgICB9DQogICAgd2luZG93Ll9faGlkZUN0eCA9IGhpZGVDdHg7DQoNCiAgICBmdW5jdGlv
biBkaXNtaXNzQ3R4VW5sZXNzSW5zaWRlKGUpIHsNCiAgICAgICAgaWYgKCFjdHhFbC5jbGFzc0xp
c3QuY29udGFpbnMoJ29uJykpIHJldHVybjsNCiAgICAgICAgaWYgKGUudGFyZ2V0LmNsb3Nlc3Qo
JyNjdHgnKSkgcmV0dXJuOw0KICAgICAgICBoaWRlQ3R4KCk7DQogICAgfQ0KICAgIGRvY3VtZW50
LmFkZEV2ZW50TGlzdGVuZXIoJ21vdXNlZG93bicsIGRpc21pc3NDdHhVbmxlc3NJbnNpZGUsIHRy
dWUpOw0KICAgIGRvY3VtZW50LmFkZEV2ZW50TGlzdGVuZXIoJ2NsaWNrJywgZGlzbWlzc0N0eFVu
bGVzc0luc2lkZSwgdHJ1ZSk7DQogICAgbGlzdEVsLmFkZEV2ZW50TGlzdGVuZXIoJ3Njcm9sbCcs
IGhpZGVDdHgsIHsgcGFzc2l2ZTogdHJ1ZSB9KTsNCiAgICBkb2N1bWVudC5hZGRFdmVudExpc3Rl
bmVyKCdrZXlkb3duJywgZSA9PiB7DQogICAgICAgIC8vIEVzYzogYWx3YXlzIGNsb3NlIHBhbmVs
IChzZWFyY2ggb3Igbm90KTsgcGluIGtlZXBzIHBhbmVsDQogICAgICAgIGlmIChlLmtleSA9PT0g
J0VzY2FwZScpIHsNCiAgICAgICAgICAgIGUucHJldmVudERlZmF1bHQoKTsNCiAgICAgICAgICAg
IGhpZGVDdHgoKTsNCiAgICAgICAgICAgIGNvbnN0IHRkID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5
SWQoJ3RpdGxlLWRsZycpOw0KICAgICAgICAgICAgaWYgKHRkICYmIHRkLmNsYXNzTGlzdC5jb250
YWlucygnb24nKSkgew0KICAgICAgICAgICAgICAgIHRyeSB7IGNsb3NlVGl0bGVEbGcoKTsgfSBj
YXRjaCB7IHRkLmNsYXNzTGlzdC5yZW1vdmUoJ29uJyk7IH0NCiAgICAgICAgICAgICAgICB0cnkg
eyBhaGsoJ2JsdXJQYW5lbCcpOyB9IGNhdGNoIHt9DQogICAgICAgICAgICAgICAgcmV0dXJuOw0K
ICAgICAgICAgICAgfQ0KICAgICAgICAgICAgaWYgKGNsckRsZy5jbGFzc0xpc3QuY29udGFpbnMo
J29uJykpIHsNCiAgICAgICAgICAgICAgICBjbG9zZUNsZWFyRGxnKCk7DQogICAgICAgICAgICAg
ICAgcmV0dXJuOw0KICAgICAgICAgICAgfQ0KICAgICAgICAgICAgaWYgKCFwaW5uZWRVSSkgYWhr
KCdoaWRlJyk7DQogICAgICAgICAgICByZXR1cm47DQogICAgICAgIH0NCiAgICAgICAgLy8gV2hp
bGUgdHlwaW5nIGluIHNlYXJjaDogQ3RybCtJL0sgYW5kIGFycm93cyBtb3ZlIGxpc3QsIGRvbid0
IGxlYXZlIHRoZSBib3gNCiAgICAgICAgaWYgKGRvY3VtZW50LmFjdGl2ZUVsZW1lbnQ/LmlkID09
PSAnc2VhcmNoJykgew0KICAgICAgICAgICAgaWYgKChlLmN0cmxLZXkgfHwgZS5tZXRhS2V5KSAm
JiAoZS5rZXkgPT09ICdpJyB8fCBlLmtleSA9PT0gJ0knKSkgew0KICAgICAgICAgICAgICAgIGUu
cHJldmVudERlZmF1bHQoKTsgZS5zdG9wUHJvcGFnYXRpb24oKTsNCiAgICAgICAgICAgICAgICB3
aW5kb3cuX19uYXYgJiYgd2luZG93Ll9fbmF2KCd1cCcpOw0KICAgICAgICAgICAgICAgIHJldHVy
bjsNCiAgICAgICAgICAgIH0NCiAgICAgICAgICAgIGlmICgoZS5jdHJsS2V5IHx8IGUubWV0YUtl
eSkgJiYgKGUua2V5ID09PSAnaycgfHwgZS5rZXkgPT09ICdLJykpIHsNCiAgICAgICAgICAgICAg
ICBlLnByZXZlbnREZWZhdWx0KCk7IGUuc3RvcFByb3BhZ2F0aW9uKCk7DQogICAgICAgICAgICAg
ICAgd2luZG93Ll9fbmF2ICYmIHdpbmRvdy5fX25hdignZG93bicpOw0KICAgICAgICAgICAgICAg
IHJldHVybjsNCiAgICAgICAgICAgIH0NCiAgICAgICAgICAgIGlmIChlLmtleSA9PT0gJ0Fycm93
RG93bicpIHsNCiAgICAgICAgICAgICAgICBlLnByZXZlbnREZWZhdWx0KCk7IGUuc3RvcFByb3Bh
Z2F0aW9uKCk7DQogICAgICAgICAgICAgICAgd2luZG93Ll9fbmF2ICYmIHdpbmRvdy5fX25hdign
ZG93bicpOw0KICAgICAgICAgICAgICAgIHJldHVybjsNCiAgICAgICAgICAgIH0NCiAgICAgICAg
ICAgIGlmIChlLmtleSA9PT0gJ0Fycm93VXAnKSB7DQogICAgICAgICAgICAgICAgZS5wcmV2ZW50
RGVmYXVsdCgpOyBlLnN0b3BQcm9wYWdhdGlvbigpOw0KICAgICAgICAgICAgICAgIHdpbmRvdy5f
X25hdiAmJiB3aW5kb3cuX19uYXYoJ3VwJyk7DQogICAgICAgICAgICAgICAgcmV0dXJuOw0KICAg
ICAgICAgICAgfQ0KICAgICAgICAgICAgcmV0dXJuOw0KICAgICAgICB9DQogICAgICAgIGNvbnN0
IHZpcyA9ICh0eXBlb2YgbmF2TGlzdCA9PT0gJ2Z1bmN0aW9uJyA/IG5hdkxpc3QoKSA6IHZpc2li
bGVMaXN0KCkpOw0KICAgICAgICBpZiAoIXZpcy5sZW5ndGgpIHJldHVybjsNCiAgICAgICAgbGV0
IGlkeCA9IHNlbGVjdGVkSW5kZXgoKTsNCiAgICAgICAgaWYgKGlkeCA8IDApIGlkeCA9IDA7DQog
ICAgICAgIGlmICAgICAgKGUua2V5ID09PSAnQXJyb3dEb3duJykgeyBlLnByZXZlbnREZWZhdWx0
KCk7IGUuc3RvcFByb3BhZ2F0aW9uKCk7IHNlbGVjdEJ5SW5kZXgoaWR4ICsgMSk7IH0NCiAgICAg
ICAgZWxzZSBpZiAoZS5rZXkgPT09ICdBcnJvd1VwJykgICB7IGUucHJldmVudERlZmF1bHQoKTsg
ZS5zdG9wUHJvcGFnYXRpb24oKTsgc2VsZWN0QnlJbmRleChpZHggLSAxKTsgfQ0KICAgICAgICBl
bHNlIGlmIChlLmtleSA9PT0gJ0VudGVyJykgew0KICAgICAgICAgICAgZS5wcmV2ZW50RGVmYXVs
dCgpOw0KICAgICAgICAgICAgLy8g5Zu65a6a5pe25Zue6L2m5LiN57KY6LS077yM5Y+q54K55p2h
55uu57KY6LS0DQogICAgICAgICAgICBpZiAocGlubmVkVUkpIHJldHVybjsNCiAgICAgICAgICAg
IGlmIChtdWx0aUlkcy5sZW5ndGggPj0gMSkgew0KICAgICAgICAgICAgICAgIGNvbnN0IGlkcyA9
IG11bHRpSWRzLnNsaWNlKCk7DQogICAgICAgICAgICAgICAgY2xlYXJNdWx0aSgpOw0KICAgICAg
ICAgICAgICAgIG1hcmtQYXN0ZWRMb2NhbChpZHMpOw0KICAgICAgICAgICAgICAgIHBhc3RlTWFu
eVdpdGhTZXAoaWRzKTsNCiAgICAgICAgICAgICAgICByZXR1cm47DQogICAgICAgICAgICB9DQog
ICAgICAgICAgICBjb25zdCBjID0gdmlzW3NlbGVjdGVkSW5kZXgoKV07DQogICAgICAgICAgICBp
ZiAoYykgew0KICAgICAgICAgICAgICAgIG1hcmtQYXN0ZWRMb2NhbChjLmlkKTsNCiAgICAgICAg
ICAgICAgICBhaGsoJ3Bhc3RlJywgU3RyaW5nKGMuaWQpKTsNCiAgICAgICAgICAgIH0NCiAgICAg
ICAgfSBlbHNlIGlmICgvXlsxLTldJC8udGVzdChlLmtleSkpIHsNCiAgICAgICAgICAgIGNvbnN0
IGMgPSB2aXNbK2Uua2V5IC0gMV07DQogICAgICAgICAgICBpZiAoYykgew0KICAgICAgICAgICAg
ICAgIG1hcmtQYXN0ZWRMb2NhbChjLmlkKTsNCiAgICAgICAgICAgICAgICBhaGsoJ3Bhc3RlJywg
U3RyaW5nKGMuaWQpKTsNCiAgICAgICAgICAgIH0NCiAgICAgICAgfQ0KICAgIH0pOw0KDQogICAg
d2luZG93Ll9fbmF2ID0gZGlyID0+IHsNCiAgICAgICAgY29uc3QgdGQgPSBkb2N1bWVudC5nZXRF
bGVtZW50QnlJZCgndGl0bGUtZGxnJyk7DQogICAgICAgIGlmICh0ZCAmJiB0ZC5jbGFzc0xpc3Qu
Y29udGFpbnMoJ29uJykpIHJldHVybjsNCiAgICAgICAgY29uc3QgdmlzID0gKHR5cGVvZiBuYXZM
aXN0ID09PSAnZnVuY3Rpb24nID8gbmF2TGlzdCgpIDogdmlzaWJsZUxpc3QoKSk7DQogICAgICAg
IGlmICghdmlzLmxlbmd0aCAmJiBkaXIgIT09ICd0YWInICYmIGRpciAhPT0gJ3RhYlByZXYnKSBy
ZXR1cm47DQogICAgICAgIGxldCBpZHggPSBzZWxlY3RlZEluZGV4KCk7DQogICAgICAgIGlmIChp
ZHggPCAwKSBpZHggPSAwOw0KICAgICAgICBpZiAoZGlyID09PSAndXAnKSBzZWxlY3RCeUluZGV4
KGlkeCAtIDEpOw0KICAgICAgICBlbHNlIGlmIChkaXIgPT09ICdkb3duJykgc2VsZWN0QnlJbmRl
eChpZHggKyAxKTsNCiAgICAgICAgZWxzZSBpZiAoZGlyID09PSAnZW50ZXInKSB7DQogICAgICAg
ICAgICBpZiAocGlubmVkVUkpIHJldHVybjsNCiAgICAgICAgICAgIF9fcHJlcFBhc3RlKCk7DQog
ICAgICAgICAgICBpZiAobXVsdGlJZHMubGVuZ3RoID49IDEpIHsNCiAgICAgICAgICAgICAgICBj
b25zdCBpZHMgPSBtdWx0aUlkcy5zbGljZSgpOw0KICAgICAgICAgICAgICAgIGNsZWFyTXVsdGko
KTsNCiAgICAgICAgICAgICAgICBtYXJrUGFzdGVkTG9jYWwoaWRzKTsNCiAgICAgICAgICAgICAg
ICBwYXN0ZU1hbnlXaXRoU2VwKGlkcyk7DQogICAgICAgICAgICAgICAgcmV0dXJuOw0KICAgICAg
ICAgICAgfQ0KICAgICAgICAgICAgY29uc3QgYyA9IHZpc1tzZWxlY3RlZEluZGV4KCldOw0KICAg
ICAgICAgICAgaWYgKGMpIHsNCiAgICAgICAgICAgICAgICBtYXJrUGFzdGVkTG9jYWwoYy5pZCk7
DQogICAgICAgICAgICAgICAgYWhrKCdwYXN0ZScsIFN0cmluZyhjLmlkKSk7DQogICAgICAgICAg
ICB9DQogICAgICAgIH0NCiAgICB9Ow0KDQogICAgLy8gQUhLIEVudGVyIGhvdGtleSBsYW5kcyBo
ZXJlIChXZWJWaWV3IG1heSBub3QgcmVjZWl2ZSB0aGUga2V5IHdoaWxlIHVucGlubmVkKQ0KICAg
IHdpbmRvdy5fX2VkaXRUaXRsZSA9ICgpID0+IHsNCiAgICAgICAgbGV0IGMgPSBudWxsOw0KICAg
ICAgICBpZiAoc2VsZWN0ZWRJZCkNCiAgICAgICAgICAgIGMgPSBhbGxDbGlwcy5maW5kKHggPT4g
K3guaWQgPT09ICtzZWxlY3RlZElkKSB8fCBudWxsOw0KICAgICAgICBpZiAoIWMgJiYgY3R4Q2xp
cCkNCiAgICAgICAgICAgIGMgPSBjdHhDbGlwOw0KICAgICAgICBpZiAoIWMpIHsNCiAgICAgICAg
ICAgIGNvbnN0IHZpcyA9IHZpc2libGVMaXN0KCk7DQogICAgICAgICAgICBpZiAodmlzLmxlbmd0
aCkgYyA9IHZpc1swXTsNCiAgICAgICAgfQ0KICAgICAgICBpZiAoIWMpIHJldHVybjsNCiAgICAg
ICAgb3BlblRpdGxlRGxnKGMpOw0KICAgIH07DQoNCiAgICB3aW5kb3cuX19vbkVudGVyID0gKCkg
PT4gew0KICAgICAgICBjb25zdCB0ZCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd0aXRsZS1k
bGcnKTsNCiAgICAgICAgaWYgKHRkICYmIHRkLmNsYXNzTGlzdC5jb250YWlucygnb24nKSkgew0K
ICAgICAgICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3RpdGxlLW9rJyk/LmNsaWNrKCk7
DQogICAgICAgICAgICByZXR1cm47DQogICAgICAgIH0NCiAgICAgICAgaWYgKGRvY3VtZW50LmFj
dGl2ZUVsZW1lbnQ/LmlkID09PSAndGl0bGUtaW5wdXQnKSB7DQogICAgICAgICAgICBkb2N1bWVu
dC5nZXRFbGVtZW50QnlJZCgndGl0bGUtb2snKT8uY2xpY2soKTsNCiAgICAgICAgICAgIHJldHVy
bjsNCiAgICAgICAgfQ0KICAgICAgICAvLyDoh6rlrprkuYnliIbpmpTnrKbvvJrmnKrlm7rlrprm
l7YgQUhLIOS8muaKoiBFbnRlcg0KICAgICAgICBjb25zdCBzZXBNZW51ID0gZG9jdW1lbnQuZ2V0
RWxlbWVudEJ5SWQoJ3Bhc3RlLXNlcC1tZW51Jyk7DQogICAgICAgIGNvbnN0IHNlcElucCA9IGRv
Y3VtZW50LmdldEVsZW1lbnRCeUlkKCdwYXN0ZS1zZXAtY3VzdG9tJyk7DQogICAgICAgIGlmIChz
ZXBNZW51ICYmIHNlcE1lbnUuY2xhc3NMaXN0LmNvbnRhaW5zKCdvbicpICYmIHNlcElucCkgew0K
ICAgICAgICAgICAgaWYgKFN0cmluZyhzZXBJbnAudmFsdWUgfHwgJycpICE9PSAnJykgYXBwbHlT
ZXBhcmF0b3Ioc2VwSW5wLnZhbHVlKTsNCiAgICAgICAgICAgIGVsc2UgY2xvc2VTZXBNZW51KCk7
DQogICAgICAgICAgICByZXR1cm47DQogICAgICAgIH0NCiAgICAgICAgLy8g5Zu65a6a5pe25Zue
6L2m5LiN57KY6LS0DQogICAgICAgIGlmIChwaW5uZWRVSSkgcmV0dXJuOw0KICAgICAgICAvLyBU
eXBpbmcgaW4gc2VhcmNoOiBFbnRlciBzaG91bGQgcGFzdGUgc2VsZWN0ZWQgaXRlbQ0KICAgICAg
ICBpZiAoZG9jdW1lbnQuYWN0aXZlRWxlbWVudD8uaWQgPT09ICdzZWFyY2gnKSB7DQogICAgICAg
ICAgICB3aW5kb3cuX19uYXYgJiYgd2luZG93Ll9fbmF2KCdlbnRlcicpOw0KICAgICAgICAgICAg
cmV0dXJuOw0KICAgICAgICB9DQogICAgICAgIHdpbmRvdy5fX25hdiAmJiB3aW5kb3cuX19uYXYo
J2VudGVyJyk7DQogICAgfTsNCg0KICAgIHdpbmRvdy5fX2N5Y2xlVGFiID0gZGlyID0+IHsNCiAg
ICAgICAgY29uc3QgaSA9IE1hdGgubWF4KDAsIFRBQl9PUkRFUi5pbmRleE9mKGN1clRhYikpOw0K
ICAgICAgICBjb25zdCBuZXh0ID0gVEFCX09SREVSWyhpICsgKGRpciB8IDApICsgVEFCX09SREVS
Lmxlbmd0aCAqIDEwKSAlIFRBQl9PUkRFUi5sZW5ndGhdOw0KICAgICAgICBzZXRUYWIobmV4dCk7
DQogICAgfTsNCiAgICB3aW5kb3cuX19vblBhbmVsU2hvdyA9IChrZWVwU2VhcmNoKSA9PiB7DQog
ICAgICAgIHdpbmRvdy5fX3BlcmZNYXJrICYmIHdpbmRvdy5fX3BlcmZNYXJrKCdqc19vblBhbmVs
U2hvdyBrZWVwU2VhcmNoPScgKyAoISFrZWVwU2VhcmNoKSk7DQogICAgICAgIHRyeSB7IHJlc2V0
UGFzdGVTZXBEZWZhdWx0KCk7IH0gY2F0Y2gge30NCiAgICAgICAgLy8gRG8gTk9UIGZvY3VzIFdl
YlZpZXcg4oCUIGtlZXAgZWRpdG9yIGNhcmV0L2ZvY3VzIChBSEsgaGFuZGxlcyBrZXlzIHZpYSAj
SG90SWYpDQogICAgICAgIC8vIFdpbitWOiBjb2xsYXBzZSBzZWFyY2guID8/IHNlYXJjaDoga2Vl
cC9vcGVuIHNlYXJjaCBib3guDQogICAgICAgIGtlZXBTZWFyY2ggPSAhIWtlZXBTZWFyY2g7DQog
ICAgICAgIHRyeSB7IGhpZGVDdHgoKTsgfSBjYXRjaCB7fQ0KICAgICAgICB0cnkgeyBjbG9zZVRp
dGxlRGxnKCk7IH0gY2F0Y2gge30NCiAgICAgICAgdHJ5IHsNCiAgICAgICAgICAgIGNvbnN0IHdy
YXAgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc2VhcmNoLXdyYXAnKTsNCiAgICAgICAgICAg
IGNvbnN0IHNyY2ggPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc2VhcmNoJyk7DQogICAgICAg
ICAgICBjb25zdCBzY2xyID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NlYXJjaC1jbHInKTsN
CiAgICAgICAgICAgIGlmICgha2VlcFNlYXJjaCkgew0KICAgICAgICAgICAgICAgIGlmICh3cmFw
KSB3cmFwLmNsYXNzTGlzdC5yZW1vdmUoJ29wZW4nKTsNCiAgICAgICAgICAgICAgICBpZiAoc3Jj
aCkgew0KICAgICAgICAgICAgICAgICAgICBzcmNoLnZhbHVlID0gJyc7DQogICAgICAgICAgICAg
ICAgICAgIHNyY2guY2xhc3NMaXN0LnJlbW92ZSgnaGFzLXZhbCcpOw0KICAgICAgICAgICAgICAg
ICAgICB0cnkgeyBzcmNoLmJsdXIoKTsgfSBjYXRjaCB7fQ0KICAgICAgICAgICAgICAgIH0NCiAg
ICAgICAgICAgICAgICBpZiAoc2Nscikgc2Nsci5zdHlsZS5kaXNwbGF5ID0gJ25vbmUnOw0KICAg
ICAgICAgICAgICAgIHF1ZXJ5ID0gJyc7DQogICAgICAgICAgICAgICAgd2luZG93Ll9faG9zdEZp
bHRlcmVkID0gZmFsc2U7DQogICAgICAgICAgICAgICAgd2luZG93Ll9faG9zdEZpbHRlclEgPSAn
JzsNCiAgICAgICAgICAgICAgICAvLyBXaW4rVu+8mueri+WIu+eUqOacqui/h+a7pOe8k+WtmOmT
uuWIl+ihqO+8jOmBv+WFjeWFiOmXqui/h+a7pOe7k+aenC/nqbrlo7Plho3nrYkgU2V0Vmlldw0K
ICAgICAgICAgICAgICAgIHRyeSB7DQogICAgICAgICAgICAgICAgICAgIGNvbnN0IGhpdCA9IHZp
ZXdNZW0uZ2V0KHZpZXdNZW1LZXkoJ2FsbCcsICcnLCBmYWxzZSkpOw0KICAgICAgICAgICAgICAg
ICAgICBpZiAoaGl0ICYmIEFycmF5LmlzQXJyYXkoaGl0Lml0ZW1zKSAmJiBoaXQuaXRlbXMubGVu
Z3RoKSB7DQogICAgICAgICAgICAgICAgICAgICAgICBhbGxDbGlwcyA9IGhpdC5pdGVtcy5zbGlj
ZSgpOw0KICAgICAgICAgICAgICAgICAgICAgICAgZGlza1RvdGFsID0gTnVtYmVyKGhpdC50b3Rh
bCkgfHwgaGl0Lml0ZW1zLmxlbmd0aDsNCiAgICAgICAgICAgICAgICAgICAgICAgIHdpbmRvdy5f
X2RhdGFSZWFkeSA9IHRydWU7DQogICAgICAgICAgICAgICAgICAgICAgICBob3N0UHVzaGVkT25j
ZSA9IHRydWU7DQogICAgICAgICAgICAgICAgICAgICAgICBzYXdOb25FbXB0eSA9IHRydWU7DQog
ICAgICAgICAgICAgICAgICAgICAgICBjbGVhcldhaXRpbmdEYXRhKCk7DQogICAgICAgICAgICAg
ICAgICAgIH0gZWxzZSB7DQogICAgICAgICAgICAgICAgICAgICAgICBzY2hlZHVsZURlbGF5ZWRT
a2VsKCk7DQogICAgICAgICAgICAgICAgICAgIH0NCiAgICAgICAgICAgICAgICB9IGNhdGNoIHsN
CiAgICAgICAgICAgICAgICAgICAgc2NoZWR1bGVEZWxheWVkU2tlbCgpOw0KICAgICAgICAgICAg
ICAgIH0NCiAgICAgICAgICAgIH0gZWxzZSBpZiAod3JhcCkgew0KICAgICAgICAgICAgICAgIHdy
YXAuY2xhc3NMaXN0LmFkZCgnb3BlbicpOw0KICAgICAgICAgICAgICAgIGlmIChzcmNoICYmIHNy
Y2gudmFsdWUpDQogICAgICAgICAgICAgICAgICAgIHF1ZXJ5ID0gc3JjaC52YWx1ZTsNCiAgICAg
ICAgICAgICAgICAvLyA/PyDmkJzntKLvvJrlnKjkuLvmnLrov4fmu6Tnu5PmnpzliLDovr7liY3v
vIzlhYjmjInlhbPplK7lrZfmnKzlnLDmu6TvvIznpoHmraLpl6rlh7rjgIzlhajpg6jjgI0NCiAg
ICAgICAgICAgICAgICBpZiAoU3RyaW5nKHF1ZXJ5IHx8ICcnKS50cmltKCkpIHsNCiAgICAgICAg
ICAgICAgICAgICAgd2luZG93Ll9faG9zdEZpbHRlcmVkID0gZmFsc2U7DQogICAgICAgICAgICAg
ICAgICAgIHdpbmRvdy5fX2hvc3RGaWx0ZXJRID0gJyc7DQogICAgICAgICAgICAgICAgfQ0KICAg
ICAgICAgICAgfQ0KICAgICAgICAgICAgdG9kYXlPbmx5ID0gZmFsc2U7DQogICAgICAgICAgICB0
cnkgew0KICAgICAgICAgICAgICAgIGNvbnN0IGJ0blRvZGF5ID0gZG9jdW1lbnQuZ2V0RWxlbWVu
dEJ5SWQoJ2J0bi10b2RheScpOw0KICAgICAgICAgICAgICAgIGlmIChidG5Ub2RheSkgYnRuVG9k
YXkuY2xhc3NMaXN0LnJlbW92ZSgnb24nKTsNCiAgICAgICAgICAgIH0gY2F0Y2gge30NCiAgICAg
ICAgICAgIGN1clRhYiA9ICdhbGwnOw0KICAgICAgICAgICAgbG9hZGluZ01vcmUgPSBmYWxzZTsN
CiAgICAgICAgICAgIG1hcmtUYWIoJ2FsbCcpOw0KICAgICAgICAgICAgLy8g5LiN6KaBIGFoaygn
Ymx1clBhbmVsJynvvJrkvJrot58gU2hvd1BhbmVsIOaKoueEpueCue+8jFdpbitWLz8/IOmDveWu
ueaYk+mXquOAgeS5sei3sw0KICAgICAgICAgICAgcmVuZGVyKCk7DQogICAgICAgICAgICAvLyDl
kIzmraXlvZPliY0gdGFiL3F1ZXJ5IOWIsCBBSEvvvIg/PyDmm77lj6rnlKggdmlld1RhYiDmkJzp
lJnpobXvvIkNCiAgICAgICAgICAgIHJlcXVlc3RWaWV3KCk7DQogICAgICAgIH0gY2F0Y2gge30N
CiAgICAgICAgc2VsZWN0Rmlyc3RPblNob3cgPSB0cnVlOw0KICAgICAgICBsb2NhdGVBY3RpdmUg
PSBmYWxzZTsNCiAgICAgICAgdXBkYXRlTG9jYXRlQnRuKCk7DQogICAgICAgIGNsZWFyTXVsdGko
KTsNCiAgICAgICAgY29uc3QgdmlzID0gdmlzaWJsZUxpc3QoKTsNCiAgICAgICAgaWYgKHZpcy5s
ZW5ndGgpIHsNCiAgICAgICAgICAgIHNlbGVjdGVkSWQgPSB2aXNbMF0uaWQ7DQogICAgICAgICAg
ICByYW5nZUFuY2hvcklkID0gc2VsZWN0ZWRJZDsNCiAgICAgICAgICAgIHJhbmdlQW5jaG9yQ2xp
Y2tlZCA9IGZhbHNlOw0KICAgICAgICAgICAgbGlzdEVsLnNjcm9sbFRvcCA9IDA7DQogICAgICAg
IH0NCiAgICAgICAgc3luY0l0ZW1IaWdobGlnaHQoKTsNCiAgICB9Ow0KDQogICAgZnVuY3Rpb24g
Y3R4QmluZChpZCwgZm4pIHsNCiAgICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoaWQpLmFk
ZEV2ZW50TGlzdGVuZXIoJ2NsaWNrJywgZSA9PiB7DQogICAgICAgICAgICBlLnN0b3BQcm9wYWdh
dGlvbigpOw0KICAgICAgICAgICAgaWYgKGN0eENsaXApIGZuKGN0eENsaXApOw0KICAgICAgICAg
ICAgaGlkZUN0eCgpOw0KICAgICAgICB9KTsNCiAgICB9DQogICAgZnVuY3Rpb24gc3FsUXVvdGUo
dikgew0KICAgICAgICByZXR1cm4gIiciICsgU3RyaW5nKHYgPz8gJycpLnJlcGxhY2UoLycvZywg
IicnIikgKyAiJyI7DQogICAgfQ0KICAgIGZ1bmN0aW9uIHN0cmlwT3V0ZXJRdW90ZXModikgew0K
ICAgICAgICBjb25zdCBzID0gU3RyaW5nKHYgPz8gJycpLnRyaW0oKTsNCiAgICAgICAgaWYgKChz
LnN0YXJ0c1dpdGgoJyInKSAmJiBzLmVuZHNXaXRoKCciJykpIHx8IChzLnN0YXJ0c1dpdGgoIici
KSAmJiBzLmVuZHNXaXRoKCInIikpKQ0KICAgICAgICAgICAgcmV0dXJuIHMuc2xpY2UoMSwgLTEp
Ow0KICAgICAgICByZXR1cm4gczsNCiAgICB9DQogICAgZnVuY3Rpb24gc3BsaXRDc3ZQYXJ0cyhy
YXcpIHsNCiAgICAgICAgY29uc3QgcyA9IFN0cmluZyhyYXcgPz8gJycpOw0KICAgICAgICBjb25z
dCBwYXJ0cyA9IFtdOw0KICAgICAgICBsZXQgY3VyID0gJyc7DQogICAgICAgIGxldCBxID0gJyc7
DQogICAgICAgIGZvciAobGV0IGkgPSAwOyBpIDwgcy5sZW5ndGg7IGkrKykgew0KICAgICAgICAg
ICAgY29uc3QgY2ggPSBzW2ldOw0KICAgICAgICAgICAgaWYgKHEpIHsNCiAgICAgICAgICAgICAg
ICBpZiAoY2ggPT09IHEpIHsNCiAgICAgICAgICAgICAgICAgICAgLy8gZG91YmxlZCBxdW90ZSBl
c2NhcGUNCiAgICAgICAgICAgICAgICAgICAgaWYgKHNbaSArIDFdID09PSBxKSB7IGN1ciArPSBx
OyBpKys7IH0NCiAgICAgICAgICAgICAgICAgICAgZWxzZSBxID0gJyc7DQogICAgICAgICAgICAg
ICAgfSBlbHNlIGN1ciArPSBjaDsNCiAgICAgICAgICAgICAgICBjb250aW51ZTsNCiAgICAgICAg
ICAgIH0NCiAgICAgICAgICAgIGlmIChjaCA9PT0gJyInIHx8IGNoID09PSAiJyIpIHsgcSA9IGNo
OyBjb250aW51ZTsgfQ0KICAgICAgICAgICAgaWYgKGNoID09PSAnLCcpIHsgcGFydHMucHVzaChj
dXIudHJpbSgpKTsgY3VyID0gJyc7IGNvbnRpbnVlOyB9DQogICAgICAgICAgICBjdXIgKz0gY2g7
DQogICAgICAgIH0NCiAgICAgICAgcGFydHMucHVzaChjdXIudHJpbSgpKTsNCiAgICAgICAgcmV0
dXJuIHBhcnRzLmZpbHRlcihwID0+IHAgIT09ICcnKTsNCiAgICB9DQogICAgZnVuY3Rpb24gdHJh
bnNmb3JtVGV4dFRvU3FsVHVwbGUocmF3LCBtb2RlKSB7DQogICAgICAgIGxldCBzcmMgPSBTdHJp
bmcocmF3ID8/ICcnKS50cmltKCk7DQogICAgICAgIGlmICghc3JjKSByZXR1cm4gJyc7DQogICAg
ICAgIGxldCBwYXJ0cyA9IFtdOw0KICAgICAgICBpZiAobW9kZSA9PT0gJ2xpbmVzJykgew0KICAg
ICAgICAgICAgcGFydHMgPSBzcmMuc3BsaXQoL1xyP1xuLykubWFwKGwgPT4gc3RyaXBPdXRlclF1
b3RlcyhsLnRyaW0oKSkpLmZpbHRlcihCb29sZWFuKTsNCiAgICAgICAgfSBlbHNlIHsNCiAgICAg
ICAgICAgIC8vIHthLGJ9IC8gYSxiIC8geyJhIiwiYiJ9DQogICAgICAgICAgICBjb25zdCBtID0g
c3JjLm1hdGNoKC9eXHMqXHsoW1xzXFNdKilcfVxzKiQvKTsNCiAgICAgICAgICAgIGlmIChtKSBz
cmMgPSBtWzFdLnRyaW0oKTsNCiAgICAgICAgICAgIHBhcnRzID0gc3BsaXRDc3ZQYXJ0cyhzcmMp
Lm1hcChzdHJpcE91dGVyUXVvdGVzKS5maWx0ZXIoQm9vbGVhbik7DQogICAgICAgIH0NCiAgICAg
ICAgaWYgKCFwYXJ0cy5sZW5ndGgpIHJldHVybiAnJzsNCiAgICAgICAgcmV0dXJuICcoJyArIHBh
cnRzLm1hcChzcWxRdW90ZSkuam9pbignLCcpICsgJyknOw0KICAgIH0NCiAgICBmdW5jdGlvbiBh
cHBseURhdGFUcmFuc2Zvcm0oYywgbW9kZSkgew0KICAgICAgICBpZiAoIWMpIHJldHVybjsNCiAg
ICAgICAgLy8gRG8gbm90IG11dGF0ZSBjbGlwIGhpc3Rvcnkg4oCUIEFISyB0cmFuc2Zvcm1zIGEg
Y29weSBhbmQgcGFzdGVzIGl0DQogICAgICAgIHRyeSB7IG1hcmtQYXN0ZWRMb2NhbChjLmlkKTsg
fSBjYXRjaCB7fQ0KICAgICAgICBhaGsoJ3RleHRUcmFuc2Zvcm0nLCBTdHJpbmcoYy5pZCksIFN0
cmluZyhtb2RlIHx8ICdhdXRvJykpOw0KICAgIH0NCiAgICBmdW5jdGlvbiBkZXRlY3REYXRhVHJh
bnNmb3JtTW9kZShyYXcpIHsNCiAgICAgICAgLy8gVUkgbGlzdCBvbmx5IGhhcyB0cnVuY2F0ZWQg
cHJldmlldyAoZGF0YT0iIikuDQogICAgICAgIC8vIENoZWNrIFwiIGZpcnN0OiBlc2NhcGVkIEpT
T04gb2Z0ZW4gYWxzbyBzdGFydHMgd2l0aCAneycuDQogICAgICAgIGNvbnN0IHMgPSBTdHJpbmco
cmF3ID8/ICcnKS50cmltKCk7DQogICAgICAgIGlmICghcykgcmV0dXJuICcnOw0KICAgICAgICBp
ZiAocy5pbmNsdWRlcygnXFwiJykpIHJldHVybiAnanNvbic7DQogICAgICAgIGlmIChzLnN0YXJ0
c1dpdGgoJ3snKSkgcmV0dXJuICdicmFjZSc7DQogICAgICAgIGlmIChzLmluY2x1ZGVzKCdcbicp
IHx8IHMuaW5jbHVkZXMoJ1xyJykpIHJldHVybiAnbGluZXMnOw0KICAgICAgICByZXR1cm4gJyc7
DQogICAgfQ0KICAgIGZ1bmN0aW9uIGNsZWFyRGF0YVN1Ym1lbnVQaWNrKCkgew0KICAgICAgICB0
cnkgew0KICAgICAgICAgICAgZG9jdW1lbnQucXVlcnlTZWxlY3RvckFsbCgnI2MtZGF0YS1zdWIg
LmMtaXRlbS5waWNrJykuZm9yRWFjaChlbCA9PiBlbC5jbGFzc0xpc3QucmVtb3ZlKCdwaWNrJykp
Ow0KICAgICAgICB9IGNhdGNoIHt9DQogICAgfQ0KICAgIGZ1bmN0aW9uIGhpZ2hsaWdodERhdGFT
dWJtZW51TW9kZShtb2RlKSB7DQogICAgICAgIGNsZWFyRGF0YVN1Ym1lbnVQaWNrKCk7DQogICAg
ICAgIGNvbnN0IGlkTWFwID0geyBicmFjZTogJ2MtZGF0YS1icmFjZScsIGxpbmVzOiAnYy1kYXRh
LWxpbmVzJywganNvbjogJ2MtZGF0YS1qc29uJyB9Ow0KICAgICAgICBjb25zdCBpZCA9IGlkTWFw
W21vZGVdOw0KICAgICAgICBpZiAoIWlkKSByZXR1cm47DQogICAgICAgIGNvbnN0IGVsID0gZG9j
dW1lbnQuZ2V0RWxlbWVudEJ5SWQoaWQpOw0KICAgICAgICBpZiAoZWwpIGVsLmNsYXNzTGlzdC5h
ZGQoJ3BpY2snKTsNCiAgICB9DQogICAgZnVuY3Rpb24gcHJldmlld0RhdGFUcmFuc2Zvcm1Nb2Rl
QXN5bmMoKSB7DQogICAgICAgIGNvbnN0IHRva2VuID0gKytwcmV2aWV3RGF0YVRyYW5zZm9ybVNl
cTsNCiAgICAgICAgY29uc3QgY2xpcCA9IGN0eENsaXA7DQogICAgICAgIHNldFRpbWVvdXQoKCkg
PT4gew0KICAgICAgICAgICAgaWYgKHRva2VuICE9PSBwcmV2aWV3RGF0YVRyYW5zZm9ybVNlcSkg
cmV0dXJuOw0KICAgICAgICAgICAgaWYgKCFjbGlwIHx8IGN0eENsaXAgIT09IGNsaXApIHJldHVy
bjsNCiAgICAgICAgICAgIGNvbnN0IHJhdyA9IFN0cmluZyhjbGlwLmRhdGEgfHwgY2xpcC5wcmV2
aWV3IHx8ICcnKTsNCiAgICAgICAgICAgIGNvbnN0IG1vZGUgPSBkZXRlY3REYXRhVHJhbnNmb3Jt
TW9kZShyYXcpOw0KICAgICAgICAgICAgaWYgKHRva2VuICE9PSBwcmV2aWV3RGF0YVRyYW5zZm9y
bVNlcSkgcmV0dXJuOw0KICAgICAgICAgICAgaGlnaGxpZ2h0RGF0YVN1Ym1lbnVNb2RlKG1vZGUp
Ow0KICAgICAgICB9LCAwKTsNCiAgICB9DQogICAgbGV0IHByZXZpZXdEYXRhVHJhbnNmb3JtU2Vx
ID0gMDsNCiAgICBjb25zdCBkYXRhUGFyZW50ID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2Mt
ZGF0YScpOw0KICAgIGNvbnN0IGRhdGFXcmFwRWwgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgn
Yy1kYXRhLXdyYXAnKTsNCiAgICBpZiAoZGF0YVBhcmVudCkgew0KICAgICAgICBkYXRhUGFyZW50
LmFkZEV2ZW50TGlzdGVuZXIoJ2NsaWNrJywgZSA9PiB7DQogICAgICAgICAgICBlLnN0b3BQcm9w
YWdhdGlvbigpOw0KICAgICAgICAgICAgLy8gUHJpbWFyeSBjbGljayA9IGF1dG8gZGV0ZWN0ICsg
dHJhbnNmb3JtICsgcGFzdGUNCiAgICAgICAgICAgIGlmIChjdHhDbGlwKSB7DQogICAgICAgICAg
ICAgICAgYXBwbHlEYXRhVHJhbnNmb3JtKGN0eENsaXAsICdhdXRvJyk7DQogICAgICAgICAgICAg
ICAgaGlkZUN0eCgpOw0KICAgICAgICAgICAgICAgIHJldHVybjsNCiAgICAgICAgICAgIH0NCiAg
ICAgICAgICAgIGNvbnN0IHdyYXAgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYy1kYXRhLXdy
YXAnKTsNCiAgICAgICAgICAgIGlmICh3cmFwKSB7DQogICAgICAgICAgICAgICAgd3JhcC5jbGFz
c0xpc3QudG9nZ2xlKCdvcGVuJyk7DQogICAgICAgICAgICAgICAgcGxhY2VEYXRhU3VibWVudSgp
Ow0KICAgICAgICAgICAgICAgIHByZXZpZXdEYXRhVHJhbnNmb3JtTW9kZUFzeW5jKCk7DQogICAg
ICAgICAgICB9DQogICAgICAgIH0pOw0KICAgIH0NCiAgICBpZiAoZGF0YVdyYXBFbCkgew0KICAg
ICAgICBkYXRhV3JhcEVsLmFkZEV2ZW50TGlzdGVuZXIoJ21vdXNlZW50ZXInLCAoKSA9PiB7DQog
ICAgICAgICAgICBwbGFjZURhdGFTdWJtZW51KCk7DQogICAgICAgICAgICBwcmV2aWV3RGF0YVRy
YW5zZm9ybU1vZGVBc3luYygpOw0KICAgICAgICB9KTsNCiAgICAgICAgZGF0YVdyYXBFbC5hZGRF
dmVudExpc3RlbmVyKCdtb3VzZWxlYXZlJywgKCkgPT4gY2xlYXJEYXRhU3VibWVudVBpY2soKSk7
DQogICAgfQ0KICAgIGN0eEJpbmQoJ2MtZGF0YS1icmFjZScsIGMgPT4gYXBwbHlEYXRhVHJhbnNm
b3JtKGMsICdicmFjZScpKTsNCiAgICBjdHhCaW5kKCdjLWRhdGEtbGluZXMnLCBjID0+IGFwcGx5
RGF0YVRyYW5zZm9ybShjLCAnbGluZXMnKSk7DQogICAgY3R4QmluZCgnYy1kYXRhLWpzb24nLCBj
ID0+IGFwcGx5RGF0YVRyYW5zZm9ybShjLCAnanNvbicpKTsNCiAgICBjdHhCaW5kKCdjLWNvcHkn
LCAgYyA9PiB7DQogICAgICAgIGlmIChub3JtVHlwZShjLnR5cGUpID09PSAncmVjZW50JykNCiAg
ICAgICAgICAgIGFoaygnY29weVBhdGgnLCBTdHJpbmcoYy5kYXRhIHx8IGMucHJldmlldyB8fCAn
JykpOw0KICAgICAgICBlbHNlDQogICAgICAgICAgICBhaGsoJ2NvcHlCeUlkJywgU3RyaW5nKGMu
aWQpKTsNCiAgICB9KTsNCiAgICBjdHhCaW5kKCdjLXBhc3RlJywgYyA9PiB7DQogICAgICAgIGFj
dGl2YXRlQ2xpcEl0ZW0oYyk7DQogICAgfSk7DQogICAgY3R4QmluZCgnYy1waW4nLCAgIGMgPT4g
ew0KICAgICAgICAvLyBPcHRpbWlzdGljIGZsaXAg4oCUIOWbuuWumuWPqumYsua3mOaxsO+8jOS4
jee9rumhtu+8m+WGjeasoeiuv+mXruaJjemdoCBSZWNvcmQg6aG25Yiw5LiK6Z2iDQogICAgICAg
IGNvbnN0IG5leHQgPSAhaXNQaW5uZWQoYyk7DQogICAgICAgIGNvbnN0IGlkID0gK2MuaWQ7DQog
ICAgICAgIHBhdGNoUGlubmVkSW5DYWNoZXMoaWQsIG5leHQpOw0KICAgICAgICBjLnBpbm5lZCA9
IG5leHQ7DQogICAgICAgIGlmIChuZXh0KSBtYXJrRmF2VW5zZWVuKGlkKTsNCiAgICAgICAgZWxz
ZSB7DQogICAgICAgICAgICB1bnNlZW5GYXZJZHMuZGVsZXRlKGlkKTsNCiAgICAgICAgICAgIHNh
dmVVbnNlZW5GYXYoKTsNCiAgICAgICAgICAgIHVwZGF0ZVBpbkRvdCgpOw0KICAgICAgICB9DQog
ICAgICAgIC8vIOaUtuiXj+mhteWPlua2iO+8mueri+WIu+S7juWIl+ihqOaRmOaOie+8jOWIq+et
iSBTZXRWaWV3IOaJq+ebmA0KICAgICAgICBpZiAoIW5leHQgJiYgY3VyVGFiID09PSAncGlubmVk
Jykgew0KICAgICAgICAgICAgYWxsQ2xpcHMgPSBhbGxDbGlwcy5maWx0ZXIoeCA9PiAreC5pZCAh
PT0gaWQpOw0KICAgICAgICAgICAgZGlza1RvdGFsID0gTWF0aC5tYXgoMCwgKE51bWJlcihkaXNr
VG90YWwpIHx8IDApIC0gMSk7DQogICAgICAgICAgICBwaW5uZWRUb3RhbCA9IE1hdGgubWF4KDAs
IChOdW1iZXIocGlubmVkVG90YWwpIHx8IDApIC0gMSk7DQogICAgICAgICAgICBpZiAoK3NlbGVj
dGVkSWQgPT09IGlkKQ0KICAgICAgICAgICAgICAgIHNlbGVjdGVkSWQgPSBhbGxDbGlwcy5sZW5n
dGggPyBhbGxDbGlwc1swXS5pZCA6IDA7DQogICAgICAgICAgICB0cnkgew0KICAgICAgICAgICAg
ICAgIHZpZXdNZW0uc2V0KHZpZXdNZW1LZXkoY3VyVGFiLCBxdWVyeSwgdG9kYXlPbmx5KSwgew0K
ICAgICAgICAgICAgICAgICAgICBpdGVtczogYWxsQ2xpcHMuc2xpY2UoKSwNCiAgICAgICAgICAg
ICAgICAgICAgdG90YWw6IGRpc2tUb3RhbA0KICAgICAgICAgICAgICAgIH0pOw0KICAgICAgICAg
ICAgfSBjYXRjaCB7fQ0KICAgICAgICAgICAgY2xlYXJGYXZVbnNlZW4oKTsNCiAgICAgICAgfSBl
bHNlIGlmIChjdXJUYWIgPT09ICdwaW5uZWQnKSB7DQogICAgICAgICAgICBjbGVhckZhdlVuc2Vl
bigpOw0KICAgICAgICB9DQogICAgICAgIHJlbmRlcigpOw0KICAgICAgICBhaGsoJ3BpbicsIFN0
cmluZyhjLmlkKSk7DQogICAgfSk7DQogICAgY3R4QmluZCgnYy10b3AnLCAgIGMgPT4gYWhrKCdt
b3ZlVG9Ub3AnLCAgICAgU3RyaW5nKGMuaWQpKSk7DQogICAgY3R4QmluZCgnYy1jbGVhci1wYXN0
ZWQnLCBjID0+IGFoaygnY2xlYXJQYXN0ZWQnLCBTdHJpbmcoYy5pZCkpKTsNCiAgICBjdHhCaW5k
KCdjLXF1ZXVlLWZyb20nLCBjID0+IHsNCiAgICAgICAgYWhrKCdyZXNldFF1ZXVlRnJvbScsIFN0
cmluZyhjLmlkKSk7DQogICAgICAgIGlmICghcGlubmVkVUkpIGFoaygnaGlkZScpOw0KICAgIH0p
Ow0KICAgIGZ1bmN0aW9uIGNvbGxlY3RRdWV1ZUVucXVldWVJZHMoc2VlZElkcykgew0KICAgICAg
ICBjb25zdCBzZWVkcyA9IChzZWVkSWRzIHx8IFtdKS5tYXAoeCA9PiAreCkuZmlsdGVyKHggPT4g
eCA+IDApOw0KICAgICAgICBpZiAoIXNlZWRzLmxlbmd0aCkgcmV0dXJuIFtdOw0KICAgICAgICBj
b25zdCBzZWVuID0gbmV3IFNldCgpOw0KICAgICAgICBjb25zdCBzZWVuRyA9IG5ldyBTZXQoKTsN
CiAgICAgICAgY29uc3Qgb3V0ID0gW107DQogICAgICAgIGNvbnN0IHB1c2hJZCA9IGlkID0+IHsN
CiAgICAgICAgICAgIGlkID0gK2lkOw0KICAgICAgICAgICAgaWYgKCFpZCB8fCBzZWVuLmhhcyhp
ZCkpIHJldHVybjsNCiAgICAgICAgICAgIHNlZW4uYWRkKGlkKTsNCiAgICAgICAgICAgIG91dC5w
dXNoKGlkKTsNCiAgICAgICAgfTsNCiAgICAgICAgY29uc3QgZXhwYW5kRyA9IGcgPT4gew0KICAg
ICAgICAgICAgZyA9IE51bWJlcihnKSB8fCAwOw0KICAgICAgICAgICAgaWYgKGcgPCAxIHx8IHNl
ZW5HLmhhcyhnKSkgcmV0dXJuOw0KICAgICAgICAgICAgc2VlbkcuYWRkKGcpOw0KICAgICAgICAg
ICAgYWxsQ2xpcHMuZm9yRWFjaCh4ID0+IHsNCiAgICAgICAgICAgICAgICBpZiAoTnVtYmVyKHgu
cXVldWVHcm91cCkgPT09IGcpIHB1c2hJZCh4LmlkKTsNCiAgICAgICAgICAgIH0pOw0KICAgICAg
ICB9Ow0KICAgICAgICBzZWVkcy5mb3JFYWNoKGlkID0+IHsNCiAgICAgICAgICAgIGNvbnN0IGl0
ID0gYWxsQ2xpcHMuZmluZCh4ID0+ICt4LmlkID09PSAraWQpOw0KICAgICAgICAgICAgY29uc3Qg
ZyA9IGl0ID8gTnVtYmVyKGl0LnF1ZXVlR3JvdXApIHx8IDAgOiAwOw0KICAgICAgICAgICAgaWYg
KGcgPiAwKSBleHBhbmRHKGcpOw0KICAgICAgICAgICAgZWxzZSBwdXNoSWQoaWQpOw0KICAgICAg
ICB9KTsNCiAgICAgICAgLy8g5Ye66Zif6aG65bqP77ya5YiX6KGo5LuO5LiL5b6A5LiK77yIYWxs
Q2xpcHMg5LiL5qCH5aSnID0g5pu06Z2g5LiL77yJDQogICAgICAgIGNvbnN0IHBvcyA9IG5ldyBN
YXAoYWxsQ2xpcHMubWFwKCh4LCBpKSA9PiBbK3guaWQsIGldKSk7DQogICAgICAgIG91dC5zb3J0
KChhLCBiKSA9PiAocG9zLmdldCgrYikgPz8gLTEpIC0gKHBvcy5nZXQoK2EpID8/IC0xKSk7DQog
ICAgICAgIHJldHVybiBvdXQ7DQogICAgfQ0KICAgIGZ1bmN0aW9uIHBhaW50UXVldWVNZXRhTG9j
YWwoaWRzKSB7DQogICAgICAgIGNvbnN0IGxpc3QgPSAoaWRzIHx8IFtdKS5tYXAoeCA9PiAreCku
ZmlsdGVyKHggPT4geCA+IDApOw0KICAgICAgICBpZiAoIWxpc3QubGVuZ3RoKSByZXR1cm47DQog
ICAgICAgIGxldCBtYXhHID0gMDsNCiAgICAgICAgYWxsQ2xpcHMuZm9yRWFjaCh4ID0+IHsNCiAg
ICAgICAgICAgIGNvbnN0IGcgPSBOdW1iZXIoeC5xdWV1ZUdyb3VwKSB8fCAwOw0KICAgICAgICAg
ICAgaWYgKGcgPiBtYXhHKSBtYXhHID0gZzsNCiAgICAgICAgfSk7DQogICAgICAgIGNvbnN0IGcg
PSBtYXhHICsgMTsNCiAgICAgICAgY29uc3QgaWRTZXQgPSBuZXcgU2V0KGxpc3QpOw0KICAgICAg
ICBsaXN0LmZvckVhY2goKGlkLCBpKSA9PiB7DQogICAgICAgICAgICBjb25zdCBpdCA9IGFsbENs
aXBzLmZpbmQoeCA9PiAreC5pZCA9PT0gaWQpOw0KICAgICAgICAgICAgaWYgKCFpdCkgcmV0dXJu
Ow0KICAgICAgICAgICAgaXQucXVldWVHcm91cCA9IGc7DQogICAgICAgICAgICBpdC5xdWV1ZUlu
ZGV4ID0gaSArIDE7DQogICAgICAgICAgICBpdC5wYXN0ZWQgPSBmYWxzZTsNCiAgICAgICAgfSk7
DQogICAgICAgIC8vIERyb3AgcXVldWUgdGFncyBvbiByb3dzIHRoYXQgbGVmdCB0aGlzIHNlc3Np
b24gdmlzdWFsbHkgKHNhbWUgZ3JvdXAgcGFpbnQpDQogICAgICAgIHRyeSB7DQogICAgICAgICAg
ICB2aWV3TWVtLmZvckVhY2goKGVudHJ5KSA9PiB7DQogICAgICAgICAgICAgICAgaWYgKCFlbnRy
eSB8fCAhQXJyYXkuaXNBcnJheShlbnRyeS5pdGVtcykpIHJldHVybjsNCiAgICAgICAgICAgICAg
ICBlbnRyeS5pdGVtcy5mb3JFYWNoKGl0ID0+IHsNCiAgICAgICAgICAgICAgICAgICAgaWYgKGlk
U2V0LmhhcygraXQuaWQpKSB7DQogICAgICAgICAgICAgICAgICAgICAgICBpdC5xdWV1ZUdyb3Vw
ID0gZzsNCiAgICAgICAgICAgICAgICAgICAgICAgIGl0LnF1ZXVlSW5kZXggPSBsaXN0LmluZGV4
T2YoK2l0LmlkKSArIDE7DQogICAgICAgICAgICAgICAgICAgICAgICBpdC5wYXN0ZWQgPSBmYWxz
ZTsNCiAgICAgICAgICAgICAgICAgICAgfQ0KICAgICAgICAgICAgICAgIH0pOw0KICAgICAgICAg
ICAgfSk7DQogICAgICAgIH0gY2F0Y2gge30NCiAgICAgICAgdHJ5IHsgcmVuZGVyKCk7IH0gY2F0
Y2gge30NCiAgICAgICAgdHJ5IHsgbWFya1F1ZXVlUmFpbHMoKTsgfSBjYXRjaCB7fQ0KICAgIH0N
CiAgICBjdHhCaW5kKCdjLXF1ZXVlLWluJywgYyA9PiB7DQogICAgICAgIGxldCBpZHMgPSBbXTsN
CiAgICAgICAgaWYgKG11bHRpSWRzLmxlbmd0aCA+PSAyICYmIG11bHRpSWRzLmluY2x1ZGVzKCtj
LmlkKSkNCiAgICAgICAgICAgIGlkcyA9IG11bHRpSWRzLnNsaWNlKCk7DQogICAgICAgIGVsc2UN
CiAgICAgICAgICAgIHJldHVybjsNCiAgICAgICAgaWRzID0gY29sbGVjdFF1ZXVlRW5xdWV1ZUlk
cyhpZHMpOw0KICAgICAgICBpZiAoaWRzLmxlbmd0aCA8IDIpIHJldHVybjsNCiAgICAgICAgcGFp
bnRRdWV1ZU1ldGFMb2NhbChpZHMpOw0KICAgICAgICBhaGsoJ2VucXVldWVNYW55JywgaWRzLmpv
aW4oJywnKSk7DQogICAgICAgIGNsZWFyTXVsdGkoKTsNCiAgICB9KTsNCiAgICBjdHhCaW5kKCdj
LXF1ZXVlLW91dCcsIGMgPT4gew0KICAgICAgICBsZXQgaWRzID0gW107DQogICAgICAgIGlmICht
dWx0aUlkcy5sZW5ndGggPj0gMSAmJiBtdWx0aUlkcy5pbmNsdWRlcygrYy5pZCkpDQogICAgICAg
ICAgICBpZHMgPSBtdWx0aUlkcy5zbGljZSgpOw0KICAgICAgICBlbHNlDQogICAgICAgICAgICBp
ZHMgPSBbK2MuaWRdOw0KICAgICAgICBpZHMgPSBpZHMubWFwKHggPT4gK3gpLmZpbHRlcih4ID0+
IHggPiAwKTsNCiAgICAgICAgaWYgKCFpZHMubGVuZ3RoKSByZXR1cm47DQogICAgICAgIGNvbnN0
IGlkU2V0ID0gbmV3IFNldChpZHMpOw0KICAgICAgICBhbGxDbGlwcy5mb3JFYWNoKGl0ID0+IHsN
CiAgICAgICAgICAgIGlmIChpZFNldC5oYXMoK2l0LmlkKSkgew0KICAgICAgICAgICAgICAgIGl0
LnF1ZXVlR3JvdXAgPSAwOw0KICAgICAgICAgICAgICAgIGl0LnF1ZXVlSW5kZXggPSAwOw0KICAg
ICAgICAgICAgfQ0KICAgICAgICB9KTsNCiAgICAgICAgdHJ5IHsgcmVuZGVyKCk7IH0gY2F0Y2gg
e30NCiAgICAgICAgdHJ5IHsgbWFya1F1ZXVlUmFpbHMoKTsgfSBjYXRjaCB7fQ0KICAgICAgICBh
aGsoJ2RlcXVldWVNYW55JywgaWRzLmpvaW4oJywnKSk7DQogICAgICAgIGNsZWFyTXVsdGkoKTsN
CiAgICB9KTsNCiAgICBjdHhCaW5kKCdjLWRlbCcsICAgYyA9PiB7DQogICAgICAgIC8vIOWkmumA
ieS4lOWPs+mUrueCueWcqOmAieS4remhueS4iiDihpIg5om56YeP5Yig6Zmk77yb5ZCm5YiZ5Y+q
5Yig5b2T5YmNDQogICAgICAgIGxldCBpZHMgPSBbXTsNCiAgICAgICAgaWYgKG11bHRpSWRzLmxl
bmd0aCA+IDEgJiYgbXVsdGlJZHMuaW5jbHVkZXMoK2MuaWQpKQ0KICAgICAgICAgICAgaWRzID0g
bXVsdGlJZHMuc2xpY2UoKTsNCiAgICAgICAgZWxzZQ0KICAgICAgICAgICAgaWRzID0gWytjLmlk
XTsNCiAgICAgICAgaWRzID0gaWRzLm1hcCh4ID0+ICt4KS5maWx0ZXIoeCA9PiB4ID4gMCk7DQog
ICAgICAgIGlmICghaWRzLmxlbmd0aCkgcmV0dXJuOw0KICAgICAgICB0cnkgew0KICAgICAgICAg
ICAgY29uc3QgaWRTZXQgPSBuZXcgU2V0KGlkcyk7DQogICAgICAgICAgICBhbGxDbGlwcyA9IGFs
bENsaXBzLmZpbHRlcih4ID0+ICFpZFNldC5oYXMoK3guaWQpKTsNCiAgICAgICAgICAgIGRpc2tU
b3RhbCA9IE1hdGgubWF4KDAsIChOdW1iZXIoZGlza1RvdGFsKSB8fCAwKSAtIGlkcy5sZW5ndGgp
Ow0KICAgICAgICAgICAgaWYgKGlkU2V0Lmhhcygrc2VsZWN0ZWRJZCkpDQogICAgICAgICAgICAg
ICAgc2VsZWN0ZWRJZCA9IGFsbENsaXBzLmxlbmd0aCA/IGFsbENsaXBzWzBdLmlkIDogMDsNCiAg
ICAgICAgICAgIGNsZWFyTXVsdGkoKTsNCiAgICAgICAgICAgIHJlbmRlcigpOw0KICAgICAgICB9
IGNhdGNoIHt9DQogICAgICAgIGlmIChpZHMubGVuZ3RoID09PSAxKQ0KICAgICAgICAgICAgYWhr
KCdkZWxldGUnLCBTdHJpbmcoaWRzWzBdKSk7DQogICAgICAgIGVsc2UNCiAgICAgICAgICAgIGFo
aygnZGVsZXRlTWFueScsIGlkcy5qb2luKCcsJykpOw0KICAgIH0pOw0KICAgIGN0eEJpbmQoJ2Mt
dGl0bGUnLCBjID0+IG9wZW5UaXRsZURsZyhjKSk7DQogICAgY3R4QmluZCgnYy1tZXJnZScsIGMg
PT4gew0KICAgICAgICBjb25zdCBpZHMgPSAobXVsdGlJZHMubGVuZ3RoID49IDIpID8gbXVsdGlJ
ZHMuc2xpY2UoKSA6IFtdOw0KICAgICAgICBpZiAoaWRzLmxlbmd0aCA8IDIpIHJldHVybjsNCiAg
ICAgICAgaWYgKCFpZHMuaW5jbHVkZXMoK2MuaWQpKSBpZHMucHVzaCgrYy5pZCk7DQogICAgICAg
IGFoaygnbWVyZ2VGYXYnLCBpZHMuam9pbignLCcpKTsNCiAgICAgICAgY2xlYXJNdWx0aSgpOw0K
ICAgIH0pOw0KICAgIGN0eEJpbmQoJ2MtdW5tZXJnZScsIGMgPT4gew0KICAgICAgICBhaGsoJ3Vu
bWVyZ2VGYXYnLCBTdHJpbmcoYy5pZCkpOw0KICAgICAgICBjbGVhck11bHRpKCk7DQogICAgfSk7
DQoNCiAgICBjb25zdCB0aXRsZURsZyA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd0aXRsZS1k
bGcnKTsNCiAgICBjb25zdCB0aXRsZUlucHV0ID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3Rp
dGxlLWlucHV0Jyk7DQogICAgbGV0IHRpdGxlRGxnQ2xpcCA9IG51bGw7DQogICAgZnVuY3Rpb24g
Y2xvc2VUaXRsZURsZygpIHsNCiAgICAgICAgaWYgKHRpdGxlRGxnKSB0aXRsZURsZy5jbGFzc0xp
c3QucmVtb3ZlKCdvbicpOw0KICAgICAgICB0aXRsZURsZ0NsaXAgPSBudWxsOw0KICAgIH0NCiAg
ICBmdW5jdGlvbiBmb2N1c1RpdGxlSW5wdXQoKSB7DQogICAgICAgIHRyeSB7IGFoaygnZm9jdXNQ
YW5lbCcpOyB9IGNhdGNoIHt9DQogICAgICAgIHRyeSB7DQogICAgICAgICAgICBpZiAoIXRpdGxl
SW5wdXQpIHJldHVybjsNCiAgICAgICAgICAgIHRpdGxlSW5wdXQuZm9jdXMoeyBwcmV2ZW50U2Ny
b2xsOiB0cnVlIH0pOw0KICAgICAgICAgICAgdGl0bGVJbnB1dC5zZWxlY3QoKTsNCiAgICAgICAg
fSBjYXRjaCB7DQogICAgICAgICAgICB0cnkgeyB0aXRsZUlucHV0LmZvY3VzKCk7IHRpdGxlSW5w
dXQuc2VsZWN0KCk7IH0gY2F0Y2gge30NCiAgICAgICAgfQ0KICAgIH0NCiAgICBmdW5jdGlvbiBv
cGVuVGl0bGVEbGcoYykgew0KICAgICAgICBoaWRlQ3R4KCk7DQogICAgICAgIHRpdGxlRGxnQ2xp
cCA9IGM7DQogICAgICAgIGlmICh0aXRsZUlucHV0KSB0aXRsZUlucHV0LnZhbHVlID0gU3RyaW5n
KGMuZmF2VGl0bGUgfHwgJycpLnRyaW0oKTsNCiAgICAgICAgaWYgKHRpdGxlRGxnKSB0aXRsZURs
Zy5jbGFzc0xpc3QuYWRkKCdvbicpOw0KICAgICAgICBmb2N1c1RpdGxlSW5wdXQoKTsNCiAgICAg
ICAgcmVxdWVzdEFuaW1hdGlvbkZyYW1lKGZvY3VzVGl0bGVJbnB1dCk7DQogICAgICAgIHNldFRp
bWVvdXQoZm9jdXNUaXRsZUlucHV0LCA0MCk7DQogICAgICAgIHNldFRpbWVvdXQoZm9jdXNUaXRs
ZUlucHV0LCAxMjApOw0KICAgIH0NCiAgICBpZiAodGl0bGVJbnB1dCkgew0KICAgICAgICB0aXRs
ZUlucHV0LmFkZEV2ZW50TGlzdGVuZXIoJ21vdXNlZG93bicsIGUgPT4gew0KICAgICAgICAgICAg
ZS5zdG9wUHJvcGFnYXRpb24oKTsNCiAgICAgICAgICAgIHRyeSB7IGFoaygnZm9jdXNQYW5lbCcp
OyB9IGNhdGNoIHt9DQogICAgICAgIH0pOw0KICAgICAgICB0aXRsZUlucHV0LmFkZEV2ZW50TGlz
dGVuZXIoJ2ZvY3VzJywgKCkgPT4gew0KICAgICAgICAgICAgdHJ5IHsgYWhrKCdmb2N1c1BhbmVs
Jyk7IH0gY2F0Y2gge30NCiAgICAgICAgfSk7DQogICAgfQ0KICAgIGlmICh0aXRsZURsZykgew0K
ICAgICAgICB0aXRsZURsZy5hZGRFdmVudExpc3RlbmVyKCdjbGljaycsIGUgPT4gew0KICAgICAg
ICAgICAgaWYgKGUudGFyZ2V0ID09PSB0aXRsZURsZykgew0KICAgICAgICAgICAgICAgIGNsb3Nl
VGl0bGVEbGcoKTsNCiAgICAgICAgICAgICAgICB0cnkgeyBhaGsoJ2JsdXJQYW5lbCcpOyB9IGNh
dGNoIHt9DQogICAgICAgICAgICB9DQogICAgICAgIH0pOw0KICAgICAgICB0aXRsZURsZy5hZGRF
dmVudExpc3RlbmVyKCdtb3VzZWRvd24nLCBlID0+IGUuc3RvcFByb3BhZ2F0aW9uKCkpOw0KICAg
IH0NCiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgndGl0bGUtY2FuY2VsJyk/LmFkZEV2ZW50
TGlzdGVuZXIoJ2NsaWNrJywgZSA9PiB7DQogICAgICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7DQog
ICAgICAgIGNsb3NlVGl0bGVEbGcoKTsNCiAgICAgICAgYWhrKCdibHVyUGFuZWwnKTsNCiAgICB9
KTsNCiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgndGl0bGUtb2snKT8uYWRkRXZlbnRMaXN0
ZW5lcignY2xpY2snLCBlID0+IHsNCiAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsNCiAgICAg
ICAgaWYgKCF0aXRsZURsZ0NsaXApIHJldHVybjsNCiAgICAgICAgY29uc3QgdCA9IFN0cmluZyh0
aXRsZUlucHV0Py52YWx1ZSB8fCAnJykudHJpbSgpLnNsaWNlKDAsIDgwKTsNCiAgICAgICAgY29u
c3QgaWQgPSBTdHJpbmcodGl0bGVEbGdDbGlwLmlkKTsNCiAgICAgICAgLy8gT3B0aW1pc3RpYyBs
b2NhbCB1cGRhdGUNCiAgICAgICAgY29uc3QgaGl0ID0gYWxsQ2xpcHMuZmluZCh4ID0+ICt4Lmlk
ID09PSAraWQpOw0KICAgICAgICBpZiAoaGl0KSBoaXQuZmF2VGl0bGUgPSB0Ow0KICAgICAgICB0
aXRsZURsZ0NsaXAuZmF2VGl0bGUgPSB0Ow0KICAgICAgICBjbG9zZVRpdGxlRGxnKCk7DQogICAg
ICAgIGFoaygnc2V0RmF2VGl0bGUnLCBpZCwgdCk7DQogICAgICAgIGFoaygnYmx1clBhbmVsJyk7
DQogICAgICAgIHJlbmRlcigpOw0KICAgIH0pOw0KICAgIHRpdGxlSW5wdXQ/LmFkZEV2ZW50TGlz
dGVuZXIoJ2tleWRvd24nLCBlID0+IHsNCiAgICAgICAgaWYgKGUua2V5ID09PSAnRW50ZXInKSB7
DQogICAgICAgICAgICBlLnByZXZlbnREZWZhdWx0KCk7DQogICAgICAgICAgICBlLnN0b3BQcm9w
YWdhdGlvbigpOw0KICAgICAgICAgICAgZS5zdG9wSW1tZWRpYXRlUHJvcGFnYXRpb24oKTsNCiAg
ICAgICAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd0aXRsZS1vaycpPy5jbGljaygpOw0K
ICAgICAgICAgICAgcmV0dXJuOw0KICAgICAgICB9DQogICAgICAgIGlmIChlLmtleSA9PT0gJ0Vz
Y2FwZScpIHsNCiAgICAgICAgICAgIGUucHJldmVudERlZmF1bHQoKTsNCiAgICAgICAgICAgIGUu
c3RvcFByb3BhZ2F0aW9uKCk7DQogICAgICAgICAgICBjbG9zZVRpdGxlRGxnKCk7DQogICAgICAg
ICAgICBhaGsoJ2JsdXJQYW5lbCcpOw0KICAgICAgICAgICAgcmV0dXJuOw0KICAgICAgICB9DQog
ICAgICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7DQogICAgfSwgdHJ1ZSk7DQoNCiAgICBkb2N1bWVu
dC5nZXRFbGVtZW50QnlJZCgndGFicycpLmFkZEV2ZW50TGlzdGVuZXIoJ2NsaWNrJywgZSA9PiB7
DQogICAgICAgIGNvbnN0IHRhYiA9IGUudGFyZ2V0LmNsb3Nlc3QoJy50YWInKTsNCiAgICAgICAg
aWYgKCF0YWIgfHwgZS50YXJnZXQuY2xvc2VzdCgnI3RhYi1hY3Rpb25zJykpIHJldHVybjsNCiAg
ICAgICAgc2V0VGFiKHRhYi5kYXRhc2V0LnRhYik7DQogICAgfSk7DQoNCiAgICBjb25zdCBzcmNo
V3JhcCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzZWFyY2gtd3JhcCcpOw0KICAgIGNvbnN0
IGJ0blNlYXJjaCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdidG4tc2VhcmNoJyk7DQogICAg
Y29uc3QgYnRuTG9jYXRlID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2J0bi1sb2NhdGUnKTsN
CiAgICBjb25zdCBidG5Ub2RheSA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdidG4tdG9kYXkn
KTsNCiAgICBjb25zdCBzcmNoID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NlYXJjaCcpOw0K
ICAgIGNvbnN0IHNjbHIgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc2VhcmNoLWNscicpOw0K
ICAgIGxldCBkZWI7DQoNCiAgICB1cGRhdGVMb2NhdGVCdG4oKTsNCiAgICBpZiAoYnRuTG9jYXRl
KSB7DQogICAgICAgIGJ0bkxvY2F0ZS5hZGRFdmVudExpc3RlbmVyKCdjbGljaycsIGUgPT4gew0K
ICAgICAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsNCiAgICAgICAgICAgIGp1bXBUb0xhc3RQ
YXN0ZSgpOw0KICAgICAgICB9KTsNCiAgICB9DQoNCiAgICBidG5Ub2RheS5hZGRFdmVudExpc3Rl
bmVyKCdtb3VzZWRvd24nLCBlID0+IHsNCiAgICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOw0KICAg
ICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOw0KICAgIH0pOw0KICAgIGJ0blRvZGF5LmFkZEV2ZW50
TGlzdGVuZXIoJ2NsaWNrJywgZSA9PiB7DQogICAgICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7DQog
ICAgICAgIGUucHJldmVudERlZmF1bHQoKTsNCiAgICAgICAgdG9kYXlPbmx5ID0gIXRvZGF5T25s
eTsNCiAgICAgICAgYnRuVG9kYXkuY2xhc3NMaXN0LnRvZ2dsZSgnb24nLCB0b2RheU9ubHkpOw0K
ICAgICAgICBsaXN0RWwuc2Nyb2xsVG9wID0gMDsNCiAgICAgICAgcmVxdWVzdFZpZXcoKTsNCiAg
ICAgICAgdHJ5IHsgc3JjaC5mb2N1cygpOyB9IGNhdGNoIHt9DQogICAgfSk7DQoNCiAgICBmdW5j
dGlvbiBvcGVuU2VhcmNoKCkgew0KICAgICAgICBpZiAoc3JjaFdyYXAuY2xhc3NMaXN0LmNvbnRh
aW5zKCdvcGVuJykpIHsNCiAgICAgICAgICAgIGFoaygnZm9jdXNQYW5lbCcpOw0KICAgICAgICAg
ICAgdHJ5IHsgc3JjaC5mb2N1cygpOyB9IGNhdGNoIHt9DQogICAgICAgICAgICByZXR1cm47DQog
ICAgICAgIH0NCiAgICAgICAgc3JjaFdyYXAuY2xhc3NMaXN0LmFkZCgnb3BlbicpOw0KICAgICAg
ICAvLyBEZWZhdWx0OiDmiYDmnInpobXmiZPlvIDmkJzntKLml7bpu5jorqTmkJzlhajpg6gNCiAg
ICAgICAgY29uc3Qgd2FudFRvZGF5ID0gZmFsc2U7DQogICAgICAgIGlmICh0b2RheU9ubHkgIT09
IHdhbnRUb2RheSkgew0KICAgICAgICAgICAgdG9kYXlPbmx5ID0gd2FudFRvZGF5Ow0KICAgICAg
ICAgICAgYnRuVG9kYXkuY2xhc3NMaXN0LnRvZ2dsZSgnb24nLCB0b2RheU9ubHkpOw0KICAgICAg
ICAgICAgbGlzdEVsLnNjcm9sbFRvcCA9IDA7DQogICAgICAgICAgICByZXF1ZXN0VmlldygpOw0K
ICAgICAgICB9IGVsc2Ugew0KICAgICAgICAgICAgYnRuVG9kYXkuY2xhc3NMaXN0LnRvZ2dsZSgn
b24nLCB0b2RheU9ubHkpOw0KICAgICAgICB9DQogICAgICAgIGFoaygnZm9jdXNQYW5lbCcpOw0K
ICAgICAgICByZXF1ZXN0QW5pbWF0aW9uRnJhbWUoKCkgPT4gew0KICAgICAgICAgICAgdHJ5IHsg
c3JjaC5mb2N1cygpOyB9IGNhdGNoIHt9DQogICAgICAgIH0pOw0KICAgIH0NCiAgICBmdW5jdGlv
biBjbG9zZVNlYXJjaFVpKCkgew0KICAgICAgICBzcmNoV3JhcC5jbGFzc0xpc3QucmVtb3ZlKCdv
cGVuJyk7DQogICAgICAgIGlmICghc3JjaC52YWx1ZSkgew0KICAgICAgICAgICAgc3JjaC5jbGFz
c0xpc3QucmVtb3ZlKCdoYXMtdmFsJyk7DQogICAgICAgICAgICBzY2xyLnN0eWxlLmRpc3BsYXkg
PSAnbm9uZSc7DQogICAgICAgICAgICAvLyBMZWF2aW5nIHNlYXJjaCB3aXRoIGVtcHR5IHF1ZXJ5
IOKGkiBkcm9wIHRvZGF5IGZpbHRlcg0KICAgICAgICAgICAgaWYgKHRvZGF5T25seSkgew0KICAg
ICAgICAgICAgICAgIHRvZGF5T25seSA9IGZhbHNlOw0KICAgICAgICAgICAgICAgIGJ0blRvZGF5
LmNsYXNzTGlzdC5yZW1vdmUoJ29uJyk7DQogICAgICAgICAgICAgICAgcmVxdWVzdFZpZXcoKTsN
CiAgICAgICAgICAgIH0NCiAgICAgICAgfQ0KICAgIH0NCiAgICB3aW5kb3cuX19vcGVuU2VhcmNo
ID0gb3BlblNlYXJjaDsNCiAgICB3aW5kb3cuX19wcmVwVHlwZVNlYXJjaCA9ICgpID0+IHsNCiAg
ICAgICAgdHJ5IHsNCiAgICAgICAgICAgIGNvbnN0IHdyYXAgPSBkb2N1bWVudC5nZXRFbGVtZW50
QnlJZCgnc2VhcmNoLXdyYXAnKTsNCiAgICAgICAgICAgIGNvbnN0IHMgPSBkb2N1bWVudC5nZXRF
bGVtZW50QnlJZCgnc2VhcmNoJyk7DQogICAgICAgICAgICBpZiAod3JhcCAmJiAhd3JhcC5jbGFz
c0xpc3QuY29udGFpbnMoJ29wZW4nKSkgew0KICAgICAgICAgICAgICAgIHdyYXAuY2xhc3NMaXN0
LmFkZCgnb3BlbicpOw0KICAgICAgICAgICAgICAgIHRyeSB7DQogICAgICAgICAgICAgICAgICAg
IGNvbnN0IHdhbnRUb2RheSA9IGZhbHNlOw0KICAgICAgICAgICAgICAgICAgICBpZiAodHlwZW9m
IHRvZGF5T25seSAhPT0gJ3VuZGVmaW5lZCcgJiYgdG9kYXlPbmx5ICE9PSB3YW50VG9kYXkpIHsN
CiAgICAgICAgICAgICAgICAgICAgICAgIHRvZGF5T25seSA9IHdhbnRUb2RheTsNCiAgICAgICAg
ICAgICAgICAgICAgICAgIGlmICh0eXBlb2YgYnRuVG9kYXkgIT09ICd1bmRlZmluZWQnICYmIGJ0
blRvZGF5KSBidG5Ub2RheS5jbGFzc0xpc3QudG9nZ2xlKCdvbicsIHRvZGF5T25seSk7DQogICAg
ICAgICAgICAgICAgICAgICAgICBpZiAodHlwZW9mIGxpc3RFbCAhPT0gJ3VuZGVmaW5lZCcgJiYg
bGlzdEVsKSBsaXN0RWwuc2Nyb2xsVG9wID0gMDsNCiAgICAgICAgICAgICAgICAgICAgICAgIGlm
ICh0eXBlb2YgcmVxdWVzdFZpZXcgPT09ICdmdW5jdGlvbicpIHNldFRpbWVvdXQocmVxdWVzdFZp
ZXcsIDApOw0KICAgICAgICAgICAgICAgICAgICB9IGVsc2UgaWYgKHR5cGVvZiBidG5Ub2RheSAh
PT0gJ3VuZGVmaW5lZCcgJiYgYnRuVG9kYXkpIHsNCiAgICAgICAgICAgICAgICAgICAgICAgIGJ0
blRvZGF5LmNsYXNzTGlzdC50b2dnbGUoJ29uJywgISF0b2RheU9ubHkpOw0KICAgICAgICAgICAg
ICAgICAgICB9DQogICAgICAgICAgICAgICAgfSBjYXRjaCB7fQ0KICAgICAgICAgICAgfQ0KICAg
ICAgICAgICAgLy8gPz8g6ZWc5YOP5pCc57Si77ya5LiN6KaBIGZvY3Vz77yM6YG/5YWN5oqi6LWw
5Y6f57yW6L6R5qGG5YWJ5qCHDQogICAgICAgIH0gY2F0Y2gge30NCiAgICB9Ow0KICAgIHdpbmRv
dy5fX3R5cGVTZWFyY2ggPSAoY2gpID0+IHsNCiAgICAgICAgdHJ5IHsNCiAgICAgICAgICAgIHdp
bmRvdy5fX3ByZXBUeXBlU2VhcmNoICYmIHdpbmRvdy5fX3ByZXBUeXBlU2VhcmNoKCk7DQogICAg
ICAgICAgICBjb25zdCBzID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NlYXJjaCcpOw0KICAg
ICAgICAgICAgaWYgKCFzKSByZXR1cm47DQogICAgICAgICAgICBzLnZhbHVlID0gU3RyaW5nKHMu
dmFsdWUgfHwgJycpICsgU3RyaW5nKGNoID09IG51bGwgPyAnJyA6IGNoKTsNCiAgICAgICAgICAg
IHMuY2xhc3NMaXN0LnRvZ2dsZSgnaGFzLXZhbCcsICEhcy52YWx1ZSk7DQogICAgICAgICAgICBz
LmRpc3BhdGNoRXZlbnQobmV3IEV2ZW50KCdpbnB1dCcsIHsgYnViYmxlczogdHJ1ZSB9KSk7DQog
ICAgICAgIH0gY2F0Y2gge30NCiAgICB9Ow0KICAgIHdpbmRvdy5fX2Jrc3BTZWFyY2ggPSAoKSA9
PiB7DQogICAgICAgIHRyeSB7DQogICAgICAgICAgICB3aW5kb3cuX19wcmVwVHlwZVNlYXJjaCAm
JiB3aW5kb3cuX19wcmVwVHlwZVNlYXJjaCgpOw0KICAgICAgICAgICAgY29uc3QgcyA9IGRvY3Vt
ZW50LmdldEVsZW1lbnRCeUlkKCdzZWFyY2gnKTsNCiAgICAgICAgICAgIGlmICghcykgcmV0dXJu
Ow0KICAgICAgICAgICAgY29uc3QgdiA9IFN0cmluZyhzLnZhbHVlIHx8ICcnKTsNCiAgICAgICAg
ICAgIHMudmFsdWUgPSB2Lmxlbmd0aCA/IHYuc2xpY2UoMCwgLTEpIDogJyc7DQogICAgICAgICAg
ICBzLmNsYXNzTGlzdC50b2dnbGUoJ2hhcy12YWwnLCAhIXMudmFsdWUpOw0KICAgICAgICAgICAg
cy5kaXNwYXRjaEV2ZW50KG5ldyBFdmVudCgnaW5wdXQnLCB7IGJ1YmJsZXM6IHRydWUgfSkpOw0K
ICAgICAgICB9IGNhdGNoIHt9DQogICAgfTsNCiAgICB3aW5kb3cuX19zZXRTZWFyY2hRdWVyeSA9
IChxKSA9PiB7DQogICAgICAgIHRyeSB7DQogICAgICAgICAgICBjb25zdCBzID0gZG9jdW1lbnQu
Z2V0RWxlbWVudEJ5SWQoJ3NlYXJjaCcpOw0KICAgICAgICAgICAgaWYgKCFzKSByZXR1cm47DQog
ICAgICAgICAgICBjb25zdCBuZXh0ID0gU3RyaW5nKHEgPT0gbnVsbCA/ICcnIDogcSk7DQogICAg
ICAgICAgICBjb25zdCBwcmV2ID0gU3RyaW5nKHMudmFsdWUgfHwgJycpOw0KICAgICAgICAgICAg
Ly8g5ZCM5YWz6ZSu5a2X6YeN5aSN5o6o6YCB77ya5Y+q5L+d6K+B5pCc57Si5qGG5byA552A77yM
56aB5q2i5YaNIHJlcXVlc3RWaWV377yI5Lya5q275b6q546v6Zeq77yJDQogICAgICAgICAgICBp
ZiAocHJldiA9PT0gbmV4dCAmJiBTdHJpbmcocXVlcnkgfHwgJycpID09PSBuZXh0KSB7DQogICAg
ICAgICAgICAgICAgdHJ5IHsNCiAgICAgICAgICAgICAgICAgICAgY29uc3Qgd3JhcCA9IGRvY3Vt
ZW50LmdldEVsZW1lbnRCeUlkKCdzZWFyY2gtd3JhcCcpOw0KICAgICAgICAgICAgICAgICAgICBp
ZiAod3JhcCAmJiAhd3JhcC5jbGFzc0xpc3QuY29udGFpbnMoJ29wZW4nKSkNCiAgICAgICAgICAg
ICAgICAgICAgICAgIHdyYXAuY2xhc3NMaXN0LmFkZCgnb3BlbicpOw0KICAgICAgICAgICAgICAg
IH0gY2F0Y2gge30NCiAgICAgICAgICAgICAgICByZXR1cm47DQogICAgICAgICAgICB9DQogICAg
ICAgICAgICAvLyDmiZPlrZfljbPml7bkuIrlsY/vvIzkuI7no4Hnm5jmkJzntKLop6PogKYNCiAg
ICAgICAgICAgIHMudmFsdWUgPSBuZXh0Ow0KICAgICAgICAgICAgcy5jbGFzc0xpc3QudG9nZ2xl
KCdoYXMtdmFsJywgISFzLnZhbHVlKTsNCiAgICAgICAgICAgIGNvbnN0IHNjbHIgPSBkb2N1bWVu
dC5nZXRFbGVtZW50QnlJZCgnc2VhcmNoLWNscicpOw0KICAgICAgICAgICAgaWYgKHNjbHIpIHNj
bHIuc3R5bGUuZGlzcGxheSA9IHMudmFsdWUgPyAnYmxvY2snIDogJ25vbmUnOw0KICAgICAgICAg
ICAgcXVlcnkgPSBzLnZhbHVlOw0KICAgICAgICAgICAgdHJ5IHsNCiAgICAgICAgICAgICAgICBj
b25zdCB3cmFwID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NlYXJjaC13cmFwJyk7DQogICAg
ICAgICAgICAgICAgaWYgKHdyYXAgJiYgIXdyYXAuY2xhc3NMaXN0LmNvbnRhaW5zKCdvcGVuJykp
DQogICAgICAgICAgICAgICAgICAgIHdpbmRvdy5fX3ByZXBUeXBlU2VhcmNoICYmIHdpbmRvdy5f
X3ByZXBUeXBlU2VhcmNoKCk7DQogICAgICAgICAgICAgICAgZWxzZSBpZiAod3JhcCkNCiAgICAg
ICAgICAgICAgICAgICAgd3JhcC5jbGFzc0xpc3QuYWRkKCdvcGVuJyk7DQogICAgICAgICAgICB9
IGNhdGNoIHt9DQogICAgICAgICAgICB3aW5kb3cuX19ob3N0RmlsdGVyZWQgPSBmYWxzZTsNCiAg
ICAgICAgICAgIHdpbmRvdy5fX2hvc3RGaWx0ZXJRID0gJyc7DQogICAgICAgICAgICBpZiAoU3Ry
aW5nKHF1ZXJ5IHx8ICcnKS50cmltKCkpIHsNCiAgICAgICAgICAgICAgICB3YWl0aW5nRGF0YSA9
IHRydWU7DQogICAgICAgICAgICAgICAgd2luZG93Ll9fZGF0YVJlYWR5ID0gZmFsc2U7DQogICAg
ICAgICAgICB9DQogICAgICAgICAgICB0cnkgew0KICAgICAgICAgICAgICAgIGNvbnN0IGNudCA9
IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdiYXItdHh0Jyk7DQogICAgICAgICAgICAgICAgaWYg
KGNudCAmJiBTdHJpbmcocXVlcnkgfHwgJycpLnRyaW0oKSkNCiAgICAgICAgICAgICAgICAgICAg
Y250LnRleHRDb250ZW50ID0gdmlzaWJsZUxpc3QoKS5sZW5ndGggKyAnIOadoSc7DQogICAgICAg
ICAgICB9IGNhdGNoIHt9DQogICAgICAgICAgICB0cnkgeyByZW5kZXIoKTsgfSBjYXRjaCB7fQ0K
ICAgICAgICAgICAgY2xlYXJUaW1lb3V0KHdpbmRvdy5fX3FxVmlld0RlYik7DQogICAgICAgICAg
ICB3aW5kb3cuX19xcVZpZXdEZWIgPSBzZXRUaW1lb3V0KCgpID0+IHsNCiAgICAgICAgICAgICAg
ICB3aW5kb3cuX19xcVZpZXdEZWIgPSAwOw0KICAgICAgICAgICAgICAgIHJlcXVlc3RWaWV3KCk7
DQogICAgICAgICAgICB9LCA3MCk7DQogICAgICAgIH0gY2F0Y2gge30NCiAgICB9Ow0KICAgIHdp
bmRvdy5fX2NsZWFyUVFTZWFyY2ggPSAoKSA9PiB7DQogICAgICAgIHRyeSB7DQogICAgICAgICAg
ICBxdWVyeSA9ICcnOw0KICAgICAgICAgICAgd2luZG93Ll9faG9zdEZpbHRlcmVkID0gZmFsc2U7
DQogICAgICAgICAgICB3aW5kb3cuX19ob3N0RmlsdGVyUSA9ICcnOw0KICAgICAgICAgICAgY29u
c3QgcyA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzZWFyY2gnKTsNCiAgICAgICAgICAgIGlm
IChzKSB7DQogICAgICAgICAgICAgICAgcy52YWx1ZSA9ICcnOw0KICAgICAgICAgICAgICAgIHMu
Y2xhc3NMaXN0LnJlbW92ZSgnaGFzLXZhbCcpOw0KICAgICAgICAgICAgICAgIHRyeSB7IHMuYmx1
cigpOyB9IGNhdGNoIHt9DQogICAgICAgICAgICB9DQogICAgICAgICAgICBjb25zdCBzY2xyID0g
ZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NlYXJjaC1jbHInKTsNCiAgICAgICAgICAgIGlmIChz
Y2xyKSBzY2xyLnN0eWxlLmRpc3BsYXkgPSAnbm9uZSc7DQogICAgICAgICAgICBjb25zdCB3cmFw
ID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NlYXJjaC13cmFwJyk7DQogICAgICAgICAgICBp
ZiAod3JhcCkgd3JhcC5jbGFzc0xpc3QucmVtb3ZlKCdvcGVuJyk7DQogICAgICAgICAgICB0cnkg
eyByZW5kZXIoKTsgfSBjYXRjaCB7fQ0KICAgICAgICB9IGNhdGNoIHt9DQogICAgfTsNCiAgICAv
LyBDYXB0dXJlIEN0cmwrRiBpbnNpZGUgV2ViVmlldyAoQ2hyb21pdW0gZmluZCBpcyBkaXNhYmxl
ZCwgYnV0IHN0aWxsIGhhbmRsZSBoZXJlKQ0KICAgIGRvY3VtZW50LmFkZEV2ZW50TGlzdGVuZXIo
J2tleWRvd24nLCBlID0+IHsNCiAgICAgICAgaWYgKChlLmN0cmxLZXkgfHwgZS5tZXRhS2V5KSAm
JiAhZS5hbHRLZXkgJiYgKGUua2V5ID09PSAnZicgfHwgZS5rZXkgPT09ICdGJykpIHsNCiAgICAg
ICAgICAgIGUucHJldmVudERlZmF1bHQoKTsNCiAgICAgICAgICAgIGUuc3RvcFByb3BhZ2F0aW9u
KCk7DQogICAgICAgICAgICBvcGVuU2VhcmNoKCk7DQogICAgICAgIH0NCiAgICB9LCB0cnVlKTsN
CiAgICBidG5TZWFyY2guYWRkRXZlbnRMaXN0ZW5lcignY2xpY2snLCBlID0+IHsNCiAgICAgICAg
ZS5zdG9wUHJvcGFnYXRpb24oKTsNCiAgICAgICAgb3BlblNlYXJjaCgpOw0KICAgIH0pOw0KICAg
IGxldCBfX3NyY2hDb21wb3NpbmcgPSBmYWxzZTsNCiAgICBjb25zdCBfX2ZsdXNoU2VhcmNoSW5w
dXQgPSAoKSA9PiB7DQogICAgICAgIHF1ZXJ5ID0gc3JjaC52YWx1ZTsNCiAgICAgICAgc3JjaC5j
bGFzc0xpc3QudG9nZ2xlKCdoYXMtdmFsJywgISFxdWVyeSk7DQogICAgICAgIHNjbHIuc3R5bGUu
ZGlzcGxheSA9IHF1ZXJ5ID8gJ2Jsb2NrJyA6ICdub25lJzsNCiAgICAgICAgbGlzdEVsLnNjcm9s
bFRvcCA9IDA7DQogICAgICAgIHdpbmRvdy5fX2hvc3RGaWx0ZXJlZCA9IGZhbHNlOw0KICAgICAg
ICB3aW5kb3cuX19ob3N0RmlsdGVyUSA9ICcnOw0KICAgICAgICB0cnkgeyByZW5kZXIoKTsgfSBj
YXRjaCB7fQ0KICAgICAgICBjbGVhclRpbWVvdXQoZGViKTsNCiAgICAgICAgZGViID0gc2V0VGlt
ZW91dChyZXF1ZXN0VmlldywgODApOw0KICAgIH07DQogICAgc3JjaC5hZGRFdmVudExpc3RlbmVy
KCdjb21wb3NpdGlvbnN0YXJ0JywgKCkgPT4geyBfX3NyY2hDb21wb3NpbmcgPSB0cnVlOyB9KTsN
CiAgICBzcmNoLmFkZEV2ZW50TGlzdGVuZXIoJ2NvbXBvc2l0aW9uZW5kJywgKCkgPT4gew0KICAg
ICAgICBfX3NyY2hDb21wb3NpbmcgPSBmYWxzZTsNCiAgICAgICAgX19mbHVzaFNlYXJjaElucHV0
KCk7DQogICAgfSk7DQogICAgc3JjaC5hZGRFdmVudExpc3RlbmVyKCdpbnB1dCcsICgpID0+IHsN
CiAgICAgICAgaWYgKF9fc3JjaENvbXBvc2luZykgew0KICAgICAgICAgICAgcXVlcnkgPSBzcmNo
LnZhbHVlOw0KICAgICAgICAgICAgc3JjaC5jbGFzc0xpc3QudG9nZ2xlKCdoYXMtdmFsJywgISFx
dWVyeSk7DQogICAgICAgICAgICBzY2xyLnN0eWxlLmRpc3BsYXkgPSBxdWVyeSA/ICdibG9jaycg
OiAnbm9uZSc7DQogICAgICAgICAgICByZXR1cm47DQogICAgICAgIH0NCiAgICAgICAgX19mbHVz
aFNlYXJjaElucHV0KCk7DQogICAgfSk7DQogICAgc3JjaC5hZGRFdmVudExpc3RlbmVyKCdmb2N1
cycsICgpID0+IHsNCiAgICAgICAgLy8gSWRlbXBvdGVudCBvbiBBSEsgc2lkZSDigJQgc2FmZSwg
YnV0IGF2b2lkIHNwYW1taW5nIGR1cmluZyBJTUUNCiAgICAgICAgdHJ5IHsgYWhrKCdmb2N1c1Bh
bmVsJyk7IH0gY2F0Y2gge30NCiAgICB9KTsNCiAgICBzcmNoLmFkZEV2ZW50TGlzdGVuZXIoJ2Js
dXInLCAoKSA9PiB7DQogICAgICAgIHNldFRpbWVvdXQoKCkgPT4gew0KICAgICAgICAgICAgaWYg
KGRvY3VtZW50LmFjdGl2ZUVsZW1lbnQgPT09IHNyY2gpIHJldHVybjsNCiAgICAgICAgICAgIGlm
IChkb2N1bWVudC5hY3RpdmVFbGVtZW50ID09PSBzY2xyIHx8IChzY2xyICYmIHNjbHIuY29udGFp
bnMoZG9jdW1lbnQuYWN0aXZlRWxlbWVudCkpKSByZXR1cm47DQogICAgICAgICAgICBpZiAoZG9j
dW1lbnQuYWN0aXZlRWxlbWVudCA9PT0gYnRuVG9kYXkgfHwgKGJ0blRvZGF5ICYmIGJ0blRvZGF5
LmNvbnRhaW5zKGRvY3VtZW50LmFjdGl2ZUVsZW1lbnQpKSkgcmV0dXJuOw0KICAgICAgICAgICAg
Ly8gSU1FIGNhbmRpZGF0ZSBVSSBzdGVhbHMgZm9jdXMgYnJpZWZseSDigJQga2VlcCBzZWFyY2gg
aWYgc3RpbGwgY29tcG9zaW5nDQogICAgICAgICAgICBpZiAoX19zcmNoQ29tcG9zaW5nKSByZXR1
cm47DQogICAgICAgICAgICBjbG9zZVNlYXJjaFVpKCk7DQogICAgICAgICAgICBhaGsoJ2JsdXJQ
YW5lbCcpOw0KICAgICAgICB9LCAyODApOw0KICAgIH0pOw0KICAgIHNyY2guYWRkRXZlbnRMaXN0
ZW5lcigna2V5ZG93bicsIGUgPT4gew0KICAgICAgICAvLyBDdHJsK0kgLyBDdHJsK0s6IG1vdmUg
Y2xpcCBzZWxlY3Rpb24gKG5vdCBpbnNlcnQgY2hhciAvIGJyb3dzZXIgc2hvcnRjdXQpDQogICAg
ICAgIGlmICgoZS5jdHJsS2V5IHx8IGUubWV0YUtleSkgJiYgKGUua2V5ID09PSAnaScgfHwgZS5r
ZXkgPT09ICdJJykpIHsNCiAgICAgICAgICAgIGUucHJldmVudERlZmF1bHQoKTsNCiAgICAgICAg
ICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7DQogICAgICAgICAgICB3aW5kb3cuX19uYXYgJiYgd2lu
ZG93Ll9fbmF2KCd1cCcpOw0KICAgICAgICAgICAgcmV0dXJuOw0KICAgICAgICB9DQogICAgICAg
IGlmICgoZS5jdHJsS2V5IHx8IGUubWV0YUtleSkgJiYgKGUua2V5ID09PSAnaycgfHwgZS5rZXkg
PT09ICdLJykpIHsNCiAgICAgICAgICAgIGUucHJldmVudERlZmF1bHQoKTsNCiAgICAgICAgICAg
IGUuc3RvcFByb3BhZ2F0aW9uKCk7DQogICAgICAgICAgICB3aW5kb3cuX19uYXYgJiYgd2luZG93
Ll9fbmF2KCdkb3duJyk7DQogICAgICAgICAgICByZXR1cm47DQogICAgICAgIH0NCiAgICAgICAg
aWYgKGUua2V5ID09PSAnQXJyb3dEb3duJykgew0KICAgICAgICAgICAgZS5wcmV2ZW50RGVmYXVs
dCgpOw0KICAgICAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsNCiAgICAgICAgICAgIHdpbmRv
dy5fX25hdiAmJiB3aW5kb3cuX19uYXYoJ2Rvd24nKTsNCiAgICAgICAgICAgIHJldHVybjsNCiAg
ICAgICAgfQ0KICAgICAgICBpZiAoZS5rZXkgPT09ICdBcnJvd1VwJykgew0KICAgICAgICAgICAg
ZS5wcmV2ZW50RGVmYXVsdCgpOw0KICAgICAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsNCiAg
ICAgICAgICAgIHdpbmRvdy5fX25hdiAmJiB3aW5kb3cuX19uYXYoJ3VwJyk7DQogICAgICAgICAg
ICByZXR1cm47DQogICAgICAgIH0NCiAgICAgICAgaWYgKGUua2V5ID09PSAnRXNjYXBlJykgew0K
ICAgICAgICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOw0KICAgICAgICAgICAgZS5zdG9wUHJvcGFn
YXRpb24oKTsNCiAgICAgICAgICAgIC8vIEFsd2F5cyBkaXNtaXNzIHRoZSB3aG9sZSBwYW5lbCAo
bm90IGp1c3QgdGhlIHNlYXJjaCBmaWVsZCkNCiAgICAgICAgICAgIGlmICghcGlubmVkVUkpIGFo
aygnaGlkZScpOw0KICAgICAgICAgICAgcmV0dXJuOw0KICAgICAgICB9DQogICAgICAgIGUuc3Rv
cFByb3BhZ2F0aW9uKCk7DQogICAgfSk7DQogICAgc2Nsci5hZGRFdmVudExpc3RlbmVyKCdjbGlj
aycsIGUgPT4gew0KICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOw0KICAgICAgICBzcmNoLnZh
bHVlID0gcXVlcnkgPSAnJzsNCiAgICAgICAgc2Nsci5zdHlsZS5kaXNwbGF5ID0gJ25vbmUnOw0K
ICAgICAgICBzcmNoLmNsYXNzTGlzdC5yZW1vdmUoJ2hhcy12YWwnKTsNCiAgICAgICAgcmVxdWVz
dFZpZXcoKTsNCiAgICAgICAgYWhrKCdmb2N1c1BhbmVsJyk7DQogICAgICAgIHNyY2guZm9jdXMo
KTsNCiAgICB9KTsNCg0KICAgIGNvbnN0IFRBQl9OQU1FUyA9IHsgYWxsOiAn5YWo6YOoJywgdGV4
dDogJ+aWh+acrCcsIGltYWdlOiAn5Zu+5YOPJywgZmlsZTogJ+aWh+S7ticsIHJlY2VudDogJ+ac
gOi/kScsIHBpbm5lZDogJ+aUtuiXjycgfTsNCiAgICBjb25zdCBjbHJEbGcgPSBkb2N1bWVudC5n
ZXRFbGVtZW50QnlJZCgnY2xyLWRsZycpOw0KICAgIGNvbnN0IGNsckFsbENiID0gZG9jdW1lbnQu
Z2V0RWxlbWVudEJ5SWQoJ2Nsci1hbGwnKTsNCiAgICBmdW5jdGlvbiBvcGVuQ2xlYXJEbGcoKSB7
DQogICAgICAgIGNvbnN0IG5hbWUgPSBUQUJfTkFNRVNbY3VyVGFiXSB8fCAn5b2T5YmNJzsNCiAg
ICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2Nsci10aXRsZScpLnRleHRDb250ZW50ID0g
J+a4heepuuOAjCcgKyBuYW1lICsgJ+OAje+8nyc7DQogICAgICAgIGRvY3VtZW50LmdldEVsZW1l
bnRCeUlkKCdjbHItZGVzYycpLnRleHRDb250ZW50ID0gY3VyVGFiID09PSAncGlubmVkJw0KICAg
ICAgICAgICAgPyAn6buY6K6k5LuF5riF56m65b2T5aSp55qE5pS26JeP6aG544CC5Yu+6YCJ44CM
5riF56m65omA5pyJ44CN5Y+v5riF6Zmk6K+l6YCJ6aG55Y2h5YWo6YOo5YaF5a6544CCJw0KICAg
ICAgICAgICAgOiAoY3VyVGFiID09PSAncmVjZW50Jw0KICAgICAgICAgICAgICAgID8gJ+a4heep
uuOAjOacgOi/keOAjeS8muWIoOmZpOacquWbuuWumueahOacgOi/keebruW9leiusOW9le+8m+W3
suWbuuWumueahOebruW9leS8muS/neeVmeOAgicNCiAgICAgICAgICAgICAgICA6ICfku4XmuIXn
qbrlvZPliY3pgInpobnljaHjgILpu5jorqTlj6rmuIXlvZPlpKnvvJvmlLbol4/pobnkuI3kvJro
oqvmuIXpmaTjgILli77pgInjgIzmuIXnqbrmiYDmnInjgI3lj6/muIXpmaTor6XpgInpobnljaHl
hajpg6jml6XmnJ/jgIInKTsNCiAgICAgICAgY2xyQWxsQ2IuY2hlY2tlZCA9IGZhbHNlOw0KICAg
ICAgICBjbHJEbGcuY2xhc3NMaXN0LmFkZCgnb24nKTsNCiAgICB9DQogICAgZnVuY3Rpb24gY2xv
c2VDbGVhckRsZygpIHsNCiAgICAgICAgY2xyRGxnLmNsYXNzTGlzdC5yZW1vdmUoJ29uJyk7DQog
ICAgfQ0KICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdidG4tY2xyJykuYWRkRXZlbnRMaXN0
ZW5lcignY2xpY2snLCBlID0+IHsNCiAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsNCiAgICAg
ICAgb3BlbkNsZWFyRGxnKCk7DQogICAgfSk7DQogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQo
J2Nsci1jYW5jZWwnKS5hZGRFdmVudExpc3RlbmVyKCdjbGljaycsIGUgPT4gew0KICAgICAgICBl
LnN0b3BQcm9wYWdhdGlvbigpOw0KICAgICAgICBjbG9zZUNsZWFyRGxnKCk7DQogICAgfSk7DQog
ICAgY2xyRGxnLmFkZEV2ZW50TGlzdGVuZXIoJ2NsaWNrJywgZSA9PiB7DQogICAgICAgIGlmIChl
LnRhcmdldCA9PT0gY2xyRGxnKSBjbG9zZUNsZWFyRGxnKCk7DQogICAgfSk7DQogICAgZG9jdW1l
bnQuZ2V0RWxlbWVudEJ5SWQoJ2Nsci1vaycpLmFkZEV2ZW50TGlzdGVuZXIoJ2NsaWNrJywgZSA9
PiB7DQogICAgICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7DQogICAgICAgIGNvbnN0IHNjb3BlID0g
KGN1clRhYiA9PT0gJ3JlY2VudCcpID8gJ2FsbCcgOiAoY2xyQWxsQ2IuY2hlY2tlZCA/ICdhbGwn
IDogJ3RvZGF5Jyk7DQogICAgICAgIGNsb3NlQ2xlYXJEbGcoKTsNCiAgICAgICAgYWhrKCdjbGVh
cicsIGN1clRhYiwgc2NvcGUpOw0KICAgIH0pOw0KICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlk
KCdtdWx0aS1zZWwnKS5hZGRFdmVudExpc3RlbmVyKCdjbGljaycsIGUgPT4gew0KICAgICAgICBl
LnN0b3BQcm9wYWdhdGlvbigpOw0KICAgICAgICBjbGVhck11bHRpKHRydWUpOw0KICAgIH0pOw0K
ICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdidG4tcGluJykuYWRkRXZlbnRMaXN0ZW5lcign
Y2xpY2snLCBlID0+IHsNCiAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsNCiAgICAgICAgcGlu
bmVkVUkgPSAhcGlubmVkVUk7DQogICAgICAgIGUuY3VycmVudFRhcmdldC5jbGFzc0xpc3QudG9n
Z2xlKCdvbicsIHBpbm5lZFVJKTsNCiAgICAgICAgYWhrKCd0b2dnbGVQaW4nLCBwaW5uZWRVSSA/
ICcxJyA6ICcwJyk7DQogICAgfSk7DQoNCiAgICB3aW5kb3cuX19wZXJmTWFyayA9IChzdGFnZSkg
PT4gew0KICAgICAgICB0cnkgew0KICAgICAgICAgICAgaWYgKHdpbmRvdy5jaHJvbWUgJiYgY2hy
b21lLndlYnZpZXcgJiYgY2hyb21lLndlYnZpZXcucG9zdE1lc3NhZ2UpDQogICAgICAgICAgICAg
ICAgY2hyb21lLndlYnZpZXcucG9zdE1lc3NhZ2UoJ3BlcmZ8JyArIFN0cmluZyhzdGFnZSB8fCAn
JykpOw0KICAgICAgICB9IGNhdGNoIHt9DQogICAgfTsNCg0KICAgIHdpbmRvdy5fX3VwZGF0ZUNs
aXBzID0gcGF5bG9hZCA9PiB7DQogICAgICAgIGNvbnN0IHQwID0gKHR5cGVvZiBwZXJmb3JtYW5j
ZSAhPT0gJ3VuZGVmaW5lZCcgJiYgcGVyZm9ybWFuY2Uubm93KSA/IHBlcmZvcm1hbmNlLm5vdygp
IDogRGF0ZS5ub3coKTsNCiAgICAgICAgd2luZG93Ll9fcGVyZk1hcmsoJ2pzX3VwZGF0ZUNsaXBz
X2VudGVyIG49JyArIChwYXlsb2FkICYmIHBheWxvYWQuaXRlbXMgPyBwYXlsb2FkLml0ZW1zLmxl
bmd0aCA6IChBcnJheS5pc0FycmF5KHBheWxvYWQpID8gcGF5bG9hZC5sZW5ndGggOiAwKSkpOw0K
ICAgICAgICAvLyBLZWVwIHByZXZpb3VzIHNjcm9sbCBmb3IgbG9hZC1tb3JlOyByZXNldCB3aGVu
IG9wZW5pbmcgcGFuZWwgdG8gZmlyc3QgaXRlbQ0KICAgICAgICBjb25zdCBrZWVwU2Nyb2xsID0g
IXNlbGVjdEZpcnN0T25TaG93Ow0KICAgICAgICBjb25zdCBzdCA9IGxpc3RFbC5zY3JvbGxUb3A7
DQogICAgICAgIHdpbmRvdy5fX3dhaXRpbmdWaWV3ID0gZmFsc2U7DQogICAgICAgIGNvbnN0IHdh
c0FwcGVuZCA9IHBheWxvYWQgJiYgcGF5bG9hZC5hcHBlbmQ7DQogICAgICAgIGxvYWRpbmdNb3Jl
ID0gZmFsc2U7DQogICAgICAgIGNvbnN0IHByZXZJdGVtcyA9IGFsbENsaXBzOw0KICAgICAgICBs
ZXQgbmV4dEl0ZW1zID0gW107DQogICAgICAgIGxldCBuZXh0VG90YWwgPSAwOw0KICAgICAgICBs
ZXQgbmV4dEZpbHRlcmVkID0gZmFsc2U7DQogICAgICAgIGxldCBwVGFiID0gJyc7DQogICAgICAg
IGxldCBwUGlubmVkVG90YWwgPSAtMTsNCiAgICAgICAgaWYgKEFycmF5LmlzQXJyYXkocGF5bG9h
ZCkpIHsNCiAgICAgICAgICAgIG5leHRJdGVtcyA9IHBheWxvYWQ7DQogICAgICAgICAgICBuZXh0
VG90YWwgPSBwYXlsb2FkLmxlbmd0aDsNCiAgICAgICAgICAgIG5leHRGaWx0ZXJlZCA9IGZhbHNl
Ow0KICAgICAgICB9IGVsc2UgaWYgKHBheWxvYWQgJiYgdHlwZW9mIHBheWxvYWQgPT09ICdvYmpl
Y3QnKSB7DQogICAgICAgICAgICBuZXh0VG90YWwgPSBOdW1iZXIocGF5bG9hZC50b3RhbCkgfHwg
MDsNCiAgICAgICAgICAgIG5leHRJdGVtcyA9IEFycmF5LmlzQXJyYXkocGF5bG9hZC5pdGVtcykg
PyBwYXlsb2FkLml0ZW1zIDogW107DQogICAgICAgICAgICBwVGFiID0gcGF5bG9hZC50YWIgIT0g
bnVsbCA/IFN0cmluZyhwYXlsb2FkLnRhYikgOiAnJzsNCiAgICAgICAgICAgIGlmIChwYXlsb2Fk
LnBpbm5lZFRvdGFsICE9IG51bGwgJiYgcGF5bG9hZC5waW5uZWRUb3RhbCAhPT0gJycpDQogICAg
ICAgICAgICAgICAgcFBpbm5lZFRvdGFsID0gTnVtYmVyKHBheWxvYWQucGlubmVkVG90YWwpIHx8
IDA7DQogICAgICAgICAgICBjb25zdCBwcTAgPSBwYXlsb2FkLnF1ZXJ5ICE9IG51bGwgPyBTdHJp
bmcocGF5bG9hZC5xdWVyeSkgOiAnJzsNCiAgICAgICAgICAgIG5leHRGaWx0ZXJlZCA9ICEhKHBh
eWxvYWQuZmlsdGVyZWQgfHwgKHBxMCAmJiBwcTAudHJpbSgpKSk7DQogICAgICAgICAgICBpZiAo
cGF5bG9hZC5hcHBlbmQpIHsNCiAgICAgICAgICAgICAgICAvLyBBcHBlbmQgb25seSBhcHBsaWVz
IHRvIHRoZSB0YWIgd2UncmUgY3VycmVudGx5IHZpZXdpbmcNCiAgICAgICAgICAgICAgICBpZiAo
cFRhYiAmJiBwVGFiICE9PSBjdXJUYWIpDQogICAgICAgICAgICAgICAgICAgIHJldHVybjsNCiAg
ICAgICAgICAgICAgICBjb25zdCBzZWVuID0gbmV3IFNldChhbGxDbGlwcy5tYXAoYyA9PiArYy5p
ZCkpOw0KICAgICAgICAgICAgICAgIGNvbnN0IG1lcmdlZCA9IGFsbENsaXBzLnNsaWNlKCk7DQog
ICAgICAgICAgICAgICAgbmV4dEl0ZW1zLmZvckVhY2goaXQgPT4gew0KICAgICAgICAgICAgICAg
ICAgICBpZiAoIXNlZW4uaGFzKCtpdC5pZCkpIG1lcmdlZC5wdXNoKGl0KTsNCiAgICAgICAgICAg
ICAgICB9KTsNCiAgICAgICAgICAgICAgICBuZXh0SXRlbXMgPSBtZXJnZWQ7DQogICAgICAgICAg
ICAgICAgbmV4dFRvdGFsID0gTWF0aC5tYXgobmV4dFRvdGFsLCBuZXh0SXRlbXMubGVuZ3RoKTsN
CiAgICAgICAgICAgIH0NCiAgICAgICAgICAgIC8vIOaQnOe0ouahhuS7peaJk+Wtl+mVnOWDj+S4
uuWHhu+8jOe7neS4jeiiq+a7nuWQjueahOejgeebmOe7k+aenOWGmeWbnuaXp+WFs+mUruWtlw0K
ICAgICAgICAgICAgdHJ5IHsNCiAgICAgICAgICAgICAgICBjb25zdCBzID0gZG9jdW1lbnQuZ2V0
RWxlbWVudEJ5SWQoJ3NlYXJjaCcpOw0KICAgICAgICAgICAgICAgIGlmIChzICYmIFN0cmluZyhz
LnZhbHVlIHx8ICcnKS5sZW5ndGgpDQogICAgICAgICAgICAgICAgICAgIHF1ZXJ5ID0gcy52YWx1
ZTsNCiAgICAgICAgICAgICAgICBlbHNlIGlmIChwcTAgIT09ICcnICYmICFTdHJpbmcocXVlcnkg
fHwgJycpLnRyaW0oKSkNCiAgICAgICAgICAgICAgICAgICAgcXVlcnkgPSBwcTA7DQogICAgICAg
ICAgICB9IGNhdGNoIHt9DQogICAgICAgIH0gZWxzZSB7DQogICAgICAgICAgICBuZXh0SXRlbXMg
PSBbXTsNCiAgICAgICAgICAgIG5leHRUb3RhbCA9IDA7DQogICAgICAgICAgICBuZXh0RmlsdGVy
ZWQgPSBmYWxzZTsNCiAgICAgICAgfQ0KDQogICAgICAgIGNvbnN0IGJveFEgPSBTdHJpbmcocXVl
cnkgfHwgJycpLnRyaW0oKTsNCiAgICAgICAgY29uc3QgcHVzaFEgPSAocGF5bG9hZCAmJiB0eXBl
b2YgcGF5bG9hZCA9PT0gJ29iamVjdCcgJiYgcGF5bG9hZC5xdWVyeSAhPSBudWxsKQ0KICAgICAg
ICAgICAgPyBTdHJpbmcocGF5bG9hZC5xdWVyeSkudHJpbSgpIDogJyc7DQoNCiAgICAgICAgLy8g
QWx3YXlzIHJlZnJlc2gg5pS26JePIGJhZGdlIGZyb20gaG9zdCB3aGVuIHByb3ZpZGVkDQogICAg
ICAgIGlmIChwUGlubmVkVG90YWwgPj0gMCkNCiAgICAgICAgICAgIHBpbm5lZFRvdGFsID0gcFBp
bm5lZFRvdGFsOw0KDQogICAgICAgIC8vIFN0YWxlIHNlYXJjaCBwdXNoIChlLmcuICJzcXVhcmUg
bG9naSIgbGFuZHMgYWZ0ZXIgdXNlciB0eXBlZCAic3F1YXJlIGxvZ2luIikg4oCUY2FjaGUgb25s
eQ0KICAgICAgICBpZiAoIXdhc0FwcGVuZCAmJiBuZXh0RmlsdGVyZWQgJiYgcHVzaFEgJiYgYm94
USAmJiBwdXNoUSAhPT0gYm94USkgew0KICAgICAgICAgICAgdmlld01lbS5zZXQodmlld01lbUtl
eShwVGFiIHx8IGN1clRhYiwgcHVzaFEsIHRvZGF5T25seSksIHsNCiAgICAgICAgICAgICAgICBp
dGVtczogbmV4dEl0ZW1zLnNsaWNlKCksDQogICAgICAgICAgICAgICAgdG90YWw6IG5leHRUb3Rh
bA0KICAgICAgICAgICAgfSk7DQogICAgICAgICAgICByZXR1cm47DQogICAgICAgIH0NCg0KICAg
ICAgICAvLyBTdGFsZSBwdXNoIGZvciBhbm90aGVyIHRhYjogb25seSByZWZyZXNoIHRoYXQgdGFi
J3Mgdmlld01lbSwgZG9uJ3QgaGlqYWNrIFVJDQogICAgICAgIGlmICghd2FzQXBwZW5kICYmIHBU
YWIgJiYgcFRhYiAhPT0gY3VyVGFiKSB7DQogICAgICAgICAgICBjb25zdCBtZW1RID0gKHBheWxv
YWQgJiYgdHlwZW9mIHBheWxvYWQgPT09ICdvYmplY3QnICYmIHBheWxvYWQucXVlcnkgIT0gbnVs
bCkNCiAgICAgICAgICAgICAgICA/IFN0cmluZyhwYXlsb2FkLnF1ZXJ5KSA6ICcnOw0KICAgICAg
ICAgICAgdmlld01lbS5zZXQodmlld01lbUtleShwVGFiLCBtZW1RLCB0b2RheU9ubHkpLCB7DQog
ICAgICAgICAgICAgICAgaXRlbXM6IG5leHRJdGVtcy5zbGljZSgpLA0KICAgICAgICAgICAgICAg
IHRvdGFsOiBuZXh0VG90YWwNCiAgICAgICAgICAgIH0pOw0KICAgICAgICAgICAgLy8gU3RpbGwg
dXBkYXRlIHBpbiBiYWRnZSBpZiBob3N0IHNlbnQgaXQNCiAgICAgICAgICAgIHRyeSB7IHVwZGF0
ZVBpbkRvdCgpOyB9IGNhdGNoIHt9DQogICAgICAgICAgICAvLyBRUSDmkJzntKLmm77lm7rlrprm
jqggYWxsIHRhYiDihpIg5b2T5YmNIHRhYiDkvJrkuIDnm7TpqqjmnrbvvJvooaXkuIDmrKEgcmVx
dWVzdFZpZXcNCiAgICAgICAgICAgIGlmICh3YWl0aW5nRGF0YSAmJiBwdXNoUSA9PT0gYm94USkg
ew0KICAgICAgICAgICAgICAgIHNldFRpbWVvdXQoKCkgPT4gew0KICAgICAgICAgICAgICAgICAg
ICBpZiAod2FpdGluZ0RhdGEgJiYgY3VyVGFiICE9PSBwVGFiKQ0KICAgICAgICAgICAgICAgICAg
ICAgICAgcmVxdWVzdFZpZXcoKTsNCiAgICAgICAgICAgICAgICB9LCA0MCk7DQogICAgICAgICAg
ICB9DQogICAgICAgICAgICByZXR1cm47DQogICAgICAgIH0NCg0KICAgICAgICAvLyBCb290c3Ry
YXAgcmFjZTogQUhLIHB1c2hlZCBlbXB0eSBiZWZvcmUgV2FybUFsbFZpZXdzIOKAlGtlZXAgc2tl
bGV0b24sIGlnbm9yZQ0KICAgICAgICBjb25zdCBxT24gPSBTdHJpbmcocXVlcnkgfHwgJycpLnRy
aW0oKS5sZW5ndGggPiAwOw0KICAgICAgICBpZiAoIXdhc0FwcGVuZCAmJiAhbmV4dEl0ZW1zLmxl
bmd0aCAmJiBuZXh0VG90YWwgPD0gMCAmJiAhcU9uICYmICFuZXh0RmlsdGVyZWQgJiYgIXNhd05v
bkVtcHR5KSB7DQogICAgICAgICAgICBpZiAoIXdpbmRvdy5fX2VtcHR5RmFsbGJhY2tUKSB7DQog
ICAgICAgICAgICAgICAgd2luZG93Ll9fZW1wdHlGYWxsYmFja1QgPSBzZXRUaW1lb3V0KCgpID0+
IHsNCiAgICAgICAgICAgICAgICAgICAgd2luZG93Ll9fZW1wdHlGYWxsYmFja1QgPSAwOw0KICAg
ICAgICAgICAgICAgICAgICBpZiAoc2F3Tm9uRW1wdHkpIHJldHVybjsNCiAgICAgICAgICAgICAg
ICAgICAgLy8gVHJ1bHkgZW1wdHkgaW5zdGFsbCBhZnRlciB3YWl0DQogICAgICAgICAgICAgICAg
ICAgIHNhd05vbkVtcHR5ID0gdHJ1ZTsNCiAgICAgICAgICAgICAgICAgICAgaG9zdFB1c2hlZE9u
Y2UgPSB0cnVlOw0KICAgICAgICAgICAgICAgICAgICB3aW5kb3cuX19kYXRhUmVhZHkgPSB0cnVl
Ow0KICAgICAgICAgICAgICAgICAgICBhbGxDbGlwcyA9IFtdOw0KICAgICAgICAgICAgICAgICAg
ICBkaXNrVG90YWwgPSAwOw0KICAgICAgICAgICAgICAgICAgICBjbGVhcldhaXRpbmdEYXRhKCk7
DQogICAgICAgICAgICAgICAgICAgIHRyeSB7IHJlbmRlcigpOyB9IGNhdGNoIHt9DQogICAgICAg
ICAgICAgICAgfSwgNDUwMCk7DQogICAgICAgICAgICB9DQogICAgICAgICAgICB3YWl0aW5nRGF0
YSA9IHRydWU7DQogICAgICAgICAgICB3aW5kb3cuX19kYXRhUmVhZHkgPSBmYWxzZTsNCiAgICAg
ICAgICAgIGhvc3RQdXNoZWRPbmNlID0gZmFsc2U7DQogICAgICAgICAgICBzZXRCb290TG9hZGlu
Zyh0cnVlKTsNCiAgICAgICAgICAgIHRyeSB7IHJlbmRlcigpOyB9IGNhdGNoIHt9DQogICAgICAg
ICAgICByZXR1cm47DQogICAgICAgIH0NCg0KICAgICAgICBjbGVhcldhaXRpbmdEYXRhKCk7DQog
ICAgICAgIGFsbENsaXBzID0gbmV4dEl0ZW1zOw0KICAgICAgICBkaXNrVG90YWwgPSBuZXh0VG90
YWw7DQogICAgICAgIC8vIEtlZXAgYmFyIGNvbnNpc3RlbnQgaWYgbGlzdCBncmV3IHBhc3QgYSBz
dGFsZSB0b3RhbA0KICAgICAgICBpZiAoYWxsQ2xpcHMubGVuZ3RoID4gZGlza1RvdGFsKQ0KICAg
ICAgICAgICAgZGlza1RvdGFsID0gYWxsQ2xpcHMubGVuZ3RoOw0KICAgICAgICB3aW5kb3cuX19o
b3N0RmlsdGVyZWQgPSBuZXh0RmlsdGVyZWQ7DQogICAgICAgIHdpbmRvdy5fX2hvc3RGaWx0ZXJR
ID0gKG5leHRGaWx0ZXJlZCAmJiBwdXNoUSkgPyBwdXNoUSA6ICcnOw0KICAgICAgICAvLyBGaWx0
ZXJlZCBzZWFyY2ggd2l0aCAwIGhpdHMg4oCUbXVzdCBsZWF2ZSBza2VsZXRvbiAoaG9zdCBkaWQg
cmVzcG9uZCkNCiAgICAgICAgaWYgKCF3YXNBcHBlbmQgJiYgbmV4dEZpbHRlcmVkICYmICFhbGxD
bGlwcy5sZW5ndGggJiYgZGlza1RvdGFsIDw9IDApIHsNCiAgICAgICAgICAgIGhvc3RQdXNoZWRP
bmNlID0gdHJ1ZTsNCiAgICAgICAgICAgIHNhd05vbkVtcHR5ID0gdHJ1ZTsNCiAgICAgICAgfQ0K
ICAgICAgICBpZiAoYWxsQ2xpcHMubGVuZ3RoIHx8IGRpc2tUb3RhbCA+IDApDQogICAgICAgICAg
ICBzYXdOb25FbXB0eSA9IHRydWU7DQogICAgICAgIGlmICh3aW5kb3cuX19lbXB0eUZhbGxiYWNr
VCkgew0KICAgICAgICAgICAgY2xlYXJUaW1lb3V0KHdpbmRvdy5fX2VtcHR5RmFsbGJhY2tUKTsN
CiAgICAgICAgICAgIHdpbmRvdy5fX2VtcHR5RmFsbGJhY2tUID0gMDsNCiAgICAgICAgfQ0KICAg
ICAgICBpZiAoIXdhc0FwcGVuZCkgew0KICAgICAgICAgICAgY29uc3QgbWVtUSA9IChwYXlsb2Fk
ICYmIHR5cGVvZiBwYXlsb2FkID09PSAnb2JqZWN0JyAmJiBwYXlsb2FkLnF1ZXJ5ICE9IG51bGwp
DQogICAgICAgICAgICAgICAgPyBTdHJpbmcocGF5bG9hZC5xdWVyeSkgOiBxdWVyeTsNCiAgICAg
ICAgICAgIHZpZXdNZW0uc2V0KHZpZXdNZW1LZXkoY3VyVGFiLCBtZW1RLCB0b2RheU9ubHkpLCB7
DQogICAgICAgICAgICAgICAgaXRlbXM6IGFsbENsaXBzLnNsaWNlKCksDQogICAgICAgICAgICAg
ICAgdG90YWw6IGRpc2tUb3RhbA0KICAgICAgICAgICAgfSk7DQogICAgICAgIH0NCiAgICAgICAg
d2luZG93Ll9fZGF0YVJlYWR5ID0gdHJ1ZTsNCiAgICAgICAgaG9zdFB1c2hlZE9uY2UgPSB0cnVl
Ow0KDQogICAgICAgIC8vIE1pZC13aGVlbDoga2VlcCBkYXRhLCBkZWxheSBET00gc28gc2Nyb2xs
L2RyYWcgbmV2ZXIgaGl0Y2ggb24gYXBwZW5kIHBhaW50DQogICAgICAgIGlmICh3YXNBcHBlbmQg
JiYgd2luZG93Ll9fc2Nyb2xsQnVzeSAmJiAhd2luZG93Ll9fcGVuZGluZ0p1bXBJZCkgew0KICAg
ICAgICAgICAgY29uc3QgZnJvbUxlbiA9IChwcmV2SXRlbXMgJiYgcHJldkl0ZW1zLmxlbmd0aCkg
PyBwcmV2SXRlbXMubGVuZ3RoIDogMDsNCiAgICAgICAgICAgIGlmICghX3BlbmRpbmdBcHBlbmQp
DQogICAgICAgICAgICAgICAgX3BlbmRpbmdBcHBlbmQgPSB7IGZyb21MZW46IGZyb21MZW4gfTsN
CiAgICAgICAgICAgIHRyeSB7IHJlZnJlc2hMaXN0Q2hyb21lKCk7IH0gY2F0Y2gge30NCiAgICAg
ICAgICAgIHJldHVybjsNCiAgICAgICAgfQ0KDQogICAgICAgIGNvbnN0IHdhc0Jvb3RMb2FkaW5n
ID0gYm9vdExvYWRpbmc7DQogICAgICAgIGxldCBzYW1lUGFpbnQgPSBmYWxzZTsNCiAgICAgICAg
Y29uc3QgcHJldkxlbiA9IChwcmV2SXRlbXMgJiYgcHJldkl0ZW1zLmxlbmd0aCkgPyBwcmV2SXRl
bXMubGVuZ3RoIDogMDsNCiAgICAgICAgaWYgKCF3YXNBcHBlbmQgJiYgIXdhc0Jvb3RMb2FkaW5n
ICYmIHByZXZJdGVtcyAmJiBwcmV2SXRlbXMubGVuZ3RoID09PSBhbGxDbGlwcy5sZW5ndGggJiYg
cHJldkl0ZW1zLmxlbmd0aCkgew0KICAgICAgICAgICAgc2FtZVBhaW50ID0gdHJ1ZTsNCiAgICAg
ICAgICAgIGZvciAobGV0IGkgPSAwOyBpIDwgYWxsQ2xpcHMubGVuZ3RoOyBpKyspIHsNCiAgICAg
ICAgICAgICAgICBjb25zdCBhID0gcHJldkl0ZW1zW2ldLCBiID0gYWxsQ2xpcHNbaV07DQogICAg
ICAgICAgICAgICAgaWYgKCthLmlkICE9PSArYi5pZCkgeyBzYW1lUGFpbnQgPSBmYWxzZTsgYnJl
YWs7IH0NCiAgICAgICAgICAgICAgICAvLyBRdWV1ZSAvIHBhc3RlZCBjaHJvbWUgbGl2ZXMgaW4g
RE9NIGNsYXNzZXMg4oCUIG11c3QgcmUtcmVuZGVyIHdoZW4gbWV0YSBmbGlwcw0KICAgICAgICAg
ICAgICAgIGlmICgoTnVtYmVyKGEucXVldWVHcm91cCkgfHwgMCkgIT09IChOdW1iZXIoYi5xdWV1
ZUdyb3VwKSB8fCAwKQ0KICAgICAgICAgICAgICAgICAgICB8fCAoTnVtYmVyKGEucXVldWVJbmRl
eCkgfHwgMCkgIT09IChOdW1iZXIoYi5xdWV1ZUluZGV4KSB8fCAwKQ0KICAgICAgICAgICAgICAg
ICAgICB8fCAhIWEucGFzdGVkICE9PSAhIWIucGFzdGVkKSB7DQogICAgICAgICAgICAgICAgICAg
IHNhbWVQYWludCA9IGZhbHNlOw0KICAgICAgICAgICAgICAgICAgICBicmVhazsNCiAgICAgICAg
ICAgICAgICB9DQogICAgICAgICAgICB9DQogICAgICAgICAgICBpZiAoc2FtZVBhaW50ICYmICFs
aXN0RWwucXVlcnlTZWxlY3RvcignLml0bScpKSBzYW1lUGFpbnQgPSBmYWxzZTsNCiAgICAgICAg
fQ0KICAgICAgICBjb25zdCBmaW5pc2hVcGRhdGUgPSAoKSA9PiB7DQogICAgICAgICAgICBjb25z
dCB0UmVuZGVyMCA9ICh0eXBlb2YgcGVyZm9ybWFuY2UgIT09ICd1bmRlZmluZWQnICYmIHBlcmZv
cm1hbmNlLm5vdykgPyBwZXJmb3JtYW5jZS5ub3coKSA6IERhdGUubm93KCk7DQogICAgICAgICAg
ICBjbGVhcldhaXRpbmdEYXRhKCk7DQogICAgICAgICAgICBpZiAod2FzQXBwZW5kICYmICF3YXNC
b290TG9hZGluZyAmJiBwcmV2TGVuID4gMCAmJiBhbGxDbGlwcy5sZW5ndGggPiBwcmV2TGVuKSB7
DQogICAgICAgICAgICAgICAgYXBwZW5kUmVuZGVyKHByZXZMZW4pOw0KICAgICAgICAgICAgfSBl
bHNlIGlmICghc2FtZVBhaW50KSB7DQogICAgICAgICAgICAgICAgcmVuZGVyKCk7DQogICAgICAg
ICAgICAgICAgYXBwbHlUYWJTd2l0Y2hBbmltKCk7DQogICAgICAgICAgICAgICAgaWYgKGtlZXBT
Y3JvbGwpDQogICAgICAgICAgICAgICAgICAgIGxpc3RFbC5zY3JvbGxUb3AgPSBzdDsNCiAgICAg
ICAgICAgICAgICBlbHNlDQogICAgICAgICAgICAgICAgICAgIGxpc3RFbC5zY3JvbGxUb3AgPSAw
Ow0KICAgICAgICAgICAgfSBlbHNlIHsNCiAgICAgICAgICAgICAgICB0cnkgeyByZWZyZXNoTGlz
dENocm9tZSgpOyB9IGNhdGNoIHt9DQogICAgICAgICAgICAgICAgaWYgKGtlZXBTY3JvbGwpDQog
ICAgICAgICAgICAgICAgICAgIGxpc3RFbC5zY3JvbGxUb3AgPSBzdDsNCiAgICAgICAgICAgIH0N
CiAgICAgICAgICAgIGNvbnN0IHQxID0gKHR5cGVvZiBwZXJmb3JtYW5jZSAhPT0gJ3VuZGVmaW5l
ZCcgJiYgcGVyZm9ybWFuY2Uubm93KSA/IHBlcmZvcm1hbmNlLm5vdygpIDogRGF0ZS5ub3coKTsN
CiAgICAgICAgICAgIHdpbmRvdy5fX3BlcmZNYXJrKCdqc191cGRhdGVDbGlwc19kb25lIHJlbmRl
ck1zPScgKyBNYXRoLnJvdW5kKHQxIC0gdFJlbmRlcjApICsgJyB0b3RhbE1zPScgKyBNYXRoLnJv
dW5kKHQxIC0gdDApICsgJyBuPScgKyBhbGxDbGlwcy5sZW5ndGgpOw0KICAgICAgICB9Ow0KICAg
ICAgICBpZiAod2FzQm9vdExvYWRpbmcpIHsNCiAgICAgICAgICAgIGNvbnN0IHNpbmNlID0gd2lu
ZG93Ll9fc2tlbFNpbmNlIHx8IDA7DQogICAgICAgICAgICBjb25zdCB3YWl0ID0gc2luY2UgPyBN
YXRoLm1heCgwLCA4MCAtIChEYXRlLm5vdygpIC0gc2luY2UpKSA6IDA7DQogICAgICAgICAgICBp
ZiAod2FpdCA+IDApDQogICAgICAgICAgICAgICAgc2V0VGltZW91dChmaW5pc2hVcGRhdGUsIHdh
aXQpOw0KICAgICAgICAgICAgZWxzZQ0KICAgICAgICAgICAgICAgIGZpbmlzaFVwZGF0ZSgpOw0K
ICAgICAgICB9IGVsc2Ugew0KICAgICAgICAgICAgZmluaXNoVXBkYXRlKCk7DQogICAgICAgIH0N
CiAgICB9Ow0KICAgIHdpbmRvdy5fX3NldFBpbm5lZCA9IHYgPT4gew0KICAgICAgICBwaW5uZWRV
SSA9ICEhdjsNCiAgICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2J0bi1waW4nKS5jbGFz
c0xpc3QudG9nZ2xlKCdvbicsIHBpbm5lZFVJKTsNCiAgICB9Ow0KICAgIHdpbmRvdy5fX2xvYWRN
b3JlRG9uZSA9ICgpID0+IHsNCiAgICAgICAgbG9hZGluZ01vcmUgPSBmYWxzZTsNCiAgICAgICAg
aWYgKHdpbmRvdy5fX2xvYWRNb3JlV2F0Y2gpIHsNCiAgICAgICAgICAgIGNsZWFyVGltZW91dCh3
aW5kb3cuX19sb2FkTW9yZVdhdGNoKTsNCiAgICAgICAgICAgIHdpbmRvdy5fX2xvYWRNb3JlV2F0
Y2ggPSAwOw0KICAgICAgICB9DQogICAgICAgIGlmICh3aW5kb3cuX19wZW5kaW5nSnVtcElkKQ0K
ICAgICAgICAgICAgdHJ5Q29udGludWVKdW1wKCk7DQogICAgfTsNCg0KICAgIGluaXRTZXBVaSgp
Ow0KICAgIHVwZGF0ZVBpbkRvdCgpOw0KICAgIHNjaGVkdWxlRGVsYXllZFNrZWwoKTsNCiAgICB3
aW5kb3cuX19wZXJmTWFyayAmJiB3aW5kb3cuX19wZXJmTWFyaygnanNfYm9vdCByZXF1ZXN0Vmll
dycpOw0KICAgIHJlcXVlc3RWaWV3KCk7DQogICAgLy8gc2NoZWR1bGVEZWxheWVkU2tlbCBhbHJl
YWR5IHJlbmRlcigpJ2Qgd2hlbiBlbXB0eTsgc3RpbGwgcGFpbnQgb25jZSBmb3IgY2hyb21lCgog
ICAgPC9zY3JpcHQ+DQo8L2JvZHk+DQo8L2h0bWw+
)"

global clips   := []
global clipUidSeq := 0
global lastAppendCount := 0
global viewTab := "all"
global viewQuery := ""
global viewToday := false
global viewTotal := 0
global viewCache := Map()
global searchPools := Map()   ; only all + pinned pools (tab+today -> { items, groups })
global diskJobQueue := []
global diskJobBusy := false
global guiWin  := ""
global wv      := ""
global wvCore  := ""
global lastTxt := ""
global lastImg := ""
global lastImageFileClipAt := 0     ; Explorer 右键复制图片文件：HDROP 与位图连发时只留一条
global lastClipImageAt := 0         ; 最近一次 type=image 写入历史
global lastFileClipKey := ""        ; 同一次复制连发 ClipChanged 时去重（微信等）
global lastFileClipAt := 0
global clipChangePendingType := 0   ; 剪贴板变更防抖：合并连发事件
global clipChangeBusy := false       ; 禁止 ClipChangedSafe 重入
global uiPinned := false
global prevActiveWin := 0
global clipIgnore := false
global clipReady := false          ; false until InitClipsFromDisk + settle (boot copy = crash)
global diskScanBusy := false
global firstAllPaintDone := false  ; true after first 20 of all tab ready
global firstOpenT0 := 0            ; PERF timeline anchor (ShowPanel first open)
global uiNavReady := false         ; true after full index.html NavigationCompleted
global viewSwitchGuardUntil := 0  ; 切 tab 扫盘期间忽略外侧点击，避免卡完面板被藏掉
global viewApplyGen := 0          ; SetView 代数：Sleep 让出后丢弃过期结果
global viewApplying := false      ; 扫盘中禁止把「旧 clips + 新 query」推给 UI
global pasteLockUntil := 0
global pasteSending := false
global pasteQueueMode := false          ; Ctrl+Shift+C queue paste mode
global pasteQueueIds := []              ; FIFO uid list
global pasteQueueGroupId := 0           ; visual group id for UI connector lines
global pasteQueueDone := 0              ; how many FIFO pastes in this session
global queueCaptureArmed := false       ; next AddClipItem joins the queue
global queueSuppressExit := false       ; ignore ~^c exit while we Send ^c for queue copy
global queueFifoPasteding := false      ; ignore re-entry during FIFO paste
global queueFifoPasteAt := 0            ; tick of last FIFO paste start
global queueCopyGen := 0                ; generation for arm timeout
global lastKeyboardCopyAt := 0          ; tick of last real Ctrl+C / Ctrl+X (not Ctrl+click)
global ctrlMouseCopyUntil := 0          ; Ctrl+LButton 开窗：剪贴板异步到达时 Ctrl 可能已松开
global queueTipGui := 0
global queueTipSeq := 0
global queueMetaMap := Map()            ; uid -> {g, i} persisted for UI after restart
global lastCaretX := 0
global lastCaretY := 0
global hasCaretPos := false
global panelVisible := false
global searchFocused := false
global qqSearchOn := false
global qqQuery := ""
global qqIh := 0
global qqPending := false
global qqNeedRelease := false
global qqPanelPlaced := false
global qqMarkCount := 0
global qqAwaitKeyword := false
global qqEmojiMode := false          ; ??? / ？？？ 表情搜索（拼音），?? 仍是剪贴板历史
global emojiIndex := []
global emojiIndexReady := false
global emojiIndexStamp := ""
global pyMap := Map()
global pyMapReady := false
global emojiHitCache := []
global emojiHitQuery := ""
global linkMetaQueue := []
global linkMetaPausedUntil := 0
global wvBuilding := false
global uiPushPending := false
global uiPushTimerArmed := false
global liveFront := []   ; recently copied items not yet confirmed on disk (survive SetView)
global recentFolders := []  ; Explorer folders (type=recent), newest first
global recentFolderUidSeq := 800000000
global lastExplorerFolder := ""
global pendingViewTab := "all"
global pendingViewQuery := ""
global pendingViewToday := "0"
global pendingViewArmed := false
; List-thumb inject: chunked + cancellable so tab switches stay responsive
global listThumbUrlCache := Map()   ; imgFile -> { mt, url }
global thumbPushGen := 0
global thumbPushQueue := []
global thumbPushArmed := false
global thumbPushedUids := Map()     ; uid already injected this session
global tabTotals := Map()           ; ViewCacheKey -> known total (skip full rescan)
global pruneScreenshotsArmed := false
global pruneScreenshotsPending := false

; 挂在快捷键4下：保持无托盘。独立运行时已在顶部 ClipSetupStandaloneTray 显示托盘。
if !clipboardStandalone {
TraySetIcon("shell32.dll", 261)
A_TrayMenu.Delete()
A_TrayMenu.Add("显示剪贴板", (*) => ShowPanel())
A_TrayMenu.Add("清空历史",   (*) => ClearAll())
A_TrayMenu.Add()
A_TrayMenu.Add("退出",       (*) => ExitApp())
A_TrayMenu.Default := "显示剪贴板"
A_IconTip := "ClipboardManager  (Win+V)"
}

; Hotkeys are registered at the end of auto-execute (after EnsureDataDir / BuildGui)
; so a failed early init cannot leave the script without any show shortcut.

; Do NOT hook ~^v to PastePngToDir here:
; Explorer/Desktop already creates a file on Ctrl+V, and 快捷键4 pastpng2dir also saves —
; a third/second save here made desktop Ctrl+V produce duplicate images.
;
; OnClipboardChange is registered AFTER InitClipsFromDisk (EnableClipboardWatch).
; Early register raced boot init →freeze/exit + history wipe on copy-right-after-start.

; =================================================
;  Panel hotkeys: while panel is open, keys go to clipboard
;  even if the editor still has focus (NoActivate popup)
; =================================================
; Always-on while panel visible (search / pin / unfocused all OK):
;   Ctrl+I/K = move selection, Ctrl+J/L = switch tabs, Ctrl+F = open search
#HotIf ClipPanelIsUp()
$^i::PanelKeyUp("")
$^k::PanelKeyDown("")
$^j::PanelKeyPrevTab("")
$^l::PanelKeyNextTab("")
$^f::PanelOpenSearch("")
F2::PanelKeyEditTitle("")
#HotIf

; ?? / ??? 搜索中：Esc 取消；Enter 粘贴（必须拦掉，否则落到 Slack 等会当成发消息）
#HotIf qqSearchOn
Esc::EscHidePanel("")
Enter::PanelKeyEnter("")
#HotIf

; Unpinned: arrows / Enter / Esc hide
#HotIf ClipPanelIsUp() && !uiPinned && !qqSearchOn
Up::PanelKeyUp("")
Down::PanelKeyDown("")
Enter::PanelKeyEnter("")
Esc::EscHidePanel("")
~LButton::OnOutsideClick("")
~LAlt::EscHidePanel("")
~RAlt::EscHidePanel("")
#HotIf

; 搜索中面板已弹出：方向键仍可用（Enter 已在 qqSearchOn 分支）
#HotIf ClipPanelIsUp() && !uiPinned && qqSearchOn
Up::PanelKeyUp("")
Down::PanelKeyDown("")
~LButton::OnOutsideClick("")
#HotIf

; Pinned: arrows still navigate；回车不粘贴（点条目才粘贴）
#HotIf ClipPanelIsUp() && uiPinned
Up::PanelKeyUp("")
Down::PanelKeyDown("")
#HotIf

ClipPanelIsUp(*) {
    global panelVisible, guiWin
    ; #HotIf 求值时勿读未赋值全局（AHK: This variable has not been assigned a value）
    if IsSet(panelVisible) && panelVisible
        return true
    try {
        if IsSet(guiWin) && IsObject(guiWin) && guiWin.Hwnd && DllCall("IsWindowVisible", "Ptr", guiWin.Hwnd, "Int")
            return true
    }
    return false
}

; =================================================
;  Clipboard
; =================================================
ClipChanged(dataType) {
    global clipIgnore, clipReady, diskScanBusy, clipChangePendingType
    if clipIgnore || dataType = 0
        return
    ; Not ready yet (boot) —ignore; EnableClipboardWatch arms after InitClipsFromDisk
    if !clipReady {
        ClipLog("ClipChanged SKIP not-ready type=" dataType)
        return
    }
    ; Preload / heavy scan in progress —retry shortly (do not race disk)
    if diskScanBusy {
        ClipLog("ClipChanged DEFER diskScanBusy type=" dataType)
        dt := Integer(dataType)
        SetTimer(() => ClipChanged(dt), -500)
        return
    }
    ; 微信/Explorer 一次复制会连发多次 OnClipboardChange —防抖后只处理一次
    clipChangePendingType := Integer(dataType)
    SetTimer(ProcessClipChangedDebounced, 0)
    SetTimer(ProcessClipChangedDebounced, -120)
}

ProcessClipChangedDebounced(*) {
    global clipChangePendingType, clipIgnore, clipReady, diskScanBusy
    if clipIgnore || !clipReady
        return
    if diskScanBusy {
        SetTimer(ProcessClipChangedDebounced, -500)
        return
    }
    dt := clipChangePendingType
    ClipLog("ClipChanged debounced ENTER type=" dt)
    try ClipChangedSafe(dt)
    catch as e {
        ClipLogErr("ClipChanged", e)
    }
    ClipLog("ClipChanged debounced EXIT type=" dt)
}

ClipChangedSafe(dataType) {
    global lastTxt, lastImg, clipIgnore, clipChangeBusy
    if clipIgnore
        return
    if clipChangeBusy {
        ClipLog("ClipChangedSafe SKIP reentrant type=" dataType)
        return
    }
    clipChangeBusy := true
    try {
        ClipChangedSafeCore(dataType)
    } finally {
        clipChangeBusy := false
    }
}

ClipChangedSafeCore(dataType) {
    global lastTxt, lastImg, clipIgnore, queueCaptureArmed
    if clipIgnore
        return
    ; Brief settle so clipboard formats are ready (too long blocked UI updates)
    Sleep 30

    hasFiles := DllCall("IsClipboardFormatAvailable", "UInt", 15, "Int")
    hasBmp   := DllCall("IsClipboardFormatAvailable", "UInt", 2, "Int")
    hasDib   := DllCall("IsClipboardFormatAvailable", "UInt", 8, "Int")
    hasDib5  := DllCall("IsClipboardFormatAvailable", "UInt", 17, "Int")
    hasImg   := hasBmp || hasDib || hasDib5 || (dataType = 2)
    ; Explorer 右键复制图片：CF_HDROP + 位图同时存在 → 只走 file 分支
    if hasFiles && hasImg && ClipboardHasOnlyImageFiles()
        hasImg := false
    ClipLog("ClipChanged formats files=" hasFiles " img=" hasImg " bmp=" hasBmp " dib=" hasDib " type=" dataType)

    item := { time: FormatTime(, "yyyy-MM-dd HH:mm:ss"), pinned: false, pasted: false }

    ; File drops first —skip ClipboardAll (can be huge / exotic shell formats →freeze)
    if hasFiles {
        ClipLog("ClipChanged branch=file getList")
        names := GetClipboardFileList()
        ClipLog("ClipChanged fileList n=" names.Length)
        if names.Length = 0 {
            raw := A_Clipboard
            if raw = "" {
                Sleep 60
                raw := A_Clipboard
            }
            if raw = ""
                return
            names := []
            for ln in StrSplit(raw, "`n", "`r") {
                ln := Trim(ln)
                if ln != ""
                    names.Push(ln)
            }
            ClipLog("ClipChanged fileList from text n=" names.Length)
        }
        if names.Length = 0
            return
        raw := ""
        for i, ln in names
            raw .= (i > 1 ? "`n" : "") ln
        item.type := "file"
        item.data := raw
        item.preview := raw
        item.fileCount := names.Length
        item.charCount := 0
        ClipLog("ClipChanged file path0=" SubStr(names[1], 1, 120))
        global lastFileClipKey, lastFileClipAt, lastImageFileClipAt
        fkey := FileClipKey(raw)
        if fkey != "" && fkey = lastFileClipKey && (A_TickCount - lastFileClipAt) < 1500 {
            ClipLog("ClipChanged skip duplicate file burst")
            return
        }
        ; 右键复制图片文件：位图可能先到，此处去掉重复的 image 条
        if ClipboardPathsAllImage(names) {
            MemoryDropBurstFrontImage()
            lastImageFileClipAt := A_TickCount
        }
        lastFileClipKey := fkey
        lastFileClipAt := A_TickCount
        ApplyClipSrc(item)
        AddClipItem(item)
        return
    }

    ; Only keep ClipboardAll for non-file clips (paste fidelity); size-capped
    ClipLog("ClipChanged ClipboardAll begin")
    try {
        ca := ClipboardAll()
        if IsObject(ca) && ca.Size > 0 && ca.Size < 12 * 1024 * 1024 {
            item.clipAll := ca
            ClipLog("ClipChanged ClipboardAll size=" ca.Size)
        } else
            ClipLog("ClipChanged ClipboardAll skip size=" (IsObject(ca) ? ca.Size : 0))
    } catch as e {
        ClipLogErr("ClipboardAll", e)
    }

    if hasImg {
        ; 第二次 OnClipboardChange：剪贴板仍带图片路径时不再记位图
        if ClipboardHasOnlyImageFiles()
            return
        global lastImageFileClipAt
        if lastImageFileClipAt && (A_TickCount - lastImageFileClipAt) < 900 {
            ClipLog("ClipChanged skip image — recent image-file clip")
            return
        }
        ClipLog("ClipChanged branch=image ClipImageToBase64")
        img := ClipImageToBase64(&w, &h)
        ClipLog("ClipChanged image b64Len=" StrLen(img) " w=" w " h=" h)
        if img != "" {
            if img = lastImg && !queueCaptureArmed && !ClipContentAlreadyInPasteQueue({ type: "image", data: img })
                return
            lastImg := img
            item.type := "image"
            item.data := img
            item.preview := ""
            item.charCount := 0
            item.width := w
            item.height := h
            ApplyClipSrc(item)
            AddClipItem(item)
            return
        }
        if dataType = 2
            return
    }

    if dataType = 1 {
        global queueCaptureArmed, pasteQueueMode, pasteQueueIds, pasteQueueGroupId, pasteQueueDone
        global lastKeyboardCopyAt, ctrlMouseCopyUntil
        ClipLog("ClipChanged branch=text")
        txt := A_Clipboard
        if txt = "" {
            Sleep 60
            txt := A_Clipboard
        }
        ; Ctrl+鼠标点击复制：以「按下时」开窗，不要求剪贴板到达时仍按着 Ctrl
        ; （网页 clipboard.writeText 异步，松 Ctrl 后才写入 → 旧逻辑会漏入队）
        ; 普通 Ctrl+C：~^c 打 lastKeyboardCopyAt，这里跳过
        if !queueCaptureArmed
            && (A_TickCount <= ctrlMouseCopyUntil)
            && (A_TickCount - lastKeyboardCopyAt) > 480
            && !GetKeyState("C", "P") && !GetKeyState("X", "P") {
            PrunePasteQueueIds()
            if !pasteQueueMode || !pasteQueueIds.Length {
                pasteQueueMode := true
                pasteQueueIds := []
                pasteQueueDone := 0
                pasteQueueGroupId += 1
                ClipLog("PasteQueue Ctrl-click new session group=" pasteQueueGroupId)
            }
            queueCaptureArmed := true
            ctrlMouseCopyUntil := 0  ; one shot per click
            ClipLog("PasteQueue Ctrl-click armed n=" pasteQueueIds.Length)
        }
        ; Queue capture / 已在队列：即使 lastTxt 相同也要新条目，否则 MemoryTake 会撕裂 FIFO
        if txt = ""
            return
        if txt = lastTxt && !queueCaptureArmed && !ClipContentAlreadyInPasteQueue({ type: "text", data: txt })
            return
        lastTxt := txt
        item.type := "text"
        item.data := txt
        item.preview := SubStr(txt, 1, 500)
        item.charCount := StrLen(txt)
        item.isMd := TextLooksLikeMarkdown(txt)
        item.isRich := ClipboardHasRichText()
        ApplyClipSrc(item)
        AddClipItem(item)
        AddLinksFromText(txt)
    }
}

; 剪贴板是否带 RTF / 带格式的 HTML（富文本）
ClipboardHasRichText(*) {
    static fmtRtf := 0, fmtHtml := 0
    if !fmtRtf
        try fmtRtf := DllCall("RegisterClipboardFormat", "Str", "Rich Text Format", "UInt")
    if !fmtHtml
        try fmtHtml := DllCall("RegisterClipboardFormat", "Str", "HTML Format", "UInt")
    if fmtRtf && DllCall("IsClipboardFormatAvailable", "UInt", fmtRtf, "Int")
        return true
    if !fmtHtml || !DllCall("IsClipboardFormatAvailable", "UInt", fmtHtml, "Int")
        return false
    ; 浏览器常给纯文本也挂 HTML：只有带明显格式才算富文本
    html := ClipboardGetHtmlSnippet(2400)
    if html = ""
        return true  ; 有 HTML 格式但读不到时仍视为富文本
    if RegExMatch(html, "i)</?(b|i|u|em|strong|h[1-6]|ul|ol|li|table|tr|td|th|img)\b")
        return true
    if RegExMatch(html, "i)\b(font-weight|font-style|text-decoration|background-color)\s*:")
        return true
    return false
}

ClipboardGetHtmlSnippet(maxLen := 2400) {
    static fmtHtml := 0
    if !fmtHtml
        try fmtHtml := DllCall("RegisterClipboardFormat", "Str", "HTML Format", "UInt")
    if !fmtHtml
        return ""
    if !DllCall("OpenClipboard", "Ptr", 0)
        return ""
    html := ""
    try {
        h := DllCall("GetClipboardData", "UInt", fmtHtml, "Ptr")
        if h {
            p := DllCall("GlobalLock", "Ptr", h, "Ptr")
            if p {
                ; HTML Format 多为 UTF-8 / ANSI 混合；按字节读一段即可做格式嗅探
                buf := Buffer(maxLen + 1, 0)
                DllCall("RtlMoveMemory", "Ptr", buf, "Ptr", p, "UPtr", maxLen)
                DllCall("GlobalUnlock", "Ptr", h)
                html := StrGet(buf, "UTF-8")
                if html = ""
                    html := StrGet(buf, "CP0")
            }
        }
    } finally {
        DllCall("CloseClipboard")
    }
    return html
}

; Markdown 启发式（与前端 isMarkdown 对齐）
TextLooksLikeMarkdown(txt) {
    s := String(txt)
    if StrLen(s) < 4
        return false
    ; AHK 里 ` 是转义符，代码围栏用 Chr(96) 拼出 ```
    fence := Chr(96) Chr(96) Chr(96)
    if InStr(s, fence)
        return true
    if RegExMatch(s, "m)^#{1,6} ")
        return true
    if RegExMatch(s, "m)^[-*+] ")
        return true
    if RegExMatch(s, "m)^> ")
        return true
    if RegExMatch(s, "\*\*[^*\r\n]+\*\*")
        return true
    if RegExMatch(s, "__[^_\r\n]+__")
        return true
    if RegExMatch(s, "\[[^\]]+\]\([^)]+\)")
        return true
    if RegExMatch(s, "\|.+\|.+\|")
        return true
    return false
}

AddClipItem(item) {
    global clips, wvCore, STORE_DIR, lastTxt, lastClipImageAt, pasteQueueMode, pasteQueueIds, queueCaptureArmed
    ClipLog("AddClipItem begin type=" item.type)
    if !item.HasProp("uid") || !item.uid
        item.uid := NextClipUid()
    ClipLog("AddClipItem uid=" item.uid)
    ; Keep clipboard path light: do NOT write image/payload files here.
    ; Disk persist is async; UI must refresh from memory immediately.
    if item.type = "file" {
        ; NEVER FileCopy/GDI+ here —thumbs are lazy via EnsureFileClipThumb (async)
        ClipLog("AddClipItem file skip eager thumb (async EnsureFileClipThumb)")
    }
    ; 已在最近粘贴队列：必须新 uid 新条目，禁止 MemoryTake/跳过。
    ; 否则会把队列中间项抽到最前，撕裂 FIFO 连线。
    keepQueueDup := queueCaptureArmed || ClipContentAlreadyInPasteQueue(item)
    if keepQueueDup {
        ClipLog("AddClipItem keep duplicate for queue type=" item.type " armed=" queueCaptureArmed)
    }
    ; Memory-first: update UI caches immediately, persist disk async
    ; Re-copy must inherit 收藏/标题 — otherwise DiskRemove*Equal deletes the pinned row
    ; and inserts a fresh unpinned clone (favorites appear "lost").
    ; EXCEPTION: queue capture / 队列内重复 → DISTINCT uid，不要 Inherit。
    if item.type = "text" {
        if !keepQueueDup {
            old := MemoryTakeTextEqual(item.data)
            InheritClipMeta(item, old)
        }
        lastTxt := item.data
    } else if item.type = "link" {
        if !keepQueueDup {
            old := MemoryTakeLinkEqual(item.data)
            InheritClipMeta(item, old)
            if IsObject(old) && old.HasProp("linkTitle") && old.linkTitle != ""
                item.linkTitle := old.linkTitle
        }
    } else if item.type = "file" {
        if !keepQueueDup {
            old := MemoryTakeFileEqual(item.data)
            InheritClipMeta(item, old)
            if IsObject(old) && old.HasProp("imgFile") && old.imgFile != "" && !(item.HasProp("imgFile") && item.imgFile != "")
                item.imgFile := old.imgFile
        }
        if FileClipLooksLikeImage(item) && !(item.HasProp("imgFile") && item.imgFile != "")
            SetTimer(EnsureFileClipThumbAndInject.Bind(item), -30)
    }
    if item.type = "image"
        lastClipImageAt := A_TickCount
    ClipLog("AddClipItem MemoryInsertFront")
    MemoryInsertFront(item)
    ; Queue: Ctrl+Shift+C 入队；其它来源的剪贴板新增 → 结束队列
    global pasteQueueMode, queueCaptureArmed
    wasQueueArmed := queueCaptureArmed
    try EnqueuePasteQueueItem(item)
    if pasteQueueMode && !wasQueueArmed
        ExitPasteQueue("foreign-clip")
    ; Never call WebView sync from OnClipboardChange —it often drops the update.
    ; Defer a coalesced UI push so the open panel shows the new item immediately.
    RequestUiPush()
    ; Image payload is stripped from list JSON —inject a list thumb ASAP so UI is not blank
    if item.type = "image" && item.HasProp("data") && item.data != ""
        SetTimer(InjectLiveImageThumb.Bind(Integer(item.uid)), -15)
    ; Queue items already PrependDiskJob'd Persist — skip duplicate enqueue
    if (item.HasProp("_queuePersistQueued") && item._queuePersistQueued)
        || (item.HasProp("_queueSyncPersisted") && item._queueSyncPersisted) {
        ClipLog("AddClipItem skip async Persist (queue queued) uid=" item.uid)
    } else {
        ClipLog("AddClipItem Enqueue PersistNewItem")
        EnqueueDiskJob(PersistNewItem.Bind(item))
    }
    ClipLog("AddClipItem done uid=" item.uid)
}

AddLinksFromText(text) {
    urls := ExtractUrls(text)
    if urls.Length = 0
        return
    for url in urls
        AddLinkItem(url, false)
    RequestUiPush()
}

AddLinkItem(url, doPush := true) {
    global clips, viewTab, viewQuery, viewToday, viewTotal, wvCore
    url := Trim(url)
    if url = ""
        return false
    item := {
        uid: NextClipUid(),
        type: "link",
        data: url,
        time: FormatTime(, "yyyy-MM-dd HH:mm:ss"),
        pinned: false,
        pasted: false,
        preview: url,
        linkTitle: "",
        linkHost: HostOfUrl(url),
        charCount: 0,
        fileCount: 0,
        width: 0,
        height: 0,
        imgFile: ""
    }
    ApplyClipSrc(item)
    old := MemoryTakeLinkEqual(url)
    InheritClipMeta(item, old)
    if IsObject(old) && old.HasProp("linkTitle") && old.linkTitle != ""
        item.linkTitle := old.linkTitle
    MemoryInsertFront(item)
    if doPush
        RequestUiPush()
    EnqueueDiskJob(PersistNewItem.Bind(item))
    return true
}

ExtractUrls(text) {
    urls := []
    seen := Map()
    pos := 1
    while foundPos := RegExMatch(text, "i)https?://\S+", &m, pos) {
        url := RegExReplace(m[0], "[.,;:!?\)\]}>]+$", "")
        url := Trim(url)
        if url != "" {
            key := StrLower(url)
            if !seen.Has(key) {
                seen[key] := true
                urls.Push(url)
            }
        }
        pos := foundPos + StrLen(m[0])
    }
    return urls
}

HostOfUrl(url) {
    if RegExMatch(url, "i)^https?://([^/:#?]+)", &m)
        return m[1]
    return ""
}

EnqueueLinkMeta(url) {
    global linkMetaQueue, clips
    for c in clips {
        if c.type = "link" && c.data = url {
            if c.HasProp("linkTitle") && c.linkTitle != ""
                return
            break
        }
    }
    for u in linkMetaQueue {
        if u = url
            return
    }
    linkMetaQueue.Push(url)
    SetTimer(ProcessLinkMetaQueue, -500)
}

; Only when user opens 链接 tab  — never during Win+V open
PrimeLinkMeta(idsStr := "") {
    global clips
    want := Map()
    if idsStr != "" {
        for part in StrSplit(String(idsStr), ",") {
            part := Trim(part)
            if part = ""
                continue
            want[Integer(part)] := true
        }
    }
    n := 0
    for c in clips {
        if c.type != "link"
            continue
        if want.Count && !want.Has(c.uid)
            continue
        if c.HasProp("linkTitle") && c.linkTitle != ""
            continue
        EnqueueLinkMeta(c.data)
        if ++n >= 8
            break
    }
}

StopLinkMeta(*) {
    global linkMetaQueue, linkMetaPausedUntil
    linkMetaQueue := []
    linkMetaPausedUntil := A_TickCount + 3000
    SetTimer(ProcessLinkMetaQueue, 0)
    SetTimer(PushClips, 0)
}

ProcessLinkMetaQueue(*) {
    global linkMetaQueue
    if linkMetaQueue.Length = 0
        return
    url := linkMetaQueue.RemoveAt(1)
    fetchUrl := url
    SetTimer(() => _FetchLinkTitleWorker(fetchUrl), -20)
}

_FetchLinkTitleWorker(url) {
    global clips, linkMetaQueue, linkMetaPausedUntil
    ; Don't block Win+V / panel open with network I/O
    if A_TickCount < linkMetaPausedUntil {
        linkMetaQueue.InsertAt(1, url)
        SetTimer(ProcessLinkMetaQueue, Max(50, linkMetaPausedUntil - A_TickCount))
        return
    }
    title := ""
    try {
        http := ComObject("WinHttp.WinHttpRequest.5.1")
        http.Open("GET", url, false)
        http.SetTimeouts(300, 300, 600, 600)
        http.SetRequestHeader("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/120.0.0.0")
        http.Send()
        if Integer(http.Status) >= 200 && Integer(http.Status) < 400 {
            html := http.ResponseText
            if StrLen(html) > 65536
                html := SubStr(html, 1, 65536)
            if RegExMatch(html, "i)<title[^>]*>([\s\S]*?)</title>", &m) {
                title := Trim(m[1])
                title := RegExReplace(title, "\s+", " ")
                title := StrReplace(title, "&amp;", "&")
                title := StrReplace(title, "&lt;", "<")
                title := StrReplace(title, "&gt;", ">")
                title := StrReplace(title, "&quot;", '"')
                title := StrReplace(title, "&#39;", "'")
                if StrLen(title) > 120
                    title := SubStr(title, 1, 120)
            }
        }
    } catch {
    }
    if title != "" {
        updated := false
        for c in clips {
            if c.type = "link" && c.data = url {
                if !c.HasProp("linkTitle") || c.linkTitle != title {
                    c.linkTitle := title
                    updated := true
                }
                break
            }
        }
        if updated {
            DiskSetLinkTitle(url, title)
            SchedulePushClips()
        }
    }
    if linkMetaQueue.Length
        SetTimer(ProcessLinkMetaQueue, -800)
}

SchedulePushClips() {
    RequestUiPush()
}

ClipImageToBase64(&outW, &outH) {
    outW := 0, outH := 0
    pToken := 0, pBitmap := 0, hCopy := 0
    try {
        DllCall("LoadLibrary", "Str", "gdiplus.dll", "Ptr")
        si := Buffer(24, 0)
        NumPut("UInt", 1, si)
        if DllCall("gdiplus\GdiplusStartup", "Ptr*", &pToken, "Ptr", si, "Ptr", 0)
            return ""

        if !DllCall("OpenClipboard", "Ptr", 0)
            return ""

        hSrc := DllCall("GetClipboardData", "UInt", 2, "Ptr")
        if hSrc
            hCopy := DllCall("CopyImage", "Ptr", hSrc, "UInt", 0, "Int", 0, "Int", 0, "UInt", 0x2008, "Ptr")
        DllCall("CloseClipboard")

        if !hCopy
            return ""

        if DllCall("gdiplus\GdipCreateBitmapFromHBITMAP", "Ptr", hCopy, "Ptr", 0, "Ptr*", &pBitmap)
            return ""
        DllCall("DeleteObject", "Ptr", hCopy)
        hCopy := 0
        if !pBitmap
            return ""

        DllCall("gdiplus\GdipGetImageWidth",  "Ptr", pBitmap, "UInt*", &w := 0)
        DllCall("gdiplus\GdipGetImageHeight", "Ptr", pBitmap, "UInt*", &h := 0)
        outW := w, outH := h
        if w < 1 || h < 1
            return ""

        if (w > 1200 || h > 1200) {
            sc := Min(1200 / w, 1200 / h)
            nw := Round(w * sc), nh := Round(h * sc)
            pThumb := 0, pGfx := 0
            DllCall("gdiplus\GdipCreateBitmapFromScan0", "Int", nw, "Int", nh,
                "Int", 0, "Int", 0x26200A, "Ptr", 0, "Ptr*", &pThumb)
            if pThumb {
                DllCall("gdiplus\GdipGetImageGraphicsContext", "Ptr", pThumb, "Ptr*", &pGfx)
                if pGfx {
                    DllCall("gdiplus\GdipSetInterpolationMode", "Ptr", pGfx, "Int", 7)
                    DllCall("gdiplus\GdipDrawImageRectI", "Ptr", pGfx, "Ptr", pBitmap, "Int", 0, "Int", 0, "Int", nw, "Int", nh)
                    DllCall("gdiplus\GdipDeleteGraphics", "Ptr", pGfx)
                }
                DllCall("gdiplus\GdipDisposeImage", "Ptr", pBitmap)
                pBitmap := pThumb
            }
        }

        clsid := Buffer(16)
        DllCall("ole32\CLSIDFromString", "Str", "{557CF406-1A04-11D3-9A73-0000F81EF32E}", "Ptr", clsid)
        tmp := A_Temp "\cb_" A_TickCount ".png"
        if DllCall("gdiplus\GdipSaveImageToFile", "Ptr", pBitmap, "WStr", tmp, "Ptr", clsid, "Ptr", 0)
            return ""
        DllCall("gdiplus\GdipDisposeImage", "Ptr", pBitmap)
        pBitmap := 0

        f := FileOpen(tmp, "r")
        if !IsObject(f)
            return ""
        buf := Buffer(f.Length)
        f.RawRead(buf)
        f.Close()
        try FileDelete tmp
        if buf.Size < 32
            return ""
        return "data:image/png;base64," B64Encode(buf)
    } catch {
        return ""
    } finally {
        if hCopy
            try DllCall("DeleteObject", "Ptr", hCopy)
        if pBitmap
            try DllCall("gdiplus\GdipDisposeImage", "Ptr", pBitmap)
        if pToken
            try DllCall("gdiplus\GdiplusShutdown", "Ptr", pToken)
    }
}

B64Encode(buf) {
    needed := 0
    DllCall("crypt32\CryptBinaryToStringW",
        "Ptr", buf, "UInt", buf.Size, "UInt", 0x40000001, "Ptr", 0, "UInt*", &needed, "Int")
    out := Buffer(needed * 2)
    DllCall("crypt32\CryptBinaryToStringW",
        "Ptr", buf, "UInt", buf.Size, "UInt", 0x40000001, "Ptr", out, "UInt*", &needed, "Int")
    return StrGet(out, "UTF-16")
}

; =================================================
;  Bridge
; =================================================
class ClipBridge {
    ; Defer out of sync WebView host call —sync paste from click re-enters and can paste twice
    paste(id) {
        RequestPaste(id)
    }
    pasteMany(ids, sep := "") {
        RequestPasteMany(ids, sep)
    }
    delete(id) {
        ; 立刻返回，避免 WebView 同步调用卡死界面
        SetTimer(DeleteItem.Bind(id), -1)
    }
    deleteMany(ids := "") {
        SetTimer(DeleteItemsMany.Bind(String(ids)), -1)
    }
    pin(id) {
        ; Defer —sync DiskSetPinned + SetView freezes WebView click
        SetTimer(PinItem.Bind(id), -1)
    }
    pinMany(ids := "", flag := "1") {
        ; flag 1=pin, 0=unpin —batch set (not toggle)
        SetTimer(PinItemsMany.Bind(String(ids), String(flag)), -1)
    }
    clear(tab := "all", scope := "today") {
        SetTimer(ClearTab.Bind(tab, scope), -1)
    }
    hide(*) {
        HidePanel()
    }
    moveToTop(id) {
        SetTimer(MoveToTop.Bind(id), -1)
    }
    copyById(id) {
        CopyById(id)
    }
    textTransform(id, mode := "auto") {
        SetTimer(ApplyTextTransform.Bind(id, mode), -1)
    }
    clearPasted(id) {
        ClearPasted(id)
    }
    resetQueueFrom(id) {
        SetTimer(ResetPasteQueueFrom.Bind(id), -1)
    }
    ; Multi-select → build/merge paste queue (keeps mode on so ^+c can keep joining)
    enqueueMany(ids := "") {
        SetTimer(EnqueueSelectedToPasteQueue.Bind(String(ids)), -1)
    }
    ; Remove selected from queue; empty → exit queue mode (Enter/pasteMany as before)
    dequeueMany(ids := "") {
        SetTimer(DequeueSelectedFromPasteQueue.Bind(String(ids)), -1)
    }
    setFavTitle(id, title := "") {
        SetFavTitle(id, title)
    }
    mergeFav(ids := "") {
        MergeFavItems(ids)
    }
    unmergeFav(id := 0) {
        UnmergeFavItem(id)
    }
    ; Locate: pull full favGroup around a pasted uid so UI shows 合并组 not a lone row
    ensureFavGroupAround(id := 0) {
        SetTimer(EnsureFavGroupAroundUid.Bind(Integer(id)), -1)
    }
    openLink(id) {
        OpenLink(id)
    }
    openPath(path := "") {
        OpenFilePath(path)
    }
    openFolder(path := "") {
        ; Defer — same as openDir (sync WebView host + explorer races look dead)
        SetTimer(OpenContainingFolder.Bind(String(path)), -1)
    }
    openDir(path := "") {
        ; 必须异步 — sync 调 explorer 会让 WebView 点击假死/无响应
        p := String(path)
        SetTimer(OpenFolderDir.Bind(p), -1)
    }
    copyPath(path := "") {
        CopyFilePath(path)
    }
    pathExists(path := "") {
        return PathExistsFlag(path)
    }
    primeLinkMeta(ids := "") {
        PrimeLinkMeta(ids)
    }
    stopLinkMeta(*) {
        StopLinkMeta()
    }
    checkPaths(raw := "") {
        return CheckFilePathsJson(raw)
    }
    togglePin(flag := "") {
        TogglePin(flag)
    }
    startDrag(*) {
        StartDrag()
    }
    focusPanel(*) {
        FocusPanelForInput()
    }
    blurPanel(*) {
        UnfocusPanelRestore()
    }
    setView(tab := "all", query := "", today := "0") {
        ; Return immediately — sync host+disk scan freezes tab clicks in WebView
        t := String(tab)
        ; Guard against WebView arg mis-bind (tab arriving as 0/empty)
        if t = "" || t = "0"
            t := "all"
        QueueSetView(t, String(query), String(today))
    }
    loadMore(*) {
        SetTimer(LoadMoreView, -1)
    }
    thumb(id := 0) {
        return ImageDataUrlForId(id)
    }
    ensureFileImg(path := "", uid := 0) {
        return EnsureFileImageInStore(path, uid)
    }
}

TogglePanel() {
    global guiWin, prevActiveWin, lastCaretX, lastCaretY, hasCaretPos, panelVisible
    ; If flag says visible but window is gone/hidden, treat as closed
    if panelVisible && IsObject(guiWin) {
        try {
            if !WinExist("ahk_id " guiWin.Hwnd) || !DllCall("IsWindowVisible", "Ptr", guiWin.Hwnd, "Int")
                panelVisible := false
        } catch {
            panelVisible := false
        }
    }
    try {
        cur := WinGetID("A")
        if !IsObject(guiWin) || (guiWin.Hwnd && cur != guiWin.Hwnd) {
            ; Never remember Start/Search as "previous app" —restoring it covers our panel
            prevActiveWin := ResolvePrevActiveWin(cur)
            ; OneNote: never probe caret (Gui/IME/Acc/UIA all risk Critical Error)
            if IsOneNoteApp() {
                lastCaretX := 0
                lastCaretY := 0
                hasCaretPos := false
            } else {
                GetCaretScreenPos(&cx, &cy, &found, true)
                if found {
                    lastCaretX := cx
                    lastCaretY := cy
                    hasCaretPos := true
                } else {
                    lastCaretX := 0
                    lastCaretY := 0
                    hasCaretPos := false
                }
            }
        }
    }
    if panelVisible {
        HidePanel()
        return
    }
    ShowPanel()
}

; Leave keyboard-hook context before Acc/UIA (avoids OneNote deadlock on Win+V)
TogglePanelDeferred(*) {
    TogglePanel()
}

; Start/Search use a higher z-band —cannot cover them; dismiss the visible overlay only.
; Do NOT ProcessClose StartMenuExperienceHost (process always runs; killing UI just flickers).
global dismissSearchUntil := 0
global lastGoodActiveWin := 0

IsShellOverlayHwnd(hwnd) {
    if !hwnd
        return false
    try exe := StrLower(WinGetProcessName("ahk_id " hwnd))
    catch
        return false
    return exe = "searchhost.exe" || exe = "searchapp.exe"
        || exe = "startmenuexperiencehost.exe" || exe = "shellexperiencehost.exe"
}

ShellOverlayIsShowing(*) {
    prevDetect := A_DetectHiddenWindows
    DetectHiddenWindows false
    try {
        for exe in ["SearchHost.exe", "SearchApp.exe", "StartMenuExperienceHost.exe"] {
            try {
                for hwnd in WinGetList("ahk_exe " exe) {
                    if !DllCall("IsWindowVisible", "Ptr", hwnd, "Int")
                        continue
                    try {
                        WinGetPos(, , &w, &h, "ahk_id " hwnd)
                        ; Real Start/Search overlay is large (taskbar helpers are tiny)
                        if w >= 400 && h >= 400
                            return true
                    }
                }
            }
        }
    } finally {
        DetectHiddenWindows prevDetect
    }
    return false
}

ResolvePrevActiveWin(cur := 0) {
    global lastGoodActiveWin, guiWin
    excludeGui := IsObject(guiWin) ? guiWin.Hwnd : 0
    if cur && cur != excludeGui && !IsShellOverlayHwnd(cur) && DllCall("IsWindow", "Ptr", cur, "Int") {
        lastGoodActiveWin := cur
        return cur
    }
    if lastGoodActiveWin && lastGoodActiveWin != excludeGui
        && !IsShellOverlayHwnd(lastGoodActiveWin)
        && DllCall("IsWindow", "Ptr", lastGoodActiveWin, "Int")
        return lastGoodActiveWin
    for hwnd in WinGetList() {
        if hwnd = excludeGui || IsShellOverlayHwnd(hwnd)
            continue
        if !DllCall("IsWindowVisible", "Ptr", hwnd, "Int")
            continue
        try {
            title := WinGetTitle("ahk_id " hwnd)
            cls := WinGetClass("ahk_id " hwnd)
            if title = "" && cls = ""
                continue
            if cls = "Shell_TrayWnd" || cls = "Shell_SecondaryTrayWnd" || cls = "Progman" || cls = "WorkerW"
                continue
        } catch {
            continue
        }
        lastGoodActiveWin := hwnd
        return hwnd
    }
    return 0
}

RememberGoodActiveWin(*) {
    global lastGoodActiveWin, guiWin, panelVisible, prevActiveWin
    ; 面板隐藏时不轮询前台窗（ShowPanel 会 ResolvePrevActiveWin）；固定显示才需要持续跟踪
    if !panelVisible
        return
    try {
        cur := WinGetID("A")
        if !cur
            return
        if IsObject(guiWin) && cur = guiWin.Hwnd
            return
        ; WebView 子窗口获焦时不要当成「粘贴目标」
        if IsWindowOwnedByPanel(cur)
            return
        if IsShellOverlayHwnd(cur) || IsScreenshotHelperHwnd(cur)
            return
        lastGoodActiveWin := cur
        prevActiveWin := cur
    }
}

; 粘贴目标：弹出前 / 最近聚焦的编辑窗口（固定时点面板不会改成自己）
ResolvePasteTargetWin(*) {
    global prevActiveWin, lastGoodActiveWin, guiWin
    for hwnd in [lastGoodActiveWin, prevActiveWin] {
        if !hwnd
            continue
        if IsObject(guiWin) && guiWin.Hwnd && hwnd = guiWin.Hwnd
            continue
        if IsWindowOwnedByPanel(hwnd)
            continue
        if IsShellOverlayHwnd(hwnd)
            continue
        if DllCall("IsWindow", "Ptr", hwnd, "Int")
            return hwnd
    }
    return ResolvePrevActiveWin(0)
}

DismissWindowsSearch(*) {
    prevDetect := A_DetectHiddenWindows
    DetectHiddenWindows false
    try {
        ; Mask Win so releasing it does not re-open Start
        try Send("{Blind}{vkE8}")
        try Send("{Blind}{LWin up}{RWin up}")
        for exe in ["SearchHost.exe", "SearchApp.exe", "StartMenuExperienceHost.exe"] {
            try {
                for hwnd in WinGetList("ahk_exe " exe) {
                    if !DllCall("IsWindowVisible", "Ptr", hwnd, "Int")
                        continue
                    try {
                        WinGetPos(, , &w, &h, "ahk_id " hwnd)
                        if w < 400 || h < 400
                            continue
                    }
                    ; Close only the visible Start/Search surface (title 寮€濮?/ Search)
                    try WinClose("ahk_id " hwnd)
                }
            }
        }
    } finally {
        DetectHiddenWindows prevDetect
    }
}

RaiseClipboardPanel(*) {
    global guiWin, panelVisible, uiPinned
    if !panelVisible || !IsObject(guiWin) || !guiWin.Hwnd
        return
    hwnd := guiWin.Hwnd
    try guiWin.Opt("+AlwaysOnTop")
    try DllCall("SetWindowPos", "Ptr", hwnd, "Ptr", -1
        , "Int", 0, "Int", 0, "Int", 0, "Int", 0
        , "UInt", 0x0013) ; SWP_NOSIZE|SWP_NOMOVE|SWP_NOACTIVATE
    try WinSetAlwaysOnTop(1, "ahk_id " hwnd)
}

; 仅在焦点被面板/系统搜索抢走时还回编辑器，避免反复 SetForegroundWindow 导致窗口乱跳
RestorePrevFocusQuietly(*) {
    global prevActiveWin, guiWin, qqSearchOn, searchFocused
    ; 搜索框 / F2 改标题时面板需要键盘焦点，绝不能抢回编辑器
    if searchFocused
        return
    if !prevActiveWin || IsShellOverlayHwnd(prevActiveWin)
        return
    cur := 0
    try cur := WinGetID("A")
    if !cur || cur = prevActiveWin
        return
    steal := false
    if IsObject(guiWin) && guiWin.Hwnd && cur = guiWin.Hwnd
        steal := true
    else if IsShellOverlayHwnd(cur)
        steal := true
    else if IsScreenshotHelperHwnd(cur)
        steal := true
    if steal
        try DllCall("SetForegroundWindow", "Ptr", prevActiveWin)
}

KeepSearchDismissed(*) {
    global dismissSearchUntil, panelVisible
    if A_TickCount > dismissSearchUntil {
        SetTimer(KeepSearchDismissed, 0)
        return
    }
    ; Only when the large overlay is actually visible —process itself always exists
    if ShellOverlayIsShowing()
        DismissWindowsSearch()
    if panelVisible
        RaiseClipboardPanel()
}

StartSearchGuard(*) {
    global dismissSearchUntil
    dismissSearchUntil := A_TickCount + 1200
    if ShellOverlayIsShowing()
        DismissWindowsSearch()
    RaiseClipboardPanel()
    SetTimer(KeepSearchDismissed, 80)
}

; Defer out of #UseHook; OneNote: longer delay + no caret probe (see TogglePanel)
; Win+V: Start/Search is a higher z-band than AlwaysOnTop (Windows clipboard is shell-band).
; We cannot draw above Start —prevent Start by delaying LWin until we know it's not Win+V.
HotkeyWinV(*) {
    RememberGoodActiveWin()
    ; 按键当下就采光标（延迟后再采时，焦点/IME 可能已变）
    global lastCaretX, lastCaretY, hasCaretPos
    if !IsOneNoteApp() {
        GetCaretScreenPos(&cx, &cy, &found, true)
        if found {
            lastCaretX := cx
            lastCaretY := cy
            hasCaretPos := true
        } else {
            lastCaretX := 0
            lastCaretY := 0
            hasCaretPos := false
        }
    } else {
        lastCaretX := 0
        lastCaretY := 0
        hasCaretPos := false
    }
    ; Fallback only if Start somehow already visible
    if ShellOverlayIsShowing()
        DismissWindowsSearch()
    delay := IsOneNoteApp() ? -200 : -30
    SetTimer(TogglePanelDeferred, delay)
}

ShowPanel() {
    global guiWin, wv, wvCore, lastCaretX, lastCaretY, hasCaretPos, panelVisible, uiPinned, prevActiveWin, linkMetaPausedUntil, viewToday, viewTab, qqSearchOn, qqQuery, clips, diskScanBusy, firstOpenT0, uiNavReady
    ; 仅冷启动（尚无 WebView）时重置 PERF；预热中的打开沿用同一条时间线
    if !IsObject(wvCore) && !IsObject(guiWin)
        PerfReset()
    PerfMark("ShowPanel ENTER clips=" (IsObject(clips) ? clips.Length : 0) " wv=" (IsObject(wv) ? 1 : 0) " wvCore=" (IsObject(wvCore) ? 1 : 0) " navReady=" (uiNavReady ? 1 : 0))
    ClipLog("ShowPanel ENTER")

    ; Pause any background title fetching so Win+V stays responsive
    linkMetaPausedUntil := A_TickCount + 2000
    prevActiveWin := ResolvePrevActiveWin(prevActiveWin)

    ; OneNote: bottom-right only  — never Acc/UIA/IME/Gui caret
    ; 弹出时强制新鲜探测；失败才回退到 HotkeyWinV 刚采到的样本
    ; 桌面 / 无编辑态：绝不沿用旧光标，固定右下角
    if !IsOneNoteApp() {
        if IsDesktopOrShellSurface() || !HasEditableCaretContext() {
            lastCaretX := 0
            lastCaretY := 0
            hasCaretPos := false
        } else {
            savedX := lastCaretX, savedY := lastCaretY, savedOk := hasCaretPos
            GetCaretScreenPos(&cx, &cy, &found, true)
            if found {
                lastCaretX := cx
                lastCaretY := cy
                hasCaretPos := true
            } else if savedOk {
                lastCaretX := savedX
                lastCaretY := savedY
                hasCaretPos := true
            } else {
                hasCaretPos := false
            }
        }
    } else {
        lastCaretX := 0
        lastCaretY := 0
        hasCaretPos := false
    }

    if !IsObject(guiWin) {
        PerfMark("ShowPanel before BuildGui")
        BuildGui()
        PerfMark("ShowPanel after BuildGui (async WV may still init)")
    }
    if !IsObject(guiWin)
        return
    CalcUiSize(&uiW, &uiH)
    GetWorkArea(&waL, &waT, &waR, &waB)

    if hasCaretPos {
        x := lastCaretX
        if (x + uiW > waR - 2)
            x := waR - uiW - 2
        if x < waL + 2
            x := waL + 2

        lineGapBelow := 10   ; half of previous 20 —panel under caret
        lineGapAbove := 30   ; was 36; only -6 when panel sits above caret
        cy := lastCaretY
        if (cy + lineGapBelow + uiH <= waB - 2)
            y := cy + lineGapBelow
        else
            y := cy - uiH - lineGapAbove
        y := Max(waT + 2, Min(y, waB - uiH - 2))
    } else {
        ; Bottom-right of work area: 2px from right edge, 2px above taskbar
        x := waR - uiW - 2
        y := waB - uiH - 2
    }

    guiWin.Move(x, y, uiW, uiH)
    ; NoActivate when unpinned (keep editor focus); pinned must stay activatable for Ctrl+F
    try guiWin.Opt("+AlwaysOnTop")
    if uiPinned {
        try guiWin.Opt("-E0x08000000")
    } else {
        try guiWin.Opt("+E0x08000000")
    }
    guiWin.Show("NA x" x " y" y " w" uiW " h" uiH)
    ApplyRoundedCorners(guiWin.Hwnd, uiW, uiH, 10)
    panelVisible := true
    PerfMark("ShowPanel window shown")
    RaiseClipboardPanel()
    ; Restore previous app focus  — never Start/Search (that re-covers our panel)
    prevActiveWin := ResolvePrevActiveWin(prevActiveWin)
    ; ?? / Win+V：不要无脑 SetForegroundWindow（会闪、会乱跳）
    RestorePrevFocusQuietly()
    if IsObject(wv) {
        try {
            wv.Fill()
            wv.IsVisible := true
            wv.NotifyParentWindowPositionChanged()
        }
    }
    if IsObject(wvCore) {
        ; Show first, push data after paint  — avoids Win+V freeze on large clip JSON
        ; 不要每次 Invalidate：清空缓存会逼磁盘重扫，列表先空再满 → 闪一下
        keepSearch := qqSearchOn ? "true" : "false"
        try wvCore.ExecuteScriptAsync("window.__onPanelShow && window.__onPanelShow(" keepSearch ")")
        if qqSearchOn {
            QQPushQuery()
        } else if (IsObject(clips) && clips.Length > 0) {
            ; 预热已有列表 → 绝不二次 SetView/扫盘（diskScanBusy 时更不能扫）
            SetTimer(() => RequestUiPush(), -30)
        } else if diskScanBusy {
            SetTimer(() => RequestUiPush(), -30)
        } else
            SetTimer(() => (SetView(viewTab, "", viewToday ? "1" : "0"), RequestUiPush()), -30)
        SetTimer(() => PushPinStateToUi(), -50)
    }
}

EscHidePanel(*) {
    global uiPinned, qqSearchOn
    ; ?? 会话中：Esc = 结束本次搜索（面板藏着也算），等下一次 ??
    if qqSearchOn {
        QQAbortSearch()
        return
    }
    if uiPinned
        return
    HidePanel()
}

PanelKeyUp(*) {
    global wvCore
    if IsObject(wvCore)
        try wvCore.ExecuteScriptAsync("window.__nav && window.__nav('up')")
}
PanelKeyDown(*) {
    global wvCore
    if IsObject(wvCore)
        try wvCore.ExecuteScriptAsync("window.__nav && window.__nav('down')")
}
PanelKeyEnter(*) {
    global wvCore
    if IsObject(wvCore)
        try wvCore.ExecuteScriptAsync("window.__onEnter && window.__onEnter()")
}
PanelKeyEditTitle(*) {
    global wvCore
    if !ClipPanelIsUp()
        return
    FocusPanelForInput()
    if IsObject(wvCore)
        try wvCore.ExecuteScriptAsync("window.__editTitle && window.__editTitle()")
    ; 对话框打开后再抢一次焦点，避免被 RestorePrevFocus / 重绘抢走
    SetTimer(FocusPanelForInput, -50)
    SetTimer(FocusPanelForInput, -140)
}
PanelKeyNextTab(*) {
    global wvCore
    if IsObject(wvCore)
        try wvCore.ExecuteScriptAsync("window.__cycleTab && window.__cycleTab(1)")
}
PanelKeyPrevTab(*) {
    global wvCore
    if IsObject(wvCore)
        try wvCore.ExecuteScriptAsync("window.__cycleTab && window.__cycleTab(-1)")
}

PanelOpenSearch(*) {
    global wvCore
    if !ClipPanelIsUp()
        return
    FocusPanelForInput()
    if IsObject(wvCore)
        try wvCore.ExecuteScriptAsync("window.__openSearch && window.__openSearch()")
}

; ?? / ？？ + 关键字：原编辑框照常输入（不删字、不抢光标），关键字镜像到面板搜索框
QQQuestionHotIf(*) {
    global searchFocused
    return !(ClipPanelIsUp() && searchFocused)
}

QQQuestionKeyHeld(*) {
    if GetKeyState("Shift", "P") && (GetKeyState("/", "P") || GetKeyState("vkBF", "P"))
        return true
    return false
}

QQOnSlashQuestion(*) {
    if GetKeyState("Shift", "P")
        QQOnQuestion()
}

QQInstallSearchHotkeys(*) {
    ; ~ 透传：问号仍打进当前编辑框；不要用裸 ~?（中文布局会报错）
    try HotIf QQQuestionHotIf
    installed := false
    try {
        Hotkey("~+/", QQOnQuestion, "On")
        installed := true
    }
    if !installed {
        try Hotkey("~*vkBF", QQOnSlashQuestion, "On")
    }
    try Hotkey("~？", QQOnQuestion, "On")
    try HotIf
}

QQArmReleaseWatch(*) {
    global qqNeedRelease
    qqNeedRelease := true
    SetTimer(QQWatchQuestionRelease, 15)
}

QQWatchQuestionRelease(*) {
    global qqNeedRelease
    if QQQuestionKeyHeld()
        return
    qqNeedRelease := false
    SetTimer(QQWatchQuestionRelease, 0)
}

QQClearPending(*) {
    global qqPending, qqMarkCount
    qqPending := false
    qqMarkCount := 0
}

QQResetMarkCount(*) {
    global qqMarkCount
    qqMarkCount := 0
}

QQIsQuestionChar(ch) {
    return ch = "?" || ch = "？"
}

QQClearSearchState(*) {
    global qqQuery, qqAwaitKeyword, viewQuery
    qqQuery := ""
    qqAwaitKeyword := false
    viewQuery := ""
    SetTimer(QQApplyQueryView, 0)
    SetTimer(QQAwaitIdleAbort, 0)
    SoftHidePanel()
    ; 强制清空搜索框（哪怕随后 Stop）
    try {
        global wvCore, qqSearchOn
        if IsObject(wvCore)
            wvCore.ExecuteScriptAsync("window.__setSearchQuery&&window.__setSearchQuery('')")
    }
}

QQAbortSearch(*) {
    ; Esc / ???? / 超时取消：结束镜像；??? 是表情搜索不是取消
    QQClearSearchState()
    QQStopSearch(true)
}

QQScheduleAwaitTimeout(*) {
    ; ?? 后一直不输入关键字（或只打了前导空格）：自动结束，避免“一直在搜”
    SetTimer(QQAwaitIdleAbort, -6000)
}

QQAwaitIdleAbort(*) {
    global qqSearchOn, qqAwaitKeyword
    if qqSearchOn && qqAwaitKeyword
        QQAbortSearch()
}

QQOnQuestion(*) {
    global searchFocused, qqNeedRelease, qqMarkCount, qqSearchOn, qqAwaitKeyword
    if GetKeyState("Ctrl", "P") || GetKeyState("Alt", "P") || GetKeyState("LWin", "P") || GetKeyState("RWin", "P")
        return
    if ClipPanelIsUp() && searchFocused
        return
    ; 按住重复触发忽略
    if qqNeedRelease
        return
    QQArmReleaseWatch()
    qqMarkCount += 1
    SetTimer(QQResetMarkCount, -700)

    if qqMarkCount >= 4 {
        ; ???? → 取消
        SetTimer(QQResetMarkCount, 0)
        qqMarkCount := 0
        QQAbortSearch()
        return
    }
    if qqMarkCount = 3 {
        ; ??? / ？？？ → 表情搜索（等关键字才出 UI，同 ??）
        QQArmEmojiSearch()
        return
    }
    if qqMarkCount = 2 {
        ; ?? → 剪贴板历史搜索
        QQArmFreshSearch()
    }
}

; 重新打 ??：清空之前的查询条件，只武装、不弹窗
QQArmFreshSearch(*) {
    global qqSearchOn, qqQuery, qqIh, qqAwaitKeyword, qqPanelPlaced, qqEmojiMode
        , prevActiveWin, lastCaretX, lastCaretY, hasCaretPos, guiWin
    SetTimer(QQClearPending, 0)
    SetTimer(QQApplyQueryView, 0)
    RememberGoodActiveWin()
    if !IsOneNoteApp() {
        GetCaretScreenPos(&cx, &cy, &found, true)
        if found {
            lastCaretX := cx
            lastCaretY := cy
            hasCaretPos := true
        } else {
            lastCaretX := 0
            lastCaretY := 0
            hasCaretPos := false
        }
    } else {
        lastCaretX := 0
        lastCaretY := 0
        hasCaretPos := false
    }
    ; 停掉旧 hook，清空脏查询
    if IsObject(qqIh) {
        try qqIh.Stop()
        qqIh := 0
    }
    qqQuery := ""
    qqAwaitKeyword := true
    qqSearchOn := true
    qqEmojiMode := false
    SoftHidePanel()
    try {
        global wvCore
        if IsObject(wvCore)
            wvCore.ExecuteScriptAsync("window.__setSearchQuery&&window.__setSearchQuery('')")
    }
    ; 不要立刻 SetView 出结果；等第一个非 ? / 非前导空格 的关键字
    qqIh := InputHook("V")
    qqIh.OnChar := QQOnChar
    qqIh.KeyOpt("{Backspace}", "N")
    qqIh.KeyOpt("{Escape}", "N")  ; Esc → OnKeyDown 结束本次搜索
    qqIh.KeyOpt("{Enter}", "NS")  ; 拦截回车，避免 Slack/微信当成发送
    qqIh.KeyOpt("{NumpadEnter}", "NS")
    qqIh.OnKeyDown := QQOnKeyDown
    qqIh.Start()
    QQScheduleAwaitTimeout()
    ; ?? 一武装就：醒 WebView + 后台建搜索池（首字前尽量暖好，避免 EnsureSearchPool 卡主线程）
    QQWakeWebView()
    SetTimer(WarmSearchPools, -1)
}

; ??? / ？？？：表情搜索。若刚打完 ?? 已挂好钩子，只切模式
QQArmEmojiSearch(*) {
    global qqEmojiMode, qqSearchOn, qqIh, qqQuery, qqAwaitKeyword, wvCore
    if !qqSearchOn || !IsObject(qqIh)
        QQArmFreshSearch()
    qqEmojiMode := true
    qqQuery := ""
    qqAwaitKeyword := true
    qqSearchOn := true
    SoftHidePanel()
    try {
        if IsObject(wvCore)
            wvCore.ExecuteScriptAsync("window.__setSearchQuery&&window.__setSearchQuery('')")
    }
    QQScheduleAwaitTimeout()
    QQWakeWebView()
    SetTimer(EnsureEmojiSearchIndex, -1)
}

QQOnChar(ih, ch) {
    global qqQuery, qqAwaitKeyword, qqMarkCount
    if ch = "" || ch = "`b" || ch = "`r" || ch = "`n"
        return
    ; 问号只用于 ?? / ??? 武装（热键计数），不进查询、这里不取消
    if QQIsQuestionChar(ch)
        return
    ; ?? / ??? 后的前导空格/制表不触发搜索
    if qqAwaitKeyword && (ch = " " || ch = "`t") {
        QQScheduleAwaitTimeout()
        return
    }
    qqAwaitKeyword := false
    qqMarkCount := 0
    SetTimer(QQResetMarkCount, 0)
    SetTimer(QQAwaitIdleAbort, 0)
    qqQuery .= ch
    QQOnQueryChanged()
}

QQOnKeyDown(ih, vk, sc) {
    global qqQuery, qqAwaitKeyword
    if vk = 8 {
        if StrLen(qqQuery)
            qqQuery := SubStr(qqQuery, 1, -1)
        if qqQuery = "" {
            qqAwaitKeyword := true
            SoftHidePanel()
            QQScheduleAwaitTimeout()
        }
        QQOnQueryChanged()
        return
    }
    if vk = 13 || vk = 1072 { ; Enter / NumpadEnter（已 NS 拦截，不会进目标窗）
        PanelKeyEnter()
        return
    }
    if vk = 27 {
        QQAbortSearch()
    }
}

QQOnQueryChanged(*) {
    ; 1) 立刻镜像搜索框（可等 WebView）
    ; 2) AHK 侧直接 SetView——不依赖 WebView 回环（久藏后 Edge 醒得慢时否则会「很久才出结果」）
    QQPushQuery()
    SetTimer(QQApplyQueryView, -30)
}

QQApplyQueryView(*) {
    global qqSearchOn, qqQuery, viewTab, viewToday, qqAwaitKeyword
    if !qqSearchOn || qqAwaitKeyword
        return
    if Trim(String(qqQuery)) = ""
        return
    SetView(viewTab, qqQuery, viewToday ? "1" : "0")
}

QQPushQuery(*) {
    global wvCore, qqQuery, qqSearchOn, uiNavReady
    if !qqSearchOn
        return
    if !IsObject(wvCore) || !uiNavReady {
        ; WebView 尚未就绪：等导航完成再挂；不要丢关键字
        SetTimer(QQAttachUi, -60)
        return
    }
    try wvCore.ExecuteScriptAsync("window.__setSearchQuery&&window.__setSearchQuery(" JsonStr(qqQuery) ")")
}

; 轻量戳醒已挂起的 WebView2（久不打开面板后 Edge 进程常休眠）
QQWakeWebView(*) {
    global guiWin, wv, wvCore, wvBuilding, uiNavReady
    if !IsObject(guiWin) && !wvBuilding {
        try BuildGui()
        return
    }
    if !IsObject(wvCore) {
        SetTimer(QQAttachUi, -80)
        return
    }
    try {
        if IsObject(wv) {
            ; 触达控制器，促醒休眠的浏览器进程
            wv.IsVisible := true
            wv.NotifyParentWindowPositionChanged()
        }
    } catch {
    }
    try wvCore.ExecuteScriptAsync("void 0")
    catch {
    }
    if !uiNavReady
        SetTimer(QQAttachUi, -80)
}

QQAttachUi(*) {
    global qqSearchOn, wvCore, uiNavReady, qqQuery, qqAwaitKeyword
    if !qqSearchOn
        return
    if !IsObject(wvCore) || !uiNavReady {
        SetTimer(QQAttachUi, -80)
        return
    }
    QQPushQuery()
    if !qqAwaitKeyword && Trim(String(qqQuery)) != ""
        SetTimer(QQApplyQueryView, -20)
    RestorePrevFocusQuietly()
}

QQStopSearch(resetFlag := true) {
    global qqIh, qqSearchOn, qqPending, qqNeedRelease, qqPanelPlaced, qqQuery
        , qqAwaitKeyword, qqMarkCount, qqEmojiMode, clips, viewQuery
        , emojiHitCache, emojiHitQuery
    SetTimer(QQAttachUi, 0)
    SetTimer(QQWatchQuestionRelease, 0)
    SetTimer(QQClearPending, 0)
    SetTimer(QQApplyQueryView, 0)
    SetTimer(QQResetMarkCount, 0)
    SetTimer(QQAwaitIdleAbort, 0)
    qqPending := false
    qqNeedRelease := false
    qqAwaitKeyword := false
    qqMarkCount := 0
    if IsObject(qqIh) {
        try qqIh.Stop()
        qqIh := 0
    }
    if resetFlag {
        wasEmoji := qqEmojiMode
        qqEmojiMode := false
        qqSearchOn := false
        qqPanelPlaced := false
        qqQuery := ""
        ; 表情结果不是剪贴板历史。清掉 clips，但保留 emojiHitCache 供粘贴 ResolveClip
        if wasEmoji {
            clips := []
            viewQuery := ""
            ; emojiHitCache / emojiHitQuery 留给紧随其后的 PasteItem
        }
    }
}

QQTypedEraseCount(*) {
    global qqSearchOn, qqQuery, qqEmojiMode
    if !qqSearchOn
        return 0
    ; ?? = 2；??? 表情 = 3；再加上关键字
    marks := qqEmojiMode ? 3 : 2
    return marks + StrLen(String(qqQuery))
}

QQEraseTypedInEditor(n) {
    n := Integer(n)
    if n < 1
        return
    Sleep 25
    SendInput("{BS " n "}")
    Sleep 30
}

; 仅还焦点，不点鼠标、不还原窗口尺寸（避免 Slack 缩窗 / 点到别的页）
ForceActivateHwnd(hwnd) {
    hwnd := Integer(hwnd)
    if hwnd < 1 || !DllCall("IsWindow", "Ptr", hwnd, "Int")
        return false
    try {
        fg := DllCall("GetForegroundWindow", "Ptr")
        tidT := DllCall("GetWindowThreadProcessId", "Ptr", hwnd, "UInt*", 0, "UInt")
        tidF := DllCall("GetWindowThreadProcessId", "Ptr", fg, "UInt*", 0, "UInt")
        attached := false
        if tidF && tidT && tidF != tidT {
            DllCall("AttachThreadInput", "UInt", tidF, "UInt", tidT, "Int", 1)
            attached := true
        }
        DllCall("SetForegroundWindow", "Ptr", hwnd)
        if attached
            DllCall("AttachThreadInput", "UInt", tidF, "UInt", tidT, "Int", 0)
    } catch {
        try DllCall("SetForegroundWindow", "Ptr", hwnd)
    }
    return true
}

; 表情 uid 不进剪贴板库，避免收藏/删除去扫盘
IsEmojiSearchUid(uid) {
    return Integer(uid) >= 1800000000
}

PinyinMapPath() {
    return A_ScriptDir "\data\pinyin_map.txt"
}

EmojiConfigPath() {
    home := ""
    try home := Trim(EnvGet("HELPME_HOME"))
    if home != "" {
        p := RTrim(home, "\/") "\command_ext\ahk\config\emoji.txt"
        if FileExist(p)
            return p
    }
    return A_ScriptDir "\data\emoji.txt"
}

LoadPinyinMap(*) {
    global pyMap, pyMapReady
    if pyMapReady
        return
    pyMap := Map()
    path := PinyinMapPath()
    if !FileExist(path) {
        ClipLog("pinyin map missing " path)
        pyMapReady := true
        return
    }
    ; 必须用 FileOpen UTF-8：Loop Read 的第二参数是输出文件，不是编码
    try {
        f := FileOpen(path, "r", "UTF-8")
        while !f.AtEOF {
            line := Trim(f.ReadLine())
            if line = "" || SubStr(line, 1, 1) = "#"
                continue
            sp := InStr(line, " ")
            if sp < 2
                continue
            pyMap[SubStr(line, 1, sp - 1)] := StrLower(Trim(SubStr(line, sp + 1)))
        }
        f.Close()
    } catch as e {
        ClipLog("pinyin map read fail: " e.Message)
    }
    pyMapReady := true
    ClipLog("pinyin map n=" pyMap.Count)
}

EmojiKeyPinyin(key, &initials) {
    global pyMap
    py := ""
    ini := ""
    if !IsObject(pyMap)
        pyMap := Map()
    for ch in StrSplit(String(key)) {
        if pyMap.Has(ch) {
            p := pyMap[ch]
            py .= p
            if p != ""
                ini .= SubStr(p, 1, 1)
        } else if RegExMatch(ch, "^[A-Za-z0-9]$") {
            p := StrLower(ch)
            py .= p
            ini .= p
        }
    }
    initials := ini
    return py
}

EnsureEmojiSearchIndex(*) {
    global emojiIndex, emojiIndexReady, emojiIndexStamp, pyMap, pyMapReady, emojiHitQuery
    LoadPinyinMap()
    path := EmojiConfigPath()
    stamp := path "|" (pyMapReady ? pyMap.Count : 0)
    if FileExist(path)
        stamp .= "|" FileGetTime(path, "M")
    if emojiIndexReady && emojiIndexStamp = stamp
        return
    emojiIndex := []
    group := ""
    seen := Map()
    n := 0
    if FileExist(path) {
        try {
            f := FileOpen(path, "r", "UTF-8")
            while !f.AtEOF {
                line := Trim(f.ReadLine())
                if line = ""
                    continue
                if RegExMatch(line, "^#{3,}.*【(.+)】", &gm) {
                    group := gm[1]
                    continue
                }
                if SubStr(line, 1, 1) = "#"
                    continue
                eq := InStr(line, "=")
                if eq < 2
                    continue
                key := Trim(SubStr(line, 1, eq - 1))
                face := Trim(SubStr(line, eq + 1))
                if key = "" || face = ""
                    continue
                sig := face "|" key
                if seen.Has(sig)
                    continue
                seen[sig] := true
                n += 1
                ini := ""
                py := EmojiKeyPinyin(key, &ini)
                emojiIndex.Push({
                    uid: 1800000000 + n,
                    face: face,
                    key: key,
                    group: group,
                    py: py,
                    pyU: StrReplace(py, "v", "u"),
                    ini: ini
                })
            }
            f.Close()
        } catch as e {
            ClipLog("emoji index read fail: " e.Message)
        }
    }
    emojiIndexStamp := stamp
    emojiIndexReady := true
    emojiHitQuery := ""
    ClipLog("emoji index n=" emojiIndex.Length " file=" path)
}

EmojiRecToClip(rec) {
    ; 上：汉字解释；下：只拼音（不显示组名）
    return {
        uid: rec.uid,
        type: "emoji",
        data: rec.face,
        preview: rec.py,
        favTitle: rec.key,
        time: FormatTime(, "yyyy-MM-dd HH:mm:ss"),
        pinned: false,
        pasted: false,
        charCount: StrLen(rec.key),
        fileCount: 0,
        width: 0,
        height: 0
    }
}

EmojiTermHit(rec, term) {
    t := StrLower(Trim(String(term)))
    if t = ""
        return false
    tU := StrReplace(t, "v", "u")
    if rec.pyU != "" && InStr(rec.pyU, tU)
        return true
    if rec.py != "" && InStr(rec.py, t)
        return true
    if InStr(StrLower(rec.key), t)
        return true
    if StrLen(t) >= 2 && (rec.ini = t || InStr(rec.ini, t) = 1)
        return true
    return false
}

EmojiRecMatches(rec, q) {
    q := StrLower(Trim(String(q)))
    if q = ""
        return false
    ; 与历史搜索一致：空格 / | 都是分词，各项须同时命中
    terms := []
    for part in StrSplit(q, "|") {
        for term in StrSplit(Trim(part), " `t") {
            term := Trim(term)
            if term != ""
                terms.Push(term)
        }
    }
    if terms.Length < 1
        return false
    for term in terms {
        if !EmojiTermHit(rec, term)
            return false
    }
    return true
}

EmojiRecPrefixScore(rec, q) {
    ; 排序：整段拼音前缀 > 首词前缀 > 其它
    compact := StrLower(RegExReplace(Trim(String(q)), "[\s|]+", ""))
    compactU := StrReplace(compact, "v", "u")
    if compactU != "" && InStr(rec.pyU, compactU) = 1
        return 0
    first := ""
    for part in StrSplit(StrLower(Trim(String(q))), "|") {
        for term in StrSplit(Trim(part), " `t") {
            if Trim(term) != "" {
                first := StrReplace(Trim(term), "v", "u")
                break
            }
        }
        if first != ""
            break
    }
    if first != "" && InStr(rec.pyU, first) = 1
        return 1
    if first != "" && InStr(StrLower(rec.key), first) = 1
        return 1
    return 2
}

QueryEmojiHits(query, offset, limit) {
    global emojiIndex, emojiHitCache, emojiHitQuery
    EnsureEmojiSearchIndex()
    q := Trim(String(query))
    all := []
    if emojiHitQuery = q && IsObject(emojiHitCache) {
        all := emojiHitCache
    } else {
        buckets := [[], [], []]
        if IsObject(emojiIndex) {
            for rec in emojiIndex {
                if !EmojiRecMatches(rec, q)
                    continue
                score := EmojiRecPrefixScore(rec, q)
                buckets[score + 1].Push(rec)
            }
        }
        for bi in [1, 2, 3] {
            for rec in buckets[bi]
                all.Push(EmojiRecToClip(rec))
        }
        emojiHitCache := all
        emojiHitQuery := q
    }
    items := []
    total := all.Length
    i := Integer(offset) + 1
    n := 0
    lim := Integer(limit)
    while i <= total && n < lim {
        items.Push(all[i])
        i += 1
        n += 1
    }
    return { items: items, total: total }
}

LoadMoreEmojiHits(*) {
    global clips, viewTotal, VIEW_PAGE_SIZE, lastAppendCount, wvCore, emojiHitCache
    if !IsObject(emojiHitCache)
        emojiHitCache := []
    viewTotal := emojiHitCache.Length
    added := 0
    i := clips.Length + 1
    while i <= emojiHitCache.Length && added < VIEW_PAGE_SIZE {
        clips.Push(emojiHitCache[i])
        i += 1
        added += 1
    }
    lastAppendCount := added
    if IsObject(wvCore) {
        if added > 0
            PushClips(true)
        else
            try wvCore.ExecuteScriptAsync("window.__loadMoreDone&&window.__loadMoreDone()")
    }
}

OnOutsideClick(*) {
    global guiWin, uiPinned, panelVisible, viewSwitchGuardUntil
    if !panelVisible || uiPinned || !IsObject(guiWin)
        return
    ; 切页/扫盘卡顿期间点到的后续点击不要关面板
    if A_TickCount < viewSwitchGuardUntil
        return
    try {
        CoordMode "Mouse", "Screen"
        MouseGetPos(&mx, &my, &hwndUnder)
        ; WebView 是子窗口：点在面板内时 hwnd 往往不是 guiWin 本身
        if hwndUnder && IsWindowOwnedByPanel(hwndUnder)
            return
        WinGetPos(&wx, &wy, &ww, &wh, "ahk_id " guiWin.Hwnd)
        if (mx >= wx && mx <= wx + ww && my >= wy && my <= wy + wh)
            return
        HidePanel()
    }
}

IsWindowOwnedByPanel(hwnd) {
    global guiWin
    if !hwnd || !IsObject(guiWin) || !guiWin.Hwnd
        return false
    root := guiWin.Hwnd
    if hwnd = root
        return true
    ; 沿父链走到面板根
    cur := hwnd
    loop 12 {
        parent := DllCall("GetParent", "Ptr", cur, "Ptr")
        if !parent
            break
        if parent = root
            return true
        cur := parent
    }
    return false
}

; 独立运行：关窗口 = 退出进程；挂在快捷键4下：只隐藏面板
OnClipboardPanelClose(*) {
    global clipboardStandalone, clipboardTrayVisible
    if clipboardStandalone
        ExitApp
    HidePanel()
}

BuildGui() {
    global guiWin, wv, wvCore, HTML_FILE, CLIP_V1_DIR, STORE_DIR, STORE_HOST, panelVisible, wvBuilding
    PerfMark("BuildGui ENTER")
    ClipLog("BuildGui ENTER")
    if IsObject(guiWin) || wvBuilding {
        ClipLog("BuildGui skip already building/built")
        return
    }
    wvBuilding := true

    guiWin := Gui("-Caption -Border +ToolWindow +AlwaysOnTop")
    guiWin.BackColor := "e4e7ee"   ; 与 UI 底色一致，避免外缘露灰边 #a6a49b
    guiWin.MarginX := 0
    guiWin.MarginY := 0
    guiWin.OnEvent("Close", OnClipboardPanelClose)
    guiWin.OnEvent("Size", OnGuiSize)
    ; WS_EX_NOACTIVATE: showing the panel must not steal keyboard focus
    try guiWin.Opt("+E0x08000000")

    CalcUiSize(&uiW, &uiH)
    guiWin.Show("NA x-32000 y-32000 w" uiW " h" uiH)
    EnableDwmShadow(guiWin.Hwnd)
    PerfMark("BuildGui before WebView2.create")

    try {
        dll := A_ScriptDir "\lib\webview2\WebView2Loader.dll"
        if !FileExist(dll)
            dll := A_Temp "\WebView2Loader.dll"  ; 兼容旧路径
        if !FileExist(dll)
            throw Error("找不到 WebView2Loader.dll:`n" A_ScriptDir "\lib\webview2\WebView2Loader.dll")

        dataDir := CLIP_V1_DIR "\wv2data"
        opts := {
            AdditionalBrowserArguments: "--enable-features=msWebView2EnableDraggableRegions"
        }
        ; Async: do not block AHK thread while Edge process starts
        WebView2.create(guiWin.Hwnd, FinishWebViewInit, 0, dataDir, "", opts, dll)
        PerfMark("BuildGui WebView2.create requested")
    } catch as e {
        wvBuilding := false
        TrayTip("WebView2 init failed", e.Message, "Iconx")
        try FileAppend(FormatTime() " WebView2: " e.Message "`n", CLIP_V1_DIR "\error.log", "UTF-8")
    }

    guiWin.Hide()
    panelVisible := false
}

FinishWebViewInit(controller) {
    global wv, wvCore, HTML_FILE, STORE_DIR, STORE_HOST, APP_HOST, CLIP_V1_DIR, wvBuilding, panelVisible
        , diskScanBusy, clips
    PerfMark("FinishWebViewInit ENTER")
    try {
        wv := controller
        wv.Fill()
        wv.IsVisible := true
        try wv.DefaultBackgroundColor := 0xFFE4E7EE

        wvCore := wv.CoreWebView2
        wvCore.Settings.AreDefaultContextMenusEnabled := false
        wvCore.Settings.IsStatusBarEnabled := false
        ; Stop Chromium Ctrl+F find from eating our search shortcut
        try wvCore.Settings.AreBrowserAcceleratorKeysEnabled := false
        ; 禁止 Ctrl+滚轮 / Ctrl± 缩放界面
        try wvCore.Settings.IsZoomControlEnabled := false
        try wvCore.Settings.IsNonClientRegionSupportEnabled := true
        try wvCore.ZoomFactor := 1

        ; Virtual hosts: UI at https://clipui.app/ ; thumbs at /clips_store/...
        ; Prefer 8.3 short paths —spaces in "goland project" break WebView2 folder mapping.
        try {
            DirCreate STORE_DIR
            DirCreate CLIP_V1_DIR
            mapRoot := GetShortPath(CLIP_V1_DIR)
            mapStore := GetShortPath(STORE_DIR)
            wvCore.SetVirtualHostNameToFolderMapping(APP_HOST, mapRoot, 1)
            wvCore.SetVirtualHostNameToFolderMapping(STORE_HOST, mapStore, 1)
            ClipLog("WV2 map APP=" mapRoot " STORE=" mapStore)
        }
        PerfMark("FinishWebViewInit mapped hosts")

        try wvCore.InjectAhkComponent()
        wvCore.AddHostObjectToScript("ahk", ClipBridge())
        PerfMark("FinishWebViewInit hostObject ready")

        if !FileExist(HTML_FILE)
            throw Error("找不到界面文件`n" HTML_FILE)

        ; UI → AHK：路径用 postMessage，避免 sync host 吞反斜杠 / 点击无响应
        try wvCore.add_WebMessageReceived(HandleUiWebMessage)

        ; Navigate 完整 UI（clipui.app 无 mDNS 坑；首屏由 PaintAllFirstPage 推）
        wvCore.add_NavigationCompleted(OnUiNavigationCompleted)
        PerfMark("FinishWebViewInit before Navigate")
        navVer := UiCacheVer()
        wvCore.Navigate("https://" APP_HOST "/index.html?v=" navVer)
        wvBuilding := false
        PerfMark("FinishWebViewInit Navigate issued ver=" navVer)
        if panelVisible
            SetTimer(() => (
                IsObject(wv) && (wv.Fill(), wv.IsVisible := true, wv.NotifyParentWindowPositionChanged())
            ), -80)
    } catch as e {
        wvBuilding := false
        TrayTip("WebView2 init failed", e.Message, "Iconx")
        try FileAppend(FormatTime() " WebView2: " e.Message "`n", CLIP_V1_DIR "\error.log", "UTF-8")
    }
}

OnUiNavigationCompleted(core, args) {
    global uiNavReady, wvCore
    uiNavReady := true
    try wvCore.ZoomFactor := 1
    PerfMark("NavigationCompleted (app)")
    SetTimer(PaintAllFirstPage, -1)
    SetTimer(() => PushPinStateToUi(), -80)
}

UiCacheVer(*) {
    global UI_CACHE_VER
    if UI_CACHE_VER = ""
        UI_CACHE_VER := "20260922-emoji-enter"
    return UI_CACHE_VER
}

; 脚本启动后后台预热 Edge/WebView，把 ~2s 冷启动挪出首次 Win+V
WarmWebViewEarly(*) {
    global guiWin, wvCore, wvBuilding, uiNavReady
    if IsObject(wvCore) || IsObject(guiWin) || wvBuilding {
        ClipLog("WarmWebViewEarly skip ready=" (IsObject(wvCore) ? 1 : 0))
        return
    }
    ClipLog("WarmWebViewEarly START")
    PerfMark("WarmWebViewEarly BuildGui")
    try BuildGui()
    catch as e {
        ClipLogErr("WarmWebViewEarly", e)
    }
}

; First paint: only push first 20 of「全部」; search pool warmed in background after paint
PaintAllFirstPage(*) {
    global qqSearchOn, clips, wvCore, pendingViewArmed, firstAllPaintDone
    PerfMark("PaintAllFirstPage START clips=" (IsObject(clips) ? clips.Length : 0))
    ClipLog("PaintAllFirstPage START")
    t0 := A_TickCount
    try {
        if IsObject(clips) && clips.Length > 0 {
            PerfMark("PaintAllFirstPage cache-hit PushClips")
            if !qqSearchOn && IsObject(wvCore)
                PushClips(false)
        } else {
            PerfMark("PaintAllFirstPage cold PreloadAllViews")
            PreloadAllViews("0", true)
        }
        firstAllPaintDone := true
        PerfMark("PaintAllFirstPage END n=" (IsObject(clips) ? clips.Length : 0) " localMs=" (A_TickCount - t0))
        ClipLog("PaintAllFirstPage END n=" (IsObject(clips) ? clips.Length : 0) " ms=" (A_TickCount - t0))
    } catch as e {
        firstAllPaintDone := true
        ClipLogErr("PaintAllFirstPage", e)
        PerfMark("PaintAllFirstPage ERR")
    }
    if pendingViewArmed
        SetTimer(ApplyPendingView, -1)
    SetTimer(DrainDiskJobs, -50)
    EnqueueDiskJob(PruneOldScreenshots)
    ; 首屏后再建搜索索引，避免 ?? 第一次敲字才全库扫盘
    SetTimer(WarmSearchPools, -250)
    SetTimer(EnsureEmojiSearchIndex, -800)
    if qqSearchOn
        SetTimer(QQAttachUi, -40)
}

WarmAllViewsAfterNav(*) {
    PaintAllFirstPage()
}
StartDrag() {
    global guiWin
    if !IsObject(guiWin)
        return
    DllCall("ReleaseCapture")
    PostMessage 0xA1, 2, 0,, "ahk_id " guiWin.Hwnd
}

; Temporarily activate panel so search / title input can receive typing
FocusPanelForInput() {
    global guiWin, searchFocused, uiPinned
    searchFocused := true
    if !IsObject(guiWin)
        return
    ; Pinned panels must accept activation; NOACTIVATE blocks Ctrl+F / F2 focus
    try guiWin.Opt("-E0x08000000")
    try {
        WinActivate("ahk_id " guiWin.Hwnd)
        DllCall("SetForegroundWindow", "Ptr", guiWin.Hwnd)
    }
}

; After search closes, restore NoActivate and return focus to previous window
UnfocusPanelRestore() {
    global guiWin, prevActiveWin, searchFocused, uiPinned, qqSearchOn
    searchFocused := false
    ; Keep activatable while pinned so Ctrl+F still works without clicking UI
    if IsObject(guiWin) && !uiPinned {
        try guiWin.Opt("+E0x08000000")
    }
    if !uiPinned && !qqSearchOn
        RestorePrevFocusQuietly()
}

GetWorkArea(&l, &t, &r, &b) {
    try MonitorGetWorkArea(, &l, &t, &r, &b)
    catch {
        l := 0, t := 0, r := A_ScreenWidth, b := A_ScreenHeight
    }
}

SetClipboardImage(imgPath) {
    if !FileExist(imgPath)
        return false

    pngBuf := ""
    try {
        f := FileOpen(imgPath, "r")
        if IsObject(f) {
            pngBuf := Buffer(f.Length)
            f.RawRead(pngBuf)
            f.Close()
        }
    }

    DllCall("LoadLibrary", "Str", "gdiplus.dll", "Ptr")
    si := Buffer(24, 0)
    NumPut("UInt", 1, si)
    pToken := 0
    DllCall("gdiplus\GdiplusStartup", "UPtr*", &pToken, "Ptr", si, "Ptr", 0)
    if !pToken
        return false

    ok := false
    pBitmap := 0, hBitmap := 0
    try {
        if DllCall("gdiplus\GdipCreateBitmapFromFile", "WStr", imgPath, "UPtr*", &pBitmap) || !pBitmap
            return false
        DllCall("gdiplus\GdipCreateHBITMAPFromBitmap",
            "UPtr", pBitmap, "UPtr*", &hBitmap, "UInt", 0xFFFFFFFF)
        if !hBitmap
            return false

        bm := Buffer(32, 0)
        DllCall("GetObject", "Ptr", hBitmap, "Int", bm.Size, "Ptr", bm)
        w := NumGet(bm, 4, "Int"), h := NumGet(bm, 8, "Int")
        if w < 1 || h < 1
            return false
        stride := ((w * 32 + 31) // 32) * 4
        dibSize := 40 + stride * h
        hDib := DllCall("GlobalAlloc", "UInt", 0x0002, "UPtr", dibSize, "Ptr")
        if !hDib
            return false
        pDib := DllCall("GlobalLock", "Ptr", hDib, "Ptr")
        DllCall("RtlZeroMemory", "Ptr", pDib, "UPtr", dibSize)
        NumPut("UInt", 40, pDib, 0)
        NumPut("Int", w, pDib, 4)
        NumPut("Int", h, pDib, 8)
        NumPut("UShort", 1, pDib, 12)
        NumPut("UShort", 32, pDib, 14)
        NumPut("UInt", 0, pDib, 16)
        hdc := DllCall("GetDC", "Ptr", 0, "Ptr")
        DllCall("GetDIBits", "Ptr", hdc, "Ptr", hBitmap, "UInt", 0, "UInt", h,
            "Ptr", pDib + 40, "Ptr", pDib, "UInt", 0)
        DllCall("ReleaseDC", "Ptr", 0, "Ptr", hdc)
        DllCall("GlobalUnlock", "Ptr", hDib)

        opened := false
        loop 10 {
            if DllCall("OpenClipboard", "Ptr", 0) {
                opened := true
                break
            }
            Sleep 10
        }
        if !opened
            return false
        DllCall("EmptyClipboard")

        if IsObject(pngBuf) && pngBuf.Size {
            cfPng := DllCall("RegisterClipboardFormat", "Str", "PNG", "UInt")
            hPng := DllCall("GlobalAlloc", "UInt", 0x0002, "UPtr", pngBuf.Size, "Ptr")
            if hPng {
                pPng := DllCall("GlobalLock", "Ptr", hPng, "Ptr")
                DllCall("RtlMoveMemory", "Ptr", pPng, "Ptr", pngBuf, "UPtr", pngBuf.Size)
                DllCall("GlobalUnlock", "Ptr", hPng)
                DllCall("SetClipboardData", "UInt", cfPng, "Ptr", hPng)
            }
        }

        DllCall("SetClipboardData", "UInt", 8, "Ptr", hDib)
        DllCall("CloseClipboard")
        ok := true
    } finally {
        if hBitmap
            try DllCall("DeleteObject", "Ptr", hBitmap)
        if pBitmap
            try DllCall("gdiplus\GdipDisposeImage", "UPtr", pBitmap)
        if pToken
            try DllCall("gdiplus\GdiplusShutdown", "UPtr", pToken)
    }
    return ok
}

; Positioning strategy (align with Win10 clipboard / Raymond Chen):
; 1) GetGUIThreadInfo + GUI_CARETBLINKING
; 2) IAccessible OBJID_CARET on hwndFocus (Chrome / WeChat custom caret)
; 3) UIA TextPattern caret
; 4) IME char position
; 5) Focus-window anchor (near typing UI) — not always screen bottom-right
; OneNote: NEVER probe — bottom-right only
global cachedCaretX := 0
global cachedCaretY := 0
global cachedCaretTick := 0
global pendingCaretHwnd := 0

IsCustomCaretApp(*) {
    try {
        if IsJetBrainsApp()
            return true
        pn := StrLower(WinGetProcessName("A"))
        if pn ~= "i)^(chrome|msedge|msedgewebview2|brave|firefox|opera|vivaldi)\.exe$"
            return true
        if pn ~= "i)^(wechat|weixin|wechatappex|wechatbrowser)\.exe$"
            return true
        if pn ~= "i)^(electron|code|discord|slack|teams|notion|figma)\.exe$"
            return true
        if pn ~= "i)webview2|cursor\.exe"
            return true
    }
    return false
}

; GoLand / IntelliJ 等：自绘光标，无 GUI_CARETBLINKING
IsJetBrainsApp(*) {
    try {
        pn := StrLower(WinGetProcessName("A"))
        if pn ~= "i)goland|idea|webstorm|pycharm|phpstorm|clion|rider|datagrip|rubymine|studio64|jetbrains"
            return true
        cls := WinGetClass("A")
        if cls ~= "i)SunAwt"
            return true
    }
    return false
}

CaretRectLooksValid(left, top, right, bottom) {
    w := right - left
    h := bottom - top
    if w < 0 || h < 0
        return false
    ; 假光标：原点零尺寸 / 明显越界
    if left = 0 && top = 0 && right <= 2 && bottom <= 2
        return false
    if left < -200 || top < -200
        return false
    if left > A_ScreenWidth + 200 || top > A_ScreenHeight + 200
        return false
    return true
}

; MSAA caret on focus hwnd — Acc 返回的已是屏幕坐标（勿再 ScreenToClient）
GetCaretPosFromMSAAFocus(&left, &top, &right, &bottom) {
    left := 0, top := 0, right := 0, bottom := 0
    gi := Buffer(A_PtrSize = 8 ? 72 : 48, 0)
    NumPut("UInt", gi.Size, gi, 0)
    if !DllCall("GetGUIThreadInfo", "UInt", 0, "Ptr", gi)
        return false
    hwndFocus := NumGet(gi, A_PtrSize = 8 ? 16 : 12, "Ptr")
    hwndActive := NumGet(gi, A_PtrSize = 8 ? 8 : 8, "Ptr")
    candidates := []
    if hwndFocus
        candidates.Push(hwndFocus)
    if hwndActive && hwndActive != hwndFocus
        candidates.Push(hwndActive)
    ; Chrome/Edge：光标常在深层 RenderWidget
    for base in [hwndFocus, hwndActive] {
        if !base
            continue
        CollectChromeRenderHwnds(base, candidates)
    }
    if !DllCall("LoadLibraryW", "Str", "oleacc.dll", "Ptr")
        return false
    static IID_IAccessible := Buffer(16, 0)
    static iidReady := false
    if !iidReady {
        DllCall("ole32\CLSIDFromString", "WStr", "{618736E0-3C3D-11CF-810C-00AA00389B71}", "Ptr", IID_IAccessible)
        iidReady := true
    }
    for hwndTry in candidates {
        if !hwndTry
            continue
        if TryMSAACaretOnHwnd(hwndTry, IID_IAccessible, &left, &top, &right, &bottom)
            return true
    }
    return false
}

CollectChromeRenderHwnds(root, arr) {
    if !root
        return
    queue := [root]
    seen := Map()
    while queue.Length {
        cur := queue.RemoveAt(1)
        if seen.Has(cur)
            continue
        seen[cur] := true
        child := 0
        loop 64 {
            child := DllCall("FindWindowExW", "Ptr", cur, "Ptr", child, "Ptr", 0, "Ptr", 0, "Ptr")
            if !child
                break
            try {
                cls := WinGetClass("ahk_id " child)
                if cls = "Chrome_RenderWidgetHostHWND"
                    arr.Push(child)
            }
            queue.Push(child)
            if queue.Length > 80
                break
        }
        if queue.Length > 80
            break
    }
}

TryMSAACaretOnHwnd(hwnd, IID_IAccessible, &left, &top, &right, &bottom) {
    acc := 0
    if DllCall("oleacc\AccessibleObjectFromWindow", "Ptr", hwnd, "UInt", 0xFFFFFFF8
        , "Ptr", IID_IAccessible, "Ptr*", &acc, "Int")
        return false
    if !acc
        return false
    try {
        x := 0, y := 0, w := 0, h := 0
        if A_PtrSize = 8 {
            varChild := Buffer(24, 0)
            NumPut("UShort", 3, varChild) ; VT_I4 CHILDID_SELF
            hr := ComCall(22, acc, "Int*", &x, "Int*", &y, "Int*", &w, "Int*", &h, "Ptr", varChild, "Int")
        } else {
            hr := ComCall(22, acc, "Int*", &x, "Int*", &y, "Int*", &w, "Int*", &h, "Int64", 3, "Int64", 0, "Int")
        }
        if hr
            return false
        if w < 1 && h < 1 {
            w := Max(w, 1)
            h := Max(h, 16)
        }
        left := x
        top := y
        right := x + w
        bottom := y + h
        return CaretRectLooksValid(left, top, right, bottom)
    } catch {
        return false
    }
}

; 桌面 / 任务栏：没有可编辑光标，面板应落在工作区右下角（对齐 Win10 Win+V）
IsDesktopOrShellSurface(*) {
    try {
        cls := WinGetClass("A")
        if cls ~= "i)^(Progman|WorkerW|Shell_TrayWnd|Shell_SecondaryTrayWnd|NotifyIconOverflowWindow)$"
            return true
        gi := Buffer(A_PtrSize = 8 ? 72 : 48, 0)
        NumPut("UInt", gi.Size, gi, 0)
        if DllCall("GetGUIThreadInfo", "UInt", 0, "Ptr", gi) {
            hwndFocus := NumGet(gi, A_PtrSize = 8 ? 16 : 12, "Ptr")
            if hwndFocus {
                fcls := WinGetClass("ahk_id " hwndFocus)
                if fcls ~= "i)^(SysListView32|SHELLDLL_DefView)$" {
                    root := DllCall("GetAncestor", "Ptr", hwndFocus, "UInt", 2, "Ptr") ; GA_ROOT
                    if root {
                        rcls := WinGetClass("ahk_id " root)
                        if rcls ~= "i)^(Progman|WorkerW)$"
                            return true
                    }
                }
            }
        }
    }
    return false
}

; 当前是否处于「可打字」编辑态（有系统光标 / 标准编辑框焦点）
HasEditableCaretContext(*) {
    if IsDesktopOrShellSurface()
        return false
    ; JetBrains / 浏览器等自绘光标：编辑器里也没有 GUI_CARETBLINKING
    if IsJetBrainsApp() || IsCustomCaretApp()
        return true
    x64 := A_PtrSize == 8
    gi := Buffer(x64 ? 72 : 48, 0)
    NumPut("UInt", gi.Size, gi)
    if !DllCall("GetGUIThreadInfo", "UInt", 0, "Ptr", gi)
        return false
    flags := NumGet(gi, 4, "UInt")
    ; GUI_CARETBLINKING：真·系统插入符
    if (flags & 0x1)
        return true
    hwndFocus := NumGet(gi, x64 ? 16 : 12, "Ptr")
    if !hwndFocus
        return false
    try {
        fcls := WinGetClass("ahk_id " hwndFocus)
        ; 经典编辑框 / 重命名框等
        if fcls ~= "i)^(Edit|RichEdit20[AW]|RichEdit50W|RICHEDIT60W|Scintilla|TxutEdit)$"
            return true
        if fcls ~= "i)Chrome_RenderWidgetHostHWND|Chrome_WidgetWin|SunAwt"
            return true
    }
    return false
}

; 找不到光标时：不再贴焦点窗口（桌面/浏览网页时会飘到奇怪位置）→ 交给 ShowPanel 右下角
GetFocusWindowAnchor(&cx, &cy) {
    cx := 0, cy := 0
    return false
}

GetCaretScreenPos(&cx, &cy, &found := false, forceFresh := false) {
    cx := 0, cy := 0, found := false
    left := 0, top := 0, right := 0, bottom := 0

    if IsOneNoteApp()
        return

    ; 桌面 / 无编辑态：直接右下角，不采假光标、不贴窗口
    if IsDesktopOrShellSurface() || !HasEditableCaretContext() {
        return
    }

    if !forceFresh && GetCachedCaretPos(&x, &y) {
        cx := x, cy := y, found := true
        return
    }

    custom := IsCustomCaretApp()
    jb := IsJetBrainsApp()
    useHook := false
    try {
        pn := WinGetProcessName("A")
        if pn ~= "i)goland|idea|webstorm|pycharm|phpstorm|clion|rider|datagrip|rubymine"
            useHook := true
    }
    if jb
        useHook := true

    ; JetBrains：Hook/UIA 优先（AWT 的 Gui 光标经常偏/假）
    ; 浏览器/微信：MSAA → UIA
    ; 其它：Gui → MSAA → UIA → IME
    if jb
        tryOrder := ["uia", "msaa", "ime"]
    else if custom
        tryOrder := ["msaa", "uia", "gui", "ime"]
    else
        tryOrder := ["gui", "msaa", "uia", "ime"]

    for step in tryOrder {
        ok := false
        if step = "gui" {
            ok := GetCaretPosFromGuiThread(&left, &top, &right, &bottom)
        } else if step = "msaa" {
            ok := GetCaretPosFromMSAAFocus(&left, &top, &right, &bottom)
        } else if step = "uia" {
            ; skipGui=true：只跑 UIA/MSAA/Hook；JetBrains 在 GetCaretPosEx 内优先 Hook
            ok := GetCaretPosEx(&left, &top, &right, &bottom, useHook, false, true)
        } else if step = "ime" {
            if GetCaretPosIME(&x, &y) {
                left := x, top := y - 18, right := x + 1, bottom := y
                ok := true
            }
        }
        if ok && CaretRectLooksValid(left, top, right, bottom) {
            cx := left
            cy := bottom > top ? bottom : top + 18
            found := true
            CacheCaretPos(cx, cy)
            return
        }
    }
    ; 探测失败 → found=false → ShowPanel 工作区右下角
}

IsOneNoteApp() {
    try {
        pn := WinGetProcessName("A")
        if pn ~= "i)^(ONENOTE|ONENOTEM|ONENOTEIM)\.EXE$"
            return true
        title := WinGetTitle("A")
        if pn ~= "i)^ApplicationFrameHost\.EXE$" && InStr(title, "OneNote")
            return true
        ; Title fallback (new OneNote / Store builds with odd process names)
        if InStr(title, "OneNote")
            return true
        cls := WinGetClass("A")
        if InStr(cls, "OneNote")
            return true
    }
    return false
}

CacheCaretPos(x, y) {
    global cachedCaretX, cachedCaretY, cachedCaretTick
    cachedCaretX := x
    cachedCaretY := y
    cachedCaretTick := A_TickCount
}

GetCachedCaretPos(&cx, &cy) {
    global cachedCaretX, cachedCaretY, cachedCaretTick
    cx := 0, cy := 0
    if !cachedCaretTick
        return false
    ; 浏览器/微信光标常变：缓存更短，避免「开在上一次位置」
    maxAge := IsOneNoteApp() ? 4000 : (IsCustomCaretApp() ? 600 : 1500)
    if (A_TickCount - cachedCaretTick) > maxAge
        return false
    if cachedCaretX = 0 && cachedCaretY = 0
        return false
    cx := cachedCaretX
    cy := cachedCaretY
    return true
}

; Background caret tracker disabled —LOCATIONCHANGE while scrolling made hosts
; auto-scroll an extra notch after the wheel stopped.
StartCaretWatcher() {
}
StopCaretWatcher() {
}

; Same as GetCaretPosEx getCaretPosFromGui —no COM
GetCaretPosFromGuiThread(&left, &top, &right, &bottom) {
    left := 0, top := 0, right := 0, bottom := 0
    x64 := A_PtrSize == 8
    guiThreadInfo := Buffer(x64 ? 72 : 48)
    NumPut("UInt", guiThreadInfo.Size, guiThreadInfo)
    if !DllCall("GetGUIThreadInfo", "UInt", 0, "Ptr", guiThreadInfo)
        return false
    flags := NumGet(guiThreadInfo, 4, "UInt")
    ; GUI_CARETBLINKING=0x1：没有真系统光标时别信 rcCaret（浏览器常给空/假矩形）
    if !(flags & 0x1) && !IsCustomCaretApp() {
        ; 非自定义光标应用也可试一下 hwndCaret；无 blinking 仍可能有效
    }
    hwndCaret := NumGet(guiThreadInfo, x64 ? 48 : 28, "Ptr")
    if !hwndCaret
        return false
    left := NumGet(guiThreadInfo, x64 ? 56 : 32, "Int")
    top := NumGet(guiThreadInfo, x64 ? 60 : 36, "Int")
    right := NumGet(guiThreadInfo, x64 ? 64 : 40, "Int")
    bottom := NumGet(guiThreadInfo, x64 ? 68 : 44, "Int")
    if (right - left) < 1 && (bottom - top) < 1
        return false
    ; 自定义光标应用：无 blinking 时 Gui 矩形经常是错的
    if IsCustomCaretApp() && !(flags & 0x1)
        return false
    pt := Buffer(8, 0)
    NumPut("Int", left, pt, 0)
    NumPut("Int", bottom, pt, 4)
    DllCall("ClientToScreen", "Ptr", hwndCaret, "Ptr", pt)
    left := NumGet(pt, 0, "Int")
    bottom := NumGet(pt, 4, "Int")
    top := bottom - Max(bottom - top, 1)
    right := left + 1
    return CaretRectLooksValid(left, top, right, bottom)
}

GetCaretPosIME(&cx, &cy) {
    cx := 0, cy := 0
    gi := Buffer(A_PtrSize = 8 ? 72 : 48, 0)
    NumPut("UInt", gi.Size, gi, 0)
    if !DllCall("GetGUIThreadInfo", "UInt", 0, "Ptr", gi)
        return false
    hwndFocus := NumGet(gi, A_PtrSize = 8 ? 16 : 12, "Ptr")
    if !hwndFocus
        return false
    ; IMECHARPOSITION: dwSize, dwCharPos, POINT pt, UINT cLineHeight, RECT rcDocument
    buf := Buffer(4 + 4 + 8 + 4 + 16, 0)
    NumPut("UInt", buf.Size, buf, 0)
    NumPut("UInt", 0, buf, 4)  ; first char / caret
    ; WM_IME_REQUEST=0x0288, IMR_QUERYCHARPOSITION=6  — never block forever
    ; SMTO_ABORTIFHUNG=0x0002
    result := 0
    ok := DllCall("SendMessageTimeoutW", "Ptr", hwndFocus, "UInt", 0x0288, "Ptr", 6, "Ptr", buf.Ptr
        , "UInt", 0x0002, "UInt", 80, "UPtr*", &result)
    if !ok || !result
        return false
    x := NumGet(buf, 8, "Int")
    y := NumGet(buf, 12, "Int")
    lineH := NumGet(buf, 16, "UInt")
    if x = 0 && y = 0
        return false
    cx := x
    cy := y + (lineH > 0 ? lineH : 18)
    return true
}

ApplyRoundedCorners(hwnd, w, h, r := 10) {
    ; 不用 CreateRoundRectRgn/SetWindowRgn：GDI 区域圆角无抗锯齿，锯齿很重
    ; 清掉旧 region，交给 Win11 DWM 圆角（系统抗锯齿）
    try DllCall("SetWindowRgn", "Ptr", hwnd, "Ptr", 0, "Int", true)
    ; DWMWA_WINDOW_CORNER_PREFERENCE=33, DWMWCP_ROUND=2
    try DllCall("dwmapi\DwmSetWindowAttribute",
        "Ptr", hwnd, "UInt", 33, "Int*", 2, "UInt", 4)
    ApplyFaintGrayBorder(hwnd)
}

; Win11 无边框窗：用 DWM 淡灰描边盖满圆角（CSS inset 盖不全拐角）
; COLORREF = 0x00BBGGRR
ApplyFaintGrayBorder(hwnd) {
    if !hwnd
        return
    gray := 0x00C9C5C0  ; ~#c0c5c9 淡灰
    ; DWMWA_BORDER_COLOR = 34
    try DllCall("dwmapi\DwmSetWindowAttribute",
        "Ptr", hwnd, "UInt", 34, "UInt*", gray, "UInt", 4)
    ; DWMWA_VISIBLE_FRAME_BORDER_THICKNESS = 37 → 1（勿置 0，否则看不见线）
    try DllCall("dwmapi\DwmSetWindowAttribute",
        "Ptr", hwnd, "UInt", 37, "UInt*", 1, "UInt", 4)
}

; 兼容旧名
ClearWindowBorder(hwnd) {
    ApplyFaintGrayBorder(hwnd)
}

EnableDwmShadow(hwnd) {
    try DllCall("dwmapi\DwmSetWindowAttribute",
        "Ptr", hwnd, "UInt", 2, "Int*", 2, "UInt", 4)
    try {
        m := Buffer(16, 0)
        NumPut("Int", 1, m, 0)
        DllCall("dwmapi\DwmExtendFrameIntoClientArea", "Ptr", hwnd, "Ptr", m)
    }
    try DllCall("dwmapi\DwmSetWindowAttribute",
        "Ptr", hwnd, "UInt", 33, "Int*", 2, "UInt", 4)
    ApplyFaintGrayBorder(hwnd)
}

HidePanel(*) {
    global guiWin, wvCore, panelVisible, hasCaretPos, searchFocused, dismissSearchUntil
    QQStopSearch()
    panelVisible := false
    hasCaretPos := false
    searchFocused := false
    dismissSearchUntil := 0
    SetTimer(KeepSearchDismissed, 0)
    if IsObject(wvCore) {
        try wvCore.ExecuteScriptAsync("window.__hideCtx&&window.__hideCtx()")
    }
    if IsObject(guiWin) {
        try guiWin.Opt("+E0x08000000")
        guiWin.Hide()
    }
}

; ?? 搜索无命中：只藏窗口，不结束镜像输入
SoftHidePanel(*) {
    global guiWin, panelVisible, wvCore
    panelVisible := false
    if IsObject(wvCore)
        try wvCore.ExecuteScriptAsync("window.__hideCtx&&window.__hideCtx()")
    if IsObject(guiWin)
        try guiWin.Hide()
}

; ?? 搜索又有命中：显示已建好的面板，不重置查询
SoftShowPanel(*) {
    global guiWin, wv, panelVisible, prevActiveWin, uiPinned, qqPanelPlaced
    ; 首次弹出必须走 ShowPanel 定位到光标；之后 SoftHide/Show 只切换可见性
    if !IsObject(guiWin) || !qqPanelPlaced {
        ShowPanel()
        qqPanelPlaced := true
        QQPushQuery()
        return
    }
    wasVis := panelVisible
    try guiWin.Opt("+AlwaysOnTop")
    if uiPinned {
        try guiWin.Opt("-E0x08000000")
    } else {
        try guiWin.Opt("+E0x08000000")
    }
    guiWin.Show("NA")
    panelVisible := true
    RaiseClipboardPanel()
    if IsObject(wv) {
        try {
            wv.IsVisible := true
            ; 已显示时不要 Fill/重排：会白闪；仅首次从隐藏恢复时刷新
            if !wasVis {
                wv.Fill()
                wv.NotifyParentWindowPositionChanged()
            }
        }
    }
    RestorePrevFocusQuietly()
    QQPushQuery()
    ; 不要再 PushClips：SetView 刚推过，重复推会整表重绘闪一下
}

; ?? 模式：无关键字 / 无命中都不显示；有命中才弹出
; ?? 模式：无关键字时隐藏；有命中才弹出；已显示时切 tab 即使 0 条也保留（避免「卡一下就消失」）
QQSyncPanelVisibility(*) {
    global qqSearchOn, viewQuery, clips, viewTotal, panelVisible
    if !qqSearchOn
        return
    q := Trim(String(viewQuery))
    if q = "" {
        if panelVisible
            SoftHidePanel()
        return
    }
    n := 0
    try n := clips.Length
    tot := Integer(viewTotal)
    if (n < 1 && tot < 1) {
        ; 未弹出：继续藏着等有命中；已弹出：显示空状态，不关窗
        return
    }
    if !panelVisible
        SoftShowPanel()
}

TogglePin(flag := "") {
    global guiWin, uiPinned, panelVisible
    if (flag = "" || !IsSet(flag)) {
        uiPinned := !uiPinned
    } else {
        s := String(flag)
        uiPinned := (s = "1" || s = "true" || s = "True")
    }
    if IsObject(guiWin) {
        if panelVisible
            guiWin.Opt("+AlwaysOnTop")
        else
            guiWin.Opt(uiPinned ? "+AlwaysOnTop" : "-AlwaysOnTop")
        ; Pinned: drop NOACTIVATE so Ctrl+F / keys work without clicking first
        if uiPinned {
            try guiWin.Opt("-E0x08000000")
        } else if panelVisible {
            try guiWin.Opt("+E0x08000000")
        }
    }
    PushPinStateToUi()
}

PushPinStateToUi() {
    global wvCore, uiPinned
    if !IsObject(wvCore)
        return
    try wvCore.ExecuteScriptAsync("window.__setPinned && window.__setPinned(" (uiPinned ? "true" : "false") ")")
}

CalcUiSize(&outW, &outH) {
    global UI_W, UI_H
    scale := A_ScreenHeight / 1080.0
    if scale < 0.75
        scale := 0.75
    if scale > 1.35
        scale := 1.35
    outW := Round(UI_W * scale)
    outH := Round(UI_H * scale)
}

OnGuiSize(*) {
    global wv
    if IsObject(wv)
        try wv.Fill()
}

PushClips(append := false) {
    global wvCore, clips, viewTotal, viewQuery, viewTab, viewToday, viewApplying
        , diskScanBusy, clipReady
    if !IsObject(wvCore)
        return
    t0 := A_TickCount
    q := String(viewQuery)
    ; 扫盘中途可能 Sleep 让出：此时 viewQuery 已新、clips 仍旧 → 绝不推「伪过滤」列表
    if viewApplying && Trim(q) != ""
        return
    sendList := clips
    sendTotal := Integer(viewTotal)
    ; Boot/warm race: empty push used to flash「暂无记录」— keep UI on skeleton instead of silent SKIP (blank white)
    if !append && (!IsObject(sendList) || sendList.Length = 0) && sendTotal <= 0 && Trim(q) = "" {
        if viewTab != "recent" && (diskScanBusy || !clipReady) {
            ClipLog("PushClips KEEP skel while warm/boot")
            try wvCore.ExecuteScriptAsync("window.setBootLoading&&window.setBootLoading(true);window.__waitingView=true;")
            return
        }
    }
    filtered := Trim(q) != ""
    if filtered {
        ; SetView / QueryDiskPage 已过滤+展开合并组，勿再扫盘
        sendList := clips
        if !append
            sendTotal := clips.Length
        else
            sendTotal := Max(Integer(viewTotal), clips.Length)
    }
    tJson0 := A_TickCount
    payload := "{"
    payload .= '"append":' (append ? "true" : "false") ","
    payload .= '"tab":' JsonStr(String(viewTab)) ","
    payload .= '"total":' sendTotal ","
    payload .= '"pinnedTotal":' Integer(PinnedTotalForUi()) ","
    payload .= '"query":' JsonStr(q) ","
    payload .= '"filtered":' (filtered ? "true" : "false") ","
    payload .= '"items":' ClipsListToJson(sendList, append)
    payload .= "}"
    jsonMs := A_TickCount - tJson0
    try wvCore.ExecuteScriptAsync("window.__updateClips && window.__updateClips(" payload ");window.__loadMoreDone&&window.__loadMoreDone();window.__perfMark&&window.__perfMark('js_updateClips_called')")
    PerfMark("PushClips done n=" (IsObject(sendList) ? sendList.Length : 0) " jsonMs=" jsonMs " totalMs=" (A_TickCount - t0) " payloadKB=" Round(StrLen(payload) / 1024, 1))
    ; Defer thumbs so first paint is not blocked
    SetTimer(ScheduleStoreThumbs.Bind(append), -400)
}

; Badge on 收藏 tab —prefer pinned viewCache total, else count current window
PinnedTotalForUi(*) {
    global viewCache, viewToday, viewTab, viewTotal, clips
    try {
        key := ViewCacheKey("pinned", "", viewToday)
        if viewCache.Has(key) {
            t := Integer(viewCache[key].total)
            if t > 0
                return t
        }
    }
    if viewTab = "pinned" {
        n := 0
        try n := clips.Length
        return Max(Integer(viewTotal), n)
    }
    n := 0
    if IsObject(clips) {
        for c in clips {
            if IsObject(c) && c.HasProp("pinned") && c.pinned
                n += 1
        }
    }
    return n
}

; Coalesce UI refreshes —safe to call from OnClipboardChange / disk jobs
RequestUiPush(*) {
    global uiPushPending, uiPushTimerArmed
    uiPushPending := true
    if uiPushTimerArmed
        return
    uiPushTimerArmed := true
    ; Leave clipboard / Critical context before talking to WebView
    SetTimer(FlushUiPush, -30)
}

FlushUiPush(*) {
    global uiPushPending, uiPushTimerArmed, wvCore, panelVisible, clips, viewApplying, viewQuery
    uiPushTimerArmed := false
    if !uiPushPending
        return
    uiPushPending := false
    if !IsObject(wvCore)
        return
    ; 面板隐藏时不往 WebView 推 JSON（仍吃 CPU）；下次 ShowPanel 会 RequestUiPush
    if !panelVisible
        return
    ; 搜索扫盘中途勿推旧列表
    if viewApplying && Trim(String(viewQuery)) != "" {
        uiPushPending := true
        uiPushTimerArmed := true
        SetTimer(FlushUiPush, -80)
        return
    }
    n := 0
    try n := clips.Length
    ClipLog("FlushUiPush panel=" panelVisible " clips=" n)
    PushClips(false)
}

; Queue list thumbs without blocking SetView / tab switch
ScheduleStoreThumbs(append := false) {
    global clips, wvCore, lastAppendCount, thumbPushGen, thumbPushQueue, thumbPushArmed
        , thumbPushedUids, clipReady, STORE_DIR, panelVisible, listThumbUrlCache
    if !IsObject(wvCore) || !panelVisible
        return
    if !clipReady {
        SetTimer(ScheduleStoreThumbs.Bind(append), -200)
        return
    }
    start := 1
    if append && lastAppendCount > 0
        start := Max(1, clips.Length - lastAppendCount + 1)
    else if !append {
        ; Full refresh: allow re-inject (DOM was rebuilt); keep memory URL cache
        thumbPushedUids := Map()
    }
    q := []
    i := start
    while i <= clips.Length {
        c := clips[i]
        i += 1
        if !IsObject(c)
            continue
        ; 历史条目：图片文件没写入 imgFile 时补拷一份，否则永远占位
        if c.type = "file" && (!c.HasProp("imgFile") || c.imgFile = "") && FileClipLooksLikeImage(c) {
            try EnsureFileClipThumb(c)
            catch {
            }
            if c.HasProp("imgFile") && c.imgFile != ""
                ApplyImgFileLocal(c.uid, c.imgFile)
        }
        if !c.HasProp("imgFile") || c.imgFile = ""
            continue
        if c.type != "image" && c.type != "file"
            continue
        uid := Integer(c.uid)
        if thumbPushedUids.Has(uid)
            continue
        ; Never inject bare virtual-host URLs here: under SaveImage/Prune disk load
        ; WebView2 mapping often 404s, and __setThumb would poison thumbCache for the whole list.
        ; Prefer in-memory data-URL cache; otherwise queue for ProcessThumbPushQueue.
        name := String(c.imgFile)
        if IsObject(listThumbUrlCache) && listThumbUrlCache.Has(name) {
            ent := listThumbUrlCache[name]
            if IsObject(ent) && ent.HasProp("url") && ent.url != "" {
                try wvCore.ExecuteScriptAsync("window.__setThumb&&window.__setThumb(" uid "," JsonStr(ent.url) ")")
                thumbPushedUids[uid] := true
                continue
            }
        }
        q.Push({ uid: uid, imgFile: name })
    }
    thumbPushGen += 1
    thumbPushQueue := q
    if !thumbPushArmed && q.Length {
        thumbPushArmed := true
        SetTimer(ProcessThumbPushQueue, -20)
    } else if !q.Length {
        thumbPushArmed := false
        SetTimer(ProcessThumbPushQueue, 0)
    }
}

ProcessThumbPushQueue(*) {
    global wvCore, STORE_DIR, APP_HOST, thumbPushGen, thumbPushQueue, thumbPushArmed, thumbPushedUids
    thumbPushArmed := false
    if !IsObject(wvCore) || !thumbPushQueue.Length
        return
    myGen := thumbPushGen
    ; At most 3 host-URL injects / 1 GDI+ encode per tick
    ; At most 2 host-URL injects / 1 GDI+ encode per tick (keep scroll fluid)
    budget := 2
    madeJpeg := false
    while budget > 0 && thumbPushQueue.Length {
        if myGen != thumbPushGen
            return
        job := thumbPushQueue.RemoveAt(1)
        uid := Integer(job.uid)
        if thumbPushedUids.Has(uid)
            continue
        name := String(job.imgFile)
        allowMake := !madeJpeg
        url := ""
        didMake := false
        ; Prefer FileRead→data-URL (listThumbUrlCache). Virtual-host URLs flake when
        ; clips_store is busy after screenshot persist / prune — that blanked the whole image tab.
        try url := ListThumbDataUrl(name, allowMake, &didMake)
        catch as e {
            ClipLog("ProcessThumbPushQueue dataUrl fail " name " " e.Message)
        }
        if didMake
            madeJpeg := true
        if url = "" && allowMake {
            try {
                if EnsureListThumbFile(name) != "" {
                    madeJpeg := true
                    didMake := false
                    try url := ListThumbDataUrl(name, false, &didMake)
                    catch {
                    }
                }
            } catch as e {
                ClipLog("ProcessThumbPushQueue Ensure fail " name " " e.Message)
            }
        }
        if url = "" && !allowMake {
            ; Encode budget used —put back and leave this tick (don't spin the queue)
            try {
                if FileExist(STORE_DIR "\" name)
                    thumbPushQueue.InsertAt(1, job)
            }
            break
        }
        if url = "" {
            ; Last resort only — may still fail under disk load
            cacheName := ListThumbCacheName(name)
            if cacheName != "" && FileExist(STORE_DIR "\" cacheName)
                url := ListThumbHostUrl(cacheName)
        }
        if url = ""
            continue
        try wvCore.ExecuteScriptAsync("window.__setThumb&&window.__setThumb(" uid "," JsonStr(url) ")")
        thumbPushedUids[uid] := true
        budget -= 1
    }
    if myGen != thumbPushGen
        return
    if thumbPushQueue.Length {
        thumbPushArmed := true
        SetTimer(ProcessThumbPushQueue, madeJpeg ? -70 : -28)
    }
}

; Prefer short virtual-host URL —no FileRead / base64 on hot path
ListThumbHostUrl(cacheName) {
    global APP_HOST
    cacheName := String(cacheName)
    if cacheName = ""
        return ""
    ; encodeURIComponent-ish for uncommon chars (img_/th_ names are usually safe)
    safe := StrReplace(cacheName, " ", "%20")
    return "https://" APP_HOST "/clips_store/" safe
}

; Just-copied image: list JSON strips data → inject a small JPEG data-URL into WV2 ASAP
InjectLiveImageThumb(uid) {
    global clips, liveFront, wvCore, thumbPushedUids, panelVisible
    uid := Integer(uid)
    if uid < 1 || !IsObject(wvCore)
        return
    item := ""
    for c in clips {
        if IsObject(c) && c.uid = uid {
            item := c
            break
        }
    }
    if !IsObject(item) && IsObject(liveFront) {
        for c in liveFront {
            if IsObject(c) && c.uid = uid {
                item := c
                break
            }
        }
    }
    if !IsObject(item) || item.type != "image"
        return
    if item.HasProp("imgFile") && item.imgFile != "" {
        InjectStoreThumbNow(uid, item.imgFile)
        return
    }
    if !(item.HasProp("data") && InStr(item.data, "base64,"))
        return
    url := ""
    try url := MemoryDataUrlToListThumbUrl(item.data)
    catch as e {
        ClipLog("InjectLiveImageThumb fail uid=" uid " " e.Message)
        return
    }
    if url = ""
        return
    try wvCore.ExecuteScriptAsync("window.__setThumb&&window.__setThumb(" uid "," JsonStr(url) ")")
    thumbPushedUids[uid] := true
    ClipLog("InjectLiveImageThumb ok uid=" uid " len=" StrLen(url))
}

; After imgFile lands on disk: ensure th_ + inject (prefer data-URL —virtual host is flaky)
InjectStoreThumbNow(uid, imgFile) {
    global wvCore, STORE_DIR, thumbPushedUids
    uid := Integer(uid)
    imgFile := String(imgFile)
    if uid < 1 || imgFile = "" || !IsObject(wvCore)
        return
    cacheName := ""
    try cacheName := EnsureListThumbFile(imgFile)
    catch as e {
        ClipLog("InjectStoreThumbNow Ensure fail " imgFile " " e.Message)
    }
    url := ""
    if cacheName != "" {
        didMake := false
        try url := ListThumbDataUrl(imgFile, false, &didMake)
        catch {
        }
        if url = ""
            url := ListThumbHostUrl(cacheName)
    }
    if url = ""
        return
    try wvCore.ExecuteScriptAsync("window.__setThumb&&window.__setThumb(" uid "," JsonStr(url) ")")
    thumbPushedUids[uid] := true
}

; Shrink in-memory clipboard PNG/data-URL to a small JPEG data-URL for list inject
MemoryDataUrlToListThumbUrl(dataUrl) {
    if !RegExMatch(String(dataUrl), "i)base64,([\s\S]+)$", &m)
        return ""
    stamp := A_TickCount "_" Random(1000, 9999)
    tmp := A_Temp "\clip_live_" stamp ".png"
    th := A_Temp "\clip_live_th_" stamp ".jpg"
    try {
        if !B64DecodeToFile(m[1], tmp)
            return ""
        if !MakeListThumbJpeg(tmp, th)
            return ""
        f := FileOpen(th, "r")
        if !IsObject(f)
            return ""
        buf := Buffer(f.Length)
        f.RawRead(buf)
        f.Close()
        if buf.Size < 32
            return ""
        return "data:image/jpeg;base64," B64Encode(buf)
    } catch {
        return ""
    } finally {
        try FileDelete tmp
        try FileDelete th
    }
}

; Small JPEG list preview (cached next to original) —keeps inject payload small
; allowMake=false →never GDI+ (used when budget already spent this tick)
ListThumbDataUrl(name, allowMake := true, &didMake := false) {
    global STORE_DIR, listThumbUrlCache
    didMake := false
    name := String(name)
    if name = ""
        return ""
    src := STORE_DIR "\" name
    if !FileExist(src)
        return ""
    mt := ""
    try mt := FileGetTime(src, "M")
    if listThumbUrlCache.Has(name) {
        ent := listThumbUrlCache[name]
        if IsObject(ent) && ent.HasProp("mt") && ent.mt = mt && ent.HasProp("url") && ent.url != ""
            return ent.url
    }
    ; Prefer existing th_*.jpg —no encode on hot path
    cacheName := ListThumbCacheName(name)
    cachePath := STORE_DIR "\" cacheName
    if FileExist(cachePath) {
        try {
            if FileGetTime(cachePath, "M") >= mt {
                u := LoadImageFromStore(cacheName)
                if u != "" {
                    CapListThumbUrlCache()
                    listThumbUrlCache[name] := { mt: mt, url: u }
                    return u
                }
            }
        } catch {
            u := LoadImageFromStore(cacheName)
            if u != "" {
                CapListThumbUrlCache()
                listThumbUrlCache[name] := { mt: mt, url: u }
                return u
            }
        }
    }
    if allowMake {
        try {
            hadCache := FileExist(cachePath)
            if EnsureListThumbFile(name) != "" {
                if !hadCache
                    didMake := true
                u := LoadImageFromStore(cacheName)
                if u != "" {
                    CapListThumbUrlCache()
                    listThumbUrlCache[name] := { mt: mt, url: u }
                    return u
                }
            }
        } catch as e {
            ClipLog("ListThumbDataUrl EnsureListThumbFile fail name=" name " err=" e.Message)
        }
    }
    ; Last resort: tiny originals only (large ExecuteScript payloads fail silently)
    try {
        if FileGetSize(src) <= 80000 {
            u := LoadImageFromStore(name)
            if u != "" {
                CapListThumbUrlCache()
                listThumbUrlCache[name] := { mt: mt, url: u }
                return u
            }
        }
    } catch {
    }
    return ""
}

CapListThumbUrlCache(*) {
    global listThumbUrlCache
    if !IsObject(listThumbUrlCache) || listThumbUrlCache.Count <= 96
        return
    ; Drop all —cheaper than LRU bookkeeping; th_ files remain on disk
    listThumbUrlCache := Map()
}

ListThumbCacheName(name) {
    base := RegExReplace(String(name), "\.[^.]+$", "")
    return "th_" base ".jpg"
}

EnsureListThumbFile(name) {
    global STORE_DIR
    src := STORE_DIR "\" name
    if !FileExist(src)
        return ""
    cacheName := ListThumbCacheName(name)
    cachePath := STORE_DIR "\" cacheName
    if FileExist(cachePath) {
        try {
            if FileGetTime(cachePath, "M") >= FileGetTime(src, "M")
                return cacheName
        } catch {
            return cacheName
        }
    }
    if MakeListThumbJpeg(src, cachePath)
        return cacheName
    return ""
}

MakeListThumbJpeg(srcPath, destPath) {
    pToken := 0, pBitmap := 0, pThumb := 0, pGfx := 0
    try {
        DllCall("LoadLibrary", "Str", "gdiplus.dll", "Ptr")
        si := Buffer(24, 0)
        NumPut("UInt", 1, si)
        if DllCall("gdiplus\GdiplusStartup", "Ptr*", &pToken, "Ptr", si, "Ptr", 0)
            return false
        if DllCall("gdiplus\GdipCreateBitmapFromFile", "WStr", srcPath, "Ptr*", &pBitmap) || !pBitmap
            return false
        DllCall("gdiplus\GdipGetImageWidth", "Ptr", pBitmap, "UInt*", &w := 0)
        DllCall("gdiplus\GdipGetImageHeight", "Ptr", pBitmap, "UInt*", &h := 0)
        if w < 1 || h < 1
            return false
        maxEdge := 420
        if (w > maxEdge || h > maxEdge) {
            sc := Min(maxEdge / w, maxEdge / h)
            nw := Max(1, Round(w * sc)), nh := Max(1, Round(h * sc))
            DllCall("gdiplus\GdipCreateBitmapFromScan0", "Int", nw, "Int", nh,
                "Int", 0, "Int", 0x26200A, "Ptr", 0, "Ptr*", &pThumb)
            if !pThumb
                return false
            DllCall("gdiplus\GdipGetImageGraphicsContext", "Ptr", pThumb, "Ptr*", &pGfx)
            if pGfx {
                DllCall("gdiplus\GdipSetInterpolationMode", "Ptr", pGfx, "Int", 7)
                DllCall("gdiplus\GdipDrawImageRectI", "Ptr", pGfx, "Ptr", pBitmap, "Int", 0, "Int", 0, "Int", nw, "Int", nh)
                DllCall("gdiplus\GdipDeleteGraphics", "Ptr", pGfx)
                pGfx := 0
            }
            DllCall("gdiplus\GdipDisposeImage", "Ptr", pBitmap)
            pBitmap := pThumb
            pThumb := 0
        }
        ; JPEG encoder
        clsid := Buffer(16)
        DllCall("ole32\CLSIDFromString", "Str", "{557CF401-1A04-11D3-9A73-0000F81EF32E}", "Ptr", clsid)
        if FileExist(destPath)
            try FileDelete destPath
        if DllCall("gdiplus\GdipSaveImageToFile", "Ptr", pBitmap, "WStr", destPath, "Ptr", clsid, "Ptr", 0)
            return false
        return FileExist(destPath) ? true : false
    } catch {
        return false
    } finally {
        if pGfx
            try DllCall("gdiplus\GdipDeleteGraphics", "Ptr", pGfx)
        if pThumb
            try DllCall("gdiplus\GdipDisposeImage", "Ptr", pThumb)
        if pBitmap
            try DllCall("gdiplus\GdipDisposeImage", "Ptr", pBitmap)
        if pToken
            try DllCall("gdiplus\GdiplusShutdown", "Ptr", pToken)
    }
}

ClipsToJson(append := false) {
    global clips
    return ClipsListToJson(clips, append)
}

ClipsListToJson(list, append := false) {
    global PAGE_SIZE, lastAppendCount
    if !IsObject(list)
        list := []
    start := 1
    if append && lastAppendCount > 0
        start := Max(1, list.Length - lastAppendCount + 1)
    out := "["
    first := true
    loop list.Length {
        i := A_Index
        if i < start
            continue
        c := list[i]
        if !first
            out .= ","
        first := false
        imgFile := c.HasProp("imgFile") ? c.imgFile : ""
        preview := c.HasProp("preview") ? String(c.preview) : ""
        ; List payload must stay small —full text body is loaded only on paste
        if c.type = "image" {
            data := ""
            preview := ""
        } else if c.type = "link" {
            data := (c.HasProp("data") && c.data != "") ? String(c.data) : preview
            if preview = ""
                preview := data
        } else if c.type = "file" {
            data := preview != "" ? preview : String(c.HasProp("data") ? c.data : "")
            if preview = ""
                preview := data
        } else if c.type = "recent" {
            data := String(c.HasProp("data") ? c.data : "")
            if data = ""
                data := preview
            if preview = ""
                preview := data
        } else if c.type = "emoji" {
            ; 列表要带上表情本身，供左侧大图标；正文是解释+拼音
            data := String(c.HasProp("data") ? c.data : "")
            if preview = "" && c.HasProp("favTitle")
                preview := String(c.favTitle)
        } else {
            data := ""
            if preview = "" && c.HasProp("data") && c.data != ""
                preview := SubStr(String(c.data), 1, 500)
        }
        uid := c.HasProp("uid") ? Integer(c.uid) : i
        ApplyQueueMetaToItem(c)
        out .= "{"
        out .= '"id":' uid ","
        out .= '"type":"' c.type '",'
        out .= '"time":"' c.time '",'
        out .= '"pinned":' (c.pinned ? "true" : "false") ","
        out .= '"pasted":' ((c.HasProp("pasted") && c.pasted) ? "true" : "false") ","
        out .= '"queueGroup":' (c.HasProp("queueGroup") ? Integer(c.queueGroup) : 0) ","
        out .= '"queueIndex":' (c.HasProp("queueIndex") ? Integer(c.queueIndex) : 0) ","
        out .= '"charCount":' (c.HasProp("charCount") ? c.charCount : 0) ","
        out .= '"fileCount":' (c.HasProp("fileCount") ? c.fileCount : 0) ","
        out .= '"width":' (c.HasProp("width") ? c.width : 0) ","
        out .= '"height":' (c.HasProp("height") ? c.height : 0) ","
        out .= '"imgFile":' JsonStr(imgFile) ","
        out .= '"linkTitle":' JsonStr(c.HasProp("linkTitle") ? c.linkTitle : "") ","
        out .= '"linkHost":' JsonStr(c.HasProp("linkHost") ? c.linkHost : "") ","
        out .= '"favTitle":' JsonStr(c.HasProp("favTitle") ? c.favTitle : "") ","
        out .= '"favGroup":' JsonStr(c.HasProp("favGroup") ? c.favGroup : "") ","
        out .= '"srcIcon":' JsonStr(c.HasProp("srcIcon") ? c.srcIcon : "") ","
        out .= '"srcExe":' JsonStr(c.HasProp("srcExe") ? c.srcExe : "") ","
        out .= '"srcTitle":' JsonStr(c.HasProp("srcTitle") ? c.srcTitle : "") ","
        out .= '"isMd":' ((c.HasProp("isMd") && c.isMd) ? "true" : "false") ","
        out .= '"isRich":' ((c.HasProp("isRich") && c.isRich) ? "true" : "false") ","
        out .= '"preview":' JsonStr(preview) ","
        out .= '"data":' JsonStr(data)
        out .= "}"
    }
    return out "]"
}

ImageDataUrlForId(uid) {
    c := ResolveClip(uid)
    if !IsObject(c)
        return ""
    if c.HasProp("imgFile") && c.imgFile != "" {
        u := ListThumbDataUrl(c.imgFile)
        if u != ""
            return u
    }
    if c.type = "image"
        return c.HasProp("data") ? String(c.data) : ""
    return ""
}

JsonStr(s) {
    s := StrReplace(s, "\", "\\")
    s := StrReplace(s, '"', '\"')
    s := StrReplace(s, "`n", "\n")
    s := StrReplace(s, "`r", "\r")
    s := StrReplace(s, "`t", "\t")
    return '"' s '"'
}

PasteItem(uid) {
    global prevActiveWin, clipIgnore, uiPinned, pasteQueueMode, qqSearchOn, qqIh
    ; Manual panel paste aborts active FIFO queue (keep original paste flow)
    if pasteQueueMode
        ExitPasteQueue("panel-paste")
    item := ResolveClip(uid)
    if !IsObject(item) {
        ClipLog("PasteItem miss uid=" uid)
        return
    }
    if StrLower(String(item.type)) = "recent" {
        path := item.HasProp("data") ? String(item.data) : String(item.preview)
        OpenFolderDir(path)
        return
    }

    eraseN := QQTypedEraseCount()
    wasQQ := qqSearchOn
    itemType := StrLower(String(item.type))
    isEmoji := (itemType = "emoji")

    ; 先停输入钩子，避免退格/粘贴被钩子吃掉；搜索态只 SoftHide，少扰动目标窗
    if IsObject(qqIh) {
        try qqIh.Stop()
        qqIh := 0
    }
    if !uiPinned {
        if wasQQ
            SoftHidePanel()
        else
            HidePanel()
    }

    clipIgnore := true
    try {
        ok := false
        if itemType = "file" {
            paths := GetItemFilePaths(item)
            if paths.Length
                ok := SetClipboardFiles(paths)
        } else if itemType = "image" {
            paths := BuildAhkNamedPastePaths([item])
            if paths.Length
                ok := SetClipboardFiles(paths)
        }

        textBody := ""
        if itemType = "text" || itemType = "link" || isEmoji {
            if isEmoji
                textBody := String(item.HasProp("data") ? item.data : "")
            else {
                EnsureClipBodyLoaded(item)
                textBody := item.HasProp("data") ? String(item.data) : ""
            }
            if textBody = "" {
                ClipLog("PasteItem empty text uid=" uid " type=" itemType)
                return
            }
            A_Clipboard := textBody
            ok := true
        } else if !ok {
            if !PutItemOnClipboard(item) {
                ClipLog("PasteItem PutClip fail uid=" uid " type=" itemType)
                return
            }
            ok := true
        }

        if !isEmoji
            MarkItemsPasted([item.uid])

        target := ResolvePasteTargetWin()
        if target
            ForceActivateHwnd(target)
        Sleep 50
        QQEraseTypedInEditor(eraseN)
        Sleep 20
        TriggerPasteKey()
        ClipLog("PasteItem ok uid=" uid " type=" itemType " erase=" eraseN " qq=" (wasQQ ? 1 : 0))
    } finally {
        if wasQQ
            QQAbortSearch()
        SetTimer(() => (clipIgnore := false), -500)
        if uiPinned
            SetTimer(RaiseClipboardPanel, -50)
    }
}

PasteMany(idsStr, sepToken := "") {
    global prevActiveWin, clipIgnore, uiPinned, pasteQueueMode, qqSearchOn, qqIh
    if pasteQueueMode
        ExitPasteQueue("panel-paste-many")
    items := []
    uids := []
    for part in StrSplit(String(idsStr), ",") {
        part := Trim(part)
        if part = ""
            continue
        it := ResolveClip(part)
        if !IsObject(it)
            continue
        items.Push(it)
        uids.Push(it.uid)
    }
    if items.Length = 0
        return
    ; 单条且无分隔符 → 普通粘贴；有分隔符（含列表包裹）则走合并，以便拆多行
    if items.Length = 1 && String(sepToken) = "" {
        PasteItem(uids[1])
        return
    }

    ; 有分隔符且全部为文本/链接 → 一次合并粘贴
    sepTok := String(sepToken)
    if sepTok != "" {
        allText := true
        for it in items {
            if !(it.type = "text" || it.type = "link" || it.type = "emoji") {
                allText := false
                break
            }
        }
        if allText {
            parts := []
            for it in items {
                if it.type = "emoji"
                    parts.Push(String(it.HasProp("data") ? it.data : ""))
                else {
                    EnsureClipBodyLoaded(it)
                    parts.Push(it.HasProp("data") ? String(it.data) : "")
                }
            }
            joined := JoinClipPartsWithSep(parts, sepTok)
            eraseN := QQTypedEraseCount()
            wasQQ := qqSearchOn
            if IsObject(qqIh) {
                try qqIh.Stop()
                qqIh := 0
            }
            if !uiPinned {
                if wasQQ
                    SoftHidePanel()
                else
                    HidePanel()
            }
            clipIgnore := true
            try {
                A_Clipboard := joined
                MarkItemsPasted(uids)
                target := ResolvePasteTargetWin()
                if target
                    ForceActivateHwnd(target)
                Sleep 50
                QQEraseTypedInEditor(eraseN)
                Sleep 20
                TriggerPasteKey()
            } finally {
                if wasQQ
                    QQAbortSearch()
                SetTimer(() => (clipIgnore := false), -500)
                if uiPinned
                    SetTimer(RaiseClipboardPanel, -50)
            }
            return
        }
    }

    paths := CollectPasteFilePaths(items)
    if paths.Length {
        eraseN := QQTypedEraseCount()
        if !uiPinned
            HidePanel()
        clipIgnore := true
        try {
            if !SetClipboardFiles(paths)
                return
            MarkItemsPasted(uids)
            target := ResolvePasteTargetWin()
            if target {
                DllCall("SetForegroundWindow", "Ptr", target)
                Sleep 30
            }
            QQEraseTypedInEditor(eraseN)
            TriggerPasteKey()
        } finally {
            SetTimer(() => (clipIgnore := false), -500)
            if uiPinned
                SetTimer(RaiseClipboardPanel, -50)
        }
        return
    }

    eraseN := QQTypedEraseCount()
    if !uiPinned
        HidePanel()
    clipIgnore := true
    pastedIds := []
    try {
        target := ResolvePasteTargetWin()
        if target {
            DllCall("SetForegroundWindow", "Ptr", target)
            Sleep 20
        }
        QQEraseTypedInEditor(eraseN)
        for i, it in items {
            if !PutItemOnClipboard(it)
                continue
            pastedIds.Push(it.uid)
            Sleep 80
            TriggerPasteKey()
            if i < items.Length
                Sleep 220
        }
        if pastedIds.Length
            MarkItemsPasted(pastedIds)
    } finally {
        SetTimer(() => (clipIgnore := false), -500)
        if uiPinned
            SetTimer(RaiseClipboardPanel, -50)
    }
}

; Gather on-disk paths for a batch of image/file clips (for one HDROP paste)
CollectPasteFilePaths(items) {
    paths := []
    if !IsObject(items) || items.Length < 1
        return paths
    imageBatch := []
    for item in items {
        if item.type = "file" {
            if imageBatch.Length {
                built := BuildAhkNamedPastePaths(imageBatch)
                if !built.Length
                    return []
                for p in built
                    paths.Push(p)
                imageBatch := []
            }
            fps := GetItemFilePaths(item)
            if !fps.Length
                return []
            for p in fps
                paths.Push(p)
        } else if item.type = "image" {
            imageBatch.Push(item)
        } else {
            return []
        }
    }
    if imageBatch.Length {
        built := BuildAhkNamedPastePaths(imageBatch)
        if !built.Length
            return []
        for p in built
            paths.Push(p)
    }
    return paths
}

; Copy clip images/files to temp as ahk_2026-07-19 00-20-31_1.png for Explorer paste names
BuildAhkNamedPastePaths(items) {
    paths := []
    if !IsObject(items) || items.Length < 1
        return paths
    stamp := FormatTime(, "yyyy-MM-dd HH-mm-ss")
    tick := A_TickCount
    idx := 0
    for item in items {
        src := GetItemFilePath(item)
        if src = ""
            return []
        dotPos := InStr(src, ".", false, -1)
        ext := dotPos > 0 ? StrLower(SubStr(src, dotPos + 1)) : "png"
        if ext = ""
            ext := "png"
        ; uid + tick + idx: never collide when called once-per-item in the same second
        uidPart := (item.HasProp("uid") && item.uid) ? Integer(item.uid) : Random(1000, 9999)
        dest := A_Temp "\ahk_" stamp "_" uidPart "_" tick "_" (++idx) "." ext
        try FileCopy src, dest, 1
        catch
            return []
        if !FileExist(dest)
            return []
        paths.Push(dest)
    }
    return paths
}

; Resolve on-disk path for image/file clip items (for HDROP multi-paste)
GetItemFilePath(item) {
    if item.type = "file" {
        paths := GetItemFilePaths(item)
        return paths.Length ? paths[1] : ""
    }
    global STORE_DIR
    if !IsObject(item)
        return ""
    if item.type = "image" {
        if item.HasProp("imgFile") && item.imgFile != "" {
            p := STORE_DIR "\" item.imgFile
            if FileExist(p)
                return p
        }
        if InStr(item.data, "base64,") {
            p := A_Temp "\clipmgr_m" A_TickCount "_" Random(1000, 9999) ".png"
            if RegExMatch(item.data, "i)base64,([\s\S]+)$", &m) && B64DecodeToFile(m[1], p)
                return p
        }
        return ""
    }
    return ""
}

; All existing paths from a file clip (files and folders)
GetItemFilePaths(item) {
    paths := []
    if !IsObject(item) || item.type != "file"
        return paths
    raw := ""
    if item.HasProp("data") && item.data != ""
        raw := String(item.data)
    else if item.HasProp("preview")
        raw := String(item.preview)
    for ln in StrSplit(raw, "`n", "`r") {
        ln := Trim(ln)
        if ln != "" && FileExist(ln)
            paths.Push(ln)
    }
    return paths
}

; "1" / "0" —simple return for WebView hostObjects (avoids JSON parse issues)
PathExistsFlag(path := "") {
    path := Trim(String(path))
    if (SubStr(path, 1, 1) = '"' && SubStr(path, -1) = '"')
        || (SubStr(path, 1, 1) = "'" && SubStr(path, -1) = "'")
        path := Trim(SubStr(path, 2, -1))
    if path = ""
        return "0"
    return FileExist(path) ? "1" : "0"
}

; JSON for UI hover tip: [{"path":"...","exists":true,"isDir":false}, ...]
CheckFilePathsJson(raw := "") {
    out := "["
    first := true
    for ln in StrSplit(String(raw), "`n", "`r") {
        ln := Trim(ln)
        if ln = ""
            continue
        ex := FileExist(ln)
        if !first
            out .= ","
        first := false
        out .= "{"
        out .= '"path":' JsonStr(ln) ","
        out .= '"exists":' (ex ? "true" : "false") ","
        out .= '"isDir":' ((ex && InStr(ex, "D")) ? "true" : "false")
        out .= "}"
    }
    return out "]"
}

; Put multiple files on clipboard as CF_HDROP (Explorer pastes them all at once)
SetClipboardFiles(paths) {
    if !IsObject(paths) || paths.Length < 1
        return false
    ; Dedupe identical paths (guards against same temp name twice → one image pasted twice)
    uniq := []
    seen := Map()
    for p in paths {
        p := String(p)
        key := StrLower(p)
        if p = "" || seen.Has(key)
            continue
        if !FileExist(p)
            return false
        seen[key] := true
        uniq.Push(p)
    }
    if uniq.Length < 1
        return false
    paths := uniq
    totalChars := 1
    for p in paths
        totalChars += StrLen(p) + 1
    offset := 20
    bufSize := offset + totalChars * 2
    hMem := DllCall("GlobalAlloc", "UInt", 0x0002, "UPtr", bufSize, "Ptr")
    if !hMem
        return false
    ptr := DllCall("GlobalLock", "Ptr", hMem, "Ptr")
    if !ptr {
        DllCall("GlobalFree", "Ptr", hMem)
        return false
    }
    DllCall("RtlZeroMemory", "Ptr", ptr, "UPtr", bufSize)
    NumPut("UInt", offset, ptr, 0)
    NumPut("Int", 0, ptr, 4)
    NumPut("Int", 0, ptr, 8)
    NumPut("UInt", 0, ptr, 12)
    NumPut("UInt", 1, ptr, 16)
    pos := offset
    for p in paths {
        StrPut(p, ptr + pos, "UTF-16")
        pos += (StrLen(p) + 1) * 2
    }
    DllCall("GlobalUnlock", "Ptr", hMem)

    ; Preferred DropEffect = COPY so Explorer pastes (not move/fail)
    hEffect := DllCall("GlobalAlloc", "UInt", 0x0002, "UPtr", 4, "Ptr")
    if hEffect {
        pEff := DllCall("GlobalLock", "Ptr", hEffect, "Ptr")
        if pEff {
            NumPut("UInt", 1, pEff, 0) ; DROPEFFECT_COPY
            DllCall("GlobalUnlock", "Ptr", hEffect)
        } else {
            DllCall("GlobalFree", "Ptr", hEffect)
            hEffect := 0
        }
    }
    fmtEffect := DllCall("RegisterClipboardFormat", "Str", "Preferred DropEffect", "UInt")

    opened := false
    loop 10 {
        if DllCall("OpenClipboard", "Ptr", 0) {
            opened := true
            break
        }
        Sleep 10
    }
    if !opened {
        DllCall("GlobalFree", "Ptr", hMem)
        if hEffect
            DllCall("GlobalFree", "Ptr", hEffect)
        return false
    }
    DllCall("EmptyClipboard")
    ok := DllCall("SetClipboardData", "UInt", 15, "Ptr", hMem)
    if ok && hEffect && fmtEffect
        DllCall("SetClipboardData", "UInt", fmtEffect, "Ptr", hEffect)
    else if hEffect
        DllCall("GlobalFree", "Ptr", hEffect)
    DllCall("CloseClipboard")
    if !ok {
        DllCall("GlobalFree", "Ptr", hMem)
        return false
    }
    return true
}

; Bridge entry: leave WebView sync stack + debounce (click→抙ost.call re-entrancy = double paste)
RequestPaste(id) {
    global pasteLockUntil
    if A_TickCount < pasteLockUntil
        return
    pasteLockUntil := A_TickCount + 500
    pasteId := id
    SetTimer(() => PasteItem(pasteId), -10)
}

RequestPasteMany(ids, sep := "") {
    global pasteLockUntil
    if A_TickCount < pasteLockUntil
        return
    pasteLockUntil := A_TickCount + 500
    pasteIds := ids
    pasteSep := String(sep)
    SetTimer(() => PasteMany(pasteIds, pasteSep), -10)
}

NormalizePasteSep(tok) {
    tok := String(tok)
    if tok = "" || tok = " "
        return " "
    if tok = "[换行]" || tok = "换行"
        return "`n"
    if tok = "[制表符]"
        return "`t"
    return tok
}

; 条目内按行拆开：每行单独走分隔符；仅跳过末尾空行（复制时常带尾换行）
ExpandPartsByNewline(parts) {
    out := []
    for p in parts {
        lines := StrSplit(String(p), "`n", "`r")
        while lines.Length > 0 && lines[lines.Length] = ""
            lines.Pop()
        for line in lines
            out.Push(line)
    }
    return out
}

; 按分隔符/包裹格式拼接文本条目
JoinClipPartsWithSep(parts, sepTok) {
    sepTok := String(sepTok)
    parts := ExpandPartsByNewline(parts)
    ; ["",""] → ["a","b"]
    if sepTok = "[`"`",`"`"]" {
        out := "["
        for i, p in parts {
            if i > 1
                out .= ","
            out .= '"' p '"'
        }
        return out "]"
    }
    ; ('','') → ('a','b')
    if sepTok = "('','')" {
        out := "("
        for i, p in parts {
            if i > 1
                out .= ","
            out .= "'" p "'"
        }
        return out ")"
    }
    sep := NormalizePasteSep(sepTok)
    out := ""
    for i, p in parts {
        if i > 1
            out .= sep
        out .= p
    }
    return out
}

; SendLevel 0: injected Ctrl+V must not re-enter ~^v / PastePngToDir.
; Explorer/Desktop already pastes HDROP/bitmap once —calling PastePngToDir here duplicated files (2→).
TriggerPasteKey() {
    global pasteSending
    pasteSending := true
    prevLvl := A_SendLevel
    try {
        SendLevel 0
        SendInput "^v"
    } finally {
        SendLevel prevLvl
        SetTimer(() => (pasteSending := false), -120)
    }
}

PutItemOnClipboard(item) {
    global STORE_DIR
    if !IsObject(item)
        return false

    if item.type = "image" {
        imgPath := ""
        if item.HasProp("imgFile") && item.imgFile != ""
            imgPath := STORE_DIR "\" item.imgFile
        if (imgPath = "" || !FileExist(imgPath)) && InStr(item.data, "base64,") {
            imgPath := A_Temp "\clipmgr_p" A_TickCount ".png"
            if RegExMatch(item.data, "i)base64,([\s\S]+)$", &m)
                B64DecodeToFile(m[1], imgPath)
        }
        if imgPath != "" && FileExist(imgPath)
            return SetClipboardImage(imgPath)
        if item.HasProp("clipAll") && IsObject(item.clipAll) && item.clipAll.Size > 0 {
            A_Clipboard := item.clipAll
            return true
        }
        return false
    }

    if item.HasProp("clipAll") && IsObject(item.clipAll) && item.clipAll.Size > 0 {
        A_Clipboard := item.clipAll
        return true
    }
    if item.type = "file" {
        paths := GetItemFilePaths(item)
        if paths.Length
            return SetClipboardFiles(paths)
        ; Fallback: path text if files were moved/deleted
        A_Clipboard := item.data
        return true
    }
    if item.type = "text" || item.type = "link" || item.type = "emoji" {
        EnsureClipBodyLoaded(item)
        data := item.HasProp("data") ? String(item.data) : ""
        if data = ""
            return false
        A_Clipboard := data
        return true
    }
    return false
}

CopyById(uid) {
    item := ResolveClip(uid)
    if !IsObject(item)
        return
    if item.type = "file" {
        paths := GetItemFilePaths(item)
        if paths.Length
            SetClipboardFiles(paths)
        else
            A_Clipboard := item.data
        return
    }
    if item.type = "text" || item.type = "link" || item.type = "emoji"
        A_Clipboard := item.data
}

/**
    Transform text and paste immediately.
    Does NOT modify the original clip history entry.
    Modes:
    ① brace: {a,b} / a,b -> ('a','b')
    ② lines: newline-separated values -> ('a','b') (dedupe)
    ③ json: StrReplace(raw, '\"', '"') JSON quote unescape
    ④ auto: detect by content — brace / lines / json
**/

ApplyTextTransform(uid, mode := "auto") {
    global clipIgnore, uiPinned
    uid := Integer(uid)
    mode := StrLower(Trim(String(mode)))
    if mode = "bracket"
        mode := "brace"
    if mode = "unescape"
        mode := "json"
    if mode = "" || mode = "smart" || mode = "auto"
        mode := "auto"
    item := ResolveClip(uid)
    if !IsObject(item)
        return
    if !(item.type = "text" || item.type = "link")
        return
    src := item.HasProp("data") ? String(item.data) : ""
    if src = "" && item.HasProp("preview")
        src := String(item.preview)
    if mode = "auto" {
        mode := DetectDataTransformMode(src)
        if mode = ""
            return
    }
    out := TransformClipText(src, mode)
    if out = ""
        return

    eraseN := QQTypedEraseCount()
    if !uiPinned
        HidePanel()
    clipIgnore := true
    try {
        A_Clipboard := out
        MarkItemsPasted([uid])
        target := ResolvePasteTargetWin()
        if target {
            DllCall("SetForegroundWindow", "Ptr", target)
            Sleep 15
        }
        QQEraseTypedInEditor(eraseN)
        TriggerPasteKey()
    } finally {
        SetTimer(() => (clipIgnore := false), -400)
        if uiPinned
            SetTimer(RaiseClipboardPanel, -50)
    }
}

/**
    Pick transform mode from raw text.
    Priority:
    ① contains \" -> json unescape (check before brace: escaped JSON also starts with {)
    ② starts with { -> brace (preview may be truncated)
    ③ has newline -> lines
**/

DetectDataTransformMode(raw) {
    s := Trim(String(raw))
    if s = ""
        return ""
    if InStr(s, "\`"")
        return "json"
    if SubStr(s, 1, 1) = "{"
        return "brace"
    if InStr(s, "`n") || InStr(s, "`r")
        return "lines"
    return ""
}

TransformClipText(raw, mode := "brace") {
    if mode = "json"
        return JsonUnescapeQuotes(raw)
    return TextToSqlTuple(raw, mode)
}

/**
    Unescape JSON quote escapes: \" -> "
**/

JsonUnescapeQuotes(raw) {
    ; StrReplace(raw, '\"', '"')
    return StrReplace(String(raw), "\`"", '"')
}

TextToSqlTuple(raw, mode := "brace") {
    raw := Trim(String(raw))
    if raw = ""
        return ""
    parts := []
    if mode = "lines" {
        seen := Map()
        for ln in StrSplit(raw, "`n", "`r") {
            t := Trim(ln)
            if t = ""
                continue
            t := StripOuterQuotes(t)
            if t = "" || seen.Has(t)
                continue
            seen[t] := true
            parts.Push(t)
        }
    } else {
        s := raw
        if RegExMatch(s, "s)^\s*\{(.*)\}\s*$", &m)
            s := Trim(m[1])
        else if RegExMatch(s, "s)^\s*\[(.*)\]\s*$", &m)
            s := Trim(m[1])
        for t in SplitCsvRespectQuotes(s) {
            t := StripOuterQuotes(Trim(t))
            if t != ""
                parts.Push(t)
        }
    }
    if !parts.Length
        return ""
    out := "("
    for i, p in parts {
        if i > 1
            out .= ","
        out .= "'" StrReplace(p, "'", "''") "'"
    }
    out .= ")"
    return out
}

StripOuterQuotes(s) {
    s := String(s)
    n := StrLen(s)
    if n >= 2 {
        a := SubStr(s, 1, 1)
        b := SubStr(s, n, 1)
        if (a = '"' && b = '"') || (a = "'" && b = "'")
            return SubStr(s, 2, n - 2)
    }
    return s
}

SplitCsvRespectQuotes(s) {
    s := String(s)
    parts := []
    cur := ""
    q := ""
    i := 1
    len := StrLen(s)
    while i <= len {
        ch := SubStr(s, i, 1)
        if q != "" {
            if ch = q {
                nxt := i < len ? SubStr(s, i + 1, 1) : ""
                if nxt = q {
                    cur .= q
                    i += 2
                    continue
                }
                q := ""
                i += 1
                continue
            }
            cur .= ch
            i += 1
            continue
        }
        if ch = '"' || ch = "'" {
            q := ch
            i += 1
            continue
        }
        if ch = "," {
            parts.Push(Trim(cur))
            cur := ""
            i += 1
            continue
        }
        cur .= ch
        i += 1
    }
    parts.Push(Trim(cur))
    out := []
    for p in parts {
        if p != ""
            out.Push(p)
    }
    return out
}

DiskReplaceItemLine(item) {
    if !IsObject(item)
        return false
    uid := Integer(item.HasProp("uid") ? item.uid : 0)
    if uid < 1
        return false
    newLine := ItemToJsonLine(item)
    m := LoadManifest()
    for name in m["pages"] {
        path := PagePath(name)
        if !FileExist(path)
            continue
        newText := ""
        changed := false
        found := false
        try {
            loop read path, "UTF-8" {
                line := A_LoopReadLine
                if !found && JsonFieldInt(line, "uid") = uid {
                    found := true
                    if line != newLine {
                        line := newLine
                        changed := true
                    }
                }
                newText .= line "`n"
            }
        } catch {
            continue
        }
        if changed {
            tmp := path ".tmp"
            try {
                if FileExist(tmp)
                    FileDelete tmp
                FileAppend newText, tmp, "UTF-8"
                if FileExist(path)
                    FileDelete path
                FileMove tmp, path
            } catch {
            }
            return true
        }
        if found
            return true
    }
    return false
}

DeleteItem(uid) {
    global clips, viewTotal, wvCore, lastTxt, lastImg, pasteQueueMode, pasteQueueIds, queueMetaMap
    uid := Integer(uid)
    if IsEmojiSearchUid(uid)
        return
    ; Optimistic UI: remove from memory first, disk later — 禁止 ResolveClip 全盘扫描
    imgFile := ""
    itemType := ""
    for c in clips {
        if c.uid = uid {
            if c.HasProp("imgFile")
                imgFile := c.imgFile
            itemType := c.type
            if itemType = "text" || itemType = "link"
                lastTxt := ""
            else if itemType = "image"
                lastImg := ""
            break
        }
    }
    MemoryRemoveUid(uid)
    LiveFrontRemoveUid(uid)
    ; Keep FIFO / meta in sync — stale ids made ^+c / Ctrl+V look "dead" after deletes
    if IsObject(pasteQueueIds) && pasteQueueIds.Length {
        i := 1
        while i <= pasteQueueIds.Length {
            if Integer(pasteQueueIds[i]) = uid
                pasteQueueIds.RemoveAt(i)
            else
                i += 1
        }
        if pasteQueueMode {
            if !pasteQueueIds.Length
                ExitPasteQueue("deleted-all")
            else
                SavePasteQueueState()
        }
    }
    if IsObject(queueMetaMap) && queueMetaMap.Has(String(uid)) {
        queueMetaMap.Delete(String(uid))
        try SaveQueueMeta()
    }
    RequestUiPush()
    EnqueueDiskJob(PersistDeleteUid.Bind(uid, imgFile, itemType))
}

DeleteItemsMany(idsStr) {
    idsStr := String(idsStr)
    seen := Map()
    for part in StrSplit(idsStr, ",") {
        uid := Integer(Trim(part))
        if uid < 1 || seen.Has(uid)
            continue
        seen[uid] := true
        DeleteItem(uid)
    }
}

PinItem(uid) {
    global clips, viewTab, viewQuery, viewToday, wvCore, viewCache, recentFolders
    uid := Integer(uid)
    if IsEmojiSearchUid(uid)
        return
    if IsObject(recentFolders) {
        for c in recentFolders {
            if !IsObject(c) || Integer(c.uid) != uid
                continue
            c.pinned := !(c.HasProp("pinned") && c.pinned)
            ; Memory + one cache rebuild; disk write async (was freezing right-click pin)
            try CacheRecentFoldersView(viewToday)
            if viewTab = "recent" {
                page := QueryRecentFoldersPage(viewQuery, viewToday, 0, VIEW_PAGE_SIZE)
                clips := page.items
                viewTotal := page.total
                PushClips(false)
            } else
                RequestUiPush()
            EnqueueDiskJob(SaveRecentFolders)
            return
        }
    }
    newPin := unset
    pinAt := ""
    for c in clips {
        if c.uid = uid {
            c.pinned := !(c.HasProp("pinned") && c.pinned)
            newPin := c.pinned
            if newPin {
                pinAt := FormatTime(, "yyyy-MM-dd HH:mm:ss")
                c.pinTime := pinAt
            } else
                c.pinTime := ""
            break
        }
    }
    if !IsSet(newPin) {
        ; Not in current list —still flip on disk/cache via resolve
        it := ResolveClip(uid)
        if !IsObject(it)
            return
        it.pinned := !(it.HasProp("pinned") && it.pinned)
        newPin := it.pinned
        if newPin {
            pinAt := FormatTime(, "yyyy-MM-dd HH:mm:ss")
            it.pinTime := pinAt
        } else
            it.pinTime := ""
    }
    for , entry in viewCache {
        if !IsObject(entry) || !entry.HasProp("items")
            continue
        for c in entry.items {
            if c.uid = uid {
                c.pinned := newPin
                c.pinTime := newPin ? pinAt : ""
                break
            }
        }
    }
    ; Keep liveFront in sync (not-yet-persisted copies)
    global liveFront
    if IsObject(liveFront) {
        for c in liveFront {
            if IsObject(c) && c.uid = uid {
                c.pinned := newPin
                c.pinTime := newPin ? pinAt : ""
                break
            }
        }
    }
    ; Drop stale 收藏-tab caches (membership / order changed)
    dropKeys := []
    for key, entry in viewCache {
        tab := "", todayOnly := false, query := ""
        ParseViewCacheKey(key, &tab, &todayOnly, &query)
        if tab = "pinned"
            dropKeys.Push(key)
    }
    for key in dropKeys
        viewCache.Delete(key)
    ; 必须清掉 pinned searchPools，否则新收藏进不了「收藏」页（旧池一直缓存）
    InvalidatePinnedSearchPools()
    ; Persist async —sync disk + SetView made pin clicks hitch
    EnqueueDiskJob(DiskSetPinned.Bind(uid, newPin, pinAt))
    if viewTab = "pinned" {
        if !newPin {
            ; 取消收藏：当前页立刻摘掉，勿走慢速全量 SetView
            kept := []
            for c in clips {
                if !IsObject(c) || Integer(c.uid) != uid
                    kept.Push(c)
            }
            clips := kept
            viewTotal := Max(0, Integer(viewTotal) - 1)
            PushClips(false)
        } else {
            ; 新收藏落在收藏页：补一次视图（相对少见）
            QueueSetView(viewTab, viewQuery, viewToday ? "1" : "0")
        }
    } else if viewQuery != "" {
        QueueSetView(viewTab, viewQuery, viewToday ? "1" : "0")
    } else
        RequestUiPush()
}

PinItemsMany(idsStr, flag := "1") {
    global clips, viewTab, viewQuery, viewToday, viewCache, recentFolders, liveFront
    wantPin := (String(flag) = "1" || String(flag) = "true")
    pinAt := wantPin ? FormatTime(, "yyyy-MM-dd HH:mm:ss") : ""
    ids := []
    seen := Map()
    for part in StrSplit(String(idsStr), ",") {
        uid := Integer(Trim(part))
        if uid < 1 || seen.Has(uid)
            continue
        seen[uid] := true
        ids.Push(uid)
    }
    if !ids.Length
        return

    ; Recent folders: set pinned flag (not clipboard 收藏)
    if IsObject(recentFolders) {
        rfHit := 0
        for uid in ids {
            for c in recentFolders {
                if !IsObject(c) || Integer(c.uid) != uid
                    continue
                c.pinned := wantPin
                rfHit += 1
                break
            }
        }
        if rfHit = ids.Length {
            try CacheRecentFoldersView(viewToday)
            if viewTab = "recent" {
                page := QueryRecentFoldersPage(viewQuery, viewToday, 0, VIEW_PAGE_SIZE)
                clips := page.items
                viewTotal := page.total
                PushClips(false)
            } else
                RequestUiPush()
            EnqueueDiskJob(SaveRecentFolders)
            return
        }
    }

    for uid in ids {
        applied := false
        for c in clips {
            if Integer(c.uid) = uid {
                c.pinned := wantPin
                c.pinTime := pinAt
                applied := true
                break
            }
        }
        if !applied {
            it := ResolveClip(uid)
            if IsObject(it) {
                it.pinned := wantPin
                it.pinTime := pinAt
            }
        }
        for , entry in viewCache {
            if !IsObject(entry) || !entry.HasProp("items")
                continue
            for c in entry.items {
                if Integer(c.uid) = uid {
                    c.pinned := wantPin
                    c.pinTime := pinAt
                    break
                }
            }
        }
        if IsObject(liveFront) {
            for c in liveFront {
                if IsObject(c) && Integer(c.uid) = uid {
                    c.pinned := wantPin
                    c.pinTime := pinAt
                    break
                }
            }
        }
        EnqueueDiskJob(DiskSetPinned.Bind(uid, wantPin, pinAt))
    }

    dropKeys := []
    for key, entry in viewCache {
        tab := "", todayOnly := false, query := ""
        ParseViewCacheKey(key, &tab, &todayOnly, &query)
        if tab = "pinned"
            dropKeys.Push(key)
    }
    for key in dropKeys
        viewCache.Delete(key)
    InvalidatePinnedSearchPools()

    if viewTab = "pinned" {
        if !wantPin {
            kept := []
            for c in clips {
                if !IsObject(c) || seen.Has(Integer(c.uid))
                    continue
                kept.Push(c)
            }
            clips := kept
            viewTotal := Max(0, Integer(viewTotal) - ids.Length)
            PushClips(false)
        } else
            QueueSetView(viewTab, viewQuery, viewToday ? "1" : "0")
    } else if viewQuery != "" {
        QueueSetView(viewTab, viewQuery, viewToday ? "1" : "0")
    } else
        RequestUiPush()
}

InvalidatePinnedSearchPools() {
    global searchPools
    if !IsObject(searchPools)
        return
    dropKeys := []
    for key, _ in searchPools {
        tab := "", todayOnly := false, query := ""
        ParseViewCacheKey(key, &tab, &todayOnly, &query)
        if tab = "pinned"
            dropKeys.Push(key)
    }
    for key in dropKeys
        searchPools.Delete(key)
}

; Clear all search pools (merge/unmerge changes favGroup for every tab)
InvalidateAllSearchPools() {
    global searchPools, viewCache
    searchPools := Map()
    ; Drop cached search results — incomplete favGroup pages would keep showing 2/3 forever
    if !IsObject(viewCache)
        return
    dropKeys := []
    for key, _ in viewCache {
        tab := "", todayOnly := false, query := ""
        ParseViewCacheKey(key, &tab, &todayOnly, &query)
        if Trim(String(query)) != "" || tab = "pinned"
            dropKeys.Push(key)
    }
    for key in dropKeys
        viewCache.Delete(key)
}

MarkItemsPasted(uids) {
    global clips, viewCache, liveFront, panelVisible, wvCore
    want := Map()
    idList := []
    for uid in uids {
        id := Integer(uid)
        if id < 1
            continue
        want[id] := true
        idList.Push(id)
    }
    if !want.Count
        return
    ; Optimistic memory update —disk write is async (was blocking paste for seconds)
    for c in clips {
        if want.Has(c.uid)
            c.pasted := true
    }
    if IsObject(liveFront) {
        for c in liveFront {
            if IsObject(c) && want.Has(c.uid)
                c.pasted := true
        }
    }
    for , entry in viewCache {
        if !IsObject(entry) || !entry.HasProp("items")
            continue
        for c in entry.items {
            if want.Has(c.uid)
                c.pasted := true
        }
    }
    diskWant := Map()
    for id, _ in want {
        if !IsEmojiSearchUid(id)
            diskWant[id] := true
    }
    if diskWant.Count
        EnqueueDiskJob(DiskSetPasted.Bind(diskWant, true))
    ; Instant ✓ — inject even if panel just hid (FIFO paste); WebView keeps DOM
    if IsObject(wvCore) && idList.Length {
        jsIds := ""
        for i, id in idList
            jsIds .= (i > 1 ? "," : "") id
        try wvCore.ExecuteScriptAsync("window.__markPasted&&window.__markPasted([" jsIds "])")
    }
}

ClearPasted(uid) {
    global clips
    uid := Integer(uid)
    want := Map()
    want[uid] := true
    DiskSetPasted(want, false)
    for c in clips {
        if c.uid = uid {
            c.pasted := false
            break
        }
    }
    PushClips(false)
}

SetFavTitle(uid, title := "") {
    global clips, viewTab, viewQuery, viewToday, wvCore, viewCache, recentFolders
    uid := Integer(uid)
    title := Trim(String(title))
    if StrLen(title) > 80
        title := SubStr(title, 1, 80)
    found := false
    isRecent := false
    if IsObject(recentFolders) {
        for c in recentFolders {
            if Integer(c.uid) = uid {
                c.favTitle := title
                found := true
                isRecent := true
                break
            }
        }
    }
    if !found {
    for c in clips {
        if c.uid = uid {
            c.favTitle := title
            found := true
            break
            }
        }
    }
    if !found {
        it := ResolveClip(uid)
        if !IsObject(it)
            return
        it.favTitle := title
        if StrLower(String(it.type)) = "recent"
            isRecent := true
    }
    for , entry in viewCache {
        if !IsObject(entry) || !entry.HasProp("items")
            continue
        for c in entry.items {
            if c.uid = uid {
                c.favTitle := title
                break
            }
        }
    }
    if isRecent {
        SaveRecentFolders()
        InvalidateRecentViewCaches()
    } else {
    DiskSetFavTitle(uid, title)
    ; Rebuild search hay so compact fav title ("gogettrans") is indexed
    global searchPools
    if IsObject(searchPools)
        searchPools := Map()
    }
    if viewQuery != "" || viewTab = "pinned" || viewTab = "recent"
        SetView(viewTab, viewQuery, viewToday ? "1" : "0")
    else if IsObject(wvCore)
        PushClips(false)
}

ApplyFavGroupLocal(uid, gid) {
    global clips, viewCache
    uid := Integer(uid)
    gid := String(gid)
    for c in clips {
        if c.uid = uid {
            c.favGroup := gid
            break
        }
    }
    for , entry in viewCache {
        if !IsObject(entry) || !entry.HasProp("items")
            continue
        for c in entry.items {
            if c.uid = uid {
                c.favGroup := gid
                break
            }
        }
    }
}

MergeFavItems(idsCsv := "") {
    global viewTab, viewQuery, viewToday, wvCore, viewCache
    ids := []
    seen := Map()
    for part in StrSplit(String(idsCsv), ",") {
        uid := Integer(Trim(part))
        if uid < 1 || seen.Has(uid)
            continue
        seen[uid] := true
        ids.Push(uid)
    }
    if ids.Length < 2
        return
    gid := "g" A_Now "_" Random(1000, 9999)
    for uid in ids {
        it := ResolveClip(uid)
        if !IsObject(it)
            continue
        ; Merge is a favorites feature —keep pinned
        if !(it.HasProp("pinned") && it.pinned) {
            it.pinned := true
            it.pinTime := FormatTime(, "yyyy-MM-dd HH:mm:ss")
            DiskSetPinned(uid, true, it.pinTime)
        }
        ApplyFavGroupLocal(uid, gid)
        DiskSetFavGroup(uid, gid)
    }
    ; Drop pinned-tab caches (order/grouping changed)
    dropKeys := []
    for key, entry in viewCache {
        tab := "", todayOnly := false, query := ""
        ParseViewCacheKey(key, &tab, &todayOnly, &query)
        if tab = "pinned"
            dropKeys.Push(key)
    }
    for key in dropKeys
        viewCache.Delete(key)
    InvalidateAllSearchPools()
    if viewTab = "pinned" || viewQuery != ""
        SetView(viewTab, viewQuery, viewToday ? "1" : "0")
    else if IsObject(wvCore)
        PushClips(false)
}

UnmergeFavItem(uid := 0) {
    global viewTab, viewQuery, viewToday, wvCore, viewCache, clips
    uid := Integer(uid)
    if uid < 1
        return
    it := ResolveClip(uid)
    if !IsObject(it)
        return
    gid := it.HasProp("favGroup") ? String(it.favGroup) : ""
    if gid = ""
        return
    targets := []
    for c in clips {
        if c.HasProp("favGroup") && String(c.favGroup) = gid
            targets.Push(c.uid)
    }
    ; Also clear mates only present in viewCache / disk resolve
    if !targets.Length
        targets.Push(uid)
    for , entry in viewCache {
        if !IsObject(entry) || !entry.HasProp("items")
            continue
        for c in entry.items {
            if c.HasProp("favGroup") && String(c.favGroup) = gid {
                found := false
                for t in targets {
                    if t = c.uid {
                        found := true
                        break
                    }
                }
                if !found
                    targets.Push(c.uid)
            }
        }
    }
    for t in targets {
        ApplyFavGroupLocal(t, "")
        DiskSetFavGroup(t, "")
    }
    dropKeys := []
    for key, entry in viewCache {
        tab := "", todayOnly := false, query := ""
        ParseViewCacheKey(key, &tab, &todayOnly, &query)
        if tab = "pinned"
            dropKeys.Push(key)
    }
    for key in dropKeys
        viewCache.Delete(key)
    InvalidateAllSearchPools()
    if viewTab = "pinned" || viewQuery != ""
        SetView(viewTab, viewQuery, viewToday ? "1" : "0")
    else if IsObject(wvCore)
        PushClips(false)
}

OpenLink(uid) {
    item := ResolveClip(uid)
    if !IsObject(item)
        return
    url := ""
    if item.type = "link"
        url := item.data
    else if item.type = "text" && RegExMatch(Trim(item.data), "i)^https?://")
        url := Trim(item.data)
    if url = ""
        return
    try Run(url)
    HidePanel()
}

OpenFilePath(path := "") {
    path := Trim(String(path))
    if (SubStr(path, 1, 1) = '"' && SubStr(path, -1) = '"')
        || (SubStr(path, 1, 1) = "'" && SubStr(path, -1) = "'")
        path := Trim(SubStr(path, 2, -1))
    if path = ""
        return
    if !FileExist(path)
        return
    ; Quote path so spaces / special chars still open
    try Run('"' path '"')
    catch {
        try DllCall("shell32\ShellExecuteW", "ptr", 0, "wstr", "open", "wstr", path, "ptr", 0, "ptr", 0, "int", 1)
    }
    HidePanel()
}

; Open a directory itself (recent-folder tab / Enter / path crumbs)
OpenFolderDir(path := "") {
    global uiPinned, qqSearchOn, qqQuery, viewQuery, viewTab, viewToday, wvCore
    path := Trim(String(path))
    path := StrReplace(path, "/", "\")
    if (SubStr(path, 1, 1) = '"' && SubStr(path, -1) = '"')
        || (SubStr(path, 1, 1) = "'" && SubStr(path, -1) = "'")
        path := Trim(SubStr(path, 2, -1))
    if path = ""
        return
    ; "E:" → "E:\" so DirExist / explorer work
    if RegExMatch(path, "^[a-zA-Z]:$")
        path .= "\"
    ClipLog("OpenFolderDir try " path)
    if !DirExist(path) {
        SplitPath path, , &dir
        if dir != "" && DirExist(dir)
            path := dir
        else {
            ClipLog("OpenFolderDir miss " path)
            return
        }
    }
    wasQQ := qqSearchOn
    eraseN := QQTypedEraseCount()
    ; Open explorer first —never call ExecuteScriptAsync inside sync WebView host
    try Run('explorer.exe "' path '"')
    if wasQQ {
        target := ResolvePasteTargetWin()
        if target {
            try DllCall("SetForegroundWindow", "Ptr", target)
            Sleep 15
        }
        QQEraseTypedInEditor(eraseN)
        QQStopSearch(true)
        qqQuery := ""
        viewQuery := ""
        ; Defer UI clear so we are outside the host call stack
        if IsObject(wvCore)
            SetTimer(() => (IsObject(wvCore) && wvCore.ExecuteScriptAsync("window.__clearQQSearch&&window.__clearQQSearch()")), -30)
    }
    if !uiPinned {
        HidePanel()
        return
    }
    if wasQQ
        SetTimer(() => SetView(viewTab, "", viewToday ? "1" : "0"), -40)
    SetTimer(RaiseClipboardPanel, -80)
}

; WebView2 postMessage: "openDir|E:/foo/bar" — 路径点击专用，避开 sync host
HandleUiWebMessage(core, args) {
    try {
        s := ""
        try s := String(args.TryGetWebMessageAsString())
        catch {
            try s := String(args.WebMessageAsJson)
        }
        s := Trim(s)
        if s = ""
            return
        ClipLog("WebMsg " SubStr(s, 1, 180))
        if SubStr(s, 1, 5) = "perf|" {
            PerfMark("UI " SubStr(s, 6))
            return
        }
        if SubStr(s, 1, 8) = "openDir|" {
            p := SubStr(s, 9)
            p := Trim(p, ' `"')
            SetTimer(OpenFolderDir.Bind(p), -1)
            return
        }
    } catch as e {
        ClipLogErr("HandleUiWebMessage", e)
    }
}

OpenContainingFolder(path := "") {
    path := Trim(String(path))
    if (SubStr(path, 1, 1) = '"' && SubStr(path, -1) = '"')
        || (SubStr(path, 1, 1) = "'" && SubStr(path, -1) = "'")
        path := Trim(SubStr(path, 2, -1))
    if path = ""
        return
    if FileExist(path) {
        try Run('explorer.exe /select,"' path '"')
        HidePanel()
        return
    }
    SplitPath path, , &dir
    if dir != "" && DirExist(dir) {
        try Run('explorer.exe "' dir '"')
        HidePanel()
    }
}

CopyFilePath(path := "") {
    global clipIgnore
    path := Trim(String(path))
    if (SubStr(path, 1, 1) = '"' && SubStr(path, -1) = '"')
        || (SubStr(path, 1, 1) = "'" && SubStr(path, -1) = "'")
        path := Trim(SubStr(path, 2, -1))
    if path = ""
        return
    clipIgnore := true
    try A_Clipboard := path
    SetTimer(() => (clipIgnore := false), -400)
}

MoveToTop(uid) {
    global viewTab, viewQuery, viewToday, wvCore
    uid := Integer(uid)
    item := MemoryTakeUid(uid)
    if !IsObject(item)
        item := ResolveClip(uid)
    if !IsObject(item)
        return
    MemoryInsertFront(item)
    RequestUiPush()
    EnqueueDiskJob(PersistMoveToTop.Bind(item))
}

ClearAll(*) {
    ClearTab("all", "all")
}

; tab: all|text|image|file|link|pinned
; scope: today (default) | all
ClearTab(tab := "all", scope := "today") {
    global viewTab, viewQuery, viewToday, lastTxt, lastImg, clips, viewTotal, liveFront, pasteQueueMode, pasteQueueIds, queueMetaMap
    tab := StrLower(Trim(String(tab)))
    scope := StrLower(Trim(String(scope)))
    if tab = "recent" {
        ClearRecentFolders()
        InvalidateRecentViewCaches()
        try CacheRecentFoldersView(false)
        try CacheRecentFoldersView(true)
        RequestUiPush()
        SetView("recent", viewQuery, viewToday ? "1" : "0")
        return
    }
    clearAllDates := (scope = "all")
    today := FormatTime(, "yyyy-MM-dd")
    ; 清空历史后队列应重新从 +1 开始
    if pasteQueueMode || (IsObject(pasteQueueIds) && pasteQueueIds.Length)
        ExitPasteQueue("clear-tab")
    ; 先清内存并立刻刷新 UI，磁盘清空丢后台（否则 3000+ 条会卡死面板）
    MemoryClearTab(tab, clearAllDates, today)
    InvalidateViewCache()
    if tab = "all" || tab = "text" || tab = "link"
        lastTxt := ""
    if tab = "all" || tab = "image"
        lastImg := ""
    try {
        if tab = "all" && clearAllDates {
            queueMetaMap := Map()
            SaveQueueMeta()
        }
    }
    RequestUiPush()
    vt := viewTab, vq := viewQuery, vd := viewToday
    EnqueueDiskJob(() => (
        DiskClearTab(tab, clearAllDates, today),
        SetView(vt, vq, vd ? "1" : "0")
    ))
}

MemoryClearTab(tab, clearAllDates, today) {
    global clips, viewTotal, liveFront
    pred := (c) => ItemShouldClear(c, tab, clearAllDates, today)
    MemoryRemoveFromList(clips, pred)
    viewTotal := clips.Length
    if IsObject(liveFront)
        MemoryRemoveFromList(liveFront, pred)
}

ItemShouldClear(c, tab, clearAllDates, today) {
    if !IsObject(c)
        return false
    if !ItemMatchesClearTab(c, tab)
        return false
    if tab != "pinned" && c.HasOwnProp("pinned") && c.pinned
        return false
    if !clearAllDates {
        t := c.HasOwnProp("time") ? String(c.time) : ""
        if SubStr(t, 1, 10) != today
            return false
    }
    return true
}

ItemMatchesClearTab(c, tab) {
    type := c.HasOwnProp("type") ? StrLower(String(c.type)) : "text"
    switch tab {
        case "text", "image", "file", "link":
            return type = tab
        case "pinned":
            return c.HasOwnProp("pinned") && c.pinned
        default: ; all
            return type != "link"
    }
}

ScheduleSave() {
    ; Disk is written immediately by mutators; keep stub for any leftover callers
}

SaveImageToStore(dataUrl) {
    global STORE_DIR
    try {
        DirCreate STORE_DIR
        if !RegExMatch(dataUrl, "i)base64,([\s\S]+)$", &m)
            return ""
        name := "img_" A_Now "_" Random(10000, 99999) ".png"
        path := STORE_DIR "\" name
        if !B64DecodeToFile(m[1], path)
            return ""
        ; Build list thumb off the clipboard hot path
        nm := name
        SetTimer(() => EnsureListThumbSafe(nm), -80)
        return name
    } catch {
        return ""
    }
}

EnsureListThumbSafe(name) {
    try EnsureListThumbFile(name)
    catch as e {
        ClipLog("EnsureListThumbSafe fail name=" name " err=" e.Message)
    }
}

; 8.3 short path —WebView2 virtual host mapping fails on folders with spaces
GetShortPath(longPath) {
    longPath := String(longPath)
    if longPath = ""
        return ""
    bufSize := 520
    buf := Buffer(bufSize * 2, 0)
    n := DllCall("GetShortPathNameW", "WStr", longPath, "Ptr", buf, "UInt", bufSize, "UInt")
    if n && n < bufSize
        return StrGet(buf, "UTF-16")
    return longPath
}

ApplyClipSrc(item) {
    src := CaptureClipSrcIcon()
    item.srcIcon := src.icon
    item.srcExe := src.exe
    item.srcTitle := src.title
}

; Capture foreground (or last non-panel / non-snip) process icon + window title
CaptureClipSrcIcon() {
    global guiWin, prevActiveWin, lastGoodActiveWin
    hwnd := 0
    try hwnd := WinExist("A")
    if IsObject(guiWin) && guiWin.Hwnd && hwnd = guiWin.Hwnd
        hwnd := prevActiveWin ? prevActiveWin : lastGoodActiveWin
    ; Win+Shift+S / 截图工具常会抢前台 — 用截图前的真实窗口
    if IsScreenshotHelperHwnd(hwnd) || IsShellOverlayHwnd(hwnd)
        hwnd := lastGoodActiveWin ? lastGoodActiveWin : prevActiveWin
    empty := { icon: "", exe: "", title: "" }
    if !hwnd
        return empty
    exePath := ""
    exeName := ""
    try {
        exePath := WinGetProcessPath("ahk_id " hwnd)
        exeName := WinGetProcessName("ahk_id " hwnd)
    }
    if IsScreenshotHelperExe(exeName) {
        hwnd := lastGoodActiveWin ? lastGoodActiveWin : prevActiveWin
        if !hwnd
            return empty
        try {
            exePath := WinGetProcessPath("ahk_id " hwnd)
            exeName := WinGetProcessName("ahk_id " hwnd)
        }
    }
    title := ClipSrcWindowTitle(hwnd, exeName)
    if exePath = "" || !FileExist(exePath)
        return { icon: "", exe: exeName, title: title }
    return { icon: SaveExeIconToStore(exePath), exe: exeName, title: title }
}

ClipSrcWindowTitle(hwnd, exeName := "") {
    global guiWin
    title := ""
    try title := Trim(WinGetTitle("ahk_id " hwnd))
    catch
        title := ""
    if IsObject(guiWin) && guiWin.Hwnd && hwnd = guiWin.Hwnd
        title := ""
    ; Strip common " — App" / " - App" suffixes only if leftover is empty
    if title = "" {
        exe := RegExReplace(String(exeName), "i)\.exe$", "")
        return exe
    }
    if StrLen(title) > 200
        title := SubStr(title, 1, 200)
    return title
}

IsScreenshotHelperExe(exe) {
    exe := StrLower(Trim(String(exe)))
    return exe = "screenclippinghost.exe"
        || exe = "snippingtool.exe"
        || exe = "pickerhost.exe"
        || exe = "screenshot.exe"
}

IsScreenshotHelperHwnd(hwnd) {
    if !hwnd
        return false
    try return IsScreenshotHelperExe(WinGetProcessName("ahk_id " hwnd))
    catch
        return false
}

SaveExeIconToStore(exePath) {
    global STORE_DIR
    exePath := Trim(String(exePath))
    if exePath = "" || !FileExist(exePath)
        return ""
    try DirCreate STORE_DIR
    SplitPath exePath, &exeName
    safe := RegExReplace(StrLower(exeName), "[^a-z0-9._-]+", "_")
    if safe = ""
        safe := "app"
    name := "appico_" safe ".png"
    dest := STORE_DIR "\" name
    if FileExist(dest)
        return name

    hLarge := 0, hSmall := 0, pToken := 0, pBitmap := 0
    try {
        DllCall("shell32\ExtractIconExW", "WStr", exePath, "Int", 0
            , "Ptr*", &hLarge, "Ptr*", &hSmall, "UInt", 1, "UInt")
        hIcon := hLarge ? hLarge : hSmall
        if !hIcon
            return ""

        DllCall("LoadLibrary", "Str", "gdiplus.dll", "Ptr")
        si := Buffer(24, 0)
        NumPut("UInt", 1, si)
        if DllCall("gdiplus\GdiplusStartup", "Ptr*", &pToken, "Ptr", si, "Ptr", 0)
            return ""
        if DllCall("gdiplus\GdipCreateBitmapFromHICON", "Ptr", hIcon, "Ptr*", &pBitmap) || !pBitmap
            return ""
        clsid := Buffer(16)
        DllCall("ole32\CLSIDFromString", "Str", "{557CF406-1A04-11D3-9A73-0000F81EF32E}", "Ptr", clsid)
        if DllCall("gdiplus\GdipSaveImageToFile", "Ptr", pBitmap, "WStr", dest, "Ptr", clsid, "Ptr", 0)
            return ""
        return FileExist(dest) ? name : ""
    } catch {
        return ""
    } finally {
        if hLarge
            try DllCall("DestroyIcon", "Ptr", hLarge)
        if hSmall && hSmall != hLarge
            try DllCall("DestroyIcon", "Ptr", hSmall)
        if pBitmap
            try DllCall("gdiplus\GdipDisposeImage", "Ptr", pBitmap)
        if pToken
            try DllCall("gdiplus\GdiplusShutdown", "Ptr", pToken)
    }
}

IsImageFilePath(path) {
    path := Trim(String(path))
    if path = ""
        return false
    SplitPath path, , , &ext
    ext := StrLower(ext)
    static imgExt := " png jpg jpeg gif webp bmp ico tif tiff svg "
    return InStr(imgExt, " " ext " ")
}

; Copy first image file path into clips_store so UI can use https://clips.store/ like screenshots
EnsureFileImageInStore(path := "", uid := 0) {
    global STORE_DIR
    path := Trim(String(path))
    if (SubStr(path, 1, 1) = '"' && SubStr(path, -1) = '"')
        || (SubStr(path, 1, 1) = "'" && SubStr(path, -1) = "'")
        path := Trim(SubStr(path, 2, StrLen(path) - 2))
    if !IsImageFilePath(path) || !FileExist(path)
        return ""
    try DirCreate STORE_DIR
    SplitPath path, , , &ext
    ext := StrLower(ext)
    if ext = ""
        ext := "png"
    uid := Integer(uid)
    name := (uid > 0 ? ("fimg_" uid) : ("fimg_" A_Now "_" Random(10000, 99999))) "." ext
    dest := STORE_DIR "\" name
    try {
        if FileExist(dest) {
            ClipLog("EnsureFileImageInStore exists " name)
            return name
        }
        ClipLog("EnsureFileImageInStore FileCopy →" name)
        ; Prefer CopyFileW; avoid AHK FileCopy hang on cloud/OneDrive Desktop
        ok := DllCall("CopyFileW", "WStr", path, "WStr", dest, "Int", 0)
        if !ok {
            ClipLog("EnsureFileImageInStore CopyFileW fail err=" A_LastError " fallback FileCopy")
            try FileCopy path, dest, 1
            catch as e {
                ClipLogErr("EnsureFileImageInStore FileCopy", e)
                return ""
            }
        }
        if FileExist(dest) {
            ClipLog("EnsureFileImageInStore OK " name " size=" FileGetSize(dest))
            return name
        }
        ClipLog("EnsureFileImageInStore missing after copy")
    } catch as e {
        ClipLogErr("EnsureFileImageInStore", e)
    }
    return ""
}

EnsureFileClipThumb(item) {
    global STORE_DIR, wvCore, panelVisible
    ; Soft path only  — never call GDI+ here (native hang/kill under disk jobs)
    if !IsObject(item) || item.type != "file"
        return
    ClipLog("EnsureFileClipThumb begin uid=" item.uid)
    if item.HasProp("imgFile") && item.imgFile != "" && FileExist(STORE_DIR "\" item.imgFile) {
        ClipLog("EnsureFileClipThumb already has " item.imgFile)
        return
    }
    raw := String(item.HasProp("data") ? item.data : "")
    if raw = "" && item.HasProp("preview")
        raw := String(item.preview)
    for ln in StrSplit(raw, "`n", "`r") {
        p := Trim(ln)
        if (SubStr(p, 1, 1) = '"' && SubStr(p, -1) = '"')
            || (SubStr(p, 1, 1) = "'" && SubStr(p, -1) = "'")
            p := Trim(SubStr(p, 2, StrLen(p) - 2))
        if !IsImageFilePath(p) || !FileExist(p)
            continue
        ClipLog("EnsureFileClipThumb copy " SubStr(p, 1, 120))
        name := ""
        try name := EnsureFileImageInStore(p, item.uid)
        catch as e {
            ClipLogErr("EnsureFileClipThumb store", e)
            return
        }
        if name = "" {
            ClipLog("EnsureFileClipThumb store empty —skip")
            return
        }
        item.imgFile := name
        ; Dimensions optional —GdipCreateBitmapFromFile hung/killed process; skip
        ClipLog("EnsureFileClipThumb done imgFile=" name " (no GDI+ dims)")
        break
    }
}

; AddClipItem 立刻异步补缩略图（不等 Persist 队列）
EnsureFileClipThumbAndInject(item) {
    global panelVisible, wvCore
    if !IsObject(item) || item.type != "file"
        return
    try EnsureFileClipThumb(item)
    catch as e {
        ClipLogErr("EnsureFileClipThumbAndInject", e)
        return
    }
    if !(item.HasProp("imgFile") && item.imgFile != "")
        return
    ApplyImgFileLocal(item.uid, item.imgFile)
    SetTimer(InjectStoreThumbNow.Bind(Integer(item.uid), String(item.imgFile)), -10)
    if panelVisible && IsObject(wvCore)
        SetTimer(() => RequestUiPush(), -40)
}

GetImageFileDimensions(path, &w := 0, &h := 0) {
    w := 0, h := 0
    if !FileExist(path)
        return false
    pToken := 0, pBitmap := 0
    try {
        si := Buffer(16, 0)
        NumPut("UInt", 1, si, 0)
        if DllCall("gdiplus\GdiplusStartup", "UPtr*", &pToken, "Ptr", si, "Ptr", 0)
            return false
        if DllCall("gdiplus\GdipCreateBitmapFromFile", "WStr", path, "Ptr*", &pBitmap) || !pBitmap
            return false
        DllCall("gdiplus\GdipGetImageWidth", "Ptr", pBitmap, "UInt*", &w)
        DllCall("gdiplus\GdipGetImageHeight", "Ptr", pBitmap, "UInt*", &h)
        return w > 0 && h > 0
    } catch {
        return false
    } finally {
        if pBitmap
            try DllCall("gdiplus\GdipDisposeImage", "Ptr", pBitmap)
        if pToken
            try DllCall("gdiplus\GdiplusShutdown", "Ptr", pToken)
    }
}

DeleteStoredImage(item) {
    global STORE_DIR, listThumbUrlCache
    if !IsObject(item) || !item.HasProp("imgFile") || item.imgFile = ""
        return
    path := STORE_DIR "\" item.imgFile
    try {
        if FileExist(path)
            FileDelete path
    }
    ; Remove list-thumb cache too
    try {
        if listThumbUrlCache.Has(String(item.imgFile))
            listThumbUrlCache.Delete(String(item.imgFile))
        base := RegExReplace(String(item.imgFile), "\.[^.]+$", "")
        th := STORE_DIR "\th_" base ".jpg"
        if FileExist(th)
            FileDelete th
    }
}

LoadImageFromStore(name) {
    global STORE_DIR
    if name = ""
        return ""
    path := STORE_DIR "\" name
    if !FileExist(path)
        return ""
    try {
        f := FileOpen(path, "r")
        if !IsObject(f)
            return ""
        buf := Buffer(f.Length)
        f.RawRead(buf)
        f.Close()
        SplitPath path, , , &ext
        ext := StrLower(ext)
        mime := "image/png"
        switch ext {
            case "jpg", "jpeg": mime := "image/jpeg"
            case "gif": mime := "image/gif"
            case "webp": mime := "image/webp"
            case "bmp": mime := "image/bmp"
            case "svg": mime := "image/svg+xml"
            case "ico": mime := "image/x-icon"
        }
        return "data:" mime ";base64," B64Encode(buf)
    } catch {
        return ""
    }
}

B64DecodeToFile(b64, path) {
    b64 := RegExReplace(b64, "\s+")
    needed := 0
    if !DllCall("crypt32\CryptStringToBinaryW",
        "WStr", b64, "UInt", 0, "UInt", 0x1, "Ptr", 0, "UInt*", &needed, "Ptr", 0, "Ptr", 0, "Int")
        return false
    buf := Buffer(needed)
    if !DllCall("crypt32\CryptStringToBinaryW",
        "WStr", b64, "UInt", 0, "UInt", 0x1, "Ptr", buf, "UInt*", &needed, "Ptr", 0, "Ptr", 0, "Int")
        return false
    f := FileOpen(path, "w")
    if !IsObject(f)
        return false
    f.RawWrite(buf)
    f.Close()
    return true
}

; 鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺?
; NDJSON page store (inlined —was data\clip_v1\ndjson_pages.ahk)
; each shard holds at most PAGE_SIZE records (newest pages first)
; 鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺?
; NDJSON page store: each shard file holds at most PAGE_SIZE records (newest pages first).
; Query/mutate only load one shard at a time —peak memory stays bounded.

ItemToJsonLine(c) {
    imgFile := c.HasProp("imgFile") ? c.imgFile : ""
    dataFile := c.HasProp("dataFile") ? c.dataFile : ""
    preview := c.HasProp("preview") ? c.preview : ""
    if c.type = "image" {
        preview := ""
        data := ""
        dataFile := ""
    } else if dataFile != "" {
        ; Large body lives in clips_payloads —keep NDJSON line small/reliable
        data := ""
    } else {
        data := c.data
    }
    uid := c.HasProp("uid") ? Integer(c.uid) : 0
    out := "{"
    out .= '"uid":' uid ","
    out .= '"type":"' c.type '",'
    out .= '"time":"' c.time '",'
    out .= '"pinned":' (c.pinned ? "true" : "false") ","
    out .= '"pinTime":' JsonStr(c.HasProp("pinTime") ? c.pinTime : "") ","
    out .= '"pasted":' ((c.HasProp("pasted") && c.pasted) ? "true" : "false") ","
    out .= '"queueGroup":' (c.HasProp("queueGroup") ? Integer(c.queueGroup) : 0) ","
    out .= '"queueIndex":' (c.HasProp("queueIndex") ? Integer(c.queueIndex) : 0) ","
    out .= '"charCount":' (c.HasProp("charCount") ? c.charCount : 0) ","
    out .= '"fileCount":' (c.HasProp("fileCount") ? c.fileCount : 0) ","
    out .= '"width":' (c.HasProp("width") ? c.width : 0) ","
    out .= '"height":' (c.HasProp("height") ? c.height : 0) ","
    out .= '"imgFile":' JsonStr(imgFile) ","
    out .= '"dataFile":' JsonStr(dataFile) ","
    out .= '"linkTitle":' JsonStr(c.HasProp("linkTitle") ? c.linkTitle : "") ","
    out .= '"linkHost":' JsonStr(c.HasProp("linkHost") ? c.linkHost : "") ","
    out .= '"favTitle":' JsonStr(c.HasProp("favTitle") ? c.favTitle : "") ","
    out .= '"favGroup":' JsonStr(c.HasProp("favGroup") ? c.favGroup : "") ","
    out .= '"srcIcon":' JsonStr(c.HasProp("srcIcon") ? c.srcIcon : "") ","
    out .= '"srcExe":' JsonStr(c.HasProp("srcExe") ? c.srcExe : "") ","
    out .= '"srcTitle":' JsonStr(c.HasProp("srcTitle") ? c.srcTitle : "") ","
    out .= '"isMd":' ((c.HasProp("isMd") && c.isMd) ? "true" : "false") ","
    out .= '"isRich":' ((c.HasProp("isRich") && c.isRich) ? "true" : "false") ","
    out .= '"preview":' JsonStr(preview) ","
    out .= '"data":' JsonStr(data)
    out .= "}"
    return out
}

JsonParse(text) {
    doc := ComObject("HTMLFile")
    doc.write("<meta http-equiv='X-UA-Compatible' content='IE=Edge'>")
    return doc.parentWindow.JSON.parse(text)
}

JsonArrayToAhk(arr) {
    result := []
    try n := Integer(arr.length)
    catch
        return result
    loop n {
        idx := A_Index - 1
        jo := ""
        try jo := arr[idx]
        catch {
            try jo := arr.%idx%
        }
        if !IsObject(jo)
            continue
        result.Push(jo)
    }
    return result
}

NextClipUid() {
    global clipUidSeq
    clipUidSeq += 1
    return clipUidSeq
}

ParseJoToItem(jo, &dirty := false, light := false) {
    global STORE_DIR, PAYLOAD_DIR, clipUidSeq
    item := {}
    try item.uid := Integer(jo.uid || 0)
    catch
        item.uid := 0
    if item.uid < 1 {
        item.uid := ++clipUidSeq
        dirty := true
    } else if item.uid > clipUidSeq {
        clipUidSeq := item.uid
    }
    item.type := String(jo.type)
    item.time := String(jo.time)
    item.pinned := (jo.pinned = true || jo.pinned = 1)
    try item.pinTime := String(jo.pinTime || "")
    catch
        item.pinTime := ""
    try
        item.pasted := (jo.pasted = true || jo.pasted = 1)
    catch
        item.pasted := false
    try item.queueGroup := Integer(jo.queueGroup || 0)
    catch
        item.queueGroup := 0
    try item.queueIndex := Integer(jo.queueIndex || 0)
    catch
        item.queueIndex := 0
    NoteQueueGroupFromItem(item)
    ApplyQueueMetaToItem(item)
    item.charCount := Integer(jo.charCount || 0)
    item.fileCount := Integer(jo.fileCount || 0)
    item.width := Integer(jo.width || 0)
    item.height := Integer(jo.height || 0)
    item.preview := String(jo.preview || "")
    item.imgFile := String(jo.imgFile || "")
    try item.dataFile := String(jo.dataFile || "")
    catch
        item.dataFile := ""
    try item.linkTitle := String(jo.linkTitle || "")
    catch
        item.linkTitle := ""
    try item.linkHost := String(jo.linkHost || "")
    catch
        item.linkHost := ""
    try item.favTitle := String(jo.favTitle || "")
    catch
        item.favTitle := ""
    try item.favGroup := String(jo.favGroup || "")
    catch
        item.favGroup := ""
    try item.srcIcon := String(jo.srcIcon || "")
    catch
        item.srcIcon := ""
    try item.srcExe := String(jo.srcExe || "")
    catch
        item.srcExe := ""
    try item.srcTitle := String(jo.srcTitle || "")
    catch
        item.srcTitle := ""
    try item.isMd := (jo.isMd = true || jo.isMd = 1)
    catch
        item.isMd := false
    try item.isRich := (jo.isRich = true || jo.isRich = 1)
    catch
        item.isRich := false
    if !item.isMd && (item.type = "text" || item.type = "link")
        item.isMd := TextLooksLikeMarkdown(item.preview != "" ? item.preview : String(jo.data || ""))
    if item.type = "image" {
        if item.imgFile = "" {
            raw := String(jo.data || "")
            if InStr(raw, "base64,") {
                item.imgFile := SaveImageToStore(raw)
                dirty := true
            }
        }
        if item.imgFile = "" || !FileExist(STORE_DIR "\" item.imgFile)
            return ""
        item.data := ""
    } else {
        if item.dataFile != "" {
            ; List/query path: keep preview only —full body loaded on paste/resolve
            if light {
                item.data := ""
            } else {
                p := PAYLOAD_DIR "\" item.dataFile
                if FileExist(p)
                    item.data := FileRead(p, "UTF-8")
                else
                    item.data := String(jo.data || "")
            }
        } else
            item.data := String(jo.data || "")
        if item.preview = "" && (item.type = "text" || item.type = "link")
            item.preview := SubStr(item.data, 1, 300)
    }
    if item.type = "link" && item.linkHost = ""
        item.linkHost := HostOfUrl(item.data)
    return item
}

ParseNdjsonLine(line, &dirty := false, light := false) {
    line := Trim(line, " `t`r`n")
    if line = "" || SubStr(line, 1, 1) != "{"
        return ""
    ; List/query path: regex extract  — avoid HTMLFile COM JSON (very slow per line)
    if light
        return ParseNdjsonLineFast(line)
    try
        return ParseJoToItem(JsonParse(line), &dirty, false)
    catch
        return ""
}

; Fast list-item parse from our own ItemToJsonLine format (no COM)
ParseNdjsonLineFast(line) {
    global clipUidSeq
    item := {}
    item.uid := JsonFieldInt(line, "uid")
    if item.uid < 1
        return ""
    if item.uid > clipUidSeq
        clipUidSeq := item.uid
    item.type := JsonFieldStr(line, "type")
    if item.type = ""
        return ""
    item.time := JsonFieldStr(line, "time")
    item.pinned := JsonFieldBool(line, "pinned")
    item.pinTime := JsonFieldStr(line, "pinTime")
    item.pasted := JsonFieldBool(line, "pasted")
    item.queueGroup := JsonFieldInt(line, "queueGroup")
    item.queueIndex := JsonFieldInt(line, "queueIndex")
    ApplyQueueMetaToItem(item)
    NoteQueueGroupFromItem(item)
    item.charCount := JsonFieldInt(line, "charCount")
    item.fileCount := JsonFieldInt(line, "fileCount")
    item.width := JsonFieldInt(line, "width")
    item.height := JsonFieldInt(line, "height")
    item.preview := JsonFieldStr(line, "preview")
    item.imgFile := JsonFieldStr(line, "imgFile")
    item.dataFile := JsonFieldStr(line, "dataFile")
    item.linkTitle := JsonFieldStr(line, "linkTitle")
    item.linkHost := JsonFieldStr(line, "linkHost")
    item.favTitle := JsonFieldStr(line, "favTitle")
    item.favGroup := JsonFieldStr(line, "favGroup")
    item.srcIcon := JsonFieldStr(line, "srcIcon")
    item.srcExe := JsonFieldStr(line, "srcExe")
    item.srcTitle := JsonFieldStr(line, "srcTitle")
    item.isMd := JsonFieldBool(line, "isMd")
    item.isRich := JsonFieldBool(line, "isRich")
    if item.type = "image" {
        item.data := ""
        ; Keep rows even without imgFile (persist race / save failure). Dropping them
        ; made the image tab look empty until a later rescan found repaired files.
    } else if item.dataFile != "" {
        ; Large body on disk —load only when pasting
        item.data := ""
        if item.type = "file"
            item._looksImage := PreviewLooksLikeImagePath(item.preview)
        if !item.isMd && (item.type = "text" || item.type = "link")
            item.isMd := TextLooksLikeMarkdown(item.preview)
    } else {
        ; Inline body (small) kept in memory for instant paste
        item.data := JsonFieldStr(line, "data")
        if item.preview = "" && (item.type = "text" || item.type = "link" || item.type = "file")
            item.preview := SubStr(item.data, 1, 500)
        ; 修复：file 缩略图曾误清 data，preview 仍在 → 读回时还原路径
        if item.type = "file" && item.data = "" && item.preview != ""
            item.data := item.preview
        if !item.isMd && (item.type = "text" || item.type = "link")
            item.isMd := TextLooksLikeMarkdown(item.preview != "" ? item.preview : item.data)
        if item.type = "file"
            item._looksImage := PreviewLooksLikeImagePath(item.preview != "" ? item.preview : item.data)
    }
    return item
}

PreviewLooksLikeImagePath(raw) {
    static imgExt := " png jpg jpeg gif webp bmp ico tif tiff svg "
    raw := Trim(String(raw))
    if raw = ""
        return false
    ; Only check first path line —enough for list bucketing
    ln := Trim(StrSplit(raw, "`n", "`r")[1])
    if (SubStr(ln, 1, 1) = '"' && SubStr(ln, -1) = '"')
        || (SubStr(ln, 1, 1) = "'" && SubStr(ln, -1) = "'")
        ln := Trim(SubStr(ln, 2, StrLen(ln) - 2))
    SplitPath ln, , , &ext
    ext := StrLower(ext)
    return ext != "" && InStr(imgExt, " " ext " ")
}

; 路径列表是否全是图片文件（Explorer 右键复制单/多张图）
ClipboardPathsAllImage(names) {
    if !IsObject(names) || names.Length < 1
        return false
    for ln in names {
        if !PreviewLooksLikeImagePath(ln)
            return false
    }
    return true
}

; 剪贴板当前是否仅为图片文件的 CF_HDROP（常伴随位图/DIB 再触发一次）
ClipboardHasOnlyImageFiles() {
    if !DllCall("IsClipboardFormatAvailable", "UInt", 15, "Int")
        return false
    return ClipboardPathsAllImage(GetClipboardFileList())
}

; 位图先到、文件路径后到时：去掉刚写入的 image 条，只保留 file
MemoryDropBurstFrontImage(maxAgeMs := 900) {
    global lastClipImageAt, liveFront, clips
    if !lastClipImageAt || (A_TickCount - lastClipImageAt) > maxAgeMs
        return false
    for src in [liveFront, clips] {
        if !IsObject(src) || src.Length < 1
            continue
        c := src[1]
        if !IsObject(c) || c.type != "image"
            continue
        MemoryRemoveUid(c.uid)
        ClipLog("MemoryDropBurstFrontImage uid=" c.uid)
        RequestUiPush()
        return true
    }
    return false
}

JsonFieldInt(line, key) {
    if RegExMatch(line, '"' key '"\s*:\s*(-?\d+)', &m)
        return Integer(m[1])
    return 0
}
JsonFieldBool(line, key) {
    if RegExMatch(line, '"' key '"\s*:\s*(true|false|1|0)', &m)
        return (m[1] = "true" || m[1] = "1")
    return false
}
JsonFieldStr(line, key) {
    if !RegExMatch(line, '"' key '"\s*:\s*"((?:\\.|[^"\\])*)"', &m)
        return ""
    s := m[1]
    out := ""
    i := 1
    len := StrLen(s)
    while i <= len {
        ch := SubStr(s, i, 1)
        if ch = "\" && i < len {
            n := SubStr(s, i + 1, 1)
            switch n {
                case "n": out .= "`n"
                case "r": out .= "`r"
                case "t": out .= "`t"
                case '"': out .= '"'
                case "\": out .= "\"
                case "/": out .= "/"
                default: out .= n
            }
            i += 2
        } else {
            out .= ch
            i += 1
        }
    }
    return out
}

EnsurePagesDir() {
    global PAGES_DIR
    try DirCreate PAGES_DIR
}

LoadManifest() {
    global MANIFEST_FILE, clipUidSeq
    EnsurePagesDir()
    m := Map("uidSeq", clipUidSeq, "nextPage", 1, "pages", [])
    if !FileExist(MANIFEST_FILE)
        return RepairManifestPages(m)
    try {
        raw := FileRead(MANIFEST_FILE, "UTF-8")
        if RegExMatch(raw, '"uidSeq"\s*:\s*(\d+)', &mm)
            m["uidSeq"] := Integer(mm[1])
        if RegExMatch(raw, '"nextPage"\s*:\s*(\d+)', &mm)
            m["nextPage"] := Integer(mm[1])
        ; Do NOT use HTMLFile JSON array parse —it often returns incomplete pages and
        ; the next SaveManifest then orphans older shards.
        pages := []
        if RegExMatch(raw, '"pages"\s*:\s*\[([\s\S]*?)\]', &pm) {
            pos := 1
            while RegExMatch(pm[1], '"([^"]+)"', &qm, pos) {
                pages.Push(qm[1])
                pos := qm.Pos + qm.Len
            }
        }
        m["pages"] := pages
        if Integer(m["uidSeq"]) > clipUidSeq
            clipUidSeq := Integer(m["uidSeq"])
    } catch {
    }
    ; 读盘时也修补：双实例/异常写入可能导致 pages 被截断，读时必须找回 orphan shard
    return RepairManifestPages(m)
}

; Re-attach orphaned p_*.ndjson files dropped by a bad manifest rewrite
RepairManifestPages(m) {
    global PAGES_DIR
    EnsurePagesDir()
    onDisk := []
    loop files PAGES_DIR "\p_*.ndjson" {
        num := 0
        if RegExMatch(A_LoopFileName, "i)p_(\d+)\.ndjson", &nm)
            num := Integer(nm[1])
        onDisk.Push({ name: A_LoopFileName, num: num, t: String(A_LoopFileTimeModified) })
    }
    if onDisk.Length = 0 {
        m["pages"] := []
        return m
    }
    ; newest modified first; tie-break by higher page number (numeric)
    loop onDisk.Length - 1 {
        loop onDisk.Length - A_Index {
            j := A_Index
            a := onDisk[j]
            b := onDisk[j + 1]
            swap := false
            if a.t < b.t
                swap := true
            else if a.t = b.t && a.num < b.num
                swap := true
            if swap {
                onDisk[j] := b
                onDisk[j + 1] := a
            }
        }
    }
    known := Map()
    valid := 0
    for name in (m.Has("pages") ? m["pages"] : []) {
        if FileExist(PagePath(name))
            valid += 1, known[name] := true
    }
    ; Rebuild from disk when manifest missing files
    if valid != onDisk.Length {
        pages := []
        for f in onDisk
            pages.Push(f.name)
        m["pages"] := pages
    } else {
        pages := []
        seen := Map()
        for name in m["pages"] {
            if !FileExist(PagePath(name)) || seen.Has(name)
                continue
            seen[name] := true
            pages.Push(name)
        }
        m["pages"] := pages
    }
    maxN := Integer(m["nextPage"])
    for name in m["pages"] {
        if RegExMatch(name, "i)p_(\d+)\.ndjson", &nm) {
            n := Integer(nm[1]) + 1
            if n > maxN
                maxN := n
        }
    }
    m["nextPage"] := maxN
    return m
}

SaveManifest(m) {
    global MANIFEST_FILE
    EnsurePagesDir()
    ; Always re-attach orphan shards before writing  — never shrink pages to one new file
    m := RepairManifestPages(m)
    pages := m.Has("pages") ? m["pages"] : []
    ; de-dupe while preserving order
    seen := Map()
    clean := []
    for p in pages {
        p := String(p)
        if p = "" || seen.Has(p)
            continue
        if !FileExist(PagePath(p))
            continue
        seen[p] := true
        clean.Push(p)
    }
    pages := clean
    m["pages"] := pages
    out := "{"
    out .= '"uidSeq":' Integer(m.Has("uidSeq") ? m["uidSeq"] : 0) ","
    out .= '"nextPage":' Integer(m.Has("nextPage") ? m["nextPage"] : 1) ","
    out .= '"pages":['
    for i, p in pages {
        if i > 1
            out .= ","
        out .= JsonStr(p)
    }
    out .= "]}"
    AtomicWriteText(MANIFEST_FILE, out)
}

; Write via tmp + MoveFileEx(REPLACE)  — never delete the live file first (crash = data loss)
AtomicWriteText(path, text) {
    tmp := path ".tmp"
    try {
        if FileExist(tmp)
            FileDelete tmp
        FileAppend text, tmp, "UTF-8"
        if !FileExist(tmp)
            return false
        ; MOVEFILE_REPLACE_EXISTING = 1
        if DllCall("MoveFileExW", "WStr", tmp, "WStr", path, "UInt", 1) {
            return true
        }
        ; Fallback: keep original if replace fails
        try FileDelete tmp
    } catch {
    }
    return false
}

PagePath(name) {
    global PAGES_DIR
    return PAGES_DIR "\" name
}

ReadPageFile(name, light := false) {
    result := []
    if name = ""
        return result
    path := PagePath(name)
    if !FileExist(path)
        return result
    try {
        dirty := false
        loop read path, "UTF-8" {
            item := ParseNdjsonLine(A_LoopReadLine, &dirty, light)
            if IsObject(item)
                result.Push(item)
        }
        ; Do NOT auto-rewrite on dirty/partial parse —that wiped shards when any line failed
    } catch {
    }
    return result
}

WritePageFile(name, items) {
    path := PagePath(name)
    EnsurePagesDir()
    text := ""
    for c in items
        text .= ItemToJsonLine(c) "`n"
    AtomicWriteText(path, text)
}

; Count non-empty lines without JSON-parsing (rewrite must not drop unparsable history)
CountPageLines(name) {
    n := 0
    path := PagePath(name)
    if name = "" || !FileExist(path)
        return 0
    try {
        loop read path, "UTF-8" {
            if Trim(A_LoopReadLine, " `t`r`n") != ""
                n += 1
        }
    } catch {
    }
    return n
}

; Prepend one NDJSON line without re-parsing the shard (avoids silent data loss)
PrependPageLine(name, line) {
    path := PagePath(name)
    EnsurePagesDir()
    tmp := path ".tmp"
    try {
        if FileExist(tmp)
            FileDelete tmp
        line := String(line)
        if SubStr(line, -1) != "`n"
            line .= "`n"
        existing := ""
        if FileExist(path)
            existing := FileRead(path, "UTF-8")
        FileAppend line existing, tmp, "UTF-8"
        if !FileExist(tmp)
            return false
        if DllCall("MoveFileExW", "WStr", tmp, "WStr", path, "UInt", 1)
            return true
        try FileDelete tmp
    } catch {
        try {
            if FileExist(tmp)
                FileDelete tmp
        }
    }
    return false
}

NewPageName(m) {
    n := Integer(m["nextPage"])
    m["nextPage"] := n + 1
    return Format("p_{:06}.ndjson", n)
}

DiskInsertFront(item) {
    global PAGE_SIZE, clipUidSeq
    ; No Critical here —disk jobs are already serialized by DrainDiskJobs.
    ; Critical blocked OnClipboardChange and made copies "appear one behind".
    try {
        ClipLog("DiskInsertFront begin uid=" (item.HasProp("uid") ? item.uid : 0))
        ; Strip non-serializable / huge clipboard blobs before touching disk
        try item.DeleteProp("clipAll")
        m := LoadManifest()
        m := RepairManifestPages(m)
        pages := m["pages"]
        ClipLog("DiskInsertFront pages=" pages.Length " next=" m["nextPage"])
        if !item.HasProp("uid") || !item.uid
            item.uid := NextClipUid()
        if item.uid > clipUidSeq
            clipUidSeq := item.uid
        m["uidSeq"] := Max(Integer(m["uidSeq"]), clipUidSeq)

        firstCount := pages.Length ? CountPageLines(pages[1]) : 0
        ClipLog("DiskInsertFront firstCount=" firstCount " page0=" (pages.Length ? pages[1] : ""))
        if pages.Length = 0 || firstCount >= PAGE_SIZE {
            name := NewPageName(m)
            ClipLog("DiskInsertFront newPage=" name)
            WritePageFile(name, [item])
            pages.InsertAt(1, name)
            m["pages"] := pages
            SaveManifest(m)
            ClipLog("DiskInsertFront saved newPage")
            return true
        }
        ; Prepend raw line  — never parse+rewrite (one bad line used to wipe the whole shard)
        ClipLog("DiskInsertFront PrependPageLine " pages[1])
        if PrependPageLine(pages[1], ItemToJsonLine(item)) {
            m["pages"] := pages
            SaveManifest(m)
            ClipLog("DiskInsertFront prepend OK")
            return true
        }
        ; Prepend failed: new shard only —keep existing pages intact
        name := NewPageName(m)
        ClipLog("DiskInsertFront prepend FAIL →newPage=" name)
        WritePageFile(name, [item])
        pages.InsertAt(1, name)
        m["pages"] := pages
        SaveManifest(m)
        ClipLog("DiskInsertFront saved fallback page")
        return true
    } catch as e {
        ClipLogErr("DiskInsertFront", e)
        return false
    }
}

DiskRemoveUid(uid) {
    uid := Integer(uid)
    m := LoadManifest()
    pages := m["pages"]
    removed := ""
    newPages := []
    n := 0
    for name in pages {
        if IsObject(removed) {
            newPages.Push(name)
            continue
        }
        ; light 足够定位 uid / imgFile / dataFile，避免删一条扫全文
        items := ReadPageFile(name, true)
        kept := []
        changed := false
        for c in items {
            if c.uid = uid {
                removed := c
                changed := true
            } else
                kept.Push(c)
            if Mod(++n, 64) = 0
                Sleep(-1)
        }
        if !changed {
            newPages.Push(name)
            continue
        }
        if kept.Length {
            WritePageFile(name, kept)
            newPages.Push(name)
        } else {
            try FileDelete PagePath(name)
        }
    }
    if IsObject(removed) {
        m["pages"] := newPages
        SaveManifest(m)
    }
    return removed
}

; Remove text-equal rows (prefer keep pinned meta). Must stay fast — full-page
; heavy reads used to block the AHK thread ~30s → busy cursor + dead ^+c.
DiskRemoveTextEqual(text) {
    global PAYLOAD_DIR
    text := String(text)
    textLen := StrLen(text)
    if textLen < 1
        return ""
    m := LoadManifest()
    pages := m["pages"]
    newPages := []
    changedAny := false
    best := ""
    ; Newest shards first; scanning all 100+ pages with full payload freezes UI
    maxScan := Min(pages.Length, 24)
    i := 1
    while i <= pages.Length {
        name := pages[i]
        if i > maxScan {
            newPages.Push(name)
            i += 1
            continue
        }
        light := ReadPageFile(name, true)
        kill := Map()
        for c in light {
            if !(IsObject(c) && c.type = "text")
                continue
            cc := (c.HasProp("charCount") ? Integer(c.charCount) : -1)
            if cc >= 0 && cc != textLen
                continue
            body := ""
            full := ""
            if c.HasProp("data") && c.data != ""
                body := String(c.data)
            else if c.HasProp("dataFile") && c.dataFile != "" {
                try body := FileRead(PAYLOAD_DIR "\" c.dataFile, "UTF-8")
            } else {
                full := DiskLoadUid(c.uid)
                if IsObject(full) && full.HasProp("data")
                    body := String(full.data)
            }
            if body = "" || body != text
                continue
            kill[Integer(c.uid)] := true
            cand := IsObject(full) ? full : c
            if !IsObject(best) || (cand.HasProp("pinned") && cand.pinned && !(best.HasProp("pinned") && best.pinned))
                best := cand
        }
        if kill.Count < 1 {
            newPages.Push(name)
            i += 1
            Sleep 0
            continue
        }
        ; Rewrite from light rows (dataFile / inline data preserved by fast parse)
        kept := []
        for c in light {
            uid := Integer(c.uid)
            if kill.Has(uid) {
                DeletePayloadFile(c)
                changedAny := true
            } else
                kept.Push(c)
        }
        if kept.Length {
            WritePageFile(name, kept)
            newPages.Push(name)
        } else {
            try FileDelete PagePath(name)
        }
        i += 1
        Sleep 0  ; yield so hotkeys / ^+c are not starved
    }
    if changedAny {
        m["pages"] := newPages
        SaveManifest(m)
    }
    return best
}

; 文件条目比较键：路径规范化（大小写/斜杠），多文件按行拼接
FileClipKey(data) {
    raw := String(data)
    if raw = ""
        return ""
    lines := []
    for ln in StrSplit(raw, "`n", "`r") {
        p := Trim(ln)
        if p = ""
            continue
        p := StrReplace(p, "/", "\")
        while InStr(p, "\\")
            p := StrReplace(p, "\\", "\")
        lines.Push(StrLower(p))
    }
    if lines.Length = 0
        return ""
    out := ""
    for i, p in lines
        out .= (i > 1 ? "`n" : "") p
    return out
}

FileClipDataEqual(a, b) {
    ka := FileClipKey(a)
    if ka = ""
        return false
    return ka = FileClipKey(b)
}

; 同路径文件去重（内存）；优先保留已收藏条目的元数据
MemoryTakeFileEqual(data) {
    global clips, viewTotal, viewCache, liveFront
    key := FileClipKey(data)
    if key = ""
        return ""
    best := ""
    matches := []
    for c in clips {
        if IsObject(c) && c.type = "file" && FileClipKey(c.HasProp("data") ? c.data : "") = key
            matches.Push(c)
    }
    for c in matches {
        if !IsObject(best) || (c.HasProp("pinned") && c.pinned && !(best.HasProp("pinned") && best.pinned))
            best := c
        MemoryRemoveUid(c.uid)
    }
    if IsObject(viewCache) {
        for cacheKey, entry in viewCache {
            if !IsObject(entry) || !entry.HasProp("items")
                continue
            i := 1
            while i <= entry.items.Length {
                c := entry.items[i]
                if IsObject(c) && c.type = "file" && FileClipKey(c.HasProp("data") ? c.data : "") = key {
                    if !IsObject(best) || (c.HasProp("pinned") && c.pinned && !(best.HasProp("pinned") && best.pinned))
                        best := c
                    entry.items.RemoveAt(i)
                    entry.total := Max(0, entry.total - 1)
                } else
                    i += 1
            }
        }
    }
    if IsObject(liveFront) {
        i := 1
        while i <= liveFront.Length {
            c := liveFront[i]
            if IsObject(c) && c.type = "file" && FileClipKey(c.HasProp("data") ? c.data : "") = key {
                if !IsObject(best) || (c.HasProp("pinned") && c.pinned && !(best.HasProp("pinned") && best.pinned))
                    best := c
                liveFront.RemoveAt(i)
            } else
                i += 1
        }
    }
    return best
}

DiskRemoveFileEqual(data) {
    global PAYLOAD_DIR
    key := FileClipKey(data)
    if key = ""
        return ""
    m := LoadManifest()
    pages := m["pages"]
    newPages := []
    changedAny := false
    best := ""
    maxScan := Min(pages.Length, 24)
    i := 1
    while i <= pages.Length {
        name := pages[i]
        if i > maxScan {
            newPages.Push(name)
            i += 1
            continue
        }
        light := ReadPageFile(name, true)
        kill := Map()
        for c in light {
            if !(IsObject(c) && c.type = "file")
                continue
            body := ""
            if c.HasProp("data") && c.data != ""
                body := String(c.data)
            else if c.HasProp("preview") && c.preview != ""
                body := String(c.preview)
            else if c.HasProp("dataFile") && c.dataFile != "" {
                try body := FileRead(PAYLOAD_DIR "\" c.dataFile, "UTF-8")
            }
            if body = "" || FileClipKey(body) != key
                continue
            kill[Integer(c.uid)] := true
            if !IsObject(best) || (c.HasProp("pinned") && c.pinned && !(best.HasProp("pinned") && best.pinned))
                best := c
        }
        if kill.Count < 1 {
            newPages.Push(name)
            i += 1
            Sleep 0
            continue
        }
        kept := []
        for c in light {
            uid := Integer(c.uid)
            if kill.Has(uid) {
                DeletePayloadFile(c)
                changedAny := true
            } else
                kept.Push(c)
        }
        if kept.Length {
            WritePageFile(name, kept)
            newPages.Push(name)
        } else {
            try FileDelete PagePath(name)
        }
        i += 1
        Sleep 0
    }
    if changedAny {
        m["pages"] := newPages
        SaveManifest(m)
    }
    return best
}

DiskTakeLinkEqual(url) {
    m := LoadManifest()
    pages := m["pages"]
    taken := ""
    newPages := []
    for name in pages {
        if IsObject(taken) {
            newPages.Push(name)
            continue
        }
        items := ReadPageFile(name)
        kept := []
        changed := false
        for c in items {
            if c.type = "link" && c.data = url {
                taken := c
                changed := true
            } else
                kept.Push(c)
        }
        if !changed {
            newPages.Push(name)
            continue
        }
        if kept.Length {
            WritePageFile(name, kept)
            newPages.Push(name)
        } else {
            try FileDelete PagePath(name)
        }
    }
    if IsObject(taken) {
        m["pages"] := newPages
        SaveManifest(m)
    }
    return taken
}

DiskSetLinkTitle(url, title) {
    m := LoadManifest()
    for name in m["pages"] {
        items := ReadPageFile(name)
        changed := false
        for c in items {
            if c.type = "link" && c.data = url {
                c.linkTitle := title
                changed := true
                break
            }
        }
        if changed {
            WritePageFile(name, items)
            return true
        }
    }
    return false
}

DiskSetPinned(uid, pinned, pinTime := "") {
    ; Patch NDJSON line in place  — avoid full parse/rewrite (async race broke 收藏)
    uid := Integer(uid)
    pinned := !!pinned
    flag := pinned ? "true" : "false"
    if pinned {
        if pinTime = ""
            pinTime := FormatTime(, "yyyy-MM-dd HH:mm:ss")
    } else
        pinTime := ""
    pinJson := JsonStr(pinTime)
    m := LoadManifest()
    for name in m["pages"] {
        path := PagePath(name)
        if !FileExist(path)
            continue
        newText := ""
        changed := false
        found := false
        try {
            loop read path, "UTF-8" {
                line := A_LoopReadLine
                if !found && JsonFieldInt(line, "uid") = uid {
                    found := true
                    nl := line
                    if RegExMatch(nl, '"pinned"\s*:')
                        nl := RegExReplace(nl, '"pinned"\s*:\s*(true|false|1|0)', '"pinned":' flag, &_cnt, 1)
                    else
                        nl := RegExReplace(nl, "\}$", ',"pinned":' flag "}")
                    if RegExMatch(nl, '"pinTime"\s*:')
                        nl := RegExReplace(nl, '"pinTime"\s*:\s*"(?:\\.|[^"\\])*"', '"pinTime":' pinJson, &_cnt, 1)
                    else
                        nl := RegExReplace(nl, '"pinned"\s*:\s*(true|false|1|0)', '"pinned":' flag ',"pinTime":' pinJson, &_cnt, 1)
                    if nl != line {
                        line := nl
                        changed := true
                    }
                }
                newText .= line "`n"
            }
        } catch {
            continue
        }
        if changed {
            tmp := path ".tmp"
            try {
                if FileExist(tmp)
                    FileDelete tmp
                FileAppend newText, tmp, "UTF-8"
                if FileExist(path)
                    FileDelete path
                FileMove tmp, path
            } catch {
            }
            return true
        }
        if found
            return true
    }
    return false
}

DiskSetFavTitle(uid, title := "") {
    uid := Integer(uid)
    titleJson := JsonStr(Trim(String(title)))
    m := LoadManifest()
    for name in m["pages"] {
        path := PagePath(name)
        if !FileExist(path)
            continue
        newText := ""
        changed := false
        found := false
        try {
            loop read path, "UTF-8" {
                line := A_LoopReadLine
                if !found && JsonFieldInt(line, "uid") = uid {
                    found := true
                    nl := line
                    if RegExMatch(nl, '"favTitle"\s*:')
                        nl := RegExReplace(nl, '"favTitle"\s*:\s*"(?:\\.|[^"\\])*"', '"favTitle":' titleJson, &_cnt, 1)
                    else
                        nl := RegExReplace(nl, "\}$", ',"favTitle":' titleJson "}")
                    if nl != line {
                        line := nl
                        changed := true
                    }
                }
                newText .= line "`n"
            }
        } catch {
            continue
        }
        if changed {
            tmp := path ".tmp"
            try {
                if FileExist(tmp)
                    FileDelete tmp
                FileAppend newText, tmp, "UTF-8"
                if FileExist(path)
                    FileDelete path
                FileMove tmp, path
            } catch {
            }
            return true
        }
        if found
            return true
    }
    return false
}

DiskSetFavGroup(uid, gid := "") {
    uid := Integer(uid)
    gidJson := JsonStr(Trim(String(gid)))
    m := LoadManifest()
    for name in m["pages"] {
        path := PagePath(name)
        if !FileExist(path)
            continue
        newText := ""
        changed := false
        found := false
        try {
            loop read path, "UTF-8" {
                line := A_LoopReadLine
                if !found && JsonFieldInt(line, "uid") = uid {
                    found := true
                    nl := line
                    if RegExMatch(nl, '"favGroup"\s*:')
                        nl := RegExReplace(nl, '"favGroup"\s*:\s*"(?:\\.|[^"\\])*"', '"favGroup":' gidJson, &_cnt, 1)
                    else
                        nl := RegExReplace(nl, "\}$", ',"favGroup":' gidJson "}")
                    if nl != line {
                        line := nl
                        changed := true
                    }
                }
                newText .= line "`n"
            }
        } catch {
            continue
        }
        if changed {
            tmp := path ".tmp"
            try {
                if FileExist(tmp)
                    FileDelete tmp
                FileAppend newText, tmp, "UTF-8"
                if FileExist(path)
                    FileDelete path
                FileMove tmp, path
            } catch {
            }
            return true
        }
        if found
            return true
    }
    return false
}

; Favorites sort key: pinTime (when favorited), else create time
ClipPinSortKey(c) {
    if !IsObject(c)
        return ""
    if c.HasProp("pinTime") && c.pinTime != ""
        return String(c.pinTime)
    return c.HasProp("time") ? String(c.time) : ""
}

SortPinnedClipsDesc(arr) {
    ; Newest favorite first (pinTime / time descending)
    n := arr.Length
    i := 2
    while i <= n {
        key := arr[i]
        keySort := ClipPinSortKey(key)
        j := i - 1
        while j >= 1 && StrCompare(ClipPinSortKey(arr[j]), keySort) < 0 {
            arr[j + 1] := arr[j]
            j -= 1
        }
        arr[j + 1] := key
        i += 1
    }
}

DiskSetPasted(wantMap, pasted) {
    ; Patch NDJSON lines in place —do NOT full-parse / load payloads (that froze paste)
    m := LoadManifest()
    changedAny := false
    left := wantMap.Count
    flag := pasted ? "true" : "false"
    for name in m["pages"] {
        if left < 1
            break
        path := PagePath(name)
        if !FileExist(path)
            continue
        newText := ""
        changed := false
        try {
            loop read path, "UTF-8" {
                line := A_LoopReadLine
                if left > 0 {
                    uid := JsonFieldInt(line, "uid")
                    if uid > 0 && wantMap.Has(uid) {
                        if RegExMatch(line, '"pasted"\s*:')
                            nl := RegExReplace(line, '"pasted"\s*:\s*(true|false|1|0)', '"pasted":' flag, &_cnt, 1)
                        else
                            nl := RegExReplace(line, "\}$", ',"pasted":' flag "}")
                        if nl != line {
                            line := nl
                            changed := true
                            changedAny := true
                        }
                        left -= 1
                    }
                }
                newText .= line "`n"
            }
        } catch {
            continue
        }
        if changed {
            tmp := path ".tmp"
            try {
                if FileExist(tmp)
                    FileDelete tmp
                FileAppend newText, tmp, "UTF-8"
                if FileExist(path)
                    FileDelete path
                FileMove tmp, path
            } catch {
            }
        }
    }
    return changedAny
}

; Persist queueGroup/queueIndex onto NDJSON so UI lines survive script restart
DiskSetQueueMeta(uid, queueGroup, queueIndex) {
    uid := Integer(uid)
    queueGroup := Integer(queueGroup)
    queueIndex := Integer(queueIndex)
    if uid < 1
        return false
    m := LoadManifest()
    for name in m["pages"] {
        path := PagePath(name)
        if !FileExist(path)
            continue
        newText := ""
        changed := false
        try {
            loop read path, "UTF-8" {
                line := A_LoopReadLine
                lineUid := JsonFieldInt(line, "uid")
                if lineUid = uid {
                    nl := line
                    if RegExMatch(nl, '"queueGroup"\s*:')
                        nl := RegExReplace(nl, '"queueGroup"\s*:\s*-?\d+', '"queueGroup":' queueGroup, &_c1, 1)
                    else
                        nl := RegExReplace(nl, "\}$", ',"queueGroup":' queueGroup "}")
                    if RegExMatch(nl, '"queueIndex"\s*:')
                        nl := RegExReplace(nl, '"queueIndex"\s*:\s*-?\d+', '"queueIndex":' queueIndex, &_c2, 1)
                    else
                        nl := RegExReplace(nl, "\}$", ',"queueIndex":' queueIndex "}")
                    if nl != line {
                        line := nl
                        changed := true
                    }
                }
                newText .= line "`n"
            }
        } catch {
            continue
        }
        if changed {
            tmp := path ".tmp"
            try {
                if FileExist(tmp)
                    FileDelete tmp
                FileAppend newText, tmp, "UTF-8"
                if FileExist(path)
                    FileDelete path
                FileMove tmp, path
                return true
            } catch {
            }
        }
    }
    return false
}

DiskClearTab(tab, clearAllDates, today) {
    InvalidateViewCache()
    m := LoadManifest()
    newPages := []
    n := 0
    for name in m["pages"] {
        ; light=true：不要加载全文 payload，否则清空会卡死
        items := ReadPageFile(name, true)
        kept := []
        for c in items {
            drop := ItemShouldClear(c, tab, clearAllDates, today)
            if drop {
                try DeleteStoredImage(c)
                try DeletePayloadFile(c)
            } else
                kept.Push(c)
            if Mod(++n, 40) = 0
                Sleep(-1)
        }
        if kept.Length {
            WritePageFile(name, kept)
            newPages.Push(name)
        } else {
            try FileDelete PagePath(name)
        }
    }
    m["pages"] := newPages
    SaveManifest(m)
}

FileClipLooksLikeImage(c) {
    if !IsObject(c)
        return false
    if c.HasProp("_looksImage")
        return !!c._looksImage
    ; Thumb created from an image path
    if c.HasProp("imgFile") && c.imgFile != "" {
        n := StrLower(String(c.imgFile))
        if InStr(n, "fimg_") = 1 || RegExMatch(n, "i)\.(png|jpe?g|gif|webp|bmp|ico|tiff?|svg)$")
            return true
    }
    raw := ""
    if c.HasProp("data")
        raw := String(c.data)
    if raw = "" && c.HasProp("preview")
        raw := String(c.preview)
    return PreviewLooksLikeImagePath(raw)
}

; Tab / today filter only (no search query)
ItemMatchesTabToday(c, tab, todayOnly) {
    if !IsObject(c)
        return false
    type := StrLower(String(c.type))
    tab := StrLower(Trim(String(tab)))
    if todayOnly {
        t := c.HasProp("time") ? String(c.time) : ""
        if SubStr(t, 1, 10) != FormatTime(, "yyyy-MM-dd")
            return false
    }
    switch tab {
        case "text", "link":
            if type != tab
                return false
        case "image":
            if type = "image" {
            } else if type = "file" && FileClipLooksLikeImage(c) {
            } else
                return false
        case "file":
            if type != "file"
                return false
        case "recent":
            if type != "recent"
                return false
        case "pinned":
            if !(c.HasProp("pinned") && c.pinned)
                return false
        default:
            if type = "link" || type = "recent"
                return false
    }
    return true
}

; Lowercased hay for list search (preview / title fields only)
ClipSearchHay(c) {
    if !IsObject(c)
        return ""
    type := StrLower(String(c.type))
    favTitle := c.HasProp("favTitle") ? String(c.favTitle) : ""
    ; Virtual compact title: "go get trans" → also match "gogettrans"
    favCompact := RegExReplace(favTitle, "\s+", "")
    favHay := favTitle
    if favCompact != "" && favCompact != favTitle
        favHay .= " " favCompact
    if type = "image"
        return StrLower(favHay)
    if type = "recent" {
        path := String(c.HasProp("data") ? c.data : "")
        if path = ""
            path := String(c.HasProp("preview") ? c.preview : "")
        return StrLower(path " " favHay)
    }
    if type = "file" {
        return StrLower(String(c.HasProp("preview") ? c.preview : "") " "
            . String(c.HasProp("data") ? c.data : "") " " favHay)
    }
    prev := c.HasProp("preview") ? String(c.preview) : ""
    dataSample := ""
    if c.HasProp("data") && c.data != ""
        dataSample := SubStr(String(c.data), 1, 500)
    if prev = "" && dataSample != ""
        prev := dataSample
    hay := StrLower(prev " "
        . String(c.HasProp("linkTitle") ? c.linkTitle : "") " " favHay)
    if dataSample != "" && dataSample != prev
        hay .= " " StrLower(dataSample)
    return hay
}

; a|b = AND segments; within each segment, space-separated words are AND (not one contiguous phrase)
QueryMatchText(hay, favTitle, type, q) {
    q := Trim(String(q))
    if q = ""
        return true
    favTitle := String(favTitle)
    favLower := StrLower(favTitle)
    favCompact := StrLower(RegExReplace(favTitle, "\s+", ""))
    favSearch := favLower
    if favCompact != "" && favCompact != favLower
        favSearch .= " " favCompact
    hay := StrLower(String(hay))
    if type = "image"
        hay := favSearch
    matchedAny := false
    for part in StrSplit(q, "|") {
        seg := Trim(part)
        if seg = ""
            continue
        segAny := false
        for term in StrSplit(seg, A_Space A_Tab) {
            term := Trim(term)
            if term = ""
                continue
            segAny := true
            matchedAny := true
            tLower := StrLower(term)
            if type = "image" {
                if favTitle = "" || !InStr(favSearch, tLower)
                    return false
            } else if !InStr(hay, tLower)
                return false
        }
        if !segAny {
            matchedAny := true
            tLower := StrLower(seg)
            if type = "image" {
                if favTitle = "" || !InStr(favSearch, tLower)
                    return false
            } else if !InStr(hay, tLower)
                return false
        }
    }
    return matchedAny
}

; Union expand only helps multi-word queries (words split across merged rows)
QueryNeedsFavGroupUnion(q) {
    q := Trim(String(q))
    if q = ""
        return false
    for part in StrSplit(q, "|") {
        seg := Trim(part)
        if InStr(seg, " ") || InStr(seg, A_Tab)
            return true
    }
    return false
}

ItemMatchesView(c, tab, query, todayOnly) {
    if !ItemMatchesTabToday(c, tab, todayOnly)
        return false
    q := Trim(String(query))
    if q = ""
        return true
    type := StrLower(String(c.type))
    favTitle := c.HasProp("favTitle") ? String(c.favTitle) : ""
    return QueryMatchText(ClipSearchHay(c), favTitle, type, q)
}

; Stream shards: never hold more than one page file + result window in memory
CountDiskMatches(tab, query, todayOnly) {
    total := 0
    n := 0
    m := LoadManifest()
    for name in m["pages"] {
        path := PagePath(name)
        if !FileExist(path)
            continue
        try {
            loop read path, "UTF-8" {
                c := ParseNdjsonLineFast(A_LoopReadLine)
                if !IsObject(c)
                    continue
                if ItemMatchesView(c, tab, query, todayOnly)
                    total += 1
                if Mod(++n, 120) = 0
                    Sleep(-1)
            }
        } catch {
        }
    }
    return total
}

QueryDiskPage(tab, query, todayOnly, offset, limit) {
    global tabTotals, VIEW_PAGE_SIZE, FIRST_PAINT_SIZE
    tab := StrLower(Trim(String(tab)))
    if tab = "recent"
        return QueryRecentFoldersPage(query, todayOnly, offset, limit)
    if tab = "pinned"
        return QueryPinnedDiskPage(query, todayOnly, offset, limit)
    q := Trim(String(query))
    n := 0
    if q != "" {
        pool := EnsureSearchPool(tab, todayOnly)
        all := SearchPoolQuery(pool, tab, q, todayOnly)
        ; SearchPoolQuery already expands+clusters; still avoid mid-group page cuts
        items := SliceKeepingFavGroups(all, offset, limit)
        return { items: items, total: all.Length }
    }
    items := []
    total := 0
    key := ViewCacheKey(tab, "", todayOnly)
    knownTotal := -1
    if IsObject(tabTotals) && tabTotals.Has(key)
        knownTotal := Integer(tabTotals[key])
    limit := Integer(limit)
    if limit < 1
        limit := Integer(VIEW_PAGE_SIZE)
    offset := Integer(offset)
    m := LoadManifest()
    t0 := A_TickCount
    for name in m["pages"] {
        path := PagePath(name)
        if !FileExist(path)
            continue
        try {
            loop read path, "UTF-8" {
                c := ParseNdjsonLineFast(A_LoopReadLine)
                if !IsObject(c)
                    continue
                if !ItemMatchesView(c, tab, query, todayOnly)
                    continue
                if total >= offset && items.Length < limit
                    items.Push(c)
                total += 1
                if items.Length >= limit && knownTotal >= 0 && knownTotal >= (offset + limit) {
                    tabTotals[key] := knownTotal
                    EnsureFavGroupsComplete(items, tab, todayOnly)
                    ClipLog("QueryDiskPage stream hit ms=" (A_TickCount - t0) " n=" items.Length)
                    return { items: items, total: knownTotal }
                }
                if items.Length >= limit {
                    approx := offset + items.Length
                    EnqueueDiskJob(RefreshTabTotalAsync.Bind(tab, todayOnly, key))
                    EnsureFavGroupsComplete(items, tab, todayOnly)
                    ClipLog("QueryDiskPage stream early ms=" (A_TickCount - t0) " n=" items.Length)
                    return { items: items, total: Max(approx + Integer(VIEW_PAGE_SIZE), approx + 1) }
                }
                if Mod(++n, 80) = 0
                    Sleep(-1)
            }
        } catch {
        }
    }
    tabTotals[key] := total
    EnsureFavGroupsComplete(items, tab, todayOnly)
    ClipLog("QueryDiskPage stream end ms=" (A_TickCount - t0) " n=" items.Length " total=" total)
    return { items: items, total: total }
}

; Background recount so first paint of「全部」does not scan the whole library
RefreshTabTotalAsync(tab, todayOnly, key := "") {
    global tabTotals, viewCache, viewTab, viewQuery, viewToday, viewTotal, panelVisible
    tab := StrLower(Trim(String(tab)))
    todayOnly := !!todayOnly
    if key = ""
        key := ViewCacheKey(tab, "", todayOnly)
    total := 0
    try total := CountDiskMatches(tab, "", todayOnly)
    catch {
        return
    }
    if !IsObject(tabTotals)
        tabTotals := Map()
    tabTotals[key] := Integer(total)
    if viewCache.Has(key) {
        try viewCache[key].total := Integer(total)
    }
    if panelVisible && viewTab = tab && Trim(String(viewQuery)) = "" && (!!viewToday) = todayOnly {
        viewTotal := Integer(total)
        RequestUiPush()
    }
}

; 收藏: newest pinTime first (not create time / disk order)
QueryPinnedDiskPage(query, todayOnly, offset, limit) {
    q := Trim(String(query))
    pool := EnsureSearchPool("pinned", todayOnly)
    if q != ""
        all := SearchPoolQuery(pool, "pinned", q, todayOnly)
    else {
        all := pool.items.Clone()
        SortPinnedClipsDesc(all)
        ; Keep merge groups contiguous —otherwise page cuts leave a lone row
        ClusterFavGroupsInPlace(all)
    }
    items := SliceKeepingFavGroups(all, offset, limit)
    return { items: items, total: all.Length }
}

; Page slice that never cuts a favGroup mid-block (may return slightly > limit)
SliceKeepingFavGroups(all, offset, limit) {
    items := []
    if !IsObject(all) || all.Length < 1
        return items
    offset := Integer(offset)
    limit := Integer(limit)
    if limit < 1
        limit := 40
    i := offset + 1
    while i <= all.Length && items.Length < limit {
        items.Push(all[i])
        i += 1
    }
    ; If last item is mid-group, keep pulling until group ends
    if items.Length {
        last := items[items.Length]
        gid := IsObject(last) && last.HasProp("favGroup") ? Trim(String(last.favGroup)) : ""
        if gid != "" {
            while i <= all.Length {
                c := all[i]
                g := IsObject(c) && c.HasProp("favGroup") ? Trim(String(c.favGroup)) : ""
                if g != gid
                    break
                items.Push(c)
                i += 1
            }
        }
    }
    return items
}

; Pull missing favGroup siblings into a page so UI can render 合并组
EnsureFavGroupsComplete(items, tab, todayOnly) {
    if !IsObject(items) || items.Length < 1
        return
    tab := StrLower(Trim(String(tab)))
    todayOnly := !!todayOnly
    have := Map()
    gids := Map()
    for c in items {
        if !IsObject(c) || !c.HasProp("uid")
            continue
        have[Integer(c.uid)] := true
        g := c.HasProp("favGroup") ? Trim(String(c.favGroup)) : ""
        if g != ""
            gids[g] := true
    }
    if !gids.Count
        return
    added := 0
    for g, _ in gids {
        for c in CollectFavGroupMembers(g) {
            if !IsObject(c) || !c.HasProp("uid")
                continue
            uid := Integer(c.uid)
            if have.Has(uid)
                continue
            if !ItemMatchesTabToday(c, tab, todayOnly)
                continue
            items.Push(c)
            have[uid] := true
            added += 1
        }
    }
    if added > 0 || gids.Count
        ClusterFavGroupsInPlace(items)
}

CollectFavGroupMembers(gid) {
    global searchPools, clips, liveFront
    gid := Trim(String(gid))
    out := []
    if gid = ""
        return out
    have := Map()
    ; Prefer in-memory search pools (already indexed by group)
    if IsObject(searchPools) {
        for , pool in searchPools {
            if !IsObject(pool) || !IsObject(pool.groups) || !pool.groups.Has(gid)
                continue
            for c in pool.groups[gid] {
                if !IsObject(c) || !c.HasProp("uid")
                    continue
                uid := Integer(c.uid)
                if have.Has(uid)
                    continue
                have[uid] := true
                out.Push(c)
            }
        }
    }
    if out.Length
        return out
    ; Fallback: scan current clips + liveFront + disk light rows
    for c in clips {
        if IsObject(c) && c.HasProp("favGroup") && Trim(String(c.favGroup)) = gid {
            uid := Integer(c.uid)
            if !have.Has(uid) {
                have[uid] := true
                out.Push(c)
            }
        }
    }
    if IsObject(liveFront) {
        for c in liveFront {
            if IsObject(c) && c.HasProp("favGroup") && Trim(String(c.favGroup)) = gid {
                uid := Integer(c.uid)
                if !have.Has(uid) {
                    have[uid] := true
                    out.Push(c)
                }
            }
        }
    }
    if out.Length >= 2
        return out
    m := LoadManifest()
    n := 0
    for name in m["pages"] {
        for c in ReadPageFile(name, true) {
            if !IsObject(c) || !(c.HasProp("favGroup") && Trim(String(c.favGroup)) = gid)
                continue
            uid := Integer(c.uid)
            if have.Has(uid)
                continue
            have[uid] := true
            out.Push(c)
            if Mod(++n, 64) = 0
                Sleep(-1)
        }
    }
    return out
}

; After paste-locate: ensure the whole merge group sits in current clips window
EnsureFavGroupAroundUid(uid) {
    global clips, viewTab, viewQuery, viewToday, viewTotal, viewCache, wvCore, panelVisible
    uid := Integer(uid)
    if uid < 1
        return
    item := ""
    if IsObject(clips) {
        for c in clips {
            if IsObject(c) && Integer(c.uid) = uid {
                item := c
                break
            }
        }
    }
    if !IsObject(item)
        item := ResolveClip(uid)
    if !IsObject(item)
        return
    gid := item.HasProp("favGroup") ? Trim(String(item.favGroup)) : ""
    if gid = ""
        return
    members := CollectFavGroupMembers(gid)
    if members.Length < 2
        return
    ; Keep only members that belong on this tab (pinned group on 全部 still ok)
    keep := []
    for c in members {
        if ItemMatchesTabToday(c, viewTab, viewToday)
            keep.Push(c)
    }
    if keep.Length < 2
        keep := members.Clone()
    if !IsObject(clips)
        clips := []
    have := Map()
    for c in clips {
        if IsObject(c) && c.HasProp("uid")
            have[Integer(c.uid)] := true
    }
    ; Find insert position = first existing group member (or target)
    insAt := 0
    loop clips.Length {
        c := clips[A_Index]
        if !IsObject(c)
            continue
        if Integer(c.uid) = uid || (c.HasProp("favGroup") && Trim(String(c.favGroup)) = gid) {
            insAt := A_Index
            break
        }
    }
    if insAt < 1
        insAt := 1
    added := 0
    for c in keep {
        id := Integer(c.uid)
        if have.Has(id)
            continue
        clips.InsertAt(insAt + added, c)
        have[id] := true
        added += 1
        viewTotal += 1
    }
    ClusterFavGroupsInPlace(clips)
    try CacheCurrentView()
    ClipLog("EnsureFavGroupAroundUid uid=" uid " gid=" gid " added=" added " n=" clips.Length)
    if IsObject(wvCore)
        PushClips(false)
}

; Search hits + favGroup siblings (siblings skip query match) — memory pool, no disk
FilterViewClipsWithFavExpand(src, tab, query, todayOnly) {
    q := Trim(String(query))
    if q = ""
        return src
    pool := EnsureSearchPool(tab, todayOnly)
    return SearchPoolQuery(pool, tab, q, todayOnly)
}

; Merged group: words may sit on different rows — match union of members' preview/title fields
ExpandFavGroupUnionHits(items, tab, todayOnly, query) {
    q := Trim(String(query))
    if q = "" || !IsObject(items)
        return
    have := Map()
    for c in items
        have[Integer(c.uid)] := true
    hitGids := Map()
    for c in items {
        g := (c.HasProp("favGroup") ? Trim(String(c.favGroup)) : "")
        if g != ""
            hitGids[g] := true
    }
    gids := Map()
    m := LoadManifest()
    for name in m["pages"] {
        for c in ReadPageFile(name, true) {
            if !ItemMatchesTabToday(c, tab, todayOnly)
                continue
            g := (c.HasProp("favGroup") ? Trim(String(c.favGroup)) : "")
            if g = ""
                continue
            if !gids.Has(g)
                gids[g] := []
            gids[g].Push(c)
        }
    }
    for g, members in gids {
        if hitGids.Has(g)
            continue
        unionHay := ""
        for c in members
            unionHay .= " " ClipSearchHay(c)
        if !QueryMatchText(unionHay, "", "text", q)
            continue
        for c in members {
            uid := Integer(c.uid)
            if !have.Has(uid) {
                items.Push(c)
                have[uid] := true
            }
        }
    }
}

; Keep favGroup members adjacent at first member's position (so first page is not truncated mid-group)
ClusterFavGroupsInPlace(items) {
    if !IsObject(items) || items.Length < 2
        return
    out := []
    used := Map()
    for c in items {
        if !IsObject(c) || !c.HasProp("uid")
            continue
        uid := Integer(c.uid)
        if used.Has(uid)
            continue
        g := c.HasProp("favGroup") ? Trim(String(c.favGroup)) : ""
        if g = "" {
            out.Push(c)
            used[uid] := true
            continue
        }
        for o in items {
            if !IsObject(o) || !o.HasProp("uid")
                continue
            ouid := Integer(o.uid)
            if used.Has(ouid)
                continue
            og := o.HasProp("favGroup") ? Trim(String(o.favGroup)) : ""
            if og = g {
                out.Push(o)
                used[ouid] := true
            }
        }
    }
    while items.Length > 0
        items.Pop()
    for c in out
        items.Push(c)
}

ResolveClip(uid) {
    global clips, liveFront, PAYLOAD_DIR, recentFolders, emojiHitCache, emojiIndex
    uid := Integer(uid)
    if uid < 1
        return ""
    ; 表情结果不在剪贴板库；优先命中缓存/索引，避免扫盘空转
    if IsEmojiSearchUid(uid) {
        if IsObject(emojiHitCache) {
            for c in emojiHitCache {
                if IsObject(c) && Integer(c.uid) = uid
                    return c
            }
        }
        if IsObject(clips) {
            for c in clips {
                if IsObject(c) && Integer(c.uid) = uid
                    return c
            }
        }
        if IsObject(emojiIndex) {
            for rec in emojiIndex {
                if Integer(rec.uid) = uid
                    return EmojiRecToClip(rec)
            }
        }
        return ""
    }
    if IsObject(recentFolders) {
        for c in recentFolders {
            if IsObject(c) && Integer(c.uid) = uid
                return c
        }
    }
    if IsObject(liveFront) {
        for c in liveFront {
            if IsObject(c) && c.uid = uid {
                ApplyQueueMetaToItem(c)
                EnsureClipBodyLoaded(c)
                return c
            }
        }
    }
    for c in clips {
        if c.uid = uid {
            ApplyQueueMetaToItem(c)
            EnsureClipBodyLoaded(c)
            return c
        }
    }
    m := LoadManifest()
    for name in m["pages"] {
        for c in ReadPageFile(name, false) {
            if c.uid = uid {
                ApplyQueueMetaToItem(c)
                EnsureClipBodyLoaded(c)
                return c
            }
        }
    }
    return ""
}

; List queries skip payload files; load body when pasting / opening
EnsureClipBodyLoaded(item) {
    global PAYLOAD_DIR
    if !IsObject(item)
        return
    if item.type = "image"
        return
    if item.HasProp("data") && item.data != ""
        return
    if item.HasProp("dataFile") && item.dataFile != "" {
        p := PAYLOAD_DIR "\" item.dataFile
        if FileExist(p)
            item.data := FileRead(p, "UTF-8")
        return
    }
    ; Inline record with empty data (shouldn't happen after fast parse) —reload from disk
    if item.HasProp("uid") && item.uid > 0 {
        full := DiskLoadUid(item.uid)
        if IsObject(full) && full.HasProp("data")
            item.data := full.data
    }
}

DiskLoadUid(uid) {
    uid := Integer(uid)
    if uid < 1
        return ""
    m := LoadManifest()
    for name in m["pages"] {
        path := PagePath(name)
        if !FileExist(path)
            continue
        try {
            loop read path, "UTF-8" {
                if JsonFieldInt(A_LoopReadLine, "uid") != uid
                    continue
                dirty := false
                return ParseNdjsonLine(A_LoopReadLine, &dirty, false)
            }
        } catch {
        }
    }
    return ""
}

ViewCacheKey(tab, query, todayOnly) {
    return StrLower(Trim(String(tab))) "`n" (todayOnly ? "1" : "0") "`n" String(query)
}

InvalidateViewCache(*) {
    global viewCache, tabTotals, searchPools
    viewCache := Map()
    tabTotals := Map()
    searchPools := Map()
    ClipLog("InvalidateViewCache")
    ; 清空后尽快重建搜索池，避免下次 ?? 再踩冷扫盘
    SetTimer(WarmSearchPools, -400)
}

SearchPoolKey(tab, todayOnly) {
    return ViewCacheKey(tab, "", todayOnly)
}

; Only keep memory pools for 全部 + 收藏；其它 tab 搜时复用 all 池再按类型滤
SearchPoolTab(tab) {
    tab := StrLower(Trim(String(tab)))
    if tab = "pinned"
        return "pinned"
    return "all"
}

EnsureSearchPool(tab, todayOnly) {
    global searchPools
    static building := Map()
    tab := SearchPoolTab(tab)
    key := SearchPoolKey(tab, todayOnly)
    if searchPools.Has(key)
        return searchPools[key]
    ; 预热与首次搜索并发时，等正在建的那次，避免双倍全库扫盘
    if building.Has(key) {
        loop 400 {
            Sleep 15
            if searchPools.Has(key)
                return searchPools[key]
            if !building.Has(key)
                break
        }
        if searchPools.Has(key)
            return searchPools[key]
    }
    building[key] := true
    t0 := A_TickCount
    pool := { items: [], groups: Map() }
    try {
    m := LoadManifest()
    n := 0
    for name in m["pages"] {
        for c in ReadPageFile(name, true) {
            if !ItemMatchesTabToday(c, tab, todayOnly)
                continue
            h := ClipSearchHay(c)
            c._searchHay := h
            pool.items.Push(c)
            g := (c.HasProp("favGroup") ? Trim(String(c.favGroup)) : "")
            if g != "" {
                if !pool.groups.Has(g)
                    pool.groups[g] := []
                pool.groups[g].Push(c)
            }
            if Mod(++n, 64) = 0
                Sleep(-1)
        }
    }
    searchPools[key] := pool
        ClipLog("EnsureSearchPool tab=" tab " n=" pool.items.Length " ms=" (A_TickCount - t0))
    } finally {
        building.Delete(key)
    }
    return pool
}

; 后台预热「全部 + 收藏」搜索池；?? 首字前建好则几乎不卡
WarmSearchPools(*) {
    global firstAllPaintDone, searchPools
    if !firstAllPaintDone
        return
    ; 已有全部池则跳过（收藏池按需）
    keyAll := SearchPoolKey("all", false)
    if IsObject(searchPools) && searchPools.Has(keyAll)
        return
    t0 := A_TickCount
    try EnsureSearchPool("all", false)
    try EnsureSearchPool("pinned", false)
    ClipLog("WarmSearchPools done ms=" (A_TickCount - t0))
}

; In-memory search (pool built once; fav-group expand without re-scanning disk)
SearchPoolQuery(pool, tab, q, todayOnly) {
    all := []
    if !IsObject(pool) || !pool.HasProp("items")
        return all
    tab := StrLower(Trim(String(tab)))
    have := Map()
    hitGids := Map()
    q := Trim(String(q))
    for c in pool.items {
        if !ItemMatchesTabToday(c, tab, todayOnly)
            continue
        type := StrLower(String(c.type))
        favTitle := c.HasProp("favTitle") ? String(c.favTitle) : ""
        hay := c.HasProp("_searchHay") ? c._searchHay : ClipSearchHay(c)
        if !QueryMatchText(hay, favTitle, type, q)
            continue
        uid := Integer(c.uid)
        if !have.Has(uid) {
            all.Push(c)
            have[uid] := true
        }
        g := (c.HasProp("favGroup") ? Trim(String(c.favGroup)) : "")
        if g != ""
            hitGids[g] := true
    }
    if IsObject(pool.groups) {
        for g, _ in hitGids {
            if !pool.groups.Has(g)
                continue
            for c in pool.groups[g] {
                uid := Integer(c.uid)
                if have.Has(uid)
                    continue
                if !ItemMatchesTabToday(c, tab, todayOnly)
                    continue
                all.Push(c)
                have[uid] := true
            }
        }
        if QueryNeedsFavGroupUnion(q) {
            for g, members in pool.groups {
                if hitGids.Has(g)
                    continue
                unionHay := ""
                anyTab := false
                for c in members {
                    if !ItemMatchesTabToday(c, tab, todayOnly)
                        continue
                    anyTab := true
                    unionHay .= " " (c.HasProp("_searchHay") ? c._searchHay : ClipSearchHay(c))
                }
                if !anyTab || !QueryMatchText(unionHay, "", "text", q)
                    continue
                for c in members {
                    if !ItemMatchesTabToday(c, tab, todayOnly)
                        continue
                    uid := Integer(c.uid)
                    if !have.Has(uid) {
                        all.Push(c)
                        have[uid] := true
                    }
                }
            }
        }
    }
    ; pool.groups already expanded siblings above; cluster so pagination keeps the whole group on page 1
    if q != "" && all.Length
        ClusterFavGroupsInPlace(all)
    return all
}

ParseViewCacheKey(key, &tab, &todayOnly, &query) {
    parts := StrSplit(String(key), "`n")
    tab := parts.Length >= 1 ? parts[1] : "all"
    todayOnly := parts.Length >= 2 && parts[2] = "1"
    query := parts.Length >= 3 ? parts[3] : ""
}

MemoryRemoveFromList(arr, pred) {
    removed := 0
    if !IsObject(arr)
        return 0
    i := 1
    while i <= arr.Length {
        if pred(arr[i]) {
            arr.RemoveAt(i)
            removed += 1
        } else
            i += 1
    }
    return removed
}

; Remove all in-memory text equals; return best match (prefer pinned) for meta inherit
MemoryTakeTextEqual(text) {
    global clips, viewTotal, viewCache, liveFront
    best := ""
    ; Collect then remove — avoid nested arrow closures mutating outer vars
    matches := []
    for c in clips {
        if IsObject(c) && c.type = "text" && c.data = text
            matches.Push(c)
    }
    for c in matches {
        if !IsObject(best) || (c.HasProp("pinned") && c.pinned && !(best.HasProp("pinned") && best.pinned))
            best := c
        MemoryRemoveUid(c.uid)
    }
    ; viewCache / liveFront may still hold copies not in clips
    if IsObject(viewCache) {
        for key, entry in viewCache {
            if !IsObject(entry) || !entry.HasProp("items")
                continue
            i := 1
            while i <= entry.items.Length {
                c := entry.items[i]
                if IsObject(c) && c.type = "text" && c.data = text {
                    if !IsObject(best) || (c.HasProp("pinned") && c.pinned && !(best.HasProp("pinned") && best.pinned))
                        best := c
                    entry.items.RemoveAt(i)
                    entry.total := Max(0, entry.total - 1)
                } else
                    i += 1
            }
        }
    }
    if IsObject(liveFront) {
        i := 1
        while i <= liveFront.Length {
            c := liveFront[i]
            if IsObject(c) && c.type = "text" && c.data = text {
                if !IsObject(best) || (c.HasProp("pinned") && c.pinned && !(best.HasProp("pinned") && best.pinned))
                    best := c
                liveFront.RemoveAt(i)
            } else
                i += 1
        }
    }
    return best
}

; Prefer keeping 收藏 / 标题 / uid when re-copy replaces an older row
InheritClipMeta(item, old) {
    if !IsObject(item) || !IsObject(old)
        return
    if old.HasProp("pasted") && old.pasted
        item.pasted := true
    if old.HasProp("pinned") && old.pinned {
        if !(item.HasProp("pinned") && item.pinned) {
            item.pinned := true
            if old.HasProp("pinTime") && old.pinTime != ""
                item.pinTime := old.pinTime
        } else if (!(item.HasProp("pinTime") && item.pinTime != "")) && old.HasProp("pinTime") && old.pinTime != ""
            item.pinTime := old.pinTime
    }
    if (!(item.HasProp("favTitle") && item.favTitle != "")) && old.HasProp("favTitle") && old.favTitle != ""
        item.favTitle := old.favTitle
    if (!(item.HasProp("favGroup") && item.favGroup != "")) && old.HasProp("favGroup") && old.favGroup != ""
        item.favGroup := old.favGroup
    ; Keep queue membership when re-copy replaces equal content (unless already tagged)
    if (!(item.HasProp("queueGroup") && Integer(item.queueGroup) > 0)) && old.HasProp("queueGroup") && Integer(old.queueGroup) > 0 {
        item.queueGroup := Integer(old.queueGroup)
        if old.HasProp("queueIndex")
            item.queueIndex := Integer(old.queueIndex)
    }
    if old.HasProp("uid") && old.uid
        item.uid := old.uid
}

MemoryTakeLinkEqual(url) {
    global clips, viewTotal, viewCache, liveFront
    taken := ""
    for i, c in clips {
        if c.type = "link" && c.data = url {
            taken := clips.RemoveAt(i)
            viewTotal := Max(0, viewTotal - 1)
            break
        }
    }
    for key, entry in viewCache {
        for i, c in entry.items {
            if c.type = "link" && c.data = url {
                if !IsObject(taken)
                    taken := c
                entry.items.RemoveAt(i)
                entry.total := Max(0, entry.total - 1)
                break
            }
        }
    }
    if IsObject(liveFront) {
        for i, c in liveFront {
            if IsObject(c) && c.type = "link" && c.data = url {
                if !IsObject(taken)
                    taken := c
                liveFront.RemoveAt(i)
                break
            }
        }
    }
    return taken
}

MemoryTakeUid(uid) {
    global clips, viewTotal, viewCache
    uid := Integer(uid)
    taken := ""
    for i, c in clips {
        if c.uid = uid {
            taken := clips.RemoveAt(i)
            viewTotal := Max(0, viewTotal - 1)
            break
        }
    }
    for key, entry in viewCache {
        for i, c in entry.items {
            if c.uid = uid {
                if !IsObject(taken)
                    taken := c
                entry.items.RemoveAt(i)
                entry.total := Max(0, entry.total - 1)
                break
            }
        }
    }
    return taken
}

MemoryRemoveUid(uid) {
    MemoryTakeUid(uid)
}

MemoryInsertFront(item) {
    global clips, viewTab, viewQuery, viewToday, viewTotal, viewCache, PAGE_SIZE, VIEW_PAGE_SIZE, tabTotals, searchPools
    ; Drop same uid anywhere first
    MemoryRemoveUid(item.uid)
    LiveFrontAdd(item)
    maxRows := Max(VIEW_PAGE_SIZE * 2, 40)
    for key, entry in viewCache {
        tab := "", todayOnly := false, query := ""
        ParseViewCacheKey(key, &tab, &todayOnly, &query)
        if !ItemMatchesView(item, tab, query, todayOnly)
            continue
        entry.items.InsertAt(1, item)
        entry.total += 1
        while entry.items.Length > maxRows
            entry.items.Pop()
        if query = "" && IsObject(tabTotals)
            tabTotals[key] := Integer(entry.total)
    }
    if IsObject(searchPools) {
        h := ClipSearchHay(item)
        item._searchHay := h
        for key, pool in searchPools {
            tab := "", todayOnly := false, query := ""
            ParseViewCacheKey(key, &tab, &todayOnly, &query)
            if !ItemMatchesTabToday(item, tab, todayOnly)
                continue
            pool.items.InsertAt(1, item)
            g := (item.HasProp("favGroup") ? Trim(String(item.favGroup)) : "")
            if g != "" {
                if !pool.groups.Has(g)
                    pool.groups[g] := []
                pool.groups[g].InsertAt(1, item)
            }
        }
    }
    if ItemMatchesView(item, viewTab, viewQuery, viewToday) {
        clips.InsertAt(1, item)
        viewTotal += 1
    }
    ; Do NOT CacheCurrentView() here —that overwrote a full disk page with the
    ; in-memory clips window (often 1 item after copy-before-open) and hid history.
}

; Keep freshly copied items across InvalidateViewCache / SetView(disk) races
LiveFrontAdd(item) {
    global liveFront
    if !IsObject(item) || !item.HasProp("uid")
        return
    LiveFrontRemoveUid(item.uid)
    liveFront.InsertAt(1, item)
    ; Bound memory —only need the newest few until disk catches up
    while liveFront.Length > 40
        liveFront.Pop()
}

LiveFrontRemoveUid(uid) {
    global liveFront
    uid := Integer(uid)
    for i, c in liveFront {
        if IsObject(c) && c.uid = uid {
            liveFront.RemoveAt(i)
            return
        }
    }
}

LiveFrontConfirmPersisted(uid) {
    LiveFrontRemoveUid(uid)
}

MergeLiveFrontIntoClips() {
    global liveFront, clips, viewTab, viewQuery, viewToday, viewTotal
    if !IsObject(liveFront) || liveFront.Length < 1
        return
    have := Map()
    for c in clips {
        if IsObject(c) && c.HasProp("uid")
            have[Integer(c.uid)] := true
    }
    ; liveFront is newest-first; collect matching missing items then prepend in order
    add := []
    for c in liveFront {
        if !IsObject(c) || !c.HasProp("uid")
            continue
        uid := Integer(c.uid)
        if have.Has(uid)
            continue
        if !ItemMatchesView(c, viewTab, viewQuery, viewToday)
            continue
        add.Push(c)
        have[uid] := true
    }
    ; 搜索模式不把同 favGroup 的未命中兄弟塞进结果
    if !add.Length
        return
    ; Insert so add[1] (newest) ends at front
    i := add.Length
    while i >= 1 {
        clips.InsertAt(1, add[i])
        viewTotal += 1
        i -= 1
    }
    ClipLog("MergeLiveFrontIntoClips added=" add.Length " clips=" clips.Length)
}

EnqueueDiskJob(fn) {
    global diskJobQueue
    diskJobQueue.Push(fn)
    SetTimer(DrainDiskJobs, -20)
}

; Run ASAP (front of queue) — queue persist must not wait behind thumbs/prune
PrependDiskJob(fn) {
    global diskJobQueue
    diskJobQueue.InsertAt(1, fn)
    SetTimer(DrainDiskJobs, -1)
}

DrainDiskJobs(*) {
    global diskJobBusy, diskJobQueue, diskScanBusy
    if diskJobBusy {
        ; Still running —retry soon so queued jobs are not stuck until next copy
        SetTimer(DrainDiskJobs, -80)
        return
    }
    if diskScanBusy {
        SetTimer(DrainDiskJobs, -200)
        return
    }
    if diskJobQueue.Length < 1
        return
    diskJobBusy := true
    ; No Critical here —GDI+/FileCopy under Critical hung then killed the process
    fn := diskJobQueue.RemoveAt(1)
    ClipLog("DrainDiskJobs RUN qLeft=" diskJobQueue.Length)
    try fn.Call()
    catch as e {
        ClipLogErr("DrainDiskJobs", e)
    }
    diskJobBusy := false
    ClipLog("DrainDiskJobs DONE")
    ; Long FileRead loops can leave the wait cursor; restore after each job
    try DllCall("SystemParametersInfo", "UInt", 0x57, "UInt", 0, "Ptr", 0, "UInt", 0)
    if diskJobQueue.Length
        SetTimer(DrainDiskJobs, -20)
}

; Block until pending disk jobs finish (used on script exit)
FlushDiskJobsSync(*) {
    global diskJobBusy, diskJobQueue
    SetTimer(DrainDiskJobs, 0)
    loop 1000 {
        if diskJobQueue.Length < 1 && !diskJobBusy
            break
        if diskJobBusy {
            Sleep 15
            continue
        }
        if diskJobQueue.Length {
            diskJobBusy := true
            fn := diskJobQueue.RemoveAt(1)
            try fn.Call()
            catch {
            }
            diskJobBusy := false
        }
    }
}

; Large text/link →external payload file (NDJSON line stays small so reload won't drop it)
EnsureSpillPayload(item) {
    global PAYLOAD_DIR, PAYLOAD_INLINE_MAX
    if !IsObject(item)
        return
    if item.type = "image" || item.type = "file"
        return
    if item.HasProp("dataFile") && item.dataFile != ""
        return
    data := String(item.HasProp("data") ? item.data : "")
    if StrLen(data) <= PAYLOAD_INLINE_MAX
        return
    try DirCreate PAYLOAD_DIR
    name := "d_" item.uid ".txt"
    path := PAYLOAD_DIR "\" name
    try {
        if FileExist(path)
            FileDelete path
        FileAppend data, path, "UTF-8"
        if FileExist(path)
            item.dataFile := name
    } catch {
    }
}

; 落盘前从内存抄回收藏/标题，避免异步 Persist 覆盖用户刚点的收藏
SyncPersistItemMetaFromMemory(item) {
    global clips, liveFront
    if !IsObject(item) || !item.HasProp("uid")
        return
    uid := Integer(item.uid)
    if uid < 1
        return
    src := ""
    if IsObject(clips) {
        for c in clips {
            if IsObject(c) && Integer(c.uid) = uid {
                src := c
                break
            }
        }
    }
    if !IsObject(src) && IsObject(liveFront) {
        for c in liveFront {
            if IsObject(c) && Integer(c.uid) = uid {
                src := c
                break
            }
        }
    }
    if !IsObject(src)
        return
    if src.HasProp("pinned")
        item.pinned := !!src.pinned
    if src.HasProp("pinTime")
        item.pinTime := src.pinTime
    if src.HasProp("favTitle")
        item.favTitle := src.favTitle
    if src.HasProp("favGroup")
        item.favGroup := src.favGroup
    if src.HasProp("pasted")
        item.pasted := !!src.pasted
}

DeletePayloadFile(item) {
    global PAYLOAD_DIR
    if !IsObject(item) || !item.HasProp("dataFile") || item.dataFile = ""
        return
    path := PAYLOAD_DIR "\" item.dataFile
    try {
        if FileExist(path)
            FileDelete path
    }
}

PersistNewItem(item) {
    global panelVisible, pasteQueueIds
    if !IsObject(item)
        return
    uidBefore := item.HasProp("uid") ? Integer(item.uid) : 0
    ClipLog("PersistNewItem begin uid=" uidBefore " type=" item.type)
    ; Keep queue tags across InheritClipMeta (disk equal may not have them yet)
    keepQg := (item.HasProp("queueGroup") ? Integer(item.queueGroup) : 0)
    keepQi := (item.HasProp("queueIndex") ? Integer(item.queueIndex) : 0)
    ; Heavy file I/O lives here (async queue) — never on OnClipboardChange
    if item.type = "image" {
        if (!item.HasProp("imgFile") || item.imgFile = "") && item.HasProp("data") && item.data != "" {
            saved := ""
            try saved := SaveImageToStore(item.data)
            catch as e {
                ClipLogErr("PersistNewItem SaveImageToStore", e)
            }
            if saved != "" {
                item.imgFile := saved
                item.data := ""
                ; Patch in-memory / cache so UI can load thumb after write
                ApplyImgFileLocal(item.uid, item.imgFile)
                ; Don't wait for coalesced PushClips —fill the blank placeholder now
                SetTimer(InjectStoreThumbNow.Bind(Integer(item.uid), String(item.imgFile)), -10)
            } else {
                ; Keep in-memory data so InjectLiveImageThumb / retry can still show a preview
                ClipLog("PersistNewItem SaveImageToStore empty uid=" uidBefore)
            }
        }
    }
    ; Remove old equals BEFORE spill — reused uid shares d_<uid>.txt with the old row.
    ; Queue FIFO slots must stay distinct: DiskRemoveTextEqual was deleting earlier queue
    ; rows with the same text and InheritClipMeta stole their uid (3→2 after restart).
    if keepQg > 0 {
        ; keep fresh uid + queue tags; do not collapse onto historical equals
    } else if item.type = "text" {
        old := DiskRemoveTextEqual(item.data)
        InheritClipMeta(item, old)
    } else if item.type = "link" {
        old := DiskTakeLinkEqual(item.data)
        if IsObject(old) {
            InheritClipMeta(item, old)
            if old.HasProp("linkTitle") && old.linkTitle != "" && !(item.HasProp("linkTitle") && item.linkTitle != "")
                item.linkTitle := old.linkTitle
            if old.uid != item.uid
                DeletePayloadFile(old)
        }
    } else if item.type = "file" {
        old := DiskRemoveFileEqual(item.data)
        InheritClipMeta(item, old)
        if IsObject(old) && old.HasProp("imgFile") && old.imgFile != "" && !(item.HasProp("imgFile") && item.imgFile != "")
            item.imgFile := old.imgFile
    }
    if keepQg > 0 {
        item.queueGroup := keepQg
        item.queueIndex := keepQi
        ; Force uid stable — never accept Inherit from a partial path above
        if uidBefore > 0
            item.uid := uidBefore
    }
    ; 文件缩略图：去重继承之后再补（队列模式也会走到这里）
    if item.type = "file" {
        if (!item.HasProp("imgFile") || item.imgFile = "") && FileClipLooksLikeImage(item) {
            try EnsureFileClipThumb(item)
            catch as e {
                ClipLogErr("PersistNewItem EnsureFileClipThumb", e)
            }
        }
        if item.HasProp("imgFile") && item.imgFile != "" {
            ApplyImgFileLocal(item.uid, item.imgFile)
            SetTimer(InjectStoreThumbNow.Bind(Integer(item.uid), String(item.imgFile)), -10)
        }
    }
    EnsureSpillPayload(item)
    ; 持久化前与内存对齐：用户可能在异步落盘前已收藏/改标题
    SyncPersistItemMetaFromMemory(item)
    ok := DiskInsertFront(item)
    uidAfter := item.HasProp("uid") ? Integer(item.uid) : 0
    ClipLog("PersistNewItem done uid=" uidAfter " ok=" ok " qg=" keepQg " qi=" keepQi)
    if ok {
        LiveFrontConfirmPersisted(item.uid)
        if keepQg > 0 {
            ; Final uid after Inherit — meta must match disk row
            if uidBefore > 0 && uidAfter > 0 && uidBefore != uidAfter
                RemapPasteQueueUid(uidBefore, uidAfter)
            UpsertQueueMeta(uidAfter, keepQg, keepQi)
            DiskSetQueueMeta(uidAfter, keepQg, keepQi)
        }
    }
    ; Cap clipboard screenshots only —file images stay forever (debounced)
    if item.type = "image"
        SchedulePruneScreenshots()
    ; Ensure open panel catches up even if the first UI push was dropped
    if panelVisible
        RequestUiPush()
}

ApplyImgFileLocal(uid, imgFile) {
    global clips, viewCache
    uid := Integer(uid)
    imgFile := String(imgFile)
    for c in clips {
        if c.uid = uid {
            c.imgFile := imgFile
            ; 仅截图位图可清空 data（已落盘 imgFile）；file 类型的 data 是路径，清掉会导致「最新图片丢了」
            if c.type = "image"
                c.data := ""
            break
        }
    }
    for , entry in viewCache {
        if !IsObject(entry) || !entry.HasProp("items")
            continue
        for c in entry.items {
            if c.uid = uid {
                c.imgFile := imgFile
                if c.type = "image"
                    c.data := ""
                break
            }
        }
    }
}

PersistDeleteUid(uid, imgFile := "", itemType := "") {
    removed := DiskRemoveUid(uid)
    if IsObject(removed)
        DeletePayloadFile(removed)
    ; Screenshots and image-format file thumbs both live in clips_store
    if imgFile != ""
        DeleteStoredImage({ type: "image", imgFile: imgFile })
    else if IsObject(removed) && removed.HasProp("imgFile") && removed.imgFile != ""
        DeleteStoredImage(removed)
}

; Keep only the newest MAX_SCREENSHOTS clipboard screenshots (type=image).
; type=file / fimg_* thumbs are never touched. Pinned screenshots are always kept.
SchedulePruneScreenshots(*) {
    global pruneScreenshotsArmed, pruneScreenshotsPending
    pruneScreenshotsPending := true
    if pruneScreenshotsArmed
        return
    pruneScreenshotsArmed := true
    ; Idle debounce —never full-scan the library on every screenshot persist
    SetTimer(FlushPruneScreenshots, -2800)
}

FlushPruneScreenshots(*) {
    global pruneScreenshotsArmed, pruneScreenshotsPending
    pruneScreenshotsArmed := false
    if !pruneScreenshotsPending
        return
    pruneScreenshotsPending := false
    EnqueueDiskJob(PruneOldScreenshots)
}

PruneOldScreenshots(*) {
    global MAX_SCREENSHOTS, viewCache
    maxKeep := Integer(MAX_SCREENSHOTS)
    if maxKeep < 1
        maxKeep := 100
    m := LoadManifest()
    pages := m["pages"]
    if !IsObject(pages) || !pages.Length
        return
    ; Newest-first by uid (pages are newest-first, but sort explicitly so最新截图绝不会被误删)
    images := []
    n := 0
    for name in pages {
        for c in ReadPageFile(name, true) {
            if !IsObject(c) || c.type != "image"
                continue
            images.Push(c)
            if Mod(++n, 64) = 0
                Sleep(-1)
        }
    }
    ; uid 越大越新；固定项跳过计数
    if images.Length > 1 {
        sorted := []
        loop images.Length
            sorted.Push(images[A_Index])
        ; simple insertion by uid desc (N is capped by MAX_SCREENSHOTS*few)
        images := []
        for c in sorted {
            uid := Integer(c.uid)
            inserted := false
            loop images.Length {
                if uid > Integer(images[A_Index].uid) {
                    images.InsertAt(A_Index, c)
                    inserted := true
                    break
                }
            }
            if !inserted
                images.Push(c)
        }
    }
    drop := Map()
    keptUnpinned := 0
    for c in images {
        uid := Integer(c.uid)
        if uid < 1
            continue
        if c.HasProp("pinned") && c.pinned
            continue
        if keptUnpinned < maxKeep {
            keptUnpinned += 1
            continue
        }
        drop[uid] := c
    }
    if !drop.Count
        return
    ClipLog("PruneOldScreenshots drop=" drop.Count " keepUnpinned=" keptUnpinned " max=" maxKeep)

    ; One rewrite pass over pages
    newPages := []
    for name in pages {
        items := ReadPageFile(name, true)
        kept := []
        changed := false
        for c in items {
            if IsObject(c) && drop.Has(Integer(c.uid)) {
                changed := true
                continue
            }
            kept.Push(c)
        }
        if !changed {
            newPages.Push(name)
            continue
        }
        if kept.Length {
            WritePageFile(name, kept)
            newPages.Push(name)
        } else {
            try FileDelete PagePath(name)
        }
        if Mod(++n, 8) = 0
            Sleep(-1)
    }
    m["pages"] := newPages
    SaveManifest(m)

    for uid, c in drop {
        try DeleteStoredImage(c)
        MemoryRemoveUid(uid)
        LiveFrontRemoveUid(uid)
    }
    ; Drop stale image-tab / all totals in viewCache
    for key, entry in viewCache {
        if !IsObject(entry) || !entry.HasProp("items")
            continue
        keptItems := []
        removedN := 0
        for c in entry.items {
            if IsObject(c) && drop.Has(Integer(c.uid)) {
                removedN += 1
                continue
            }
            keptItems.Push(c)
        }
        if removedN {
            entry.items := keptItems
            entry.total := Max(0, Integer(entry.total) - removedN)
        }
    }
    ; Totals changed —force next QueryDiskPage to recount if needed
    global tabTotals, panelVisible
    tabTotals := Map()
    ClipLog("PruneOldScreenshots done")
    if panelVisible
        RequestUiPush()
}

PersistMoveToTop(item) {
    if !IsObject(item)
        return
    EnsureSpillPayload(item)
    DiskRemoveUid(item.uid)
    DiskInsertFront(item)
}

CacheCurrentView() {
    global viewCache, clips, viewTab, viewQuery, viewToday, viewTotal, VIEW_PAGE_SIZE, tabTotals
    key := ViewCacheKey(viewTab, viewQuery, viewToday)
    ; 禁止用「仅一页、total 未扫完」的全部快照盖掉已有完整 total
    if viewTab = "all" && viewQuery = "" && !viewToday {
        if viewTotal <= VIEW_PAGE_SIZE && clips.Length <= VIEW_PAGE_SIZE {
            if viewCache.Has(key) {
                old := viewCache[key]
                if IsObject(old) && old.HasProp("total") && old.total > VIEW_PAGE_SIZE
                    return
            }
            ; 完整小库（条数=total）可以缓存；未扫完的首屏快照不要写
            if !(viewTotal > 0 && viewTotal = clips.Length)
                return
        }
    }
    cloned := []
    for c in clips
        cloned.Push(c)
    viewCache[key] := { items: cloned, total: viewTotal }
    if viewQuery = "" && IsObject(tabTotals)
        tabTotals[key] := Integer(viewTotal)
}

; 首屏：只暖「全部」前 FIRST_PAINT_SIZE 条；pushUi=false 时只填内存（Navigate 前用）
PreloadAllViews(today := "", pushUi := true) {
    global viewCache, viewToday, VIEW_PAGE_SIZE, FIRST_PAINT_SIZE, qqSearchOn, tabTotals
        , clips, viewTab, viewQuery, viewTotal, viewApplying, wvCore
    PerfMark("PreloadAllViews ENTER pushUi=" pushUi)
    try {
        if today = ""
            todayFlag := viewToday
        else
            todayFlag := (String(today) = "1" || String(today) = "true")
        key := ViewCacheKey("all", "", todayFlag)
        if viewCache.Has(key) {
            entry := viewCache[key]
            if IsObject(entry) && entry.HasProp("items") && entry.items.Length >= 1 {
                PerfMark("PreloadAllViews viewCache HIT n=" entry.items.Length)
                if !qqSearchOn {
                    clips := []
                    for c in entry.items
                        clips.Push(c)
                    viewTab := "all"
                    viewQuery := ""
                    viewToday := todayFlag
                    viewTotal := Integer(entry.HasProp("total") ? entry.total : clips.Length)
                    viewApplying := false
                    if pushUi && IsObject(wvCore)
                        PushClips(false)
                }
                CacheRecentFoldersView(todayFlag)
                return
            }
        }

        paintN := Integer(FIRST_PAINT_SIZE)
        if paintN < 1
            paintN := 20
        if paintN > VIEW_PAGE_SIZE
            paintN := VIEW_PAGE_SIZE

        items := []
        m := LoadManifest()
        pageN := 0
        try pageN := m["pages"].Length
        PerfMark("PreloadAllViews scan start paintN=" paintN " pages=" pageN)
        n := 0
        t0 := A_TickCount
        for name in m["pages"] {
            path := PagePath(name)
            if !FileExist(path)
                continue
            try {
                loop read path, "UTF-8" {
                    c := ParseNdjsonLineFast(A_LoopReadLine)
                    if !IsObject(c)
                        continue
                    if !ItemMatchesView(c, "all", "", todayFlag)
                        continue
                    items.Push(c)
                    if items.Length >= paintN {
                        approxTotal := items.Length + VIEW_PAGE_SIZE
                        viewCache[key] := { items: items.Clone(), total: approxTotal }
                        if IsObject(tabTotals)
                            tabTotals[key] := Integer(approxTotal)
                        if !qqSearchOn {
                            clips := items.Clone()
                            viewTab := "all"
                            viewQuery := ""
                            viewToday := todayFlag
                            viewTotal := approxTotal
                            viewApplying := false
                            if pushUi && IsObject(wvCore)
                                PushClips(false)
                        }
                        CacheRecentFoldersView(todayFlag)
                        EnqueueDiskJob(RefreshTabTotalAsync.Bind("all", todayFlag, key))
                        ClipLog("PreloadAllViews paint n=" items.Length " ms=" (A_TickCount - t0))
                        PerfMark("PreloadAllViews paint done n=" items.Length " scanMs=" (A_TickCount - t0))
                        return
                    }
                }
            } catch {
            }
        }
        viewCache[key] := { items: items, total: items.Length }
        if IsObject(tabTotals)
            tabTotals[key] := Integer(items.Length)
        CacheRecentFoldersView(todayFlag)
        ClipLog("PreloadAllViews full-lib n=" items.Length " ms=" (A_TickCount - t0))
        PerfMark("PreloadAllViews full-lib n=" items.Length " scanMs=" (A_TickCount - t0))
        if pushUi && !qqSearchOn
            SetView("all", "", todayFlag ? "1" : "0")
    }
}

; 兼容旧名
PreloadAllViewsContinue(todayFlag := false, startPageIdx := 1) {
    key := ViewCacheKey("all", "", !!todayFlag)
    EnqueueDiskJob(RefreshTabTotalAsync.Bind("all", !!todayFlag, key))
}

PreloadNonLinkViews(today := "") {
    PreloadAllViews(today, true)
}

QueueSetView(tab, query, today) {
    global pendingViewTab, pendingViewQuery, pendingViewToday, pendingViewArmed
        , qqSearchOn, qqQuery, firstAllPaintDone
    ; ?? 搜索中前端偶发带空 query 的 setView：改写为当前关键字，避免冲掉命中
    if qqSearchOn {
        want := Trim(String(qqQuery))
        if want != "" && Trim(String(query)) = ""
            query := qqQuery
    }
    pendingViewTab := tab
    pendingViewQuery := query
    pendingViewToday := today
    ; 首屏未出前：只记 pending，避免 JS requestView 冷扫盘抢跑
    if !firstAllPaintDone {
        pendingViewArmed := true
        return
    }
    if pendingViewArmed
        return
    pendingViewArmed := true
    SetTimer(ApplyPendingView, -1)
}

ApplyPendingView(*) {
    global pendingViewArmed, pendingViewTab, pendingViewQuery, pendingViewToday
    pendingViewArmed := false
    SetView(pendingViewTab, pendingViewQuery, pendingViewToday)
}

SetView(tab := "all", query := "", today := "0") {
    global clips, viewTab, viewQuery, viewToday, viewTotal, VIEW_PAGE_SIZE, FIRST_PAINT_SIZE, lastAppendCount, wvCore, viewCache
        , qqSearchOn, qqQuery, qqAwaitKeyword, qqEmojiMode, viewSwitchGuardUntil, viewApplyGen, viewApplying
    ; ?? 搜索进行中：禁止空查询把结果冲成「全部未过滤」，否则前端按关键字一滤就变成 0 条
    if qqSearchOn {
        want := Trim(String(qqQuery))
        incoming := Trim(String(query))
        if want != "" && incoming = "" {
            ClipLog("SetView SKIP empty while qqSearch q=" want)
            return
        }
        if qqAwaitKeyword && incoming = "" {
            ClipLog("SetView SKIP empty while qqAwaitKeyword")
            return
        }
    }
    newTab := StrLower(Trim(String(tab)))
    if newTab = "" || newTab = "0"
        newTab := "all"
    newQuery := String(query)
    newToday := (String(today) = "1" || String(today) = "true")
    ; ??? 表情：不走剪贴板磁盘索引，按拼音命中 emoji.txt
    if qqSearchOn && qqEmojiMode && Trim(newQuery) != "" {
        viewSwitchGuardUntil := A_TickCount + 200
        myGen := ++viewApplyGen
        viewApplying := true
        viewTab := newTab
        viewQuery := newQuery
        viewToday := newToday
        lastAppendCount := 0
        try {
            page := QueryEmojiHits(viewQuery, 0, VIEW_PAGE_SIZE)
            if myGen != viewApplyGen
                return
            clips := page.items
            viewTotal := page.total
            ClipLog("SetView emoji q=" viewQuery " n=" clips.Length " total=" viewTotal)
            viewApplying := false
            if IsObject(wvCore)
                PushClips(false)
            QQSyncPanelVisibility()
            viewSwitchGuardUntil := A_TickCount + 120
        } finally {
            if myGen = viewApplyGen
                viewApplying := false
        }
        return
    }
    ; 「最近」纯内存：短守卫，不走整盘扫
    if newTab = "recent" {
        viewSwitchGuardUntil := A_TickCount + 200
        myGen := ++viewApplyGen
        viewApplying := true
        viewTab := newTab
        viewQuery := newQuery
        viewToday := newToday
        lastAppendCount := 0
        try {
            page := QueryRecentFoldersPage(viewQuery, viewToday, 0, VIEW_PAGE_SIZE)
            if myGen != viewApplyGen
                return
            clips := page.items
            viewTotal := page.total
            key := ViewCacheKey(viewTab, viewQuery, viewToday)
            cached := []
            for c in clips
                cached.Push(c)
            viewCache[key] := { items: cached, total: viewTotal }
            ClipLog("SetView recent n=" clips.Length " total=" viewTotal)
            viewApplying := false
            if IsObject(wvCore)
                PushClips(false)
            QQSyncPanelVisibility()
            viewSwitchGuardUntil := A_TickCount + 120
        } finally {
            if myGen = viewApplyGen
                viewApplying := false
        }
        return
    }
    ; 切页扫盘可能较慢：期间忽略外侧点击，避免卡完面板被误关
    viewSwitchGuardUntil := A_TickCount + 1200
    myGen := ++viewApplyGen
    viewApplying := true
    viewTab := newTab
    viewQuery := newQuery
    viewToday := newToday
    lastAppendCount := 0
    try {
        key := ViewCacheKey(viewTab, viewQuery, viewToday)
        if viewCache.Has(key) {
            entry := viewCache[key]
            ; Only drop empty / near-empty snapshots (copy-before-open / race).
            ; Do NOT treat total<=VIEW_PAGE_SIZE as poison —that forced a full disk
            ; rescan on every tab switch for libraries with ≤20 items.
            poisoned := viewQuery = "" && !viewToday
                && IsObject(entry) && entry.HasProp("items")
                && entry.items.Length < 5 && entry.total <= entry.items.Length
                && (viewTab = "all" || viewTab = "image" || viewTab = "file"
                    || viewTab = "text" || viewTab = "link" || viewTab = "pinned")
            thin := !IsObject(entry) || !entry.HasProp("items") || poisoned
            if !thin {
                if myGen != viewApplyGen
                    return
                clips := []
                for c in entry.items
                    clips.Push(c)
                viewTotal := entry.total
                MergeLiveFrontIntoClips()
                EnsureFavGroupsComplete(clips, viewTab, viewToday)
                ClipLog("SetView cache hit tab=" viewTab " n=" clips.Length " total=" viewTotal)
                viewApplying := false
                if IsObject(wvCore)
                    PushClips(false)
                ; 不要 QQPushQuery：会触发前端 requestView → SetView 死循环闪烁
                QQSyncPanelVisibility()
                viewSwitchGuardUntil := A_TickCount + 400
                return
            }
            ClipLog("SetView drop thin cache tab=" viewTab " n=" entry.items.Length " total=" entry.total)
            viewCache.Delete(key)
        }
        page := QueryDiskPage(viewTab, viewQuery, viewToday, 0
            , (viewTab = "all" && viewQuery = "" ? FIRST_PAINT_SIZE : VIEW_PAGE_SIZE))
        if myGen != viewApplyGen
            return
        clips := page.items
        viewTotal := page.total
        MergeLiveFrontIntoClips()
        EnsureFavGroupsComplete(clips, viewTab, viewToday)
        ClipLog("SetView disk tab=" viewTab " n=" clips.Length " total=" viewTotal)
        CacheCurrentView()
        viewApplying := false
        if IsObject(wvCore)
            PushClips(false)
        ; 不要 QQPushQuery：会触发前端 requestView → SetView 死循环闪烁
        QQSyncPanelVisibility()
        viewSwitchGuardUntil := A_TickCount + 400
    } finally {
        if myGen = viewApplyGen
            viewApplying := false
    }
}

; 有搜索关键字时，严格命中 + 合并组整组展示（防缓存/竞态脏数据）
FilterClipsInPlaceToQuery(*) {
    global clips, viewTab, viewQuery, viewToday, viewTotal
    q := Trim(String(viewQuery))
    if q = ""
        return
    clips := FilterViewClipsWithFavExpand(clips, viewTab, viewQuery, viewToday)
    viewTotal := clips.Length
}

LoadMoreView(*) {
    global clips, viewTab, viewQuery, viewToday, viewTotal, VIEW_PAGE_SIZE, lastAppendCount, wvCore, qqEmojiMode
    if qqEmojiMode {
        LoadMoreEmojiHits()
        return
    }
    if clips.Length >= viewTotal {
        lastAppendCount := 0
        if IsObject(wvCore)
            try wvCore.ExecuteScriptAsync("window.__loadMoreDone&&window.__loadMoreDone()")
        return
    }
    ; Offset by unique uids already loaded (ignore favGroup siblings pulled in by Ensure*)
    have := Map()
    diskN := 0
    for c in clips {
        if !IsObject(c) || !c.HasProp("uid")
            continue
        uid := Integer(c.uid)
        if have.Has(uid)
            continue
        have[uid] := true
        diskN += 1
    }
    page := QueryDiskPage(viewTab, viewQuery, viewToday, diskN, VIEW_PAGE_SIZE)
    viewTotal := page.total
    added := 0
    for c in page.items {
        if !IsObject(c) || !c.HasProp("uid")
            continue
        uid := Integer(c.uid)
        if have.Has(uid)
            continue
        clips.Push(c)
        have[uid] := true
        added += 1
    }
    lastAppendCount := added
    ; Complete any partial merge groups at the new seam
    EnsureFavGroupsComplete(clips, viewTab, viewToday)
    CacheCurrentView()
    if IsObject(wvCore)
        PushClips(true)
}

; One-time migrate clips.json →NDJSON shards of PAGE_SIZE
MigrateLegacyJsonIfNeeded() {
    global SAVE_FILE, MANIFEST_FILE, PAGE_SIZE, clipUidSeq, STORE_DIR
    EnsurePagesDir()
    if FileExist(MANIFEST_FILE)
        return
    bak := SAVE_FILE ".bak"
    src := ""
    if FileExist(SAVE_FILE)
        src := SAVE_FILE
    else if FileExist(bak)
        src := bak
    if src = "" {
        SaveManifest(Map("uidSeq", clipUidSeq, "nextPage", 1, "pages", []))
        return
    }
    try {
        txt := FileRead(src, "UTF-8")
        if txt = "" || !RegExMatch(txt, "^\s*\[")
            return
        all := []
        dirty := false
        for jo in JsonArrayToAhk(JsonParse(txt)) {
            item := ParseJoToItem(jo, &dirty)
            if IsObject(item)
                all.Push(item)
        }
        pages := []
        nextPage := 1
        i := 1
        while i <= all.Length {
            chunk := []
            loop PAGE_SIZE {
                if i > all.Length
                    break
                chunk.Push(all[i])
                i += 1
            }
            name := Format("p_{:06}.ndjson", nextPage)
            nextPage += 1
            WritePageFile(name, chunk)
            pages.Push(name)
        }
        SaveManifest(Map("uidSeq", clipUidSeq, "nextPage", nextPage, "pages", pages))
        try FileMove src, src ".migrated", 1
    } catch {
        SaveManifest(Map("uidSeq", clipUidSeq, "nextPage", 1, "pages", []))
    }
}

InitClipsFromDisk() {
    global clips, lastTxt, clipUidSeq
    clips := []
    MigrateLegacyJsonIfNeeded()
    m := LoadManifest()
    m := RepairManifestPages(m)
    SaveManifest(m)
    clipUidSeq := Integer(m["uidSeq"])
    if m["pages"].Length {
        for c in ReadPageFile(m["pages"][1]) {
            NoteQueueGroupFromItem(c)
            if c.type = "text" {
                lastTxt := c.data
                break
            }
        }
    }
    LoadQueueMeta()
    LoadPasteQueueState()
}


; Keep running after non-critical errors (clipboard exotic formats etc.)
OnError(ClipMgrOnError, 1)
ClipMgrOnError(err, mode) {
    ClipLogErr("OnError mode=" mode, err)
    return true
}

OnExit SaveAndExit
SaveAndExit(exitReason, exitCode) {
    ClipLog("OnExit reason=" exitReason " code=" exitCode " —flushing disk")
    try SavePasteQueueState()
    catch as e {
        ClipLogErr("SavePasteQueueState", e)
    }
    try SaveQueueMeta()
    catch as e {
        ClipLogErr("SaveQueueMeta", e)
    }
    try FlushDiskJobsSync()
    catch as e {
        ClipLogErr("FlushDiskJobsSync", e)
    }
    try StopCaretWatcher()
    ClipLog("OnExit done")
}

ClipLog("=== SCRIPT BOOT begin pid=" ProcessExist() " ===")
; Keep last run tail so we can compare; mark new session clearly
try {
    if FileExist(DEBUG_LOG) && FileGetSize(DEBUG_LOG) > 2 * 1024 * 1024 {
        FileMove DEBUG_LOG, DEBUG_LOG ".old", 1
    }
}
EnsureDataDir()
ClipLog("EnsureDataDir done CLIP_V1_DIR=" CLIP_V1_DIR " script=" A_ScriptDir)
InitClipsFromDisk()
ClipLog("InitClipsFromDisk done")
LoadRecentFolders()
ClipLog("LoadRecentFolders n=" (IsObject(recentFolders) ? recentFolders.Length : 0))
; Warm「最近」cache immediately —do not wait for full-disk PreloadAllViews
try CacheRecentFoldersView(false)
try CacheRecentFoldersView(true)
; 「最近文件夹」：仅记录资源管理器里双击进入的目录（无后台定时 COM）
; One-shot: trim historical screenshots over the cap (file images untouched)
SetTimer(() => PreloadAllViews("0", false), -1)

; Clipboard watch ONLY after disk init —early OnClipboardChange caused boot-copy crash
EnableClipboardWatch()
ClipLog("EnableClipboardWatch scheduled")

; Register Win+V before BuildGui (WebView2 init must not block hotkey setup)
try RegWrite(0, "REG_DWORD", "HKCU\Software\Microsoft\Clipboard", "EnableClipboardHistory")
A_MenuMaskKey := "vkE8"

; ── Win key gate ───────────────────────────────────────────
; Windows clipboard sits in a higher shell z-band; our GUI cannot cover Start/Search.
; Swallow Win on keydown and NEVER auto-forward on a timer (that was reopening Search).
; - Win+V  → our panel (Win never reaches OS)
; - Win+其它 → forward Win then the key
; - 单击 Win → on release, open Start
global winPendingL := false, winPendingR := false
global winSentL := false, winSentR := false
global winChord := false

FlushWinForSystemChord(key) {
    global winChord, winPendingL, winPendingR, winSentL, winSentR
    winChord := false
    if GetKeyState("LWin", "P") && !winSentL {
        Send("{Blind}{LWin down}")
        winSentL := true
        winPendingL := false
    }
    if GetKeyState("RWin", "P") && !winSentR {
        Send("{Blind}{RWin down}")
        winSentR := true
        winPendingR := false
    }
    Send("{Blind}{" key "}")
}
TriggerWinV(*) {
    global winChord, winPendingL, winPendingR, winSentL, winSentR
    winChord := true
    winPendingL := false
    winPendingR := false
    ; If Win was already forwarded somehow, release + dismiss Search
    if winSentL {
        Send("{Blind}{LWin up}")
        winSentL := false
    }
    if winSentR {
        Send("{Blind}{RWin up}")
        winSentR := false
    }
    if ShellOverlayIsShowing()
        DismissWindowsSearch()
    HotkeyWinV()
}

*$LWin:: {
    global winPendingL, winSentL, winChord
    winChord := false
    winPendingL := true
    winSentL := false
}
*$RWin:: {
    global winPendingR, winSentR, winChord
    winChord := false
    winPendingR := true
    winSentR := false
}
*$LWin up:: {
    global winPendingL, winSentL, winChord
    if winChord {
        winPendingL := false
        winSentL := false
        winChord := false
        return
    }
    if winSentL {
        Send("{Blind}{LWin up}")
    } else if winPendingL {
        Send("{Blind}{LWin down}{LWin up}")
    }
    winPendingL := false
    winSentL := false
}
*$RWin up:: {
    global winPendingR, winSentR, winChord
    if winChord {
        winPendingR := false
        winSentR := false
        winChord := false
        return
    }
    if winSentR {
        Send("{Blind}{RWin up}")
    } else if winPendingR {
        Send("{Blind}{RWin down}{RWin up}")
    }
    winPendingR := false
    winSentR := false
}

#HotIf GetKeyState("LWin", "P") || GetKeyState("RWin", "P")
*$v:: TriggerWinV()
; Quick Win+other —still reach the OS
*$e:: FlushWinForSystemChord("e")
*$d:: FlushWinForSystemChord("d")
*$r:: FlushWinForSystemChord("r")
*$i:: FlushWinForSystemChord("i")
*$x:: FlushWinForSystemChord("x")
*$l:: FlushWinForSystemChord("l")
*$s:: FlushWinForSystemChord("s")
*$a:: FlushWinForSystemChord("a")
*$Tab:: FlushWinForSystemChord("Tab")
*$Left:: FlushWinForSystemChord("Left")
*$Right:: FlushWinForSystemChord("Right")
*$Up:: FlushWinForSystemChord("Up")
*$Down:: FlushWinForSystemChord("Down")
*$1:: FlushWinForSystemChord("1")
*$2:: FlushWinForSystemChord("2")
*$3:: FlushWinForSystemChord("3")
*$4:: FlushWinForSystemChord("4")
*$5:: FlushWinForSystemChord("5")
*$6:: FlushWinForSystemChord("6")
*$7:: FlushWinForSystemChord("7")
*$8:: FlushWinForSystemChord("8")
*$9:: FlushWinForSystemChord("9")
*$0:: FlushWinForSystemChord("0")
*$Escape:: FlushWinForSystemChord("Escape")
*$Space:: FlushWinForSystemChord("Space")
*$m:: FlushWinForSystemChord("m")
*$n:: FlushWinForSystemChord("n")
*$p:: FlushWinForSystemChord("p")
*$u:: FlushWinForSystemChord("u")
*$h:: FlushWinForSystemChord("h")
*$k:: FlushWinForSystemChord("k")
*$g:: FlushWinForSystemChord("g")
*$c:: FlushWinForSystemChord("c")
*$b:: FlushWinForSystemChord("b")
*$t:: FlushWinForSystemChord("t")
*$w:: FlushWinForSystemChord("w")
*$z:: FlushWinForSystemChord("z")
*$f:: FlushWinForSystemChord("f")
*$q:: FlushWinForSystemChord("q")
*$y:: FlushWinForSystemChord("y")
*$o:: FlushWinForSystemChord("o")
*$j:: FlushWinForSystemChord("j")
*$,:: FlushWinForSystemChord(",")
*$.:: FlushWinForSystemChord(".")
#HotIf

; =================================================
;  Paste queue: Ctrl+Shift+C / Ctrl+Shift+V
;  (^+c / dbeaver+goland ^+v moved here from 快捷键4)
; =================================================     
PasteQueueModeActive(*) {
    global pasteQueueMode
    return !!pasteQueueMode
}
ShiftVLegacyTarget(*) {
    return WinActive("ahk_exe dbeaver.exe") || WinActive("ahk_exe datagrip64.exe")
        || WinActive("ahk_exe goland64.exe")
}

NoteQueueGroupFromItem(item) {
    global pasteQueueGroupId
    if !IsObject(item)
        return
    g := (item.HasProp("queueGroup") ? Integer(item.queueGroup) : 0)
    if g > pasteQueueGroupId
        pasteQueueGroupId := g
}

; Sync sidecar: UI queue lines survive restart even if NDJSON patch lags
LoadQueueMeta(*) {
    global QUEUE_META_FILE, queueMetaMap, pasteQueueGroupId
    queueMetaMap := Map()
    if !FileExist(QUEUE_META_FILE)
        return
    try {
        loop read QUEUE_META_FILE, "UTF-8" {
            line := Trim(A_LoopReadLine)
            if line = "" || SubStr(line, 1, 1) = "#"
                continue
            parts := StrSplit(line, "`t")
            if parts.Length < 3
                continue
            uid := Integer(parts[1])
            g := Integer(parts[2])
            i := Integer(parts[3])
            if uid < 1 || g < 1
                continue
            queueMetaMap[String(uid)] := { g: g, i: i }
            if g > pasteQueueGroupId
                pasteQueueGroupId := g
        }
        ClipLog("LoadQueueMeta n=" queueMetaMap.Count " maxGroup=" pasteQueueGroupId)
    } catch as e {
        ClipLogErr("LoadQueueMeta", e)
    }
}

SaveQueueMeta(*) {
    global QUEUE_META_FILE, CLIP_V1_DIR, queueMetaMap
    try DirCreate(CLIP_V1_DIR)
    out := ""
    if IsObject(queueMetaMap) {
        for key, meta in queueMetaMap {
            if !IsObject(meta)
                continue
            out .= Integer(key) "`t" Integer(meta.g) "`t" Integer(meta.i) "`n"
        }
    }
    AtomicWriteText(QUEUE_META_FILE, out)
}

UpsertQueueMeta(uid, g, i, save := true) {
    global queueMetaMap
    uid := Integer(uid)
    g := Integer(g)
    i := Integer(i)
    if uid < 1 || g < 1
        return
    if !IsObject(queueMetaMap)
        queueMetaMap := Map()
    ; String key — avoids AHK Map int/string Has() mismatches
    queueMetaMap[String(uid)] := { g: g, i: i }
    if save
    SaveQueueMeta()
}

RemapPasteQueueUid(oldUid, newUid) {
    global pasteQueueIds, queueMetaMap
    oldUid := Integer(oldUid)
    newUid := Integer(newUid)
    if oldUid < 1 || newUid < 1 || oldUid = newUid
        return
    if IsObject(pasteQueueIds) {
        for i, id in pasteQueueIds {
            if Integer(id) = oldUid
                pasteQueueIds[i] := newUid
        }
    }
    if IsObject(queueMetaMap) && queueMetaMap.Has(String(oldUid)) {
        meta := queueMetaMap[String(oldUid)]
        queueMetaMap.Delete(String(oldUid))
        if IsObject(meta)
            queueMetaMap[String(newUid)] := meta
        SaveQueueMeta()
    }
    ClipLog("PasteQueue remap uid " oldUid " -> " newUid)
}

ApplyQueueMetaToItem(item) {
    global queueMetaMap
    if !IsObject(item) || !IsObject(queueMetaMap)
        return
    uid := item.HasProp("uid") ? Integer(item.uid) : 0
    if uid < 1
        return
    key := String(uid)
    if !queueMetaMap.Has(key)
        return
    meta := queueMetaMap[key]
    if !IsObject(meta)
        return
    if Integer(meta.g) > 0 {
        item.queueGroup := Integer(meta.g)
        item.queueIndex := Integer(meta.i)
    }
}

SavePasteQueueState(*) {
    global QUEUE_STATE_FILE, CLIP_V1_DIR, pasteQueueMode, pasteQueueIds, pasteQueueDone, pasteQueueGroupId
    try DirCreate(CLIP_V1_DIR)
    ids := ""
    if IsObject(pasteQueueIds) {
        for i, id in pasteQueueIds
            ids .= (i > 1 ? "," : "") Integer(id)
    }
    out := "{"
    out .= '"mode":' (pasteQueueMode ? "true" : "false") ","
    out .= '"groupId":' Integer(pasteQueueGroupId) ","
    out .= '"done":' Integer(pasteQueueDone) ","
    out .= '"ids":"' ids '"'
    out .= "}"
    AtomicWriteText(QUEUE_STATE_FILE, out)
}

LoadPasteQueueState(*) {
    global QUEUE_STATE_FILE, pasteQueueMode, pasteQueueIds, pasteQueueDone, pasteQueueGroupId
    if !FileExist(QUEUE_STATE_FILE)
        return
    try {
        raw := FileRead(QUEUE_STATE_FILE, "UTF-8")
        mode := RegExMatch(raw, '"mode"\s*:\s*(true|false)', &m) ? (m[1] = "true") : false
        g := JsonFieldInt(raw, "groupId")
        done := JsonFieldInt(raw, "done")
        idsRaw := JsonFieldStr(raw, "ids")
        if g > pasteQueueGroupId
            pasteQueueGroupId := g
        pasteQueueDone := Max(0, done)
        pasteQueueIds := []
        if idsRaw != "" {
            for part in StrSplit(idsRaw, ",") {
                part := Trim(part)
                if part != ""
                    pasteQueueIds.Push(Integer(part))
            }
        }
        pasteQueueMode := mode && pasteQueueIds.Length > 0
        if pasteQueueMode
            ClipLog("PasteQueue restored n=" pasteQueueIds.Length " group=" pasteQueueGroupId " done=" pasteQueueDone)
        else {
            pasteQueueMode := false
            pasteQueueIds := []
            pasteQueueDone := 0
        }
    } catch as e {
        ClipLogErr("LoadPasteQueueState", e)
    }
}

; Start/continue queue + copy selection (counts as queue item)
$^+c:: {
    QueueCopyHotkey()
}

; 标记键盘复制，供 ClipChanged 区分「Ctrl+C」与「Ctrl+鼠标点击复制」
~^c:: {
    global lastKeyboardCopyAt
    lastKeyboardCopyAt := A_TickCount
}
~^x:: {
    global lastKeyboardCopyAt
    lastKeyboardCopyAt := A_TickCount
}

; Ctrl+左键：开 1.5s 窗口，等网页异步写入剪贴板（此时 Ctrl 往往已松开）
; 顺带：资源管理器双击 → 若进入新文件夹则记入「最近」
~*LButton:: {
    global ctrlMouseCopyUntil
    if GetKeyState("Ctrl", "P") && !GetKeyState("Shift", "P") && !GetKeyState("Alt", "P")
        ctrlMouseCopyUntil := A_TickCount + 1500
    NoteExplorerFolderDblClick()
}

; Queue on: Ctrl+V = FIFO paste. Queue off: let OS / 快捷键4 handle Ctrl+V.
#HotIf PasteQueueModeActive()
$^v:: {
    global queueFifoPasteding, pasteSending, queueFifoPasteAt
    if queueFifoPasteding
        return
    if (A_TickCount - queueFifoPasteAt) < 70
        return
    if pasteSending && (A_TickCount - queueFifoPasteAt) < 50
        return
    ; 热键返回后再粘贴：避免在物理 Ctrl+V 未结束时注入，也不会 KeyWait 变慢
    SetTimer(PasteQueueFifo, -1)
}
#HotIf

; Ctrl+Shift+V:
; - 队列开启：出队到剪贴板，若在 DBeaver/DataGrip/GoLand 再跑原有转换后粘贴；否则普通出队粘贴
; - 队列关闭：仅在上述 IDE 里做原有转换粘贴
$^+v:: {
    global queueFifoPasteding, pasteSending, queueFifoPasteAt
    if PasteQueueModeActive() {
        if queueFifoPasteding
            return
        if (A_TickCount - queueFifoPasteAt) < 70
            return
        if pasteSending && (A_TickCount - queueFifoPasteAt) < 50
            return
        SetTimer(() => PasteQueueFifo(true), -1)
        return
    }
    if !ShiftVLegacyTarget()
        return
    if WinActive("ahk_exe dbeaver.exe") || WinActive("ahk_exe datagrip64.exe")
        LegacyDbeaverShiftV()
    else if WinActive("ahk_exe goland64.exe")
        LegacyGolandShiftV()
}

; Tiny OS ToolTip at cursor — Gui tip was blocking ^+c / Ctrl+V (AHK single thread)
ShowQueueTip(title, sub := "", ms := 900) {
    ; Defer so paste/copy hotkey finishes Send first
    SetTimer(ShowQueueTipNow.Bind(String(title), String(sub), Integer(ms)), -80)
}

ShowQueueTipNow(title, sub := "", ms := 900) {
    global queueTipSeq
    queueTipSeq += 1
    seq := queueTipSeq
    text := Trim(String(title))
    ; Keep one short line by default; sub only if title is very short
    if text = "" && sub != ""
        text := Trim(String(sub))
    CoordMode "Mouse", "Screen"
    CoordMode "ToolTip", "Screen"
    MouseGetPos(&mx, &my)
    try ToolTip text, mx + 12, my + 14
    SetTimer(HideQueueTip.Bind(seq), -Max(500, Integer(ms)))
}

HideQueueTip(seq := 0) {
    global queueTipSeq
    if seq && seq != queueTipSeq
        return
    try ToolTip()
}

QueueCopyHotkey(*) {
    global pasteQueueMode, pasteQueueIds, pasteQueueGroupId, pasteQueueDone, queueCaptureArmed, queueSuppressExit, queueCopyGen
    ; Drop uids deleted from history; if none left, start a fresh session at 队列 +1
    PrunePasteQueueIds()
    if !pasteQueueMode || !pasteQueueIds.Length {
        pasteQueueMode := true
        pasteQueueIds := []
        pasteQueueDone := 0
        pasteQueueGroupId += 1
        ClipLog("PasteQueue new session group=" pasteQueueGroupId)
    }
    queueCaptureArmed := true
    queueSuppressExit := true
    queueCopyGen += 1
    gen := queueCopyGen
    ClipLog("PasteQueue hotkey ^+c armed group=" pasteQueueGroupId " n=" pasteQueueIds.Length)
    ; Holding Ctrl+Shift+C: {Blind}{Shift up} does NOT clear physical Shift, so the
    ; following ^c arrives as Ctrl+Shift+C and many apps never copy. Force real key-ups.
    SendInput "{LShift up}{RShift up}"
    Sleep 25
    ; Ctrl may stay physically down — that is correct for Ctrl+C
    SendInput "^c"
    SetTimer(() => (queueSuppressExit := false), -600)
    ; Allow app time to update clipboard; also covers "clipboard unchanged" after delete
    SetTimer(QueueCopyCatchup.Bind(gen), -250)
    SetTimer(ClearStaleQueueArm.Bind(gen), -3000)
}

; Remove FIFO slots whose clips were deleted (meta cleared in DeleteItem)
PrunePasteQueueIds(*) {
    global pasteQueueMode, pasteQueueIds, pasteQueueDone, queueCaptureArmed
    if !IsObject(pasteQueueIds) || !pasteQueueIds.Length
        return
    kept := []
    for id in pasteQueueIds {
        if PasteQueueUidAlive(Integer(id))
            kept.Push(Integer(id))
    }
    removed := pasteQueueIds.Length - kept.Length
    pasteQueueIds := kept
    if removed > 0
        ClipLog("PasteQueue prune removed=" removed " left=" pasteQueueIds.Length)
    if pasteQueueMode && !pasteQueueIds.Length {
        ; End session so next ^+c opens 队列 +1 (not +4 after deleting old rows)
        pasteQueueMode := false
        pasteQueueDone := 0
        queueCaptureArmed := false
        SavePasteQueueState()
        ClipLog("PasteQueue prune → session ended")
    } else if removed > 0 && pasteQueueMode {
        SavePasteQueueState()
    }
}

PasteQueueUidAlive(uid) {
    global clips, liveFront, queueMetaMap
    uid := Integer(uid)
    if uid < 1
        return false
    if IsObject(liveFront) {
        for c in liveFront {
            if IsObject(c) && Integer(c.uid) = uid
                return true
        }
    }
    if IsObject(clips) {
        for c in clips {
            if IsObject(c) && Integer(c.uid) = uid
                return true
        }
    }
    ; DeleteItem removes meta; if meta gone and not in memory → treat as deleted
    if IsObject(queueMetaMap) && queueMetaMap.Has(String(uid))
        return true
    return false
}

ClearStaleQueueArm(gen) {
    global queueCaptureArmed, queueCopyGen
    if queueCopyGen = gen && queueCaptureArmed
        queueCaptureArmed := false
}

; If ClipChanged skipped (same clipboard bytes), still join the queue
QueueCopyCatchup(gen) {
    global queueCaptureArmed, queueCopyGen, lastTxt, pasteQueueMode
    if queueCopyGen != gen || !queueCaptureArmed || !pasteQueueMode
        return
    txt := ""
    try txt := A_Clipboard
    if txt = "" {
        Sleep 40
        try txt := A_Clipboard
    }
    if txt = ""
        return
    ClipLog("PasteQueue catchup force-add len=" StrLen(txt))
    ; Allow duplicate of lastTxt — this path exists specifically for unchanged clipboard
    item := {
        uid: NextClipUid(),
        type: "text",
        data: txt,
        time: FormatTime(, "yyyy-MM-dd HH:mm:ss"),
        pinned: false,
        pasted: false,
        preview: SubStr(txt, 1, 500),
        charCount: StrLen(txt),
        fileCount: 0,
        width: 0,
        height: 0,
        imgFile: ""
    }
    try item.isMd := TextLooksLikeMarkdown(txt)
    try item.isRich := ClipboardHasRichText()
    ApplyClipSrc(item)
    ; Skip MemoryTake so a deleted-but-still-on-OS-clip row gets a fresh queue slot
    lastTxt := txt
    MemoryInsertFront(item)
    EnqueuePasteQueueItem(item)
    RequestUiPush()
}

; 当前 FIFO 队列里是否已有与 item 内容相同的条目
ClipContentAlreadyInPasteQueue(item) {
    global pasteQueueMode, pasteQueueIds
    if !IsObject(item) || !pasteQueueMode || !IsObject(pasteQueueIds) || !pasteQueueIds.Length
        return false
    typ := item.HasProp("type") ? item.type : ""
    data := item.HasProp("data") ? item.data : ""
    if typ = "" || data = ""
        return false
    for id in pasteQueueIds {
        c := ResolveClip(Integer(id))
        if !IsObject(c) || c.type != typ || !c.HasProp("data")
            continue
        if typ = "file" {
            if FileClipDataEqual(c.data, data)
                return true
        } else if c.data = data
            return true
    }
    return false
}

EnqueuePasteQueueItem(item) {
    global pasteQueueMode, pasteQueueIds, pasteQueueGroupId, queueCaptureArmed
    if !pasteQueueMode || !queueCaptureArmed || !IsObject(item)
        return
    queueCaptureArmed := false
    item.queueGroup := pasteQueueGroupId
    pasteQueueIds.Push(Integer(item.uid))
    item.queueIndex := pasteQueueIds.Length
    n := pasteQueueIds.Length
    ClipLog("PasteQueue enqueue uid=" item.uid " n=" n " group=" pasteQueueGroupId)
    ; Fast path only: TSV meta + paste_queue.json (restart-safe for blue lines).
    ; NEVER PersistNewItem here — disk I/O blocks the AHK thread and makes ^+c #3+ feel dead.
    try UpsertQueueMeta(Integer(item.uid), Integer(item.queueGroup), Integer(item.queueIndex))
    catch as e
        ClipLogErr("PasteQueue UpsertQueueMeta", e)
    try SavePasteQueueState()
    catch as e
        ClipLogErr("PasteQueue SavePasteQueueState", e)
    item._queuePersistQueued := true
    ; Persist ASAP without DiskRemove scan (see PersistNewItem keepQg path) — front of disk queue
    PrependDiskJob(PersistNewItem.Bind(item))
    if n = 1
        ShowQueueTip("队列 +1", "", 800)
    else
        ShowQueueTip("队列 +" n, "", 700)
}

; Right-click: restart FIFO from this queue item (same queueGroup)
ResetPasteQueueFrom(uid) {
    global pasteQueueMode, pasteQueueIds, pasteQueueDone, pasteQueueGroupId, queueCaptureArmed
    global clips, liveFront, panelVisible, queueMetaMap, uiPinned
    uid := Integer(uid)
    it := ResolveClip(uid)
    g := 0
    startIdx := 0
    if IsObject(it) {
        g := (it.HasProp("queueGroup") && Integer(it.queueGroup) > 0) ? Integer(it.queueGroup) : 0
        startIdx := (it.HasProp("queueIndex") && Integer(it.queueIndex) > 0) ? Integer(it.queueIndex) : 0
    }
    ; Fall back to sidecar meta when ResolveClip misses (item not in current page)
    if g < 1 && IsObject(queueMetaMap) && queueMetaMap.Has(String(uid)) {
        meta := queueMetaMap[String(uid)]
        if IsObject(meta) {
            g := Integer(meta.g)
            startIdx := Integer(meta.i)
        }
    }
    if g < 1 {
        ShowQueueTip("非队列项", "", 700)
        return
    }
    if startIdx < 1
        startIdx := 1

    members := [] ; {uid, qi}
    seen := Map()
    AddMember(id, qi) {
        id := Integer(id)
        qi := Integer(qi)
        if id < 1 || qi < 1
            return
        if qi < startIdx
            return
        if seen.Has(id)
            return
        seen[id] := true
        members.Push({ uid: id, qi: qi })
    }

    ; 1) Authoritative: queue_meta.tsv (survives page unload / restart)
    if IsObject(queueMetaMap) {
        for key, meta in queueMetaMap {
            if !IsObject(meta) || Integer(meta.g) != g
                continue
            AddMember(Integer(key), Integer(meta.i))
        }
    }
    ; 2) Active FIFO ids (same group session)
    if IsObject(pasteQueueIds) {
        for id in pasteQueueIds {
            id := Integer(id)
            qi := 0
            if IsObject(queueMetaMap) && queueMetaMap.Has(String(id))
                qi := Integer(queueMetaMap[String(id)].i)
            if qi < 1 {
                c := ResolveClip(id)
                if IsObject(c) && c.HasProp("queueIndex")
                    qi := Integer(c.queueIndex)
            }
            if qi < 1
                qi := id
            AddMember(id, qi)
        }
    }
    ; 3) In-memory clips / liveFront
    CollectMem(c) {
        if !IsObject(c) || !c.HasProp("uid")
            return
        if !(c.HasProp("queueGroup") && Integer(c.queueGroup) = g)
            return
        qi := (c.HasProp("queueIndex") && Integer(c.queueIndex) > 0) ? Integer(c.queueIndex) : Integer(c.uid)
        AddMember(Integer(c.uid), qi)
    }
    if IsObject(clips) {
        for c in clips
            CollectMem(c)
    }
    if IsObject(liveFront) {
        for c in liveFront
            CollectMem(c)
    }
    ; Always include the clicked item
    AddMember(uid, startIdx)

    if members.Length < 1
        return
    ; Sort by queueIndex ascending (FIFO)
    loop members.Length - 1 {
        i := 1
        while i <= members.Length - A_Index {
            if members[i].qi > members[i + 1].qi {
                tmp := members[i]
                members[i] := members[i + 1]
                members[i + 1] := tmp
            }
            i += 1
        }
    }
    startAt := 1
    for i, m in members {
        if m.uid = uid {
            startAt := i
            break
        }
    }
    newIds := []
    i := startAt
    while i <= members.Length {
        newIds.Push(members[i].uid)
        i += 1
    }
    pasteQueueMode := true
    pasteQueueIds := newIds
    pasteQueueDone := 0
    pasteQueueGroupId := g
    queueCaptureArmed := false
    MarkItemsUnpasted(newIds)
    n := newIds.Length
    ShowQueueTip("队列 重置 +" n, "", 800)
    ; Keep panel open so gray rails are visible; only soft-hide when unpinned after a beat
    if panelVisible
        SetTimer(() => PushClips(false), -50)
    ClipLog("PasteQueue resetFrom uid=" uid " n=" n " group=" g " startIdx=" startIdx)
    SavePasteQueueState()
}

; Resolve queueGroup for a uid (memory → sidecar meta)
GetPasteQueueGroupOfUid(uid) {
    global queueMetaMap
    uid := Integer(uid)
    if uid < 1
        return 0
    it := ResolveClip(uid)
    if IsObject(it) && it.HasProp("queueGroup") && Integer(it.queueGroup) > 0
        return Integer(it.queueGroup)
    if IsObject(queueMetaMap) && queueMetaMap.Has(String(uid)) {
        meta := queueMetaMap[String(uid)]
        if IsObject(meta) && Integer(meta.g) > 0
            return Integer(meta.g)
    }
    return 0
}

; All members of group g as [{uid, qi}, ...] sorted by queueIndex
CollectPasteQueueGroupMembers(g) {
    global pasteQueueIds, queueMetaMap, clips, liveFront
    g := Integer(g)
    members := []
    seen := Map()
    if g < 1
        return members
    AddMember(id, qi) {
        id := Integer(id)
        qi := Integer(qi)
        if id < 1
            return
        if qi < 1
            qi := id
        if seen.Has(id)
            return
        seen[id] := true
        members.Push({ uid: id, qi: qi })
    }
    if IsObject(queueMetaMap) {
        for key, meta in queueMetaMap {
            if !IsObject(meta) || Integer(meta.g) != g
                continue
            AddMember(Integer(key), Integer(meta.i))
        }
    }
    if IsObject(pasteQueueIds) {
        for id in pasteQueueIds {
            id := Integer(id)
            if GetPasteQueueGroupOfUid(id) != g
                continue
            qi := 0
            if IsObject(queueMetaMap) && queueMetaMap.Has(String(id))
                qi := Integer(queueMetaMap[String(id)].i)
            if qi < 1 {
                c := ResolveClip(id)
                if IsObject(c) && c.HasProp("queueIndex")
                    qi := Integer(c.queueIndex)
            }
            AddMember(id, qi)
        }
    }
    CollectMem(c) {
        if !IsObject(c) || !c.HasProp("uid")
            return
        if !(c.HasProp("queueGroup") && Integer(c.queueGroup) = g)
            return
        qi := (c.HasProp("queueIndex") && Integer(c.queueIndex) > 0) ? Integer(c.queueIndex) : Integer(c.uid)
        AddMember(Integer(c.uid), qi)
    }
    if IsObject(clips) {
        for c in clips
            CollectMem(c)
    }
    if IsObject(liveFront) {
        for c in liveFront
            CollectMem(c)
    }
    if members.Length > 1 {
        loop members.Length - 1 {
            i := 1
            while i <= members.Length - A_Index {
                if members[i].qi > members[i + 1].qi {
                    tmp := members[i]
                    members[i] := members[i + 1]
                    members[i + 1] := tmp
                }
                i += 1
            }
        }
    }
    return members
}

; Stamp queueGroup/queueIndex onto in-memory copies + sidecar + NDJSON job
ApplyPasteQueueTagsToUid(uid, g, qi, saveMeta := true) {
    global clips, liveFront, viewCache, queueMetaMap
    uid := Integer(uid)
    g := Integer(g)
    qi := Integer(qi)
    if uid < 1 || g < 1 || qi < 1
        return
    Stamp(c) {
        if !IsObject(c) || !c.HasProp("uid") || Integer(c.uid) != uid
            return
        c.queueGroup := g
        c.queueIndex := qi
    }
    if IsObject(clips) {
        for c in clips
            Stamp(c)
    }
    if IsObject(liveFront) {
        for c in liveFront
            Stamp(c)
    }
    if IsObject(viewCache) {
        for , entry in viewCache {
            if !IsObject(entry) || !entry.HasProp("items")
                continue
            for c in entry.items
                Stamp(c)
        }
    }
    try UpsertQueueMeta(uid, g, qi, saveMeta)
    catch as e
        ClipLogErr("ApplyPasteQueueTags UpsertQueueMeta", e)
    EnqueueDiskJob(DiskSetQueueMeta.Bind(uid, g, qi))
}

ClearPasteQueueTagsOnUid(uid) {
    global clips, liveFront, viewCache, queueMetaMap
    uid := Integer(uid)
    if uid < 1
        return
    Clear(c) {
        if !IsObject(c) || !c.HasProp("uid") || Integer(c.uid) != uid
            return
        c.queueGroup := 0
        c.queueIndex := 0
    }
    if IsObject(clips) {
        for c in clips
            Clear(c)
    }
    if IsObject(liveFront) {
        for c in liveFront
            Clear(c)
    }
    if IsObject(viewCache) {
        for , entry in viewCache {
            if !IsObject(entry) || !entry.HasProp("items")
                continue
            for c in entry.items
                Clear(c)
        }
    }
    if IsObject(queueMetaMap) && queueMetaMap.Has(String(uid)) {
        queueMetaMap.Delete(String(uid))
        try SaveQueueMeta()
    }
    EnqueueDiskJob(DiskSetQueueMeta.Bind(uid, 0, 0))
}

; Multi-select → one FIFO. Selection order; any touched queueGroup expands & merges.
; Mode stays on so later ^+c / Ctrl-click can keep joining this session.
EnqueueSelectedToPasteQueue(idsRaw := "") {
    global pasteQueueMode, pasteQueueIds, pasteQueueDone, pasteQueueGroupId, queueCaptureArmed, panelVisible
    raw := Trim(String(idsRaw))
    if raw = ""
        return
    sel := []
    for part in StrSplit(raw, ",") {
        id := Integer(Trim(part))
        if id > 0
            sel.Push(id)
    }
    if !sel.Length {
        ShowQueueTip("无选中项", "", 700)
        return
    }

    finalIds := []
    seenUid := Map()
    seenGroup := Map()
    AppendUid(id) {
        id := Integer(id)
        if id < 1 || seenUid.Has(id)
            return
        seenUid[id] := true
        finalIds.Push(id)
    }
    AppendGroup(g) {
        g := Integer(g)
        if g < 1 || seenGroup.Has(g)
            return
        seenGroup[g] := true
        for m in CollectPasteQueueGroupMembers(g)
            AppendUid(m.uid)
    }

    for id in sel {
        g := GetPasteQueueGroupOfUid(id)
        if g > 0
            AppendGroup(g)
        else
            AppendUid(id)
    }

    if !finalIds.Length {
        ShowQueueTip("无有效项", "", 700)
        return
    }

    ; 粘贴 FIFO：列表从下往上（clips 下标大 = 靠下 = 先出队）
    OrderPasteQueueIdsBottomToTop(&finalIds)

    pasteQueueGroupId += 1
    gNew := pasteQueueGroupId
    pasteQueueMode := true
    pasteQueueIds := finalIds
    pasteQueueDone := 0
    ; Stay in session; next ^+c arms capture to append more
    queueCaptureArmed := false

    for i, uid in finalIds
        ApplyPasteQueueTagsToUid(Integer(uid), gNew, i, false)
    try SaveQueueMeta()
    catch as e
        ClipLogErr("enqueueMany SaveQueueMeta", e)

    MarkItemsUnpasted(finalIds)
    n := finalIds.Length
    merged := seenGroup.Count
    ClipLog("PasteQueue enqueueMany n=" n " group=" gNew " mergedGroups=" merged)
    SavePasteQueueState()
    if merged > 1
        ShowQueueTip("合并队列 +" n, "", 900)
    else
        ShowQueueTip("队列 +" n, "", 800)
    ; Immediate paint — delayed PushClips raced samePaint and skipped rails
    PushClips(false)
}

; Sort uid list so FIFO pops bottom-of-list first (matches UI top=newest)
OrderPasteQueueIdsBottomToTop(&arr) {
    global clips
    if !IsObject(arr) || arr.Length < 2
        return
    pos := Map()
    if IsObject(clips) {
        for i, c in clips {
            if !IsObject(c) || !c.HasProp("uid")
                continue
            pos[Integer(c.uid)] := Integer(i)
        }
    }
    n := arr.Length
    loop n - 1 {
        i := 1
        while i <= n - A_Index {
            a := Integer(arr[i])
            b := Integer(arr[i + 1])
            pa := pos.Has(a) ? Integer(pos[a]) : -1
            pb := pos.Has(b) ? Integer(pos[b]) : -1
            ; Higher index = lower on screen → should come first in FIFO
            if pa < pb {
                tmp := arr[i]
                arr[i] := arr[i + 1]
                arr[i + 1] := tmp
            }
            i += 1
        }
    }
}

; Remove selected from FIFO + clear their queue tags. Empty → original Ctrl+V / pasteMany flow.
DequeueSelectedFromPasteQueue(idsRaw := "") {
    global pasteQueueMode, pasteQueueIds, pasteQueueDone, pasteQueueGroupId, queueCaptureArmed, panelVisible
    raw := Trim(String(idsRaw))
    if raw = ""
        return
    want := Map()
    for part in StrSplit(raw, ",") {
        id := Integer(Trim(part))
        if id > 0
            want[id] := true
    }
    if !want.Count {
        ShowQueueTip("无选中项", "", 700)
        return
    }

    removed := 0
    for id, _ in want {
        had := GetPasteQueueGroupOfUid(id) > 0
        inFifo := false
        if IsObject(pasteQueueIds) {
            i := 1
            while i <= pasteQueueIds.Length {
                if Integer(pasteQueueIds[i]) = id {
                    pasteQueueIds.RemoveAt(i)
                    inFifo := true
                    continue
                }
                i += 1
            }
        }
        if had || inFifo {
            ClearPasteQueueTagsOnUid(id)
            removed += 1
        }
    }

    if !removed {
        ShowQueueTip("非队列项", "", 700)
        return
    }

    if !IsObject(pasteQueueIds) || !pasteQueueIds.Length {
        ExitPasteQueue("dequeue-empty")
        ShowQueueTip("已出队 · 原流程", "", 800)
        PushClips(false)
        return
    }

    ; Reindex remaining under current group
    gKeep := pasteQueueGroupId
    if gKeep < 1
        gKeep := 1
    for i, uid in pasteQueueIds
        ApplyPasteQueueTagsToUid(Integer(uid), gKeep, i, false)
    try SaveQueueMeta()
    catch as e
        ClipLogErr("dequeueMany SaveQueueMeta", e)
    pasteQueueMode := true
    pasteQueueDone := 0
    queueCaptureArmed := false
    SavePasteQueueState()
    ClipLog("PasteQueue dequeueMany removed=" removed " left=" pasteQueueIds.Length)
    ShowQueueTip("已出队 剩 +" pasteQueueIds.Length, "", 800)
    PushClips(false)
}

MarkItemsUnpasted(uids) {
    global clips, viewCache, liveFront, wvCore
    want := Map()
    idList := []
    for uid in uids {
        id := Integer(uid)
        if id < 1
            continue
        want[id] := true
        idList.Push(id)
    }
    if !want.Count
        return
    for c in clips {
        if want.Has(c.uid)
            c.pasted := false
    }
    if IsObject(liveFront) {
        for c in liveFront {
            if IsObject(c) && want.Has(c.uid)
                c.pasted := false
        }
    }
    for , entry in viewCache {
        if !IsObject(entry) || !entry.HasProp("items")
            continue
        for c in entry.items {
            if want.Has(c.uid)
                c.pasted := false
        }
    }
    EnqueueDiskJob(DiskSetPasted.Bind(want, false))
    ; Instant gray rails / clear ✓ — same path as mark pasted
    if IsObject(wvCore) && idList.Length {
        jsIds := ""
        for i, id in idList
            jsIds .= (i > 1 ? "," : "") id
        try wvCore.ExecuteScriptAsync("window.__markUnpasted&&window.__markUnpasted([" jsIds "])")
    }
}

ExitPasteQueue(reason := "") {
    global pasteQueueMode, pasteQueueIds, pasteQueueDone, queueCaptureArmed
    if !pasteQueueMode && !pasteQueueIds.Length
        return
    ClipLog("PasteQueue exit reason=" reason " left=" pasteQueueIds.Length)
    pasteQueueMode := false
    pasteQueueIds := []
    pasteQueueDone := 0
    queueCaptureArmed := false
    SavePasteQueueState()
    if reason = "foreign-clip" || reason = "deleted-all" || reason = "clear-tab"
        ShowQueueTip("队列结束", "", 700)
}

PasteQueueFifo(useLegacy := false) {
    global pasteQueueMode, pasteQueueIds, pasteQueueDone, clipIgnore, queueFifoPasteding, queueFifoPasteAt, uiPinned, panelVisible
    if queueFifoPasteding
        return
    if !pasteQueueMode && !(IsObject(pasteQueueIds) && pasteQueueIds.Length) {
        return
    }
    pasteQueueMode := true
    if !pasteQueueIds.Length {
        ExitPasteQueue("empty")
        return
    }
    queueFifoPasteding := true
    queueFifoPasteAt := A_TickCount
    clipIgnore := true
    pastedOk := false
    uid := 0
    didLegacy := false
    try {
        ; Peek first — only dequeue after a successful paste
        uid := Integer(pasteQueueIds[1])
        item := ResolveClip(uid)
        if !IsObject(item) {
            ClipLog("PasteQueueFifo miss uid=" uid " —drop dead slot")
            pasteQueueIds.RemoveAt(1)
            SetTimer(SavePasteQueueState, -1)
            ShowQueueTip("队列 缺项 跳过", "", 700)
            if !pasteQueueIds.Length
                ExitPasteQueue("missing-empty")
            return
        }
        EnsureClipBodyLoaded(item)
        ; Panel open: hide first so Send ^v goes to the editor
        if panelVisible && !uiPinned
            HidePanel()
        ok := false
        if item.type = "file" {
            paths := GetItemFilePaths(item)
            if paths.Length
                ok := SetClipboardFiles(paths)
        } else if item.type = "image" {
            paths := BuildAhkNamedPastePaths([item])
            if paths.Length
                ok := SetClipboardFiles(paths)
        }
        if !ok
            ok := PutItemOnClipboard(item)
        if !ok {
            ClipLog("PasteQueueFifo put fail uid=" uid " type=" item.type)
            ShowQueueTip("队列 粘贴失败", "", 800)
            return
        }
        ; 队列 Ctrl+V：人已经在编辑器里，优先用当前前台窗。
        ; 勿盲目 ForceActivate(lastGoodActiveWin)——面板关着时该值常过期，会把 ^v 打到别的窗口，只剩 tip。
        cur := 0
        try cur := WinGetID("A")
        target := 0
        if cur
            && !(IsObject(guiWin) && guiWin.Hwnd && cur = guiWin.Hwnd)
            && !IsWindowOwnedByPanel(cur)
            && !IsShellOverlayHwnd(cur)
            && !IsScreenshotHelperHwnd(cur)
            target := cur
        else
            target := ResolvePasteTargetWin()
        if !target
            target := cur
        if target && target != cur
            ForceActivateHwnd(target)
        Sleep 25
        if useLegacy && ShiftVLegacyTarget() {
            if WinActive("ahk_exe dbeaver.exe") || WinActive("ahk_exe datagrip64.exe")
                didLegacy := LegacyDbeaverShiftV()
            else if WinActive("ahk_exe goland64.exe")
                didLegacy := LegacyGolandShiftV()
        }
        if !didLegacy
            TriggerPasteKey()
        fgAfter := 0
        try fgAfter := WinGetID("A")
        ClipLog("PasteQueueFifo paste uid=" uid " type=" item.type " cur=" cur " target=" target " fg=" fgAfter)
        pasteQueueIds.RemoveAt(1)
        pasteQueueDone += 1
        pastedOk := true
        queueFifoPasteAt := A_TickCount
        MarkItemsPasted([uid])
        done := pasteQueueDone
        left := pasteQueueIds.Length
        if left = 0 {
            ShowQueueTip("队列 完成 -" done, "", 800)
            ExitPasteQueue("drained")
        } else {
            ShowQueueTip("队列 -" done " 剩" left, "", 700)
            SetTimer(SavePasteQueueState, -1)
        }
        ClipLog("PasteQueueFifo ok uid=" uid " left=" left " legacy=" (didLegacy ? 1 : 0))
    } finally {
        queueFifoPasteding := false
        SetTimer(() => (clipIgnore := false), -200)
        if uiPinned && panelVisible
            SetTimer(RaiseClipboardPanel, -50)
    }
    if !pastedOk && uid > 0
        ClipLog("PasteQueueFifo aborted uid=" uid " kept in queue")
}

ClipArrHas(arr, value) {
    for item in arr {
        if item == value
            return A_Index
    }
    return 0
}
ClipStrEndWith(str, sub) {
    if !InStr(str, sub)
        return 0
    return SubStr(str, StrLen(str) - StrLen(sub) + 1) == sub ? 1 : 0
}
ClipJoinArr(arr, separator := ",", L := "[", R := "]", quote := "") {
    out := L
    for i, v in arr {
        if i > 1
            out .= separator
        out .= quote v quote
    }
    return out R
}
ClipUnderlineToPascal(selectStr) {
    selectStr := String(selectStr)
    if InStr(selectStr, "_") {
        camel := ""
        Loop Parse selectStr, "_" {
            if A_Index = 1
                camel := A_LoopField
            else
                camel .= StrUpper(SubStr(A_LoopField, 1, 1)) StrLower(SubStr(A_LoopField, 2))
        }
        selectStr := camel
    }
    return RegExReplace(selectStr, "(\b\w)", "$U1")
}

LegacyDbeaverShiftV(*) {
    global clipIgnore, pasteSending, queueFifoPasteAt
    clip := A_Clipboard
    if InStr(Trim(clip), "('") = 1
        return false
    strArr := []
    delim := ClipStrEndWith(Trim(clip), "|") ? "|" : "`n"
    Loop Parse clip, delim {
        currentLine := Trim(Trim(A_LoopField), "`r`n")
        if currentLine != "" && !ClipArrHas(strArr, currentLine)
            strArr.Push(currentLine)
    }
    if !strArr.Length
        return false
    caseA := ClipJoinArr(strArr, ",", "", "", "")
    caseB := strArr.Length <= 2
        ? ClipJoinArr(strArr, ",", "(", ")", "'")
        : ClipJoinArr(strArr, ",`n", "(", ")", "'")
    clipIgnore := true
    pasteSending := true
    queueFifoPasteAt := A_TickCount
    ok := false
    try {
        A_Clipboard := ClipStrEndWith(Trim(clip), "|") ? caseA : (caseB . ";")
        Sleep 50
        TriggerPasteKey()
        ok := true
    } finally {
        SetTimer(() => (clipIgnore := false), -400)
    }
    return ok
}

LegacyGolandShiftV(*) {
    global clipIgnore, pasteSending, queueFifoPasteAt
    clip := A_Clipboard
    if !InStr(Trim(clip), "|")
        return false
    strArr := [""]
    Loop Parse clip, "|" {
        currentLine := Trim(Trim(A_LoopField), "`r`n")
        if currentLine = "" || ClipArrHas(strArr, currentLine)
            continue
        fieldType := " string"
        if ClipArrHas(["created_at", "updated_at"], currentLine)
            fieldType := " time.Time"
        strArr.Push(ClipUnderlineToPascal(currentLine) . fieldType . ' ``json:"' . currentLine . '"``')
    }
    if strArr.Length < 2
        return false
    caseA := ClipJoinArr(strArr, "`n", "", "", "")
    clipIgnore := true
    pasteSending := true
    queueFifoPasteAt := A_TickCount
    ok := false
    try {
        A_Clipboard := caseA
        Sleep 50
        TriggerPasteKey()
        ok := true
    } finally {
        SetTimer(() => (clipIgnore := false), -400)
    }
    return ok
}

; ?? / ？？：不要注册 ~?（中文键盘布局没有独立问号键，会弹 AHK 提示且热键无效）
QQInstallSearchHotkeys()
StartCaretWatcher()
SetTimer(RememberGoodActiveWin, 1000)
ClipLog("=== SCRIPT BOOT auto-execute END —waiting for clipReady ===")

; 启动立刻后台预热：先出骨架，再加载完整 UI（把 ~2s 挪到脚本启动后）
SetTimer(WarmWebViewEarly, -1)

; =================================================
;  Init: create data\clip_v1 dirs and write HTML
; =================================================
EnsureDataDir() {
    global CLIP_V1_DIR, HTML_FILE, STORE_DIR, PAGES_DIR, PAYLOAD_DIR
    try DirCreate CLIP_V1_DIR
    try DirCreate STORE_DIR
    try DirCreate PAGES_DIR
    try DirCreate PAYLOAD_DIR
    WriteHtmlFile()
}

; Arm clipboard AFTER disk init. Early OnClipboardChange raced boot and crashed on first copy.
EnableClipboardWatch(*) {
    static registered := false
    if !registered {
        OnClipboardChange ClipChanged
        registered := true
        ClipLog("OnClipboardChange registered")
    }
    ; Brief settle so auto-execute / tray finish before accepting copies
    SetTimer(ArmClipboardReady, -1000)
    ; Was 2s file IO → busy cursor; only heartbeat when panel open / slow interval
    SetTimer(ClipLogHeartbeat, 15000)
    ClipLog("ArmClipboardReady in 1000ms + heartbeat 2s")
}

ArmClipboardReady(*) {
    global clipReady, pasteQueueMode, pasteQueueIds
    clipReady := true
    ClipLog("clipReady=TRUE —accepting clipboard now")
    if pasteQueueMode && IsObject(pasteQueueIds) && pasteQueueIds.Length > 0
        SetTimer(() => ShowQueueTip("队列 恢复 +" pasteQueueIds.Length, "", 900), -800)
}

ClipLogHeartbeat(*) {
    global clipReady, diskScanBusy, diskJobBusy, diskJobQueue, panelVisible, wvBuilding, clips
    if !panelVisible
        return
    q := 0
    try q := diskJobQueue.Length
    n := 0
    try n := clips.Length
    ClipLog("HB ready=" clipReady " scan=" diskScanBusy " jobBusy=" diskJobBusy
        . " q=" q " panel=" panelVisible " wvBuild=" wvBuilding " clips=" n)
}

WriteHtmlFile() {
    global HTML_FILE, HTML_B64, CLIP_V1_DIR, UI_CACHE_VER
    ver := UiCacheVer()
    ; 开发态优先用脚本旁解码 HTML，改 UI 不用重编整段 base64
    decoded := A_ScriptDir "\_clip_ui_decoded.html"
    srcText := ""
    if FileExist(decoded) {
        try srcText := FileRead(decoded, "UTF-8")
    }
    if FileExist(HTML_FILE) {
        try {
            existing := FileRead(HTML_FILE, "UTF-8")
            if ver != "" && InStr(existing, 'data-ui-ver="' ver '"') {
                ClipLog("WriteHtmlFile SKIP unchanged ver=" ver)
                return
            }
        } catch {
        }
    }
    try DirCreate(CLIP_V1_DIR)
    if srcText != "" {
        if ver != "" && !InStr(srcText, 'data-ui-ver="' ver '"')
            srcText := RegExReplace(srcText, 'data-ui-ver="[^"]*"', 'data-ui-ver="' ver '"', &_, 1)
        AtomicWriteText(HTML_FILE, srcText)
        ClipLog("WriteHtmlFile from decoded -> " HTML_FILE " ver=" ver)
        return
    }
    B64DecodeToFile(HTML_B64, HTML_FILE)
    ClipLog("WriteHtmlFile -> " HTML_FILE " ver=" ver)
}

; =================================================
;  Ctrl+V: save clipboard image(s) into the active folder (not data\clip_v1)
; =================================================
; =================================================
;  Recent Explorer folders (double-click into dir -> "最近" tab)
; =================================================
NormalizeFolderPath(path) {
    path := Trim(String(path))
    if path = ""
        return ""
    try path := RTrim(path, "\/")
    try {
        n := DllCall("kernel32\GetLongPathNameW", "WStr", path, "Ptr", 0, "UInt", 0, "UInt")
        if n > 0 {
            buf := Buffer(n * 2)
            if DllCall("kernel32\GetLongPathNameW", "WStr", path, "Ptr", buf, "UInt", n, "UInt")
                path := RTrim(StrGet(buf, "UTF-16"), "\/")
        }
    }
    return path
}

IsDesktopFolderPath(path) {
    path := NormalizeFolderPath(path)
    if path = ""
        return true
    p := StrLower(path)
    d1 := StrLower(NormalizeFolderPath(A_Desktop))
    d2 := StrLower(NormalizeFolderPath(A_DesktopCommon))
    if d1 != "" && p = d1
        return true
    if d2 != "" && p = d2
        return true
    if InStr(p, "::{") = 1
        return true
    return false
}

; Skip drive roots like C:\ / D:\ and bare UNC shares
IsDriveRootFolderPath(path) {
    path := NormalizeFolderPath(path)
    if path = ""
        return true
    if RegExMatch(path, "i)^[a-z]:\\?$")
        return true
    if RegExMatch(path, "^\\\\[^\\]+\\[^\\]+$")
        return true
    return false
}

RecentPathIsParentOf(parent, child) {
    parent := StrLower(NormalizeFolderPath(parent))
    child := StrLower(NormalizeFolderPath(child))
    if parent = "" || child = "" || parent = child
        return false
    return InStr(child "\", parent "\") = 1
}

UnescapeJsonStr(s) {
    s := String(s)
    s := StrReplace(s, "\\", "\x00")
    s := StrReplace(s, "\/", "/")
    s := StrReplace(s, '\"', '"')
    s := StrReplace(s, "\n", "`n")
    s := StrReplace(s, "\r", "`r")
    s := StrReplace(s, "\t", "`t")
    s := StrReplace(s, "\x00", "\")
    return s
}

MakeRecentFolderItem(uid, path, time := "", pinned := false, favTitle := "") {
    if time = ""
        time := FormatTime(, "yyyy-MM-dd HH:mm:ss")
    return {
        uid: Integer(uid),
        type: "recent",
        time: time,
        pinned: !!pinned,
        pasted: false,
        charCount: StrLen(path),
        fileCount: 0,
        width: 0,
        height: 0,
        preview: path,
        data: path,
        imgFile: "",
        favTitle: Trim(String(favTitle)),
        favGroup: "",
        linkTitle: "",
        linkHost: "",
        srcIcon: "",
        srcExe: "",
        srcTitle: "",
        isMd: false,
        isRich: false
    }
}

IsRecentFolderPinned(c) {
    return IsObject(c) && c.HasProp("pinned") && c.pinned
}

TrimRecentFoldersToMax(*) {
    global recentFolders, MAX_RECENT_FOLDERS
    if !IsObject(recentFolders)
        return
    while recentFolders.Length > MAX_RECENT_FOLDERS {
        removed := false
        i := recentFolders.Length
        while i >= 1 {
            if !IsRecentFolderPinned(recentFolders[i]) {
                recentFolders.RemoveAt(i)
                removed := true
                break
            }
            i -= 1
        }
        if !removed
            break
    }
}

RecentFoldersHasEvictable(*) {
    global recentFolders
    if !IsObject(recentFolders)
        return false
    for c in recentFolders {
        if !IsRecentFolderPinned(c)
            return true
    }
    return false
}

LoadRecentFolders(*) {
    global recentFolders, recentFolderUidSeq, RECENT_FOLDERS_FILE, MAX_RECENT_FOLDERS
    recentFolders := []
    if !FileExist(RECENT_FOLDERS_FILE)
        return
    try {
        raw := FileRead(RECENT_FOLDERS_FILE, "UTF-8")
        raw := Trim(raw)
        if raw = "" || SubStr(raw, 1, 1) != "["
            return
        pos := 1
        while RegExMatch(raw, '\{[^{}]*\}', &m, pos) {
            block := m[0]
            path := ""
            if RegExMatch(block, '"path"\s*:\s*"((?:\\.|[^"\\])*)"', &pm)
                path := UnescapeJsonStr(pm[1])
            path := NormalizeFolderPath(path)
            if path = "" || IsDesktopFolderPath(path) || IsDriveRootFolderPath(path) {
                pos := m.Pos + m.Len
                continue
            }
            uid := 0
            if RegExMatch(block, '"uid"\s*:\s*(-?\d+)', &um)
                uid := Integer(um[1])
            if uid < 1
                uid := ++recentFolderUidSeq
            else if uid >= recentFolderUidSeq
                recentFolderUidSeq := uid
            time := ""
            if RegExMatch(block, '"time"\s*:\s*"((?:\\.|[^"\\])*)"', &tm)
                time := UnescapeJsonStr(tm[1])
            if time = ""
                time := FormatTime(, "yyyy-MM-dd HH:mm:ss")
            pinned := false
            if RegExMatch(block, '"pinned"\s*:\s*(true|false|1|0)', &pim)
                pinned := (pim[1] = "true" || pim[1] = "1")
            favTitle := ""
            if RegExMatch(block, '"favTitle"\s*:\s*"((?:\\.|[^"\\])*)"', &ftm)
                favTitle := UnescapeJsonStr(ftm[1])
            recentFolders.Push(MakeRecentFolderItem(uid, path, time, pinned, favTitle))
            pos := m.Pos + m.Len
            if recentFolders.Length >= MAX_RECENT_FOLDERS
                break
        }
    } catch as e {
        ClipLogErr("LoadRecentFolders", e)
        recentFolders := []
    }
}

SaveRecentFolders(*) {
    global recentFolders, RECENT_FOLDERS_FILE, CLIP_V1_DIR
    try {
        if !DirExist(CLIP_V1_DIR)
            DirCreate CLIP_V1_DIR
        out := "["
        first := true
        if IsObject(recentFolders) {
            for c in recentFolders {
                if !first
                    out .= ","
                first := false
                path := c.HasProp("data") ? String(c.data) : String(c.preview)
                favTitle := c.HasProp("favTitle") ? String(c.favTitle) : ""
                out .= "{"
                out .= '"uid":' Integer(c.uid) ","
                out .= '"path":' JsonStr(path) ","
                out .= '"time":' JsonStr(c.HasProp("time") ? c.time : "") ","
                out .= '"pinned":' (IsRecentFolderPinned(c) ? "true" : "false") ","
                out .= '"favTitle":' JsonStr(favTitle)
                out .= "}"
            }
        }
        out .= "]"
        tmp := RECENT_FOLDERS_FILE ".tmp"
        if FileExist(tmp)
            try FileDelete tmp
        FileAppend out, tmp, "UTF-8"
        if FileExist(RECENT_FOLDERS_FILE)
            try FileDelete RECENT_FOLDERS_FILE
        FileMove tmp, RECENT_FOLDERS_FILE
    } catch as e {
        ClipLogErr("SaveRecentFolders", e)
    }
}

RecordRecentFolder(path) {
    global recentFolders, recentFolderUidSeq, MAX_RECENT_FOLDERS, viewTab, viewQuery, viewToday, panelVisible
    path := NormalizeFolderPath(path)
    if path = "" || IsDesktopFolderPath(path) || IsDriveRootFolderPath(path)
        return false
    if !DirExist(path)
        return false
    key := StrLower(path)
    keptUid := 0
    keptPinned := false
    keptTitle := ""
    foundSame := false
    i := 1
    while IsObject(recentFolders) && i <= recentFolders.Length {
        c := recentFolders[i]
        p := StrLower(NormalizeFolderPath(c.HasProp("data") ? c.data : c.preview))
        if p = "" {
            recentFolders.RemoveAt(i)
            continue
        }
        if p = key {
            foundSame := true
            keptUid := Integer(c.uid)
            keptPinned := IsRecentFolderPinned(c)
            keptTitle := c.HasProp("favTitle") ? String(c.favTitle) : ""
            recentFolders.RemoveAt(i)
            continue
        }
        if RecentPathIsParentOf(p, key) {
            if IsRecentFolderPinned(c) {
                i += 1
                continue
            }
            recentFolders.RemoveAt(i)
            continue
        }
        i += 1
    }
    if !IsObject(recentFolders)
        recentFolders := []
    if !foundSame && recentFolders.Length >= MAX_RECENT_FOLDERS && !RecentFoldersHasEvictable()
        return false
    if keptUid < 1
        keptUid := ++recentFolderUidSeq
    item := MakeRecentFolderItem(keptUid, path, "", keptPinned, keptTitle)
    recentFolders.InsertAt(1, item)
    TrimRecentFoldersToMax()
    SaveRecentFolders()
    InvalidateRecentViewCaches()
    try CacheRecentFoldersView(false)
    try CacheRecentFoldersView(true)
    if panelVisible && viewTab = "recent" {
        try SetView("recent", viewQuery, viewToday ? "1" : "0")
    }
    return true
}

IsExplorerOrDesktopFront(*) {
    if WinActive("ahk_class CabinetWClass") || WinActive("ahk_class ExploreWClass")
        return true
    if WinActive("ahk_class WorkerW") || WinActive("ahk_class Progman")
        return true
    return false
}

; 资源管理器/桌面：检测到双击后，等导航完成；路径变了 = 双击进了文件夹 → 记历史
NoteExplorerFolderDblClick(*) {
    static lastTick := 0, lastX := -99999, lastY := -99999
    if !IsExplorerOrDesktopFront()
        return
    CoordMode "Mouse", "Screen"
    MouseGetPos(&x, &y)
    now := A_TickCount
    dblMs := 500
    try dblMs := Integer(DllCall("GetDoubleClickTime", "UInt"))
    if dblMs < 200
        dblMs := 500
    if (now - lastTick) <= dblMs && Abs(x - lastX) <= 6 && Abs(y - lastY) <= 6 {
        lastTick := 0
        lastX := -99999
        lastY := -99999
        before := ""
        try before := NormalizeFolderPath(GetActiveFolderPath())
        ; 导航后重试：导航有时慢于双击回调
        SetTimer(TryRecordExplorerDblNav.Bind(before, 1), -180)
        return
    }
    lastTick := now
    lastX := x
    lastY := y
}

TryRecordExplorerDblNav(beforePath, attempt := 1) {
    global lastExplorerFolder
    beforePath := NormalizeFolderPath(beforePath)
    after := ""
    try after := NormalizeFolderPath(GetActiveFolderPath())
    if after != "" && after != beforePath {
        if after = lastExplorerFolder
            return
        lastExplorerFolder := after
        RecordRecentFolder(after)
        ClipLog("ExplorerDblClick folder=" after)
        return
    }
    if Integer(attempt) < 4
        SetTimer(TryRecordExplorerDblNav.Bind(beforePath, Integer(attempt) + 1), -220)
}

; 兼容旧名（若别处误调）：不再用于 Tab/面板打开
CaptureActiveExplorerFolder(*) {
    return false
}

QueryRecentFoldersPage(query, todayOnly, offset, limit) {
    global recentFolders
    q := Trim(String(query))
    ; 无搜索：按访问时间（newest first），固定只防淘汰不置顶
    ; 有搜索：命中的固定项排到前面，组内仍按原时间序
    pinnedHits := []
    normalHits := []
    if IsObject(recentFolders) {
        for c in recentFolders {
            if !ItemMatchesView(c, "recent", query, todayOnly)
                continue
            if q != "" && IsRecentFolderPinned(c)
                pinnedHits.Push(c)
            else
                normalHits.Push(c)
        }
    }
    all := []
    for c in pinnedHits
        all.Push(c)
    for c in normalHits
        all.Push(c)
    items := []
    i := Integer(offset) + 1
    while i <= all.Length && items.Length < limit {
        items.Push(all[i])
        i += 1
    }
    return { items: items, total: all.Length }
}

ClearRecentFolders(*) {
    global recentFolders
    kept := []
    if IsObject(recentFolders) {
        for c in recentFolders {
            if IsRecentFolderPinned(c)
                kept.Push(c)
        }
    }
    recentFolders := kept
    SaveRecentFolders()
}

CacheRecentFoldersView(todayFlag := false) {
    global viewCache, tabTotals, recentFolders, VIEW_PAGE_SIZE
    key := ViewCacheKey("recent", "", todayFlag)
    items := []
    total := 0
    if IsObject(recentFolders) {
        for c in recentFolders {
            if !ItemMatchesTabToday(c, "recent", todayFlag)
                continue
            total += 1
            if items.Length < VIEW_PAGE_SIZE
                items.Push(c)
        }
    }
    viewCache[key] := { items: items, total: total }
    if IsObject(tabTotals)
        tabTotals[key] := total
}

InvalidateRecentViewCaches(*) {
    global viewCache, tabTotals
    if !IsObject(viewCache)
        return
    dropKeys := []
    for key, _ in viewCache {
        tab := "", todayOnly := false, query := ""
        ParseViewCacheKey(key, &tab, &todayOnly, &query)
        if tab = "recent"
            dropKeys.Push(key)
    }
    for key in dropKeys {
        viewCache.Delete(key)
        if IsObject(tabTotals) && tabTotals.Has(key)
            tabTotals.Delete(key)
    }
}


PastePngToDir() {
    hasBmp   := DllCall("IsClipboardFormatAvailable", "UInt", 2, "Int")
    hasDib   := DllCall("IsClipboardFormatAvailable", "UInt", 8, "Int")
    hasFiles := DllCall("IsClipboardFormatAvailable", "UInt", 15, "Int")
    if !hasBmp && !hasDib && !hasFiles
        return

    saveDir := GetActiveFolderPath()
    if saveDir = ""
        return  ; only act when Explorer/Desktop is active

    ; CF_HDROP: copy each image file into the current folder
    if hasFiles {
        files := []
        raw := A_Clipboard
        if raw != "" {
            for ln in StrSplit(raw, "`n", "`r") {
                ln := Trim(ln)
                if ln != ""
                    files.Push(ln)
            }
        }
        if files.Length = 0
            files := GetClipboardFileList()

        stamp := FormatTime(, "yyyyMMdd_HHmmss")
        copied := 0
        for ln in files {
            if ln = "" || !FileExist(ln)
                continue
            ; Skip directories  — never copy/create folder trees
            if InStr(FileExist(ln), "D")
                continue
            dotPos := InStr(ln, ".", false, -1)
            ext := dotPos > 0 ? StrLower(SubStr(ln, dotPos + 1)) : ""
            if !IsImgExt(ext)
                continue
            dest := saveDir "\ahk_" stamp "_" (++copied) "." ext
            try FileCopy ln, dest, 1
        }
        return
    }

    ; Single bitmap/DIB (screenshot, etc.)
    if hasBmp || hasDib {
        stamp   := FormatTime(, "yyyyMMdd_HHmmss")
        imgPath := saveDir "\ahk_" stamp "_1.png"
        SaveClipboardImageToFile(imgPath)
    }
}

; Active Explorer folder, desktop, or empty
GetActiveFolderPath() {
    try {
        if WinActive("ahk_class WorkerW") || WinActive("ahk_class Progman")
            return A_Desktop
        hwnd := WinActive("ahk_class CabinetWClass")
        if !hwnd
            hwnd := WinActive("ahk_class ExploreWClass")
        if !hwnd
            return ""
        for win in ComObject("Shell.Application").Windows {
            try {
                if (win.HWND = hwnd) {
                    path := win.Document.Folder.Self.Path
                    if path != ""
                        return path
                }
            }
        }
    }
    return ""
}

; Enumerate all CF_HDROP paths (supports multi-select; OpenClipboard retry)
GetClipboardFileList() {
    files := []
    opened := false
    loop 10 {
        if DllCall("OpenClipboard", "Ptr", 0) {
            opened := true
            break
        }
        Sleep 20
    }
    if !opened
        return files
    try {
        hDrop := DllCall("GetClipboardData", "UInt", 15, "Ptr")
        if !hDrop
            return files
        cnt := DllCall("shell32\DragQueryFileW", "Ptr", hDrop, "UInt", 0xFFFFFFFF, "Ptr", 0, "UInt", 0, "UInt")
        loop cnt {
            n := DllCall("shell32\DragQueryFileW", "Ptr", hDrop, "UInt", A_Index - 1, "Ptr", 0, "UInt", 0, "UInt")
            if n < 1
                continue
            buf := Buffer((n + 1) * 2, 0)
            DllCall("shell32\DragQueryFileW", "Ptr", hDrop, "UInt", A_Index - 1, "Ptr", buf, "UInt", n + 1)
            files.Push(StrGet(buf, "UTF-16"))
        }
    } finally {
        DllCall("CloseClipboard")
    }
    return files
}

IsImgExt(ext) {
    return RegExMatch(ext, "^(?i)(?:png|jpe?g|gif|webp|bmp|ico|tiff?)$") > 0
}

SaveClipboardImageToFile(path) {
    pToken := 0, pBitmap := 0, hCopy := 0
    try {
        DllCall("LoadLibrary", "Str", "gdiplus.dll", "Ptr")
        si := Buffer(24, 0)
        NumPut("UInt", 1, si)
        if DllCall("gdiplus\GdiplusStartup", "Ptr*", &pToken, "Ptr", si, "Ptr", 0)
            return false
        if !DllCall("OpenClipboard", "Ptr", 0)
            return false
        hSrc := DllCall("GetClipboardData", "UInt", 2, "Ptr")
        if hSrc
            hCopy := DllCall("CopyImage", "Ptr", hSrc, "UInt", 0, "Int", 0, "Int", 0, "UInt", 0x2008, "Ptr")
        DllCall("CloseClipboard")
        if !hCopy
            return false
        if DllCall("gdiplus\GdipCreateBitmapFromHBITMAP", "Ptr", hCopy, "Ptr", 0, "Ptr*", &pBitmap)
            return false
        DllCall("DeleteObject", "Ptr", hCopy), hCopy := 0
        if !pBitmap
            return false
        clsid := Buffer(16)
        DllCall("ole32\CLSIDFromString", "Str", "{557CF406-1A04-11D3-9A73-0000F81EF32E}", "Ptr", clsid)
        DllCall("gdiplus\GdipSaveImageToFile", "Ptr", pBitmap, "WStr", path, "Ptr", clsid, "Ptr", 0)
        return true
    } catch {
        return false
    } finally {
        if hCopy {
            try DllCall("DeleteObject", "Ptr", hCopy)
        }
        if pBitmap {
            try DllCall("gdiplus\GdipDisposeImage", "Ptr", pBitmap)
        }
        if pToken {
            try DllCall("gdiplus\GdiplusShutdown", "Ptr", pToken)
        }
    }
}
