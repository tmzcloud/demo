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
UI_CACHE_VER := "20260916-dwm-border"
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
IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGp1c3RpZnktY29udGVudDogY2VudGVyOwogICAgICAgIH0K
ICAgICAgICAjdGl0bGUtZGxnLm9uIHsgZGlzcGxheTogZmxleDsgfQogICAgICAgICN0aXRsZS1k
bGcgLnRpdGxlLWJveCB7CiAgICAgICAgICAgIHdpZHRoOiAyNjBweDsgcGFkZGluZzogMTZweCAx
NnB4IDEycHg7CiAgICAgICAgICAgIGJhY2tncm91bmQ6IHZhcigtLWNhcmQpOyBib3JkZXItcmFk
aXVzOiAxMHB4OwogICAgICAgICAgICBib3gtc2hhZG93OiAwIDhweCAyOHB4IHJnYmEoMCwwLDAs
LjE4KTsKICAgICAgICB9CiAgICAgICAgI3RpdGxlLWlucHV0IHsKICAgICAgICAgICAgd2lkdGg6
IDEwMCU7IGJveC1zaXppbmc6IGJvcmRlci1ib3g7IG1hcmdpbjogOHB4IDAgMTJweDsKICAgICAg
ICAgICAgaGVpZ2h0OiAzMnB4OyBwYWRkaW5nOiAwIDEwcHg7IGJvcmRlci1yYWRpdXM6IDZweDsK
ICAgICAgICAgICAgYm9yZGVyOiAxcHggc29saWQgI2Q1ZGFlNjsgYmFja2dyb3VuZDogI2ZmZjsg
Y29sb3I6IHZhcigtLXR4dCk7CiAgICAgICAgICAgIGZvbnQtc2l6ZTogMTNweDsgb3V0bGluZTog
bm9uZTsKICAgICAgICB9CiAgICAgICAgI3RpdGxlLWlucHV0OmZvY3VzIHsgYm9yZGVyLWNvbG9y
OiB2YXIoLS1hY2MpOyB9CgogICAgCiAgICAgICAgLyogdWktZ3JheS1iZy12MSAqLwogICAgICAg
IDpyb290IHsKICAgICAgICAgICAgLS1iZzogI2U0ZTdlZSAhaW1wb3J0YW50OwogICAgICAgIH0K
ICAgICAgICBodG1sLCBib2R5IHsKICAgICAgICAgICAgYmFja2dyb3VuZDogI2U0ZTdlZSAhaW1w
b3J0YW50OwogICAgICAgIH0KICAgICAgICAjYXBwIHsKICAgICAgICAgICAgYmFja2dyb3VuZDog
bGluZWFyLWdyYWRpZW50KDE4MGRlZywgI2U5ZWNmMyAwJSwgI2UwZTRlYyAxMDAlKSAhaW1wb3J0
YW50OwogICAgICAgIH0KICAgICAgICAjaGRyIHsKICAgICAgICAgICAgYmFja2dyb3VuZDogI2Uy
ZTZlZSAhaW1wb3J0YW50OwogICAgICAgIH0KICAgICAgICAjdGFicyB7CiAgICAgICAgICAgIGJh
Y2tncm91bmQ6ICNlMmU2ZWUgIWltcG9ydGFudDsKICAgICAgICB9CiAgICAgICAgI2xpc3QsICNl
bXB0eSwgI3NrZWwsICNoZHItZ3JvdywgI3NlYXJjaC13cmFwIHsKICAgICAgICAgICAgYmFja2dy
b3VuZDogdHJhbnNwYXJlbnQgIWltcG9ydGFudDsKICAgICAgICB9CiAgICAgICAgI3NlYXJjaC1i
b3ggewogICAgICAgICAgICB0cmFuc2Zvcm0tb3JpZ2luOiByaWdodCBjZW50ZXI7CiAgICAgICAg
ICAgIGJhY2tncm91bmQ6IHRyYW5zcGFyZW50ICFpbXBvcnRhbnQ7CiAgICAgICAgfQogICAgICAg
IC5pdG0sIC5tZywgLm1nLXJvdywgLm1lcmdlLWdyb3VwIHsKICAgICAgICAgICAgYmFja2dyb3Vu
ZDogI2ZmZmZmZiAhaW1wb3J0YW50OwogICAgICAgIH0KICAgICAgICAuaXRtOmhvdmVyIHsKICAg
ICAgICAgICAgYmFja2dyb3VuZDogI2Y4ZjlmYyAhaW1wb3J0YW50OwogICAgICAgIH0KICAgIAog
ICAgICAgIC8qIHNlbC10aW50LWJsdWUtdjEgKi8KICAgICAgICAuaXRtLnNlbCwKICAgICAgICAu
bWctcm93LnNlbCwKICAgICAgICAuaXRtLm11bHRpLAogICAgICAgIC5tZy1yb3cubXVsdGksCiAg
ICAgICAgLml0bS5tdWx0aS5zZWwsCiAgICAgICAgLml0LWdyb3VwLnNlbCwKICAgICAgICAuaXQt
Z3JvdXAubXVsdGkgewogICAgICAgICAgICBiYWNrZ3JvdW5kOiAjZThlZmZmICFpbXBvcnRhbnQ7
CiAgICAgICAgfQogICAgICAgIC5pdG0uc2VsOmhvdmVyLAogICAgICAgIC5pdG0ubXVsdGk6aG92
ZXIsCiAgICAgICAgLm1nLXJvdy5zZWw6aG92ZXIsCiAgICAgICAgLm1nLXJvdy5tdWx0aTpob3Zl
ciB7CiAgICAgICAgICAgIGJhY2tncm91bmQ6ICNkZGU2ZmYgIWltcG9ydGFudDsKICAgICAgICB9
CiAgICAKICAgICAgICAvKiBob3Zlci1ncmVlbi1yaXNlLXYyICovCiAgICAgICAgLyogaG92ZXIt
YWNjZW50LXJpc2UtdjMgKi8KICAgICAgICAuaXRtIHsgcG9zaXRpb246IHJlbGF0aXZlICFpbXBv
cnRhbnQ7IG92ZXJmbG93OiBoaWRkZW4gIWltcG9ydGFudDsgfQogICAgICAgIC5pdG06OmJlZm9y
ZSB7CiAgICAgICAgICAgIGNvbnRlbnQ6ICIiICFpbXBvcnRhbnQ7CiAgICAgICAgICAgIHBvc2l0
aW9uOiBhYnNvbHV0ZSAhaW1wb3J0YW50OwogICAgICAgICAgICBsZWZ0OiAwICFpbXBvcnRhbnQ7
IHJpZ2h0OiAwICFpbXBvcnRhbnQ7IGJvdHRvbTogMCAhaW1wb3J0YW50OwogICAgICAgICAgICBo
ZWlnaHQ6IDAgIWltcG9ydGFudDsKICAgICAgICAgICAgcG9pbnRlci1ldmVudHM6IG5vbmUgIWlt
cG9ydGFudDsKICAgICAgICAgICAgei1pbmRleDogMCAhaW1wb3J0YW50OwogICAgICAgICAgICBi
b3JkZXItcmFkaXVzOiAwIDAgdmFyKC0tciwgNHB4KSB2YXIoLS1yLCA0cHgpICFpbXBvcnRhbnQ7
CiAgICAgICAgICAgIGJhY2tncm91bmQ6IGxpbmVhci1ncmFkaWVudCh0byB0b3AsCiAgICAgICAg
ICAgICAgICByZ2JhKDkxLCAxMTUsIDIzMiwgLjMyKSAwJSwKICAgICAgICAgICAgICAgIHJnYmEo
OTEsIDExNSwgMjMyLCAuMTIpIDU1JSwKICAgICAgICAgICAgICAgIHJnYmEoOTEsIDExNSwgMjMy
LCAwKSAxMDAlKSAhaW1wb3J0YW50OwogICAgICAgICAgICB0cmFuc2l0aW9uOiBoZWlnaHQgLjM0
cyBjdWJpYy1iZXppZXIoLjIyLCAxLCAuMzYsIDEpICFpbXBvcnRhbnQ7CiAgICAgICAgfQogICAg
ICAgIC5pdG06aG92ZXI6OmJlZm9yZSB7IGhlaWdodDogMzMuMzMzJSAhaW1wb3J0YW50OyB9CiAg
ICAgICAgLml0bTo6YWZ0ZXIgewogICAgICAgICAgICBjb250ZW50OiAiIiAhaW1wb3J0YW50Owog
ICAgICAgICAgICBwb3NpdGlvbjogYWJzb2x1dGUgIWltcG9ydGFudDsKICAgICAgICAgICAgbGVm
dDogMCAhaW1wb3J0YW50OyByaWdodDogMCAhaW1wb3J0YW50OyBib3R0b206IDAgIWltcG9ydGFu
dDsKICAgICAgICAgICAgaGVpZ2h0OiAycHggIWltcG9ydGFudDsKICAgICAgICAgICAgcG9pbnRl
ci1ldmVudHM6IG5vbmUgIWltcG9ydGFudDsKICAgICAgICAgICAgei1pbmRleDogMSAhaW1wb3J0
YW50OwogICAgICAgICAgICBiYWNrZ3JvdW5kOiByZ2JhKDkxLCAxMTUsIDIzMiwgLjkyKSAhaW1w
b3J0YW50OwogICAgICAgICAgICBib3JkZXItcmFkaXVzOiAxcHggIWltcG9ydGFudDsKICAgICAg
ICAgICAgdHJhbnNmb3JtOiBzY2FsZVgoMCkgIWltcG9ydGFudDsKICAgICAgICAgICAgdHJhbnNm
b3JtLW9yaWdpbjogY2VudGVyICFpbXBvcnRhbnQ7CiAgICAgICAgICAgIHRyYW5zaXRpb246IHRy
YW5zZm9ybSAuM3MgY3ViaWMtYmV6aWVyKC4yMiwgMSwgLjM2LCAxKSAhaW1wb3J0YW50OwogICAg
ICAgIH0KICAgICAgICAuaXRtOmhvdmVyOjphZnRlciB7CiAgICAgICAgICAgIHRyYW5zZm9ybTog
c2NhbGVYKDEpICFpbXBvcnRhbnQ7CiAgICAgICAgICAgIGJhY2tncm91bmQ6IHJnYmEoOTEsIDEx
NSwgMjMyLCAuOTUpICFpbXBvcnRhbnQ7CiAgICAgICAgfQogICAgICAgIC5pdG0gPiAqIHsgcG9z
aXRpb246IHJlbGF0aXZlOyB6LWluZGV4OiAyOyB9CiAgICAgICAgLyog6Z2i5p2/5pyA5aSW5reh
5rWF57u/57uG57q/77yb5p2h55uu5Y2h54mH6L275oKs5rWu5Y6a5bqmICovCiAgICAgICAgaHRt
bCwgYm9keSB7CiAgICAgICAgICAgIGJvcmRlcjogbm9uZSAhaW1wb3J0YW50OwogICAgICAgICAg
ICBvdXRsaW5lOiBub25lICFpbXBvcnRhbnQ7CiAgICAgICAgICAgIGJveC1zaGFkb3c6IG5vbmUg
IWltcG9ydGFudDsKICAgICAgICB9CiAgICAgICAgI2FwcCB7CiAgICAgICAgICAgIGJvcmRlcjog
MXB4IHNvbGlkIHJnYmEoMTY3LCAyNDMsIDIwOCwgMC43NSkgIWltcG9ydGFudDsgLyog5reh6JaE
6I2357u/ICovCiAgICAgICAgICAgIG91dGxpbmU6IG5vbmUgIWltcG9ydGFudDsKICAgICAgICAg
ICAgYm94LXNoYWRvdzogbm9uZSAhaW1wb3J0YW50OwogICAgICAgICAgICBib3JkZXItcmFkaXVz
OiAwICFpbXBvcnRhbnQ7CiAgICAgICAgICAgIGJveC1zaXppbmc6IGJvcmRlci1ib3ggIWltcG9y
dGFudDsKICAgICAgICAgICAgb3ZlcmZsb3c6IGhpZGRlbiAhaW1wb3J0YW50OwogICAgICAgIH0K
ICAgICAgICAuaXRtLCAubWcsIC5tZXJnZS1ncm91cCB7CiAgICAgICAgICAgIGJvcmRlcjogbm9u
ZSAhaW1wb3J0YW50OwogICAgICAgICAgICBib3JkZXItcmFkaXVzOiA0cHggIWltcG9ydGFudDsK
ICAgICAgICAgICAgYm94LXNoYWRvdzoKICAgICAgICAgICAgICAgIDAgMXB4IDJweCByZ2JhKDI0
LCAzMiwgNTYsIC4wNSksCiAgICAgICAgICAgICAgICAwIDNweCAxMHB4IHJnYmEoMjQsIDMyLCA1
NiwgLjA5KSAhaW1wb3J0YW50OwogICAgICAgIH0KICAgICAgICAuaXRtOmhvdmVyLCAubWc6aG92
ZXIsIC5tZXJnZS1ncm91cDpob3ZlciB7CiAgICAgICAgICAgIGJveC1zaGFkb3c6CiAgICAgICAg
ICAgICAgICAwIDJweCA0cHggcmdiYSgyNCwgMzIsIDU2LCAuMDcpLAogICAgICAgICAgICAgICAg
MCA2cHggMTZweCByZ2JhKDI0LCAzMiwgNTYsIC4xMykgIWltcG9ydGFudDsKICAgICAgICB9CiAg
ICAgICAgLml0bS5zZWwsCiAgICAgICAgLm1nLXJvdy5zZWwsCiAgICAgICAgLml0bS5tdWx0aSwK
ICAgICAgICAubWctcm93Lm11bHRpLAogICAgICAgIC5pdG0ubXVsdGkuc2VsLAogICAgICAgIC5p
dC1ncm91cC5zZWwsCiAgICAgICAgLml0LWdyb3VwLm11bHRpIHsKICAgICAgICAgICAgYm94LXNo
YWRvdzoKICAgICAgICAgICAgICAgIDAgMCAwIDJweCByZ2JhKDkxLCAxMTUsIDIzMiwgLjQyKSwK
ICAgICAgICAgICAgICAgIDAgMnB4IDRweCByZ2JhKDkxLCAxMTUsIDIzMiwgLjEwKSwKICAgICAg
ICAgICAgICAgIDAgNnB4IDE0cHggcmdiYSg5MSwgMTE1LCAyMzIsIC4xNikgIWltcG9ydGFudDsK
ICAgICAgICB9CiAgICA8L3N0eWxlPgo8L2hlYWQ+Cjxib2R5IGRhdGEtdWktYnVpbGQ9IjIwMjYw
OTE2LW1pbnQtYm9yZGVyIj4KPGRpdiBpZD0iYXBwIiBkYXRhLXVpLXZlcj0iMjAyNjA5MTYtbWlu
dC1ib3JkZXIiPgogICAgPGRpdiBpZD0iaGRyIj4KICAgICAgICA8ZGl2IGlkPSJoZWFydCI+CiAg
ICAgICAgICAgIDxzdmcgdmlld0JveD0iMCAwIDI0IDI0IiBmaWxsPSJub25lIiBzdHJva2U9ImN1
cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIxLjgiCiAgICAgICAgICAgICAgICAgc3Ryb2tlLWxp
bmVjYXA9InJvdW5kIiBzdHJva2UtbGluZWpvaW49InJvdW5kIj4KICAgICAgICAgICAgICAgIDxy
ZWN0IHg9IjkiIHk9IjIiIHdpZHRoPSI2IiBoZWlnaHQ9IjQiIHJ4PSIxIi8+CiAgICAgICAgICAg
ICAgICA8cGF0aCBkPSJNMTYgNGgyYTIgMiAwIDAgMSAyIDJ2MTRhMiAyIDAgMCAxLTIgMkg2YTIg
MiAwIDAgMS0yLTJWNmEyIDIgMCAwIDEgMi0yaDIiLz4KICAgICAgICAgICAgICAgIDxwYXRoIGQ9
Ik05IDEyaDZNOSAxNmg0Ii8+CiAgICAgICAgICAgIDwvc3ZnPgogICAgICAgIDwvZGl2PgogICAg
ICAgIDxkaXYgaWQ9Imhkci1ncm93Ij48L2Rpdj4KICAgICAgICA8ZGl2IGlkPSJtdWx0aS1iYXIi
PgogICAgICAgICAgICA8YnV0dG9uIGlkPSJtdWx0aS1zZWwiIHR5cGU9ImJ1dHRvbiIgdGl0bGU9
IuWPlua2iOWkmumAiSI+CiAgICAgICAgICAgICAgICA8c3BhbiBpZD0ibXVsdGktc2VsLWxhYiI+
5bey6YCJPC9zcGFuPgogICAgICAgICAgICAgICAgPHNwYW4gaWQ9Im11bHRpLWNudCI+MDwvc3Bh
bj4KICAgICAgICAgICAgPC9idXR0b24+CiAgICAgICAgICAgIDxkaXYgaWQ9InBhc3RlLXNlcC13
cmFwIj4KICAgICAgICAgICAgICAgIDxidXR0b24gaWQ9InBhc3RlLXNlcC1idG4iIHR5cGU9ImJ1
dHRvbiIgdGl0bGU9IueymOi0tOWIhumalOespu+8iOeCuemAieeUqOW5tueymOi0tO+8iSI+CiAg
ICAgICAgICAgICAgICAgICAgPHNwYW4gaWQ9InBhc3RlLXNlcC1sYWJlbCI+4pCjPC9zcGFuPgog
ICAgICAgICAgICAgICAgPC9idXR0b24+CiAgICAgICAgICAgICAgICA8ZGl2IGlkPSJwYXN0ZS1z
ZXAtbWVudSI+PC9kaXY+CiAgICAgICAgICAgIDwvZGl2PgogICAgICAgIDwvZGl2PgogICAgICAg
IDxidXR0b24gaWQ9ImJ0bi1sb2NhdGUiIHR5cGU9ImJ1dHRvbiIgdGl0bGU9IuWumuS9jeWIsOS4
iuasoeS9v+eUqOeahOadoeebriIgZGlzYWJsZWQ+CiAgICAgICAgICAgIDxzdmcgdmlld0JveD0i
MCAwIDI0IDI0IiBmaWxsPSJub25lIiBzdHJva2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRo
PSIyIgogICAgICAgICAgICAgICAgIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIgc3Ryb2tlLWxpbmVq
b2luPSJyb3VuZCI+CiAgICAgICAgICAgICAgICA8Y2lyY2xlIGN4PSIxMiIgY3k9IjEyIiByPSI4
Ii8+CiAgICAgICAgICAgICAgICA8Y2lyY2xlIGN4PSIxMiIgY3k9IjEyIiByPSIzLjUiLz4KICAg
ICAgICAgICAgPC9zdmc+CiAgICAgICAgPC9idXR0b24+CiAgICAgICAgPGRpdiBpZD0ic2VhcmNo
LXdyYXAiPgogICAgICAgICAgICA8YnV0dG9uIGlkPSJidG4tc2VhcmNoIiB0eXBlPSJidXR0b24i
IHRpdGxlPSLmkJzntKIiPgogICAgICAgICAgICAgICAgPHN2ZyB2aWV3Qm94PSIwIDAgMjQgMjQi
IGZpbGw9Im5vbmUiIHN0cm9rZT0iY3VycmVudENvbG9yIiBzdHJva2Utd2lkdGg9IjIiCiAgICAg
ICAgICAgICAgICAgICAgIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIgc3Ryb2tlLWxpbmVqb2luPSJy
b3VuZCI+CiAgICAgICAgICAgICAgICAgICAgPGNpcmNsZSBjeD0iMTEiIGN5PSIxMSIgcj0iNyIv
PgogICAgICAgICAgICAgICAgICAgIDxwYXRoIGQ9Ik0yMCAyMGwtMy41LTMuNSIvPgogICAgICAg
ICAgICAgICAgPC9zdmc+CiAgICAgICAgICAgIDwvYnV0dG9uPgogICAgICAgICAgICA8ZGl2IGlk
PSJzZWFyY2gtYm94Ij4KICAgICAgICAgICAgICAgIDxidXR0b24gaWQ9ImJ0bi10b2RheSIgdHlw
ZT0iYnV0dG9uIj7lvZPlpKk8L2J1dHRvbj4KICAgICAgICAgICAgICAgIDxpbnB1dCBpZD0ic2Vh
cmNoIiB0eXBlPSJ0ZXh0IiBwbGFjZWhvbGRlcj0i5pCc57Si4oCmIOepuuagvOWIhuivjemhu+WQ
jOaXtuWMheWQqyDCtyBhfGIg5YiG5q61IiBhdXRvY29tcGxldGU9Im9mZiIgc3BlbGxjaGVjaz0i
ZmFsc2UiPgogICAgICAgICAgICAgICAgPGJ1dHRvbiBpZD0ic2VhcmNoLWNsciIgdHlwZT0iYnV0
dG9uIj7inJU8L2J1dHRvbj4KICAgICAgICAgICAgPC9kaXY+CiAgICAgICAgPC9kaXY+CiAgICAg
ICAgPGJ1dHRvbiBpZD0iYnRuLXBpbiIgdHlwZT0iYnV0dG9uIiB0aXRsZT0i6ZKJ5Zyo5bGP5bmV
5LiKIj4KICAgICAgICAgICAgPHN2ZyB2aWV3Qm94PSIwIDAgMjQgMjQiIGZpbGw9Im5vbmUiIHN0
cm9rZT0iY3VycmVudENvbG9yIiBzdHJva2Utd2lkdGg9IjIiCiAgICAgICAgICAgICAgICAgc3Ry
b2tlLWxpbmVqb2luPSJyb3VuZCIgc3Ryb2tlLWxpbmVjYXA9InJvdW5kIj4KICAgICAgICAgICAg
ICAgIDxsaW5lIHgxPSIxMiIgeTE9IjE3IiB4Mj0iMTIiIHkyPSIyMiIvPgogICAgICAgICAgICAg
ICAgPHBhdGggZD0iTTUgMTdoMTR2LTEuNzZhMiAyIDAgMCAwLTEuMTEtMS43OWwtMS43OC0uOUEy
IDIgMCAwIDEgMTUgMTAuNzZWNmgxYTIgMiAwIDAgMCAwLTRIOGEyIDIgMCAwIDAgMCA0aDF2NC43
NmEyIDIgMCAwIDEtMS4xMSAxLjc5bC0xLjc4LjlBMiAyIDAgMCAwIDUgMTUuMjRaIi8+CiAgICAg
ICAgICAgIDwvc3ZnPgogICAgICAgIDwvYnV0dG9uPgogICAgPC9kaXY+CgogICAgPGRpdiBpZD0i
dGFicyI+CiAgICAgICAgPGRpdiBpZD0idGFiLWluayIgYXJpYS1oaWRkZW49InRydWUiPjwvZGl2
PgogICAgICAgIDxkaXYgY2xhc3M9InRhYiBvbiIgZGF0YS10YWI9ImFsbCI+5YWo6YOoPC9kaXY+
CiAgICAgICAgPGRpdiBjbGFzcz0idGFiIiBkYXRhLXRhYj0idGV4dCI+5paH5pysPC9kaXY+CiAg
ICAgICAgPGRpdiBjbGFzcz0idGFiIiBkYXRhLXRhYj0iaW1hZ2UiPuWbvuWDjzwvZGl2PgogICAg
ICAgIDxkaXYgY2xhc3M9InRhYiIgZGF0YS10YWI9ImZpbGUiPuaWh+S7tjwvZGl2PgogICAgICAg
IDxkaXYgY2xhc3M9InRhYiIgZGF0YS10YWI9InJlY2VudCI+5pyA6L+RPC9kaXY+CiAgICAgICAg
PGRpdiBjbGFzcz0idGFiIiBkYXRhLXRhYj0icGlubmVkIj7mlLbol48gPHNwYW4gaWQ9InBpbi1k
b3QiIHRpdGxlPSLmnInmlrDmlLbol48iPjwvc3Bhbj48L2Rpdj4KICAgICAgICA8ZGl2IGlkPSJ0
YWItYWN0aW9ucyI+CiAgICAgICAgICAgIDxzcGFuIGlkPSJiYXItdHh0Ij4wPC9zcGFuPgogICAg
ICAgICAgICA8YnV0dG9uIGlkPSJidG4tY2xyIiB0eXBlPSJidXR0b24iIHRpdGxlPSLmuIXnqbrl
joblj7IiPgogICAgICAgICAgICAgICAgPHN2ZyB2aWV3Qm94PSIwIDAgMjQgMjQiIGZpbGw9Im5v
bmUiIHN0cm9rZT0iY3VycmVudENvbG9yIiBzdHJva2Utd2lkdGg9IjIiCiAgICAgICAgICAgICAg
ICAgICAgIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIgc3Ryb2tlLWxpbmVqb2luPSJyb3VuZCI+CiAg
ICAgICAgICAgICAgICAgICAgPHBvbHlsaW5lIHBvaW50cz0iMyA2IDUgNiAyMSA2Ii8+CiAgICAg
ICAgICAgICAgICAgICAgPHBhdGggZD0iTTE5IDZsLTEgMTRhMiAyIDAgMCAxLTIgMkg4YTIgMiAw
IDAgMS0yLTJMNSA2Ii8+CiAgICAgICAgICAgICAgICAgICAgPHBhdGggZD0iTTEwIDExdjZNMTQg
MTF2Nk05IDZWNGg2djIiLz4KICAgICAgICAgICAgICAgIDwvc3ZnPgogICAgICAgICAgICA8L2J1
dHRvbj4KICAgICAgICA8L2Rpdj4KICAgIDwvZGl2PgoKICAgIDxkaXYgaWQ9Imxpc3QiPgogICAg
ICAgIDxkaXYgaWQ9InNrZWwiIGFyaWEtaGlkZGVuPSJ0cnVlIj4KICAgICAgICAgICAgPGRpdiBj
bGFzcz0ic2stcm93Ij48ZGl2IGNsYXNzPSJzay1pY28iPjwvZGl2PjxkaXYgY2xhc3M9InNrLWJv
ZHkiPjxkaXYgY2xhc3M9InNrLWxpbmUgbWlkIj48L2Rpdj48ZGl2IGNsYXNzPSJzay1saW5lIHNo
b3J0Ij48L2Rpdj48L2Rpdj48L2Rpdj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0ic2stcm93Ij48
ZGl2IGNsYXNzPSJzay1pY28iPjwvZGl2PjxkaXYgY2xhc3M9InNrLWJvZHkiPjxkaXYgY2xhc3M9
InNrLWxpbmUiPjwvZGl2PjxkaXYgY2xhc3M9InNrLWxpbmUgbWlkIj48L2Rpdj48L2Rpdj48L2Rp
dj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0ic2stcm93Ij48ZGl2IGNsYXNzPSJzay1pY28iPjwv
ZGl2PjxkaXYgY2xhc3M9InNrLWJvZHkiPjxkaXYgY2xhc3M9InNrLWxpbmUgbWlkIj48L2Rpdj48
ZGl2IGNsYXNzPSJzay1saW5lIHNob3J0Ij48L2Rpdj48L2Rpdj48L2Rpdj4KICAgICAgICAgICAg
PGRpdiBjbGFzcz0ic2stcm93Ij48ZGl2IGNsYXNzPSJzay1pY28iPjwvZGl2PjxkaXYgY2xhc3M9
InNrLWJvZHkiPjxkaXYgY2xhc3M9InNrLWxpbmUiPjwvZGl2PjxkaXYgY2xhc3M9InNrLWxpbmUg
bWlkIj48L2Rpdj48L2Rpdj48L2Rpdj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0ic2stcm93Ij48
ZGl2IGNsYXNzPSJzay1pY28iPjwvZGl2PjxkaXYgY2xhc3M9InNrLWJvZHkiPjxkaXYgY2xhc3M9
InNrLWxpbmUgbWlkIj48L2Rpdj48ZGl2IGNsYXNzPSJzay1saW5lIHNob3J0Ij48L2Rpdj48L2Rp
dj48L2Rpdj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0ic2stcm93Ij48ZGl2IGNsYXNzPSJzay1p
Y28iPjwvZGl2PjxkaXYgY2xhc3M9InNrLWJvZHkiPjxkaXYgY2xhc3M9InNrLWxpbmUiPjwvZGl2
PjxkaXYgY2xhc3M9InNrLWxpbmUgc2hvcnQiPjwvZGl2PjwvZGl2PjwvZGl2PgogICAgICAgIDwv
ZGl2PgogICAgICAgIDxkaXYgaWQ9ImVtcHR5Ij4KICAgICAgICAgICAgPGRpdiBjbGFzcz0iZS10
eHQiIGlkPSJlbXB0eS10eHQiPuaaguaXoOiusOW9le+8jOWkjeWItuWQjuiHquWKqOWHuueOsDwv
ZGl2PgogICAgICAgIDwvZGl2PgogICAgPC9kaXY+CiAgICA8YnV0dG9uIGlkPSJidG4tdG9wIiB0
eXBlPSJidXR0b24iIHRpdGxlPSLlm57liLDpobbpg6giIGFyaWEtbGFiZWw9IuWbnuWIsOmhtumD
qCI+CiAgICAgICAgPHN2ZyB2aWV3Qm94PSIwIDAgMjQgMjQiIGZpbGw9Im5vbmUiIHN0cm9rZT0i
Y3VycmVudENvbG9yIiBzdHJva2Utd2lkdGg9IjIuMiIKICAgICAgICAgICAgIHN0cm9rZS1saW5l
Y2FwPSJyb3VuZCIgc3Ryb2tlLWxpbmVqb2luPSJyb3VuZCI+CiAgICAgICAgICAgIDxwYXRoIGQ9
Ik0xMiAxOVY1Ii8+CiAgICAgICAgICAgIDxwYXRoIGQ9Ik01IDEybDctNyA3IDciLz4KICAgICAg
ICA8L3N2Zz4KICAgIDwvYnV0dG9uPgo8L2Rpdj4KCjxkaXYgaWQ9ImN0eCI+CiAgICA8ZGl2IGNs
YXNzPSJjLWl0ZW0iIGlkPSJjLWNvcHkiPjxzcGFuIGNsYXNzPSJjLWljbyI+4o6YPC9zcGFuPuWk
jeWItjwvZGl2PgogICAgPGRpdiBjbGFzcz0iYy1pdGVtIiBpZD0iYy1wYXN0ZSI+PHNwYW4gY2xh
c3M9ImMtaWNvIj7ij448L3NwYW4+57KY6LS0PC9kaXY+CiAgICA8ZGl2IGNsYXNzPSJjLXNlcCIg
aWQ9ImMtZGF0YS1zZXAiIHN0eWxlPSJkaXNwbGF5Om5vbmUiPjwvZGl2PgogICAgPGRpdiBjbGFz
cz0iYy1zdWJ3cmFwIiBpZD0iYy1kYXRhLXdyYXAiIHN0eWxlPSJkaXNwbGF5Om5vbmUiPgogICAg
ICAgIDxkaXYgY2xhc3M9ImMtaXRlbSIgaWQ9ImMtZGF0YSI+PHNwYW4gY2xhc3M9ImMtaWNvIj7O
ozwvc3Bhbj7mlbDmja7lpITnkIY8c3BhbiBjbGFzcz0iYy1jYXJldCI+4oC6PC9zcGFuPjwvZGl2
PgogICAgICAgIDxkaXYgY2xhc3M9ImMtc3ViIiBpZD0iYy1kYXRhLXN1YiI+CiAgICAgICAgICAg
IDxkaXYgY2xhc3M9ImMtaXRlbSIgaWQ9ImMtZGF0YS1icmFjZSIgdGl0bGU9InthLGJ9IC8gYSxi
IOKGkiBTUUwiPgogICAgICAgICAgICAgICAgPHNwYW4gY2xhc3M9ImMtbnVtIj4xPC9zcGFuPjxz
cGFuIGNsYXNzPSJjLWZyb20iPnthLGJ9PC9zcGFuPjxzcGFuIGNsYXNzPSJjLWFycm93Ij7ihpI8
L3NwYW4+PHNwYW4gY2xhc3M9ImMtdG8iPignYScsJ2InKTwvc3Bhbj4KICAgICAgICAgICAgPC9k
aXY+CiAgICAgICAgICAgIDxkaXYgY2xhc3M9ImMtaXRlbSIgaWQ9ImMtZGF0YS1saW5lcyIgdGl0
bGU9IuaNouihjOWIhumalCDihpIgU1FMIj4KICAgICAgICAgICAgICAgIDxzcGFuIGNsYXNzPSJj
LW51bSI+Mjwvc3Bhbj48c3BhbiBjbGFzcz0iYy1mcm9tIj5hIFxuIGI8L3NwYW4+PHNwYW4gY2xh
c3M9ImMtYXJyb3ciPuKGkjwvc3Bhbj48c3BhbiBjbGFzcz0iYy10byI+KCdhJywnYicpPC9zcGFu
PgogICAgICAgICAgICA8L2Rpdj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0iYy1pdGVtIiBpZD0i
Yy1kYXRhLWpzb24iIHRpdGxlPSJKU09OIOWOu+i9rOS5ie+8mlwmcXVvdDsg4oaSICZxdW90OyI+
CiAgICAgICAgICAgICAgICA8c3BhbiBjbGFzcz0iYy1udW0iPjM8L3NwYW4+PHNwYW4gY2xhc3M9
ImMtZnJvbSI+anNvbiAgJnF1b3Q7XCZxdW90Ozwvc3Bhbj48c3BhbiBjbGFzcz0iYy1hcnJvdyI+
4oaSPC9zcGFuPjxzcGFuIGNsYXNzPSJjLXRvIj4mcXVvdDsgJnF1b3Q7PC9zcGFuPgogICAgICAg
ICAgICA8L2Rpdj4KICAgICAgICA8L2Rpdj4KICAgIDwvZGl2PgogICAgPGRpdiBjbGFzcz0iYy1z
ZXAiPjwvZGl2PgogICAgPGRpdiBjbGFzcz0iYy1pdGVtIiBpZD0iYy1waW4iPjxzcGFuIGNsYXNz
PSJjLWljbyI+4piFPC9zcGFuPuaUtuiXjzwvZGl2PgogICAgPGRpdiBjbGFzcz0iYy1pdGVtIiBp
ZD0iYy10aXRsZSIgc3R5bGU9ImRpc3BsYXk6bm9uZSI+PHNwYW4gY2xhc3M9ImMtaWNvIj7inI48
L3NwYW4+6K6+572u5qCH6aKYPC9kaXY+CiAgICA8ZGl2IGNsYXNzPSJjLWl0ZW0iIGlkPSJjLW1l
cmdlIiBzdHlsZT0iZGlzcGxheTpub25lIj48c3BhbiBjbGFzcz0iYy1pY28iPuKniTwvc3Bhbj7l
kIjlubY8L2Rpdj4KICAgIDxkaXYgY2xhc3M9ImMtaXRlbSIgaWQ9ImMtdW5tZXJnZSIgc3R5bGU9
ImRpc3BsYXk6bm9uZSI+PHNwYW4gY2xhc3M9ImMtaWNvIj7ih4Q8L3NwYW4+5Y+W5raI5ZCI5bm2
PC9kaXY+CiAgICA8ZGl2IGNsYXNzPSJjLWl0ZW0iIGlkPSJjLXRvcCI+PHNwYW4gY2xhc3M9ImMt
aWNvIj7ihpE8L3NwYW4+56e75Yiw6aG26YOoPC9kaXY+CiAgICA8ZGl2IGNsYXNzPSJjLWl0ZW0i
IGlkPSJjLWNsZWFyLXBhc3RlZCIgc3R5bGU9ImRpc3BsYXk6bm9uZSI+PHNwYW4gY2xhc3M9ImMt
aWNvIj7inJM8L3NwYW4+5riF6Zmk54q25oCBPC9kaXY+CiAgICA8ZGl2IGNsYXNzPSJjLWl0ZW0i
IGlkPSJjLXF1ZXVlLWZyb20iIHN0eWxlPSJkaXNwbGF5Om5vbmUiPjxzcGFuIGNsYXNzPSJjLWlj
byI+4oa7PC9zcGFuPuS7juatpOWkhOW8gOWni+mYn+WIlzwvZGl2PgogICAgPGRpdiBjbGFzcz0i
Yy1zZXAiPjwvZGl2PgogICAgPGRpdiBjbGFzcz0iYy1pdGVtIGRhbmdlciIgaWQ9ImMtZGVsIj48
c3BhbiBjbGFzcz0iYy1pY28iPuKclTwvc3Bhbj7liKDpmaQ8L2Rpdj4KPC9kaXY+Cgo8ZGl2IGlk
PSJjbHItZGxnIj4KICAgIDxkaXYgY2xhc3M9ImNsci1ib3giIHJvbGU9ImRpYWxvZyIgYXJpYS1t
b2RhbD0idHJ1ZSI+CiAgICAgICAgPGRpdiBjbGFzcz0iY2xyLXRpdGxlIiBpZD0iY2xyLXRpdGxl
Ij7noa7orqTmuIXnqbrvvJ88L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJjbHItZGVzYyIgaWQ9
ImNsci1kZXNjIj7pu5jorqTku4XmuIXnqbrlvZPlpKnlhoXlrrnjgII8L2Rpdj4KICAgICAgICA8
bGFiZWwgY2xhc3M9ImNsci1jaGVjayIgZm9yPSJjbHItYWxsIj4KICAgICAgICAgICAgPGlucHV0
IHR5cGU9ImNoZWNrYm94IiBpZD0iY2xyLWFsbCI+CiAgICAgICAgICAgIDxzcGFuPua4heepuuaJ
gOaciTwvc3Bhbj4KICAgICAgICA8L2xhYmVsPgogICAgICAgIDxkaXYgY2xhc3M9ImNsci1idG5z
Ij4KICAgICAgICAgICAgPGJ1dHRvbiB0eXBlPSJidXR0b24iIGlkPSJjbHItY2FuY2VsIj7lj5bm
tog8L2J1dHRvbj4KICAgICAgICAgICAgPGJ1dHRvbiB0eXBlPSJidXR0b24iIGlkPSJjbHItb2si
Pua4heepujwvYnV0dG9uPgogICAgICAgIDwvZGl2PgogICAgPC9kaXY+CjwvZGl2PgoKPGRpdiBp
ZD0idGl0bGUtZGxnIj4KICAgIDxkaXYgY2xhc3M9InRpdGxlLWJveCIgcm9sZT0iZGlhbG9nIiBh
cmlhLW1vZGFsPSJ0cnVlIj4KICAgICAgICA8ZGl2IGNsYXNzPSJjbHItdGl0bGUiPuiuvue9ruag
h+mimDwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9ImNsci1kZXNjIj7moIfpopjlj6/ooqvmkJzn
tKLmib7liLDvvIzku4XnlKjkuo7mlLbol4/mlbTnkIbjgII8L2Rpdj4KICAgICAgICA8aW5wdXQg
aWQ9InRpdGxlLWlucHV0IiB0eXBlPSJ0ZXh0IiBtYXhsZW5ndGg9IjgwIiBwbGFjZWhvbGRlcj0i
57uZ6L+Z5p2h5pS26JeP6LW35Liq5ZCN5a2X4oCmIiBhdXRvY29tcGxldGU9Im9mZiIgc3BlbGxj
aGVjaz0iZmFsc2UiPgogICAgICAgIDxkaXYgY2xhc3M9ImNsci1idG5zIj4KICAgICAgICAgICAg
PGJ1dHRvbiB0eXBlPSJidXR0b24iIGlkPSJ0aXRsZS1jYW5jZWwiPuWPlua2iDwvYnV0dG9uPgog
ICAgICAgICAgICA8YnV0dG9uIHR5cGU9ImJ1dHRvbiIgaWQ9InRpdGxlLW9rIj7kv53lrZg8L2J1
dHRvbj4KICAgICAgICA8L2Rpdj4KICAgIDwvZGl2Pgo8L2Rpdj4KPGRpdiBpZD0icGF0aC10aXAi
IGFyaWEtaGlkZGVuPSJ0cnVlIj48L2Rpdj4KCjxzY3JpcHQ+Ci8qIOemgeatoiBDdHJsK+a7mui9
rue8qeaUvu+8iFdlYlZpZXcg6K6+572uICsg6aG16Z2i5YWc5bqV77yJICovCihmdW5jdGlvbigp
ewogIGNvbnN0IGJsb2NrWm9vbSA9IGUgPT4gewogICAgaWYgKGUuY3RybEtleSB8fCBlLm1ldGFL
ZXkpIHsKICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOwogICAgICBlLnN0b3BQcm9wYWdhdGlvbigp
OwogICAgfQogIH07CiAgd2luZG93LmFkZEV2ZW50TGlzdGVuZXIoJ3doZWVsJywgYmxvY2tab29t
LCB7IHBhc3NpdmU6IGZhbHNlLCBjYXB0dXJlOiB0cnVlIH0pOwogIHdpbmRvdy5hZGRFdmVudExp
c3RlbmVyKCdnZXN0dXJlc3RhcnQnLCBlID0+IGUucHJldmVudERlZmF1bHQoKSwgeyBwYXNzaXZl
OiBmYWxzZSwgY2FwdHVyZTogdHJ1ZSB9KTsKICBkb2N1bWVudC5hZGRFdmVudExpc3RlbmVyKCdr
ZXlkb3duJywgZSA9PiB7CiAgICBpZiAoIShlLmN0cmxLZXkgfHwgZS5tZXRhS2V5KSkgcmV0dXJu
OwogICAgaWYgKGUua2V5ID09PSAnKycgfHwgZS5rZXkgPT09ICctJyB8fCBlLmtleSA9PT0gJz0n
IHx8IGUua2V5ID09PSAnXycKICAgICAgICB8fCBlLmNvZGUgPT09ICdOdW1wYWRBZGQnIHx8IGUu
Y29kZSA9PT0gJ051bXBhZFN1YnRyYWN0JwogICAgICAgIHx8IGUua2V5ID09PSAnMCcpIHsKICAg
ICAgLy8gYWxsb3cgbm90aGluZyBmb3Igem9vbTsgQ3RybCswIC8gwrEKICAgICAgaWYgKGUua2V5
ID09PSAnMCcgfHwgZS5rZXkgPT09ICcrJyB8fCBlLmtleSA9PT0gJy0nIHx8IGUua2V5ID09PSAn
PScgfHwgZS5rZXkgPT09ICdfJwogICAgICAgICAgfHwgZS5jb2RlID09PSAnTnVtcGFkQWRkJyB8
fCBlLmNvZGUgPT09ICdOdW1wYWRTdWJ0cmFjdCcpIHsKICAgICAgICBlLnByZXZlbnREZWZhdWx0
KCk7CiAgICAgIH0KICAgIH0KICB9LCB0cnVlKTsKfSkoKTsKPC9zY3JpcHQ+CjxzY3JpcHQ+Ci8q
IHNrZWwtZmFpbHNhZmU6IG9ubHkgaWYgbWFpbiBVSSBzY3JpcHQgbmV2ZXIgYm9vdGVkIOKAlG5l
dmVyIGludmVudCBlbXB0eS1zdGF0ZSAqLwooZnVuY3Rpb24oKXsKICBzZXRUaW1lb3V0KCgpID0+
IHsKICAgIHRyeSB7CiAgICAgIGlmICh3aW5kb3cuX191aUJvb3RlZCkgcmV0dXJuOwogICAgICB2
YXIgYXBwID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2FwcCcpOwogICAgICBpZiAoYXBwKSBh
cHAuY2xhc3NMaXN0LnJlbW92ZSgnYm9vdC1sb2FkaW5nJyk7CiAgICAgIHZhciBzID0gZG9jdW1l
bnQuZ2V0RWxlbWVudEJ5SWQoJ3NrZWwnKTsKICAgICAgaWYgKHMpIHMuY2xhc3NMaXN0LnJlbW92
ZSgnb24nKTsKICAgIH0gY2F0Y2ggKGVycikge30KICB9LCAzMDAwKTsKfSkoKTsKPC9zY3JpcHQ+
CjxzY3JpcHQ+CiAgICBsZXQgYWxsQ2xpcHMgPSBbXSwgY3VyVGFiID0gJ2FsbCcsIHF1ZXJ5ID0g
JycsIGN0eENsaXAgPSBudWxsLCBzZWxlY3RlZElkID0gMCwgcGlubmVkVUkgPSBmYWxzZTsKICAg
IGNvbnN0IFRBQl9PUkRFUiA9IFsnYWxsJywgJ3RleHQnLCAnaW1hZ2UnLCAnZmlsZScsICdyZWNl
bnQnLCAncGlubmVkJ107CiAgICBjb25zdCB2aWV3TWVtID0gbmV3IE1hcCgpOwogICAgZnVuY3Rp
b24gdmlld01lbUtleSh0YWIsIHEsIHRvZGF5KSB7CiAgICAgICAgcmV0dXJuIFN0cmluZyh0YWIg
fHwgJ2FsbCcpICsgJ1x0JyArIFN0cmluZyhxIHx8ICcnKSArICdcdCcgKyAodG9kYXkgPyAnMScg
OiAnMCcpOwogICAgfQogICAgbGV0IHRhYlN3aXRjaEFuaW1EaXIgPSAwOwogICAgbGV0IG11bHRp
SWRzID0gW107CiAgICBsZXQgdG9kYXlPbmx5ID0gZmFsc2U7CiAgICBsZXQgZGlza1RvdGFsID0g
MDsKICAgIGxldCBsb2FkaW5nTW9yZSA9IGZhbHNlOwogICAgLy8gRG9uJ3Qgc2hvdyBza2VsZXRv
biBpbW1lZGlhdGVseSDigJRvbmx5IGFmdGVyIFNLRUxfREVMQVlfTVMgaWYgZGF0YSBzdGlsbCBt
aXNzaW5nCiAgICBsZXQgYm9vdExvYWRpbmcgPSBmYWxzZTsKICAgIGxldCB3YWl0aW5nRGF0YSA9
IGZhbHNlOwogICAgbGV0IGhvc3RQdXNoZWRPbmNlID0gZmFsc2U7IC8vIG9ubHkgdGhlbiBtYXkg
c2hvd+OAjOaaguaXoOiusOW9leOAjQogICAgbGV0IHNhd05vbkVtcHR5ID0gZmFsc2U7ICAgIC8v
IGlnbm9yZSBib290c3RyYXAgZW1wdHkgcHVzaGVzIGJlZm9yZSBmaXJzdCByZWFsIGxpc3QKICAg
IGxldCBwaW5uZWRUb3RhbCA9IDA7ICAgICAgICAvLyBhdXRob3JpdGF0aXZlIOaUtuiXjyBjb3Vu
dCBmcm9tIEFISwogICAgbGV0IHVuc2VlbkZhdklkcyA9IG5ldyBTZXQoKTsKICAgIHRyeSB7CiAg
ICAgICAgY29uc3QgcmF3ID0gbG9jYWxTdG9yYWdlLmdldEl0ZW0oJ2NsaXBfdW5zZWVuX2Zhdicp
OwogICAgICAgIGlmIChyYXcpIEpTT04ucGFyc2UocmF3KS5mb3JFYWNoKGlkID0+IHsgaWQgPSAr
aWQ7IGlmIChpZCkgdW5zZWVuRmF2SWRzLmFkZChpZCk7IH0pOwogICAgfSBjYXRjaCB7fQogICAg
ZnVuY3Rpb24gc2F2ZVVuc2VlbkZhdigpIHsKICAgICAgICB0cnkgeyBsb2NhbFN0b3JhZ2Uuc2V0
SXRlbSgnY2xpcF91bnNlZW5fZmF2JywgSlNPTi5zdHJpbmdpZnkoWy4uLnVuc2VlbkZhdklkc10p
KTsgfSBjYXRjaCB7fQogICAgfQogICAgZnVuY3Rpb24gdXBkYXRlUGluRG90KCkgewogICAgICAg
IGNvbnN0IGVsID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3Bpbi1kb3QnKTsKICAgICAgICBp
ZiAoIWVsKSByZXR1cm47CiAgICAgICAgZWwuY2xhc3NMaXN0LnRvZ2dsZSgnb24nLCB1bnNlZW5G
YXZJZHMuc2l6ZSA+IDApOwogICAgfQogICAgZnVuY3Rpb24gbWFya0ZhdlVuc2VlbihpZCkgewog
ICAgICAgIGlkID0gK2lkOwogICAgICAgIGlmICghaWQpIHJldHVybjsKICAgICAgICB1bnNlZW5G
YXZJZHMuYWRkKGlkKTsKICAgICAgICBzYXZlVW5zZWVuRmF2KCk7CiAgICAgICAgdXBkYXRlUGlu
RG90KCk7CiAgICB9CiAgICBmdW5jdGlvbiBjbGVhckZhdlVuc2VlbigpIHsKICAgICAgICBpZiAo
IXVuc2VlbkZhdklkcy5zaXplKSB7CiAgICAgICAgICAgIHVwZGF0ZVBpbkRvdCgpOwogICAgICAg
ICAgICByZXR1cm47CiAgICAgICAgfQogICAgICAgIHVuc2VlbkZhdklkcy5jbGVhcigpOwogICAg
ICAgIHNhdmVVbnNlZW5GYXYoKTsKICAgICAgICB1cGRhdGVQaW5Eb3QoKTsKICAgIH0KICAgIGNv
bnN0IFNLRUxfREVMQVlfTVMgPSA2MDsKICAgIHdpbmRvdy5fX2RhdGFSZWFkeSA9IGZhbHNlOwog
ICAgd2luZG93Ll9fdWlCb290ZWQgPSB0cnVlOwogICAgLy8gT3BlbiBwYW5lbCB3aXRob3V0IHBh
c3Rpbmcg4oaSIGFsd2F5cyBsYW5kIG9uIGZpcnN0IGl0ZW0gKGFmdGVyIGRhdGEgYXJyaXZlcykK
ICAgIGxldCBzZWxlY3RGaXJzdE9uU2hvdyA9IGZhbHNlOwogICAgbGV0IGxhc3RQYXN0ZUlkID0g
MDsKICAgIGxldCBsYXN0UGFzdGVUYWIgPSAnYWxsJzsKICAgIGxldCBsb2NhdGVBY3RpdmUgPSBm
YWxzZTsKICAgIHRyeSB7IGxhc3RQYXN0ZUlkID0gK2xvY2FsU3RvcmFnZS5nZXRJdGVtKCdjbGlw
TGFzdFBhc3RlSWQnKSB8fCAwOyB9IGNhdGNoIHt9CiAgICB0cnkgewogICAgICAgIGNvbnN0IHQg
PSBsb2NhbFN0b3JhZ2UuZ2V0SXRlbSgnY2xpcExhc3RQYXN0ZVRhYicpIHx8ICdhbGwnOwogICAg
ICAgIGxhc3RQYXN0ZVRhYiA9IFsnYWxsJywndGV4dCcsJ2ltYWdlJywnZmlsZScsJ3Bpbm5lZCdd
LmluY2x1ZGVzKHQpID8gdCA6ICdhbGwnOwogICAgfSBjYXRjaCB7fQogICAgLy8gUHJlZmVyIHNh
bWUtb3JpZ2luIHVuZGVyIGNsaXB1aS5hcHAgKEFQUF9IT1NUIOKGkiBDTElQX1YxX0RJUi9jbGlw
c19zdG9yZSkuCiAgICAvLyDli7/nlKggKi5sb2NhbO+8muezu+e7nyBtRE5TIOS8muWNoSAy4oCT
M3PjgIJjbGlwcy5zdG9yZSDku4XkvZwgZmFsbGJhY2vjgIIKICAgIGNvbnN0IFNUT1JFX0JBU0Ug
PSAobG9jYXRpb24ub3JpZ2luICYmIGxvY2F0aW9uLm9yaWdpbi5pbmRleE9mKCdodHRwczovLycp
ID09PSAwKQogICAgICAgID8gKGxvY2F0aW9uLm9yaWdpbi5yZXBsYWNlKC9cLyQvLCAnJykgKyAn
L2NsaXBzX3N0b3JlLycpCiAgICAgICAgOiAnaHR0cHM6Ly9jbGlwdWkuYXBwL2NsaXBzX3N0b3Jl
Lyc7CiAgICBjb25zdCBTVE9SRV9CQVNFX0ZBTExCQUNLID0gJ2h0dHBzOi8vY2xpcHMuc3RvcmUv
JzsKICAgIGZ1bmN0aW9uIG1ldGFDZW50ZXJIdG1sKGV4cGFuZElubmVyKSB7CiAgICAgICAgaWYg
KGV4cGFuZElubmVyID09IG51bGwgfHwgZXhwYW5kSW5uZXIgPT09IGZhbHNlKQogICAgICAgICAg
ICByZXR1cm4gYDxzcGFuIGNsYXNzPSJpLW1ldGEtY2VudGVyIj48L3NwYW4+YDsKICAgICAgICBy
ZXR1cm4gYDxzcGFuIGNsYXNzPSJpLW1ldGEtY2VudGVyIj48YnV0dG9uIGNsYXNzPSJpLWV4cGFu
ZC1idG4ke2V4cGFuZElubmVyLm9uID8gJyBvbicgOiAnJ30iIHR5cGU9ImJ1dHRvbiIgdGl0bGU9
IuWxleW8gC/mlLbotbciPiR7ZXhwYW5kSW5uZXIuaHRtbH08L2J1dHRvbj48L3NwYW4+YDsKICAg
IH0KCiAgICBmdW5jdGlvbiByZW1lbWJlckxhc3RQYXN0ZShpZCkgewogICAgICAgIGxhc3RQYXN0
ZUlkID0gK2lkIHx8IDA7CiAgICAgICAgbGFzdFBhc3RlVGFiID0gY3VyVGFiIHx8ICdhbGwnOwog
ICAgICAgIHRyeSB7CiAgICAgICAgICAgIGxvY2FsU3RvcmFnZS5zZXRJdGVtKCdjbGlwTGFzdFBh
c3RlSWQnLCBTdHJpbmcobGFzdFBhc3RlSWQpKTsKICAgICAgICAgICAgbG9jYWxTdG9yYWdlLnNl
dEl0ZW0oJ2NsaXBMYXN0UGFzdGVUYWInLCBsYXN0UGFzdGVUYWIpOwogICAgICAgIH0gY2F0Y2gg
e30KICAgICAgICB1cGRhdGVMb2NhdGVCdG4oKTsKICAgIH0KICAgIGZ1bmN0aW9uIHVwZGF0ZUxv
Y2F0ZUJ0bigpIHsKICAgICAgICBjb25zdCBidG4gPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgn
YnRuLWxvY2F0ZScpOwogICAgICAgIGlmICghYnRuKSByZXR1cm47CiAgICAgICAgYnRuLmRpc2Fi
bGVkID0gIWxhc3RQYXN0ZUlkOwogICAgICAgIGJ0bi5jbGFzc0xpc3QudG9nZ2xlKCdoYXMtdGFy
Z2V0JywgISFsYXN0UGFzdGVJZCk7CiAgICAgICAgYnRuLmNsYXNzTGlzdC50b2dnbGUoJ29uJywg
bG9jYXRlQWN0aXZlICYmICEhbGFzdFBhc3RlSWQpOwogICAgICAgIGJ0bi50aXRsZSA9ICFsYXN0
UGFzdGVJZAogICAgICAgICAgICA/ICfmmoLml6DkuIrmrKHkvb/nlKjkvY3nva4nCiAgICAgICAg
ICAgIDogKGxvY2F0ZUFjdGl2ZSA/ICflj5bmtojlrprkvY3vvIzlm57liLDnrKzkuIDmnaEnIDog
J+WumuS9jeWIsOS4iuasoeS9v+eUqOeahOadoeebricpOwogICAgfQogICAgZnVuY3Rpb24gc2Vs
ZWN0Rmlyc3RJdGVtKCkgewogICAgICAgIGxvY2F0ZUFjdGl2ZSA9IGZhbHNlOwogICAgICAgIHdp
bmRvdy5fX3BlbmRpbmdKdW1wSWQgPSAwOwogICAgICAgIHdpbmRvdy5fX2p1bXBMb2FkVHJpZXMg
PSAwOwogICAgICAgIHNlbGVjdEZpcnN0T25TaG93ID0gZmFsc2U7CiAgICAgICAgY29uc3Qgdmlz
ID0gdmlzaWJsZUxpc3QoKTsKICAgICAgICBpZiAoIXZpcy5sZW5ndGgpIHsKICAgICAgICAgICAg
c2VsZWN0ZWRJZCA9IDA7CiAgICAgICAgICAgIHN5bmNJdGVtSGlnaGxpZ2h0KCk7CiAgICAgICAg
ICAgIHVwZGF0ZUxvY2F0ZUJ0bigpOwogICAgICAgICAgICByZXR1cm47CiAgICAgICAgfQogICAg
ICAgIHNlbGVjdGVkSWQgPSB2aXNbMF0uaWQ7CiAgICAgICAgcmFuZ2VBbmNob3JJZCA9IHNlbGVj
dGVkSWQ7CiAgICAgICAgcmFuZ2VBbmNob3JDbGlja2VkID0gZmFsc2U7CiAgICAgICAgbGlzdEVs
LnNjcm9sbFRvcCA9IDA7CiAgICAgICAgc3luY0l0ZW1IaWdobGlnaHQoKTsKICAgICAgICBjb25z
dCBlbCA9IGxpc3RFbC5xdWVyeVNlbGVjdG9yKCcuaXRtW2RhdGEtaWQ9IicgKyBzZWxlY3RlZElk
ICsgJyJdJyk7CiAgICAgICAgaWYgKGVsKSBlbC5zY3JvbGxJbnRvVmlldyh7IGJsb2NrOiAnbmVh
cmVzdCcgfSk7CiAgICAgICAgdXBkYXRlTG9jYXRlQnRuKCk7CiAgICB9CiAgICBmdW5jdGlvbiBq
dW1wVG9MYXN0UGFzdGUoKSB7CiAgICAgICAgaWYgKCFsYXN0UGFzdGVJZCkgcmV0dXJuOwogICAg
ICAgIC8vIEFscmVhZHkgbG9jYXRlZCBvbiBsYXN0IHBhc3RlIOKGkiBjYW5jZWwgYW5kIHNlbGVj
dCBmaXJzdAogICAgICAgIGlmIChsb2NhdGVBY3RpdmUgJiYgK3NlbGVjdGVkSWQgPT09ICtsYXN0
UGFzdGVJZCkgewogICAgICAgICAgICBzZWxlY3RGaXJzdEl0ZW0oKTsKICAgICAgICAgICAgcmV0
dXJuOwogICAgICAgIH0KICAgICAgICBsb2NhdGVBY3RpdmUgPSB0cnVlOwogICAgICAgIHNlbGVj
dEZpcnN0T25TaG93ID0gZmFsc2U7CiAgICAgICAgLy8gQ2xlYXIgZmlsdGVycyBzbyB0aGUgaXRl
bSBpcyBmaW5kYWJsZSBvbiB0aGUgdGFiIHdoZXJlIGl0IHdhcyB1c2VkCiAgICAgICAgcXVlcnkg
PSAnJzsKICAgICAgICB0b2RheU9ubHkgPSBmYWxzZTsKICAgICAgICB0cnkgewogICAgICAgICAg
ICBjb25zdCBzcmNoID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NlYXJjaCcpOwogICAgICAg
ICAgICBjb25zdCBzY2xyID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NlYXJjaC1jbHInKTsK
ICAgICAgICAgICAgY29uc3Qgd3JhcCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzZWFyY2gt
d3JhcCcpOwogICAgICAgICAgICBjb25zdCBidG5Ub2RheSA9IGRvY3VtZW50LmdldEVsZW1lbnRC
eUlkKCdidG4tdG9kYXknKTsKICAgICAgICAgICAgaWYgKHNyY2gpIHsgc3JjaC52YWx1ZSA9ICcn
OyBzcmNoLmNsYXNzTGlzdC5yZW1vdmUoJ2hhcy12YWwnKTsgfQogICAgICAgICAgICBpZiAoc2Ns
cikgc2Nsci5zdHlsZS5kaXNwbGF5ID0gJ25vbmUnOwogICAgICAgICAgICBpZiAod3JhcCkgd3Jh
cC5jbGFzc0xpc3QucmVtb3ZlKCdvcGVuJyk7CiAgICAgICAgICAgIGlmIChidG5Ub2RheSkgYnRu
VG9kYXkuY2xhc3NMaXN0LnJlbW92ZSgnb24nKTsKICAgICAgICB9IGNhdGNoIHt9CiAgICAgICAg
Y29uc3QgdGFiID0gWydhbGwnLCd0ZXh0JywnaW1hZ2UnLCdmaWxlJywncGlubmVkJ10uaW5jbHVk
ZXMobGFzdFBhc3RlVGFiKQogICAgICAgICAgICA/IGxhc3RQYXN0ZVRhYiA6ICdhbGwnOwogICAg
ICAgIGNvbnN0IHByZXZUYWIgPSBjdXJUYWI7CiAgICAgICAgY3VyVGFiID0gdGFiOwogICAgICAg
IGxvYWRpbmdNb3JlID0gZmFsc2U7CiAgICAgICAgbWFya1RhYih0YWIpOwogICAgICAgIGNsZWFy
TXVsdGkoKTsKICAgICAgICBzZWxlY3RlZElkID0gbGFzdFBhc3RlSWQ7CiAgICAgICAgd2luZG93
Ll9fcGVuZGluZ0p1bXBJZCA9IGxhc3RQYXN0ZUlkOwogICAgICAgIHdpbmRvdy5fX2p1bXBMb2Fk
VHJpZXMgPSAwOwogICAgICAgIHdpbmRvdy5fX2p1bXBGZWxsQmFjayA9IGZhbHNlOwogICAgICAg
IHVwZGF0ZUxvY2F0ZUJ0bigpOwogICAgICAgIHJlcXVlc3RWaWV3KCk7CiAgICB9CgogICAgZnVu
Y3Rpb24gcmVxdWVzdFZpZXcoKSB7CiAgICAgICAgY29uc3QgdGFiID0gY3VyVGFiLCBxID0gcXVl
cnksIHRvZGF5ID0gdG9kYXlPbmx5ID8gJzEnIDogJzAnOwogICAgICAgIGlmICh3aW5kb3cuX192
aWV3UmFmKSBjYW5jZWxBbmltYXRpb25GcmFtZSh3aW5kb3cuX192aWV3UmFmKTsKICAgICAgICB3
aW5kb3cuX192aWV3UmFmID0gcmVxdWVzdEFuaW1hdGlvbkZyYW1lKCgpID0+IHsKICAgICAgICAg
ICAgd2luZG93Ll9fdmlld1JhZiA9IDA7CiAgICAgICAgICAgIHNldFRpbWVvdXQoKCkgPT4gYWhr
KCdzZXRWaWV3JywgdGFiLCBxLCB0b2RheSksIDApOwogICAgICAgIH0pOwogICAgfQogICAgLyoq
IERlYm91bmNlZCBBSEsgc3luYyBhZnRlciB2aWV3TWVtIGluc3RhbnQgcGFpbnQg4oCUYXZvaWRz
IHRhYi1zd2l0Y2ggZG91YmxlIFB1c2hDbGlwcyAqLwogICAgZnVuY3Rpb24gc29mdFJlcXVlc3RW
aWV3KCkgewogICAgICAgIGlmICh3aW5kb3cuX19zb2Z0Vmlld1QpIGNsZWFyVGltZW91dCh3aW5k
b3cuX19zb2Z0Vmlld1QpOwogICAgICAgIHdpbmRvdy5fX3NvZnRWaWV3VCA9IHNldFRpbWVvdXQo
KCkgPT4gewogICAgICAgICAgICB3aW5kb3cuX19zb2Z0Vmlld1QgPSAwOwogICAgICAgICAgICBy
ZXF1ZXN0VmlldygpOwogICAgICAgIH0sIDMyMCk7CiAgICB9CiAgICBmdW5jdGlvbiByZXF1ZXN0
TW9yZShmb3JjZSA9IGZhbHNlKSB7CiAgICAgICAgaWYgKGRpc2tUb3RhbCA+IDAgJiYgYWxsQ2xp
cHMubGVuZ3RoID49IGRpc2tUb3RhbCkgcmV0dXJuOwogICAgICAgIC8vIExvY2F0ZSAvIGp1bXAg
bXVzdCBub3Qgd2FpdCBvbiBzY3JvbGwtaWRsZSBvciBhIHN0dWNrIGxvYWRpbmdNb3JlIGZsYWcK
ICAgICAgICBpZiAoIWZvcmNlKSB7CiAgICAgICAgICAgIGlmIChsb2FkaW5nTW9yZSkgcmV0dXJu
OwogICAgICAgICAgICBpZiAod2luZG93Ll9fc2Nyb2xsQnVzeSB8fCBfbGlzdFB0ckRvd24pIHsK
ICAgICAgICAgICAgICAgIHdpbmRvdy5fX3dhbnRNb3JlID0gdHJ1ZTsKICAgICAgICAgICAgICAg
IHJldHVybjsKICAgICAgICAgICAgfQogICAgICAgIH0gZWxzZSB7CiAgICAgICAgICAgIGxvYWRp
bmdNb3JlID0gZmFsc2U7CiAgICAgICAgICAgIHdpbmRvdy5fX3Njcm9sbEJ1c3kgPSBmYWxzZTsK
ICAgICAgICAgICAgd2luZG93Ll9fd2FudE1vcmUgPSBmYWxzZTsKICAgICAgICAgICAgX2xpc3RQ
dHJEb3duID0gZmFsc2U7CiAgICAgICAgICAgIHRyeSB7IGxpc3RFbC5jbGFzc0xpc3QucmVtb3Zl
KCdpcy1zY3JvbGxpbmcnKTsgfSBjYXRjaCB7fQogICAgICAgIH0KICAgICAgICBpZiAobG9hZGlu
Z01vcmUpIHJldHVybjsKICAgICAgICBsb2FkaW5nTW9yZSA9IHRydWU7CiAgICAgICAgd2luZG93
Ll9fd2FudE1vcmUgPSBmYWxzZTsKICAgICAgICBpZiAod2luZG93Ll9fbG9hZE1vcmVXYXRjaCkg
Y2xlYXJUaW1lb3V0KHdpbmRvdy5fX2xvYWRNb3JlV2F0Y2gpOwogICAgICAgIHdpbmRvdy5fX2xv
YWRNb3JlV2F0Y2ggPSBzZXRUaW1lb3V0KCgpID0+IHsKICAgICAgICAgICAgd2luZG93Ll9fbG9h
ZE1vcmVXYXRjaCA9IDA7CiAgICAgICAgICAgIGlmIChsb2FkaW5nTW9yZSkgewogICAgICAgICAg
ICAgICAgbG9hZGluZ01vcmUgPSBmYWxzZTsKICAgICAgICAgICAgICAgIGlmICh3aW5kb3cuX19w
ZW5kaW5nSnVtcElkKSB0cnlDb250aW51ZUp1bXAoKTsKICAgICAgICAgICAgfQogICAgICAgIH0s
IDE4MDApOwogICAgICAgIGFoaygnbG9hZE1vcmUnKTsKICAgIH0KCiAgICBmdW5jdGlvbiB0cnlD
b250aW51ZUp1bXAoKSB7CiAgICAgICAgY29uc3QgamlkID0gK3dpbmRvdy5fX3BlbmRpbmdKdW1w
SWQ7CiAgICAgICAgaWYgKCFqaWQpIHJldHVybjsKICAgICAgICBpZiAoX3BlbmRpbmdBcHBlbmQp
IHsKICAgICAgICAgICAgY29uc3QgcGVuZGluZyA9IF9wZW5kaW5nQXBwZW5kOwogICAgICAgICAg
ICBfcGVuZGluZ0FwcGVuZCA9IG51bGw7CiAgICAgICAgICAgIGFwcGx5QXBwZW5kUGF5bG9hZChw
ZW5kaW5nKTsKICAgICAgICB9CiAgICAgICAgY29uc3QgZWwgPSBsaXN0RWwucXVlcnlTZWxlY3Rv
cignLm1nLXJvd1tkYXRhLWlkPSInICsgamlkICsgJyJdJykgfHwgbGlzdEVsLnF1ZXJ5U2VsZWN0
b3IoJy5pdG1bZGF0YS1pZD0iJyArIGppZCArICciXScpOwogICAgICAgIGlmIChlbCkgewogICAg
ICAgICAgICB3aW5kb3cuX19wZW5kaW5nSnVtcElkID0gMDsKICAgICAgICAgICAgd2luZG93Ll9f
anVtcExvYWRUcmllcyA9IDA7CiAgICAgICAgICAgIHNlbGVjdGVkSWQgPSBqaWQ7CiAgICAgICAg
ICAgIGxvY2F0ZUFjdGl2ZSA9IHRydWU7CiAgICAgICAgICAgIHVwZGF0ZUxvY2F0ZUJ0bigpOwog
ICAgICAgICAgICByZXF1ZXN0QW5pbWF0aW9uRnJhbWUoKCkgPT4gewogICAgICAgICAgICAgICAg
Y29uc3Qgbm9kZSA9IGxpc3RFbC5xdWVyeVNlbGVjdG9yKCcubWctcm93W2RhdGEtaWQ9IicgKyBq
aWQgKyAnIl0nKSB8fCBsaXN0RWwucXVlcnlTZWxlY3RvcignLml0bVtkYXRhLWlkPSInICsgamlk
ICsgJyJdJyk7CiAgICAgICAgICAgICAgICBpZiAoIW5vZGUpIHJldHVybjsKICAgICAgICAgICAg
ICAgIG5vZGUuc2Nyb2xsSW50b1ZpZXcoeyBibG9jazogJ2NlbnRlcicgfSk7CiAgICAgICAgICAg
ICAgICBub2RlLmNsYXNzTGlzdC5hZGQoJ2p1bXAtZmxhc2gnKTsKICAgICAgICAgICAgICAgIHNl
dFRpbWVvdXQoKCkgPT4gbm9kZS5jbGFzc0xpc3QucmVtb3ZlKCdqdW1wLWZsYXNoJyksIDkwMCk7
CiAgICAgICAgICAgICAgICBzeW5jSXRlbUhpZ2hsaWdodCgpOwogICAgICAgICAgICB9KTsKICAg
ICAgICAgICAgcmV0dXJuOwogICAgICAgIH0KICAgICAgICBpZiAoYWxsQ2xpcHMuc29tZShjID0+
ICtjLmlkID09PSBqaWQpKSB7CiAgICAgICAgICAgIHJlbmRlcigpOwogICAgICAgICAgICByZXF1
ZXN0QW5pbWF0aW9uRnJhbWUoKCkgPT4gdHJ5Q29udGludWVKdW1wKCkpOwogICAgICAgICAgICBy
ZXR1cm47CiAgICAgICAgfQogICAgICAgIGlmIChhbGxDbGlwcy5sZW5ndGggPCBkaXNrVG90YWwg
JiYgKHdpbmRvdy5fX2p1bXBMb2FkVHJpZXMgfHwgMCkgPCA4MCkgewogICAgICAgICAgICB3aW5k
b3cuX19qdW1wTG9hZFRyaWVzID0gKHdpbmRvdy5fX2p1bXBMb2FkVHJpZXMgfHwgMCkgKyAxOwog
ICAgICAgICAgICByZXF1ZXN0TW9yZSh0cnVlKTsKICAgICAgICAgICAgcmV0dXJuOwogICAgICAg
IH0KICAgICAgICB3aW5kb3cuX19wZW5kaW5nSnVtcElkID0gMDsKICAgICAgICB3aW5kb3cuX19q
dW1wTG9hZFRyaWVzID0gMDsKICAgIH0KICAgIGNvbnN0IEVNUFRZX01TRyA9IHsKICAgICAgICBh
bGw6ICAgICfmmoLml6DorrDlvZXvvIzlpI3liLblkI7oh6rliqjlh7rnjrAnLAogICAgICAgIHRl
eHQ6ICAgJ+aaguaXoOaWh+acrCcsCiAgICAgICAgaW1hZ2U6ICAn5pqC5peg5Zu+5YOPJywKICAg
ICAgICBmaWxlOiAgICfmmoLml6Dmlofku7YnLAogICAgICAgIHBpbm5lZDogJ+aaguaXoOaUtuiX
jycsCiAgICAgICAgcmVjZW50OiAn5pqC5peg5pyA6L+R5omT5byA55qE55uu5b2VJwogICAgfTsK
CiAgICBmdW5jdGlvbiBhaGtJbnZva2UobWV0aG9kLCBhcmdzKSB7CiAgICAgICAgdHJ5IHsKICAg
ICAgICAgICAgY29uc3QgaG9zdCA9IGNocm9tZS53ZWJ2aWV3Lmhvc3RPYmplY3RzLnN5bmMuYWhr
OwogICAgICAgICAgICBpZiAoIWhvc3QpIHJldHVybjsKICAgICAgICAgICAgbGV0IGNhbGxlZCA9
IGZhbHNlOwogICAgICAgICAgICAvLyBXZWJWaWV3MjogaG9zdC5jYWxsKG5hbWUsIOKApikgaXMg
dGhlIHJlbGlhYmxlIHBhdGguIERpcmVjdCBob3N0W21ldGhvZF0o4oCmKQogICAgICAgICAgICAv
LyBjYW4gbWlzLWJpbmQgYXJncyAoc2F3IHNldFZpZXcgdGFiIGJlY29tZSAwIOKGkiBmb3JldmVy
IHNrZWxldG9uIC8gd3JvbmcgdGFiKS4KICAgICAgICAgICAgaWYgKHR5cGVvZiBob3N0LmNhbGwg
PT09ICdmdW5jdGlvbicpIHsKICAgICAgICAgICAgICAgIHRyeSB7IGhvc3QuY2FsbChtZXRob2Qs
IC4uLmFyZ3MpOyBjYWxsZWQgPSB0cnVlOyB9IGNhdGNoIHt9CiAgICAgICAgICAgIH0KICAgICAg
ICAgICAgaWYgKCFjYWxsZWQgJiYgdHlwZW9mIGhvc3RbbWV0aG9kXSA9PT0gJ2Z1bmN0aW9uJykg
ewogICAgICAgICAgICAgICAgdHJ5IHsgaG9zdFttZXRob2RdKC4uLmFyZ3MpOyBjYWxsZWQgPSB0
cnVlOyB9IGNhdGNoIChlKSB7IGNvbnNvbGUud2FybignYWhrLicgKyBtZXRob2QsIGUpOyB9CiAg
ICAgICAgICAgIH0KICAgICAgICAgICAgaWYgKCFjYWxsZWQgJiYgaG9zdFttZXRob2RdICE9IG51
bGwgJiYgdHlwZW9mIGhvc3RbbWV0aG9kXSAhPT0gJ2Z1bmN0aW9uJykgewogICAgICAgICAgICAg
ICAgdHJ5IHsgdm9pZCBob3N0W21ldGhvZF07IH0gY2F0Y2gge30KICAgICAgICAgICAgfQogICAg
ICAgIH0gY2F0Y2ggKGUpIHsgY29uc29sZS53YXJuKCdhaGsuJyArIG1ldGhvZCwgZSk7IH0KICAg
IH0KICAgIGZ1bmN0aW9uIGFoayhtZXRob2QsIC4uLmFyZ3MpIHsKICAgICAgICBhaGtJbnZva2Uo
bWV0aG9kLCBhcmdzKTsKICAgIH0KICAgIGZ1bmN0aW9uIGFoa1JldChtZXRob2QsIC4uLmFyZ3Mp
IHsKICAgICAgICB0cnkgewogICAgICAgICAgICBjb25zdCBob3N0ID0gY2hyb21lLndlYnZpZXcu
aG9zdE9iamVjdHMuc3luYy5haGs7CiAgICAgICAgICAgIGlmICghaG9zdCkgcmV0dXJuIG51bGw7
CiAgICAgICAgICAgIGxldCByZXQgPSBudWxsOwogICAgICAgICAgICBpZiAodHlwZW9mIGhvc3Qu
Y2FsbCA9PT0gJ2Z1bmN0aW9uJykgewogICAgICAgICAgICAgICAgdHJ5IHsgcmV0ID0gaG9zdC5j
YWxsKG1ldGhvZCwgLi4uYXJncyk7IH0gY2F0Y2gge30KICAgICAgICAgICAgfQogICAgICAgICAg
ICBpZiAocmV0ID09IG51bGwgJiYgdHlwZW9mIGhvc3RbbWV0aG9kXSA9PT0gJ2Z1bmN0aW9uJykg
ewogICAgICAgICAgICAgICAgdHJ5IHsgcmV0ID0gaG9zdFttZXRob2RdKC4uLmFyZ3MpOyB9IGNh
dGNoIHt9CiAgICAgICAgICAgICAgICBpZiAocmV0ID09IG51bGwpIHsKICAgICAgICAgICAgICAg
ICAgICB0cnkgeyByZXQgPSBob3N0W21ldGhvZF0oLi4uYXJncyk7IH0gY2F0Y2gge30KICAgICAg
ICAgICAgICAgIH0KICAgICAgICAgICAgfQogICAgICAgICAgICBpZiAocmV0ID09IG51bGwgJiYg
aG9zdFttZXRob2RdICE9IG51bGwgJiYgdHlwZW9mIGhvc3RbbWV0aG9kXSAhPT0gJ2Z1bmN0aW9u
JykKICAgICAgICAgICAgICAgIHJldCA9IGhvc3RbbWV0aG9kXTsKICAgICAgICAgICAgaWYgKHJl
dCA9PSBudWxsKSByZXR1cm4gbnVsbDsKICAgICAgICAgICAgaWYgKHR5cGVvZiByZXQgPT09ICdz
dHJpbmcnIHx8IHR5cGVvZiByZXQgPT09ICdudW1iZXInIHx8IHR5cGVvZiByZXQgPT09ICdib29s
ZWFuJykKICAgICAgICAgICAgICAgIHJldHVybiByZXQ7CiAgICAgICAgICAgIHRyeSB7IHJldHVy
biBTdHJpbmcocmV0KTsgfSBjYXRjaCB7IHJldHVybiByZXQ7IH0KICAgICAgICB9IGNhdGNoIChl
KSB7IGNvbnNvbGUud2FybignYWhrUmV0LicgKyBtZXRob2QsIGUpOyB9CiAgICAgICAgcmV0dXJu
IG51bGw7CiAgICB9CgogICAgLy8gRWFybHkgQUhLIF9fc2V0VGh1bWIgY2FuIGFycml2ZSBiZWZv
cmUgRE9NIG5vZGVzIGV4aXN0IOKAlCBrZWVwIHVudGlsIGJpbmQKICAgIGNvbnN0IHRodW1iQ2Fj
aGUgPSBuZXcgTWFwKCk7CgogICAgLyoqIFByZWZlciBjYWNoZSAvIGRhdGEtVVJMLCB0aGVuIHRo
XyouanBnIHZpYSB2aXJ0dWFsIGhvc3QsIHRoZW4gb3JpZ2luYWwgKi8KICAgIGZ1bmN0aW9uIGJp
bmRTdG9yZVRodW1iKGltZywgZmlsZSwgaWQsIGZhbGxiYWNrKSB7CiAgICAgICAgaW1nLmRhdGFz
ZXQudGh1bWJJZCA9IFN0cmluZyhpZCk7CiAgICAgICAgaW1nLmFsdCA9ICcnOwogICAgICAgIGlt
Zy5jbGFzc0xpc3QuYWRkKCd0aHVtYi1sb2FkaW5nJyk7CiAgICAgICAgY29uc3Qgd3JhcCA9IGlt
Zy5wYXJlbnRFbGVtZW50OwogICAgICAgIGlmICh3cmFwICYmIHdyYXAuY2xhc3NMaXN0LmNvbnRh
aW5zKCdpLXRodW1iLXdyYXAnKSkKICAgICAgICAgICAgd3JhcC5jbGFzc0xpc3QuYWRkKCd3YWl0
aW5nJyk7CiAgICAgICAgY29uc3QgY2xlYXJXYWl0ID0gKCkgPT4gewogICAgICAgICAgICBpbWcu
Y2xhc3NMaXN0LnJlbW92ZSgndGh1bWItbG9hZGluZycpOwogICAgICAgICAgICBpZiAod3JhcCkg
d3JhcC5jbGFzc0xpc3QucmVtb3ZlKCd3YWl0aW5nJyk7CiAgICAgICAgICAgIGlmIChpbWcuX2Zh
aWxUaW1lcikgdHJ5IHsgY2xlYXJUaW1lb3V0KGltZy5fZmFpbFRpbWVyKTsgfSBjYXRjaCB7fQog
ICAgICAgIH07CiAgICAgICAgY29uc3QgZmFpbFRpbWVyID0gc2V0VGltZW91dCgoKSA9PiB7CiAg
ICAgICAgICAgIGlmICghaW1nLnNyYyB8fCBpbWcubmF0dXJhbFdpZHRoIDwgMSkKICAgICAgICAg
ICAgICAgIGltZy5hbHQgPSAn5peg5rOV5Yqg6L29JzsKICAgICAgICAgICAgY2xlYXJXYWl0KCk7
CiAgICAgICAgfSwgMTIwMDApOwogICAgICAgIGltZy5fZmFpbFRpbWVyID0gZmFpbFRpbWVyOwog
ICAgICAgIGNvbnN0IHByZXZMb2FkID0gaW1nLm9ubG9hZDsKICAgICAgICBpbWcub25sb2FkID0g
ZSA9PiB7CiAgICAgICAgICAgIGNsZWFyV2FpdCgpOwogICAgICAgICAgICBpbWcuYWx0ID0gJyc7
CiAgICAgICAgICAgIGlmICh0eXBlb2YgcHJldkxvYWQgPT09ICdmdW5jdGlvbicpIHByZXZMb2Fk
LmNhbGwoaW1nLCBlKTsKICAgICAgICB9OwogICAgICAgIGNvbnN0IGJhcmUgPSBmaWxlID8gU3Ry
aW5nKGZpbGUpLnNwbGl0KC9bXFwvXS8pLnBvcCgpIDogJyc7CiAgICAgICAgY29uc3QgdGhOYW1l
ID0gYmFyZSA/ICgndGhfJyArIGJhcmUucmVwbGFjZSgvXC5bXi5dKyQvLCAnJykgKyAnLmpwZycp
IDogJyc7CiAgICAgICAgaW1nLm9uZXJyb3IgPSAoKSA9PiB7CiAgICAgICAgICAgIGNvbnN0IHN0
ZXAgPSBOdW1iZXIoaW1nLmRhdGFzZXQuc3RlcCB8fCAwKTsKICAgICAgICAgICAgaWYgKHN0ZXAg
PCAyICYmIGJhcmUpIHsKICAgICAgICAgICAgICAgIGltZy5kYXRhc2V0LnN0ZXAgPSAnMic7CiAg
ICAgICAgICAgICAgICBpbWcuc3JjID0gU1RPUkVfQkFTRSArIGVuY29kZVVSSUNvbXBvbmVudChi
YXJlKTsKICAgICAgICAgICAgICAgIHJldHVybjsKICAgICAgICAgICAgfQogICAgICAgICAgICBp
ZiAoc3RlcCA8IDMgJiYgKHRoTmFtZSB8fCBiYXJlKSkgewogICAgICAgICAgICAgICAgaW1nLmRh
dGFzZXQuc3RlcCA9ICczJzsKICAgICAgICAgICAgICAgIGltZy5zcmMgPSBTVE9SRV9CQVNFX0ZB
TExCQUNLICsgZW5jb2RlVVJJQ29tcG9uZW50KHRoTmFtZSB8fCBiYXJlKTsKICAgICAgICAgICAg
ICAgIHJldHVybjsKICAgICAgICAgICAgfQogICAgICAgICAgICBpZiAoc3RlcCA8IDQgJiYgYmFy
ZSAmJiB0aE5hbWUpIHsKICAgICAgICAgICAgICAgIGltZy5kYXRhc2V0LnN0ZXAgPSAnNCc7CiAg
ICAgICAgICAgICAgICBpbWcuc3JjID0gU1RPUkVfQkFTRV9GQUxMQkFDSyArIGVuY29kZVVSSUNv
bXBvbmVudChiYXJlKTsKICAgICAgICAgICAgICAgIHJldHVybjsKICAgICAgICAgICAgfQogICAg
ICAgICAgICAvLyBLZWVwIHNoaW1tZXI7IEFISyBfX3NldFRodW1iIHdpbGwgZmlsbCBpbgogICAg
ICAgICAgICBpbWcucmVtb3ZlQXR0cmlidXRlKCdzcmMnKTsKICAgICAgICAgICAgaW1nLmNsYXNz
TGlzdC5hZGQoJ3RodW1iLWxvYWRpbmcnKTsKICAgICAgICAgICAgaWYgKHdyYXApIHdyYXAuY2xh
c3NMaXN0LmFkZCgnd2FpdGluZycpOwogICAgICAgIH07CiAgICAgICAgY29uc3QgY2FjaGVkID0g
dGh1bWJDYWNoZS5nZXQoU3RyaW5nKGlkKSk7CiAgICAgICAgLy8gQWNjZXB0IGRhdGEtVVJMIG9y
IGhvc3QgVVJMIGZyb20gcHJpb3IgX19zZXRUaHVtYiAocmUtcmVuZGVyIG11c3Qgbm90IGRyb3Ag
aXQpCiAgICAgICAgaWYgKGNhY2hlZCAmJiBTdHJpbmcoY2FjaGVkKS5sZW5ndGgpIHsKICAgICAg
ICAgICAgaW1nLmRhdGFzZXQuc3RlcCA9ICc5JzsKICAgICAgICAgICAgaW1nLnNyYyA9IFN0cmlu
ZyhjYWNoZWQpOwogICAgICAgICAgICByZXR1cm47CiAgICAgICAgfQogICAgICAgIGNvbnN0IGRh
dGFVcmwgPSAoZmFsbGJhY2sgJiYgU3RyaW5nKGZhbGxiYWNrKS5zdGFydHNXaXRoKCdkYXRhOicp
KQogICAgICAgICAgICA/IFN0cmluZyhmYWxsYmFjaykgOiAnJzsKICAgICAgICBpZiAoZGF0YVVy
bCkgewogICAgICAgICAgICBpbWcuZGF0YXNldC5zdGVwID0gJzknOwogICAgICAgICAgICBpbWcu
c3JjID0gZGF0YVVybDsKICAgICAgICAgICAgcmV0dXJuOwogICAgICAgIH0KICAgICAgICBpZiAo
YmFyZSkgewogICAgICAgICAgICAvLyBQcmVmZXIgbGlzdCB0aHVtYiBKUEVHIChzbWFsbCkgb24g
ZGVkaWNhdGVkIHN0b3JlIGhvc3QKICAgICAgICAgICAgaW1nLmRhdGFzZXQuc3RlcCA9ICcxJzsK
ICAgICAgICAgICAgaW1nLnNyYyA9IFNUT1JFX0JBU0UgKyBlbmNvZGVVUklDb21wb25lbnQodGhO
YW1lIHx8IGJhcmUpOwogICAgICAgIH0gZWxzZSB7CiAgICAgICAgICAgIC8vIE5vIGZpbGUgeWV0
IChqdXN0IGNvcGllZCkg4oCUa2VlcCBzaGltbWVyOyBJbmplY3RMaXZlSW1hZ2VUaHVtYiAvIF9f
c2V0VGh1bWIgZmlsbHMgaW4KICAgICAgICAgICAgaW1nLmNsYXNzTGlzdC5hZGQoJ3RodW1iLWxv
YWRpbmcnKTsKICAgICAgICAgICAgaWYgKHdyYXApIHdyYXAuY2xhc3NMaXN0LmFkZCgnd2FpdGlu
ZycpOwogICAgICAgIH0KICAgIH0KCiAgICB3aW5kb3cuX19zZXRUaHVtYiA9IChpZCwgdXJsKSA9
PiB7CiAgICAgICAgaWYgKCF1cmwpIHJldHVybjsKICAgICAgICBjb25zdCBrZXkgPSBTdHJpbmco
aWQpOwogICAgICAgIHRodW1iQ2FjaGUuc2V0KGtleSwgdXJsKTsKICAgICAgICBjb25zdCBhcHBs
eSA9IGltZyA9PiB7CiAgICAgICAgICAgIGlmIChpbWcuX2ZhaWxUaW1lcikgdHJ5IHsgY2xlYXJU
aW1lb3V0KGltZy5fZmFpbFRpbWVyKTsgfSBjYXRjaCB7fQogICAgICAgICAgICBpbWcub25lcnJv
ciA9IG51bGw7CiAgICAgICAgICAgIGltZy5hbHQgPSAnJzsKICAgICAgICAgICAgaW1nLmNsYXNz
TGlzdC5yZW1vdmUoJ3RodW1iLWxvYWRpbmcnKTsKICAgICAgICAgICAgY29uc3Qgd3JhcCA9IGlt
Zy5wYXJlbnRFbGVtZW50OwogICAgICAgICAgICBpZiAod3JhcCkgd3JhcC5jbGFzc0xpc3QucmVt
b3ZlKCd3YWl0aW5nJyk7CiAgICAgICAgICAgIGltZy5zcmMgPSB1cmw7CiAgICAgICAgfTsKICAg
ICAgICBsZXQgaGl0ID0gMDsKICAgICAgICBkb2N1bWVudC5xdWVyeVNlbGVjdG9yQWxsKCcuaXRt
W2RhdGEtaWQ9IicgKyBrZXkgKyAnIl0gaW1nLmktdGh1bWInKS5mb3JFYWNoKGltZyA9PiB7CiAg
ICAgICAgICAgIGFwcGx5KGltZyk7IGhpdCsrOwogICAgICAgIH0pOwogICAgICAgIGlmICghaGl0
KSB7CiAgICAgICAgICAgIGRvY3VtZW50LnF1ZXJ5U2VsZWN0b3JBbGwoJ2ltZy5pLXRodW1iW2Rh
dGEtdGh1bWItaWQ9IicgKyBrZXkgKyAnIl0nKS5mb3JFYWNoKGFwcGx5KTsKICAgICAgICB9CiAg
ICB9OwoKICAgIGZ1bmN0aW9uIGlzRHJhZ0V4Y2x1ZGUodCkgewogICAgICAgIHJldHVybiAhIXQu
Y2xvc2VzdCgnI3NlYXJjaC13cmFwLCAjYnRuLXNlYXJjaCwgI2J0bi1sb2NhdGUsICNidG4tdG9k
YXksICNidG4tcGluLCAjYnRuLWNsciwgI211bHRpLWJhciwgI211bHRpLXNlbCwgI211bHRpLWNu
dCwgI3Bhc3RlLXNlcC13cmFwLCAudGFiLCAuaXRtLCAjdGFiLWFjdGlvbnMsICNjdHgsICNjbHIt
ZGxnLCAjcGF0aC10aXAsIGJ1dHRvbiwgaW5wdXQsIGEnKTsKICAgIH0KICAgIGRvY3VtZW50Lmdl
dEVsZW1lbnRCeUlkKCdhcHAnKS5hZGRFdmVudExpc3RlbmVyKCdtb3VzZWRvd24nLCBlID0+IHsK
ICAgICAgICBpZiAoZS5idXR0b24gIT09IDApIHJldHVybjsKICAgICAgICBpZiAoaXNEcmFnRXhj
bHVkZShlLnRhcmdldCkpIHJldHVybjsKICAgICAgICBlLnByZXZlbnREZWZhdWx0KCk7CiAgICAg
ICAgYWhrKCdzdGFydERyYWcnKTsKICAgIH0sIHRydWUpOwoKICAgIGNvbnN0IGlzVXJsICA9IHMg
PT4gL15odHRwcz86XC9cLy9pLnRlc3QoKHMgfHwgJycpLnRyaW0oKSk7CgogICAgZnVuY3Rpb24g
YWdvKGRhdGVTdHIpIHsKICAgICAgICB0cnkgewogICAgICAgICAgICBjb25zdCBkID0gbmV3IERh
dGUoU3RyaW5nKGRhdGVTdHIpLnJlcGxhY2UoJyAnLCAnVCcpKTsKICAgICAgICAgICAgY29uc3Qg
cyA9IChEYXRlLm5vdygpIC0gZCkgLyAxMDAwIHwgMDsKICAgICAgICAgICAgaWYgKHMgPCA2MCkg
cmV0dXJuICfliJrliJonOwogICAgICAgICAgICBpZiAocyA8IDM2MDApIHJldHVybiAocyAvIDYw
IHwgMCkgKyAnIOWIhumSn+WJjSc7CiAgICAgICAgICAgIGlmIChzIDwgODY0MDApIHJldHVybiAo
cyAvIDM2MDAgfCAwKSArICcg5bCP5pe25YmNJzsKICAgICAgICAgICAgcmV0dXJuIChzIC8gODY0
MDAgfCAwKSArICcg5aSp5YmNJzsKICAgICAgICB9IGNhdGNoIHsgcmV0dXJuIGRhdGVTdHI7IH0K
ICAgIH0KCiAgICBmdW5jdGlvbiBub3JtVHlwZSh0KSB7CiAgICAgICAgdCA9IFN0cmluZyh0IHx8
ICcnKS50b0xvd2VyQ2FzZSgpOwogICAgICAgIGlmICh0ID09PSAnaW1hZ2UnIHx8IHQgPT09ICdp
bWcnIHx8IHQgPT09ICdiaXRtYXAnKSByZXR1cm4gJ2ltYWdlJzsKICAgICAgICBpZiAodCA9PT0g
J2ZpbGUnICB8fCB0ID09PSAnZmlsZXMnKSByZXR1cm4gJ2ZpbGUnOwogICAgICAgIGlmICh0ID09
PSAncmVjZW50JyB8fCB0ID09PSAnZm9sZGVyJyB8fCB0ID09PSAnZGlyJykgcmV0dXJuICdyZWNl
bnQnOwogICAgICAgIGlmICh0ID09PSAnbGluaycgfHwgdCA9PT0gJ3VybCcpIHJldHVybiAnbGlu
ayc7CiAgICAgICAgcmV0dXJuICd0ZXh0JzsKICAgIH0KICAgIGZ1bmN0aW9uIGlzUGlubmVkKGMp
IHsKICAgICAgICByZXR1cm4gYy5waW5uZWQgPT09IHRydWUgfHwgYy5waW5uZWQgPT09IDEgfHwg
Yy5waW5uZWQgPT09ICd0cnVlJyB8fCBjLnBpbm5lZCA9PT0gJzEnOwogICAgfQogICAgLyoqIOWQ
jOatpeaJgOaciSB0YWIg57yT5a2Y6YeM55qE5pS26JeP5qCH6K6w77yM6YG/5YWN5pS26JeP6aG1
5Y+W5raI5ZCO5YW25a6D5YiX6KGo5LuN5pi+56S644CM5Y+W5raI5pS26JeP44CNICovCiAgICBm
dW5jdGlvbiBwYXRjaFBpbm5lZEluQ2FjaGVzKGlkLCBwaW5uZWQpIHsKICAgICAgICBpZCA9ICtp
ZDsKICAgICAgICBpZiAoIWlkKSByZXR1cm47CiAgICAgICAgY29uc3QgYXBwbHkgPSAoYykgPT4g
ewogICAgICAgICAgICBpZiAoIWMgfHwgK2MuaWQgIT09IGlkKSByZXR1cm47CiAgICAgICAgICAg
IGMucGlubmVkID0gISFwaW5uZWQ7CiAgICAgICAgICAgIGlmICghcGlubmVkKSBjLnBpblRpbWUg
PSAnJzsKICAgICAgICB9OwogICAgICAgIGZvciAoY29uc3QgeCBvZiBhbGxDbGlwcykgYXBwbHko
eCk7CiAgICAgICAgdHJ5IHsKICAgICAgICAgICAgZm9yIChjb25zdCBba2V5LCBoaXRdIG9mIHZp
ZXdNZW0uZW50cmllcygpKSB7CiAgICAgICAgICAgICAgICBpZiAoIWhpdCB8fCAhQXJyYXkuaXNB
cnJheShoaXQuaXRlbXMpKSBjb250aW51ZTsKICAgICAgICAgICAgICAgIGZvciAoY29uc3QgeCBv
ZiBoaXQuaXRlbXMpIGFwcGx5KHgpOwogICAgICAgICAgICAgICAgLy8g5pS26JePIHRhYiDnvJPl
rZjvvJrlj5bmtojlkI7nm7TmjqXnp7vlh7oKICAgICAgICAgICAgICAgIGlmICghcGlubmVkICYm
IFN0cmluZyhrZXkpLnN0YXJ0c1dpdGgoJ3Bpbm5lZFx0JykpIHsKICAgICAgICAgICAgICAgICAg
ICBjb25zdCBiZWZvcmUgPSBoaXQuaXRlbXMubGVuZ3RoOwogICAgICAgICAgICAgICAgICAgIGhp
dC5pdGVtcyA9IGhpdC5pdGVtcy5maWx0ZXIoeCA9PiAreC5pZCAhPT0gaWQpOwogICAgICAgICAg
ICAgICAgICAgIGlmIChoaXQuaXRlbXMubGVuZ3RoICE9PSBiZWZvcmUpCiAgICAgICAgICAgICAg
ICAgICAgICAgIGhpdC50b3RhbCA9IE1hdGgubWF4KDAsIChOdW1iZXIoaGl0LnRvdGFsKSB8fCBi
ZWZvcmUpIC0gKGJlZm9yZSAtIGhpdC5pdGVtcy5sZW5ndGgpKTsKICAgICAgICAgICAgICAgICAg
ICB2aWV3TWVtLnNldChrZXksIGhpdCk7CiAgICAgICAgICAgICAgICB9CiAgICAgICAgICAgIH0K
ICAgICAgICB9IGNhdGNoIHt9CiAgICB9CiAgICBmdW5jdGlvbiBpc1Bhc3RlZChjKSB7CiAgICAg
ICAgcmV0dXJuIGMucGFzdGVkID09PSB0cnVlIHx8IGMucGFzdGVkID09PSAxIHx8IGMucGFzdGVk
ID09PSAndHJ1ZScgfHwgYy5wYXN0ZWQgPT09ICcxJzsKICAgIH0KCiAgICBmdW5jdGlvbiBpc01h
cmtkb3duKHRleHQpIHsKICAgICAgICBpZiAoIXRleHQgfHwgdGV4dC5sZW5ndGggPCA0KSByZXR1
cm4gZmFsc2U7CiAgICAgICAgcmV0dXJuIC8oPzpefFxuKSN7MSw2fSB8XlstKitdIHxcKlwqW14q
XG5dK1wqXCp8X19bXl9cbl0rX198KD86Xnxcbik+IHxgYGB8YFteYFxuXStgfFxbW15cXV0rXF1c
KFteKV0rXCl8XHwuK1x8LitcfC9tLnRlc3QodGV4dCk7CiAgICB9CiAgICBmdW5jdGlvbiBjbGlw
VXNlc01JY29uKGMpIHsKICAgICAgICBpZiAoIWMpIHJldHVybiBmYWxzZTsKICAgICAgICBpZiAo
Yy5pc01kID09PSB0cnVlIHx8IGMuaXNNZCA9PT0gMSB8fCBjLmlzTWQgPT09ICd0cnVlJyB8fCBj
LmlzTWQgPT09ICcxJykgcmV0dXJuIHRydWU7CiAgICAgICAgaWYgKGMuaXNSaWNoID09PSB0cnVl
IHx8IGMuaXNSaWNoID09PSAxIHx8IGMuaXNSaWNoID09PSAndHJ1ZScgfHwgYy5pc1JpY2ggPT09
ICcxJykgcmV0dXJuIHRydWU7CiAgICAgICAgY29uc3QgdCA9IFN0cmluZyhjLnR5cGUgfHwgJycp
LnRvTG93ZXJDYXNlKCk7CiAgICAgICAgaWYgKHQgJiYgdCAhPT0gJ3RleHQnICYmIHQgIT09ICds
aW5rJykgcmV0dXJuIGZhbHNlOwogICAgICAgIHJldHVybiBpc01hcmtkb3duKGMuZGF0YSB8fCBj
LnByZXZpZXcgfHwgJycpOwogICAgfQogICAgZnVuY3Rpb24gZXNjQXR0cihzKSB7CiAgICAgICAg
cmV0dXJuIFN0cmluZyhzIHx8ICcnKQogICAgICAgICAgICAucmVwbGFjZSgvJi9nLCAnJmFtcDsn
KQogICAgICAgICAgICAucmVwbGFjZSgvIi9nLCAnJnF1b3Q7JykKICAgICAgICAgICAgLnJlcGxh
Y2UoLzwvZywgJyZsdDsnKQogICAgICAgICAgICAucmVwbGFjZSgvPi9nLCAnJmd0OycpOwogICAg
fQoKICAgIGZ1bmN0aW9uIHRvZGF5UHJlZml4KCkgewogICAgICAgIGNvbnN0IGQgPSBuZXcgRGF0
ZSgpOwogICAgICAgIGNvbnN0IHAgPSBuID0+IFN0cmluZyhuKS5wYWRTdGFydCgyLCAnMCcpOwog
ICAgICAgIHJldHVybiBkLmdldEZ1bGxZZWFyKCkgKyAnLScgKyBwKGQuZ2V0TW9udGgoKSArIDEp
ICsgJy0nICsgcChkLmdldERhdGUoKSk7CiAgICB9CiAgICBmdW5jdGlvbiBpc1RvZGF5Q2xpcChj
KSB7CiAgICAgICAgcmV0dXJuIFN0cmluZyhjLnRpbWUgfHwgJycpLnN0YXJ0c1dpdGgodG9kYXlQ
cmVmaXgoKSk7CiAgICB9CgogICAgZnVuY3Rpb24gY2xpcEhheShjKSB7CiAgICAgICAgcmV0dXJu
IFN0cmluZyhjLnByZXZpZXcgfHwgJycpICsgJyAnICsgU3RyaW5nKGMuZGF0YSB8fCAnJykgKyAn
ICcKICAgICAgICAgICAgKyBTdHJpbmcoYy5saW5rVGl0bGUgfHwgJycpICsgJyAnICsgU3RyaW5n
KGMuZmF2VGl0bGUgfHwgJycpOwogICAgfQogICAgLyoqIE1hdGNoIEFISyBJdGVtTWF0Y2hlc1Zp
ZXcgbGlzdCBzZWFyY2gg4oCUIHByZXZpZXcgKCsgc2hvcnQgYm9keSBmYWxsYmFjayksIG5vdCBm
dWxsIGRhdGEgKi8KICAgIGZ1bmN0aW9uIGNsaXBTZWFyY2hIYXkoYykgewogICAgICAgIGNvbnN0
IHR5cGUgPSBTdHJpbmcoYy50eXBlIHx8ICcnKS50b0xvd2VyQ2FzZSgpOwogICAgICAgIGlmICh0
eXBlID09PSAnaW1hZ2UnKQogICAgICAgICAgICByZXR1cm4gU3RyaW5nKGMuZmF2VGl0bGUgfHwg
JycpOwogICAgICAgIGlmICh0eXBlID09PSAnZmlsZScpIHsKICAgICAgICAgICAgcmV0dXJuIFN0
cmluZyhjLnByZXZpZXcgfHwgJycpICsgJyAnICsgU3RyaW5nKGMuZGF0YSB8fCAnJykgKyAnICcK
ICAgICAgICAgICAgICAgICsgU3RyaW5nKGMuZmF2VGl0bGUgfHwgJycpOwogICAgICAgIH0KICAg
ICAgICBsZXQgcHJldiA9IFN0cmluZyhjLnByZXZpZXcgfHwgJycpOwogICAgICAgIGlmICghcHJl
diAmJiBjLmRhdGEpCiAgICAgICAgICAgIHByZXYgPSBTdHJpbmcoYy5kYXRhKS5zbGljZSgwLCA1
MDApOwogICAgICAgIHJldHVybiBwcmV2ICsgJyAnICsgU3RyaW5nKGMubGlua1RpdGxlIHx8ICcn
KSArICcgJyArIFN0cmluZyhjLmZhdlRpdGxlIHx8ICcnKTsKICAgIH0KICAgIGZ1bmN0aW9uIGNs
aXBNYXRjaGVzU2VhcmNoKGMsIHRlcm1MKSB7CiAgICAgICAgY29uc3QgdHlwZSA9IFN0cmluZyhj
LnR5cGUgfHwgJycpLnRvTG93ZXJDYXNlKCk7CiAgICAgICAgY29uc3QgaGF5ID0gKHR5cGUgPT09
ICdpbWFnZScgPyBTdHJpbmcoYy5mYXZUaXRsZSB8fCAnJykgOiBjbGlwU2VhcmNoSGF5KGMpKS50
b0xvd2VyQ2FzZSgpOwogICAgICAgIHJldHVybiB0ZXJtTC5ldmVyeSh0ID0+IGhheS5pbmNsdWRl
cyh0KSk7CiAgICB9CiAgICBmdW5jdGlvbiBmaWx0ZXIoY2xpcHMsIHRhYiwgcSkgewogICAgICAg
IC8vIOS4u+acuuW3sui/h+a7pOaXtuS7jeWBmuWJjeerr+WFnOW6le+8mumBv+WFjeernuaAgeaO
qOadpeacquWRveS4reihjAogICAgICAgIGNvbnN0IHRlcm1zID0gcXVlcnlUZXJtcyhxKTsKICAg
ICAgICBpZiAoIXRlcm1zLmxlbmd0aCkgcmV0dXJuIGNsaXBzOwogICAgICAgIGNvbnN0IHRlcm1M
ID0gdGVybXMubWFwKHQgPT4gdC50b0xvd2VyQ2FzZSgpKTsKICAgICAgICBjb25zdCBtYXRjaGVk
R3JvdXBzID0gbmV3IFNldCgpOwogICAgICAgIGZvciAoY29uc3QgYyBvZiBjbGlwcykgewogICAg
ICAgICAgICBpZiAoIWNsaXBNYXRjaGVzU2VhcmNoKGMsIHRlcm1MKSkgY29udGludWU7CiAgICAg
ICAgICAgIGNvbnN0IGdpZCA9IFN0cmluZyhjICYmIGMuZmF2R3JvdXAgfHwgJycpLnRyaW0oKTsK
ICAgICAgICAgICAgaWYgKGdpZCkgbWF0Y2hlZEdyb3Vwcy5hZGQoZ2lkKTsKICAgICAgICB9CiAg
ICAgICAgLy8g5ZCI5bm257uE77ya5YWz6ZSu5a2X5Y+v6IO95YiG5pWj5Zyo5LiN5ZCM6KGM77yI
5qCH6aKYL+ato+aWh++8iQogICAgICAgIGNvbnN0IGJ5R3JvdXAgPSBuZXcgTWFwKCk7CiAgICAg
ICAgZm9yIChjb25zdCBjIG9mIGNsaXBzKSB7CiAgICAgICAgICAgIGNvbnN0IGdpZCA9IFN0cmlu
ZyhjICYmIGMuZmF2R3JvdXAgfHwgJycpLnRyaW0oKTsKICAgICAgICAgICAgaWYgKCFnaWQpIGNv
bnRpbnVlOwogICAgICAgICAgICBpZiAoIWJ5R3JvdXAuaGFzKGdpZCkpIGJ5R3JvdXAuc2V0KGdp
ZCwgW10pOwogICAgICAgICAgICBieUdyb3VwLmdldChnaWQpLnB1c2goYyk7CiAgICAgICAgfQog
ICAgICAgIGZvciAoY29uc3QgW2dpZCwgbWVtYmVyc10gb2YgYnlHcm91cCkgewogICAgICAgICAg
ICBpZiAobWF0Y2hlZEdyb3Vwcy5oYXMoZ2lkKSkgY29udGludWU7CiAgICAgICAgICAgIGNvbnN0
IHVuaW9uID0gbWVtYmVycy5tYXAoYyA9PiB7CiAgICAgICAgICAgICAgICBjb25zdCB0eXBlID0g
U3RyaW5nKGMudHlwZSB8fCAnJykudG9Mb3dlckNhc2UoKTsKICAgICAgICAgICAgICAgIHJldHVy
biAodHlwZSA9PT0gJ2ltYWdlJyA/IFN0cmluZyhjLmZhdlRpdGxlIHx8ICcnKSA6IGNsaXBTZWFy
Y2hIYXkoYykpLnRvTG93ZXJDYXNlKCk7CiAgICAgICAgICAgIH0pLmpvaW4oJyAnKTsKICAgICAg
ICAgICAgaWYgKHRlcm1MLmV2ZXJ5KHQgPT4gdW5pb24uaW5jbHVkZXModCkpKQogICAgICAgICAg
ICAgICAgbWF0Y2hlZEdyb3Vwcy5hZGQoZ2lkKTsKICAgICAgICB9CiAgICAgICAgcmV0dXJuIGNs
aXBzLmZpbHRlcihjID0+IHsKICAgICAgICAgICAgaWYgKGNsaXBNYXRjaGVzU2VhcmNoKGMsIHRl
cm1MKSkgcmV0dXJuIHRydWU7CiAgICAgICAgICAgIGNvbnN0IGdpZCA9IFN0cmluZyhjICYmIGMu
ZmF2R3JvdXAgfHwgJycpLnRyaW0oKTsKICAgICAgICAgICAgcmV0dXJuIGdpZCAmJiBtYXRjaGVk
R3JvdXBzLmhhcyhnaWQpOwogICAgICAgIH0pOwogICAgfQoKICAgIGZ1bmN0aW9uIG1hcmtQYXN0
ZWRMb2NhbChpZHMpIHsKICAgICAgICBjb25zdCBsaXN0ID0gQXJyYXkuaXNBcnJheShpZHMpID8g
aWRzIDogW2lkc107CiAgICAgICAgaWYgKGxpc3QubGVuZ3RoKQogICAgICAgICAgICByZW1lbWJl
ckxhc3RQYXN0ZShsaXN0W2xpc3QubGVuZ3RoIC0gMV0pOwogICAgICAgIGNvbnN0IGJhZGdlSHRt
bCA9IGA8c3ZnIHZpZXdCb3g9IjAgMCAxNiAxNiIgZmlsbD0ibm9uZSIgc3Ryb2tlPSJjdXJyZW50
Q29sb3IiIHN0cm9rZS13aWR0aD0iMi40IiBzdHJva2UtbGluZWNhcD0icm91bmQiIHN0cm9rZS1s
aW5lam9pbj0icm91bmQiPjxwb2x5bGluZSBwb2ludHM9IjMuNSA4LjUgNi41IDExLjUgMTIuNSA0
LjUiLz48L3N2Zz5gOwogICAgICAgIGxpc3QuZm9yRWFjaChyYXdJZCA9PiB7CiAgICAgICAgICAg
IGNvbnN0IGlkID0gK3Jhd0lkOwogICAgICAgICAgICBjb25zdCBjID0gYWxsQ2xpcHMuZmluZCh4
ID0+ICt4LmlkID09PSBpZCk7CiAgICAgICAgICAgIGlmIChjKSBjLnBhc3RlZCA9IHRydWU7CiAg
ICAgICAgICAgIGNvbnN0IHJvdyA9IGxpc3RFbCAmJiAoCiAgICAgICAgICAgICAgICBsaXN0RWwu
cXVlcnlTZWxlY3RvcignLml0bVtkYXRhLWlkPSInICsgaWQgKyAnIl0nKQogICAgICAgICAgICAg
ICAgfHwgbGlzdEVsLnF1ZXJ5U2VsZWN0b3IoJy5pdG1bZGF0YS1pZD0iJyArIFN0cmluZyhyYXdJ
ZCkgKyAnIl0nKQogICAgICAgICAgICApOwogICAgICAgICAgICBpZiAoIXJvdykgcmV0dXJuOwog
ICAgICAgICAgICByb3cuY2xhc3NMaXN0LmFkZCgncGFzdGVkJywgJ3EtZG9uZScpOwogICAgICAg
ICAgICBjb25zdCBpY28gPSByb3cucXVlcnlTZWxlY3RvcignLmktaWNvJyk7CiAgICAgICAgICAg
IGlmIChpY28gJiYgIWljby5xdWVyeVNlbGVjdG9yKCcuaS11c2VkJykpIHsKICAgICAgICAgICAg
ICAgIGNvbnN0IGJhZGdlID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnc3BhbicpOwogICAgICAg
ICAgICAgICAgYmFkZ2UuY2xhc3NOYW1lID0gJ2ktdXNlZCc7CiAgICAgICAgICAgICAgICBiYWRn
ZS50aXRsZSA9ICflt7LnspjotLQnOwogICAgICAgICAgICAgICAgYmFkZ2UuaW5uZXJIVE1MID0g
YmFkZ2VIdG1sOwogICAgICAgICAgICAgICAgaWNvLmFwcGVuZENoaWxkKGJhZGdlKTsKICAgICAg
ICAgICAgfQogICAgICAgIH0pOwogICAgICAgIHRyeSB7IG1hcmtRdWV1ZVJhaWxzKCk7IH0gY2F0
Y2ggKGUpIHt9CiAgICB9CiAgICB3aW5kb3cuX19tYXJrUGFzdGVkID0gbWFya1Bhc3RlZExvY2Fs
OwoKICAgIGZ1bmN0aW9uIG1hcmtVbnBhc3RlZExvY2FsKGlkcykgewogICAgICAgIGNvbnN0IGxp
c3QgPSBBcnJheS5pc0FycmF5KGlkcykgPyBpZHMgOiBbaWRzXTsKICAgICAgICBsaXN0LmZvckVh
Y2gocmF3SWQgPT4gewogICAgICAgICAgICBjb25zdCBpZCA9ICtyYXdJZDsKICAgICAgICAgICAg
Y29uc3QgYyA9IGFsbENsaXBzLmZpbmQoeCA9PiAreC5pZCA9PT0gaWQpOwogICAgICAgICAgICBp
ZiAoYykgYy5wYXN0ZWQgPSBmYWxzZTsKICAgICAgICAgICAgY29uc3Qgcm93ID0gbGlzdEVsICYm
ICgKICAgICAgICAgICAgICAgIGxpc3RFbC5xdWVyeVNlbGVjdG9yKCcuaXRtW2RhdGEtaWQ9Iicg
KyBpZCArICciXScpCiAgICAgICAgICAgICAgICB8fCBsaXN0RWwucXVlcnlTZWxlY3RvcignLml0
bVtkYXRhLWlkPSInICsgU3RyaW5nKHJhd0lkKSArICciXScpCiAgICAgICAgICAgICk7CiAgICAg
ICAgICAgIGlmICghcm93KSByZXR1cm47CiAgICAgICAgICAgIHJvdy5jbGFzc0xpc3QucmVtb3Zl
KCdwYXN0ZWQnLCAncS1kb25lJywgJ3EtZG9uZS1saW5rJyk7CiAgICAgICAgICAgIGNvbnN0IGJh
ZGdlID0gcm93LnF1ZXJ5U2VsZWN0b3IoJy5pLXVzZWQnKTsKICAgICAgICAgICAgaWYgKGJhZGdl
KSBiYWRnZS5yZW1vdmUoKTsKICAgICAgICAgICAgY29uc3QgZG90ID0gcm93LnF1ZXJ5U2VsZWN0
b3IoJy5xLWRvdCcpOwogICAgICAgICAgICBpZiAoZG90KSBkb3QudGl0bGUgPSAn57KY6LS06Zif
5YiXJzsKICAgICAgICB9KTsKICAgICAgICB0cnkgeyBtYXJrUXVldWVSYWlscygpOyB9IGNhdGNo
IChlKSB7fQogICAgfQogICAgd2luZG93Ll9fbWFya1VucGFzdGVkID0gbWFya1VucGFzdGVkTG9j
YWw7CgogICAgY29uc3QgbGlzdEVsICA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdsaXN0Jyk7
CiAgICBjb25zdCBlbXB0eUVsID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2VtcHR5Jyk7CiAg
ICBjb25zdCBza2VsRWwgID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NrZWwnKTsKICAgIGNv
bnN0IGJ0blRvcCAgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYnRuLXRvcCcpOwogICAgZnVu
Y3Rpb24gc2V0Qm9vdExvYWRpbmcob24pIHsKICAgICAgICBib290TG9hZGluZyA9ICEhb247CiAg
ICAgICAgLy8g56eS5byA77ya5LiN5YaN5omT5byA6aqo5p626Zeq5Yqo77yb5Y+q5L+d55WZIHdh
aXRpbmdEYXRhIOmAu+i+kemYsuepuuaAgeivr+mXqgogICAgICAgIGlmIChza2VsRWwpIHNrZWxF
bC5jbGFzc0xpc3QucmVtb3ZlKCdvbicpOwogICAgICAgIGlmIChvbiAmJiBlbXB0eUVsKSBlbXB0
eUVsLmNsYXNzTGlzdC5yZW1vdmUoJ29uJyk7CiAgICAgICAgY29uc3QgYXBwID0gZG9jdW1lbnQu
Z2V0RWxlbWVudEJ5SWQoJ2FwcCcpOwogICAgICAgIGlmIChhcHApIGFwcC5jbGFzc0xpc3QucmVt
b3ZlKCdib290LWxvYWRpbmcnKTsKICAgIH0KICAgIC8qKiBXYWl0IGZvciBob3N0IGRhdGEg4oCU
5LiN5YaN56uL5Yi75by56aqo5p6277yM5pyJ5YaF5a655pe25L+d5oyB5pen5YiX6KGoICovCiAg
ICBmdW5jdGlvbiBzY2hlZHVsZURlbGF5ZWRTa2VsKCkgewogICAgICAgIHdhaXRpbmdEYXRhID0g
dHJ1ZTsKICAgICAgICB3aW5kb3cuX19kYXRhUmVhZHkgPSBmYWxzZTsKICAgICAgICBpZiAoZW1w
dHlFbCkgZW1wdHlFbC5jbGFzc0xpc3QucmVtb3ZlKCdvbicpOwogICAgICAgIGlmICh3aW5kb3cu
X19wZW5kaW5nU2tlbFRpbWVyKSB7CiAgICAgICAgICAgIGNsZWFyVGltZW91dCh3aW5kb3cuX19w
ZW5kaW5nU2tlbFRpbWVyKTsKICAgICAgICAgICAgd2luZG93Ll9fcGVuZGluZ1NrZWxUaW1lciA9
IDA7CiAgICAgICAgfQogICAgICAgIHdpbmRvdy5fX3BlbmRpbmdTa2VsU2luY2UgPSBEYXRlLm5v
dygpOwogICAgICAgIC8vIOacieaXp+WIl+ihqOWwseS/neeVme+8m+epuuWIl+ihqOS5n+S4jeWG
jeaSremqqOaetuWKqOeUuwogICAgfQogICAgZnVuY3Rpb24gY2xlYXJXYWl0aW5nRGF0YSgpIHsK
ICAgICAgICB3YWl0aW5nRGF0YSA9IGZhbHNlOwogICAgICAgIGlmICh3aW5kb3cuX19wZW5kaW5n
U2tlbFRpbWVyKSB7CiAgICAgICAgICAgIGNsZWFyVGltZW91dCh3aW5kb3cuX19wZW5kaW5nU2tl
bFRpbWVyKTsKICAgICAgICAgICAgd2luZG93Ll9fcGVuZGluZ1NrZWxUaW1lciA9IDA7CiAgICAg
ICAgfQogICAgICAgIHdpbmRvdy5fX3BlbmRpbmdTa2VsU2luY2UgPSAwOwogICAgICAgIHNldEJv
b3RMb2FkaW5nKGZhbHNlKTsKICAgIH0KICAgIHdpbmRvdy5zZXRCb290TG9hZGluZyA9IHNldEJv
b3RMb2FkaW5nOwogICAgd2luZG93LmZvcmNlRW5kQm9vdExvYWRpbmcgPSBmdW5jdGlvbigpIHsK
ICAgICAgICBjbGVhcldhaXRpbmdEYXRhKCk7CiAgICAgICAgLy8gRG8gbm90IGZha2XjgIzmmoLm
l6DorrDlvZXjgI1pZiBob3N0IG5ldmVyIHB1c2hlZAogICAgICAgIGlmIChob3N0UHVzaGVkT25j
ZSkKICAgICAgICAgICAgd2luZG93Ll9fZGF0YVJlYWR5ID0gdHJ1ZTsKICAgICAgICB0cnkgeyBy
ZW5kZXIoKTsgfSBjYXRjaCAoZSkge30KICAgIH07CiAgICAvLyBTYWZldHk6IGRyb3Agc3R1Y2sg
c2tlbGV0b247IHN0aWxsIG5ldmVyIGludmVudCBlbXB0eS1zdGF0ZSB3aXRob3V0IGhvc3QgcHVz
aAogICAgc2V0VGltZW91dCgoKSA9PiB7CiAgICAgICAgaWYgKGhvc3RQdXNoZWRPbmNlIHx8IHdp
bmRvdy5fX2RhdGFSZWFkeSkgcmV0dXJuOwogICAgICAgIGlmICghYm9vdExvYWRpbmcgJiYgIXdh
aXRpbmdEYXRhKSByZXR1cm47CiAgICAgICAgY2xlYXJXYWl0aW5nRGF0YSgpOwogICAgICAgIHRy
eSB7IHJlbmRlcigpOyB9IGNhdGNoIHt9CiAgICB9LCA4MDAwKTsKCiAgICBmdW5jdGlvbiB1cGRh
dGVUb3BCdG4oKSB7CiAgICAgICAgaWYgKCFidG5Ub3AgfHwgIWxpc3RFbCkgcmV0dXJuOwogICAg
ICAgIGJ0blRvcC5jbGFzc0xpc3QudG9nZ2xlKCdvbicsIGxpc3RFbC5zY3JvbGxUb3AgPiA0OCk7
CiAgICB9CiAgICBsZXQgX3Njcm9sbFJhZiA9IDA7CiAgICBsZXQgX3Njcm9sbElkbGVUID0gMDsK
ICAgIGxldCBfbGlzdFB0ckRvd24gPSBmYWxzZTsKICAgIGxldCBfcGVuZGluZ0FwcGVuZCA9IG51
bGw7IC8vIHsgZnJvbUxlbiB9IHF1ZXVlZCB3aGlsZSBzY3JvbGxpbmcKICAgIHdpbmRvdy5fX3Nj
cm9sbEJ1c3kgPSBmYWxzZTsKICAgIHdpbmRvdy5fX3dhbnRNb3JlID0gZmFsc2U7CgogICAgZnVu
Y3Rpb24gbWFya0xpc3RTY3JvbGxpbmcoKSB7CiAgICAgICAgd2luZG93Ll9fc2Nyb2xsQnVzeSA9
IHRydWU7CiAgICAgICAgdHJ5IHsgbGlzdEVsLmNsYXNzTGlzdC5hZGQoJ2lzLXNjcm9sbGluZycp
OyB9IGNhdGNoIHt9CiAgICAgICAgaWYgKF9zY3JvbGxJZGxlVCkgY2xlYXJUaW1lb3V0KF9zY3Jv
bGxJZGxlVCk7CiAgICAgICAgX3Njcm9sbElkbGVUID0gc2V0VGltZW91dCgoKSA9PiB7CiAgICAg
ICAgICAgIF9zY3JvbGxJZGxlVCA9IDA7CiAgICAgICAgICAgIGZsdXNoU2Nyb2xsSWRsZSgpOwog
ICAgICAgIH0sIDIyMCk7CiAgICB9CgogICAgZnVuY3Rpb24gZmx1c2hTY3JvbGxJZGxlKCkgewog
ICAgICAgIGlmIChfbGlzdFB0ckRvd24pIHsKICAgICAgICAgICAgbWFya0xpc3RTY3JvbGxpbmco
KTsKICAgICAgICAgICAgcmV0dXJuOwogICAgICAgIH0KICAgICAgICB3aW5kb3cuX19zY3JvbGxC
dXN5ID0gZmFsc2U7CiAgICAgICAgdHJ5IHsgbGlzdEVsLmNsYXNzTGlzdC5yZW1vdmUoJ2lzLXNj
cm9sbGluZycpOyB9IGNhdGNoIHt9CiAgICAgICAgaWYgKF9wZW5kaW5nQXBwZW5kKSB7CiAgICAg
ICAgICAgIGNvbnN0IHBlbmRpbmcgPSBfcGVuZGluZ0FwcGVuZDsKICAgICAgICAgICAgX3BlbmRp
bmdBcHBlbmQgPSBudWxsOwogICAgICAgICAgICBhcHBseUFwcGVuZFBheWxvYWQocGVuZGluZyk7
CiAgICAgICAgfQogICAgICAgIGlmICh3aW5kb3cuX193YW50TW9yZSkKICAgICAgICAgICAgcmVx
dWVzdE1vcmUoKTsKICAgICAgICBlbHNlIGlmICghbG9hZGluZ01vcmUKICAgICAgICAgICAgJiYg
ZGlza1RvdGFsID4gMAogICAgICAgICAgICAmJiBhbGxDbGlwcy5sZW5ndGggPCBkaXNrVG90YWwK
ICAgICAgICAgICAgJiYgbGlzdEVsLnNjcm9sbFRvcCArIGxpc3RFbC5jbGllbnRIZWlnaHQgPj0g
bGlzdEVsLnNjcm9sbEhlaWdodCAtIDQyMCkKICAgICAgICAgICAgcmVxdWVzdE1vcmUoKTsKICAg
IH0KCiAgICBmdW5jdGlvbiBvbkxpc3RTY3JvbGwoKSB7CiAgICAgICAgbWFya0xpc3RTY3JvbGxp
bmcoKTsKICAgICAgICBpZiAoX3Njcm9sbFJhZikgcmV0dXJuOwogICAgICAgIF9zY3JvbGxSYWYg
PSByZXF1ZXN0QW5pbWF0aW9uRnJhbWUoKCkgPT4gewogICAgICAgICAgICBfc2Nyb2xsUmFmID0g
MDsKICAgICAgICAgICAgdHJ5IHsgaGlkZVBhdGhUaXAoKTsgfSBjYXRjaCB7fQogICAgICAgICAg
ICB1cGRhdGVUb3BCdG4oKTsKICAgICAgICAgICAgaWYgKCFsb2FkaW5nTW9yZQogICAgICAgICAg
ICAgICAgJiYgZGlza1RvdGFsID4gMAogICAgICAgICAgICAgICAgJiYgYWxsQ2xpcHMubGVuZ3Ro
IDwgZGlza1RvdGFsCiAgICAgICAgICAgICAgICAmJiBsaXN0RWwuc2Nyb2xsVG9wICsgbGlzdEVs
LmNsaWVudEhlaWdodCA+PSBsaXN0RWwuc2Nyb2xsSGVpZ2h0IC0gMjQwKQogICAgICAgICAgICAg
ICAgd2luZG93Ll9fd2FudE1vcmUgPSB0cnVlOwogICAgICAgIH0pOwogICAgfQogICAgbGlzdEVs
LmFkZEV2ZW50TGlzdGVuZXIoJ3Njcm9sbCcsIG9uTGlzdFNjcm9sbCwgeyBwYXNzaXZlOiB0cnVl
IH0pOwogICAgbGlzdEVsLmFkZEV2ZW50TGlzdGVuZXIoJ3doZWVsJywgbWFya0xpc3RTY3JvbGxp
bmcsIHsgcGFzc2l2ZTogdHJ1ZSB9KTsKICAgIGxpc3RFbC5hZGRFdmVudExpc3RlbmVyKCdwb2lu
dGVyZG93bicsIGUgPT4gewogICAgICAgIGlmIChlLmJ1dHRvbiAhPT0gMCkgcmV0dXJuOwogICAg
ICAgIF9saXN0UHRyRG93biA9IHRydWU7CiAgICAgICAgbWFya0xpc3RTY3JvbGxpbmcoKTsKICAg
IH0sIHsgcGFzc2l2ZTogdHJ1ZSB9KTsKICAgIHdpbmRvdy5hZGRFdmVudExpc3RlbmVyKCdwb2lu
dGVydXAnLCAoKSA9PiB7CiAgICAgICAgaWYgKCFfbGlzdFB0ckRvd24pIHJldHVybjsKICAgICAg
ICBfbGlzdFB0ckRvd24gPSBmYWxzZTsKICAgICAgICBtYXJrTGlzdFNjcm9sbGluZygpOwogICAg
fSwgeyBwYXNzaXZlOiB0cnVlIH0pOwogICAgd2luZG93LmFkZEV2ZW50TGlzdGVuZXIoJ3BvaW50
ZXJjYW5jZWwnLCAoKSA9PiB7CiAgICAgICAgaWYgKCFfbGlzdFB0ckRvd24pIHJldHVybjsKICAg
ICAgICBfbGlzdFB0ckRvd24gPSBmYWxzZTsKICAgICAgICBtYXJrTGlzdFNjcm9sbGluZygpOwog
ICAgfSwgeyBwYXNzaXZlOiB0cnVlIH0pOwogICAgYnRuVG9wLmFkZEV2ZW50TGlzdGVuZXIoJ2Ns
aWNrJywgZSA9PiB7CiAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICBsaXN0RWwu
c2Nyb2xsVG8oeyB0b3A6IDAsIGJlaGF2aW9yOiAnc21vb3RoJyB9KTsKICAgIH0pOwoKICAgIGZ1
bmN0aW9uIHZpc2libGVMaXN0KCkgewogICAgICAgIGNvbnN0IHEgPSBTdHJpbmcocXVlcnkgfHwg
JycpLnRyaW0oKTsKICAgICAgICAvLyBIb3N0IGFscmVhZHkgZmlsdGVyZWQrZXhwYW5kZWQgZm9y
IHRoaXMgZXhhY3QgcXVlcnkg4oCUIGRvbid0IHJlLWZpbHRlciAoYXZvaWRzIGZsYXNoIC8gZHJv
cHBlZCBmYXYgZ3JvdXBzKQogICAgICAgIGxldCBsaXN0ID0gKHEgJiYgd2luZG93Ll9faG9zdEZp
bHRlcmVkICYmIHdpbmRvdy5fX2hvc3RGaWx0ZXJRID09PSBxKQogICAgICAgICAgICA/IGFsbENs
aXBzCiAgICAgICAgICAgIDogZmlsdGVyKGFsbENsaXBzLCBjdXJUYWIsIHF1ZXJ5KTsKICAgICAg
ICAvLyDmlLbol4/pobXvvJrmnKzlnLDlho3mu6TkuIDmrKHvvIzlj5bmtojmlLbol4/lj6/nq4vl
iLvmtojlpLHvvIzkuI3lv4XnrYkgQUhLIOmHjeW7ugogICAgICAgIGlmIChjdXJUYWIgPT09ICdw
aW5uZWQnKQogICAgICAgICAgICBsaXN0ID0gbGlzdC5maWx0ZXIoYyA9PiBpc1Bpbm5lZChjKSk7
CiAgICAgICAgcmV0dXJuIGxpc3Q7CiAgICB9CiAgICBmdW5jdGlvbiBlc2NIdG1sKHMpIHsKICAg
ICAgICByZXR1cm4gU3RyaW5nKHMgPz8gJycpLnJlcGxhY2UoLyYvZywnJmFtcDsnKS5yZXBsYWNl
KC88L2csJyZsdDsnKS5yZXBsYWNlKC8+L2csJyZndDsnKS5yZXBsYWNlKC8iL2csJyZxdW90Oycp
OwogICAgfQogICAgZnVuY3Rpb24gcXVlcnlUZXJtcyhxKSB7CiAgICAgICAgY29uc3Qgb3V0ID0g
W107CiAgICAgICAgZm9yIChjb25zdCBzZWcgb2YgU3RyaW5nKHEgfHwgJycpLnNwbGl0KCd8Jykp
IHsKICAgICAgICAgICAgY29uc3QgcyA9IHNlZy50cmltKCk7CiAgICAgICAgICAgIGlmICghcykg
Y29udGludWU7CiAgICAgICAgICAgIGNvbnN0IHdvcmRzID0gcy5zcGxpdCgvXHMrLykuZmlsdGVy
KEJvb2xlYW4pOwogICAgICAgICAgICBpZiAod29yZHMubGVuZ3RoKSBvdXQucHVzaCguLi53b3Jk
cyk7CiAgICAgICAgfQogICAgICAgIHJldHVybiBvdXQ7CiAgICB9CiAgICBmdW5jdGlvbiBobEh0
bWwodGV4dCkgewogICAgICAgIGNvbnN0IHRlcm1zID0gcXVlcnlUZXJtcyhxdWVyeSk7CiAgICAg
ICAgY29uc3QgcyA9IFN0cmluZyh0ZXh0ID8/ICcnKTsKICAgICAgICBpZiAoIXRlcm1zLmxlbmd0
aCkgcmV0dXJuIGVzY0h0bWwocyk7CiAgICAgICAgY29uc3QgbG93ZXIgPSBzLnRvTG93ZXJDYXNl
KCk7CiAgICAgICAgY29uc3QgdGVybUwgPSB0ZXJtcy5tYXAodCA9PiB0LnRvTG93ZXJDYXNlKCkp
OwogICAgICAgIGxldCBvdXQgPSAnJywgaSA9IDA7CiAgICAgICAgd2hpbGUgKGkgPCBzLmxlbmd0
aCkgewogICAgICAgICAgICBsZXQgYmVzdEogPSAtMSwgYmVzdExlbiA9IDA7CiAgICAgICAgICAg
IGZvciAobGV0IHRpID0gMDsgdGkgPCB0ZXJtTC5sZW5ndGg7IHRpKyspIHsKICAgICAgICAgICAg
ICAgIGNvbnN0IHQgPSB0ZXJtTFt0aV07CiAgICAgICAgICAgICAgICBpZiAoIXQpIGNvbnRpbnVl
OwogICAgICAgICAgICAgICAgY29uc3QgaiA9IGxvd2VyLmluZGV4T2YodCwgaSk7CiAgICAgICAg
ICAgICAgICBpZiAoaiA8IDApIGNvbnRpbnVlOwogICAgICAgICAgICAgICAgaWYgKGJlc3RKIDwg
MCB8fCBqIDwgYmVzdEogfHwgKGogPT09IGJlc3RKICYmIHQubGVuZ3RoID4gYmVzdExlbikpIHsK
ICAgICAgICAgICAgICAgICAgICBiZXN0SiA9IGo7IGJlc3RMZW4gPSB0Lmxlbmd0aDsKICAgICAg
ICAgICAgICAgIH0KICAgICAgICAgICAgfQogICAgICAgICAgICBpZiAoYmVzdEogPCAwKSB7IG91
dCArPSBlc2NIdG1sKHMuc2xpY2UoaSkpOyBicmVhazsgfQogICAgICAgICAgICBvdXQgKz0gZXNj
SHRtbChzLnNsaWNlKGksIGJlc3RKKSk7CiAgICAgICAgICAgIG91dCArPSAnPG1hcmsgY2xhc3M9
InEtaGwiPicgKyBlc2NIdG1sKHMuc2xpY2UoYmVzdEosIGJlc3RKICsgYmVzdExlbikpICsgJzwv
bWFyaz4nOwogICAgICAgICAgICBpID0gYmVzdEogKyBNYXRoLm1heCgxLCBiZXN0TGVuKTsKICAg
ICAgICB9CiAgICAgICAgcmV0dXJuIG91dDsKICAgIH0KICAgIGZ1bmN0aW9uIHNldEhsVGV4dChl
bCwgdGV4dCkgewogICAgICAgIGlmICghZWwpIHJldHVybjsKICAgICAgICBjb25zdCBxID0gU3Ry
aW5nKHF1ZXJ5IHx8ICcnKS50cmltKCk7CiAgICAgICAgaWYgKCFxKSB7CiAgICAgICAgICAgIGVs
LmNsYXNzTGlzdC5yZW1vdmUoJ2hhcy1obCcpOwogICAgICAgICAgICBlbC50ZXh0Q29udGVudCA9
IHRleHQgPT0gbnVsbCA/ICcnIDogU3RyaW5nKHRleHQpOwogICAgICAgICAgICByZXR1cm47CiAg
ICAgICAgfQogICAgICAgIGVsLmNsYXNzTGlzdC5hZGQoJ2hhcy1obCcpOwogICAgICAgIGVsLmlu
bmVySFRNTCA9IGhsSHRtbCh0ZXh0KTsKICAgIH0KCgogICAgZnVuY3Rpb24gYXBwbHlUYWJTd2l0
Y2hBbmltKCkgewogICAgICAgIGlmICghdGFiU3dpdGNoQW5pbURpciB8fCAhbGlzdEVsKSByZXR1
cm47CiAgICAgICAgaWYgKCFsaXN0RWwucXVlcnlTZWxlY3RvcignLml0bSwgI2VtcHR5Lm9uLCAj
bGlzdC1tb3JlJykpCiAgICAgICAgICAgIHJldHVybjsKICAgICAgICBjb25zdCBkaXIgPSB0YWJT
d2l0Y2hBbmltRGlyOwogICAgICAgIHRhYlN3aXRjaEFuaW1EaXIgPSAwOwogICAgICAgIGxpc3RF
bC5jbGFzc0xpc3QucmVtb3ZlKCd0YWItaW4tbHInLCAndGFiLWluLXJsJyk7CiAgICAgICAgdm9p
ZCBsaXN0RWwub2Zmc2V0V2lkdGg7CiAgICAgICAgbGlzdEVsLmNsYXNzTGlzdC5hZGQoZGlyID4g
MCA/ICd0YWItaW4tbHInIDogJ3RhYi1pbi1ybCcpOwogICAgICAgIGNsZWFyVGltZW91dChsaXN0
RWwuX3RhYkFuaW1UaW1lcik7CiAgICAgICAgbGlzdEVsLl90YWJBbmltVGltZXIgPSBzZXRUaW1l
b3V0KCgpID0+IHsKICAgICAgICAgICAgbGlzdEVsLmNsYXNzTGlzdC5yZW1vdmUoJ3RhYi1pbi1s
cicsICd0YWItaW4tcmwnKTsKICAgICAgICB9LCA0MDApOwogICAgfQoKICAgIGZ1bmN0aW9uIHRh
YkluZGV4KHRhYikgewogICAgICAgIGNvbnN0IGkgPSBUQUJfT1JERVIuaW5kZXhPZih0YWIpOwog
ICAgICAgIHJldHVybiBpID49IDAgPyBpIDogMDsKICAgIH0KCiAgICBmdW5jdGlvbiBtb3ZlVGFi
SW5rKGluc3RhbnQsIHRhcmdldEVsKSB7CiAgICAgICAgY29uc3QgaW5rID0gZG9jdW1lbnQuZ2V0
RWxlbWVudEJ5SWQoJ3RhYi1pbmsnKTsKICAgICAgICBjb25zdCB0YWJzID0gZG9jdW1lbnQuZ2V0
RWxlbWVudEJ5SWQoJ3RhYnMnKTsKICAgICAgICBjb25zdCBlbCA9IHRhcmdldEVsIHx8IGRvY3Vt
ZW50LnF1ZXJ5U2VsZWN0b3IoJyN0YWJzIC50YWIub24nKTsKICAgICAgICBpZiAoIWluayB8fCAh
dGFicyB8fCAhZWwpIHJldHVybjsKICAgICAgICBjb25zdCB0ciA9IHRhYnMuZ2V0Qm91bmRpbmdD
bGllbnRSZWN0KCk7CiAgICAgICAgY29uc3QgciA9IGVsLmdldEJvdW5kaW5nQ2xpZW50UmVjdCgp
OwogICAgICAgIGNvbnN0IHggPSByLmxlZnQgLSB0ci5sZWZ0OwogICAgICAgIGNvbnN0IGggPSBN
YXRoLm1heCgyMCwgTWF0aC5yb3VuZChyLmhlaWdodCkpOwogICAgICAgIGNvbnN0IHkgPSByLnRv
cCAtIHRyLnRvcDsKICAgICAgICBjb25zdCB3ID0gTWF0aC5tYXgoMjQsIHIud2lkdGgpOwogICAg
ICAgIGNvbnN0IHBvcyA9ICd0cmFuc2xhdGUzZCgnICsgeCArICdweCwnICsgeSArICdweCwwKSc7
CiAgICAgICAgaW5rLnN0eWxlLnRyYW5zZm9ybU9yaWdpbiA9ICdjZW50ZXIgYm90dG9tJzsKICAg
ICAgICBpbmsuc3R5bGUud2lkdGggPSB3ICsgJ3B4JzsKICAgICAgICBpbmsuc3R5bGUuaGVpZ2h0
ID0gaCArICdweCc7CiAgICAgICAgaWYgKGluc3RhbnQpIHsKICAgICAgICAgICAgaW5rLnN0eWxl
LnRyYW5zaXRpb24gPSAnbm9uZSc7CiAgICAgICAgICAgIGluay5jbGFzc0xpc3QucmVtb3ZlKCdz
cXVhc2gnKTsKICAgICAgICAgICAgaW5rLnN0eWxlLnRyYW5zZm9ybSA9IHBvcyArICcgc2NhbGVY
KDEpJzsKICAgICAgICAgICAgaW5rLm9mZnNldEhlaWdodDsKICAgICAgICAgICAgaW5rLnN0eWxl
LnRyYW5zaXRpb24gPSAnJzsKICAgICAgICAgICAgcmV0dXJuOwogICAgICAgIH0KICAgICAgICAv
LyBTbmFwIHRvIGhvdmVyZWQgdGFiLCBleHBhbmQgZnJvbSBib3R0b20tY2VudGVyIOKAlCBubyBz
bGlkaW5nIGJldHdlZW4gdGFicwogICAgICAgIGluay5zdHlsZS50cmFuc2l0aW9uID0gJ25vbmUn
OwogICAgICAgIGluay5zdHlsZS50cmFuc2Zvcm0gPSBwb3MgKyAnIHNjYWxlWCgwLjAwMSknOwog
ICAgICAgIGluay5vZmZzZXRIZWlnaHQ7CiAgICAgICAgaW5rLnN0eWxlLnRyYW5zaXRpb24gPSAn
JzsKICAgICAgICBpbmsuY2xhc3NMaXN0LmFkZCgnc3F1YXNoJyk7CiAgICAgICAgaW5rLnN0eWxl
LnRyYW5zZm9ybSA9IHBvcyArICcgc2NhbGVYKDEpJzsKICAgICAgICBjbGVhclRpbWVvdXQoaW5r
Ll9zcXVhc2hUaW1lcik7CiAgICAgICAgaW5rLl9zcXVhc2hUaW1lciA9IHNldFRpbWVvdXQoKCkg
PT4gaW5rLmNsYXNzTGlzdC5yZW1vdmUoJ3NxdWFzaCcpLCAzNDApOwogICAgfQogICAgZnVuY3Rp
b24gbWFya1RhYih0YWIsIGluc3RhbnQpIHsKICAgICAgICBkb2N1bWVudC5xdWVyeVNlbGVjdG9y
QWxsKCcjdGFicyAudGFiJykuZm9yRWFjaChlbCA9PgogICAgICAgICAgICBlbC5jbGFzc0xpc3Qu
dG9nZ2xlKCdvbicsIGVsLmRhdGFzZXQudGFiID09PSB0YWIpKTsKICAgICAgICBtb3ZlVGFiSW5r
KCEhaW5zdGFudCk7CiAgICB9CiAgICBmdW5jdGlvbiBiaW5kVGFiSW5rSG92ZXIoKSB7CiAgICAg
ICAgY29uc3QgdGFicyA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd0YWJzJyk7CiAgICAgICAg
aWYgKCF0YWJzIHx8IHRhYnMuX2lua0hvdmVyQm91bmQpIHJldHVybjsKICAgICAgICB0YWJzLl9p
bmtIb3ZlckJvdW5kID0gdHJ1ZTsKICAgICAgICB0YWJzLmFkZEV2ZW50TGlzdGVuZXIoJ3BvaW50
ZXJvdmVyJywgZSA9PiB7CiAgICAgICAgICAgIGNvbnN0IHRhYiA9IGUudGFyZ2V0LmNsb3Nlc3Qo
Jy50YWInKTsKICAgICAgICAgICAgaWYgKCF0YWIgfHwgIXRhYnMuY29udGFpbnModGFiKSkgcmV0
dXJuOwogICAgICAgICAgICBtb3ZlVGFiSW5rKGZhbHNlLCB0YWIpOwogICAgICAgIH0pOwogICAg
ICAgIHRhYnMuYWRkRXZlbnRMaXN0ZW5lcigncG9pbnRlcmxlYXZlJywgZSA9PiB7CiAgICAgICAg
ICAgIGlmIChlLnJlbGF0ZWRUYXJnZXQgJiYgdGFicy5jb250YWlucyhlLnJlbGF0ZWRUYXJnZXQp
KSByZXR1cm47CiAgICAgICAgICAgIG1vdmVUYWJJbmsoZmFsc2UpOwogICAgICAgIH0pOwogICAg
fQpmdW5jdGlvbiBzZXRUYWIodGFiKSB7CiAgICAgICAgaWYgKHRhYiA9PT0gY3VyVGFiKSByZXR1
cm47CiAgICAgICAgY29uc3QgZnJvbSA9IHRhYkluZGV4KGN1clRhYik7CiAgICAgICAgY29uc3Qg
dG8gPSB0YWJJbmRleCh0YWIpOwogICAgICAgIHRhYlN3aXRjaEFuaW1EaXIgPSB0byA+IGZyb20g
PyAxIDogKHRvIDwgZnJvbSA/IC0xIDogMCk7CiAgICAgICAgY3VyVGFiID0gdGFiOwogICAgICAg
IGxvYWRpbmdNb3JlID0gZmFsc2U7CiAgICAgICAgbWFya1RhYih0YWIpOwogICAgICAgIC8vIOaJ
k+W8gOaUtuiXj+W5tuafpeeci+WQju+8jOa4hemZpOOAjOaWsOaUtuiXj+OAjee7v+eCuQogICAg
ICAgIGlmICh0YWIgPT09ICdwaW5uZWQnKQogICAgICAgICAgICBjbGVhckZhdlVuc2VlbigpOwoK
ICAgICAgICAvLyBLZWVwIHNlYXJjaCAidG9kYXkiIGZpbHRlciBpbiBzeW5jIHdoZW4gc2VhcmNo
IGlzIG9wZW4KICAgICAgICB0cnkgewogICAgICAgICAgICBjb25zdCB3cmFwID0gZG9jdW1lbnQu
Z2V0RWxlbWVudEJ5SWQoJ3NlYXJjaC13cmFwJyk7CiAgICAgICAgICAgIGNvbnN0IGJ0blRvZGF5
ID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2J0bi10b2RheScpOwogICAgICAgICAgICBpZiAo
d3JhcCAmJiB3cmFwLmNsYXNzTGlzdC5jb250YWlucygnb3BlbicpKSB7CiAgICAgICAgICAgICAg
ICBjb25zdCB3YW50VG9kYXkgPSBmYWxzZTsKICAgICAgICAgICAgICAgIGlmICh0b2RheU9ubHkg
IT09IHdhbnRUb2RheSkgewogICAgICAgICAgICAgICAgICAgIHRvZGF5T25seSA9IHdhbnRUb2Rh
eTsKICAgICAgICAgICAgICAgICAgICBpZiAoYnRuVG9kYXkpIGJ0blRvZGF5LmNsYXNzTGlzdC50
b2dnbGUoJ29uJywgdG9kYXlPbmx5KTsKICAgICAgICAgICAgICAgIH0KICAgICAgICAgICAgfQog
ICAgICAgIH0gY2F0Y2gge30KCiAgICAgICAgc2VsZWN0ZWRJZCA9IG51bGw7CiAgICAgICAgbXVs
dGlJZHMgPSBbXTsKICAgICAgICBsaXN0RWwuc2Nyb2xsVG9wID0gMDsKICAgICAgICBjb25zdCBo
aXQgPSB2aWV3TWVtLmdldCh2aWV3TWVtS2V5KHRhYiwgcXVlcnksIHRvZGF5T25seSkpOwogICAg
ICAgIGlmIChoaXQgJiYgQXJyYXkuaXNBcnJheShoaXQuaXRlbXMpICYmIGhpdC5pdGVtcy5sZW5n
dGgpIHsKICAgICAgICAgICAgYWxsQ2xpcHMgPSBoaXQuaXRlbXMuc2xpY2UoKTsKICAgICAgICAg
ICAgZGlza1RvdGFsID0gTnVtYmVyKGhpdC50b3RhbCkgfHwgaGl0Lml0ZW1zLmxlbmd0aDsKICAg
ICAgICAgICAgd2luZG93Ll9fd2FpdGluZ1ZpZXcgPSBmYWxzZTsKICAgICAgICAgICAgY2xlYXJX
YWl0aW5nRGF0YSgpOwogICAgICAgICAgICB3aW5kb3cuX19kYXRhUmVhZHkgPSB0cnVlOwogICAg
ICAgICAgICBob3N0UHVzaGVkT25jZSA9IHRydWU7CiAgICAgICAgICAgIHNhd05vbkVtcHR5ID0g
dHJ1ZTsKICAgICAgICAgICAgcmVuZGVyKCk7CiAgICAgICAgICAgIGFwcGx5VGFiU3dpdGNoQW5p
bSgpOwogICAgICAgICAgICAvLyBNZW1vcnkgcGFpbnQgZmlyc3Qg4oCUYmFja2dyb3VuZCBzb2Z0
LXN5bmMga2VlcHMgQUhLIGluIHN0ZXAgd2l0aG91dCBkb3VibGUgcmVkcmF3CiAgICAgICAgICAg
IHNvZnRSZXF1ZXN0VmlldygpOwogICAgICAgICAgICByZXR1cm47CiAgICAgICAgfQogICAgICAg
IC8vIE5vIGNhY2hlIHlldDoga2VlcCBjdXJyZW50IHJvd3Mg4oCUIE5FVkVSIHdpcGUgdG8gYmxh
bmsgd2hpdGUKICAgICAgICB3aW5kb3cuX193YWl0aW5nVmlldyA9IHRydWU7CiAgICAgICAgc2No
ZWR1bGVEZWxheWVkU2tlbCgpOwogICAgICAgIGlmICghYWxsQ2xpcHMubGVuZ3RoKQogICAgICAg
ICAgICByZW5kZXIoKTsKICAgICAgICByZXF1ZXN0VmlldygpOwogICAgICAgIGFwcGx5VGFiU3dp
dGNoQW5pbSgpOwogICAgfQoKICAgIG1vdmVUYWJJbmsodHJ1ZSk7CiAgICBiaW5kVGFiSW5rSG92
ZXIoKTsKICAgIHRyeSB7IG5ldyBSZXNpemVPYnNlcnZlcigoKSA9PiBtb3ZlVGFiSW5rKHRydWUp
KS5vYnNlcnZlKGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd0YWJzJykpOyB9IGNhdGNoIHt9CiAg
ICB3aW5kb3cuYWRkRXZlbnRMaXN0ZW5lcigncmVzaXplJywgKCkgPT4gbW92ZVRhYkluayh0cnVl
KSk7CgogICAgZnVuY3Rpb24gdXBkYXRlTW9yZUZvb3Rlcih0b3RhbCkgewogICAgICAgIGxldCBt
b3JlRWwgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbGlzdC1tb3JlJyk7CiAgICAgICAgY29u
c3QgbG9hZGVkID0gYWxsQ2xpcHMubGVuZ3RoOwogICAgICAgIGlmIChsb2FkZWQgPj0gdG90YWwp
IHsKICAgICAgICAgICAgaWYgKG1vcmVFbCkgbW9yZUVsLnJlbW92ZSgpOwogICAgICAgICAgICBy
ZXR1cm47CiAgICAgICAgfQogICAgICAgIGlmICghbW9yZUVsKSB7CiAgICAgICAgICAgIG1vcmVF
bCA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOwogICAgICAgICAgICBtb3JlRWwuaWQg
PSAnbGlzdC1tb3JlJzsKICAgICAgICAgICAgbW9yZUVsLmNsYXNzTmFtZSA9ICdsaXN0LW1vcmUn
OwogICAgICAgICAgICBsaXN0RWwuYXBwZW5kQ2hpbGQobW9yZUVsKTsKICAgICAgICB9CiAgICAg
ICAgbW9yZUVsLnRleHRDb250ZW50ID0gJ+e7p+e7reS4i+a7keS7juejgeebmOWKoOi9ve+8iCcg
KyBsb2FkZWQgKyAnLycgKyB0b3RhbCArICfvvIknOwogICAgfQoKICAgIC8qKiBVcGRhdGUgYmFy
IC8gcGluIGJhZGdlIHdpdGhvdXQgdG91Y2hpbmcgdGhlIGxpc3QgRE9NICovCiAgICBmdW5jdGlv
biByZWZyZXNoTGlzdENocm9tZSgpIHsKICAgICAgICBjb25zdCB2aXNpYmxlID0gdmlzaWJsZUxp
c3QoKTsKICAgICAgICBjb25zdCBsb2FkZWQgPSBhbGxDbGlwcy5sZW5ndGg7CiAgICAgICAgY29u
c3Qgc2hvd25Db3VudCA9IHZpc2libGUubGVuZ3RoOwogICAgICAgIGxldCBwaW5uZWROID0gTnVt
YmVyKHBpbm5lZFRvdGFsKSB8fCAwOwogICAgICAgIGlmIChwaW5uZWROIDwgMSkgewogICAgICAg
ICAgICBpZiAoY3VyVGFiID09PSAncGlubmVkJykKICAgICAgICAgICAgICAgIHBpbm5lZE4gPSBN
YXRoLm1heChOdW1iZXIoZGlza1RvdGFsKSB8fCAwLCBsb2FkZWQpOwogICAgICAgICAgICBlbHNl
CiAgICAgICAgICAgICAgICBwaW5uZWROID0gYWxsQ2xpcHMuZmlsdGVyKGMgPT4gaXNQaW5uZWQo
YykpLmxlbmd0aDsKICAgICAgICB9CiAgICAgICAgdXBkYXRlUGluRG90KCk7CiAgICAgICAgbGV0
IHNob3dUb3RhbCA9IGRpc2tUb3RhbCA+IDAgPyBkaXNrVG90YWwgOiAobG9hZGVkIHx8IDApOwog
ICAgICAgIGlmIChjdXJUYWIgPT09ICdwaW5uZWQnICYmIHBpbm5lZE4gPiBzaG93VG90YWwpCiAg
ICAgICAgICAgIHNob3dUb3RhbCA9IHBpbm5lZE47CiAgICAgICAgY29uc3QgcU9uID0gU3RyaW5n
KHF1ZXJ5IHx8ICcnKS50cmltKCkubGVuZ3RoID4gMDsKICAgICAgICBjb25zdCBiYXIgPSBkb2N1
bWVudC5nZXRFbGVtZW50QnlJZCgnYmFyLXR4dCcpOwogICAgICAgIGlmIChiYXIpIHsKICAgICAg
ICAgICAgYmFyLnRleHRDb250ZW50ID0gcU9uCiAgICAgICAgICAgICAgICA/IChzaG93bkNvdW50
ICsgJyDmnaEnKQogICAgICAgICAgICAgICAgOiAoc2hvd1RvdGFsID4gbG9hZGVkID8gKHNob3du
Q291bnQgKyAnIC8gJyArIHNob3dUb3RhbCArICcg5p2hJykgOiAoc2hvd1RvdGFsICsgJyDmnaEn
KSk7CiAgICAgICAgfQogICAgICAgIHVwZGF0ZU1vcmVGb290ZXIoZGlza1RvdGFsKTsKICAgICAg
ICB1cGRhdGVUb3BCdG4oKTsKICAgIH0KCiAgICAvKioKICAgICAqIExvYWQtbW9yZTogYXBwZW5k
IG9ubHkgbmV3IERPTSBub2Rlcy4gRnVsbCByZW5kZXIoKSBudWtlcyBldmVyeSAuaXRtIGFuZAog
ICAgICogcmVzdG9yZXMgc2Nyb2xsVG9wIOKAlCB0aGF0IGhpdGNoIGlzIHdoYXQgbWFrZXMgZHJh
Z2dpbmcgdGhlIHNjcm9sbGJhciBmZWVsIHN0aWNreS4KICAgICAqLwogICAgZnVuY3Rpb24gYXBw
ZW5kUmVuZGVyKHByZXZMZW4pIHsKICAgICAgICBjb25zdCB2aXNpYmxlID0gdmlzaWJsZUxpc3Qo
KTsKICAgICAgICBpZiAoIXZpc2libGUubGVuZ3RoKSB7CiAgICAgICAgICAgIHJlbmRlcigpOwog
ICAgICAgICAgICByZXR1cm4gZmFsc2U7CiAgICAgICAgfQogICAgICAgIGlmIChwcmV2TGVuID4g
MCAmJiBwcmV2TGVuIDwgYWxsQ2xpcHMubGVuZ3RoKSB7CiAgICAgICAgICAgIGNvbnN0IHNlYW1H
aWRzID0gbmV3IFNldCgpOwogICAgICAgICAgICBmb3IgKGxldCBpID0gTWF0aC5tYXgoMCwgcHJl
dkxlbiAtIDgpOyBpIDwgTWF0aC5taW4oYWxsQ2xpcHMubGVuZ3RoLCBwcmV2TGVuICsgOCk7IGkr
KykgewogICAgICAgICAgICAgICAgY29uc3QgZyA9IGZhdkdyb3VwT2YoYWxsQ2xpcHNbaV0pOwog
ICAgICAgICAgICAgICAgaWYgKGcpIHNlYW1HaWRzLmFkZChnKTsKICAgICAgICAgICAgfQogICAg
ICAgICAgICBpZiAoc2VhbUdpZHMuc2l6ZSkgewogICAgICAgICAgICAgICAgZm9yIChjb25zdCBn
IG9mIHNlYW1HaWRzKSB7CiAgICAgICAgICAgICAgICAgICAgbGV0IGJlZm9yZSA9IDAsIGFmdGVy
ID0gMDsKICAgICAgICAgICAgICAgICAgICBmb3IgKGxldCBpID0gMDsgaSA8IGFsbENsaXBzLmxl
bmd0aDsgaSsrKSB7CiAgICAgICAgICAgICAgICAgICAgICAgIGlmIChmYXZHcm91cE9mKGFsbENs
aXBzW2ldKSAhPT0gZykgY29udGludWU7CiAgICAgICAgICAgICAgICAgICAgICAgIGlmIChpIDwg
cHJldkxlbikgYmVmb3JlKys7CiAgICAgICAgICAgICAgICAgICAgICAgIGVsc2UgYWZ0ZXIrKzsK
ICAgICAgICAgICAgICAgICAgICB9CiAgICAgICAgICAgICAgICAgICAgaWYgKGJlZm9yZSA+IDAg
JiYgYWZ0ZXIgPiAwKSB7CiAgICAgICAgICAgICAgICAgICAgICAgIHJlbmRlcigpOwogICAgICAg
ICAgICAgICAgICAgICAgICByZXR1cm4gZmFsc2U7CiAgICAgICAgICAgICAgICAgICAgfQogICAg
ICAgICAgICAgICAgfQogICAgICAgICAgICB9CiAgICAgICAgfQogICAgICAgIGNvbnN0IGJsb2Nr
cyA9IGJ1aWxkUGlubmVkQmxvY2tzKHZpc2libGUpOwogICAgICAgIGNvbnN0IGV4aXN0aW5nID0g
bGlzdEVsLnF1ZXJ5U2VsZWN0b3JBbGwoJy5pdG0nKS5sZW5ndGg7CiAgICAgICAgaWYgKGV4aXN0
aW5nIDwgMSkgewogICAgICAgICAgICByZW5kZXIoKTsKICAgICAgICAgICAgcmV0dXJuIGZhbHNl
OwogICAgICAgIH0KICAgICAgICBpZiAoYmxvY2tzLmxlbmd0aCA8PSBleGlzdGluZykgewogICAg
ICAgICAgICByZWZyZXNoTGlzdENocm9tZSgpOwogICAgICAgICAgICB0cnkgeyBtYXJrUXVldWVS
YWlscygpOyB9IGNhdGNoIChlKSB7fQogICAgICAgICAgICByZXR1cm4gdHJ1ZTsKICAgICAgICB9
CiAgICAgICAgY29uc3QgZnJhZyA9IGRvY3VtZW50LmNyZWF0ZURvY3VtZW50RnJhZ21lbnQoKTsK
ICAgICAgICBsZXQgbnVtID0gMDsKICAgICAgICBibG9ja3MuZm9yRWFjaChiID0+IHsKICAgICAg
ICAgICAgbnVtICs9IDE7CiAgICAgICAgICAgIGlmIChudW0gPD0gZXhpc3RpbmcpIHJldHVybjsK
ICAgICAgICAgICAgaWYgKGIua2luZCA9PT0gJ2dyb3VwJyAmJiBiLml0ZW1zLmxlbmd0aCA+IDEp
CiAgICAgICAgICAgICAgICBmcmFnLmFwcGVuZENoaWxkKG1ha2VHcm91cEl0ZW0oYi5pdGVtcywg
bnVtKSk7CiAgICAgICAgICAgIGVsc2UKICAgICAgICAgICAgICAgIGZyYWcuYXBwZW5kQ2hpbGQo
bWFrZUl0ZW0oYi5pdGVtc1swXSwgbnVtKSk7CiAgICAgICAgfSk7CiAgICAgICAgY29uc3QgbW9y
ZUVsID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2xpc3QtbW9yZScpOwogICAgICAgIGlmICht
b3JlRWwpCiAgICAgICAgICAgIGxpc3RFbC5pbnNlcnRCZWZvcmUoZnJhZywgbW9yZUVsKTsKICAg
ICAgICBlbHNlCiAgICAgICAgICAgIGxpc3RFbC5hcHBlbmRDaGlsZChmcmFnKTsKICAgICAgICB0
cnkgeyBtYXJrUXVldWVSYWlscygpOyB9IGNhdGNoIChlKSB7fQogICAgICAgIHJlZnJlc2hMaXN0
Q2hyb21lKCk7CiAgICAgICAgcmVxdWVzdEFuaW1hdGlvbkZyYW1lKCgpID0+IHsKICAgICAgICAg
ICAgaWYgKGFsbENsaXBzLmxlbmd0aCA8IGRpc2tUb3RhbAogICAgICAgICAgICAgICAgJiYgbGlz
dEVsLnNjcm9sbEhlaWdodCA8PSBsaXN0RWwuY2xpZW50SGVpZ2h0ICsgMjApCiAgICAgICAgICAg
ICAgICByZXF1ZXN0TW9yZSgpOwogICAgICAgICAgICB0cnkgeyBzY2hlZHVsZUZpbGVHb25lQ2hl
Y2soKTsgfSBjYXRjaCB7fQogICAgICAgIH0pOwogICAgICAgIHJldHVybiB0cnVlOwogICAgfQoK
ICAgIGZ1bmN0aW9uIGFwcGx5QXBwZW5kUGF5bG9hZChwZW5kaW5nKSB7CiAgICAgICAgaWYgKCFw
ZW5kaW5nIHx8IHBlbmRpbmcuZnJvbUxlbiA9PSBudWxsKSByZXR1cm47CiAgICAgICAgY29uc3Qg
ZnJvbUxlbiA9IE51bWJlcihwZW5kaW5nLmZyb21MZW4pIHx8IDA7CiAgICAgICAgaWYgKGZyb21M
ZW4gPCAwIHx8IGFsbENsaXBzLmxlbmd0aCA8PSBmcm9tTGVuKSB7CiAgICAgICAgICAgIHJlZnJl
c2hMaXN0Q2hyb21lKCk7CiAgICAgICAgICAgIHJldHVybjsKICAgICAgICB9CiAgICAgICAgYXBw
ZW5kUmVuZGVyKGZyb21MZW4pOwogICAgfQoKICAgIGZ1bmN0aW9uIG5hdkxpc3QoKSB7CiAgICAg
ICAgY29uc3QgYmxvY2tzID0gYnVpbGRQaW5uZWRCbG9ja3ModmlzaWJsZUxpc3QoKSk7CiAgICAg
ICAgY29uc3Qgb3V0ID0gW107CiAgICAgICAgZm9yIChjb25zdCBiIG9mIGJsb2NrcykgewogICAg
ICAgICAgICBpZiAoIWIgfHwgIWIuaXRlbXMpIGNvbnRpbnVlOwogICAgICAgICAgICBmb3IgKGNv
bnN0IGMgb2YgYi5pdGVtcykgb3V0LnB1c2goYyk7CiAgICAgICAgfQogICAgICAgIHJldHVybiBv
dXQ7CiAgICB9CgogICAgZnVuY3Rpb24gc2VsZWN0QnlJbmRleChpZHgpIHsKICAgICAgICBjb25z
dCB2aXMgPSBuYXZMaXN0KCk7CiAgICAgICAgaWYgKCF2aXMubGVuZ3RoKSByZXR1cm47CiAgICAg
ICAgaWR4ID0gTWF0aC5tYXgoMCwgTWF0aC5taW4odmlzLmxlbmd0aCAtIDEsIGlkeCkpOwogICAg
ICAgIGlmIChpZHggPj0gdmlzLmxlbmd0aCAtIDEgJiYgYWxsQ2xpcHMubGVuZ3RoIDwgZGlza1Rv
dGFsKQogICAgICAgICAgICByZXF1ZXN0TW9yZSgpOwogICAgICAgIHNlbGVjdGVkSWQgPSB2aXNb
TWF0aC5taW4oaWR4LCB2aXMubGVuZ3RoIC0gMSldLmlkOwogICAgICAgIHJhbmdlQW5jaG9ySWQg
PSBzZWxlY3RlZElkOwogICAgICAgIHJhbmdlQW5jaG9yQ2xpY2tlZCA9IGZhbHNlOwogICAgICAg
IGlmICgrc2VsZWN0ZWRJZCAhPT0gK2xhc3RQYXN0ZUlkKQogICAgICAgICAgICBsb2NhdGVBY3Rp
dmUgPSBmYWxzZTsKICAgICAgICB1cGRhdGVMb2NhdGVCdG4oKTsKICAgICAgICBzeW5jSXRlbUhp
Z2hsaWdodCgpOwogICAgICAgIGNvbnN0IGVsID0gbGlzdEVsLnF1ZXJ5U2VsZWN0b3IoJy5tZy1y
b3dbZGF0YS1pZD0iJyArIHNlbGVjdGVkSWQgKyAnIl0nKQogICAgICAgICAgICB8fCBsaXN0RWwu
cXVlcnlTZWxlY3RvcignLml0bVtkYXRhLWlkPSInICsgc2VsZWN0ZWRJZCArICciXScpOwogICAg
ICAgIGlmIChlbCkgZWwuc2Nyb2xsSW50b1ZpZXcoeyBibG9jazogJ25lYXJlc3QnIH0pOwogICAg
fQoKICAgIGZ1bmN0aW9uIHNlbGVjdGVkSW5kZXgoKSB7CiAgICAgICAgcmV0dXJuIG5hdkxpc3Qo
KS5maW5kSW5kZXgoYyA9PiBjLmlkID09IHNlbGVjdGVkSWQpOwogICAgfQoKICAgIGZ1bmN0aW9u
IHN5bmNJdGVtSGlnaGxpZ2h0KCkgewogICAgICAgIGRvY3VtZW50LnF1ZXJ5U2VsZWN0b3JBbGwo
Jy5pdG0nKS5mb3JFYWNoKG4gPT4gewogICAgICAgICAgICBpZiAobi5jbGFzc0xpc3QuY29udGFp
bnMoJ2l0LWdyb3VwJykpIHsKICAgICAgICAgICAgICAgIGNvbnN0IHJvd3MgPSBbLi4ubi5xdWVy
eVNlbGVjdG9yQWxsKCcubWctcm93JyldOwogICAgICAgICAgICAgICAgY29uc3QgaWRzID0gcm93
cy5tYXAociA9PiArci5kYXRhc2V0LmlkKTsKICAgICAgICAgICAgICAgIGNvbnN0IGFueVNlbCA9
IGlkcy5pbmNsdWRlcygrc2VsZWN0ZWRJZCkgfHwgaWRzLnNvbWUoaWQgPT4gbXVsdGlJZHMuaW5j
bHVkZXMoaWQpKTsKICAgICAgICAgICAgICAgIG4uY2xhc3NMaXN0LnRvZ2dsZSgnc2VsJywgYW55
U2VsKTsKICAgICAgICAgICAgICAgIG4uY2xhc3NMaXN0LnRvZ2dsZSgnbXVsdGknLCBpZHMuc29t
ZShpZCA9PiBtdWx0aUlkcy5pbmNsdWRlcyhpZCkpKTsKICAgICAgICAgICAgICAgIHJvd3MuZm9y
RWFjaChyID0+IHsKICAgICAgICAgICAgICAgICAgICBjb25zdCBpZCA9ICtyLmRhdGFzZXQuaWQ7
CiAgICAgICAgICAgICAgICAgICAgY29uc3QgaW5NdWx0aSA9IG11bHRpSWRzLmluY2x1ZGVzKGlk
KTsKICAgICAgICAgICAgICAgICAgICByLmNsYXNzTGlzdC50b2dnbGUoJ3NlbCcsIGlkID09IHNl
bGVjdGVkSWQgfHwgaW5NdWx0aSk7CiAgICAgICAgICAgICAgICAgICAgci5jbGFzc0xpc3QudG9n
Z2xlKCdtdWx0aScsIGluTXVsdGkpOwogICAgICAgICAgICAgICAgfSk7CiAgICAgICAgICAgICAg
ICByZXR1cm47CiAgICAgICAgICAgIH0KICAgICAgICAgICAgY29uc3QgaWQgPSArbi5kYXRhc2V0
LmlkOwogICAgICAgICAgICBjb25zdCBpbk11bHRpID0gbXVsdGlJZHMuaW5jbHVkZXMoaWQpOwog
ICAgICAgICAgICBuLmNsYXNzTGlzdC50b2dnbGUoJ3NlbCcsIGlkID09IHNlbGVjdGVkSWQgfHwg
aW5NdWx0aSk7CiAgICAgICAgICAgIG4uY2xhc3NMaXN0LnRvZ2dsZSgnbXVsdGknLCBpbk11bHRp
KTsKICAgICAgICB9KTsKICAgIH0KICAgIGZ1bmN0aW9uIHVwZGF0ZU11bHRpQmFkZ2UoKSB7CiAg
ICAgICAgY29uc3QgYmFyID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ211bHRpLWJhcicpOwog
ICAgICAgIGNvbnN0IGVsID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ211bHRpLWNudCcpOwog
ICAgICAgIGlmIChtdWx0aUlkcy5sZW5ndGggPiAwKSB7CiAgICAgICAgICAgIGlmIChlbCkgZWwu
dGV4dENvbnRlbnQgPSBTdHJpbmcobXVsdGlJZHMubGVuZ3RoKTsKICAgICAgICAgICAgaWYgKGJh
cikgewogICAgICAgICAgICAgICAgY29uc3Qgd2FzT2ZmID0gIWJhci5jbGFzc0xpc3QuY29udGFp
bnMoJ29uJyk7CiAgICAgICAgICAgICAgICBiYXIuY2xhc3NMaXN0LmFkZCgnb24nKTsKICAgICAg
ICAgICAgICAgIGlmICh3YXNPZmYpIHJlc2V0UGFzdGVTZXBEZWZhdWx0KCk7CiAgICAgICAgICAg
IH0KICAgICAgICB9IGVsc2UgewogICAgICAgICAgICBpZiAoYmFyKSBiYXIuY2xhc3NMaXN0LnJl
bW92ZSgnb24nKTsKICAgICAgICAgICAgY2xvc2VTZXBNZW51KCk7CiAgICAgICAgfQogICAgICAg
IHN5bmNJdGVtSGlnaGxpZ2h0KCk7CiAgICB9CgogICAgY29uc3QgU0VQX05FV0xJTkVfVE9LRU4g
PSAnW+aNouihjF0nOwogICAgLy8g5Zu65a6a5bi455So5YiG6ZqU56ym77yb6Ieq5a6a5LmJ5LiN
6L+b5YiX6KGoCiAgICBjb25zdCBTRVBfTElTVCA9IFsnICcsIFNFUF9ORVdMSU5FX1RPS0VOLCAn
LCcsICcsICcsICfjgIEnLCAnfCcsICdbIiIsIiJdJywgIignJywnJykiXTsKICAgIGxldCBwYXN0
ZVNlcFZhbHVlID0gJyAnOwoKICAgIGZ1bmN0aW9uIG5vcm1hbGl6ZVNlcElucHV0KHJhdykgewog
ICAgICAgIGxldCBzID0gU3RyaW5nKHJhdyA/PyAnJyk7CiAgICAgICAgaWYgKHMgPT09ICcnKSBy
ZXR1cm4gJyAnOwogICAgICAgIGNvbnN0IHQgPSBzLnRyaW0oKTsKICAgICAgICBpZiAodCA9PT0g
U0VQX05FV0xJTkVfVE9LRU4gfHwgdCA9PT0gJ+aNouihjCcgfHwgdCA9PT0gJ1xcbicgfHwgdCA9
PT0gJ1xuJyB8fCB0ID09PSAnXHJcbicpCiAgICAgICAgICAgIHJldHVybiBTRVBfTkVXTElORV9U
T0tFTjsKICAgICAgICBpZiAodCA9PT0gJ1xcdCcgfHwgdCA9PT0gJ1x0JykgcmV0dXJuICdcdCc7
CiAgICAgICAgcmV0dXJuIHM7CiAgICB9CiAgICBmdW5jdGlvbiBzZXBUb0FjdHVhbChyYXcpIHsK
ICAgICAgICBjb25zdCBzID0gbm9ybWFsaXplU2VwSW5wdXQocmF3KTsKICAgICAgICByZXR1cm4g
cyA9PT0gU0VQX05FV0xJTkVfVE9LRU4gPyAnXG4nIDogczsKICAgIH0KICAgIGZ1bmN0aW9uIHNl
cFRvQnJpZGdlKHJhdykgewogICAgICAgIGNvbnN0IHMgPSBub3JtYWxpemVTZXBJbnB1dChyYXcp
OwogICAgICAgIGlmIChzID09PSBTRVBfTkVXTElORV9UT0tFTiB8fCBzID09PSAnXG4nIHx8IHMg
PT09ICdcclxuJykgcmV0dXJuIFNFUF9ORVdMSU5FX1RPS0VOOwogICAgICAgIGlmIChzID09PSAn
XHQnKSByZXR1cm4gJ1vliLbooajnrKZdJzsKICAgICAgICByZXR1cm4gczsKICAgIH0KICAgIGZ1
bmN0aW9uIHNlcERpc3BsYXlTeW1ib2wocmF3KSB7CiAgICAgICAgY29uc3QgcyA9IG5vcm1hbGl6
ZVNlcElucHV0KHJhdyk7CiAgICAgICAgaWYgKHMgPT09ICcgJykgcmV0dXJuICfikKMnOwogICAg
ICAgIGlmIChzID09PSBTRVBfTkVXTElORV9UT0tFTiB8fCBzID09PSAnXG4nIHx8IHMgPT09ICdc
clxuJykgcmV0dXJuICfihrUnOwogICAgICAgIGlmIChzID09PSAnXHQnKSByZXR1cm4gJ+KHpSc7
CiAgICAgICAgaWYgKHMgPT09ICcsJykgcmV0dXJuICcsJzsKICAgICAgICBpZiAocyA9PT0gJywg
JykgcmV0dXJuICcs4pCjJzsKICAgICAgICBpZiAocyA9PT0gJ+OAgScpIHJldHVybiAn44CBJzsK
ICAgICAgICBpZiAocyA9PT0gJ3wnKSByZXR1cm4gJ3wnOwogICAgICAgIGlmIChzID09PSAnWyIi
LCIiXScpIHJldHVybiAnWyIiLCIiXSc7CiAgICAgICAgaWYgKHMgPT09ICIoJycsJycpIikgcmV0
dXJuICIoJycsJycpIjsKICAgICAgICByZXR1cm4gcy5yZXBsYWNlKC9cclxuL2csICfihrUnKS5y
ZXBsYWNlKC9cbi9nLCAn4oa1JykucmVwbGFjZSgvXHQvZywgJ+KHpScpLnJlcGxhY2UoL1xyL2cs
ICcnKTsKICAgIH0KICAgIGZ1bmN0aW9uIHNlcERpc3BsYXlOYW1lKHJhdykgewogICAgICAgIGNv
bnN0IHMgPSBub3JtYWxpemVTZXBJbnB1dChyYXcpOwogICAgICAgIGlmIChzID09PSAnICcpIHJl
dHVybiAn56m65qC8JzsKICAgICAgICBpZiAocyA9PT0gU0VQX05FV0xJTkVfVE9LRU4gfHwgcyA9
PT0gJ1xuJyB8fCBzID09PSAnXHJcbicpIHJldHVybiAn5o2i6KGMJzsKICAgICAgICBpZiAocyA9
PT0gJ1x0JykgcmV0dXJuICfliLbooajnrKYnOwogICAgICAgIGlmIChzID09PSAnLCcpIHJldHVy
biAn6YCX5Y+3JzsKICAgICAgICBpZiAocyA9PT0gJywgJykgcmV0dXJuICfpgJflj7fnqbrmoLwn
OwogICAgICAgIGlmIChzID09PSAn44CBJykgcmV0dXJuICfpob/lj7cnOwogICAgICAgIGlmIChz
ID09PSAnfCcpIHJldHVybiAn56uW57q/JzsKICAgICAgICBpZiAocyA9PT0gJ1siIiwiIl0nKSBy
ZXR1cm4gJ+WIl+ihqDEnOwogICAgICAgIGlmIChzID09PSAiKCcnLCcnKSIpIHJldHVybiAn5YiX
6KGoMic7CiAgICAgICAgcmV0dXJuICcnOwogICAgfQogICAgZnVuY3Rpb24gZmlsbFNlcE1lbnVJ
dGVtKGJ0biwgdikgewogICAgICAgIGJ0bi5pbm5lckhUTUwgPSAnJzsKICAgICAgICBjb25zdCBz
eW0gPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdzcGFuJyk7CiAgICAgICAgc3ltLmNsYXNzTmFt
ZSA9ICdwYXN0ZS1zZXAtc3ltJyArIChzZXBEaXNwbGF5TmFtZSh2KSA/ICcnIDogJyBvbmx5Jyk7
CiAgICAgICAgc3ltLnRleHRDb250ZW50ID0gc2VwRGlzcGxheVN5bWJvbCh2KTsKICAgICAgICBi
dG4uYXBwZW5kQ2hpbGQoc3ltKTsKICAgICAgICBjb25zdCBuYW1lID0gc2VwRGlzcGxheU5hbWUo
dik7CiAgICAgICAgaWYgKG5hbWUpIHsKICAgICAgICAgICAgY29uc3QgbGFiID0gZG9jdW1lbnQu
Y3JlYXRlRWxlbWVudCgnc3BhbicpOwogICAgICAgICAgICBsYWIuY2xhc3NOYW1lID0gJ3Bhc3Rl
LXNlcC1uYW1lJzsKICAgICAgICAgICAgbGFiLnRleHRDb250ZW50ID0gbmFtZTsKICAgICAgICAg
ICAgYnRuLmFwcGVuZENoaWxkKGxhYik7CiAgICAgICAgfQogICAgfQogICAgZnVuY3Rpb24gdXBk
YXRlU2VwTGFiZWwoKSB7CiAgICAgICAgY29uc3QgbGFiID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5
SWQoJ3Bhc3RlLXNlcC1sYWJlbCcpOwogICAgICAgIGlmIChsYWIpIGxhYi50ZXh0Q29udGVudCA9
IHNlcERpc3BsYXlTeW1ib2wocGFzdGVTZXBWYWx1ZSk7CiAgICB9CiAgICBmdW5jdGlvbiBhcHBs
eVNlcGFyYXRvcihyYXcsIG9wdHMgPSB7fSkgewogICAgICAgIGNvbnN0IGRvUGFzdGUgPSBvcHRz
LnBhc3RlICE9IG51bGwgPyBvcHRzLnBhc3RlIDogbXVsdGlJZHMubGVuZ3RoID4gMDsKICAgICAg
ICBwYXN0ZVNlcFZhbHVlID0gbm9ybWFsaXplU2VwSW5wdXQocmF3KTsKICAgICAgICB1cGRhdGVT
ZXBMYWJlbCgpOwogICAgICAgIGNsb3NlU2VwTWVudSgpOwogICAgICAgIGlmIChkb1Bhc3RlKSBw
YXN0ZU11bHRpU2VsZWN0aW9uKCk7CiAgICB9CiAgICBmdW5jdGlvbiBjbG9zZVNlcE1lbnUoKSB7
CiAgICAgICAgY29uc3QgbWVudSA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdwYXN0ZS1zZXAt
bWVudScpOwogICAgICAgIGNvbnN0IGJ0biA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdwYXN0
ZS1zZXAtYnRuJyk7CiAgICAgICAgaWYgKG1lbnUpIG1lbnUuY2xhc3NMaXN0LnJlbW92ZSgnb24n
KTsKICAgICAgICBpZiAoYnRuKSBidG4uY2xhc3NMaXN0LnJlbW92ZSgnb3BlbicpOwogICAgfQog
ICAgZnVuY3Rpb24gcmVuZGVyU2VwTWVudSgpIHsKICAgICAgICBjb25zdCBtZW51ID0gZG9jdW1l
bnQuZ2V0RWxlbWVudEJ5SWQoJ3Bhc3RlLXNlcC1tZW51Jyk7CiAgICAgICAgaWYgKCFtZW51KSBy
ZXR1cm47CiAgICAgICAgbWVudS5pbm5lckhUTUwgPSAnJzsKICAgICAgICBmb3IgKGNvbnN0IHYg
b2YgU0VQX0xJU1QpIHsKICAgICAgICAgICAgY29uc3QgYiA9IGRvY3VtZW50LmNyZWF0ZUVsZW1l
bnQoJ2J1dHRvbicpOwogICAgICAgICAgICBiLnR5cGUgPSAnYnV0dG9uJzsKICAgICAgICAgICAg
Yi5jbGFzc05hbWUgPSAncGFzdGUtc2VwLWl0ZW0nICsgKHYgPT09IHBhc3RlU2VwVmFsdWUgPyAn
IHNlbCcgOiAnJyk7CiAgICAgICAgICAgIGZpbGxTZXBNZW51SXRlbShiLCB2KTsKICAgICAgICAg
ICAgYi5vbmNsaWNrID0gZSA9PiB7CiAgICAgICAgICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigp
OwogICAgICAgICAgICAgICAgYXBwbHlTZXBhcmF0b3Iodik7CiAgICAgICAgICAgIH07CiAgICAg
ICAgICAgIG1lbnUuYXBwZW5kQ2hpbGQoYik7CiAgICAgICAgfQogICAgICAgIGNvbnN0IGZvb3Qg
PSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsKICAgICAgICBmb290LmNsYXNzTmFtZSA9
ICdwYXN0ZS1zZXAtZm9vdCc7CiAgICAgICAgY29uc3QgaW5wID0gZG9jdW1lbnQuY3JlYXRlRWxl
bWVudCgnaW5wdXQnKTsKICAgICAgICBpbnAuaWQgPSAncGFzdGUtc2VwLWN1c3RvbSc7CiAgICAg
ICAgaW5wLnR5cGUgPSAndGV4dCc7CiAgICAgICAgaW5wLnNpemUgPSAxOwogICAgICAgIGlucC5w
bGFjZWhvbGRlciA9ICfoh6rlrprkuYknOwogICAgICAgIGlucC5hdXRvY29tcGxldGUgPSAnb2Zm
JzsKICAgICAgICBpbnAuc3BlbGxjaGVjayA9IGZhbHNlOwogICAgICAgIGlucC52YWx1ZSA9IFNF
UF9MSVNULmluY2x1ZGVzKHBhc3RlU2VwVmFsdWUpID8gJycgOiBwYXN0ZVNlcFZhbHVlOwogICAg
ICAgIGlucC5vbm1vdXNlZG93biA9IGUgPT4gewogICAgICAgICAgICBlLnN0b3BQcm9wYWdhdGlv
bigpOwogICAgICAgICAgICBlLnByZXZlbnREZWZhdWx0KCk7CiAgICAgICAgICAgIHRyeSB7IGFo
aygnZm9jdXNQYW5lbCcpOyB9IGNhdGNoIHt9CiAgICAgICAgICAgIGlucC5mb2N1cygpOwogICAg
ICAgIH07CiAgICAgICAgaW5wLm9uY2xpY2sgPSBlID0+IGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAg
ICAgICAgaW5wLm9uZm9jdXMgPSAoKSA9PiB7IHRyeSB7IGFoaygnZm9jdXNQYW5lbCcpOyB9IGNh
dGNoIHt9IH07CiAgICAgICAgaW5wLm9uaW5wdXQgPSBlID0+IGUuc3RvcFByb3BhZ2F0aW9uKCk7
CiAgICAgICAgaW5wLm9ua2V5ZG93biA9IGUgPT4gewogICAgICAgICAgICBlLnN0b3BQcm9wYWdh
dGlvbigpOwogICAgICAgICAgICBpZiAoZS5rZXkgPT09ICdFbnRlcicpIHsKICAgICAgICAgICAg
ICAgIGUucHJldmVudERlZmF1bHQoKTsKICAgICAgICAgICAgICAgIGlmIChpbnAudmFsdWUgIT09
ICcnKSBhcHBseVNlcGFyYXRvcihpbnAudmFsdWUpOwogICAgICAgICAgICAgICAgZWxzZSBjbG9z
ZVNlcE1lbnUoKTsKICAgICAgICAgICAgfSBlbHNlIGlmIChlLmtleSA9PT0gJ0VzY2FwZScpIHsK
ICAgICAgICAgICAgICAgIGUucHJldmVudERlZmF1bHQoKTsKICAgICAgICAgICAgICAgIGNsb3Nl
U2VwTWVudSgpOwogICAgICAgICAgICB9CiAgICAgICAgfTsKICAgICAgICBmb290LmFwcGVuZENo
aWxkKGlucCk7CiAgICAgICAgbWVudS5hcHBlbmRDaGlsZChmb290KTsKICAgIH0KICAgIGZ1bmN0
aW9uIHJlc2V0UGFzdGVTZXBEZWZhdWx0KCkgewogICAgICAgIHBhc3RlU2VwVmFsdWUgPSAnICc7
CiAgICAgICAgdXBkYXRlU2VwTGFiZWwoKTsKICAgICAgICBjbG9zZVNlcE1lbnUoKTsKICAgIH0K
ICAgIGZ1bmN0aW9uIHBhc3RlTWFueVdpdGhTZXAoaWRzKSB7CiAgICAgICAgYWhrKCdwYXN0ZU1h
bnknLCBpZHMuam9pbignLCcpLCBzZXBUb0JyaWRnZShwYXN0ZVNlcFZhbHVlKSk7CiAgICB9CiAg
ICBmdW5jdGlvbiBwYXN0ZU11bHRpU2VsZWN0aW9uKCkgewogICAgICAgIGlmICghbXVsdGlJZHMu
bGVuZ3RoKSByZXR1cm47CiAgICAgICAgY29uc3QgaWRzID0gbXVsdGlJZHMuc2xpY2UoKTsKICAg
ICAgICBjbGVhck11bHRpKCk7CiAgICAgICAgaWYgKGlkcy5zb21lKGlkID0+IHsKICAgICAgICAg
ICAgY29uc3QgaXQgPSBhbGxDbGlwcy5maW5kKHggPT4gK3guaWQgPT09ICtpZCk7CiAgICAgICAg
ICAgIHJldHVybiBpdCAmJiBub3JtVHlwZShpdC50eXBlKSA9PT0gJ3JlY2VudCc7CiAgICAgICAg
fSkpIHsKICAgICAgICAgICAgY29uc3QgZmlyc3QgPSBhbGxDbGlwcy5maW5kKHggPT4gK3guaWQg
PT09ICtpZHNbMF0pOwogICAgICAgICAgICBpZiAoZmlyc3QpIGFjdGl2YXRlQ2xpcEl0ZW0oZmly
c3QpOwogICAgICAgICAgICByZXR1cm47CiAgICAgICAgfQogICAgICAgIG1hcmtQYXN0ZWRMb2Nh
bChpZHMpOwogICAgICAgIHBhc3RlTWFueVdpdGhTZXAoaWRzKTsKICAgIH0KICAgIGZ1bmN0aW9u
IGluaXRTZXBVaSgpIHsKICAgICAgICB1cGRhdGVTZXBMYWJlbCgpOwogICAgICAgIGNvbnN0IGJ0
biA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdwYXN0ZS1zZXAtYnRuJyk7CiAgICAgICAgaWYg
KGJ0bikgewogICAgICAgICAgICBidG4uYWRkRXZlbnRMaXN0ZW5lcignY2xpY2snLCBlID0+IHsK
ICAgICAgICAgICAgICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAgICAgICAgICAgICBjb25z
dCBtZW51ID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3Bhc3RlLXNlcC1tZW51Jyk7CiAgICAg
ICAgICAgICAgICBjb25zdCBvcGVuID0gbWVudSAmJiBtZW51LmNsYXNzTGlzdC5jb250YWlucygn
b24nKTsKICAgICAgICAgICAgICAgIGlmIChvcGVuKSB7CiAgICAgICAgICAgICAgICAgICAgY29u
c3QgaW5wID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3Bhc3RlLXNlcC1jdXN0b20nKTsKICAg
ICAgICAgICAgICAgICAgICBpZiAoaW5wICYmIGlucC52YWx1ZSAhPT0gJycpIGFwcGx5U2VwYXJh
dG9yKGlucC52YWx1ZSwgeyBwYXN0ZTogbXVsdGlJZHMubGVuZ3RoID4gMCB9KTsKICAgICAgICAg
ICAgICAgICAgICBlbHNlIGNsb3NlU2VwTWVudSgpOwogICAgICAgICAgICAgICAgICAgIHJldHVy
bjsKICAgICAgICAgICAgICAgIH0KICAgICAgICAgICAgICAgIHJlbmRlclNlcE1lbnUoKTsKICAg
ICAgICAgICAgICAgIG1lbnUuY2xhc3NMaXN0LmFkZCgnb24nKTsKICAgICAgICAgICAgICAgIGJ0
bi5jbGFzc0xpc3QuYWRkKCdvcGVuJyk7CiAgICAgICAgICAgIH0pOwogICAgICAgIH0KICAgICAg
ICBkb2N1bWVudC5hZGRFdmVudExpc3RlbmVyKCdtb3VzZWRvd24nLCBlID0+IHsKICAgICAgICAg
ICAgaWYgKGUudGFyZ2V0LmNsb3Nlc3QoJyNwYXN0ZS1zZXAtd3JhcCcpKSByZXR1cm47CiAgICAg
ICAgICAgIGNvbnN0IG1lbnUgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgncGFzdGUtc2VwLW1l
bnUnKTsKICAgICAgICAgICAgaWYgKCFtZW51IHx8ICFtZW51LmNsYXNzTGlzdC5jb250YWlucygn
b24nKSkgcmV0dXJuOwogICAgICAgICAgICBjb25zdCBpbnAgPSBkb2N1bWVudC5nZXRFbGVtZW50
QnlJZCgncGFzdGUtc2VwLWN1c3RvbScpOwogICAgICAgICAgICBpZiAoaW5wICYmIGlucC52YWx1
ZSAhPT0gJycpIHsKICAgICAgICAgICAgICAgIGFwcGx5U2VwYXJhdG9yKGlucC52YWx1ZSk7CiAg
ICAgICAgICAgICAgICByZXR1cm47CiAgICAgICAgICAgIH0KICAgICAgICAgICAgY2xvc2VTZXBN
ZW51KCk7CiAgICAgICAgfSwgdHJ1ZSk7CiAgICB9CgogICAgZnVuY3Rpb24gY2xlYXJNdWx0aShy
ZXN0b3JlVG9BbmNob3IpIHsKICAgICAgICBjb25zdCBiYWNrSWQgPSArcmFuZ2VBbmNob3JJZCB8
fCAwOwogICAgICAgIG11bHRpSWRzID0gW107CiAgICAgICAgaWYgKHJlc3RvcmVUb0FuY2hvciAm
JiBiYWNrSWQpCiAgICAgICAgICAgIHNlbGVjdGVkSWQgPSBiYWNrSWQ7CiAgICAgICAgcmFuZ2VB
bmNob3JJZCA9IHNlbGVjdGVkSWQgfHwgMDsKICAgICAgICByYW5nZUFuY2hvckNsaWNrZWQgPSBm
YWxzZTsKICAgICAgICB1cGRhdGVNdWx0aUJhZGdlKCk7CiAgICAgICAgaWYgKHJlc3RvcmVUb0Fu
Y2hvciAmJiBzZWxlY3RlZElkKSB7CiAgICAgICAgICAgIGNvbnN0IGVsID0gbGlzdEVsLnF1ZXJ5
U2VsZWN0b3IoJy5tZy1yb3dbZGF0YS1pZD0iJyArIHNlbGVjdGVkSWQgKyAnIl0nKQogICAgICAg
ICAgICAgICAgfHwgbGlzdEVsLnF1ZXJ5U2VsZWN0b3IoJy5pdG1bZGF0YS1pZD0iJyArIHNlbGVj
dGVkSWQgKyAnIl0nKTsKICAgICAgICAgICAgaWYgKGVsKSBlbC5zY3JvbGxJbnRvVmlldyh7IGJs
b2NrOiAnbmVhcmVzdCcgfSk7CiAgICAgICAgfQogICAgfQoKCiAgICAvKiBzaGlmdC9jdHJsIG11
bHRpLXNlbGVjdDoKICAgICAqIFNoaWZ077ya5pyJ6YCJ5Yy65pe25Lul44CM5pyA5LiKL+acgOS4
i+OAjeS4uumUmu+8jOS4jei3n+m8oOagh+S4iuasoeeCueWHu+i1sAogICAgICogICAtIOeCueWc
qOmAieWMuuS4i+aWuSDihpIg5LuO5LiK6YCJ5Yiw5b2T5YmNCiAgICAgKiAgIC0g54K55Zyo6YCJ
5Yy65LiK5pa5IOKGkiDku47lvZPliY3liLDkuIvpgIkKICAgICAqICAgLSDngrnlnKjpgInljLro
t6jluqblhoUg4oaSIOWhq+a7oeacgOS4iuWIsOacgOS4i++8iOWQq+mdnui/nue7reepuua0nu+8
iQogICAgICogQ3RybO+8mummluasoeeCueS7u+aEj+mhue+8iOWQq+m7mOiupOmrmOS6ru+8iei/
m+WFpeWkmumAieW5tumAieS4re+8m+WGjeeCueW3sumAiemhueWPlua2iOOAgeacqumAiemhueWK
oOWFpQogICAgICovCiAgICBsZXQgcmFuZ2VBbmNob3JJZCA9IDA7CiAgICBsZXQgcmFuZ2VBbmNo
b3JDbGlja2VkID0gZmFsc2U7CiAgICBmdW5jdGlvbiBzZWxlY3RlZEluZGljZXNJbkxpc3QobGlz
dCkgewogICAgICAgIGNvbnN0IHNldCA9IG5ldyBTZXQoKG11bHRpSWRzIHx8IFtdKS5tYXAoTnVt
YmVyKS5maWx0ZXIoQm9vbGVhbikpOwogICAgICAgIGlmICgrc2VsZWN0ZWRJZCkgc2V0LmFkZCgr
c2VsZWN0ZWRJZCk7CiAgICAgICAgY29uc3QgaWR4cyA9IFtdOwogICAgICAgIGxpc3QuZm9yRWFj
aCgoYywgaSkgPT4gewogICAgICAgICAgICBpZiAoc2V0LmhhcygrYy5pZCkpIGlkeHMucHVzaChp
KTsKICAgICAgICB9KTsKICAgICAgICByZXR1cm4gaWR4czsKICAgIH0KICAgIGZ1bmN0aW9uIHNl
bGVjdFJhbmdlVG8oaWQpIHsKICAgICAgICBpZCA9ICtpZDsKICAgICAgICBjb25zdCBsaXN0ID0g
KHR5cGVvZiBuYXZMaXN0ID09PSAnZnVuY3Rpb24nID8gbmF2TGlzdCgpIDogdmlzaWJsZUxpc3Qo
KSk7CiAgICAgICAgY29uc3QgYiA9IGxpc3QuZmluZEluZGV4KGMgPT4gK2MuaWQgPT09IGlkKTsK
ICAgICAgICBpZiAoYiA8IDApIHJldHVybjsKICAgICAgICBjb25zdCBpZHhzID0gc2VsZWN0ZWRJ
bmRpY2VzSW5MaXN0KGxpc3QpOwogICAgICAgIGxldCBsbywgaGk7CiAgICAgICAgaWYgKCFpZHhz
Lmxlbmd0aCkgewogICAgICAgICAgICBsbyA9IGhpID0gYjsKICAgICAgICB9IGVsc2UgewogICAg
ICAgICAgICBjb25zdCB0b3AgPSBNYXRoLm1pbiguLi5pZHhzKTsKICAgICAgICAgICAgY29uc3Qg
Ym90ID0gTWF0aC5tYXgoLi4uaWR4cyk7CiAgICAgICAgICAgIGlmIChiID4gYm90KSB7CiAgICAg
ICAgICAgICAgICAvLyDpgInljLrkuIvmlrnvvJrmnIDkuIog4oaSIOW9k+WJjQogICAgICAgICAg
ICAgICAgbG8gPSB0b3A7CiAgICAgICAgICAgICAgICBoaSA9IGI7CiAgICAgICAgICAgIH0gZWxz
ZSBpZiAoYiA8IHRvcCkgewogICAgICAgICAgICAgICAgLy8g6YCJ5Yy65LiK5pa577ya5b2T5YmN
IOKGkiDmnIDkuIsKICAgICAgICAgICAgICAgIGxvID0gYjsKICAgICAgICAgICAgICAgIGhpID0g
Ym90OwogICAgICAgICAgICB9IGVsc2UgewogICAgICAgICAgICAgICAgLy8g5Zyo6Leo5bqm5YaF
77yI5ZCr6Z2e6L+e57ut56m65rSe77yJ77ya5pW05q615pyA5LiK4oaS5pyA5LiLCiAgICAgICAg
ICAgICAgICBsbyA9IHRvcDsKICAgICAgICAgICAgICAgIGhpID0gYm90OwogICAgICAgICAgICB9
CiAgICAgICAgfQogICAgICAgIG11bHRpSWRzID0gW107CiAgICAgICAgZm9yIChsZXQgaSA9IGxv
OyBpIDw9IGhpOyBpKyspCiAgICAgICAgICAgIG11bHRpSWRzLnB1c2goK2xpc3RbaV0uaWQpOwog
ICAgICAgIHNlbGVjdGVkSWQgPSBpZDsKICAgICAgICAvLyDkuI3lho3miorpvKDmoIfngrnlh7vl
vZPmiJDkuIvkuIDmrKEgU2hpZnQg6ZSa54K5CiAgICAgICAgcmFuZ2VBbmNob3JJZCA9ICtsaXN0
W2xvXS5pZDsKICAgICAgICByYW5nZUFuY2hvckNsaWNrZWQgPSB0cnVlOwogICAgICAgIHVwZGF0
ZU11bHRpQmFkZ2UoKTsKICAgICAgICBjb25zdCBlbCA9IGxpc3RFbC5xdWVyeVNlbGVjdG9yKCcu
bWctcm93W2RhdGEtaWQ9IicgKyBzZWxlY3RlZElkICsgJyJdJykKICAgICAgICAgICAgfHwgbGlz
dEVsLnF1ZXJ5U2VsZWN0b3IoJy5pdG1bZGF0YS1pZD0iJyArIHNlbGVjdGVkSWQgKyAnIl0nKTsK
ICAgICAgICBpZiAoZWwpIGVsLnNjcm9sbEludG9WaWV3KHsgYmxvY2s6ICduZWFyZXN0JyB9KTsK
ICAgIH0KICAgIGZ1bmN0aW9uIGhhbmRsZUl0ZW1DbGljayhlLCBjKSB7CiAgICAgICAgaWYgKGUu
c2hpZnRLZXkpIHsKICAgICAgICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOyBlLnN0b3BQcm9wYWdh
dGlvbigpOwogICAgICAgICAgICBzZWxlY3RSYW5nZVRvKGMuaWQpOwogICAgICAgICAgICByZXR1
cm4gdHJ1ZTsKICAgICAgICB9CiAgICAgICAgaWYgKGUuY3RybEtleSB8fCBlLm1ldGFLZXkpIHsK
ICAgICAgICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOyBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAg
ICAgICAgICB0b2dnbGVNdWx0aShjLmlkKTsKICAgICAgICAgICAgcmV0dXJuIHRydWU7CiAgICAg
ICAgfQogICAgICAgIHJhbmdlQW5jaG9ySWQgPSBjLmlkOwogICAgICAgIHJhbmdlQW5jaG9yQ2xp
Y2tlZCA9IHRydWU7CiAgICAgICAgcmV0dXJuIGZhbHNlOwogICAgfQogICAgZnVuY3Rpb24gdG9n
Z2xlTXVsdGkoaWQpIHsKICAgICAgICBpZCA9ICtpZDsKICAgICAgICAvLyDpppbmrKEgQ3RybO+8
muWPqumAieS4reW9k+WJjeeCueWHu+mhue+8iOWQq+m7mOiupOmrmOS6rumhuSDihpIg6L+b5YWl
5aSa6YCJ77yM5LiN6KaB5Y+W5raI77yJCiAgICAgICAgaWYgKCFtdWx0aUlkcy5sZW5ndGgpIHsK
ICAgICAgICAgICAgbXVsdGlJZHMgPSBbaWRdOwogICAgICAgICAgICBzZWxlY3RlZElkID0gaWQ7
CiAgICAgICAgICAgIHVwZGF0ZU11bHRpQmFkZ2UoKTsKICAgICAgICAgICAgcmV0dXJuOwogICAg
ICAgIH0KICAgICAgICBjb25zdCBpID0gbXVsdGlJZHMuaW5kZXhPZihpZCk7CiAgICAgICAgaWYg
KGkgPj0gMCkgewogICAgICAgICAgICBtdWx0aUlkcy5zcGxpY2UoaSwgMSk7CiAgICAgICAgICAg
IGlmICgrc2VsZWN0ZWRJZCA9PT0gaWQpCiAgICAgICAgICAgICAgICBzZWxlY3RlZElkID0gbXVs
dGlJZHMubGVuZ3RoID8gbXVsdGlJZHNbbXVsdGlJZHMubGVuZ3RoIC0gMV0gOiAwOwogICAgICAg
IH0gZWxzZSB7CiAgICAgICAgICAgIG11bHRpSWRzLnB1c2goaWQpOwogICAgICAgICAgICBzZWxl
Y3RlZElkID0gaWQ7CiAgICAgICAgfQogICAgICAgIHVwZGF0ZU11bHRpQmFkZ2UoKTsKICAgIH0K
ICAgIGZ1bmN0aW9uIHNob3dTcmNUaXAoYW5jaG9yLCB0ZXh0KSB7CiAgICAgICAgdGV4dCA9IFN0
cmluZyh0ZXh0IHx8ICcnKS50cmltKCk7CiAgICAgICAgaWYgKCF0ZXh0KSByZXR1cm47CiAgICAg
ICAgbGV0IHRpcCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzcmMtdGlwJyk7CiAgICAgICAg
aWYgKCF0aXApIHsKICAgICAgICAgICAgdGlwID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnZGl2
Jyk7CiAgICAgICAgICAgIHRpcC5pZCA9ICdzcmMtdGlwJzsKICAgICAgICAgICAgZG9jdW1lbnQu
Ym9keS5hcHBlbmRDaGlsZCh0aXApOwogICAgICAgIH0KICAgICAgICB0aXAudGV4dENvbnRlbnQg
PSB0ZXh0OwogICAgICAgIHRpcC5jbGFzc0xpc3QuYWRkKCdzaG93Jyk7CiAgICAgICAgY29uc3Qg
ciA9IGFuY2hvci5nZXRCb3VuZGluZ0NsaWVudFJlY3QoKTsKICAgICAgICBjb25zdCB0dyA9IHRp
cC5vZmZzZXRXaWR0aCB8fCAxNjA7CiAgICAgICAgY29uc3QgdGggPSB0aXAub2Zmc2V0SGVpZ2h0
IHx8IDI4OwogICAgICAgIGxldCBsZWZ0ID0gci5yaWdodCAtIHR3OwogICAgICAgIGxldCB0b3Ag
PSByLnRvcCAtIHRoIC0gODsKICAgICAgICBpZiAobGVmdCA8IDgpIGxlZnQgPSA4OwogICAgICAg
IGlmIChsZWZ0ICsgdHcgPiB3aW5kb3cuaW5uZXJXaWR0aCAtIDgpIGxlZnQgPSB3aW5kb3cuaW5u
ZXJXaWR0aCAtIHR3IC0gODsKICAgICAgICBpZiAodG9wIDwgOCkgdG9wID0gci5ib3R0b20gKyA4
OwogICAgICAgIHRpcC5zdHlsZS5sZWZ0ID0gbGVmdCArICdweCc7CiAgICAgICAgdGlwLnN0eWxl
LnRvcCA9IHRvcCArICdweCc7CiAgICAgICAgY2xlYXJUaW1lb3V0KHRpcC5faGlkZVQpOwogICAg
ICAgIHRpcC5faGlkZVQgPSBzZXRUaW1lb3V0KCgpID0+IHRpcC5jbGFzc0xpc3QucmVtb3ZlKCdz
aG93JyksIDIyMDApOwogICAgfQogICAgLyogaW1nLWhvdmVyLXByZXZpZXctdjggKi8KICAgIGxl
dCBfX2ltZ0hvdmVyVGltZXIgPSAwLCBfX2ltZ0hvdmVySGlkZVRpbWVyID0gMCwgX19pbWdIb3Zl
cktleSA9ICcnOwogICAgZnVuY3Rpb24gX19pbWdIb3ZlckVuc3VyZSgpIHsKICAgICAgICBsZXQg
Ym94ID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2ltZy1ob3Zlci1zaWRlJyk7CiAgICAgICAg
aWYgKCFib3gpIHsKICAgICAgICAgICAgYm94ID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnZGl2
Jyk7IGJveC5pZCA9ICdpbWctaG92ZXItc2lkZSc7CiAgICAgICAgICAgIGNvbnN0IGZyYW1lID0g
ZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnZGl2Jyk7IGZyYW1lLmNsYXNzTmFtZSA9ICdpaHAtZnJh
bWUnOwogICAgICAgICAgICBjb25zdCBpbSA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2ltZycp
OyBpbS5hbHQgPSAnJzsKICAgICAgICAgICAgZnJhbWUuYXBwZW5kQ2hpbGQoaW0pOyBib3guYXBw
ZW5kQ2hpbGQoZnJhbWUpOyBkb2N1bWVudC5ib2R5LmFwcGVuZENoaWxkKGJveCk7CiAgICAgICAg
fQogICAgICAgIGxldCBzdCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdpbWctaG92ZXItc2lk
ZS1jc3MnKTsKICAgICAgICBpZiAoIXN0KSB7IHN0ID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgn
c3R5bGUnKTsgc3QuaWQgPSAnaW1nLWhvdmVyLXNpZGUtY3NzJzsgZG9jdW1lbnQuaGVhZC5hcHBl
bmRDaGlsZChzdCk7IH0KICAgICAgICBzdC50ZXh0Q29udGVudCA9ICIjaW1nLWhvdmVyLXNpZGV7
cG9zaXRpb246Zml4ZWQ7ei1pbmRleDoxMDAwMDA7cmlnaHQ6NnB4O3RvcDo1MCU7dHJhbnNmb3Jt
OnRyYW5zbGF0ZVkoLTUwJSk7cG9pbnRlci1ldmVudHM6bm9uZTtvcGFjaXR5OjA7dmlzaWJpbGl0
eTpoaWRkZW47bWF4LXdpZHRoOm1pbig2MjBweCw5MnZ3KTttYXgtaGVpZ2h0Om1pbig5MnZoLDky
MHB4KX0jaW1nLWhvdmVyLXNpZGUuc2hvd3tvcGFjaXR5OjE7dmlzaWJpbGl0eTp2aXNpYmxlfSNp
bWctaG92ZXItc2lkZSAuaWhwLWZyYW1le3BhZGRpbmc6M3B4O2JhY2tncm91bmQ6I2ZmZjtib3Jk
ZXI6MXB4IHNvbGlkICNDNUNEREM7Ym9yZGVyLXJhZGl1czoycHg7Ym94LXNoYWRvdzowIDZweCAx
OHB4IHJnYmEoNDQsNDYsNTQsLjEyKX0jaW1nLWhvdmVyLXNpZGUgaW1ne2Rpc3BsYXk6YmxvY2s7
bWF4LXdpZHRoOm1pbig2MTJweCw5MHZ3KTttYXgtaGVpZ2h0Om1pbig5MHZoLDkwMHB4KTt3aWR0
aDphdXRvO2hlaWdodDphdXRvO29iamVjdC1maXQ6Y29udGFpbjtiYWNrZ3JvdW5kOiNmZmZ9IjsK
ICAgICAgICByZXR1cm4gYm94OwogICAgfQogICAgd2luZG93Ll9faW1nSG92ZXJTaG93ID0gZnVu
Y3Rpb24oZmlsZSwgaWQpIHsKICAgICAgICBjb25zdCBiYXJlID0gU3RyaW5nKGZpbGUgfHwgJycp
LnNwbGl0KC9bXFxcXC9dLykucG9wKCk7IGlmICghYmFyZSkgcmV0dXJuOwogICAgICAgIGNvbnN0
IGJveCA9IF9faW1nSG92ZXJFbnN1cmUoKTsgY29uc3QgaW1nID0gYm94LnF1ZXJ5U2VsZWN0b3Io
J2ltZycpOyBpZiAoIWltZykgcmV0dXJuOwogICAgICAgIGJveC5jbGFzc0xpc3QuYWRkKCdzaG93
Jyk7CiAgICAgICAgaW1nLm9uZXJyb3IgPSAoKSA9PiB7CiAgICAgICAgICAgIGltZy5vbmVycm9y
ID0gKCkgPT4geyBpbWcub25lcnJvciA9IG51bGw7IHRyeSB7IGNvbnN0IGMgPSB0aHVtYkNhY2hl
ICYmIHRodW1iQ2FjaGUuZ2V0KFN0cmluZyhpZCkpOyBpZiAoYykgaW1nLnNyYyA9IGM7IH0gY2F0
Y2ggKGUpIHt9IH07CiAgICAgICAgICAgIGltZy5zcmMgPSBTVE9SRV9CQVNFICsgJ3RoXycgKyBi
YXJlLnJlcGxhY2UoL1wuW14uXSskLywgJycpICsgJy5qcGcnOwogICAgICAgIH07CiAgICAgICAg
aW1nLm9ubG9hZCA9ICgpID0+IHsgaW1nLm9uZXJyb3IgPSBudWxsOyB9OwogICAgICAgIGltZy5k
YXRhc2V0LmJhcmUgPSBiYXJlOyBpbWcuc3JjID0gU1RPUkVfQkFTRSArIGJhcmU7CiAgICB9Owog
ICAgd2luZG93Ll9faW1nSG92ZXJDbGVhclVpID0gZnVuY3Rpb24oKSB7CiAgICAgICAgX19pbWdI
b3ZlcktleSA9ICcnOwogICAgICAgIGlmIChfX2ltZ0hvdmVyVGltZXIpIHsgY2xlYXJUaW1lb3V0
KF9faW1nSG92ZXJUaW1lcik7IF9faW1nSG92ZXJUaW1lciA9IDA7IH0KICAgICAgICBpZiAoX19p
bWdIb3ZlckhpZGVUaW1lcikgeyBjbGVhclRpbWVvdXQoX19pbWdIb3ZlckhpZGVUaW1lcik7IF9f
aW1nSG92ZXJIaWRlVGltZXIgPSAwOyB9CiAgICAgICAgY29uc3QgYm94ID0gZG9jdW1lbnQuZ2V0
RWxlbWVudEJ5SWQoJ2ltZy1ob3Zlci1zaWRlJyk7IGlmIChib3gpIGJveC5jbGFzc0xpc3QucmVt
b3ZlKCdzaG93Jyk7CiAgICAgICAgY29uc3QgaW1nID0gYm94ICYmIGJveC5xdWVyeVNlbGVjdG9y
KCdpbWcnKTsKICAgICAgICBpZiAoaW1nKSB7IGltZy5vbmxvYWQgPSBudWxsOyBpbWcub25lcnJv
ciA9IG51bGw7IGltZy5yZW1vdmVBdHRyaWJ1dGUoJ3NyYycpOyBkZWxldGUgaW1nLmRhdGFzZXQu
YmFyZTsgfQogICAgfTsKICAgIHdpbmRvdy5fX2ltZ0hvdmVySGlkZSA9IGZ1bmN0aW9uKCkgeyB3
aW5kb3cuX19pbWdIb3ZlckNsZWFyVWkoKTsgfTsKICAgIGZ1bmN0aW9uIGJpbmRJbWdIb3ZlclBy
ZXZpZXcoZWwsIGlkLCBmaWxlKSB7CiAgICAgICAgaWYgKCFlbCkgcmV0dXJuOwogICAgICAgIGNv
bnN0IGJhcmUgPSBTdHJpbmcoZmlsZSB8fCAnJykuc3BsaXQoL1tcXFxcL10vKS5wb3AoKTsgaWYg
KCFiYXJlKSByZXR1cm47CiAgICAgICAgY29uc3Qga2V5ID0gU3RyaW5nKGlkKSArICd8JyArIGJh
cmU7CiAgICAgICAgZWwuc3R5bGUuY3Vyc29yID0gJ3pvb20taW4nOwogICAgICAgIGVsLmFkZEV2
ZW50TGlzdGVuZXIoJ21vdXNlZW50ZXInLCAoKSA9PiB7CiAgICAgICAgICAgIGlmIChfX2ltZ0hv
dmVySGlkZVRpbWVyKSB7IGNsZWFyVGltZW91dChfX2ltZ0hvdmVySGlkZVRpbWVyKTsgX19pbWdI
b3ZlckhpZGVUaW1lciA9IDA7IH0KICAgICAgICAgICAgX19pbWdIb3ZlcktleSA9IGtleTsKICAg
ICAgICAgICAgaWYgKF9faW1nSG92ZXJUaW1lcikgY2xlYXJUaW1lb3V0KF9faW1nSG92ZXJUaW1l
cik7CiAgICAgICAgICAgIF9faW1nSG92ZXJUaW1lciA9IHNldFRpbWVvdXQoKCkgPT4geyBpZiAo
X19pbWdIb3ZlcktleSA9PT0ga2V5KSB0cnkgeyB3aW5kb3cuX19pbWdIb3ZlclNob3coYmFyZSwg
aWQpOyB9IGNhdGNoIChlKSB7fSB9LCA2MCk7CiAgICAgICAgfSk7CiAgICAgICAgZWwuYWRkRXZl
bnRMaXN0ZW5lcignbW91c2VsZWF2ZScsICgpID0+IHsKICAgICAgICAgICAgaWYgKF9faW1nSG92
ZXJUaW1lcikgeyBjbGVhclRpbWVvdXQoX19pbWdIb3ZlclRpbWVyKTsgX19pbWdIb3ZlclRpbWVy
ID0gMDsgfQogICAgICAgICAgICBfX2ltZ0hvdmVySGlkZVRpbWVyID0gc2V0VGltZW91dCgoKSA9
PiB7IGlmICghX19pbWdIb3ZlcktleSB8fCBfX2ltZ0hvdmVyS2V5ID09PSBrZXkpIHdpbmRvdy5f
X2ltZ0hvdmVySGlkZSgpOyB9LCA3MCk7CiAgICAgICAgfSk7CiAgICB9CgogICAgZnVuY3Rpb24g
cmVuZGVyKCkgewogICAgICAgIGhpZGVQYXRoVGlwKCk7CgogICAgICAgIGNvbnN0IHZpc2libGUg
PSB2aXNpYmxlTGlzdCgpOwogICAgICAgIGNvbnN0IGxvYWRlZCA9IGFsbENsaXBzLmxlbmd0aDsK
ICAgICAgICBjb25zdCBzaG93bkNvdW50ID0gdmlzaWJsZS5sZW5ndGg7CiAgICAgICAgLy8g5pS2
6JeP6KeS5qCH77ya5pS55Li657u/54K577yI5pyJ5pyq5p+l55yL55qE5paw5pS26JeP5pe25pi+
56S677yJCiAgICAgICAgbGV0IHBpbm5lZE4gPSBOdW1iZXIocGlubmVkVG90YWwpIHx8IDA7CiAg
ICAgICAgaWYgKHBpbm5lZE4gPCAxKSB7CiAgICAgICAgICAgIGlmIChjdXJUYWIgPT09ICdwaW5u
ZWQnKQogICAgICAgICAgICAgICAgcGlubmVkTiA9IE1hdGgubWF4KE51bWJlcihkaXNrVG90YWwp
IHx8IDAsIGxvYWRlZCk7CiAgICAgICAgICAgIGVsc2UKICAgICAgICAgICAgICAgIHBpbm5lZE4g
PSBhbGxDbGlwcy5maWx0ZXIoYyA9PiBpc1Bpbm5lZChjKSkubGVuZ3RoOwogICAgICAgIH0KICAg
ICAgICB1cGRhdGVQaW5Eb3QoKTsKICAgICAgICAvLyDmlLbol48gdGFi77yaYmFyIOeUqOaAu+aV
sO+8m+acqua7oemhteaXtuaYvuekuiDlt7LliqDovb0v5oC75pWwCiAgICAgICAgbGV0IHNob3dU
b3RhbCA9IGRpc2tUb3RhbCA+IDAgPyBkaXNrVG90YWwgOiAobG9hZGVkIHx8IDApOwogICAgICAg
IGlmIChjdXJUYWIgPT09ICdwaW5uZWQnICYmIHBpbm5lZE4gPiBzaG93VG90YWwpCiAgICAgICAg
ICAgIHNob3dUb3RhbCA9IHBpbm5lZE47CiAgICAgICAgY29uc3QgcU9uID0gU3RyaW5nKHF1ZXJ5
IHx8ICcnKS50cmltKCkubGVuZ3RoID4gMDsKICAgICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJ
ZCgnYmFyLXR4dCcpLnRleHRDb250ZW50ID0gcU9uCiAgICAgICAgICAgID8gKHNob3duQ291bnQg
KyAnIOadoScpCiAgICAgICAgICAgIDogKHNob3dUb3RhbCA+IGxvYWRlZCA/IChzaG93bkNvdW50
ICsgJyAvICcgKyBzaG93VG90YWwgKyAnIOadoScpIDogKHNob3dUb3RhbCArICcg5p2hJykpOwog
ICAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdlbXB0eS10eHQnKS50ZXh0Q29udGVudCA9
IEVNUFRZX01TR1tjdXJUYWJdIHx8IEVNUFRZX01TRy5hbGw7CgogICAgICAgIGNvbnN0IGlkU2V0
ID0gbmV3IFNldChhbGxDbGlwcy5tYXAoYyA9PiArYy5pZCkpOwogICAgICAgIG11bHRpSWRzID0g
bXVsdGlJZHMuZmlsdGVyKGlkID0+IGlkU2V0LmhhcyhpZCkpOwogICAgICAgIHVwZGF0ZU11bHRp
QmFkZ2UoKTsKCiAgICAgICAgY29uc3Qgc2hvd24gPSB2aXNpYmxlOwoKICAgICAgICBsaXN0RWwu
cXVlcnlTZWxlY3RvckFsbCgnLml0bSwgI2xpc3QtbW9yZScpLmZvckVhY2goZSA9PiBlLnJlbW92
ZSgpKTsKICAgICAgICAvLyDpqqjmnrblt7LlhbPpl63vvJrljbPkvb8gd2FpdGluZyDkuZ/kuI0g
cmV0dXJu77yM5pyJ5pWw5o2u5bCx55u05o6l55S7CiAgICAgICAgaWYgKHNrZWxFbCkgc2tlbEVs
LmNsYXNzTGlzdC5yZW1vdmUoJ29uJyk7CiAgICAgICAgY29uc3QgYXBwQm9vdCA9IGRvY3VtZW50
LmdldEVsZW1lbnRCeUlkKCdhcHAnKTsKICAgICAgICBpZiAoYXBwQm9vdCkgYXBwQm9vdC5jbGFz
c0xpc3QucmVtb3ZlKCdib290LWxvYWRpbmcnKTsKICAgICAgICBpZiAoKHdhaXRpbmdEYXRhIHx8
ICFob3N0UHVzaGVkT25jZSkgJiYgIXZpc2libGUubGVuZ3RoKSB7CiAgICAgICAgICAgIGVtcHR5
RWwuY2xhc3NMaXN0LnJlbW92ZSgnb24nKTsKICAgICAgICAgICAgdXBkYXRlVG9wQnRuKCk7CiAg
ICAgICAgICAgIHJldHVybjsKICAgICAgICB9CiAgICAgICAgaWYgKCF2aXNpYmxlLmxlbmd0aCkg
ewogICAgICAgICAgICAvLyBOZXZlciBzaG9344CM5pqC5peg6K6w5b2V44CNdW50aWwgd2UgaGF2
ZSBzZWVuIGEgcmVhbCBub24tZW1wdHkgcHVzaCwKICAgICAgICAgICAgLy8gb3IgYSBjb25maXJt
ZWQgZW1wdHkgYWZ0ZXIgd2FybSAoc2F3Tm9uRW1wdHkgY2FuIGJlIHNldCBieSBlbXB0eS1mYWxs
YmFjaykuCiAgICAgICAgICAgIC8vIEZpbHRlcmVkIHNlYXJjaCB3aXRoIDAgaGl0cyBpcyBhbGxv
d2VkIG9uY2UgaG9zdCBwdXNoZWQuCiAgICAgICAgICAgIGNvbnN0IHFPbiA9IFN0cmluZyhxdWVy
eSB8fCAnJykudHJpbSgpLmxlbmd0aCA+IDA7CiAgICAgICAgICAgIGNvbnN0IGFsbG93RW1wdHkg
PSBob3N0UHVzaGVkT25jZSAmJiBzYXdOb25FbXB0eSAmJiAhd2FpdGluZ0RhdGEgJiYgIWJvb3RM
b2FkaW5nCiAgICAgICAgICAgICAgICAmJiAocU9uIHx8IGRpc2tUb3RhbCA8PSAwKTsKICAgICAg
ICAgICAgaWYgKCFhbGxvd0VtcHR5KSB7CiAgICAgICAgICAgICAgICBlbXB0eUVsLmNsYXNzTGlz
dC5yZW1vdmUoJ29uJyk7CiAgICAgICAgICAgICAgICB1cGRhdGVUb3BCdG4oKTsKICAgICAgICAg
ICAgICAgIHJldHVybjsKICAgICAgICAgICAgfQogICAgICAgICAgICBpZiAoc2VsZWN0Rmlyc3RP
blNob3cpIHsKICAgICAgICAgICAgICAgIHNlbGVjdEZpcnN0T25TaG93ID0gZmFsc2U7CiAgICAg
ICAgICAgICAgICBzZWxlY3RlZElkID0gMDsKICAgICAgICAgICAgICAgIGNsZWFyTXVsdGkoKTsK
ICAgICAgICAgICAgICAgIGxpc3RFbC5zY3JvbGxUb3AgPSAwOwogICAgICAgICAgICB9CiAgICAg
ICAgICAgIGVtcHR5RWwuY2xhc3NMaXN0LmFkZCgnb24nKTsKICAgICAgICAgICAgdXBkYXRlVG9w
QnRuKCk7CiAgICAgICAgICAgIHJldHVybjsKICAgICAgICB9CiAgICAgICAgZW1wdHlFbC5jbGFz
c0xpc3QucmVtb3ZlKCdvbicpOwogICAgICAgIGNvbnN0IGZyYWcgPSBkb2N1bWVudC5jcmVhdGVE
b2N1bWVudEZyYWdtZW50KCk7CiAgICAgICAgY29uc3QgYmxvY2tzID0gYnVpbGRQaW5uZWRCbG9j
a3Moc2hvd24pOwogICAgICAgIGxldCBudW0gPSAwOwogICAgICAgIGJsb2Nrcy5mb3JFYWNoKGIg
PT4gewogICAgICAgICAgICBudW0gKz0gMTsKICAgICAgICAgICAgaWYgKGIua2luZCA9PT0gJ2dy
b3VwJyAmJiBiLml0ZW1zLmxlbmd0aCA+IDEpCiAgICAgICAgICAgICAgICBmcmFnLmFwcGVuZENo
aWxkKG1ha2VHcm91cEl0ZW0oYi5pdGVtcywgbnVtKSk7CiAgICAgICAgICAgIGVsc2UKICAgICAg
ICAgICAgICAgIGZyYWcuYXBwZW5kQ2hpbGQobWFrZUl0ZW0oYi5pdGVtc1swXSwgbnVtKSk7CiAg
ICAgICAgfSk7CiAgICAgICAgbGlzdEVsLmFwcGVuZENoaWxkKGZyYWcpOwogICAgICAgIG1hcmtR
dWV1ZVJhaWxzKCk7CiAgICAgICAgdXBkYXRlTW9yZUZvb3RlcihkaXNrVG90YWwpOwogICAgICAg
IGlmIChzZWxlY3RGaXJzdE9uU2hvdykgewogICAgICAgICAgICBzZWxlY3RGaXJzdE9uU2hvdyA9
IGZhbHNlOwogICAgICAgICAgICBzZWxlY3RlZElkID0gdmlzaWJsZVswXS5pZDsKICAgICAgICAg
ICAgY2xlYXJNdWx0aSgpOwogICAgICAgICAgICBsaXN0RWwuc2Nyb2xsVG9wID0gMDsKICAgICAg
ICB9IGVsc2UgaWYgKCF2aXNpYmxlLnNvbWUoYyA9PiBjLmlkID09IHNlbGVjdGVkSWQpKSB7CiAg
ICAgICAgICAgIHNlbGVjdGVkSWQgPSB2aXNpYmxlWzBdLmlkOwogICAgICAgICAgICByYW5nZUFu
Y2hvcklkID0gc2VsZWN0ZWRJZDsKICAgICAgICAgICAgcmFuZ2VBbmNob3JDbGlja2VkID0gZmFs
c2U7CiAgICAgICAgfSBlbHNlIGlmICghcmFuZ2VBbmNob3JJZCkgewogICAgICAgICAgICByYW5n
ZUFuY2hvcklkID0gc2VsZWN0ZWRJZDsKICAgICAgICB9CiAgICAgICAgc3luY0l0ZW1IaWdobGln
aHQoKTsKICAgICAgICB1cGRhdGVUb3BCdG4oKTsKICAgICAgICBpZiAod2luZG93Ll9fcGVuZGlu
Z0p1bXBJZCkgewogICAgICAgICAgICBjb25zdCBqaWQgPSArd2luZG93Ll9fcGVuZGluZ0p1bXBJ
ZDsKICAgICAgICAgICAgY29uc3QgZWwgPSBsaXN0RWwucXVlcnlTZWxlY3RvcignLm1nLXJvd1tk
YXRhLWlkPSInICsgamlkICsgJyJdJykgfHwgbGlzdEVsLnF1ZXJ5U2VsZWN0b3IoJy5pdG1bZGF0
YS1pZD0iJyArIGppZCArICciXScpOwogICAgICAgICAgICBpZiAoZWwpIHsKICAgICAgICAgICAg
ICAgIHdpbmRvdy5fX3BlbmRpbmdKdW1wSWQgPSAwOwogICAgICAgICAgICAgICAgd2luZG93Ll9f
anVtcExvYWRUcmllcyA9IDA7CiAgICAgICAgICAgICAgICBzZWxlY3RlZElkID0gamlkOwogICAg
ICAgICAgICAgICAgcmVxdWVzdEFuaW1hdGlvbkZyYW1lKCgpID0+IHsKICAgICAgICAgICAgICAg
ICAgICBjb25zdCBub2RlID0gbGlzdEVsLnF1ZXJ5U2VsZWN0b3IoJy5tZy1yb3dbZGF0YS1pZD0i
JyArIGppZCArICciXScpIHx8IGxpc3RFbC5xdWVyeVNlbGVjdG9yKCcuaXRtW2RhdGEtaWQ9Iicg
KyBqaWQgKyAnIl0nKTsKICAgICAgICAgICAgICAgICAgICBpZiAoIW5vZGUpIHJldHVybjsKICAg
ICAgICAgICAgICAgICAgICBub2RlLnNjcm9sbEludG9WaWV3KHsgYmxvY2s6ICdjZW50ZXInIH0p
OwogICAgICAgICAgICAgICAgICAgIG5vZGUuY2xhc3NMaXN0LmFkZCgnanVtcC1mbGFzaCcpOwog
ICAgICAgICAgICAgICAgICAgIHNldFRpbWVvdXQoKCkgPT4gbm9kZS5jbGFzc0xpc3QucmVtb3Zl
KCdqdW1wLWZsYXNoJyksIDkwMCk7CiAgICAgICAgICAgICAgICAgICAgc3luY0l0ZW1IaWdobGln
aHQoKTsKICAgICAgICAgICAgICAgIH0pOwogICAgICAgICAgICB9IGVsc2UgaWYgKGFsbENsaXBz
Lmxlbmd0aCA8IGRpc2tUb3RhbCAmJiAod2luZG93Ll9fanVtcExvYWRUcmllcyB8fCAwKSA8IDQw
KSB7CiAgICAgICAgICAgICAgICB3aW5kb3cuX19qdW1wTG9hZFRyaWVzID0gKHdpbmRvdy5fX2p1
bXBMb2FkVHJpZXMgfHwgMCkgKyAxOwogICAgICAgICAgICAgICAgcmVxdWVzdE1vcmUoKTsKICAg
ICAgICAgICAgfSBlbHNlIGlmIChjdXJUYWIgIT09ICdhbGwnICYmICF3aW5kb3cuX19qdW1wRmVs
bEJhY2spIHsKICAgICAgICAgICAgICAgIC8vIEl0ZW0gZ29uZSBmcm9tIHRoaXMgdGFiIChlLmcu
IHVucGlubmVkKSDigJQgZmFsbCBiYWNrIHRvIOWFqOmDqCBvbmNlCiAgICAgICAgICAgICAgICB3
aW5kb3cuX19qdW1wRmVsbEJhY2sgPSB0cnVlOwogICAgICAgICAgICAgICAgd2luZG93Ll9fanVt
cExvYWRUcmllcyA9IDA7CiAgICAgICAgICAgICAgICBjdXJUYWIgPSAnYWxsJzsKICAgICAgICAg
ICAgICAgIG1hcmtUYWIoJ2FsbCcpOwogICAgICAgICAgICAgICAgcmVxdWVzdFZpZXcoKTsKICAg
ICAgICAgICAgfSBlbHNlIHsKICAgICAgICAgICAgICAgIHdpbmRvdy5fX3BlbmRpbmdKdW1wSWQg
PSAwOwogICAgICAgICAgICAgICAgd2luZG93Ll9fanVtcExvYWRUcmllcyA9IDA7CiAgICAgICAg
ICAgICAgICBpZiAoYWxsQ2xpcHMuc29tZShjID0+ICtjLmlkID09PSBqaWQpKQogICAgICAgICAg
ICAgICAgICAgIHNlbGVjdGVkSWQgPSBqaWQ7CiAgICAgICAgICAgICAgICBzeW5jSXRlbUhpZ2hs
aWdodCgpOwogICAgICAgICAgICB9CiAgICAgICAgfQogICAgICAgIHJlcXVlc3RBbmltYXRpb25G
cmFtZSgoKSA9PiB7CiAgICAgICAgICAgIGlmIChhbGxDbGlwcy5sZW5ndGggPCBkaXNrVG90YWwK
ICAgICAgICAgICAgICAgICYmIGxpc3RFbC5zY3JvbGxIZWlnaHQgPD0gbGlzdEVsLmNsaWVudEhl
aWdodCArIDIwKQogICAgICAgICAgICAgICAgcmVxdWVzdE1vcmUoKTsKICAgICAgICAgICAgc2No
ZWR1bGVGaWxlR29uZUNoZWNrKCk7CiAgICAgICAgfSk7CiAgICB9CgogICAgY29uc3QgU1ZHID0g
ewogICAgICAgIHRleHQ6ICAgYDxzdmcgdmlld0JveD0iMCAwIDI0IDI0IiBmaWxsPSJub25lIiBz
dHJva2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIyIj48cGF0aCBkPSJNNCA3VjRoMTZ2
M005IDIwaDZNMTIgNHYxNiIvPjwvc3ZnPmAsCiAgICAgICAgbWQ6ICAgICBgPHN2ZyB2aWV3Qm94
PSIwIDAgMjQgMjQiIGZpbGw9ImN1cnJlbnRDb2xvciI+PHRleHQgeD0iMTIiIHk9IjE3IiB0ZXh0
LWFuY2hvcj0ibWlkZGxlIiBmb250LXNpemU9IjE1IiBmb250LXdlaWdodD0iODAwIiBmb250LWZh
bWlseT0iU2Vnb2UgVUksTWljcm9zb2Z0IFlhSGVpLHNhbnMtc2VyaWYiPk08L3RleHQ+PC9zdmc+
YCwKICAgICAgICBpbWFnZTogIGA8c3ZnIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0ibm9uZSIg
c3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0cm9rZS13aWR0aD0iMS44Ij48cmVjdCB4PSIzIiB5PSI1
IiB3aWR0aD0iMTgiIGhlaWdodD0iMTQiIHJ4PSIyIi8+PGNpcmNsZSBjeD0iOC41IiBjeT0iMTAi
IHI9IjEuNSIgZmlsbD0iY3VycmVudENvbG9yIiBzdHJva2U9Im5vbmUiLz48cGF0aCBkPSJNMyAx
Nmw1LTUgNCA0IDMtMyA2IDYiLz48L3N2Zz5gLAogICAgICAgIHZpZGVvOiAgYDxzdmcgdmlld0Jv
eD0iMCAwIDI0IDI0IiBmaWxsPSJub25lIiBzdHJva2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdp
ZHRoPSIxLjgiPjxyZWN0IHg9IjMiIHk9IjYiIHdpZHRoPSIxNCIgaGVpZ2h0PSIxMiIgcng9IjIi
Lz48cGF0aCBkPSJNMTcgOS41bDQtMi41djEwbC00LTIuNVY5LjV6IiBmaWxsPSJjdXJyZW50Q29s
b3IiIHN0cm9rZT0ibm9uZSIvPjxwYXRoIGQ9Ik04LjUgMTAuMnYzLjZsMy4yLTEuOC0zLjItMS44
eiIgZmlsbD0iY3VycmVudENvbG9yIiBzdHJva2U9Im5vbmUiLz48L3N2Zz5gLAogICAgICAgIGZv
bGRlcjogYDxzdmcgdmlld0JveD0iMCAwIDI0IDI0IiBmaWxsPSJjdXJyZW50Q29sb3IiPjxwYXRo
IGQ9Ik0xMCA0SDRjLTEuMSAwLTIgLjktMiAydjEyYzAgMS4xLjkgMiAyIDJoMTZjMS4xIDAgMi0u
OSAyLTJWOGMwLTEuMS0uOS0yLTItMmgtOGwtMi0yeiIvPjwvc3ZnPmAsCiAgICAgICAgemlwOiAg
ICBgPHN2ZyB2aWV3Qm94PSIwIDAgMjQgMjQiIGZpbGw9Im5vbmUiIHN0cm9rZT0iY3VycmVudENv
bG9yIiBzdHJva2Utd2lkdGg9IjEuOCI+PHBhdGggZD0iTTYgM2g5bDUgNXYxM2ExIDEgMCAwIDEt
MSAxSDZhMSAxIDAgMCAxLTEtMVY0YTEgMSAwIDAgMSAxLTF6Ii8+PHBhdGggZD0iTTE0IDN2Nmg2
Ii8+PC9zdmc+YCwKICAgICAgICBhaGs6ICAgIGA8c3ZnIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmls
bD0iY3VycmVudENvbG9yIj48dGV4dCB4PSIxMiIgeT0iMTciIHRleHQtYW5jaG9yPSJtaWRkbGUi
IGZvbnQtc2l6ZT0iMTQiIGZvbnQtd2VpZ2h0PSI3MDAiPkg8L3RleHQ+PC9zdmc+YCwKICAgICAg
ICBsbms6ICAgIGA8c3ZnIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSJj
dXJyZW50Q29sb3IiIHN0cm9rZS13aWR0aD0iMS44Ij48cGF0aCBkPSJNMTAgMTNhNSA1IDAgMCAw
IDcuMDcgMGwyLjEyLTIuMTJhNSA1IDAgMCAwLTcuMDctNy4wN0wxMSA1Ii8+PHBhdGggZD0iTTE0
IDExYTUgNSAwIDAgMC03LjA3IDBMNC44IDEzLjEyYTUgNSAwIDEgMCA3LjA3IDcuMDdMMTMgMTki
Lz48L3N2Zz5gLAogICAgICAgIGRvYzogICAgYDxzdmcgdmlld0JveD0iMCAwIDI0IDI0IiBmaWxs
PSJub25lIiBzdHJva2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIxLjgiPjxwYXRoIGQ9
Ik03IDNoN2w1IDV2MTNhMSAxIDAgMCAxLTEgMUg3YTEgMSAwIDAgMS0xLTFWNGExIDEgMCAwIDEg
MS0xeiIvPjxwYXRoIGQ9Ik0xNCAzdjZoNiIvPjwvc3ZnPmAsCiAgICAgICAgbXVsdGk6ICBgPHN2
ZyB2aWV3Qm94PSIwIDAgMjQgMjQiIGZpbGw9Im5vbmUiIHN0cm9rZT0iY3VycmVudENvbG9yIiBz
dHJva2Utd2lkdGg9IjEuOCI+PHJlY3QgeD0iNyIgeT0iNyIgd2lkdGg9IjEyIiBoZWlnaHQ9IjE0
IiByeD0iMS41Ii8+PHBhdGggZD0iTTUgMTdWNWExIDEgMCAwIDEgMS0xaDEwIi8+PC9zdmc+YAog
ICAgfTsKCiAgICBmdW5jdGlvbiBmaWxlRXh0KHBhdGgpIHsKICAgICAgICBjb25zdCBiYXNlID0g
U3RyaW5nKHBhdGggfHwgJycpLnNwbGl0KC9bXFwvXS8pLnBvcCgpIHx8ICcnOwogICAgICAgIGNv
bnN0IGkgPSBiYXNlLmxhc3RJbmRleE9mKCcuJyk7CiAgICAgICAgcmV0dXJuIGkgPiAwID8gYmFz
ZS5zbGljZShpICsgMSkudG9Mb3dlckNhc2UoKSA6ICcnOwogICAgfQogICAgY29uc3QgaXNJbWFn
ZUV4dCA9IGUgPT4gWydwbmcnLCdqcGcnLCdqcGVnJywnZ2lmJywnd2VicCcsJ2JtcCcsJ2ljbycs
J3RpZicsJ3RpZmYnLCdzdmcnXS5pbmNsdWRlcyhlKTsKICAgIGNvbnN0IGlzVmlkZW9FeHQgPSBl
ID0+IFsnbXA0JywnbWt2JywnYXZpJywnbW92Jywnd212JywnZmx2Jywnd2VibScsJ200dicsJ21w
ZWcnLCdtcGcnLCd0cycsJ20ydHMnLCczZ3AnLCdybScsJ3JtdmInXS5pbmNsdWRlcyhlKTsKICAg
IGNvbnN0IGlzWmlwRXh0ICAgPSBlID0+IFsnemlwJywncmFyJywnN3onLCd0YXInLCdneicsJ2J6
MiddLmluY2x1ZGVzKGUpOwoKICAgIGZ1bmN0aW9uIGljb25Gb3JGaWxlcyhmaWxlcykgewogICAg
ICAgIGlmICghZmlsZXMubGVuZ3RoKSAgICByZXR1cm4geyBjbHM6ICdmaWxlIGZ0LWRvYycsIHN2
ZzogU1ZHLmRvYyB9OwogICAgICAgIGlmIChmaWxlcy5sZW5ndGggPiAxKSByZXR1cm4geyBjbHM6
ICdmaWxlIGZ0LWxuaycsIHN2ZzogU1ZHLm11bHRpIH07CiAgICAgICAgY29uc3QgZXh0ID0gZmls
ZUV4dChmaWxlc1swXSk7CiAgICAgICAgaWYgKCFleHQpICAgICAgICAgICAgICByZXR1cm4geyBj
bHM6ICdmaWxlIGZ0LWRpcicsIHN2ZzogU1ZHLmZvbGRlciB9OwogICAgICAgIGlmIChpc0ltYWdl
RXh0KGV4dCkpICAgcmV0dXJuIHsgY2xzOiAnZmlsZSBmdC1pbWcnLCBzdmc6IFNWRy5pbWFnZSB9
OwogICAgICAgIGlmIChpc1ZpZGVvRXh0KGV4dCkpICAgcmV0dXJuIHsgY2xzOiAnZmlsZSBmdC12
aWQnLCBzdmc6IChTVkcudmlkZW8gfHwgU1ZHLmRvYykgfTsKICAgICAgICBpZiAoaXNaaXBFeHQo
ZXh0KSkgICAgIHJldHVybiB7IGNsczogJ2ZpbGUgZnQtemlwJywgc3ZnOiBTVkcuemlwIH07CiAg
ICAgICAgaWYgKGV4dCA9PT0gJ2FoaycpICAgICByZXR1cm4geyBjbHM6ICdmaWxlIGZ0LWFoaycs
IHN2ZzogU1ZHLmFoayB9OwogICAgICAgIGlmIChleHQgPT09ICdsbmsnKSAgICAgcmV0dXJuIHsg
Y2xzOiAnZmlsZSBmdC1sbmsnLCBzdmc6IFNWRy5sbmsgfTsKICAgICAgICByZXR1cm4geyBjbHM6
ICdmaWxlIGZ0LWRvYycsIHN2ZzogU1ZHLmRvYyB9OwogICAgfQoKICAgIGZ1bmN0aW9uIHNyY1dp
bkxhYmVsKGMpIHsKICAgICAgICBjb25zdCB0ID0gU3RyaW5nKGMgJiYgYy5zcmNUaXRsZSB8fCAn
JykudHJpbSgpOwogICAgICAgIGlmICh0KSByZXR1cm4gdDsKICAgICAgICByZXR1cm4gU3RyaW5n
KGMgJiYgYy5zcmNFeGUgfHwgJycpLnJlcGxhY2UoL1wuZXhlJC9pLCAnJyk7CiAgICB9CiAgICBm
dW5jdGlvbiBzcmNUaXRsZUh0bWwoYykgewogICAgICAgIC8vIOWIl+ihqOS4remXtC/lj7Pkvqfk
uI3lho3mmL7npLrnqpflj6PmoIfpopjvvIzmnaXmupDlj6rkv53nlZnlj7Pkvqflm77moIfmgqzl
gZzmj5DnpLoKICAgICAgICByZXR1cm4gJyc7CiAgICB9CiAgICBmdW5jdGlvbiBleHBhbmRDaGV2
cm9uKG9wZW4pIHsKICAgICAgICByZXR1cm4gb3BlbgogICAgICAgICAgICA/IGA8c3ZnIHZpZXdC
b3g9IjAgMCAxNiAxNiIgd2lkdGg9IjE0IiBoZWlnaHQ9IjE0IiBmaWxsPSJub25lIiBzdHJva2U9
ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIxLjgiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCI+
PHBvbHlsaW5lIHBvaW50cz0iNCAxMCA4IDYgMTIgMTAiLz48L3N2Zz48c3Bhbj7mlLbotbc8L3Nw
YW4+YAogICAgICAgICAgICA6IGA8c3ZnIHZpZXdCb3g9IjAgMCAxNiAxNiIgd2lkdGg9IjE0IiBo
ZWlnaHQ9IjE0IiBmaWxsPSJub25lIiBzdHJva2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRo
PSIxLjgiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCI+PHBvbHlsaW5lIHBvaW50cz0iNCA2IDggMTAg
MTIgNiIvPjwvc3ZnPjxzcGFuPuWxleW8gDwvc3Bhbj5gOwogICAgfQogICAgZnVuY3Rpb24gbGlz
dEV4cGFuZE1heFB4KCkgewogICAgICAgIGNvbnN0IGggPSAobGlzdEVsICYmIGxpc3RFbC5jbGll
bnRIZWlnaHQpIHx8IDM2MDsKICAgICAgICAvLyDlh6DkuY7ljaDmu6HliJfooajvvIzlupXpg6jn
lZnnuqbkuIDooYwKICAgICAgICByZXR1cm4gTWF0aC5tYXgoOTYsIGggLSAyOCk7CiAgICB9CiAg
ICBmdW5jdGlvbiBhcHBseUV4cGFuZGVkUHJldmlldyhwcmV2LCBmdWxsVGV4dCkgewogICAgICAg
IGNvbnN0IG1heEggPSBsaXN0RXhwYW5kTWF4UHgoKTsKICAgICAgICBwcmV2LnN0eWxlLm1heEhl
aWdodCA9IG1heEggKyAncHgnOwogICAgICAgIHByZXYuY2xhc3NMaXN0LmFkZCgnZXhwYW5kZWQn
KTsKICAgICAgICBzZXRIbFRleHQocHJldiwgZnVsbFRleHQpOwogICAgICAgIC8vIOS7jea6ouWH
uu+8muaIquaWreW5tuWcqOacq+WwvuWKoOOAjCAuLi7jgI0KICAgICAgICBpZiAocHJldi5zY3Jv
bGxIZWlnaHQgPD0gcHJldi5jbGllbnRIZWlnaHQgKyAyKQogICAgICAgICAgICByZXR1cm47CiAg
ICAgICAgbGV0IGxvID0gMCwgaGkgPSBmdWxsVGV4dC5sZW5ndGgsIGJlc3QgPSAwOwogICAgICAg
IHdoaWxlIChsbyA8PSBoaSkgewogICAgICAgICAgICBjb25zdCBtaWQgPSAobG8gKyBoaSkgPj4g
MTsKICAgICAgICAgICAgc2V0SGxUZXh0KHByZXYsIGZ1bGxUZXh0LnNsaWNlKDAsIG1pZCkgKyAn
IC4uLicpOwogICAgICAgICAgICBpZiAocHJldi5zY3JvbGxIZWlnaHQgPD0gcHJldi5jbGllbnRI
ZWlnaHQgKyAyKSB7CiAgICAgICAgICAgICAgICBiZXN0ID0gbWlkOwogICAgICAgICAgICAgICAg
bG8gPSBtaWQgKyAxOwogICAgICAgICAgICB9IGVsc2UgewogICAgICAgICAgICAgICAgaGkgPSBt
aWQgLSAxOwogICAgICAgICAgICB9CiAgICAgICAgfQogICAgICAgIHNldEhsVGV4dChwcmV2LCBm
dWxsVGV4dC5zbGljZSgwLCBiZXN0KSArICcgLi4uJyk7CiAgICB9CiAgICBmdW5jdGlvbiBjb2xs
YXBzZVByZXZpZXcocHJldiwgZnVsbFRleHQpIHsKICAgICAgICBwcmV2LmNsYXNzTGlzdC5yZW1v
dmUoJ2V4cGFuZGVkJyk7CiAgICAgICAgcHJldi5zdHlsZS5tYXhIZWlnaHQgPSAnJzsKICAgICAg
ICBzZXRIbFRleHQocHJldiwgZnVsbFRleHQpOwogICAgfQoKICAgIGZ1bmN0aW9uIGZhdkdyb3Vw
T2YoYykgewogICAgICAgIHJldHVybiBTdHJpbmcoYyAmJiBjLmZhdkdyb3VwIHx8ICcnKS50cmlt
KCk7CiAgICB9CiAgICBmdW5jdGlvbiBjbGlwQ29udGVudFByZXZpZXcoYykgewogICAgICAgIGNv
bnN0IHR5cGUgPSBub3JtVHlwZShjLnR5cGUpOwogICAgICAgIGlmICh0eXBlID09PSAnaW1hZ2Un
KSByZXR1cm4gJ1vlm77lg49dJyArIChjLndpZHRoICYmIGMuaGVpZ2h0ID8gKCcgJyArIGMud2lk
dGggKyAnw5cnICsgYy5oZWlnaHQpIDogJycpOwogICAgICAgIGlmICh0eXBlID09PSAnZmlsZScp
IHsKICAgICAgICAgICAgY29uc3QgZmlsZXMgPSBTdHJpbmcoYy5wcmV2aWV3IHx8IGMuZGF0YSB8
fCAnJykuc3BsaXQoL1xyP1xuLykuZmlsdGVyKEJvb2xlYW4pOwogICAgICAgICAgICByZXR1cm4g
ZmlsZXMubWFwKGYgPT4gZi5zcGxpdCgvW1xcL10vKS5wb3AoKSkuam9pbignIMK3ICcpIHx8ICdb
5paH5Lu2XSc7CiAgICAgICAgfQogICAgICAgIGxldCBfcCA9IFN0cmluZyhjLnByZXZpZXcgfHwg
Yy5kYXRhIHx8ICcnKTsKICAgICAgICB7IGNvbnN0IF9uID0gTnVtYmVyKGMuY2hhckNvdW50KSB8
fCAwOyBpZiAoX24gPiBfcC5sZW5ndGggJiYgX3AubGVuZ3RoKSBfcCArPSAnLi4uJzsgfQogICAg
ICAgIHJldHVybiBfcDsKICAgIH0KICAgIGZ1bmN0aW9uIGJ1aWxkUGlubmVkQmxvY2tzKGxpc3Qp
IHsKICAgICAgICBjb25zdCB1c2VkID0gbmV3IFNldCgpOwogICAgICAgIGNvbnN0IG91dCA9IFtd
OwogICAgICAgIGZvciAoY29uc3QgYyBvZiBsaXN0KSB7CiAgICAgICAgICAgIGlmICh1c2VkLmhh
cygrYy5pZCkpIGNvbnRpbnVlOwogICAgICAgICAgICBjb25zdCBnaWQgPSBmYXZHcm91cE9mKGMp
OwogICAgICAgICAgICBpZiAoIWdpZCkgewogICAgICAgICAgICAgICAgdXNlZC5hZGQoK2MuaWQp
OwogICAgICAgICAgICAgICAgb3V0LnB1c2goeyBraW5kOiAnc2luZ2xlJywgaXRlbXM6IFtjXSB9
KTsKICAgICAgICAgICAgICAgIGNvbnRpbnVlOwogICAgICAgICAgICB9CiAgICAgICAgICAgIGNv
bnN0IG1lbWJlcnMgPSBsaXN0LmZpbHRlcih4ID0+IGZhdkdyb3VwT2YoeCkgPT09IGdpZCk7CiAg
ICAgICAgICAgIG1lbWJlcnMuZm9yRWFjaChtID0+IHVzZWQuYWRkKCttLmlkKSk7CiAgICAgICAg
ICAgIGlmIChtZW1iZXJzLmxlbmd0aCA8IDIpCiAgICAgICAgICAgICAgICBvdXQucHVzaCh7IGtp
bmQ6ICdzaW5nbGUnLCBpdGVtczogW21lbWJlcnNbMF0gfHwgY10gfSk7CiAgICAgICAgICAgIGVs
c2UKICAgICAgICAgICAgICAgIG91dC5wdXNoKHsga2luZDogJ2dyb3VwJywgZ2lkLCBpdGVtczog
bWVtYmVycyB9KTsKICAgICAgICB9CiAgICAgICAgcmV0dXJuIG91dDsKICAgIH0KICAgIGZ1bmN0
aW9uIF9fcHJlcFBhc3RlKCkgewogICAgICAgIHRyeSB7CiAgICAgICAgICAgIGNvbnN0IHMgPSBk
b2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc2VhcmNoJyk7CiAgICAgICAgICAgIGlmIChzICYmIGRv
Y3VtZW50LmFjdGl2ZUVsZW1lbnQgPT09IHMpIHRyeSB7IHMuYmx1cigpOyB9IGNhdGNoIHt9CiAg
ICAgICAgICAgIGlmICh3aW5kb3cuZ2V0U2VsZWN0aW9uKSB3aW5kb3cuZ2V0U2VsZWN0aW9uKCku
cmVtb3ZlQWxsUmFuZ2VzKCk7CiAgICAgICAgfSBjYXRjaCB7fQogICAgfQogICAgZnVuY3Rpb24g
cGFzdGVPbmUoYykgewogICAgICAgIF9fcHJlcFBhc3RlKCk7CiAgICAgICAgc2VsZWN0ZWRJZCA9
IGMuaWQ7CiAgICAgICAgaWYgKG11bHRpSWRzLmxlbmd0aCkgY2xlYXJNdWx0aSgpOwogICAgICAg
IHN5bmNJdGVtSGlnaGxpZ2h0KCk7CiAgICAgICAgbWFya1Bhc3RlZExvY2FsKGMuaWQpOwogICAg
ICAgIGFoaygncGFzdGUnLCBTdHJpbmcoYy5pZCkpOwogICAgfQogICAgZnVuY3Rpb24gb3BlblJl
Y2VudERpcihwYXRoKSB7CiAgICAgICAgbGV0IHAgPSBTdHJpbmcocGF0aCB8fCAnJykudHJpbSgp
OwogICAgICAgIGlmICghcCkgcmV0dXJuOwogICAgICAgIGlmICgvXlthLXpBLVpdOiQvLnRlc3Qo
cCkpIHAgKz0gJ1xcJzsKICAgICAgICAvLyDnu5/kuIAgLyDvvJrpgb/lhY0gV2ViVmlldyBob3N0
L0pTT04g5ZCD5o6J5Y+N5pac5p2gCiAgICAgICAgY29uc3Qgd2lyZSA9IHAucmVwbGFjZSgvXFwv
ZywgJy8nKTsKICAgICAgICBjb25zdCBzZW5kID0gKCkgPT4gewogICAgICAgICAgICAvLyAxKSBw
b3N0TWVzc2FnZSDmnIDnqLPvvIjkuI3ov5sgc3luYyBDT03vvIkKICAgICAgICAgICAgdHJ5IHsK
ICAgICAgICAgICAgICAgIGlmICh3aW5kb3cuY2hyb21lICYmIGNocm9tZS53ZWJ2aWV3ICYmIHR5
cGVvZiBjaHJvbWUud2Vidmlldy5wb3N0TWVzc2FnZSA9PT0gJ2Z1bmN0aW9uJykgewogICAgICAg
ICAgICAgICAgICAgIGNocm9tZS53ZWJ2aWV3LnBvc3RNZXNzYWdlKCdvcGVuRGlyfCcgKyB3aXJl
KTsKICAgICAgICAgICAgICAgICAgICByZXR1cm4gdHJ1ZTsKICAgICAgICAgICAgICAgIH0KICAg
ICAgICAgICAgfSBjYXRjaCB7fQogICAgICAgICAgICAvLyAyKSBhc3luYyBob3N077yI6Z2eIHN5
bmPvvIkKICAgICAgICAgICAgdHJ5IHsKICAgICAgICAgICAgICAgIGNvbnN0IGhvc3QgPSBjaHJv
bWUud2Vidmlldy5ob3N0T2JqZWN0cy5haGs7CiAgICAgICAgICAgICAgICBpZiAoaG9zdCAmJiBo
b3N0Lm9wZW5EaXIpIHsKICAgICAgICAgICAgICAgICAgICBQcm9taXNlLnJlc29sdmUoaG9zdC5v
cGVuRGlyKHdpcmUpKS5jYXRjaCgoKSA9PiB7fSk7CiAgICAgICAgICAgICAgICAgICAgcmV0dXJu
IHRydWU7CiAgICAgICAgICAgICAgICB9CiAgICAgICAgICAgIH0gY2F0Y2gge30KICAgICAgICAg
ICAgLy8gMykg5pyA5ZCO5omNIHN5bmMKICAgICAgICAgICAgdHJ5IHsgYWhrKCdvcGVuRGlyJywg
d2lyZSk7IHJldHVybiB0cnVlOyB9IGNhdGNoIHt9CiAgICAgICAgICAgIHJldHVybiBmYWxzZTsK
ICAgICAgICB9OwogICAgICAgIC8vIOemu+W8gCBwb2ludGVyIOS6i+S7tuagiOWGjeiwg++8jOmB
v+WFjSBXZWJWaWV3MiDlkIzmraXmrbvplIHlr7zoh7TigJzngrnkuobmsqHlj43lupTigJ0KICAg
ICAgICBzZXRUaW1lb3V0KHNlbmQsIDApOwogICAgfQogICAgZnVuY3Rpb24gaXNJdGVtQ2hyb21l
VGFyZ2V0KHQpIHsKICAgICAgICByZXR1cm4gISEodCAmJiB0LmNsb3Nlc3QgJiYgdC5jbG9zZXN0
KCcuaS1leHBhbmQtYnRuLCAuaS1zcmMtaWNvLCAubWctc3JjLCAuZmQtYnRuLCAuZmQtcGF0aCwg
LnJmLXNlZywgYnV0dG9uLCBhLCBpbnB1dCcpKTsKICAgIH0KICAgIGZ1bmN0aW9uIGJlZ2luUGFz
dGVGcm9tSXRlbShlLCBjKSB7CiAgICAgICAgaWYgKGUuYnV0dG9uICE9IG51bGwgJiYgZS5idXR0
b24gIT09IDApIHJldHVybjsKICAgICAgICBjb25zdCBzZWcgPSBlLnRhcmdldCAmJiBlLnRhcmdl
dC5jbG9zZXN0ICYmIGUudGFyZ2V0LmNsb3Nlc3QoJy5yZi1zZWcnKTsKICAgICAgICBpZiAoc2Vn
KSB7CiAgICAgICAgICAgIGNvbnN0IG9wZW5QYXRoID0gc2VnLl9vcGVuUGF0aCB8fCBzZWcuZ2V0
QXR0cmlidXRlKCdkYXRhLXBhdGgnKSB8fCBzZWcuZGF0YXNldC5vcGVuUGF0aCB8fCAnJzsKICAg
ICAgICAgICAgaWYgKG9wZW5QYXRoKSB7CiAgICAgICAgICAgICAgICBlLnByZXZlbnREZWZhdWx0
KCk7CiAgICAgICAgICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgICAgICAgICAgICAg
b3BlblJlY2VudERpcihvcGVuUGF0aCk7CiAgICAgICAgICAgICAgICByZXR1cm47CiAgICAgICAg
ICAgIH0KICAgICAgICB9CiAgICAgICAgaWYgKGUudGFyZ2V0ICYmIGUudGFyZ2V0LmNsb3Nlc3Qg
JiYgZS50YXJnZXQuY2xvc2VzdCgnLnJmLXBhdGgnKSkKICAgICAgICAgICAgcmV0dXJuOwogICAg
ICAgIGlmIChpc0l0ZW1DaHJvbWVUYXJnZXQoZS50YXJnZXQpKSByZXR1cm47CiAgICAgICAgaWYg
KG5vcm1UeXBlKGMudHlwZSkgPT09ICdyZWNlbnQnKSB7CiAgICAgICAgICAgIGFjdGl2YXRlQ2xp
cEl0ZW0oYyk7CiAgICAgICAgICAgIHJldHVybjsKICAgICAgICB9CiAgICAgICAgaWYgKGhhbmRs
ZUl0ZW1DbGljayhlLCBjKSkKICAgICAgICAgICAgcmV0dXJuOwogICAgICAgIF9fcHJlcFBhc3Rl
KCk7CiAgICAgICAgc2VsZWN0ZWRJZCA9IGMuaWQ7CiAgICAgICAgcmFuZ2VBbmNob3JJZCA9IGMu
aWQ7CiAgICAgICAgICAgIGlmIChtdWx0aUlkcy5sZW5ndGggPiAwICYmIG11bHRpSWRzLmluY2x1
ZGVzKCtjLmlkKSkgewogICAgICAgICAgICBjb25zdCBpZHMgPSBtdWx0aUlkcy5zbGljZSgpOwog
ICAgICAgICAgICBjbGVhck11bHRpKCk7CiAgICAgICAgICAgIG1hcmtQYXN0ZWRMb2NhbChpZHMp
OwogICAgICAgICAgICBwYXN0ZU1hbnlXaXRoU2VwKGlkcyk7CiAgICAgICAgICAgIHJldHVybjsK
ICAgICAgICB9CiAgICAgICAgaWYgKG11bHRpSWRzLmxlbmd0aCkgY2xlYXJNdWx0aSgpOwogICAg
ICAgIHN5bmNJdGVtSGlnaGxpZ2h0KCk7CiAgICAgICAgbWFya1Bhc3RlZExvY2FsKGMuaWQpOwog
ICAgICAgIGFoaygncGFzdGUnLCBTdHJpbmcoYy5pZCkpOwogICAgfQogICAgZnVuY3Rpb24gbWFr
ZUdyb3VwSXRlbShpdGVtcywgaWR4KSB7CiAgICAgICAgY29uc3QgZWwgPSBkb2N1bWVudC5jcmVh
dGVFbGVtZW50KCdkaXYnKTsKICAgICAgICBlbC5jbGFzc05hbWUgPSAnaXRtIGl0LWdyb3VwJwog
ICAgICAgICAgICArIChpdGVtcy5zb21lKGMgPT4gK2MuaWQgPT09ICtzZWxlY3RlZElkKSA/ICcg
c2VsJyA6ICcnKQogICAgICAgICAgICArIChpdGVtcy5zb21lKGMgPT4gbXVsdGlJZHMuaW5jbHVk
ZXMoK2MuaWQpKSA/ICcgbXVsdGknIDogJycpOwogICAgICAgIGVsLmRhdGFzZXQuZ3JvdXAgPSBm
YXZHcm91cE9mKGl0ZW1zWzBdKSB8fCAnJzsKICAgICAgICBlbC5kYXRhc2V0LmlkID0gaXRlbXNb
MF0uaWQ7CgogICAgICAgIGNvbnN0IGhlYWQgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYn
KTsKICAgICAgICBoZWFkLmNsYXNzTmFtZSA9ICdtZy1oZWFkJzsKICAgICAgICBoZWFkLmlubmVy
SFRNTCA9ICc8c3BhbiBjbGFzcz0ibWctdGFnIj7lkIjlubY8L3NwYW4+PHNwYW4+JyArIGl0ZW1z
Lmxlbmd0aCArICcg5p2hIMK3IOeCueWHu+WNleadoeeymOi0tDwvc3Bhbj4nOwogICAgICAgIGVs
LmFwcGVuZENoaWxkKGhlYWQpOwoKICAgICAgICBpdGVtcy5mb3JFYWNoKGMgPT4gewogICAgICAg
ICAgICBjb25zdCByb3cgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsKICAgICAgICAg
ICAgcm93LmNsYXNzTmFtZSA9ICdtZy1yb3cnCiAgICAgICAgICAgICAgICArICgrc2VsZWN0ZWRJ
ZCA9PT0gK2MuaWQgPyAnIHNlbCcgOiAnJykKICAgICAgICAgICAgICAgICsgKG11bHRpSWRzLmlu
Y2x1ZGVzKCtjLmlkKSA/ICcgbXVsdGknIDogJycpOwogICAgICAgICAgICByb3cuZGF0YXNldC5p
ZCA9IGMuaWQ7CgogICAgICAgICAgICBjb25zdCB0b3AgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50
KCdkaXYnKTsKICAgICAgICAgICAgdG9wLmNsYXNzTmFtZSA9ICdtZy1yb3ctdG9wJzsKICAgICAg
ICAgICAgY29uc3QgbWFpbiA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOwogICAgICAg
ICAgICBtYWluLmNsYXNzTmFtZSA9ICdtZy1yb3ctbWFpbic7CgogICAgICAgICAgICBjb25zdCB0
aXRsZSA9IFN0cmluZyhjLmZhdlRpdGxlIHx8ICcnKS50cmltKCk7CiAgICAgICAgICAgIGlmICh0
aXRsZSkgewogICAgICAgICAgICAgICAgY29uc3QgdCA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQo
J2RpdicpOwogICAgICAgICAgICAgICAgdC5jbGFzc05hbWUgPSAnbWctdGl0bGUnOwogICAgICAg
ICAgICAgICAgc2V0SGxUZXh0KHQsIHRpdGxlKTsKICAgICAgICAgICAgICAgIG1haW4uYXBwZW5k
Q2hpbGQodCk7CiAgICAgICAgICAgIH0KICAgICAgICAgICAgY29uc3QgYm9keSA9IGRvY3VtZW50
LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOwogICAgICAgICAgICBib2R5LmNsYXNzTmFtZSA9ICdtZy1i
b2R5JyArIChub3JtVHlwZShjLnR5cGUpID09PSAnaW1hZ2UnID8gJyBpbWcnIDogJycpOwogICAg
ICAgICAgICBzZXRIbFRleHQoYm9keSwgY2xpcENvbnRlbnRQcmV2aWV3KGMpKTsKICAgICAgICAg
ICAgbWFpbi5hcHBlbmRDaGlsZChib2R5KTsKICAgICAgICAgICAgdG9wLmFwcGVuZENoaWxkKG1h
aW4pOwoKICAgICAgICAgICAgY29uc3Qgc3JjSWNvID0gU3RyaW5nKGMuc3JjSWNvbiB8fCAnJyk7
CiAgICAgICAgICAgIGNvbnN0IHNyY0V4ZSA9IFN0cmluZyhjLnNyY0V4ZSB8fCAnJyk7CiAgICAg
ICAgICAgIGNvbnN0IHNyY1RpdGxlID0gU3RyaW5nKGMuc3JjVGl0bGUgfHwgJycpOwogICAgICAg
ICAgICBpZiAoc3JjSWNvKSB7CiAgICAgICAgICAgICAgICBjb25zdCBpbWcgPSBkb2N1bWVudC5j
cmVhdGVFbGVtZW50KCdpbWcnKTsKICAgICAgICAgICAgICAgIGltZy5jbGFzc05hbWUgPSAnbWct
c3JjJzsKICAgICAgICAgICAgICAgIGltZy5zcmMgPSBTVE9SRV9CQVNFICsgZW5jb2RlVVJJQ29t
cG9uZW50KHNyY0ljbyk7CiAgICAgICAgICAgICAgICBpbWcuYWx0ID0gJyc7CiAgICAgICAgICAg
ICAgICBjb25zdCB0aXBUeHQgPSBzcmNUaXRsZSB8fCBzcmNFeGUgfHwgJ+adpea6kCc7CiAgICAg
ICAgICAgICAgICBpbWcudGl0bGUgPSB0aXBUeHQ7CiAgICAgICAgICAgICAgICBpbWcub25jbGlj
ayA9IGUgPT4geyBlLnByZXZlbnREZWZhdWx0KCk7IGUuc3RvcFByb3BhZ2F0aW9uKCk7IHNob3dT
cmNUaXAoaW1nLCB0aXBUeHQpOyB9OwogICAgICAgICAgICAgICAgdG9wLmFwcGVuZENoaWxkKGlt
Zyk7CiAgICAgICAgICAgIH0KICAgICAgICAgICAgcm93LmFwcGVuZENoaWxkKHRvcCk7CgogICAg
ICAgICAgICByb3cub25wb2ludGVyZG93biA9IGUgPT4gewogICAgICAgICAgICAgICAgaWYgKGUu
YnV0dG9uICE9PSAwKSByZXR1cm47CiAgICAgICAgICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigp
OwogICAgICAgICAgICAgICAgYmVnaW5QYXN0ZUZyb21JdGVtKGUsIGMpOwogICAgICAgICAgICB9
OwogICAgICAgICAgICByb3cub25jb250ZXh0bWVudSA9IGUgPT4gewogICAgICAgICAgICAgICAg
ZS5wcmV2ZW50RGVmYXVsdCgpOwogICAgICAgICAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsK
ICAgICAgICAgICAgICAgIHNlbGVjdGVkSWQgPSBjLmlkOwogICAgICAgICAgICAgICAgc2hvd0N0
eChlLmNsaWVudFgsIGUuY2xpZW50WSwgYyk7CiAgICAgICAgICAgIH07CiAgICAgICAgICAgIGVs
LmFwcGVuZENoaWxkKHJvdyk7CiAgICAgICAgfSk7CgogICAgICAgIGVsLm9uY29udGV4dG1lbnUg
PSBlID0+IHsKICAgICAgICAgICAgaWYgKGUudGFyZ2V0LmNsb3Nlc3QoJy5tZy1yb3cnKSkgcmV0
dXJuOwogICAgICAgICAgICBlLnByZXZlbnREZWZhdWx0KCk7CiAgICAgICAgICAgIHNlbGVjdGVk
SWQgPSBpdGVtc1swXS5pZDsKICAgICAgICAgICAgc2hvd0N0eChlLmNsaWVudFgsIGUuY2xpZW50
WSwgaXRlbXNbMF0pOwogICAgICAgIH07CiAgICAgICAgcmV0dXJuIGVsOwogICAgfQoKCiAgICBm
dW5jdGlvbiBidWlsZFJlY2VudFBhdGhDcnVtYnMoY29udGFpbmVyLCBmdWxsUGF0aCkgewogICAg
ICAgIGlmICghY29udGFpbmVyKSByZXR1cm47CiAgICAgICAgY29udGFpbmVyLnF1ZXJ5U2VsZWN0
b3JBbGwoJy5yZi1zZWcsIC5yZi1zZXAnKS5mb3JFYWNoKG4gPT4gbi5yZW1vdmUoKSk7CiAgICAg
ICAgY29uc3QgcmF3ID0gU3RyaW5nKGZ1bGxQYXRoIHx8ICcnKS5yZXBsYWNlKC9cLy9nLCAnXFwn
KS5yZXBsYWNlKC9cXCskLywgJycpOwogICAgICAgIGlmICghcmF3KSByZXR1cm47CiAgICAgICAg
Y29uc3QgdW5jID0gcmF3LnN0YXJ0c1dpdGgoJ1xcXFwnKTsKICAgICAgICBsZXQgcmVzdCA9IHVu
YyA/IHJhdy5zbGljZSgyKSA6IHJhdzsKICAgICAgICBjb25zdCBwYXJ0cyA9IHJlc3Quc3BsaXQo
J1xcJykuZmlsdGVyKEJvb2xlYW4pOwogICAgICAgIGNvbnN0IGFkZFNlZyA9IChsYWJlbCwgb3Bl
blBhdGgpID0+IHsKICAgICAgICAgICAgaWYgKGNvbnRhaW5lci5xdWVyeVNlbGVjdG9yKCcucmYt
c2VnLCAucmYtc2VwJykpIHsKICAgICAgICAgICAgICAgIGNvbnN0IHNlcCA9IGRvY3VtZW50LmNy
ZWF0ZUVsZW1lbnQoJ3NwYW4nKTsKICAgICAgICAgICAgICAgIHNlcC5jbGFzc05hbWUgPSAncmYt
c2VwJzsKICAgICAgICAgICAgICAgIHNlcC50ZXh0Q29udGVudCA9ICdcXCc7CiAgICAgICAgICAg
ICAgICBjb250YWluZXIuYXBwZW5kQ2hpbGQoc2VwKTsKICAgICAgICAgICAgfQogICAgICAgICAg
ICAvLyBidXR0b27vvJrlkb3kuK3mm7TnqLPvvIzkuI3ooqsgYXBwLXJlZ2lvbiAvIOeItue6pyBw
b2ludGVyIOWQg+aOiQogICAgICAgICAgICBjb25zdCBzZWcgPSBkb2N1bWVudC5jcmVhdGVFbGVt
ZW50KCdidXR0b24nKTsKICAgICAgICAgICAgc2VnLnR5cGUgPSAnYnV0dG9uJzsKICAgICAgICAg
ICAgc2VnLmNsYXNzTmFtZSA9ICdyZi1zZWcnOwogICAgICAgICAgICBzZXRIbFRleHQoc2VnLCBs
YWJlbCk7CiAgICAgICAgICAgIHNlZy50aXRsZSA9ICfmiZPlvIA6ICcgKyBvcGVuUGF0aDsKICAg
ICAgICAgICAgc2VnLnNldEF0dHJpYnV0ZSgnZGF0YS1wYXRoJywgb3BlblBhdGgucmVwbGFjZSgv
XFwvZywgJy8nKSk7CiAgICAgICAgICAgIHNlZy5fb3BlblBhdGggPSBvcGVuUGF0aDsKICAgICAg
ICAgICAgc2VnLmFkZEV2ZW50TGlzdGVuZXIoJ2NsaWNrJywgZSA9PiB7CiAgICAgICAgICAgICAg
ICBlLnByZXZlbnREZWZhdWx0KCk7CiAgICAgICAgICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigp
OwogICAgICAgICAgICAgICAgb3BlblJlY2VudERpcihvcGVuUGF0aCk7CiAgICAgICAgICAgIH0s
IHRydWUpOwogICAgICAgICAgICBzZWcuYWRkRXZlbnRMaXN0ZW5lcigncG9pbnRlcmRvd24nLCBl
ID0+IHsKICAgICAgICAgICAgICAgIGlmIChlLmJ1dHRvbiAhPT0gMCkgcmV0dXJuOwogICAgICAg
ICAgICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOwogICAgICAgICAgICAgICAgZS5zdG9wUHJvcGFn
YXRpb24oKTsKICAgICAgICAgICAgICAgIG9wZW5SZWNlbnREaXIob3BlblBhdGgpOwogICAgICAg
ICAgICB9LCB0cnVlKTsKICAgICAgICAgICAgY29udGFpbmVyLmFwcGVuZENoaWxkKHNlZyk7CiAg
ICAgICAgfTsKICAgICAgICBpZiAoIXBhcnRzLmxlbmd0aCkgewogICAgICAgICAgICBhZGRTZWco
cmF3LCByYXcpOwogICAgICAgICAgICByZXR1cm47CiAgICAgICAgfQogICAgICAgIGxldCBhY2Mg
PSB1bmMgPyAnXFxcXCcgKyBwYXJ0c1swXSA6IHBhcnRzWzBdOwogICAgICAgIGlmICghdW5jICYm
IC9eW2EtekEtWl06JC8udGVzdChwYXJ0c1swXSkpCiAgICAgICAgICAgIGFjYyA9IHBhcnRzWzBd
ICsgJ1xcJzsKICAgICAgICBhZGRTZWcocGFydHNbMF0sIGFjYyk7CiAgICAgICAgZm9yIChsZXQg
aSA9IDE7IGkgPCBwYXJ0cy5sZW5ndGg7IGkrKykgewogICAgICAgICAgICBhY2MgPSBhY2MucmVw
bGFjZSgvXFwrJC8sICcnKSArICdcXCcgKyBwYXJ0c1tpXTsKICAgICAgICAgICAgYWRkU2VnKHBh
cnRzW2ldLCBhY2MpOwogICAgICAgIH0KICAgIH0KCiAgICBmdW5jdGlvbiBhY3RpdmF0ZUNsaXBJ
dGVtKGMpIHsKICAgICAgICBpZiAoIWMpIHJldHVybjsKICAgICAgICBpZiAobm9ybVR5cGUoYy50
eXBlKSA9PT0gJ3JlY2VudCcpIHsKICAgICAgICAgICAgX19wcmVwUGFzdGUoKTsKICAgICAgICAg
ICAgc2VsZWN0ZWRJZCA9IGMuaWQ7CiAgICAgICAgICAgIGlmIChtdWx0aUlkcy5sZW5ndGgpIGNs
ZWFyTXVsdGkoKTsKICAgICAgICAgICAgc3luY0l0ZW1IaWdobGlnaHQoKTsKICAgICAgICAgICAg
YWhrKCdwYXN0ZScsIFN0cmluZyhjLmlkKSk7CiAgICAgICAgICAgIHJldHVybjsKICAgICAgICB9
CiAgICAgICAgcGFzdGVPbmUoYyk7CiAgICB9CiAgICBmdW5jdGlvbiBtYWtlSXRlbShjLCBpZHgp
IHsKICAgICAgICBjb25zdCB0eXBlICAgPSBub3JtVHlwZShjLnR5cGUpOwogICAgICAgIGNvbnN0
IHBpbm5lZCA9IGlzUGlubmVkKGMpOwogICAgICAgIGNvbnN0IHBhc3RlZCA9IGlzUGFzdGVkKGMp
OwogICAgICAgIGNvbnN0IGVsICAgICA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOwog
ICAgICAgIGVsLmNsYXNzTmFtZSAgPSAnaXRtJwogICAgICAgICAgICArIChzZWxlY3RlZElkID09
IGMuaWQgPyAnIHNlbCcgOiAnJykKICAgICAgICAgICAgKyAobXVsdGlJZHMuaW5jbHVkZXMoK2Mu
aWQpID8gJyBtdWx0aScgOiAnJyk7CiAgICAgICAgZWwuZGF0YXNldC5pZCA9IGMuaWQ7CiAgICAg
ICAgY29uc3QgcWcgPSBOdW1iZXIoYy5xdWV1ZUdyb3VwKSB8fCAwOwogICAgICAgIGlmIChxZyA+
IDApIHsKICAgICAgICAgICAgZWwuY2xhc3NMaXN0LmFkZCgncS1tZW1iZXInKTsKICAgICAgICAg
ICAgZWwuZGF0YXNldC5xZyA9IFN0cmluZyhxZyk7CiAgICAgICAgICAgIGVsLmRhdGFzZXQucWkg
PSBTdHJpbmcoTnVtYmVyKGMucXVldWVJbmRleCkgfHwgMCk7CiAgICAgICAgICAgIGlmIChwYXN0
ZWQpIGVsLmNsYXNzTGlzdC5hZGQoJ3EtZG9uZScpOwogICAgICAgICAgICBjb25zdCByYWlsID0g
ZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnc3BhbicpOwogICAgICAgICAgICByYWlsLmNsYXNzTmFt
ZSA9ICdxLXJhaWwnOwogICAgICAgICAgICBjb25zdCBkb3QgPSBkb2N1bWVudC5jcmVhdGVFbGVt
ZW50KCdzcGFuJyk7CiAgICAgICAgICAgIGRvdC5jbGFzc05hbWUgPSAncS1kb3QnOwogICAgICAg
ICAgICBkb3QudGl0bGUgPSBwYXN0ZWQgPyAn6Zif5YiX5bey57KY6LS0JyA6ICfnspjotLTpmJ/l
iJcnOwogICAgICAgICAgICBlbC5hcHBlbmRDaGlsZChyYWlsKTsKICAgICAgICAgICAgZWwuYXBw
ZW5kQ2hpbGQoZG90KTsKICAgICAgICB9CgogICAgICAgIGNvbnN0IGljbyAgPSBkb2N1bWVudC5j
cmVhdGVFbGVtZW50KCdkaXYnKTsKICAgICAgICBjb25zdCBib2R5ID0gZG9jdW1lbnQuY3JlYXRl
RWxlbWVudCgnZGl2Jyk7CiAgICAgICAgYm9keS5jbGFzc05hbWUgPSAnaS1ib2R5JzsKCiAgICAg
ICAgaWYgKHR5cGUgPT09ICdpbWFnZScpIHsKICAgICAgICAgICAgaWNvLmNsYXNzTmFtZSA9ICdp
LWljbyBpbWFnZSc7CiAgICAgICAgICAgIGljby5pbm5lckhUTUwgPSBTVkcuaW1hZ2U7CiAgICAg
ICAgICAgIGJpbmRJbWdIb3ZlclByZXZpZXcoaWNvLCBjLmlkLCBjLmltZ0ZpbGUpOwogICAgICAg
ICAgICBjb25zdCB3cmFwID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnZGl2Jyk7CiAgICAgICAg
ICAgIHdyYXAuY2xhc3NOYW1lID0gJ2ktdGh1bWItd3JhcCc7CiAgICAgICAgICAgIGNvbnN0IGlt
ZyAgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdpbWcnKTsKICAgICAgICAgICAgaW1nLmNsYXNz
TmFtZSA9ICdpLXRodW1iJzsKICAgICAgICAgICAgaW1nLmFsdCA9ICcnOwogICAgICAgICAgICBj
b25zdCBmaWxlID0gU3RyaW5nKGMuaW1nRmlsZSB8fCAnJyk7CiAgICAgICAgICAgIGxldCBmYWxs
YmFjayA9IFN0cmluZyhjLmRhdGEgfHwgJycpOwogICAgICAgICAgICAvLyBOZXZlciBzeW5jLWNh
bGwgQUhLIHRodW1iIGhlcmUg4oCUIGZyZWV6ZXMgdGFiIHN3aXRjaGVzOyBQdXNoU3RvcmVUaHVt
YnMgZmlsbHMgYXN5bmMKICAgICAgICAgICAgaWYgKCFmYWxsYmFjay5zdGFydHNXaXRoKCdkYXRh
OicpICYmIHRodW1iQ2FjaGUuaGFzKFN0cmluZyhjLmlkKSkpCiAgICAgICAgICAgICAgICBmYWxs
YmFjayA9IFN0cmluZyh0aHVtYkNhY2hlLmdldChTdHJpbmcoYy5pZCkpKTsKICAgICAgICAgICAg
aW1nLm9ubG9hZCA9ICgpID0+IHsKICAgICAgICAgICAgICAgIGNvbnN0IG13ID0gd3JhcC5jbGll
bnRXaWR0aCB8fCAzMDA7CiAgICAgICAgICAgICAgICBjb25zdCBudyA9IGltZy5uYXR1cmFsV2lk
dGggIHx8IDA7CiAgICAgICAgICAgICAgICBjb25zdCBuaCA9IGltZy5uYXR1cmFsSGVpZ2h0IHx8
IDA7CiAgICAgICAgICAgICAgICBpZiAoIW53IHx8ICFuaCkgcmV0dXJuOwogICAgICAgICAgICAg
ICAgY29uc3Qgc2NhbGUgPSBNYXRoLm1pbigxLCAxODAgLyBuaCwgbXcgLyBudyk7CiAgICAgICAg
ICAgICAgICBpbWcuc3R5bGUud2lkdGggID0gTWF0aC5yb3VuZChudyAqIHNjYWxlKSArICdweCc7
CiAgICAgICAgICAgICAgICBpbWcuc3R5bGUuaGVpZ2h0ID0gTWF0aC5yb3VuZChuaCAqIHNjYWxl
KSArICdweCc7CiAgICAgICAgICAgIH07CiAgICAgICAgICAgIGJpbmRTdG9yZVRodW1iKGltZywg
ZmlsZSwgYy5pZCwgZmFsbGJhY2spOwogICAgICAgICAgICB3cmFwLmFwcGVuZENoaWxkKGltZyk7
CiAgICAgICAgICAgIGNvbnN0IG1ldGEgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsK
ICAgICAgICAgICAgbWV0YS5jbGFzc05hbWUgPSAnaS1tZXRhJzsKICAgICAgICAgICAgbWV0YS5p
bm5lckhUTUwgID0gYDxzcGFuIGNsYXNzPSJpLXRpbWUiPiR7YWdvKGMudGltZSl9PC9zcGFuPiR7
bWV0YUNlbnRlckh0bWwoZmFsc2UpfTxkaXYgY2xhc3M9ImktbWV0YS1yaWdodCI+JHtjLndpZHRo
ID8gYDxzcGFuIGNsYXNzPSJpLXRhZyI+JHtjLndpZHRofcOXJHtjLmhlaWdodH0gcHg8L3NwYW4+
YCA6ICcnfTwvZGl2PmA7CiAgICAgICAgICAgIGJvZHkuYXBwZW5kQ2hpbGQod3JhcCk7CiAgICAg
ICAgICAgIGJvZHkuYXBwZW5kQ2hpbGQobWV0YSk7CiAgICAgICAgfSBlbHNlIGlmICh0eXBlID09
PSAncmVjZW50JykgewogICAgICAgICAgICBpY28uY2xhc3NOYW1lID0gJ2ktaWNvIGZpbGUgZnQt
ZGlyJzsKICAgICAgICAgICAgaWNvLmlubmVySFRNTCA9IFNWRy5mb2xkZXI7CiAgICAgICAgICAg
IGlmIChwaW5uZWQpIGVsLmNsYXNzTGlzdC5hZGQoJ3JmLWZpeGVkJyk7CiAgICAgICAgICAgIGNv
bnN0IHBhdGggPSBTdHJpbmcoYy5kYXRhIHx8IGMucHJldmlldyB8fCAnJyk7CiAgICAgICAgICAg
IGNvbnN0IGNydW1icyA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOwogICAgICAgICAg
ICBjcnVtYnMuY2xhc3NOYW1lID0gJ3JmLXBhdGgnOwogICAgICAgICAgICBidWlsZFJlY2VudFBh
dGhDcnVtYnMoY3J1bWJzLCBwYXRoKTsKICAgICAgICAgICAgLy8g5Zu65a6a5qCH6K6w5Y+q5pS+
IG1ldGEg5Y+z5L6n77yM5LiN5oyh6Lev5b6ECiAgICAgICAgICAgIGNvbnN0IG1ldGEgPSBkb2N1
bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsKICAgICAgICAgICAgbWV0YS5jbGFzc05hbWUgPSAn
aS1tZXRhJzsKICAgICAgICAgICAgbWV0YS5pbm5lckhUTUwgPQogICAgICAgICAgICAgICAgYDxz
cGFuIGNsYXNzPSJpLXRpbWUiPiR7YWdvKGMudGltZSl9PC9zcGFuPmAgKwogICAgICAgICAgICAg
ICAgbWV0YUNlbnRlckh0bWwoZmFsc2UpICsKICAgICAgICAgICAgICAgIGA8ZGl2IGNsYXNzPSJp
LW1ldGEtcmlnaHQiPiR7cGlubmVkID8gJzxzcGFuIGNsYXNzPSJyZi1waW4tdGFnIiB0aXRsZT0i
5bey5Zu65a6a77yM5LiN5Lya6KKr5reY5rGwIj7lm7rlrpo8L3NwYW4+JyA6ICcnfTwvZGl2PmA7
CiAgICAgICAgICAgIGJvZHkuYXBwZW5kQ2hpbGQoY3J1bWJzKTsKICAgICAgICAgICAgYm9keS5h
cHBlbmRDaGlsZChtZXRhKTsKICAgICAgICB9IGVsc2UgaWYgKHR5cGUgPT09ICdmaWxlJykgewog
ICAgICAgICAgICBjb25zdCBmaWxlcyA9IFN0cmluZyhjLnByZXZpZXcgfHwgYy5kYXRhIHx8ICcn
KS5zcGxpdCgvXHI/XG4vKS5maWx0ZXIoQm9vbGVhbik7CiAgICAgICAgICAgIGNvbnN0IGltYWdl
UGF0aHMgPSBmaWxlcy5maWx0ZXIoZiA9PiBpc0ltYWdlRXh0KGZpbGVFeHQoZikpKTsKICAgICAg
ICAgICAgY29uc3QgaWMgICAgPSBpY29uRm9yRmlsZXMoZmlsZXMpOwogICAgICAgICAgICBpY28u
Y2xhc3NOYW1lID0gJ2ktaWNvICcgKyBpYy5jbHM7CiAgICAgICAgICAgIGljby5pbm5lckhUTUwg
PSBpYy5zdmc7CgogICAgICAgICAgICBsZXQgdGh1bWJGaWxlID0gU3RyaW5nKGMuaW1nRmlsZSB8
fCAnJyk7CiAgICAgICAgICAgIC8qIGVuc3VyZUZpbGVJbWcgZGVmZXJyZWQ6IGF2b2lkIHN5bmMg
ZnJlZXplIG9uIGZpbGUgdGFiICovCgogICAgICAgICAgICAvLyBJbWFnZS1mb3JtYXQgZmlsZXM6
IHNhbWUgdGh1bWJuYWlsIHJ1bGVzIGFzIHNjcmVlbnNob3QgY2xpcHMKICAgICAgICAgICAgaWYg
KHRodW1iRmlsZSB8fCBpbWFnZVBhdGhzLmxlbmd0aCkgewogICAgICAgICAgICAgICAgY29uc3Qg
d3JhcCA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOwogICAgICAgICAgICAgICAgd3Jh
cC5jbGFzc05hbWUgPSAnaS10aHVtYi13cmFwJzsKICAgICAgICAgICAgICAgIGNvbnN0IGltZyAg
PSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdpbWcnKTsKICAgICAgICAgICAgICAgIGltZy5jbGFz
c05hbWUgPSAnaS10aHVtYic7CiAgICAgICAgICAgICAgICBpbWcuYWx0ID0gJyc7CiAgICAgICAg
ICAgICAgICBpbWcub25sb2FkID0gKCkgPT4gewogICAgICAgICAgICAgICAgICAgIGNvbnN0IG13
ID0gd3JhcC5jbGllbnRXaWR0aCB8fCAzMDA7CiAgICAgICAgICAgICAgICAgICAgY29uc3Qgbncg
PSBpbWcubmF0dXJhbFdpZHRoICB8fCAwOwogICAgICAgICAgICAgICAgICAgIGNvbnN0IG5oID0g
aW1nLm5hdHVyYWxIZWlnaHQgfHwgMDsKICAgICAgICAgICAgICAgICAgICBpZiAoIW53IHx8ICFu
aCkgcmV0dXJuOwogICAgICAgICAgICAgICAgICAgIGNvbnN0IHNjYWxlID0gTWF0aC5taW4oMSwg
MTgwIC8gbmgsIG13IC8gbncpOwogICAgICAgICAgICAgICAgICAgIGltZy5zdHlsZS53aWR0aCAg
PSBNYXRoLnJvdW5kKG53ICogc2NhbGUpICsgJ3B4JzsKICAgICAgICAgICAgICAgICAgICBpbWcu
c3R5bGUuaGVpZ2h0ID0gTWF0aC5yb3VuZChuaCAqIHNjYWxlKSArICdweCc7CiAgICAgICAgICAg
ICAgICB9OwogICAgICAgICAgICAvKiBlbnN1cmVGaWxlSW1nIGRlZmVycmVkOiBhdm9pZCBzeW5j
IGZyZWV6ZSBvbiBmaWxlIHRhYiAqLwogICAgICAgICAgICAgICAgYmluZFN0b3JlVGh1bWIoaW1n
LCB0aHVtYkZpbGUsIGMuaWQsICcnKTsKICAgICAgICAgICAgICAgIHdyYXAuYXBwZW5kQ2hpbGQo
aW1nKTsKICAgICAgICAgICAgICAgIGJvZHkuYXBwZW5kQ2hpbGQod3JhcCk7CiAgICAgICAgICAg
IH0KCiAgICAgICAgICAgIGNvbnN0IG5hbWUgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYn
KTsKICAgICAgICAgICAgbmFtZS5jbGFzc05hbWUgID0gJ2ktbmFtZSc7CiAgICAgICAgICAgIHNl
dEhsVGV4dChuYW1lLCBmaWxlcy5tYXAoZiA9PiBmLnNwbGl0KC9bXFwvXS8pLnBvcCgpKS5qb2lu
KCdcbicpIHx8ICco5paH5Lu2KScpOwoKICAgICAgICAgICAgZWwuX2ZpbGVQYXRocyA9IGZpbGVz
OwoKICAgICAgICAgICAgY29uc3QgZGV0YWlsID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnZGl2
Jyk7CiAgICAgICAgICAgIGRldGFpbC5jbGFzc05hbWUgPSAnaS1maWxlLWRldGFpbCc7CgogICAg
ICAgICAgICBjb25zdCBtZXRhID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnZGl2Jyk7CiAgICAg
ICAgICAgIG1ldGEuY2xhc3NOYW1lID0gJ2ktbWV0YSc7CiAgICAgICAgICAgIGxldCByaWdodCA9
ICcnOwogICAgICAgICAgICByaWdodCArPSBgPHNwYW4gY2xhc3M9ImktdGFnIj4ke2MuZmlsZUNv
dW50IHx8IGZpbGVzLmxlbmd0aCB8fCAxfSDkuKrmlofku7Y8L3NwYW4+YDsKICAgICAgICAgICAg
aWYgKCh0aHVtYkZpbGUgfHwgaW1hZ2VQYXRocy5sZW5ndGgpICYmIGMud2lkdGgpCiAgICAgICAg
ICAgICAgICByaWdodCArPSBgPHNwYW4gY2xhc3M9ImktdGFnIj4ke2Mud2lkdGh9w5cke2MuaGVp
Z2h0fSBweDwvc3Bhbj5gOwogICAgICAgICAgICBjb25zdCBleHBhbmRIdG1sID0gZXhwYW5kQ2hl
dnJvbihmYWxzZSk7CiAgICAgICAgICAgIGNvbnN0IGNvbGxhcHNlSHRtbCA9IGV4cGFuZENoZXZy
b24odHJ1ZSk7CiAgICAgICAgICAgIG1ldGEuaW5uZXJIVE1MID0KICAgICAgICAgICAgICAgIGA8
c3BhbiBjbGFzcz0iaS10aW1lIj4ke2FnbyhjLnRpbWUpfTwvc3Bhbj5gICsKICAgICAgICAgICAg
ICAgIG1ldGFDZW50ZXJIdG1sKHsgb246IHRydWUsIGh0bWw6IGV4cGFuZEh0bWwgfSkgKwogICAg
ICAgICAgICAgICAgYDxkaXYgY2xhc3M9ImktbWV0YS1yaWdodCI+JHtyaWdodH08L2Rpdj5gOwoK
ICAgICAgICAgICAgY29uc3QgZXhwQnRuID0gbWV0YS5xdWVyeVNlbGVjdG9yKCcuaS1leHBhbmQt
YnRuJyk7CiAgICAgICAgICAgIGxldCBkZXRhaWxCdWlsdCA9IGZhbHNlOwogICAgICAgICAgICBl
eHBCdG4ub25jbGljayA9IGUgPT4gewogICAgICAgICAgICAgICAgZS5wcmV2ZW50RGVmYXVsdCgp
OwogICAgICAgICAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICAgICAgICAgIGNv
bnN0IG9wZW4gPSAhZGV0YWlsLmNsYXNzTGlzdC5jb250YWlucygnb24nKTsKICAgICAgICAgICAg
ICAgIGlmIChvcGVuICYmICFkZXRhaWxCdWlsdCkgewogICAgICAgICAgICAgICAgICAgIGNvbnN0
IHBhdGhSb3dzID0gZWwuX3BhdGhSb3dzIHx8IGNoZWNrRmlsZVBhdGhzKGVsLl9maWxlUGF0aHMg
fHwgZmlsZXMpOwogICAgICAgICAgICAgICAgICAgIGZpbGxGaWxlRGV0YWlsUGFuZWwoZGV0YWls
LCBwYXRoUm93cyk7CiAgICAgICAgICAgICAgICAgICAgZGV0YWlsQnVpbHQgPSB0cnVlOwogICAg
ICAgICAgICAgICAgfQogICAgICAgICAgICAgICAgZGV0YWlsLmNsYXNzTGlzdC50b2dnbGUoJ29u
Jywgb3Blbik7CiAgICAgICAgICAgICAgICBpZiAob3BlbikgewogICAgICAgICAgICAgICAgICAg
IGRldGFpbC5zdHlsZS5tYXhIZWlnaHQgPSBsaXN0RXhwYW5kTWF4UHgoKSArICdweCc7CiAgICAg
ICAgICAgICAgICAgICAgZGV0YWlsLnN0eWxlLm92ZXJmbG93ID0gJ2F1dG8nOwogICAgICAgICAg
ICAgICAgfSBlbHNlIHsKICAgICAgICAgICAgICAgICAgICBkZXRhaWwuc3R5bGUubWF4SGVpZ2h0
ID0gJyc7CiAgICAgICAgICAgICAgICAgICAgZGV0YWlsLnN0eWxlLm92ZXJmbG93ID0gJyc7CiAg
ICAgICAgICAgICAgICB9CiAgICAgICAgICAgICAgICBleHBCdG4uaW5uZXJIVE1MID0gb3BlbiA/
IGNvbGxhcHNlSHRtbCA6IGV4cGFuZEh0bWw7CiAgICAgICAgICAgIH07CgogICAgICAgICAgICBi
b2R5LmFwcGVuZENoaWxkKG5hbWUpOwogICAgICAgICAgICBib2R5LmFwcGVuZENoaWxkKGRldGFp
bCk7CiAgICAgICAgICAgIGJvZHkuYXBwZW5kQ2hpbGQobWV0YSk7CiAgICAgICAgfSBlbHNlIHsK
ICAgICAgICAgICAgY29uc3QgdXNlTSA9IGNsaXBVc2VzTUljb24oYyk7CiAgICAgICAgICAgIGlj
by5jbGFzc05hbWUgPSB1c2VNID8gJ2ktaWNvIG1kJyA6ICdpLWljbyB0ZXh0JzsKICAgICAgICAg
ICAgaWNvLmlubmVySFRNTCA9IHVzZU0gPyAoU1ZHLm1kIHx8IFNWRy50ZXh0KSA6IFNWRy50ZXh0
OwogICAgICAgICAgICAvKiBwbGFpbi1saXN0LXByZXYgKi8KICAgICAgICAgICAgLyogcHJldmll
dy1lbGxpcHNpcyAqLwogICAgICAgICAgICBsZXQgdHh0ICA9IGMucHJldmlldyB8fCBjLmRhdGEg
fHwgJyc7CiAgICAgICAgICAgIHsgY29uc3QgX24gPSBOdW1iZXIoYy5jaGFyQ291bnQpIHx8IDA7
IGlmIChfbiA+IHR4dC5sZW5ndGggJiYgdHh0Lmxlbmd0aCkgdHh0ICs9ICcuLi4nOyB9CiAgICAg
ICAgICAgIGNvbnN0IHByZXYgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsKICAgICAg
ICAgICAgcHJldi5jbGFzc05hbWUgID0gJ2ktcHJldicgKyAoaXNVcmwodHh0KSA/ICcgdXJsJyA6
ICcnKTsKICAgICAgICAgICAgc2V0SGxUZXh0KHByZXYsIHR4dCk7CgogICAgICAgICAgICBjb25z
dCBtZXRhID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnZGl2Jyk7CiAgICAgICAgICAgIG1ldGEu
Y2xhc3NOYW1lID0gJ2ktbWV0YSc7CgogICAgICAgICAgICBjb25zdCBjaGFycyA9IE51bWJlcihj
LmNoYXJDb3VudCkgfHwgMDsKICAgICAgICAgICAgY29uc3QgcmlnaHRIVE1MID0gYDxzcGFuIGNs
YXNzPSJpLWNoYXJzIj48c3BhbiBjbGFzcz0ibiI+JHtjaGFyc308L3NwYW4+IOWtl+espjwvc3Bh
bj5gOwoKICAgICAgICAgICAgbWV0YS5pbm5lckhUTUwgPQogICAgICAgICAgICAgICAgYDxzcGFu
IGNsYXNzPSJpLXRpbWUiPiR7YWdvKGMudGltZSl9PC9zcGFuPmAgKwogICAgICAgICAgICAgICAg
bWV0YUNlbnRlckh0bWwoewogICAgICAgICAgICAgICAgICAgIG9uOiBmYWxzZSwKICAgICAgICAg
ICAgICAgICAgICBodG1sOiBleHBhbmRDaGV2cm9uKGZhbHNlKQogICAgICAgICAgICAgICAgfSkg
KwogICAgICAgICAgICAgICAgYDxkaXYgY2xhc3M9ImktbWV0YS1yaWdodCB0ZXh0LW1ldGEiPiR7
cmlnaHRIVE1MfTwvZGl2PmA7CgogICAgICAgICAgICBib2R5LmFwcGVuZENoaWxkKHByZXYpOwog
ICAgICAgICAgICBib2R5LmFwcGVuZENoaWxkKG1ldGEpOwoKICAgICAgICAgICAgY29uc3QgZXhw
QnRuID0gbWV0YS5xdWVyeVNlbGVjdG9yKCcuaS1leHBhbmQtYnRuJyk7CiAgICAgICAgICAgIGlm
IChleHBCdG4pIHsKICAgICAgICAgICAgICAgIGV4cEJ0bi5vbmNsaWNrID0gZSA9PiB7CiAgICAg
ICAgICAgICAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICAgICAgICAgICAgICBj
b25zdCB3aWxsRXhwYW5kID0gIXByZXYuY2xhc3NMaXN0LmNvbnRhaW5zKCdleHBhbmRlZCcpOwog
ICAgICAgICAgICAgICAgICAgIGlmICh3aWxsRXhwYW5kKSB7CiAgICAgICAgICAgICAgICAgICAg
ICAgIGFwcGx5RXhwYW5kZWRQcmV2aWV3KHByZXYsIHR4dCk7CiAgICAgICAgICAgICAgICAgICAg
ICAgIGV4cEJ0bi5pbm5lckhUTUwgPSBleHBhbmRDaGV2cm9uKHRydWUpOwogICAgICAgICAgICAg
ICAgICAgICAgICB0cnkgeyBlbC5zY3JvbGxJbnRvVmlldyh7IGJsb2NrOiAnbmVhcmVzdCcgfSk7
IH0gY2F0Y2gge30KICAgICAgICAgICAgICAgICAgICB9IGVsc2UgewogICAgICAgICAgICAgICAg
ICAgICAgICBjb2xsYXBzZVByZXZpZXcocHJldiwgdHh0KTsKICAgICAgICAgICAgICAgICAgICAg
ICAgZXhwQnRuLmlubmVySFRNTCA9IGV4cGFuZENoZXZyb24oZmFsc2UpOwogICAgICAgICAgICAg
ICAgICAgIH0KICAgICAgICAgICAgICAgIH07CiAgICAgICAgICAgICAgICBjb25zdCBjaGVja092
ZXJmbG93ID0gKCkgPT4gewogICAgICAgICAgICAgICAgICAgIGNvbnN0IHBsYWluTGVuID0gU3Ry
aW5nKGMucHJldmlldyB8fCBjLmRhdGEgfHwgJycpLmxlbmd0aDsKICAgICAgICAgICAgICAgICAg
ICBjb25zdCBmdWxsTiA9IE51bWJlcihjLmNoYXJDb3VudCkgfHwgMDsKICAgICAgICAgICAgICAg
ICAgICBjb25zdCB0cnVuYyA9IGZ1bGxOID4gcGxhaW5MZW47CiAgICAgICAgICAgICAgICAgICAg
aWYgKHByZXYuc2Nyb2xsSGVpZ2h0ID4gcHJldi5jbGllbnRIZWlnaHQgKyAyIHx8IHRydW5jKQog
ICAgICAgICAgICAgICAgICAgICAgICBleHBCdG4uY2xhc3NMaXN0LmFkZCgnb24nKTsKICAgICAg
ICAgICAgICAgICAgICBlbHNlCiAgICAgICAgICAgICAgICAgICAgICAgIGV4cEJ0bi5jbGFzc0xp
c3QucmVtb3ZlKCdvbicpOwogICAgICAgICAgICAgICAgfTsKICAgICAgICAgICAgICAgIHJlcXVl
c3RBbmltYXRpb25GcmFtZShjaGVja092ZXJmbG93KTsKICAgICAgICAgICAgICAgIHNldFRpbWVv
dXQoY2hlY2tPdmVyZmxvdywgODApOwogICAgICAgICAgICB9CiAgICAgICAgfQoKICAgICAgICBj
b25zdCBmYXZUID0gU3RyaW5nKGMuZmF2VGl0bGUgfHwgJycpLnRyaW0oKTsKICAgICAgICBpZiAo
ZmF2VCkgewogICAgICAgICAgICBjb25zdCBmdCA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2Rp
dicpOwogICAgICAgICAgICBmdC5jbGFzc05hbWUgPSAnaS1mYXYtdGl0bGUnOwogICAgICAgICAg
ICBzZXRIbFRleHQoZnQsIGZhdlQpOwogICAgICAgICAgICBib2R5Lmluc2VydEJlZm9yZShmdCwg
Ym9keS5maXJzdENoaWxkKTsKICAgICAgICB9CgogICAgICAgIGlmIChwYXN0ZWQpIHsKICAgICAg
ICAgICAgZWwuY2xhc3NMaXN0LmFkZCgncGFzdGVkJyk7CiAgICAgICAgICAgIGNvbnN0IGJhZGdl
ID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnc3BhbicpOwogICAgICAgICAgICBiYWRnZS5jbGFz
c05hbWUgPSAnaS11c2VkJzsKICAgICAgICAgICAgYmFkZ2UudGl0bGUgPSAn5bey57KY6LS0JzsK
ICAgICAgICAgICAgYmFkZ2UuaW5uZXJIVE1MID0gYDxzdmcgdmlld0JveD0iMCAwIDE2IDE2IiBm
aWxsPSJub25lIiBzdHJva2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIyLjQiIHN0cm9r
ZS1saW5lY2FwPSJyb3VuZCIgc3Ryb2tlLWxpbmVqb2luPSJyb3VuZCI+PHBvbHlsaW5lIHBvaW50
cz0iMy41IDguNSA2LjUgMTEuNSAxMi41IDQuNSIvPjwvc3ZnPmA7CiAgICAgICAgICAgIGljby5h
cHBlbmRDaGlsZChiYWRnZSk7CiAgICAgICAgfQoKICAgICAgICBjb25zdCBudW0gPSBkb2N1bWVu
dC5jcmVhdGVFbGVtZW50KCdkaXYnKTsKICAgICAgICBudW0uY2xhc3NOYW1lID0gJ2ktbnVtJzsK
ICAgICAgICBjb25zdCBudW1UeHQgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdzcGFuJyk7CiAg
ICAgICAgbnVtVHh0LnRleHRDb250ZW50ID0gaWR4OwogICAgICAgIG51bS5hcHBlbmRDaGlsZChu
dW1UeHQpOwogICAgICAgIGNvbnN0IHNyY0ljbyA9IFN0cmluZyhjLnNyY0ljb24gfHwgJycpOwog
ICAgICAgIGNvbnN0IHNyY0V4ZSA9IFN0cmluZyhjLnNyY0V4ZSB8fCAnJyk7CiAgICAgICAgY29u
c3Qgc3JjVGl0bGUgPSBTdHJpbmcoYy5zcmNUaXRsZSB8fCAnJyk7CiAgICAgICAgaWYgKHNyY0lj
bykgewogICAgICAgICAgICBjb25zdCBpbWcgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdpbWcn
KTsKICAgICAgICAgICAgaW1nLmNsYXNzTmFtZSA9ICdpLXNyYy1pY28nOwogICAgICAgICAgICBp
bWcuc3JjID0gU1RPUkVfQkFTRSArIGVuY29kZVVSSUNvbXBvbmVudChzcmNJY28pOwogICAgICAg
ICAgICBpbWcuYWx0ID0gJyc7CiAgICAgICAgICAgIGNvbnN0IHRpcFR4dCA9IHNyY1RpdGxlIHx8
IHNyY0V4ZSB8fCAn5p2l5rqQJzsKICAgICAgICAgICAgaW1nLnRpdGxlID0gdGlwVHh0OwogICAg
ICAgICAgICBpbWcub25jbGljayA9IGUgPT4geyBlLnByZXZlbnREZWZhdWx0KCk7IGUuc3RvcFBy
b3BhZ2F0aW9uKCk7IHNob3dTcmNUaXAoaW1nLCB0aXBUeHQpOyB9OwogICAgICAgICAgICBudW0u
YXBwZW5kQ2hpbGQoaW1nKTsKICAgICAgICB9CgogICAgICAgIGVsLmFwcGVuZENoaWxkKGljbyk7
CiAgICAgICAgZWwuYXBwZW5kQ2hpbGQoYm9keSk7CiAgICAgICAgZWwuYXBwZW5kQ2hpbGQobnVt
KTsKCiAgICAgICAgZWwub25wb2ludGVyZG93biA9IGUgPT4gewogICAgICAgICAgICBiZWdpblBh
c3RlRnJvbUl0ZW0oZSwgYyk7CiAgICAgICAgfTsKICAgICAgICBlbC5vbmNvbnRleHRtZW51ID0g
ZSA9PiB7CiAgICAgICAgICAgIGUucHJldmVudERlZmF1bHQoKTsKICAgICAgICAgICAgc2VsZWN0
ZWRJZCA9IGMuaWQ7CiAgICAgICAgICAgIHNob3dDdHgoZS5jbGllbnRYLCBlLmNsaWVudFksIGMp
OwogICAgICAgIH07CgogICAgICAgIHJldHVybiBlbDsKICAgIH0KCiAgICBmdW5jdGlvbiBpdGVt
SXNRdWV1ZURvbmUocm93KSB7CiAgICAgICAgaWYgKCFyb3cpIHJldHVybiBmYWxzZTsKICAgICAg
ICBpZiAocm93LmNsYXNzTGlzdC5jb250YWlucygncGFzdGVkJykgfHwgcm93LmNsYXNzTGlzdC5j
b250YWlucygncS1kb25lJykpCiAgICAgICAgICAgIHJldHVybiB0cnVlOwogICAgICAgIGNvbnN0
IGlkID0gK3Jvdy5kYXRhc2V0LmlkOwogICAgICAgIGNvbnN0IGMgPSBhbGxDbGlwcy5maW5kKHgg
PT4gK3guaWQgPT09IGlkKTsKICAgICAgICByZXR1cm4gISEoYyAmJiBpc1Bhc3RlZChjKSk7CiAg
ICB9CgogICAgZnVuY3Rpb24gbWFya1F1ZXVlUmFpbHMoKSB7CiAgICAgICAgaWYgKCFsaXN0RWwp
IHJldHVybjsKICAgICAgICBjb25zdCBub2RlcyA9IFsuLi5saXN0RWwucXVlcnlTZWxlY3RvckFs
bCgnLml0bS5xLW1lbWJlcicpXTsKICAgICAgICBpZiAoIW5vZGVzLmxlbmd0aCkgcmV0dXJuOwog
ICAgICAgIC8vIFJlc2V0IGxpbmsgY2xhc3Nlczsga2VlcCBzdHJ1Y3R1cmFsIGVuZHMKICAgICAg
ICBub2Rlcy5mb3JFYWNoKG4gPT4gbi5jbGFzc0xpc3QucmVtb3ZlKCdxLWZpcnN0JywgJ3EtbGFz
dCcsICdxLW9ubHknLCAncS1kb25lLWxpbmsnLCAncS1wYXN0ZWQtbmV4dCcpKTsKICAgICAgICAv
LyBHcm91cCBjb25zZWN1dGl2ZSBzYW1lIHF1ZXVlR3JvdXAgaW4gRE9NIG9yZGVyCiAgICAgICAg
bGV0IGkgPSAwOwogICAgICAgIHdoaWxlIChpIDwgbm9kZXMubGVuZ3RoKSB7CiAgICAgICAgICAg
IGNvbnN0IGcgPSBub2Rlc1tpXS5kYXRhc2V0LnFnOwogICAgICAgICAgICBsZXQgaiA9IGkgKyAx
OwogICAgICAgICAgICB3aGlsZSAoaiA8IG5vZGVzLmxlbmd0aCAmJiBub2Rlc1tqXS5kYXRhc2V0
LnFnID09PSBnKSBqKys7CiAgICAgICAgICAgIGNvbnN0IHNsaWNlID0gbm9kZXMuc2xpY2UoaSwg
aik7CiAgICAgICAgICAgIGlmIChzbGljZS5sZW5ndGggPT09IDEpIHsKICAgICAgICAgICAgICAg
IHNsaWNlWzBdLmNsYXNzTGlzdC5hZGQoJ3Etb25seScpOwogICAgICAgICAgICB9IGVsc2Ugewog
ICAgICAgICAgICAgICAgc2xpY2VbMF0uY2xhc3NMaXN0LmFkZCgncS1maXJzdCcpOwogICAgICAg
ICAgICAgICAgc2xpY2Vbc2xpY2UubGVuZ3RoIC0gMV0uY2xhc3NMaXN0LmFkZCgncS1sYXN0Jyk7
CiAgICAgICAgICAgIH0KICAgICAgICAgICAgZm9yIChsZXQgayA9IDA7IGsgPCBzbGljZS5sZW5n
dGg7IGsrKykgewogICAgICAgICAgICAgICAgY29uc3QgZG9uZSA9IGl0ZW1Jc1F1ZXVlRG9uZShz
bGljZVtrXSk7CiAgICAgICAgICAgICAgICBzbGljZVtrXS5jbGFzc0xpc3QudG9nZ2xlKCdxLWRv
bmUnLCBkb25lKTsKICAgICAgICAgICAgICAgIGNvbnN0IGRvdCA9IHNsaWNlW2tdLnF1ZXJ5U2Vs
ZWN0b3IoJy5xLWRvdCcpOwogICAgICAgICAgICAgICAgaWYgKGRvdCkgZG90LnRpdGxlID0gZG9u
ZSA/ICfpmJ/liJflt7LnspjotLQnIDogJ+eymOi0tOmYn+WIlyc7CiAgICAgICAgICAgICAgICAv
LyBHcmVlbiByYWlsIGZvciBldmVyeSBpdGVtIGluIGEgMisgZGVxdWV1ZWQgcnVuIChpbmNsLiBm
aXJzdC9sYXN0IHN0dWJzKQogICAgICAgICAgICAgICAgY29uc3QgcHJldkRvbmUgPSBrID4gMCAm
JiBpdGVtSXNRdWV1ZURvbmUoc2xpY2VbayAtIDFdKTsKICAgICAgICAgICAgICAgIGNvbnN0IG5l
eHREb25lID0gayA8IHNsaWNlLmxlbmd0aCAtIDEgJiYgaXRlbUlzUXVldWVEb25lKHNsaWNlW2sg
KyAxXSk7CiAgICAgICAgICAgICAgICBpZiAoZG9uZSAmJiAocHJldkRvbmUgfHwgbmV4dERvbmUp
KQogICAgICAgICAgICAgICAgICAgIHNsaWNlW2tdLmNsYXNzTGlzdC5hZGQoJ3EtZG9uZS1saW5r
Jyk7CiAgICAgICAgICAgIH0KICAgICAgICAgICAgaSA9IGo7CiAgICAgICAgfQogICAgfQoKICAg
IGNvbnN0IHBhdGhUaXBFbCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdwYXRoLXRpcCcpOwog
ICAgbGV0IHBhdGhUaXBUaW1lciA9IDA7CiAgICBsZXQgcGF0aFRpcEhpZGVUaW1lciA9IDA7CiAg
ICBsZXQgcGF0aFRpcFRva2VuID0gMDsKICAgIGxldCBwYXRoVGlwQW5jaG9yQnRuID0gbnVsbDsK
CiAgICBmdW5jdGlvbiBoaWRlUGF0aFRpcCgpIHsKICAgICAgICBjbGVhclRpbWVvdXQocGF0aFRp
cFRpbWVyKTsKICAgICAgICBjbGVhclRpbWVvdXQocGF0aFRpcEhpZGVUaW1lcik7CiAgICAgICAg
cGF0aFRpcFRva2VuKys7CiAgICAgICAgaWYgKHBhdGhUaXBBbmNob3JCdG4pIHsKICAgICAgICAg
ICAgcGF0aFRpcEFuY2hvckJ0bi5jbGFzc0xpc3QucmVtb3ZlKCdvbicpOwogICAgICAgICAgICBw
YXRoVGlwQW5jaG9yQnRuID0gbnVsbDsKICAgICAgICB9CiAgICAgICAgaWYgKHBhdGhUaXBFbCkg
ewogICAgICAgICAgICBwYXRoVGlwRWwuY2xhc3NMaXN0LnJlbW92ZSgnb24nKTsKICAgICAgICAg
ICAgcGF0aFRpcEVsLnNldEF0dHJpYnV0ZSgnYXJpYS1oaWRkZW4nLCAndHJ1ZScpOwogICAgICAg
IH0KICAgIH0KICAgIGZ1bmN0aW9uIHBsYWNlUGF0aFRpcChhbmNob3JFbCkgewogICAgICAgIGlm
ICghcGF0aFRpcEVsIHx8ICFhbmNob3JFbCkgcmV0dXJuOwogICAgICAgIGNvbnN0IHRpcCA9IHBh
dGhUaXBFbDsKICAgICAgICBjb25zdCBhciA9IGFuY2hvckVsLmdldEJvdW5kaW5nQ2xpZW50UmVj
dCgpOwogICAgICAgIGNvbnN0IHBhZCA9IDg7CiAgICAgICAgdGlwLnN0eWxlLmxlZnQgPSAnMHB4
JzsKICAgICAgICB0aXAuc3R5bGUudG9wID0gJzBweCc7CiAgICAgICAgdGlwLmNsYXNzTGlzdC5h
ZGQoJ29uJyk7CiAgICAgICAgY29uc3QgdHcgPSB0aXAub2Zmc2V0V2lkdGg7CiAgICAgICAgY29u
c3QgdGggPSB0aXAub2Zmc2V0SGVpZ2h0OwogICAgICAgIGxldCBsZWZ0ID0gYXIubGVmdDsKICAg
ICAgICBsZXQgdG9wID0gYXIuYm90dG9tICsgNjsKICAgICAgICBpZiAobGVmdCArIHR3ID4gd2lu
ZG93LmlubmVyV2lkdGggLSBwYWQpCiAgICAgICAgICAgIGxlZnQgPSBNYXRoLm1heChwYWQsIHdp
bmRvdy5pbm5lcldpZHRoIC0gdHcgLSBwYWQpOwogICAgICAgIGlmIChsZWZ0IDwgcGFkKSBsZWZ0
ID0gcGFkOwogICAgICAgIGlmICh0b3AgKyB0aCA+IHdpbmRvdy5pbm5lckhlaWdodCAtIHBhZCkK
ICAgICAgICAgICAgdG9wID0gTWF0aC5tYXgocGFkLCBhci50b3AgLSB0aCAtIDYpOwogICAgICAg
IHRpcC5zdHlsZS5sZWZ0ID0gbGVmdCArICdweCc7CiAgICAgICAgdGlwLnN0eWxlLnRvcCA9IHRv
cCArICdweCc7CiAgICB9CiAgICAgICAgZnVuY3Rpb24gY2hlY2tGaWxlUGF0aHMocGF0aHMpIHsK
ICAgICAgICBjb25zdCBsaXN0ID0gKHBhdGhzIHx8IFtdKS5tYXAocCA9PiB7CiAgICAgICAgICAg
IGxldCBwYXRoID0gU3RyaW5nKHAgfHwgJycpLnRyaW0oKTsKICAgICAgICAgICAgaWYgKChwYXRo
LnN0YXJ0c1dpdGgoJyInKSAmJiBwYXRoLmVuZHNXaXRoKCciJykpIHx8IChwYXRoLnN0YXJ0c1dp
dGgoIiciKSAmJiBwYXRoLmVuZHNXaXRoKCInIikpKQogICAgICAgICAgICAgICAgcGF0aCA9IHBh
dGguc2xpY2UoMSwgLTEpLnRyaW0oKTsKICAgICAgICAgICAgcmV0dXJuIHBhdGg7CiAgICAgICAg
fSk7CiAgICAgICAgLy8gT25lIGhvc3Qgcm91bmQtdHJpcCBmb3IgdGhlIHdob2xlIGxpc3Qg4oCU
IE7DlyBwYXRoRXhpc3RzIGZyZWV6ZXMgZmlsZSB0YWIKICAgICAgICB0cnkgewogICAgICAgICAg
ICBjb25zdCByYXcgPSBhaGtSZXQoJ2NoZWNrUGF0aHMnLCBsaXN0LmpvaW4oJ1xuJykpOwogICAg
ICAgICAgICBpZiAocmF3KSB7CiAgICAgICAgICAgICAgICBjb25zdCBwYXJzZWQgPSB0eXBlb2Yg
cmF3ID09PSAnc3RyaW5nJyA/IEpTT04ucGFyc2UocmF3KSA6IHJhdzsKICAgICAgICAgICAgICAg
IGlmIChBcnJheS5pc0FycmF5KHBhcnNlZCkgJiYgcGFyc2VkLmxlbmd0aCkgewogICAgICAgICAg
ICAgICAgICAgIHJldHVybiBsaXN0Lm1hcCgocGF0aCwgaSkgPT4gewogICAgICAgICAgICAgICAg
ICAgICAgICBjb25zdCByb3cgPSBwYXJzZWRbaV0gfHwge307CiAgICAgICAgICAgICAgICAgICAg
ICAgIHJldHVybiB7CiAgICAgICAgICAgICAgICAgICAgICAgICAgICBwYXRoOiBwYXRoIHx8IFN0
cmluZyhyb3cucGF0aCB8fCAnJyksCiAgICAgICAgICAgICAgICAgICAgICAgICAgICBleGlzdHM6
IHJvdy5leGlzdHMgPT09IHRydWUgfHwgcm93LmV4aXN0cyA9PT0gMSB8fCByb3cuZXhpc3RzID09
PSAnMScsCiAgICAgICAgICAgICAgICAgICAgICAgICAgICBpc0RpcjogISEocm93LmlzRGlyID09
PSB0cnVlIHx8IHJvdy5pc0RpciA9PT0gMSB8fCByb3cuaXNEaXIgPT09ICcxJykKICAgICAgICAg
ICAgICAgICAgICAgICAgfTsKICAgICAgICAgICAgICAgICAgICB9KTsKICAgICAgICAgICAgICAg
IH0KICAgICAgICAgICAgfQogICAgICAgIH0gY2F0Y2gge30KICAgICAgICByZXR1cm4gbGlzdC5t
YXAocGF0aCA9PiB7CiAgICAgICAgICAgIGlmICghcGF0aCkgcmV0dXJuIHsgcGF0aCwgZXhpc3Rz
OiBmYWxzZSwgaXNEaXI6IGZhbHNlIH07CiAgICAgICAgICAgIGxldCBleGlzdHMgPSBmYWxzZTsK
ICAgICAgICAgICAgdHJ5IHsKICAgICAgICAgICAgICAgIGNvbnN0IGZsYWcgPSBTdHJpbmcoYWhr
UmV0KCdwYXRoRXhpc3RzJywgcGF0aCkgPz8gJycpLnRyaW0oKS50b0xvd2VyQ2FzZSgpOwogICAg
ICAgICAgICAgICAgZXhpc3RzID0gKGZsYWcgPT09ICcxJyB8fCBmbGFnID09PSAndHJ1ZScpOwog
ICAgICAgICAgICB9IGNhdGNoIHt9CiAgICAgICAgICAgIHJldHVybiB7IHBhdGgsIGV4aXN0cywg
aXNEaXI6IGZhbHNlIH07CiAgICAgICAgfSk7CiAgICB9CiAgICBsZXQgZ29uZUNoZWNrVGltZXIg
PSAwOwogICAgZnVuY3Rpb24gc2NoZWR1bGVGaWxlR29uZUNoZWNrKCkgewogICAgICAgIGlmIChn
b25lQ2hlY2tUaW1lcikgcmV0dXJuOwogICAgICAgIGdvbmVDaGVja1RpbWVyID0gc2V0VGltZW91
dCgoKSA9PiB7CiAgICAgICAgICAgIGdvbmVDaGVja1RpbWVyID0gMDsKICAgICAgICAgICAgY29u
c3Qgbm9kZXMgPSBbLi4ubGlzdEVsLnF1ZXJ5U2VsZWN0b3JBbGwoJy5pdG0nKV0uZmlsdGVyKG4g
PT4gbi5fZmlsZVBhdGhzICYmIG4uX2ZpbGVQYXRocy5sZW5ndGgpOwogICAgICAgICAgICBpZiAo
IW5vZGVzLmxlbmd0aCkgcmV0dXJuOwogICAgICAgICAgICBjb25zdCB1bmlxdWUgPSBbXTsKICAg
ICAgICAgICAgY29uc3Qgc2VlbiA9IG5ldyBTZXQoKTsKICAgICAgICAgICAgbm9kZXMuZm9yRWFj
aChuID0+IHsKICAgICAgICAgICAgICAgIG4uX2ZpbGVQYXRocy5mb3JFYWNoKHAgPT4gewogICAg
ICAgICAgICAgICAgICAgIGNvbnN0IHBhdGggPSBTdHJpbmcocCB8fCAnJyk7CiAgICAgICAgICAg
ICAgICAgICAgaWYgKCFwYXRoIHx8IHNlZW4uaGFzKHBhdGgpKSByZXR1cm47CiAgICAgICAgICAg
ICAgICAgICAgc2Vlbi5hZGQocGF0aCk7CiAgICAgICAgICAgICAgICAgICAgdW5pcXVlLnB1c2go
cGF0aCk7CiAgICAgICAgICAgICAgICB9KTsKICAgICAgICAgICAgfSk7CiAgICAgICAgICAgIGNv
bnN0IHJvd3MgPSBjaGVja0ZpbGVQYXRocyh1bmlxdWUpOwogICAgICAgICAgICBjb25zdCBieVBh
dGggPSBuZXcgTWFwKCk7CiAgICAgICAgICAgIHJvd3MuZm9yRWFjaChyID0+IGJ5UGF0aC5zZXQo
U3RyaW5nKHIucGF0aCB8fCAnJyksIHIpKTsKICAgICAgICAgICAgbm9kZXMuZm9yRWFjaChuID0+
IHsKICAgICAgICAgICAgICAgIGNvbnN0IHBhdGhSb3dzID0gbi5fZmlsZVBhdGhzLm1hcChwID0+
IHsKICAgICAgICAgICAgICAgICAgICBjb25zdCBoaXQgPSBieVBhdGguZ2V0KFN0cmluZyhwIHx8
ICcnKSk7CiAgICAgICAgICAgICAgICAgICAgcmV0dXJuIGhpdCB8fCB7IHBhdGg6IHAsIGV4aXN0
czogdHJ1ZSwgaXNEaXI6IGZhbHNlIH07CiAgICAgICAgICAgICAgICB9KTsKICAgICAgICAgICAg
ICAgIG4uX3BhdGhSb3dzID0gcGF0aFJvd3M7CiAgICAgICAgICAgICAgICBjb25zdCBhbGxHb25l
ID0gcGF0aFJvd3MubGVuZ3RoID4gMCAmJiBwYXRoUm93cy5ldmVyeShyID0+IHIuZXhpc3RzID09
PSBmYWxzZSk7CiAgICAgICAgICAgICAgICBuLmNsYXNzTGlzdC50b2dnbGUoJ2dvbmUnLCBhbGxH
b25lKTsKICAgICAgICAgICAgfSk7CiAgICAgICAgfSwgNDAwKTsKICAgIH0KICAgIGZ1bmN0aW9u
IGZpbGxGaWxlRGV0YWlsUGFuZWwoY29udGFpbmVyLCByb3dzKSB7CiAgICAgICAgY29udGFpbmVy
LmlubmVySFRNTCA9ICcnOwogICAgICAgIGlmICghcm93cy5sZW5ndGgpIHsKICAgICAgICAgICAg
Y29uc3QgZW1wdHkgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsKICAgICAgICAgICAg
ZW1wdHkuY2xhc3NOYW1lID0gJ2ZkLXBhdGgnOwogICAgICAgICAgICBlbXB0eS50ZXh0Q29udGVu
dCA9ICfml6Dot6/lvoQnOwogICAgICAgICAgICBjb250YWluZXIuYXBwZW5kQ2hpbGQoZW1wdHkp
OwogICAgICAgICAgICByZXR1cm47CiAgICAgICAgfQogICAgICAgIHJvd3MuZm9yRWFjaChyID0+
IHsKICAgICAgICAgICAgY29uc3QgcGF0aCA9IFN0cmluZyhyLnBhdGggfHwgJycpOwogICAgICAg
ICAgICBjb25zdCBtaXNzaW5nID0gci5leGlzdHMgPT09IGZhbHNlOwogICAgICAgICAgICBjb25z
dCBibG9jayA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOwogICAgICAgICAgICBibG9j
ay5jbGFzc05hbWUgPSAnZmQtYmxvY2snOwoKICAgICAgICAgICAgY29uc3QgcGF0aEVsID0gZG9j
dW1lbnQuY3JlYXRlRWxlbWVudCgnZGl2Jyk7CiAgICAgICAgICAgIHBhdGhFbC5jbGFzc05hbWUg
PSAnZmQtcGF0aCcgKyAobWlzc2luZyA/ICcgZGVhZCcgOiAnIGxpdmUnKTsKICAgICAgICAgICAg
cGF0aEVsLnRleHRDb250ZW50ID0gcGF0aCB8fCAnKOepuui3r+W+hCknOwogICAgICAgICAgICBp
ZiAoIW1pc3NpbmcpIHsKICAgICAgICAgICAgICAgIHBhdGhFbC5vbmNsaWNrID0gZSA9PiB7CiAg
ICAgICAgICAgICAgICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOwogICAgICAgICAgICAgICAgICAg
IGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAgICAgICAgICAgICAgICAgYWhrKCdvcGVuUGF0aCcs
IHBhdGgpOwogICAgICAgICAgICAgICAgfTsKICAgICAgICAgICAgfQogICAgICAgICAgICBibG9j
ay5hcHBlbmRDaGlsZChwYXRoRWwpOwoKICAgICAgICAgICAgY29uc3QgYWN0aW9ucyA9IGRvY3Vt
ZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOwogICAgICAgICAgICBhY3Rpb25zLmNsYXNzTmFtZSA9
ICdmZC1hY3Rpb25zJzsKCiAgICAgICAgICAgIGNvbnN0IGNvcHlCdG4gPSBkb2N1bWVudC5jcmVh
dGVFbGVtZW50KCdidXR0b24nKTsKICAgICAgICAgICAgY29weUJ0bi50eXBlID0gJ2J1dHRvbic7
CiAgICAgICAgICAgIGNvcHlCdG4uY2xhc3NOYW1lID0gJ2ZkLWJ0bic7CiAgICAgICAgICAgIGNv
cHlCdG4uaW5uZXJIVE1MID0gJzxzcGFuIGNsYXNzPSJmZC1pY28iPvCflJc8L3NwYW4+PHNwYW4g
Y2xhc3M9ImZkLXR4dCI+5aSN5Yi26Lev5b6EPC9zcGFuPic7CiAgICAgICAgICAgIGNvcHlCdG4u
b25jbGljayA9IGUgPT4gewogICAgICAgICAgICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOwogICAg
ICAgICAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICAgICAgICAgIGFoaygnY29w
eVBhdGgnLCBwYXRoKTsKICAgICAgICAgICAgICAgIGNvcHlCdG4ucXVlcnlTZWxlY3RvcignLmZk
LXR4dCcpLnRleHRDb250ZW50ID0gJ+W3suWkjeWItic7CiAgICAgICAgICAgICAgICBjb3B5QnRu
LmNsYXNzTGlzdC5hZGQoJ29rJyk7CiAgICAgICAgICAgICAgICBzZXRUaW1lb3V0KCgpID0+IHsK
ICAgICAgICAgICAgICAgICAgICBjb3B5QnRuLnF1ZXJ5U2VsZWN0b3IoJy5mZC10eHQnKS50ZXh0
Q29udGVudCA9ICflpI3liLbot6/lvoQnOwogICAgICAgICAgICAgICAgICAgIGNvcHlCdG4uY2xh
c3NMaXN0LnJlbW92ZSgnb2snKTsKICAgICAgICAgICAgICAgIH0sIDEyMDApOwogICAgICAgICAg
ICB9OwogICAgICAgICAgICBhY3Rpb25zLmFwcGVuZENoaWxkKGNvcHlCdG4pOwoKICAgICAgICAg
ICAgY29uc3QgZm9sZGVyQnRuID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnYnV0dG9uJyk7CiAg
ICAgICAgICAgIGZvbGRlckJ0bi50eXBlID0gJ2J1dHRvbic7CiAgICAgICAgICAgIGZvbGRlckJ0
bi5jbGFzc05hbWUgPSAnZmQtYnRuJzsKICAgICAgICAgICAgZm9sZGVyQnRuLmlubmVySFRNTCA9
ICc8c3BhbiBjbGFzcz0iZmQtaWNvIj7wn5OCPC9zcGFuPjxzcGFuIGNsYXNzPSJmZC10eHQiPuaJ
k+W8gOaJgOWcqOaWh+S7tuWkuTwvc3Bhbj4nOwogICAgICAgICAgICBmb2xkZXJCdG4ub25jbGlj
ayA9IGUgPT4gewogICAgICAgICAgICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOwogICAgICAgICAg
ICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICAgICAgICAgIGFoaygnb3BlbkZvbGRl
cicsIHBhdGgpOwogICAgICAgICAgICB9OwogICAgICAgICAgICBhY3Rpb25zLmFwcGVuZENoaWxk
KGZvbGRlckJ0bik7CgogICAgICAgICAgICBibG9jay5hcHBlbmRDaGlsZChhY3Rpb25zKTsKICAg
ICAgICAgICAgY29udGFpbmVyLmFwcGVuZENoaWxkKGJsb2NrKTsKICAgICAgICB9KTsKICAgIH0K
CiAgICBjb25zdCBjdHhFbCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjdHgnKTsKICAgIGZ1
bmN0aW9uIHNob3dDdHgoeCwgeSwgYykgewogICAgICAgIGN0eENsaXAgPSBjOwogICAgICAgIHNl
bGVjdGVkSWQgPSBjLmlkOwogICAgICAgIHJhbmdlQW5jaG9ySWQgPSBjLmlkOwogICAgICAgIHJh
bmdlQW5jaG9yQ2xpY2tlZCA9IHRydWU7CiAgICAgICAgY29uc3QgY2xlYXJCdG4gPSBkb2N1bWVu
dC5nZXRFbGVtZW50QnlJZCgnYy1jbGVhci1wYXN0ZWQnKTsKICAgICAgICBpZiAoY2xlYXJCdG4p
IGNsZWFyQnRuLnN0eWxlLmRpc3BsYXkgPSBpc1Bhc3RlZChjKSA/ICcnIDogJ25vbmUnOwogICAg
ICAgIGNvbnN0IHFGcm9tID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2MtcXVldWUtZnJvbScp
OwogICAgICAgIGlmIChxRnJvbSkgcUZyb20uc3R5bGUuZGlzcGxheSA9IChOdW1iZXIoYy5xdWV1
ZUdyb3VwKSA+IDApID8gJycgOiAnbm9uZSc7CgogICAgICAgIGNvbnN0IHBpbkJ0biA9IGRvY3Vt
ZW50LmdldEVsZW1lbnRCeUlkKCdjLXBpbicpOwogICAgICAgIGNvbnN0IGNvcHlCdG4gPSBkb2N1
bWVudC5nZXRFbGVtZW50QnlJZCgnYy1jb3B5Jyk7CiAgICAgICAgY29uc3QgaXNSZWNlbnQgPSBu
b3JtVHlwZShjLnR5cGUpID09PSAncmVjZW50JyB8fCBjdXJUYWIgPT09ICdyZWNlbnQnOwogICAg
ICAgIGlmIChjb3B5QnRuKSB7CiAgICAgICAgICAgIGNvcHlCdG4uaW5uZXJIVE1MID0gaXNSZWNl
bnQKICAgICAgICAgICAgICAgID8gJzxzcGFuIGNsYXNzPSJjLWljbyI+8J+Ulzwvc3Bhbj7lpI3l
iLbot6/lvoQnCiAgICAgICAgICAgICAgICA6ICc8c3BhbiBjbGFzcz0iYy1pY28iPuKOmDwvc3Bh
bj7lpI3liLYnOwogICAgICAgICAgICBjb3B5QnRuLnN0eWxlLmRpc3BsYXkgPSAnJzsKICAgICAg
ICB9CiAgICAgICAgaWYgKHBpbkJ0bikgewogICAgICAgICAgICBpZiAoaXNSZWNlbnQpIHsKICAg
ICAgICAgICAgICAgIC8vIFJlY2VudCBmb2xkZXJzOiBwaW4gPSBrZWVwIHBhdGggKG5vdCBjbGlw
Ym9hcmQg5pS26JePKQogICAgICAgICAgICAgICAgcGluQnRuLnN0eWxlLmRpc3BsYXkgPSAnJzsK
ICAgICAgICAgICAgICAgIGNvbnN0IG9uID0gaXNQaW5uZWQoYyk7CiAgICAgICAgICAgICAgICBw
aW5CdG4uaW5uZXJIVE1MID0gb24KICAgICAgICAgICAgICAgICAgICA/ICc8c3BhbiBjbGFzcz0i
Yy1pY28iPuKYhTwvc3Bhbj7lj5bmtojlm7rlrponCiAgICAgICAgICAgICAgICAgICAgOiAnPHNw
YW4gY2xhc3M9ImMtaWNvIj7imIU8L3NwYW4+5Zu65a6a6Lev5b6EJzsKICAgICAgICAgICAgfSBl
bHNlIHsKICAgICAgICAgICAgICAgIHBpbkJ0bi5zdHlsZS5kaXNwbGF5ID0gJyc7CiAgICAgICAg
ICAgICAgICBjb25zdCBvbiA9IGlzUGlubmVkKGMpOwogICAgICAgICAgICAgICAgcGluQnRuLmlu
bmVySFRNTCA9IG9uCiAgICAgICAgICAgICAgICAgICAgPyAnPHNwYW4gY2xhc3M9ImMtaWNvIj7i
mIU8L3NwYW4+5Y+W5raI5pS26JePJwogICAgICAgICAgICAgICAgICAgIDogJzxzcGFuIGNsYXNz
PSJjLWljbyI+4piFPC9zcGFuPuaUtuiXjyc7CiAgICAgICAgICAgIH0KICAgICAgICB9CiAgICAg
ICAgY29uc3QgdGl0bGVCdG4gPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYy10aXRsZScpOwog
ICAgICAgIGlmICh0aXRsZUJ0bikgewogICAgICAgICAgICAvLyBObyBmYXYtdGl0bGUgZm9yIHJl
Y2VudCBwYXRocwogICAgICAgICAgICBjb25zdCBzaG93VGl0bGUgPSAhaXNSZWNlbnQgJiYgKGlz
UGlubmVkKGMpIHx8IGN1clRhYiA9PT0gJ3Bpbm5lZCcpOwogICAgICAgICAgICB0aXRsZUJ0bi5z
dHlsZS5kaXNwbGF5ID0gc2hvd1RpdGxlID8gJycgOiAnbm9uZSc7CiAgICAgICAgICAgIGlmIChz
aG93VGl0bGUpCiAgICAgICAgICAgICAgICB0aXRsZUJ0bi5pbm5lckhUTUwgPSAoU3RyaW5nKGMu
ZmF2VGl0bGUgfHwgJycpLnRyaW0oKSA/ICc8c3BhbiBjbGFzcz0iYy1pY28iPuKcjjwvc3Bhbj7n
vJbovpHmoIfpopgnIDogJzxzcGFuIGNsYXNzPSJjLWljbyI+4pyOPC9zcGFuPuiuvue9ruagh+mi
mCcpOwogICAgICAgIH0KICAgICAgICBjb25zdCBtZXJnZUJ0biA9IGRvY3VtZW50LmdldEVsZW1l
bnRCeUlkKCdjLW1lcmdlJyk7CiAgICAgICAgY29uc3QgdW5tZXJnZUJ0biA9IGRvY3VtZW50Lmdl
dEVsZW1lbnRCeUlkKCdjLXVubWVyZ2UnKTsKICAgICAgICBjb25zdCBvblBpbm5lZCA9IGN1clRh
YiA9PT0gJ3Bpbm5lZCc7CiAgICAgICAgaWYgKG1lcmdlQnRuKQogICAgICAgICAgICBtZXJnZUJ0
bi5zdHlsZS5kaXNwbGF5ID0gKCFpc1JlY2VudCAmJiBvblBpbm5lZCAmJiBtdWx0aUlkcy5sZW5n
dGggPj0gMikgPyAnJyA6ICdub25lJzsKICAgICAgICBpZiAodW5tZXJnZUJ0bikKICAgICAgICAg
ICAgdW5tZXJnZUJ0bi5zdHlsZS5kaXNwbGF5ID0gKCFpc1JlY2VudCAmJiBvblBpbm5lZCAmJiBm
YXZHcm91cE9mKGMpKSA/ICcnIDogJ25vbmUnOwogICAgICAgIGNvbnN0IHRvcEJ0biA9IGRvY3Vt
ZW50LmdldEVsZW1lbnRCeUlkKCdjLXRvcCcpOwogICAgICAgIGlmICh0b3BCdG4pCiAgICAgICAg
ICAgIHRvcEJ0bi5zdHlsZS5kaXNwbGF5ID0gaXNSZWNlbnQgPyAnbm9uZScgOiAnJzsKICAgICAg
ICBjb25zdCBjbGVhckJ0bjIgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYy1jbGVhci1wYXN0
ZWQnKTsKICAgICAgICBpZiAoY2xlYXJCdG4yICYmIGlzUmVjZW50KQogICAgICAgICAgICBjbGVh
ckJ0bjIuc3R5bGUuZGlzcGxheSA9ICdub25lJzsKICAgICAgICBjb25zdCBxRnJvbTIgPSBkb2N1
bWVudC5nZXRFbGVtZW50QnlJZCgnYy1xdWV1ZS1mcm9tJyk7CiAgICAgICAgaWYgKHFGcm9tMiAm
JiBpc1JlY2VudCkKICAgICAgICAgICAgcUZyb20yLnN0eWxlLmRpc3BsYXkgPSAnbm9uZSc7CiAg
ICAgICAgY29uc3QgZGVsQnRuID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2MtZGVsJyk7CiAg
ICAgICAgaWYgKGRlbEJ0bikgewogICAgICAgICAgICBjb25zdCBtdWx0aURlbCA9IG11bHRpSWRz
Lmxlbmd0aCA+IDEgJiYgbXVsdGlJZHMuaW5jbHVkZXMoK2MuaWQpOwogICAgICAgICAgICBjb25z
dCBuID0gbXVsdGlEZWwgPyBtdWx0aUlkcy5sZW5ndGggOiAxOwogICAgICAgICAgICBkZWxCdG4u
aW5uZXJIVE1MID0gbiA+IDEKICAgICAgICAgICAgICAgID8gKCc8c3BhbiBjbGFzcz0iYy1pY28i
PuKclTwvc3Bhbj7liKDpmaQgKCcgKyBuICsgJyknKQogICAgICAgICAgICAgICAgOiAnPHNwYW4g
Y2xhc3M9ImMtaWNvIj7inJU8L3NwYW4+5Yig6ZmkJzsKICAgICAgICB9CiAgICAgICAgY29uc3Qg
ZGF0YVdyYXAgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYy1kYXRhLXdyYXAnKTsKICAgICAg
ICBjb25zdCBkYXRhU2VwID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2MtZGF0YS1zZXAnKTsK
ICAgICAgICBjb25zdCBzaG93RGF0YSA9ICFpc1JlY2VudCAmJiAobm9ybVR5cGUoYy50eXBlKSA9
PT0gJ3RleHQnIHx8IG5vcm1UeXBlKGMudHlwZSkgPT09ICdsaW5rJyk7CiAgICAgICAgaWYgKGRh
dGFXcmFwKSBkYXRhV3JhcC5zdHlsZS5kaXNwbGF5ID0gc2hvd0RhdGEgPyAnJyA6ICdub25lJzsK
ICAgICAgICBpZiAoZGF0YVNlcCkgZGF0YVNlcC5zdHlsZS5kaXNwbGF5ID0gc2hvd0RhdGEgPyAn
JyA6ICdub25lJzsKICAgICAgICBpZiAoZGF0YVdyYXApIGRhdGFXcmFwLmNsYXNzTGlzdC5yZW1v
dmUoJ29wZW4nKTsKICAgICAgICBjdHhFbC5jbGFzc0xpc3QuYWRkKCdvbicpOwogICAgICAgIGN0
eEVsLnN0eWxlLmxlZnQgPSB4ICsgJ3B4JzsKICAgICAgICBjdHhFbC5zdHlsZS50b3AgID0geSAr
ICdweCc7CiAgICAgICAgcmVxdWVzdEFuaW1hdGlvbkZyYW1lKCgpID0+IHsKICAgICAgICAgICAg
Y29uc3QgciA9IGN0eEVsLmdldEJvdW5kaW5nQ2xpZW50UmVjdCgpOwogICAgICAgICAgICBpZiAo
ci5yaWdodCAgPiBpbm5lcldpZHRoKSAgY3R4RWwuc3R5bGUubGVmdCA9ICh4IC0gci53aWR0aCkg
ICsgJ3B4JzsKICAgICAgICAgICAgaWYgKHIuYm90dG9tID4gaW5uZXJIZWlnaHQpIGN0eEVsLnN0
eWxlLnRvcCAgPSAoeSAtIHIuaGVpZ2h0KSArICdweCc7CiAgICAgICAgICAgIHBsYWNlRGF0YVN1
Ym1lbnUoKTsKICAgICAgICB9KTsKICAgIH0KICAgIGZ1bmN0aW9uIHBsYWNlRGF0YVN1Ym1lbnUo
KSB7CiAgICAgICAgY29uc3Qgd3JhcCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjLWRhdGEt
d3JhcCcpOwogICAgICAgIGNvbnN0IHN1YiA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjLWRh
dGEtc3ViJyk7CiAgICAgICAgaWYgKCF3cmFwIHx8ICFzdWIgfHwgd3JhcC5zdHlsZS5kaXNwbGF5
ID09PSAnbm9uZScpIHJldHVybjsKICAgICAgICBjb25zdCBwYWQgPSA0OwogICAgICAgIC8vIE1l
YXN1cmUgd2hpbGUgdGVtcG9yYXJpbHkgdmlzaWJsZSAoc3VibWVudSBtYXkgc3RpbGwgYmUgZGlz
cGxheTpub25lKQogICAgICAgIGNvbnN0IHByZXZEaXNwbGF5ID0gc3ViLnN0eWxlLmRpc3BsYXk7
CiAgICAgICAgY29uc3QgcHJldlZpc2liaWxpdHkgPSBzdWIuc3R5bGUudmlzaWJpbGl0eTsKICAg
ICAgICBjb25zdCBwcmV2TGVmdCA9IHN1Yi5zdHlsZS5sZWZ0OwogICAgICAgIGNvbnN0IHByZXZS
aWdodCA9IHN1Yi5zdHlsZS5yaWdodDsKICAgICAgICBzdWIuY2xhc3NMaXN0LnJlbW92ZSgnbGVm
dCcpOwogICAgICAgIHN1Yi5zdHlsZS5sZWZ0ID0gJ2NhbGMoMTAwJSAtIDJweCknOwogICAgICAg
IHN1Yi5zdHlsZS5yaWdodCA9ICdhdXRvJzsKICAgICAgICBzdWIuc3R5bGUudmlzaWJpbGl0eSA9
ICdoaWRkZW4nOwogICAgICAgIHN1Yi5zdHlsZS5kaXNwbGF5ID0gJ2Jsb2NrJzsKICAgICAgICBj
b25zdCBzdWJXID0gTWF0aC5jZWlsKHN1Yi5nZXRCb3VuZGluZ0NsaWVudFJlY3QoKS53aWR0aCB8
fCBzdWIub2Zmc2V0V2lkdGggfHwgMCk7CiAgICAgICAgY29uc3Qgd3JhcFJlY3QgPSB3cmFwLmdl
dEJvdW5kaW5nQ2xpZW50UmVjdCgpOwogICAgICAgIHN1Yi5zdHlsZS5kaXNwbGF5ID0gcHJldkRp
c3BsYXk7CiAgICAgICAgc3ViLnN0eWxlLnZpc2liaWxpdHkgPSBwcmV2VmlzaWJpbGl0eTsKICAg
ICAgICBzdWIuc3R5bGUubGVmdCA9IHByZXZMZWZ0OwogICAgICAgIHN1Yi5zdHlsZS5yaWdodCA9
IHByZXZSaWdodDsKCiAgICAgICAgaWYgKHN1YlcgPD0gMCkgcmV0dXJuOwogICAgICAgIGNvbnN0
IHNwYWNlUmlnaHQgPSB3aW5kb3cuaW5uZXJXaWR0aCAtIHdyYXBSZWN0LnJpZ2h0IC0gcGFkOwog
ICAgICAgIGNvbnN0IHNwYWNlTGVmdCA9IHdyYXBSZWN0LmxlZnQgLSBwYWQ7CiAgICAgICAgY29u
c3QgZml0c1JpZ2h0ID0gc3BhY2VSaWdodCA+PSBzdWJXOwogICAgICAgIGNvbnN0IGZpdHNMZWZ0
ID0gc3BhY2VMZWZ0ID49IHN1Ylc7CiAgICAgICAgbGV0IG9wZW5MZWZ0ID0gZmFsc2U7CiAgICAg
ICAgaWYgKGZpdHNSaWdodCkgb3BlbkxlZnQgPSBmYWxzZTsKICAgICAgICBlbHNlIGlmIChmaXRz
TGVmdCkgb3BlbkxlZnQgPSB0cnVlOwogICAgICAgIGVsc2Ugb3BlbkxlZnQgPSBzcGFjZUxlZnQg
PiBzcGFjZVJpZ2h0OyAvLyBuZWl0aGVyIGZpdHMg4oCUIHBpY2sgdGhlIGxhcmdlciBnYXAKCiAg
ICAgICAgaWYgKG9wZW5MZWZ0KSB7CiAgICAgICAgICAgIHN1Yi5jbGFzc0xpc3QuYWRkKCdsZWZ0
Jyk7CiAgICAgICAgICAgIHN1Yi5zdHlsZS5sZWZ0ID0gJ2F1dG8nOwogICAgICAgICAgICBzdWIu
c3R5bGUucmlnaHQgPSAnY2FsYygxMDAlIC0gMnB4KSc7CiAgICAgICAgfSBlbHNlIHsKICAgICAg
ICAgICAgc3ViLmNsYXNzTGlzdC5yZW1vdmUoJ2xlZnQnKTsKICAgICAgICAgICAgc3ViLnN0eWxl
LmxlZnQgPSAnY2FsYygxMDAlIC0gMnB4KSc7CiAgICAgICAgICAgIHN1Yi5zdHlsZS5yaWdodCA9
ICdhdXRvJzsKICAgICAgICB9CiAgICB9CiAgICBmdW5jdGlvbiBoaWRlQ3R4KCkgewogICAgICAg
IGN0eEVsLmNsYXNzTGlzdC5yZW1vdmUoJ29uJyk7CiAgICAgICAgY3R4Q2xpcCA9IG51bGw7CiAg
ICAgICAgdHJ5IHsKICAgICAgICAgICAgY29uc3Qgd3JhcCA9IGRvY3VtZW50LmdldEVsZW1lbnRC
eUlkKCdjLWRhdGEtd3JhcCcpOwogICAgICAgICAgICBpZiAod3JhcCkgd3JhcC5jbGFzc0xpc3Qu
cmVtb3ZlKCdvcGVuJyk7CiAgICAgICAgICAgIGNsZWFyRGF0YVN1Ym1lbnVQaWNrKCk7CiAgICAg
ICAgICAgIHByZXZpZXdEYXRhVHJhbnNmb3JtU2VxKys7CiAgICAgICAgfSBjYXRjaCB7fQogICAg
fQogICAgd2luZG93Ll9faGlkZUN0eCA9IGhpZGVDdHg7CgogICAgZnVuY3Rpb24gZGlzbWlzc0N0
eFVubGVzc0luc2lkZShlKSB7CiAgICAgICAgaWYgKCFjdHhFbC5jbGFzc0xpc3QuY29udGFpbnMo
J29uJykpIHJldHVybjsKICAgICAgICBpZiAoZS50YXJnZXQuY2xvc2VzdCgnI2N0eCcpKSByZXR1
cm47CiAgICAgICAgaGlkZUN0eCgpOwogICAgfQogICAgZG9jdW1lbnQuYWRkRXZlbnRMaXN0ZW5l
cignbW91c2Vkb3duJywgZGlzbWlzc0N0eFVubGVzc0luc2lkZSwgdHJ1ZSk7CiAgICBkb2N1bWVu
dC5hZGRFdmVudExpc3RlbmVyKCdjbGljaycsIGRpc21pc3NDdHhVbmxlc3NJbnNpZGUsIHRydWUp
OwogICAgbGlzdEVsLmFkZEV2ZW50TGlzdGVuZXIoJ3Njcm9sbCcsIGhpZGVDdHgsIHsgcGFzc2l2
ZTogdHJ1ZSB9KTsKICAgIGRvY3VtZW50LmFkZEV2ZW50TGlzdGVuZXIoJ2tleWRvd24nLCBlID0+
IHsKICAgICAgICAvLyBFc2M6IGFsd2F5cyBjbG9zZSBwYW5lbCAoc2VhcmNoIG9yIG5vdCk7IHBp
biBrZWVwcyBwYW5lbAogICAgICAgIGlmIChlLmtleSA9PT0gJ0VzY2FwZScpIHsKICAgICAgICAg
ICAgZS5wcmV2ZW50RGVmYXVsdCgpOwogICAgICAgICAgICBoaWRlQ3R4KCk7CiAgICAgICAgICAg
IGNvbnN0IHRkID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3RpdGxlLWRsZycpOwogICAgICAg
ICAgICBpZiAodGQgJiYgdGQuY2xhc3NMaXN0LmNvbnRhaW5zKCdvbicpKSB7CiAgICAgICAgICAg
ICAgICB0cnkgeyBjbG9zZVRpdGxlRGxnKCk7IH0gY2F0Y2ggeyB0ZC5jbGFzc0xpc3QucmVtb3Zl
KCdvbicpOyB9CiAgICAgICAgICAgICAgICByZXR1cm47CiAgICAgICAgICAgIH0KICAgICAgICAg
ICAgaWYgKGNsckRsZy5jbGFzc0xpc3QuY29udGFpbnMoJ29uJykpIHsKICAgICAgICAgICAgICAg
IGNsb3NlQ2xlYXJEbGcoKTsKICAgICAgICAgICAgICAgIHJldHVybjsKICAgICAgICAgICAgfQog
ICAgICAgICAgICBpZiAoIXBpbm5lZFVJKSBhaGsoJ2hpZGUnKTsKICAgICAgICAgICAgcmV0dXJu
OwogICAgICAgIH0KICAgICAgICAvLyBXaGlsZSB0eXBpbmcgaW4gc2VhcmNoOiBDdHJsK0kvSyBh
bmQgYXJyb3dzIG1vdmUgbGlzdCwgZG9uJ3QgbGVhdmUgdGhlIGJveAogICAgICAgIGlmIChkb2N1
bWVudC5hY3RpdmVFbGVtZW50Py5pZCA9PT0gJ3NlYXJjaCcpIHsKICAgICAgICAgICAgaWYgKChl
LmN0cmxLZXkgfHwgZS5tZXRhS2V5KSAmJiAoZS5rZXkgPT09ICdpJyB8fCBlLmtleSA9PT0gJ0kn
KSkgewogICAgICAgICAgICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOyBlLnN0b3BQcm9wYWdhdGlv
bigpOwogICAgICAgICAgICAgICAgd2luZG93Ll9fbmF2ICYmIHdpbmRvdy5fX25hdigndXAnKTsK
ICAgICAgICAgICAgICAgIHJldHVybjsKICAgICAgICAgICAgfQogICAgICAgICAgICBpZiAoKGUu
Y3RybEtleSB8fCBlLm1ldGFLZXkpICYmIChlLmtleSA9PT0gJ2snIHx8IGUua2V5ID09PSAnSycp
KSB7CiAgICAgICAgICAgICAgICBlLnByZXZlbnREZWZhdWx0KCk7IGUuc3RvcFByb3BhZ2F0aW9u
KCk7CiAgICAgICAgICAgICAgICB3aW5kb3cuX19uYXYgJiYgd2luZG93Ll9fbmF2KCdkb3duJyk7
CiAgICAgICAgICAgICAgICByZXR1cm47CiAgICAgICAgICAgIH0KICAgICAgICAgICAgaWYgKGUu
a2V5ID09PSAnQXJyb3dEb3duJykgewogICAgICAgICAgICAgICAgZS5wcmV2ZW50RGVmYXVsdCgp
OyBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgICAgICAgICAgICAgd2luZG93Ll9fbmF2ICYmIHdp
bmRvdy5fX25hdignZG93bicpOwogICAgICAgICAgICAgICAgcmV0dXJuOwogICAgICAgICAgICB9
CiAgICAgICAgICAgIGlmIChlLmtleSA9PT0gJ0Fycm93VXAnKSB7CiAgICAgICAgICAgICAgICBl
LnByZXZlbnREZWZhdWx0KCk7IGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAgICAgICAgICAgICB3
aW5kb3cuX19uYXYgJiYgd2luZG93Ll9fbmF2KCd1cCcpOwogICAgICAgICAgICAgICAgcmV0dXJu
OwogICAgICAgICAgICB9CiAgICAgICAgICAgIHJldHVybjsKICAgICAgICB9CiAgICAgICAgY29u
c3QgdmlzID0gKHR5cGVvZiBuYXZMaXN0ID09PSAnZnVuY3Rpb24nID8gbmF2TGlzdCgpIDogdmlz
aWJsZUxpc3QoKSk7CiAgICAgICAgaWYgKCF2aXMubGVuZ3RoKSByZXR1cm47CiAgICAgICAgbGV0
IGlkeCA9IHNlbGVjdGVkSW5kZXgoKTsKICAgICAgICBpZiAoaWR4IDwgMCkgaWR4ID0gMDsKICAg
ICAgICBpZiAgICAgIChlLmtleSA9PT0gJ0Fycm93RG93bicpIHsgZS5wcmV2ZW50RGVmYXVsdCgp
OyBlLnN0b3BQcm9wYWdhdGlvbigpOyBzZWxlY3RCeUluZGV4KGlkeCArIDEpOyB9CiAgICAgICAg
ZWxzZSBpZiAoZS5rZXkgPT09ICdBcnJvd1VwJykgICB7IGUucHJldmVudERlZmF1bHQoKTsgZS5z
dG9wUHJvcGFnYXRpb24oKTsgc2VsZWN0QnlJbmRleChpZHggLSAxKTsgfQogICAgICAgIGVsc2Ug
aWYgKGUua2V5ID09PSAnRW50ZXInKSB7CiAgICAgICAgICAgIGUucHJldmVudERlZmF1bHQoKTsK
ICAgICAgICAgICAgLy8g5Zu65a6a5pe25Zue6L2m5LiN57KY6LS077yM5Y+q54K55p2h55uu57KY
6LS0CiAgICAgICAgICAgIGlmIChwaW5uZWRVSSkgcmV0dXJuOwogICAgICAgICAgICBpZiAobXVs
dGlJZHMubGVuZ3RoID49IDEpIHsKICAgICAgICAgICAgICAgIGNvbnN0IGlkcyA9IG11bHRpSWRz
LnNsaWNlKCk7CiAgICAgICAgICAgICAgICBjbGVhck11bHRpKCk7CiAgICAgICAgICAgICAgICBt
YXJrUGFzdGVkTG9jYWwoaWRzKTsKICAgICAgICAgICAgICAgIHBhc3RlTWFueVdpdGhTZXAoaWRz
KTsKICAgICAgICAgICAgICAgIHJldHVybjsKICAgICAgICAgICAgfQogICAgICAgICAgICBjb25z
dCBjID0gdmlzW3NlbGVjdGVkSW5kZXgoKV07CiAgICAgICAgICAgIGlmIChjKSB7CiAgICAgICAg
ICAgICAgICBtYXJrUGFzdGVkTG9jYWwoYy5pZCk7CiAgICAgICAgICAgICAgICBhaGsoJ3Bhc3Rl
JywgU3RyaW5nKGMuaWQpKTsKICAgICAgICAgICAgfQogICAgICAgIH0gZWxzZSBpZiAoL15bMS05
XSQvLnRlc3QoZS5rZXkpKSB7CiAgICAgICAgICAgIGNvbnN0IGMgPSB2aXNbK2Uua2V5IC0gMV07
CiAgICAgICAgICAgIGlmIChjKSB7CiAgICAgICAgICAgICAgICBtYXJrUGFzdGVkTG9jYWwoYy5p
ZCk7CiAgICAgICAgICAgICAgICBhaGsoJ3Bhc3RlJywgU3RyaW5nKGMuaWQpKTsKICAgICAgICAg
ICAgfQogICAgICAgIH0KICAgIH0pOwoKICAgIHdpbmRvdy5fX25hdiA9IGRpciA9PiB7CiAgICAg
ICAgY29uc3QgdmlzID0gKHR5cGVvZiBuYXZMaXN0ID09PSAnZnVuY3Rpb24nID8gbmF2TGlzdCgp
IDogdmlzaWJsZUxpc3QoKSk7CiAgICAgICAgaWYgKCF2aXMubGVuZ3RoICYmIGRpciAhPT0gJ3Rh
YicgJiYgZGlyICE9PSAndGFiUHJldicpIHJldHVybjsKICAgICAgICBsZXQgaWR4ID0gc2VsZWN0
ZWRJbmRleCgpOwogICAgICAgIGlmIChpZHggPCAwKSBpZHggPSAwOwogICAgICAgIGlmIChkaXIg
PT09ICd1cCcpIHNlbGVjdEJ5SW5kZXgoaWR4IC0gMSk7CiAgICAgICAgZWxzZSBpZiAoZGlyID09
PSAnZG93bicpIHNlbGVjdEJ5SW5kZXgoaWR4ICsgMSk7CiAgICAgICAgZWxzZSBpZiAoZGlyID09
PSAnZW50ZXInKSB7CiAgICAgICAgICAgIGlmIChwaW5uZWRVSSkgcmV0dXJuOwogICAgICAgICAg
ICBfX3ByZXBQYXN0ZSgpOwogICAgICAgICAgICBpZiAobXVsdGlJZHMubGVuZ3RoID49IDEpIHsK
ICAgICAgICAgICAgICAgIGNvbnN0IGlkcyA9IG11bHRpSWRzLnNsaWNlKCk7CiAgICAgICAgICAg
ICAgICBjbGVhck11bHRpKCk7CiAgICAgICAgICAgICAgICBtYXJrUGFzdGVkTG9jYWwoaWRzKTsK
ICAgICAgICAgICAgICAgIHBhc3RlTWFueVdpdGhTZXAoaWRzKTsKICAgICAgICAgICAgICAgIHJl
dHVybjsKICAgICAgICAgICAgfQogICAgICAgICAgICBjb25zdCBjID0gdmlzW3NlbGVjdGVkSW5k
ZXgoKV07CiAgICAgICAgICAgIGlmIChjKSB7CiAgICAgICAgICAgICAgICBtYXJrUGFzdGVkTG9j
YWwoYy5pZCk7CiAgICAgICAgICAgICAgICBhaGsoJ3Bhc3RlJywgU3RyaW5nKGMuaWQpKTsKICAg
ICAgICAgICAgfQogICAgICAgIH0KICAgIH07CgogICAgLy8gQUhLIEVudGVyIGhvdGtleSBsYW5k
cyBoZXJlIChXZWJWaWV3IG1heSBub3QgcmVjZWl2ZSB0aGUga2V5IHdoaWxlIHVucGlubmVkKQog
ICAgd2luZG93Ll9fZWRpdFRpdGxlID0gKCkgPT4gewogICAgICAgIGxldCBjID0gbnVsbDsKICAg
ICAgICBpZiAoc2VsZWN0ZWRJZCkKICAgICAgICAgICAgYyA9IGFsbENsaXBzLmZpbmQoeCA9PiAr
eC5pZCA9PT0gK3NlbGVjdGVkSWQpIHx8IG51bGw7CiAgICAgICAgaWYgKCFjICYmIGN0eENsaXAp
CiAgICAgICAgICAgIGMgPSBjdHhDbGlwOwogICAgICAgIGlmICghYykgewogICAgICAgICAgICBj
b25zdCB2aXMgPSB2aXNpYmxlTGlzdCgpOwogICAgICAgICAgICBpZiAodmlzLmxlbmd0aCkgYyA9
IHZpc1swXTsKICAgICAgICB9CiAgICAgICAgaWYgKCFjKSByZXR1cm47CiAgICAgICAgb3BlblRp
dGxlRGxnKGMpOwogICAgfTsKCiAgICB3aW5kb3cuX19vbkVudGVyID0gKCkgPT4gewogICAgICAg
IGNvbnN0IHRkID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3RpdGxlLWRsZycpOwogICAgICAg
IGlmICh0ZCAmJiB0ZC5jbGFzc0xpc3QuY29udGFpbnMoJ29uJykpIHsKICAgICAgICAgICAgZG9j
dW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3RpdGxlLW9rJyk/LmNsaWNrKCk7CiAgICAgICAgICAgIHJl
dHVybjsKICAgICAgICB9CiAgICAgICAgaWYgKGRvY3VtZW50LmFjdGl2ZUVsZW1lbnQ/LmlkID09
PSAndGl0bGUtaW5wdXQnKSB7CiAgICAgICAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd0
aXRsZS1vaycpPy5jbGljaygpOwogICAgICAgICAgICByZXR1cm47CiAgICAgICAgfQogICAgICAg
IC8vIOiHquWumuS5ieWIhumalOespu+8muacquWbuuWumuaXtiBBSEsg5Lya5oqiIEVudGVyCiAg
ICAgICAgY29uc3Qgc2VwTWVudSA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdwYXN0ZS1zZXAt
bWVudScpOwogICAgICAgIGNvbnN0IHNlcElucCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdw
YXN0ZS1zZXAtY3VzdG9tJyk7CiAgICAgICAgaWYgKHNlcE1lbnUgJiYgc2VwTWVudS5jbGFzc0xp
c3QuY29udGFpbnMoJ29uJykgJiYgc2VwSW5wKSB7CiAgICAgICAgICAgIGlmIChTdHJpbmcoc2Vw
SW5wLnZhbHVlIHx8ICcnKSAhPT0gJycpIGFwcGx5U2VwYXJhdG9yKHNlcElucC52YWx1ZSk7CiAg
ICAgICAgICAgIGVsc2UgY2xvc2VTZXBNZW51KCk7CiAgICAgICAgICAgIHJldHVybjsKICAgICAg
ICB9CiAgICAgICAgLy8g5Zu65a6a5pe25Zue6L2m5LiN57KY6LS0CiAgICAgICAgaWYgKHBpbm5l
ZFVJKSByZXR1cm47CiAgICAgICAgLy8gVHlwaW5nIGluIHNlYXJjaDogRW50ZXIgc2hvdWxkIHBh
c3RlIHNlbGVjdGVkIGl0ZW0KICAgICAgICBpZiAoZG9jdW1lbnQuYWN0aXZlRWxlbWVudD8uaWQg
PT09ICdzZWFyY2gnKSB7CiAgICAgICAgICAgIHdpbmRvdy5fX25hdiAmJiB3aW5kb3cuX19uYXYo
J2VudGVyJyk7CiAgICAgICAgICAgIHJldHVybjsKICAgICAgICB9CiAgICAgICAgd2luZG93Ll9f
bmF2ICYmIHdpbmRvdy5fX25hdignZW50ZXInKTsKICAgIH07CgogICAgd2luZG93Ll9fY3ljbGVU
YWIgPSBkaXIgPT4gewogICAgICAgIGNvbnN0IGkgPSBNYXRoLm1heCgwLCBUQUJfT1JERVIuaW5k
ZXhPZihjdXJUYWIpKTsKICAgICAgICBjb25zdCBuZXh0ID0gVEFCX09SREVSWyhpICsgKGRpciB8
IDApICsgVEFCX09SREVSLmxlbmd0aCAqIDEwKSAlIFRBQl9PUkRFUi5sZW5ndGhdOwogICAgICAg
IHNldFRhYihuZXh0KTsKICAgIH07CiAgICB3aW5kb3cuX19vblBhbmVsU2hvdyA9IChrZWVwU2Vh
cmNoKSA9PiB7CiAgICAgICAgd2luZG93Ll9fcGVyZk1hcmsgJiYgd2luZG93Ll9fcGVyZk1hcmso
J2pzX29uUGFuZWxTaG93IGtlZXBTZWFyY2g9JyArICghIWtlZXBTZWFyY2gpKTsKICAgICAgICB0
cnkgeyByZXNldFBhc3RlU2VwRGVmYXVsdCgpOyB9IGNhdGNoIHt9CiAgICAgICAgLy8gRG8gTk9U
IGZvY3VzIFdlYlZpZXcg4oCUIGtlZXAgZWRpdG9yIGNhcmV0L2ZvY3VzIChBSEsgaGFuZGxlcyBr
ZXlzIHZpYSAjSG90SWYpCiAgICAgICAgLy8gV2luK1Y6IGNvbGxhcHNlIHNlYXJjaC4gPz8gc2Vh
cmNoOiBrZWVwL29wZW4gc2VhcmNoIGJveC4KICAgICAgICBrZWVwU2VhcmNoID0gISFrZWVwU2Vh
cmNoOwogICAgICAgIHRyeSB7IGhpZGVDdHgoKTsgfSBjYXRjaCB7fQogICAgICAgIHRyeSB7IGNs
b3NlVGl0bGVEbGcoKTsgfSBjYXRjaCB7fQogICAgICAgIHRyeSB7CiAgICAgICAgICAgIGNvbnN0
IHdyYXAgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc2VhcmNoLXdyYXAnKTsKICAgICAgICAg
ICAgY29uc3Qgc3JjaCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzZWFyY2gnKTsKICAgICAg
ICAgICAgY29uc3Qgc2NsciA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzZWFyY2gtY2xyJyk7
CiAgICAgICAgICAgIGlmICgha2VlcFNlYXJjaCkgewogICAgICAgICAgICAgICAgaWYgKHdyYXAp
IHdyYXAuY2xhc3NMaXN0LnJlbW92ZSgnb3BlbicpOwogICAgICAgICAgICAgICAgaWYgKHNyY2gp
IHsKICAgICAgICAgICAgICAgICAgICBzcmNoLnZhbHVlID0gJyc7CiAgICAgICAgICAgICAgICAg
ICAgc3JjaC5jbGFzc0xpc3QucmVtb3ZlKCdoYXMtdmFsJyk7CiAgICAgICAgICAgICAgICAgICAg
dHJ5IHsgc3JjaC5ibHVyKCk7IH0gY2F0Y2gge30KICAgICAgICAgICAgICAgIH0KICAgICAgICAg
ICAgICAgIGlmIChzY2xyKSBzY2xyLnN0eWxlLmRpc3BsYXkgPSAnbm9uZSc7CiAgICAgICAgICAg
ICAgICBxdWVyeSA9ICcnOwogICAgICAgICAgICAgICAgd2luZG93Ll9faG9zdEZpbHRlcmVkID0g
ZmFsc2U7CiAgICAgICAgICAgICAgICB3aW5kb3cuX19ob3N0RmlsdGVyUSA9ICcnOwogICAgICAg
ICAgICAgICAgLy8gV2luK1bvvJrnq4vliLvnlKjmnKrov4fmu6TnvJPlrZjpk7rliJfooajvvIzp
gb/lhY3lhYjpl6rov4fmu6Tnu5Pmnpwv56m65aOz5YaN562JIFNldFZpZXcKICAgICAgICAgICAg
ICAgIHRyeSB7CiAgICAgICAgICAgICAgICAgICAgY29uc3QgaGl0ID0gdmlld01lbS5nZXQodmll
d01lbUtleSgnYWxsJywgJycsIGZhbHNlKSk7CiAgICAgICAgICAgICAgICAgICAgaWYgKGhpdCAm
JiBBcnJheS5pc0FycmF5KGhpdC5pdGVtcykgJiYgaGl0Lml0ZW1zLmxlbmd0aCkgewogICAgICAg
ICAgICAgICAgICAgICAgICBhbGxDbGlwcyA9IGhpdC5pdGVtcy5zbGljZSgpOwogICAgICAgICAg
ICAgICAgICAgICAgICBkaXNrVG90YWwgPSBOdW1iZXIoaGl0LnRvdGFsKSB8fCBoaXQuaXRlbXMu
bGVuZ3RoOwogICAgICAgICAgICAgICAgICAgICAgICB3aW5kb3cuX19kYXRhUmVhZHkgPSB0cnVl
OwogICAgICAgICAgICAgICAgICAgICAgICBob3N0UHVzaGVkT25jZSA9IHRydWU7CiAgICAgICAg
ICAgICAgICAgICAgICAgIHNhd05vbkVtcHR5ID0gdHJ1ZTsKICAgICAgICAgICAgICAgICAgICAg
ICAgY2xlYXJXYWl0aW5nRGF0YSgpOwogICAgICAgICAgICAgICAgICAgIH0gZWxzZSB7CiAgICAg
ICAgICAgICAgICAgICAgICAgIHNjaGVkdWxlRGVsYXllZFNrZWwoKTsKICAgICAgICAgICAgICAg
ICAgICB9CiAgICAgICAgICAgICAgICB9IGNhdGNoIHsKICAgICAgICAgICAgICAgICAgICBzY2hl
ZHVsZURlbGF5ZWRTa2VsKCk7CiAgICAgICAgICAgICAgICB9CiAgICAgICAgICAgIH0gZWxzZSBp
ZiAod3JhcCkgewogICAgICAgICAgICAgICAgd3JhcC5jbGFzc0xpc3QuYWRkKCdvcGVuJyk7CiAg
ICAgICAgICAgICAgICBpZiAoc3JjaCAmJiBzcmNoLnZhbHVlKQogICAgICAgICAgICAgICAgICAg
IHF1ZXJ5ID0gc3JjaC52YWx1ZTsKICAgICAgICAgICAgICAgIC8vID8/IOaQnOe0ou+8muWcqOS4
u+acuui/h+a7pOe7k+aenOWIsOi+vuWJje+8jOWFiOaMieWFs+mUruWtl+acrOWcsOa7pO+8jOem
geatoumXquWHuuOAjOWFqOmDqOOAjQogICAgICAgICAgICAgICAgaWYgKFN0cmluZyhxdWVyeSB8
fCAnJykudHJpbSgpKSB7CiAgICAgICAgICAgICAgICAgICAgd2luZG93Ll9faG9zdEZpbHRlcmVk
ID0gZmFsc2U7CiAgICAgICAgICAgICAgICAgICAgd2luZG93Ll9faG9zdEZpbHRlclEgPSAnJzsK
ICAgICAgICAgICAgICAgIH0KICAgICAgICAgICAgfQogICAgICAgICAgICB0b2RheU9ubHkgPSBm
YWxzZTsKICAgICAgICAgICAgdHJ5IHsKICAgICAgICAgICAgICAgIGNvbnN0IGJ0blRvZGF5ID0g
ZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2J0bi10b2RheScpOwogICAgICAgICAgICAgICAgaWYg
KGJ0blRvZGF5KSBidG5Ub2RheS5jbGFzc0xpc3QucmVtb3ZlKCdvbicpOwogICAgICAgICAgICB9
IGNhdGNoIHt9CiAgICAgICAgICAgIGN1clRhYiA9ICdhbGwnOwogICAgICAgICAgICBsb2FkaW5n
TW9yZSA9IGZhbHNlOwogICAgICAgICAgICBtYXJrVGFiKCdhbGwnKTsKICAgICAgICAgICAgLy8g
5LiN6KaBIGFoaygnYmx1clBhbmVsJynvvJrkvJrot58gU2hvd1BhbmVsIOaKoueEpueCue+8jFdp
bitWLz8/IOmDveWuueaYk+mXquOAgeS5sei3swogICAgICAgICAgICByZW5kZXIoKTsKICAgICAg
ICAgICAgLy8g5ZCM5q2l5b2T5YmNIHRhYi9xdWVyeSDliLAgQUhL77yIPz8g5pu+5Y+q55SoIHZp
ZXdUYWIg5pCc6ZSZ6aG177yJCiAgICAgICAgICAgIHJlcXVlc3RWaWV3KCk7CiAgICAgICAgfSBj
YXRjaCB7fQogICAgICAgIHNlbGVjdEZpcnN0T25TaG93ID0gdHJ1ZTsKICAgICAgICBsb2NhdGVB
Y3RpdmUgPSBmYWxzZTsKICAgICAgICB1cGRhdGVMb2NhdGVCdG4oKTsKICAgICAgICBjbGVhck11
bHRpKCk7CiAgICAgICAgY29uc3QgdmlzID0gdmlzaWJsZUxpc3QoKTsKICAgICAgICBpZiAodmlz
Lmxlbmd0aCkgewogICAgICAgICAgICBzZWxlY3RlZElkID0gdmlzWzBdLmlkOwogICAgICAgICAg
ICByYW5nZUFuY2hvcklkID0gc2VsZWN0ZWRJZDsKICAgICAgICAgICAgcmFuZ2VBbmNob3JDbGlj
a2VkID0gZmFsc2U7CiAgICAgICAgICAgIGxpc3RFbC5zY3JvbGxUb3AgPSAwOwogICAgICAgIH0K
ICAgICAgICBzeW5jSXRlbUhpZ2hsaWdodCgpOwogICAgfTsKCiAgICBmdW5jdGlvbiBjdHhCaW5k
KGlkLCBmbikgewogICAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKGlkKS5hZGRFdmVudExp
c3RlbmVyKCdjbGljaycsIGUgPT4gewogICAgICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwog
ICAgICAgICAgICBpZiAoY3R4Q2xpcCkgZm4oY3R4Q2xpcCk7CiAgICAgICAgICAgIGhpZGVDdHgo
KTsKICAgICAgICB9KTsKICAgIH0KICAgIGZ1bmN0aW9uIHNxbFF1b3RlKHYpIHsKICAgICAgICBy
ZXR1cm4gIiciICsgU3RyaW5nKHYgPz8gJycpLnJlcGxhY2UoLycvZywgIicnIikgKyAiJyI7CiAg
ICB9CiAgICBmdW5jdGlvbiBzdHJpcE91dGVyUXVvdGVzKHYpIHsKICAgICAgICBjb25zdCBzID0g
U3RyaW5nKHYgPz8gJycpLnRyaW0oKTsKICAgICAgICBpZiAoKHMuc3RhcnRzV2l0aCgnIicpICYm
IHMuZW5kc1dpdGgoJyInKSkgfHwgKHMuc3RhcnRzV2l0aCgiJyIpICYmIHMuZW5kc1dpdGgoIici
KSkpCiAgICAgICAgICAgIHJldHVybiBzLnNsaWNlKDEsIC0xKTsKICAgICAgICByZXR1cm4gczsK
ICAgIH0KICAgIGZ1bmN0aW9uIHNwbGl0Q3N2UGFydHMocmF3KSB7CiAgICAgICAgY29uc3QgcyA9
IFN0cmluZyhyYXcgPz8gJycpOwogICAgICAgIGNvbnN0IHBhcnRzID0gW107CiAgICAgICAgbGV0
IGN1ciA9ICcnOwogICAgICAgIGxldCBxID0gJyc7CiAgICAgICAgZm9yIChsZXQgaSA9IDA7IGkg
PCBzLmxlbmd0aDsgaSsrKSB7CiAgICAgICAgICAgIGNvbnN0IGNoID0gc1tpXTsKICAgICAgICAg
ICAgaWYgKHEpIHsKICAgICAgICAgICAgICAgIGlmIChjaCA9PT0gcSkgewogICAgICAgICAgICAg
ICAgICAgIC8vIGRvdWJsZWQgcXVvdGUgZXNjYXBlCiAgICAgICAgICAgICAgICAgICAgaWYgKHNb
aSArIDFdID09PSBxKSB7IGN1ciArPSBxOyBpKys7IH0KICAgICAgICAgICAgICAgICAgICBlbHNl
IHEgPSAnJzsKICAgICAgICAgICAgICAgIH0gZWxzZSBjdXIgKz0gY2g7CiAgICAgICAgICAgICAg
ICBjb250aW51ZTsKICAgICAgICAgICAgfQogICAgICAgICAgICBpZiAoY2ggPT09ICciJyB8fCBj
aCA9PT0gIiciKSB7IHEgPSBjaDsgY29udGludWU7IH0KICAgICAgICAgICAgaWYgKGNoID09PSAn
LCcpIHsgcGFydHMucHVzaChjdXIudHJpbSgpKTsgY3VyID0gJyc7IGNvbnRpbnVlOyB9CiAgICAg
ICAgICAgIGN1ciArPSBjaDsKICAgICAgICB9CiAgICAgICAgcGFydHMucHVzaChjdXIudHJpbSgp
KTsKICAgICAgICByZXR1cm4gcGFydHMuZmlsdGVyKHAgPT4gcCAhPT0gJycpOwogICAgfQogICAg
ZnVuY3Rpb24gdHJhbnNmb3JtVGV4dFRvU3FsVHVwbGUocmF3LCBtb2RlKSB7CiAgICAgICAgbGV0
IHNyYyA9IFN0cmluZyhyYXcgPz8gJycpLnRyaW0oKTsKICAgICAgICBpZiAoIXNyYykgcmV0dXJu
ICcnOwogICAgICAgIGxldCBwYXJ0cyA9IFtdOwogICAgICAgIGlmIChtb2RlID09PSAnbGluZXMn
KSB7CiAgICAgICAgICAgIHBhcnRzID0gc3JjLnNwbGl0KC9ccj9cbi8pLm1hcChsID0+IHN0cmlw
T3V0ZXJRdW90ZXMobC50cmltKCkpKS5maWx0ZXIoQm9vbGVhbik7CiAgICAgICAgfSBlbHNlIHsK
ICAgICAgICAgICAgLy8ge2EsYn0gLyBhLGIgLyB7ImEiLCJiIn0KICAgICAgICAgICAgY29uc3Qg
bSA9IHNyYy5tYXRjaCgvXlxzKlx7KFtcc1xTXSopXH1ccyokLyk7CiAgICAgICAgICAgIGlmICht
KSBzcmMgPSBtWzFdLnRyaW0oKTsKICAgICAgICAgICAgcGFydHMgPSBzcGxpdENzdlBhcnRzKHNy
YykubWFwKHN0cmlwT3V0ZXJRdW90ZXMpLmZpbHRlcihCb29sZWFuKTsKICAgICAgICB9CiAgICAg
ICAgaWYgKCFwYXJ0cy5sZW5ndGgpIHJldHVybiAnJzsKICAgICAgICByZXR1cm4gJygnICsgcGFy
dHMubWFwKHNxbFF1b3RlKS5qb2luKCcsJykgKyAnKSc7CiAgICB9CiAgICBmdW5jdGlvbiBhcHBs
eURhdGFUcmFuc2Zvcm0oYywgbW9kZSkgewogICAgICAgIGlmICghYykgcmV0dXJuOwogICAgICAg
IC8vIERvIG5vdCBtdXRhdGUgY2xpcCBoaXN0b3J5IOKAlCBBSEsgdHJhbnNmb3JtcyBhIGNvcHkg
YW5kIHBhc3RlcyBpdAogICAgICAgIHRyeSB7IG1hcmtQYXN0ZWRMb2NhbChjLmlkKTsgfSBjYXRj
aCB7fQogICAgICAgIGFoaygndGV4dFRyYW5zZm9ybScsIFN0cmluZyhjLmlkKSwgU3RyaW5nKG1v
ZGUgfHwgJ2F1dG8nKSk7CiAgICB9CiAgICBmdW5jdGlvbiBkZXRlY3REYXRhVHJhbnNmb3JtTW9k
ZShyYXcpIHsKICAgICAgICAvLyBVSSBsaXN0IG9ubHkgaGFzIHRydW5jYXRlZCBwcmV2aWV3IChk
YXRhPSIiKS4KICAgICAgICAvLyBDaGVjayBcIiBmaXJzdDogZXNjYXBlZCBKU09OIG9mdGVuIGFs
c28gc3RhcnRzIHdpdGggJ3snLgogICAgICAgIGNvbnN0IHMgPSBTdHJpbmcocmF3ID8/ICcnKS50
cmltKCk7CiAgICAgICAgaWYgKCFzKSByZXR1cm4gJyc7CiAgICAgICAgaWYgKHMuaW5jbHVkZXMo
J1xcIicpKSByZXR1cm4gJ2pzb24nOwogICAgICAgIGlmIChzLnN0YXJ0c1dpdGgoJ3snKSkgcmV0
dXJuICdicmFjZSc7CiAgICAgICAgaWYgKHMuaW5jbHVkZXMoJ1xuJykgfHwgcy5pbmNsdWRlcygn
XHInKSkgcmV0dXJuICdsaW5lcyc7CiAgICAgICAgcmV0dXJuICcnOwogICAgfQogICAgZnVuY3Rp
b24gY2xlYXJEYXRhU3VibWVudVBpY2soKSB7CiAgICAgICAgdHJ5IHsKICAgICAgICAgICAgZG9j
dW1lbnQucXVlcnlTZWxlY3RvckFsbCgnI2MtZGF0YS1zdWIgLmMtaXRlbS5waWNrJykuZm9yRWFj
aChlbCA9PiBlbC5jbGFzc0xpc3QucmVtb3ZlKCdwaWNrJykpOwogICAgICAgIH0gY2F0Y2gge30K
ICAgIH0KICAgIGZ1bmN0aW9uIGhpZ2hsaWdodERhdGFTdWJtZW51TW9kZShtb2RlKSB7CiAgICAg
ICAgY2xlYXJEYXRhU3VibWVudVBpY2soKTsKICAgICAgICBjb25zdCBpZE1hcCA9IHsgYnJhY2U6
ICdjLWRhdGEtYnJhY2UnLCBsaW5lczogJ2MtZGF0YS1saW5lcycsIGpzb246ICdjLWRhdGEtanNv
bicgfTsKICAgICAgICBjb25zdCBpZCA9IGlkTWFwW21vZGVdOwogICAgICAgIGlmICghaWQpIHJl
dHVybjsKICAgICAgICBjb25zdCBlbCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKGlkKTsKICAg
ICAgICBpZiAoZWwpIGVsLmNsYXNzTGlzdC5hZGQoJ3BpY2snKTsKICAgIH0KICAgIGZ1bmN0aW9u
IHByZXZpZXdEYXRhVHJhbnNmb3JtTW9kZUFzeW5jKCkgewogICAgICAgIGNvbnN0IHRva2VuID0g
KytwcmV2aWV3RGF0YVRyYW5zZm9ybVNlcTsKICAgICAgICBjb25zdCBjbGlwID0gY3R4Q2xpcDsK
ICAgICAgICBzZXRUaW1lb3V0KCgpID0+IHsKICAgICAgICAgICAgaWYgKHRva2VuICE9PSBwcmV2
aWV3RGF0YVRyYW5zZm9ybVNlcSkgcmV0dXJuOwogICAgICAgICAgICBpZiAoIWNsaXAgfHwgY3R4
Q2xpcCAhPT0gY2xpcCkgcmV0dXJuOwogICAgICAgICAgICBjb25zdCByYXcgPSBTdHJpbmcoY2xp
cC5kYXRhIHx8IGNsaXAucHJldmlldyB8fCAnJyk7CiAgICAgICAgICAgIGNvbnN0IG1vZGUgPSBk
ZXRlY3REYXRhVHJhbnNmb3JtTW9kZShyYXcpOwogICAgICAgICAgICBpZiAodG9rZW4gIT09IHBy
ZXZpZXdEYXRhVHJhbnNmb3JtU2VxKSByZXR1cm47CiAgICAgICAgICAgIGhpZ2hsaWdodERhdGFT
dWJtZW51TW9kZShtb2RlKTsKICAgICAgICB9LCAwKTsKICAgIH0KICAgIGxldCBwcmV2aWV3RGF0
YVRyYW5zZm9ybVNlcSA9IDA7CiAgICBjb25zdCBkYXRhUGFyZW50ID0gZG9jdW1lbnQuZ2V0RWxl
bWVudEJ5SWQoJ2MtZGF0YScpOwogICAgY29uc3QgZGF0YVdyYXBFbCA9IGRvY3VtZW50LmdldEVs
ZW1lbnRCeUlkKCdjLWRhdGEtd3JhcCcpOwogICAgaWYgKGRhdGFQYXJlbnQpIHsKICAgICAgICBk
YXRhUGFyZW50LmFkZEV2ZW50TGlzdGVuZXIoJ2NsaWNrJywgZSA9PiB7CiAgICAgICAgICAgIGUu
c3RvcFByb3BhZ2F0aW9uKCk7CiAgICAgICAgICAgIC8vIFByaW1hcnkgY2xpY2sgPSBhdXRvIGRl
dGVjdCArIHRyYW5zZm9ybSArIHBhc3RlCiAgICAgICAgICAgIGlmIChjdHhDbGlwKSB7CiAgICAg
ICAgICAgICAgICBhcHBseURhdGFUcmFuc2Zvcm0oY3R4Q2xpcCwgJ2F1dG8nKTsKICAgICAgICAg
ICAgICAgIGhpZGVDdHgoKTsKICAgICAgICAgICAgICAgIHJldHVybjsKICAgICAgICAgICAgfQog
ICAgICAgICAgICBjb25zdCB3cmFwID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2MtZGF0YS13
cmFwJyk7CiAgICAgICAgICAgIGlmICh3cmFwKSB7CiAgICAgICAgICAgICAgICB3cmFwLmNsYXNz
TGlzdC50b2dnbGUoJ29wZW4nKTsKICAgICAgICAgICAgICAgIHBsYWNlRGF0YVN1Ym1lbnUoKTsK
ICAgICAgICAgICAgICAgIHByZXZpZXdEYXRhVHJhbnNmb3JtTW9kZUFzeW5jKCk7CiAgICAgICAg
ICAgIH0KICAgICAgICB9KTsKICAgIH0KICAgIGlmIChkYXRhV3JhcEVsKSB7CiAgICAgICAgZGF0
YVdyYXBFbC5hZGRFdmVudExpc3RlbmVyKCdtb3VzZWVudGVyJywgKCkgPT4gewogICAgICAgICAg
ICBwbGFjZURhdGFTdWJtZW51KCk7CiAgICAgICAgICAgIHByZXZpZXdEYXRhVHJhbnNmb3JtTW9k
ZUFzeW5jKCk7CiAgICAgICAgfSk7CiAgICAgICAgZGF0YVdyYXBFbC5hZGRFdmVudExpc3RlbmVy
KCdtb3VzZWxlYXZlJywgKCkgPT4gY2xlYXJEYXRhU3VibWVudVBpY2soKSk7CiAgICB9CiAgICBj
dHhCaW5kKCdjLWRhdGEtYnJhY2UnLCBjID0+IGFwcGx5RGF0YVRyYW5zZm9ybShjLCAnYnJhY2Un
KSk7CiAgICBjdHhCaW5kKCdjLWRhdGEtbGluZXMnLCBjID0+IGFwcGx5RGF0YVRyYW5zZm9ybShj
LCAnbGluZXMnKSk7CiAgICBjdHhCaW5kKCdjLWRhdGEtanNvbicsIGMgPT4gYXBwbHlEYXRhVHJh
bnNmb3JtKGMsICdqc29uJykpOwogICAgY3R4QmluZCgnYy1jb3B5JywgIGMgPT4gewogICAgICAg
IGlmIChub3JtVHlwZShjLnR5cGUpID09PSAncmVjZW50JykKICAgICAgICAgICAgYWhrKCdjb3B5
UGF0aCcsIFN0cmluZyhjLmRhdGEgfHwgYy5wcmV2aWV3IHx8ICcnKSk7CiAgICAgICAgZWxzZQog
ICAgICAgICAgICBhaGsoJ2NvcHlCeUlkJywgU3RyaW5nKGMuaWQpKTsKICAgIH0pOwogICAgY3R4
QmluZCgnYy1wYXN0ZScsIGMgPT4gewogICAgICAgIGFjdGl2YXRlQ2xpcEl0ZW0oYyk7CiAgICB9
KTsKICAgIGN0eEJpbmQoJ2MtcGluJywgICBjID0+IHsKICAgICAgICAvLyBPcHRpbWlzdGljIGZs
aXAg4oCUIOWbuuWumuWPqumYsua3mOaxsO+8jOS4jee9rumhtu+8m+WGjeasoeiuv+mXruaJjemd
oCBSZWNvcmQg6aG25Yiw5LiK6Z2iCiAgICAgICAgY29uc3QgbmV4dCA9ICFpc1Bpbm5lZChjKTsK
ICAgICAgICBjb25zdCBpZCA9ICtjLmlkOwogICAgICAgIHBhdGNoUGlubmVkSW5DYWNoZXMoaWQs
IG5leHQpOwogICAgICAgIGMucGlubmVkID0gbmV4dDsKICAgICAgICBpZiAobmV4dCkgbWFya0Zh
dlVuc2VlbihpZCk7CiAgICAgICAgZWxzZSB7CiAgICAgICAgICAgIHVuc2VlbkZhdklkcy5kZWxl
dGUoaWQpOwogICAgICAgICAgICBzYXZlVW5zZWVuRmF2KCk7CiAgICAgICAgICAgIHVwZGF0ZVBp
bkRvdCgpOwogICAgICAgIH0KICAgICAgICAvLyDmlLbol4/pobXlj5bmtojvvJrnq4vliLvku47l
iJfooajmkZjmjonvvIzliKvnrYkgU2V0VmlldyDmiavnm5gKICAgICAgICBpZiAoIW5leHQgJiYg
Y3VyVGFiID09PSAncGlubmVkJykgewogICAgICAgICAgICBhbGxDbGlwcyA9IGFsbENsaXBzLmZp
bHRlcih4ID0+ICt4LmlkICE9PSBpZCk7CiAgICAgICAgICAgIGRpc2tUb3RhbCA9IE1hdGgubWF4
KDAsIChOdW1iZXIoZGlza1RvdGFsKSB8fCAwKSAtIDEpOwogICAgICAgICAgICBwaW5uZWRUb3Rh
bCA9IE1hdGgubWF4KDAsIChOdW1iZXIocGlubmVkVG90YWwpIHx8IDApIC0gMSk7CiAgICAgICAg
ICAgIGlmICgrc2VsZWN0ZWRJZCA9PT0gaWQpCiAgICAgICAgICAgICAgICBzZWxlY3RlZElkID0g
YWxsQ2xpcHMubGVuZ3RoID8gYWxsQ2xpcHNbMF0uaWQgOiAwOwogICAgICAgICAgICB0cnkgewog
ICAgICAgICAgICAgICAgdmlld01lbS5zZXQodmlld01lbUtleShjdXJUYWIsIHF1ZXJ5LCB0b2Rh
eU9ubHkpLCB7CiAgICAgICAgICAgICAgICAgICAgaXRlbXM6IGFsbENsaXBzLnNsaWNlKCksCiAg
ICAgICAgICAgICAgICAgICAgdG90YWw6IGRpc2tUb3RhbAogICAgICAgICAgICAgICAgfSk7CiAg
ICAgICAgICAgIH0gY2F0Y2gge30KICAgICAgICAgICAgY2xlYXJGYXZVbnNlZW4oKTsKICAgICAg
ICB9IGVsc2UgaWYgKGN1clRhYiA9PT0gJ3Bpbm5lZCcpIHsKICAgICAgICAgICAgY2xlYXJGYXZV
bnNlZW4oKTsKICAgICAgICB9CiAgICAgICAgcmVuZGVyKCk7CiAgICAgICAgYWhrKCdwaW4nLCBT
dHJpbmcoYy5pZCkpOwogICAgfSk7CiAgICBjdHhCaW5kKCdjLXRvcCcsICAgYyA9PiBhaGsoJ21v
dmVUb1RvcCcsICAgICBTdHJpbmcoYy5pZCkpKTsKICAgIGN0eEJpbmQoJ2MtY2xlYXItcGFzdGVk
JywgYyA9PiBhaGsoJ2NsZWFyUGFzdGVkJywgU3RyaW5nKGMuaWQpKSk7CiAgICBjdHhCaW5kKCdj
LXF1ZXVlLWZyb20nLCBjID0+IHsKICAgICAgICBhaGsoJ3Jlc2V0UXVldWVGcm9tJywgU3RyaW5n
KGMuaWQpKTsKICAgICAgICBpZiAoIXBpbm5lZFVJKSBhaGsoJ2hpZGUnKTsKICAgIH0pOwogICAg
Y3R4QmluZCgnYy1kZWwnLCAgIGMgPT4gewogICAgICAgIC8vIOWkmumAieS4lOWPs+mUrueCueWc
qOmAieS4remhueS4iiDihpIg5om56YeP5Yig6Zmk77yb5ZCm5YiZ5Y+q5Yig5b2T5YmNCiAgICAg
ICAgbGV0IGlkcyA9IFtdOwogICAgICAgIGlmIChtdWx0aUlkcy5sZW5ndGggPiAxICYmIG11bHRp
SWRzLmluY2x1ZGVzKCtjLmlkKSkKICAgICAgICAgICAgaWRzID0gbXVsdGlJZHMuc2xpY2UoKTsK
ICAgICAgICBlbHNlCiAgICAgICAgICAgIGlkcyA9IFsrYy5pZF07CiAgICAgICAgaWRzID0gaWRz
Lm1hcCh4ID0+ICt4KS5maWx0ZXIoeCA9PiB4ID4gMCk7CiAgICAgICAgaWYgKCFpZHMubGVuZ3Ro
KSByZXR1cm47CiAgICAgICAgdHJ5IHsKICAgICAgICAgICAgY29uc3QgaWRTZXQgPSBuZXcgU2V0
KGlkcyk7CiAgICAgICAgICAgIGFsbENsaXBzID0gYWxsQ2xpcHMuZmlsdGVyKHggPT4gIWlkU2V0
LmhhcygreC5pZCkpOwogICAgICAgICAgICBkaXNrVG90YWwgPSBNYXRoLm1heCgwLCAoTnVtYmVy
KGRpc2tUb3RhbCkgfHwgMCkgLSBpZHMubGVuZ3RoKTsKICAgICAgICAgICAgaWYgKGlkU2V0Lmhh
cygrc2VsZWN0ZWRJZCkpCiAgICAgICAgICAgICAgICBzZWxlY3RlZElkID0gYWxsQ2xpcHMubGVu
Z3RoID8gYWxsQ2xpcHNbMF0uaWQgOiAwOwogICAgICAgICAgICBjbGVhck11bHRpKCk7CiAgICAg
ICAgICAgIHJlbmRlcigpOwogICAgICAgIH0gY2F0Y2gge30KICAgICAgICBpZiAoaWRzLmxlbmd0
aCA9PT0gMSkKICAgICAgICAgICAgYWhrKCdkZWxldGUnLCBTdHJpbmcoaWRzWzBdKSk7CiAgICAg
ICAgZWxzZQogICAgICAgICAgICBhaGsoJ2RlbGV0ZU1hbnknLCBpZHMuam9pbignLCcpKTsKICAg
IH0pOwogICAgY3R4QmluZCgnYy10aXRsZScsIGMgPT4gb3BlblRpdGxlRGxnKGMpKTsKICAgIGN0
eEJpbmQoJ2MtbWVyZ2UnLCBjID0+IHsKICAgICAgICBjb25zdCBpZHMgPSAobXVsdGlJZHMubGVu
Z3RoID49IDIpID8gbXVsdGlJZHMuc2xpY2UoKSA6IFtdOwogICAgICAgIGlmIChpZHMubGVuZ3Ro
IDwgMikgcmV0dXJuOwogICAgICAgIGlmICghaWRzLmluY2x1ZGVzKCtjLmlkKSkgaWRzLnB1c2go
K2MuaWQpOwogICAgICAgIGFoaygnbWVyZ2VGYXYnLCBpZHMuam9pbignLCcpKTsKICAgICAgICBj
bGVhck11bHRpKCk7CiAgICB9KTsKICAgIGN0eEJpbmQoJ2MtdW5tZXJnZScsIGMgPT4gewogICAg
ICAgIGFoaygndW5tZXJnZUZhdicsIFN0cmluZyhjLmlkKSk7CiAgICAgICAgY2xlYXJNdWx0aSgp
OwogICAgfSk7CgogICAgY29uc3QgdGl0bGVEbGcgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgn
dGl0bGUtZGxnJyk7CiAgICBjb25zdCB0aXRsZUlucHV0ID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5
SWQoJ3RpdGxlLWlucHV0Jyk7CiAgICBsZXQgdGl0bGVEbGdDbGlwID0gbnVsbDsKICAgIGZ1bmN0
aW9uIGNsb3NlVGl0bGVEbGcoKSB7CiAgICAgICAgaWYgKHRpdGxlRGxnKSB0aXRsZURsZy5jbGFz
c0xpc3QucmVtb3ZlKCdvbicpOwogICAgICAgIHRpdGxlRGxnQ2xpcCA9IG51bGw7CiAgICB9CiAg
ICBmdW5jdGlvbiBvcGVuVGl0bGVEbGcoYykgewogICAgICAgIGhpZGVDdHgoKTsKICAgICAgICB0
aXRsZURsZ0NsaXAgPSBjOwogICAgICAgIGlmICh0aXRsZUlucHV0KSB0aXRsZUlucHV0LnZhbHVl
ID0gU3RyaW5nKGMuZmF2VGl0bGUgfHwgJycpLnRyaW0oKTsKICAgICAgICBpZiAodGl0bGVEbGcp
IHRpdGxlRGxnLmNsYXNzTGlzdC5hZGQoJ29uJyk7CiAgICAgICAgYWhrKCdmb2N1c1BhbmVsJyk7
CiAgICAgICAgcmVxdWVzdEFuaW1hdGlvbkZyYW1lKCgpID0+IHsKICAgICAgICAgICAgdHJ5IHsg
dGl0bGVJbnB1dC5mb2N1cygpOyB0aXRsZUlucHV0LnNlbGVjdCgpOyB9IGNhdGNoIHt9CiAgICAg
ICAgfSk7CiAgICB9CiAgICBpZiAodGl0bGVEbGcpIHsKICAgICAgICB0aXRsZURsZy5hZGRFdmVu
dExpc3RlbmVyKCdjbGljaycsIGUgPT4gewogICAgICAgICAgICBpZiAoZS50YXJnZXQgPT09IHRp
dGxlRGxnKSBjbG9zZVRpdGxlRGxnKCk7CiAgICAgICAgfSk7CiAgICB9CiAgICBkb2N1bWVudC5n
ZXRFbGVtZW50QnlJZCgndGl0bGUtY2FuY2VsJyk/LmFkZEV2ZW50TGlzdGVuZXIoJ2NsaWNrJywg
ZSA9PiB7CiAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICBjbG9zZVRpdGxlRGxn
KCk7CiAgICAgICAgYWhrKCdibHVyUGFuZWwnKTsKICAgIH0pOwogICAgZG9jdW1lbnQuZ2V0RWxl
bWVudEJ5SWQoJ3RpdGxlLW9rJyk/LmFkZEV2ZW50TGlzdGVuZXIoJ2NsaWNrJywgZSA9PiB7CiAg
ICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICBpZiAoIXRpdGxlRGxnQ2xpcCkgcmV0
dXJuOwogICAgICAgIGNvbnN0IHQgPSBTdHJpbmcodGl0bGVJbnB1dD8udmFsdWUgfHwgJycpLnRy
aW0oKS5zbGljZSgwLCA4MCk7CiAgICAgICAgY29uc3QgaWQgPSBTdHJpbmcodGl0bGVEbGdDbGlw
LmlkKTsKICAgICAgICAvLyBPcHRpbWlzdGljIGxvY2FsIHVwZGF0ZQogICAgICAgIGNvbnN0IGhp
dCA9IGFsbENsaXBzLmZpbmQoeCA9PiAreC5pZCA9PT0gK2lkKTsKICAgICAgICBpZiAoaGl0KSBo
aXQuZmF2VGl0bGUgPSB0OwogICAgICAgIHRpdGxlRGxnQ2xpcC5mYXZUaXRsZSA9IHQ7CiAgICAg
ICAgY2xvc2VUaXRsZURsZygpOwogICAgICAgIGFoaygnc2V0RmF2VGl0bGUnLCBpZCwgdCk7CiAg
ICAgICAgYWhrKCdibHVyUGFuZWwnKTsKICAgICAgICByZW5kZXIoKTsKICAgIH0pOwogICAgdGl0
bGVJbnB1dD8uYWRkRXZlbnRMaXN0ZW5lcigna2V5ZG93bicsIGUgPT4gewogICAgICAgIGlmIChl
LmtleSA9PT0gJ0VudGVyJykgewogICAgICAgICAgICBlLnByZXZlbnREZWZhdWx0KCk7CiAgICAg
ICAgICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAgICAgICAgIGUuc3RvcEltbWVkaWF0ZVBy
b3BhZ2F0aW9uKCk7CiAgICAgICAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd0aXRsZS1v
aycpPy5jbGljaygpOwogICAgICAgICAgICByZXR1cm47CiAgICAgICAgfQogICAgICAgIGlmIChl
LmtleSA9PT0gJ0VzY2FwZScpIHsKICAgICAgICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOwogICAg
ICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgICAgICAgICBjbG9zZVRpdGxlRGxnKCk7
CiAgICAgICAgICAgIGFoaygnYmx1clBhbmVsJyk7CiAgICAgICAgICAgIHJldHVybjsKICAgICAg
ICB9CiAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgIH0sIHRydWUpOwoKICAgIGRvY3Vt
ZW50LmdldEVsZW1lbnRCeUlkKCd0YWJzJykuYWRkRXZlbnRMaXN0ZW5lcignY2xpY2snLCBlID0+
IHsKICAgICAgICBjb25zdCB0YWIgPSBlLnRhcmdldC5jbG9zZXN0KCcudGFiJyk7CiAgICAgICAg
aWYgKCF0YWIgfHwgZS50YXJnZXQuY2xvc2VzdCgnI3RhYi1hY3Rpb25zJykpIHJldHVybjsKICAg
ICAgICBzZXRUYWIodGFiLmRhdGFzZXQudGFiKTsKICAgIH0pOwoKICAgIGNvbnN0IHNyY2hXcmFw
ID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NlYXJjaC13cmFwJyk7CiAgICBjb25zdCBidG5T
ZWFyY2ggPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYnRuLXNlYXJjaCcpOwogICAgY29uc3Qg
YnRuTG9jYXRlID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2J0bi1sb2NhdGUnKTsKICAgIGNv
bnN0IGJ0blRvZGF5ID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2J0bi10b2RheScpOwogICAg
Y29uc3Qgc3JjaCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzZWFyY2gnKTsKICAgIGNvbnN0
IHNjbHIgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc2VhcmNoLWNscicpOwogICAgbGV0IGRl
YjsKCiAgICB1cGRhdGVMb2NhdGVCdG4oKTsKICAgIGlmIChidG5Mb2NhdGUpIHsKICAgICAgICBi
dG5Mb2NhdGUuYWRkRXZlbnRMaXN0ZW5lcignY2xpY2snLCBlID0+IHsKICAgICAgICAgICAgZS5z
dG9wUHJvcGFnYXRpb24oKTsKICAgICAgICAgICAganVtcFRvTGFzdFBhc3RlKCk7CiAgICAgICAg
fSk7CiAgICB9CgogICAgYnRuVG9kYXkuYWRkRXZlbnRMaXN0ZW5lcignbW91c2Vkb3duJywgZSA9
PiB7CiAgICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOwogICAgICAgIGUuc3RvcFByb3BhZ2F0aW9u
KCk7CiAgICB9KTsKICAgIGJ0blRvZGF5LmFkZEV2ZW50TGlzdGVuZXIoJ2NsaWNrJywgZSA9PiB7
CiAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICBlLnByZXZlbnREZWZhdWx0KCk7
CiAgICAgICAgdG9kYXlPbmx5ID0gIXRvZGF5T25seTsKICAgICAgICBidG5Ub2RheS5jbGFzc0xp
c3QudG9nZ2xlKCdvbicsIHRvZGF5T25seSk7CiAgICAgICAgbGlzdEVsLnNjcm9sbFRvcCA9IDA7
CiAgICAgICAgcmVxdWVzdFZpZXcoKTsKICAgICAgICB0cnkgeyBzcmNoLmZvY3VzKCk7IH0gY2F0
Y2gge30KICAgIH0pOwoKICAgIGZ1bmN0aW9uIG9wZW5TZWFyY2goKSB7CiAgICAgICAgaWYgKHNy
Y2hXcmFwLmNsYXNzTGlzdC5jb250YWlucygnb3BlbicpKSB7CiAgICAgICAgICAgIGFoaygnZm9j
dXNQYW5lbCcpOwogICAgICAgICAgICB0cnkgeyBzcmNoLmZvY3VzKCk7IH0gY2F0Y2gge30KICAg
ICAgICAgICAgcmV0dXJuOwogICAgICAgIH0KICAgICAgICBzcmNoV3JhcC5jbGFzc0xpc3QuYWRk
KCdvcGVuJyk7CiAgICAgICAgLy8gRGVmYXVsdDog5omA5pyJ6aG15omT5byA5pCc57Si5pe26buY
6K6k5pCc5YWo6YOoCiAgICAgICAgY29uc3Qgd2FudFRvZGF5ID0gZmFsc2U7CiAgICAgICAgaWYg
KHRvZGF5T25seSAhPT0gd2FudFRvZGF5KSB7CiAgICAgICAgICAgIHRvZGF5T25seSA9IHdhbnRU
b2RheTsKICAgICAgICAgICAgYnRuVG9kYXkuY2xhc3NMaXN0LnRvZ2dsZSgnb24nLCB0b2RheU9u
bHkpOwogICAgICAgICAgICBsaXN0RWwuc2Nyb2xsVG9wID0gMDsKICAgICAgICAgICAgcmVxdWVz
dFZpZXcoKTsKICAgICAgICB9IGVsc2UgewogICAgICAgICAgICBidG5Ub2RheS5jbGFzc0xpc3Qu
dG9nZ2xlKCdvbicsIHRvZGF5T25seSk7CiAgICAgICAgfQogICAgICAgIGFoaygnZm9jdXNQYW5l
bCcpOwogICAgICAgIHJlcXVlc3RBbmltYXRpb25GcmFtZSgoKSA9PiB7CiAgICAgICAgICAgIHRy
eSB7IHNyY2guZm9jdXMoKTsgfSBjYXRjaCB7fQogICAgICAgIH0pOwogICAgfQogICAgZnVuY3Rp
b24gY2xvc2VTZWFyY2hVaSgpIHsKICAgICAgICBzcmNoV3JhcC5jbGFzc0xpc3QucmVtb3ZlKCdv
cGVuJyk7CiAgICAgICAgaWYgKCFzcmNoLnZhbHVlKSB7CiAgICAgICAgICAgIHNyY2guY2xhc3NM
aXN0LnJlbW92ZSgnaGFzLXZhbCcpOwogICAgICAgICAgICBzY2xyLnN0eWxlLmRpc3BsYXkgPSAn
bm9uZSc7CiAgICAgICAgICAgIC8vIExlYXZpbmcgc2VhcmNoIHdpdGggZW1wdHkgcXVlcnkg4oaS
IGRyb3AgdG9kYXkgZmlsdGVyCiAgICAgICAgICAgIGlmICh0b2RheU9ubHkpIHsKICAgICAgICAg
ICAgICAgIHRvZGF5T25seSA9IGZhbHNlOwogICAgICAgICAgICAgICAgYnRuVG9kYXkuY2xhc3NM
aXN0LnJlbW92ZSgnb24nKTsKICAgICAgICAgICAgICAgIHJlcXVlc3RWaWV3KCk7CiAgICAgICAg
ICAgIH0KICAgICAgICB9CiAgICB9CiAgICB3aW5kb3cuX19vcGVuU2VhcmNoID0gb3BlblNlYXJj
aDsKICAgIHdpbmRvdy5fX3ByZXBUeXBlU2VhcmNoID0gKCkgPT4gewogICAgICAgIHRyeSB7CiAg
ICAgICAgICAgIGNvbnN0IHdyYXAgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc2VhcmNoLXdy
YXAnKTsKICAgICAgICAgICAgY29uc3QgcyA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzZWFy
Y2gnKTsKICAgICAgICAgICAgaWYgKHdyYXAgJiYgIXdyYXAuY2xhc3NMaXN0LmNvbnRhaW5zKCdv
cGVuJykpIHsKICAgICAgICAgICAgICAgIHdyYXAuY2xhc3NMaXN0LmFkZCgnb3BlbicpOwogICAg
ICAgICAgICAgICAgdHJ5IHsKICAgICAgICAgICAgICAgICAgICBjb25zdCB3YW50VG9kYXkgPSBm
YWxzZTsKICAgICAgICAgICAgICAgICAgICBpZiAodHlwZW9mIHRvZGF5T25seSAhPT0gJ3VuZGVm
aW5lZCcgJiYgdG9kYXlPbmx5ICE9PSB3YW50VG9kYXkpIHsKICAgICAgICAgICAgICAgICAgICAg
ICAgdG9kYXlPbmx5ID0gd2FudFRvZGF5OwogICAgICAgICAgICAgICAgICAgICAgICBpZiAodHlw
ZW9mIGJ0blRvZGF5ICE9PSAndW5kZWZpbmVkJyAmJiBidG5Ub2RheSkgYnRuVG9kYXkuY2xhc3NM
aXN0LnRvZ2dsZSgnb24nLCB0b2RheU9ubHkpOwogICAgICAgICAgICAgICAgICAgICAgICBpZiAo
dHlwZW9mIGxpc3RFbCAhPT0gJ3VuZGVmaW5lZCcgJiYgbGlzdEVsKSBsaXN0RWwuc2Nyb2xsVG9w
ID0gMDsKICAgICAgICAgICAgICAgICAgICAgICAgaWYgKHR5cGVvZiByZXF1ZXN0VmlldyA9PT0g
J2Z1bmN0aW9uJykgc2V0VGltZW91dChyZXF1ZXN0VmlldywgMCk7CiAgICAgICAgICAgICAgICAg
ICAgfSBlbHNlIGlmICh0eXBlb2YgYnRuVG9kYXkgIT09ICd1bmRlZmluZWQnICYmIGJ0blRvZGF5
KSB7CiAgICAgICAgICAgICAgICAgICAgICAgIGJ0blRvZGF5LmNsYXNzTGlzdC50b2dnbGUoJ29u
JywgISF0b2RheU9ubHkpOwogICAgICAgICAgICAgICAgICAgIH0KICAgICAgICAgICAgICAgIH0g
Y2F0Y2gge30KICAgICAgICAgICAgfQogICAgICAgICAgICAvLyA/PyDplZzlg4/mkJzntKLvvJrk
uI3opoEgZm9jdXPvvIzpgb/lhY3miqLotbDljp/nvJbovpHmoYblhYnmoIcKICAgICAgICB9IGNh
dGNoIHt9CiAgICB9OwogICAgd2luZG93Ll9fdHlwZVNlYXJjaCA9IChjaCkgPT4gewogICAgICAg
IHRyeSB7CiAgICAgICAgICAgIHdpbmRvdy5fX3ByZXBUeXBlU2VhcmNoICYmIHdpbmRvdy5fX3By
ZXBUeXBlU2VhcmNoKCk7CiAgICAgICAgICAgIGNvbnN0IHMgPSBkb2N1bWVudC5nZXRFbGVtZW50
QnlJZCgnc2VhcmNoJyk7CiAgICAgICAgICAgIGlmICghcykgcmV0dXJuOwogICAgICAgICAgICBz
LnZhbHVlID0gU3RyaW5nKHMudmFsdWUgfHwgJycpICsgU3RyaW5nKGNoID09IG51bGwgPyAnJyA6
IGNoKTsKICAgICAgICAgICAgcy5jbGFzc0xpc3QudG9nZ2xlKCdoYXMtdmFsJywgISFzLnZhbHVl
KTsKICAgICAgICAgICAgcy5kaXNwYXRjaEV2ZW50KG5ldyBFdmVudCgnaW5wdXQnLCB7IGJ1YmJs
ZXM6IHRydWUgfSkpOwogICAgICAgIH0gY2F0Y2gge30KICAgIH07CiAgICB3aW5kb3cuX19ia3Nw
U2VhcmNoID0gKCkgPT4gewogICAgICAgIHRyeSB7CiAgICAgICAgICAgIHdpbmRvdy5fX3ByZXBU
eXBlU2VhcmNoICYmIHdpbmRvdy5fX3ByZXBUeXBlU2VhcmNoKCk7CiAgICAgICAgICAgIGNvbnN0
IHMgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc2VhcmNoJyk7CiAgICAgICAgICAgIGlmICgh
cykgcmV0dXJuOwogICAgICAgICAgICBjb25zdCB2ID0gU3RyaW5nKHMudmFsdWUgfHwgJycpOwog
ICAgICAgICAgICBzLnZhbHVlID0gdi5sZW5ndGggPyB2LnNsaWNlKDAsIC0xKSA6ICcnOwogICAg
ICAgICAgICBzLmNsYXNzTGlzdC50b2dnbGUoJ2hhcy12YWwnLCAhIXMudmFsdWUpOwogICAgICAg
ICAgICBzLmRpc3BhdGNoRXZlbnQobmV3IEV2ZW50KCdpbnB1dCcsIHsgYnViYmxlczogdHJ1ZSB9
KSk7CiAgICAgICAgfSBjYXRjaCB7fQogICAgfTsKICAgIHdpbmRvdy5fX3NldFNlYXJjaFF1ZXJ5
ID0gKHEpID0+IHsKICAgICAgICB0cnkgewogICAgICAgICAgICBjb25zdCBzID0gZG9jdW1lbnQu
Z2V0RWxlbWVudEJ5SWQoJ3NlYXJjaCcpOwogICAgICAgICAgICBpZiAoIXMpIHJldHVybjsKICAg
ICAgICAgICAgY29uc3QgbmV4dCA9IFN0cmluZyhxID09IG51bGwgPyAnJyA6IHEpOwogICAgICAg
ICAgICBjb25zdCBwcmV2ID0gU3RyaW5nKHMudmFsdWUgfHwgJycpOwogICAgICAgICAgICAvLyDl
kIzlhbPplK7lrZfph43lpI3mjqjpgIHvvJrlj6rkv53or4HmkJzntKLmoYblvIDnnYDvvIznpoHm
raLlho0gcmVxdWVzdFZpZXfvvIjkvJrmrbvlvqrnjq/pl6rvvIkKICAgICAgICAgICAgaWYgKHBy
ZXYgPT09IG5leHQgJiYgU3RyaW5nKHF1ZXJ5IHx8ICcnKSA9PT0gbmV4dCkgewogICAgICAgICAg
ICAgICAgdHJ5IHsKICAgICAgICAgICAgICAgICAgICBjb25zdCB3cmFwID0gZG9jdW1lbnQuZ2V0
RWxlbWVudEJ5SWQoJ3NlYXJjaC13cmFwJyk7CiAgICAgICAgICAgICAgICAgICAgaWYgKHdyYXAg
JiYgIXdyYXAuY2xhc3NMaXN0LmNvbnRhaW5zKCdvcGVuJykpCiAgICAgICAgICAgICAgICAgICAg
ICAgIHdyYXAuY2xhc3NMaXN0LmFkZCgnb3BlbicpOwogICAgICAgICAgICAgICAgfSBjYXRjaCB7
fQogICAgICAgICAgICAgICAgcmV0dXJuOwogICAgICAgICAgICB9CiAgICAgICAgICAgIC8vIOaJ
k+Wtl+WNs+aXtuS4iuWxj++8jOS4juejgeebmOaQnOe0ouino+iApgogICAgICAgICAgICBzLnZh
bHVlID0gbmV4dDsKICAgICAgICAgICAgcy5jbGFzc0xpc3QudG9nZ2xlKCdoYXMtdmFsJywgISFz
LnZhbHVlKTsKICAgICAgICAgICAgY29uc3Qgc2NsciA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlk
KCdzZWFyY2gtY2xyJyk7CiAgICAgICAgICAgIGlmIChzY2xyKSBzY2xyLnN0eWxlLmRpc3BsYXkg
PSBzLnZhbHVlID8gJ2Jsb2NrJyA6ICdub25lJzsKICAgICAgICAgICAgcXVlcnkgPSBzLnZhbHVl
OwogICAgICAgICAgICB0cnkgewogICAgICAgICAgICAgICAgY29uc3Qgd3JhcCA9IGRvY3VtZW50
LmdldEVsZW1lbnRCeUlkKCdzZWFyY2gtd3JhcCcpOwogICAgICAgICAgICAgICAgaWYgKHdyYXAg
JiYgIXdyYXAuY2xhc3NMaXN0LmNvbnRhaW5zKCdvcGVuJykpCiAgICAgICAgICAgICAgICAgICAg
d2luZG93Ll9fcHJlcFR5cGVTZWFyY2ggJiYgd2luZG93Ll9fcHJlcFR5cGVTZWFyY2goKTsKICAg
ICAgICAgICAgICAgIGVsc2UgaWYgKHdyYXApCiAgICAgICAgICAgICAgICAgICAgd3JhcC5jbGFz
c0xpc3QuYWRkKCdvcGVuJyk7CiAgICAgICAgICAgIH0gY2F0Y2gge30KICAgICAgICAgICAgd2lu
ZG93Ll9faG9zdEZpbHRlcmVkID0gZmFsc2U7CiAgICAgICAgICAgIHdpbmRvdy5fX2hvc3RGaWx0
ZXJRID0gJyc7CiAgICAgICAgICAgIGlmIChTdHJpbmcocXVlcnkgfHwgJycpLnRyaW0oKSkgewog
ICAgICAgICAgICAgICAgd2FpdGluZ0RhdGEgPSB0cnVlOwogICAgICAgICAgICAgICAgd2luZG93
Ll9fZGF0YVJlYWR5ID0gZmFsc2U7CiAgICAgICAgICAgIH0KICAgICAgICAgICAgdHJ5IHsKICAg
ICAgICAgICAgICAgIGNvbnN0IGNudCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdiYXItdHh0
Jyk7CiAgICAgICAgICAgICAgICBpZiAoY250ICYmIFN0cmluZyhxdWVyeSB8fCAnJykudHJpbSgp
KQogICAgICAgICAgICAgICAgICAgIGNudC50ZXh0Q29udGVudCA9IHZpc2libGVMaXN0KCkubGVu
Z3RoICsgJyDmnaEnOwogICAgICAgICAgICB9IGNhdGNoIHt9CiAgICAgICAgICAgIHRyeSB7IHJl
bmRlcigpOyB9IGNhdGNoIHt9CiAgICAgICAgICAgIGNsZWFyVGltZW91dCh3aW5kb3cuX19xcVZp
ZXdEZWIpOwogICAgICAgICAgICB3aW5kb3cuX19xcVZpZXdEZWIgPSBzZXRUaW1lb3V0KCgpID0+
IHsKICAgICAgICAgICAgICAgIHdpbmRvdy5fX3FxVmlld0RlYiA9IDA7CiAgICAgICAgICAgICAg
ICByZXF1ZXN0VmlldygpOwogICAgICAgICAgICB9LCA3MCk7CiAgICAgICAgfSBjYXRjaCB7fQog
ICAgfTsKICAgIHdpbmRvdy5fX2NsZWFyUVFTZWFyY2ggPSAoKSA9PiB7CiAgICAgICAgdHJ5IHsK
ICAgICAgICAgICAgcXVlcnkgPSAnJzsKICAgICAgICAgICAgd2luZG93Ll9faG9zdEZpbHRlcmVk
ID0gZmFsc2U7CiAgICAgICAgICAgIHdpbmRvdy5fX2hvc3RGaWx0ZXJRID0gJyc7CiAgICAgICAg
ICAgIGNvbnN0IHMgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc2VhcmNoJyk7CiAgICAgICAg
ICAgIGlmIChzKSB7CiAgICAgICAgICAgICAgICBzLnZhbHVlID0gJyc7CiAgICAgICAgICAgICAg
ICBzLmNsYXNzTGlzdC5yZW1vdmUoJ2hhcy12YWwnKTsKICAgICAgICAgICAgICAgIHRyeSB7IHMu
Ymx1cigpOyB9IGNhdGNoIHt9CiAgICAgICAgICAgIH0KICAgICAgICAgICAgY29uc3Qgc2NsciA9
IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzZWFyY2gtY2xyJyk7CiAgICAgICAgICAgIGlmIChz
Y2xyKSBzY2xyLnN0eWxlLmRpc3BsYXkgPSAnbm9uZSc7CiAgICAgICAgICAgIGNvbnN0IHdyYXAg
PSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc2VhcmNoLXdyYXAnKTsKICAgICAgICAgICAgaWYg
KHdyYXApIHdyYXAuY2xhc3NMaXN0LnJlbW92ZSgnb3BlbicpOwogICAgICAgICAgICB0cnkgeyBy
ZW5kZXIoKTsgfSBjYXRjaCB7fQogICAgICAgIH0gY2F0Y2gge30KICAgIH07CiAgICAvLyBDYXB0
dXJlIEN0cmwrRiBpbnNpZGUgV2ViVmlldyAoQ2hyb21pdW0gZmluZCBpcyBkaXNhYmxlZCwgYnV0
IHN0aWxsIGhhbmRsZSBoZXJlKQogICAgZG9jdW1lbnQuYWRkRXZlbnRMaXN0ZW5lcigna2V5ZG93
bicsIGUgPT4gewogICAgICAgIGlmICgoZS5jdHJsS2V5IHx8IGUubWV0YUtleSkgJiYgIWUuYWx0
S2V5ICYmIChlLmtleSA9PT0gJ2YnIHx8IGUua2V5ID09PSAnRicpKSB7CiAgICAgICAgICAgIGUu
cHJldmVudERlZmF1bHQoKTsKICAgICAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAg
ICAgICAgb3BlblNlYXJjaCgpOwogICAgICAgIH0KICAgIH0sIHRydWUpOwogICAgYnRuU2VhcmNo
LmFkZEV2ZW50TGlzdGVuZXIoJ2NsaWNrJywgZSA9PiB7CiAgICAgICAgZS5zdG9wUHJvcGFnYXRp
b24oKTsKICAgICAgICBvcGVuU2VhcmNoKCk7CiAgICB9KTsKICAgIGxldCBfX3NyY2hDb21wb3Np
bmcgPSBmYWxzZTsKICAgIGNvbnN0IF9fZmx1c2hTZWFyY2hJbnB1dCA9ICgpID0+IHsKICAgICAg
ICBxdWVyeSA9IHNyY2gudmFsdWU7CiAgICAgICAgc3JjaC5jbGFzc0xpc3QudG9nZ2xlKCdoYXMt
dmFsJywgISFxdWVyeSk7CiAgICAgICAgc2Nsci5zdHlsZS5kaXNwbGF5ID0gcXVlcnkgPyAnYmxv
Y2snIDogJ25vbmUnOwogICAgICAgIGxpc3RFbC5zY3JvbGxUb3AgPSAwOwogICAgICAgIHdpbmRv
dy5fX2hvc3RGaWx0ZXJlZCA9IGZhbHNlOwogICAgICAgIHdpbmRvdy5fX2hvc3RGaWx0ZXJRID0g
Jyc7CiAgICAgICAgdHJ5IHsgcmVuZGVyKCk7IH0gY2F0Y2gge30KICAgICAgICBjbGVhclRpbWVv
dXQoZGViKTsKICAgICAgICBkZWIgPSBzZXRUaW1lb3V0KHJlcXVlc3RWaWV3LCA4MCk7CiAgICB9
OwogICAgc3JjaC5hZGRFdmVudExpc3RlbmVyKCdjb21wb3NpdGlvbnN0YXJ0JywgKCkgPT4geyBf
X3NyY2hDb21wb3NpbmcgPSB0cnVlOyB9KTsKICAgIHNyY2guYWRkRXZlbnRMaXN0ZW5lcignY29t
cG9zaXRpb25lbmQnLCAoKSA9PiB7CiAgICAgICAgX19zcmNoQ29tcG9zaW5nID0gZmFsc2U7CiAg
ICAgICAgX19mbHVzaFNlYXJjaElucHV0KCk7CiAgICB9KTsKICAgIHNyY2guYWRkRXZlbnRMaXN0
ZW5lcignaW5wdXQnLCAoKSA9PiB7CiAgICAgICAgaWYgKF9fc3JjaENvbXBvc2luZykgewogICAg
ICAgICAgICBxdWVyeSA9IHNyY2gudmFsdWU7CiAgICAgICAgICAgIHNyY2guY2xhc3NMaXN0LnRv
Z2dsZSgnaGFzLXZhbCcsICEhcXVlcnkpOwogICAgICAgICAgICBzY2xyLnN0eWxlLmRpc3BsYXkg
PSBxdWVyeSA/ICdibG9jaycgOiAnbm9uZSc7CiAgICAgICAgICAgIHJldHVybjsKICAgICAgICB9
CiAgICAgICAgX19mbHVzaFNlYXJjaElucHV0KCk7CiAgICB9KTsKICAgIHNyY2guYWRkRXZlbnRM
aXN0ZW5lcignZm9jdXMnLCAoKSA9PiB7CiAgICAgICAgLy8gSWRlbXBvdGVudCBvbiBBSEsgc2lk
ZSDigJQgc2FmZSwgYnV0IGF2b2lkIHNwYW1taW5nIGR1cmluZyBJTUUKICAgICAgICB0cnkgeyBh
aGsoJ2ZvY3VzUGFuZWwnKTsgfSBjYXRjaCB7fQogICAgfSk7CiAgICBzcmNoLmFkZEV2ZW50TGlz
dGVuZXIoJ2JsdXInLCAoKSA9PiB7CiAgICAgICAgc2V0VGltZW91dCgoKSA9PiB7CiAgICAgICAg
ICAgIGlmIChkb2N1bWVudC5hY3RpdmVFbGVtZW50ID09PSBzcmNoKSByZXR1cm47CiAgICAgICAg
ICAgIGlmIChkb2N1bWVudC5hY3RpdmVFbGVtZW50ID09PSBzY2xyIHx8IChzY2xyICYmIHNjbHIu
Y29udGFpbnMoZG9jdW1lbnQuYWN0aXZlRWxlbWVudCkpKSByZXR1cm47CiAgICAgICAgICAgIGlm
IChkb2N1bWVudC5hY3RpdmVFbGVtZW50ID09PSBidG5Ub2RheSB8fCAoYnRuVG9kYXkgJiYgYnRu
VG9kYXkuY29udGFpbnMoZG9jdW1lbnQuYWN0aXZlRWxlbWVudCkpKSByZXR1cm47CiAgICAgICAg
ICAgIC8vIElNRSBjYW5kaWRhdGUgVUkgc3RlYWxzIGZvY3VzIGJyaWVmbHkg4oCUIGtlZXAgc2Vh
cmNoIGlmIHN0aWxsIGNvbXBvc2luZwogICAgICAgICAgICBpZiAoX19zcmNoQ29tcG9zaW5nKSBy
ZXR1cm47CiAgICAgICAgICAgIGNsb3NlU2VhcmNoVWkoKTsKICAgICAgICAgICAgYWhrKCdibHVy
UGFuZWwnKTsKICAgICAgICB9LCAyODApOwogICAgfSk7CiAgICBzcmNoLmFkZEV2ZW50TGlzdGVu
ZXIoJ2tleWRvd24nLCBlID0+IHsKICAgICAgICAvLyBDdHJsK0kgLyBDdHJsK0s6IG1vdmUgY2xp
cCBzZWxlY3Rpb24gKG5vdCBpbnNlcnQgY2hhciAvIGJyb3dzZXIgc2hvcnRjdXQpCiAgICAgICAg
aWYgKChlLmN0cmxLZXkgfHwgZS5tZXRhS2V5KSAmJiAoZS5rZXkgPT09ICdpJyB8fCBlLmtleSA9
PT0gJ0knKSkgewogICAgICAgICAgICBlLnByZXZlbnREZWZhdWx0KCk7CiAgICAgICAgICAgIGUu
c3RvcFByb3BhZ2F0aW9uKCk7CiAgICAgICAgICAgIHdpbmRvdy5fX25hdiAmJiB3aW5kb3cuX19u
YXYoJ3VwJyk7CiAgICAgICAgICAgIHJldHVybjsKICAgICAgICB9CiAgICAgICAgaWYgKChlLmN0
cmxLZXkgfHwgZS5tZXRhS2V5KSAmJiAoZS5rZXkgPT09ICdrJyB8fCBlLmtleSA9PT0gJ0snKSkg
ewogICAgICAgICAgICBlLnByZXZlbnREZWZhdWx0KCk7CiAgICAgICAgICAgIGUuc3RvcFByb3Bh
Z2F0aW9uKCk7CiAgICAgICAgICAgIHdpbmRvdy5fX25hdiAmJiB3aW5kb3cuX19uYXYoJ2Rvd24n
KTsKICAgICAgICAgICAgcmV0dXJuOwogICAgICAgIH0KICAgICAgICBpZiAoZS5rZXkgPT09ICdB
cnJvd0Rvd24nKSB7CiAgICAgICAgICAgIGUucHJldmVudERlZmF1bHQoKTsKICAgICAgICAgICAg
ZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICAgICAgd2luZG93Ll9fbmF2ICYmIHdpbmRvdy5f
X25hdignZG93bicpOwogICAgICAgICAgICByZXR1cm47CiAgICAgICAgfQogICAgICAgIGlmIChl
LmtleSA9PT0gJ0Fycm93VXAnKSB7CiAgICAgICAgICAgIGUucHJldmVudERlZmF1bHQoKTsKICAg
ICAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICAgICAgd2luZG93Ll9fbmF2ICYm
IHdpbmRvdy5fX25hdigndXAnKTsKICAgICAgICAgICAgcmV0dXJuOwogICAgICAgIH0KICAgICAg
ICBpZiAoZS5rZXkgPT09ICdFc2NhcGUnKSB7CiAgICAgICAgICAgIGUucHJldmVudERlZmF1bHQo
KTsKICAgICAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICAgICAgLy8gQWx3YXlz
IGRpc21pc3MgdGhlIHdob2xlIHBhbmVsIChub3QganVzdCB0aGUgc2VhcmNoIGZpZWxkKQogICAg
ICAgICAgICBpZiAoIXBpbm5lZFVJKSBhaGsoJ2hpZGUnKTsKICAgICAgICAgICAgcmV0dXJuOwog
ICAgICAgIH0KICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgfSk7CiAgICBzY2xyLmFk
ZEV2ZW50TGlzdGVuZXIoJ2NsaWNrJywgZSA9PiB7CiAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24o
KTsKICAgICAgICBzcmNoLnZhbHVlID0gcXVlcnkgPSAnJzsKICAgICAgICBzY2xyLnN0eWxlLmRp
c3BsYXkgPSAnbm9uZSc7CiAgICAgICAgc3JjaC5jbGFzc0xpc3QucmVtb3ZlKCdoYXMtdmFsJyk7
CiAgICAgICAgcmVxdWVzdFZpZXcoKTsKICAgICAgICBhaGsoJ2ZvY3VzUGFuZWwnKTsKICAgICAg
ICBzcmNoLmZvY3VzKCk7CiAgICB9KTsKCiAgICBjb25zdCBUQUJfTkFNRVMgPSB7IGFsbDogJ+WF
qOmDqCcsIHRleHQ6ICfmlofmnKwnLCBpbWFnZTogJ+WbvuWDjycsIGZpbGU6ICfmlofku7YnLCBy
ZWNlbnQ6ICfmnIDov5EnLCBwaW5uZWQ6ICfmlLbol48nIH07CiAgICBjb25zdCBjbHJEbGcgPSBk
b2N1bWVudC5nZXRFbGVtZW50QnlJZCgnY2xyLWRsZycpOwogICAgY29uc3QgY2xyQWxsQ2IgPSBk
b2N1bWVudC5nZXRFbGVtZW50QnlJZCgnY2xyLWFsbCcpOwogICAgZnVuY3Rpb24gb3BlbkNsZWFy
RGxnKCkgewogICAgICAgIGNvbnN0IG5hbWUgPSBUQUJfTkFNRVNbY3VyVGFiXSB8fCAn5b2T5YmN
JzsKICAgICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnY2xyLXRpdGxlJykudGV4dENvbnRl
bnQgPSAn5riF56m644CMJyArIG5hbWUgKyAn44CN77yfJzsKICAgICAgICBkb2N1bWVudC5nZXRF
bGVtZW50QnlJZCgnY2xyLWRlc2MnKS50ZXh0Q29udGVudCA9IGN1clRhYiA9PT0gJ3Bpbm5lZCcK
ICAgICAgICAgICAgPyAn6buY6K6k5LuF5riF56m65b2T5aSp55qE5pS26JeP6aG544CC5Yu+6YCJ
44CM5riF56m65omA5pyJ44CN5Y+v5riF6Zmk6K+l6YCJ6aG55Y2h5YWo6YOo5YaF5a6544CCJwog
ICAgICAgICAgICA6IChjdXJUYWIgPT09ICdyZWNlbnQnCiAgICAgICAgICAgICAgICA/ICfmuIXn
qbrjgIzmnIDov5HjgI3kvJrliKDpmaTmnKrlm7rlrprnmoTmnIDov5Hnm67lvZXorrDlvZXvvJvl
t7Llm7rlrprnmoTnm67lvZXkvJrkv53nlZnjgIInCiAgICAgICAgICAgICAgICA6ICfku4XmuIXn
qbrlvZPliY3pgInpobnljaHjgILpu5jorqTlj6rmuIXlvZPlpKnvvJvmlLbol4/pobnkuI3kvJro
oqvmuIXpmaTjgILli77pgInjgIzmuIXnqbrmiYDmnInjgI3lj6/muIXpmaTor6XpgInpobnljaHl
hajpg6jml6XmnJ/jgIInKTsKICAgICAgICBjbHJBbGxDYi5jaGVja2VkID0gZmFsc2U7CiAgICAg
ICAgY2xyRGxnLmNsYXNzTGlzdC5hZGQoJ29uJyk7CiAgICB9CiAgICBmdW5jdGlvbiBjbG9zZUNs
ZWFyRGxnKCkgewogICAgICAgIGNsckRsZy5jbGFzc0xpc3QucmVtb3ZlKCdvbicpOwogICAgfQog
ICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2J0bi1jbHInKS5hZGRFdmVudExpc3RlbmVyKCdj
bGljaycsIGUgPT4gewogICAgICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAgICAgb3BlbkNs
ZWFyRGxnKCk7CiAgICB9KTsKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjbHItY2FuY2Vs
JykuYWRkRXZlbnRMaXN0ZW5lcignY2xpY2snLCBlID0+IHsKICAgICAgICBlLnN0b3BQcm9wYWdh
dGlvbigpOwogICAgICAgIGNsb3NlQ2xlYXJEbGcoKTsKICAgIH0pOwogICAgY2xyRGxnLmFkZEV2
ZW50TGlzdGVuZXIoJ2NsaWNrJywgZSA9PiB7CiAgICAgICAgaWYgKGUudGFyZ2V0ID09PSBjbHJE
bGcpIGNsb3NlQ2xlYXJEbGcoKTsKICAgIH0pOwogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQo
J2Nsci1vaycpLmFkZEV2ZW50TGlzdGVuZXIoJ2NsaWNrJywgZSA9PiB7CiAgICAgICAgZS5zdG9w
UHJvcGFnYXRpb24oKTsKICAgICAgICBjb25zdCBzY29wZSA9IChjdXJUYWIgPT09ICdyZWNlbnQn
KSA/ICdhbGwnIDogKGNsckFsbENiLmNoZWNrZWQgPyAnYWxsJyA6ICd0b2RheScpOwogICAgICAg
IGNsb3NlQ2xlYXJEbGcoKTsKICAgICAgICBhaGsoJ2NsZWFyJywgY3VyVGFiLCBzY29wZSk7CiAg
ICB9KTsKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdtdWx0aS1zZWwnKS5hZGRFdmVudExp
c3RlbmVyKCdjbGljaycsIGUgPT4gewogICAgICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAg
ICAgY2xlYXJNdWx0aSh0cnVlKTsKICAgIH0pOwogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQo
J2J0bi1waW4nKS5hZGRFdmVudExpc3RlbmVyKCdjbGljaycsIGUgPT4gewogICAgICAgIGUuc3Rv
cFByb3BhZ2F0aW9uKCk7CiAgICAgICAgcGlubmVkVUkgPSAhcGlubmVkVUk7CiAgICAgICAgZS5j
dXJyZW50VGFyZ2V0LmNsYXNzTGlzdC50b2dnbGUoJ29uJywgcGlubmVkVUkpOwogICAgICAgIGFo
aygndG9nZ2xlUGluJywgcGlubmVkVUkgPyAnMScgOiAnMCcpOwogICAgfSk7CgogICAgd2luZG93
Ll9fcGVyZk1hcmsgPSAoc3RhZ2UpID0+IHsKICAgICAgICB0cnkgewogICAgICAgICAgICBpZiAo
d2luZG93LmNocm9tZSAmJiBjaHJvbWUud2VidmlldyAmJiBjaHJvbWUud2Vidmlldy5wb3N0TWVz
c2FnZSkKICAgICAgICAgICAgICAgIGNocm9tZS53ZWJ2aWV3LnBvc3RNZXNzYWdlKCdwZXJmfCcg
KyBTdHJpbmcoc3RhZ2UgfHwgJycpKTsKICAgICAgICB9IGNhdGNoIHt9CiAgICB9OwoKICAgIHdp
bmRvdy5fX3VwZGF0ZUNsaXBzID0gcGF5bG9hZCA9PiB7CiAgICAgICAgY29uc3QgdDAgPSAodHlw
ZW9mIHBlcmZvcm1hbmNlICE9PSAndW5kZWZpbmVkJyAmJiBwZXJmb3JtYW5jZS5ub3cpID8gcGVy
Zm9ybWFuY2Uubm93KCkgOiBEYXRlLm5vdygpOwogICAgICAgIHdpbmRvdy5fX3BlcmZNYXJrKCdq
c191cGRhdGVDbGlwc19lbnRlciBuPScgKyAocGF5bG9hZCAmJiBwYXlsb2FkLml0ZW1zID8gcGF5
bG9hZC5pdGVtcy5sZW5ndGggOiAoQXJyYXkuaXNBcnJheShwYXlsb2FkKSA/IHBheWxvYWQubGVu
Z3RoIDogMCkpKTsKICAgICAgICAvLyBLZWVwIHByZXZpb3VzIHNjcm9sbCBmb3IgbG9hZC1tb3Jl
OyByZXNldCB3aGVuIG9wZW5pbmcgcGFuZWwgdG8gZmlyc3QgaXRlbQogICAgICAgIGNvbnN0IGtl
ZXBTY3JvbGwgPSAhc2VsZWN0Rmlyc3RPblNob3c7CiAgICAgICAgY29uc3Qgc3QgPSBsaXN0RWwu
c2Nyb2xsVG9wOwogICAgICAgIHdpbmRvdy5fX3dhaXRpbmdWaWV3ID0gZmFsc2U7CiAgICAgICAg
Y29uc3Qgd2FzQXBwZW5kID0gcGF5bG9hZCAmJiBwYXlsb2FkLmFwcGVuZDsKICAgICAgICBsb2Fk
aW5nTW9yZSA9IGZhbHNlOwogICAgICAgIGNvbnN0IHByZXZJdGVtcyA9IGFsbENsaXBzOwogICAg
ICAgIGxldCBuZXh0SXRlbXMgPSBbXTsKICAgICAgICBsZXQgbmV4dFRvdGFsID0gMDsKICAgICAg
ICBsZXQgbmV4dEZpbHRlcmVkID0gZmFsc2U7CiAgICAgICAgbGV0IHBUYWIgPSAnJzsKICAgICAg
ICBsZXQgcFBpbm5lZFRvdGFsID0gLTE7CiAgICAgICAgaWYgKEFycmF5LmlzQXJyYXkocGF5bG9h
ZCkpIHsKICAgICAgICAgICAgbmV4dEl0ZW1zID0gcGF5bG9hZDsKICAgICAgICAgICAgbmV4dFRv
dGFsID0gcGF5bG9hZC5sZW5ndGg7CiAgICAgICAgICAgIG5leHRGaWx0ZXJlZCA9IGZhbHNlOwog
ICAgICAgIH0gZWxzZSBpZiAocGF5bG9hZCAmJiB0eXBlb2YgcGF5bG9hZCA9PT0gJ29iamVjdCcp
IHsKICAgICAgICAgICAgbmV4dFRvdGFsID0gTnVtYmVyKHBheWxvYWQudG90YWwpIHx8IDA7CiAg
ICAgICAgICAgIG5leHRJdGVtcyA9IEFycmF5LmlzQXJyYXkocGF5bG9hZC5pdGVtcykgPyBwYXls
b2FkLml0ZW1zIDogW107CiAgICAgICAgICAgIHBUYWIgPSBwYXlsb2FkLnRhYiAhPSBudWxsID8g
U3RyaW5nKHBheWxvYWQudGFiKSA6ICcnOwogICAgICAgICAgICBpZiAocGF5bG9hZC5waW5uZWRU
b3RhbCAhPSBudWxsICYmIHBheWxvYWQucGlubmVkVG90YWwgIT09ICcnKQogICAgICAgICAgICAg
ICAgcFBpbm5lZFRvdGFsID0gTnVtYmVyKHBheWxvYWQucGlubmVkVG90YWwpIHx8IDA7CiAgICAg
ICAgICAgIGNvbnN0IHBxMCA9IHBheWxvYWQucXVlcnkgIT0gbnVsbCA/IFN0cmluZyhwYXlsb2Fk
LnF1ZXJ5KSA6ICcnOwogICAgICAgICAgICBuZXh0RmlsdGVyZWQgPSAhIShwYXlsb2FkLmZpbHRl
cmVkIHx8IChwcTAgJiYgcHEwLnRyaW0oKSkpOwogICAgICAgICAgICBpZiAocGF5bG9hZC5hcHBl
bmQpIHsKICAgICAgICAgICAgICAgIC8vIEFwcGVuZCBvbmx5IGFwcGxpZXMgdG8gdGhlIHRhYiB3
ZSdyZSBjdXJyZW50bHkgdmlld2luZwogICAgICAgICAgICAgICAgaWYgKHBUYWIgJiYgcFRhYiAh
PT0gY3VyVGFiKQogICAgICAgICAgICAgICAgICAgIHJldHVybjsKICAgICAgICAgICAgICAgIGNv
bnN0IHNlZW4gPSBuZXcgU2V0KGFsbENsaXBzLm1hcChjID0+ICtjLmlkKSk7CiAgICAgICAgICAg
ICAgICBjb25zdCBtZXJnZWQgPSBhbGxDbGlwcy5zbGljZSgpOwogICAgICAgICAgICAgICAgbmV4
dEl0ZW1zLmZvckVhY2goaXQgPT4gewogICAgICAgICAgICAgICAgICAgIGlmICghc2Vlbi5oYXMo
K2l0LmlkKSkgbWVyZ2VkLnB1c2goaXQpOwogICAgICAgICAgICAgICAgfSk7CiAgICAgICAgICAg
ICAgICBuZXh0SXRlbXMgPSBtZXJnZWQ7CiAgICAgICAgICAgICAgICBuZXh0VG90YWwgPSBNYXRo
Lm1heChuZXh0VG90YWwsIG5leHRJdGVtcy5sZW5ndGgpOwogICAgICAgICAgICB9CiAgICAgICAg
ICAgIC8vIOaQnOe0ouahhuS7peaJk+Wtl+mVnOWDj+S4uuWHhu+8jOe7neS4jeiiq+a7nuWQjuea
hOejgeebmOe7k+aenOWGmeWbnuaXp+WFs+mUruWtlwogICAgICAgICAgICB0cnkgewogICAgICAg
ICAgICAgICAgY29uc3QgcyA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzZWFyY2gnKTsKICAg
ICAgICAgICAgICAgIGlmIChzICYmIFN0cmluZyhzLnZhbHVlIHx8ICcnKS5sZW5ndGgpCiAgICAg
ICAgICAgICAgICAgICAgcXVlcnkgPSBzLnZhbHVlOwogICAgICAgICAgICAgICAgZWxzZSBpZiAo
cHEwICE9PSAnJyAmJiAhU3RyaW5nKHF1ZXJ5IHx8ICcnKS50cmltKCkpCiAgICAgICAgICAgICAg
ICAgICAgcXVlcnkgPSBwcTA7CiAgICAgICAgICAgIH0gY2F0Y2gge30KICAgICAgICB9IGVsc2Ug
ewogICAgICAgICAgICBuZXh0SXRlbXMgPSBbXTsKICAgICAgICAgICAgbmV4dFRvdGFsID0gMDsK
ICAgICAgICAgICAgbmV4dEZpbHRlcmVkID0gZmFsc2U7CiAgICAgICAgfQoKICAgICAgICBjb25z
dCBib3hRID0gU3RyaW5nKHF1ZXJ5IHx8ICcnKS50cmltKCk7CiAgICAgICAgY29uc3QgcHVzaFEg
PSAocGF5bG9hZCAmJiB0eXBlb2YgcGF5bG9hZCA9PT0gJ29iamVjdCcgJiYgcGF5bG9hZC5xdWVy
eSAhPSBudWxsKQogICAgICAgICAgICA/IFN0cmluZyhwYXlsb2FkLnF1ZXJ5KS50cmltKCkgOiAn
JzsKCiAgICAgICAgLy8gQWx3YXlzIHJlZnJlc2gg5pS26JePIGJhZGdlIGZyb20gaG9zdCB3aGVu
IHByb3ZpZGVkCiAgICAgICAgaWYgKHBQaW5uZWRUb3RhbCA+PSAwKQogICAgICAgICAgICBwaW5u
ZWRUb3RhbCA9IHBQaW5uZWRUb3RhbDsKCiAgICAgICAgLy8gU3RhbGUgc2VhcmNoIHB1c2ggKGUu
Zy4gInNxdWFyZSBsb2dpIiBsYW5kcyBhZnRlciB1c2VyIHR5cGVkICJzcXVhcmUgbG9naW4iKSDi
gJRjYWNoZSBvbmx5CiAgICAgICAgaWYgKCF3YXNBcHBlbmQgJiYgbmV4dEZpbHRlcmVkICYmIHB1
c2hRICYmIGJveFEgJiYgcHVzaFEgIT09IGJveFEpIHsKICAgICAgICAgICAgdmlld01lbS5zZXQo
dmlld01lbUtleShwVGFiIHx8IGN1clRhYiwgcHVzaFEsIHRvZGF5T25seSksIHsKICAgICAgICAg
ICAgICAgIGl0ZW1zOiBuZXh0SXRlbXMuc2xpY2UoKSwKICAgICAgICAgICAgICAgIHRvdGFsOiBu
ZXh0VG90YWwKICAgICAgICAgICAgfSk7CiAgICAgICAgICAgIHJldHVybjsKICAgICAgICB9Cgog
ICAgICAgIC8vIFN0YWxlIHB1c2ggZm9yIGFub3RoZXIgdGFiOiBvbmx5IHJlZnJlc2ggdGhhdCB0
YWIncyB2aWV3TWVtLCBkb24ndCBoaWphY2sgVUkKICAgICAgICBpZiAoIXdhc0FwcGVuZCAmJiBw
VGFiICYmIHBUYWIgIT09IGN1clRhYikgewogICAgICAgICAgICBjb25zdCBtZW1RID0gKHBheWxv
YWQgJiYgdHlwZW9mIHBheWxvYWQgPT09ICdvYmplY3QnICYmIHBheWxvYWQucXVlcnkgIT0gbnVs
bCkKICAgICAgICAgICAgICAgID8gU3RyaW5nKHBheWxvYWQucXVlcnkpIDogJyc7CiAgICAgICAg
ICAgIHZpZXdNZW0uc2V0KHZpZXdNZW1LZXkocFRhYiwgbWVtUSwgdG9kYXlPbmx5KSwgewogICAg
ICAgICAgICAgICAgaXRlbXM6IG5leHRJdGVtcy5zbGljZSgpLAogICAgICAgICAgICAgICAgdG90
YWw6IG5leHRUb3RhbAogICAgICAgICAgICB9KTsKICAgICAgICAgICAgLy8gU3RpbGwgdXBkYXRl
IHBpbiBiYWRnZSBpZiBob3N0IHNlbnQgaXQKICAgICAgICAgICAgdHJ5IHsgdXBkYXRlUGluRG90
KCk7IH0gY2F0Y2gge30KICAgICAgICAgICAgLy8gUVEg5pCc57Si5pu+5Zu65a6a5o6oIGFsbCB0
YWIg4oaSIOW9k+WJjSB0YWIg5Lya5LiA55u06aqo5p6277yb6KGl5LiA5qyhIHJlcXVlc3RWaWV3
CiAgICAgICAgICAgIGlmICh3YWl0aW5nRGF0YSAmJiBwdXNoUSA9PT0gYm94USkgewogICAgICAg
ICAgICAgICAgc2V0VGltZW91dCgoKSA9PiB7CiAgICAgICAgICAgICAgICAgICAgaWYgKHdhaXRp
bmdEYXRhICYmIGN1clRhYiAhPT0gcFRhYikKICAgICAgICAgICAgICAgICAgICAgICAgcmVxdWVz
dFZpZXcoKTsKICAgICAgICAgICAgICAgIH0sIDQwKTsKICAgICAgICAgICAgfQogICAgICAgICAg
ICByZXR1cm47CiAgICAgICAgfQoKICAgICAgICAvLyBCb290c3RyYXAgcmFjZTogQUhLIHB1c2hl
ZCBlbXB0eSBiZWZvcmUgV2FybUFsbFZpZXdzIOKAlGtlZXAgc2tlbGV0b24sIGlnbm9yZQogICAg
ICAgIGNvbnN0IHFPbiA9IFN0cmluZyhxdWVyeSB8fCAnJykudHJpbSgpLmxlbmd0aCA+IDA7CiAg
ICAgICAgaWYgKCF3YXNBcHBlbmQgJiYgIW5leHRJdGVtcy5sZW5ndGggJiYgbmV4dFRvdGFsIDw9
IDAgJiYgIXFPbiAmJiAhbmV4dEZpbHRlcmVkICYmICFzYXdOb25FbXB0eSkgewogICAgICAgICAg
ICBpZiAoIXdpbmRvdy5fX2VtcHR5RmFsbGJhY2tUKSB7CiAgICAgICAgICAgICAgICB3aW5kb3cu
X19lbXB0eUZhbGxiYWNrVCA9IHNldFRpbWVvdXQoKCkgPT4gewogICAgICAgICAgICAgICAgICAg
IHdpbmRvdy5fX2VtcHR5RmFsbGJhY2tUID0gMDsKICAgICAgICAgICAgICAgICAgICBpZiAoc2F3
Tm9uRW1wdHkpIHJldHVybjsKICAgICAgICAgICAgICAgICAgICAvLyBUcnVseSBlbXB0eSBpbnN0
YWxsIGFmdGVyIHdhaXQKICAgICAgICAgICAgICAgICAgICBzYXdOb25FbXB0eSA9IHRydWU7CiAg
ICAgICAgICAgICAgICAgICAgaG9zdFB1c2hlZE9uY2UgPSB0cnVlOwogICAgICAgICAgICAgICAg
ICAgIHdpbmRvdy5fX2RhdGFSZWFkeSA9IHRydWU7CiAgICAgICAgICAgICAgICAgICAgYWxsQ2xp
cHMgPSBbXTsKICAgICAgICAgICAgICAgICAgICBkaXNrVG90YWwgPSAwOwogICAgICAgICAgICAg
ICAgICAgIGNsZWFyV2FpdGluZ0RhdGEoKTsKICAgICAgICAgICAgICAgICAgICB0cnkgeyByZW5k
ZXIoKTsgfSBjYXRjaCB7fQogICAgICAgICAgICAgICAgfSwgNDUwMCk7CiAgICAgICAgICAgIH0K
ICAgICAgICAgICAgd2FpdGluZ0RhdGEgPSB0cnVlOwogICAgICAgICAgICB3aW5kb3cuX19kYXRh
UmVhZHkgPSBmYWxzZTsKICAgICAgICAgICAgaG9zdFB1c2hlZE9uY2UgPSBmYWxzZTsKICAgICAg
ICAgICAgc2V0Qm9vdExvYWRpbmcodHJ1ZSk7CiAgICAgICAgICAgIHRyeSB7IHJlbmRlcigpOyB9
IGNhdGNoIHt9CiAgICAgICAgICAgIHJldHVybjsKICAgICAgICB9CgogICAgICAgIGNsZWFyV2Fp
dGluZ0RhdGEoKTsKICAgICAgICBhbGxDbGlwcyA9IG5leHRJdGVtczsKICAgICAgICBkaXNrVG90
YWwgPSBuZXh0VG90YWw7CiAgICAgICAgLy8gS2VlcCBiYXIgY29uc2lzdGVudCBpZiBsaXN0IGdy
ZXcgcGFzdCBhIHN0YWxlIHRvdGFsCiAgICAgICAgaWYgKGFsbENsaXBzLmxlbmd0aCA+IGRpc2tU
b3RhbCkKICAgICAgICAgICAgZGlza1RvdGFsID0gYWxsQ2xpcHMubGVuZ3RoOwogICAgICAgIHdp
bmRvdy5fX2hvc3RGaWx0ZXJlZCA9IG5leHRGaWx0ZXJlZDsKICAgICAgICB3aW5kb3cuX19ob3N0
RmlsdGVyUSA9IChuZXh0RmlsdGVyZWQgJiYgcHVzaFEpID8gcHVzaFEgOiAnJzsKICAgICAgICAv
LyBGaWx0ZXJlZCBzZWFyY2ggd2l0aCAwIGhpdHMg4oCUbXVzdCBsZWF2ZSBza2VsZXRvbiAoaG9z
dCBkaWQgcmVzcG9uZCkKICAgICAgICBpZiAoIXdhc0FwcGVuZCAmJiBuZXh0RmlsdGVyZWQgJiYg
IWFsbENsaXBzLmxlbmd0aCAmJiBkaXNrVG90YWwgPD0gMCkgewogICAgICAgICAgICBob3N0UHVz
aGVkT25jZSA9IHRydWU7CiAgICAgICAgICAgIHNhd05vbkVtcHR5ID0gdHJ1ZTsKICAgICAgICB9
CiAgICAgICAgaWYgKGFsbENsaXBzLmxlbmd0aCB8fCBkaXNrVG90YWwgPiAwKQogICAgICAgICAg
ICBzYXdOb25FbXB0eSA9IHRydWU7CiAgICAgICAgaWYgKHdpbmRvdy5fX2VtcHR5RmFsbGJhY2tU
KSB7CiAgICAgICAgICAgIGNsZWFyVGltZW91dCh3aW5kb3cuX19lbXB0eUZhbGxiYWNrVCk7CiAg
ICAgICAgICAgIHdpbmRvdy5fX2VtcHR5RmFsbGJhY2tUID0gMDsKICAgICAgICB9CiAgICAgICAg
aWYgKCF3YXNBcHBlbmQpIHsKICAgICAgICAgICAgY29uc3QgbWVtUSA9IChwYXlsb2FkICYmIHR5
cGVvZiBwYXlsb2FkID09PSAnb2JqZWN0JyAmJiBwYXlsb2FkLnF1ZXJ5ICE9IG51bGwpCiAgICAg
ICAgICAgICAgICA/IFN0cmluZyhwYXlsb2FkLnF1ZXJ5KSA6IHF1ZXJ5OwogICAgICAgICAgICB2
aWV3TWVtLnNldCh2aWV3TWVtS2V5KGN1clRhYiwgbWVtUSwgdG9kYXlPbmx5KSwgewogICAgICAg
ICAgICAgICAgaXRlbXM6IGFsbENsaXBzLnNsaWNlKCksCiAgICAgICAgICAgICAgICB0b3RhbDog
ZGlza1RvdGFsCiAgICAgICAgICAgIH0pOwogICAgICAgIH0KICAgICAgICB3aW5kb3cuX19kYXRh
UmVhZHkgPSB0cnVlOwogICAgICAgIGhvc3RQdXNoZWRPbmNlID0gdHJ1ZTsKCiAgICAgICAgLy8g
TWlkLXdoZWVsOiBrZWVwIGRhdGEsIGRlbGF5IERPTSBzbyBzY3JvbGwvZHJhZyBuZXZlciBoaXRj
aCBvbiBhcHBlbmQgcGFpbnQKICAgICAgICBpZiAod2FzQXBwZW5kICYmIHdpbmRvdy5fX3Njcm9s
bEJ1c3kgJiYgIXdpbmRvdy5fX3BlbmRpbmdKdW1wSWQpIHsKICAgICAgICAgICAgY29uc3QgZnJv
bUxlbiA9IChwcmV2SXRlbXMgJiYgcHJldkl0ZW1zLmxlbmd0aCkgPyBwcmV2SXRlbXMubGVuZ3Ro
IDogMDsKICAgICAgICAgICAgaWYgKCFfcGVuZGluZ0FwcGVuZCkKICAgICAgICAgICAgICAgIF9w
ZW5kaW5nQXBwZW5kID0geyBmcm9tTGVuOiBmcm9tTGVuIH07CiAgICAgICAgICAgIHRyeSB7IHJl
ZnJlc2hMaXN0Q2hyb21lKCk7IH0gY2F0Y2gge30KICAgICAgICAgICAgcmV0dXJuOwogICAgICAg
IH0KCiAgICAgICAgY29uc3Qgd2FzQm9vdExvYWRpbmcgPSBib290TG9hZGluZzsKICAgICAgICBs
ZXQgc2FtZVBhaW50ID0gZmFsc2U7CiAgICAgICAgY29uc3QgcHJldkxlbiA9IChwcmV2SXRlbXMg
JiYgcHJldkl0ZW1zLmxlbmd0aCkgPyBwcmV2SXRlbXMubGVuZ3RoIDogMDsKICAgICAgICBpZiAo
IXdhc0FwcGVuZCAmJiAhd2FzQm9vdExvYWRpbmcgJiYgcHJldkl0ZW1zICYmIHByZXZJdGVtcy5s
ZW5ndGggPT09IGFsbENsaXBzLmxlbmd0aCAmJiBwcmV2SXRlbXMubGVuZ3RoKSB7CiAgICAgICAg
ICAgIHNhbWVQYWludCA9IHRydWU7CiAgICAgICAgICAgIGZvciAobGV0IGkgPSAwOyBpIDwgYWxs
Q2xpcHMubGVuZ3RoOyBpKyspIHsKICAgICAgICAgICAgICAgIGlmICgrcHJldkl0ZW1zW2ldLmlk
ICE9PSArYWxsQ2xpcHNbaV0uaWQpIHsgc2FtZVBhaW50ID0gZmFsc2U7IGJyZWFrOyB9CiAgICAg
ICAgICAgIH0KICAgICAgICAgICAgaWYgKHNhbWVQYWludCAmJiAhbGlzdEVsLnF1ZXJ5U2VsZWN0
b3IoJy5pdG0nKSkgc2FtZVBhaW50ID0gZmFsc2U7CiAgICAgICAgfQogICAgICAgIGNvbnN0IGZp
bmlzaFVwZGF0ZSA9ICgpID0+IHsKICAgICAgICAgICAgY29uc3QgdFJlbmRlcjAgPSAodHlwZW9m
IHBlcmZvcm1hbmNlICE9PSAndW5kZWZpbmVkJyAmJiBwZXJmb3JtYW5jZS5ub3cpID8gcGVyZm9y
bWFuY2Uubm93KCkgOiBEYXRlLm5vdygpOwogICAgICAgICAgICBjbGVhcldhaXRpbmdEYXRhKCk7
CiAgICAgICAgICAgIGlmICh3YXNBcHBlbmQgJiYgIXdhc0Jvb3RMb2FkaW5nICYmIHByZXZMZW4g
PiAwICYmIGFsbENsaXBzLmxlbmd0aCA+IHByZXZMZW4pIHsKICAgICAgICAgICAgICAgIGFwcGVu
ZFJlbmRlcihwcmV2TGVuKTsKICAgICAgICAgICAgfSBlbHNlIGlmICghc2FtZVBhaW50KSB7CiAg
ICAgICAgICAgICAgICByZW5kZXIoKTsKICAgICAgICAgICAgICAgIGFwcGx5VGFiU3dpdGNoQW5p
bSgpOwogICAgICAgICAgICAgICAgaWYgKGtlZXBTY3JvbGwpCiAgICAgICAgICAgICAgICAgICAg
bGlzdEVsLnNjcm9sbFRvcCA9IHN0OwogICAgICAgICAgICAgICAgZWxzZQogICAgICAgICAgICAg
ICAgICAgIGxpc3RFbC5zY3JvbGxUb3AgPSAwOwogICAgICAgICAgICB9IGVsc2UgewogICAgICAg
ICAgICAgICAgdHJ5IHsgcmVmcmVzaExpc3RDaHJvbWUoKTsgfSBjYXRjaCB7fQogICAgICAgICAg
ICAgICAgaWYgKGtlZXBTY3JvbGwpCiAgICAgICAgICAgICAgICAgICAgbGlzdEVsLnNjcm9sbFRv
cCA9IHN0OwogICAgICAgICAgICB9CiAgICAgICAgICAgIGNvbnN0IHQxID0gKHR5cGVvZiBwZXJm
b3JtYW5jZSAhPT0gJ3VuZGVmaW5lZCcgJiYgcGVyZm9ybWFuY2Uubm93KSA/IHBlcmZvcm1hbmNl
Lm5vdygpIDogRGF0ZS5ub3coKTsKICAgICAgICAgICAgd2luZG93Ll9fcGVyZk1hcmsoJ2pzX3Vw
ZGF0ZUNsaXBzX2RvbmUgcmVuZGVyTXM9JyArIE1hdGgucm91bmQodDEgLSB0UmVuZGVyMCkgKyAn
IHRvdGFsTXM9JyArIE1hdGgucm91bmQodDEgLSB0MCkgKyAnIG49JyArIGFsbENsaXBzLmxlbmd0
aCk7CiAgICAgICAgfTsKICAgICAgICBpZiAod2FzQm9vdExvYWRpbmcpIHsKICAgICAgICAgICAg
Y29uc3Qgc2luY2UgPSB3aW5kb3cuX19za2VsU2luY2UgfHwgMDsKICAgICAgICAgICAgY29uc3Qg
d2FpdCA9IHNpbmNlID8gTWF0aC5tYXgoMCwgODAgLSAoRGF0ZS5ub3coKSAtIHNpbmNlKSkgOiAw
OwogICAgICAgICAgICBpZiAod2FpdCA+IDApCiAgICAgICAgICAgICAgICBzZXRUaW1lb3V0KGZp
bmlzaFVwZGF0ZSwgd2FpdCk7CiAgICAgICAgICAgIGVsc2UKICAgICAgICAgICAgICAgIGZpbmlz
aFVwZGF0ZSgpOwogICAgICAgIH0gZWxzZSB7CiAgICAgICAgICAgIGZpbmlzaFVwZGF0ZSgpOwog
ICAgICAgIH0KICAgIH07CiAgICB3aW5kb3cuX19zZXRQaW5uZWQgPSB2ID0+IHsKICAgICAgICBw
aW5uZWRVSSA9ICEhdjsKICAgICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYnRuLXBpbicp
LmNsYXNzTGlzdC50b2dnbGUoJ29uJywgcGlubmVkVUkpOwogICAgfTsKICAgIHdpbmRvdy5fX2xv
YWRNb3JlRG9uZSA9ICgpID0+IHsKICAgICAgICBsb2FkaW5nTW9yZSA9IGZhbHNlOwogICAgICAg
IGlmICh3aW5kb3cuX19sb2FkTW9yZVdhdGNoKSB7CiAgICAgICAgICAgIGNsZWFyVGltZW91dCh3
aW5kb3cuX19sb2FkTW9yZVdhdGNoKTsKICAgICAgICAgICAgd2luZG93Ll9fbG9hZE1vcmVXYXRj
aCA9IDA7CiAgICAgICAgfQogICAgICAgIGlmICh3aW5kb3cuX19wZW5kaW5nSnVtcElkKQogICAg
ICAgICAgICB0cnlDb250aW51ZUp1bXAoKTsKICAgIH07CgogICAgaW5pdFNlcFVpKCk7CiAgICB1
cGRhdGVQaW5Eb3QoKTsKICAgIHNjaGVkdWxlRGVsYXllZFNrZWwoKTsKICAgIHdpbmRvdy5fX3Bl
cmZNYXJrICYmIHdpbmRvdy5fX3BlcmZNYXJrKCdqc19ib290IHJlcXVlc3RWaWV3Jyk7CiAgICBy
ZXF1ZXN0VmlldygpOwogICAgLy8gc2NoZWR1bGVEZWxheWVkU2tlbCBhbHJlYWR5IHJlbmRlcigp
J2Qgd2hlbiBlbXB0eTsgc3RpbGwgcGFpbnQgb25jZSBmb3IgY2hyb21lCgogICAgPC9zY3JpcHQ+
CjwvYm9keT4KPC9odG1sPg==
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
    global prevActiveWin, guiWin, qqSearchOn
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

; Temporarily activate panel so search input can receive typing
FocusPanelForInput() {
    global guiWin, searchFocused, uiPinned
    searchFocused := true
    if !IsObject(guiWin)
        return
    ; Pinned panels must accept activation; NOACTIVATE blocks Ctrl+F / focus
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
