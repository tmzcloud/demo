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
UI_CACHE_VER := "20260919-rf-path-wrap2"
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
ICAgICAgZGlzcGxheTogYmxvY2s7CiAgICAgICAgICAgIHdpZHRoOiAxMDAlOwogICAgICAgICAg
ICBtYXgtd2lkdGg6IDEwMCU7CiAgICAgICAgICAgIGJveC1zaXppbmc6IGJvcmRlci1ib3g7CiAg
ICAgICAgICAgIGZvbnQtc2l6ZTogMTNweDsgZm9udC13ZWlnaHQ6IDYwMDsgY29sb3I6IHZhcigt
LXR4dCk7CiAgICAgICAgICAgIGxpbmUtaGVpZ2h0OiAxLjQ1OwogICAgICAgICAgICAvKiDlhYjp
k7rmu6HkuIDooYzlho3mlq3lrZfvvIzpgb/lhY3mlbTmrrXnm67lvZXlkI3mj5DliY3mipjliLDk
uIvkuIDooYwgKi8KICAgICAgICAgICAgd29yZC1icmVhazogYnJlYWstYWxsOwogICAgICAgICAg
ICBvdmVyZmxvdy13cmFwOiBhbnl3aGVyZTsKICAgICAgICAgICAgcG9zaXRpb246IHJlbGF0aXZl
OwogICAgICAgICAgICB6LWluZGV4OiA2OwogICAgICAgICAgICAtd2Via2l0LWFwcC1yZWdpb246
IG5vLWRyYWc7IGFwcC1yZWdpb246IG5vLWRyYWc7CiAgICAgICAgICAgIHBvaW50ZXItZXZlbnRz
OiBhdXRvOwogICAgICAgIH0KICAgICAgICAucmYtc2VnIHsKICAgICAgICAgICAgZGlzcGxheTog
aW5saW5lOwogICAgICAgICAgICBjb2xvcjogdmFyKC0tYWNjKTsKICAgICAgICAgICAgY3Vyc29y
OiBwb2ludGVyOwogICAgICAgICAgICBwYWRkaW5nOiAwIDFweDsKICAgICAgICAgICAgbWFyZ2lu
OiAwOwogICAgICAgICAgICBib3JkZXI6IG5vbmU7CiAgICAgICAgICAgIGJhY2tncm91bmQ6IHRy
YW5zcGFyZW50OwogICAgICAgICAgICBib3JkZXItcmFkaXVzOiAzcHg7CiAgICAgICAgICAgIGZv
bnQ6IGluaGVyaXQ7CiAgICAgICAgICAgIGZvbnQtc2l6ZTogMTNweDsKICAgICAgICAgICAgZm9u
dC13ZWlnaHQ6IDYwMDsKICAgICAgICAgICAgbGluZS1oZWlnaHQ6IDEuNDU7CiAgICAgICAgICAg
IHdvcmQtYnJlYWs6IGJyZWFrLWFsbDsKICAgICAgICAgICAgb3ZlcmZsb3ctd3JhcDogYW55d2hl
cmU7CiAgICAgICAgICAgIC13ZWJraXQtYXBwLXJlZ2lvbjogbm8tZHJhZzsgYXBwLXJlZ2lvbjog
bm8tZHJhZzsKICAgICAgICAgICAgcG9pbnRlci1ldmVudHM6IGF1dG8gIWltcG9ydGFudDsKICAg
ICAgICAgICAgcG9zaXRpb246IHJlbGF0aXZlOwogICAgICAgICAgICB6LWluZGV4OiA4OwogICAg
ICAgICAgICB0cmFuc2l0aW9uOiBiYWNrZ3JvdW5kIC4xMnMgZWFzZSwgY29sb3IgLjEycyBlYXNl
OwogICAgICAgIH0KICAgICAgICAucmYtc2VnOmhvdmVyIHsKICAgICAgICAgICAgYmFja2dyb3Vu
ZDogcmdiYSg5MSwxMTUsMjMyLC4xNCk7CiAgICAgICAgICAgIHRleHQtZGVjb3JhdGlvbjogdW5k
ZXJsaW5lOwogICAgICAgIH0KICAgICAgICAucmYtc2VwIHsKICAgICAgICAgICAgZGlzcGxheTog
aW5saW5lOwogICAgICAgICAgICBjb2xvcjogdmFyKC0tdHh0Myk7CiAgICAgICAgICAgIHBhZGRp
bmc6IDAgMXB4OwogICAgICAgICAgICBtYXJnaW46IDA7CiAgICAgICAgICAgIHVzZXItc2VsZWN0
OiBub25lOwogICAgICAgICAgICBvcGFjaXR5OiAuNTU7CiAgICAgICAgICAgIHBvaW50ZXItZXZl
bnRzOiBub25lOwogICAgICAgICAgICBmb250LXNpemU6IDEycHg7CiAgICAgICAgICAgIGxpbmUt
aGVpZ2h0OiAxLjQ1OwogICAgICAgIH0KICAgICAgICAuaXRtLnJmLWZpeGVkIC5pLWljbyB7CiAg
ICAgICAgICAgIGJveC1zaGFkb3c6IDAgMCAwIDEuNXB4IHJnYmEoOTEsMTE1LDIzMiwuNDUpOwog
ICAgICAgIH0KICAgICAgICAucmYtcGluLXRhZyB7CiAgICAgICAgICAgIGRpc3BsYXk6IGlubGlu
ZS1mbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBqdXN0aWZ5LWNvbnRlbnQ6IGNlbnRlcjsKICAg
ICAgICAgICAgZmxleC1zaHJpbms6IDA7CiAgICAgICAgICAgIGhlaWdodDogMTZweDsgcGFkZGlu
ZzogMCA2cHg7IG1hcmdpbi1yaWdodDogMDsKICAgICAgICAgICAgYm9yZGVyLXJhZGl1czogNHB4
OwogICAgICAgICAgICBmb250LXNpemU6IDEwcHg7IGZvbnQtd2VpZ2h0OiA1MDA7CiAgICAgICAg
ICAgIGNvbG9yOiAjN2E4NDk5OwogICAgICAgICAgICBiYWNrZ3JvdW5kOiByZ2JhKDEyMiwxMzIs
MTUzLC4xMik7CiAgICAgICAgICAgIGJvcmRlcjogMXB4IHNvbGlkIHJnYmEoMTIyLDEzMiwxNTMs
LjIyKTsKICAgICAgICAgICAgbGV0dGVyLXNwYWNpbmc6IC4wMmVtOwogICAgICAgICAgICB3aGl0
ZS1zcGFjZTogbm93cmFwOwogICAgICAgICAgICBwb2ludGVyLWV2ZW50czogbm9uZTsKICAgICAg
ICB9CiAgICAgICAgLmktdGh1bWItd3JhcCB7CiAgICAgICAgICAgIHdpZHRoOiAxMDAlOyBtaW4t
aGVpZ2h0OiA0OHB4OyBtYXgtaGVpZ2h0OiAxODBweDsgbWFyZ2luLWJvdHRvbTogNHB4OwogICAg
ICAgICAgICBkaXNwbGF5OiBmbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBqdXN0aWZ5LWNvbnRl
bnQ6IGNlbnRlcjsKICAgICAgICAgICAgYmFja2dyb3VuZDogI2YzZjVmOTsgYm9yZGVyLXJhZGl1
czogdmFyKC0tcik7IG92ZXJmbG93OiBoaWRkZW47CiAgICAgICAgfQogICAgICAgIC5pLXRodW1i
LXdyYXAud2FpdGluZyB7CiAgICAgICAgICAgIG1pbi1oZWlnaHQ6IDg4cHg7CiAgICAgICAgICAg
IGJhY2tncm91bmQ6IGxpbmVhci1ncmFkaWVudCg5MGRlZywgI2U4ZWJmMiAwJSwgI2Y0ZjZmYSA0
NSUsICNlOGViZjIgMTAwJSk7CiAgICAgICAgICAgIGJhY2tncm91bmQtc2l6ZTogMjAwJSAxMDAl
OwogICAgICAgICAgICBhbmltYXRpb246IHRodW1iU2hpbW1lciAxLjA1cyBlYXNlLWluLW91dCBp
bmZpbml0ZTsKICAgICAgICB9CiAgICAgICAgQGtleWZyYW1lcyB0aHVtYlNoaW1tZXIgewogICAg
ICAgICAgICAwJSB7IGJhY2tncm91bmQtcG9zaXRpb246IDEwMCUgMDsgfQogICAgICAgICAgICAx
MDAlIHsgYmFja2dyb3VuZC1wb3NpdGlvbjogLTEwMCUgMDsgfQogICAgICAgIH0KICAgICAgICAu
aS10aHVtYiB7IG1heC13aWR0aDogMTAwJTsgbWF4LWhlaWdodDogMTgwcHg7IHdpZHRoOiBhdXRv
OyBoZWlnaHQ6IGF1dG87IG9iamVjdC1maXQ6IGNvbnRhaW47IGRpc3BsYXk6IGJsb2NrOyB9CiAg
ICAgICAgLmktdGh1bWIudGh1bWItbG9hZGluZyB7IG9wYWNpdHk6IDA7IHdpZHRoOiAxcHg7IGhl
aWdodDogMXB4OyB9CgogICAgICAgIC8qIE1ldGEgYmFyOiB0aW1lIGxlZnQgfCBleHBhbmQgY2Vu
dGVyIHwgdGFncyByaWdodCAqLwogICAgICAgIC5pLW1ldGEgewogICAgICAgICAgICBkaXNwbGF5
OiBncmlkOwogICAgICAgICAgICBncmlkLXRlbXBsYXRlLWNvbHVtbnM6IDFmciBhdXRvIDFmcjsK
ICAgICAgICAgICAgYWxpZ24taXRlbXM6IGNlbnRlcjsKICAgICAgICAgICAgZ2FwOiA0cHg7CiAg
ICAgICAgICAgIG1hcmdpbi10b3A6IDRweDsKICAgICAgICAgICAgd2lkdGg6IDEwMCU7CiAgICAg
ICAgfQogICAgICAgIC5pLW1ldGEgLmktdGltZSB7IGp1c3RpZnktc2VsZjogc3RhcnQ7IH0KICAg
ICAgICAuaS1tZXRhLWNlbnRlciB7CiAgICAgICAgICAgIGp1c3RpZnktc2VsZjogY2VudGVyOwog
ICAgICAgICAgICBkaXNwbGF5OiBmbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBqdXN0aWZ5LWNv
bnRlbnQ6IGNlbnRlcjsKICAgICAgICAgICAgZ2FwOiA0cHg7CiAgICAgICAgICAgIG1pbi13aWR0
aDogMXB4OyAvKiBrZWVwIGNlbnRlciBjb2x1bW4gZXZlbiB3aGVuIGV4cGFuZCBpcyBoaWRkZW4g
Ki8KICAgICAgICB9CiAgICAgICAgLmktbWV0YS1yaWdodCB7CiAgICAgICAgICAgIGp1c3RpZnkt
c2VsZjogZW5kOwogICAgICAgICAgICBkaXNwbGF5OiBmbGV4OyBhbGlnbi1pdGVtczogY2VudGVy
OyBnYXA6IDVweDsgZmxleC13cmFwOiBub3dyYXA7CiAgICAgICAgICAgIGp1c3RpZnktY29udGVu
dDogZmxleC1lbmQ7CiAgICAgICAgICAgIG1pbi13aWR0aDogMDsKICAgICAgICB9CiAgICAgICAg
LmktbWV0YS1yaWdodC50ZXh0LW1ldGEgewogICAgICAgICAgICBmbGV4LXdyYXA6IG5vd3JhcDsK
ICAgICAgICAgICAgZ2FwOiA0cHg7CiAgICAgICAgfQogICAgICAgIC5pLXNyYy10aXRsZSB7CiAg
ICAgICAgICAgIGZvbnQtc2l6ZTogMTBweDsKICAgICAgICAgICAgY29sb3I6IHZhcigtLXR4dDMp
OwogICAgICAgICAgICBtYXgtd2lkdGg6IDExZW07CiAgICAgICAgICAgIG92ZXJmbG93OiBoaWRk
ZW47CiAgICAgICAgICAgIHRleHQtb3ZlcmZsb3c6IGVsbGlwc2lzOwogICAgICAgICAgICB3aGl0
ZS1zcGFjZTogbm93cmFwOwogICAgICAgICAgICBtaW4td2lkdGg6IDA7CiAgICAgICAgICAgIGxp
bmUtaGVpZ2h0OiAxLjQ7CiAgICAgICAgfQogICAgICAgIC5pLXRpbWUsIC5pLXRhZyB7IGZvbnQt
c2l6ZTogMTBweDsgY29sb3I6IHZhcigtLXR4dDMpOyB9CiAgICAgICAgLmktdGFnIHsKICAgICAg
ICAgICAgYmFja2dyb3VuZDogI2YxZjNmODsgcGFkZGluZzogMCA1cHg7IGJvcmRlci1yYWRpdXM6
IDNweDsKICAgICAgICAgICAgd2hpdGUtc3BhY2U6IG5vd3JhcDsgZmxleC1zaHJpbms6IDA7IGxp
bmUtaGVpZ2h0OiAxLjQ7CiAgICAgICAgfQogICAgICAgIC5pLWNoYXJzIHsKICAgICAgICAgICAg
Zm9udC1zaXplOiAxMHB4OyBjb2xvcjogdmFyKC0tdHh0Myk7CiAgICAgICAgICAgIGJhY2tncm91
bmQ6ICNmMWYzZjg7IHBhZGRpbmc6IDAgNXB4OyBib3JkZXItcmFkaXVzOiAzcHg7CiAgICAgICAg
ICAgIGZvbnQtdmFyaWFudC1udW1lcmljOiB0YWJ1bGFyLW51bXM7CiAgICAgICAgICAgIHdoaXRl
LXNwYWNlOiBub3dyYXA7CiAgICAgICAgICAgIGRpc3BsYXk6IGlubGluZS1mbGV4OyBhbGlnbi1p
dGVtczogYmFzZWxpbmU7IGdhcDogMnB4OwogICAgICAgIH0KICAgICAgICAuaS1jaGFycyAubiB7
CiAgICAgICAgICAgIGRpc3BsYXk6IGlubGluZS1ibG9jazsKICAgICAgICAgICAgbWluLXdpZHRo
OiA0Y2g7CiAgICAgICAgICAgIHRleHQtYWxpZ246IHJpZ2h0OwogICAgICAgICAgICBmb250LWZh
bWlseTogJ0Nhc2NhZGlhIE1vbm8nLCAnQ29uc29sYXMnLCAnU2FyYXNhIE1vbm8gU0MnLCB1aS1t
b25vc3BhY2UsIG1vbm9zcGFjZTsKICAgICAgICAgICAgZm9udC13ZWlnaHQ6IDYwMDsKICAgICAg
ICAgICAgY29sb3I6IHZhcigtLXR4dDIpOwogICAgICAgIH0KICAgICAgICAvKiBzcmMtdGl0bGUt
dGlwICovCiAgICAgICAgLmktc3JjLWljbywgLm1nLXNyYyB7IGN1cnNvcjogcG9pbnRlcjsgfQog
ICAgICAgICNzcmMtdGlwIHsKICAgICAgICAgICAgcG9zaXRpb246IGZpeGVkOyB6LWluZGV4OiA5
OTk5OTsKICAgICAgICAgICAgbWF4LXdpZHRoOiBtaW4oMjgwcHgsIGNhbGMoMTAwdncgLSAxNnB4
KSk7CiAgICAgICAgICAgIHBhZGRpbmc6IDZweCAxMHB4OwogICAgICAgICAgICBib3JkZXItcmFk
aXVzOiA4cHg7CiAgICAgICAgICAgIGJhY2tncm91bmQ6IHJnYmEoMzIsMzYsNDgsLjkyKTsgY29s
b3I6ICNmZmY7CiAgICAgICAgICAgIGZvbnQtc2l6ZTogMTJweDsgbGluZS1oZWlnaHQ6IDEuMzU7
CiAgICAgICAgICAgIGJveC1zaGFkb3c6IDAgNnB4IDE4cHggcmdiYSgwLDAsMCwuMjIpOwogICAg
ICAgICAgICBwb2ludGVyLWV2ZW50czogbm9uZTsKICAgICAgICAgICAgb3BhY2l0eTogMDsgdHJh
bnNmb3JtOiB0cmFuc2xhdGVZKDRweCk7CiAgICAgICAgICAgIHRyYW5zaXRpb246IG9wYWNpdHkg
LjJzIGVhc2UsIHRyYW5zZm9ybSAuMjJzIGN1YmljLWJlemllciguMjIsMSwuMzYsMSk7CiAgICAg
ICAgICAgIHdvcmQtYnJlYWs6IGJyZWFrLXdvcmQ7CiAgICAgICAgfQogICAgICAgICNzcmMtdGlw
LnNob3cgeyBvcGFjaXR5OiAxOyB0cmFuc2Zvcm06IHRyYW5zbGF0ZVkoMCk7IH0KICAgICAgICAu
aS1zcmMtaWNvIHsKICAgICAgICAgICAgd2lkdGg6IDE0cHg7IGhlaWdodDogMTRweDsgZmxleC1z
aHJpbms6IDA7CiAgICAgICAgICAgIGJvcmRlci1yYWRpdXM6IDJweDsgb2JqZWN0LWZpdDogY29u
dGFpbjsKICAgICAgICAgICAgZGlzcGxheTogYmxvY2s7CiAgICAgICAgfQogICAgICAgIC5pLW51
bSB7CiAgICAgICAgICAgIGRpc3BsYXk6IGZsZXg7IGZsZXgtZGlyZWN0aW9uOiBjb2x1bW47IGFs
aWduLWl0ZW1zOiBmbGV4LWVuZDsKICAgICAgICAgICAganVzdGlmeS1jb250ZW50OiBzcGFjZS1i
ZXR3ZWVuOwogICAgICAgICAgICBhbGlnbi1zZWxmOiBzdHJldGNoOwogICAgICAgICAgICBmb250
LXNpemU6IDEwcHg7IGNvbG9yOiB2YXIoLS10eHQzKTsgbWluLXdpZHRoOiAxNnB4OwogICAgICAg
ICAgICB0ZXh0LWFsaWduOiByaWdodDsgZmxleC1zaHJpbms6IDA7CiAgICAgICAgICAgIHBhZGRp
bmctdG9wOiAycHg7CiAgICAgICAgfQogICAgICAgIC5pLW51bSAuaS1zcmMtaWNvIHsgd2lkdGg6
IDE2cHg7IGhlaWdodDogMTZweDsgbWFyZ2luLXRvcDogYXV0bzsgfQoKICAgICAgICAuaS1leHBh
bmQtYnRuIHsKICAgICAgICAgICAgYm9yZGVyOiBub25lOyBiYWNrZ3JvdW5kOiBub25lOyBjdXJz
b3I6IHBvaW50ZXI7CiAgICAgICAgICAgIGNvbG9yOiB2YXIoLS10eHQzKTsgZm9udC1zaXplOiAx
MnB4OyBwYWRkaW5nOiAzcHggMTBweDsKICAgICAgICAgICAgYm9yZGVyLXJhZGl1czogOHB4OyBk
aXNwbGF5OiBub25lOyBhbGlnbi1pdGVtczogY2VudGVyOyBnYXA6IDRweDsKICAgICAgICAgICAg
dHJhbnNpdGlvbjogY29sb3IgdmFyKC0tdHIpLCBiYWNrZ3JvdW5kIHZhcigtLXRyKTsKICAgICAg
ICAgICAgLXdlYmtpdC1hcHAtcmVnaW9uOiBuby1kcmFnOyBhcHAtcmVnaW9uOiBuby1kcmFnOwog
ICAgICAgICAgICBsaW5lLWhlaWdodDogMS4yOwogICAgICAgIH0KICAgICAgICAuaS1leHBhbmQt
YnRuIHN2ZyB7IHdpZHRoOiAxNHB4OyBoZWlnaHQ6IDE0cHg7IGZsZXgtc2hyaW5rOiAwOyB9CiAg
ICAgICAgLmktZXhwYW5kLWJ0bi5vbiB7IGRpc3BsYXk6IGlubGluZS1mbGV4OyB9CiAgICAgICAg
LmktZXhwYW5kLWJ0bjpob3ZlciB7IGNvbG9yOiB2YXIoLS1hY2MpOyBiYWNrZ3JvdW5kOiByZ2Jh
KDkxLDExNSwyMzIsLjA4KTsgfQogICAgICAgIC5pLXByZXYuZXhwYW5kZWQsIC5pLW5hbWUuZXhw
YW5kZWQgewogICAgICAgICAgICAtd2Via2l0LWxpbmUtY2xhbXA6IHVuc2V0OwogICAgICAgICAg
ICBkaXNwbGF5OiBibG9jazsKICAgICAgICAgICAgb3ZlcmZsb3c6IGhpZGRlbjsKICAgICAgICAg
ICAgLyog6auY5bqm55SxIEpTIOaMieWIl+ihqOWPr+inhuWMuuiuvuWumu+8mue6puWNoOaVtOih
qOWwkeS4gOihjCAqLwogICAgICAgIH0KICAgICAgICAuaS1zcmMtdGl0bGUgeyBkaXNwbGF5OiBu
b25lICFpbXBvcnRhbnQ7IH0KICAgICAgICAuaS1maWxlLWRldGFpbCB7CiAgICAgICAgICAgIGRp
c3BsYXk6IG5vbmU7CiAgICAgICAgICAgIG1hcmdpbi10b3A6IDRweDsKICAgICAgICAgICAgcGFk
ZGluZzogMDsKICAgICAgICAgICAgYmFja2dyb3VuZDogbm9uZTsKICAgICAgICAgICAgYm9yZGVy
OiBub25lOwogICAgICAgIH0KICAgICAgICAuaS1maWxlLWRldGFpbC5vbiB7IGRpc3BsYXk6IGJs
b2NrOyB9CiAgICAgICAgLmZkLWJsb2NrIHsKICAgICAgICAgICAgZGlzcGxheTogZmxleDsgZmxl
eC1kaXJlY3Rpb246IGNvbHVtbjsgZ2FwOiA2cHg7CiAgICAgICAgfQogICAgICAgIC5mZC1ibG9j
ayArIC5mZC1ibG9jayB7IG1hcmdpbi10b3A6IDhweDsgfQogICAgICAgIC5mZC1wYXRoIHsKICAg
ICAgICAgICAgd2lkdGg6IDEwMCU7CiAgICAgICAgICAgIGZvbnQ6IDYwMCAxMnB4LzEuNTUgJ1Nl
Z29lIFVJIFZhcmlhYmxlIFRleHQnLCdTZWdvZSBVSScsJ01pY3Jvc29mdCBZYUhlaSBVSScsc2Fu
cy1zZXJpZjsKICAgICAgICAgICAgY29sb3I6IHZhcigtLXR4dDIpOwogICAgICAgICAgICBsZXR0
ZXItc3BhY2luZzogLjAxZW07CiAgICAgICAgICAgIHdvcmQtYnJlYWs6IGJyZWFrLWFsbDsKICAg
ICAgICAgICAgdXNlci1zZWxlY3Q6IHRleHQ7CiAgICAgICAgICAgIC13ZWJraXQtYXBwLXJlZ2lv
bjogbm8tZHJhZzsgYXBwLXJlZ2lvbjogbm8tZHJhZzsKICAgICAgICB9CiAgICAgICAgLmZkLXBh
dGgubGl2ZSB7IGN1cnNvcjogcG9pbnRlcjsgfQogICAgICAgIC5mZC1wYXRoLmxpdmU6aG92ZXIg
eyBjb2xvcjogdmFyKC0tYWNjKTsgfQogICAgICAgIC5mZC1wYXRoLmRlYWQgewogICAgICAgICAg
ICBjb2xvcjogIzlhYTBiMDsKICAgICAgICAgICAgdGV4dC1kZWNvcmF0aW9uOiBsaW5lLXRocm91
Z2g7CiAgICAgICAgICAgIHRleHQtZGVjb3JhdGlvbi10aGlja25lc3M6IDJweDsKICAgICAgICAg
ICAgdGV4dC1kZWNvcmF0aW9uLWNvbG9yOiByZ2JhKDE1NCwgMTYwLCAxNzYsIC41NSk7CiAgICAg
ICAgICAgIHRleHQtZGVjb3JhdGlvbi1za2lwLWluazogbm9uZTsKICAgICAgICAgICAgY3Vyc29y
OiBkZWZhdWx0OwogICAgICAgIH0KICAgICAgICAuZmQtYWN0aW9ucyB7CiAgICAgICAgICAgIGRp
c3BsYXk6IGZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGp1c3RpZnktY29udGVudDogZmxleC1l
bmQ7CiAgICAgICAgICAgIGdhcDogOHB4OyBmbGV4LXdyYXA6IHdyYXA7CiAgICAgICAgfQogICAg
ICAgIC5mZC1idG4gewogICAgICAgICAgICBib3JkZXI6IG5vbmU7IGJhY2tncm91bmQ6IG5vbmU7
IGN1cnNvcjogcG9pbnRlcjsKICAgICAgICAgICAgY29sb3I6IHZhcigtLXR4dDMpOyBmb250LXNp
emU6IDEwcHg7IGZvbnQtd2VpZ2h0OiA2MDA7CiAgICAgICAgICAgIHBhZGRpbmc6IDFweCAycHg7
IGRpc3BsYXk6IGlubGluZS1mbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBnYXA6IDJweDsKICAg
ICAgICAgICAgd2hpdGUtc3BhY2U6IG5vd3JhcDsKICAgICAgICAgICAgLXdlYmtpdC1hcHAtcmVn
aW9uOiBuby1kcmFnOyBhcHAtcmVnaW9uOiBuby1kcmFnOwogICAgICAgICAgICB0cmFuc2l0aW9u
OiBjb2xvciB2YXIoLS10cik7CiAgICAgICAgfQogICAgICAgIC5mZC1idG46aG92ZXIgeyBjb2xv
cjogdmFyKC0tYWNjKTsgfQogICAgICAgIC5mZC1idG4ub2sgeyBjb2xvcjogIzFmN2E1NTsgfQoK
ICAgICAgICAvKiDilIDilIAgQ29udGV4dCBtZW51IOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKU
gOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKU
gOKUgOKUgOKUgOKUgCAqLwogICAgICAgICNjdHggewogICAgICAgICAgICBwb3NpdGlvbjogZml4
ZWQ7IHotaW5kZXg6IDk5OTk7IG1pbi13aWR0aDogMTMycHg7IGRpc3BsYXk6IG5vbmU7IHBhZGRp
bmc6IDRweDsKICAgICAgICAgICAgYmFja2dyb3VuZDogI2ZmZjsgYm9yZGVyLXJhZGl1czogdmFy
KC0tcik7IGJveC1zaGFkb3c6IDAgNnB4IDE2cHggcmdiYSgwLDAsMCwuMTQpOwogICAgICAgICAg
ICAtd2Via2l0LWFwcC1yZWdpb246IG5vLWRyYWc7IGFwcC1yZWdpb246IG5vLWRyYWc7CiAgICAg
ICAgfQogICAgICAgICNjdHgub24geyBkaXNwbGF5OiBibG9jazsgfQogICAgICAgIC5jLWl0ZW0g
ewogICAgICAgICAgICBkaXNwbGF5OiBmbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBnYXA6IDdw
eDsgcGFkZGluZzogNnB4IDlweDsKICAgICAgICAgICAgYm9yZGVyLXJhZGl1czogdmFyKC0tcik7
IGN1cnNvcjogcG9pbnRlcjsgZm9udC1zaXplOiAxMXB4OyBjb2xvcjogdmFyKC0tdHh0KTsKICAg
ICAgICB9CiAgICAgICAgLmMtaXRlbTpob3ZlciB7IGJhY2tncm91bmQ6ICNmMmY0Zjk7IH0KICAg
ICAgICAuYy1pdGVtLmRhbmdlciB7IGNvbG9yOiAjZmY3YjljOyB9CiAgICAgICAgLmMtc2VwIHsg
aGVpZ2h0OiAxcHg7IGJhY2tncm91bmQ6ICNlY2VmZjU7IG1hcmdpbjogM3B4IDA7IH0KICAgICAg
ICAuYy1pY28geyB3aWR0aDogMTRweDsgdGV4dC1hbGlnbjogY2VudGVyOyB9CiAgICAgICAgLmMt
c3Vid3JhcCB7IHBvc2l0aW9uOiByZWxhdGl2ZTsgfQogICAgICAgIC5jLXN1YndyYXAgPiAuYy1p
dGVtIHsgd2lkdGg6IDEwMCU7IGJveC1zaXppbmc6IGJvcmRlci1ib3g7IH0KICAgICAgICAuYy1j
YXJldCB7IG1hcmdpbi1sZWZ0OiBhdXRvOyBjb2xvcjogdmFyKC0tdHh0Myk7IGZvbnQtc2l6ZTog
MTBweDsgfQogICAgICAgIC5jLXN1YiB7CiAgICAgICAgICAgIGRpc3BsYXk6IG5vbmU7IHBvc2l0
aW9uOiBhYnNvbHV0ZTsgbGVmdDogY2FsYygxMDAlIC0gMnB4KTsgdG9wOiAtMnB4OyB6LWluZGV4
OiAxOwogICAgICAgICAgICBtaW4td2lkdGg6IDA7IHdpZHRoOiBtYXgtY29udGVudDsgcGFkZGlu
ZzogMnB4OwogICAgICAgICAgICBiYWNrZ3JvdW5kOiAjZmZmOyBib3JkZXItcmFkaXVzOiB2YXIo
LS1yKTsKICAgICAgICAgICAgYm94LXNoYWRvdzogMCA2cHggMTZweCByZ2JhKDAsMCwwLC4xNCk7
CiAgICAgICAgfQogICAgICAgIC5jLXN1Yi5sZWZ0IHsKICAgICAgICAgICAgbGVmdDogYXV0bzsg
cmlnaHQ6IGNhbGMoMTAwJSAtIDJweCk7CiAgICAgICAgfQogICAgICAgIC5jLXN1YndyYXA6aG92
ZXIgPiAuYy1zdWIsCiAgICAgICAgLmMtc3Vid3JhcC5vcGVuID4gLmMtc3ViIHsgZGlzcGxheTog
YmxvY2s7IH0KICAgICAgICAuYy1zdWIgLmMtaXRlbSB7CiAgICAgICAgICAgIGZvbnQtZmFtaWx5
OiB1aS1tb25vc3BhY2UsIENvbnNvbGFzLCAiQ2FzY2FkaWEgTW9ubyIsIG1vbm9zcGFjZTsKICAg
ICAgICAgICAgZm9udC1zaXplOiAxMHB4OyB3aGl0ZS1zcGFjZTogbm93cmFwOwogICAgICAgICAg
ICBwYWRkaW5nOiA0cHggN3B4OyBnYXA6IDA7CiAgICAgICAgfQogICAgICAgIC5jLXN1YiAuYy1p
dGVtLnBpY2sgewogICAgICAgICAgICBiYWNrZ3JvdW5kOiByZ2JhKDkxLCAxMjQsIDI1MCwgLjE0
KTsKICAgICAgICAgICAgY29sb3I6ICMzYjViZGI7CiAgICAgICAgICAgIGZvbnQtd2VpZ2h0OiA2
MDA7CiAgICAgICAgfQogICAgICAgIC5jLXN1YiAuYy1pdGVtLnBpY2sgLmMtbnVtLAogICAgICAg
IC5jLXN1YiAuYy1pdGVtLnBpY2sgLmMtYXJyb3cgeyBjb2xvcjogIzViN2NmYTsgfQogICAgICAg
IC5jLXN1YiAuYy1udW0gewogICAgICAgICAgICB3aWR0aDogMTJweDsgZmxleC1zaHJpbms6IDA7
IGNvbG9yOiB2YXIoLS10eHQzKTsgdGV4dC1hbGlnbjogbGVmdDsKICAgICAgICAgICAgbWFyZ2lu
LXJpZ2h0OiA0cHg7CiAgICAgICAgfQogICAgICAgIC5jLXN1YiAuYy1mcm9tIHsKICAgICAgICAg
ICAgZGlzcGxheTogaW5saW5lLWJsb2NrOyBtaW4td2lkdGg6IDA7IHRleHQtYWxpZ246IGxlZnQ7
IGZsZXgtc2hyaW5rOiAwOwogICAgICAgIH0KICAgICAgICAuYy1zdWIgLmMtYXJyb3cgewogICAg
ICAgICAgICBkaXNwbGF5OiBpbmxpbmUtYmxvY2s7IHBhZGRpbmc6IDAgNHB4OyBjb2xvcjogdmFy
KC0tdHh0Myk7IGZsZXgtc2hyaW5rOiAwOwogICAgICAgIH0KICAgICAgICAuYy1zdWIgLmMtdG8g
eyBmbGV4LXNocmluazogMDsgfQoKICAgICAgICAvKiDilIDilIAgQ2xlYXIgY29uZmlybSDilIDi
lIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDi
lIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIAgKi8KICAgICAgICAjY2xyLWRsZyB7CiAg
ICAgICAgICAgIGRpc3BsYXk6IG5vbmU7IHBvc2l0aW9uOiBmaXhlZDsgaW5zZXQ6IDA7IHotaW5k
ZXg6IDEwMDAwOwogICAgICAgICAgICBiYWNrZ3JvdW5kOiByZ2JhKDIwLCAyMiwgMzUsIC40Mik7
CiAgICAgICAgICAgIGFsaWduLWl0ZW1zOiBjZW50ZXI7IGp1c3RpZnktY29udGVudDogY2VudGVy
OwogICAgICAgICAgICAtd2Via2l0LWFwcC1yZWdpb246IG5vLWRyYWc7IGFwcC1yZWdpb246IG5v
LWRyYWc7CiAgICAgICAgfQogICAgICAgICNjbHItZGxnLm9uIHsgZGlzcGxheTogZmxleDsgfQog
ICAgICAgIC5jbHItYm94IHsKICAgICAgICAgICAgd2lkdGg6IG1pbigyODBweCwgY2FsYygxMDAl
IC0gMzJweCkpOwogICAgICAgICAgICBiYWNrZ3JvdW5kOiAjZmZmOyBib3JkZXItcmFkaXVzOiAx
MnB4OwogICAgICAgICAgICBib3gtc2hhZG93OiAwIDEycHggMzJweCByZ2JhKDAsMCwwLC4xOCk7
CiAgICAgICAgICAgIHBhZGRpbmc6IDE2cHggMTZweCAxNHB4OyBjb2xvcjogdmFyKC0tdHh0KTsK
ICAgICAgICB9CiAgICAgICAgLmNsci10aXRsZSB7IGZvbnQtc2l6ZTogMTRweDsgZm9udC13ZWln
aHQ6IDcwMDsgbWFyZ2luLWJvdHRvbTogNnB4OyB9CiAgICAgICAgLmNsci1kZXNjIHsgZm9udC1z
aXplOiAxMXB4OyBjb2xvcjogdmFyKC0tdHh0Myk7IGxpbmUtaGVpZ2h0OiAxLjU7IG1hcmdpbi1i
b3R0b206IDEycHg7IH0KICAgICAgICAuY2xyLWNoZWNrIHsKICAgICAgICAgICAgZGlzcGxheTog
ZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsgZ2FwOiA3cHg7CiAgICAgICAgICAgIGZvbnQtc2l6
ZTogMTJweDsgY29sb3I6IHZhcigtLXR4dCk7IGN1cnNvcjogcG9pbnRlcjsKICAgICAgICAgICAg
dXNlci1zZWxlY3Q6IG5vbmU7IG1hcmdpbi1ib3R0b206IDE0cHg7CiAgICAgICAgfQogICAgICAg
IC5jbHItY2hlY2sgaW5wdXQgewogICAgICAgICAgICB3aWR0aDogMTRweDsgaGVpZ2h0OiAxNHB4
OyBhY2NlbnQtY29sb3I6IHZhcigtLWFjYyk7IGN1cnNvcjogcG9pbnRlcjsKICAgICAgICB9CiAg
ICAgICAgLmNsci1idG5zIHsgZGlzcGxheTogZmxleDsgZ2FwOiA4cHg7IGp1c3RpZnktY29udGVu
dDogZmxleC1lbmQ7IH0KICAgICAgICAuY2xyLWJ0bnMgYnV0dG9uIHsKICAgICAgICAgICAgYm9y
ZGVyOiBub25lOyBib3JkZXItcmFkaXVzOiA4cHg7IHBhZGRpbmc6IDdweCAxNHB4OwogICAgICAg
ICAgICBmb250LXNpemU6IDEycHg7IGN1cnNvcjogcG9pbnRlcjsgZm9udC13ZWlnaHQ6IDYwMDsK
ICAgICAgICAgICAgdHJhbnNpdGlvbjogYmFja2dyb3VuZCB2YXIoLS10ciksIGNvbG9yIHZhcigt
LXRyKTsKICAgICAgICB9CiAgICAgICAgI2Nsci1jYW5jZWwgeyBiYWNrZ3JvdW5kOiAjZjFmM2Y4
OyBjb2xvcjogdmFyKC0tdHh0Mik7IH0KICAgICAgICAjY2xyLWNhbmNlbDpob3ZlciB7IGJhY2tn
cm91bmQ6ICNlNmU5ZjI7IH0KICAgICAgICAjY2xyLW9rIHsgYmFja2dyb3VuZDogcmdiYSgyNTUs
MTIzLDE1NiwuMTQpOyBjb2xvcjogI2U4NWE3YTsgfQogICAgICAgICNjbHItb2s6aG92ZXIgeyBi
YWNrZ3JvdW5kOiByZ2JhKDI1NSwxMjMsMTU2LC4yNCk7IH0KCiAgICAgICAgLyog4pSA4pSAIEZp
bGUgcGF0aCB0aXAg4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA
4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSAICovCiAgICAg
ICAgI3BhdGgtdGlwIHsKICAgICAgICAgICAgZGlzcGxheTogbm9uZTsgcG9zaXRpb246IGZpeGVk
OyB6LWluZGV4OiAxMDAwMTsKICAgICAgICAgICAgd2lkdGg6IG1pbigzMjBweCwgY2FsYygxMDB2
dyAtIDE2cHgpKTsKICAgICAgICAgICAgbWF4LWhlaWdodDogbWluKDI4MHB4LCBjYWxjKDEwMHZo
IC0gMjRweCkpOwogICAgICAgICAgICBvdmVyZmxvdzogYXV0bzsKICAgICAgICAgICAgcGFkZGlu
ZzogMDsKICAgICAgICAgICAgYmFja2dyb3VuZDogbGluZWFyLWdyYWRpZW50KDE2NWRlZywgI2Zm
ZmZmZiAwJSwgI2Y2ZjhmYyAxMDAlKTsKICAgICAgICAgICAgYm9yZGVyOiAxcHggc29saWQgcmdi
YSg3MCwgODQsIDEyMCwgLjEpOwogICAgICAgICAgICBib3JkZXItcmFkaXVzOiAxMnB4OwogICAg
ICAgICAgICBib3gtc2hhZG93OgogICAgICAgICAgICAgICAgMCA0cHggNnB4IHJnYmEoMzAsIDQw
LCA3MCwgLjA0KSwKICAgICAgICAgICAgICAgIDAgMTRweCAzNnB4IHJnYmEoMzAsIDQwLCA3MCwg
LjE2KTsKICAgICAgICAgICAgY29sb3I6IHZhcigtLXR4dCk7CiAgICAgICAgICAgIHBvaW50ZXIt
ZXZlbnRzOiBhdXRvOwogICAgICAgICAgICBvcGFjaXR5OiAwOwogICAgICAgICAgICB0cmFuc2Zv
cm06IHRyYW5zbGF0ZVkoNHB4KSBzY2FsZSguOTgpOwogICAgICAgICAgICB0cmFuc2l0aW9uOiBv
cGFjaXR5IC4xNHMgZWFzZSwgdHJhbnNmb3JtIC4xNHMgZWFzZTsKICAgICAgICAgICAgLXdlYmtp
dC1hcHAtcmVnaW9uOiBuby1kcmFnOyBhcHAtcmVnaW9uOiBuby1kcmFnOwogICAgICAgIH0KICAg
ICAgICAjcGF0aC10aXAub24gewogICAgICAgICAgICBkaXNwbGF5OiBibG9jazsKICAgICAgICAg
ICAgb3BhY2l0eTogMTsKICAgICAgICAgICAgdHJhbnNmb3JtOiB0cmFuc2xhdGVZKDApIHNjYWxl
KDEpOwogICAgICAgIH0KICAgICAgICAucHQtaGVhZCB7CiAgICAgICAgICAgIGRpc3BsYXk6IGZs
ZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGp1c3RpZnktY29udGVudDogc3BhY2UtYmV0d2VlbjsK
ICAgICAgICAgICAgZ2FwOiAxMHB4OyBwYWRkaW5nOiAxMHB4IDEycHggOHB4OwogICAgICAgICAg
ICBib3JkZXItYm90dG9tOiAxcHggc29saWQgcmdiYSg3MCwgODQsIDEyMCwgLjA3KTsKICAgICAg
ICB9CiAgICAgICAgLnB0LXRpdGxlIHsKICAgICAgICAgICAgZm9udC1zaXplOiAxMXB4OyBmb250
LXdlaWdodDogNzAwOyBsZXR0ZXItc3BhY2luZzogLjA0ZW07CiAgICAgICAgICAgIGNvbG9yOiB2
YXIoLS10eHQyKTsgdGV4dC10cmFuc2Zvcm06IHVwcGVyY2FzZTsKICAgICAgICAgICAgZmxleC1z
aHJpbms6IDA7CiAgICAgICAgfQogICAgICAgIC5wdC1oZWFkLWJ0biB7CiAgICAgICAgICAgIGZs
ZXgtc2hyaW5rOiAwOyBtYXJnaW4tbGVmdDogYXV0bzsKICAgICAgICAgICAgaGVpZ2h0OiAyMnB4
OyBwYWRkaW5nOiAwIDhweDsgZGlzcGxheTogaW5saW5lLWZsZXg7IGFsaWduLWl0ZW1zOiBjZW50
ZXI7IGdhcDogNHB4OwogICAgICAgICAgICBib3JkZXI6IDFweCBzb2xpZCByZ2JhKDEwNywxMTIs
MTI4LC4yMik7IGJvcmRlci1yYWRpdXM6IDZweDsgY3Vyc29yOiBwb2ludGVyOwogICAgICAgICAg
ICBiYWNrZ3JvdW5kOiByZ2JhKDEwNywxMTIsMTI4LC4wNik7IGNvbG9yOiAjOGE5MGEwOyBmb250
LXNpemU6IDExcHg7IGZvbnQtd2VpZ2h0OiA2MDA7CiAgICAgICAgICAgIHdoaXRlLXNwYWNlOiBu
b3dyYXA7CiAgICAgICAgICAgIC13ZWJraXQtYXBwLXJlZ2lvbjogbm8tZHJhZzsgYXBwLXJlZ2lv
bjogbm8tZHJhZzsKICAgICAgICAgICAgdHJhbnNpdGlvbjogYmFja2dyb3VuZCB2YXIoLS10ciks
IGNvbG9yIHZhcigtLXRyKSwgYm9yZGVyLWNvbG9yIHZhcigtLXRyKTsKICAgICAgICB9CiAgICAg
ICAgLnB0LWhlYWQtYnRuOmhvdmVyIHsKICAgICAgICAgICAgYmFja2dyb3VuZDogcmdiYSgxMDcs
MTEyLDEyOCwuMTIpOyBjb2xvcjogdmFyKC0tdHh0Mik7CiAgICAgICAgICAgIGJvcmRlci1jb2xv
cjogcmdiYSgxMDcsMTEyLDEyOCwuNCk7CiAgICAgICAgfQogICAgICAgIC5wdC1saXN0IHsgcGFk
ZGluZzogNnB4IDhweCA4cHg7IGRpc3BsYXk6IGZsZXg7IGZsZXgtZGlyZWN0aW9uOiBjb2x1bW47
IGdhcDogNHB4OyB9CiAgICAgICAgLnB0LXJvdyB7CiAgICAgICAgICAgIGRpc3BsYXk6IGdyaWQ7
IGdyaWQtdGVtcGxhdGUtY29sdW1uczogOHB4IDFmcjsgZ2FwOiA4cHg7CiAgICAgICAgICAgIHBh
ZGRpbmc6IDhweCA4cHg7IGJvcmRlci1yYWRpdXM6IDhweDsKICAgICAgICAgICAgYmFja2dyb3Vu
ZDogcmdiYSgyNTUsMjU1LDI1NSwuNyk7CiAgICAgICAgfQogICAgICAgIC5wdC1yb3cuZGVhZCB7
IGJhY2tncm91bmQ6IHJnYmEoMjU1LCAxMjMsIDE1NiwgLjA2KTsgfQogICAgICAgIC5wdC1kb3Qg
ewogICAgICAgICAgICB3aWR0aDogOHB4OyBoZWlnaHQ6IDhweDsgYm9yZGVyLXJhZGl1czogNTAl
OyBtYXJnaW4tdG9wOiA1cHg7CiAgICAgICAgICAgIGJhY2tncm91bmQ6ICMyZWI0Nzg7IGJveC1z
aGFkb3c6IDAgMCAwIDNweCByZ2JhKDQ2LCAxODAsIDEyMCwgLjE4KTsKICAgICAgICB9CiAgICAg
ICAgLnB0LXJvdy5kZWFkIC5wdC1kb3QgewogICAgICAgICAgICBiYWNrZ3JvdW5kOiAjZTg1YTdh
OyBib3gtc2hhZG93OiAwIDAgMCAzcHggcmdiYSgyMzIsIDkwLCAxMjIsIC4xNik7CiAgICAgICAg
fQogICAgICAgIC5wdC1uYW1lIHsKICAgICAgICAgICAgZm9udC1zaXplOiAxMnB4OyBmb250LXdl
aWdodDogNjUwOyBjb2xvcjogdmFyKC0tdHh0KTsKICAgICAgICAgICAgbGluZS1oZWlnaHQ6IDEu
Mzsgd29yZC1icmVhazogYnJlYWstYWxsOwogICAgICAgIH0KICAgICAgICAucHQtcGF0aCB7CiAg
ICAgICAgICAgIG1hcmdpbi10b3A6IDNweDsKICAgICAgICAgICAgZm9udDogMTAuNXB4LzEuNDUg
J0Nhc2NhZGlhIE1vbm8nLCdDb25zb2xhcycsJ01pY3Jvc29mdCBZYUhlaSBVSScsbW9ub3NwYWNl
OwogICAgICAgICAgICBjb2xvcjogdmFyKC0tdHh0Mik7IHdvcmQtYnJlYWs6IGJyZWFrLWFsbDsK
ICAgICAgICAgICAgdXNlci1zZWxlY3Q6IHRleHQ7CiAgICAgICAgfQogICAgICAgIC5wdC1wYXRo
LmxpdmUgewogICAgICAgICAgICBjb2xvcjogdmFyKC0tYWNjKTsgY3Vyc29yOiBwb2ludGVyOwog
ICAgICAgIH0KICAgICAgICAucHQtcGF0aC5saXZlOmhvdmVyIHsgdGV4dC1kZWNvcmF0aW9uOiB1
bmRlcmxpbmU7IH0KICAgICAgICAucHQtcGF0aC5kZWFkIHsKICAgICAgICAgICAgY29sb3I6ICNj
NDNkNWM7CiAgICAgICAgICAgIHRleHQtZGVjb3JhdGlvbjogbGluZS10aHJvdWdoOwogICAgICAg
ICAgICB0ZXh0LWRlY29yYXRpb24tdGhpY2tuZXNzOiAycHg7CiAgICAgICAgICAgIHRleHQtZGVj
b3JhdGlvbi1jb2xvcjogI2UxMWQ0ODsKICAgICAgICAgICAgY3Vyc29yOiBkZWZhdWx0OwogICAg
ICAgIH0KICAgICAgICAucHQtYWN0aW9ucyB7CiAgICAgICAgICAgIG1hcmdpbi10b3A6IDZweDsK
ICAgICAgICAgICAgZGlzcGxheTogZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsgZ2FwOiA2cHg7
IGZsZXgtd3JhcDogd3JhcDsKICAgICAgICB9CiAgICAgICAgLnB0LWNvcHktYnRuIHsKICAgICAg
ICAgICAgaGVpZ2h0OiAyMnB4OyBwYWRkaW5nOiAwIDhweDsgZGlzcGxheTogaW5saW5lLWZsZXg7
IGFsaWduLWl0ZW1zOiBjZW50ZXI7CiAgICAgICAgICAgIGJvcmRlcjogMXB4IHNvbGlkIHJnYmEo
MTA3LDExMiwxMjgsLjIyKTsgYm9yZGVyLXJhZGl1czogNnB4OyBjdXJzb3I6IHBvaW50ZXI7CiAg
ICAgICAgICAgIGJhY2tncm91bmQ6IHJnYmEoMTA3LDExMiwxMjgsLjA2KTsgY29sb3I6ICM4YTkw
YTA7IGZvbnQtc2l6ZTogMTFweDsgZm9udC13ZWlnaHQ6IDYwMDsKICAgICAgICAgICAgLXdlYmtp
dC1hcHAtcmVnaW9uOiBuby1kcmFnOyBhcHAtcmVnaW9uOiBuby1kcmFnOwogICAgICAgICAgICB0
cmFuc2l0aW9uOiBiYWNrZ3JvdW5kIHZhcigtLXRyKSwgY29sb3IgdmFyKC0tdHIpLCBib3JkZXIt
Y29sb3IgdmFyKC0tdHIpOwogICAgICAgIH0KICAgICAgICAucHQtY29weS1idG46aG92ZXIgewog
ICAgICAgICAgICBiYWNrZ3JvdW5kOiByZ2JhKDEwNywxMTIsMTI4LC4xMik7IGNvbG9yOiB2YXIo
LS10eHQyKTsKICAgICAgICAgICAgYm9yZGVyLWNvbG9yOiByZ2JhKDEwNywxMTIsMTI4LC40KTsK
ICAgICAgICB9CiAgICAgICAgLnB0LWNvcHktYnRuLm9rIHsKICAgICAgICAgICAgY29sb3I6ICMx
ZjdhNTU7IGJvcmRlci1jb2xvcjogcmdiYSg0NiwgMTgwLCAxMjAsIC4zNSk7CiAgICAgICAgICAg
IGJhY2tncm91bmQ6IHJnYmEoNDYsIDE4MCwgMTIwLCAuMSk7CiAgICAgICAgfQogICAgICAgIC5p
dG0uaXQtZ3JvdXAgewogICAgICAgICAgICBmbGV4LWRpcmVjdGlvbjogY29sdW1uOwogICAgICAg
ICAgICBhbGlnbi1pdGVtczogc3RyZXRjaDsKICAgICAgICAgICAgZ2FwOiAwOwogICAgICAgICAg
ICBwYWRkaW5nOiA2cHggOHB4IDRweDsKICAgICAgICAgICAgY3Vyc29yOiBkZWZhdWx0OwogICAg
ICAgIH0KICAgICAgICAuaXRtLml0LWdyb3VwOmhvdmVyIHsgYmFja2dyb3VuZDogdmFyKC0tY2Fy
ZCk7IH0KICAgICAgICAubWctaGVhZCB7CiAgICAgICAgICAgIGRpc3BsYXk6IGZsZXg7IGFsaWdu
LWl0ZW1zOiBjZW50ZXI7IGdhcDogNnB4OwogICAgICAgICAgICBmb250LXNpemU6IDExcHg7IGNv
bG9yOiB2YXIoLS10eHQzKTsgZm9udC13ZWlnaHQ6IDYwMDsKICAgICAgICAgICAgcGFkZGluZzog
MnB4IDJweCA2cHg7IHVzZXItc2VsZWN0OiBub25lOwogICAgICAgIH0KICAgICAgICAubWctaGVh
ZCAubWctdGFnIHsKICAgICAgICAgICAgZGlzcGxheTogaW5saW5lLWZsZXg7IGFsaWduLWl0ZW1z
OiBjZW50ZXI7CiAgICAgICAgICAgIGhlaWdodDogMTZweDsgcGFkZGluZzogMCA2cHg7IGJvcmRl
ci1yYWRpdXM6IDhweDsKICAgICAgICAgICAgYmFja2dyb3VuZDogcmdiYSg5MSwxMTUsMjMyLC4x
Mik7IGNvbG9yOiB2YXIoLS1hY2MpOyBmb250LXNpemU6IDEwcHg7CiAgICAgICAgfQogICAgICAg
IC5tZy1yb3cgewogICAgICAgICAgICBwYWRkaW5nOiA3cHggNnB4OyBtYXJnaW4tYm90dG9tOiAz
cHg7CiAgICAgICAgICAgIGJvcmRlci1yYWRpdXM6IDVweDsgY3Vyc29yOiBwb2ludGVyOwogICAg
ICAgICAgICBib3JkZXI6IDFweCBzb2xpZCB0cmFuc3BhcmVudDsKICAgICAgICAgICAgdHJhbnNp
dGlvbjogYmFja2dyb3VuZCAuMTJzIGVhc2UsIGJvcmRlci1jb2xvciAuMTJzIGVhc2U7CiAgICAg
ICAgfQogICAgICAgIC5tZy1yb3c6aG92ZXIgeyBiYWNrZ3JvdW5kOiB2YXIoLS1jYXJkLWgpOyB9
CiAgICAgICAgLm1nLXJvdy5zZWwgewogICAgICAgICAgICBiYWNrZ3JvdW5kOiAjZWRmMWZmOwog
ICAgICAgICAgICBib3JkZXItY29sb3I6IHJnYmEoOTEsMTE1LDIzMiwuMzUpOwogICAgICAgICAg
ICBib3gtc2hhZG93OiAwIDAgMCAxcHggcmdiYSg5MSwxMTUsMjMyLC4yNSk7CiAgICAgICAgfQog
ICAgICAgIC5tZy1yb3cubXVsdGkgewogICAgICAgICAgICBiYWNrZ3JvdW5kOiAjZWVmMmZmOwog
ICAgICAgICAgICBib3JkZXItY29sb3I6IHJnYmEoOTEsMTE1LDIzMiwuNDUpOwogICAgICAgIH0K
ICAgICAgICAubWctdGl0bGUgewogICAgICAgICAgICBmb250LXNpemU6IDEzcHg7IGZvbnQtd2Vp
Z2h0OiA2MDA7IGNvbG9yOiB2YXIoLS1hY2MpOwogICAgICAgICAgICBtYXJnaW4tYm90dG9tOiAy
cHg7IGxpbmUtaGVpZ2h0OiAxLjM1OwogICAgICAgICAgICBkaXNwbGF5OiAtd2Via2l0LWJveDsg
LXdlYmtpdC1ib3gtb3JpZW50OiB2ZXJ0aWNhbDsgLXdlYmtpdC1saW5lLWNsYW1wOiAyOwogICAg
ICAgICAgICBvdmVyZmxvdzogaGlkZGVuOyB3b3JkLWJyZWFrOiBicmVhay13b3JkOwogICAgICAg
IH0KICAgICAgICAubWctYm9keSB7CiAgICAgICAgICAgIGZvbnQtc2l6ZTogMTIuNXB4OyBmb250
LXdlaWdodDogNTAwOyBjb2xvcjogdmFyKC0tdHh0KTsKICAgICAgICAgICAgd2hpdGUtc3BhY2U6
IHByZS13cmFwOyB3b3JkLWJyZWFrOiBicmVhay1hbGw7CiAgICAgICAgICAgIGRpc3BsYXk6IC13
ZWJraXQtYm94OyAtd2Via2l0LWJveC1vcmllbnQ6IHZlcnRpY2FsOyAtd2Via2l0LWxpbmUtY2xh
bXA6IDQ7CiAgICAgICAgICAgIG92ZXJmbG93OiBoaWRkZW47IGxpbmUtaGVpZ2h0OiAxLjQ7CiAg
ICAgICAgfQogICAgICAgIC5tZy1ib2R5LmltZyB7IGNvbG9yOiB2YXIoLS10eHQyKTsgfQogICAg
ICAgIC5tZy1yb3ctdG9wIHsKICAgICAgICAgICAgZGlzcGxheTogZmxleDsgYWxpZ24taXRlbXM6
IGZsZXgtc3RhcnQ7IGdhcDogOHB4OwogICAgICAgIH0KICAgICAgICAubWctcm93LW1haW4geyBm
bGV4OiAxOyBtaW4td2lkdGg6IDA7IH0KICAgICAgICAubWctc3JjIHsKICAgICAgICAgICAgd2lk
dGg6IDE4cHg7IGhlaWdodDogMThweDsgZmxleC1zaHJpbms6IDA7IG1hcmdpbi10b3A6IDJweDsK
ICAgICAgICAgICAgYm9yZGVyLXJhZGl1czogM3B4OyBvYmplY3QtZml0OiBjb250YWluOwogICAg
ICAgICAgICBiYWNrZ3JvdW5kOiByZ2JhKDAsMCwwLC4wNCk7CiAgICAgICAgfQogICAgICAgIC5p
LWZhdi10aXRsZSB7CiAgICAgICAgICAgIGZvbnQtc2l6ZTogMTNweDsgZm9udC13ZWlnaHQ6IDYw
MDsgY29sb3I6IHZhcigtLWFjYyk7CiAgICAgICAgICAgIG1hcmdpbjogMCAwIDNweDsgbGluZS1o
ZWlnaHQ6IDEuMzU7CiAgICAgICAgICAgIGRpc3BsYXk6IC13ZWJraXQtYm94OyAtd2Via2l0LWJv
eC1vcmllbnQ6IHZlcnRpY2FsOyAtd2Via2l0LWxpbmUtY2xhbXA6IDI7CiAgICAgICAgICAgIG92
ZXJmbG93OiBoaWRkZW47IHdvcmQtYnJlYWs6IGJyZWFrLXdvcmQ7CiAgICAgICAgfQogICAgICAg
IC8qIOacgOi/ke+8muagh+mimOS4juiTneiJsui3r+W+hOauteWMuuWIhu+8iDpoYXMg5YWc5bqV
77yM6YG/5YWN5pen57yT5a2Y5ryPIGNsYXNz77yJICovCiAgICAgICAgLmktZmF2LXRpdGxlLnJm
LXRpdGxlLAogICAgICAgIC5pdG06aGFzKC5yZi1wYXRoKSA+IC5pLWJvZHkgPiAuaS1mYXYtdGl0
bGUsCiAgICAgICAgLml0bTpoYXMoLnJmLXBhdGgpIC5pLWZhdi10aXRsZSB7CiAgICAgICAgICAg
IGNvbG9yOiAjYjQ1MzA5ICFpbXBvcnRhbnQ7CiAgICAgICAgICAgIGZvbnQtd2VpZ2h0OiA3MDAg
IWltcG9ydGFudDsKICAgICAgICB9CiAgICAgICAgI3RpdGxlLWRsZyB7CiAgICAgICAgICAgIGRp
c3BsYXk6IG5vbmU7IHBvc2l0aW9uOiBmaXhlZDsgaW5zZXQ6IDA7IHotaW5kZXg6IDEwMDsKICAg
ICAgICAgICAgYmFja2dyb3VuZDogcmdiYSgxNSwxOCwyOCwuMzUpOwogICAgICAgICAgICBhbGln
bi1pdGVtczogY2VudGVyOyBqdXN0aWZ5LWNvbnRlbnQ6IGNlbnRlcjsKICAgICAgICAgICAgLXdl
YmtpdC1hcHAtcmVnaW9uOiBuby1kcmFnOyBhcHAtcmVnaW9uOiBuby1kcmFnOwogICAgICAgIH0K
ICAgICAgICAjdGl0bGUtZGxnLm9uIHsgZGlzcGxheTogZmxleDsgfQogICAgICAgICN0aXRsZS1k
bGcgLnRpdGxlLWJveCB7CiAgICAgICAgICAgIHdpZHRoOiAyNjBweDsgcGFkZGluZzogMTZweCAx
NnB4IDEycHg7CiAgICAgICAgICAgIGJhY2tncm91bmQ6IHZhcigtLWNhcmQpOyBib3JkZXItcmFk
aXVzOiAxMHB4OwogICAgICAgICAgICBib3gtc2hhZG93OiAwIDhweCAyOHB4IHJnYmEoMCwwLDAs
LjE4KTsKICAgICAgICAgICAgLXdlYmtpdC1hcHAtcmVnaW9uOiBuby1kcmFnOyBhcHAtcmVnaW9u
OiBuby1kcmFnOwogICAgICAgIH0KICAgICAgICAjdGl0bGUtaW5wdXQgewogICAgICAgICAgICB3
aWR0aDogMTAwJTsgYm94LXNpemluZzogYm9yZGVyLWJveDsgbWFyZ2luOiA4cHggMCAxMnB4Owog
ICAgICAgICAgICBoZWlnaHQ6IDMycHg7IHBhZGRpbmc6IDAgMTBweDsgYm9yZGVyLXJhZGl1czog
NnB4OwogICAgICAgICAgICBib3JkZXI6IDFweCBzb2xpZCAjZDVkYWU2OyBiYWNrZ3JvdW5kOiAj
ZmZmOyBjb2xvcjogdmFyKC0tdHh0KTsKICAgICAgICAgICAgZm9udC1zaXplOiAxM3B4OyBvdXRs
aW5lOiBub25lOwogICAgICAgICAgICAtd2Via2l0LWFwcC1yZWdpb246IG5vLWRyYWc7IGFwcC1y
ZWdpb246IG5vLWRyYWc7CiAgICAgICAgICAgIHVzZXItc2VsZWN0OiB0ZXh0OwogICAgICAgIH0K
ICAgICAgICAjdGl0bGUtaW5wdXQ6Zm9jdXMgeyBib3JkZXItY29sb3I6IHZhcigtLWFjYyk7IH0K
CiAgICAKICAgICAgICAvKiB1aS1ncmF5LWJnLXYxICovCiAgICAgICAgOnJvb3QgewogICAgICAg
ICAgICAtLWJnOiAjZTRlN2VlICFpbXBvcnRhbnQ7CiAgICAgICAgfQogICAgICAgIGh0bWwsIGJv
ZHkgewogICAgICAgICAgICBiYWNrZ3JvdW5kOiAjZTRlN2VlICFpbXBvcnRhbnQ7CiAgICAgICAg
fQogICAgICAgICNhcHAgewogICAgICAgICAgICBiYWNrZ3JvdW5kOiBsaW5lYXItZ3JhZGllbnQo
MTgwZGVnLCAjZTllY2YzIDAlLCAjZTBlNGVjIDEwMCUpICFpbXBvcnRhbnQ7CiAgICAgICAgfQog
ICAgICAgICNoZHIgewogICAgICAgICAgICBiYWNrZ3JvdW5kOiAjZTJlNmVlICFpbXBvcnRhbnQ7
CiAgICAgICAgfQogICAgICAgICN0YWJzIHsKICAgICAgICAgICAgYmFja2dyb3VuZDogI2UyZTZl
ZSAhaW1wb3J0YW50OwogICAgICAgIH0KICAgICAgICAjbGlzdCwgI2VtcHR5LCAjc2tlbCwgI2hk
ci1ncm93LCAjc2VhcmNoLXdyYXAgewogICAgICAgICAgICBiYWNrZ3JvdW5kOiB0cmFuc3BhcmVu
dCAhaW1wb3J0YW50OwogICAgICAgIH0KICAgICAgICAjc2VhcmNoLWJveCB7CiAgICAgICAgICAg
IHRyYW5zZm9ybS1vcmlnaW46IHJpZ2h0IGNlbnRlcjsKICAgICAgICAgICAgYmFja2dyb3VuZDog
dHJhbnNwYXJlbnQgIWltcG9ydGFudDsKICAgICAgICB9CiAgICAgICAgLml0bSwgLm1nLCAubWct
cm93LCAubWVyZ2UtZ3JvdXAgewogICAgICAgICAgICBiYWNrZ3JvdW5kOiAjZmZmZmZmICFpbXBv
cnRhbnQ7CiAgICAgICAgfQogICAgICAgIC5pdG06aG92ZXIgewogICAgICAgICAgICBiYWNrZ3Jv
dW5kOiAjZjhmOWZjICFpbXBvcnRhbnQ7CiAgICAgICAgfQogICAgCiAgICAgICAgLyogc2VsLXRp
bnQtYmx1ZS12MSAqLwogICAgICAgIC5pdG0uc2VsLAogICAgICAgIC5tZy1yb3cuc2VsLAogICAg
ICAgIC5pdG0ubXVsdGksCiAgICAgICAgLm1nLXJvdy5tdWx0aSwKICAgICAgICAuaXRtLm11bHRp
LnNlbCwKICAgICAgICAuaXQtZ3JvdXAuc2VsLAogICAgICAgIC5pdC1ncm91cC5tdWx0aSB7CiAg
ICAgICAgICAgIGJhY2tncm91bmQ6ICNlOGVmZmYgIWltcG9ydGFudDsKICAgICAgICB9CiAgICAg
ICAgLml0bS5zZWw6aG92ZXIsCiAgICAgICAgLml0bS5tdWx0aTpob3ZlciwKICAgICAgICAubWct
cm93LnNlbDpob3ZlciwKICAgICAgICAubWctcm93Lm11bHRpOmhvdmVyIHsKICAgICAgICAgICAg
YmFja2dyb3VuZDogI2RkZTZmZiAhaW1wb3J0YW50OwogICAgICAgIH0KICAgIAogICAgICAgIC8q
IGhvdmVyLWdyZWVuLXJpc2UtdjIgKi8KICAgICAgICAvKiBob3Zlci1hY2NlbnQtcmlzZS12MyAq
LwogICAgICAgIC5pdG06bm90KC5xLW1lbWJlcikgeyBwb3NpdGlvbjogcmVsYXRpdmUgIWltcG9y
dGFudDsgb3ZlcmZsb3c6IGhpZGRlbiAhaW1wb3J0YW50OyB9CiAgICAgICAgLml0bS5xLW1lbWJl
ciB7IHBvc2l0aW9uOiByZWxhdGl2ZSAhaW1wb3J0YW50OyBvdmVyZmxvdzogdmlzaWJsZSAhaW1w
b3J0YW50OyB9CiAgICAgICAgLml0bTo6YmVmb3JlIHsKICAgICAgICAgICAgY29udGVudDogIiIg
IWltcG9ydGFudDsKICAgICAgICAgICAgcG9zaXRpb246IGFic29sdXRlICFpbXBvcnRhbnQ7CiAg
ICAgICAgICAgIGxlZnQ6IDAgIWltcG9ydGFudDsgcmlnaHQ6IDAgIWltcG9ydGFudDsgYm90dG9t
OiAwICFpbXBvcnRhbnQ7CiAgICAgICAgICAgIGhlaWdodDogMCAhaW1wb3J0YW50OwogICAgICAg
ICAgICBwb2ludGVyLWV2ZW50czogbm9uZSAhaW1wb3J0YW50OwogICAgICAgICAgICB6LWluZGV4
OiAwICFpbXBvcnRhbnQ7CiAgICAgICAgICAgIGJvcmRlci1yYWRpdXM6IDAgMCB2YXIoLS1yLCA0
cHgpIHZhcigtLXIsIDRweCkgIWltcG9ydGFudDsKICAgICAgICAgICAgYmFja2dyb3VuZDogbGlu
ZWFyLWdyYWRpZW50KHRvIHRvcCwKICAgICAgICAgICAgICAgIHJnYmEoOTEsIDExNSwgMjMyLCAu
MzIpIDAlLAogICAgICAgICAgICAgICAgcmdiYSg5MSwgMTE1LCAyMzIsIC4xMikgNTUlLAogICAg
ICAgICAgICAgICAgcmdiYSg5MSwgMTE1LCAyMzIsIDApIDEwMCUpICFpbXBvcnRhbnQ7CiAgICAg
ICAgICAgIHRyYW5zaXRpb246IGhlaWdodCAuMzRzIGN1YmljLWJlemllciguMjIsIDEsIC4zNiwg
MSkgIWltcG9ydGFudDsKICAgICAgICB9CiAgICAgICAgLml0bTpob3Zlcjo6YmVmb3JlIHsgaGVp
Z2h0OiAzMy4zMzMlICFpbXBvcnRhbnQ7IH0KICAgICAgICAuaXRtOjphZnRlciB7CiAgICAgICAg
ICAgIGNvbnRlbnQ6ICIiICFpbXBvcnRhbnQ7CiAgICAgICAgICAgIHBvc2l0aW9uOiBhYnNvbHV0
ZSAhaW1wb3J0YW50OwogICAgICAgICAgICBsZWZ0OiAwICFpbXBvcnRhbnQ7IHJpZ2h0OiAwICFp
bXBvcnRhbnQ7IGJvdHRvbTogMCAhaW1wb3J0YW50OwogICAgICAgICAgICBoZWlnaHQ6IDJweCAh
aW1wb3J0YW50OwogICAgICAgICAgICBwb2ludGVyLWV2ZW50czogbm9uZSAhaW1wb3J0YW50Owog
ICAgICAgICAgICB6LWluZGV4OiAxICFpbXBvcnRhbnQ7CiAgICAgICAgICAgIGJhY2tncm91bmQ6
IHJnYmEoOTEsIDExNSwgMjMyLCAuOTIpICFpbXBvcnRhbnQ7CiAgICAgICAgICAgIGJvcmRlci1y
YWRpdXM6IDFweCAhaW1wb3J0YW50OwogICAgICAgICAgICB0cmFuc2Zvcm06IHNjYWxlWCgwKSAh
aW1wb3J0YW50OwogICAgICAgICAgICB0cmFuc2Zvcm0tb3JpZ2luOiBjZW50ZXIgIWltcG9ydGFu
dDsKICAgICAgICAgICAgdHJhbnNpdGlvbjogdHJhbnNmb3JtIC4zcyBjdWJpYy1iZXppZXIoLjIy
LCAxLCAuMzYsIDEpICFpbXBvcnRhbnQ7CiAgICAgICAgfQogICAgICAgIC5pdG06aG92ZXI6OmFm
dGVyIHsKICAgICAgICAgICAgdHJhbnNmb3JtOiBzY2FsZVgoMSkgIWltcG9ydGFudDsKICAgICAg
ICAgICAgYmFja2dyb3VuZDogcmdiYSg5MSwgMTE1LCAyMzIsIC45NSkgIWltcG9ydGFudDsKICAg
ICAgICB9CiAgICAgICAgLml0bSA+ICogeyBwb3NpdGlvbjogcmVsYXRpdmU7IHotaW5kZXg6IDI7
IH0KICAgICAgICAuaXRtLnEtbWVtYmVyID4gLnEtcmFpbCwKICAgICAgICAuaXRtLnEtbWVtYmVy
ID4gLnEtZG90IHsKICAgICAgICAgICAgcG9zaXRpb246IGFic29sdXRlICFpbXBvcnRhbnQ7CiAg
ICAgICAgICAgIHotaW5kZXg6IDYgIWltcG9ydGFudDsKICAgICAgICB9CiAgICAgICAgLyog5aSW
5qGG5pS555SxIFdpbjExIERXTSDmt6HngbDmj4/ovrnvvIjnm5bmu6HlnIbop5LvvInvvJvmraTl
pITlj6roo4HliIflhoXlrrkgKi8KICAgICAgICBodG1sLCBib2R5IHsKICAgICAgICAgICAgYm9y
ZGVyOiBub25lICFpbXBvcnRhbnQ7CiAgICAgICAgICAgIG91dGxpbmU6IG5vbmUgIWltcG9ydGFu
dDsKICAgICAgICAgICAgYm94LXNoYWRvdzogbm9uZSAhaW1wb3J0YW50OwogICAgICAgICAgICBi
b3JkZXItcmFkaXVzOiA4cHggIWltcG9ydGFudDsKICAgICAgICAgICAgb3ZlcmZsb3c6IGhpZGRl
biAhaW1wb3J0YW50OwogICAgICAgIH0KICAgICAgICAjYXBwIHsKICAgICAgICAgICAgYm9yZGVy
OiBub25lICFpbXBvcnRhbnQ7CiAgICAgICAgICAgIG91dGxpbmU6IG5vbmUgIWltcG9ydGFudDsK
ICAgICAgICAgICAgYm94LXNoYWRvdzogbm9uZSAhaW1wb3J0YW50OwogICAgICAgICAgICBib3Jk
ZXItcmFkaXVzOiA4cHggIWltcG9ydGFudDsKICAgICAgICAgICAgYm94LXNpemluZzogYm9yZGVy
LWJveCAhaW1wb3J0YW50OwogICAgICAgICAgICBvdmVyZmxvdzogaGlkZGVuICFpbXBvcnRhbnQ7
CiAgICAgICAgfQogICAgICAgIC5pdG0sIC5tZywgLm1lcmdlLWdyb3VwIHsKICAgICAgICAgICAg
Ym9yZGVyOiBub25lICFpbXBvcnRhbnQ7CiAgICAgICAgICAgIGJvcmRlci1yYWRpdXM6IDRweCAh
aW1wb3J0YW50OwogICAgICAgICAgICBib3gtc2hhZG93OgogICAgICAgICAgICAgICAgMCAxcHgg
MnB4IHJnYmEoMjQsIDMyLCA1NiwgLjA1KSwKICAgICAgICAgICAgICAgIDAgM3B4IDEwcHggcmdi
YSgyNCwgMzIsIDU2LCAuMDkpICFpbXBvcnRhbnQ7CiAgICAgICAgfQogICAgICAgIC5pdG06aG92
ZXIsIC5tZzpob3ZlciwgLm1lcmdlLWdyb3VwOmhvdmVyIHsKICAgICAgICAgICAgYm94LXNoYWRv
dzoKICAgICAgICAgICAgICAgIDAgMnB4IDRweCByZ2JhKDI0LCAzMiwgNTYsIC4wNyksCiAgICAg
ICAgICAgICAgICAwIDZweCAxNnB4IHJnYmEoMjQsIDMyLCA1NiwgLjEzKSAhaW1wb3J0YW50Owog
ICAgICAgIH0KICAgICAgICAuaXRtLnNlbCwKICAgICAgICAubWctcm93LnNlbCwKICAgICAgICAu
aXRtLm11bHRpLAogICAgICAgIC5tZy1yb3cubXVsdGksCiAgICAgICAgLml0bS5tdWx0aS5zZWws
CiAgICAgICAgLml0LWdyb3VwLnNlbCwKICAgICAgICAuaXQtZ3JvdXAubXVsdGkgewogICAgICAg
ICAgICBib3gtc2hhZG93OgogICAgICAgICAgICAgICAgMCAwIDAgMnB4IHJnYmEoOTEsIDExNSwg
MjMyLCAuNDIpLAogICAgICAgICAgICAgICAgMCAycHggNHB4IHJnYmEoOTEsIDExNSwgMjMyLCAu
MTApLAogICAgICAgICAgICAgICAgMCA2cHggMTRweCByZ2JhKDkxLCAxMTUsIDIzMiwgLjE2KSAh
aW1wb3J0YW50OwogICAgICAgIH0KICAgIDwvc3R5bGU+CjwvaGVhZD4KPGJvZHkgZGF0YS11aS1i
dWlsZD0iMjAyNjA5MTctZjItdGl0bGUiPgo8ZGl2IGlkPSJhcHAiIGRhdGEtdWktdmVyPSIyMDI2
MDkxOS1yZi1wYXRoLXdyYXAyIj4KICAgIDxkaXYgaWQ9ImhkciI+CiAgICAgICAgPGRpdiBpZD0i
aGVhcnQiPgogICAgICAgICAgICA8c3ZnIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0ibm9uZSIg
c3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0cm9rZS13aWR0aD0iMS44IgogICAgICAgICAgICAgICAg
IHN0cm9rZS1saW5lY2FwPSJyb3VuZCIgc3Ryb2tlLWxpbmVqb2luPSJyb3VuZCI+CiAgICAgICAg
ICAgICAgICA8cmVjdCB4PSI5IiB5PSIyIiB3aWR0aD0iNiIgaGVpZ2h0PSI0IiByeD0iMSIvPgog
ICAgICAgICAgICAgICAgPHBhdGggZD0iTTE2IDRoMmEyIDIgMCAwIDEgMiAydjE0YTIgMiAwIDAg
MS0yIDJINmEyIDIgMCAwIDEtMi0yVjZhMiAyIDAgMCAxIDItMmgyIi8+CiAgICAgICAgICAgICAg
ICA8cGF0aCBkPSJNOSAxMmg2TTkgMTZoNCIvPgogICAgICAgICAgICA8L3N2Zz4KICAgICAgICA8
L2Rpdj4KICAgICAgICA8ZGl2IGlkPSJoZHItZ3JvdyI+PC9kaXY+CiAgICAgICAgPGRpdiBpZD0i
bXVsdGktYmFyIj4KICAgICAgICAgICAgPGJ1dHRvbiBpZD0ibXVsdGktc2VsIiB0eXBlPSJidXR0
b24iIHRpdGxlPSLlj5bmtojlpJrpgIkiPgogICAgICAgICAgICAgICAgPHNwYW4gaWQ9Im11bHRp
LXNlbC1sYWIiPuW3sumAiTwvc3Bhbj4KICAgICAgICAgICAgICAgIDxzcGFuIGlkPSJtdWx0aS1j
bnQiPjA8L3NwYW4+CiAgICAgICAgICAgIDwvYnV0dG9uPgogICAgICAgICAgICA8ZGl2IGlkPSJw
YXN0ZS1zZXAtd3JhcCI+CiAgICAgICAgICAgICAgICA8YnV0dG9uIGlkPSJwYXN0ZS1zZXAtYnRu
IiB0eXBlPSJidXR0b24iIHRpdGxlPSLnspjotLTliIbpmpTnrKbvvIjngrnpgInnlKjlubbnspjo
tLTvvIkiPgogICAgICAgICAgICAgICAgICAgIDxzcGFuIGlkPSJwYXN0ZS1zZXAtbGFiZWwiPuKQ
ozwvc3Bhbj4KICAgICAgICAgICAgICAgIDwvYnV0dG9uPgogICAgICAgICAgICAgICAgPGRpdiBp
ZD0icGFzdGUtc2VwLW1lbnUiPjwvZGl2PgogICAgICAgICAgICA8L2Rpdj4KICAgICAgICA8L2Rp
dj4KICAgICAgICA8YnV0dG9uIGlkPSJidG4tbG9jYXRlIiB0eXBlPSJidXR0b24iIHRpdGxlPSLl
rprkvY3liLDkuIrmrKHkvb/nlKjnmoTmnaHnm64iIGRpc2FibGVkPgogICAgICAgICAgICA8c3Zn
IHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0
cm9rZS13aWR0aD0iMiIKICAgICAgICAgICAgICAgICBzdHJva2UtbGluZWNhcD0icm91bmQiIHN0
cm9rZS1saW5lam9pbj0icm91bmQiPgogICAgICAgICAgICAgICAgPGNpcmNsZSBjeD0iMTIiIGN5
PSIxMiIgcj0iOCIvPgogICAgICAgICAgICAgICAgPGNpcmNsZSBjeD0iMTIiIGN5PSIxMiIgcj0i
My41Ii8+CiAgICAgICAgICAgIDwvc3ZnPgogICAgICAgIDwvYnV0dG9uPgogICAgICAgIDxkaXYg
aWQ9InNlYXJjaC13cmFwIj4KICAgICAgICAgICAgPGJ1dHRvbiBpZD0iYnRuLXNlYXJjaCIgdHlw
ZT0iYnV0dG9uIiB0aXRsZT0i5pCc57SiIj4KICAgICAgICAgICAgICAgIDxzdmcgdmlld0JveD0i
MCAwIDI0IDI0IiBmaWxsPSJub25lIiBzdHJva2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRo
PSIyIgogICAgICAgICAgICAgICAgICAgICBzdHJva2UtbGluZWNhcD0icm91bmQiIHN0cm9rZS1s
aW5lam9pbj0icm91bmQiPgogICAgICAgICAgICAgICAgICAgIDxjaXJjbGUgY3g9IjExIiBjeT0i
MTEiIHI9IjciLz4KICAgICAgICAgICAgICAgICAgICA8cGF0aCBkPSJNMjAgMjBsLTMuNS0zLjUi
Lz4KICAgICAgICAgICAgICAgIDwvc3ZnPgogICAgICAgICAgICA8L2J1dHRvbj4KICAgICAgICAg
ICAgPGRpdiBpZD0ic2VhcmNoLWJveCI+CiAgICAgICAgICAgICAgICA8YnV0dG9uIGlkPSJidG4t
dG9kYXkiIHR5cGU9ImJ1dHRvbiI+5b2T5aSpPC9idXR0b24+CiAgICAgICAgICAgICAgICA8aW5w
dXQgaWQ9InNlYXJjaCIgdHlwZT0idGV4dCIgcGxhY2Vob2xkZXI9IuaQnOe0ouKApiDnqbrmoLzl
iIbor43pobvlkIzml7bljIXlkKsgwrcgYXxiIOWIhuautSIgYXV0b2NvbXBsZXRlPSJvZmYiIHNw
ZWxsY2hlY2s9ImZhbHNlIj4KICAgICAgICAgICAgICAgIDxidXR0b24gaWQ9InNlYXJjaC1jbHIi
IHR5cGU9ImJ1dHRvbiI+4pyVPC9idXR0b24+CiAgICAgICAgICAgIDwvZGl2PgogICAgICAgIDwv
ZGl2PgogICAgICAgIDxidXR0b24gaWQ9ImJ0bi1waW4iIHR5cGU9ImJ1dHRvbiIgdGl0bGU9IumS
ieWcqOWxj+W5leS4iiI+CiAgICAgICAgICAgIDxzdmcgdmlld0JveD0iMCAwIDI0IDI0IiBmaWxs
PSJub25lIiBzdHJva2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIyIgogICAgICAgICAg
ICAgICAgIHN0cm9rZS1saW5lam9pbj0icm91bmQiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCI+CiAg
ICAgICAgICAgICAgICA8bGluZSB4MT0iMTIiIHkxPSIxNyIgeDI9IjEyIiB5Mj0iMjIiLz4KICAg
ICAgICAgICAgICAgIDxwYXRoIGQ9Ik01IDE3aDE0di0xLjc2YTIgMiAwIDAgMC0xLjExLTEuNzls
LTEuNzgtLjlBMiAyIDAgMCAxIDE1IDEwLjc2VjZoMWEyIDIgMCAwIDAgMC00SDhhMiAyIDAgMCAw
IDAgNGgxdjQuNzZhMiAyIDAgMCAxLTEuMTEgMS43OWwtMS43OC45QTIgMiAwIDAgMCA1IDE1LjI0
WiIvPgogICAgICAgICAgICA8L3N2Zz4KICAgICAgICA8L2J1dHRvbj4KICAgIDwvZGl2PgoKICAg
IDxkaXYgaWQ9InRhYnMiPgogICAgICAgIDxkaXYgaWQ9InRhYi1pbmsiIGFyaWEtaGlkZGVuPSJ0
cnVlIj48L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJ0YWIgb24iIGRhdGEtdGFiPSJhbGwiPuWF
qOmDqDwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9InRhYiIgZGF0YS10YWI9InRleHQiPuaWh+ac
rDwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9InRhYiIgZGF0YS10YWI9ImltYWdlIj7lm77lg488
L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJ0YWIiIGRhdGEtdGFiPSJmaWxlIj7mlofku7Y8L2Rp
dj4KICAgICAgICA8ZGl2IGNsYXNzPSJ0YWIiIGRhdGEtdGFiPSJyZWNlbnQiPuacgOi/kTwvZGl2
PgogICAgICAgIDxkaXYgY2xhc3M9InRhYiIgZGF0YS10YWI9InBpbm5lZCI+5pS26JePIDxzcGFu
IGlkPSJwaW4tZG90IiB0aXRsZT0i5pyJ5paw5pS26JePIj48L3NwYW4+PC9kaXY+CiAgICAgICAg
PGRpdiBpZD0idGFiLWFjdGlvbnMiPgogICAgICAgICAgICA8c3BhbiBpZD0iYmFyLXR4dCI+MDwv
c3Bhbj4KICAgICAgICAgICAgPGJ1dHRvbiBpZD0iYnRuLWNsciIgdHlwZT0iYnV0dG9uIiB0aXRs
ZT0i5riF56m65Y6G5Y+yIj4KICAgICAgICAgICAgICAgIDxzdmcgdmlld0JveD0iMCAwIDI0IDI0
IiBmaWxsPSJub25lIiBzdHJva2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIyIgogICAg
ICAgICAgICAgICAgICAgICBzdHJva2UtbGluZWNhcD0icm91bmQiIHN0cm9rZS1saW5lam9pbj0i
cm91bmQiPgogICAgICAgICAgICAgICAgICAgIDxwb2x5bGluZSBwb2ludHM9IjMgNiA1IDYgMjEg
NiIvPgogICAgICAgICAgICAgICAgICAgIDxwYXRoIGQ9Ik0xOSA2bC0xIDE0YTIgMiAwIDAgMS0y
IDJIOGEyIDIgMCAwIDEtMi0yTDUgNiIvPgogICAgICAgICAgICAgICAgICAgIDxwYXRoIGQ9Ik0x
MCAxMXY2TTE0IDExdjZNOSA2VjRoNnYyIi8+CiAgICAgICAgICAgICAgICA8L3N2Zz4KICAgICAg
ICAgICAgPC9idXR0b24+CiAgICAgICAgPC9kaXY+CiAgICA8L2Rpdj4KCiAgICA8ZGl2IGlkPSJs
aXN0Ij4KICAgICAgICA8ZGl2IGlkPSJza2VsIiBhcmlhLWhpZGRlbj0idHJ1ZSI+CiAgICAgICAg
ICAgIDxkaXYgY2xhc3M9InNrLXJvdyI+PGRpdiBjbGFzcz0ic2staWNvIj48L2Rpdj48ZGl2IGNs
YXNzPSJzay1ib2R5Ij48ZGl2IGNsYXNzPSJzay1saW5lIG1pZCI+PC9kaXY+PGRpdiBjbGFzcz0i
c2stbGluZSBzaG9ydCI+PC9kaXY+PC9kaXY+PC9kaXY+CiAgICAgICAgICAgIDxkaXYgY2xhc3M9
InNrLXJvdyI+PGRpdiBjbGFzcz0ic2staWNvIj48L2Rpdj48ZGl2IGNsYXNzPSJzay1ib2R5Ij48
ZGl2IGNsYXNzPSJzay1saW5lIj48L2Rpdj48ZGl2IGNsYXNzPSJzay1saW5lIG1pZCI+PC9kaXY+
PC9kaXY+PC9kaXY+CiAgICAgICAgICAgIDxkaXYgY2xhc3M9InNrLXJvdyI+PGRpdiBjbGFzcz0i
c2staWNvIj48L2Rpdj48ZGl2IGNsYXNzPSJzay1ib2R5Ij48ZGl2IGNsYXNzPSJzay1saW5lIG1p
ZCI+PC9kaXY+PGRpdiBjbGFzcz0ic2stbGluZSBzaG9ydCI+PC9kaXY+PC9kaXY+PC9kaXY+CiAg
ICAgICAgICAgIDxkaXYgY2xhc3M9InNrLXJvdyI+PGRpdiBjbGFzcz0ic2staWNvIj48L2Rpdj48
ZGl2IGNsYXNzPSJzay1ib2R5Ij48ZGl2IGNsYXNzPSJzay1saW5lIj48L2Rpdj48ZGl2IGNsYXNz
PSJzay1saW5lIG1pZCI+PC9kaXY+PC9kaXY+PC9kaXY+CiAgICAgICAgICAgIDxkaXYgY2xhc3M9
InNrLXJvdyI+PGRpdiBjbGFzcz0ic2staWNvIj48L2Rpdj48ZGl2IGNsYXNzPSJzay1ib2R5Ij48
ZGl2IGNsYXNzPSJzay1saW5lIG1pZCI+PC9kaXY+PGRpdiBjbGFzcz0ic2stbGluZSBzaG9ydCI+
PC9kaXY+PC9kaXY+PC9kaXY+CiAgICAgICAgICAgIDxkaXYgY2xhc3M9InNrLXJvdyI+PGRpdiBj
bGFzcz0ic2staWNvIj48L2Rpdj48ZGl2IGNsYXNzPSJzay1ib2R5Ij48ZGl2IGNsYXNzPSJzay1s
aW5lIj48L2Rpdj48ZGl2IGNsYXNzPSJzay1saW5lIHNob3J0Ij48L2Rpdj48L2Rpdj48L2Rpdj4K
ICAgICAgICA8L2Rpdj4KICAgICAgICA8ZGl2IGlkPSJlbXB0eSI+CiAgICAgICAgICAgIDxkaXYg
Y2xhc3M9ImUtdHh0IiBpZD0iZW1wdHktdHh0Ij7mmoLml6DorrDlvZXvvIzlpI3liLblkI7oh6rl
iqjlh7rnjrA8L2Rpdj4KICAgICAgICA8L2Rpdj4KICAgIDwvZGl2PgogICAgPGJ1dHRvbiBpZD0i
YnRuLXRvcCIgdHlwZT0iYnV0dG9uIiB0aXRsZT0i5Zue5Yiw6aG26YOoIiBhcmlhLWxhYmVsPSLl
m57liLDpobbpg6giPgogICAgICAgIDxzdmcgdmlld0JveD0iMCAwIDI0IDI0IiBmaWxsPSJub25l
IiBzdHJva2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIyLjIiCiAgICAgICAgICAgICBz
dHJva2UtbGluZWNhcD0icm91bmQiIHN0cm9rZS1saW5lam9pbj0icm91bmQiPgogICAgICAgICAg
ICA8cGF0aCBkPSJNMTIgMTlWNSIvPgogICAgICAgICAgICA8cGF0aCBkPSJNNSAxMmw3LTcgNyA3
Ii8+CiAgICAgICAgPC9zdmc+CiAgICA8L2J1dHRvbj4KPC9kaXY+Cgo8ZGl2IGlkPSJjdHgiPgog
ICAgPGRpdiBjbGFzcz0iYy1pdGVtIiBpZD0iYy1jb3B5Ij48c3BhbiBjbGFzcz0iYy1pY28iPuKO
mDwvc3Bhbj7lpI3liLY8L2Rpdj4KICAgIDxkaXYgY2xhc3M9ImMtaXRlbSIgaWQ9ImMtcGFzdGUi
PjxzcGFuIGNsYXNzPSJjLWljbyI+4o+OPC9zcGFuPueymOi0tDwvZGl2PgogICAgPGRpdiBjbGFz
cz0iYy1zZXAiIGlkPSJjLWRhdGEtc2VwIiBzdHlsZT0iZGlzcGxheTpub25lIj48L2Rpdj4KICAg
IDxkaXYgY2xhc3M9ImMtc3Vid3JhcCIgaWQ9ImMtZGF0YS13cmFwIiBzdHlsZT0iZGlzcGxheTpu
b25lIj4KICAgICAgICA8ZGl2IGNsYXNzPSJjLWl0ZW0iIGlkPSJjLWRhdGEiPjxzcGFuIGNsYXNz
PSJjLWljbyI+zqM8L3NwYW4+5pWw5o2u5aSE55CGPHNwYW4gY2xhc3M9ImMtY2FyZXQiPuKAujwv
c3Bhbj48L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJjLXN1YiIgaWQ9ImMtZGF0YS1zdWIiPgog
ICAgICAgICAgICA8ZGl2IGNsYXNzPSJjLWl0ZW0iIGlkPSJjLWRhdGEtYnJhY2UiIHRpdGxlPSJ7
YSxifSAvIGEsYiDihpIgU1FMIj4KICAgICAgICAgICAgICAgIDxzcGFuIGNsYXNzPSJjLW51bSI+
MTwvc3Bhbj48c3BhbiBjbGFzcz0iYy1mcm9tIj57YSxifTwvc3Bhbj48c3BhbiBjbGFzcz0iYy1h
cnJvdyI+4oaSPC9zcGFuPjxzcGFuIGNsYXNzPSJjLXRvIj4oJ2EnLCdiJyk8L3NwYW4+CiAgICAg
ICAgICAgIDwvZGl2PgogICAgICAgICAgICA8ZGl2IGNsYXNzPSJjLWl0ZW0iIGlkPSJjLWRhdGEt
bGluZXMiIHRpdGxlPSLmjaLooYzliIbpmpQg4oaSIFNRTCI+CiAgICAgICAgICAgICAgICA8c3Bh
biBjbGFzcz0iYy1udW0iPjI8L3NwYW4+PHNwYW4gY2xhc3M9ImMtZnJvbSI+YSBcbiBiPC9zcGFu
PjxzcGFuIGNsYXNzPSJjLWFycm93Ij7ihpI8L3NwYW4+PHNwYW4gY2xhc3M9ImMtdG8iPignYScs
J2InKTwvc3Bhbj4KICAgICAgICAgICAgPC9kaXY+CiAgICAgICAgICAgIDxkaXYgY2xhc3M9ImMt
aXRlbSIgaWQ9ImMtZGF0YS1qc29uIiB0aXRsZT0iSlNPTiDljrvovazkuYnvvJpcJnF1b3Q7IOKG
kiAmcXVvdDsiPgogICAgICAgICAgICAgICAgPHNwYW4gY2xhc3M9ImMtbnVtIj4zPC9zcGFuPjxz
cGFuIGNsYXNzPSJjLWZyb20iPmpzb24gICZxdW90O1wmcXVvdDs8L3NwYW4+PHNwYW4gY2xhc3M9
ImMtYXJyb3ciPuKGkjwvc3Bhbj48c3BhbiBjbGFzcz0iYy10byI+JnF1b3Q7ICZxdW90Ozwvc3Bh
bj4KICAgICAgICAgICAgPC9kaXY+CiAgICAgICAgPC9kaXY+CiAgICA8L2Rpdj4KICAgIDxkaXYg
Y2xhc3M9ImMtc2VwIj48L2Rpdj4KICAgIDxkaXYgY2xhc3M9ImMtaXRlbSIgaWQ9ImMtcGluIj48
c3BhbiBjbGFzcz0iYy1pY28iPuKYhTwvc3Bhbj7mlLbol488L2Rpdj4KICAgIDxkaXYgY2xhc3M9
ImMtaXRlbSIgaWQ9ImMtdGl0bGUiIHN0eWxlPSJkaXNwbGF5Om5vbmUiPjxzcGFuIGNsYXNzPSJj
LWljbyI+4pyOPC9zcGFuPuiuvue9ruagh+mimDwvZGl2PgogICAgPGRpdiBjbGFzcz0iYy1pdGVt
IiBpZD0iYy1tZXJnZSIgc3R5bGU9ImRpc3BsYXk6bm9uZSI+PHNwYW4gY2xhc3M9ImMtaWNvIj7i
p4k8L3NwYW4+5ZCI5bm2PC9kaXY+CiAgICA8ZGl2IGNsYXNzPSJjLWl0ZW0iIGlkPSJjLXVubWVy
Z2UiIHN0eWxlPSJkaXNwbGF5Om5vbmUiPjxzcGFuIGNsYXNzPSJjLWljbyI+4oeEPC9zcGFuPuWP
lua2iOWQiOW5tjwvZGl2PgogICAgPGRpdiBjbGFzcz0iYy1pdGVtIiBpZD0iYy10b3AiPjxzcGFu
IGNsYXNzPSJjLWljbyI+4oaRPC9zcGFuPuenu+WIsOmhtumDqDwvZGl2PgogICAgPGRpdiBjbGFz
cz0iYy1pdGVtIiBpZD0iYy1jbGVhci1wYXN0ZWQiIHN0eWxlPSJkaXNwbGF5Om5vbmUiPjxzcGFu
IGNsYXNzPSJjLWljbyI+4pyTPC9zcGFuPua4hemZpOeKtuaAgTwvZGl2PgogICAgPGRpdiBjbGFz
cz0iYy1pdGVtIiBpZD0iYy1xdWV1ZS1mcm9tIiBzdHlsZT0iZGlzcGxheTpub25lIj48c3BhbiBj
bGFzcz0iYy1pY28iPuKGuzwvc3Bhbj7ku47mraTlpITlvIDlp4vpmJ/liJc8L2Rpdj4KICAgIDxk
aXYgY2xhc3M9ImMtaXRlbSIgaWQ9ImMtcXVldWUtaW4iIHN0eWxlPSJkaXNwbGF5Om5vbmUiPjxz
cGFuIGNsYXNzPSJjLWljbyI+4oeJPC9zcGFuPuWKoOWFpeeymOi0tOmYn+WIlzwvZGl2PgogICAg
PGRpdiBjbGFzcz0iYy1pdGVtIiBpZD0iYy1xdWV1ZS1vdXQiIHN0eWxlPSJkaXNwbGF5Om5vbmUi
PjxzcGFuIGNsYXNzPSJjLWljbyI+4oeHPC9zcGFuPuenu+WHuueymOi0tOmYn+WIlzwvZGl2Pgog
ICAgPGRpdiBjbGFzcz0iYy1zZXAiPjwvZGl2PgogICAgPGRpdiBjbGFzcz0iYy1pdGVtIGRhbmdl
ciIgaWQ9ImMtZGVsIj48c3BhbiBjbGFzcz0iYy1pY28iPuKclTwvc3Bhbj7liKDpmaQ8L2Rpdj4K
PC9kaXY+Cgo8ZGl2IGlkPSJjbHItZGxnIj4KICAgIDxkaXYgY2xhc3M9ImNsci1ib3giIHJvbGU9
ImRpYWxvZyIgYXJpYS1tb2RhbD0idHJ1ZSI+CiAgICAgICAgPGRpdiBjbGFzcz0iY2xyLXRpdGxl
IiBpZD0iY2xyLXRpdGxlIj7noa7orqTmuIXnqbrvvJ88L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNz
PSJjbHItZGVzYyIgaWQ9ImNsci1kZXNjIj7pu5jorqTku4XmuIXnqbrlvZPlpKnlhoXlrrnjgII8
L2Rpdj4KICAgICAgICA8bGFiZWwgY2xhc3M9ImNsci1jaGVjayIgZm9yPSJjbHItYWxsIj4KICAg
ICAgICAgICAgPGlucHV0IHR5cGU9ImNoZWNrYm94IiBpZD0iY2xyLWFsbCI+CiAgICAgICAgICAg
IDxzcGFuPua4heepuuaJgOaciTwvc3Bhbj4KICAgICAgICA8L2xhYmVsPgogICAgICAgIDxkaXYg
Y2xhc3M9ImNsci1idG5zIj4KICAgICAgICAgICAgPGJ1dHRvbiB0eXBlPSJidXR0b24iIGlkPSJj
bHItY2FuY2VsIj7lj5bmtog8L2J1dHRvbj4KICAgICAgICAgICAgPGJ1dHRvbiB0eXBlPSJidXR0
b24iIGlkPSJjbHItb2siPua4heepujwvYnV0dG9uPgogICAgICAgIDwvZGl2PgogICAgPC9kaXY+
CjwvZGl2PgoKPGRpdiBpZD0idGl0bGUtZGxnIj4KICAgIDxkaXYgY2xhc3M9InRpdGxlLWJveCIg
cm9sZT0iZGlhbG9nIiBhcmlhLW1vZGFsPSJ0cnVlIj4KICAgICAgICA8ZGl2IGNsYXNzPSJjbHIt
dGl0bGUiPuiuvue9ruagh+mimDwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9ImNsci1kZXNjIj7m
oIfpopjlj6/ooqvmkJzntKLmib7liLDvvJvmnIDov5Hot6/lvoTkuI7mlLbol4/pg73lj6/nlKjj
gII8L2Rpdj4KICAgICAgICA8aW5wdXQgaWQ9InRpdGxlLWlucHV0IiB0eXBlPSJ0ZXh0IiBtYXhs
ZW5ndGg9IjgwIiBwbGFjZWhvbGRlcj0i57uZ6L+Z5p2h5pS26JeP6LW35Liq5ZCN5a2X4oCmIiBh
dXRvY29tcGxldGU9Im9mZiIgc3BlbGxjaGVjaz0iZmFsc2UiPgogICAgICAgIDxkaXYgY2xhc3M9
ImNsci1idG5zIj4KICAgICAgICAgICAgPGJ1dHRvbiB0eXBlPSJidXR0b24iIGlkPSJ0aXRsZS1j
YW5jZWwiPuWPlua2iDwvYnV0dG9uPgogICAgICAgICAgICA8YnV0dG9uIHR5cGU9ImJ1dHRvbiIg
aWQ9InRpdGxlLW9rIj7kv53lrZg8L2J1dHRvbj4KICAgICAgICA8L2Rpdj4KICAgIDwvZGl2Pgo8
L2Rpdj4KPGRpdiBpZD0icGF0aC10aXAiIGFyaWEtaGlkZGVuPSJ0cnVlIj48L2Rpdj4KCjxzY3Jp
cHQ+Ci8qIOemgeatoiBDdHJsK+a7mui9rue8qeaUvu+8iFdlYlZpZXcg6K6+572uICsg6aG16Z2i
5YWc5bqV77yJICovCihmdW5jdGlvbigpewogIGNvbnN0IGJsb2NrWm9vbSA9IGUgPT4gewogICAg
aWYgKGUuY3RybEtleSB8fCBlLm1ldGFLZXkpIHsKICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOwog
ICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgfQogIH07CiAgd2luZG93LmFkZEV2ZW50TGlz
dGVuZXIoJ3doZWVsJywgYmxvY2tab29tLCB7IHBhc3NpdmU6IGZhbHNlLCBjYXB0dXJlOiB0cnVl
IH0pOwogIHdpbmRvdy5hZGRFdmVudExpc3RlbmVyKCdnZXN0dXJlc3RhcnQnLCBlID0+IGUucHJl
dmVudERlZmF1bHQoKSwgeyBwYXNzaXZlOiBmYWxzZSwgY2FwdHVyZTogdHJ1ZSB9KTsKICBkb2N1
bWVudC5hZGRFdmVudExpc3RlbmVyKCdrZXlkb3duJywgZSA9PiB7CiAgICBpZiAoIShlLmN0cmxL
ZXkgfHwgZS5tZXRhS2V5KSkgcmV0dXJuOwogICAgaWYgKGUua2V5ID09PSAnKycgfHwgZS5rZXkg
PT09ICctJyB8fCBlLmtleSA9PT0gJz0nIHx8IGUua2V5ID09PSAnXycKICAgICAgICB8fCBlLmNv
ZGUgPT09ICdOdW1wYWRBZGQnIHx8IGUuY29kZSA9PT0gJ051bXBhZFN1YnRyYWN0JwogICAgICAg
IHx8IGUua2V5ID09PSAnMCcpIHsKICAgICAgLy8gYWxsb3cgbm90aGluZyBmb3Igem9vbTsgQ3Ry
bCswIC8gwrEKICAgICAgaWYgKGUua2V5ID09PSAnMCcgfHwgZS5rZXkgPT09ICcrJyB8fCBlLmtl
eSA9PT0gJy0nIHx8IGUua2V5ID09PSAnPScgfHwgZS5rZXkgPT09ICdfJwogICAgICAgICAgfHwg
ZS5jb2RlID09PSAnTnVtcGFkQWRkJyB8fCBlLmNvZGUgPT09ICdOdW1wYWRTdWJ0cmFjdCcpIHsK
ICAgICAgICBlLnByZXZlbnREZWZhdWx0KCk7CiAgICAgIH0KICAgIH0KICB9LCB0cnVlKTsKfSko
KTsKPC9zY3JpcHQ+CjxzY3JpcHQ+Ci8qIHNrZWwtZmFpbHNhZmU6IG9ubHkgaWYgbWFpbiBVSSBz
Y3JpcHQgbmV2ZXIgYm9vdGVkIOKAlG5ldmVyIGludmVudCBlbXB0eS1zdGF0ZSAqLwooZnVuY3Rp
b24oKXsKICBzZXRUaW1lb3V0KCgpID0+IHsKICAgIHRyeSB7CiAgICAgIGlmICh3aW5kb3cuX191
aUJvb3RlZCkgcmV0dXJuOwogICAgICB2YXIgYXBwID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQo
J2FwcCcpOwogICAgICBpZiAoYXBwKSBhcHAuY2xhc3NMaXN0LnJlbW92ZSgnYm9vdC1sb2FkaW5n
Jyk7CiAgICAgIHZhciBzID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NrZWwnKTsKICAgICAg
aWYgKHMpIHMuY2xhc3NMaXN0LnJlbW92ZSgnb24nKTsKICAgIH0gY2F0Y2ggKGVycikge30KICB9
LCAzMDAwKTsKfSkoKTsKPC9zY3JpcHQ+CjxzY3JpcHQ+CiAgICBsZXQgYWxsQ2xpcHMgPSBbXSwg
Y3VyVGFiID0gJ2FsbCcsIHF1ZXJ5ID0gJycsIGN0eENsaXAgPSBudWxsLCBzZWxlY3RlZElkID0g
MCwgcGlubmVkVUkgPSBmYWxzZTsKICAgIGNvbnN0IFRBQl9PUkRFUiA9IFsnYWxsJywgJ3RleHQn
LCAnaW1hZ2UnLCAnZmlsZScsICdyZWNlbnQnLCAncGlubmVkJ107CiAgICBjb25zdCB2aWV3TWVt
ID0gbmV3IE1hcCgpOwogICAgZnVuY3Rpb24gdmlld01lbUtleSh0YWIsIHEsIHRvZGF5KSB7CiAg
ICAgICAgcmV0dXJuIFN0cmluZyh0YWIgfHwgJ2FsbCcpICsgJ1x0JyArIFN0cmluZyhxIHx8ICcn
KSArICdcdCcgKyAodG9kYXkgPyAnMScgOiAnMCcpOwogICAgfQogICAgbGV0IHRhYlN3aXRjaEFu
aW1EaXIgPSAwOwogICAgbGV0IG11bHRpSWRzID0gW107CiAgICBsZXQgdG9kYXlPbmx5ID0gZmFs
c2U7CiAgICBsZXQgZGlza1RvdGFsID0gMDsKICAgIGxldCBsb2FkaW5nTW9yZSA9IGZhbHNlOwog
ICAgLy8gRG9uJ3Qgc2hvdyBza2VsZXRvbiBpbW1lZGlhdGVseSDigJRvbmx5IGFmdGVyIFNLRUxf
REVMQVlfTVMgaWYgZGF0YSBzdGlsbCBtaXNzaW5nCiAgICBsZXQgYm9vdExvYWRpbmcgPSBmYWxz
ZTsKICAgIGxldCB3YWl0aW5nRGF0YSA9IGZhbHNlOwogICAgbGV0IGhvc3RQdXNoZWRPbmNlID0g
ZmFsc2U7IC8vIG9ubHkgdGhlbiBtYXkgc2hvd+OAjOaaguaXoOiusOW9leOAjQogICAgbGV0IHNh
d05vbkVtcHR5ID0gZmFsc2U7ICAgIC8vIGlnbm9yZSBib290c3RyYXAgZW1wdHkgcHVzaGVzIGJl
Zm9yZSBmaXJzdCByZWFsIGxpc3QKICAgIGxldCBwaW5uZWRUb3RhbCA9IDA7ICAgICAgICAvLyBh
dXRob3JpdGF0aXZlIOaUtuiXjyBjb3VudCBmcm9tIEFISwogICAgbGV0IHVuc2VlbkZhdklkcyA9
IG5ldyBTZXQoKTsKICAgIHRyeSB7CiAgICAgICAgY29uc3QgcmF3ID0gbG9jYWxTdG9yYWdlLmdl
dEl0ZW0oJ2NsaXBfdW5zZWVuX2ZhdicpOwogICAgICAgIGlmIChyYXcpIEpTT04ucGFyc2UocmF3
KS5mb3JFYWNoKGlkID0+IHsgaWQgPSAraWQ7IGlmIChpZCkgdW5zZWVuRmF2SWRzLmFkZChpZCk7
IH0pOwogICAgfSBjYXRjaCB7fQogICAgZnVuY3Rpb24gc2F2ZVVuc2VlbkZhdigpIHsKICAgICAg
ICB0cnkgeyBsb2NhbFN0b3JhZ2Uuc2V0SXRlbSgnY2xpcF91bnNlZW5fZmF2JywgSlNPTi5zdHJp
bmdpZnkoWy4uLnVuc2VlbkZhdklkc10pKTsgfSBjYXRjaCB7fQogICAgfQogICAgZnVuY3Rpb24g
dXBkYXRlUGluRG90KCkgewogICAgICAgIGNvbnN0IGVsID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5
SWQoJ3Bpbi1kb3QnKTsKICAgICAgICBpZiAoIWVsKSByZXR1cm47CiAgICAgICAgZWwuY2xhc3NM
aXN0LnRvZ2dsZSgnb24nLCB1bnNlZW5GYXZJZHMuc2l6ZSA+IDApOwogICAgfQogICAgZnVuY3Rp
b24gbWFya0ZhdlVuc2VlbihpZCkgewogICAgICAgIGlkID0gK2lkOwogICAgICAgIGlmICghaWQp
IHJldHVybjsKICAgICAgICB1bnNlZW5GYXZJZHMuYWRkKGlkKTsKICAgICAgICBzYXZlVW5zZWVu
RmF2KCk7CiAgICAgICAgdXBkYXRlUGluRG90KCk7CiAgICB9CiAgICBmdW5jdGlvbiBjbGVhckZh
dlVuc2VlbigpIHsKICAgICAgICBpZiAoIXVuc2VlbkZhdklkcy5zaXplKSB7CiAgICAgICAgICAg
IHVwZGF0ZVBpbkRvdCgpOwogICAgICAgICAgICByZXR1cm47CiAgICAgICAgfQogICAgICAgIHVu
c2VlbkZhdklkcy5jbGVhcigpOwogICAgICAgIHNhdmVVbnNlZW5GYXYoKTsKICAgICAgICB1cGRh
dGVQaW5Eb3QoKTsKICAgIH0KICAgIGNvbnN0IFNLRUxfREVMQVlfTVMgPSA2MDsKICAgIHdpbmRv
dy5fX2RhdGFSZWFkeSA9IGZhbHNlOwogICAgd2luZG93Ll9fdWlCb290ZWQgPSB0cnVlOwogICAg
Ly8gT3BlbiBwYW5lbCB3aXRob3V0IHBhc3Rpbmcg4oaSIGFsd2F5cyBsYW5kIG9uIGZpcnN0IGl0
ZW0gKGFmdGVyIGRhdGEgYXJyaXZlcykKICAgIGxldCBzZWxlY3RGaXJzdE9uU2hvdyA9IGZhbHNl
OwogICAgbGV0IGxhc3RQYXN0ZUlkID0gMDsKICAgIGxldCBsYXN0UGFzdGVUYWIgPSAnYWxsJzsK
ICAgIGxldCBsb2NhdGVBY3RpdmUgPSBmYWxzZTsKICAgIHRyeSB7IGxhc3RQYXN0ZUlkID0gK2xv
Y2FsU3RvcmFnZS5nZXRJdGVtKCdjbGlwTGFzdFBhc3RlSWQnKSB8fCAwOyB9IGNhdGNoIHt9CiAg
ICB0cnkgewogICAgICAgIGNvbnN0IHQgPSBsb2NhbFN0b3JhZ2UuZ2V0SXRlbSgnY2xpcExhc3RQ
YXN0ZVRhYicpIHx8ICdhbGwnOwogICAgICAgIGxhc3RQYXN0ZVRhYiA9IFsnYWxsJywndGV4dCcs
J2ltYWdlJywnZmlsZScsJ3Bpbm5lZCddLmluY2x1ZGVzKHQpID8gdCA6ICdhbGwnOwogICAgfSBj
YXRjaCB7fQogICAgLy8gUHJlZmVyIHNhbWUtb3JpZ2luIHVuZGVyIGNsaXB1aS5hcHAgKEFQUF9I
T1NUIOKGkiBDTElQX1YxX0RJUi9jbGlwc19zdG9yZSkuCiAgICAvLyDli7/nlKggKi5sb2NhbO+8
muezu+e7nyBtRE5TIOS8muWNoSAy4oCTM3PjgIJjbGlwcy5zdG9yZSDku4XkvZwgZmFsbGJhY2vj
gIIKICAgIGNvbnN0IFNUT1JFX0JBU0UgPSAobG9jYXRpb24ub3JpZ2luICYmIGxvY2F0aW9uLm9y
aWdpbi5pbmRleE9mKCdodHRwczovLycpID09PSAwKQogICAgICAgID8gKGxvY2F0aW9uLm9yaWdp
bi5yZXBsYWNlKC9cLyQvLCAnJykgKyAnL2NsaXBzX3N0b3JlLycpCiAgICAgICAgOiAnaHR0cHM6
Ly9jbGlwdWkuYXBwL2NsaXBzX3N0b3JlLyc7CiAgICBjb25zdCBTVE9SRV9CQVNFX0ZBTExCQUNL
ID0gJ2h0dHBzOi8vY2xpcHMuc3RvcmUvJzsKICAgIGZ1bmN0aW9uIG1ldGFDZW50ZXJIdG1sKGV4
cGFuZElubmVyKSB7CiAgICAgICAgaWYgKGV4cGFuZElubmVyID09IG51bGwgfHwgZXhwYW5kSW5u
ZXIgPT09IGZhbHNlKQogICAgICAgICAgICByZXR1cm4gYDxzcGFuIGNsYXNzPSJpLW1ldGEtY2Vu
dGVyIj48L3NwYW4+YDsKICAgICAgICByZXR1cm4gYDxzcGFuIGNsYXNzPSJpLW1ldGEtY2VudGVy
Ij48YnV0dG9uIGNsYXNzPSJpLWV4cGFuZC1idG4ke2V4cGFuZElubmVyLm9uID8gJyBvbicgOiAn
J30iIHR5cGU9ImJ1dHRvbiIgdGl0bGU9IuWxleW8gC/mlLbotbciPiR7ZXhwYW5kSW5uZXIuaHRt
bH08L2J1dHRvbj48L3NwYW4+YDsKICAgIH0KCiAgICBmdW5jdGlvbiByZW1lbWJlckxhc3RQYXN0
ZShpZCkgewogICAgICAgIGxhc3RQYXN0ZUlkID0gK2lkIHx8IDA7CiAgICAgICAgbGFzdFBhc3Rl
VGFiID0gY3VyVGFiIHx8ICdhbGwnOwogICAgICAgIHRyeSB7CiAgICAgICAgICAgIGxvY2FsU3Rv
cmFnZS5zZXRJdGVtKCdjbGlwTGFzdFBhc3RlSWQnLCBTdHJpbmcobGFzdFBhc3RlSWQpKTsKICAg
ICAgICAgICAgbG9jYWxTdG9yYWdlLnNldEl0ZW0oJ2NsaXBMYXN0UGFzdGVUYWInLCBsYXN0UGFz
dGVUYWIpOwogICAgICAgIH0gY2F0Y2gge30KICAgICAgICB1cGRhdGVMb2NhdGVCdG4oKTsKICAg
IH0KICAgIGZ1bmN0aW9uIHVwZGF0ZUxvY2F0ZUJ0bigpIHsKICAgICAgICBjb25zdCBidG4gPSBk
b2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYnRuLWxvY2F0ZScpOwogICAgICAgIGlmICghYnRuKSBy
ZXR1cm47CiAgICAgICAgYnRuLmRpc2FibGVkID0gIWxhc3RQYXN0ZUlkOwogICAgICAgIGJ0bi5j
bGFzc0xpc3QudG9nZ2xlKCdoYXMtdGFyZ2V0JywgISFsYXN0UGFzdGVJZCk7CiAgICAgICAgYnRu
LmNsYXNzTGlzdC50b2dnbGUoJ29uJywgbG9jYXRlQWN0aXZlICYmICEhbGFzdFBhc3RlSWQpOwog
ICAgICAgIGJ0bi50aXRsZSA9ICFsYXN0UGFzdGVJZAogICAgICAgICAgICA/ICfmmoLml6DkuIrm
rKHkvb/nlKjkvY3nva4nCiAgICAgICAgICAgIDogKGxvY2F0ZUFjdGl2ZSA/ICflj5bmtojlrprk
vY3vvIzlm57liLDnrKzkuIDmnaEnIDogJ+WumuS9jeWIsOS4iuasoeS9v+eUqOeahOadoeebricp
OwogICAgfQogICAgZnVuY3Rpb24gc2VsZWN0Rmlyc3RJdGVtKCkgewogICAgICAgIGxvY2F0ZUFj
dGl2ZSA9IGZhbHNlOwogICAgICAgIHdpbmRvdy5fX3BlbmRpbmdKdW1wSWQgPSAwOwogICAgICAg
IHdpbmRvdy5fX2p1bXBMb2FkVHJpZXMgPSAwOwogICAgICAgIHNlbGVjdEZpcnN0T25TaG93ID0g
ZmFsc2U7CiAgICAgICAgY29uc3QgdmlzID0gdmlzaWJsZUxpc3QoKTsKICAgICAgICBpZiAoIXZp
cy5sZW5ndGgpIHsKICAgICAgICAgICAgc2VsZWN0ZWRJZCA9IDA7CiAgICAgICAgICAgIHN5bmNJ
dGVtSGlnaGxpZ2h0KCk7CiAgICAgICAgICAgIHVwZGF0ZUxvY2F0ZUJ0bigpOwogICAgICAgICAg
ICByZXR1cm47CiAgICAgICAgfQogICAgICAgIHNlbGVjdGVkSWQgPSB2aXNbMF0uaWQ7CiAgICAg
ICAgcmFuZ2VBbmNob3JJZCA9IHNlbGVjdGVkSWQ7CiAgICAgICAgcmFuZ2VBbmNob3JDbGlja2Vk
ID0gZmFsc2U7CiAgICAgICAgbGlzdEVsLnNjcm9sbFRvcCA9IDA7CiAgICAgICAgc3luY0l0ZW1I
aWdobGlnaHQoKTsKICAgICAgICBjb25zdCBlbCA9IGxpc3RFbC5xdWVyeVNlbGVjdG9yKCcuaXRt
W2RhdGEtaWQ9IicgKyBzZWxlY3RlZElkICsgJyJdJyk7CiAgICAgICAgaWYgKGVsKSBlbC5zY3Jv
bGxJbnRvVmlldyh7IGJsb2NrOiAnbmVhcmVzdCcgfSk7CiAgICAgICAgdXBkYXRlTG9jYXRlQnRu
KCk7CiAgICB9CiAgICBmdW5jdGlvbiBqdW1wVG9MYXN0UGFzdGUoKSB7CiAgICAgICAgaWYgKCFs
YXN0UGFzdGVJZCkgcmV0dXJuOwogICAgICAgIC8vIEFscmVhZHkgbG9jYXRlZCBvbiBsYXN0IHBh
c3RlIOKGkiBjYW5jZWwgYW5kIHNlbGVjdCBmaXJzdAogICAgICAgIGlmIChsb2NhdGVBY3RpdmUg
JiYgK3NlbGVjdGVkSWQgPT09ICtsYXN0UGFzdGVJZCkgewogICAgICAgICAgICBzZWxlY3RGaXJz
dEl0ZW0oKTsKICAgICAgICAgICAgcmV0dXJuOwogICAgICAgIH0KICAgICAgICBsb2NhdGVBY3Rp
dmUgPSB0cnVlOwogICAgICAgIHNlbGVjdEZpcnN0T25TaG93ID0gZmFsc2U7CiAgICAgICAgLy8g
Q2xlYXIgZmlsdGVycyBzbyB0aGUgaXRlbSBpcyBmaW5kYWJsZSBvbiB0aGUgdGFiIHdoZXJlIGl0
IHdhcyB1c2VkCiAgICAgICAgcXVlcnkgPSAnJzsKICAgICAgICB0b2RheU9ubHkgPSBmYWxzZTsK
ICAgICAgICB0cnkgewogICAgICAgICAgICBjb25zdCBzcmNoID0gZG9jdW1lbnQuZ2V0RWxlbWVu
dEJ5SWQoJ3NlYXJjaCcpOwogICAgICAgICAgICBjb25zdCBzY2xyID0gZG9jdW1lbnQuZ2V0RWxl
bWVudEJ5SWQoJ3NlYXJjaC1jbHInKTsKICAgICAgICAgICAgY29uc3Qgd3JhcCA9IGRvY3VtZW50
LmdldEVsZW1lbnRCeUlkKCdzZWFyY2gtd3JhcCcpOwogICAgICAgICAgICBjb25zdCBidG5Ub2Rh
eSA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdidG4tdG9kYXknKTsKICAgICAgICAgICAgaWYg
KHNyY2gpIHsgc3JjaC52YWx1ZSA9ICcnOyBzcmNoLmNsYXNzTGlzdC5yZW1vdmUoJ2hhcy12YWwn
KTsgfQogICAgICAgICAgICBpZiAoc2Nscikgc2Nsci5zdHlsZS5kaXNwbGF5ID0gJ25vbmUnOwog
ICAgICAgICAgICBpZiAod3JhcCkgd3JhcC5jbGFzc0xpc3QucmVtb3ZlKCdvcGVuJyk7CiAgICAg
ICAgICAgIGlmIChidG5Ub2RheSkgYnRuVG9kYXkuY2xhc3NMaXN0LnJlbW92ZSgnb24nKTsKICAg
ICAgICB9IGNhdGNoIHt9CiAgICAgICAgY29uc3QgdGFiID0gWydhbGwnLCd0ZXh0JywnaW1hZ2Un
LCdmaWxlJywncGlubmVkJ10uaW5jbHVkZXMobGFzdFBhc3RlVGFiKQogICAgICAgICAgICA/IGxh
c3RQYXN0ZVRhYiA6ICdhbGwnOwogICAgICAgIGNvbnN0IHByZXZUYWIgPSBjdXJUYWI7CiAgICAg
ICAgY3VyVGFiID0gdGFiOwogICAgICAgIGxvYWRpbmdNb3JlID0gZmFsc2U7CiAgICAgICAgbWFy
a1RhYih0YWIpOwogICAgICAgIGNsZWFyTXVsdGkoKTsKICAgICAgICBzZWxlY3RlZElkID0gbGFz
dFBhc3RlSWQ7CiAgICAgICAgd2luZG93Ll9fcGVuZGluZ0p1bXBJZCA9IGxhc3RQYXN0ZUlkOwog
ICAgICAgIHdpbmRvdy5fX2p1bXBMb2FkVHJpZXMgPSAwOwogICAgICAgIHdpbmRvdy5fX2p1bXBG
ZWxsQmFjayA9IGZhbHNlOwogICAgICAgIHVwZGF0ZUxvY2F0ZUJ0bigpOwogICAgICAgIHJlcXVl
c3RWaWV3KCk7CiAgICB9CgogICAgZnVuY3Rpb24gcmVxdWVzdFZpZXcoKSB7CiAgICAgICAgY29u
c3QgdGFiID0gY3VyVGFiLCBxID0gcXVlcnksIHRvZGF5ID0gdG9kYXlPbmx5ID8gJzEnIDogJzAn
OwogICAgICAgIGlmICh3aW5kb3cuX192aWV3UmFmKSBjYW5jZWxBbmltYXRpb25GcmFtZSh3aW5k
b3cuX192aWV3UmFmKTsKICAgICAgICB3aW5kb3cuX192aWV3UmFmID0gcmVxdWVzdEFuaW1hdGlv
bkZyYW1lKCgpID0+IHsKICAgICAgICAgICAgd2luZG93Ll9fdmlld1JhZiA9IDA7CiAgICAgICAg
ICAgIHNldFRpbWVvdXQoKCkgPT4gYWhrKCdzZXRWaWV3JywgdGFiLCBxLCB0b2RheSksIDApOwog
ICAgICAgIH0pOwogICAgfQogICAgLyoqIERlYm91bmNlZCBBSEsgc3luYyBhZnRlciB2aWV3TWVt
IGluc3RhbnQgcGFpbnQg4oCUYXZvaWRzIHRhYi1zd2l0Y2ggZG91YmxlIFB1c2hDbGlwcyAqLwog
ICAgZnVuY3Rpb24gc29mdFJlcXVlc3RWaWV3KCkgewogICAgICAgIGlmICh3aW5kb3cuX19zb2Z0
Vmlld1QpIGNsZWFyVGltZW91dCh3aW5kb3cuX19zb2Z0Vmlld1QpOwogICAgICAgIHdpbmRvdy5f
X3NvZnRWaWV3VCA9IHNldFRpbWVvdXQoKCkgPT4gewogICAgICAgICAgICB3aW5kb3cuX19zb2Z0
Vmlld1QgPSAwOwogICAgICAgICAgICByZXF1ZXN0VmlldygpOwogICAgICAgIH0sIDMyMCk7CiAg
ICB9CiAgICBmdW5jdGlvbiByZXF1ZXN0TW9yZShmb3JjZSA9IGZhbHNlKSB7CiAgICAgICAgaWYg
KGRpc2tUb3RhbCA+IDAgJiYgYWxsQ2xpcHMubGVuZ3RoID49IGRpc2tUb3RhbCkgcmV0dXJuOwog
ICAgICAgIC8vIExvY2F0ZSAvIGp1bXAgbXVzdCBub3Qgd2FpdCBvbiBzY3JvbGwtaWRsZSBvciBh
IHN0dWNrIGxvYWRpbmdNb3JlIGZsYWcKICAgICAgICBpZiAoIWZvcmNlKSB7CiAgICAgICAgICAg
IGlmIChsb2FkaW5nTW9yZSkgcmV0dXJuOwogICAgICAgICAgICBpZiAod2luZG93Ll9fc2Nyb2xs
QnVzeSB8fCBfbGlzdFB0ckRvd24pIHsKICAgICAgICAgICAgICAgIHdpbmRvdy5fX3dhbnRNb3Jl
ID0gdHJ1ZTsKICAgICAgICAgICAgICAgIHJldHVybjsKICAgICAgICAgICAgfQogICAgICAgIH0g
ZWxzZSB7CiAgICAgICAgICAgIGxvYWRpbmdNb3JlID0gZmFsc2U7CiAgICAgICAgICAgIHdpbmRv
dy5fX3Njcm9sbEJ1c3kgPSBmYWxzZTsKICAgICAgICAgICAgd2luZG93Ll9fd2FudE1vcmUgPSBm
YWxzZTsKICAgICAgICAgICAgX2xpc3RQdHJEb3duID0gZmFsc2U7CiAgICAgICAgICAgIHRyeSB7
IGxpc3RFbC5jbGFzc0xpc3QucmVtb3ZlKCdpcy1zY3JvbGxpbmcnKTsgfSBjYXRjaCB7fQogICAg
ICAgIH0KICAgICAgICBpZiAobG9hZGluZ01vcmUpIHJldHVybjsKICAgICAgICBsb2FkaW5nTW9y
ZSA9IHRydWU7CiAgICAgICAgd2luZG93Ll9fd2FudE1vcmUgPSBmYWxzZTsKICAgICAgICBpZiAo
d2luZG93Ll9fbG9hZE1vcmVXYXRjaCkgY2xlYXJUaW1lb3V0KHdpbmRvdy5fX2xvYWRNb3JlV2F0
Y2gpOwogICAgICAgIHdpbmRvdy5fX2xvYWRNb3JlV2F0Y2ggPSBzZXRUaW1lb3V0KCgpID0+IHsK
ICAgICAgICAgICAgd2luZG93Ll9fbG9hZE1vcmVXYXRjaCA9IDA7CiAgICAgICAgICAgIGlmIChs
b2FkaW5nTW9yZSkgewogICAgICAgICAgICAgICAgbG9hZGluZ01vcmUgPSBmYWxzZTsKICAgICAg
ICAgICAgICAgIGlmICh3aW5kb3cuX19wZW5kaW5nSnVtcElkKSB0cnlDb250aW51ZUp1bXAoKTsK
ICAgICAgICAgICAgfQogICAgICAgIH0sIDE4MDApOwogICAgICAgIGFoaygnbG9hZE1vcmUnKTsK
ICAgIH0KCiAgICBmdW5jdGlvbiB0cnlDb250aW51ZUp1bXAoKSB7CiAgICAgICAgY29uc3Qgamlk
ID0gK3dpbmRvdy5fX3BlbmRpbmdKdW1wSWQ7CiAgICAgICAgaWYgKCFqaWQpIHJldHVybjsKICAg
ICAgICBpZiAoX3BlbmRpbmdBcHBlbmQpIHsKICAgICAgICAgICAgY29uc3QgcGVuZGluZyA9IF9w
ZW5kaW5nQXBwZW5kOwogICAgICAgICAgICBfcGVuZGluZ0FwcGVuZCA9IG51bGw7CiAgICAgICAg
ICAgIGFwcGx5QXBwZW5kUGF5bG9hZChwZW5kaW5nKTsKICAgICAgICB9CiAgICAgICAgY29uc3Qg
ZWwgPSBsaXN0RWwucXVlcnlTZWxlY3RvcignLm1nLXJvd1tkYXRhLWlkPSInICsgamlkICsgJyJd
JykgfHwgbGlzdEVsLnF1ZXJ5U2VsZWN0b3IoJy5pdG1bZGF0YS1pZD0iJyArIGppZCArICciXScp
OwogICAgICAgIGlmIChlbCkgewogICAgICAgICAgICB3aW5kb3cuX19wZW5kaW5nSnVtcElkID0g
MDsKICAgICAgICAgICAgd2luZG93Ll9fanVtcExvYWRUcmllcyA9IDA7CiAgICAgICAgICAgIHNl
bGVjdGVkSWQgPSBqaWQ7CiAgICAgICAgICAgIGxvY2F0ZUFjdGl2ZSA9IHRydWU7CiAgICAgICAg
ICAgIHVwZGF0ZUxvY2F0ZUJ0bigpOwogICAgICAgICAgICByZXF1ZXN0QW5pbWF0aW9uRnJhbWUo
KCkgPT4gewogICAgICAgICAgICAgICAgY29uc3Qgbm9kZSA9IGxpc3RFbC5xdWVyeVNlbGVjdG9y
KCcubWctcm93W2RhdGEtaWQ9IicgKyBqaWQgKyAnIl0nKSB8fCBsaXN0RWwucXVlcnlTZWxlY3Rv
cignLml0bVtkYXRhLWlkPSInICsgamlkICsgJyJdJyk7CiAgICAgICAgICAgICAgICBpZiAoIW5v
ZGUpIHJldHVybjsKICAgICAgICAgICAgICAgIG5vZGUuc2Nyb2xsSW50b1ZpZXcoeyBibG9jazog
J2NlbnRlcicgfSk7CiAgICAgICAgICAgICAgICBub2RlLmNsYXNzTGlzdC5hZGQoJ2p1bXAtZmxh
c2gnKTsKICAgICAgICAgICAgICAgIHNldFRpbWVvdXQoKCkgPT4gbm9kZS5jbGFzc0xpc3QucmVt
b3ZlKCdqdW1wLWZsYXNoJyksIDkwMCk7CiAgICAgICAgICAgICAgICBzeW5jSXRlbUhpZ2hsaWdo
dCgpOwogICAgICAgICAgICB9KTsKICAgICAgICAgICAgcmV0dXJuOwogICAgICAgIH0KICAgICAg
ICBpZiAoYWxsQ2xpcHMuc29tZShjID0+ICtjLmlkID09PSBqaWQpKSB7CiAgICAgICAgICAgIHJl
bmRlcigpOwogICAgICAgICAgICByZXF1ZXN0QW5pbWF0aW9uRnJhbWUoKCkgPT4gdHJ5Q29udGlu
dWVKdW1wKCkpOwogICAgICAgICAgICByZXR1cm47CiAgICAgICAgfQogICAgICAgIGlmIChhbGxD
bGlwcy5sZW5ndGggPCBkaXNrVG90YWwgJiYgKHdpbmRvdy5fX2p1bXBMb2FkVHJpZXMgfHwgMCkg
PCA4MCkgewogICAgICAgICAgICB3aW5kb3cuX19qdW1wTG9hZFRyaWVzID0gKHdpbmRvdy5fX2p1
bXBMb2FkVHJpZXMgfHwgMCkgKyAxOwogICAgICAgICAgICByZXF1ZXN0TW9yZSh0cnVlKTsKICAg
ICAgICAgICAgcmV0dXJuOwogICAgICAgIH0KICAgICAgICB3aW5kb3cuX19wZW5kaW5nSnVtcElk
ID0gMDsKICAgICAgICB3aW5kb3cuX19qdW1wTG9hZFRyaWVzID0gMDsKICAgIH0KICAgIGNvbnN0
IEVNUFRZX01TRyA9IHsKICAgICAgICBhbGw6ICAgICfmmoLml6DorrDlvZXvvIzlpI3liLblkI7o
h6rliqjlh7rnjrAnLAogICAgICAgIHRleHQ6ICAgJ+aaguaXoOaWh+acrCcsCiAgICAgICAgaW1h
Z2U6ICAn5pqC5peg5Zu+5YOPJywKICAgICAgICBmaWxlOiAgICfmmoLml6Dmlofku7YnLAogICAg
ICAgIHBpbm5lZDogJ+aaguaXoOaUtuiXjycsCiAgICAgICAgcmVjZW50OiAn5pqC5peg5pyA6L+R
5omT5byA55qE55uu5b2VJwogICAgfTsKCiAgICBmdW5jdGlvbiBhaGtJbnZva2UobWV0aG9kLCBh
cmdzKSB7CiAgICAgICAgdHJ5IHsKICAgICAgICAgICAgY29uc3QgaG9zdCA9IGNocm9tZS53ZWJ2
aWV3Lmhvc3RPYmplY3RzLnN5bmMuYWhrOwogICAgICAgICAgICBpZiAoIWhvc3QpIHJldHVybjsK
ICAgICAgICAgICAgbGV0IGNhbGxlZCA9IGZhbHNlOwogICAgICAgICAgICAvLyBXZWJWaWV3Mjog
aG9zdC5jYWxsKG5hbWUsIOKApikgaXMgdGhlIHJlbGlhYmxlIHBhdGguIERpcmVjdCBob3N0W21l
dGhvZF0o4oCmKQogICAgICAgICAgICAvLyBjYW4gbWlzLWJpbmQgYXJncyAoc2F3IHNldFZpZXcg
dGFiIGJlY29tZSAwIOKGkiBmb3JldmVyIHNrZWxldG9uIC8gd3JvbmcgdGFiKS4KICAgICAgICAg
ICAgaWYgKHR5cGVvZiBob3N0LmNhbGwgPT09ICdmdW5jdGlvbicpIHsKICAgICAgICAgICAgICAg
IHRyeSB7IGhvc3QuY2FsbChtZXRob2QsIC4uLmFyZ3MpOyBjYWxsZWQgPSB0cnVlOyB9IGNhdGNo
IHt9CiAgICAgICAgICAgIH0KICAgICAgICAgICAgaWYgKCFjYWxsZWQgJiYgdHlwZW9mIGhvc3Rb
bWV0aG9kXSA9PT0gJ2Z1bmN0aW9uJykgewogICAgICAgICAgICAgICAgdHJ5IHsgaG9zdFttZXRo
b2RdKC4uLmFyZ3MpOyBjYWxsZWQgPSB0cnVlOyB9IGNhdGNoIChlKSB7IGNvbnNvbGUud2Fybign
YWhrLicgKyBtZXRob2QsIGUpOyB9CiAgICAgICAgICAgIH0KICAgICAgICAgICAgaWYgKCFjYWxs
ZWQgJiYgaG9zdFttZXRob2RdICE9IG51bGwgJiYgdHlwZW9mIGhvc3RbbWV0aG9kXSAhPT0gJ2Z1
bmN0aW9uJykgewogICAgICAgICAgICAgICAgdHJ5IHsgdm9pZCBob3N0W21ldGhvZF07IH0gY2F0
Y2gge30KICAgICAgICAgICAgfQogICAgICAgIH0gY2F0Y2ggKGUpIHsgY29uc29sZS53YXJuKCdh
aGsuJyArIG1ldGhvZCwgZSk7IH0KICAgIH0KICAgIGZ1bmN0aW9uIGFoayhtZXRob2QsIC4uLmFy
Z3MpIHsKICAgICAgICBhaGtJbnZva2UobWV0aG9kLCBhcmdzKTsKICAgIH0KICAgIGZ1bmN0aW9u
IGFoa1JldChtZXRob2QsIC4uLmFyZ3MpIHsKICAgICAgICB0cnkgewogICAgICAgICAgICBjb25z
dCBob3N0ID0gY2hyb21lLndlYnZpZXcuaG9zdE9iamVjdHMuc3luYy5haGs7CiAgICAgICAgICAg
IGlmICghaG9zdCkgcmV0dXJuIG51bGw7CiAgICAgICAgICAgIGxldCByZXQgPSBudWxsOwogICAg
ICAgICAgICBpZiAodHlwZW9mIGhvc3QuY2FsbCA9PT0gJ2Z1bmN0aW9uJykgewogICAgICAgICAg
ICAgICAgdHJ5IHsgcmV0ID0gaG9zdC5jYWxsKG1ldGhvZCwgLi4uYXJncyk7IH0gY2F0Y2gge30K
ICAgICAgICAgICAgfQogICAgICAgICAgICBpZiAocmV0ID09IG51bGwgJiYgdHlwZW9mIGhvc3Rb
bWV0aG9kXSA9PT0gJ2Z1bmN0aW9uJykgewogICAgICAgICAgICAgICAgdHJ5IHsgcmV0ID0gaG9z
dFttZXRob2RdKC4uLmFyZ3MpOyB9IGNhdGNoIHt9CiAgICAgICAgICAgICAgICBpZiAocmV0ID09
IG51bGwpIHsKICAgICAgICAgICAgICAgICAgICB0cnkgeyByZXQgPSBob3N0W21ldGhvZF0oLi4u
YXJncyk7IH0gY2F0Y2gge30KICAgICAgICAgICAgICAgIH0KICAgICAgICAgICAgfQogICAgICAg
ICAgICBpZiAocmV0ID09IG51bGwgJiYgaG9zdFttZXRob2RdICE9IG51bGwgJiYgdHlwZW9mIGhv
c3RbbWV0aG9kXSAhPT0gJ2Z1bmN0aW9uJykKICAgICAgICAgICAgICAgIHJldCA9IGhvc3RbbWV0
aG9kXTsKICAgICAgICAgICAgaWYgKHJldCA9PSBudWxsKSByZXR1cm4gbnVsbDsKICAgICAgICAg
ICAgaWYgKHR5cGVvZiByZXQgPT09ICdzdHJpbmcnIHx8IHR5cGVvZiByZXQgPT09ICdudW1iZXIn
IHx8IHR5cGVvZiByZXQgPT09ICdib29sZWFuJykKICAgICAgICAgICAgICAgIHJldHVybiByZXQ7
CiAgICAgICAgICAgIHRyeSB7IHJldHVybiBTdHJpbmcocmV0KTsgfSBjYXRjaCB7IHJldHVybiBy
ZXQ7IH0KICAgICAgICB9IGNhdGNoIChlKSB7IGNvbnNvbGUud2FybignYWhrUmV0LicgKyBtZXRo
b2QsIGUpOyB9CiAgICAgICAgcmV0dXJuIG51bGw7CiAgICB9CgogICAgLy8gRWFybHkgQUhLIF9f
c2V0VGh1bWIgY2FuIGFycml2ZSBiZWZvcmUgRE9NIG5vZGVzIGV4aXN0IOKAlCBrZWVwIHVudGls
IGJpbmQKICAgIGNvbnN0IHRodW1iQ2FjaGUgPSBuZXcgTWFwKCk7CgogICAgLyoqIFByZWZlciBj
YWNoZSAvIGRhdGEtVVJMLCB0aGVuIHRoXyouanBnIHZpYSB2aXJ0dWFsIGhvc3QsIHRoZW4gb3Jp
Z2luYWwgKi8KICAgIGZ1bmN0aW9uIGJpbmRTdG9yZVRodW1iKGltZywgZmlsZSwgaWQsIGZhbGxi
YWNrKSB7CiAgICAgICAgaW1nLmRhdGFzZXQudGh1bWJJZCA9IFN0cmluZyhpZCk7CiAgICAgICAg
aW1nLmFsdCA9ICcnOwogICAgICAgIGltZy5jbGFzc0xpc3QuYWRkKCd0aHVtYi1sb2FkaW5nJyk7
CiAgICAgICAgY29uc3Qgd3JhcCA9IGltZy5wYXJlbnRFbGVtZW50OwogICAgICAgIGlmICh3cmFw
ICYmIHdyYXAuY2xhc3NMaXN0LmNvbnRhaW5zKCdpLXRodW1iLXdyYXAnKSkKICAgICAgICAgICAg
d3JhcC5jbGFzc0xpc3QuYWRkKCd3YWl0aW5nJyk7CiAgICAgICAgY29uc3QgY2xlYXJXYWl0ID0g
KCkgPT4gewogICAgICAgICAgICBpbWcuY2xhc3NMaXN0LnJlbW92ZSgndGh1bWItbG9hZGluZycp
OwogICAgICAgICAgICBpZiAod3JhcCkgd3JhcC5jbGFzc0xpc3QucmVtb3ZlKCd3YWl0aW5nJyk7
CiAgICAgICAgICAgIGlmIChpbWcuX2ZhaWxUaW1lcikgdHJ5IHsgY2xlYXJUaW1lb3V0KGltZy5f
ZmFpbFRpbWVyKTsgfSBjYXRjaCB7fQogICAgICAgIH07CiAgICAgICAgY29uc3QgZmFpbFRpbWVy
ID0gc2V0VGltZW91dCgoKSA9PiB7CiAgICAgICAgICAgIGlmICghaW1nLnNyYyB8fCBpbWcubmF0
dXJhbFdpZHRoIDwgMSkKICAgICAgICAgICAgICAgIGltZy5hbHQgPSAn5peg5rOV5Yqg6L29JzsK
ICAgICAgICAgICAgY2xlYXJXYWl0KCk7CiAgICAgICAgfSwgMTIwMDApOwogICAgICAgIGltZy5f
ZmFpbFRpbWVyID0gZmFpbFRpbWVyOwogICAgICAgIGNvbnN0IHByZXZMb2FkID0gaW1nLm9ubG9h
ZDsKICAgICAgICBpbWcub25sb2FkID0gZSA9PiB7CiAgICAgICAgICAgIGNsZWFyV2FpdCgpOwog
ICAgICAgICAgICBpbWcuYWx0ID0gJyc7CiAgICAgICAgICAgIGlmICh0eXBlb2YgcHJldkxvYWQg
PT09ICdmdW5jdGlvbicpIHByZXZMb2FkLmNhbGwoaW1nLCBlKTsKICAgICAgICB9OwogICAgICAg
IGNvbnN0IGJhcmUgPSBmaWxlID8gU3RyaW5nKGZpbGUpLnNwbGl0KC9bXFwvXS8pLnBvcCgpIDog
Jyc7CiAgICAgICAgY29uc3QgdGhOYW1lID0gYmFyZSA/ICgndGhfJyArIGJhcmUucmVwbGFjZSgv
XC5bXi5dKyQvLCAnJykgKyAnLmpwZycpIDogJyc7CiAgICAgICAgaW1nLm9uZXJyb3IgPSAoKSA9
PiB7CiAgICAgICAgICAgIGNvbnN0IHN0ZXAgPSBOdW1iZXIoaW1nLmRhdGFzZXQuc3RlcCB8fCAw
KTsKICAgICAgICAgICAgaWYgKHN0ZXAgPCAyICYmIGJhcmUpIHsKICAgICAgICAgICAgICAgIGlt
Zy5kYXRhc2V0LnN0ZXAgPSAnMic7CiAgICAgICAgICAgICAgICBpbWcuc3JjID0gU1RPUkVfQkFT
RSArIGVuY29kZVVSSUNvbXBvbmVudChiYXJlKTsKICAgICAgICAgICAgICAgIHJldHVybjsKICAg
ICAgICAgICAgfQogICAgICAgICAgICBpZiAoc3RlcCA8IDMgJiYgKHRoTmFtZSB8fCBiYXJlKSkg
ewogICAgICAgICAgICAgICAgaW1nLmRhdGFzZXQuc3RlcCA9ICczJzsKICAgICAgICAgICAgICAg
IGltZy5zcmMgPSBTVE9SRV9CQVNFX0ZBTExCQUNLICsgZW5jb2RlVVJJQ29tcG9uZW50KHRoTmFt
ZSB8fCBiYXJlKTsKICAgICAgICAgICAgICAgIHJldHVybjsKICAgICAgICAgICAgfQogICAgICAg
ICAgICBpZiAoc3RlcCA8IDQgJiYgYmFyZSAmJiB0aE5hbWUpIHsKICAgICAgICAgICAgICAgIGlt
Zy5kYXRhc2V0LnN0ZXAgPSAnNCc7CiAgICAgICAgICAgICAgICBpbWcuc3JjID0gU1RPUkVfQkFT
RV9GQUxMQkFDSyArIGVuY29kZVVSSUNvbXBvbmVudChiYXJlKTsKICAgICAgICAgICAgICAgIHJl
dHVybjsKICAgICAgICAgICAgfQogICAgICAgICAgICAvLyBLZWVwIHNoaW1tZXI7IEFISyBfX3Nl
dFRodW1iIHdpbGwgZmlsbCBpbgogICAgICAgICAgICBpbWcucmVtb3ZlQXR0cmlidXRlKCdzcmMn
KTsKICAgICAgICAgICAgaW1nLmNsYXNzTGlzdC5hZGQoJ3RodW1iLWxvYWRpbmcnKTsKICAgICAg
ICAgICAgaWYgKHdyYXApIHdyYXAuY2xhc3NMaXN0LmFkZCgnd2FpdGluZycpOwogICAgICAgIH07
CiAgICAgICAgY29uc3QgY2FjaGVkID0gdGh1bWJDYWNoZS5nZXQoU3RyaW5nKGlkKSk7CiAgICAg
ICAgLy8gQWNjZXB0IGRhdGEtVVJMIG9yIGhvc3QgVVJMIGZyb20gcHJpb3IgX19zZXRUaHVtYiAo
cmUtcmVuZGVyIG11c3Qgbm90IGRyb3AgaXQpCiAgICAgICAgaWYgKGNhY2hlZCAmJiBTdHJpbmco
Y2FjaGVkKS5sZW5ndGgpIHsKICAgICAgICAgICAgaW1nLmRhdGFzZXQuc3RlcCA9ICc5JzsKICAg
ICAgICAgICAgaW1nLnNyYyA9IFN0cmluZyhjYWNoZWQpOwogICAgICAgICAgICByZXR1cm47CiAg
ICAgICAgfQogICAgICAgIGNvbnN0IGRhdGFVcmwgPSAoZmFsbGJhY2sgJiYgU3RyaW5nKGZhbGxi
YWNrKS5zdGFydHNXaXRoKCdkYXRhOicpKQogICAgICAgICAgICA/IFN0cmluZyhmYWxsYmFjaykg
OiAnJzsKICAgICAgICBpZiAoZGF0YVVybCkgewogICAgICAgICAgICBpbWcuZGF0YXNldC5zdGVw
ID0gJzknOwogICAgICAgICAgICBpbWcuc3JjID0gZGF0YVVybDsKICAgICAgICAgICAgcmV0dXJu
OwogICAgICAgIH0KICAgICAgICBpZiAoYmFyZSkgewogICAgICAgICAgICAvLyBQcmVmZXIgbGlz
dCB0aHVtYiBKUEVHIChzbWFsbCkgb24gZGVkaWNhdGVkIHN0b3JlIGhvc3QKICAgICAgICAgICAg
aW1nLmRhdGFzZXQuc3RlcCA9ICcxJzsKICAgICAgICAgICAgaW1nLnNyYyA9IFNUT1JFX0JBU0Ug
KyBlbmNvZGVVUklDb21wb25lbnQodGhOYW1lIHx8IGJhcmUpOwogICAgICAgIH0gZWxzZSB7CiAg
ICAgICAgICAgIC8vIE5vIGZpbGUgeWV0IChqdXN0IGNvcGllZCkg4oCUa2VlcCBzaGltbWVyOyBJ
bmplY3RMaXZlSW1hZ2VUaHVtYiAvIF9fc2V0VGh1bWIgZmlsbHMgaW4KICAgICAgICAgICAgaW1n
LmNsYXNzTGlzdC5hZGQoJ3RodW1iLWxvYWRpbmcnKTsKICAgICAgICAgICAgaWYgKHdyYXApIHdy
YXAuY2xhc3NMaXN0LmFkZCgnd2FpdGluZycpOwogICAgICAgIH0KICAgIH0KCiAgICB3aW5kb3cu
X19zZXRUaHVtYiA9IChpZCwgdXJsKSA9PiB7CiAgICAgICAgaWYgKCF1cmwpIHJldHVybjsKICAg
ICAgICBjb25zdCBrZXkgPSBTdHJpbmcoaWQpOwogICAgICAgIHRodW1iQ2FjaGUuc2V0KGtleSwg
dXJsKTsKICAgICAgICBjb25zdCBhcHBseSA9IGltZyA9PiB7CiAgICAgICAgICAgIGlmIChpbWcu
X2ZhaWxUaW1lcikgdHJ5IHsgY2xlYXJUaW1lb3V0KGltZy5fZmFpbFRpbWVyKTsgfSBjYXRjaCB7
fQogICAgICAgICAgICBpbWcub25lcnJvciA9IG51bGw7CiAgICAgICAgICAgIGltZy5hbHQgPSAn
JzsKICAgICAgICAgICAgaW1nLmNsYXNzTGlzdC5yZW1vdmUoJ3RodW1iLWxvYWRpbmcnKTsKICAg
ICAgICAgICAgY29uc3Qgd3JhcCA9IGltZy5wYXJlbnRFbGVtZW50OwogICAgICAgICAgICBpZiAo
d3JhcCkgd3JhcC5jbGFzc0xpc3QucmVtb3ZlKCd3YWl0aW5nJyk7CiAgICAgICAgICAgIGltZy5z
cmMgPSB1cmw7CiAgICAgICAgfTsKICAgICAgICBsZXQgaGl0ID0gMDsKICAgICAgICBkb2N1bWVu
dC5xdWVyeVNlbGVjdG9yQWxsKCcuaXRtW2RhdGEtaWQ9IicgKyBrZXkgKyAnIl0gaW1nLmktdGh1
bWInKS5mb3JFYWNoKGltZyA9PiB7CiAgICAgICAgICAgIGFwcGx5KGltZyk7IGhpdCsrOwogICAg
ICAgIH0pOwogICAgICAgIGlmICghaGl0KSB7CiAgICAgICAgICAgIGRvY3VtZW50LnF1ZXJ5U2Vs
ZWN0b3JBbGwoJ2ltZy5pLXRodW1iW2RhdGEtdGh1bWItaWQ9IicgKyBrZXkgKyAnIl0nKS5mb3JF
YWNoKGFwcGx5KTsKICAgICAgICB9CiAgICB9OwoKICAgIGZ1bmN0aW9uIGlzRHJhZ0V4Y2x1ZGUo
dCkgewogICAgICAgIHJldHVybiAhIXQuY2xvc2VzdCgnI3NlYXJjaC13cmFwLCAjYnRuLXNlYXJj
aCwgI2J0bi1sb2NhdGUsICNidG4tdG9kYXksICNidG4tcGluLCAjYnRuLWNsciwgI211bHRpLWJh
ciwgI211bHRpLXNlbCwgI211bHRpLWNudCwgI3Bhc3RlLXNlcC13cmFwLCAudGFiLCAuaXRtLCAj
dGFiLWFjdGlvbnMsICNjdHgsICNjbHItZGxnLCAjdGl0bGUtZGxnLCAjcGF0aC10aXAsIGJ1dHRv
biwgaW5wdXQsIGEnKTsKICAgIH0KICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdhcHAnKS5h
ZGRFdmVudExpc3RlbmVyKCdtb3VzZWRvd24nLCBlID0+IHsKICAgICAgICBpZiAoZS5idXR0b24g
IT09IDApIHJldHVybjsKICAgICAgICBpZiAoaXNEcmFnRXhjbHVkZShlLnRhcmdldCkpIHJldHVy
bjsKICAgICAgICBlLnByZXZlbnREZWZhdWx0KCk7CiAgICAgICAgYWhrKCdzdGFydERyYWcnKTsK
ICAgIH0sIHRydWUpOwoKICAgIGNvbnN0IGlzVXJsICA9IHMgPT4gL15odHRwcz86XC9cLy9pLnRl
c3QoKHMgfHwgJycpLnRyaW0oKSk7CgogICAgZnVuY3Rpb24gYWdvKGRhdGVTdHIpIHsKICAgICAg
ICB0cnkgewogICAgICAgICAgICBjb25zdCBkID0gbmV3IERhdGUoU3RyaW5nKGRhdGVTdHIpLnJl
cGxhY2UoJyAnLCAnVCcpKTsKICAgICAgICAgICAgY29uc3QgcyA9IChEYXRlLm5vdygpIC0gZCkg
LyAxMDAwIHwgMDsKICAgICAgICAgICAgaWYgKHMgPCA2MCkgcmV0dXJuICfliJrliJonOwogICAg
ICAgICAgICBpZiAocyA8IDM2MDApIHJldHVybiAocyAvIDYwIHwgMCkgKyAnIOWIhumSn+WJjSc7
CiAgICAgICAgICAgIGlmIChzIDwgODY0MDApIHJldHVybiAocyAvIDM2MDAgfCAwKSArICcg5bCP
5pe25YmNJzsKICAgICAgICAgICAgcmV0dXJuIChzIC8gODY0MDAgfCAwKSArICcg5aSp5YmNJzsK
ICAgICAgICB9IGNhdGNoIHsgcmV0dXJuIGRhdGVTdHI7IH0KICAgIH0KCiAgICBmdW5jdGlvbiBu
b3JtVHlwZSh0KSB7CiAgICAgICAgdCA9IFN0cmluZyh0IHx8ICcnKS50b0xvd2VyQ2FzZSgpOwog
ICAgICAgIGlmICh0ID09PSAnaW1hZ2UnIHx8IHQgPT09ICdpbWcnIHx8IHQgPT09ICdiaXRtYXAn
KSByZXR1cm4gJ2ltYWdlJzsKICAgICAgICBpZiAodCA9PT0gJ2ZpbGUnICB8fCB0ID09PSAnZmls
ZXMnKSByZXR1cm4gJ2ZpbGUnOwogICAgICAgIGlmICh0ID09PSAncmVjZW50JyB8fCB0ID09PSAn
Zm9sZGVyJyB8fCB0ID09PSAnZGlyJykgcmV0dXJuICdyZWNlbnQnOwogICAgICAgIGlmICh0ID09
PSAnbGluaycgfHwgdCA9PT0gJ3VybCcpIHJldHVybiAnbGluayc7CiAgICAgICAgcmV0dXJuICd0
ZXh0JzsKICAgIH0KICAgIGZ1bmN0aW9uIGlzUGlubmVkKGMpIHsKICAgICAgICByZXR1cm4gYy5w
aW5uZWQgPT09IHRydWUgfHwgYy5waW5uZWQgPT09IDEgfHwgYy5waW5uZWQgPT09ICd0cnVlJyB8
fCBjLnBpbm5lZCA9PT0gJzEnOwogICAgfQogICAgLyoqIOWQjOatpeaJgOaciSB0YWIg57yT5a2Y
6YeM55qE5pS26JeP5qCH6K6w77yM6YG/5YWN5pS26JeP6aG15Y+W5raI5ZCO5YW25a6D5YiX6KGo
5LuN5pi+56S644CM5Y+W5raI5pS26JeP44CNICovCiAgICBmdW5jdGlvbiBwYXRjaFBpbm5lZElu
Q2FjaGVzKGlkLCBwaW5uZWQpIHsKICAgICAgICBpZCA9ICtpZDsKICAgICAgICBpZiAoIWlkKSBy
ZXR1cm47CiAgICAgICAgY29uc3QgYXBwbHkgPSAoYykgPT4gewogICAgICAgICAgICBpZiAoIWMg
fHwgK2MuaWQgIT09IGlkKSByZXR1cm47CiAgICAgICAgICAgIGMucGlubmVkID0gISFwaW5uZWQ7
CiAgICAgICAgICAgIGlmICghcGlubmVkKSBjLnBpblRpbWUgPSAnJzsKICAgICAgICB9OwogICAg
ICAgIGZvciAoY29uc3QgeCBvZiBhbGxDbGlwcykgYXBwbHkoeCk7CiAgICAgICAgdHJ5IHsKICAg
ICAgICAgICAgZm9yIChjb25zdCBba2V5LCBoaXRdIG9mIHZpZXdNZW0uZW50cmllcygpKSB7CiAg
ICAgICAgICAgICAgICBpZiAoIWhpdCB8fCAhQXJyYXkuaXNBcnJheShoaXQuaXRlbXMpKSBjb250
aW51ZTsKICAgICAgICAgICAgICAgIGZvciAoY29uc3QgeCBvZiBoaXQuaXRlbXMpIGFwcGx5KHgp
OwogICAgICAgICAgICAgICAgLy8g5pS26JePIHRhYiDnvJPlrZjvvJrlj5bmtojlkI7nm7TmjqXn
p7vlh7oKICAgICAgICAgICAgICAgIGlmICghcGlubmVkICYmIFN0cmluZyhrZXkpLnN0YXJ0c1dp
dGgoJ3Bpbm5lZFx0JykpIHsKICAgICAgICAgICAgICAgICAgICBjb25zdCBiZWZvcmUgPSBoaXQu
aXRlbXMubGVuZ3RoOwogICAgICAgICAgICAgICAgICAgIGhpdC5pdGVtcyA9IGhpdC5pdGVtcy5m
aWx0ZXIoeCA9PiAreC5pZCAhPT0gaWQpOwogICAgICAgICAgICAgICAgICAgIGlmIChoaXQuaXRl
bXMubGVuZ3RoICE9PSBiZWZvcmUpCiAgICAgICAgICAgICAgICAgICAgICAgIGhpdC50b3RhbCA9
IE1hdGgubWF4KDAsIChOdW1iZXIoaGl0LnRvdGFsKSB8fCBiZWZvcmUpIC0gKGJlZm9yZSAtIGhp
dC5pdGVtcy5sZW5ndGgpKTsKICAgICAgICAgICAgICAgICAgICB2aWV3TWVtLnNldChrZXksIGhp
dCk7CiAgICAgICAgICAgICAgICB9CiAgICAgICAgICAgIH0KICAgICAgICB9IGNhdGNoIHt9CiAg
ICB9CiAgICBmdW5jdGlvbiBpc1Bhc3RlZChjKSB7CiAgICAgICAgcmV0dXJuIGMucGFzdGVkID09
PSB0cnVlIHx8IGMucGFzdGVkID09PSAxIHx8IGMucGFzdGVkID09PSAndHJ1ZScgfHwgYy5wYXN0
ZWQgPT09ICcxJzsKICAgIH0KCiAgICBmdW5jdGlvbiBpc01hcmtkb3duKHRleHQpIHsKICAgICAg
ICBpZiAoIXRleHQgfHwgdGV4dC5sZW5ndGggPCA0KSByZXR1cm4gZmFsc2U7CiAgICAgICAgcmV0
dXJuIC8oPzpefFxuKSN7MSw2fSB8XlstKitdIHxcKlwqW14qXG5dK1wqXCp8X19bXl9cbl0rX198
KD86Xnxcbik+IHxgYGB8YFteYFxuXStgfFxbW15cXV0rXF1cKFteKV0rXCl8XHwuK1x8LitcfC9t
LnRlc3QodGV4dCk7CiAgICB9CiAgICBmdW5jdGlvbiBjbGlwVXNlc01JY29uKGMpIHsKICAgICAg
ICBpZiAoIWMpIHJldHVybiBmYWxzZTsKICAgICAgICBpZiAoYy5pc01kID09PSB0cnVlIHx8IGMu
aXNNZCA9PT0gMSB8fCBjLmlzTWQgPT09ICd0cnVlJyB8fCBjLmlzTWQgPT09ICcxJykgcmV0dXJu
IHRydWU7CiAgICAgICAgaWYgKGMuaXNSaWNoID09PSB0cnVlIHx8IGMuaXNSaWNoID09PSAxIHx8
IGMuaXNSaWNoID09PSAndHJ1ZScgfHwgYy5pc1JpY2ggPT09ICcxJykgcmV0dXJuIHRydWU7CiAg
ICAgICAgY29uc3QgdCA9IFN0cmluZyhjLnR5cGUgfHwgJycpLnRvTG93ZXJDYXNlKCk7CiAgICAg
ICAgaWYgKHQgJiYgdCAhPT0gJ3RleHQnICYmIHQgIT09ICdsaW5rJykgcmV0dXJuIGZhbHNlOwog
ICAgICAgIHJldHVybiBpc01hcmtkb3duKGMuZGF0YSB8fCBjLnByZXZpZXcgfHwgJycpOwogICAg
fQogICAgZnVuY3Rpb24gZXNjQXR0cihzKSB7CiAgICAgICAgcmV0dXJuIFN0cmluZyhzIHx8ICcn
KQogICAgICAgICAgICAucmVwbGFjZSgvJi9nLCAnJmFtcDsnKQogICAgICAgICAgICAucmVwbGFj
ZSgvIi9nLCAnJnF1b3Q7JykKICAgICAgICAgICAgLnJlcGxhY2UoLzwvZywgJyZsdDsnKQogICAg
ICAgICAgICAucmVwbGFjZSgvPi9nLCAnJmd0OycpOwogICAgfQoKICAgIGZ1bmN0aW9uIHRvZGF5
UHJlZml4KCkgewogICAgICAgIGNvbnN0IGQgPSBuZXcgRGF0ZSgpOwogICAgICAgIGNvbnN0IHAg
PSBuID0+IFN0cmluZyhuKS5wYWRTdGFydCgyLCAnMCcpOwogICAgICAgIHJldHVybiBkLmdldEZ1
bGxZZWFyKCkgKyAnLScgKyBwKGQuZ2V0TW9udGgoKSArIDEpICsgJy0nICsgcChkLmdldERhdGUo
KSk7CiAgICB9CiAgICBmdW5jdGlvbiBpc1RvZGF5Q2xpcChjKSB7CiAgICAgICAgcmV0dXJuIFN0
cmluZyhjLnRpbWUgfHwgJycpLnN0YXJ0c1dpdGgodG9kYXlQcmVmaXgoKSk7CiAgICB9CgogICAg
ZnVuY3Rpb24gY2xpcEhheShjKSB7CiAgICAgICAgcmV0dXJuIFN0cmluZyhjLnByZXZpZXcgfHwg
JycpICsgJyAnICsgU3RyaW5nKGMuZGF0YSB8fCAnJykgKyAnICcKICAgICAgICAgICAgKyBTdHJp
bmcoYy5saW5rVGl0bGUgfHwgJycpICsgJyAnICsgU3RyaW5nKGMuZmF2VGl0bGUgfHwgJycpOwog
ICAgfQogICAgLyoqIE1hdGNoIEFISyBJdGVtTWF0Y2hlc1ZpZXcgbGlzdCBzZWFyY2gg4oCUIHBy
ZXZpZXcgKCsgc2hvcnQgYm9keSBmYWxsYmFjayksIG5vdCBmdWxsIGRhdGEgKi8KICAgIGZ1bmN0
aW9uIGNsaXBTZWFyY2hIYXkoYykgewogICAgICAgIGNvbnN0IHR5cGUgPSBTdHJpbmcoYy50eXBl
IHx8ICcnKS50b0xvd2VyQ2FzZSgpOwogICAgICAgIGlmICh0eXBlID09PSAnaW1hZ2UnKQogICAg
ICAgICAgICByZXR1cm4gU3RyaW5nKGMuZmF2VGl0bGUgfHwgJycpOwogICAgICAgIGlmICh0eXBl
ID09PSAncmVjZW50JykgewogICAgICAgICAgICByZXR1cm4gU3RyaW5nKGMuZGF0YSB8fCBjLnBy
ZXZpZXcgfHwgJycpICsgJyAnICsgU3RyaW5nKGMuZmF2VGl0bGUgfHwgJycpOwogICAgICAgIH0K
ICAgICAgICBpZiAodHlwZSA9PT0gJ2ZpbGUnKSB7CiAgICAgICAgICAgIHJldHVybiBTdHJpbmco
Yy5wcmV2aWV3IHx8ICcnKSArICcgJyArIFN0cmluZyhjLmRhdGEgfHwgJycpICsgJyAnCiAgICAg
ICAgICAgICAgICArIFN0cmluZyhjLmZhdlRpdGxlIHx8ICcnKTsKICAgICAgICB9CiAgICAgICAg
bGV0IHByZXYgPSBTdHJpbmcoYy5wcmV2aWV3IHx8ICcnKTsKICAgICAgICBpZiAoIXByZXYgJiYg
Yy5kYXRhKQogICAgICAgICAgICBwcmV2ID0gU3RyaW5nKGMuZGF0YSkuc2xpY2UoMCwgNTAwKTsK
ICAgICAgICByZXR1cm4gcHJldiArICcgJyArIFN0cmluZyhjLmxpbmtUaXRsZSB8fCAnJykgKyAn
ICcgKyBTdHJpbmcoYy5mYXZUaXRsZSB8fCAnJyk7CiAgICB9CiAgICBmdW5jdGlvbiBjbGlwTWF0
Y2hlc1NlYXJjaChjLCB0ZXJtTCkgewogICAgICAgIGNvbnN0IHR5cGUgPSBTdHJpbmcoYy50eXBl
IHx8ICcnKS50b0xvd2VyQ2FzZSgpOwogICAgICAgIGNvbnN0IGhheSA9ICh0eXBlID09PSAnaW1h
Z2UnID8gU3RyaW5nKGMuZmF2VGl0bGUgfHwgJycpIDogY2xpcFNlYXJjaEhheShjKSkudG9Mb3dl
ckNhc2UoKTsKICAgICAgICByZXR1cm4gdGVybUwuZXZlcnkodCA9PiBoYXkuaW5jbHVkZXModCkp
OwogICAgfQogICAgZnVuY3Rpb24gZmlsdGVyKGNsaXBzLCB0YWIsIHEpIHsKICAgICAgICAvLyDk
uLvmnLrlt7Lov4fmu6Tml7bku43lgZrliY3nq6/lhZzlupXvvJrpgb/lhY3nq57mgIHmjqjmnaXm
nKrlkb3kuK3ooYwKICAgICAgICBjb25zdCB0ZXJtcyA9IHF1ZXJ5VGVybXMocSk7CiAgICAgICAg
aWYgKCF0ZXJtcy5sZW5ndGgpIHJldHVybiBjbGlwczsKICAgICAgICBjb25zdCB0ZXJtTCA9IHRl
cm1zLm1hcCh0ID0+IHQudG9Mb3dlckNhc2UoKSk7CiAgICAgICAgY29uc3QgbWF0Y2hlZEdyb3Vw
cyA9IG5ldyBTZXQoKTsKICAgICAgICBmb3IgKGNvbnN0IGMgb2YgY2xpcHMpIHsKICAgICAgICAg
ICAgaWYgKCFjbGlwTWF0Y2hlc1NlYXJjaChjLCB0ZXJtTCkpIGNvbnRpbnVlOwogICAgICAgICAg
ICBjb25zdCBnaWQgPSBTdHJpbmcoYyAmJiBjLmZhdkdyb3VwIHx8ICcnKS50cmltKCk7CiAgICAg
ICAgICAgIGlmIChnaWQpIG1hdGNoZWRHcm91cHMuYWRkKGdpZCk7CiAgICAgICAgfQogICAgICAg
IC8vIOWQiOW5tue7hO+8muWFs+mUruWtl+WPr+iDveWIhuaVo+WcqOS4jeWQjOihjO+8iOagh+mi
mC/mraPmlofvvIkKICAgICAgICBjb25zdCBieUdyb3VwID0gbmV3IE1hcCgpOwogICAgICAgIGZv
ciAoY29uc3QgYyBvZiBjbGlwcykgewogICAgICAgICAgICBjb25zdCBnaWQgPSBTdHJpbmcoYyAm
JiBjLmZhdkdyb3VwIHx8ICcnKS50cmltKCk7CiAgICAgICAgICAgIGlmICghZ2lkKSBjb250aW51
ZTsKICAgICAgICAgICAgaWYgKCFieUdyb3VwLmhhcyhnaWQpKSBieUdyb3VwLnNldChnaWQsIFtd
KTsKICAgICAgICAgICAgYnlHcm91cC5nZXQoZ2lkKS5wdXNoKGMpOwogICAgICAgIH0KICAgICAg
ICBmb3IgKGNvbnN0IFtnaWQsIG1lbWJlcnNdIG9mIGJ5R3JvdXApIHsKICAgICAgICAgICAgaWYg
KG1hdGNoZWRHcm91cHMuaGFzKGdpZCkpIGNvbnRpbnVlOwogICAgICAgICAgICBjb25zdCB1bmlv
biA9IG1lbWJlcnMubWFwKGMgPT4gewogICAgICAgICAgICAgICAgY29uc3QgdHlwZSA9IFN0cmlu
ZyhjLnR5cGUgfHwgJycpLnRvTG93ZXJDYXNlKCk7CiAgICAgICAgICAgICAgICByZXR1cm4gKHR5
cGUgPT09ICdpbWFnZScgPyBTdHJpbmcoYy5mYXZUaXRsZSB8fCAnJykgOiBjbGlwU2VhcmNoSGF5
KGMpKS50b0xvd2VyQ2FzZSgpOwogICAgICAgICAgICB9KS5qb2luKCcgJyk7CiAgICAgICAgICAg
IGlmICh0ZXJtTC5ldmVyeSh0ID0+IHVuaW9uLmluY2x1ZGVzKHQpKSkKICAgICAgICAgICAgICAg
IG1hdGNoZWRHcm91cHMuYWRkKGdpZCk7CiAgICAgICAgfQogICAgICAgIGxldCBvdXQgPSBjbGlw
cy5maWx0ZXIoYyA9PiB7CiAgICAgICAgICAgIGlmIChjbGlwTWF0Y2hlc1NlYXJjaChjLCB0ZXJt
TCkpIHJldHVybiB0cnVlOwogICAgICAgICAgICBjb25zdCBnaWQgPSBTdHJpbmcoYyAmJiBjLmZh
dkdyb3VwIHx8ICcnKS50cmltKCk7CiAgICAgICAgICAgIHJldHVybiBnaWQgJiYgbWF0Y2hlZEdy
b3Vwcy5oYXMoZ2lkKTsKICAgICAgICB9KTsKICAgICAgICAvLyDmnIDov5HpobXmkJzntKLvvJrl
kb3kuK3nmoTlm7rlrprpobnmjpLliY3pnaIKICAgICAgICBpZiAodGFiID09PSAncmVjZW50JyB8
fCAob3V0Lmxlbmd0aCAmJiBvdXQuZXZlcnkoYyA9PiBub3JtVHlwZShjLnR5cGUpID09PSAncmVj
ZW50JykpKSB7CiAgICAgICAgICAgIGNvbnN0IHBpbm5lZCA9IFtdOwogICAgICAgICAgICBjb25z
dCByZXN0ID0gW107CiAgICAgICAgICAgIGZvciAoY29uc3QgYyBvZiBvdXQpIHsKICAgICAgICAg
ICAgICAgIGlmIChpc1Bpbm5lZChjKSkgcGlubmVkLnB1c2goYyk7CiAgICAgICAgICAgICAgICBl
bHNlIHJlc3QucHVzaChjKTsKICAgICAgICAgICAgfQogICAgICAgICAgICBvdXQgPSBwaW5uZWQu
Y29uY2F0KHJlc3QpOwogICAgICAgIH0KICAgICAgICByZXR1cm4gb3V0OwogICAgfQoKICAgIGZ1
bmN0aW9uIG1hcmtQYXN0ZWRMb2NhbChpZHMpIHsKICAgICAgICBjb25zdCBsaXN0ID0gQXJyYXku
aXNBcnJheShpZHMpID8gaWRzIDogW2lkc107CiAgICAgICAgaWYgKGxpc3QubGVuZ3RoKQogICAg
ICAgICAgICByZW1lbWJlckxhc3RQYXN0ZShsaXN0W2xpc3QubGVuZ3RoIC0gMV0pOwogICAgICAg
IGNvbnN0IGJhZGdlSHRtbCA9IGA8c3ZnIHZpZXdCb3g9IjAgMCAxNiAxNiIgZmlsbD0ibm9uZSIg
c3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0cm9rZS13aWR0aD0iMi40IiBzdHJva2UtbGluZWNhcD0i
cm91bmQiIHN0cm9rZS1saW5lam9pbj0icm91bmQiPjxwb2x5bGluZSBwb2ludHM9IjMuNSA4LjUg
Ni41IDExLjUgMTIuNSA0LjUiLz48L3N2Zz5gOwogICAgICAgIGxpc3QuZm9yRWFjaChyYXdJZCA9
PiB7CiAgICAgICAgICAgIGNvbnN0IGlkID0gK3Jhd0lkOwogICAgICAgICAgICBjb25zdCBjID0g
YWxsQ2xpcHMuZmluZCh4ID0+ICt4LmlkID09PSBpZCk7CiAgICAgICAgICAgIGlmIChjKSBjLnBh
c3RlZCA9IHRydWU7CiAgICAgICAgICAgIGNvbnN0IHJvdyA9IGxpc3RFbCAmJiAoCiAgICAgICAg
ICAgICAgICBsaXN0RWwucXVlcnlTZWxlY3RvcignLml0bVtkYXRhLWlkPSInICsgaWQgKyAnIl0n
KQogICAgICAgICAgICAgICAgfHwgbGlzdEVsLnF1ZXJ5U2VsZWN0b3IoJy5pdG1bZGF0YS1pZD0i
JyArIFN0cmluZyhyYXdJZCkgKyAnIl0nKQogICAgICAgICAgICApOwogICAgICAgICAgICBpZiAo
IXJvdykgcmV0dXJuOwogICAgICAgICAgICByb3cuY2xhc3NMaXN0LmFkZCgncGFzdGVkJywgJ3Et
ZG9uZScpOwogICAgICAgICAgICBjb25zdCBpY28gPSByb3cucXVlcnlTZWxlY3RvcignLmktaWNv
Jyk7CiAgICAgICAgICAgIGlmIChpY28gJiYgIWljby5xdWVyeVNlbGVjdG9yKCcuaS11c2VkJykp
IHsKICAgICAgICAgICAgICAgIGNvbnN0IGJhZGdlID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgn
c3BhbicpOwogICAgICAgICAgICAgICAgYmFkZ2UuY2xhc3NOYW1lID0gJ2ktdXNlZCc7CiAgICAg
ICAgICAgICAgICBiYWRnZS50aXRsZSA9ICflt7LnspjotLQnOwogICAgICAgICAgICAgICAgYmFk
Z2UuaW5uZXJIVE1MID0gYmFkZ2VIdG1sOwogICAgICAgICAgICAgICAgaWNvLmFwcGVuZENoaWxk
KGJhZGdlKTsKICAgICAgICAgICAgfQogICAgICAgIH0pOwogICAgICAgIHRyeSB7IG1hcmtRdWV1
ZVJhaWxzKCk7IH0gY2F0Y2ggKGUpIHt9CiAgICB9CiAgICB3aW5kb3cuX19tYXJrUGFzdGVkID0g
bWFya1Bhc3RlZExvY2FsOwoKICAgIGZ1bmN0aW9uIG1hcmtVbnBhc3RlZExvY2FsKGlkcykgewog
ICAgICAgIGNvbnN0IGxpc3QgPSBBcnJheS5pc0FycmF5KGlkcykgPyBpZHMgOiBbaWRzXTsKICAg
ICAgICBsaXN0LmZvckVhY2gocmF3SWQgPT4gewogICAgICAgICAgICBjb25zdCBpZCA9ICtyYXdJ
ZDsKICAgICAgICAgICAgY29uc3QgYyA9IGFsbENsaXBzLmZpbmQoeCA9PiAreC5pZCA9PT0gaWQp
OwogICAgICAgICAgICBpZiAoYykgYy5wYXN0ZWQgPSBmYWxzZTsKICAgICAgICAgICAgY29uc3Qg
cm93ID0gbGlzdEVsICYmICgKICAgICAgICAgICAgICAgIGxpc3RFbC5xdWVyeVNlbGVjdG9yKCcu
aXRtW2RhdGEtaWQ9IicgKyBpZCArICciXScpCiAgICAgICAgICAgICAgICB8fCBsaXN0RWwucXVl
cnlTZWxlY3RvcignLml0bVtkYXRhLWlkPSInICsgU3RyaW5nKHJhd0lkKSArICciXScpCiAgICAg
ICAgICAgICk7CiAgICAgICAgICAgIGlmICghcm93KSByZXR1cm47CiAgICAgICAgICAgIHJvdy5j
bGFzc0xpc3QucmVtb3ZlKCdwYXN0ZWQnLCAncS1kb25lJywgJ3EtZG9uZS1saW5rJyk7CiAgICAg
ICAgICAgIGNvbnN0IGJhZGdlID0gcm93LnF1ZXJ5U2VsZWN0b3IoJy5pLXVzZWQnKTsKICAgICAg
ICAgICAgaWYgKGJhZGdlKSBiYWRnZS5yZW1vdmUoKTsKICAgICAgICAgICAgY29uc3QgZG90ID0g
cm93LnF1ZXJ5U2VsZWN0b3IoJy5xLWRvdCcpOwogICAgICAgICAgICBpZiAoZG90KSBkb3QudGl0
bGUgPSAn57KY6LS06Zif5YiXJzsKICAgICAgICB9KTsKICAgICAgICB0cnkgeyBtYXJrUXVldWVS
YWlscygpOyB9IGNhdGNoIChlKSB7fQogICAgfQogICAgd2luZG93Ll9fbWFya1VucGFzdGVkID0g
bWFya1VucGFzdGVkTG9jYWw7CgogICAgY29uc3QgbGlzdEVsICA9IGRvY3VtZW50LmdldEVsZW1l
bnRCeUlkKCdsaXN0Jyk7CiAgICBjb25zdCBlbXB0eUVsID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5
SWQoJ2VtcHR5Jyk7CiAgICBjb25zdCBza2VsRWwgID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQo
J3NrZWwnKTsKICAgIGNvbnN0IGJ0blRvcCAgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYnRu
LXRvcCcpOwogICAgZnVuY3Rpb24gc2V0Qm9vdExvYWRpbmcob24pIHsKICAgICAgICBib290TG9h
ZGluZyA9ICEhb247CiAgICAgICAgLy8g56eS5byA77ya5LiN5YaN5omT5byA6aqo5p626Zeq5Yqo
77yb5Y+q5L+d55WZIHdhaXRpbmdEYXRhIOmAu+i+kemYsuepuuaAgeivr+mXqgogICAgICAgIGlm
IChza2VsRWwpIHNrZWxFbC5jbGFzc0xpc3QucmVtb3ZlKCdvbicpOwogICAgICAgIGlmIChvbiAm
JiBlbXB0eUVsKSBlbXB0eUVsLmNsYXNzTGlzdC5yZW1vdmUoJ29uJyk7CiAgICAgICAgY29uc3Qg
YXBwID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2FwcCcpOwogICAgICAgIGlmIChhcHApIGFw
cC5jbGFzc0xpc3QucmVtb3ZlKCdib290LWxvYWRpbmcnKTsKICAgIH0KICAgIC8qKiBXYWl0IGZv
ciBob3N0IGRhdGEg4oCU5LiN5YaN56uL5Yi75by56aqo5p6277yM5pyJ5YaF5a655pe25L+d5oyB
5pen5YiX6KGoICovCiAgICBmdW5jdGlvbiBzY2hlZHVsZURlbGF5ZWRTa2VsKCkgewogICAgICAg
IHdhaXRpbmdEYXRhID0gdHJ1ZTsKICAgICAgICB3aW5kb3cuX19kYXRhUmVhZHkgPSBmYWxzZTsK
ICAgICAgICBpZiAoZW1wdHlFbCkgZW1wdHlFbC5jbGFzc0xpc3QucmVtb3ZlKCdvbicpOwogICAg
ICAgIGlmICh3aW5kb3cuX19wZW5kaW5nU2tlbFRpbWVyKSB7CiAgICAgICAgICAgIGNsZWFyVGlt
ZW91dCh3aW5kb3cuX19wZW5kaW5nU2tlbFRpbWVyKTsKICAgICAgICAgICAgd2luZG93Ll9fcGVu
ZGluZ1NrZWxUaW1lciA9IDA7CiAgICAgICAgfQogICAgICAgIHdpbmRvdy5fX3BlbmRpbmdTa2Vs
U2luY2UgPSBEYXRlLm5vdygpOwogICAgICAgIC8vIOacieaXp+WIl+ihqOWwseS/neeVme+8m+ep
uuWIl+ihqOS5n+S4jeWGjeaSremqqOaetuWKqOeUuwogICAgfQogICAgZnVuY3Rpb24gY2xlYXJX
YWl0aW5nRGF0YSgpIHsKICAgICAgICB3YWl0aW5nRGF0YSA9IGZhbHNlOwogICAgICAgIGlmICh3
aW5kb3cuX19wZW5kaW5nU2tlbFRpbWVyKSB7CiAgICAgICAgICAgIGNsZWFyVGltZW91dCh3aW5k
b3cuX19wZW5kaW5nU2tlbFRpbWVyKTsKICAgICAgICAgICAgd2luZG93Ll9fcGVuZGluZ1NrZWxU
aW1lciA9IDA7CiAgICAgICAgfQogICAgICAgIHdpbmRvdy5fX3BlbmRpbmdTa2VsU2luY2UgPSAw
OwogICAgICAgIHNldEJvb3RMb2FkaW5nKGZhbHNlKTsKICAgIH0KICAgIHdpbmRvdy5zZXRCb290
TG9hZGluZyA9IHNldEJvb3RMb2FkaW5nOwogICAgd2luZG93LmZvcmNlRW5kQm9vdExvYWRpbmcg
PSBmdW5jdGlvbigpIHsKICAgICAgICBjbGVhcldhaXRpbmdEYXRhKCk7CiAgICAgICAgLy8gRG8g
bm90IGZha2XjgIzmmoLml6DorrDlvZXjgI1pZiBob3N0IG5ldmVyIHB1c2hlZAogICAgICAgIGlm
IChob3N0UHVzaGVkT25jZSkKICAgICAgICAgICAgd2luZG93Ll9fZGF0YVJlYWR5ID0gdHJ1ZTsK
ICAgICAgICB0cnkgeyByZW5kZXIoKTsgfSBjYXRjaCAoZSkge30KICAgIH07CiAgICAvLyBTYWZl
dHk6IGRyb3Agc3R1Y2sgc2tlbGV0b247IHN0aWxsIG5ldmVyIGludmVudCBlbXB0eS1zdGF0ZSB3
aXRob3V0IGhvc3QgcHVzaAogICAgc2V0VGltZW91dCgoKSA9PiB7CiAgICAgICAgaWYgKGhvc3RQ
dXNoZWRPbmNlIHx8IHdpbmRvdy5fX2RhdGFSZWFkeSkgcmV0dXJuOwogICAgICAgIGlmICghYm9v
dExvYWRpbmcgJiYgIXdhaXRpbmdEYXRhKSByZXR1cm47CiAgICAgICAgY2xlYXJXYWl0aW5nRGF0
YSgpOwogICAgICAgIHRyeSB7IHJlbmRlcigpOyB9IGNhdGNoIHt9CiAgICB9LCA4MDAwKTsKCiAg
ICBmdW5jdGlvbiB1cGRhdGVUb3BCdG4oKSB7CiAgICAgICAgaWYgKCFidG5Ub3AgfHwgIWxpc3RF
bCkgcmV0dXJuOwogICAgICAgIGJ0blRvcC5jbGFzc0xpc3QudG9nZ2xlKCdvbicsIGxpc3RFbC5z
Y3JvbGxUb3AgPiA0OCk7CiAgICB9CiAgICBsZXQgX3Njcm9sbFJhZiA9IDA7CiAgICBsZXQgX3Nj
cm9sbElkbGVUID0gMDsKICAgIGxldCBfbGlzdFB0ckRvd24gPSBmYWxzZTsKICAgIGxldCBfcGVu
ZGluZ0FwcGVuZCA9IG51bGw7IC8vIHsgZnJvbUxlbiB9IHF1ZXVlZCB3aGlsZSBzY3JvbGxpbmcK
ICAgIHdpbmRvdy5fX3Njcm9sbEJ1c3kgPSBmYWxzZTsKICAgIHdpbmRvdy5fX3dhbnRNb3JlID0g
ZmFsc2U7CgogICAgZnVuY3Rpb24gbWFya0xpc3RTY3JvbGxpbmcoKSB7CiAgICAgICAgd2luZG93
Ll9fc2Nyb2xsQnVzeSA9IHRydWU7CiAgICAgICAgdHJ5IHsgbGlzdEVsLmNsYXNzTGlzdC5hZGQo
J2lzLXNjcm9sbGluZycpOyB9IGNhdGNoIHt9CiAgICAgICAgaWYgKF9zY3JvbGxJZGxlVCkgY2xl
YXJUaW1lb3V0KF9zY3JvbGxJZGxlVCk7CiAgICAgICAgX3Njcm9sbElkbGVUID0gc2V0VGltZW91
dCgoKSA9PiB7CiAgICAgICAgICAgIF9zY3JvbGxJZGxlVCA9IDA7CiAgICAgICAgICAgIGZsdXNo
U2Nyb2xsSWRsZSgpOwogICAgICAgIH0sIDIyMCk7CiAgICB9CgogICAgZnVuY3Rpb24gZmx1c2hT
Y3JvbGxJZGxlKCkgewogICAgICAgIGlmIChfbGlzdFB0ckRvd24pIHsKICAgICAgICAgICAgbWFy
a0xpc3RTY3JvbGxpbmcoKTsKICAgICAgICAgICAgcmV0dXJuOwogICAgICAgIH0KICAgICAgICB3
aW5kb3cuX19zY3JvbGxCdXN5ID0gZmFsc2U7CiAgICAgICAgdHJ5IHsgbGlzdEVsLmNsYXNzTGlz
dC5yZW1vdmUoJ2lzLXNjcm9sbGluZycpOyB9IGNhdGNoIHt9CiAgICAgICAgaWYgKF9wZW5kaW5n
QXBwZW5kKSB7CiAgICAgICAgICAgIGNvbnN0IHBlbmRpbmcgPSBfcGVuZGluZ0FwcGVuZDsKICAg
ICAgICAgICAgX3BlbmRpbmdBcHBlbmQgPSBudWxsOwogICAgICAgICAgICBhcHBseUFwcGVuZFBh
eWxvYWQocGVuZGluZyk7CiAgICAgICAgfQogICAgICAgIGlmICh3aW5kb3cuX193YW50TW9yZSkK
ICAgICAgICAgICAgcmVxdWVzdE1vcmUoKTsKICAgICAgICBlbHNlIGlmICghbG9hZGluZ01vcmUK
ICAgICAgICAgICAgJiYgZGlza1RvdGFsID4gMAogICAgICAgICAgICAmJiBhbGxDbGlwcy5sZW5n
dGggPCBkaXNrVG90YWwKICAgICAgICAgICAgJiYgbGlzdEVsLnNjcm9sbFRvcCArIGxpc3RFbC5j
bGllbnRIZWlnaHQgPj0gbGlzdEVsLnNjcm9sbEhlaWdodCAtIDQyMCkKICAgICAgICAgICAgcmVx
dWVzdE1vcmUoKTsKICAgIH0KCiAgICBmdW5jdGlvbiBvbkxpc3RTY3JvbGwoKSB7CiAgICAgICAg
bWFya0xpc3RTY3JvbGxpbmcoKTsKICAgICAgICBpZiAoX3Njcm9sbFJhZikgcmV0dXJuOwogICAg
ICAgIF9zY3JvbGxSYWYgPSByZXF1ZXN0QW5pbWF0aW9uRnJhbWUoKCkgPT4gewogICAgICAgICAg
ICBfc2Nyb2xsUmFmID0gMDsKICAgICAgICAgICAgdHJ5IHsgaGlkZVBhdGhUaXAoKTsgfSBjYXRj
aCB7fQogICAgICAgICAgICB1cGRhdGVUb3BCdG4oKTsKICAgICAgICAgICAgaWYgKCFsb2FkaW5n
TW9yZQogICAgICAgICAgICAgICAgJiYgZGlza1RvdGFsID4gMAogICAgICAgICAgICAgICAgJiYg
YWxsQ2xpcHMubGVuZ3RoIDwgZGlza1RvdGFsCiAgICAgICAgICAgICAgICAmJiBsaXN0RWwuc2Ny
b2xsVG9wICsgbGlzdEVsLmNsaWVudEhlaWdodCA+PSBsaXN0RWwuc2Nyb2xsSGVpZ2h0IC0gMjQw
KQogICAgICAgICAgICAgICAgd2luZG93Ll9fd2FudE1vcmUgPSB0cnVlOwogICAgICAgIH0pOwog
ICAgfQogICAgbGlzdEVsLmFkZEV2ZW50TGlzdGVuZXIoJ3Njcm9sbCcsIG9uTGlzdFNjcm9sbCwg
eyBwYXNzaXZlOiB0cnVlIH0pOwogICAgbGlzdEVsLmFkZEV2ZW50TGlzdGVuZXIoJ3doZWVsJywg
bWFya0xpc3RTY3JvbGxpbmcsIHsgcGFzc2l2ZTogdHJ1ZSB9KTsKICAgIGxpc3RFbC5hZGRFdmVu
dExpc3RlbmVyKCdwb2ludGVyZG93bicsIGUgPT4gewogICAgICAgIGlmIChlLmJ1dHRvbiAhPT0g
MCkgcmV0dXJuOwogICAgICAgIF9saXN0UHRyRG93biA9IHRydWU7CiAgICAgICAgbWFya0xpc3RT
Y3JvbGxpbmcoKTsKICAgIH0sIHsgcGFzc2l2ZTogdHJ1ZSB9KTsKICAgIHdpbmRvdy5hZGRFdmVu
dExpc3RlbmVyKCdwb2ludGVydXAnLCAoKSA9PiB7CiAgICAgICAgaWYgKCFfbGlzdFB0ckRvd24p
IHJldHVybjsKICAgICAgICBfbGlzdFB0ckRvd24gPSBmYWxzZTsKICAgICAgICBtYXJrTGlzdFNj
cm9sbGluZygpOwogICAgfSwgeyBwYXNzaXZlOiB0cnVlIH0pOwogICAgd2luZG93LmFkZEV2ZW50
TGlzdGVuZXIoJ3BvaW50ZXJjYW5jZWwnLCAoKSA9PiB7CiAgICAgICAgaWYgKCFfbGlzdFB0ckRv
d24pIHJldHVybjsKICAgICAgICBfbGlzdFB0ckRvd24gPSBmYWxzZTsKICAgICAgICBtYXJrTGlz
dFNjcm9sbGluZygpOwogICAgfSwgeyBwYXNzaXZlOiB0cnVlIH0pOwogICAgYnRuVG9wLmFkZEV2
ZW50TGlzdGVuZXIoJ2NsaWNrJywgZSA9PiB7CiAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsK
ICAgICAgICBsaXN0RWwuc2Nyb2xsVG8oeyB0b3A6IDAsIGJlaGF2aW9yOiAnc21vb3RoJyB9KTsK
ICAgIH0pOwoKICAgIGZ1bmN0aW9uIHZpc2libGVMaXN0KCkgewogICAgICAgIGNvbnN0IHEgPSBT
dHJpbmcocXVlcnkgfHwgJycpLnRyaW0oKTsKICAgICAgICAvLyBIb3N0IGFscmVhZHkgZmlsdGVy
ZWQrZXhwYW5kZWQgZm9yIHRoaXMgZXhhY3QgcXVlcnkg4oCUIGRvbid0IHJlLWZpbHRlciAoYXZv
aWRzIGZsYXNoIC8gZHJvcHBlZCBmYXYgZ3JvdXBzKQogICAgICAgIGxldCBsaXN0ID0gKHEgJiYg
d2luZG93Ll9faG9zdEZpbHRlcmVkICYmIHdpbmRvdy5fX2hvc3RGaWx0ZXJRID09PSBxKQogICAg
ICAgICAgICA/IGFsbENsaXBzCiAgICAgICAgICAgIDogZmlsdGVyKGFsbENsaXBzLCBjdXJUYWIs
IHF1ZXJ5KTsKICAgICAgICAvLyDmlLbol4/pobXvvJrmnKzlnLDlho3mu6TkuIDmrKHvvIzlj5bm
tojmlLbol4/lj6/nq4vliLvmtojlpLHvvIzkuI3lv4XnrYkgQUhLIOmHjeW7ugogICAgICAgIGlm
IChjdXJUYWIgPT09ICdwaW5uZWQnKQogICAgICAgICAgICBsaXN0ID0gbGlzdC5maWx0ZXIoYyA9
PiBpc1Bpbm5lZChjKSk7CiAgICAgICAgcmV0dXJuIGxpc3Q7CiAgICB9CiAgICBmdW5jdGlvbiBl
c2NIdG1sKHMpIHsKICAgICAgICByZXR1cm4gU3RyaW5nKHMgPz8gJycpLnJlcGxhY2UoLyYvZywn
JmFtcDsnKS5yZXBsYWNlKC88L2csJyZsdDsnKS5yZXBsYWNlKC8+L2csJyZndDsnKS5yZXBsYWNl
KC8iL2csJyZxdW90OycpOwogICAgfQogICAgZnVuY3Rpb24gcXVlcnlUZXJtcyhxKSB7CiAgICAg
ICAgY29uc3Qgb3V0ID0gW107CiAgICAgICAgZm9yIChjb25zdCBzZWcgb2YgU3RyaW5nKHEgfHwg
JycpLnNwbGl0KCd8JykpIHsKICAgICAgICAgICAgY29uc3QgcyA9IHNlZy50cmltKCk7CiAgICAg
ICAgICAgIGlmICghcykgY29udGludWU7CiAgICAgICAgICAgIGNvbnN0IHdvcmRzID0gcy5zcGxp
dCgvXHMrLykuZmlsdGVyKEJvb2xlYW4pOwogICAgICAgICAgICBpZiAod29yZHMubGVuZ3RoKSBv
dXQucHVzaCguLi53b3Jkcyk7CiAgICAgICAgfQogICAgICAgIHJldHVybiBvdXQ7CiAgICB9CiAg
ICBmdW5jdGlvbiBobEh0bWwodGV4dCkgewogICAgICAgIGNvbnN0IHRlcm1zID0gcXVlcnlUZXJt
cyhxdWVyeSk7CiAgICAgICAgY29uc3QgcyA9IFN0cmluZyh0ZXh0ID8/ICcnKTsKICAgICAgICBp
ZiAoIXRlcm1zLmxlbmd0aCkgcmV0dXJuIGVzY0h0bWwocyk7CiAgICAgICAgY29uc3QgbG93ZXIg
PSBzLnRvTG93ZXJDYXNlKCk7CiAgICAgICAgY29uc3QgdGVybUwgPSB0ZXJtcy5tYXAodCA9PiB0
LnRvTG93ZXJDYXNlKCkpOwogICAgICAgIGxldCBvdXQgPSAnJywgaSA9IDA7CiAgICAgICAgd2hp
bGUgKGkgPCBzLmxlbmd0aCkgewogICAgICAgICAgICBsZXQgYmVzdEogPSAtMSwgYmVzdExlbiA9
IDA7CiAgICAgICAgICAgIGZvciAobGV0IHRpID0gMDsgdGkgPCB0ZXJtTC5sZW5ndGg7IHRpKysp
IHsKICAgICAgICAgICAgICAgIGNvbnN0IHQgPSB0ZXJtTFt0aV07CiAgICAgICAgICAgICAgICBp
ZiAoIXQpIGNvbnRpbnVlOwogICAgICAgICAgICAgICAgY29uc3QgaiA9IGxvd2VyLmluZGV4T2Yo
dCwgaSk7CiAgICAgICAgICAgICAgICBpZiAoaiA8IDApIGNvbnRpbnVlOwogICAgICAgICAgICAg
ICAgaWYgKGJlc3RKIDwgMCB8fCBqIDwgYmVzdEogfHwgKGogPT09IGJlc3RKICYmIHQubGVuZ3Ro
ID4gYmVzdExlbikpIHsKICAgICAgICAgICAgICAgICAgICBiZXN0SiA9IGo7IGJlc3RMZW4gPSB0
Lmxlbmd0aDsKICAgICAgICAgICAgICAgIH0KICAgICAgICAgICAgfQogICAgICAgICAgICBpZiAo
YmVzdEogPCAwKSB7IG91dCArPSBlc2NIdG1sKHMuc2xpY2UoaSkpOyBicmVhazsgfQogICAgICAg
ICAgICBvdXQgKz0gZXNjSHRtbChzLnNsaWNlKGksIGJlc3RKKSk7CiAgICAgICAgICAgIG91dCAr
PSAnPG1hcmsgY2xhc3M9InEtaGwiPicgKyBlc2NIdG1sKHMuc2xpY2UoYmVzdEosIGJlc3RKICsg
YmVzdExlbikpICsgJzwvbWFyaz4nOwogICAgICAgICAgICBpID0gYmVzdEogKyBNYXRoLm1heCgx
LCBiZXN0TGVuKTsKICAgICAgICB9CiAgICAgICAgcmV0dXJuIG91dDsKICAgIH0KICAgIGZ1bmN0
aW9uIHNldEhsVGV4dChlbCwgdGV4dCkgewogICAgICAgIGlmICghZWwpIHJldHVybjsKICAgICAg
ICBjb25zdCBxID0gU3RyaW5nKHF1ZXJ5IHx8ICcnKS50cmltKCk7CiAgICAgICAgaWYgKCFxKSB7
CiAgICAgICAgICAgIGVsLmNsYXNzTGlzdC5yZW1vdmUoJ2hhcy1obCcpOwogICAgICAgICAgICBl
bC50ZXh0Q29udGVudCA9IHRleHQgPT0gbnVsbCA/ICcnIDogU3RyaW5nKHRleHQpOwogICAgICAg
ICAgICByZXR1cm47CiAgICAgICAgfQogICAgICAgIGVsLmNsYXNzTGlzdC5hZGQoJ2hhcy1obCcp
OwogICAgICAgIGVsLmlubmVySFRNTCA9IGhsSHRtbCh0ZXh0KTsKICAgIH0KCgogICAgZnVuY3Rp
b24gYXBwbHlUYWJTd2l0Y2hBbmltKCkgewogICAgICAgIGlmICghdGFiU3dpdGNoQW5pbURpciB8
fCAhbGlzdEVsKSByZXR1cm47CiAgICAgICAgaWYgKCFsaXN0RWwucXVlcnlTZWxlY3RvcignLml0
bSwgI2VtcHR5Lm9uLCAjbGlzdC1tb3JlJykpCiAgICAgICAgICAgIHJldHVybjsKICAgICAgICBj
b25zdCBkaXIgPSB0YWJTd2l0Y2hBbmltRGlyOwogICAgICAgIHRhYlN3aXRjaEFuaW1EaXIgPSAw
OwogICAgICAgIGxpc3RFbC5jbGFzc0xpc3QucmVtb3ZlKCd0YWItaW4tbHInLCAndGFiLWluLXJs
Jyk7CiAgICAgICAgdm9pZCBsaXN0RWwub2Zmc2V0V2lkdGg7CiAgICAgICAgbGlzdEVsLmNsYXNz
TGlzdC5hZGQoZGlyID4gMCA/ICd0YWItaW4tbHInIDogJ3RhYi1pbi1ybCcpOwogICAgICAgIGNs
ZWFyVGltZW91dChsaXN0RWwuX3RhYkFuaW1UaW1lcik7CiAgICAgICAgbGlzdEVsLl90YWJBbmlt
VGltZXIgPSBzZXRUaW1lb3V0KCgpID0+IHsKICAgICAgICAgICAgbGlzdEVsLmNsYXNzTGlzdC5y
ZW1vdmUoJ3RhYi1pbi1scicsICd0YWItaW4tcmwnKTsKICAgICAgICB9LCA0MDApOwogICAgfQoK
ICAgIGZ1bmN0aW9uIHRhYkluZGV4KHRhYikgewogICAgICAgIGNvbnN0IGkgPSBUQUJfT1JERVIu
aW5kZXhPZih0YWIpOwogICAgICAgIHJldHVybiBpID49IDAgPyBpIDogMDsKICAgIH0KCiAgICBm
dW5jdGlvbiBtb3ZlVGFiSW5rKGluc3RhbnQsIHRhcmdldEVsKSB7CiAgICAgICAgY29uc3QgaW5r
ID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3RhYi1pbmsnKTsKICAgICAgICBjb25zdCB0YWJz
ID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3RhYnMnKTsKICAgICAgICBjb25zdCBlbCA9IHRh
cmdldEVsIHx8IGRvY3VtZW50LnF1ZXJ5U2VsZWN0b3IoJyN0YWJzIC50YWIub24nKTsKICAgICAg
ICBpZiAoIWluayB8fCAhdGFicyB8fCAhZWwpIHJldHVybjsKICAgICAgICBjb25zdCB0ciA9IHRh
YnMuZ2V0Qm91bmRpbmdDbGllbnRSZWN0KCk7CiAgICAgICAgY29uc3QgciA9IGVsLmdldEJvdW5k
aW5nQ2xpZW50UmVjdCgpOwogICAgICAgIGNvbnN0IHggPSByLmxlZnQgLSB0ci5sZWZ0OwogICAg
ICAgIGNvbnN0IGggPSBNYXRoLm1heCgyMCwgTWF0aC5yb3VuZChyLmhlaWdodCkpOwogICAgICAg
IGNvbnN0IHkgPSByLnRvcCAtIHRyLnRvcDsKICAgICAgICBjb25zdCB3ID0gTWF0aC5tYXgoMjQs
IHIud2lkdGgpOwogICAgICAgIGNvbnN0IHBvcyA9ICd0cmFuc2xhdGUzZCgnICsgeCArICdweCwn
ICsgeSArICdweCwwKSc7CiAgICAgICAgaW5rLnN0eWxlLnRyYW5zZm9ybU9yaWdpbiA9ICdjZW50
ZXIgYm90dG9tJzsKICAgICAgICBpbmsuc3R5bGUud2lkdGggPSB3ICsgJ3B4JzsKICAgICAgICBp
bmsuc3R5bGUuaGVpZ2h0ID0gaCArICdweCc7CiAgICAgICAgaWYgKGluc3RhbnQpIHsKICAgICAg
ICAgICAgaW5rLnN0eWxlLnRyYW5zaXRpb24gPSAnbm9uZSc7CiAgICAgICAgICAgIGluay5jbGFz
c0xpc3QucmVtb3ZlKCdzcXVhc2gnKTsKICAgICAgICAgICAgaW5rLnN0eWxlLnRyYW5zZm9ybSA9
IHBvcyArICcgc2NhbGVYKDEpJzsKICAgICAgICAgICAgaW5rLm9mZnNldEhlaWdodDsKICAgICAg
ICAgICAgaW5rLnN0eWxlLnRyYW5zaXRpb24gPSAnJzsKICAgICAgICAgICAgcmV0dXJuOwogICAg
ICAgIH0KICAgICAgICAvLyBTbmFwIHRvIGhvdmVyZWQgdGFiLCBleHBhbmQgZnJvbSBib3R0b20t
Y2VudGVyIOKAlCBubyBzbGlkaW5nIGJldHdlZW4gdGFicwogICAgICAgIGluay5zdHlsZS50cmFu
c2l0aW9uID0gJ25vbmUnOwogICAgICAgIGluay5zdHlsZS50cmFuc2Zvcm0gPSBwb3MgKyAnIHNj
YWxlWCgwLjAwMSknOwogICAgICAgIGluay5vZmZzZXRIZWlnaHQ7CiAgICAgICAgaW5rLnN0eWxl
LnRyYW5zaXRpb24gPSAnJzsKICAgICAgICBpbmsuY2xhc3NMaXN0LmFkZCgnc3F1YXNoJyk7CiAg
ICAgICAgaW5rLnN0eWxlLnRyYW5zZm9ybSA9IHBvcyArICcgc2NhbGVYKDEpJzsKICAgICAgICBj
bGVhclRpbWVvdXQoaW5rLl9zcXVhc2hUaW1lcik7CiAgICAgICAgaW5rLl9zcXVhc2hUaW1lciA9
IHNldFRpbWVvdXQoKCkgPT4gaW5rLmNsYXNzTGlzdC5yZW1vdmUoJ3NxdWFzaCcpLCAzNDApOwog
ICAgfQogICAgZnVuY3Rpb24gbWFya1RhYih0YWIsIGluc3RhbnQpIHsKICAgICAgICBkb2N1bWVu
dC5xdWVyeVNlbGVjdG9yQWxsKCcjdGFicyAudGFiJykuZm9yRWFjaChlbCA9PgogICAgICAgICAg
ICBlbC5jbGFzc0xpc3QudG9nZ2xlKCdvbicsIGVsLmRhdGFzZXQudGFiID09PSB0YWIpKTsKICAg
ICAgICBtb3ZlVGFiSW5rKCEhaW5zdGFudCk7CiAgICB9CiAgICBmdW5jdGlvbiBiaW5kVGFiSW5r
SG92ZXIoKSB7CiAgICAgICAgY29uc3QgdGFicyA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd0
YWJzJyk7CiAgICAgICAgaWYgKCF0YWJzIHx8IHRhYnMuX2lua0hvdmVyQm91bmQpIHJldHVybjsK
ICAgICAgICB0YWJzLl9pbmtIb3ZlckJvdW5kID0gdHJ1ZTsKICAgICAgICB0YWJzLmFkZEV2ZW50
TGlzdGVuZXIoJ3BvaW50ZXJvdmVyJywgZSA9PiB7CiAgICAgICAgICAgIGNvbnN0IHRhYiA9IGUu
dGFyZ2V0LmNsb3Nlc3QoJy50YWInKTsKICAgICAgICAgICAgaWYgKCF0YWIgfHwgIXRhYnMuY29u
dGFpbnModGFiKSkgcmV0dXJuOwogICAgICAgICAgICBtb3ZlVGFiSW5rKGZhbHNlLCB0YWIpOwog
ICAgICAgIH0pOwogICAgICAgIHRhYnMuYWRkRXZlbnRMaXN0ZW5lcigncG9pbnRlcmxlYXZlJywg
ZSA9PiB7CiAgICAgICAgICAgIGlmIChlLnJlbGF0ZWRUYXJnZXQgJiYgdGFicy5jb250YWlucyhl
LnJlbGF0ZWRUYXJnZXQpKSByZXR1cm47CiAgICAgICAgICAgIG1vdmVUYWJJbmsoZmFsc2UpOwog
ICAgICAgIH0pOwogICAgfQpmdW5jdGlvbiBzZXRUYWIodGFiKSB7CiAgICAgICAgaWYgKHRhYiA9
PT0gY3VyVGFiKSByZXR1cm47CiAgICAgICAgY29uc3QgZnJvbSA9IHRhYkluZGV4KGN1clRhYik7
CiAgICAgICAgY29uc3QgdG8gPSB0YWJJbmRleCh0YWIpOwogICAgICAgIHRhYlN3aXRjaEFuaW1E
aXIgPSB0byA+IGZyb20gPyAxIDogKHRvIDwgZnJvbSA/IC0xIDogMCk7CiAgICAgICAgY3VyVGFi
ID0gdGFiOwogICAgICAgIGxvYWRpbmdNb3JlID0gZmFsc2U7CiAgICAgICAgbWFya1RhYih0YWIp
OwogICAgICAgIC8vIOaJk+W8gOaUtuiXj+W5tuafpeeci+WQju+8jOa4hemZpOOAjOaWsOaUtuiX
j+OAjee7v+eCuQogICAgICAgIGlmICh0YWIgPT09ICdwaW5uZWQnKQogICAgICAgICAgICBjbGVh
ckZhdlVuc2VlbigpOwoKICAgICAgICAvLyBLZWVwIHNlYXJjaCAidG9kYXkiIGZpbHRlciBpbiBz
eW5jIHdoZW4gc2VhcmNoIGlzIG9wZW4KICAgICAgICB0cnkgewogICAgICAgICAgICBjb25zdCB3
cmFwID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NlYXJjaC13cmFwJyk7CiAgICAgICAgICAg
IGNvbnN0IGJ0blRvZGF5ID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2J0bi10b2RheScpOwog
ICAgICAgICAgICBpZiAod3JhcCAmJiB3cmFwLmNsYXNzTGlzdC5jb250YWlucygnb3BlbicpKSB7
CiAgICAgICAgICAgICAgICBjb25zdCB3YW50VG9kYXkgPSBmYWxzZTsKICAgICAgICAgICAgICAg
IGlmICh0b2RheU9ubHkgIT09IHdhbnRUb2RheSkgewogICAgICAgICAgICAgICAgICAgIHRvZGF5
T25seSA9IHdhbnRUb2RheTsKICAgICAgICAgICAgICAgICAgICBpZiAoYnRuVG9kYXkpIGJ0blRv
ZGF5LmNsYXNzTGlzdC50b2dnbGUoJ29uJywgdG9kYXlPbmx5KTsKICAgICAgICAgICAgICAgIH0K
ICAgICAgICAgICAgfQogICAgICAgIH0gY2F0Y2gge30KCiAgICAgICAgc2VsZWN0ZWRJZCA9IG51
bGw7CiAgICAgICAgbXVsdGlJZHMgPSBbXTsKICAgICAgICBsaXN0RWwuc2Nyb2xsVG9wID0gMDsK
ICAgICAgICBjb25zdCBoaXQgPSB2aWV3TWVtLmdldCh2aWV3TWVtS2V5KHRhYiwgcXVlcnksIHRv
ZGF5T25seSkpOwogICAgICAgIGlmIChoaXQgJiYgQXJyYXkuaXNBcnJheShoaXQuaXRlbXMpICYm
IGhpdC5pdGVtcy5sZW5ndGgpIHsKICAgICAgICAgICAgYWxsQ2xpcHMgPSBoaXQuaXRlbXMuc2xp
Y2UoKTsKICAgICAgICAgICAgZGlza1RvdGFsID0gTnVtYmVyKGhpdC50b3RhbCkgfHwgaGl0Lml0
ZW1zLmxlbmd0aDsKICAgICAgICAgICAgd2luZG93Ll9fd2FpdGluZ1ZpZXcgPSBmYWxzZTsKICAg
ICAgICAgICAgY2xlYXJXYWl0aW5nRGF0YSgpOwogICAgICAgICAgICB3aW5kb3cuX19kYXRhUmVh
ZHkgPSB0cnVlOwogICAgICAgICAgICBob3N0UHVzaGVkT25jZSA9IHRydWU7CiAgICAgICAgICAg
IHNhd05vbkVtcHR5ID0gdHJ1ZTsKICAgICAgICAgICAgcmVuZGVyKCk7CiAgICAgICAgICAgIGFw
cGx5VGFiU3dpdGNoQW5pbSgpOwogICAgICAgICAgICAvLyBNZW1vcnkgcGFpbnQgZmlyc3Qg4oCU
YmFja2dyb3VuZCBzb2Z0LXN5bmMga2VlcHMgQUhLIGluIHN0ZXAgd2l0aG91dCBkb3VibGUgcmVk
cmF3CiAgICAgICAgICAgIHNvZnRSZXF1ZXN0VmlldygpOwogICAgICAgICAgICByZXR1cm47CiAg
ICAgICAgfQogICAgICAgIC8vIE5vIGNhY2hlIHlldDoga2VlcCBjdXJyZW50IHJvd3Mg4oCUIE5F
VkVSIHdpcGUgdG8gYmxhbmsgd2hpdGUKICAgICAgICB3aW5kb3cuX193YWl0aW5nVmlldyA9IHRy
dWU7CiAgICAgICAgc2NoZWR1bGVEZWxheWVkU2tlbCgpOwogICAgICAgIGlmICghYWxsQ2xpcHMu
bGVuZ3RoKQogICAgICAgICAgICByZW5kZXIoKTsKICAgICAgICByZXF1ZXN0VmlldygpOwogICAg
ICAgIGFwcGx5VGFiU3dpdGNoQW5pbSgpOwogICAgfQoKICAgIG1vdmVUYWJJbmsodHJ1ZSk7CiAg
ICBiaW5kVGFiSW5rSG92ZXIoKTsKICAgIHRyeSB7IG5ldyBSZXNpemVPYnNlcnZlcigoKSA9PiBt
b3ZlVGFiSW5rKHRydWUpKS5vYnNlcnZlKGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd0YWJzJykp
OyB9IGNhdGNoIHt9CiAgICB3aW5kb3cuYWRkRXZlbnRMaXN0ZW5lcigncmVzaXplJywgKCkgPT4g
bW92ZVRhYkluayh0cnVlKSk7CgogICAgZnVuY3Rpb24gdXBkYXRlTW9yZUZvb3Rlcih0b3RhbCkg
ewogICAgICAgIGxldCBtb3JlRWwgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbGlzdC1tb3Jl
Jyk7CiAgICAgICAgY29uc3QgbG9hZGVkID0gYWxsQ2xpcHMubGVuZ3RoOwogICAgICAgIGlmIChs
b2FkZWQgPj0gdG90YWwpIHsKICAgICAgICAgICAgaWYgKG1vcmVFbCkgbW9yZUVsLnJlbW92ZSgp
OwogICAgICAgICAgICByZXR1cm47CiAgICAgICAgfQogICAgICAgIGlmICghbW9yZUVsKSB7CiAg
ICAgICAgICAgIG1vcmVFbCA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOwogICAgICAg
ICAgICBtb3JlRWwuaWQgPSAnbGlzdC1tb3JlJzsKICAgICAgICAgICAgbW9yZUVsLmNsYXNzTmFt
ZSA9ICdsaXN0LW1vcmUnOwogICAgICAgICAgICBsaXN0RWwuYXBwZW5kQ2hpbGQobW9yZUVsKTsK
ICAgICAgICB9CiAgICAgICAgbW9yZUVsLnRleHRDb250ZW50ID0gJ+e7p+e7reS4i+a7keS7juej
geebmOWKoOi9ve+8iCcgKyBsb2FkZWQgKyAnLycgKyB0b3RhbCArICfvvIknOwogICAgfQoKICAg
IC8qKiBVcGRhdGUgYmFyIC8gcGluIGJhZGdlIHdpdGhvdXQgdG91Y2hpbmcgdGhlIGxpc3QgRE9N
ICovCiAgICBmdW5jdGlvbiByZWZyZXNoTGlzdENocm9tZSgpIHsKICAgICAgICBjb25zdCB2aXNp
YmxlID0gdmlzaWJsZUxpc3QoKTsKICAgICAgICBjb25zdCBsb2FkZWQgPSBhbGxDbGlwcy5sZW5n
dGg7CiAgICAgICAgY29uc3Qgc2hvd25Db3VudCA9IHZpc2libGUubGVuZ3RoOwogICAgICAgIGxl
dCBwaW5uZWROID0gTnVtYmVyKHBpbm5lZFRvdGFsKSB8fCAwOwogICAgICAgIGlmIChwaW5uZWRO
IDwgMSkgewogICAgICAgICAgICBpZiAoY3VyVGFiID09PSAncGlubmVkJykKICAgICAgICAgICAg
ICAgIHBpbm5lZE4gPSBNYXRoLm1heChOdW1iZXIoZGlza1RvdGFsKSB8fCAwLCBsb2FkZWQpOwog
ICAgICAgICAgICBlbHNlCiAgICAgICAgICAgICAgICBwaW5uZWROID0gYWxsQ2xpcHMuZmlsdGVy
KGMgPT4gaXNQaW5uZWQoYykpLmxlbmd0aDsKICAgICAgICB9CiAgICAgICAgdXBkYXRlUGluRG90
KCk7CiAgICAgICAgbGV0IHNob3dUb3RhbCA9IGRpc2tUb3RhbCA+IDAgPyBkaXNrVG90YWwgOiAo
bG9hZGVkIHx8IDApOwogICAgICAgIGlmIChjdXJUYWIgPT09ICdwaW5uZWQnICYmIHBpbm5lZE4g
PiBzaG93VG90YWwpCiAgICAgICAgICAgIHNob3dUb3RhbCA9IHBpbm5lZE47CiAgICAgICAgY29u
c3QgcU9uID0gU3RyaW5nKHF1ZXJ5IHx8ICcnKS50cmltKCkubGVuZ3RoID4gMDsKICAgICAgICBj
b25zdCBiYXIgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYmFyLXR4dCcpOwogICAgICAgIGlm
IChiYXIpIHsKICAgICAgICAgICAgYmFyLnRleHRDb250ZW50ID0gcU9uCiAgICAgICAgICAgICAg
ICA/IChzaG93bkNvdW50ICsgJyDmnaEnKQogICAgICAgICAgICAgICAgOiAoc2hvd1RvdGFsID4g
bG9hZGVkID8gKHNob3duQ291bnQgKyAnIC8gJyArIHNob3dUb3RhbCArICcg5p2hJykgOiAoc2hv
d1RvdGFsICsgJyDmnaEnKSk7CiAgICAgICAgfQogICAgICAgIHVwZGF0ZU1vcmVGb290ZXIoZGlz
a1RvdGFsKTsKICAgICAgICB1cGRhdGVUb3BCdG4oKTsKICAgIH0KCiAgICAvKioKICAgICAqIExv
YWQtbW9yZTogYXBwZW5kIG9ubHkgbmV3IERPTSBub2Rlcy4gRnVsbCByZW5kZXIoKSBudWtlcyBl
dmVyeSAuaXRtIGFuZAogICAgICogcmVzdG9yZXMgc2Nyb2xsVG9wIOKAlCB0aGF0IGhpdGNoIGlz
IHdoYXQgbWFrZXMgZHJhZ2dpbmcgdGhlIHNjcm9sbGJhciBmZWVsIHN0aWNreS4KICAgICAqLwog
ICAgZnVuY3Rpb24gYXBwZW5kUmVuZGVyKHByZXZMZW4pIHsKICAgICAgICBjb25zdCB2aXNpYmxl
ID0gdmlzaWJsZUxpc3QoKTsKICAgICAgICBpZiAoIXZpc2libGUubGVuZ3RoKSB7CiAgICAgICAg
ICAgIHJlbmRlcigpOwogICAgICAgICAgICByZXR1cm4gZmFsc2U7CiAgICAgICAgfQogICAgICAg
IGlmIChwcmV2TGVuID4gMCAmJiBwcmV2TGVuIDwgYWxsQ2xpcHMubGVuZ3RoKSB7CiAgICAgICAg
ICAgIGNvbnN0IHNlYW1HaWRzID0gbmV3IFNldCgpOwogICAgICAgICAgICBmb3IgKGxldCBpID0g
TWF0aC5tYXgoMCwgcHJldkxlbiAtIDgpOyBpIDwgTWF0aC5taW4oYWxsQ2xpcHMubGVuZ3RoLCBw
cmV2TGVuICsgOCk7IGkrKykgewogICAgICAgICAgICAgICAgY29uc3QgZyA9IGZhdkdyb3VwT2Yo
YWxsQ2xpcHNbaV0pOwogICAgICAgICAgICAgICAgaWYgKGcpIHNlYW1HaWRzLmFkZChnKTsKICAg
ICAgICAgICAgfQogICAgICAgICAgICBpZiAoc2VhbUdpZHMuc2l6ZSkgewogICAgICAgICAgICAg
ICAgZm9yIChjb25zdCBnIG9mIHNlYW1HaWRzKSB7CiAgICAgICAgICAgICAgICAgICAgbGV0IGJl
Zm9yZSA9IDAsIGFmdGVyID0gMDsKICAgICAgICAgICAgICAgICAgICBmb3IgKGxldCBpID0gMDsg
aSA8IGFsbENsaXBzLmxlbmd0aDsgaSsrKSB7CiAgICAgICAgICAgICAgICAgICAgICAgIGlmIChm
YXZHcm91cE9mKGFsbENsaXBzW2ldKSAhPT0gZykgY29udGludWU7CiAgICAgICAgICAgICAgICAg
ICAgICAgIGlmIChpIDwgcHJldkxlbikgYmVmb3JlKys7CiAgICAgICAgICAgICAgICAgICAgICAg
IGVsc2UgYWZ0ZXIrKzsKICAgICAgICAgICAgICAgICAgICB9CiAgICAgICAgICAgICAgICAgICAg
aWYgKGJlZm9yZSA+IDAgJiYgYWZ0ZXIgPiAwKSB7CiAgICAgICAgICAgICAgICAgICAgICAgIHJl
bmRlcigpOwogICAgICAgICAgICAgICAgICAgICAgICByZXR1cm4gZmFsc2U7CiAgICAgICAgICAg
ICAgICAgICAgfQogICAgICAgICAgICAgICAgfQogICAgICAgICAgICB9CiAgICAgICAgfQogICAg
ICAgIGNvbnN0IGJsb2NrcyA9IGJ1aWxkUGlubmVkQmxvY2tzKHZpc2libGUpOwogICAgICAgIGNv
bnN0IGV4aXN0aW5nID0gbGlzdEVsLnF1ZXJ5U2VsZWN0b3JBbGwoJy5pdG0nKS5sZW5ndGg7CiAg
ICAgICAgaWYgKGV4aXN0aW5nIDwgMSkgewogICAgICAgICAgICByZW5kZXIoKTsKICAgICAgICAg
ICAgcmV0dXJuIGZhbHNlOwogICAgICAgIH0KICAgICAgICBpZiAoYmxvY2tzLmxlbmd0aCA8PSBl
eGlzdGluZykgewogICAgICAgICAgICByZWZyZXNoTGlzdENocm9tZSgpOwogICAgICAgICAgICB0
cnkgeyBtYXJrUXVldWVSYWlscygpOyB9IGNhdGNoIChlKSB7fQogICAgICAgICAgICByZXR1cm4g
dHJ1ZTsKICAgICAgICB9CiAgICAgICAgY29uc3QgZnJhZyA9IGRvY3VtZW50LmNyZWF0ZURvY3Vt
ZW50RnJhZ21lbnQoKTsKICAgICAgICBsZXQgbnVtID0gMDsKICAgICAgICBibG9ja3MuZm9yRWFj
aChiID0+IHsKICAgICAgICAgICAgbnVtICs9IDE7CiAgICAgICAgICAgIGlmIChudW0gPD0gZXhp
c3RpbmcpIHJldHVybjsKICAgICAgICAgICAgaWYgKGIua2luZCA9PT0gJ2dyb3VwJyAmJiBiLml0
ZW1zLmxlbmd0aCA+IDEpCiAgICAgICAgICAgICAgICBmcmFnLmFwcGVuZENoaWxkKG1ha2VHcm91
cEl0ZW0oYi5pdGVtcywgbnVtKSk7CiAgICAgICAgICAgIGVsc2UKICAgICAgICAgICAgICAgIGZy
YWcuYXBwZW5kQ2hpbGQobWFrZUl0ZW0oYi5pdGVtc1swXSwgbnVtKSk7CiAgICAgICAgfSk7CiAg
ICAgICAgY29uc3QgbW9yZUVsID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2xpc3QtbW9yZScp
OwogICAgICAgIGlmIChtb3JlRWwpCiAgICAgICAgICAgIGxpc3RFbC5pbnNlcnRCZWZvcmUoZnJh
ZywgbW9yZUVsKTsKICAgICAgICBlbHNlCiAgICAgICAgICAgIGxpc3RFbC5hcHBlbmRDaGlsZChm
cmFnKTsKICAgICAgICB0cnkgeyBtYXJrUXVldWVSYWlscygpOyB9IGNhdGNoIChlKSB7fQogICAg
ICAgIHJlZnJlc2hMaXN0Q2hyb21lKCk7CiAgICAgICAgcmVxdWVzdEFuaW1hdGlvbkZyYW1lKCgp
ID0+IHsKICAgICAgICAgICAgaWYgKGFsbENsaXBzLmxlbmd0aCA8IGRpc2tUb3RhbAogICAgICAg
ICAgICAgICAgJiYgbGlzdEVsLnNjcm9sbEhlaWdodCA8PSBsaXN0RWwuY2xpZW50SGVpZ2h0ICsg
MjApCiAgICAgICAgICAgICAgICByZXF1ZXN0TW9yZSgpOwogICAgICAgICAgICB0cnkgeyBzY2hl
ZHVsZUZpbGVHb25lQ2hlY2soKTsgfSBjYXRjaCB7fQogICAgICAgIH0pOwogICAgICAgIHJldHVy
biB0cnVlOwogICAgfQoKICAgIGZ1bmN0aW9uIGFwcGx5QXBwZW5kUGF5bG9hZChwZW5kaW5nKSB7
CiAgICAgICAgaWYgKCFwZW5kaW5nIHx8IHBlbmRpbmcuZnJvbUxlbiA9PSBudWxsKSByZXR1cm47
CiAgICAgICAgY29uc3QgZnJvbUxlbiA9IE51bWJlcihwZW5kaW5nLmZyb21MZW4pIHx8IDA7CiAg
ICAgICAgaWYgKGZyb21MZW4gPCAwIHx8IGFsbENsaXBzLmxlbmd0aCA8PSBmcm9tTGVuKSB7CiAg
ICAgICAgICAgIHJlZnJlc2hMaXN0Q2hyb21lKCk7CiAgICAgICAgICAgIHJldHVybjsKICAgICAg
ICB9CiAgICAgICAgYXBwZW5kUmVuZGVyKGZyb21MZW4pOwogICAgfQoKICAgIGZ1bmN0aW9uIG5h
dkxpc3QoKSB7CiAgICAgICAgY29uc3QgYmxvY2tzID0gYnVpbGRQaW5uZWRCbG9ja3ModmlzaWJs
ZUxpc3QoKSk7CiAgICAgICAgY29uc3Qgb3V0ID0gW107CiAgICAgICAgZm9yIChjb25zdCBiIG9m
IGJsb2NrcykgewogICAgICAgICAgICBpZiAoIWIgfHwgIWIuaXRlbXMpIGNvbnRpbnVlOwogICAg
ICAgICAgICBmb3IgKGNvbnN0IGMgb2YgYi5pdGVtcykgb3V0LnB1c2goYyk7CiAgICAgICAgfQog
ICAgICAgIHJldHVybiBvdXQ7CiAgICB9CgogICAgZnVuY3Rpb24gc2VsZWN0QnlJbmRleChpZHgp
IHsKICAgICAgICBjb25zdCB2aXMgPSBuYXZMaXN0KCk7CiAgICAgICAgaWYgKCF2aXMubGVuZ3Ro
KSByZXR1cm47CiAgICAgICAgaWR4ID0gTWF0aC5tYXgoMCwgTWF0aC5taW4odmlzLmxlbmd0aCAt
IDEsIGlkeCkpOwogICAgICAgIGlmIChpZHggPj0gdmlzLmxlbmd0aCAtIDEgJiYgYWxsQ2xpcHMu
bGVuZ3RoIDwgZGlza1RvdGFsKQogICAgICAgICAgICByZXF1ZXN0TW9yZSgpOwogICAgICAgIHNl
bGVjdGVkSWQgPSB2aXNbTWF0aC5taW4oaWR4LCB2aXMubGVuZ3RoIC0gMSldLmlkOwogICAgICAg
IHJhbmdlQW5jaG9ySWQgPSBzZWxlY3RlZElkOwogICAgICAgIHJhbmdlQW5jaG9yQ2xpY2tlZCA9
IGZhbHNlOwogICAgICAgIGlmICgrc2VsZWN0ZWRJZCAhPT0gK2xhc3RQYXN0ZUlkKQogICAgICAg
ICAgICBsb2NhdGVBY3RpdmUgPSBmYWxzZTsKICAgICAgICB1cGRhdGVMb2NhdGVCdG4oKTsKICAg
ICAgICBzeW5jSXRlbUhpZ2hsaWdodCgpOwogICAgICAgIGNvbnN0IGVsID0gbGlzdEVsLnF1ZXJ5
U2VsZWN0b3IoJy5tZy1yb3dbZGF0YS1pZD0iJyArIHNlbGVjdGVkSWQgKyAnIl0nKQogICAgICAg
ICAgICB8fCBsaXN0RWwucXVlcnlTZWxlY3RvcignLml0bVtkYXRhLWlkPSInICsgc2VsZWN0ZWRJ
ZCArICciXScpOwogICAgICAgIGlmIChlbCkgZWwuc2Nyb2xsSW50b1ZpZXcoeyBibG9jazogJ25l
YXJlc3QnIH0pOwogICAgfQoKICAgIGZ1bmN0aW9uIHNlbGVjdGVkSW5kZXgoKSB7CiAgICAgICAg
cmV0dXJuIG5hdkxpc3QoKS5maW5kSW5kZXgoYyA9PiBjLmlkID09IHNlbGVjdGVkSWQpOwogICAg
fQoKICAgIGZ1bmN0aW9uIHN5bmNJdGVtSGlnaGxpZ2h0KCkgewogICAgICAgIGRvY3VtZW50LnF1
ZXJ5U2VsZWN0b3JBbGwoJy5pdG0nKS5mb3JFYWNoKG4gPT4gewogICAgICAgICAgICBpZiAobi5j
bGFzc0xpc3QuY29udGFpbnMoJ2l0LWdyb3VwJykpIHsKICAgICAgICAgICAgICAgIGNvbnN0IHJv
d3MgPSBbLi4ubi5xdWVyeVNlbGVjdG9yQWxsKCcubWctcm93JyldOwogICAgICAgICAgICAgICAg
Y29uc3QgaWRzID0gcm93cy5tYXAociA9PiArci5kYXRhc2V0LmlkKTsKICAgICAgICAgICAgICAg
IGNvbnN0IGFueVNlbCA9IGlkcy5pbmNsdWRlcygrc2VsZWN0ZWRJZCkgfHwgaWRzLnNvbWUoaWQg
PT4gbXVsdGlJZHMuaW5jbHVkZXMoaWQpKTsKICAgICAgICAgICAgICAgIG4uY2xhc3NMaXN0LnRv
Z2dsZSgnc2VsJywgYW55U2VsKTsKICAgICAgICAgICAgICAgIG4uY2xhc3NMaXN0LnRvZ2dsZSgn
bXVsdGknLCBpZHMuc29tZShpZCA9PiBtdWx0aUlkcy5pbmNsdWRlcyhpZCkpKTsKICAgICAgICAg
ICAgICAgIHJvd3MuZm9yRWFjaChyID0+IHsKICAgICAgICAgICAgICAgICAgICBjb25zdCBpZCA9
ICtyLmRhdGFzZXQuaWQ7CiAgICAgICAgICAgICAgICAgICAgY29uc3QgaW5NdWx0aSA9IG11bHRp
SWRzLmluY2x1ZGVzKGlkKTsKICAgICAgICAgICAgICAgICAgICByLmNsYXNzTGlzdC50b2dnbGUo
J3NlbCcsIGlkID09IHNlbGVjdGVkSWQgfHwgaW5NdWx0aSk7CiAgICAgICAgICAgICAgICAgICAg
ci5jbGFzc0xpc3QudG9nZ2xlKCdtdWx0aScsIGluTXVsdGkpOwogICAgICAgICAgICAgICAgfSk7
CiAgICAgICAgICAgICAgICByZXR1cm47CiAgICAgICAgICAgIH0KICAgICAgICAgICAgY29uc3Qg
aWQgPSArbi5kYXRhc2V0LmlkOwogICAgICAgICAgICBjb25zdCBpbk11bHRpID0gbXVsdGlJZHMu
aW5jbHVkZXMoaWQpOwogICAgICAgICAgICBuLmNsYXNzTGlzdC50b2dnbGUoJ3NlbCcsIGlkID09
IHNlbGVjdGVkSWQgfHwgaW5NdWx0aSk7CiAgICAgICAgICAgIG4uY2xhc3NMaXN0LnRvZ2dsZSgn
bXVsdGknLCBpbk11bHRpKTsKICAgICAgICB9KTsKICAgIH0KICAgIGZ1bmN0aW9uIHVwZGF0ZU11
bHRpQmFkZ2UoKSB7CiAgICAgICAgY29uc3QgYmFyID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQo
J211bHRpLWJhcicpOwogICAgICAgIGNvbnN0IGVsID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQo
J211bHRpLWNudCcpOwogICAgICAgIGlmIChtdWx0aUlkcy5sZW5ndGggPiAwKSB7CiAgICAgICAg
ICAgIGlmIChlbCkgZWwudGV4dENvbnRlbnQgPSBTdHJpbmcobXVsdGlJZHMubGVuZ3RoKTsKICAg
ICAgICAgICAgaWYgKGJhcikgewogICAgICAgICAgICAgICAgY29uc3Qgd2FzT2ZmID0gIWJhci5j
bGFzc0xpc3QuY29udGFpbnMoJ29uJyk7CiAgICAgICAgICAgICAgICBiYXIuY2xhc3NMaXN0LmFk
ZCgnb24nKTsKICAgICAgICAgICAgICAgIGlmICh3YXNPZmYpIHJlc2V0UGFzdGVTZXBEZWZhdWx0
KCk7CiAgICAgICAgICAgIH0KICAgICAgICB9IGVsc2UgewogICAgICAgICAgICBpZiAoYmFyKSBi
YXIuY2xhc3NMaXN0LnJlbW92ZSgnb24nKTsKICAgICAgICAgICAgY2xvc2VTZXBNZW51KCk7CiAg
ICAgICAgfQogICAgICAgIHN5bmNJdGVtSGlnaGxpZ2h0KCk7CiAgICB9CgogICAgY29uc3QgU0VQ
X05FV0xJTkVfVE9LRU4gPSAnW+aNouihjF0nOwogICAgLy8g5Zu65a6a5bi455So5YiG6ZqU56ym
77yb6Ieq5a6a5LmJ5LiN6L+b5YiX6KGoCiAgICBjb25zdCBTRVBfTElTVCA9IFsnICcsIFNFUF9O
RVdMSU5FX1RPS0VOLCAnLCcsICcsICcsICfjgIEnLCAnfCcsICdbIiIsIiJdJywgIignJywnJyki
XTsKICAgIGxldCBwYXN0ZVNlcFZhbHVlID0gJyAnOwoKICAgIGZ1bmN0aW9uIG5vcm1hbGl6ZVNl
cElucHV0KHJhdykgewogICAgICAgIGxldCBzID0gU3RyaW5nKHJhdyA/PyAnJyk7CiAgICAgICAg
aWYgKHMgPT09ICcnKSByZXR1cm4gJyAnOwogICAgICAgIGNvbnN0IHQgPSBzLnRyaW0oKTsKICAg
ICAgICBpZiAodCA9PT0gU0VQX05FV0xJTkVfVE9LRU4gfHwgdCA9PT0gJ+aNouihjCcgfHwgdCA9
PT0gJ1xcbicgfHwgdCA9PT0gJ1xuJyB8fCB0ID09PSAnXHJcbicpCiAgICAgICAgICAgIHJldHVy
biBTRVBfTkVXTElORV9UT0tFTjsKICAgICAgICBpZiAodCA9PT0gJ1xcdCcgfHwgdCA9PT0gJ1x0
JykgcmV0dXJuICdcdCc7CiAgICAgICAgcmV0dXJuIHM7CiAgICB9CiAgICBmdW5jdGlvbiBzZXBU
b0FjdHVhbChyYXcpIHsKICAgICAgICBjb25zdCBzID0gbm9ybWFsaXplU2VwSW5wdXQocmF3KTsK
ICAgICAgICByZXR1cm4gcyA9PT0gU0VQX05FV0xJTkVfVE9LRU4gPyAnXG4nIDogczsKICAgIH0K
ICAgIGZ1bmN0aW9uIHNlcFRvQnJpZGdlKHJhdykgewogICAgICAgIGNvbnN0IHMgPSBub3JtYWxp
emVTZXBJbnB1dChyYXcpOwogICAgICAgIGlmIChzID09PSBTRVBfTkVXTElORV9UT0tFTiB8fCBz
ID09PSAnXG4nIHx8IHMgPT09ICdcclxuJykgcmV0dXJuIFNFUF9ORVdMSU5FX1RPS0VOOwogICAg
ICAgIGlmIChzID09PSAnXHQnKSByZXR1cm4gJ1vliLbooajnrKZdJzsKICAgICAgICByZXR1cm4g
czsKICAgIH0KICAgIGZ1bmN0aW9uIHNlcERpc3BsYXlTeW1ib2wocmF3KSB7CiAgICAgICAgY29u
c3QgcyA9IG5vcm1hbGl6ZVNlcElucHV0KHJhdyk7CiAgICAgICAgaWYgKHMgPT09ICcgJykgcmV0
dXJuICfikKMnOwogICAgICAgIGlmIChzID09PSBTRVBfTkVXTElORV9UT0tFTiB8fCBzID09PSAn
XG4nIHx8IHMgPT09ICdcclxuJykgcmV0dXJuICfihrUnOwogICAgICAgIGlmIChzID09PSAnXHQn
KSByZXR1cm4gJ+KHpSc7CiAgICAgICAgaWYgKHMgPT09ICcsJykgcmV0dXJuICcsJzsKICAgICAg
ICBpZiAocyA9PT0gJywgJykgcmV0dXJuICcs4pCjJzsKICAgICAgICBpZiAocyA9PT0gJ+OAgScp
IHJldHVybiAn44CBJzsKICAgICAgICBpZiAocyA9PT0gJ3wnKSByZXR1cm4gJ3wnOwogICAgICAg
IGlmIChzID09PSAnWyIiLCIiXScpIHJldHVybiAnWyIiLCIiXSc7CiAgICAgICAgaWYgKHMgPT09
ICIoJycsJycpIikgcmV0dXJuICIoJycsJycpIjsKICAgICAgICByZXR1cm4gcy5yZXBsYWNlKC9c
clxuL2csICfihrUnKS5yZXBsYWNlKC9cbi9nLCAn4oa1JykucmVwbGFjZSgvXHQvZywgJ+KHpScp
LnJlcGxhY2UoL1xyL2csICcnKTsKICAgIH0KICAgIGZ1bmN0aW9uIHNlcERpc3BsYXlOYW1lKHJh
dykgewogICAgICAgIGNvbnN0IHMgPSBub3JtYWxpemVTZXBJbnB1dChyYXcpOwogICAgICAgIGlm
IChzID09PSAnICcpIHJldHVybiAn56m65qC8JzsKICAgICAgICBpZiAocyA9PT0gU0VQX05FV0xJ
TkVfVE9LRU4gfHwgcyA9PT0gJ1xuJyB8fCBzID09PSAnXHJcbicpIHJldHVybiAn5o2i6KGMJzsK
ICAgICAgICBpZiAocyA9PT0gJ1x0JykgcmV0dXJuICfliLbooajnrKYnOwogICAgICAgIGlmIChz
ID09PSAnLCcpIHJldHVybiAn6YCX5Y+3JzsKICAgICAgICBpZiAocyA9PT0gJywgJykgcmV0dXJu
ICfpgJflj7fnqbrmoLwnOwogICAgICAgIGlmIChzID09PSAn44CBJykgcmV0dXJuICfpob/lj7cn
OwogICAgICAgIGlmIChzID09PSAnfCcpIHJldHVybiAn56uW57q/JzsKICAgICAgICBpZiAocyA9
PT0gJ1siIiwiIl0nKSByZXR1cm4gJ+WIl+ihqDEnOwogICAgICAgIGlmIChzID09PSAiKCcnLCcn
KSIpIHJldHVybiAn5YiX6KGoMic7CiAgICAgICAgcmV0dXJuICcnOwogICAgfQogICAgZnVuY3Rp
b24gZmlsbFNlcE1lbnVJdGVtKGJ0biwgdikgewogICAgICAgIGJ0bi5pbm5lckhUTUwgPSAnJzsK
ICAgICAgICBjb25zdCBzeW0gPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdzcGFuJyk7CiAgICAg
ICAgc3ltLmNsYXNzTmFtZSA9ICdwYXN0ZS1zZXAtc3ltJyArIChzZXBEaXNwbGF5TmFtZSh2KSA/
ICcnIDogJyBvbmx5Jyk7CiAgICAgICAgc3ltLnRleHRDb250ZW50ID0gc2VwRGlzcGxheVN5bWJv
bCh2KTsKICAgICAgICBidG4uYXBwZW5kQ2hpbGQoc3ltKTsKICAgICAgICBjb25zdCBuYW1lID0g
c2VwRGlzcGxheU5hbWUodik7CiAgICAgICAgaWYgKG5hbWUpIHsKICAgICAgICAgICAgY29uc3Qg
bGFiID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnc3BhbicpOwogICAgICAgICAgICBsYWIuY2xh
c3NOYW1lID0gJ3Bhc3RlLXNlcC1uYW1lJzsKICAgICAgICAgICAgbGFiLnRleHRDb250ZW50ID0g
bmFtZTsKICAgICAgICAgICAgYnRuLmFwcGVuZENoaWxkKGxhYik7CiAgICAgICAgfQogICAgfQog
ICAgZnVuY3Rpb24gdXBkYXRlU2VwTGFiZWwoKSB7CiAgICAgICAgY29uc3QgbGFiID0gZG9jdW1l
bnQuZ2V0RWxlbWVudEJ5SWQoJ3Bhc3RlLXNlcC1sYWJlbCcpOwogICAgICAgIGlmIChsYWIpIGxh
Yi50ZXh0Q29udGVudCA9IHNlcERpc3BsYXlTeW1ib2wocGFzdGVTZXBWYWx1ZSk7CiAgICB9CiAg
ICBmdW5jdGlvbiBhcHBseVNlcGFyYXRvcihyYXcsIG9wdHMgPSB7fSkgewogICAgICAgIGNvbnN0
IGRvUGFzdGUgPSBvcHRzLnBhc3RlICE9IG51bGwgPyBvcHRzLnBhc3RlIDogbXVsdGlJZHMubGVu
Z3RoID4gMDsKICAgICAgICBwYXN0ZVNlcFZhbHVlID0gbm9ybWFsaXplU2VwSW5wdXQocmF3KTsK
ICAgICAgICB1cGRhdGVTZXBMYWJlbCgpOwogICAgICAgIGNsb3NlU2VwTWVudSgpOwogICAgICAg
IGlmIChkb1Bhc3RlKSBwYXN0ZU11bHRpU2VsZWN0aW9uKCk7CiAgICB9CiAgICBmdW5jdGlvbiBj
bG9zZVNlcE1lbnUoKSB7CiAgICAgICAgY29uc3QgbWVudSA9IGRvY3VtZW50LmdldEVsZW1lbnRC
eUlkKCdwYXN0ZS1zZXAtbWVudScpOwogICAgICAgIGNvbnN0IGJ0biA9IGRvY3VtZW50LmdldEVs
ZW1lbnRCeUlkKCdwYXN0ZS1zZXAtYnRuJyk7CiAgICAgICAgaWYgKG1lbnUpIG1lbnUuY2xhc3NM
aXN0LnJlbW92ZSgnb24nKTsKICAgICAgICBpZiAoYnRuKSBidG4uY2xhc3NMaXN0LnJlbW92ZSgn
b3BlbicpOwogICAgfQogICAgZnVuY3Rpb24gcmVuZGVyU2VwTWVudSgpIHsKICAgICAgICBjb25z
dCBtZW51ID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3Bhc3RlLXNlcC1tZW51Jyk7CiAgICAg
ICAgaWYgKCFtZW51KSByZXR1cm47CiAgICAgICAgbWVudS5pbm5lckhUTUwgPSAnJzsKICAgICAg
ICBmb3IgKGNvbnN0IHYgb2YgU0VQX0xJU1QpIHsKICAgICAgICAgICAgY29uc3QgYiA9IGRvY3Vt
ZW50LmNyZWF0ZUVsZW1lbnQoJ2J1dHRvbicpOwogICAgICAgICAgICBiLnR5cGUgPSAnYnV0dG9u
JzsKICAgICAgICAgICAgYi5jbGFzc05hbWUgPSAncGFzdGUtc2VwLWl0ZW0nICsgKHYgPT09IHBh
c3RlU2VwVmFsdWUgPyAnIHNlbCcgOiAnJyk7CiAgICAgICAgICAgIGZpbGxTZXBNZW51SXRlbShi
LCB2KTsKICAgICAgICAgICAgYi5vbmNsaWNrID0gZSA9PiB7CiAgICAgICAgICAgICAgICBlLnN0
b3BQcm9wYWdhdGlvbigpOwogICAgICAgICAgICAgICAgYXBwbHlTZXBhcmF0b3Iodik7CiAgICAg
ICAgICAgIH07CiAgICAgICAgICAgIG1lbnUuYXBwZW5kQ2hpbGQoYik7CiAgICAgICAgfQogICAg
ICAgIGNvbnN0IGZvb3QgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsKICAgICAgICBm
b290LmNsYXNzTmFtZSA9ICdwYXN0ZS1zZXAtZm9vdCc7CiAgICAgICAgY29uc3QgaW5wID0gZG9j
dW1lbnQuY3JlYXRlRWxlbWVudCgnaW5wdXQnKTsKICAgICAgICBpbnAuaWQgPSAncGFzdGUtc2Vw
LWN1c3RvbSc7CiAgICAgICAgaW5wLnR5cGUgPSAndGV4dCc7CiAgICAgICAgaW5wLnNpemUgPSAx
OwogICAgICAgIGlucC5wbGFjZWhvbGRlciA9ICfoh6rlrprkuYknOwogICAgICAgIGlucC5hdXRv
Y29tcGxldGUgPSAnb2ZmJzsKICAgICAgICBpbnAuc3BlbGxjaGVjayA9IGZhbHNlOwogICAgICAg
IGlucC52YWx1ZSA9IFNFUF9MSVNULmluY2x1ZGVzKHBhc3RlU2VwVmFsdWUpID8gJycgOiBwYXN0
ZVNlcFZhbHVlOwogICAgICAgIGlucC5vbm1vdXNlZG93biA9IGUgPT4gewogICAgICAgICAgICBl
LnN0b3BQcm9wYWdhdGlvbigpOwogICAgICAgICAgICBlLnByZXZlbnREZWZhdWx0KCk7CiAgICAg
ICAgICAgIHRyeSB7IGFoaygnZm9jdXNQYW5lbCcpOyB9IGNhdGNoIHt9CiAgICAgICAgICAgIGlu
cC5mb2N1cygpOwogICAgICAgIH07CiAgICAgICAgaW5wLm9uY2xpY2sgPSBlID0+IGUuc3RvcFBy
b3BhZ2F0aW9uKCk7CiAgICAgICAgaW5wLm9uZm9jdXMgPSAoKSA9PiB7IHRyeSB7IGFoaygnZm9j
dXNQYW5lbCcpOyB9IGNhdGNoIHt9IH07CiAgICAgICAgaW5wLm9uaW5wdXQgPSBlID0+IGUuc3Rv
cFByb3BhZ2F0aW9uKCk7CiAgICAgICAgaW5wLm9ua2V5ZG93biA9IGUgPT4gewogICAgICAgICAg
ICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgICAgICAgICBpZiAoZS5rZXkgPT09ICdFbnRlcicp
IHsKICAgICAgICAgICAgICAgIGUucHJldmVudERlZmF1bHQoKTsKICAgICAgICAgICAgICAgIGlm
IChpbnAudmFsdWUgIT09ICcnKSBhcHBseVNlcGFyYXRvcihpbnAudmFsdWUpOwogICAgICAgICAg
ICAgICAgZWxzZSBjbG9zZVNlcE1lbnUoKTsKICAgICAgICAgICAgfSBlbHNlIGlmIChlLmtleSA9
PT0gJ0VzY2FwZScpIHsKICAgICAgICAgICAgICAgIGUucHJldmVudERlZmF1bHQoKTsKICAgICAg
ICAgICAgICAgIGNsb3NlU2VwTWVudSgpOwogICAgICAgICAgICB9CiAgICAgICAgfTsKICAgICAg
ICBmb290LmFwcGVuZENoaWxkKGlucCk7CiAgICAgICAgbWVudS5hcHBlbmRDaGlsZChmb290KTsK
ICAgIH0KICAgIGZ1bmN0aW9uIHJlc2V0UGFzdGVTZXBEZWZhdWx0KCkgewogICAgICAgIHBhc3Rl
U2VwVmFsdWUgPSAnICc7CiAgICAgICAgdXBkYXRlU2VwTGFiZWwoKTsKICAgICAgICBjbG9zZVNl
cE1lbnUoKTsKICAgIH0KICAgIGZ1bmN0aW9uIHBhc3RlTWFueVdpdGhTZXAoaWRzKSB7CiAgICAg
ICAgYWhrKCdwYXN0ZU1hbnknLCBpZHMuam9pbignLCcpLCBzZXBUb0JyaWRnZShwYXN0ZVNlcFZh
bHVlKSk7CiAgICB9CiAgICBmdW5jdGlvbiBwYXN0ZU11bHRpU2VsZWN0aW9uKCkgewogICAgICAg
IGlmICghbXVsdGlJZHMubGVuZ3RoKSByZXR1cm47CiAgICAgICAgY29uc3QgaWRzID0gbXVsdGlJ
ZHMuc2xpY2UoKTsKICAgICAgICBjbGVhck11bHRpKCk7CiAgICAgICAgaWYgKGlkcy5zb21lKGlk
ID0+IHsKICAgICAgICAgICAgY29uc3QgaXQgPSBhbGxDbGlwcy5maW5kKHggPT4gK3guaWQgPT09
ICtpZCk7CiAgICAgICAgICAgIHJldHVybiBpdCAmJiBub3JtVHlwZShpdC50eXBlKSA9PT0gJ3Jl
Y2VudCc7CiAgICAgICAgfSkpIHsKICAgICAgICAgICAgY29uc3QgZmlyc3QgPSBhbGxDbGlwcy5m
aW5kKHggPT4gK3guaWQgPT09ICtpZHNbMF0pOwogICAgICAgICAgICBpZiAoZmlyc3QpIGFjdGl2
YXRlQ2xpcEl0ZW0oZmlyc3QpOwogICAgICAgICAgICByZXR1cm47CiAgICAgICAgfQogICAgICAg
IG1hcmtQYXN0ZWRMb2NhbChpZHMpOwogICAgICAgIHBhc3RlTWFueVdpdGhTZXAoaWRzKTsKICAg
IH0KICAgIGZ1bmN0aW9uIGluaXRTZXBVaSgpIHsKICAgICAgICB1cGRhdGVTZXBMYWJlbCgpOwog
ICAgICAgIGNvbnN0IGJ0biA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdwYXN0ZS1zZXAtYnRu
Jyk7CiAgICAgICAgaWYgKGJ0bikgewogICAgICAgICAgICBidG4uYWRkRXZlbnRMaXN0ZW5lcign
Y2xpY2snLCBlID0+IHsKICAgICAgICAgICAgICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAg
ICAgICAgICAgICBjb25zdCBtZW51ID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3Bhc3RlLXNl
cC1tZW51Jyk7CiAgICAgICAgICAgICAgICBjb25zdCBvcGVuID0gbWVudSAmJiBtZW51LmNsYXNz
TGlzdC5jb250YWlucygnb24nKTsKICAgICAgICAgICAgICAgIGlmIChvcGVuKSB7CiAgICAgICAg
ICAgICAgICAgICAgY29uc3QgaW5wID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3Bhc3RlLXNl
cC1jdXN0b20nKTsKICAgICAgICAgICAgICAgICAgICBpZiAoaW5wICYmIGlucC52YWx1ZSAhPT0g
JycpIGFwcGx5U2VwYXJhdG9yKGlucC52YWx1ZSwgeyBwYXN0ZTogbXVsdGlJZHMubGVuZ3RoID4g
MCB9KTsKICAgICAgICAgICAgICAgICAgICBlbHNlIGNsb3NlU2VwTWVudSgpOwogICAgICAgICAg
ICAgICAgICAgIHJldHVybjsKICAgICAgICAgICAgICAgIH0KICAgICAgICAgICAgICAgIHJlbmRl
clNlcE1lbnUoKTsKICAgICAgICAgICAgICAgIG1lbnUuY2xhc3NMaXN0LmFkZCgnb24nKTsKICAg
ICAgICAgICAgICAgIGJ0bi5jbGFzc0xpc3QuYWRkKCdvcGVuJyk7CiAgICAgICAgICAgIH0pOwog
ICAgICAgIH0KICAgICAgICBkb2N1bWVudC5hZGRFdmVudExpc3RlbmVyKCdtb3VzZWRvd24nLCBl
ID0+IHsKICAgICAgICAgICAgaWYgKGUudGFyZ2V0LmNsb3Nlc3QoJyNwYXN0ZS1zZXAtd3JhcCcp
KSByZXR1cm47CiAgICAgICAgICAgIGNvbnN0IG1lbnUgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJ
ZCgncGFzdGUtc2VwLW1lbnUnKTsKICAgICAgICAgICAgaWYgKCFtZW51IHx8ICFtZW51LmNsYXNz
TGlzdC5jb250YWlucygnb24nKSkgcmV0dXJuOwogICAgICAgICAgICBjb25zdCBpbnAgPSBkb2N1
bWVudC5nZXRFbGVtZW50QnlJZCgncGFzdGUtc2VwLWN1c3RvbScpOwogICAgICAgICAgICBpZiAo
aW5wICYmIGlucC52YWx1ZSAhPT0gJycpIHsKICAgICAgICAgICAgICAgIGFwcGx5U2VwYXJhdG9y
KGlucC52YWx1ZSk7CiAgICAgICAgICAgICAgICByZXR1cm47CiAgICAgICAgICAgIH0KICAgICAg
ICAgICAgY2xvc2VTZXBNZW51KCk7CiAgICAgICAgfSwgdHJ1ZSk7CiAgICB9CgogICAgZnVuY3Rp
b24gY2xlYXJNdWx0aShyZXN0b3JlVG9BbmNob3IpIHsKICAgICAgICBjb25zdCBiYWNrSWQgPSAr
cmFuZ2VBbmNob3JJZCB8fCAwOwogICAgICAgIG11bHRpSWRzID0gW107CiAgICAgICAgaWYgKHJl
c3RvcmVUb0FuY2hvciAmJiBiYWNrSWQpCiAgICAgICAgICAgIHNlbGVjdGVkSWQgPSBiYWNrSWQ7
CiAgICAgICAgcmFuZ2VBbmNob3JJZCA9IHNlbGVjdGVkSWQgfHwgMDsKICAgICAgICByYW5nZUFu
Y2hvckNsaWNrZWQgPSBmYWxzZTsKICAgICAgICB1cGRhdGVNdWx0aUJhZGdlKCk7CiAgICAgICAg
aWYgKHJlc3RvcmVUb0FuY2hvciAmJiBzZWxlY3RlZElkKSB7CiAgICAgICAgICAgIGNvbnN0IGVs
ID0gbGlzdEVsLnF1ZXJ5U2VsZWN0b3IoJy5tZy1yb3dbZGF0YS1pZD0iJyArIHNlbGVjdGVkSWQg
KyAnIl0nKQogICAgICAgICAgICAgICAgfHwgbGlzdEVsLnF1ZXJ5U2VsZWN0b3IoJy5pdG1bZGF0
YS1pZD0iJyArIHNlbGVjdGVkSWQgKyAnIl0nKTsKICAgICAgICAgICAgaWYgKGVsKSBlbC5zY3Jv
bGxJbnRvVmlldyh7IGJsb2NrOiAnbmVhcmVzdCcgfSk7CiAgICAgICAgfQogICAgfQoKCiAgICAv
KiBzaGlmdC9jdHJsIG11bHRpLXNlbGVjdDoKICAgICAqIFNoaWZ077ya5pyJ6YCJ5Yy65pe25Lul
44CM5pyA5LiKL+acgOS4i+OAjeS4uumUmu+8jOS4jei3n+m8oOagh+S4iuasoeeCueWHu+i1sAog
ICAgICogICAtIOeCueWcqOmAieWMuuS4i+aWuSDihpIg5LuO5LiK6YCJ5Yiw5b2T5YmNCiAgICAg
KiAgIC0g54K55Zyo6YCJ5Yy65LiK5pa5IOKGkiDku47lvZPliY3liLDkuIvpgIkKICAgICAqICAg
LSDngrnlnKjpgInljLrot6jluqblhoUg4oaSIOWhq+a7oeacgOS4iuWIsOacgOS4i++8iOWQq+md
nui/nue7reepuua0nu+8iQogICAgICogQ3RybO+8mummluasoeeCueS7u+aEj+mhue+8iOWQq+m7
mOiupOmrmOS6ru+8iei/m+WFpeWkmumAieW5tumAieS4re+8m+WGjeeCueW3sumAiemhueWPlua2
iOOAgeacqumAiemhueWKoOWFpQogICAgICovCiAgICBsZXQgcmFuZ2VBbmNob3JJZCA9IDA7CiAg
ICBsZXQgcmFuZ2VBbmNob3JDbGlja2VkID0gZmFsc2U7CiAgICBmdW5jdGlvbiBzZWxlY3RlZElu
ZGljZXNJbkxpc3QobGlzdCkgewogICAgICAgIGNvbnN0IHNldCA9IG5ldyBTZXQoKG11bHRpSWRz
IHx8IFtdKS5tYXAoTnVtYmVyKS5maWx0ZXIoQm9vbGVhbikpOwogICAgICAgIGlmICgrc2VsZWN0
ZWRJZCkgc2V0LmFkZCgrc2VsZWN0ZWRJZCk7CiAgICAgICAgY29uc3QgaWR4cyA9IFtdOwogICAg
ICAgIGxpc3QuZm9yRWFjaCgoYywgaSkgPT4gewogICAgICAgICAgICBpZiAoc2V0LmhhcygrYy5p
ZCkpIGlkeHMucHVzaChpKTsKICAgICAgICB9KTsKICAgICAgICByZXR1cm4gaWR4czsKICAgIH0K
ICAgIGZ1bmN0aW9uIHNlbGVjdFJhbmdlVG8oaWQpIHsKICAgICAgICBpZCA9ICtpZDsKICAgICAg
ICBjb25zdCBsaXN0ID0gKHR5cGVvZiBuYXZMaXN0ID09PSAnZnVuY3Rpb24nID8gbmF2TGlzdCgp
IDogdmlzaWJsZUxpc3QoKSk7CiAgICAgICAgY29uc3QgYiA9IGxpc3QuZmluZEluZGV4KGMgPT4g
K2MuaWQgPT09IGlkKTsKICAgICAgICBpZiAoYiA8IDApIHJldHVybjsKICAgICAgICBjb25zdCBp
ZHhzID0gc2VsZWN0ZWRJbmRpY2VzSW5MaXN0KGxpc3QpOwogICAgICAgIGxldCBsbywgaGk7CiAg
ICAgICAgaWYgKCFpZHhzLmxlbmd0aCkgewogICAgICAgICAgICBsbyA9IGhpID0gYjsKICAgICAg
ICB9IGVsc2UgewogICAgICAgICAgICBjb25zdCB0b3AgPSBNYXRoLm1pbiguLi5pZHhzKTsKICAg
ICAgICAgICAgY29uc3QgYm90ID0gTWF0aC5tYXgoLi4uaWR4cyk7CiAgICAgICAgICAgIGlmIChi
ID4gYm90KSB7CiAgICAgICAgICAgICAgICAvLyDpgInljLrkuIvmlrnvvJrmnIDkuIog4oaSIOW9
k+WJjQogICAgICAgICAgICAgICAgbG8gPSB0b3A7CiAgICAgICAgICAgICAgICBoaSA9IGI7CiAg
ICAgICAgICAgIH0gZWxzZSBpZiAoYiA8IHRvcCkgewogICAgICAgICAgICAgICAgLy8g6YCJ5Yy6
5LiK5pa577ya5b2T5YmNIOKGkiDmnIDkuIsKICAgICAgICAgICAgICAgIGxvID0gYjsKICAgICAg
ICAgICAgICAgIGhpID0gYm90OwogICAgICAgICAgICB9IGVsc2UgewogICAgICAgICAgICAgICAg
Ly8g5Zyo6Leo5bqm5YaF77yI5ZCr6Z2e6L+e57ut56m65rSe77yJ77ya5pW05q615pyA5LiK4oaS
5pyA5LiLCiAgICAgICAgICAgICAgICBsbyA9IHRvcDsKICAgICAgICAgICAgICAgIGhpID0gYm90
OwogICAgICAgICAgICB9CiAgICAgICAgfQogICAgICAgIG11bHRpSWRzID0gW107CiAgICAgICAg
Zm9yIChsZXQgaSA9IGxvOyBpIDw9IGhpOyBpKyspCiAgICAgICAgICAgIG11bHRpSWRzLnB1c2go
K2xpc3RbaV0uaWQpOwogICAgICAgIHNlbGVjdGVkSWQgPSBpZDsKICAgICAgICAvLyDkuI3lho3m
iorpvKDmoIfngrnlh7vlvZPmiJDkuIvkuIDmrKEgU2hpZnQg6ZSa54K5CiAgICAgICAgcmFuZ2VB
bmNob3JJZCA9ICtsaXN0W2xvXS5pZDsKICAgICAgICByYW5nZUFuY2hvckNsaWNrZWQgPSB0cnVl
OwogICAgICAgIHVwZGF0ZU11bHRpQmFkZ2UoKTsKICAgICAgICBjb25zdCBlbCA9IGxpc3RFbC5x
dWVyeVNlbGVjdG9yKCcubWctcm93W2RhdGEtaWQ9IicgKyBzZWxlY3RlZElkICsgJyJdJykKICAg
ICAgICAgICAgfHwgbGlzdEVsLnF1ZXJ5U2VsZWN0b3IoJy5pdG1bZGF0YS1pZD0iJyArIHNlbGVj
dGVkSWQgKyAnIl0nKTsKICAgICAgICBpZiAoZWwpIGVsLnNjcm9sbEludG9WaWV3KHsgYmxvY2s6
ICduZWFyZXN0JyB9KTsKICAgIH0KICAgIGZ1bmN0aW9uIGhhbmRsZUl0ZW1DbGljayhlLCBjKSB7
CiAgICAgICAgaWYgKGUuc2hpZnRLZXkpIHsKICAgICAgICAgICAgZS5wcmV2ZW50RGVmYXVsdCgp
OyBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgICAgICAgICBzZWxlY3RSYW5nZVRvKGMuaWQpOwog
ICAgICAgICAgICByZXR1cm4gdHJ1ZTsKICAgICAgICB9CiAgICAgICAgaWYgKGUuY3RybEtleSB8
fCBlLm1ldGFLZXkpIHsKICAgICAgICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOyBlLnN0b3BQcm9w
YWdhdGlvbigpOwogICAgICAgICAgICB0b2dnbGVNdWx0aShjLmlkKTsKICAgICAgICAgICAgcmV0
dXJuIHRydWU7CiAgICAgICAgfQogICAgICAgIHJhbmdlQW5jaG9ySWQgPSBjLmlkOwogICAgICAg
IHJhbmdlQW5jaG9yQ2xpY2tlZCA9IHRydWU7CiAgICAgICAgcmV0dXJuIGZhbHNlOwogICAgfQog
ICAgZnVuY3Rpb24gdG9nZ2xlTXVsdGkoaWQpIHsKICAgICAgICBpZCA9ICtpZDsKICAgICAgICAv
LyDpppbmrKEgQ3RybO+8muWPqumAieS4reW9k+WJjeeCueWHu+mhue+8iOWQq+m7mOiupOmrmOS6
rumhuSDihpIg6L+b5YWl5aSa6YCJ77yM5LiN6KaB5Y+W5raI77yJCiAgICAgICAgaWYgKCFtdWx0
aUlkcy5sZW5ndGgpIHsKICAgICAgICAgICAgbXVsdGlJZHMgPSBbaWRdOwogICAgICAgICAgICBz
ZWxlY3RlZElkID0gaWQ7CiAgICAgICAgICAgIHVwZGF0ZU11bHRpQmFkZ2UoKTsKICAgICAgICAg
ICAgcmV0dXJuOwogICAgICAgIH0KICAgICAgICBjb25zdCBpID0gbXVsdGlJZHMuaW5kZXhPZihp
ZCk7CiAgICAgICAgaWYgKGkgPj0gMCkgewogICAgICAgICAgICBtdWx0aUlkcy5zcGxpY2UoaSwg
MSk7CiAgICAgICAgICAgIGlmICgrc2VsZWN0ZWRJZCA9PT0gaWQpCiAgICAgICAgICAgICAgICBz
ZWxlY3RlZElkID0gbXVsdGlJZHMubGVuZ3RoID8gbXVsdGlJZHNbbXVsdGlJZHMubGVuZ3RoIC0g
MV0gOiAwOwogICAgICAgIH0gZWxzZSB7CiAgICAgICAgICAgIG11bHRpSWRzLnB1c2goaWQpOwog
ICAgICAgICAgICBzZWxlY3RlZElkID0gaWQ7CiAgICAgICAgfQogICAgICAgIHVwZGF0ZU11bHRp
QmFkZ2UoKTsKICAgIH0KICAgIGZ1bmN0aW9uIHNob3dTcmNUaXAoYW5jaG9yLCB0ZXh0KSB7CiAg
ICAgICAgdGV4dCA9IFN0cmluZyh0ZXh0IHx8ICcnKS50cmltKCk7CiAgICAgICAgaWYgKCF0ZXh0
KSByZXR1cm47CiAgICAgICAgbGV0IHRpcCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzcmMt
dGlwJyk7CiAgICAgICAgaWYgKCF0aXApIHsKICAgICAgICAgICAgdGlwID0gZG9jdW1lbnQuY3Jl
YXRlRWxlbWVudCgnZGl2Jyk7CiAgICAgICAgICAgIHRpcC5pZCA9ICdzcmMtdGlwJzsKICAgICAg
ICAgICAgZG9jdW1lbnQuYm9keS5hcHBlbmRDaGlsZCh0aXApOwogICAgICAgIH0KICAgICAgICB0
aXAudGV4dENvbnRlbnQgPSB0ZXh0OwogICAgICAgIHRpcC5jbGFzc0xpc3QuYWRkKCdzaG93Jyk7
CiAgICAgICAgY29uc3QgciA9IGFuY2hvci5nZXRCb3VuZGluZ0NsaWVudFJlY3QoKTsKICAgICAg
ICBjb25zdCB0dyA9IHRpcC5vZmZzZXRXaWR0aCB8fCAxNjA7CiAgICAgICAgY29uc3QgdGggPSB0
aXAub2Zmc2V0SGVpZ2h0IHx8IDI4OwogICAgICAgIGxldCBsZWZ0ID0gci5yaWdodCAtIHR3Owog
ICAgICAgIGxldCB0b3AgPSByLnRvcCAtIHRoIC0gODsKICAgICAgICBpZiAobGVmdCA8IDgpIGxl
ZnQgPSA4OwogICAgICAgIGlmIChsZWZ0ICsgdHcgPiB3aW5kb3cuaW5uZXJXaWR0aCAtIDgpIGxl
ZnQgPSB3aW5kb3cuaW5uZXJXaWR0aCAtIHR3IC0gODsKICAgICAgICBpZiAodG9wIDwgOCkgdG9w
ID0gci5ib3R0b20gKyA4OwogICAgICAgIHRpcC5zdHlsZS5sZWZ0ID0gbGVmdCArICdweCc7CiAg
ICAgICAgdGlwLnN0eWxlLnRvcCA9IHRvcCArICdweCc7CiAgICAgICAgY2xlYXJUaW1lb3V0KHRp
cC5faGlkZVQpOwogICAgICAgIHRpcC5faGlkZVQgPSBzZXRUaW1lb3V0KCgpID0+IHRpcC5jbGFz
c0xpc3QucmVtb3ZlKCdzaG93JyksIDIyMDApOwogICAgfQogICAgLyogaW1nLWhvdmVyLXByZXZp
ZXctdjggKi8KICAgIGxldCBfX2ltZ0hvdmVyVGltZXIgPSAwLCBfX2ltZ0hvdmVySGlkZVRpbWVy
ID0gMCwgX19pbWdIb3ZlcktleSA9ICcnOwogICAgZnVuY3Rpb24gX19pbWdIb3ZlckVuc3VyZSgp
IHsKICAgICAgICBsZXQgYm94ID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2ltZy1ob3Zlci1z
aWRlJyk7CiAgICAgICAgaWYgKCFib3gpIHsKICAgICAgICAgICAgYm94ID0gZG9jdW1lbnQuY3Jl
YXRlRWxlbWVudCgnZGl2Jyk7IGJveC5pZCA9ICdpbWctaG92ZXItc2lkZSc7CiAgICAgICAgICAg
IGNvbnN0IGZyYW1lID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnZGl2Jyk7IGZyYW1lLmNsYXNz
TmFtZSA9ICdpaHAtZnJhbWUnOwogICAgICAgICAgICBjb25zdCBpbSA9IGRvY3VtZW50LmNyZWF0
ZUVsZW1lbnQoJ2ltZycpOyBpbS5hbHQgPSAnJzsKICAgICAgICAgICAgZnJhbWUuYXBwZW5kQ2hp
bGQoaW0pOyBib3guYXBwZW5kQ2hpbGQoZnJhbWUpOyBkb2N1bWVudC5ib2R5LmFwcGVuZENoaWxk
KGJveCk7CiAgICAgICAgfQogICAgICAgIGxldCBzdCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlk
KCdpbWctaG92ZXItc2lkZS1jc3MnKTsKICAgICAgICBpZiAoIXN0KSB7IHN0ID0gZG9jdW1lbnQu
Y3JlYXRlRWxlbWVudCgnc3R5bGUnKTsgc3QuaWQgPSAnaW1nLWhvdmVyLXNpZGUtY3NzJzsgZG9j
dW1lbnQuaGVhZC5hcHBlbmRDaGlsZChzdCk7IH0KICAgICAgICBzdC50ZXh0Q29udGVudCA9ICIj
aW1nLWhvdmVyLXNpZGV7cG9zaXRpb246Zml4ZWQ7ei1pbmRleDoxMDAwMDA7cmlnaHQ6NnB4O3Rv
cDo1MCU7dHJhbnNmb3JtOnRyYW5zbGF0ZVkoLTUwJSk7cG9pbnRlci1ldmVudHM6bm9uZTtvcGFj
aXR5OjA7dmlzaWJpbGl0eTpoaWRkZW47bWF4LXdpZHRoOm1pbig2MjBweCw5MnZ3KTttYXgtaGVp
Z2h0Om1pbig5MnZoLDkyMHB4KX0jaW1nLWhvdmVyLXNpZGUuc2hvd3tvcGFjaXR5OjE7dmlzaWJp
bGl0eTp2aXNpYmxlfSNpbWctaG92ZXItc2lkZSAuaWhwLWZyYW1le3BhZGRpbmc6M3B4O2JhY2tn
cm91bmQ6I2ZmZjtib3JkZXI6MXB4IHNvbGlkICNDNUNEREM7Ym9yZGVyLXJhZGl1czoycHg7Ym94
LXNoYWRvdzowIDZweCAxOHB4IHJnYmEoNDQsNDYsNTQsLjEyKX0jaW1nLWhvdmVyLXNpZGUgaW1n
e2Rpc3BsYXk6YmxvY2s7bWF4LXdpZHRoOm1pbig2MTJweCw5MHZ3KTttYXgtaGVpZ2h0Om1pbig5
MHZoLDkwMHB4KTt3aWR0aDphdXRvO2hlaWdodDphdXRvO29iamVjdC1maXQ6Y29udGFpbjtiYWNr
Z3JvdW5kOiNmZmZ9IjsKICAgICAgICByZXR1cm4gYm94OwogICAgfQogICAgd2luZG93Ll9faW1n
SG92ZXJTaG93ID0gZnVuY3Rpb24oZmlsZSwgaWQpIHsKICAgICAgICBjb25zdCBiYXJlID0gU3Ry
aW5nKGZpbGUgfHwgJycpLnNwbGl0KC9bXFxcXC9dLykucG9wKCk7IGlmICghYmFyZSkgcmV0dXJu
OwogICAgICAgIGNvbnN0IGJveCA9IF9faW1nSG92ZXJFbnN1cmUoKTsgY29uc3QgaW1nID0gYm94
LnF1ZXJ5U2VsZWN0b3IoJ2ltZycpOyBpZiAoIWltZykgcmV0dXJuOwogICAgICAgIGJveC5jbGFz
c0xpc3QuYWRkKCdzaG93Jyk7CiAgICAgICAgaW1nLm9uZXJyb3IgPSAoKSA9PiB7CiAgICAgICAg
ICAgIGltZy5vbmVycm9yID0gKCkgPT4geyBpbWcub25lcnJvciA9IG51bGw7IHRyeSB7IGNvbnN0
IGMgPSB0aHVtYkNhY2hlICYmIHRodW1iQ2FjaGUuZ2V0KFN0cmluZyhpZCkpOyBpZiAoYykgaW1n
LnNyYyA9IGM7IH0gY2F0Y2ggKGUpIHt9IH07CiAgICAgICAgICAgIGltZy5zcmMgPSBTVE9SRV9C
QVNFICsgJ3RoXycgKyBiYXJlLnJlcGxhY2UoL1wuW14uXSskLywgJycpICsgJy5qcGcnOwogICAg
ICAgIH07CiAgICAgICAgaW1nLm9ubG9hZCA9ICgpID0+IHsgaW1nLm9uZXJyb3IgPSBudWxsOyB9
OwogICAgICAgIGltZy5kYXRhc2V0LmJhcmUgPSBiYXJlOyBpbWcuc3JjID0gU1RPUkVfQkFTRSAr
IGJhcmU7CiAgICB9OwogICAgd2luZG93Ll9faW1nSG92ZXJDbGVhclVpID0gZnVuY3Rpb24oKSB7
CiAgICAgICAgX19pbWdIb3ZlcktleSA9ICcnOwogICAgICAgIGlmIChfX2ltZ0hvdmVyVGltZXIp
IHsgY2xlYXJUaW1lb3V0KF9faW1nSG92ZXJUaW1lcik7IF9faW1nSG92ZXJUaW1lciA9IDA7IH0K
ICAgICAgICBpZiAoX19pbWdIb3ZlckhpZGVUaW1lcikgeyBjbGVhclRpbWVvdXQoX19pbWdIb3Zl
ckhpZGVUaW1lcik7IF9faW1nSG92ZXJIaWRlVGltZXIgPSAwOyB9CiAgICAgICAgY29uc3QgYm94
ID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2ltZy1ob3Zlci1zaWRlJyk7IGlmIChib3gpIGJv
eC5jbGFzc0xpc3QucmVtb3ZlKCdzaG93Jyk7CiAgICAgICAgY29uc3QgaW1nID0gYm94ICYmIGJv
eC5xdWVyeVNlbGVjdG9yKCdpbWcnKTsKICAgICAgICBpZiAoaW1nKSB7IGltZy5vbmxvYWQgPSBu
dWxsOyBpbWcub25lcnJvciA9IG51bGw7IGltZy5yZW1vdmVBdHRyaWJ1dGUoJ3NyYycpOyBkZWxl
dGUgaW1nLmRhdGFzZXQuYmFyZTsgfQogICAgfTsKICAgIHdpbmRvdy5fX2ltZ0hvdmVySGlkZSA9
IGZ1bmN0aW9uKCkgeyB3aW5kb3cuX19pbWdIb3ZlckNsZWFyVWkoKTsgfTsKICAgIGZ1bmN0aW9u
IGJpbmRJbWdIb3ZlclByZXZpZXcoZWwsIGlkLCBmaWxlKSB7CiAgICAgICAgaWYgKCFlbCkgcmV0
dXJuOwogICAgICAgIGNvbnN0IGJhcmUgPSBTdHJpbmcoZmlsZSB8fCAnJykuc3BsaXQoL1tcXFxc
L10vKS5wb3AoKTsgaWYgKCFiYXJlKSByZXR1cm47CiAgICAgICAgY29uc3Qga2V5ID0gU3RyaW5n
KGlkKSArICd8JyArIGJhcmU7CiAgICAgICAgZWwuc3R5bGUuY3Vyc29yID0gJ3pvb20taW4nOwog
ICAgICAgIGVsLmFkZEV2ZW50TGlzdGVuZXIoJ21vdXNlZW50ZXInLCAoKSA9PiB7CiAgICAgICAg
ICAgIGlmIChfX2ltZ0hvdmVySGlkZVRpbWVyKSB7IGNsZWFyVGltZW91dChfX2ltZ0hvdmVySGlk
ZVRpbWVyKTsgX19pbWdIb3ZlckhpZGVUaW1lciA9IDA7IH0KICAgICAgICAgICAgX19pbWdIb3Zl
cktleSA9IGtleTsKICAgICAgICAgICAgaWYgKF9faW1nSG92ZXJUaW1lcikgY2xlYXJUaW1lb3V0
KF9faW1nSG92ZXJUaW1lcik7CiAgICAgICAgICAgIF9faW1nSG92ZXJUaW1lciA9IHNldFRpbWVv
dXQoKCkgPT4geyBpZiAoX19pbWdIb3ZlcktleSA9PT0ga2V5KSB0cnkgeyB3aW5kb3cuX19pbWdI
b3ZlclNob3coYmFyZSwgaWQpOyB9IGNhdGNoIChlKSB7fSB9LCA2MCk7CiAgICAgICAgfSk7CiAg
ICAgICAgZWwuYWRkRXZlbnRMaXN0ZW5lcignbW91c2VsZWF2ZScsICgpID0+IHsKICAgICAgICAg
ICAgaWYgKF9faW1nSG92ZXJUaW1lcikgeyBjbGVhclRpbWVvdXQoX19pbWdIb3ZlclRpbWVyKTsg
X19pbWdIb3ZlclRpbWVyID0gMDsgfQogICAgICAgICAgICBfX2ltZ0hvdmVySGlkZVRpbWVyID0g
c2V0VGltZW91dCgoKSA9PiB7IGlmICghX19pbWdIb3ZlcktleSB8fCBfX2ltZ0hvdmVyS2V5ID09
PSBrZXkpIHdpbmRvdy5fX2ltZ0hvdmVySGlkZSgpOyB9LCA3MCk7CiAgICAgICAgfSk7CiAgICB9
CgogICAgZnVuY3Rpb24gcmVuZGVyKCkgewogICAgICAgIGhpZGVQYXRoVGlwKCk7CgogICAgICAg
IGNvbnN0IHZpc2libGUgPSB2aXNpYmxlTGlzdCgpOwogICAgICAgIGNvbnN0IGxvYWRlZCA9IGFs
bENsaXBzLmxlbmd0aDsKICAgICAgICBjb25zdCBzaG93bkNvdW50ID0gdmlzaWJsZS5sZW5ndGg7
CiAgICAgICAgLy8g5pS26JeP6KeS5qCH77ya5pS55Li657u/54K577yI5pyJ5pyq5p+l55yL55qE
5paw5pS26JeP5pe25pi+56S677yJCiAgICAgICAgbGV0IHBpbm5lZE4gPSBOdW1iZXIocGlubmVk
VG90YWwpIHx8IDA7CiAgICAgICAgaWYgKHBpbm5lZE4gPCAxKSB7CiAgICAgICAgICAgIGlmIChj
dXJUYWIgPT09ICdwaW5uZWQnKQogICAgICAgICAgICAgICAgcGlubmVkTiA9IE1hdGgubWF4KE51
bWJlcihkaXNrVG90YWwpIHx8IDAsIGxvYWRlZCk7CiAgICAgICAgICAgIGVsc2UKICAgICAgICAg
ICAgICAgIHBpbm5lZE4gPSBhbGxDbGlwcy5maWx0ZXIoYyA9PiBpc1Bpbm5lZChjKSkubGVuZ3Ro
OwogICAgICAgIH0KICAgICAgICB1cGRhdGVQaW5Eb3QoKTsKICAgICAgICAvLyDmlLbol48gdGFi
77yaYmFyIOeUqOaAu+aVsO+8m+acqua7oemhteaXtuaYvuekuiDlt7LliqDovb0v5oC75pWwCiAg
ICAgICAgbGV0IHNob3dUb3RhbCA9IGRpc2tUb3RhbCA+IDAgPyBkaXNrVG90YWwgOiAobG9hZGVk
IHx8IDApOwogICAgICAgIGlmIChjdXJUYWIgPT09ICdwaW5uZWQnICYmIHBpbm5lZE4gPiBzaG93
VG90YWwpCiAgICAgICAgICAgIHNob3dUb3RhbCA9IHBpbm5lZE47CiAgICAgICAgY29uc3QgcU9u
ID0gU3RyaW5nKHF1ZXJ5IHx8ICcnKS50cmltKCkubGVuZ3RoID4gMDsKICAgICAgICBkb2N1bWVu
dC5nZXRFbGVtZW50QnlJZCgnYmFyLXR4dCcpLnRleHRDb250ZW50ID0gcU9uCiAgICAgICAgICAg
ID8gKHNob3duQ291bnQgKyAnIOadoScpCiAgICAgICAgICAgIDogKHNob3dUb3RhbCA+IGxvYWRl
ZCA/IChzaG93bkNvdW50ICsgJyAvICcgKyBzaG93VG90YWwgKyAnIOadoScpIDogKHNob3dUb3Rh
bCArICcg5p2hJykpOwogICAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdlbXB0eS10eHQn
KS50ZXh0Q29udGVudCA9IEVNUFRZX01TR1tjdXJUYWJdIHx8IEVNUFRZX01TRy5hbGw7CgogICAg
ICAgIGNvbnN0IGlkU2V0ID0gbmV3IFNldChhbGxDbGlwcy5tYXAoYyA9PiArYy5pZCkpOwogICAg
ICAgIG11bHRpSWRzID0gbXVsdGlJZHMuZmlsdGVyKGlkID0+IGlkU2V0LmhhcyhpZCkpOwogICAg
ICAgIHVwZGF0ZU11bHRpQmFkZ2UoKTsKCiAgICAgICAgY29uc3Qgc2hvd24gPSB2aXNpYmxlOwoK
ICAgICAgICBsaXN0RWwucXVlcnlTZWxlY3RvckFsbCgnLml0bSwgI2xpc3QtbW9yZScpLmZvckVh
Y2goZSA9PiBlLnJlbW92ZSgpKTsKICAgICAgICAvLyDpqqjmnrblt7LlhbPpl63vvJrljbPkvb8g
d2FpdGluZyDkuZ/kuI0gcmV0dXJu77yM5pyJ5pWw5o2u5bCx55u05o6l55S7CiAgICAgICAgaWYg
KHNrZWxFbCkgc2tlbEVsLmNsYXNzTGlzdC5yZW1vdmUoJ29uJyk7CiAgICAgICAgY29uc3QgYXBw
Qm9vdCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdhcHAnKTsKICAgICAgICBpZiAoYXBwQm9v
dCkgYXBwQm9vdC5jbGFzc0xpc3QucmVtb3ZlKCdib290LWxvYWRpbmcnKTsKICAgICAgICBpZiAo
KHdhaXRpbmdEYXRhIHx8ICFob3N0UHVzaGVkT25jZSkgJiYgIXZpc2libGUubGVuZ3RoKSB7CiAg
ICAgICAgICAgIGVtcHR5RWwuY2xhc3NMaXN0LnJlbW92ZSgnb24nKTsKICAgICAgICAgICAgdXBk
YXRlVG9wQnRuKCk7CiAgICAgICAgICAgIHJldHVybjsKICAgICAgICB9CiAgICAgICAgaWYgKCF2
aXNpYmxlLmxlbmd0aCkgewogICAgICAgICAgICAvLyBOZXZlciBzaG9344CM5pqC5peg6K6w5b2V
44CNdW50aWwgd2UgaGF2ZSBzZWVuIGEgcmVhbCBub24tZW1wdHkgcHVzaCwKICAgICAgICAgICAg
Ly8gb3IgYSBjb25maXJtZWQgZW1wdHkgYWZ0ZXIgd2FybSAoc2F3Tm9uRW1wdHkgY2FuIGJlIHNl
dCBieSBlbXB0eS1mYWxsYmFjaykuCiAgICAgICAgICAgIC8vIEZpbHRlcmVkIHNlYXJjaCB3aXRo
IDAgaGl0cyBpcyBhbGxvd2VkIG9uY2UgaG9zdCBwdXNoZWQuCiAgICAgICAgICAgIGNvbnN0IHFP
biA9IFN0cmluZyhxdWVyeSB8fCAnJykudHJpbSgpLmxlbmd0aCA+IDA7CiAgICAgICAgICAgIGNv
bnN0IGFsbG93RW1wdHkgPSBob3N0UHVzaGVkT25jZSAmJiBzYXdOb25FbXB0eSAmJiAhd2FpdGlu
Z0RhdGEgJiYgIWJvb3RMb2FkaW5nCiAgICAgICAgICAgICAgICAmJiAocU9uIHx8IGRpc2tUb3Rh
bCA8PSAwKTsKICAgICAgICAgICAgaWYgKCFhbGxvd0VtcHR5KSB7CiAgICAgICAgICAgICAgICBl
bXB0eUVsLmNsYXNzTGlzdC5yZW1vdmUoJ29uJyk7CiAgICAgICAgICAgICAgICB1cGRhdGVUb3BC
dG4oKTsKICAgICAgICAgICAgICAgIHJldHVybjsKICAgICAgICAgICAgfQogICAgICAgICAgICBp
ZiAoc2VsZWN0Rmlyc3RPblNob3cpIHsKICAgICAgICAgICAgICAgIHNlbGVjdEZpcnN0T25TaG93
ID0gZmFsc2U7CiAgICAgICAgICAgICAgICBzZWxlY3RlZElkID0gMDsKICAgICAgICAgICAgICAg
IGNsZWFyTXVsdGkoKTsKICAgICAgICAgICAgICAgIGxpc3RFbC5zY3JvbGxUb3AgPSAwOwogICAg
ICAgICAgICB9CiAgICAgICAgICAgIGVtcHR5RWwuY2xhc3NMaXN0LmFkZCgnb24nKTsKICAgICAg
ICAgICAgdXBkYXRlVG9wQnRuKCk7CiAgICAgICAgICAgIHJldHVybjsKICAgICAgICB9CiAgICAg
ICAgZW1wdHlFbC5jbGFzc0xpc3QucmVtb3ZlKCdvbicpOwogICAgICAgIGNvbnN0IGZyYWcgPSBk
b2N1bWVudC5jcmVhdGVEb2N1bWVudEZyYWdtZW50KCk7CiAgICAgICAgY29uc3QgYmxvY2tzID0g
YnVpbGRQaW5uZWRCbG9ja3Moc2hvd24pOwogICAgICAgIGxldCBudW0gPSAwOwogICAgICAgIGJs
b2Nrcy5mb3JFYWNoKGIgPT4gewogICAgICAgICAgICBudW0gKz0gMTsKICAgICAgICAgICAgaWYg
KGIua2luZCA9PT0gJ2dyb3VwJyAmJiBiLml0ZW1zLmxlbmd0aCA+IDEpCiAgICAgICAgICAgICAg
ICBmcmFnLmFwcGVuZENoaWxkKG1ha2VHcm91cEl0ZW0oYi5pdGVtcywgbnVtKSk7CiAgICAgICAg
ICAgIGVsc2UKICAgICAgICAgICAgICAgIGZyYWcuYXBwZW5kQ2hpbGQobWFrZUl0ZW0oYi5pdGVt
c1swXSwgbnVtKSk7CiAgICAgICAgfSk7CiAgICAgICAgbGlzdEVsLmFwcGVuZENoaWxkKGZyYWcp
OwogICAgICAgIG1hcmtRdWV1ZVJhaWxzKCk7CiAgICAgICAgdXBkYXRlTW9yZUZvb3RlcihkaXNr
VG90YWwpOwogICAgICAgIGlmIChzZWxlY3RGaXJzdE9uU2hvdykgewogICAgICAgICAgICBzZWxl
Y3RGaXJzdE9uU2hvdyA9IGZhbHNlOwogICAgICAgICAgICBzZWxlY3RlZElkID0gdmlzaWJsZVsw
XS5pZDsKICAgICAgICAgICAgY2xlYXJNdWx0aSgpOwogICAgICAgICAgICBsaXN0RWwuc2Nyb2xs
VG9wID0gMDsKICAgICAgICB9IGVsc2UgaWYgKCF2aXNpYmxlLnNvbWUoYyA9PiBjLmlkID09IHNl
bGVjdGVkSWQpKSB7CiAgICAgICAgICAgIHNlbGVjdGVkSWQgPSB2aXNpYmxlWzBdLmlkOwogICAg
ICAgICAgICByYW5nZUFuY2hvcklkID0gc2VsZWN0ZWRJZDsKICAgICAgICAgICAgcmFuZ2VBbmNo
b3JDbGlja2VkID0gZmFsc2U7CiAgICAgICAgfSBlbHNlIGlmICghcmFuZ2VBbmNob3JJZCkgewog
ICAgICAgICAgICByYW5nZUFuY2hvcklkID0gc2VsZWN0ZWRJZDsKICAgICAgICB9CiAgICAgICAg
c3luY0l0ZW1IaWdobGlnaHQoKTsKICAgICAgICB1cGRhdGVUb3BCdG4oKTsKICAgICAgICBpZiAo
d2luZG93Ll9fcGVuZGluZ0p1bXBJZCkgewogICAgICAgICAgICBjb25zdCBqaWQgPSArd2luZG93
Ll9fcGVuZGluZ0p1bXBJZDsKICAgICAgICAgICAgY29uc3QgZWwgPSBsaXN0RWwucXVlcnlTZWxl
Y3RvcignLm1nLXJvd1tkYXRhLWlkPSInICsgamlkICsgJyJdJykgfHwgbGlzdEVsLnF1ZXJ5U2Vs
ZWN0b3IoJy5pdG1bZGF0YS1pZD0iJyArIGppZCArICciXScpOwogICAgICAgICAgICBpZiAoZWwp
IHsKICAgICAgICAgICAgICAgIHdpbmRvdy5fX3BlbmRpbmdKdW1wSWQgPSAwOwogICAgICAgICAg
ICAgICAgd2luZG93Ll9fanVtcExvYWRUcmllcyA9IDA7CiAgICAgICAgICAgICAgICBzZWxlY3Rl
ZElkID0gamlkOwogICAgICAgICAgICAgICAgcmVxdWVzdEFuaW1hdGlvbkZyYW1lKCgpID0+IHsK
ICAgICAgICAgICAgICAgICAgICBjb25zdCBub2RlID0gbGlzdEVsLnF1ZXJ5U2VsZWN0b3IoJy5t
Zy1yb3dbZGF0YS1pZD0iJyArIGppZCArICciXScpIHx8IGxpc3RFbC5xdWVyeVNlbGVjdG9yKCcu
aXRtW2RhdGEtaWQ9IicgKyBqaWQgKyAnIl0nKTsKICAgICAgICAgICAgICAgICAgICBpZiAoIW5v
ZGUpIHJldHVybjsKICAgICAgICAgICAgICAgICAgICBub2RlLnNjcm9sbEludG9WaWV3KHsgYmxv
Y2s6ICdjZW50ZXInIH0pOwogICAgICAgICAgICAgICAgICAgIG5vZGUuY2xhc3NMaXN0LmFkZCgn
anVtcC1mbGFzaCcpOwogICAgICAgICAgICAgICAgICAgIHNldFRpbWVvdXQoKCkgPT4gbm9kZS5j
bGFzc0xpc3QucmVtb3ZlKCdqdW1wLWZsYXNoJyksIDkwMCk7CiAgICAgICAgICAgICAgICAgICAg
c3luY0l0ZW1IaWdobGlnaHQoKTsKICAgICAgICAgICAgICAgIH0pOwogICAgICAgICAgICB9IGVs
c2UgaWYgKGFsbENsaXBzLmxlbmd0aCA8IGRpc2tUb3RhbCAmJiAod2luZG93Ll9fanVtcExvYWRU
cmllcyB8fCAwKSA8IDQwKSB7CiAgICAgICAgICAgICAgICB3aW5kb3cuX19qdW1wTG9hZFRyaWVz
ID0gKHdpbmRvdy5fX2p1bXBMb2FkVHJpZXMgfHwgMCkgKyAxOwogICAgICAgICAgICAgICAgcmVx
dWVzdE1vcmUoKTsKICAgICAgICAgICAgfSBlbHNlIGlmIChjdXJUYWIgIT09ICdhbGwnICYmICF3
aW5kb3cuX19qdW1wRmVsbEJhY2spIHsKICAgICAgICAgICAgICAgIC8vIEl0ZW0gZ29uZSBmcm9t
IHRoaXMgdGFiIChlLmcuIHVucGlubmVkKSDigJQgZmFsbCBiYWNrIHRvIOWFqOmDqCBvbmNlCiAg
ICAgICAgICAgICAgICB3aW5kb3cuX19qdW1wRmVsbEJhY2sgPSB0cnVlOwogICAgICAgICAgICAg
ICAgd2luZG93Ll9fanVtcExvYWRUcmllcyA9IDA7CiAgICAgICAgICAgICAgICBjdXJUYWIgPSAn
YWxsJzsKICAgICAgICAgICAgICAgIG1hcmtUYWIoJ2FsbCcpOwogICAgICAgICAgICAgICAgcmVx
dWVzdFZpZXcoKTsKICAgICAgICAgICAgfSBlbHNlIHsKICAgICAgICAgICAgICAgIHdpbmRvdy5f
X3BlbmRpbmdKdW1wSWQgPSAwOwogICAgICAgICAgICAgICAgd2luZG93Ll9fanVtcExvYWRUcmll
cyA9IDA7CiAgICAgICAgICAgICAgICBpZiAoYWxsQ2xpcHMuc29tZShjID0+ICtjLmlkID09PSBq
aWQpKQogICAgICAgICAgICAgICAgICAgIHNlbGVjdGVkSWQgPSBqaWQ7CiAgICAgICAgICAgICAg
ICBzeW5jSXRlbUhpZ2hsaWdodCgpOwogICAgICAgICAgICB9CiAgICAgICAgfQogICAgICAgIHJl
cXVlc3RBbmltYXRpb25GcmFtZSgoKSA9PiB7CiAgICAgICAgICAgIGlmIChhbGxDbGlwcy5sZW5n
dGggPCBkaXNrVG90YWwKICAgICAgICAgICAgICAgICYmIGxpc3RFbC5zY3JvbGxIZWlnaHQgPD0g
bGlzdEVsLmNsaWVudEhlaWdodCArIDIwKQogICAgICAgICAgICAgICAgcmVxdWVzdE1vcmUoKTsK
ICAgICAgICAgICAgc2NoZWR1bGVGaWxlR29uZUNoZWNrKCk7CiAgICAgICAgfSk7CiAgICB9Cgog
ICAgY29uc3QgU1ZHID0gewogICAgICAgIHRleHQ6ICAgYDxzdmcgdmlld0JveD0iMCAwIDI0IDI0
IiBmaWxsPSJub25lIiBzdHJva2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIyIj48cGF0
aCBkPSJNNCA3VjRoMTZ2M005IDIwaDZNMTIgNHYxNiIvPjwvc3ZnPmAsCiAgICAgICAgbWQ6ICAg
ICBgPHN2ZyB2aWV3Qm94PSIwIDAgMjQgMjQiIGZpbGw9ImN1cnJlbnRDb2xvciI+PHRleHQgeD0i
MTIiIHk9IjE3IiB0ZXh0LWFuY2hvcj0ibWlkZGxlIiBmb250LXNpemU9IjE1IiBmb250LXdlaWdo
dD0iODAwIiBmb250LWZhbWlseT0iU2Vnb2UgVUksTWljcm9zb2Z0IFlhSGVpLHNhbnMtc2VyaWYi
Pk08L3RleHQ+PC9zdmc+YCwKICAgICAgICBpbWFnZTogIGA8c3ZnIHZpZXdCb3g9IjAgMCAyNCAy
NCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0cm9rZS13aWR0aD0iMS44Ij48
cmVjdCB4PSIzIiB5PSI1IiB3aWR0aD0iMTgiIGhlaWdodD0iMTQiIHJ4PSIyIi8+PGNpcmNsZSBj
eD0iOC41IiBjeT0iMTAiIHI9IjEuNSIgZmlsbD0iY3VycmVudENvbG9yIiBzdHJva2U9Im5vbmUi
Lz48cGF0aCBkPSJNMyAxNmw1LTUgNCA0IDMtMyA2IDYiLz48L3N2Zz5gLAogICAgICAgIHZpZGVv
OiAgYDxzdmcgdmlld0JveD0iMCAwIDI0IDI0IiBmaWxsPSJub25lIiBzdHJva2U9ImN1cnJlbnRD
b2xvciIgc3Ryb2tlLXdpZHRoPSIxLjgiPjxyZWN0IHg9IjMiIHk9IjYiIHdpZHRoPSIxNCIgaGVp
Z2h0PSIxMiIgcng9IjIiLz48cGF0aCBkPSJNMTcgOS41bDQtMi41djEwbC00LTIuNVY5LjV6IiBm
aWxsPSJjdXJyZW50Q29sb3IiIHN0cm9rZT0ibm9uZSIvPjxwYXRoIGQ9Ik04LjUgMTAuMnYzLjZs
My4yLTEuOC0zLjItMS44eiIgZmlsbD0iY3VycmVudENvbG9yIiBzdHJva2U9Im5vbmUiLz48L3N2
Zz5gLAogICAgICAgIGZvbGRlcjogYDxzdmcgdmlld0JveD0iMCAwIDI0IDI0IiBmaWxsPSJjdXJy
ZW50Q29sb3IiPjxwYXRoIGQ9Ik0xMCA0SDRjLTEuMSAwLTIgLjktMiAydjEyYzAgMS4xLjkgMiAy
IDJoMTZjMS4xIDAgMi0uOSAyLTJWOGMwLTEuMS0uOS0yLTItMmgtOGwtMi0yeiIvPjwvc3ZnPmAs
CiAgICAgICAgemlwOiAgICBgPHN2ZyB2aWV3Qm94PSIwIDAgMjQgMjQiIGZpbGw9Im5vbmUiIHN0
cm9rZT0iY3VycmVudENvbG9yIiBzdHJva2Utd2lkdGg9IjEuOCI+PHBhdGggZD0iTTYgM2g5bDUg
NXYxM2ExIDEgMCAwIDEtMSAxSDZhMSAxIDAgMCAxLTEtMVY0YTEgMSAwIDAgMSAxLTF6Ii8+PHBh
dGggZD0iTTE0IDN2Nmg2Ii8+PC9zdmc+YCwKICAgICAgICBhaGs6ICAgIGA8c3ZnIHZpZXdCb3g9
IjAgMCAyNCAyNCIgZmlsbD0iY3VycmVudENvbG9yIj48dGV4dCB4PSIxMiIgeT0iMTciIHRleHQt
YW5jaG9yPSJtaWRkbGUiIGZvbnQtc2l6ZT0iMTQiIGZvbnQtd2VpZ2h0PSI3MDAiPkg8L3RleHQ+
PC9zdmc+YCwKICAgICAgICBsbms6ICAgIGA8c3ZnIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0i
bm9uZSIgc3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0cm9rZS13aWR0aD0iMS44Ij48cGF0aCBkPSJN
MTAgMTNhNSA1IDAgMCAwIDcuMDcgMGwyLjEyLTIuMTJhNSA1IDAgMCAwLTcuMDctNy4wN0wxMSA1
Ii8+PHBhdGggZD0iTTE0IDExYTUgNSAwIDAgMC03LjA3IDBMNC44IDEzLjEyYTUgNSAwIDEgMCA3
LjA3IDcuMDdMMTMgMTkiLz48L3N2Zz5gLAogICAgICAgIGRvYzogICAgYDxzdmcgdmlld0JveD0i
MCAwIDI0IDI0IiBmaWxsPSJub25lIiBzdHJva2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRo
PSIxLjgiPjxwYXRoIGQ9Ik03IDNoN2w1IDV2MTNhMSAxIDAgMCAxLTEgMUg3YTEgMSAwIDAgMS0x
LTFWNGExIDEgMCAwIDEgMS0xeiIvPjxwYXRoIGQ9Ik0xNCAzdjZoNiIvPjwvc3ZnPmAsCiAgICAg
ICAgbXVsdGk6ICBgPHN2ZyB2aWV3Qm94PSIwIDAgMjQgMjQiIGZpbGw9Im5vbmUiIHN0cm9rZT0i
Y3VycmVudENvbG9yIiBzdHJva2Utd2lkdGg9IjEuOCI+PHJlY3QgeD0iNyIgeT0iNyIgd2lkdGg9
IjEyIiBoZWlnaHQ9IjE0IiByeD0iMS41Ii8+PHBhdGggZD0iTTUgMTdWNWExIDEgMCAwIDEgMS0x
aDEwIi8+PC9zdmc+YAogICAgfTsKCiAgICBmdW5jdGlvbiBmaWxlRXh0KHBhdGgpIHsKICAgICAg
ICBjb25zdCBiYXNlID0gU3RyaW5nKHBhdGggfHwgJycpLnNwbGl0KC9bXFwvXS8pLnBvcCgpIHx8
ICcnOwogICAgICAgIGNvbnN0IGkgPSBiYXNlLmxhc3RJbmRleE9mKCcuJyk7CiAgICAgICAgcmV0
dXJuIGkgPiAwID8gYmFzZS5zbGljZShpICsgMSkudG9Mb3dlckNhc2UoKSA6ICcnOwogICAgfQog
ICAgY29uc3QgaXNJbWFnZUV4dCA9IGUgPT4gWydwbmcnLCdqcGcnLCdqcGVnJywnZ2lmJywnd2Vi
cCcsJ2JtcCcsJ2ljbycsJ3RpZicsJ3RpZmYnLCdzdmcnXS5pbmNsdWRlcyhlKTsKICAgIGNvbnN0
IGlzVmlkZW9FeHQgPSBlID0+IFsnbXA0JywnbWt2JywnYXZpJywnbW92Jywnd212JywnZmx2Jywn
d2VibScsJ200dicsJ21wZWcnLCdtcGcnLCd0cycsJ20ydHMnLCczZ3AnLCdybScsJ3JtdmInXS5p
bmNsdWRlcyhlKTsKICAgIGNvbnN0IGlzWmlwRXh0ICAgPSBlID0+IFsnemlwJywncmFyJywnN3on
LCd0YXInLCdneicsJ2J6MiddLmluY2x1ZGVzKGUpOwoKICAgIGZ1bmN0aW9uIGljb25Gb3JGaWxl
cyhmaWxlcykgewogICAgICAgIGlmICghZmlsZXMubGVuZ3RoKSAgICByZXR1cm4geyBjbHM6ICdm
aWxlIGZ0LWRvYycsIHN2ZzogU1ZHLmRvYyB9OwogICAgICAgIGlmIChmaWxlcy5sZW5ndGggPiAx
KSByZXR1cm4geyBjbHM6ICdmaWxlIGZ0LWxuaycsIHN2ZzogU1ZHLm11bHRpIH07CiAgICAgICAg
Y29uc3QgZXh0ID0gZmlsZUV4dChmaWxlc1swXSk7CiAgICAgICAgaWYgKCFleHQpICAgICAgICAg
ICAgICByZXR1cm4geyBjbHM6ICdmaWxlIGZ0LWRpcicsIHN2ZzogU1ZHLmZvbGRlciB9OwogICAg
ICAgIGlmIChpc0ltYWdlRXh0KGV4dCkpICAgcmV0dXJuIHsgY2xzOiAnZmlsZSBmdC1pbWcnLCBz
dmc6IFNWRy5pbWFnZSB9OwogICAgICAgIGlmIChpc1ZpZGVvRXh0KGV4dCkpICAgcmV0dXJuIHsg
Y2xzOiAnZmlsZSBmdC12aWQnLCBzdmc6IChTVkcudmlkZW8gfHwgU1ZHLmRvYykgfTsKICAgICAg
ICBpZiAoaXNaaXBFeHQoZXh0KSkgICAgIHJldHVybiB7IGNsczogJ2ZpbGUgZnQtemlwJywgc3Zn
OiBTVkcuemlwIH07CiAgICAgICAgaWYgKGV4dCA9PT0gJ2FoaycpICAgICByZXR1cm4geyBjbHM6
ICdmaWxlIGZ0LWFoaycsIHN2ZzogU1ZHLmFoayB9OwogICAgICAgIGlmIChleHQgPT09ICdsbmsn
KSAgICAgcmV0dXJuIHsgY2xzOiAnZmlsZSBmdC1sbmsnLCBzdmc6IFNWRy5sbmsgfTsKICAgICAg
ICByZXR1cm4geyBjbHM6ICdmaWxlIGZ0LWRvYycsIHN2ZzogU1ZHLmRvYyB9OwogICAgfQoKICAg
IGZ1bmN0aW9uIHNyY1dpbkxhYmVsKGMpIHsKICAgICAgICBjb25zdCB0ID0gU3RyaW5nKGMgJiYg
Yy5zcmNUaXRsZSB8fCAnJykudHJpbSgpOwogICAgICAgIGlmICh0KSByZXR1cm4gdDsKICAgICAg
ICByZXR1cm4gU3RyaW5nKGMgJiYgYy5zcmNFeGUgfHwgJycpLnJlcGxhY2UoL1wuZXhlJC9pLCAn
Jyk7CiAgICB9CiAgICBmdW5jdGlvbiBzcmNUaXRsZUh0bWwoYykgewogICAgICAgIC8vIOWIl+ih
qOS4remXtC/lj7PkvqfkuI3lho3mmL7npLrnqpflj6PmoIfpopjvvIzmnaXmupDlj6rkv53nlZnl
j7Pkvqflm77moIfmgqzlgZzmj5DnpLoKICAgICAgICByZXR1cm4gJyc7CiAgICB9CiAgICBmdW5j
dGlvbiBleHBhbmRDaGV2cm9uKG9wZW4pIHsKICAgICAgICByZXR1cm4gb3BlbgogICAgICAgICAg
ICA/IGA8c3ZnIHZpZXdCb3g9IjAgMCAxNiAxNiIgd2lkdGg9IjE0IiBoZWlnaHQ9IjE0IiBmaWxs
PSJub25lIiBzdHJva2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIxLjgiIHN0cm9rZS1s
aW5lY2FwPSJyb3VuZCI+PHBvbHlsaW5lIHBvaW50cz0iNCAxMCA4IDYgMTIgMTAiLz48L3N2Zz48
c3Bhbj7mlLbotbc8L3NwYW4+YAogICAgICAgICAgICA6IGA8c3ZnIHZpZXdCb3g9IjAgMCAxNiAx
NiIgd2lkdGg9IjE0IiBoZWlnaHQ9IjE0IiBmaWxsPSJub25lIiBzdHJva2U9ImN1cnJlbnRDb2xv
ciIgc3Ryb2tlLXdpZHRoPSIxLjgiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCI+PHBvbHlsaW5lIHBv
aW50cz0iNCA2IDggMTAgMTIgNiIvPjwvc3ZnPjxzcGFuPuWxleW8gDwvc3Bhbj5gOwogICAgfQog
ICAgZnVuY3Rpb24gbGlzdEV4cGFuZE1heFB4KCkgewogICAgICAgIGNvbnN0IGggPSAobGlzdEVs
ICYmIGxpc3RFbC5jbGllbnRIZWlnaHQpIHx8IDM2MDsKICAgICAgICAvLyDlh6DkuY7ljaDmu6Hl
iJfooajvvIzlupXpg6jnlZnnuqbkuIDooYwKICAgICAgICByZXR1cm4gTWF0aC5tYXgoOTYsIGgg
LSAyOCk7CiAgICB9CiAgICBmdW5jdGlvbiBhcHBseUV4cGFuZGVkUHJldmlldyhwcmV2LCBmdWxs
VGV4dCkgewogICAgICAgIGNvbnN0IG1heEggPSBsaXN0RXhwYW5kTWF4UHgoKTsKICAgICAgICBw
cmV2LnN0eWxlLm1heEhlaWdodCA9IG1heEggKyAncHgnOwogICAgICAgIHByZXYuY2xhc3NMaXN0
LmFkZCgnZXhwYW5kZWQnKTsKICAgICAgICBzZXRIbFRleHQocHJldiwgZnVsbFRleHQpOwogICAg
ICAgIC8vIOS7jea6ouWHuu+8muaIquaWreW5tuWcqOacq+WwvuWKoOOAjCAuLi7jgI0KICAgICAg
ICBpZiAocHJldi5zY3JvbGxIZWlnaHQgPD0gcHJldi5jbGllbnRIZWlnaHQgKyAyKQogICAgICAg
ICAgICByZXR1cm47CiAgICAgICAgbGV0IGxvID0gMCwgaGkgPSBmdWxsVGV4dC5sZW5ndGgsIGJl
c3QgPSAwOwogICAgICAgIHdoaWxlIChsbyA8PSBoaSkgewogICAgICAgICAgICBjb25zdCBtaWQg
PSAobG8gKyBoaSkgPj4gMTsKICAgICAgICAgICAgc2V0SGxUZXh0KHByZXYsIGZ1bGxUZXh0LnNs
aWNlKDAsIG1pZCkgKyAnIC4uLicpOwogICAgICAgICAgICBpZiAocHJldi5zY3JvbGxIZWlnaHQg
PD0gcHJldi5jbGllbnRIZWlnaHQgKyAyKSB7CiAgICAgICAgICAgICAgICBiZXN0ID0gbWlkOwog
ICAgICAgICAgICAgICAgbG8gPSBtaWQgKyAxOwogICAgICAgICAgICB9IGVsc2UgewogICAgICAg
ICAgICAgICAgaGkgPSBtaWQgLSAxOwogICAgICAgICAgICB9CiAgICAgICAgfQogICAgICAgIHNl
dEhsVGV4dChwcmV2LCBmdWxsVGV4dC5zbGljZSgwLCBiZXN0KSArICcgLi4uJyk7CiAgICB9CiAg
ICBmdW5jdGlvbiBjb2xsYXBzZVByZXZpZXcocHJldiwgZnVsbFRleHQpIHsKICAgICAgICBwcmV2
LmNsYXNzTGlzdC5yZW1vdmUoJ2V4cGFuZGVkJyk7CiAgICAgICAgcHJldi5zdHlsZS5tYXhIZWln
aHQgPSAnJzsKICAgICAgICBzZXRIbFRleHQocHJldiwgZnVsbFRleHQpOwogICAgfQoKICAgIGZ1
bmN0aW9uIGZhdkdyb3VwT2YoYykgewogICAgICAgIHJldHVybiBTdHJpbmcoYyAmJiBjLmZhdkdy
b3VwIHx8ICcnKS50cmltKCk7CiAgICB9CiAgICBmdW5jdGlvbiBjbGlwQ29udGVudFByZXZpZXco
YykgewogICAgICAgIGNvbnN0IHR5cGUgPSBub3JtVHlwZShjLnR5cGUpOwogICAgICAgIGlmICh0
eXBlID09PSAnaW1hZ2UnKSByZXR1cm4gJ1vlm77lg49dJyArIChjLndpZHRoICYmIGMuaGVpZ2h0
ID8gKCcgJyArIGMud2lkdGggKyAnw5cnICsgYy5oZWlnaHQpIDogJycpOwogICAgICAgIGlmICh0
eXBlID09PSAnZmlsZScpIHsKICAgICAgICAgICAgY29uc3QgZmlsZXMgPSBTdHJpbmcoYy5wcmV2
aWV3IHx8IGMuZGF0YSB8fCAnJykuc3BsaXQoL1xyP1xuLykuZmlsdGVyKEJvb2xlYW4pOwogICAg
ICAgICAgICByZXR1cm4gZmlsZXMubWFwKGYgPT4gZi5zcGxpdCgvW1xcL10vKS5wb3AoKSkuam9p
bignIMK3ICcpIHx8ICdb5paH5Lu2XSc7CiAgICAgICAgfQogICAgICAgIGxldCBfcCA9IFN0cmlu
ZyhjLnByZXZpZXcgfHwgYy5kYXRhIHx8ICcnKTsKICAgICAgICB7IGNvbnN0IF9uID0gTnVtYmVy
KGMuY2hhckNvdW50KSB8fCAwOyBpZiAoX24gPiBfcC5sZW5ndGggJiYgX3AubGVuZ3RoKSBfcCAr
PSAnLi4uJzsgfQogICAgICAgIHJldHVybiBfcDsKICAgIH0KICAgIGZ1bmN0aW9uIGJ1aWxkUGlu
bmVkQmxvY2tzKGxpc3QpIHsKICAgICAgICBjb25zdCB1c2VkID0gbmV3IFNldCgpOwogICAgICAg
IGNvbnN0IG91dCA9IFtdOwogICAgICAgIGZvciAoY29uc3QgYyBvZiBsaXN0KSB7CiAgICAgICAg
ICAgIGlmICh1c2VkLmhhcygrYy5pZCkpIGNvbnRpbnVlOwogICAgICAgICAgICBjb25zdCBnaWQg
PSBmYXZHcm91cE9mKGMpOwogICAgICAgICAgICBpZiAoIWdpZCkgewogICAgICAgICAgICAgICAg
dXNlZC5hZGQoK2MuaWQpOwogICAgICAgICAgICAgICAgb3V0LnB1c2goeyBraW5kOiAnc2luZ2xl
JywgaXRlbXM6IFtjXSB9KTsKICAgICAgICAgICAgICAgIGNvbnRpbnVlOwogICAgICAgICAgICB9
CiAgICAgICAgICAgIGNvbnN0IG1lbWJlcnMgPSBsaXN0LmZpbHRlcih4ID0+IGZhdkdyb3VwT2Yo
eCkgPT09IGdpZCk7CiAgICAgICAgICAgIG1lbWJlcnMuZm9yRWFjaChtID0+IHVzZWQuYWRkKCtt
LmlkKSk7CiAgICAgICAgICAgIGlmIChtZW1iZXJzLmxlbmd0aCA8IDIpCiAgICAgICAgICAgICAg
ICBvdXQucHVzaCh7IGtpbmQ6ICdzaW5nbGUnLCBpdGVtczogW21lbWJlcnNbMF0gfHwgY10gfSk7
CiAgICAgICAgICAgIGVsc2UKICAgICAgICAgICAgICAgIG91dC5wdXNoKHsga2luZDogJ2dyb3Vw
JywgZ2lkLCBpdGVtczogbWVtYmVycyB9KTsKICAgICAgICB9CiAgICAgICAgcmV0dXJuIG91dDsK
ICAgIH0KICAgIGZ1bmN0aW9uIF9fcHJlcFBhc3RlKCkgewogICAgICAgIHRyeSB7CiAgICAgICAg
ICAgIGNvbnN0IHMgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc2VhcmNoJyk7CiAgICAgICAg
ICAgIGlmIChzICYmIGRvY3VtZW50LmFjdGl2ZUVsZW1lbnQgPT09IHMpIHRyeSB7IHMuYmx1cigp
OyB9IGNhdGNoIHt9CiAgICAgICAgICAgIGlmICh3aW5kb3cuZ2V0U2VsZWN0aW9uKSB3aW5kb3cu
Z2V0U2VsZWN0aW9uKCkucmVtb3ZlQWxsUmFuZ2VzKCk7CiAgICAgICAgfSBjYXRjaCB7fQogICAg
fQogICAgZnVuY3Rpb24gcGFzdGVPbmUoYykgewogICAgICAgIF9fcHJlcFBhc3RlKCk7CiAgICAg
ICAgc2VsZWN0ZWRJZCA9IGMuaWQ7CiAgICAgICAgaWYgKG11bHRpSWRzLmxlbmd0aCkgY2xlYXJN
dWx0aSgpOwogICAgICAgIHN5bmNJdGVtSGlnaGxpZ2h0KCk7CiAgICAgICAgbWFya1Bhc3RlZExv
Y2FsKGMuaWQpOwogICAgICAgIGFoaygncGFzdGUnLCBTdHJpbmcoYy5pZCkpOwogICAgfQogICAg
ZnVuY3Rpb24gb3BlblJlY2VudERpcihwYXRoKSB7CiAgICAgICAgbGV0IHAgPSBTdHJpbmcocGF0
aCB8fCAnJykudHJpbSgpOwogICAgICAgIGlmICghcCkgcmV0dXJuOwogICAgICAgIGlmICgvXlth
LXpBLVpdOiQvLnRlc3QocCkpIHAgKz0gJ1xcJzsKICAgICAgICAvLyDnu5/kuIAgLyDvvJrpgb/l
hY0gV2ViVmlldyBob3N0L0pTT04g5ZCD5o6J5Y+N5pac5p2gCiAgICAgICAgY29uc3Qgd2lyZSA9
IHAucmVwbGFjZSgvXFwvZywgJy8nKTsKICAgICAgICBjb25zdCBzZW5kID0gKCkgPT4gewogICAg
ICAgICAgICAvLyAxKSBwb3N0TWVzc2FnZSDmnIDnqLPvvIjkuI3ov5sgc3luYyBDT03vvIkKICAg
ICAgICAgICAgdHJ5IHsKICAgICAgICAgICAgICAgIGlmICh3aW5kb3cuY2hyb21lICYmIGNocm9t
ZS53ZWJ2aWV3ICYmIHR5cGVvZiBjaHJvbWUud2Vidmlldy5wb3N0TWVzc2FnZSA9PT0gJ2Z1bmN0
aW9uJykgewogICAgICAgICAgICAgICAgICAgIGNocm9tZS53ZWJ2aWV3LnBvc3RNZXNzYWdlKCdv
cGVuRGlyfCcgKyB3aXJlKTsKICAgICAgICAgICAgICAgICAgICByZXR1cm4gdHJ1ZTsKICAgICAg
ICAgICAgICAgIH0KICAgICAgICAgICAgfSBjYXRjaCB7fQogICAgICAgICAgICAvLyAyKSBhc3lu
YyBob3N077yI6Z2eIHN5bmPvvIkKICAgICAgICAgICAgdHJ5IHsKICAgICAgICAgICAgICAgIGNv
bnN0IGhvc3QgPSBjaHJvbWUud2Vidmlldy5ob3N0T2JqZWN0cy5haGs7CiAgICAgICAgICAgICAg
ICBpZiAoaG9zdCAmJiBob3N0Lm9wZW5EaXIpIHsKICAgICAgICAgICAgICAgICAgICBQcm9taXNl
LnJlc29sdmUoaG9zdC5vcGVuRGlyKHdpcmUpKS5jYXRjaCgoKSA9PiB7fSk7CiAgICAgICAgICAg
ICAgICAgICAgcmV0dXJuIHRydWU7CiAgICAgICAgICAgICAgICB9CiAgICAgICAgICAgIH0gY2F0
Y2gge30KICAgICAgICAgICAgLy8gMykg5pyA5ZCO5omNIHN5bmMKICAgICAgICAgICAgdHJ5IHsg
YWhrKCdvcGVuRGlyJywgd2lyZSk7IHJldHVybiB0cnVlOyB9IGNhdGNoIHt9CiAgICAgICAgICAg
IHJldHVybiBmYWxzZTsKICAgICAgICB9OwogICAgICAgIC8vIOemu+W8gCBwb2ludGVyIOS6i+S7
tuagiOWGjeiwg++8jOmBv+WFjSBXZWJWaWV3MiDlkIzmraXmrbvplIHlr7zoh7TigJzngrnkuobm
sqHlj43lupTigJ0KICAgICAgICBzZXRUaW1lb3V0KHNlbmQsIDApOwogICAgfQogICAgZnVuY3Rp
b24gaXNJdGVtQ2hyb21lVGFyZ2V0KHQpIHsKICAgICAgICByZXR1cm4gISEodCAmJiB0LmNsb3Nl
c3QgJiYgdC5jbG9zZXN0KCcuaS1leHBhbmQtYnRuLCAuaS1zcmMtaWNvLCAubWctc3JjLCAuZmQt
YnRuLCAuZmQtcGF0aCwgLnJmLXNlZywgYnV0dG9uLCBhLCBpbnB1dCcpKTsKICAgIH0KICAgIGZ1
bmN0aW9uIGJlZ2luUGFzdGVGcm9tSXRlbShlLCBjKSB7CiAgICAgICAgaWYgKGUuYnV0dG9uICE9
IG51bGwgJiYgZS5idXR0b24gIT09IDApIHJldHVybjsKICAgICAgICBjb25zdCBzZWcgPSBlLnRh
cmdldCAmJiBlLnRhcmdldC5jbG9zZXN0ICYmIGUudGFyZ2V0LmNsb3Nlc3QoJy5yZi1zZWcnKTsK
ICAgICAgICBpZiAoc2VnKSB7CiAgICAgICAgICAgIGNvbnN0IG9wZW5QYXRoID0gc2VnLl9vcGVu
UGF0aCB8fCBzZWcuZ2V0QXR0cmlidXRlKCdkYXRhLXBhdGgnKSB8fCBzZWcuZGF0YXNldC5vcGVu
UGF0aCB8fCAnJzsKICAgICAgICAgICAgaWYgKG9wZW5QYXRoKSB7CiAgICAgICAgICAgICAgICBl
LnByZXZlbnREZWZhdWx0KCk7CiAgICAgICAgICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwog
ICAgICAgICAgICAgICAgb3BlblJlY2VudERpcihvcGVuUGF0aCk7CiAgICAgICAgICAgICAgICBy
ZXR1cm47CiAgICAgICAgICAgIH0KICAgICAgICB9CiAgICAgICAgaWYgKGUudGFyZ2V0ICYmIGUu
dGFyZ2V0LmNsb3Nlc3QgJiYgZS50YXJnZXQuY2xvc2VzdCgnLnJmLXBhdGgnKSkKICAgICAgICAg
ICAgcmV0dXJuOwogICAgICAgIGlmIChpc0l0ZW1DaHJvbWVUYXJnZXQoZS50YXJnZXQpKSByZXR1
cm47CiAgICAgICAgaWYgKG5vcm1UeXBlKGMudHlwZSkgPT09ICdyZWNlbnQnKSB7CiAgICAgICAg
ICAgIGFjdGl2YXRlQ2xpcEl0ZW0oYyk7CiAgICAgICAgICAgIHJldHVybjsKICAgICAgICB9CiAg
ICAgICAgaWYgKGhhbmRsZUl0ZW1DbGljayhlLCBjKSkKICAgICAgICAgICAgcmV0dXJuOwogICAg
ICAgIF9fcHJlcFBhc3RlKCk7CiAgICAgICAgc2VsZWN0ZWRJZCA9IGMuaWQ7CiAgICAgICAgcmFu
Z2VBbmNob3JJZCA9IGMuaWQ7CiAgICAgICAgICAgIGlmIChtdWx0aUlkcy5sZW5ndGggPiAwICYm
IG11bHRpSWRzLmluY2x1ZGVzKCtjLmlkKSkgewogICAgICAgICAgICBjb25zdCBpZHMgPSBtdWx0
aUlkcy5zbGljZSgpOwogICAgICAgICAgICBjbGVhck11bHRpKCk7CiAgICAgICAgICAgIG1hcmtQ
YXN0ZWRMb2NhbChpZHMpOwogICAgICAgICAgICBwYXN0ZU1hbnlXaXRoU2VwKGlkcyk7CiAgICAg
ICAgICAgIHJldHVybjsKICAgICAgICB9CiAgICAgICAgaWYgKG11bHRpSWRzLmxlbmd0aCkgY2xl
YXJNdWx0aSgpOwogICAgICAgIHN5bmNJdGVtSGlnaGxpZ2h0KCk7CiAgICAgICAgbWFya1Bhc3Rl
ZExvY2FsKGMuaWQpOwogICAgICAgIGFoaygncGFzdGUnLCBTdHJpbmcoYy5pZCkpOwogICAgfQog
ICAgZnVuY3Rpb24gbWFrZUdyb3VwSXRlbShpdGVtcywgaWR4KSB7CiAgICAgICAgY29uc3QgZWwg
PSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsKICAgICAgICBlbC5jbGFzc05hbWUgPSAn
aXRtIGl0LWdyb3VwJwogICAgICAgICAgICArIChpdGVtcy5zb21lKGMgPT4gK2MuaWQgPT09ICtz
ZWxlY3RlZElkKSA/ICcgc2VsJyA6ICcnKQogICAgICAgICAgICArIChpdGVtcy5zb21lKGMgPT4g
bXVsdGlJZHMuaW5jbHVkZXMoK2MuaWQpKSA/ICcgbXVsdGknIDogJycpOwogICAgICAgIGVsLmRh
dGFzZXQuZ3JvdXAgPSBmYXZHcm91cE9mKGl0ZW1zWzBdKSB8fCAnJzsKICAgICAgICBlbC5kYXRh
c2V0LmlkID0gaXRlbXNbMF0uaWQ7CgogICAgICAgIGNvbnN0IGhlYWQgPSBkb2N1bWVudC5jcmVh
dGVFbGVtZW50KCdkaXYnKTsKICAgICAgICBoZWFkLmNsYXNzTmFtZSA9ICdtZy1oZWFkJzsKICAg
ICAgICBoZWFkLmlubmVySFRNTCA9ICc8c3BhbiBjbGFzcz0ibWctdGFnIj7lkIjlubY8L3NwYW4+
PHNwYW4+JyArIGl0ZW1zLmxlbmd0aCArICcg5p2hIMK3IOeCueWHu+WNleadoeeymOi0tDwvc3Bh
bj4nOwogICAgICAgIGVsLmFwcGVuZENoaWxkKGhlYWQpOwoKICAgICAgICBpdGVtcy5mb3JFYWNo
KGMgPT4gewogICAgICAgICAgICBjb25zdCByb3cgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdk
aXYnKTsKICAgICAgICAgICAgcm93LmNsYXNzTmFtZSA9ICdtZy1yb3cnCiAgICAgICAgICAgICAg
ICArICgrc2VsZWN0ZWRJZCA9PT0gK2MuaWQgPyAnIHNlbCcgOiAnJykKICAgICAgICAgICAgICAg
ICsgKG11bHRpSWRzLmluY2x1ZGVzKCtjLmlkKSA/ICcgbXVsdGknIDogJycpOwogICAgICAgICAg
ICByb3cuZGF0YXNldC5pZCA9IGMuaWQ7CgogICAgICAgICAgICBjb25zdCB0b3AgPSBkb2N1bWVu
dC5jcmVhdGVFbGVtZW50KCdkaXYnKTsKICAgICAgICAgICAgdG9wLmNsYXNzTmFtZSA9ICdtZy1y
b3ctdG9wJzsKICAgICAgICAgICAgY29uc3QgbWFpbiA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQo
J2RpdicpOwogICAgICAgICAgICBtYWluLmNsYXNzTmFtZSA9ICdtZy1yb3ctbWFpbic7CgogICAg
ICAgICAgICBjb25zdCB0aXRsZSA9IFN0cmluZyhjLmZhdlRpdGxlIHx8ICcnKS50cmltKCk7CiAg
ICAgICAgICAgIGlmICh0aXRsZSkgewogICAgICAgICAgICAgICAgY29uc3QgdCA9IGRvY3VtZW50
LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOwogICAgICAgICAgICAgICAgdC5jbGFzc05hbWUgPSAnbWct
dGl0bGUnOwogICAgICAgICAgICAgICAgc2V0SGxUZXh0KHQsIHRpdGxlKTsKICAgICAgICAgICAg
ICAgIG1haW4uYXBwZW5kQ2hpbGQodCk7CiAgICAgICAgICAgIH0KICAgICAgICAgICAgY29uc3Qg
Ym9keSA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOwogICAgICAgICAgICBib2R5LmNs
YXNzTmFtZSA9ICdtZy1ib2R5JyArIChub3JtVHlwZShjLnR5cGUpID09PSAnaW1hZ2UnID8gJyBp
bWcnIDogJycpOwogICAgICAgICAgICBzZXRIbFRleHQoYm9keSwgY2xpcENvbnRlbnRQcmV2aWV3
KGMpKTsKICAgICAgICAgICAgbWFpbi5hcHBlbmRDaGlsZChib2R5KTsKICAgICAgICAgICAgdG9w
LmFwcGVuZENoaWxkKG1haW4pOwoKICAgICAgICAgICAgY29uc3Qgc3JjSWNvID0gU3RyaW5nKGMu
c3JjSWNvbiB8fCAnJyk7CiAgICAgICAgICAgIGNvbnN0IHNyY0V4ZSA9IFN0cmluZyhjLnNyY0V4
ZSB8fCAnJyk7CiAgICAgICAgICAgIGNvbnN0IHNyY1RpdGxlID0gU3RyaW5nKGMuc3JjVGl0bGUg
fHwgJycpOwogICAgICAgICAgICBpZiAoc3JjSWNvKSB7CiAgICAgICAgICAgICAgICBjb25zdCBp
bWcgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdpbWcnKTsKICAgICAgICAgICAgICAgIGltZy5j
bGFzc05hbWUgPSAnbWctc3JjJzsKICAgICAgICAgICAgICAgIGltZy5zcmMgPSBTVE9SRV9CQVNF
ICsgZW5jb2RlVVJJQ29tcG9uZW50KHNyY0ljbyk7CiAgICAgICAgICAgICAgICBpbWcuYWx0ID0g
Jyc7CiAgICAgICAgICAgICAgICBjb25zdCB0aXBUeHQgPSBzcmNUaXRsZSB8fCBzcmNFeGUgfHwg
J+adpea6kCc7CiAgICAgICAgICAgICAgICBpbWcudGl0bGUgPSB0aXBUeHQ7CiAgICAgICAgICAg
ICAgICBpbWcub25jbGljayA9IGUgPT4geyBlLnByZXZlbnREZWZhdWx0KCk7IGUuc3RvcFByb3Bh
Z2F0aW9uKCk7IHNob3dTcmNUaXAoaW1nLCB0aXBUeHQpOyB9OwogICAgICAgICAgICAgICAgdG9w
LmFwcGVuZENoaWxkKGltZyk7CiAgICAgICAgICAgIH0KICAgICAgICAgICAgcm93LmFwcGVuZENo
aWxkKHRvcCk7CgogICAgICAgICAgICByb3cub25wb2ludGVyZG93biA9IGUgPT4gewogICAgICAg
ICAgICAgICAgaWYgKGUuYnV0dG9uICE9PSAwKSByZXR1cm47CiAgICAgICAgICAgICAgICBlLnN0
b3BQcm9wYWdhdGlvbigpOwogICAgICAgICAgICAgICAgYmVnaW5QYXN0ZUZyb21JdGVtKGUsIGMp
OwogICAgICAgICAgICB9OwogICAgICAgICAgICByb3cub25jb250ZXh0bWVudSA9IGUgPT4gewog
ICAgICAgICAgICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOwogICAgICAgICAgICAgICAgZS5zdG9w
UHJvcGFnYXRpb24oKTsKICAgICAgICAgICAgICAgIHNlbGVjdGVkSWQgPSBjLmlkOwogICAgICAg
ICAgICAgICAgc2hvd0N0eChlLmNsaWVudFgsIGUuY2xpZW50WSwgYyk7CiAgICAgICAgICAgIH07
CiAgICAgICAgICAgIGVsLmFwcGVuZENoaWxkKHJvdyk7CiAgICAgICAgfSk7CgogICAgICAgIGVs
Lm9uY29udGV4dG1lbnUgPSBlID0+IHsKICAgICAgICAgICAgaWYgKGUudGFyZ2V0LmNsb3Nlc3Qo
Jy5tZy1yb3cnKSkgcmV0dXJuOwogICAgICAgICAgICBlLnByZXZlbnREZWZhdWx0KCk7CiAgICAg
ICAgICAgIHNlbGVjdGVkSWQgPSBpdGVtc1swXS5pZDsKICAgICAgICAgICAgc2hvd0N0eChlLmNs
aWVudFgsIGUuY2xpZW50WSwgaXRlbXNbMF0pOwogICAgICAgIH07CiAgICAgICAgcmV0dXJuIGVs
OwogICAgfQoKCiAgICBmdW5jdGlvbiBidWlsZFJlY2VudFBhdGhDcnVtYnMoY29udGFpbmVyLCBm
dWxsUGF0aCkgewogICAgICAgIGlmICghY29udGFpbmVyKSByZXR1cm47CiAgICAgICAgY29udGFp
bmVyLnF1ZXJ5U2VsZWN0b3JBbGwoJy5yZi1zZWcsIC5yZi1zZXAnKS5mb3JFYWNoKG4gPT4gbi5y
ZW1vdmUoKSk7CiAgICAgICAgY29uc3QgcmF3ID0gU3RyaW5nKGZ1bGxQYXRoIHx8ICcnKS5yZXBs
YWNlKC9cLy9nLCAnXFwnKS5yZXBsYWNlKC9cXCskLywgJycpOwogICAgICAgIGlmICghcmF3KSBy
ZXR1cm47CiAgICAgICAgY29uc3QgdW5jID0gcmF3LnN0YXJ0c1dpdGgoJ1xcXFwnKTsKICAgICAg
ICBsZXQgcmVzdCA9IHVuYyA/IHJhdy5zbGljZSgyKSA6IHJhdzsKICAgICAgICBjb25zdCBwYXJ0
cyA9IHJlc3Quc3BsaXQoJ1xcJykuZmlsdGVyKEJvb2xlYW4pOwogICAgICAgIGNvbnN0IGFkZFNl
ZyA9IChsYWJlbCwgb3BlblBhdGgpID0+IHsKICAgICAgICAgICAgaWYgKGNvbnRhaW5lci5xdWVy
eVNlbGVjdG9yKCcucmYtc2VnLCAucmYtc2VwJykpIHsKICAgICAgICAgICAgICAgIGNvbnN0IHNl
cCA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ3NwYW4nKTsKICAgICAgICAgICAgICAgIHNlcC5j
bGFzc05hbWUgPSAncmYtc2VwJzsKICAgICAgICAgICAgICAgIHNlcC50ZXh0Q29udGVudCA9ICdc
XCc7CiAgICAgICAgICAgICAgICBjb250YWluZXIuYXBwZW5kQ2hpbGQoc2VwKTsKICAgICAgICAg
ICAgfQogICAgICAgICAgICAvLyBidXR0b27vvJrlkb3kuK3mm7TnqLPvvIzkuI3ooqsgYXBwLXJl
Z2lvbiAvIOeItue6pyBwb2ludGVyIOWQg+aOiQogICAgICAgICAgICBjb25zdCBzZWcgPSBkb2N1
bWVudC5jcmVhdGVFbGVtZW50KCdidXR0b24nKTsKICAgICAgICAgICAgc2VnLnR5cGUgPSAnYnV0
dG9uJzsKICAgICAgICAgICAgc2VnLmNsYXNzTmFtZSA9ICdyZi1zZWcnOwogICAgICAgICAgICBz
ZXRIbFRleHQoc2VnLCBsYWJlbCk7CiAgICAgICAgICAgIHNlZy50aXRsZSA9ICfmiZPlvIA6ICcg
KyBvcGVuUGF0aDsKICAgICAgICAgICAgc2VnLnNldEF0dHJpYnV0ZSgnZGF0YS1wYXRoJywgb3Bl
blBhdGgucmVwbGFjZSgvXFwvZywgJy8nKSk7CiAgICAgICAgICAgIHNlZy5fb3BlblBhdGggPSBv
cGVuUGF0aDsKICAgICAgICAgICAgc2VnLmFkZEV2ZW50TGlzdGVuZXIoJ2NsaWNrJywgZSA9PiB7
CiAgICAgICAgICAgICAgICBlLnByZXZlbnREZWZhdWx0KCk7CiAgICAgICAgICAgICAgICBlLnN0
b3BQcm9wYWdhdGlvbigpOwogICAgICAgICAgICAgICAgb3BlblJlY2VudERpcihvcGVuUGF0aCk7
CiAgICAgICAgICAgIH0sIHRydWUpOwogICAgICAgICAgICBzZWcuYWRkRXZlbnRMaXN0ZW5lcign
cG9pbnRlcmRvd24nLCBlID0+IHsKICAgICAgICAgICAgICAgIGlmIChlLmJ1dHRvbiAhPT0gMCkg
cmV0dXJuOwogICAgICAgICAgICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOwogICAgICAgICAgICAg
ICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICAgICAgICAgIG9wZW5SZWNlbnREaXIob3Bl
blBhdGgpOwogICAgICAgICAgICB9LCB0cnVlKTsKICAgICAgICAgICAgY29udGFpbmVyLmFwcGVu
ZENoaWxkKHNlZyk7CiAgICAgICAgfTsKICAgICAgICBpZiAoIXBhcnRzLmxlbmd0aCkgewogICAg
ICAgICAgICBhZGRTZWcocmF3LCByYXcpOwogICAgICAgICAgICByZXR1cm47CiAgICAgICAgfQog
ICAgICAgIGxldCBhY2MgPSB1bmMgPyAnXFxcXCcgKyBwYXJ0c1swXSA6IHBhcnRzWzBdOwogICAg
ICAgIGlmICghdW5jICYmIC9eW2EtekEtWl06JC8udGVzdChwYXJ0c1swXSkpCiAgICAgICAgICAg
IGFjYyA9IHBhcnRzWzBdICsgJ1xcJzsKICAgICAgICBhZGRTZWcocGFydHNbMF0sIGFjYyk7CiAg
ICAgICAgZm9yIChsZXQgaSA9IDE7IGkgPCBwYXJ0cy5sZW5ndGg7IGkrKykgewogICAgICAgICAg
ICBhY2MgPSBhY2MucmVwbGFjZSgvXFwrJC8sICcnKSArICdcXCcgKyBwYXJ0c1tpXTsKICAgICAg
ICAgICAgYWRkU2VnKHBhcnRzW2ldLCBhY2MpOwogICAgICAgIH0KICAgIH0KCiAgICBmdW5jdGlv
biBhY3RpdmF0ZUNsaXBJdGVtKGMpIHsKICAgICAgICBpZiAoIWMpIHJldHVybjsKICAgICAgICBp
ZiAobm9ybVR5cGUoYy50eXBlKSA9PT0gJ3JlY2VudCcpIHsKICAgICAgICAgICAgX19wcmVwUGFz
dGUoKTsKICAgICAgICAgICAgc2VsZWN0ZWRJZCA9IGMuaWQ7CiAgICAgICAgICAgIGlmIChtdWx0
aUlkcy5sZW5ndGgpIGNsZWFyTXVsdGkoKTsKICAgICAgICAgICAgc3luY0l0ZW1IaWdobGlnaHQo
KTsKICAgICAgICAgICAgYWhrKCdwYXN0ZScsIFN0cmluZyhjLmlkKSk7CiAgICAgICAgICAgIHJl
dHVybjsKICAgICAgICB9CiAgICAgICAgcGFzdGVPbmUoYyk7CiAgICB9CiAgICBmdW5jdGlvbiBt
YWtlSXRlbShjLCBpZHgpIHsKICAgICAgICBjb25zdCB0eXBlICAgPSBub3JtVHlwZShjLnR5cGUp
OwogICAgICAgIGNvbnN0IHBpbm5lZCA9IGlzUGlubmVkKGMpOwogICAgICAgIGNvbnN0IHBhc3Rl
ZCA9IGlzUGFzdGVkKGMpOwogICAgICAgIGNvbnN0IGVsICAgICA9IGRvY3VtZW50LmNyZWF0ZUVs
ZW1lbnQoJ2RpdicpOwogICAgICAgIGVsLmNsYXNzTmFtZSAgPSAnaXRtJwogICAgICAgICAgICAr
IChzZWxlY3RlZElkID09IGMuaWQgPyAnIHNlbCcgOiAnJykKICAgICAgICAgICAgKyAobXVsdGlJ
ZHMuaW5jbHVkZXMoK2MuaWQpID8gJyBtdWx0aScgOiAnJyk7CiAgICAgICAgZWwuZGF0YXNldC5p
ZCA9IGMuaWQ7CiAgICAgICAgY29uc3QgcWcgPSBOdW1iZXIoYy5xdWV1ZUdyb3VwKSB8fCAwOwog
ICAgICAgIGlmIChxZyA+IDApIHsKICAgICAgICAgICAgZWwuY2xhc3NMaXN0LmFkZCgncS1tZW1i
ZXInKTsKICAgICAgICAgICAgZWwuZGF0YXNldC5xZyA9IFN0cmluZyhxZyk7CiAgICAgICAgICAg
IGVsLmRhdGFzZXQucWkgPSBTdHJpbmcoTnVtYmVyKGMucXVldWVJbmRleCkgfHwgMCk7CiAgICAg
ICAgICAgIGlmIChwYXN0ZWQpIGVsLmNsYXNzTGlzdC5hZGQoJ3EtZG9uZScpOwogICAgICAgICAg
ICBjb25zdCByYWlsID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnc3BhbicpOwogICAgICAgICAg
ICByYWlsLmNsYXNzTmFtZSA9ICdxLXJhaWwnOwogICAgICAgICAgICBjb25zdCBkb3QgPSBkb2N1
bWVudC5jcmVhdGVFbGVtZW50KCdzcGFuJyk7CiAgICAgICAgICAgIGRvdC5jbGFzc05hbWUgPSAn
cS1kb3QnOwogICAgICAgICAgICBkb3QudGl0bGUgPSBwYXN0ZWQgPyAn6Zif5YiX5bey57KY6LS0
JyA6ICfnspjotLTpmJ/liJcnOwogICAgICAgICAgICBlbC5hcHBlbmRDaGlsZChyYWlsKTsKICAg
ICAgICAgICAgZWwuYXBwZW5kQ2hpbGQoZG90KTsKICAgICAgICB9CgogICAgICAgIGNvbnN0IGlj
byAgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsKICAgICAgICBjb25zdCBib2R5ID0g
ZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnZGl2Jyk7CiAgICAgICAgYm9keS5jbGFzc05hbWUgPSAn
aS1ib2R5JzsKCiAgICAgICAgaWYgKHR5cGUgPT09ICdpbWFnZScpIHsKICAgICAgICAgICAgaWNv
LmNsYXNzTmFtZSA9ICdpLWljbyBpbWFnZSc7CiAgICAgICAgICAgIGljby5pbm5lckhUTUwgPSBT
VkcuaW1hZ2U7CiAgICAgICAgICAgIGJpbmRJbWdIb3ZlclByZXZpZXcoaWNvLCBjLmlkLCBjLmlt
Z0ZpbGUpOwogICAgICAgICAgICBjb25zdCB3cmFwID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgn
ZGl2Jyk7CiAgICAgICAgICAgIHdyYXAuY2xhc3NOYW1lID0gJ2ktdGh1bWItd3JhcCc7CiAgICAg
ICAgICAgIGNvbnN0IGltZyAgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdpbWcnKTsKICAgICAg
ICAgICAgaW1nLmNsYXNzTmFtZSA9ICdpLXRodW1iJzsKICAgICAgICAgICAgaW1nLmFsdCA9ICcn
OwogICAgICAgICAgICBjb25zdCBmaWxlID0gU3RyaW5nKGMuaW1nRmlsZSB8fCAnJyk7CiAgICAg
ICAgICAgIGxldCBmYWxsYmFjayA9IFN0cmluZyhjLmRhdGEgfHwgJycpOwogICAgICAgICAgICAv
LyBOZXZlciBzeW5jLWNhbGwgQUhLIHRodW1iIGhlcmUg4oCUIGZyZWV6ZXMgdGFiIHN3aXRjaGVz
OyBQdXNoU3RvcmVUaHVtYnMgZmlsbHMgYXN5bmMKICAgICAgICAgICAgaWYgKCFmYWxsYmFjay5z
dGFydHNXaXRoKCdkYXRhOicpICYmIHRodW1iQ2FjaGUuaGFzKFN0cmluZyhjLmlkKSkpCiAgICAg
ICAgICAgICAgICBmYWxsYmFjayA9IFN0cmluZyh0aHVtYkNhY2hlLmdldChTdHJpbmcoYy5pZCkp
KTsKICAgICAgICAgICAgaW1nLm9ubG9hZCA9ICgpID0+IHsKICAgICAgICAgICAgICAgIGNvbnN0
IG13ID0gd3JhcC5jbGllbnRXaWR0aCB8fCAzMDA7CiAgICAgICAgICAgICAgICBjb25zdCBudyA9
IGltZy5uYXR1cmFsV2lkdGggIHx8IDA7CiAgICAgICAgICAgICAgICBjb25zdCBuaCA9IGltZy5u
YXR1cmFsSGVpZ2h0IHx8IDA7CiAgICAgICAgICAgICAgICBpZiAoIW53IHx8ICFuaCkgcmV0dXJu
OwogICAgICAgICAgICAgICAgY29uc3Qgc2NhbGUgPSBNYXRoLm1pbigxLCAxODAgLyBuaCwgbXcg
LyBudyk7CiAgICAgICAgICAgICAgICBpbWcuc3R5bGUud2lkdGggID0gTWF0aC5yb3VuZChudyAq
IHNjYWxlKSArICdweCc7CiAgICAgICAgICAgICAgICBpbWcuc3R5bGUuaGVpZ2h0ID0gTWF0aC5y
b3VuZChuaCAqIHNjYWxlKSArICdweCc7CiAgICAgICAgICAgIH07CiAgICAgICAgICAgIGJpbmRT
dG9yZVRodW1iKGltZywgZmlsZSwgYy5pZCwgZmFsbGJhY2spOwogICAgICAgICAgICB3cmFwLmFw
cGVuZENoaWxkKGltZyk7CiAgICAgICAgICAgIGNvbnN0IG1ldGEgPSBkb2N1bWVudC5jcmVhdGVF
bGVtZW50KCdkaXYnKTsKICAgICAgICAgICAgbWV0YS5jbGFzc05hbWUgPSAnaS1tZXRhJzsKICAg
ICAgICAgICAgbWV0YS5pbm5lckhUTUwgID0gYDxzcGFuIGNsYXNzPSJpLXRpbWUiPiR7YWdvKGMu
dGltZSl9PC9zcGFuPiR7bWV0YUNlbnRlckh0bWwoZmFsc2UpfTxkaXYgY2xhc3M9ImktbWV0YS1y
aWdodCI+JHtjLndpZHRoID8gYDxzcGFuIGNsYXNzPSJpLXRhZyI+JHtjLndpZHRofcOXJHtjLmhl
aWdodH0gcHg8L3NwYW4+YCA6ICcnfTwvZGl2PmA7CiAgICAgICAgICAgIGJvZHkuYXBwZW5kQ2hp
bGQod3JhcCk7CiAgICAgICAgICAgIGJvZHkuYXBwZW5kQ2hpbGQobWV0YSk7CiAgICAgICAgfSBl
bHNlIGlmICh0eXBlID09PSAncmVjZW50JykgewogICAgICAgICAgICBpY28uY2xhc3NOYW1lID0g
J2ktaWNvIGZpbGUgZnQtZGlyJzsKICAgICAgICAgICAgaWNvLmlubmVySFRNTCA9IFNWRy5mb2xk
ZXI7CiAgICAgICAgICAgIGlmIChwaW5uZWQpIGVsLmNsYXNzTGlzdC5hZGQoJ3JmLWZpeGVkJyk7
CiAgICAgICAgICAgIGNvbnN0IHBhdGggPSBTdHJpbmcoYy5kYXRhIHx8IGMucHJldmlldyB8fCAn
Jyk7CiAgICAgICAgICAgIGNvbnN0IGNydW1icyA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2Rp
dicpOwogICAgICAgICAgICBjcnVtYnMuY2xhc3NOYW1lID0gJ3JmLXBhdGgnOwogICAgICAgICAg
ICBidWlsZFJlY2VudFBhdGhDcnVtYnMoY3J1bWJzLCBwYXRoKTsKICAgICAgICAgICAgLy8g5Zu6
5a6a5qCH6K6w5Y+q5pS+IG1ldGEg5Y+z5L6n77yM5LiN5oyh6Lev5b6ECiAgICAgICAgICAgIGNv
bnN0IG1ldGEgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsKICAgICAgICAgICAgbWV0
YS5jbGFzc05hbWUgPSAnaS1tZXRhJzsKICAgICAgICAgICAgbWV0YS5pbm5lckhUTUwgPQogICAg
ICAgICAgICAgICAgYDxzcGFuIGNsYXNzPSJpLXRpbWUiPiR7YWdvKGMudGltZSl9PC9zcGFuPmAg
KwogICAgICAgICAgICAgICAgbWV0YUNlbnRlckh0bWwoZmFsc2UpICsKICAgICAgICAgICAgICAg
IGA8ZGl2IGNsYXNzPSJpLW1ldGEtcmlnaHQiPiR7cGlubmVkID8gJzxzcGFuIGNsYXNzPSJyZi1w
aW4tdGFnIiB0aXRsZT0i5bey5Zu65a6a77yM5LiN5Lya6KKr5reY5rGwIj7lm7rlrpo8L3NwYW4+
JyA6ICcnfTwvZGl2PmA7CiAgICAgICAgICAgIGJvZHkuYXBwZW5kQ2hpbGQoY3J1bWJzKTsKICAg
ICAgICAgICAgYm9keS5hcHBlbmRDaGlsZChtZXRhKTsKICAgICAgICB9IGVsc2UgaWYgKHR5cGUg
PT09ICdmaWxlJykgewogICAgICAgICAgICBjb25zdCBmaWxlcyA9IFN0cmluZyhjLnByZXZpZXcg
fHwgYy5kYXRhIHx8ICcnKS5zcGxpdCgvXHI/XG4vKS5maWx0ZXIoQm9vbGVhbik7CiAgICAgICAg
ICAgIGNvbnN0IGltYWdlUGF0aHMgPSBmaWxlcy5maWx0ZXIoZiA9PiBpc0ltYWdlRXh0KGZpbGVF
eHQoZikpKTsKICAgICAgICAgICAgY29uc3QgaWMgICAgPSBpY29uRm9yRmlsZXMoZmlsZXMpOwog
ICAgICAgICAgICBpY28uY2xhc3NOYW1lID0gJ2ktaWNvICcgKyBpYy5jbHM7CiAgICAgICAgICAg
IGljby5pbm5lckhUTUwgPSBpYy5zdmc7CgogICAgICAgICAgICBsZXQgdGh1bWJGaWxlID0gU3Ry
aW5nKGMuaW1nRmlsZSB8fCAnJyk7CiAgICAgICAgICAgIC8qIGVuc3VyZUZpbGVJbWcgZGVmZXJy
ZWQ6IGF2b2lkIHN5bmMgZnJlZXplIG9uIGZpbGUgdGFiICovCgogICAgICAgICAgICAvLyBJbWFn
ZS1mb3JtYXQgZmlsZXM6IHNhbWUgdGh1bWJuYWlsIHJ1bGVzIGFzIHNjcmVlbnNob3QgY2xpcHMK
ICAgICAgICAgICAgaWYgKHRodW1iRmlsZSB8fCBpbWFnZVBhdGhzLmxlbmd0aCkgewogICAgICAg
ICAgICAgICAgY29uc3Qgd3JhcCA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOwogICAg
ICAgICAgICAgICAgd3JhcC5jbGFzc05hbWUgPSAnaS10aHVtYi13cmFwJzsKICAgICAgICAgICAg
ICAgIGNvbnN0IGltZyAgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdpbWcnKTsKICAgICAgICAg
ICAgICAgIGltZy5jbGFzc05hbWUgPSAnaS10aHVtYic7CiAgICAgICAgICAgICAgICBpbWcuYWx0
ID0gJyc7CiAgICAgICAgICAgICAgICBpbWcub25sb2FkID0gKCkgPT4gewogICAgICAgICAgICAg
ICAgICAgIGNvbnN0IG13ID0gd3JhcC5jbGllbnRXaWR0aCB8fCAzMDA7CiAgICAgICAgICAgICAg
ICAgICAgY29uc3QgbncgPSBpbWcubmF0dXJhbFdpZHRoICB8fCAwOwogICAgICAgICAgICAgICAg
ICAgIGNvbnN0IG5oID0gaW1nLm5hdHVyYWxIZWlnaHQgfHwgMDsKICAgICAgICAgICAgICAgICAg
ICBpZiAoIW53IHx8ICFuaCkgcmV0dXJuOwogICAgICAgICAgICAgICAgICAgIGNvbnN0IHNjYWxl
ID0gTWF0aC5taW4oMSwgMTgwIC8gbmgsIG13IC8gbncpOwogICAgICAgICAgICAgICAgICAgIGlt
Zy5zdHlsZS53aWR0aCAgPSBNYXRoLnJvdW5kKG53ICogc2NhbGUpICsgJ3B4JzsKICAgICAgICAg
ICAgICAgICAgICBpbWcuc3R5bGUuaGVpZ2h0ID0gTWF0aC5yb3VuZChuaCAqIHNjYWxlKSArICdw
eCc7CiAgICAgICAgICAgICAgICB9OwogICAgICAgICAgICAvKiBlbnN1cmVGaWxlSW1nIGRlZmVy
cmVkOiBhdm9pZCBzeW5jIGZyZWV6ZSBvbiBmaWxlIHRhYiAqLwogICAgICAgICAgICAgICAgYmlu
ZFN0b3JlVGh1bWIoaW1nLCB0aHVtYkZpbGUsIGMuaWQsICcnKTsKICAgICAgICAgICAgICAgIHdy
YXAuYXBwZW5kQ2hpbGQoaW1nKTsKICAgICAgICAgICAgICAgIGJvZHkuYXBwZW5kQ2hpbGQod3Jh
cCk7CiAgICAgICAgICAgIH0KCiAgICAgICAgICAgIGNvbnN0IG5hbWUgPSBkb2N1bWVudC5jcmVh
dGVFbGVtZW50KCdkaXYnKTsKICAgICAgICAgICAgbmFtZS5jbGFzc05hbWUgID0gJ2ktbmFtZSc7
CiAgICAgICAgICAgIHNldEhsVGV4dChuYW1lLCBmaWxlcy5tYXAoZiA9PiBmLnNwbGl0KC9bXFwv
XS8pLnBvcCgpKS5qb2luKCdcbicpIHx8ICco5paH5Lu2KScpOwoKICAgICAgICAgICAgZWwuX2Zp
bGVQYXRocyA9IGZpbGVzOwoKICAgICAgICAgICAgY29uc3QgZGV0YWlsID0gZG9jdW1lbnQuY3Jl
YXRlRWxlbWVudCgnZGl2Jyk7CiAgICAgICAgICAgIGRldGFpbC5jbGFzc05hbWUgPSAnaS1maWxl
LWRldGFpbCc7CgogICAgICAgICAgICBjb25zdCBtZXRhID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVu
dCgnZGl2Jyk7CiAgICAgICAgICAgIG1ldGEuY2xhc3NOYW1lID0gJ2ktbWV0YSc7CiAgICAgICAg
ICAgIGxldCByaWdodCA9ICcnOwogICAgICAgICAgICByaWdodCArPSBgPHNwYW4gY2xhc3M9Imkt
dGFnIj4ke2MuZmlsZUNvdW50IHx8IGZpbGVzLmxlbmd0aCB8fCAxfSDkuKrmlofku7Y8L3NwYW4+
YDsKICAgICAgICAgICAgaWYgKCh0aHVtYkZpbGUgfHwgaW1hZ2VQYXRocy5sZW5ndGgpICYmIGMu
d2lkdGgpCiAgICAgICAgICAgICAgICByaWdodCArPSBgPHNwYW4gY2xhc3M9ImktdGFnIj4ke2Mu
d2lkdGh9w5cke2MuaGVpZ2h0fSBweDwvc3Bhbj5gOwogICAgICAgICAgICBjb25zdCBleHBhbmRI
dG1sID0gZXhwYW5kQ2hldnJvbihmYWxzZSk7CiAgICAgICAgICAgIGNvbnN0IGNvbGxhcHNlSHRt
bCA9IGV4cGFuZENoZXZyb24odHJ1ZSk7CiAgICAgICAgICAgIG1ldGEuaW5uZXJIVE1MID0KICAg
ICAgICAgICAgICAgIGA8c3BhbiBjbGFzcz0iaS10aW1lIj4ke2FnbyhjLnRpbWUpfTwvc3Bhbj5g
ICsKICAgICAgICAgICAgICAgIG1ldGFDZW50ZXJIdG1sKHsgb246IHRydWUsIGh0bWw6IGV4cGFu
ZEh0bWwgfSkgKwogICAgICAgICAgICAgICAgYDxkaXYgY2xhc3M9ImktbWV0YS1yaWdodCI+JHty
aWdodH08L2Rpdj5gOwoKICAgICAgICAgICAgY29uc3QgZXhwQnRuID0gbWV0YS5xdWVyeVNlbGVj
dG9yKCcuaS1leHBhbmQtYnRuJyk7CiAgICAgICAgICAgIGxldCBkZXRhaWxCdWlsdCA9IGZhbHNl
OwogICAgICAgICAgICBleHBCdG4ub25jbGljayA9IGUgPT4gewogICAgICAgICAgICAgICAgZS5w
cmV2ZW50RGVmYXVsdCgpOwogICAgICAgICAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAg
ICAgICAgICAgICAgIGNvbnN0IG9wZW4gPSAhZGV0YWlsLmNsYXNzTGlzdC5jb250YWlucygnb24n
KTsKICAgICAgICAgICAgICAgIGlmIChvcGVuICYmICFkZXRhaWxCdWlsdCkgewogICAgICAgICAg
ICAgICAgICAgIGNvbnN0IHBhdGhSb3dzID0gZWwuX3BhdGhSb3dzIHx8IGNoZWNrRmlsZVBhdGhz
KGVsLl9maWxlUGF0aHMgfHwgZmlsZXMpOwogICAgICAgICAgICAgICAgICAgIGZpbGxGaWxlRGV0
YWlsUGFuZWwoZGV0YWlsLCBwYXRoUm93cyk7CiAgICAgICAgICAgICAgICAgICAgZGV0YWlsQnVp
bHQgPSB0cnVlOwogICAgICAgICAgICAgICAgfQogICAgICAgICAgICAgICAgZGV0YWlsLmNsYXNz
TGlzdC50b2dnbGUoJ29uJywgb3Blbik7CiAgICAgICAgICAgICAgICBpZiAob3BlbikgewogICAg
ICAgICAgICAgICAgICAgIGRldGFpbC5zdHlsZS5tYXhIZWlnaHQgPSBsaXN0RXhwYW5kTWF4UHgo
KSArICdweCc7CiAgICAgICAgICAgICAgICAgICAgZGV0YWlsLnN0eWxlLm92ZXJmbG93ID0gJ2F1
dG8nOwogICAgICAgICAgICAgICAgfSBlbHNlIHsKICAgICAgICAgICAgICAgICAgICBkZXRhaWwu
c3R5bGUubWF4SGVpZ2h0ID0gJyc7CiAgICAgICAgICAgICAgICAgICAgZGV0YWlsLnN0eWxlLm92
ZXJmbG93ID0gJyc7CiAgICAgICAgICAgICAgICB9CiAgICAgICAgICAgICAgICBleHBCdG4uaW5u
ZXJIVE1MID0gb3BlbiA/IGNvbGxhcHNlSHRtbCA6IGV4cGFuZEh0bWw7CiAgICAgICAgICAgIH07
CgogICAgICAgICAgICBib2R5LmFwcGVuZENoaWxkKG5hbWUpOwogICAgICAgICAgICBib2R5LmFw
cGVuZENoaWxkKGRldGFpbCk7CiAgICAgICAgICAgIGJvZHkuYXBwZW5kQ2hpbGQobWV0YSk7CiAg
ICAgICAgfSBlbHNlIHsKICAgICAgICAgICAgY29uc3QgdXNlTSA9IGNsaXBVc2VzTUljb24oYyk7
CiAgICAgICAgICAgIGljby5jbGFzc05hbWUgPSB1c2VNID8gJ2ktaWNvIG1kJyA6ICdpLWljbyB0
ZXh0JzsKICAgICAgICAgICAgaWNvLmlubmVySFRNTCA9IHVzZU0gPyAoU1ZHLm1kIHx8IFNWRy50
ZXh0KSA6IFNWRy50ZXh0OwogICAgICAgICAgICAvKiBwbGFpbi1saXN0LXByZXYgKi8KICAgICAg
ICAgICAgLyogcHJldmlldy1lbGxpcHNpcyAqLwogICAgICAgICAgICBsZXQgdHh0ICA9IGMucHJl
dmlldyB8fCBjLmRhdGEgfHwgJyc7CiAgICAgICAgICAgIHsgY29uc3QgX24gPSBOdW1iZXIoYy5j
aGFyQ291bnQpIHx8IDA7IGlmIChfbiA+IHR4dC5sZW5ndGggJiYgdHh0Lmxlbmd0aCkgdHh0ICs9
ICcuLi4nOyB9CiAgICAgICAgICAgIGNvbnN0IHByZXYgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50
KCdkaXYnKTsKICAgICAgICAgICAgcHJldi5jbGFzc05hbWUgID0gJ2ktcHJldicgKyAoaXNVcmwo
dHh0KSA/ICcgdXJsJyA6ICcnKTsKICAgICAgICAgICAgc2V0SGxUZXh0KHByZXYsIHR4dCk7Cgog
ICAgICAgICAgICBjb25zdCBtZXRhID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnZGl2Jyk7CiAg
ICAgICAgICAgIG1ldGEuY2xhc3NOYW1lID0gJ2ktbWV0YSc7CgogICAgICAgICAgICBjb25zdCBj
aGFycyA9IE51bWJlcihjLmNoYXJDb3VudCkgfHwgMDsKICAgICAgICAgICAgY29uc3QgcmlnaHRI
VE1MID0gYDxzcGFuIGNsYXNzPSJpLWNoYXJzIj48c3BhbiBjbGFzcz0ibiI+JHtjaGFyc308L3Nw
YW4+IOWtl+espjwvc3Bhbj5gOwoKICAgICAgICAgICAgbWV0YS5pbm5lckhUTUwgPQogICAgICAg
ICAgICAgICAgYDxzcGFuIGNsYXNzPSJpLXRpbWUiPiR7YWdvKGMudGltZSl9PC9zcGFuPmAgKwog
ICAgICAgICAgICAgICAgbWV0YUNlbnRlckh0bWwoewogICAgICAgICAgICAgICAgICAgIG9uOiBm
YWxzZSwKICAgICAgICAgICAgICAgICAgICBodG1sOiBleHBhbmRDaGV2cm9uKGZhbHNlKQogICAg
ICAgICAgICAgICAgfSkgKwogICAgICAgICAgICAgICAgYDxkaXYgY2xhc3M9ImktbWV0YS1yaWdo
dCB0ZXh0LW1ldGEiPiR7cmlnaHRIVE1MfTwvZGl2PmA7CgogICAgICAgICAgICBib2R5LmFwcGVu
ZENoaWxkKHByZXYpOwogICAgICAgICAgICBib2R5LmFwcGVuZENoaWxkKG1ldGEpOwoKICAgICAg
ICAgICAgY29uc3QgZXhwQnRuID0gbWV0YS5xdWVyeVNlbGVjdG9yKCcuaS1leHBhbmQtYnRuJyk7
CiAgICAgICAgICAgIGlmIChleHBCdG4pIHsKICAgICAgICAgICAgICAgIGV4cEJ0bi5vbmNsaWNr
ID0gZSA9PiB7CiAgICAgICAgICAgICAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAg
ICAgICAgICAgICAgICBjb25zdCB3aWxsRXhwYW5kID0gIXByZXYuY2xhc3NMaXN0LmNvbnRhaW5z
KCdleHBhbmRlZCcpOwogICAgICAgICAgICAgICAgICAgIGlmICh3aWxsRXhwYW5kKSB7CiAgICAg
ICAgICAgICAgICAgICAgICAgIGFwcGx5RXhwYW5kZWRQcmV2aWV3KHByZXYsIHR4dCk7CiAgICAg
ICAgICAgICAgICAgICAgICAgIGV4cEJ0bi5pbm5lckhUTUwgPSBleHBhbmRDaGV2cm9uKHRydWUp
OwogICAgICAgICAgICAgICAgICAgICAgICB0cnkgeyBlbC5zY3JvbGxJbnRvVmlldyh7IGJsb2Nr
OiAnbmVhcmVzdCcgfSk7IH0gY2F0Y2gge30KICAgICAgICAgICAgICAgICAgICB9IGVsc2Ugewog
ICAgICAgICAgICAgICAgICAgICAgICBjb2xsYXBzZVByZXZpZXcocHJldiwgdHh0KTsKICAgICAg
ICAgICAgICAgICAgICAgICAgZXhwQnRuLmlubmVySFRNTCA9IGV4cGFuZENoZXZyb24oZmFsc2Up
OwogICAgICAgICAgICAgICAgICAgIH0KICAgICAgICAgICAgICAgIH07CiAgICAgICAgICAgICAg
ICBjb25zdCBjaGVja092ZXJmbG93ID0gKCkgPT4gewogICAgICAgICAgICAgICAgICAgIGNvbnN0
IHBsYWluTGVuID0gU3RyaW5nKGMucHJldmlldyB8fCBjLmRhdGEgfHwgJycpLmxlbmd0aDsKICAg
ICAgICAgICAgICAgICAgICBjb25zdCBmdWxsTiA9IE51bWJlcihjLmNoYXJDb3VudCkgfHwgMDsK
ICAgICAgICAgICAgICAgICAgICBjb25zdCB0cnVuYyA9IGZ1bGxOID4gcGxhaW5MZW47CiAgICAg
ICAgICAgICAgICAgICAgaWYgKHByZXYuc2Nyb2xsSGVpZ2h0ID4gcHJldi5jbGllbnRIZWlnaHQg
KyAyIHx8IHRydW5jKQogICAgICAgICAgICAgICAgICAgICAgICBleHBCdG4uY2xhc3NMaXN0LmFk
ZCgnb24nKTsKICAgICAgICAgICAgICAgICAgICBlbHNlCiAgICAgICAgICAgICAgICAgICAgICAg
IGV4cEJ0bi5jbGFzc0xpc3QucmVtb3ZlKCdvbicpOwogICAgICAgICAgICAgICAgfTsKICAgICAg
ICAgICAgICAgIHJlcXVlc3RBbmltYXRpb25GcmFtZShjaGVja092ZXJmbG93KTsKICAgICAgICAg
ICAgICAgIHNldFRpbWVvdXQoY2hlY2tPdmVyZmxvdywgODApOwogICAgICAgICAgICB9CiAgICAg
ICAgfQoKICAgICAgICBjb25zdCBmYXZUID0gU3RyaW5nKGMuZmF2VGl0bGUgfHwgJycpLnRyaW0o
KTsKICAgICAgICBpZiAoZmF2VCkgewogICAgICAgICAgICBjb25zdCBmdCA9IGRvY3VtZW50LmNy
ZWF0ZUVsZW1lbnQoJ2RpdicpOwogICAgICAgICAgICBmdC5jbGFzc05hbWUgPSAnaS1mYXYtdGl0
bGUnICsgKHR5cGUgPT09ICdyZWNlbnQnID8gJyByZi10aXRsZScgOiAnJyk7CiAgICAgICAgICAg
IHNldEhsVGV4dChmdCwgZmF2VCk7CiAgICAgICAgICAgIGJvZHkuaW5zZXJ0QmVmb3JlKGZ0LCBi
b2R5LmZpcnN0Q2hpbGQpOwogICAgICAgIH0KCiAgICAgICAgaWYgKHBhc3RlZCkgewogICAgICAg
ICAgICBlbC5jbGFzc0xpc3QuYWRkKCdwYXN0ZWQnKTsKICAgICAgICAgICAgY29uc3QgYmFkZ2Ug
PSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdzcGFuJyk7CiAgICAgICAgICAgIGJhZGdlLmNsYXNz
TmFtZSA9ICdpLXVzZWQnOwogICAgICAgICAgICBiYWRnZS50aXRsZSA9ICflt7LnspjotLQnOwog
ICAgICAgICAgICBiYWRnZS5pbm5lckhUTUwgPSBgPHN2ZyB2aWV3Qm94PSIwIDAgMTYgMTYiIGZp
bGw9Im5vbmUiIHN0cm9rZT0iY3VycmVudENvbG9yIiBzdHJva2Utd2lkdGg9IjIuNCIgc3Ryb2tl
LWxpbmVjYXA9InJvdW5kIiBzdHJva2UtbGluZWpvaW49InJvdW5kIj48cG9seWxpbmUgcG9pbnRz
PSIzLjUgOC41IDYuNSAxMS41IDEyLjUgNC41Ii8+PC9zdmc+YDsKICAgICAgICAgICAgaWNvLmFw
cGVuZENoaWxkKGJhZGdlKTsKICAgICAgICB9CgogICAgICAgIGNvbnN0IG51bSA9IGRvY3VtZW50
LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOwogICAgICAgIG51bS5jbGFzc05hbWUgPSAnaS1udW0nOwog
ICAgICAgIGNvbnN0IG51bVR4dCA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ3NwYW4nKTsKICAg
ICAgICBudW1UeHQudGV4dENvbnRlbnQgPSBpZHg7CiAgICAgICAgbnVtLmFwcGVuZENoaWxkKG51
bVR4dCk7CiAgICAgICAgY29uc3Qgc3JjSWNvID0gU3RyaW5nKGMuc3JjSWNvbiB8fCAnJyk7CiAg
ICAgICAgY29uc3Qgc3JjRXhlID0gU3RyaW5nKGMuc3JjRXhlIHx8ICcnKTsKICAgICAgICBjb25z
dCBzcmNUaXRsZSA9IFN0cmluZyhjLnNyY1RpdGxlIHx8ICcnKTsKICAgICAgICBpZiAoc3JjSWNv
KSB7CiAgICAgICAgICAgIGNvbnN0IGltZyA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2ltZycp
OwogICAgICAgICAgICBpbWcuY2xhc3NOYW1lID0gJ2ktc3JjLWljbyc7CiAgICAgICAgICAgIGlt
Zy5zcmMgPSBTVE9SRV9CQVNFICsgZW5jb2RlVVJJQ29tcG9uZW50KHNyY0ljbyk7CiAgICAgICAg
ICAgIGltZy5hbHQgPSAnJzsKICAgICAgICAgICAgY29uc3QgdGlwVHh0ID0gc3JjVGl0bGUgfHwg
c3JjRXhlIHx8ICfmnaXmupAnOwogICAgICAgICAgICBpbWcudGl0bGUgPSB0aXBUeHQ7CiAgICAg
ICAgICAgIGltZy5vbmNsaWNrID0gZSA9PiB7IGUucHJldmVudERlZmF1bHQoKTsgZS5zdG9wUHJv
cGFnYXRpb24oKTsgc2hvd1NyY1RpcChpbWcsIHRpcFR4dCk7IH07CiAgICAgICAgICAgIG51bS5h
cHBlbmRDaGlsZChpbWcpOwogICAgICAgIH0KCiAgICAgICAgZWwuYXBwZW5kQ2hpbGQoaWNvKTsK
ICAgICAgICBlbC5hcHBlbmRDaGlsZChib2R5KTsKICAgICAgICBlbC5hcHBlbmRDaGlsZChudW0p
OwoKICAgICAgICBlbC5vbnBvaW50ZXJkb3duID0gZSA9PiB7CiAgICAgICAgICAgIGJlZ2luUGFz
dGVGcm9tSXRlbShlLCBjKTsKICAgICAgICB9OwogICAgICAgIGVsLm9uY29udGV4dG1lbnUgPSBl
ID0+IHsKICAgICAgICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOwogICAgICAgICAgICBzZWxlY3Rl
ZElkID0gYy5pZDsKICAgICAgICAgICAgc2hvd0N0eChlLmNsaWVudFgsIGUuY2xpZW50WSwgYyk7
CiAgICAgICAgfTsKCiAgICAgICAgcmV0dXJuIGVsOwogICAgfQoKICAgIGZ1bmN0aW9uIGl0ZW1J
c1F1ZXVlRG9uZShyb3cpIHsKICAgICAgICBpZiAoIXJvdykgcmV0dXJuIGZhbHNlOwogICAgICAg
IGlmIChyb3cuY2xhc3NMaXN0LmNvbnRhaW5zKCdwYXN0ZWQnKSB8fCByb3cuY2xhc3NMaXN0LmNv
bnRhaW5zKCdxLWRvbmUnKSkKICAgICAgICAgICAgcmV0dXJuIHRydWU7CiAgICAgICAgY29uc3Qg
aWQgPSArcm93LmRhdGFzZXQuaWQ7CiAgICAgICAgY29uc3QgYyA9IGFsbENsaXBzLmZpbmQoeCA9
PiAreC5pZCA9PT0gaWQpOwogICAgICAgIHJldHVybiAhIShjICYmIGlzUGFzdGVkKGMpKTsKICAg
IH0KCiAgICBmdW5jdGlvbiBtYXJrUXVldWVSYWlscygpIHsKICAgICAgICBpZiAoIWxpc3RFbCkg
cmV0dXJuOwogICAgICAgIGNvbnN0IG5vZGVzID0gWy4uLmxpc3RFbC5xdWVyeVNlbGVjdG9yQWxs
KCcuaXRtLnEtbWVtYmVyJyldOwogICAgICAgIG5vZGVzLmZvckVhY2gobiA9PiBuLmNsYXNzTGlz
dC5yZW1vdmUoJ3EtZmlyc3QnLCAncS1sYXN0JywgJ3Etb25seScsICdxLWRvbmUtbGluaycsICdx
LXBhc3RlZC1uZXh0JykpOwogICAgICAgIGlmICghbm9kZXMubGVuZ3RoKSByZXR1cm47CiAgICAg
ICAgLy8gT25seSB2aXN1YWxseSBhZGphY2VudCByb3dzIChzYW1lIGdyb3VwKS4gU2tpcCBnYXBz
IOKAlCBxdWVyeVNlbGVjdG9yQWxsIHdvdWxkIGdsdWUgdGhlbS4KICAgICAgICBjb25zdCByb3dz
ID0gWy4uLmxpc3RFbC5jaGlsZHJlbl0uZmlsdGVyKG4gPT4gbi5jbGFzc0xpc3QgJiYgbi5jbGFz
c0xpc3QuY29udGFpbnMoJ2l0bScpKTsKICAgICAgICBjb25zdCBydW5zID0gW107CiAgICAgICAg
bGV0IHJ1biA9IFtdOwogICAgICAgIGNvbnN0IGZsdXNoID0gKCkgPT4geyBpZiAocnVuLmxlbmd0
aCkgeyBydW5zLnB1c2gocnVuKTsgcnVuID0gW107IH0gfTsKICAgICAgICBmb3IgKGxldCByID0g
MDsgciA8IHJvd3MubGVuZ3RoOyByKyspIHsKICAgICAgICAgICAgY29uc3QgbiA9IHJvd3Nbcl07
CiAgICAgICAgICAgIGlmICghbi5jbGFzc0xpc3QuY29udGFpbnMoJ3EtbWVtYmVyJykpIHsgZmx1
c2goKTsgY29udGludWU7IH0KICAgICAgICAgICAgY29uc3QgZyA9IG4uZGF0YXNldC5xZyB8fCAn
JzsKICAgICAgICAgICAgaWYgKCFydW4ubGVuZ3RoIHx8IHJ1blswXS5kYXRhc2V0LnFnID09PSBn
KQogICAgICAgICAgICAgICAgcnVuLnB1c2gobik7CiAgICAgICAgICAgIGVsc2UgewogICAgICAg
ICAgICAgICAgZmx1c2goKTsKICAgICAgICAgICAgICAgIHJ1bi5wdXNoKG4pOwogICAgICAgICAg
ICB9CiAgICAgICAgfQogICAgICAgIGZsdXNoKCk7CiAgICAgICAgZm9yIChjb25zdCBzbGljZSBv
ZiBydW5zKSB7CiAgICAgICAgICAgIGlmIChzbGljZS5sZW5ndGggPT09IDEpIHsKICAgICAgICAg
ICAgICAgIHNsaWNlWzBdLmNsYXNzTGlzdC5hZGQoJ3Etb25seScpOwogICAgICAgICAgICB9IGVs
c2UgewogICAgICAgICAgICAgICAgc2xpY2VbMF0uY2xhc3NMaXN0LmFkZCgncS1maXJzdCcpOwog
ICAgICAgICAgICAgICAgc2xpY2Vbc2xpY2UubGVuZ3RoIC0gMV0uY2xhc3NMaXN0LmFkZCgncS1s
YXN0Jyk7CiAgICAgICAgICAgIH0KICAgICAgICAgICAgZm9yIChsZXQgayA9IDA7IGsgPCBzbGlj
ZS5sZW5ndGg7IGsrKykgewogICAgICAgICAgICAgICAgY29uc3QgZG9uZSA9IGl0ZW1Jc1F1ZXVl
RG9uZShzbGljZVtrXSk7CiAgICAgICAgICAgICAgICBzbGljZVtrXS5jbGFzc0xpc3QudG9nZ2xl
KCdxLWRvbmUnLCBkb25lKTsKICAgICAgICAgICAgICAgIGNvbnN0IGRvdCA9IHNsaWNlW2tdLnF1
ZXJ5U2VsZWN0b3IoJy5xLWRvdCcpOwogICAgICAgICAgICAgICAgaWYgKGRvdCkgZG90LnRpdGxl
ID0gZG9uZSA/ICfpmJ/liJflt7LnspjotLQnIDogJ+eymOi0tOmYn+WIlyc7CiAgICAgICAgICAg
ICAgICAvLyBHcmVlbiByYWlsIGZvciBldmVyeSBpdGVtIGluIGEgMisgZGVxdWV1ZWQgcnVuIChp
bmNsLiBmaXJzdC9sYXN0IHN0dWJzKQogICAgICAgICAgICAgICAgY29uc3QgcHJldkRvbmUgPSBr
ID4gMCAmJiBpdGVtSXNRdWV1ZURvbmUoc2xpY2VbayAtIDFdKTsKICAgICAgICAgICAgICAgIGNv
bnN0IG5leHREb25lID0gayA8IHNsaWNlLmxlbmd0aCAtIDEgJiYgaXRlbUlzUXVldWVEb25lKHNs
aWNlW2sgKyAxXSk7CiAgICAgICAgICAgICAgICBpZiAoZG9uZSAmJiAocHJldkRvbmUgfHwgbmV4
dERvbmUpKQogICAgICAgICAgICAgICAgICAgIHNsaWNlW2tdLmNsYXNzTGlzdC5hZGQoJ3EtZG9u
ZS1saW5rJyk7CiAgICAgICAgICAgIH0KICAgICAgICB9CiAgICB9CgogICAgY29uc3QgcGF0aFRp
cEVsID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3BhdGgtdGlwJyk7CiAgICBsZXQgcGF0aFRp
cFRpbWVyID0gMDsKICAgIGxldCBwYXRoVGlwSGlkZVRpbWVyID0gMDsKICAgIGxldCBwYXRoVGlw
VG9rZW4gPSAwOwogICAgbGV0IHBhdGhUaXBBbmNob3JCdG4gPSBudWxsOwoKICAgIGZ1bmN0aW9u
IGhpZGVQYXRoVGlwKCkgewogICAgICAgIGNsZWFyVGltZW91dChwYXRoVGlwVGltZXIpOwogICAg
ICAgIGNsZWFyVGltZW91dChwYXRoVGlwSGlkZVRpbWVyKTsKICAgICAgICBwYXRoVGlwVG9rZW4r
KzsKICAgICAgICBpZiAocGF0aFRpcEFuY2hvckJ0bikgewogICAgICAgICAgICBwYXRoVGlwQW5j
aG9yQnRuLmNsYXNzTGlzdC5yZW1vdmUoJ29uJyk7CiAgICAgICAgICAgIHBhdGhUaXBBbmNob3JC
dG4gPSBudWxsOwogICAgICAgIH0KICAgICAgICBpZiAocGF0aFRpcEVsKSB7CiAgICAgICAgICAg
IHBhdGhUaXBFbC5jbGFzc0xpc3QucmVtb3ZlKCdvbicpOwogICAgICAgICAgICBwYXRoVGlwRWwu
c2V0QXR0cmlidXRlKCdhcmlhLWhpZGRlbicsICd0cnVlJyk7CiAgICAgICAgfQogICAgfQogICAg
ZnVuY3Rpb24gcGxhY2VQYXRoVGlwKGFuY2hvckVsKSB7CiAgICAgICAgaWYgKCFwYXRoVGlwRWwg
fHwgIWFuY2hvckVsKSByZXR1cm47CiAgICAgICAgY29uc3QgdGlwID0gcGF0aFRpcEVsOwogICAg
ICAgIGNvbnN0IGFyID0gYW5jaG9yRWwuZ2V0Qm91bmRpbmdDbGllbnRSZWN0KCk7CiAgICAgICAg
Y29uc3QgcGFkID0gODsKICAgICAgICB0aXAuc3R5bGUubGVmdCA9ICcwcHgnOwogICAgICAgIHRp
cC5zdHlsZS50b3AgPSAnMHB4JzsKICAgICAgICB0aXAuY2xhc3NMaXN0LmFkZCgnb24nKTsKICAg
ICAgICBjb25zdCB0dyA9IHRpcC5vZmZzZXRXaWR0aDsKICAgICAgICBjb25zdCB0aCA9IHRpcC5v
ZmZzZXRIZWlnaHQ7CiAgICAgICAgbGV0IGxlZnQgPSBhci5sZWZ0OwogICAgICAgIGxldCB0b3Ag
PSBhci5ib3R0b20gKyA2OwogICAgICAgIGlmIChsZWZ0ICsgdHcgPiB3aW5kb3cuaW5uZXJXaWR0
aCAtIHBhZCkKICAgICAgICAgICAgbGVmdCA9IE1hdGgubWF4KHBhZCwgd2luZG93LmlubmVyV2lk
dGggLSB0dyAtIHBhZCk7CiAgICAgICAgaWYgKGxlZnQgPCBwYWQpIGxlZnQgPSBwYWQ7CiAgICAg
ICAgaWYgKHRvcCArIHRoID4gd2luZG93LmlubmVySGVpZ2h0IC0gcGFkKQogICAgICAgICAgICB0
b3AgPSBNYXRoLm1heChwYWQsIGFyLnRvcCAtIHRoIC0gNik7CiAgICAgICAgdGlwLnN0eWxlLmxl
ZnQgPSBsZWZ0ICsgJ3B4JzsKICAgICAgICB0aXAuc3R5bGUudG9wID0gdG9wICsgJ3B4JzsKICAg
IH0KICAgICAgICBmdW5jdGlvbiBjaGVja0ZpbGVQYXRocyhwYXRocykgewogICAgICAgIGNvbnN0
IGxpc3QgPSAocGF0aHMgfHwgW10pLm1hcChwID0+IHsKICAgICAgICAgICAgbGV0IHBhdGggPSBT
dHJpbmcocCB8fCAnJykudHJpbSgpOwogICAgICAgICAgICBpZiAoKHBhdGguc3RhcnRzV2l0aCgn
IicpICYmIHBhdGguZW5kc1dpdGgoJyInKSkgfHwgKHBhdGguc3RhcnRzV2l0aCgiJyIpICYmIHBh
dGguZW5kc1dpdGgoIiciKSkpCiAgICAgICAgICAgICAgICBwYXRoID0gcGF0aC5zbGljZSgxLCAt
MSkudHJpbSgpOwogICAgICAgICAgICByZXR1cm4gcGF0aDsKICAgICAgICB9KTsKICAgICAgICAv
LyBPbmUgaG9zdCByb3VuZC10cmlwIGZvciB0aGUgd2hvbGUgbGlzdCDigJQgTsOXIHBhdGhFeGlz
dHMgZnJlZXplcyBmaWxlIHRhYgogICAgICAgIHRyeSB7CiAgICAgICAgICAgIGNvbnN0IHJhdyA9
IGFoa1JldCgnY2hlY2tQYXRocycsIGxpc3Quam9pbignXG4nKSk7CiAgICAgICAgICAgIGlmIChy
YXcpIHsKICAgICAgICAgICAgICAgIGNvbnN0IHBhcnNlZCA9IHR5cGVvZiByYXcgPT09ICdzdHJp
bmcnID8gSlNPTi5wYXJzZShyYXcpIDogcmF3OwogICAgICAgICAgICAgICAgaWYgKEFycmF5Lmlz
QXJyYXkocGFyc2VkKSAmJiBwYXJzZWQubGVuZ3RoKSB7CiAgICAgICAgICAgICAgICAgICAgcmV0
dXJuIGxpc3QubWFwKChwYXRoLCBpKSA9PiB7CiAgICAgICAgICAgICAgICAgICAgICAgIGNvbnN0
IHJvdyA9IHBhcnNlZFtpXSB8fCB7fTsKICAgICAgICAgICAgICAgICAgICAgICAgcmV0dXJuIHsK
ICAgICAgICAgICAgICAgICAgICAgICAgICAgIHBhdGg6IHBhdGggfHwgU3RyaW5nKHJvdy5wYXRo
IHx8ICcnKSwKICAgICAgICAgICAgICAgICAgICAgICAgICAgIGV4aXN0czogcm93LmV4aXN0cyA9
PT0gdHJ1ZSB8fCByb3cuZXhpc3RzID09PSAxIHx8IHJvdy5leGlzdHMgPT09ICcxJywKICAgICAg
ICAgICAgICAgICAgICAgICAgICAgIGlzRGlyOiAhIShyb3cuaXNEaXIgPT09IHRydWUgfHwgcm93
LmlzRGlyID09PSAxIHx8IHJvdy5pc0RpciA9PT0gJzEnKQogICAgICAgICAgICAgICAgICAgICAg
ICB9OwogICAgICAgICAgICAgICAgICAgIH0pOwogICAgICAgICAgICAgICAgfQogICAgICAgICAg
ICB9CiAgICAgICAgfSBjYXRjaCB7fQogICAgICAgIHJldHVybiBsaXN0Lm1hcChwYXRoID0+IHsK
ICAgICAgICAgICAgaWYgKCFwYXRoKSByZXR1cm4geyBwYXRoLCBleGlzdHM6IGZhbHNlLCBpc0Rp
cjogZmFsc2UgfTsKICAgICAgICAgICAgbGV0IGV4aXN0cyA9IGZhbHNlOwogICAgICAgICAgICB0
cnkgewogICAgICAgICAgICAgICAgY29uc3QgZmxhZyA9IFN0cmluZyhhaGtSZXQoJ3BhdGhFeGlz
dHMnLCBwYXRoKSA/PyAnJykudHJpbSgpLnRvTG93ZXJDYXNlKCk7CiAgICAgICAgICAgICAgICBl
eGlzdHMgPSAoZmxhZyA9PT0gJzEnIHx8IGZsYWcgPT09ICd0cnVlJyk7CiAgICAgICAgICAgIH0g
Y2F0Y2gge30KICAgICAgICAgICAgcmV0dXJuIHsgcGF0aCwgZXhpc3RzLCBpc0RpcjogZmFsc2Ug
fTsKICAgICAgICB9KTsKICAgIH0KICAgIGxldCBnb25lQ2hlY2tUaW1lciA9IDA7CiAgICBmdW5j
dGlvbiBzY2hlZHVsZUZpbGVHb25lQ2hlY2soKSB7CiAgICAgICAgaWYgKGdvbmVDaGVja1RpbWVy
KSByZXR1cm47CiAgICAgICAgZ29uZUNoZWNrVGltZXIgPSBzZXRUaW1lb3V0KCgpID0+IHsKICAg
ICAgICAgICAgZ29uZUNoZWNrVGltZXIgPSAwOwogICAgICAgICAgICBjb25zdCBub2RlcyA9IFsu
Li5saXN0RWwucXVlcnlTZWxlY3RvckFsbCgnLml0bScpXS5maWx0ZXIobiA9PiBuLl9maWxlUGF0
aHMgJiYgbi5fZmlsZVBhdGhzLmxlbmd0aCk7CiAgICAgICAgICAgIGlmICghbm9kZXMubGVuZ3Ro
KSByZXR1cm47CiAgICAgICAgICAgIGNvbnN0IHVuaXF1ZSA9IFtdOwogICAgICAgICAgICBjb25z
dCBzZWVuID0gbmV3IFNldCgpOwogICAgICAgICAgICBub2Rlcy5mb3JFYWNoKG4gPT4gewogICAg
ICAgICAgICAgICAgbi5fZmlsZVBhdGhzLmZvckVhY2gocCA9PiB7CiAgICAgICAgICAgICAgICAg
ICAgY29uc3QgcGF0aCA9IFN0cmluZyhwIHx8ICcnKTsKICAgICAgICAgICAgICAgICAgICBpZiAo
IXBhdGggfHwgc2Vlbi5oYXMocGF0aCkpIHJldHVybjsKICAgICAgICAgICAgICAgICAgICBzZWVu
LmFkZChwYXRoKTsKICAgICAgICAgICAgICAgICAgICB1bmlxdWUucHVzaChwYXRoKTsKICAgICAg
ICAgICAgICAgIH0pOwogICAgICAgICAgICB9KTsKICAgICAgICAgICAgY29uc3Qgcm93cyA9IGNo
ZWNrRmlsZVBhdGhzKHVuaXF1ZSk7CiAgICAgICAgICAgIGNvbnN0IGJ5UGF0aCA9IG5ldyBNYXAo
KTsKICAgICAgICAgICAgcm93cy5mb3JFYWNoKHIgPT4gYnlQYXRoLnNldChTdHJpbmcoci5wYXRo
IHx8ICcnKSwgcikpOwogICAgICAgICAgICBub2Rlcy5mb3JFYWNoKG4gPT4gewogICAgICAgICAg
ICAgICAgY29uc3QgcGF0aFJvd3MgPSBuLl9maWxlUGF0aHMubWFwKHAgPT4gewogICAgICAgICAg
ICAgICAgICAgIGNvbnN0IGhpdCA9IGJ5UGF0aC5nZXQoU3RyaW5nKHAgfHwgJycpKTsKICAgICAg
ICAgICAgICAgICAgICByZXR1cm4gaGl0IHx8IHsgcGF0aDogcCwgZXhpc3RzOiB0cnVlLCBpc0Rp
cjogZmFsc2UgfTsKICAgICAgICAgICAgICAgIH0pOwogICAgICAgICAgICAgICAgbi5fcGF0aFJv
d3MgPSBwYXRoUm93czsKICAgICAgICAgICAgICAgIGNvbnN0IGFsbEdvbmUgPSBwYXRoUm93cy5s
ZW5ndGggPiAwICYmIHBhdGhSb3dzLmV2ZXJ5KHIgPT4gci5leGlzdHMgPT09IGZhbHNlKTsKICAg
ICAgICAgICAgICAgIG4uY2xhc3NMaXN0LnRvZ2dsZSgnZ29uZScsIGFsbEdvbmUpOwogICAgICAg
ICAgICB9KTsKICAgICAgICB9LCA0MDApOwogICAgfQogICAgZnVuY3Rpb24gZmlsbEZpbGVEZXRh
aWxQYW5lbChjb250YWluZXIsIHJvd3MpIHsKICAgICAgICBjb250YWluZXIuaW5uZXJIVE1MID0g
Jyc7CiAgICAgICAgaWYgKCFyb3dzLmxlbmd0aCkgewogICAgICAgICAgICBjb25zdCBlbXB0eSA9
IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOwogICAgICAgICAgICBlbXB0eS5jbGFzc05h
bWUgPSAnZmQtcGF0aCc7CiAgICAgICAgICAgIGVtcHR5LnRleHRDb250ZW50ID0gJ+aXoOi3r+W+
hCc7CiAgICAgICAgICAgIGNvbnRhaW5lci5hcHBlbmRDaGlsZChlbXB0eSk7CiAgICAgICAgICAg
IHJldHVybjsKICAgICAgICB9CiAgICAgICAgcm93cy5mb3JFYWNoKHIgPT4gewogICAgICAgICAg
ICBjb25zdCBwYXRoID0gU3RyaW5nKHIucGF0aCB8fCAnJyk7CiAgICAgICAgICAgIGNvbnN0IG1p
c3NpbmcgPSByLmV4aXN0cyA9PT0gZmFsc2U7CiAgICAgICAgICAgIGNvbnN0IGJsb2NrID0gZG9j
dW1lbnQuY3JlYXRlRWxlbWVudCgnZGl2Jyk7CiAgICAgICAgICAgIGJsb2NrLmNsYXNzTmFtZSA9
ICdmZC1ibG9jayc7CgogICAgICAgICAgICBjb25zdCBwYXRoRWwgPSBkb2N1bWVudC5jcmVhdGVF
bGVtZW50KCdkaXYnKTsKICAgICAgICAgICAgcGF0aEVsLmNsYXNzTmFtZSA9ICdmZC1wYXRoJyAr
IChtaXNzaW5nID8gJyBkZWFkJyA6ICcgbGl2ZScpOwogICAgICAgICAgICBwYXRoRWwudGV4dENv
bnRlbnQgPSBwYXRoIHx8ICco56m66Lev5b6EKSc7CiAgICAgICAgICAgIGlmICghbWlzc2luZykg
ewogICAgICAgICAgICAgICAgcGF0aEVsLm9uY2xpY2sgPSBlID0+IHsKICAgICAgICAgICAgICAg
ICAgICBlLnByZXZlbnREZWZhdWx0KCk7CiAgICAgICAgICAgICAgICAgICAgZS5zdG9wUHJvcGFn
YXRpb24oKTsKICAgICAgICAgICAgICAgICAgICBhaGsoJ29wZW5QYXRoJywgcGF0aCk7CiAgICAg
ICAgICAgICAgICB9OwogICAgICAgICAgICB9CiAgICAgICAgICAgIGJsb2NrLmFwcGVuZENoaWxk
KHBhdGhFbCk7CgogICAgICAgICAgICBjb25zdCBhY3Rpb25zID0gZG9jdW1lbnQuY3JlYXRlRWxl
bWVudCgnZGl2Jyk7CiAgICAgICAgICAgIGFjdGlvbnMuY2xhc3NOYW1lID0gJ2ZkLWFjdGlvbnMn
OwoKICAgICAgICAgICAgY29uc3QgY29weUJ0biA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2J1
dHRvbicpOwogICAgICAgICAgICBjb3B5QnRuLnR5cGUgPSAnYnV0dG9uJzsKICAgICAgICAgICAg
Y29weUJ0bi5jbGFzc05hbWUgPSAnZmQtYnRuJzsKICAgICAgICAgICAgY29weUJ0bi5pbm5lckhU
TUwgPSAnPHNwYW4gY2xhc3M9ImZkLWljbyI+8J+Ulzwvc3Bhbj48c3BhbiBjbGFzcz0iZmQtdHh0
Ij7lpI3liLbot6/lvoQ8L3NwYW4+JzsKICAgICAgICAgICAgY29weUJ0bi5vbmNsaWNrID0gZSA9
PiB7CiAgICAgICAgICAgICAgICBlLnByZXZlbnREZWZhdWx0KCk7CiAgICAgICAgICAgICAgICBl
LnN0b3BQcm9wYWdhdGlvbigpOwogICAgICAgICAgICAgICAgYWhrKCdjb3B5UGF0aCcsIHBhdGgp
OwogICAgICAgICAgICAgICAgY29weUJ0bi5xdWVyeVNlbGVjdG9yKCcuZmQtdHh0JykudGV4dENv
bnRlbnQgPSAn5bey5aSN5Yi2JzsKICAgICAgICAgICAgICAgIGNvcHlCdG4uY2xhc3NMaXN0LmFk
ZCgnb2snKTsKICAgICAgICAgICAgICAgIHNldFRpbWVvdXQoKCkgPT4gewogICAgICAgICAgICAg
ICAgICAgIGNvcHlCdG4ucXVlcnlTZWxlY3RvcignLmZkLXR4dCcpLnRleHRDb250ZW50ID0gJ+Wk
jeWItui3r+W+hCc7CiAgICAgICAgICAgICAgICAgICAgY29weUJ0bi5jbGFzc0xpc3QucmVtb3Zl
KCdvaycpOwogICAgICAgICAgICAgICAgfSwgMTIwMCk7CiAgICAgICAgICAgIH07CiAgICAgICAg
ICAgIGFjdGlvbnMuYXBwZW5kQ2hpbGQoY29weUJ0bik7CgogICAgICAgICAgICBjb25zdCBmb2xk
ZXJCdG4gPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdidXR0b24nKTsKICAgICAgICAgICAgZm9s
ZGVyQnRuLnR5cGUgPSAnYnV0dG9uJzsKICAgICAgICAgICAgZm9sZGVyQnRuLmNsYXNzTmFtZSA9
ICdmZC1idG4nOwogICAgICAgICAgICBmb2xkZXJCdG4uaW5uZXJIVE1MID0gJzxzcGFuIGNsYXNz
PSJmZC1pY28iPvCfk4I8L3NwYW4+PHNwYW4gY2xhc3M9ImZkLXR4dCI+5omT5byA5omA5Zyo5paH
5Lu25aS5PC9zcGFuPic7CiAgICAgICAgICAgIGZvbGRlckJ0bi5vbmNsaWNrID0gZSA9PiB7CiAg
ICAgICAgICAgICAgICBlLnByZXZlbnREZWZhdWx0KCk7CiAgICAgICAgICAgICAgICBlLnN0b3BQ
cm9wYWdhdGlvbigpOwogICAgICAgICAgICAgICAgYWhrKCdvcGVuRm9sZGVyJywgcGF0aCk7CiAg
ICAgICAgICAgIH07CiAgICAgICAgICAgIGFjdGlvbnMuYXBwZW5kQ2hpbGQoZm9sZGVyQnRuKTsK
CiAgICAgICAgICAgIGJsb2NrLmFwcGVuZENoaWxkKGFjdGlvbnMpOwogICAgICAgICAgICBjb250
YWluZXIuYXBwZW5kQ2hpbGQoYmxvY2spOwogICAgICAgIH0pOwogICAgfQoKICAgIGNvbnN0IGN0
eEVsID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2N0eCcpOwogICAgZnVuY3Rpb24gc2hvd0N0
eCh4LCB5LCBjKSB7CiAgICAgICAgY3R4Q2xpcCA9IGM7CiAgICAgICAgc2VsZWN0ZWRJZCA9IGMu
aWQ7CiAgICAgICAgcmFuZ2VBbmNob3JJZCA9IGMuaWQ7CiAgICAgICAgcmFuZ2VBbmNob3JDbGlj
a2VkID0gdHJ1ZTsKICAgICAgICBjb25zdCBjbGVhckJ0biA9IGRvY3VtZW50LmdldEVsZW1lbnRC
eUlkKCdjLWNsZWFyLXBhc3RlZCcpOwogICAgICAgIGlmIChjbGVhckJ0bikgY2xlYXJCdG4uc3R5
bGUuZGlzcGxheSA9IGlzUGFzdGVkKGMpID8gJycgOiAnbm9uZSc7CiAgICAgICAgY29uc3QgcGlu
QnRuID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2MtcGluJyk7CiAgICAgICAgY29uc3QgY29w
eUJ0biA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjLWNvcHknKTsKICAgICAgICBjb25zdCBp
c1JlY2VudCA9IG5vcm1UeXBlKGMudHlwZSkgPT09ICdyZWNlbnQnIHx8IGN1clRhYiA9PT0gJ3Jl
Y2VudCc7CgogICAgICAgIGNvbnN0IG11bHRpU2VsID0gbXVsdGlJZHMubGVuZ3RoID49IDEgJiYg
bXVsdGlJZHMuaW5jbHVkZXMoK2MuaWQpOwogICAgICAgIGNvbnN0IHF1ZXVlSWRzID0gbXVsdGlT
ZWwgPyBtdWx0aUlkcy5zbGljZSgpIDogWytjLmlkXTsKICAgICAgICBjb25zdCBxdWV1ZWRPZiA9
IGlkID0+IHsKICAgICAgICAgICAgY29uc3QgaXQgPSAoK2lkID09PSArYy5pZCkgPyBjIDogYWxs
Q2xpcHMuZmluZCh4ID0+ICt4LmlkID09PSAraWQpOwogICAgICAgICAgICByZXR1cm4gISEoaXQg
JiYgTnVtYmVyKGl0LnF1ZXVlR3JvdXApID4gMCk7CiAgICAgICAgfTsKICAgICAgICAvLyDlhajp
g6jlt7LlnKjpmJ/liJcg4oaSIOWPquaYvuekuuenu+WHuu+8m+WQpuWIme+8iOWQq+a3t+mAie+8
ieWPquaYvuekuuWKoOWFpeOAguS4pOiAheS6kuaWpeOAggogICAgICAgIGNvbnN0IGFsbFF1ZXVl
ZCA9IHF1ZXVlSWRzLmxlbmd0aCA+IDAgJiYgcXVldWVJZHMuZXZlcnkocXVldWVkT2YpOwogICAg
ICAgIGNvbnN0IHFGcm9tID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2MtcXVldWUtZnJvbScp
OwogICAgICAgIGlmIChxRnJvbSkKICAgICAgICAgICAgcUZyb20uc3R5bGUuZGlzcGxheSA9ICgh
aXNSZWNlbnQgJiYgYWxsUXVldWVkICYmIE51bWJlcihjLnF1ZXVlR3JvdXApID4gMCkgPyAnJyA6
ICdub25lJzsKICAgICAgICBjb25zdCBxSW4gPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYy1x
dWV1ZS1pbicpOwogICAgICAgIGlmIChxSW4pIHsKICAgICAgICAgICAgY29uc3Qgc2hvd0luID0g
IWlzUmVjZW50ICYmICFhbGxRdWV1ZWQ7CiAgICAgICAgICAgIHFJbi5zdHlsZS5kaXNwbGF5ID0g
c2hvd0luID8gJycgOiAnbm9uZSc7CiAgICAgICAgICAgIGlmIChzaG93SW4pIHsKICAgICAgICAg
ICAgICAgIGNvbnN0IG4gPSBxdWV1ZUlkcy5sZW5ndGg7CiAgICAgICAgICAgICAgICBxSW4uaW5u
ZXJIVE1MID0gbiA+IDEKICAgICAgICAgICAgICAgICAgICA/ICgnPHNwYW4gY2xhc3M9ImMtaWNv
Ij7ih4k8L3NwYW4+5Yqg5YWl57KY6LS06Zif5YiXICgnICsgbiArICcpJykKICAgICAgICAgICAg
ICAgICAgICA6ICc8c3BhbiBjbGFzcz0iYy1pY28iPuKHiTwvc3Bhbj7liqDlhaXnspjotLTpmJ/l
iJcnOwogICAgICAgICAgICB9CiAgICAgICAgfQogICAgICAgIGNvbnN0IHFPdXQgPSBkb2N1bWVu
dC5nZXRFbGVtZW50QnlJZCgnYy1xdWV1ZS1vdXQnKTsKICAgICAgICBpZiAocU91dCkgewogICAg
ICAgICAgICBjb25zdCBzaG93T3V0ID0gIWlzUmVjZW50ICYmIGFsbFF1ZXVlZDsKICAgICAgICAg
ICAgcU91dC5zdHlsZS5kaXNwbGF5ID0gc2hvd091dCA/ICcnIDogJ25vbmUnOwogICAgICAgICAg
ICBpZiAoc2hvd091dCkgewogICAgICAgICAgICAgICAgY29uc3QgbiA9IHF1ZXVlSWRzLmxlbmd0
aDsKICAgICAgICAgICAgICAgIHFPdXQuaW5uZXJIVE1MID0gbiA+IDEKICAgICAgICAgICAgICAg
ICAgICA/ICgnPHNwYW4gY2xhc3M9ImMtaWNvIj7ih4c8L3NwYW4+56e75Ye657KY6LS06Zif5YiX
ICgnICsgbiArICcpJykKICAgICAgICAgICAgICAgICAgICA6ICc8c3BhbiBjbGFzcz0iYy1pY28i
PuKHhzwvc3Bhbj7np7vlh7rnspjotLTpmJ/liJcnOwogICAgICAgICAgICB9CiAgICAgICAgfQoK
ICAgICAgICBpZiAoY29weUJ0bikgewogICAgICAgICAgICBjb3B5QnRuLmlubmVySFRNTCA9IGlz
UmVjZW50CiAgICAgICAgICAgICAgICA/ICc8c3BhbiBjbGFzcz0iYy1pY28iPvCflJc8L3NwYW4+
5aSN5Yi26Lev5b6EJwogICAgICAgICAgICAgICAgOiAnPHNwYW4gY2xhc3M9ImMtaWNvIj7ijpg8
L3NwYW4+5aSN5Yi2JzsKICAgICAgICAgICAgY29weUJ0bi5zdHlsZS5kaXNwbGF5ID0gJyc7CiAg
ICAgICAgfQogICAgICAgIGlmIChwaW5CdG4pIHsKICAgICAgICAgICAgaWYgKGlzUmVjZW50KSB7
CiAgICAgICAgICAgICAgICAvLyBSZWNlbnQgZm9sZGVyczogcGluID0ga2VlcCBwYXRoIChub3Qg
Y2xpcGJvYXJkIOaUtuiXjykKICAgICAgICAgICAgICAgIHBpbkJ0bi5zdHlsZS5kaXNwbGF5ID0g
Jyc7CiAgICAgICAgICAgICAgICBjb25zdCBvbiA9IGlzUGlubmVkKGMpOwogICAgICAgICAgICAg
ICAgcGluQnRuLmlubmVySFRNTCA9IG9uCiAgICAgICAgICAgICAgICAgICAgPyAnPHNwYW4gY2xh
c3M9ImMtaWNvIj7imIU8L3NwYW4+5Y+W5raI5Zu65a6aJwogICAgICAgICAgICAgICAgICAgIDog
JzxzcGFuIGNsYXNzPSJjLWljbyI+4piFPC9zcGFuPuWbuuWumui3r+W+hCc7CiAgICAgICAgICAg
IH0gZWxzZSB7CiAgICAgICAgICAgICAgICBwaW5CdG4uc3R5bGUuZGlzcGxheSA9ICcnOwogICAg
ICAgICAgICAgICAgY29uc3Qgb24gPSBpc1Bpbm5lZChjKTsKICAgICAgICAgICAgICAgIHBpbkJ0
bi5pbm5lckhUTUwgPSBvbgogICAgICAgICAgICAgICAgICAgID8gJzxzcGFuIGNsYXNzPSJjLWlj
byI+4piFPC9zcGFuPuWPlua2iOaUtuiXjycKICAgICAgICAgICAgICAgICAgICA6ICc8c3BhbiBj
bGFzcz0iYy1pY28iPuKYhTwvc3Bhbj7mlLbol48nOwogICAgICAgICAgICB9CiAgICAgICAgfQog
ICAgICAgIGNvbnN0IHRpdGxlQnRuID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2MtdGl0bGUn
KTsKICAgICAgICBpZiAodGl0bGVCdG4pIHsKICAgICAgICAgICAgLy8g5pyA6L+R6Lev5b6E5Lmf
5Y+v6K6+5qCH6aKY77yI5Y+C5LiO5pCc57Si77yJ77yb5pS26JeP6aG1L+W3suaUtuiXj+adoeeb
ruWQjOWJjQogICAgICAgICAgICBjb25zdCBzaG93VGl0bGUgPSBpc1JlY2VudCB8fCBpc1Bpbm5l
ZChjKSB8fCBjdXJUYWIgPT09ICdwaW5uZWQnOwogICAgICAgICAgICB0aXRsZUJ0bi5zdHlsZS5k
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
Y29uc3QgcUluMiA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjLXF1ZXVlLWluJyk7CiAgICAg
ICAgaWYgKHFJbjIgJiYgaXNSZWNlbnQpCiAgICAgICAgICAgIHFJbjIuc3R5bGUuZGlzcGxheSA9
ICdub25lJzsKICAgICAgICBjb25zdCBxT3V0MiA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdj
LXF1ZXVlLW91dCcpOwogICAgICAgIGlmIChxT3V0MiAmJiBpc1JlY2VudCkKICAgICAgICAgICAg
cU91dDIuc3R5bGUuZGlzcGxheSA9ICdub25lJzsKICAgICAgICBjb25zdCBkZWxCdG4gPSBkb2N1
bWVudC5nZXRFbGVtZW50QnlJZCgnYy1kZWwnKTsKICAgICAgICBpZiAoZGVsQnRuKSB7CiAgICAg
ICAgICAgIGNvbnN0IG11bHRpRGVsID0gbXVsdGlJZHMubGVuZ3RoID4gMSAmJiBtdWx0aUlkcy5p
bmNsdWRlcygrYy5pZCk7CiAgICAgICAgICAgIGNvbnN0IG4gPSBtdWx0aURlbCA/IG11bHRpSWRz
Lmxlbmd0aCA6IDE7CiAgICAgICAgICAgIGRlbEJ0bi5pbm5lckhUTUwgPSBuID4gMQogICAgICAg
ICAgICAgICAgPyAoJzxzcGFuIGNsYXNzPSJjLWljbyI+4pyVPC9zcGFuPuWIoOmZpCAoJyArIG4g
KyAnKScpCiAgICAgICAgICAgICAgICA6ICc8c3BhbiBjbGFzcz0iYy1pY28iPuKclTwvc3Bhbj7l
iKDpmaQnOwogICAgICAgIH0KICAgICAgICBjb25zdCBkYXRhV3JhcCA9IGRvY3VtZW50LmdldEVs
ZW1lbnRCeUlkKCdjLWRhdGEtd3JhcCcpOwogICAgICAgIGNvbnN0IGRhdGFTZXAgPSBkb2N1bWVu
dC5nZXRFbGVtZW50QnlJZCgnYy1kYXRhLXNlcCcpOwogICAgICAgIGNvbnN0IHNob3dEYXRhID0g
IWlzUmVjZW50ICYmIChub3JtVHlwZShjLnR5cGUpID09PSAndGV4dCcgfHwgbm9ybVR5cGUoYy50
eXBlKSA9PT0gJ2xpbmsnKTsKICAgICAgICBpZiAoZGF0YVdyYXApIGRhdGFXcmFwLnN0eWxlLmRp
c3BsYXkgPSBzaG93RGF0YSA/ICcnIDogJ25vbmUnOwogICAgICAgIGlmIChkYXRhU2VwKSBkYXRh
U2VwLnN0eWxlLmRpc3BsYXkgPSBzaG93RGF0YSA/ICcnIDogJ25vbmUnOwogICAgICAgIGlmIChk
YXRhV3JhcCkgZGF0YVdyYXAuY2xhc3NMaXN0LnJlbW92ZSgnb3BlbicpOwogICAgICAgIGN0eEVs
LmNsYXNzTGlzdC5hZGQoJ29uJyk7CiAgICAgICAgY3R4RWwuc3R5bGUubGVmdCA9IHggKyAncHgn
OwogICAgICAgIGN0eEVsLnN0eWxlLnRvcCAgPSB5ICsgJ3B4JzsKICAgICAgICByZXF1ZXN0QW5p
bWF0aW9uRnJhbWUoKCkgPT4gewogICAgICAgICAgICBjb25zdCByID0gY3R4RWwuZ2V0Qm91bmRp
bmdDbGllbnRSZWN0KCk7CiAgICAgICAgICAgIGlmIChyLnJpZ2h0ICA+IGlubmVyV2lkdGgpICBj
dHhFbC5zdHlsZS5sZWZ0ID0gKHggLSByLndpZHRoKSAgKyAncHgnOwogICAgICAgICAgICBpZiAo
ci5ib3R0b20gPiBpbm5lckhlaWdodCkgY3R4RWwuc3R5bGUudG9wICA9ICh5IC0gci5oZWlnaHQp
ICsgJ3B4JzsKICAgICAgICAgICAgcGxhY2VEYXRhU3VibWVudSgpOwogICAgICAgIH0pOwogICAg
fQogICAgZnVuY3Rpb24gcGxhY2VEYXRhU3VibWVudSgpIHsKICAgICAgICBjb25zdCB3cmFwID0g
ZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2MtZGF0YS13cmFwJyk7CiAgICAgICAgY29uc3Qgc3Vi
ID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2MtZGF0YS1zdWInKTsKICAgICAgICBpZiAoIXdy
YXAgfHwgIXN1YiB8fCB3cmFwLnN0eWxlLmRpc3BsYXkgPT09ICdub25lJykgcmV0dXJuOwogICAg
ICAgIGNvbnN0IHBhZCA9IDQ7CiAgICAgICAgLy8gTWVhc3VyZSB3aGlsZSB0ZW1wb3JhcmlseSB2
aXNpYmxlIChzdWJtZW51IG1heSBzdGlsbCBiZSBkaXNwbGF5Om5vbmUpCiAgICAgICAgY29uc3Qg
cHJldkRpc3BsYXkgPSBzdWIuc3R5bGUuZGlzcGxheTsKICAgICAgICBjb25zdCBwcmV2VmlzaWJp
bGl0eSA9IHN1Yi5zdHlsZS52aXNpYmlsaXR5OwogICAgICAgIGNvbnN0IHByZXZMZWZ0ID0gc3Vi
LnN0eWxlLmxlZnQ7CiAgICAgICAgY29uc3QgcHJldlJpZ2h0ID0gc3ViLnN0eWxlLnJpZ2h0Owog
ICAgICAgIHN1Yi5jbGFzc0xpc3QucmVtb3ZlKCdsZWZ0Jyk7CiAgICAgICAgc3ViLnN0eWxlLmxl
ZnQgPSAnY2FsYygxMDAlIC0gMnB4KSc7CiAgICAgICAgc3ViLnN0eWxlLnJpZ2h0ID0gJ2F1dG8n
OwogICAgICAgIHN1Yi5zdHlsZS52aXNpYmlsaXR5ID0gJ2hpZGRlbic7CiAgICAgICAgc3ViLnN0
eWxlLmRpc3BsYXkgPSAnYmxvY2snOwogICAgICAgIGNvbnN0IHN1YlcgPSBNYXRoLmNlaWwoc3Vi
LmdldEJvdW5kaW5nQ2xpZW50UmVjdCgpLndpZHRoIHx8IHN1Yi5vZmZzZXRXaWR0aCB8fCAwKTsK
ICAgICAgICBjb25zdCB3cmFwUmVjdCA9IHdyYXAuZ2V0Qm91bmRpbmdDbGllbnRSZWN0KCk7CiAg
ICAgICAgc3ViLnN0eWxlLmRpc3BsYXkgPSBwcmV2RGlzcGxheTsKICAgICAgICBzdWIuc3R5bGUu
dmlzaWJpbGl0eSA9IHByZXZWaXNpYmlsaXR5OwogICAgICAgIHN1Yi5zdHlsZS5sZWZ0ID0gcHJl
dkxlZnQ7CiAgICAgICAgc3ViLnN0eWxlLnJpZ2h0ID0gcHJldlJpZ2h0OwoKICAgICAgICBpZiAo
c3ViVyA8PSAwKSByZXR1cm47CiAgICAgICAgY29uc3Qgc3BhY2VSaWdodCA9IHdpbmRvdy5pbm5l
cldpZHRoIC0gd3JhcFJlY3QucmlnaHQgLSBwYWQ7CiAgICAgICAgY29uc3Qgc3BhY2VMZWZ0ID0g
d3JhcFJlY3QubGVmdCAtIHBhZDsKICAgICAgICBjb25zdCBmaXRzUmlnaHQgPSBzcGFjZVJpZ2h0
ID49IHN1Ylc7CiAgICAgICAgY29uc3QgZml0c0xlZnQgPSBzcGFjZUxlZnQgPj0gc3ViVzsKICAg
ICAgICBsZXQgb3BlbkxlZnQgPSBmYWxzZTsKICAgICAgICBpZiAoZml0c1JpZ2h0KSBvcGVuTGVm
dCA9IGZhbHNlOwogICAgICAgIGVsc2UgaWYgKGZpdHNMZWZ0KSBvcGVuTGVmdCA9IHRydWU7CiAg
ICAgICAgZWxzZSBvcGVuTGVmdCA9IHNwYWNlTGVmdCA+IHNwYWNlUmlnaHQ7IC8vIG5laXRoZXIg
Zml0cyDigJQgcGljayB0aGUgbGFyZ2VyIGdhcAoKICAgICAgICBpZiAob3BlbkxlZnQpIHsKICAg
ICAgICAgICAgc3ViLmNsYXNzTGlzdC5hZGQoJ2xlZnQnKTsKICAgICAgICAgICAgc3ViLnN0eWxl
LmxlZnQgPSAnYXV0byc7CiAgICAgICAgICAgIHN1Yi5zdHlsZS5yaWdodCA9ICdjYWxjKDEwMCUg
LSAycHgpJzsKICAgICAgICB9IGVsc2UgewogICAgICAgICAgICBzdWIuY2xhc3NMaXN0LnJlbW92
ZSgnbGVmdCcpOwogICAgICAgICAgICBzdWIuc3R5bGUubGVmdCA9ICdjYWxjKDEwMCUgLSAycHgp
JzsKICAgICAgICAgICAgc3ViLnN0eWxlLnJpZ2h0ID0gJ2F1dG8nOwogICAgICAgIH0KICAgIH0K
ICAgIGZ1bmN0aW9uIGhpZGVDdHgoKSB7CiAgICAgICAgY3R4RWwuY2xhc3NMaXN0LnJlbW92ZSgn
b24nKTsKICAgICAgICBjdHhDbGlwID0gbnVsbDsKICAgICAgICB0cnkgewogICAgICAgICAgICBj
b25zdCB3cmFwID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2MtZGF0YS13cmFwJyk7CiAgICAg
ICAgICAgIGlmICh3cmFwKSB3cmFwLmNsYXNzTGlzdC5yZW1vdmUoJ29wZW4nKTsKICAgICAgICAg
ICAgY2xlYXJEYXRhU3VibWVudVBpY2soKTsKICAgICAgICAgICAgcHJldmlld0RhdGFUcmFuc2Zv
cm1TZXErKzsKICAgICAgICB9IGNhdGNoIHt9CiAgICB9CiAgICB3aW5kb3cuX19oaWRlQ3R4ID0g
aGlkZUN0eDsKCiAgICBmdW5jdGlvbiBkaXNtaXNzQ3R4VW5sZXNzSW5zaWRlKGUpIHsKICAgICAg
ICBpZiAoIWN0eEVsLmNsYXNzTGlzdC5jb250YWlucygnb24nKSkgcmV0dXJuOwogICAgICAgIGlm
IChlLnRhcmdldC5jbG9zZXN0KCcjY3R4JykpIHJldHVybjsKICAgICAgICBoaWRlQ3R4KCk7CiAg
ICB9CiAgICBkb2N1bWVudC5hZGRFdmVudExpc3RlbmVyKCdtb3VzZWRvd24nLCBkaXNtaXNzQ3R4
VW5sZXNzSW5zaWRlLCB0cnVlKTsKICAgIGRvY3VtZW50LmFkZEV2ZW50TGlzdGVuZXIoJ2NsaWNr
JywgZGlzbWlzc0N0eFVubGVzc0luc2lkZSwgdHJ1ZSk7CiAgICBsaXN0RWwuYWRkRXZlbnRMaXN0
ZW5lcignc2Nyb2xsJywgaGlkZUN0eCwgeyBwYXNzaXZlOiB0cnVlIH0pOwogICAgZG9jdW1lbnQu
YWRkRXZlbnRMaXN0ZW5lcigna2V5ZG93bicsIGUgPT4gewogICAgICAgIC8vIEVzYzogYWx3YXlz
IGNsb3NlIHBhbmVsIChzZWFyY2ggb3Igbm90KTsgcGluIGtlZXBzIHBhbmVsCiAgICAgICAgaWYg
KGUua2V5ID09PSAnRXNjYXBlJykgewogICAgICAgICAgICBlLnByZXZlbnREZWZhdWx0KCk7CiAg
ICAgICAgICAgIGhpZGVDdHgoKTsKICAgICAgICAgICAgY29uc3QgdGQgPSBkb2N1bWVudC5nZXRF
bGVtZW50QnlJZCgndGl0bGUtZGxnJyk7CiAgICAgICAgICAgIGlmICh0ZCAmJiB0ZC5jbGFzc0xp
c3QuY29udGFpbnMoJ29uJykpIHsKICAgICAgICAgICAgICAgIHRyeSB7IGNsb3NlVGl0bGVEbGco
KTsgfSBjYXRjaCB7IHRkLmNsYXNzTGlzdC5yZW1vdmUoJ29uJyk7IH0KICAgICAgICAgICAgICAg
IHRyeSB7IGFoaygnYmx1clBhbmVsJyk7IH0gY2F0Y2gge30KICAgICAgICAgICAgICAgIHJldHVy
bjsKICAgICAgICAgICAgfQogICAgICAgICAgICBpZiAoY2xyRGxnLmNsYXNzTGlzdC5jb250YWlu
cygnb24nKSkgewogICAgICAgICAgICAgICAgY2xvc2VDbGVhckRsZygpOwogICAgICAgICAgICAg
ICAgcmV0dXJuOwogICAgICAgICAgICB9CiAgICAgICAgICAgIGlmICghcGlubmVkVUkpIGFoaygn
aGlkZScpOwogICAgICAgICAgICByZXR1cm47CiAgICAgICAgfQogICAgICAgIC8vIFdoaWxlIHR5
cGluZyBpbiBzZWFyY2g6IEN0cmwrSS9LIGFuZCBhcnJvd3MgbW92ZSBsaXN0LCBkb24ndCBsZWF2
ZSB0aGUgYm94CiAgICAgICAgaWYgKGRvY3VtZW50LmFjdGl2ZUVsZW1lbnQ/LmlkID09PSAnc2Vh
cmNoJykgewogICAgICAgICAgICBpZiAoKGUuY3RybEtleSB8fCBlLm1ldGFLZXkpICYmIChlLmtl
eSA9PT0gJ2knIHx8IGUua2V5ID09PSAnSScpKSB7CiAgICAgICAgICAgICAgICBlLnByZXZlbnRE
ZWZhdWx0KCk7IGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAgICAgICAgICAgICB3aW5kb3cuX19u
YXYgJiYgd2luZG93Ll9fbmF2KCd1cCcpOwogICAgICAgICAgICAgICAgcmV0dXJuOwogICAgICAg
ICAgICB9CiAgICAgICAgICAgIGlmICgoZS5jdHJsS2V5IHx8IGUubWV0YUtleSkgJiYgKGUua2V5
ID09PSAnaycgfHwgZS5rZXkgPT09ICdLJykpIHsKICAgICAgICAgICAgICAgIGUucHJldmVudERl
ZmF1bHQoKTsgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICAgICAgICAgIHdpbmRvdy5fX25h
diAmJiB3aW5kb3cuX19uYXYoJ2Rvd24nKTsKICAgICAgICAgICAgICAgIHJldHVybjsKICAgICAg
ICAgICAgfQogICAgICAgICAgICBpZiAoZS5rZXkgPT09ICdBcnJvd0Rvd24nKSB7CiAgICAgICAg
ICAgICAgICBlLnByZXZlbnREZWZhdWx0KCk7IGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAgICAg
ICAgICAgICB3aW5kb3cuX19uYXYgJiYgd2luZG93Ll9fbmF2KCdkb3duJyk7CiAgICAgICAgICAg
ICAgICByZXR1cm47CiAgICAgICAgICAgIH0KICAgICAgICAgICAgaWYgKGUua2V5ID09PSAnQXJy
b3dVcCcpIHsKICAgICAgICAgICAgICAgIGUucHJldmVudERlZmF1bHQoKTsgZS5zdG9wUHJvcGFn
YXRpb24oKTsKICAgICAgICAgICAgICAgIHdpbmRvdy5fX25hdiAmJiB3aW5kb3cuX19uYXYoJ3Vw
Jyk7CiAgICAgICAgICAgICAgICByZXR1cm47CiAgICAgICAgICAgIH0KICAgICAgICAgICAgcmV0
dXJuOwogICAgICAgIH0KICAgICAgICBjb25zdCB2aXMgPSAodHlwZW9mIG5hdkxpc3QgPT09ICdm
dW5jdGlvbicgPyBuYXZMaXN0KCkgOiB2aXNpYmxlTGlzdCgpKTsKICAgICAgICBpZiAoIXZpcy5s
ZW5ndGgpIHJldHVybjsKICAgICAgICBsZXQgaWR4ID0gc2VsZWN0ZWRJbmRleCgpOwogICAgICAg
IGlmIChpZHggPCAwKSBpZHggPSAwOwogICAgICAgIGlmICAgICAgKGUua2V5ID09PSAnQXJyb3dE
b3duJykgeyBlLnByZXZlbnREZWZhdWx0KCk7IGUuc3RvcFByb3BhZ2F0aW9uKCk7IHNlbGVjdEJ5
SW5kZXgoaWR4ICsgMSk7IH0KICAgICAgICBlbHNlIGlmIChlLmtleSA9PT0gJ0Fycm93VXAnKSAg
IHsgZS5wcmV2ZW50RGVmYXVsdCgpOyBlLnN0b3BQcm9wYWdhdGlvbigpOyBzZWxlY3RCeUluZGV4
KGlkeCAtIDEpOyB9CiAgICAgICAgZWxzZSBpZiAoZS5rZXkgPT09ICdFbnRlcicpIHsKICAgICAg
ICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOwogICAgICAgICAgICAvLyDlm7rlrprml7blm57ovabk
uI3nspjotLTvvIzlj6rngrnmnaHnm67nspjotLQKICAgICAgICAgICAgaWYgKHBpbm5lZFVJKSBy
ZXR1cm47CiAgICAgICAgICAgIGlmIChtdWx0aUlkcy5sZW5ndGggPj0gMSkgewogICAgICAgICAg
ICAgICAgY29uc3QgaWRzID0gbXVsdGlJZHMuc2xpY2UoKTsKICAgICAgICAgICAgICAgIGNsZWFy
TXVsdGkoKTsKICAgICAgICAgICAgICAgIG1hcmtQYXN0ZWRMb2NhbChpZHMpOwogICAgICAgICAg
ICAgICAgcGFzdGVNYW55V2l0aFNlcChpZHMpOwogICAgICAgICAgICAgICAgcmV0dXJuOwogICAg
ICAgICAgICB9CiAgICAgICAgICAgIGNvbnN0IGMgPSB2aXNbc2VsZWN0ZWRJbmRleCgpXTsKICAg
ICAgICAgICAgaWYgKGMpIHsKICAgICAgICAgICAgICAgIG1hcmtQYXN0ZWRMb2NhbChjLmlkKTsK
ICAgICAgICAgICAgICAgIGFoaygncGFzdGUnLCBTdHJpbmcoYy5pZCkpOwogICAgICAgICAgICB9
CiAgICAgICAgfSBlbHNlIGlmICgvXlsxLTldJC8udGVzdChlLmtleSkpIHsKICAgICAgICAgICAg
Y29uc3QgYyA9IHZpc1srZS5rZXkgLSAxXTsKICAgICAgICAgICAgaWYgKGMpIHsKICAgICAgICAg
ICAgICAgIG1hcmtQYXN0ZWRMb2NhbChjLmlkKTsKICAgICAgICAgICAgICAgIGFoaygncGFzdGUn
LCBTdHJpbmcoYy5pZCkpOwogICAgICAgICAgICB9CiAgICAgICAgfQogICAgfSk7CgogICAgd2lu
ZG93Ll9fbmF2ID0gZGlyID0+IHsKICAgICAgICBjb25zdCB0ZCA9IGRvY3VtZW50LmdldEVsZW1l
bnRCeUlkKCd0aXRsZS1kbGcnKTsKICAgICAgICBpZiAodGQgJiYgdGQuY2xhc3NMaXN0LmNvbnRh
aW5zKCdvbicpKSByZXR1cm47CiAgICAgICAgY29uc3QgdmlzID0gKHR5cGVvZiBuYXZMaXN0ID09
PSAnZnVuY3Rpb24nID8gbmF2TGlzdCgpIDogdmlzaWJsZUxpc3QoKSk7CiAgICAgICAgaWYgKCF2
aXMubGVuZ3RoICYmIGRpciAhPT0gJ3RhYicgJiYgZGlyICE9PSAndGFiUHJldicpIHJldHVybjsK
ICAgICAgICBsZXQgaWR4ID0gc2VsZWN0ZWRJbmRleCgpOwogICAgICAgIGlmIChpZHggPCAwKSBp
ZHggPSAwOwogICAgICAgIGlmIChkaXIgPT09ICd1cCcpIHNlbGVjdEJ5SW5kZXgoaWR4IC0gMSk7
CiAgICAgICAgZWxzZSBpZiAoZGlyID09PSAnZG93bicpIHNlbGVjdEJ5SW5kZXgoaWR4ICsgMSk7
CiAgICAgICAgZWxzZSBpZiAoZGlyID09PSAnZW50ZXInKSB7CiAgICAgICAgICAgIGlmIChwaW5u
ZWRVSSkgcmV0dXJuOwogICAgICAgICAgICBfX3ByZXBQYXN0ZSgpOwogICAgICAgICAgICBpZiAo
bXVsdGlJZHMubGVuZ3RoID49IDEpIHsKICAgICAgICAgICAgICAgIGNvbnN0IGlkcyA9IG11bHRp
SWRzLnNsaWNlKCk7CiAgICAgICAgICAgICAgICBjbGVhck11bHRpKCk7CiAgICAgICAgICAgICAg
ICBtYXJrUGFzdGVkTG9jYWwoaWRzKTsKICAgICAgICAgICAgICAgIHBhc3RlTWFueVdpdGhTZXAo
aWRzKTsKICAgICAgICAgICAgICAgIHJldHVybjsKICAgICAgICAgICAgfQogICAgICAgICAgICBj
b25zdCBjID0gdmlzW3NlbGVjdGVkSW5kZXgoKV07CiAgICAgICAgICAgIGlmIChjKSB7CiAgICAg
ICAgICAgICAgICBtYXJrUGFzdGVkTG9jYWwoYy5pZCk7CiAgICAgICAgICAgICAgICBhaGsoJ3Bh
c3RlJywgU3RyaW5nKGMuaWQpKTsKICAgICAgICAgICAgfQogICAgICAgIH0KICAgIH07CgogICAg
Ly8gQUhLIEVudGVyIGhvdGtleSBsYW5kcyBoZXJlIChXZWJWaWV3IG1heSBub3QgcmVjZWl2ZSB0
aGUga2V5IHdoaWxlIHVucGlubmVkKQogICAgd2luZG93Ll9fZWRpdFRpdGxlID0gKCkgPT4gewog
ICAgICAgIGxldCBjID0gbnVsbDsKICAgICAgICBpZiAoc2VsZWN0ZWRJZCkKICAgICAgICAgICAg
YyA9IGFsbENsaXBzLmZpbmQoeCA9PiAreC5pZCA9PT0gK3NlbGVjdGVkSWQpIHx8IG51bGw7CiAg
ICAgICAgaWYgKCFjICYmIGN0eENsaXApCiAgICAgICAgICAgIGMgPSBjdHhDbGlwOwogICAgICAg
IGlmICghYykgewogICAgICAgICAgICBjb25zdCB2aXMgPSB2aXNpYmxlTGlzdCgpOwogICAgICAg
ICAgICBpZiAodmlzLmxlbmd0aCkgYyA9IHZpc1swXTsKICAgICAgICB9CiAgICAgICAgaWYgKCFj
KSByZXR1cm47CiAgICAgICAgb3BlblRpdGxlRGxnKGMpOwogICAgfTsKCiAgICB3aW5kb3cuX19v
bkVudGVyID0gKCkgPT4gewogICAgICAgIGNvbnN0IHRkID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5
SWQoJ3RpdGxlLWRsZycpOwogICAgICAgIGlmICh0ZCAmJiB0ZC5jbGFzc0xpc3QuY29udGFpbnMo
J29uJykpIHsKICAgICAgICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3RpdGxlLW9rJyk/
LmNsaWNrKCk7CiAgICAgICAgICAgIHJldHVybjsKICAgICAgICB9CiAgICAgICAgaWYgKGRvY3Vt
ZW50LmFjdGl2ZUVsZW1lbnQ/LmlkID09PSAndGl0bGUtaW5wdXQnKSB7CiAgICAgICAgICAgIGRv
Y3VtZW50LmdldEVsZW1lbnRCeUlkKCd0aXRsZS1vaycpPy5jbGljaygpOwogICAgICAgICAgICBy
ZXR1cm47CiAgICAgICAgfQogICAgICAgIC8vIOiHquWumuS5ieWIhumalOespu+8muacquWbuuWu
muaXtiBBSEsg5Lya5oqiIEVudGVyCiAgICAgICAgY29uc3Qgc2VwTWVudSA9IGRvY3VtZW50Lmdl
dEVsZW1lbnRCeUlkKCdwYXN0ZS1zZXAtbWVudScpOwogICAgICAgIGNvbnN0IHNlcElucCA9IGRv
Y3VtZW50LmdldEVsZW1lbnRCeUlkKCdwYXN0ZS1zZXAtY3VzdG9tJyk7CiAgICAgICAgaWYgKHNl
cE1lbnUgJiYgc2VwTWVudS5jbGFzc0xpc3QuY29udGFpbnMoJ29uJykgJiYgc2VwSW5wKSB7CiAg
ICAgICAgICAgIGlmIChTdHJpbmcoc2VwSW5wLnZhbHVlIHx8ICcnKSAhPT0gJycpIGFwcGx5U2Vw
YXJhdG9yKHNlcElucC52YWx1ZSk7CiAgICAgICAgICAgIGVsc2UgY2xvc2VTZXBNZW51KCk7CiAg
ICAgICAgICAgIHJldHVybjsKICAgICAgICB9CiAgICAgICAgLy8g5Zu65a6a5pe25Zue6L2m5LiN
57KY6LS0CiAgICAgICAgaWYgKHBpbm5lZFVJKSByZXR1cm47CiAgICAgICAgLy8gVHlwaW5nIGlu
IHNlYXJjaDogRW50ZXIgc2hvdWxkIHBhc3RlIHNlbGVjdGVkIGl0ZW0KICAgICAgICBpZiAoZG9j
dW1lbnQuYWN0aXZlRWxlbWVudD8uaWQgPT09ICdzZWFyY2gnKSB7CiAgICAgICAgICAgIHdpbmRv
dy5fX25hdiAmJiB3aW5kb3cuX19uYXYoJ2VudGVyJyk7CiAgICAgICAgICAgIHJldHVybjsKICAg
ICAgICB9CiAgICAgICAgd2luZG93Ll9fbmF2ICYmIHdpbmRvdy5fX25hdignZW50ZXInKTsKICAg
IH07CgogICAgd2luZG93Ll9fY3ljbGVUYWIgPSBkaXIgPT4gewogICAgICAgIGNvbnN0IGkgPSBN
YXRoLm1heCgwLCBUQUJfT1JERVIuaW5kZXhPZihjdXJUYWIpKTsKICAgICAgICBjb25zdCBuZXh0
ID0gVEFCX09SREVSWyhpICsgKGRpciB8IDApICsgVEFCX09SREVSLmxlbmd0aCAqIDEwKSAlIFRB
Ql9PUkRFUi5sZW5ndGhdOwogICAgICAgIHNldFRhYihuZXh0KTsKICAgIH07CiAgICB3aW5kb3cu
X19vblBhbmVsU2hvdyA9IChrZWVwU2VhcmNoKSA9PiB7CiAgICAgICAgd2luZG93Ll9fcGVyZk1h
cmsgJiYgd2luZG93Ll9fcGVyZk1hcmsoJ2pzX29uUGFuZWxTaG93IGtlZXBTZWFyY2g9JyArICgh
IWtlZXBTZWFyY2gpKTsKICAgICAgICB0cnkgeyByZXNldFBhc3RlU2VwRGVmYXVsdCgpOyB9IGNh
dGNoIHt9CiAgICAgICAgLy8gRG8gTk9UIGZvY3VzIFdlYlZpZXcg4oCUIGtlZXAgZWRpdG9yIGNh
cmV0L2ZvY3VzIChBSEsgaGFuZGxlcyBrZXlzIHZpYSAjSG90SWYpCiAgICAgICAgLy8gV2luK1Y6
IGNvbGxhcHNlIHNlYXJjaC4gPz8gc2VhcmNoOiBrZWVwL29wZW4gc2VhcmNoIGJveC4KICAgICAg
ICBrZWVwU2VhcmNoID0gISFrZWVwU2VhcmNoOwogICAgICAgIHRyeSB7IGhpZGVDdHgoKTsgfSBj
YXRjaCB7fQogICAgICAgIHRyeSB7IGNsb3NlVGl0bGVEbGcoKTsgfSBjYXRjaCB7fQogICAgICAg
IHRyeSB7CiAgICAgICAgICAgIGNvbnN0IHdyYXAgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgn
c2VhcmNoLXdyYXAnKTsKICAgICAgICAgICAgY29uc3Qgc3JjaCA9IGRvY3VtZW50LmdldEVsZW1l
bnRCeUlkKCdzZWFyY2gnKTsKICAgICAgICAgICAgY29uc3Qgc2NsciA9IGRvY3VtZW50LmdldEVs
ZW1lbnRCeUlkKCdzZWFyY2gtY2xyJyk7CiAgICAgICAgICAgIGlmICgha2VlcFNlYXJjaCkgewog
ICAgICAgICAgICAgICAgaWYgKHdyYXApIHdyYXAuY2xhc3NMaXN0LnJlbW92ZSgnb3BlbicpOwog
ICAgICAgICAgICAgICAgaWYgKHNyY2gpIHsKICAgICAgICAgICAgICAgICAgICBzcmNoLnZhbHVl
ID0gJyc7CiAgICAgICAgICAgICAgICAgICAgc3JjaC5jbGFzc0xpc3QucmVtb3ZlKCdoYXMtdmFs
Jyk7CiAgICAgICAgICAgICAgICAgICAgdHJ5IHsgc3JjaC5ibHVyKCk7IH0gY2F0Y2gge30KICAg
ICAgICAgICAgICAgIH0KICAgICAgICAgICAgICAgIGlmIChzY2xyKSBzY2xyLnN0eWxlLmRpc3Bs
YXkgPSAnbm9uZSc7CiAgICAgICAgICAgICAgICBxdWVyeSA9ICcnOwogICAgICAgICAgICAgICAg
d2luZG93Ll9faG9zdEZpbHRlcmVkID0gZmFsc2U7CiAgICAgICAgICAgICAgICB3aW5kb3cuX19o
b3N0RmlsdGVyUSA9ICcnOwogICAgICAgICAgICAgICAgLy8gV2luK1bvvJrnq4vliLvnlKjmnKro
v4fmu6TnvJPlrZjpk7rliJfooajvvIzpgb/lhY3lhYjpl6rov4fmu6Tnu5Pmnpwv56m65aOz5YaN
562JIFNldFZpZXcKICAgICAgICAgICAgICAgIHRyeSB7CiAgICAgICAgICAgICAgICAgICAgY29u
c3QgaGl0ID0gdmlld01lbS5nZXQodmlld01lbUtleSgnYWxsJywgJycsIGZhbHNlKSk7CiAgICAg
ICAgICAgICAgICAgICAgaWYgKGhpdCAmJiBBcnJheS5pc0FycmF5KGhpdC5pdGVtcykgJiYgaGl0
Lml0ZW1zLmxlbmd0aCkgewogICAgICAgICAgICAgICAgICAgICAgICBhbGxDbGlwcyA9IGhpdC5p
dGVtcy5zbGljZSgpOwogICAgICAgICAgICAgICAgICAgICAgICBkaXNrVG90YWwgPSBOdW1iZXIo
aGl0LnRvdGFsKSB8fCBoaXQuaXRlbXMubGVuZ3RoOwogICAgICAgICAgICAgICAgICAgICAgICB3
aW5kb3cuX19kYXRhUmVhZHkgPSB0cnVlOwogICAgICAgICAgICAgICAgICAgICAgICBob3N0UHVz
aGVkT25jZSA9IHRydWU7CiAgICAgICAgICAgICAgICAgICAgICAgIHNhd05vbkVtcHR5ID0gdHJ1
ZTsKICAgICAgICAgICAgICAgICAgICAgICAgY2xlYXJXYWl0aW5nRGF0YSgpOwogICAgICAgICAg
ICAgICAgICAgIH0gZWxzZSB7CiAgICAgICAgICAgICAgICAgICAgICAgIHNjaGVkdWxlRGVsYXll
ZFNrZWwoKTsKICAgICAgICAgICAgICAgICAgICB9CiAgICAgICAgICAgICAgICB9IGNhdGNoIHsK
ICAgICAgICAgICAgICAgICAgICBzY2hlZHVsZURlbGF5ZWRTa2VsKCk7CiAgICAgICAgICAgICAg
ICB9CiAgICAgICAgICAgIH0gZWxzZSBpZiAod3JhcCkgewogICAgICAgICAgICAgICAgd3JhcC5j
bGFzc0xpc3QuYWRkKCdvcGVuJyk7CiAgICAgICAgICAgICAgICBpZiAoc3JjaCAmJiBzcmNoLnZh
bHVlKQogICAgICAgICAgICAgICAgICAgIHF1ZXJ5ID0gc3JjaC52YWx1ZTsKICAgICAgICAgICAg
ICAgIC8vID8/IOaQnOe0ou+8muWcqOS4u+acuui/h+a7pOe7k+aenOWIsOi+vuWJje+8jOWFiOaM
ieWFs+mUruWtl+acrOWcsOa7pO+8jOemgeatoumXquWHuuOAjOWFqOmDqOOAjQogICAgICAgICAg
ICAgICAgaWYgKFN0cmluZyhxdWVyeSB8fCAnJykudHJpbSgpKSB7CiAgICAgICAgICAgICAgICAg
ICAgd2luZG93Ll9faG9zdEZpbHRlcmVkID0gZmFsc2U7CiAgICAgICAgICAgICAgICAgICAgd2lu
ZG93Ll9faG9zdEZpbHRlclEgPSAnJzsKICAgICAgICAgICAgICAgIH0KICAgICAgICAgICAgfQog
ICAgICAgICAgICB0b2RheU9ubHkgPSBmYWxzZTsKICAgICAgICAgICAgdHJ5IHsKICAgICAgICAg
ICAgICAgIGNvbnN0IGJ0blRvZGF5ID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2J0bi10b2Rh
eScpOwogICAgICAgICAgICAgICAgaWYgKGJ0blRvZGF5KSBidG5Ub2RheS5jbGFzc0xpc3QucmVt
b3ZlKCdvbicpOwogICAgICAgICAgICB9IGNhdGNoIHt9CiAgICAgICAgICAgIGN1clRhYiA9ICdh
bGwnOwogICAgICAgICAgICBsb2FkaW5nTW9yZSA9IGZhbHNlOwogICAgICAgICAgICBtYXJrVGFi
KCdhbGwnKTsKICAgICAgICAgICAgLy8g5LiN6KaBIGFoaygnYmx1clBhbmVsJynvvJrkvJrot58g
U2hvd1BhbmVsIOaKoueEpueCue+8jFdpbitWLz8/IOmDveWuueaYk+mXquOAgeS5sei3swogICAg
ICAgICAgICByZW5kZXIoKTsKICAgICAgICAgICAgLy8g5ZCM5q2l5b2T5YmNIHRhYi9xdWVyeSDl
iLAgQUhL77yIPz8g5pu+5Y+q55SoIHZpZXdUYWIg5pCc6ZSZ6aG177yJCiAgICAgICAgICAgIHJl
cXVlc3RWaWV3KCk7CiAgICAgICAgfSBjYXRjaCB7fQogICAgICAgIHNlbGVjdEZpcnN0T25TaG93
ID0gdHJ1ZTsKICAgICAgICBsb2NhdGVBY3RpdmUgPSBmYWxzZTsKICAgICAgICB1cGRhdGVMb2Nh
dGVCdG4oKTsKICAgICAgICBjbGVhck11bHRpKCk7CiAgICAgICAgY29uc3QgdmlzID0gdmlzaWJs
ZUxpc3QoKTsKICAgICAgICBpZiAodmlzLmxlbmd0aCkgewogICAgICAgICAgICBzZWxlY3RlZElk
ID0gdmlzWzBdLmlkOwogICAgICAgICAgICByYW5nZUFuY2hvcklkID0gc2VsZWN0ZWRJZDsKICAg
ICAgICAgICAgcmFuZ2VBbmNob3JDbGlja2VkID0gZmFsc2U7CiAgICAgICAgICAgIGxpc3RFbC5z
Y3JvbGxUb3AgPSAwOwogICAgICAgIH0KICAgICAgICBzeW5jSXRlbUhpZ2hsaWdodCgpOwogICAg
fTsKCiAgICBmdW5jdGlvbiBjdHhCaW5kKGlkLCBmbikgewogICAgICAgIGRvY3VtZW50LmdldEVs
ZW1lbnRCeUlkKGlkKS5hZGRFdmVudExpc3RlbmVyKCdjbGljaycsIGUgPT4gewogICAgICAgICAg
ICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgICAgICAgICBpZiAoY3R4Q2xpcCkgZm4oY3R4Q2xp
cCk7CiAgICAgICAgICAgIGhpZGVDdHgoKTsKICAgICAgICB9KTsKICAgIH0KICAgIGZ1bmN0aW9u
IHNxbFF1b3RlKHYpIHsKICAgICAgICByZXR1cm4gIiciICsgU3RyaW5nKHYgPz8gJycpLnJlcGxh
Y2UoLycvZywgIicnIikgKyAiJyI7CiAgICB9CiAgICBmdW5jdGlvbiBzdHJpcE91dGVyUXVvdGVz
KHYpIHsKICAgICAgICBjb25zdCBzID0gU3RyaW5nKHYgPz8gJycpLnRyaW0oKTsKICAgICAgICBp
ZiAoKHMuc3RhcnRzV2l0aCgnIicpICYmIHMuZW5kc1dpdGgoJyInKSkgfHwgKHMuc3RhcnRzV2l0
aCgiJyIpICYmIHMuZW5kc1dpdGgoIiciKSkpCiAgICAgICAgICAgIHJldHVybiBzLnNsaWNlKDEs
IC0xKTsKICAgICAgICByZXR1cm4gczsKICAgIH0KICAgIGZ1bmN0aW9uIHNwbGl0Q3N2UGFydHMo
cmF3KSB7CiAgICAgICAgY29uc3QgcyA9IFN0cmluZyhyYXcgPz8gJycpOwogICAgICAgIGNvbnN0
IHBhcnRzID0gW107CiAgICAgICAgbGV0IGN1ciA9ICcnOwogICAgICAgIGxldCBxID0gJyc7CiAg
ICAgICAgZm9yIChsZXQgaSA9IDA7IGkgPCBzLmxlbmd0aDsgaSsrKSB7CiAgICAgICAgICAgIGNv
bnN0IGNoID0gc1tpXTsKICAgICAgICAgICAgaWYgKHEpIHsKICAgICAgICAgICAgICAgIGlmIChj
aCA9PT0gcSkgewogICAgICAgICAgICAgICAgICAgIC8vIGRvdWJsZWQgcXVvdGUgZXNjYXBlCiAg
ICAgICAgICAgICAgICAgICAgaWYgKHNbaSArIDFdID09PSBxKSB7IGN1ciArPSBxOyBpKys7IH0K
ICAgICAgICAgICAgICAgICAgICBlbHNlIHEgPSAnJzsKICAgICAgICAgICAgICAgIH0gZWxzZSBj
dXIgKz0gY2g7CiAgICAgICAgICAgICAgICBjb250aW51ZTsKICAgICAgICAgICAgfQogICAgICAg
ICAgICBpZiAoY2ggPT09ICciJyB8fCBjaCA9PT0gIiciKSB7IHEgPSBjaDsgY29udGludWU7IH0K
ICAgICAgICAgICAgaWYgKGNoID09PSAnLCcpIHsgcGFydHMucHVzaChjdXIudHJpbSgpKTsgY3Vy
ID0gJyc7IGNvbnRpbnVlOyB9CiAgICAgICAgICAgIGN1ciArPSBjaDsKICAgICAgICB9CiAgICAg
ICAgcGFydHMucHVzaChjdXIudHJpbSgpKTsKICAgICAgICByZXR1cm4gcGFydHMuZmlsdGVyKHAg
PT4gcCAhPT0gJycpOwogICAgfQogICAgZnVuY3Rpb24gdHJhbnNmb3JtVGV4dFRvU3FsVHVwbGUo
cmF3LCBtb2RlKSB7CiAgICAgICAgbGV0IHNyYyA9IFN0cmluZyhyYXcgPz8gJycpLnRyaW0oKTsK
ICAgICAgICBpZiAoIXNyYykgcmV0dXJuICcnOwogICAgICAgIGxldCBwYXJ0cyA9IFtdOwogICAg
ICAgIGlmIChtb2RlID09PSAnbGluZXMnKSB7CiAgICAgICAgICAgIHBhcnRzID0gc3JjLnNwbGl0
KC9ccj9cbi8pLm1hcChsID0+IHN0cmlwT3V0ZXJRdW90ZXMobC50cmltKCkpKS5maWx0ZXIoQm9v
bGVhbik7CiAgICAgICAgfSBlbHNlIHsKICAgICAgICAgICAgLy8ge2EsYn0gLyBhLGIgLyB7ImEi
LCJiIn0KICAgICAgICAgICAgY29uc3QgbSA9IHNyYy5tYXRjaCgvXlxzKlx7KFtcc1xTXSopXH1c
cyokLyk7CiAgICAgICAgICAgIGlmIChtKSBzcmMgPSBtWzFdLnRyaW0oKTsKICAgICAgICAgICAg
cGFydHMgPSBzcGxpdENzdlBhcnRzKHNyYykubWFwKHN0cmlwT3V0ZXJRdW90ZXMpLmZpbHRlcihC
b29sZWFuKTsKICAgICAgICB9CiAgICAgICAgaWYgKCFwYXJ0cy5sZW5ndGgpIHJldHVybiAnJzsK
ICAgICAgICByZXR1cm4gJygnICsgcGFydHMubWFwKHNxbFF1b3RlKS5qb2luKCcsJykgKyAnKSc7
CiAgICB9CiAgICBmdW5jdGlvbiBhcHBseURhdGFUcmFuc2Zvcm0oYywgbW9kZSkgewogICAgICAg
IGlmICghYykgcmV0dXJuOwogICAgICAgIC8vIERvIG5vdCBtdXRhdGUgY2xpcCBoaXN0b3J5IOKA
lCBBSEsgdHJhbnNmb3JtcyBhIGNvcHkgYW5kIHBhc3RlcyBpdAogICAgICAgIHRyeSB7IG1hcmtQ
YXN0ZWRMb2NhbChjLmlkKTsgfSBjYXRjaCB7fQogICAgICAgIGFoaygndGV4dFRyYW5zZm9ybScs
IFN0cmluZyhjLmlkKSwgU3RyaW5nKG1vZGUgfHwgJ2F1dG8nKSk7CiAgICB9CiAgICBmdW5jdGlv
biBkZXRlY3REYXRhVHJhbnNmb3JtTW9kZShyYXcpIHsKICAgICAgICAvLyBVSSBsaXN0IG9ubHkg
aGFzIHRydW5jYXRlZCBwcmV2aWV3IChkYXRhPSIiKS4KICAgICAgICAvLyBDaGVjayBcIiBmaXJz
dDogZXNjYXBlZCBKU09OIG9mdGVuIGFsc28gc3RhcnRzIHdpdGggJ3snLgogICAgICAgIGNvbnN0
IHMgPSBTdHJpbmcocmF3ID8/ICcnKS50cmltKCk7CiAgICAgICAgaWYgKCFzKSByZXR1cm4gJyc7
CiAgICAgICAgaWYgKHMuaW5jbHVkZXMoJ1xcIicpKSByZXR1cm4gJ2pzb24nOwogICAgICAgIGlm
IChzLnN0YXJ0c1dpdGgoJ3snKSkgcmV0dXJuICdicmFjZSc7CiAgICAgICAgaWYgKHMuaW5jbHVk
ZXMoJ1xuJykgfHwgcy5pbmNsdWRlcygnXHInKSkgcmV0dXJuICdsaW5lcyc7CiAgICAgICAgcmV0
dXJuICcnOwogICAgfQogICAgZnVuY3Rpb24gY2xlYXJEYXRhU3VibWVudVBpY2soKSB7CiAgICAg
ICAgdHJ5IHsKICAgICAgICAgICAgZG9jdW1lbnQucXVlcnlTZWxlY3RvckFsbCgnI2MtZGF0YS1z
dWIgLmMtaXRlbS5waWNrJykuZm9yRWFjaChlbCA9PiBlbC5jbGFzc0xpc3QucmVtb3ZlKCdwaWNr
JykpOwogICAgICAgIH0gY2F0Y2gge30KICAgIH0KICAgIGZ1bmN0aW9uIGhpZ2hsaWdodERhdGFT
dWJtZW51TW9kZShtb2RlKSB7CiAgICAgICAgY2xlYXJEYXRhU3VibWVudVBpY2soKTsKICAgICAg
ICBjb25zdCBpZE1hcCA9IHsgYnJhY2U6ICdjLWRhdGEtYnJhY2UnLCBsaW5lczogJ2MtZGF0YS1s
aW5lcycsIGpzb246ICdjLWRhdGEtanNvbicgfTsKICAgICAgICBjb25zdCBpZCA9IGlkTWFwW21v
ZGVdOwogICAgICAgIGlmICghaWQpIHJldHVybjsKICAgICAgICBjb25zdCBlbCA9IGRvY3VtZW50
LmdldEVsZW1lbnRCeUlkKGlkKTsKICAgICAgICBpZiAoZWwpIGVsLmNsYXNzTGlzdC5hZGQoJ3Bp
Y2snKTsKICAgIH0KICAgIGZ1bmN0aW9uIHByZXZpZXdEYXRhVHJhbnNmb3JtTW9kZUFzeW5jKCkg
ewogICAgICAgIGNvbnN0IHRva2VuID0gKytwcmV2aWV3RGF0YVRyYW5zZm9ybVNlcTsKICAgICAg
ICBjb25zdCBjbGlwID0gY3R4Q2xpcDsKICAgICAgICBzZXRUaW1lb3V0KCgpID0+IHsKICAgICAg
ICAgICAgaWYgKHRva2VuICE9PSBwcmV2aWV3RGF0YVRyYW5zZm9ybVNlcSkgcmV0dXJuOwogICAg
ICAgICAgICBpZiAoIWNsaXAgfHwgY3R4Q2xpcCAhPT0gY2xpcCkgcmV0dXJuOwogICAgICAgICAg
ICBjb25zdCByYXcgPSBTdHJpbmcoY2xpcC5kYXRhIHx8IGNsaXAucHJldmlldyB8fCAnJyk7CiAg
ICAgICAgICAgIGNvbnN0IG1vZGUgPSBkZXRlY3REYXRhVHJhbnNmb3JtTW9kZShyYXcpOwogICAg
ICAgICAgICBpZiAodG9rZW4gIT09IHByZXZpZXdEYXRhVHJhbnNmb3JtU2VxKSByZXR1cm47CiAg
ICAgICAgICAgIGhpZ2hsaWdodERhdGFTdWJtZW51TW9kZShtb2RlKTsKICAgICAgICB9LCAwKTsK
ICAgIH0KICAgIGxldCBwcmV2aWV3RGF0YVRyYW5zZm9ybVNlcSA9IDA7CiAgICBjb25zdCBkYXRh
UGFyZW50ID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2MtZGF0YScpOwogICAgY29uc3QgZGF0
YVdyYXBFbCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjLWRhdGEtd3JhcCcpOwogICAgaWYg
KGRhdGFQYXJlbnQpIHsKICAgICAgICBkYXRhUGFyZW50LmFkZEV2ZW50TGlzdGVuZXIoJ2NsaWNr
JywgZSA9PiB7CiAgICAgICAgICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAgICAgICAgIC8v
IFByaW1hcnkgY2xpY2sgPSBhdXRvIGRldGVjdCArIHRyYW5zZm9ybSArIHBhc3RlCiAgICAgICAg
ICAgIGlmIChjdHhDbGlwKSB7CiAgICAgICAgICAgICAgICBhcHBseURhdGFUcmFuc2Zvcm0oY3R4
Q2xpcCwgJ2F1dG8nKTsKICAgICAgICAgICAgICAgIGhpZGVDdHgoKTsKICAgICAgICAgICAgICAg
IHJldHVybjsKICAgICAgICAgICAgfQogICAgICAgICAgICBjb25zdCB3cmFwID0gZG9jdW1lbnQu
Z2V0RWxlbWVudEJ5SWQoJ2MtZGF0YS13cmFwJyk7CiAgICAgICAgICAgIGlmICh3cmFwKSB7CiAg
ICAgICAgICAgICAgICB3cmFwLmNsYXNzTGlzdC50b2dnbGUoJ29wZW4nKTsKICAgICAgICAgICAg
ICAgIHBsYWNlRGF0YVN1Ym1lbnUoKTsKICAgICAgICAgICAgICAgIHByZXZpZXdEYXRhVHJhbnNm
b3JtTW9kZUFzeW5jKCk7CiAgICAgICAgICAgIH0KICAgICAgICB9KTsKICAgIH0KICAgIGlmIChk
YXRhV3JhcEVsKSB7CiAgICAgICAgZGF0YVdyYXBFbC5hZGRFdmVudExpc3RlbmVyKCdtb3VzZWVu
dGVyJywgKCkgPT4gewogICAgICAgICAgICBwbGFjZURhdGFTdWJtZW51KCk7CiAgICAgICAgICAg
IHByZXZpZXdEYXRhVHJhbnNmb3JtTW9kZUFzeW5jKCk7CiAgICAgICAgfSk7CiAgICAgICAgZGF0
YVdyYXBFbC5hZGRFdmVudExpc3RlbmVyKCdtb3VzZWxlYXZlJywgKCkgPT4gY2xlYXJEYXRhU3Vi
bWVudVBpY2soKSk7CiAgICB9CiAgICBjdHhCaW5kKCdjLWRhdGEtYnJhY2UnLCBjID0+IGFwcGx5
RGF0YVRyYW5zZm9ybShjLCAnYnJhY2UnKSk7CiAgICBjdHhCaW5kKCdjLWRhdGEtbGluZXMnLCBj
ID0+IGFwcGx5RGF0YVRyYW5zZm9ybShjLCAnbGluZXMnKSk7CiAgICBjdHhCaW5kKCdjLWRhdGEt
anNvbicsIGMgPT4gYXBwbHlEYXRhVHJhbnNmb3JtKGMsICdqc29uJykpOwogICAgY3R4QmluZCgn
Yy1jb3B5JywgIGMgPT4gewogICAgICAgIGlmIChub3JtVHlwZShjLnR5cGUpID09PSAncmVjZW50
JykKICAgICAgICAgICAgYWhrKCdjb3B5UGF0aCcsIFN0cmluZyhjLmRhdGEgfHwgYy5wcmV2aWV3
IHx8ICcnKSk7CiAgICAgICAgZWxzZQogICAgICAgICAgICBhaGsoJ2NvcHlCeUlkJywgU3RyaW5n
KGMuaWQpKTsKICAgIH0pOwogICAgY3R4QmluZCgnYy1wYXN0ZScsIGMgPT4gewogICAgICAgIGFj
dGl2YXRlQ2xpcEl0ZW0oYyk7CiAgICB9KTsKICAgIGN0eEJpbmQoJ2MtcGluJywgICBjID0+IHsK
ICAgICAgICAvLyBPcHRpbWlzdGljIGZsaXAg4oCUIOWbuuWumuWPqumYsua3mOaxsO+8jOS4jee9
rumhtu+8m+WGjeasoeiuv+mXruaJjemdoCBSZWNvcmQg6aG25Yiw5LiK6Z2iCiAgICAgICAgY29u
c3QgbmV4dCA9ICFpc1Bpbm5lZChjKTsKICAgICAgICBjb25zdCBpZCA9ICtjLmlkOwogICAgICAg
IHBhdGNoUGlubmVkSW5DYWNoZXMoaWQsIG5leHQpOwogICAgICAgIGMucGlubmVkID0gbmV4dDsK
ICAgICAgICBpZiAobmV4dCkgbWFya0ZhdlVuc2VlbihpZCk7CiAgICAgICAgZWxzZSB7CiAgICAg
ICAgICAgIHVuc2VlbkZhdklkcy5kZWxldGUoaWQpOwogICAgICAgICAgICBzYXZlVW5zZWVuRmF2
KCk7CiAgICAgICAgICAgIHVwZGF0ZVBpbkRvdCgpOwogICAgICAgIH0KICAgICAgICAvLyDmlLbo
l4/pobXlj5bmtojvvJrnq4vliLvku47liJfooajmkZjmjonvvIzliKvnrYkgU2V0VmlldyDmiavn
m5gKICAgICAgICBpZiAoIW5leHQgJiYgY3VyVGFiID09PSAncGlubmVkJykgewogICAgICAgICAg
ICBhbGxDbGlwcyA9IGFsbENsaXBzLmZpbHRlcih4ID0+ICt4LmlkICE9PSBpZCk7CiAgICAgICAg
ICAgIGRpc2tUb3RhbCA9IE1hdGgubWF4KDAsIChOdW1iZXIoZGlza1RvdGFsKSB8fCAwKSAtIDEp
OwogICAgICAgICAgICBwaW5uZWRUb3RhbCA9IE1hdGgubWF4KDAsIChOdW1iZXIocGlubmVkVG90
YWwpIHx8IDApIC0gMSk7CiAgICAgICAgICAgIGlmICgrc2VsZWN0ZWRJZCA9PT0gaWQpCiAgICAg
ICAgICAgICAgICBzZWxlY3RlZElkID0gYWxsQ2xpcHMubGVuZ3RoID8gYWxsQ2xpcHNbMF0uaWQg
OiAwOwogICAgICAgICAgICB0cnkgewogICAgICAgICAgICAgICAgdmlld01lbS5zZXQodmlld01l
bUtleShjdXJUYWIsIHF1ZXJ5LCB0b2RheU9ubHkpLCB7CiAgICAgICAgICAgICAgICAgICAgaXRl
bXM6IGFsbENsaXBzLnNsaWNlKCksCiAgICAgICAgICAgICAgICAgICAgdG90YWw6IGRpc2tUb3Rh
bAogICAgICAgICAgICAgICAgfSk7CiAgICAgICAgICAgIH0gY2F0Y2gge30KICAgICAgICAgICAg
Y2xlYXJGYXZVbnNlZW4oKTsKICAgICAgICB9IGVsc2UgaWYgKGN1clRhYiA9PT0gJ3Bpbm5lZCcp
IHsKICAgICAgICAgICAgY2xlYXJGYXZVbnNlZW4oKTsKICAgICAgICB9CiAgICAgICAgcmVuZGVy
KCk7CiAgICAgICAgYWhrKCdwaW4nLCBTdHJpbmcoYy5pZCkpOwogICAgfSk7CiAgICBjdHhCaW5k
KCdjLXRvcCcsICAgYyA9PiBhaGsoJ21vdmVUb1RvcCcsICAgICBTdHJpbmcoYy5pZCkpKTsKICAg
IGN0eEJpbmQoJ2MtY2xlYXItcGFzdGVkJywgYyA9PiBhaGsoJ2NsZWFyUGFzdGVkJywgU3RyaW5n
KGMuaWQpKSk7CiAgICBjdHhCaW5kKCdjLXF1ZXVlLWZyb20nLCBjID0+IHsKICAgICAgICBhaGso
J3Jlc2V0UXVldWVGcm9tJywgU3RyaW5nKGMuaWQpKTsKICAgICAgICBpZiAoIXBpbm5lZFVJKSBh
aGsoJ2hpZGUnKTsKICAgIH0pOwogICAgZnVuY3Rpb24gY29sbGVjdFF1ZXVlRW5xdWV1ZUlkcyhz
ZWVkSWRzKSB7CiAgICAgICAgY29uc3Qgc2VlZHMgPSAoc2VlZElkcyB8fCBbXSkubWFwKHggPT4g
K3gpLmZpbHRlcih4ID0+IHggPiAwKTsKICAgICAgICBpZiAoIXNlZWRzLmxlbmd0aCkgcmV0dXJu
IFtdOwogICAgICAgIGNvbnN0IHNlZW4gPSBuZXcgU2V0KCk7CiAgICAgICAgY29uc3Qgc2Vlbkcg
PSBuZXcgU2V0KCk7CiAgICAgICAgY29uc3Qgb3V0ID0gW107CiAgICAgICAgY29uc3QgcHVzaElk
ID0gaWQgPT4gewogICAgICAgICAgICBpZCA9ICtpZDsKICAgICAgICAgICAgaWYgKCFpZCB8fCBz
ZWVuLmhhcyhpZCkpIHJldHVybjsKICAgICAgICAgICAgc2Vlbi5hZGQoaWQpOwogICAgICAgICAg
ICBvdXQucHVzaChpZCk7CiAgICAgICAgfTsKICAgICAgICBjb25zdCBleHBhbmRHID0gZyA9PiB7
CiAgICAgICAgICAgIGcgPSBOdW1iZXIoZykgfHwgMDsKICAgICAgICAgICAgaWYgKGcgPCAxIHx8
IHNlZW5HLmhhcyhnKSkgcmV0dXJuOwogICAgICAgICAgICBzZWVuRy5hZGQoZyk7CiAgICAgICAg
ICAgIGFsbENsaXBzLmZvckVhY2goeCA9PiB7CiAgICAgICAgICAgICAgICBpZiAoTnVtYmVyKHgu
cXVldWVHcm91cCkgPT09IGcpIHB1c2hJZCh4LmlkKTsKICAgICAgICAgICAgfSk7CiAgICAgICAg
fTsKICAgICAgICBzZWVkcy5mb3JFYWNoKGlkID0+IHsKICAgICAgICAgICAgY29uc3QgaXQgPSBh
bGxDbGlwcy5maW5kKHggPT4gK3guaWQgPT09ICtpZCk7CiAgICAgICAgICAgIGNvbnN0IGcgPSBp
dCA/IE51bWJlcihpdC5xdWV1ZUdyb3VwKSB8fCAwIDogMDsKICAgICAgICAgICAgaWYgKGcgPiAw
KSBleHBhbmRHKGcpOwogICAgICAgICAgICBlbHNlIHB1c2hJZChpZCk7CiAgICAgICAgfSk7CiAg
ICAgICAgLy8g5Ye66Zif6aG65bqP77ya5YiX6KGo5LuO5LiL5b6A5LiK77yIYWxsQ2xpcHMg5LiL
5qCH5aSnID0g5pu06Z2g5LiL77yJCiAgICAgICAgY29uc3QgcG9zID0gbmV3IE1hcChhbGxDbGlw
cy5tYXAoKHgsIGkpID0+IFsreC5pZCwgaV0pKTsKICAgICAgICBvdXQuc29ydCgoYSwgYikgPT4g
KHBvcy5nZXQoK2IpID8/IC0xKSAtIChwb3MuZ2V0KCthKSA/PyAtMSkpOwogICAgICAgIHJldHVy
biBvdXQ7CiAgICB9CiAgICBmdW5jdGlvbiBwYWludFF1ZXVlTWV0YUxvY2FsKGlkcykgewogICAg
ICAgIGNvbnN0IGxpc3QgPSAoaWRzIHx8IFtdKS5tYXAoeCA9PiAreCkuZmlsdGVyKHggPT4geCA+
IDApOwogICAgICAgIGlmICghbGlzdC5sZW5ndGgpIHJldHVybjsKICAgICAgICBsZXQgbWF4RyA9
IDA7CiAgICAgICAgYWxsQ2xpcHMuZm9yRWFjaCh4ID0+IHsKICAgICAgICAgICAgY29uc3QgZyA9
IE51bWJlcih4LnF1ZXVlR3JvdXApIHx8IDA7CiAgICAgICAgICAgIGlmIChnID4gbWF4RykgbWF4
RyA9IGc7CiAgICAgICAgfSk7CiAgICAgICAgY29uc3QgZyA9IG1heEcgKyAxOwogICAgICAgIGNv
bnN0IGlkU2V0ID0gbmV3IFNldChsaXN0KTsKICAgICAgICBsaXN0LmZvckVhY2goKGlkLCBpKSA9
PiB7CiAgICAgICAgICAgIGNvbnN0IGl0ID0gYWxsQ2xpcHMuZmluZCh4ID0+ICt4LmlkID09PSBp
ZCk7CiAgICAgICAgICAgIGlmICghaXQpIHJldHVybjsKICAgICAgICAgICAgaXQucXVldWVHcm91
cCA9IGc7CiAgICAgICAgICAgIGl0LnF1ZXVlSW5kZXggPSBpICsgMTsKICAgICAgICAgICAgaXQu
cGFzdGVkID0gZmFsc2U7CiAgICAgICAgfSk7CiAgICAgICAgLy8gRHJvcCBxdWV1ZSB0YWdzIG9u
IHJvd3MgdGhhdCBsZWZ0IHRoaXMgc2Vzc2lvbiB2aXN1YWxseSAoc2FtZSBncm91cCBwYWludCkK
ICAgICAgICB0cnkgewogICAgICAgICAgICB2aWV3TWVtLmZvckVhY2goKGVudHJ5KSA9PiB7CiAg
ICAgICAgICAgICAgICBpZiAoIWVudHJ5IHx8ICFBcnJheS5pc0FycmF5KGVudHJ5Lml0ZW1zKSkg
cmV0dXJuOwogICAgICAgICAgICAgICAgZW50cnkuaXRlbXMuZm9yRWFjaChpdCA9PiB7CiAgICAg
ICAgICAgICAgICAgICAgaWYgKGlkU2V0LmhhcygraXQuaWQpKSB7CiAgICAgICAgICAgICAgICAg
ICAgICAgIGl0LnF1ZXVlR3JvdXAgPSBnOwogICAgICAgICAgICAgICAgICAgICAgICBpdC5xdWV1
ZUluZGV4ID0gbGlzdC5pbmRleE9mKCtpdC5pZCkgKyAxOwogICAgICAgICAgICAgICAgICAgICAg
ICBpdC5wYXN0ZWQgPSBmYWxzZTsKICAgICAgICAgICAgICAgICAgICB9CiAgICAgICAgICAgICAg
ICB9KTsKICAgICAgICAgICAgfSk7CiAgICAgICAgfSBjYXRjaCB7fQogICAgICAgIHRyeSB7IHJl
bmRlcigpOyB9IGNhdGNoIHt9CiAgICAgICAgdHJ5IHsgbWFya1F1ZXVlUmFpbHMoKTsgfSBjYXRj
aCB7fQogICAgfQogICAgY3R4QmluZCgnYy1xdWV1ZS1pbicsIGMgPT4gewogICAgICAgIGxldCBp
ZHMgPSBbXTsKICAgICAgICBpZiAobXVsdGlJZHMubGVuZ3RoID49IDEgJiYgbXVsdGlJZHMuaW5j
bHVkZXMoK2MuaWQpKQogICAgICAgICAgICBpZHMgPSBtdWx0aUlkcy5zbGljZSgpOwogICAgICAg
IGVsc2UKICAgICAgICAgICAgaWRzID0gWytjLmlkXTsKICAgICAgICBpZHMgPSBjb2xsZWN0UXVl
dWVFbnF1ZXVlSWRzKGlkcyk7CiAgICAgICAgaWYgKCFpZHMubGVuZ3RoKSByZXR1cm47CiAgICAg
ICAgcGFpbnRRdWV1ZU1ldGFMb2NhbChpZHMpOwogICAgICAgIGFoaygnZW5xdWV1ZU1hbnknLCBp
ZHMuam9pbignLCcpKTsKICAgICAgICBjbGVhck11bHRpKCk7CiAgICB9KTsKICAgIGN0eEJpbmQo
J2MtcXVldWUtb3V0JywgYyA9PiB7CiAgICAgICAgbGV0IGlkcyA9IFtdOwogICAgICAgIGlmICht
dWx0aUlkcy5sZW5ndGggPj0gMSAmJiBtdWx0aUlkcy5pbmNsdWRlcygrYy5pZCkpCiAgICAgICAg
ICAgIGlkcyA9IG11bHRpSWRzLnNsaWNlKCk7CiAgICAgICAgZWxzZQogICAgICAgICAgICBpZHMg
PSBbK2MuaWRdOwogICAgICAgIGlkcyA9IGlkcy5tYXAoeCA9PiAreCkuZmlsdGVyKHggPT4geCA+
IDApOwogICAgICAgIGlmICghaWRzLmxlbmd0aCkgcmV0dXJuOwogICAgICAgIGNvbnN0IGlkU2V0
ID0gbmV3IFNldChpZHMpOwogICAgICAgIGFsbENsaXBzLmZvckVhY2goaXQgPT4gewogICAgICAg
ICAgICBpZiAoaWRTZXQuaGFzKCtpdC5pZCkpIHsKICAgICAgICAgICAgICAgIGl0LnF1ZXVlR3Jv
dXAgPSAwOwogICAgICAgICAgICAgICAgaXQucXVldWVJbmRleCA9IDA7CiAgICAgICAgICAgIH0K
ICAgICAgICB9KTsKICAgICAgICB0cnkgeyByZW5kZXIoKTsgfSBjYXRjaCB7fQogICAgICAgIHRy
eSB7IG1hcmtRdWV1ZVJhaWxzKCk7IH0gY2F0Y2gge30KICAgICAgICBhaGsoJ2RlcXVldWVNYW55
JywgaWRzLmpvaW4oJywnKSk7CiAgICAgICAgY2xlYXJNdWx0aSgpOwogICAgfSk7CiAgICBjdHhC
aW5kKCdjLWRlbCcsICAgYyA9PiB7CiAgICAgICAgLy8g5aSa6YCJ5LiU5Y+z6ZSu54K55Zyo6YCJ
5Lit6aG55LiKIOKGkiDmibnph4/liKDpmaTvvJvlkKbliJnlj6rliKDlvZPliY0KICAgICAgICBs
ZXQgaWRzID0gW107CiAgICAgICAgaWYgKG11bHRpSWRzLmxlbmd0aCA+IDEgJiYgbXVsdGlJZHMu
aW5jbHVkZXMoK2MuaWQpKQogICAgICAgICAgICBpZHMgPSBtdWx0aUlkcy5zbGljZSgpOwogICAg
ICAgIGVsc2UKICAgICAgICAgICAgaWRzID0gWytjLmlkXTsKICAgICAgICBpZHMgPSBpZHMubWFw
KHggPT4gK3gpLmZpbHRlcih4ID0+IHggPiAwKTsKICAgICAgICBpZiAoIWlkcy5sZW5ndGgpIHJl
dHVybjsKICAgICAgICB0cnkgewogICAgICAgICAgICBjb25zdCBpZFNldCA9IG5ldyBTZXQoaWRz
KTsKICAgICAgICAgICAgYWxsQ2xpcHMgPSBhbGxDbGlwcy5maWx0ZXIoeCA9PiAhaWRTZXQuaGFz
KCt4LmlkKSk7CiAgICAgICAgICAgIGRpc2tUb3RhbCA9IE1hdGgubWF4KDAsIChOdW1iZXIoZGlz
a1RvdGFsKSB8fCAwKSAtIGlkcy5sZW5ndGgpOwogICAgICAgICAgICBpZiAoaWRTZXQuaGFzKCtz
ZWxlY3RlZElkKSkKICAgICAgICAgICAgICAgIHNlbGVjdGVkSWQgPSBhbGxDbGlwcy5sZW5ndGgg
PyBhbGxDbGlwc1swXS5pZCA6IDA7CiAgICAgICAgICAgIGNsZWFyTXVsdGkoKTsKICAgICAgICAg
ICAgcmVuZGVyKCk7CiAgICAgICAgfSBjYXRjaCB7fQogICAgICAgIGlmIChpZHMubGVuZ3RoID09
PSAxKQogICAgICAgICAgICBhaGsoJ2RlbGV0ZScsIFN0cmluZyhpZHNbMF0pKTsKICAgICAgICBl
bHNlCiAgICAgICAgICAgIGFoaygnZGVsZXRlTWFueScsIGlkcy5qb2luKCcsJykpOwogICAgfSk7
CiAgICBjdHhCaW5kKCdjLXRpdGxlJywgYyA9PiBvcGVuVGl0bGVEbGcoYykpOwogICAgY3R4Qmlu
ZCgnYy1tZXJnZScsIGMgPT4gewogICAgICAgIGNvbnN0IGlkcyA9IChtdWx0aUlkcy5sZW5ndGgg
Pj0gMikgPyBtdWx0aUlkcy5zbGljZSgpIDogW107CiAgICAgICAgaWYgKGlkcy5sZW5ndGggPCAy
KSByZXR1cm47CiAgICAgICAgaWYgKCFpZHMuaW5jbHVkZXMoK2MuaWQpKSBpZHMucHVzaCgrYy5p
ZCk7CiAgICAgICAgYWhrKCdtZXJnZUZhdicsIGlkcy5qb2luKCcsJykpOwogICAgICAgIGNsZWFy
TXVsdGkoKTsKICAgIH0pOwogICAgY3R4QmluZCgnYy11bm1lcmdlJywgYyA9PiB7CiAgICAgICAg
YWhrKCd1bm1lcmdlRmF2JywgU3RyaW5nKGMuaWQpKTsKICAgICAgICBjbGVhck11bHRpKCk7CiAg
ICB9KTsKCiAgICBjb25zdCB0aXRsZURsZyA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd0aXRs
ZS1kbGcnKTsKICAgIGNvbnN0IHRpdGxlSW5wdXQgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgn
dGl0bGUtaW5wdXQnKTsKICAgIGxldCB0aXRsZURsZ0NsaXAgPSBudWxsOwogICAgZnVuY3Rpb24g
Y2xvc2VUaXRsZURsZygpIHsKICAgICAgICBpZiAodGl0bGVEbGcpIHRpdGxlRGxnLmNsYXNzTGlz
dC5yZW1vdmUoJ29uJyk7CiAgICAgICAgdGl0bGVEbGdDbGlwID0gbnVsbDsKICAgIH0KICAgIGZ1
bmN0aW9uIGZvY3VzVGl0bGVJbnB1dCgpIHsKICAgICAgICB0cnkgeyBhaGsoJ2ZvY3VzUGFuZWwn
KTsgfSBjYXRjaCB7fQogICAgICAgIHRyeSB7CiAgICAgICAgICAgIGlmICghdGl0bGVJbnB1dCkg
cmV0dXJuOwogICAgICAgICAgICB0aXRsZUlucHV0LmZvY3VzKHsgcHJldmVudFNjcm9sbDogdHJ1
ZSB9KTsKICAgICAgICAgICAgdGl0bGVJbnB1dC5zZWxlY3QoKTsKICAgICAgICB9IGNhdGNoIHsK
ICAgICAgICAgICAgdHJ5IHsgdGl0bGVJbnB1dC5mb2N1cygpOyB0aXRsZUlucHV0LnNlbGVjdCgp
OyB9IGNhdGNoIHt9CiAgICAgICAgfQogICAgfQogICAgZnVuY3Rpb24gb3BlblRpdGxlRGxnKGMp
IHsKICAgICAgICBoaWRlQ3R4KCk7CiAgICAgICAgdGl0bGVEbGdDbGlwID0gYzsKICAgICAgICBp
ZiAodGl0bGVJbnB1dCkgdGl0bGVJbnB1dC52YWx1ZSA9IFN0cmluZyhjLmZhdlRpdGxlIHx8ICcn
KS50cmltKCk7CiAgICAgICAgaWYgKHRpdGxlRGxnKSB0aXRsZURsZy5jbGFzc0xpc3QuYWRkKCdv
bicpOwogICAgICAgIGZvY3VzVGl0bGVJbnB1dCgpOwogICAgICAgIHJlcXVlc3RBbmltYXRpb25G
cmFtZShmb2N1c1RpdGxlSW5wdXQpOwogICAgICAgIHNldFRpbWVvdXQoZm9jdXNUaXRsZUlucHV0
LCA0MCk7CiAgICAgICAgc2V0VGltZW91dChmb2N1c1RpdGxlSW5wdXQsIDEyMCk7CiAgICB9CiAg
ICBpZiAodGl0bGVJbnB1dCkgewogICAgICAgIHRpdGxlSW5wdXQuYWRkRXZlbnRMaXN0ZW5lcign
bW91c2Vkb3duJywgZSA9PiB7CiAgICAgICAgICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAg
ICAgICAgIHRyeSB7IGFoaygnZm9jdXNQYW5lbCcpOyB9IGNhdGNoIHt9CiAgICAgICAgfSk7CiAg
ICAgICAgdGl0bGVJbnB1dC5hZGRFdmVudExpc3RlbmVyKCdmb2N1cycsICgpID0+IHsKICAgICAg
ICAgICAgdHJ5IHsgYWhrKCdmb2N1c1BhbmVsJyk7IH0gY2F0Y2gge30KICAgICAgICB9KTsKICAg
IH0KICAgIGlmICh0aXRsZURsZykgewogICAgICAgIHRpdGxlRGxnLmFkZEV2ZW50TGlzdGVuZXIo
J2NsaWNrJywgZSA9PiB7CiAgICAgICAgICAgIGlmIChlLnRhcmdldCA9PT0gdGl0bGVEbGcpIHsK
ICAgICAgICAgICAgICAgIGNsb3NlVGl0bGVEbGcoKTsKICAgICAgICAgICAgICAgIHRyeSB7IGFo
aygnYmx1clBhbmVsJyk7IH0gY2F0Y2gge30KICAgICAgICAgICAgfQogICAgICAgIH0pOwogICAg
ICAgIHRpdGxlRGxnLmFkZEV2ZW50TGlzdGVuZXIoJ21vdXNlZG93bicsIGUgPT4gZS5zdG9wUHJv
cGFnYXRpb24oKSk7CiAgICB9CiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgndGl0bGUtY2Fu
Y2VsJyk/LmFkZEV2ZW50TGlzdGVuZXIoJ2NsaWNrJywgZSA9PiB7CiAgICAgICAgZS5zdG9wUHJv
cGFnYXRpb24oKTsKICAgICAgICBjbG9zZVRpdGxlRGxnKCk7CiAgICAgICAgYWhrKCdibHVyUGFu
ZWwnKTsKICAgIH0pOwogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3RpdGxlLW9rJyk/LmFk
ZEV2ZW50TGlzdGVuZXIoJ2NsaWNrJywgZSA9PiB7CiAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24o
KTsKICAgICAgICBpZiAoIXRpdGxlRGxnQ2xpcCkgcmV0dXJuOwogICAgICAgIGNvbnN0IHQgPSBT
dHJpbmcodGl0bGVJbnB1dD8udmFsdWUgfHwgJycpLnRyaW0oKS5zbGljZSgwLCA4MCk7CiAgICAg
ICAgY29uc3QgaWQgPSBTdHJpbmcodGl0bGVEbGdDbGlwLmlkKTsKICAgICAgICAvLyBPcHRpbWlz
dGljIGxvY2FsIHVwZGF0ZQogICAgICAgIGNvbnN0IGhpdCA9IGFsbENsaXBzLmZpbmQoeCA9PiAr
eC5pZCA9PT0gK2lkKTsKICAgICAgICBpZiAoaGl0KSBoaXQuZmF2VGl0bGUgPSB0OwogICAgICAg
IHRpdGxlRGxnQ2xpcC5mYXZUaXRsZSA9IHQ7CiAgICAgICAgY2xvc2VUaXRsZURsZygpOwogICAg
ICAgIGFoaygnc2V0RmF2VGl0bGUnLCBpZCwgdCk7CiAgICAgICAgYWhrKCdibHVyUGFuZWwnKTsK
ICAgICAgICByZW5kZXIoKTsKICAgIH0pOwogICAgdGl0bGVJbnB1dD8uYWRkRXZlbnRMaXN0ZW5l
cigna2V5ZG93bicsIGUgPT4gewogICAgICAgIGlmIChlLmtleSA9PT0gJ0VudGVyJykgewogICAg
ICAgICAgICBlLnByZXZlbnREZWZhdWx0KCk7CiAgICAgICAgICAgIGUuc3RvcFByb3BhZ2F0aW9u
KCk7CiAgICAgICAgICAgIGUuc3RvcEltbWVkaWF0ZVByb3BhZ2F0aW9uKCk7CiAgICAgICAgICAg
IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd0aXRsZS1vaycpPy5jbGljaygpOwogICAgICAgICAg
ICByZXR1cm47CiAgICAgICAgfQogICAgICAgIGlmIChlLmtleSA9PT0gJ0VzY2FwZScpIHsKICAg
ICAgICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOwogICAgICAgICAgICBlLnN0b3BQcm9wYWdhdGlv
bigpOwogICAgICAgICAgICBjbG9zZVRpdGxlRGxnKCk7CiAgICAgICAgICAgIGFoaygnYmx1clBh
bmVsJyk7CiAgICAgICAgICAgIHJldHVybjsKICAgICAgICB9CiAgICAgICAgZS5zdG9wUHJvcGFn
YXRpb24oKTsKICAgIH0sIHRydWUpOwoKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd0YWJz
JykuYWRkRXZlbnRMaXN0ZW5lcignY2xpY2snLCBlID0+IHsKICAgICAgICBjb25zdCB0YWIgPSBl
LnRhcmdldC5jbG9zZXN0KCcudGFiJyk7CiAgICAgICAgaWYgKCF0YWIgfHwgZS50YXJnZXQuY2xv
c2VzdCgnI3RhYi1hY3Rpb25zJykpIHJldHVybjsKICAgICAgICBzZXRUYWIodGFiLmRhdGFzZXQu
dGFiKTsKICAgIH0pOwoKICAgIGNvbnN0IHNyY2hXcmFwID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5
SWQoJ3NlYXJjaC13cmFwJyk7CiAgICBjb25zdCBidG5TZWFyY2ggPSBkb2N1bWVudC5nZXRFbGVt
ZW50QnlJZCgnYnRuLXNlYXJjaCcpOwogICAgY29uc3QgYnRuTG9jYXRlID0gZG9jdW1lbnQuZ2V0
RWxlbWVudEJ5SWQoJ2J0bi1sb2NhdGUnKTsKICAgIGNvbnN0IGJ0blRvZGF5ID0gZG9jdW1lbnQu
Z2V0RWxlbWVudEJ5SWQoJ2J0bi10b2RheScpOwogICAgY29uc3Qgc3JjaCA9IGRvY3VtZW50Lmdl
dEVsZW1lbnRCeUlkKCdzZWFyY2gnKTsKICAgIGNvbnN0IHNjbHIgPSBkb2N1bWVudC5nZXRFbGVt
ZW50QnlJZCgnc2VhcmNoLWNscicpOwogICAgbGV0IGRlYjsKCiAgICB1cGRhdGVMb2NhdGVCdG4o
KTsKICAgIGlmIChidG5Mb2NhdGUpIHsKICAgICAgICBidG5Mb2NhdGUuYWRkRXZlbnRMaXN0ZW5l
cignY2xpY2snLCBlID0+IHsKICAgICAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAg
ICAgICAganVtcFRvTGFzdFBhc3RlKCk7CiAgICAgICAgfSk7CiAgICB9CgogICAgYnRuVG9kYXku
YWRkRXZlbnRMaXN0ZW5lcignbW91c2Vkb3duJywgZSA9PiB7CiAgICAgICAgZS5wcmV2ZW50RGVm
YXVsdCgpOwogICAgICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICB9KTsKICAgIGJ0blRvZGF5
LmFkZEV2ZW50TGlzdGVuZXIoJ2NsaWNrJywgZSA9PiB7CiAgICAgICAgZS5zdG9wUHJvcGFnYXRp
b24oKTsKICAgICAgICBlLnByZXZlbnREZWZhdWx0KCk7CiAgICAgICAgdG9kYXlPbmx5ID0gIXRv
ZGF5T25seTsKICAgICAgICBidG5Ub2RheS5jbGFzc0xpc3QudG9nZ2xlKCdvbicsIHRvZGF5T25s
eSk7CiAgICAgICAgbGlzdEVsLnNjcm9sbFRvcCA9IDA7CiAgICAgICAgcmVxdWVzdFZpZXcoKTsK
ICAgICAgICB0cnkgeyBzcmNoLmZvY3VzKCk7IH0gY2F0Y2gge30KICAgIH0pOwoKICAgIGZ1bmN0
aW9uIG9wZW5TZWFyY2goKSB7CiAgICAgICAgaWYgKHNyY2hXcmFwLmNsYXNzTGlzdC5jb250YWlu
cygnb3BlbicpKSB7CiAgICAgICAgICAgIGFoaygnZm9jdXNQYW5lbCcpOwogICAgICAgICAgICB0
cnkgeyBzcmNoLmZvY3VzKCk7IH0gY2F0Y2gge30KICAgICAgICAgICAgcmV0dXJuOwogICAgICAg
IH0KICAgICAgICBzcmNoV3JhcC5jbGFzc0xpc3QuYWRkKCdvcGVuJyk7CiAgICAgICAgLy8gRGVm
YXVsdDog5omA5pyJ6aG15omT5byA5pCc57Si5pe26buY6K6k5pCc5YWo6YOoCiAgICAgICAgY29u
c3Qgd2FudFRvZGF5ID0gZmFsc2U7CiAgICAgICAgaWYgKHRvZGF5T25seSAhPT0gd2FudFRvZGF5
KSB7CiAgICAgICAgICAgIHRvZGF5T25seSA9IHdhbnRUb2RheTsKICAgICAgICAgICAgYnRuVG9k
YXkuY2xhc3NMaXN0LnRvZ2dsZSgnb24nLCB0b2RheU9ubHkpOwogICAgICAgICAgICBsaXN0RWwu
c2Nyb2xsVG9wID0gMDsKICAgICAgICAgICAgcmVxdWVzdFZpZXcoKTsKICAgICAgICB9IGVsc2Ug
ewogICAgICAgICAgICBidG5Ub2RheS5jbGFzc0xpc3QudG9nZ2xlKCdvbicsIHRvZGF5T25seSk7
CiAgICAgICAgfQogICAgICAgIGFoaygnZm9jdXNQYW5lbCcpOwogICAgICAgIHJlcXVlc3RBbmlt
YXRpb25GcmFtZSgoKSA9PiB7CiAgICAgICAgICAgIHRyeSB7IHNyY2guZm9jdXMoKTsgfSBjYXRj
aCB7fQogICAgICAgIH0pOwogICAgfQogICAgZnVuY3Rpb24gY2xvc2VTZWFyY2hVaSgpIHsKICAg
ICAgICBzcmNoV3JhcC5jbGFzc0xpc3QucmVtb3ZlKCdvcGVuJyk7CiAgICAgICAgaWYgKCFzcmNo
LnZhbHVlKSB7CiAgICAgICAgICAgIHNyY2guY2xhc3NMaXN0LnJlbW92ZSgnaGFzLXZhbCcpOwog
ICAgICAgICAgICBzY2xyLnN0eWxlLmRpc3BsYXkgPSAnbm9uZSc7CiAgICAgICAgICAgIC8vIExl
YXZpbmcgc2VhcmNoIHdpdGggZW1wdHkgcXVlcnkg4oaSIGRyb3AgdG9kYXkgZmlsdGVyCiAgICAg
ICAgICAgIGlmICh0b2RheU9ubHkpIHsKICAgICAgICAgICAgICAgIHRvZGF5T25seSA9IGZhbHNl
OwogICAgICAgICAgICAgICAgYnRuVG9kYXkuY2xhc3NMaXN0LnJlbW92ZSgnb24nKTsKICAgICAg
ICAgICAgICAgIHJlcXVlc3RWaWV3KCk7CiAgICAgICAgICAgIH0KICAgICAgICB9CiAgICB9CiAg
ICB3aW5kb3cuX19vcGVuU2VhcmNoID0gb3BlblNlYXJjaDsKICAgIHdpbmRvdy5fX3ByZXBUeXBl
U2VhcmNoID0gKCkgPT4gewogICAgICAgIHRyeSB7CiAgICAgICAgICAgIGNvbnN0IHdyYXAgPSBk
b2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc2VhcmNoLXdyYXAnKTsKICAgICAgICAgICAgY29uc3Qg
cyA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzZWFyY2gnKTsKICAgICAgICAgICAgaWYgKHdy
YXAgJiYgIXdyYXAuY2xhc3NMaXN0LmNvbnRhaW5zKCdvcGVuJykpIHsKICAgICAgICAgICAgICAg
IHdyYXAuY2xhc3NMaXN0LmFkZCgnb3BlbicpOwogICAgICAgICAgICAgICAgdHJ5IHsKICAgICAg
ICAgICAgICAgICAgICBjb25zdCB3YW50VG9kYXkgPSBmYWxzZTsKICAgICAgICAgICAgICAgICAg
ICBpZiAodHlwZW9mIHRvZGF5T25seSAhPT0gJ3VuZGVmaW5lZCcgJiYgdG9kYXlPbmx5ICE9PSB3
YW50VG9kYXkpIHsKICAgICAgICAgICAgICAgICAgICAgICAgdG9kYXlPbmx5ID0gd2FudFRvZGF5
OwogICAgICAgICAgICAgICAgICAgICAgICBpZiAodHlwZW9mIGJ0blRvZGF5ICE9PSAndW5kZWZp
bmVkJyAmJiBidG5Ub2RheSkgYnRuVG9kYXkuY2xhc3NMaXN0LnRvZ2dsZSgnb24nLCB0b2RheU9u
bHkpOwogICAgICAgICAgICAgICAgICAgICAgICBpZiAodHlwZW9mIGxpc3RFbCAhPT0gJ3VuZGVm
aW5lZCcgJiYgbGlzdEVsKSBsaXN0RWwuc2Nyb2xsVG9wID0gMDsKICAgICAgICAgICAgICAgICAg
ICAgICAgaWYgKHR5cGVvZiByZXF1ZXN0VmlldyA9PT0gJ2Z1bmN0aW9uJykgc2V0VGltZW91dChy
ZXF1ZXN0VmlldywgMCk7CiAgICAgICAgICAgICAgICAgICAgfSBlbHNlIGlmICh0eXBlb2YgYnRu
VG9kYXkgIT09ICd1bmRlZmluZWQnICYmIGJ0blRvZGF5KSB7CiAgICAgICAgICAgICAgICAgICAg
ICAgIGJ0blRvZGF5LmNsYXNzTGlzdC50b2dnbGUoJ29uJywgISF0b2RheU9ubHkpOwogICAgICAg
ICAgICAgICAgICAgIH0KICAgICAgICAgICAgICAgIH0gY2F0Y2gge30KICAgICAgICAgICAgfQog
ICAgICAgICAgICAvLyA/PyDplZzlg4/mkJzntKLvvJrkuI3opoEgZm9jdXPvvIzpgb/lhY3miqLo
tbDljp/nvJbovpHmoYblhYnmoIcKICAgICAgICB9IGNhdGNoIHt9CiAgICB9OwogICAgd2luZG93
Ll9fdHlwZVNlYXJjaCA9IChjaCkgPT4gewogICAgICAgIHRyeSB7CiAgICAgICAgICAgIHdpbmRv
dy5fX3ByZXBUeXBlU2VhcmNoICYmIHdpbmRvdy5fX3ByZXBUeXBlU2VhcmNoKCk7CiAgICAgICAg
ICAgIGNvbnN0IHMgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc2VhcmNoJyk7CiAgICAgICAg
ICAgIGlmICghcykgcmV0dXJuOwogICAgICAgICAgICBzLnZhbHVlID0gU3RyaW5nKHMudmFsdWUg
fHwgJycpICsgU3RyaW5nKGNoID09IG51bGwgPyAnJyA6IGNoKTsKICAgICAgICAgICAgcy5jbGFz
c0xpc3QudG9nZ2xlKCdoYXMtdmFsJywgISFzLnZhbHVlKTsKICAgICAgICAgICAgcy5kaXNwYXRj
aEV2ZW50KG5ldyBFdmVudCgnaW5wdXQnLCB7IGJ1YmJsZXM6IHRydWUgfSkpOwogICAgICAgIH0g
Y2F0Y2gge30KICAgIH07CiAgICB3aW5kb3cuX19ia3NwU2VhcmNoID0gKCkgPT4gewogICAgICAg
IHRyeSB7CiAgICAgICAgICAgIHdpbmRvdy5fX3ByZXBUeXBlU2VhcmNoICYmIHdpbmRvdy5fX3By
ZXBUeXBlU2VhcmNoKCk7CiAgICAgICAgICAgIGNvbnN0IHMgPSBkb2N1bWVudC5nZXRFbGVtZW50
QnlJZCgnc2VhcmNoJyk7CiAgICAgICAgICAgIGlmICghcykgcmV0dXJuOwogICAgICAgICAgICBj
b25zdCB2ID0gU3RyaW5nKHMudmFsdWUgfHwgJycpOwogICAgICAgICAgICBzLnZhbHVlID0gdi5s
ZW5ndGggPyB2LnNsaWNlKDAsIC0xKSA6ICcnOwogICAgICAgICAgICBzLmNsYXNzTGlzdC50b2dn
bGUoJ2hhcy12YWwnLCAhIXMudmFsdWUpOwogICAgICAgICAgICBzLmRpc3BhdGNoRXZlbnQobmV3
IEV2ZW50KCdpbnB1dCcsIHsgYnViYmxlczogdHJ1ZSB9KSk7CiAgICAgICAgfSBjYXRjaCB7fQog
ICAgfTsKICAgIHdpbmRvdy5fX3NldFNlYXJjaFF1ZXJ5ID0gKHEpID0+IHsKICAgICAgICB0cnkg
ewogICAgICAgICAgICBjb25zdCBzID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NlYXJjaCcp
OwogICAgICAgICAgICBpZiAoIXMpIHJldHVybjsKICAgICAgICAgICAgY29uc3QgbmV4dCA9IFN0
cmluZyhxID09IG51bGwgPyAnJyA6IHEpOwogICAgICAgICAgICBjb25zdCBwcmV2ID0gU3RyaW5n
KHMudmFsdWUgfHwgJycpOwogICAgICAgICAgICAvLyDlkIzlhbPplK7lrZfph43lpI3mjqjpgIHv
vJrlj6rkv53or4HmkJzntKLmoYblvIDnnYDvvIznpoHmraLlho0gcmVxdWVzdFZpZXfvvIjkvJrm
rbvlvqrnjq/pl6rvvIkKICAgICAgICAgICAgaWYgKHByZXYgPT09IG5leHQgJiYgU3RyaW5nKHF1
ZXJ5IHx8ICcnKSA9PT0gbmV4dCkgewogICAgICAgICAgICAgICAgdHJ5IHsKICAgICAgICAgICAg
ICAgICAgICBjb25zdCB3cmFwID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NlYXJjaC13cmFw
Jyk7CiAgICAgICAgICAgICAgICAgICAgaWYgKHdyYXAgJiYgIXdyYXAuY2xhc3NMaXN0LmNvbnRh
aW5zKCdvcGVuJykpCiAgICAgICAgICAgICAgICAgICAgICAgIHdyYXAuY2xhc3NMaXN0LmFkZCgn
b3BlbicpOwogICAgICAgICAgICAgICAgfSBjYXRjaCB7fQogICAgICAgICAgICAgICAgcmV0dXJu
OwogICAgICAgICAgICB9CiAgICAgICAgICAgIC8vIOaJk+Wtl+WNs+aXtuS4iuWxj++8jOS4juej
geebmOaQnOe0ouino+iApgogICAgICAgICAgICBzLnZhbHVlID0gbmV4dDsKICAgICAgICAgICAg
cy5jbGFzc0xpc3QudG9nZ2xlKCdoYXMtdmFsJywgISFzLnZhbHVlKTsKICAgICAgICAgICAgY29u
c3Qgc2NsciA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzZWFyY2gtY2xyJyk7CiAgICAgICAg
ICAgIGlmIChzY2xyKSBzY2xyLnN0eWxlLmRpc3BsYXkgPSBzLnZhbHVlID8gJ2Jsb2NrJyA6ICdu
b25lJzsKICAgICAgICAgICAgcXVlcnkgPSBzLnZhbHVlOwogICAgICAgICAgICB0cnkgewogICAg
ICAgICAgICAgICAgY29uc3Qgd3JhcCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzZWFyY2gt
d3JhcCcpOwogICAgICAgICAgICAgICAgaWYgKHdyYXAgJiYgIXdyYXAuY2xhc3NMaXN0LmNvbnRh
aW5zKCdvcGVuJykpCiAgICAgICAgICAgICAgICAgICAgd2luZG93Ll9fcHJlcFR5cGVTZWFyY2gg
JiYgd2luZG93Ll9fcHJlcFR5cGVTZWFyY2goKTsKICAgICAgICAgICAgICAgIGVsc2UgaWYgKHdy
YXApCiAgICAgICAgICAgICAgICAgICAgd3JhcC5jbGFzc0xpc3QuYWRkKCdvcGVuJyk7CiAgICAg
ICAgICAgIH0gY2F0Y2gge30KICAgICAgICAgICAgd2luZG93Ll9faG9zdEZpbHRlcmVkID0gZmFs
c2U7CiAgICAgICAgICAgIHdpbmRvdy5fX2hvc3RGaWx0ZXJRID0gJyc7CiAgICAgICAgICAgIGlm
IChTdHJpbmcocXVlcnkgfHwgJycpLnRyaW0oKSkgewogICAgICAgICAgICAgICAgd2FpdGluZ0Rh
dGEgPSB0cnVlOwogICAgICAgICAgICAgICAgd2luZG93Ll9fZGF0YVJlYWR5ID0gZmFsc2U7CiAg
ICAgICAgICAgIH0KICAgICAgICAgICAgdHJ5IHsKICAgICAgICAgICAgICAgIGNvbnN0IGNudCA9
IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdiYXItdHh0Jyk7CiAgICAgICAgICAgICAgICBpZiAo
Y250ICYmIFN0cmluZyhxdWVyeSB8fCAnJykudHJpbSgpKQogICAgICAgICAgICAgICAgICAgIGNu
dC50ZXh0Q29udGVudCA9IHZpc2libGVMaXN0KCkubGVuZ3RoICsgJyDmnaEnOwogICAgICAgICAg
ICB9IGNhdGNoIHt9CiAgICAgICAgICAgIHRyeSB7IHJlbmRlcigpOyB9IGNhdGNoIHt9CiAgICAg
ICAgICAgIGNsZWFyVGltZW91dCh3aW5kb3cuX19xcVZpZXdEZWIpOwogICAgICAgICAgICB3aW5k
b3cuX19xcVZpZXdEZWIgPSBzZXRUaW1lb3V0KCgpID0+IHsKICAgICAgICAgICAgICAgIHdpbmRv
dy5fX3FxVmlld0RlYiA9IDA7CiAgICAgICAgICAgICAgICByZXF1ZXN0VmlldygpOwogICAgICAg
ICAgICB9LCA3MCk7CiAgICAgICAgfSBjYXRjaCB7fQogICAgfTsKICAgIHdpbmRvdy5fX2NsZWFy
UVFTZWFyY2ggPSAoKSA9PiB7CiAgICAgICAgdHJ5IHsKICAgICAgICAgICAgcXVlcnkgPSAnJzsK
ICAgICAgICAgICAgd2luZG93Ll9faG9zdEZpbHRlcmVkID0gZmFsc2U7CiAgICAgICAgICAgIHdp
bmRvdy5fX2hvc3RGaWx0ZXJRID0gJyc7CiAgICAgICAgICAgIGNvbnN0IHMgPSBkb2N1bWVudC5n
ZXRFbGVtZW50QnlJZCgnc2VhcmNoJyk7CiAgICAgICAgICAgIGlmIChzKSB7CiAgICAgICAgICAg
ICAgICBzLnZhbHVlID0gJyc7CiAgICAgICAgICAgICAgICBzLmNsYXNzTGlzdC5yZW1vdmUoJ2hh
cy12YWwnKTsKICAgICAgICAgICAgICAgIHRyeSB7IHMuYmx1cigpOyB9IGNhdGNoIHt9CiAgICAg
ICAgICAgIH0KICAgICAgICAgICAgY29uc3Qgc2NsciA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlk
KCdzZWFyY2gtY2xyJyk7CiAgICAgICAgICAgIGlmIChzY2xyKSBzY2xyLnN0eWxlLmRpc3BsYXkg
PSAnbm9uZSc7CiAgICAgICAgICAgIGNvbnN0IHdyYXAgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJ
ZCgnc2VhcmNoLXdyYXAnKTsKICAgICAgICAgICAgaWYgKHdyYXApIHdyYXAuY2xhc3NMaXN0LnJl
bW92ZSgnb3BlbicpOwogICAgICAgICAgICB0cnkgeyByZW5kZXIoKTsgfSBjYXRjaCB7fQogICAg
ICAgIH0gY2F0Y2gge30KICAgIH07CiAgICAvLyBDYXB0dXJlIEN0cmwrRiBpbnNpZGUgV2ViVmll
dyAoQ2hyb21pdW0gZmluZCBpcyBkaXNhYmxlZCwgYnV0IHN0aWxsIGhhbmRsZSBoZXJlKQogICAg
ZG9jdW1lbnQuYWRkRXZlbnRMaXN0ZW5lcigna2V5ZG93bicsIGUgPT4gewogICAgICAgIGlmICgo
ZS5jdHJsS2V5IHx8IGUubWV0YUtleSkgJiYgIWUuYWx0S2V5ICYmIChlLmtleSA9PT0gJ2YnIHx8
IGUua2V5ID09PSAnRicpKSB7CiAgICAgICAgICAgIGUucHJldmVudERlZmF1bHQoKTsKICAgICAg
ICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICAgICAgb3BlblNlYXJjaCgpOwogICAg
ICAgIH0KICAgIH0sIHRydWUpOwogICAgYnRuU2VhcmNoLmFkZEV2ZW50TGlzdGVuZXIoJ2NsaWNr
JywgZSA9PiB7CiAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICBvcGVuU2VhcmNo
KCk7CiAgICB9KTsKICAgIGxldCBfX3NyY2hDb21wb3NpbmcgPSBmYWxzZTsKICAgIGNvbnN0IF9f
Zmx1c2hTZWFyY2hJbnB1dCA9ICgpID0+IHsKICAgICAgICBxdWVyeSA9IHNyY2gudmFsdWU7CiAg
ICAgICAgc3JjaC5jbGFzc0xpc3QudG9nZ2xlKCdoYXMtdmFsJywgISFxdWVyeSk7CiAgICAgICAg
c2Nsci5zdHlsZS5kaXNwbGF5ID0gcXVlcnkgPyAnYmxvY2snIDogJ25vbmUnOwogICAgICAgIGxp
c3RFbC5zY3JvbGxUb3AgPSAwOwogICAgICAgIHdpbmRvdy5fX2hvc3RGaWx0ZXJlZCA9IGZhbHNl
OwogICAgICAgIHdpbmRvdy5fX2hvc3RGaWx0ZXJRID0gJyc7CiAgICAgICAgdHJ5IHsgcmVuZGVy
KCk7IH0gY2F0Y2gge30KICAgICAgICBjbGVhclRpbWVvdXQoZGViKTsKICAgICAgICBkZWIgPSBz
ZXRUaW1lb3V0KHJlcXVlc3RWaWV3LCA4MCk7CiAgICB9OwogICAgc3JjaC5hZGRFdmVudExpc3Rl
bmVyKCdjb21wb3NpdGlvbnN0YXJ0JywgKCkgPT4geyBfX3NyY2hDb21wb3NpbmcgPSB0cnVlOyB9
KTsKICAgIHNyY2guYWRkRXZlbnRMaXN0ZW5lcignY29tcG9zaXRpb25lbmQnLCAoKSA9PiB7CiAg
ICAgICAgX19zcmNoQ29tcG9zaW5nID0gZmFsc2U7CiAgICAgICAgX19mbHVzaFNlYXJjaElucHV0
KCk7CiAgICB9KTsKICAgIHNyY2guYWRkRXZlbnRMaXN0ZW5lcignaW5wdXQnLCAoKSA9PiB7CiAg
ICAgICAgaWYgKF9fc3JjaENvbXBvc2luZykgewogICAgICAgICAgICBxdWVyeSA9IHNyY2gudmFs
dWU7CiAgICAgICAgICAgIHNyY2guY2xhc3NMaXN0LnRvZ2dsZSgnaGFzLXZhbCcsICEhcXVlcnkp
OwogICAgICAgICAgICBzY2xyLnN0eWxlLmRpc3BsYXkgPSBxdWVyeSA/ICdibG9jaycgOiAnbm9u
ZSc7CiAgICAgICAgICAgIHJldHVybjsKICAgICAgICB9CiAgICAgICAgX19mbHVzaFNlYXJjaElu
cHV0KCk7CiAgICB9KTsKICAgIHNyY2guYWRkRXZlbnRMaXN0ZW5lcignZm9jdXMnLCAoKSA9PiB7
CiAgICAgICAgLy8gSWRlbXBvdGVudCBvbiBBSEsgc2lkZSDigJQgc2FmZSwgYnV0IGF2b2lkIHNw
YW1taW5nIGR1cmluZyBJTUUKICAgICAgICB0cnkgeyBhaGsoJ2ZvY3VzUGFuZWwnKTsgfSBjYXRj
aCB7fQogICAgfSk7CiAgICBzcmNoLmFkZEV2ZW50TGlzdGVuZXIoJ2JsdXInLCAoKSA9PiB7CiAg
ICAgICAgc2V0VGltZW91dCgoKSA9PiB7CiAgICAgICAgICAgIGlmIChkb2N1bWVudC5hY3RpdmVF
bGVtZW50ID09PSBzcmNoKSByZXR1cm47CiAgICAgICAgICAgIGlmIChkb2N1bWVudC5hY3RpdmVF
bGVtZW50ID09PSBzY2xyIHx8IChzY2xyICYmIHNjbHIuY29udGFpbnMoZG9jdW1lbnQuYWN0aXZl
RWxlbWVudCkpKSByZXR1cm47CiAgICAgICAgICAgIGlmIChkb2N1bWVudC5hY3RpdmVFbGVtZW50
ID09PSBidG5Ub2RheSB8fCAoYnRuVG9kYXkgJiYgYnRuVG9kYXkuY29udGFpbnMoZG9jdW1lbnQu
YWN0aXZlRWxlbWVudCkpKSByZXR1cm47CiAgICAgICAgICAgIC8vIElNRSBjYW5kaWRhdGUgVUkg
c3RlYWxzIGZvY3VzIGJyaWVmbHkg4oCUIGtlZXAgc2VhcmNoIGlmIHN0aWxsIGNvbXBvc2luZwog
ICAgICAgICAgICBpZiAoX19zcmNoQ29tcG9zaW5nKSByZXR1cm47CiAgICAgICAgICAgIGNsb3Nl
U2VhcmNoVWkoKTsKICAgICAgICAgICAgYWhrKCdibHVyUGFuZWwnKTsKICAgICAgICB9LCAyODAp
OwogICAgfSk7CiAgICBzcmNoLmFkZEV2ZW50TGlzdGVuZXIoJ2tleWRvd24nLCBlID0+IHsKICAg
ICAgICAvLyBDdHJsK0kgLyBDdHJsK0s6IG1vdmUgY2xpcCBzZWxlY3Rpb24gKG5vdCBpbnNlcnQg
Y2hhciAvIGJyb3dzZXIgc2hvcnRjdXQpCiAgICAgICAgaWYgKChlLmN0cmxLZXkgfHwgZS5tZXRh
S2V5KSAmJiAoZS5rZXkgPT09ICdpJyB8fCBlLmtleSA9PT0gJ0knKSkgewogICAgICAgICAgICBl
LnByZXZlbnREZWZhdWx0KCk7CiAgICAgICAgICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAg
ICAgICAgIHdpbmRvdy5fX25hdiAmJiB3aW5kb3cuX19uYXYoJ3VwJyk7CiAgICAgICAgICAgIHJl
dHVybjsKICAgICAgICB9CiAgICAgICAgaWYgKChlLmN0cmxLZXkgfHwgZS5tZXRhS2V5KSAmJiAo
ZS5rZXkgPT09ICdrJyB8fCBlLmtleSA9PT0gJ0snKSkgewogICAgICAgICAgICBlLnByZXZlbnRE
ZWZhdWx0KCk7CiAgICAgICAgICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAgICAgICAgIHdp
bmRvdy5fX25hdiAmJiB3aW5kb3cuX19uYXYoJ2Rvd24nKTsKICAgICAgICAgICAgcmV0dXJuOwog
ICAgICAgIH0KICAgICAgICBpZiAoZS5rZXkgPT09ICdBcnJvd0Rvd24nKSB7CiAgICAgICAgICAg
IGUucHJldmVudERlZmF1bHQoKTsKICAgICAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAg
ICAgICAgICAgd2luZG93Ll9fbmF2ICYmIHdpbmRvdy5fX25hdignZG93bicpOwogICAgICAgICAg
ICByZXR1cm47CiAgICAgICAgfQogICAgICAgIGlmIChlLmtleSA9PT0gJ0Fycm93VXAnKSB7CiAg
ICAgICAgICAgIGUucHJldmVudERlZmF1bHQoKTsKICAgICAgICAgICAgZS5zdG9wUHJvcGFnYXRp
b24oKTsKICAgICAgICAgICAgd2luZG93Ll9fbmF2ICYmIHdpbmRvdy5fX25hdigndXAnKTsKICAg
ICAgICAgICAgcmV0dXJuOwogICAgICAgIH0KICAgICAgICBpZiAoZS5rZXkgPT09ICdFc2NhcGUn
KSB7CiAgICAgICAgICAgIGUucHJldmVudERlZmF1bHQoKTsKICAgICAgICAgICAgZS5zdG9wUHJv
cGFnYXRpb24oKTsKICAgICAgICAgICAgLy8gQWx3YXlzIGRpc21pc3MgdGhlIHdob2xlIHBhbmVs
IChub3QganVzdCB0aGUgc2VhcmNoIGZpZWxkKQogICAgICAgICAgICBpZiAoIXBpbm5lZFVJKSBh
aGsoJ2hpZGUnKTsKICAgICAgICAgICAgcmV0dXJuOwogICAgICAgIH0KICAgICAgICBlLnN0b3BQ
cm9wYWdhdGlvbigpOwogICAgfSk7CiAgICBzY2xyLmFkZEV2ZW50TGlzdGVuZXIoJ2NsaWNrJywg
ZSA9PiB7CiAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICBzcmNoLnZhbHVlID0g
cXVlcnkgPSAnJzsKICAgICAgICBzY2xyLnN0eWxlLmRpc3BsYXkgPSAnbm9uZSc7CiAgICAgICAg
c3JjaC5jbGFzc0xpc3QucmVtb3ZlKCdoYXMtdmFsJyk7CiAgICAgICAgcmVxdWVzdFZpZXcoKTsK
ICAgICAgICBhaGsoJ2ZvY3VzUGFuZWwnKTsKICAgICAgICBzcmNoLmZvY3VzKCk7CiAgICB9KTsK
CiAgICBjb25zdCBUQUJfTkFNRVMgPSB7IGFsbDogJ+WFqOmDqCcsIHRleHQ6ICfmlofmnKwnLCBp
bWFnZTogJ+WbvuWDjycsIGZpbGU6ICfmlofku7YnLCByZWNlbnQ6ICfmnIDov5EnLCBwaW5uZWQ6
ICfmlLbol48nIH07CiAgICBjb25zdCBjbHJEbGcgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgn
Y2xyLWRsZycpOwogICAgY29uc3QgY2xyQWxsQ2IgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgn
Y2xyLWFsbCcpOwogICAgZnVuY3Rpb24gb3BlbkNsZWFyRGxnKCkgewogICAgICAgIGNvbnN0IG5h
bWUgPSBUQUJfTkFNRVNbY3VyVGFiXSB8fCAn5b2T5YmNJzsKICAgICAgICBkb2N1bWVudC5nZXRF
bGVtZW50QnlJZCgnY2xyLXRpdGxlJykudGV4dENvbnRlbnQgPSAn5riF56m644CMJyArIG5hbWUg
KyAn44CN77yfJzsKICAgICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnY2xyLWRlc2MnKS50
ZXh0Q29udGVudCA9IGN1clRhYiA9PT0gJ3Bpbm5lZCcKICAgICAgICAgICAgPyAn6buY6K6k5LuF
5riF56m65b2T5aSp55qE5pS26JeP6aG544CC5Yu+6YCJ44CM5riF56m65omA5pyJ44CN5Y+v5riF
6Zmk6K+l6YCJ6aG55Y2h5YWo6YOo5YaF5a6544CCJwogICAgICAgICAgICA6IChjdXJUYWIgPT09
ICdyZWNlbnQnCiAgICAgICAgICAgICAgICA/ICfmuIXnqbrjgIzmnIDov5HjgI3kvJrliKDpmaTm
nKrlm7rlrprnmoTmnIDov5Hnm67lvZXorrDlvZXvvJvlt7Llm7rlrprnmoTnm67lvZXkvJrkv53n
lZnjgIInCiAgICAgICAgICAgICAgICA6ICfku4XmuIXnqbrlvZPliY3pgInpobnljaHjgILpu5jo
rqTlj6rmuIXlvZPlpKnvvJvmlLbol4/pobnkuI3kvJrooqvmuIXpmaTjgILli77pgInjgIzmuIXn
qbrmiYDmnInjgI3lj6/muIXpmaTor6XpgInpobnljaHlhajpg6jml6XmnJ/jgIInKTsKICAgICAg
ICBjbHJBbGxDYi5jaGVja2VkID0gZmFsc2U7CiAgICAgICAgY2xyRGxnLmNsYXNzTGlzdC5hZGQo
J29uJyk7CiAgICB9CiAgICBmdW5jdGlvbiBjbG9zZUNsZWFyRGxnKCkgewogICAgICAgIGNsckRs
Zy5jbGFzc0xpc3QucmVtb3ZlKCdvbicpOwogICAgfQogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5
SWQoJ2J0bi1jbHInKS5hZGRFdmVudExpc3RlbmVyKCdjbGljaycsIGUgPT4gewogICAgICAgIGUu
c3RvcFByb3BhZ2F0aW9uKCk7CiAgICAgICAgb3BlbkNsZWFyRGxnKCk7CiAgICB9KTsKICAgIGRv
Y3VtZW50LmdldEVsZW1lbnRCeUlkKCdjbHItY2FuY2VsJykuYWRkRXZlbnRMaXN0ZW5lcignY2xp
Y2snLCBlID0+IHsKICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgICAgIGNsb3NlQ2xl
YXJEbGcoKTsKICAgIH0pOwogICAgY2xyRGxnLmFkZEV2ZW50TGlzdGVuZXIoJ2NsaWNrJywgZSA9
PiB7CiAgICAgICAgaWYgKGUudGFyZ2V0ID09PSBjbHJEbGcpIGNsb3NlQ2xlYXJEbGcoKTsKICAg
IH0pOwogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2Nsci1vaycpLmFkZEV2ZW50TGlzdGVu
ZXIoJ2NsaWNrJywgZSA9PiB7CiAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICBj
b25zdCBzY29wZSA9IChjdXJUYWIgPT09ICdyZWNlbnQnKSA/ICdhbGwnIDogKGNsckFsbENiLmNo
ZWNrZWQgPyAnYWxsJyA6ICd0b2RheScpOwogICAgICAgIGNsb3NlQ2xlYXJEbGcoKTsKICAgICAg
ICBhaGsoJ2NsZWFyJywgY3VyVGFiLCBzY29wZSk7CiAgICB9KTsKICAgIGRvY3VtZW50LmdldEVs
ZW1lbnRCeUlkKCdtdWx0aS1zZWwnKS5hZGRFdmVudExpc3RlbmVyKCdjbGljaycsIGUgPT4gewog
ICAgICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAgICAgY2xlYXJNdWx0aSh0cnVlKTsKICAg
IH0pOwogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2J0bi1waW4nKS5hZGRFdmVudExpc3Rl
bmVyKCdjbGljaycsIGUgPT4gewogICAgICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAgICAg
cGlubmVkVUkgPSAhcGlubmVkVUk7CiAgICAgICAgZS5jdXJyZW50VGFyZ2V0LmNsYXNzTGlzdC50
b2dnbGUoJ29uJywgcGlubmVkVUkpOwogICAgICAgIGFoaygndG9nZ2xlUGluJywgcGlubmVkVUkg
PyAnMScgOiAnMCcpOwogICAgfSk7CgogICAgd2luZG93Ll9fcGVyZk1hcmsgPSAoc3RhZ2UpID0+
IHsKICAgICAgICB0cnkgewogICAgICAgICAgICBpZiAod2luZG93LmNocm9tZSAmJiBjaHJvbWUu
d2VidmlldyAmJiBjaHJvbWUud2Vidmlldy5wb3N0TWVzc2FnZSkKICAgICAgICAgICAgICAgIGNo
cm9tZS53ZWJ2aWV3LnBvc3RNZXNzYWdlKCdwZXJmfCcgKyBTdHJpbmcoc3RhZ2UgfHwgJycpKTsK
ICAgICAgICB9IGNhdGNoIHt9CiAgICB9OwoKICAgIHdpbmRvdy5fX3VwZGF0ZUNsaXBzID0gcGF5
bG9hZCA9PiB7CiAgICAgICAgY29uc3QgdDAgPSAodHlwZW9mIHBlcmZvcm1hbmNlICE9PSAndW5k
ZWZpbmVkJyAmJiBwZXJmb3JtYW5jZS5ub3cpID8gcGVyZm9ybWFuY2Uubm93KCkgOiBEYXRlLm5v
dygpOwogICAgICAgIHdpbmRvdy5fX3BlcmZNYXJrKCdqc191cGRhdGVDbGlwc19lbnRlciBuPScg
KyAocGF5bG9hZCAmJiBwYXlsb2FkLml0ZW1zID8gcGF5bG9hZC5pdGVtcy5sZW5ndGggOiAoQXJy
YXkuaXNBcnJheShwYXlsb2FkKSA/IHBheWxvYWQubGVuZ3RoIDogMCkpKTsKICAgICAgICAvLyBL
ZWVwIHByZXZpb3VzIHNjcm9sbCBmb3IgbG9hZC1tb3JlOyByZXNldCB3aGVuIG9wZW5pbmcgcGFu
ZWwgdG8gZmlyc3QgaXRlbQogICAgICAgIGNvbnN0IGtlZXBTY3JvbGwgPSAhc2VsZWN0Rmlyc3RP
blNob3c7CiAgICAgICAgY29uc3Qgc3QgPSBsaXN0RWwuc2Nyb2xsVG9wOwogICAgICAgIHdpbmRv
dy5fX3dhaXRpbmdWaWV3ID0gZmFsc2U7CiAgICAgICAgY29uc3Qgd2FzQXBwZW5kID0gcGF5bG9h
ZCAmJiBwYXlsb2FkLmFwcGVuZDsKICAgICAgICBsb2FkaW5nTW9yZSA9IGZhbHNlOwogICAgICAg
IGNvbnN0IHByZXZJdGVtcyA9IGFsbENsaXBzOwogICAgICAgIGxldCBuZXh0SXRlbXMgPSBbXTsK
ICAgICAgICBsZXQgbmV4dFRvdGFsID0gMDsKICAgICAgICBsZXQgbmV4dEZpbHRlcmVkID0gZmFs
c2U7CiAgICAgICAgbGV0IHBUYWIgPSAnJzsKICAgICAgICBsZXQgcFBpbm5lZFRvdGFsID0gLTE7
CiAgICAgICAgaWYgKEFycmF5LmlzQXJyYXkocGF5bG9hZCkpIHsKICAgICAgICAgICAgbmV4dEl0
ZW1zID0gcGF5bG9hZDsKICAgICAgICAgICAgbmV4dFRvdGFsID0gcGF5bG9hZC5sZW5ndGg7CiAg
ICAgICAgICAgIG5leHRGaWx0ZXJlZCA9IGZhbHNlOwogICAgICAgIH0gZWxzZSBpZiAocGF5bG9h
ZCAmJiB0eXBlb2YgcGF5bG9hZCA9PT0gJ29iamVjdCcpIHsKICAgICAgICAgICAgbmV4dFRvdGFs
ID0gTnVtYmVyKHBheWxvYWQudG90YWwpIHx8IDA7CiAgICAgICAgICAgIG5leHRJdGVtcyA9IEFy
cmF5LmlzQXJyYXkocGF5bG9hZC5pdGVtcykgPyBwYXlsb2FkLml0ZW1zIDogW107CiAgICAgICAg
ICAgIHBUYWIgPSBwYXlsb2FkLnRhYiAhPSBudWxsID8gU3RyaW5nKHBheWxvYWQudGFiKSA6ICcn
OwogICAgICAgICAgICBpZiAocGF5bG9hZC5waW5uZWRUb3RhbCAhPSBudWxsICYmIHBheWxvYWQu
cGlubmVkVG90YWwgIT09ICcnKQogICAgICAgICAgICAgICAgcFBpbm5lZFRvdGFsID0gTnVtYmVy
KHBheWxvYWQucGlubmVkVG90YWwpIHx8IDA7CiAgICAgICAgICAgIGNvbnN0IHBxMCA9IHBheWxv
YWQucXVlcnkgIT0gbnVsbCA/IFN0cmluZyhwYXlsb2FkLnF1ZXJ5KSA6ICcnOwogICAgICAgICAg
ICBuZXh0RmlsdGVyZWQgPSAhIShwYXlsb2FkLmZpbHRlcmVkIHx8IChwcTAgJiYgcHEwLnRyaW0o
KSkpOwogICAgICAgICAgICBpZiAocGF5bG9hZC5hcHBlbmQpIHsKICAgICAgICAgICAgICAgIC8v
IEFwcGVuZCBvbmx5IGFwcGxpZXMgdG8gdGhlIHRhYiB3ZSdyZSBjdXJyZW50bHkgdmlld2luZwog
ICAgICAgICAgICAgICAgaWYgKHBUYWIgJiYgcFRhYiAhPT0gY3VyVGFiKQogICAgICAgICAgICAg
ICAgICAgIHJldHVybjsKICAgICAgICAgICAgICAgIGNvbnN0IHNlZW4gPSBuZXcgU2V0KGFsbENs
aXBzLm1hcChjID0+ICtjLmlkKSk7CiAgICAgICAgICAgICAgICBjb25zdCBtZXJnZWQgPSBhbGxD
bGlwcy5zbGljZSgpOwogICAgICAgICAgICAgICAgbmV4dEl0ZW1zLmZvckVhY2goaXQgPT4gewog
ICAgICAgICAgICAgICAgICAgIGlmICghc2Vlbi5oYXMoK2l0LmlkKSkgbWVyZ2VkLnB1c2goaXQp
OwogICAgICAgICAgICAgICAgfSk7CiAgICAgICAgICAgICAgICBuZXh0SXRlbXMgPSBtZXJnZWQ7
CiAgICAgICAgICAgICAgICBuZXh0VG90YWwgPSBNYXRoLm1heChuZXh0VG90YWwsIG5leHRJdGVt
cy5sZW5ndGgpOwogICAgICAgICAgICB9CiAgICAgICAgICAgIC8vIOaQnOe0ouahhuS7peaJk+Wt
l+mVnOWDj+S4uuWHhu+8jOe7neS4jeiiq+a7nuWQjueahOejgeebmOe7k+aenOWGmeWbnuaXp+WF
s+mUruWtlwogICAgICAgICAgICB0cnkgewogICAgICAgICAgICAgICAgY29uc3QgcyA9IGRvY3Vt
ZW50LmdldEVsZW1lbnRCeUlkKCdzZWFyY2gnKTsKICAgICAgICAgICAgICAgIGlmIChzICYmIFN0
cmluZyhzLnZhbHVlIHx8ICcnKS5sZW5ndGgpCiAgICAgICAgICAgICAgICAgICAgcXVlcnkgPSBz
LnZhbHVlOwogICAgICAgICAgICAgICAgZWxzZSBpZiAocHEwICE9PSAnJyAmJiAhU3RyaW5nKHF1
ZXJ5IHx8ICcnKS50cmltKCkpCiAgICAgICAgICAgICAgICAgICAgcXVlcnkgPSBwcTA7CiAgICAg
ICAgICAgIH0gY2F0Y2gge30KICAgICAgICB9IGVsc2UgewogICAgICAgICAgICBuZXh0SXRlbXMg
PSBbXTsKICAgICAgICAgICAgbmV4dFRvdGFsID0gMDsKICAgICAgICAgICAgbmV4dEZpbHRlcmVk
ID0gZmFsc2U7CiAgICAgICAgfQoKICAgICAgICBjb25zdCBib3hRID0gU3RyaW5nKHF1ZXJ5IHx8
ICcnKS50cmltKCk7CiAgICAgICAgY29uc3QgcHVzaFEgPSAocGF5bG9hZCAmJiB0eXBlb2YgcGF5
bG9hZCA9PT0gJ29iamVjdCcgJiYgcGF5bG9hZC5xdWVyeSAhPSBudWxsKQogICAgICAgICAgICA/
IFN0cmluZyhwYXlsb2FkLnF1ZXJ5KS50cmltKCkgOiAnJzsKCiAgICAgICAgLy8gQWx3YXlzIHJl
ZnJlc2gg5pS26JePIGJhZGdlIGZyb20gaG9zdCB3aGVuIHByb3ZpZGVkCiAgICAgICAgaWYgKHBQ
aW5uZWRUb3RhbCA+PSAwKQogICAgICAgICAgICBwaW5uZWRUb3RhbCA9IHBQaW5uZWRUb3RhbDsK
CiAgICAgICAgLy8gU3RhbGUgc2VhcmNoIHB1c2ggKGUuZy4gInNxdWFyZSBsb2dpIiBsYW5kcyBh
ZnRlciB1c2VyIHR5cGVkICJzcXVhcmUgbG9naW4iKSDigJRjYWNoZSBvbmx5CiAgICAgICAgaWYg
KCF3YXNBcHBlbmQgJiYgbmV4dEZpbHRlcmVkICYmIHB1c2hRICYmIGJveFEgJiYgcHVzaFEgIT09
IGJveFEpIHsKICAgICAgICAgICAgdmlld01lbS5zZXQodmlld01lbUtleShwVGFiIHx8IGN1clRh
YiwgcHVzaFEsIHRvZGF5T25seSksIHsKICAgICAgICAgICAgICAgIGl0ZW1zOiBuZXh0SXRlbXMu
c2xpY2UoKSwKICAgICAgICAgICAgICAgIHRvdGFsOiBuZXh0VG90YWwKICAgICAgICAgICAgfSk7
CiAgICAgICAgICAgIHJldHVybjsKICAgICAgICB9CgogICAgICAgIC8vIFN0YWxlIHB1c2ggZm9y
IGFub3RoZXIgdGFiOiBvbmx5IHJlZnJlc2ggdGhhdCB0YWIncyB2aWV3TWVtLCBkb24ndCBoaWph
Y2sgVUkKICAgICAgICBpZiAoIXdhc0FwcGVuZCAmJiBwVGFiICYmIHBUYWIgIT09IGN1clRhYikg
ewogICAgICAgICAgICBjb25zdCBtZW1RID0gKHBheWxvYWQgJiYgdHlwZW9mIHBheWxvYWQgPT09
ICdvYmplY3QnICYmIHBheWxvYWQucXVlcnkgIT0gbnVsbCkKICAgICAgICAgICAgICAgID8gU3Ry
aW5nKHBheWxvYWQucXVlcnkpIDogJyc7CiAgICAgICAgICAgIHZpZXdNZW0uc2V0KHZpZXdNZW1L
ZXkocFRhYiwgbWVtUSwgdG9kYXlPbmx5KSwgewogICAgICAgICAgICAgICAgaXRlbXM6IG5leHRJ
dGVtcy5zbGljZSgpLAogICAgICAgICAgICAgICAgdG90YWw6IG5leHRUb3RhbAogICAgICAgICAg
ICB9KTsKICAgICAgICAgICAgLy8gU3RpbGwgdXBkYXRlIHBpbiBiYWRnZSBpZiBob3N0IHNlbnQg
aXQKICAgICAgICAgICAgdHJ5IHsgdXBkYXRlUGluRG90KCk7IH0gY2F0Y2gge30KICAgICAgICAg
ICAgLy8gUVEg5pCc57Si5pu+5Zu65a6a5o6oIGFsbCB0YWIg4oaSIOW9k+WJjSB0YWIg5Lya5LiA
55u06aqo5p6277yb6KGl5LiA5qyhIHJlcXVlc3RWaWV3CiAgICAgICAgICAgIGlmICh3YWl0aW5n
RGF0YSAmJiBwdXNoUSA9PT0gYm94USkgewogICAgICAgICAgICAgICAgc2V0VGltZW91dCgoKSA9
PiB7CiAgICAgICAgICAgICAgICAgICAgaWYgKHdhaXRpbmdEYXRhICYmIGN1clRhYiAhPT0gcFRh
YikKICAgICAgICAgICAgICAgICAgICAgICAgcmVxdWVzdFZpZXcoKTsKICAgICAgICAgICAgICAg
IH0sIDQwKTsKICAgICAgICAgICAgfQogICAgICAgICAgICByZXR1cm47CiAgICAgICAgfQoKICAg
ICAgICAvLyBCb290c3RyYXAgcmFjZTogQUhLIHB1c2hlZCBlbXB0eSBiZWZvcmUgV2FybUFsbFZp
ZXdzIOKAlGtlZXAgc2tlbGV0b24sIGlnbm9yZQogICAgICAgIGNvbnN0IHFPbiA9IFN0cmluZyhx
dWVyeSB8fCAnJykudHJpbSgpLmxlbmd0aCA+IDA7CiAgICAgICAgaWYgKCF3YXNBcHBlbmQgJiYg
IW5leHRJdGVtcy5sZW5ndGggJiYgbmV4dFRvdGFsIDw9IDAgJiYgIXFPbiAmJiAhbmV4dEZpbHRl
cmVkICYmICFzYXdOb25FbXB0eSkgewogICAgICAgICAgICBpZiAoIXdpbmRvdy5fX2VtcHR5RmFs
bGJhY2tUKSB7CiAgICAgICAgICAgICAgICB3aW5kb3cuX19lbXB0eUZhbGxiYWNrVCA9IHNldFRp
bWVvdXQoKCkgPT4gewogICAgICAgICAgICAgICAgICAgIHdpbmRvdy5fX2VtcHR5RmFsbGJhY2tU
ID0gMDsKICAgICAgICAgICAgICAgICAgICBpZiAoc2F3Tm9uRW1wdHkpIHJldHVybjsKICAgICAg
ICAgICAgICAgICAgICAvLyBUcnVseSBlbXB0eSBpbnN0YWxsIGFmdGVyIHdhaXQKICAgICAgICAg
ICAgICAgICAgICBzYXdOb25FbXB0eSA9IHRydWU7CiAgICAgICAgICAgICAgICAgICAgaG9zdFB1
c2hlZE9uY2UgPSB0cnVlOwogICAgICAgICAgICAgICAgICAgIHdpbmRvdy5fX2RhdGFSZWFkeSA9
IHRydWU7CiAgICAgICAgICAgICAgICAgICAgYWxsQ2xpcHMgPSBbXTsKICAgICAgICAgICAgICAg
ICAgICBkaXNrVG90YWwgPSAwOwogICAgICAgICAgICAgICAgICAgIGNsZWFyV2FpdGluZ0RhdGEo
KTsKICAgICAgICAgICAgICAgICAgICB0cnkgeyByZW5kZXIoKTsgfSBjYXRjaCB7fQogICAgICAg
ICAgICAgICAgfSwgNDUwMCk7CiAgICAgICAgICAgIH0KICAgICAgICAgICAgd2FpdGluZ0RhdGEg
PSB0cnVlOwogICAgICAgICAgICB3aW5kb3cuX19kYXRhUmVhZHkgPSBmYWxzZTsKICAgICAgICAg
ICAgaG9zdFB1c2hlZE9uY2UgPSBmYWxzZTsKICAgICAgICAgICAgc2V0Qm9vdExvYWRpbmcodHJ1
ZSk7CiAgICAgICAgICAgIHRyeSB7IHJlbmRlcigpOyB9IGNhdGNoIHt9CiAgICAgICAgICAgIHJl
dHVybjsKICAgICAgICB9CgogICAgICAgIGNsZWFyV2FpdGluZ0RhdGEoKTsKICAgICAgICBhbGxD
bGlwcyA9IG5leHRJdGVtczsKICAgICAgICBkaXNrVG90YWwgPSBuZXh0VG90YWw7CiAgICAgICAg
Ly8gS2VlcCBiYXIgY29uc2lzdGVudCBpZiBsaXN0IGdyZXcgcGFzdCBhIHN0YWxlIHRvdGFsCiAg
ICAgICAgaWYgKGFsbENsaXBzLmxlbmd0aCA+IGRpc2tUb3RhbCkKICAgICAgICAgICAgZGlza1Rv
dGFsID0gYWxsQ2xpcHMubGVuZ3RoOwogICAgICAgIHdpbmRvdy5fX2hvc3RGaWx0ZXJlZCA9IG5l
eHRGaWx0ZXJlZDsKICAgICAgICB3aW5kb3cuX19ob3N0RmlsdGVyUSA9IChuZXh0RmlsdGVyZWQg
JiYgcHVzaFEpID8gcHVzaFEgOiAnJzsKICAgICAgICAvLyBGaWx0ZXJlZCBzZWFyY2ggd2l0aCAw
IGhpdHMg4oCUbXVzdCBsZWF2ZSBza2VsZXRvbiAoaG9zdCBkaWQgcmVzcG9uZCkKICAgICAgICBp
ZiAoIXdhc0FwcGVuZCAmJiBuZXh0RmlsdGVyZWQgJiYgIWFsbENsaXBzLmxlbmd0aCAmJiBkaXNr
VG90YWwgPD0gMCkgewogICAgICAgICAgICBob3N0UHVzaGVkT25jZSA9IHRydWU7CiAgICAgICAg
ICAgIHNhd05vbkVtcHR5ID0gdHJ1ZTsKICAgICAgICB9CiAgICAgICAgaWYgKGFsbENsaXBzLmxl
bmd0aCB8fCBkaXNrVG90YWwgPiAwKQogICAgICAgICAgICBzYXdOb25FbXB0eSA9IHRydWU7CiAg
ICAgICAgaWYgKHdpbmRvdy5fX2VtcHR5RmFsbGJhY2tUKSB7CiAgICAgICAgICAgIGNsZWFyVGlt
ZW91dCh3aW5kb3cuX19lbXB0eUZhbGxiYWNrVCk7CiAgICAgICAgICAgIHdpbmRvdy5fX2VtcHR5
RmFsbGJhY2tUID0gMDsKICAgICAgICB9CiAgICAgICAgaWYgKCF3YXNBcHBlbmQpIHsKICAgICAg
ICAgICAgY29uc3QgbWVtUSA9IChwYXlsb2FkICYmIHR5cGVvZiBwYXlsb2FkID09PSAnb2JqZWN0
JyAmJiBwYXlsb2FkLnF1ZXJ5ICE9IG51bGwpCiAgICAgICAgICAgICAgICA/IFN0cmluZyhwYXls
b2FkLnF1ZXJ5KSA6IHF1ZXJ5OwogICAgICAgICAgICB2aWV3TWVtLnNldCh2aWV3TWVtS2V5KGN1
clRhYiwgbWVtUSwgdG9kYXlPbmx5KSwgewogICAgICAgICAgICAgICAgaXRlbXM6IGFsbENsaXBz
LnNsaWNlKCksCiAgICAgICAgICAgICAgICB0b3RhbDogZGlza1RvdGFsCiAgICAgICAgICAgIH0p
OwogICAgICAgIH0KICAgICAgICB3aW5kb3cuX19kYXRhUmVhZHkgPSB0cnVlOwogICAgICAgIGhv
c3RQdXNoZWRPbmNlID0gdHJ1ZTsKCiAgICAgICAgLy8gTWlkLXdoZWVsOiBrZWVwIGRhdGEsIGRl
bGF5IERPTSBzbyBzY3JvbGwvZHJhZyBuZXZlciBoaXRjaCBvbiBhcHBlbmQgcGFpbnQKICAgICAg
ICBpZiAod2FzQXBwZW5kICYmIHdpbmRvdy5fX3Njcm9sbEJ1c3kgJiYgIXdpbmRvdy5fX3BlbmRp
bmdKdW1wSWQpIHsKICAgICAgICAgICAgY29uc3QgZnJvbUxlbiA9IChwcmV2SXRlbXMgJiYgcHJl
dkl0ZW1zLmxlbmd0aCkgPyBwcmV2SXRlbXMubGVuZ3RoIDogMDsKICAgICAgICAgICAgaWYgKCFf
cGVuZGluZ0FwcGVuZCkKICAgICAgICAgICAgICAgIF9wZW5kaW5nQXBwZW5kID0geyBmcm9tTGVu
OiBmcm9tTGVuIH07CiAgICAgICAgICAgIHRyeSB7IHJlZnJlc2hMaXN0Q2hyb21lKCk7IH0gY2F0
Y2gge30KICAgICAgICAgICAgcmV0dXJuOwogICAgICAgIH0KCiAgICAgICAgY29uc3Qgd2FzQm9v
dExvYWRpbmcgPSBib290TG9hZGluZzsKICAgICAgICBsZXQgc2FtZVBhaW50ID0gZmFsc2U7CiAg
ICAgICAgY29uc3QgcHJldkxlbiA9IChwcmV2SXRlbXMgJiYgcHJldkl0ZW1zLmxlbmd0aCkgPyBw
cmV2SXRlbXMubGVuZ3RoIDogMDsKICAgICAgICBpZiAoIXdhc0FwcGVuZCAmJiAhd2FzQm9vdExv
YWRpbmcgJiYgcHJldkl0ZW1zICYmIHByZXZJdGVtcy5sZW5ndGggPT09IGFsbENsaXBzLmxlbmd0
aCAmJiBwcmV2SXRlbXMubGVuZ3RoKSB7CiAgICAgICAgICAgIHNhbWVQYWludCA9IHRydWU7CiAg
ICAgICAgICAgIGZvciAobGV0IGkgPSAwOyBpIDwgYWxsQ2xpcHMubGVuZ3RoOyBpKyspIHsKICAg
ICAgICAgICAgICAgIGNvbnN0IGEgPSBwcmV2SXRlbXNbaV0sIGIgPSBhbGxDbGlwc1tpXTsKICAg
ICAgICAgICAgICAgIGlmICgrYS5pZCAhPT0gK2IuaWQpIHsgc2FtZVBhaW50ID0gZmFsc2U7IGJy
ZWFrOyB9CiAgICAgICAgICAgICAgICAvLyBRdWV1ZSAvIHBhc3RlZCBjaHJvbWUgbGl2ZXMgaW4g
RE9NIGNsYXNzZXMg4oCUIG11c3QgcmUtcmVuZGVyIHdoZW4gbWV0YSBmbGlwcwogICAgICAgICAg
ICAgICAgaWYgKChOdW1iZXIoYS5xdWV1ZUdyb3VwKSB8fCAwKSAhPT0gKE51bWJlcihiLnF1ZXVl
R3JvdXApIHx8IDApCiAgICAgICAgICAgICAgICAgICAgfHwgKE51bWJlcihhLnF1ZXVlSW5kZXgp
IHx8IDApICE9PSAoTnVtYmVyKGIucXVldWVJbmRleCkgfHwgMCkKICAgICAgICAgICAgICAgICAg
ICB8fCAhIWEucGFzdGVkICE9PSAhIWIucGFzdGVkKSB7CiAgICAgICAgICAgICAgICAgICAgc2Ft
ZVBhaW50ID0gZmFsc2U7CiAgICAgICAgICAgICAgICAgICAgYnJlYWs7CiAgICAgICAgICAgICAg
ICB9CiAgICAgICAgICAgIH0KICAgICAgICAgICAgaWYgKHNhbWVQYWludCAmJiAhbGlzdEVsLnF1
ZXJ5U2VsZWN0b3IoJy5pdG0nKSkgc2FtZVBhaW50ID0gZmFsc2U7CiAgICAgICAgfQogICAgICAg
IGNvbnN0IGZpbmlzaFVwZGF0ZSA9ICgpID0+IHsKICAgICAgICAgICAgY29uc3QgdFJlbmRlcjAg
PSAodHlwZW9mIHBlcmZvcm1hbmNlICE9PSAndW5kZWZpbmVkJyAmJiBwZXJmb3JtYW5jZS5ub3cp
ID8gcGVyZm9ybWFuY2Uubm93KCkgOiBEYXRlLm5vdygpOwogICAgICAgICAgICBjbGVhcldhaXRp
bmdEYXRhKCk7CiAgICAgICAgICAgIGlmICh3YXNBcHBlbmQgJiYgIXdhc0Jvb3RMb2FkaW5nICYm
IHByZXZMZW4gPiAwICYmIGFsbENsaXBzLmxlbmd0aCA+IHByZXZMZW4pIHsKICAgICAgICAgICAg
ICAgIGFwcGVuZFJlbmRlcihwcmV2TGVuKTsKICAgICAgICAgICAgfSBlbHNlIGlmICghc2FtZVBh
aW50KSB7CiAgICAgICAgICAgICAgICByZW5kZXIoKTsKICAgICAgICAgICAgICAgIGFwcGx5VGFi
U3dpdGNoQW5pbSgpOwogICAgICAgICAgICAgICAgaWYgKGtlZXBTY3JvbGwpCiAgICAgICAgICAg
ICAgICAgICAgbGlzdEVsLnNjcm9sbFRvcCA9IHN0OwogICAgICAgICAgICAgICAgZWxzZQogICAg
ICAgICAgICAgICAgICAgIGxpc3RFbC5zY3JvbGxUb3AgPSAwOwogICAgICAgICAgICB9IGVsc2Ug
ewogICAgICAgICAgICAgICAgdHJ5IHsgcmVmcmVzaExpc3RDaHJvbWUoKTsgfSBjYXRjaCB7fQog
ICAgICAgICAgICAgICAgaWYgKGtlZXBTY3JvbGwpCiAgICAgICAgICAgICAgICAgICAgbGlzdEVs
LnNjcm9sbFRvcCA9IHN0OwogICAgICAgICAgICB9CiAgICAgICAgICAgIGNvbnN0IHQxID0gKHR5
cGVvZiBwZXJmb3JtYW5jZSAhPT0gJ3VuZGVmaW5lZCcgJiYgcGVyZm9ybWFuY2Uubm93KSA/IHBl
cmZvcm1hbmNlLm5vdygpIDogRGF0ZS5ub3coKTsKICAgICAgICAgICAgd2luZG93Ll9fcGVyZk1h
cmsoJ2pzX3VwZGF0ZUNsaXBzX2RvbmUgcmVuZGVyTXM9JyArIE1hdGgucm91bmQodDEgLSB0UmVu
ZGVyMCkgKyAnIHRvdGFsTXM9JyArIE1hdGgucm91bmQodDEgLSB0MCkgKyAnIG49JyArIGFsbENs
aXBzLmxlbmd0aCk7CiAgICAgICAgfTsKICAgICAgICBpZiAod2FzQm9vdExvYWRpbmcpIHsKICAg
ICAgICAgICAgY29uc3Qgc2luY2UgPSB3aW5kb3cuX19za2VsU2luY2UgfHwgMDsKICAgICAgICAg
ICAgY29uc3Qgd2FpdCA9IHNpbmNlID8gTWF0aC5tYXgoMCwgODAgLSAoRGF0ZS5ub3coKSAtIHNp
bmNlKSkgOiAwOwogICAgICAgICAgICBpZiAod2FpdCA+IDApCiAgICAgICAgICAgICAgICBzZXRU
aW1lb3V0KGZpbmlzaFVwZGF0ZSwgd2FpdCk7CiAgICAgICAgICAgIGVsc2UKICAgICAgICAgICAg
ICAgIGZpbmlzaFVwZGF0ZSgpOwogICAgICAgIH0gZWxzZSB7CiAgICAgICAgICAgIGZpbmlzaFVw
ZGF0ZSgpOwogICAgICAgIH0KICAgIH07CiAgICB3aW5kb3cuX19zZXRQaW5uZWQgPSB2ID0+IHsK
ICAgICAgICBwaW5uZWRVSSA9ICEhdjsKICAgICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgn
YnRuLXBpbicpLmNsYXNzTGlzdC50b2dnbGUoJ29uJywgcGlubmVkVUkpOwogICAgfTsKICAgIHdp
bmRvdy5fX2xvYWRNb3JlRG9uZSA9ICgpID0+IHsKICAgICAgICBsb2FkaW5nTW9yZSA9IGZhbHNl
OwogICAgICAgIGlmICh3aW5kb3cuX19sb2FkTW9yZVdhdGNoKSB7CiAgICAgICAgICAgIGNsZWFy
VGltZW91dCh3aW5kb3cuX19sb2FkTW9yZVdhdGNoKTsKICAgICAgICAgICAgd2luZG93Ll9fbG9h
ZE1vcmVXYXRjaCA9IDA7CiAgICAgICAgfQogICAgICAgIGlmICh3aW5kb3cuX19wZW5kaW5nSnVt
cElkKQogICAgICAgICAgICB0cnlDb250aW51ZUp1bXAoKTsKICAgIH07CgogICAgaW5pdFNlcFVp
KCk7CiAgICB1cGRhdGVQaW5Eb3QoKTsKICAgIHNjaGVkdWxlRGVsYXllZFNrZWwoKTsKICAgIHdp
bmRvdy5fX3BlcmZNYXJrICYmIHdpbmRvdy5fX3BlcmZNYXJrKCdqc19ib290IHJlcXVlc3RWaWV3
Jyk7CiAgICByZXF1ZXN0VmlldygpOwogICAgLy8gc2NoZWR1bGVEZWxheWVkU2tlbCBhbHJlYWR5
IHJlbmRlcigpJ2Qgd2hlbiBlbXB0eTsgc3RpbGwgcGFpbnQgb25jZSBmb3IgY2hyb21lCgogICAg
PC9zY3JpcHQ+CjwvYm9keT4KPC9odG1sPg==
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
