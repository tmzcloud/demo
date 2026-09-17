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
UI_CACHE_VER := "20260917-f2-title"
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
77u/PCFET0NUWVBFIGh0bWw+CjxodG1sIGxhbmc9InpoLUNOIj4KPGhlYWQ+CiAgICA8bWV0YSBj
aGFyc2V0PSJVVEYtOCI+CiAgICA8dGl0bGU+5Ymq6LS05p2/PC90aXRsZT4KICAgIDxzdHlsZT4K
ICAgICAgICA6cm9vdCB7CiAgICAgICAgICAgIC0tYmc6ICAgICAjZWVmMWY2OwogICAgICAgICAg
ICAtLWFjYzogICAgIzViNzNlODsKICAgICAgICAgICAgLS10eHQ6ICAgICMyYzJlMzY7CiAgICAg
ICAgICAgIC0tdHh0MjogICAjNmI3MDgwOwogICAgICAgICAgICAtLXR4dDM6ICAgIzlhYTBiMDsK
ICAgICAgICAgICAgLS1jYXJkOiAgICNmZmZmZmY7CiAgICAgICAgICAgIC0tY2FyZC1oOiAjZjhm
OWZjOwogICAgICAgICAgICAtLXI6ICAgICAgNHB4OwogICAgICAgICAgICAtLXRyOiAgICAgMC4x
MnMgZWFzZTsKICAgICAgICB9CiAgICAgICAgKiwgKjo6YmVmb3JlLCAqOjphZnRlciB7IGJveC1z
aXppbmc6IGJvcmRlci1ib3g7IG1hcmdpbjogMDsgcGFkZGluZzogMDsgfQogICAgICAgIGh0bWws
IGJvZHkgewogICAgICAgICAgICB3aWR0aDogMTAwJTsgaGVpZ2h0OiAxMDAlOyBvdmVyZmxvdzog
aGlkZGVuOwogICAgICAgICAgICBiYWNrZ3JvdW5kOiB2YXIoLS1iZyk7IGNvbG9yOiB2YXIoLS10
eHQpOwogICAgICAgICAgICBmb250OiAxMnB4LzEuNDUgJ1NlZ29lIFVJJywnTWljcm9zb2Z0IFlh
SGVpIFVJJyxzeXN0ZW0tdWksc2Fucy1zZXJpZjsKICAgICAgICAgICAgdXNlci1zZWxlY3Q6IG5v
bmU7CiAgICAgICAgICAgIHpvb206IDE7CiAgICAgICAgICAgIHRvdWNoLWFjdGlvbjogcGFuLXgg
cGFuLXk7CiAgICAgICAgfQogICAgICAgIDo6LXdlYmtpdC1zY3JvbGxiYXIgeyB3aWR0aDogNXB4
OyB9CiAgICAgICAgOjotd2Via2l0LXNjcm9sbGJhci10aHVtYiB7IGJhY2tncm91bmQ6ICNjNWM5
ZDQ7IGJvcmRlci1yYWRpdXM6IDNweDsgfQogICAgICAgIDo6LXdlYmtpdC1zY3JvbGxiYXItdGh1
bWI6aG92ZXIgeyBiYWNrZ3JvdW5kOiAjYWViM2MwOyB9CiAgICAgICAgOjotd2Via2l0LXNjcm9s
bGJhci10cmFjayB7IGJhY2tncm91bmQ6IHRyYW5zcGFyZW50OyB9CgogICAgICAgICNhcHAgewog
ICAgICAgICAgICBoZWlnaHQ6IDEwMCU7IGRpc3BsYXk6IGZsZXg7IGZsZXgtZGlyZWN0aW9uOiBj
b2x1bW47CiAgICAgICAgICAgIGJhY2tncm91bmQ6IGxpbmVhci1ncmFkaWVudCgxODBkZWcsICNm
N2Y5ZmMgMCUsICNlZWYxZjYgMTAwJSk7CiAgICAgICAgICAgIC13ZWJraXQtYXBwLXJlZ2lvbjog
ZHJhZzsgYXBwLXJlZ2lvbjogZHJhZzsKICAgICAgICAgICAgcG9zaXRpb246IHJlbGF0aXZlOwog
ICAgICAgICAgICBvdmVyZmxvdzogaGlkZGVuOwogICAgICAgIH0KCiAgICAgICAgLyog4pSA4pSA
IFJvdyAxIOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKU
gOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKU
gOKUgOKUgOKUgCAqLwogICAgICAgICNoZHIgewogICAgICAgICAgICBkaXNwbGF5OiBmbGV4OyBh
bGlnbi1pdGVtczogY2VudGVyOyBmbGV4LXNocmluazogMDsKICAgICAgICAgICAgcGFkZGluZzog
NXB4IDRweCA1cHggNnB4OyBnYXA6IDRweDsKICAgICAgICAgICAgYmFja2dyb3VuZDogI2YyZjRm
OTsKICAgICAgICB9CiAgICAgICAgI2hlYXJ0IHsgZmxleC1zaHJpbms6IDA7IGxpbmUtaGVpZ2h0
OiAxOyBkaXNwbGF5OmZsZXg7IGFsaWduLWl0ZW1zOmNlbnRlcjsgfQogICAgICAgICNoZWFydCBz
dmcgeyB3aWR0aDoxN3B4OyBoZWlnaHQ6MTdweDsgY29sb3I6IHZhcigtLXR4dDIpOyB9CiAgICAg
ICAgI2hkci1ncm93IHsgZmxleDogMTsgbWluLXdpZHRoOiA4cHg7IH0KCiAgICAgICAgLyogU2Vh
cmNoOiBvdmVybGF5IGV4cGFuZCAodHJhbnNmb3JtL29wYWNpdHkgb25seSDigJQgbm8gd2lkdGgg
bGF5b3V0IHRocmFzaCkgKi8KICAgICAgICAjc2VhcmNoLXdyYXAgewogICAgICAgICAgICBmbGV4
OiAwIDAgMjhweDsKICAgICAgICAgICAgd2lkdGg6IDI4cHg7CiAgICAgICAgICAgIGhlaWdodDog
MjhweDsKICAgICAgICAgICAgcG9zaXRpb246IHJlbGF0aXZlOwogICAgICAgICAgICB6LWluZGV4
OiA2OwogICAgICAgICAgICAtd2Via2l0LWFwcC1yZWdpb246IG5vLWRyYWc7IGFwcC1yZWdpb246
IG5vLWRyYWc7CiAgICAgICAgfQogICAgICAgICNidG4tc2VhcmNoIHsKICAgICAgICAgICAgcG9z
aXRpb246IGFic29sdXRlOyByaWdodDogMDsgdG9wOiAwOwogICAgICAgICAgICB3aWR0aDogMjhw
eDsgaGVpZ2h0OiAyOHB4OwogICAgICAgICAgICBkaXNwbGF5OiBmbGV4OyBhbGlnbi1pdGVtczog
Y2VudGVyOyBqdXN0aWZ5LWNvbnRlbnQ6IGNlbnRlcjsKICAgICAgICAgICAgYm9yZGVyOiBub25l
OyBiYWNrZ3JvdW5kOiBub25lOyBjdXJzb3I6IHBvaW50ZXI7CiAgICAgICAgICAgIGNvbG9yOiB2
YXIoLS10eHQzKTsgYm9yZGVyLXJhZGl1czogdmFyKC0tcik7CiAgICAgICAgICAgIHotaW5kZXg6
IDI7CiAgICAgICAgICAgIHRyYW5zaXRpb246IGNvbG9yIDAuMTVzIGVhc2UsIGJhY2tncm91bmQg
MC4xNXMgZWFzZSwgb3BhY2l0eSAwLjE1cyBlYXNlOwogICAgICAgIH0KICAgICAgICAjYnRuLXNl
YXJjaDpob3ZlciB7IGNvbG9yOiB2YXIoLS1hY2MpOyBiYWNrZ3JvdW5kOiByZ2JhKDkxLDExNSwy
MzIsLjEpOyB9CiAgICAgICAgI2J0bi1zZWFyY2ggc3ZnIHsgd2lkdGg6IDE1cHg7IGhlaWdodDog
MTVweDsgZGlzcGxheTogYmxvY2s7IH0KICAgICAgICAjc2VhcmNoLXdyYXAub3BlbiAjYnRuLXNl
YXJjaCB7CiAgICAgICAgICAgIG9wYWNpdHk6IDA7CiAgICAgICAgICAgIHBvaW50ZXItZXZlbnRz
OiBub25lOwogICAgICAgIH0KCiAgICAgICAgI3NlYXJjaC1ib3ggewogICAgICAgICAgICB0cmFu
c2Zvcm0tb3JpZ2luOiByaWdodCBjZW50ZXI7CiAgICAgICAgICAgIHBvc2l0aW9uOiBhYnNvbHV0
ZTsKICAgICAgICAgICAgcmlnaHQ6IDA7CiAgICAgICAgICAgIHRvcDogMDsKICAgICAgICAgICAg
d2lkdGg6IDE5NnB4OwogICAgICAgICAgICBoZWlnaHQ6IDI4cHg7CiAgICAgICAgICAgIGJveC1z
aXppbmc6IGJvcmRlci1ib3g7CiAgICAgICAgICAgIHBhZGRpbmc6IDAgMnB4IDAgMnB4OwogICAg
ICAgICAgICBiYWNrZ3JvdW5kOiB0cmFuc3BhcmVudDsKICAgICAgICAgICAgYm9yZGVyOiBub25l
OwogICAgICAgICAgICBib3JkZXItcmFkaXVzOiAwOwogICAgICAgICAgICBvcGFjaXR5OiAwOwog
ICAgICAgICAgICB0cmFuc2Zvcm06IHRyYW5zbGF0ZTNkKDhweCwgMCwgMCkgc2NhbGUoMC45ODUp
OwogICAgICAgICAgICBwb2ludGVyLWV2ZW50czogbm9uZTsKICAgICAgICAgICAgZGlzcGxheTog
ZmxleDsKICAgICAgICAgICAgYWxpZ24taXRlbXM6IGNlbnRlcjsKICAgICAgICAgICAgZ2FwOiA0
cHg7CiAgICAgICAgICAgIHdpbGwtY2hhbmdlOiB0cmFuc2Zvcm0sIG9wYWNpdHk7CiAgICAgICAg
ICAgIGJhY2tmYWNlLXZpc2liaWxpdHk6IGhpZGRlbjsKICAgICAgICAgICAgdHJhbnNpdGlvbjog
b3BhY2l0eSAwLjE4cyBlYXNlLCB0cmFuc2Zvcm0gMC4yNHMgY3ViaWMtYmV6aWVyKDAuMTYsIDEs
IDAuMywgMSk7CiAgICAgICAgfQogICAgICAgICNzZWFyY2gtd3JhcC5vcGVuICNzZWFyY2gtYm94
IHsKICAgICAgICAgICAgdHJhbnNmb3JtLW9yaWdpbjogcmlnaHQgY2VudGVyOwogICAgICAgICAg
ICB0cmFuc2Zvcm0tb3JpZ2luOiByaWdodCBjZW50ZXI7CiAgICAgICAgICAgIG9wYWNpdHk6IDE7
CiAgICAgICAgICAgIHRyYW5zZm9ybTogdHJhbnNsYXRlM2QoMCwgMCwgMCk7CiAgICAgICAgICAg
IHBvaW50ZXItZXZlbnRzOiBhdXRvOwogICAgICAgIH0KCiAgICAgICAgI3NlYXJjaCB7CiAgICAg
ICAgICAgIGZsZXg6IDE7IG1pbi13aWR0aDogMDsgaGVpZ2h0OiAyOHB4OyBib3JkZXI6IG5vbmU7
CiAgICAgICAgICAgIGJvcmRlci1ib3R0b206IDFweCBzb2xpZCB0cmFuc3BhcmVudDsKICAgICAg
ICAgICAgYm9yZGVyLXJhZGl1czogMDsgYmFja2dyb3VuZDogdHJhbnNwYXJlbnQ7IGNvbG9yOiB2
YXIoLS10eHQpOyBmb250LXNpemU6IDEycHg7CiAgICAgICAgICAgIHBhZGRpbmc6IDAgMjJweCAw
IDJweDsgb3V0bGluZTogbm9uZTsKICAgICAgICAgICAgdHJhbnNpdGlvbjogYm9yZGVyLWJvdHRv
bS1jb2xvciAwLjE4cyBlYXNlOwogICAgICAgIH0KICAgICAgICAjc2VhcmNoLXdyYXAub3BlbiAj
c2VhcmNoIHsKICAgICAgICAgICAgYm9yZGVyLWJvdHRvbS1jb2xvcjogI2M1Y2FkNjsKICAgICAg
ICB9CiAgICAgICAgI3NlYXJjaC13cmFwLm9wZW4gI3NlYXJjaDpmb2N1cyB7CiAgICAgICAgICAg
IGJvcmRlci1ib3R0b20tY29sb3I6IHZhcigtLWFjYyk7CiAgICAgICAgfQogICAgICAgIG1hcmsu
cS1obCB7CiAgICAgICAgICAgIGJhY2tncm91bmQ6IHJnYmEoMjU1LCAxOTYsIDAsIC40Mik7CiAg
ICAgICAgICAgIGNvbG9yOiBpbmhlcml0OwogICAgICAgICAgICBib3JkZXItcmFkaXVzOiAycHg7
CiAgICAgICAgICAgIHBhZGRpbmc6IDAgMXB4OwogICAgICAgICAgICBkaXNwbGF5OiBpbmxpbmU7
CiAgICAgICAgICAgIGJveC1kZWNvcmF0aW9uLWJyZWFrOiBjbG9uZTsKICAgICAgICAgICAgLXdl
YmtpdC1ib3gtZGVjb3JhdGlvbi1icmVhazogY2xvbmU7CiAgICAgICAgfQogICAgICAgIC8qIG1h
cmsgYnJlYWtzIC13ZWJraXQtbGluZS1jbGFtcDsga2VlcCBmb2xkIHZpYSBtYXgtaGVpZ2h0IHdo
aWxlIHNlYXJjaGluZyAqLwogICAgICAgIC5pLXByZXYuaGFzLWhsLCAuaS1uYW1lLmhhcy1obCwg
Lm1nLWJvZHkuaGFzLWhsLAogICAgICAgIC5pLWxpbmstdGl0bGUuaGFzLWhsLCAuaS1saW5rLXVy
bC5oYXMtaGwsIC5pLWZhdi10aXRsZS5oYXMtaGwgewogICAgICAgICAgICBkaXNwbGF5OiBibG9j
azsKICAgICAgICAgICAgLXdlYmtpdC1saW5lLWNsYW1wOiB1bnNldDsKICAgICAgICAgICAgb3Zl
cmZsb3c6IGhpZGRlbjsKICAgICAgICB9CiAgICAgICAgLmktcHJldi5oYXMtaGwsIC5tZy1ib2R5
Lmhhcy1obCB7IG1heC1oZWlnaHQ6IGNhbGMoMS40NWVtICogNSk7IH0KICAgICAgICAuaS1uYW1l
Lmhhcy1obCB7IG1heC1oZWlnaHQ6IGNhbGMoMS40NWVtICogMik7IH0KICAgICAgICAuaS1saW5r
LXVybC5oYXMtaGwgeyBtYXgtaGVpZ2h0OiBjYWxjKDEuNDVlbSAqIDMpOyB9CiAgICAgICAgLmkt
cHJldi5oYXMtaGwuZXhwYW5kZWQsIC5pLW5hbWUuaGFzLWhsLmV4cGFuZGVkLAogICAgICAgIC5t
Zy1ib2R5Lmhhcy1obC5leHBhbmRlZCwgLmktbGluay11cmwuaGFzLWhsLmV4cGFuZGVkIHsKICAg
ICAgICAgICAgLyog5bGV5byA6auY5bqm55SxIEpTIOaOp+WItu+8m+S7jeijgeWIh+W5tuWcqOac
q+WwvuWKoOOAjCAuLi7jgI0gKi8KICAgICAgICAgICAgb3ZlcmZsb3c6IGhpZGRlbjsKICAgICAg
ICB9CiAgICAgICAgLmktZXhwYW5kLWJ0biwgLmktbWV0YSB7IHVzZXItc2VsZWN0OiBub25lOyB9
CiAgICAgICAgI3NlYXJjaDo6cGxhY2Vob2xkZXIgeyBjb2xvcjogdmFyKC0tdHh0Myk7IH0KICAg
ICAgICAjc2VhcmNoLWNsciB7CiAgICAgICAgICAgIHBvc2l0aW9uOiBhYnNvbHV0ZTsgcmlnaHQ6
IDRweDsgdG9wOiA1MCU7IHRyYW5zZm9ybTogdHJhbnNsYXRlWSgtNTAlKTsKICAgICAgICAgICAg
Ym9yZGVyOiBub25lOyBiYWNrZ3JvdW5kOiBub25lOyBjb2xvcjogdmFyKC0tdHh0Myk7IGN1cnNv
cjogcG9pbnRlcjsKICAgICAgICAgICAgZm9udC1zaXplOiAxMXB4OyBkaXNwbGF5OiBub25lOyBw
YWRkaW5nOiAycHg7CiAgICAgICAgICAgIG9wYWNpdHk6IDAuODU7CiAgICAgICAgICAgIHRyYW5z
aXRpb246IGNvbG9yIDAuMTJzIGVhc2UsIG9wYWNpdHkgMC4xMnMgZWFzZTsKICAgICAgICAgICAg
LXdlYmtpdC1hcHAtcmVnaW9uOiBuby1kcmFnOyBhcHAtcmVnaW9uOiBuby1kcmFnOwogICAgICAg
IH0KICAgICAgICAjc2VhcmNoLWNscjpob3ZlciB7IGNvbG9yOiB2YXIoLS1hY2MpOyBvcGFjaXR5
OiAxOyB9CgogICAgICAgICNidG4tdG9kYXkgewogICAgICAgICAgICBkaXNwbGF5OiBub25lOwog
ICAgICAgICAgICBoZWlnaHQ6IDE4cHg7IHBhZGRpbmc6IDAgN3B4OyBmbGV4LXNocmluazogMDsK
ICAgICAgICAgICAgYWxpZ24taXRlbXM6IGNlbnRlcjsganVzdGlmeS1jb250ZW50OiBjZW50ZXI7
CiAgICAgICAgICAgIGJvcmRlcjogMXB4IHNvbGlkIHJnYmEoOTEsMTE1LDIzMiwuMjIpOyBiYWNr
Z3JvdW5kOiByZ2JhKDkxLDExNSwyMzIsLjEwKTsKICAgICAgICAgICAgY29sb3I6ICM2YjgyZTg7
IGJvcmRlci1yYWRpdXM6IDk5OXB4OyBmb250LXNpemU6IDlweDsgZm9udC13ZWlnaHQ6IDYwMDsK
ICAgICAgICAgICAgbGluZS1oZWlnaHQ6IDE7IHdoaXRlLXNwYWNlOiBub3dyYXA7IGN1cnNvcjog
cG9pbnRlcjsKICAgICAgICAgICAgLXdlYmtpdC1hcHAtcmVnaW9uOiBuby1kcmFnOyBhcHAtcmVn
aW9uOiBuby1kcmFnOwogICAgICAgICAgICB0cmFuc2l0aW9uOiBjb2xvciB2YXIoLS10ciksIGJh
Y2tncm91bmQgdmFyKC0tdHIpLCBib3JkZXItY29sb3IgdmFyKC0tdHIpLCBvcGFjaXR5IHZhcigt
LXRyKTsKICAgICAgICB9CiAgICAgICAgI3NlYXJjaC13cmFwLm9wZW4gI2J0bi10b2RheSB7IGRp
c3BsYXk6IGlubGluZS1mbGV4OyB9CiAgICAgICAgI2J0bi10b2RheTpob3ZlciB7IGNvbG9yOiAj
NGE2MmQ0OyBiYWNrZ3JvdW5kOiByZ2JhKDkxLDExNSwyMzIsLjE2KTsgfQogICAgICAgICNidG4t
dG9kYXkub24gewogICAgICAgICAgICBjb2xvcjogIzViNzNlODsKICAgICAgICAgICAgYmFja2dy
b3VuZDogcmdiYSg5MSwxMTUsMjMyLC4xNik7CiAgICAgICAgICAgIGJvcmRlci1jb2xvcjogcmdi
YSg5MSwxMTUsMjMyLC4zMik7CiAgICAgICAgfQogICAgICAgICNidG4tdG9kYXk6bm90KC5vbikg
ewogICAgICAgICAgICBjb2xvcjogdmFyKC0tdHh0Myk7CiAgICAgICAgICAgIGJhY2tncm91bmQ6
IHJnYmEoMCwwLDAsLjA0KTsKICAgICAgICAgICAgYm9yZGVyLWNvbG9yOiByZ2JhKDAsMCwwLC4w
Nik7CiAgICAgICAgfQoKICAgICAgICAjYnRuLXBpbiB7CiAgICAgICAgICAgIGRpc3BsYXk6IGZs
ZXg7CiAgICAgICAgICAgIHdpZHRoOiAyOHB4OyBoZWlnaHQ6IDI4cHg7IGZsZXgtc2hyaW5rOiAw
OwogICAgICAgICAgICBhbGlnbi1pdGVtczogY2VudGVyOyBqdXN0aWZ5LWNvbnRlbnQ6IGNlbnRl
cjsKICAgICAgICAgICAgYm9yZGVyOiAxLjVweCBzb2xpZCB0cmFuc3BhcmVudDsgYmFja2dyb3Vu
ZDogbm9uZTsgY3Vyc29yOiBwb2ludGVyOwogICAgICAgICAgICBjb2xvcjogdmFyKC0tdHh0Myk7
IGJvcmRlci1yYWRpdXM6IHZhcigtLXIpOwogICAgICAgICAgICAtd2Via2l0LWFwcC1yZWdpb246
IG5vLWRyYWc7IGFwcC1yZWdpb246IG5vLWRyYWc7CiAgICAgICAgICAgIHRyYW5zaXRpb246IGNv
bG9yIHZhcigtLXRyKSwgYmFja2dyb3VuZCB2YXIoLS10ciksIGJvcmRlci1jb2xvciB2YXIoLS10
cik7CiAgICAgICAgfQogICAgICAgICNidG4tcGluOmhvdmVyIHsgY29sb3I6IHZhcigtLWFjYyk7
IGJhY2tncm91bmQ6IHJnYmEoOTEsMTE1LDIzMiwuMSk7IH0KICAgICAgICAjYnRuLXBpbi5vbiAg
ewogICAgICAgICAgICBjb2xvcjogdmFyKC0tYWNjKTsKICAgICAgICAgICAgYmFja2dyb3VuZDog
cmdiYSg5MSwxMTUsMjMyLC4xOCk7CiAgICAgICAgICAgIGJvcmRlci1jb2xvcjogcmdiYSg5MSwx
MTUsMjMyLC41NSk7CiAgICAgICAgfQogICAgICAgICNidG4tcGluIHN2ZyB7IHdpZHRoOiAxNHB4
OyBoZWlnaHQ6IDE0cHg7IGRpc3BsYXk6IGJsb2NrOyB9CgogICAgICAgICNidG4tbG9jYXRlIHsK
ICAgICAgICAgICAgd2lkdGg6IDI4cHg7IGhlaWdodDogMjhweDsgZmxleC1zaHJpbms6IDA7CiAg
ICAgICAgICAgIGRpc3BsYXk6IGZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGp1c3RpZnktY29u
dGVudDogY2VudGVyOwogICAgICAgICAgICBib3JkZXI6IG5vbmU7IGJhY2tncm91bmQ6IG5vbmU7
IGN1cnNvcjogcG9pbnRlcjsKICAgICAgICAgICAgY29sb3I6IHZhcigtLXR4dDMpOyBib3JkZXIt
cmFkaXVzOiB2YXIoLS1yKTsKICAgICAgICAgICAgLXdlYmtpdC1hcHAtcmVnaW9uOiBuby1kcmFn
OyBhcHAtcmVnaW9uOiBuby1kcmFnOwogICAgICAgICAgICB0cmFuc2l0aW9uOiBjb2xvciB2YXIo
LS10ciksIGJhY2tncm91bmQgdmFyKC0tdHIpLCBvcGFjaXR5IHZhcigtLXRyKTsKICAgICAgICB9
CiAgICAgICAgI2J0bi1sb2NhdGU6aG92ZXI6bm90KDpkaXNhYmxlZCkgeyBjb2xvcjogdmFyKC0t
YWNjKTsgYmFja2dyb3VuZDogcmdiYSg5MSwxMTUsMjMyLC4xKTsgfQogICAgICAgICNidG4tbG9j
YXRlOmRpc2FibGVkIHsgb3BhY2l0eTogLjM1OyBjdXJzb3I6IGRlZmF1bHQ7IH0KICAgICAgICAj
YnRuLWxvY2F0ZS5oYXMtdGFyZ2V0IHsgY29sb3I6IHZhcigtLWFjYyk7IH0KICAgICAgICAjYnRu
LWxvY2F0ZS5vbiB7CiAgICAgICAgICAgIGNvbG9yOiB2YXIoLS1hY2MpOwogICAgICAgICAgICBi
YWNrZ3JvdW5kOiByZ2JhKDkxLDExNSwyMzIsLjE4KTsKICAgICAgICB9CiAgICAgICAgI2J0bi1s
b2NhdGUgc3ZnIHsgd2lkdGg6IDE1cHg7IGhlaWdodDogMTVweDsgZGlzcGxheTogYmxvY2s7IH0K
ICAgICAgICAjaGRyOmhhcygjc2VhcmNoLXdyYXAub3BlbikgI2J0bi1sb2NhdGUgewogICAgICAg
ICAgICBkaXNwbGF5OiBub25lOwogICAgICAgIH0KCiAgICAgICAgLyog4pSA4pSAIFJvdyAyIOKU
gOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKU
gOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKU
gCAqLwogICAgICAgICN0YWJzIHsKICAgICAgICAgICAgcG9zaXRpb246IHJlbGF0aXZlOwogICAg
ICAgICAgICBkaXNwbGF5OiBmbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBnYXA6IDJweDsgZmxl
eC13cmFwOiBub3dyYXA7CiAgICAgICAgICAgIHBhZGRpbmc6IDVweCA0cHggNXB4IDZweDsgZmxl
eC1zaHJpbms6IDA7CiAgICAgICAgICAgIGJhY2tncm91bmQ6ICNmMmY0Zjk7CiAgICAgICAgICAg
IG1pbi13aWR0aDogMDsKICAgICAgICB9CiAgICAgICAgI3RhYi1pbmsgewogICAgICAgICAgICBw
b3NpdGlvbjogYWJzb2x1dGU7CiAgICAgICAgICAgIGxlZnQ6IDA7IHRvcDogMDsKICAgICAgICAg
ICAgaGVpZ2h0OiAyMnB4OwogICAgICAgICAgICBib3JkZXItcmFkaXVzOiA5OTlweDsKICAgICAg
ICAgICAgYmFja2dyb3VuZDogI2ZmZjsKICAgICAgICAgICAgYm94LXNoYWRvdzogMCAxcHggM3B4
IHJnYmEoMCwwLDAsLjA3KSwgMCAwIDAgMXB4IHJnYmEoOTEsMTE1LDIzMiwuMDYpOwogICAgICAg
ICAgICBwb2ludGVyLWV2ZW50czogbm9uZTsKICAgICAgICAgICAgei1pbmRleDogMDsKICAgICAg
ICAgICAgdHJhbnNmb3JtOiB0cmFuc2xhdGUzZCgwLDAsMCkgc2NhbGVYKDEpOwogICAgICAgICAg
ICB0cmFuc2Zvcm0tb3JpZ2luOiBjZW50ZXIgYm90dG9tOwogICAgICAgICAgICB0cmFuc2l0aW9u
OgogICAgICAgICAgICAgICAgdHJhbnNmb3JtIDAuMzRzIGN1YmljLWJlemllcigwLjIyLCAxLjE4
LCAwLjMyLCAxKSwKICAgICAgICAgICAgICAgIGhlaWdodCAwLjI0cyBlYXNlOwogICAgICAgICAg
ICB3aWxsLWNoYW5nZTogdHJhbnNmb3JtLCBoZWlnaHQ7CiAgICAgICAgfQogICAgICAgICN0YWIt
aW5rLnNxdWFzaCB7CiAgICAgICAgICAgIHRyYW5zaXRpb246CiAgICAgICAgICAgICAgICB0cmFu
c2Zvcm0gMC4zMHMgY3ViaWMtYmV6aWVyKDAuMzQsIDEuMjgsIDAuNDQsIDEpLAogICAgICAgICAg
ICAgICAgaGVpZ2h0IDAuMjBzIGVhc2U7CiAgICAgICAgfQogICAgICAgIC50YWIgewogICAgICAg
ICAgICBwb3NpdGlvbjogcmVsYXRpdmU7CiAgICAgICAgICAgIHotaW5kZXg6IDE7CiAgICAgICAg
ICAgIHBhZGRpbmc6IDNweCA5cHg7IGZvbnQtc2l6ZTogMTFweDsgY29sb3I6IHZhcigtLXR4dDIp
OyBjdXJzb3I6IHBvaW50ZXI7CiAgICAgICAgICAgIGJvcmRlci1yYWRpdXM6IDk5OXB4OyB3aGl0
ZS1zcGFjZTogbm93cmFwOwogICAgICAgICAgICBiYWNrZ3JvdW5kOiB0cmFuc3BhcmVudDsKICAg
ICAgICAgICAgZmxleDogMCAwIGF1dG87CiAgICAgICAgICAgIHRyYW5zaXRpb246IGNvbG9yIDAu
MjhzIGN1YmljLWJlemllcigwLjIyLCAxLCAwLjM2LCAxKSwKICAgICAgICAgICAgICAgICAgICAg
ICAgdHJhbnNmb3JtIDAuMjhzIGN1YmljLWJlemllcigwLjIyLCAxLCAwLjM2LCAxKTsKICAgICAg
ICAgICAgLXdlYmtpdC1hcHAtcmVnaW9uOiBuby1kcmFnOyBhcHAtcmVnaW9uOiBuby1kcmFnOwog
ICAgICAgIH0KICAgICAgICAudGFiOmhvdmVyIHsgY29sb3I6IHZhcigtLXR4dCk7IGJhY2tncm91
bmQ6IHRyYW5zcGFyZW50OyB9CiAgICAgICAgLnRhYjphY3RpdmUgeyB0cmFuc2Zvcm06IHNjYWxl
KDAuOTYpOyB9CiAgICAgICAgLnRhYi5vbiB7IGNvbG9yOiB2YXIoLS1hY2MpOyBiYWNrZ3JvdW5k
OiB0cmFuc3BhcmVudDsgYm94LXNoYWRvdzogbm9uZTsgZm9udC13ZWlnaHQ6IDYwMDsgfQogICAg
ICAgIC5iYWRnZSB7CiAgICAgICAgICAgIGRpc3BsYXk6IGlubGluZS1mbGV4OyBtaW4td2lkdGg6
IDEzcHg7IGhlaWdodDogMTNweDsgcGFkZGluZzogMCAycHg7CiAgICAgICAgICAgIGFsaWduLWl0
ZW1zOiBjZW50ZXI7IGp1c3RpZnktY29udGVudDogY2VudGVyOwogICAgICAgICAgICBiYWNrZ3Jv
dW5kOiB2YXIoLS1hY2MpOyBjb2xvcjogI2ZmZjsgZm9udC1zaXplOiA5cHg7IGJvcmRlci1yYWRp
dXM6IDdweDsgZm9udC13ZWlnaHQ6IDcwMDsKICAgICAgICAgICAgbWFyZ2luLWxlZnQ6IDFweDsK
ICAgICAgICB9CiAgICAgICAgI3Bpbi1kb3QgewogICAgICAgICAgICBkaXNwbGF5OiBub25lOwog
ICAgICAgICAgICB3aWR0aDogN3B4OyBoZWlnaHQ6IDdweDsKICAgICAgICAgICAgbWFyZ2luLWxl
ZnQ6IDRweDsKICAgICAgICAgICAgYm9yZGVyLXJhZGl1czogNTAlOwogICAgICAgICAgICBiYWNr
Z3JvdW5kOiAjMjJjNTVlOwogICAgICAgICAgICBib3gtc2hhZG93OiAwIDAgMCAycHggcmdiYSgz
NCwxOTcsOTQsLjE4KTsKICAgICAgICAgICAgZmxleC1zaHJpbms6IDA7CiAgICAgICAgICAgIHZl
cnRpY2FsLWFsaWduOiBtaWRkbGU7CiAgICAgICAgfQogICAgICAgICNwaW4tZG90Lm9uIHsgZGlz
cGxheTogaW5saW5lLWJsb2NrOyB9CiAgICAgICAgI3RhYi1hY3Rpb25zIHsKICAgICAgICAgICAg
bWFyZ2luLWxlZnQ6IGF1dG87IGRpc3BsYXk6IGZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGdh
cDogM3B4OwogICAgICAgICAgICBjb2xvcjogdmFyKC0tdHh0Myk7IGZvbnQtc2l6ZTogMTBweDsK
ICAgICAgICAgICAgZmxleDogMCAwIGF1dG87CiAgICAgICAgICAgIG1pbi13aWR0aDogMDsKICAg
ICAgICAgICAgLXdlYmtpdC1hcHAtcmVnaW9uOiBuby1kcmFnOyBhcHAtcmVnaW9uOiBuby1kcmFn
OwogICAgICAgIH0KICAgICAgICAjYmFyLXR4dCB7IHdoaXRlLXNwYWNlOiBub3dyYXA7IGZvbnQt
c2l6ZTogMTBweDsgbWF4LXdpZHRoOiA4LjVlbTsgb3ZlcmZsb3c6IGhpZGRlbjsgdGV4dC1vdmVy
ZmxvdzogZWxsaXBzaXM7IH0KICAgICAgICAjYnRuLWNsciB7CiAgICAgICAgICAgIGRpc3BsYXk6
IGZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGp1c3RpZnktY29udGVudDogY2VudGVyOwogICAg
ICAgICAgICB3aWR0aDogMjZweDsgaGVpZ2h0OiAyNnB4OyBib3JkZXI6IG5vbmU7IGJhY2tncm91
bmQ6IG5vbmU7IGNvbG9yOiB2YXIoLS10eHQzKTsKICAgICAgICAgICAgY3Vyc29yOiBwb2ludGVy
OyBib3JkZXItcmFkaXVzOiB2YXIoLS1yKTsKICAgICAgICAgICAgLXdlYmtpdC1hcHAtcmVnaW9u
OiBuby1kcmFnOyBhcHAtcmVnaW9uOiBuby1kcmFnOwogICAgICAgICAgICB0cmFuc2l0aW9uOiBj
b2xvciB2YXIoLS10ciksIGJhY2tncm91bmQgdmFyKC0tdHIpOwogICAgICAgIH0KICAgICAgICAj
YnRuLWNscjpob3ZlciB7IGNvbG9yOiAjZmY3YjljOyBiYWNrZ3JvdW5kOiByZ2JhKDI1NSwxMjMs
MTU2LC4wOCk7IH0KICAgICAgICAjYnRuLWNsciBzdmcgeyB3aWR0aDogMTRweDsgaGVpZ2h0OiAx
NHB4OyBkaXNwbGF5OiBibG9jazsgfQoKICAgICAgICAvKiDilIDilIAgTGlzdCDilIDilIDilIDi
lIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDi
lIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIAgKi8K
ICAgICAgICAjbGlzdCB7CiAgICAgICAgICAgIGZsZXg6IDE7IG92ZXJmbG93LXk6IGF1dG87IG92
ZXJmbG93LXg6IGhpZGRlbjsKICAgICAgICAgICAgLyog5bemIDEwIC8g5Y+zIDXvvJrlj7Pkvqfm
u5rliqjmnaHnuqbljaAgNXB477yM6KeG6KeJ5bem5Y+z5a+56b2QICovCiAgICAgICAgICAgIHBh
ZGRpbmc6IDRweCA1cHggNHB4IDEwcHg7CiAgICAgICAgICAgIGN1cnNvcjogZGVmYXVsdDsKICAg
ICAgICAgICAgLyogTVVTVCBiZSBuby1kcmFnOiBkcmFnIHJlZ2lvbiBvbiB0aGUgc2Nyb2xsZXIg
bWFrZXMgV2ViVmlldzIgc2Nyb2xsYmFyL3doZWVsIGhpdGNoICovCiAgICAgICAgICAgIC13ZWJr
aXQtYXBwLXJlZ2lvbjogbm8tZHJhZzsgYXBwLXJlZ2lvbjogbm8tZHJhZzsKICAgICAgICAgICAg
bWluLWhlaWdodDogMDsKICAgICAgICAgICAgb3ZlcmZsb3ctYW5jaG9yOiBub25lOwogICAgICAg
IH0KICAgICAgICAvKiBXaGlsZSBzY3JvbGxpbmc6IGtpbGwgaG92ZXIgYW5pbWF0aW9ucyB0aGF0
IGNhdXNlIGxheW91dC9wYWludCB0aHJhc2ggKi8KICAgICAgICAjbGlzdC5pcy1zY3JvbGxpbmcg
Lml0bSB7CiAgICAgICAgICAgIHRyYW5zaXRpb246IG5vbmUgIWltcG9ydGFudDsKICAgICAgICB9
CiAgICAgICAgI2xpc3QuaXMtc2Nyb2xsaW5nIC5pdG06OmJlZm9yZSwKICAgICAgICAjbGlzdC5p
cy1zY3JvbGxpbmcgLml0bTo6YWZ0ZXIgewogICAgICAgICAgICB0cmFuc2l0aW9uOiBub25lICFp
bXBvcnRhbnQ7CiAgICAgICAgfQogICAgICAgIEBrZXlmcmFtZXMgdGFiUGFuZUluTHIgewogICAg
ICAgICAgICBmcm9tIHsgb3BhY2l0eTogMDsgdHJhbnNmb3JtOiB0cmFuc2xhdGVYKC00MHB4KTsg
fQogICAgICAgICAgICB0byB7IG9wYWNpdHk6IDE7IHRyYW5zZm9ybTogdHJhbnNsYXRlWCgwKTsg
fQogICAgICAgIH0KICAgICAgICBAa2V5ZnJhbWVzIHRhYlBhbmVJblJsIHsKICAgICAgICAgICAg
ZnJvbSB7IG9wYWNpdHk6IDA7IHRyYW5zZm9ybTogdHJhbnNsYXRlWCg0MHB4KTsgfQogICAgICAg
ICAgICB0byB7IG9wYWNpdHk6IDE7IHRyYW5zZm9ybTogdHJhbnNsYXRlWCgwKTsgfQogICAgICAg
IH0KICAgICAgICAjbGlzdC50YWItaW4tbHIgeyBhbmltYXRpb246IHRhYlBhbmVJbkxyIC4zNHMg
Y3ViaWMtYmV6aWVyKC4yMiwgMSwgLjM2LCAxKSBib3RoOyB9CiAgICAgICAgI2xpc3QudGFiLWlu
LXJsIHsgYW5pbWF0aW9uOiB0YWJQYW5lSW5SbCAuMzRzIGN1YmljLWJlemllciguMjIsIDEsIC4z
NiwgMSkgYm90aDsgfQogICAgICAgICNidG4tdG9wIHsKICAgICAgICAgICAgcG9zaXRpb246IGFi
c29sdXRlOyByaWdodDogMTBweDsgYm90dG9tOiAxMHB4OyB6LWluZGV4OiAyMDsKICAgICAgICAg
ICAgd2lkdGg6IDI4cHg7IGhlaWdodDogMjhweDsgYm9yZGVyOiBub25lOyBib3JkZXItcmFkaXVz
OiA1MCU7CiAgICAgICAgICAgIGRpc3BsYXk6IG5vbmU7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGp1
c3RpZnktY29udGVudDogY2VudGVyOwogICAgICAgICAgICBiYWNrZ3JvdW5kOiAjZmZmOyBjb2xv
cjogdmFyKC0tdHh0Mik7CiAgICAgICAgICAgIGJveC1zaGFkb3c6IDAgMnB4IDhweCByZ2JhKDI0
LDMyLDU2LC4xNik7CiAgICAgICAgICAgIGN1cnNvcjogcG9pbnRlcjsKICAgICAgICAgICAgLXdl
YmtpdC1hcHAtcmVnaW9uOiBuby1kcmFnOyBhcHAtcmVnaW9uOiBuby1kcmFnOwogICAgICAgICAg
ICB0cmFuc2l0aW9uOiBiYWNrZ3JvdW5kIHZhcigtLXRyKSwgY29sb3IgdmFyKC0tdHIpLCBib3gt
c2hhZG93IHZhcigtLXRyKTsKICAgICAgICB9CiAgICAgICAgI2J0bi10b3Aub24geyBkaXNwbGF5
OiBmbGV4OyB9CiAgICAgICAgI2J0bi10b3A6aG92ZXIgeyBjb2xvcjogdmFyKC0tYWNjKTsgYmFj
a2dyb3VuZDogI2VkZjFmZjsgYm94LXNoYWRvdzogMCAzcHggMTBweCByZ2JhKDkxLDExNSwyMzIs
LjI1KTsgfQogICAgICAgICNidG4tdG9wIHN2ZyB7IHdpZHRoOiAxNHB4OyBoZWlnaHQ6IDE0cHg7
IGRpc3BsYXk6IGJsb2NrOyB9CiAgICAgICAgI2VtcHR5IHsKICAgICAgICAgICAgZGlzcGxheTog
bm9uZTsgZmxleC1kaXJlY3Rpb246IGNvbHVtbjsgYWxpZ24taXRlbXM6IGNlbnRlcjsganVzdGlm
eS1jb250ZW50OiBjZW50ZXI7CiAgICAgICAgICAgIHBhZGRpbmc6IDQ4cHggMTZweDsgY29sb3I6
IHZhcigtLXR4dDMpOyBnYXA6IDhweDsKICAgICAgICAgICAgLXdlYmtpdC1hcHAtcmVnaW9uOiBk
cmFnOyBhcHAtcmVnaW9uOiBkcmFnOwogICAgICAgIH0KICAgICAgICAjZW1wdHkub24geyBkaXNw
bGF5OiBmbGV4OyB9CiAgICAgICAgLmUtdHh0IHsgZm9udC1zaXplOiAxMnB4OyB0ZXh0LWFsaWdu
OiBjZW50ZXI7IGxldHRlci1zcGFjaW5nOiAuMDJlbTsgfQogICAgICAgICNza2VsIHsKICAgICAg
ICAgICAgZGlzcGxheTogbm9uZSAhaW1wb3J0YW50OyAvKiDnp5LlvIDlkI7kuI3lho3lsZXnpLrp
qqjmnrbliqjnlLsgKi8KICAgICAgICB9CiAgICAgICAgI3NrZWwub24geyBkaXNwbGF5OiBub25l
ICFpbXBvcnRhbnQ7IH0KICAgICAgICAjYXBwLmJvb3QtbG9hZGluZyAjc2tlbCB7CiAgICAgICAg
ICAgIGRpc3BsYXk6IG5vbmUgIWltcG9ydGFudDsKICAgICAgICB9CiAgICAgICAgI2FwcC5ib290
LWxvYWRpbmcgI2VtcHR5IHsKICAgICAgICAgICAgZGlzcGxheTogbm9uZSAhaW1wb3J0YW50Owog
ICAgICAgIH0KICAgICAgICAuc2stcm93IHsKICAgICAgICAgICAgZGlzcGxheTogZmxleDsgYWxp
Z24taXRlbXM6IGZsZXgtc3RhcnQ7IGdhcDogMTBweDsKICAgICAgICAgICAgcGFkZGluZzogMTBw
eCA4cHg7IGJvcmRlci1yYWRpdXM6IDhweDsKICAgICAgICAgICAgYmFja2dyb3VuZDogcmdiYSgy
NTUsMjU1LDI1NSwuNzIpOwogICAgICAgICAgICBib3JkZXI6IDFweCBzb2xpZCByZ2JhKDE3MCwx
ODAsMjAwLC40NSk7CiAgICAgICAgICAgIHBvc2l0aW9uOiByZWxhdGl2ZTsKICAgICAgICAgICAg
b3ZlcmZsb3c6IGhpZGRlbjsKICAgICAgICB9CiAgICAgICAgLnNrLXJvdzo6YWZ0ZXIgewogICAg
ICAgICAgICBjb250ZW50OiAnJzsKICAgICAgICAgICAgcG9zaXRpb246IGFic29sdXRlOwogICAg
ICAgICAgICBpbnNldDogMDsKICAgICAgICAgICAgYmFja2dyb3VuZDogbGluZWFyLWdyYWRpZW50
KDkwZGVnLCB0cmFuc3BhcmVudCAwJSwgcmdiYSgyNTUsMjU1LDI1NSwuNzIpIDQ4JSwgdHJhbnNw
YXJlbnQgMTAwJSk7CiAgICAgICAgICAgIHRyYW5zZm9ybTogdHJhbnNsYXRlWCgtMTIwJSk7CiAg
ICAgICAgICAgIGFuaW1hdGlvbjogc2stc3dlZXAgMC45NXMgZWFzZS1pbi1vdXQgaW5maW5pdGU7
CiAgICAgICAgICAgIHBvaW50ZXItZXZlbnRzOiBub25lOwogICAgICAgIH0KICAgICAgICBAa2V5
ZnJhbWVzIHNrLXN3ZWVwIHsKICAgICAgICAgICAgMTAwJSB7IHRyYW5zZm9ybTogdHJhbnNsYXRl
WCgxMjAlKTsgfQogICAgICAgIH0KICAgICAgICAuc2staWNvLCAuc2stbGluZSB7CiAgICAgICAg
ICAgIGJhY2tncm91bmQ6IGxpbmVhci1ncmFkaWVudCg5MGRlZywgI2I4YzJkOCAwJSwgI2YwZjRm
YSAzOCUsICNkY2UzZjAgNTIlLCAjYjhjMmQ4IDEwMCUpOwogICAgICAgICAgICBiYWNrZ3JvdW5k
LXNpemU6IDI0MCUgMTAwJTsKICAgICAgICAgICAgYW5pbWF0aW9uOiBzay1zaGltbWVyIDAuNzJz
IGVhc2UtaW4tb3V0IGluZmluaXRlOwogICAgICAgICAgICB3aWxsLWNoYW5nZTogYmFja2dyb3Vu
ZC1wb3NpdGlvbjsKICAgICAgICAgICAgYm9yZGVyLXJhZGl1czogNnB4OwogICAgICAgIH0KICAg
ICAgICAuc2staWNvIHsgd2lkdGg6IDM0cHg7IGhlaWdodDogMzRweDsgZmxleC1zaHJpbms6IDA7
IGJvcmRlci1yYWRpdXM6IDhweDsgfQogICAgICAgIC5zay1ib2R5IHsgZmxleDogMTsgbWluLXdp
ZHRoOiAwOyBkaXNwbGF5OiBmbGV4OyBmbGV4LWRpcmVjdGlvbjogY29sdW1uOyBnYXA6IDhweDsg
cGFkZGluZy10b3A6IDJweDsgfQogICAgICAgIC5zay1saW5lIHsgaGVpZ2h0OiAxMHB4OyB3aWR0
aDogMTAwJTsgfQogICAgICAgIC5zay1saW5lLnNob3J0IHsgd2lkdGg6IDQyJTsgfQogICAgICAg
IC5zay1saW5lLm1pZCB7IHdpZHRoOiA2OCU7IH0KICAgICAgICAuc2stcm93Om50aC1jaGlsZCgy
KTo6YWZ0ZXIgeyBhbmltYXRpb24tZGVsYXk6IC4xMnM7IH0KICAgICAgICAuc2stcm93Om50aC1j
aGlsZCgzKTo6YWZ0ZXIgeyBhbmltYXRpb24tZGVsYXk6IC4yNHM7IH0KICAgICAgICAuc2stcm93
Om50aC1jaGlsZCg0KTo6YWZ0ZXIgeyBhbmltYXRpb24tZGVsYXk6IC4zNnM7IH0KICAgICAgICAu
c2stcm93Om50aC1jaGlsZCg1KTo6YWZ0ZXIgeyBhbmltYXRpb24tZGVsYXk6IC40OHM7IH0KICAg
ICAgICAuc2stcm93Om50aC1jaGlsZCg2KTo6YWZ0ZXIgeyBhbmltYXRpb24tZGVsYXk6IC42czsg
fQogICAgICAgIEBrZXlmcmFtZXMgc2stc2hpbW1lciB7CiAgICAgICAgICAgIDAlIHsgYmFja2dy
b3VuZC1wb3NpdGlvbjogMTAwJSAwOyB9CiAgICAgICAgICAgIDEwMCUgeyBiYWNrZ3JvdW5kLXBv
c2l0aW9uOiAtMTAwJSAwOyB9CiAgICAgICAgfQogICAgICAgIC5saXN0LW1vcmUgewogICAgICAg
ICAgICB0ZXh0LWFsaWduOiBjZW50ZXI7IHBhZGRpbmc6IDEwcHggOHB4IDE0cHg7IGZvbnQtc2l6
ZTogMTFweDsKICAgICAgICAgICAgY29sb3I6IHZhcigtLXR4dDMpOyAtd2Via2l0LWFwcC1yZWdp
b246IG5vLWRyYWc7IGFwcC1yZWdpb246IG5vLWRyYWc7CiAgICAgICAgfQogICAgICAgIC5saXN0
LW1vcmUuZG9uZSB7IGRpc3BsYXk6IG5vbmU7IH0KCiAgICAgICAgLml0bSB7CiAgICAgICAgICAg
IGRpc3BsYXk6IGZsZXg7IGFsaWduLWl0ZW1zOiBmbGV4LXN0YXJ0OyBnYXA6IDhweDsKICAgICAg
ICAgICAgcGFkZGluZzogOHB4OyBtYXJnaW4tYm90dG9tOiA1cHg7CiAgICAgICAgICAgIGJhY2tn
cm91bmQ6IHZhcigtLWNhcmQpOyBib3JkZXItcmFkaXVzOiA0cHg7IGN1cnNvcjogcG9pbnRlcjsK
ICAgICAgICAgICAgYm9yZGVyOiBub25lOwogICAgICAgICAgICBib3gtc2hhZG93OgogICAgICAg
ICAgICAgICAgMCAxcHggMnB4IHJnYmEoMjQsMzIsNTYsLjA1KSwKICAgICAgICAgICAgICAgIDAg
M3B4IDEwcHggcmdiYSgyNCwzMiw1NiwuMDgpOwogICAgICAgICAgICAvKiBob3Zlci1saW5lICov
CiAgICAgICAgICAgIHBvc2l0aW9uOiByZWxhdGl2ZTsKICAgICAgICAgICAgdHJhbnNpdGlvbjog
YmFja2dyb3VuZCAuMnMgZWFzZSwgYm94LXNoYWRvdyAuMnMgZWFzZSwgdHJhbnNmb3JtIC4ycyBl
YXNlOwogICAgICAgICAgICAtd2Via2l0LWFwcC1yZWdpb246IG5vLWRyYWc7IGFwcC1yZWdpb246
IG5vLWRyYWc7CiAgICAgICAgICAgIG92ZXJmbG93OiB2aXNpYmxlOwogICAgICAgIH0KICAgICAg
ICAuaXRtOjpiZWZvcmUgewogICAgICAgICAgICBjb250ZW50OiAiIjsKICAgICAgICAgICAgcG9z
aXRpb246IGFic29sdXRlOwogICAgICAgICAgICBsZWZ0OiAwOyByaWdodDogMDsgYm90dG9tOiAw
OwogICAgICAgICAgICBoZWlnaHQ6IDA7CiAgICAgICAgICAgIHBvaW50ZXItZXZlbnRzOiBub25l
OwogICAgICAgICAgICB6LWluZGV4OiAwOwogICAgICAgICAgICBib3JkZXItcmFkaXVzOiAwIDAg
dmFyKC0tcikgdmFyKC0tcik7CiAgICAgICAgICAgIGJhY2tncm91bmQ6IGxpbmVhci1ncmFkaWVu
dCh0byB0b3AsIHJnYmEoOTEsMTE1LDIzMiwuMzIpLCByZ2JhKDkxLDExNSwyMzIsLjEyKSA1NSUs
IHRyYW5zcGFyZW50KTsKICAgICAgICAgICAgdHJhbnNpdGlvbjogaGVpZ2h0IC4zNHMgY3ViaWMt
YmV6aWVyKC4yMiwxLC4zNiwxKTsKICAgICAgICB9CiAgICAgICAgLml0bTpob3Zlcjo6YmVmb3Jl
IHsgaGVpZ2h0OiAzMy4zMzMlOyB9CiAgICAgICAgLml0bTo6YWZ0ZXIgewogICAgICAgICAgICBj
b250ZW50OiAiIjsKICAgICAgICAgICAgcG9zaXRpb246IGFic29sdXRlOwogICAgICAgICAgICBs
ZWZ0OiAwOyByaWdodDogMDsgYm90dG9tOiAwOwogICAgICAgICAgICBoZWlnaHQ6IDJweDsKICAg
ICAgICAgICAgcG9pbnRlci1ldmVudHM6IG5vbmU7CiAgICAgICAgICAgIHotaW5kZXg6IDE7CiAg
ICAgICAgICAgIGJhY2tncm91bmQ6IHJnYmEoOTEsMTE1LDIzMiwuOTUpOwogICAgICAgICAgICBi
b3JkZXItcmFkaXVzOiAxcHg7CiAgICAgICAgICAgIHRyYW5zZm9ybTogc2NhbGVYKDApOwogICAg
ICAgICAgICB0cmFuc2Zvcm0tb3JpZ2luOiBjZW50ZXI7CiAgICAgICAgICAgIHRyYW5zaXRpb246
IHRyYW5zZm9ybSAuM3MgY3ViaWMtYmV6aWVyKC4yMiwxLC4zNiwxKTsKICAgICAgICB9CiAgICAg
ICAgLml0bTpob3ZlciB7CiAgICAgICAgICAgIGJhY2tncm91bmQ6IHZhcigtLWNhcmQtaCk7CiAg
ICAgICAgICAgIGJveC1zaGFkb3c6CiAgICAgICAgICAgICAgICAwIDJweCA0cHggcmdiYSgyNCwz
Miw1NiwuMDcpLAogICAgICAgICAgICAgICAgMCA2cHggMTZweCByZ2JhKDI0LDMyLDU2LC4xMik7
CiAgICAgICAgfQogICAgICAgIC5pdG06aG92ZXI6OmFmdGVyIHsKICAgICAgICAgICAgdHJhbnNm
b3JtOiBzY2FsZVgoMSk7CiAgICAgICAgfQogICAgICAgIC5pdG0uc2VsIHsKICAgICAgICAgICAg
Ym94LXNoYWRvdzoKICAgICAgICAgICAgICAgIDAgMCAwIDJweCByZ2JhKDkxLDExNSwyMzIsLjQy
KSwKICAgICAgICAgICAgICAgIDAgMnB4IDRweCByZ2JhKDkxLDExNSwyMzIsLjEwKSwKICAgICAg
ICAgICAgICAgIDAgNnB4IDE0cHggcmdiYSg5MSwxMTUsMjMyLC4xNik7CiAgICAgICAgICAgIGJh
Y2tncm91bmQ6ICNlZGYxZmY7CiAgICAgICAgfQogICAgICAgIC5pdG0ubXVsdGkgewogICAgICAg
ICAgICBib3gtc2hhZG93OiAwIDAgMCAxLjVweCByZ2JhKDkxLDExNSwyMzIsLjU1KSwgMCAycHgg
NnB4IHJnYmEoOTEsMTE1LDIzMiwuMTgpOwogICAgICAgICAgICBiYWNrZ3JvdW5kOiAjZWVmMmZm
OwogICAgICAgIH0KICAgICAgICAuaXRtLm11bHRpLnNlbCB7CiAgICAgICAgICAgIGJveC1zaGFk
b3c6IDAgMCAwIDJweCByZ2JhKDkxLDExNSwyMzIsLjcpLCAwIDJweCA4cHggcmdiYSg5MSwxMTUs
MjMyLC4yMik7CiAgICAgICAgfQoKICAgICAgICAjbXVsdGktYmFyIHsKICAgICAgICAgICAgZGlz
cGxheTogbm9uZTsKICAgICAgICAgICAgYWxpZ24taXRlbXM6IGNlbnRlcjsKICAgICAgICAgICAg
Z2FwOiA0cHg7CiAgICAgICAgICAgIG1hcmdpbjogMCAycHggMCAwOwogICAgICAgICAgICBmbGV4
LXNocmluazogMDsKICAgICAgICAgICAgLXdlYmtpdC1hcHAtcmVnaW9uOiBuby1kcmFnOyBhcHAt
cmVnaW9uOiBuby1kcmFnOwogICAgICAgIH0KICAgICAgICAjbXVsdGktYmFyLm9uIHsgZGlzcGxh
eTogaW5saW5lLWZsZXg7IH0KICAgICAgICAjbXVsdGktc2VsIHsKICAgICAgICAgICAgZGlzcGxh
eTogaW5saW5lLWZsZXg7CiAgICAgICAgICAgIGFsaWduLWl0ZW1zOiBjZW50ZXI7CiAgICAgICAg
ICAgIGdhcDogNHB4OwogICAgICAgICAgICBoZWlnaHQ6IDIycHg7CiAgICAgICAgICAgIHBhZGRp
bmc6IDAgOXB4OwogICAgICAgICAgICBmbGV4LXNocmluazogMDsKICAgICAgICAgICAgYm9yZGVy
OiBub25lOwogICAgICAgICAgICBib3JkZXItcmFkaXVzOiAxMXB4OwogICAgICAgICAgICBiYWNr
Z3JvdW5kOiB2YXIoLS1hY2MpOwogICAgICAgICAgICBjb2xvcjogI2ZmZjsKICAgICAgICAgICAg
Y3Vyc29yOiBwb2ludGVyOwogICAgICAgICAgICAtd2Via2l0LWFwcC1yZWdpb246IG5vLWRyYWc7
IGFwcC1yZWdpb246IG5vLWRyYWc7CiAgICAgICAgICAgIHRyYW5zaXRpb246IGJhY2tncm91bmQg
dmFyKC0tdHIpLCBvcGFjaXR5IHZhcigtLXRyKTsKICAgICAgICB9CiAgICAgICAgI211bHRpLXNl
bDpob3ZlciB7IGJhY2tncm91bmQ6ICM0YTYyZDQ7IH0KICAgICAgICAjbXVsdGktc2VsLWxhYiB7
CiAgICAgICAgICAgIGZvbnQtc2l6ZTogMTFweDsKICAgICAgICAgICAgZm9udC13ZWlnaHQ6IDYw
MDsKICAgICAgICAgICAgY29sb3I6ICNmZmY7CiAgICAgICAgICAgIGxldHRlci1zcGFjaW5nOiAu
MDJlbTsKICAgICAgICAgICAgbGluZS1oZWlnaHQ6IDE7CiAgICAgICAgICAgIHVzZXItc2VsZWN0
OiBub25lOwogICAgICAgIH0KICAgICAgICAjbXVsdGktY250IHsKICAgICAgICAgICAgZGlzcGxh
eTogaW5saW5lLWZsZXg7CiAgICAgICAgICAgIGFsaWduLWl0ZW1zOiBjZW50ZXI7CiAgICAgICAg
ICAgIGp1c3RpZnktY29udGVudDogY2VudGVyOwogICAgICAgICAgICBtaW4td2lkdGg6IDFlbTsK
ICAgICAgICAgICAgZm9udC1zaXplOiAxMXB4OwogICAgICAgICAgICBmb250LXdlaWdodDogNzAw
OwogICAgICAgICAgICBjb2xvcjogI2ZmZjsKICAgICAgICAgICAgbGluZS1oZWlnaHQ6IDE7CiAg
ICAgICAgICAgIHVzZXItc2VsZWN0OiBub25lOwogICAgICAgIH0KCiAgICAgICAgI3Bhc3RlLXNl
cC13cmFwIHsKICAgICAgICAgICAgcG9zaXRpb246IHJlbGF0aXZlOyBmbGV4LXNocmluazogMDsK
ICAgICAgICB9CiAgICAgICAgI3Bhc3RlLXNlcC1idG4gewogICAgICAgICAgICBkaXNwbGF5OiBp
bmxpbmUtZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsKICAgICAgICAgICAgaGVpZ2h0OiAyMnB4
OyBwYWRkaW5nOiAwIDhweDsKICAgICAgICAgICAgYm9yZGVyOiBub25lOyBib3JkZXItcmFkaXVz
OiAxMXB4OyBjdXJzb3I6IHBvaW50ZXI7CiAgICAgICAgICAgIGJhY2tncm91bmQ6IHJnYmEoOTEs
MTE1LDIzMiwuMTApOyBjb2xvcjogdmFyKC0tYWNjKTsKICAgICAgICAgICAgZm9udC1zaXplOiAx
MnB4OyBsaW5lLWhlaWdodDogMTsgZm9udC13ZWlnaHQ6IDcwMDsKICAgICAgICAgICAgZm9udC1m
YW1pbHk6IHVpLW1vbm9zcGFjZSwgQ29uc29sYXMsICJDYXNjYWRpYSBNb25vIiwgbW9ub3NwYWNl
OwogICAgICAgICAgICAtd2Via2l0LWFwcC1yZWdpb246IG5vLWRyYWc7IGFwcC1yZWdpb246IG5v
LWRyYWc7CiAgICAgICAgICAgIHRyYW5zaXRpb246IGJhY2tncm91bmQgdmFyKC0tdHIpLCBjb2xv
ciB2YXIoLS10cik7CiAgICAgICAgfQogICAgICAgICNwYXN0ZS1zZXAtYnRuOmhvdmVyLCAjcGFz
dGUtc2VwLWJ0bi5vcGVuIHsKICAgICAgICAgICAgYmFja2dyb3VuZDogcmdiYSg5MSwxMTUsMjMy
LC4xOCk7IGNvbG9yOiAjNGE2MmQ0OwogICAgICAgIH0KICAgICAgICAjcGFzdGUtc2VwLW1lbnUg
ewogICAgICAgICAgICBkaXNwbGF5OiBub25lOyBwb3NpdGlvbjogYWJzb2x1dGU7IHRvcDogY2Fs
YygxMDAlICsgNXB4KTsgcmlnaHQ6IDA7CiAgICAgICAgICAgIHdpZHRoOiBtYXgtY29udGVudDsg
bWF4LXdpZHRoOiAxNDBweDsgbWF4LWhlaWdodDogMjgwcHg7CiAgICAgICAgICAgIG92ZXJmbG93
LXk6IGF1dG87IHotaW5kZXg6IDEyMDsKICAgICAgICAgICAgYmFja2dyb3VuZDogcmdiYSgyNTAs
MjUxLDI1NCwuOTcpOwogICAgICAgICAgICBib3JkZXI6IDFweCBzb2xpZCByZ2JhKDAsMCwwLC4w
NSk7CiAgICAgICAgICAgIGJvcmRlci1yYWRpdXM6IDhweDsKICAgICAgICAgICAgYm94LXNoYWRv
dzogMCA2cHggMjBweCByZ2JhKDQ0LDQ2LDU0LC4xKTsKICAgICAgICAgICAgcGFkZGluZzogM3B4
OwogICAgICAgICAgICBiYWNrZHJvcC1maWx0ZXI6IGJsdXIoOHB4KTsKICAgICAgICB9CiAgICAg
ICAgI3Bhc3RlLXNlcC1tZW51Lm9uIHsKICAgICAgICAgICAgZGlzcGxheTogZmxleDsgZmxleC1k
aXJlY3Rpb246IGNvbHVtbjsgYWxpZ24taXRlbXM6IHN0cmV0Y2g7CiAgICAgICAgfQogICAgICAg
IC5wYXN0ZS1zZXAtaXRlbSB7CiAgICAgICAgICAgIGRpc3BsYXk6IGZsZXg7IGFsaWduLWl0ZW1z
OiBjZW50ZXI7IGp1c3RpZnktY29udGVudDogc3BhY2UtYmV0d2VlbjsgZ2FwOiA4cHg7CiAgICAg
ICAgICAgIHdpZHRoOiAxMDAlOyBib3gtc2l6aW5nOiBib3JkZXItYm94OyB0ZXh0LWFsaWduOiBs
ZWZ0OwogICAgICAgICAgICBwYWRkaW5nOiA0cHggNnB4OyBib3JkZXI6IG5vbmU7IGJvcmRlci1y
YWRpdXM6IDZweDsKICAgICAgICAgICAgYmFja2dyb3VuZDogbm9uZTsgY29sb3I6IHZhcigtLXR4
dDIpOwogICAgICAgICAgICBmb250LXNpemU6IDEwcHg7IGN1cnNvcjogcG9pbnRlcjsgd2hpdGUt
c3BhY2U6IG5vd3JhcDsKICAgICAgICAgICAgb3ZlcmZsb3c6IGhpZGRlbjsKICAgICAgICAgICAg
dHJhbnNpdGlvbjogYmFja2dyb3VuZCB2YXIoLS10ciksIGNvbG9yIHZhcigtLXRyKTsKICAgICAg
ICB9CiAgICAgICAgLnBhc3RlLXNlcC1zeW0gewogICAgICAgICAgICBmbGV4LXNocmluazogMDsK
ICAgICAgICAgICAgZm9udC1mYW1pbHk6IHVpLW1vbm9zcGFjZSwgQ29uc29sYXMsICJDYXNjYWRp
YSBNb25vIiwgbW9ub3NwYWNlOwogICAgICAgICAgICBmb250LXNpemU6IDEwcHg7IGZvbnQtd2Vp
Z2h0OiA3MDA7IGNvbG9yOiB2YXIoLS1hY2MpOwogICAgICAgICAgICBsZXR0ZXItc3BhY2luZzog
LTAuMDNlbTsKICAgICAgICB9CiAgICAgICAgLnBhc3RlLXNlcC1zeW0ub25seSB7IG1pbi13aWR0
aDogMDsgfQogICAgICAgIC5wYXN0ZS1zZXAtbmFtZSB7CiAgICAgICAgICAgIGZsZXg6IDAgMCBh
dXRvOyBtYXJnaW4tbGVmdDogYXV0bzsKICAgICAgICAgICAgZm9udC1zaXplOiAxMHB4OyBjb2xv
cjogdmFyKC0tdHh0Myk7CiAgICAgICAgICAgIG92ZXJmbG93OiBoaWRkZW47IHRleHQtb3ZlcmZs
b3c6IGVsbGlwc2lzOwogICAgICAgIH0KICAgICAgICAucGFzdGUtc2VwLWl0ZW06aG92ZXIgeyBi
YWNrZ3JvdW5kOiByZ2JhKDkxLDExNSwyMzIsLjA4KTsgfQogICAgICAgIC5wYXN0ZS1zZXAtaXRl
bTpob3ZlciAucGFzdGUtc2VwLW5hbWUgeyBjb2xvcjogdmFyKC0tdHh0Mik7IH0KICAgICAgICAu
cGFzdGUtc2VwLWl0ZW0uc2VsIHsgYmFja2dyb3VuZDogcmdiYSg5MSwxMTUsMjMyLC4xMik7IH0K
ICAgICAgICAucGFzdGUtc2VwLWl0ZW0uc2VsIC5wYXN0ZS1zZXAtbmFtZSB7IGNvbG9yOiB2YXIo
LS1hY2MpOyBmb250LXdlaWdodDogNjAwOyB9CiAgICAgICAgLnBhc3RlLXNlcC1mb290IHsKICAg
ICAgICAgICAgbWFyZ2luLXRvcDogM3B4OyBwYWRkaW5nLXRvcDogM3B4OwogICAgICAgICAgICBi
b3JkZXItdG9wOiAxcHggc29saWQgcmdiYSgwLDAsMCwuMDUpOwogICAgICAgICAgICBtaW4td2lk
dGg6IDA7IGFsaWduLXNlbGY6IHN0cmV0Y2g7CiAgICAgICAgfQogICAgICAgICNwYXN0ZS1zZXAt
Y3VzdG9tIHsKICAgICAgICAgICAgZGlzcGxheTogYmxvY2s7IHdpZHRoOiAxMDAlOyBtaW4td2lk
dGg6IDA7IG1heC13aWR0aDogMTAwJTsKICAgICAgICAgICAgYm94LXNpemluZzogYm9yZGVyLWJv
eDsKICAgICAgICAgICAgaGVpZ2h0OiAyMnB4OyBwYWRkaW5nOiAwIDZweDsKICAgICAgICAgICAg
Ym9yZGVyOiBub25lOyBib3JkZXItcmFkaXVzOiA1cHg7CiAgICAgICAgICAgIGJhY2tncm91bmQ6
IHJnYmEoOTEsMTE1LDIzMiwuMDYpOwogICAgICAgICAgICBjb2xvcjogdmFyKC0tdHh0Mik7IGZv
bnQtc2l6ZTogMTBweDsKICAgICAgICAgICAgLXdlYmtpdC1hcHAtcmVnaW9uOiBuby1kcmFnOyBh
cHAtcmVnaW9uOiBuby1kcmFnOwogICAgICAgIH0KICAgICAgICAjcGFzdGUtc2VwLWN1c3RvbTpm
b2N1cyB7CiAgICAgICAgICAgIG91dGxpbmU6IG5vbmU7IGJhY2tncm91bmQ6IHJnYmEoOTEsMTE1
LDIzMiwuMSk7IGNvbG9yOiB2YXIoLS10eHQpOwogICAgICAgIH0KICAgICAgICAjcGFzdGUtc2Vw
LWN1c3RvbTo6cGxhY2Vob2xkZXIgeyBjb2xvcjogdmFyKC0tdHh0Myk7IH0KCiAgICAgICAgLmkt
aWNvIHsKICAgICAgICAgICAgd2lkdGg6IDI4cHg7IGhlaWdodDogMjhweDsgYm9yZGVyLXJhZGl1
czogdmFyKC0tcik7IGRpc3BsYXk6IGZsZXg7CiAgICAgICAgICAgIGFsaWduLWl0ZW1zOiBjZW50
ZXI7IGp1c3RpZnktY29udGVudDogY2VudGVyOyBmbGV4LXNocmluazogMDsKICAgICAgICAgICAg
YmFja2dyb3VuZDogI2VkZjJmZjsgY29sb3I6IHZhcigtLWFjYyk7CiAgICAgICAgICAgIHBvc2l0
aW9uOiByZWxhdGl2ZTsgb3ZlcmZsb3c6IHZpc2libGU7CiAgICAgICAgfQogICAgICAgIC5pLWlj
byBzdmcgeyB3aWR0aDogMTZweDsgaGVpZ2h0OiAxNnB4OyBkaXNwbGF5OiBibG9jazsgfQogICAg
ICAgIC5pLWljby5mdC1pbWcgeyBjb2xvcjogIzdhZDdmZjsgfQogICAgICAgIC5pLWljby5mdC12
aWQgeyBjb2xvcjogI2MwODRmYzsgfQogICAgICAgIC5pLWljby5mdC16aXAgeyBjb2xvcjogIzhh
YjRmZjsgfQogICAgICAgIC5pLWljby5mdC1kaXIgeyBjb2xvcjogI2ZmZDU2YTsgfQogICAgICAg
IC5pLWljby5mdC1haGsgeyBjb2xvcjogIzZkZmY5YTsgfQogICAgICAgIC5pLWljby5tZCB7IGNv
bG9yOiAjNmI4Y2ZmOyB9CiAgICAgICAgLmktaWNvLm1kIHN2ZyB7IHdpZHRoOiAyMHB4OyBoZWln
aHQ6IDIwcHg7IH0KICAgICAgICAuaS1pY28uZnQtbG5rLCAuaS1pY28uZnQtZG9jIHsgY29sb3I6
ICNhOWJkZDA7IH0KICAgICAgICAuaS11c2VkIHsKICAgICAgICAgICAgcG9zaXRpb246IGFic29s
dXRlOyByaWdodDogMDsgYm90dG9tOiAwOwogICAgICAgICAgICB3aWR0aDogMTNweDsgaGVpZ2h0
OiAxM3B4OyBib3JkZXItcmFkaXVzOiA1MCU7CiAgICAgICAgICAgIGJhY2tncm91bmQ6ICMyMmM1
NWU7IGJvcmRlcjogMS41cHggc29saWQgI2ZmZjsKICAgICAgICAgICAgZGlzcGxheTogZmxleDsg
YWxpZ24taXRlbXM6IGNlbnRlcjsganVzdGlmeS1jb250ZW50OiBjZW50ZXI7CiAgICAgICAgICAg
IHBvaW50ZXItZXZlbnRzOiBub25lOyB6LWluZGV4OiAzOwogICAgICAgICAgICBib3gtc2hhZG93
OiAwIDFweCAycHggcmdiYSgwLDAsMCwuMTYpOwogICAgICAgICAgICB0cmFuc2Zvcm06IHRyYW5z
bGF0ZSgzMCUsIDMwJSk7CiAgICAgICAgfQogICAgICAgIC5pLXVzZWQgc3ZnIHsgd2lkdGg6IDlw
eDsgaGVpZ2h0OiA5cHg7IGNvbG9yOiAjZmZmOyBkaXNwbGF5OiBibG9jazsgfQoKICAgICAgICAv
KiBQYXN0ZS1xdWV1ZSB2aXN1YWwgY2hhaW46IGdyYXkgPSBpbiBxdWV1ZTsgZ3JlZW4gPSBkZXF1
ZXVlZCAocGFzdGVkKSBjaGFpbiAqLwogICAgICAgIC5pdG0ucS1tZW1iZXIgewogICAgICAgICAg
ICBwYWRkaW5nLWxlZnQ6IDE0cHg7CiAgICAgICAgICAgIC8qIE1VU1Qgb3ZlcnJpZGUgZ2xvYmFs
IC5pdG17b3ZlcmZsb3c6aGlkZGVufSDigJQgb3RoZXJ3aXNlIGJvdHRvbTotTiByYWlsCiAgICAg
ICAgICAgICAgIGlzIGNsaXBwZWQgYW5kIHRoZSBjaGFpbiBsb29rcyDigJzmlq3nur/igJ0gYWNy
b3NzIHRoZSA1cHggY2FyZCBnYXAgKi8KICAgICAgICAgICAgb3ZlcmZsb3c6IHZpc2libGUgIWlt
cG9ydGFudDsKICAgICAgICB9CiAgICAgICAgLml0bS5xLW1lbWJlciAucS1yYWlsIHsKICAgICAg
ICAgICAgcG9zaXRpb246IGFic29sdXRlOwogICAgICAgICAgICBsZWZ0OiA1cHg7CiAgICAgICAg
ICAgIHRvcDogMDsKICAgICAgICAgICAgLyogQnJpZGdlIC5pdG0gbWFyZ2luLWJvdHRvbTo1cHgg
c28gY29uc2VjdXRpdmUgcmFpbHMgcmVhZCBhcyBvbmUgc3Ryb2tlICovCiAgICAgICAgICAgIGJv
dHRvbTogLTVweDsKICAgICAgICAgICAgd2lkdGg6IDJweDsKICAgICAgICAgICAgYmFja2dyb3Vu
ZDogIzljYTNhZjsKICAgICAgICAgICAgb3BhY2l0eTogLjcyOwogICAgICAgICAgICBwb2ludGVy
LWV2ZW50czogbm9uZTsKICAgICAgICAgICAgei1pbmRleDogNDsKICAgICAgICB9CiAgICAgICAg
Lml0bS5xLW1lbWJlci5xLWZpcnN0IC5xLXJhaWwgeyB0b3A6IDE2cHg7IGJvcmRlci1yYWRpdXM6
IDJweCAycHggMCAwOyB9CiAgICAgICAgLyogRW5kIGNoYWluIGF0IHRoZSBsYXN0IGRvdCDigJQg
ZG8gbm90IGhhbmcgaW50byB0aGUgZ2FwIGJlbG93ICovCiAgICAgICAgLml0bS5xLW1lbWJlci5x
LWxhc3QgLnEtcmFpbCB7CiAgICAgICAgICAgIGJvdHRvbTogYXV0bzsKICAgICAgICAgICAgaGVp
Z2h0OiAyMnB4OwogICAgICAgICAgICBib3JkZXItcmFkaXVzOiAwIDAgMnB4IDJweDsKICAgICAg
ICB9CiAgICAgICAgLml0bS5xLW1lbWJlci5xLWZpcnN0LnEtbGFzdCAucS1yYWlsLAogICAgICAg
IC5pdG0ucS1tZW1iZXIucS1vbmx5IC5xLXJhaWwgeyBkaXNwbGF5OiBub25lOyB9CiAgICAgICAg
Lml0bS5xLW1lbWJlciAucS1kb3QgewogICAgICAgICAgICBwb3NpdGlvbjogYWJzb2x1dGU7CiAg
ICAgICAgICAgIGxlZnQ6IDJweDsKICAgICAgICAgICAgdG9wOiAxNHB4OwogICAgICAgICAgICB3
aWR0aDogOHB4OwogICAgICAgICAgICBoZWlnaHQ6IDhweDsKICAgICAgICAgICAgYm9yZGVyLXJh
ZGl1czogNTAlOwogICAgICAgICAgICBiYWNrZ3JvdW5kOiAjOWNhM2FmOwogICAgICAgICAgICBi
b3JkZXI6IDEuNXB4IHNvbGlkICNmZmY7CiAgICAgICAgICAgIGJveC1zaGFkb3c6IDAgMCAwIDFw
eCByZ2JhKDE1NiwxNjMsMTc1LC40NSk7CiAgICAgICAgICAgIHBvaW50ZXItZXZlbnRzOiBub25l
OwogICAgICAgICAgICB6LWluZGV4OiA1OwogICAgICAgIH0KICAgICAgICAvKiBEZXF1ZXVlZDog
Z3JlZW4gZG90czsgZ3JlZW4gcmFpbCBmb3IgY29uc2VjdXRpdmUgZG9uZSBydW4gKi8KICAgICAg
ICAuaXRtLnEtbWVtYmVyLnEtZG9uZSAucS1kb3QgewogICAgICAgICAgICBiYWNrZ3JvdW5kOiAj
MjJjNTVlOwogICAgICAgICAgICBib3gtc2hhZG93OiAwIDAgMCAxcHggcmdiYSgzNCwxOTcsOTQs
LjQpOwogICAgICAgIH0KICAgICAgICAuaXRtLnEtbWVtYmVyLnEtZG9uZS1saW5rIC5xLXJhaWwg
ewogICAgICAgICAgICBiYWNrZ3JvdW5kOiAjMjJjNTVlOwogICAgICAgICAgICBvcGFjaXR5OiAu
OTI7CiAgICAgICAgfQoKICAgICAgICAuaXRtLmp1bXAtZmxhc2ggewogICAgICAgICAgICBib3gt
c2hhZG93OiAwIDAgMCAycHggcmdiYSg5MSwxMTUsMjMyLC41NSksIDAgMnB4IDEwcHggcmdiYSg5
MSwxMTUsMjMyLC4yMik7CiAgICAgICAgICAgIGJhY2tncm91bmQ6ICNlOGVkZmY7CiAgICAgICAg
ICAgIHRyYW5zaXRpb246IGJhY2tncm91bmQgLjM1cyBlYXNlLCBib3gtc2hhZG93IC4zNXMgZWFz
ZTsKICAgICAgICB9CgogICAgICAgIC5pLWJvZHkgeyBmbGV4OiAxOyBtaW4td2lkdGg6IDA7IGRp
c3BsYXk6IGZsZXg7IGZsZXgtZGlyZWN0aW9uOiBjb2x1bW47IHBvc2l0aW9uOiByZWxhdGl2ZTsg
ei1pbmRleDogMjsgfQogICAgICAgIC5pLXByZXYsIC5pLW5hbWUgewogICAgICAgICAgICBmb250
LXNpemU6IDEzcHg7IGZvbnQtd2VpZ2h0OiA1MDA7IGNvbG9yOiB2YXIoLS10eHQpOyB3b3JkLWJy
ZWFrOiBicmVhay1hbGw7CiAgICAgICAgICAgIHdoaXRlLXNwYWNlOiBwcmUtd3JhcDsgLyog5pSv
5oyB5aSa5paH5Lu2L+WkmuihjOaWh+acrOaNouihjOaYvuekuiAqLwogICAgICAgIH0KICAgICAg
ICAuaS1wcmV2IHsKICAgICAgICAgICAgZGlzcGxheTogLXdlYmtpdC1ib3g7IC13ZWJraXQtYm94
LW9yaWVudDogdmVydGljYWw7IC13ZWJraXQtbGluZS1jbGFtcDogNTsgb3ZlcmZsb3c6IGhpZGRl
bjsKICAgICAgICAgICAgdGV4dC1vdmVyZmxvdzogZWxsaXBzaXM7CiAgICAgICAgfQogICAgICAg
IC5pLW5hbWUgewogICAgICAgICAgICBkaXNwbGF5OiAtd2Via2l0LWJveDsgLXdlYmtpdC1ib3gt
b3JpZW50OiB2ZXJ0aWNhbDsgLXdlYmtpdC1saW5lLWNsYW1wOiAyOyBvdmVyZmxvdzogaGlkZGVu
OwogICAgICAgIH0KICAgICAgICAvKiBGaWxlIGNsaXAgd2hvc2UgcGF0aChzKSBubyBsb25nZXIg
ZXhpc3Qg4oCUIGxpZ2h0IGJvbGQgZ3JheSBzdHJpa2UgKi8KICAgICAgICAuaXRtLmdvbmUgLmkt
bmFtZSB7CiAgICAgICAgICAgIGNvbG9yOiAjOWFhMGIwOwogICAgICAgICAgICB0ZXh0LWRlY29y
YXRpb246IGxpbmUtdGhyb3VnaDsKICAgICAgICAgICAgdGV4dC1kZWNvcmF0aW9uLXRoaWNrbmVz
czogMnB4OwogICAgICAgICAgICB0ZXh0LWRlY29yYXRpb24tY29sb3I6IHJnYmEoMTU0LCAxNjAs
IDE3NiwgLjU1KTsKICAgICAgICAgICAgdGV4dC1kZWNvcmF0aW9uLXNraXAtaW5rOiBub25lOwog
ICAgICAgIH0KICAgICAgICAuaXRtLmdvbmUgLmktaWNvIHsgb3BhY2l0eTogLjU1OyB9CiAgICAg
ICAgLml0bS5nb25lIC5pLXRodW1iLXdyYXAgeyBvcGFjaXR5OiAuNTU7IH0KICAgICAgICAuaS1w
cmV2LnVybCB7IGNvbG9yOiB2YXIoLS1hY2MpOyB9CgogICAgICAgIC5yZi1wYXRoIHsKICAgICAg
ICAgICAgZGlzcGxheTogZmxleDsgZmxleC13cmFwOiB3cmFwOyBhbGlnbi1pdGVtczogY2VudGVy
OwogICAgICAgICAgICBnYXA6IDA7IHJvdy1nYXA6IDNweDsKICAgICAgICAgICAgZm9udC1zaXpl
OiAxM3B4OyBmb250LXdlaWdodDogNjAwOyBjb2xvcjogdmFyKC0tdHh0KTsKICAgICAgICAgICAg
bGluZS1oZWlnaHQ6IDEuNDU7IHdvcmQtYnJlYWs6IGJyZWFrLXdvcmQ7CiAgICAgICAgICAgIG1h
eC13aWR0aDogMTAwJTsKICAgICAgICAgICAgd2lkdGg6IGZpdC1jb250ZW50OwogICAgICAgICAg
ICBwb3NpdGlvbjogcmVsYXRpdmU7CiAgICAgICAgICAgIHotaW5kZXg6IDY7CiAgICAgICAgICAg
IC13ZWJraXQtYXBwLXJlZ2lvbjogbm8tZHJhZzsgYXBwLXJlZ2lvbjogbm8tZHJhZzsKICAgICAg
ICAgICAgcG9pbnRlci1ldmVudHM6IGF1dG87CiAgICAgICAgfQogICAgICAgIC5yZi1zZWcgewog
ICAgICAgICAgICBjb2xvcjogdmFyKC0tYWNjKTsKICAgICAgICAgICAgY3Vyc29yOiBwb2ludGVy
OwogICAgICAgICAgICBwYWRkaW5nOiAxcHggM3B4OwogICAgICAgICAgICBtYXJnaW46IDA7CiAg
ICAgICAgICAgIGJvcmRlcjogbm9uZTsKICAgICAgICAgICAgYmFja2dyb3VuZDogdHJhbnNwYXJl
bnQ7CiAgICAgICAgICAgIGJvcmRlci1yYWRpdXM6IDNweDsKICAgICAgICAgICAgZm9udDogaW5o
ZXJpdDsKICAgICAgICAgICAgZm9udC1zaXplOiAxM3B4OwogICAgICAgICAgICBmb250LXdlaWdo
dDogNjAwOwogICAgICAgICAgICBsaW5lLWhlaWdodDogMS40NTsKICAgICAgICAgICAgLXdlYmtp
dC1hcHAtcmVnaW9uOiBuby1kcmFnOyBhcHAtcmVnaW9uOiBuby1kcmFnOwogICAgICAgICAgICBw
b2ludGVyLWV2ZW50czogYXV0byAhaW1wb3J0YW50OwogICAgICAgICAgICBwb3NpdGlvbjogcmVs
YXRpdmU7CiAgICAgICAgICAgIHotaW5kZXg6IDg7CiAgICAgICAgICAgIHRyYW5zaXRpb246IGJh
Y2tncm91bmQgLjEycyBlYXNlLCBjb2xvciAuMTJzIGVhc2U7CiAgICAgICAgfQogICAgICAgIC5y
Zi1zZWc6aG92ZXIgewogICAgICAgICAgICBiYWNrZ3JvdW5kOiByZ2JhKDkxLDExNSwyMzIsLjE0
KTsKICAgICAgICAgICAgdGV4dC1kZWNvcmF0aW9uOiB1bmRlcmxpbmU7CiAgICAgICAgfQogICAg
ICAgIC5yZi1zZXAgewogICAgICAgICAgICBjb2xvcjogdmFyKC0tdHh0Myk7CiAgICAgICAgICAg
IHBhZGRpbmc6IDAgMnB4OwogICAgICAgICAgICBtYXJnaW46IDA7CiAgICAgICAgICAgIHVzZXIt
c2VsZWN0OiBub25lOwogICAgICAgICAgICBmbGV4LXNocmluazogMDsKICAgICAgICAgICAgb3Bh
Y2l0eTogLjU1OwogICAgICAgICAgICBwb2ludGVyLWV2ZW50czogbm9uZTsKICAgICAgICAgICAg
Zm9udC1zaXplOiAxMnB4OwogICAgICAgICAgICBsaW5lLWhlaWdodDogMS40NTsKICAgICAgICB9
CiAgICAgICAgLml0bS5yZi1maXhlZCAuaS1pY28gewogICAgICAgICAgICBib3gtc2hhZG93OiAw
IDAgMCAxLjVweCByZ2JhKDkxLDExNSwyMzIsLjQ1KTsKICAgICAgICB9CiAgICAgICAgLnJmLXBp
bi10YWcgewogICAgICAgICAgICBkaXNwbGF5OiBpbmxpbmUtZmxleDsgYWxpZ24taXRlbXM6IGNl
bnRlcjsganVzdGlmeS1jb250ZW50OiBjZW50ZXI7CiAgICAgICAgICAgIGZsZXgtc2hyaW5rOiAw
OwogICAgICAgICAgICBoZWlnaHQ6IDE2cHg7IHBhZGRpbmc6IDAgNnB4OyBtYXJnaW4tcmlnaHQ6
IDA7CiAgICAgICAgICAgIGJvcmRlci1yYWRpdXM6IDRweDsKICAgICAgICAgICAgZm9udC1zaXpl
OiAxMHB4OyBmb250LXdlaWdodDogNTAwOwogICAgICAgICAgICBjb2xvcjogIzdhODQ5OTsKICAg
ICAgICAgICAgYmFja2dyb3VuZDogcmdiYSgxMjIsMTMyLDE1MywuMTIpOwogICAgICAgICAgICBi
b3JkZXI6IDFweCBzb2xpZCByZ2JhKDEyMiwxMzIsMTUzLC4yMik7CiAgICAgICAgICAgIGxldHRl
ci1zcGFjaW5nOiAuMDJlbTsKICAgICAgICAgICAgd2hpdGUtc3BhY2U6IG5vd3JhcDsKICAgICAg
ICAgICAgcG9pbnRlci1ldmVudHM6IG5vbmU7CiAgICAgICAgfQogICAgICAgIC5pLXRodW1iLXdy
YXAgewogICAgICAgICAgICB3aWR0aDogMTAwJTsgbWluLWhlaWdodDogNDhweDsgbWF4LWhlaWdo
dDogMTgwcHg7IG1hcmdpbi1ib3R0b206IDRweDsKICAgICAgICAgICAgZGlzcGxheTogZmxleDsg
YWxpZ24taXRlbXM6IGNlbnRlcjsganVzdGlmeS1jb250ZW50OiBjZW50ZXI7CiAgICAgICAgICAg
IGJhY2tncm91bmQ6ICNmM2Y1Zjk7IGJvcmRlci1yYWRpdXM6IHZhcigtLXIpOyBvdmVyZmxvdzog
aGlkZGVuOwogICAgICAgIH0KICAgICAgICAuaS10aHVtYi13cmFwLndhaXRpbmcgewogICAgICAg
ICAgICBtaW4taGVpZ2h0OiA4OHB4OwogICAgICAgICAgICBiYWNrZ3JvdW5kOiBsaW5lYXItZ3Jh
ZGllbnQoOTBkZWcsICNlOGViZjIgMCUsICNmNGY2ZmEgNDUlLCAjZThlYmYyIDEwMCUpOwogICAg
ICAgICAgICBiYWNrZ3JvdW5kLXNpemU6IDIwMCUgMTAwJTsKICAgICAgICAgICAgYW5pbWF0aW9u
OiB0aHVtYlNoaW1tZXIgMS4wNXMgZWFzZS1pbi1vdXQgaW5maW5pdGU7CiAgICAgICAgfQogICAg
ICAgIEBrZXlmcmFtZXMgdGh1bWJTaGltbWVyIHsKICAgICAgICAgICAgMCUgeyBiYWNrZ3JvdW5k
LXBvc2l0aW9uOiAxMDAlIDA7IH0KICAgICAgICAgICAgMTAwJSB7IGJhY2tncm91bmQtcG9zaXRp
b246IC0xMDAlIDA7IH0KICAgICAgICB9CiAgICAgICAgLmktdGh1bWIgeyBtYXgtd2lkdGg6IDEw
MCU7IG1heC1oZWlnaHQ6IDE4MHB4OyB3aWR0aDogYXV0bzsgaGVpZ2h0OiBhdXRvOyBvYmplY3Qt
Zml0OiBjb250YWluOyBkaXNwbGF5OiBibG9jazsgfQogICAgICAgIC5pLXRodW1iLnRodW1iLWxv
YWRpbmcgeyBvcGFjaXR5OiAwOyB3aWR0aDogMXB4OyBoZWlnaHQ6IDFweDsgfQoKICAgICAgICAv
KiBNZXRhIGJhcjogdGltZSBsZWZ0IHwgZXhwYW5kIGNlbnRlciB8IHRhZ3MgcmlnaHQgKi8KICAg
ICAgICAuaS1tZXRhIHsKICAgICAgICAgICAgZGlzcGxheTogZ3JpZDsKICAgICAgICAgICAgZ3Jp
ZC10ZW1wbGF0ZS1jb2x1bW5zOiAxZnIgYXV0byAxZnI7CiAgICAgICAgICAgIGFsaWduLWl0ZW1z
OiBjZW50ZXI7CiAgICAgICAgICAgIGdhcDogNHB4OwogICAgICAgICAgICBtYXJnaW4tdG9wOiA0
cHg7CiAgICAgICAgICAgIHdpZHRoOiAxMDAlOwogICAgICAgIH0KICAgICAgICAuaS1tZXRhIC5p
LXRpbWUgeyBqdXN0aWZ5LXNlbGY6IHN0YXJ0OyB9CiAgICAgICAgLmktbWV0YS1jZW50ZXIgewog
ICAgICAgICAgICBqdXN0aWZ5LXNlbGY6IGNlbnRlcjsKICAgICAgICAgICAgZGlzcGxheTogZmxl
eDsgYWxpZ24taXRlbXM6IGNlbnRlcjsganVzdGlmeS1jb250ZW50OiBjZW50ZXI7CiAgICAgICAg
ICAgIGdhcDogNHB4OwogICAgICAgICAgICBtaW4td2lkdGg6IDFweDsgLyoga2VlcCBjZW50ZXIg
Y29sdW1uIGV2ZW4gd2hlbiBleHBhbmQgaXMgaGlkZGVuICovCiAgICAgICAgfQogICAgICAgIC5p
LW1ldGEtcmlnaHQgewogICAgICAgICAgICBqdXN0aWZ5LXNlbGY6IGVuZDsKICAgICAgICAgICAg
ZGlzcGxheTogZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsgZ2FwOiA1cHg7IGZsZXgtd3JhcDog
bm93cmFwOwogICAgICAgICAgICBqdXN0aWZ5LWNvbnRlbnQ6IGZsZXgtZW5kOwogICAgICAgICAg
ICBtaW4td2lkdGg6IDA7CiAgICAgICAgfQogICAgICAgIC5pLW1ldGEtcmlnaHQudGV4dC1tZXRh
IHsKICAgICAgICAgICAgZmxleC13cmFwOiBub3dyYXA7CiAgICAgICAgICAgIGdhcDogNHB4Owog
ICAgICAgIH0KICAgICAgICAuaS1zcmMtdGl0bGUgewogICAgICAgICAgICBmb250LXNpemU6IDEw
cHg7CiAgICAgICAgICAgIGNvbG9yOiB2YXIoLS10eHQzKTsKICAgICAgICAgICAgbWF4LXdpZHRo
OiAxMWVtOwogICAgICAgICAgICBvdmVyZmxvdzogaGlkZGVuOwogICAgICAgICAgICB0ZXh0LW92
ZXJmbG93OiBlbGxpcHNpczsKICAgICAgICAgICAgd2hpdGUtc3BhY2U6IG5vd3JhcDsKICAgICAg
ICAgICAgbWluLXdpZHRoOiAwOwogICAgICAgICAgICBsaW5lLWhlaWdodDogMS40OwogICAgICAg
IH0KICAgICAgICAuaS10aW1lLCAuaS10YWcgeyBmb250LXNpemU6IDEwcHg7IGNvbG9yOiB2YXIo
LS10eHQzKTsgfQogICAgICAgIC5pLXRhZyB7CiAgICAgICAgICAgIGJhY2tncm91bmQ6ICNmMWYz
Zjg7IHBhZGRpbmc6IDAgNXB4OyBib3JkZXItcmFkaXVzOiAzcHg7CiAgICAgICAgICAgIHdoaXRl
LXNwYWNlOiBub3dyYXA7IGZsZXgtc2hyaW5rOiAwOyBsaW5lLWhlaWdodDogMS40OwogICAgICAg
IH0KICAgICAgICAuaS1jaGFycyB7CiAgICAgICAgICAgIGZvbnQtc2l6ZTogMTBweDsgY29sb3I6
IHZhcigtLXR4dDMpOwogICAgICAgICAgICBiYWNrZ3JvdW5kOiAjZjFmM2Y4OyBwYWRkaW5nOiAw
IDVweDsgYm9yZGVyLXJhZGl1czogM3B4OwogICAgICAgICAgICBmb250LXZhcmlhbnQtbnVtZXJp
YzogdGFidWxhci1udW1zOwogICAgICAgICAgICB3aGl0ZS1zcGFjZTogbm93cmFwOwogICAgICAg
ICAgICBkaXNwbGF5OiBpbmxpbmUtZmxleDsgYWxpZ24taXRlbXM6IGJhc2VsaW5lOyBnYXA6IDJw
eDsKICAgICAgICB9CiAgICAgICAgLmktY2hhcnMgLm4gewogICAgICAgICAgICBkaXNwbGF5OiBp
bmxpbmUtYmxvY2s7CiAgICAgICAgICAgIG1pbi13aWR0aDogNGNoOwogICAgICAgICAgICB0ZXh0
LWFsaWduOiByaWdodDsKICAgICAgICAgICAgZm9udC1mYW1pbHk6ICdDYXNjYWRpYSBNb25vJywg
J0NvbnNvbGFzJywgJ1NhcmFzYSBNb25vIFNDJywgdWktbW9ub3NwYWNlLCBtb25vc3BhY2U7CiAg
ICAgICAgICAgIGZvbnQtd2VpZ2h0OiA2MDA7CiAgICAgICAgICAgIGNvbG9yOiB2YXIoLS10eHQy
KTsKICAgICAgICB9CiAgICAgICAgLyogc3JjLXRpdGxlLXRpcCAqLwogICAgICAgIC5pLXNyYy1p
Y28sIC5tZy1zcmMgeyBjdXJzb3I6IHBvaW50ZXI7IH0KICAgICAgICAjc3JjLXRpcCB7CiAgICAg
ICAgICAgIHBvc2l0aW9uOiBmaXhlZDsgei1pbmRleDogOTk5OTk7CiAgICAgICAgICAgIG1heC13
aWR0aDogbWluKDI4MHB4LCBjYWxjKDEwMHZ3IC0gMTZweCkpOwogICAgICAgICAgICBwYWRkaW5n
OiA2cHggMTBweDsKICAgICAgICAgICAgYm9yZGVyLXJhZGl1czogOHB4OwogICAgICAgICAgICBi
YWNrZ3JvdW5kOiByZ2JhKDMyLDM2LDQ4LC45Mik7IGNvbG9yOiAjZmZmOwogICAgICAgICAgICBm
b250LXNpemU6IDEycHg7IGxpbmUtaGVpZ2h0OiAxLjM1OwogICAgICAgICAgICBib3gtc2hhZG93
OiAwIDZweCAxOHB4IHJnYmEoMCwwLDAsLjIyKTsKICAgICAgICAgICAgcG9pbnRlci1ldmVudHM6
IG5vbmU7CiAgICAgICAgICAgIG9wYWNpdHk6IDA7IHRyYW5zZm9ybTogdHJhbnNsYXRlWSg0cHgp
OwogICAgICAgICAgICB0cmFuc2l0aW9uOiBvcGFjaXR5IC4ycyBlYXNlLCB0cmFuc2Zvcm0gLjIy
cyBjdWJpYy1iZXppZXIoLjIyLDEsLjM2LDEpOwogICAgICAgICAgICB3b3JkLWJyZWFrOiBicmVh
ay13b3JkOwogICAgICAgIH0KICAgICAgICAjc3JjLXRpcC5zaG93IHsgb3BhY2l0eTogMTsgdHJh
bnNmb3JtOiB0cmFuc2xhdGVZKDApOyB9CiAgICAgICAgLmktc3JjLWljbyB7CiAgICAgICAgICAg
IHdpZHRoOiAxNHB4OyBoZWlnaHQ6IDE0cHg7IGZsZXgtc2hyaW5rOiAwOwogICAgICAgICAgICBi
b3JkZXItcmFkaXVzOiAycHg7IG9iamVjdC1maXQ6IGNvbnRhaW47CiAgICAgICAgICAgIGRpc3Bs
YXk6IGJsb2NrOwogICAgICAgIH0KICAgICAgICAuaS1udW0gewogICAgICAgICAgICBkaXNwbGF5
OiBmbGV4OyBmbGV4LWRpcmVjdGlvbjogY29sdW1uOyBhbGlnbi1pdGVtczogZmxleC1lbmQ7CiAg
ICAgICAgICAgIGp1c3RpZnktY29udGVudDogc3BhY2UtYmV0d2VlbjsKICAgICAgICAgICAgYWxp
Z24tc2VsZjogc3RyZXRjaDsKICAgICAgICAgICAgZm9udC1zaXplOiAxMHB4OyBjb2xvcjogdmFy
KC0tdHh0Myk7IG1pbi13aWR0aDogMTZweDsKICAgICAgICAgICAgdGV4dC1hbGlnbjogcmlnaHQ7
IGZsZXgtc2hyaW5rOiAwOwogICAgICAgICAgICBwYWRkaW5nLXRvcDogMnB4OwogICAgICAgIH0K
ICAgICAgICAuaS1udW0gLmktc3JjLWljbyB7IHdpZHRoOiAxNnB4OyBoZWlnaHQ6IDE2cHg7IG1h
cmdpbi10b3A6IGF1dG87IH0KCiAgICAgICAgLmktZXhwYW5kLWJ0biB7CiAgICAgICAgICAgIGJv
cmRlcjogbm9uZTsgYmFja2dyb3VuZDogbm9uZTsgY3Vyc29yOiBwb2ludGVyOwogICAgICAgICAg
ICBjb2xvcjogdmFyKC0tdHh0Myk7IGZvbnQtc2l6ZTogMTJweDsgcGFkZGluZzogM3B4IDEwcHg7
CiAgICAgICAgICAgIGJvcmRlci1yYWRpdXM6IDhweDsgZGlzcGxheTogbm9uZTsgYWxpZ24taXRl
bXM6IGNlbnRlcjsgZ2FwOiA0cHg7CiAgICAgICAgICAgIHRyYW5zaXRpb246IGNvbG9yIHZhcigt
LXRyKSwgYmFja2dyb3VuZCB2YXIoLS10cik7CiAgICAgICAgICAgIC13ZWJraXQtYXBwLXJlZ2lv
bjogbm8tZHJhZzsgYXBwLXJlZ2lvbjogbm8tZHJhZzsKICAgICAgICAgICAgbGluZS1oZWlnaHQ6
IDEuMjsKICAgICAgICB9CiAgICAgICAgLmktZXhwYW5kLWJ0biBzdmcgeyB3aWR0aDogMTRweDsg
aGVpZ2h0OiAxNHB4OyBmbGV4LXNocmluazogMDsgfQogICAgICAgIC5pLWV4cGFuZC1idG4ub24g
eyBkaXNwbGF5OiBpbmxpbmUtZmxleDsgfQogICAgICAgIC5pLWV4cGFuZC1idG46aG92ZXIgeyBj
b2xvcjogdmFyKC0tYWNjKTsgYmFja2dyb3VuZDogcmdiYSg5MSwxMTUsMjMyLC4wOCk7IH0KICAg
ICAgICAuaS1wcmV2LmV4cGFuZGVkLCAuaS1uYW1lLmV4cGFuZGVkIHsKICAgICAgICAgICAgLXdl
YmtpdC1saW5lLWNsYW1wOiB1bnNldDsKICAgICAgICAgICAgZGlzcGxheTogYmxvY2s7CiAgICAg
ICAgICAgIG92ZXJmbG93OiBoaWRkZW47CiAgICAgICAgICAgIC8qIOmrmOW6pueUsSBKUyDmjInl
iJfooajlj6/op4bljLrorr7lrprvvJrnuqbljaDmlbTooajlsJHkuIDooYwgKi8KICAgICAgICB9
CiAgICAgICAgLmktc3JjLXRpdGxlIHsgZGlzcGxheTogbm9uZSAhaW1wb3J0YW50OyB9CiAgICAg
ICAgLmktZmlsZS1kZXRhaWwgewogICAgICAgICAgICBkaXNwbGF5OiBub25lOwogICAgICAgICAg
ICBtYXJnaW4tdG9wOiA0cHg7CiAgICAgICAgICAgIHBhZGRpbmc6IDA7CiAgICAgICAgICAgIGJh
Y2tncm91bmQ6IG5vbmU7CiAgICAgICAgICAgIGJvcmRlcjogbm9uZTsKICAgICAgICB9CiAgICAg
ICAgLmktZmlsZS1kZXRhaWwub24geyBkaXNwbGF5OiBibG9jazsgfQogICAgICAgIC5mZC1ibG9j
ayB7CiAgICAgICAgICAgIGRpc3BsYXk6IGZsZXg7IGZsZXgtZGlyZWN0aW9uOiBjb2x1bW47IGdh
cDogNnB4OwogICAgICAgIH0KICAgICAgICAuZmQtYmxvY2sgKyAuZmQtYmxvY2sgeyBtYXJnaW4t
dG9wOiA4cHg7IH0KICAgICAgICAuZmQtcGF0aCB7CiAgICAgICAgICAgIHdpZHRoOiAxMDAlOwog
ICAgICAgICAgICBmb250OiA2MDAgMTJweC8xLjU1ICdTZWdvZSBVSSBWYXJpYWJsZSBUZXh0Jywn
U2Vnb2UgVUknLCdNaWNyb3NvZnQgWWFIZWkgVUknLHNhbnMtc2VyaWY7CiAgICAgICAgICAgIGNv
bG9yOiB2YXIoLS10eHQyKTsKICAgICAgICAgICAgbGV0dGVyLXNwYWNpbmc6IC4wMWVtOwogICAg
ICAgICAgICB3b3JkLWJyZWFrOiBicmVhay1hbGw7CiAgICAgICAgICAgIHVzZXItc2VsZWN0OiB0
ZXh0OwogICAgICAgICAgICAtd2Via2l0LWFwcC1yZWdpb246IG5vLWRyYWc7IGFwcC1yZWdpb246
IG5vLWRyYWc7CiAgICAgICAgfQogICAgICAgIC5mZC1wYXRoLmxpdmUgeyBjdXJzb3I6IHBvaW50
ZXI7IH0KICAgICAgICAuZmQtcGF0aC5saXZlOmhvdmVyIHsgY29sb3I6IHZhcigtLWFjYyk7IH0K
ICAgICAgICAuZmQtcGF0aC5kZWFkIHsKICAgICAgICAgICAgY29sb3I6ICM5YWEwYjA7CiAgICAg
ICAgICAgIHRleHQtZGVjb3JhdGlvbjogbGluZS10aHJvdWdoOwogICAgICAgICAgICB0ZXh0LWRl
Y29yYXRpb24tdGhpY2tuZXNzOiAycHg7CiAgICAgICAgICAgIHRleHQtZGVjb3JhdGlvbi1jb2xv
cjogcmdiYSgxNTQsIDE2MCwgMTc2LCAuNTUpOwogICAgICAgICAgICB0ZXh0LWRlY29yYXRpb24t
c2tpcC1pbms6IG5vbmU7CiAgICAgICAgICAgIGN1cnNvcjogZGVmYXVsdDsKICAgICAgICB9CiAg
ICAgICAgLmZkLWFjdGlvbnMgewogICAgICAgICAgICBkaXNwbGF5OiBmbGV4OyBhbGlnbi1pdGVt
czogY2VudGVyOyBqdXN0aWZ5LWNvbnRlbnQ6IGZsZXgtZW5kOwogICAgICAgICAgICBnYXA6IDhw
eDsgZmxleC13cmFwOiB3cmFwOwogICAgICAgIH0KICAgICAgICAuZmQtYnRuIHsKICAgICAgICAg
ICAgYm9yZGVyOiBub25lOyBiYWNrZ3JvdW5kOiBub25lOyBjdXJzb3I6IHBvaW50ZXI7CiAgICAg
ICAgICAgIGNvbG9yOiB2YXIoLS10eHQzKTsgZm9udC1zaXplOiAxMHB4OyBmb250LXdlaWdodDog
NjAwOwogICAgICAgICAgICBwYWRkaW5nOiAxcHggMnB4OyBkaXNwbGF5OiBpbmxpbmUtZmxleDsg
YWxpZ24taXRlbXM6IGNlbnRlcjsgZ2FwOiAycHg7CiAgICAgICAgICAgIHdoaXRlLXNwYWNlOiBu
b3dyYXA7CiAgICAgICAgICAgIC13ZWJraXQtYXBwLXJlZ2lvbjogbm8tZHJhZzsgYXBwLXJlZ2lv
bjogbm8tZHJhZzsKICAgICAgICAgICAgdHJhbnNpdGlvbjogY29sb3IgdmFyKC0tdHIpOwogICAg
ICAgIH0KICAgICAgICAuZmQtYnRuOmhvdmVyIHsgY29sb3I6IHZhcigtLWFjYyk7IH0KICAgICAg
ICAuZmQtYnRuLm9rIHsgY29sb3I6ICMxZjdhNTU7IH0KCiAgICAgICAgLyog4pSA4pSAIENvbnRl
eHQgbWVudSDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDi
lIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIAgKi8KICAgICAg
ICAjY3R4IHsKICAgICAgICAgICAgcG9zaXRpb246IGZpeGVkOyB6LWluZGV4OiA5OTk5OyBtaW4t
d2lkdGg6IDEzMnB4OyBkaXNwbGF5OiBub25lOyBwYWRkaW5nOiA0cHg7CiAgICAgICAgICAgIGJh
Y2tncm91bmQ6ICNmZmY7IGJvcmRlci1yYWRpdXM6IHZhcigtLXIpOyBib3gtc2hhZG93OiAwIDZw
eCAxNnB4IHJnYmEoMCwwLDAsLjE0KTsKICAgICAgICAgICAgLXdlYmtpdC1hcHAtcmVnaW9uOiBu
by1kcmFnOyBhcHAtcmVnaW9uOiBuby1kcmFnOwogICAgICAgIH0KICAgICAgICAjY3R4Lm9uIHsg
ZGlzcGxheTogYmxvY2s7IH0KICAgICAgICAuYy1pdGVtIHsKICAgICAgICAgICAgZGlzcGxheTog
ZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsgZ2FwOiA3cHg7IHBhZGRpbmc6IDZweCA5cHg7CiAg
ICAgICAgICAgIGJvcmRlci1yYWRpdXM6IHZhcigtLXIpOyBjdXJzb3I6IHBvaW50ZXI7IGZvbnQt
c2l6ZTogMTFweDsgY29sb3I6IHZhcigtLXR4dCk7CiAgICAgICAgfQogICAgICAgIC5jLWl0ZW06
aG92ZXIgeyBiYWNrZ3JvdW5kOiAjZjJmNGY5OyB9CiAgICAgICAgLmMtaXRlbS5kYW5nZXIgeyBj
b2xvcjogI2ZmN2I5YzsgfQogICAgICAgIC5jLXNlcCB7IGhlaWdodDogMXB4OyBiYWNrZ3JvdW5k
OiAjZWNlZmY1OyBtYXJnaW46IDNweCAwOyB9CiAgICAgICAgLmMtaWNvIHsgd2lkdGg6IDE0cHg7
IHRleHQtYWxpZ246IGNlbnRlcjsgfQogICAgICAgIC5jLXN1YndyYXAgeyBwb3NpdGlvbjogcmVs
YXRpdmU7IH0KICAgICAgICAuYy1zdWJ3cmFwID4gLmMtaXRlbSB7IHdpZHRoOiAxMDAlOyBib3gt
c2l6aW5nOiBib3JkZXItYm94OyB9CiAgICAgICAgLmMtY2FyZXQgeyBtYXJnaW4tbGVmdDogYXV0
bzsgY29sb3I6IHZhcigtLXR4dDMpOyBmb250LXNpemU6IDEwcHg7IH0KICAgICAgICAuYy1zdWIg
ewogICAgICAgICAgICBkaXNwbGF5OiBub25lOyBwb3NpdGlvbjogYWJzb2x1dGU7IGxlZnQ6IGNh
bGMoMTAwJSAtIDJweCk7IHRvcDogLTJweDsgei1pbmRleDogMTsKICAgICAgICAgICAgbWluLXdp
ZHRoOiAwOyB3aWR0aDogbWF4LWNvbnRlbnQ7IHBhZGRpbmc6IDJweDsKICAgICAgICAgICAgYmFj
a2dyb3VuZDogI2ZmZjsgYm9yZGVyLXJhZGl1czogdmFyKC0tcik7CiAgICAgICAgICAgIGJveC1z
aGFkb3c6IDAgNnB4IDE2cHggcmdiYSgwLDAsMCwuMTQpOwogICAgICAgIH0KICAgICAgICAuYy1z
dWIubGVmdCB7CiAgICAgICAgICAgIGxlZnQ6IGF1dG87IHJpZ2h0OiBjYWxjKDEwMCUgLSAycHgp
OwogICAgICAgIH0KICAgICAgICAuYy1zdWJ3cmFwOmhvdmVyID4gLmMtc3ViLAogICAgICAgIC5j
LXN1YndyYXAub3BlbiA+IC5jLXN1YiB7IGRpc3BsYXk6IGJsb2NrOyB9CiAgICAgICAgLmMtc3Vi
IC5jLWl0ZW0gewogICAgICAgICAgICBmb250LWZhbWlseTogdWktbW9ub3NwYWNlLCBDb25zb2xh
cywgIkNhc2NhZGlhIE1vbm8iLCBtb25vc3BhY2U7CiAgICAgICAgICAgIGZvbnQtc2l6ZTogMTBw
eDsgd2hpdGUtc3BhY2U6IG5vd3JhcDsKICAgICAgICAgICAgcGFkZGluZzogNHB4IDdweDsgZ2Fw
OiAwOwogICAgICAgIH0KICAgICAgICAuYy1zdWIgLmMtaXRlbS5waWNrIHsKICAgICAgICAgICAg
YmFja2dyb3VuZDogcmdiYSg5MSwgMTI0LCAyNTAsIC4xNCk7CiAgICAgICAgICAgIGNvbG9yOiAj
M2I1YmRiOwogICAgICAgICAgICBmb250LXdlaWdodDogNjAwOwogICAgICAgIH0KICAgICAgICAu
Yy1zdWIgLmMtaXRlbS5waWNrIC5jLW51bSwKICAgICAgICAuYy1zdWIgLmMtaXRlbS5waWNrIC5j
LWFycm93IHsgY29sb3I6ICM1YjdjZmE7IH0KICAgICAgICAuYy1zdWIgLmMtbnVtIHsKICAgICAg
ICAgICAgd2lkdGg6IDEycHg7IGZsZXgtc2hyaW5rOiAwOyBjb2xvcjogdmFyKC0tdHh0Myk7IHRl
eHQtYWxpZ246IGxlZnQ7CiAgICAgICAgICAgIG1hcmdpbi1yaWdodDogNHB4OwogICAgICAgIH0K
ICAgICAgICAuYy1zdWIgLmMtZnJvbSB7CiAgICAgICAgICAgIGRpc3BsYXk6IGlubGluZS1ibG9j
azsgbWluLXdpZHRoOiAwOyB0ZXh0LWFsaWduOiBsZWZ0OyBmbGV4LXNocmluazogMDsKICAgICAg
ICB9CiAgICAgICAgLmMtc3ViIC5jLWFycm93IHsKICAgICAgICAgICAgZGlzcGxheTogaW5saW5l
LWJsb2NrOyBwYWRkaW5nOiAwIDRweDsgY29sb3I6IHZhcigtLXR4dDMpOyBmbGV4LXNocmluazog
MDsKICAgICAgICB9CiAgICAgICAgLmMtc3ViIC5jLXRvIHsgZmxleC1zaHJpbms6IDA7IH0KCiAg
ICAgICAgLyog4pSA4pSAIENsZWFyIGNvbmZpcm0g4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA
4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA
4pSA4pSA4pSAICovCiAgICAgICAgI2Nsci1kbGcgewogICAgICAgICAgICBkaXNwbGF5OiBub25l
OyBwb3NpdGlvbjogZml4ZWQ7IGluc2V0OiAwOyB6LWluZGV4OiAxMDAwMDsKICAgICAgICAgICAg
YmFja2dyb3VuZDogcmdiYSgyMCwgMjIsIDM1LCAuNDIpOwogICAgICAgICAgICBhbGlnbi1pdGVt
czogY2VudGVyOyBqdXN0aWZ5LWNvbnRlbnQ6IGNlbnRlcjsKICAgICAgICAgICAgLXdlYmtpdC1h
cHAtcmVnaW9uOiBuby1kcmFnOyBhcHAtcmVnaW9uOiBuby1kcmFnOwogICAgICAgIH0KICAgICAg
ICAjY2xyLWRsZy5vbiB7IGRpc3BsYXk6IGZsZXg7IH0KICAgICAgICAuY2xyLWJveCB7CiAgICAg
ICAgICAgIHdpZHRoOiBtaW4oMjgwcHgsIGNhbGMoMTAwJSAtIDMycHgpKTsKICAgICAgICAgICAg
YmFja2dyb3VuZDogI2ZmZjsgYm9yZGVyLXJhZGl1czogMTJweDsKICAgICAgICAgICAgYm94LXNo
YWRvdzogMCAxMnB4IDMycHggcmdiYSgwLDAsMCwuMTgpOwogICAgICAgICAgICBwYWRkaW5nOiAx
NnB4IDE2cHggMTRweDsgY29sb3I6IHZhcigtLXR4dCk7CiAgICAgICAgfQogICAgICAgIC5jbHIt
dGl0bGUgeyBmb250LXNpemU6IDE0cHg7IGZvbnQtd2VpZ2h0OiA3MDA7IG1hcmdpbi1ib3R0b206
IDZweDsgfQogICAgICAgIC5jbHItZGVzYyB7IGZvbnQtc2l6ZTogMTFweDsgY29sb3I6IHZhcigt
LXR4dDMpOyBsaW5lLWhlaWdodDogMS41OyBtYXJnaW4tYm90dG9tOiAxMnB4OyB9CiAgICAgICAg
LmNsci1jaGVjayB7CiAgICAgICAgICAgIGRpc3BsYXk6IGZsZXg7IGFsaWduLWl0ZW1zOiBjZW50
ZXI7IGdhcDogN3B4OwogICAgICAgICAgICBmb250LXNpemU6IDEycHg7IGNvbG9yOiB2YXIoLS10
eHQpOyBjdXJzb3I6IHBvaW50ZXI7CiAgICAgICAgICAgIHVzZXItc2VsZWN0OiBub25lOyBtYXJn
aW4tYm90dG9tOiAxNHB4OwogICAgICAgIH0KICAgICAgICAuY2xyLWNoZWNrIGlucHV0IHsKICAg
ICAgICAgICAgd2lkdGg6IDE0cHg7IGhlaWdodDogMTRweDsgYWNjZW50LWNvbG9yOiB2YXIoLS1h
Y2MpOyBjdXJzb3I6IHBvaW50ZXI7CiAgICAgICAgfQogICAgICAgIC5jbHItYnRucyB7IGRpc3Bs
YXk6IGZsZXg7IGdhcDogOHB4OyBqdXN0aWZ5LWNvbnRlbnQ6IGZsZXgtZW5kOyB9CiAgICAgICAg
LmNsci1idG5zIGJ1dHRvbiB7CiAgICAgICAgICAgIGJvcmRlcjogbm9uZTsgYm9yZGVyLXJhZGl1
czogOHB4OyBwYWRkaW5nOiA3cHggMTRweDsKICAgICAgICAgICAgZm9udC1zaXplOiAxMnB4OyBj
dXJzb3I6IHBvaW50ZXI7IGZvbnQtd2VpZ2h0OiA2MDA7CiAgICAgICAgICAgIHRyYW5zaXRpb246
IGJhY2tncm91bmQgdmFyKC0tdHIpLCBjb2xvciB2YXIoLS10cik7CiAgICAgICAgfQogICAgICAg
ICNjbHItY2FuY2VsIHsgYmFja2dyb3VuZDogI2YxZjNmODsgY29sb3I6IHZhcigtLXR4dDIpOyB9
CiAgICAgICAgI2Nsci1jYW5jZWw6aG92ZXIgeyBiYWNrZ3JvdW5kOiAjZTZlOWYyOyB9CiAgICAg
ICAgI2Nsci1vayB7IGJhY2tncm91bmQ6IHJnYmEoMjU1LDEyMywxNTYsLjE0KTsgY29sb3I6ICNl
ODVhN2E7IH0KICAgICAgICAjY2xyLW9rOmhvdmVyIHsgYmFja2dyb3VuZDogcmdiYSgyNTUsMTIz
LDE1NiwuMjQpOyB9CgogICAgICAgIC8qIOKUgOKUgCBGaWxlIHBhdGggdGlwIOKUgOKUgOKUgOKU
gOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKU
gOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgCAqLwogICAgICAgICNwYXRoLXRpcCB7CiAgICAgICAg
ICAgIGRpc3BsYXk6IG5vbmU7IHBvc2l0aW9uOiBmaXhlZDsgei1pbmRleDogMTAwMDE7CiAgICAg
ICAgICAgIHdpZHRoOiBtaW4oMzIwcHgsIGNhbGMoMTAwdncgLSAxNnB4KSk7CiAgICAgICAgICAg
IG1heC1oZWlnaHQ6IG1pbigyODBweCwgY2FsYygxMDB2aCAtIDI0cHgpKTsKICAgICAgICAgICAg
b3ZlcmZsb3c6IGF1dG87CiAgICAgICAgICAgIHBhZGRpbmc6IDA7CiAgICAgICAgICAgIGJhY2tn
cm91bmQ6IGxpbmVhci1ncmFkaWVudCgxNjVkZWcsICNmZmZmZmYgMCUsICNmNmY4ZmMgMTAwJSk7
CiAgICAgICAgICAgIGJvcmRlcjogMXB4IHNvbGlkIHJnYmEoNzAsIDg0LCAxMjAsIC4xKTsKICAg
ICAgICAgICAgYm9yZGVyLXJhZGl1czogMTJweDsKICAgICAgICAgICAgYm94LXNoYWRvdzoKICAg
ICAgICAgICAgICAgIDAgNHB4IDZweCByZ2JhKDMwLCA0MCwgNzAsIC4wNCksCiAgICAgICAgICAg
ICAgICAwIDE0cHggMzZweCByZ2JhKDMwLCA0MCwgNzAsIC4xNik7CiAgICAgICAgICAgIGNvbG9y
OiB2YXIoLS10eHQpOwogICAgICAgICAgICBwb2ludGVyLWV2ZW50czogYXV0bzsKICAgICAgICAg
ICAgb3BhY2l0eTogMDsKICAgICAgICAgICAgdHJhbnNmb3JtOiB0cmFuc2xhdGVZKDRweCkgc2Nh
bGUoLjk4KTsKICAgICAgICAgICAgdHJhbnNpdGlvbjogb3BhY2l0eSAuMTRzIGVhc2UsIHRyYW5z
Zm9ybSAuMTRzIGVhc2U7CiAgICAgICAgICAgIC13ZWJraXQtYXBwLXJlZ2lvbjogbm8tZHJhZzsg
YXBwLXJlZ2lvbjogbm8tZHJhZzsKICAgICAgICB9CiAgICAgICAgI3BhdGgtdGlwLm9uIHsKICAg
ICAgICAgICAgZGlzcGxheTogYmxvY2s7CiAgICAgICAgICAgIG9wYWNpdHk6IDE7CiAgICAgICAg
ICAgIHRyYW5zZm9ybTogdHJhbnNsYXRlWSgwKSBzY2FsZSgxKTsKICAgICAgICB9CiAgICAgICAg
LnB0LWhlYWQgewogICAgICAgICAgICBkaXNwbGF5OiBmbGV4OyBhbGlnbi1pdGVtczogY2VudGVy
OyBqdXN0aWZ5LWNvbnRlbnQ6IHNwYWNlLWJldHdlZW47CiAgICAgICAgICAgIGdhcDogMTBweDsg
cGFkZGluZzogMTBweCAxMnB4IDhweDsKICAgICAgICAgICAgYm9yZGVyLWJvdHRvbTogMXB4IHNv
bGlkIHJnYmEoNzAsIDg0LCAxMjAsIC4wNyk7CiAgICAgICAgfQogICAgICAgIC5wdC10aXRsZSB7
CiAgICAgICAgICAgIGZvbnQtc2l6ZTogMTFweDsgZm9udC13ZWlnaHQ6IDcwMDsgbGV0dGVyLXNw
YWNpbmc6IC4wNGVtOwogICAgICAgICAgICBjb2xvcjogdmFyKC0tdHh0Mik7IHRleHQtdHJhbnNm
b3JtOiB1cHBlcmNhc2U7CiAgICAgICAgICAgIGZsZXgtc2hyaW5rOiAwOwogICAgICAgIH0KICAg
ICAgICAucHQtaGVhZC1idG4gewogICAgICAgICAgICBmbGV4LXNocmluazogMDsgbWFyZ2luLWxl
ZnQ6IGF1dG87CiAgICAgICAgICAgIGhlaWdodDogMjJweDsgcGFkZGluZzogMCA4cHg7IGRpc3Bs
YXk6IGlubGluZS1mbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBnYXA6IDRweDsKICAgICAgICAg
ICAgYm9yZGVyOiAxcHggc29saWQgcmdiYSgxMDcsMTEyLDEyOCwuMjIpOyBib3JkZXItcmFkaXVz
OiA2cHg7IGN1cnNvcjogcG9pbnRlcjsKICAgICAgICAgICAgYmFja2dyb3VuZDogcmdiYSgxMDcs
MTEyLDEyOCwuMDYpOyBjb2xvcjogIzhhOTBhMDsgZm9udC1zaXplOiAxMXB4OyBmb250LXdlaWdo
dDogNjAwOwogICAgICAgICAgICB3aGl0ZS1zcGFjZTogbm93cmFwOwogICAgICAgICAgICAtd2Vi
a2l0LWFwcC1yZWdpb246IG5vLWRyYWc7IGFwcC1yZWdpb246IG5vLWRyYWc7CiAgICAgICAgICAg
IHRyYW5zaXRpb246IGJhY2tncm91bmQgdmFyKC0tdHIpLCBjb2xvciB2YXIoLS10ciksIGJvcmRl
ci1jb2xvciB2YXIoLS10cik7CiAgICAgICAgfQogICAgICAgIC5wdC1oZWFkLWJ0bjpob3ZlciB7
CiAgICAgICAgICAgIGJhY2tncm91bmQ6IHJnYmEoMTA3LDExMiwxMjgsLjEyKTsgY29sb3I6IHZh
cigtLXR4dDIpOwogICAgICAgICAgICBib3JkZXItY29sb3I6IHJnYmEoMTA3LDExMiwxMjgsLjQp
OwogICAgICAgIH0KICAgICAgICAucHQtbGlzdCB7IHBhZGRpbmc6IDZweCA4cHggOHB4OyBkaXNw
bGF5OiBmbGV4OyBmbGV4LWRpcmVjdGlvbjogY29sdW1uOyBnYXA6IDRweDsgfQogICAgICAgIC5w
dC1yb3cgewogICAgICAgICAgICBkaXNwbGF5OiBncmlkOyBncmlkLXRlbXBsYXRlLWNvbHVtbnM6
IDhweCAxZnI7IGdhcDogOHB4OwogICAgICAgICAgICBwYWRkaW5nOiA4cHggOHB4OyBib3JkZXIt
cmFkaXVzOiA4cHg7CiAgICAgICAgICAgIGJhY2tncm91bmQ6IHJnYmEoMjU1LDI1NSwyNTUsLjcp
OwogICAgICAgIH0KICAgICAgICAucHQtcm93LmRlYWQgeyBiYWNrZ3JvdW5kOiByZ2JhKDI1NSwg
MTIzLCAxNTYsIC4wNik7IH0KICAgICAgICAucHQtZG90IHsKICAgICAgICAgICAgd2lkdGg6IDhw
eDsgaGVpZ2h0OiA4cHg7IGJvcmRlci1yYWRpdXM6IDUwJTsgbWFyZ2luLXRvcDogNXB4OwogICAg
ICAgICAgICBiYWNrZ3JvdW5kOiAjMmViNDc4OyBib3gtc2hhZG93OiAwIDAgMCAzcHggcmdiYSg0
NiwgMTgwLCAxMjAsIC4xOCk7CiAgICAgICAgfQogICAgICAgIC5wdC1yb3cuZGVhZCAucHQtZG90
IHsKICAgICAgICAgICAgYmFja2dyb3VuZDogI2U4NWE3YTsgYm94LXNoYWRvdzogMCAwIDAgM3B4
IHJnYmEoMjMyLCA5MCwgMTIyLCAuMTYpOwogICAgICAgIH0KICAgICAgICAucHQtbmFtZSB7CiAg
ICAgICAgICAgIGZvbnQtc2l6ZTogMTJweDsgZm9udC13ZWlnaHQ6IDY1MDsgY29sb3I6IHZhcigt
LXR4dCk7CiAgICAgICAgICAgIGxpbmUtaGVpZ2h0OiAxLjM7IHdvcmQtYnJlYWs6IGJyZWFrLWFs
bDsKICAgICAgICB9CiAgICAgICAgLnB0LXBhdGggewogICAgICAgICAgICBtYXJnaW4tdG9wOiAz
cHg7CiAgICAgICAgICAgIGZvbnQ6IDEwLjVweC8xLjQ1ICdDYXNjYWRpYSBNb25vJywnQ29uc29s
YXMnLCdNaWNyb3NvZnQgWWFIZWkgVUknLG1vbm9zcGFjZTsKICAgICAgICAgICAgY29sb3I6IHZh
cigtLXR4dDIpOyB3b3JkLWJyZWFrOiBicmVhay1hbGw7CiAgICAgICAgICAgIHVzZXItc2VsZWN0
OiB0ZXh0OwogICAgICAgIH0KICAgICAgICAucHQtcGF0aC5saXZlIHsKICAgICAgICAgICAgY29s
b3I6IHZhcigtLWFjYyk7IGN1cnNvcjogcG9pbnRlcjsKICAgICAgICB9CiAgICAgICAgLnB0LXBh
dGgubGl2ZTpob3ZlciB7IHRleHQtZGVjb3JhdGlvbjogdW5kZXJsaW5lOyB9CiAgICAgICAgLnB0
LXBhdGguZGVhZCB7CiAgICAgICAgICAgIGNvbG9yOiAjYzQzZDVjOwogICAgICAgICAgICB0ZXh0
LWRlY29yYXRpb246IGxpbmUtdGhyb3VnaDsKICAgICAgICAgICAgdGV4dC1kZWNvcmF0aW9uLXRo
aWNrbmVzczogMnB4OwogICAgICAgICAgICB0ZXh0LWRlY29yYXRpb24tY29sb3I6ICNlMTFkNDg7
CiAgICAgICAgICAgIGN1cnNvcjogZGVmYXVsdDsKICAgICAgICB9CiAgICAgICAgLnB0LWFjdGlv
bnMgewogICAgICAgICAgICBtYXJnaW4tdG9wOiA2cHg7CiAgICAgICAgICAgIGRpc3BsYXk6IGZs
ZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGdhcDogNnB4OyBmbGV4LXdyYXA6IHdyYXA7CiAgICAg
ICAgfQogICAgICAgIC5wdC1jb3B5LWJ0biB7CiAgICAgICAgICAgIGhlaWdodDogMjJweDsgcGFk
ZGluZzogMCA4cHg7IGRpc3BsYXk6IGlubGluZS1mbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOwog
ICAgICAgICAgICBib3JkZXI6IDFweCBzb2xpZCByZ2JhKDEwNywxMTIsMTI4LC4yMik7IGJvcmRl
ci1yYWRpdXM6IDZweDsgY3Vyc29yOiBwb2ludGVyOwogICAgICAgICAgICBiYWNrZ3JvdW5kOiBy
Z2JhKDEwNywxMTIsMTI4LC4wNik7IGNvbG9yOiAjOGE5MGEwOyBmb250LXNpemU6IDExcHg7IGZv
bnQtd2VpZ2h0OiA2MDA7CiAgICAgICAgICAgIC13ZWJraXQtYXBwLXJlZ2lvbjogbm8tZHJhZzsg
YXBwLXJlZ2lvbjogbm8tZHJhZzsKICAgICAgICAgICAgdHJhbnNpdGlvbjogYmFja2dyb3VuZCB2
YXIoLS10ciksIGNvbG9yIHZhcigtLXRyKSwgYm9yZGVyLWNvbG9yIHZhcigtLXRyKTsKICAgICAg
ICB9CiAgICAgICAgLnB0LWNvcHktYnRuOmhvdmVyIHsKICAgICAgICAgICAgYmFja2dyb3VuZDog
cmdiYSgxMDcsMTEyLDEyOCwuMTIpOyBjb2xvcjogdmFyKC0tdHh0Mik7CiAgICAgICAgICAgIGJv
cmRlci1jb2xvcjogcmdiYSgxMDcsMTEyLDEyOCwuNCk7CiAgICAgICAgfQogICAgICAgIC5wdC1j
b3B5LWJ0bi5vayB7CiAgICAgICAgICAgIGNvbG9yOiAjMWY3YTU1OyBib3JkZXItY29sb3I6IHJn
YmEoNDYsIDE4MCwgMTIwLCAuMzUpOwogICAgICAgICAgICBiYWNrZ3JvdW5kOiByZ2JhKDQ2LCAx
ODAsIDEyMCwgLjEpOwogICAgICAgIH0KICAgICAgICAuaXRtLml0LWdyb3VwIHsKICAgICAgICAg
ICAgZmxleC1kaXJlY3Rpb246IGNvbHVtbjsKICAgICAgICAgICAgYWxpZ24taXRlbXM6IHN0cmV0
Y2g7CiAgICAgICAgICAgIGdhcDogMDsKICAgICAgICAgICAgcGFkZGluZzogNnB4IDhweCA0cHg7
CiAgICAgICAgICAgIGN1cnNvcjogZGVmYXVsdDsKICAgICAgICB9CiAgICAgICAgLml0bS5pdC1n
cm91cDpob3ZlciB7IGJhY2tncm91bmQ6IHZhcigtLWNhcmQpOyB9CiAgICAgICAgLm1nLWhlYWQg
ewogICAgICAgICAgICBkaXNwbGF5OiBmbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBnYXA6IDZw
eDsKICAgICAgICAgICAgZm9udC1zaXplOiAxMXB4OyBjb2xvcjogdmFyKC0tdHh0Myk7IGZvbnQt
d2VpZ2h0OiA2MDA7CiAgICAgICAgICAgIHBhZGRpbmc6IDJweCAycHggNnB4OyB1c2VyLXNlbGVj
dDogbm9uZTsKICAgICAgICB9CiAgICAgICAgLm1nLWhlYWQgLm1nLXRhZyB7CiAgICAgICAgICAg
IGRpc3BsYXk6IGlubGluZS1mbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOwogICAgICAgICAgICBo
ZWlnaHQ6IDE2cHg7IHBhZGRpbmc6IDAgNnB4OyBib3JkZXItcmFkaXVzOiA4cHg7CiAgICAgICAg
ICAgIGJhY2tncm91bmQ6IHJnYmEoOTEsMTE1LDIzMiwuMTIpOyBjb2xvcjogdmFyKC0tYWNjKTsg
Zm9udC1zaXplOiAxMHB4OwogICAgICAgIH0KICAgICAgICAubWctcm93IHsKICAgICAgICAgICAg
cGFkZGluZzogN3B4IDZweDsgbWFyZ2luLWJvdHRvbTogM3B4OwogICAgICAgICAgICBib3JkZXIt
cmFkaXVzOiA1cHg7IGN1cnNvcjogcG9pbnRlcjsKICAgICAgICAgICAgYm9yZGVyOiAxcHggc29s
aWQgdHJhbnNwYXJlbnQ7CiAgICAgICAgICAgIHRyYW5zaXRpb246IGJhY2tncm91bmQgLjEycyBl
YXNlLCBib3JkZXItY29sb3IgLjEycyBlYXNlOwogICAgICAgIH0KICAgICAgICAubWctcm93Omhv
dmVyIHsgYmFja2dyb3VuZDogdmFyKC0tY2FyZC1oKTsgfQogICAgICAgIC5tZy1yb3cuc2VsIHsK
ICAgICAgICAgICAgYmFja2dyb3VuZDogI2VkZjFmZjsKICAgICAgICAgICAgYm9yZGVyLWNvbG9y
OiByZ2JhKDkxLDExNSwyMzIsLjM1KTsKICAgICAgICAgICAgYm94LXNoYWRvdzogMCAwIDAgMXB4
IHJnYmEoOTEsMTE1LDIzMiwuMjUpOwogICAgICAgIH0KICAgICAgICAubWctcm93Lm11bHRpIHsK
ICAgICAgICAgICAgYmFja2dyb3VuZDogI2VlZjJmZjsKICAgICAgICAgICAgYm9yZGVyLWNvbG9y
OiByZ2JhKDkxLDExNSwyMzIsLjQ1KTsKICAgICAgICB9CiAgICAgICAgLm1nLXRpdGxlIHsKICAg
ICAgICAgICAgZm9udC1zaXplOiAxM3B4OyBmb250LXdlaWdodDogNjAwOyBjb2xvcjogdmFyKC0t
YWNjKTsKICAgICAgICAgICAgbWFyZ2luLWJvdHRvbTogMnB4OyBsaW5lLWhlaWdodDogMS4zNTsK
ICAgICAgICAgICAgZGlzcGxheTogLXdlYmtpdC1ib3g7IC13ZWJraXQtYm94LW9yaWVudDogdmVy
dGljYWw7IC13ZWJraXQtbGluZS1jbGFtcDogMjsKICAgICAgICAgICAgb3ZlcmZsb3c6IGhpZGRl
bjsgd29yZC1icmVhazogYnJlYWstd29yZDsKICAgICAgICB9CiAgICAgICAgLm1nLWJvZHkgewog
ICAgICAgICAgICBmb250LXNpemU6IDEyLjVweDsgZm9udC13ZWlnaHQ6IDUwMDsgY29sb3I6IHZh
cigtLXR4dCk7CiAgICAgICAgICAgIHdoaXRlLXNwYWNlOiBwcmUtd3JhcDsgd29yZC1icmVhazog
YnJlYWstYWxsOwogICAgICAgICAgICBkaXNwbGF5OiAtd2Via2l0LWJveDsgLXdlYmtpdC1ib3gt
b3JpZW50OiB2ZXJ0aWNhbDsgLXdlYmtpdC1saW5lLWNsYW1wOiA0OwogICAgICAgICAgICBvdmVy
ZmxvdzogaGlkZGVuOyBsaW5lLWhlaWdodDogMS40OwogICAgICAgIH0KICAgICAgICAubWctYm9k
eS5pbWcgeyBjb2xvcjogdmFyKC0tdHh0Mik7IH0KICAgICAgICAubWctcm93LXRvcCB7CiAgICAg
ICAgICAgIGRpc3BsYXk6IGZsZXg7IGFsaWduLWl0ZW1zOiBmbGV4LXN0YXJ0OyBnYXA6IDhweDsK
ICAgICAgICB9CiAgICAgICAgLm1nLXJvdy1tYWluIHsgZmxleDogMTsgbWluLXdpZHRoOiAwOyB9
CiAgICAgICAgLm1nLXNyYyB7CiAgICAgICAgICAgIHdpZHRoOiAxOHB4OyBoZWlnaHQ6IDE4cHg7
IGZsZXgtc2hyaW5rOiAwOyBtYXJnaW4tdG9wOiAycHg7CiAgICAgICAgICAgIGJvcmRlci1yYWRp
dXM6IDNweDsgb2JqZWN0LWZpdDogY29udGFpbjsKICAgICAgICAgICAgYmFja2dyb3VuZDogcmdi
YSgwLDAsMCwuMDQpOwogICAgICAgIH0KICAgICAgICAuaS1mYXYtdGl0bGUgewogICAgICAgICAg
ICBmb250LXNpemU6IDEzcHg7IGZvbnQtd2VpZ2h0OiA2MDA7IGNvbG9yOiB2YXIoLS1hY2MpOwog
ICAgICAgICAgICBtYXJnaW46IDAgMCAzcHg7IGxpbmUtaGVpZ2h0OiAxLjM1OwogICAgICAgICAg
ICBkaXNwbGF5OiAtd2Via2l0LWJveDsgLXdlYmtpdC1ib3gtb3JpZW50OiB2ZXJ0aWNhbDsgLXdl
YmtpdC1saW5lLWNsYW1wOiAyOwogICAgICAgICAgICBvdmVyZmxvdzogaGlkZGVuOyB3b3JkLWJy
ZWFrOiBicmVhay13b3JkOwogICAgICAgIH0KICAgICAgICAjdGl0bGUtZGxnIHsKICAgICAgICAg
ICAgZGlzcGxheTogbm9uZTsgcG9zaXRpb246IGZpeGVkOyBpbnNldDogMDsgei1pbmRleDogMTAw
OwogICAgICAgICAgICBiYWNrZ3JvdW5kOiByZ2JhKDE1LDE4LDI4LC4zNSk7CiAgICAgICAgICAg
IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGp1c3RpZnktY29udGVudDogY2VudGVyOwogICAgICAgICAg
ICAtd2Via2l0LWFwcC1yZWdpb246IG5vLWRyYWc7IGFwcC1yZWdpb246IG5vLWRyYWc7CiAgICAg
ICAgfQogICAgICAgICN0aXRsZS1kbGcub24geyBkaXNwbGF5OiBmbGV4OyB9CiAgICAgICAgI3Rp
dGxlLWRsZyAudGl0bGUtYm94IHsKICAgICAgICAgICAgd2lkdGg6IDI2MHB4OyBwYWRkaW5nOiAx
NnB4IDE2cHggMTJweDsKICAgICAgICAgICAgYmFja2dyb3VuZDogdmFyKC0tY2FyZCk7IGJvcmRl
ci1yYWRpdXM6IDEwcHg7CiAgICAgICAgICAgIGJveC1zaGFkb3c6IDAgOHB4IDI4cHggcmdiYSgw
LDAsMCwuMTgpOwogICAgICAgICAgICAtd2Via2l0LWFwcC1yZWdpb246IG5vLWRyYWc7IGFwcC1y
ZWdpb246IG5vLWRyYWc7CiAgICAgICAgfQogICAgICAgICN0aXRsZS1pbnB1dCB7CiAgICAgICAg
ICAgIHdpZHRoOiAxMDAlOyBib3gtc2l6aW5nOiBib3JkZXItYm94OyBtYXJnaW46IDhweCAwIDEy
cHg7CiAgICAgICAgICAgIGhlaWdodDogMzJweDsgcGFkZGluZzogMCAxMHB4OyBib3JkZXItcmFk
aXVzOiA2cHg7CiAgICAgICAgICAgIGJvcmRlcjogMXB4IHNvbGlkICNkNWRhZTY7IGJhY2tncm91
bmQ6ICNmZmY7IGNvbG9yOiB2YXIoLS10eHQpOwogICAgICAgICAgICBmb250LXNpemU6IDEzcHg7
IG91dGxpbmU6IG5vbmU7CiAgICAgICAgICAgIC13ZWJraXQtYXBwLXJlZ2lvbjogbm8tZHJhZzsg
YXBwLXJlZ2lvbjogbm8tZHJhZzsKICAgICAgICAgICAgdXNlci1zZWxlY3Q6IHRleHQ7CiAgICAg
ICAgfQogICAgICAgICN0aXRsZS1pbnB1dDpmb2N1cyB7IGJvcmRlci1jb2xvcjogdmFyKC0tYWNj
KTsgfQoKICAgIAogICAgICAgIC8qIHVpLWdyYXktYmctdjEgKi8KICAgICAgICA6cm9vdCB7CiAg
ICAgICAgICAgIC0tYmc6ICNlNGU3ZWUgIWltcG9ydGFudDsKICAgICAgICB9CiAgICAgICAgaHRt
bCwgYm9keSB7CiAgICAgICAgICAgIGJhY2tncm91bmQ6ICNlNGU3ZWUgIWltcG9ydGFudDsKICAg
ICAgICB9CiAgICAgICAgI2FwcCB7CiAgICAgICAgICAgIGJhY2tncm91bmQ6IGxpbmVhci1ncmFk
aWVudCgxODBkZWcsICNlOWVjZjMgMCUsICNlMGU0ZWMgMTAwJSkgIWltcG9ydGFudDsKICAgICAg
ICB9CiAgICAgICAgI2hkciB7CiAgICAgICAgICAgIGJhY2tncm91bmQ6ICNlMmU2ZWUgIWltcG9y
dGFudDsKICAgICAgICB9CiAgICAgICAgI3RhYnMgewogICAgICAgICAgICBiYWNrZ3JvdW5kOiAj
ZTJlNmVlICFpbXBvcnRhbnQ7CiAgICAgICAgfQogICAgICAgICNsaXN0LCAjZW1wdHksICNza2Vs
LCAjaGRyLWdyb3csICNzZWFyY2gtd3JhcCB7CiAgICAgICAgICAgIGJhY2tncm91bmQ6IHRyYW5z
cGFyZW50ICFpbXBvcnRhbnQ7CiAgICAgICAgfQogICAgICAgICNzZWFyY2gtYm94IHsKICAgICAg
ICAgICAgdHJhbnNmb3JtLW9yaWdpbjogcmlnaHQgY2VudGVyOwogICAgICAgICAgICBiYWNrZ3Jv
dW5kOiB0cmFuc3BhcmVudCAhaW1wb3J0YW50OwogICAgICAgIH0KICAgICAgICAuaXRtLCAubWcs
IC5tZy1yb3csIC5tZXJnZS1ncm91cCB7CiAgICAgICAgICAgIGJhY2tncm91bmQ6ICNmZmZmZmYg
IWltcG9ydGFudDsKICAgICAgICB9CiAgICAgICAgLml0bTpob3ZlciB7CiAgICAgICAgICAgIGJh
Y2tncm91bmQ6ICNmOGY5ZmMgIWltcG9ydGFudDsKICAgICAgICB9CiAgICAKICAgICAgICAvKiBz
ZWwtdGludC1ibHVlLXYxICovCiAgICAgICAgLml0bS5zZWwsCiAgICAgICAgLm1nLXJvdy5zZWws
CiAgICAgICAgLml0bS5tdWx0aSwKICAgICAgICAubWctcm93Lm11bHRpLAogICAgICAgIC5pdG0u
bXVsdGkuc2VsLAogICAgICAgIC5pdC1ncm91cC5zZWwsCiAgICAgICAgLml0LWdyb3VwLm11bHRp
IHsKICAgICAgICAgICAgYmFja2dyb3VuZDogI2U4ZWZmZiAhaW1wb3J0YW50OwogICAgICAgIH0K
ICAgICAgICAuaXRtLnNlbDpob3ZlciwKICAgICAgICAuaXRtLm11bHRpOmhvdmVyLAogICAgICAg
IC5tZy1yb3cuc2VsOmhvdmVyLAogICAgICAgIC5tZy1yb3cubXVsdGk6aG92ZXIgewogICAgICAg
ICAgICBiYWNrZ3JvdW5kOiAjZGRlNmZmICFpbXBvcnRhbnQ7CiAgICAgICAgfQogICAgCiAgICAg
ICAgLyogaG92ZXItZ3JlZW4tcmlzZS12MiAqLwogICAgICAgIC8qIGhvdmVyLWFjY2VudC1yaXNl
LXYzICovCiAgICAgICAgLml0bSB7IHBvc2l0aW9uOiByZWxhdGl2ZSAhaW1wb3J0YW50OyBvdmVy
ZmxvdzogaGlkZGVuICFpbXBvcnRhbnQ7IH0KICAgICAgICAuaXRtOjpiZWZvcmUgewogICAgICAg
ICAgICBjb250ZW50OiAiIiAhaW1wb3J0YW50OwogICAgICAgICAgICBwb3NpdGlvbjogYWJzb2x1
dGUgIWltcG9ydGFudDsKICAgICAgICAgICAgbGVmdDogMCAhaW1wb3J0YW50OyByaWdodDogMCAh
aW1wb3J0YW50OyBib3R0b206IDAgIWltcG9ydGFudDsKICAgICAgICAgICAgaGVpZ2h0OiAwICFp
bXBvcnRhbnQ7CiAgICAgICAgICAgIHBvaW50ZXItZXZlbnRzOiBub25lICFpbXBvcnRhbnQ7CiAg
ICAgICAgICAgIHotaW5kZXg6IDAgIWltcG9ydGFudDsKICAgICAgICAgICAgYm9yZGVyLXJhZGl1
czogMCAwIHZhcigtLXIsIDRweCkgdmFyKC0tciwgNHB4KSAhaW1wb3J0YW50OwogICAgICAgICAg
ICBiYWNrZ3JvdW5kOiBsaW5lYXItZ3JhZGllbnQodG8gdG9wLAogICAgICAgICAgICAgICAgcmdi
YSg5MSwgMTE1LCAyMzIsIC4zMikgMCUsCiAgICAgICAgICAgICAgICByZ2JhKDkxLCAxMTUsIDIz
MiwgLjEyKSA1NSUsCiAgICAgICAgICAgICAgICByZ2JhKDkxLCAxMTUsIDIzMiwgMCkgMTAwJSkg
IWltcG9ydGFudDsKICAgICAgICAgICAgdHJhbnNpdGlvbjogaGVpZ2h0IC4zNHMgY3ViaWMtYmV6
aWVyKC4yMiwgMSwgLjM2LCAxKSAhaW1wb3J0YW50OwogICAgICAgIH0KICAgICAgICAuaXRtOmhv
dmVyOjpiZWZvcmUgeyBoZWlnaHQ6IDMzLjMzMyUgIWltcG9ydGFudDsgfQogICAgICAgIC5pdG06
OmFmdGVyIHsKICAgICAgICAgICAgY29udGVudDogIiIgIWltcG9ydGFudDsKICAgICAgICAgICAg
cG9zaXRpb246IGFic29sdXRlICFpbXBvcnRhbnQ7CiAgICAgICAgICAgIGxlZnQ6IDAgIWltcG9y
dGFudDsgcmlnaHQ6IDAgIWltcG9ydGFudDsgYm90dG9tOiAwICFpbXBvcnRhbnQ7CiAgICAgICAg
ICAgIGhlaWdodDogMnB4ICFpbXBvcnRhbnQ7CiAgICAgICAgICAgIHBvaW50ZXItZXZlbnRzOiBu
b25lICFpbXBvcnRhbnQ7CiAgICAgICAgICAgIHotaW5kZXg6IDEgIWltcG9ydGFudDsKICAgICAg
ICAgICAgYmFja2dyb3VuZDogcmdiYSg5MSwgMTE1LCAyMzIsIC45MikgIWltcG9ydGFudDsKICAg
ICAgICAgICAgYm9yZGVyLXJhZGl1czogMXB4ICFpbXBvcnRhbnQ7CiAgICAgICAgICAgIHRyYW5z
Zm9ybTogc2NhbGVYKDApICFpbXBvcnRhbnQ7CiAgICAgICAgICAgIHRyYW5zZm9ybS1vcmlnaW46
IGNlbnRlciAhaW1wb3J0YW50OwogICAgICAgICAgICB0cmFuc2l0aW9uOiB0cmFuc2Zvcm0gLjNz
IGN1YmljLWJlemllciguMjIsIDEsIC4zNiwgMSkgIWltcG9ydGFudDsKICAgICAgICB9CiAgICAg
ICAgLml0bTpob3Zlcjo6YWZ0ZXIgewogICAgICAgICAgICB0cmFuc2Zvcm06IHNjYWxlWCgxKSAh
aW1wb3J0YW50OwogICAgICAgICAgICBiYWNrZ3JvdW5kOiByZ2JhKDkxLCAxMTUsIDIzMiwgLjk1
KSAhaW1wb3J0YW50OwogICAgICAgIH0KICAgICAgICAuaXRtID4gKiB7IHBvc2l0aW9uOiByZWxh
dGl2ZTsgei1pbmRleDogMjsgfQogICAgICAgIC8qIOWkluahhuaUueeUsSBXaW4xMSBEV00g5reh
54Gw5o+P6L6577yI55uW5ruh5ZyG6KeS77yJ77yb5q2k5aSE5Y+q6KOB5YiH5YaF5a65ICovCiAg
ICAgICAgaHRtbCwgYm9keSB7CiAgICAgICAgICAgIGJvcmRlcjogbm9uZSAhaW1wb3J0YW50Owog
ICAgICAgICAgICBvdXRsaW5lOiBub25lICFpbXBvcnRhbnQ7CiAgICAgICAgICAgIGJveC1zaGFk
b3c6IG5vbmUgIWltcG9ydGFudDsKICAgICAgICAgICAgYm9yZGVyLXJhZGl1czogOHB4ICFpbXBv
cnRhbnQ7CiAgICAgICAgICAgIG92ZXJmbG93OiBoaWRkZW4gIWltcG9ydGFudDsKICAgICAgICB9
CiAgICAgICAgI2FwcCB7CiAgICAgICAgICAgIGJvcmRlcjogbm9uZSAhaW1wb3J0YW50OwogICAg
ICAgICAgICBvdXRsaW5lOiBub25lICFpbXBvcnRhbnQ7CiAgICAgICAgICAgIGJveC1zaGFkb3c6
IG5vbmUgIWltcG9ydGFudDsKICAgICAgICAgICAgYm9yZGVyLXJhZGl1czogOHB4ICFpbXBvcnRh
bnQ7CiAgICAgICAgICAgIGJveC1zaXppbmc6IGJvcmRlci1ib3ggIWltcG9ydGFudDsKICAgICAg
ICAgICAgb3ZlcmZsb3c6IGhpZGRlbiAhaW1wb3J0YW50OwogICAgICAgIH0KICAgICAgICAuaXRt
LCAubWcsIC5tZXJnZS1ncm91cCB7CiAgICAgICAgICAgIGJvcmRlcjogbm9uZSAhaW1wb3J0YW50
OwogICAgICAgICAgICBib3JkZXItcmFkaXVzOiA0cHggIWltcG9ydGFudDsKICAgICAgICAgICAg
Ym94LXNoYWRvdzoKICAgICAgICAgICAgICAgIDAgMXB4IDJweCByZ2JhKDI0LCAzMiwgNTYsIC4w
NSksCiAgICAgICAgICAgICAgICAwIDNweCAxMHB4IHJnYmEoMjQsIDMyLCA1NiwgLjA5KSAhaW1w
b3J0YW50OwogICAgICAgIH0KICAgICAgICAuaXRtOmhvdmVyLCAubWc6aG92ZXIsIC5tZXJnZS1n
cm91cDpob3ZlciB7CiAgICAgICAgICAgIGJveC1zaGFkb3c6CiAgICAgICAgICAgICAgICAwIDJw
eCA0cHggcmdiYSgyNCwgMzIsIDU2LCAuMDcpLAogICAgICAgICAgICAgICAgMCA2cHggMTZweCBy
Z2JhKDI0LCAzMiwgNTYsIC4xMykgIWltcG9ydGFudDsKICAgICAgICB9CiAgICAgICAgLml0bS5z
ZWwsCiAgICAgICAgLm1nLXJvdy5zZWwsCiAgICAgICAgLml0bS5tdWx0aSwKICAgICAgICAubWct
cm93Lm11bHRpLAogICAgICAgIC5pdG0ubXVsdGkuc2VsLAogICAgICAgIC5pdC1ncm91cC5zZWws
CiAgICAgICAgLml0LWdyb3VwLm11bHRpIHsKICAgICAgICAgICAgYm94LXNoYWRvdzoKICAgICAg
ICAgICAgICAgIDAgMCAwIDJweCByZ2JhKDkxLCAxMTUsIDIzMiwgLjQyKSwKICAgICAgICAgICAg
ICAgIDAgMnB4IDRweCByZ2JhKDkxLCAxMTUsIDIzMiwgLjEwKSwKICAgICAgICAgICAgICAgIDAg
NnB4IDE0cHggcmdiYSg5MSwgMTE1LCAyMzIsIC4xNikgIWltcG9ydGFudDsKICAgICAgICB9CiAg
ICA8L3N0eWxlPgo8L2hlYWQ+Cjxib2R5IGRhdGEtdWktYnVpbGQ9IjIwMjYwOTE3LWYyLXRpdGxl
Ij4KPGRpdiBpZD0iYXBwIiBkYXRhLXVpLXZlcj0iMjAyNjA5MTctZjItdGl0bGUiPgogICAgPGRp
diBpZD0iaGRyIj4KICAgICAgICA8ZGl2IGlkPSJoZWFydCI+CiAgICAgICAgICAgIDxzdmcgdmll
d0JveD0iMCAwIDI0IDI0IiBmaWxsPSJub25lIiBzdHJva2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tl
LXdpZHRoPSIxLjgiCiAgICAgICAgICAgICAgICAgc3Ryb2tlLWxpbmVjYXA9InJvdW5kIiBzdHJv
a2UtbGluZWpvaW49InJvdW5kIj4KICAgICAgICAgICAgICAgIDxyZWN0IHg9IjkiIHk9IjIiIHdp
ZHRoPSI2IiBoZWlnaHQ9IjQiIHJ4PSIxIi8+CiAgICAgICAgICAgICAgICA8cGF0aCBkPSJNMTYg
NGgyYTIgMiAwIDAgMSAyIDJ2MTRhMiAyIDAgMCAxLTIgMkg2YTIgMiAwIDAgMS0yLTJWNmEyIDIg
MCAwIDEgMi0yaDIiLz4KICAgICAgICAgICAgICAgIDxwYXRoIGQ9Ik05IDEyaDZNOSAxNmg0Ii8+
CiAgICAgICAgICAgIDwvc3ZnPgogICAgICAgIDwvZGl2PgogICAgICAgIDxkaXYgaWQ9Imhkci1n
cm93Ij48L2Rpdj4KICAgICAgICA8ZGl2IGlkPSJtdWx0aS1iYXIiPgogICAgICAgICAgICA8YnV0
dG9uIGlkPSJtdWx0aS1zZWwiIHR5cGU9ImJ1dHRvbiIgdGl0bGU9IuWPlua2iOWkmumAiSI+CiAg
ICAgICAgICAgICAgICA8c3BhbiBpZD0ibXVsdGktc2VsLWxhYiI+5bey6YCJPC9zcGFuPgogICAg
ICAgICAgICAgICAgPHNwYW4gaWQ9Im11bHRpLWNudCI+MDwvc3Bhbj4KICAgICAgICAgICAgPC9i
dXR0b24+CiAgICAgICAgICAgIDxkaXYgaWQ9InBhc3RlLXNlcC13cmFwIj4KICAgICAgICAgICAg
ICAgIDxidXR0b24gaWQ9InBhc3RlLXNlcC1idG4iIHR5cGU9ImJ1dHRvbiIgdGl0bGU9IueymOi0
tOWIhumalOespu+8iOeCuemAieeUqOW5tueymOi0tO+8iSI+CiAgICAgICAgICAgICAgICAgICAg
PHNwYW4gaWQ9InBhc3RlLXNlcC1sYWJlbCI+4pCjPC9zcGFuPgogICAgICAgICAgICAgICAgPC9i
dXR0b24+CiAgICAgICAgICAgICAgICA8ZGl2IGlkPSJwYXN0ZS1zZXAtbWVudSI+PC9kaXY+CiAg
ICAgICAgICAgIDwvZGl2PgogICAgICAgIDwvZGl2PgogICAgICAgIDxidXR0b24gaWQ9ImJ0bi1s
b2NhdGUiIHR5cGU9ImJ1dHRvbiIgdGl0bGU9IuWumuS9jeWIsOS4iuasoeS9v+eUqOeahOadoeeb
riIgZGlzYWJsZWQ+CiAgICAgICAgICAgIDxzdmcgdmlld0JveD0iMCAwIDI0IDI0IiBmaWxsPSJu
b25lIiBzdHJva2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIyIgogICAgICAgICAgICAg
ICAgIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIgc3Ryb2tlLWxpbmVqb2luPSJyb3VuZCI+CiAgICAg
ICAgICAgICAgICA8Y2lyY2xlIGN4PSIxMiIgY3k9IjEyIiByPSI4Ii8+CiAgICAgICAgICAgICAg
ICA8Y2lyY2xlIGN4PSIxMiIgY3k9IjEyIiByPSIzLjUiLz4KICAgICAgICAgICAgPC9zdmc+CiAg
ICAgICAgPC9idXR0b24+CiAgICAgICAgPGRpdiBpZD0ic2VhcmNoLXdyYXAiPgogICAgICAgICAg
ICA8YnV0dG9uIGlkPSJidG4tc2VhcmNoIiB0eXBlPSJidXR0b24iIHRpdGxlPSLmkJzntKIiPgog
ICAgICAgICAgICAgICAgPHN2ZyB2aWV3Qm94PSIwIDAgMjQgMjQiIGZpbGw9Im5vbmUiIHN0cm9r
ZT0iY3VycmVudENvbG9yIiBzdHJva2Utd2lkdGg9IjIiCiAgICAgICAgICAgICAgICAgICAgIHN0
cm9rZS1saW5lY2FwPSJyb3VuZCIgc3Ryb2tlLWxpbmVqb2luPSJyb3VuZCI+CiAgICAgICAgICAg
ICAgICAgICAgPGNpcmNsZSBjeD0iMTEiIGN5PSIxMSIgcj0iNyIvPgogICAgICAgICAgICAgICAg
ICAgIDxwYXRoIGQ9Ik0yMCAyMGwtMy41LTMuNSIvPgogICAgICAgICAgICAgICAgPC9zdmc+CiAg
ICAgICAgICAgIDwvYnV0dG9uPgogICAgICAgICAgICA8ZGl2IGlkPSJzZWFyY2gtYm94Ij4KICAg
ICAgICAgICAgICAgIDxidXR0b24gaWQ9ImJ0bi10b2RheSIgdHlwZT0iYnV0dG9uIj7lvZPlpKk8
L2J1dHRvbj4KICAgICAgICAgICAgICAgIDxpbnB1dCBpZD0ic2VhcmNoIiB0eXBlPSJ0ZXh0IiBw
bGFjZWhvbGRlcj0i5pCc57Si4oCmIOepuuagvOWIhuivjemhu+WQjOaXtuWMheWQqyDCtyBhfGIg
5YiG5q61IiBhdXRvY29tcGxldGU9Im9mZiIgc3BlbGxjaGVjaz0iZmFsc2UiPgogICAgICAgICAg
ICAgICAgPGJ1dHRvbiBpZD0ic2VhcmNoLWNsciIgdHlwZT0iYnV0dG9uIj7inJU8L2J1dHRvbj4K
ICAgICAgICAgICAgPC9kaXY+CiAgICAgICAgPC9kaXY+CiAgICAgICAgPGJ1dHRvbiBpZD0iYnRu
LXBpbiIgdHlwZT0iYnV0dG9uIiB0aXRsZT0i6ZKJ5Zyo5bGP5bmV5LiKIj4KICAgICAgICAgICAg
PHN2ZyB2aWV3Qm94PSIwIDAgMjQgMjQiIGZpbGw9Im5vbmUiIHN0cm9rZT0iY3VycmVudENvbG9y
IiBzdHJva2Utd2lkdGg9IjIiCiAgICAgICAgICAgICAgICAgc3Ryb2tlLWxpbmVqb2luPSJyb3Vu
ZCIgc3Ryb2tlLWxpbmVjYXA9InJvdW5kIj4KICAgICAgICAgICAgICAgIDxsaW5lIHgxPSIxMiIg
eTE9IjE3IiB4Mj0iMTIiIHkyPSIyMiIvPgogICAgICAgICAgICAgICAgPHBhdGggZD0iTTUgMTdo
MTR2LTEuNzZhMiAyIDAgMCAwLTEuMTEtMS43OWwtMS43OC0uOUEyIDIgMCAwIDEgMTUgMTAuNzZW
NmgxYTIgMiAwIDAgMCAwLTRIOGEyIDIgMCAwIDAgMCA0aDF2NC43NmEyIDIgMCAwIDEtMS4xMSAx
Ljc5bC0xLjc4LjlBMiAyIDAgMCAwIDUgMTUuMjRaIi8+CiAgICAgICAgICAgIDwvc3ZnPgogICAg
ICAgIDwvYnV0dG9uPgogICAgPC9kaXY+CgogICAgPGRpdiBpZD0idGFicyI+CiAgICAgICAgPGRp
diBpZD0idGFiLWluayIgYXJpYS1oaWRkZW49InRydWUiPjwvZGl2PgogICAgICAgIDxkaXYgY2xh
c3M9InRhYiBvbiIgZGF0YS10YWI9ImFsbCI+5YWo6YOoPC9kaXY+CiAgICAgICAgPGRpdiBjbGFz
cz0idGFiIiBkYXRhLXRhYj0idGV4dCI+5paH5pysPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0i
dGFiIiBkYXRhLXRhYj0iaW1hZ2UiPuWbvuWDjzwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9InRh
YiIgZGF0YS10YWI9ImZpbGUiPuaWh+S7tjwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9InRhYiIg
ZGF0YS10YWI9InJlY2VudCI+5pyA6L+RPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0idGFiIiBk
YXRhLXRhYj0icGlubmVkIj7mlLbol48gPHNwYW4gaWQ9InBpbi1kb3QiIHRpdGxlPSLmnInmlrDm
lLbol48iPjwvc3Bhbj48L2Rpdj4KICAgICAgICA8ZGl2IGlkPSJ0YWItYWN0aW9ucyI+CiAgICAg
ICAgICAgIDxzcGFuIGlkPSJiYXItdHh0Ij4wPC9zcGFuPgogICAgICAgICAgICA8YnV0dG9uIGlk
PSJidG4tY2xyIiB0eXBlPSJidXR0b24iIHRpdGxlPSLmuIXnqbrljoblj7IiPgogICAgICAgICAg
ICAgICAgPHN2ZyB2aWV3Qm94PSIwIDAgMjQgMjQiIGZpbGw9Im5vbmUiIHN0cm9rZT0iY3VycmVu
dENvbG9yIiBzdHJva2Utd2lkdGg9IjIiCiAgICAgICAgICAgICAgICAgICAgIHN0cm9rZS1saW5l
Y2FwPSJyb3VuZCIgc3Ryb2tlLWxpbmVqb2luPSJyb3VuZCI+CiAgICAgICAgICAgICAgICAgICAg
PHBvbHlsaW5lIHBvaW50cz0iMyA2IDUgNiAyMSA2Ii8+CiAgICAgICAgICAgICAgICAgICAgPHBh
dGggZD0iTTE5IDZsLTEgMTRhMiAyIDAgMCAxLTIgMkg4YTIgMiAwIDAgMS0yLTJMNSA2Ii8+CiAg
ICAgICAgICAgICAgICAgICAgPHBhdGggZD0iTTEwIDExdjZNMTQgMTF2Nk05IDZWNGg2djIiLz4K
ICAgICAgICAgICAgICAgIDwvc3ZnPgogICAgICAgICAgICA8L2J1dHRvbj4KICAgICAgICA8L2Rp
dj4KICAgIDwvZGl2PgoKICAgIDxkaXYgaWQ9Imxpc3QiPgogICAgICAgIDxkaXYgaWQ9InNrZWwi
IGFyaWEtaGlkZGVuPSJ0cnVlIj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0ic2stcm93Ij48ZGl2
IGNsYXNzPSJzay1pY28iPjwvZGl2PjxkaXYgY2xhc3M9InNrLWJvZHkiPjxkaXYgY2xhc3M9InNr
LWxpbmUgbWlkIj48L2Rpdj48ZGl2IGNsYXNzPSJzay1saW5lIHNob3J0Ij48L2Rpdj48L2Rpdj48
L2Rpdj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0ic2stcm93Ij48ZGl2IGNsYXNzPSJzay1pY28i
PjwvZGl2PjxkaXYgY2xhc3M9InNrLWJvZHkiPjxkaXYgY2xhc3M9InNrLWxpbmUiPjwvZGl2Pjxk
aXYgY2xhc3M9InNrLWxpbmUgbWlkIj48L2Rpdj48L2Rpdj48L2Rpdj4KICAgICAgICAgICAgPGRp
diBjbGFzcz0ic2stcm93Ij48ZGl2IGNsYXNzPSJzay1pY28iPjwvZGl2PjxkaXYgY2xhc3M9InNr
LWJvZHkiPjxkaXYgY2xhc3M9InNrLWxpbmUgbWlkIj48L2Rpdj48ZGl2IGNsYXNzPSJzay1saW5l
IHNob3J0Ij48L2Rpdj48L2Rpdj48L2Rpdj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0ic2stcm93
Ij48ZGl2IGNsYXNzPSJzay1pY28iPjwvZGl2PjxkaXYgY2xhc3M9InNrLWJvZHkiPjxkaXYgY2xh
c3M9InNrLWxpbmUiPjwvZGl2PjxkaXYgY2xhc3M9InNrLWxpbmUgbWlkIj48L2Rpdj48L2Rpdj48
L2Rpdj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0ic2stcm93Ij48ZGl2IGNsYXNzPSJzay1pY28i
PjwvZGl2PjxkaXYgY2xhc3M9InNrLWJvZHkiPjxkaXYgY2xhc3M9InNrLWxpbmUgbWlkIj48L2Rp
dj48ZGl2IGNsYXNzPSJzay1saW5lIHNob3J0Ij48L2Rpdj48L2Rpdj48L2Rpdj4KICAgICAgICAg
ICAgPGRpdiBjbGFzcz0ic2stcm93Ij48ZGl2IGNsYXNzPSJzay1pY28iPjwvZGl2PjxkaXYgY2xh
c3M9InNrLWJvZHkiPjxkaXYgY2xhc3M9InNrLWxpbmUiPjwvZGl2PjxkaXYgY2xhc3M9InNrLWxp
bmUgc2hvcnQiPjwvZGl2PjwvZGl2PjwvZGl2PgogICAgICAgIDwvZGl2PgogICAgICAgIDxkaXYg
aWQ9ImVtcHR5Ij4KICAgICAgICAgICAgPGRpdiBjbGFzcz0iZS10eHQiIGlkPSJlbXB0eS10eHQi
PuaaguaXoOiusOW9le+8jOWkjeWItuWQjuiHquWKqOWHuueOsDwvZGl2PgogICAgICAgIDwvZGl2
PgogICAgPC9kaXY+CiAgICA8YnV0dG9uIGlkPSJidG4tdG9wIiB0eXBlPSJidXR0b24iIHRpdGxl
PSLlm57liLDpobbpg6giIGFyaWEtbGFiZWw9IuWbnuWIsOmhtumDqCI+CiAgICAgICAgPHN2ZyB2
aWV3Qm94PSIwIDAgMjQgMjQiIGZpbGw9Im5vbmUiIHN0cm9rZT0iY3VycmVudENvbG9yIiBzdHJv
a2Utd2lkdGg9IjIuMiIKICAgICAgICAgICAgIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIgc3Ryb2tl
LWxpbmVqb2luPSJyb3VuZCI+CiAgICAgICAgICAgIDxwYXRoIGQ9Ik0xMiAxOVY1Ii8+CiAgICAg
ICAgICAgIDxwYXRoIGQ9Ik01IDEybDctNyA3IDciLz4KICAgICAgICA8L3N2Zz4KICAgIDwvYnV0
dG9uPgo8L2Rpdj4KCjxkaXYgaWQ9ImN0eCI+CiAgICA8ZGl2IGNsYXNzPSJjLWl0ZW0iIGlkPSJj
LWNvcHkiPjxzcGFuIGNsYXNzPSJjLWljbyI+4o6YPC9zcGFuPuWkjeWItjwvZGl2PgogICAgPGRp
diBjbGFzcz0iYy1pdGVtIiBpZD0iYy1wYXN0ZSI+PHNwYW4gY2xhc3M9ImMtaWNvIj7ij448L3Nw
YW4+57KY6LS0PC9kaXY+CiAgICA8ZGl2IGNsYXNzPSJjLXNlcCIgaWQ9ImMtZGF0YS1zZXAiIHN0
eWxlPSJkaXNwbGF5Om5vbmUiPjwvZGl2PgogICAgPGRpdiBjbGFzcz0iYy1zdWJ3cmFwIiBpZD0i
Yy1kYXRhLXdyYXAiIHN0eWxlPSJkaXNwbGF5Om5vbmUiPgogICAgICAgIDxkaXYgY2xhc3M9ImMt
aXRlbSIgaWQ9ImMtZGF0YSI+PHNwYW4gY2xhc3M9ImMtaWNvIj7Oozwvc3Bhbj7mlbDmja7lpITn
kIY8c3BhbiBjbGFzcz0iYy1jYXJldCI+4oC6PC9zcGFuPjwvZGl2PgogICAgICAgIDxkaXYgY2xh
c3M9ImMtc3ViIiBpZD0iYy1kYXRhLXN1YiI+CiAgICAgICAgICAgIDxkaXYgY2xhc3M9ImMtaXRl
bSIgaWQ9ImMtZGF0YS1icmFjZSIgdGl0bGU9InthLGJ9IC8gYSxiIOKGkiBTUUwiPgogICAgICAg
ICAgICAgICAgPHNwYW4gY2xhc3M9ImMtbnVtIj4xPC9zcGFuPjxzcGFuIGNsYXNzPSJjLWZyb20i
PnthLGJ9PC9zcGFuPjxzcGFuIGNsYXNzPSJjLWFycm93Ij7ihpI8L3NwYW4+PHNwYW4gY2xhc3M9
ImMtdG8iPignYScsJ2InKTwvc3Bhbj4KICAgICAgICAgICAgPC9kaXY+CiAgICAgICAgICAgIDxk
aXYgY2xhc3M9ImMtaXRlbSIgaWQ9ImMtZGF0YS1saW5lcyIgdGl0bGU9IuaNouihjOWIhumalCDi
hpIgU1FMIj4KICAgICAgICAgICAgICAgIDxzcGFuIGNsYXNzPSJjLW51bSI+Mjwvc3Bhbj48c3Bh
biBjbGFzcz0iYy1mcm9tIj5hIFxuIGI8L3NwYW4+PHNwYW4gY2xhc3M9ImMtYXJyb3ciPuKGkjwv
c3Bhbj48c3BhbiBjbGFzcz0iYy10byI+KCdhJywnYicpPC9zcGFuPgogICAgICAgICAgICA8L2Rp
dj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0iYy1pdGVtIiBpZD0iYy1kYXRhLWpzb24iIHRpdGxl
PSJKU09OIOWOu+i9rOS5ie+8mlwmcXVvdDsg4oaSICZxdW90OyI+CiAgICAgICAgICAgICAgICA8
c3BhbiBjbGFzcz0iYy1udW0iPjM8L3NwYW4+PHNwYW4gY2xhc3M9ImMtZnJvbSI+anNvbiAgJnF1
b3Q7XCZxdW90Ozwvc3Bhbj48c3BhbiBjbGFzcz0iYy1hcnJvdyI+4oaSPC9zcGFuPjxzcGFuIGNs
YXNzPSJjLXRvIj4mcXVvdDsgJnF1b3Q7PC9zcGFuPgogICAgICAgICAgICA8L2Rpdj4KICAgICAg
ICA8L2Rpdj4KICAgIDwvZGl2PgogICAgPGRpdiBjbGFzcz0iYy1zZXAiPjwvZGl2PgogICAgPGRp
diBjbGFzcz0iYy1pdGVtIiBpZD0iYy1waW4iPjxzcGFuIGNsYXNzPSJjLWljbyI+4piFPC9zcGFu
PuaUtuiXjzwvZGl2PgogICAgPGRpdiBjbGFzcz0iYy1pdGVtIiBpZD0iYy10aXRsZSIgc3R5bGU9
ImRpc3BsYXk6bm9uZSI+PHNwYW4gY2xhc3M9ImMtaWNvIj7inI48L3NwYW4+6K6+572u5qCH6aKY
PC9kaXY+CiAgICA8ZGl2IGNsYXNzPSJjLWl0ZW0iIGlkPSJjLW1lcmdlIiBzdHlsZT0iZGlzcGxh
eTpub25lIj48c3BhbiBjbGFzcz0iYy1pY28iPuKniTwvc3Bhbj7lkIjlubY8L2Rpdj4KICAgIDxk
aXYgY2xhc3M9ImMtaXRlbSIgaWQ9ImMtdW5tZXJnZSIgc3R5bGU9ImRpc3BsYXk6bm9uZSI+PHNw
YW4gY2xhc3M9ImMtaWNvIj7ih4Q8L3NwYW4+5Y+W5raI5ZCI5bm2PC9kaXY+CiAgICA8ZGl2IGNs
YXNzPSJjLWl0ZW0iIGlkPSJjLXRvcCI+PHNwYW4gY2xhc3M9ImMtaWNvIj7ihpE8L3NwYW4+56e7
5Yiw6aG26YOoPC9kaXY+CiAgICA8ZGl2IGNsYXNzPSJjLWl0ZW0iIGlkPSJjLWNsZWFyLXBhc3Rl
ZCIgc3R5bGU9ImRpc3BsYXk6bm9uZSI+PHNwYW4gY2xhc3M9ImMtaWNvIj7inJM8L3NwYW4+5riF
6Zmk54q25oCBPC9kaXY+CiAgICA8ZGl2IGNsYXNzPSJjLWl0ZW0iIGlkPSJjLXF1ZXVlLWZyb20i
IHN0eWxlPSJkaXNwbGF5Om5vbmUiPjxzcGFuIGNsYXNzPSJjLWljbyI+4oa7PC9zcGFuPuS7juat
pOWkhOW8gOWni+mYn+WIlzwvZGl2PgogICAgPGRpdiBjbGFzcz0iYy1zZXAiPjwvZGl2PgogICAg
PGRpdiBjbGFzcz0iYy1pdGVtIGRhbmdlciIgaWQ9ImMtZGVsIj48c3BhbiBjbGFzcz0iYy1pY28i
PuKclTwvc3Bhbj7liKDpmaQ8L2Rpdj4KPC9kaXY+Cgo8ZGl2IGlkPSJjbHItZGxnIj4KICAgIDxk
aXYgY2xhc3M9ImNsci1ib3giIHJvbGU9ImRpYWxvZyIgYXJpYS1tb2RhbD0idHJ1ZSI+CiAgICAg
ICAgPGRpdiBjbGFzcz0iY2xyLXRpdGxlIiBpZD0iY2xyLXRpdGxlIj7noa7orqTmuIXnqbrvvJ88
L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJjbHItZGVzYyIgaWQ9ImNsci1kZXNjIj7pu5jorqTk
u4XmuIXnqbrlvZPlpKnlhoXlrrnjgII8L2Rpdj4KICAgICAgICA8bGFiZWwgY2xhc3M9ImNsci1j
aGVjayIgZm9yPSJjbHItYWxsIj4KICAgICAgICAgICAgPGlucHV0IHR5cGU9ImNoZWNrYm94IiBp
ZD0iY2xyLWFsbCI+CiAgICAgICAgICAgIDxzcGFuPua4heepuuaJgOaciTwvc3Bhbj4KICAgICAg
ICA8L2xhYmVsPgogICAgICAgIDxkaXYgY2xhc3M9ImNsci1idG5zIj4KICAgICAgICAgICAgPGJ1
dHRvbiB0eXBlPSJidXR0b24iIGlkPSJjbHItY2FuY2VsIj7lj5bmtog8L2J1dHRvbj4KICAgICAg
ICAgICAgPGJ1dHRvbiB0eXBlPSJidXR0b24iIGlkPSJjbHItb2siPua4heepujwvYnV0dG9uPgog
ICAgICAgIDwvZGl2PgogICAgPC9kaXY+CjwvZGl2PgoKPGRpdiBpZD0idGl0bGUtZGxnIj4KICAg
IDxkaXYgY2xhc3M9InRpdGxlLWJveCIgcm9sZT0iZGlhbG9nIiBhcmlhLW1vZGFsPSJ0cnVlIj4K
ICAgICAgICA8ZGl2IGNsYXNzPSJjbHItdGl0bGUiPuiuvue9ruagh+mimDwvZGl2PgogICAgICAg
IDxkaXYgY2xhc3M9ImNsci1kZXNjIj7moIfpopjlj6/ooqvmkJzntKLmib7liLDvvIzku4XnlKjk
uo7mlLbol4/mlbTnkIbjgII8L2Rpdj4KICAgICAgICA8aW5wdXQgaWQ9InRpdGxlLWlucHV0IiB0
eXBlPSJ0ZXh0IiBtYXhsZW5ndGg9IjgwIiBwbGFjZWhvbGRlcj0i57uZ6L+Z5p2h5pS26JeP6LW3
5Liq5ZCN5a2X4oCmIiBhdXRvY29tcGxldGU9Im9mZiIgc3BlbGxjaGVjaz0iZmFsc2UiPgogICAg
ICAgIDxkaXYgY2xhc3M9ImNsci1idG5zIj4KICAgICAgICAgICAgPGJ1dHRvbiB0eXBlPSJidXR0
b24iIGlkPSJ0aXRsZS1jYW5jZWwiPuWPlua2iDwvYnV0dG9uPgogICAgICAgICAgICA8YnV0dG9u
IHR5cGU9ImJ1dHRvbiIgaWQ9InRpdGxlLW9rIj7kv53lrZg8L2J1dHRvbj4KICAgICAgICA8L2Rp
dj4KICAgIDwvZGl2Pgo8L2Rpdj4KPGRpdiBpZD0icGF0aC10aXAiIGFyaWEtaGlkZGVuPSJ0cnVl
Ij48L2Rpdj4KCjxzY3JpcHQ+Ci8qIOemgeatoiBDdHJsK+a7mui9rue8qeaUvu+8iFdlYlZpZXcg
6K6+572uICsg6aG16Z2i5YWc5bqV77yJICovCihmdW5jdGlvbigpewogIGNvbnN0IGJsb2NrWm9v
bSA9IGUgPT4gewogICAgaWYgKGUuY3RybEtleSB8fCBlLm1ldGFLZXkpIHsKICAgICAgZS5wcmV2
ZW50RGVmYXVsdCgpOwogICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgfQogIH07CiAgd2lu
ZG93LmFkZEV2ZW50TGlzdGVuZXIoJ3doZWVsJywgYmxvY2tab29tLCB7IHBhc3NpdmU6IGZhbHNl
LCBjYXB0dXJlOiB0cnVlIH0pOwogIHdpbmRvdy5hZGRFdmVudExpc3RlbmVyKCdnZXN0dXJlc3Rh
cnQnLCBlID0+IGUucHJldmVudERlZmF1bHQoKSwgeyBwYXNzaXZlOiBmYWxzZSwgY2FwdHVyZTog
dHJ1ZSB9KTsKICBkb2N1bWVudC5hZGRFdmVudExpc3RlbmVyKCdrZXlkb3duJywgZSA9PiB7CiAg
ICBpZiAoIShlLmN0cmxLZXkgfHwgZS5tZXRhS2V5KSkgcmV0dXJuOwogICAgaWYgKGUua2V5ID09
PSAnKycgfHwgZS5rZXkgPT09ICctJyB8fCBlLmtleSA9PT0gJz0nIHx8IGUua2V5ID09PSAnXycK
ICAgICAgICB8fCBlLmNvZGUgPT09ICdOdW1wYWRBZGQnIHx8IGUuY29kZSA9PT0gJ051bXBhZFN1
YnRyYWN0JwogICAgICAgIHx8IGUua2V5ID09PSAnMCcpIHsKICAgICAgLy8gYWxsb3cgbm90aGlu
ZyBmb3Igem9vbTsgQ3RybCswIC8gwrEKICAgICAgaWYgKGUua2V5ID09PSAnMCcgfHwgZS5rZXkg
PT09ICcrJyB8fCBlLmtleSA9PT0gJy0nIHx8IGUua2V5ID09PSAnPScgfHwgZS5rZXkgPT09ICdf
JwogICAgICAgICAgfHwgZS5jb2RlID09PSAnTnVtcGFkQWRkJyB8fCBlLmNvZGUgPT09ICdOdW1w
YWRTdWJ0cmFjdCcpIHsKICAgICAgICBlLnByZXZlbnREZWZhdWx0KCk7CiAgICAgIH0KICAgIH0K
ICB9LCB0cnVlKTsKfSkoKTsKPC9zY3JpcHQ+CjxzY3JpcHQ+Ci8qIHNrZWwtZmFpbHNhZmU6IG9u
bHkgaWYgbWFpbiBVSSBzY3JpcHQgbmV2ZXIgYm9vdGVkIOKAlG5ldmVyIGludmVudCBlbXB0eS1z
dGF0ZSAqLwooZnVuY3Rpb24oKXsKICBzZXRUaW1lb3V0KCgpID0+IHsKICAgIHRyeSB7CiAgICAg
IGlmICh3aW5kb3cuX191aUJvb3RlZCkgcmV0dXJuOwogICAgICB2YXIgYXBwID0gZG9jdW1lbnQu
Z2V0RWxlbWVudEJ5SWQoJ2FwcCcpOwogICAgICBpZiAoYXBwKSBhcHAuY2xhc3NMaXN0LnJlbW92
ZSgnYm9vdC1sb2FkaW5nJyk7CiAgICAgIHZhciBzID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQo
J3NrZWwnKTsKICAgICAgaWYgKHMpIHMuY2xhc3NMaXN0LnJlbW92ZSgnb24nKTsKICAgIH0gY2F0
Y2ggKGVycikge30KICB9LCAzMDAwKTsKfSkoKTsKPC9zY3JpcHQ+CjxzY3JpcHQ+CiAgICBsZXQg
YWxsQ2xpcHMgPSBbXSwgY3VyVGFiID0gJ2FsbCcsIHF1ZXJ5ID0gJycsIGN0eENsaXAgPSBudWxs
LCBzZWxlY3RlZElkID0gMCwgcGlubmVkVUkgPSBmYWxzZTsKICAgIGNvbnN0IFRBQl9PUkRFUiA9
IFsnYWxsJywgJ3RleHQnLCAnaW1hZ2UnLCAnZmlsZScsICdyZWNlbnQnLCAncGlubmVkJ107CiAg
ICBjb25zdCB2aWV3TWVtID0gbmV3IE1hcCgpOwogICAgZnVuY3Rpb24gdmlld01lbUtleSh0YWIs
IHEsIHRvZGF5KSB7CiAgICAgICAgcmV0dXJuIFN0cmluZyh0YWIgfHwgJ2FsbCcpICsgJ1x0JyAr
IFN0cmluZyhxIHx8ICcnKSArICdcdCcgKyAodG9kYXkgPyAnMScgOiAnMCcpOwogICAgfQogICAg
bGV0IHRhYlN3aXRjaEFuaW1EaXIgPSAwOwogICAgbGV0IG11bHRpSWRzID0gW107CiAgICBsZXQg
dG9kYXlPbmx5ID0gZmFsc2U7CiAgICBsZXQgZGlza1RvdGFsID0gMDsKICAgIGxldCBsb2FkaW5n
TW9yZSA9IGZhbHNlOwogICAgLy8gRG9uJ3Qgc2hvdyBza2VsZXRvbiBpbW1lZGlhdGVseSDigJRv
bmx5IGFmdGVyIFNLRUxfREVMQVlfTVMgaWYgZGF0YSBzdGlsbCBtaXNzaW5nCiAgICBsZXQgYm9v
dExvYWRpbmcgPSBmYWxzZTsKICAgIGxldCB3YWl0aW5nRGF0YSA9IGZhbHNlOwogICAgbGV0IGhv
c3RQdXNoZWRPbmNlID0gZmFsc2U7IC8vIG9ubHkgdGhlbiBtYXkgc2hvd+OAjOaaguaXoOiusOW9
leOAjQogICAgbGV0IHNhd05vbkVtcHR5ID0gZmFsc2U7ICAgIC8vIGlnbm9yZSBib290c3RyYXAg
ZW1wdHkgcHVzaGVzIGJlZm9yZSBmaXJzdCByZWFsIGxpc3QKICAgIGxldCBwaW5uZWRUb3RhbCA9
IDA7ICAgICAgICAvLyBhdXRob3JpdGF0aXZlIOaUtuiXjyBjb3VudCBmcm9tIEFISwogICAgbGV0
IHVuc2VlbkZhdklkcyA9IG5ldyBTZXQoKTsKICAgIHRyeSB7CiAgICAgICAgY29uc3QgcmF3ID0g
bG9jYWxTdG9yYWdlLmdldEl0ZW0oJ2NsaXBfdW5zZWVuX2ZhdicpOwogICAgICAgIGlmIChyYXcp
IEpTT04ucGFyc2UocmF3KS5mb3JFYWNoKGlkID0+IHsgaWQgPSAraWQ7IGlmIChpZCkgdW5zZWVu
RmF2SWRzLmFkZChpZCk7IH0pOwogICAgfSBjYXRjaCB7fQogICAgZnVuY3Rpb24gc2F2ZVVuc2Vl
bkZhdigpIHsKICAgICAgICB0cnkgeyBsb2NhbFN0b3JhZ2Uuc2V0SXRlbSgnY2xpcF91bnNlZW5f
ZmF2JywgSlNPTi5zdHJpbmdpZnkoWy4uLnVuc2VlbkZhdklkc10pKTsgfSBjYXRjaCB7fQogICAg
fQogICAgZnVuY3Rpb24gdXBkYXRlUGluRG90KCkgewogICAgICAgIGNvbnN0IGVsID0gZG9jdW1l
bnQuZ2V0RWxlbWVudEJ5SWQoJ3Bpbi1kb3QnKTsKICAgICAgICBpZiAoIWVsKSByZXR1cm47CiAg
ICAgICAgZWwuY2xhc3NMaXN0LnRvZ2dsZSgnb24nLCB1bnNlZW5GYXZJZHMuc2l6ZSA+IDApOwog
ICAgfQogICAgZnVuY3Rpb24gbWFya0ZhdlVuc2VlbihpZCkgewogICAgICAgIGlkID0gK2lkOwog
ICAgICAgIGlmICghaWQpIHJldHVybjsKICAgICAgICB1bnNlZW5GYXZJZHMuYWRkKGlkKTsKICAg
ICAgICBzYXZlVW5zZWVuRmF2KCk7CiAgICAgICAgdXBkYXRlUGluRG90KCk7CiAgICB9CiAgICBm
dW5jdGlvbiBjbGVhckZhdlVuc2VlbigpIHsKICAgICAgICBpZiAoIXVuc2VlbkZhdklkcy5zaXpl
KSB7CiAgICAgICAgICAgIHVwZGF0ZVBpbkRvdCgpOwogICAgICAgICAgICByZXR1cm47CiAgICAg
ICAgfQogICAgICAgIHVuc2VlbkZhdklkcy5jbGVhcigpOwogICAgICAgIHNhdmVVbnNlZW5GYXYo
KTsKICAgICAgICB1cGRhdGVQaW5Eb3QoKTsKICAgIH0KICAgIGNvbnN0IFNLRUxfREVMQVlfTVMg
PSA2MDsKICAgIHdpbmRvdy5fX2RhdGFSZWFkeSA9IGZhbHNlOwogICAgd2luZG93Ll9fdWlCb290
ZWQgPSB0cnVlOwogICAgLy8gT3BlbiBwYW5lbCB3aXRob3V0IHBhc3Rpbmcg4oaSIGFsd2F5cyBs
YW5kIG9uIGZpcnN0IGl0ZW0gKGFmdGVyIGRhdGEgYXJyaXZlcykKICAgIGxldCBzZWxlY3RGaXJz
dE9uU2hvdyA9IGZhbHNlOwogICAgbGV0IGxhc3RQYXN0ZUlkID0gMDsKICAgIGxldCBsYXN0UGFz
dGVUYWIgPSAnYWxsJzsKICAgIGxldCBsb2NhdGVBY3RpdmUgPSBmYWxzZTsKICAgIHRyeSB7IGxh
c3RQYXN0ZUlkID0gK2xvY2FsU3RvcmFnZS5nZXRJdGVtKCdjbGlwTGFzdFBhc3RlSWQnKSB8fCAw
OyB9IGNhdGNoIHt9CiAgICB0cnkgewogICAgICAgIGNvbnN0IHQgPSBsb2NhbFN0b3JhZ2UuZ2V0
SXRlbSgnY2xpcExhc3RQYXN0ZVRhYicpIHx8ICdhbGwnOwogICAgICAgIGxhc3RQYXN0ZVRhYiA9
IFsnYWxsJywndGV4dCcsJ2ltYWdlJywnZmlsZScsJ3Bpbm5lZCddLmluY2x1ZGVzKHQpID8gdCA6
ICdhbGwnOwogICAgfSBjYXRjaCB7fQogICAgLy8gUHJlZmVyIHNhbWUtb3JpZ2luIHVuZGVyIGNs
aXB1aS5hcHAgKEFQUF9IT1NUIOKGkiBDTElQX1YxX0RJUi9jbGlwc19zdG9yZSkuCiAgICAvLyDl
i7/nlKggKi5sb2NhbO+8muezu+e7nyBtRE5TIOS8muWNoSAy4oCTM3PjgIJjbGlwcy5zdG9yZSDk
u4XkvZwgZmFsbGJhY2vjgIIKICAgIGNvbnN0IFNUT1JFX0JBU0UgPSAobG9jYXRpb24ub3JpZ2lu
ICYmIGxvY2F0aW9uLm9yaWdpbi5pbmRleE9mKCdodHRwczovLycpID09PSAwKQogICAgICAgID8g
KGxvY2F0aW9uLm9yaWdpbi5yZXBsYWNlKC9cLyQvLCAnJykgKyAnL2NsaXBzX3N0b3JlLycpCiAg
ICAgICAgOiAnaHR0cHM6Ly9jbGlwdWkuYXBwL2NsaXBzX3N0b3JlLyc7CiAgICBjb25zdCBTVE9S
RV9CQVNFX0ZBTExCQUNLID0gJ2h0dHBzOi8vY2xpcHMuc3RvcmUvJzsKICAgIGZ1bmN0aW9uIG1l
dGFDZW50ZXJIdG1sKGV4cGFuZElubmVyKSB7CiAgICAgICAgaWYgKGV4cGFuZElubmVyID09IG51
bGwgfHwgZXhwYW5kSW5uZXIgPT09IGZhbHNlKQogICAgICAgICAgICByZXR1cm4gYDxzcGFuIGNs
YXNzPSJpLW1ldGEtY2VudGVyIj48L3NwYW4+YDsKICAgICAgICByZXR1cm4gYDxzcGFuIGNsYXNz
PSJpLW1ldGEtY2VudGVyIj48YnV0dG9uIGNsYXNzPSJpLWV4cGFuZC1idG4ke2V4cGFuZElubmVy
Lm9uID8gJyBvbicgOiAnJ30iIHR5cGU9ImJ1dHRvbiIgdGl0bGU9IuWxleW8gC/mlLbotbciPiR7
ZXhwYW5kSW5uZXIuaHRtbH08L2J1dHRvbj48L3NwYW4+YDsKICAgIH0KCiAgICBmdW5jdGlvbiBy
ZW1lbWJlckxhc3RQYXN0ZShpZCkgewogICAgICAgIGxhc3RQYXN0ZUlkID0gK2lkIHx8IDA7CiAg
ICAgICAgbGFzdFBhc3RlVGFiID0gY3VyVGFiIHx8ICdhbGwnOwogICAgICAgIHRyeSB7CiAgICAg
ICAgICAgIGxvY2FsU3RvcmFnZS5zZXRJdGVtKCdjbGlwTGFzdFBhc3RlSWQnLCBTdHJpbmcobGFz
dFBhc3RlSWQpKTsKICAgICAgICAgICAgbG9jYWxTdG9yYWdlLnNldEl0ZW0oJ2NsaXBMYXN0UGFz
dGVUYWInLCBsYXN0UGFzdGVUYWIpOwogICAgICAgIH0gY2F0Y2gge30KICAgICAgICB1cGRhdGVM
b2NhdGVCdG4oKTsKICAgIH0KICAgIGZ1bmN0aW9uIHVwZGF0ZUxvY2F0ZUJ0bigpIHsKICAgICAg
ICBjb25zdCBidG4gPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYnRuLWxvY2F0ZScpOwogICAg
ICAgIGlmICghYnRuKSByZXR1cm47CiAgICAgICAgYnRuLmRpc2FibGVkID0gIWxhc3RQYXN0ZUlk
OwogICAgICAgIGJ0bi5jbGFzc0xpc3QudG9nZ2xlKCdoYXMtdGFyZ2V0JywgISFsYXN0UGFzdGVJ
ZCk7CiAgICAgICAgYnRuLmNsYXNzTGlzdC50b2dnbGUoJ29uJywgbG9jYXRlQWN0aXZlICYmICEh
bGFzdFBhc3RlSWQpOwogICAgICAgIGJ0bi50aXRsZSA9ICFsYXN0UGFzdGVJZAogICAgICAgICAg
ICA/ICfmmoLml6DkuIrmrKHkvb/nlKjkvY3nva4nCiAgICAgICAgICAgIDogKGxvY2F0ZUFjdGl2
ZSA/ICflj5bmtojlrprkvY3vvIzlm57liLDnrKzkuIDmnaEnIDogJ+WumuS9jeWIsOS4iuasoeS9
v+eUqOeahOadoeebricpOwogICAgfQogICAgZnVuY3Rpb24gc2VsZWN0Rmlyc3RJdGVtKCkgewog
ICAgICAgIGxvY2F0ZUFjdGl2ZSA9IGZhbHNlOwogICAgICAgIHdpbmRvdy5fX3BlbmRpbmdKdW1w
SWQgPSAwOwogICAgICAgIHdpbmRvdy5fX2p1bXBMb2FkVHJpZXMgPSAwOwogICAgICAgIHNlbGVj
dEZpcnN0T25TaG93ID0gZmFsc2U7CiAgICAgICAgY29uc3QgdmlzID0gdmlzaWJsZUxpc3QoKTsK
ICAgICAgICBpZiAoIXZpcy5sZW5ndGgpIHsKICAgICAgICAgICAgc2VsZWN0ZWRJZCA9IDA7CiAg
ICAgICAgICAgIHN5bmNJdGVtSGlnaGxpZ2h0KCk7CiAgICAgICAgICAgIHVwZGF0ZUxvY2F0ZUJ0
bigpOwogICAgICAgICAgICByZXR1cm47CiAgICAgICAgfQogICAgICAgIHNlbGVjdGVkSWQgPSB2
aXNbMF0uaWQ7CiAgICAgICAgcmFuZ2VBbmNob3JJZCA9IHNlbGVjdGVkSWQ7CiAgICAgICAgcmFu
Z2VBbmNob3JDbGlja2VkID0gZmFsc2U7CiAgICAgICAgbGlzdEVsLnNjcm9sbFRvcCA9IDA7CiAg
ICAgICAgc3luY0l0ZW1IaWdobGlnaHQoKTsKICAgICAgICBjb25zdCBlbCA9IGxpc3RFbC5xdWVy
eVNlbGVjdG9yKCcuaXRtW2RhdGEtaWQ9IicgKyBzZWxlY3RlZElkICsgJyJdJyk7CiAgICAgICAg
aWYgKGVsKSBlbC5zY3JvbGxJbnRvVmlldyh7IGJsb2NrOiAnbmVhcmVzdCcgfSk7CiAgICAgICAg
dXBkYXRlTG9jYXRlQnRuKCk7CiAgICB9CiAgICBmdW5jdGlvbiBqdW1wVG9MYXN0UGFzdGUoKSB7
CiAgICAgICAgaWYgKCFsYXN0UGFzdGVJZCkgcmV0dXJuOwogICAgICAgIC8vIEFscmVhZHkgbG9j
YXRlZCBvbiBsYXN0IHBhc3RlIOKGkiBjYW5jZWwgYW5kIHNlbGVjdCBmaXJzdAogICAgICAgIGlm
IChsb2NhdGVBY3RpdmUgJiYgK3NlbGVjdGVkSWQgPT09ICtsYXN0UGFzdGVJZCkgewogICAgICAg
ICAgICBzZWxlY3RGaXJzdEl0ZW0oKTsKICAgICAgICAgICAgcmV0dXJuOwogICAgICAgIH0KICAg
ICAgICBsb2NhdGVBY3RpdmUgPSB0cnVlOwogICAgICAgIHNlbGVjdEZpcnN0T25TaG93ID0gZmFs
c2U7CiAgICAgICAgLy8gQ2xlYXIgZmlsdGVycyBzbyB0aGUgaXRlbSBpcyBmaW5kYWJsZSBvbiB0
aGUgdGFiIHdoZXJlIGl0IHdhcyB1c2VkCiAgICAgICAgcXVlcnkgPSAnJzsKICAgICAgICB0b2Rh
eU9ubHkgPSBmYWxzZTsKICAgICAgICB0cnkgewogICAgICAgICAgICBjb25zdCBzcmNoID0gZG9j
dW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NlYXJjaCcpOwogICAgICAgICAgICBjb25zdCBzY2xyID0g
ZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NlYXJjaC1jbHInKTsKICAgICAgICAgICAgY29uc3Qg
d3JhcCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzZWFyY2gtd3JhcCcpOwogICAgICAgICAg
ICBjb25zdCBidG5Ub2RheSA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdidG4tdG9kYXknKTsK
ICAgICAgICAgICAgaWYgKHNyY2gpIHsgc3JjaC52YWx1ZSA9ICcnOyBzcmNoLmNsYXNzTGlzdC5y
ZW1vdmUoJ2hhcy12YWwnKTsgfQogICAgICAgICAgICBpZiAoc2Nscikgc2Nsci5zdHlsZS5kaXNw
bGF5ID0gJ25vbmUnOwogICAgICAgICAgICBpZiAod3JhcCkgd3JhcC5jbGFzc0xpc3QucmVtb3Zl
KCdvcGVuJyk7CiAgICAgICAgICAgIGlmIChidG5Ub2RheSkgYnRuVG9kYXkuY2xhc3NMaXN0LnJl
bW92ZSgnb24nKTsKICAgICAgICB9IGNhdGNoIHt9CiAgICAgICAgY29uc3QgdGFiID0gWydhbGwn
LCd0ZXh0JywnaW1hZ2UnLCdmaWxlJywncGlubmVkJ10uaW5jbHVkZXMobGFzdFBhc3RlVGFiKQog
ICAgICAgICAgICA/IGxhc3RQYXN0ZVRhYiA6ICdhbGwnOwogICAgICAgIGNvbnN0IHByZXZUYWIg
PSBjdXJUYWI7CiAgICAgICAgY3VyVGFiID0gdGFiOwogICAgICAgIGxvYWRpbmdNb3JlID0gZmFs
c2U7CiAgICAgICAgbWFya1RhYih0YWIpOwogICAgICAgIGNsZWFyTXVsdGkoKTsKICAgICAgICBz
ZWxlY3RlZElkID0gbGFzdFBhc3RlSWQ7CiAgICAgICAgd2luZG93Ll9fcGVuZGluZ0p1bXBJZCA9
IGxhc3RQYXN0ZUlkOwogICAgICAgIHdpbmRvdy5fX2p1bXBMb2FkVHJpZXMgPSAwOwogICAgICAg
IHdpbmRvdy5fX2p1bXBGZWxsQmFjayA9IGZhbHNlOwogICAgICAgIHVwZGF0ZUxvY2F0ZUJ0bigp
OwogICAgICAgIHJlcXVlc3RWaWV3KCk7CiAgICB9CgogICAgZnVuY3Rpb24gcmVxdWVzdFZpZXco
KSB7CiAgICAgICAgY29uc3QgdGFiID0gY3VyVGFiLCBxID0gcXVlcnksIHRvZGF5ID0gdG9kYXlP
bmx5ID8gJzEnIDogJzAnOwogICAgICAgIGlmICh3aW5kb3cuX192aWV3UmFmKSBjYW5jZWxBbmlt
YXRpb25GcmFtZSh3aW5kb3cuX192aWV3UmFmKTsKICAgICAgICB3aW5kb3cuX192aWV3UmFmID0g
cmVxdWVzdEFuaW1hdGlvbkZyYW1lKCgpID0+IHsKICAgICAgICAgICAgd2luZG93Ll9fdmlld1Jh
ZiA9IDA7CiAgICAgICAgICAgIHNldFRpbWVvdXQoKCkgPT4gYWhrKCdzZXRWaWV3JywgdGFiLCBx
LCB0b2RheSksIDApOwogICAgICAgIH0pOwogICAgfQogICAgLyoqIERlYm91bmNlZCBBSEsgc3lu
YyBhZnRlciB2aWV3TWVtIGluc3RhbnQgcGFpbnQg4oCUYXZvaWRzIHRhYi1zd2l0Y2ggZG91Ymxl
IFB1c2hDbGlwcyAqLwogICAgZnVuY3Rpb24gc29mdFJlcXVlc3RWaWV3KCkgewogICAgICAgIGlm
ICh3aW5kb3cuX19zb2Z0Vmlld1QpIGNsZWFyVGltZW91dCh3aW5kb3cuX19zb2Z0Vmlld1QpOwog
ICAgICAgIHdpbmRvdy5fX3NvZnRWaWV3VCA9IHNldFRpbWVvdXQoKCkgPT4gewogICAgICAgICAg
ICB3aW5kb3cuX19zb2Z0Vmlld1QgPSAwOwogICAgICAgICAgICByZXF1ZXN0VmlldygpOwogICAg
ICAgIH0sIDMyMCk7CiAgICB9CiAgICBmdW5jdGlvbiByZXF1ZXN0TW9yZShmb3JjZSA9IGZhbHNl
KSB7CiAgICAgICAgaWYgKGRpc2tUb3RhbCA+IDAgJiYgYWxsQ2xpcHMubGVuZ3RoID49IGRpc2tU
b3RhbCkgcmV0dXJuOwogICAgICAgIC8vIExvY2F0ZSAvIGp1bXAgbXVzdCBub3Qgd2FpdCBvbiBz
Y3JvbGwtaWRsZSBvciBhIHN0dWNrIGxvYWRpbmdNb3JlIGZsYWcKICAgICAgICBpZiAoIWZvcmNl
KSB7CiAgICAgICAgICAgIGlmIChsb2FkaW5nTW9yZSkgcmV0dXJuOwogICAgICAgICAgICBpZiAo
d2luZG93Ll9fc2Nyb2xsQnVzeSB8fCBfbGlzdFB0ckRvd24pIHsKICAgICAgICAgICAgICAgIHdp
bmRvdy5fX3dhbnRNb3JlID0gdHJ1ZTsKICAgICAgICAgICAgICAgIHJldHVybjsKICAgICAgICAg
ICAgfQogICAgICAgIH0gZWxzZSB7CiAgICAgICAgICAgIGxvYWRpbmdNb3JlID0gZmFsc2U7CiAg
ICAgICAgICAgIHdpbmRvdy5fX3Njcm9sbEJ1c3kgPSBmYWxzZTsKICAgICAgICAgICAgd2luZG93
Ll9fd2FudE1vcmUgPSBmYWxzZTsKICAgICAgICAgICAgX2xpc3RQdHJEb3duID0gZmFsc2U7CiAg
ICAgICAgICAgIHRyeSB7IGxpc3RFbC5jbGFzc0xpc3QucmVtb3ZlKCdpcy1zY3JvbGxpbmcnKTsg
fSBjYXRjaCB7fQogICAgICAgIH0KICAgICAgICBpZiAobG9hZGluZ01vcmUpIHJldHVybjsKICAg
ICAgICBsb2FkaW5nTW9yZSA9IHRydWU7CiAgICAgICAgd2luZG93Ll9fd2FudE1vcmUgPSBmYWxz
ZTsKICAgICAgICBpZiAod2luZG93Ll9fbG9hZE1vcmVXYXRjaCkgY2xlYXJUaW1lb3V0KHdpbmRv
dy5fX2xvYWRNb3JlV2F0Y2gpOwogICAgICAgIHdpbmRvdy5fX2xvYWRNb3JlV2F0Y2ggPSBzZXRU
aW1lb3V0KCgpID0+IHsKICAgICAgICAgICAgd2luZG93Ll9fbG9hZE1vcmVXYXRjaCA9IDA7CiAg
ICAgICAgICAgIGlmIChsb2FkaW5nTW9yZSkgewogICAgICAgICAgICAgICAgbG9hZGluZ01vcmUg
PSBmYWxzZTsKICAgICAgICAgICAgICAgIGlmICh3aW5kb3cuX19wZW5kaW5nSnVtcElkKSB0cnlD
b250aW51ZUp1bXAoKTsKICAgICAgICAgICAgfQogICAgICAgIH0sIDE4MDApOwogICAgICAgIGFo
aygnbG9hZE1vcmUnKTsKICAgIH0KCiAgICBmdW5jdGlvbiB0cnlDb250aW51ZUp1bXAoKSB7CiAg
ICAgICAgY29uc3QgamlkID0gK3dpbmRvdy5fX3BlbmRpbmdKdW1wSWQ7CiAgICAgICAgaWYgKCFq
aWQpIHJldHVybjsKICAgICAgICBpZiAoX3BlbmRpbmdBcHBlbmQpIHsKICAgICAgICAgICAgY29u
c3QgcGVuZGluZyA9IF9wZW5kaW5nQXBwZW5kOwogICAgICAgICAgICBfcGVuZGluZ0FwcGVuZCA9
IG51bGw7CiAgICAgICAgICAgIGFwcGx5QXBwZW5kUGF5bG9hZChwZW5kaW5nKTsKICAgICAgICB9
CiAgICAgICAgY29uc3QgZWwgPSBsaXN0RWwucXVlcnlTZWxlY3RvcignLm1nLXJvd1tkYXRhLWlk
PSInICsgamlkICsgJyJdJykgfHwgbGlzdEVsLnF1ZXJ5U2VsZWN0b3IoJy5pdG1bZGF0YS1pZD0i
JyArIGppZCArICciXScpOwogICAgICAgIGlmIChlbCkgewogICAgICAgICAgICB3aW5kb3cuX19w
ZW5kaW5nSnVtcElkID0gMDsKICAgICAgICAgICAgd2luZG93Ll9fanVtcExvYWRUcmllcyA9IDA7
CiAgICAgICAgICAgIHNlbGVjdGVkSWQgPSBqaWQ7CiAgICAgICAgICAgIGxvY2F0ZUFjdGl2ZSA9
IHRydWU7CiAgICAgICAgICAgIHVwZGF0ZUxvY2F0ZUJ0bigpOwogICAgICAgICAgICByZXF1ZXN0
QW5pbWF0aW9uRnJhbWUoKCkgPT4gewogICAgICAgICAgICAgICAgY29uc3Qgbm9kZSA9IGxpc3RF
bC5xdWVyeVNlbGVjdG9yKCcubWctcm93W2RhdGEtaWQ9IicgKyBqaWQgKyAnIl0nKSB8fCBsaXN0
RWwucXVlcnlTZWxlY3RvcignLml0bVtkYXRhLWlkPSInICsgamlkICsgJyJdJyk7CiAgICAgICAg
ICAgICAgICBpZiAoIW5vZGUpIHJldHVybjsKICAgICAgICAgICAgICAgIG5vZGUuc2Nyb2xsSW50
b1ZpZXcoeyBibG9jazogJ2NlbnRlcicgfSk7CiAgICAgICAgICAgICAgICBub2RlLmNsYXNzTGlz
dC5hZGQoJ2p1bXAtZmxhc2gnKTsKICAgICAgICAgICAgICAgIHNldFRpbWVvdXQoKCkgPT4gbm9k
ZS5jbGFzc0xpc3QucmVtb3ZlKCdqdW1wLWZsYXNoJyksIDkwMCk7CiAgICAgICAgICAgICAgICBz
eW5jSXRlbUhpZ2hsaWdodCgpOwogICAgICAgICAgICB9KTsKICAgICAgICAgICAgcmV0dXJuOwog
ICAgICAgIH0KICAgICAgICBpZiAoYWxsQ2xpcHMuc29tZShjID0+ICtjLmlkID09PSBqaWQpKSB7
CiAgICAgICAgICAgIHJlbmRlcigpOwogICAgICAgICAgICByZXF1ZXN0QW5pbWF0aW9uRnJhbWUo
KCkgPT4gdHJ5Q29udGludWVKdW1wKCkpOwogICAgICAgICAgICByZXR1cm47CiAgICAgICAgfQog
ICAgICAgIGlmIChhbGxDbGlwcy5sZW5ndGggPCBkaXNrVG90YWwgJiYgKHdpbmRvdy5fX2p1bXBM
b2FkVHJpZXMgfHwgMCkgPCA4MCkgewogICAgICAgICAgICB3aW5kb3cuX19qdW1wTG9hZFRyaWVz
ID0gKHdpbmRvdy5fX2p1bXBMb2FkVHJpZXMgfHwgMCkgKyAxOwogICAgICAgICAgICByZXF1ZXN0
TW9yZSh0cnVlKTsKICAgICAgICAgICAgcmV0dXJuOwogICAgICAgIH0KICAgICAgICB3aW5kb3cu
X19wZW5kaW5nSnVtcElkID0gMDsKICAgICAgICB3aW5kb3cuX19qdW1wTG9hZFRyaWVzID0gMDsK
ICAgIH0KICAgIGNvbnN0IEVNUFRZX01TRyA9IHsKICAgICAgICBhbGw6ICAgICfmmoLml6DorrDl
vZXvvIzlpI3liLblkI7oh6rliqjlh7rnjrAnLAogICAgICAgIHRleHQ6ICAgJ+aaguaXoOaWh+ac
rCcsCiAgICAgICAgaW1hZ2U6ICAn5pqC5peg5Zu+5YOPJywKICAgICAgICBmaWxlOiAgICfmmoLm
l6Dmlofku7YnLAogICAgICAgIHBpbm5lZDogJ+aaguaXoOaUtuiXjycsCiAgICAgICAgcmVjZW50
OiAn5pqC5peg5pyA6L+R5omT5byA55qE55uu5b2VJwogICAgfTsKCiAgICBmdW5jdGlvbiBhaGtJ
bnZva2UobWV0aG9kLCBhcmdzKSB7CiAgICAgICAgdHJ5IHsKICAgICAgICAgICAgY29uc3QgaG9z
dCA9IGNocm9tZS53ZWJ2aWV3Lmhvc3RPYmplY3RzLnN5bmMuYWhrOwogICAgICAgICAgICBpZiAo
IWhvc3QpIHJldHVybjsKICAgICAgICAgICAgbGV0IGNhbGxlZCA9IGZhbHNlOwogICAgICAgICAg
ICAvLyBXZWJWaWV3MjogaG9zdC5jYWxsKG5hbWUsIOKApikgaXMgdGhlIHJlbGlhYmxlIHBhdGgu
IERpcmVjdCBob3N0W21ldGhvZF0o4oCmKQogICAgICAgICAgICAvLyBjYW4gbWlzLWJpbmQgYXJn
cyAoc2F3IHNldFZpZXcgdGFiIGJlY29tZSAwIOKGkiBmb3JldmVyIHNrZWxldG9uIC8gd3Jvbmcg
dGFiKS4KICAgICAgICAgICAgaWYgKHR5cGVvZiBob3N0LmNhbGwgPT09ICdmdW5jdGlvbicpIHsK
ICAgICAgICAgICAgICAgIHRyeSB7IGhvc3QuY2FsbChtZXRob2QsIC4uLmFyZ3MpOyBjYWxsZWQg
PSB0cnVlOyB9IGNhdGNoIHt9CiAgICAgICAgICAgIH0KICAgICAgICAgICAgaWYgKCFjYWxsZWQg
JiYgdHlwZW9mIGhvc3RbbWV0aG9kXSA9PT0gJ2Z1bmN0aW9uJykgewogICAgICAgICAgICAgICAg
dHJ5IHsgaG9zdFttZXRob2RdKC4uLmFyZ3MpOyBjYWxsZWQgPSB0cnVlOyB9IGNhdGNoIChlKSB7
IGNvbnNvbGUud2FybignYWhrLicgKyBtZXRob2QsIGUpOyB9CiAgICAgICAgICAgIH0KICAgICAg
ICAgICAgaWYgKCFjYWxsZWQgJiYgaG9zdFttZXRob2RdICE9IG51bGwgJiYgdHlwZW9mIGhvc3Rb
bWV0aG9kXSAhPT0gJ2Z1bmN0aW9uJykgewogICAgICAgICAgICAgICAgdHJ5IHsgdm9pZCBob3N0
W21ldGhvZF07IH0gY2F0Y2gge30KICAgICAgICAgICAgfQogICAgICAgIH0gY2F0Y2ggKGUpIHsg
Y29uc29sZS53YXJuKCdhaGsuJyArIG1ldGhvZCwgZSk7IH0KICAgIH0KICAgIGZ1bmN0aW9uIGFo
ayhtZXRob2QsIC4uLmFyZ3MpIHsKICAgICAgICBhaGtJbnZva2UobWV0aG9kLCBhcmdzKTsKICAg
IH0KICAgIGZ1bmN0aW9uIGFoa1JldChtZXRob2QsIC4uLmFyZ3MpIHsKICAgICAgICB0cnkgewog
ICAgICAgICAgICBjb25zdCBob3N0ID0gY2hyb21lLndlYnZpZXcuaG9zdE9iamVjdHMuc3luYy5h
aGs7CiAgICAgICAgICAgIGlmICghaG9zdCkgcmV0dXJuIG51bGw7CiAgICAgICAgICAgIGxldCBy
ZXQgPSBudWxsOwogICAgICAgICAgICBpZiAodHlwZW9mIGhvc3QuY2FsbCA9PT0gJ2Z1bmN0aW9u
JykgewogICAgICAgICAgICAgICAgdHJ5IHsgcmV0ID0gaG9zdC5jYWxsKG1ldGhvZCwgLi4uYXJn
cyk7IH0gY2F0Y2gge30KICAgICAgICAgICAgfQogICAgICAgICAgICBpZiAocmV0ID09IG51bGwg
JiYgdHlwZW9mIGhvc3RbbWV0aG9kXSA9PT0gJ2Z1bmN0aW9uJykgewogICAgICAgICAgICAgICAg
dHJ5IHsgcmV0ID0gaG9zdFttZXRob2RdKC4uLmFyZ3MpOyB9IGNhdGNoIHt9CiAgICAgICAgICAg
ICAgICBpZiAocmV0ID09IG51bGwpIHsKICAgICAgICAgICAgICAgICAgICB0cnkgeyByZXQgPSBo
b3N0W21ldGhvZF0oLi4uYXJncyk7IH0gY2F0Y2gge30KICAgICAgICAgICAgICAgIH0KICAgICAg
ICAgICAgfQogICAgICAgICAgICBpZiAocmV0ID09IG51bGwgJiYgaG9zdFttZXRob2RdICE9IG51
bGwgJiYgdHlwZW9mIGhvc3RbbWV0aG9kXSAhPT0gJ2Z1bmN0aW9uJykKICAgICAgICAgICAgICAg
IHJldCA9IGhvc3RbbWV0aG9kXTsKICAgICAgICAgICAgaWYgKHJldCA9PSBudWxsKSByZXR1cm4g
bnVsbDsKICAgICAgICAgICAgaWYgKHR5cGVvZiByZXQgPT09ICdzdHJpbmcnIHx8IHR5cGVvZiBy
ZXQgPT09ICdudW1iZXInIHx8IHR5cGVvZiByZXQgPT09ICdib29sZWFuJykKICAgICAgICAgICAg
ICAgIHJldHVybiByZXQ7CiAgICAgICAgICAgIHRyeSB7IHJldHVybiBTdHJpbmcocmV0KTsgfSBj
YXRjaCB7IHJldHVybiByZXQ7IH0KICAgICAgICB9IGNhdGNoIChlKSB7IGNvbnNvbGUud2Fybign
YWhrUmV0LicgKyBtZXRob2QsIGUpOyB9CiAgICAgICAgcmV0dXJuIG51bGw7CiAgICB9CgogICAg
Ly8gRWFybHkgQUhLIF9fc2V0VGh1bWIgY2FuIGFycml2ZSBiZWZvcmUgRE9NIG5vZGVzIGV4aXN0
IOKAlCBrZWVwIHVudGlsIGJpbmQKICAgIGNvbnN0IHRodW1iQ2FjaGUgPSBuZXcgTWFwKCk7Cgog
ICAgLyoqIFByZWZlciBjYWNoZSAvIGRhdGEtVVJMLCB0aGVuIHRoXyouanBnIHZpYSB2aXJ0dWFs
IGhvc3QsIHRoZW4gb3JpZ2luYWwgKi8KICAgIGZ1bmN0aW9uIGJpbmRTdG9yZVRodW1iKGltZywg
ZmlsZSwgaWQsIGZhbGxiYWNrKSB7CiAgICAgICAgaW1nLmRhdGFzZXQudGh1bWJJZCA9IFN0cmlu
ZyhpZCk7CiAgICAgICAgaW1nLmFsdCA9ICcnOwogICAgICAgIGltZy5jbGFzc0xpc3QuYWRkKCd0
aHVtYi1sb2FkaW5nJyk7CiAgICAgICAgY29uc3Qgd3JhcCA9IGltZy5wYXJlbnRFbGVtZW50Owog
ICAgICAgIGlmICh3cmFwICYmIHdyYXAuY2xhc3NMaXN0LmNvbnRhaW5zKCdpLXRodW1iLXdyYXAn
KSkKICAgICAgICAgICAgd3JhcC5jbGFzc0xpc3QuYWRkKCd3YWl0aW5nJyk7CiAgICAgICAgY29u
c3QgY2xlYXJXYWl0ID0gKCkgPT4gewogICAgICAgICAgICBpbWcuY2xhc3NMaXN0LnJlbW92ZSgn
dGh1bWItbG9hZGluZycpOwogICAgICAgICAgICBpZiAod3JhcCkgd3JhcC5jbGFzc0xpc3QucmVt
b3ZlKCd3YWl0aW5nJyk7CiAgICAgICAgICAgIGlmIChpbWcuX2ZhaWxUaW1lcikgdHJ5IHsgY2xl
YXJUaW1lb3V0KGltZy5fZmFpbFRpbWVyKTsgfSBjYXRjaCB7fQogICAgICAgIH07CiAgICAgICAg
Y29uc3QgZmFpbFRpbWVyID0gc2V0VGltZW91dCgoKSA9PiB7CiAgICAgICAgICAgIGlmICghaW1n
LnNyYyB8fCBpbWcubmF0dXJhbFdpZHRoIDwgMSkKICAgICAgICAgICAgICAgIGltZy5hbHQgPSAn
5peg5rOV5Yqg6L29JzsKICAgICAgICAgICAgY2xlYXJXYWl0KCk7CiAgICAgICAgfSwgMTIwMDAp
OwogICAgICAgIGltZy5fZmFpbFRpbWVyID0gZmFpbFRpbWVyOwogICAgICAgIGNvbnN0IHByZXZM
b2FkID0gaW1nLm9ubG9hZDsKICAgICAgICBpbWcub25sb2FkID0gZSA9PiB7CiAgICAgICAgICAg
IGNsZWFyV2FpdCgpOwogICAgICAgICAgICBpbWcuYWx0ID0gJyc7CiAgICAgICAgICAgIGlmICh0
eXBlb2YgcHJldkxvYWQgPT09ICdmdW5jdGlvbicpIHByZXZMb2FkLmNhbGwoaW1nLCBlKTsKICAg
ICAgICB9OwogICAgICAgIGNvbnN0IGJhcmUgPSBmaWxlID8gU3RyaW5nKGZpbGUpLnNwbGl0KC9b
XFwvXS8pLnBvcCgpIDogJyc7CiAgICAgICAgY29uc3QgdGhOYW1lID0gYmFyZSA/ICgndGhfJyAr
IGJhcmUucmVwbGFjZSgvXC5bXi5dKyQvLCAnJykgKyAnLmpwZycpIDogJyc7CiAgICAgICAgaW1n
Lm9uZXJyb3IgPSAoKSA9PiB7CiAgICAgICAgICAgIGNvbnN0IHN0ZXAgPSBOdW1iZXIoaW1nLmRh
dGFzZXQuc3RlcCB8fCAwKTsKICAgICAgICAgICAgaWYgKHN0ZXAgPCAyICYmIGJhcmUpIHsKICAg
ICAgICAgICAgICAgIGltZy5kYXRhc2V0LnN0ZXAgPSAnMic7CiAgICAgICAgICAgICAgICBpbWcu
c3JjID0gU1RPUkVfQkFTRSArIGVuY29kZVVSSUNvbXBvbmVudChiYXJlKTsKICAgICAgICAgICAg
ICAgIHJldHVybjsKICAgICAgICAgICAgfQogICAgICAgICAgICBpZiAoc3RlcCA8IDMgJiYgKHRo
TmFtZSB8fCBiYXJlKSkgewogICAgICAgICAgICAgICAgaW1nLmRhdGFzZXQuc3RlcCA9ICczJzsK
ICAgICAgICAgICAgICAgIGltZy5zcmMgPSBTVE9SRV9CQVNFX0ZBTExCQUNLICsgZW5jb2RlVVJJ
Q29tcG9uZW50KHRoTmFtZSB8fCBiYXJlKTsKICAgICAgICAgICAgICAgIHJldHVybjsKICAgICAg
ICAgICAgfQogICAgICAgICAgICBpZiAoc3RlcCA8IDQgJiYgYmFyZSAmJiB0aE5hbWUpIHsKICAg
ICAgICAgICAgICAgIGltZy5kYXRhc2V0LnN0ZXAgPSAnNCc7CiAgICAgICAgICAgICAgICBpbWcu
c3JjID0gU1RPUkVfQkFTRV9GQUxMQkFDSyArIGVuY29kZVVSSUNvbXBvbmVudChiYXJlKTsKICAg
ICAgICAgICAgICAgIHJldHVybjsKICAgICAgICAgICAgfQogICAgICAgICAgICAvLyBLZWVwIHNo
aW1tZXI7IEFISyBfX3NldFRodW1iIHdpbGwgZmlsbCBpbgogICAgICAgICAgICBpbWcucmVtb3Zl
QXR0cmlidXRlKCdzcmMnKTsKICAgICAgICAgICAgaW1nLmNsYXNzTGlzdC5hZGQoJ3RodW1iLWxv
YWRpbmcnKTsKICAgICAgICAgICAgaWYgKHdyYXApIHdyYXAuY2xhc3NMaXN0LmFkZCgnd2FpdGlu
ZycpOwogICAgICAgIH07CiAgICAgICAgY29uc3QgY2FjaGVkID0gdGh1bWJDYWNoZS5nZXQoU3Ry
aW5nKGlkKSk7CiAgICAgICAgLy8gQWNjZXB0IGRhdGEtVVJMIG9yIGhvc3QgVVJMIGZyb20gcHJp
b3IgX19zZXRUaHVtYiAocmUtcmVuZGVyIG11c3Qgbm90IGRyb3AgaXQpCiAgICAgICAgaWYgKGNh
Y2hlZCAmJiBTdHJpbmcoY2FjaGVkKS5sZW5ndGgpIHsKICAgICAgICAgICAgaW1nLmRhdGFzZXQu
c3RlcCA9ICc5JzsKICAgICAgICAgICAgaW1nLnNyYyA9IFN0cmluZyhjYWNoZWQpOwogICAgICAg
ICAgICByZXR1cm47CiAgICAgICAgfQogICAgICAgIGNvbnN0IGRhdGFVcmwgPSAoZmFsbGJhY2sg
JiYgU3RyaW5nKGZhbGxiYWNrKS5zdGFydHNXaXRoKCdkYXRhOicpKQogICAgICAgICAgICA/IFN0
cmluZyhmYWxsYmFjaykgOiAnJzsKICAgICAgICBpZiAoZGF0YVVybCkgewogICAgICAgICAgICBp
bWcuZGF0YXNldC5zdGVwID0gJzknOwogICAgICAgICAgICBpbWcuc3JjID0gZGF0YVVybDsKICAg
ICAgICAgICAgcmV0dXJuOwogICAgICAgIH0KICAgICAgICBpZiAoYmFyZSkgewogICAgICAgICAg
ICAvLyBQcmVmZXIgbGlzdCB0aHVtYiBKUEVHIChzbWFsbCkgb24gZGVkaWNhdGVkIHN0b3JlIGhv
c3QKICAgICAgICAgICAgaW1nLmRhdGFzZXQuc3RlcCA9ICcxJzsKICAgICAgICAgICAgaW1nLnNy
YyA9IFNUT1JFX0JBU0UgKyBlbmNvZGVVUklDb21wb25lbnQodGhOYW1lIHx8IGJhcmUpOwogICAg
ICAgIH0gZWxzZSB7CiAgICAgICAgICAgIC8vIE5vIGZpbGUgeWV0IChqdXN0IGNvcGllZCkg4oCU
a2VlcCBzaGltbWVyOyBJbmplY3RMaXZlSW1hZ2VUaHVtYiAvIF9fc2V0VGh1bWIgZmlsbHMgaW4K
ICAgICAgICAgICAgaW1nLmNsYXNzTGlzdC5hZGQoJ3RodW1iLWxvYWRpbmcnKTsKICAgICAgICAg
ICAgaWYgKHdyYXApIHdyYXAuY2xhc3NMaXN0LmFkZCgnd2FpdGluZycpOwogICAgICAgIH0KICAg
IH0KCiAgICB3aW5kb3cuX19zZXRUaHVtYiA9IChpZCwgdXJsKSA9PiB7CiAgICAgICAgaWYgKCF1
cmwpIHJldHVybjsKICAgICAgICBjb25zdCBrZXkgPSBTdHJpbmcoaWQpOwogICAgICAgIHRodW1i
Q2FjaGUuc2V0KGtleSwgdXJsKTsKICAgICAgICBjb25zdCBhcHBseSA9IGltZyA9PiB7CiAgICAg
ICAgICAgIGlmIChpbWcuX2ZhaWxUaW1lcikgdHJ5IHsgY2xlYXJUaW1lb3V0KGltZy5fZmFpbFRp
bWVyKTsgfSBjYXRjaCB7fQogICAgICAgICAgICBpbWcub25lcnJvciA9IG51bGw7CiAgICAgICAg
ICAgIGltZy5hbHQgPSAnJzsKICAgICAgICAgICAgaW1nLmNsYXNzTGlzdC5yZW1vdmUoJ3RodW1i
LWxvYWRpbmcnKTsKICAgICAgICAgICAgY29uc3Qgd3JhcCA9IGltZy5wYXJlbnRFbGVtZW50Owog
ICAgICAgICAgICBpZiAod3JhcCkgd3JhcC5jbGFzc0xpc3QucmVtb3ZlKCd3YWl0aW5nJyk7CiAg
ICAgICAgICAgIGltZy5zcmMgPSB1cmw7CiAgICAgICAgfTsKICAgICAgICBsZXQgaGl0ID0gMDsK
ICAgICAgICBkb2N1bWVudC5xdWVyeVNlbGVjdG9yQWxsKCcuaXRtW2RhdGEtaWQ9IicgKyBrZXkg
KyAnIl0gaW1nLmktdGh1bWInKS5mb3JFYWNoKGltZyA9PiB7CiAgICAgICAgICAgIGFwcGx5KGlt
Zyk7IGhpdCsrOwogICAgICAgIH0pOwogICAgICAgIGlmICghaGl0KSB7CiAgICAgICAgICAgIGRv
Y3VtZW50LnF1ZXJ5U2VsZWN0b3JBbGwoJ2ltZy5pLXRodW1iW2RhdGEtdGh1bWItaWQ9IicgKyBr
ZXkgKyAnIl0nKS5mb3JFYWNoKGFwcGx5KTsKICAgICAgICB9CiAgICB9OwoKICAgIGZ1bmN0aW9u
IGlzRHJhZ0V4Y2x1ZGUodCkgewogICAgICAgIHJldHVybiAhIXQuY2xvc2VzdCgnI3NlYXJjaC13
cmFwLCAjYnRuLXNlYXJjaCwgI2J0bi1sb2NhdGUsICNidG4tdG9kYXksICNidG4tcGluLCAjYnRu
LWNsciwgI211bHRpLWJhciwgI211bHRpLXNlbCwgI211bHRpLWNudCwgI3Bhc3RlLXNlcC13cmFw
LCAudGFiLCAuaXRtLCAjdGFiLWFjdGlvbnMsICNjdHgsICNjbHItZGxnLCAjdGl0bGUtZGxnLCAj
cGF0aC10aXAsIGJ1dHRvbiwgaW5wdXQsIGEnKTsKICAgIH0KICAgIGRvY3VtZW50LmdldEVsZW1l
bnRCeUlkKCdhcHAnKS5hZGRFdmVudExpc3RlbmVyKCdtb3VzZWRvd24nLCBlID0+IHsKICAgICAg
ICBpZiAoZS5idXR0b24gIT09IDApIHJldHVybjsKICAgICAgICBpZiAoaXNEcmFnRXhjbHVkZShl
LnRhcmdldCkpIHJldHVybjsKICAgICAgICBlLnByZXZlbnREZWZhdWx0KCk7CiAgICAgICAgYWhr
KCdzdGFydERyYWcnKTsKICAgIH0sIHRydWUpOwoKICAgIGNvbnN0IGlzVXJsICA9IHMgPT4gL15o
dHRwcz86XC9cLy9pLnRlc3QoKHMgfHwgJycpLnRyaW0oKSk7CgogICAgZnVuY3Rpb24gYWdvKGRh
dGVTdHIpIHsKICAgICAgICB0cnkgewogICAgICAgICAgICBjb25zdCBkID0gbmV3IERhdGUoU3Ry
aW5nKGRhdGVTdHIpLnJlcGxhY2UoJyAnLCAnVCcpKTsKICAgICAgICAgICAgY29uc3QgcyA9IChE
YXRlLm5vdygpIC0gZCkgLyAxMDAwIHwgMDsKICAgICAgICAgICAgaWYgKHMgPCA2MCkgcmV0dXJu
ICfliJrliJonOwogICAgICAgICAgICBpZiAocyA8IDM2MDApIHJldHVybiAocyAvIDYwIHwgMCkg
KyAnIOWIhumSn+WJjSc7CiAgICAgICAgICAgIGlmIChzIDwgODY0MDApIHJldHVybiAocyAvIDM2
MDAgfCAwKSArICcg5bCP5pe25YmNJzsKICAgICAgICAgICAgcmV0dXJuIChzIC8gODY0MDAgfCAw
KSArICcg5aSp5YmNJzsKICAgICAgICB9IGNhdGNoIHsgcmV0dXJuIGRhdGVTdHI7IH0KICAgIH0K
CiAgICBmdW5jdGlvbiBub3JtVHlwZSh0KSB7CiAgICAgICAgdCA9IFN0cmluZyh0IHx8ICcnKS50
b0xvd2VyQ2FzZSgpOwogICAgICAgIGlmICh0ID09PSAnaW1hZ2UnIHx8IHQgPT09ICdpbWcnIHx8
IHQgPT09ICdiaXRtYXAnKSByZXR1cm4gJ2ltYWdlJzsKICAgICAgICBpZiAodCA9PT0gJ2ZpbGUn
ICB8fCB0ID09PSAnZmlsZXMnKSByZXR1cm4gJ2ZpbGUnOwogICAgICAgIGlmICh0ID09PSAncmVj
ZW50JyB8fCB0ID09PSAnZm9sZGVyJyB8fCB0ID09PSAnZGlyJykgcmV0dXJuICdyZWNlbnQnOwog
ICAgICAgIGlmICh0ID09PSAnbGluaycgfHwgdCA9PT0gJ3VybCcpIHJldHVybiAnbGluayc7CiAg
ICAgICAgcmV0dXJuICd0ZXh0JzsKICAgIH0KICAgIGZ1bmN0aW9uIGlzUGlubmVkKGMpIHsKICAg
ICAgICByZXR1cm4gYy5waW5uZWQgPT09IHRydWUgfHwgYy5waW5uZWQgPT09IDEgfHwgYy5waW5u
ZWQgPT09ICd0cnVlJyB8fCBjLnBpbm5lZCA9PT0gJzEnOwogICAgfQogICAgLyoqIOWQjOatpeaJ
gOaciSB0YWIg57yT5a2Y6YeM55qE5pS26JeP5qCH6K6w77yM6YG/5YWN5pS26JeP6aG15Y+W5raI
5ZCO5YW25a6D5YiX6KGo5LuN5pi+56S644CM5Y+W5raI5pS26JeP44CNICovCiAgICBmdW5jdGlv
biBwYXRjaFBpbm5lZEluQ2FjaGVzKGlkLCBwaW5uZWQpIHsKICAgICAgICBpZCA9ICtpZDsKICAg
ICAgICBpZiAoIWlkKSByZXR1cm47CiAgICAgICAgY29uc3QgYXBwbHkgPSAoYykgPT4gewogICAg
ICAgICAgICBpZiAoIWMgfHwgK2MuaWQgIT09IGlkKSByZXR1cm47CiAgICAgICAgICAgIGMucGlu
bmVkID0gISFwaW5uZWQ7CiAgICAgICAgICAgIGlmICghcGlubmVkKSBjLnBpblRpbWUgPSAnJzsK
ICAgICAgICB9OwogICAgICAgIGZvciAoY29uc3QgeCBvZiBhbGxDbGlwcykgYXBwbHkoeCk7CiAg
ICAgICAgdHJ5IHsKICAgICAgICAgICAgZm9yIChjb25zdCBba2V5LCBoaXRdIG9mIHZpZXdNZW0u
ZW50cmllcygpKSB7CiAgICAgICAgICAgICAgICBpZiAoIWhpdCB8fCAhQXJyYXkuaXNBcnJheSho
aXQuaXRlbXMpKSBjb250aW51ZTsKICAgICAgICAgICAgICAgIGZvciAoY29uc3QgeCBvZiBoaXQu
aXRlbXMpIGFwcGx5KHgpOwogICAgICAgICAgICAgICAgLy8g5pS26JePIHRhYiDnvJPlrZjvvJrl
j5bmtojlkI7nm7TmjqXnp7vlh7oKICAgICAgICAgICAgICAgIGlmICghcGlubmVkICYmIFN0cmlu
ZyhrZXkpLnN0YXJ0c1dpdGgoJ3Bpbm5lZFx0JykpIHsKICAgICAgICAgICAgICAgICAgICBjb25z
dCBiZWZvcmUgPSBoaXQuaXRlbXMubGVuZ3RoOwogICAgICAgICAgICAgICAgICAgIGhpdC5pdGVt
cyA9IGhpdC5pdGVtcy5maWx0ZXIoeCA9PiAreC5pZCAhPT0gaWQpOwogICAgICAgICAgICAgICAg
ICAgIGlmIChoaXQuaXRlbXMubGVuZ3RoICE9PSBiZWZvcmUpCiAgICAgICAgICAgICAgICAgICAg
ICAgIGhpdC50b3RhbCA9IE1hdGgubWF4KDAsIChOdW1iZXIoaGl0LnRvdGFsKSB8fCBiZWZvcmUp
IC0gKGJlZm9yZSAtIGhpdC5pdGVtcy5sZW5ndGgpKTsKICAgICAgICAgICAgICAgICAgICB2aWV3
TWVtLnNldChrZXksIGhpdCk7CiAgICAgICAgICAgICAgICB9CiAgICAgICAgICAgIH0KICAgICAg
ICB9IGNhdGNoIHt9CiAgICB9CiAgICBmdW5jdGlvbiBpc1Bhc3RlZChjKSB7CiAgICAgICAgcmV0
dXJuIGMucGFzdGVkID09PSB0cnVlIHx8IGMucGFzdGVkID09PSAxIHx8IGMucGFzdGVkID09PSAn
dHJ1ZScgfHwgYy5wYXN0ZWQgPT09ICcxJzsKICAgIH0KCiAgICBmdW5jdGlvbiBpc01hcmtkb3du
KHRleHQpIHsKICAgICAgICBpZiAoIXRleHQgfHwgdGV4dC5sZW5ndGggPCA0KSByZXR1cm4gZmFs
c2U7CiAgICAgICAgcmV0dXJuIC8oPzpefFxuKSN7MSw2fSB8XlstKitdIHxcKlwqW14qXG5dK1wq
XCp8X19bXl9cbl0rX198KD86Xnxcbik+IHxgYGB8YFteYFxuXStgfFxbW15cXV0rXF1cKFteKV0r
XCl8XHwuK1x8LitcfC9tLnRlc3QodGV4dCk7CiAgICB9CiAgICBmdW5jdGlvbiBjbGlwVXNlc01J
Y29uKGMpIHsKICAgICAgICBpZiAoIWMpIHJldHVybiBmYWxzZTsKICAgICAgICBpZiAoYy5pc01k
ID09PSB0cnVlIHx8IGMuaXNNZCA9PT0gMSB8fCBjLmlzTWQgPT09ICd0cnVlJyB8fCBjLmlzTWQg
PT09ICcxJykgcmV0dXJuIHRydWU7CiAgICAgICAgaWYgKGMuaXNSaWNoID09PSB0cnVlIHx8IGMu
aXNSaWNoID09PSAxIHx8IGMuaXNSaWNoID09PSAndHJ1ZScgfHwgYy5pc1JpY2ggPT09ICcxJykg
cmV0dXJuIHRydWU7CiAgICAgICAgY29uc3QgdCA9IFN0cmluZyhjLnR5cGUgfHwgJycpLnRvTG93
ZXJDYXNlKCk7CiAgICAgICAgaWYgKHQgJiYgdCAhPT0gJ3RleHQnICYmIHQgIT09ICdsaW5rJykg
cmV0dXJuIGZhbHNlOwogICAgICAgIHJldHVybiBpc01hcmtkb3duKGMuZGF0YSB8fCBjLnByZXZp
ZXcgfHwgJycpOwogICAgfQogICAgZnVuY3Rpb24gZXNjQXR0cihzKSB7CiAgICAgICAgcmV0dXJu
IFN0cmluZyhzIHx8ICcnKQogICAgICAgICAgICAucmVwbGFjZSgvJi9nLCAnJmFtcDsnKQogICAg
ICAgICAgICAucmVwbGFjZSgvIi9nLCAnJnF1b3Q7JykKICAgICAgICAgICAgLnJlcGxhY2UoLzwv
ZywgJyZsdDsnKQogICAgICAgICAgICAucmVwbGFjZSgvPi9nLCAnJmd0OycpOwogICAgfQoKICAg
IGZ1bmN0aW9uIHRvZGF5UHJlZml4KCkgewogICAgICAgIGNvbnN0IGQgPSBuZXcgRGF0ZSgpOwog
ICAgICAgIGNvbnN0IHAgPSBuID0+IFN0cmluZyhuKS5wYWRTdGFydCgyLCAnMCcpOwogICAgICAg
IHJldHVybiBkLmdldEZ1bGxZZWFyKCkgKyAnLScgKyBwKGQuZ2V0TW9udGgoKSArIDEpICsgJy0n
ICsgcChkLmdldERhdGUoKSk7CiAgICB9CiAgICBmdW5jdGlvbiBpc1RvZGF5Q2xpcChjKSB7CiAg
ICAgICAgcmV0dXJuIFN0cmluZyhjLnRpbWUgfHwgJycpLnN0YXJ0c1dpdGgodG9kYXlQcmVmaXgo
KSk7CiAgICB9CgogICAgZnVuY3Rpb24gY2xpcEhheShjKSB7CiAgICAgICAgcmV0dXJuIFN0cmlu
ZyhjLnByZXZpZXcgfHwgJycpICsgJyAnICsgU3RyaW5nKGMuZGF0YSB8fCAnJykgKyAnICcKICAg
ICAgICAgICAgKyBTdHJpbmcoYy5saW5rVGl0bGUgfHwgJycpICsgJyAnICsgU3RyaW5nKGMuZmF2
VGl0bGUgfHwgJycpOwogICAgfQogICAgLyoqIE1hdGNoIEFISyBJdGVtTWF0Y2hlc1ZpZXcgbGlz
dCBzZWFyY2gg4oCUIHByZXZpZXcgKCsgc2hvcnQgYm9keSBmYWxsYmFjayksIG5vdCBmdWxsIGRh
dGEgKi8KICAgIGZ1bmN0aW9uIGNsaXBTZWFyY2hIYXkoYykgewogICAgICAgIGNvbnN0IHR5cGUg
PSBTdHJpbmcoYy50eXBlIHx8ICcnKS50b0xvd2VyQ2FzZSgpOwogICAgICAgIGlmICh0eXBlID09
PSAnaW1hZ2UnKQogICAgICAgICAgICByZXR1cm4gU3RyaW5nKGMuZmF2VGl0bGUgfHwgJycpOwog
ICAgICAgIGlmICh0eXBlID09PSAnZmlsZScpIHsKICAgICAgICAgICAgcmV0dXJuIFN0cmluZyhj
LnByZXZpZXcgfHwgJycpICsgJyAnICsgU3RyaW5nKGMuZGF0YSB8fCAnJykgKyAnICcKICAgICAg
ICAgICAgICAgICsgU3RyaW5nKGMuZmF2VGl0bGUgfHwgJycpOwogICAgICAgIH0KICAgICAgICBs
ZXQgcHJldiA9IFN0cmluZyhjLnByZXZpZXcgfHwgJycpOwogICAgICAgIGlmICghcHJldiAmJiBj
LmRhdGEpCiAgICAgICAgICAgIHByZXYgPSBTdHJpbmcoYy5kYXRhKS5zbGljZSgwLCA1MDApOwog
ICAgICAgIHJldHVybiBwcmV2ICsgJyAnICsgU3RyaW5nKGMubGlua1RpdGxlIHx8ICcnKSArICcg
JyArIFN0cmluZyhjLmZhdlRpdGxlIHx8ICcnKTsKICAgIH0KICAgIGZ1bmN0aW9uIGNsaXBNYXRj
aGVzU2VhcmNoKGMsIHRlcm1MKSB7CiAgICAgICAgY29uc3QgdHlwZSA9IFN0cmluZyhjLnR5cGUg
fHwgJycpLnRvTG93ZXJDYXNlKCk7CiAgICAgICAgY29uc3QgaGF5ID0gKHR5cGUgPT09ICdpbWFn
ZScgPyBTdHJpbmcoYy5mYXZUaXRsZSB8fCAnJykgOiBjbGlwU2VhcmNoSGF5KGMpKS50b0xvd2Vy
Q2FzZSgpOwogICAgICAgIHJldHVybiB0ZXJtTC5ldmVyeSh0ID0+IGhheS5pbmNsdWRlcyh0KSk7
CiAgICB9CiAgICBmdW5jdGlvbiBmaWx0ZXIoY2xpcHMsIHRhYiwgcSkgewogICAgICAgIC8vIOS4
u+acuuW3sui/h+a7pOaXtuS7jeWBmuWJjeerr+WFnOW6le+8mumBv+WFjeernuaAgeaOqOadpeac
quWRveS4reihjAogICAgICAgIGNvbnN0IHRlcm1zID0gcXVlcnlUZXJtcyhxKTsKICAgICAgICBp
ZiAoIXRlcm1zLmxlbmd0aCkgcmV0dXJuIGNsaXBzOwogICAgICAgIGNvbnN0IHRlcm1MID0gdGVy
bXMubWFwKHQgPT4gdC50b0xvd2VyQ2FzZSgpKTsKICAgICAgICBjb25zdCBtYXRjaGVkR3JvdXBz
ID0gbmV3IFNldCgpOwogICAgICAgIGZvciAoY29uc3QgYyBvZiBjbGlwcykgewogICAgICAgICAg
ICBpZiAoIWNsaXBNYXRjaGVzU2VhcmNoKGMsIHRlcm1MKSkgY29udGludWU7CiAgICAgICAgICAg
IGNvbnN0IGdpZCA9IFN0cmluZyhjICYmIGMuZmF2R3JvdXAgfHwgJycpLnRyaW0oKTsKICAgICAg
ICAgICAgaWYgKGdpZCkgbWF0Y2hlZEdyb3Vwcy5hZGQoZ2lkKTsKICAgICAgICB9CiAgICAgICAg
Ly8g5ZCI5bm257uE77ya5YWz6ZSu5a2X5Y+v6IO95YiG5pWj5Zyo5LiN5ZCM6KGM77yI5qCH6aKY
L+ato+aWh++8iQogICAgICAgIGNvbnN0IGJ5R3JvdXAgPSBuZXcgTWFwKCk7CiAgICAgICAgZm9y
IChjb25zdCBjIG9mIGNsaXBzKSB7CiAgICAgICAgICAgIGNvbnN0IGdpZCA9IFN0cmluZyhjICYm
IGMuZmF2R3JvdXAgfHwgJycpLnRyaW0oKTsKICAgICAgICAgICAgaWYgKCFnaWQpIGNvbnRpbnVl
OwogICAgICAgICAgICBpZiAoIWJ5R3JvdXAuaGFzKGdpZCkpIGJ5R3JvdXAuc2V0KGdpZCwgW10p
OwogICAgICAgICAgICBieUdyb3VwLmdldChnaWQpLnB1c2goYyk7CiAgICAgICAgfQogICAgICAg
IGZvciAoY29uc3QgW2dpZCwgbWVtYmVyc10gb2YgYnlHcm91cCkgewogICAgICAgICAgICBpZiAo
bWF0Y2hlZEdyb3Vwcy5oYXMoZ2lkKSkgY29udGludWU7CiAgICAgICAgICAgIGNvbnN0IHVuaW9u
ID0gbWVtYmVycy5tYXAoYyA9PiB7CiAgICAgICAgICAgICAgICBjb25zdCB0eXBlID0gU3RyaW5n
KGMudHlwZSB8fCAnJykudG9Mb3dlckNhc2UoKTsKICAgICAgICAgICAgICAgIHJldHVybiAodHlw
ZSA9PT0gJ2ltYWdlJyA/IFN0cmluZyhjLmZhdlRpdGxlIHx8ICcnKSA6IGNsaXBTZWFyY2hIYXko
YykpLnRvTG93ZXJDYXNlKCk7CiAgICAgICAgICAgIH0pLmpvaW4oJyAnKTsKICAgICAgICAgICAg
aWYgKHRlcm1MLmV2ZXJ5KHQgPT4gdW5pb24uaW5jbHVkZXModCkpKQogICAgICAgICAgICAgICAg
bWF0Y2hlZEdyb3Vwcy5hZGQoZ2lkKTsKICAgICAgICB9CiAgICAgICAgcmV0dXJuIGNsaXBzLmZp
bHRlcihjID0+IHsKICAgICAgICAgICAgaWYgKGNsaXBNYXRjaGVzU2VhcmNoKGMsIHRlcm1MKSkg
cmV0dXJuIHRydWU7CiAgICAgICAgICAgIGNvbnN0IGdpZCA9IFN0cmluZyhjICYmIGMuZmF2R3Jv
dXAgfHwgJycpLnRyaW0oKTsKICAgICAgICAgICAgcmV0dXJuIGdpZCAmJiBtYXRjaGVkR3JvdXBz
LmhhcyhnaWQpOwogICAgICAgIH0pOwogICAgfQoKICAgIGZ1bmN0aW9uIG1hcmtQYXN0ZWRMb2Nh
bChpZHMpIHsKICAgICAgICBjb25zdCBsaXN0ID0gQXJyYXkuaXNBcnJheShpZHMpID8gaWRzIDog
W2lkc107CiAgICAgICAgaWYgKGxpc3QubGVuZ3RoKQogICAgICAgICAgICByZW1lbWJlckxhc3RQ
YXN0ZShsaXN0W2xpc3QubGVuZ3RoIC0gMV0pOwogICAgICAgIGNvbnN0IGJhZGdlSHRtbCA9IGA8
c3ZnIHZpZXdCb3g9IjAgMCAxNiAxNiIgZmlsbD0ibm9uZSIgc3Ryb2tlPSJjdXJyZW50Q29sb3Ii
IHN0cm9rZS13aWR0aD0iMi40IiBzdHJva2UtbGluZWNhcD0icm91bmQiIHN0cm9rZS1saW5lam9p
bj0icm91bmQiPjxwb2x5bGluZSBwb2ludHM9IjMuNSA4LjUgNi41IDExLjUgMTIuNSA0LjUiLz48
L3N2Zz5gOwogICAgICAgIGxpc3QuZm9yRWFjaChyYXdJZCA9PiB7CiAgICAgICAgICAgIGNvbnN0
IGlkID0gK3Jhd0lkOwogICAgICAgICAgICBjb25zdCBjID0gYWxsQ2xpcHMuZmluZCh4ID0+ICt4
LmlkID09PSBpZCk7CiAgICAgICAgICAgIGlmIChjKSBjLnBhc3RlZCA9IHRydWU7CiAgICAgICAg
ICAgIGNvbnN0IHJvdyA9IGxpc3RFbCAmJiAoCiAgICAgICAgICAgICAgICBsaXN0RWwucXVlcnlT
ZWxlY3RvcignLml0bVtkYXRhLWlkPSInICsgaWQgKyAnIl0nKQogICAgICAgICAgICAgICAgfHwg
bGlzdEVsLnF1ZXJ5U2VsZWN0b3IoJy5pdG1bZGF0YS1pZD0iJyArIFN0cmluZyhyYXdJZCkgKyAn
Il0nKQogICAgICAgICAgICApOwogICAgICAgICAgICBpZiAoIXJvdykgcmV0dXJuOwogICAgICAg
ICAgICByb3cuY2xhc3NMaXN0LmFkZCgncGFzdGVkJywgJ3EtZG9uZScpOwogICAgICAgICAgICBj
b25zdCBpY28gPSByb3cucXVlcnlTZWxlY3RvcignLmktaWNvJyk7CiAgICAgICAgICAgIGlmIChp
Y28gJiYgIWljby5xdWVyeVNlbGVjdG9yKCcuaS11c2VkJykpIHsKICAgICAgICAgICAgICAgIGNv
bnN0IGJhZGdlID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnc3BhbicpOwogICAgICAgICAgICAg
ICAgYmFkZ2UuY2xhc3NOYW1lID0gJ2ktdXNlZCc7CiAgICAgICAgICAgICAgICBiYWRnZS50aXRs
ZSA9ICflt7LnspjotLQnOwogICAgICAgICAgICAgICAgYmFkZ2UuaW5uZXJIVE1MID0gYmFkZ2VI
dG1sOwogICAgICAgICAgICAgICAgaWNvLmFwcGVuZENoaWxkKGJhZGdlKTsKICAgICAgICAgICAg
fQogICAgICAgIH0pOwogICAgICAgIHRyeSB7IG1hcmtRdWV1ZVJhaWxzKCk7IH0gY2F0Y2ggKGUp
IHt9CiAgICB9CiAgICB3aW5kb3cuX19tYXJrUGFzdGVkID0gbWFya1Bhc3RlZExvY2FsOwoKICAg
IGZ1bmN0aW9uIG1hcmtVbnBhc3RlZExvY2FsKGlkcykgewogICAgICAgIGNvbnN0IGxpc3QgPSBB
cnJheS5pc0FycmF5KGlkcykgPyBpZHMgOiBbaWRzXTsKICAgICAgICBsaXN0LmZvckVhY2gocmF3
SWQgPT4gewogICAgICAgICAgICBjb25zdCBpZCA9ICtyYXdJZDsKICAgICAgICAgICAgY29uc3Qg
YyA9IGFsbENsaXBzLmZpbmQoeCA9PiAreC5pZCA9PT0gaWQpOwogICAgICAgICAgICBpZiAoYykg
Yy5wYXN0ZWQgPSBmYWxzZTsKICAgICAgICAgICAgY29uc3Qgcm93ID0gbGlzdEVsICYmICgKICAg
ICAgICAgICAgICAgIGxpc3RFbC5xdWVyeVNlbGVjdG9yKCcuaXRtW2RhdGEtaWQ9IicgKyBpZCAr
ICciXScpCiAgICAgICAgICAgICAgICB8fCBsaXN0RWwucXVlcnlTZWxlY3RvcignLml0bVtkYXRh
LWlkPSInICsgU3RyaW5nKHJhd0lkKSArICciXScpCiAgICAgICAgICAgICk7CiAgICAgICAgICAg
IGlmICghcm93KSByZXR1cm47CiAgICAgICAgICAgIHJvdy5jbGFzc0xpc3QucmVtb3ZlKCdwYXN0
ZWQnLCAncS1kb25lJywgJ3EtZG9uZS1saW5rJyk7CiAgICAgICAgICAgIGNvbnN0IGJhZGdlID0g
cm93LnF1ZXJ5U2VsZWN0b3IoJy5pLXVzZWQnKTsKICAgICAgICAgICAgaWYgKGJhZGdlKSBiYWRn
ZS5yZW1vdmUoKTsKICAgICAgICAgICAgY29uc3QgZG90ID0gcm93LnF1ZXJ5U2VsZWN0b3IoJy5x
LWRvdCcpOwogICAgICAgICAgICBpZiAoZG90KSBkb3QudGl0bGUgPSAn57KY6LS06Zif5YiXJzsK
ICAgICAgICB9KTsKICAgICAgICB0cnkgeyBtYXJrUXVldWVSYWlscygpOyB9IGNhdGNoIChlKSB7
fQogICAgfQogICAgd2luZG93Ll9fbWFya1VucGFzdGVkID0gbWFya1VucGFzdGVkTG9jYWw7Cgog
ICAgY29uc3QgbGlzdEVsICA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdsaXN0Jyk7CiAgICBj
b25zdCBlbXB0eUVsID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2VtcHR5Jyk7CiAgICBjb25z
dCBza2VsRWwgID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NrZWwnKTsKICAgIGNvbnN0IGJ0
blRvcCAgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYnRuLXRvcCcpOwogICAgZnVuY3Rpb24g
c2V0Qm9vdExvYWRpbmcob24pIHsKICAgICAgICBib290TG9hZGluZyA9ICEhb247CiAgICAgICAg
Ly8g56eS5byA77ya5LiN5YaN5omT5byA6aqo5p626Zeq5Yqo77yb5Y+q5L+d55WZIHdhaXRpbmdE
YXRhIOmAu+i+kemYsuepuuaAgeivr+mXqgogICAgICAgIGlmIChza2VsRWwpIHNrZWxFbC5jbGFz
c0xpc3QucmVtb3ZlKCdvbicpOwogICAgICAgIGlmIChvbiAmJiBlbXB0eUVsKSBlbXB0eUVsLmNs
YXNzTGlzdC5yZW1vdmUoJ29uJyk7CiAgICAgICAgY29uc3QgYXBwID0gZG9jdW1lbnQuZ2V0RWxl
bWVudEJ5SWQoJ2FwcCcpOwogICAgICAgIGlmIChhcHApIGFwcC5jbGFzc0xpc3QucmVtb3ZlKCdi
b290LWxvYWRpbmcnKTsKICAgIH0KICAgIC8qKiBXYWl0IGZvciBob3N0IGRhdGEg4oCU5LiN5YaN
56uL5Yi75by56aqo5p6277yM5pyJ5YaF5a655pe25L+d5oyB5pen5YiX6KGoICovCiAgICBmdW5j
dGlvbiBzY2hlZHVsZURlbGF5ZWRTa2VsKCkgewogICAgICAgIHdhaXRpbmdEYXRhID0gdHJ1ZTsK
ICAgICAgICB3aW5kb3cuX19kYXRhUmVhZHkgPSBmYWxzZTsKICAgICAgICBpZiAoZW1wdHlFbCkg
ZW1wdHlFbC5jbGFzc0xpc3QucmVtb3ZlKCdvbicpOwogICAgICAgIGlmICh3aW5kb3cuX19wZW5k
aW5nU2tlbFRpbWVyKSB7CiAgICAgICAgICAgIGNsZWFyVGltZW91dCh3aW5kb3cuX19wZW5kaW5n
U2tlbFRpbWVyKTsKICAgICAgICAgICAgd2luZG93Ll9fcGVuZGluZ1NrZWxUaW1lciA9IDA7CiAg
ICAgICAgfQogICAgICAgIHdpbmRvdy5fX3BlbmRpbmdTa2VsU2luY2UgPSBEYXRlLm5vdygpOwog
ICAgICAgIC8vIOacieaXp+WIl+ihqOWwseS/neeVme+8m+epuuWIl+ihqOS5n+S4jeWGjeaSremq
qOaetuWKqOeUuwogICAgfQogICAgZnVuY3Rpb24gY2xlYXJXYWl0aW5nRGF0YSgpIHsKICAgICAg
ICB3YWl0aW5nRGF0YSA9IGZhbHNlOwogICAgICAgIGlmICh3aW5kb3cuX19wZW5kaW5nU2tlbFRp
bWVyKSB7CiAgICAgICAgICAgIGNsZWFyVGltZW91dCh3aW5kb3cuX19wZW5kaW5nU2tlbFRpbWVy
KTsKICAgICAgICAgICAgd2luZG93Ll9fcGVuZGluZ1NrZWxUaW1lciA9IDA7CiAgICAgICAgfQog
ICAgICAgIHdpbmRvdy5fX3BlbmRpbmdTa2VsU2luY2UgPSAwOwogICAgICAgIHNldEJvb3RMb2Fk
aW5nKGZhbHNlKTsKICAgIH0KICAgIHdpbmRvdy5zZXRCb290TG9hZGluZyA9IHNldEJvb3RMb2Fk
aW5nOwogICAgd2luZG93LmZvcmNlRW5kQm9vdExvYWRpbmcgPSBmdW5jdGlvbigpIHsKICAgICAg
ICBjbGVhcldhaXRpbmdEYXRhKCk7CiAgICAgICAgLy8gRG8gbm90IGZha2XjgIzmmoLml6DorrDl
vZXjgI1pZiBob3N0IG5ldmVyIHB1c2hlZAogICAgICAgIGlmIChob3N0UHVzaGVkT25jZSkKICAg
ICAgICAgICAgd2luZG93Ll9fZGF0YVJlYWR5ID0gdHJ1ZTsKICAgICAgICB0cnkgeyByZW5kZXIo
KTsgfSBjYXRjaCAoZSkge30KICAgIH07CiAgICAvLyBTYWZldHk6IGRyb3Agc3R1Y2sgc2tlbGV0
b247IHN0aWxsIG5ldmVyIGludmVudCBlbXB0eS1zdGF0ZSB3aXRob3V0IGhvc3QgcHVzaAogICAg
c2V0VGltZW91dCgoKSA9PiB7CiAgICAgICAgaWYgKGhvc3RQdXNoZWRPbmNlIHx8IHdpbmRvdy5f
X2RhdGFSZWFkeSkgcmV0dXJuOwogICAgICAgIGlmICghYm9vdExvYWRpbmcgJiYgIXdhaXRpbmdE
YXRhKSByZXR1cm47CiAgICAgICAgY2xlYXJXYWl0aW5nRGF0YSgpOwogICAgICAgIHRyeSB7IHJl
bmRlcigpOyB9IGNhdGNoIHt9CiAgICB9LCA4MDAwKTsKCiAgICBmdW5jdGlvbiB1cGRhdGVUb3BC
dG4oKSB7CiAgICAgICAgaWYgKCFidG5Ub3AgfHwgIWxpc3RFbCkgcmV0dXJuOwogICAgICAgIGJ0
blRvcC5jbGFzc0xpc3QudG9nZ2xlKCdvbicsIGxpc3RFbC5zY3JvbGxUb3AgPiA0OCk7CiAgICB9
CiAgICBsZXQgX3Njcm9sbFJhZiA9IDA7CiAgICBsZXQgX3Njcm9sbElkbGVUID0gMDsKICAgIGxl
dCBfbGlzdFB0ckRvd24gPSBmYWxzZTsKICAgIGxldCBfcGVuZGluZ0FwcGVuZCA9IG51bGw7IC8v
IHsgZnJvbUxlbiB9IHF1ZXVlZCB3aGlsZSBzY3JvbGxpbmcKICAgIHdpbmRvdy5fX3Njcm9sbEJ1
c3kgPSBmYWxzZTsKICAgIHdpbmRvdy5fX3dhbnRNb3JlID0gZmFsc2U7CgogICAgZnVuY3Rpb24g
bWFya0xpc3RTY3JvbGxpbmcoKSB7CiAgICAgICAgd2luZG93Ll9fc2Nyb2xsQnVzeSA9IHRydWU7
CiAgICAgICAgdHJ5IHsgbGlzdEVsLmNsYXNzTGlzdC5hZGQoJ2lzLXNjcm9sbGluZycpOyB9IGNh
dGNoIHt9CiAgICAgICAgaWYgKF9zY3JvbGxJZGxlVCkgY2xlYXJUaW1lb3V0KF9zY3JvbGxJZGxl
VCk7CiAgICAgICAgX3Njcm9sbElkbGVUID0gc2V0VGltZW91dCgoKSA9PiB7CiAgICAgICAgICAg
IF9zY3JvbGxJZGxlVCA9IDA7CiAgICAgICAgICAgIGZsdXNoU2Nyb2xsSWRsZSgpOwogICAgICAg
IH0sIDIyMCk7CiAgICB9CgogICAgZnVuY3Rpb24gZmx1c2hTY3JvbGxJZGxlKCkgewogICAgICAg
IGlmIChfbGlzdFB0ckRvd24pIHsKICAgICAgICAgICAgbWFya0xpc3RTY3JvbGxpbmcoKTsKICAg
ICAgICAgICAgcmV0dXJuOwogICAgICAgIH0KICAgICAgICB3aW5kb3cuX19zY3JvbGxCdXN5ID0g
ZmFsc2U7CiAgICAgICAgdHJ5IHsgbGlzdEVsLmNsYXNzTGlzdC5yZW1vdmUoJ2lzLXNjcm9sbGlu
ZycpOyB9IGNhdGNoIHt9CiAgICAgICAgaWYgKF9wZW5kaW5nQXBwZW5kKSB7CiAgICAgICAgICAg
IGNvbnN0IHBlbmRpbmcgPSBfcGVuZGluZ0FwcGVuZDsKICAgICAgICAgICAgX3BlbmRpbmdBcHBl
bmQgPSBudWxsOwogICAgICAgICAgICBhcHBseUFwcGVuZFBheWxvYWQocGVuZGluZyk7CiAgICAg
ICAgfQogICAgICAgIGlmICh3aW5kb3cuX193YW50TW9yZSkKICAgICAgICAgICAgcmVxdWVzdE1v
cmUoKTsKICAgICAgICBlbHNlIGlmICghbG9hZGluZ01vcmUKICAgICAgICAgICAgJiYgZGlza1Rv
dGFsID4gMAogICAgICAgICAgICAmJiBhbGxDbGlwcy5sZW5ndGggPCBkaXNrVG90YWwKICAgICAg
ICAgICAgJiYgbGlzdEVsLnNjcm9sbFRvcCArIGxpc3RFbC5jbGllbnRIZWlnaHQgPj0gbGlzdEVs
LnNjcm9sbEhlaWdodCAtIDQyMCkKICAgICAgICAgICAgcmVxdWVzdE1vcmUoKTsKICAgIH0KCiAg
ICBmdW5jdGlvbiBvbkxpc3RTY3JvbGwoKSB7CiAgICAgICAgbWFya0xpc3RTY3JvbGxpbmcoKTsK
ICAgICAgICBpZiAoX3Njcm9sbFJhZikgcmV0dXJuOwogICAgICAgIF9zY3JvbGxSYWYgPSByZXF1
ZXN0QW5pbWF0aW9uRnJhbWUoKCkgPT4gewogICAgICAgICAgICBfc2Nyb2xsUmFmID0gMDsKICAg
ICAgICAgICAgdHJ5IHsgaGlkZVBhdGhUaXAoKTsgfSBjYXRjaCB7fQogICAgICAgICAgICB1cGRh
dGVUb3BCdG4oKTsKICAgICAgICAgICAgaWYgKCFsb2FkaW5nTW9yZQogICAgICAgICAgICAgICAg
JiYgZGlza1RvdGFsID4gMAogICAgICAgICAgICAgICAgJiYgYWxsQ2xpcHMubGVuZ3RoIDwgZGlz
a1RvdGFsCiAgICAgICAgICAgICAgICAmJiBsaXN0RWwuc2Nyb2xsVG9wICsgbGlzdEVsLmNsaWVu
dEhlaWdodCA+PSBsaXN0RWwuc2Nyb2xsSGVpZ2h0IC0gMjQwKQogICAgICAgICAgICAgICAgd2lu
ZG93Ll9fd2FudE1vcmUgPSB0cnVlOwogICAgICAgIH0pOwogICAgfQogICAgbGlzdEVsLmFkZEV2
ZW50TGlzdGVuZXIoJ3Njcm9sbCcsIG9uTGlzdFNjcm9sbCwgeyBwYXNzaXZlOiB0cnVlIH0pOwog
ICAgbGlzdEVsLmFkZEV2ZW50TGlzdGVuZXIoJ3doZWVsJywgbWFya0xpc3RTY3JvbGxpbmcsIHsg
cGFzc2l2ZTogdHJ1ZSB9KTsKICAgIGxpc3RFbC5hZGRFdmVudExpc3RlbmVyKCdwb2ludGVyZG93
bicsIGUgPT4gewogICAgICAgIGlmIChlLmJ1dHRvbiAhPT0gMCkgcmV0dXJuOwogICAgICAgIF9s
aXN0UHRyRG93biA9IHRydWU7CiAgICAgICAgbWFya0xpc3RTY3JvbGxpbmcoKTsKICAgIH0sIHsg
cGFzc2l2ZTogdHJ1ZSB9KTsKICAgIHdpbmRvdy5hZGRFdmVudExpc3RlbmVyKCdwb2ludGVydXAn
LCAoKSA9PiB7CiAgICAgICAgaWYgKCFfbGlzdFB0ckRvd24pIHJldHVybjsKICAgICAgICBfbGlz
dFB0ckRvd24gPSBmYWxzZTsKICAgICAgICBtYXJrTGlzdFNjcm9sbGluZygpOwogICAgfSwgeyBw
YXNzaXZlOiB0cnVlIH0pOwogICAgd2luZG93LmFkZEV2ZW50TGlzdGVuZXIoJ3BvaW50ZXJjYW5j
ZWwnLCAoKSA9PiB7CiAgICAgICAgaWYgKCFfbGlzdFB0ckRvd24pIHJldHVybjsKICAgICAgICBf
bGlzdFB0ckRvd24gPSBmYWxzZTsKICAgICAgICBtYXJrTGlzdFNjcm9sbGluZygpOwogICAgfSwg
eyBwYXNzaXZlOiB0cnVlIH0pOwogICAgYnRuVG9wLmFkZEV2ZW50TGlzdGVuZXIoJ2NsaWNrJywg
ZSA9PiB7CiAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICBsaXN0RWwuc2Nyb2xs
VG8oeyB0b3A6IDAsIGJlaGF2aW9yOiAnc21vb3RoJyB9KTsKICAgIH0pOwoKICAgIGZ1bmN0aW9u
IHZpc2libGVMaXN0KCkgewogICAgICAgIGNvbnN0IHEgPSBTdHJpbmcocXVlcnkgfHwgJycpLnRy
aW0oKTsKICAgICAgICAvLyBIb3N0IGFscmVhZHkgZmlsdGVyZWQrZXhwYW5kZWQgZm9yIHRoaXMg
ZXhhY3QgcXVlcnkg4oCUIGRvbid0IHJlLWZpbHRlciAoYXZvaWRzIGZsYXNoIC8gZHJvcHBlZCBm
YXYgZ3JvdXBzKQogICAgICAgIGxldCBsaXN0ID0gKHEgJiYgd2luZG93Ll9faG9zdEZpbHRlcmVk
ICYmIHdpbmRvdy5fX2hvc3RGaWx0ZXJRID09PSBxKQogICAgICAgICAgICA/IGFsbENsaXBzCiAg
ICAgICAgICAgIDogZmlsdGVyKGFsbENsaXBzLCBjdXJUYWIsIHF1ZXJ5KTsKICAgICAgICAvLyDm
lLbol4/pobXvvJrmnKzlnLDlho3mu6TkuIDmrKHvvIzlj5bmtojmlLbol4/lj6/nq4vliLvmtojl
pLHvvIzkuI3lv4XnrYkgQUhLIOmHjeW7ugogICAgICAgIGlmIChjdXJUYWIgPT09ICdwaW5uZWQn
KQogICAgICAgICAgICBsaXN0ID0gbGlzdC5maWx0ZXIoYyA9PiBpc1Bpbm5lZChjKSk7CiAgICAg
ICAgcmV0dXJuIGxpc3Q7CiAgICB9CiAgICBmdW5jdGlvbiBlc2NIdG1sKHMpIHsKICAgICAgICBy
ZXR1cm4gU3RyaW5nKHMgPz8gJycpLnJlcGxhY2UoLyYvZywnJmFtcDsnKS5yZXBsYWNlKC88L2cs
JyZsdDsnKS5yZXBsYWNlKC8+L2csJyZndDsnKS5yZXBsYWNlKC8iL2csJyZxdW90OycpOwogICAg
fQogICAgZnVuY3Rpb24gcXVlcnlUZXJtcyhxKSB7CiAgICAgICAgY29uc3Qgb3V0ID0gW107CiAg
ICAgICAgZm9yIChjb25zdCBzZWcgb2YgU3RyaW5nKHEgfHwgJycpLnNwbGl0KCd8JykpIHsKICAg
ICAgICAgICAgY29uc3QgcyA9IHNlZy50cmltKCk7CiAgICAgICAgICAgIGlmICghcykgY29udGlu
dWU7CiAgICAgICAgICAgIGNvbnN0IHdvcmRzID0gcy5zcGxpdCgvXHMrLykuZmlsdGVyKEJvb2xl
YW4pOwogICAgICAgICAgICBpZiAod29yZHMubGVuZ3RoKSBvdXQucHVzaCguLi53b3Jkcyk7CiAg
ICAgICAgfQogICAgICAgIHJldHVybiBvdXQ7CiAgICB9CiAgICBmdW5jdGlvbiBobEh0bWwodGV4
dCkgewogICAgICAgIGNvbnN0IHRlcm1zID0gcXVlcnlUZXJtcyhxdWVyeSk7CiAgICAgICAgY29u
c3QgcyA9IFN0cmluZyh0ZXh0ID8/ICcnKTsKICAgICAgICBpZiAoIXRlcm1zLmxlbmd0aCkgcmV0
dXJuIGVzY0h0bWwocyk7CiAgICAgICAgY29uc3QgbG93ZXIgPSBzLnRvTG93ZXJDYXNlKCk7CiAg
ICAgICAgY29uc3QgdGVybUwgPSB0ZXJtcy5tYXAodCA9PiB0LnRvTG93ZXJDYXNlKCkpOwogICAg
ICAgIGxldCBvdXQgPSAnJywgaSA9IDA7CiAgICAgICAgd2hpbGUgKGkgPCBzLmxlbmd0aCkgewog
ICAgICAgICAgICBsZXQgYmVzdEogPSAtMSwgYmVzdExlbiA9IDA7CiAgICAgICAgICAgIGZvciAo
bGV0IHRpID0gMDsgdGkgPCB0ZXJtTC5sZW5ndGg7IHRpKyspIHsKICAgICAgICAgICAgICAgIGNv
bnN0IHQgPSB0ZXJtTFt0aV07CiAgICAgICAgICAgICAgICBpZiAoIXQpIGNvbnRpbnVlOwogICAg
ICAgICAgICAgICAgY29uc3QgaiA9IGxvd2VyLmluZGV4T2YodCwgaSk7CiAgICAgICAgICAgICAg
ICBpZiAoaiA8IDApIGNvbnRpbnVlOwogICAgICAgICAgICAgICAgaWYgKGJlc3RKIDwgMCB8fCBq
IDwgYmVzdEogfHwgKGogPT09IGJlc3RKICYmIHQubGVuZ3RoID4gYmVzdExlbikpIHsKICAgICAg
ICAgICAgICAgICAgICBiZXN0SiA9IGo7IGJlc3RMZW4gPSB0Lmxlbmd0aDsKICAgICAgICAgICAg
ICAgIH0KICAgICAgICAgICAgfQogICAgICAgICAgICBpZiAoYmVzdEogPCAwKSB7IG91dCArPSBl
c2NIdG1sKHMuc2xpY2UoaSkpOyBicmVhazsgfQogICAgICAgICAgICBvdXQgKz0gZXNjSHRtbChz
LnNsaWNlKGksIGJlc3RKKSk7CiAgICAgICAgICAgIG91dCArPSAnPG1hcmsgY2xhc3M9InEtaGwi
PicgKyBlc2NIdG1sKHMuc2xpY2UoYmVzdEosIGJlc3RKICsgYmVzdExlbikpICsgJzwvbWFyaz4n
OwogICAgICAgICAgICBpID0gYmVzdEogKyBNYXRoLm1heCgxLCBiZXN0TGVuKTsKICAgICAgICB9
CiAgICAgICAgcmV0dXJuIG91dDsKICAgIH0KICAgIGZ1bmN0aW9uIHNldEhsVGV4dChlbCwgdGV4
dCkgewogICAgICAgIGlmICghZWwpIHJldHVybjsKICAgICAgICBjb25zdCBxID0gU3RyaW5nKHF1
ZXJ5IHx8ICcnKS50cmltKCk7CiAgICAgICAgaWYgKCFxKSB7CiAgICAgICAgICAgIGVsLmNsYXNz
TGlzdC5yZW1vdmUoJ2hhcy1obCcpOwogICAgICAgICAgICBlbC50ZXh0Q29udGVudCA9IHRleHQg
PT0gbnVsbCA/ICcnIDogU3RyaW5nKHRleHQpOwogICAgICAgICAgICByZXR1cm47CiAgICAgICAg
fQogICAgICAgIGVsLmNsYXNzTGlzdC5hZGQoJ2hhcy1obCcpOwogICAgICAgIGVsLmlubmVySFRN
TCA9IGhsSHRtbCh0ZXh0KTsKICAgIH0KCgogICAgZnVuY3Rpb24gYXBwbHlUYWJTd2l0Y2hBbmlt
KCkgewogICAgICAgIGlmICghdGFiU3dpdGNoQW5pbURpciB8fCAhbGlzdEVsKSByZXR1cm47CiAg
ICAgICAgaWYgKCFsaXN0RWwucXVlcnlTZWxlY3RvcignLml0bSwgI2VtcHR5Lm9uLCAjbGlzdC1t
b3JlJykpCiAgICAgICAgICAgIHJldHVybjsKICAgICAgICBjb25zdCBkaXIgPSB0YWJTd2l0Y2hB
bmltRGlyOwogICAgICAgIHRhYlN3aXRjaEFuaW1EaXIgPSAwOwogICAgICAgIGxpc3RFbC5jbGFz
c0xpc3QucmVtb3ZlKCd0YWItaW4tbHInLCAndGFiLWluLXJsJyk7CiAgICAgICAgdm9pZCBsaXN0
RWwub2Zmc2V0V2lkdGg7CiAgICAgICAgbGlzdEVsLmNsYXNzTGlzdC5hZGQoZGlyID4gMCA/ICd0
YWItaW4tbHInIDogJ3RhYi1pbi1ybCcpOwogICAgICAgIGNsZWFyVGltZW91dChsaXN0RWwuX3Rh
YkFuaW1UaW1lcik7CiAgICAgICAgbGlzdEVsLl90YWJBbmltVGltZXIgPSBzZXRUaW1lb3V0KCgp
ID0+IHsKICAgICAgICAgICAgbGlzdEVsLmNsYXNzTGlzdC5yZW1vdmUoJ3RhYi1pbi1scicsICd0
YWItaW4tcmwnKTsKICAgICAgICB9LCA0MDApOwogICAgfQoKICAgIGZ1bmN0aW9uIHRhYkluZGV4
KHRhYikgewogICAgICAgIGNvbnN0IGkgPSBUQUJfT1JERVIuaW5kZXhPZih0YWIpOwogICAgICAg
IHJldHVybiBpID49IDAgPyBpIDogMDsKICAgIH0KCiAgICBmdW5jdGlvbiBtb3ZlVGFiSW5rKGlu
c3RhbnQsIHRhcmdldEVsKSB7CiAgICAgICAgY29uc3QgaW5rID0gZG9jdW1lbnQuZ2V0RWxlbWVu
dEJ5SWQoJ3RhYi1pbmsnKTsKICAgICAgICBjb25zdCB0YWJzID0gZG9jdW1lbnQuZ2V0RWxlbWVu
dEJ5SWQoJ3RhYnMnKTsKICAgICAgICBjb25zdCBlbCA9IHRhcmdldEVsIHx8IGRvY3VtZW50LnF1
ZXJ5U2VsZWN0b3IoJyN0YWJzIC50YWIub24nKTsKICAgICAgICBpZiAoIWluayB8fCAhdGFicyB8
fCAhZWwpIHJldHVybjsKICAgICAgICBjb25zdCB0ciA9IHRhYnMuZ2V0Qm91bmRpbmdDbGllbnRS
ZWN0KCk7CiAgICAgICAgY29uc3QgciA9IGVsLmdldEJvdW5kaW5nQ2xpZW50UmVjdCgpOwogICAg
ICAgIGNvbnN0IHggPSByLmxlZnQgLSB0ci5sZWZ0OwogICAgICAgIGNvbnN0IGggPSBNYXRoLm1h
eCgyMCwgTWF0aC5yb3VuZChyLmhlaWdodCkpOwogICAgICAgIGNvbnN0IHkgPSByLnRvcCAtIHRy
LnRvcDsKICAgICAgICBjb25zdCB3ID0gTWF0aC5tYXgoMjQsIHIud2lkdGgpOwogICAgICAgIGNv
bnN0IHBvcyA9ICd0cmFuc2xhdGUzZCgnICsgeCArICdweCwnICsgeSArICdweCwwKSc7CiAgICAg
ICAgaW5rLnN0eWxlLnRyYW5zZm9ybU9yaWdpbiA9ICdjZW50ZXIgYm90dG9tJzsKICAgICAgICBp
bmsuc3R5bGUud2lkdGggPSB3ICsgJ3B4JzsKICAgICAgICBpbmsuc3R5bGUuaGVpZ2h0ID0gaCAr
ICdweCc7CiAgICAgICAgaWYgKGluc3RhbnQpIHsKICAgICAgICAgICAgaW5rLnN0eWxlLnRyYW5z
aXRpb24gPSAnbm9uZSc7CiAgICAgICAgICAgIGluay5jbGFzc0xpc3QucmVtb3ZlKCdzcXVhc2gn
KTsKICAgICAgICAgICAgaW5rLnN0eWxlLnRyYW5zZm9ybSA9IHBvcyArICcgc2NhbGVYKDEpJzsK
ICAgICAgICAgICAgaW5rLm9mZnNldEhlaWdodDsKICAgICAgICAgICAgaW5rLnN0eWxlLnRyYW5z
aXRpb24gPSAnJzsKICAgICAgICAgICAgcmV0dXJuOwogICAgICAgIH0KICAgICAgICAvLyBTbmFw
IHRvIGhvdmVyZWQgdGFiLCBleHBhbmQgZnJvbSBib3R0b20tY2VudGVyIOKAlCBubyBzbGlkaW5n
IGJldHdlZW4gdGFicwogICAgICAgIGluay5zdHlsZS50cmFuc2l0aW9uID0gJ25vbmUnOwogICAg
ICAgIGluay5zdHlsZS50cmFuc2Zvcm0gPSBwb3MgKyAnIHNjYWxlWCgwLjAwMSknOwogICAgICAg
IGluay5vZmZzZXRIZWlnaHQ7CiAgICAgICAgaW5rLnN0eWxlLnRyYW5zaXRpb24gPSAnJzsKICAg
ICAgICBpbmsuY2xhc3NMaXN0LmFkZCgnc3F1YXNoJyk7CiAgICAgICAgaW5rLnN0eWxlLnRyYW5z
Zm9ybSA9IHBvcyArICcgc2NhbGVYKDEpJzsKICAgICAgICBjbGVhclRpbWVvdXQoaW5rLl9zcXVh
c2hUaW1lcik7CiAgICAgICAgaW5rLl9zcXVhc2hUaW1lciA9IHNldFRpbWVvdXQoKCkgPT4gaW5r
LmNsYXNzTGlzdC5yZW1vdmUoJ3NxdWFzaCcpLCAzNDApOwogICAgfQogICAgZnVuY3Rpb24gbWFy
a1RhYih0YWIsIGluc3RhbnQpIHsKICAgICAgICBkb2N1bWVudC5xdWVyeVNlbGVjdG9yQWxsKCcj
dGFicyAudGFiJykuZm9yRWFjaChlbCA9PgogICAgICAgICAgICBlbC5jbGFzc0xpc3QudG9nZ2xl
KCdvbicsIGVsLmRhdGFzZXQudGFiID09PSB0YWIpKTsKICAgICAgICBtb3ZlVGFiSW5rKCEhaW5z
dGFudCk7CiAgICB9CiAgICBmdW5jdGlvbiBiaW5kVGFiSW5rSG92ZXIoKSB7CiAgICAgICAgY29u
c3QgdGFicyA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd0YWJzJyk7CiAgICAgICAgaWYgKCF0
YWJzIHx8IHRhYnMuX2lua0hvdmVyQm91bmQpIHJldHVybjsKICAgICAgICB0YWJzLl9pbmtIb3Zl
ckJvdW5kID0gdHJ1ZTsKICAgICAgICB0YWJzLmFkZEV2ZW50TGlzdGVuZXIoJ3BvaW50ZXJvdmVy
JywgZSA9PiB7CiAgICAgICAgICAgIGNvbnN0IHRhYiA9IGUudGFyZ2V0LmNsb3Nlc3QoJy50YWIn
KTsKICAgICAgICAgICAgaWYgKCF0YWIgfHwgIXRhYnMuY29udGFpbnModGFiKSkgcmV0dXJuOwog
ICAgICAgICAgICBtb3ZlVGFiSW5rKGZhbHNlLCB0YWIpOwogICAgICAgIH0pOwogICAgICAgIHRh
YnMuYWRkRXZlbnRMaXN0ZW5lcigncG9pbnRlcmxlYXZlJywgZSA9PiB7CiAgICAgICAgICAgIGlm
IChlLnJlbGF0ZWRUYXJnZXQgJiYgdGFicy5jb250YWlucyhlLnJlbGF0ZWRUYXJnZXQpKSByZXR1
cm47CiAgICAgICAgICAgIG1vdmVUYWJJbmsoZmFsc2UpOwogICAgICAgIH0pOwogICAgfQpmdW5j
dGlvbiBzZXRUYWIodGFiKSB7CiAgICAgICAgaWYgKHRhYiA9PT0gY3VyVGFiKSByZXR1cm47CiAg
ICAgICAgY29uc3QgZnJvbSA9IHRhYkluZGV4KGN1clRhYik7CiAgICAgICAgY29uc3QgdG8gPSB0
YWJJbmRleCh0YWIpOwogICAgICAgIHRhYlN3aXRjaEFuaW1EaXIgPSB0byA+IGZyb20gPyAxIDog
KHRvIDwgZnJvbSA/IC0xIDogMCk7CiAgICAgICAgY3VyVGFiID0gdGFiOwogICAgICAgIGxvYWRp
bmdNb3JlID0gZmFsc2U7CiAgICAgICAgbWFya1RhYih0YWIpOwogICAgICAgIC8vIOaJk+W8gOaU
tuiXj+W5tuafpeeci+WQju+8jOa4hemZpOOAjOaWsOaUtuiXj+OAjee7v+eCuQogICAgICAgIGlm
ICh0YWIgPT09ICdwaW5uZWQnKQogICAgICAgICAgICBjbGVhckZhdlVuc2VlbigpOwoKICAgICAg
ICAvLyBLZWVwIHNlYXJjaCAidG9kYXkiIGZpbHRlciBpbiBzeW5jIHdoZW4gc2VhcmNoIGlzIG9w
ZW4KICAgICAgICB0cnkgewogICAgICAgICAgICBjb25zdCB3cmFwID0gZG9jdW1lbnQuZ2V0RWxl
bWVudEJ5SWQoJ3NlYXJjaC13cmFwJyk7CiAgICAgICAgICAgIGNvbnN0IGJ0blRvZGF5ID0gZG9j
dW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2J0bi10b2RheScpOwogICAgICAgICAgICBpZiAod3JhcCAm
JiB3cmFwLmNsYXNzTGlzdC5jb250YWlucygnb3BlbicpKSB7CiAgICAgICAgICAgICAgICBjb25z
dCB3YW50VG9kYXkgPSBmYWxzZTsKICAgICAgICAgICAgICAgIGlmICh0b2RheU9ubHkgIT09IHdh
bnRUb2RheSkgewogICAgICAgICAgICAgICAgICAgIHRvZGF5T25seSA9IHdhbnRUb2RheTsKICAg
ICAgICAgICAgICAgICAgICBpZiAoYnRuVG9kYXkpIGJ0blRvZGF5LmNsYXNzTGlzdC50b2dnbGUo
J29uJywgdG9kYXlPbmx5KTsKICAgICAgICAgICAgICAgIH0KICAgICAgICAgICAgfQogICAgICAg
IH0gY2F0Y2gge30KCiAgICAgICAgc2VsZWN0ZWRJZCA9IG51bGw7CiAgICAgICAgbXVsdGlJZHMg
PSBbXTsKICAgICAgICBsaXN0RWwuc2Nyb2xsVG9wID0gMDsKICAgICAgICBjb25zdCBoaXQgPSB2
aWV3TWVtLmdldCh2aWV3TWVtS2V5KHRhYiwgcXVlcnksIHRvZGF5T25seSkpOwogICAgICAgIGlm
IChoaXQgJiYgQXJyYXkuaXNBcnJheShoaXQuaXRlbXMpICYmIGhpdC5pdGVtcy5sZW5ndGgpIHsK
ICAgICAgICAgICAgYWxsQ2xpcHMgPSBoaXQuaXRlbXMuc2xpY2UoKTsKICAgICAgICAgICAgZGlz
a1RvdGFsID0gTnVtYmVyKGhpdC50b3RhbCkgfHwgaGl0Lml0ZW1zLmxlbmd0aDsKICAgICAgICAg
ICAgd2luZG93Ll9fd2FpdGluZ1ZpZXcgPSBmYWxzZTsKICAgICAgICAgICAgY2xlYXJXYWl0aW5n
RGF0YSgpOwogICAgICAgICAgICB3aW5kb3cuX19kYXRhUmVhZHkgPSB0cnVlOwogICAgICAgICAg
ICBob3N0UHVzaGVkT25jZSA9IHRydWU7CiAgICAgICAgICAgIHNhd05vbkVtcHR5ID0gdHJ1ZTsK
ICAgICAgICAgICAgcmVuZGVyKCk7CiAgICAgICAgICAgIGFwcGx5VGFiU3dpdGNoQW5pbSgpOwog
ICAgICAgICAgICAvLyBNZW1vcnkgcGFpbnQgZmlyc3Qg4oCUYmFja2dyb3VuZCBzb2Z0LXN5bmMg
a2VlcHMgQUhLIGluIHN0ZXAgd2l0aG91dCBkb3VibGUgcmVkcmF3CiAgICAgICAgICAgIHNvZnRS
ZXF1ZXN0VmlldygpOwogICAgICAgICAgICByZXR1cm47CiAgICAgICAgfQogICAgICAgIC8vIE5v
IGNhY2hlIHlldDoga2VlcCBjdXJyZW50IHJvd3Mg4oCUIE5FVkVSIHdpcGUgdG8gYmxhbmsgd2hp
dGUKICAgICAgICB3aW5kb3cuX193YWl0aW5nVmlldyA9IHRydWU7CiAgICAgICAgc2NoZWR1bGVE
ZWxheWVkU2tlbCgpOwogICAgICAgIGlmICghYWxsQ2xpcHMubGVuZ3RoKQogICAgICAgICAgICBy
ZW5kZXIoKTsKICAgICAgICByZXF1ZXN0VmlldygpOwogICAgICAgIGFwcGx5VGFiU3dpdGNoQW5p
bSgpOwogICAgfQoKICAgIG1vdmVUYWJJbmsodHJ1ZSk7CiAgICBiaW5kVGFiSW5rSG92ZXIoKTsK
ICAgIHRyeSB7IG5ldyBSZXNpemVPYnNlcnZlcigoKSA9PiBtb3ZlVGFiSW5rKHRydWUpKS5vYnNl
cnZlKGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd0YWJzJykpOyB9IGNhdGNoIHt9CiAgICB3aW5k
b3cuYWRkRXZlbnRMaXN0ZW5lcigncmVzaXplJywgKCkgPT4gbW92ZVRhYkluayh0cnVlKSk7Cgog
ICAgZnVuY3Rpb24gdXBkYXRlTW9yZUZvb3Rlcih0b3RhbCkgewogICAgICAgIGxldCBtb3JlRWwg
PSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbGlzdC1tb3JlJyk7CiAgICAgICAgY29uc3QgbG9h
ZGVkID0gYWxsQ2xpcHMubGVuZ3RoOwogICAgICAgIGlmIChsb2FkZWQgPj0gdG90YWwpIHsKICAg
ICAgICAgICAgaWYgKG1vcmVFbCkgbW9yZUVsLnJlbW92ZSgpOwogICAgICAgICAgICByZXR1cm47
CiAgICAgICAgfQogICAgICAgIGlmICghbW9yZUVsKSB7CiAgICAgICAgICAgIG1vcmVFbCA9IGRv
Y3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOwogICAgICAgICAgICBtb3JlRWwuaWQgPSAnbGlz
dC1tb3JlJzsKICAgICAgICAgICAgbW9yZUVsLmNsYXNzTmFtZSA9ICdsaXN0LW1vcmUnOwogICAg
ICAgICAgICBsaXN0RWwuYXBwZW5kQ2hpbGQobW9yZUVsKTsKICAgICAgICB9CiAgICAgICAgbW9y
ZUVsLnRleHRDb250ZW50ID0gJ+e7p+e7reS4i+a7keS7juejgeebmOWKoOi9ve+8iCcgKyBsb2Fk
ZWQgKyAnLycgKyB0b3RhbCArICfvvIknOwogICAgfQoKICAgIC8qKiBVcGRhdGUgYmFyIC8gcGlu
IGJhZGdlIHdpdGhvdXQgdG91Y2hpbmcgdGhlIGxpc3QgRE9NICovCiAgICBmdW5jdGlvbiByZWZy
ZXNoTGlzdENocm9tZSgpIHsKICAgICAgICBjb25zdCB2aXNpYmxlID0gdmlzaWJsZUxpc3QoKTsK
ICAgICAgICBjb25zdCBsb2FkZWQgPSBhbGxDbGlwcy5sZW5ndGg7CiAgICAgICAgY29uc3Qgc2hv
d25Db3VudCA9IHZpc2libGUubGVuZ3RoOwogICAgICAgIGxldCBwaW5uZWROID0gTnVtYmVyKHBp
bm5lZFRvdGFsKSB8fCAwOwogICAgICAgIGlmIChwaW5uZWROIDwgMSkgewogICAgICAgICAgICBp
ZiAoY3VyVGFiID09PSAncGlubmVkJykKICAgICAgICAgICAgICAgIHBpbm5lZE4gPSBNYXRoLm1h
eChOdW1iZXIoZGlza1RvdGFsKSB8fCAwLCBsb2FkZWQpOwogICAgICAgICAgICBlbHNlCiAgICAg
ICAgICAgICAgICBwaW5uZWROID0gYWxsQ2xpcHMuZmlsdGVyKGMgPT4gaXNQaW5uZWQoYykpLmxl
bmd0aDsKICAgICAgICB9CiAgICAgICAgdXBkYXRlUGluRG90KCk7CiAgICAgICAgbGV0IHNob3dU
b3RhbCA9IGRpc2tUb3RhbCA+IDAgPyBkaXNrVG90YWwgOiAobG9hZGVkIHx8IDApOwogICAgICAg
IGlmIChjdXJUYWIgPT09ICdwaW5uZWQnICYmIHBpbm5lZE4gPiBzaG93VG90YWwpCiAgICAgICAg
ICAgIHNob3dUb3RhbCA9IHBpbm5lZE47CiAgICAgICAgY29uc3QgcU9uID0gU3RyaW5nKHF1ZXJ5
IHx8ICcnKS50cmltKCkubGVuZ3RoID4gMDsKICAgICAgICBjb25zdCBiYXIgPSBkb2N1bWVudC5n
ZXRFbGVtZW50QnlJZCgnYmFyLXR4dCcpOwogICAgICAgIGlmIChiYXIpIHsKICAgICAgICAgICAg
YmFyLnRleHRDb250ZW50ID0gcU9uCiAgICAgICAgICAgICAgICA/IChzaG93bkNvdW50ICsgJyDm
naEnKQogICAgICAgICAgICAgICAgOiAoc2hvd1RvdGFsID4gbG9hZGVkID8gKHNob3duQ291bnQg
KyAnIC8gJyArIHNob3dUb3RhbCArICcg5p2hJykgOiAoc2hvd1RvdGFsICsgJyDmnaEnKSk7CiAg
ICAgICAgfQogICAgICAgIHVwZGF0ZU1vcmVGb290ZXIoZGlza1RvdGFsKTsKICAgICAgICB1cGRh
dGVUb3BCdG4oKTsKICAgIH0KCiAgICAvKioKICAgICAqIExvYWQtbW9yZTogYXBwZW5kIG9ubHkg
bmV3IERPTSBub2Rlcy4gRnVsbCByZW5kZXIoKSBudWtlcyBldmVyeSAuaXRtIGFuZAogICAgICog
cmVzdG9yZXMgc2Nyb2xsVG9wIOKAlCB0aGF0IGhpdGNoIGlzIHdoYXQgbWFrZXMgZHJhZ2dpbmcg
dGhlIHNjcm9sbGJhciBmZWVsIHN0aWNreS4KICAgICAqLwogICAgZnVuY3Rpb24gYXBwZW5kUmVu
ZGVyKHByZXZMZW4pIHsKICAgICAgICBjb25zdCB2aXNpYmxlID0gdmlzaWJsZUxpc3QoKTsKICAg
ICAgICBpZiAoIXZpc2libGUubGVuZ3RoKSB7CiAgICAgICAgICAgIHJlbmRlcigpOwogICAgICAg
ICAgICByZXR1cm4gZmFsc2U7CiAgICAgICAgfQogICAgICAgIGlmIChwcmV2TGVuID4gMCAmJiBw
cmV2TGVuIDwgYWxsQ2xpcHMubGVuZ3RoKSB7CiAgICAgICAgICAgIGNvbnN0IHNlYW1HaWRzID0g
bmV3IFNldCgpOwogICAgICAgICAgICBmb3IgKGxldCBpID0gTWF0aC5tYXgoMCwgcHJldkxlbiAt
IDgpOyBpIDwgTWF0aC5taW4oYWxsQ2xpcHMubGVuZ3RoLCBwcmV2TGVuICsgOCk7IGkrKykgewog
ICAgICAgICAgICAgICAgY29uc3QgZyA9IGZhdkdyb3VwT2YoYWxsQ2xpcHNbaV0pOwogICAgICAg
ICAgICAgICAgaWYgKGcpIHNlYW1HaWRzLmFkZChnKTsKICAgICAgICAgICAgfQogICAgICAgICAg
ICBpZiAoc2VhbUdpZHMuc2l6ZSkgewogICAgICAgICAgICAgICAgZm9yIChjb25zdCBnIG9mIHNl
YW1HaWRzKSB7CiAgICAgICAgICAgICAgICAgICAgbGV0IGJlZm9yZSA9IDAsIGFmdGVyID0gMDsK
ICAgICAgICAgICAgICAgICAgICBmb3IgKGxldCBpID0gMDsgaSA8IGFsbENsaXBzLmxlbmd0aDsg
aSsrKSB7CiAgICAgICAgICAgICAgICAgICAgICAgIGlmIChmYXZHcm91cE9mKGFsbENsaXBzW2ld
KSAhPT0gZykgY29udGludWU7CiAgICAgICAgICAgICAgICAgICAgICAgIGlmIChpIDwgcHJldkxl
bikgYmVmb3JlKys7CiAgICAgICAgICAgICAgICAgICAgICAgIGVsc2UgYWZ0ZXIrKzsKICAgICAg
ICAgICAgICAgICAgICB9CiAgICAgICAgICAgICAgICAgICAgaWYgKGJlZm9yZSA+IDAgJiYgYWZ0
ZXIgPiAwKSB7CiAgICAgICAgICAgICAgICAgICAgICAgIHJlbmRlcigpOwogICAgICAgICAgICAg
ICAgICAgICAgICByZXR1cm4gZmFsc2U7CiAgICAgICAgICAgICAgICAgICAgfQogICAgICAgICAg
ICAgICAgfQogICAgICAgICAgICB9CiAgICAgICAgfQogICAgICAgIGNvbnN0IGJsb2NrcyA9IGJ1
aWxkUGlubmVkQmxvY2tzKHZpc2libGUpOwogICAgICAgIGNvbnN0IGV4aXN0aW5nID0gbGlzdEVs
LnF1ZXJ5U2VsZWN0b3JBbGwoJy5pdG0nKS5sZW5ndGg7CiAgICAgICAgaWYgKGV4aXN0aW5nIDwg
MSkgewogICAgICAgICAgICByZW5kZXIoKTsKICAgICAgICAgICAgcmV0dXJuIGZhbHNlOwogICAg
ICAgIH0KICAgICAgICBpZiAoYmxvY2tzLmxlbmd0aCA8PSBleGlzdGluZykgewogICAgICAgICAg
ICByZWZyZXNoTGlzdENocm9tZSgpOwogICAgICAgICAgICB0cnkgeyBtYXJrUXVldWVSYWlscygp
OyB9IGNhdGNoIChlKSB7fQogICAgICAgICAgICByZXR1cm4gdHJ1ZTsKICAgICAgICB9CiAgICAg
ICAgY29uc3QgZnJhZyA9IGRvY3VtZW50LmNyZWF0ZURvY3VtZW50RnJhZ21lbnQoKTsKICAgICAg
ICBsZXQgbnVtID0gMDsKICAgICAgICBibG9ja3MuZm9yRWFjaChiID0+IHsKICAgICAgICAgICAg
bnVtICs9IDE7CiAgICAgICAgICAgIGlmIChudW0gPD0gZXhpc3RpbmcpIHJldHVybjsKICAgICAg
ICAgICAgaWYgKGIua2luZCA9PT0gJ2dyb3VwJyAmJiBiLml0ZW1zLmxlbmd0aCA+IDEpCiAgICAg
ICAgICAgICAgICBmcmFnLmFwcGVuZENoaWxkKG1ha2VHcm91cEl0ZW0oYi5pdGVtcywgbnVtKSk7
CiAgICAgICAgICAgIGVsc2UKICAgICAgICAgICAgICAgIGZyYWcuYXBwZW5kQ2hpbGQobWFrZUl0
ZW0oYi5pdGVtc1swXSwgbnVtKSk7CiAgICAgICAgfSk7CiAgICAgICAgY29uc3QgbW9yZUVsID0g
ZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2xpc3QtbW9yZScpOwogICAgICAgIGlmIChtb3JlRWwp
CiAgICAgICAgICAgIGxpc3RFbC5pbnNlcnRCZWZvcmUoZnJhZywgbW9yZUVsKTsKICAgICAgICBl
bHNlCiAgICAgICAgICAgIGxpc3RFbC5hcHBlbmRDaGlsZChmcmFnKTsKICAgICAgICB0cnkgeyBt
YXJrUXVldWVSYWlscygpOyB9IGNhdGNoIChlKSB7fQogICAgICAgIHJlZnJlc2hMaXN0Q2hyb21l
KCk7CiAgICAgICAgcmVxdWVzdEFuaW1hdGlvbkZyYW1lKCgpID0+IHsKICAgICAgICAgICAgaWYg
KGFsbENsaXBzLmxlbmd0aCA8IGRpc2tUb3RhbAogICAgICAgICAgICAgICAgJiYgbGlzdEVsLnNj
cm9sbEhlaWdodCA8PSBsaXN0RWwuY2xpZW50SGVpZ2h0ICsgMjApCiAgICAgICAgICAgICAgICBy
ZXF1ZXN0TW9yZSgpOwogICAgICAgICAgICB0cnkgeyBzY2hlZHVsZUZpbGVHb25lQ2hlY2soKTsg
fSBjYXRjaCB7fQogICAgICAgIH0pOwogICAgICAgIHJldHVybiB0cnVlOwogICAgfQoKICAgIGZ1
bmN0aW9uIGFwcGx5QXBwZW5kUGF5bG9hZChwZW5kaW5nKSB7CiAgICAgICAgaWYgKCFwZW5kaW5n
IHx8IHBlbmRpbmcuZnJvbUxlbiA9PSBudWxsKSByZXR1cm47CiAgICAgICAgY29uc3QgZnJvbUxl
biA9IE51bWJlcihwZW5kaW5nLmZyb21MZW4pIHx8IDA7CiAgICAgICAgaWYgKGZyb21MZW4gPCAw
IHx8IGFsbENsaXBzLmxlbmd0aCA8PSBmcm9tTGVuKSB7CiAgICAgICAgICAgIHJlZnJlc2hMaXN0
Q2hyb21lKCk7CiAgICAgICAgICAgIHJldHVybjsKICAgICAgICB9CiAgICAgICAgYXBwZW5kUmVu
ZGVyKGZyb21MZW4pOwogICAgfQoKICAgIGZ1bmN0aW9uIG5hdkxpc3QoKSB7CiAgICAgICAgY29u
c3QgYmxvY2tzID0gYnVpbGRQaW5uZWRCbG9ja3ModmlzaWJsZUxpc3QoKSk7CiAgICAgICAgY29u
c3Qgb3V0ID0gW107CiAgICAgICAgZm9yIChjb25zdCBiIG9mIGJsb2NrcykgewogICAgICAgICAg
ICBpZiAoIWIgfHwgIWIuaXRlbXMpIGNvbnRpbnVlOwogICAgICAgICAgICBmb3IgKGNvbnN0IGMg
b2YgYi5pdGVtcykgb3V0LnB1c2goYyk7CiAgICAgICAgfQogICAgICAgIHJldHVybiBvdXQ7CiAg
ICB9CgogICAgZnVuY3Rpb24gc2VsZWN0QnlJbmRleChpZHgpIHsKICAgICAgICBjb25zdCB2aXMg
PSBuYXZMaXN0KCk7CiAgICAgICAgaWYgKCF2aXMubGVuZ3RoKSByZXR1cm47CiAgICAgICAgaWR4
ID0gTWF0aC5tYXgoMCwgTWF0aC5taW4odmlzLmxlbmd0aCAtIDEsIGlkeCkpOwogICAgICAgIGlm
IChpZHggPj0gdmlzLmxlbmd0aCAtIDEgJiYgYWxsQ2xpcHMubGVuZ3RoIDwgZGlza1RvdGFsKQog
ICAgICAgICAgICByZXF1ZXN0TW9yZSgpOwogICAgICAgIHNlbGVjdGVkSWQgPSB2aXNbTWF0aC5t
aW4oaWR4LCB2aXMubGVuZ3RoIC0gMSldLmlkOwogICAgICAgIHJhbmdlQW5jaG9ySWQgPSBzZWxl
Y3RlZElkOwogICAgICAgIHJhbmdlQW5jaG9yQ2xpY2tlZCA9IGZhbHNlOwogICAgICAgIGlmICgr
c2VsZWN0ZWRJZCAhPT0gK2xhc3RQYXN0ZUlkKQogICAgICAgICAgICBsb2NhdGVBY3RpdmUgPSBm
YWxzZTsKICAgICAgICB1cGRhdGVMb2NhdGVCdG4oKTsKICAgICAgICBzeW5jSXRlbUhpZ2hsaWdo
dCgpOwogICAgICAgIGNvbnN0IGVsID0gbGlzdEVsLnF1ZXJ5U2VsZWN0b3IoJy5tZy1yb3dbZGF0
YS1pZD0iJyArIHNlbGVjdGVkSWQgKyAnIl0nKQogICAgICAgICAgICB8fCBsaXN0RWwucXVlcnlT
ZWxlY3RvcignLml0bVtkYXRhLWlkPSInICsgc2VsZWN0ZWRJZCArICciXScpOwogICAgICAgIGlm
IChlbCkgZWwuc2Nyb2xsSW50b1ZpZXcoeyBibG9jazogJ25lYXJlc3QnIH0pOwogICAgfQoKICAg
IGZ1bmN0aW9uIHNlbGVjdGVkSW5kZXgoKSB7CiAgICAgICAgcmV0dXJuIG5hdkxpc3QoKS5maW5k
SW5kZXgoYyA9PiBjLmlkID09IHNlbGVjdGVkSWQpOwogICAgfQoKICAgIGZ1bmN0aW9uIHN5bmNJ
dGVtSGlnaGxpZ2h0KCkgewogICAgICAgIGRvY3VtZW50LnF1ZXJ5U2VsZWN0b3JBbGwoJy5pdG0n
KS5mb3JFYWNoKG4gPT4gewogICAgICAgICAgICBpZiAobi5jbGFzc0xpc3QuY29udGFpbnMoJ2l0
LWdyb3VwJykpIHsKICAgICAgICAgICAgICAgIGNvbnN0IHJvd3MgPSBbLi4ubi5xdWVyeVNlbGVj
dG9yQWxsKCcubWctcm93JyldOwogICAgICAgICAgICAgICAgY29uc3QgaWRzID0gcm93cy5tYXAo
ciA9PiArci5kYXRhc2V0LmlkKTsKICAgICAgICAgICAgICAgIGNvbnN0IGFueVNlbCA9IGlkcy5p
bmNsdWRlcygrc2VsZWN0ZWRJZCkgfHwgaWRzLnNvbWUoaWQgPT4gbXVsdGlJZHMuaW5jbHVkZXMo
aWQpKTsKICAgICAgICAgICAgICAgIG4uY2xhc3NMaXN0LnRvZ2dsZSgnc2VsJywgYW55U2VsKTsK
ICAgICAgICAgICAgICAgIG4uY2xhc3NMaXN0LnRvZ2dsZSgnbXVsdGknLCBpZHMuc29tZShpZCA9
PiBtdWx0aUlkcy5pbmNsdWRlcyhpZCkpKTsKICAgICAgICAgICAgICAgIHJvd3MuZm9yRWFjaChy
ID0+IHsKICAgICAgICAgICAgICAgICAgICBjb25zdCBpZCA9ICtyLmRhdGFzZXQuaWQ7CiAgICAg
ICAgICAgICAgICAgICAgY29uc3QgaW5NdWx0aSA9IG11bHRpSWRzLmluY2x1ZGVzKGlkKTsKICAg
ICAgICAgICAgICAgICAgICByLmNsYXNzTGlzdC50b2dnbGUoJ3NlbCcsIGlkID09IHNlbGVjdGVk
SWQgfHwgaW5NdWx0aSk7CiAgICAgICAgICAgICAgICAgICAgci5jbGFzc0xpc3QudG9nZ2xlKCdt
dWx0aScsIGluTXVsdGkpOwogICAgICAgICAgICAgICAgfSk7CiAgICAgICAgICAgICAgICByZXR1
cm47CiAgICAgICAgICAgIH0KICAgICAgICAgICAgY29uc3QgaWQgPSArbi5kYXRhc2V0LmlkOwog
ICAgICAgICAgICBjb25zdCBpbk11bHRpID0gbXVsdGlJZHMuaW5jbHVkZXMoaWQpOwogICAgICAg
ICAgICBuLmNsYXNzTGlzdC50b2dnbGUoJ3NlbCcsIGlkID09IHNlbGVjdGVkSWQgfHwgaW5NdWx0
aSk7CiAgICAgICAgICAgIG4uY2xhc3NMaXN0LnRvZ2dsZSgnbXVsdGknLCBpbk11bHRpKTsKICAg
ICAgICB9KTsKICAgIH0KICAgIGZ1bmN0aW9uIHVwZGF0ZU11bHRpQmFkZ2UoKSB7CiAgICAgICAg
Y29uc3QgYmFyID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ211bHRpLWJhcicpOwogICAgICAg
IGNvbnN0IGVsID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ211bHRpLWNudCcpOwogICAgICAg
IGlmIChtdWx0aUlkcy5sZW5ndGggPiAwKSB7CiAgICAgICAgICAgIGlmIChlbCkgZWwudGV4dENv
bnRlbnQgPSBTdHJpbmcobXVsdGlJZHMubGVuZ3RoKTsKICAgICAgICAgICAgaWYgKGJhcikgewog
ICAgICAgICAgICAgICAgY29uc3Qgd2FzT2ZmID0gIWJhci5jbGFzc0xpc3QuY29udGFpbnMoJ29u
Jyk7CiAgICAgICAgICAgICAgICBiYXIuY2xhc3NMaXN0LmFkZCgnb24nKTsKICAgICAgICAgICAg
ICAgIGlmICh3YXNPZmYpIHJlc2V0UGFzdGVTZXBEZWZhdWx0KCk7CiAgICAgICAgICAgIH0KICAg
ICAgICB9IGVsc2UgewogICAgICAgICAgICBpZiAoYmFyKSBiYXIuY2xhc3NMaXN0LnJlbW92ZSgn
b24nKTsKICAgICAgICAgICAgY2xvc2VTZXBNZW51KCk7CiAgICAgICAgfQogICAgICAgIHN5bmNJ
dGVtSGlnaGxpZ2h0KCk7CiAgICB9CgogICAgY29uc3QgU0VQX05FV0xJTkVfVE9LRU4gPSAnW+aN
ouihjF0nOwogICAgLy8g5Zu65a6a5bi455So5YiG6ZqU56ym77yb6Ieq5a6a5LmJ5LiN6L+b5YiX
6KGoCiAgICBjb25zdCBTRVBfTElTVCA9IFsnICcsIFNFUF9ORVdMSU5FX1RPS0VOLCAnLCcsICcs
ICcsICfjgIEnLCAnfCcsICdbIiIsIiJdJywgIignJywnJykiXTsKICAgIGxldCBwYXN0ZVNlcFZh
bHVlID0gJyAnOwoKICAgIGZ1bmN0aW9uIG5vcm1hbGl6ZVNlcElucHV0KHJhdykgewogICAgICAg
IGxldCBzID0gU3RyaW5nKHJhdyA/PyAnJyk7CiAgICAgICAgaWYgKHMgPT09ICcnKSByZXR1cm4g
JyAnOwogICAgICAgIGNvbnN0IHQgPSBzLnRyaW0oKTsKICAgICAgICBpZiAodCA9PT0gU0VQX05F
V0xJTkVfVE9LRU4gfHwgdCA9PT0gJ+aNouihjCcgfHwgdCA9PT0gJ1xcbicgfHwgdCA9PT0gJ1xu
JyB8fCB0ID09PSAnXHJcbicpCiAgICAgICAgICAgIHJldHVybiBTRVBfTkVXTElORV9UT0tFTjsK
ICAgICAgICBpZiAodCA9PT0gJ1xcdCcgfHwgdCA9PT0gJ1x0JykgcmV0dXJuICdcdCc7CiAgICAg
ICAgcmV0dXJuIHM7CiAgICB9CiAgICBmdW5jdGlvbiBzZXBUb0FjdHVhbChyYXcpIHsKICAgICAg
ICBjb25zdCBzID0gbm9ybWFsaXplU2VwSW5wdXQocmF3KTsKICAgICAgICByZXR1cm4gcyA9PT0g
U0VQX05FV0xJTkVfVE9LRU4gPyAnXG4nIDogczsKICAgIH0KICAgIGZ1bmN0aW9uIHNlcFRvQnJp
ZGdlKHJhdykgewogICAgICAgIGNvbnN0IHMgPSBub3JtYWxpemVTZXBJbnB1dChyYXcpOwogICAg
ICAgIGlmIChzID09PSBTRVBfTkVXTElORV9UT0tFTiB8fCBzID09PSAnXG4nIHx8IHMgPT09ICdc
clxuJykgcmV0dXJuIFNFUF9ORVdMSU5FX1RPS0VOOwogICAgICAgIGlmIChzID09PSAnXHQnKSBy
ZXR1cm4gJ1vliLbooajnrKZdJzsKICAgICAgICByZXR1cm4gczsKICAgIH0KICAgIGZ1bmN0aW9u
IHNlcERpc3BsYXlTeW1ib2wocmF3KSB7CiAgICAgICAgY29uc3QgcyA9IG5vcm1hbGl6ZVNlcElu
cHV0KHJhdyk7CiAgICAgICAgaWYgKHMgPT09ICcgJykgcmV0dXJuICfikKMnOwogICAgICAgIGlm
IChzID09PSBTRVBfTkVXTElORV9UT0tFTiB8fCBzID09PSAnXG4nIHx8IHMgPT09ICdcclxuJykg
cmV0dXJuICfihrUnOwogICAgICAgIGlmIChzID09PSAnXHQnKSByZXR1cm4gJ+KHpSc7CiAgICAg
ICAgaWYgKHMgPT09ICcsJykgcmV0dXJuICcsJzsKICAgICAgICBpZiAocyA9PT0gJywgJykgcmV0
dXJuICcs4pCjJzsKICAgICAgICBpZiAocyA9PT0gJ+OAgScpIHJldHVybiAn44CBJzsKICAgICAg
ICBpZiAocyA9PT0gJ3wnKSByZXR1cm4gJ3wnOwogICAgICAgIGlmIChzID09PSAnWyIiLCIiXScp
IHJldHVybiAnWyIiLCIiXSc7CiAgICAgICAgaWYgKHMgPT09ICIoJycsJycpIikgcmV0dXJuICIo
JycsJycpIjsKICAgICAgICByZXR1cm4gcy5yZXBsYWNlKC9cclxuL2csICfihrUnKS5yZXBsYWNl
KC9cbi9nLCAn4oa1JykucmVwbGFjZSgvXHQvZywgJ+KHpScpLnJlcGxhY2UoL1xyL2csICcnKTsK
ICAgIH0KICAgIGZ1bmN0aW9uIHNlcERpc3BsYXlOYW1lKHJhdykgewogICAgICAgIGNvbnN0IHMg
PSBub3JtYWxpemVTZXBJbnB1dChyYXcpOwogICAgICAgIGlmIChzID09PSAnICcpIHJldHVybiAn
56m65qC8JzsKICAgICAgICBpZiAocyA9PT0gU0VQX05FV0xJTkVfVE9LRU4gfHwgcyA9PT0gJ1xu
JyB8fCBzID09PSAnXHJcbicpIHJldHVybiAn5o2i6KGMJzsKICAgICAgICBpZiAocyA9PT0gJ1x0
JykgcmV0dXJuICfliLbooajnrKYnOwogICAgICAgIGlmIChzID09PSAnLCcpIHJldHVybiAn6YCX
5Y+3JzsKICAgICAgICBpZiAocyA9PT0gJywgJykgcmV0dXJuICfpgJflj7fnqbrmoLwnOwogICAg
ICAgIGlmIChzID09PSAn44CBJykgcmV0dXJuICfpob/lj7cnOwogICAgICAgIGlmIChzID09PSAn
fCcpIHJldHVybiAn56uW57q/JzsKICAgICAgICBpZiAocyA9PT0gJ1siIiwiIl0nKSByZXR1cm4g
J+WIl+ihqDEnOwogICAgICAgIGlmIChzID09PSAiKCcnLCcnKSIpIHJldHVybiAn5YiX6KGoMic7
CiAgICAgICAgcmV0dXJuICcnOwogICAgfQogICAgZnVuY3Rpb24gZmlsbFNlcE1lbnVJdGVtKGJ0
biwgdikgewogICAgICAgIGJ0bi5pbm5lckhUTUwgPSAnJzsKICAgICAgICBjb25zdCBzeW0gPSBk
b2N1bWVudC5jcmVhdGVFbGVtZW50KCdzcGFuJyk7CiAgICAgICAgc3ltLmNsYXNzTmFtZSA9ICdw
YXN0ZS1zZXAtc3ltJyArIChzZXBEaXNwbGF5TmFtZSh2KSA/ICcnIDogJyBvbmx5Jyk7CiAgICAg
ICAgc3ltLnRleHRDb250ZW50ID0gc2VwRGlzcGxheVN5bWJvbCh2KTsKICAgICAgICBidG4uYXBw
ZW5kQ2hpbGQoc3ltKTsKICAgICAgICBjb25zdCBuYW1lID0gc2VwRGlzcGxheU5hbWUodik7CiAg
ICAgICAgaWYgKG5hbWUpIHsKICAgICAgICAgICAgY29uc3QgbGFiID0gZG9jdW1lbnQuY3JlYXRl
RWxlbWVudCgnc3BhbicpOwogICAgICAgICAgICBsYWIuY2xhc3NOYW1lID0gJ3Bhc3RlLXNlcC1u
YW1lJzsKICAgICAgICAgICAgbGFiLnRleHRDb250ZW50ID0gbmFtZTsKICAgICAgICAgICAgYnRu
LmFwcGVuZENoaWxkKGxhYik7CiAgICAgICAgfQogICAgfQogICAgZnVuY3Rpb24gdXBkYXRlU2Vw
TGFiZWwoKSB7CiAgICAgICAgY29uc3QgbGFiID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3Bh
c3RlLXNlcC1sYWJlbCcpOwogICAgICAgIGlmIChsYWIpIGxhYi50ZXh0Q29udGVudCA9IHNlcERp
c3BsYXlTeW1ib2wocGFzdGVTZXBWYWx1ZSk7CiAgICB9CiAgICBmdW5jdGlvbiBhcHBseVNlcGFy
YXRvcihyYXcsIG9wdHMgPSB7fSkgewogICAgICAgIGNvbnN0IGRvUGFzdGUgPSBvcHRzLnBhc3Rl
ICE9IG51bGwgPyBvcHRzLnBhc3RlIDogbXVsdGlJZHMubGVuZ3RoID4gMDsKICAgICAgICBwYXN0
ZVNlcFZhbHVlID0gbm9ybWFsaXplU2VwSW5wdXQocmF3KTsKICAgICAgICB1cGRhdGVTZXBMYWJl
bCgpOwogICAgICAgIGNsb3NlU2VwTWVudSgpOwogICAgICAgIGlmIChkb1Bhc3RlKSBwYXN0ZU11
bHRpU2VsZWN0aW9uKCk7CiAgICB9CiAgICBmdW5jdGlvbiBjbG9zZVNlcE1lbnUoKSB7CiAgICAg
ICAgY29uc3QgbWVudSA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdwYXN0ZS1zZXAtbWVudScp
OwogICAgICAgIGNvbnN0IGJ0biA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdwYXN0ZS1zZXAt
YnRuJyk7CiAgICAgICAgaWYgKG1lbnUpIG1lbnUuY2xhc3NMaXN0LnJlbW92ZSgnb24nKTsKICAg
ICAgICBpZiAoYnRuKSBidG4uY2xhc3NMaXN0LnJlbW92ZSgnb3BlbicpOwogICAgfQogICAgZnVu
Y3Rpb24gcmVuZGVyU2VwTWVudSgpIHsKICAgICAgICBjb25zdCBtZW51ID0gZG9jdW1lbnQuZ2V0
RWxlbWVudEJ5SWQoJ3Bhc3RlLXNlcC1tZW51Jyk7CiAgICAgICAgaWYgKCFtZW51KSByZXR1cm47
CiAgICAgICAgbWVudS5pbm5lckhUTUwgPSAnJzsKICAgICAgICBmb3IgKGNvbnN0IHYgb2YgU0VQ
X0xJU1QpIHsKICAgICAgICAgICAgY29uc3QgYiA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2J1
dHRvbicpOwogICAgICAgICAgICBiLnR5cGUgPSAnYnV0dG9uJzsKICAgICAgICAgICAgYi5jbGFz
c05hbWUgPSAncGFzdGUtc2VwLWl0ZW0nICsgKHYgPT09IHBhc3RlU2VwVmFsdWUgPyAnIHNlbCcg
OiAnJyk7CiAgICAgICAgICAgIGZpbGxTZXBNZW51SXRlbShiLCB2KTsKICAgICAgICAgICAgYi5v
bmNsaWNrID0gZSA9PiB7CiAgICAgICAgICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAg
ICAgICAgICAgICAgYXBwbHlTZXBhcmF0b3Iodik7CiAgICAgICAgICAgIH07CiAgICAgICAgICAg
IG1lbnUuYXBwZW5kQ2hpbGQoYik7CiAgICAgICAgfQogICAgICAgIGNvbnN0IGZvb3QgPSBkb2N1
bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsKICAgICAgICBmb290LmNsYXNzTmFtZSA9ICdwYXN0
ZS1zZXAtZm9vdCc7CiAgICAgICAgY29uc3QgaW5wID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgn
aW5wdXQnKTsKICAgICAgICBpbnAuaWQgPSAncGFzdGUtc2VwLWN1c3RvbSc7CiAgICAgICAgaW5w
LnR5cGUgPSAndGV4dCc7CiAgICAgICAgaW5wLnNpemUgPSAxOwogICAgICAgIGlucC5wbGFjZWhv
bGRlciA9ICfoh6rlrprkuYknOwogICAgICAgIGlucC5hdXRvY29tcGxldGUgPSAnb2ZmJzsKICAg
ICAgICBpbnAuc3BlbGxjaGVjayA9IGZhbHNlOwogICAgICAgIGlucC52YWx1ZSA9IFNFUF9MSVNU
LmluY2x1ZGVzKHBhc3RlU2VwVmFsdWUpID8gJycgOiBwYXN0ZVNlcFZhbHVlOwogICAgICAgIGlu
cC5vbm1vdXNlZG93biA9IGUgPT4gewogICAgICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwog
ICAgICAgICAgICBlLnByZXZlbnREZWZhdWx0KCk7CiAgICAgICAgICAgIHRyeSB7IGFoaygnZm9j
dXNQYW5lbCcpOyB9IGNhdGNoIHt9CiAgICAgICAgICAgIGlucC5mb2N1cygpOwogICAgICAgIH07
CiAgICAgICAgaW5wLm9uY2xpY2sgPSBlID0+IGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAgICAg
aW5wLm9uZm9jdXMgPSAoKSA9PiB7IHRyeSB7IGFoaygnZm9jdXNQYW5lbCcpOyB9IGNhdGNoIHt9
IH07CiAgICAgICAgaW5wLm9uaW5wdXQgPSBlID0+IGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAg
ICAgaW5wLm9ua2V5ZG93biA9IGUgPT4gewogICAgICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigp
OwogICAgICAgICAgICBpZiAoZS5rZXkgPT09ICdFbnRlcicpIHsKICAgICAgICAgICAgICAgIGUu
cHJldmVudERlZmF1bHQoKTsKICAgICAgICAgICAgICAgIGlmIChpbnAudmFsdWUgIT09ICcnKSBh
cHBseVNlcGFyYXRvcihpbnAudmFsdWUpOwogICAgICAgICAgICAgICAgZWxzZSBjbG9zZVNlcE1l
bnUoKTsKICAgICAgICAgICAgfSBlbHNlIGlmIChlLmtleSA9PT0gJ0VzY2FwZScpIHsKICAgICAg
ICAgICAgICAgIGUucHJldmVudERlZmF1bHQoKTsKICAgICAgICAgICAgICAgIGNsb3NlU2VwTWVu
dSgpOwogICAgICAgICAgICB9CiAgICAgICAgfTsKICAgICAgICBmb290LmFwcGVuZENoaWxkKGlu
cCk7CiAgICAgICAgbWVudS5hcHBlbmRDaGlsZChmb290KTsKICAgIH0KICAgIGZ1bmN0aW9uIHJl
c2V0UGFzdGVTZXBEZWZhdWx0KCkgewogICAgICAgIHBhc3RlU2VwVmFsdWUgPSAnICc7CiAgICAg
ICAgdXBkYXRlU2VwTGFiZWwoKTsKICAgICAgICBjbG9zZVNlcE1lbnUoKTsKICAgIH0KICAgIGZ1
bmN0aW9uIHBhc3RlTWFueVdpdGhTZXAoaWRzKSB7CiAgICAgICAgYWhrKCdwYXN0ZU1hbnknLCBp
ZHMuam9pbignLCcpLCBzZXBUb0JyaWRnZShwYXN0ZVNlcFZhbHVlKSk7CiAgICB9CiAgICBmdW5j
dGlvbiBwYXN0ZU11bHRpU2VsZWN0aW9uKCkgewogICAgICAgIGlmICghbXVsdGlJZHMubGVuZ3Ro
KSByZXR1cm47CiAgICAgICAgY29uc3QgaWRzID0gbXVsdGlJZHMuc2xpY2UoKTsKICAgICAgICBj
bGVhck11bHRpKCk7CiAgICAgICAgaWYgKGlkcy5zb21lKGlkID0+IHsKICAgICAgICAgICAgY29u
c3QgaXQgPSBhbGxDbGlwcy5maW5kKHggPT4gK3guaWQgPT09ICtpZCk7CiAgICAgICAgICAgIHJl
dHVybiBpdCAmJiBub3JtVHlwZShpdC50eXBlKSA9PT0gJ3JlY2VudCc7CiAgICAgICAgfSkpIHsK
ICAgICAgICAgICAgY29uc3QgZmlyc3QgPSBhbGxDbGlwcy5maW5kKHggPT4gK3guaWQgPT09ICtp
ZHNbMF0pOwogICAgICAgICAgICBpZiAoZmlyc3QpIGFjdGl2YXRlQ2xpcEl0ZW0oZmlyc3QpOwog
ICAgICAgICAgICByZXR1cm47CiAgICAgICAgfQogICAgICAgIG1hcmtQYXN0ZWRMb2NhbChpZHMp
OwogICAgICAgIHBhc3RlTWFueVdpdGhTZXAoaWRzKTsKICAgIH0KICAgIGZ1bmN0aW9uIGluaXRT
ZXBVaSgpIHsKICAgICAgICB1cGRhdGVTZXBMYWJlbCgpOwogICAgICAgIGNvbnN0IGJ0biA9IGRv
Y3VtZW50LmdldEVsZW1lbnRCeUlkKCdwYXN0ZS1zZXAtYnRuJyk7CiAgICAgICAgaWYgKGJ0bikg
ewogICAgICAgICAgICBidG4uYWRkRXZlbnRMaXN0ZW5lcignY2xpY2snLCBlID0+IHsKICAgICAg
ICAgICAgICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAgICAgICAgICAgICBjb25zdCBtZW51
ID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3Bhc3RlLXNlcC1tZW51Jyk7CiAgICAgICAgICAg
ICAgICBjb25zdCBvcGVuID0gbWVudSAmJiBtZW51LmNsYXNzTGlzdC5jb250YWlucygnb24nKTsK
ICAgICAgICAgICAgICAgIGlmIChvcGVuKSB7CiAgICAgICAgICAgICAgICAgICAgY29uc3QgaW5w
ID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3Bhc3RlLXNlcC1jdXN0b20nKTsKICAgICAgICAg
ICAgICAgICAgICBpZiAoaW5wICYmIGlucC52YWx1ZSAhPT0gJycpIGFwcGx5U2VwYXJhdG9yKGlu
cC52YWx1ZSwgeyBwYXN0ZTogbXVsdGlJZHMubGVuZ3RoID4gMCB9KTsKICAgICAgICAgICAgICAg
ICAgICBlbHNlIGNsb3NlU2VwTWVudSgpOwogICAgICAgICAgICAgICAgICAgIHJldHVybjsKICAg
ICAgICAgICAgICAgIH0KICAgICAgICAgICAgICAgIHJlbmRlclNlcE1lbnUoKTsKICAgICAgICAg
ICAgICAgIG1lbnUuY2xhc3NMaXN0LmFkZCgnb24nKTsKICAgICAgICAgICAgICAgIGJ0bi5jbGFz
c0xpc3QuYWRkKCdvcGVuJyk7CiAgICAgICAgICAgIH0pOwogICAgICAgIH0KICAgICAgICBkb2N1
bWVudC5hZGRFdmVudExpc3RlbmVyKCdtb3VzZWRvd24nLCBlID0+IHsKICAgICAgICAgICAgaWYg
KGUudGFyZ2V0LmNsb3Nlc3QoJyNwYXN0ZS1zZXAtd3JhcCcpKSByZXR1cm47CiAgICAgICAgICAg
IGNvbnN0IG1lbnUgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgncGFzdGUtc2VwLW1lbnUnKTsK
ICAgICAgICAgICAgaWYgKCFtZW51IHx8ICFtZW51LmNsYXNzTGlzdC5jb250YWlucygnb24nKSkg
cmV0dXJuOwogICAgICAgICAgICBjb25zdCBpbnAgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgn
cGFzdGUtc2VwLWN1c3RvbScpOwogICAgICAgICAgICBpZiAoaW5wICYmIGlucC52YWx1ZSAhPT0g
JycpIHsKICAgICAgICAgICAgICAgIGFwcGx5U2VwYXJhdG9yKGlucC52YWx1ZSk7CiAgICAgICAg
ICAgICAgICByZXR1cm47CiAgICAgICAgICAgIH0KICAgICAgICAgICAgY2xvc2VTZXBNZW51KCk7
CiAgICAgICAgfSwgdHJ1ZSk7CiAgICB9CgogICAgZnVuY3Rpb24gY2xlYXJNdWx0aShyZXN0b3Jl
VG9BbmNob3IpIHsKICAgICAgICBjb25zdCBiYWNrSWQgPSArcmFuZ2VBbmNob3JJZCB8fCAwOwog
ICAgICAgIG11bHRpSWRzID0gW107CiAgICAgICAgaWYgKHJlc3RvcmVUb0FuY2hvciAmJiBiYWNr
SWQpCiAgICAgICAgICAgIHNlbGVjdGVkSWQgPSBiYWNrSWQ7CiAgICAgICAgcmFuZ2VBbmNob3JJ
ZCA9IHNlbGVjdGVkSWQgfHwgMDsKICAgICAgICByYW5nZUFuY2hvckNsaWNrZWQgPSBmYWxzZTsK
ICAgICAgICB1cGRhdGVNdWx0aUJhZGdlKCk7CiAgICAgICAgaWYgKHJlc3RvcmVUb0FuY2hvciAm
JiBzZWxlY3RlZElkKSB7CiAgICAgICAgICAgIGNvbnN0IGVsID0gbGlzdEVsLnF1ZXJ5U2VsZWN0
b3IoJy5tZy1yb3dbZGF0YS1pZD0iJyArIHNlbGVjdGVkSWQgKyAnIl0nKQogICAgICAgICAgICAg
ICAgfHwgbGlzdEVsLnF1ZXJ5U2VsZWN0b3IoJy5pdG1bZGF0YS1pZD0iJyArIHNlbGVjdGVkSWQg
KyAnIl0nKTsKICAgICAgICAgICAgaWYgKGVsKSBlbC5zY3JvbGxJbnRvVmlldyh7IGJsb2NrOiAn
bmVhcmVzdCcgfSk7CiAgICAgICAgfQogICAgfQoKCiAgICAvKiBzaGlmdC9jdHJsIG11bHRpLXNl
bGVjdDoKICAgICAqIFNoaWZ077ya5pyJ6YCJ5Yy65pe25Lul44CM5pyA5LiKL+acgOS4i+OAjeS4
uumUmu+8jOS4jei3n+m8oOagh+S4iuasoeeCueWHu+i1sAogICAgICogICAtIOeCueWcqOmAieWM
uuS4i+aWuSDihpIg5LuO5LiK6YCJ5Yiw5b2T5YmNCiAgICAgKiAgIC0g54K55Zyo6YCJ5Yy65LiK
5pa5IOKGkiDku47lvZPliY3liLDkuIvpgIkKICAgICAqICAgLSDngrnlnKjpgInljLrot6jluqbl
hoUg4oaSIOWhq+a7oeacgOS4iuWIsOacgOS4i++8iOWQq+mdnui/nue7reepuua0nu+8iQogICAg
ICogQ3RybO+8mummluasoeeCueS7u+aEj+mhue+8iOWQq+m7mOiupOmrmOS6ru+8iei/m+WFpeWk
mumAieW5tumAieS4re+8m+WGjeeCueW3sumAiemhueWPlua2iOOAgeacqumAiemhueWKoOWFpQog
ICAgICovCiAgICBsZXQgcmFuZ2VBbmNob3JJZCA9IDA7CiAgICBsZXQgcmFuZ2VBbmNob3JDbGlj
a2VkID0gZmFsc2U7CiAgICBmdW5jdGlvbiBzZWxlY3RlZEluZGljZXNJbkxpc3QobGlzdCkgewog
ICAgICAgIGNvbnN0IHNldCA9IG5ldyBTZXQoKG11bHRpSWRzIHx8IFtdKS5tYXAoTnVtYmVyKS5m
aWx0ZXIoQm9vbGVhbikpOwogICAgICAgIGlmICgrc2VsZWN0ZWRJZCkgc2V0LmFkZCgrc2VsZWN0
ZWRJZCk7CiAgICAgICAgY29uc3QgaWR4cyA9IFtdOwogICAgICAgIGxpc3QuZm9yRWFjaCgoYywg
aSkgPT4gewogICAgICAgICAgICBpZiAoc2V0LmhhcygrYy5pZCkpIGlkeHMucHVzaChpKTsKICAg
ICAgICB9KTsKICAgICAgICByZXR1cm4gaWR4czsKICAgIH0KICAgIGZ1bmN0aW9uIHNlbGVjdFJh
bmdlVG8oaWQpIHsKICAgICAgICBpZCA9ICtpZDsKICAgICAgICBjb25zdCBsaXN0ID0gKHR5cGVv
ZiBuYXZMaXN0ID09PSAnZnVuY3Rpb24nID8gbmF2TGlzdCgpIDogdmlzaWJsZUxpc3QoKSk7CiAg
ICAgICAgY29uc3QgYiA9IGxpc3QuZmluZEluZGV4KGMgPT4gK2MuaWQgPT09IGlkKTsKICAgICAg
ICBpZiAoYiA8IDApIHJldHVybjsKICAgICAgICBjb25zdCBpZHhzID0gc2VsZWN0ZWRJbmRpY2Vz
SW5MaXN0KGxpc3QpOwogICAgICAgIGxldCBsbywgaGk7CiAgICAgICAgaWYgKCFpZHhzLmxlbmd0
aCkgewogICAgICAgICAgICBsbyA9IGhpID0gYjsKICAgICAgICB9IGVsc2UgewogICAgICAgICAg
ICBjb25zdCB0b3AgPSBNYXRoLm1pbiguLi5pZHhzKTsKICAgICAgICAgICAgY29uc3QgYm90ID0g
TWF0aC5tYXgoLi4uaWR4cyk7CiAgICAgICAgICAgIGlmIChiID4gYm90KSB7CiAgICAgICAgICAg
ICAgICAvLyDpgInljLrkuIvmlrnvvJrmnIDkuIog4oaSIOW9k+WJjQogICAgICAgICAgICAgICAg
bG8gPSB0b3A7CiAgICAgICAgICAgICAgICBoaSA9IGI7CiAgICAgICAgICAgIH0gZWxzZSBpZiAo
YiA8IHRvcCkgewogICAgICAgICAgICAgICAgLy8g6YCJ5Yy65LiK5pa577ya5b2T5YmNIOKGkiDm
nIDkuIsKICAgICAgICAgICAgICAgIGxvID0gYjsKICAgICAgICAgICAgICAgIGhpID0gYm90Owog
ICAgICAgICAgICB9IGVsc2UgewogICAgICAgICAgICAgICAgLy8g5Zyo6Leo5bqm5YaF77yI5ZCr
6Z2e6L+e57ut56m65rSe77yJ77ya5pW05q615pyA5LiK4oaS5pyA5LiLCiAgICAgICAgICAgICAg
ICBsbyA9IHRvcDsKICAgICAgICAgICAgICAgIGhpID0gYm90OwogICAgICAgICAgICB9CiAgICAg
ICAgfQogICAgICAgIG11bHRpSWRzID0gW107CiAgICAgICAgZm9yIChsZXQgaSA9IGxvOyBpIDw9
IGhpOyBpKyspCiAgICAgICAgICAgIG11bHRpSWRzLnB1c2goK2xpc3RbaV0uaWQpOwogICAgICAg
IHNlbGVjdGVkSWQgPSBpZDsKICAgICAgICAvLyDkuI3lho3miorpvKDmoIfngrnlh7vlvZPmiJDk
uIvkuIDmrKEgU2hpZnQg6ZSa54K5CiAgICAgICAgcmFuZ2VBbmNob3JJZCA9ICtsaXN0W2xvXS5p
ZDsKICAgICAgICByYW5nZUFuY2hvckNsaWNrZWQgPSB0cnVlOwogICAgICAgIHVwZGF0ZU11bHRp
QmFkZ2UoKTsKICAgICAgICBjb25zdCBlbCA9IGxpc3RFbC5xdWVyeVNlbGVjdG9yKCcubWctcm93
W2RhdGEtaWQ9IicgKyBzZWxlY3RlZElkICsgJyJdJykKICAgICAgICAgICAgfHwgbGlzdEVsLnF1
ZXJ5U2VsZWN0b3IoJy5pdG1bZGF0YS1pZD0iJyArIHNlbGVjdGVkSWQgKyAnIl0nKTsKICAgICAg
ICBpZiAoZWwpIGVsLnNjcm9sbEludG9WaWV3KHsgYmxvY2s6ICduZWFyZXN0JyB9KTsKICAgIH0K
ICAgIGZ1bmN0aW9uIGhhbmRsZUl0ZW1DbGljayhlLCBjKSB7CiAgICAgICAgaWYgKGUuc2hpZnRL
ZXkpIHsKICAgICAgICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOyBlLnN0b3BQcm9wYWdhdGlvbigp
OwogICAgICAgICAgICBzZWxlY3RSYW5nZVRvKGMuaWQpOwogICAgICAgICAgICByZXR1cm4gdHJ1
ZTsKICAgICAgICB9CiAgICAgICAgaWYgKGUuY3RybEtleSB8fCBlLm1ldGFLZXkpIHsKICAgICAg
ICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOyBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgICAgICAg
ICB0b2dnbGVNdWx0aShjLmlkKTsKICAgICAgICAgICAgcmV0dXJuIHRydWU7CiAgICAgICAgfQog
ICAgICAgIHJhbmdlQW5jaG9ySWQgPSBjLmlkOwogICAgICAgIHJhbmdlQW5jaG9yQ2xpY2tlZCA9
IHRydWU7CiAgICAgICAgcmV0dXJuIGZhbHNlOwogICAgfQogICAgZnVuY3Rpb24gdG9nZ2xlTXVs
dGkoaWQpIHsKICAgICAgICBpZCA9ICtpZDsKICAgICAgICAvLyDpppbmrKEgQ3RybO+8muWPqumA
ieS4reW9k+WJjeeCueWHu+mhue+8iOWQq+m7mOiupOmrmOS6rumhuSDihpIg6L+b5YWl5aSa6YCJ
77yM5LiN6KaB5Y+W5raI77yJCiAgICAgICAgaWYgKCFtdWx0aUlkcy5sZW5ndGgpIHsKICAgICAg
ICAgICAgbXVsdGlJZHMgPSBbaWRdOwogICAgICAgICAgICBzZWxlY3RlZElkID0gaWQ7CiAgICAg
ICAgICAgIHVwZGF0ZU11bHRpQmFkZ2UoKTsKICAgICAgICAgICAgcmV0dXJuOwogICAgICAgIH0K
ICAgICAgICBjb25zdCBpID0gbXVsdGlJZHMuaW5kZXhPZihpZCk7CiAgICAgICAgaWYgKGkgPj0g
MCkgewogICAgICAgICAgICBtdWx0aUlkcy5zcGxpY2UoaSwgMSk7CiAgICAgICAgICAgIGlmICgr
c2VsZWN0ZWRJZCA9PT0gaWQpCiAgICAgICAgICAgICAgICBzZWxlY3RlZElkID0gbXVsdGlJZHMu
bGVuZ3RoID8gbXVsdGlJZHNbbXVsdGlJZHMubGVuZ3RoIC0gMV0gOiAwOwogICAgICAgIH0gZWxz
ZSB7CiAgICAgICAgICAgIG11bHRpSWRzLnB1c2goaWQpOwogICAgICAgICAgICBzZWxlY3RlZElk
ID0gaWQ7CiAgICAgICAgfQogICAgICAgIHVwZGF0ZU11bHRpQmFkZ2UoKTsKICAgIH0KICAgIGZ1
bmN0aW9uIHNob3dTcmNUaXAoYW5jaG9yLCB0ZXh0KSB7CiAgICAgICAgdGV4dCA9IFN0cmluZyh0
ZXh0IHx8ICcnKS50cmltKCk7CiAgICAgICAgaWYgKCF0ZXh0KSByZXR1cm47CiAgICAgICAgbGV0
IHRpcCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzcmMtdGlwJyk7CiAgICAgICAgaWYgKCF0
aXApIHsKICAgICAgICAgICAgdGlwID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnZGl2Jyk7CiAg
ICAgICAgICAgIHRpcC5pZCA9ICdzcmMtdGlwJzsKICAgICAgICAgICAgZG9jdW1lbnQuYm9keS5h
cHBlbmRDaGlsZCh0aXApOwogICAgICAgIH0KICAgICAgICB0aXAudGV4dENvbnRlbnQgPSB0ZXh0
OwogICAgICAgIHRpcC5jbGFzc0xpc3QuYWRkKCdzaG93Jyk7CiAgICAgICAgY29uc3QgciA9IGFu
Y2hvci5nZXRCb3VuZGluZ0NsaWVudFJlY3QoKTsKICAgICAgICBjb25zdCB0dyA9IHRpcC5vZmZz
ZXRXaWR0aCB8fCAxNjA7CiAgICAgICAgY29uc3QgdGggPSB0aXAub2Zmc2V0SGVpZ2h0IHx8IDI4
OwogICAgICAgIGxldCBsZWZ0ID0gci5yaWdodCAtIHR3OwogICAgICAgIGxldCB0b3AgPSByLnRv
cCAtIHRoIC0gODsKICAgICAgICBpZiAobGVmdCA8IDgpIGxlZnQgPSA4OwogICAgICAgIGlmIChs
ZWZ0ICsgdHcgPiB3aW5kb3cuaW5uZXJXaWR0aCAtIDgpIGxlZnQgPSB3aW5kb3cuaW5uZXJXaWR0
aCAtIHR3IC0gODsKICAgICAgICBpZiAodG9wIDwgOCkgdG9wID0gci5ib3R0b20gKyA4OwogICAg
ICAgIHRpcC5zdHlsZS5sZWZ0ID0gbGVmdCArICdweCc7CiAgICAgICAgdGlwLnN0eWxlLnRvcCA9
IHRvcCArICdweCc7CiAgICAgICAgY2xlYXJUaW1lb3V0KHRpcC5faGlkZVQpOwogICAgICAgIHRp
cC5faGlkZVQgPSBzZXRUaW1lb3V0KCgpID0+IHRpcC5jbGFzc0xpc3QucmVtb3ZlKCdzaG93Jyks
IDIyMDApOwogICAgfQogICAgLyogaW1nLWhvdmVyLXByZXZpZXctdjggKi8KICAgIGxldCBfX2lt
Z0hvdmVyVGltZXIgPSAwLCBfX2ltZ0hvdmVySGlkZVRpbWVyID0gMCwgX19pbWdIb3ZlcktleSA9
ICcnOwogICAgZnVuY3Rpb24gX19pbWdIb3ZlckVuc3VyZSgpIHsKICAgICAgICBsZXQgYm94ID0g
ZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2ltZy1ob3Zlci1zaWRlJyk7CiAgICAgICAgaWYgKCFi
b3gpIHsKICAgICAgICAgICAgYm94ID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnZGl2Jyk7IGJv
eC5pZCA9ICdpbWctaG92ZXItc2lkZSc7CiAgICAgICAgICAgIGNvbnN0IGZyYW1lID0gZG9jdW1l
bnQuY3JlYXRlRWxlbWVudCgnZGl2Jyk7IGZyYW1lLmNsYXNzTmFtZSA9ICdpaHAtZnJhbWUnOwog
ICAgICAgICAgICBjb25zdCBpbSA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2ltZycpOyBpbS5h
bHQgPSAnJzsKICAgICAgICAgICAgZnJhbWUuYXBwZW5kQ2hpbGQoaW0pOyBib3guYXBwZW5kQ2hp
bGQoZnJhbWUpOyBkb2N1bWVudC5ib2R5LmFwcGVuZENoaWxkKGJveCk7CiAgICAgICAgfQogICAg
ICAgIGxldCBzdCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdpbWctaG92ZXItc2lkZS1jc3Mn
KTsKICAgICAgICBpZiAoIXN0KSB7IHN0ID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnc3R5bGUn
KTsgc3QuaWQgPSAnaW1nLWhvdmVyLXNpZGUtY3NzJzsgZG9jdW1lbnQuaGVhZC5hcHBlbmRDaGls
ZChzdCk7IH0KICAgICAgICBzdC50ZXh0Q29udGVudCA9ICIjaW1nLWhvdmVyLXNpZGV7cG9zaXRp
b246Zml4ZWQ7ei1pbmRleDoxMDAwMDA7cmlnaHQ6NnB4O3RvcDo1MCU7dHJhbnNmb3JtOnRyYW5z
bGF0ZVkoLTUwJSk7cG9pbnRlci1ldmVudHM6bm9uZTtvcGFjaXR5OjA7dmlzaWJpbGl0eTpoaWRk
ZW47bWF4LXdpZHRoOm1pbig2MjBweCw5MnZ3KTttYXgtaGVpZ2h0Om1pbig5MnZoLDkyMHB4KX0j
aW1nLWhvdmVyLXNpZGUuc2hvd3tvcGFjaXR5OjE7dmlzaWJpbGl0eTp2aXNpYmxlfSNpbWctaG92
ZXItc2lkZSAuaWhwLWZyYW1le3BhZGRpbmc6M3B4O2JhY2tncm91bmQ6I2ZmZjtib3JkZXI6MXB4
IHNvbGlkICNDNUNEREM7Ym9yZGVyLXJhZGl1czoycHg7Ym94LXNoYWRvdzowIDZweCAxOHB4IHJn
YmEoNDQsNDYsNTQsLjEyKX0jaW1nLWhvdmVyLXNpZGUgaW1ne2Rpc3BsYXk6YmxvY2s7bWF4LXdp
ZHRoOm1pbig2MTJweCw5MHZ3KTttYXgtaGVpZ2h0Om1pbig5MHZoLDkwMHB4KTt3aWR0aDphdXRv
O2hlaWdodDphdXRvO29iamVjdC1maXQ6Y29udGFpbjtiYWNrZ3JvdW5kOiNmZmZ9IjsKICAgICAg
ICByZXR1cm4gYm94OwogICAgfQogICAgd2luZG93Ll9faW1nSG92ZXJTaG93ID0gZnVuY3Rpb24o
ZmlsZSwgaWQpIHsKICAgICAgICBjb25zdCBiYXJlID0gU3RyaW5nKGZpbGUgfHwgJycpLnNwbGl0
KC9bXFxcXC9dLykucG9wKCk7IGlmICghYmFyZSkgcmV0dXJuOwogICAgICAgIGNvbnN0IGJveCA9
IF9faW1nSG92ZXJFbnN1cmUoKTsgY29uc3QgaW1nID0gYm94LnF1ZXJ5U2VsZWN0b3IoJ2ltZycp
OyBpZiAoIWltZykgcmV0dXJuOwogICAgICAgIGJveC5jbGFzc0xpc3QuYWRkKCdzaG93Jyk7CiAg
ICAgICAgaW1nLm9uZXJyb3IgPSAoKSA9PiB7CiAgICAgICAgICAgIGltZy5vbmVycm9yID0gKCkg
PT4geyBpbWcub25lcnJvciA9IG51bGw7IHRyeSB7IGNvbnN0IGMgPSB0aHVtYkNhY2hlICYmIHRo
dW1iQ2FjaGUuZ2V0KFN0cmluZyhpZCkpOyBpZiAoYykgaW1nLnNyYyA9IGM7IH0gY2F0Y2ggKGUp
IHt9IH07CiAgICAgICAgICAgIGltZy5zcmMgPSBTVE9SRV9CQVNFICsgJ3RoXycgKyBiYXJlLnJl
cGxhY2UoL1wuW14uXSskLywgJycpICsgJy5qcGcnOwogICAgICAgIH07CiAgICAgICAgaW1nLm9u
bG9hZCA9ICgpID0+IHsgaW1nLm9uZXJyb3IgPSBudWxsOyB9OwogICAgICAgIGltZy5kYXRhc2V0
LmJhcmUgPSBiYXJlOyBpbWcuc3JjID0gU1RPUkVfQkFTRSArIGJhcmU7CiAgICB9OwogICAgd2lu
ZG93Ll9faW1nSG92ZXJDbGVhclVpID0gZnVuY3Rpb24oKSB7CiAgICAgICAgX19pbWdIb3Zlcktl
eSA9ICcnOwogICAgICAgIGlmIChfX2ltZ0hvdmVyVGltZXIpIHsgY2xlYXJUaW1lb3V0KF9faW1n
SG92ZXJUaW1lcik7IF9faW1nSG92ZXJUaW1lciA9IDA7IH0KICAgICAgICBpZiAoX19pbWdIb3Zl
ckhpZGVUaW1lcikgeyBjbGVhclRpbWVvdXQoX19pbWdIb3ZlckhpZGVUaW1lcik7IF9faW1nSG92
ZXJIaWRlVGltZXIgPSAwOyB9CiAgICAgICAgY29uc3QgYm94ID0gZG9jdW1lbnQuZ2V0RWxlbWVu
dEJ5SWQoJ2ltZy1ob3Zlci1zaWRlJyk7IGlmIChib3gpIGJveC5jbGFzc0xpc3QucmVtb3ZlKCdz
aG93Jyk7CiAgICAgICAgY29uc3QgaW1nID0gYm94ICYmIGJveC5xdWVyeVNlbGVjdG9yKCdpbWcn
KTsKICAgICAgICBpZiAoaW1nKSB7IGltZy5vbmxvYWQgPSBudWxsOyBpbWcub25lcnJvciA9IG51
bGw7IGltZy5yZW1vdmVBdHRyaWJ1dGUoJ3NyYycpOyBkZWxldGUgaW1nLmRhdGFzZXQuYmFyZTsg
fQogICAgfTsKICAgIHdpbmRvdy5fX2ltZ0hvdmVySGlkZSA9IGZ1bmN0aW9uKCkgeyB3aW5kb3cu
X19pbWdIb3ZlckNsZWFyVWkoKTsgfTsKICAgIGZ1bmN0aW9uIGJpbmRJbWdIb3ZlclByZXZpZXco
ZWwsIGlkLCBmaWxlKSB7CiAgICAgICAgaWYgKCFlbCkgcmV0dXJuOwogICAgICAgIGNvbnN0IGJh
cmUgPSBTdHJpbmcoZmlsZSB8fCAnJykuc3BsaXQoL1tcXFxcL10vKS5wb3AoKTsgaWYgKCFiYXJl
KSByZXR1cm47CiAgICAgICAgY29uc3Qga2V5ID0gU3RyaW5nKGlkKSArICd8JyArIGJhcmU7CiAg
ICAgICAgZWwuc3R5bGUuY3Vyc29yID0gJ3pvb20taW4nOwogICAgICAgIGVsLmFkZEV2ZW50TGlz
dGVuZXIoJ21vdXNlZW50ZXInLCAoKSA9PiB7CiAgICAgICAgICAgIGlmIChfX2ltZ0hvdmVySGlk
ZVRpbWVyKSB7IGNsZWFyVGltZW91dChfX2ltZ0hvdmVySGlkZVRpbWVyKTsgX19pbWdIb3Zlckhp
ZGVUaW1lciA9IDA7IH0KICAgICAgICAgICAgX19pbWdIb3ZlcktleSA9IGtleTsKICAgICAgICAg
ICAgaWYgKF9faW1nSG92ZXJUaW1lcikgY2xlYXJUaW1lb3V0KF9faW1nSG92ZXJUaW1lcik7CiAg
ICAgICAgICAgIF9faW1nSG92ZXJUaW1lciA9IHNldFRpbWVvdXQoKCkgPT4geyBpZiAoX19pbWdI
b3ZlcktleSA9PT0ga2V5KSB0cnkgeyB3aW5kb3cuX19pbWdIb3ZlclNob3coYmFyZSwgaWQpOyB9
IGNhdGNoIChlKSB7fSB9LCA2MCk7CiAgICAgICAgfSk7CiAgICAgICAgZWwuYWRkRXZlbnRMaXN0
ZW5lcignbW91c2VsZWF2ZScsICgpID0+IHsKICAgICAgICAgICAgaWYgKF9faW1nSG92ZXJUaW1l
cikgeyBjbGVhclRpbWVvdXQoX19pbWdIb3ZlclRpbWVyKTsgX19pbWdIb3ZlclRpbWVyID0gMDsg
fQogICAgICAgICAgICBfX2ltZ0hvdmVySGlkZVRpbWVyID0gc2V0VGltZW91dCgoKSA9PiB7IGlm
ICghX19pbWdIb3ZlcktleSB8fCBfX2ltZ0hvdmVyS2V5ID09PSBrZXkpIHdpbmRvdy5fX2ltZ0hv
dmVySGlkZSgpOyB9LCA3MCk7CiAgICAgICAgfSk7CiAgICB9CgogICAgZnVuY3Rpb24gcmVuZGVy
KCkgewogICAgICAgIGhpZGVQYXRoVGlwKCk7CgogICAgICAgIGNvbnN0IHZpc2libGUgPSB2aXNp
YmxlTGlzdCgpOwogICAgICAgIGNvbnN0IGxvYWRlZCA9IGFsbENsaXBzLmxlbmd0aDsKICAgICAg
ICBjb25zdCBzaG93bkNvdW50ID0gdmlzaWJsZS5sZW5ndGg7CiAgICAgICAgLy8g5pS26JeP6KeS
5qCH77ya5pS55Li657u/54K577yI5pyJ5pyq5p+l55yL55qE5paw5pS26JeP5pe25pi+56S677yJ
CiAgICAgICAgbGV0IHBpbm5lZE4gPSBOdW1iZXIocGlubmVkVG90YWwpIHx8IDA7CiAgICAgICAg
aWYgKHBpbm5lZE4gPCAxKSB7CiAgICAgICAgICAgIGlmIChjdXJUYWIgPT09ICdwaW5uZWQnKQog
ICAgICAgICAgICAgICAgcGlubmVkTiA9IE1hdGgubWF4KE51bWJlcihkaXNrVG90YWwpIHx8IDAs
IGxvYWRlZCk7CiAgICAgICAgICAgIGVsc2UKICAgICAgICAgICAgICAgIHBpbm5lZE4gPSBhbGxD
bGlwcy5maWx0ZXIoYyA9PiBpc1Bpbm5lZChjKSkubGVuZ3RoOwogICAgICAgIH0KICAgICAgICB1
cGRhdGVQaW5Eb3QoKTsKICAgICAgICAvLyDmlLbol48gdGFi77yaYmFyIOeUqOaAu+aVsO+8m+ac
qua7oemhteaXtuaYvuekuiDlt7LliqDovb0v5oC75pWwCiAgICAgICAgbGV0IHNob3dUb3RhbCA9
IGRpc2tUb3RhbCA+IDAgPyBkaXNrVG90YWwgOiAobG9hZGVkIHx8IDApOwogICAgICAgIGlmIChj
dXJUYWIgPT09ICdwaW5uZWQnICYmIHBpbm5lZE4gPiBzaG93VG90YWwpCiAgICAgICAgICAgIHNo
b3dUb3RhbCA9IHBpbm5lZE47CiAgICAgICAgY29uc3QgcU9uID0gU3RyaW5nKHF1ZXJ5IHx8ICcn
KS50cmltKCkubGVuZ3RoID4gMDsKICAgICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYmFy
LXR4dCcpLnRleHRDb250ZW50ID0gcU9uCiAgICAgICAgICAgID8gKHNob3duQ291bnQgKyAnIOad
oScpCiAgICAgICAgICAgIDogKHNob3dUb3RhbCA+IGxvYWRlZCA/IChzaG93bkNvdW50ICsgJyAv
ICcgKyBzaG93VG90YWwgKyAnIOadoScpIDogKHNob3dUb3RhbCArICcg5p2hJykpOwogICAgICAg
IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdlbXB0eS10eHQnKS50ZXh0Q29udGVudCA9IEVNUFRZ
X01TR1tjdXJUYWJdIHx8IEVNUFRZX01TRy5hbGw7CgogICAgICAgIGNvbnN0IGlkU2V0ID0gbmV3
IFNldChhbGxDbGlwcy5tYXAoYyA9PiArYy5pZCkpOwogICAgICAgIG11bHRpSWRzID0gbXVsdGlJ
ZHMuZmlsdGVyKGlkID0+IGlkU2V0LmhhcyhpZCkpOwogICAgICAgIHVwZGF0ZU11bHRpQmFkZ2Uo
KTsKCiAgICAgICAgY29uc3Qgc2hvd24gPSB2aXNpYmxlOwoKICAgICAgICBsaXN0RWwucXVlcnlT
ZWxlY3RvckFsbCgnLml0bSwgI2xpc3QtbW9yZScpLmZvckVhY2goZSA9PiBlLnJlbW92ZSgpKTsK
ICAgICAgICAvLyDpqqjmnrblt7LlhbPpl63vvJrljbPkvb8gd2FpdGluZyDkuZ/kuI0gcmV0dXJu
77yM5pyJ5pWw5o2u5bCx55u05o6l55S7CiAgICAgICAgaWYgKHNrZWxFbCkgc2tlbEVsLmNsYXNz
TGlzdC5yZW1vdmUoJ29uJyk7CiAgICAgICAgY29uc3QgYXBwQm9vdCA9IGRvY3VtZW50LmdldEVs
ZW1lbnRCeUlkKCdhcHAnKTsKICAgICAgICBpZiAoYXBwQm9vdCkgYXBwQm9vdC5jbGFzc0xpc3Qu
cmVtb3ZlKCdib290LWxvYWRpbmcnKTsKICAgICAgICBpZiAoKHdhaXRpbmdEYXRhIHx8ICFob3N0
UHVzaGVkT25jZSkgJiYgIXZpc2libGUubGVuZ3RoKSB7CiAgICAgICAgICAgIGVtcHR5RWwuY2xh
c3NMaXN0LnJlbW92ZSgnb24nKTsKICAgICAgICAgICAgdXBkYXRlVG9wQnRuKCk7CiAgICAgICAg
ICAgIHJldHVybjsKICAgICAgICB9CiAgICAgICAgaWYgKCF2aXNpYmxlLmxlbmd0aCkgewogICAg
ICAgICAgICAvLyBOZXZlciBzaG9344CM5pqC5peg6K6w5b2V44CNdW50aWwgd2UgaGF2ZSBzZWVu
IGEgcmVhbCBub24tZW1wdHkgcHVzaCwKICAgICAgICAgICAgLy8gb3IgYSBjb25maXJtZWQgZW1w
dHkgYWZ0ZXIgd2FybSAoc2F3Tm9uRW1wdHkgY2FuIGJlIHNldCBieSBlbXB0eS1mYWxsYmFjayku
CiAgICAgICAgICAgIC8vIEZpbHRlcmVkIHNlYXJjaCB3aXRoIDAgaGl0cyBpcyBhbGxvd2VkIG9u
Y2UgaG9zdCBwdXNoZWQuCiAgICAgICAgICAgIGNvbnN0IHFPbiA9IFN0cmluZyhxdWVyeSB8fCAn
JykudHJpbSgpLmxlbmd0aCA+IDA7CiAgICAgICAgICAgIGNvbnN0IGFsbG93RW1wdHkgPSBob3N0
UHVzaGVkT25jZSAmJiBzYXdOb25FbXB0eSAmJiAhd2FpdGluZ0RhdGEgJiYgIWJvb3RMb2FkaW5n
CiAgICAgICAgICAgICAgICAmJiAocU9uIHx8IGRpc2tUb3RhbCA8PSAwKTsKICAgICAgICAgICAg
aWYgKCFhbGxvd0VtcHR5KSB7CiAgICAgICAgICAgICAgICBlbXB0eUVsLmNsYXNzTGlzdC5yZW1v
dmUoJ29uJyk7CiAgICAgICAgICAgICAgICB1cGRhdGVUb3BCdG4oKTsKICAgICAgICAgICAgICAg
IHJldHVybjsKICAgICAgICAgICAgfQogICAgICAgICAgICBpZiAoc2VsZWN0Rmlyc3RPblNob3cp
IHsKICAgICAgICAgICAgICAgIHNlbGVjdEZpcnN0T25TaG93ID0gZmFsc2U7CiAgICAgICAgICAg
ICAgICBzZWxlY3RlZElkID0gMDsKICAgICAgICAgICAgICAgIGNsZWFyTXVsdGkoKTsKICAgICAg
ICAgICAgICAgIGxpc3RFbC5zY3JvbGxUb3AgPSAwOwogICAgICAgICAgICB9CiAgICAgICAgICAg
IGVtcHR5RWwuY2xhc3NMaXN0LmFkZCgnb24nKTsKICAgICAgICAgICAgdXBkYXRlVG9wQnRuKCk7
CiAgICAgICAgICAgIHJldHVybjsKICAgICAgICB9CiAgICAgICAgZW1wdHlFbC5jbGFzc0xpc3Qu
cmVtb3ZlKCdvbicpOwogICAgICAgIGNvbnN0IGZyYWcgPSBkb2N1bWVudC5jcmVhdGVEb2N1bWVu
dEZyYWdtZW50KCk7CiAgICAgICAgY29uc3QgYmxvY2tzID0gYnVpbGRQaW5uZWRCbG9ja3Moc2hv
d24pOwogICAgICAgIGxldCBudW0gPSAwOwogICAgICAgIGJsb2Nrcy5mb3JFYWNoKGIgPT4gewog
ICAgICAgICAgICBudW0gKz0gMTsKICAgICAgICAgICAgaWYgKGIua2luZCA9PT0gJ2dyb3VwJyAm
JiBiLml0ZW1zLmxlbmd0aCA+IDEpCiAgICAgICAgICAgICAgICBmcmFnLmFwcGVuZENoaWxkKG1h
a2VHcm91cEl0ZW0oYi5pdGVtcywgbnVtKSk7CiAgICAgICAgICAgIGVsc2UKICAgICAgICAgICAg
ICAgIGZyYWcuYXBwZW5kQ2hpbGQobWFrZUl0ZW0oYi5pdGVtc1swXSwgbnVtKSk7CiAgICAgICAg
fSk7CiAgICAgICAgbGlzdEVsLmFwcGVuZENoaWxkKGZyYWcpOwogICAgICAgIG1hcmtRdWV1ZVJh
aWxzKCk7CiAgICAgICAgdXBkYXRlTW9yZUZvb3RlcihkaXNrVG90YWwpOwogICAgICAgIGlmIChz
ZWxlY3RGaXJzdE9uU2hvdykgewogICAgICAgICAgICBzZWxlY3RGaXJzdE9uU2hvdyA9IGZhbHNl
OwogICAgICAgICAgICBzZWxlY3RlZElkID0gdmlzaWJsZVswXS5pZDsKICAgICAgICAgICAgY2xl
YXJNdWx0aSgpOwogICAgICAgICAgICBsaXN0RWwuc2Nyb2xsVG9wID0gMDsKICAgICAgICB9IGVs
c2UgaWYgKCF2aXNpYmxlLnNvbWUoYyA9PiBjLmlkID09IHNlbGVjdGVkSWQpKSB7CiAgICAgICAg
ICAgIHNlbGVjdGVkSWQgPSB2aXNpYmxlWzBdLmlkOwogICAgICAgICAgICByYW5nZUFuY2hvcklk
ID0gc2VsZWN0ZWRJZDsKICAgICAgICAgICAgcmFuZ2VBbmNob3JDbGlja2VkID0gZmFsc2U7CiAg
ICAgICAgfSBlbHNlIGlmICghcmFuZ2VBbmNob3JJZCkgewogICAgICAgICAgICByYW5nZUFuY2hv
cklkID0gc2VsZWN0ZWRJZDsKICAgICAgICB9CiAgICAgICAgc3luY0l0ZW1IaWdobGlnaHQoKTsK
ICAgICAgICB1cGRhdGVUb3BCdG4oKTsKICAgICAgICBpZiAod2luZG93Ll9fcGVuZGluZ0p1bXBJ
ZCkgewogICAgICAgICAgICBjb25zdCBqaWQgPSArd2luZG93Ll9fcGVuZGluZ0p1bXBJZDsKICAg
ICAgICAgICAgY29uc3QgZWwgPSBsaXN0RWwucXVlcnlTZWxlY3RvcignLm1nLXJvd1tkYXRhLWlk
PSInICsgamlkICsgJyJdJykgfHwgbGlzdEVsLnF1ZXJ5U2VsZWN0b3IoJy5pdG1bZGF0YS1pZD0i
JyArIGppZCArICciXScpOwogICAgICAgICAgICBpZiAoZWwpIHsKICAgICAgICAgICAgICAgIHdp
bmRvdy5fX3BlbmRpbmdKdW1wSWQgPSAwOwogICAgICAgICAgICAgICAgd2luZG93Ll9fanVtcExv
YWRUcmllcyA9IDA7CiAgICAgICAgICAgICAgICBzZWxlY3RlZElkID0gamlkOwogICAgICAgICAg
ICAgICAgcmVxdWVzdEFuaW1hdGlvbkZyYW1lKCgpID0+IHsKICAgICAgICAgICAgICAgICAgICBj
b25zdCBub2RlID0gbGlzdEVsLnF1ZXJ5U2VsZWN0b3IoJy5tZy1yb3dbZGF0YS1pZD0iJyArIGpp
ZCArICciXScpIHx8IGxpc3RFbC5xdWVyeVNlbGVjdG9yKCcuaXRtW2RhdGEtaWQ9IicgKyBqaWQg
KyAnIl0nKTsKICAgICAgICAgICAgICAgICAgICBpZiAoIW5vZGUpIHJldHVybjsKICAgICAgICAg
ICAgICAgICAgICBub2RlLnNjcm9sbEludG9WaWV3KHsgYmxvY2s6ICdjZW50ZXInIH0pOwogICAg
ICAgICAgICAgICAgICAgIG5vZGUuY2xhc3NMaXN0LmFkZCgnanVtcC1mbGFzaCcpOwogICAgICAg
ICAgICAgICAgICAgIHNldFRpbWVvdXQoKCkgPT4gbm9kZS5jbGFzc0xpc3QucmVtb3ZlKCdqdW1w
LWZsYXNoJyksIDkwMCk7CiAgICAgICAgICAgICAgICAgICAgc3luY0l0ZW1IaWdobGlnaHQoKTsK
ICAgICAgICAgICAgICAgIH0pOwogICAgICAgICAgICB9IGVsc2UgaWYgKGFsbENsaXBzLmxlbmd0
aCA8IGRpc2tUb3RhbCAmJiAod2luZG93Ll9fanVtcExvYWRUcmllcyB8fCAwKSA8IDQwKSB7CiAg
ICAgICAgICAgICAgICB3aW5kb3cuX19qdW1wTG9hZFRyaWVzID0gKHdpbmRvdy5fX2p1bXBMb2Fk
VHJpZXMgfHwgMCkgKyAxOwogICAgICAgICAgICAgICAgcmVxdWVzdE1vcmUoKTsKICAgICAgICAg
ICAgfSBlbHNlIGlmIChjdXJUYWIgIT09ICdhbGwnICYmICF3aW5kb3cuX19qdW1wRmVsbEJhY2sp
IHsKICAgICAgICAgICAgICAgIC8vIEl0ZW0gZ29uZSBmcm9tIHRoaXMgdGFiIChlLmcuIHVucGlu
bmVkKSDigJQgZmFsbCBiYWNrIHRvIOWFqOmDqCBvbmNlCiAgICAgICAgICAgICAgICB3aW5kb3cu
X19qdW1wRmVsbEJhY2sgPSB0cnVlOwogICAgICAgICAgICAgICAgd2luZG93Ll9fanVtcExvYWRU
cmllcyA9IDA7CiAgICAgICAgICAgICAgICBjdXJUYWIgPSAnYWxsJzsKICAgICAgICAgICAgICAg
IG1hcmtUYWIoJ2FsbCcpOwogICAgICAgICAgICAgICAgcmVxdWVzdFZpZXcoKTsKICAgICAgICAg
ICAgfSBlbHNlIHsKICAgICAgICAgICAgICAgIHdpbmRvdy5fX3BlbmRpbmdKdW1wSWQgPSAwOwog
ICAgICAgICAgICAgICAgd2luZG93Ll9fanVtcExvYWRUcmllcyA9IDA7CiAgICAgICAgICAgICAg
ICBpZiAoYWxsQ2xpcHMuc29tZShjID0+ICtjLmlkID09PSBqaWQpKQogICAgICAgICAgICAgICAg
ICAgIHNlbGVjdGVkSWQgPSBqaWQ7CiAgICAgICAgICAgICAgICBzeW5jSXRlbUhpZ2hsaWdodCgp
OwogICAgICAgICAgICB9CiAgICAgICAgfQogICAgICAgIHJlcXVlc3RBbmltYXRpb25GcmFtZSgo
KSA9PiB7CiAgICAgICAgICAgIGlmIChhbGxDbGlwcy5sZW5ndGggPCBkaXNrVG90YWwKICAgICAg
ICAgICAgICAgICYmIGxpc3RFbC5zY3JvbGxIZWlnaHQgPD0gbGlzdEVsLmNsaWVudEhlaWdodCAr
IDIwKQogICAgICAgICAgICAgICAgcmVxdWVzdE1vcmUoKTsKICAgICAgICAgICAgc2NoZWR1bGVG
aWxlR29uZUNoZWNrKCk7CiAgICAgICAgfSk7CiAgICB9CgogICAgY29uc3QgU1ZHID0gewogICAg
ICAgIHRleHQ6ICAgYDxzdmcgdmlld0JveD0iMCAwIDI0IDI0IiBmaWxsPSJub25lIiBzdHJva2U9
ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIyIj48cGF0aCBkPSJNNCA3VjRoMTZ2M005IDIw
aDZNMTIgNHYxNiIvPjwvc3ZnPmAsCiAgICAgICAgbWQ6ICAgICBgPHN2ZyB2aWV3Qm94PSIwIDAg
MjQgMjQiIGZpbGw9ImN1cnJlbnRDb2xvciI+PHRleHQgeD0iMTIiIHk9IjE3IiB0ZXh0LWFuY2hv
cj0ibWlkZGxlIiBmb250LXNpemU9IjE1IiBmb250LXdlaWdodD0iODAwIiBmb250LWZhbWlseT0i
U2Vnb2UgVUksTWljcm9zb2Z0IFlhSGVpLHNhbnMtc2VyaWYiPk08L3RleHQ+PC9zdmc+YCwKICAg
ICAgICBpbWFnZTogIGA8c3ZnIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0ibm9uZSIgc3Ryb2tl
PSJjdXJyZW50Q29sb3IiIHN0cm9rZS13aWR0aD0iMS44Ij48cmVjdCB4PSIzIiB5PSI1IiB3aWR0
aD0iMTgiIGhlaWdodD0iMTQiIHJ4PSIyIi8+PGNpcmNsZSBjeD0iOC41IiBjeT0iMTAiIHI9IjEu
NSIgZmlsbD0iY3VycmVudENvbG9yIiBzdHJva2U9Im5vbmUiLz48cGF0aCBkPSJNMyAxNmw1LTUg
NCA0IDMtMyA2IDYiLz48L3N2Zz5gLAogICAgICAgIHZpZGVvOiAgYDxzdmcgdmlld0JveD0iMCAw
IDI0IDI0IiBmaWxsPSJub25lIiBzdHJva2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIx
LjgiPjxyZWN0IHg9IjMiIHk9IjYiIHdpZHRoPSIxNCIgaGVpZ2h0PSIxMiIgcng9IjIiLz48cGF0
aCBkPSJNMTcgOS41bDQtMi41djEwbC00LTIuNVY5LjV6IiBmaWxsPSJjdXJyZW50Q29sb3IiIHN0
cm9rZT0ibm9uZSIvPjxwYXRoIGQ9Ik04LjUgMTAuMnYzLjZsMy4yLTEuOC0zLjItMS44eiIgZmls
bD0iY3VycmVudENvbG9yIiBzdHJva2U9Im5vbmUiLz48L3N2Zz5gLAogICAgICAgIGZvbGRlcjog
YDxzdmcgdmlld0JveD0iMCAwIDI0IDI0IiBmaWxsPSJjdXJyZW50Q29sb3IiPjxwYXRoIGQ9Ik0x
MCA0SDRjLTEuMSAwLTIgLjktMiAydjEyYzAgMS4xLjkgMiAyIDJoMTZjMS4xIDAgMi0uOSAyLTJW
OGMwLTEuMS0uOS0yLTItMmgtOGwtMi0yeiIvPjwvc3ZnPmAsCiAgICAgICAgemlwOiAgICBgPHN2
ZyB2aWV3Qm94PSIwIDAgMjQgMjQiIGZpbGw9Im5vbmUiIHN0cm9rZT0iY3VycmVudENvbG9yIiBz
dHJva2Utd2lkdGg9IjEuOCI+PHBhdGggZD0iTTYgM2g5bDUgNXYxM2ExIDEgMCAwIDEtMSAxSDZh
MSAxIDAgMCAxLTEtMVY0YTEgMSAwIDAgMSAxLTF6Ii8+PHBhdGggZD0iTTE0IDN2Nmg2Ii8+PC9z
dmc+YCwKICAgICAgICBhaGs6ICAgIGA8c3ZnIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0iY3Vy
cmVudENvbG9yIj48dGV4dCB4PSIxMiIgeT0iMTciIHRleHQtYW5jaG9yPSJtaWRkbGUiIGZvbnQt
c2l6ZT0iMTQiIGZvbnQtd2VpZ2h0PSI3MDAiPkg8L3RleHQ+PC9zdmc+YCwKICAgICAgICBsbms6
ICAgIGA8c3ZnIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSJjdXJyZW50
Q29sb3IiIHN0cm9rZS13aWR0aD0iMS44Ij48cGF0aCBkPSJNMTAgMTNhNSA1IDAgMCAwIDcuMDcg
MGwyLjEyLTIuMTJhNSA1IDAgMCAwLTcuMDctNy4wN0wxMSA1Ii8+PHBhdGggZD0iTTE0IDExYTUg
NSAwIDAgMC03LjA3IDBMNC44IDEzLjEyYTUgNSAwIDEgMCA3LjA3IDcuMDdMMTMgMTkiLz48L3N2
Zz5gLAogICAgICAgIGRvYzogICAgYDxzdmcgdmlld0JveD0iMCAwIDI0IDI0IiBmaWxsPSJub25l
IiBzdHJva2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIxLjgiPjxwYXRoIGQ9Ik03IDNo
N2w1IDV2MTNhMSAxIDAgMCAxLTEgMUg3YTEgMSAwIDAgMS0xLTFWNGExIDEgMCAwIDEgMS0xeiIv
PjxwYXRoIGQ9Ik0xNCAzdjZoNiIvPjwvc3ZnPmAsCiAgICAgICAgbXVsdGk6ICBgPHN2ZyB2aWV3
Qm94PSIwIDAgMjQgMjQiIGZpbGw9Im5vbmUiIHN0cm9rZT0iY3VycmVudENvbG9yIiBzdHJva2Ut
d2lkdGg9IjEuOCI+PHJlY3QgeD0iNyIgeT0iNyIgd2lkdGg9IjEyIiBoZWlnaHQ9IjE0IiByeD0i
MS41Ii8+PHBhdGggZD0iTTUgMTdWNWExIDEgMCAwIDEgMS0xaDEwIi8+PC9zdmc+YAogICAgfTsK
CiAgICBmdW5jdGlvbiBmaWxlRXh0KHBhdGgpIHsKICAgICAgICBjb25zdCBiYXNlID0gU3RyaW5n
KHBhdGggfHwgJycpLnNwbGl0KC9bXFwvXS8pLnBvcCgpIHx8ICcnOwogICAgICAgIGNvbnN0IGkg
PSBiYXNlLmxhc3RJbmRleE9mKCcuJyk7CiAgICAgICAgcmV0dXJuIGkgPiAwID8gYmFzZS5zbGlj
ZShpICsgMSkudG9Mb3dlckNhc2UoKSA6ICcnOwogICAgfQogICAgY29uc3QgaXNJbWFnZUV4dCA9
IGUgPT4gWydwbmcnLCdqcGcnLCdqcGVnJywnZ2lmJywnd2VicCcsJ2JtcCcsJ2ljbycsJ3RpZics
J3RpZmYnLCdzdmcnXS5pbmNsdWRlcyhlKTsKICAgIGNvbnN0IGlzVmlkZW9FeHQgPSBlID0+IFsn
bXA0JywnbWt2JywnYXZpJywnbW92Jywnd212JywnZmx2Jywnd2VibScsJ200dicsJ21wZWcnLCdt
cGcnLCd0cycsJ20ydHMnLCczZ3AnLCdybScsJ3JtdmInXS5pbmNsdWRlcyhlKTsKICAgIGNvbnN0
IGlzWmlwRXh0ICAgPSBlID0+IFsnemlwJywncmFyJywnN3onLCd0YXInLCdneicsJ2J6MiddLmlu
Y2x1ZGVzKGUpOwoKICAgIGZ1bmN0aW9uIGljb25Gb3JGaWxlcyhmaWxlcykgewogICAgICAgIGlm
ICghZmlsZXMubGVuZ3RoKSAgICByZXR1cm4geyBjbHM6ICdmaWxlIGZ0LWRvYycsIHN2ZzogU1ZH
LmRvYyB9OwogICAgICAgIGlmIChmaWxlcy5sZW5ndGggPiAxKSByZXR1cm4geyBjbHM6ICdmaWxl
IGZ0LWxuaycsIHN2ZzogU1ZHLm11bHRpIH07CiAgICAgICAgY29uc3QgZXh0ID0gZmlsZUV4dChm
aWxlc1swXSk7CiAgICAgICAgaWYgKCFleHQpICAgICAgICAgICAgICByZXR1cm4geyBjbHM6ICdm
aWxlIGZ0LWRpcicsIHN2ZzogU1ZHLmZvbGRlciB9OwogICAgICAgIGlmIChpc0ltYWdlRXh0KGV4
dCkpICAgcmV0dXJuIHsgY2xzOiAnZmlsZSBmdC1pbWcnLCBzdmc6IFNWRy5pbWFnZSB9OwogICAg
ICAgIGlmIChpc1ZpZGVvRXh0KGV4dCkpICAgcmV0dXJuIHsgY2xzOiAnZmlsZSBmdC12aWQnLCBz
dmc6IChTVkcudmlkZW8gfHwgU1ZHLmRvYykgfTsKICAgICAgICBpZiAoaXNaaXBFeHQoZXh0KSkg
ICAgIHJldHVybiB7IGNsczogJ2ZpbGUgZnQtemlwJywgc3ZnOiBTVkcuemlwIH07CiAgICAgICAg
aWYgKGV4dCA9PT0gJ2FoaycpICAgICByZXR1cm4geyBjbHM6ICdmaWxlIGZ0LWFoaycsIHN2Zzog
U1ZHLmFoayB9OwogICAgICAgIGlmIChleHQgPT09ICdsbmsnKSAgICAgcmV0dXJuIHsgY2xzOiAn
ZmlsZSBmdC1sbmsnLCBzdmc6IFNWRy5sbmsgfTsKICAgICAgICByZXR1cm4geyBjbHM6ICdmaWxl
IGZ0LWRvYycsIHN2ZzogU1ZHLmRvYyB9OwogICAgfQoKICAgIGZ1bmN0aW9uIHNyY1dpbkxhYmVs
KGMpIHsKICAgICAgICBjb25zdCB0ID0gU3RyaW5nKGMgJiYgYy5zcmNUaXRsZSB8fCAnJykudHJp
bSgpOwogICAgICAgIGlmICh0KSByZXR1cm4gdDsKICAgICAgICByZXR1cm4gU3RyaW5nKGMgJiYg
Yy5zcmNFeGUgfHwgJycpLnJlcGxhY2UoL1wuZXhlJC9pLCAnJyk7CiAgICB9CiAgICBmdW5jdGlv
biBzcmNUaXRsZUh0bWwoYykgewogICAgICAgIC8vIOWIl+ihqOS4remXtC/lj7PkvqfkuI3lho3m
mL7npLrnqpflj6PmoIfpopjvvIzmnaXmupDlj6rkv53nlZnlj7Pkvqflm77moIfmgqzlgZzmj5Dn
pLoKICAgICAgICByZXR1cm4gJyc7CiAgICB9CiAgICBmdW5jdGlvbiBleHBhbmRDaGV2cm9uKG9w
ZW4pIHsKICAgICAgICByZXR1cm4gb3BlbgogICAgICAgICAgICA/IGA8c3ZnIHZpZXdCb3g9IjAg
MCAxNiAxNiIgd2lkdGg9IjE0IiBoZWlnaHQ9IjE0IiBmaWxsPSJub25lIiBzdHJva2U9ImN1cnJl
bnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIxLjgiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCI+PHBvbHls
aW5lIHBvaW50cz0iNCAxMCA4IDYgMTIgMTAiLz48L3N2Zz48c3Bhbj7mlLbotbc8L3NwYW4+YAog
ICAgICAgICAgICA6IGA8c3ZnIHZpZXdCb3g9IjAgMCAxNiAxNiIgd2lkdGg9IjE0IiBoZWlnaHQ9
IjE0IiBmaWxsPSJub25lIiBzdHJva2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIxLjgi
IHN0cm9rZS1saW5lY2FwPSJyb3VuZCI+PHBvbHlsaW5lIHBvaW50cz0iNCA2IDggMTAgMTIgNiIv
Pjwvc3ZnPjxzcGFuPuWxleW8gDwvc3Bhbj5gOwogICAgfQogICAgZnVuY3Rpb24gbGlzdEV4cGFu
ZE1heFB4KCkgewogICAgICAgIGNvbnN0IGggPSAobGlzdEVsICYmIGxpc3RFbC5jbGllbnRIZWln
aHQpIHx8IDM2MDsKICAgICAgICAvLyDlh6DkuY7ljaDmu6HliJfooajvvIzlupXpg6jnlZnnuqbk
uIDooYwKICAgICAgICByZXR1cm4gTWF0aC5tYXgoOTYsIGggLSAyOCk7CiAgICB9CiAgICBmdW5j
dGlvbiBhcHBseUV4cGFuZGVkUHJldmlldyhwcmV2LCBmdWxsVGV4dCkgewogICAgICAgIGNvbnN0
IG1heEggPSBsaXN0RXhwYW5kTWF4UHgoKTsKICAgICAgICBwcmV2LnN0eWxlLm1heEhlaWdodCA9
IG1heEggKyAncHgnOwogICAgICAgIHByZXYuY2xhc3NMaXN0LmFkZCgnZXhwYW5kZWQnKTsKICAg
ICAgICBzZXRIbFRleHQocHJldiwgZnVsbFRleHQpOwogICAgICAgIC8vIOS7jea6ouWHuu+8muaI
quaWreW5tuWcqOacq+WwvuWKoOOAjCAuLi7jgI0KICAgICAgICBpZiAocHJldi5zY3JvbGxIZWln
aHQgPD0gcHJldi5jbGllbnRIZWlnaHQgKyAyKQogICAgICAgICAgICByZXR1cm47CiAgICAgICAg
bGV0IGxvID0gMCwgaGkgPSBmdWxsVGV4dC5sZW5ndGgsIGJlc3QgPSAwOwogICAgICAgIHdoaWxl
IChsbyA8PSBoaSkgewogICAgICAgICAgICBjb25zdCBtaWQgPSAobG8gKyBoaSkgPj4gMTsKICAg
ICAgICAgICAgc2V0SGxUZXh0KHByZXYsIGZ1bGxUZXh0LnNsaWNlKDAsIG1pZCkgKyAnIC4uLicp
OwogICAgICAgICAgICBpZiAocHJldi5zY3JvbGxIZWlnaHQgPD0gcHJldi5jbGllbnRIZWlnaHQg
KyAyKSB7CiAgICAgICAgICAgICAgICBiZXN0ID0gbWlkOwogICAgICAgICAgICAgICAgbG8gPSBt
aWQgKyAxOwogICAgICAgICAgICB9IGVsc2UgewogICAgICAgICAgICAgICAgaGkgPSBtaWQgLSAx
OwogICAgICAgICAgICB9CiAgICAgICAgfQogICAgICAgIHNldEhsVGV4dChwcmV2LCBmdWxsVGV4
dC5zbGljZSgwLCBiZXN0KSArICcgLi4uJyk7CiAgICB9CiAgICBmdW5jdGlvbiBjb2xsYXBzZVBy
ZXZpZXcocHJldiwgZnVsbFRleHQpIHsKICAgICAgICBwcmV2LmNsYXNzTGlzdC5yZW1vdmUoJ2V4
cGFuZGVkJyk7CiAgICAgICAgcHJldi5zdHlsZS5tYXhIZWlnaHQgPSAnJzsKICAgICAgICBzZXRI
bFRleHQocHJldiwgZnVsbFRleHQpOwogICAgfQoKICAgIGZ1bmN0aW9uIGZhdkdyb3VwT2YoYykg
ewogICAgICAgIHJldHVybiBTdHJpbmcoYyAmJiBjLmZhdkdyb3VwIHx8ICcnKS50cmltKCk7CiAg
ICB9CiAgICBmdW5jdGlvbiBjbGlwQ29udGVudFByZXZpZXcoYykgewogICAgICAgIGNvbnN0IHR5
cGUgPSBub3JtVHlwZShjLnR5cGUpOwogICAgICAgIGlmICh0eXBlID09PSAnaW1hZ2UnKSByZXR1
cm4gJ1vlm77lg49dJyArIChjLndpZHRoICYmIGMuaGVpZ2h0ID8gKCcgJyArIGMud2lkdGggKyAn
w5cnICsgYy5oZWlnaHQpIDogJycpOwogICAgICAgIGlmICh0eXBlID09PSAnZmlsZScpIHsKICAg
ICAgICAgICAgY29uc3QgZmlsZXMgPSBTdHJpbmcoYy5wcmV2aWV3IHx8IGMuZGF0YSB8fCAnJyku
c3BsaXQoL1xyP1xuLykuZmlsdGVyKEJvb2xlYW4pOwogICAgICAgICAgICByZXR1cm4gZmlsZXMu
bWFwKGYgPT4gZi5zcGxpdCgvW1xcL10vKS5wb3AoKSkuam9pbignIMK3ICcpIHx8ICdb5paH5Lu2
XSc7CiAgICAgICAgfQogICAgICAgIGxldCBfcCA9IFN0cmluZyhjLnByZXZpZXcgfHwgYy5kYXRh
IHx8ICcnKTsKICAgICAgICB7IGNvbnN0IF9uID0gTnVtYmVyKGMuY2hhckNvdW50KSB8fCAwOyBp
ZiAoX24gPiBfcC5sZW5ndGggJiYgX3AubGVuZ3RoKSBfcCArPSAnLi4uJzsgfQogICAgICAgIHJl
dHVybiBfcDsKICAgIH0KICAgIGZ1bmN0aW9uIGJ1aWxkUGlubmVkQmxvY2tzKGxpc3QpIHsKICAg
ICAgICBjb25zdCB1c2VkID0gbmV3IFNldCgpOwogICAgICAgIGNvbnN0IG91dCA9IFtdOwogICAg
ICAgIGZvciAoY29uc3QgYyBvZiBsaXN0KSB7CiAgICAgICAgICAgIGlmICh1c2VkLmhhcygrYy5p
ZCkpIGNvbnRpbnVlOwogICAgICAgICAgICBjb25zdCBnaWQgPSBmYXZHcm91cE9mKGMpOwogICAg
ICAgICAgICBpZiAoIWdpZCkgewogICAgICAgICAgICAgICAgdXNlZC5hZGQoK2MuaWQpOwogICAg
ICAgICAgICAgICAgb3V0LnB1c2goeyBraW5kOiAnc2luZ2xlJywgaXRlbXM6IFtjXSB9KTsKICAg
ICAgICAgICAgICAgIGNvbnRpbnVlOwogICAgICAgICAgICB9CiAgICAgICAgICAgIGNvbnN0IG1l
bWJlcnMgPSBsaXN0LmZpbHRlcih4ID0+IGZhdkdyb3VwT2YoeCkgPT09IGdpZCk7CiAgICAgICAg
ICAgIG1lbWJlcnMuZm9yRWFjaChtID0+IHVzZWQuYWRkKCttLmlkKSk7CiAgICAgICAgICAgIGlm
IChtZW1iZXJzLmxlbmd0aCA8IDIpCiAgICAgICAgICAgICAgICBvdXQucHVzaCh7IGtpbmQ6ICdz
aW5nbGUnLCBpdGVtczogW21lbWJlcnNbMF0gfHwgY10gfSk7CiAgICAgICAgICAgIGVsc2UKICAg
ICAgICAgICAgICAgIG91dC5wdXNoKHsga2luZDogJ2dyb3VwJywgZ2lkLCBpdGVtczogbWVtYmVy
cyB9KTsKICAgICAgICB9CiAgICAgICAgcmV0dXJuIG91dDsKICAgIH0KICAgIGZ1bmN0aW9uIF9f
cHJlcFBhc3RlKCkgewogICAgICAgIHRyeSB7CiAgICAgICAgICAgIGNvbnN0IHMgPSBkb2N1bWVu
dC5nZXRFbGVtZW50QnlJZCgnc2VhcmNoJyk7CiAgICAgICAgICAgIGlmIChzICYmIGRvY3VtZW50
LmFjdGl2ZUVsZW1lbnQgPT09IHMpIHRyeSB7IHMuYmx1cigpOyB9IGNhdGNoIHt9CiAgICAgICAg
ICAgIGlmICh3aW5kb3cuZ2V0U2VsZWN0aW9uKSB3aW5kb3cuZ2V0U2VsZWN0aW9uKCkucmVtb3Zl
QWxsUmFuZ2VzKCk7CiAgICAgICAgfSBjYXRjaCB7fQogICAgfQogICAgZnVuY3Rpb24gcGFzdGVP
bmUoYykgewogICAgICAgIF9fcHJlcFBhc3RlKCk7CiAgICAgICAgc2VsZWN0ZWRJZCA9IGMuaWQ7
CiAgICAgICAgaWYgKG11bHRpSWRzLmxlbmd0aCkgY2xlYXJNdWx0aSgpOwogICAgICAgIHN5bmNJ
dGVtSGlnaGxpZ2h0KCk7CiAgICAgICAgbWFya1Bhc3RlZExvY2FsKGMuaWQpOwogICAgICAgIGFo
aygncGFzdGUnLCBTdHJpbmcoYy5pZCkpOwogICAgfQogICAgZnVuY3Rpb24gb3BlblJlY2VudERp
cihwYXRoKSB7CiAgICAgICAgbGV0IHAgPSBTdHJpbmcocGF0aCB8fCAnJykudHJpbSgpOwogICAg
ICAgIGlmICghcCkgcmV0dXJuOwogICAgICAgIGlmICgvXlthLXpBLVpdOiQvLnRlc3QocCkpIHAg
Kz0gJ1xcJzsKICAgICAgICAvLyDnu5/kuIAgLyDvvJrpgb/lhY0gV2ViVmlldyBob3N0L0pTT04g
5ZCD5o6J5Y+N5pac5p2gCiAgICAgICAgY29uc3Qgd2lyZSA9IHAucmVwbGFjZSgvXFwvZywgJy8n
KTsKICAgICAgICBjb25zdCBzZW5kID0gKCkgPT4gewogICAgICAgICAgICAvLyAxKSBwb3N0TWVz
c2FnZSDmnIDnqLPvvIjkuI3ov5sgc3luYyBDT03vvIkKICAgICAgICAgICAgdHJ5IHsKICAgICAg
ICAgICAgICAgIGlmICh3aW5kb3cuY2hyb21lICYmIGNocm9tZS53ZWJ2aWV3ICYmIHR5cGVvZiBj
aHJvbWUud2Vidmlldy5wb3N0TWVzc2FnZSA9PT0gJ2Z1bmN0aW9uJykgewogICAgICAgICAgICAg
ICAgICAgIGNocm9tZS53ZWJ2aWV3LnBvc3RNZXNzYWdlKCdvcGVuRGlyfCcgKyB3aXJlKTsKICAg
ICAgICAgICAgICAgICAgICByZXR1cm4gdHJ1ZTsKICAgICAgICAgICAgICAgIH0KICAgICAgICAg
ICAgfSBjYXRjaCB7fQogICAgICAgICAgICAvLyAyKSBhc3luYyBob3N077yI6Z2eIHN5bmPvvIkK
ICAgICAgICAgICAgdHJ5IHsKICAgICAgICAgICAgICAgIGNvbnN0IGhvc3QgPSBjaHJvbWUud2Vi
dmlldy5ob3N0T2JqZWN0cy5haGs7CiAgICAgICAgICAgICAgICBpZiAoaG9zdCAmJiBob3N0Lm9w
ZW5EaXIpIHsKICAgICAgICAgICAgICAgICAgICBQcm9taXNlLnJlc29sdmUoaG9zdC5vcGVuRGly
KHdpcmUpKS5jYXRjaCgoKSA9PiB7fSk7CiAgICAgICAgICAgICAgICAgICAgcmV0dXJuIHRydWU7
CiAgICAgICAgICAgICAgICB9CiAgICAgICAgICAgIH0gY2F0Y2gge30KICAgICAgICAgICAgLy8g
Mykg5pyA5ZCO5omNIHN5bmMKICAgICAgICAgICAgdHJ5IHsgYWhrKCdvcGVuRGlyJywgd2lyZSk7
IHJldHVybiB0cnVlOyB9IGNhdGNoIHt9CiAgICAgICAgICAgIHJldHVybiBmYWxzZTsKICAgICAg
ICB9OwogICAgICAgIC8vIOemu+W8gCBwb2ludGVyIOS6i+S7tuagiOWGjeiwg++8jOmBv+WFjSBX
ZWJWaWV3MiDlkIzmraXmrbvplIHlr7zoh7TigJzngrnkuobmsqHlj43lupTigJ0KICAgICAgICBz
ZXRUaW1lb3V0KHNlbmQsIDApOwogICAgfQogICAgZnVuY3Rpb24gaXNJdGVtQ2hyb21lVGFyZ2V0
KHQpIHsKICAgICAgICByZXR1cm4gISEodCAmJiB0LmNsb3Nlc3QgJiYgdC5jbG9zZXN0KCcuaS1l
eHBhbmQtYnRuLCAuaS1zcmMtaWNvLCAubWctc3JjLCAuZmQtYnRuLCAuZmQtcGF0aCwgLnJmLXNl
ZywgYnV0dG9uLCBhLCBpbnB1dCcpKTsKICAgIH0KICAgIGZ1bmN0aW9uIGJlZ2luUGFzdGVGcm9t
SXRlbShlLCBjKSB7CiAgICAgICAgaWYgKGUuYnV0dG9uICE9IG51bGwgJiYgZS5idXR0b24gIT09
IDApIHJldHVybjsKICAgICAgICBjb25zdCBzZWcgPSBlLnRhcmdldCAmJiBlLnRhcmdldC5jbG9z
ZXN0ICYmIGUudGFyZ2V0LmNsb3Nlc3QoJy5yZi1zZWcnKTsKICAgICAgICBpZiAoc2VnKSB7CiAg
ICAgICAgICAgIGNvbnN0IG9wZW5QYXRoID0gc2VnLl9vcGVuUGF0aCB8fCBzZWcuZ2V0QXR0cmli
dXRlKCdkYXRhLXBhdGgnKSB8fCBzZWcuZGF0YXNldC5vcGVuUGF0aCB8fCAnJzsKICAgICAgICAg
ICAgaWYgKG9wZW5QYXRoKSB7CiAgICAgICAgICAgICAgICBlLnByZXZlbnREZWZhdWx0KCk7CiAg
ICAgICAgICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgICAgICAgICAgICAgb3BlblJl
Y2VudERpcihvcGVuUGF0aCk7CiAgICAgICAgICAgICAgICByZXR1cm47CiAgICAgICAgICAgIH0K
ICAgICAgICB9CiAgICAgICAgaWYgKGUudGFyZ2V0ICYmIGUudGFyZ2V0LmNsb3Nlc3QgJiYgZS50
YXJnZXQuY2xvc2VzdCgnLnJmLXBhdGgnKSkKICAgICAgICAgICAgcmV0dXJuOwogICAgICAgIGlm
IChpc0l0ZW1DaHJvbWVUYXJnZXQoZS50YXJnZXQpKSByZXR1cm47CiAgICAgICAgaWYgKG5vcm1U
eXBlKGMudHlwZSkgPT09ICdyZWNlbnQnKSB7CiAgICAgICAgICAgIGFjdGl2YXRlQ2xpcEl0ZW0o
Yyk7CiAgICAgICAgICAgIHJldHVybjsKICAgICAgICB9CiAgICAgICAgaWYgKGhhbmRsZUl0ZW1D
bGljayhlLCBjKSkKICAgICAgICAgICAgcmV0dXJuOwogICAgICAgIF9fcHJlcFBhc3RlKCk7CiAg
ICAgICAgc2VsZWN0ZWRJZCA9IGMuaWQ7CiAgICAgICAgcmFuZ2VBbmNob3JJZCA9IGMuaWQ7CiAg
ICAgICAgICAgIGlmIChtdWx0aUlkcy5sZW5ndGggPiAwICYmIG11bHRpSWRzLmluY2x1ZGVzKCtj
LmlkKSkgewogICAgICAgICAgICBjb25zdCBpZHMgPSBtdWx0aUlkcy5zbGljZSgpOwogICAgICAg
ICAgICBjbGVhck11bHRpKCk7CiAgICAgICAgICAgIG1hcmtQYXN0ZWRMb2NhbChpZHMpOwogICAg
ICAgICAgICBwYXN0ZU1hbnlXaXRoU2VwKGlkcyk7CiAgICAgICAgICAgIHJldHVybjsKICAgICAg
ICB9CiAgICAgICAgaWYgKG11bHRpSWRzLmxlbmd0aCkgY2xlYXJNdWx0aSgpOwogICAgICAgIHN5
bmNJdGVtSGlnaGxpZ2h0KCk7CiAgICAgICAgbWFya1Bhc3RlZExvY2FsKGMuaWQpOwogICAgICAg
IGFoaygncGFzdGUnLCBTdHJpbmcoYy5pZCkpOwogICAgfQogICAgZnVuY3Rpb24gbWFrZUdyb3Vw
SXRlbShpdGVtcywgaWR4KSB7CiAgICAgICAgY29uc3QgZWwgPSBkb2N1bWVudC5jcmVhdGVFbGVt
ZW50KCdkaXYnKTsKICAgICAgICBlbC5jbGFzc05hbWUgPSAnaXRtIGl0LWdyb3VwJwogICAgICAg
ICAgICArIChpdGVtcy5zb21lKGMgPT4gK2MuaWQgPT09ICtzZWxlY3RlZElkKSA/ICcgc2VsJyA6
ICcnKQogICAgICAgICAgICArIChpdGVtcy5zb21lKGMgPT4gbXVsdGlJZHMuaW5jbHVkZXMoK2Mu
aWQpKSA/ICcgbXVsdGknIDogJycpOwogICAgICAgIGVsLmRhdGFzZXQuZ3JvdXAgPSBmYXZHcm91
cE9mKGl0ZW1zWzBdKSB8fCAnJzsKICAgICAgICBlbC5kYXRhc2V0LmlkID0gaXRlbXNbMF0uaWQ7
CgogICAgICAgIGNvbnN0IGhlYWQgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsKICAg
ICAgICBoZWFkLmNsYXNzTmFtZSA9ICdtZy1oZWFkJzsKICAgICAgICBoZWFkLmlubmVySFRNTCA9
ICc8c3BhbiBjbGFzcz0ibWctdGFnIj7lkIjlubY8L3NwYW4+PHNwYW4+JyArIGl0ZW1zLmxlbmd0
aCArICcg5p2hIMK3IOeCueWHu+WNleadoeeymOi0tDwvc3Bhbj4nOwogICAgICAgIGVsLmFwcGVu
ZENoaWxkKGhlYWQpOwoKICAgICAgICBpdGVtcy5mb3JFYWNoKGMgPT4gewogICAgICAgICAgICBj
b25zdCByb3cgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsKICAgICAgICAgICAgcm93
LmNsYXNzTmFtZSA9ICdtZy1yb3cnCiAgICAgICAgICAgICAgICArICgrc2VsZWN0ZWRJZCA9PT0g
K2MuaWQgPyAnIHNlbCcgOiAnJykKICAgICAgICAgICAgICAgICsgKG11bHRpSWRzLmluY2x1ZGVz
KCtjLmlkKSA/ICcgbXVsdGknIDogJycpOwogICAgICAgICAgICByb3cuZGF0YXNldC5pZCA9IGMu
aWQ7CgogICAgICAgICAgICBjb25zdCB0b3AgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYn
KTsKICAgICAgICAgICAgdG9wLmNsYXNzTmFtZSA9ICdtZy1yb3ctdG9wJzsKICAgICAgICAgICAg
Y29uc3QgbWFpbiA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOwogICAgICAgICAgICBt
YWluLmNsYXNzTmFtZSA9ICdtZy1yb3ctbWFpbic7CgogICAgICAgICAgICBjb25zdCB0aXRsZSA9
IFN0cmluZyhjLmZhdlRpdGxlIHx8ICcnKS50cmltKCk7CiAgICAgICAgICAgIGlmICh0aXRsZSkg
ewogICAgICAgICAgICAgICAgY29uc3QgdCA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2Rpdicp
OwogICAgICAgICAgICAgICAgdC5jbGFzc05hbWUgPSAnbWctdGl0bGUnOwogICAgICAgICAgICAg
ICAgc2V0SGxUZXh0KHQsIHRpdGxlKTsKICAgICAgICAgICAgICAgIG1haW4uYXBwZW5kQ2hpbGQo
dCk7CiAgICAgICAgICAgIH0KICAgICAgICAgICAgY29uc3QgYm9keSA9IGRvY3VtZW50LmNyZWF0
ZUVsZW1lbnQoJ2RpdicpOwogICAgICAgICAgICBib2R5LmNsYXNzTmFtZSA9ICdtZy1ib2R5JyAr
IChub3JtVHlwZShjLnR5cGUpID09PSAnaW1hZ2UnID8gJyBpbWcnIDogJycpOwogICAgICAgICAg
ICBzZXRIbFRleHQoYm9keSwgY2xpcENvbnRlbnRQcmV2aWV3KGMpKTsKICAgICAgICAgICAgbWFp
bi5hcHBlbmRDaGlsZChib2R5KTsKICAgICAgICAgICAgdG9wLmFwcGVuZENoaWxkKG1haW4pOwoK
ICAgICAgICAgICAgY29uc3Qgc3JjSWNvID0gU3RyaW5nKGMuc3JjSWNvbiB8fCAnJyk7CiAgICAg
ICAgICAgIGNvbnN0IHNyY0V4ZSA9IFN0cmluZyhjLnNyY0V4ZSB8fCAnJyk7CiAgICAgICAgICAg
IGNvbnN0IHNyY1RpdGxlID0gU3RyaW5nKGMuc3JjVGl0bGUgfHwgJycpOwogICAgICAgICAgICBp
ZiAoc3JjSWNvKSB7CiAgICAgICAgICAgICAgICBjb25zdCBpbWcgPSBkb2N1bWVudC5jcmVhdGVF
bGVtZW50KCdpbWcnKTsKICAgICAgICAgICAgICAgIGltZy5jbGFzc05hbWUgPSAnbWctc3JjJzsK
ICAgICAgICAgICAgICAgIGltZy5zcmMgPSBTVE9SRV9CQVNFICsgZW5jb2RlVVJJQ29tcG9uZW50
KHNyY0ljbyk7CiAgICAgICAgICAgICAgICBpbWcuYWx0ID0gJyc7CiAgICAgICAgICAgICAgICBj
b25zdCB0aXBUeHQgPSBzcmNUaXRsZSB8fCBzcmNFeGUgfHwgJ+adpea6kCc7CiAgICAgICAgICAg
ICAgICBpbWcudGl0bGUgPSB0aXBUeHQ7CiAgICAgICAgICAgICAgICBpbWcub25jbGljayA9IGUg
PT4geyBlLnByZXZlbnREZWZhdWx0KCk7IGUuc3RvcFByb3BhZ2F0aW9uKCk7IHNob3dTcmNUaXAo
aW1nLCB0aXBUeHQpOyB9OwogICAgICAgICAgICAgICAgdG9wLmFwcGVuZENoaWxkKGltZyk7CiAg
ICAgICAgICAgIH0KICAgICAgICAgICAgcm93LmFwcGVuZENoaWxkKHRvcCk7CgogICAgICAgICAg
ICByb3cub25wb2ludGVyZG93biA9IGUgPT4gewogICAgICAgICAgICAgICAgaWYgKGUuYnV0dG9u
ICE9PSAwKSByZXR1cm47CiAgICAgICAgICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAg
ICAgICAgICAgICAgYmVnaW5QYXN0ZUZyb21JdGVtKGUsIGMpOwogICAgICAgICAgICB9OwogICAg
ICAgICAgICByb3cub25jb250ZXh0bWVudSA9IGUgPT4gewogICAgICAgICAgICAgICAgZS5wcmV2
ZW50RGVmYXVsdCgpOwogICAgICAgICAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAg
ICAgICAgICAgIHNlbGVjdGVkSWQgPSBjLmlkOwogICAgICAgICAgICAgICAgc2hvd0N0eChlLmNs
aWVudFgsIGUuY2xpZW50WSwgYyk7CiAgICAgICAgICAgIH07CiAgICAgICAgICAgIGVsLmFwcGVu
ZENoaWxkKHJvdyk7CiAgICAgICAgfSk7CgogICAgICAgIGVsLm9uY29udGV4dG1lbnUgPSBlID0+
IHsKICAgICAgICAgICAgaWYgKGUudGFyZ2V0LmNsb3Nlc3QoJy5tZy1yb3cnKSkgcmV0dXJuOwog
ICAgICAgICAgICBlLnByZXZlbnREZWZhdWx0KCk7CiAgICAgICAgICAgIHNlbGVjdGVkSWQgPSBp
dGVtc1swXS5pZDsKICAgICAgICAgICAgc2hvd0N0eChlLmNsaWVudFgsIGUuY2xpZW50WSwgaXRl
bXNbMF0pOwogICAgICAgIH07CiAgICAgICAgcmV0dXJuIGVsOwogICAgfQoKCiAgICBmdW5jdGlv
biBidWlsZFJlY2VudFBhdGhDcnVtYnMoY29udGFpbmVyLCBmdWxsUGF0aCkgewogICAgICAgIGlm
ICghY29udGFpbmVyKSByZXR1cm47CiAgICAgICAgY29udGFpbmVyLnF1ZXJ5U2VsZWN0b3JBbGwo
Jy5yZi1zZWcsIC5yZi1zZXAnKS5mb3JFYWNoKG4gPT4gbi5yZW1vdmUoKSk7CiAgICAgICAgY29u
c3QgcmF3ID0gU3RyaW5nKGZ1bGxQYXRoIHx8ICcnKS5yZXBsYWNlKC9cLy9nLCAnXFwnKS5yZXBs
YWNlKC9cXCskLywgJycpOwogICAgICAgIGlmICghcmF3KSByZXR1cm47CiAgICAgICAgY29uc3Qg
dW5jID0gcmF3LnN0YXJ0c1dpdGgoJ1xcXFwnKTsKICAgICAgICBsZXQgcmVzdCA9IHVuYyA/IHJh
dy5zbGljZSgyKSA6IHJhdzsKICAgICAgICBjb25zdCBwYXJ0cyA9IHJlc3Quc3BsaXQoJ1xcJyku
ZmlsdGVyKEJvb2xlYW4pOwogICAgICAgIGNvbnN0IGFkZFNlZyA9IChsYWJlbCwgb3BlblBhdGgp
ID0+IHsKICAgICAgICAgICAgaWYgKGNvbnRhaW5lci5xdWVyeVNlbGVjdG9yKCcucmYtc2VnLCAu
cmYtc2VwJykpIHsKICAgICAgICAgICAgICAgIGNvbnN0IHNlcCA9IGRvY3VtZW50LmNyZWF0ZUVs
ZW1lbnQoJ3NwYW4nKTsKICAgICAgICAgICAgICAgIHNlcC5jbGFzc05hbWUgPSAncmYtc2VwJzsK
ICAgICAgICAgICAgICAgIHNlcC50ZXh0Q29udGVudCA9ICdcXCc7CiAgICAgICAgICAgICAgICBj
b250YWluZXIuYXBwZW5kQ2hpbGQoc2VwKTsKICAgICAgICAgICAgfQogICAgICAgICAgICAvLyBi
dXR0b27vvJrlkb3kuK3mm7TnqLPvvIzkuI3ooqsgYXBwLXJlZ2lvbiAvIOeItue6pyBwb2ludGVy
IOWQg+aOiQogICAgICAgICAgICBjb25zdCBzZWcgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdi
dXR0b24nKTsKICAgICAgICAgICAgc2VnLnR5cGUgPSAnYnV0dG9uJzsKICAgICAgICAgICAgc2Vn
LmNsYXNzTmFtZSA9ICdyZi1zZWcnOwogICAgICAgICAgICBzZXRIbFRleHQoc2VnLCBsYWJlbCk7
CiAgICAgICAgICAgIHNlZy50aXRsZSA9ICfmiZPlvIA6ICcgKyBvcGVuUGF0aDsKICAgICAgICAg
ICAgc2VnLnNldEF0dHJpYnV0ZSgnZGF0YS1wYXRoJywgb3BlblBhdGgucmVwbGFjZSgvXFwvZywg
Jy8nKSk7CiAgICAgICAgICAgIHNlZy5fb3BlblBhdGggPSBvcGVuUGF0aDsKICAgICAgICAgICAg
c2VnLmFkZEV2ZW50TGlzdGVuZXIoJ2NsaWNrJywgZSA9PiB7CiAgICAgICAgICAgICAgICBlLnBy
ZXZlbnREZWZhdWx0KCk7CiAgICAgICAgICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAg
ICAgICAgICAgICAgb3BlblJlY2VudERpcihvcGVuUGF0aCk7CiAgICAgICAgICAgIH0sIHRydWUp
OwogICAgICAgICAgICBzZWcuYWRkRXZlbnRMaXN0ZW5lcigncG9pbnRlcmRvd24nLCBlID0+IHsK
ICAgICAgICAgICAgICAgIGlmIChlLmJ1dHRvbiAhPT0gMCkgcmV0dXJuOwogICAgICAgICAgICAg
ICAgZS5wcmV2ZW50RGVmYXVsdCgpOwogICAgICAgICAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24o
KTsKICAgICAgICAgICAgICAgIG9wZW5SZWNlbnREaXIob3BlblBhdGgpOwogICAgICAgICAgICB9
LCB0cnVlKTsKICAgICAgICAgICAgY29udGFpbmVyLmFwcGVuZENoaWxkKHNlZyk7CiAgICAgICAg
fTsKICAgICAgICBpZiAoIXBhcnRzLmxlbmd0aCkgewogICAgICAgICAgICBhZGRTZWcocmF3LCBy
YXcpOwogICAgICAgICAgICByZXR1cm47CiAgICAgICAgfQogICAgICAgIGxldCBhY2MgPSB1bmMg
PyAnXFxcXCcgKyBwYXJ0c1swXSA6IHBhcnRzWzBdOwogICAgICAgIGlmICghdW5jICYmIC9eW2Et
ekEtWl06JC8udGVzdChwYXJ0c1swXSkpCiAgICAgICAgICAgIGFjYyA9IHBhcnRzWzBdICsgJ1xc
JzsKICAgICAgICBhZGRTZWcocGFydHNbMF0sIGFjYyk7CiAgICAgICAgZm9yIChsZXQgaSA9IDE7
IGkgPCBwYXJ0cy5sZW5ndGg7IGkrKykgewogICAgICAgICAgICBhY2MgPSBhY2MucmVwbGFjZSgv
XFwrJC8sICcnKSArICdcXCcgKyBwYXJ0c1tpXTsKICAgICAgICAgICAgYWRkU2VnKHBhcnRzW2ld
LCBhY2MpOwogICAgICAgIH0KICAgIH0KCiAgICBmdW5jdGlvbiBhY3RpdmF0ZUNsaXBJdGVtKGMp
IHsKICAgICAgICBpZiAoIWMpIHJldHVybjsKICAgICAgICBpZiAobm9ybVR5cGUoYy50eXBlKSA9
PT0gJ3JlY2VudCcpIHsKICAgICAgICAgICAgX19wcmVwUGFzdGUoKTsKICAgICAgICAgICAgc2Vs
ZWN0ZWRJZCA9IGMuaWQ7CiAgICAgICAgICAgIGlmIChtdWx0aUlkcy5sZW5ndGgpIGNsZWFyTXVs
dGkoKTsKICAgICAgICAgICAgc3luY0l0ZW1IaWdobGlnaHQoKTsKICAgICAgICAgICAgYWhrKCdw
YXN0ZScsIFN0cmluZyhjLmlkKSk7CiAgICAgICAgICAgIHJldHVybjsKICAgICAgICB9CiAgICAg
ICAgcGFzdGVPbmUoYyk7CiAgICB9CiAgICBmdW5jdGlvbiBtYWtlSXRlbShjLCBpZHgpIHsKICAg
ICAgICBjb25zdCB0eXBlICAgPSBub3JtVHlwZShjLnR5cGUpOwogICAgICAgIGNvbnN0IHBpbm5l
ZCA9IGlzUGlubmVkKGMpOwogICAgICAgIGNvbnN0IHBhc3RlZCA9IGlzUGFzdGVkKGMpOwogICAg
ICAgIGNvbnN0IGVsICAgICA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOwogICAgICAg
IGVsLmNsYXNzTmFtZSAgPSAnaXRtJwogICAgICAgICAgICArIChzZWxlY3RlZElkID09IGMuaWQg
PyAnIHNlbCcgOiAnJykKICAgICAgICAgICAgKyAobXVsdGlJZHMuaW5jbHVkZXMoK2MuaWQpID8g
JyBtdWx0aScgOiAnJyk7CiAgICAgICAgZWwuZGF0YXNldC5pZCA9IGMuaWQ7CiAgICAgICAgY29u
c3QgcWcgPSBOdW1iZXIoYy5xdWV1ZUdyb3VwKSB8fCAwOwogICAgICAgIGlmIChxZyA+IDApIHsK
ICAgICAgICAgICAgZWwuY2xhc3NMaXN0LmFkZCgncS1tZW1iZXInKTsKICAgICAgICAgICAgZWwu
ZGF0YXNldC5xZyA9IFN0cmluZyhxZyk7CiAgICAgICAgICAgIGVsLmRhdGFzZXQucWkgPSBTdHJp
bmcoTnVtYmVyKGMucXVldWVJbmRleCkgfHwgMCk7CiAgICAgICAgICAgIGlmIChwYXN0ZWQpIGVs
LmNsYXNzTGlzdC5hZGQoJ3EtZG9uZScpOwogICAgICAgICAgICBjb25zdCByYWlsID0gZG9jdW1l
bnQuY3JlYXRlRWxlbWVudCgnc3BhbicpOwogICAgICAgICAgICByYWlsLmNsYXNzTmFtZSA9ICdx
LXJhaWwnOwogICAgICAgICAgICBjb25zdCBkb3QgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdz
cGFuJyk7CiAgICAgICAgICAgIGRvdC5jbGFzc05hbWUgPSAncS1kb3QnOwogICAgICAgICAgICBk
b3QudGl0bGUgPSBwYXN0ZWQgPyAn6Zif5YiX5bey57KY6LS0JyA6ICfnspjotLTpmJ/liJcnOwog
ICAgICAgICAgICBlbC5hcHBlbmRDaGlsZChyYWlsKTsKICAgICAgICAgICAgZWwuYXBwZW5kQ2hp
bGQoZG90KTsKICAgICAgICB9CgogICAgICAgIGNvbnN0IGljbyAgPSBkb2N1bWVudC5jcmVhdGVF
bGVtZW50KCdkaXYnKTsKICAgICAgICBjb25zdCBib2R5ID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVu
dCgnZGl2Jyk7CiAgICAgICAgYm9keS5jbGFzc05hbWUgPSAnaS1ib2R5JzsKCiAgICAgICAgaWYg
KHR5cGUgPT09ICdpbWFnZScpIHsKICAgICAgICAgICAgaWNvLmNsYXNzTmFtZSA9ICdpLWljbyBp
bWFnZSc7CiAgICAgICAgICAgIGljby5pbm5lckhUTUwgPSBTVkcuaW1hZ2U7CiAgICAgICAgICAg
IGJpbmRJbWdIb3ZlclByZXZpZXcoaWNvLCBjLmlkLCBjLmltZ0ZpbGUpOwogICAgICAgICAgICBj
b25zdCB3cmFwID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnZGl2Jyk7CiAgICAgICAgICAgIHdy
YXAuY2xhc3NOYW1lID0gJ2ktdGh1bWItd3JhcCc7CiAgICAgICAgICAgIGNvbnN0IGltZyAgPSBk
b2N1bWVudC5jcmVhdGVFbGVtZW50KCdpbWcnKTsKICAgICAgICAgICAgaW1nLmNsYXNzTmFtZSA9
ICdpLXRodW1iJzsKICAgICAgICAgICAgaW1nLmFsdCA9ICcnOwogICAgICAgICAgICBjb25zdCBm
aWxlID0gU3RyaW5nKGMuaW1nRmlsZSB8fCAnJyk7CiAgICAgICAgICAgIGxldCBmYWxsYmFjayA9
IFN0cmluZyhjLmRhdGEgfHwgJycpOwogICAgICAgICAgICAvLyBOZXZlciBzeW5jLWNhbGwgQUhL
IHRodW1iIGhlcmUg4oCUIGZyZWV6ZXMgdGFiIHN3aXRjaGVzOyBQdXNoU3RvcmVUaHVtYnMgZmls
bHMgYXN5bmMKICAgICAgICAgICAgaWYgKCFmYWxsYmFjay5zdGFydHNXaXRoKCdkYXRhOicpICYm
IHRodW1iQ2FjaGUuaGFzKFN0cmluZyhjLmlkKSkpCiAgICAgICAgICAgICAgICBmYWxsYmFjayA9
IFN0cmluZyh0aHVtYkNhY2hlLmdldChTdHJpbmcoYy5pZCkpKTsKICAgICAgICAgICAgaW1nLm9u
bG9hZCA9ICgpID0+IHsKICAgICAgICAgICAgICAgIGNvbnN0IG13ID0gd3JhcC5jbGllbnRXaWR0
aCB8fCAzMDA7CiAgICAgICAgICAgICAgICBjb25zdCBudyA9IGltZy5uYXR1cmFsV2lkdGggIHx8
IDA7CiAgICAgICAgICAgICAgICBjb25zdCBuaCA9IGltZy5uYXR1cmFsSGVpZ2h0IHx8IDA7CiAg
ICAgICAgICAgICAgICBpZiAoIW53IHx8ICFuaCkgcmV0dXJuOwogICAgICAgICAgICAgICAgY29u
c3Qgc2NhbGUgPSBNYXRoLm1pbigxLCAxODAgLyBuaCwgbXcgLyBudyk7CiAgICAgICAgICAgICAg
ICBpbWcuc3R5bGUud2lkdGggID0gTWF0aC5yb3VuZChudyAqIHNjYWxlKSArICdweCc7CiAgICAg
ICAgICAgICAgICBpbWcuc3R5bGUuaGVpZ2h0ID0gTWF0aC5yb3VuZChuaCAqIHNjYWxlKSArICdw
eCc7CiAgICAgICAgICAgIH07CiAgICAgICAgICAgIGJpbmRTdG9yZVRodW1iKGltZywgZmlsZSwg
Yy5pZCwgZmFsbGJhY2spOwogICAgICAgICAgICB3cmFwLmFwcGVuZENoaWxkKGltZyk7CiAgICAg
ICAgICAgIGNvbnN0IG1ldGEgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsKICAgICAg
ICAgICAgbWV0YS5jbGFzc05hbWUgPSAnaS1tZXRhJzsKICAgICAgICAgICAgbWV0YS5pbm5lckhU
TUwgID0gYDxzcGFuIGNsYXNzPSJpLXRpbWUiPiR7YWdvKGMudGltZSl9PC9zcGFuPiR7bWV0YUNl
bnRlckh0bWwoZmFsc2UpfTxkaXYgY2xhc3M9ImktbWV0YS1yaWdodCI+JHtjLndpZHRoID8gYDxz
cGFuIGNsYXNzPSJpLXRhZyI+JHtjLndpZHRofcOXJHtjLmhlaWdodH0gcHg8L3NwYW4+YCA6ICcn
fTwvZGl2PmA7CiAgICAgICAgICAgIGJvZHkuYXBwZW5kQ2hpbGQod3JhcCk7CiAgICAgICAgICAg
IGJvZHkuYXBwZW5kQ2hpbGQobWV0YSk7CiAgICAgICAgfSBlbHNlIGlmICh0eXBlID09PSAncmVj
ZW50JykgewogICAgICAgICAgICBpY28uY2xhc3NOYW1lID0gJ2ktaWNvIGZpbGUgZnQtZGlyJzsK
ICAgICAgICAgICAgaWNvLmlubmVySFRNTCA9IFNWRy5mb2xkZXI7CiAgICAgICAgICAgIGlmIChw
aW5uZWQpIGVsLmNsYXNzTGlzdC5hZGQoJ3JmLWZpeGVkJyk7CiAgICAgICAgICAgIGNvbnN0IHBh
dGggPSBTdHJpbmcoYy5kYXRhIHx8IGMucHJldmlldyB8fCAnJyk7CiAgICAgICAgICAgIGNvbnN0
IGNydW1icyA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOwogICAgICAgICAgICBjcnVt
YnMuY2xhc3NOYW1lID0gJ3JmLXBhdGgnOwogICAgICAgICAgICBidWlsZFJlY2VudFBhdGhDcnVt
YnMoY3J1bWJzLCBwYXRoKTsKICAgICAgICAgICAgLy8g5Zu65a6a5qCH6K6w5Y+q5pS+IG1ldGEg
5Y+z5L6n77yM5LiN5oyh6Lev5b6ECiAgICAgICAgICAgIGNvbnN0IG1ldGEgPSBkb2N1bWVudC5j
cmVhdGVFbGVtZW50KCdkaXYnKTsKICAgICAgICAgICAgbWV0YS5jbGFzc05hbWUgPSAnaS1tZXRh
JzsKICAgICAgICAgICAgbWV0YS5pbm5lckhUTUwgPQogICAgICAgICAgICAgICAgYDxzcGFuIGNs
YXNzPSJpLXRpbWUiPiR7YWdvKGMudGltZSl9PC9zcGFuPmAgKwogICAgICAgICAgICAgICAgbWV0
YUNlbnRlckh0bWwoZmFsc2UpICsKICAgICAgICAgICAgICAgIGA8ZGl2IGNsYXNzPSJpLW1ldGEt
cmlnaHQiPiR7cGlubmVkID8gJzxzcGFuIGNsYXNzPSJyZi1waW4tdGFnIiB0aXRsZT0i5bey5Zu6
5a6a77yM5LiN5Lya6KKr5reY5rGwIj7lm7rlrpo8L3NwYW4+JyA6ICcnfTwvZGl2PmA7CiAgICAg
ICAgICAgIGJvZHkuYXBwZW5kQ2hpbGQoY3J1bWJzKTsKICAgICAgICAgICAgYm9keS5hcHBlbmRD
aGlsZChtZXRhKTsKICAgICAgICB9IGVsc2UgaWYgKHR5cGUgPT09ICdmaWxlJykgewogICAgICAg
ICAgICBjb25zdCBmaWxlcyA9IFN0cmluZyhjLnByZXZpZXcgfHwgYy5kYXRhIHx8ICcnKS5zcGxp
dCgvXHI/XG4vKS5maWx0ZXIoQm9vbGVhbik7CiAgICAgICAgICAgIGNvbnN0IGltYWdlUGF0aHMg
PSBmaWxlcy5maWx0ZXIoZiA9PiBpc0ltYWdlRXh0KGZpbGVFeHQoZikpKTsKICAgICAgICAgICAg
Y29uc3QgaWMgICAgPSBpY29uRm9yRmlsZXMoZmlsZXMpOwogICAgICAgICAgICBpY28uY2xhc3NO
YW1lID0gJ2ktaWNvICcgKyBpYy5jbHM7CiAgICAgICAgICAgIGljby5pbm5lckhUTUwgPSBpYy5z
dmc7CgogICAgICAgICAgICBsZXQgdGh1bWJGaWxlID0gU3RyaW5nKGMuaW1nRmlsZSB8fCAnJyk7
CiAgICAgICAgICAgIC8qIGVuc3VyZUZpbGVJbWcgZGVmZXJyZWQ6IGF2b2lkIHN5bmMgZnJlZXpl
IG9uIGZpbGUgdGFiICovCgogICAgICAgICAgICAvLyBJbWFnZS1mb3JtYXQgZmlsZXM6IHNhbWUg
dGh1bWJuYWlsIHJ1bGVzIGFzIHNjcmVlbnNob3QgY2xpcHMKICAgICAgICAgICAgaWYgKHRodW1i
RmlsZSB8fCBpbWFnZVBhdGhzLmxlbmd0aCkgewogICAgICAgICAgICAgICAgY29uc3Qgd3JhcCA9
IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOwogICAgICAgICAgICAgICAgd3JhcC5jbGFz
c05hbWUgPSAnaS10aHVtYi13cmFwJzsKICAgICAgICAgICAgICAgIGNvbnN0IGltZyAgPSBkb2N1
bWVudC5jcmVhdGVFbGVtZW50KCdpbWcnKTsKICAgICAgICAgICAgICAgIGltZy5jbGFzc05hbWUg
PSAnaS10aHVtYic7CiAgICAgICAgICAgICAgICBpbWcuYWx0ID0gJyc7CiAgICAgICAgICAgICAg
ICBpbWcub25sb2FkID0gKCkgPT4gewogICAgICAgICAgICAgICAgICAgIGNvbnN0IG13ID0gd3Jh
cC5jbGllbnRXaWR0aCB8fCAzMDA7CiAgICAgICAgICAgICAgICAgICAgY29uc3QgbncgPSBpbWcu
bmF0dXJhbFdpZHRoICB8fCAwOwogICAgICAgICAgICAgICAgICAgIGNvbnN0IG5oID0gaW1nLm5h
dHVyYWxIZWlnaHQgfHwgMDsKICAgICAgICAgICAgICAgICAgICBpZiAoIW53IHx8ICFuaCkgcmV0
dXJuOwogICAgICAgICAgICAgICAgICAgIGNvbnN0IHNjYWxlID0gTWF0aC5taW4oMSwgMTgwIC8g
bmgsIG13IC8gbncpOwogICAgICAgICAgICAgICAgICAgIGltZy5zdHlsZS53aWR0aCAgPSBNYXRo
LnJvdW5kKG53ICogc2NhbGUpICsgJ3B4JzsKICAgICAgICAgICAgICAgICAgICBpbWcuc3R5bGUu
aGVpZ2h0ID0gTWF0aC5yb3VuZChuaCAqIHNjYWxlKSArICdweCc7CiAgICAgICAgICAgICAgICB9
OwogICAgICAgICAgICAvKiBlbnN1cmVGaWxlSW1nIGRlZmVycmVkOiBhdm9pZCBzeW5jIGZyZWV6
ZSBvbiBmaWxlIHRhYiAqLwogICAgICAgICAgICAgICAgYmluZFN0b3JlVGh1bWIoaW1nLCB0aHVt
YkZpbGUsIGMuaWQsICcnKTsKICAgICAgICAgICAgICAgIHdyYXAuYXBwZW5kQ2hpbGQoaW1nKTsK
ICAgICAgICAgICAgICAgIGJvZHkuYXBwZW5kQ2hpbGQod3JhcCk7CiAgICAgICAgICAgIH0KCiAg
ICAgICAgICAgIGNvbnN0IG5hbWUgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsKICAg
ICAgICAgICAgbmFtZS5jbGFzc05hbWUgID0gJ2ktbmFtZSc7CiAgICAgICAgICAgIHNldEhsVGV4
dChuYW1lLCBmaWxlcy5tYXAoZiA9PiBmLnNwbGl0KC9bXFwvXS8pLnBvcCgpKS5qb2luKCdcbicp
IHx8ICco5paH5Lu2KScpOwoKICAgICAgICAgICAgZWwuX2ZpbGVQYXRocyA9IGZpbGVzOwoKICAg
ICAgICAgICAgY29uc3QgZGV0YWlsID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnZGl2Jyk7CiAg
ICAgICAgICAgIGRldGFpbC5jbGFzc05hbWUgPSAnaS1maWxlLWRldGFpbCc7CgogICAgICAgICAg
ICBjb25zdCBtZXRhID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnZGl2Jyk7CiAgICAgICAgICAg
IG1ldGEuY2xhc3NOYW1lID0gJ2ktbWV0YSc7CiAgICAgICAgICAgIGxldCByaWdodCA9ICcnOwog
ICAgICAgICAgICByaWdodCArPSBgPHNwYW4gY2xhc3M9ImktdGFnIj4ke2MuZmlsZUNvdW50IHx8
IGZpbGVzLmxlbmd0aCB8fCAxfSDkuKrmlofku7Y8L3NwYW4+YDsKICAgICAgICAgICAgaWYgKCh0
aHVtYkZpbGUgfHwgaW1hZ2VQYXRocy5sZW5ndGgpICYmIGMud2lkdGgpCiAgICAgICAgICAgICAg
ICByaWdodCArPSBgPHNwYW4gY2xhc3M9ImktdGFnIj4ke2Mud2lkdGh9w5cke2MuaGVpZ2h0fSBw
eDwvc3Bhbj5gOwogICAgICAgICAgICBjb25zdCBleHBhbmRIdG1sID0gZXhwYW5kQ2hldnJvbihm
YWxzZSk7CiAgICAgICAgICAgIGNvbnN0IGNvbGxhcHNlSHRtbCA9IGV4cGFuZENoZXZyb24odHJ1
ZSk7CiAgICAgICAgICAgIG1ldGEuaW5uZXJIVE1MID0KICAgICAgICAgICAgICAgIGA8c3BhbiBj
bGFzcz0iaS10aW1lIj4ke2FnbyhjLnRpbWUpfTwvc3Bhbj5gICsKICAgICAgICAgICAgICAgIG1l
dGFDZW50ZXJIdG1sKHsgb246IHRydWUsIGh0bWw6IGV4cGFuZEh0bWwgfSkgKwogICAgICAgICAg
ICAgICAgYDxkaXYgY2xhc3M9ImktbWV0YS1yaWdodCI+JHtyaWdodH08L2Rpdj5gOwoKICAgICAg
ICAgICAgY29uc3QgZXhwQnRuID0gbWV0YS5xdWVyeVNlbGVjdG9yKCcuaS1leHBhbmQtYnRuJyk7
CiAgICAgICAgICAgIGxldCBkZXRhaWxCdWlsdCA9IGZhbHNlOwogICAgICAgICAgICBleHBCdG4u
b25jbGljayA9IGUgPT4gewogICAgICAgICAgICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOwogICAg
ICAgICAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICAgICAgICAgIGNvbnN0IG9w
ZW4gPSAhZGV0YWlsLmNsYXNzTGlzdC5jb250YWlucygnb24nKTsKICAgICAgICAgICAgICAgIGlm
IChvcGVuICYmICFkZXRhaWxCdWlsdCkgewogICAgICAgICAgICAgICAgICAgIGNvbnN0IHBhdGhS
b3dzID0gZWwuX3BhdGhSb3dzIHx8IGNoZWNrRmlsZVBhdGhzKGVsLl9maWxlUGF0aHMgfHwgZmls
ZXMpOwogICAgICAgICAgICAgICAgICAgIGZpbGxGaWxlRGV0YWlsUGFuZWwoZGV0YWlsLCBwYXRo
Um93cyk7CiAgICAgICAgICAgICAgICAgICAgZGV0YWlsQnVpbHQgPSB0cnVlOwogICAgICAgICAg
ICAgICAgfQogICAgICAgICAgICAgICAgZGV0YWlsLmNsYXNzTGlzdC50b2dnbGUoJ29uJywgb3Bl
bik7CiAgICAgICAgICAgICAgICBpZiAob3BlbikgewogICAgICAgICAgICAgICAgICAgIGRldGFp
bC5zdHlsZS5tYXhIZWlnaHQgPSBsaXN0RXhwYW5kTWF4UHgoKSArICdweCc7CiAgICAgICAgICAg
ICAgICAgICAgZGV0YWlsLnN0eWxlLm92ZXJmbG93ID0gJ2F1dG8nOwogICAgICAgICAgICAgICAg
fSBlbHNlIHsKICAgICAgICAgICAgICAgICAgICBkZXRhaWwuc3R5bGUubWF4SGVpZ2h0ID0gJyc7
CiAgICAgICAgICAgICAgICAgICAgZGV0YWlsLnN0eWxlLm92ZXJmbG93ID0gJyc7CiAgICAgICAg
ICAgICAgICB9CiAgICAgICAgICAgICAgICBleHBCdG4uaW5uZXJIVE1MID0gb3BlbiA/IGNvbGxh
cHNlSHRtbCA6IGV4cGFuZEh0bWw7CiAgICAgICAgICAgIH07CgogICAgICAgICAgICBib2R5LmFw
cGVuZENoaWxkKG5hbWUpOwogICAgICAgICAgICBib2R5LmFwcGVuZENoaWxkKGRldGFpbCk7CiAg
ICAgICAgICAgIGJvZHkuYXBwZW5kQ2hpbGQobWV0YSk7CiAgICAgICAgfSBlbHNlIHsKICAgICAg
ICAgICAgY29uc3QgdXNlTSA9IGNsaXBVc2VzTUljb24oYyk7CiAgICAgICAgICAgIGljby5jbGFz
c05hbWUgPSB1c2VNID8gJ2ktaWNvIG1kJyA6ICdpLWljbyB0ZXh0JzsKICAgICAgICAgICAgaWNv
LmlubmVySFRNTCA9IHVzZU0gPyAoU1ZHLm1kIHx8IFNWRy50ZXh0KSA6IFNWRy50ZXh0OwogICAg
ICAgICAgICAvKiBwbGFpbi1saXN0LXByZXYgKi8KICAgICAgICAgICAgLyogcHJldmlldy1lbGxp
cHNpcyAqLwogICAgICAgICAgICBsZXQgdHh0ICA9IGMucHJldmlldyB8fCBjLmRhdGEgfHwgJyc7
CiAgICAgICAgICAgIHsgY29uc3QgX24gPSBOdW1iZXIoYy5jaGFyQ291bnQpIHx8IDA7IGlmIChf
biA+IHR4dC5sZW5ndGggJiYgdHh0Lmxlbmd0aCkgdHh0ICs9ICcuLi4nOyB9CiAgICAgICAgICAg
IGNvbnN0IHByZXYgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsKICAgICAgICAgICAg
cHJldi5jbGFzc05hbWUgID0gJ2ktcHJldicgKyAoaXNVcmwodHh0KSA/ICcgdXJsJyA6ICcnKTsK
ICAgICAgICAgICAgc2V0SGxUZXh0KHByZXYsIHR4dCk7CgogICAgICAgICAgICBjb25zdCBtZXRh
ID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnZGl2Jyk7CiAgICAgICAgICAgIG1ldGEuY2xhc3NO
YW1lID0gJ2ktbWV0YSc7CgogICAgICAgICAgICBjb25zdCBjaGFycyA9IE51bWJlcihjLmNoYXJD
b3VudCkgfHwgMDsKICAgICAgICAgICAgY29uc3QgcmlnaHRIVE1MID0gYDxzcGFuIGNsYXNzPSJp
LWNoYXJzIj48c3BhbiBjbGFzcz0ibiI+JHtjaGFyc308L3NwYW4+IOWtl+espjwvc3Bhbj5gOwoK
ICAgICAgICAgICAgbWV0YS5pbm5lckhUTUwgPQogICAgICAgICAgICAgICAgYDxzcGFuIGNsYXNz
PSJpLXRpbWUiPiR7YWdvKGMudGltZSl9PC9zcGFuPmAgKwogICAgICAgICAgICAgICAgbWV0YUNl
bnRlckh0bWwoewogICAgICAgICAgICAgICAgICAgIG9uOiBmYWxzZSwKICAgICAgICAgICAgICAg
ICAgICBodG1sOiBleHBhbmRDaGV2cm9uKGZhbHNlKQogICAgICAgICAgICAgICAgfSkgKwogICAg
ICAgICAgICAgICAgYDxkaXYgY2xhc3M9ImktbWV0YS1yaWdodCB0ZXh0LW1ldGEiPiR7cmlnaHRI
VE1MfTwvZGl2PmA7CgogICAgICAgICAgICBib2R5LmFwcGVuZENoaWxkKHByZXYpOwogICAgICAg
ICAgICBib2R5LmFwcGVuZENoaWxkKG1ldGEpOwoKICAgICAgICAgICAgY29uc3QgZXhwQnRuID0g
bWV0YS5xdWVyeVNlbGVjdG9yKCcuaS1leHBhbmQtYnRuJyk7CiAgICAgICAgICAgIGlmIChleHBC
dG4pIHsKICAgICAgICAgICAgICAgIGV4cEJ0bi5vbmNsaWNrID0gZSA9PiB7CiAgICAgICAgICAg
ICAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICAgICAgICAgICAgICBjb25zdCB3
aWxsRXhwYW5kID0gIXByZXYuY2xhc3NMaXN0LmNvbnRhaW5zKCdleHBhbmRlZCcpOwogICAgICAg
ICAgICAgICAgICAgIGlmICh3aWxsRXhwYW5kKSB7CiAgICAgICAgICAgICAgICAgICAgICAgIGFw
cGx5RXhwYW5kZWRQcmV2aWV3KHByZXYsIHR4dCk7CiAgICAgICAgICAgICAgICAgICAgICAgIGV4
cEJ0bi5pbm5lckhUTUwgPSBleHBhbmRDaGV2cm9uKHRydWUpOwogICAgICAgICAgICAgICAgICAg
ICAgICB0cnkgeyBlbC5zY3JvbGxJbnRvVmlldyh7IGJsb2NrOiAnbmVhcmVzdCcgfSk7IH0gY2F0
Y2gge30KICAgICAgICAgICAgICAgICAgICB9IGVsc2UgewogICAgICAgICAgICAgICAgICAgICAg
ICBjb2xsYXBzZVByZXZpZXcocHJldiwgdHh0KTsKICAgICAgICAgICAgICAgICAgICAgICAgZXhw
QnRuLmlubmVySFRNTCA9IGV4cGFuZENoZXZyb24oZmFsc2UpOwogICAgICAgICAgICAgICAgICAg
IH0KICAgICAgICAgICAgICAgIH07CiAgICAgICAgICAgICAgICBjb25zdCBjaGVja092ZXJmbG93
ID0gKCkgPT4gewogICAgICAgICAgICAgICAgICAgIGNvbnN0IHBsYWluTGVuID0gU3RyaW5nKGMu
cHJldmlldyB8fCBjLmRhdGEgfHwgJycpLmxlbmd0aDsKICAgICAgICAgICAgICAgICAgICBjb25z
dCBmdWxsTiA9IE51bWJlcihjLmNoYXJDb3VudCkgfHwgMDsKICAgICAgICAgICAgICAgICAgICBj
b25zdCB0cnVuYyA9IGZ1bGxOID4gcGxhaW5MZW47CiAgICAgICAgICAgICAgICAgICAgaWYgKHBy
ZXYuc2Nyb2xsSGVpZ2h0ID4gcHJldi5jbGllbnRIZWlnaHQgKyAyIHx8IHRydW5jKQogICAgICAg
ICAgICAgICAgICAgICAgICBleHBCdG4uY2xhc3NMaXN0LmFkZCgnb24nKTsKICAgICAgICAgICAg
ICAgICAgICBlbHNlCiAgICAgICAgICAgICAgICAgICAgICAgIGV4cEJ0bi5jbGFzc0xpc3QucmVt
b3ZlKCdvbicpOwogICAgICAgICAgICAgICAgfTsKICAgICAgICAgICAgICAgIHJlcXVlc3RBbmlt
YXRpb25GcmFtZShjaGVja092ZXJmbG93KTsKICAgICAgICAgICAgICAgIHNldFRpbWVvdXQoY2hl
Y2tPdmVyZmxvdywgODApOwogICAgICAgICAgICB9CiAgICAgICAgfQoKICAgICAgICBjb25zdCBm
YXZUID0gU3RyaW5nKGMuZmF2VGl0bGUgfHwgJycpLnRyaW0oKTsKICAgICAgICBpZiAoZmF2VCkg
ewogICAgICAgICAgICBjb25zdCBmdCA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOwog
ICAgICAgICAgICBmdC5jbGFzc05hbWUgPSAnaS1mYXYtdGl0bGUnOwogICAgICAgICAgICBzZXRI
bFRleHQoZnQsIGZhdlQpOwogICAgICAgICAgICBib2R5Lmluc2VydEJlZm9yZShmdCwgYm9keS5m
aXJzdENoaWxkKTsKICAgICAgICB9CgogICAgICAgIGlmIChwYXN0ZWQpIHsKICAgICAgICAgICAg
ZWwuY2xhc3NMaXN0LmFkZCgncGFzdGVkJyk7CiAgICAgICAgICAgIGNvbnN0IGJhZGdlID0gZG9j
dW1lbnQuY3JlYXRlRWxlbWVudCgnc3BhbicpOwogICAgICAgICAgICBiYWRnZS5jbGFzc05hbWUg
PSAnaS11c2VkJzsKICAgICAgICAgICAgYmFkZ2UudGl0bGUgPSAn5bey57KY6LS0JzsKICAgICAg
ICAgICAgYmFkZ2UuaW5uZXJIVE1MID0gYDxzdmcgdmlld0JveD0iMCAwIDE2IDE2IiBmaWxsPSJu
b25lIiBzdHJva2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIyLjQiIHN0cm9rZS1saW5l
Y2FwPSJyb3VuZCIgc3Ryb2tlLWxpbmVqb2luPSJyb3VuZCI+PHBvbHlsaW5lIHBvaW50cz0iMy41
IDguNSA2LjUgMTEuNSAxMi41IDQuNSIvPjwvc3ZnPmA7CiAgICAgICAgICAgIGljby5hcHBlbmRD
aGlsZChiYWRnZSk7CiAgICAgICAgfQoKICAgICAgICBjb25zdCBudW0gPSBkb2N1bWVudC5jcmVh
dGVFbGVtZW50KCdkaXYnKTsKICAgICAgICBudW0uY2xhc3NOYW1lID0gJ2ktbnVtJzsKICAgICAg
ICBjb25zdCBudW1UeHQgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdzcGFuJyk7CiAgICAgICAg
bnVtVHh0LnRleHRDb250ZW50ID0gaWR4OwogICAgICAgIG51bS5hcHBlbmRDaGlsZChudW1UeHQp
OwogICAgICAgIGNvbnN0IHNyY0ljbyA9IFN0cmluZyhjLnNyY0ljb24gfHwgJycpOwogICAgICAg
IGNvbnN0IHNyY0V4ZSA9IFN0cmluZyhjLnNyY0V4ZSB8fCAnJyk7CiAgICAgICAgY29uc3Qgc3Jj
VGl0bGUgPSBTdHJpbmcoYy5zcmNUaXRsZSB8fCAnJyk7CiAgICAgICAgaWYgKHNyY0ljbykgewog
ICAgICAgICAgICBjb25zdCBpbWcgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdpbWcnKTsKICAg
ICAgICAgICAgaW1nLmNsYXNzTmFtZSA9ICdpLXNyYy1pY28nOwogICAgICAgICAgICBpbWcuc3Jj
ID0gU1RPUkVfQkFTRSArIGVuY29kZVVSSUNvbXBvbmVudChzcmNJY28pOwogICAgICAgICAgICBp
bWcuYWx0ID0gJyc7CiAgICAgICAgICAgIGNvbnN0IHRpcFR4dCA9IHNyY1RpdGxlIHx8IHNyY0V4
ZSB8fCAn5p2l5rqQJzsKICAgICAgICAgICAgaW1nLnRpdGxlID0gdGlwVHh0OwogICAgICAgICAg
ICBpbWcub25jbGljayA9IGUgPT4geyBlLnByZXZlbnREZWZhdWx0KCk7IGUuc3RvcFByb3BhZ2F0
aW9uKCk7IHNob3dTcmNUaXAoaW1nLCB0aXBUeHQpOyB9OwogICAgICAgICAgICBudW0uYXBwZW5k
Q2hpbGQoaW1nKTsKICAgICAgICB9CgogICAgICAgIGVsLmFwcGVuZENoaWxkKGljbyk7CiAgICAg
ICAgZWwuYXBwZW5kQ2hpbGQoYm9keSk7CiAgICAgICAgZWwuYXBwZW5kQ2hpbGQobnVtKTsKCiAg
ICAgICAgZWwub25wb2ludGVyZG93biA9IGUgPT4gewogICAgICAgICAgICBiZWdpblBhc3RlRnJv
bUl0ZW0oZSwgYyk7CiAgICAgICAgfTsKICAgICAgICBlbC5vbmNvbnRleHRtZW51ID0gZSA9PiB7
CiAgICAgICAgICAgIGUucHJldmVudERlZmF1bHQoKTsKICAgICAgICAgICAgc2VsZWN0ZWRJZCA9
IGMuaWQ7CiAgICAgICAgICAgIHNob3dDdHgoZS5jbGllbnRYLCBlLmNsaWVudFksIGMpOwogICAg
ICAgIH07CgogICAgICAgIHJldHVybiBlbDsKICAgIH0KCiAgICBmdW5jdGlvbiBpdGVtSXNRdWV1
ZURvbmUocm93KSB7CiAgICAgICAgaWYgKCFyb3cpIHJldHVybiBmYWxzZTsKICAgICAgICBpZiAo
cm93LmNsYXNzTGlzdC5jb250YWlucygncGFzdGVkJykgfHwgcm93LmNsYXNzTGlzdC5jb250YWlu
cygncS1kb25lJykpCiAgICAgICAgICAgIHJldHVybiB0cnVlOwogICAgICAgIGNvbnN0IGlkID0g
K3Jvdy5kYXRhc2V0LmlkOwogICAgICAgIGNvbnN0IGMgPSBhbGxDbGlwcy5maW5kKHggPT4gK3gu
aWQgPT09IGlkKTsKICAgICAgICByZXR1cm4gISEoYyAmJiBpc1Bhc3RlZChjKSk7CiAgICB9Cgog
ICAgZnVuY3Rpb24gbWFya1F1ZXVlUmFpbHMoKSB7CiAgICAgICAgaWYgKCFsaXN0RWwpIHJldHVy
bjsKICAgICAgICBjb25zdCBub2RlcyA9IFsuLi5saXN0RWwucXVlcnlTZWxlY3RvckFsbCgnLml0
bS5xLW1lbWJlcicpXTsKICAgICAgICBpZiAoIW5vZGVzLmxlbmd0aCkgcmV0dXJuOwogICAgICAg
IC8vIFJlc2V0IGxpbmsgY2xhc3Nlczsga2VlcCBzdHJ1Y3R1cmFsIGVuZHMKICAgICAgICBub2Rl
cy5mb3JFYWNoKG4gPT4gbi5jbGFzc0xpc3QucmVtb3ZlKCdxLWZpcnN0JywgJ3EtbGFzdCcsICdx
LW9ubHknLCAncS1kb25lLWxpbmsnLCAncS1wYXN0ZWQtbmV4dCcpKTsKICAgICAgICAvLyBHcm91
cCBjb25zZWN1dGl2ZSBzYW1lIHF1ZXVlR3JvdXAgaW4gRE9NIG9yZGVyCiAgICAgICAgbGV0IGkg
PSAwOwogICAgICAgIHdoaWxlIChpIDwgbm9kZXMubGVuZ3RoKSB7CiAgICAgICAgICAgIGNvbnN0
IGcgPSBub2Rlc1tpXS5kYXRhc2V0LnFnOwogICAgICAgICAgICBsZXQgaiA9IGkgKyAxOwogICAg
ICAgICAgICB3aGlsZSAoaiA8IG5vZGVzLmxlbmd0aCAmJiBub2Rlc1tqXS5kYXRhc2V0LnFnID09
PSBnKSBqKys7CiAgICAgICAgICAgIGNvbnN0IHNsaWNlID0gbm9kZXMuc2xpY2UoaSwgaik7CiAg
ICAgICAgICAgIGlmIChzbGljZS5sZW5ndGggPT09IDEpIHsKICAgICAgICAgICAgICAgIHNsaWNl
WzBdLmNsYXNzTGlzdC5hZGQoJ3Etb25seScpOwogICAgICAgICAgICB9IGVsc2UgewogICAgICAg
ICAgICAgICAgc2xpY2VbMF0uY2xhc3NMaXN0LmFkZCgncS1maXJzdCcpOwogICAgICAgICAgICAg
ICAgc2xpY2Vbc2xpY2UubGVuZ3RoIC0gMV0uY2xhc3NMaXN0LmFkZCgncS1sYXN0Jyk7CiAgICAg
ICAgICAgIH0KICAgICAgICAgICAgZm9yIChsZXQgayA9IDA7IGsgPCBzbGljZS5sZW5ndGg7IGsr
KykgewogICAgICAgICAgICAgICAgY29uc3QgZG9uZSA9IGl0ZW1Jc1F1ZXVlRG9uZShzbGljZVtr
XSk7CiAgICAgICAgICAgICAgICBzbGljZVtrXS5jbGFzc0xpc3QudG9nZ2xlKCdxLWRvbmUnLCBk
b25lKTsKICAgICAgICAgICAgICAgIGNvbnN0IGRvdCA9IHNsaWNlW2tdLnF1ZXJ5U2VsZWN0b3Io
Jy5xLWRvdCcpOwogICAgICAgICAgICAgICAgaWYgKGRvdCkgZG90LnRpdGxlID0gZG9uZSA/ICfp
mJ/liJflt7LnspjotLQnIDogJ+eymOi0tOmYn+WIlyc7CiAgICAgICAgICAgICAgICAvLyBHcmVl
biByYWlsIGZvciBldmVyeSBpdGVtIGluIGEgMisgZGVxdWV1ZWQgcnVuIChpbmNsLiBmaXJzdC9s
YXN0IHN0dWJzKQogICAgICAgICAgICAgICAgY29uc3QgcHJldkRvbmUgPSBrID4gMCAmJiBpdGVt
SXNRdWV1ZURvbmUoc2xpY2VbayAtIDFdKTsKICAgICAgICAgICAgICAgIGNvbnN0IG5leHREb25l
ID0gayA8IHNsaWNlLmxlbmd0aCAtIDEgJiYgaXRlbUlzUXVldWVEb25lKHNsaWNlW2sgKyAxXSk7
CiAgICAgICAgICAgICAgICBpZiAoZG9uZSAmJiAocHJldkRvbmUgfHwgbmV4dERvbmUpKQogICAg
ICAgICAgICAgICAgICAgIHNsaWNlW2tdLmNsYXNzTGlzdC5hZGQoJ3EtZG9uZS1saW5rJyk7CiAg
ICAgICAgICAgIH0KICAgICAgICAgICAgaSA9IGo7CiAgICAgICAgfQogICAgfQoKICAgIGNvbnN0
IHBhdGhUaXBFbCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdwYXRoLXRpcCcpOwogICAgbGV0
IHBhdGhUaXBUaW1lciA9IDA7CiAgICBsZXQgcGF0aFRpcEhpZGVUaW1lciA9IDA7CiAgICBsZXQg
cGF0aFRpcFRva2VuID0gMDsKICAgIGxldCBwYXRoVGlwQW5jaG9yQnRuID0gbnVsbDsKCiAgICBm
dW5jdGlvbiBoaWRlUGF0aFRpcCgpIHsKICAgICAgICBjbGVhclRpbWVvdXQocGF0aFRpcFRpbWVy
KTsKICAgICAgICBjbGVhclRpbWVvdXQocGF0aFRpcEhpZGVUaW1lcik7CiAgICAgICAgcGF0aFRp
cFRva2VuKys7CiAgICAgICAgaWYgKHBhdGhUaXBBbmNob3JCdG4pIHsKICAgICAgICAgICAgcGF0
aFRpcEFuY2hvckJ0bi5jbGFzc0xpc3QucmVtb3ZlKCdvbicpOwogICAgICAgICAgICBwYXRoVGlw
QW5jaG9yQnRuID0gbnVsbDsKICAgICAgICB9CiAgICAgICAgaWYgKHBhdGhUaXBFbCkgewogICAg
ICAgICAgICBwYXRoVGlwRWwuY2xhc3NMaXN0LnJlbW92ZSgnb24nKTsKICAgICAgICAgICAgcGF0
aFRpcEVsLnNldEF0dHJpYnV0ZSgnYXJpYS1oaWRkZW4nLCAndHJ1ZScpOwogICAgICAgIH0KICAg
IH0KICAgIGZ1bmN0aW9uIHBsYWNlUGF0aFRpcChhbmNob3JFbCkgewogICAgICAgIGlmICghcGF0
aFRpcEVsIHx8ICFhbmNob3JFbCkgcmV0dXJuOwogICAgICAgIGNvbnN0IHRpcCA9IHBhdGhUaXBF
bDsKICAgICAgICBjb25zdCBhciA9IGFuY2hvckVsLmdldEJvdW5kaW5nQ2xpZW50UmVjdCgpOwog
ICAgICAgIGNvbnN0IHBhZCA9IDg7CiAgICAgICAgdGlwLnN0eWxlLmxlZnQgPSAnMHB4JzsKICAg
ICAgICB0aXAuc3R5bGUudG9wID0gJzBweCc7CiAgICAgICAgdGlwLmNsYXNzTGlzdC5hZGQoJ29u
Jyk7CiAgICAgICAgY29uc3QgdHcgPSB0aXAub2Zmc2V0V2lkdGg7CiAgICAgICAgY29uc3QgdGgg
PSB0aXAub2Zmc2V0SGVpZ2h0OwogICAgICAgIGxldCBsZWZ0ID0gYXIubGVmdDsKICAgICAgICBs
ZXQgdG9wID0gYXIuYm90dG9tICsgNjsKICAgICAgICBpZiAobGVmdCArIHR3ID4gd2luZG93Lmlu
bmVyV2lkdGggLSBwYWQpCiAgICAgICAgICAgIGxlZnQgPSBNYXRoLm1heChwYWQsIHdpbmRvdy5p
bm5lcldpZHRoIC0gdHcgLSBwYWQpOwogICAgICAgIGlmIChsZWZ0IDwgcGFkKSBsZWZ0ID0gcGFk
OwogICAgICAgIGlmICh0b3AgKyB0aCA+IHdpbmRvdy5pbm5lckhlaWdodCAtIHBhZCkKICAgICAg
ICAgICAgdG9wID0gTWF0aC5tYXgocGFkLCBhci50b3AgLSB0aCAtIDYpOwogICAgICAgIHRpcC5z
dHlsZS5sZWZ0ID0gbGVmdCArICdweCc7CiAgICAgICAgdGlwLnN0eWxlLnRvcCA9IHRvcCArICdw
eCc7CiAgICB9CiAgICAgICAgZnVuY3Rpb24gY2hlY2tGaWxlUGF0aHMocGF0aHMpIHsKICAgICAg
ICBjb25zdCBsaXN0ID0gKHBhdGhzIHx8IFtdKS5tYXAocCA9PiB7CiAgICAgICAgICAgIGxldCBw
YXRoID0gU3RyaW5nKHAgfHwgJycpLnRyaW0oKTsKICAgICAgICAgICAgaWYgKChwYXRoLnN0YXJ0
c1dpdGgoJyInKSAmJiBwYXRoLmVuZHNXaXRoKCciJykpIHx8IChwYXRoLnN0YXJ0c1dpdGgoIici
KSAmJiBwYXRoLmVuZHNXaXRoKCInIikpKQogICAgICAgICAgICAgICAgcGF0aCA9IHBhdGguc2xp
Y2UoMSwgLTEpLnRyaW0oKTsKICAgICAgICAgICAgcmV0dXJuIHBhdGg7CiAgICAgICAgfSk7CiAg
ICAgICAgLy8gT25lIGhvc3Qgcm91bmQtdHJpcCBmb3IgdGhlIHdob2xlIGxpc3Qg4oCUIE7DlyBw
YXRoRXhpc3RzIGZyZWV6ZXMgZmlsZSB0YWIKICAgICAgICB0cnkgewogICAgICAgICAgICBjb25z
dCByYXcgPSBhaGtSZXQoJ2NoZWNrUGF0aHMnLCBsaXN0LmpvaW4oJ1xuJykpOwogICAgICAgICAg
ICBpZiAocmF3KSB7CiAgICAgICAgICAgICAgICBjb25zdCBwYXJzZWQgPSB0eXBlb2YgcmF3ID09
PSAnc3RyaW5nJyA/IEpTT04ucGFyc2UocmF3KSA6IHJhdzsKICAgICAgICAgICAgICAgIGlmIChB
cnJheS5pc0FycmF5KHBhcnNlZCkgJiYgcGFyc2VkLmxlbmd0aCkgewogICAgICAgICAgICAgICAg
ICAgIHJldHVybiBsaXN0Lm1hcCgocGF0aCwgaSkgPT4gewogICAgICAgICAgICAgICAgICAgICAg
ICBjb25zdCByb3cgPSBwYXJzZWRbaV0gfHwge307CiAgICAgICAgICAgICAgICAgICAgICAgIHJl
dHVybiB7CiAgICAgICAgICAgICAgICAgICAgICAgICAgICBwYXRoOiBwYXRoIHx8IFN0cmluZyhy
b3cucGF0aCB8fCAnJyksCiAgICAgICAgICAgICAgICAgICAgICAgICAgICBleGlzdHM6IHJvdy5l
eGlzdHMgPT09IHRydWUgfHwgcm93LmV4aXN0cyA9PT0gMSB8fCByb3cuZXhpc3RzID09PSAnMScs
CiAgICAgICAgICAgICAgICAgICAgICAgICAgICBpc0RpcjogISEocm93LmlzRGlyID09PSB0cnVl
IHx8IHJvdy5pc0RpciA9PT0gMSB8fCByb3cuaXNEaXIgPT09ICcxJykKICAgICAgICAgICAgICAg
ICAgICAgICAgfTsKICAgICAgICAgICAgICAgICAgICB9KTsKICAgICAgICAgICAgICAgIH0KICAg
ICAgICAgICAgfQogICAgICAgIH0gY2F0Y2gge30KICAgICAgICByZXR1cm4gbGlzdC5tYXAocGF0
aCA9PiB7CiAgICAgICAgICAgIGlmICghcGF0aCkgcmV0dXJuIHsgcGF0aCwgZXhpc3RzOiBmYWxz
ZSwgaXNEaXI6IGZhbHNlIH07CiAgICAgICAgICAgIGxldCBleGlzdHMgPSBmYWxzZTsKICAgICAg
ICAgICAgdHJ5IHsKICAgICAgICAgICAgICAgIGNvbnN0IGZsYWcgPSBTdHJpbmcoYWhrUmV0KCdw
YXRoRXhpc3RzJywgcGF0aCkgPz8gJycpLnRyaW0oKS50b0xvd2VyQ2FzZSgpOwogICAgICAgICAg
ICAgICAgZXhpc3RzID0gKGZsYWcgPT09ICcxJyB8fCBmbGFnID09PSAndHJ1ZScpOwogICAgICAg
ICAgICB9IGNhdGNoIHt9CiAgICAgICAgICAgIHJldHVybiB7IHBhdGgsIGV4aXN0cywgaXNEaXI6
IGZhbHNlIH07CiAgICAgICAgfSk7CiAgICB9CiAgICBsZXQgZ29uZUNoZWNrVGltZXIgPSAwOwog
ICAgZnVuY3Rpb24gc2NoZWR1bGVGaWxlR29uZUNoZWNrKCkgewogICAgICAgIGlmIChnb25lQ2hl
Y2tUaW1lcikgcmV0dXJuOwogICAgICAgIGdvbmVDaGVja1RpbWVyID0gc2V0VGltZW91dCgoKSA9
PiB7CiAgICAgICAgICAgIGdvbmVDaGVja1RpbWVyID0gMDsKICAgICAgICAgICAgY29uc3Qgbm9k
ZXMgPSBbLi4ubGlzdEVsLnF1ZXJ5U2VsZWN0b3JBbGwoJy5pdG0nKV0uZmlsdGVyKG4gPT4gbi5f
ZmlsZVBhdGhzICYmIG4uX2ZpbGVQYXRocy5sZW5ndGgpOwogICAgICAgICAgICBpZiAoIW5vZGVz
Lmxlbmd0aCkgcmV0dXJuOwogICAgICAgICAgICBjb25zdCB1bmlxdWUgPSBbXTsKICAgICAgICAg
ICAgY29uc3Qgc2VlbiA9IG5ldyBTZXQoKTsKICAgICAgICAgICAgbm9kZXMuZm9yRWFjaChuID0+
IHsKICAgICAgICAgICAgICAgIG4uX2ZpbGVQYXRocy5mb3JFYWNoKHAgPT4gewogICAgICAgICAg
ICAgICAgICAgIGNvbnN0IHBhdGggPSBTdHJpbmcocCB8fCAnJyk7CiAgICAgICAgICAgICAgICAg
ICAgaWYgKCFwYXRoIHx8IHNlZW4uaGFzKHBhdGgpKSByZXR1cm47CiAgICAgICAgICAgICAgICAg
ICAgc2Vlbi5hZGQocGF0aCk7CiAgICAgICAgICAgICAgICAgICAgdW5pcXVlLnB1c2gocGF0aCk7
CiAgICAgICAgICAgICAgICB9KTsKICAgICAgICAgICAgfSk7CiAgICAgICAgICAgIGNvbnN0IHJv
d3MgPSBjaGVja0ZpbGVQYXRocyh1bmlxdWUpOwogICAgICAgICAgICBjb25zdCBieVBhdGggPSBu
ZXcgTWFwKCk7CiAgICAgICAgICAgIHJvd3MuZm9yRWFjaChyID0+IGJ5UGF0aC5zZXQoU3RyaW5n
KHIucGF0aCB8fCAnJyksIHIpKTsKICAgICAgICAgICAgbm9kZXMuZm9yRWFjaChuID0+IHsKICAg
ICAgICAgICAgICAgIGNvbnN0IHBhdGhSb3dzID0gbi5fZmlsZVBhdGhzLm1hcChwID0+IHsKICAg
ICAgICAgICAgICAgICAgICBjb25zdCBoaXQgPSBieVBhdGguZ2V0KFN0cmluZyhwIHx8ICcnKSk7
CiAgICAgICAgICAgICAgICAgICAgcmV0dXJuIGhpdCB8fCB7IHBhdGg6IHAsIGV4aXN0czogdHJ1
ZSwgaXNEaXI6IGZhbHNlIH07CiAgICAgICAgICAgICAgICB9KTsKICAgICAgICAgICAgICAgIG4u
X3BhdGhSb3dzID0gcGF0aFJvd3M7CiAgICAgICAgICAgICAgICBjb25zdCBhbGxHb25lID0gcGF0
aFJvd3MubGVuZ3RoID4gMCAmJiBwYXRoUm93cy5ldmVyeShyID0+IHIuZXhpc3RzID09PSBmYWxz
ZSk7CiAgICAgICAgICAgICAgICBuLmNsYXNzTGlzdC50b2dnbGUoJ2dvbmUnLCBhbGxHb25lKTsK
ICAgICAgICAgICAgfSk7CiAgICAgICAgfSwgNDAwKTsKICAgIH0KICAgIGZ1bmN0aW9uIGZpbGxG
aWxlRGV0YWlsUGFuZWwoY29udGFpbmVyLCByb3dzKSB7CiAgICAgICAgY29udGFpbmVyLmlubmVy
SFRNTCA9ICcnOwogICAgICAgIGlmICghcm93cy5sZW5ndGgpIHsKICAgICAgICAgICAgY29uc3Qg
ZW1wdHkgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsKICAgICAgICAgICAgZW1wdHku
Y2xhc3NOYW1lID0gJ2ZkLXBhdGgnOwogICAgICAgICAgICBlbXB0eS50ZXh0Q29udGVudCA9ICfm
l6Dot6/lvoQnOwogICAgICAgICAgICBjb250YWluZXIuYXBwZW5kQ2hpbGQoZW1wdHkpOwogICAg
ICAgICAgICByZXR1cm47CiAgICAgICAgfQogICAgICAgIHJvd3MuZm9yRWFjaChyID0+IHsKICAg
ICAgICAgICAgY29uc3QgcGF0aCA9IFN0cmluZyhyLnBhdGggfHwgJycpOwogICAgICAgICAgICBj
b25zdCBtaXNzaW5nID0gci5leGlzdHMgPT09IGZhbHNlOwogICAgICAgICAgICBjb25zdCBibG9j
ayA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOwogICAgICAgICAgICBibG9jay5jbGFz
c05hbWUgPSAnZmQtYmxvY2snOwoKICAgICAgICAgICAgY29uc3QgcGF0aEVsID0gZG9jdW1lbnQu
Y3JlYXRlRWxlbWVudCgnZGl2Jyk7CiAgICAgICAgICAgIHBhdGhFbC5jbGFzc05hbWUgPSAnZmQt
cGF0aCcgKyAobWlzc2luZyA/ICcgZGVhZCcgOiAnIGxpdmUnKTsKICAgICAgICAgICAgcGF0aEVs
LnRleHRDb250ZW50ID0gcGF0aCB8fCAnKOepuui3r+W+hCknOwogICAgICAgICAgICBpZiAoIW1p
c3NpbmcpIHsKICAgICAgICAgICAgICAgIHBhdGhFbC5vbmNsaWNrID0gZSA9PiB7CiAgICAgICAg
ICAgICAgICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOwogICAgICAgICAgICAgICAgICAgIGUuc3Rv
cFByb3BhZ2F0aW9uKCk7CiAgICAgICAgICAgICAgICAgICAgYWhrKCdvcGVuUGF0aCcsIHBhdGgp
OwogICAgICAgICAgICAgICAgfTsKICAgICAgICAgICAgfQogICAgICAgICAgICBibG9jay5hcHBl
bmRDaGlsZChwYXRoRWwpOwoKICAgICAgICAgICAgY29uc3QgYWN0aW9ucyA9IGRvY3VtZW50LmNy
ZWF0ZUVsZW1lbnQoJ2RpdicpOwogICAgICAgICAgICBhY3Rpb25zLmNsYXNzTmFtZSA9ICdmZC1h
Y3Rpb25zJzsKCiAgICAgICAgICAgIGNvbnN0IGNvcHlCdG4gPSBkb2N1bWVudC5jcmVhdGVFbGVt
ZW50KCdidXR0b24nKTsKICAgICAgICAgICAgY29weUJ0bi50eXBlID0gJ2J1dHRvbic7CiAgICAg
ICAgICAgIGNvcHlCdG4uY2xhc3NOYW1lID0gJ2ZkLWJ0bic7CiAgICAgICAgICAgIGNvcHlCdG4u
aW5uZXJIVE1MID0gJzxzcGFuIGNsYXNzPSJmZC1pY28iPvCflJc8L3NwYW4+PHNwYW4gY2xhc3M9
ImZkLXR4dCI+5aSN5Yi26Lev5b6EPC9zcGFuPic7CiAgICAgICAgICAgIGNvcHlCdG4ub25jbGlj
ayA9IGUgPT4gewogICAgICAgICAgICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOwogICAgICAgICAg
ICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICAgICAgICAgIGFoaygnY29weVBhdGgn
LCBwYXRoKTsKICAgICAgICAgICAgICAgIGNvcHlCdG4ucXVlcnlTZWxlY3RvcignLmZkLXR4dCcp
LnRleHRDb250ZW50ID0gJ+W3suWkjeWItic7CiAgICAgICAgICAgICAgICBjb3B5QnRuLmNsYXNz
TGlzdC5hZGQoJ29rJyk7CiAgICAgICAgICAgICAgICBzZXRUaW1lb3V0KCgpID0+IHsKICAgICAg
ICAgICAgICAgICAgICBjb3B5QnRuLnF1ZXJ5U2VsZWN0b3IoJy5mZC10eHQnKS50ZXh0Q29udGVu
dCA9ICflpI3liLbot6/lvoQnOwogICAgICAgICAgICAgICAgICAgIGNvcHlCdG4uY2xhc3NMaXN0
LnJlbW92ZSgnb2snKTsKICAgICAgICAgICAgICAgIH0sIDEyMDApOwogICAgICAgICAgICB9Owog
ICAgICAgICAgICBhY3Rpb25zLmFwcGVuZENoaWxkKGNvcHlCdG4pOwoKICAgICAgICAgICAgY29u
c3QgZm9sZGVyQnRuID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnYnV0dG9uJyk7CiAgICAgICAg
ICAgIGZvbGRlckJ0bi50eXBlID0gJ2J1dHRvbic7CiAgICAgICAgICAgIGZvbGRlckJ0bi5jbGFz
c05hbWUgPSAnZmQtYnRuJzsKICAgICAgICAgICAgZm9sZGVyQnRuLmlubmVySFRNTCA9ICc8c3Bh
biBjbGFzcz0iZmQtaWNvIj7wn5OCPC9zcGFuPjxzcGFuIGNsYXNzPSJmZC10eHQiPuaJk+W8gOaJ
gOWcqOaWh+S7tuWkuTwvc3Bhbj4nOwogICAgICAgICAgICBmb2xkZXJCdG4ub25jbGljayA9IGUg
PT4gewogICAgICAgICAgICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOwogICAgICAgICAgICAgICAg
ZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICAgICAgICAgIGFoaygnb3BlbkZvbGRlcicsIHBh
dGgpOwogICAgICAgICAgICB9OwogICAgICAgICAgICBhY3Rpb25zLmFwcGVuZENoaWxkKGZvbGRl
ckJ0bik7CgogICAgICAgICAgICBibG9jay5hcHBlbmRDaGlsZChhY3Rpb25zKTsKICAgICAgICAg
ICAgY29udGFpbmVyLmFwcGVuZENoaWxkKGJsb2NrKTsKICAgICAgICB9KTsKICAgIH0KCiAgICBj
b25zdCBjdHhFbCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjdHgnKTsKICAgIGZ1bmN0aW9u
IHNob3dDdHgoeCwgeSwgYykgewogICAgICAgIGN0eENsaXAgPSBjOwogICAgICAgIHNlbGVjdGVk
SWQgPSBjLmlkOwogICAgICAgIHJhbmdlQW5jaG9ySWQgPSBjLmlkOwogICAgICAgIHJhbmdlQW5j
aG9yQ2xpY2tlZCA9IHRydWU7CiAgICAgICAgY29uc3QgY2xlYXJCdG4gPSBkb2N1bWVudC5nZXRF
bGVtZW50QnlJZCgnYy1jbGVhci1wYXN0ZWQnKTsKICAgICAgICBpZiAoY2xlYXJCdG4pIGNsZWFy
QnRuLnN0eWxlLmRpc3BsYXkgPSBpc1Bhc3RlZChjKSA/ICcnIDogJ25vbmUnOwogICAgICAgIGNv
bnN0IHFGcm9tID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2MtcXVldWUtZnJvbScpOwogICAg
ICAgIGlmIChxRnJvbSkgcUZyb20uc3R5bGUuZGlzcGxheSA9IChOdW1iZXIoYy5xdWV1ZUdyb3Vw
KSA+IDApID8gJycgOiAnbm9uZSc7CgogICAgICAgIGNvbnN0IHBpbkJ0biA9IGRvY3VtZW50Lmdl
dEVsZW1lbnRCeUlkKCdjLXBpbicpOwogICAgICAgIGNvbnN0IGNvcHlCdG4gPSBkb2N1bWVudC5n
ZXRFbGVtZW50QnlJZCgnYy1jb3B5Jyk7CiAgICAgICAgY29uc3QgaXNSZWNlbnQgPSBub3JtVHlw
ZShjLnR5cGUpID09PSAncmVjZW50JyB8fCBjdXJUYWIgPT09ICdyZWNlbnQnOwogICAgICAgIGlm
IChjb3B5QnRuKSB7CiAgICAgICAgICAgIGNvcHlCdG4uaW5uZXJIVE1MID0gaXNSZWNlbnQKICAg
ICAgICAgICAgICAgID8gJzxzcGFuIGNsYXNzPSJjLWljbyI+8J+Ulzwvc3Bhbj7lpI3liLbot6/l
voQnCiAgICAgICAgICAgICAgICA6ICc8c3BhbiBjbGFzcz0iYy1pY28iPuKOmDwvc3Bhbj7lpI3l
iLYnOwogICAgICAgICAgICBjb3B5QnRuLnN0eWxlLmRpc3BsYXkgPSAnJzsKICAgICAgICB9CiAg
ICAgICAgaWYgKHBpbkJ0bikgewogICAgICAgICAgICBpZiAoaXNSZWNlbnQpIHsKICAgICAgICAg
ICAgICAgIC8vIFJlY2VudCBmb2xkZXJzOiBwaW4gPSBrZWVwIHBhdGggKG5vdCBjbGlwYm9hcmQg
5pS26JePKQogICAgICAgICAgICAgICAgcGluQnRuLnN0eWxlLmRpc3BsYXkgPSAnJzsKICAgICAg
ICAgICAgICAgIGNvbnN0IG9uID0gaXNQaW5uZWQoYyk7CiAgICAgICAgICAgICAgICBwaW5CdG4u
aW5uZXJIVE1MID0gb24KICAgICAgICAgICAgICAgICAgICA/ICc8c3BhbiBjbGFzcz0iYy1pY28i
PuKYhTwvc3Bhbj7lj5bmtojlm7rlrponCiAgICAgICAgICAgICAgICAgICAgOiAnPHNwYW4gY2xh
c3M9ImMtaWNvIj7imIU8L3NwYW4+5Zu65a6a6Lev5b6EJzsKICAgICAgICAgICAgfSBlbHNlIHsK
ICAgICAgICAgICAgICAgIHBpbkJ0bi5zdHlsZS5kaXNwbGF5ID0gJyc7CiAgICAgICAgICAgICAg
ICBjb25zdCBvbiA9IGlzUGlubmVkKGMpOwogICAgICAgICAgICAgICAgcGluQnRuLmlubmVySFRN
TCA9IG9uCiAgICAgICAgICAgICAgICAgICAgPyAnPHNwYW4gY2xhc3M9ImMtaWNvIj7imIU8L3Nw
YW4+5Y+W5raI5pS26JePJwogICAgICAgICAgICAgICAgICAgIDogJzxzcGFuIGNsYXNzPSJjLWlj
byI+4piFPC9zcGFuPuaUtuiXjyc7CiAgICAgICAgICAgIH0KICAgICAgICB9CiAgICAgICAgY29u
c3QgdGl0bGVCdG4gPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYy10aXRsZScpOwogICAgICAg
IGlmICh0aXRsZUJ0bikgewogICAgICAgICAgICAvLyBObyBmYXYtdGl0bGUgZm9yIHJlY2VudCBw
YXRocwogICAgICAgICAgICBjb25zdCBzaG93VGl0bGUgPSAhaXNSZWNlbnQgJiYgKGlzUGlubmVk
KGMpIHx8IGN1clRhYiA9PT0gJ3Bpbm5lZCcpOwogICAgICAgICAgICB0aXRsZUJ0bi5zdHlsZS5k
aXNwbGF5ID0gc2hvd1RpdGxlID8gJycgOiAnbm9uZSc7CiAgICAgICAgICAgIGlmIChzaG93VGl0
bGUpCiAgICAgICAgICAgICAgICB0aXRsZUJ0bi5pbm5lckhUTUwgPSAoU3RyaW5nKGMuZmF2VGl0
bGUgfHwgJycpLnRyaW0oKSA/ICc8c3BhbiBjbGFzcz0iYy1pY28iPuKcjjwvc3Bhbj7nvJbovpHm
oIfpopgnIDogJzxzcGFuIGNsYXNzPSJjLWljbyI+4pyOPC9zcGFuPuiuvue9ruagh+mimCcpOwog
ICAgICAgIH0KICAgICAgICBjb25zdCBtZXJnZUJ0biA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlk
KCdjLW1lcmdlJyk7CiAgICAgICAgY29uc3QgdW5tZXJnZUJ0biA9IGRvY3VtZW50LmdldEVsZW1l
bnRCeUlkKCdjLXVubWVyZ2UnKTsKICAgICAgICBjb25zdCBvblBpbm5lZCA9IGN1clRhYiA9PT0g
J3Bpbm5lZCc7CiAgICAgICAgaWYgKG1lcmdlQnRuKQogICAgICAgICAgICBtZXJnZUJ0bi5zdHls
ZS5kaXNwbGF5ID0gKCFpc1JlY2VudCAmJiBvblBpbm5lZCAmJiBtdWx0aUlkcy5sZW5ndGggPj0g
MikgPyAnJyA6ICdub25lJzsKICAgICAgICBpZiAodW5tZXJnZUJ0bikKICAgICAgICAgICAgdW5t
ZXJnZUJ0bi5zdHlsZS5kaXNwbGF5ID0gKCFpc1JlY2VudCAmJiBvblBpbm5lZCAmJiBmYXZHcm91
cE9mKGMpKSA/ICcnIDogJ25vbmUnOwogICAgICAgIGNvbnN0IHRvcEJ0biA9IGRvY3VtZW50Lmdl
dEVsZW1lbnRCeUlkKCdjLXRvcCcpOwogICAgICAgIGlmICh0b3BCdG4pCiAgICAgICAgICAgIHRv
cEJ0bi5zdHlsZS5kaXNwbGF5ID0gaXNSZWNlbnQgPyAnbm9uZScgOiAnJzsKICAgICAgICBjb25z
dCBjbGVhckJ0bjIgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYy1jbGVhci1wYXN0ZWQnKTsK
ICAgICAgICBpZiAoY2xlYXJCdG4yICYmIGlzUmVjZW50KQogICAgICAgICAgICBjbGVhckJ0bjIu
c3R5bGUuZGlzcGxheSA9ICdub25lJzsKICAgICAgICBjb25zdCBxRnJvbTIgPSBkb2N1bWVudC5n
ZXRFbGVtZW50QnlJZCgnYy1xdWV1ZS1mcm9tJyk7CiAgICAgICAgaWYgKHFGcm9tMiAmJiBpc1Jl
Y2VudCkKICAgICAgICAgICAgcUZyb20yLnN0eWxlLmRpc3BsYXkgPSAnbm9uZSc7CiAgICAgICAg
Y29uc3QgZGVsQnRuID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2MtZGVsJyk7CiAgICAgICAg
aWYgKGRlbEJ0bikgewogICAgICAgICAgICBjb25zdCBtdWx0aURlbCA9IG11bHRpSWRzLmxlbmd0
aCA+IDEgJiYgbXVsdGlJZHMuaW5jbHVkZXMoK2MuaWQpOwogICAgICAgICAgICBjb25zdCBuID0g
bXVsdGlEZWwgPyBtdWx0aUlkcy5sZW5ndGggOiAxOwogICAgICAgICAgICBkZWxCdG4uaW5uZXJI
VE1MID0gbiA+IDEKICAgICAgICAgICAgICAgID8gKCc8c3BhbiBjbGFzcz0iYy1pY28iPuKclTwv
c3Bhbj7liKDpmaQgKCcgKyBuICsgJyknKQogICAgICAgICAgICAgICAgOiAnPHNwYW4gY2xhc3M9
ImMtaWNvIj7inJU8L3NwYW4+5Yig6ZmkJzsKICAgICAgICB9CiAgICAgICAgY29uc3QgZGF0YVdy
YXAgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYy1kYXRhLXdyYXAnKTsKICAgICAgICBjb25z
dCBkYXRhU2VwID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2MtZGF0YS1zZXAnKTsKICAgICAg
ICBjb25zdCBzaG93RGF0YSA9ICFpc1JlY2VudCAmJiAobm9ybVR5cGUoYy50eXBlKSA9PT0gJ3Rl
eHQnIHx8IG5vcm1UeXBlKGMudHlwZSkgPT09ICdsaW5rJyk7CiAgICAgICAgaWYgKGRhdGFXcmFw
KSBkYXRhV3JhcC5zdHlsZS5kaXNwbGF5ID0gc2hvd0RhdGEgPyAnJyA6ICdub25lJzsKICAgICAg
ICBpZiAoZGF0YVNlcCkgZGF0YVNlcC5zdHlsZS5kaXNwbGF5ID0gc2hvd0RhdGEgPyAnJyA6ICdu
b25lJzsKICAgICAgICBpZiAoZGF0YVdyYXApIGRhdGFXcmFwLmNsYXNzTGlzdC5yZW1vdmUoJ29w
ZW4nKTsKICAgICAgICBjdHhFbC5jbGFzc0xpc3QuYWRkKCdvbicpOwogICAgICAgIGN0eEVsLnN0
eWxlLmxlZnQgPSB4ICsgJ3B4JzsKICAgICAgICBjdHhFbC5zdHlsZS50b3AgID0geSArICdweCc7
CiAgICAgICAgcmVxdWVzdEFuaW1hdGlvbkZyYW1lKCgpID0+IHsKICAgICAgICAgICAgY29uc3Qg
ciA9IGN0eEVsLmdldEJvdW5kaW5nQ2xpZW50UmVjdCgpOwogICAgICAgICAgICBpZiAoci5yaWdo
dCAgPiBpbm5lcldpZHRoKSAgY3R4RWwuc3R5bGUubGVmdCA9ICh4IC0gci53aWR0aCkgICsgJ3B4
JzsKICAgICAgICAgICAgaWYgKHIuYm90dG9tID4gaW5uZXJIZWlnaHQpIGN0eEVsLnN0eWxlLnRv
cCAgPSAoeSAtIHIuaGVpZ2h0KSArICdweCc7CiAgICAgICAgICAgIHBsYWNlRGF0YVN1Ym1lbnUo
KTsKICAgICAgICB9KTsKICAgIH0KICAgIGZ1bmN0aW9uIHBsYWNlRGF0YVN1Ym1lbnUoKSB7CiAg
ICAgICAgY29uc3Qgd3JhcCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjLWRhdGEtd3JhcCcp
OwogICAgICAgIGNvbnN0IHN1YiA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjLWRhdGEtc3Vi
Jyk7CiAgICAgICAgaWYgKCF3cmFwIHx8ICFzdWIgfHwgd3JhcC5zdHlsZS5kaXNwbGF5ID09PSAn
bm9uZScpIHJldHVybjsKICAgICAgICBjb25zdCBwYWQgPSA0OwogICAgICAgIC8vIE1lYXN1cmUg
d2hpbGUgdGVtcG9yYXJpbHkgdmlzaWJsZSAoc3VibWVudSBtYXkgc3RpbGwgYmUgZGlzcGxheTpu
b25lKQogICAgICAgIGNvbnN0IHByZXZEaXNwbGF5ID0gc3ViLnN0eWxlLmRpc3BsYXk7CiAgICAg
ICAgY29uc3QgcHJldlZpc2liaWxpdHkgPSBzdWIuc3R5bGUudmlzaWJpbGl0eTsKICAgICAgICBj
b25zdCBwcmV2TGVmdCA9IHN1Yi5zdHlsZS5sZWZ0OwogICAgICAgIGNvbnN0IHByZXZSaWdodCA9
IHN1Yi5zdHlsZS5yaWdodDsKICAgICAgICBzdWIuY2xhc3NMaXN0LnJlbW92ZSgnbGVmdCcpOwog
ICAgICAgIHN1Yi5zdHlsZS5sZWZ0ID0gJ2NhbGMoMTAwJSAtIDJweCknOwogICAgICAgIHN1Yi5z
dHlsZS5yaWdodCA9ICdhdXRvJzsKICAgICAgICBzdWIuc3R5bGUudmlzaWJpbGl0eSA9ICdoaWRk
ZW4nOwogICAgICAgIHN1Yi5zdHlsZS5kaXNwbGF5ID0gJ2Jsb2NrJzsKICAgICAgICBjb25zdCBz
dWJXID0gTWF0aC5jZWlsKHN1Yi5nZXRCb3VuZGluZ0NsaWVudFJlY3QoKS53aWR0aCB8fCBzdWIu
b2Zmc2V0V2lkdGggfHwgMCk7CiAgICAgICAgY29uc3Qgd3JhcFJlY3QgPSB3cmFwLmdldEJvdW5k
aW5nQ2xpZW50UmVjdCgpOwogICAgICAgIHN1Yi5zdHlsZS5kaXNwbGF5ID0gcHJldkRpc3BsYXk7
CiAgICAgICAgc3ViLnN0eWxlLnZpc2liaWxpdHkgPSBwcmV2VmlzaWJpbGl0eTsKICAgICAgICBz
dWIuc3R5bGUubGVmdCA9IHByZXZMZWZ0OwogICAgICAgIHN1Yi5zdHlsZS5yaWdodCA9IHByZXZS
aWdodDsKCiAgICAgICAgaWYgKHN1YlcgPD0gMCkgcmV0dXJuOwogICAgICAgIGNvbnN0IHNwYWNl
UmlnaHQgPSB3aW5kb3cuaW5uZXJXaWR0aCAtIHdyYXBSZWN0LnJpZ2h0IC0gcGFkOwogICAgICAg
IGNvbnN0IHNwYWNlTGVmdCA9IHdyYXBSZWN0LmxlZnQgLSBwYWQ7CiAgICAgICAgY29uc3QgZml0
c1JpZ2h0ID0gc3BhY2VSaWdodCA+PSBzdWJXOwogICAgICAgIGNvbnN0IGZpdHNMZWZ0ID0gc3Bh
Y2VMZWZ0ID49IHN1Ylc7CiAgICAgICAgbGV0IG9wZW5MZWZ0ID0gZmFsc2U7CiAgICAgICAgaWYg
KGZpdHNSaWdodCkgb3BlbkxlZnQgPSBmYWxzZTsKICAgICAgICBlbHNlIGlmIChmaXRzTGVmdCkg
b3BlbkxlZnQgPSB0cnVlOwogICAgICAgIGVsc2Ugb3BlbkxlZnQgPSBzcGFjZUxlZnQgPiBzcGFj
ZVJpZ2h0OyAvLyBuZWl0aGVyIGZpdHMg4oCUIHBpY2sgdGhlIGxhcmdlciBnYXAKCiAgICAgICAg
aWYgKG9wZW5MZWZ0KSB7CiAgICAgICAgICAgIHN1Yi5jbGFzc0xpc3QuYWRkKCdsZWZ0Jyk7CiAg
ICAgICAgICAgIHN1Yi5zdHlsZS5sZWZ0ID0gJ2F1dG8nOwogICAgICAgICAgICBzdWIuc3R5bGUu
cmlnaHQgPSAnY2FsYygxMDAlIC0gMnB4KSc7CiAgICAgICAgfSBlbHNlIHsKICAgICAgICAgICAg
c3ViLmNsYXNzTGlzdC5yZW1vdmUoJ2xlZnQnKTsKICAgICAgICAgICAgc3ViLnN0eWxlLmxlZnQg
PSAnY2FsYygxMDAlIC0gMnB4KSc7CiAgICAgICAgICAgIHN1Yi5zdHlsZS5yaWdodCA9ICdhdXRv
JzsKICAgICAgICB9CiAgICB9CiAgICBmdW5jdGlvbiBoaWRlQ3R4KCkgewogICAgICAgIGN0eEVs
LmNsYXNzTGlzdC5yZW1vdmUoJ29uJyk7CiAgICAgICAgY3R4Q2xpcCA9IG51bGw7CiAgICAgICAg
dHJ5IHsKICAgICAgICAgICAgY29uc3Qgd3JhcCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdj
LWRhdGEtd3JhcCcpOwogICAgICAgICAgICBpZiAod3JhcCkgd3JhcC5jbGFzc0xpc3QucmVtb3Zl
KCdvcGVuJyk7CiAgICAgICAgICAgIGNsZWFyRGF0YVN1Ym1lbnVQaWNrKCk7CiAgICAgICAgICAg
IHByZXZpZXdEYXRhVHJhbnNmb3JtU2VxKys7CiAgICAgICAgfSBjYXRjaCB7fQogICAgfQogICAg
d2luZG93Ll9faGlkZUN0eCA9IGhpZGVDdHg7CgogICAgZnVuY3Rpb24gZGlzbWlzc0N0eFVubGVz
c0luc2lkZShlKSB7CiAgICAgICAgaWYgKCFjdHhFbC5jbGFzc0xpc3QuY29udGFpbnMoJ29uJykp
IHJldHVybjsKICAgICAgICBpZiAoZS50YXJnZXQuY2xvc2VzdCgnI2N0eCcpKSByZXR1cm47CiAg
ICAgICAgaGlkZUN0eCgpOwogICAgfQogICAgZG9jdW1lbnQuYWRkRXZlbnRMaXN0ZW5lcignbW91
c2Vkb3duJywgZGlzbWlzc0N0eFVubGVzc0luc2lkZSwgdHJ1ZSk7CiAgICBkb2N1bWVudC5hZGRF
dmVudExpc3RlbmVyKCdjbGljaycsIGRpc21pc3NDdHhVbmxlc3NJbnNpZGUsIHRydWUpOwogICAg
bGlzdEVsLmFkZEV2ZW50TGlzdGVuZXIoJ3Njcm9sbCcsIGhpZGVDdHgsIHsgcGFzc2l2ZTogdHJ1
ZSB9KTsKICAgIGRvY3VtZW50LmFkZEV2ZW50TGlzdGVuZXIoJ2tleWRvd24nLCBlID0+IHsKICAg
ICAgICAvLyBFc2M6IGFsd2F5cyBjbG9zZSBwYW5lbCAoc2VhcmNoIG9yIG5vdCk7IHBpbiBrZWVw
cyBwYW5lbAogICAgICAgIGlmIChlLmtleSA9PT0gJ0VzY2FwZScpIHsKICAgICAgICAgICAgZS5w
cmV2ZW50RGVmYXVsdCgpOwogICAgICAgICAgICBoaWRlQ3R4KCk7CiAgICAgICAgICAgIGNvbnN0
IHRkID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3RpdGxlLWRsZycpOwogICAgICAgICAgICBp
ZiAodGQgJiYgdGQuY2xhc3NMaXN0LmNvbnRhaW5zKCdvbicpKSB7CiAgICAgICAgICAgICAgICB0
cnkgeyBjbG9zZVRpdGxlRGxnKCk7IH0gY2F0Y2ggeyB0ZC5jbGFzc0xpc3QucmVtb3ZlKCdvbicp
OyB9CiAgICAgICAgICAgICAgICB0cnkgeyBhaGsoJ2JsdXJQYW5lbCcpOyB9IGNhdGNoIHt9CiAg
ICAgICAgICAgICAgICByZXR1cm47CiAgICAgICAgICAgIH0KICAgICAgICAgICAgaWYgKGNsckRs
Zy5jbGFzc0xpc3QuY29udGFpbnMoJ29uJykpIHsKICAgICAgICAgICAgICAgIGNsb3NlQ2xlYXJE
bGcoKTsKICAgICAgICAgICAgICAgIHJldHVybjsKICAgICAgICAgICAgfQogICAgICAgICAgICBp
ZiAoIXBpbm5lZFVJKSBhaGsoJ2hpZGUnKTsKICAgICAgICAgICAgcmV0dXJuOwogICAgICAgIH0K
ICAgICAgICAvLyBXaGlsZSB0eXBpbmcgaW4gc2VhcmNoOiBDdHJsK0kvSyBhbmQgYXJyb3dzIG1v
dmUgbGlzdCwgZG9uJ3QgbGVhdmUgdGhlIGJveAogICAgICAgIGlmIChkb2N1bWVudC5hY3RpdmVF
bGVtZW50Py5pZCA9PT0gJ3NlYXJjaCcpIHsKICAgICAgICAgICAgaWYgKChlLmN0cmxLZXkgfHwg
ZS5tZXRhS2V5KSAmJiAoZS5rZXkgPT09ICdpJyB8fCBlLmtleSA9PT0gJ0knKSkgewogICAgICAg
ICAgICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOyBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgICAg
ICAgICAgICAgd2luZG93Ll9fbmF2ICYmIHdpbmRvdy5fX25hdigndXAnKTsKICAgICAgICAgICAg
ICAgIHJldHVybjsKICAgICAgICAgICAgfQogICAgICAgICAgICBpZiAoKGUuY3RybEtleSB8fCBl
Lm1ldGFLZXkpICYmIChlLmtleSA9PT0gJ2snIHx8IGUua2V5ID09PSAnSycpKSB7CiAgICAgICAg
ICAgICAgICBlLnByZXZlbnREZWZhdWx0KCk7IGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAgICAg
ICAgICAgICB3aW5kb3cuX19uYXYgJiYgd2luZG93Ll9fbmF2KCdkb3duJyk7CiAgICAgICAgICAg
ICAgICByZXR1cm47CiAgICAgICAgICAgIH0KICAgICAgICAgICAgaWYgKGUua2V5ID09PSAnQXJy
b3dEb3duJykgewogICAgICAgICAgICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOyBlLnN0b3BQcm9w
YWdhdGlvbigpOwogICAgICAgICAgICAgICAgd2luZG93Ll9fbmF2ICYmIHdpbmRvdy5fX25hdign
ZG93bicpOwogICAgICAgICAgICAgICAgcmV0dXJuOwogICAgICAgICAgICB9CiAgICAgICAgICAg
IGlmIChlLmtleSA9PT0gJ0Fycm93VXAnKSB7CiAgICAgICAgICAgICAgICBlLnByZXZlbnREZWZh
dWx0KCk7IGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAgICAgICAgICAgICB3aW5kb3cuX19uYXYg
JiYgd2luZG93Ll9fbmF2KCd1cCcpOwogICAgICAgICAgICAgICAgcmV0dXJuOwogICAgICAgICAg
ICB9CiAgICAgICAgICAgIHJldHVybjsKICAgICAgICB9CiAgICAgICAgY29uc3QgdmlzID0gKHR5
cGVvZiBuYXZMaXN0ID09PSAnZnVuY3Rpb24nID8gbmF2TGlzdCgpIDogdmlzaWJsZUxpc3QoKSk7
CiAgICAgICAgaWYgKCF2aXMubGVuZ3RoKSByZXR1cm47CiAgICAgICAgbGV0IGlkeCA9IHNlbGVj
dGVkSW5kZXgoKTsKICAgICAgICBpZiAoaWR4IDwgMCkgaWR4ID0gMDsKICAgICAgICBpZiAgICAg
IChlLmtleSA9PT0gJ0Fycm93RG93bicpIHsgZS5wcmV2ZW50RGVmYXVsdCgpOyBlLnN0b3BQcm9w
YWdhdGlvbigpOyBzZWxlY3RCeUluZGV4KGlkeCArIDEpOyB9CiAgICAgICAgZWxzZSBpZiAoZS5r
ZXkgPT09ICdBcnJvd1VwJykgICB7IGUucHJldmVudERlZmF1bHQoKTsgZS5zdG9wUHJvcGFnYXRp
b24oKTsgc2VsZWN0QnlJbmRleChpZHggLSAxKTsgfQogICAgICAgIGVsc2UgaWYgKGUua2V5ID09
PSAnRW50ZXInKSB7CiAgICAgICAgICAgIGUucHJldmVudERlZmF1bHQoKTsKICAgICAgICAgICAg
Ly8g5Zu65a6a5pe25Zue6L2m5LiN57KY6LS077yM5Y+q54K55p2h55uu57KY6LS0CiAgICAgICAg
ICAgIGlmIChwaW5uZWRVSSkgcmV0dXJuOwogICAgICAgICAgICBpZiAobXVsdGlJZHMubGVuZ3Ro
ID49IDEpIHsKICAgICAgICAgICAgICAgIGNvbnN0IGlkcyA9IG11bHRpSWRzLnNsaWNlKCk7CiAg
ICAgICAgICAgICAgICBjbGVhck11bHRpKCk7CiAgICAgICAgICAgICAgICBtYXJrUGFzdGVkTG9j
YWwoaWRzKTsKICAgICAgICAgICAgICAgIHBhc3RlTWFueVdpdGhTZXAoaWRzKTsKICAgICAgICAg
ICAgICAgIHJldHVybjsKICAgICAgICAgICAgfQogICAgICAgICAgICBjb25zdCBjID0gdmlzW3Nl
bGVjdGVkSW5kZXgoKV07CiAgICAgICAgICAgIGlmIChjKSB7CiAgICAgICAgICAgICAgICBtYXJr
UGFzdGVkTG9jYWwoYy5pZCk7CiAgICAgICAgICAgICAgICBhaGsoJ3Bhc3RlJywgU3RyaW5nKGMu
aWQpKTsKICAgICAgICAgICAgfQogICAgICAgIH0gZWxzZSBpZiAoL15bMS05XSQvLnRlc3QoZS5r
ZXkpKSB7CiAgICAgICAgICAgIGNvbnN0IGMgPSB2aXNbK2Uua2V5IC0gMV07CiAgICAgICAgICAg
IGlmIChjKSB7CiAgICAgICAgICAgICAgICBtYXJrUGFzdGVkTG9jYWwoYy5pZCk7CiAgICAgICAg
ICAgICAgICBhaGsoJ3Bhc3RlJywgU3RyaW5nKGMuaWQpKTsKICAgICAgICAgICAgfQogICAgICAg
IH0KICAgIH0pOwoKICAgIHdpbmRvdy5fX25hdiA9IGRpciA9PiB7CiAgICAgICAgY29uc3QgdGQg
PSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgndGl0bGUtZGxnJyk7CiAgICAgICAgaWYgKHRkICYm
IHRkLmNsYXNzTGlzdC5jb250YWlucygnb24nKSkgcmV0dXJuOwogICAgICAgIGNvbnN0IHZpcyA9
ICh0eXBlb2YgbmF2TGlzdCA9PT0gJ2Z1bmN0aW9uJyA/IG5hdkxpc3QoKSA6IHZpc2libGVMaXN0
KCkpOwogICAgICAgIGlmICghdmlzLmxlbmd0aCAmJiBkaXIgIT09ICd0YWInICYmIGRpciAhPT0g
J3RhYlByZXYnKSByZXR1cm47CiAgICAgICAgbGV0IGlkeCA9IHNlbGVjdGVkSW5kZXgoKTsKICAg
ICAgICBpZiAoaWR4IDwgMCkgaWR4ID0gMDsKICAgICAgICBpZiAoZGlyID09PSAndXAnKSBzZWxl
Y3RCeUluZGV4KGlkeCAtIDEpOwogICAgICAgIGVsc2UgaWYgKGRpciA9PT0gJ2Rvd24nKSBzZWxl
Y3RCeUluZGV4KGlkeCArIDEpOwogICAgICAgIGVsc2UgaWYgKGRpciA9PT0gJ2VudGVyJykgewog
ICAgICAgICAgICBpZiAocGlubmVkVUkpIHJldHVybjsKICAgICAgICAgICAgX19wcmVwUGFzdGUo
KTsKICAgICAgICAgICAgaWYgKG11bHRpSWRzLmxlbmd0aCA+PSAxKSB7CiAgICAgICAgICAgICAg
ICBjb25zdCBpZHMgPSBtdWx0aUlkcy5zbGljZSgpOwogICAgICAgICAgICAgICAgY2xlYXJNdWx0
aSgpOwogICAgICAgICAgICAgICAgbWFya1Bhc3RlZExvY2FsKGlkcyk7CiAgICAgICAgICAgICAg
ICBwYXN0ZU1hbnlXaXRoU2VwKGlkcyk7CiAgICAgICAgICAgICAgICByZXR1cm47CiAgICAgICAg
ICAgIH0KICAgICAgICAgICAgY29uc3QgYyA9IHZpc1tzZWxlY3RlZEluZGV4KCldOwogICAgICAg
ICAgICBpZiAoYykgewogICAgICAgICAgICAgICAgbWFya1Bhc3RlZExvY2FsKGMuaWQpOwogICAg
ICAgICAgICAgICAgYWhrKCdwYXN0ZScsIFN0cmluZyhjLmlkKSk7CiAgICAgICAgICAgIH0KICAg
ICAgICB9CiAgICB9OwoKICAgIC8vIEFISyBFbnRlciBob3RrZXkgbGFuZHMgaGVyZSAoV2ViVmll
dyBtYXkgbm90IHJlY2VpdmUgdGhlIGtleSB3aGlsZSB1bnBpbm5lZCkKICAgIHdpbmRvdy5fX2Vk
aXRUaXRsZSA9ICgpID0+IHsKICAgICAgICBsZXQgYyA9IG51bGw7CiAgICAgICAgaWYgKHNlbGVj
dGVkSWQpCiAgICAgICAgICAgIGMgPSBhbGxDbGlwcy5maW5kKHggPT4gK3guaWQgPT09ICtzZWxl
Y3RlZElkKSB8fCBudWxsOwogICAgICAgIGlmICghYyAmJiBjdHhDbGlwKQogICAgICAgICAgICBj
ID0gY3R4Q2xpcDsKICAgICAgICBpZiAoIWMpIHsKICAgICAgICAgICAgY29uc3QgdmlzID0gdmlz
aWJsZUxpc3QoKTsKICAgICAgICAgICAgaWYgKHZpcy5sZW5ndGgpIGMgPSB2aXNbMF07CiAgICAg
ICAgfQogICAgICAgIGlmICghYykgcmV0dXJuOwogICAgICAgIG9wZW5UaXRsZURsZyhjKTsKICAg
IH07CgogICAgd2luZG93Ll9fb25FbnRlciA9ICgpID0+IHsKICAgICAgICBjb25zdCB0ZCA9IGRv
Y3VtZW50LmdldEVsZW1lbnRCeUlkKCd0aXRsZS1kbGcnKTsKICAgICAgICBpZiAodGQgJiYgdGQu
Y2xhc3NMaXN0LmNvbnRhaW5zKCdvbicpKSB7CiAgICAgICAgICAgIGRvY3VtZW50LmdldEVsZW1l
bnRCeUlkKCd0aXRsZS1vaycpPy5jbGljaygpOwogICAgICAgICAgICByZXR1cm47CiAgICAgICAg
fQogICAgICAgIGlmIChkb2N1bWVudC5hY3RpdmVFbGVtZW50Py5pZCA9PT0gJ3RpdGxlLWlucHV0
JykgewogICAgICAgICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgndGl0bGUtb2snKT8uY2xp
Y2soKTsKICAgICAgICAgICAgcmV0dXJuOwogICAgICAgIH0KICAgICAgICAvLyDoh6rlrprkuYnl
iIbpmpTnrKbvvJrmnKrlm7rlrprml7YgQUhLIOS8muaKoiBFbnRlcgogICAgICAgIGNvbnN0IHNl
cE1lbnUgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgncGFzdGUtc2VwLW1lbnUnKTsKICAgICAg
ICBjb25zdCBzZXBJbnAgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgncGFzdGUtc2VwLWN1c3Rv
bScpOwogICAgICAgIGlmIChzZXBNZW51ICYmIHNlcE1lbnUuY2xhc3NMaXN0LmNvbnRhaW5zKCdv
bicpICYmIHNlcElucCkgewogICAgICAgICAgICBpZiAoU3RyaW5nKHNlcElucC52YWx1ZSB8fCAn
JykgIT09ICcnKSBhcHBseVNlcGFyYXRvcihzZXBJbnAudmFsdWUpOwogICAgICAgICAgICBlbHNl
IGNsb3NlU2VwTWVudSgpOwogICAgICAgICAgICByZXR1cm47CiAgICAgICAgfQogICAgICAgIC8v
IOWbuuWumuaXtuWbnui9puS4jeeymOi0tAogICAgICAgIGlmIChwaW5uZWRVSSkgcmV0dXJuOwog
ICAgICAgIC8vIFR5cGluZyBpbiBzZWFyY2g6IEVudGVyIHNob3VsZCBwYXN0ZSBzZWxlY3RlZCBp
dGVtCiAgICAgICAgaWYgKGRvY3VtZW50LmFjdGl2ZUVsZW1lbnQ/LmlkID09PSAnc2VhcmNoJykg
ewogICAgICAgICAgICB3aW5kb3cuX19uYXYgJiYgd2luZG93Ll9fbmF2KCdlbnRlcicpOwogICAg
ICAgICAgICByZXR1cm47CiAgICAgICAgfQogICAgICAgIHdpbmRvdy5fX25hdiAmJiB3aW5kb3cu
X19uYXYoJ2VudGVyJyk7CiAgICB9OwoKICAgIHdpbmRvdy5fX2N5Y2xlVGFiID0gZGlyID0+IHsK
ICAgICAgICBjb25zdCBpID0gTWF0aC5tYXgoMCwgVEFCX09SREVSLmluZGV4T2YoY3VyVGFiKSk7
CiAgICAgICAgY29uc3QgbmV4dCA9IFRBQl9PUkRFUlsoaSArIChkaXIgfCAwKSArIFRBQl9PUkRF
Ui5sZW5ndGggKiAxMCkgJSBUQUJfT1JERVIubGVuZ3RoXTsKICAgICAgICBzZXRUYWIobmV4dCk7
CiAgICB9OwogICAgd2luZG93Ll9fb25QYW5lbFNob3cgPSAoa2VlcFNlYXJjaCkgPT4gewogICAg
ICAgIHdpbmRvdy5fX3BlcmZNYXJrICYmIHdpbmRvdy5fX3BlcmZNYXJrKCdqc19vblBhbmVsU2hv
dyBrZWVwU2VhcmNoPScgKyAoISFrZWVwU2VhcmNoKSk7CiAgICAgICAgdHJ5IHsgcmVzZXRQYXN0
ZVNlcERlZmF1bHQoKTsgfSBjYXRjaCB7fQogICAgICAgIC8vIERvIE5PVCBmb2N1cyBXZWJWaWV3
IOKAlCBrZWVwIGVkaXRvciBjYXJldC9mb2N1cyAoQUhLIGhhbmRsZXMga2V5cyB2aWEgI0hvdElm
KQogICAgICAgIC8vIFdpbitWOiBjb2xsYXBzZSBzZWFyY2guID8/IHNlYXJjaDoga2VlcC9vcGVu
IHNlYXJjaCBib3guCiAgICAgICAga2VlcFNlYXJjaCA9ICEha2VlcFNlYXJjaDsKICAgICAgICB0
cnkgeyBoaWRlQ3R4KCk7IH0gY2F0Y2gge30KICAgICAgICB0cnkgeyBjbG9zZVRpdGxlRGxnKCk7
IH0gY2F0Y2gge30KICAgICAgICB0cnkgewogICAgICAgICAgICBjb25zdCB3cmFwID0gZG9jdW1l
bnQuZ2V0RWxlbWVudEJ5SWQoJ3NlYXJjaC13cmFwJyk7CiAgICAgICAgICAgIGNvbnN0IHNyY2gg
PSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc2VhcmNoJyk7CiAgICAgICAgICAgIGNvbnN0IHNj
bHIgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc2VhcmNoLWNscicpOwogICAgICAgICAgICBp
ZiAoIWtlZXBTZWFyY2gpIHsKICAgICAgICAgICAgICAgIGlmICh3cmFwKSB3cmFwLmNsYXNzTGlz
dC5yZW1vdmUoJ29wZW4nKTsKICAgICAgICAgICAgICAgIGlmIChzcmNoKSB7CiAgICAgICAgICAg
ICAgICAgICAgc3JjaC52YWx1ZSA9ICcnOwogICAgICAgICAgICAgICAgICAgIHNyY2guY2xhc3NM
aXN0LnJlbW92ZSgnaGFzLXZhbCcpOwogICAgICAgICAgICAgICAgICAgIHRyeSB7IHNyY2guYmx1
cigpOyB9IGNhdGNoIHt9CiAgICAgICAgICAgICAgICB9CiAgICAgICAgICAgICAgICBpZiAoc2Ns
cikgc2Nsci5zdHlsZS5kaXNwbGF5ID0gJ25vbmUnOwogICAgICAgICAgICAgICAgcXVlcnkgPSAn
JzsKICAgICAgICAgICAgICAgIHdpbmRvdy5fX2hvc3RGaWx0ZXJlZCA9IGZhbHNlOwogICAgICAg
ICAgICAgICAgd2luZG93Ll9faG9zdEZpbHRlclEgPSAnJzsKICAgICAgICAgICAgICAgIC8vIFdp
bitW77ya56uL5Yi755So5pyq6L+H5ruk57yT5a2Y6ZO65YiX6KGo77yM6YG/5YWN5YWI6Zeq6L+H
5ruk57uT5p6cL+epuuWjs+WGjeetiSBTZXRWaWV3CiAgICAgICAgICAgICAgICB0cnkgewogICAg
ICAgICAgICAgICAgICAgIGNvbnN0IGhpdCA9IHZpZXdNZW0uZ2V0KHZpZXdNZW1LZXkoJ2FsbCcs
ICcnLCBmYWxzZSkpOwogICAgICAgICAgICAgICAgICAgIGlmIChoaXQgJiYgQXJyYXkuaXNBcnJh
eShoaXQuaXRlbXMpICYmIGhpdC5pdGVtcy5sZW5ndGgpIHsKICAgICAgICAgICAgICAgICAgICAg
ICAgYWxsQ2xpcHMgPSBoaXQuaXRlbXMuc2xpY2UoKTsKICAgICAgICAgICAgICAgICAgICAgICAg
ZGlza1RvdGFsID0gTnVtYmVyKGhpdC50b3RhbCkgfHwgaGl0Lml0ZW1zLmxlbmd0aDsKICAgICAg
ICAgICAgICAgICAgICAgICAgd2luZG93Ll9fZGF0YVJlYWR5ID0gdHJ1ZTsKICAgICAgICAgICAg
ICAgICAgICAgICAgaG9zdFB1c2hlZE9uY2UgPSB0cnVlOwogICAgICAgICAgICAgICAgICAgICAg
ICBzYXdOb25FbXB0eSA9IHRydWU7CiAgICAgICAgICAgICAgICAgICAgICAgIGNsZWFyV2FpdGlu
Z0RhdGEoKTsKICAgICAgICAgICAgICAgICAgICB9IGVsc2UgewogICAgICAgICAgICAgICAgICAg
ICAgICBzY2hlZHVsZURlbGF5ZWRTa2VsKCk7CiAgICAgICAgICAgICAgICAgICAgfQogICAgICAg
ICAgICAgICAgfSBjYXRjaCB7CiAgICAgICAgICAgICAgICAgICAgc2NoZWR1bGVEZWxheWVkU2tl
bCgpOwogICAgICAgICAgICAgICAgfQogICAgICAgICAgICB9IGVsc2UgaWYgKHdyYXApIHsKICAg
ICAgICAgICAgICAgIHdyYXAuY2xhc3NMaXN0LmFkZCgnb3BlbicpOwogICAgICAgICAgICAgICAg
aWYgKHNyY2ggJiYgc3JjaC52YWx1ZSkKICAgICAgICAgICAgICAgICAgICBxdWVyeSA9IHNyY2gu
dmFsdWU7CiAgICAgICAgICAgICAgICAvLyA/PyDmkJzntKLvvJrlnKjkuLvmnLrov4fmu6Tnu5Pm
npzliLDovr7liY3vvIzlhYjmjInlhbPplK7lrZfmnKzlnLDmu6TvvIznpoHmraLpl6rlh7rjgIzl
hajpg6jjgI0KICAgICAgICAgICAgICAgIGlmIChTdHJpbmcocXVlcnkgfHwgJycpLnRyaW0oKSkg
ewogICAgICAgICAgICAgICAgICAgIHdpbmRvdy5fX2hvc3RGaWx0ZXJlZCA9IGZhbHNlOwogICAg
ICAgICAgICAgICAgICAgIHdpbmRvdy5fX2hvc3RGaWx0ZXJRID0gJyc7CiAgICAgICAgICAgICAg
ICB9CiAgICAgICAgICAgIH0KICAgICAgICAgICAgdG9kYXlPbmx5ID0gZmFsc2U7CiAgICAgICAg
ICAgIHRyeSB7CiAgICAgICAgICAgICAgICBjb25zdCBidG5Ub2RheSA9IGRvY3VtZW50LmdldEVs
ZW1lbnRCeUlkKCdidG4tdG9kYXknKTsKICAgICAgICAgICAgICAgIGlmIChidG5Ub2RheSkgYnRu
VG9kYXkuY2xhc3NMaXN0LnJlbW92ZSgnb24nKTsKICAgICAgICAgICAgfSBjYXRjaCB7fQogICAg
ICAgICAgICBjdXJUYWIgPSAnYWxsJzsKICAgICAgICAgICAgbG9hZGluZ01vcmUgPSBmYWxzZTsK
ICAgICAgICAgICAgbWFya1RhYignYWxsJyk7CiAgICAgICAgICAgIC8vIOS4jeimgSBhaGsoJ2Js
dXJQYW5lbCcp77ya5Lya6LefIFNob3dQYW5lbCDmiqLnhKbngrnvvIxXaW4rVi8/PyDpg73lrrnm
mJPpl6rjgIHkubHot7MKICAgICAgICAgICAgcmVuZGVyKCk7CiAgICAgICAgICAgIC8vIOWQjOat
peW9k+WJjSB0YWIvcXVlcnkg5YiwIEFIS++8iD8/IOabvuWPqueUqCB2aWV3VGFiIOaQnOmUmemh
te+8iQogICAgICAgICAgICByZXF1ZXN0VmlldygpOwogICAgICAgIH0gY2F0Y2gge30KICAgICAg
ICBzZWxlY3RGaXJzdE9uU2hvdyA9IHRydWU7CiAgICAgICAgbG9jYXRlQWN0aXZlID0gZmFsc2U7
CiAgICAgICAgdXBkYXRlTG9jYXRlQnRuKCk7CiAgICAgICAgY2xlYXJNdWx0aSgpOwogICAgICAg
IGNvbnN0IHZpcyA9IHZpc2libGVMaXN0KCk7CiAgICAgICAgaWYgKHZpcy5sZW5ndGgpIHsKICAg
ICAgICAgICAgc2VsZWN0ZWRJZCA9IHZpc1swXS5pZDsKICAgICAgICAgICAgcmFuZ2VBbmNob3JJ
ZCA9IHNlbGVjdGVkSWQ7CiAgICAgICAgICAgIHJhbmdlQW5jaG9yQ2xpY2tlZCA9IGZhbHNlOwog
ICAgICAgICAgICBsaXN0RWwuc2Nyb2xsVG9wID0gMDsKICAgICAgICB9CiAgICAgICAgc3luY0l0
ZW1IaWdobGlnaHQoKTsKICAgIH07CgogICAgZnVuY3Rpb24gY3R4QmluZChpZCwgZm4pIHsKICAg
ICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZChpZCkuYWRkRXZlbnRMaXN0ZW5lcignY2xpY2sn
LCBlID0+IHsKICAgICAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICAgICAgaWYg
KGN0eENsaXApIGZuKGN0eENsaXApOwogICAgICAgICAgICBoaWRlQ3R4KCk7CiAgICAgICAgfSk7
CiAgICB9CiAgICBmdW5jdGlvbiBzcWxRdW90ZSh2KSB7CiAgICAgICAgcmV0dXJuICInIiArIFN0
cmluZyh2ID8/ICcnKS5yZXBsYWNlKC8nL2csICInJyIpICsgIiciOwogICAgfQogICAgZnVuY3Rp
b24gc3RyaXBPdXRlclF1b3Rlcyh2KSB7CiAgICAgICAgY29uc3QgcyA9IFN0cmluZyh2ID8/ICcn
KS50cmltKCk7CiAgICAgICAgaWYgKChzLnN0YXJ0c1dpdGgoJyInKSAmJiBzLmVuZHNXaXRoKCci
JykpIHx8IChzLnN0YXJ0c1dpdGgoIiciKSAmJiBzLmVuZHNXaXRoKCInIikpKQogICAgICAgICAg
ICByZXR1cm4gcy5zbGljZSgxLCAtMSk7CiAgICAgICAgcmV0dXJuIHM7CiAgICB9CiAgICBmdW5j
dGlvbiBzcGxpdENzdlBhcnRzKHJhdykgewogICAgICAgIGNvbnN0IHMgPSBTdHJpbmcocmF3ID8/
ICcnKTsKICAgICAgICBjb25zdCBwYXJ0cyA9IFtdOwogICAgICAgIGxldCBjdXIgPSAnJzsKICAg
ICAgICBsZXQgcSA9ICcnOwogICAgICAgIGZvciAobGV0IGkgPSAwOyBpIDwgcy5sZW5ndGg7IGkr
KykgewogICAgICAgICAgICBjb25zdCBjaCA9IHNbaV07CiAgICAgICAgICAgIGlmIChxKSB7CiAg
ICAgICAgICAgICAgICBpZiAoY2ggPT09IHEpIHsKICAgICAgICAgICAgICAgICAgICAvLyBkb3Vi
bGVkIHF1b3RlIGVzY2FwZQogICAgICAgICAgICAgICAgICAgIGlmIChzW2kgKyAxXSA9PT0gcSkg
eyBjdXIgKz0gcTsgaSsrOyB9CiAgICAgICAgICAgICAgICAgICAgZWxzZSBxID0gJyc7CiAgICAg
ICAgICAgICAgICB9IGVsc2UgY3VyICs9IGNoOwogICAgICAgICAgICAgICAgY29udGludWU7CiAg
ICAgICAgICAgIH0KICAgICAgICAgICAgaWYgKGNoID09PSAnIicgfHwgY2ggPT09ICInIikgeyBx
ID0gY2g7IGNvbnRpbnVlOyB9CiAgICAgICAgICAgIGlmIChjaCA9PT0gJywnKSB7IHBhcnRzLnB1
c2goY3VyLnRyaW0oKSk7IGN1ciA9ICcnOyBjb250aW51ZTsgfQogICAgICAgICAgICBjdXIgKz0g
Y2g7CiAgICAgICAgfQogICAgICAgIHBhcnRzLnB1c2goY3VyLnRyaW0oKSk7CiAgICAgICAgcmV0
dXJuIHBhcnRzLmZpbHRlcihwID0+IHAgIT09ICcnKTsKICAgIH0KICAgIGZ1bmN0aW9uIHRyYW5z
Zm9ybVRleHRUb1NxbFR1cGxlKHJhdywgbW9kZSkgewogICAgICAgIGxldCBzcmMgPSBTdHJpbmco
cmF3ID8/ICcnKS50cmltKCk7CiAgICAgICAgaWYgKCFzcmMpIHJldHVybiAnJzsKICAgICAgICBs
ZXQgcGFydHMgPSBbXTsKICAgICAgICBpZiAobW9kZSA9PT0gJ2xpbmVzJykgewogICAgICAgICAg
ICBwYXJ0cyA9IHNyYy5zcGxpdCgvXHI/XG4vKS5tYXAobCA9PiBzdHJpcE91dGVyUXVvdGVzKGwu
dHJpbSgpKSkuZmlsdGVyKEJvb2xlYW4pOwogICAgICAgIH0gZWxzZSB7CiAgICAgICAgICAgIC8v
IHthLGJ9IC8gYSxiIC8geyJhIiwiYiJ9CiAgICAgICAgICAgIGNvbnN0IG0gPSBzcmMubWF0Y2go
L15ccypceyhbXHNcU10qKVx9XHMqJC8pOwogICAgICAgICAgICBpZiAobSkgc3JjID0gbVsxXS50
cmltKCk7CiAgICAgICAgICAgIHBhcnRzID0gc3BsaXRDc3ZQYXJ0cyhzcmMpLm1hcChzdHJpcE91
dGVyUXVvdGVzKS5maWx0ZXIoQm9vbGVhbik7CiAgICAgICAgfQogICAgICAgIGlmICghcGFydHMu
bGVuZ3RoKSByZXR1cm4gJyc7CiAgICAgICAgcmV0dXJuICcoJyArIHBhcnRzLm1hcChzcWxRdW90
ZSkuam9pbignLCcpICsgJyknOwogICAgfQogICAgZnVuY3Rpb24gYXBwbHlEYXRhVHJhbnNmb3Jt
KGMsIG1vZGUpIHsKICAgICAgICBpZiAoIWMpIHJldHVybjsKICAgICAgICAvLyBEbyBub3QgbXV0
YXRlIGNsaXAgaGlzdG9yeSDigJQgQUhLIHRyYW5zZm9ybXMgYSBjb3B5IGFuZCBwYXN0ZXMgaXQK
ICAgICAgICB0cnkgeyBtYXJrUGFzdGVkTG9jYWwoYy5pZCk7IH0gY2F0Y2gge30KICAgICAgICBh
aGsoJ3RleHRUcmFuc2Zvcm0nLCBTdHJpbmcoYy5pZCksIFN0cmluZyhtb2RlIHx8ICdhdXRvJykp
OwogICAgfQogICAgZnVuY3Rpb24gZGV0ZWN0RGF0YVRyYW5zZm9ybU1vZGUocmF3KSB7CiAgICAg
ICAgLy8gVUkgbGlzdCBvbmx5IGhhcyB0cnVuY2F0ZWQgcHJldmlldyAoZGF0YT0iIikuCiAgICAg
ICAgLy8gQ2hlY2sgXCIgZmlyc3Q6IGVzY2FwZWQgSlNPTiBvZnRlbiBhbHNvIHN0YXJ0cyB3aXRo
ICd7Jy4KICAgICAgICBjb25zdCBzID0gU3RyaW5nKHJhdyA/PyAnJykudHJpbSgpOwogICAgICAg
IGlmICghcykgcmV0dXJuICcnOwogICAgICAgIGlmIChzLmluY2x1ZGVzKCdcXCInKSkgcmV0dXJu
ICdqc29uJzsKICAgICAgICBpZiAocy5zdGFydHNXaXRoKCd7JykpIHJldHVybiAnYnJhY2UnOwog
ICAgICAgIGlmIChzLmluY2x1ZGVzKCdcbicpIHx8IHMuaW5jbHVkZXMoJ1xyJykpIHJldHVybiAn
bGluZXMnOwogICAgICAgIHJldHVybiAnJzsKICAgIH0KICAgIGZ1bmN0aW9uIGNsZWFyRGF0YVN1
Ym1lbnVQaWNrKCkgewogICAgICAgIHRyeSB7CiAgICAgICAgICAgIGRvY3VtZW50LnF1ZXJ5U2Vs
ZWN0b3JBbGwoJyNjLWRhdGEtc3ViIC5jLWl0ZW0ucGljaycpLmZvckVhY2goZWwgPT4gZWwuY2xh
c3NMaXN0LnJlbW92ZSgncGljaycpKTsKICAgICAgICB9IGNhdGNoIHt9CiAgICB9CiAgICBmdW5j
dGlvbiBoaWdobGlnaHREYXRhU3VibWVudU1vZGUobW9kZSkgewogICAgICAgIGNsZWFyRGF0YVN1
Ym1lbnVQaWNrKCk7CiAgICAgICAgY29uc3QgaWRNYXAgPSB7IGJyYWNlOiAnYy1kYXRhLWJyYWNl
JywgbGluZXM6ICdjLWRhdGEtbGluZXMnLCBqc29uOiAnYy1kYXRhLWpzb24nIH07CiAgICAgICAg
Y29uc3QgaWQgPSBpZE1hcFttb2RlXTsKICAgICAgICBpZiAoIWlkKSByZXR1cm47CiAgICAgICAg
Y29uc3QgZWwgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZChpZCk7CiAgICAgICAgaWYgKGVsKSBl
bC5jbGFzc0xpc3QuYWRkKCdwaWNrJyk7CiAgICB9CiAgICBmdW5jdGlvbiBwcmV2aWV3RGF0YVRy
YW5zZm9ybU1vZGVBc3luYygpIHsKICAgICAgICBjb25zdCB0b2tlbiA9ICsrcHJldmlld0RhdGFU
cmFuc2Zvcm1TZXE7CiAgICAgICAgY29uc3QgY2xpcCA9IGN0eENsaXA7CiAgICAgICAgc2V0VGlt
ZW91dCgoKSA9PiB7CiAgICAgICAgICAgIGlmICh0b2tlbiAhPT0gcHJldmlld0RhdGFUcmFuc2Zv
cm1TZXEpIHJldHVybjsKICAgICAgICAgICAgaWYgKCFjbGlwIHx8IGN0eENsaXAgIT09IGNsaXAp
IHJldHVybjsKICAgICAgICAgICAgY29uc3QgcmF3ID0gU3RyaW5nKGNsaXAuZGF0YSB8fCBjbGlw
LnByZXZpZXcgfHwgJycpOwogICAgICAgICAgICBjb25zdCBtb2RlID0gZGV0ZWN0RGF0YVRyYW5z
Zm9ybU1vZGUocmF3KTsKICAgICAgICAgICAgaWYgKHRva2VuICE9PSBwcmV2aWV3RGF0YVRyYW5z
Zm9ybVNlcSkgcmV0dXJuOwogICAgICAgICAgICBoaWdobGlnaHREYXRhU3VibWVudU1vZGUobW9k
ZSk7CiAgICAgICAgfSwgMCk7CiAgICB9CiAgICBsZXQgcHJldmlld0RhdGFUcmFuc2Zvcm1TZXEg
PSAwOwogICAgY29uc3QgZGF0YVBhcmVudCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjLWRh
dGEnKTsKICAgIGNvbnN0IGRhdGFXcmFwRWwgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYy1k
YXRhLXdyYXAnKTsKICAgIGlmIChkYXRhUGFyZW50KSB7CiAgICAgICAgZGF0YVBhcmVudC5hZGRF
dmVudExpc3RlbmVyKCdjbGljaycsIGUgPT4gewogICAgICAgICAgICBlLnN0b3BQcm9wYWdhdGlv
bigpOwogICAgICAgICAgICAvLyBQcmltYXJ5IGNsaWNrID0gYXV0byBkZXRlY3QgKyB0cmFuc2Zv
cm0gKyBwYXN0ZQogICAgICAgICAgICBpZiAoY3R4Q2xpcCkgewogICAgICAgICAgICAgICAgYXBw
bHlEYXRhVHJhbnNmb3JtKGN0eENsaXAsICdhdXRvJyk7CiAgICAgICAgICAgICAgICBoaWRlQ3R4
KCk7CiAgICAgICAgICAgICAgICByZXR1cm47CiAgICAgICAgICAgIH0KICAgICAgICAgICAgY29u
c3Qgd3JhcCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjLWRhdGEtd3JhcCcpOwogICAgICAg
ICAgICBpZiAod3JhcCkgewogICAgICAgICAgICAgICAgd3JhcC5jbGFzc0xpc3QudG9nZ2xlKCdv
cGVuJyk7CiAgICAgICAgICAgICAgICBwbGFjZURhdGFTdWJtZW51KCk7CiAgICAgICAgICAgICAg
ICBwcmV2aWV3RGF0YVRyYW5zZm9ybU1vZGVBc3luYygpOwogICAgICAgICAgICB9CiAgICAgICAg
fSk7CiAgICB9CiAgICBpZiAoZGF0YVdyYXBFbCkgewogICAgICAgIGRhdGFXcmFwRWwuYWRkRXZl
bnRMaXN0ZW5lcignbW91c2VlbnRlcicsICgpID0+IHsKICAgICAgICAgICAgcGxhY2VEYXRhU3Vi
bWVudSgpOwogICAgICAgICAgICBwcmV2aWV3RGF0YVRyYW5zZm9ybU1vZGVBc3luYygpOwogICAg
ICAgIH0pOwogICAgICAgIGRhdGFXcmFwRWwuYWRkRXZlbnRMaXN0ZW5lcignbW91c2VsZWF2ZScs
ICgpID0+IGNsZWFyRGF0YVN1Ym1lbnVQaWNrKCkpOwogICAgfQogICAgY3R4QmluZCgnYy1kYXRh
LWJyYWNlJywgYyA9PiBhcHBseURhdGFUcmFuc2Zvcm0oYywgJ2JyYWNlJykpOwogICAgY3R4Qmlu
ZCgnYy1kYXRhLWxpbmVzJywgYyA9PiBhcHBseURhdGFUcmFuc2Zvcm0oYywgJ2xpbmVzJykpOwog
ICAgY3R4QmluZCgnYy1kYXRhLWpzb24nLCBjID0+IGFwcGx5RGF0YVRyYW5zZm9ybShjLCAnanNv
bicpKTsKICAgIGN0eEJpbmQoJ2MtY29weScsICBjID0+IHsKICAgICAgICBpZiAobm9ybVR5cGUo
Yy50eXBlKSA9PT0gJ3JlY2VudCcpCiAgICAgICAgICAgIGFoaygnY29weVBhdGgnLCBTdHJpbmco
Yy5kYXRhIHx8IGMucHJldmlldyB8fCAnJykpOwogICAgICAgIGVsc2UKICAgICAgICAgICAgYWhr
KCdjb3B5QnlJZCcsIFN0cmluZyhjLmlkKSk7CiAgICB9KTsKICAgIGN0eEJpbmQoJ2MtcGFzdGUn
LCBjID0+IHsKICAgICAgICBhY3RpdmF0ZUNsaXBJdGVtKGMpOwogICAgfSk7CiAgICBjdHhCaW5k
KCdjLXBpbicsICAgYyA9PiB7CiAgICAgICAgLy8gT3B0aW1pc3RpYyBmbGlwIOKAlCDlm7rlrprl
j6rpmLLmt5jmsbDvvIzkuI3nva7pobbvvJvlho3mrKHorr/pl67miY3pnaAgUmVjb3JkIOmhtuWI
sOS4iumdogogICAgICAgIGNvbnN0IG5leHQgPSAhaXNQaW5uZWQoYyk7CiAgICAgICAgY29uc3Qg
aWQgPSArYy5pZDsKICAgICAgICBwYXRjaFBpbm5lZEluQ2FjaGVzKGlkLCBuZXh0KTsKICAgICAg
ICBjLnBpbm5lZCA9IG5leHQ7CiAgICAgICAgaWYgKG5leHQpIG1hcmtGYXZVbnNlZW4oaWQpOwog
ICAgICAgIGVsc2UgewogICAgICAgICAgICB1bnNlZW5GYXZJZHMuZGVsZXRlKGlkKTsKICAgICAg
ICAgICAgc2F2ZVVuc2VlbkZhdigpOwogICAgICAgICAgICB1cGRhdGVQaW5Eb3QoKTsKICAgICAg
ICB9CiAgICAgICAgLy8g5pS26JeP6aG15Y+W5raI77ya56uL5Yi75LuO5YiX6KGo5pGY5o6J77yM
5Yir562JIFNldFZpZXcg5omr55uYCiAgICAgICAgaWYgKCFuZXh0ICYmIGN1clRhYiA9PT0gJ3Bp
bm5lZCcpIHsKICAgICAgICAgICAgYWxsQ2xpcHMgPSBhbGxDbGlwcy5maWx0ZXIoeCA9PiAreC5p
ZCAhPT0gaWQpOwogICAgICAgICAgICBkaXNrVG90YWwgPSBNYXRoLm1heCgwLCAoTnVtYmVyKGRp
c2tUb3RhbCkgfHwgMCkgLSAxKTsKICAgICAgICAgICAgcGlubmVkVG90YWwgPSBNYXRoLm1heCgw
LCAoTnVtYmVyKHBpbm5lZFRvdGFsKSB8fCAwKSAtIDEpOwogICAgICAgICAgICBpZiAoK3NlbGVj
dGVkSWQgPT09IGlkKQogICAgICAgICAgICAgICAgc2VsZWN0ZWRJZCA9IGFsbENsaXBzLmxlbmd0
aCA/IGFsbENsaXBzWzBdLmlkIDogMDsKICAgICAgICAgICAgdHJ5IHsKICAgICAgICAgICAgICAg
IHZpZXdNZW0uc2V0KHZpZXdNZW1LZXkoY3VyVGFiLCBxdWVyeSwgdG9kYXlPbmx5KSwgewogICAg
ICAgICAgICAgICAgICAgIGl0ZW1zOiBhbGxDbGlwcy5zbGljZSgpLAogICAgICAgICAgICAgICAg
ICAgIHRvdGFsOiBkaXNrVG90YWwKICAgICAgICAgICAgICAgIH0pOwogICAgICAgICAgICB9IGNh
dGNoIHt9CiAgICAgICAgICAgIGNsZWFyRmF2VW5zZWVuKCk7CiAgICAgICAgfSBlbHNlIGlmIChj
dXJUYWIgPT09ICdwaW5uZWQnKSB7CiAgICAgICAgICAgIGNsZWFyRmF2VW5zZWVuKCk7CiAgICAg
ICAgfQogICAgICAgIHJlbmRlcigpOwogICAgICAgIGFoaygncGluJywgU3RyaW5nKGMuaWQpKTsK
ICAgIH0pOwogICAgY3R4QmluZCgnYy10b3AnLCAgIGMgPT4gYWhrKCdtb3ZlVG9Ub3AnLCAgICAg
U3RyaW5nKGMuaWQpKSk7CiAgICBjdHhCaW5kKCdjLWNsZWFyLXBhc3RlZCcsIGMgPT4gYWhrKCdj
bGVhclBhc3RlZCcsIFN0cmluZyhjLmlkKSkpOwogICAgY3R4QmluZCgnYy1xdWV1ZS1mcm9tJywg
YyA9PiB7CiAgICAgICAgYWhrKCdyZXNldFF1ZXVlRnJvbScsIFN0cmluZyhjLmlkKSk7CiAgICAg
ICAgaWYgKCFwaW5uZWRVSSkgYWhrKCdoaWRlJyk7CiAgICB9KTsKICAgIGN0eEJpbmQoJ2MtZGVs
JywgICBjID0+IHsKICAgICAgICAvLyDlpJrpgInkuJTlj7PplK7ngrnlnKjpgInkuK3pobnkuIog
4oaSIOaJuemHj+WIoOmZpO+8m+WQpuWImeWPquWIoOW9k+WJjQogICAgICAgIGxldCBpZHMgPSBb
XTsKICAgICAgICBpZiAobXVsdGlJZHMubGVuZ3RoID4gMSAmJiBtdWx0aUlkcy5pbmNsdWRlcygr
Yy5pZCkpCiAgICAgICAgICAgIGlkcyA9IG11bHRpSWRzLnNsaWNlKCk7CiAgICAgICAgZWxzZQog
ICAgICAgICAgICBpZHMgPSBbK2MuaWRdOwogICAgICAgIGlkcyA9IGlkcy5tYXAoeCA9PiAreCku
ZmlsdGVyKHggPT4geCA+IDApOwogICAgICAgIGlmICghaWRzLmxlbmd0aCkgcmV0dXJuOwogICAg
ICAgIHRyeSB7CiAgICAgICAgICAgIGNvbnN0IGlkU2V0ID0gbmV3IFNldChpZHMpOwogICAgICAg
ICAgICBhbGxDbGlwcyA9IGFsbENsaXBzLmZpbHRlcih4ID0+ICFpZFNldC5oYXMoK3guaWQpKTsK
ICAgICAgICAgICAgZGlza1RvdGFsID0gTWF0aC5tYXgoMCwgKE51bWJlcihkaXNrVG90YWwpIHx8
IDApIC0gaWRzLmxlbmd0aCk7CiAgICAgICAgICAgIGlmIChpZFNldC5oYXMoK3NlbGVjdGVkSWQp
KQogICAgICAgICAgICAgICAgc2VsZWN0ZWRJZCA9IGFsbENsaXBzLmxlbmd0aCA/IGFsbENsaXBz
WzBdLmlkIDogMDsKICAgICAgICAgICAgY2xlYXJNdWx0aSgpOwogICAgICAgICAgICByZW5kZXIo
KTsKICAgICAgICB9IGNhdGNoIHt9CiAgICAgICAgaWYgKGlkcy5sZW5ndGggPT09IDEpCiAgICAg
ICAgICAgIGFoaygnZGVsZXRlJywgU3RyaW5nKGlkc1swXSkpOwogICAgICAgIGVsc2UKICAgICAg
ICAgICAgYWhrKCdkZWxldGVNYW55JywgaWRzLmpvaW4oJywnKSk7CiAgICB9KTsKICAgIGN0eEJp
bmQoJ2MtdGl0bGUnLCBjID0+IG9wZW5UaXRsZURsZyhjKSk7CiAgICBjdHhCaW5kKCdjLW1lcmdl
JywgYyA9PiB7CiAgICAgICAgY29uc3QgaWRzID0gKG11bHRpSWRzLmxlbmd0aCA+PSAyKSA/IG11
bHRpSWRzLnNsaWNlKCkgOiBbXTsKICAgICAgICBpZiAoaWRzLmxlbmd0aCA8IDIpIHJldHVybjsK
ICAgICAgICBpZiAoIWlkcy5pbmNsdWRlcygrYy5pZCkpIGlkcy5wdXNoKCtjLmlkKTsKICAgICAg
ICBhaGsoJ21lcmdlRmF2JywgaWRzLmpvaW4oJywnKSk7CiAgICAgICAgY2xlYXJNdWx0aSgpOwog
ICAgfSk7CiAgICBjdHhCaW5kKCdjLXVubWVyZ2UnLCBjID0+IHsKICAgICAgICBhaGsoJ3VubWVy
Z2VGYXYnLCBTdHJpbmcoYy5pZCkpOwogICAgICAgIGNsZWFyTXVsdGkoKTsKICAgIH0pOwoKICAg
IGNvbnN0IHRpdGxlRGxnID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3RpdGxlLWRsZycpOwog
ICAgY29uc3QgdGl0bGVJbnB1dCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd0aXRsZS1pbnB1
dCcpOwogICAgbGV0IHRpdGxlRGxnQ2xpcCA9IG51bGw7CiAgICBmdW5jdGlvbiBjbG9zZVRpdGxl
RGxnKCkgewogICAgICAgIGlmICh0aXRsZURsZykgdGl0bGVEbGcuY2xhc3NMaXN0LnJlbW92ZSgn
b24nKTsKICAgICAgICB0aXRsZURsZ0NsaXAgPSBudWxsOwogICAgfQogICAgZnVuY3Rpb24gZm9j
dXNUaXRsZUlucHV0KCkgewogICAgICAgIHRyeSB7IGFoaygnZm9jdXNQYW5lbCcpOyB9IGNhdGNo
IHt9CiAgICAgICAgdHJ5IHsKICAgICAgICAgICAgaWYgKCF0aXRsZUlucHV0KSByZXR1cm47CiAg
ICAgICAgICAgIHRpdGxlSW5wdXQuZm9jdXMoeyBwcmV2ZW50U2Nyb2xsOiB0cnVlIH0pOwogICAg
ICAgICAgICB0aXRsZUlucHV0LnNlbGVjdCgpOwogICAgICAgIH0gY2F0Y2ggewogICAgICAgICAg
ICB0cnkgeyB0aXRsZUlucHV0LmZvY3VzKCk7IHRpdGxlSW5wdXQuc2VsZWN0KCk7IH0gY2F0Y2gg
e30KICAgICAgICB9CiAgICB9CiAgICBmdW5jdGlvbiBvcGVuVGl0bGVEbGcoYykgewogICAgICAg
IGhpZGVDdHgoKTsKICAgICAgICB0aXRsZURsZ0NsaXAgPSBjOwogICAgICAgIGlmICh0aXRsZUlu
cHV0KSB0aXRsZUlucHV0LnZhbHVlID0gU3RyaW5nKGMuZmF2VGl0bGUgfHwgJycpLnRyaW0oKTsK
ICAgICAgICBpZiAodGl0bGVEbGcpIHRpdGxlRGxnLmNsYXNzTGlzdC5hZGQoJ29uJyk7CiAgICAg
ICAgZm9jdXNUaXRsZUlucHV0KCk7CiAgICAgICAgcmVxdWVzdEFuaW1hdGlvbkZyYW1lKGZvY3Vz
VGl0bGVJbnB1dCk7CiAgICAgICAgc2V0VGltZW91dChmb2N1c1RpdGxlSW5wdXQsIDQwKTsKICAg
ICAgICBzZXRUaW1lb3V0KGZvY3VzVGl0bGVJbnB1dCwgMTIwKTsKICAgIH0KICAgIGlmICh0aXRs
ZUlucHV0KSB7CiAgICAgICAgdGl0bGVJbnB1dC5hZGRFdmVudExpc3RlbmVyKCdtb3VzZWRvd24n
LCBlID0+IHsKICAgICAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICAgICAgdHJ5
IHsgYWhrKCdmb2N1c1BhbmVsJyk7IH0gY2F0Y2gge30KICAgICAgICB9KTsKICAgICAgICB0aXRs
ZUlucHV0LmFkZEV2ZW50TGlzdGVuZXIoJ2ZvY3VzJywgKCkgPT4gewogICAgICAgICAgICB0cnkg
eyBhaGsoJ2ZvY3VzUGFuZWwnKTsgfSBjYXRjaCB7fQogICAgICAgIH0pOwogICAgfQogICAgaWYg
KHRpdGxlRGxnKSB7CiAgICAgICAgdGl0bGVEbGcuYWRkRXZlbnRMaXN0ZW5lcignY2xpY2snLCBl
ID0+IHsKICAgICAgICAgICAgaWYgKGUudGFyZ2V0ID09PSB0aXRsZURsZykgewogICAgICAgICAg
ICAgICAgY2xvc2VUaXRsZURsZygpOwogICAgICAgICAgICAgICAgdHJ5IHsgYWhrKCdibHVyUGFu
ZWwnKTsgfSBjYXRjaCB7fQogICAgICAgICAgICB9CiAgICAgICAgfSk7CiAgICAgICAgdGl0bGVE
bGcuYWRkRXZlbnRMaXN0ZW5lcignbW91c2Vkb3duJywgZSA9PiBlLnN0b3BQcm9wYWdhdGlvbigp
KTsKICAgIH0KICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd0aXRsZS1jYW5jZWwnKT8uYWRk
RXZlbnRMaXN0ZW5lcignY2xpY2snLCBlID0+IHsKICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigp
OwogICAgICAgIGNsb3NlVGl0bGVEbGcoKTsKICAgICAgICBhaGsoJ2JsdXJQYW5lbCcpOwogICAg
fSk7CiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgndGl0bGUtb2snKT8uYWRkRXZlbnRMaXN0
ZW5lcignY2xpY2snLCBlID0+IHsKICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgICAg
IGlmICghdGl0bGVEbGdDbGlwKSByZXR1cm47CiAgICAgICAgY29uc3QgdCA9IFN0cmluZyh0aXRs
ZUlucHV0Py52YWx1ZSB8fCAnJykudHJpbSgpLnNsaWNlKDAsIDgwKTsKICAgICAgICBjb25zdCBp
ZCA9IFN0cmluZyh0aXRsZURsZ0NsaXAuaWQpOwogICAgICAgIC8vIE9wdGltaXN0aWMgbG9jYWwg
dXBkYXRlCiAgICAgICAgY29uc3QgaGl0ID0gYWxsQ2xpcHMuZmluZCh4ID0+ICt4LmlkID09PSAr
aWQpOwogICAgICAgIGlmIChoaXQpIGhpdC5mYXZUaXRsZSA9IHQ7CiAgICAgICAgdGl0bGVEbGdD
bGlwLmZhdlRpdGxlID0gdDsKICAgICAgICBjbG9zZVRpdGxlRGxnKCk7CiAgICAgICAgYWhrKCdz
ZXRGYXZUaXRsZScsIGlkLCB0KTsKICAgICAgICBhaGsoJ2JsdXJQYW5lbCcpOwogICAgICAgIHJl
bmRlcigpOwogICAgfSk7CiAgICB0aXRsZUlucHV0Py5hZGRFdmVudExpc3RlbmVyKCdrZXlkb3du
JywgZSA9PiB7CiAgICAgICAgaWYgKGUua2V5ID09PSAnRW50ZXInKSB7CiAgICAgICAgICAgIGUu
cHJldmVudERlZmF1bHQoKTsKICAgICAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAg
ICAgICAgZS5zdG9wSW1tZWRpYXRlUHJvcGFnYXRpb24oKTsKICAgICAgICAgICAgZG9jdW1lbnQu
Z2V0RWxlbWVudEJ5SWQoJ3RpdGxlLW9rJyk/LmNsaWNrKCk7CiAgICAgICAgICAgIHJldHVybjsK
ICAgICAgICB9CiAgICAgICAgaWYgKGUua2V5ID09PSAnRXNjYXBlJykgewogICAgICAgICAgICBl
LnByZXZlbnREZWZhdWx0KCk7CiAgICAgICAgICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAg
ICAgICAgIGNsb3NlVGl0bGVEbGcoKTsKICAgICAgICAgICAgYWhrKCdibHVyUGFuZWwnKTsKICAg
ICAgICAgICAgcmV0dXJuOwogICAgICAgIH0KICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwog
ICAgfSwgdHJ1ZSk7CgogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3RhYnMnKS5hZGRFdmVu
dExpc3RlbmVyKCdjbGljaycsIGUgPT4gewogICAgICAgIGNvbnN0IHRhYiA9IGUudGFyZ2V0LmNs
b3Nlc3QoJy50YWInKTsKICAgICAgICBpZiAoIXRhYiB8fCBlLnRhcmdldC5jbG9zZXN0KCcjdGFi
LWFjdGlvbnMnKSkgcmV0dXJuOwogICAgICAgIHNldFRhYih0YWIuZGF0YXNldC50YWIpOwogICAg
fSk7CgogICAgY29uc3Qgc3JjaFdyYXAgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc2VhcmNo
LXdyYXAnKTsKICAgIGNvbnN0IGJ0blNlYXJjaCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdi
dG4tc2VhcmNoJyk7CiAgICBjb25zdCBidG5Mb2NhdGUgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJ
ZCgnYnRuLWxvY2F0ZScpOwogICAgY29uc3QgYnRuVG9kYXkgPSBkb2N1bWVudC5nZXRFbGVtZW50
QnlJZCgnYnRuLXRvZGF5Jyk7CiAgICBjb25zdCBzcmNoID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5
SWQoJ3NlYXJjaCcpOwogICAgY29uc3Qgc2NsciA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdz
ZWFyY2gtY2xyJyk7CiAgICBsZXQgZGViOwoKICAgIHVwZGF0ZUxvY2F0ZUJ0bigpOwogICAgaWYg
KGJ0bkxvY2F0ZSkgewogICAgICAgIGJ0bkxvY2F0ZS5hZGRFdmVudExpc3RlbmVyKCdjbGljaycs
IGUgPT4gewogICAgICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgICAgICAgICBqdW1w
VG9MYXN0UGFzdGUoKTsKICAgICAgICB9KTsKICAgIH0KCiAgICBidG5Ub2RheS5hZGRFdmVudExp
c3RlbmVyKCdtb3VzZWRvd24nLCBlID0+IHsKICAgICAgICBlLnByZXZlbnREZWZhdWx0KCk7CiAg
ICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgIH0pOwogICAgYnRuVG9kYXkuYWRkRXZlbnRM
aXN0ZW5lcignY2xpY2snLCBlID0+IHsKICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAg
ICAgIGUucHJldmVudERlZmF1bHQoKTsKICAgICAgICB0b2RheU9ubHkgPSAhdG9kYXlPbmx5Owog
ICAgICAgIGJ0blRvZGF5LmNsYXNzTGlzdC50b2dnbGUoJ29uJywgdG9kYXlPbmx5KTsKICAgICAg
ICBsaXN0RWwuc2Nyb2xsVG9wID0gMDsKICAgICAgICByZXF1ZXN0VmlldygpOwogICAgICAgIHRy
eSB7IHNyY2guZm9jdXMoKTsgfSBjYXRjaCB7fQogICAgfSk7CgogICAgZnVuY3Rpb24gb3BlblNl
YXJjaCgpIHsKICAgICAgICBpZiAoc3JjaFdyYXAuY2xhc3NMaXN0LmNvbnRhaW5zKCdvcGVuJykp
IHsKICAgICAgICAgICAgYWhrKCdmb2N1c1BhbmVsJyk7CiAgICAgICAgICAgIHRyeSB7IHNyY2gu
Zm9jdXMoKTsgfSBjYXRjaCB7fQogICAgICAgICAgICByZXR1cm47CiAgICAgICAgfQogICAgICAg
IHNyY2hXcmFwLmNsYXNzTGlzdC5hZGQoJ29wZW4nKTsKICAgICAgICAvLyBEZWZhdWx0OiDmiYDm
nInpobXmiZPlvIDmkJzntKLml7bpu5jorqTmkJzlhajpg6gKICAgICAgICBjb25zdCB3YW50VG9k
YXkgPSBmYWxzZTsKICAgICAgICBpZiAodG9kYXlPbmx5ICE9PSB3YW50VG9kYXkpIHsKICAgICAg
ICAgICAgdG9kYXlPbmx5ID0gd2FudFRvZGF5OwogICAgICAgICAgICBidG5Ub2RheS5jbGFzc0xp
c3QudG9nZ2xlKCdvbicsIHRvZGF5T25seSk7CiAgICAgICAgICAgIGxpc3RFbC5zY3JvbGxUb3Ag
PSAwOwogICAgICAgICAgICByZXF1ZXN0VmlldygpOwogICAgICAgIH0gZWxzZSB7CiAgICAgICAg
ICAgIGJ0blRvZGF5LmNsYXNzTGlzdC50b2dnbGUoJ29uJywgdG9kYXlPbmx5KTsKICAgICAgICB9
CiAgICAgICAgYWhrKCdmb2N1c1BhbmVsJyk7CiAgICAgICAgcmVxdWVzdEFuaW1hdGlvbkZyYW1l
KCgpID0+IHsKICAgICAgICAgICAgdHJ5IHsgc3JjaC5mb2N1cygpOyB9IGNhdGNoIHt9CiAgICAg
ICAgfSk7CiAgICB9CiAgICBmdW5jdGlvbiBjbG9zZVNlYXJjaFVpKCkgewogICAgICAgIHNyY2hX
cmFwLmNsYXNzTGlzdC5yZW1vdmUoJ29wZW4nKTsKICAgICAgICBpZiAoIXNyY2gudmFsdWUpIHsK
ICAgICAgICAgICAgc3JjaC5jbGFzc0xpc3QucmVtb3ZlKCdoYXMtdmFsJyk7CiAgICAgICAgICAg
IHNjbHIuc3R5bGUuZGlzcGxheSA9ICdub25lJzsKICAgICAgICAgICAgLy8gTGVhdmluZyBzZWFy
Y2ggd2l0aCBlbXB0eSBxdWVyeSDihpIgZHJvcCB0b2RheSBmaWx0ZXIKICAgICAgICAgICAgaWYg
KHRvZGF5T25seSkgewogICAgICAgICAgICAgICAgdG9kYXlPbmx5ID0gZmFsc2U7CiAgICAgICAg
ICAgICAgICBidG5Ub2RheS5jbGFzc0xpc3QucmVtb3ZlKCdvbicpOwogICAgICAgICAgICAgICAg
cmVxdWVzdFZpZXcoKTsKICAgICAgICAgICAgfQogICAgICAgIH0KICAgIH0KICAgIHdpbmRvdy5f
X29wZW5TZWFyY2ggPSBvcGVuU2VhcmNoOwogICAgd2luZG93Ll9fcHJlcFR5cGVTZWFyY2ggPSAo
KSA9PiB7CiAgICAgICAgdHJ5IHsKICAgICAgICAgICAgY29uc3Qgd3JhcCA9IGRvY3VtZW50Lmdl
dEVsZW1lbnRCeUlkKCdzZWFyY2gtd3JhcCcpOwogICAgICAgICAgICBjb25zdCBzID0gZG9jdW1l
bnQuZ2V0RWxlbWVudEJ5SWQoJ3NlYXJjaCcpOwogICAgICAgICAgICBpZiAod3JhcCAmJiAhd3Jh
cC5jbGFzc0xpc3QuY29udGFpbnMoJ29wZW4nKSkgewogICAgICAgICAgICAgICAgd3JhcC5jbGFz
c0xpc3QuYWRkKCdvcGVuJyk7CiAgICAgICAgICAgICAgICB0cnkgewogICAgICAgICAgICAgICAg
ICAgIGNvbnN0IHdhbnRUb2RheSA9IGZhbHNlOwogICAgICAgICAgICAgICAgICAgIGlmICh0eXBl
b2YgdG9kYXlPbmx5ICE9PSAndW5kZWZpbmVkJyAmJiB0b2RheU9ubHkgIT09IHdhbnRUb2RheSkg
ewogICAgICAgICAgICAgICAgICAgICAgICB0b2RheU9ubHkgPSB3YW50VG9kYXk7CiAgICAgICAg
ICAgICAgICAgICAgICAgIGlmICh0eXBlb2YgYnRuVG9kYXkgIT09ICd1bmRlZmluZWQnICYmIGJ0
blRvZGF5KSBidG5Ub2RheS5jbGFzc0xpc3QudG9nZ2xlKCdvbicsIHRvZGF5T25seSk7CiAgICAg
ICAgICAgICAgICAgICAgICAgIGlmICh0eXBlb2YgbGlzdEVsICE9PSAndW5kZWZpbmVkJyAmJiBs
aXN0RWwpIGxpc3RFbC5zY3JvbGxUb3AgPSAwOwogICAgICAgICAgICAgICAgICAgICAgICBpZiAo
dHlwZW9mIHJlcXVlc3RWaWV3ID09PSAnZnVuY3Rpb24nKSBzZXRUaW1lb3V0KHJlcXVlc3RWaWV3
LCAwKTsKICAgICAgICAgICAgICAgICAgICB9IGVsc2UgaWYgKHR5cGVvZiBidG5Ub2RheSAhPT0g
J3VuZGVmaW5lZCcgJiYgYnRuVG9kYXkpIHsKICAgICAgICAgICAgICAgICAgICAgICAgYnRuVG9k
YXkuY2xhc3NMaXN0LnRvZ2dsZSgnb24nLCAhIXRvZGF5T25seSk7CiAgICAgICAgICAgICAgICAg
ICAgfQogICAgICAgICAgICAgICAgfSBjYXRjaCB7fQogICAgICAgICAgICB9CiAgICAgICAgICAg
IC8vID8/IOmVnOWDj+aQnOe0ou+8muS4jeimgSBmb2N1c++8jOmBv+WFjeaKoui1sOWOn+e8lui+
keahhuWFieaghwogICAgICAgIH0gY2F0Y2gge30KICAgIH07CiAgICB3aW5kb3cuX190eXBlU2Vh
cmNoID0gKGNoKSA9PiB7CiAgICAgICAgdHJ5IHsKICAgICAgICAgICAgd2luZG93Ll9fcHJlcFR5
cGVTZWFyY2ggJiYgd2luZG93Ll9fcHJlcFR5cGVTZWFyY2goKTsKICAgICAgICAgICAgY29uc3Qg
cyA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzZWFyY2gnKTsKICAgICAgICAgICAgaWYgKCFz
KSByZXR1cm47CiAgICAgICAgICAgIHMudmFsdWUgPSBTdHJpbmcocy52YWx1ZSB8fCAnJykgKyBT
dHJpbmcoY2ggPT0gbnVsbCA/ICcnIDogY2gpOwogICAgICAgICAgICBzLmNsYXNzTGlzdC50b2dn
bGUoJ2hhcy12YWwnLCAhIXMudmFsdWUpOwogICAgICAgICAgICBzLmRpc3BhdGNoRXZlbnQobmV3
IEV2ZW50KCdpbnB1dCcsIHsgYnViYmxlczogdHJ1ZSB9KSk7CiAgICAgICAgfSBjYXRjaCB7fQog
ICAgfTsKICAgIHdpbmRvdy5fX2Jrc3BTZWFyY2ggPSAoKSA9PiB7CiAgICAgICAgdHJ5IHsKICAg
ICAgICAgICAgd2luZG93Ll9fcHJlcFR5cGVTZWFyY2ggJiYgd2luZG93Ll9fcHJlcFR5cGVTZWFy
Y2goKTsKICAgICAgICAgICAgY29uc3QgcyA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzZWFy
Y2gnKTsKICAgICAgICAgICAgaWYgKCFzKSByZXR1cm47CiAgICAgICAgICAgIGNvbnN0IHYgPSBT
dHJpbmcocy52YWx1ZSB8fCAnJyk7CiAgICAgICAgICAgIHMudmFsdWUgPSB2Lmxlbmd0aCA/IHYu
c2xpY2UoMCwgLTEpIDogJyc7CiAgICAgICAgICAgIHMuY2xhc3NMaXN0LnRvZ2dsZSgnaGFzLXZh
bCcsICEhcy52YWx1ZSk7CiAgICAgICAgICAgIHMuZGlzcGF0Y2hFdmVudChuZXcgRXZlbnQoJ2lu
cHV0JywgeyBidWJibGVzOiB0cnVlIH0pKTsKICAgICAgICB9IGNhdGNoIHt9CiAgICB9OwogICAg
d2luZG93Ll9fc2V0U2VhcmNoUXVlcnkgPSAocSkgPT4gewogICAgICAgIHRyeSB7CiAgICAgICAg
ICAgIGNvbnN0IHMgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc2VhcmNoJyk7CiAgICAgICAg
ICAgIGlmICghcykgcmV0dXJuOwogICAgICAgICAgICBjb25zdCBuZXh0ID0gU3RyaW5nKHEgPT0g
bnVsbCA/ICcnIDogcSk7CiAgICAgICAgICAgIGNvbnN0IHByZXYgPSBTdHJpbmcocy52YWx1ZSB8
fCAnJyk7CiAgICAgICAgICAgIC8vIOWQjOWFs+mUruWtl+mHjeWkjeaOqOmAge+8muWPquS/neiv
geaQnOe0ouahhuW8gOedgO+8jOemgeatouWGjSByZXF1ZXN0Vmlld++8iOS8muatu+W+queOr+mX
qu+8iQogICAgICAgICAgICBpZiAocHJldiA9PT0gbmV4dCAmJiBTdHJpbmcocXVlcnkgfHwgJycp
ID09PSBuZXh0KSB7CiAgICAgICAgICAgICAgICB0cnkgewogICAgICAgICAgICAgICAgICAgIGNv
bnN0IHdyYXAgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc2VhcmNoLXdyYXAnKTsKICAgICAg
ICAgICAgICAgICAgICBpZiAod3JhcCAmJiAhd3JhcC5jbGFzc0xpc3QuY29udGFpbnMoJ29wZW4n
KSkKICAgICAgICAgICAgICAgICAgICAgICAgd3JhcC5jbGFzc0xpc3QuYWRkKCdvcGVuJyk7CiAg
ICAgICAgICAgICAgICB9IGNhdGNoIHt9CiAgICAgICAgICAgICAgICByZXR1cm47CiAgICAgICAg
ICAgIH0KICAgICAgICAgICAgLy8g5omT5a2X5Y2z5pe25LiK5bGP77yM5LiO56OB55uY5pCc57Si
6Kej6ICmCiAgICAgICAgICAgIHMudmFsdWUgPSBuZXh0OwogICAgICAgICAgICBzLmNsYXNzTGlz
dC50b2dnbGUoJ2hhcy12YWwnLCAhIXMudmFsdWUpOwogICAgICAgICAgICBjb25zdCBzY2xyID0g
ZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NlYXJjaC1jbHInKTsKICAgICAgICAgICAgaWYgKHNj
bHIpIHNjbHIuc3R5bGUuZGlzcGxheSA9IHMudmFsdWUgPyAnYmxvY2snIDogJ25vbmUnOwogICAg
ICAgICAgICBxdWVyeSA9IHMudmFsdWU7CiAgICAgICAgICAgIHRyeSB7CiAgICAgICAgICAgICAg
ICBjb25zdCB3cmFwID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NlYXJjaC13cmFwJyk7CiAg
ICAgICAgICAgICAgICBpZiAod3JhcCAmJiAhd3JhcC5jbGFzc0xpc3QuY29udGFpbnMoJ29wZW4n
KSkKICAgICAgICAgICAgICAgICAgICB3aW5kb3cuX19wcmVwVHlwZVNlYXJjaCAmJiB3aW5kb3cu
X19wcmVwVHlwZVNlYXJjaCgpOwogICAgICAgICAgICAgICAgZWxzZSBpZiAod3JhcCkKICAgICAg
ICAgICAgICAgICAgICB3cmFwLmNsYXNzTGlzdC5hZGQoJ29wZW4nKTsKICAgICAgICAgICAgfSBj
YXRjaCB7fQogICAgICAgICAgICB3aW5kb3cuX19ob3N0RmlsdGVyZWQgPSBmYWxzZTsKICAgICAg
ICAgICAgd2luZG93Ll9faG9zdEZpbHRlclEgPSAnJzsKICAgICAgICAgICAgaWYgKFN0cmluZyhx
dWVyeSB8fCAnJykudHJpbSgpKSB7CiAgICAgICAgICAgICAgICB3YWl0aW5nRGF0YSA9IHRydWU7
CiAgICAgICAgICAgICAgICB3aW5kb3cuX19kYXRhUmVhZHkgPSBmYWxzZTsKICAgICAgICAgICAg
fQogICAgICAgICAgICB0cnkgewogICAgICAgICAgICAgICAgY29uc3QgY250ID0gZG9jdW1lbnQu
Z2V0RWxlbWVudEJ5SWQoJ2Jhci10eHQnKTsKICAgICAgICAgICAgICAgIGlmIChjbnQgJiYgU3Ry
aW5nKHF1ZXJ5IHx8ICcnKS50cmltKCkpCiAgICAgICAgICAgICAgICAgICAgY250LnRleHRDb250
ZW50ID0gdmlzaWJsZUxpc3QoKS5sZW5ndGggKyAnIOadoSc7CiAgICAgICAgICAgIH0gY2F0Y2gg
e30KICAgICAgICAgICAgdHJ5IHsgcmVuZGVyKCk7IH0gY2F0Y2gge30KICAgICAgICAgICAgY2xl
YXJUaW1lb3V0KHdpbmRvdy5fX3FxVmlld0RlYik7CiAgICAgICAgICAgIHdpbmRvdy5fX3FxVmll
d0RlYiA9IHNldFRpbWVvdXQoKCkgPT4gewogICAgICAgICAgICAgICAgd2luZG93Ll9fcXFWaWV3
RGViID0gMDsKICAgICAgICAgICAgICAgIHJlcXVlc3RWaWV3KCk7CiAgICAgICAgICAgIH0sIDcw
KTsKICAgICAgICB9IGNhdGNoIHt9CiAgICB9OwogICAgd2luZG93Ll9fY2xlYXJRUVNlYXJjaCA9
ICgpID0+IHsKICAgICAgICB0cnkgewogICAgICAgICAgICBxdWVyeSA9ICcnOwogICAgICAgICAg
ICB3aW5kb3cuX19ob3N0RmlsdGVyZWQgPSBmYWxzZTsKICAgICAgICAgICAgd2luZG93Ll9faG9z
dEZpbHRlclEgPSAnJzsKICAgICAgICAgICAgY29uc3QgcyA9IGRvY3VtZW50LmdldEVsZW1lbnRC
eUlkKCdzZWFyY2gnKTsKICAgICAgICAgICAgaWYgKHMpIHsKICAgICAgICAgICAgICAgIHMudmFs
dWUgPSAnJzsKICAgICAgICAgICAgICAgIHMuY2xhc3NMaXN0LnJlbW92ZSgnaGFzLXZhbCcpOwog
ICAgICAgICAgICAgICAgdHJ5IHsgcy5ibHVyKCk7IH0gY2F0Y2gge30KICAgICAgICAgICAgfQog
ICAgICAgICAgICBjb25zdCBzY2xyID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NlYXJjaC1j
bHInKTsKICAgICAgICAgICAgaWYgKHNjbHIpIHNjbHIuc3R5bGUuZGlzcGxheSA9ICdub25lJzsK
ICAgICAgICAgICAgY29uc3Qgd3JhcCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzZWFyY2gt
d3JhcCcpOwogICAgICAgICAgICBpZiAod3JhcCkgd3JhcC5jbGFzc0xpc3QucmVtb3ZlKCdvcGVu
Jyk7CiAgICAgICAgICAgIHRyeSB7IHJlbmRlcigpOyB9IGNhdGNoIHt9CiAgICAgICAgfSBjYXRj
aCB7fQogICAgfTsKICAgIC8vIENhcHR1cmUgQ3RybCtGIGluc2lkZSBXZWJWaWV3IChDaHJvbWl1
bSBmaW5kIGlzIGRpc2FibGVkLCBidXQgc3RpbGwgaGFuZGxlIGhlcmUpCiAgICBkb2N1bWVudC5h
ZGRFdmVudExpc3RlbmVyKCdrZXlkb3duJywgZSA9PiB7CiAgICAgICAgaWYgKChlLmN0cmxLZXkg
fHwgZS5tZXRhS2V5KSAmJiAhZS5hbHRLZXkgJiYgKGUua2V5ID09PSAnZicgfHwgZS5rZXkgPT09
ICdGJykpIHsKICAgICAgICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOwogICAgICAgICAgICBlLnN0
b3BQcm9wYWdhdGlvbigpOwogICAgICAgICAgICBvcGVuU2VhcmNoKCk7CiAgICAgICAgfQogICAg
fSwgdHJ1ZSk7CiAgICBidG5TZWFyY2guYWRkRXZlbnRMaXN0ZW5lcignY2xpY2snLCBlID0+IHsK
ICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgICAgIG9wZW5TZWFyY2goKTsKICAgIH0p
OwogICAgbGV0IF9fc3JjaENvbXBvc2luZyA9IGZhbHNlOwogICAgY29uc3QgX19mbHVzaFNlYXJj
aElucHV0ID0gKCkgPT4gewogICAgICAgIHF1ZXJ5ID0gc3JjaC52YWx1ZTsKICAgICAgICBzcmNo
LmNsYXNzTGlzdC50b2dnbGUoJ2hhcy12YWwnLCAhIXF1ZXJ5KTsKICAgICAgICBzY2xyLnN0eWxl
LmRpc3BsYXkgPSBxdWVyeSA/ICdibG9jaycgOiAnbm9uZSc7CiAgICAgICAgbGlzdEVsLnNjcm9s
bFRvcCA9IDA7CiAgICAgICAgd2luZG93Ll9faG9zdEZpbHRlcmVkID0gZmFsc2U7CiAgICAgICAg
d2luZG93Ll9faG9zdEZpbHRlclEgPSAnJzsKICAgICAgICB0cnkgeyByZW5kZXIoKTsgfSBjYXRj
aCB7fQogICAgICAgIGNsZWFyVGltZW91dChkZWIpOwogICAgICAgIGRlYiA9IHNldFRpbWVvdXQo
cmVxdWVzdFZpZXcsIDgwKTsKICAgIH07CiAgICBzcmNoLmFkZEV2ZW50TGlzdGVuZXIoJ2NvbXBv
c2l0aW9uc3RhcnQnLCAoKSA9PiB7IF9fc3JjaENvbXBvc2luZyA9IHRydWU7IH0pOwogICAgc3Jj
aC5hZGRFdmVudExpc3RlbmVyKCdjb21wb3NpdGlvbmVuZCcsICgpID0+IHsKICAgICAgICBfX3Ny
Y2hDb21wb3NpbmcgPSBmYWxzZTsKICAgICAgICBfX2ZsdXNoU2VhcmNoSW5wdXQoKTsKICAgIH0p
OwogICAgc3JjaC5hZGRFdmVudExpc3RlbmVyKCdpbnB1dCcsICgpID0+IHsKICAgICAgICBpZiAo
X19zcmNoQ29tcG9zaW5nKSB7CiAgICAgICAgICAgIHF1ZXJ5ID0gc3JjaC52YWx1ZTsKICAgICAg
ICAgICAgc3JjaC5jbGFzc0xpc3QudG9nZ2xlKCdoYXMtdmFsJywgISFxdWVyeSk7CiAgICAgICAg
ICAgIHNjbHIuc3R5bGUuZGlzcGxheSA9IHF1ZXJ5ID8gJ2Jsb2NrJyA6ICdub25lJzsKICAgICAg
ICAgICAgcmV0dXJuOwogICAgICAgIH0KICAgICAgICBfX2ZsdXNoU2VhcmNoSW5wdXQoKTsKICAg
IH0pOwogICAgc3JjaC5hZGRFdmVudExpc3RlbmVyKCdmb2N1cycsICgpID0+IHsKICAgICAgICAv
LyBJZGVtcG90ZW50IG9uIEFISyBzaWRlIOKAlCBzYWZlLCBidXQgYXZvaWQgc3BhbW1pbmcgZHVy
aW5nIElNRQogICAgICAgIHRyeSB7IGFoaygnZm9jdXNQYW5lbCcpOyB9IGNhdGNoIHt9CiAgICB9
KTsKICAgIHNyY2guYWRkRXZlbnRMaXN0ZW5lcignYmx1cicsICgpID0+IHsKICAgICAgICBzZXRU
aW1lb3V0KCgpID0+IHsKICAgICAgICAgICAgaWYgKGRvY3VtZW50LmFjdGl2ZUVsZW1lbnQgPT09
IHNyY2gpIHJldHVybjsKICAgICAgICAgICAgaWYgKGRvY3VtZW50LmFjdGl2ZUVsZW1lbnQgPT09
IHNjbHIgfHwgKHNjbHIgJiYgc2Nsci5jb250YWlucyhkb2N1bWVudC5hY3RpdmVFbGVtZW50KSkp
IHJldHVybjsKICAgICAgICAgICAgaWYgKGRvY3VtZW50LmFjdGl2ZUVsZW1lbnQgPT09IGJ0blRv
ZGF5IHx8IChidG5Ub2RheSAmJiBidG5Ub2RheS5jb250YWlucyhkb2N1bWVudC5hY3RpdmVFbGVt
ZW50KSkpIHJldHVybjsKICAgICAgICAgICAgLy8gSU1FIGNhbmRpZGF0ZSBVSSBzdGVhbHMgZm9j
dXMgYnJpZWZseSDigJQga2VlcCBzZWFyY2ggaWYgc3RpbGwgY29tcG9zaW5nCiAgICAgICAgICAg
IGlmIChfX3NyY2hDb21wb3NpbmcpIHJldHVybjsKICAgICAgICAgICAgY2xvc2VTZWFyY2hVaSgp
OwogICAgICAgICAgICBhaGsoJ2JsdXJQYW5lbCcpOwogICAgICAgIH0sIDI4MCk7CiAgICB9KTsK
ICAgIHNyY2guYWRkRXZlbnRMaXN0ZW5lcigna2V5ZG93bicsIGUgPT4gewogICAgICAgIC8vIEN0
cmwrSSAvIEN0cmwrSzogbW92ZSBjbGlwIHNlbGVjdGlvbiAobm90IGluc2VydCBjaGFyIC8gYnJv
d3NlciBzaG9ydGN1dCkKICAgICAgICBpZiAoKGUuY3RybEtleSB8fCBlLm1ldGFLZXkpICYmIChl
LmtleSA9PT0gJ2knIHx8IGUua2V5ID09PSAnSScpKSB7CiAgICAgICAgICAgIGUucHJldmVudERl
ZmF1bHQoKTsKICAgICAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICAgICAgd2lu
ZG93Ll9fbmF2ICYmIHdpbmRvdy5fX25hdigndXAnKTsKICAgICAgICAgICAgcmV0dXJuOwogICAg
ICAgIH0KICAgICAgICBpZiAoKGUuY3RybEtleSB8fCBlLm1ldGFLZXkpICYmIChlLmtleSA9PT0g
J2snIHx8IGUua2V5ID09PSAnSycpKSB7CiAgICAgICAgICAgIGUucHJldmVudERlZmF1bHQoKTsK
ICAgICAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICAgICAgd2luZG93Ll9fbmF2
ICYmIHdpbmRvdy5fX25hdignZG93bicpOwogICAgICAgICAgICByZXR1cm47CiAgICAgICAgfQog
ICAgICAgIGlmIChlLmtleSA9PT0gJ0Fycm93RG93bicpIHsKICAgICAgICAgICAgZS5wcmV2ZW50
RGVmYXVsdCgpOwogICAgICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgICAgICAgICB3
aW5kb3cuX19uYXYgJiYgd2luZG93Ll9fbmF2KCdkb3duJyk7CiAgICAgICAgICAgIHJldHVybjsK
ICAgICAgICB9CiAgICAgICAgaWYgKGUua2V5ID09PSAnQXJyb3dVcCcpIHsKICAgICAgICAgICAg
ZS5wcmV2ZW50RGVmYXVsdCgpOwogICAgICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAg
ICAgICAgICB3aW5kb3cuX19uYXYgJiYgd2luZG93Ll9fbmF2KCd1cCcpOwogICAgICAgICAgICBy
ZXR1cm47CiAgICAgICAgfQogICAgICAgIGlmIChlLmtleSA9PT0gJ0VzY2FwZScpIHsKICAgICAg
ICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOwogICAgICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigp
OwogICAgICAgICAgICAvLyBBbHdheXMgZGlzbWlzcyB0aGUgd2hvbGUgcGFuZWwgKG5vdCBqdXN0
IHRoZSBzZWFyY2ggZmllbGQpCiAgICAgICAgICAgIGlmICghcGlubmVkVUkpIGFoaygnaGlkZScp
OwogICAgICAgICAgICByZXR1cm47CiAgICAgICAgfQogICAgICAgIGUuc3RvcFByb3BhZ2F0aW9u
KCk7CiAgICB9KTsKICAgIHNjbHIuYWRkRXZlbnRMaXN0ZW5lcignY2xpY2snLCBlID0+IHsKICAg
ICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgICAgIHNyY2gudmFsdWUgPSBxdWVyeSA9ICcn
OwogICAgICAgIHNjbHIuc3R5bGUuZGlzcGxheSA9ICdub25lJzsKICAgICAgICBzcmNoLmNsYXNz
TGlzdC5yZW1vdmUoJ2hhcy12YWwnKTsKICAgICAgICByZXF1ZXN0VmlldygpOwogICAgICAgIGFo
aygnZm9jdXNQYW5lbCcpOwogICAgICAgIHNyY2guZm9jdXMoKTsKICAgIH0pOwoKICAgIGNvbnN0
IFRBQl9OQU1FUyA9IHsgYWxsOiAn5YWo6YOoJywgdGV4dDogJ+aWh+acrCcsIGltYWdlOiAn5Zu+
5YOPJywgZmlsZTogJ+aWh+S7ticsIHJlY2VudDogJ+acgOi/kScsIHBpbm5lZDogJ+aUtuiXjycg
fTsKICAgIGNvbnN0IGNsckRsZyA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjbHItZGxnJyk7
CiAgICBjb25zdCBjbHJBbGxDYiA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjbHItYWxsJyk7
CiAgICBmdW5jdGlvbiBvcGVuQ2xlYXJEbGcoKSB7CiAgICAgICAgY29uc3QgbmFtZSA9IFRBQl9O
QU1FU1tjdXJUYWJdIHx8ICflvZPliY0nOwogICAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlk
KCdjbHItdGl0bGUnKS50ZXh0Q29udGVudCA9ICfmuIXnqbrjgIwnICsgbmFtZSArICfjgI3vvJ8n
OwogICAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjbHItZGVzYycpLnRleHRDb250ZW50
ID0gY3VyVGFiID09PSAncGlubmVkJwogICAgICAgICAgICA/ICfpu5jorqTku4XmuIXnqbrlvZPl
pKnnmoTmlLbol4/pobnjgILli77pgInjgIzmuIXnqbrmiYDmnInjgI3lj6/muIXpmaTor6XpgInp
obnljaHlhajpg6jlhoXlrrnjgIInCiAgICAgICAgICAgIDogKGN1clRhYiA9PT0gJ3JlY2VudCcK
ICAgICAgICAgICAgICAgID8gJ+a4heepuuOAjOacgOi/keOAjeS8muWIoOmZpOacquWbuuWumuea
hOacgOi/keebruW9leiusOW9le+8m+W3suWbuuWumueahOebruW9leS8muS/neeVmeOAgicKICAg
ICAgICAgICAgICAgIDogJ+S7hea4heepuuW9k+WJjemAiemhueWNoeOAgum7mOiupOWPqua4heW9
k+Wkqe+8m+aUtuiXj+mhueS4jeS8muiiq+a4hemZpOOAguWLvumAieOAjOa4heepuuaJgOacieOA
jeWPr+a4hemZpOivpemAiemhueWNoeWFqOmDqOaXpeacn+OAgicpOwogICAgICAgIGNsckFsbENi
LmNoZWNrZWQgPSBmYWxzZTsKICAgICAgICBjbHJEbGcuY2xhc3NMaXN0LmFkZCgnb24nKTsKICAg
IH0KICAgIGZ1bmN0aW9uIGNsb3NlQ2xlYXJEbGcoKSB7CiAgICAgICAgY2xyRGxnLmNsYXNzTGlz
dC5yZW1vdmUoJ29uJyk7CiAgICB9CiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYnRuLWNs
cicpLmFkZEV2ZW50TGlzdGVuZXIoJ2NsaWNrJywgZSA9PiB7CiAgICAgICAgZS5zdG9wUHJvcGFn
YXRpb24oKTsKICAgICAgICBvcGVuQ2xlYXJEbGcoKTsKICAgIH0pOwogICAgZG9jdW1lbnQuZ2V0
RWxlbWVudEJ5SWQoJ2Nsci1jYW5jZWwnKS5hZGRFdmVudExpc3RlbmVyKCdjbGljaycsIGUgPT4g
ewogICAgICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAgICAgY2xvc2VDbGVhckRsZygpOwog
ICAgfSk7CiAgICBjbHJEbGcuYWRkRXZlbnRMaXN0ZW5lcignY2xpY2snLCBlID0+IHsKICAgICAg
ICBpZiAoZS50YXJnZXQgPT09IGNsckRsZykgY2xvc2VDbGVhckRsZygpOwogICAgfSk7CiAgICBk
b2N1bWVudC5nZXRFbGVtZW50QnlJZCgnY2xyLW9rJykuYWRkRXZlbnRMaXN0ZW5lcignY2xpY2sn
LCBlID0+IHsKICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgICAgIGNvbnN0IHNjb3Bl
ID0gKGN1clRhYiA9PT0gJ3JlY2VudCcpID8gJ2FsbCcgOiAoY2xyQWxsQ2IuY2hlY2tlZCA/ICdh
bGwnIDogJ3RvZGF5Jyk7CiAgICAgICAgY2xvc2VDbGVhckRsZygpOwogICAgICAgIGFoaygnY2xl
YXInLCBjdXJUYWIsIHNjb3BlKTsKICAgIH0pOwogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQo
J211bHRpLXNlbCcpLmFkZEV2ZW50TGlzdGVuZXIoJ2NsaWNrJywgZSA9PiB7CiAgICAgICAgZS5z
dG9wUHJvcGFnYXRpb24oKTsKICAgICAgICBjbGVhck11bHRpKHRydWUpOwogICAgfSk7CiAgICBk
b2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYnRuLXBpbicpLmFkZEV2ZW50TGlzdGVuZXIoJ2NsaWNr
JywgZSA9PiB7CiAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICBwaW5uZWRVSSA9
ICFwaW5uZWRVSTsKICAgICAgICBlLmN1cnJlbnRUYXJnZXQuY2xhc3NMaXN0LnRvZ2dsZSgnb24n
LCBwaW5uZWRVSSk7CiAgICAgICAgYWhrKCd0b2dnbGVQaW4nLCBwaW5uZWRVSSA/ICcxJyA6ICcw
Jyk7CiAgICB9KTsKCiAgICB3aW5kb3cuX19wZXJmTWFyayA9IChzdGFnZSkgPT4gewogICAgICAg
IHRyeSB7CiAgICAgICAgICAgIGlmICh3aW5kb3cuY2hyb21lICYmIGNocm9tZS53ZWJ2aWV3ICYm
IGNocm9tZS53ZWJ2aWV3LnBvc3RNZXNzYWdlKQogICAgICAgICAgICAgICAgY2hyb21lLndlYnZp
ZXcucG9zdE1lc3NhZ2UoJ3BlcmZ8JyArIFN0cmluZyhzdGFnZSB8fCAnJykpOwogICAgICAgIH0g
Y2F0Y2gge30KICAgIH07CgogICAgd2luZG93Ll9fdXBkYXRlQ2xpcHMgPSBwYXlsb2FkID0+IHsK
ICAgICAgICBjb25zdCB0MCA9ICh0eXBlb2YgcGVyZm9ybWFuY2UgIT09ICd1bmRlZmluZWQnICYm
IHBlcmZvcm1hbmNlLm5vdykgPyBwZXJmb3JtYW5jZS5ub3coKSA6IERhdGUubm93KCk7CiAgICAg
ICAgd2luZG93Ll9fcGVyZk1hcmsoJ2pzX3VwZGF0ZUNsaXBzX2VudGVyIG49JyArIChwYXlsb2Fk
ICYmIHBheWxvYWQuaXRlbXMgPyBwYXlsb2FkLml0ZW1zLmxlbmd0aCA6IChBcnJheS5pc0FycmF5
KHBheWxvYWQpID8gcGF5bG9hZC5sZW5ndGggOiAwKSkpOwogICAgICAgIC8vIEtlZXAgcHJldmlv
dXMgc2Nyb2xsIGZvciBsb2FkLW1vcmU7IHJlc2V0IHdoZW4gb3BlbmluZyBwYW5lbCB0byBmaXJz
dCBpdGVtCiAgICAgICAgY29uc3Qga2VlcFNjcm9sbCA9ICFzZWxlY3RGaXJzdE9uU2hvdzsKICAg
ICAgICBjb25zdCBzdCA9IGxpc3RFbC5zY3JvbGxUb3A7CiAgICAgICAgd2luZG93Ll9fd2FpdGlu
Z1ZpZXcgPSBmYWxzZTsKICAgICAgICBjb25zdCB3YXNBcHBlbmQgPSBwYXlsb2FkICYmIHBheWxv
YWQuYXBwZW5kOwogICAgICAgIGxvYWRpbmdNb3JlID0gZmFsc2U7CiAgICAgICAgY29uc3QgcHJl
dkl0ZW1zID0gYWxsQ2xpcHM7CiAgICAgICAgbGV0IG5leHRJdGVtcyA9IFtdOwogICAgICAgIGxl
dCBuZXh0VG90YWwgPSAwOwogICAgICAgIGxldCBuZXh0RmlsdGVyZWQgPSBmYWxzZTsKICAgICAg
ICBsZXQgcFRhYiA9ICcnOwogICAgICAgIGxldCBwUGlubmVkVG90YWwgPSAtMTsKICAgICAgICBp
ZiAoQXJyYXkuaXNBcnJheShwYXlsb2FkKSkgewogICAgICAgICAgICBuZXh0SXRlbXMgPSBwYXls
b2FkOwogICAgICAgICAgICBuZXh0VG90YWwgPSBwYXlsb2FkLmxlbmd0aDsKICAgICAgICAgICAg
bmV4dEZpbHRlcmVkID0gZmFsc2U7CiAgICAgICAgfSBlbHNlIGlmIChwYXlsb2FkICYmIHR5cGVv
ZiBwYXlsb2FkID09PSAnb2JqZWN0JykgewogICAgICAgICAgICBuZXh0VG90YWwgPSBOdW1iZXIo
cGF5bG9hZC50b3RhbCkgfHwgMDsKICAgICAgICAgICAgbmV4dEl0ZW1zID0gQXJyYXkuaXNBcnJh
eShwYXlsb2FkLml0ZW1zKSA/IHBheWxvYWQuaXRlbXMgOiBbXTsKICAgICAgICAgICAgcFRhYiA9
IHBheWxvYWQudGFiICE9IG51bGwgPyBTdHJpbmcocGF5bG9hZC50YWIpIDogJyc7CiAgICAgICAg
ICAgIGlmIChwYXlsb2FkLnBpbm5lZFRvdGFsICE9IG51bGwgJiYgcGF5bG9hZC5waW5uZWRUb3Rh
bCAhPT0gJycpCiAgICAgICAgICAgICAgICBwUGlubmVkVG90YWwgPSBOdW1iZXIocGF5bG9hZC5w
aW5uZWRUb3RhbCkgfHwgMDsKICAgICAgICAgICAgY29uc3QgcHEwID0gcGF5bG9hZC5xdWVyeSAh
PSBudWxsID8gU3RyaW5nKHBheWxvYWQucXVlcnkpIDogJyc7CiAgICAgICAgICAgIG5leHRGaWx0
ZXJlZCA9ICEhKHBheWxvYWQuZmlsdGVyZWQgfHwgKHBxMCAmJiBwcTAudHJpbSgpKSk7CiAgICAg
ICAgICAgIGlmIChwYXlsb2FkLmFwcGVuZCkgewogICAgICAgICAgICAgICAgLy8gQXBwZW5kIG9u
bHkgYXBwbGllcyB0byB0aGUgdGFiIHdlJ3JlIGN1cnJlbnRseSB2aWV3aW5nCiAgICAgICAgICAg
ICAgICBpZiAocFRhYiAmJiBwVGFiICE9PSBjdXJUYWIpCiAgICAgICAgICAgICAgICAgICAgcmV0
dXJuOwogICAgICAgICAgICAgICAgY29uc3Qgc2VlbiA9IG5ldyBTZXQoYWxsQ2xpcHMubWFwKGMg
PT4gK2MuaWQpKTsKICAgICAgICAgICAgICAgIGNvbnN0IG1lcmdlZCA9IGFsbENsaXBzLnNsaWNl
KCk7CiAgICAgICAgICAgICAgICBuZXh0SXRlbXMuZm9yRWFjaChpdCA9PiB7CiAgICAgICAgICAg
ICAgICAgICAgaWYgKCFzZWVuLmhhcygraXQuaWQpKSBtZXJnZWQucHVzaChpdCk7CiAgICAgICAg
ICAgICAgICB9KTsKICAgICAgICAgICAgICAgIG5leHRJdGVtcyA9IG1lcmdlZDsKICAgICAgICAg
ICAgICAgIG5leHRUb3RhbCA9IE1hdGgubWF4KG5leHRUb3RhbCwgbmV4dEl0ZW1zLmxlbmd0aCk7
CiAgICAgICAgICAgIH0KICAgICAgICAgICAgLy8g5pCc57Si5qGG5Lul5omT5a2X6ZWc5YOP5Li6
5YeG77yM57ud5LiN6KKr5rue5ZCO55qE56OB55uY57uT5p6c5YaZ5Zue5pen5YWz6ZSu5a2XCiAg
ICAgICAgICAgIHRyeSB7CiAgICAgICAgICAgICAgICBjb25zdCBzID0gZG9jdW1lbnQuZ2V0RWxl
bWVudEJ5SWQoJ3NlYXJjaCcpOwogICAgICAgICAgICAgICAgaWYgKHMgJiYgU3RyaW5nKHMudmFs
dWUgfHwgJycpLmxlbmd0aCkKICAgICAgICAgICAgICAgICAgICBxdWVyeSA9IHMudmFsdWU7CiAg
ICAgICAgICAgICAgICBlbHNlIGlmIChwcTAgIT09ICcnICYmICFTdHJpbmcocXVlcnkgfHwgJycp
LnRyaW0oKSkKICAgICAgICAgICAgICAgICAgICBxdWVyeSA9IHBxMDsKICAgICAgICAgICAgfSBj
YXRjaCB7fQogICAgICAgIH0gZWxzZSB7CiAgICAgICAgICAgIG5leHRJdGVtcyA9IFtdOwogICAg
ICAgICAgICBuZXh0VG90YWwgPSAwOwogICAgICAgICAgICBuZXh0RmlsdGVyZWQgPSBmYWxzZTsK
ICAgICAgICB9CgogICAgICAgIGNvbnN0IGJveFEgPSBTdHJpbmcocXVlcnkgfHwgJycpLnRyaW0o
KTsKICAgICAgICBjb25zdCBwdXNoUSA9IChwYXlsb2FkICYmIHR5cGVvZiBwYXlsb2FkID09PSAn
b2JqZWN0JyAmJiBwYXlsb2FkLnF1ZXJ5ICE9IG51bGwpCiAgICAgICAgICAgID8gU3RyaW5nKHBh
eWxvYWQucXVlcnkpLnRyaW0oKSA6ICcnOwoKICAgICAgICAvLyBBbHdheXMgcmVmcmVzaCDmlLbo
l48gYmFkZ2UgZnJvbSBob3N0IHdoZW4gcHJvdmlkZWQKICAgICAgICBpZiAocFBpbm5lZFRvdGFs
ID49IDApCiAgICAgICAgICAgIHBpbm5lZFRvdGFsID0gcFBpbm5lZFRvdGFsOwoKICAgICAgICAv
LyBTdGFsZSBzZWFyY2ggcHVzaCAoZS5nLiAic3F1YXJlIGxvZ2kiIGxhbmRzIGFmdGVyIHVzZXIg
dHlwZWQgInNxdWFyZSBsb2dpbiIpIOKAlGNhY2hlIG9ubHkKICAgICAgICBpZiAoIXdhc0FwcGVu
ZCAmJiBuZXh0RmlsdGVyZWQgJiYgcHVzaFEgJiYgYm94USAmJiBwdXNoUSAhPT0gYm94USkgewog
ICAgICAgICAgICB2aWV3TWVtLnNldCh2aWV3TWVtS2V5KHBUYWIgfHwgY3VyVGFiLCBwdXNoUSwg
dG9kYXlPbmx5KSwgewogICAgICAgICAgICAgICAgaXRlbXM6IG5leHRJdGVtcy5zbGljZSgpLAog
ICAgICAgICAgICAgICAgdG90YWw6IG5leHRUb3RhbAogICAgICAgICAgICB9KTsKICAgICAgICAg
ICAgcmV0dXJuOwogICAgICAgIH0KCiAgICAgICAgLy8gU3RhbGUgcHVzaCBmb3IgYW5vdGhlciB0
YWI6IG9ubHkgcmVmcmVzaCB0aGF0IHRhYidzIHZpZXdNZW0sIGRvbid0IGhpamFjayBVSQogICAg
ICAgIGlmICghd2FzQXBwZW5kICYmIHBUYWIgJiYgcFRhYiAhPT0gY3VyVGFiKSB7CiAgICAgICAg
ICAgIGNvbnN0IG1lbVEgPSAocGF5bG9hZCAmJiB0eXBlb2YgcGF5bG9hZCA9PT0gJ29iamVjdCcg
JiYgcGF5bG9hZC5xdWVyeSAhPSBudWxsKQogICAgICAgICAgICAgICAgPyBTdHJpbmcocGF5bG9h
ZC5xdWVyeSkgOiAnJzsKICAgICAgICAgICAgdmlld01lbS5zZXQodmlld01lbUtleShwVGFiLCBt
ZW1RLCB0b2RheU9ubHkpLCB7CiAgICAgICAgICAgICAgICBpdGVtczogbmV4dEl0ZW1zLnNsaWNl
KCksCiAgICAgICAgICAgICAgICB0b3RhbDogbmV4dFRvdGFsCiAgICAgICAgICAgIH0pOwogICAg
ICAgICAgICAvLyBTdGlsbCB1cGRhdGUgcGluIGJhZGdlIGlmIGhvc3Qgc2VudCBpdAogICAgICAg
ICAgICB0cnkgeyB1cGRhdGVQaW5Eb3QoKTsgfSBjYXRjaCB7fQogICAgICAgICAgICAvLyBRUSDm
kJzntKLmm77lm7rlrprmjqggYWxsIHRhYiDihpIg5b2T5YmNIHRhYiDkvJrkuIDnm7Tpqqjmnrbv
vJvooaXkuIDmrKEgcmVxdWVzdFZpZXcKICAgICAgICAgICAgaWYgKHdhaXRpbmdEYXRhICYmIHB1
c2hRID09PSBib3hRKSB7CiAgICAgICAgICAgICAgICBzZXRUaW1lb3V0KCgpID0+IHsKICAgICAg
ICAgICAgICAgICAgICBpZiAod2FpdGluZ0RhdGEgJiYgY3VyVGFiICE9PSBwVGFiKQogICAgICAg
ICAgICAgICAgICAgICAgICByZXF1ZXN0VmlldygpOwogICAgICAgICAgICAgICAgfSwgNDApOwog
ICAgICAgICAgICB9CiAgICAgICAgICAgIHJldHVybjsKICAgICAgICB9CgogICAgICAgIC8vIEJv
b3RzdHJhcCByYWNlOiBBSEsgcHVzaGVkIGVtcHR5IGJlZm9yZSBXYXJtQWxsVmlld3Mg4oCUa2Vl
cCBza2VsZXRvbiwgaWdub3JlCiAgICAgICAgY29uc3QgcU9uID0gU3RyaW5nKHF1ZXJ5IHx8ICcn
KS50cmltKCkubGVuZ3RoID4gMDsKICAgICAgICBpZiAoIXdhc0FwcGVuZCAmJiAhbmV4dEl0ZW1z
Lmxlbmd0aCAmJiBuZXh0VG90YWwgPD0gMCAmJiAhcU9uICYmICFuZXh0RmlsdGVyZWQgJiYgIXNh
d05vbkVtcHR5KSB7CiAgICAgICAgICAgIGlmICghd2luZG93Ll9fZW1wdHlGYWxsYmFja1QpIHsK
ICAgICAgICAgICAgICAgIHdpbmRvdy5fX2VtcHR5RmFsbGJhY2tUID0gc2V0VGltZW91dCgoKSA9
PiB7CiAgICAgICAgICAgICAgICAgICAgd2luZG93Ll9fZW1wdHlGYWxsYmFja1QgPSAwOwogICAg
ICAgICAgICAgICAgICAgIGlmIChzYXdOb25FbXB0eSkgcmV0dXJuOwogICAgICAgICAgICAgICAg
ICAgIC8vIFRydWx5IGVtcHR5IGluc3RhbGwgYWZ0ZXIgd2FpdAogICAgICAgICAgICAgICAgICAg
IHNhd05vbkVtcHR5ID0gdHJ1ZTsKICAgICAgICAgICAgICAgICAgICBob3N0UHVzaGVkT25jZSA9
IHRydWU7CiAgICAgICAgICAgICAgICAgICAgd2luZG93Ll9fZGF0YVJlYWR5ID0gdHJ1ZTsKICAg
ICAgICAgICAgICAgICAgICBhbGxDbGlwcyA9IFtdOwogICAgICAgICAgICAgICAgICAgIGRpc2tU
b3RhbCA9IDA7CiAgICAgICAgICAgICAgICAgICAgY2xlYXJXYWl0aW5nRGF0YSgpOwogICAgICAg
ICAgICAgICAgICAgIHRyeSB7IHJlbmRlcigpOyB9IGNhdGNoIHt9CiAgICAgICAgICAgICAgICB9
LCA0NTAwKTsKICAgICAgICAgICAgfQogICAgICAgICAgICB3YWl0aW5nRGF0YSA9IHRydWU7CiAg
ICAgICAgICAgIHdpbmRvdy5fX2RhdGFSZWFkeSA9IGZhbHNlOwogICAgICAgICAgICBob3N0UHVz
aGVkT25jZSA9IGZhbHNlOwogICAgICAgICAgICBzZXRCb290TG9hZGluZyh0cnVlKTsKICAgICAg
ICAgICAgdHJ5IHsgcmVuZGVyKCk7IH0gY2F0Y2gge30KICAgICAgICAgICAgcmV0dXJuOwogICAg
ICAgIH0KCiAgICAgICAgY2xlYXJXYWl0aW5nRGF0YSgpOwogICAgICAgIGFsbENsaXBzID0gbmV4
dEl0ZW1zOwogICAgICAgIGRpc2tUb3RhbCA9IG5leHRUb3RhbDsKICAgICAgICAvLyBLZWVwIGJh
ciBjb25zaXN0ZW50IGlmIGxpc3QgZ3JldyBwYXN0IGEgc3RhbGUgdG90YWwKICAgICAgICBpZiAo
YWxsQ2xpcHMubGVuZ3RoID4gZGlza1RvdGFsKQogICAgICAgICAgICBkaXNrVG90YWwgPSBhbGxD
bGlwcy5sZW5ndGg7CiAgICAgICAgd2luZG93Ll9faG9zdEZpbHRlcmVkID0gbmV4dEZpbHRlcmVk
OwogICAgICAgIHdpbmRvdy5fX2hvc3RGaWx0ZXJRID0gKG5leHRGaWx0ZXJlZCAmJiBwdXNoUSkg
PyBwdXNoUSA6ICcnOwogICAgICAgIC8vIEZpbHRlcmVkIHNlYXJjaCB3aXRoIDAgaGl0cyDigJRt
dXN0IGxlYXZlIHNrZWxldG9uIChob3N0IGRpZCByZXNwb25kKQogICAgICAgIGlmICghd2FzQXBw
ZW5kICYmIG5leHRGaWx0ZXJlZCAmJiAhYWxsQ2xpcHMubGVuZ3RoICYmIGRpc2tUb3RhbCA8PSAw
KSB7CiAgICAgICAgICAgIGhvc3RQdXNoZWRPbmNlID0gdHJ1ZTsKICAgICAgICAgICAgc2F3Tm9u
RW1wdHkgPSB0cnVlOwogICAgICAgIH0KICAgICAgICBpZiAoYWxsQ2xpcHMubGVuZ3RoIHx8IGRp
c2tUb3RhbCA+IDApCiAgICAgICAgICAgIHNhd05vbkVtcHR5ID0gdHJ1ZTsKICAgICAgICBpZiAo
d2luZG93Ll9fZW1wdHlGYWxsYmFja1QpIHsKICAgICAgICAgICAgY2xlYXJUaW1lb3V0KHdpbmRv
dy5fX2VtcHR5RmFsbGJhY2tUKTsKICAgICAgICAgICAgd2luZG93Ll9fZW1wdHlGYWxsYmFja1Qg
PSAwOwogICAgICAgIH0KICAgICAgICBpZiAoIXdhc0FwcGVuZCkgewogICAgICAgICAgICBjb25z
dCBtZW1RID0gKHBheWxvYWQgJiYgdHlwZW9mIHBheWxvYWQgPT09ICdvYmplY3QnICYmIHBheWxv
YWQucXVlcnkgIT0gbnVsbCkKICAgICAgICAgICAgICAgID8gU3RyaW5nKHBheWxvYWQucXVlcnkp
IDogcXVlcnk7CiAgICAgICAgICAgIHZpZXdNZW0uc2V0KHZpZXdNZW1LZXkoY3VyVGFiLCBtZW1R
LCB0b2RheU9ubHkpLCB7CiAgICAgICAgICAgICAgICBpdGVtczogYWxsQ2xpcHMuc2xpY2UoKSwK
ICAgICAgICAgICAgICAgIHRvdGFsOiBkaXNrVG90YWwKICAgICAgICAgICAgfSk7CiAgICAgICAg
fQogICAgICAgIHdpbmRvdy5fX2RhdGFSZWFkeSA9IHRydWU7CiAgICAgICAgaG9zdFB1c2hlZE9u
Y2UgPSB0cnVlOwoKICAgICAgICAvLyBNaWQtd2hlZWw6IGtlZXAgZGF0YSwgZGVsYXkgRE9NIHNv
IHNjcm9sbC9kcmFnIG5ldmVyIGhpdGNoIG9uIGFwcGVuZCBwYWludAogICAgICAgIGlmICh3YXNB
cHBlbmQgJiYgd2luZG93Ll9fc2Nyb2xsQnVzeSAmJiAhd2luZG93Ll9fcGVuZGluZ0p1bXBJZCkg
ewogICAgICAgICAgICBjb25zdCBmcm9tTGVuID0gKHByZXZJdGVtcyAmJiBwcmV2SXRlbXMubGVu
Z3RoKSA/IHByZXZJdGVtcy5sZW5ndGggOiAwOwogICAgICAgICAgICBpZiAoIV9wZW5kaW5nQXBw
ZW5kKQogICAgICAgICAgICAgICAgX3BlbmRpbmdBcHBlbmQgPSB7IGZyb21MZW46IGZyb21MZW4g
fTsKICAgICAgICAgICAgdHJ5IHsgcmVmcmVzaExpc3RDaHJvbWUoKTsgfSBjYXRjaCB7fQogICAg
ICAgICAgICByZXR1cm47CiAgICAgICAgfQoKICAgICAgICBjb25zdCB3YXNCb290TG9hZGluZyA9
IGJvb3RMb2FkaW5nOwogICAgICAgIGxldCBzYW1lUGFpbnQgPSBmYWxzZTsKICAgICAgICBjb25z
dCBwcmV2TGVuID0gKHByZXZJdGVtcyAmJiBwcmV2SXRlbXMubGVuZ3RoKSA/IHByZXZJdGVtcy5s
ZW5ndGggOiAwOwogICAgICAgIGlmICghd2FzQXBwZW5kICYmICF3YXNCb290TG9hZGluZyAmJiBw
cmV2SXRlbXMgJiYgcHJldkl0ZW1zLmxlbmd0aCA9PT0gYWxsQ2xpcHMubGVuZ3RoICYmIHByZXZJ
dGVtcy5sZW5ndGgpIHsKICAgICAgICAgICAgc2FtZVBhaW50ID0gdHJ1ZTsKICAgICAgICAgICAg
Zm9yIChsZXQgaSA9IDA7IGkgPCBhbGxDbGlwcy5sZW5ndGg7IGkrKykgewogICAgICAgICAgICAg
ICAgaWYgKCtwcmV2SXRlbXNbaV0uaWQgIT09ICthbGxDbGlwc1tpXS5pZCkgeyBzYW1lUGFpbnQg
PSBmYWxzZTsgYnJlYWs7IH0KICAgICAgICAgICAgfQogICAgICAgICAgICBpZiAoc2FtZVBhaW50
ICYmICFsaXN0RWwucXVlcnlTZWxlY3RvcignLml0bScpKSBzYW1lUGFpbnQgPSBmYWxzZTsKICAg
ICAgICB9CiAgICAgICAgY29uc3QgZmluaXNoVXBkYXRlID0gKCkgPT4gewogICAgICAgICAgICBj
b25zdCB0UmVuZGVyMCA9ICh0eXBlb2YgcGVyZm9ybWFuY2UgIT09ICd1bmRlZmluZWQnICYmIHBl
cmZvcm1hbmNlLm5vdykgPyBwZXJmb3JtYW5jZS5ub3coKSA6IERhdGUubm93KCk7CiAgICAgICAg
ICAgIGNsZWFyV2FpdGluZ0RhdGEoKTsKICAgICAgICAgICAgaWYgKHdhc0FwcGVuZCAmJiAhd2Fz
Qm9vdExvYWRpbmcgJiYgcHJldkxlbiA+IDAgJiYgYWxsQ2xpcHMubGVuZ3RoID4gcHJldkxlbikg
ewogICAgICAgICAgICAgICAgYXBwZW5kUmVuZGVyKHByZXZMZW4pOwogICAgICAgICAgICB9IGVs
c2UgaWYgKCFzYW1lUGFpbnQpIHsKICAgICAgICAgICAgICAgIHJlbmRlcigpOwogICAgICAgICAg
ICAgICAgYXBwbHlUYWJTd2l0Y2hBbmltKCk7CiAgICAgICAgICAgICAgICBpZiAoa2VlcFNjcm9s
bCkKICAgICAgICAgICAgICAgICAgICBsaXN0RWwuc2Nyb2xsVG9wID0gc3Q7CiAgICAgICAgICAg
ICAgICBlbHNlCiAgICAgICAgICAgICAgICAgICAgbGlzdEVsLnNjcm9sbFRvcCA9IDA7CiAgICAg
ICAgICAgIH0gZWxzZSB7CiAgICAgICAgICAgICAgICB0cnkgeyByZWZyZXNoTGlzdENocm9tZSgp
OyB9IGNhdGNoIHt9CiAgICAgICAgICAgICAgICBpZiAoa2VlcFNjcm9sbCkKICAgICAgICAgICAg
ICAgICAgICBsaXN0RWwuc2Nyb2xsVG9wID0gc3Q7CiAgICAgICAgICAgIH0KICAgICAgICAgICAg
Y29uc3QgdDEgPSAodHlwZW9mIHBlcmZvcm1hbmNlICE9PSAndW5kZWZpbmVkJyAmJiBwZXJmb3Jt
YW5jZS5ub3cpID8gcGVyZm9ybWFuY2Uubm93KCkgOiBEYXRlLm5vdygpOwogICAgICAgICAgICB3
aW5kb3cuX19wZXJmTWFyaygnanNfdXBkYXRlQ2xpcHNfZG9uZSByZW5kZXJNcz0nICsgTWF0aC5y
b3VuZCh0MSAtIHRSZW5kZXIwKSArICcgdG90YWxNcz0nICsgTWF0aC5yb3VuZCh0MSAtIHQwKSAr
ICcgbj0nICsgYWxsQ2xpcHMubGVuZ3RoKTsKICAgICAgICB9OwogICAgICAgIGlmICh3YXNCb290
TG9hZGluZykgewogICAgICAgICAgICBjb25zdCBzaW5jZSA9IHdpbmRvdy5fX3NrZWxTaW5jZSB8
fCAwOwogICAgICAgICAgICBjb25zdCB3YWl0ID0gc2luY2UgPyBNYXRoLm1heCgwLCA4MCAtIChE
YXRlLm5vdygpIC0gc2luY2UpKSA6IDA7CiAgICAgICAgICAgIGlmICh3YWl0ID4gMCkKICAgICAg
ICAgICAgICAgIHNldFRpbWVvdXQoZmluaXNoVXBkYXRlLCB3YWl0KTsKICAgICAgICAgICAgZWxz
ZQogICAgICAgICAgICAgICAgZmluaXNoVXBkYXRlKCk7CiAgICAgICAgfSBlbHNlIHsKICAgICAg
ICAgICAgZmluaXNoVXBkYXRlKCk7CiAgICAgICAgfQogICAgfTsKICAgIHdpbmRvdy5fX3NldFBp
bm5lZCA9IHYgPT4gewogICAgICAgIHBpbm5lZFVJID0gISF2OwogICAgICAgIGRvY3VtZW50Lmdl
dEVsZW1lbnRCeUlkKCdidG4tcGluJykuY2xhc3NMaXN0LnRvZ2dsZSgnb24nLCBwaW5uZWRVSSk7
CiAgICB9OwogICAgd2luZG93Ll9fbG9hZE1vcmVEb25lID0gKCkgPT4gewogICAgICAgIGxvYWRp
bmdNb3JlID0gZmFsc2U7CiAgICAgICAgaWYgKHdpbmRvdy5fX2xvYWRNb3JlV2F0Y2gpIHsKICAg
ICAgICAgICAgY2xlYXJUaW1lb3V0KHdpbmRvdy5fX2xvYWRNb3JlV2F0Y2gpOwogICAgICAgICAg
ICB3aW5kb3cuX19sb2FkTW9yZVdhdGNoID0gMDsKICAgICAgICB9CiAgICAgICAgaWYgKHdpbmRv
dy5fX3BlbmRpbmdKdW1wSWQpCiAgICAgICAgICAgIHRyeUNvbnRpbnVlSnVtcCgpOwogICAgfTsK
CiAgICBpbml0U2VwVWkoKTsKICAgIHVwZGF0ZVBpbkRvdCgpOwogICAgc2NoZWR1bGVEZWxheWVk
U2tlbCgpOwogICAgd2luZG93Ll9fcGVyZk1hcmsgJiYgd2luZG93Ll9fcGVyZk1hcmsoJ2pzX2Jv
b3QgcmVxdWVzdFZpZXcnKTsKICAgIHJlcXVlc3RWaWV3KCk7CiAgICAvLyBzY2hlZHVsZURlbGF5
ZWRTa2VsIGFscmVhZHkgcmVuZGVyKCknZCB3aGVuIGVtcHR5OyBzdGlsbCBwYWludCBvbmNlIGZv
ciBjaHJvbWUKCiAgICA8L3NjcmlwdD4KPC9ib2R5Pgo8L2h0bWw+
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

; ?? 搜索中（面板可能已 SoftHide）：Esc 结束本次搜索
#HotIf qqSearchOn
Esc::EscHidePanel("")
#HotIf

; Unpinned: arrows / Enter / Esc hide
#HotIf ClipPanelIsUp() && !uiPinned
Up::PanelKeyUp("")
Down::PanelKeyDown("")
Enter::PanelKeyEnter("")
Esc::EscHidePanel("")
~LButton::OnOutsideClick("")
~LAlt::EscHidePanel("")
~RAlt::EscHidePanel("")
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
        ; 固定显示期间也记住最近编辑窗，方便多次粘贴
        if panelVisible
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
    ; Esc / ??? / 超时取消：结束镜像，不保留脏查询；下次需重新 ??
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

    if qqMarkCount >= 3 {
        ; ??? → 不触发搜索，清掉刚武装的状态
        SetTimer(QQResetMarkCount, 0)
        qqMarkCount := 0
        QQAbortSearch()
        return
    }
    if qqMarkCount = 2 {
        ; ?? → 清空旧条件，等待关键字；尚未出 UI
        QQArmFreshSearch()
    }
}

; 重新打 ??：清空之前的查询条件，只武装、不弹窗
QQArmFreshSearch(*) {
    global qqSearchOn, qqQuery, qqIh, qqAwaitKeyword, qqPanelPlaced
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
    qqIh.OnKeyDown := QQOnKeyDown
    qqIh.Start()
    QQScheduleAwaitTimeout()
    if !IsObject(guiWin)
        BuildGui()
}

QQOnChar(ih, ch) {
    global qqQuery, qqAwaitKeyword, qqMarkCount
    if ch = "" || ch = "`b" || ch = "`r" || ch = "`n"
        return
    ; 问号只用于武装/取消，不进查询串（避免 ?? 重输时污染关键字）
    if QQIsQuestionChar(ch) {
        if qqAwaitKeyword || qqQuery = ""
            QQAbortSearch()
        return
    }
    ; ?? 后的前导空格/制表不触发搜索（?? wiki 里的空格应忽略；纯 ??+空格也不开搜）
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
    if vk = 27 {
        QQAbortSearch()
    }
}

QQOnQueryChanged(*) {
    global qqQuery
    ; 搜索框镜像到 WebView；磁盘过滤由前端 requestView(setView) 驱动（带当前 tab）
    QQPushQuery()
}

QQApplyQueryView(*) {
    global qqSearchOn, qqQuery, viewTab, viewToday
    if !qqSearchOn
        return
    SetView(viewTab, qqQuery, viewToday ? "1" : "0")
}

QQPushQuery(*) {
    global wvCore, qqQuery, qqSearchOn
    if !qqSearchOn || !IsObject(wvCore)
        return
    try wvCore.ExecuteScriptAsync("window.__setSearchQuery&&window.__setSearchQuery(" JsonStr(qqQuery) ")")
}

QQAttachUi(*) {
    global qqSearchOn, wvCore, prevActiveWin
    if !qqSearchOn
        return
    if !IsObject(wvCore) {
        SetTimer(QQAttachUi, -80)
        return
    }
    QQPushQuery()
    RestorePrevFocusQuietly()
}

QQStopSearch(resetFlag := true) {
    global qqIh, qqSearchOn, qqPending, qqNeedRelease, qqPanelPlaced, qqQuery
        , qqAwaitKeyword, qqMarkCount
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
        qqSearchOn := false
        qqPanelPlaced := false
        qqQuery := ""
    }
}

QQTypedEraseCount(*) {
    global qqSearchOn, qqQuery
    if !qqSearchOn
        return 0
    ; ?? / ？？ 各 2 字 + 关键字
    return 2 + StrLen(String(qqQuery))
}

QQEraseTypedInEditor(n) {
    n := Integer(n)
    if n < 1
        return
    Sleep 20
    Send("{BS " n "}")
    Sleep 20
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
        UI_CACHE_VER := "1"
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

; First paint: only push first 20 of「全部」; totals/prune run in background (no search index)
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
    ; Drop leftover right-click menu so next open is clean
    if IsObject(wvCore)
        try wvCore.ExecuteScriptAsync("window.__hideCtx&&window.__hideCtx()")
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
    global prevActiveWin, clipIgnore, uiPinned, pasteQueueMode
    ; Manual panel paste aborts active FIFO queue (keep original paste flow)
    if pasteQueueMode
        ExitPasteQueue("panel-paste")
    item := ResolveClip(uid)
    if !IsObject(item)
        return
    if StrLower(String(item.type)) = "recent" {
        path := item.HasProp("data") ? String(item.data) : String(item.preview)
        OpenFolderDir(path)
        return
    }

    eraseN := QQTypedEraseCount()
    ; 未固定：先藏面板再粘贴；固定：保持 UI，粘贴到原编辑光标处
    if !uiPinned
        HidePanel()

    clipIgnore := true
    try {
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
        if !ok && !PutItemOnClipboard(item)
            return
        MarkItemsPasted([item.uid])
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

PasteMany(idsStr, sepToken := "") {
    global prevActiveWin, clipIgnore, uiPinned, pasteQueueMode
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
            if !(it.type = "text" || it.type = "link") {
                allText := false
                break
            }
        }
        if allText {
            parts := []
            for it in items {
                EnsureClipBodyLoaded(it)
                parts.Push(it.HasProp("data") ? String(it.data) : "")
            }
            joined := JoinClipPartsWithSep(parts, sepTok)
            eraseN := QQTypedEraseCount()
            if !uiPinned
                HidePanel()
            clipIgnore := true
            try {
                A_Clipboard := joined
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
    if item.type = "text" || item.type = "link" {
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
    if item.type = "text" || item.type = "link"
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
    EnqueueDiskJob(DiskSetPasted.Bind(want, true))
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
    global clips, viewTab, viewQuery, viewToday, wvCore, viewCache
    uid := Integer(uid)
    title := Trim(String(title))
    if StrLen(title) > 80
        title := SubStr(title, 1, 80)
    found := false
    for c in clips {
        if c.uid = uid {
            c.favTitle := title
            found := true
            break
        }
    }
    if !found {
        it := ResolveClip(uid)
        if !IsObject(it)
            return
        it.favTitle := title
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
    DiskSetFavTitle(uid, title)
    ; Rebuild search hay so compact fav title ("gogettrans") is indexed
    global searchPools
    if IsObject(searchPools)
        searchPools := Map()
    if viewQuery != "" || viewTab = "pinned"
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
    global clips, liveFront, PAYLOAD_DIR, recentFolders
    uid := Integer(uid)
    if uid < 1
        return ""
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
    tab := SearchPoolTab(tab)
    key := SearchPoolKey(tab, todayOnly)
    if searchPools.Has(key)
        return searchPools[key]
    pool := { items: [], groups: Map() }
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
    ClipLog("EnsureSearchPool tab=" tab " n=" pool.items.Length)
    return pool
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
    ; Newest-first (page order): collect screenshot rows only
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
        , qqSearchOn, qqQuery, qqAwaitKeyword, viewSwitchGuardUntil, viewApplyGen, viewApplying
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
    global clips, viewTab, viewQuery, viewToday, viewTotal, VIEW_PAGE_SIZE, lastAppendCount, wvCore
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
SetTimer(WatchExplorerFolder, 700)
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

UpsertQueueMeta(uid, g, i) {
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
~*LButton:: {
    global ctrlMouseCopyUntil
    if GetKeyState("Ctrl", "P") && !GetKeyState("Shift", "P") && !GetKeyState("Alt", "P")
        ctrlMouseCopyUntil := A_TickCount + 1500
}

; Queue on: Ctrl+V = FIFO paste. Queue off: let OS / 快捷键4 handle Ctrl+V.
#HotIf PasteQueueModeActive()
$^v:: {
    global queueFifoPasteding, pasteSending, queueFifoPasteAt
    ; Only block while a paste is actually running (was 280ms after-start → ate next Ctrl+V)
    if queueFifoPasteding
        return
    ; Ignore keyboard auto-repeat only
    if (A_TickCount - queueFifoPasteAt) < 70
        return
    if pasteSending && (A_TickCount - queueFifoPasteAt) < 50
        return
    PasteQueueFifo()
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
        PasteQueueFifo(true)
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
        target := ResolvePasteTargetWin()
        if !target {
            try target := WinExist("A")
        }
        if target
            DllCall("SetForegroundWindow", "Ptr", target)
        ; Paste ASAP — mark/tip/save after (old order felt like dead Ctrl+V)
        if useLegacy && ShiftVLegacyTarget() {
            if WinActive("ahk_exe dbeaver.exe") || WinActive("ahk_exe datagrip64.exe")
                didLegacy := LegacyDbeaverShiftV()
            else if WinActive("ahk_exe goland64.exe")
                didLegacy := LegacyGolandShiftV()
        }
        if !didLegacy
            TriggerPasteKey()
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
    ; 未变更则跳过写入，避免 mtime 变了导致 WebView 每次冷加载 ~2s
    if FileExist(HTML_FILE) {
        try {
            existing := FileRead(HTML_FILE, "UTF-8")
            ver := UiCacheVer()
            if ver != "" && InStr(existing, 'data-ui-ver="' ver '"') {
                ClipLog("WriteHtmlFile SKIP unchanged ver=" ver)
                return
            }
        } catch {
        }
    }
    B64DecodeToFile(HTML_B64, HTML_FILE)
    ClipLog("WriteHtmlFile -> " HTML_FILE " ver=" UiCacheVer())
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

MakeRecentFolderItem(uid, path, time := "", pinned := false) {
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
        favTitle: "",
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
            recentFolders.Push(MakeRecentFolderItem(uid, path, time, pinned))
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
                out .= "{"
                out .= '"uid":' Integer(c.uid) ","
                out .= '"path":' JsonStr(path) ","
                out .= '"time":' JsonStr(c.HasProp("time") ? c.time : "") ","
                out .= '"pinned":' (IsRecentFolderPinned(c) ? "true" : "false")
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
    item := MakeRecentFolderItem(keptUid, path, "", keptPinned)
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

WatchExplorerFolder(*) {
    global lastExplorerFolder
    try {
        if !(WinActive("ahk_class CabinetWClass") || WinActive("ahk_class ExploreWClass"))
            return
        p := GetActiveFolderPath()
        if p = ""
            return
        p := NormalizeFolderPath(p)
        if p = "" || p = lastExplorerFolder
            return
        lastExplorerFolder := p
        RecordRecentFolder(p)
    }
}

QueryRecentFoldersPage(query, todayOnly, offset, limit) {
    global recentFolders
    ; 按访问时间顺序（newest first），固定项不置顶 — 只防淘汰
    all := []
    if IsObject(recentFolders) {
        for c in recentFolders {
            if !ItemMatchesView(c, "recent", query, todayOnly)
                continue
            all.Push(c)
        }
    }
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
