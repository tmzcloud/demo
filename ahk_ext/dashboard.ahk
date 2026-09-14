#Requires AutoHotkey v2.0
#SingleInstance Force
#NoTrayIcon
; 独立启动：缺 WebView2 时下载后重启；配置/下载/索引进度一律走圆圈 boot 页（不另开启动窗）
; 相对路径 Include（勿用 "%A_ScriptDir%\..."）
#Include *i lib\webview2\WebView2.ahk
Persistent
FileEncoding "UTF-8"

; ── 直接运行显示主窗+圆圈；快捷键4 传 hosted 则后台静默 ─────────────
global dashboardHosted := DashArgsHas("hosted")
global dashboardStandalone := !dashboardHosted
global dashTrayVisible := false
global evBootStarted := false
global wv2BootGui := 0, wv2BootStatus := 0, wv2BootPct := 0

DashArgsHas(name) {
    name := StrLower(String(name))
    for a in A_Args {
        if StrLower(String(a)) = name
            return true
    }
    return false
}

; 最早可用的启动日志（AppLog 依赖 data 目录，此时可能还没有）
BootLog(msg) {
    try {
        DirCreate A_ScriptDir "\data\local_search"
        FileAppend FormatTime(, "HH:mm:ss") " " msg "`n", A_ScriptDir "\data\local_search\debug.log", "UTF-8"
    }
}

; 重启自身：独立运行带 show，不用 Hide（否则用户以为没弹窗）
DashboardRelaunchSelf(*) {
    global dashboardStandalone
    args := ""
    for a in A_Args {
        al := StrLower(String(a))
        if al = "show" || al = "hosted"
            continue
        args .= (args = "" ? "" : " ") '"' String(a) '"'
    }
    ; 独立运行强制带 show，重启后一定进界面
    if dashboardStandalone
        args := Trim(args " show")
    else if DashArgsHas("hosted")
        args := Trim(args " hosted")
    cmd := Format('"{1}" "{2}"{3}', A_AhkPath, A_ScriptFullPath, args = "" ? "" : " " args)
    BootLog("Relaunch: " cmd)
    Run(cmd)  ; 不要 Hide
}

; WebView2 下载阶段的简易进度窗（此时还不能进圆圈页）
Wv2BootShow(msg, pct := 0) {
    global wv2BootGui, wv2BootStatus, wv2BootPct, dashboardStandalone
    BootLog("Wv2Boot " pct "% " msg)
    if !dashboardStandalone && DashArgsHas("hosted")
        return
    pct := Max(0, Min(100, Integer(pct)))
    if !IsObject(wv2BootGui) {
        g := Gui("+AlwaysOnTop -MinimizeBox", "本地搜索")
        g.SetFont("s11", "Segoe UI")
        g.Add("Text", "w400", "首次运行需下载 WebView2 运行库")
        wv2BootStatus := g.Add("Text", "w400 h40", msg)
        wv2BootPct := g.Add("Progress", "w400 h18 Range0-100", pct)
        g.Add("Text", "w400 c666666", "完成后会自动重启并打开搜索界面。")
        g.OnEvent("Close", (*) => ExitApp())
        g.Show("Center w440")
        wv2BootGui := g
    } else {
        try wv2BootStatus.Value := msg
        try wv2BootPct.Value := pct
        try wv2BootGui.Show("NA")
    }
    Sleep 40
}

DashSetupStandaloneTray(*) {
    global dashboardStandalone, dashTrayVisible
    if !dashboardStandalone {
        dashTrayVisible := false
        return
    }
    try {
        A_IconHidden := false
        ; 系统自带搜索图标，零外部资源
        TraySetIcon("shell32.dll", 23)
        A_TrayMenu.Delete()
        A_TrayMenu.Add("显示本地搜索", (*) => ShowWindow())
        A_TrayMenu.Add()
        A_TrayMenu.Add("退出", (*) => ExitApp())
        A_TrayMenu.Default := "显示本地搜索"
        A_IconTip := "本地搜索  (Win+Shift+F)"
        dashTrayVisible := !A_IconHidden
    } catch {
        dashTrayVisible := false
    }
}

; WebView2 缺失时尚无法进圆圈页：下载完成后必须重启，才能 #Include 并弹出界面
_wv2Ahk := A_ScriptDir "\lib\webview2\WebView2.ahk"
_wv2Dll := A_ScriptDir "\lib\webview2\WebView2Loader.dll"
_wv2NeedBoot := !FileExist(_wv2Ahk) || !FileExist(_wv2Dll) || !IsSet(WebView2)
BootLog("wv2 check need=" _wv2NeedBoot " ahk=" FileExist(_wv2Ahk) " dll=" FileExist(_wv2Dll) " class=" IsSet(WebView2))
if _wv2NeedBoot {
    Wv2BootShow("正在准备 WebView2 组件…", 5)
    if !DashboardBootstrapWebView2() {
        Wv2BootShow("WebView2 下载失败，请检查网络后重试", 0)
        MsgBox "无法准备 WebView2 组件（lib\webview2）。`n请检查网络后重试。", "本地搜索", "Iconx"
        ExitApp
    }
    ; 下载/复制完成后必须重启，#Include 才会生效，随后自动弹出圆圈页
    Wv2BootShow("组件已就绪，正在重启并打开界面…", 95)
    Sleep 500
    DashboardRelaunchSelf()
    ExitApp
}

; ── Paths ─────────────────────────────────────────────────────────────
; 数据根：优先 HELPME_HOME\command_ext\ahk_ext\data，否则脚本旁 data\
; clip 数据 → data\clip_v1；本地搜索 → data\local_search
; 公共工具 → lib\everything；WebView2 → lib\webview2
; 界面 HTML 内嵌于脚本末尾 local_search_index.html 注释块（一行 base64）
APP_DIR      := A_ScriptDir
DATA_ROOT    := ResolveAhkExtDataRoot()
SEARCH_DIR   := ResolveLocalSearchDir()
HTML_FILE    := SEARCH_DIR "\index.html"
LIB_DIR      := APP_DIR "\lib"
WV2_DIR      := LIB_DIR "\webview2"
WV2_AHK      := WV2_DIR "\WebView2.ahk"
WV2_DLL      := WV2_DIR "\WebView2Loader.dll"
TOOLS_DIR    := LIB_DIR "\everything"
EV_DIR       := TOOLS_DIR
EV_EXE       := EV_DIR "\Everything.exe"
ES_EXE       := EV_DIR "\es.exe"
EV_ZIP       := TOOLS_DIR "\Everything-portable.zip"
ES_ZIP       := TOOLS_DIR "\ES-portable.zip"
WV_DATA      := SEARCH_DIR "\wv2data"
DEBUG_LOG    := SEARCH_DIR "\debug.log"
ICON_DIR     := SEARCH_DIR "\icons_v4"
APP_HOST     := "localsearch.app"
STORE_HOST   := "files.local"
; 仅 Everything / WebView2 安装包允许外网下载
EV_URL       := "https://www.voidtools.com/Everything-1.4.1.1032.x64.zip"
ES_URL       := "https://www.voidtools.com/ES-1.1.0.37.x64.zip"
EMBED_HTML_TAG := "local_search_index.html"

global guiWin := "", wv := "", wvCore := "", wvBuilding := false
global uiReady := false, evReady := false, searchGen := 0
global lastQuery := "", lastCat := "all", lastSort := "date-desc"
global previewCache := Map()
global searchHost := ""
global webMsgSub := ""  ; keep WebMessage subscription alive
global pendingSearch := ""
global lastSearchAt := 0
global lastSearchKey := ""
global drainBusy := false
global queuePollOn := false
global searchBusy := false
global searchSeq := 0
global iconCache := Map()   ; key -> https://localsearch.app/icons/xxx.png
global gdipToken := 0
global hAppIconBig := 0
global hAppIconSmall := 0
global bootOn := false
global bootPct := 0
global pendingBoot := false
global pendingBootMsg := ""
global pendingBootHint := ""

; 启动前确保 lib\webview2 有 WebView2.ahk + WebView2Loader.dll；缺失则下载（调用方负责重启）
DashboardBootstrapWebView2() {
    static ahkUrl := "https://raw.githubusercontent.com/thqby/ahk2_lib/master/WebView2/WebView2.ahk"
    static nupkgUrl := "https://api.nuget.org/v3-flatcontainer/microsoft.web.webview2/1.0.2903.40/microsoft.web.webview2.1.0.2903.40.nupkg"
    dir := A_ScriptDir "\lib\webview2"
    ahk := dir "\WebView2.ahk"
    dll := dir "\WebView2Loader.dll"
    try DirCreate(dir)
    BootLog("BootstrapWebView2 dir=" dir)
    ; 兼容旧位置 / 误改名的 bak
    for p in [
        A_ScriptDir "\lib\webview2_bak\WebView2.ahk",
        A_ScriptDir "\lib\WebView2.ahk",
        A_Temp "\WebView2.ahk"
    ] {
        if !FileExist(ahk) && FileExist(p) {
            Wv2BootShow("复制 WebView2.ahk…", 12)
            try FileCopy(p, ahk, 1)
        }
    }
    for p in [
        A_ScriptDir "\lib\webview2_bak\WebView2Loader.dll",
        A_ScriptDir "\lib\WebView2Loader.dll",
        A_Temp "\WebView2Loader.dll"
    ] {
        if !FileExist(dll) && FileExist(p) {
            Wv2BootShow("复制 WebView2Loader.dll…", 15)
            try FileCopy(p, dll, 1)
        }
    }
    needAhk := !FileExist(ahk)
    needDll := !FileExist(dll)
    if !needAhk && !needDll {
        Wv2BootShow("WebView2 文件已就绪", 90)
        BootLog("BootstrapWebView2 files already present")
        return true
    }
    ok := true
    if needAhk {
        Wv2BootShow("正在下载 WebView2.ahk…", 25)
        ; 优先用可让出消息泵的 DownloadFile；失败再 WinHttp
        if !DownloadFile(ahkUrl, ahk) && !DashboardDownloadFile(ahkUrl, ahk)
            ok := false
        else
            Wv2BootShow("WebView2.ahk 下载完成", 45)
    }
    if needDll {
        Wv2BootShow("正在下载 WebView2Loader.dll…", 55)
        if !DashboardDownloadWebView2Dll(nupkgUrl, dll)
            ok := false
        else
            Wv2BootShow("WebView2Loader.dll 就绪", 85)
    }
    if !ok || !FileExist(ahk) || !FileExist(dll) {
        BootLog("BootstrapWebView2 FAILED ok=" ok " ahk=" FileExist(ahk) " dll=" FileExist(dll))
        return false
    }
    Wv2BootShow("下载完成", 92)
    BootLog("BootstrapWebView2 OK")
    return true
}

JoinArgs(args) {
    out := ""
    for a in args
        out .= (out = "" ? "" : " ") '"' String(a) '"'
    return out
}

DashboardDownloadFile(url, dest) {
    try {
        SplitPath dest, , &destDir
        if destDir != ""
            DirCreate destDir
        tmp := dest ".part"
        try FileDelete tmp
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

DashboardDownloadWebView2Dll(nupkgUrl, destDll) {
    nupkg := A_Temp "\wv2_" A_TickCount ".nupkg"
    unzipDir := A_Temp "\wv2_extract_" A_TickCount
    try {
        if !DashboardDownloadFile(nupkgUrl, nupkg)
            return false
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

; HELPME_HOME set →%HELPME_HOME%\command_ext\ahk_ext\data（仅 hosted）
; 独立运行（陌生目录拷贝）→ 永远用脚本旁 data\，不跟 HELPME
ResolveAhkExtDataRoot() {
    global dashboardStandalone
    if IsSet(dashboardStandalone) && dashboardStandalone {
        dir := A_ScriptDir "\data"
        try DirCreate dir
        return dir
    }
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

ResolveLocalSearchDir() {
    global dashboardStandalone
    root := ResolveAhkExtDataRoot()
    dir := root "\local_search"
    try DirCreate dir
    ; 独立便携目录不迁入 HELPME 旧数据，避免串台
    if IsSet(dashboardStandalone) && dashboardStandalone
        return dir
    legacy := ""
    home := ""
    try home := EnvGet("HELPME_HOME")
    home := Trim(String(home))
    if home != ""
        legacy := RTrim(home, "\/") "\command_ext\ahk_ext\ahk\local_search"
    else
        legacy := A_ScriptDir "\ahk\local_search"
    MigrateLegacyDataDir(legacy, dir)
    return dir
}

; 目标为空且旧目录有内容时，整体迁入
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
        try DirCopy(legacy, preferred, 1)
    }
}

DirCreate SEARCH_DIR
DirCreate TOOLS_DIR
DirCreate WV_DATA
DirCreate ICON_DIR
DirCreate WV2_DIR
DashSetupStandaloneTray()
; 注意：不要在这里同步解码整段内嵌 HTML——会卡住数秒且窗口还没创建，
; 表现为「第一次点没 UI、只有 data，第二次才弹出」。写出放到 FinishWebViewInit / 异步。

AppLog(msg) {
    global DEBUG_LOG, SEARCH_DIR
    try {
        DirCreate SEARCH_DIR
        FileAppend FormatTime(, "HH:mm:ss") " " msg "`n", DEBUG_LOG, "UTF-8"
    }
}

; ── Entry ─────────────────────────────────────────────────────────────
AppLog("=== local search boot === standalone=" dashboardStandalone " script=" A_ScriptDir " data=" SEARCH_DIR)
EnsureWebViewLoader()
; 默认：快捷键4 传 hosted 时不弹窗；直接运行 / 参数 show 则显示圆圈 boot 页
global showWhenReady := false
for a in A_Args {
    if StrLower(String(a)) = "show"
        showWhenReady := true
}
if !showWhenReady && dashboardStandalone
    showWhenReady := true
; 0x8001：外部（快捷键4 托盘双击）唤出
OnMessage(0x8001, OnExternalShowMsg)
; Hotkey: Win+Shift+F 打开/聚焦本地搜索
#+f::ShowWindow()
; Esc：视频全屏时只退出全屏；否则隐藏窗口。Ctrl+F 定位搜索框
#HotIf LocalSearchWinActive()
Esc::HandleEscKey()
^f::FocusSearchBox()
#HotIf
; 独立运行：立刻弹窗（优先于写 HTML / 下 Everything），避免第一次点击无界面
; 快捷键4 写 show.request 时唤出（比 PostMessage 更稳）
SetTimer(PollShowRequest, 250)
if showWhenReady
    SetTimer(ShowWindow, -1)
else
    SetTimer(StartEverythingBootOnce, -400)
; 后台写出 HTML（已存在则秒过）；WebView Navigate 前 FinishWebViewInit 还会再确保一次
SetTimer(EnsureEmbeddedHtmlSafe, -1)

OnExternalShowMsg(*) {
    SetTimer(ShowWindow, -1)
    return 0
}

PollShowRequest(*) {
    global SEARCH_DIR
    req := SEARCH_DIR "\show.request"
    if !FileExist(req)
        return
    try FileDelete(req)
    catch
        return
    AppLog("PollShowRequest → ShowWindow")
    SetTimer(ShowWindow, -1)
}

FocusSearchBox(*) {
    global wvCore
    if !IsObject(wvCore)
        return
    try wvCore.ExecuteScriptAsync("window.__focusSearch&&window.__focusSearch()")
}

HandleEscKey(*) {
    global wvCore
    if !IsObject(wvCore) {
        HideWindow()
        return
    }
    ; 交给页面判断：全屏视频 → 退出全屏；否则回传 escHide
    try wvCore.ExecuteScriptAsync("window.__handleEsc&&window.__handleEsc()")
    catch
        HideWindow()
}

LocalSearchWinActive(*) {
    global guiWin
    return IsObject(guiWin) && WinActive("ahk_id " guiWin.Hwnd)
}

; ── GUI / WebView2 ────────────────────────────────────────────────────
BuildGui() {
    global guiWin, wvBuilding, SEARCH_DIR, WV_DATA, WV2_DLL, dashboardStandalone, showWhenReady
    if IsObject(guiWin) || wvBuilding
        return
    wvBuilding := true
    guiWin := Gui("+Resize", "本地搜索")
    guiWin.BackColor := "f3f4f7"
    guiWin.MarginX := 0
    guiWin.MarginY := 0
    guiWin.OnEvent("Close", OnDashboardClose)
    guiWin.OnEvent("Size", OnGuiSize)
    w := Min(1280, Max(980, A_ScreenWidth - 120))
    h := Min(820, Max(620, A_ScreenHeight - 120))
    ; 独立运行：立刻显示窗口（圆圈页），下载组件时用户能看见；hosted 仍先隐藏
    if dashboardStandalone || showWhenReady
        guiWin.Show("Center w" w " h" h)
    else
        guiWin.Show("Hide w" w " h" h)
    SetWindowAppIcon(guiWin.Hwnd)
    SetTimer(() => SetWindowAppIcon(guiWin.Hwnd), -200)

    try {
        dll := WV2_DLL
        if !FileExist(dll)
            throw Error("找不到 WebView2Loader.dll:`n" dll)
        opts := {
            AdditionalBrowserArguments: "--enable-features=msWebView2EnableDraggableRegions --allow-file-access-from-files"
        }
        WebView2.create(guiWin.Hwnd, FinishWebViewInit, 0, WV_DATA, "", opts, dll)
        AppLog("WebView2.create requested")
    } catch as e {
        wvBuilding := false
        MsgBox "WebView2 初始化失败:`n" e.Message, "本地搜索", "Iconx"
    }
}

FinishWebViewInit(controller) {
    global wv, wvCore, HTML_FILE, SEARCH_DIR, APP_HOST, STORE_HOST, wvBuilding, APP_DIR
    try {
        wv := controller
        wv.Fill()
        wv.IsVisible := true
        try wv.DefaultBackgroundColor := 0xFFF3F4F7
        wvCore := wv.CoreWebView2
        wvCore.Settings.AreDefaultContextMenusEnabled := true
        wvCore.Settings.IsStatusBarEnabled := false
        try wvCore.Settings.IsZoomControlEnabled := false
        try wvCore.Settings.IsNonClientRegionSupportEnabled := true
        try wvCore.Settings.IsWebMessageEnabled := true
        try wvCore.Settings.AreHostObjectsAllowed := true

        ; 每次导航前确保内嵌 HTML 已写出（独立运行不依赖外部 index.html）
        ; 若后台定时器尚未写完，这里会同步补写；已存在则秒过
        try EnsureEmbeddedHtml()
        if !FileExist(HTML_FILE)
            throw Error("找不到界面:`n" HTML_FILE)

        mapRoot := GetShortPath(SEARCH_DIR)
        ; Map drive roots so preview can use https://files.local/C:/...
        try wvCore.SetVirtualHostNameToFolderMapping(APP_HOST, mapRoot, 1)
        ; Allow reading local files for preview via NavigateToString / custom host
        try {
            ; Map each fixed drive letter if present
            loop parse "CDEFGHIJKLMNOPQRSTUVWXYZ" {
                root := A_LoopField ":\"
                if DirExist(root) {
                    sp := GetShortPath(root)
                    if sp != ""
                        try wvCore.SetVirtualHostNameToFolderMapping(
                            StrLower(A_LoopField) ".disk.local", sp, 1)
                }
            }
        }

        ; Keep bridge + message subscription rooted so GC won't kill UI→AHK
        global searchHost, webMsgSub, queuePollOn
        ; Do NOT InjectAhkComponent / sync host for search UI — sync COM deadlocks
        ; WebView2 and prevents postMessage from ever running. Clipboard uses
        ; postMessage for the same reason. We drain window.__ahkQ via ExecuteScript.
        searchHost := SearchBridge()
        try wvCore.AddHostObjectToScript("ahk", searchHost)
        try webMsgSub := wvCore.add_WebMessageReceived(HandleUiMessage)
        catch as e {
            AppLog("add_WebMessageReceived fail " e.Message)
        }
        AppLog("Host+WebMsg ready token=" webMsgSub)
        wvCore.Navigate("https://" APP_HOST "/index.html?v=" A_Now)
        wvBuilding := false
        AppLog("Navigate issued")
        if !queuePollOn {
            queuePollOn := true
            SetTimer(DrainAhkQueue, 60)
            AppLog("Queue poller started")
        }
        ; Pre-cache common shell icons (non-blocking)
        SetTimer(WarmCommonIcons, -300)
        ; Everything 可能已先于 WebView 就绪；就绪则直接进主界面，切勿再 PushBoot(true,100)
        FlushPendingBoot()
        SetTimer(SyncBootUi, -120)
        ; WebView2 挂载后会重置窗口图标，再设一次
        global guiWin, showWhenReady
        if IsObject(guiWin) {
            SetTimer(() => SetWindowAppIcon(guiWin.Hwnd), -50)
            if showWhenReady {
                showWhenReady := false
                SetTimer(ShowWindow, -80)
            }
        }
    } catch as e {
        wvBuilding := false
        AppLog("FinishWebViewInit fail " e.Message)
        MsgBox "界面加载失败:`n" e.Message, "本地搜索", "Iconx"
    }
}

OnGuiSize(*) {
    global wv
    if IsObject(wv)
        try wv.Fill()
}

ShowWindow() {
    global guiWin, wvBuilding, showWhenReady, wv
    showWhenReady := true
    if !IsObject(guiWin) && !wvBuilding {
        BuildGui()
        ; WebView 异步初始化完成后 FinishWebViewInit 会再 Show
        return
    }
    if !IsObject(guiWin)
        return
    guiWin.Show()
    try {
        if IsObject(wv) {
            wv.IsVisible := true
            wv.Fill()
            wv.NotifyParentWindowPositionChanged()
        }
    }
    SetWindowAppIcon(guiWin.Hwnd)
    try WinActivate("ahk_id " guiWin.Hwnd)
    try WinRestore("ahk_id " guiWin.Hwnd)
    showWhenReady := false
    AppLog("ShowWindow hwnd=" guiWin.Hwnd)
}

; 独立运行：关窗口退出；hosted：只隐藏
OnDashboardClose(*) {
    global dashboardStandalone
    if dashboardStandalone
        ExitApp
    HideWindow()
}

HideWindow() {
    global guiWin
    if IsObject(guiWin)
        guiWin.Hide()
}

MinimizeWindow() {
    global guiWin
    if IsObject(guiWin)
        WinMinimize("ahk_id " guiWin.Hwnd)
}

GetShortPath(longPath) {
    longPath := String(longPath)
    if longPath = ""
        return ""
    buf := Buffer(520 * 2, 0)
    n := DllCall("GetShortPathNameW", "WStr", longPath, "Ptr", buf, "UInt", 520, "UInt")
    if n && n < 520
        return StrGet(buf, "UTF-16")
    return longPath
}

EnsureWebViewLoader() {
    global WV2_DLL, LIB_DIR, WV2_DIR, WV2_AHK
    DirCreate LIB_DIR
    DirCreate WV2_DIR
    if FileExist(WV2_DLL) && FileExist(WV2_AHK)
        return
    ; 兼容旧路径：迁入 lib\webview2
    for p in [
        A_ScriptDir "\lib\WebView2Loader.dll",
        A_ScriptDir "\WebView2Loader.dll",
        A_ScriptDir "\ahk\WebView2Loader.dll",
        A_Temp "\WebView2Loader.dll"
    ] {
        if !FileExist(WV2_DLL) && FileExist(p)
            try FileCopy p, WV2_DLL, 1
    }
    for p in [A_ScriptDir "\lib\WebView2.ahk", A_Temp "\WebView2.ahk"] {
        if !FileExist(WV2_AHK) && FileExist(p)
            try FileCopy p, WV2_AHK, 1
    }
    ; 仍缺则下载（独立运行兜底；启动引导失败后的二次尝试）
    if !FileExist(WV2_AHK) || !FileExist(WV2_DLL) {
        static ahkUrl := "https://raw.githubusercontent.com/thqby/ahk2_lib/master/WebView2/WebView2.ahk"
        static nupkgUrl := "https://api.nuget.org/v3-flatcontainer/microsoft.web.webview2/1.0.2903.40/microsoft.web.webview2.1.0.2903.40.nupkg"
        AppLog("EnsureWebViewLoader downloading…")
        if !FileExist(WV2_AHK)
            DashboardDownloadFile(ahkUrl, WV2_AHK)
        if !FileExist(WV2_DLL)
            DashboardDownloadWebView2Dll(nupkgUrl, WV2_DLL)
    }
}

; ahk_ext 同级是否存在 快捷键4.ahk（有则默认后台待命；无则独立显示 UI）
ParentHotkey4Exists() {
    parent := ""
    SplitPath A_ScriptDir, , &parent
    if parent = ""
        return false
    return FileExist(parent "\快捷键4.ahk")
}

; 从脚本末尾 ;##### local_search_index.html 注释块解码写出 index.html
EnsureEmbeddedHtmlSafe(*) {
    try EnsureEmbeddedHtml()
    catch as e {
        AppLog("EnsureEmbeddedHtmlSafe " e.Message)
        ; 独立首次：窗口可能已出，用提示而不是静默失败
        try TrayTip("本地搜索", "界面文件写出失败：`n" e.Message, "Iconx")
    }
}

EnsureEmbeddedHtml() {
    global HTML_FILE, SEARCH_DIR, EMBED_HTML_TAG
    DirCreate SEARCH_DIR
    ; 已有有效界面则跳过（避免每次启动 FileRead 整份脚本 + base64 解码卡死）
    if FileExist(HTML_FILE) {
        try {
            if FileGetSize(HTML_FILE) > 1000 {
                AppLog("EnsureEmbeddedHtml reuse " HTML_FILE)
                return
            }
        }
    }
    AppLog("EnsureEmbeddedHtml extract begin")
    t0 := A_TickCount
    b64 := ReadEmbeddedCommentB64(EMBED_HTML_TAG)
    if b64 = "" || b64 = "xxxxx" {
        if FileExist(HTML_FILE)
            return
        throw Error("缺少内嵌界面 HTML（注释块 " EMBED_HTML_TAG "）")
    }
    if !B64DecodeToFile(b64, HTML_FILE)
        throw Error("写出界面 HTML 失败:`n" HTML_FILE)
    AppLog("EnsureEmbeddedHtml extract done ms=" (A_TickCount - t0) " size=" FileGetSize(HTML_FILE))
}

ReadEmbeddedCommentB64(tag) {
    content := FileRead(A_ScriptFullPath, "UTF-8")
    mark := ";########################################################################################################### " String(tag)
    p1 := InStr(content, mark)
    if !p1
        return ""
    start := p1 + StrLen(mark)
    if SubStr(content, start, 1) = "`r"
        start += 1
    if SubStr(content, start, 1) = "`n"
        start += 1
    p2 := InStr(content, mark, false, start)
    if !p2
        return ""
    block := SubStr(content, start, p2 - start)
    out := ""
    for line in StrSplit(block, "`n", "`r") {
        line := Trim(line)
        if line = ""
            continue
        if SubStr(line, 1, 1) = ";"
            line := SubStr(line, 2)
        line := RegExReplace(line, "\s+")
        if line = "" || line = "xxxxx"
            continue
        out .= line
    }
    return out
}

B64DecodeToFile(b64, path) {
    b64 := RegExReplace(String(b64), "\s+")
    if b64 = ""
        return false
    size := 0
    if !DllCall("crypt32\CryptStringToBinaryW", "WStr", b64, "UInt", 0, "UInt", 1, "Ptr", 0, "UInt*", &size, "Ptr", 0, "Ptr", 0)
        return false
    buf := Buffer(size)
    if !DllCall("crypt32\CryptStringToBinaryW", "WStr", b64, "UInt", 0, "UInt", 1, "Ptr", buf, "UInt*", &size, "Ptr", 0, "Ptr", 0)
        return false
    SplitPath path, , &dir
    if dir != ""
        DirCreate dir
    f := FileOpen(path, "w")
    if !IsObject(f)
        return false
    f.RawWrite(buf)
    f.Close()
    return FileExist(path) && FileGetSize(path) > 0
}

; 窗口/托盘一律用 shell32 搜索图标（#23），不依赖任何外部 app.ico
SetWindowAppIcon(hwnd) {
    global hAppIconBig, hAppIconSmall
    if !hwnd
        return
    try {
        if !hAppIconBig {
            shell := A_WinDir "\System32\shell32.dll"
            hBig := 0, hSmall := 0
            n1 := DllCall("User32\PrivateExtractIconsW", "WStr", shell
                , "Int", 23, "Int", 32, "Int", 32, "Ptr*", &hBig, "Ptr", 0, "UInt", 1, "UInt", 0, "UInt")
            n2 := DllCall("User32\PrivateExtractIconsW", "WStr", shell
                , "Int", 23, "Int", 16, "Int", 16, "Ptr*", &hSmall, "Ptr", 0, "UInt", 1, "UInt", 0, "UInt")
            if n1 >= 1 && hBig
                hAppIconBig := hBig
            if n2 >= 1 && hSmall
                hAppIconSmall := hSmall
            if !hAppIconSmall
                hAppIconSmall := hAppIconBig
            if !hAppIconBig {
                try hAppIconBig := LoadPicture(shell, "Icon23 W32 H32")
                try hAppIconSmall := LoadPicture(shell, "Icon23 W16 H16")
            }
        }
        if !hAppIconBig
            return
        DllCall("SendMessageW", "Ptr", hwnd, "UInt", 0x80, "Ptr", 1, "Ptr", hAppIconBig)  ; ICON_BIG
        DllCall("SendMessageW", "Ptr", hwnd, "UInt", 0x80, "Ptr", 0, "Ptr", hAppIconSmall) ; ICON_SMALL
        DllCall("SetClassLongPtrW", "Ptr", hwnd, "Int", -14, "Ptr", hAppIconBig)   ; GCLP_HICON
        DllCall("SetClassLongPtrW", "Ptr", hwnd, "Int", -34, "Ptr", hAppIconSmall) ; GCLP_HICONSM
        DllCall("RedrawWindow", "Ptr", hwnd, "Ptr", 0, "Ptr", 0, "UInt", 0x401)
    } catch as e {
        AppLog("SetWindowAppIcon " e.Message)
    }
}

; ── Everything install / start（进度写到圆圈 boot 页）────────────────
StartEverythingBootOnce(*) {
    global evBootStarted, evReady
    if evBootStarted || evReady
        return
    evBootStarted := true
    SetTimer(EnsureEverythingReady, -1)
}

EnsureEverythingReady(*) {
    global evReady
    try {
        PushBoot(true, 5, "检查组件", "正在检查 Everything / ES 是否就绪…")
        Sleep 120
        if !EnsureEverythingFiles() {
            PushBoot(true, 8, "组件缺失", "Everything/ES 下载失败，请检查网络后重试。`n将下载到脚本旁 lib\everything\")
            TrayTip "本地搜索", "Everything/ES 组件缺失或下载失败，请检查网络后重试", "Iconx"
            AppLog("EnsureEverythingReady: components missing")
            return
        }
        PushBoot(true, 28, "启动服务", "正在启动 Everything…")
        Sleep 80
        HideEverythingTrayIcon()
        StartEverythingService()
        HideEverythingTrayIcon()
        PushBoot(true, 42, "磁盘索引中", "正在建立磁盘文件索引，完成后即可搜索。")
        if WaitEverythingIndexed(55) {
            evReady := true
            EnterMainUi()
            SetTimer(() => RunSearch("", "all", "date-desc", 0), -120)
        } else {
            SetTimer(PollIndexProgress, 800)
        }
    } catch as e {
        global bootPct
        AppLog("EnsureEverythingReady " e.Message)
        PushBoot(true, Max(Integer(bootPct), 10), "出错", e.Message)
        TrayTip "本地搜索", e.Message, "Iconx"
    }
}

EnsureEverythingFiles() {
    global EV_EXE, ES_EXE, EV_ZIP, ES_ZIP, EV_URL, EV_DIR, TOOLS_DIR, DATA_ROOT
    DirCreate TOOLS_DIR
    DirCreate EV_DIR

    ; 兼容旧位置 → lib\everything：tools\Everything、data\ 根下散落的工具
    try {
        legacyDirs := []
        home := ""
        try home := EnvGet("HELPME_HOME")
        home := Trim(String(home))
        if home != "" {
            home := RTrim(home, "\/")
            legacyDirs.Push(home "\command_ext\ahk_ext\tools\Everything")
            legacyDirs.Push(home "\command_ext\ahk_ext\data")
        }
        legacyDirs.Push(A_ScriptDir "\tools\Everything")
        legacyDirs.Push(A_ScriptDir "\data")
        if !FileExist(EV_EXE) {
            for legacyTools in legacyDirs {
                if !DirExist(legacyTools)
                    continue
                for name in ["Everything.exe", "everything.exe", "es.exe", "Everything-portable.zip", "ES-portable.zip", "Everything.ini", "Everything.lng"] {
                    src := legacyTools "\" name
                    dst := TOOLS_DIR "\" name
                    if FileExist(src) && !FileExist(dst)
                        try FileCopy(src, dst, 0)
                }
                if FileExist(EV_EXE)
                    break
            }
        }
    }

    ; Reuse system install if present
    sysEv := FindSystemEverything()
    if sysEv != "" {
        EV_EXE := sysEv
        SplitPath EV_EXE, , &evParent
        if FileExist(evParent "\es.exe")
            ES_EXE := evParent "\es.exe"
        AppLog("Using system Everything " EV_EXE)
    }

    if !FileExist(EV_EXE) {
        ; 优先用已内置的便携包，没有才允许下载 Everything（唯一外网依赖）
        if FileExist(EV_ZIP) {
            AppLog("Using bundled Everything zip")
            PushBoot(true, 8, "解压组件", "正在解压内置 Everything…")
            if !UnzipTo(EV_ZIP, EV_DIR) {
                AppLog("Everything unzip failed")
                return false
            }
        } else {
            AppLog("Downloading Everything portable…")
            PushBoot(true, 8, "下载组件", "正在下载 Everything 便携版…")
            if !DownloadFile(EV_URL, EV_ZIP) {
                AppLog("Everything download failed")
                return false
            }
            PushBoot(true, 15, "解压组件", "正在解压 Everything…")
            if !UnzipTo(EV_ZIP, EV_DIR) {
                AppLog("Everything unzip failed")
                return false
            }
        }
        ; Zip may nest a folder
        if !FileExist(EV_EXE) {
            loop files EV_DIR "\*", "D" {
                cand := A_LoopFileFullPath "\Everything.exe"
                if FileExist(cand) {
                    EV_EXE := cand
                    break
                }
            }
            if !FileExist(EV_EXE) {
                loop files EV_DIR "\Everything.exe", "FR" {
                    EV_EXE := A_LoopFileFullPath
                    break
                }
            }
        }
        if !FileExist(EV_EXE) {
            AppLog("Everything.exe missing after unzip")
            return false
        }
    }

    if !FileExist(ES_EXE) {
        ; 本地：Everything 同目录 / 内置 es.exe / 内置 ES zip；再不行则下载 ES CLI
        SplitPath EV_EXE, , &evParent
        if FileExist(evParent "\es.exe")
            ES_EXE := evParent "\es.exe"
        else if FileExist(TOOLS_DIR "\es.exe")
            ES_EXE := TOOLS_DIR "\es.exe"
        else if FileExist(ES_ZIP) {
            AppLog("Extracting bundled ES CLI…")
            PushBoot(true, 20, "准备 ES", "正在解压 ES 命令行…")
            UnzipTo(ES_ZIP, EV_DIR)
            if !FileExist(ES_EXE) {
                loop files EV_DIR "\es.exe", "FR" {
                    ES_EXE := A_LoopFileFullPath
                    break
                }
            }
        }
        if !FileExist(ES_EXE) {
            AppLog("Downloading ES CLI…")
            PushBoot(true, 22, "下载 ES", "正在下载 ES 命令行…")
            if DownloadFile(ES_URL, ES_ZIP) {
                UnzipTo(ES_ZIP, EV_DIR)
                if !FileExist(ES_EXE) {
                    loop files EV_DIR "\es.exe", "FR" {
                        ES_EXE := A_LoopFileFullPath
                        break
                    }
                }
            } else {
                AppLog("ES download failed")
            }
        }
    }
    AppLog("EV=" EV_EXE " ES=" ES_EXE)
    return FileExist(EV_EXE) && FileExist(ES_EXE)
}

FindSystemEverything() {
    ; 仅本机正式安装 + 脚本旁；不要扫其它工程目录
    for p in [
        A_ProgramFiles "\Everything\Everything.exe",
        EnvGet("ProgramFiles(x86)") "\Everything\Everything.exe",
        EnvGet("LOCALAPPDATA") "\Everything\Everything.exe",
        A_ScriptDir "\lib\everything\Everything.exe",
        A_ScriptDir "\lib\everything\everything.exe"
    ] {
        if p != "" && FileExist(p)
            return p
    }
    return ""
}

OpenEverythingOptions(*) {
    global EV_EXE
    if FileExist(EV_EXE) {
        try Run(Format('"{1}" -options', EV_EXE))
        catch as e
            AppLog("OpenEverythingOptions " e.Message)
        return
    }
    try TrayTip("本地搜索", "未找到 Everything，请等待索引组件就绪", "Iconi")
}

DownloadFile(url, dest) {
    try {
        if FileExist(dest)
            FileDelete dest
        SplitPath dest, , &destDir
        if destDir != ""
            DirCreate destDir
        tmp := dest ".part"
        try FileDelete tmp
        ; Prefer curl：Run+轮询，避免 RunWait 卡死界面/圆圈
        curl := A_WinDir "\System32\curl.exe"
        if FileExist(curl) {
            cmd := Format('"{1}" -L --retry 3 --connect-timeout 20 -o "{2}" "{3}"', curl, tmp, url)
            pid := 0
            Run(cmd, , "Hide", &pid)
            t0 := A_TickCount
            lastTip := 0
            while pid && ProcessExist(pid) {
                Sleep 200
                ; 下载中轻微推进圆环，避免一直停在旧百分比
                if (A_TickCount - lastTip) > 800 {
                    lastTip := A_TickCount
                    try {
                        sz := FileExist(tmp) ? FileGetSize(tmp) : 0
                        if sz > 0
                            PushBoot(true, Min(24, 8 + Integer(sz / 200000)), "下载组件", "正在下载… " Round(sz / 1024) " KB")
                    }
                }
                if (A_TickCount - t0) > 180000 {
                    try ProcessClose(pid)
                    break
                }
            }
            if FileExist(tmp) && FileGetSize(tmp) > 1000 {
                try FileMove tmp, dest, 1
                return FileExist(dest) && FileGetSize(dest) > 1000
            }
        }
        ; Fallback WinHttp（1 秒一段 Wait，中间 Sleep 让出消息泵）
        whr := ComObject("WinHttp.WinHttpRequest.5.1")
        whr.Open("GET", url, true)
        whr.Send()
        t1 := A_TickCount
        loop {
            done := false
            try done := !!whr.WaitForResponse(1)
            catch
                break
            if done
                break
            Sleep 50
            if (A_TickCount - t1) > 180000
                return false
        }
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
    } catch as e {
        AppLog("DownloadFile " e.Message)
        return false
    }
}

UnzipTo(zipPath, destDir) {
    try {
        DirCreate destDir
        ps := Format(
            "Expand-Archive -LiteralPath '{1}' -DestinationPath '{2}' -Force",
            StrReplace(zipPath, "'", "''"),
            StrReplace(destDir, "'", "''")
        )
        pid := 0
        Run(Format('powershell -NoProfile -Command "{1}"', ps), , "Hide", &pid)
        t0 := A_TickCount
        while pid && ProcessExist(pid) {
            Sleep 200
            if (A_TickCount - t0) > 120000 {
                try ProcessClose(pid)
                break
            }
        }
        return true
    } catch as e {
        AppLog("UnzipTo " e.Message)
        return false
    }
}

StartEverythingService() {
    global EV_EXE, EV_DIR
    SplitPath EV_EXE, , &wd
    HideEverythingTrayIcon()
    if RepairEverythingIpc()
        return
    ; 无可用实例 → 启动一个
    for pid in GetEverythingPids() {
        try ProcessClose(pid)
    }
    Sleep 200
    try Run(Format('"{1}" -startup', EV_EXE), wd, "Hide")
    catch as e {
        AppLog("StartEverything " e.Message)
        try Run(EV_EXE, wd)
    }
    WaitEsIpc(10000)
    HideEverythingTrayIcon()
    AppLog("Everything started tray=off alive=" EsAlive() " hits=" EsProbeHasHits())
}

; 进程很多或 IPC 空结果时，清掉重拉一个干净实例；返回当前是否可用
RepairEverythingIpc(*) {
    global EV_EXE
    SplitPath EV_EXE, , &wd
    cnt := GetEverythingPids().Length
    if cnt > 0 && EsProbeHasHits() {
        AppLog("Everything IPC ok pids=" cnt)
        return true
    }
    if cnt = 0
        return false
    AppLog("Everything IPC broken pids=" cnt " → hard restart")
    for pid in GetEverythingPids() {
        try ProcessClose(pid)
    }
    t0 := A_TickCount
    while GetEverythingPids().Length && (A_TickCount - t0) < 5000
        Sleep 100
    Sleep 300
    HideEverythingTrayIcon()
    try Run(Format('"{1}" -startup', EV_EXE), wd, "Hide")
    catch as e {
        AppLog("Repair start fail " e.Message)
        return false
    }
    WaitEsIpc(10000)
    HideEverythingTrayIcon()
    ok := EsProbeHasHits()
    AppLog("Everything repaired hits=" ok)
    return ok
}

GetEverythingPids() {
    pids := []
    try {
        for proc in ComObjGet("winmgmts:").ExecQuery("Select ProcessId from Win32_Process where Name='Everything.exe'")
            pids.Push(Integer(proc.ProcessId))
    } catch as e {
        AppLog("GetEverythingPids " e.Message)
        ; fallback: single ProcessExist
        if (pid := ProcessExist("Everything.exe"))
            pids.Push(pid)
    }
    return pids
}

WaitEsIpc(maxMs := 8000) {
    t1 := A_TickCount
    while (A_TickCount - t1) < maxMs {
        if EsAlive()
            return true
        Sleep 200
    }
    return EsAlive()
}

; 无过滤抽几条，确认索引 IPC 真有数据（避开空实例）
EsProbeHasHits() {
    global ES_EXE
    if !FileExist(ES_EXE) || !ProcessExist("Everything.exe")
        return false
    outFile := A_Temp "\es_probe_" A_TickCount ".txt"
    try {
        cmd := Format('"{1}" -n 5 -no-result-error -export-txt "{2}"', ES_EXE, outFile)
        RunWait(cmd, , "Hide")
        if !FileExist(outFile)
            return false
        txt := ""
        try txt := FileRead(outFile, "UTF-8")
        try FileDelete outFile
        return RegExMatch(txt, "i)[A-Za-z]:\\")
    } catch {
        try FileDelete outFile
        return false
    }
}

; 只改 ini，避免反复 -config-value 拉起多余 Everything 进程
HideEverythingTrayIcon(*) {
    global EV_EXE, EV_DIR
    paths := []
    if EV_DIR != ""
        paths.Push(EV_DIR "\Everything.ini")
    try paths.Push(EnvGet("APPDATA") "\Everything\Everything.ini")
    SplitPath EV_EXE, , &wd
    if wd != ""
        paths.Push(wd "\Everything.ini")

    for ini in paths {
        try PatchEverythingIniTray(ini)
    }
}

PatchEverythingIniTray(iniPath) {
    iniPath := String(iniPath)
    if iniPath = ""
        return
    try {
        dir := ""
        SplitPath iniPath, , &dir
        if dir != "" && !DirExist(dir)
            DirCreate dir
        txt := ""
        if FileExist(iniPath) {
            try txt := FileRead(iniPath, "UTF-8")
            catch
                try txt := FileRead(iniPath, "CP0")
        }
        if txt = ""
            txt := "show_tray_icon=0`nshow_in_taskbar=0`n"
        else {
            for pair in [["show_tray_icon", "0"], ["show_in_taskbar", "0"]] {
                key := pair[1], val := pair[2]
                if RegExMatch(txt, "im)^" key "\s*=")
                    txt := RegExReplace(txt, "im)^" key "\s*=.*$", key "=" val)
                else
                    txt .= "`n" key "=" val "`n"
            }
        }
        f := FileOpen(iniPath, "w", "UTF-8-RAW")
        if IsObject(f) {
            f.Write(txt)
            f.Close()
        }
    } catch as e {
        AppLog("PatchEverythingIniTray " iniPath " " e.Message)
    }
}

WaitEverythingIndexed(maxSec := 60) {
    global ES_EXE
    t0 := A_TickCount
    pct := 40
    while (A_TickCount - t0) < maxSec * 1000 {
        if EsAlive() {
            PushBoot(true, 99, "即将完成", "索引已就绪…")
            return true
        }
        pct := Min(92, pct + 2)
        PushBoot(true, pct, "磁盘索引中", "正在建立磁盘文件索引，完成后即可搜索。<br>若本机已安装 Everything 并开机启动，下次会更快就绪。")
        Sleep 700
    }
    return EsAlive()
}

EsAlive() {
    global ES_EXE
    if !FileExist(ES_EXE)
        return false
    if !ProcessExist("Everything.exe")
        return false
    outFile := A_Temp "\es_alive_" A_TickCount ".txt"
    try {
        ; Empty export succeeding means IPC is up (even with 0 hits)
        cmd := Format('"{1}" -n 1 -export-txt "{2}" *', ES_EXE, outFile)
        rc := RunWait(cmd, , "Hide")
        ok := FileExist(outFile)
        try FileDelete outFile
        ; rc 0 = ok; some builds return 1 when no results — still means IPC works if file exists
        return ok || rc = 0
    } catch {
        return false
    }
}

PollIndexProgress(*) {
    global evReady
    static ticks := 0
    ticks += 1
    if EsAlive() {
        evReady := true
        SetTimer(PollIndexProgress, 0)
        EnterMainUi()
        SetTimer(() => RunSearch("", "all", "date-desc", 0), -100)
        return
    }
    PushBoot(true, Min(95, 40 + ticks), "磁盘索引中", "索引仍在建立，请稍候…")
}

; ── Search via ES ─────────────────────────────────────────────────────
; Category filters MUST NOT be wrapped in quotes on the ES command line.
; Quoting "ext:png;jpg" makes Everything return 0 hits (ES 1.1 / IPC quirk).
CatToFilter(cat) {
    switch StrLower(Trim(String(cat))) {
        case "folder": return "/ad"   ; folders only (DIR attribute)
        case "excel":  return "ext:xls;xlsx;xlsm;csv"
        case "word":   return "ext:doc;docx;rtf"
        case "ppt":    return "ext:ppt;pptx"
        case "pdf":    return "ext:pdf"
        case "image":  return "ext:png;jpg;jpeg;gif;webp;bmp;ico;svg;tif;tiff"
        case "video":  return "ext:mp4;mkv;avi;mov;wmv;webm;flv;m4v;mpeg;mpg"
        case "audio":  return "ext:mp3;wav;flac;aac;m4a;ogg;wma"
        case "zip":    return "ext:zip;rar;7z;tar;gz;bz2"
        default:       return ""
    }
}

SortFlags(sort) {
    switch StrLower(String(sort)) {
        case "date-asc":  return "-sort date-modified"
        case "name-asc":  return "-sort name"
        case "size-desc": return "-sort size -sort-descending"
        default:          return "-sort date-modified -sort-descending"
    }
}

; User:  "|" = AND,  "||" = OR
; Everything: space = AND,  "|" = OR
NormalizeSearchQuery(q) {
    q := Trim(String(q))
    if q = ""
        return ""
    orGroups := []
    for g in StrSplit(q, "||") {
        g := Trim(g)
        if g = ""
            continue
        andParts := []
        for p in StrSplit(g, "|") {
            p := Trim(p)
            if p != ""
                andParts.Push(p)
        }
        if andParts.Length = 0
            continue
        andStr := ""
        for i, p in andParts {
            if i > 1
                andStr .= " "
            andStr .= p
        }
        orGroups.Push(andStr)
    }
    if orGroups.Length = 0
        return ""
    out := ""
    for i, g in orGroups {
        if i > 1
            out .= " | "
        out .= g
    }
    return out
}

AppendEsQuery(&cmd, filter, qTrim, drive := "") {
    filter := Trim(String(filter))
    qTrim := Trim(String(qTrim))
    drive := Trim(String(drive))
    drive := RegExReplace(drive, "[^A-Za-z]", "")
    if drive != ""
        cmd .= " " StrUpper(drive) ":"
    if filter != ""
        cmd .= " " filter
    if qTrim = ""
        return
    ; Space = AND in Everything. Never wrap the whole multi-term query in quotes
    ; (that would become a phrase match). Quote only a single term that itself has spaces.
    qSafe := StrReplace(qTrim, '"', "")
    for term in StrSplit(qSafe, A_Space) {
        term := Trim(term)
        if term = ""
            continue
        cmd .= " " term
    }
}

RunSearch(q, cat := "all", sort := "date-desc", gen := 0, offset := 0, drive := "") {
    ; Compat entry — always go through the serial queue
    ScheduleSearch(q, cat, sort, gen, offset, drive)
}

RunSearchNow(q, cat, sort, seq, offset := 0, drive := "") {
    global ES_EXE, evReady, wvCore
    q := String(q)
    cat := String(cat)
    sort := String(sort)
    drive := String(drive)
    seq := Integer(seq)
    offset := Max(0, Integer(offset))

    if !FileExist(ES_EXE) {
        AppLog("ES missing: " ES_EXE)
        return
    }
    if !evReady && !EsAlive() {
        AppLog("ES not ready — skip push")
        return
    }
    evReady := true

    filter := CatToFilter(cat)
    qTrim := NormalizeSearchQuery(Trim(q))
    sortArgs := SortFlags(sort)
    ; Page size for infinite scroll (not a hard cap — scroll keeps loading)
    limit := 50
    outFile := A_Temp "\es_out_" A_TickCount "_" seq ".txt"

    ; Always use viewport-* so offset pagination works ( -n + -viewport-offset returns 0 )
    cmd := Format('"{1}" -viewport-count {2} -viewport-offset {3} -no-result-error {4} -export-txt "{5}"',
        ES_EXE, limit, offset, sortArgs, outFile)
    AppendEsQuery(&cmd, filter, qTrim, drive)

    AppLog("ES cmd seq=" seq " " cmd)
    try RunWait(cmd, , "Hide")
    catch as e {
        AppLog("ES run fail " e.Message)
        PushResults([], 0, offset, offset > 0)
        return
    }
    global pendingSearch
    ; Only discard results when the user changed the query — never drop a page
    ; just because a later load-more was queued.
    if IsObject(pendingSearch) && Integer(pendingSearch.seq) > seq {
        sameQ := String(pendingSearch.q) = q
            && String(pendingSearch.cat) = cat
            && String(pendingSearch.sort) = sort
            && String(pendingSearch.drive) = drive
        if !sameQ {
            AppLog("Skip stale push seq=" seq " pending=" pendingSearch.seq)
            try FileDelete outFile
            return
        }
    }

    items := ParseEsTxt(outFile)
    try FileDelete outFile

    total := items.Length + offset
    ; Count only on first page — keeps scrolling cheap
    if offset = 0 {
        try {
            cntFile := A_Temp "\es_cnt_" A_TickCount "_" seq ".txt"
            cntTail := " -get-result-count -no-result-error"
            AppendEsQuery(&cntTail, filter, qTrim, drive)
            RunWait(A_ComSpec ' /c ""' ES_EXE '"' cntTail ' > "' cntFile '" 2>nul"', , "Hide")
            if FileExist(cntFile) {
                raw := Trim(FileRead(cntFile, "UTF-8"))
                if RegExMatch(raw, "\d+", &m)
                    total := Integer(m[0])
                try FileDelete cntFile
            }
        }
    } else {
        total := -1  ; UI keeps previous totalHits
    }
    AppLog("ES done seq=" seq " offset=" offset " items=" items.Length " total=" total " cat=" cat " drive=" drive " q=" qTrim)
    PushResults(items, total, offset, offset > 0)
}

ParseEsTxt(path) {
    items := []
    if !FileExist(path)
        return items
    try txt := FileRead(path, "UTF-8")
    catch {
        try txt := FileRead(path, "CP0")
        catch
            return items
    }
    for line in StrSplit(txt, "`n", "`r") {
        full := Trim(line, " `t`"")
        if full = "" || (!RegExMatch(full, "i)^[A-Za-z]:\\") && !RegExMatch(full, "^\\\\"))
            continue
        ; ES folder paths often end with "\" — SplitPath would yield empty name
        fullTrim := RTrim(full, "\/")
        SplitPath fullTrim, &name, &dir
        if name = "" {
            ; drive root like "C:"
            name := fullTrim
            dir := ""
        }
        attrs := FileExist(full)
        if !attrs
            attrs := FileExist(fullTrim)
        isDir := (attrs && InStr(attrs, "D")) || (SubStr(full, -1) = "\")
        items.Push({
            name: name,
            path: isDir && SubStr(full, -1) != "\" ? fullTrim : fullTrim,
            dir: dir,
            size: "",
            mtime: "",
            isDir: isDir ? 1 : 0
        })
    }
    return items
}

ParseEsCsv(path) {
    items := []
    if !FileExist(path)
        return items
    try {
        txt := FileRead(path, "UTF-8")
    } catch {
        try txt := FileRead(path, "CP0")
        catch
            return items
    }
    lines := StrSplit(txt, "`n", "`r")
    start := 1
    ; Skip header if present
    if lines.Length && (InStr(lines[1], "Filename") || InStr(lines[1], "Name") || InStr(lines[1], "Size") || InStr(lines[1], "Path"))
        start := 2
    for i, line in lines {
        if i < start
            continue
        line := Trim(line)
        if line = ""
            continue
        cols := ParseCsvLine(line)
        if cols.Length < 1
            continue
        ; Common ES csv: Filename, Size, Date Modified  OR Full Path, Size, Date
        full := cols[1]
        sizeStr := cols.Length >= 2 ? cols[2] : ""
        dateStr := cols.Length >= 3 ? cols[3] : ""
        full := StrReplace(full, '"', "")
        if full = "" || full = "Filename" || full = "Name"
            continue
        SplitPath full, &name, &dir
        isDir := (InStr(FileExist(full), "D") = 1)
        items.Push({
            name: name,
            path: full,
            dir: dir,
            size: sizeStr,
            mtime: dateStr,
            isDir: isDir ? 1 : 0
        })
    }
    return items
}

ParseCsvLine(line) {
    out := []
    i := 1
    len := StrLen(line)
    while i <= len {
        ch := SubStr(line, i, 1)
        if ch = '"' {
            i += 1
            val := ""
            while i <= len {
                c := SubStr(line, i, 1)
                if c = '"' {
                    if SubStr(line, i + 1, 1) = '"' {
                        val .= '"'
                        i += 2
                        continue
                    }
                    i += 1
                    break
                }
                val .= c
                i += 1
            }
            out.Push(val)
            if SubStr(line, i, 1) = ","
                i += 1
            continue
        }
        j := InStr(line, ",", , i)
        if !j {
            out.Push(SubStr(line, i))
            break
        }
        out.Push(SubStr(line, i, j - i))
        i := j + 1
    }
    return out
}

PushResults(items, total, offset := 0, append := false) {
    global wvCore
    if !IsObject(wvCore)
        return
    arr := "["
    first := true
    for it in items {
        if !first
            arr .= ","
        first := false
        arr .= "{"
        arr .= '"name":' JStr(it.name) ","
        arr .= '"path":' JStr(it.path) ","
        arr .= '"size":' JStr(it.HasProp("size") ? it.size : "") ","
        arr .= '"mtime":' JStr(it.HasProp("mtime") ? it.mtime : "") ","
        arr .= '"isDir":' (it.isDir ? "true" : "false") ","
        arr .= '"icon":' JStr(ShellIconUrl(it.path, it.isDir))
        arr .= "}"
    }
    arr .= "]"
    payload := '{"total":' Integer(total)
        . ',"offset":' Integer(offset)
        . ',"append":' (append ? "true" : "false")
        . ',"items":' arr "}"
    js := "try{window.__updateResults&&window.__updateResults(" payload ")}catch(e){console.error('updateResults',e)}"
    try {
        wvCore.ExecuteScriptAsync(js)
        AppLog("PushResults n=" items.Length " total=" total " offset=" offset " append=" append " bytes=" StrLen(payload))
    } catch as e {
        AppLog("PushResults fail " e.Message)
    }
}

; 圆圈 boot 页：on/pct + 标题/说明（不再另开启动窗）
PushBoot(on, pct, title := "", hint := "") {
    global wvCore, bootOn, bootPct, pendingBoot, pendingBootMsg, pendingBootHint
    pct := Integer(pct)
    if on && bootOn && pct < bootPct
        pct := bootPct
    bootOn := !!on
    bootPct := pct
    if title = "" && on
        title := BootTitleForPct(pct)
    if hint = "" && on
        hint := BootHintForPct(pct)
    if on {
        pendingBootMsg := title
        pendingBootHint := hint
    }
    if !IsObject(wvCore) {
        pendingBoot := true
        return
    }
    pendingBoot := false
    ApplyBootToPage(on, pct, title, hint)
}

BootTitleForPct(pct) {
    pct := Integer(pct)
    if pct < 12
        return "正在启动"
    if pct < 22
        return "下载组件"
    if pct < 35
        return "准备 ES"
    if pct < 45
        return "启动服务"
    if pct < 95
        return "磁盘索引中"
    return "即将完成"
}

BootHintForPct(pct) {
    pct := Integer(pct)
    if pct < 12
        return "正在准备本地搜索…"
    if pct < 22
        return "正在下载/准备 Everything…"
    if pct < 35
        return "正在准备 ES 命令行…"
    if pct < 45
        return "正在启动 Everything 服务…"
    if pct < 95
        return "正在建立磁盘文件索引，完成后即可搜索。<br>若本机已安装 Everything 并开机启动，下次会更快就绪。"
    return "索引即将完成…"
}

JsQuote(s) {
    s := StrReplace(String(s), "\", "\\")
    s := StrReplace(s, "'", "\'")
    s := StrReplace(s, "`r", "\r")
    s := StrReplace(s, "`n", "\n")
    return "'" s "'"
}

ApplyBootToPage(on, pct, title := "", hint := "") {
    global wvCore
    if !IsObject(wvCore)
        return
    flag := on ? "true" : "false"
    js := "try{window.__setBoot&&window.__setBoot(" flag "," Integer(pct) ");"
    if on && title != ""
        js .= "var t=document.querySelector('#boot .t1');if(t)t.textContent=" JsQuote(title) ";"
    if on && hint != ""
        js .= "var h=document.querySelector('.boot-hint');if(h)h.innerHTML=" JsQuote(hint) ";"
    js .= "}catch(e){}"
    try wvCore.ExecuteScriptAsync(js)
}

; WebView 晚于 Everything 就绪时，把积压的 boot 状态补推一次
FlushPendingBoot(*) {
    global wvCore, pendingBoot, bootOn, bootPct, pendingBootMsg, pendingBootHint
    if !pendingBoot || !IsObject(wvCore)
        return
    pendingBoot := false
    ApplyBootToPage(bootOn, bootPct, pendingBootMsg, pendingBootHint)
}

; Everything 已就绪 → 关掉索引页进入主界面（可重复调用）
EnterMainUi(*) {
    global evReady, wvCore
    evReady := true
    PushBoot(false, 100)
    ; WebView 尚未就绪时，稍后由 SyncBootUi / uiReady 再补一次
    if !IsObject(wvCore)
        SetTimer(SyncBootUi, -200)
}

SyncBootUi(*) {
    global evReady, wvCore
    if !IsObject(wvCore)
        return
    FlushPendingBoot()
    if evReady || EsAlive() {
        evReady := true
        PushBoot(false, 100)
    }
    ; 未就绪时不要把索引进度打回低百分比
}

; ── Preview ───────────────────────────────────────────────────────────
RequestPreview(path) {
    global wvCore, APP_HOST, ICON_DIR
    path := String(path)
    ; Folder paths from ES may end with "\"
    pathTrim := RTrim(path, "\/")
    if path = "" || (!FileExist(path) && !FileExist(pathTrim) && !DirExist(pathTrim)) {
        PushPreview({ kind: "none", message: "文件不存在" })
        return
    }
    if !FileExist(path) && FileExist(pathTrim)
        path := pathTrim
    SplitPath pathTrim, &name, &dir, &ext
    if name = ""
        name := pathTrim
    ext := StrLower(ext)
    size := 0
    try size := FileGetSize(path)
    mtime := ""
    try mtime := FormatTime(FileGetTime(path, "M"), "yyyy-MM-dd HH:mm:ss")
    sizeText := FormatSize(size)
    attrs := FileExist(path)
    if !attrs
        attrs := FileExist(pathTrim)
    isDir := InStr(attrs, "D") || DirExist(pathTrim)
    icon := ShellIconUrl(pathTrim, isDir)
    ; Avoid shell thumbnails for folders/docs — they often bake a black matte.
    ; Use clean 32px shell icons instead (except real image/video preview media).
    thumb := ""

    if isDir {
        kids := ListFolderPreview(pathTrim, 18)
        PushPreview({
            kind: "folder",
            name: name,
            path: pathTrim,
            dir: dir,
            icon: icon,
            thumb: "",
            typeName: "文件夹",
            sizeText: "",
            mtime: mtime,
            children: kids
        })
        return
    }

    url := FileUrlForPreview(path)
    if ImageExt(ext) || VideoExt(ext)
        thumb := ShellThumbUrl(path, 512)

    if ImageExt(ext) {
        dims := GetImageDims(path)
        PushPreview({
            kind: "image",
            url: url,
            name: name,
            path: path,
            sizeText: sizeText,
            mtime: mtime,
            dims: dims,
            icon: icon
        })
        return
    }
    if VideoExt(ext) {
        PushPreview({
            kind: "video",
            url: url,
            thumb: thumb,
            name: name,
            path: path,
            sizeText: sizeText,
            mtime: mtime,
            icon: icon
        })
        return
    }
    if AudioExt(ext) {
        PushPreview({
            kind: "audio",
            url: url,
            name: name,
            path: path,
            sizeText: sizeText,
            mtime: mtime,
            icon: icon
        })
        return
    }
    if ext = "pdf" {
        PushPreview({
            kind: "pdf",
            url: url,
            name: name,
            path: path,
            sizeText: sizeText,
            mtime: mtime,
            icon: icon,
            thumb: thumb
        })
        return
    }
    ; Office binaries — never dump as "text" (looks like garbage)
    if OfficeExt(ext) {
        PushPreview({
            kind: "fileinfo",
            name: name,
            path: path,
            dir: dir,
            icon: icon,
            thumb: "",
            typeName: ShellTypeName(path, ext),
            sizeText: sizeText,
            mtime: mtime,
            hint: "Office 文档不支持内嵌文本预览，请双击打开"
        })
        return
    }
    if TextExt(ext) {
        text := ReadPreviewText(path, 20 * 1024, &enc)
        if text = "" && enc = "BINARY" {
            PushPreview({
                kind: "fileinfo",
                name: name,
                path: path,
                dir: dir,
                icon: icon,
                thumb: "",
                typeName: ShellTypeName(path, ext),
                sizeText: sizeText,
                mtime: mtime,
                hint: "该文件不是可读文本，请双击用关联程序打开"
            })
            return
        }
        PushPreview({
            kind: "text",
            text: text,
            textTitle: "预览前 20KB 内容",
            encoding: enc,
            name: name,
            path: path,
            sizeText: sizeText,
            mtime: mtime,
            icon: icon
        })
        return
    }
    PushPreview({
        kind: "fileinfo",
        name: name,
        path: path,
        dir: dir,
        icon: icon,
        thumb: "",
        typeName: ShellTypeName(path, ext),
        sizeText: sizeText,
        mtime: mtime
    })
}

ListFolderPreview(dir, maxN := 18) {
    out := []
    try {
        loop files dir "\*", "FD" {
            if out.Length >= maxN
                break
            mark := InStr(A_LoopFileAttrib, "D") ? "📁 " : "📄 "
            out.Push(mark A_LoopFileName)
        }
    }
    return out
}

; Shell thumbnail → https://localsearch.app/icons_v2/th_xxx.png
ShellThumbUrl(path, px := 256) {
    global APP_HOST, ICON_DIR, iconCache
    path := String(path)
    if path = "" || !FileExist(path)
        return ""
    sum := 0
    loop parse path
        sum := (sum * 33 + Ord(A_LoopField)) & 0x7FFFFFFF
    key := "th_" Format("{:08x}", sum) "_" px
    if iconCache.Has(key)
        return iconCache[key]
    DirCreate ICON_DIR
    dest := ICON_DIR "\" key ".png"
    if !FileExist(dest) {
        if !SaveShellThumbnail(path, dest, px)
            return ""
    }
    url := "https://" APP_HOST "/icons_v4/" key ".png"
    iconCache[key] := url
    return url
}

SaveShellThumbnail(path, dest, px := 256) {
    hbm := 0
    try {
        guidItem := Buffer(16)
        DllCall("ole32\CLSIDFromString", "WStr", "{43826d1e-e718-42ee-bc55-a1e261c37bfe}", "Ptr", guidItem)
        pItem := 0
        if DllCall("shell32\SHCreateItemFromParsingName", "WStr", path, "Ptr", 0
            , "Ptr", guidItem, "Ptr*", &pItem, "Int") || !pItem
            return false
        factory := ComObjQuery(pItem, "{bcc18b79-ba16-442f-80c4-8a59c30c463b}")
        ObjRelease(pItem)
        ; GetImage(SIZE size by value, SIIGBF, HBITMAP*) — SIZE is two LONGs
        px := Integer(px)
        sizeVal := (px & 0xFFFFFFFF) | ((px & 0xFFFFFFFF) << 32)
        ComCall(3, factory, "Int64", sizeVal, "UInt", 0x1, "Ptr*", &hbm) ; SIIGBF_BIGGERSIZEOK
        if !hbm
            return false
        ok := SaveHBitmapToPng(hbm, dest)
        DllCall("DeleteObject", "Ptr", hbm)
        hbm := 0
        return ok
    } catch as e {
        AppLog("SaveShellThumbnail " e.Message)
        if hbm
            try DllCall("DeleteObject", "Ptr", hbm)
        return false
    }
}

SaveHBitmapToPng(hbm, dest) {
    if !hbm || !EnsureGdiplus()
        return false
    pBitmap := 0
    try {
        if DllCall("gdiplus\GdipCreateBitmapFromHBITMAP", "Ptr", hbm, "Ptr", 0, "Ptr*", &pBitmap) || !pBitmap
            return false
        clsid := Buffer(16)
        DllCall("ole32\CLSIDFromString", "Str", "{557CF406-1A04-11D3-9A73-0000F81EF32E}", "Ptr", clsid)
        if DllCall("gdiplus\GdipSaveImageToFile", "Ptr", pBitmap, "WStr", dest, "Ptr", clsid, "Ptr", 0)
            return false
        return FileExist(dest)
    } finally {
        if pBitmap
            try DllCall("gdiplus\GdipDisposeImage", "Ptr", pBitmap)
    }
}

GetImageDims(path) {
    w := 0, h := 0
    try {
        EnsureGdiplus()
        global gdipToken
        pBitmap := 0
        if DllCall("gdiplus\GdipCreateBitmapFromFile", "WStr", path, "Ptr*", &pBitmap) || !pBitmap
            return ""
        DllCall("gdiplus\GdipGetImageWidth", "Ptr", pBitmap, "UInt*", &w)
        DllCall("gdiplus\GdipGetImageHeight", "Ptr", pBitmap, "UInt*", &h)
        DllCall("gdiplus\GdipDisposeImage", "Ptr", pBitmap)
        if w > 0 && h > 0
            return w " × " h
    }
    return ""
}

ShellTypeName(path, ext := "") {
    ext := StrLower(ext)
    switch ext {
        case "doc", "docx", "rtf": return "Word 文档"
        case "xls", "xlsx", "xlsm", "csv": return "Excel 表格"
        case "ppt", "pptx": return "PowerPoint 演示文稿"
        case "pdf": return "PDF 文档"
        case "zip", "rar", "7z", "tar", "gz", "bz2": return "压缩文件"
    }
    ; Try shell type name
    try {
        sfi := Buffer(A_PtrSize + 8 + 520 + 160, 0)
        flags := 0x400  ; SHGFI_TYPENAME
        if DllCall("shell32\SHGetFileInfoW", "WStr", path, "UInt", 0, "Ptr", sfi, "UInt", sfi.Size, "UInt", flags, "Ptr") {
            ; szTypeName starts after hIcon+iIcon+dwAttributes+szDisplayName
            off := A_PtrSize + 8 + 520
            tn := StrGet(sfi.Ptr + off, 80, "UTF-16")
            if tn != ""
                return tn
        }
    }
    return (ext != "" ? "." ext " 文件" : "文件")
}

FileUrlForPreview(path) {
    ; Use virtual host per drive: https://c.disk.local/Windows/...
    path := StrReplace(path, "/", "\")
    if RegExMatch(path, "i)^([A-Za-z]):\\(.*)$", &m) {
        drive := StrLower(m[1])
        rest := StrReplace(m[2], "\", "/")
        ; encode each segment lightly
        parts := StrSplit(rest, "/")
        enc := ""
        for i, p in parts {
            if i > 1
                enc .= "/"
            enc .= EncodeUriComp(p)
        }
        return "https://" drive ".disk.local/" enc
    }
    return "file:///" StrReplace(StrReplace(path, "\", "/"), " ", "%20")
}

EncodeUriComp(s) {
    ; Minimal encode for WebView path segments
    s := String(s)
    out := ""
    loop parse s {
        c := A_LoopField
        o := Ord(c)
        if (o >= 0x30 && o <= 0x39) || (o >= 0x41 && o <= 0x5A) || (o >= 0x61 && o <= 0x7A)
            || c = "-" || c = "_" || c = "." || c = "~"
            out .= c
        else if o < 128
            out .= Format("%{:02X}", o)
        else {
            ; UTF-8 bytes
            buf := StrPutVarUtf8(c)
            loop buf.Size - 1
                out .= Format("%{:02X}", NumGet(buf, A_Index - 1, "UChar"))
        }
    }
    return out
}

StrPutVarUtf8(s) {
    n := StrPut(s, "UTF-8")
    buf := Buffer(n)
    StrPut(s, buf, "UTF-8")
    return buf
}

ReadPreviewText(path, maxBytes := 20480, &enc := "UTF-8") {
    enc := "UTF-8"
    try {
        f := FileOpen(path, "r")
        if !IsObject(f)
            return ""
        n := Min(f.Length, maxBytes)
        if n <= 0 {
            f.Close()
            return ""
        }
        buf := Buffer(n)
        f.RawRead(buf)
        f.Close()

        ; BOM
        if n >= 3 && NumGet(buf, 0, "UChar") = 0xEF && NumGet(buf, 1, "UChar") = 0xBB && NumGet(buf, 2, "UChar") = 0xBF {
            enc := "UTF-8"
            return StrGet(buf.Ptr + 3, n - 3, "UTF-8")
        }
        if n >= 2 && NumGet(buf, 0, "UShort") = 0xFEFF {
            enc := "UTF-16 LE"
            return StrGet(buf.Ptr + 2, (n - 2) // 2, "UTF-16")
        }
        if n >= 2 && NumGet(buf, 0, "UShort") = 0xFFFE {
            enc := "UTF-16 BE"
            ; Swap to LE for StrGet
            loop (n // 2) {
                o := (A_Index - 1) * 2
                a := NumGet(buf, o, "UChar")
                b := NumGet(buf, o + 1, "UChar")
                NumPut("UChar", b, buf, o)
                NumPut("UChar", a, buf, o + 1)
            }
            return StrGet(buf.Ptr + 2, (n - 2) // 2, "UTF-16")
        }

        ; Heuristic: UTF-16 LE without BOM (many 0x00 on odd bytes)
        nulls := 0
        loop n {
            if NumGet(buf, A_Index - 1, "UChar") = 0
                nulls++
        }
        if n >= 8 && nulls > n * 0.25 {
            ; Likely UTF-16 or binary
            if nulls > n * 0.4 {
                ; try UTF-16 LE
                t16 := StrGet(buf, n // 2, "UTF-16")
                if TextPreviewScore(t16) >= 70 {
                    enc := "UTF-16"
                    return t16
                }
                enc := "BINARY"
                return ""
            }
        }

        candidates := []
        candidates.Push({ e: "UTF-8", t: StrGet(buf, n, "UTF-8") })
        candidates.Push({ e: "GBK", t: StrGet(buf, n, "CP936") })
        candidates.Push({ e: "ANSI", t: StrGet(buf, n, "CP0") })
        best := candidates[1]
        bestScore := TextPreviewScore(best.t)
        for c in candidates {
            sc := TextPreviewScore(c.t)
            if sc > bestScore {
                bestScore := sc
                best := c
            }
        }
        if bestScore < 35 {
            enc := "BINARY"
            return ""
        }
        enc := best.e
        return best.t
    } catch {
        return ""
    }
}

TextPreviewScore(t) {
    t := String(t ?? "")
    if t = ""
        return 0
    bad := 0, good := 0, n := StrLen(t)
    loop parse t {
        c := Ord(A_LoopField)
        if c = 0xFFFD || c < 9 || (c > 13 && c < 32) {
            bad++
        } else if c = 9 || c = 10 || c = 13 || (c >= 32 && c < 0xFFFE) {
            good++
        }
    }
    if n = 0
        return 0
    ; Prefer fewer replacement/control chars
    return Round(100 * good / n - 40 * bad / n)
}

OfficeExt(e) {
    static s := " doc docx docm rtf xls xlsx xlsm xlsb ppt pptx pptm ods odp odt "
    return InStr(s, " " StrLower(e) " ")
}

PushPreview(obj) {
    global wvCore
    if !IsObject(wvCore)
        return
    js := "{"
    first := true
    for k, v in obj.OwnProps() {
        if !first
            js .= ","
        first := false
        if Type(v) = "Integer" || Type(v) = "Float"
            js .= '"' k '":' v
        else if Type(v) = "Array" {
            js .= '"' k '":['
            f2 := true
            for item in v {
                if !f2
                    js .= ","
                f2 := false
                if Type(item) = "Integer" || Type(item) = "Float"
                    js .= item
                else
                    js .= JStr(item)
            }
            js .= "]"
        } else
            js .= '"' k '":' JStr(v)
    }
    js .= "}"
    try wvCore.ExecuteScriptAsync("window.__setPreview&&window.__setPreview(" js ")")
}

FormatSize(n) {
    n := Number(n)
    if n < 1024
        return n " B"
    if n < 1024 * 1024
        return Round(n / 1024, 2) " KB"
    if n < 1024 * 1024 * 1024
        return Round(n / 1024 / 1024, 2) " MB"
    return Round(n / 1024 / 1024 / 1024, 2) " GB"
}

; ── Shell icons (SHGetFileInfo → PNG under icons/) ────────────────────
WarmCommonIcons(*) {
    global wvCore
    for ext in ["", "folder", "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx",
        "png", "jpg", "jpeg", "gif", "webp", "bmp", "mp4", "mkv", "avi", "mp3",
        "wav", "zip", "rar", "7z", "txt", "exe", "lnk", "html", "json"] {
        try ShellIconUrl("", ext = "folder", ext)
    }
    ; Push sidebar category icons into UI
    try PushCatIcons()
}

PushCatIcons(*) {
    global wvCore
    if !IsObject(wvCore)
        return
    ; NOTE: do not name a local "map" — AHK is case-insensitive and it shadows Map()
    catMap := Map(
        "all", ShellIconUrl("", false, "txt"),
        "folder", ShellIconUrl("", true, "folder"),
        "excel", ShellIconUrl("", false, "xlsx"),
        "word", ShellIconUrl("", false, "docx"),
        "ppt", ShellIconUrl("", false, "pptx"),
        "pdf", ShellIconUrl("", false, "pdf"),
        "image", ShellIconUrl("", false, "png"),
        "video", VideosCategoryIconUrl(),
        "audio", ShellIconUrl("", false, "mp3"),
        "zip", ShellIconUrl("", false, "zip")
    )
    js := "{"
    first := true
    for k, v in catMap {
        if !first
            js .= ","
        first := false
        js .= JStr(k) ":" JStr(v)
    }
    js .= "}"
    try wvCore.ExecuteScriptAsync("window.__setCatIcons&&window.__setCatIcons(" js ")")
}

PushDrives(*) {
    global wvCore
    if !IsObject(wvCore)
        return
    ; 「此电脑 / 我的电脑」系统图标
    computerIco := PathShellIconUrl("::{20D04FE0-3AEA-1069-A2D8-08002B30309D}", "_computer")
    if computerIco = "" {
        kf := KnownFolderPath("{0AC0837C-BBF8-452A-850D-79D08E667CA7}")
        if kf != ""
            computerIco := PathShellIconUrl(kf, "_computer")
    }

    drivesJs := "["
    first := true
    try {
        for ch in StrSplit(DriveGetList()) {
            if ch = ""
                continue
            letter := StrUpper(ch)
            root := letter ":\"
            ico := PathShellIconUrl(root, "_drive_" StrLower(letter))
            label := letter " 盘"
            try {
                vol := DriveGetLabel(root)
                if vol != ""
                    label := vol " (" letter ":)"
                else
                    label := letter ":"
            }
            if !first
                drivesJs .= ","
            first := false
            drivesJs .= '{"letter":' JStr(letter) ',"icon":' JStr(ico) ',"label":' JStr(label) "}"
        }
    } catch as e {
        AppLog("DriveGetList " e.Message)
    }
    drivesJs .= "]"
    js := '{"computer":' JStr(computerIco) ',"drives":' drivesJs "}"
    try wvCore.ExecuteScriptAsync("window.__setDrives&&window.__setDrives(" js ")")
}

; Cache shell icon for a real path / shell CLSID (e.g. drive root, This PC)
PathShellIconUrl(path, key) {
    global APP_HOST, iconCache, ICON_DIR
    path := String(path)
    key := String(key)
    if key = ""
        return ""
    if iconCache.Has(key) && iconCache[key] != ""
        return iconCache[key]
    DirCreate ICON_DIR
    dest := ICON_DIR "\" key ".png"
    if !FileExist(dest) {
        ok := false
        try {
            if RegExMatch(path, "^::\{")
                ok := SaveShellIconFromParse(path, dest)
            else
                ok := SaveShellIconPng(path, false, "realpath", dest)
        } catch as e {
            AppLog("PathShellIcon " key " " e.Message)
        }
        if !ok || !FileExist(dest) {
            ; Fallback: shell32 / imageres 「此电脑」常见索引
            if key = "_computer" {
                try {
                    if ExtractShell32IconPng(15, dest)
                        ok := true
                    else if ExtractShell32IconPng(16, dest)
                        ok := true
                    else if ExtractDllIconSafe(A_WinDir "\System32\imageres.dll", 104, dest)
                        ok := true
                }
            }
        }
        if !ok || !FileExist(dest) {
            iconCache[key] := ""
            return ""
        }
    }
    url := "https://" APP_HOST "/icons_v4/" key ".png"
    iconCache[key] := url
    return url
}

; Parse shell namespace (::{GUID}) → HICON → PNG
SaveShellIconFromParse(displayName, dest) {
    pidl := 0
    if DllCall("shell32\SHParseDisplayName", "WStr", displayName, "Ptr", 0, "Ptr*", &pidl, "UInt", 0, "UInt*", 0) != 0 || !pidl
        return false
    flags := 0x100 | 0x8  ; SHGFI_ICON | SHGFI_PIDL
    sfi := Buffer(A_PtrSize + 8 + 520 + 160, 0)
    okInfo := DllCall("shell32\SHGetFileInfoW", "Ptr", pidl, "UInt", 0
        , "Ptr", sfi, "UInt", sfi.Size, "UInt", flags, "Ptr")
    DllCall("ole32\CoTaskMemFree", "Ptr", pidl)
    if !okInfo
        return false
    hIcon := NumGet(sfi, 0, "Ptr")
    if !hIcon
        return false
    return SaveHIconToPngFile(hIcon, dest, true)
}

ExtractShell32IconPng(index, dest) {
    return ExtractDllIconSafe(A_WinDir "\System32\shell32.dll", index, dest)
}

; Safe extract — never calls GdiplusShutdown (process-lifetime token via EnsureGdiplus)
ExtractDllIconSafe(dll, index, dest) {
    hIcon := 0
    n := DllCall("User32\PrivateExtractIconsW", "WStr", dll, "Int", index, "Int", 32, "Int", 32
        , "Ptr*", &hIcon, "Ptr", 0, "UInt", 1, "UInt", 0, "UInt")
    if n < 1 || !hIcon
        return false
    return SaveHIconToPngFile(hIcon, dest, true)
}

SaveHIconToPngFile(hIcon, dest, destroyIcon := true) {
    w := DllCall("GetSystemMetrics", "Int", 11, "Int")
    h := DllCall("GetSystemMetrics", "Int", 12, "Int")
    if w < 16
        w := 32
    if h < 16
        h := 32
    bi := Buffer(40, 0)
    NumPut("UInt", 40, bi, 0)
    NumPut("Int", w, bi, 4)
    NumPut("Int", -h, bi, 8)
    NumPut("UShort", 1, bi, 12)
    NumPut("UShort", 32, bi, 14)
    hdc := DllCall("CreateCompatibleDC", "Ptr", 0, "Ptr")
    ppv := 0
    hbm := DllCall("CreateDIBSection", "Ptr", hdc, "Ptr", bi, "UInt", 0, "Ptr*", &ppv, "Ptr", 0, "UInt", 0, "Ptr")
    if !hbm || !ppv {
        if destroyIcon
            DllCall("DestroyIcon", "Ptr", hIcon)
        DllCall("DeleteDC", "Ptr", hdc)
        return false
    }
    old := DllCall("SelectObject", "Ptr", hdc, "Ptr", hbm, "Ptr")
    DllCall("ntdll\RtlFillMemory", "Ptr", ppv, "UPtr", w * h * 4, "UChar", 0)
    DllCall("DrawIconEx", "Ptr", hdc, "Int", 0, "Int", 0, "Ptr", hIcon
        , "Int", w, "Int", h, "UInt", 0, "Ptr", 0, "UInt", 0x0003)
    if destroyIcon
        DllCall("DestroyIcon", "Ptr", hIcon)
    FixIconBlackMatte(ppv, w, h)
    ok := false
    if EnsureGdiplus() {
        pBitmap := 0
        if !DllCall("gdiplus\GdipCreateBitmapFromScan0", "Int", w, "Int", h, "Int", w * 4
            , "Int", 0x26200A, "Ptr", ppv, "Ptr*", &pBitmap) && pBitmap {
            pClone := 0
            if !DllCall("gdiplus\GdipCloneImage", "Ptr", pBitmap, "Ptr*", &pClone) && pClone {
                clsid := Buffer(16)
                DllCall("ole32\CLSIDFromString", "Str", "{557CF406-1A04-11D3-9A73-0000F81EF32E}", "Ptr", clsid)
                ok := !DllCall("gdiplus\GdipSaveImageToFile", "Ptr", pClone, "WStr", dest, "Ptr", clsid, "Ptr", 0)
                DllCall("gdiplus\GdipDisposeImage", "Ptr", pClone)
            }
            DllCall("gdiplus\GdipDisposeImage", "Ptr", pBitmap)
        }
    }
    DllCall("SelectObject", "Ptr", hdc, "Ptr", old)
    DllCall("DeleteObject", "Ptr", hbm)
    DllCall("DeleteDC", "Ptr", hdc)
    return ok && FileExist(dest)
}

; Prefer Windows 「视频」库图标（蓝底白三角）；失败再回退 mp4 关联图标
VideosCategoryIconUrl() {
    global APP_HOST, iconCache, ICON_DIR
    key := "_cat_videos"
    if iconCache.Has(key) && iconCache[key] != ""
        return iconCache[key]

    candidates := []
    ; Videos.library-ms is the classic blue folder + play glyph
    try candidates.Push(EnvGet("APPDATA") "\Microsoft\Windows\Libraries\Videos.library-ms")
    try {
        kf := KnownFolderPath("{18989B1D-99B5-455B-841C-AB7C74E4DDFC}")
        if kf != ""
            candidates.Push(kf)
    }
    try candidates.Push(EnvGet("USERPROFILE") "\Videos")
    try candidates.Push(EnvGet("PUBLIC") "\Videos")

    DirCreate ICON_DIR
    dest := ICON_DIR "\" key ".png"
    if !FileExist(dest) {
        ok := false
        for p in candidates {
            if p = "" || (!FileExist(p) && !DirExist(p))
                continue
            try {
                if SaveShellIconPng(p, false, "realpath", dest) && FileExist(dest) {
                    AppLog("Videos icon from " p)
                    ok := true
                    break
                }
            } catch as e {
                AppLog("Videos icon fail " p " " e.Message)
            }
        }
        if !ok {
            iconCache[key] := ""
            return ShellIconUrl("", false, "mp4")
        }
    }
    url := "https://" APP_HOST "/icons_v4/" key ".png"
    iconCache[key] := url
    return url
}

KnownFolderPath(guid) {
    try {
        clsid := Buffer(16, 0)
        if DllCall("ole32\CLSIDFromString", "WStr", guid, "Ptr", clsid) != 0
            return ""
        pPath := 0
        if DllCall("shell32\SHGetKnownFolderPath", "Ptr", clsid, "UInt", 0, "Ptr", 0, "Ptr*", &pPath) != 0 || !pPath
            return ""
        path := StrGet(pPath, "UTF-16")
        DllCall("ole32\CoTaskMemFree", "Ptr", pPath)
        return path
    } catch {
        return ""
    }
}

; Returns https://localsearch.app/icons/xxx.png (cached by extension / folder / exe)
ShellIconUrl(path := "", isDir := false, forceExt := "") {
    global APP_HOST, iconCache
    path := String(path)
    isDir := !!isDir
    key := ""
    if isDir || forceExt = "folder" {
        key := "_folder"
    } else if forceExt != "" {
        key := "_" RegExReplace(StrLower(forceExt), "[^a-z0-9]+", "")
        if key = "_"
            key := "_file"
    } else {
        SplitPath path, , , &ext
        ext := StrLower(ext)
        ; Per-file icons for executables / shortcuts (unique look)
        if ext = "exe" || ext = "lnk" || ext = "ico" || ext = "dll" {
            sum := 0
            loop parse path {
                sum := (sum * 33 + Ord(A_LoopField)) & 0x7FFFFFFF
            }
            key := ext "_" Format("{:08x}", sum)
        } else if ext != "" {
            key := "_" RegExReplace(ext, "[^a-z0-9]+", "")
        } else {
            key := "_file"
        }
    }
    if iconCache.Has(key)
        return iconCache[key]
    fileName := EnsureShellIconFile(key, path, isDir || forceExt = "folder", forceExt)
    if fileName = "" {
        iconCache[key] := ""
        return ""
    }
    url := "https://" APP_HOST "/icons_v4/" fileName
    iconCache[key] := url
    return url
}

EnsureShellIconFile(key, path, isDir, forceExt := "") {
    global ICON_DIR
    DirCreate ICON_DIR
    dest := ICON_DIR "\" key ".png"
    if FileExist(dest)
        return key ".png"

    try {
        if SaveShellIconPng(path, isDir, forceExt, dest)
            return key ".png"
        return ""
    } catch as e {
        AppLog("EnsureShellIcon " key " " e.Message)
        return ""
    }
}

; System LARGE icon (32×32) → 32bpp DIB + DrawIconEx → strip black matte → PNG
SaveShellIconPng(path, isDir, forceExt, dest) {
    flags := 0x100  ; SHGFI_ICON (large / typically 32×32)
    attrs := 0
    query := path
    if isDir || forceExt = "folder" {
        flags |= 0x10
        attrs := 0x10
        query := "folder"
    } else if forceExt = "realpath" {
        ; Keep real path / shell CLSID so specialized icons are used
        if path = ""
            return false
        ; CLSID paths like ::{GUID} don't pass FileExist
        if !RegExMatch(path, "^::\{") && !FileExist(path) && !DirExist(path)
            return false
        query := path
        flags := 0x100  ; SHGFI_ICON only
    } else if forceExt != "" {
        flags |= 0x10
        attrs := 0x80
        query := "file." forceExt
    } else if path = "" || !FileExist(path) {
        SplitPath path, , , &ext
        ext := StrLower(ext)
        flags |= 0x10
        attrs := 0x80
        query := (ext != "" ? "file." ext : "file")
    }
    sfi := Buffer(A_PtrSize + 8 + 520 + 160, 0)
    if !DllCall("shell32\SHGetFileInfoW", "WStr", query, "UInt", attrs
        , "Ptr", sfi, "UInt", sfi.Size, "UInt", flags, "Ptr")
        return false
    hIcon := NumGet(sfi, 0, "Ptr")
    if !hIcon
        return false

    w := DllCall("GetSystemMetrics", "Int", 11, "Int")  ; SM_CXICON
    h := DllCall("GetSystemMetrics", "Int", 12, "Int")  ; SM_CYICON
    if w < 16
        w := 32
    if h < 16
        h := 32

    bi := Buffer(40, 0)
    NumPut("UInt", 40, bi, 0)
    NumPut("Int", w, bi, 4)
    NumPut("Int", -h, bi, 8)
    NumPut("UShort", 1, bi, 12)
    NumPut("UShort", 32, bi, 14)
    NumPut("UInt", 0, bi, 16)

    hdc := DllCall("CreateCompatibleDC", "Ptr", 0, "Ptr")
    ppv := 0
    hbm := DllCall("CreateDIBSection", "Ptr", hdc, "Ptr", bi, "UInt", 0, "Ptr*", &ppv, "Ptr", 0, "UInt", 0, "Ptr")
    if !hbm || !ppv {
        DllCall("DestroyIcon", "Ptr", hIcon)
        DllCall("DeleteDC", "Ptr", hdc)
        return false
    }
    old := DllCall("SelectObject", "Ptr", hdc, "Ptr", hbm, "Ptr")
    DllCall("ntdll\RtlFillMemory", "Ptr", ppv, "UPtr", w * h * 4, "UChar", 0)
    DllCall("DrawIconEx", "Ptr", hdc, "Int", 0, "Int", 0, "Ptr", hIcon
        , "Int", w, "Int", h, "UInt", 0, "Ptr", 0, "UInt", 0x0003)
    DllCall("DestroyIcon", "Ptr", hIcon)

    FixIconBlackMatte(ppv, w, h)

    ok := false
    if EnsureGdiplus() {
        pBitmap := 0
        if !DllCall("gdiplus\GdipCreateBitmapFromScan0", "Int", w, "Int", h, "Int", w * 4
            , "Int", 0x26200A, "Ptr", ppv, "Ptr*", &pBitmap) && pBitmap {
            pClone := 0
            if !DllCall("gdiplus\GdipCloneImage", "Ptr", pBitmap, "Ptr*", &pClone) && pClone {
                clsid := Buffer(16)
                DllCall("ole32\CLSIDFromString", "Str", "{557CF406-1A04-11D3-9A73-0000F81EF32E}", "Ptr", clsid)
                ok := !DllCall("gdiplus\GdipSaveImageToFile", "Ptr", pClone, "WStr", dest, "Ptr", clsid, "Ptr", 0)
                DllCall("gdiplus\GdipDisposeImage", "Ptr", pClone)
            }
            DllCall("gdiplus\GdipDisposeImage", "Ptr", pBitmap)
        }
    }

    DllCall("SelectObject", "Ptr", hdc, "Ptr", old)
    DllCall("DeleteObject", "Ptr", hbm)
    DllCall("DeleteDC", "Ptr", hdc)
    return ok && FileExist(dest)
}

; Convert opaque pure-black (matte) pixels to transparent; keep intentional dark anti-alias
FixIconBlackMatte(ppv, w, h) {
    ; First pass: is there any non-black opaque pixel? (real icon content)
    hasContent := false
    hasOpaqueBlack := false
    n := w * h
    loop n {
        off := (A_Index - 1) * 4
        b := NumGet(ppv, off, "UChar")
        g := NumGet(ppv, off + 1, "UChar")
        r := NumGet(ppv, off + 2, "UChar")
        a := NumGet(ppv, off + 3, "UChar")
        if a > 0 && (r > 8 || g > 8 || b > 8)
            hasContent := true
        if a = 255 && r = 0 && g = 0 && b = 0
            hasOpaqueBlack := true
    }
    if !(hasContent && hasOpaqueBlack)
        return
    loop n {
        off := (A_Index - 1) * 4
        b := NumGet(ppv, off, "UChar")
        g := NumGet(ppv, off + 1, "UChar")
        r := NumGet(ppv, off + 2, "UChar")
        a := NumGet(ppv, off + 3, "UChar")
        ; Pure black with full opacity → leftover matte from GDI
        if a = 255 && r = 0 && g = 0 && b = 0
            NumPut("UInt", 0, ppv, off)  ; A=R=G=B=0
    }
}

ExtractShellIcon(path, isDir, forceExt := "") {
    ; Kept for compatibility — prefer SaveShellIconPng
    flags := 0x100  ; SHGFI_ICON (large)
    attrs := 0
    query := path
    if isDir {
        flags |= 0x10
        attrs := 0x10
        query := "folder"
    } else if forceExt != "" && forceExt != "folder" {
        flags |= 0x10
        attrs := 0x80
        query := "file." forceExt
    } else if path = "" || !FileExist(path) {
        SplitPath path, , , &ext
        ext := StrLower(ext != "" ? ext : forceExt)
        flags |= 0x10
        attrs := 0x80
        query := (ext != "" ? "file." ext : "file")
    }
    sfi := Buffer(A_PtrSize + 8 + 520 + 160, 0)
    r := DllCall("shell32\SHGetFileInfoW", "WStr", query, "UInt", attrs
        , "Ptr", sfi, "UInt", sfi.Size, "UInt", flags, "Ptr")
    if !r
        return 0
    return NumGet(sfi, 0, "Ptr")
}

EnsureGdiplus() {
    global gdipToken
    if gdipToken
        return true
    DllCall("LoadLibrary", "Str", "gdiplus.dll", "Ptr")
    si := Buffer(24, 0)
    NumPut("UInt", 1, si)
    if DllCall("gdiplus\GdiplusStartup", "Ptr*", &gdipToken, "Ptr", si, "Ptr", 0)
        return false
    return gdipToken != 0
}

ImageExt(e) {
    static s := " png jpg jpeg gif webp bmp ico svg tif tiff "
    return InStr(s, " " StrLower(e) " ")
}
VideoExt(e) {
    static s := " mp4 mkv avi mov wmv webm flv m4v mpeg mpg "
    return InStr(s, " " StrLower(e) " ")
}
AudioExt(e) {
    static s := " mp3 wav flac aac m4a ogg wma "
    return InStr(s, " " StrLower(e) " ")
}
TextExt(e) {
    e := StrLower(e)
    static set := " txt log md json jsonl ndjson xml html htm css js ts csv ini conf cfg yaml yml toml ahk go py java c cpp h cs sql php rs "
    return InStr(set, " " e " ")
}

JStr(s) {
    s := String(s ?? "")
    s := StrReplace(s, "\", "\\")
    s := StrReplace(s, "`n", "\n")
    s := StrReplace(s, "`r", "\r")
    s := StrReplace(s, "`t", "\t")
    s := StrReplace(s, '"', '\"')
    return '"' s '"'
}

; ── UI messages / bridge ──────────────────────────────────────────────
; Primary path: JS pushes into window.__ahkQ; AHK polls via ExecuteScript.
; postMessage / hostObject are secondary (sync host intentionally unused).
DrainAhkQueue(*) {
    global wvCore, drainBusy
    if drainBusy || !IsObject(wvCore)
        return
    drainBusy := true
    js := "(()=>{try{const q=window.__ahkQ||[];window.__ahkQ=[];"
        . "try{document.documentElement.dataset.ahkPending='0';}catch(e){}"
        . "return q;}catch(e){return [];}})()"
    try {
        wvCore.ExecuteScriptAsync(js).then(OnDrainResult, OnDrainFail)
    } catch as e {
        drainBusy := false
        AppLog("DrainAhkQueue fail " e.Message)
    }
}

OnDrainFail(err := "") {
    global drainBusy
    drainBusy := false
}

OnDrainResult(result) {
    global drainBusy
    drainBusy := false
    s := Trim(String(result ?? ""))
    if s = "" || s = "null" || s = "undefined" || s = "[]"
        return
    ; ExecuteScript JSON-encodes the returned array → ["msg1","msg2"]
    msgs := ParseJsonStringArray(s)
    if msgs.Length = 0
        return
    for msg in msgs {
        msg := Trim(String(msg))
        if msg = ""
            continue
        AppLog("QueueMsg " SubStr(msg, 1, 200))
        try DispatchUiMsg(msg)
        catch as e {
            AppLog("DispatchUiMsg err " e.Message)
        }
    }
}

; Minimal parser for JSON array of strings: ["a","b\"c"]
ParseJsonStringArray(s) {
    out := []
    s := Trim(s)
    if SubStr(s, 1, 1) != "[" || SubStr(s, -1) != "]"
        return out
    i := 2
    n := StrLen(s)
    while i < n {
        while i < n && InStr(" `t`r`n,", SubStr(s, i, 1))
            i++
        if i >= n || SubStr(s, i, 1) = "]"
            break
        if SubStr(s, i, 1) != '"'
            break
        i++
        val := ""
        while i <= n {
            ch := SubStr(s, i, 1)
            if ch = "\" {
                nxt := SubStr(s, i + 1, 1)
                switch nxt {
                    case '"': val .= '"'
                    case "\": val .= "\"
                    case "n": val .= "`n"
                    case "r": val .= "`r"
                    case "t": val .= "`t"
                    case "/": val .= "/"
                    default: val .= nxt
                }
                i += 2
                continue
            }
            if ch = '"' {
                i++
                break
            }
            val .= ch
            i++
        }
        out.Push(val)
    }
    return out
}

HandleUiMessage(core, args) {
    try {
        msg := ""
        try msg := String(args.TryGetWebMessageAsString())
        catch {
            try {
                msg := String(args.WebMessageAsJson)
                if SubStr(msg, 1, 1) = '"' && SubStr(msg, -1) = '"'
                    msg := SubStr(msg, 2, -1)
                msg := StrReplace(msg, '\"', '"')
            }
        }
        msg := Trim(msg)
        if msg = ""
            return
        AppLog("WebMsg " SubStr(msg, 1, 200))
        DispatchUiMsg(msg)
    } catch as e {
        AppLog("HandleUiMessage err " e.Message)
    }
}   

DispatchUiMsg(msg) {
    msg := String(msg)
    if msg = "uiReady" {
        global uiReady, evReady, dashboardStandalone
        uiReady := true
        SyncBootUi()
        ; 独立运行：确保窗口在前台（下载前就能看见圆圈）
        if dashboardStandalone
            SetTimer(ShowWindow, -1)
        ; 圆圈页就绪后再做下载/索引，进度才能画在圆环上
        SetTimer(StartEverythingBootOnce, -120)
        SetTimer(PushCatIcons, -200)
        SetTimer(PushCatIcons, -800)
        SetTimer(PushDrives, -200)
        SetTimer(PushDrives, -800)
        if evReady
            SetTimer(() => RunSearch("", "all", "date-desc", 0), -150)
        return
    }
    if msg = "close" {
        HideWindow()
        return
    }
    if msg = "escHide" {
        HideWindow()
        return
    }
    if msg = "escConsumed" {
        return
    }
    if msg = "minimize" {
        MinimizeWindow()
        return
    }
    if msg = "drag" {
        global guiWin
        if IsObject(guiWin) {
            DllCall("ReleaseCapture")
            PostMessage 0xA1, 2, 0, , "ahk_id " guiWin.Hwnd
        }
        return
    }
    if msg = "settings" {
        OpenEverythingOptions()
        return
    }
    if SubStr(msg, 1, 8) = "openUrl|" {
        ; 禁止打开外链；仅保留本地 Everything 设置入口
        AppLog("Blocked openUrl " SubStr(msg, 9))
        OpenEverythingOptions()
        return
    }
    if SubStr(msg, 1, 7) = "search|" {
        raw := SubStr(msg, 8)
        q := "", cat := "all", sort := "date-desc", drive := "", gen := 0
        if RegExMatch(raw, '"q"\s*:\s*"((?:\\.|[^"\\])*)"', &m)
            q := UnescapeJson(m[1])
        if RegExMatch(raw, '"cat"\s*:\s*"([^"]*)"', &m)
            cat := m[1]
        if RegExMatch(raw, '"sort"\s*:\s*"([^"]*)"', &m)
            sort := m[1]
        if RegExMatch(raw, '"drive"\s*:\s*"([^"]*)"', &m)
            drive := m[1]
        if RegExMatch(raw, '"gen"\s*:\s*(\d+)', &m)
            gen := Integer(m[1])
        offset := 0
        if RegExMatch(raw, '"offset"\s*:\s*(\d+)', &m)
            offset := Integer(m[1])
        ; Also support search|q|cat|sort
        if !InStr(raw, "{") {
            parts := StrSplit(raw, "|")
            if parts.Length >= 1
                q := parts[1]
            if parts.Length >= 2
                cat := parts[2]
            if parts.Length >= 3
                sort := parts[3]
            if parts.Length >= 4
                offset := Integer(parts[4])
        }
        AppLog("Dispatch search q=" q " cat=" cat " sort=" sort " drive=" drive " offset=" offset)
        ScheduleSearch(q, cat, sort, gen, offset, drive)
        return
    }
    if SubStr(msg, 1, 8) = "preview|" {
        SetTimer(RequestPreview.Bind(SubStr(msg, 9)), -1)
        return
    }
    if SubStr(msg, 1, 5) = "open|" {
        try Run(SubStr(msg, 6))
        return
    }
    if SubStr(msg, 1, 7) = "reveal|" {
        try Run('explorer.exe /select,"' SubStr(msg, 8) '"')
        return
    }
    if SubStr(msg, 1, 9) = "copyFile|" {
        p := SubStr(msg, 10)
        if p != ""
            SetClipboardFiles([p])
        return
    }
    if SubStr(msg, 1, 9) = "copyPath|" {
        p := SubStr(msg, 10)
        if p != ""
            try A_Clipboard := p
        return
    }
    if SubStr(msg, 1, 8) = "copyDir|" {
        p := SubStr(msg, 9)
        if p = ""
            return
        SplitPath p, , &dir
        if dir = ""
            dir := p
        try A_Clipboard := dir
        return
    }
    if SubStr(msg, 1, 8) = "recycle|" {
        p := SubStr(msg, 9)
        if p = ""
            return
        try {
            FileRecycle(p)
            NotifyPathRemoved(p)
        } catch as e {
            AppLog("recycle fail " p " " e.Message)
            try TrayTip("本地搜索", "无法删除：可能被占用或无权限", "Iconx")
        }
        return
    }
}

NotifyPathRemoved(path) {
    global wvCore
    if !IsObject(wvCore) || path = ""
        return
    js := "try{window.__removePath&&window.__removePath(" JStr(path) ")}catch(e){}"
    try wvCore.ExecuteScriptAsync(js)
}

; Put file/folder paths on clipboard as CF_HDROP (Explorer paste)
SetClipboardFiles(paths) {
    if !IsObject(paths) || paths.Length < 1
        return false
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
    totalChars := 1
    for p in uniq
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
    for p in uniq {
        StrPut(p, ptr + pos, "UTF-16")
        pos += (StrLen(p) + 1) * 2
    }
    DllCall("GlobalUnlock", "Ptr", hMem)
    hEffect := DllCall("GlobalAlloc", "UInt", 0x0002, "UPtr", 4, "Ptr")
    if hEffect {
        pEff := DllCall("GlobalLock", "Ptr", hEffect, "Ptr")
        if pEff {
            NumPut("UInt", 1, pEff, 0)
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

ScheduleSearch(q, cat := "all", sort := "date-desc", gen := 0, offset := 0, drive := "") {
    global pendingSearch, searchBusy, searchSeq
    q := String(q)
    cat := String(cat)
    sort := String(sort)
    drive := String(drive)
    offset := Max(0, Integer(offset))
    ; Same query + load-more: keep the earliest offset so we don't skip pages
    if IsObject(pendingSearch)
        && String(pendingSearch.q) = q
        && String(pendingSearch.cat) = cat
        && String(pendingSearch.sort) = sort
        && String(pendingSearch.drive) = drive
        && offset > 0
        && Integer(pendingSearch.offset) > 0
        && offset > Integer(pendingSearch.offset) {
        AppLog("Coalesce load-more keep offset=" pendingSearch.offset " drop=" offset)
        return
    }
    searchSeq += 1
    pendingSearch := {
        q: q,
        cat: cat,
        sort: sort,
        drive: drive,
        gen: Integer(gen),
        offset: offset,
        seq: searchSeq
    }
    if !searchBusy
        SetTimer(FlushPendingSearch, -20)
}

FlushPendingSearch(*) {
    global pendingSearch, searchBusy
    if searchBusy
        return
    if !IsObject(pendingSearch)
        return
    searchBusy := true
    p := pendingSearch
    pendingSearch := ""
    try {
        RunSearchNow(p.q, p.cat, p.sort, p.seq, p.HasProp("offset") ? p.offset : 0, p.HasProp("drive") ? p.drive : "")
    } catch as e {
        AppLog("FlushPendingSearch err " e.Message)
        try PushResults([], 0, 0, false)
    }
    searchBusy := false
    ; Run latest if more queries arrived while we were busy
    if IsObject(pendingSearch)
        SetTimer(FlushPendingSearch, -20)
}

UnescapeJson(s) {
    s := StrReplace(s, "\\", "\")
    s := StrReplace(s, "\n", "`n")
    s := StrReplace(s, "\r", "`r")
    s := StrReplace(s, "\t", "`t")
    s := StrReplace(s, '\"', '"')
    return s
}

class SearchBridge {
    search(q := "", cat := "all", sort := "date-desc") {
        AppLog("Bridge.search q=" q " cat=" cat)
        ScheduleSearch(String(q), String(cat), String(sort), 0)
    }
    preview(path := "") {
        SetTimer(RequestPreview.Bind(String(path)), -1)
    }
    open(path := "") {
        try Run(String(path))
    }
    reveal(path := "") {
        try Run('explorer.exe /select,"' String(path) '"')
    }
    close(*) {
        HideWindow()
    }
    minimize(*) {
        MinimizeWindow()
    }
    drag(*) {
        global guiWin
        if IsObject(guiWin) {
            DllCall("ReleaseCapture")
            PostMessage 0xA1, 2, 0, , "ahk_id " guiWin.Hwnd
        }
    }
}


;########################################################################################################### local_search_index.html
;PCFET0NUWVBFIGh0bWw+DQo8aHRtbCBsYW5nPSJ6aC1DTiI+DQo8aGVhZD4NCjxtZXRhIGNoYXJzZXQ9IlVURi04Ij4NCjxtZXRhIG5hbWU9InZpZXdwb3J0IiBjb250ZW50PSJ3aWR0aD1kZXZpY2Utd2lkdGgsIGluaXRpYWwtc2NhbGU9MSI+DQo8dGl0bGU+5pys5Zyw5pCc57SiPC90aXRsZT4NCjxzdHlsZT4NCjpyb290IHsNCiAgLS1iZzogI2YzZjRmNzsNCiAgLS1wYW5lbDogI2ZmZmZmZjsNCiAgLS1saW5lOiAjZTZlOGVlOw0KICAtLXR4dDogIzFmMjQzMDsNCiAgLS10eHQyOiAjNmI3Mjg1Ow0KICAtLXR4dDM6ICM5YWExYjI7DQogIC0tYWNjOiAjM2I4MmY2Ow0KICAtLWFjYzI6ICMyNTYzZWI7DQogIC0tbmFtZTogIzExMTgyNzsNCiAgLS1uYW1lLWV4dDogI2VhNTgwYzsNCiAgLS1obDogI2ZlZjA4YTsNCiAgLS1obC10ZXh0OiAjODU0ZDBlOw0KICAtLXNlbDogI2VlZjFmNjsNCiAgLS1zaWRlOiAjZjdmOGZiOw0KICAtLXNpZGUtdzogMTQ4cHg7DQogIC0tcmluZzogI2Y1OWUwYjsNCiAgLS1zaGFkb3c6IDAgMTBweCAzMHB4IHJnYmEoMjAsIDI4LCA0NSwgLjA4KTsNCiAgLS1yOiAxMHB4Ow0KICBmb250LWZhbWlseTogIlNlZ29lIFVJIiwgIk1pY3Jvc29mdCBZYUhlaSBVSSIsICJQaW5nRmFuZyBTQyIsIHNhbnMtc2VyaWY7DQp9DQoqIHsgYm94LXNpemluZzogYm9yZGVyLWJveDsgfQ0KaHRtbCwgYm9keSB7IG1hcmdpbjogMDsgaGVpZ2h0OiAxMDAlOyBiYWNrZ3JvdW5kOiB2YXIoLS1iZyk7IGNvbG9yOiB2YXIoLS10eHQpOyBvdmVyZmxvdzogaGlkZGVuOyB9DQpidXR0b24sIGlucHV0IHsgZm9udDogaW5oZXJpdDsgfQ0KI2FwcCB7IGRpc3BsYXk6IGZsZXg7IGZsZXgtZGlyZWN0aW9uOiBjb2x1bW47IGhlaWdodDogMTAwJTsgfQ0KDQovKiBpbmRleGluZyAqLw0KI2Jvb3Qgew0KICBkaXNwbGF5OiBub25lOyBmbGV4OiAxOyBhbGlnbi1pdGVtczogY2VudGVyOyBqdXN0aWZ5LWNvbnRlbnQ6IGNlbnRlcjsNCiAgZmxleC1kaXJlY3Rpb246IGNvbHVtbjsgZ2FwOiAyOHB4OyBiYWNrZ3JvdW5kOiAjZmZmOw0KfQ0KI2Jvb3Qub24geyBkaXNwbGF5OiBmbGV4OyB9DQoucmluZy13cmFwIHsgd2lkdGg6IDE2OHB4OyBoZWlnaHQ6IDE2OHB4OyBwb3NpdGlvbjogcmVsYXRpdmU7IH0NCi5yaW5nLXdyYXAgc3ZnIHsgd2lkdGg6IDEwMCU7IGhlaWdodDogMTAwJTsgdHJhbnNmb3JtOiByb3RhdGUoLTkwZGVnKTsgfQ0KLnJpbmctYmcgeyBmaWxsOiBub25lOyBzdHJva2U6ICNlY2VmZjQ7IHN0cm9rZS13aWR0aDogODsgfQ0KLnJpbmctZmcgeyBmaWxsOiBub25lOyBzdHJva2U6IHZhcigtLXJpbmcpOyBzdHJva2Utd2lkdGg6IDg7IHN0cm9rZS1saW5lY2FwOiByb3VuZDsNCiAgdHJhbnNpdGlvbjogc3Ryb2tlLWRhc2hvZmZzZXQgLjM1cyBlYXNlOyB9DQoucmluZy1sYWJlbCB7DQogIHBvc2l0aW9uOiBhYnNvbHV0ZTsgaW5zZXQ6IDA7IGRpc3BsYXk6IGZsZXg7IGZsZXgtZGlyZWN0aW9uOiBjb2x1bW47DQogIGFsaWduLWl0ZW1zOiBjZW50ZXI7IGp1c3RpZnktY29udGVudDogY2VudGVyOyBnYXA6IDZweDsNCn0NCi5yaW5nLWxhYmVsIC50MSB7IGZvbnQtc2l6ZTogMTZweDsgZm9udC13ZWlnaHQ6IDYwMDsgfQ0KLnJpbmctbGFiZWwgLnQyIHsgZm9udC1zaXplOiAyOHB4OyBmb250LXdlaWdodDogNzAwOyBjb2xvcjogIzExMTgyNzsgfQ0KLmJvb3QtaGludCB7IGNvbG9yOiB2YXIoLS10eHQyKTsgZm9udC1zaXplOiAxM3B4OyBtYXgtd2lkdGg6IDUyMHB4OyB0ZXh0LWFsaWduOiBjZW50ZXI7IGxpbmUtaGVpZ2h0OiAxLjY7IH0NCi5ib290LWhpbnQgYSB7IGNvbG9yOiB2YXIoLS1hY2MpOyB0ZXh0LWRlY29yYXRpb246IG5vbmU7IGN1cnNvcjogcG9pbnRlcjsgfQ0KLmJvb3QtaGludCBhOmhvdmVyIHsgdGV4dC1kZWNvcmF0aW9uOiB1bmRlcmxpbmU7IH0NCg0KLyogY2hyb21lICovDQojY2hyb21lIHsgZGlzcGxheTogZmxleDsgZmxleC1kaXJlY3Rpb246IGNvbHVtbjsgZmxleDogMTsgbWluLWhlaWdodDogMDsgfQ0KI2Nocm9tZS5oaWRkZW4geyBkaXNwbGF5OiBub25lOyB9DQojdG9wIHsNCiAgaGVpZ2h0OiA0OHB4OyBkaXNwbGF5OiBncmlkOw0KICBncmlkLXRlbXBsYXRlLWNvbHVtbnM6IHZhcigtLXNpZGUtdykgbWlubWF4KDI4MHB4LCAxLjFmcikgbWlubWF4KDMyMHB4LCAxLjJmcik7DQogIGFsaWduLWl0ZW1zOiBzdHJldGNoOyBwYWRkaW5nOiAwOyBiYWNrZ3JvdW5kOiAjZmZmOw0KICBib3JkZXItYm90dG9tOiAxcHggc29saWQgdmFyKC0tbGluZSk7DQogIC13ZWJraXQtYXBwLXJlZ2lvbjogZHJhZzsgYXBwLXJlZ2lvbjogZHJhZzsNCn0NCiN0b3AgLm5vLWRyYWcsICN0b3AgYnV0dG9uLCAjdG9wIGlucHV0IHsNCiAgLXdlYmtpdC1hcHAtcmVnaW9uOiBuby1kcmFnOyBhcHAtcmVnaW9uOiBuby1kcmFnOw0KfQ0KI2RyaXZlLXdyYXAgew0KICBwb3NpdGlvbjogcmVsYXRpdmU7IHdpZHRoOiAxMDAlOw0KICBib3JkZXItcmlnaHQ6IDFweCBzb2xpZCB2YXIoLS1saW5lKTsgYmFja2dyb3VuZDogdmFyKC0tc2lkZSk7DQogIGRpc3BsYXk6IGZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7DQp9DQojYnRuLWRyaXZlIHsNCiAgZGlzcGxheTogZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsgZ2FwOiA4cHg7DQogIHdpZHRoOiAxMDAlOyBoZWlnaHQ6IDEwMCU7IHBhZGRpbmc6IDAgMTBweDsNCiAgYm9yZGVyOiAwOyBib3JkZXItcmFkaXVzOiAwOyBiYWNrZ3JvdW5kOiB0cmFuc3BhcmVudDsNCiAgY29sb3I6IHZhcigtLXR4dCk7IGZvbnQtc2l6ZTogMTMuNXB4OyBmb250LXdlaWdodDogNjAwOw0KICBjdXJzb3I6IHBvaW50ZXI7IHRleHQtYWxpZ246IGxlZnQ7DQp9DQojYnRuLWRyaXZlOmhvdmVyIHsgYmFja2dyb3VuZDogI2VlZjFmNjsgY29sb3I6IHZhcigtLWFjYzIpOyB9DQojYnRuLWRyaXZlIC5kcml2ZS1pY28gew0KICB3aWR0aDogMjBweDsgaGVpZ2h0OiAyMHB4OyBvYmplY3QtZml0OiBjb250YWluOyBmbGV4LXNocmluazogMDsNCiAgYmFja2dyb3VuZDogdHJhbnNwYXJlbnQ7DQp9DQojYnRuLWRyaXZlIC5kcml2ZS1pY28uaGlkZGVuIHsgZGlzcGxheTogbm9uZTsgfQ0KI2J0bi1kcml2ZSAuY2FyZXQgeyBmb250LXNpemU6IDEwcHg7IGNvbG9yOiB2YXIoLS10eHQzKTsgbWFyZ2luLWxlZnQ6IGF1dG87IH0NCiNkcml2ZS1sYWJlbCB7IG92ZXJmbG93OiBoaWRkZW47IHRleHQtb3ZlcmZsb3c6IGVsbGlwc2lzOyB3aGl0ZS1zcGFjZTogbm93cmFwOyB9DQojZHJpdmUtbWVudSB7DQogIGRpc3BsYXk6IG5vbmU7IHBvc2l0aW9uOiBhYnNvbHV0ZTsgdG9wOiAxMDAlOyBsZWZ0OiAwOyByaWdodDogMDsgei1pbmRleDogNDA7DQogIHdpZHRoOiAxMDAlOyBtYXgtaGVpZ2h0OiAzMjBweDsgb3ZlcmZsb3c6IGF1dG87DQogIGJhY2tncm91bmQ6ICNmZmY7IGJvcmRlcjogMXB4IHNvbGlkIHZhcigtLWxpbmUpOyBib3JkZXItdG9wOiAwOw0KICBib3gtc2hhZG93OiB2YXIoLS1zaGFkb3cpOyBwYWRkaW5nOiA0cHg7IGJvcmRlci1yYWRpdXM6IDAgMCA4cHggOHB4Ow0KfQ0KI2RyaXZlLW1lbnUub24geyBkaXNwbGF5OiBibG9jazsgfQ0KI2RyaXZlLW1lbnUgYnV0dG9uIHsNCiAgZGlzcGxheTogZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsgZ2FwOiA4cHg7IHdpZHRoOiAxMDAlOw0KICB0ZXh0LWFsaWduOiBsZWZ0OyBib3JkZXI6IDA7IGJhY2tncm91bmQ6IHRyYW5zcGFyZW50Ow0KICBwYWRkaW5nOiA4cHggMTBweDsgYm9yZGVyLXJhZGl1czogNnB4OyBjdXJzb3I6IHBvaW50ZXI7IGNvbG9yOiB2YXIoLS10eHQpOyBmb250LXNpemU6IDEzcHg7DQp9DQojZHJpdmUtbWVudSBidXR0b24gaW1nIHsNCiAgd2lkdGg6IDIwcHg7IGhlaWdodDogMjBweDsgb2JqZWN0LWZpdDogY29udGFpbjsgZmxleC1zaHJpbms6IDA7IGJhY2tncm91bmQ6IHRyYW5zcGFyZW50Ow0KfQ0KI2RyaXZlLW1lbnUgYnV0dG9uOmhvdmVyIHsgYmFja2dyb3VuZDogI2VlZjJmZjsgfQ0KI2RyaXZlLW1lbnUgYnV0dG9uLm9uIHsgYmFja2dyb3VuZDogI2VmZjZmZjsgY29sb3I6IHZhcigtLWFjYzIpOyBmb250LXdlaWdodDogNjAwOyB9DQojc2VhcmNoLXdyYXAgew0KICBkaXNwbGF5OiBmbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBtaW4td2lkdGg6IDA7IGhlaWdodDogMTAwJTsNCiAgcGFkZGluZzogMCAxMnB4OyBib3JkZXItcmlnaHQ6IDFweCBzb2xpZCB2YXIoLS1saW5lKTsNCn0NCiNzZWFyY2gtYm94IHsNCiAgcG9zaXRpb246IHJlbGF0aXZlOyBkaXNwbGF5OiBmbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBnYXA6IDRweDsNCiAgd2lkdGg6IDEwMCU7IGhlaWdodDogMzRweDsNCiAgYm9yZGVyOiAxcHggc29saWQgdmFyKC0tbGluZSk7IGJvcmRlci1yYWRpdXM6IDhweDsNCiAgcGFkZGluZzogMCA0cHggMCAxMHB4OyBiYWNrZ3JvdW5kOiAjZmJmYmZkOyBvdmVyZmxvdzogdmlzaWJsZTsNCn0NCiNzZWFyY2gtYm94OmZvY3VzLXdpdGhpbiB7DQogIGJvcmRlci1jb2xvcjogIzkzYzVmZDsNCiAgYm94LXNoYWRvdzogMCAwIDAgM3B4IHJnYmEoNTksMTMwLDI0NiwuMTUpOw0KICBiYWNrZ3JvdW5kOiAjZmZmOw0KfQ0KI3Egew0KICBmbGV4OiAxOyBtaW4td2lkdGg6IDA7IGhlaWdodDogMTAwJTsNCiAgYm9yZGVyOiAwOyBib3JkZXItcmFkaXVzOiAwOyBwYWRkaW5nOiAwOyBvdXRsaW5lOiBub25lOyBiYWNrZ3JvdW5kOiB0cmFuc3BhcmVudDsNCiAgZm9udC1zaXplOiAxMy41cHg7IGNvbG9yOiB2YXIoLS10eHQpOw0KfQ0KI3E6OnBsYWNlaG9sZGVyIHsgY29sb3I6IHZhcigtLXR4dDMpOyB9DQojYnRuLWNsZWFyIHsNCiAgZGlzcGxheTogbm9uZTsgZmxleC1zaHJpbms6IDA7IGhlaWdodDogMjJweDsgcGFkZGluZzogMCAxMHB4Ow0KICBib3JkZXI6IDA7IGJvcmRlci1yYWRpdXM6IDk5OXB4OyBiYWNrZ3JvdW5kOiAjZWVmMWY2Ow0KICBjb2xvcjogdmFyKC0tdHh0Mik7IGZvbnQtc2l6ZTogMTJweDsgY3Vyc29yOiBwb2ludGVyOyBsaW5lLWhlaWdodDogMjJweDsNCn0NCiNidG4tY2xlYXIub24geyBkaXNwbGF5OiBpbmxpbmUtZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsganVzdGlmeS1jb250ZW50OiBjZW50ZXI7IH0NCiNidG4tY2xlYXI6aG92ZXIgeyBiYWNrZ3JvdW5kOiAjZTJlOGYwOyBjb2xvcjogdmFyKC0tdHh0KTsgfQ0KI2J0bi1oaXN0IHsNCiAgZmxleC1zaHJpbms6IDA7IHdpZHRoOiAyNHB4OyBoZWlnaHQ6IDI0cHg7IGJvcmRlcjogMDsgYm9yZGVyLXJhZGl1czogNnB4Ow0KICBiYWNrZ3JvdW5kOiB0cmFuc3BhcmVudDsgY29sb3I6IHZhcigtLXR4dDMpOyBmb250LXNpemU6IDEwcHg7DQogIGN1cnNvcjogcG9pbnRlcjsgbGluZS1oZWlnaHQ6IDE7IHBhZGRpbmc6IDA7DQp9DQojYnRuLWhpc3Q6aG92ZXIsICNidG4taGlzdC5vbiB7IGJhY2tncm91bmQ6ICNlZWYyZmY7IGNvbG9yOiB2YXIoLS1hY2MyKTsgfQ0KI2hpc3QtbWVudSB7DQogIGRpc3BsYXk6IG5vbmU7IHBvc2l0aW9uOiBhYnNvbHV0ZTsgdG9wOiAxMDAlOyBsZWZ0OiAtMXB4OyByaWdodDogLTFweDsgei1pbmRleDogNDU7DQogIG1heC1oZWlnaHQ6IDI4MHB4OyBvdmVyZmxvdzogYXV0bzsNCiAgYmFja2dyb3VuZDogI2ZmZjsgYm9yZGVyOiAxcHggc29saWQgdmFyKC0tbGluZSk7IGJvcmRlci10b3A6IDA7DQogIGJveC1zaGFkb3c6IDAgOHB4IDE4cHggcmdiYSgxNSwgMjMsIDQyLCAuMDgpOyBwYWRkaW5nOiAycHggNHB4IDRweDsNCiAgYm9yZGVyLXJhZGl1czogMCAwIDhweCA4cHg7DQp9DQojaGlzdC1tZW51Lm9uIHsgZGlzcGxheTogYmxvY2s7IH0NCiNzZWFyY2gtYm94Lmhpc3Qtb3BlbiB7DQogIGJvcmRlci1ib3R0b20tbGVmdC1yYWRpdXM6IDA7IGJvcmRlci1ib3R0b20tcmlnaHQtcmFkaXVzOiAwOw0KfQ0KI2hpc3QtbWVudSBidXR0b24gew0KICBkaXNwbGF5OiBibG9jazsgd2lkdGg6IDEwMCU7IHRleHQtYWxpZ246IGxlZnQ7IGJvcmRlcjogMDsgYmFja2dyb3VuZDogdHJhbnNwYXJlbnQ7DQogIHBhZGRpbmc6IDhweCAxMHB4OyBib3JkZXItcmFkaXVzOiA2cHg7IGN1cnNvcjogcG9pbnRlcjsgY29sb3I6IHZhcigtLXR4dCk7DQogIGZvbnQtc2l6ZTogMTNweDsgb3ZlcmZsb3c6IGhpZGRlbjsgdGV4dC1vdmVyZmxvdzogZWxsaXBzaXM7IHdoaXRlLXNwYWNlOiBub3dyYXA7DQp9DQojaGlzdC1tZW51IGJ1dHRvbjpob3ZlciB7IGJhY2tncm91bmQ6ICNmM2Y0ZjY7IH0NCiNoaXN0LW1lbnUgLmhpc3QtZW1wdHkgew0KICBwYWRkaW5nOiAxMHB4OyBjb2xvcjogdmFyKC0tdHh0Myk7IGZvbnQtc2l6ZTogMTJweDsgdGV4dC1hbGlnbjogY2VudGVyOw0KfQ0KI3RvcC1wcmV2aWV3IHsNCiAgZGlzcGxheTogZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsgbWluLXdpZHRoOiAwOyBwYWRkaW5nOiAwIDE0cHg7DQogIGJhY2tncm91bmQ6ICNmZmY7IGNvbG9yOiB2YXIoLS10eHQyKTsgZm9udC1zaXplOiAxMnB4OyBvdmVyZmxvdzogaGlkZGVuOw0KfQ0KI3RvcC1wcmV2aWV3IC5wdi1tZXRhIHsNCiAgYm9yZGVyOiAwOyBwYWRkaW5nOiAwOyB3aWR0aDogMTAwJTsNCiAgZmxleC13cmFwOiBub3dyYXA7IG92ZXJmbG93OiBoaWRkZW47DQp9DQoNCiNtYWluIHsgZmxleDogMTsgZGlzcGxheTogZ3JpZDsgZ3JpZC10ZW1wbGF0ZS1jb2x1bW5zOiB2YXIoLS1zaWRlLXcpIG1pbm1heCgyODBweCwgMS4xZnIpIG1pbm1heCgzMjBweCwgMS4yZnIpOyBtaW4taGVpZ2h0OiAwOyB9DQoNCi8qIHNpZGUgKi8NCiNzaWRlIHsNCiAgYmFja2dyb3VuZDogdmFyKC0tc2lkZSk7IGJvcmRlci1yaWdodDogMXB4IHNvbGlkIHZhcigtLWxpbmUpOw0KICBkaXNwbGF5OiBmbGV4OyBmbGV4LWRpcmVjdGlvbjogY29sdW1uOyBwYWRkaW5nOiAxMHB4IDhweDsgZ2FwOiAycHg7DQp9DQouY2F0IHsNCiAgZGlzcGxheTogZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsgZ2FwOiAxMHB4OyBoZWlnaHQ6IDQycHg7IHBhZGRpbmc6IDAgMTBweDsNCiAgYm9yZGVyOiAwOyBib3JkZXItcmFkaXVzOiA4cHg7IGJhY2tncm91bmQ6IHRyYW5zcGFyZW50OyBjb2xvcjogdmFyKC0tdHh0KTsgY3Vyc29yOiBwb2ludGVyOw0KICB0ZXh0LWFsaWduOiBsZWZ0OyBwb3NpdGlvbjogcmVsYXRpdmU7DQp9DQouY2F0OmhvdmVyIHsgYmFja2dyb3VuZDogI2VlZjFmNjsgfQ0KLmNhdC5vbiB7IGJhY2tncm91bmQ6ICNlOGViZjI7IGZvbnQtd2VpZ2h0OiA2MDA7IH0NCi5jYXQub246OmJlZm9yZSB7DQogIGNvbnRlbnQ6ICIiOyBwb3NpdGlvbjogYWJzb2x1dGU7IGxlZnQ6IDA7IHRvcDogOHB4OyBib3R0b206IDhweDsgd2lkdGg6IDNweDsNCiAgYm9yZGVyLXJhZGl1czogMnB4OyBiYWNrZ3JvdW5kOiB2YXIoLS1hY2MpOw0KfQ0KLmNhdCAuaWNvIHsNCiAgd2lkdGg6IDMycHg7IGhlaWdodDogMzJweDsgZmxleC1zaHJpbms6IDA7DQogIGRpc3BsYXk6IGlubGluZS1mbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBqdXN0aWZ5LWNvbnRlbnQ6IGNlbnRlcjsNCiAgY29sb3I6IHZhcigtLXR4dDIpOyBmb250LXNpemU6IDE0cHg7IGxpbmUtaGVpZ2h0OiAxOw0KfQ0KLmNhdCBpbWcuaWNvIHsNCiAgd2lkdGg6IDMycHg7IGhlaWdodDogMzJweDsNCiAgb2JqZWN0LWZpdDogY29udGFpbjsgaW1hZ2UtcmVuZGVyaW5nOiBhdXRvOw0KfQ0KI3NpZGUtZm9vdCB7IG1hcmdpbi10b3A6IGF1dG87IHBhZGRpbmc6IDhweCA2cHg7IH0NCiNidG4tc2V0dGluZ3Mgew0KICB3aWR0aDogMzRweDsgaGVpZ2h0OiAzNHB4OyBib3JkZXI6IDA7IGJvcmRlci1yYWRpdXM6IDhweDsgYmFja2dyb3VuZDogdHJhbnNwYXJlbnQ7DQogIGNvbG9yOiB2YXIoLS10eHQyKTsgY3Vyc29yOiBwb2ludGVyOw0KfQ0KI2J0bi1zZXR0aW5nczpob3ZlciB7IGJhY2tncm91bmQ6ICNlZWYxZjY7IGNvbG9yOiB2YXIoLS10eHQpOyB9DQoNCi8qIGxpc3QgKi8NCiNsaXN0LXBhbmUgew0KICBkaXNwbGF5OiBmbGV4OyBmbGV4LWRpcmVjdGlvbjogY29sdW1uOyBtaW4td2lkdGg6IDA7IG1pbi1oZWlnaHQ6IDA7DQogIGJhY2tncm91bmQ6ICNmZmY7IGJvcmRlci1yaWdodDogMXB4IHNvbGlkIHZhcigtLWxpbmUpOyBvdmVyZmxvdzogaGlkZGVuOw0KfQ0KI2xpc3Qgew0KICBmbGV4OiAxOyBtaW4taGVpZ2h0OiAwOyBvdmVyZmxvdy15OiBhdXRvOyBvdmVyZmxvdy14OiBoaWRkZW47IHBhZGRpbmc6IDRweCAwOw0KICBzY3JvbGxiYXItd2lkdGg6IHRoaW47IHNjcm9sbGJhci1jb2xvcjogI2M1YzlkNCB0cmFuc3BhcmVudDsNCiAgLXdlYmtpdC1vdmVyZmxvdy1zY3JvbGxpbmc6IHRvdWNoOw0KfQ0KI2xpc3Q6Oi13ZWJraXQtc2Nyb2xsYmFyIHsgd2lkdGg6IDhweDsgfQ0KI2xpc3Q6Oi13ZWJraXQtc2Nyb2xsYmFyLXRodW1iIHsgYmFja2dyb3VuZDogI2M1YzlkNDsgYm9yZGVyLXJhZGl1czogNHB4OyB9DQoucm93IHsNCiAgZGlzcGxheTogZ3JpZDsgZ3JpZC10ZW1wbGF0ZS1jb2x1bW5zOiA0MHB4IDFmcjsgZ2FwOiAxMHB4Ow0KICBhbGlnbi1pdGVtczogY2VudGVyOyBtaW4taGVpZ2h0OiA0NHB4Ow0KICBwYWRkaW5nOiA2cHggMTRweDsgY3Vyc29yOiBwb2ludGVyOyBib3JkZXItbGVmdDogM3B4IHNvbGlkIHRyYW5zcGFyZW50Ow0KfQ0KLnJvdzpob3ZlciB7IGJhY2tncm91bmQ6ICNmN2Y4ZmI7IH0NCi5yb3cub24geyBiYWNrZ3JvdW5kOiB2YXIoLS1zZWwpOyBib3JkZXItbGVmdC1jb2xvcjogdmFyKC0tYWNjKTsgfQ0KLnJvdyAuZmkgew0KICB3aWR0aDogMzJweDsgaGVpZ2h0OiAzMnB4Ow0KICBjb2xvcjogdmFyKC0tdHh0Mik7IGRpc3BsYXk6IGdyaWQ7IHBsYWNlLWl0ZW1zOiBjZW50ZXI7IGZsZXgtc2hyaW5rOiAwOw0KfQ0KLnJvdyAuZmkgaW1nIHsNCiAgd2lkdGg6IDMycHg7IGhlaWdodDogMzJweDsNCiAgb2JqZWN0LWZpdDogY29udGFpbjsgZGlzcGxheTogYmxvY2s7IGJhY2tncm91bmQ6IHRyYW5zcGFyZW50Ow0KICBpbWFnZS1yZW5kZXJpbmc6IGF1dG87DQp9DQoucm93IC5maSAuZmktZmFsbGJhY2sgeyBmb250LXNpemU6IDE4cHg7IGxpbmUtaGVpZ2h0OiAxOyB9DQoucm93IC5uYW1lIHsgY29sb3I6IHZhcigtLW5hbWUpOyBmb250LXNpemU6IDEzLjVweDsgZm9udC13ZWlnaHQ6IDYwMDsgd29yZC1icmVhazogYnJlYWstYWxsOyBsaW5lLWhlaWdodDogMS4zNTsgfQ0KLnJvdyAubmFtZSAuZXh0IHsgY29sb3I6IHZhcigtLW5hbWUtZXh0KTsgfQ0KLnJvdyAubmFtZSBtYXJrLCAucm93IC5wYXRoIG1hcmsgew0KICBiYWNrZ3JvdW5kOiB2YXIoLS1obCk7IGNvbG9yOiB2YXIoLS1obC10ZXh0KTsgcGFkZGluZzogMCAxcHg7IGJvcmRlci1yYWRpdXM6IDJweDsNCiAgZm9udC13ZWlnaHQ6IDcwMDsNCn0NCi5yb3cgLnBhdGggeyBjb2xvcjogIzRiNTU2MzsgZm9udC1zaXplOiAxMnB4OyBtYXJnaW4tdG9wOiAycHg7IHdvcmQtYnJlYWs6IGJyZWFrLWFsbDsgfQ0KI2xpc3QtZW1wdHkgew0KICBkaXNwbGF5OiBub25lOyBmbGV4OiAxOyBhbGlnbi1pdGVtczogY2VudGVyOyBqdXN0aWZ5LWNvbnRlbnQ6IGNlbnRlcjsNCiAgY29sb3I6IHZhcigtLXR4dDMpOyBmb250LXNpemU6IDE0cHg7DQp9DQojbGlzdC1lbXB0eS5vbiB7IGRpc3BsYXk6IGZsZXg7IH0NCg0KLyogcHJldmlldyAqLw0KI3ByZXZpZXcgew0KICBiYWNrZ3JvdW5kOiAjZmZmOyBtaW4td2lkdGg6IDA7IG1pbi1oZWlnaHQ6IDA7IGRpc3BsYXk6IGZsZXg7IGZsZXgtZGlyZWN0aW9uOiBjb2x1bW47IG92ZXJmbG93OiBoaWRkZW47DQp9DQojcHJldmlldy5vZmYgLnB2LWJvZHkgeyBkaXNwbGF5OiBub25lOyB9DQojcHJldmlldy5vZmYgLnB2LW9mZiB7DQogIGRpc3BsYXk6IGZsZXg7IGZsZXg6IDE7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGp1c3RpZnktY29udGVudDogY2VudGVyOyBjb2xvcjogdmFyKC0tdHh0Myk7DQp9DQoucHYtb2ZmIHsgZGlzcGxheTogbm9uZTsgfQ0KLnB2LW1ldGEgew0KICBkaXNwbGF5OiBmbGV4OyBnYXA6IDE0cHg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IHBhZGRpbmc6IDEwcHggMTRweDsNCiAgYm9yZGVyLWJvdHRvbTogMXB4IHNvbGlkIHZhcigtLWxpbmUpOyBjb2xvcjogdmFyKC0tdHh0Mik7IGZvbnQtc2l6ZTogMTJweDsgZmxleC13cmFwOiB3cmFwOw0KfQ0KLnB2LW1ldGEgYiB7IGNvbG9yOiB2YXIoLS10eHQpOyBmb250LXdlaWdodDogNjAwOyB9DQoucHYtbWV0YSAuZHJ2IHsNCiAgZGlzcGxheTogaW5saW5lLWZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGdhcDogNnB4Ow0KICBjb2xvcjogdmFyKC0tdHh0KTsgZm9udC13ZWlnaHQ6IDYwMDsNCn0NCi5wdi1tZXRhIC5kcnYgaW1nIHsNCiAgd2lkdGg6IDE2cHg7IGhlaWdodDogMTZweDsgb2JqZWN0LWZpdDogY29udGFpbjsgYmFja2dyb3VuZDogdHJhbnNwYXJlbnQ7IGZsZXgtc2hyaW5rOiAwOw0KfQ0KLnB2LWJvZHkgeyBmbGV4OiAxOyBtaW4taGVpZ2h0OiAwOyBkaXNwbGF5OiBmbGV4OyBmbGV4LWRpcmVjdGlvbjogY29sdW1uOyB9DQoucHYtbWVkaWEgew0KICBmbGV4OiAxOyBtaW4taGVpZ2h0OiAwOyBiYWNrZ3JvdW5kOiAjM2Y0NDUwOyBkaXNwbGF5OiBmbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBqdXN0aWZ5LWNvbnRlbnQ6IGNlbnRlcjsNCiAgb3ZlcmZsb3c6IGhpZGRlbjsgcG9zaXRpb246IHJlbGF0aXZlOw0KfQ0KLnB2LW1lZGlhLmNvbXBhY3Qgew0KICBmbGV4OiAwIDAgYXV0bzsgbWluLWhlaWdodDogMDsgaGVpZ2h0OiAwOyBwYWRkaW5nOiAwOyBvdmVyZmxvdzogaGlkZGVuOw0KICBib3JkZXI6IDA7DQp9DQoucHYtYm9keS50ZXh0LW1vZGUgLnB2LW1lZGlhIHsgZGlzcGxheTogbm9uZTsgfQ0KLnB2LWJvZHkudGV4dC1tb2RlIC5wdi10ZXh0IHsNCiAgZmxleDogMTsgZGlzcGxheTogZmxleDsgYm9yZGVyLXRvcDogMDsgbWluLWhlaWdodDogMDsNCn0NCi5wdi1tZWRpYSBpbWcsIC5wdi1tZWRpYSB2aWRlbyB7DQogIG1heC13aWR0aDogMTAwJTsgbWF4LWhlaWdodDogMTAwJTsgb2JqZWN0LWZpdDogY29udGFpbjsgYmFja2dyb3VuZDogIzExMTsNCn0NCi5wdi1tZWRpYSAucHYtZmlsZWluZm8gaW1nLmJpZy1pY28gew0KICBiYWNrZ3JvdW5kOiB0cmFuc3BhcmVudCAhaW1wb3J0YW50Ow0KICBtYXgtd2lkdGg6IDQ4cHg7IG1heC1oZWlnaHQ6IDQ4cHg7DQp9DQoucHYtbWVkaWEgZW1iZWQucGRmLCAucHYtbWVkaWEgaWZyYW1lLnBkZiB7DQogIHdpZHRoOiAxMDAlOyBoZWlnaHQ6IDEwMCU7IGJvcmRlcjogMDsgYmFja2dyb3VuZDogIzUyNTY1OTsNCn0NCi5wdi1tZWRpYSAucGggeyBjb2xvcjogI2NiZDVlMTsgZm9udC1zaXplOiAxM3B4OyB9DQoucHYtZmlsZWluZm8gew0KICBkaXNwbGF5OiBmbGV4OyBmbGV4LWRpcmVjdGlvbjogY29sdW1uOyBhbGlnbi1pdGVtczogc3RyZXRjaDsganVzdGlmeS1jb250ZW50OiBjZW50ZXI7DQogIGdhcDogMTBweDsgcGFkZGluZzogMjhweCAyNHB4OyB0ZXh0LWFsaWduOiBsZWZ0OyB3aWR0aDogMTAwJTsgaGVpZ2h0OiAxMDAlOw0KICBib3gtc2l6aW5nOiBib3JkZXItYm94OyBvdmVyZmxvdzogYXV0bzsNCiAgYmFja2dyb3VuZDogI2Y3ZjhmYjsgY29sb3I6IHZhcigtLXR4dCk7DQp9DQoucHYtZmlsZWluZm8gLmJpZy1pY28gew0KICB3aWR0aDogNDhweDsgaGVpZ2h0OiA0OHB4OyBvYmplY3QtZml0OiBjb250YWluOyBhbGlnbi1zZWxmOiBjZW50ZXI7DQogIGJhY2tncm91bmQ6IHRyYW5zcGFyZW50ICFpbXBvcnRhbnQ7DQogIGltYWdlLXJlbmRlcmluZzogYXV0bzsgZmxleC1zaHJpbms6IDA7DQp9DQoucHYtbWVkaWE6aGFzKC5wdi1maWxlaW5mbykgeyBiYWNrZ3JvdW5kOiAjZjdmOGZiOyB9DQoucHYtZmlsZWluZm8gLmZuIHsNCiAgZm9udC1zaXplOiAxNnB4OyBmb250LXdlaWdodDogNjUwOyBjb2xvcjogdmFyKC0tdHh0KTsNCiAgd29yZC1icmVhazogYnJlYWstYWxsOyB0ZXh0LWFsaWduOiBjZW50ZXI7IHdpZHRoOiAxMDAlOyBsaW5lLWhlaWdodDogMS4zNTsNCn0NCi5wdi1maWxlaW5mbyAudG4gew0KICBmb250LXNpemU6IDEycHg7IGNvbG9yOiB2YXIoLS10eHQyKTsgdGV4dC1hbGlnbjogY2VudGVyOyB3aWR0aDogMTAwJTsNCn0NCi5wdi1maWxlaW5mbyAuaGludCB7DQogIGZvbnQtc2l6ZTogMTJweDsgY29sb3I6ICNiNDUzMDk7IHRleHQtYWxpZ246IGNlbnRlcjsgd2lkdGg6IDEwMCU7IGxpbmUtaGVpZ2h0OiAxLjQ1Ow0KfQ0KLnB2LWZpbGVpbmZvIC5rdiB7DQogIGRpc3BsYXk6IGZsZXg7IGZsZXgtZGlyZWN0aW9uOiBjb2x1bW47IGdhcDogOHB4Ow0KICBtYXJnaW4tdG9wOiA2cHg7IHdpZHRoOiAxMDAlOyBmb250LXNpemU6IDEyLjVweDsgY29sb3I6IHZhcigtLXR4dDIpOw0KfQ0KLnB2LWZpbGVpbmZvIC5rdi1yb3cgew0KICBkaXNwbGF5OiBncmlkOyBncmlkLXRlbXBsYXRlLWNvbHVtbnM6IDQuNWVtIDFmcjsgZ2FwOiAxMnB4OyBhbGlnbi1pdGVtczogc3RhcnQ7DQogIGxpbmUtaGVpZ2h0OiAxLjU1Ow0KfQ0KLnB2LWZpbGVpbmZvIC5rdi1yb3cgLmsgeyBjb2xvcjogdmFyKC0tdHh0Mik7IHdoaXRlLXNwYWNlOiBub3dyYXA7IH0NCi5wdi1maWxlaW5mbyAua3Ytcm93IC52IHsgY29sb3I6IHZhcigtLXR4dCk7IHdvcmQtYnJlYWs6IGJyZWFrLWFsbDsgZm9udC13ZWlnaHQ6IDUwMDsgfQ0KLnB2LWZpbGVpbmZvIC5raWRzIHsNCiAgbWFyZ2luLXRvcDogOHB4OyBmb250LXNpemU6IDEyLjVweDsgY29sb3I6IHZhcigtLXR4dDIpOyBsaW5lLWhlaWdodDogMS42Ow0KICB3b3JkLWJyZWFrOiBicmVhay1hbGw7DQp9DQoucHYtZmlsZWluZm8gLmtpZHMgYiB7IGNvbG9yOiB2YXIoLS10eHQpOyBmb250LXdlaWdodDogNjAwOyB9DQoNCi8qIGNvbnRleHQgbWVudSAqLw0KI2N0eCB7DQogIGRpc3BsYXk6IG5vbmU7IHBvc2l0aW9uOiBmaXhlZDsgei1pbmRleDogMjAwOyBtaW4td2lkdGg6IDE2OHB4Ow0KICBwYWRkaW5nOiA0cHg7IGJhY2tncm91bmQ6ICNmZmY7IGJvcmRlcjogMXB4IHNvbGlkIHZhcigtLWxpbmUpOw0KICBib3JkZXItcmFkaXVzOiA4cHg7IGJveC1zaGFkb3c6IDAgOHB4IDI0cHggcmdiYSgxNSwyMyw0MiwuMTIpOw0KfQ0KI2N0eC5vbiB7IGRpc3BsYXk6IGJsb2NrOyB9DQojY3R4IGJ1dHRvbiB7DQogIGRpc3BsYXk6IGZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGdhcDogMTBweDsgd2lkdGg6IDEwMCU7DQogIGJvcmRlcjogMDsgYmFja2dyb3VuZDogdHJhbnNwYXJlbnQ7IHBhZGRpbmc6IDhweCAxMHB4OyBib3JkZXItcmFkaXVzOiA2cHg7DQogIGN1cnNvcjogcG9pbnRlcjsgY29sb3I6IHZhcigtLXR4dCk7IGZvbnQtc2l6ZTogMTNweDsgdGV4dC1hbGlnbjogbGVmdDsNCn0NCiNjdHggYnV0dG9uOmhvdmVyIHsgYmFja2dyb3VuZDogI2YzZjRmNjsgfQ0KI2N0eCBidXR0b24uZGFuZ2VyIHsgY29sb3I6ICNkYzI2MjY7IH0NCiNjdHggYnV0dG9uLmRhbmdlcjpob3ZlciB7IGJhY2tncm91bmQ6ICNmZWYyZjI7IH0NCiNjdHggLmMtaWNvIHsNCiAgd2lkdGg6IDE2cHg7IGhlaWdodDogMTZweDsgZmxleC1zaHJpbms6IDA7DQogIGRpc3BsYXk6IGlubGluZS1mbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBqdXN0aWZ5LWNvbnRlbnQ6IGNlbnRlcjsNCiAgY29sb3I6ICMzNzQxNTE7DQp9DQojY3R4IGJ1dHRvbi5kYW5nZXIgLmMtaWNvIHsgY29sb3I6ICNkYzI2MjY7IH0NCiNjdHggLmMtaWNvIHN2ZyB7IHdpZHRoOiAxNnB4OyBoZWlnaHQ6IDE2cHg7IGRpc3BsYXk6IGJsb2NrOyB9DQoNCi5wdi10ZXh0IHsNCiAgZmxleDogMTsgbWluLWhlaWdodDogMDsgZGlzcGxheTogZmxleDsgZmxleC1kaXJlY3Rpb246IGNvbHVtbjsgYm9yZGVyLXRvcDogMXB4IHNvbGlkIHZhcigtLWxpbmUpOw0KfQ0KLnB2LXRleHQgLmhkIHsNCiAgcGFkZGluZzogOHB4IDE0cHg7IGZvbnQtc2l6ZTogMTJweDsgY29sb3I6IHZhcigtLXR4dDIpOyBiYWNrZ3JvdW5kOiAjZmFmYmZjOyBib3JkZXItYm90dG9tOiAxcHggc29saWQgdmFyKC0tbGluZSk7DQp9DQoucHYtdGV4dCBwcmUgew0KICBtYXJnaW46IDA7IGZsZXg6IDE7IG92ZXJmbG93OiBhdXRvOyBwYWRkaW5nOiAxMnB4IDE0cHg7IGZvbnQtc2l6ZTogMTJweDsgbGluZS1oZWlnaHQ6IDEuNTsNCiAgd2hpdGUtc3BhY2U6IHByZS13cmFwOyB3b3JkLWJyZWFrOiBicmVhay13b3JkOyBmb250LWZhbWlseTogQ29uc29sYXMsICJTYXJhc2EgTW9ubyBTQyIsIG1vbm9zcGFjZTsNCiAgYmFja2dyb3VuZDogI2ZmZjsgY29sb3I6ICMxMTE4Mjc7DQp9DQoNCi8qIGJvdHRvbSAqLw0KI2JhciB7DQogIGhlaWdodDogNDJweDsgZGlzcGxheTogZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsgZ2FwOiAxNnB4Ow0KICBwYWRkaW5nOiAwIDE0cHg7IGJhY2tncm91bmQ6ICNmZmY7IGJvcmRlci10b3A6IDFweCBzb2xpZCB2YXIoLS1saW5lKTsgZm9udC1zaXplOiAxMi41cHg7IGNvbG9yOiB2YXIoLS10eHQyKTsNCn0NCiNiYXIgLnNvcnQgeyBkaXNwbGF5OiBpbmxpbmUtZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsgZ2FwOiA2cHg7IGN1cnNvcjogcG9pbnRlcjsgYm9yZGVyOiAwOyBiYWNrZ3JvdW5kOiB0cmFuc3BhcmVudDsgY29sb3I6IGluaGVyaXQ7IH0NCiNiYXIgLnNvcnQ6aG92ZXIgeyBjb2xvcjogdmFyKC0tdHh0KTsgfQ0KI2JhciAuc3BhY2VyIHsgZmxleDogMTsgfQ0KLnRvZ2dsZSB7DQogIGRpc3BsYXk6IGlubGluZS1mbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBnYXA6IDhweDsgY3Vyc29yOiBwb2ludGVyOyB1c2VyLXNlbGVjdDogbm9uZTsNCn0NCi50b2dnbGUgaW5wdXQgeyBkaXNwbGF5OiBub25lOyB9DQoudG9nZ2xlIC5zdyB7DQogIHdpZHRoOiAzNnB4OyBoZWlnaHQ6IDIwcHg7IGJvcmRlci1yYWRpdXM6IDk5OXB4OyBiYWNrZ3JvdW5kOiAjZDFkNWRiOyBwb3NpdGlvbjogcmVsYXRpdmU7IHRyYW5zaXRpb246IC4yczsNCn0NCi50b2dnbGUgLnN3OjphZnRlciB7DQogIGNvbnRlbnQ6ICIiOyBwb3NpdGlvbjogYWJzb2x1dGU7IHRvcDogMnB4OyBsZWZ0OiAycHg7IHdpZHRoOiAxNnB4OyBoZWlnaHQ6IDE2cHg7DQogIGJvcmRlci1yYWRpdXM6IDUwJTsgYmFja2dyb3VuZDogI2ZmZjsgdHJhbnNpdGlvbjogLjJzOyBib3gtc2hhZG93OiAwIDFweCAycHggcmdiYSgwLDAsMCwuMik7DQp9DQoudG9nZ2xlIGlucHV0OmNoZWNrZWQgKyAuc3cgeyBiYWNrZ3JvdW5kOiB2YXIoLS1hY2MpOyB9DQoudG9nZ2xlIGlucHV0OmNoZWNrZWQgKyAuc3c6OmFmdGVyIHsgbGVmdDogMThweDsgfQ0KI2NvdW50IHsgY29sb3I6IHZhcigtLXR4dCk7IGZvbnQtdmFyaWFudC1udW1lcmljOiB0YWJ1bGFyLW51bXM7IH0NCjwvc3R5bGU+DQo8L2hlYWQ+DQo8Ym9keT4NCjxkaXYgaWQ9ImFwcCI+DQogIDxkaXYgaWQ9ImJvb3QiPg0KICAgIDxkaXYgY2xhc3M9InJpbmctd3JhcCI+DQogICAgICA8c3ZnIHZpZXdCb3g9IjAgMCAxMjAgMTIwIj4NCiAgICAgICAgPGNpcmNsZSBjbGFzcz0icmluZy1iZyIgY3g9IjYwIiBjeT0iNjAiIHI9IjUyIj48L2NpcmNsZT4NCiAgICAgICAgPGNpcmNsZSBpZD0icmluZy1mZyIgY2xhc3M9InJpbmctZmciIGN4PSI2MCIgY3k9IjYwIiByPSI1MiINCiAgICAgICAgICBzdHJva2UtZGFzaGFycmF5PSIzMjYuNzMiIHN0cm9rZS1kYXNob2Zmc2V0PSIzMjYuNzMiPjwvY2lyY2xlPg0KICAgICAgPC9zdmc+DQogICAgICA8ZGl2IGNsYXNzPSJyaW5nLWxhYmVsIj4NCiAgICAgICAgPGRpdiBjbGFzcz0idDEiPuejgeebmOe0ouW8leS4rTwvZGl2Pg0KICAgICAgICA8ZGl2IGNsYXNzPSJ0MiIgaWQ9ImJvb3QtcGN0Ij4wJTwvZGl2Pg0KICAgICAgPC9kaXY+DQogICAgPC9kaXY+DQogICAgPGRpdiBjbGFzcz0iYm9vdC1oaW50Ij4NCiAgICAgIOato+WcqOW7uueri+ejgeebmOaWh+S7tue0ouW8le+8jOWujOaIkOWQjuWNs+WPr+aQnOe0ouOAgjxicj4NCiAgICAgIOiLpeacrOacuuW3suWuieijhSBFdmVyeXRoaW5nIOW5tuW8gOacuuWQr+WKqO+8jOS4i+asoeS8muabtOW/q+Wwsee7quOAgg0KICAgIDwvZGl2Pg0KICA8L2Rpdj4NCg0KICA8ZGl2IGlkPSJjaHJvbWUiIGNsYXNzPSJoaWRkZW4iPg0KICAgIDxkaXYgaWQ9InRvcCI+DQogICAgICA8ZGl2IGlkPSJkcml2ZS13cmFwIiBjbGFzcz0ibm8tZHJhZyI+DQogICAgICAgIDxidXR0b24gaWQ9ImJ0bi1kcml2ZSIgdHlwZT0iYnV0dG9uIiB0aXRsZT0i6YCJ5oup5pCc57Si56OB55uYIj4NCiAgICAgICAgICA8aW1nIGlkPSJkcml2ZS1idG4taWNvIiBjbGFzcz0iZHJpdmUtaWNvIGhpZGRlbiIgYWx0PSIiIHdpZHRoPSIyMCIgaGVpZ2h0PSIyMCI+DQogICAgICAgICAgPHNwYW4gaWQ9ImRyaXZlLWxhYmVsIj7lhajnm5jmkJzntKI8L3NwYW4+PHNwYW4gY2xhc3M9ImNhcmV0Ij7ilr48L3NwYW4+DQogICAgICAgIDwvYnV0dG9uPg0KICAgICAgICA8ZGl2IGlkPSJkcml2ZS1tZW51IiByb2xlPSJtZW51Ij48L2Rpdj4NCiAgICAgIDwvZGl2Pg0KICAgICAgPGRpdiBpZD0ic2VhcmNoLXdyYXAiIGNsYXNzPSJuby1kcmFnIj4NCiAgICAgICAgPGRpdiBpZD0ic2VhcmNoLWJveCI+DQogICAgICAgICAgPGlucHV0IGlkPSJxIiB0eXBlPSJ0ZXh0IiBwbGFjZWhvbGRlcj0i6L6T5YWl5paH5Lu25ZCNIC8g5omp5bGV5ZCNIC8g6Lev5b6E5YWz6ZSu5a2X77ybfCDooajnpLrkuJTvvIx8fCDooajnpLrmiJYiIGF1dG9jb21wbGV0ZT0ib2ZmIiBzcGVsbGNoZWNrPSJmYWxzZSI+DQogICAgICAgICAgPGJ1dHRvbiBpZD0iYnRuLWNsZWFyIiB0eXBlPSJidXR0b24iIHRpdGxlPSLmuIXnqbrmkJzntKIiPua4heepujwvYnV0dG9uPg0KICAgICAgICAgIDxidXR0b24gaWQ9ImJ0bi1oaXN0IiB0eXBlPSJidXR0b24iIHRpdGxlPSLmnIDov5HmkJzntKIiPuKWvjwvYnV0dG9uPg0KICAgICAgICAgIDxkaXYgaWQ9Imhpc3QtbWVudSIgcm9sZT0ibWVudSI+PC9kaXY+DQogICAgICAgIDwvZGl2Pg0KICAgICAgPC9kaXY+DQogICAgICA8ZGl2IGlkPSJ0b3AtcHJldmlldyIgY2xhc3M9Im5vLWRyYWciPg0KICAgICAgICA8ZGl2IGNsYXNzPSJwdi1tZXRhIiBpZD0icHYtbWV0YSI+6YCJ5oup5paH5Lu25Lul6aKE6KeIPC9kaXY+DQogICAgICA8L2Rpdj4NCiAgICA8L2Rpdj4NCg0KICAgIDxkaXYgaWQ9Im1haW4iPg0KICAgICAgPGFzaWRlIGlkPSJzaWRlIj4NCiAgICAgICAgPGJ1dHRvbiBjbGFzcz0iY2F0IG9uIiBkYXRhLWNhdD0iYWxsIj48c3BhbiBjbGFzcz0iaWNvIiBkYXRhLWNhdC1pY289ImFsbCI+4piwPC9zcGFuPuWFqOmDqDwvYnV0dG9uPg0KICAgICAgICA8YnV0dG9uIGNsYXNzPSJjYXQiIGRhdGEtY2F0PSJmb2xkZXIiPjxzcGFuIGNsYXNzPSJpY28iIGRhdGEtY2F0LWljbz0iZm9sZGVyIj7wn5OBPC9zcGFuPuaWh+S7tuWkuTwvYnV0dG9uPg0KICAgICAgICA8YnV0dG9uIGNsYXNzPSJjYXQiIGRhdGEtY2F0PSJleGNlbCI+PHNwYW4gY2xhc3M9ImljbyIgZGF0YS1jYXQtaWNvPSJleGNlbCI+8J+Tijwvc3Bhbj5FWENFTDwvYnV0dG9uPg0KICAgICAgICA8YnV0dG9uIGNsYXNzPSJjYXQiIGRhdGEtY2F0PSJ3b3JkIj48c3BhbiBjbGFzcz0iaWNvIiBkYXRhLWNhdC1pY289IndvcmQiPvCfk4Q8L3NwYW4+V09SRDwvYnV0dG9uPg0KICAgICAgICA8YnV0dG9uIGNsYXNzPSJjYXQiIGRhdGEtY2F0PSJwcHQiPjxzcGFuIGNsYXNzPSJpY28iIGRhdGEtY2F0LWljbz0icHB0Ij7wn5ORPC9zcGFuPlBQVDwvYnV0dG9uPg0KICAgICAgICA8YnV0dG9uIGNsYXNzPSJjYXQiIGRhdGEtY2F0PSJwZGYiPjxzcGFuIGNsYXNzPSJpY28iIGRhdGEtY2F0LWljbz0icGRmIj7wn5OVPC9zcGFuPlBERjwvYnV0dG9uPg0KICAgICAgICA8YnV0dG9uIGNsYXNzPSJjYXQiIGRhdGEtY2F0PSJpbWFnZSI+PHNwYW4gY2xhc3M9ImljbyIgZGF0YS1jYXQtaWNvPSJpbWFnZSI+8J+WvDwvc3Bhbj7lm77niYc8L2J1dHRvbj4NCiAgICAgICAgPGJ1dHRvbiBjbGFzcz0iY2F0IiBkYXRhLWNhdD0idmlkZW8iPjxzcGFuIGNsYXNzPSJpY28iIGRhdGEtY2F0LWljbz0idmlkZW8iPuKWtjwvc3Bhbj7op4bpopE8L2J1dHRvbj4NCiAgICAgICAgPGJ1dHRvbiBjbGFzcz0iY2F0IiBkYXRhLWNhdD0iYXVkaW8iPjxzcGFuIGNsYXNzPSJpY28iIGRhdGEtY2F0LWljbz0iYXVkaW8iPuKZqjwvc3Bhbj7pn7PpopE8L2J1dHRvbj4NCiAgICAgICAgPGJ1dHRvbiBjbGFzcz0iY2F0IiBkYXRhLWNhdD0iemlwIj48c3BhbiBjbGFzcz0iaWNvIiBkYXRhLWNhdC1pY289InppcCI+8J+XnDwvc3Bhbj7ljovnvKnmlofku7Y8L2J1dHRvbj4NCiAgICAgICAgPGRpdiBpZD0ic2lkZS1mb290Ij4NCiAgICAgICAgICA8YnV0dG9uIGlkPSJidG4tc2V0dGluZ3MiIHR5cGU9ImJ1dHRvbiIgdGl0bGU9Iuiuvue9riI+4pqZPC9idXR0b24+DQogICAgICAgIDwvZGl2Pg0KICAgICAgPC9hc2lkZT4NCg0KICAgICAgPHNlY3Rpb24gaWQ9Imxpc3QtcGFuZSI+DQogICAgICAgIDxkaXYgaWQ9Imxpc3QiPjwvZGl2Pg0KICAgICAgICA8ZGl2IGlkPSJsaXN0LWVtcHR5Ij7ovpPlhaXlhbPplK7lrZflvIDlp4vmkJzntKLvvIzmiJbpgInmi6nlt6bkvqfliIbnsbvmtY/op4g8L2Rpdj4NCiAgICAgIDwvc2VjdGlvbj4NCg0KICAgICAgPHNlY3Rpb24gaWQ9InByZXZpZXciPg0KICAgICAgICA8ZGl2IGNsYXNzPSJwdi1ib2R5IiBpZD0icHYtYm9keSI+DQogICAgICAgICAgPGRpdiBjbGFzcz0icHYtbWVkaWEiIGlkPSJwdi1tZWRpYSI+PGRpdiBjbGFzcz0icGgiPumihOiniOWMujwvZGl2PjwvZGl2Pg0KICAgICAgICAgIDxkaXYgY2xhc3M9InB2LXRleHQiIGlkPSJwdi10ZXh0IiBzdHlsZT0iZGlzcGxheTpub25lIj4NCiAgICAgICAgICAgIDxkaXYgY2xhc3M9ImhkIiBpZD0icHYtdGV4dC1oZCI+6aKE6KeI5YmNIDIwS0Ig5YaF5a65PC9kaXY+DQogICAgICAgICAgICA8cHJlIGlkPSJwdi1wcmUiPjwvcHJlPg0KICAgICAgICAgIDwvZGl2Pg0KICAgICAgICA8L2Rpdj4NCiAgICAgICAgPGRpdiBjbGFzcz0icHYtb2ZmIj7lt7LlhbPpl63mlofku7bpooTop4g8L2Rpdj4NCiAgICAgIDwvc2VjdGlvbj4NCiAgICA8L2Rpdj4NCg0KICAgIDxkaXYgaWQ9ImJhciI+DQogICAgICA8YnV0dG9uIGNsYXNzPSJzb3J0IiBpZD0iYnRuLXNvcnQiIHR5cGU9ImJ1dHRvbiIgdGl0bGU9IuWIh+aNouaOkuW6jyI+4oeFIDxzcGFuIGlkPSJzb3J0LWxhYmVsIj7mjInkv67mlLnml7bpl7TpmY3luo88L3NwYW4+PC9idXR0b24+DQogICAgICA8bGFiZWwgY2xhc3M9InRvZ2dsZSIgdGl0bGU9IuW8gOWQry/lhbPpl63lj7PkvqfpooTop4giPg0KICAgICAgICA8aW5wdXQgdHlwZT0iY2hlY2tib3giIGlkPSJjaGstcHJldmlldyIgY2hlY2tlZD4NCiAgICAgICAgPHNwYW4gY2xhc3M9InN3Ij48L3NwYW4+DQogICAgICAgIDxzcGFuPuW8gOWQr+aWh+S7tumihOiniDwvc3Bhbj4NCiAgICAgIDwvbGFiZWw+DQogICAgICA8ZGl2IGNsYXNzPSJzcGFjZXIiPjwvZGl2Pg0KICAgICAgPGRpdiBpZD0iY291bnQiPuWFsSAwIOadoee7k+aenDwvZGl2Pg0KICAgIDwvZGl2Pg0KICA8L2Rpdj4NCg0KICA8ZGl2IGlkPSJjdHgiIHJvbGU9Im1lbnUiPg0KICAgIDxidXR0b24gdHlwZT0iYnV0dG9uIiBkYXRhLWFjdD0icmV2ZWFsIj48c3BhbiBjbGFzcz0iYy1pY28iPjxzdmcgdmlld0JveD0iMCAwIDI0IDI0IiBmaWxsPSJub25lIiBzdHJva2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIxLjgiPjxwYXRoIGQ9Ik0zIDcuNUExLjUgMS41IDAgMCAxIDQuNSA2SDlsMiAyaDguNUExLjUgMS41IDAgMCAxIDIxIDkuNXY3QTEuNSAxLjUgMCAwIDEgMTkuNSAxOGgtMTVBMS41IDEuNSAwIDAgMSAzIDE2LjV2LTl6Ii8+PC9zdmc+PC9zcGFuPuaWh+S7tuWkueS4reaYvuekujwvYnV0dG9uPg0KICAgIDxidXR0b24gdHlwZT0iYnV0dG9uIiBkYXRhLWFjdD0iY29weSI+PHNwYW4gY2xhc3M9ImMtaWNvIj48c3ZnIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0cm9rZS13aWR0aD0iMS44Ij48cmVjdCB4PSI4IiB5PSI4IiB3aWR0aD0iMTEiIGhlaWdodD0iMTEiIHJ4PSIxLjUiLz48cGF0aCBkPSJNNSAxNVY1LjVBMS41IDEuNSAwIDAgMSA2LjUgNEgxNSIvPjwvc3ZnPjwvc3Bhbj7lpI3liLY8L2J1dHRvbj4NCiAgICA8YnV0dG9uIHR5cGU9ImJ1dHRvbiIgZGF0YS1hY3Q9ImNvcHlQYXRoIj48c3BhbiBjbGFzcz0iYy1pY28iPjxzdmcgdmlld0JveD0iMCAwIDI0IDI0IiBmaWxsPSJub25lIiBzdHJva2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIxLjgiPjxwYXRoIGQ9Ik04IDEyaDgiLz48cGF0aCBkPSJNMTAgN0g3LjVBMi41IDIuNSAwIDAgMCA1IDkuNXY1QTIuNSAyLjUgMCAwIDAgNy41IDE3SDEwIi8+PHBhdGggZD0iTTE0IDdoMi41QTIuNSAyLjUgMCAwIDEgMTkgOS41djVBMi41IDIuNSAwIDAgMSAxNi41IDE3SDE0Ii8+PC9zdmc+PC9zcGFuPuWkjeWItui3r+W+hDwvYnV0dG9uPg0KICAgIDxidXR0b24gdHlwZT0iYnV0dG9uIiBkYXRhLWFjdD0iY29weURpciI+PHNwYW4gY2xhc3M9ImMtaWNvIj48c3ZnIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0cm9rZS13aWR0aD0iMS44Ij48cGF0aCBkPSJNOSA4LjVhMy41IDMuNSAwIDAgMSA1LjYtMi44bDEuNyAxLjRhMy41IDMuNSAwIDAgMS0yLjIgNi4ySDEzIi8+PHBhdGggZD0iTTE1IDE1LjVhMy41IDMuNSAwIDAgMS01LjYgMi44bC0xLjctMS40YTMuNSAzLjUgMCAwIDEgMi4yLTYuMkgxMSIvPjwvc3ZnPjwvc3Bhbj7lpI3liLbmiYDlnKjot6/lvoQ8L2J1dHRvbj4NCiAgICA8YnV0dG9uIHR5cGU9ImJ1dHRvbiIgZGF0YS1hY3Q9InJlY3ljbGUiIGNsYXNzPSJkYW5nZXIiPjxzcGFuIGNsYXNzPSJjLWljbyI+PHN2ZyB2aWV3Qm94PSIwIDAgMjQgMjQiIGZpbGw9Im5vbmUiIHN0cm9rZT0iY3VycmVudENvbG9yIiBzdHJva2Utd2lkdGg9IjEuOCI+PHBhdGggZD0iTTUgOGgxNCIvPjxwYXRoIGQ9Ik05IDhWNi41QTEuNSAxLjUgMCAwIDEgMTAuNSA1aDNBMS41IDEuNSAwIDAgMSAxNSA2LjVWOCIvPjxwYXRoIGQ9Ik03LjUgOGwuNyAxMWExLjUgMS41IDAgMCAwIDEuNSAxLjRoNC42YTEuNSAxLjUgMCAwIDAgMS41LTEuNGwuNy0xMSIvPjwvc3ZnPjwvc3Bhbj7liKDpmaQo5Zue5pS256uZKTwvYnV0dG9uPg0KICA8L2Rpdj4NCjwvZGl2Pg0KPHNjcmlwdD4NCigoKSA9PiB7DQogIGNvbnN0IGJvb3QgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYm9vdCcpOw0KICBjb25zdCBjaHJvbWUgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnY2hyb21lJyk7DQogIGNvbnN0IHJpbmdGZyA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdyaW5nLWZnJyk7DQogIGNvbnN0IGJvb3RQY3QgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYm9vdC1wY3QnKTsNCiAgY29uc3QgcUVsID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3EnKTsNCiAgY29uc3QgbGlzdEVsID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2xpc3QnKTsNCiAgY29uc3QgZW1wdHlFbCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdsaXN0LWVtcHR5Jyk7DQogIGNvbnN0IGNvdW50RWwgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnY291bnQnKTsNCiAgY29uc3QgcHZNZXRhID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3B2LW1ldGEnKTsNCiAgY29uc3QgcHZNZWRpYSA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdwdi1tZWRpYScpOw0KICBjb25zdCBwdlRleHQgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgncHYtdGV4dCcpOw0KICBjb25zdCBwdkJvZHkgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgncHYtYm9keScpOw0KICBjb25zdCBwdlByZSA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdwdi1wcmUnKTsNCiAgY29uc3QgcHZUZXh0SGQgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgncHYtdGV4dC1oZCcpOw0KICBjb25zdCBwcmV2aWV3ID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3ByZXZpZXcnKTsNCiAgY29uc3QgY2hrUHJldmlldyA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjaGstcHJldmlldycpOw0KICBjb25zdCBzb3J0TGFiZWwgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc29ydC1sYWJlbCcpOw0KICBjb25zdCBDSVJDID0gMiAqIE1hdGguUEkgKiA1MjsNCg0KICBsZXQgY2F0ID0gJ2FsbCc7DQogIGxldCBzb3J0ID0gJ2RhdGUtZGVzYyc7DQogIGxldCBkcml2ZSA9ICcnOyAvLyAnJyA9IGFsbCBkaXNrcywgJ0MnIC8gJ0QnIC8gLi4uDQogIGxldCBpdGVtcyA9IFtdOw0KICBsZXQgc2VsZWN0ZWQgPSAtMTsNCiAgbGV0IHByZXZpZXdPbiA9IHRydWU7DQogIGxldCBzZWFyY2hUaW1lciA9IDA7DQogIGxldCBnZW4gPSAwOw0KICBsZXQgdG90YWxIaXRzID0gMDsNCiAgbGV0IGxvYWRpbmdNb3JlID0gZmFsc2U7DQogIGxldCBoYXNNb3JlID0gZmFsc2U7DQoNCiAgY29uc3QgZHJpdmVMYWJlbCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdkcml2ZS1sYWJlbCcpOw0KICBjb25zdCBkcml2ZU1lbnUgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnZHJpdmUtbWVudScpOw0KICBjb25zdCBidG5Ecml2ZSA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdidG4tZHJpdmUnKTsNCiAgY29uc3QgZHJpdmVCdG5JY28gPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnZHJpdmUtYnRuLWljbycpOw0KICBsZXQgZHJpdmVNZXRhID0geyBjb21wdXRlcjogJycsIGRyaXZlczogW10gfTsNCg0KICBmdW5jdGlvbiBkcml2ZVRleHQoKSB7DQogICAgaWYgKCFkcml2ZSkgcmV0dXJuICflhajnm5jmkJzntKInOw0KICAgIGNvbnN0IGhpdCA9IChkcml2ZU1ldGEuZHJpdmVzIHx8IFtdKS5maW5kKGQgPT4gU3RyaW5nKGQubGV0dGVyIHx8ICcnKS50b1VwcGVyQ2FzZSgpID09PSBkcml2ZSk7DQogICAgaWYgKGhpdCAmJiBoaXQubGFiZWwpIHJldHVybiBoaXQubGFiZWw7DQogICAgcmV0dXJuIGRyaXZlLnRvVXBwZXJDYXNlKCkgKyAnIOebmCc7DQogIH0NCiAgZnVuY3Rpb24gc2V0QnRuSWNvbih1cmwpIHsNCiAgICBpZiAodXJsKSB7DQogICAgICBkcml2ZUJ0bkljby5zcmMgPSB1cmwgKyAodXJsLmluY2x1ZGVzKCc/JykgPyAnJicgOiAnPycpICsgJ3Q9JyArIERhdGUubm93KCk7DQogICAgICBkcml2ZUJ0bkljby5jbGFzc0xpc3QucmVtb3ZlKCdoaWRkZW4nKTsNCiAgICB9IGVsc2Ugew0KICAgICAgZHJpdmVCdG5JY28ucmVtb3ZlQXR0cmlidXRlKCdzcmMnKTsNCiAgICAgIGRyaXZlQnRuSWNvLmNsYXNzTGlzdC5hZGQoJ2hpZGRlbicpOw0KICAgIH0NCiAgfQ0KICBmdW5jdGlvbiBzeW5jRHJpdmVCdXR0b24oKSB7DQogICAgZHJpdmVMYWJlbC50ZXh0Q29udGVudCA9IGRyaXZlVGV4dCgpOw0KICAgIGlmICghZHJpdmUpIHNldEJ0bkljb24oZHJpdmVNZXRhLmNvbXB1dGVyIHx8ICcnKTsNCiAgICBlbHNlIHsNCiAgICAgIGNvbnN0IGhpdCA9IChkcml2ZU1ldGEuZHJpdmVzIHx8IFtdKS5maW5kKGQgPT4gU3RyaW5nKGQubGV0dGVyIHx8ICcnKS50b1VwcGVyQ2FzZSgpID09PSBkcml2ZSk7DQogICAgICBzZXRCdG5JY29uKChoaXQgJiYgaGl0Lmljb24pIHx8IGRyaXZlTWV0YS5jb21wdXRlciB8fCAnJyk7DQogICAgfQ0KICB9DQogIGZ1bmN0aW9uIGljb0h0bWwodXJsKSB7DQogICAgcmV0dXJuIHVybCA/ICc8aW1nIHNyYz0iJyArIFN0cmluZyh1cmwpLnJlcGxhY2UoLyIvZywgJycpICsgJyIgYWx0PSIiPicgOiAnJzsNCiAgfQ0KICBmdW5jdGlvbiByZW5kZXJEcml2ZU1lbnUoKSB7DQogICAgY29uc3QgZHJpdmVzID0gQXJyYXkuaXNBcnJheShkcml2ZU1ldGEuZHJpdmVzKSA/IGRyaXZlTWV0YS5kcml2ZXMgOiBbXTsNCiAgICBsZXQgaHRtbCA9ICc8YnV0dG9uIHR5cGU9ImJ1dHRvbiIgZGF0YS1kcml2ZT0iIicgKyAoIWRyaXZlID8gJyBjbGFzcz0ib24iJyA6ICcnKSArICc+Jw0KICAgICAgKyBpY29IdG1sKGRyaXZlTWV0YS5jb21wdXRlcikgKyAnPHNwYW4+5YWo55uY5pCc57SiPC9zcGFuPjwvYnV0dG9uPic7DQogICAgZm9yIChjb25zdCBkIG9mIGRyaXZlcykgew0KICAgICAgY29uc3QgbGV0dGVyID0gU3RyaW5nKGQubGV0dGVyIHx8IGQgfHwgJycpLnJlcGxhY2UoLzokLywgJycpLnRvVXBwZXJDYXNlKCk7DQogICAgICBpZiAoIWxldHRlcikgY29udGludWU7DQogICAgICBjb25zdCBsYWJlbCA9IGQubGFiZWwgfHwgKGxldHRlciArICcg55uYJyk7DQogICAgICBodG1sICs9ICc8YnV0dG9uIHR5cGU9ImJ1dHRvbiIgZGF0YS1kcml2ZT0iJyArIGxldHRlciArICciJw0KICAgICAgICArIChkcml2ZSA9PT0gbGV0dGVyID8gJyBjbGFzcz0ib24iJyA6ICcnKSArICc+Jw0KICAgICAgICArIGljb0h0bWwoZC5pY29uIHx8ICcnKSArICc8c3Bhbj4nICsgbGFiZWwgKyAnPC9zcGFuPjwvYnV0dG9uPic7DQogICAgfQ0KICAgIGRyaXZlTWVudS5pbm5lckhUTUwgPSBodG1sOw0KICAgIGRyaXZlTWVudS5xdWVyeVNlbGVjdG9yQWxsKCdidXR0b24nKS5mb3JFYWNoKGJ0biA9PiB7DQogICAgICBidG4ub25jbGljayA9IChlKSA9PiB7DQogICAgICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7DQogICAgICAgIGRyaXZlID0gYnRuLmdldEF0dHJpYnV0ZSgnZGF0YS1kcml2ZScpIHx8ICcnOw0KICAgICAgICBkcml2ZU1lbnUuY2xhc3NMaXN0LnJlbW92ZSgnb24nKTsNCiAgICAgICAgc3luY0RyaXZlQnV0dG9uKCk7DQogICAgICAgIHJlbmRlckRyaXZlTWVudSgpOw0KICAgICAgICBkb1NlYXJjaCgpOw0KICAgICAgfTsNCiAgICB9KTsNCiAgfQ0KICB3aW5kb3cuX19zZXREcml2ZXMgPSAocGF5bG9hZCkgPT4gew0KICAgIHRyeSB7DQogICAgICBjb25zdCBkYXRhID0gdHlwZW9mIHBheWxvYWQgPT09ICdzdHJpbmcnID8gSlNPTi5wYXJzZShwYXlsb2FkKSA6IHBheWxvYWQ7DQogICAgICBpZiAoQXJyYXkuaXNBcnJheShkYXRhKSkgew0KICAgICAgICBkcml2ZU1ldGEgPSB7DQogICAgICAgICAgY29tcHV0ZXI6ICcnLA0KICAgICAgICAgIGRyaXZlczogZGF0YS5tYXAoeCA9PiB0eXBlb2YgeCA9PT0gJ3N0cmluZycNCiAgICAgICAgICAgID8gKHsgbGV0dGVyOiB4LCBpY29uOiAnJywgbGFiZWw6IFN0cmluZyh4KS50b1VwcGVyQ2FzZSgpICsgJyDnm5gnIH0pDQogICAgICAgICAgICA6IHgpDQogICAgICAgIH07DQogICAgICB9IGVsc2Ugew0KICAgICAgICBkcml2ZU1ldGEgPSB7DQogICAgICAgICAgY29tcHV0ZXI6IChkYXRhICYmIGRhdGEuY29tcHV0ZXIpIHx8ICcnLA0KICAgICAgICAgIGRyaXZlczogQXJyYXkuaXNBcnJheShkYXRhICYmIGRhdGEuZHJpdmVzKSA/IGRhdGEuZHJpdmVzIDogW10NCiAgICAgICAgfTsNCiAgICAgIH0NCiAgICAgIHN5bmNEcml2ZUJ1dHRvbigpOw0KICAgICAgcmVuZGVyRHJpdmVNZW51KCk7DQogICAgfSBjYXRjaCAoZSkgeyBjb25zb2xlLndhcm4oJ3NldERyaXZlcycsIGUpOyB9DQogIH07DQoNCiAgY29uc3QgSElTVF9LRVkgPSAnbG9jYWxfc2VhcmNoX2hpc3RfdjEnOw0KICBjb25zdCBISVNUX01BWCA9IDEwOw0KICBjb25zdCBzZWFyY2hCb3ggPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc2VhcmNoLWJveCcpOw0KICBjb25zdCBoaXN0TWVudSA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdoaXN0LW1lbnUnKTsNCiAgY29uc3QgYnRuSGlzdCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdidG4taGlzdCcpOw0KICBjb25zdCBidG5DbGVhciA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdidG4tY2xlYXInKTsNCiAgbGV0IGhpc3RJZGxlVGltZXIgPSAwOw0KDQogIGZ1bmN0aW9uIHN5bmNDbGVhckJ0bigpIHsNCiAgICBidG5DbGVhci5jbGFzc0xpc3QudG9nZ2xlKCdvbicsICEhKHFFbC52YWx1ZSB8fCAnJykudHJpbSgpKTsNCiAgfQ0KICBmdW5jdGlvbiBjbGVhclNlYXJjaCgpIHsNCiAgICBjbGVhclRpbWVvdXQoaGlzdElkbGVUaW1lcik7DQogICAgcUVsLnZhbHVlID0gJyc7DQogICAgc3luY0NsZWFyQnRuKCk7DQogICAgaGlzdE1lbnUuY2xhc3NMaXN0LnJlbW92ZSgnb24nKTsNCiAgICBzZWFyY2hCb3guY2xhc3NMaXN0LnJlbW92ZSgnaGlzdC1vcGVuJyk7DQogICAgYnRuSGlzdC5jbGFzc0xpc3QucmVtb3ZlKCdvbicpOw0KICAgIHFFbC5mb2N1cygpOw0KICAgIGRvU2VhcmNoKCk7DQogIH0NCiAgYnRuQ2xlYXIub25jbGljayA9IChlKSA9PiB7DQogICAgZS5zdG9wUHJvcGFnYXRpb24oKTsNCiAgICBjbGVhclNlYXJjaCgpOw0KICB9Ow0KDQogIGZ1bmN0aW9uIGxvYWRIaXN0KCkgew0KICAgIHRyeSB7DQogICAgICBjb25zdCByYXcgPSBsb2NhbFN0b3JhZ2UuZ2V0SXRlbShISVNUX0tFWSk7DQogICAgICBjb25zdCBhcnIgPSByYXcgPyBKU09OLnBhcnNlKHJhdykgOiBbXTsNCiAgICAgIHJldHVybiBBcnJheS5pc0FycmF5KGFycikgPyBhcnIubWFwKHggPT4gU3RyaW5nKHggfHwgJycpLnRyaW0oKSkuZmlsdGVyKEJvb2xlYW4pLnNsaWNlKDAsIEhJU1RfTUFYKSA6IFtdOw0KICAgIH0gY2F0Y2ggKF8pIHsgcmV0dXJuIFtdOyB9DQogIH0NCiAgZnVuY3Rpb24gc2F2ZUhpc3QobGlzdCkgew0KICAgIHRyeSB7IGxvY2FsU3RvcmFnZS5zZXRJdGVtKEhJU1RfS0VZLCBKU09OLnN0cmluZ2lmeShsaXN0LnNsaWNlKDAsIEhJU1RfTUFYKSkpOyB9IGNhdGNoIChfKSB7fQ0KICB9DQogIGZ1bmN0aW9uIHB1c2hIaXN0KHEpIHsNCiAgICBxID0gU3RyaW5nKHEgfHwgJycpLnRyaW0oKTsNCiAgICBpZiAoIXEpIHJldHVybjsNCiAgICBjb25zdCBsaXN0ID0gbG9hZEhpc3QoKS5maWx0ZXIoeCA9PiB4ICE9PSBxKTsNCiAgICBsaXN0LnVuc2hpZnQocSk7DQogICAgc2F2ZUhpc3QobGlzdCk7DQogICAgaWYgKGhpc3RNZW51LmNsYXNzTGlzdC5jb250YWlucygnb24nKSkgcmVuZGVySGlzdE1lbnUoKTsNCiAgfQ0KICBmdW5jdGlvbiBlc2NhcGVBdHRyKHMpIHsNCiAgICByZXR1cm4gU3RyaW5nKHMgfHwgJycpLnJlcGxhY2UoLyYvZywgJyZhbXA7JykucmVwbGFjZSgvIi9nLCAnJnF1b3Q7JykucmVwbGFjZSgvPC9nLCAnJmx0OycpOw0KICB9DQogIGZ1bmN0aW9uIHJlbmRlckhpc3RNZW51KCkgew0KICAgIGNvbnN0IGxpc3QgPSBsb2FkSGlzdCgpOw0KICAgIGlmICghbGlzdC5sZW5ndGgpIHsNCiAgICAgIGhpc3RNZW51LmlubmVySFRNTCA9ICc8ZGl2IGNsYXNzPSJoaXN0LWVtcHR5Ij7mmoLml6DmnIDov5HmkJzntKI8L2Rpdj4nOw0KICAgICAgcmV0dXJuOw0KICAgIH0NCiAgICBoaXN0TWVudS5pbm5lckhUTUwgPSBsaXN0Lm1hcChxID0+DQogICAgICAnPGJ1dHRvbiB0eXBlPSJidXR0b24iIGRhdGEtcT0iJyArIGVzY2FwZUF0dHIocSkgKyAnIiB0aXRsZT0iJyArIGVzY2FwZUF0dHIocSkgKyAnIj4nDQogICAgICArIGVzY2FwZUF0dHIocSkgKyAnPC9idXR0b24+Jw0KICAgICkuam9pbignJyk7DQogICAgaGlzdE1lbnUucXVlcnlTZWxlY3RvckFsbCgnYnV0dG9uJykuZm9yRWFjaChidG4gPT4gew0KICAgICAgYnRuLm9uY2xpY2sgPSAoZSkgPT4gew0KICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOw0KICAgICAgICBjb25zdCBxID0gYnRuLmdldEF0dHJpYnV0ZSgnZGF0YS1xJykgfHwgJyc7DQogICAgICAgIGhpc3RNZW51LmNsYXNzTGlzdC5yZW1vdmUoJ29uJyk7DQogICAgICAgIHNlYXJjaEJveC5jbGFzc0xpc3QucmVtb3ZlKCdoaXN0LW9wZW4nKTsNCiAgICAgICAgYnRuSGlzdC5jbGFzc0xpc3QucmVtb3ZlKCdvbicpOw0KICAgICAgICBxRWwudmFsdWUgPSBxOw0KICAgICAgICBwdXNoSGlzdChxKTsNCiAgICAgICAgc3luY0NsZWFyQnRuKCk7DQogICAgICAgIGRvU2VhcmNoKCk7DQogICAgICB9Ow0KICAgIH0pOw0KICB9DQogIGJ0bkRyaXZlLm9uY2xpY2sgPSAoZSkgPT4gew0KICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7DQogICAgY2xvc2VIaXN0TWVudSgpOw0KICAgIGRyaXZlTWVudS5jbGFzc0xpc3QudG9nZ2xlKCdvbicpOw0KICB9Ow0KICBmdW5jdGlvbiBjbG9zZUhpc3RNZW51KCkgew0KICAgIGhpc3RNZW51LmNsYXNzTGlzdC5yZW1vdmUoJ29uJyk7DQogICAgc2VhcmNoQm94LmNsYXNzTGlzdC5yZW1vdmUoJ2hpc3Qtb3BlbicpOw0KICAgIGJ0bkhpc3QuY2xhc3NMaXN0LnJlbW92ZSgnb24nKTsNCiAgfQ0KICBmdW5jdGlvbiBvcGVuSGlzdE1lbnUoKSB7DQogICAgZHJpdmVNZW51LmNsYXNzTGlzdC5yZW1vdmUoJ29uJyk7DQogICAgcmVuZGVySGlzdE1lbnUoKTsNCiAgICBoaXN0TWVudS5jbGFzc0xpc3QuYWRkKCdvbicpOw0KICAgIHNlYXJjaEJveC5jbGFzc0xpc3QuYWRkKCdoaXN0LW9wZW4nKTsNCiAgICBidG5IaXN0LmNsYXNzTGlzdC5hZGQoJ29uJyk7DQogIH0NCiAgYnRuSGlzdC5vbmNsaWNrID0gKGUpID0+IHsNCiAgICBlLnN0b3BQcm9wYWdhdGlvbigpOw0KICAgIGlmIChoaXN0TWVudS5jbGFzc0xpc3QuY29udGFpbnMoJ29uJykpIGNsb3NlSGlzdE1lbnUoKTsNCiAgICBlbHNlIG9wZW5IaXN0TWVudSgpOw0KICB9Ow0KICBoaXN0TWVudS5hZGRFdmVudExpc3RlbmVyKCdjbGljaycsIGUgPT4gZS5zdG9wUHJvcGFnYXRpb24oKSk7DQogIGRvY3VtZW50LmFkZEV2ZW50TGlzdGVuZXIoJ2NsaWNrJywgKCkgPT4gew0KICAgIGRyaXZlTWVudS5jbGFzc0xpc3QucmVtb3ZlKCdvbicpOw0KICAgIGNsb3NlSGlzdE1lbnUoKTsNCiAgICBoaWRlQ3R4KCk7DQogIH0pOw0KICByZW5kZXJEcml2ZU1lbnUoKTsNCiAgcmVuZGVySGlzdE1lbnUoKTsNCiAgc3luY0NsZWFyQnRuKCk7DQoNCiAgLy8gUHJpbWFyeSBVSeKGkkFISyBjaGFubmVsOiBpbi1wYWdlIHF1ZXVlIGRyYWluZWQgYnkgQUhLIEV4ZWN1dGVTY3JpcHQuDQogIC8vIE5ldmVyIHVzZSBob3N0T2JqZWN0cy5zeW5jIOKAlCBpdCBkZWFkbG9ja3MgV2ViVmlldzIgYW5kIGJsb2NrcyBwb3N0TWVzc2FnZSB0b28uDQogIHdpbmRvdy5fX2Foa1EgPSB3aW5kb3cuX19haGtRIHx8IFtdOw0KICBmdW5jdGlvbiBlbnF1ZXVlKG1zZykgew0KICAgIHRyeSB7DQogICAgICB3aW5kb3cuX19haGtRLnB1c2goU3RyaW5nKG1zZykpOw0KICAgICAgLy8gVGlwIEFISyBwb2xsZXIgdmlhIHRpdGxlIGNoYW5nZSAob3B0aW9uYWwgZmFzdCBwYXRoKQ0KICAgICAgdHJ5IHsgZG9jdW1lbnQuZG9jdW1lbnRFbGVtZW50LmRhdGFzZXQuYWhrUGVuZGluZyA9IFN0cmluZyh3aW5kb3cuX19haGtRLmxlbmd0aCk7IH0gY2F0Y2ggKF8pIHt9DQogICAgfSBjYXRjaCAoZSkgeyBjb25zb2xlLndhcm4oJ2VucXVldWUnLCBlKTsgfQ0KICB9DQogIGZ1bmN0aW9uIHBvc3QobXNnKSB7DQogICAgZW5xdWV1ZShtc2cpOw0KICAgIHRyeSB7DQogICAgICBpZiAod2luZG93LmNocm9tZSAmJiBjaHJvbWUud2VidmlldyAmJiB0eXBlb2YgY2hyb21lLndlYnZpZXcucG9zdE1lc3NhZ2UgPT09ICdmdW5jdGlvbicpIHsNCiAgICAgICAgY2hyb21lLndlYnZpZXcucG9zdE1lc3NhZ2UoU3RyaW5nKG1zZykpOw0KICAgICAgICByZXR1cm4gdHJ1ZTsNCiAgICAgIH0NCiAgICB9IGNhdGNoIChlKSB7IGNvbnNvbGUud2FybigncG9zdCcsIGUpOyB9DQogICAgcmV0dXJuIGZhbHNlOw0KICB9DQogIGZ1bmN0aW9uIGNhbGxIb3N0KG1ldGhvZCwgLi4uYXJncykgew0KICAgIGxldCBtc2cgPSAnJzsNCiAgICBpZiAobWV0aG9kID09PSAnc2VhcmNoJykgew0KICAgICAgY29uc3QgW3EsIGMsIHMsIG9mZnNldF0gPSBhcmdzOw0KICAgICAgbXNnID0gJ3NlYXJjaHwnICsgSlNPTi5zdHJpbmdpZnkoew0KICAgICAgICBxOiBxIHx8ICcnLCBjYXQ6IGMgfHwgJ2FsbCcsIHNvcnQ6IHMgfHwgJ2RhdGUtZGVzYycsDQogICAgICAgIGRyaXZlOiBkcml2ZSB8fCAnJywNCiAgICAgICAgb2Zmc2V0OiBOdW1iZXIob2Zmc2V0KSB8fCAwLCBnZW46ICsrZ2VuDQogICAgICB9KTsNCiAgICB9IGVsc2UgaWYgKG1ldGhvZCA9PT0gJ3ByZXZpZXcnKSB7DQogICAgICBtc2cgPSAncHJldmlld3wnICsgKGFyZ3NbMF0gfHwgJycpOw0KICAgIH0gZWxzZSBpZiAobWV0aG9kID09PSAnb3BlbicpIHsNCiAgICAgIG1zZyA9ICdvcGVufCcgKyAoYXJnc1swXSB8fCAnJyk7DQogICAgfSBlbHNlIGlmIChtZXRob2QgPT09ICdyZXZlYWwnKSB7DQogICAgICBtc2cgPSAncmV2ZWFsfCcgKyAoYXJnc1swXSB8fCAnJyk7DQogICAgfSBlbHNlIGlmIChtZXRob2QgPT09ICdjb3B5RmlsZScpIHsNCiAgICAgIG1zZyA9ICdjb3B5RmlsZXwnICsgKGFyZ3NbMF0gfHwgJycpOw0KICAgIH0gZWxzZSBpZiAobWV0aG9kID09PSAnY29weVBhdGgnKSB7DQogICAgICBtc2cgPSAnY29weVBhdGh8JyArIChhcmdzWzBdIHx8ICcnKTsNCiAgICB9IGVsc2UgaWYgKG1ldGhvZCA9PT0gJ2NvcHlEaXInKSB7DQogICAgICBtc2cgPSAnY29weURpcnwnICsgKGFyZ3NbMF0gfHwgJycpOw0KICAgIH0gZWxzZSBpZiAobWV0aG9kID09PSAncmVjeWNsZScpIHsNCiAgICAgIG1zZyA9ICdyZWN5Y2xlfCcgKyAoYXJnc1swXSB8fCAnJyk7DQogICAgfSBlbHNlIGlmIChtZXRob2QgPT09ICdjbG9zZScgfHwgbWV0aG9kID09PSAnbWluaW1pemUnIHx8IG1ldGhvZCA9PT0gJ2RyYWcnKSB7DQogICAgICBtc2cgPSBtZXRob2Q7DQogICAgfSBlbHNlIHsNCiAgICAgIG1zZyA9IG1ldGhvZCArICd8JyArIGFyZ3MubWFwKGEgPT4gU3RyaW5nKGEgPz8gJycpKS5qb2luKCd8Jyk7DQogICAgfQ0KICAgIHBvc3QobXNnKTsNCiAgfQ0KDQogIGZ1bmN0aW9uIHNldEJvb3RQY3QocCkgew0KICAgIHAgPSBNYXRoLm1heCgwLCBNYXRoLm1pbigxMDAsIE51bWJlcihwKSB8fCAwKSk7DQogICAgYm9vdFBjdC50ZXh0Q29udGVudCA9IE1hdGgucm91bmQocCkgKyAnJSc7DQogICAgcmluZ0ZnLnN0eWxlLnN0cm9rZURhc2hhcnJheSA9IFN0cmluZyhDSVJDKTsNCiAgICByaW5nRmcuc3R5bGUuc3Ryb2tlRGFzaG9mZnNldCA9IFN0cmluZyhDSVJDICogKDEgLSBwIC8gMTAwKSk7DQogIH0NCg0KICB3aW5kb3cuX19zZXRCb290ID0gKG9uLCBwY3QsIG1zZykgPT4gew0KICAgIGlmIChvbikgew0KICAgICAgYm9vdC5jbGFzc0xpc3QuYWRkKCdvbicpOw0KICAgICAgY2hyb21lLmNsYXNzTGlzdC5hZGQoJ2hpZGRlbicpOw0KICAgICAgc2V0Qm9vdFBjdChwY3QpOw0KICAgIH0gZWxzZSB7DQogICAgICBib290LmNsYXNzTGlzdC5yZW1vdmUoJ29uJyk7DQogICAgICBjaHJvbWUuY2xhc3NMaXN0LnJlbW92ZSgnaGlkZGVuJyk7DQogICAgfQ0KICB9Ow0KICB3aW5kb3cuX19zZXRJbmRleFByb2dyZXNzID0gKHBjdCkgPT4gc2V0Qm9vdFBjdChwY3QpOw0KDQogIHdpbmRvdy5fX3NldENhdEljb25zID0gKHBheWxvYWQpID0+IHsNCiAgICB0cnkgew0KICAgICAgY29uc3QgbWFwID0gdHlwZW9mIHBheWxvYWQgPT09ICdzdHJpbmcnID8gSlNPTi5wYXJzZShwYXlsb2FkKSA6IHBheWxvYWQ7DQogICAgICBpZiAoIW1hcCB8fCB0eXBlb2YgbWFwICE9PSAnb2JqZWN0JykgcmV0dXJuOw0KICAgICAgZG9jdW1lbnQucXVlcnlTZWxlY3RvckFsbCgnLmNhdCcpLmZvckVhY2goYnRuID0+IHsNCiAgICAgICAgY29uc3Qga2V5ID0gYnRuLmdldEF0dHJpYnV0ZSgnZGF0YS1jYXQnKTsNCiAgICAgICAgY29uc3QgdXJsID0gbWFwW2tleV07DQogICAgICAgIGlmICghdXJsKSByZXR1cm47DQogICAgICAgIGxldCBpbWcgPSBidG4ucXVlcnlTZWxlY3RvcignaW1nLmljbycpOw0KICAgICAgICBpZiAoIWltZykgew0KICAgICAgICAgIGNvbnN0IG9sZCA9IGJ0bi5xdWVyeVNlbGVjdG9yKCcuaWNvLCBbZGF0YS1jYXQtaWNvXScpOw0KICAgICAgICAgIGltZyA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2ltZycpOw0KICAgICAgICAgIGltZy5jbGFzc05hbWUgPSAnaWNvJzsNCiAgICAgICAgICBpbWcuYWx0ID0gJyc7DQogICAgICAgICAgaWYgKG9sZCkgb2xkLnJlcGxhY2VXaXRoKGltZyk7DQogICAgICAgICAgZWxzZSBidG4uaW5zZXJ0QmVmb3JlKGltZywgYnRuLmZpcnN0Q2hpbGQpOw0KICAgICAgICB9DQogICAgICAgIGltZy5zcmMgPSB1cmwgKyAodXJsLmluY2x1ZGVzKCc/JykgPyAnJicgOiAnPycpICsgJ3Q9JyArIERhdGUubm93KCk7DQogICAgICB9KTsNCiAgICB9IGNhdGNoIChlKSB7IGNvbnNvbGUud2Fybignc2V0Q2F0SWNvbnMnLCBlKTsgfQ0KICB9Ow0KDQogIGZ1bmN0aW9uIGV4dE9mKG5hbWUpIHsNCiAgICBjb25zdCBpID0gU3RyaW5nKG5hbWUgfHwgJycpLmxhc3RJbmRleE9mKCcuJyk7DQogICAgcmV0dXJuIGkgPiAwID8gbmFtZS5zbGljZShpICsgMSkudG9Mb3dlckNhc2UoKSA6ICcnOw0KICB9DQogIGZ1bmN0aW9uIGljb25IdG1sKGl0KSB7DQogICAgaWYgKGl0Lmljb24pIHsNCiAgICAgIHJldHVybiAnPGltZyBzcmM9IicgKyBlc2NhcGVIdG1sKGl0Lmljb24pICsgJyIgYWx0PSIiIGxvYWRpbmc9ImxhenkiIGRlY29kaW5nPSJhc3luYyIgb25lcnJvcj0idGhpcy5vdXRlckhUTUw9XCc8c3BhbiBjbGFzcz1maS1mYWxsYmFjaz7wn5OEPC9zcGFuPlwnIj4nOw0KICAgIH0NCiAgICBpZiAoaXQuaXNEaXIpIHJldHVybiAnPHNwYW4gY2xhc3M9ImZpLWZhbGxiYWNrIj7wn5OBPC9zcGFuPic7DQogICAgcmV0dXJuICc8c3BhbiBjbGFzcz0iZmktZmFsbGJhY2siPvCfk4Q8L3NwYW4+JzsNCiAgfQ0KICBmdW5jdGlvbiBoaWdobGlnaHRIdG1sKHRleHQpIHsNCiAgICBjb25zdCByYXcgPSBTdHJpbmcodGV4dCA/PyAnJyk7DQogICAgbGV0IGh0bWwgPSBlc2NhcGVIdG1sKHJhdyk7DQogICAgY29uc3QgcSA9IChxRWwudmFsdWUgfHwgJycpLnRyaW0oKTsNCiAgICBpZiAoIXEpIHJldHVybiBodG1sOw0KICAgIGNvbnN0IHRlcm1zID0gcS5zcGxpdCgvXHxcfHxcfC8pLmZsYXRNYXAocyA9PiBzLnNwbGl0KC9ccysvKSkubWFwKHQgPT4gdC50cmltKCkpLmZpbHRlcihCb29sZWFuKTsNCiAgICAvLyBsb25nZXIgdGVybXMgZmlyc3QgdG8gYXZvaWQgcGFydGlhbCBvdmVybGFwIGlzc3Vlcw0KICAgIHRlcm1zLnNvcnQoKGEsIGIpID0+IGIubGVuZ3RoIC0gYS5sZW5ndGgpOw0KICAgIGZvciAoY29uc3QgdCBvZiB0ZXJtcykgew0KICAgICAgaWYgKCF0KSBjb250aW51ZTsNCiAgICAgIGNvbnN0IHJlID0gbmV3IFJlZ0V4cCh0LnJlcGxhY2UoL1suKis/XiR7fSgpfFtcXVxcXS9nLCAnXFwkJicpLCAnZ2knKTsNCiAgICAgIGh0bWwgPSBodG1sLnJlcGxhY2UocmUsIG0gPT4gJzxtYXJrPicgKyBtICsgJzwvbWFyaz4nKTsNCiAgICB9DQogICAgcmV0dXJuIGh0bWw7DQogIH0NCiAgZnVuY3Rpb24gcHJldHR5TmFtZShuYW1lKSB7DQogICAgbmFtZSA9IFN0cmluZyhuYW1lIHx8ICcnKTsNCiAgICBpZiAoIW5hbWUpIHJldHVybiAnJzsNCiAgICBjb25zdCBlID0gZXh0T2YobmFtZSk7DQogICAgaWYgKCFlIHx8IG5hbWUuc3RhcnRzV2l0aCgnLicpKSByZXR1cm4gaGlnaGxpZ2h0SHRtbChuYW1lKTsNCiAgICBjb25zdCBiYXNlID0gbmFtZS5zbGljZSgwLCAtKGUubGVuZ3RoICsgMSkpOw0KICAgIHJldHVybiBoaWdobGlnaHRIdG1sKGJhc2UpICsgJzxzcGFuIGNsYXNzPSJleHQiPi4nICsgZXNjYXBlSHRtbChlKSArICc8L3NwYW4+JzsNCiAgfQ0KICBmdW5jdGlvbiBkaXNwbGF5TmFtZShpdCkgew0KICAgIGxldCBuID0gU3RyaW5nKGl0Lm5hbWUgfHwgJycpLnRyaW0oKTsNCiAgICBpZiAobikgcmV0dXJuIG47DQogICAgLy8gZmFsbGJhY2s6IGxhc3Qgc2VnbWVudCBvZiBwYXRoDQogICAgY29uc3QgcCA9IFN0cmluZyhpdC5wYXRoIHx8ICcnKS5yZXBsYWNlKC9bXFwvXSskLywgJycpOw0KICAgIGNvbnN0IGkgPSBNYXRoLm1heChwLmxhc3RJbmRleE9mKCdcXCcpLCBwLmxhc3RJbmRleE9mKCcvJykpOw0KICAgIHJldHVybiBpID49IDAgPyBwLnNsaWNlKGkgKyAxKSA6IHA7DQogIH0NCiAgZnVuY3Rpb24gZXNjYXBlSHRtbChzKSB7DQogICAgcmV0dXJuIFN0cmluZyhzID8/ICcnKS5yZXBsYWNlKC8mL2csJyZhbXA7JykucmVwbGFjZSgvPC9nLCcmbHQ7JykucmVwbGFjZSgvPi9nLCcmZ3Q7JykucmVwbGFjZSgvIi9nLCcmcXVvdDsnKTsNCiAgfQ0KICBmdW5jdGlvbiBzaG9ydFBhdGgocCkgew0KICAgIHAgPSBTdHJpbmcocCB8fCAnJyk7DQogICAgaWYgKHAubGVuZ3RoIDw9IDU2KSByZXR1cm4gcDsNCiAgICByZXR1cm4gcC5zbGljZSgwLCAyOCkgKyAnLi4uJyArIHAuc2xpY2UoLTI0KTsNCiAgfQ0KDQogIGZ1bmN0aW9uIHVwZGF0ZUNvdW50KCkgew0KICAgIGlmICghaXRlbXMubGVuZ3RoKSB7DQogICAgICBjb3VudEVsLnRleHRDb250ZW50ID0gJ+WFsSAwIOadoee7k+aenCc7DQogICAgICByZXR1cm47DQogICAgfQ0KICAgIGNvbnN0IHNob3duID0gaXRlbXMubGVuZ3RoOw0KICAgIGNvdW50RWwudGV4dENvbnRlbnQgPSB0b3RhbEhpdHMgPiBzaG93bg0KICAgICAgPyAoJ+WFsSAnICsgdG90YWxIaXRzLnRvTG9jYWxlU3RyaW5nKCkgKyAnIOadoee7k+aenO+8iOW3suWKoOi9vSAnICsgc2hvd24udG9Mb2NhbGVTdHJpbmcoKSArICcg5p2h77yJJykNCiAgICAgIDogKCflhbEgJyArIE1hdGgubWF4KHRvdGFsSGl0cywgc2hvd24pLnRvTG9jYWxlU3RyaW5nKCkgKyAnIOadoee7k+aenCcpOw0KICB9DQoNCiAgZnVuY3Rpb24gbWFrZVJvdyhpdCwgaSkgew0KICAgIGNvbnN0IHJvdyA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOw0KICAgIHJvdy5jbGFzc05hbWUgPSAncm93JyArIChpID09PSBzZWxlY3RlZCA/ICcgb24nIDogJycpOw0KICAgIGNvbnN0IHRpdGxlID0gZGlzcGxheU5hbWUoaXQpOw0KICAgIHJvdy5pbm5lckhUTUwgPSBgPGRpdiBjbGFzcz0iZmkiPiR7aWNvbkh0bWwoaXQpfTwvZGl2Pg0KICAgICAgPGRpdj4NCiAgICAgICAgPGRpdiBjbGFzcz0ibmFtZSI+JHtwcmV0dHlOYW1lKHRpdGxlKX08L2Rpdj4NCiAgICAgICAgPGRpdiBjbGFzcz0icGF0aCIgdGl0bGU9IiR7ZXNjYXBlSHRtbChpdC5wYXRoKX0iPiR7aGlnaGxpZ2h0SHRtbChzaG9ydFBhdGgoaXQucGF0aCkpfTwvZGl2Pg0KICAgICAgPC9kaXY+YDsNCiAgICByb3cub25jbGljayA9ICgpID0+IHsgaGlkZUN0eCgpOyBzZWxlY3RSb3coaSk7IH07DQogICAgcm93Lm9uZGJsY2xpY2sgPSAoKSA9PiB7DQogICAgICBoaWRlQ3R4KCk7DQogICAgICBwdXNoSGlzdChxRWwudmFsdWUgfHwgJycpOw0KICAgICAgY2FsbEhvc3QoJ29wZW4nLCBpdC5wYXRoKTsNCiAgICB9Ow0KICAgIHJvdy5vbmNvbnRleHRtZW51ID0gKGUpID0+IHsNCiAgICAgIGUucHJldmVudERlZmF1bHQoKTsNCiAgICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7DQogICAgICBzZWxlY3RSb3coaSk7DQogICAgICBzaG93Q3R4KGUuY2xpZW50WCwgZS5jbGllbnRZLCBpdC5wYXRoKTsNCiAgICB9Ow0KICAgIHJldHVybiByb3c7DQogIH0NCg0KICBjb25zdCBjdHhFbCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjdHgnKTsNCiAgbGV0IGN0eFBhdGggPSAnJzsNCiAgZnVuY3Rpb24gaGlkZUN0eCgpIHsNCiAgICBjdHhFbC5jbGFzc0xpc3QucmVtb3ZlKCdvbicpOw0KICAgIGN0eFBhdGggPSAnJzsNCiAgfQ0KICBmdW5jdGlvbiBzaG93Q3R4KHgsIHksIHBhdGgpIHsNCiAgICBjdHhQYXRoID0gU3RyaW5nKHBhdGggfHwgJycpOw0KICAgIGlmICghY3R4UGF0aCkgcmV0dXJuOw0KICAgIGN0eEVsLmNsYXNzTGlzdC5hZGQoJ29uJyk7DQogICAgY29uc3QgcGFkID0gNjsNCiAgICBjb25zdCB2dyA9IHdpbmRvdy5pbm5lcldpZHRoOw0KICAgIGNvbnN0IHZoID0gd2luZG93LmlubmVySGVpZ2h0Ow0KICAgIGN0eEVsLnN0eWxlLmxlZnQgPSAnMHB4JzsNCiAgICBjdHhFbC5zdHlsZS50b3AgPSAnMHB4JzsNCiAgICBjb25zdCByZWN0ID0gY3R4RWwuZ2V0Qm91bmRpbmdDbGllbnRSZWN0KCk7DQogICAgbGV0IGxlZnQgPSB4Ow0KICAgIGxldCB0b3AgPSB5Ow0KICAgIGlmIChsZWZ0ICsgcmVjdC53aWR0aCA+IHZ3IC0gcGFkKSBsZWZ0ID0gTWF0aC5tYXgocGFkLCB2dyAtIHJlY3Qud2lkdGggLSBwYWQpOw0KICAgIGlmICh0b3AgKyByZWN0LmhlaWdodCA+IHZoIC0gcGFkKSB0b3AgPSBNYXRoLm1heChwYWQsIHZoIC0gcmVjdC5oZWlnaHQgLSBwYWQpOw0KICAgIGN0eEVsLnN0eWxlLmxlZnQgPSBsZWZ0ICsgJ3B4JzsNCiAgICBjdHhFbC5zdHlsZS50b3AgPSB0b3AgKyAncHgnOw0KICB9DQogIGN0eEVsLnF1ZXJ5U2VsZWN0b3JBbGwoJ2J1dHRvbltkYXRhLWFjdF0nKS5mb3JFYWNoKGJ0biA9PiB7DQogICAgYnRuLmFkZEV2ZW50TGlzdGVuZXIoJ2NsaWNrJywgKGUpID0+IHsNCiAgICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7DQogICAgICBjb25zdCBhY3QgPSBidG4uZ2V0QXR0cmlidXRlKCdkYXRhLWFjdCcpOw0KICAgICAgY29uc3QgcGF0aCA9IGN0eFBhdGg7DQogICAgICBoaWRlQ3R4KCk7DQogICAgICBpZiAoIXBhdGggfHwgIWFjdCkgcmV0dXJuOw0KICAgICAgaWYgKGFjdCA9PT0gJ3JldmVhbCcpIGNhbGxIb3N0KCdyZXZlYWwnLCBwYXRoKTsNCiAgICAgIGVsc2UgaWYgKGFjdCA9PT0gJ2NvcHknKSBjYWxsSG9zdCgnY29weUZpbGUnLCBwYXRoKTsNCiAgICAgIGVsc2UgaWYgKGFjdCA9PT0gJ2NvcHlQYXRoJykgY2FsbEhvc3QoJ2NvcHlQYXRoJywgcGF0aCk7DQogICAgICBlbHNlIGlmIChhY3QgPT09ICdjb3B5RGlyJykgY2FsbEhvc3QoJ2NvcHlEaXInLCBwYXRoKTsNCiAgICAgIGVsc2UgaWYgKGFjdCA9PT0gJ3JlY3ljbGUnKSBjYWxsSG9zdCgncmVjeWNsZScsIHBhdGgpOw0KICAgIH0pOw0KICB9KTsNCiAgZG9jdW1lbnQuYWRkRXZlbnRMaXN0ZW5lcignY29udGV4dG1lbnUnLCAoZSkgPT4gew0KICAgIGlmICghZS50YXJnZXQuY2xvc2VzdCgnI2xpc3QgLnJvdycpICYmICFlLnRhcmdldC5jbG9zZXN0KCcjY3R4JykpIGhpZGVDdHgoKTsNCiAgfSk7DQogIHdpbmRvdy5hZGRFdmVudExpc3RlbmVyKCdibHVyJywgaGlkZUN0eCk7DQogIHdpbmRvdy5hZGRFdmVudExpc3RlbmVyKCdyZXNpemUnLCBoaWRlQ3R4KTsNCiAgd2luZG93Ll9fcmVtb3ZlUGF0aCA9IChwYXRoKSA9PiB7DQogICAgcGF0aCA9IFN0cmluZyhwYXRoIHx8ICcnKTsNCiAgICBpZiAoIXBhdGgpIHJldHVybjsNCiAgICBjb25zdCBwcmV2U2VsID0gc2VsZWN0ZWQgPj0gMCA/IChpdGVtc1tzZWxlY3RlZF0gJiYgaXRlbXNbc2VsZWN0ZWRdLnBhdGgpIDogJyc7DQogICAgaXRlbXMgPSBpdGVtcy5maWx0ZXIoaXQgPT4gU3RyaW5nKGl0LnBhdGggfHwgJycpICE9PSBwYXRoKTsNCiAgICBpZiAodG90YWxIaXRzID4gMCkgdG90YWxIaXRzID0gTWF0aC5tYXgoMCwgdG90YWxIaXRzIC0gMSk7DQogICAgc2VsZWN0ZWQgPSAtMTsNCiAgICBpZiAocHJldlNlbCAmJiBwcmV2U2VsICE9PSBwYXRoKSB7DQogICAgICBzZWxlY3RlZCA9IGl0ZW1zLmZpbmRJbmRleChpdCA9PiBpdC5wYXRoID09PSBwcmV2U2VsKTsNCiAgICB9IGVsc2UgaWYgKGl0ZW1zLmxlbmd0aCkgew0KICAgICAgc2VsZWN0ZWQgPSBNYXRoLm1pbihzZWxlY3RlZCA8IDAgPyAwIDogc2VsZWN0ZWQsIGl0ZW1zLmxlbmd0aCAtIDEpOw0KICAgIH0NCiAgICByZW5kZXJMaXN0KGZhbHNlKTsNCiAgICBpZiAoc2VsZWN0ZWQgPj0gMCAmJiBwcmV2aWV3T24pIHJlcXVlc3RQcmV2aWV3KGl0ZW1zW3NlbGVjdGVkXSk7DQogICAgZWxzZSB7DQogICAgICBwdk1ldGEudGV4dENvbnRlbnQgPSAn6YCJ5oup5paH5Lu25Lul6aKE6KeIJzsNCiAgICAgIHB2TWVkaWEuaW5uZXJIVE1MID0gJzxkaXYgY2xhc3M9InBoIj7pooTop4jljLo8L2Rpdj4nOw0KICAgICAgcHZUZXh0LnN0eWxlLmRpc3BsYXkgPSAnbm9uZSc7DQogICAgfQ0KICB9Ow0KDQogIGZ1bmN0aW9uIHJlbmRlckxpc3QoYXBwZW5kKSB7DQogICAgaWYgKCFhcHBlbmQpIGxpc3RFbC5pbm5lckhUTUwgPSAnJzsNCiAgICBpZiAoIWl0ZW1zLmxlbmd0aCkgew0KICAgICAgZW1wdHlFbC5jbGFzc0xpc3QuYWRkKCdvbicpOw0KICAgICAgdXBkYXRlQ291bnQoKTsNCiAgICAgIHJldHVybjsNCiAgICB9DQogICAgZW1wdHlFbC5jbGFzc0xpc3QucmVtb3ZlKCdvbicpOw0KICAgIGNvbnN0IHN0YXJ0ID0gYXBwZW5kID8gbGlzdEVsLnF1ZXJ5U2VsZWN0b3JBbGwoJy5yb3cnKS5sZW5ndGggOiAwOw0KICAgIGNvbnN0IGZyYWcgPSBkb2N1bWVudC5jcmVhdGVEb2N1bWVudEZyYWdtZW50KCk7DQogICAgZm9yIChsZXQgaSA9IHN0YXJ0OyBpIDwgaXRlbXMubGVuZ3RoOyBpKyspDQogICAgICBmcmFnLmFwcGVuZENoaWxkKG1ha2VSb3coaXRlbXNbaV0sIGkpKTsNCiAgICBsaXN0RWwuYXBwZW5kQ2hpbGQoZnJhZyk7DQogICAgdXBkYXRlQ291bnQoKTsNCiAgfQ0KDQogIGZ1bmN0aW9uIHNlbGVjdFJvdyhpKSB7DQogICAgc2VsZWN0ZWQgPSBpOw0KICAgIGxpc3RFbC5xdWVyeVNlbGVjdG9yQWxsKCcucm93JykuZm9yRWFjaCgoZWwsIGlkeCkgPT4gZWwuY2xhc3NMaXN0LnRvZ2dsZSgnb24nLCBpZHggPT09IGkpKTsNCiAgICBjb25zdCBpdCA9IGl0ZW1zW2ldOw0KICAgIGlmICghaXQpIHJldHVybjsNCiAgICBpZiAocHJldmlld09uKSByZXF1ZXN0UHJldmlldyhpdCk7DQogIH0NCg0KICBmdW5jdGlvbiByZXF1ZXN0UHJldmlldyhpdCkgew0KICAgIHB2TWV0YS5pbm5lckhUTUwgPSBgPHNwYW4+5ZCN56ewIDxiPiR7ZXNjYXBlSHRtbChpdC5uYW1lKX08L2I+PC9zcGFuPmA7DQogICAgaWYgKHB2Qm9keSkgcHZCb2R5LmNsYXNzTGlzdC5yZW1vdmUoJ3RleHQtbW9kZScpOw0KICAgIHB2TWVkaWEuaW5uZXJIVE1MID0gJzxkaXYgY2xhc3M9InBoIj7liqDovb3pooTop4jigKY8L2Rpdj4nOw0KICAgIHB2VGV4dC5zdHlsZS5kaXNwbGF5ID0gJ25vbmUnOw0KICAgIGNhbGxIb3N0KCdwcmV2aWV3JywgaXQucGF0aCk7DQogIH0NCg0KICBmdW5jdGlvbiB0cnlMb2FkTW9yZSgpIHsNCiAgICBpZiAoIWhhc01vcmUgfHwgbG9hZGluZ01vcmUpIHJldHVybjsNCiAgICBsb2FkaW5nTW9yZSA9IHRydWU7DQogICAgY2FsbEhvc3QoJ3NlYXJjaCcsIHFFbC52YWx1ZSB8fCAnJywgY2F0LCBzb3J0LCBpdGVtcy5sZW5ndGgpOw0KICB9DQoNCiAgZnVuY3Rpb24gbWF5YmVGaWxsVmlld3BvcnQoKSB7DQogICAgLy8g6aaW5bGP5Y+q5pyJIDE1IOadoeaXtuWPr+iDveS4jeWkn+a7muWKqO+8jOiHquWKqOihpemhteebtOWIsOWPr+a7muaIluayoeacieabtOWkmg0KICAgIGlmICghaGFzTW9yZSB8fCBsb2FkaW5nTW9yZSkgcmV0dXJuOw0KICAgIGlmIChsaXN0RWwuc2Nyb2xsSGVpZ2h0IDw9IGxpc3RFbC5jbGllbnRIZWlnaHQgKyA4KQ0KICAgICAgdHJ5TG9hZE1vcmUoKTsNCiAgfQ0KDQogIGxpc3RFbC5hZGRFdmVudExpc3RlbmVyKCdzY3JvbGwnLCAoKSA9PiB7DQogICAgaWYgKGxpc3RFbC5zY3JvbGxUb3AgKyBsaXN0RWwuY2xpZW50SGVpZ2h0ID49IGxpc3RFbC5zY3JvbGxIZWlnaHQgLSAxMjApDQogICAgICB0cnlMb2FkTW9yZSgpOw0KICB9KTsNCg0KICB3aW5kb3cuX191cGRhdGVSZXN1bHRzID0gKHBheWxvYWQpID0+IHsNCiAgICB0cnkgew0KICAgICAgY29uc3QgZGF0YSA9IHR5cGVvZiBwYXlsb2FkID09PSAnc3RyaW5nJyA/IEpTT04ucGFyc2UocGF5bG9hZCkgOiBwYXlsb2FkOw0KICAgICAgY29uc3QgYmF0Y2ggPSBBcnJheS5pc0FycmF5KGRhdGEuaXRlbXMpID8gZGF0YS5pdGVtcyA6IFtdOw0KICAgICAgY29uc3QgdG90YWwgPSBOdW1iZXIoZGF0YS50b3RhbCAhPSBudWxsID8gZGF0YS50b3RhbCA6IDApIHx8IDA7DQogICAgICBjb25zdCBvZmZzZXQgPSBOdW1iZXIoZGF0YS5vZmZzZXQpIHx8IDA7DQogICAgICBjb25zdCBhcHBlbmQgPSAhIWRhdGEuYXBwZW5kICYmIG9mZnNldCA+IDA7DQoNCiAgICAgIHRvdGFsSGl0cyA9ICh0b3RhbCA+PSAwID8gdG90YWwgOiB0b3RhbEhpdHMpIHx8IHRvdGFsSGl0czsNCiAgICAgIGlmIChhcHBlbmQpIHsNCiAgICAgICAgY29uc3Qgc2VlbiA9IG5ldyBTZXQoaXRlbXMubWFwKHggPT4geC5wYXRoKSk7DQogICAgICAgIGZvciAoY29uc3QgaXQgb2YgYmF0Y2gpIHsNCiAgICAgICAgICBpZiAoIXNlZW4uaGFzKGl0LnBhdGgpKSBpdGVtcy5wdXNoKGl0KTsNCiAgICAgICAgfQ0KICAgICAgICBsb2FkaW5nTW9yZSA9IGZhbHNlOw0KICAgICAgICBoYXNNb3JlID0gYmF0Y2gubGVuZ3RoID4gMCAmJiBpdGVtcy5sZW5ndGggPCB0b3RhbEhpdHM7DQogICAgICAgIHJlbmRlckxpc3QodHJ1ZSk7DQogICAgICB9IGVsc2Ugew0KICAgICAgICBpdGVtcyA9IGJhdGNoOw0KICAgICAgICBsb2FkaW5nTW9yZSA9IGZhbHNlOw0KICAgICAgICBoYXNNb3JlID0gYmF0Y2gubGVuZ3RoID4gMCAmJiBpdGVtcy5sZW5ndGggPCB0b3RhbEhpdHM7DQogICAgICAgIHNlbGVjdGVkID0gaXRlbXMubGVuZ3RoID8gMCA6IC0xOw0KICAgICAgICByZW5kZXJMaXN0KGZhbHNlKTsNCiAgICAgICAgaWYgKHNlbGVjdGVkID49IDAgJiYgcHJldmlld09uKSByZXF1ZXN0UHJldmlldyhpdGVtc1tzZWxlY3RlZF0pOw0KICAgICAgICBlbHNlIGlmICghaXRlbXMubGVuZ3RoKSB7DQogICAgICAgICAgaWYgKHB2Qm9keSkgcHZCb2R5LmNsYXNzTGlzdC5yZW1vdmUoJ3RleHQtbW9kZScpOw0KICAgICAgICAgIHB2TWV0YS50ZXh0Q29udGVudCA9ICfpgInmi6nmlofku7bku6XpooTop4gnOw0KICAgICAgICAgIHB2TWVkaWEuaW5uZXJIVE1MID0gJzxkaXYgY2xhc3M9InBoIj7pooTop4jljLo8L2Rpdj4nOw0KICAgICAgICAgIHB2VGV4dC5zdHlsZS5kaXNwbGF5ID0gJ25vbmUnOw0KICAgICAgICB9DQogICAgICB9DQogICAgICB1cGRhdGVDb3VudCgpOw0KICAgICAgcmVxdWVzdEFuaW1hdGlvbkZyYW1lKG1heWJlRmlsbFZpZXdwb3J0KTsNCiAgICB9IGNhdGNoIChlKSB7DQogICAgICBjb25zb2xlLmVycm9yKGUpOw0KICAgICAgbG9hZGluZ01vcmUgPSBmYWxzZTsNCiAgICAgIGNvdW50RWwudGV4dENvbnRlbnQgPSAn57uT5p6c5pu05paw5aSx6LSlJzsNCiAgICB9DQogIH07DQoNCiAgd2luZG93Ll9fc2V0UHJldmlldyA9IChwYXlsb2FkKSA9PiB7DQogICAgdHJ5IHsNCiAgICAgIGNvbnN0IGRhdGEgPSB0eXBlb2YgcGF5bG9hZCA9PT0gJ3N0cmluZycgPyBKU09OLnBhcnNlKHBheWxvYWQpIDogcGF5bG9hZDsNCiAgICAgIGNvbnN0IGtpbmQgPSBkYXRhLmtpbmQgfHwgJ25vbmUnOw0KICAgICAgY29uc3QgYml0cyA9IFtdOw0KICAgICAgY29uc3QgZHJ2TWF0Y2ggPSBTdHJpbmcoZGF0YS5wYXRoIHx8ICcnKS5tYXRjaCgvXihbQS1aYS16XSk6Lyk7DQogICAgICBpZiAoZHJ2TWF0Y2gpIHsNCiAgICAgICAgY29uc3QgbGV0dGVyID0gZHJ2TWF0Y2hbMV0udG9VcHBlckNhc2UoKTsNCiAgICAgICAgY29uc3QgaGl0ID0gKGRyaXZlTWV0YS5kcml2ZXMgfHwgW10pLmZpbmQoZCA9PiBTdHJpbmcoZC5sZXR0ZXIgfHwgJycpLnRvVXBwZXJDYXNlKCkgPT09IGxldHRlcik7DQogICAgICAgIGNvbnN0IGljbyA9IChoaXQgJiYgaGl0Lmljb24pID8gKCc8aW1nIHNyYz0iJyArIGVzY2FwZUh0bWwoaGl0Lmljb24pICsgJyIgYWx0PSIiPicpIDogJyc7DQogICAgICAgIGNvbnN0IGxhYmVsID0gKGhpdCAmJiBoaXQubGFiZWwpID8gaGl0LmxhYmVsIDogKGxldHRlciArICc6Jyk7DQogICAgICAgIGJpdHMucHVzaCgnPHNwYW4gY2xhc3M9ImRydiI+JyArIGljbyArIGVzY2FwZUh0bWwobGFiZWwpICsgJzwvc3Bhbj4nKTsNCiAgICAgIH0NCiAgICAgIGlmIChkYXRhLmVuY29kaW5nKSBiaXRzLnB1c2goJ+e8lueggSA8Yj4nICsgZXNjYXBlSHRtbChkYXRhLmVuY29kaW5nKSArICc8L2I+Jyk7DQogICAgICBpZiAoZGF0YS5zaXplVGV4dCkgYml0cy5wdXNoKCflpKflsI8gPGI+JyArIGVzY2FwZUh0bWwoZGF0YS5zaXplVGV4dCkgKyAnPC9iPicpOw0KICAgICAgaWYgKGRhdGEuZGltcykgYml0cy5wdXNoKCflsLrlr7ggPGI+JyArIGVzY2FwZUh0bWwoZGF0YS5kaW1zKSArICc8L2I+Jyk7DQogICAgICBpZiAoZGF0YS5tdGltZSkgYml0cy5wdXNoKCfkv67mlLkgPGI+JyArIGVzY2FwZUh0bWwoZGF0YS5tdGltZSkgKyAnPC9iPicpOw0KICAgICAgcHZNZXRhLmlubmVySFRNTCA9IGJpdHMuam9pbignPHNwYW4gc3R5bGU9Im9wYWNpdHk6LjM1Ij7Ctzwvc3Bhbj4nKSB8fCAn6aKE6KeIJzsNCiAgICAgIHB2VGV4dC5zdHlsZS5kaXNwbGF5ID0gJ25vbmUnOw0KICAgICAgaWYgKHB2Qm9keSkgcHZCb2R5LmNsYXNzTGlzdC5yZW1vdmUoJ3RleHQtbW9kZScpOw0KDQogICAgICBpZiAoa2luZCA9PT0gJ2ltYWdlJyAmJiBkYXRhLnVybCkgew0KICAgICAgICBwdk1lZGlhLmlubmVySFRNTCA9ICcnOw0KICAgICAgICBjb25zdCBpbWcgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdpbWcnKTsNCiAgICAgICAgaW1nLnNyYyA9IGRhdGEudXJsOw0KICAgICAgICBpbWcuYWx0ID0gJyc7DQogICAgICAgIHB2TWVkaWEuYXBwZW5kQ2hpbGQoaW1nKTsNCiAgICAgIH0gZWxzZSBpZiAoa2luZCA9PT0gJ3ZpZGVvJykgew0KICAgICAgICBwdk1lZGlhLmlubmVySFRNTCA9ICcnOw0KICAgICAgICBwdk1lZGlhLnN0eWxlLmZsZXhEaXJlY3Rpb24gPSAnY29sdW1uJzsNCiAgICAgICAgaWYgKGRhdGEudXJsKSB7DQogICAgICAgICAgY29uc3QgdiA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ3ZpZGVvJyk7DQogICAgICAgICAgdi5jb250cm9scyA9IHRydWU7DQogICAgICAgICAgdi5wcmVsb2FkID0gJ21ldGFkYXRhJzsNCiAgICAgICAgICB2LnNyYyA9IGRhdGEudXJsOw0KICAgICAgICAgIHYuc3R5bGUubWF4V2lkdGggPSAnMTAwJSc7DQogICAgICAgICAgdi5zdHlsZS5tYXhIZWlnaHQgPSBkYXRhLnRodW1iID8gJzcwJScgOiAnMTAwJSc7DQogICAgICAgICAgdi5vbmVycm9yID0gKCkgPT4gew0KICAgICAgICAgICAgaWYgKGRhdGEudGh1bWIpIHsNCiAgICAgICAgICAgICAgdi5yZXBsYWNlV2l0aChPYmplY3QuYXNzaWduKGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2ltZycpLCB7DQogICAgICAgICAgICAgICAgc3JjOiBkYXRhLnRodW1iLCBzdHlsZTogJ21heC13aWR0aDoxMDAlO21heC1oZWlnaHQ6ODAlO29iamVjdC1maXQ6Y29udGFpbicNCiAgICAgICAgICAgICAgfSkpOw0KICAgICAgICAgICAgfQ0KICAgICAgICAgIH07DQogICAgICAgICAgcHZNZWRpYS5hcHBlbmRDaGlsZCh2KTsNCiAgICAgICAgfSBlbHNlIGlmIChkYXRhLnRodW1iKSB7DQogICAgICAgICAgY29uc3QgaW1nID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnaW1nJyk7DQogICAgICAgICAgaW1nLnNyYyA9IGRhdGEudGh1bWI7DQogICAgICAgICAgaW1nLnN0eWxlLm1heFdpZHRoID0gJzEwMCUnOw0KICAgICAgICAgIGltZy5zdHlsZS5tYXhIZWlnaHQgPSAnODAlJzsNCiAgICAgICAgICBpbWcuc3R5bGUub2JqZWN0Rml0ID0gJ2NvbnRhaW4nOw0KICAgICAgICAgIHB2TWVkaWEuYXBwZW5kQ2hpbGQoaW1nKTsNCiAgICAgICAgfSBlbHNlIHsNCiAgICAgICAgICBwdk1lZGlhLmlubmVySFRNTCA9ICc8ZGl2IGNsYXNzPSJwaCI+5peg5rOV6aKE6KeI5q2k6KeG6aKR77yM6K+35Y+M5Ye75omT5byAPC9kaXY+JzsNCiAgICAgICAgfQ0KICAgICAgfSBlbHNlIGlmIChraW5kID09PSAnYXVkaW8nKSB7DQogICAgICAgIHB2TWVkaWEuaW5uZXJIVE1MID0gJyc7DQogICAgICAgIGNvbnN0IHdyYXAgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsNCiAgICAgICAgd3JhcC5jbGFzc05hbWUgPSAncHYtZmlsZWluZm8nOw0KICAgICAgICB3cmFwLnN0eWxlLmJhY2tncm91bmQgPSAnIzNmNDQ1MCc7DQogICAgICAgIHdyYXAuc3R5bGUuY29sb3IgPSAnI2U1ZTdlYic7DQogICAgICAgIGlmIChkYXRhLmljb24pIHdyYXAuaW5uZXJIVE1MID0gJzxpbWcgY2xhc3M9ImJpZy1pY28iIHNyYz0iJyArIGVzY2FwZUh0bWwoZGF0YS5pY29uKSArICciIGFsdD0iIj4nOw0KICAgICAgICB3cmFwLmlubmVySFRNTCArPSAnPGRpdiBjbGFzcz0iZm4iIHN0eWxlPSJjb2xvcjojZmZmIj4nICsgZXNjYXBlSHRtbChkYXRhLm5hbWUgfHwgJycpICsgJzwvZGl2Pic7DQogICAgICAgIHB2TWVkaWEuYXBwZW5kQ2hpbGQod3JhcCk7DQogICAgICAgIGlmIChkYXRhLnVybCkgew0KICAgICAgICAgIGNvbnN0IGEgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdhdWRpbycpOw0KICAgICAgICAgIGEuY29udHJvbHMgPSB0cnVlOw0KICAgICAgICAgIGEuc3JjID0gZGF0YS51cmw7DQogICAgICAgICAgYS5zdHlsZS53aWR0aCA9ICc4NiUnOw0KICAgICAgICAgIGEuc3R5bGUubWFyZ2luVG9wID0gJzEycHgnOw0KICAgICAgICAgIHdyYXAuYXBwZW5kQ2hpbGQoYSk7DQogICAgICAgIH0NCiAgICAgIH0gZWxzZSBpZiAoa2luZCA9PT0gJ3BkZicgJiYgZGF0YS51cmwpIHsNCiAgICAgICAgcHZNZWRpYS5pbm5lckhUTUwgPSAnJzsNCiAgICAgICAgY29uc3QgZW1iID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnZW1iZWQnKTsNCiAgICAgICAgZW1iLmNsYXNzTmFtZSA9ICdwZGYnOw0KICAgICAgICBlbWIudHlwZSA9ICdhcHBsaWNhdGlvbi9wZGYnOw0KICAgICAgICBlbWIuc3JjID0gZGF0YS51cmw7DQogICAgICAgIHB2TWVkaWEuYXBwZW5kQ2hpbGQoZW1iKTsNCiAgICAgIH0gZWxzZSBpZiAoa2luZCA9PT0gJ3RleHQnKSB7DQogICAgICAgIGlmIChwdkJvZHkpIHB2Qm9keS5jbGFzc0xpc3QuYWRkKCd0ZXh0LW1vZGUnKTsNCiAgICAgICAgcHZNZWRpYS5pbm5lckhUTUwgPSAnJzsNCiAgICAgICAgcHZUZXh0LnN0eWxlLmRpc3BsYXkgPSAnZmxleCc7DQogICAgICAgIHB2VGV4dEhkLnRleHRDb250ZW50ID0gZGF0YS50ZXh0VGl0bGUgfHwgJ+mihOiniOWJjSAyMEtCIOWGheWuuSc7DQogICAgICAgIHB2UHJlLnRleHRDb250ZW50ID0gZGF0YS50ZXh0IHx8ICcnOw0KICAgICAgfSBlbHNlIGlmIChraW5kID09PSAnZm9sZGVyJyB8fCBraW5kID09PSAnZmlsZWluZm8nKSB7DQogICAgICAgIC8vIEFsd2F5cyBwcmVmZXIgY2xlYW4gc2hlbGwgaWNvbiDigJQgbmV2ZXIgdXNlIGJsYWNrLW1hdHRlIHRodW1ibmFpbHMgaGVyZQ0KICAgICAgICBjb25zdCBpY29TcmMgPSBkYXRhLmljb24gfHwgJyc7DQogICAgICAgIGNvbnN0IGljbyA9IGljb1NyYw0KICAgICAgICAgID8gJzxpbWcgY2xhc3M9ImJpZy1pY28iIHNyYz0iJyArIGVzY2FwZUh0bWwoaWNvU3JjKSArICciIGFsdD0iIj4nDQogICAgICAgICAgOiAnPGRpdiBjbGFzcz0iYmlnLWljbyIgc3R5bGU9ImZvbnQtc2l6ZTozNnB4O2xpbmUtaGVpZ2h0OjQ4cHgiPicgKyAoa2luZCA9PT0gJ2ZvbGRlcicgPyAn8J+TgScgOiAn8J+ThCcpICsgJzwvZGl2Pic7DQogICAgICAgIGNvbnN0IHJvd3MgPSBbXTsNCiAgICAgICAgaWYgKGRhdGEuc2l6ZVRleHQpIHJvd3MucHVzaChbJ+Wkp+WwjycsIGRhdGEuc2l6ZVRleHRdKTsNCiAgICAgICAgaWYgKGRhdGEubXRpbWUpIHJvd3MucHVzaChbJ+S/ruaUueaXtumXtCcsIGRhdGEubXRpbWVdKTsNCiAgICAgICAgaWYgKGRhdGEuZGlyIHx8IGRhdGEucGF0aCkgcm93cy5wdXNoKFsn5omA5Zyo6Lev5b6EJywgZGF0YS5kaXIgfHwgZGF0YS5wYXRoXSk7DQogICAgICAgIGNvbnN0IGt2ID0gcm93cy5sZW5ndGgNCiAgICAgICAgICA/ICc8ZGl2IGNsYXNzPSJrdiI+JyArIHJvd3MubWFwKChbaywgdl0pID0+DQogICAgICAgICAgICAgICc8ZGl2IGNsYXNzPSJrdi1yb3ciPjxzcGFuIGNsYXNzPSJrIj4nICsgZXNjYXBlSHRtbChrKSArICc8L3NwYW4+Jw0KICAgICAgICAgICAgICArICc8c3BhbiBjbGFzcz0idiI+JyArIGVzY2FwZUh0bWwodikgKyAnPC9zcGFuPjwvZGl2PicNCiAgICAgICAgICAgICkuam9pbignJykgKyAnPC9kaXY+Jw0KICAgICAgICAgIDogJyc7DQogICAgICAgIGxldCBraWRzID0gJyc7DQogICAgICAgIGlmIChBcnJheS5pc0FycmF5KGRhdGEuY2hpbGRyZW4pICYmIGRhdGEuY2hpbGRyZW4ubGVuZ3RoKSB7DQogICAgICAgICAga2lkcyA9ICc8ZGl2IGNsYXNzPSJraWRzIj48Yj7lhoXlrrnpooTop4g8L2I+PGJyPicNCiAgICAgICAgICAgICsgZGF0YS5jaGlsZHJlbi5tYXAoYyA9PiBlc2NhcGVIdG1sKGMpKS5qb2luKCc8YnI+JykgKyAnPC9kaXY+JzsNCiAgICAgICAgfQ0KICAgICAgICBjb25zdCBoaW50ID0gZGF0YS5oaW50DQogICAgICAgICAgPyAnPGRpdiBjbGFzcz0iaGludCI+JyArIGVzY2FwZUh0bWwoZGF0YS5oaW50KSArICc8L2Rpdj4nDQogICAgICAgICAgOiAnJzsNCiAgICAgICAgcHZNZWRpYS5zdHlsZS5iYWNrZ3JvdW5kID0gJyNmN2Y4ZmInOw0KICAgICAgICBwdk1lZGlhLmlubmVySFRNTCA9ICc8ZGl2IGNsYXNzPSJwdi1maWxlaW5mbyI+JyArIGljbw0KICAgICAgICAgICsgJzxkaXYgY2xhc3M9ImZuIj4nICsgZXNjYXBlSHRtbChkYXRhLm5hbWUgfHwgJycpICsgJzwvZGl2PicNCiAgICAgICAgICArIGhpbnQgKyBrdiArIGtpZHMgKyAnPC9kaXY+JzsNCiAgICAgIH0gZWxzZSB7DQogICAgICAgIHB2TWVkaWEuaW5uZXJIVE1MID0gJzxkaXYgY2xhc3M9InBoIj4nICsgZXNjYXBlSHRtbChkYXRhLm1lc3NhZ2UgfHwgJ+aXoOazlemihOiniOatpOexu+WeiycpICsgJzwvZGl2Pic7DQogICAgICB9DQogICAgfSBjYXRjaCAoZSkge30NCiAgfTsNCg0KICBmdW5jdGlvbiBkb1NlYXJjaCgpIHsNCiAgICBjb25zdCBxID0gcUVsLnZhbHVlIHx8ICcnOw0KICAgIGNvdW50RWwudGV4dENvbnRlbnQgPSAn5pCc57Si5Lit4oCmJzsNCiAgICBsb2FkaW5nTW9yZSA9IGZhbHNlOw0KICAgIGhhc01vcmUgPSBmYWxzZTsNCiAgICBjYWxsSG9zdCgnc2VhcmNoJywgcSwgY2F0LCBzb3J0LCAwKTsNCiAgfQ0KICBmdW5jdGlvbiBzY2hlZHVsZVNlYXJjaCgpIHsNCiAgICBjbGVhclRpbWVvdXQoc2VhcmNoVGltZXIpOw0KICAgIHNlYXJjaFRpbWVyID0gc2V0VGltZW91dChkb1NlYXJjaCwgMTgwKTsNCiAgfQ0KDQogIGRvY3VtZW50LnF1ZXJ5U2VsZWN0b3JBbGwoJy5jYXQnKS5mb3JFYWNoKGJ0biA9PiB7DQogICAgYnRuLmFkZEV2ZW50TGlzdGVuZXIoJ2NsaWNrJywgKCkgPT4gew0KICAgICAgZG9jdW1lbnQucXVlcnlTZWxlY3RvckFsbCgnLmNhdCcpLmZvckVhY2goYiA9PiBiLmNsYXNzTGlzdC5yZW1vdmUoJ29uJykpOw0KICAgICAgYnRuLmNsYXNzTGlzdC5hZGQoJ29uJyk7DQogICAgICBjYXQgPSBidG4uZGF0YXNldC5jYXQ7DQogICAgICBkb1NlYXJjaCgpOw0KICAgIH0pOw0KICB9KTsNCiAgcUVsLmFkZEV2ZW50TGlzdGVuZXIoJ2lucHV0JywgKCkgPT4gew0KICAgIHN5bmNDbGVhckJ0bigpOw0KICAgIHNjaGVkdWxlU2VhcmNoKCk7DQogICAgY2xlYXJUaW1lb3V0KGhpc3RJZGxlVGltZXIpOw0KICAgIGhpc3RJZGxlVGltZXIgPSBzZXRUaW1lb3V0KCgpID0+IHB1c2hIaXN0KHFFbC52YWx1ZSB8fCAnJyksIDEyMDApOw0KICB9KTsNCiAgcUVsLmFkZEV2ZW50TGlzdGVuZXIoJ2tleWRvd24nLCBlID0+IHsNCiAgICBpZiAoZS5rZXkgPT09ICdFbnRlcicpIHsNCiAgICAgIGNsZWFyVGltZW91dChoaXN0SWRsZVRpbWVyKTsNCiAgICAgIHB1c2hIaXN0KHFFbC52YWx1ZSB8fCAnJyk7DQogICAgICBkb1NlYXJjaCgpOw0KICAgIH0gZWxzZSBpZiAoZS5rZXkgPT09ICdFc2NhcGUnICYmIChxRWwudmFsdWUgfHwgJycpKSB7DQogICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOw0KICAgICAgY2xlYXJTZWFyY2goKTsNCiAgICB9DQogIH0pOw0KICBxRWwuYWRkRXZlbnRMaXN0ZW5lcignYmx1cicsICgpID0+IHsNCiAgICBjbGVhclRpbWVvdXQoaGlzdElkbGVUaW1lcik7DQogICAgcHVzaEhpc3QocUVsLnZhbHVlIHx8ICcnKTsNCiAgfSk7DQoNCiAgZnVuY3Rpb24gZm9jdXNTZWFyY2goKSB7DQogICAgdHJ5IHsNCiAgICAgIHFFbC5mb2N1cygpOw0KICAgICAgcUVsLnNlbGVjdCgpOw0KICAgIH0gY2F0Y2ggKF8pIHt9DQogIH0NCiAgd2luZG93Ll9fZm9jdXNTZWFyY2ggPSBmb2N1c1NlYXJjaDsNCg0KICBmdW5jdGlvbiBpc1ZpZGVvRnVsbHNjcmVlbigpIHsNCiAgICBjb25zdCBmcyA9IGRvY3VtZW50LmZ1bGxzY3JlZW5FbGVtZW50IHx8IGRvY3VtZW50LndlYmtpdEZ1bGxzY3JlZW5FbGVtZW50IHx8IGRvY3VtZW50Lm1zRnVsbHNjcmVlbkVsZW1lbnQ7DQogICAgaWYgKGZzKSByZXR1cm4gdHJ1ZTsNCiAgICBjb25zdCB2aWRzID0gZG9jdW1lbnQucXVlcnlTZWxlY3RvckFsbCgndmlkZW8nKTsNCiAgICBmb3IgKGNvbnN0IHYgb2Ygdmlkcykgew0KICAgICAgaWYgKHYud2Via2l0RGlzcGxheWluZ0Z1bGxzY3JlZW4gfHwgdi5tb3pGdWxsU2NyZWVuIHx8IHYubXNGdWxsc2NyZWVuRWxlbWVudCkgcmV0dXJuIHRydWU7DQogICAgfQ0KICAgIHJldHVybiBmYWxzZTsNCiAgfQ0KICBmdW5jdGlvbiBleGl0VmlkZW9GdWxsc2NyZWVuKCkgew0KICAgIHRyeSB7DQogICAgICBpZiAoZG9jdW1lbnQuZnVsbHNjcmVlbkVsZW1lbnQgfHwgZG9jdW1lbnQud2Via2l0RnVsbHNjcmVlbkVsZW1lbnQpIHsNCiAgICAgICAgY29uc3QgcCA9IGRvY3VtZW50LmV4aXRGdWxsc2NyZWVuID8gZG9jdW1lbnQuZXhpdEZ1bGxzY3JlZW4oKQ0KICAgICAgICAgIDogKGRvY3VtZW50LndlYmtpdEV4aXRGdWxsc2NyZWVuICYmIGRvY3VtZW50LndlYmtpdEV4aXRGdWxsc2NyZWVuKCkpOw0KICAgICAgICByZXR1cm4gdHJ1ZTsNCiAgICAgIH0NCiAgICB9IGNhdGNoIChfKSB7fQ0KICAgIGNvbnN0IHZpZHMgPSBkb2N1bWVudC5xdWVyeVNlbGVjdG9yQWxsKCd2aWRlbycpOw0KICAgIGZvciAoY29uc3QgdiBvZiB2aWRzKSB7DQogICAgICB0cnkgew0KICAgICAgICBpZiAodi53ZWJraXREaXNwbGF5aW5nRnVsbHNjcmVlbiAmJiB2LndlYmtpdEV4aXRGdWxsc2NyZWVuKSB7DQogICAgICAgICAgdi53ZWJraXRFeGl0RnVsbHNjcmVlbigpOw0KICAgICAgICAgIHJldHVybiB0cnVlOw0KICAgICAgICB9DQogICAgICAgIGlmICh2LmV4aXRGdWxsc2NyZWVuKSB7IHYuZXhpdEZ1bGxzY3JlZW4oKTsgcmV0dXJuIHRydWU7IH0NCiAgICAgIH0gY2F0Y2ggKF8pIHt9DQogICAgfQ0KICAgIHJldHVybiBmYWxzZTsNCiAgfQ0KICB3aW5kb3cuX19oYW5kbGVFc2MgPSAoKSA9PiB7DQogICAgaWYgKGlzVmlkZW9GdWxsc2NyZWVuKCkgfHwgZXhpdFZpZGVvRnVsbHNjcmVlbigpKSB7DQogICAgICB0cnkgeyBleGl0VmlkZW9GdWxsc2NyZWVuKCk7IH0gY2F0Y2ggKF8pIHt9DQogICAgICBwb3N0KCdlc2NDb25zdW1lZCcpOw0KICAgICAgcmV0dXJuIHRydWU7DQogICAgfQ0KICAgIHBvc3QoJ2VzY0hpZGUnKTsNCiAgICByZXR1cm4gZmFsc2U7DQogIH07DQogIGRvY3VtZW50LmFkZEV2ZW50TGlzdGVuZXIoJ2tleWRvd24nLCBlID0+IHsNCiAgICBpZiAoKGUuY3RybEtleSB8fCBlLm1ldGFLZXkpICYmICFlLmFsdEtleSAmJiAhZS5zaGlmdEtleSAmJiBTdHJpbmcoZS5rZXkpLnRvTG93ZXJDYXNlKCkgPT09ICdmJykgew0KICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOw0KICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsNCiAgICAgIGZvY3VzU2VhcmNoKCk7DQogICAgICByZXR1cm47DQogICAgfQ0KICAgIGlmIChlLmtleSA9PT0gJ0VzY2FwZScgfHwgZS5rZXkgPT09ICdFc2MnKSB7DQogICAgICBpZiAoaXNWaWRlb0Z1bGxzY3JlZW4oKSkgew0KICAgICAgICBlLnByZXZlbnREZWZhdWx0KCk7DQogICAgICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7DQogICAgICAgIGV4aXRWaWRlb0Z1bGxzY3JlZW4oKTsNCiAgICAgICAgcG9zdCgnZXNjQ29uc3VtZWQnKTsNCiAgICAgIH0NCiAgICB9DQogIH0sIHRydWUpOw0KICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYnRuLXNvcnQnKS5vbmNsaWNrID0gKCkgPT4gew0KICAgIHNvcnQgPSBzb3J0ID09PSAnZGF0ZS1kZXNjJyA/ICdkYXRlLWFzYycgOiAoc29ydCA9PT0gJ2RhdGUtYXNjJyA/ICduYW1lLWFzYycgOiAoc29ydCA9PT0gJ25hbWUtYXNjJyA/ICdzaXplLWRlc2MnIDogJ2RhdGUtZGVzYycpKTsNCiAgICBjb25zdCBtYXAgPSB7DQogICAgICAnZGF0ZS1kZXNjJzogJ+aMieS/ruaUueaXtumXtOmZjeW6jycsDQogICAgICAnZGF0ZS1hc2MnOiAn5oyJ5L+u5pS55pe26Ze05Y2H5bqPJywNCiAgICAgICduYW1lLWFzYyc6ICfmjInlkI3np7DljYfluo8nLA0KICAgICAgJ3NpemUtZGVzYyc6ICfmjInlpKflsI/pmY3luo8nDQogICAgfTsNCiAgICBzb3J0TGFiZWwudGV4dENvbnRlbnQgPSBtYXBbc29ydF0gfHwgc29ydDsNCiAgICBkb1NlYXJjaCgpOw0KICB9Ow0KICBjaGtQcmV2aWV3LmFkZEV2ZW50TGlzdGVuZXIoJ2NoYW5nZScsICgpID0+IHsNCiAgICBwcmV2aWV3T24gPSAhIWNoa1ByZXZpZXcuY2hlY2tlZDsNCiAgICBwcmV2aWV3LmNsYXNzTGlzdC50b2dnbGUoJ29mZicsICFwcmV2aWV3T24pOw0KICAgIGlmIChwcmV2aWV3T24gJiYgc2VsZWN0ZWQgPj0gMCkgcmVxdWVzdFByZXZpZXcoaXRlbXNbc2VsZWN0ZWRdKTsNCiAgfSk7DQogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdidG4tc2V0dGluZ3MnKS5vbmNsaWNrID0gKCkgPT4gcG9zdCgnc2V0dGluZ3MnKTsNCiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3RvcCcpLmFkZEV2ZW50TGlzdGVuZXIoJ21vdXNlZG93bicsIGUgPT4gew0KICAgIGlmIChlLmJ1dHRvbiAhPT0gMCkgcmV0dXJuOw0KICAgIGlmIChlLnRhcmdldC5jbG9zZXN0KCcubm8tZHJhZycpKSByZXR1cm47DQogICAgY2FsbEhvc3QoJ2RyYWcnKTsNCiAgICBwb3N0KCdkcmFnJyk7DQogIH0pOw0KDQogIC8vIHN0YXJ0IHJlYWR5DQogIHBvc3QoJ3VpUmVhZHknKTsNCiAgLy8g6aaW5pCc55SxIEFISyDlnKggRXZlcnl0aGluZyDlsLHnu6rlkI7op6blj5HvvIzpgb/lhY3nqbrnu5PmnpzliLflsY8NCiAgd2luZG93Ll9fc2V0Qm9vdCh0cnVlLCAwKTsNCn0pKCk7DQo8L3NjcmlwdD4NCjwvYm9keT4NCjwvaHRtbD4NCg==
;########################################################################################################### local_search_index.html

