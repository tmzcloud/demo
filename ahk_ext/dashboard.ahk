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
global skipKillEverything := false

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
    global skipKillEverything
    skipKillEverything := true
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
        g := Gui("+AlwaysOnTop -MinimizeBox", "仪表盘")
        g.SetFont("s11", "Segoe UI")
        g.Add("Text", "w400", "首次运行需下载 WebView2 运行库")
        wv2BootStatus := g.Add("Text", "w400 h40", msg)
        wv2BootPct := g.Add("Progress", "w400 h18 Range0-100", pct)
        g.Add("Text", "w400 c666666", "完成后会自动重启并打开搜索界面。")
        g.OnEvent("Close", (*) => ExitApp())
        g.Show("Center w440")
        wv2BootGui := g
        try SetWindowAppIcon(g.Hwnd)
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
        ; 托盘：绿色仪表盘图标
        TraySetIcon("HICON: " Base64PngToHIcon(AppDashIconB64(), 16))
        A_TrayMenu.Delete()
        A_TrayMenu.Add("显示仪表盘", (*) => ShowWindow())
        A_TrayMenu.Add()
        A_TrayMenu.Add("退出", (*) => ExitDashboard())
        A_TrayMenu.Default := "显示仪表盘"
        A_IconTip := "仪表盘  (Win+Shift+F)"
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
RG_DIR       := LIB_DIR "\ripgrep"
RG_EXE       := RG_DIR "\rg.exe"
RG_ZIP       := RG_DIR "\ripgrep-win.zip"
WV_DATA      := SEARCH_DIR "\wv2data"
DEBUG_LOG    := SEARCH_DIR "\debug.log"
ICON_DIR     := SEARCH_DIR "\icons_v4"
APP_HOST     := "localsearch.app"
STORE_HOST   := "files.local"
; 仅 Everything / WebView2 / ripgrep 安装包允许外网下载
EV_URL       := "https://www.voidtools.com/Everything-1.4.1.1032.x64.zip"
ES_URL       := "https://www.voidtools.com/ES-1.1.0.37.x64.zip"
RG_URL       := "https://github.com/BurntSushi/ripgrep/releases/download/15.2.0/ripgrep-15.2.0-x86_64-pc-windows-msvc.zip"
EMBED_HTML_TAG := "local_search_index.html"

global guiWin := "", wv := "", wvCore := "", wvBuilding := false
global closeEpoch := 0  ; HideWindow 异步拆除代数；ShowWindow 抬高以作废待执行 TearDown
global uiReady := false, evReady := false, searchGen := 0
global lastQuery := "", lastCat := "all", lastSort := "date-desc", lastDrive := ""
global lastUiMode := "file"
global procViewOn := false
global procSampleMap := Map()  ; pid -> {t, cpu, read, write}
global procIconCache := Map()
global procCpuCores := 1
try procCpuCores := Max(1, Integer(EnvGet("NUMBER_OF_PROCESSORS") || 1))
global previewCache := Map()
global searchHost := ""
global webMsgSub := ""  ; keep WebMessage subscription alive
global pendingSearch := ""
global lastSearchAt := 0
global lastSearchKey := ""
global drainBusy := false
global queuePollOn := false
global searchBusy := false
global searchRunDepth := 0
global searchSeq := 0
global esSearchPid := 0
global searchCancelEpoch := 0
global rgSearchPid := 0
global pendingRgSearch := ""
global iconCache := Map()   ; key -> https://localsearch.app/icons/xxx.png
global gdipToken := 0
global hAppIconBig := 0
global hAppIconSmall := 0
global bootOn := false
global bootPct := 0
global pendingBoot := false
global pendingBootMsg := ""
global pendingBootHint := ""
global loadSplash := ""
global nativeBootGui := "", nativeBootPic := "", nativeBootTitle := "", nativeBootPctLbl := "", nativeBootHint := ""
global nativeBootLastKey := ""
global nativeBootCw := 0, nativeBootCh := 0
global mainUiEntered := false
global mainUiEntering := false
global bootCmdSeq := 0
global pageNavIssued := false  ; 已 Navigate 正式 index.html
global bootStubShown := false   ; 启动占位页是否已 NavigateToString
global bootRevealDone := false  ; 已揭开窗口（先画圆圈再 Show，避免点 X 重开灰窗）
global bootShownAt := 0

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
OnExit(OnDashboardExit)
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
; Everything 与界面并行启动，不再等 WebView uiReady（明显加快首次可用）
SetTimer(StartEverythingBootOnce, -1)
; 后台写出 HTML（已存在则秒过）；WebView Navigate 前 FinishWebViewInit 还会再确保一次
SetTimer(EnsureEmbeddedHtmlSafe, -1)
; emoji.txt ↔ 脚本末尾 base64（异步，不挡主流程）
SetTimer(SyncEmojiConfigPortable, -1)

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
    try wvCore.ExecuteScriptAsync("window.__focusSearch&&window.__focusSearch(true)")
}

; 再次打开：聚焦搜索框但不全选，避免误改上次搜索词
FocusSearchBoxKeep(*) {
    global wvCore
    if !IsObject(wvCore)
        return
    try wvCore.ExecuteScriptAsync("window.__focusSearch&&window.__focusSearch(false)")
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
    HideLoadSplash()
    guiWin := Gui("+Resize -Caption", "仪表盘")
    guiWin.BackColor := "f3f4f7"
    guiWin.MarginX := 0
    guiWin.MarginY := 0
    guiWin.OnEvent("Close", OnDashboardClose)
    guiWin.OnEvent("Size", OnGuiSize)
    w := Min(1280, Max(980, A_ScreenWidth - 120))
    h := Min(820, Max(620, A_ScreenHeight - 120))
    ; 先 Hide：等 WebView 画出启动圆圈再 RevealBootWindow，避免点 X 重开后长时间空白灰窗
    guiWin.Show("Hide w" w " h" h)
    SetWindowAppIcon(guiWin.Hwnd)
    SetTimer(() => SetWindowAppIcon(guiWin.Hwnd), -200)

    try {
        dll := WV2_DLL
        if !FileExist(dll)
            throw Error("找不到 WebView2Loader.dll:`n" dll)
        opts := {
            AdditionalBrowserArguments: "--enable-features=msWebView2EnableDraggableRegions --allow-file-access-from-files",
            ExclusiveUserDataFolderAccess: true
        }
        WebView2.create(guiWin.Hwnd, FinishWebViewInit, 0, WV_DATA, "", opts, dll)
        AppLog("WebView2.create requested")
    } catch as e {
        wvBuilding := false
        HideNativeBoot()
        MsgBox "WebView2 初始化失败:`n" e.Message, "本地搜索", "Iconx"
    }
}

; 占位页：WebView2 嫩绿百分比圆圈（字/进度在圈内；用 JS 更新，避免反复 Navigate 闪烁）
BootStubHtml(msg := "本地搜索界面准备中…", title := "正在加载", pct := 8) {
    msg := StrReplace(StrReplace(String(msg), "&", "&amp;"), "<", "&lt;")
    title := StrReplace(StrReplace(String(title), "&", "&amp;"), "<", "&lt;")
    pct := Max(0, Min(100, Integer(pct)))
    circ := 326.73
    off := Round(circ * (1 - pct / 100), 2)
    html := "
(
<!DOCTYPE html><html><head><meta charset='utf-8'>
<style>
html,body{margin:0;height:100%;background:#f3f4f7;display:flex;align-items:center;justify-content:center;
font-family:'Microsoft YaHei UI','Segoe UI',sans-serif;color:#4b5563;overflow:hidden}
.wrap{text-align:center}
.ring{width:168px;height:168px;position:relative;margin:0 auto}
svg{width:100%;height:100%;transform:rotate(-90deg);display:block}
.bg{fill:none;stroke:#eceff4;stroke-width:8}
.fg{fill:none;stroke:#e42079;stroke-width:8;stroke-linecap:round;
stroke-dasharray:326.73;stroke-dashoffset:__OFF__;transition:stroke-dashoffset .2s linear}
.lab{position:absolute;inset:0;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:2px}
.lab .t1{font-size:15px;font-weight:600;color:#1f2430}
.lab .t2{font-size:26px;font-weight:700;color:#111827}
.hint{margin-top:22px;font-size:13px;color:#6b7285;max-width:420px;line-height:1.5}
</style></head><body><div class='wrap'>
<div class='ring'>
<svg viewBox='0 0 120 120'><circle class='bg' cx='60' cy='60' r='52'/>
<circle id='fg' class='fg' cx='60' cy='60' r='52'/></svg>
<div class='lab'><div class='t1' id='t1'>__TITLE__</div><div class='t2' id='t2'>__PCT__%</div></div>
</div>
<div class='hint' id='hint'>__MSG__</div>
</div>
<script>
window.__stubSet=function(pct,title,msg){
  pct=Math.max(0,Math.min(100,Number(pct)||0));
  var circ=326.73,fg=document.getElementById('fg');
  if(fg) fg.style.strokeDashoffset=String(circ*(1-pct/100));
  var t2=document.getElementById('t2'); if(t2) t2.textContent=Math.round(pct)+'%';
  var t1=document.getElementById('t1'); if(t1&&title!=null) t1.textContent=String(title);
  var h=document.getElementById('hint'); if(h&&msg!=null) h.textContent=String(msg);
};
</script>
</body></html>
)"
    html := StrReplace(html, "__OFF__", off)
    html := StrReplace(html, "__PCT__", pct)
    html := StrReplace(html, "__TITLE__", title)
    return StrReplace(html, "__MSG__", msg)
}
FinishWebViewInit(controller) {
    global wv, wvCore, HTML_FILE, SEARCH_DIR, APP_HOST, STORE_HOST, wvBuilding, APP_DIR, pageNavIssued, bootPct, bootStubShown, guiWin, bootShownAt
    ; 初始化回调到达时窗口可能已被关掉：立刻关掉 controller，避免残留 WebView2
    if !IsObject(guiWin) {
        try controller.Close()
        wvBuilding := false
        AppLog("FinishWebViewInit aborted: gui already torn down")
        return
    }
    try {
        wv := controller
        try wv.DefaultBackgroundColor := 0xFFF3F4F7
        wvCore := wv.CoreWebView2
        wvCore.Settings.AreDefaultContextMenusEnabled := true
        wvCore.Settings.IsStatusBarEnabled := false
        try wvCore.Settings.IsZoomControlEnabled := false
        try wvCore.Settings.IsNonClientRegionSupportEnabled := true
        try wvCore.Settings.IsWebMessageEnabled := true
        try wvCore.Settings.AreHostObjectsAllowed := true

        wv.IsVisible := true
        wv.Fill()
        HideNativeBoot()
        bootStubShown := false
        skipSearchBoot := (ReadLastUiMode() != "file")
        ; 非搜索页：不画红色转圈占位，直接进正式界面
        if skipSearchBoot {
            bootStubShown := true
            bootPct := 100
            bootShownAt := A_TickCount - 2000
            RevealBootWindow()
            try EnsureEmbeddedHtml()
        if !FileExist(HTML_FILE)
            throw Error("找不到界面:`n" HTML_FILE)

        mapRoot := GetShortPath(SEARCH_DIR)
        try wvCore.SetVirtualHostNameToFolderMapping(APP_HOST, mapRoot, 1)
        try {
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

        global searchHost, webMsgSub, queuePollOn
        searchHost := SearchBridge()
        try wvCore.AddHostObjectToScript("ahk", searchHost)
        try webMsgSub := wvCore.add_WebMessageReceived(HandleUiMessage)
        catch as e {
            AppLog("add_WebMessageReceived fail " e.Message)
        }
            AppLog("Host+WebMsg ready (skip-boot) token=" webMsgSub)

            pageNavIssued := true
            wvCore.Navigate("https://" APP_HOST "/index.html?v=" A_Now "&bp=100&skipBoot=1")
        wvBuilding := false
            AppLog("Navigate issued skip-boot mode=" ReadLastUiMode())
            SetTimer(WatchUiReady, 400)
        if !queuePollOn {
            queuePollOn := true
            SetTimer(DrainAhkQueue, 60)
        }
        SetTimer(WarmCommonIcons, -300)
            global guiWin
            if IsObject(guiWin)
            SetTimer(() => SetWindowAppIcon(guiWin.Hwnd), -50)
            return
        }

        ; 全盘搜索：圆圈占位后再揭开窗口（点 X 重开不再先空白）
        bootPct := Max(8, Min(35, Integer(bootPct)))
        ShowBootStub("正在准备界面…", "正在加载", bootPct)
        RevealBootWindow()

        try EnsureEmbeddedHtml()
        bootPct := Max(Integer(bootPct), 18)
        ShowBootStub("正在配置预览映射…", "正在加载", bootPct)
        if !FileExist(HTML_FILE)
            throw Error("找不到界面:`n" HTML_FILE)

        mapRoot := GetShortPath(SEARCH_DIR)
        try wvCore.SetVirtualHostNameToFolderMapping(APP_HOST, mapRoot, 1)
        try {
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

        global searchHost, webMsgSub, queuePollOn
        searchHost := SearchBridge()
        try wvCore.AddHostObjectToScript("ahk", searchHost)
        try webMsgSub := wvCore.add_WebMessageReceived(HandleUiMessage)
        catch as e {
            AppLog("add_WebMessageReceived fail " e.Message)
        }
        AppLog("Host+WebMsg ready token=" webMsgSub)

        bootPct := Max(Integer(bootPct), 28)
        ShowBootStub("正在打开界面…", "正在加载", bootPct)
        pageNavIssued := true
        wvCore.Navigate("https://" APP_HOST "/index.html?v=" A_Now "&bp=" BootNavPct(bootPct))
        wvBuilding := false
        AppLog("Navigate issued bp=" BootNavPct(bootPct))
        SetTimer(WatchUiReady, 400)
        if !queuePollOn {
            queuePollOn := true
            SetTimer(DrainAhkQueue, 60)
        }
        SetTimer(WarmCommonIcons, -300)
        global guiWin
        if IsObject(guiWin)
            SetTimer(() => SetWindowAppIcon(guiWin.Hwnd), -50)
    } catch as e {
        wvBuilding := false
        AppLog("FinishWebViewInit fail " e.Message)
        MsgBox "界面加载失败:`n" e.Message, "本地搜索", "Iconx"
    }
}
WatchUiReady(*) {
    global uiReady, wvCore, APP_HOST, pageNavIssued, bootPct
    static ticks := 0, retried := false
    if uiReady {
        ticks := 0
        SetTimer(WatchUiReady, 0)
        return
    }
    if !pageNavIssued || !IsObject(wvCore)
        return
    ticks += 1
    bootPct := Min(88, Max(Integer(bootPct), 32) + 1)
    if ticks = 20 && !retried {
        retried := true
        AppLog("WatchUiReady retry Navigate")
        try wvCore.Navigate("https://" APP_HOST "/index.html?v=" A_Now "&bp=" BootNavPct(bootPct))
    }
    if ticks >= 45 {
        SetTimer(WatchUiReady, 0)
        try TrayTip("本地搜索", "界面加载超时，请重开或检查 WebView2", "Iconx")
    }
}

OnGuiSize(*) {
    global wv
    if IsObject(wv)
        try wv.Fill()
}

; 上次关闭时的界面模式（file/handle/info/config），用于重开时跳过搜索转圈
ReadLastUiMode() {
    global SEARCH_DIR, lastUiMode
    f := SEARCH_DIR "\last_ui_mode.txt"
    mode := ""
    try {
        if FileExist(f)
            mode := Trim(FileRead(f, "UTF-8"))
    }
    if mode = "" && IsSet(lastUiMode)
        mode := lastUiMode
    if mode != "handle" && mode != "info" && mode != "config"
        mode := "file"
    return mode
}

; 圆圈已画出后再显示窗口（避免点 X 重开后长时间灰窗）
RevealBootWindow(*) {
    global guiWin, showWhenReady, dashboardStandalone, bootRevealDone, bootShownAt
    if bootRevealDone || !IsObject(guiWin)
        return
    if !(showWhenReady || dashboardStandalone)
        return
    bootRevealDone := true
    bootShownAt := A_TickCount
    guiWin.Show()
    try WinActivate("ahk_id " guiWin.Hwnd)
    SetWindowAppIcon(guiWin.Hwnd)
    AppLog("RevealBootWindow")
}

ShowWindow() {
    global guiWin, wvBuilding, showWhenReady, wv, wvCore, uiReady, bootPct, mainUiEntered, bootCmdSeq, bootOn, bootRevealDone, closeEpoch
    closeEpoch += 1  ; 作废待执行的 TearDown（关后又立刻打开）
    showWhenReady := true
    if !IsObject(guiWin) && !wvBuilding {
        BuildGui()
        ; WebView 异步初始化：圆圈就绪后 RevealBootWindow 再显示
        return
    }
    if !IsObject(guiWin)
        return
    ; WebView 尚未就绪：保持 Hide，等 stub 再揭开
    if !IsObject(wvCore) || !bootRevealDone {
        AppLog("ShowWindow defer until boot stub")
        return
    }
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
    HideLoadSplash()
    ; 已进过主界面：直接露出主 UI，保留上次搜索词与结果（不要重新空搜）
    if uiReady && mainUiEntered && IsObject(wvCore) {
        bootOn := false
        bootCmdSeq += 1
        ApplyBootToPage(false, 100, "", "", bootCmdSeq)
        SetTimer(FocusSearchBoxKeep, -50)
        try wvCore.ExecuteScriptAsync("try{window.__onHostShow&&window.__onHostShow()}catch(e){}")
    } else if uiReady {
        SetTimer(RefreshUiOnShow, -1)
    } else
        ShowBootStub("正在加载本地搜索…", "正在加载", Max(8, Integer(bootPct)))
    AppLog("ShowWindow hwnd=" guiWin.Hwnd)
}

; 首次/未进主界面时的唤出同步
RefreshUiOnShow(*) {
    global wvCore, evReady, lastQuery, lastCat, lastSort, lastDrive, mainUiEntered, bootCmdSeq, bootOn, bootPct
    if !IsObject(wvCore) {
        HideLoadSplash()
        return
    }
    if mainUiEntered {
        bootOn := false
        bootPct := 100
        bootCmdSeq += 1
        ApplyBootToPage(false, 100, "", "", bootCmdSeq)
        SetTimer(FocusSearchBoxKeep, -40)
        HideLoadSplash()
        try wvCore.ExecuteScriptAsync("try{window.__onHostShow&&window.__onHostShow()}catch(e){}")
        return
    }
    SyncBootUi()
    try wvCore.ExecuteScriptAsync("try{document.body&&(document.body.offsetHeight,window.dispatchEvent(new Event('resize')))}catch(e){}")
    if evReady || EsAlive()
        SetTimer(RequestFrontendSearch, -40)
    SetTimer(FocusSearchBox, -60)
    SetTimer(HideLoadSplash, -80)
}

; 点标题栏 X / Esc / 页面关闭 → 释放 WebView2 省内存；Everything 继续跑，下次打开秒搜
; 真正退出：托盘「退出」→ ExitDashboard（才会停 Everything）
OnDashboardClose(*) {
    HideWindow()
    return true  ; 阻止默认 Destroy，改由异步 TearDown 处理
}

HideWindow() {
    global guiWin, closeEpoch, wvCore
    ; 先立刻藏窗，避免等 WMI/WebView 拆除才消失
    closeEpoch += 1
    ep := closeEpoch
    try {
        if IsObject(guiWin)
            guiWin.Hide()
    }
    ; 藏窗后再异步清空页面，减轻 WebView.Close 拆大 DOM 的卡顿
    SetTimer(LightenDashboardPage.Bind(ep), -30)
    SetTimer(TearDownDashboardUi.Bind(ep), -150)
}

LightenDashboardPage(ep := 0) {
    global wvCore, closeEpoch
    if ep && ep != closeEpoch
        return
    try {
        if IsObject(wvCore)
            wvCore.ExecuteScriptAsync("try{if(window.__lightenForClose)window.__lightenForClose();else document.body&&(document.body.innerHTML='')}catch(e){}")
    }
}

; 关闭界面并结束本窗口的 msedgewebview2（不动 Everything、不误杀剪贴板 WebView）
TearDownDashboardUi(ep := 0) {
    global guiWin, wv, wvCore, wvBuilding, uiReady, mainUiEntered, mainUiEntering
    global pageNavIssued, bootRevealDone, bootStubShown, bootOn, webMsgSub, showWhenReady, closeEpoch
    ; 用户已再次打开 → 作废这次拆除
    if ep && ep != closeEpoch
        return
    static tearing := false
    if tearing
        return
    tearing := true
    try {
        ; 轻量取消：只杀已知 pid，不做慢 WMI 全盘扫
        CancelActiveSearch("teardown", false)
        StopProcMonitor()
        HideLoadSplash()
        pids := []
        try {
            if IsObject(wvCore) {
                try {
                    bp := Integer(wvCore.BrowserProcessId)
                    if bp > 0
                        pids.Push(bp)
                }
                try {
                    infos := wvCore.Environment.GetProcessInfos()
                    if IsObject(infos) {
                        n := Integer(infos.Count)
                        loop n {
                            try {
                                info := infos.GetValueAtIndex(A_Index - 1)
                                pid := Integer(info.ProcessId)
                                if pid > 0
                                    pids.Push(pid)
                            }
                        }
                    }
                }
            }
        }
        try {
            if IsObject(wv)
                wv.Close()
        }
        wv := ""
        wvCore := ""
        webMsgSub := ""
        try {
            if IsObject(guiWin)
                guiWin.Destroy()
        }
        guiWin := ""
        uiReady := false
        mainUiEntered := false
        mainUiEntering := false
        pageNavIssued := false
        bootRevealDone := false
        bootStubShown := false
        wvBuilding := false
        bootOn := true
        ; 保留 evReady / Everything；稍后再清残留 renderer
        if pids.Length
            SetTimer(KillDashWebViewPids.Bind(UniqPids(pids)), -600)
        AppLog("TearDownDashboardUi pids=" pids.Length " evReady kept")
    } finally {
        tearing := false
    }
}

UniqPids(arr) {
    out := [], seen := Map()
    for p in arr {
        p := Integer(p)
        if p < 1 || seen.Has(p)
            continue
        seen[p] := 1
        out.Push(p)
    }
    return out
}

KillDashWebViewPids(pids, *) {
    if !IsObject(pids)
        return
    for pid in pids {
        pid := Integer(pid)
        if pid < 1 || !ProcessExist(pid)
            continue
        try {
            nm := ProcessGetName(pid)
            if !RegExMatch(String(nm), "i)^msedgewebview2\.exe$")
                continue
            ProcessClose(pid)
            AppLog("KillDashWebViewPids " pid)
        }
    }
}

; 进程监控后台采样：关窗 / 离开进程页时必须停，否则 netstat+WMI 持续耗 CPU
StopProcMonitor(*) {
    global procViewOn, portPushGen, handleSearchGen, handleSearchBusy
    procViewOn := false
    portPushGen += 1
    handleSearchGen += 1
    handleSearchBusy := false
    SetTimer(PushPortIconsBatch, 0)
    SetTimer(PushPortList, 0)
}

IsDashboardVisible() {
    global guiWin
    if !IsObject(guiWin)
        return false
    try return !!DllCall("IsWindowVisible", "Ptr", guiWin.Hwnd)
    return false
}

; 结束本机 Everything.exe（搜索后台）；不长时间阻塞，避免关窗卡顿
StopEverythingService(*) {
    AppLog("StopEverythingService")
    Loop 12 {
        if !ProcessExist("Everything.exe")
            break
        try ProcessClose("Everything.exe")
        for pid in GetEverythingPids() {
            try ProcessClose(pid)
        }
        Sleep 30
    }
}

; 先立刻藏 UI，再异步杀 Everything / ExitApp（点 X 不再卡半秒才消失）
ExitDashboard(*) {
    global guiWin
    StopProcMonitor()
    HideLoadSplash()
    try {
    if IsObject(guiWin)
        guiWin.Hide()
    }
    SetTimer(ExitDashboardFinish, -10)
}

ExitDashboardFinish(*) {
    SetTimer(ExitDashboardFinish, 0)
    try StopEverythingService()
    ExitApp
}

OnDashboardExit(ExitReason, ExitCode) {
    global skipKillEverything, dashboardHosted
    ; hosted：由快捷键4托管，杀进程不杀 Everything，避免下次打开再冷启动 20–30s
    if skipKillEverything || dashboardHosted
        return
    try StopEverythingService()
}

MinimizeWindow() {
    global guiWin
    if IsObject(guiWin)
        WinMinimize("ahk_id " guiWin.Hwnd)
}

ToggleMaximizeWindow() {
    global guiWin
    if !IsObject(guiWin)
        return
    hwnd := guiWin.Hwnd
    try {
        ; 无边框窗体用 ShowWindow 更稳；连续两次 maximize 消息曾把最大化立刻还原
        mm := WinGetMinMax("ahk_id " hwnd)
        if mm = 1 {
            DllCall("ShowWindow", "Ptr", hwnd, "Int", 9)  ; SW_RESTORE
            AppLog("ToggleMaximize restore")
        } else {
            DllCall("ShowWindow", "Ptr", hwnd, "Int", 3)  ; SW_MAXIMIZE
            AppLog("ToggleMaximize maximize")
        }
    } catch as e {
        AppLog("ToggleMaximize fail " e.Message)
    }
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
    ; 优先用脚本旁 data\local_search\index.html（开发改这里即可同步到 HELPME 运行目录）
    ship := A_ScriptDir "\data\local_search\index.html"
    if FileExist(ship) {
        try {
            f := FileOpen(ship, "r", "UTF-8")
            sample := IsObject(f) ? f.Read(1200) : ""
            if IsObject(f)
                f.Close()
            if InStr(sample, "local_search_ui:") && InStr(sample, "--ring: #e42079") {
                if ship != HTML_FILE
                    FileCopy(ship, HTML_FILE, 1)
                AppLog("EnsureEmbeddedHtml ship sync " HTML_FILE)
            return
        }
    }
    }
    ; 已有且版本匹配才跳过；旧黄圈 / 旧闪屏逻辑要强制覆盖（HELPME 数据目录常残留旧文件）
    if FileExist(HTML_FILE) {
        try {
            if FileGetSize(HTML_FILE) > 1000 {
                ; 只读文件头，避免每次 FileRead 整页卡住灰窗
                f := FileOpen(HTML_FILE, "r", "UTF-8")
                sample := IsObject(f) ? f.Read(1200) : ""
                if IsObject(f)
                    f.Close()
                if InStr(sample, "local_search_ui:") && InStr(sample, "--ring: #e42079") {
                    AppLog("EnsureEmbeddedHtml reuse " HTML_FILE)
                    return
                }
                AppLog("EnsureEmbeddedHtml stale → rewrite " HTML_FILE)
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

; ── emoji.txt 便携同步（%HELPME_HOME%\command_ext\ahk\config\emoji.txt ↔ 脚本注释 base64）──
EMOJI_CONFIG_TAG := "emoji.txt"
global emojiEmbedArmed := false

DefaultEmojiConfigText(*) {
    return "############【常用】`r`n"
        . "笑脸=😀`r`n"
        . "赞=👍`r`n"
        . "完成=✅`r`n"
}

B64EncodeFileBytes(path) {
    if !FileExist(path)
        return ""
    try {
        f := FileOpen(path, "r")
        if !IsObject(f)
            return ""
        n := f.Length
        if n < 1 {
            f.Close()
            return ""
        }
        buf := Buffer(n)
        f.RawRead(buf)
        f.Close()
        while n > 0 && NumGet(buf, n - 1, "UChar") = 0
            n -= 1
        if n < 1
            return ""
        cch := 0
        if !DllCall("crypt32\CryptBinaryToStringW", "Ptr", buf, "UInt", n, "UInt", 0x40000001, "Ptr", 0, "UInt*", &cch)
            return ""
        wbuf := Buffer(cch * 2, 0)
        if !DllCall("crypt32\CryptBinaryToStringW", "Ptr", buf, "UInt", n, "UInt", 0x40000001, "Ptr", wbuf, "UInt*", &cch)
            return ""
        return RegExReplace(StrGet(wbuf, "UTF-16"), "[\r\n\s]+")
    } catch {
        return ""
    }
}

PortableCommentMark(tag) {
    return ";########################################################################################################### " String(tag)
}

FormatEmbeddedCommentB64(tag, b64) {
    mark := PortableCommentMark(tag)
    b64 := RegExReplace(String(b64), "\s+")
    if b64 = "" || b64 = "xxxxx"
        b64 := "xxxxx"
    return mark "`n;" b64 "`n" mark
}

UpdateEmbeddedCommentB64(tag, newB64) {
    path := A_ScriptFullPath
    try content := FileRead(path, "UTF-8")
    catch as e {
        AppLog("UpdateEmbeddedCommentB64 read " e.Message)
        return
    }
    mark := PortableCommentMark(tag)
    replacement := FormatEmbeddedCommentB64(tag, newB64)
    p1 := InStr(content, mark)
    if !p1 {
        if !RegExMatch(content, "`r?`n$")
            content .= "`n"
        content .= "`n" replacement "`n"
    } else {
        p2 := InStr(content, mark, false, p1 + StrLen(mark))
        if !p2 {
            end := p1 + StrLen(mark)
            content := SubStr(content, 1, p1 - 1) . replacement . SubStr(content, end)
        } else {
            end := p2 + StrLen(mark)
            content := SubStr(content, 1, p1 - 1) . replacement . SubStr(content, end)
        }
    }
    try {
        f := FileOpen(path, "w", "UTF-8")
        f.Write(content)
        f.Close()
        AppLog("UpdateEmbeddedCommentB64 tag=" tag " b64Len=" StrLen(RegExReplace(String(newB64), "\s+")))
    } catch as e {
        AppLog("UpdateEmbeddedCommentB64 write " e.Message)
    }
}

ScheduleEmojiConfigEmbed(*) {
    global emojiEmbedArmed
    if emojiEmbedArmed
                return
    emojiEmbedArmed := true
    SetTimer(FlushEmojiConfigEmbed, -2000)
}

FlushEmojiConfigEmbed(*) {
    global emojiEmbedArmed, EMOJI_CONFIG_TAG
    emojiEmbedArmed := false
    if !HasHelpmeHome()
        return
    path := AhkConfigPath("emoji")
    if path = "" || !FileExist(path)
        return
    b64 := B64EncodeFileBytes(path)
    if b64 = ""
        return
    cur := ReadEmbeddedCommentB64(EMOJI_CONFIG_TAG)
    if b64 = cur
        return
    UpdateEmbeddedCommentB64(EMOJI_CONFIG_TAG, b64)
}

; 启动：缺文件→从脚本 base64 写出；有文件→异步回写脚本（不阻塞 UI）
SyncEmojiConfigPortable(*) {
    global EMOJI_CONFIG_TAG
    try {
        if !HasHelpmeHome() {
            AppLog("SyncEmojiConfigPortable skip (no HELPME_HOME)")
            return
        }
        dir := ResolveAhkConfigDir()
        if dir = ""
            return
        DirCreate dir
        path := AhkConfigPath("emoji")
        if path = ""
            return
        if FileExist(path) {
            ScheduleEmojiConfigEmbed()
            AppLog("SyncEmojiConfigPortable file→embed scheduled")
            return
        }
        curB64 := ReadEmbeddedCommentB64(EMOJI_CONFIG_TAG)
        if curB64 != "" && curB64 != "xxxxx" {
            ok := B64DecodeToFile(curB64, path)
            AppLog("SyncEmojiConfigPortable decode→file ok=" (ok ? 1 : 0))
            if ok
                return
        }
        ; 无嵌入时写默认模板
        f := FileOpen(path, "w", "UTF-8")
        if IsObject(f) {
            f.Write(DefaultEmojiConfigText())
            f.Close()
            ScheduleEmojiConfigEmbed()
            AppLog("SyncEmojiConfigPortable wrote default emoji.txt")
        }
    } catch as e {
        AppLog("SyncEmojiConfigPortable " e.Message)
    }
}

; 绿色仪表盘/表盘图标（托盘与窗口）
AppDashIconB64() {
    return "iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAYAAACqaXHeAAAAAXNSR0IArs4c6QAAAARnQU1BAACxjwv8YQUAAAAJcEhZcwAADsMAAA7DAcdvqGQAAASISURBVHhe7ZstUFtBEIAZXmgjkcjKysrKShwIcteqVCIRTO+lJnWVyEpkJBKZOiSykpkaZmoiqWtn7+5Bsrf7cj/7Qph538wOGXK/73b3du9ednZ6enp6enp6enp6umM6Hu5+UR+rWn0f1GruRC8Gtf63Ku67yugfg3p0unM+OsBNvRzORwcwiUGtr8KJxktV69uB0fWryae3uIvtxE5cXeKJyIia730dvcNdbgfTo32r4kY9hAMXl9lWmcee0Z9pm+5QjHqAB47HsnGqib4IBtcilVG/vLO7rIz+9ii2HTWvan2D67SLmoP24XF1z/Ro33tzYlBY7ITPXhv9BjdDMj3a91o1izEpeKgbdZIwEbeS4WAeBVR0oi8kVgce3qDW90Efq7Ko6pNDXFcet/J3xACWZRa92rG0OdmJ/wvffVHvcVU5puPhGrVfVEZ/wNUkAVWvzOg30Xcj9+IPv6HN4W3KDkHNB0b9xf2vjKXWN7BYuG4R3ikFnTnZjCf2kw9NgBR1ievnY6M7ep+Hld++yXuR8gctqr/ozN6WWDt5o/8E//N5BG4rHVh9pvOuHR6wdvKg6i7/IHemaqKOcZtJcNkcpKy4rDRRk2/KTtRx+H2hFoB64watGPXQdTKSMvmnOvo2LAcPITNAgjwcN2YbhAivQ3ImD3BawJVfCxn0wOpL77FL5E6+gQnRF7jcemzIGzQEHvcaF5WidPIAZJZhvQyHzQU+8H9cVgKJyQOw94d1M8yWO9aSdH5wvAUrY7M9gck3UJmjDdhSoOy/aEtZAlaJtlVVPHmAWbw0P8AEFjNcLhVORWlJnzzA+YEk502pZLIdYVw6TT3YJ2ly+8zJA5z/is9W+R2gxkVTiF39XaN+4ropWIdKtBu9E8CTwpVBSncAf1EStIsFVBjXTaF8/C79DRoAb42LpsCtTCijU1w3Bbez4DYTQ2Jc2TVQeA4PpkX4FizxtkoD95C4TZCkWyXaWeU7poZ1ZiCRZfpT5KDtpBiGvqBQc1wuB5tkkZqgLpO2KgZ3C43ahhwmBfIcQDARcqm2OrN7ttF1knqugVm8O1yuFS6YSHIkzwHrwBODOFgRohERG+0SzsfEb4FLMI4wTZU2DKTrwZit6WacXHOnwcUHjV3BHuBmOm82oLB3ATLOUBJ7m0yMNz+wmo6H3EFjaVQoDeezig9w+YNGfV/UsDDU+YXYQnGNd3IJmQHnq+wiSYyPVa8t2Ba5uN+JwOo38A5GuKMErJMmvX4XjrrVIQqcFiViV56ZPJz/lWaUJP6qjLwm93KVFXAk0mLzVjoN19vUznWub6OPnhKxJz1UpLcshcd2UXDxNhrItViGdz46cC9QE/2sSPl5RTQ+Pmgzh2ZQae8INiS/K1h2jpiF2x6phIkW8MzuVTddg5lYU3Graz+DZrk0nI47GFk8b26S9MaorGzqzbQonEnEa0OhLGzsIbrPC+HtNricFBF4/RZsfQNbbRnT8dA/iPBcMUNcAKbOtin5isf/Xsjf2EbsGo9y9fJ/N8Sx5PntbwXqk0P4/BwO7T+Qn6xZhSVK4QAAAABJRU5ErkJggg=="
}
AppHeartIconB64() {
    return AppDashIconB64()
}

; 同快捷键4 imageutil.Base64PNG_to_HICON
Base64PngToHIcon(Base64PNG, height := 16) {
    size := StrLen(RTrim(Base64PNG, "=")) * 3 // 4
    if DllCall("Crypt32\CryptStringToBinary", "Str", Base64PNG, "UInt", StrLen(Base64PNG), "UInt", 1
            , "Ptr", buf := Buffer(size), "UIntP", &size, "Ptr", 0, "Ptr", 0)
        return DllCall("CreateIconFromResourceEx", "Ptr", buf, "UInt", size, "UInt", true
            , "UInt", 0x30000, "Int", height, "Int", height, "UInt", 0)
    return 0
}

; 窗口/托盘用绿色仪表盘图标
SetWindowAppIcon(hwnd) {
    global hAppIconBig, hAppIconSmall
    if !hwnd
        return
    try {
        if !hAppIconBig {
            b64 := AppDashIconB64()
            hAppIconBig := Base64PngToHIcon(b64, 32)
            hAppIconSmall := Base64PngToHIcon(b64, 16)
            if !hAppIconSmall
                hAppIconSmall := hAppIconBig
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
    global evReady, mainUiEntered
    try {
        ; 主界面已提前揭开时不再挡绿圈；仅后台拉 Everything
        if !mainUiEntered
            PushBoot(true, 5, "检查组件", "正在检查 Everything / ES 是否就绪…")
        if !EnsureEverythingFiles() {
            if !mainUiEntered
                PushBoot(true, 8, "组件缺失", "Everything/ES 下载失败，请检查网络后重试。`n将下载到脚本旁 lib\everything\")
            TrayTip "本地搜索", "Everything/ES 组件缺失或下载失败，请检查网络后重试", "Iconx"
            AppLog("EnsureEverythingReady: components missing")
            return
        }
        if !mainUiEntered
            PushBoot(true, 28, "启动服务", "正在启动 Everything…")
        HideEverythingTrayIcon()
        StartEverythingService()
        HideEverythingTrayIcon()
        if !mainUiEntered
            PushBoot(true, 42, "磁盘索引中", "正在建立磁盘文件索引，完成后即可搜索。")
        else
            PushIndexPendingHint()
        ; 主界面已开：短探 IPC，不通则交给 PollIndexProgress（不堵 12 秒）
        readyNow := false
        if mainUiEntered
            readyNow := EsAlive() || WaitEsIpc(800)
        else
            readyNow := WaitEverythingIndexed(12)
            if readyNow {
            evReady := true
            EnterMainUi()
            if ReadLastUiMode() = "file"
                SetTimer(RequestFrontendSearch, -80)
        } else {
            SetTimer(PollIndexProgress, 400)
        }
    } catch as e {
        global bootPct
        AppLog("EnsureEverythingReady " e.Message)
        if !mainUiEntered
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

; 旁路超大 Everything.db：加载 70MB+ 库常卡 20–40s 才 IPC；无库时走 NTFS 约 3–5s（与 GoLand 目录行为一致）
PreferFastEverythingColdStart(*) {
    global EV_DIR, EV_EXE
    SplitPath EV_EXE, , &wd
    if wd = ""
        wd := EV_DIR
    db := wd "\Everything.db"
    if !FileExist(db)
        return
    try {
        sz := FileGetSize(db)
        ; 小库可保留；大库冷启代价远高于重建 USN
        if sz < 8 * 1024 * 1024
            return
        bak := db ".coldbak"
        try FileDelete bak
        FileMove db, bak, 1
        AppLog("Everything.db shelved size=" sz " → coldbak (fast NTFS start)")
    } catch as e {
        AppLog("PreferFastEverythingColdStart " e.Message)
    }
}

StartEverythingService() {
    global EV_EXE, EV_DIR
    SplitPath EV_EXE, , &wd
    HideEverythingTrayIcon()
    if RepairEverythingIpc()
        return
    PreferFastEverythingColdStart()
    ; 无可用实例 → 启动一个（不要先杀再等，直接 -startup）
    try Run(Format('"{1}" -startup', EV_EXE), wd, "Hide")
    catch as e {
        AppLog("StartEverything " e.Message)
        try Run(EV_EXE, wd)
    }
    WaitEsIpc(4000)
    HideEverythingTrayIcon()
    AppLog("Everything started tray=off alive=" EsAlive())
}

; 已有实例且 IPC 通 → 直接复用（索引未完成时 hits=0 也不要误杀重拉）
RepairEverythingIpc(*) {
    global EV_EXE
    SplitPath EV_EXE, , &wd
    if !ProcessExist("Everything.exe")
        return false
    if EsAlive() {
        AppLog("Everything IPC ok reuse")
        return true
    }
    ; 刚启动时 IPC 可能稍慢，短等一下
    if WaitEsIpc(2000) {
        AppLog("Everything IPC ok after wait")
        return true
    }
    AppLog("Everything IPC broken → hard restart")
    Loop 15 {
        if !ProcessExist("Everything.exe")
            break
        try ProcessClose("Everything.exe")
        Sleep 40
    }
    HideEverythingTrayIcon()
    PreferFastEverythingColdStart()
    try Run(Format('"{1}" -startup', EV_EXE), wd, "Hide")
    catch as e {
        AppLog("Repair start fail " e.Message)
        return false
    }
    ok := WaitEsIpc(4000)
    HideEverythingTrayIcon()
    AppLog("Everything repaired alive=" ok)
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
        if ProcessExist("Everything.exe") && EsAlive()
            return true
        Sleep 80
    }
    return ProcessExist("Everything.exe") && EsAlive()
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
    ; 已在跑且 IPC 通 → 立刻返回（点 X 再开时最常见）
    if ProcessExist("Everything.exe") && EsAlive() {
        PushBoot(true, 82, "即将完成", "索引已就绪…")
        return true
    }
    while (A_TickCount - t0) < maxSec * 1000 {
        if ProcessExist("Everything.exe") && EsAlive() {
            PushBoot(true, 82, "即将完成", "索引已就绪…")
            return true
        }
        pct := Min(88, pct + 4)
        PushBoot(true, pct, "磁盘索引中", "正在建立磁盘文件索引，完成后即可搜索。<br>若本机已安装 Everything 并开机启动，下次会更快就绪。")
        Sleep 100
    }
    return ProcessExist("Everything.exe") && EsAlive()
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
    global evReady, mainUiEntered
    static ticks := 0
    ticks += 1
    if EsAlive() {
        evReady := true
        SetTimer(PollIndexProgress, 0)
        EnterMainUi()
        SetTimer(RequestFrontendSearch, -100)
        return
    }
    ; 主界面已开：只刷新列表提示，不再挡绿圈
    if mainUiEntered {
        if Mod(ticks, 5) = 1
            PushIndexPendingHint()
        return
    }
    PushBoot(true, Min(95, 40 + ticks), "磁盘索引中", "索引仍在建立，请稍候…")
}

; 文件搜索区提示：Everything 仍在冷启动（不挡整页）
RequestFrontendSearch(*) {
    global wvCore
    if !IsObject(wvCore)
        return
    js := "try{window.__resyncSearch&&window.__resyncSearch()}catch(e){}"
    try wvCore.ExecuteScriptAsync(js)
}

; 文件搜索区提示：Everything 仍在冷启动（不挡整页）
PushIndexPendingHint(*) {
    global wvCore, evReady, mainUiEntered
    if !mainUiEntered || evReady || !IsObject(wvCore)
        return
    if EsAlive()
        return
    js := "try{var e=document.getElementById('list-empty');if(e){e.textContent='磁盘索引加载中，完成后自动显示结果…';e.classList.add('on')}}catch(x){}"
    try wvCore.ExecuteScriptAsync(js)
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
        default:       return "/a-d"  ; 「全部」等：只要文件，不要目录（含 path 标签根目录自身）
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
    ; Space = AND. Keep regex:… / content:… / "quoted" as one token.
    qSafe := String(qTrim)
    terms := []
    i := 1
    len := StrLen(qSafe)
    while i <= len {
        while i <= len && SubStr(qSafe, i, 1) = " "
            i += 1
        if i > len
            break
        if SubStr(qSafe, i, 6) = "regex:" {
            j := i + 6
            while j <= len && SubStr(qSafe, j, 1) != " "
                j += 1
            terms.Push(SubStr(qSafe, i, j - i))
            i := j
            continue
        }
        if SubStr(qSafe, i, 8) = "content:" {
            j := i + 8
            if j <= len && SubStr(qSafe, j, 1) = '"' {
                j += 1
                while j <= len && SubStr(qSafe, j, 1) != '"'
                    j += 1
                if j <= len
                    j += 1
            } else {
                while j <= len && SubStr(qSafe, j, 1) != " "
                    j += 1
            }
            terms.Push(SubStr(qSafe, i, j - i))
            i := j
            continue
        }
        if SubStr(qSafe, i, 5) = "path:" {
            j := i + 5
            if j <= len && SubStr(qSafe, j, 1) = '"' {
                j += 1
                while j <= len && SubStr(qSafe, j, 1) != '"'
                    j += 1
                if j <= len
                    j += 1
            } else {
                while j <= len && SubStr(qSafe, j, 1) != " "
                    j += 1
            }
            terms.Push(SubStr(qSafe, i, j - i))
            i := j
            continue
        }
        if SubStr(qSafe, i, 7) = "parent:" {
            j := i + 7
            if j <= len && SubStr(qSafe, j, 1) = '"' {
                j += 1
                while j <= len && SubStr(qSafe, j, 1) != '"'
                    j += 1
                if j <= len
                    j += 1
            } else {
                while j <= len && SubStr(qSafe, j, 1) != " "
                    j += 1
            }
            terms.Push(SubStr(qSafe, i, j - i))
            i := j
            continue
        }
        if SubStr(qSafe, i, 1) = '"' {
            j := i + 1
            while j <= len && SubStr(qSafe, j, 1) != '"'
                j += 1
            if j <= len
                j += 1
            terms.Push(SubStr(qSafe, i, j - i))
            i := j
            continue
        }
        j := i
        while j <= len && SubStr(qSafe, j, 1) != " "
            j += 1
        terms.Push(SubStr(qSafe, i, j - i))
        i := j
    }
    for term in terms {
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

; 立刻终止当前/排队中的文件搜索（切模式、关窗、清空、取消等）
; sweepOrphans=true 时扫 WMI 清残留（较慢）；关窗路径请传 false
CancelActiveSearch(reason := "", sweepOrphans := true) {
    global pendingSearch, searchBusy, esSearchPid, searchSeq, searchCancelEpoch, ES_EXE
    global rgSearchPid, pendingRgSearch, RG_EXE
    searchCancelEpoch += 1
    searchSeq += 1
    pendingSearch := ""
    pendingRgSearch := ""
    try SetTimer(FlushPendingSearch, 0)
    try SetTimer(FlushPendingRgSearch, 0)
    try SetTimer(SearchBusyWatchdog, 0)
    try SetTimer(SearchBusyForceUnlock, 0)
    try SetTimer(SearchBusySoftClear, 0)
    if esSearchPid {
        if ProcessExist(esSearchPid)
            try ProcessClose(esSearchPid)
        esSearchPid := 0
    }
    if rgSearchPid {
        if ProcessExist(rgSearchPid)
            try ProcessClose(rgSearchPid)
        rgSearchPid := 0
    }
    ; 顺带清掉本目录残留 es/rg（WMI 慢，关窗时跳过）
    if sweepOrphans {
        try {
            esWant := StrLower(String(ES_EXE))
            rgWant := StrLower(String(RG_EXE))
            for proc in ComObjGet("winmgmts:").ExecQuery("Select ProcessId,ExecutablePath from Win32_Process where Name='es.exe' or Name='rg.exe'") {
                try {
                    p := StrLower(String(proc.ExecutablePath))
                    if p = ""
                        continue
                    if (esWant != "" && p = esWant) || InStr(p, "\ahk_ext\lib\everything\") || InStr(p, "\lib\everything\es.exe")
                        try ProcessClose(Integer(proc.ProcessId))
                    if (rgWant != "" && p = rgWant) || InStr(p, "\ahk_ext\lib\ripgrep\") || InStr(p, "\lib\ripgrep\rg.exe")
                        try ProcessClose(Integer(proc.ProcessId))
                }
            }
        }
    }
    ; 勿用 ForceUnlock（会抬 epoch 误杀紧接着的新搜索 → 前端卡「搜索中…」）
    ; SoftClear 仅在无在跑 es/rg、且不在 RunSearchNow 栈内时清 busy
    SetTimer(SearchBusySoftClear, -350)
    AppLog("CancelActiveSearch " reason " epoch=" searchCancelEpoch " sweep=" (sweepOrphans ? 1 : 0))
}

; ── ripgrep（按需下载，仅切到「搜索文本」时触发）────────────────────
ResolveRgExe() {
    global RG_DIR, RG_EXE
    if FileExist(RG_EXE)
        return RG_EXE
    if !DirExist(RG_DIR)
        return ""
    loop files RG_DIR "\rg.exe", "FR" {
        RG_EXE := A_LoopFileFullPath
        return RG_EXE
    }
    return ""
}

EmitRgReady(ok, err := "") {
    global wvCore
    if !IsObject(wvCore)
        return
    flag := ok ? "true" : "false"
    js := "try{window.__rgReady&&window.__rgReady(" flag "," JStr(String(err)) ")}catch(e){}"
    try wvCore.ExecuteScriptAsync(js)
}

; 主界面已进入后仍可显示圆圈（仅用于按需下载 rg）
PushToolDownloadBoot(on, pct, title := "", hint := "") {
    global wvCore, bootCmdSeq
    if !IsObject(wvCore)
        return
    pct := Max(0, Min(100, Integer(pct)))
    bootCmdSeq += 1
    ApplyBootToPage(!!on, pct, title, hint, bootCmdSeq)
}

DownloadFileToolProgress(url, dest, title := "下载组件") {
    try {
        if FileExist(dest)
            FileDelete dest
        SplitPath dest, , &destDir
        if destDir != ""
            DirCreate destDir
        tmp := dest ".part"
        try FileDelete tmp
        curl := A_WinDir "\System32\curl.exe"
        if FileExist(curl) {
            cmd := Format('"{1}" -L --retry 3 --connect-timeout 20 -o "{2}" "{3}"', curl, tmp, url)
            pid := 0
            Run(cmd, , "Hide", &pid)
            t0 := A_TickCount
            lastTip := 0
            while pid && ProcessExist(pid) {
                Sleep 200
                if (A_TickCount - lastTip) > 600 {
                    lastTip := A_TickCount
                    try {
                        sz := FileExist(tmp) ? FileGetSize(tmp) : 0
                        if sz > 0
                            PushToolDownloadBoot(true, Min(70, 12 + Integer(sz / 40000)), title, "正在下载… " Round(sz / 1024) " KB")
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
        return DownloadFile(url, dest)
    } catch as e {
        AppLog("DownloadFileToolProgress " e.Message)
        return false
    }
}

EnsureRipgrepReady(*) {
    global RG_DIR, RG_EXE, RG_ZIP, RG_URL
    try {
        if ResolveRgExe() != "" {
            PushToolDownloadBoot(false, 100)
            EmitRgReady(true)
            return
        }
        DirCreate RG_DIR
        PushToolDownloadBoot(true, 8, "下载 ripgrep", "正在下载专业文本搜索组件（首次需要）…")
        ok := false
        if FileExist(RG_ZIP) && FileGetSize(RG_ZIP) > 1000
            ok := true
        else
            ok := DownloadFileToolProgress(RG_URL, RG_ZIP, "下载 ripgrep")
        if !ok {
            PushToolDownloadBoot(false, 100)
            EmitRgReady(false, "ripgrep 下载失败，请检查网络后重试")
            return
        }
        PushToolDownloadBoot(true, 78, "解压 ripgrep", "正在解压文本搜索组件…")
        if !UnzipTo(RG_ZIP, RG_DIR) {
            PushToolDownloadBoot(false, 100)
            EmitRgReady(false, "ripgrep 解压失败")
            return
        }
        if ResolveRgExe() = "" {
            PushToolDownloadBoot(false, 100)
            EmitRgReady(false, "未找到 rg.exe")
            return
        }
        PushToolDownloadBoot(true, 96, "即将完成", "文本搜索组件已就绪…")
        Sleep 200
        PushToolDownloadBoot(false, 100)
        EmitRgReady(true)
        AppLog("EnsureRipgrepReady ok " RG_EXE)
    } catch as e {
        AppLog("EnsureRipgrepReady " e.Message)
        try PushToolDownloadBoot(false, 100)
        EmitRgReady(false, e.Message)
    }
}

ScheduleRgSearch(rawJson) {
    global pendingRgSearch, pendingSearch, searchBusy, searchSeq, searchCancelEpoch, esSearchPid, rgSearchPid
    searchSeq += 1
    pendingRgSearch := { raw: String(rawJson), seq: searchSeq }
    pendingSearch := ""
    ; 打断旧 es/rg
    searchCancelEpoch += 1
    if esSearchPid && ProcessExist(esSearchPid) {
        try ProcessClose(esSearchPid)
        esSearchPid := 0
    }
    if rgSearchPid && ProcessExist(rgSearchPid) {
        try ProcessClose(rgSearchPid)
        rgSearchPid := 0
    }
    if !searchBusy
        SetTimer(FlushPendingRgSearch, -20)
    ; busy 时靠 epoch 打断旧任务后 Flush 会接力；勿挂短看门狗误杀新 rg
}

FlushPendingRgSearch(*) {
    global pendingRgSearch, pendingSearch, searchBusy, searchRunDepth
    if searchBusy
        return
    if !IsObject(pendingRgSearch)
        return
    searchBusy := true
    searchRunDepth := Integer(searchRunDepth) + 1
    p := pendingRgSearch
    pendingRgSearch := ""
    try {
        RunRgSearchNow(p.raw, p.seq)
    } catch as e {
        AppLog("FlushPendingRgSearch err " e.Message)
        try PushResults([], 0, 0, false, 50, "文本搜索失败: " e.Message)
    }
    searchRunDepth := Max(0, Integer(searchRunDepth) - 1)
    searchBusy := false
    if IsObject(pendingRgSearch)
        SetTimer(FlushPendingRgSearch, -20)
    else if IsObject(pendingSearch)
        SetTimer(FlushPendingSearch, -20)
}

JsonArrGet(raw, key) {
    ; 粗解析 "key":[ ... ] 字符串数组
    out := []
    pat := '"' key '"\s*:\s*\[([^\]]*)\]'
    if !RegExMatch(String(raw), pat, &m)
        return out
    body := m[1]
    pos := 1
    while RegExMatch(body, '"((?:\\.|[^"\\])*)"', &sm, pos) {
        out.Push(UnescapeJson(sm[1]))
        pos := sm.Pos + sm.Len
    }
    return out
}

JsonStrGet(raw, key, def := "") {
    if RegExMatch(String(raw), '"' key '"\s*:\s*"((?:\\.|[^"\\])*)"', &m)
        return UnescapeJson(m[1])
    return def
}

JsonBoolGet(raw, key, def := false) {
    if RegExMatch(String(raw), '"' key '"\s*:\s*(true|false)', &m)
        return m[1] = "true"
    return !!def
}

JsonIntGet(raw, key, def := 0) {
    if RegExMatch(String(raw), '"' key '"\s*:\s*(-?\d+)', &m)
        return Integer(m[1])
    return Integer(def)
}

CatToRgGlobs(cat) {
    ; 用花括号合并，缩短命令行；通配必须带引号（见 RunRgSearchNow）
    textables := ["*.{txt,md,markdown,log,ini,cfg,conf,json,xml,yml,yaml,toml,csv,tsv,html,htm,css,scss,less,js,jsx,ts,tsx,vue,go,py,java,c,h,cpp,hpp,cc,cs,rs,rb,php,sql,sh,bash,bat,cmd,ps1,ahk,lua,swift,kt,proto,env,srt,vtt,tex,svg,rtf,properties,gradle,cmake,dockerfile,editorconfig}"]
    switch StrLower(Trim(String(cat))) {
        case "excel":  return ["*.{xls,xlsx,xlsm,csv}"]
        case "word":   return ["*.{doc,docx,rtf}"]
        case "ppt":    return ["*.{ppt,pptx}"]
        case "pdf":    return ["*.pdf"]
        case "image":  return []
        case "video":  return []
        case "audio":  return []
        case "zip":    return []
        case "folder": return []
        default:       return textables
    }
}

RunRgSearchNow(rawJson, seq) {
    global RG_EXE, searchCancelEpoch, rgSearchPid, pendingRgSearch, pendingSearch
    seq := Integer(seq)
    epochAtStart := Integer(searchCancelEpoch)
    if ResolveRgExe() = "" {
        PushResults([], 0, 0, false, 50, "ripgrep 未就绪，请重新开启「搜索文本」")
        return
    }
    q := Trim(JsonStrGet(rawJson, "q"))
    if q = "" {
        PushResults([], 0, 0, false, 50, "请输入要搜索的文本内容")
        return
    }
    recursive := JsonBoolGet(rawJson, "recursive", true)
    drive := Trim(JsonStrGet(rawJson, "drive"))
    cat := JsonStrGet(rawJson, "cat", "all")
    sort := JsonStrGet(rawJson, "sort", "date-desc")
    offset := Max(0, JsonIntGet(rawJson, "offset", 0))
    paths := JsonArrGet(rawJson, "paths")
    regexes := JsonArrGet(rawJson, "regexes")
    if paths.Length = 0 {
        letter := RegExReplace(drive, "[^A-Za-z]", "")
        if letter != ""
            paths.Push(StrUpper(letter) ":\")
    }
    if paths.Length = 0 {
        PushResults([], 0, 0, false, 50, "请先选择盘符或启用目录标签")
        return
    }
    if Integer(searchCancelEpoch) != epochAtStart
        return

    outFile := A_Temp "\rg_out_" A_TickCount "_" seq ".txt"
    try FileDelete outFile
    ; 不用脆弱的 cmd /c 拼接：必须 ""exe" args > "out"" 形式，且 glob 必须加引号
    ; 否则 CreateProcess 吃掉引号 / 通配被 shell 展开 → 空输出被当成 0 条
    args := "-l -i -F --no-messages --color never"
    if !recursive
        args .= " --max-depth 1"
    for g in CatToRgGlobs(cat) {
        if g != ""
            args .= ' -g "' g '"'
    }
    ; | = AND → 多段都要匹配：用多次 -e 不够（OR）；改成对 AND 逐段过滤较重。
    ; 简化：整段当字面量；用户可用空格。|| 取第一段或。
    pattern := q
    if InStr(q, "||") {
        parts := StrSplit(q, "||")
        pattern := Trim(parts[1])
    } else if InStr(q, "|") {
        ; AND：取第一段给 rg，其余在结果里再筛（文件内容二次确认成本高）→ 用空格连接作近似
        andParts := []
        for p in StrSplit(q, "|") {
            p := Trim(p)
            if p != ""
                andParts.Push(p)
        }
        if andParts.Length
            pattern := andParts[1]
    }
    if pattern = "" {
        PushResults([], 0, 0, false, 50, "请输入要搜索的文本内容")
        return
    }
    args .= " -e " QuoteArg(pattern)
    pathN := 0
    for p in paths {
        p := Trim(p)
        if p = ""
            continue
        if !DirExist(p) && !FileExist(p)
            continue
        args .= " " QuoteArg(p)
        pathN += 1
    }
    if pathN = 0 {
        PushResults([], 0, 0, false, 50, "请先选择盘符或启用目录标签")
        return
    }
    ; cmd.exe /c ""C:\path\rg.exe" -l ... > "out" 2>nul"
    fullCmd := Format('"{1}" /c ""{2}" {3} > "{4}" 2>nul"', A_ComSpec, RG_EXE, args, outFile)
    AppLog("RG cmd seq=" seq " " fullCmd)
    pid := 0
    try Run(fullCmd, , "Hide", &pid)
    catch as e {
        AppLog("RG run fail " e.Message)
        PushResults([], 0, offset, offset > 0, 50, "文本搜索启动失败")
        return
    }
    rgSearchPid := pid
    deadline := A_TickCount + 45000
    aborted := false
    while pid && ProcessExist(pid) {
        if Integer(searchCancelEpoch) != epochAtStart {
            try ProcessClose(pid)
            aborted := true
            break
        }
        if IsObject(pendingRgSearch) && Integer(pendingRgSearch.seq) > seq {
            try ProcessClose(pid)
            aborted := true
            break
        }
        if IsObject(pendingSearch) {
            try ProcessClose(pid)
            aborted := true
            break
        }
        if A_TickCount >= deadline {
            try ProcessClose(pid)
            aborted := true
            PushResults([], 0, offset, false, 50, "文本搜索超时，请缩小目录范围后重试")
            break
        }
        Sleep 50
    }
    if rgSearchPid = pid
        rgSearchPid := 0
    if aborted || Integer(searchCancelEpoch) != epochAtStart {
        try FileDelete outFile
        return
    }

    files := []
    if FileExist(outFile) {
        try txt := FileRead(outFile, "UTF-8")
        catch {
            try txt := FileRead(outFile, "CP0")
            catch
                txt := ""
        }
        for line in StrSplit(txt, "`n", "`r") {
            line := Trim(line)
            if line = "" || SubStr(line, 1, 1) = "{"
                continue
            ; 名称正则过滤
            SplitPath line, &name
            okName := true
            for re in regexes {
                re := Trim(re)
                if re = ""
                    continue
                try {
                    if !RegExMatch(name, re)
                        okName := false
                } catch {
                    ; Everything 风格 \x{4e00} 在 AHK 可能不同，失败则不过滤该项
                }
                if !okName
                    break
            }
            if okName
                files.Push(line)
        }
    }
    try FileDelete outFile

    ; 排序
    try {
        switch StrLower(sort) {
            case "name-asc":
                files := SortPathsByName(files, false)
            case "size-desc":
                files := SortPathsBySize(files, true)
            case "date-asc":
                files := SortPathsByMtime(files, false)
            default:
                files := SortPathsByMtime(files, true)
        }
    }

    total := files.Length
    pageSize := 50
    items := []
    i := offset + 1
    while i <= files.Length && items.Length < pageSize {
        full := files[i]
        SplitPath full, &name
        isDir := DirExist(full) ? true : false
        mtime := ""
        size := ""
        try {
            mtime := FormatTime(FileGetTime(full, "M"), "yyyy-MM-dd HH:mm")
            if !isDir
                size := FileGetSize(full)
        }
        items.Push({
            name: name,
            path: full,
            size: size,
            mtime: mtime,
            isDir: isDir
        })
        i += 1
    }
    AppLog("RG done seq=" seq " total=" total " page=" items.Length " offset=" offset)
    note := ""
    if total = 0 && offset = 0
        note := "内容中未找到。可关掉顶部路径标签扩大范围；搜文件名请关闭「搜索文本」。"
    PushResults(items, total, offset, offset > 0, pageSize, note)
}

QuoteArg(s) {
    s := String(s)
    if s = ""
        return '""'
    ; * ? 也要加引号，否则 cmd 会按当前目录展开通配
    if RegExMatch(s, '[ \t&|()<>^"*?\[\]]')
        return '"' StrReplace(s, '"', '\"') '"'
    return s
}

SortPathsByMtime(arr, desc := true) {
    ; 简单插入：带时间戳
    scored := []
    for p in arr {
        t := 0
        try t := Integer(FileGetTime(p, "M"))
        scored.Push({ p: p, t: t })
    }
    n := scored.Length
    loop n - 1 {
        i := A_Index
        loop n - i {
            j := A_Index
            a := scored[j], b := scored[j + 1]
            swap := desc ? (a.t < b.t) : (a.t > b.t)
            if swap {
                scored[j] := b
                scored[j + 1] := a
            }
        }
    }
    out := []
    for x in scored
        out.Push(x.p)
    return out
}

SortPathsByName(arr, desc := false) {
    ; 用 Sort 命令对路径名
    blob := ""
    for p in arr
        blob .= p "`n"
    blob := Sort(blob, desc ? "R" : "")
    out := []
    for line in StrSplit(blob, "`n", "`r") {
        if Trim(line) != ""
            out.Push(line)
    }
    return out
}

SortPathsBySize(arr, desc := true) {
    scored := []
    for p in arr {
        sz := 0
        try sz := Integer(FileGetSize(p))
        scored.Push({ p: p, t: sz })
    }
    n := scored.Length
    loop n - 1 {
        i := A_Index
        loop n - i {
            j := A_Index
            a := scored[j], b := scored[j + 1]
            swap := desc ? (a.t < b.t) : (a.t > b.t)
            if swap {
                scored[j] := b
                scored[j + 1] := a
            }
        }
    }
    out := []
    for x in scored
        out.Push(x.p)
    return out
}

; content: 无内容索引时会拖死 es/Everything；必须可超时取消，否则搜索队列卡死
RunEsTimed(cmd, timeoutMs := 30000, seq := 0) {
    global esSearchPid, pendingSearch, searchCancelEpoch
    epochAtStart := Integer(searchCancelEpoch)
    if esSearchPid && ProcessExist(esSearchPid) {
        try ProcessClose(esSearchPid)
        esSearchPid := 0
    }
    pid := 0
    try Run(cmd, , "Hide", &pid)
    catch as e {
        AppLog("ES run fail " e.Message)
        return { ok: false, timedOut: false, aborted: false }
    }
    if !pid {
        return { ok: false, timedOut: false, aborted: false }
    }
    esSearchPid := pid
    deadline := A_TickCount + Max(800, Integer(timeoutMs))
    timedOut := false
    aborted := false
    while ProcessExist(pid) {
        if Integer(searchCancelEpoch) != epochAtStart {
            AppLog("ES abort cancel epoch seq=" seq)
            try ProcessClose(pid)
            aborted := true
            break
        }
        if IsObject(pendingSearch) && Integer(pendingSearch.seq) > Integer(seq) {
            AppLog("ES abort superseded seq=" seq " by=" pendingSearch.seq)
            try ProcessClose(pid)
            aborted := true
            break
        }
        if A_TickCount >= deadline {
            timedOut := true
            AppLog("ES timeout seq=" seq " ms=" timeoutMs)
            try ProcessClose(pid)
            break
        }
        Sleep 40
    }
    if esSearchPid = pid
        esSearchPid := 0
    return { ok: !timedOut && !aborted, timedOut: timedOut, aborted: aborted }
}

RunSearchNow(q, cat, sort, seq, offset := 0, drive := "") {
    global ES_EXE, evReady, wvCore, searchCancelEpoch
    q := String(q)
    cat := String(cat)
    sort := String(sort)
    drive := String(drive)
    seq := Integer(seq)
    offset := Max(0, Integer(offset))
    epochAtStart := Integer(searchCancelEpoch)

    if !FileExist(ES_EXE) {
        AppLog("ES missing: " ES_EXE)
        return
    }
    if !evReady && !EsAlive() {
        AppLog("ES not ready — skip push")
        PushIndexPendingHint()
        return
    }
    evReady := true
    if Integer(searchCancelEpoch) != epochAtStart
        return

    filter := CatToFilter(cat)
    qTrim := NormalizeSearchQuery(Trim(q))
    sortArgs := SortFlags(sort)
    ; Page size for infinite scroll (not a hard cap — scroll keeps loading)
    limit := 50
    outFile := A_Temp "\es_out_" A_TickCount "_" seq ".txt"
    isContent := InStr(qTrim, "content:") > 0
    ; 内容搜索给足时间；普通搜索也限时，避免永久「搜索中」
    timeoutMs := isContent ? 25000 : 30000

    ; Always use viewport-* so offset pagination works ( -n + -viewport-offset returns 0 )
    cmd := Format('"{1}" -viewport-count {2} -viewport-offset {3} -no-result-error {4} -export-txt "{5}"',
        ES_EXE, limit, offset, sortArgs, outFile)
    AppendEsQuery(&cmd, filter, qTrim, drive)

    AppLog("ES cmd seq=" seq " " cmd)
    runRes := RunEsTimed(cmd, timeoutMs, seq)
    if Integer(searchCancelEpoch) != epochAtStart || runRes.aborted {
        try FileDelete outFile
        return
    }
    if runRes.timedOut {
        try FileDelete outFile
        note := isContent
            ? "内容搜索超时。请先选盘符/目录标签缩小范围，或在 Everything 中开启内容索引。"
            : "搜索超时，请缩小范围后重试。"
        PushResults([], 0, offset, false, limit, note)
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
    if Integer(searchCancelEpoch) != epochAtStart {
        try FileDelete outFile
        return
    }

    items := ParseEsTxt(outFile)
    try FileDelete outFile

    total := items.Length + offset
    ; 首屏取真实总数，否则滚动会在「假总数」处提前停住（例如只剩 60）
    if offset = 0 {
        try {
            cntFile := A_Temp "\es_cnt_" A_TickCount "_" seq ".txt"
            try FileDelete cntFile
            cntTail := " -get-result-count -no-result-error"
            AppendEsQuery(&cntTail, filter, qTrim, drive)
            ; 用隐藏 cmd 写文件取数。| 必须 ^|，否则被当成管道；勿用 WScript.Exec（控制台会闪黑框）
            cntTailEsc := StrReplace(StrReplace(cntTail, "^", "^^"), "|", "^|")
            fullCnt := Format('"{1}" /c ""{2}"{3} > "{4}" 2>nul"', A_ComSpec, ES_EXE, cntTailEsc, cntFile)
            cntRes := RunEsTimed(fullCnt, isContent ? 12000 : 15000, seq)
            if Integer(searchCancelEpoch) != epochAtStart {
                try FileDelete cntFile
                return
            }
            if cntRes.ok && FileExist(cntFile) {
                raw := Trim(FileRead(cntFile, "UTF-8"))
                if raw = "" {
                    try raw := Trim(FileRead(cntFile, "CP0"))
                }
                if RegExMatch(raw, "\d+", &m)
                    total := Integer(m[0])
                else if items.Length >= limit
                    total := -1
            } else if items.Length >= limit {
                total := -1
            }
                try FileDelete cntFile
        }
    } else {
        total := -1  ; UI keeps previous totalHits
    }
    if Integer(searchCancelEpoch) != epochAtStart
        return
    AppLog("ES done seq=" seq " offset=" offset " items=" items.Length " total=" total " cat=" cat " drive=" drive " q=" qTrim)
    note := ""
    if isContent && items.Length = 0 && offset = 0
        note := "无内容命中。未开启内容索引时结果常为空；可改用盘符/目录标签缩小范围。"
    PushResults(items, total, offset, offset > 0, limit, note)
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
        ; 列表解析：用 ES 尾部 \ 判断文件夹，避免每条 FileExist 卡顿
        isDir := (SubStr(full, -1) = "\")
        items.Push({
            name: name,
            path: fullTrim,
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

PushResults(items, total, offset := 0, append := false, pageSize := 50, note := "") {
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
        . ',"pageSize":' Integer(pageSize)
        . ',"note":' JStr(String(note))
        . ',"items":' arr "}"
    js := "try{window.__updateResults&&window.__updateResults(" payload ")}catch(e){console.error('updateResults',e)}"
    try {
        wvCore.ExecuteScriptAsync(js)
        AppLog("PushResults n=" items.Length " total=" total " offset=" offset " append=" append " bytes=" StrLen(payload))
    } catch as e {
        AppLog("PushResults fail " e.Message)
    }
}

; ── 进程监控 ─────────────────────────────────────────────────────────
global procShowSysWanted := false

PushProcessList(*) {
    global wvCore, procShowSysWanted, procSampleMap, procCpuCores, procIconCache
    if !IsObject(wvCore)
        return
    showSys := !!procShowSysWanted
    now := A_TickCount
    items := []
    try {
        for proc in ComObjGet("winmgmts:").ExecQuery("SELECT Name,ProcessId,WorkingSetSize,ExecutablePath FROM Win32_Process") {
            try {
                name := String(proc.Name)
                pid := Integer(proc.ProcessId)
                if name = "" || pid <= 0
                    continue
                path := ""
                try path := String(proc.ExecutablePath)
                mem := 0
                try mem := Integer(proc.WorkingSetSize)
                isSys := IsSystemProcess(name, path, pid)
                if !showSys && isSys
                    continue
                cpuTxt := "0%", readTxt := "0 K/S", writeTxt := "0 K/S"
                cpuNow := 0, readNow := 0, writeNow := 0
                GetProcessCpu100ns(pid, &cpuNow)
                GetProcessIoBytes(pid, &readNow, &writeNow)
                if procSampleMap.Has(pid) {
                    prev := procSampleMap[pid]
                    dt := Max(1, now - Integer(prev.t))
                    dCpu := Max(0, cpuNow - Integer(prev.cpu))
                    avail := dt * 10000.0 * procCpuCores
                    pct := avail > 0 ? Min(100.0, dCpu / avail * 100.0) : 0.0
                    cpuTxt := FormatCpuPct(pct)
                    dR := Max(0, readNow - Integer(prev.read))
                    dW := Max(0, writeNow - Integer(prev.write))
                    readTxt := FormatByteRate(dR * 1000 / dt)
                    writeTxt := FormatByteRate(dW * 1000 / dt)
                }
                procSampleMap[pid] := { t: now, cpu: cpuNow, read: readNow, write: writeNow }
                ico := ""
                if path != "" {
                    if procIconCache.Has(path)
                        ico := procIconCache[path]
                    else if FileExist(path) {
                        ico := ShellIconUrl(path, false)
                        procIconCache[path] := ico
                    }
                }
                items.Push({
                    name: name,
                    pid: pid,
                    path: path,
                    mem: FormatMemSize(mem),
                    cpu: cpuTxt,
                    read: readTxt,
                    write: writeTxt,
                    icon: ico,
                    sys: isSys
                })
            }
        }
    } catch as e {
        AppLog("PushProcessList " e.Message)
    }
    try items := SortProcByMem(items)
    arr := "["
    first := true
    for it in items {
        if !first
            arr .= ","
        first := false
        arr .= "{"
        arr .= '"name":' JStr(it.name) ","
        arr .= '"pid":' Integer(it.pid) ","
        arr .= '"path":' JStr(it.path) ","
        arr .= '"mem":' JStr(it.mem) ","
        arr .= '"cpu":' JStr(it.cpu) ","
        arr .= '"read":' JStr(it.read) ","
        arr .= '"write":' JStr(it.write) ","
        arr .= '"icon":' JStr(it.icon)
        arr .= "}"
    }
    arr .= "]"
    js := "try{window.__setProcesses&&window.__setProcesses(" arr ")}catch(e){}"
    try wvCore.ExecuteScriptAsync(js)
}

SortProcByMem(items) {
    ; 简易选择排序（条目通常 < 500）
    n := items.Length
    loop n - 1 {
        i := A_Index
        best := i
        loop n - i {
            j := i + A_Index
            if ProcMemRank(items[j].mem) > ProcMemRank(items[best].mem)
                best := j
        }
        if best != i {
            tmp := items[i]
            items[i] := items[best]
            items[best] := tmp
        }
    }
    return items
}

ProcMemRank(s) {
    s := Trim(String(s))
    if RegExMatch(s, "i)([\d.]+)\s*([KMGT]?)", &m) {
        v := Float(m[1])
        u := StrUpper(m[2])
        if u = "T"
            return v * 1024 ** 4
        if u = "G"
            return v * 1024 ** 3
        if u = "M"
            return v * 1024 ** 2
        if u = "K"
            return v * 1024
        return v
    }
    return 0
}

IsSystemProcess(name, path, pid) {
    n := StrLower(String(name))
    p := StrLower(String(path))
    if pid <= 4
        return true
    static sysNames := Map(
        "system", 1, "registry", 1, "smss.exe", 1, "csrss.exe", 1,
        "wininit.exe", 1, "services.exe", 1, "lsass.exe", 1, "winlogon.exe", 1,
        "svchost.exe", 1, "fontdrvhost.exe", 1, "dwm.exe", 1, "conhost.exe", 1,
        "sihost.exe", 1, "taskhostw.exe", 1, "runtimebroker.exe", 1,
        "searchindexer.exe", 1, "securityhealthservice.exe", 1,
        "memory compression", 1, "idle", 1, "system idle process", 1
    )
    if sysNames.Has(n)
        return true
    if InStr(p, "\windows\system32\") || InStr(p, "\windows\syswow64\")
        return true
    if InStr(p, "\windows\") && (InStr(n, "host") || InStr(n, "svc"))
        return true
    return false
}

FormatMemSize(bytes) {
    bytes := Max(0, Integer(bytes))
    if bytes >= 1024 ** 3
        return Format("{:.1f} G", bytes / (1024 ** 3))
    if bytes >= 1024 ** 2 {
        mb := bytes / (1024 ** 2)
        return mb >= 100 ? (Integer(Round(mb)) " M") : Format("{:.1f} M", mb)
    }
    if bytes >= 1024
        return Integer(Round(bytes / 1024)) " K"
    return bytes " B"
}

; 任务管理器风格：1,606.8 MB
FormatMemSizeTM(bytes) {
    bytes := Max(0, Integer(bytes))
    if bytes >= 1024 ** 3
        return Format("{:.1f} GB", bytes / (1024 ** 3))
    if bytes >= 1024 ** 2
        return Format("{:.1f} MB", bytes / (1024 ** 2))
    if bytes >= 1024
        return Format("{:.1f} KB", bytes / 1024)
    return bytes " B"
}

FormatCpuPct(pct) {
    pct := Max(0.0, Min(100.0, Float(pct)))
    if pct < 0.05
        return "0%"
    r := Round(pct, 1)
    if Abs(r - Round(r)) < 0.05
        return Integer(Round(r)) "%"
    return Format("{:.1f}%", r)
}

FormatByteRate(bps) {
    bps := Max(0, Float(bps))
    if bps >= 1024 ** 2
        return Format("{:.1f} M/S", bps / (1024 ** 2))
    if bps >= 1024
        return Integer(Round(bps / 1024)) " K/S"
    return Integer(Round(bps)) " B/S"
}

GetProcessCpu100ns(pid, &outCpu) {
    outCpu := 0
    h := DllCall("OpenProcess", "UInt", 0x0400, "Int", 0, "UInt", pid, "Ptr")  ; PROCESS_QUERY_INFORMATION
    if !h
        h := DllCall("OpenProcess", "UInt", 0x1000, "Int", 0, "UInt", pid, "Ptr")  ; PROCESS_QUERY_LIMITED_INFORMATION
    if !h
        return false
    ct := Buffer(8, 0), et := Buffer(8, 0), kt := Buffer(8, 0), ut := Buffer(8, 0)
    ok := DllCall("GetProcessTimes", "Ptr", h, "Ptr", ct, "Ptr", et, "Ptr", kt, "Ptr", ut)
    DllCall("CloseHandle", "Ptr", h)
    if !ok
        return false
    outCpu := NumGet(kt, 0, "Int64") + NumGet(ut, 0, "Int64")
    return true
}

GetProcessIoBytes(pid, &outRead, &outWrite) {
    outRead := 0, outWrite := 0
    h := DllCall("OpenProcess", "UInt", 0x0400, "Int", 0, "UInt", pid, "Ptr")
    if !h
        h := DllCall("OpenProcess", "UInt", 0x1000, "Int", 0, "UInt", pid, "Ptr")
    if !h
        return false
    ; IO_COUNTERS: 6 ULONGLONG
    io := Buffer(48, 0)
    ok := DllCall("GetProcessIoCounters", "Ptr", h, "Ptr", io)
    DllCall("CloseHandle", "Ptr", h)
    if !ok
        return false
    outRead := NumGet(io, 16, "UInt64")   ; ReadTransferCount
    outWrite := NumGet(io, 32, "UInt64")  ; WriteTransferCount
    return true
}

; ── 进程监控（连接列表：先出表，再异步补图标）────────────
global portShowSys := false
global portPidCache := Map()  ; pid -> {name, path, icon, sys}
global portPushGen := 0
global portIconItems := []
global portIconGen := 0
global portIconCursor := 1

PushPortList(*) {
    global wvCore, portShowSys, portPushGen, portIconItems, portIconGen, portIconCursor, procIconCache, procViewOn
    if !IsObject(wvCore)
        return
    ; 窗口已隐藏或未在进程监控页：不采样
    if !procViewOn || !IsDashboardVisible() {
        SetTimer(PushPortIconsBatch, 0)
        return
    }
    showSys := !!portShowSys
    portPushGen += 1
    myGen := portPushGen
    SetTimer(PushPortIconsBatch, 0)

    outFile := A_Temp "\netstat_ports_" A_TickCount ".txt"
    try {
        RunWait(A_ComSpec ' /c netstat -ano > "' outFile '"', , "Hide")
    } catch as e {
        AppLog("PushPortList netstat " e.Message)
        return
    }
    if myGen != portPushGen
        return
    txt := ""
    try txt := FileRead(outFile, "UTF-8")
    catch
        try txt := FileRead(outFile, "CP0")
    try FileDelete outFile

    raw := []
    for line in StrSplit(txt, "`n", "`r") {
        line := Trim(line)
        if line = "" || InStr(line, "Proto") || InStr(line, "活动") || InStr(line, "Active")
            continue
        parts := []
        for part in StrSplit(RegExReplace(line, "\s+", A_Space), A_Space)
            if part != ""
                parts.Push(part)
        if parts.Length < 4
            continue
        proto := StrUpper(parts[1])
        if proto != "TCP" && proto != "UDP"
            continue
        localAddr := parts[2]
        remoteAddr := parts[3]
        state := ""
        pid := 0
        if proto = "TCP" {
            if parts.Length < 5
                continue
            state := StrUpper(parts[4])
            pid := Integer(parts[5])
        } else {
            pid := Integer(parts[parts.Length])
        }
        localIp := "", localPort := -1, remoteIp := "", remotePort := -1
        SplitNetAddr(localAddr, &localIp, &localPort)
        SplitNetAddr(remoteAddr, &remoteIp, &remotePort)
        if localPort < 0
            continue
        raw.Push({
            proto: proto,
            localIp: localIp,
            localPort: localPort,
            remoteIp: remoteIp,
            remotePort: Max(0, remotePort),
            state: MapNetState(state),
            pid: pid
        })
    }
    if myGen != portPushGen
        return

    ; 一次 WMI 批量补全后推送正文（无图标，避免多次整表刷新闪烁）
    pmap := BuildPortProcMap()
    if myGen != portPushGen
        return
    items := BuildPortItemsFromRaw(raw, showSys, false, pmap)
    EmitPortItems(items)

    ; 异步分批补图标（前端只补 img，不重绘整表）
    portIconItems := items
    portIconGen := myGen
    portIconCursor := 1
    SetTimer(PushPortIconsBatch, -30)
}

BuildPortItemsFromRaw(raw, showSys, withIcons := false, pmap := 0) {
    items := []
    seenPid := Map()
    for r in raw {
        info := LookupPortPid(r.pid, pmap, withIcons)
        if !showSys && info.sys
            continue
        procName := info.name
        if procName = "" && Integer(r.pid) > 0
            procName := "PID " r.pid
        if procName = "" && Integer(r.pid) <= 0
            procName := "—"
        pid := Integer(r.pid)
        if pid > 0
            seenPid[pid] := 1
        memN := 0
        if pmap is Map && pmap.Has(pid) && pmap[pid].HasProp("mem")
            memN := Integer(pmap[pid].mem)
        items.Push({
            proto: r.proto,
            localIp: r.localIp,
            localPort: r.localPort,
            remoteIp: r.remoteIp,
            remotePort: r.remotePort,
            state: r.state,
            pid: pid,
            ppid: Integer(info.ppid),
            proc: procName,
            path: info.path,
            icon: withIcons ? info.icon : "",
            sys: !!info.sys,
            hasNet: true,
            mem: memN > 0 ? FormatMemSizeTM(memN) : "",
            memN: memN,
            cpu: "0%",
            cpuN: 0.0
        })
    }
    ; 补上无网络连接的进程，才能像任务管理器一样搜到 AutoHotkey 等
    if pmap is Map {
        for pid, info in pmap {
            pid := Integer(pid)
            if pid <= 0 || seenPid.Has(pid)
                continue
            if !showSys && info.sys
                continue
            procName := info.name
            if procName = ""
                procName := "PID " pid
            ico := ""
            if withIcons && info.path != "" {
                global procIconCache
                if procIconCache.Has(info.path)
                    ico := procIconCache[info.path]
            } else if info.path != "" {
                global procIconCache
                if procIconCache.Has(info.path)
                    ico := procIconCache[info.path]
            }
            memN := info.HasProp("mem") ? Integer(info.mem) : 0
            items.Push({
                proto: "",
                localIp: "",
                localPort: -1,
                remoteIp: "",
                remotePort: -1,
                state: "",
                pid: pid,
                ppid: Integer(info.ppid),
                proc: procName,
                path: info.path,
                icon: ico,
                sys: !!info.sys,
                hasNet: false,
                mem: memN > 0 ? FormatMemSizeTM(memN) : "",
                memN: memN,
                cpu: "0%",
                cpuN: 0.0
            })
        }
    }
    EnrichPortCpuMem(items)
    return items
}

; 按唯一 PID 采样 CPU
EnrichPortCpuMem(items) {
    global procSampleMap, procCpuCores
    if !IsObject(items) || !items.Length
        return
    now := A_TickCount
    cache := Map()
    for it in items {
        pid := Integer(it.pid)
        if pid <= 0 {
            it.cpu := ""
            it.cpuN := 0.0
            continue
        }
        if cache.Has(pid) {
            s := cache[pid]
            it.cpu := s.cpu
            it.cpuN := s.cpuN
            continue
        }
        cpuTxt := "0%", cpuN := 0.0
        cpuNow := 0
        GetProcessCpu100ns(pid, &cpuNow)
        if procSampleMap.Has(pid) {
            prev := procSampleMap[pid]
            dt := Max(1, now - Integer(prev.t))
            dCpu := Max(0, cpuNow - Integer(prev.cpu))
            avail := dt * 10000.0 * procCpuCores
            pct := avail > 0 ? Min(100.0, dCpu / avail * 100.0) : 0.0
            cpuN := pct
            cpuTxt := FormatCpuPct(pct)
            readNow := Integer(prev.HasProp("read") ? prev.read : 0)
            writeNow := Integer(prev.HasProp("write") ? prev.write : 0)
            procSampleMap[pid] := { t: now, cpu: cpuNow, read: readNow, write: writeNow }
        } else {
            procSampleMap[pid] := { t: now, cpu: cpuNow, read: 0, write: 0 }
        }
        cache[pid] := { cpu: cpuTxt, cpuN: cpuN }
        it.cpu := cpuTxt
        it.cpuN := cpuN
    }
}

; 系统总 CPU% / 内存占用%（表头顶部数字）
global sysTimesSample := { t: 0, idle: 0, kernel: 0, user: 0 }
GetSysCpuMemPct(&cpuPct, &memPct) {
    global sysTimesSample
    cpuPct := 0.0
    memPct := 0.0
    mse := Buffer(64, 0)
    NumPut("UInt", 64, mse, 0)
    if DllCall("kernel32\GlobalMemoryStatusEx", "Ptr", mse)
        memPct := Float(NumGet(mse, 4, "UInt"))
    idle := Buffer(8, 0), kernel := Buffer(8, 0), user := Buffer(8, 0)
    if !DllCall("GetSystemTimes", "Ptr", idle, "Ptr", kernel, "Ptr", user)
        return
    i := NumGet(idle, 0, "Int64")
    k := NumGet(kernel, 0, "Int64")
    u := NumGet(user, 0, "Int64")
    if Integer(sysTimesSample.t) > 0 {
        dIdle := i - Integer(sysTimesSample.idle)
        dKernel := k - Integer(sysTimesSample.kernel)
        dUser := u - Integer(sysTimesSample.user)
        dTotal := dKernel + dUser
        if dTotal > 0
            cpuPct := Max(0.0, Min(100.0, (dTotal - dIdle) / dTotal * 100.0))
    }
    sysTimesSample := { t: A_TickCount, idle: i, kernel: k, user: u }
}

BuildPortProcMap() {
    m := Map()
    try {
        for proc in ComObjGet("winmgmts:").ExecQuery("SELECT Name,ProcessId,ParentProcessId,ExecutablePath,WorkingSetSize FROM Win32_Process") {
            try {
                pid := Integer(proc.ProcessId)
                if pid <= 0
                    continue
                name := "", path := "", ppid := 0, mem := 0
                try name := String(proc.Name)
                try path := String(proc.ExecutablePath)
                try ppid := Integer(proc.ParentProcessId)
                try mem := Integer(proc.WorkingSetSize)
                ; WMI 对部分 UWP/受保护进程 ExecutablePath 为空 → QueryFullProcessImageName 补
                if path = ""
                    path := ResolveProcessImagePath(pid)
                m[pid] := { name: name, path: path, ppid: ppid, mem: mem, icon: "", sys: IsSystemProcess(name, path, pid) }
            }
        }
    } catch as e {
        AppLog("BuildPortProcMap " e.Message)
    }
    return m
}

; 打开进程取完整映像路径（WMI ExecutablePath 为空时的兜底）
ResolveProcessImagePath(pid) {
    pid := Integer(pid)
    if pid <= 0
        return ""
    h := DllCall("OpenProcess", "UInt", 0x1000, "Int", 0, "UInt", pid, "Ptr") ; PROCESS_QUERY_LIMITED_INFORMATION
    if !h
        h := DllCall("OpenProcess", "UInt", 0x0400, "Int", 0, "UInt", pid, "Ptr") ; PROCESS_QUERY_INFORMATION
    if !h
        return ""
    try {
        sz := 520
        buf := Buffer(sz * 2, 0)
        n := sz
        if DllCall("QueryFullProcessImageNameW", "Ptr", h, "UInt", 0, "Ptr", buf, "UInt*", &n)
            return StrGet(buf, "UTF-16")
    } finally {
        DllCall("CloseHandle", "Ptr", h)
    }
    return ""
}

LookupPortPid(pid, pmap := 0, withIcons := false) {
    global portPidCache, procIconCache
    pid := Integer(pid)
    if pid <= 0
        return { name: "", path: "", icon: "", sys: true, ppid: 0 }
    if pmap is Map && pmap.Has(pid) {
        info := pmap[pid]
        ico := ""
        if withIcons && info.path != "" {
            if procIconCache.Has(info.path)
                ico := procIconCache[info.path]
            else {
                ico := ShellIconUrl(info.path, false)
                procIconCache[info.path] := ico
            }
        } else if info.path != "" && procIconCache.Has(info.path)
            ico := procIconCache[info.path]
        out := { name: info.name, path: info.path, icon: ico, sys: !!info.sys, ppid: Integer(info.ppid) }
        portPidCache[pid] := out
        return out
    }
    if portPidCache.Has(pid) {
        cached := portPidCache[pid]
        if !cached.HasProp("ppid")
            cached.ppid := 0
        if withIcons && cached.path != "" && cached.icon = "" {
            if procIconCache.Has(cached.path)
                cached.icon := procIconCache[cached.path]
            else {
                cached.icon := ShellIconUrl(cached.path, false)
                procIconCache[cached.path] := cached.icon
            }
            portPidCache[pid] := cached
        }
        return cached
    }
    name := "", path := ""
    try name := ProcessGetName(pid)
    catch
        name := ""
    path := ResolveProcessImagePath(pid)
    out := { name: name, path: path, icon: "", sys: IsSystemProcess(name, path, pid), ppid: 0 }
    if withIcons && path != "" {
        if procIconCache.Has(path)
            out.icon := procIconCache[path]
        else {
            out.icon := ShellIconUrl(path, false)
            procIconCache[path] := out.icon
        }
    }
    portPidCache[pid] := out
    return out
}

EmitPortItems(items, *) {
    global wvCore
    if !IsObject(wvCore)
        return
    cpuTot := 0.0, memTot := 0.0
    GetSysCpuMemPct(&cpuTot, &memTot)
    arr := "["
    first := true
    for it in items {
        if !first
            arr .= ","
        first := false
        arr .= "{"
        arr .= '"proto":' JStr(it.proto) ","
        arr .= '"localIp":' JStr(it.localIp) ","
        arr .= '"localPort":' Integer(it.localPort) ","
        arr .= '"remoteIp":' JStr(it.remoteIp) ","
        arr .= '"remotePort":' Integer(it.remotePort) ","
        arr .= '"state":' JStr(it.state) ","
        arr .= '"pid":' Integer(it.pid) ","
        arr .= '"ppid":' Integer(it.ppid) ","
        arr .= '"proc":' JStr(it.proc) ","
        arr .= '"path":' JStr(it.path) ","
        arr .= '"icon":' JStr(it.icon) ","
        arr .= '"sys":' (it.sys ? "true" : "false") ","
        arr .= '"hasNet":' (it.HasProp("hasNet") && it.hasNet ? "true" : "false") ","
        arr .= '"cpu":' JStr(it.HasProp("cpu") ? it.cpu : "") ","
        arr .= '"cpuN":' Format("{:.2f}", Float(it.HasProp("cpuN") ? it.cpuN : 0)) ","
        arr .= '"mem":' JStr(it.HasProp("mem") ? it.mem : "") ","
        arr .= '"memN":' Integer(it.HasProp("memN") ? it.memN : 0)
        arr .= "}"
    }
    arr .= "]"
    payload := '{"cpuTotal":' JStr(FormatCpuPct(cpuTot))
        . ',"memTotal":' JStr(Integer(Round(memTot)) "%")
        . ',"items":' arr "}"
    js := "try{window.__setPorts&&window.__setPorts(" payload ")}catch(e){}"
    try wvCore.ExecuteScriptAsync(js)
}

PushPortIconsBatch(*) {
    global portPushGen, portIconItems, portIconGen, portIconCursor, procIconCache, procViewOn
    if !procViewOn || !IsDashboardVisible() {
        SetTimer(PushPortIconsBatch, 0)
        return
    }
    if portIconGen != portPushGen || !IsObject(portIconItems)
        return
    n := portIconItems.Length
    if n < 1 || portIconCursor > n {
        SetTimer(PushPortIconsBatch, 0)
        return
    }
    ; 每批最多处理 16 个尚未有图标的唯一路径，减少推送次数
    done := 0
    paths := Map()
    while portIconCursor <= n && done < 16 {
        it := portIconItems[portIconCursor]
        portIconCursor += 1
        p := String(it.path)
        if p = "" || it.icon != ""
            continue
        if procIconCache.Has(p) {
            it.icon := procIconCache[p]
            continue
        }
        if paths.Has(p)
            continue
        paths[p] := 1
        ico := ShellIconUrl(p, false)
        procIconCache[p] := ico
        it.icon := ico
        done += 1
    }
    for it in portIconItems {
        if it.icon = "" && it.path != "" && procIconCache.Has(it.path)
            it.icon := procIconCache[it.path]
    }
    EmitPortItems(portIconItems)
    if portIconCursor <= n
        SetTimer(PushPortIconsBatch, -80)
    else
        SetTimer(PushPortIconsBatch, 0)
}

SplitNetAddr(addr, &ip, &port) {
    addr := Trim(String(addr))
    ip := "0.0.0.0", port := 0
    if addr = "" || addr = "*" || addr = "*:*"
        return
    if RegExMatch(addr, "^\[([^\]]+)\]:(\d+)$", &m) {
        ip := m[1], port := Integer(m[2])
        return
    }
    if RegExMatch(addr, "^(.+):(\d+)$", &m) {
        ip := m[1], port := Integer(m[2])
        if ip = "*" || ip = ""
            ip := "0.0.0.0"
        return
    }
    if RegExMatch(addr, ":(\d+)$", &m)
        port := Integer(m[1])
    else
        ip := addr
}

ParseLocalPort(addr) {
    localIp := "", port := -1
    SplitNetAddr(addr, &localIp, &port)
    return port
}

MapNetState(s) {
    s := StrUpper(Trim(String(s)))
    switch s {
        case "LISTENING": return "监听"
        case "ESTABLISHED": return "连接"
        case "TIME_WAIT": return "等待"
        case "CLOSE_WAIT": return "关闭等待"
        case "SYN_SENT": return "连接中"
        case "SYN_RECEIVED", "SYN_RECV": return "接收连接"
        case "FIN_WAIT_1", "FIN_WAIT_2": return "结束等待"
        case "LAST_ACK": return "最后确认"
        case "CLOSING": return "关闭中"
        case "": return ""
        default: return s
    }
}

ResolvePortPid(pid) {
    return LookupPortPid(pid, 0, true)
}

; ── 本机信息 ─────────────────────────────────────────────
global sysInfoCache := ""
global sysInfoForce := false
; ── 关联句柄（Sysinternals handle64）────────────────────
global HANDLE_EXE := A_Temp "\handle64.exe"
global HANDLE_URL := "https://live.sysinternals.com/handle64.exe"
global handleSearchGen := 0
global handleSearchBusy := false

EnsureHandle64() {
    global HANDLE_EXE, HANDLE_URL
    if FileExist(HANDLE_EXE) && FileGetSize(HANDLE_EXE) > 50000
        return true
    AppLog("EnsureHandle64 download " HANDLE_URL)
    try DirCreate(A_Temp)
    ok := false
    try ok := DownloadFile(HANDLE_URL, HANDLE_EXE)
    if !ok {
        try ok := DashboardDownloadFile(HANDLE_URL, HANDLE_EXE)
    }
    if ok && FileExist(HANDLE_EXE) && FileGetSize(HANDLE_EXE) > 50000
        return true
    AppLog("EnsureHandle64 fail")
    return false
}

; UI: handleSearch|keyword  （端口：8080|80、0-300|500、0-65535 全部连接 → 按需 netstat）
StartHandleSearch(q) {
    global handleSearchGen, handleSearchBusy
    q := Trim(String(q))
    handleSearchGen += 1
    gen := handleSearchGen
    handleSearchBusy := true
    if IsPortSearchQuery(q) {
        if IsAllPortsQuery(q)
            SetTimer(RunPortSearch.Bind([], q, gen, true), -1)
        else {
            ports := ParsePortListFromQuery(q)
            SetTimer(RunPortSearch.Bind(ports, q, gen, false), -1)
        }
        return
    }
    SetTimer(RunHandleSearch.Bind(q, gen), -1)
}

IsAllPortsQuery(q) {
    q := Trim(String(q))
    if RegExMatch(q, "i)^/(端口|port)\s*(.*)$", &m)
        q := Trim(m[2])
    return q = "*" || q = "all" || RegExMatch(q, "^0\s*-\s*65535$")
}

IsPortSearchQuery(q) {
    q := Trim(String(q))
    if RegExMatch(q, "i)^/(端口|port)\s*(.*)$", &m)
        q := Trim(m[2])
    if q = ""
        return false
    return !!RegExMatch(q, "^[\d\s|\-]+$") && RegExMatch(q, "\d")
}

ParsePortListFromQuery(q) {
    q := Trim(String(q))
    if RegExMatch(q, "i)^/(端口|port)\s*(.*)$", &m)
        q := Trim(m[2])
    ports := []
    seen := Map()
    AddPort(p) {
        p := Integer(p)
        if p < 0 || p > 65535 || seen.Has(p)
            return
        seen[p] := 1
        ports.Push(p)
    }
    for part in StrSplit(q, "|") {
        part := Trim(part)
        if part = ""
            continue
        if RegExMatch(part, "^(\d+)\s*-\s*(\d+)$", &rm) {
            a := Integer(rm[1]), b := Integer(rm[2])
            if a > b {
                t := a, a := b, b := t
            }
            a := Max(0, Min(65535, a))
            b := Max(0, Min(65535, b))
            loop (b - a + 1)
                AddPort(a + A_Index - 1)
        } else if RegExMatch(part, "^\d+$") {
            AddPort(Integer(part))
        }
    }
    return ports
}

RunPortSearch(ports, q, gen, allPorts := false) {
    global handleSearchGen, handleSearchBusy
    if gen != handleSearchGen
        return
    try {
        allPorts := !!allPorts || IsAllPortsQuery(q)
        if !allPorts && (!IsObject(ports) || !ports.Length) {
            EmitHandles([], q, "端口无效，示例：8080|80 或 0-300|500", "port")
            return
        }
        want := Map()
        if !allPorts {
            for p in ports
                want[Integer(p)] := 1
        }
        outFile := A_Temp "\ahk_port_" gen ".txt"
        try FileDelete outFile
        try RunWait(A_ComSpec ' /c netstat -ano > "' outFile '"', , "Hide")
        catch as e {
            EmitHandles([], q, "netstat 失败: " e.Message, "port")
            return
        }
        if gen != handleSearchGen
            return
        txt := ""
        if FileExist(outFile) {
            try txt := FileRead(outFile, "UTF-8")
            catch
                try txt := FileRead(outFile, "CP0")
            try FileDelete outFile
        }
        items := []
        seenRow := Map()
        for line in StrSplit(txt, "`n", "`r") {
            line := Trim(line)
            if line = "" || InStr(line, "Proto") || InStr(line, "活动") || InStr(line, "Active")
                continue
            parts := []
            for part in StrSplit(RegExReplace(line, "\s+", A_Space), A_Space)
                if part != ""
                    parts.Push(part)
            if parts.Length < 4
                continue
            proto := StrUpper(parts[1])
            if proto != "TCP" && proto != "UDP"
                continue
            localAddr := parts[2]
            remoteAddr := parts[3]
            state := ""
            pid := 0
            if proto = "TCP" {
                if parts.Length < 5
                    continue
                state := MapNetState(StrUpper(parts[4]))
                pid := Integer(parts[5])
            } else {
                pid := Integer(parts[parts.Length])
            }
            localIp := "", localPort := -1, remoteIp := "", remotePort := -1
            SplitNetAddr(localAddr, &localIp, &localPort)
            SplitNetAddr(remoteAddr, &remoteIp, &remotePort)
            if localPort < 0
                continue
            if !allPorts && !want.Has(Integer(localPort))
                continue
            ; TIME_WAIT / 无主连接：Windows 上多为 PID 0，名称空白且会占满 2000 条上限
            if pid <= 0
                continue
            rawState := proto = "TCP" ? StrUpper(parts[4]) : ""
            if rawState = "TIME_WAIT" || rawState = "FIN_WAIT_1" || rawState = "FIN_WAIT_2"
             || rawState = "CLOSING" || rawState = "LAST_ACK"
                continue
            rport := Max(0, Integer(remotePort))
            ; 去重：同 PID/协议/本机端口/远程端口/状态（合并 0.0.0.0 与 [::] 等重复监听）
            rowKey := pid "|" proto "|" Integer(localPort) "|" rport "|" state
            if seenRow.Has(rowKey)
                continue
            seenRow[rowKey] := 1
            name := ""
            try name := ProcessGetName(pid)
            catch
                name := ""
            if name = ""
                name := "PID " pid
            items.Push({
                name: name,
                pid: pid,
                type: proto,
                handle: state != "" ? state : "",
                localIp: localIp,
                localPort: localPort,
                remoteIp: remoteIp,
                remotePort: rport,
                path: "",
                icon: ""
            })
            if items.Length >= 5000
                break
        }
        SortHandleItems(items, true)
        EnrichHandleIcons(items)
        EmitHandles(items, q, items.Length ? "" : "没有匹配的端口（已忽略无进程的等待连接）", "port")
    } catch as e {
        AppLog("RunPortSearch " e.Message)
        EmitHandles([], q, e.Message, "port")
    } finally {
        if gen = handleSearchGen
            handleSearchBusy := false
    }
}

RunHandleSearch(q, gen) {
    global handleSearchGen, handleSearchBusy, HANDLE_EXE, wvCore
    if gen != handleSearchGen
        return
    try {
        if q = "" {
            EmitHandles([], "", "")
            return
        }
        if !EnsureHandle64() {
            EmitHandles([], q, "无法下载 handle64.exe，请检查网络")
            return
        }
        ; 首次运行自动接受 EULA；输出重定向到临时文件
        outFile := A_Temp "\ahk_handle_" gen ".txt"
        try FileDelete outFile
        ; 转义查询串中的引号；不加 -a：默认只查文件句柄（与 handle64 "goland64" | File 一致）
        qSafe := StrReplace(q, '"', '')
        cmd := Format('"{1}" /c ""{2}" -accepteula -nobanner "{3}" > "{4}" 2>&1"', A_ComSpec, HANDLE_EXE, qSafe, outFile)
        AppLog("HandleSearch run q=" qSafe)
        try RunWait(cmd, A_Temp, "Hide")
        catch as e {
            EmitHandles([], q, "执行 handle64 失败: " e.Message)
            return
        }
        if gen != handleSearchGen
            return
        text := ""
        if FileExist(outFile) {
            try text := FileRead(outFile, "UTF-8")
            catch {
                try text := FileRead(outFile)
            }
            try FileDelete outFile
        }
        items := ParseHandleOutput(text)
        SortHandleItems(items)
        EnrichHandleIcons(items)
        EmitHandles(items, q, items.Length ? "" : "没有匹配的文件句柄")
    } catch as e {
        AppLog("RunHandleSearch " e.Message)
        EmitHandles([], q, e.Message)
    } finally {
        if gen = handleSearchGen
            handleSearchBusy := false
    }
}

; 按 PID 批量补进程图标（同 PID 只抽一次）
EnrichHandleIcons(items) {
    global procIconCache
    if !IsObject(items) || !items.Length
        return
    byPid := Map()
    for it in items {
        pid := Integer(it.pid)
        if pid <= 0
            continue
        if !byPid.Has(pid)
            byPid[pid] := []
        byPid[pid].Push(it)
    }
    for pid, list in byPid {
        ico := ""
        path := ""
        info := LookupPortPid(pid, 0, false)
        if IsObject(info)
            path := info.HasProp("path") ? String(info.path) : ""
        if path = "" {
            try {
                n := ProcessGetName(pid)
                if n != ""
                    path := ResolveProcessImagePath(pid)
            }
        }
        if path != "" {
            ico := ShellIconUrl(path, false)
            if ico != ""
                procIconCache[path] := ico
        }
        for it in list {
            it.icon := ico
            if path != ""
                it.path := path
        }
    }
}

ParseHandleOutput(text) {
    items := []
    text := String(text ?? "")
    for line in StrSplit(text, "`n", "`r") {
        line := Trim(line)
        if line = "" || InStr(line, "No matching handles") || InStr(line, "Handle v")
            continue
        ; name  pid: N  type: T  HEX: handle-name
        if !RegExMatch(line, "i)^(.+?)\s+pid:\s*(\d+)\s+type:\s*(\S+)\s+[0-9A-Fa-f]+:\s*(.*)$", &m)
            continue
        ; 只保留文件句柄（对应：handle64 … | Where type:\s*File）
        if StrLower(Trim(m[3])) != "file"
            continue
        items.Push({
            name: Trim(m[1]),
            pid: Integer(m[2]),
            type: Trim(m[3]),
            handle: Trim(m[4])
        })
        ; 防止极端输出撑爆 UI
        if items.Length >= 5000
            break
    }
    return items
}

; 同名进程挨在一起，再按 PID / 类型 / 句柄名；portMode 时优先按本机端口
SortHandleItems(items, portMode := false) {
    if !IsObject(items) || items.Length < 2
        return
    keys := []
    for i, it in items {
        nm := RegExReplace(StrLower(String(it.name)), "[\t\r\n]+", " ")
        tp := RegExReplace(StrLower(String(it.type)), "[\t\r\n]+", " ")
        hd := RegExReplace(StrLower(String(it.handle)), "[\t\r\n]+", " ")
        lp := 0
        try lp := Integer(it.localPort)
        catch
            lp := 0
        if portMode
            keys.Push(Format("{:05d}`t{:s}`t{:08d}`t{:s}`t{:s}`t{:08d}", lp, nm, Integer(it.pid), tp, hd, i))
        else
            keys.Push(Format("{:s}`t{:08d}`t{:05d}`t{:s}`t{:s}`t{:08d}", nm, Integer(it.pid), lp, tp, hd, i))
    }
    blob := ""
    for k in keys
        blob .= k "`n"
    blob := Sort(blob, "Logical")
    sorted := []
    for line in StrSplit(blob, "`n", "`r") {
        line := Trim(line)
        if line = ""
            continue
        parts := StrSplit(line, "`t")
        idx := Integer(parts[parts.Length])
        if idx >= 1 && idx <= items.Length
            sorted.Push(items[idx])
    }
    if sorted.Length != items.Length
        return
    items.Length := 0
    for it in sorted
        items.Push(it)
}

EmitHandles(items, q := "", err := "", mode := "handle") {
    global wvCore
    if !IsObject(wvCore)
        return
    if mode != "port"
        mode := "handle"
    arr := "["
    for i, it in items {
        if i > 1
            arr .= ","
        arr .= "{"
        arr .= '"name":' JStr(it.name) ","
        arr .= '"pid":' Integer(it.pid) ","
        arr .= '"type":' JStr(it.type) ","
        arr .= '"handle":' JStr(it.handle) ","
        arr .= '"icon":' JStr(it.HasProp("icon") ? it.icon : "") ","
        arr .= '"path":' JStr(it.HasProp("path") ? it.path : "") ","
        arr .= '"localIp":' JStr(it.HasProp("localIp") ? it.localIp : "") ","
        arr .= '"localPort":' Integer(it.HasProp("localPort") ? it.localPort : -1) ","
        arr .= '"remoteIp":' JStr(it.HasProp("remoteIp") ? it.remoteIp : "") ","
        arr .= '"remotePort":' Integer(it.HasProp("remotePort") ? it.remotePort : -1)
        arr .= "}"
    }
    arr .= "]"
    payload := '{"q":' JStr(q) ',"mode":' JStr(mode) ',"error":' JStr(err) ',"items":' arr "}"
    js := "try{window.__setHandles&&window.__setHandles(" payload ")}catch(e){}"
    try wvCore.ExecuteScriptAsync(js)
}

EmitProcKilled(pids) {
    global wvCore
    if !IsObject(wvCore) || !IsObject(pids) || !pids.Length
        return
    arr := "["
    for i, pid in pids {
        if i > 1
            arr .= ","
        arr .= Integer(pid)
    }
    arr .= "]"
    js := "try{window.__procKilled&&window.__procKilled(" arr ")}catch(e){}"
    try wvCore.ExecuteScriptAsync(js)
}

PushSysInfo(*) {
    global wvCore, sysInfoCache, sysInfoForce
    if !IsObject(wvCore)
        return
    force := !!sysInfoForce
    sysInfoForce := false
    if !force && sysInfoCache != "" {
        js := "try{window.__setSysInfo&&window.__setSysInfo(" sysInfoCache ")}catch(e){}"
        try wvCore.ExecuteScriptAsync(js)
        return
    }
    info := CollectSysInfo()
    payload := SysInfoToJson(info)
    sysInfoCache := payload
    js := "try{window.__setSysInfo&&window.__setSysInfo(" payload ")}catch(e){}"
    try wvCore.ExecuteScriptAsync(js)
}

CollectSysInfo() {
    os := "", board := "", monitor := "", cpu := "", memory := "", disk := "", gpu := ""
    sound := [], nics := []
    wan := "未知", ie := "未知", flash := "未知"
    boot := "未知", uptime := "", uptimeSec := 0, shutdown := "未知", install := "未知"
    try {
        for o in ComObjGet("winmgmts:").ExecQuery("SELECT Caption,Version,BuildNumber,OSArchitecture,LastBootUpTime,InstallDate FROM Win32_OperatingSystem") {
            cap := String(o.Caption)
            ver := String(o.Version)
            build := String(o.BuildNumber)
            arch := InStr(String(o.OSArchitecture), "64") ? "64位" : String(o.OSArchitecture)
            os := Trim(cap) " (Build " build "), " arch
            boot := FormatWmiTime(o.LastBootUpTime)
            install := FormatWmiTime(o.InstallDate)
            uptimeSec := UptimeSecondsFromBoot(o.LastBootUpTime)
            uptime := FormatUptimeSeconds(uptimeSec)
            break
        }
    }
    try {
        for o in ComObjGet("winmgmts:").ExecQuery("SELECT Manufacturer,Product FROM Win32_BaseBoard") {
            board := Trim(String(o.Manufacturer) " " String(o.Product))
            break
        }
    }
    try {
        names := []
        for o in ComObjGet("winmgmts:").ExecQuery("SELECT Name FROM Win32_DesktopMonitor WHERE Status='OK'") {
            n := Trim(String(o.Name))
            if n != ""
                names.Push(n)
        }
        if !names.Length {
            for o in ComObjGet("winmgmts:").ExecQuery("SELECT Name FROM Win32_PnPEntity WHERE Service='monitor'") {
                n := Trim(String(o.Name))
                if n != ""
                    names.Push(n)
            }
        }
        monitor := names.Length ? JoinUnique(names, " / ") : "通用即插即用监视器"
    }
    try {
        for o in ComObjGet("winmgmts:").ExecQuery("SELECT Name FROM Win32_Processor") {
            cpu := Trim(String(o.Name))
            break
        }
    }
    try {
        tot := 0
        for o in ComObjGet("winmgmts:").ExecQuery("SELECT Capacity FROM Win32_PhysicalMemory") {
            tot += Integer(o.Capacity)
        }
        if tot > 0
            memory := Format("{:.2f} GB", tot / (1024 ** 3))
    }
    try {
        parts := []
        for o in ComObjGet("winmgmts:").ExecQuery("SELECT Model,Size,MediaType,InterfaceType FROM Win32_DiskDrive") {
            model := Trim(String(o.Model))
            sz := Integer(o.Size)
            gb := sz > 0 ? Integer(Round(sz / (1024 ** 3))) : 0
            if model = ""
                continue
            parts.Push(model (gb > 0 ? " (" gb "GB)" : ""))
        }
        disk := parts.Length ? JoinUnique(parts, "；") : "未知"
    }
    try {
        parts := []
        for o in ComObjGet("winmgmts:").ExecQuery("SELECT Name,AdapterCompatibility FROM Win32_VideoController") {
            n := Trim(String(o.Name))
            if n = "" || InStr(StrLower(n), "basic render") || InStr(StrLower(n), "microsoft basic")
                continue
            parts.Push(n)
        }
        gpu := parts.Length ? JoinUnique(parts, " / ") : "未知"
    }
    try {
        for o in ComObjGet("winmgmts:").ExecQuery("SELECT Name,Status FROM Win32_SoundDevice") {
            n := Trim(String(o.Name))
            if n != ""
                sound.Push(n)
        }
    }
    try {
        nics := CollectNicList()
    }
    try {
        ie := RegRead("HKLM\SOFTWARE\Microsoft\Internet Explorer", "svcVersion")
        if ie = ""
            ie := RegRead("HKLM\SOFTWARE\Microsoft\Internet Explorer", "Version")
    } catch
        ie := "未知"
    if ie = ""
        ie := "未知"
    try {
        flash := RegRead("HKLM\SOFTWARE\Macromedia\FlashPlayer", "CurrentVersion")
    } catch
        flash := "未知"
    if flash = ""
        flash := "未知"
    try {
        raw := RegRead("HKLM\SYSTEM\CurrentControlSet\Control\Windows", "ShutdownTime")
        shutdown := FormatRegFileTime(raw)
    } catch
        shutdown := "未知"
    ; 外网 IP：短超时，失败则未知
    wan := FetchPublicIp()
    return {
        os: os != "" ? os : "未知",
        board: board != "" ? board : "未知",
        monitor: monitor,
        cpu: cpu != "" ? cpu : "未知",
        memory: memory != "" ? memory : "未知",
        disk: disk,
        gpu: gpu,
        sound: sound,
        nics: nics,
        wan: wan,
        ie: ie,
        flash: flash,
        boot: boot,
        uptime: uptime,
        uptimeSec: Integer(uptimeSec),
        shutdown: shutdown,
        install: install
    }
}

SysInfoToJson(info) {
    soundArr := "["
    first := true
    for s in info.sound {
        if !first
            soundArr .= ","
        first := false
        soundArr .= JStr(s)
    }
    soundArr .= "]"
    nicArr := "["
    first := true
    for n in info.nics {
        if !first
            nicArr .= ","
        first := false
        nicArr .= '{"name":' JStr(n.name) ',"mac":' JStr(n.mac) ',"ip":' JStr(n.ip) "}"
    }
    nicArr .= "]"
    text := "操作系统: " info.os "`n主板: " info.board "`n显示器: " info.monitor
        . "`n处理器: " info.cpu "`n内存: " info.memory "`n硬盘: " info.disk
        . "`n显卡: " info.gpu "`n外网IP: " info.wan "`nIE版本: " info.ie
        . "`nFlash版本: " info.flash "`n开机时间: " info.boot
        . (info.uptime != "" ? "  系统已运行: " info.uptime : "")
        . "`n上次关机时间: " info.shutdown "`n系统安装日期: " info.install
    return "{"
        . '"os":' JStr(info.os) ","
        . '"board":' JStr(info.board) ","
        . '"monitor":' JStr(info.monitor) ","
        . '"cpu":' JStr(info.cpu) ","
        . '"memory":' JStr(info.memory) ","
        . '"disk":' JStr(info.disk) ","
        . '"gpu":' JStr(info.gpu) ","
        . '"sound":' soundArr ","
        . '"nics":' nicArr ","
        . '"wan":' JStr(info.wan) ","
        . '"ie":' JStr(info.ie) ","
        . '"flash":' JStr(info.flash) ","
        . '"boot":' JStr(info.boot) ","
        . '"uptime":' JStr(info.uptime) ","
        . '"uptimeSec":' Integer(info.HasProp("uptimeSec") ? info.uptimeSec : 0) ","
        . '"shutdown":' JStr(info.shutdown) ","
        . '"install":' JStr(info.install) ","
        . '"text":' JStr(text)
        . "}"
}

JoinUnique(arr, sep := " / ") {
    seen := Map(), out := []
    for s in arr {
        k := StrLower(Trim(String(s)))
        if k = "" || seen.Has(k)
            continue
        seen[k] := 1
        out.Push(Trim(String(s)))
    }
    return out.Length ? out[1] JoinRest(out, sep) : ""
}
JoinRest(arr, sep) {
    if arr.Length <= 1
        return ""
    s := ""
    loop arr.Length - 1
        s .= sep arr[A_Index + 1]
    return s
}

FormatMac(mac) {
    mac := StrUpper(RegExReplace(String(mac), "[^0-9A-Fa-f]", ""))
    if StrLen(mac) != 12
        return String(mac)
    out := ""
    loop 6 {
        if A_Index > 1
            out .= "-"
        out .= SubStr(mac, (A_Index - 1) * 2 + 1, 2)
    }
    return out
}

FormatWmiTime(t) {
    t := String(t)
    ; yyyymmddHHMMSS.mmmmmm+UUU
    if RegExMatch(t, "^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})", &m)
        return m[1] "年" Integer(m[2]) "月" Integer(m[3]) "日 " m[4] ":" m[5] ":" m[6]
    return t != "" ? t : "未知"
}

FormatUptimeFromBoot(t) {
    return FormatUptimeSeconds(UptimeSecondsFromBoot(t))
}

UptimeSecondsFromBoot(t) {
    t := String(t)
    if !RegExMatch(t, "^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})", &m)
        return 0
    try {
        boot := m[1] m[2] m[3] m[4] m[5] m[6]
        sec := DateDiff(A_Now, boot, "Seconds")
        return sec > 0 ? Integer(sec) : 0
    }
    return 0
}

FormatUptimeSeconds(sec) {
    sec := Max(0, Integer(sec))
    d := sec // 86400
    h := Mod(sec, 86400) // 3600
    mi := Mod(sec, 3600) // 60
    s := Mod(sec, 60)
    out := ""
    if d > 0
        out .= d "天"
    out .= h "小时" mi "分钟" s "秒"
    return out
}

WmiFirstIpv4(ips) {
    if ips = "" || ips = 0
        return ""
    try {
        if ips is String {
            if RegExMatch(ips, "(\d{1,3}(?:\.\d{1,3}){3})", &m)
                return m[1]
            return ""
        }
    }
    ; SAFEARRAY / COM 枚举
    try {
        for cand in ips {
            c := String(cand)
            if RegExMatch(c, "^\d{1,3}(\.\d{1,3}){3}$")
                return c
        }
    }
    try {
        loop 16 {
            idx := A_Index - 1
            try {
                c := String(ips[idx])
                if RegExMatch(c, "^\d{1,3}(\.\d{1,3}){3}$")
                    return c
            }
        }
    }
    try {
        raw := String(ips)
        if RegExMatch(raw, "(\d{1,3}(?:\.\d{1,3}){3})", &m)
            return m[1]
    }
    return ""
}

CollectNicList() {
    nics := []
    psFile := A_Temp "\helpme_nic_list.ps1"
    outFile := A_Temp "\helpme_nic_list_out.txt"
    ; 在脚本内写文件（RunWait 直接调 powershell 时 shell 重定向无效）
    script := "
(
param([string]`$OutPath)
`$lines = @()
Get-CimInstance Win32_NetworkAdapterConfiguration | Where-Object { `$_.MACAddress } | ForEach-Object {
  `$ip = @(`$_.IPAddress | Where-Object { `$_ -match '^\d{1,3}(\.\d{1,3}){3}$' }) | Select-Object -First 1
  if (-not `$ip) { `$ip = '0.0.0.0' }
  `$lines += ((`$_.Description) + [char]9 + (`$_.MACAddress) + [char]9 + `$ip)
}
[System.IO.File]::WriteAllLines(`$OutPath, `$lines, [System.Text.UTF8Encoding]::new(`$false))
)"
    try {
        try FileDelete psFile
        try FileDelete outFile
        FileAppend script, psFile, "UTF-8"
        RunWait(Format('powershell -NoProfile -ExecutionPolicy Bypass -File "{1}" -OutPath "{2}"', psFile, outFile), , "Hide")
        if FileExist(outFile) {
            txt := ""
            try txt := FileRead(outFile, "UTF-8")
            catch
                try txt := FileRead(outFile, "CP0")
            for line in StrSplit(txt, "`n", "`r") {
                line := Trim(line)
                if line = "" || !InStr(line, "`t")
                    continue
                parts := StrSplit(line, "`t")
                if parts.Length < 3
                    continue
                name := Trim(parts[1]), mac := FormatMac(parts[2]), ip := Trim(parts[3])
                if name = ""
                    continue
                if !RegExMatch(ip, "^\d{1,3}(\.\d{1,3}){3}$")
                    ip := "0.0.0.0"
                nics.Push({ name: name, mac: mac, ip: ip })
            }
        }
    } catch as e {
        AppLog("CollectNicList ps " e.Message)
    }
    try FileDelete psFile
    try FileDelete outFile
    if nics.Length
        return nics
    ; 回退 WMI
    try {
        for o in ComObjGet("winmgmts:").ExecQuery("SELECT Description,MACAddress,IPAddress FROM Win32_NetworkAdapterConfiguration WHERE MACAddress IS NOT NULL") {
            name := Trim(String(o.Description))
            mac := FormatMac(String(o.MACAddress))
            ip := WmiFirstIpv4(o.IPAddress)
            if ip = ""
                ip := "0.0.0.0"
            if name = ""
                continue
            nics.Push({ name: name, mac: mac, ip: ip })
        }
    }
    return nics
}

FormatRegFileTime(raw) {
    try {
        buf := ""
        if raw is Buffer {
            if raw.Size < 8
                return "未知"
            buf := raw
        } else if Type(raw) = "String" {
            if StrLen(raw) < 8
                return "未知"
            buf := Buffer(8, 0)
            loop 8
                NumPut("UChar", Ord(SubStr(raw, A_Index, 1)), buf, A_Index - 1)
        } else
            return "未知"
        ft := Buffer(8, 0)
        NumPut("UInt64", NumGet(buf, 0, "UInt64"), ft, 0)
        st := Buffer(16, 0)
        if !DllCall("FileTimeToSystemTime", "Ptr", ft, "Ptr", st)
            return "未知"
        lt := Buffer(16, 0)
        if !DllCall("SystemTimeToTzSpecificLocalTime", "Ptr", 0, "Ptr", st, "Ptr", lt)
            lt := st
        y := NumGet(lt, 0, "UShort")
        mo := NumGet(lt, 2, "UShort")
        d := NumGet(lt, 6, "UShort")
        h := NumGet(lt, 8, "UShort")
        mi := NumGet(lt, 10, "UShort")
        s := NumGet(lt, 12, "UShort")
        return y "年" mo "月" d "日 " Format("{:02d}:{:02d}:{:02d}", h, mi, s)
    }
    return "未知"
}

FetchPublicIp() {
    urls := ["https://api.ipify.org", "https://ifconfig.me/ip"]
    for url in urls {
        try {
            whr := ComObject("WinHttp.WinHttpRequest.5.1")
            whr.SetTimeouts(800, 800, 1200, 1200)
            whr.Open("GET", url, false)
            whr.Send()
            if whr.Status = 200 {
                ip := Trim(String(whr.ResponseText))
                if RegExMatch(ip, "^\d{1,3}(\.\d{1,3}){3}$")
                    return ip
            }
        }
    }
    return "未知"
}

; 圆圈 boot 页：on/pct + 标题/说明（不再另开启动窗）
PushBoot(on, pct, title := "", hint := "") {
    global wvCore, bootOn, bootPct, pendingBoot, pendingBootMsg, pendingBootHint, uiReady, mainUiEntered, bootCmdSeq, mainUiEntering
    pct := Integer(pct)
    ; 已进入主界面后禁止再打开 boot（迟到的 ExecuteScript / 轮询会造成闪一下）
    if on && mainUiEntered
        return
    ; 上次停在非搜索页：后台热 Everything，但不要再画红色圈
    if on && ReadLastUiMode() != "file"
        return
    ; 进主界面前进度封顶 88，避免 Everything 秒就绪时直接显示 100%
    if on && !mainUiEntering
        pct := Min(88, pct)
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
    ; uiReady 前：主 WebView 内更新百分比圆圈（pageNav 后只记状态）
    if !uiReady || !IsObject(wvCore) {
        pendingBoot := true
        if on
            ShowBootStub(hint != "" ? hint : title, title != "" ? title : "正在加载", pct)
        return
    }
    pendingBoot := false
    bootCmdSeq += 1
    ApplyBootToPage(on, BootDisplayPct(pct), title, hint, bootCmdSeq)
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

ApplyBootToPage(on, pct, title := "", hint := "", seq := 0) {
    global wvCore
    if !IsObject(wvCore)
        return
    flag := on ? "true" : "false"
    seq := Integer(seq)
    js := "try{window.__setBoot&&window.__setBoot(" flag "," Integer(pct) "," seq ");"
    if on && title != ""
        js .= "var t=document.querySelector('#boot .t1');if(t)t.textContent=" JsQuote(title) ";"
    if on && hint != ""
        js .= "var h=document.querySelector('.boot-hint');if(h)h.innerHTML=" JsQuote(hint) ";"
    js .= "}catch(e){}"
    try wvCore.ExecuteScriptAsync(js)
}

; WebView 晚于 Everything 就绪时，把积压的 boot 状态补推一次
FlushPendingBoot(*) {
    global wvCore, pendingBoot, bootOn, bootPct, pendingBootMsg, pendingBootHint, uiReady, bootCmdSeq, mainUiEntered
    if !pendingBoot || !uiReady || !IsObject(wvCore)
        return
    pendingBoot := false
    if mainUiEntered {
        bootOn := false
        bootCmdSeq += 1
        ApplyBootToPage(false, 100, "", "", bootCmdSeq)
        return
    }
    bootCmdSeq += 1
    ApplyBootToPage(bootOn, BootDisplayPct(bootPct), pendingBootMsg, pendingBootHint, bootCmdSeq)
}

; 过程中如实显示百分比；只有进主界面前一刻才到 100（不再把 ~88 提前映射成 100）
BootDisplayPct(realPct) {
    realPct := Max(0, Min(100, Integer(realPct)))
    return Min(92, realPct)
}

; Navigate ?bp= 上限，避免首屏直接 100%
BootNavPct(realPct) {
    return Max(8, Min(88, BootDisplayPct(realPct)))
}

; Everything 已就绪 → 等页面 uiReady 后再关 boot（避免 WebView 还在初始化时只剩空白）
EnterMainUi(*) {
    global evReady, uiReady, wvCore, mainUiEntered, bootOn, bootPct, pendingBoot, pendingBootMsg, pendingBootHint
    evReady := true
    if mainUiEntered
        return
    if uiReady && IsObject(wvCore) {
        FinishEnterMainUi()
        return
    }
    ; 页面未好：进度先顶到 85（显示仍 <100），再等界面
    bootOn := true
    bootPct := Max(Integer(bootPct), 85)
    pendingBoot := true
    pendingBootMsg := "即将完成"
    pendingBootHint := "索引已就绪，正在加载界面…"
}

FinishEnterMainUi(*) {
    global mainUiEntered, mainUiEntering, bootOn, bootPct, pendingBoot, bootCmdSeq, wvCore, bootShownAt
    if mainUiEntered || mainUiEntering
        return
    mainUiEntering := true
    pendingBoot := false
    SetTimer(FinishEnterMainUiNow, 0)
    ; 非搜索页 / 已可见一段时间 / 进度已较高 → 直接进
    if ReadLastUiMode() != "file" {
        bootPct := 100
        SetTimer(FinishEnterMainUiNow, -1)
        return
    }
    shownMs := (bootShownAt > 0) ? (A_TickCount - bootShownAt) : 0
    cur := BootDisplayPct(bootPct)
    if shownMs >= 350 || cur >= 70 {
        bootPct := 100
        bootCmdSeq += 1
        ApplyBootToPage(true, 100, "即将完成", "马上进入…", bootCmdSeq)
        SetTimer(FinishEnterMainUiNow, -120)
        return
    }
    cur := Max(40, Min(70, cur))
    bootPct := cur
    bootCmdSeq += 1
    ApplyBootToPage(true, cur, "正在加载", "正在准备界面…", bootCmdSeq)
    SetTimer(() => BootFinishRamp(100), -120)
}

BootFinishRamp(pct) {
    global mainUiEntered, mainUiEntering, bootCmdSeq, bootPct
    if mainUiEntered || !mainUiEntering
        return
    pct := Integer(pct)
    bootPct := pct
    bootCmdSeq += 1
    ApplyBootToPage(true, Min(100, pct), pct >= 100 ? "即将完成" : "正在加载", pct >= 100 ? "马上进入…" : "正在准备界面…", bootCmdSeq)
    if pct >= 100 {
        SetTimer(FinishEnterMainUiNow, -100)
        return
    }
    SetTimer(() => BootFinishRamp(100), -100)
}

FinishEnterMainUiNow(*) {
    global mainUiEntered, mainUiEntering, bootOn, bootPct, bootCmdSeq
    SetTimer(FinishEnterMainUiNow, 0)
    if mainUiEntered
        return
    mainUiEntered := true
    mainUiEntering := false
    bootOn := false
    bootPct := 100
    HideNativeBoot()
    HideLoadSplash()
    bootCmdSeq += 1
    ApplyBootToPage(false, 100, "", "", bootCmdSeq)
}

SyncBootUi(*) {
    global evReady, uiReady, wvCore, bootOn, bootPct, pendingBootMsg, pendingBootHint, mainUiEntered, bootCmdSeq
    if !uiReady || !IsObject(wvCore)
        return
    if mainUiEntered {
        HideLoadSplash()
        return
    }
    if evReady || EsAlive() {
        FinishEnterMainUi()
        return
    }
    FlushPendingBoot()
    if bootOn {
        bootCmdSeq += 1
        ApplyBootToPage(true, BootDisplayPct(bootPct), pendingBootMsg, pendingBootHint, bootCmdSeq)
    }
}

; ── WebView2 启动圆圈（不用 GDI/ActiveX 遮罩）────────────────────────
ShowBootStub(msg := "正在加载…", title := "正在加载", pct := 8) {
    global wvCore, pageNavIssued, uiReady, bootPct, pendingBootMsg, pendingBootHint, bootStubShown
    if pageNavIssued || uiReady || !IsObject(wvCore)
        return
    pct := Max(1, Min(99, Integer(pct)))
    bootPct := Max(Integer(bootPct), pct)
    pendingBootMsg := title
    pendingBootHint := msg
    vis := BootDisplayPct(bootPct)
    if !bootStubShown {
        bootStubShown := true
        try wvCore.NavigateToString(BootStubHtml(msg, title, vis))
        return
    }
    ; 已显示占位页：只改 DOM，避免反复 Navigate 闪/卡
    t := JsQuote(title), m := JsQuote(msg)
    js := "try{window.__stubSet&&window.__stubSet(" Integer(vis) "," t "," m ")}catch(e){}"
    try wvCore.ExecuteScriptAsync(js)
}

ShowNativeBoot(msg := "正在加载…", title := "正在加载", pct := 8) {
    ShowBootStub(msg, title, pct)
}
HideNativeBoot(*) {
    SetTimer(PulseNativeBoot, 0)
}
PulseNativeBoot(*) {
}
DrawNativeBootRing(*) {
    return 0
}

ShowLoadSplash(msg := "正在加载本地搜索…", force := false, pct := 0) {
    global bootPct, uiReady, mainUiEntered
    if uiReady || mainUiEntered
        return
    if pct <= 0
        pct := Max(8, Integer(bootPct))
    ShowBootStub(String(msg), "正在加载", pct)
}
PumpLoadSplash(*) {
}
PulseLoadSplash(*) {
}
HideLoadSplash(*) {
    HideNativeBoot()
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

; 列表用：按扩展名共用图标（不按每个 exe/lnk 路径提图标），首屏快很多
ShellIconUrlList(path := "", isDir := false) {
    path := String(path)
    if !!isDir
        return ShellIconUrl(path, true)
    SplitPath path, , , &ext
    ext := StrLower(ext)
    if ext = ""
        return ShellIconUrl(path, false, "file")
    return ShellIconUrl(path, false, ext)
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
        ; _a2：避开旧版抠黑底导致的发灰缓存（如 cmd.exe）
        if ext = "exe" || ext = "lnk" || ext = "ico" || ext = "dll" {
            sum := 0
            loop parse path {
                sum := (sum * 33 + Ord(A_LoopField)) & 0x7FFFFFFF
            }
            key := ext "_a2_" Format("{:08x}", sum)
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
        ; 不永久缓存失败，下次刷新可重试（UWP/短路径常需兜底）
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
ExtractIconFromFile(path, size := 32, index := 0) {
    if path = "" || (!FileExist(path) && !RegExMatch(path, "i)\\shell32\.dll$"))
        return 0
    hIcon := 0
    n := DllCall("User32\PrivateExtractIconsW", "WStr", path
        , "Int", index, "Int", size, "Int", size, "Ptr*", &hIcon, "Ptr", 0, "UInt", 1, "UInt", 0, "UInt")
    if n >= 1 && hIcon
        return hIcon
    hLarge := 0, hSmall := 0
    if DllCall("shell32\ExtractIconExW", "WStr", path, "Int", index, "Ptr*", &hLarge, "Ptr*", &hSmall, "UInt", 1) {
        if hSmall
            try DllCall("DestroyIcon", "Ptr", hSmall)
        if hLarge
            return hLarge
    }
    return 0
}

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
    hIcon := 0
    SplitPath path, , , &pathExt
    pathExt := StrLower(pathExt)
    ; exe/dll/ico：优先直接抽内嵌图标，避免 SHGetFileInfo 壳层图标异常
    if !isDir && (forceExt = "" || forceExt = "realpath") && path != "" && FileExist(path)
        && (pathExt = "exe" || pathExt = "dll" || pathExt = "ico") {
        hIcon := ExtractIconFromFile(path, 32)
    }
    if !hIcon && DllCall("shell32\SHGetFileInfoW", "WStr", query, "UInt", attrs
        , "Ptr", sfi, "UInt", sfi.Size, "UInt", flags, "Ptr")
    hIcon := NumGet(sfi, 0, "Ptr")
    ; SHGetFileInfo 失败时：PrivateExtractIcons / ExtractIconEx 直接抽 exe 图标
    if !hIcon && path != "" && FileExist(path) && !isDir && forceExt = "" {
        hIcon := ExtractIconFromFile(path, 32)
    }
    ; 仍失败 → shell32 默认应用程序图标
    if !hIcon {
        hIcon := ExtractIconFromFile(A_WinDir "\System32\shell32.dll", 32, 2)
    }
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
    hasRealAlpha := false  ; 已有透明通道则勿再抠纯黑（否则 cmd.exe 黑窗体会被挖空发灰）
    n := w * h
    loop n {
        off := (A_Index - 1) * 4
        b := NumGet(ppv, off, "UChar")
        g := NumGet(ppv, off + 1, "UChar")
        r := NumGet(ppv, off + 2, "UChar")
        a := NumGet(ppv, off + 3, "UChar")
        if a < 255
            hasRealAlpha := true
        if a > 0 && (r > 8 || g > 8 || b > 8)
            hasContent := true
        if a = 255 && r = 0 && g = 0 && b = 0
            hasOpaqueBlack := true
    }
    if hasRealAlpha || !(hasContent && hasOpaqueBlack)
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

; ── AHK run/get/sys config files（必须 HELPME_HOME\command_ext\ahk\config）──
HasHelpmeHome() {
    home := ""
    try home := EnvGet("HELPME_HOME")
    return Trim(String(home)) != ""
}

ResolveAhkConfigDir() {
    home := ""
    try home := EnvGet("HELPME_HOME")
    home := Trim(String(home))
    if home = ""
        return ""
    return RTrim(home, "\/") "\command_ext\ahk\config"
}

NormalizeAhkConfigName(name) {
    n := StrLower(Trim(String(name)))
    n := RegExReplace(n, "\.txt$", "")
    if n = "run" || n = "runconfig"
        return "runconfig"
    if n = "get" || n = "getconfig"
        return "getconfig"
    if n = "sys" || n = "sysconfig"
        return "sysconfig"
    if n = "emoji" || n = "emoji_config" || n = "emojiconfig"
        return "emoji"
    return ""
}

AhkConfigPath(name) {
    n := NormalizeAhkConfigName(name)
    if n = ""
        return ""
    return ResolveAhkConfigDir() "\" n ".txt"
}

ReadAhkConfigText(path, &encUsed := "") {
    encUsed := "UTF-8"
    if !FileExist(path)
        return ""
    ; 读 BOM / 字节是否合法 UTF-8，避免把 UTF-8 文件按 CP0 读成乱码，或反过来
    isUtf8 := false
    try {
        f := FileOpen(path, "r")
        if IsObject(f) {
            b0 := -1, b1 := -1, b2 := -1
            try b0 := f.ReadUChar()
            try b1 := f.ReadUChar()
            try b2 := f.ReadUChar()
            f.Seek(0)
            raw := Buffer(f.Length)
            f.RawRead(raw)
            f.Close()
            if b0 = 0xEF && b1 = 0xBB && b2 = 0xBF
                isUtf8 := true
            else
                isUtf8 := AhkConfigBytesAreUtf8(raw)
        }
    }
    if isUtf8 {
        try {
            t := FileRead(path, "UTF-8")
            encUsed := "UTF-8"
            return String(t)
        }
    }
    try {
        t := FileRead(path, "CP0")
        encUsed := "CP0"
        return String(t)
    }
    try {
        t := FileRead(path, "UTF-8")
        encUsed := "UTF-8"
        return String(t)
    }
    try {
        t := FileRead(path)
        encUsed := ""
        return String(t)
    }
    return ""
}

; 校验原始字节是否为合法 UTF-8（允许无 BOM）
AhkConfigBytesAreUtf8(buf) {
    if !IsObject(buf)
        return false
    n := buf.Size
    i := 0
    ; skip BOM
    if n >= 3 && NumGet(buf, 0, "UChar") = 0xEF && NumGet(buf, 1, "UChar") = 0xBB && NumGet(buf, 2, "UChar") = 0xBF
        i := 3
    hasMulti := false
    while i < n {
        c := NumGet(buf, i, "UChar")
        if c < 0x80 {
            i += 1
            continue
        }
        if (c & 0xE0) = 0xC0 {
            if i + 1 >= n
                return false
            c1 := NumGet(buf, i + 1, "UChar")
            if (c1 & 0xC0) != 0x80
                return false
            hasMulti := true
            i += 2
            continue
        }
        if (c & 0xF0) = 0xE0 {
            if i + 2 >= n
                return false
            c1 := NumGet(buf, i + 1, "UChar"), c2 := NumGet(buf, i + 2, "UChar")
            if (c1 & 0xC0) != 0x80 || (c2 & 0xC0) != 0x80
                return false
            hasMulti := true
            i += 3
            continue
        }
        if (c & 0xF8) = 0xF0 {
            if i + 3 >= n
                return false
            c1 := NumGet(buf, i + 1, "UChar"), c2 := NumGet(buf, i + 2, "UChar"), c3 := NumGet(buf, i + 3, "UChar")
            if (c1 & 0xC0) != 0x80 || (c2 & 0xC0) != 0x80 || (c3 & 0xC0) != 0x80
                return false
            hasMulti := true
            i += 4
            continue
        }
        return false
    }
    ; 纯 ASCII 也算 UTF-8；含多字节更可信
    return true
}

; 简单启发式：含替换符则视为解码失败
AhkConfigTextLooksOk(t) {
    t := String(t)
    if t = ""
        return false
    if InStr(t, "�")
        return false
    if !RegExMatch(t, "(?m)^[^#\r\n][^=\r\n]*=|【|#")
        return false
    return true
}

DetectAhkConfigWriteEnc(path) {
    if !FileExist(path)
        return "UTF-8"  ; 新文件默认 UTF-8，与现有 HELPME 配置一致
    try {
        f := FileOpen(path, "r")
        if IsObject(f) {
            b0 := -1, b1 := -1, b2 := -1
            try b0 := f.ReadUChar()
            try b1 := f.ReadUChar()
            try b2 := f.ReadUChar()
            f.Seek(0)
            raw := Buffer(f.Length)
            f.RawRead(raw)
            f.Close()
            if b0 = 0xEF && b1 = 0xBB && b2 = 0xBF
                return "UTF-8"
            if AhkConfigBytesAreUtf8(raw)
                return "UTF-8"
        }
    }
    return "CP0"
}

B64DecodeToUtf8Text(b64) {
    b64 := RegExReplace(String(b64), "\s+")
    if b64 = ""
        return ""
    size := 0
    if !DllCall("crypt32\CryptStringToBinaryW", "WStr", b64, "UInt", 0, "UInt", 1, "Ptr", 0, "UInt*", &size, "Ptr", 0, "Ptr", 0)
        return ""
    buf := Buffer(size)
    if !DllCall("crypt32\CryptStringToBinaryW", "WStr", b64, "UInt", 0, "UInt", 1, "Ptr", buf, "UInt*", &size, "Ptr", 0, "Ptr", 0)
        return ""
    return StrGet(buf, size, "UTF-8")
}

EmitAhkConfigResult(name, ok, msg := "", text := "", path := "") {
    global wvCore
    if !IsObject(wvCore)
        return
    if path = "" && name != ""
        path := AhkConfigPath(name)
    payload := '{"name":' JStr(name)
        . ',"ok":' (ok ? "true" : "false")
        . ',"message":' JStr(msg)
        . ',"text":' JStr(text)
        . ',"path":' JStr(path)
        . "}"
    js := "try{window.__setAhkConfig&&window.__setAhkConfig(" payload ")}catch(e){}"
    try wvCore.ExecuteScriptAsync(js)
}

ExpandAhkEnvPath(s) {
    s := String(s ?? "")
    if s = ""
        return ""
    loop {
        if !RegExMatch(s, "%([^%]+)%", &m)
            break
        val := ""
        try val := EnvGet(m[1])
        s := StrReplace(s, m[0], String(val), , , 1)
        if A_Index > 20
            break
    }
    return s
}

EmitCfgIconResult(id, kind, path, url) {
    global wvCore
    if !IsObject(wvCore)
        return
    payload := '{"id":' JStr(id)
        . ',"kind":' JStr(kind)
        . ',"path":' JStr(path)
        . ',"url":' JStr(url)
        . "}"
    js := "try{window.__setCfgIcon&&window.__setCfgIcon(" payload ")}catch(e){}"
    try wvCore.ExecuteScriptAsync(js)
}

PushCfgIcon(id, kind, pathB64 := "") {
    id := Trim(String(id))
    kind := StrLower(Trim(String(kind)))
    path := ""
    if pathB64 != ""
        path := B64DecodeToUtf8Text(pathB64)
    path := ExpandAhkEnvPath(path)
    url := ""
    try {
        if kind = "cmd" {
            url := ShellIconUrl(A_WinDir "\System32\cmd.exe", false)
        } else if kind = "folder" {
            if path != ""
                url := ShellIconUrl(path, true)
            else
                url := ShellIconUrl("", true, "folder")
        } else if kind = "exe" || kind = "file" {
            if path != ""
                url := ShellIconUrl(path, false)
        }
    } catch as e {
        AppLog("PushCfgIcon " e.Message)
    }
    EmitCfgIconResult(id, kind, path, url)
}

PushAhkConfigFile(name) {
    n := NormalizeAhkConfigName(name)
    if n = "" {
        EmitAhkConfigResult(name, false, "未知配置: " name)
        return
    }
    if !HasHelpmeHome() {
        EmitAhkConfigResult(n, false, "必须设置环境变量 HELPME_HOME 才能读写运行配置", "", "")
        return
    }
    path := AhkConfigPath(n)
    if path = "" || !FileExist(path) {
        EmitAhkConfigResult(n, false, "文件不存在: " path, "", path)
        return
    }
    enc := ""
    text := ReadAhkConfigText(path, &enc)
    EmitAhkConfigResult(n, true, "已加载 (" enc ")", text, path)
}

SaveAhkConfigFile(name, b64) {
    n := NormalizeAhkConfigName(name)
    if n = "" {
        EmitAhkConfigResult(name, false, "未知配置: " name)
        return
    }
    if !HasHelpmeHome() {
        EmitAhkConfigResult(n, false, "必须设置环境变量 HELPME_HOME 才能保存配置", "", "")
        return
    }
    path := AhkConfigPath(n)
    dir := ResolveAhkConfigDir()
    if dir = "" || path = "" {
        EmitAhkConfigResult(n, false, "必须设置环境变量 HELPME_HOME 才能保存配置", "", "")
        return
    }
    try DirCreate dir
    text := B64DecodeToUtf8Text(b64)
    ; normalize newlines
    text := StrReplace(text, "`r`n", "`n")
    text := StrReplace(text, "`r", "`n")
    text := StrReplace(text, "`n", "`r`n")
    enc := DetectAhkConfigWriteEnc(path)
    ; emoji / 含非 ASCII：一律 UTF-8（clipboard 索引也按 UTF-8 读，写 CP0 会表现为「汉字掉了」）
    if n = "emoji" || RegExMatch(text, "[^\x00-\x7F]")
        enc := "UTF-8"
    ; 若现文件是误存成 CP0、但旁边有 UTF-8 备份且当前看起来像乱码视图源，仍按 UTF-8 写回
    if enc = "CP0" {
        bak := path ".bak"
        if FileExist(bak) {
            try {
                f := FileOpen(bak, "r")
                if IsObject(f) {
                    b0 := -1, b1 := -1, b2 := -1
                    try b0 := f.ReadUChar()
                    try b1 := f.ReadUChar()
                    try b2 := f.ReadUChar()
                    f.Close()
                    if b0 = 0xEF && b1 = 0xBB && b2 = 0xBF
                        enc := "UTF-8"
                }
            }
        }
    }
    try {
        if FileExist(path)
            FileCopy(path, path ".bak", 1)
    }
    try {
        if FileExist(path)
            FileDelete path
        ; UTF-8 带 BOM，与 HELPME 原配置文件一致；ANSI 用 CP0
        writeEnc := (enc = "CP0") ? "CP0" : "UTF-8"
        f := FileOpen(path, "w", writeEnc)
        if !IsObject(f)
            throw Error("无法打开文件写入")
        f.Write(text)
        f.Close()
        EmitAhkConfigResult(n, true, "保存成功 (" writeEnc ")", text, path)
        ; 系统配置生效需重启脚本（箭头函数不能用 {} 多语句，会当成对象字面量）
        if n = "sysconfig"
            SetTimer(DashboardRelaunchAfterSysSave, -900)
        else if n = "emoji"
            ScheduleEmojiConfigEmbed()
    } catch as e {
        EmitAhkConfigResult(n, false, "保存失败: " e.Message)
    }
}

DashboardRelaunchAfterSysSave(*) {
    try DashboardRelaunchSelf()
    ExitApp
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
    if msg = "uiReady" || SubStr(msg, 1, 8) = "uiReady|" {
        global uiReady, evReady, dashboardStandalone, mainUiEntered, lastUiMode, bootShownAt, SEARCH_DIR
        uiMode := "file"
        if SubStr(msg, 1, 8) = "uiReady|"
            uiMode := Trim(SubStr(msg, 9))
        if uiMode != "handle" && uiMode != "info" && uiMode != "config"
            uiMode := "file"
        lastUiMode := uiMode
        try FileOpen(SEARCH_DIR "\last_ui_mode.txt", "w", "UTF-8").Write(uiMode)
        uiReady := true
        SetTimer(WatchUiReady, 0)
        ; 非搜索页：立刻揭主界面，不等索引转圈 / 不主动空搜
        if uiMode != "file" {
            bootShownAt := A_TickCount - 2000
            if !mainUiEntered
                FinishEnterMainUi()
            else
        SyncBootUi()
            HideNativeBoot()
            HideLoadSplash()
            if dashboardStandalone && !mainUiEntered
                SetTimer(ShowWindow, -1)
            SetTimer(StartEverythingBootOnce, -400)
        SetTimer(PushCatIcons, -200)
        SetTimer(PushCatIcons, -800)
        SetTimer(PushDrives, -200)
        SetTimer(PushDrives, -800)
            return
        }
        ; 第一次打开：不等 Everything，先揭主界面（绿圈只等 WebView ~1s）
        if !mainUiEntered
            FinishEnterMainUi()
        else
            SyncBootUi()
        HideNativeBoot()
        HideLoadSplash()
        if dashboardStandalone && !mainUiEntered
            SetTimer(ShowWindow, -1)
        SetTimer(StartEverythingBootOnce, -120)
        SetTimer(PushCatIcons, -200)
        SetTimer(PushCatIcons, -800)
        SetTimer(PushDrives, -200)
        SetTimer(PushDrives, -800)
        if evReady || EsAlive()
            SetTimer(RequestFrontendSearch, -150)
        else
            SetTimer(PushIndexPendingHint, -200)
        return
    }
    if SubStr(msg, 1, 12) = "sessionMode|" {
        global lastUiMode, SEARCH_DIR
        mode := Trim(SubStr(msg, 13))
        if mode != "handle" && mode != "info" && mode != "config"
            mode := "file"
        lastUiMode := mode
        if mode != "file"
            try CancelActiveSearch("sessionMode-" mode)
        try FileOpen(SEARCH_DIR "\last_ui_mode.txt", "w", "UTF-8").Write(mode)
        return
    }
    if SubStr(msg, 1, 12) = "searchCancel" {
        reason := "ui"
        if SubStr(msg, 13, 1) = "|"
            reason := Trim(SubStr(msg, 14))
        try CancelActiveSearch(reason)
        return
    }
    if msg = "rgEnsure" {
        if ResolveRgExe() != "" {
            EmitRgReady(true)
            return
        }
        SetTimer(EnsureRipgrepReady, -1)
        return
    }
    if SubStr(msg, 1, 11) = "searchText|" {
        ScheduleRgSearch(SubStr(msg, 12))
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
    if SubStr(msg, 1, 9) = "procView|" {
        ; 已取消重型进程监控轮询，忽略开启请求
        StopProcMonitor()
        return
    }
    if SubStr(msg, 1, 9) = "procList|" {
        return
    }
    if SubStr(msg, 1, 9) = "portList|" {
        return
    }
    if SubStr(msg, 1, 8) = "sysInfo|" {
        global sysInfoForce
        sysInfoForce := (SubStr(msg, 9) = "1")
        SetTimer(PushSysInfo, -1)
        return
    }
    if SubStr(msg, 1, 8) = "cfgIcon|" {
        ; cfgIcon|id|kind|b64path
        rest := SubStr(msg, 9)
        p1 := InStr(rest, "|")
        if !p1 {
            return
        }
        id := Trim(SubStr(rest, 1, p1 - 1))
        rest2 := SubStr(rest, p1 + 1)
        p2 := InStr(rest2, "|")
        if !p2 {
            PushCfgIcon(id, rest2, "")
            return
        }
        kind := Trim(SubStr(rest2, 1, p2 - 1))
        b64 := SubStr(rest2, p2 + 1)
        PushCfgIcon(id, kind, b64)
        return
    }
    if SubStr(msg, 1, 11) = "configLoad|" {
        PushAhkConfigFile(Trim(SubStr(msg, 12)))
        return
    }
    if SubStr(msg, 1, 11) = "configSave|" {
        ; configSave|name|b64utf8
        rest := SubStr(msg, 12)
        p := InStr(rest, "|")
        if !p {
            EmitAhkConfigResult("", false, "保存参数无效")
            return
        }
        name := Trim(SubStr(rest, 1, p - 1))
        b64 := SubStr(rest, p + 1)
        SaveAhkConfigFile(name, b64)
        return
    }
    if SubStr(msg, 1, 13) = "handleSearch|" {
        StartHandleSearch(SubStr(msg, 14))
        return
    }
    if SubStr(msg, 1, 9) = "copyText|" {
        try A_Clipboard := SubStr(msg, 10)
        return
    }
    if SubStr(msg, 1, 9) = "procKill|" {
        raw := Trim(SubStr(msg, 10))
        killed := []
        for part in StrSplit(raw, ",") {
            pid := Integer(Trim(part))
            if pid <= 0
                continue
            try ProcessClose(pid)
            ; 稍候确认是否已退出
            Sleep 40
            still := false
            try still := !!ProcessExist(pid)
            catch
                still := false
            if !still
                killed.Push(pid)
            else {
                ; 再试一次强关
                try ProcessClose(pid)
                Sleep 60
                try still := !!ProcessExist(pid)
                catch
                    still := false
                if !still
                    killed.Push(pid)
            }
        }
        if killed.Length {
            EmitProcKilled(killed)
            SetTimer(PushPortList, -80)
        }
        return
    }
    if msg = "minimize" {
        MinimizeWindow()
        return
    }
    if msg = "maximize" {
        ToggleMaximizeWindow()
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
    if SubStr(msg, 1, 8) = "openTxt|" {
        p := ExpandAhkEnvPath(SubStr(msg, 9))
        p := Trim(p)
        if p = ""
            return
        try Run('notepad.exe "' p '"')
        catch {
            try Run(p)
        }
        return
    }
    if SubStr(msg, 1, 5) = "open|" {
        p := ExpandAhkEnvPath(SubStr(msg, 6))
        try Run(p)
        return
    }
    if SubStr(msg, 1, 9) = "openPath|" {
        p := ExpandAhkEnvPath(SubStr(msg, 10))
        p := Trim(p)
        if p = ""
            return
        if RegExMatch(p, "i)^[A-Za-z]:\\?$") {
            try Run('explorer.exe "' StrUpper(SubStr(p, 1, 1)) ':\"')
            return
        }
        if DirExist(p) {
            try Run('explorer.exe "' p '"')
            return
        }
        if FileExist(p) {
            try Run('explorer.exe /select,"' p '"')
            return
        }
        ; 目录尚不存在时仍尝试打开父级
        SplitPath p, , &parent
        if parent != "" && DirExist(parent) {
            try Run('explorer.exe "' parent '"')
            return
        }
        try Run(p)
        return
    }
    if SubStr(msg, 1, 7) = "reveal|" {
        p := ExpandAhkEnvPath(SubStr(msg, 8))
        try Run('explorer.exe /select,"' p '"')
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
    global pendingSearch, pendingRgSearch, searchBusy, searchSeq, lastQuery, lastCat, lastSort, lastDrive, esSearchPid, rgSearchPid, searchCancelEpoch
    q := String(q)
    cat := String(cat)
    sort := String(sort)
    drive := String(drive)
    offset := Max(0, Integer(offset))
    ; 记住最近一次搜索条件（再次打开可复用）
    if offset = 0 {
        lastQuery := q
        lastCat := cat
        lastSort := sort
        lastDrive := drive
    }
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
    pendingRgSearch := ""
    ; 新查询（非翻页）立刻打断旧 es/rg + 抬升 cancel epoch
    if searchBusy && offset = 0 {
        searchCancelEpoch += 1
        if esSearchPid && ProcessExist(esSearchPid) {
            AppLog("ES preempt kill pid=" esSearchPid " for seq=" searchSeq)
            try ProcessClose(esSearchPid)
            esSearchPid := 0
        }
        if rgSearchPid && ProcessExist(rgSearchPid) {
            try ProcessClose(rgSearchPid)
            rgSearchPid := 0
        }
        ; 不要在这里挂短看门狗：会误杀紧接着启动的新搜索，推送假 0 条
    }
    if !searchBusy
        SetTimer(FlushPendingSearch, -20)
}

SearchBusyWatchdog(*) {
    global searchBusy, esSearchPid, rgSearchPid, pendingSearch, pendingRgSearch, searchCancelEpoch
    if !searchBusy
        return
    AppLog("SearchBusyWatchdog busy=1 es=" esSearchPid " rg=" rgSearchPid)
    ; 必须抬升 epoch，否则杀掉 es 后会被当成「搜完了 0 条」推给前端
    searchCancelEpoch += 1
    if esSearchPid && ProcessExist(esSearchPid) {
        try ProcessClose(esSearchPid)
        esSearchPid := 0
    }
    if rgSearchPid && ProcessExist(rgSearchPid) {
        try ProcessClose(rgSearchPid)
        rgSearchPid := 0
    }
    SetTimer(SearchBusyForceUnlock, -800)
}

; 取消后的轻量解锁：绝不抬 epoch / 杀进程，避免误伤紧接着的新 Everything 查询
SearchBusySoftClear(*) {
    global searchBusy, pendingSearch, pendingRgSearch, esSearchPid, rgSearchPid, searchRunDepth
    if !searchBusy
        return
    if Integer(searchRunDepth) > 0
        return
    if esSearchPid && ProcessExist(esSearchPid)
        return
    if rgSearchPid && ProcessExist(rgSearchPid)
        return
    AppLog("SearchBusySoftClear")
    searchBusy := false
    if IsObject(pendingRgSearch)
        SetTimer(FlushPendingRgSearch, -20)
    else if IsObject(pendingSearch)
        SetTimer(FlushPendingSearch, -20)
}

SearchBusyForceUnlock(*) {
    global searchBusy, pendingSearch, pendingRgSearch, esSearchPid, rgSearchPid, searchCancelEpoch
    if !searchBusy
        return
    AppLog("SearchBusyForceUnlock")
    searchCancelEpoch += 1
    if esSearchPid && ProcessExist(esSearchPid) {
        try ProcessClose(esSearchPid)
    }
    if rgSearchPid && ProcessExist(rgSearchPid) {
        try ProcessClose(rgSearchPid)
    }
    esSearchPid := 0
    rgSearchPid := 0
    searchBusy := false
    if IsObject(pendingRgSearch)
        SetTimer(FlushPendingRgSearch, -20)
    else if IsObject(pendingSearch)
        SetTimer(FlushPendingSearch, -20)
}

FlushPendingSearch(*) {
    global pendingSearch, pendingRgSearch, searchBusy, searchRunDepth
    if searchBusy
        return
    if !IsObject(pendingSearch)
        return
    searchBusy := true
    searchRunDepth := Integer(searchRunDepth) + 1
    p := pendingSearch
    pendingSearch := ""
    try {
        RunSearchNow(p.q, p.cat, p.sort, p.seq, p.HasProp("offset") ? p.offset : 0, p.HasProp("drive") ? p.drive : "")
    } catch as e {
        AppLog("FlushPendingSearch err " e.Message)
        try PushResults([], 0, 0, false)
    }
    searchRunDepth := Max(0, Integer(searchRunDepth) - 1)
    searchBusy := false
    if IsObject(pendingRgSearch)
        SetTimer(FlushPendingRgSearch, -20)
    else if IsObject(pendingSearch)
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
    maximize(*) {
        ToggleMaximizeWindow()
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
;PCFET0NUWVBFIGh0bWw+CjxodG1sIGxhbmc9InpoLUNOIj4KPGhlYWQ+CjxtZXRhIGNoYXJzZXQ9IlVURi04Ij4KPG1ldGEgbmFtZT0idmlld3BvcnQiIGNv
;bnRlbnQ9IndpZHRoPWRldmljZS13aWR0aCwgaW5pdGlhbC1zY2FsZT0xIj4KPHRpdGxlPuS7quihqOebmDwvdGl0bGU+CjwhLS0gbG9jYWxfc2VhcmNoX3Vp
;OjIwMjYtMDktMThlIC0tPgo8c3R5bGU+Cjpyb290IHsKICAtLWJnOiAjZjNmNGY3OwogIC0tcGFuZWw6ICNmZmZmZmY7CiAgLS1saW5lOiAjZTZlOGVlOwog
;IC0tdHh0OiAjMWYyNDMwOwogIC0tdHh0MjogIzZiNzI4NTsKICAtLXR4dDM6ICM5YWExYjI7CiAgLS1hY2M6ICMzYjgyZjY7CiAgLS1hY2MyOiAjMjU2M2Vi
;OwogIC0tbmFtZTogIzExMTgyNzsKICAtLW5hbWUtZXh0OiAjZWE1ODBjOwogIC0taGw6ICNmZWYwOGE7CiAgLS1obC10ZXh0OiAjODU0ZDBlOwogIC0tc2Vs
;OiAjZWVmMWY2OwogIC0tc2lkZTogI2Y1ZjZmOTsKICAtLWNocm9tZTogI2Y1ZjZmOTsKICAtLXNpZGUtdzogMTQ4cHg7CiAgLS1yaW5nOiAjZTQyMDc5Owog
;IC0tc2hhZG93OiAwIDEwcHggMzBweCByZ2JhKDIwLCAyOCwgNDUsIC4wOCk7CiAgLS1yOiAxMHB4OwogIGZvbnQtZmFtaWx5OiAiU2Vnb2UgVUkiLCAiTWlj
;cm9zb2Z0IFlhSGVpIFVJIiwgIlBpbmdGYW5nIFNDIiwgc2Fucy1zZXJpZjsKfQoqIHsgYm94LXNpemluZzogYm9yZGVyLWJveDsgfQpodG1sLCBib2R5IHsg
;bWFyZ2luOiAwOyBoZWlnaHQ6IDEwMCU7IGJhY2tncm91bmQ6IHZhcigtLWJnKTsgY29sb3I6IHZhcigtLXR4dCk7IG92ZXJmbG93OiBoaWRkZW47IH0KYnV0
;dG9uLCBpbnB1dCB7IGZvbnQ6IGluaGVyaXQ7IH0KI2FwcCB7IGRpc3BsYXk6IGZsZXg7IGZsZXgtZGlyZWN0aW9uOiBjb2x1bW47IGhlaWdodDogMTAwJTsg
;fQoKLyog5YWo5bGA77ya566A57qm57qk57uG57q15ZCR5rua5Yqo5p2hICovCiogewogIHNjcm9sbGJhci13aWR0aDogdGhpbjsKICBzY3JvbGxiYXItY29s
;b3I6ICNjMGM0Y2MgdHJhbnNwYXJlbnQ7Cn0KKjo6LXdlYmtpdC1zY3JvbGxiYXIgeyB3aWR0aDogNHB4OyBoZWlnaHQ6IDRweDsgfQoqOjotd2Via2l0LXNj
;cm9sbGJhci10cmFjayB7IGJhY2tncm91bmQ6IHRyYW5zcGFyZW50OyB9Cio6Oi13ZWJraXQtc2Nyb2xsYmFyLXRodW1iIHsKICBiYWNrZ3JvdW5kOiAjYzBj
;NGNjOyBib3JkZXItcmFkaXVzOiA5OTlweDsgYm9yZGVyOiAwOwogIG1pbi1oZWlnaHQ6IDI0cHg7Cn0KKjo6LXdlYmtpdC1zY3JvbGxiYXItdGh1bWI6aG92
;ZXIgeyBiYWNrZ3JvdW5kOiAjOWFhMWIyOyB9Cio6Oi13ZWJraXQtc2Nyb2xsYmFyLWNvcm5lciB7IGJhY2tncm91bmQ6IHRyYW5zcGFyZW50OyB9CgovKiBp
;bmRleGluZyAqLwojYm9vdCB7CiAgZGlzcGxheTogbm9uZTsgZmxleDogMTsgYWxpZ24taXRlbXM6IGNlbnRlcjsganVzdGlmeS1jb250ZW50OiBjZW50ZXI7
;CiAgZmxleC1kaXJlY3Rpb246IGNvbHVtbjsgZ2FwOiAyOHB4OyBiYWNrZ3JvdW5kOiAjZmZmOwp9CiNib290Lm9uIHsgZGlzcGxheTogZmxleDsgfQoucmlu
;Zy13cmFwIHsgd2lkdGg6IDE2OHB4OyBoZWlnaHQ6IDE2OHB4OyBwb3NpdGlvbjogcmVsYXRpdmU7IH0KLnJpbmctd3JhcCBzdmcgeyB3aWR0aDogMTAwJTsg
;aGVpZ2h0OiAxMDAlOyB0cmFuc2Zvcm06IHJvdGF0ZSgtOTBkZWcpOyB9Ci5yaW5nLWJnIHsgZmlsbDogbm9uZTsgc3Ryb2tlOiAjZWNlZmY0OyBzdHJva2Ut
;d2lkdGg6IDg7IH0KLnJpbmctZmcgeyBmaWxsOiBub25lOyBzdHJva2U6IHZhcigtLXJpbmcpOyBzdHJva2Utd2lkdGg6IDg7IHN0cm9rZS1saW5lY2FwOiBy
;b3VuZDsKICB0cmFuc2l0aW9uOiBzdHJva2UtZGFzaG9mZnNldCAuMzVzIGVhc2U7IH0KLnJpbmctbGFiZWwgewogIHBvc2l0aW9uOiBhYnNvbHV0ZTsgaW5z
;ZXQ6IDA7IGRpc3BsYXk6IGZsZXg7IGZsZXgtZGlyZWN0aW9uOiBjb2x1bW47CiAgYWxpZ24taXRlbXM6IGNlbnRlcjsganVzdGlmeS1jb250ZW50OiBjZW50
;ZXI7IGdhcDogNnB4Owp9Ci5yaW5nLWxhYmVsIC50MSB7IGZvbnQtc2l6ZTogMTZweDsgZm9udC13ZWlnaHQ6IDYwMDsgfQoucmluZy1sYWJlbCAudDIgeyBm
;b250LXNpemU6IDI4cHg7IGZvbnQtd2VpZ2h0OiA3MDA7IGNvbG9yOiAjMTExODI3OyB9Ci5ib290LWhpbnQgeyBjb2xvcjogdmFyKC0tdHh0Mik7IGZvbnQt
;c2l6ZTogMTNweDsgbWF4LXdpZHRoOiA1MjBweDsgdGV4dC1hbGlnbjogY2VudGVyOyBsaW5lLWhlaWdodDogMS42OyB9Ci5ib290LWhpbnQgYSB7IGNvbG9y
;OiB2YXIoLS1hY2MpOyB0ZXh0LWRlY29yYXRpb246IG5vbmU7IGN1cnNvcjogcG9pbnRlcjsgfQouYm9vdC1oaW50IGE6aG92ZXIgeyB0ZXh0LWRlY29yYXRp
;b246IHVuZGVybGluZTsgfQovKiDkuIrmrKHlgZzlnKjpnZ7mkJzntKLpobXvvJrpppblsY/nm7TmjqXlh7rkuLvnlYzpnaLvvIzkuI3mjKHnu7/lnIggKi8K
;aHRtbFtkYXRhLXNraXAtYm9vdD0iMSJdICNib290IHsgZGlzcGxheTogbm9uZSAhaW1wb3J0YW50OyB9Cmh0bWxbZGF0YS1za2lwLWJvb3Q9IjEiXSAjY2hy
;b21lLmhpZGRlbiB7IGRpc3BsYXk6IGZsZXggIWltcG9ydGFudDsgfQpodG1sW2RhdGEtc2tpcC1ib290PSIxIl0gI2FwcC5ib290aW5nICNmaWx0ZXItcmFp
;bCB7IGRpc3BsYXk6IG5vbmUgIWltcG9ydGFudDsgfQoKLyogdGl0bGViYXIgPSDku6rooajnm5jpgqPkuIDooYzvvJvmipjlj6Dnrq3lpLTkuI7kuIvmlrnm
;kJzntKLmoYbliJflr7npvZAgKi8KI3RpdGxlYmFyIHsKICBkaXNwbGF5OiBmbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBnYXA6IDA7IGZsZXgtc2hyaW5r
;OiAwOwogIG1pbi1oZWlnaHQ6IDM2cHg7IHBhZGRpbmc6IDA7IGJveC1zaXppbmc6IGJvcmRlci1ib3g7CiAgYmFja2dyb3VuZDogdmFyKC0tY2hyb21lKTsg
;Ym9yZGVyLWJvdHRvbTogMDsKICAtd2Via2l0LWFwcC1yZWdpb246IGRyYWc7IGFwcC1yZWdpb246IGRyYWc7IHVzZXItc2VsZWN0OiBub25lOwp9CiN0aXRs
;ZWJhciAubm8tZHJhZywgI3RpdGxlYmFyIGJ1dHRvbiB7CiAgLXdlYmtpdC1hcHAtcmVnaW9uOiBuby1kcmFnOyBhcHAtcmVnaW9uOiBuby1kcmFnOwp9CiN0
;aXRsZWJhciAudGItYnJhbmQgewogIGRpc3BsYXk6IGlubGluZS1mbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBnYXA6IDhweDsgZmxleC1zaHJpbms6IDA7
;CiAgd2lkdGg6IHZhcigtLXNpZGUtdyk7IHBhZGRpbmc6IDAgMTBweDsgYm94LXNpemluZzogYm9yZGVyLWJveDsKICBjb2xvcjogdmFyKC0tdHh0KTsgZm9u
;dC1zaXplOiAxM3B4OyBmb250LXdlaWdodDogNjUwOyBsZXR0ZXItc3BhY2luZzogLjAxZW07Cn0KI3RpdGxlYmFyIC50Yi1pY28gewogIHdpZHRoOiAxNnB4
;OyBoZWlnaHQ6IDE2cHg7IGRpc3BsYXk6IGJsb2NrOyBjb2xvcjogIzA0Nzg1NzsgZmxleC1zaHJpbms6IDA7Cn0KI3RpdGxlYmFyIC50Yi1zcGFjZSB7IGZs
;ZXg6IDE7IG1pbi13aWR0aDogOHB4OyBhbGlnbi1zZWxmOiBzdHJldGNoOyB9CiN0aXRsZWJhciAudGItd2luIHsKICBkaXNwbGF5OiBmbGV4OyBhbGlnbi1p
;dGVtczogc3RyZXRjaDsgZmxleC1zaHJpbms6IDA7IGhlaWdodDogMzZweDsKfQojdGl0bGViYXIgLnRiLXdpbiBidXR0b24gewogIHdpZHRoOiA0NnB4OyBo
;ZWlnaHQ6IDEwMCU7IHBhZGRpbmc6IDA7IGJvcmRlcjogMDsgYmFja2dyb3VuZDogdHJhbnNwYXJlbnQ7CiAgY29sb3I6IHZhcigtLXR4dDIpOyBjdXJzb3I6
;IHBvaW50ZXI7CiAgZGlzcGxheTogaW5saW5lLWZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGp1c3RpZnktY29udGVudDogY2VudGVyOwp9CiN0aXRsZWJh
;ciAudGItd2luIGJ1dHRvbjpob3ZlciB7IGJhY2tncm91bmQ6ICNlOGViZjA7IGNvbG9yOiB2YXIoLS10eHQpOyB9CiN0aXRsZWJhciAudGItd2luICNidG4t
;d2luLWNsb3NlOmhvdmVyIHsgYmFja2dyb3VuZDogI2U4MTEyMzsgY29sb3I6ICNmZmY7IH0KI3RpdGxlYmFyIC50Yi13aW4gYnV0dG9uIHN2ZyB7IHdpZHRo
;OiAxMHB4OyBoZWlnaHQ6IDEwcHg7IGRpc3BsYXk6IGJsb2NrOyB9CiNmaWx0ZXItcmFpbCB7CiAgZGlzcGxheTogZmxleDsgYWxpZ24taXRlbXM6IGNlbnRl
;cjsgZ2FwOiA4cHg7IGZsZXgtc2hyaW5rOiAxOyBtaW4td2lkdGg6IDA7CiAgcGFkZGluZzogNHB4IDA7IG1hcmdpbjogMDsKfQojYXBwLmJvb3RpbmcgI2Zp
;bHRlci1yYWlsLAojYXBwLmhpZGUtZmlsdGVycyAjZmlsdGVyLXJhaWwgeyBkaXNwbGF5OiBub25lICFpbXBvcnRhbnQ7IH0KI2ZpbHRlci1iYXIsCiNoYW5k
;bGUtdGFnLWJhciwKI2NmZy1zZWFyY2gtdGFncyB7CiAgZGlzcGxheTogbm9uZTsgZmxleC13cmFwOiB3cmFwOyBhbGlnbi1pdGVtczogY2VudGVyOyBnYXA6
;IDZweDsgbWluLXdpZHRoOiAwOwp9CiNhcHAucmFpbC1maWxlICNmaWx0ZXItYmFyLAojYXBwLnJhaWwtaGFuZGxlICNoYW5kbGUtdGFnLWJhciwKI2FwcC5y
;YWlsLWNvbmZpZyAjY2ZnLXNlYXJjaC10YWdzIHsgZGlzcGxheTogZmxleDsgfQojYXBwLnJhaWwtZmlsZSAjZmlsdGVyLWFkZCwKI2FwcC5yYWlsLWhhbmRs
;ZSAjZmlsdGVyLWFkZCB7IGRpc3BsYXk6IGlubGluZS1mbGV4OyB9CiNhcHAucmFpbC1jb25maWcgI2ZpbHRlci1hZGQgeyBkaXNwbGF5OiBub25lICFpbXBv
;cnRhbnQ7IH0KLmZpbHRlci1jaGlwIHsKICBkaXNwbGF5OiBpbmxpbmUtZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsgZ2FwOiA1cHg7CiAgaGVpZ2h0OiAy
;MnB4OyBwYWRkaW5nOiAwIDEwcHg7IGJvcmRlcjogMXB4IHNvbGlkIHZhcigtLWxpbmUpOwogIGJvcmRlci1yYWRpdXM6IDk5OXB4OyBiYWNrZ3JvdW5kOiAj
;ZmJmYmZkOyBjb2xvcjogdmFyKC0tdHh0Mik7CiAgZm9udC1zaXplOiAxMnB4OyBjdXJzb3I6IHBvaW50ZXI7IGxpbmUtaGVpZ2h0OiAyMHB4OyB3aGl0ZS1z
;cGFjZTogbm93cmFwOwp9Ci5maWx0ZXItY2hpcCBzdmcgeyB3aWR0aDogMTJweDsgaGVpZ2h0OiAxMnB4OyBkaXNwbGF5OiBibG9jazsgZmxleC1zaHJpbms6
;IDA7IH0KLmZpbHRlci1jaGlwOmhvdmVyIHsgYmFja2dyb3VuZDogI2VlZjFmNjsgY29sb3I6IHZhcigtLXR4dCk7IH0KLmZpbHRlci1jaGlwLm9uIHsKICBi
;YWNrZ3JvdW5kOiAjZWZmNmZmOyBib3JkZXItY29sb3I6ICM5M2M1ZmQ7IGNvbG9yOiAjMWQ0ZWQ4OyBmb250LXdlaWdodDogNjAwOwp9Ci5maWx0ZXItY2hp
;cC5wYXRoLWNoaXA6bm90KC5vbikgewogIGJvcmRlci1zdHlsZTogZGFzaGVkOyBjb2xvcjogIzY0NzQ4YjsKfQojZmlsdGVyLWFkZCB7CiAgZGlzcGxheTog
;bm9uZTsgd2lkdGg6IDIycHg7IGhlaWdodDogMjJweDsgcGFkZGluZzogMDsgZmxleC1zaHJpbms6IDA7CiAgYWxpZ24taXRlbXM6IGNlbnRlcjsganVzdGlm
;eS1jb250ZW50OiBjZW50ZXI7CiAgYm9yZGVyOiAxcHggZGFzaGVkICNjYmQ1ZTE7IGJvcmRlci1yYWRpdXM6IDUwJTsKICBiYWNrZ3JvdW5kOiAjZmZmOyBj
;b2xvcjogIzY0NzQ4YjsgY3Vyc29yOiBwb2ludGVyOyBsaW5lLWhlaWdodDogMTsKfQojZmlsdGVyLWFkZDpob3ZlciB7CiAgYm9yZGVyLWNvbG9yOiAjODZl
;ZmFjOyBiYWNrZ3JvdW5kOiAjZWNmZGY1OyBjb2xvcjogIzA0Nzg1NzsKfQojZmlsdGVyLWFkZCBzdmcgeyB3aWR0aDogMTJweDsgaGVpZ2h0OiAxMnB4OyBk
;aXNwbGF5OiBibG9jazsgfQoKLyogY2hyb21lICovCiNjaHJvbWUgeyBkaXNwbGF5OiBmbGV4OyBmbGV4LWRpcmVjdGlvbjogY29sdW1uOyBmbGV4OiAxOyBt
;aW4taGVpZ2h0OiAwOyB9CiNjaHJvbWUuaGlkZGVuIHsgZGlzcGxheTogbm9uZTsgfQojdG9wIHsKICBoZWlnaHQ6IDQ4cHg7IGRpc3BsYXk6IGdyaWQ7CiAg
;Z3JpZC10ZW1wbGF0ZS1jb2x1bW5zOiB2YXIoLS1zaWRlLXcpIG1pbm1heCgwLCAxZnIpOwogIGFsaWduLWl0ZW1zOiBzdHJldGNoOyBwYWRkaW5nOiAwIDEw
;cHggMCAwOyBiYWNrZ3JvdW5kOiB2YXIoLS1jaHJvbWUpOwogIGJvcmRlci1ib3R0b206IDA7IGJveC1zaXppbmc6IGJvcmRlci1ib3g7CiAgLXdlYmtpdC1h
;cHAtcmVnaW9uOiBkcmFnOyBhcHAtcmVnaW9uOiBkcmFnOwp9CiN0b3AgLm5vLWRyYWcsICN0b3AgYnV0dG9uLCAjdG9wIGlucHV0IHsKICAtd2Via2l0LWFw
;cC1yZWdpb246IG5vLWRyYWc7IGFwcC1yZWdpb246IG5vLWRyYWc7Cn0KI2RyaXZlLXdyYXAgewogIHBvc2l0aW9uOiByZWxhdGl2ZTsgd2lkdGg6IDEwMCU7
;CiAgYm9yZGVyLXJpZ2h0OiAwOyBiYWNrZ3JvdW5kOiB2YXIoLS1jaHJvbWUpOwogIGRpc3BsYXk6IGZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7Cn0KI2J0
;bi1kcml2ZSB7CiAgZGlzcGxheTogZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsgZ2FwOiA4cHg7CiAgd2lkdGg6IDEwMCU7IGhlaWdodDogMTAwJTsgcGFk
;ZGluZzogMCAxMHB4OwogIGJvcmRlcjogMDsgYm9yZGVyLXJhZGl1czogMDsgYmFja2dyb3VuZDogdHJhbnNwYXJlbnQ7CiAgY29sb3I6IHZhcigtLXR4dCk7
;IGZvbnQtc2l6ZTogMTMuNXB4OyBmb250LXdlaWdodDogNjAwOwogIGN1cnNvcjogcG9pbnRlcjsgdGV4dC1hbGlnbjogbGVmdDsKfQojYnRuLWRyaXZlOmhv
;dmVyIHsgYmFja2dyb3VuZDogI2VlZjFmNjsgY29sb3I6IHZhcigtLWFjYzIpOyB9CiNidG4tZHJpdmUgLmRyaXZlLWljbyB7CiAgd2lkdGg6IDIwcHg7IGhl
;aWdodDogMjBweDsgb2JqZWN0LWZpdDogY29udGFpbjsgZmxleC1zaHJpbms6IDA7CiAgYmFja2dyb3VuZDogdHJhbnNwYXJlbnQ7Cn0KI2J0bi1kcml2ZSAu
;ZHJpdmUtaWNvLmhpZGRlbiB7IGRpc3BsYXk6IG5vbmU7IH0KI2J0bi1kcml2ZSAuY2FyZXQgeyBmb250LXNpemU6IDEwcHg7IGNvbG9yOiB2YXIoLS10eHQz
;KTsgbWFyZ2luLWxlZnQ6IGF1dG87IH0KI2RyaXZlLWxhYmVsIHsgb3ZlcmZsb3c6IGhpZGRlbjsgdGV4dC1vdmVyZmxvdzogZWxsaXBzaXM7IHdoaXRlLXNw
;YWNlOiBub3dyYXA7IH0KI2RyaXZlLW1lbnUgewogIGRpc3BsYXk6IG5vbmU7IHBvc2l0aW9uOiBhYnNvbHV0ZTsgdG9wOiAxMDAlOyBsZWZ0OiAwOyByaWdo
;dDogMDsgei1pbmRleDogNDA7CiAgd2lkdGg6IDEwMCU7IG1heC1oZWlnaHQ6IDMyMHB4OyBvdmVyZmxvdzogYXV0bzsKICBiYWNrZ3JvdW5kOiAjZmZmOyBi
;b3JkZXI6IDFweCBzb2xpZCB2YXIoLS1saW5lKTsgYm9yZGVyLXRvcDogMDsKICBib3gtc2hhZG93OiB2YXIoLS1zaGFkb3cpOyBwYWRkaW5nOiA0cHg7IGJv
;cmRlci1yYWRpdXM6IDAgMCA4cHggOHB4Owp9CiNkcml2ZS1tZW51Lm9uIHsgZGlzcGxheTogYmxvY2s7IH0KI2RyaXZlLW1lbnUgYnV0dG9uIHsKICBkaXNw
;bGF5OiBmbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBnYXA6IDhweDsgd2lkdGg6IDEwMCU7CiAgdGV4dC1hbGlnbjogbGVmdDsgYm9yZGVyOiAwOyBiYWNr
;Z3JvdW5kOiB0cmFuc3BhcmVudDsKICBwYWRkaW5nOiA4cHggMTBweDsgYm9yZGVyLXJhZGl1czogNnB4OyBjdXJzb3I6IHBvaW50ZXI7IGNvbG9yOiB2YXIo
;LS10eHQpOyBmb250LXNpemU6IDEzcHg7Cn0KI2RyaXZlLW1lbnUgYnV0dG9uIGltZyB7CiAgd2lkdGg6IDIwcHg7IGhlaWdodDogMjBweDsgb2JqZWN0LWZp
;dDogY29udGFpbjsgZmxleC1zaHJpbms6IDA7IGJhY2tncm91bmQ6IHRyYW5zcGFyZW50Owp9CiNkcml2ZS1tZW51IGJ1dHRvbjpob3ZlciB7IGJhY2tncm91
;bmQ6ICNlZWYyZmY7IH0KI2RyaXZlLW1lbnUgYnV0dG9uLm9uIHsgYmFja2dyb3VuZDogI2VmZjZmZjsgY29sb3I6IHZhcigtLWFjYzIpOyBmb250LXdlaWdo
;dDogNjAwOyB9CiN0b3AtcmVzdCB7CiAgZGlzcGxheTogZ3JpZDsKICBncmlkLXRlbXBsYXRlLWNvbHVtbnM6IG1pbm1heCgyODBweCwgMS4xZnIpIG1pbm1h
;eCgzMjBweCwgMS4yZnIpOwogIGFsaWduLWl0ZW1zOiBzdHJldGNoOyBtaW4td2lkdGg6IDA7IG1pbi1oZWlnaHQ6IDA7CiAgYmFja2dyb3VuZDogdmFyKC0t
;Y2hyb21lKTsKfQojdG9wLm1vZGUtdG9vbCAjdG9wLXJlc3QgewogIGdyaWQtdGVtcGxhdGUtY29sdW1uczogMWZyOwp9Ci8qIOWFs+iBlOWPpeafhO+8muS7
;heaQnOe0ouahhuWNoOS4gOWNiu+8jOWIl+ihqOS7jeWFqOWuvSAqLwojdG9wLm1vZGUtaGFuZGxlICN0b3AtcmVzdCB7CiAgZ3JpZC10ZW1wbGF0ZS1jb2x1
;bW5zOiBtaW5tYXgoMjgwcHgsIDUwJSk7CiAganVzdGlmeS1jb250ZW50OiBzdGFydDsKfQojc2VhcmNoLXdyYXAgewogIGRpc3BsYXk6IGZsZXg7IGFsaWdu
;LWl0ZW1zOiBjZW50ZXI7IG1pbi13aWR0aDogMDsgaGVpZ2h0OiAxMDAlOwogIHBhZGRpbmc6IDA7IGJvcmRlci1yaWdodDogMDsgYmFja2dyb3VuZDogdmFy
;KC0tY2hyb21lKTsKfQojZmlsdGVyLXNldHRpbmdzIHsKICBkaXNwbGF5OiBub25lOyBwb3NpdGlvbjogZml4ZWQ7IGluc2V0OiAwOyB6LWluZGV4OiAzMDA7
;CiAgYmFja2dyb3VuZDogcmdiYSgxNSwgMjMsIDQyLCAuMjgpOyBhbGlnbi1pdGVtczogY2VudGVyOyBqdXN0aWZ5LWNvbnRlbnQ6IGNlbnRlcjsKfQojZmls
;dGVyLXNldHRpbmdzLm9uIHsgZGlzcGxheTogZmxleDsgfQojZmlsdGVyLXNldHRpbmdzIC5mcy1jYXJkIHsKICB3aWR0aDogbWluKDQ2MHB4LCA5MnZ3KTsg
;bWF4LWhlaWdodDogbWluKDYyMHB4LCA4OHZoKTsKICBiYWNrZ3JvdW5kOiAjZmZmOyBib3JkZXItcmFkaXVzOiAxNHB4OyBib3JkZXI6IDFweCBzb2xpZCB2
;YXIoLS1saW5lKTsKICBib3gtc2hhZG93OiAwIDE4cHggNDBweCByZ2JhKDE1LCAyMywgNDIsIC4xOCk7CiAgZGlzcGxheTogZmxleDsgZmxleC1kaXJlY3Rp
;b246IGNvbHVtbjsgb3ZlcmZsb3c6IGhpZGRlbjsKfQojZmlsdGVyLXNldHRpbmdzIC5mcy1oZCB7CiAgZGlzcGxheTogZmxleDsgYWxpZ24taXRlbXM6IGNl
;bnRlcjsganVzdGlmeS1jb250ZW50OiBzcGFjZS1iZXR3ZWVuOwogIHBhZGRpbmc6IDE0cHggMTZweDsgYm9yZGVyLWJvdHRvbTogMXB4IHNvbGlkIHZhcigt
;LWxpbmUpOyBmb250LXdlaWdodDogNjAwOwp9CiNmaWx0ZXItc2V0dGluZ3MgLmZzLWhkIGJ1dHRvbiB7CiAgYm9yZGVyOiAwOyBiYWNrZ3JvdW5kOiB0cmFu
;c3BhcmVudDsgY29sb3I6IHZhcigtLXR4dDIpOyBjdXJzb3I6IHBvaW50ZXI7IGZvbnQtc2l6ZTogMThweDsgbGluZS1oZWlnaHQ6IDE7Cn0KI2ZpbHRlci1z
;ZXR0aW5ncyAuZnMtYmQgewogIHBhZGRpbmc6IDE0cHggMTZweDsgb3ZlcmZsb3c6IGF1dG87IGRpc3BsYXk6IGZsZXg7IGZsZXgtZGlyZWN0aW9uOiBjb2x1
;bW47IGdhcDogMTJweDsKfQojZmlsdGVyLXNldHRpbmdzIC5mcy1oaW50IHsgZm9udC1zaXplOiAxMnB4OyBjb2xvcjogdmFyKC0tdHh0Myk7IGxpbmUtaGVp
;Z2h0OiAxLjU7IH0KI2ZpbHRlci1zZXR0aW5ncyAuZnMtbGlzdCB7IGRpc3BsYXk6IGZsZXg7IGZsZXgtZGlyZWN0aW9uOiBjb2x1bW47IGdhcDogMTBweDsg
;fQojZmlsdGVyLXNldHRpbmdzIC5mcy1ibG9jayB7CiAgcG9zaXRpb246IHJlbGF0aXZlOyBkaXNwbGF5OiBncmlkOwogIGdyaWQtdGVtcGxhdGUtY29sdW1u
;czogMjhweCBtaW5tYXgoMCwgMWZyKSBhdXRvOwogIGdhcDogOHB4IDEwcHg7IGFsaWduLWl0ZW1zOiBzdGFydDsKICBwYWRkaW5nOiAxNHB4IDM2cHggMTJw
;eCAxMnB4OwogIGJvcmRlcjogMXB4IHNvbGlkICNkN2RkZTg7IGJvcmRlci1yYWRpdXM6IDEycHg7CiAgYmFja2dyb3VuZDogbGluZWFyLWdyYWRpZW50KDE4
;MGRlZywgI2ZmZmZmZiAwJSwgI2Y3ZjlmYyAxMDAlKTsKICBib3gtc2hhZG93OiAwIDFweCAwIHJnYmEoMjU1LDI1NSwyNTUsLjkpIGluc2V0LCAwIDRweCAx
;MnB4IHJnYmEoMTUsIDIzLCA0MiwgLjA1KTsKICBib3JkZXItbGVmdDogM3B4IHNvbGlkICM4NmVmYWM7Cn0KI2ZpbHRlci1zZXR0aW5ncyAuZnMtYmxvY2su
;b2ZmIHsKICBvcGFjaXR5OiAuNjI7IGJvcmRlci1sZWZ0LWNvbG9yOiAjY2JkNWUxOwogIGJhY2tncm91bmQ6IGxpbmVhci1ncmFkaWVudCgxODBkZWcsICNm
;OGZhZmMgMCUsICNmMWY1ZjkgMTAwJSk7Cn0KI2ZpbHRlci1zZXR0aW5ncyAuZnMtYmxvY2sgLmZzLWRlbCB7CiAgcG9zaXRpb246IGFic29sdXRlOyB0b3A6
;IDhweDsgcmlnaHQ6IDhweDsKICB3aWR0aDogMjJweDsgaGVpZ2h0OiAyMnB4OyBwYWRkaW5nOiAwOyBib3JkZXI6IDA7IGJvcmRlci1yYWRpdXM6IDZweDsK
;ICBiYWNrZ3JvdW5kOiB0cmFuc3BhcmVudDsgY29sb3I6IHZhcigtLXR4dDMpOyBjdXJzb3I6IHBvaW50ZXI7CiAgZGlzcGxheTogaW5saW5lLWZsZXg7IGFs
;aWduLWl0ZW1zOiBjZW50ZXI7IGp1c3RpZnktY29udGVudDogY2VudGVyOwp9CiNmaWx0ZXItc2V0dGluZ3MgLmZzLWJsb2NrIC5mcy1kZWw6aG92ZXIgeyBi
;YWNrZ3JvdW5kOiAjZmVlMmUyOyBjb2xvcjogI2I5MWMxYzsgfQojZmlsdGVyLXNldHRpbmdzIC5mcy1ibG9jayAuZnMtZGVsIHN2ZyB7IHdpZHRoOiAxMnB4
;OyBoZWlnaHQ6IDEycHg7IGRpc3BsYXk6IGJsb2NrOyB9CiNmaWx0ZXItc2V0dGluZ3MgLmZzLW9yZCB7CiAgZGlzcGxheTogZmxleDsgZmxleC1kaXJlY3Rp
;b246IGNvbHVtbjsgZ2FwOiAycHg7IHBhZGRpbmctdG9wOiAycHg7Cn0KI2ZpbHRlci1zZXR0aW5ncyAuZnMtb3JkIGJ1dHRvbiB7CiAgd2lkdGg6IDI0cHg7
;IGhlaWdodDogMjBweDsgcGFkZGluZzogMDsgYm9yZGVyOiAwOyBib3JkZXItcmFkaXVzOiA1cHg7CiAgYmFja2dyb3VuZDogI2VlZjJmNzsgY29sb3I6IHZh
;cigtLXR4dDIpOyBjdXJzb3I6IHBvaW50ZXI7CiAgZGlzcGxheTogaW5saW5lLWZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGp1c3RpZnktY29udGVudDog
;Y2VudGVyOwp9CiNmaWx0ZXItc2V0dGluZ3MgLmZzLW9yZCBidXR0b246aG92ZXIgeyBiYWNrZ3JvdW5kOiAjZTJlOGYwOyBjb2xvcjogdmFyKC0tdHh0KTsg
;fQojZmlsdGVyLXNldHRpbmdzIC5mcy1vcmQgYnV0dG9uOmRpc2FibGVkIHsgb3BhY2l0eTogLjI4OyBjdXJzb3I6IGRlZmF1bHQ7IH0KI2ZpbHRlci1zZXR0
;aW5ncyAuZnMtb3JkIGJ1dHRvbiBzdmcgeyB3aWR0aDogMTFweDsgaGVpZ2h0OiAxMXB4OyBkaXNwbGF5OiBibG9jazsgfQojZmlsdGVyLXNldHRpbmdzIC5m
;cy1tYWluIHsgbWluLXdpZHRoOiAwOyBkaXNwbGF5OiBmbGV4OyBmbGV4LWRpcmVjdGlvbjogY29sdW1uOyBnYXA6IDRweDsgfQojZmlsdGVyLXNldHRpbmdz
;IC5mcy10aXRsZS1yb3cgewogIGRpc3BsYXk6IGZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGdhcDogOHB4OyBtaW4td2lkdGg6IDA7Cn0KI2ZpbHRlci1z
;ZXR0aW5ncyAuZnMtdGl0bGUgewogIGZvbnQtc2l6ZTogMTMuNXB4OyBmb250LXdlaWdodDogNzAwOyBjb2xvcjogdmFyKC0tdHh0KTsKICBvdmVyZmxvdzog
;aGlkZGVuOyB0ZXh0LW92ZXJmbG93OiBlbGxpcHNpczsgd2hpdGUtc3BhY2U6IG5vd3JhcDsKfQojZmlsdGVyLXNldHRpbmdzIC5mcy10YWcgewogIGZsZXgt
;c2hyaW5rOiAwOyBmb250LXNpemU6IDEwcHg7IGZvbnQtd2VpZ2h0OiA2MDA7IGxpbmUtaGVpZ2h0OiAxOwogIHBhZGRpbmc6IDNweCA2cHg7IGJvcmRlci1y
;YWRpdXM6IDk5OXB4OwogIGJhY2tncm91bmQ6ICNlY2ZkZjU7IGNvbG9yOiAjMDQ3ODU3OyBib3JkZXI6IDFweCBzb2xpZCAjYTdmM2QwOwp9CiNmaWx0ZXIt
;c2V0dGluZ3MgLmZzLWJsb2NrLm9mZiAuZnMtdGFnIHsKICBiYWNrZ3JvdW5kOiAjZjFmNWY5OyBjb2xvcjogIzY0NzQ4YjsgYm9yZGVyLWNvbG9yOiAjZTJl
;OGYwOwp9CiNmaWx0ZXItc2V0dGluZ3MgLmZzLXJlZ2V4IHsKICBmb250LXNpemU6IDExcHg7IGNvbG9yOiB2YXIoLS10eHQzKTsgbGluZS1oZWlnaHQ6IDEu
;MzU7CiAgd29yZC1icmVhazogYnJlYWstYWxsOyBmb250LWZhbWlseTogQ29uc29sYXMsICJDYXNjYWRpYSBNb25vIiwgbW9ub3NwYWNlOwp9CiNmaWx0ZXIt
;c2V0dGluZ3MgLmZzLWVuIHsKICBkaXNwbGF5OiBmbGV4OyBmbGV4LWRpcmVjdGlvbjogY29sdW1uOyBhbGlnbi1pdGVtczogZmxleC1lbmQ7IGdhcDogNHB4
;OwogIHBhZGRpbmctdG9wOiAycHg7IHBhZGRpbmctcmlnaHQ6IDRweDsKfQojZmlsdGVyLXNldHRpbmdzIC5mcy1lbiAuZnMtZW4tbGFiIHsKICBmb250LXNp
;emU6IDEwcHg7IGNvbG9yOiB2YXIoLS10eHQzKTsgbGluZS1oZWlnaHQ6IDE7IHdoaXRlLXNwYWNlOiBub3dyYXA7Cn0KI2ZpbHRlci1zZXR0aW5ncyAuZnMt
;c3dpdGNoIHsKICBwb3NpdGlvbjogcmVsYXRpdmU7IHdpZHRoOiAzNnB4OyBoZWlnaHQ6IDIwcHg7IGZsZXgtc2hyaW5rOiAwOwogIGJvcmRlcjogMDsgYm9y
;ZGVyLXJhZGl1czogOTk5cHg7IGJhY2tncm91bmQ6ICNjYmQ1ZTE7IGN1cnNvcjogcG9pbnRlcjsgcGFkZGluZzogMDsKfQojZmlsdGVyLXNldHRpbmdzIC5m
;cy1zd2l0Y2gub24geyBiYWNrZ3JvdW5kOiAjMzRkMzk5OyB9CiNmaWx0ZXItc2V0dGluZ3MgLmZzLXN3aXRjaCBpIHsKICBwb3NpdGlvbjogYWJzb2x1dGU7
;IHRvcDogMnB4OyBsZWZ0OiAycHg7IHdpZHRoOiAxNnB4OyBoZWlnaHQ6IDE2cHg7CiAgYm9yZGVyLXJhZGl1czogNTAlOyBiYWNrZ3JvdW5kOiAjZmZmOyBi
;b3gtc2hhZG93OiAwIDFweCAzcHggcmdiYSgxNSwyMyw0MiwuMik7CiAgdHJhbnNpdGlvbjogdHJhbnNmb3JtIC4xNXMgZWFzZTsgcG9pbnRlci1ldmVudHM6
;IG5vbmU7Cn0KI2ZpbHRlci1zZXR0aW5ncyAuZnMtc3dpdGNoLm9uIGkgeyB0cmFuc2Zvcm06IHRyYW5zbGF0ZVgoMTZweCk7IH0KI2ZpbHRlci1zZXR0aW5n
;cyAuZnMtZm9ybSB7CiAgZGlzcGxheTogZ3JpZDsgZ2FwOiA4cHg7IHBhZGRpbmc6IDEycHg7IGJvcmRlci1yYWRpdXM6IDEycHg7CiAgYm9yZGVyOiAxcHgg
;ZGFzaGVkICNjNWNlZGQ7IGJhY2tncm91bmQ6ICNmYWZiZmQ7Cn0KI2ZpbHRlci1zZXR0aW5ncyBsYWJlbCB7IGZvbnQtc2l6ZTogMTJweDsgY29sb3I6IHZh
;cigtLXR4dDIpOyB9CiNmaWx0ZXItc2V0dGluZ3MgaW5wdXQgewogIHdpZHRoOiAxMDAlOyBoZWlnaHQ6IDM0cHg7IGJvcmRlcjogMXB4IHNvbGlkIHZhcigt
;LWxpbmUpOyBib3JkZXItcmFkaXVzOiA4cHg7CiAgcGFkZGluZzogMCAxMHB4OyBmb250LXNpemU6IDEzcHg7IGJveC1zaXppbmc6IGJvcmRlci1ib3g7IG91
;dGxpbmU6IG5vbmU7Cn0KI2ZpbHRlci1zZXR0aW5ncyBpbnB1dDpmb2N1cyB7IGJvcmRlci1jb2xvcjogIzkzYzVmZDsgYm94LXNoYWRvdzogMCAwIDAgM3B4
;IHJnYmEoNTksMTMwLDI0NiwuMTIpOyB9CiNmaWx0ZXItc2V0dGluZ3MgLmZzLXRhYnMgewogIGRpc3BsYXk6IGZsZXg7IGdhcDogMDsgbWFyZ2luOiAwIDAg
;MTJweDsgYm9yZGVyOiAxcHggc29saWQgdmFyKC0tbGluZSk7IGJvcmRlci1yYWRpdXM6IDEwcHg7IG92ZXJmbG93OiBoaWRkZW47Cn0KI2ZpbHRlci1zZXR0
;aW5ncyAuZnMtdGFiIHsKICBmbGV4OiAxOyBoZWlnaHQ6IDM0cHg7IGJvcmRlcjogMDsgYmFja2dyb3VuZDogI2Y4ZmFmYzsgY29sb3I6IHZhcigtLXR4dDIp
;OwogIGZvbnQtc2l6ZTogMTNweDsgY3Vyc29yOiBwb2ludGVyOwp9CiNmaWx0ZXItc2V0dGluZ3MgLmZzLXRhYiArIC5mcy10YWIgeyBib3JkZXItbGVmdDog
;MXB4IHNvbGlkIHZhcigtLWxpbmUpOyB9CiNmaWx0ZXItc2V0dGluZ3MgLmZzLXRhYjpob3ZlciB7IGJhY2tncm91bmQ6ICNlZWYyZjc7IGNvbG9yOiB2YXIo
;LS10eHQpOyB9CiNmaWx0ZXItc2V0dGluZ3MgLmZzLXRhYi5vbiB7CiAgYmFja2dyb3VuZDogI2VmZjZmZjsgY29sb3I6ICMxZDRlZDg7IGZvbnQtd2VpZ2h0
;OiA2NTA7Cn0KI2ZpbHRlci1zZXR0aW5ncyAuZnMtZm9ybS1wYXRoIHsgZGlzcGxheTogbm9uZTsgfQojZmlsdGVyLXNldHRpbmdzLnRhYi1wYXRoIC5mcy1m
;b3JtLW5hbWUgeyBkaXNwbGF5OiBub25lOyB9CiNmaWx0ZXItc2V0dGluZ3MudGFiLXBhdGggLmZzLWZvcm0tcGF0aCB7IGRpc3BsYXk6IGJsb2NrOyB9CiNw
;di1wcmUgbWFyayB7CiAgYmFja2dyb3VuZDogI2ZlZjA4YTsgY29sb3I6IGluaGVyaXQ7IHBhZGRpbmc6IDAgMXB4OyBib3JkZXItcmFkaXVzOiAycHg7Cn0K
;I2ZpbHRlci1zZXR0aW5ncyAuZnMtYWN0aW9ucyBidXR0b24gewogIGhlaWdodDogMzJweDsgcGFkZGluZzogMCAxNHB4OyBib3JkZXItcmFkaXVzOiA4cHg7
;IGJvcmRlcjogMXB4IHNvbGlkIHZhcigtLWxpbmUpOwogIGJhY2tncm91bmQ6ICNmZmY7IGN1cnNvcjogcG9pbnRlcjsgZm9udC1zaXplOiAxM3B4Owp9CiNm
;aWx0ZXItc2V0dGluZ3MgLmZzLWFjdGlvbnMgLnByaW1hcnkgewogIGJhY2tncm91bmQ6IHZhcigtLWFjYyk7IGJvcmRlci1jb2xvcjogdmFyKC0tYWNjKTsg
;Y29sb3I6ICNmZmY7Cn0KI2ZpbHRlci1zZXR0aW5ncyAuZnMtYWN0aW9ucyAucHJpbWFyeTpob3ZlciB7IGJhY2tncm91bmQ6IHZhcigtLWFjYzIpOyB9CiNm
;aWx0ZXItc2V0dGluZ3MgLmZzLWZvb3QgewogIGRpc3BsYXk6IGZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGp1c3RpZnktY29udGVudDogc3BhY2UtYmV0
;d2VlbjsgZ2FwOiAxMnB4OwogIHBhZGRpbmc6IDEwcHggMTZweCAxNHB4OyBib3JkZXItdG9wOiAxcHggc29saWQgdmFyKC0tbGluZSk7Cn0KI2ZpbHRlci1z
;ZXR0aW5ncyAuZnMtZm9vdCBidXR0b24gewogIGJvcmRlcjogMDsgYmFja2dyb3VuZDogdHJhbnNwYXJlbnQ7IGNvbG9yOiB2YXIoLS1hY2MyKTsgY3Vyc29y
;OiBwb2ludGVyOyBmb250LXNpemU6IDEycHg7IHBhZGRpbmc6IDA7Cn0KI2ZpbHRlci1zZXR0aW5ncyAuZnMtZm9vdCAjZnMtcmVzZXQgewogIGNvbG9yOiB2
;YXIoLS10eHQyKTsKfQojZmlsdGVyLXNldHRpbmdzIC5mcy1mb290ICNmcy1yZXNldDpob3ZlciB7IGNvbG9yOiAjYjkxYzFjOyB9CiN0b3AubW9kZS10b29s
;ICNzZWFyY2gtd3JhcCB7IHBhZGRpbmctcmlnaHQ6IDA7IH0KI3RvcC5tb2RlLXRvb2wgI3RvcC1wcmV2aWV3IHsgZGlzcGxheTogbm9uZTsgfQojdG9wLm1v
;ZGUtaGFuZGxlICN0b3AtcHJldmlldyB7IGRpc3BsYXk6IG5vbmU7IH0KI3RvcC5tb2RlLWluZm8gI3NlYXJjaC13cmFwIHsgZGlzcGxheTogbm9uZSAhaW1w
;b3J0YW50OyB9CiN0b3AubW9kZS1pbmZvICN0b3AtcHJldmlldyB7IGRpc3BsYXk6IG5vbmU7IH0KI3RvcC5tb2RlLWluZm8gI3RvcC1yZXN0IHsgZ3JpZC10
;ZW1wbGF0ZS1jb2x1bW5zOiAxZnI7IG1pbi1oZWlnaHQ6IDA7IH0KI3RvcC5tb2RlLWNvbmZpZyAjdG9wLXByZXZpZXcgeyBkaXNwbGF5OiBub25lOyB9CiN0
;b3AubW9kZS1jb25maWcgI3RvcC1yZXN0IHsKICBncmlkLXRlbXBsYXRlLWNvbHVtbnM6IG1pbm1heCgyNDBweCwgNTAlKTsKICBqdXN0aWZ5LWNvbnRlbnQ6
;IHN0YXJ0Owp9CiN0b3AubW9kZS1jb25maWcgI3NlYXJjaC13cmFwIHsKICBwYWRkaW5nLXJpZ2h0OiAwOwp9Ci5jZmctc3RhZyB7CiAgaGVpZ2h0OiAyMnB4
;OyBwYWRkaW5nOiAwIDEwcHg7IGJvcmRlcjogMXB4IHNvbGlkIHZhcigtLWxpbmUpOyBib3JkZXItcmFkaXVzOiA5OTlweDsKICBiYWNrZ3JvdW5kOiAjZmJm
;YmZkOyBjb2xvcjogdmFyKC0tdHh0Mik7IGZvbnQtc2l6ZTogMTJweDsgY3Vyc29yOiBwb2ludGVyOwogIHVzZXItc2VsZWN0OiBub25lOyB3aGl0ZS1zcGFj
;ZTogbm93cmFwOyBsaW5lLWhlaWdodDogMjBweDsKfQouY2ZnLXN0YWc6aG92ZXIgeyBiYWNrZ3JvdW5kOiAjZWVmMWY2OyBjb2xvcjogdmFyKC0tdHh0KTsg
;fQouY2ZnLXN0YWcub24gewogIGJhY2tncm91bmQ6ICNlY2ZkZjU7IGJvcmRlci1jb2xvcjogIzg2ZWZhYzsgY29sb3I6ICMwNDc4NTc7IGZvbnQtd2VpZ2h0
;OiA2MDA7Cn0KI2NmZy1zZWFyY2gtY2xlYXIgewogIGRpc3BsYXk6IG5vbmU7IGZsZXgtc2hyaW5rOiAwOyBhbGlnbi1pdGVtczogY2VudGVyOyBnYXA6IDRw
;eDsKICBoZWlnaHQ6IDIycHg7IHBhZGRpbmc6IDAgNnB4IDAgOHB4OyBtYXJnaW4tcmlnaHQ6IDJweDsKICBib3JkZXI6IDA7IGJvcmRlci1yYWRpdXM6IDk5
;OXB4OwogIGJhY2tncm91bmQ6ICNlY2ZkZjU7IGNvbG9yOiAjNmI3MjgwOwogIGN1cnNvcjogcG9pbnRlcjsgdXNlci1zZWxlY3Q6IG5vbmU7IHdoaXRlLXNw
;YWNlOiBub3dyYXA7CiAgZm9udC1zaXplOiAxMS41cHg7IGZvbnQtd2VpZ2h0OiA1MDA7IGZvbnQtdmFyaWFudC1udW1lcmljOiB0YWJ1bGFyLW51bXM7CiAg
;bGluZS1oZWlnaHQ6IDE7Cn0KI2NmZy1zZWFyY2gtY2xlYXIub24geyBkaXNwbGF5OiBpbmxpbmUtZmxleDsgfQojY2ZnLXNlYXJjaC1jbGVhcjpob3ZlciB7
;IGJhY2tncm91bmQ6ICNkMWZhZTU7IGNvbG9yOiAjNGI1NTYzOyB9CiNjZmctc2VhcmNoLWNsZWFyICNjZmctc2VhcmNoLWhpdCB7IGRpc3BsYXk6IGlubGlu
;ZTsgcGFkZGluZzogMDsgY29sb3I6IGluaGVyaXQ7IGZvbnQ6IGluaGVyaXQ7IG9wYWNpdHk6IC43MjsgfQojY2ZnLXNlYXJjaC1jbGVhcjpob3ZlciAjY2Zn
;LXNlYXJjaC1oaXQgeyBvcGFjaXR5OiAuODU7IH0KI2NmZy1zZWFyY2gtY2xlYXIgLmNmZy14IHsKICB3aWR0aDogMTRweDsgaGVpZ2h0OiAxNHB4OyBkaXNw
;bGF5OiBibG9jazsgZmxleC1zaHJpbms6IDA7IGNvbG9yOiAjOWNhM2FmOwp9CiNjZmctc2VhcmNoLWNsZWFyOmhvdmVyIC5jZmcteCB7IGNvbG9yOiAjNmI3
;MjgwOyB9CiNjZmctc2VhcmNoLWNsZWFyLm9uIH4gI2J0bi1jbGVhciwKI3RvcC5tb2RlLWNvbmZpZyAjYnRuLWNsZWFyLAojdG9wLm1vZGUtaGFuZGxlICNi
;dG4tY2xlYXIgeyBkaXNwbGF5OiBub25lICFpbXBvcnRhbnQ7IH0KI3NlYXJjaC1ib3ggewogIHBvc2l0aW9uOiByZWxhdGl2ZTsgZGlzcGxheTogZmxleDsg
;YWxpZ24taXRlbXM6IGNlbnRlcjsgZ2FwOiA0cHg7CiAgd2lkdGg6IDEwMCU7IGhlaWdodDogMzRweDsKICBib3JkZXI6IDFweCBzb2xpZCB2YXIoLS1saW5l
;KTsgYm9yZGVyLXJhZGl1czogOHB4OwogIHBhZGRpbmc6IDAgNHB4IDAgOHB4OyBiYWNrZ3JvdW5kOiAjZmJmYmZkOyBvdmVyZmxvdzogdmlzaWJsZTsKfQoj
;c2VhcmNoLWJveDpmb2N1cy13aXRoaW4gewogIGJvcmRlci1jb2xvcjogIzkzYzVmZDsKICBib3gtc2hhZG93OiAwIDAgMCAzcHggcmdiYSg1OSwxMzAsMjQ2
;LC4xNSk7CiAgYmFja2dyb3VuZDogI2ZmZjsKfQojc2VhcmNoLWljbyB7CiAgZmxleC1zaHJpbms6IDA7IHdpZHRoOiAyNHB4OyBoZWlnaHQ6IDI0cHg7IG1h
;cmdpbjogMCAxcHggMCAtMnB4OyBwYWRkaW5nOiAwOwogIGJvcmRlcjogMDsgYm9yZGVyLXJhZGl1czogNnB4OyBiYWNrZ3JvdW5kOiB0cmFuc3BhcmVudDsK
;ICBjb2xvcjogdmFyKC0tdHh0Myk7IGRpc3BsYXk6IGlubGluZS1mbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBqdXN0aWZ5LWNvbnRlbnQ6IGNlbnRlcjsK
;ICBjdXJzb3I6IHBvaW50ZXI7IGxpbmUtaGVpZ2h0OiAwOwp9CiNzZWFyY2gtaWNvIHN2ZyB7IHdpZHRoOiAxNXB4OyBoZWlnaHQ6IDE1cHg7IGRpc3BsYXk6
;IGJsb2NrOyB9CiNzZWFyY2gtaWNvOmhvdmVyLCAjc2VhcmNoLWljby5vbiB7IGJhY2tncm91bmQ6ICNlZWYyZmY7IGNvbG9yOiB2YXIoLS1hY2MyKTsgfQoj
;c2VhcmNoLWJveDpmb2N1cy13aXRoaW4gI3NlYXJjaC1pY28geyBjb2xvcjogIzY0NzQ4YjsgfQojc2VhcmNoLWJveDpmb2N1cy13aXRoaW4gI3NlYXJjaC1p
;Y286aG92ZXIsCiNzZWFyY2gtYm94OmZvY3VzLXdpdGhpbiAjc2VhcmNoLWljby5vbiB7IGNvbG9yOiB2YXIoLS1hY2MyKTsgfQojcSB7CiAgZmxleDogMTsg
;bWluLXdpZHRoOiAwOyBoZWlnaHQ6IDEwMCU7CiAgYm9yZGVyOiAwOyBib3JkZXItcmFkaXVzOiAwOyBwYWRkaW5nOiAwOyBvdXRsaW5lOiBub25lOyBiYWNr
;Z3JvdW5kOiB0cmFuc3BhcmVudDsKICBmb250LXNpemU6IDEzLjVweDsgY29sb3I6IHZhcigtLXR4dCk7Cn0KI3E6OnBsYWNlaG9sZGVyIHsgY29sb3I6IHZh
;cigtLXR4dDMpOyB9CiNidG4tY2xlYXIgewogIGRpc3BsYXk6IG5vbmU7IGZsZXgtc2hyaW5rOiAwOyBoZWlnaHQ6IDIycHg7IHBhZGRpbmc6IDAgMTBweDsK
;ICBib3JkZXI6IDA7IGJvcmRlci1yYWRpdXM6IDk5OXB4OyBiYWNrZ3JvdW5kOiAjZWVmMWY2OwogIGNvbG9yOiB2YXIoLS10eHQyKTsgZm9udC1zaXplOiAx
;MnB4OyBjdXJzb3I6IHBvaW50ZXI7IGxpbmUtaGVpZ2h0OiAyMnB4Owp9CiNidG4tY2xlYXIub24geyBkaXNwbGF5OiBpbmxpbmUtZmxleDsgYWxpZ24taXRl
;bXM6IGNlbnRlcjsganVzdGlmeS1jb250ZW50OiBjZW50ZXI7IH0KI2J0bi1jbGVhcjpob3ZlciB7IGJhY2tncm91bmQ6ICNlMmU4ZjA7IGNvbG9yOiB2YXIo
;LS10eHQpOyB9CiNidG4taGlzdCB7IGRpc3BsYXk6IG5vbmUgIWltcG9ydGFudDsgfQojaGlzdC1tZW51IHsKICBkaXNwbGF5OiBub25lOyBwb3NpdGlvbjog
;YWJzb2x1dGU7IHRvcDogMTAwJTsgbGVmdDogLTFweDsgcmlnaHQ6IC0xcHg7IHotaW5kZXg6IDQ1OwogIG1heC1oZWlnaHQ6IDI4MHB4OyBvdmVyZmxvdzog
;YXV0bzsKICBiYWNrZ3JvdW5kOiAjZmZmOyBib3JkZXI6IDFweCBzb2xpZCB2YXIoLS1saW5lKTsgYm9yZGVyLXRvcDogMDsKICBib3gtc2hhZG93OiAwIDhw
;eCAxOHB4IHJnYmEoMTUsIDIzLCA0MiwgLjA4KTsgcGFkZGluZzogMnB4IDRweCA0cHg7CiAgYm9yZGVyLXJhZGl1czogMCAwIDhweCA4cHg7Cn0KI2hpc3Qt
;bWVudS5vbiB7IGRpc3BsYXk6IGJsb2NrOyB9CiNzZWFyY2gtYm94Lmhpc3Qtb3BlbiB7CiAgYm9yZGVyLWJvdHRvbS1sZWZ0LXJhZGl1czogMDsgYm9yZGVy
;LWJvdHRvbS1yaWdodC1yYWRpdXM6IDA7Cn0KI2hpc3QtbWVudSBidXR0b24gewogIGRpc3BsYXk6IGZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGdhcDog
;OHB4OyB3aWR0aDogMTAwJTsgdGV4dC1hbGlnbjogbGVmdDsKICBib3JkZXI6IDA7IGJhY2tncm91bmQ6IHRyYW5zcGFyZW50OyBwYWRkaW5nOiA3cHggMTBw
;eDsgYm9yZGVyLXJhZGl1czogNnB4OwogIGN1cnNvcjogcG9pbnRlcjsgY29sb3I6IHZhcigtLXR4dCk7IGZvbnQtc2l6ZTogMTNweDsKfQojaGlzdC1tZW51
;IGJ1dHRvbjpob3ZlciB7IGJhY2tncm91bmQ6ICNmM2Y0ZjY7IH0KI2hpc3QtbWVudSBidXR0b24gLmhpc3QtaWNvIHsKICBmbGV4LXNocmluazogMDsgd2lk
;dGg6IDE0cHg7IGhlaWdodDogMTRweDsgY29sb3I6IHZhcigtLXR4dDMpOyBkaXNwbGF5OiBibG9jazsKfQojaGlzdC1tZW51IGJ1dHRvbjpob3ZlciAuaGlz
;dC1pY28geyBjb2xvcjogdmFyKC0tYWNjMik7IH0KI2hpc3QtbWVudSBidXR0b24gLmhpc3QtdHh0IHsKICBmbGV4OiAxOyBtaW4td2lkdGg6IDA7IG92ZXJm
;bG93OiBoaWRkZW47IHRleHQtb3ZlcmZsb3c6IGVsbGlwc2lzOyB3aGl0ZS1zcGFjZTogbm93cmFwOwp9CiNoaXN0LW1lbnUgLmhpc3QtZW1wdHkgewogIHBh
;ZGRpbmc6IDEwcHg7IGNvbG9yOiB2YXIoLS10eHQzKTsgZm9udC1zaXplOiAxMnB4OyB0ZXh0LWFsaWduOiBjZW50ZXI7Cn0KI3RvcC1wcmV2aWV3IHsKICBk
;aXNwbGF5OiBmbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBnYXA6IDEwcHg7IG1pbi13aWR0aDogMDsgcGFkZGluZzogMCAxMnB4OwogIGJhY2tncm91bmQ6
;IHZhcigtLWNocm9tZSk7IGNvbG9yOiB2YXIoLS10eHQyKTsgZm9udC1zaXplOiAxMnB4OyBvdmVyZmxvdzogaGlkZGVuOwp9CiN0b3AtcHJldmlldyAucHYt
;bWV0YSB7CiAgYm9yZGVyOiAwOyBwYWRkaW5nOiAwOyBmbGV4OiAxOyBtaW4td2lkdGg6IDA7CiAgZmxleC13cmFwOiBub3dyYXA7IG92ZXJmbG93OiBoaWRk
;ZW47Cn0KI2J0bi1nb3RvLXByb2MgewogIGZsZXgtc2hyaW5rOiAwOyBoZWlnaHQ6IDMwcHg7IHBhZGRpbmc6IDAgMTJweDsKICBib3JkZXI6IDA7IGJvcmRl
;ci1yYWRpdXM6IDk5OXB4OyBjdXJzb3I6IHBvaW50ZXI7CiAgYmFja2dyb3VuZDogI2U4ZjFmZjsgY29sb3I6ICMxZDRlZDg7IGZvbnQtc2l6ZTogMTIuNXB4
;OyBmb250LXdlaWdodDogNjAwOwp9CiNidG4tZ290by1wcm9jOmhvdmVyIHsgYmFja2dyb3VuZDogI2RiZWFmZTsgfQoKI3ZpZXctc2VhcmNoIHsgZGlzcGxh
;eTogZmxleDsgZmxleC1kaXJlY3Rpb246IGNvbHVtbjsgZmxleDogMTsgbWluLWhlaWdodDogMDsgfQojdmlldy1zZWFyY2guaGlkZGVuIHsgZGlzcGxheTog
;bm9uZTsgfQojdmlldy1wcm9jIHsKICBkaXNwbGF5OiBub25lOyBmbGV4LWRpcmVjdGlvbjogY29sdW1uOyBmbGV4OiAxOyBtaW4taGVpZ2h0OiAwOwogIGJh
;Y2tncm91bmQ6ICNmMGYyZjU7Cn0KI3ZpZXctcHJvYy5vbiB7IGRpc3BsYXk6IGZsZXg7IH0KLnByb2MtdG9wIHsKICBkaXNwbGF5OiBmbGV4OyBhbGlnbi1p
;dGVtczogY2VudGVyOyBnYXA6IDEwcHg7IHBhZGRpbmc6IDEwcHggMTRweCA4cHg7CiAgYmFja2dyb3VuZDogI2ZmZjsgYm9yZGVyLWJvdHRvbTogMXB4IHNv
;bGlkIHZhcigtLWxpbmUpOwogIC13ZWJraXQtYXBwLXJlZ2lvbjogZHJhZzsgYXBwLXJlZ2lvbjogZHJhZzsKfQoucHJvYy10b3AgLm5vLWRyYWcsIC5wcm9j
;LXRvcCBidXR0b24sIC5wcm9jLXRvcCBpbnB1dCB7CiAgLXdlYmtpdC1hcHAtcmVnaW9uOiBuby1kcmFnOyBhcHAtcmVnaW9uOiBuby1kcmFnOwp9Ci5wcm9j
;LXRhYnMgeyBkaXNwbGF5OiBmbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBnYXA6IDhweDsgZmxleC13cmFwOiB3cmFwOyB9Ci5wcm9jLXRhYiB7CiAgaGVp
;Z2h0OiAzMHB4OyBwYWRkaW5nOiAwIDE0cHg7IGJvcmRlcjogMDsgYm9yZGVyLXJhZGl1czogOTk5cHg7CiAgYmFja2dyb3VuZDogI2VjZWZmMzsgY29sb3I6
;ICM0YjU1NjM7IGZvbnQtc2l6ZTogMTNweDsgY3Vyc29yOiBwb2ludGVyOwp9Ci5wcm9jLXRhYi5vbiB7IGJhY2tncm91bmQ6ICMzYjgyZjY7IGNvbG9yOiAj
;ZmZmOyBmb250LXdlaWdodDogNjAwOyB9Ci5wcm9jLXRhYjpkaXNhYmxlZCB7IG9wYWNpdHk6IC41NTsgY3Vyc29yOiBkZWZhdWx0OyB9Ci5wcm9jLXRvcC1y
;aWdodCB7IG1hcmdpbi1sZWZ0OiBhdXRvOyBkaXNwbGF5OiBmbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBnYXA6IDhweDsgfQojYnRuLWJhY2stc2VhcmNo
;IHsKICBoZWlnaHQ6IDMwcHg7IHBhZGRpbmc6IDAgMTJweDsgYm9yZGVyOiAwOyBib3JkZXItcmFkaXVzOiA5OTlweDsKICBiYWNrZ3JvdW5kOiAjZjNmNGY2
;OyBjb2xvcjogdmFyKC0tdHh0KTsgZm9udC1zaXplOiAxMi41cHg7IGN1cnNvcjogcG9pbnRlcjsKfQojYnRuLWJhY2stc2VhcmNoOmhvdmVyIHsgYmFja2dy
;b3VuZDogI2U1ZTdlYjsgfQoucHJvYy1zZWFyY2ggewogIGRpc3BsYXk6IGZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGdhcDogOHB4OyBwYWRkaW5nOiA4
;cHggMTRweDsKICBiYWNrZ3JvdW5kOiAjZmZmOyBib3JkZXItYm90dG9tOiAxcHggc29saWQgdmFyKC0tbGluZSk7Cn0KLnByb2Mtc2VhcmNoIGlucHV0IHsK
;ICBmbGV4OiAxOyBoZWlnaHQ6IDMycHg7IGJvcmRlcjogMXB4IHNvbGlkIHZhcigtLWxpbmUpOyBib3JkZXItcmFkaXVzOiA4cHg7CiAgcGFkZGluZzogMCAx
;MnB4OyBvdXRsaW5lOiBub25lOyBiYWNrZ3JvdW5kOiAjZmJmYmZkOyBmb250LXNpemU6IDEzcHg7Cn0KLnByb2Mtc2VhcmNoIGlucHV0OmZvY3VzIHsKICBi
;b3JkZXItY29sb3I6ICM5M2M1ZmQ7IGJveC1zaGFkb3c6IDAgMCAwIDNweCByZ2JhKDU5LDEzMCwyNDYsLjE1KTsgYmFja2dyb3VuZDogI2ZmZjsKfQoucHJv
;Yy10YWJsZS13cmFwIHsKICBmbGV4OiAxOyBtaW4taGVpZ2h0OiAwOyBtYXJnaW46IDAgMTBweCA4cHg7IGJvcmRlcjogMXB4IHNvbGlkICNkNGQ0ZDQ7CiAg
;Ym9yZGVyLXJhZGl1czogMDsgb3ZlcmZsb3c6IGhpZGRlbjsgYmFja2dyb3VuZDogI2ZmZjsKICBkaXNwbGF5OiBmbGV4OyBmbGV4LWRpcmVjdGlvbjogY29s
;dW1uOwp9Ci5wcm9jLXRhYmxlLXdyYXAuaGlkZGVuIHsgZGlzcGxheTogbm9uZTsgfQovKiDnu5/kuIDliJflrr3vvJrooajlpLTkuI7mlbDmja7lkIzkuIDl
;pZfmqKHmnb/vvIzpgb/lhY3mu5rliqjmnaHplJnkvY0gKi8KLnByb2MtY29scyB7CiAgLS1jLW5hbWU6IG1pbm1heCgxODBweCwgMS42ZnIpOwogIC0tYy1j
;cHU6IDcycHg7CiAgLS1jLW1lbTogOTZweDsKICAtLWMtcGlkOiA4MHB4OwogIC0tYy1wcm90bzogNjhweDsKICAtLWMtbGlwOiBtaW5tYXgoMTEwcHgsIDFm
;cik7CiAgLS1jLWxwb3J0OiA3NnB4OwogIC0tYy1yaXA6IG1pbm1heCgxMTBweCwgMWZyKTsKICAtLWMtcnBvcnQ6IDc2cHg7CiAgLS1jLXN0YXRlOiA4OHB4
;OwogIGRpc3BsYXk6IGdyaWQ7CiAgZ3JpZC10ZW1wbGF0ZS1jb2x1bW5zOiB2YXIoLS1jLW5hbWUpIHZhcigtLWMtY3B1KSB2YXIoLS1jLW1lbSkgdmFyKC0t
;Yy1waWQpIHZhcigtLWMtcHJvdG8pIHZhcigtLWMtbGlwKSB2YXIoLS1jLWxwb3J0KSB2YXIoLS1jLXJpcCkgdmFyKC0tYy1ycG9ydCkgdmFyKC0tYy1zdGF0
;ZSk7CiAgZ2FwOiAwOwogIGFsaWduLWl0ZW1zOiBzdHJldGNoOwogIHdpZHRoOiAxMDAlOwogIGJveC1zaXppbmc6IGJvcmRlci1ib3g7Cn0KLnByb2Mtc2Ny
;b2xsIHsKICBmbGV4OiAxOyBtaW4taGVpZ2h0OiAwOyBvdmVyZmxvdzogYXV0bzsKICBzY3JvbGxiYXItZ3V0dGVyOiBzdGFibGU7Cn0KLyogV2luMTEg5Lu7
;5Yqh566h55CG5Zmo6aOO5qC85Y+M5bGC6KGo5aS077ya55m95bqV44CB5LiK5LiL5bGF5Lit5a+56b2QICovCi5wcm9jLWhlYWQgewogIHBvc2l0aW9uOiBz
;dGlja3k7IHRvcDogMDsgei1pbmRleDogMjsKICBiYWNrZ3JvdW5kOiAjZmZmOyBjb2xvcjogIzVhNWE1YTsKICBoZWlnaHQ6IDQ4cHg7IG1pbi1oZWlnaHQ6
;IDQ4cHg7IHBhZGRpbmc6IDA7CiAgYm9yZGVyLWJvdHRvbTogMXB4IHNvbGlkICNlNWU1ZTU7Cn0KLnByb2MtaGNlbGwgewogIGRpc3BsYXk6IGZsZXg7IGZs
;ZXgtZGlyZWN0aW9uOiBjb2x1bW47IGp1c3RpZnktY29udGVudDogc3BhY2UtYmV0d2VlbjsKICBhbGlnbi1pdGVtczogc3RyZXRjaDsKICBtaW4td2lkdGg6
;IDA7IGhlaWdodDogMTAwJTsgcGFkZGluZzogNnB4IDhweCA3cHg7CiAgYm9yZGVyLXJpZ2h0OiAxcHggc29saWQgI2U1ZTVlNTsgYm94LXNpemluZzogYm9y
;ZGVyLWJveDsKICBjdXJzb3I6IHBvaW50ZXI7IHVzZXItc2VsZWN0OiBub25lOwogIGJhY2tncm91bmQ6ICNmZmY7Cn0KLnByb2MtaGNlbGw6bGFzdC1jaGls
;ZCB7IGJvcmRlci1yaWdodDogMDsgfQoucHJvYy1oY2VsbDpob3ZlciB7IGJhY2tncm91bmQ6ICNmN2Y3Zjc7IH0KLnByb2MtaGNlbGwuc29ydGVkIHsgYmFj
;a2dyb3VuZDogI2ZmZjsgfQoucHJvYy1oLXRvcCB7CiAgZmxleDogMTsKICBtaW4taGVpZ2h0OiAxOHB4OwogIGZvbnQtc2l6ZTogMTNweDsgZm9udC13ZWln
;aHQ6IDYwMDsKICBjb2xvcjogIzFiMWIxYjsgd2hpdGUtc3BhY2U6IG5vd3JhcDsKICBkaXNwbGF5OiBmbGV4OyBhbGlnbi1pdGVtczogZmxleC1zdGFydDsg
;anVzdGlmeS1jb250ZW50OiBjZW50ZXI7CiAgZ2FwOiA0cHg7IGxpbmUtaGVpZ2h0OiAxLjI7CiAgcG9zaXRpb246IHJlbGF0aXZlOwp9Ci5wcm9jLWNlbGwt
;bmFtZSAucHJvYy1oLXRvcCB7IGp1c3RpZnktY29udGVudDogY2VudGVyOyB9Ci5wcm9jLWgtbGFiIHsKICBmbGV4OiAwIDAgYXV0bzsKICBmb250LXNpemU6
;IDEycHg7IGZvbnQtd2VpZ2h0OiA0MDA7CiAgY29sb3I6ICM1YTVhNWE7IHRleHQtYWxpZ246IGNlbnRlcjsgd2hpdGUtc3BhY2U6IG5vd3JhcDsKICBsaW5l
;LWhlaWdodDogMS4yOwp9Ci5wcm9jLWNlbGwtbmFtZSAucHJvYy1oLWxhYiB7IHRleHQtYWxpZ246IGxlZnQ7IH0KLnByb2MtaC1zb3J0IHsKICBkaXNwbGF5
;OiBpbmxpbmUtYmxvY2s7IHdpZHRoOiAwOyBoZWlnaHQ6IDA7CiAgYm9yZGVyLWxlZnQ6IDRweCBzb2xpZCB0cmFuc3BhcmVudDsgYm9yZGVyLXJpZ2h0OiA0
;cHggc29saWQgdHJhbnNwYXJlbnQ7CiAgb3BhY2l0eTogMDsgZmxleC1zaHJpbms6IDA7Cn0KLnByb2MtaGNlbGwuc29ydGVkIC5wcm9jLWgtc29ydCB7IG9w
;YWNpdHk6IDE7IH0KLnByb2MtaGNlbGwuc29ydGVkLmFzYyAucHJvYy1oLXNvcnQgewogIGJvcmRlci1ib3R0b206IDVweCBzb2xpZCAjMWIxYjFiOyBib3Jk
;ZXItdG9wOiAwOwp9Ci5wcm9jLWhjZWxsLnNvcnRlZC5kZXNjIC5wcm9jLWgtc29ydCB7CiAgYm9yZGVyLXRvcDogNXB4IHNvbGlkICMxYjFiMWI7IGJvcmRl
;ci1ib3R0b206IDA7Cn0KLnByb2MtYm9keSB7IGRpc3BsYXk6IGJsb2NrOyB9Ci5wcm9jLXJvdyB7CiAgbWluLWhlaWdodDogMjhweDsgaGVpZ2h0OiAyOHB4
;OyBwYWRkaW5nOiAwOwogIGZvbnQtc2l6ZTogMTJweDsgY29sb3I6ICMxYjFiMWI7CiAgYm9yZGVyLWJvdHRvbTogMDsKICBjdXJzb3I6IGRlZmF1bHQ7IGJh
;Y2tncm91bmQ6ICNmZmY7IHVzZXItc2VsZWN0OiBub25lOwogIHBvc2l0aW9uOiByZWxhdGl2ZTsKfQoucHJvYy1yb3c6aG92ZXIgeyBiYWNrZ3JvdW5kOiAj
;ZjVmOGZiOyB9Ci5wcm9jLXJvdy5vbiwgLnByb2Mtcm93Lm9uOmhvdmVyIHsgYmFja2dyb3VuZDogI2NjZThmZjsgfQovKiDlkIzlkI3ov5vnqIvov57nu63m
;rrXvvJrku4Xmt6Hnu7/oibLlpJbmoYbvvIzml6DlupXoibIgKi8KLnByb2Mtcm93LmdycC1maXJzdCB7CiAgYm94LXNoYWRvdzogaW5zZXQgMCAycHggMCAj
;ODhmZmMxLCBpbnNldCAycHggMCAwICM4OGZmYzEsIGluc2V0IC0ycHggMCAwICM4OGZmYzE7CiAgYm9yZGVyLXJhZGl1czogNHB4IDRweCAwIDA7Cn0KLnBy
;b2Mtcm93LmdycC1taWQgewogIGJveC1zaGFkb3c6IGluc2V0IDJweCAwIDAgIzg4ZmZjMSwgaW5zZXQgLTJweCAwIDAgIzg4ZmZjMTsKICBib3JkZXItcmFk
;aXVzOiAwOwp9Ci5wcm9jLXJvdy5ncnAtbGFzdCB7CiAgYm94LXNoYWRvdzogaW5zZXQgMCAtMnB4IDAgIzg4ZmZjMSwgaW5zZXQgMnB4IDAgMCAjODhmZmMx
;LCBpbnNldCAtMnB4IDAgMCAjODhmZmMxOwogIGJvcmRlci1yYWRpdXM6IDAgMCA0cHggNHB4Owp9Ci5wcm9jLXJvdy5ncnAtb25seSwKLnByb2Mtcm93Lmdy
;cC1maXJzdC5ncnAtbGFzdCB7CiAgYm94LXNoYWRvdzogaW5zZXQgMCAwIDAgMnB4ICM4OGZmYzE7CiAgYm9yZGVyLXJhZGl1czogNHB4Owp9Ci8qIOe7hOWG
;hemdnueEpueCueihjOS/neaMgeeZveW6le+8m+ecn+ato+eCueS4reeahOmCo+S4gOihjOS/neeVmeiTneiJsuW6lSAqLwoucHJvYy1yb3cuZ3JwOm5vdCgu
;b24pIHsgYmFja2dyb3VuZDogI2ZmZjsgfQoucHJvYy1yb3cuZ3JwOm5vdCgub24pOmhvdmVyIHsgYmFja2dyb3VuZDogI2Y1ZjhmYjsgfQovKiBXaW5kb3dz
;IOa3oeerlue6v++8m+WNleWFg+agvOWQjOWuveWQjOWeq++8jOihqOWktOS4juaVsOaNruS4peagvOWvuem9kCAqLwoucHJvYy1yb3cgPiBkaXYgewogIGRp
;c3BsYXk6IGZsZXg7CiAgYWxpZ24taXRlbXM6IGNlbnRlcjsKICBtaW4td2lkdGg6IDA7CiAgaGVpZ2h0OiAxMDAlOwogIHBhZGRpbmc6IDAgOHB4OwogIGJv
;cmRlci1yaWdodDogMXB4IHNvbGlkICNlNWU1ZTU7CiAgYm94LXNpemluZzogYm9yZGVyLWJveDsKICBvdmVyZmxvdzogaGlkZGVuOwogIHdoaXRlLXNwYWNl
;OiBub3dyYXA7Cn0KLnByb2Mtcm93ID4gZGl2Omxhc3QtY2hpbGQgeyBib3JkZXItcmlnaHQ6IDA7IH0KLnByb2MtY2VsbC1uYW1lIHsganVzdGlmeS1jb250
;ZW50OiBmbGV4LXN0YXJ0OyB9Ci5wcm9jLWNlbGwtcGlkLAoucHJvYy1jZWxsLXBvcnQsCi5wcm9jLWNlbGwtY3B1LAoucHJvYy1jZWxsLW1lbSB7IGp1c3Rp
;ZnktY29udGVudDogZmxleC1lbmQ7IH0KLnByb2MtY2VsbC1wcm90byB7IGp1c3RpZnktY29udGVudDogY2VudGVyOyB9Ci5wcm9jLWNlbGwtc3RhdGUgeyBq
;dXN0aWZ5LWNvbnRlbnQ6IGZsZXgtc3RhcnQ7IGdhcDogNnB4OyB9Ci5wcm9jLWNlbGwtaXAgeyBqdXN0aWZ5LWNvbnRlbnQ6IGZsZXgtc3RhcnQ7IH0KLnBy
;b2MtY2VsbC1jcHUsIC5wcm9jLWNlbGwtbWVtIHsKICBiYWNrZ3JvdW5kOiAjY2VmZmU1Owp9Ci5wcm9jLWNlbGwtY3B1LmhvdCwgLnByb2MtY2VsbC1tZW0u
;aG90IHsKICBiYWNrZ3JvdW5kOiAjODhmZmMxOwp9Ci5wcm9jLXJvdy5vbiAucHJvYy1jZWxsLWNwdSwKLnByb2Mtcm93Lm9uIC5wcm9jLWNlbGwtbWVtIHsK
;ICBiYWNrZ3JvdW5kOiAjY2VmZmU1Owp9Ci5wcm9jLXJvdy5vbiAucHJvYy1jZWxsLWNwdS5ob3QsCi5wcm9jLXJvdy5vbiAucHJvYy1jZWxsLW1lbS5ob3Qg
;ewogIGJhY2tncm91bmQ6ICM4OGZmYzE7Cn0KLnByb2MtaGNlbGwucHJvYy1jZWxsLWNwdSwKLnByb2MtaGNlbGwucHJvYy1jZWxsLW1lbSB7CiAgYmFja2dy
;b3VuZDogI2ZmZjsKfQoucHJvYy1oY2VsbC5wcm9jLWNlbGwtY3B1LmhvdCwKLnByb2MtaGNlbGwucHJvYy1jZWxsLW1lbS5ob3QgewogIGJhY2tncm91bmQ6
;ICM4OGZmYzE7Cn0KLnByb2MtaGNlbGwucHJvYy1jZWxsLWNwdTpub3QoLmhvdCksCi5wcm9jLWhjZWxsLnByb2MtY2VsbC1tZW06bm90KC5ob3QpIHsKICBi
;YWNrZ3JvdW5kOiAjY2VmZmU1Owp9Ci5wcm9jLW5hbWUgewogIGRpc3BsYXk6IGZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGdhcDogOHB4OwogIG1pbi13
;aWR0aDogMDsgd2lkdGg6IDEwMCU7IG92ZXJmbG93OiBoaWRkZW47Cn0KLnByb2MtbmFtZSBpbWcsIC5wcm9jLW5hbWUgLnByb2MtaWNvLXBoIHsKICB3aWR0
;aDogMTZweDsgaGVpZ2h0OiAxNnB4OyBvYmplY3QtZml0OiBjb250YWluOyBmbGV4LXNocmluazogMDsKfQoucHJvYy1uYW1lIC5wcm9jLWljby1waCB7CiAg
;ZGlzcGxheTogaW5saW5lLWJsb2NrOyBiYWNrZ3JvdW5kOiAjZThlYWVkOyBib3JkZXItcmFkaXVzOiAycHg7CiAgYm9yZGVyOiAxcHggc29saWQgI2QwZDRk
;YTsKfQoucHJvYy1uYW1lIC5wcm9jLWxhYmVsIHsKICBvdmVyZmxvdzogaGlkZGVuOyB0ZXh0LW92ZXJmbG93OiBlbGxpcHNpczsgd2hpdGUtc3BhY2U6IG5v
;d3JhcDsgbWluLXdpZHRoOiAwOwp9Ci5wcm9jLW5ldC1kb3QgewogIHdpZHRoOiA3cHg7IGhlaWdodDogN3B4OyBib3JkZXItcmFkaXVzOiA1MCU7IGZsZXgt
;c2hyaW5rOiAwOwogIGJhY2tncm91bmQ6ICMyMmM1NWU7IGJveC1zaGFkb3c6IDAgMCAwIDJweCByZ2JhKDM0LCAxOTcsIDk0LCAuMik7Cn0KLnByb2MtbmV0
;LWRvdC5oaWRkZW4geyBkaXNwbGF5OiBub25lOyB9Ci5wcm9jLW51bSB7CiAgZm9udC12YXJpYW50LW51bWVyaWM6IHRhYnVsYXItbnVtczsgY29sb3I6ICMx
;YjFiMWI7CiAgd2lkdGg6IDEwMCU7Cn0KLnByb2MtbnVtLnBvcnQtaG90IHsKICBjb2xvcjogI2MyNDEwYzsKICBmb250LXdlaWdodDogNzAwOwp9Ci8qIOKU
;gOKUgCDlhbPogZTlj6Xmn4TvvIjnjrDku6Povbvph4/ooajmoLzvvInilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDi
;lIDilIDilIDilIDilIDilIDilIDilIDilIAgKi8KI2hhbmRsZS1wYW5lbCB7CiAgZmxleDogMTsgbWluLWhlaWdodDogMDsgbWFyZ2luOiAwOyBib3JkZXI6
;IDA7CiAgYmFja2dyb3VuZDogI2ZmZjsgZGlzcGxheTogZmxleDsgZmxleC1kaXJlY3Rpb246IGNvbHVtbjsgb3ZlcmZsb3c6IGhpZGRlbjsKfQojaGFuZGxl
;LXBhbmVsLmhpZGRlbiB7IGRpc3BsYXk6IG5vbmU7IH0KLmhhbmRsZS1iYW5uZXIgewogIGRpc3BsYXk6IG5vbmU7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGdh
;cDogOHB4OwogIG1hcmdpbjogMDsgcGFkZGluZzogOHB4IDE0cHg7CiAgYmFja2dyb3VuZDogI2YwZjdmZjsgYm9yZGVyOiAwOyBib3JkZXItcmFkaXVzOiAw
;OwogIGNvbG9yOiAjMWUzYTVmOyBmb250LXNpemU6IDEyLjVweDsgZmxleC1zaHJpbms6IDA7Cn0KLmhhbmRsZS1iYW5uZXIub24geyBkaXNwbGF5OiBmbGV4
;OyB9Ci5oYW5kbGUtYmFubmVyOjpiZWZvcmUgewogIGNvbnRlbnQ6ICIiOyB3aWR0aDogNnB4OyBoZWlnaHQ6IDZweDsgYm9yZGVyLXJhZGl1czogNTAlOwog
;IGJhY2tncm91bmQ6ICMzYjgyZjY7IGZsZXgtc2hyaW5rOiAwOwp9Ci5oYW5kbGUtY29scyB7CiAgLS1oLW5hbWU6IG1pbm1heCgxNDBweCwgMS4yZnIpOwog
;IC0taC1waWQ6IDg4cHg7CiAgLS1oLXBvcnQ6IDg0cHg7CiAgLS1oLXJwb3J0OiA4NHB4OwogIC0taC10eXBlOiA3MnB4OwogIC0taC1wYXRoOiBtaW5tYXgo
;MTYwcHgsIDJmcik7CiAgZGlzcGxheTogZ3JpZDsKICBncmlkLXRlbXBsYXRlLWNvbHVtbnM6IHZhcigtLWgtbmFtZSkgdmFyKC0taC1waWQpIHZhcigtLWgt
;dHlwZSkgdmFyKC0taC1wYXRoKTsKICBnYXA6IDA7IHdpZHRoOiAxMDAlOyBib3gtc2l6aW5nOiBib3JkZXItYm94OyBhbGlnbi1pdGVtczogc3RyZXRjaDsK
;fQouaGFuZGxlLWNvbHMucG9ydC1tb2RlIHsKICBncmlkLXRlbXBsYXRlLWNvbHVtbnM6IHZhcigtLWgtbmFtZSkgdmFyKC0taC1waWQpIHZhcigtLWgtcG9y
;dCkgdmFyKC0taC1ycG9ydCkgdmFyKC0taC10eXBlKSB2YXIoLS1oLXBhdGgpOwp9Ci5oYW5kbGUtY29sLXBvcnQuaGlkZGVuLCAuaGFuZGxlLWNvbC1ycG9y
;dC5oaWRkZW4geyBkaXNwbGF5OiBub25lICFpbXBvcnRhbnQ7IH0KLmhhbmRsZS1jb2xzLnBvcnQtbW9kZSAuaGFuZGxlLWNvbC1wb3J0LmhpZGRlbiwKLmhh
;bmRsZS1jb2xzLnBvcnQtbW9kZSAuaGFuZGxlLWNvbC1ycG9ydC5oaWRkZW4geyBkaXNwbGF5OiBmbGV4ICFpbXBvcnRhbnQ7IH0KLmhhbmRsZS1zY3JvbGwg
;eyBmbGV4OiAxOyBtaW4taGVpZ2h0OiAwOyBvdmVyZmxvdzogYXV0bzsgcGFkZGluZzogMCA4cHggOHB4OyB9Ci5oYW5kbGUtaGVhZCB7CiAgcG9zaXRpb246
;IHN0aWNreTsgdG9wOiAwOyB6LWluZGV4OiAyOyBoZWlnaHQ6IDM0cHg7IG1pbi1oZWlnaHQ6IDM0cHg7CiAgYmFja2dyb3VuZDogI2ZmZjsgY29sb3I6IHZh
;cigtLXR4dDIpOyBmb250LXNpemU6IDEycHg7IGZvbnQtd2VpZ2h0OiA2MDA7CiAgYm9yZGVyLWJvdHRvbTogMXB4IHNvbGlkIHZhcigtLWxpbmUpOwp9Ci5o
;YW5kbGUtaGNlbGwgewogIGN1cnNvcjogcG9pbnRlcjsgdXNlci1zZWxlY3Q6IG5vbmU7IGdhcDogNnB4Owp9Ci5oYW5kbGUtaGNlbGw6aG92ZXIgeyBiYWNr
;Z3JvdW5kOiAjZjVmN2ZiOyBjb2xvcjogdmFyKC0tdHh0KTsgfQouaGFuZGxlLWhjZWxsLnNvcnRlZCB7IGNvbG9yOiB2YXIoLS10eHQpOyB9Ci5oYW5kbGUt
;aGNlbGwgLmgtc29ydCB7CiAgZGlzcGxheTogaW5saW5lLWJsb2NrOyB3aWR0aDogMDsgaGVpZ2h0OiAwOwogIGJvcmRlci1sZWZ0OiA0cHggc29saWQgdHJh
;bnNwYXJlbnQ7IGJvcmRlci1yaWdodDogNHB4IHNvbGlkIHRyYW5zcGFyZW50OwogIG9wYWNpdHk6IDA7IGZsZXgtc2hyaW5rOiAwOwp9Ci5oYW5kbGUtaGNl
;bGwuc29ydGVkIC5oLXNvcnQgeyBvcGFjaXR5OiAxOyB9Ci5oYW5kbGUtaGNlbGwuc29ydGVkLmFzYyAuaC1zb3J0IHsKICBib3JkZXItYm90dG9tOiA1cHgg
;c29saWQgIzFiMWIxYjsgYm9yZGVyLXRvcDogMDsKfQouaGFuZGxlLWhjZWxsLnNvcnRlZC5kZXNjIC5oLXNvcnQgewogIGJvcmRlci10b3A6IDVweCBzb2xp
;ZCAjMWIxYjFiOyBib3JkZXItYm90dG9tOiAwOwp9Ci5oYW5kbGUtYm9keSB7IGRpc3BsYXk6IGJsb2NrOyBwYWRkaW5nLXRvcDogMnB4OyB9Ci5oYW5kbGUt
;cm93IHsKICBtaW4taGVpZ2h0OiAzNnB4OyBoZWlnaHQ6IDM2cHg7IGZvbnQtc2l6ZTogMTNweDsgY29sb3I6IHZhcigtLXR4dCk7CiAgYm9yZGVyOiAwOyBi
;b3JkZXItcmFkaXVzOiA4cHg7IGJhY2tncm91bmQ6IHRyYW5zcGFyZW50OyBjdXJzb3I6IGRlZmF1bHQ7IHVzZXItc2VsZWN0OiBub25lOwogIG1hcmdpbjog
;MXB4IDA7Cn0KLmhhbmRsZS1yb3c6aG92ZXIgeyBiYWNrZ3JvdW5kOiAjZjVmN2ZiOyB9Ci5oYW5kbGUtcm93Lm9uLCAuaGFuZGxlLXJvdy5vbjpob3ZlciB7
;IGJhY2tncm91bmQ6IHZhcigtLXNlbCk7IH0KLmhhbmRsZS1oZWFkID4gZGl2LAouaGFuZGxlLXJvdyA+IGRpdiB7CiAgZGlzcGxheTogZmxleDsgYWxpZ24t
;aXRlbXM6IGNlbnRlcjsgbWluLXdpZHRoOiAwOyBoZWlnaHQ6IDEwMCU7CiAgcGFkZGluZzogMCAxMnB4OyBib3JkZXI6IDA7IGJveC1zaXppbmc6IGJvcmRl
;ci1ib3g7CiAgb3ZlcmZsb3c6IGhpZGRlbjsgd2hpdGUtc3BhY2U6IG5vd3JhcDsgdGV4dC1vdmVyZmxvdzogZWxsaXBzaXM7Cn0KLmhhbmRsZS1uYW1lIHsK
;ICBkaXNwbGF5OiBmbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBnYXA6IDEwcHg7IG1pbi13aWR0aDogMDsgd2lkdGg6IDEwMCU7IG92ZXJmbG93OiBoaWRk
;ZW47Cn0KLmhhbmRsZS1uYW1lIGltZywgLmhhbmRsZS1uYW1lIC5oYW5kbGUtaWNvLXBoIHsKICB3aWR0aDogMThweDsgaGVpZ2h0OiAxOHB4OyBvYmplY3Qt
;Zml0OiBjb250YWluOyBmbGV4LXNocmluazogMDsKfQouaGFuZGxlLW5hbWUgLmhhbmRsZS1pY28tcGggewogIGRpc3BsYXk6IGlubGluZS1ibG9jazsgYmFj
;a2dyb3VuZDogI2VlZjFmNjsgYm9yZGVyLXJhZGl1czogNHB4OyBib3JkZXI6IDA7Cn0KLmhhbmRsZS1uYW1lIHNwYW4gewogIG92ZXJmbG93OiBoaWRkZW47
;IHRleHQtb3ZlcmZsb3c6IGVsbGlwc2lzOyB3aGl0ZS1zcGFjZTogbm93cmFwOyBtaW4td2lkdGg6IDA7IGZvbnQtd2VpZ2h0OiA1MDA7Cn0KLmhhbmRsZS1u
;ZXQtZG90IHsKICB3aWR0aDogN3B4OyBoZWlnaHQ6IDdweDsgYm9yZGVyLXJhZGl1czogNTAlOyBmbGV4LXNocmluazogMDsKICBiYWNrZ3JvdW5kOiAjMjJj
;NTVlOyBib3gtc2hhZG93OiAwIDAgMCAycHggcmdiYSgzNCwgMTk3LCA5NCwgLjIpOwp9Ci5oYW5kbGUtc3RhdGUgewogIGRpc3BsYXk6IGZsZXg7IGFsaWdu
;LWl0ZW1zOiBjZW50ZXI7IGdhcDogNnB4OyBtaW4td2lkdGg6IDA7Cn0KLmhhbmRsZS1lbXB0eSB7CiAgcGFkZGluZzogNDhweCAxNnB4OyB0ZXh0LWFsaWdu
;OiBjZW50ZXI7IGNvbG9yOiB2YXIoLS10eHQzKTsgZm9udC1zaXplOiAxMy41cHg7IGxpbmUtaGVpZ2h0OiAxLjY7Cn0KLmhhbmRsZS1sb2FkaW5nIHsKICBk
;aXNwbGF5OiBmbGV4OyBmbGV4LWRpcmVjdGlvbjogY29sdW1uOyBhbGlnbi1pdGVtczogY2VudGVyOyBqdXN0aWZ5LWNvbnRlbnQ6IGNlbnRlcjsKICBnYXA6
;IDE0cHg7IHBhZGRpbmc6IDY0cHggMTZweDsgY29sb3I6IHZhcigtLXR4dDIpOyBmb250LXNpemU6IDEzcHg7Cn0KLmhhbmRsZS1zcGlubmVyIHsKICB3aWR0
;aDogMjZweDsgaGVpZ2h0OiAyNnB4OyBib3JkZXItcmFkaXVzOiA1MCU7IGJveC1zaXppbmc6IGJvcmRlci1ib3g7CiAgYm9yZGVyOiAyLjVweCBzb2xpZCAj
;ZTVlN2ViOyBib3JkZXItdG9wLWNvbG9yOiAjZTQyMDc5OwogIGFuaW1hdGlvbjogaGFuZGxlLXNwaW4gLjdzIGxpbmVhciBpbmZpbml0ZTsKfQpAa2V5ZnJh
;bWVzIGhhbmRsZS1zcGluIHsKICB0byB7IHRyYW5zZm9ybTogcm90YXRlKDM2MGRlZyk7IH0KfQouaW5mby1sb2FkaW5nIHsKICBkaXNwbGF5OiBmbGV4OyBm
;bGV4LWRpcmVjdGlvbjogY29sdW1uOyBhbGlnbi1pdGVtczogY2VudGVyOyBqdXN0aWZ5LWNvbnRlbnQ6IGNlbnRlcjsKICBnYXA6IDE0cHg7IG1pbi1oZWln
;aHQ6IDI0MHB4OyBwYWRkaW5nOiA2NHB4IDE2cHg7IGNvbG9yOiB2YXIoLS10eHQyKTsgZm9udC1zaXplOiAxM3B4OwogIGJveC1zaXppbmc6IGJvcmRlci1i
;b3g7Cn0KLmluZm8tc3Bpbm5lciB7CiAgd2lkdGg6IDI4cHg7IGhlaWdodDogMjhweDsgYm9yZGVyLXJhZGl1czogNTAlOyBib3gtc2l6aW5nOiBib3JkZXIt
;Ym94OwogIGJvcmRlcjogMi41cHggc29saWQgI2U1ZTdlYjsgYm9yZGVyLXRvcC1jb2xvcjogI2U0MjA3OTsKICBhbmltYXRpb246IGhhbmRsZS1zcGluIC43
;cyBsaW5lYXIgaW5maW5pdGU7Cn0KI2Jhci1oYW5kbGUtYWN0aW9ucyB7CiAgZGlzcGxheTogbm9uZTsgYWxpZ24taXRlbXM6IGNlbnRlcjsgZ2FwOiAxMHB4
;OyBtYXJnaW4tcmlnaHQ6IDhweDsgbWluLXdpZHRoOiAwOwogIHBvc2l0aW9uOiByZWxhdGl2ZTsKfQojYmFyLm1vZGUtaGFuZGxlICNiYXItaGFuZGxlLWFj
;dGlvbnMgeyBkaXNwbGF5OiBpbmxpbmUtZmxleDsgfQojYmFyLWhhbmRsZS1hY3Rpb25zICNoYW5kbGUtc3RhdHVzIHsKICBjb2xvcjogdmFyKC0tdHh0Myk7
;IGZvbnQtc2l6ZTogMTJweDsgbWF4LXdpZHRoOiAyNDBweDsKICBvdmVyZmxvdzogaGlkZGVuOyB0ZXh0LW92ZXJmbG93OiBlbGxpcHNpczsgd2hpdGUtc3Bh
;Y2U6IG5vd3JhcDsKfQojYnRuLXBvcnQtbWFyayB7CiAgd2lkdGg6IDI4cHg7IGhlaWdodDogMjhweDsgYm9yZGVyOiAwOyBib3JkZXItcmFkaXVzOiA4cHg7
;CiAgYmFja2dyb3VuZDogdHJhbnNwYXJlbnQ7IGNvbG9yOiB2YXIoLS10eHQyKTsgZm9udC1zaXplOiAxNXB4OwogIGN1cnNvcjogcG9pbnRlcjsgbGluZS1o
;ZWlnaHQ6IDE7IGZsZXgtc2hyaW5rOiAwOwp9CiNidG4tcG9ydC1tYXJrOmhvdmVyLCAjYnRuLXBvcnQtbWFyay5vbiB7CiAgYmFja2dyb3VuZDogI2VlZjFm
;NjsgY29sb3I6IHZhcigtLXR4dCk7Cn0KI2Jhci5tb2RlLWhhbmRsZSAuc29ydCwgI2Jhci5tb2RlLWhhbmRsZSAudG9nZ2xlIHsgZGlzcGxheTogbm9uZTsg
;fQouaGFuZGxlLWNvbC1wb3J0LnBvcnQtaG90LAouaGFuZGxlLWNvbC1ycG9ydC5wb3J0LWhvdCB7CiAgY29sb3I6ICNjMjQxMGM7IGZvbnQtd2VpZ2h0OiA3
;MDA7Cn0KI3BvcnQtbWFyay1wb3AgewogIGRpc3BsYXk6IG5vbmU7IHBvc2l0aW9uOiBhYnNvbHV0ZTsgcmlnaHQ6IDA7IGJvdHRvbTogY2FsYygxMDAlICsg
;OHB4KTsKICB3aWR0aDogMzAwcHg7IHotaW5kZXg6IDgwOyBwYWRkaW5nOiAxMnB4OwogIGJhY2tncm91bmQ6ICNmZmY7IGJvcmRlcjogMXB4IHNvbGlkIHZh
;cigtLWxpbmUpOyBib3JkZXItcmFkaXVzOiAxMnB4OwogIGJveC1zaGFkb3c6IDAgMTJweCAyOHB4IHJnYmEoMTUsIDIzLCA0MiwgLjEyKTsKfQojcG9ydC1t
;YXJrLXBvcC5vbiB7IGRpc3BsYXk6IGJsb2NrOyB9Ci5wbXAtaGQgeyBmb250LXNpemU6IDEzLjVweDsgZm9udC13ZWlnaHQ6IDY1MDsgY29sb3I6IHZhcigt
;LXR4dCk7IG1hcmdpbi1ib3R0b206IDRweDsgfQoucG1wLWhpbnQgeyBmb250LXNpemU6IDEycHg7IGNvbG9yOiB2YXIoLS10eHQzKTsgbWFyZ2luLWJvdHRv
;bTogMTBweDsgbGluZS1oZWlnaHQ6IDEuNDsgfQoucG1wLXRhZ3MgewogIGRpc3BsYXk6IGZsZXg7IGZsZXgtd3JhcDogd3JhcDsgZ2FwOiA2cHg7IG1pbi1o
;ZWlnaHQ6IDMycHg7CiAgbWF4LWhlaWdodDogMTQwcHg7IG92ZXJmbG93OiBhdXRvOyBtYXJnaW4tYm90dG9tOiAxMHB4Owp9Ci5wbXAtdGFnIHsKICBkaXNw
;bGF5OiBpbmxpbmUtZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsgZ2FwOiA0cHg7CiAgaGVpZ2h0OiAyNnB4OyBwYWRkaW5nOiAwIDRweCAwIDEwcHg7IGJv
;cmRlci1yYWRpdXM6IDk5OXB4OwogIGJhY2tncm91bmQ6ICNmZmY3ZWQ7IGNvbG9yOiAjYzI0MTBjOyBmb250LXNpemU6IDEyLjVweDsgZm9udC13ZWlnaHQ6
;IDYwMDsKICBmb250LXZhcmlhbnQtbnVtZXJpYzogdGFidWxhci1udW1zOwp9Ci5wbXAtdGFnIGJ1dHRvbiB7CiAgd2lkdGg6IDIwcHg7IGhlaWdodDogMjBw
;eDsgYm9yZGVyOiAwOyBib3JkZXItcmFkaXVzOiA1MCU7CiAgYmFja2dyb3VuZDogdHJhbnNwYXJlbnQ7IGNvbG9yOiAjZWE1ODBjOyBjdXJzb3I6IHBvaW50
;ZXI7IGZvbnQtc2l6ZTogMTRweDsgbGluZS1oZWlnaHQ6IDE7Cn0KLnBtcC10YWcgYnV0dG9uOmhvdmVyIHsgYmFja2dyb3VuZDogI2ZmZWRkNTsgfQoucG1w
;LWVtcHR5IHsgY29sb3I6IHZhcigtLXR4dDMpOyBmb250LXNpemU6IDEycHg7IHBhZGRpbmc6IDZweCAycHg7IH0KLnBtcC1hZGQgeyBkaXNwbGF5OiBmbGV4
;OyBnYXA6IDhweDsgYWxpZ24taXRlbXM6IGNlbnRlcjsgbWFyZ2luLWJvdHRvbTogOHB4OyB9Ci5wbXAtYWRkIGlucHV0IHsKICBmbGV4OiAxOyBtaW4td2lk
;dGg6IDA7IGhlaWdodDogMzJweDsgYm9yZGVyOiAxcHggc29saWQgdmFyKC0tbGluZSk7IGJvcmRlci1yYWRpdXM6IDhweDsKICBwYWRkaW5nOiAwIDEwcHg7
;IG91dGxpbmU6IG5vbmU7IGZvbnQtc2l6ZTogMTNweDsgYmFja2dyb3VuZDogI2ZiZmJmZDsKfQoucG1wLWFkZCBpbnB1dDpmb2N1cyB7IGJvcmRlci1jb2xv
;cjogIzkzYzVmZDsgYmFja2dyb3VuZDogI2ZmZjsgfQoucG1wLWFkZCBidXR0b24sIC5wbXAtcmVzZXQgewogIGhlaWdodDogMzJweDsgcGFkZGluZzogMCAx
;MnB4OyBib3JkZXI6IDA7IGJvcmRlci1yYWRpdXM6IDhweDsKICBiYWNrZ3JvdW5kOiAjZWZmNmZmOyBjb2xvcjogIzFkNGVkODsgZm9udC1zaXplOiAxMi41
;cHg7IGZvbnQtd2VpZ2h0OiA2MDA7IGN1cnNvcjogcG9pbnRlcjsKfQoucG1wLWFkZCBidXR0b246aG92ZXIgeyBiYWNrZ3JvdW5kOiAjZGJlYWZlOyB9Ci5w
;bXAtcmVzZXQgewogIHdpZHRoOiAxMDAlOyBiYWNrZ3JvdW5kOiB0cmFuc3BhcmVudDsgY29sb3I6IHZhcigtLXR4dDIpOyBmb250LXdlaWdodDogNTAwOwp9
;Ci5wbXAtcmVzZXQ6aG92ZXIgeyBiYWNrZ3JvdW5kOiAjZjNmNGY2OyBjb2xvcjogdmFyKC0tdHh0KTsgfQojaGFuZGxlLXRhZy1wb3AgewogIGRpc3BsYXk6
;IG5vbmU7IHBvc2l0aW9uOiBmaXhlZDsgaW5zZXQ6IDA7IHotaW5kZXg6IDMwMDsKICBiYWNrZ3JvdW5kOiByZ2JhKDE1LCAyMywgNDIsIC4yOCk7IGFsaWdu
;LWl0ZW1zOiBjZW50ZXI7IGp1c3RpZnktY29udGVudDogY2VudGVyOwp9CiNoYW5kbGUtdGFnLXBvcC5vbiB7IGRpc3BsYXk6IGZsZXg7IH0KI2hhbmRsZS10
;YWctcG9wIC5odHAtY2FyZCB7CiAgd2lkdGg6IG1pbigzNDBweCwgOTJ2dyk7IG1heC1oZWlnaHQ6IG1pbig1MjBweCwgODh2aCk7CiAgcGFkZGluZzogMTRw
;eCAxNnB4IDE2cHg7IGJveC1zaXppbmc6IGJvcmRlci1ib3g7CiAgYmFja2dyb3VuZDogI2ZmZjsgYm9yZGVyOiAxcHggc29saWQgdmFyKC0tbGluZSk7IGJv
;cmRlci1yYWRpdXM6IDE0cHg7CiAgYm94LXNoYWRvdzogMCAxOHB4IDQwcHggcmdiYSgxNSwgMjMsIDQyLCAuMTgpOwogIGRpc3BsYXk6IGZsZXg7IGZsZXgt
;ZGlyZWN0aW9uOiBjb2x1bW47IG92ZXJmbG93OiBoaWRkZW47Cn0KLmh0cC1oZCB7CiAgZGlzcGxheTogZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsganVz
;dGlmeS1jb250ZW50OiBzcGFjZS1iZXR3ZWVuOwogIGZvbnQtc2l6ZTogMTRweDsgZm9udC13ZWlnaHQ6IDY1MDsgY29sb3I6IHZhcigtLXR4dCk7IG1hcmdp
;bi1ib3R0b206IDE2cHg7Cn0KLmh0cC1oZCAjaHRwLWNsb3NlIHsKICBib3JkZXI6IDA7IGJhY2tncm91bmQ6IHRyYW5zcGFyZW50OyBjb2xvcjogdmFyKC0t
;dHh0Mik7IGN1cnNvcjogcG9pbnRlcjsKICBmb250LXNpemU6IDE4cHg7IGxpbmUtaGVpZ2h0OiAxOyBwYWRkaW5nOiAwIDJweDsKfQouaHRwLWhpbnQgeyBk
;aXNwbGF5OiBub25lOyB9Ci5odHAtdGFncyB7CiAgZGlzcGxheTogZmxleDsgZmxleC13cmFwOiB3cmFwOyBnYXA6IDZweDsgbWluLWhlaWdodDogMzJweDsK
;ICBtYXgtaGVpZ2h0OiAxNjBweDsgb3ZlcmZsb3c6IGF1dG87IG1hcmdpbjogNHB4IDAgMTRweDsKfQouaHRwLXRhZyB7CiAgZGlzcGxheTogaW5saW5lLWZs
;ZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGdhcDogNHB4OwogIGhlaWdodDogMjZweDsgcGFkZGluZzogMCA0cHggMCAxMHB4OyBib3JkZXItcmFkaXVzOiA5
;OTlweDsKICBiYWNrZ3JvdW5kOiAjZWNmZGY1OyBjb2xvcjogIzA0Nzg1NzsgZm9udC1zaXplOiAxMi41cHg7IGZvbnQtd2VpZ2h0OiA2MDA7CiAgYm9yZGVy
;OiAxcHggc29saWQgI2E3ZjNkMDsKfQouaHRwLXRhZyBidXR0b24gewogIHdpZHRoOiAyMHB4OyBoZWlnaHQ6IDIwcHg7IGJvcmRlcjogMDsgYm9yZGVyLXJh
;ZGl1czogNTAlOwogIGJhY2tncm91bmQ6IHRyYW5zcGFyZW50OyBjb2xvcjogIzA1OTY2OTsgY3Vyc29yOiBwb2ludGVyOyBmb250LXNpemU6IDE0cHg7IGxp
;bmUtaGVpZ2h0OiAxOwp9Ci5odHAtdGFnIGJ1dHRvbjpob3ZlciB7IGJhY2tncm91bmQ6ICNkMWZhZTU7IH0KLmh0cC1lbXB0eSB7IGNvbG9yOiB2YXIoLS10
;eHQzKTsgZm9udC1zaXplOiAxMnB4OyBwYWRkaW5nOiA2cHggMnB4OyB9Ci5odHAtYWRkIHsKICBkaXNwbGF5OiBmbGV4OyBmbGV4LWRpcmVjdGlvbjogY29s
;dW1uOyBnYXA6IDEycHg7CiAgbWFyZ2luLXRvcDogOHB4OyBwYWRkaW5nLXRvcDogMTBweDsgYm9yZGVyLXRvcDogMXB4IHNvbGlkICNlZWYyZjc7Cn0KLmh0
;cC1hZGQgLmh0cC1yb3cgewogIGRpc3BsYXk6IGdyaWQ7IGdyaWQtdGVtcGxhdGUtY29sdW1uczogYXV0byBtaW5tYXgoMCwgMWZyKTsKICBhbGlnbi1pdGVt
;czogY2VudGVyOyBnYXA6IDEwcHg7IG1pbi13aWR0aDogMDsKfQouaHRwLWFkZCAuaHRwLWxhYiB7CiAgZGlzcGxheTogaW5saW5lLWZsZXg7IGFsaWduLWl0
;ZW1zOiBjZW50ZXI7IGdhcDogNnB4OwogIGZvbnQtc2l6ZTogMTNweDsgY29sb3I6IHZhcigtLXR4dDIpOyB3aGl0ZS1zcGFjZTogbm93cmFwOwp9Ci5odHAt
;YWRkIC5odHAtbGFiIHN2ZyB7CiAgd2lkdGg6IDE1cHg7IGhlaWdodDogMTVweDsgZGlzcGxheTogYmxvY2s7IGNvbG9yOiAjNjQ3NDhiOyBmbGV4LXNocmlu
;azogMDsKfQouaHRwLWFkZCBpbnB1dCB7CiAgd2lkdGg6IDEwMCU7IG1pbi13aWR0aDogMDsgaGVpZ2h0OiAzMHB4OyBib3gtc2l6aW5nOiBib3JkZXItYm94
;OwogIGJvcmRlcjogMDsgYm9yZGVyLWJvdHRvbTogMXB4IHNvbGlkICNjYmQ1ZTE7IGJvcmRlci1yYWRpdXM6IDA7CiAgcGFkZGluZzogMCAycHg7IG91dGxp
;bmU6IG5vbmU7IGZvbnQtc2l6ZTogMTNweDsgYmFja2dyb3VuZDogdHJhbnNwYXJlbnQ7IGNvbG9yOiB2YXIoLS10eHQpOwp9Ci5odHAtYWRkIGlucHV0OmZv
;Y3VzIHsKICBib3JkZXItYm90dG9tLWNvbG9yOiAjMTZhMzRhOwogIGJveC1zaGFkb3c6IG5vbmU7IGJhY2tncm91bmQ6IHRyYW5zcGFyZW50Owp9Ci5odHAt
;YWRkICNodHAtYWRkIHsKICBkaXNwbGF5OiBibG9jazsgd2lkdGg6IDEwMCU7IGhlaWdodDogMzRweDsgbWFyZ2luLXRvcDogNHB4OwogIHBhZGRpbmc6IDAg
;MTJweDsgYm9yZGVyOiAwOyBib3JkZXItcmFkaXVzOiA4cHg7CiAgYmFja2dyb3VuZDogIzE2YTM0YTsgY29sb3I6ICNmZmY7IGZvbnQtc2l6ZTogMTNweDsg
;Zm9udC13ZWlnaHQ6IDYwMDsgY3Vyc29yOiBwb2ludGVyOwp9Ci5odHAtYWRkICNodHAtYWRkOmhvdmVyIHsgYmFja2dyb3VuZDogIzE1ODAzZDsgfQoucHJv
;Yy1hY3QgewogIHdpZHRoOiAyMnB4OyBoZWlnaHQ6IDIycHg7IGJvcmRlcjogMDsgYm9yZGVyLXJhZGl1czogNHB4OyBiYWNrZ3JvdW5kOiB0cmFuc3BhcmVu
;dDsKICBjb2xvcjogIzlhYTFiMjsgY3Vyc29yOiBwb2ludGVyOyBmb250LXNpemU6IDEycHg7IGxpbmUtaGVpZ2h0OiAxOwp9Ci5wcm9jLWFjdDpob3ZlciB7
;IGJhY2tncm91bmQ6ICNlNWU3ZWI7IGNvbG9yOiAjMTExODI3OyB9Ci5wcm9jLWZvb3QgewogIGRpc3BsYXk6IGZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7
;IGp1c3RpZnktY29udGVudDogZmxleC1lbmQ7IGdhcDogMTRweDsKICBwYWRkaW5nOiA2cHggMTZweCAxMHB4OyBjb2xvcjogIzNiODJmNjsgZm9udC1zaXpl
;OiAxMi41cHg7Cn0KLnByb2MtZm9vdC5oaWRkZW4geyBkaXNwbGF5OiBub25lOyB9Ci5wcm9jLXN5cy10b2cgewogIGRpc3BsYXk6IGlubGluZS1mbGV4OyBh
;bGlnbi1pdGVtczogY2VudGVyOyBnYXA6IDhweDsgY3Vyc29yOiBwb2ludGVyOwogIHVzZXItc2VsZWN0OiBub25lOyBjb2xvcjogIzNiODJmNjsgZm9udC1z
;aXplOiAxMi41cHg7Cn0KLnByb2Mtc3lzLXRvZyBpbnB1dCB7IHBvc2l0aW9uOiBhYnNvbHV0ZTsgb3BhY2l0eTogMDsgd2lkdGg6IDA7IGhlaWdodDogMDsg
;fQoucHJvYy1zeXMtdG9nIC50b2cgewogIHdpZHRoOiAzNnB4OyBoZWlnaHQ6IDIwcHg7IGJvcmRlci1yYWRpdXM6IDk5OXB4OyBiYWNrZ3JvdW5kOiAjZDFk
;NWRiOwogIHBvc2l0aW9uOiByZWxhdGl2ZTsgZmxleC1zaHJpbms6IDA7IHRyYW5zaXRpb246IGJhY2tncm91bmQgLjE1cyBlYXNlOwp9Ci5wcm9jLXN5cy10
;b2cgLnRvZzo6YWZ0ZXIgewogIGNvbnRlbnQ6ICIiOyBwb3NpdGlvbjogYWJzb2x1dGU7IHRvcDogMnB4OyBsZWZ0OiAycHg7CiAgd2lkdGg6IDE2cHg7IGhl
;aWdodDogMTZweDsgYm9yZGVyLXJhZGl1czogNTAlOyBiYWNrZ3JvdW5kOiAjZmZmOwogIGJveC1zaGFkb3c6IDAgMXB4IDJweCByZ2JhKDAsMCwwLC4xOCk7
;IHRyYW5zaXRpb246IHRyYW5zZm9ybSAuMTVzIGVhc2U7Cn0KLnByb2Mtc3lzLXRvZyBpbnB1dDpjaGVja2VkICsgLnRvZyB7IGJhY2tncm91bmQ6ICMzYjgy
;ZjY7IH0KLnByb2Mtc3lzLXRvZyBpbnB1dDpjaGVja2VkICsgLnRvZzo6YWZ0ZXIgeyB0cmFuc2Zvcm06IHRyYW5zbGF0ZVgoMTZweCk7IH0KI3Byb2MtY291
;bnQgewogIGNvbG9yOiAjNmI3MjgwOyBmb250LXZhcmlhbnQtbnVtZXJpYzogdGFidWxhci1udW1zOyBtaW4td2lkdGg6IDIuNWVtOyB0ZXh0LWFsaWduOiBy
;aWdodDsKfQojaW5mby1wYW5lbCB7CiAgZmxleDogMTsgbWluLWhlaWdodDogMDsgbWFyZ2luOiAwOyBib3JkZXI6IDA7IGJvcmRlci1yYWRpdXM6IDA7CiAg
;b3ZlcmZsb3c6IGF1dG87IGJhY2tncm91bmQ6ICNmZmY7CiAgZGlzcGxheTogYmxvY2s7IC8qIOWLv+eUqCBmbGV4IOWIl++8muWkmuihjOe9keWNoeS8muii
;q+WOi+efruWPoOWtlyAqLwp9CiNpbmZvLXBhbmVsLmhpZGRlbiB7IGRpc3BsYXk6IG5vbmU7IH0KLmluZm8tcm93IHsKICBkaXNwbGF5OiBncmlkOyBncmlk
;LXRlbXBsYXRlLWNvbHVtbnM6IDEwOHB4IDE4cHggMWZyIGF1dG87CiAgZ2FwOiAwIDhweDsgYWxpZ24taXRlbXM6IHN0YXJ0OyBtaW4taGVpZ2h0OiAzNnB4
;OyBoZWlnaHQ6IGF1dG87CiAgcGFkZGluZzogOHB4IDE0cHg7IGJvcmRlci1ib3R0b206IDFweCBzb2xpZCAjZWVmMGY0OwogIGZsZXgtc2hyaW5rOiAwOyBv
;dmVyZmxvdzogdmlzaWJsZTsKfQouaW5mby1yb3c6bnRoLWNoaWxkKGV2ZW4pIHsgYmFja2dyb3VuZDogI2Y3ZjhmYTsgfQouaW5mby1sYWIgewogIGNvbG9y
;OiAjM2I4MmY2OyBmb250LXNpemU6IDEzcHg7IHRleHQtYWxpZ246IHJpZ2h0OyBwYWRkaW5nLXRvcDogMnB4OwogIHdoaXRlLXNwYWNlOiBub3dyYXA7Cn0K
;LmluZm8tZGFzaCB7CiAgaGVpZ2h0OiAxcHg7IGJhY2tncm91bmQ6ICNkMWQ1ZGI7IG1hcmdpbi10b3A6IDEycHg7IGFsaWduLXNlbGY6IHN0YXJ0Owp9Ci5p
;bmZvLXZhbCB7CiAgY29sb3I6ICMxMTE4Mjc7IGZvbnQtc2l6ZTogMTNweDsgbGluZS1oZWlnaHQ6IDEuNTU7IHdvcmQtYnJlYWs6IGJyZWFrLXdvcmQ7CiAg
;cGFkZGluZy10b3A6IDFweDsgbWluLXdpZHRoOiAwOyBvdmVyZmxvdzogdmlzaWJsZTsKfQouaW5mby12YWwgLnN1YiB7CiAgY29sb3I6ICMzNzQxNTE7IG1h
;cmdpbi1sZWZ0OiAyNHB4OyB3aGl0ZS1zcGFjZTogbm93cmFwOwp9CiNpbmZvLXVwdGltZSB7CiAgY29sb3I6ICMzNzQxNTE7IGZvbnQtdmFyaWFudC1udW1l
;cmljOiB0YWJ1bGFyLW51bXM7Cn0KLmluZm8tdmFsIC5saW5lIHsgZGlzcGxheTogYmxvY2s7IH0KLmluZm8tdmFsIC5uZXQtbGluZSB7CiAgZGlzcGxheTog
;Z3JpZDsgZ3JpZC10ZW1wbGF0ZS1jb2x1bW5zOiBtaW5tYXgoMTQwcHgsIDEuNWZyKSBtaW5tYXgoMTUwcHgsIDFmcikgbWlubWF4KDExMHB4LCAwLjg1ZnIp
;OwogIGdhcDogNHB4IDEycHg7IGFsaWduLWl0ZW1zOiBiYXNlbGluZTsgbWFyZ2luOiAwIDAgNnB4OyBtaW4td2lkdGg6IDA7Cn0KLmluZm8tdmFsIC5uZXQt
;bGluZTpsYXN0LWNoaWxkIHsgbWFyZ2luLWJvdHRvbTogMDsgfQouaW5mby12YWwgLm5ldC1saW5lID4gc3BhbiB7IG1pbi13aWR0aDogMDsgb3ZlcmZsb3ct
;d3JhcDogYW55d2hlcmU7IH0KLmluZm8tdmFsIC5uZXQtbGluZSAuayB7IGNvbG9yOiAjNmI3MjgwOyB9Ci5pbmZvLWxpbmsgewogIGJvcmRlcjogMDsgYmFj
;a2dyb3VuZDogdHJhbnNwYXJlbnQ7IGNvbG9yOiAjM2I4MmY2OyBmb250LXNpemU6IDEyLjVweDsKICBjdXJzb3I6IHBvaW50ZXI7IHBhZGRpbmc6IDJweCAw
;OyB3aGl0ZS1zcGFjZTogbm93cmFwOyBhbGlnbi1zZWxmOiBzdGFydDsKfQouaW5mby1saW5rOmhvdmVyIHsgdGV4dC1kZWNvcmF0aW9uOiB1bmRlcmxpbmU7
;IH0KI2Jhci1pbmZvLWFjdGlvbnMgewogIGRpc3BsYXk6IG5vbmU7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGdhcDogMTZweDsgbWFyZ2luLXJpZ2h0OiA4cHg7
;Cn0KI2Jhci5tb2RlLWluZm8gI2Jhci1pbmZvLWFjdGlvbnMgeyBkaXNwbGF5OiBpbmxpbmUtZmxleDsgfQojYmFyLWluZm8tYWN0aW9ucyBidXR0b24gewog
;IGJvcmRlcjogMDsgYmFja2dyb3VuZDogdHJhbnNwYXJlbnQ7IGNvbG9yOiAjM2I4MmY2OyBmb250LXNpemU6IDEyLjVweDsgY3Vyc29yOiBwb2ludGVyOyBw
;YWRkaW5nOiAwOwp9CiNiYXItaW5mby1hY3Rpb25zIGJ1dHRvbjpob3ZlciB7IHRleHQtZGVjb3JhdGlvbjogdW5kZXJsaW5lOyB9CiNiYXIubW9kZS1pbmZv
;ICNjb3VudCB7IGNvbG9yOiB2YXIoLS10eHQyKTsgfQojYmFyLm1vZGUtY29uZmlnICNjb3VudCB7IGRpc3BsYXk6IG5vbmU7IH0KI2Jhci1jb25maWctYWN0
;aW9ucyB7CiAgZGlzcGxheTogbm9uZTsgYWxpZ24taXRlbXM6IGNlbnRlcjsgZ2FwOiA4cHg7IG1pbi13aWR0aDogMDsgbWF4LXdpZHRoOiBtaW4oNzJ2dywg
;NzYwcHgpOwp9CiNiYXIubW9kZS1jb25maWcgI2Jhci1jb25maWctYWN0aW9ucyB7IGRpc3BsYXk6IGlubGluZS1mbGV4OyB9CiNjZmctcGF0aC1sYWJlbCB7
;CiAgbWluLXdpZHRoOiAwOyBvdmVyZmxvdzogaGlkZGVuOyB0ZXh0LW92ZXJmbG93OiBlbGxpcHNpczsgd2hpdGUtc3BhY2U6IG5vd3JhcDsKICBmb250LWZh
;bWlseTogQ29uc29sYXMsICJDYXNjYWRpYSBNb25vIiwgbW9ub3NwYWNlOyBmb250LXNpemU6IDEycHg7IGNvbG9yOiB2YXIoLS10eHQyKTsKICB1c2VyLXNl
;bGVjdDogdGV4dDsKfQojY2ZnLXBhdGgtbGFiZWwgLmNmZy1zZXAgeyBjb2xvcjogI2NiZDVlMTsgbWFyZ2luOiAwIDFweDsgfQojY2ZnLXBhdGgtbGFiZWwg
;LmNmZy1zZWcgeyBjb2xvcjogaW5oZXJpdDsgY3Vyc29yOiBkZWZhdWx0OyB9CiNjZmctcGF0aC1sYWJlbC5jdHJsLWhlbGQgLmNmZy1zZWcgeyBjdXJzb3I6
;IHBvaW50ZXI7IH0KI2NmZy1wYXRoLWxhYmVsLmN0cmwtaGVsZCAuY2ZnLXNlZzpob3ZlciB7CiAgY29sb3I6ICMyNTYzZWI7IHRleHQtZGVjb3JhdGlvbjog
;dW5kZXJsaW5lOwp9CiNjZmctcmVsb2FkIHsKICB3aWR0aDogMjhweDsgaGVpZ2h0OiAyOHB4OyBmbGV4LXNocmluazogMDsgYm9yZGVyOiAwOyBib3JkZXIt
;cmFkaXVzOiA2cHg7CiAgYmFja2dyb3VuZDogdHJhbnNwYXJlbnQ7IGNvbG9yOiB2YXIoLS10eHQyKTsgY3Vyc29yOiBwb2ludGVyOwogIGRpc3BsYXk6IGlu
;bGluZS1mbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBqdXN0aWZ5LWNvbnRlbnQ6IGNlbnRlcjsgcGFkZGluZzogMDsKfQojY2ZnLXJlbG9hZDpob3ZlciB7
;IGJhY2tncm91bmQ6ICNlZWYxZjY7IGNvbG9yOiB2YXIoLS10eHQpOyB9CiNjZmctcmVsb2FkIHN2ZyB7IHdpZHRoOiAxNnB4OyBoZWlnaHQ6IDE2cHg7IGRp
;c3BsYXk6IGJsb2NrOyB9CiNiYXIubW9kZS1jb25maWcgLnNvcnQsICNiYXIubW9kZS1jb25maWcgLnRvZ2dsZSB7IGRpc3BsYXk6IG5vbmU7IH0KI2Jhci5t
;b2RlLWluZm8gLnNvcnQsICNiYXIubW9kZS1pbmZvIC50b2dnbGUgeyBkaXNwbGF5OiBub25lOyB9CgovKiDilIDilIAg6L+Q6KGM6YWN572u57yW6L6R5Zmo
;77yI5YiG57uE5Y2h54mH77yJIOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgCAqLwojY29uZmlnLXBhbmVsIHsKICBmbGV4OiAxIDEgMDsgbWlu
;LWhlaWdodDogMDsgbWFyZ2luOiAwOyBib3JkZXI6IDA7CiAgYmFja2dyb3VuZDogI2Y0ZjZmOTsgZGlzcGxheTogZmxleDsgZmxleC1kaXJlY3Rpb246IGNv
;bHVtbjsgb3ZlcmZsb3c6IGhpZGRlbjsKfQojY29uZmlnLXBhbmVsLmhpZGRlbiB7IGRpc3BsYXk6IG5vbmU7IH0KLmNmZy10b3AgewogIGZsZXgtc2hyaW5r
;OiAwOyBkaXNwbGF5OiBmbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBqdXN0aWZ5LWNvbnRlbnQ6IHNwYWNlLWJldHdlZW47CiAgZ2FwOiAxMHB4OyBmbGV4
;LXdyYXA6IHdyYXA7CiAgcGFkZGluZzogMTBweCAxNHB4OyBib3JkZXItYm90dG9tOiAxcHggc29saWQgdmFyKC0tbGluZSk7IGJhY2tncm91bmQ6ICNmZmY7
;Cn0KLmNmZy10YWJzIHsgZGlzcGxheTogZmxleDsgZ2FwOiA4cHg7IGZsZXgtd3JhcDogd3JhcDsgZmxleC1zaHJpbms6IDA7IH0KLmNmZy10YWIgewogIGhl
;aWdodDogMzBweDsgcGFkZGluZzogMCAxNHB4OyBib3JkZXI6IDA7IGJvcmRlci1yYWRpdXM6IDk5OXB4OwogIGJhY2tncm91bmQ6ICNlZWYxZjY7IGNvbG9y
;OiB2YXIoLS10eHQyKTsgY3Vyc29yOiBwb2ludGVyOyBmb250LXNpemU6IDEzcHg7Cn0KLmNmZy10YWI6aG92ZXIgeyBiYWNrZ3JvdW5kOiAjZTJlOGYwOyBj
;b2xvcjogdmFyKC0tdHh0KTsgfQouY2ZnLXRhYi5vbiB7IGJhY2tncm91bmQ6ICMxNmEzNGE7IGNvbG9yOiAjZmZmOyBmb250LXdlaWdodDogNjAwOyB9Ci5j
;ZmctdG9vbHMgeyBkaXNwbGF5OiBmbGV4OyBnYXA6IDhweDsgYWxpZ24taXRlbXM6IGNlbnRlcjsgZmxleC13cmFwOiB3cmFwOyBmbGV4LXNocmluazogMDsg
;bWFyZ2luLWxlZnQ6IGF1dG87IH0KLmNmZy10b29scyBidXR0b24gewogIGhlaWdodDogMzBweDsgcGFkZGluZzogMCAxMnB4OyBib3JkZXI6IDFweCBzb2xp
;ZCB2YXIoLS1saW5lKTsgYm9yZGVyLXJhZGl1czogNnB4OwogIGJhY2tncm91bmQ6ICNmZmY7IGNvbG9yOiB2YXIoLS10eHQpOyBjdXJzb3I6IHBvaW50ZXI7
;IGZvbnQtc2l6ZTogMTIuNXB4OwogIGRpc3BsYXk6IGlubGluZS1mbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBnYXA6IDVweDsKfQouY2ZnLXRvb2xzIGJ1
;dHRvbjpob3ZlciB7IGJhY2tncm91bmQ6ICNmM2Y0ZjY7IH0KLmNmZy10b29scyBidXR0b24ucHJpbWFyeSB7CiAgYmFja2dyb3VuZDogIzE2YTM0YTsgYm9y
;ZGVyLWNvbG9yOiAjMTZhMzRhOyBjb2xvcjogI2ZmZjsKfQouY2ZnLXRvb2xzIGJ1dHRvbi5wcmltYXJ5OmhvdmVyIHsgYmFja2dyb3VuZDogIzE1ODAzZDsg
;Ym9yZGVyLWNvbG9yOiAjMTU4MDNkOyB9CiNjZmctc2F2ZSB7CiAgZGlzcGxheTogbm9uZTsgaGVpZ2h0OiAzMHB4OyBwYWRkaW5nOiAwIDE0cHg7IGJvcmRl
;ci1yYWRpdXM6IDhweDsKICBib3JkZXI6IDFweCBzb2xpZCAjMTZhMzRhOyBiYWNrZ3JvdW5kOiAjMTZhMzRhOyBjb2xvcjogI2ZmZjsKICBmb250LXNpemU6
;IDEyLjVweDsgZm9udC13ZWlnaHQ6IDYwMDsgY3Vyc29yOiBwb2ludGVyOwp9CiNjZmctc2F2ZS5vbiB7IGRpc3BsYXk6IGlubGluZS1mbGV4OyBhbGlnbi1p
;dGVtczogY2VudGVyOyB9CiNjZmctc2F2ZTpob3ZlciB7IGJhY2tncm91bmQ6ICMxNTgwM2Q7IGJvcmRlci1jb2xvcjogIzE1ODAzZDsgfQojY2ZnLXNhdmU6
;ZGlzYWJsZWQgewogIG9wYWNpdHk6IC40NTsgY3Vyc29yOiBkZWZhdWx0OyBiYWNrZ3JvdW5kOiAjODZlZmFjOyBib3JkZXItY29sb3I6ICM4NmVmYWM7Cn0K
;LmNmZy10b29scyBidXR0b24uY2ZnLWljby1idG4gewogIHdpZHRoOiAzMHB4OyBwYWRkaW5nOiAwOyBqdXN0aWZ5LWNvbnRlbnQ6IGNlbnRlcjsgcG9zaXRp
;b246IHJlbGF0aXZlOwp9Ci5jZmctdG9vbHMgYnV0dG9uLmNmZy1pY28tYnRuIHN2ZyB7CiAgd2lkdGg6IDE1cHg7IGhlaWdodDogMTVweDsgZGlzcGxheTog
;YmxvY2s7IGZsZXgtc2hyaW5rOiAwOwogIHRyYW5zaXRpb246IHRyYW5zZm9ybSAuMThzIGVhc2U7Cn0KLmNmZy10b29scyBidXR0b24uY2ZnLWljby1idG4g
;Lmljby1jb2xsYXBzZSB7IGRpc3BsYXk6IG5vbmU7IH0KLmNmZy10b29scyBidXR0b24uY2ZnLWljby1idG4uaXMtZXhwYW5kZWQgLmljby1leHBhbmQgeyBk
;aXNwbGF5OiBub25lOyB9Ci5jZmctdG9vbHMgYnV0dG9uLmNmZy1pY28tYnRuLmlzLWV4cGFuZGVkIC5pY28tY29sbGFwc2UgeyBkaXNwbGF5OiBibG9jazsg
;fQojdWktZGxnIHsKICBkaXNwbGF5OiBub25lOyBwb3NpdGlvbjogZml4ZWQ7IGluc2V0OiAwOyB6LWluZGV4OiA0MDA7CiAgYWxpZ24taXRlbXM6IGNlbnRl
;cjsganVzdGlmeS1jb250ZW50OiBjZW50ZXI7Cn0KI3VpLWRsZy5vbiB7IGRpc3BsYXk6IGZsZXg7IH0KLnVpLWRsZy1tYXNrIHsKICBwb3NpdGlvbjogYWJz
;b2x1dGU7IGluc2V0OiAwOyBiYWNrZ3JvdW5kOiByZ2JhKDE1LCAyMywgNDIsIC4yOCk7CiAgYmFja2Ryb3AtZmlsdGVyOiBibHVyKDJweCk7Cn0KLnVpLWRs
;Zy1jYXJkIHsKICBwb3NpdGlvbjogcmVsYXRpdmU7IHotaW5kZXg6IDE7IHdpZHRoOiBtaW4oMzgwcHgsIGNhbGMoMTAwdncgLSAzMnB4KSk7CiAgYmFja2dy
;b3VuZDogI2ZmZjsgYm9yZGVyLXJhZGl1czogMTJweDsgYm9yZGVyOiAxcHggc29saWQgI2UyZThmMDsKICBib3gtc2hhZG93OiAwIDE4cHggNDhweCByZ2Jh
;KDE1LCAyMywgNDIsIC4xOCk7CiAgcGFkZGluZzogMThweCAxOHB4IDE0cHg7IGFuaW1hdGlvbjogdWlEbGdJbiAuMTZzIGVhc2Utb3V0Owp9CkBrZXlmcmFt
;ZXMgdWlEbGdJbiB7CiAgZnJvbSB7IG9wYWNpdHk6IDA7IHRyYW5zZm9ybTogdHJhbnNsYXRlWSg2cHgpIHNjYWxlKC45OCk7IH0KICB0byB7IG9wYWNpdHk6
;IDE7IHRyYW5zZm9ybTogbm9uZTsgfQp9Ci51aS1kbGctdGl0bGUgewogIGZvbnQtc2l6ZTogMTVweDsgZm9udC13ZWlnaHQ6IDY1MDsgY29sb3I6ICMxMTE4
;Mjc7IG1hcmdpbjogMCAwIDhweDsKfQoudWktZGxnLW1zZyB7CiAgZm9udC1zaXplOiAxM3B4OyBsaW5lLWhlaWdodDogMS41NTsgY29sb3I6ICM0YjU1NjM7
;IG1hcmdpbjogMCAwIDE0cHg7CiAgd2hpdGUtc3BhY2U6IHByZS13cmFwOyB3b3JkLWJyZWFrOiBicmVhay13b3JkOwp9Ci51aS1kbGctaW5wdXQgewogIGRp
;c3BsYXk6IG5vbmU7IHdpZHRoOiAxMDAlOyBib3gtc2l6aW5nOiBib3JkZXItYm94OyBoZWlnaHQ6IDM2cHg7CiAgbWFyZ2luOiAtNHB4IDAgMTRweDsgcGFk
;ZGluZzogMCAxMnB4OwogIGJvcmRlcjogMXB4IHNvbGlkICNjYmQ1ZTE7IGJvcmRlci1yYWRpdXM6IDhweDsgYmFja2dyb3VuZDogI2Y4ZmFmYzsKICBjb2xv
;cjogdmFyKC0tdHh0KTsgZm9udC1zaXplOiAxMy41cHg7IG91dGxpbmU6IG5vbmU7Cn0KLnVpLWRsZy1pbnB1dC5vbiB7IGRpc3BsYXk6IGJsb2NrOyB9Ci51
;aS1kbGctaW5wdXQ6Zm9jdXMgewogIGJvcmRlci1jb2xvcjogIzkzYzVmZDsgYmFja2dyb3VuZDogI2ZmZjsKICBib3gtc2hhZG93OiAwIDAgMCAzcHggcmdi
;YSg1OSwxMzAsMjQ2LC4xNCk7Cn0KLnVpLWRsZy1hY3Rpb25zIHsKICBkaXNwbGF5OiBmbGV4OyBqdXN0aWZ5LWNvbnRlbnQ6IGZsZXgtZW5kOyBnYXA6IDhw
;eDsKfQoudWktZGxnLWFjdGlvbnMgYnV0dG9uIHsKICBtaW4td2lkdGg6IDcycHg7IGhlaWdodDogMzJweDsgcGFkZGluZzogMCAxNHB4OwogIGJvcmRlcjog
;MXB4IHNvbGlkICNlMmU4ZjA7IGJvcmRlci1yYWRpdXM6IDhweDsKICBiYWNrZ3JvdW5kOiAjZmZmOyBjb2xvcjogIzM3NDE1MTsgZm9udC1zaXplOiAxM3B4
;OyBjdXJzb3I6IHBvaW50ZXI7Cn0KLnVpLWRsZy1hY3Rpb25zIGJ1dHRvbjpob3ZlciB7IGJhY2tncm91bmQ6ICNmM2Y0ZjY7IH0KLnVpLWRsZy1hY3Rpb25z
;IGJ1dHRvbi5wcmltYXJ5IHsKICBiYWNrZ3JvdW5kOiAjM2I4MmY2OyBib3JkZXItY29sb3I6ICMzYjgyZjY7IGNvbG9yOiAjZmZmOwp9Ci51aS1kbGctYWN0
;aW9ucyBidXR0b24ucHJpbWFyeTpob3ZlciB7IGJhY2tncm91bmQ6ICMyNTYzZWI7IH0KLnVpLWRsZy1hY3Rpb25zIGJ1dHRvbi5kYW5nZXIgewogIGJhY2tn
;cm91bmQ6ICNkYzI2MjY7IGJvcmRlci1jb2xvcjogI2RjMjYyNjsgY29sb3I6ICNmZmY7Cn0KLnVpLWRsZy1hY3Rpb25zIGJ1dHRvbi5kYW5nZXI6aG92ZXIg
;eyBiYWNrZ3JvdW5kOiAjYjkxYzFjOyB9CiNjZmctc3RhdHVzIHsKICBkaXNwbGF5OiBub25lOyBmbGV4LXNocmluazogMDsgcGFkZGluZzogOHB4IDE0cHg7
;IGZvbnQtc2l6ZTogMTIuNXB4OyBmb250LXdlaWdodDogNTUwOwp9CiNjZmctc3RhdHVzLmVyciB7IGRpc3BsYXk6IGJsb2NrOyBjb2xvcjogI2I5MWMxYzsg
;YmFja2dyb3VuZDogI2ZlZjJmMjsgfQojY2ZnLXN0YXR1cy5vayB7IGRpc3BsYXk6IGJsb2NrOyBjb2xvcjogIzE1ODAzZDsgYmFja2dyb3VuZDogI2YwZmRm
;NDsgfQojY2ZnLXN0YXR1cy5pbmZvIHsgZGlzcGxheTogYmxvY2s7IGNvbG9yOiAjMWQ0ZWQ4OyBiYWNrZ3JvdW5kOiAjZWZmNmZmOyB9CiNjZmctdGlwLXdy
;YXAgewogIGZsZXgtc2hyaW5rOiAwOyBkaXNwbGF5OiBmbGV4OyBhbGlnbi1pdGVtczogZmxleC1zdGFydDsgZ2FwOiA4cHg7CiAgcGFkZGluZzogMTJweCAx
;NnB4IDZweDsgYmFja2dyb3VuZDogI2Y0ZjZmOTsgYm9yZGVyLWJvdHRvbTogMDsKfQojY2ZnLXRpcC13cmFwLmhpZGRlbiB7IGRpc3BsYXk6IG5vbmU7IH0K
;LmNmZy10aXAtaWNvIHsKICBmbGV4LXNocmluazogMDsgd2lkdGg6IDE4cHg7IGhlaWdodDogMThweDsgbWFyZ2luLXRvcDogMnB4OyBjb2xvcjogIzk0YTNi
;ODsKfQouY2ZnLXRpcC1pY28gc3ZnIHsgd2lkdGg6IDE4cHg7IGhlaWdodDogMThweDsgZGlzcGxheTogYmxvY2s7IH0KLmNmZy10aXAtYm9keSB7IGZsZXg6
;IDE7IG1pbi13aWR0aDogMDsgfQojY2ZnLXRpcCB7CiAgbWFyZ2luOiAwOyBwYWRkaW5nOiAwIDAgMCAxMHB4OwogIGJvcmRlcjogMDsgYm9yZGVyLWxlZnQ6
;IDJweCBzb2xpZCAjY2JkNWUxOyBib3JkZXItcmFkaXVzOiAwOwogIGJhY2tncm91bmQ6IHRyYW5zcGFyZW50OwogIGNvbG9yOiAjNjQ3NDhiOyBmb250LXNp
;emU6IDEyLjVweDsgbGluZS1oZWlnaHQ6IDEuODU7CiAgbGV0dGVyLXNwYWNpbmc6IC4wNGVtOwogIGZvbnQtZmFtaWx5OiAiU2Vnb2UgVUkiLCAiUGluZ0Zh
;bmcgU0MiLCAiSGlyYWdpbm8gU2FucyBHQiIsICJNaWNyb3NvZnQgWWFIZWkgVUkiLCBzYW5zLXNlcmlmOwogIHdoaXRlLXNwYWNlOiBwcmUtd3JhcDsgd29y
;ZC1icmVhazogYnJlYWstd29yZDsKICB1c2VyLXNlbGVjdDogdGV4dDsgY3Vyc29yOiBkZWZhdWx0Owp9CiNjZmctdGlwOmhvdmVyIHsgY29sb3I6ICM0NzU1
;Njk7IH0KI2NmZy10aXAtZWRpdCB7CiAgZGlzcGxheTogbm9uZTsgd2lkdGg6IDEwMCU7IG1pbi1oZWlnaHQ6IDcycHg7IG1heC1oZWlnaHQ6IDE2MHB4OyBy
;ZXNpemU6IHZlcnRpY2FsOwogIGJveC1zaXppbmc6IGJvcmRlci1ib3g7IG1hcmdpbjogMDsgcGFkZGluZzogNnB4IDhweCA2cHggMTBweDsKICBib3JkZXI6
;IDFweCBzb2xpZCAjY2JkNWUxOyBib3JkZXItbGVmdDogMnB4IHNvbGlkICM5NGEzYjg7IGJvcmRlci1yYWRpdXM6IDAgNnB4IDZweCAwOwogIGJhY2tncm91
;bmQ6ICNmZmY7CiAgY29sb3I6ICM0NzU1Njk7IGZvbnQtc2l6ZTogMTIuNXB4OyBsaW5lLWhlaWdodDogMS44NTsgbGV0dGVyLXNwYWNpbmc6IC4wNGVtOwog
;IGZvbnQtZmFtaWx5OiAiU2Vnb2UgVUkiLCAiUGluZ0ZhbmcgU0MiLCAiSGlyYWdpbm8gU2FucyBHQiIsICJNaWNyb3NvZnQgWWFIZWkgVUkiLCBzYW5zLXNl
;cmlmOwogIG91dGxpbmU6IG5vbmU7Cn0KI2NmZy10aXAtZWRpdDpmb2N1cyB7CiAgYm9yZGVyLWNvbG9yOiAjOTNjNWZkOyBib3gtc2hhZG93OiAwIDAgMCAz
;cHggcmdiYSg1OSwxMzAsMjQ2LC4xMik7Cn0KI2NmZy10aXAtd3JhcC5lZGl0aW5nICNjZmctdGlwIHsgZGlzcGxheTogbm9uZTsgfQojY2ZnLXRpcC13cmFw
;LmVkaXRpbmcgI2NmZy10aXAtZWRpdCB7IGRpc3BsYXk6IGJsb2NrOyB9CiNjZmctdGlwLXdyYXAuZWRpdGluZyAuY2ZnLXRpcC1pY28geyBjb2xvcjogIzY0
;NzQ4YjsgfQojY2ZnLWJvZHkgewogIGZsZXg6IDEgMSAwOyBtaW4taGVpZ2h0OiAwOyBoZWlnaHQ6IDA7CiAgb3ZlcmZsb3cteDogaGlkZGVuOyBvdmVyZmxv
;dy15OiBzY3JvbGw7IG92ZXJzY3JvbGwtYmVoYXZpb3I6IGNvbnRhaW47CiAgcGFkZGluZzogOHB4IDE0cHggMjBweDsKICBkaXNwbGF5OiBmbGV4OyBmbGV4
;LWRpcmVjdGlvbjogY29sdW1uOyBnYXA6IDEwcHg7IGJhY2tncm91bmQ6ICNmNGY2Zjk7CiAgc2Nyb2xsYmFyLWd1dHRlcjogc3RhYmxlOwp9Ci5jZmctZW1w
;dHkgewogIHBhZGRpbmc6IDQwcHggMTZweDsgdGV4dC1hbGlnbjogY2VudGVyOyBjb2xvcjogdmFyKC0tdHh0Myk7IGZvbnQtc2l6ZTogMTNweDsKfQouY2Zn
;LWNhcmQgewogIGJhY2tncm91bmQ6ICNmZmY7IGJvcmRlcjogMXB4IHNvbGlkICNlMmU4ZjA7IGJvcmRlci1yYWRpdXM6IDhweDsKICBib3gtc2hhZG93OiBu
;b25lOyBvdmVyZmxvdzogaGlkZGVuOyBmbGV4LXNocmluazogMDsKfQouY2ZnLWNhcmQuZGltIHsgb3BhY2l0eTogLjU1OyB9Ci5jZmctY2FyZC5vbiB7IGJv
;cmRlci1jb2xvcjogI2JmZGJmZTsgfQouY2ZnLWNhcmQub3BlbiB7IGJvcmRlci1jb2xvcjogI2NiZDVlMTsgYm9yZGVyLWxlZnQtY29sb3I6ICNjYmQ1ZTE7
;IH0KLmNmZy1jYXJkOm5vdCgub3BlbikgeyBib3JkZXItbGVmdDogM3B4IHNvbGlkICMyMmM1NWU7IH0KLmNmZy1jYXJkOm5vdCgub3Blbikub24geyBib3Jk
;ZXItbGVmdC1jb2xvcjogIzE2YTM0YTsgfQouY2ZnLWNhcmQuaGl0ID4gLmNmZy1jYXJkLWhkIHsgYmFja2dyb3VuZDogI2ZmZmJlYjsgfQouY2ZnLWNhcmQt
;aGQgewogIGRpc3BsYXk6IGZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGdhcDogMTBweDsgcGFkZGluZzogOHB4IDEycHg7CiAgYmFja2dyb3VuZDogI2Y4
;ZmFmYzsgYm9yZGVyLWJvdHRvbTogMXB4IHNvbGlkIHRyYW5zcGFyZW50OwogIGN1cnNvcjogY29udGV4dC1tZW51OyB1c2VyLXNlbGVjdDogbm9uZTsKfQou
;Y2ZnLWNhcmQub3BlbiA+IC5jZmctY2FyZC1oZCB7IGJvcmRlci1ib3R0b20tY29sb3I6ICNlZWYyZjc7IH0KLmNmZy1jYXJkLWhkIC5jZmctZ3RpdGxlIHsK
;ICBmbGV4OiAxOyBtaW4td2lkdGg6IDA7IGhlaWdodDogMjhweDsgYm9yZGVyOiAwOyBib3JkZXItcmFkaXVzOiA2cHg7CiAgcGFkZGluZzogMCA4cHg7IGJh
;Y2tncm91bmQ6IHRyYW5zcGFyZW50OwogIGZvbnQtc2l6ZTogMTMuNXB4OyBmb250LXdlaWdodDogNzAwOyBjb2xvcjogIzMzNDE1NTsgb3V0bGluZTogbm9u
;ZTsKfQouY2ZnLWNhcmQtaGQgLmNmZy1ndGl0bGU6OnBsYWNlaG9sZGVyIHsgY29sb3I6ICM5NGEzYjg7IH0KLmNmZy1jYXJkLWhkIC5jZmctZ3RpdGxlOmZv
;Y3VzIHsgYmFja2dyb3VuZDogI2ZmZjsgYm94LXNoYWRvdzogMCAwIDAgMXB4ICNjYmQ1ZTEgaW5zZXQ7IH0KLmNmZy1jYXJkLWhkIC5jZmctZ2NvdW50IHsK
;ICBmbGV4LXNocmluazogMDsgZm9udC1zaXplOiAxMXB4OyBmb250LXdlaWdodDogNjAwOyBsaW5lLWhlaWdodDogMTsKICBjb2xvcjogIzY0NzQ4YjsgcGFk
;ZGluZzogNXB4IDEwcHg7IGJvcmRlci1yYWRpdXM6IDk5OXB4OwogIGJhY2tncm91bmQ6ICNlZWYyZjc7IGJvcmRlcjogMXB4IHNvbGlkICNlMmU4ZjA7IGN1
;cnNvcjogcG9pbnRlcjsKICBkaXNwbGF5OiBpbmxpbmUtZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsgZ2FwOiA0cHg7Cn0KLmNmZy1jYXJkLWhkIC5jZmct
;Z2NvdW50OmhvdmVyIHsgYmFja2dyb3VuZDogI2UyZThmMDsgY29sb3I6ICMzMzQxNTU7IH0KLmNmZy1jYXJkLWhkIC5jZmctZ2NvdW50IC5jZmctY2hldiB7
;IGZvbnQtc2l6ZTogMTBweDsgY29sb3I6ICM5NGEzYjg7IH0KLmNmZy1saXN0IHsgZGlzcGxheTogbm9uZTsgZmxleC1kaXJlY3Rpb246IGNvbHVtbjsgfQou
;Y2ZnLWNhcmQub3BlbiA+IC5jZmctbGlzdCB7IGRpc3BsYXk6IGZsZXg7IH0KLmNmZy1hZGQtZHJhZnQgewogIGRpc3BsYXk6IGZsZXg7IGZsZXgtZGlyZWN0
;aW9uOiBjb2x1bW47IGdhcDogOHB4OwogIHBhZGRpbmc6IDhweCAxMnB4IDEwcHg7CiAgYm9yZGVyLXRvcDogMXB4IHNvbGlkICNlMmU4ZjA7CiAgYmFja2dy
;b3VuZDogI2ZmZjsKfQouY2ZnLWFkZC1kcmFmdCAuY2ZnLWFkZC1maWVsZHMgewogIGRpc3BsYXk6IGdyaWQ7CiAgZ3JpZC10ZW1wbGF0ZS1jb2x1bW5zOiAx
;OHB4IG1pbm1heCg5MHB4LCAxNDBweCkgMjJweCBtaW5tYXgoMCwgMS4yZnIpIG1pbm1heCg1MHB4LCAwLjQyZnIpOwogIGdhcDogOHB4OyBhbGlnbi1pdGVt
;czogY2VudGVyOwp9Ci5jZmctYWRkLWRyYWZ0IC5jZmctZG90IHsgYmFja2dyb3VuZDogIzk0YTNiODsgfQouY2ZnLWFkZC1kcmFmdCBpbnB1dFt0eXBlPSJ0
;ZXh0Il0gewogIHdpZHRoOiAxMDAlOyBoZWlnaHQ6IDMwcHg7IGJvcmRlcjogMXB4IHNvbGlkICNlMmU4ZjA7IGJvcmRlci1yYWRpdXM6IDVweDsKICBwYWRk
;aW5nOiAwIDhweDsgZm9udC1zaXplOiAxM3B4OyBvdXRsaW5lOiBub25lOyBiYWNrZ3JvdW5kOiAjZmZmOyBib3gtc2l6aW5nOiBib3JkZXItYm94Owp9Ci5j
;ZmctYWRkLWRyYWZ0IGlucHV0W3R5cGU9InRleHQiXTpmb2N1cyB7CiAgYm9yZGVyLWNvbG9yOiAjOTNjNWZkOyBib3gtc2hhZG93OiAwIDAgMCAycHggcmdi
;YSg1OSwxMzAsMjQ2LC4xMik7Cn0KLmNmZy1hZGQtZHJhZnQgLmNmZy1rZXkgewogIGZvbnQtZmFtaWx5OiBDb25zb2xhcywgIkNhc2NhZGlhIE1vbm8iLCAi
;U2Vnb2UgVUkiLCBtb25vc3BhY2U7CiAgZm9udC13ZWlnaHQ6IDY1MDsgY29sb3I6ICNiNDUzMDk7Cn0KLmNmZy1hZGQtZHJhZnQgLmNmZy12YWwgeyBjb2xv
;cjogIzNiODJmNjsgfQouY2ZnLWFkZC1kcmFmdCAuY2ZnLWNtdCB7IGZvbnQtc2l6ZTogMTJweDsgY29sb3I6ICM2NDc0OGI7IH0KLmNmZy1hZGQtZHJhZnQg
;LmNmZy1hZGQtYWN0cyB7CiAgZGlzcGxheTogaW5saW5lLWZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGdhcDogOHB4OyBqdXN0aWZ5LWNvbnRlbnQ6IGZs
;ZXgtZW5kOwogIHBhZGRpbmctbGVmdDogMjZweDsKfQouY2ZnLWFkZC1kcmFmdCAuY2ZnLWFkZC1hY3RzIGJ1dHRvbiB7CiAgaGVpZ2h0OiAyOHB4OyBtaW4t
;d2lkdGg6IDY0cHg7IHBhZGRpbmc6IDAgMTRweDsgYm9yZGVyOiAwOyBib3JkZXItcmFkaXVzOiA2cHg7CiAgY3Vyc29yOiBwb2ludGVyOyBmb250LXNpemU6
;IDEyLjVweDsgZm9udC13ZWlnaHQ6IDYwMDsgd2hpdGUtc3BhY2U6IG5vd3JhcDsKfQouY2ZnLWFkZC1kcmFmdCAuY2ZnLWFkZC1vayB7IGJhY2tncm91bmQ6
;ICMxNmEzNGE7IGNvbG9yOiAjZmZmOyB9Ci5jZmctYWRkLWRyYWZ0IC5jZmctYWRkLW9rOmhvdmVyIHsgYmFja2dyb3VuZDogIzE1ODAzZDsgfQouY2ZnLWFk
;ZC1kcmFmdCAuY2ZnLWFkZC1jYW5jZWwgeyBiYWNrZ3JvdW5kOiAjZTJlOGYwOyBjb2xvcjogIzQ3NTU2OTsgfQouY2ZnLWFkZC1kcmFmdCAuY2ZnLWFkZC1j
;YW5jZWw6aG92ZXIgeyBiYWNrZ3JvdW5kOiAjY2JkNWUxOyB9Ci5jZmctaXRlbSB7CiAgZGlzcGxheTogZ3JpZDsKICBncmlkLXRlbXBsYXRlLWNvbHVtbnM6
;IDE4cHggbWlubWF4KDkwcHgsIDE0MHB4KSAyMnB4IG1pbm1heCgwLCAxLjJmcikgbWlubWF4KDUwcHgsIDAuNDJmcikgNTZweDsKICBnYXA6IDhweDsgYWxp
;Z24taXRlbXM6IGNlbnRlcjsKICBwYWRkaW5nOiA4cHggMTJweDsgYm9yZGVyLXRvcDogMXB4IHNvbGlkICNlZWYxZjY7CiAgY3Vyc29yOiBjb250ZXh0LW1l
;bnU7IGJhY2tncm91bmQ6ICNmZmY7Cn0KLmNmZy1pdGVtOm50aC1jaGlsZChldmVuKSB7IGJhY2tncm91bmQ6ICNmYWZiZmQ7IH0KLmNmZy1pdGVtOmhvdmVy
;IHsgYmFja2dyb3VuZDogI2YwZjdmZjsgfQouY2ZnLWl0ZW0ub24geyBiYWNrZ3JvdW5kOiAjZWZmNmZmOyBvdXRsaW5lOiAxcHggc29saWQgI2JmZGJmZTsg
;b3V0bGluZS1vZmZzZXQ6IC0xcHg7IH0KLmNmZy1pdGVtLm9mZiB7IG9wYWNpdHk6IC41NTsgfQouY2ZnLWl0ZW0ub2ZmIC5jZmcta2V5LCAuY2ZnLWl0ZW0u
;b2ZmIC5jZmctdmFsIHsgdGV4dC1kZWNvcmF0aW9uOiBsaW5lLXRocm91Z2g7IGNvbG9yOiAjOTRhM2I4ICFpbXBvcnRhbnQ7IH0KLmNmZy1pdGVtIGlucHV0
;W3R5cGU9InRleHQiXSB7CiAgd2lkdGg6IDEwMCU7IGhlaWdodDogMzBweDsgYm9yZGVyOiAxcHggc29saWQgdHJhbnNwYXJlbnQ7IGJvcmRlci1yYWRpdXM6
;IDVweDsKICBwYWRkaW5nOiAwIDhweDsgZm9udC1zaXplOiAxM3B4OyBvdXRsaW5lOiBub25lOyBiYWNrZ3JvdW5kOiB0cmFuc3BhcmVudDsgYm94LXNpemlu
;ZzogYm9yZGVyLWJveDsKfQouY2ZnLWl0ZW0gaW5wdXRbdHlwZT0idGV4dCJdOmhvdmVyIHsgYm9yZGVyLWNvbG9yOiAjZTJlOGYwOyBiYWNrZ3JvdW5kOiAj
;ZmZmOyB9Ci5jZmctaXRlbSBpbnB1dFt0eXBlPSJ0ZXh0Il06Zm9jdXMgewogIGJvcmRlci1jb2xvcjogIzkzYzVmZDsgYmFja2dyb3VuZDogI2ZmZjsgYm94
;LXNoYWRvdzogMCAwIDAgMnB4IHJnYmEoNTksMTMwLDI0NiwuMTIpOwp9Ci5jZmctaXRlbSAuY2ZnLWtleSB7CiAgZm9udC1mYW1pbHk6IENvbnNvbGFzLCAi
;Q2FzY2FkaWEgTW9ubyIsICJTZWdvZSBVSSIsIG1vbm9zcGFjZTsKICBmb250LXdlaWdodDogNjUwOyBjb2xvcjogI2I0NTMwOTsKfQouY2ZnLWl0ZW0gLmNm
;Zy12YWwgeyBjb2xvcjogIzNiODJmNjsgfQouY2ZnLWl0ZW0gLmNmZy1jbXQgewogIGhlaWdodDogMzBweCAhaW1wb3J0YW50OyBmb250LXNpemU6IDEycHgg
;IWltcG9ydGFudDsKICBjb2xvcjogIzY0NzQ4YjsgYm9yZGVyOiAwICFpbXBvcnRhbnQ7IGJveC1zaGFkb3c6IG5vbmUgIWltcG9ydGFudDsKICBiYWNrZ3Jv
;dW5kOiB0cmFuc3BhcmVudCAhaW1wb3J0YW50Owp9Ci5jZmctaXRlbSBpbnB1dC5jZmctY210OmhvdmVyLAouY2ZnLWl0ZW0gaW5wdXQuY2ZnLWNtdDpmb2N1
;cyB7CiAgYm9yZGVyOiAwICFpbXBvcnRhbnQ7IGJveC1zaGFkb3c6IG5vbmUgIWltcG9ydGFudDsgYmFja2dyb3VuZDogdHJhbnNwYXJlbnQgIWltcG9ydGFu
;dDsKfQouY2ZnLWhsLWZpZWxkLmNmZy1jbXQgLmNmZy1obC12aWV3IHsKICBtaW4taGVpZ2h0OiAzMHB4OyBmb250LXNpemU6IDEycHg7IGNvbG9yOiAjNjQ3
;NDhiOwogIGJveC1zaGFkb3c6IG5vbmUgIWltcG9ydGFudDsgYmFja2dyb3VuZDogdHJhbnNwYXJlbnQgIWltcG9ydGFudDsKfQouY2ZnLWhsLWZpZWxkLmNm
;Zy1jbXQgLmNmZy1obC12aWV3OmhvdmVyIHsKICBiYWNrZ3JvdW5kOiB0cmFuc3BhcmVudCAhaW1wb3J0YW50OyBib3gtc2hhZG93OiBub25lICFpbXBvcnRh
;bnQ7Cn0KLmNmZy1obC1maWVsZCB7CiAgcG9zaXRpb246IHJlbGF0aXZlOyBtaW4td2lkdGg6IDA7IHdpZHRoOiAxMDAlOwp9Ci5jZmctaGwtdmlldyB7CiAg
;bWluLWhlaWdodDogMzBweDsgZGlzcGxheTogZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsKICBwYWRkaW5nOiAwIDhweDsgYm9yZGVyLXJhZGl1czogNXB4
;OyBib3gtc2l6aW5nOiBib3JkZXItYm94OwogIGZvbnQtc2l6ZTogMTNweDsgbGluZS1oZWlnaHQ6IDEuMzU7IHdvcmQtYnJlYWs6IGJyZWFrLWFsbDsKICBj
;dXJzb3I6IHRleHQ7IHdoaXRlLXNwYWNlOiBwcmUtd3JhcDsKfQouY2ZnLWhsLXZpZXc6aG92ZXIgeyBiYWNrZ3JvdW5kOiAjZmZmOyBib3gtc2hhZG93OiAw
;IDAgMCAxcHggI2UyZThmMCBpbnNldDsgfQouY2ZnLWhsLWZpZWxkLmNmZy1rZXkgLmNmZy1obC12aWV3IHsKICBmb250LWZhbWlseTogQ29uc29sYXMsICJD
;YXNjYWRpYSBNb25vIiwgIlNlZ29lIFVJIiwgbW9ub3NwYWNlOwogIGZvbnQtd2VpZ2h0OiA2NTA7IGNvbG9yOiAjYjQ1MzA5Owp9Ci5jZmctaGwtZmllbGQu
;Y2ZnLXZhbCAuY2ZnLWhsLXZpZXcgeyBjb2xvcjogIzNiODJmNjsgfQouY2ZnLWNhcmQtaGQgLmNmZy1ndGl0bGUtaGwgewogIGZsZXg6IDE7IG1pbi13aWR0
;aDogMDsgbWluLWhlaWdodDogMjhweDsgZGlzcGxheTogZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsKICBwYWRkaW5nOiAwIDhweDsgYm9yZGVyLXJhZGl1
;czogNnB4OwogIGZvbnQtc2l6ZTogMTMuNXB4OyBmb250LXdlaWdodDogNzAwOyBjb2xvcjogIzMzNDE1NTsgY3Vyc29yOiB0ZXh0Owp9Ci5jZmctY2FyZC1o
;ZCAuY2ZnLWd0aXRsZS1obDpob3ZlciB7IGJhY2tncm91bmQ6ICNmZmY7IGJveC1zaGFkb3c6IDAgMCAwIDFweCAjY2JkNWUxIGluc2V0OyB9Ci5jZmctaGwt
;dmlldyBtYXJrLCAuY2ZnLWd0aXRsZS1obCBtYXJrIHsKICBiYWNrZ3JvdW5kOiB2YXIoLS1obCk7IGNvbG9yOiB2YXIoLS1obC10ZXh0KTsgcGFkZGluZzog
;MCAxcHg7IGJvcmRlci1yYWRpdXM6IDJweDsKICBmb250LXdlaWdodDogNzAwOwp9Ci5jZmctZW4gewogIGRpc3BsYXk6IGlubGluZS1mbGV4OyBhbGlnbi1p
;dGVtczogY2VudGVyOyBqdXN0aWZ5LWNvbnRlbnQ6IGNlbnRlcjsgZ2FwOiAzcHg7CiAgZm9udC1zaXplOiAxMXB4OyBjb2xvcjogdmFyKC0tdHh0Mik7IHVz
;ZXItc2VsZWN0OiBub25lOyB3aGl0ZS1zcGFjZTogbm93cmFwOwp9Ci5jZmctZW4gaW5wdXQgewogIHdpZHRoOiAxNHB4OyBoZWlnaHQ6IDE0cHg7IGN1cnNv
;cjogcG9pbnRlcjsgbWFyZ2luOiAwOwogIGFjY2VudC1jb2xvcjogIzE2YTM0YTsKfQouY2ZnLXZpY28geyB3aWR0aDogMThweDsgaGVpZ2h0OiAxOHB4OyBk
;aXNwbGF5OiBncmlkOyBwbGFjZS1pdGVtczogY2VudGVyOyBjb2xvcjogIzY0NzQ4YjsgfQouY2ZnLXZpY28gaW1nIHsgd2lkdGg6IDE2cHg7IGhlaWdodDog
;MTZweDsgb2JqZWN0LWZpdDogY29udGFpbjsgZGlzcGxheTogYmxvY2s7IH0KLmNmZy12aWNvIHN2ZyB7IHdpZHRoOiAxNXB4OyBoZWlnaHQ6IDE1cHg7IGRp
;c3BsYXk6IGJsb2NrOyB9Ci5jZmctZG90IHsgd2lkdGg6IDhweDsgaGVpZ2h0OiA4cHg7IGJvcmRlci1yYWRpdXM6IDUwJTsgYmFja2dyb3VuZDogI2NiZDVl
;MTsganVzdGlmeS1zZWxmOiBjZW50ZXI7IH0KLmNmZy1pdGVtLm9uIC5jZmctZG90IHsgYmFja2dyb3VuZDogIzNiODJmNjsgfQouY2ZnLWl0ZW0tZW1wdHkg
;eyBwYWRkaW5nOiAxNHB4IDE2cHg7IGNvbG9yOiB2YXIoLS10eHQzKTsgZm9udC1zaXplOiAxMnB4OyBib3JkZXItdG9wOiAxcHggc29saWQgI2VlZjFmNjsg
;fQojY2ZnLW1lbnUgewogIGRpc3BsYXk6IG5vbmU7IHBvc2l0aW9uOiBmaXhlZDsgei1pbmRleDogMjQwOyBtaW4td2lkdGg6IDE2OHB4OwogIHBhZGRpbmc6
;IDRweDsgYmFja2dyb3VuZDogI2ZmZjsgYm9yZGVyOiAxcHggc29saWQgdmFyKC0tbGluZSk7CiAgYm9yZGVyLXJhZGl1czogOHB4OyBib3gtc2hhZG93OiB2
;YXIoLS1zaGFkb3cpOwp9CiNjZmctbWVudS5vbiB7IGRpc3BsYXk6IGJsb2NrOyB9CiNjZmctbWVudSBidXR0b24gewogIGRpc3BsYXk6IGZsZXg7IGFsaWdu
;LWl0ZW1zOiBjZW50ZXI7IGdhcDogOHB4OyB3aWR0aDogMTAwJTsKICB0ZXh0LWFsaWduOiBsZWZ0OyBib3JkZXI6IDA7IGJhY2tncm91bmQ6IHRyYW5zcGFy
;ZW50OwogIHBhZGRpbmc6IDhweCAxMHB4OyBib3JkZXItcmFkaXVzOiA2cHg7IGN1cnNvcjogcG9pbnRlcjsgY29sb3I6IHZhcigtLXR4dCk7IGZvbnQtc2l6
;ZTogMTNweDsKfQojY2ZnLW1lbnUgYnV0dG9uOmhvdmVyIHsgYmFja2dyb3VuZDogI2YzZjRmNjsgfQojY2ZnLW1lbnUgYnV0dG9uLmRhbmdlciB7IGNvbG9y
;OiAjZGMyNjI2OyB9CiNjZmctbWVudSBidXR0b24uZGFuZ2VyOmhvdmVyIHsgYmFja2dyb3VuZDogI2ZlZjJmMjsgfQojY2ZnLW1lbnUgYnV0dG9uOmRpc2Fi
;bGVkIHsgb3BhY2l0eTogLjQ7IGN1cnNvcjogZGVmYXVsdDsgfQojY2ZnLW1lbnUgLmMtaWNvIHsKICB3aWR0aDogMTZweDsgaGVpZ2h0OiAxNnB4OyBmbGV4
;LXNocmluazogMDsgY29sb3I6ICM2NDc0OGI7CiAgZGlzcGxheTogaW5saW5lLWZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGp1c3RpZnktY29udGVudDog
;Y2VudGVyOwp9CiNjZmctbWVudSBidXR0b24uZGFuZ2VyIC5jLWljbyB7IGNvbG9yOiAjZGMyNjI2OyB9CiNjZmctbWVudSAuYy1pY28gc3ZnIHsgd2lkdGg6
;IDE2cHg7IGhlaWdodDogMTZweDsgZGlzcGxheTogYmxvY2s7IH0KI2NmZy1tZW51IC5jYWN0LWxhYmVsIHsgZmxleDogMTsgbWluLXdpZHRoOiAwOyB9CiNj
;ZmctbWVudSBociB7IGJvcmRlcjogMDsgYm9yZGVyLXRvcDogMXB4IHNvbGlkICNlZWYxZjY7IG1hcmdpbjogNHB4IDZweDsgfQoucHJvYy1zZWFyY2guaGlk
;ZGVuIHsgZGlzcGxheTogbm9uZSAhaW1wb3J0YW50OyB9CiNwcm9jLW1lbnUgewogIGRpc3BsYXk6IG5vbmU7IHBvc2l0aW9uOiBmaXhlZDsgei1pbmRleDog
;MjIwOyBtaW4td2lkdGg6IDE4OHB4OwogIHBhZGRpbmc6IDRweDsgYmFja2dyb3VuZDogI2ZmZjsgYm9yZGVyOiAxcHggc29saWQgdmFyKC0tbGluZSk7CiAg
;Ym9yZGVyLXJhZGl1czogOHB4OyBib3gtc2hhZG93OiB2YXIoLS1zaGFkb3cpOwp9CiNwcm9jLW1lbnUub24geyBkaXNwbGF5OiBibG9jazsgfQojcHJvYy1t
;ZW51IGJ1dHRvbiB7CiAgZGlzcGxheTogZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsgZ2FwOiAxMHB4OyB3aWR0aDogMTAwJTsKICB0ZXh0LWFsaWduOiBs
;ZWZ0OyBib3JkZXI6IDA7IGJhY2tncm91bmQ6IHRyYW5zcGFyZW50OwogIHBhZGRpbmc6IDhweCAxMHB4OyBib3JkZXItcmFkaXVzOiA2cHg7IGN1cnNvcjog
;cG9pbnRlcjsgY29sb3I6IHZhcigtLXR4dCk7IGZvbnQtc2l6ZTogMTNweDsKfQojcHJvYy1tZW51IGJ1dHRvbjpob3ZlciB7IGJhY2tncm91bmQ6ICNmM2Y0
;ZjY7IH0KI3Byb2MtbWVudSBidXR0b24uZGFuZ2VyIHsgY29sb3I6ICNkYzI2MjY7IH0KI3Byb2MtbWVudSBidXR0b24uZGFuZ2VyOmhvdmVyIHsgYmFja2dy
;b3VuZDogI2ZlZjJmMjsgfQojcHJvYy1tZW51IGJ1dHRvbjpkaXNhYmxlZCB7IG9wYWNpdHk6IC40NTsgY3Vyc29yOiBkZWZhdWx0OyB9CiNwcm9jLW1lbnUg
;LmMtaWNvIHsKICB3aWR0aDogMTZweDsgaGVpZ2h0OiAxNnB4OyBmbGV4LXNocmluazogMDsKICBkaXNwbGF5OiBpbmxpbmUtZmxleDsgYWxpZ24taXRlbXM6
;IGNlbnRlcjsganVzdGlmeS1jb250ZW50OiBjZW50ZXI7CiAgY29sb3I6ICMzNzQxNTE7Cn0KI3Byb2MtbWVudSBidXR0b24uZGFuZ2VyIC5jLWljbyB7IGNv
;bG9yOiAjZGMyNjI2OyB9CiNwcm9jLW1lbnUgLmMtaWNvIHN2ZyB7IHdpZHRoOiAxNnB4OyBoZWlnaHQ6IDE2cHg7IGRpc3BsYXk6IGJsb2NrOyB9CiNwcm9j
;LW1lbnUgLnBhY3QtbGFiZWwgewogIGZsZXg6IDE7IG1pbi13aWR0aDogMDsgb3ZlcmZsb3c6IGhpZGRlbjsgdGV4dC1vdmVyZmxvdzogZWxsaXBzaXM7IHdo
;aXRlLXNwYWNlOiBub3dyYXA7Cn0KCiNtYWluIHsgZmxleDogMTsgZGlzcGxheTogZ3JpZDsgZ3JpZC10ZW1wbGF0ZS1jb2x1bW5zOiB2YXIoLS1zaWRlLXcp
;IG1pbm1heCgwLCAxZnIpOyBtaW4taGVpZ2h0OiAwOyBiYWNrZ3JvdW5kOiB2YXIoLS1jaHJvbWUpOyBwYWRkaW5nOiAwIDEwcHggMCAwOyBib3gtc2l6aW5n
;OiBib3JkZXItYm94OyB9CiNjb250ZW50LXBhbmUgewogIGRpc3BsYXk6IGdyaWQ7CiAgZ3JpZC10ZW1wbGF0ZS1jb2x1bW5zOiBtaW5tYXgoMjgwcHgsIDEu
;MWZyKSBtaW5tYXgoMzIwcHgsIDEuMmZyKTsKICBtaW4td2lkdGg6IDA7IG1pbi1oZWlnaHQ6IDA7CiAgYmFja2dyb3VuZDogI2ZmZjsKICBib3JkZXI6IDFw
;eCBzb2xpZCAjZDhkZGU2OwogIGJvcmRlci1yYWRpdXM6IDRweDsKICBvdmVyZmxvdzogaGlkZGVuOwp9CiNtYWluLm1vZGUtdG9vbCAjY29udGVudC1wYW5l
;IHsKICBncmlkLXRlbXBsYXRlLWNvbHVtbnM6IDFmcjsKfQojbWFpbi5tb2RlLWhhbmRsZSAjcHJldmlldyB7IGRpc3BsYXk6IG5vbmU7IH0KCi8qIHNpZGUg
;Ki8KI3NpZGUgewogIGJhY2tncm91bmQ6IHZhcigtLWNocm9tZSk7IGJvcmRlci1yaWdodDogMDsKICBkaXNwbGF5OiBmbGV4OyBmbGV4LWRpcmVjdGlvbjog
;Y29sdW1uOyBwYWRkaW5nOiAxMHB4IDhweDsgZ2FwOiAycHg7Cn0KLmNhdCB7CiAgZGlzcGxheTogZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsgZ2FwOiAx
;MHB4OyBoZWlnaHQ6IDQycHg7IHBhZGRpbmc6IDAgMTBweDsKICBib3JkZXI6IDA7IGJvcmRlci1yYWRpdXM6IDhweDsgYmFja2dyb3VuZDogdHJhbnNwYXJl
;bnQ7IGNvbG9yOiB2YXIoLS10eHQpOyBjdXJzb3I6IHBvaW50ZXI7CiAgdGV4dC1hbGlnbjogbGVmdDsgcG9zaXRpb246IHJlbGF0aXZlOwp9Ci5jYXQ6aG92
;ZXIgeyBiYWNrZ3JvdW5kOiAjZWVmMWY2OyB9Ci5jYXQub24geyBiYWNrZ3JvdW5kOiAjZThlYmYyOyBmb250LXdlaWdodDogNjAwOyB9Ci5jYXQub246OmJl
;Zm9yZSB7CiAgY29udGVudDogIiI7IHBvc2l0aW9uOiBhYnNvbHV0ZTsgbGVmdDogMDsgdG9wOiA4cHg7IGJvdHRvbTogOHB4OyB3aWR0aDogM3B4OwogIGJv
;cmRlci1yYWRpdXM6IDJweDsgYmFja2dyb3VuZDogdmFyKC0tYWNjKTsKfQouY2F0IC5pY28gewogIHdpZHRoOiAzMnB4OyBoZWlnaHQ6IDMycHg7IGZsZXgt
;c2hyaW5rOiAwOwogIGRpc3BsYXk6IGlubGluZS1mbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBqdXN0aWZ5LWNvbnRlbnQ6IGNlbnRlcjsKICBjb2xvcjog
;dmFyKC0tdHh0Mik7IGZvbnQtc2l6ZTogMTRweDsgbGluZS1oZWlnaHQ6IDE7Cn0KLmNhdCBpbWcuaWNvIHsKICB3aWR0aDogMzJweDsgaGVpZ2h0OiAzMnB4
;OwogIG9iamVjdC1maXQ6IGNvbnRhaW47IGltYWdlLXJlbmRlcmluZzogYXV0bzsKfQoKLnNpZGUtc2VwIHsKICBoZWlnaHQ6IDFweDsgbWFyZ2luOiA4cHgg
;MTBweDsgYmFja2dyb3VuZDogdmFyKC0tbGluZSk7IGZsZXgtc2hyaW5rOiAwOwp9CiNsaXN0LXBhbmUgeyBwb3NpdGlvbjogcmVsYXRpdmU7IH0KI2ZpbGUt
;cmVzdWx0cyB7IGRpc3BsYXk6IGZsZXg7IGZsZXgtZGlyZWN0aW9uOiBjb2x1bW47IGZsZXg6IDE7IG1pbi1oZWlnaHQ6IDA7IH0KI2ZpbGUtcmVzdWx0cy5o
;aWRkZW4geyBkaXNwbGF5OiBub25lICFpbXBvcnRhbnQ7IH0KI2hhbmRsZS1wYW5lbC5lbWJlZGRlZCB7CiAgZmxleDogMTsgbWluLWhlaWdodDogMDsgbWFy
;Z2luOiAwOyBib3JkZXI6IDA7IGJvcmRlci1yYWRpdXM6IDA7CiAgZGlzcGxheTogZmxleDsgZmxleC1kaXJlY3Rpb246IGNvbHVtbjsgb3ZlcmZsb3c6IGhp
;ZGRlbjsgYmFja2dyb3VuZDogI2ZmZjsKfQojaGFuZGxlLXBhbmVsLmVtYmVkZGVkLmhpZGRlbiB7IGRpc3BsYXk6IG5vbmUgIWltcG9ydGFudDsgfQojaW5m
;by1wYW5lbC5lbWJlZGRlZCB7CiAgZmxleDogMTsgbWluLWhlaWdodDogMDsgb3ZlcmZsb3c6IGF1dG87IHBhZGRpbmc6IDhweCAxNnB4IDEycHg7IGJhY2tn
;cm91bmQ6ICNmZmY7CiAgYm9yZGVyOiAwOyBtYXJnaW46IDA7Cn0KI2luZm8tcGFuZWwuZW1iZWRkZWQuaGlkZGVuIHsgZGlzcGxheTogbm9uZSAhaW1wb3J0
;YW50OyB9CiNjb25maWctcGFuZWwuZW1iZWRkZWQgewogIGZsZXg6IDEgMSAwOyBtaW4taGVpZ2h0OiAwOyBoZWlnaHQ6IDEwMCU7IG1hcmdpbjogMDsgYm9y
;ZGVyOiAwOyBib3JkZXItcmFkaXVzOiAwOwogIGRpc3BsYXk6IGZsZXg7IGZsZXgtZGlyZWN0aW9uOiBjb2x1bW47IG92ZXJmbG93OiBoaWRkZW47IGJhY2tn
;cm91bmQ6ICNmNGY2Zjk7Cn0KI2NvbmZpZy1wYW5lbC5lbWJlZGRlZC5oaWRkZW4geyBkaXNwbGF5OiBub25lICFpbXBvcnRhbnQ7IH0KI21haW4ubW9kZS10
;b29sICNwcmV2aWV3IHsgZGlzcGxheTogbm9uZTsgfQojbWFpbi5tb2RlLXRvb2wgewogIGdyaWQtdGVtcGxhdGUtY29sdW1uczogdmFyKC0tc2lkZS13KSBt
;aW5tYXgoMCwgMWZyKTsKfQojYmFyLm1vZGUtdG9vbCAuc29ydCwgI2Jhci5tb2RlLXRvb2wgLnRvZ2dsZSB7IGRpc3BsYXk6IG5vbmU7IH0KI2Jhci5tb2Rl
;LWluZm8gLnNvcnQsICNiYXIubW9kZS1pbmZvIC50b2dnbGUgeyBkaXNwbGF5OiBub25lOyB9CiN2aWV3LXByb2MgeyBkaXNwbGF5OiBub25lICFpbXBvcnRh
;bnQ7IH0KI2J0bi1nb3RvLXByb2MgeyBkaXNwbGF5OiBub25lICFpbXBvcnRhbnQ7IH0KI3NpZGUtZm9vdCB7IGRpc3BsYXk6IG5vbmU7IH0KI2J0bi1zZXR0
;aW5ncyB7CiAgd2lkdGg6IDM0cHg7IGhlaWdodDogMzRweDsgYm9yZGVyOiAwOyBib3JkZXItcmFkaXVzOiA4cHg7IGJhY2tncm91bmQ6IHRyYW5zcGFyZW50
;OwogIGNvbG9yOiB2YXIoLS10eHQyKTsgY3Vyc29yOiBwb2ludGVyOwp9CiNidG4tc2V0dGluZ3M6aG92ZXIgeyBiYWNrZ3JvdW5kOiAjZWVmMWY2OyBjb2xv
;cjogdmFyKC0tdHh0KTsgfQoKLyogbGlzdCAqLwojbGlzdC1wYW5lIHsKICBkaXNwbGF5OiBmbGV4OyBmbGV4LWRpcmVjdGlvbjogY29sdW1uOyBtaW4td2lk
;dGg6IDA7IG1pbi1oZWlnaHQ6IDA7IGhlaWdodDogMTAwJTsKICBiYWNrZ3JvdW5kOiAjZmZmOyBib3JkZXI6IDA7IG92ZXJmbG93OiBoaWRkZW47CiAgYm9y
;ZGVyLXJhZGl1czogMDsgYm94LXNoYWRvdzogbm9uZTsgb3V0bGluZTogbm9uZTsKfQojbGlzdCB7CiAgZmxleDogMTsgbWluLWhlaWdodDogMDsgb3ZlcmZs
;b3cteTogYXV0bzsgb3ZlcmZsb3cteDogaGlkZGVuOyBwYWRkaW5nOiA0cHggMDsKICAtd2Via2l0LW92ZXJmbG93LXNjcm9sbGluZzogdG91Y2g7Cn0KLnJv
;dyB7CiAgZGlzcGxheTogZ3JpZDsgZ3JpZC10ZW1wbGF0ZS1jb2x1bW5zOiA0MHB4IDFmcjsgZ2FwOiAxMHB4OwogIGFsaWduLWl0ZW1zOiBjZW50ZXI7IG1p
;bi1oZWlnaHQ6IDQ0cHg7CiAgcGFkZGluZzogNnB4IDE0cHg7IGN1cnNvcjogcG9pbnRlcjsgYm9yZGVyLWxlZnQ6IDNweCBzb2xpZCB0cmFuc3BhcmVudDsK
;fQoucm93OmhvdmVyIHsgYmFja2dyb3VuZDogI2Y3ZjhmYjsgfQoucm93Lm9uIHsgYmFja2dyb3VuZDogdmFyKC0tc2VsKTsgYm9yZGVyLWxlZnQtY29sb3I6
;IHZhcigtLWFjYyk7IH0KLnJvdyAuZmkgewogIHdpZHRoOiAzMnB4OyBoZWlnaHQ6IDMycHg7CiAgY29sb3I6IHZhcigtLXR4dDIpOyBkaXNwbGF5OiBncmlk
;OyBwbGFjZS1pdGVtczogY2VudGVyOyBmbGV4LXNocmluazogMDsKfQoucm93IC5maSBpbWcgewogIHdpZHRoOiAzMnB4OyBoZWlnaHQ6IDMycHg7CiAgb2Jq
;ZWN0LWZpdDogY29udGFpbjsgZGlzcGxheTogYmxvY2s7IGJhY2tncm91bmQ6IHRyYW5zcGFyZW50OwogIGltYWdlLXJlbmRlcmluZzogYXV0bzsKfQoucm93
;IC5maSAuZmktZmFsbGJhY2sgeyBmb250LXNpemU6IDE4cHg7IGxpbmUtaGVpZ2h0OiAxOyB9Ci5yb3cgLm5hbWUgeyBjb2xvcjogdmFyKC0tbmFtZSk7IGZv
;bnQtc2l6ZTogMTMuNXB4OyBmb250LXdlaWdodDogNjAwOyB3b3JkLWJyZWFrOiBicmVhay1hbGw7IGxpbmUtaGVpZ2h0OiAxLjM1OyB9Ci5yb3cgLm5hbWUg
;LmV4dCB7IGNvbG9yOiB2YXIoLS1uYW1lLWV4dCk7IH0KLnJvdyAubmFtZSBtYXJrLCAucm93IC5wYXRoIG1hcmsgewogIGJhY2tncm91bmQ6IHZhcigtLWhs
;KTsgY29sb3I6IHZhcigtLWhsLXRleHQpOyBwYWRkaW5nOiAwIDFweDsgYm9yZGVyLXJhZGl1czogMnB4OwogIGZvbnQtd2VpZ2h0OiA3MDA7Cn0KLnJvdyAu
;cGF0aCB7IGNvbG9yOiAjNGI1NTYzOyBmb250LXNpemU6IDEycHg7IG1hcmdpbi10b3A6IDJweDsgd29yZC1icmVhazogYnJlYWstYWxsOyB9CiNsaXN0LWVt
;cHR5IHsKICBkaXNwbGF5OiBub25lOyBmbGV4OiAxOyBhbGlnbi1pdGVtczogY2VudGVyOyBqdXN0aWZ5LWNvbnRlbnQ6IGNlbnRlcjsKICBjb2xvcjogdmFy
;KC0tdHh0Myk7IGZvbnQtc2l6ZTogMTRweDsKfQojbGlzdC1lbXB0eS5vbiB7IGRpc3BsYXk6IGZsZXg7IH0KCi8qIHByZXZpZXcgKi8KI3ByZXZpZXcgewog
;IGJhY2tncm91bmQ6ICNmZmY7IG1pbi13aWR0aDogMDsgbWluLWhlaWdodDogMDsgZGlzcGxheTogZmxleDsgZmxleC1kaXJlY3Rpb246IGNvbHVtbjsgb3Zl
;cmZsb3c6IGhpZGRlbjsKICBib3JkZXI6IDA7IGJvcmRlci1yYWRpdXM6IDA7IGJveC1zaGFkb3c6IG5vbmU7IG91dGxpbmU6IG5vbmU7Cn0KI3ByZXZpZXcu
;b2ZmIC5wdi1ib2R5IHsgZGlzcGxheTogbm9uZTsgfQojcHJldmlldy5vZmYgLnB2LW9mZiB7CiAgZGlzcGxheTogZmxleDsgZmxleDogMTsgYWxpZ24taXRl
;bXM6IGNlbnRlcjsganVzdGlmeS1jb250ZW50OiBjZW50ZXI7IGNvbG9yOiB2YXIoLS10eHQzKTsKfQoucHYtb2ZmIHsgZGlzcGxheTogbm9uZTsgfQoucHYt
;bWV0YSB7CiAgZGlzcGxheTogZmxleDsgZ2FwOiAxNHB4OyBhbGlnbi1pdGVtczogY2VudGVyOyBwYWRkaW5nOiAxMHB4IDE0cHg7CiAgYm9yZGVyLWJvdHRv
;bTogMXB4IHNvbGlkIHZhcigtLWxpbmUpOyBjb2xvcjogdmFyKC0tdHh0Mik7IGZvbnQtc2l6ZTogMTJweDsgZmxleC13cmFwOiB3cmFwOwp9Ci5wdi1tZXRh
;IGIgeyBjb2xvcjogdmFyKC0tdHh0KTsgZm9udC13ZWlnaHQ6IDYwMDsgfQoucHYtbWV0YSAuZHJ2IHsKICBkaXNwbGF5OiBpbmxpbmUtZmxleDsgYWxpZ24t
;aXRlbXM6IGNlbnRlcjsgZ2FwOiA2cHg7CiAgY29sb3I6IHZhcigtLXR4dCk7IGZvbnQtd2VpZ2h0OiA2MDA7Cn0KLnB2LW1ldGEgLmRydiBpbWcgewogIHdp
;ZHRoOiAxNnB4OyBoZWlnaHQ6IDE2cHg7IG9iamVjdC1maXQ6IGNvbnRhaW47IGJhY2tncm91bmQ6IHRyYW5zcGFyZW50OyBmbGV4LXNocmluazogMDsKfQou
;cHYtYm9keSB7IGZsZXg6IDE7IG1pbi1oZWlnaHQ6IDA7IGRpc3BsYXk6IGZsZXg7IGZsZXgtZGlyZWN0aW9uOiBjb2x1bW47IH0KLnB2LW1lZGlhIHsKICBm
;bGV4OiAxOyBtaW4taGVpZ2h0OiAwOyBiYWNrZ3JvdW5kOiAjM2Y0NDUwOyBkaXNwbGF5OiBmbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBqdXN0aWZ5LWNv
;bnRlbnQ6IGNlbnRlcjsKICBvdmVyZmxvdzogaGlkZGVuOyBwb3NpdGlvbjogcmVsYXRpdmU7Cn0KLnB2LW1lZGlhLmNvbXBhY3QgewogIGZsZXg6IDAgMCBh
;dXRvOyBtaW4taGVpZ2h0OiAwOyBoZWlnaHQ6IDA7IHBhZGRpbmc6IDA7IG92ZXJmbG93OiBoaWRkZW47CiAgYm9yZGVyOiAwOwp9Ci5wdi1ib2R5LnRleHQt
;bW9kZSAucHYtbWVkaWEgeyBkaXNwbGF5OiBub25lOyB9Ci5wdi1ib2R5LnRleHQtbW9kZSAucHYtdGV4dCB7CiAgZmxleDogMTsgZGlzcGxheTogZmxleDsg
;Ym9yZGVyLXRvcDogMDsgbWluLWhlaWdodDogMDsKfQoucHYtbWVkaWEgaW1nLCAucHYtbWVkaWEgdmlkZW8gewogIG1heC13aWR0aDogMTAwJTsgbWF4LWhl
;aWdodDogMTAwJTsgb2JqZWN0LWZpdDogY29udGFpbjsgYmFja2dyb3VuZDogIzExMTsKfQoucHYtbWVkaWEgLnB2LWZpbGVpbmZvIGltZy5iaWctaWNvIHsK
;ICBiYWNrZ3JvdW5kOiB0cmFuc3BhcmVudCAhaW1wb3J0YW50OwogIG1heC13aWR0aDogNDhweDsgbWF4LWhlaWdodDogNDhweDsKfQoucHYtbWVkaWEgZW1i
;ZWQucGRmLCAucHYtbWVkaWEgaWZyYW1lLnBkZiB7CiAgd2lkdGg6IDEwMCU7IGhlaWdodDogMTAwJTsgYm9yZGVyOiAwOyBiYWNrZ3JvdW5kOiAjNTI1NjU5
;Owp9Ci5wdi1tZWRpYSAucGggeyBjb2xvcjogI2NiZDVlMTsgZm9udC1zaXplOiAxM3B4OyB9Ci5wdi1maWxlaW5mbyB7CiAgZGlzcGxheTogZmxleDsgZmxl
;eC1kaXJlY3Rpb246IGNvbHVtbjsgYWxpZ24taXRlbXM6IHN0cmV0Y2g7IGp1c3RpZnktY29udGVudDogY2VudGVyOwogIGdhcDogMTBweDsgcGFkZGluZzog
;MjhweCAyNHB4OyB0ZXh0LWFsaWduOiBsZWZ0OyB3aWR0aDogMTAwJTsgaGVpZ2h0OiAxMDAlOwogIGJveC1zaXppbmc6IGJvcmRlci1ib3g7IG92ZXJmbG93
;OiBhdXRvOwogIGJhY2tncm91bmQ6ICNmN2Y4ZmI7IGNvbG9yOiB2YXIoLS10eHQpOwp9Ci5wdi1maWxlaW5mbyAuYmlnLWljbyB7CiAgd2lkdGg6IDQ4cHg7
;IGhlaWdodDogNDhweDsgb2JqZWN0LWZpdDogY29udGFpbjsgYWxpZ24tc2VsZjogY2VudGVyOwogIGJhY2tncm91bmQ6IHRyYW5zcGFyZW50ICFpbXBvcnRh
;bnQ7CiAgaW1hZ2UtcmVuZGVyaW5nOiBhdXRvOyBmbGV4LXNocmluazogMDsKfQoucHYtbWVkaWE6aGFzKC5wdi1maWxlaW5mbykgeyBiYWNrZ3JvdW5kOiAj
;ZjdmOGZiOyB9Ci5wdi1maWxlaW5mbyAuZm4gewogIGZvbnQtc2l6ZTogMTZweDsgZm9udC13ZWlnaHQ6IDY1MDsgY29sb3I6IHZhcigtLXR4dCk7CiAgd29y
;ZC1icmVhazogYnJlYWstYWxsOyB0ZXh0LWFsaWduOiBjZW50ZXI7IHdpZHRoOiAxMDAlOyBsaW5lLWhlaWdodDogMS4zNTsKfQoucHYtZmlsZWluZm8gLnRu
;IHsKICBmb250LXNpemU6IDEycHg7IGNvbG9yOiB2YXIoLS10eHQyKTsgdGV4dC1hbGlnbjogY2VudGVyOyB3aWR0aDogMTAwJTsKfQoucHYtZmlsZWluZm8g
;LmhpbnQgewogIGZvbnQtc2l6ZTogMTJweDsgY29sb3I6ICNiNDUzMDk7IHRleHQtYWxpZ246IGNlbnRlcjsgd2lkdGg6IDEwMCU7IGxpbmUtaGVpZ2h0OiAx
;LjQ1Owp9Ci5wdi1maWxlaW5mbyAua3YgewogIGRpc3BsYXk6IGZsZXg7IGZsZXgtZGlyZWN0aW9uOiBjb2x1bW47IGdhcDogOHB4OwogIG1hcmdpbi10b3A6
;IDZweDsgd2lkdGg6IDEwMCU7IGZvbnQtc2l6ZTogMTIuNXB4OyBjb2xvcjogdmFyKC0tdHh0Mik7Cn0KLnB2LWZpbGVpbmZvIC5rdi1yb3cgewogIGRpc3Bs
;YXk6IGdyaWQ7IGdyaWQtdGVtcGxhdGUtY29sdW1uczogNC41ZW0gMWZyOyBnYXA6IDEycHg7IGFsaWduLWl0ZW1zOiBzdGFydDsKICBsaW5lLWhlaWdodDog
;MS41NTsKfQoucHYtZmlsZWluZm8gLmt2LXJvdyAuayB7IGNvbG9yOiB2YXIoLS10eHQyKTsgd2hpdGUtc3BhY2U6IG5vd3JhcDsgfQoucHYtZmlsZWluZm8g
;Lmt2LXJvdyAudiB7IGNvbG9yOiB2YXIoLS10eHQpOyB3b3JkLWJyZWFrOiBicmVhay1hbGw7IGZvbnQtd2VpZ2h0OiA1MDA7IH0KLnB2LWZpbGVpbmZvIC5r
;aWRzIHsKICBtYXJnaW4tdG9wOiA4cHg7IGZvbnQtc2l6ZTogMTIuNXB4OyBjb2xvcjogdmFyKC0tdHh0Mik7IGxpbmUtaGVpZ2h0OiAxLjY7CiAgd29yZC1i
;cmVhazogYnJlYWstYWxsOwp9Ci5wdi1maWxlaW5mbyAua2lkcyBiIHsgY29sb3I6IHZhcigtLXR4dCk7IGZvbnQtd2VpZ2h0OiA2MDA7IH0KCi8qIGNvbnRl
;eHQgbWVudSAqLwojY3R4IHsKICBkaXNwbGF5OiBub25lOyBwb3NpdGlvbjogZml4ZWQ7IHotaW5kZXg6IDIwMDsgbWluLXdpZHRoOiAxNjhweDsKICBwYWRk
;aW5nOiA0cHg7IGJhY2tncm91bmQ6ICNmZmY7IGJvcmRlcjogMXB4IHNvbGlkIHZhcigtLWxpbmUpOwogIGJvcmRlci1yYWRpdXM6IDhweDsgYm94LXNoYWRv
;dzogMCA4cHggMjRweCByZ2JhKDE1LDIzLDQyLC4xMik7Cn0KI2N0eC5vbiB7IGRpc3BsYXk6IGJsb2NrOyB9CiNjdHggYnV0dG9uIHsKICBkaXNwbGF5OiBm
;bGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBnYXA6IDEwcHg7IHdpZHRoOiAxMDAlOwogIGJvcmRlcjogMDsgYmFja2dyb3VuZDogdHJhbnNwYXJlbnQ7IHBh
;ZGRpbmc6IDhweCAxMHB4OyBib3JkZXItcmFkaXVzOiA2cHg7CiAgY3Vyc29yOiBwb2ludGVyOyBjb2xvcjogdmFyKC0tdHh0KTsgZm9udC1zaXplOiAxM3B4
;OyB0ZXh0LWFsaWduOiBsZWZ0Owp9CiNjdHggYnV0dG9uOmhvdmVyIHsgYmFja2dyb3VuZDogI2YzZjRmNjsgfQojY3R4IGJ1dHRvbi5kYW5nZXIgeyBjb2xv
;cjogI2RjMjYyNjsgfQojY3R4IGJ1dHRvbi5kYW5nZXI6aG92ZXIgeyBiYWNrZ3JvdW5kOiAjZmVmMmYyOyB9CiNjdHggLmMtaWNvIHsKICB3aWR0aDogMTZw
;eDsgaGVpZ2h0OiAxNnB4OyBmbGV4LXNocmluazogMDsKICBkaXNwbGF5OiBpbmxpbmUtZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsganVzdGlmeS1jb250
;ZW50OiBjZW50ZXI7CiAgY29sb3I6ICMzNzQxNTE7Cn0KI2N0eCBidXR0b24uZGFuZ2VyIC5jLWljbyB7IGNvbG9yOiAjZGMyNjI2OyB9CiNjdHggLmMtaWNv
;IHN2ZyB7IHdpZHRoOiAxNnB4OyBoZWlnaHQ6IDE2cHg7IGRpc3BsYXk6IGJsb2NrOyB9CgoucHYtdGV4dCB7CiAgZmxleDogMTsgbWluLWhlaWdodDogMDsg
;ZGlzcGxheTogZmxleDsgZmxleC1kaXJlY3Rpb246IGNvbHVtbjsgYm9yZGVyLXRvcDogMXB4IHNvbGlkIHZhcigtLWxpbmUpOwp9Ci5wdi10ZXh0IC5oZCB7
;CiAgcGFkZGluZzogOHB4IDE0cHg7IGZvbnQtc2l6ZTogMTJweDsgY29sb3I6IHZhcigtLXR4dDIpOyBiYWNrZ3JvdW5kOiAjZmFmYmZjOyBib3JkZXItYm90
;dG9tOiAxcHggc29saWQgdmFyKC0tbGluZSk7Cn0KLnB2LXRleHQgcHJlIHsKICBtYXJnaW46IDA7IGZsZXg6IDE7IG92ZXJmbG93OiBhdXRvOyBwYWRkaW5n
;OiAxMnB4IDE0cHg7IGZvbnQtc2l6ZTogMTJweDsgbGluZS1oZWlnaHQ6IDEuNTsKICB3aGl0ZS1zcGFjZTogcHJlLXdyYXA7IHdvcmQtYnJlYWs6IGJyZWFr
;LXdvcmQ7IGZvbnQtZmFtaWx5OiBDb25zb2xhcywgIlNhcmFzYSBNb25vIFNDIiwgbW9ub3NwYWNlOwogIGJhY2tncm91bmQ6ICNmZmY7IGNvbG9yOiAjMTEx
;ODI3Owp9CgovKiBib3R0b23vvJrorr7nva7lnKjlt6bkuIvop5LvvIzmjpLluo8v6aKE6KeI57Sn5oyo6K6+572u5bm255WZ56m66ZqZICovCiNiYXIgewog
;IGhlaWdodDogNDJweDsgZGlzcGxheTogZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsgZ2FwOiAwOwogIHBhZGRpbmc6IDAgMTRweCAwIDEwcHg7IGJhY2tn
;cm91bmQ6IHZhcigtLWNocm9tZSk7IGJvcmRlci10b3A6IDA7IGZvbnQtc2l6ZTogMTIuNXB4OyBjb2xvcjogdmFyKC0tdHh0Mik7Cn0KI2JhciAuYmFyLWxl
;ZnQgewogIGZsZXgtc2hyaW5rOiAwOyBoZWlnaHQ6IDEwMCU7CiAgZGlzcGxheTogZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsKfQojYmFyIC5iYXItbWFp
;biB7CiAgZmxleDogMTsgbWluLXdpZHRoOiAwOyBoZWlnaHQ6IDEwMCU7CiAgZGlzcGxheTogZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsgZ2FwOiAxNnB4
;OwogIG1hcmdpbi1sZWZ0OiAxOHB4OyBib3gtc2l6aW5nOiBib3JkZXItYm94Owp9CiNiYXIgLnNvcnQgeyBkaXNwbGF5OiBpbmxpbmUtZmxleDsgYWxpZ24t
;aXRlbXM6IGNlbnRlcjsgZ2FwOiA2cHg7IGN1cnNvcjogcG9pbnRlcjsgYm9yZGVyOiAwOyBiYWNrZ3JvdW5kOiB0cmFuc3BhcmVudDsgY29sb3I6IGluaGVy
;aXQ7IH0KI2JhciAuc29ydDpob3ZlciB7IGNvbG9yOiB2YXIoLS10eHQpOyB9CiNiYXIgLnNwYWNlciB7IGZsZXg6IDE7IH0KLnRvZ2dsZSB7CiAgZGlzcGxh
;eTogaW5saW5lLWZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGdhcDogOHB4OyBjdXJzb3I6IHBvaW50ZXI7IHVzZXItc2VsZWN0OiBub25lOwp9Ci50b2dn
;bGUgaW5wdXQgeyBkaXNwbGF5OiBub25lOyB9Ci50b2dnbGUgLnN3IHsKICB3aWR0aDogMzZweDsgaGVpZ2h0OiAyMHB4OyBib3JkZXItcmFkaXVzOiA5OTlw
;eDsgYmFja2dyb3VuZDogI2QxZDVkYjsgcG9zaXRpb246IHJlbGF0aXZlOyB0cmFuc2l0aW9uOiAuMnM7Cn0KLnRvZ2dsZSAuc3c6OmFmdGVyIHsKICBjb250
;ZW50OiAiIjsgcG9zaXRpb246IGFic29sdXRlOyB0b3A6IDJweDsgbGVmdDogMnB4OyB3aWR0aDogMTZweDsgaGVpZ2h0OiAxNnB4OwogIGJvcmRlci1yYWRp
;dXM6IDUwJTsgYmFja2dyb3VuZDogI2ZmZjsgdHJhbnNpdGlvbjogLjJzOyBib3gtc2hhZG93OiAwIDFweCAycHggcmdiYSgwLDAsMCwuMik7Cn0KLnRvZ2ds
;ZSBpbnB1dDpjaGVja2VkICsgLnN3IHsgYmFja2dyb3VuZDogdmFyKC0tYWNjKTsgfQoudG9nZ2xlIGlucHV0OmNoZWNrZWQgKyAuc3c6OmFmdGVyIHsgbGVm
;dDogMThweDsgfQojY291bnQgeyBjb2xvcjogdmFyKC0tdHh0KTsgZm9udC12YXJpYW50LW51bWVyaWM6IHRhYnVsYXItbnVtczsgfQo8L3N0eWxlPgo8c2Ny
;aXB0PgooZnVuY3Rpb24gKCkgewogIHRyeSB7CiAgICB2YXIgcSA9IGxvY2F0aW9uLnNlYXJjaCB8fCAnJzsKICAgIHZhciBza2lwID0gLyg/Olw/fCYpc2tp
;cEJvb3Q9MSg/OiZ8JCkvLnRlc3QocSk7CiAgICBpZiAoIXNraXApIHsKICAgICAgdmFyIHMgPSBKU09OLnBhcnNlKGxvY2FsU3RvcmFnZS5nZXRJdGVtKCds
;b2NhbF9zZWFyY2hfc2Vzc2lvbl92MScpIHx8ICdudWxsJyk7CiAgICAgIHZhciBtID0gcyAmJiBzLmFwcE1vZGU7CiAgICAgIGlmIChtID09PSAnaGFuZGxl
;JyB8fCBtID09PSAnaW5mbycgfHwgbSA9PT0gJ2NvbmZpZycpIHNraXAgPSB0cnVlOwogICAgfQogICAgaWYgKHNraXApCiAgICAgIGRvY3VtZW50LmRvY3Vt
;ZW50RWxlbWVudC5zZXRBdHRyaWJ1dGUoJ2RhdGEtc2tpcC1ib290JywgJzEnKTsKICB9IGNhdGNoIChlKSB7fQp9KSgpOwo8L3NjcmlwdD4KPC9oZWFkPgo8
;Ym9keT4KPGRpdiBpZD0iYXBwIiBjbGFzcz0iYm9vdGluZyI+CiAgPGRpdiBpZD0idGl0bGViYXIiPgogICAgPGRpdiBjbGFzcz0idGItYnJhbmQgbm8tZHJh
;ZyIgdGl0bGU9IuS7quihqOebmCI+CiAgICAgIDxzdmcgY2xhc3M9InRiLWljbyIgdmlld0JveD0iMCAwIDE2IDE2IiBmaWxsPSJub25lIiBhcmlhLWhpZGRl
;bj0idHJ1ZSI+CiAgICAgICAgPGNpcmNsZSBjeD0iOCIgY3k9IjkiIHI9IjUuMiIgc3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0cm9rZS13aWR0aD0iMS40Ii8+
;CiAgICAgICAgPHBhdGggZD0iTTggOWwzLjItMy4yIiBzdHJva2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIxLjQiIHN0cm9rZS1saW5lY2FwPSJy
;b3VuZCIvPgogICAgICAgIDxjaXJjbGUgY3g9IjgiIGN5PSI5IiByPSIxLjE1IiBmaWxsPSJjdXJyZW50Q29sb3IiLz4KICAgICAgPC9zdmc+CiAgICAgIDxz
;cGFuIGNsYXNzPSJ0Yi1uYW1lIj7ku6rooajnm5g8L3NwYW4+CiAgICA8L2Rpdj4KICAgIDxkaXYgaWQ9ImZpbHRlci1yYWlsIiBjbGFzcz0ibm8tZHJhZyI+
;CiAgICAgIDxkaXYgaWQ9ImZpbHRlci1iYXIiIGFyaWEtbGFiZWw9IuaQnOe0ouetm+mAiSI+PC9kaXY+CiAgICAgIDxkaXYgaWQ9ImhhbmRsZS10YWctYmFy
;IiBhcmlhLWxhYmVsPSLlj6Xmn4TmkJzntKLmoIfnrb4iPjwvZGl2PgogICAgICA8ZGl2IGlkPSJjZmctc2VhcmNoLXRhZ3MiIHJvbGU9Imdyb3VwIiBhcmlh
;LWxhYmVsPSLmkJzntKLojIPlm7QiPgogICAgICAgIDxidXR0b24gdHlwZT0iYnV0dG9uIiBjbGFzcz0iY2ZnLXN0YWciIGRhdGEtY2ZnLXNjb3BlPSJrZXki
;IHRpdGxlPSLlj6rmkJwga2V5Ij7ku4Uga2V5PC9idXR0b24+CiAgICAgICAgPGJ1dHRvbiB0eXBlPSJidXR0b24iIGNsYXNzPSJjZmctc3RhZyIgZGF0YS1j
;Zmctc2NvcGU9InZhbHVlIiB0aXRsZT0i5Y+q5pCcIHZhbHVlIj7ku4UgdmFsdWU8L2J1dHRvbj4KICAgICAgICA8YnV0dG9uIHR5cGU9ImJ1dHRvbiIgY2xh
;c3M9ImNmZy1zdGFnIiBkYXRhLWNmZy1zY29wZT0iZW5hYmxlZCIgdGl0bGU9IuWPqueci+W3suWQr+eUqCI+5ZCv55SoPC9idXR0b24+CiAgICAgICAgPGJ1
;dHRvbiB0eXBlPSJidXR0b24iIGNsYXNzPSJjZmctc3RhZyIgZGF0YS1jZmctc2NvcGU9ImRpc2FibGVkIiB0aXRsZT0i5Y+q55yL5pyq5ZCv55SoIj7mnKrl
;kK/nlKg8L2J1dHRvbj4KICAgICAgPC9kaXY+CiAgICAgIDxidXR0b24gdHlwZT0iYnV0dG9uIiBpZD0iZmlsdGVyLWFkZCIgdGl0bGU9IueuoeeQhuagh+et
;viIgYXJpYS1sYWJlbD0i566h55CG5qCH562+Ij4KICAgICAgICA8c3ZnIHZpZXdCb3g9IjAgMCAxMiAxMiIgZmlsbD0ibm9uZSIgYXJpYS1oaWRkZW49InRy
;dWUiPgogICAgICAgICAgPHBhdGggZD0iTTYgMi4ydjcuNk0yLjIgNmg3LjYiIHN0cm9rZT0iY3VycmVudENvbG9yIiBzdHJva2Utd2lkdGg9IjEuNiIgc3Ry
;b2tlLWxpbmVjYXA9InJvdW5kIi8+CiAgICAgICAgPC9zdmc+CiAgICAgIDwvYnV0dG9uPgogICAgPC9kaXY+CiAgICA8ZGl2IGNsYXNzPSJ0Yi1zcGFjZSIg
;aWQ9InRpdGxlYmFyLWRyYWciPjwvZGl2PgogICAgPGRpdiBjbGFzcz0idGItd2luIG5vLWRyYWciPgogICAgICA8YnV0dG9uIHR5cGU9ImJ1dHRvbiIgaWQ9
;ImJ0bi13aW4tbWluIiB0aXRsZT0i5pyA5bCP5YyWIiBhcmlhLWxhYmVsPSLmnIDlsI/ljJYiPgogICAgICAgIDxzdmcgdmlld0JveD0iMCAwIDEwIDEwIiBm
;aWxsPSJub25lIiBhcmlhLWhpZGRlbj0idHJ1ZSI+PHBhdGggZD0iTTEuNSA1aDciIHN0cm9rZT0iY3VycmVudENvbG9yIiBzdHJva2Utd2lkdGg9IjEuMiIg
;c3Ryb2tlLWxpbmVjYXA9InJvdW5kIi8+PC9zdmc+CiAgICAgIDwvYnV0dG9uPgogICAgICA8YnV0dG9uIHR5cGU9ImJ1dHRvbiIgaWQ9ImJ0bi13aW4tbWF4
;IiB0aXRsZT0i5pyA5aSn5YyWIiBhcmlhLWxhYmVsPSLmnIDlpKfljJYiPgogICAgICAgIDxzdmcgdmlld0JveD0iMCAwIDEwIDEwIiBmaWxsPSJub25lIiBh
;cmlhLWhpZGRlbj0idHJ1ZSI+PHJlY3QgeD0iMS42IiB5PSIxLjYiIHdpZHRoPSI2LjgiIGhlaWdodD0iNi44IiByeD0iMC42IiBzdHJva2U9ImN1cnJlbnRD
;b2xvciIgc3Ryb2tlLXdpZHRoPSIxLjIiLz48L3N2Zz4KICAgICAgPC9idXR0b24+CiAgICAgIDxidXR0b24gdHlwZT0iYnV0dG9uIiBpZD0iYnRuLXdpbi1j
;bG9zZSIgdGl0bGU9IuWFs+mXrSIgYXJpYS1sYWJlbD0i5YWz6ZetIj4KICAgICAgICA8c3ZnIHZpZXdCb3g9IjAgMCAxMCAxMCIgZmlsbD0ibm9uZSIgYXJp
;YS1oaWRkZW49InRydWUiPjxwYXRoIGQ9Ik0yIDJsNiA2TTggMkwyIDgiIHN0cm9rZT0iY3VycmVudENvbG9yIiBzdHJva2Utd2lkdGg9IjEuMiIgc3Ryb2tl
;LWxpbmVjYXA9InJvdW5kIi8+PC9zdmc+CiAgICAgIDwvYnV0dG9uPgogICAgPC9kaXY+CiAgPC9kaXY+CiAgPGRpdiBpZD0iYm9vdCIgY2xhc3M9Im9uIj4K
;ICAgIDxkaXYgY2xhc3M9InJpbmctd3JhcCI+CiAgICAgIDxzdmcgdmlld0JveD0iMCAwIDEyMCAxMjAiPgogICAgICAgIDxjaXJjbGUgY2xhc3M9InJpbmct
;YmciIGN4PSI2MCIgY3k9IjYwIiByPSI1MiI+PC9jaXJjbGU+CiAgICAgICAgPGNpcmNsZSBpZD0icmluZy1mZyIgY2xhc3M9InJpbmctZmciIGN4PSI2MCIg
;Y3k9IjYwIiByPSI1MiIKICAgICAgICAgIHN0cm9rZS1kYXNoYXJyYXk9IjMyNi43MyIgc3Ryb2tlLWRhc2hvZmZzZXQ9IjMyNi43MyI+PC9jaXJjbGU+CiAg
;ICAgIDwvc3ZnPgogICAgICA8ZGl2IGNsYXNzPSJyaW5nLWxhYmVsIj4KICAgICAgICA8ZGl2IGNsYXNzPSJ0MSI+56OB55uY57Si5byV5LitPC9kaXY+CiAg
;ICAgICAgPGRpdiBjbGFzcz0idDIiIGlkPSJib290LXBjdCI+4oCmPC9kaXY+CiAgICAgIDwvZGl2PgogICAgPC9kaXY+CiAgICA8ZGl2IGNsYXNzPSJib290
;LWhpbnQiPgogICAgICDmraPlnKjlu7rnq4vno4Hnm5jmlofku7bntKLlvJXvvIzlrozmiJDlkI7ljbPlj6/mkJzntKLjgII8YnI+CiAgICAgIOiLpeacrOac
;uuW3suWuieijhSBFdmVyeXRoaW5nIOW5tuW8gOacuuWQr+WKqO+8jOS4i+asoeS8muabtOW/q+Wwsee7quOAggogICAgPC9kaXY+CiAgPC9kaXY+CgogIDxk
;aXYgaWQ9ImNocm9tZSIgY2xhc3M9ImhpZGRlbiI+CiAgICA8ZGl2IGlkPSJ2aWV3LXNlYXJjaCI+CiAgICA8ZGl2IGlkPSJ0b3AiPgogICAgICA8ZGl2IGlk
;PSJkcml2ZS13cmFwIiBjbGFzcz0ibm8tZHJhZyI+CiAgICAgICAgPGJ1dHRvbiBpZD0iYnRuLWRyaXZlIiB0eXBlPSJidXR0b24iIHRpdGxlPSLpgInmi6nm
;kJzntKLno4Hnm5giPgogICAgICAgICAgPGltZyBpZD0iZHJpdmUtYnRuLWljbyIgY2xhc3M9ImRyaXZlLWljbyBoaWRkZW4iIGFsdD0iIiB3aWR0aD0iMjAi
;IGhlaWdodD0iMjAiPgogICAgICAgICAgPHNwYW4gaWQ9ImRyaXZlLWxhYmVsIj7lhajnm5jmkJzntKI8L3NwYW4+PHNwYW4gY2xhc3M9ImNhcmV0Ij7ilr48
;L3NwYW4+CiAgICAgICAgPC9idXR0b24+CiAgICAgICAgPGRpdiBpZD0iZHJpdmUtbWVudSIgcm9sZT0ibWVudSI+PC9kaXY+CiAgICAgIDwvZGl2PgogICAg
;ICA8ZGl2IGlkPSJ0b3AtcmVzdCI+CiAgICAgICAgPGRpdiBpZD0ic2VhcmNoLXdyYXAiIGNsYXNzPSJuby1kcmFnIj4KICAgICAgICAgIDxkaXYgaWQ9InNl
;YXJjaC1ib3giPgogICAgICAgICAgICA8YnV0dG9uIHR5cGU9ImJ1dHRvbiIgaWQ9InNlYXJjaC1pY28iIHRpdGxlPSLmnIDov5HmkJzntKIiIGFyaWEtbGFi
;ZWw9IuacgOi/keaQnOe0oiI+CiAgICAgICAgICAgICAgPHN2ZyB2aWV3Qm94PSIwIDAgMTYgMTYiIGZpbGw9Im5vbmUiIGFyaWEtaGlkZGVuPSJ0cnVlIj4K
;ICAgICAgICAgICAgICAgIDxjaXJjbGUgY3g9IjciIGN5PSI3IiByPSI0LjI1IiBzdHJva2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIxLjQiLz4K
;ICAgICAgICAgICAgICAgIDxwYXRoIGQ9Ik0xMC4yIDEwLjJMMTMuNCAxMy40IiBzdHJva2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIxLjQiIHN0
;cm9rZS1saW5lY2FwPSJyb3VuZCIvPgogICAgICAgICAgICAgIDwvc3ZnPgogICAgICAgICAgICA8L2J1dHRvbj4KICAgICAgICAgICAgPGlucHV0IGlkPSJx
;IiB0eXBlPSJ0ZXh0IiBwbGFjZWhvbGRlcj0i6L6T5YWl5paH5Lu25ZCNIC8g5omp5bGV5ZCNIC8g6Lev5b6E5YWz6ZSu5a2X77ybfCDooajnpLrkuJTvvIx8
;fCDooajnpLrmiJYiIGF1dG9jb21wbGV0ZT0ib2ZmIiBzcGVsbGNoZWNrPSJmYWxzZSI+CiAgICAgICAgICAgIDxidXR0b24gdHlwZT0iYnV0dG9uIiBpZD0i
;Y2ZnLXNlYXJjaC1jbGVhciIgdGl0bGU9Iua4heepuuaQnOe0ouadoeS7tiIgYXJpYS1sYWJlbD0i5riF56m65pCc57SiIj4KICAgICAgICAgICAgICA8c3Bh
;biBpZD0iY2ZnLXNlYXJjaC1oaXQiPjwvc3Bhbj4KICAgICAgICAgICAgICA8c3ZnIGNsYXNzPSJjZmcteCIgdmlld0JveD0iMCAwIDI0IDI0IiBmaWxsPSJu
;b25lIiBzdHJva2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIyLjIiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIgYXJpYS1oaWRkZW49InRydWUiPjxw
;YXRoIGQ9Ik02IDZsMTIgMTJNMTggNkw2IDE4Ii8+PC9zdmc+CiAgICAgICAgICAgIDwvYnV0dG9uPgogICAgICAgICAgICA8YnV0dG9uIGlkPSJidG4tY2xl
;YXIiIHR5cGU9ImJ1dHRvbiIgdGl0bGU9Iua4heepuuaQnOe0oiI+5riF56m6PC9idXR0b24+CiAgICAgICAgICAgIDxkaXYgaWQ9Imhpc3QtbWVudSIgcm9s
;ZT0ibWVudSI+PC9kaXY+CiAgICAgICAgICA8L2Rpdj4KICAgICAgICA8L2Rpdj4KICAgICAgICA8ZGl2IGlkPSJ0b3AtcHJldmlldyIgY2xhc3M9Im5vLWRy
;YWciPgogICAgICAgICAgPGRpdiBjbGFzcz0icHYtbWV0YSIgaWQ9InB2LW1ldGEiPumAieaLqeaWh+S7tuS7pemihOiniDwvZGl2PgogICAgICAgIDwvZGl2
;PgogICAgICA8L2Rpdj4KICAgIDwvZGl2PgoKICAgIDxkaXYgaWQ9Im1haW4iPgogICAgICA8YXNpZGUgaWQ9InNpZGUiPgogICAgICAgIDxidXR0b24gY2xh
;c3M9ImNhdCBvbiIgZGF0YS1jYXQ9ImFsbCI+PHNwYW4gY2xhc3M9ImljbyIgZGF0YS1jYXQtaWNvPSJhbGwiPuKYsDwvc3Bhbj7lhajpg6g8L2J1dHRvbj4K
;ICAgICAgICA8YnV0dG9uIGNsYXNzPSJjYXQiIGRhdGEtY2F0PSJmb2xkZXIiPjxzcGFuIGNsYXNzPSJpY28iIGRhdGEtY2F0LWljbz0iZm9sZGVyIj7wn5OB
;PC9zcGFuPuaWh+S7tuWkuTwvYnV0dG9uPgogICAgICAgIDxidXR0b24gY2xhc3M9ImNhdCIgZGF0YS1jYXQ9ImV4Y2VsIj48c3BhbiBjbGFzcz0iaWNvIiBk
;YXRhLWNhdC1pY289ImV4Y2VsIj7wn5OKPC9zcGFuPkVYQ0VMPC9idXR0b24+CiAgICAgICAgPGJ1dHRvbiBjbGFzcz0iY2F0IiBkYXRhLWNhdD0id29yZCI+
;PHNwYW4gY2xhc3M9ImljbyIgZGF0YS1jYXQtaWNvPSJ3b3JkIj7wn5OEPC9zcGFuPldPUkQ8L2J1dHRvbj4KICAgICAgICA8YnV0dG9uIGNsYXNzPSJjYXQi
;IGRhdGEtY2F0PSJwcHQiPjxzcGFuIGNsYXNzPSJpY28iIGRhdGEtY2F0LWljbz0icHB0Ij7wn5ORPC9zcGFuPlBQVDwvYnV0dG9uPgogICAgICAgIDxidXR0
;b24gY2xhc3M9ImNhdCIgZGF0YS1jYXQ9InBkZiI+PHNwYW4gY2xhc3M9ImljbyIgZGF0YS1jYXQtaWNvPSJwZGYiPvCfk5U8L3NwYW4+UERGPC9idXR0b24+
;CiAgICAgICAgPGJ1dHRvbiBjbGFzcz0iY2F0IiBkYXRhLWNhdD0iaW1hZ2UiPjxzcGFuIGNsYXNzPSJpY28iIGRhdGEtY2F0LWljbz0iaW1hZ2UiPvCflrw8
;L3NwYW4+5Zu+54mHPC9idXR0b24+CiAgICAgICAgPGJ1dHRvbiBjbGFzcz0iY2F0IiBkYXRhLWNhdD0idmlkZW8iPjxzcGFuIGNsYXNzPSJpY28iIGRhdGEt
;Y2F0LWljbz0idmlkZW8iPuKWtjwvc3Bhbj7op4bpopE8L2J1dHRvbj4KICAgICAgICA8YnV0dG9uIGNsYXNzPSJjYXQiIGRhdGEtY2F0PSJhdWRpbyI+PHNw
;YW4gY2xhc3M9ImljbyIgZGF0YS1jYXQtaWNvPSJhdWRpbyI+4pmqPC9zcGFuPumfs+mikTwvYnV0dG9uPgogICAgICAgIDxidXR0b24gY2xhc3M9ImNhdCIg
;ZGF0YS1jYXQ9InppcCI+PHNwYW4gY2xhc3M9ImljbyIgZGF0YS1jYXQtaWNvPSJ6aXAiPvCfl5w8L3NwYW4+5Y6L57yp5paH5Lu2PC9idXR0b24+CiAgICAg
;ICAgPGRpdiBjbGFzcz0ic2lkZS1zZXAiIHJvbGU9InNlcGFyYXRvciI+PC9kaXY+CiAgICAgICAgPGJ1dHRvbiBjbGFzcz0iY2F0IiBkYXRhLWNhdD0iX19o
;YW5kbGUiIHR5cGU9ImJ1dHRvbiI+PHNwYW4gY2xhc3M9ImljbyI+4puTPC9zcGFuPuWFs+iBlOWPpeafhDwvYnV0dG9uPgogICAgICAgIDxidXR0b24gY2xh
;c3M9ImNhdCIgZGF0YS1jYXQ9Il9faW5mbyIgdHlwZT0iYnV0dG9uIj48c3BhbiBjbGFzcz0iaWNvIj7ihLk8L3NwYW4+5pys5py65L+h5oGvPC9idXR0b24+
;CiAgICAgICAgPGRpdiBjbGFzcz0ic2lkZS1zZXAiIHJvbGU9InNlcGFyYXRvciI+PC9kaXY+CiAgICAgICAgPGJ1dHRvbiBjbGFzcz0iY2F0IiBkYXRhLWNh
;dD0iX19jb25maWciIHR5cGU9ImJ1dHRvbiI+PHNwYW4gY2xhc3M9ImljbyI+4pqZPC9zcGFuPui/kOihjOmFjee9rjwvYnV0dG9uPgogICAgICAgIDxkaXYg
;aWQ9InNpZGUtZm9vdCI+PC9kaXY+CiAgICAgIDwvYXNpZGU+CgogICAgICA8ZGl2IGlkPSJjb250ZW50LXBhbmUiPgogICAgICAgIDxzZWN0aW9uIGlkPSJs
;aXN0LXBhbmUiPgogICAgICAgICAgPGRpdiBpZD0iZmlsZS1yZXN1bHRzIj4KICAgICAgICAgICAgPGRpdiBpZD0ibGlzdCI+PC9kaXY+CiAgICAgICAgICAg
;IDxkaXYgaWQ9Imxpc3QtZW1wdHkiPui+k+WFpeWFs+mUruWtl+W8gOWni+aQnOe0ou+8jOaIlumAieaLqeW3puS+p+WIhuexu+a1j+iniDwvZGl2PgogICAg
;ICAgICAgPC9kaXY+CiAgICAgICAgICA8ZGl2IGlkPSJoYW5kbGUtcGFuZWwiIGNsYXNzPSJoaWRkZW4gbm8tZHJhZyBlbWJlZGRlZCI+CiAgICAgICAgICAg
;IDxkaXYgY2xhc3M9ImhhbmRsZS1iYW5uZXIiIGlkPSJoYW5kbGUtYmFubmVyIj48L2Rpdj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0iaGFuZGxlLXNjcm9s
;bCIgaWQ9ImhhbmRsZS1zY3JvbGwiPgogICAgICAgICAgICAgIDxkaXYgY2xhc3M9ImhhbmRsZS1oZWFkIGhhbmRsZS1jb2xzIiBpZD0iaGFuZGxlLWhlYWQi
;PgogICAgICAgICAgICAgICAgPGRpdiBjbGFzcz0iaGFuZGxlLWhjZWxsIiBkYXRhLXNvcnQ9Im5hbWUiPuWQjeensDxzcGFuIGNsYXNzPSJoLXNvcnQiPjwv
;c3Bhbj48L2Rpdj4KICAgICAgICAgICAgICAgIDxkaXYgY2xhc3M9ImhhbmRsZS1oY2VsbCIgZGF0YS1zb3J0PSJwaWQiPlBJRDxzcGFuIGNsYXNzPSJoLXNv
;cnQiPjwvc3Bhbj48L2Rpdj4KICAgICAgICAgICAgICAgIDxkaXYgY2xhc3M9ImhhbmRsZS1oY2VsbCBoYW5kbGUtY29sLXBvcnQgaGlkZGVuIiBkYXRhLXNv
;cnQ9Imxwb3J0Ij7mnKzmnLrnq6/lj6M8c3BhbiBjbGFzcz0iaC1zb3J0Ij48L3NwYW4+PC9kaXY+CiAgICAgICAgICAgICAgICA8ZGl2IGNsYXNzPSJoYW5k
;bGUtaGNlbGwgaGFuZGxlLWNvbC1ycG9ydCBoaWRkZW4iIGRhdGEtc29ydD0icnBvcnQiPui/nOeoi+err+WPozxzcGFuIGNsYXNzPSJoLXNvcnQiPjwvc3Bh
;bj48L2Rpdj4KICAgICAgICAgICAgICAgIDxkaXYgY2xhc3M9ImhhbmRsZS1oY2VsbCIgZGF0YS1zb3J0PSJ0eXBlIj7nsbvlnos8c3BhbiBjbGFzcz0iaC1z
;b3J0Ij48L3NwYW4+PC9kaXY+CiAgICAgICAgICAgICAgICA8ZGl2IGNsYXNzPSJoYW5kbGUtaGNlbGwiIGRhdGEtc29ydD0iaGFuZGxlIj7lj6Xmn4TlkI3n
;p7A8c3BhbiBjbGFzcz0iaC1zb3J0Ij48L3NwYW4+PC9kaXY+CiAgICAgICAgICAgICAgPC9kaXY+CiAgICAgICAgICAgICAgPGRpdiBjbGFzcz0iaGFuZGxl
;LWJvZHkiIGlkPSJoYW5kbGUtYm9keSI+CiAgICAgICAgICAgICAgICA8ZGl2IGNsYXNzPSJoYW5kbGUtZW1wdHkiPuWPpeafhOaQnOe0ou+8mui+k+WFpeWF
;s+mUruWtl++8m+err+WPo+aQnOe0ou+8mjgwODB8ODAg5oiWIDAtMzAwfDUwMDwvZGl2PgogICAgICAgICAgICAgIDwvZGl2PgogICAgICAgICAgICA8L2Rp
;dj4KICAgICAgICAgIDwvZGl2PgogICAgICAgICAgPGRpdiBpZD0iaW5mby1wYW5lbCIgY2xhc3M9ImhpZGRlbiBuby1kcmFnIGVtYmVkZGVkIj48L2Rpdj4K
;ICAgICAgICAgIDxkaXYgaWQ9ImNvbmZpZy1wYW5lbCIgY2xhc3M9ImhpZGRlbiBuby1kcmFnIGVtYmVkZGVkIj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0i
;Y2ZnLXRvcCI+CiAgICAgICAgICAgICAgPGRpdiBjbGFzcz0iY2ZnLXRhYnMiIHJvbGU9InRhYmxpc3QiPgogICAgICAgICAgICAgICAgPGJ1dHRvbiB0eXBl
;PSJidXR0b24iIGNsYXNzPSJjZmctdGFiIG9uIiBkYXRhLWNmZz0icnVuY29uZmlnIj7ov5DooYzphY3nva48L2J1dHRvbj4KICAgICAgICAgICAgICAgIDxi
;dXR0b24gdHlwZT0iYnV0dG9uIiBjbGFzcz0iY2ZnLXRhYiIgZGF0YS1jZmc9ImdldGNvbmZpZyI+5Y+W5YC86YWN572uPC9idXR0b24+CiAgICAgICAgICAg
;ICAgICA8YnV0dG9uIHR5cGU9ImJ1dHRvbiIgY2xhc3M9ImNmZy10YWIiIGRhdGEtY2ZnPSJzeXNjb25maWciPuezu+e7n+mFjee9rjwvYnV0dG9uPgogICAg
;ICAgICAgICAgIDwvZGl2PgogICAgICAgICAgICAgIDxkaXYgY2xhc3M9ImNmZy10b29scyI+CiAgICAgICAgICAgICAgICA8YnV0dG9uIHR5cGU9ImJ1dHRv
;biIgaWQ9ImNmZy10b2dnbGUtYWxsIiBjbGFzcz0iY2ZnLWljby1idG4iIHRpdGxlPSLlhajpg6jlsZXlvIAiIGFyaWEtZXhwYW5kZWQ9ImZhbHNlIj4KICAg
;ICAgICAgICAgICAgICAgPHN2ZyBjbGFzcz0iaWNvLWV4cGFuZCIgdmlld0JveD0iMCAwIDI0IDI0IiBmaWxsPSJub25lIiBzdHJva2U9ImN1cnJlbnRDb2xv
;ciIgc3Ryb2tlLXdpZHRoPSIxLjkiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIgc3Ryb2tlLWxpbmVqb2luPSJyb3VuZCIgYXJpYS1oaWRkZW49InRydWUiPjxw
;YXRoIGQ9Ik03IDhsNSA1IDUtNSIvPjxwYXRoIGQ9Ik03IDEzbDUgNSA1LTUiLz48L3N2Zz4KICAgICAgICAgICAgICAgICAgPHN2ZyBjbGFzcz0iaWNvLWNv
;bGxhcHNlIiB2aWV3Qm94PSIwIDAgMjQgMjQiIGZpbGw9Im5vbmUiIHN0cm9rZT0iY3VycmVudENvbG9yIiBzdHJva2Utd2lkdGg9IjEuOSIgc3Ryb2tlLWxp
;bmVjYXA9InJvdW5kIiBzdHJva2UtbGluZWpvaW49InJvdW5kIiBhcmlhLWhpZGRlbj0idHJ1ZSI+PHBhdGggZD0iTTcgMTZsNS01IDUgNSIvPjxwYXRoIGQ9
;Ik03IDExbDUtNSA1IDUiLz48L3N2Zz4KICAgICAgICAgICAgICAgIDwvYnV0dG9uPgogICAgICAgICAgICAgICAgPGJ1dHRvbiB0eXBlPSJidXR0b24iIGlk
;PSJjZmctYWRkLWdyb3VwIiB0aXRsZT0i5re75Yqg57uEIj48c3BhbiBhcmlhLWhpZGRlbj0idHJ1ZSI+Kzwvc3Bhbj7mt7vliqDnu4Q8L2J1dHRvbj4KICAg
;ICAgICAgICAgICAgIDxidXR0b24gdHlwZT0iYnV0dG9uIiBpZD0iY2ZnLXNhdmUiIGNsYXNzPSJwcmltYXJ5IiB0aXRsZT0i5L+d5a2Y57O757uf6YWN572u
;5bm26YeN5ZCv6ISa5pysIj7kv53lrZg8L2J1dHRvbj4KICAgICAgICAgICAgICA8L2Rpdj4KICAgICAgICAgICAgPC9kaXY+CiAgICAgICAgICAgIDxkaXYg
;aWQ9ImNmZy1zdGF0dXMiPjwvZGl2PgogICAgICAgICAgICA8ZGl2IGlkPSJjZmctdGlwLXdyYXAiIGNsYXNzPSJoaWRkZW4iPgogICAgICAgICAgICAgIDxz
;cGFuIGNsYXNzPSJjZmctdGlwLWljbyIgYXJpYS1oaWRkZW49InRydWUiIHRpdGxlPSLor7TmmI4iPgogICAgICAgICAgICAgICAgPHN2ZyB2aWV3Qm94PSIw
;IDAgMjQgMjQiIGZpbGw9Im5vbmUiIHN0cm9rZT0iY3VycmVudENvbG9yIiBzdHJva2Utd2lkdGg9IjEuNyIgc3Ryb2tlLWxpbmVjYXA9InJvdW5kIiBzdHJv
;a2UtbGluZWpvaW49InJvdW5kIj48Y2lyY2xlIGN4PSIxMiIgY3k9IjEyIiByPSI5Ii8+PHBhdGggZD0iTTEyIDExdjZNMTIgOGguMDEiLz48L3N2Zz4KICAg
;ICAgICAgICAgICA8L3NwYW4+CiAgICAgICAgICAgICAgPGRpdiBjbGFzcz0iY2ZnLXRpcC1ib2R5Ij4KICAgICAgICAgICAgICAgIDxkaXYgaWQ9ImNmZy10
;aXAiIHRpdGxlPSLlj4zlh7vnvJbovpEiPjwvZGl2PgogICAgICAgICAgICAgICAgPHRleHRhcmVhIGlkPSJjZmctdGlwLWVkaXQiIHNwZWxsY2hlY2s9ImZh
;bHNlIiBhcmlhLWxhYmVsPSLnvJbovpHmlofku7bor7TmmI4iPjwvdGV4dGFyZWE+CiAgICAgICAgICAgICAgPC9kaXY+CiAgICAgICAgICAgIDwvZGl2Pgog
;ICAgICAgICAgICA8ZGl2IGlkPSJjZmctYm9keSI+PC9kaXY+CiAgICAgICAgICA8L2Rpdj4KICAgICAgICA8L3NlY3Rpb24+CgogICAgICAgIDxzZWN0aW9u
;IGlkPSJwcmV2aWV3IiBjbGFzcz0ib2ZmIj4KICAgICAgICAgIDxkaXYgY2xhc3M9InB2LWJvZHkiIGlkPSJwdi1ib2R5Ij4KICAgICAgICAgICAgPGRpdiBj
;bGFzcz0icHYtbWVkaWEiIGlkPSJwdi1tZWRpYSI+PGRpdiBjbGFzcz0icGgiPumihOiniOWMujwvZGl2PjwvZGl2PgogICAgICAgICAgICA8ZGl2IGNsYXNz
;PSJwdi10ZXh0IiBpZD0icHYtdGV4dCIgc3R5bGU9ImRpc3BsYXk6bm9uZSI+CiAgICAgICAgICAgICAgPGRpdiBjbGFzcz0iaGQiIGlkPSJwdi10ZXh0LWhk
;Ij7pooTop4jliY0gMjBLQiDlhoXlrrk8L2Rpdj4KICAgICAgICAgICAgICA8cHJlIGlkPSJwdi1wcmUiPjwvcHJlPgogICAgICAgICAgICA8L2Rpdj4KICAg
;ICAgICAgIDwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0icHYtb2ZmIj7mnKrlvIDlkK/jgIzmkJzntKLmlofmnKzjgI08L2Rpdj4KICAgICAgICA8L3Nl
;Y3Rpb24+CiAgICAgIDwvZGl2PgogICAgPC9kaXY+CgogICAgPGRpdiBpZD0iYmFyIj4KICAgICAgPGRpdiBjbGFzcz0iYmFyLWxlZnQiPgogICAgICAgIDxi
;dXR0b24gaWQ9ImJ0bi1zZXR0aW5ncyIgdHlwZT0iYnV0dG9uIiB0aXRsZT0i6K6+572uIj7impk8L2J1dHRvbj4KICAgICAgPC9kaXY+CiAgICAgIDxkaXYg
;Y2xhc3M9ImJhci1tYWluIj4KICAgICAgICA8YnV0dG9uIGNsYXNzPSJzb3J0IiBpZD0iYnRuLXNvcnQiIHR5cGU9ImJ1dHRvbiIgdGl0bGU9IuWIh+aNouaO
;kuW6jyI+4oeFIDxzcGFuIGlkPSJzb3J0LWxhYmVsIj7mjInkv67mlLnml7bpl7TpmY3luo88L3NwYW4+PC9idXR0b24+CiAgICAgICAgPGxhYmVsIGNsYXNz
;PSJ0b2dnbGUiIHRpdGxlPSLlvIDlkK/lkI7mjInovpPlhaXmoYblhbPplK7lrZfmkJzntKLmlofku7blhoXlrrnvvIjpnIAgRXZlcnl0aGluZyDlhoXlrrnn
;tKLlvJXvvIkiPgogICAgICAgICAgPGlucHV0IHR5cGU9ImNoZWNrYm94IiBpZD0iY2hrLXByZXZpZXciPgogICAgICAgICAgPHNwYW4gY2xhc3M9InN3Ij48
;L3NwYW4+CiAgICAgICAgICA8c3Bhbj7mkJzntKLmlofmnKw8L3NwYW4+CiAgICAgICAgPC9sYWJlbD4KICAgICAgICA8ZGl2IGNsYXNzPSJzcGFjZXIiPjwv
;ZGl2PgogICAgICAgIDxkaXYgaWQ9ImJhci1oYW5kbGUtYWN0aW9ucyIgY2xhc3M9Im5vLWRyYWciPgogICAgICAgICAgPHNwYW4gaWQ9ImhhbmRsZS1zdGF0
;dXMiPjwvc3Bhbj4KICAgICAgICAgIDxidXR0b24gaWQ9ImJ0bi1wb3J0LW1hcmsiIHR5cGU9ImJ1dHRvbiIgdGl0bGU9Iuagh+iusOerr+WPoyI+4pqZPC9i
;dXR0b24+CiAgICAgICAgICA8ZGl2IGlkPSJwb3J0LW1hcmstcG9wIiBjbGFzcz0ibm8tZHJhZyI+CiAgICAgICAgICAgIDxkaXYgY2xhc3M9InBtcC1oZCI+
;5qCH6K6w56uv5Y+jPC9kaXY+CiAgICAgICAgICAgIDxkaXYgY2xhc3M9InBtcC1oaW50Ij7ljLnphY3nmoTmnKzmnLov6L+c56iL56uv5Y+j5Lya6auY5Lqu
;5pi+56S677yM5Y+v6Ieq6KGM5re75YqgPC9kaXY+CiAgICAgICAgICAgIDxkaXYgY2xhc3M9InBtcC10YWdzIiBpZD0icG9ydC1tYXJrLXRhZ3MiPjwvZGl2
;PgogICAgICAgICAgICA8ZGl2IGNsYXNzPSJwbXAtYWRkIj4KICAgICAgICAgICAgICA8aW5wdXQgaWQ9InBvcnQtbWFyay1pbnB1dCIgdHlwZT0idGV4dCIg
;aW5wdXRtb2RlPSJudW1lcmljIiBwbGFjZWhvbGRlcj0i56uv5Y+j5Y+377yM5aaCIDkwMDAiIGF1dG9jb21wbGV0ZT0ib2ZmIiBzcGVsbGNoZWNrPSJmYWxz
;ZSI+CiAgICAgICAgICAgICAgPGJ1dHRvbiBpZD0icG9ydC1tYXJrLWFkZCIgdHlwZT0iYnV0dG9uIj7mt7vliqA8L2J1dHRvbj4KICAgICAgICAgICAgPC9k
;aXY+CiAgICAgICAgICAgIDxidXR0b24gaWQ9InBvcnQtbWFyay1yZXNldCIgdHlwZT0iYnV0dG9uIiBjbGFzcz0icG1wLXJlc2V0Ij7mgaLlpI3pu5jorqQ8
;L2J1dHRvbj4KICAgICAgICAgIDwvZGl2PgogICAgICAgIDwvZGl2PgogICAgICAgIDxkaXYgaWQ9ImJhci1pbmZvLWFjdGlvbnMiIGNsYXNzPSJuby1kcmFn
;Ij4KICAgICAgICAgIDxidXR0b24gaWQ9ImJ0bi1pbmZvLXJlZnJlc2giIHR5cGU9ImJ1dHRvbiI+5Yi35pawPC9idXR0b24+CiAgICAgICAgICA8YnV0dG9u
;IGlkPSJidG4taW5mby1jb3B5IiB0eXBlPSJidXR0b24iPuWkjeWItjwvYnV0dG9uPgogICAgICAgIDwvZGl2PgogICAgICAgIDxkaXYgaWQ9ImJhci1jb25m
;aWctYWN0aW9ucyIgY2xhc3M9Im5vLWRyYWciPgogICAgICAgICAgPHNwYW4gaWQ9ImNmZy1wYXRoLWxhYmVsIj48L3NwYW4+CiAgICAgICAgICA8YnV0dG9u
;IHR5cGU9ImJ1dHRvbiIgaWQ9ImNmZy1yZWxvYWQiIHRpdGxlPSLph43mlrDliqDovb0iPgogICAgICAgICAgICA8c3ZnIHZpZXdCb3g9IjAgMCAyNCAyNCIg
;ZmlsbD0ibm9uZSIgc3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0cm9rZS13aWR0aD0iMS44IiBzdHJva2UtbGluZWNhcD0icm91bmQiIHN0cm9rZS1saW5lam9p
;bj0icm91bmQiIGFyaWEtaGlkZGVuPSJ0cnVlIj48cGF0aCBkPSJNMjAgMTJhOCA4IDAgMSAxLTIuMi01LjUiLz48cGF0aCBkPSJNMjAgNHY1aC01Ii8+PC9z
;dmc+CiAgICAgICAgICA8L2J1dHRvbj4KICAgICAgICA8L2Rpdj4KICAgICAgICA8ZGl2IGlkPSJjb3VudCI+5YWxIDAg5p2h57uT5p6cPC9kaXY+CiAgICAg
;IDwvZGl2PgogICAgPC9kaXY+CiAgICA8L2Rpdj4KCiAgICA8ZGl2IGlkPSJmaWx0ZXItc2V0dGluZ3MiIGNsYXNzPSJuby1kcmFnIiByb2xlPSJkaWFsb2ci
;IGFyaWEtbW9kYWw9InRydWUiIGFyaWEtbGFiZWw9Iuetm+mAieiuvue9riI+CiAgICAgIDxkaXYgY2xhc3M9ImZzLWNhcmQiPgogICAgICAgIDxkaXYgY2xh
;c3M9ImZzLWhkIj4KICAgICAgICAgIDxzcGFuPuetm+mAieadoeS7tjwvc3Bhbj4KICAgICAgICAgIDxidXR0b24gdHlwZT0iYnV0dG9uIiBpZD0iZnMtY2xv
;c2UiIHRpdGxlPSLlhbPpl60iPsOXPC9idXR0b24+CiAgICAgICAgPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0iZnMtYmQiPgogICAgICAgICAgPGRpdiBj
;bGFzcz0iZnMtdGFicyIgcm9sZT0idGFibGlzdCI+CiAgICAgICAgICAgIDxidXR0b24gdHlwZT0iYnV0dG9uIiBjbGFzcz0iZnMtdGFiIG9uIiBkYXRhLWZz
;LXRhYj0ibmFtZSI+5ZCN56ew5qCH562+PC9idXR0b24+CiAgICAgICAgICAgIDxidXR0b24gdHlwZT0iYnV0dG9uIiBjbGFzcz0iZnMtdGFiIiBkYXRhLWZz
;LXRhYj0icGF0aCI+6Lev5b6E5qCH562+PC9idXR0b24+CiAgICAgICAgICA8L2Rpdj4KICAgICAgICAgIDxkaXYgY2xhc3M9ImZzLWhpbnQiIGlkPSJmcy1o
;aW50LW5hbWUiPuWQr+eUqOeahOWQjeensOagh+etvuS8muWHuueOsOWcqOmhtumDqO+8m+mAieS4reWQjuS7peiTneiJsuaYvuekuu+8jOW5tuaKiuato+WI
;meWKoOWFpeaWh+S7tuWQjeaQnOe0ouOAgjwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0iZnMtaGludCIgaWQ9ImZzLWhpbnQtcGF0aCIgc3R5bGU9ImRp
;c3BsYXk6bm9uZSI+5ZCv55So55qE6Lev5b6E5qCH562+5Lya5Ye6546w5Zyo6aG26YOo77yb6YCJ5Lit5ZCO5Lul6JOd6Imy5pi+56S677yM5bm25oyJ6Lev
;5b6E6L+H5ruk77yb5ZCM5pe26IGU5Yqo5bem5L6n55uY56ym44CCPC9kaXY+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJmcy1saXN0IiBpZD0iZnMtbGlzdCI+
;PC9kaXY+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJmcy1mb3JtIj4KICAgICAgICAgICAgPGRpdj4KICAgICAgICAgICAgICA8bGFiZWwgZm9yPSJmcy10aXRs
;ZSI+5qCH6aKYPC9sYWJlbD4KICAgICAgICAgICAgICA8aW5wdXQgaWQ9ImZzLXRpdGxlIiB0eXBlPSJ0ZXh0IiBtYXhsZW5ndGg9IjI0IiBwbGFjZWhvbGRl
;cj0i5L6L5aaC77ya6aG555uu55uu5b2VIiBhdXRvY29tcGxldGU9Im9mZiI+CiAgICAgICAgICAgIDwvZGl2PgogICAgICAgICAgICA8ZGl2IGNsYXNzPSJm
;cy1mb3JtLW5hbWUiPgogICAgICAgICAgICAgIDxsYWJlbCBmb3I9ImZzLXJlZ2V4Ij7mraPliJnooajovr7lvI88L2xhYmVsPgogICAgICAgICAgICAgIDxp
;bnB1dCBpZD0iZnMtcmVnZXgiIHR5cGU9InRleHQiIG1heGxlbmd0aD0iMjAwIiBwbGFjZWhvbGRlcj0i5L6L5aaC77yaKD9pKVwudG1wJCIgYXV0b2NvbXBs
;ZXRlPSJvZmYiIHNwZWxsY2hlY2s9ImZhbHNlIj4KICAgICAgICAgICAgPC9kaXY+CiAgICAgICAgICAgIDxkaXYgY2xhc3M9ImZzLWZvcm0tcGF0aCI+CiAg
;ICAgICAgICAgICAgPGxhYmVsIGZvcj0iZnMtcGF0aCI+6Lev5b6EPC9sYWJlbD4KICAgICAgICAgICAgICA8aW5wdXQgaWQ9ImZzLXBhdGgiIHR5cGU9InRl
;eHQiIG1heGxlbmd0aD0iMjYwIiBwbGFjZWhvbGRlcj0i5L6L5aaC77yaRDpcd29ya1xwcm9qZWN0IiBhdXRvY29tcGxldGU9Im9mZiIgc3BlbGxjaGVjaz0i
;ZmFsc2UiPgogICAgICAgICAgICA8L2Rpdj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0iZnMtYWN0aW9ucyI+CiAgICAgICAgICAgICAgPGJ1dHRvbiB0eXBl
;PSJidXR0b24iIGNsYXNzPSJwcmltYXJ5IiBpZD0iZnMtYWRkIj7liqDlhaXnrZvpgIk8L2J1dHRvbj4KICAgICAgICAgICAgPC9kaXY+CiAgICAgICAgICA8
;L2Rpdj4KICAgICAgICA8L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJmcy1mb290Ij4KICAgICAgICAgIDxidXR0b24gdHlwZT0iYnV0dG9uIiBpZD0iZnMt
;ZXYtb3B0cyI+5omT5byAIEV2ZXJ5dGhpbmcg6YCJ6aG54oCmPC9idXR0b24+CiAgICAgICAgICA8YnV0dG9uIHR5cGU9ImJ1dHRvbiIgaWQ9ImZzLXJlc2V0
;IiB0aXRsZT0i5oGi5aSN5YaF572u562b6YCJ5bm25riF56m66Ieq5a6a5LmJIj7mgaLlpI3pu5jorqQ8L2J1dHRvbj4KICAgICAgICA8L2Rpdj4KICAgICAg
;PC9kaXY+CiAgICA8L2Rpdj4KCiAgICA8ZGl2IGlkPSJoYW5kbGUtdGFnLXBvcCIgY2xhc3M9Im5vLWRyYWciIHJvbGU9ImRpYWxvZyIgYXJpYS1tb2RhbD0i
;dHJ1ZSIgYXJpYS1sYWJlbD0i5pCc57Si5qCH562+Ij4KICAgICAgPGRpdiBjbGFzcz0iaHRwLWNhcmQiPgogICAgICAgIDxkaXYgY2xhc3M9Imh0cC1oZCI+
;CiAgICAgICAgICA8c3Bhbj7mkJzntKLmoIfnrb48L3NwYW4+CiAgICAgICAgICA8YnV0dG9uIHR5cGU9ImJ1dHRvbiIgaWQ9Imh0cC1jbG9zZSIgdGl0bGU9
;IuWFs+mXrSI+w5c8L2J1dHRvbj4KICAgICAgICA8L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJodHAtdGFncyIgaWQ9ImhhbmRsZS10YWctbWFuYWdlIj48
;L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJodHAtYWRkIj4KICAgICAgICAgIDxkaXYgY2xhc3M9Imh0cC1yb3ciPgogICAgICAgICAgICA8c3BhbiBjbGFz
;cz0iaHRwLWxhYiI+CiAgICAgICAgICAgICAgPHN2ZyB2aWV3Qm94PSIwIDAgMjQgMjQiIGZpbGw9Im5vbmUiIHN0cm9rZT0iY3VycmVudENvbG9yIiBzdHJv
;a2Utd2lkdGg9IjEuNyIgc3Ryb2tlLWxpbmVjYXA9InJvdW5kIiBzdHJva2UtbGluZWpvaW49InJvdW5kIiBhcmlhLWhpZGRlbj0idHJ1ZSI+CiAgICAgICAg
;ICAgICAgICA8cGF0aCBkPSJNMjAuNiAxMy4xbC03LjUgNy41YTIgMiAwIDAgMS0yLjggMEwzLjQgMTMuN2EyIDIgMCAwIDEgMC0yLjhsNy41LTcuNWEyIDIg
;MCAwIDEgMS40LS42SDE5YTIgMiAwIDAgMSAyIDJ2Ni43YTIgMiAwIDAgMS0uNiAxLjR6Ii8+CiAgICAgICAgICAgICAgICA8Y2lyY2xlIGN4PSIxNi4yIiBj
;eT0iNy44IiByPSIxLjIiIGZpbGw9ImN1cnJlbnRDb2xvciIgc3Ryb2tlPSJub25lIi8+CiAgICAgICAgICAgICAgPC9zdmc+CiAgICAgICAgICAgICAg5qCH
;562+77yaCiAgICAgICAgICAgIDwvc3Bhbj4KICAgICAgICAgICAgPGlucHV0IGlkPSJodHAtdGl0bGUiIHR5cGU9InRleHQiIG1heGxlbmd0aD0iMjQiIHBs
;YWNlaG9sZGVyPSLlpoIgQ2hyb21lIiBhdXRvY29tcGxldGU9Im9mZiI+CiAgICAgICAgICA8L2Rpdj4KICAgICAgICAgIDxkaXYgY2xhc3M9Imh0cC1yb3ci
;PgogICAgICAgICAgICA8c3BhbiBjbGFzcz0iaHRwLWxhYiI+CiAgICAgICAgICAgICAgPHN2ZyB2aWV3Qm94PSIwIDAgMjQgMjQiIGZpbGw9Im5vbmUiIHN0
;cm9rZT0iY3VycmVudENvbG9yIiBzdHJva2Utd2lkdGg9IjEuNyIgc3Ryb2tlLWxpbmVjYXA9InJvdW5kIiBzdHJva2UtbGluZWpvaW49InJvdW5kIiBhcmlh
;LWhpZGRlbj0idHJ1ZSI+CiAgICAgICAgICAgICAgICA8Y2lyY2xlIGN4PSIxMSIgY3k9IjExIiByPSI2LjIiLz4KICAgICAgICAgICAgICAgIDxwYXRoIGQ9
;Ik0xNi4yIDE2LjJMMjAuNSAyMC41Ii8+CiAgICAgICAgICAgICAgPC9zdmc+CiAgICAgICAgICAgICAg5p2h5Lu277yaCiAgICAgICAgICAgIDwvc3Bhbj4K
;ICAgICAgICAgICAgPGlucHV0IGlkPSJodHAtcXVlcnkiIHR5cGU9InRleHQiIG1heGxlbmd0aD0iMTIwIiBwbGFjZWhvbGRlcj0i5aaCIGNocm9tZSDmiJYg
;ODA4MCIgYXV0b2NvbXBsZXRlPSJvZmYiIHNwZWxsY2hlY2s9ImZhbHNlIj4KICAgICAgICAgIDwvZGl2PgogICAgICAgICAgPGJ1dHRvbiBpZD0iaHRwLWFk
;ZCIgdHlwZT0iYnV0dG9uIj7kv53lrZg8L2J1dHRvbj4KICAgICAgICA8L2Rpdj4KICAgICAgPC9kaXY+CiAgICA8L2Rpdj4KCiAgICAgICAgPGRpdiBpZD0i
;cHJvYy1tZW51IiByb2xlPSJtZW51Ij4KICAgICAgPGJ1dHRvbiB0eXBlPSJidXR0b24iIGRhdGEtcGFjdD0icmV2ZWFsIj48c3BhbiBjbGFzcz0iYy1pY28i
;IGFyaWEtaGlkZGVuPSJ0cnVlIj48c3ZnIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0cm9rZS13aWR0
;aD0iMS44Ij48cGF0aCBkPSJNMyA3LjVBMS41IDEuNSAwIDAgMSA0LjUgNkg5bDIgMmg4LjVBMS41IDEuNSAwIDAgMSAyMSA5LjV2N0ExLjUgMS41IDAgMCAx
;IDE5LjUgMThoLTE1QTEuNSAxLjUgMCAwIDEgMyAxNi41di05eiIvPjwvc3ZnPjwvc3Bhbj48c3BhbiBjbGFzcz0icGFjdC1sYWJlbCI+5omT5byA6L+b56iL
;5omA5Zyo5L2N572uPC9zcGFuPjwvYnV0dG9uPgogICAgICA8YnV0dG9uIHR5cGU9ImJ1dHRvbiIgZGF0YS1wYWN0PSJjb3B5Ij48c3BhbiBjbGFzcz0iYy1p
;Y28iIGFyaWEtaGlkZGVuPSJ0cnVlIj48c3ZnIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0cm9rZS13
;aWR0aD0iMS44Ij48cmVjdCB4PSI4IiB5PSI4IiB3aWR0aD0iMTEiIGhlaWdodD0iMTEiIHJ4PSIxLjUiLz48cGF0aCBkPSJNNSAxNVY1LjVBMS41IDEuNSAw
;IDAgMSA2LjUgNEgxNSIvPjwvc3ZnPjwvc3Bhbj48c3BhbiBjbGFzcz0icGFjdC1sYWJlbCIgaWQ9InByb2MtbWVudS1jb3B5Ij7lpI3liLbov5vnqIvlkI08
;L3NwYW4+PC9idXR0b24+CiAgICAgIDxidXR0b24gdHlwZT0iYnV0dG9uIiBkYXRhLXBhY3Q9ImNvcHlQaWQiPjxzcGFuIGNsYXNzPSJjLWljbyIgYXJpYS1o
;aWRkZW49InRydWUiPjxzdmcgdmlld0JveD0iMCAwIDI0IDI0IiBmaWxsPSJub25lIiBzdHJva2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIxLjgi
;PjxwYXRoIGQ9Ik03IDdoNHY0SDd6TTEzIDdoNHY0aC00ek03IDEzaDR2NEg3ek0xMyAxM2g0djRoLTR6Ii8+PC9zdmc+PC9zcGFuPjxzcGFuIGNsYXNzPSJw
;YWN0LWxhYmVsIiBpZD0icHJvYy1tZW51LWNvcHlwaWQiPuWkjeWItui/m+eoi+WPtzwvc3Bhbj48L2J1dHRvbj4KICAgICAgPGJ1dHRvbiB0eXBlPSJidXR0
;b24iIGRhdGEtcGFjdD0iZW5kIiBjbGFzcz0iZGFuZ2VyIiBpZD0icHJvYy1tZW51LWVuZCI+PHNwYW4gY2xhc3M9ImMtaWNvIiBhcmlhLWhpZGRlbj0idHJ1
;ZSI+PHN2ZyB2aWV3Qm94PSIwIDAgMjQgMjQiIGZpbGw9Im5vbmUiIHN0cm9rZT0iY3VycmVudENvbG9yIiBzdHJva2Utd2lkdGg9IjEuOCI+PGNpcmNsZSBj
;eD0iMTIiIGN5PSIxMiIgcj0iOC41Ii8+PHBhdGggZD0iTTkgOWw2IDZNMTUgOWwtNiA2Ii8+PC9zdmc+PC9zcGFuPjxzcGFuIGNsYXNzPSJwYWN0LWxhYmVs
;IiBpZD0icHJvYy1tZW51LWVuZC1sYWJlbCI+5YWz6Zet6L+b56iLPC9zcGFuPjwvYnV0dG9uPgogICAgPC9kaXY+CiAgICA8ZGF0YWxpc3QgaWQ9ImhhbmRs
;ZS1oaXN0LWxpc3QiPjwvZGF0YWxpc3Q+CjwvZGl2PgoKICAgIDxkaXYgaWQ9InVpLWRsZyIgYXJpYS1oaWRkZW49InRydWUiPgogICAgICA8ZGl2IGNsYXNz
;PSJ1aS1kbGctbWFzayIgZGF0YS11aS1kbGctZGlzbWlzcz0iMSI+PC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9InVpLWRsZy1jYXJkIiByb2xlPSJkaWFsb2ci
;IGFyaWEtbW9kYWw9InRydWUiIGFyaWEtbGFiZWxsZWRieT0idWktZGxnLXRpdGxlIj4KICAgICAgICA8ZGl2IGNsYXNzPSJ1aS1kbGctdGl0bGUiIGlkPSJ1
;aS1kbGctdGl0bGUiPuaPkOekujwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9InVpLWRsZy1tc2ciIGlkPSJ1aS1kbGctbXNnIj48L2Rpdj4KICAgICAgICA8
;aW5wdXQgdHlwZT0idGV4dCIgY2xhc3M9InVpLWRsZy1pbnB1dCIgaWQ9InVpLWRsZy1pbnB1dCIgc3BlbGxjaGVjaz0iZmFsc2UiIGF1dG9jb21wbGV0ZT0i
;b2ZmIj4KICAgICAgICA8ZGl2IGNsYXNzPSJ1aS1kbGctYWN0aW9ucyI+CiAgICAgICAgICA8YnV0dG9uIHR5cGU9ImJ1dHRvbiIgaWQ9InVpLWRsZy1jYW5j
;ZWwiPuWPlua2iDwvYnV0dG9uPgogICAgICAgICAgPGJ1dHRvbiB0eXBlPSJidXR0b24iIGlkPSJ1aS1kbGctb2siIGNsYXNzPSJwcmltYXJ5Ij7noa7lrpo8
;L2J1dHRvbj4KICAgICAgICA8L2Rpdj4KICAgICAgPC9kaXY+CiAgICA8L2Rpdj4KICAgIDxkaXYgaWQ9ImNmZy1tZW51IiByb2xlPSJtZW51Ij4KICAgICAg
;PGJ1dHRvbiB0eXBlPSJidXR0b24iIGRhdGEtY2FjdD0iYWRkIj48c3BhbiBjbGFzcz0iYy1pY28iIGFyaWEtaGlkZGVuPSJ0cnVlIj48c3ZnIHZpZXdCb3g9
;IjAgMCAyNCAyNCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0cm9rZS13aWR0aD0iMS44IiBzdHJva2UtbGluZWNhcD0icm91bmQiPjxw
;YXRoIGQ9Ik0xMiA1djE0TTUgMTJoMTQiLz48L3N2Zz48L3NwYW4+PHNwYW4gY2xhc3M9ImNhY3QtbGFiZWwiPua3u+WKoOadoeebrjwvc3Bhbj48L2J1dHRv
;bj4KICAgICAgPGJ1dHRvbiB0eXBlPSJidXR0b24iIGRhdGEtY2FjdD0idG9wIj48c3BhbiBjbGFzcz0iYy1pY28iIGFyaWEtaGlkZGVuPSJ0cnVlIj48c3Zn
;IHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0cm9rZS13aWR0aD0iMS44IiBzdHJva2UtbGluZWNhcD0i
;cm91bmQiIHN0cm9rZS1saW5lam9pbj0icm91bmQiPjxwYXRoIGQ9Ik0xMiAxOVY3TTcgMTFsNS01IDUgNU01IDVoMTQiLz48L3N2Zz48L3NwYW4+PHNwYW4g
;Y2xhc3M9ImNhY3QtbGFiZWwiPue9rumhtjwvc3Bhbj48L2J1dHRvbj4KICAgICAgPGJ1dHRvbiB0eXBlPSJidXR0b24iIGRhdGEtY2FjdD0idXAiPjxzcGFu
;IGNsYXNzPSJjLWljbyIgYXJpYS1oaWRkZW49InRydWUiPjxzdmcgdmlld0JveD0iMCAwIDI0IDI0IiBmaWxsPSJub25lIiBzdHJva2U9ImN1cnJlbnRDb2xv
;ciIgc3Ryb2tlLXdpZHRoPSIxLjgiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIgc3Ryb2tlLWxpbmVqb2luPSJyb3VuZCI+PHBhdGggZD0iTTEyIDE5VjZNNyAx
;MGw1LTUgNSA1Ii8+PC9zdmc+PC9zcGFuPjxzcGFuIGNsYXNzPSJjYWN0LWxhYmVsIj7kuIrnp7s8L3NwYW4+PC9idXR0b24+CiAgICAgIDxidXR0b24gdHlw
;ZT0iYnV0dG9uIiBkYXRhLWNhY3Q9ImRvd24iPjxzcGFuIGNsYXNzPSJjLWljbyIgYXJpYS1oaWRkZW49InRydWUiPjxzdmcgdmlld0JveD0iMCAwIDI0IDI0
;IiBmaWxsPSJub25lIiBzdHJva2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIxLjgiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIgc3Ryb2tlLWxpbmVq
;b2luPSJyb3VuZCI+PHBhdGggZD0iTTEyIDV2MTNNNyAxNGw1IDUgNS01Ii8+PC9zdmc+PC9zcGFuPjxzcGFuIGNsYXNzPSJjYWN0LWxhYmVsIj7kuIvnp7s8
;L3NwYW4+PC9idXR0b24+CiAgICAgIDxocj4KICAgICAgPGJ1dHRvbiB0eXBlPSJidXR0b24iIGRhdGEtY2FjdD0iZGVsIiBjbGFzcz0iZGFuZ2VyIj48c3Bh
;biBjbGFzcz0iYy1pY28iIGFyaWEtaGlkZGVuPSJ0cnVlIj48c3ZnIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSJjdXJyZW50Q29s
;b3IiIHN0cm9rZS13aWR0aD0iMS44IiBzdHJva2UtbGluZWNhcD0icm91bmQiIHN0cm9rZS1saW5lam9pbj0icm91bmQiPjxwYXRoIGQ9Ik01IDhoMTQiLz48
;cGF0aCBkPSJNOSA4VjYuNUExLjUgMS41IDAgMCAxIDEwLjUgNWgzQTEuNSAxLjUgMCAwIDEgMTUgNi41VjgiLz48cGF0aCBkPSJNNy41IDhsLjcgMTFhMS41
;IDEuNSAwIDAgMCAxLjUgMS40aDQuNmExLjUgMS41IDAgMCAwIDEuNS0xLjRsLjctMTEiLz48L3N2Zz48L3NwYW4+PHNwYW4gY2xhc3M9ImNhY3QtbGFiZWwi
;PuWIoOmZpDwvc3Bhbj48L2J1dHRvbj4KICAgIDwvZGl2PgogIDxkaXYgaWQ9ImN0eCIgcm9sZT0ibWVudSI+CiAgICA8YnV0dG9uIHR5cGU9ImJ1dHRvbiIg
;ZGF0YS1hY3Q9InJldmVhbCI+PHNwYW4gY2xhc3M9ImMtaWNvIj48c3ZnIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSJjdXJyZW50
;Q29sb3IiIHN0cm9rZS13aWR0aD0iMS44Ij48cGF0aCBkPSJNMyA3LjVBMS41IDEuNSAwIDAgMSA0LjUgNkg5bDIgMmg4LjVBMS41IDEuNSAwIDAgMSAyMSA5
;LjV2N0ExLjUgMS41IDAgMCAxIDE5LjUgMThoLTE1QTEuNSAxLjUgMCAwIDEgMyAxNi41di05eiIvPjwvc3ZnPjwvc3Bhbj7mlofku7blpLnkuK3mmL7npLo8
;L2J1dHRvbj4KICAgIDxidXR0b24gdHlwZT0iYnV0dG9uIiBkYXRhLWFjdD0iY29weSI+PHNwYW4gY2xhc3M9ImMtaWNvIj48c3ZnIHZpZXdCb3g9IjAgMCAy
;NCAyNCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0cm9rZS13aWR0aD0iMS44Ij48cmVjdCB4PSI4IiB5PSI4IiB3aWR0aD0iMTEiIGhl
;aWdodD0iMTEiIHJ4PSIxLjUiLz48cGF0aCBkPSJNNSAxNVY1LjVBMS41IDEuNSAwIDAgMSA2LjUgNEgxNSIvPjwvc3ZnPjwvc3Bhbj7lpI3liLY8L2J1dHRv
;bj4KICAgIDxidXR0b24gdHlwZT0iYnV0dG9uIiBkYXRhLWFjdD0iY29weVBhdGgiPjxzcGFuIGNsYXNzPSJjLWljbyI+PHN2ZyB2aWV3Qm94PSIwIDAgMjQg
;MjQiIGZpbGw9Im5vbmUiIHN0cm9rZT0iY3VycmVudENvbG9yIiBzdHJva2Utd2lkdGg9IjEuOCI+PHBhdGggZD0iTTggMTJoOCIvPjxwYXRoIGQ9Ik0xMCA3
;SDcuNUEyLjUgMi41IDAgMCAwIDUgOS41djVBMi41IDIuNSAwIDAgMCA3LjUgMTdIMTAiLz48cGF0aCBkPSJNMTQgN2gyLjVBMi41IDIuNSAwIDAgMSAxOSA5
;LjV2NUEyLjUgMi41IDAgMCAxIDE2LjUgMTdIMTQiLz48L3N2Zz48L3NwYW4+5aSN5Yi26Lev5b6EPC9idXR0b24+CiAgICA8YnV0dG9uIHR5cGU9ImJ1dHRv
;biIgZGF0YS1hY3Q9ImNvcHlEaXIiPjxzcGFuIGNsYXNzPSJjLWljbyI+PHN2ZyB2aWV3Qm94PSIwIDAgMjQgMjQiIGZpbGw9Im5vbmUiIHN0cm9rZT0iY3Vy
;cmVudENvbG9yIiBzdHJva2Utd2lkdGg9IjEuOCI+PHBhdGggZD0iTTkgOC41YTMuNSAzLjUgMCAwIDEgNS42LTIuOGwxLjcgMS40YTMuNSAzLjUgMCAwIDEt
;Mi4yIDYuMkgxMyIvPjxwYXRoIGQ9Ik0xNSAxNS41YTMuNSAzLjUgMCAwIDEtNS42IDIuOGwtMS43LTEuNGEzLjUgMy41IDAgMCAxIDIuMi02LjJIMTEiLz48
;L3N2Zz48L3NwYW4+5aSN5Yi25omA5Zyo6Lev5b6EPC9idXR0b24+CiAgICA8YnV0dG9uIHR5cGU9ImJ1dHRvbiIgZGF0YS1hY3Q9InJlY3ljbGUiIGNsYXNz
;PSJkYW5nZXIiPjxzcGFuIGNsYXNzPSJjLWljbyI+PHN2ZyB2aWV3Qm94PSIwIDAgMjQgMjQiIGZpbGw9Im5vbmUiIHN0cm9rZT0iY3VycmVudENvbG9yIiBz
;dHJva2Utd2lkdGg9IjEuOCI+PHBhdGggZD0iTTUgOGgxNCIvPjxwYXRoIGQ9Ik05IDhWNi41QTEuNSAxLjUgMCAwIDEgMTAuNSA1aDNBMS41IDEuNSAwIDAg
;MSAxNSA2LjVWOCIvPjxwYXRoIGQ9Ik03LjUgOGwuNyAxMWExLjUgMS41IDAgMCAwIDEuNSAxLjRoNC42YTEuNSAxLjUgMCAwIDAgMS41LTEuNGwuNy0xMSIv
;Pjwvc3ZnPjwvc3Bhbj7liKDpmaQo5Zue5pS256uZKTwvYnV0dG9uPgogIDwvZGl2Pgo8L2Rpdj4KPHNjcmlwdD4KKCgpID0+IHsKICAvLyDlhajlsYDlsY/o
;lL3mtY/op4jlmajpu5jorqTlj7PplK7oj5zljZXvvJvpobXpnaLlhoXoh6rlrprkuYnoj5zljZXoh6rooYwgcHJldmVudERlZmF1bHQg5ZCO5by55Ye6CiAg
;ZG9jdW1lbnQuYWRkRXZlbnRMaXN0ZW5lcignY29udGV4dG1lbnUnLCAoZSkgPT4geyBlLnByZXZlbnREZWZhdWx0KCk7IH0sIHRydWUpOwogIGNvbnN0IGJv
;b3QgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYm9vdCcpOwogIGNvbnN0IGNocm9tZSA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjaHJvbWUnKTsK
;ICBjb25zdCBhcHBSb290ID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2FwcCcpOwogIGNvbnN0IHRpdGxlYmFyID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5
;SWQoJ3RpdGxlYmFyJyk7CiAgY29uc3QgcmluZ0ZnID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3JpbmctZmcnKTsKICBjb25zdCBib290UGN0ID0gZG9j
;dW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2Jvb3QtcGN0Jyk7CiAgY29uc3QgcUVsID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3EnKTsKICBjb25zdCBsaXN0
;RWwgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbGlzdCcpOwogIGNvbnN0IGVtcHR5RWwgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbGlzdC1lbXB0
;eScpOwogIGNvbnN0IGNvdW50RWwgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnY291bnQnKTsKICBjb25zdCBwdk1ldGEgPSBkb2N1bWVudC5nZXRFbGVt
;ZW50QnlJZCgncHYtbWV0YScpOwogIGNvbnN0IHB2TWVkaWEgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgncHYtbWVkaWEnKTsKICBjb25zdCBwdlRleHQg
;PSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgncHYtdGV4dCcpOwogIGNvbnN0IHB2Qm9keSA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdwdi1ib2R5Jyk7
;CiAgY29uc3QgcHZQcmUgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgncHYtcHJlJyk7CiAgY29uc3QgcHZUZXh0SGQgPSBkb2N1bWVudC5nZXRFbGVtZW50
;QnlJZCgncHYtdGV4dC1oZCcpOwogIGNvbnN0IHByZXZpZXcgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgncHJldmlldycpOwogIGNvbnN0IGNoa1ByZXZp
;ZXcgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnY2hrLXByZXZpZXcnKTsKICBjb25zdCBzb3J0TGFiZWwgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgn
;c29ydC1sYWJlbCcpOwogIGNvbnN0IENJUkMgPSAyICogTWF0aC5QSSAqIDUyOwoKICBsZXQgY2F0ID0gJ2FsbCc7CiAgbGV0IGFwcE1vZGUgPSAnZmlsZSc7
;IC8vIGZpbGUgfCBoYW5kbGUgfCBpbmZvIHwgY29uZmlnCiAgY29uc3QgUExBQ0VIT0xERVJfRklMRSA9ICfovpPlhaXmlofku7blkI0gLyDmianlsZXlkI0g
;LyDot6/lvoTlhbPplK7lrZfvvJt8IOihqOekuuS4lO+8jHx8IOihqOekuuaIlic7CiAgY29uc3QgUExBQ0VIT0xERVJfSEFORExFID0gJ+aWh+S7tuWPpeaf
;hOWFs+mUruWtl++8jOaIluerr+WPoyA4MDgwfDgw44CBMC0zMDB8NTAwJzsKICBjb25zdCBQTEFDRUhPTERFUl9JTkZPID0gJ+acrOacuuS/oeaBr+aXoOmc
;gOWFs+mUruWtl++8jOeCueW3puS+p+WNs+WPr+afpeeciyc7CiAgY29uc3QgUExBQ0VIT0xERVJfQ09ORklHID0gJ+i/kOihjOmFjee9ru+8muWPr+aQnOe0
;oiBrZXkgLyB2YWx1ZSc7CiAgLy8g5pys5Zyw5pCc57SiIC8g5Y+l5p+E5pCc57Si5ZCE6Ieq5L+d55WZ6L6T5YWl5p2h5Lu277yM5LqS5LiN5Liy5Y+wCiAg
;Y29uc3QgbW9kZVF1ZXJ5ID0geyBmaWxlOiAnJywgaGFuZGxlOiAnJywgaW5mbzogJycsIGNvbmZpZzogJycgfTsKICBsZXQgY2ZnQWN0aXZlVGFiID0gJ3J1
;bmNvbmZpZyc7CiAgbGV0IHNvcnQgPSAnZGF0ZS1kZXNjJzsKICBsZXQgZHJpdmUgPSAnJzsgLy8gJycgPSBhbGwgZGlza3MsICdDJyAvICdEJyAvIC4uLgog
;IGxldCBpdGVtcyA9IFtdOwogIGxldCBzZWxlY3RlZCA9IC0xOwogIGxldCB0ZXh0U2VhcmNoT24gPSBmYWxzZTsgLy8g44CM5pCc57Si5paH5pys44CN77ya
;5oyJIGNvbnRlbnQ6IOaQnOaWh+S7tuWGheWuuQogIGxldCBzZWFyY2hUaW1lciA9IDA7CiAgbGV0IGdlbiA9IDA7CiAgbGV0IHRvdGFsSGl0cyA9IDA7CiAg
;bGV0IGxvYWRpbmdNb3JlID0gZmFsc2U7CiAgbGV0IGhhc01vcmUgPSBmYWxzZTsKCiAgY29uc3QgZHJpdmVMYWJlbCA9IGRvY3VtZW50LmdldEVsZW1lbnRC
;eUlkKCdkcml2ZS1sYWJlbCcpOwogIGNvbnN0IGRyaXZlTWVudSA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdkcml2ZS1tZW51Jyk7CiAgY29uc3QgYnRu
;RHJpdmUgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYnRuLWRyaXZlJyk7CiAgY29uc3QgZHJpdmVCdG5JY28gPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJ
;ZCgnZHJpdmUtYnRuLWljbycpOwogIGxldCBkcml2ZU1ldGEgPSB7IGNvbXB1dGVyOiAnJywgZHJpdmVzOiBbXSB9OwoKICBmdW5jdGlvbiBkcml2ZVRleHQo
;KSB7CiAgICBpZiAoIWRyaXZlKSByZXR1cm4gJ+WFqOebmOaQnOe0oic7CiAgICBjb25zdCBoaXQgPSAoZHJpdmVNZXRhLmRyaXZlcyB8fCBbXSkuZmluZChk
;ID0+IFN0cmluZyhkLmxldHRlciB8fCAnJykudG9VcHBlckNhc2UoKSA9PT0gZHJpdmUpOwogICAgaWYgKGhpdCAmJiBoaXQubGFiZWwpIHJldHVybiBoaXQu
;bGFiZWw7CiAgICByZXR1cm4gZHJpdmUudG9VcHBlckNhc2UoKSArICcg55uYJzsKICB9CiAgZnVuY3Rpb24gc2V0QnRuSWNvbih1cmwpIHsKICAgIGlmICh1
;cmwpIHsKICAgICAgZHJpdmVCdG5JY28uc3JjID0gdXJsICsgKHVybC5pbmNsdWRlcygnPycpID8gJyYnIDogJz8nKSArICd0PScgKyBEYXRlLm5vdygpOwog
;ICAgICBkcml2ZUJ0bkljby5jbGFzc0xpc3QucmVtb3ZlKCdoaWRkZW4nKTsKICAgIH0gZWxzZSB7CiAgICAgIGRyaXZlQnRuSWNvLnJlbW92ZUF0dHJpYnV0
;ZSgnc3JjJyk7CiAgICAgIGRyaXZlQnRuSWNvLmNsYXNzTGlzdC5hZGQoJ2hpZGRlbicpOwogICAgfQogIH0KICBmdW5jdGlvbiBzeW5jRHJpdmVCdXR0b24o
;KSB7CiAgICBkcml2ZUxhYmVsLnRleHRDb250ZW50ID0gZHJpdmVUZXh0KCk7CiAgICBpZiAoIWRyaXZlKSBzZXRCdG5JY29uKGRyaXZlTWV0YS5jb21wdXRl
;ciB8fCAnJyk7CiAgICBlbHNlIHsKICAgICAgY29uc3QgaGl0ID0gKGRyaXZlTWV0YS5kcml2ZXMgfHwgW10pLmZpbmQoZCA9PiBTdHJpbmcoZC5sZXR0ZXIg
;fHwgJycpLnRvVXBwZXJDYXNlKCkgPT09IGRyaXZlKTsKICAgICAgc2V0QnRuSWNvbigoaGl0ICYmIGhpdC5pY29uKSB8fCBkcml2ZU1ldGEuY29tcHV0ZXIg
;fHwgJycpOwogICAgfQogIH0KICBmdW5jdGlvbiBpY29IdG1sKHVybCkgewogICAgcmV0dXJuIHVybCA/ICc8aW1nIHNyYz0iJyArIFN0cmluZyh1cmwpLnJl
;cGxhY2UoLyIvZywgJycpICsgJyIgYWx0PSIiPicgOiAnJzsKICB9CiAgZnVuY3Rpb24gcmVuZGVyRHJpdmVNZW51KCkgewogICAgY29uc3QgZHJpdmVzID0g
;QXJyYXkuaXNBcnJheShkcml2ZU1ldGEuZHJpdmVzKSA/IGRyaXZlTWV0YS5kcml2ZXMgOiBbXTsKICAgIGxldCBodG1sID0gJzxidXR0b24gdHlwZT0iYnV0
;dG9uIiBkYXRhLWRyaXZlPSIiJyArICghZHJpdmUgPyAnIGNsYXNzPSJvbiInIDogJycpICsgJz4nCiAgICAgICsgaWNvSHRtbChkcml2ZU1ldGEuY29tcHV0
;ZXIpICsgJzxzcGFuPuWFqOebmOaQnOe0ojwvc3Bhbj48L2J1dHRvbj4nOwogICAgZm9yIChjb25zdCBkIG9mIGRyaXZlcykgewogICAgICBjb25zdCBsZXR0
;ZXIgPSBTdHJpbmcoZC5sZXR0ZXIgfHwgZCB8fCAnJykucmVwbGFjZSgvOiQvLCAnJykudG9VcHBlckNhc2UoKTsKICAgICAgaWYgKCFsZXR0ZXIpIGNvbnRp
;bnVlOwogICAgICBjb25zdCBsYWJlbCA9IGQubGFiZWwgfHwgKGxldHRlciArICcg55uYJyk7CiAgICAgIGh0bWwgKz0gJzxidXR0b24gdHlwZT0iYnV0dG9u
;IiBkYXRhLWRyaXZlPSInICsgbGV0dGVyICsgJyInCiAgICAgICAgKyAoZHJpdmUgPT09IGxldHRlciA/ICcgY2xhc3M9Im9uIicgOiAnJykgKyAnPicKICAg
;ICAgICArIGljb0h0bWwoZC5pY29uIHx8ICcnKSArICc8c3Bhbj4nICsgbGFiZWwgKyAnPC9zcGFuPjwvYnV0dG9uPic7CiAgICB9CiAgICBkcml2ZU1lbnUu
;aW5uZXJIVE1MID0gaHRtbDsKICAgIGRyaXZlTWVudS5xdWVyeVNlbGVjdG9yQWxsKCdidXR0b24nKS5mb3JFYWNoKGJ0biA9PiB7CiAgICAgIGJ0bi5vbmNs
;aWNrID0gKGUpID0+IHsKICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgICAgIGRyaXZlID0gYnRuLmdldEF0dHJpYnV0ZSgnZGF0YS1kcml2ZScp
;IHx8ICcnOwogICAgICAgIGRyaXZlTWVudS5jbGFzc0xpc3QucmVtb3ZlKCdvbicpOwogICAgICAgIHN5bmNEcml2ZUJ1dHRvbigpOwogICAgICAgIHJlbmRl
;ckRyaXZlTWVudSgpOwogICAgICAgIGRvU2VhcmNoKCk7CiAgICAgICAgaWYgKHR5cGVvZiBzYXZlU2Vzc2lvblNvb24gPT09ICdmdW5jdGlvbicpIHNhdmVT
;ZXNzaW9uU29vbigpOwogICAgICB9OwogICAgfSk7CiAgfQogIHdpbmRvdy5fX3NldERyaXZlcyA9IChwYXlsb2FkKSA9PiB7CiAgICB0cnkgewogICAgICBj
;b25zdCBkYXRhID0gdHlwZW9mIHBheWxvYWQgPT09ICdzdHJpbmcnID8gSlNPTi5wYXJzZShwYXlsb2FkKSA6IHBheWxvYWQ7CiAgICAgIGlmIChBcnJheS5p
;c0FycmF5KGRhdGEpKSB7CiAgICAgICAgZHJpdmVNZXRhID0gewogICAgICAgICAgY29tcHV0ZXI6ICcnLAogICAgICAgICAgZHJpdmVzOiBkYXRhLm1hcCh4
;ID0+IHR5cGVvZiB4ID09PSAnc3RyaW5nJwogICAgICAgICAgICA/ICh7IGxldHRlcjogeCwgaWNvbjogJycsIGxhYmVsOiBTdHJpbmcoeCkudG9VcHBlckNh
;c2UoKSArICcg55uYJyB9KQogICAgICAgICAgICA6IHgpCiAgICAgICAgfTsKICAgICAgfSBlbHNlIHsKICAgICAgICBkcml2ZU1ldGEgPSB7CiAgICAgICAg
;ICBjb21wdXRlcjogKGRhdGEgJiYgZGF0YS5jb21wdXRlcikgfHwgJycsCiAgICAgICAgICBkcml2ZXM6IEFycmF5LmlzQXJyYXkoZGF0YSAmJiBkYXRhLmRy
;aXZlcykgPyBkYXRhLmRyaXZlcyA6IFtdCiAgICAgICAgfTsKICAgICAgfQogICAgICBzeW5jRHJpdmVCdXR0b24oKTsKICAgICAgcmVuZGVyRHJpdmVNZW51
;KCk7CiAgICB9IGNhdGNoIChlKSB7IGNvbnNvbGUud2Fybignc2V0RHJpdmVzJywgZSk7IH0KICB9OwoKICBjb25zdCBISVNUX0tFWSA9ICdsb2NhbF9zZWFy
;Y2hfaGlzdF92MSc7CiAgY29uc3QgQ09ORklHX0hJU1RfS0VZID0gJ2xvY2FsX3NlYXJjaF9jb25maWdfaGlzdF92MSc7CiAgY29uc3QgSElTVF9NQVggPSAx
;MDsKICBjb25zdCBzZWFyY2hCb3ggPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc2VhcmNoLWJveCcpOwogIGNvbnN0IGhpc3RNZW51ID0gZG9jdW1lbnQu
;Z2V0RWxlbWVudEJ5SWQoJ2hpc3QtbWVudScpOwogIGNvbnN0IGJ0bkhpc3QgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYnRuLWhpc3QnKTsKICBjb25z
;dCBidG5DbGVhciA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdidG4tY2xlYXInKTsKICBjb25zdCBzZWFyY2hJY28gPSBkb2N1bWVudC5nZXRFbGVtZW50
;QnlJZCgnc2VhcmNoLWljbycpOwogIGxldCBoaXN0SWRsZVRpbWVyID0gMDsKCiAgZnVuY3Rpb24gc2V0SGlzdENocm9tZShvbikgewogICAgc2VhcmNoQm94
;LmNsYXNzTGlzdC50b2dnbGUoJ2hpc3Qtb3BlbicsICEhb24pOwogICAgaGlzdE1lbnUuY2xhc3NMaXN0LnRvZ2dsZSgnb24nLCAhIW9uKTsKICAgIGlmIChz
;ZWFyY2hJY28pIHNlYXJjaEljby5jbGFzc0xpc3QudG9nZ2xlKCdvbicsICEhb24pOwogICAgaWYgKGJ0bkhpc3QpIGJ0bkhpc3QuY2xhc3NMaXN0LnRvZ2ds
;ZSgnb24nLCAhIW9uKTsKICB9CgogIGZ1bmN0aW9uIHN5bmNDbGVhckJ0bigpIHsKICAgIGJ0bkNsZWFyLmNsYXNzTGlzdC50b2dnbGUoJ29uJywgISEocUVs
;LnZhbHVlIHx8ICcnKS50cmltKCkpOwogICAgaWYgKHR5cGVvZiBzeW5jRmlsZVNlYXJjaENsZWFyUGlsbCA9PT0gJ2Z1bmN0aW9uJykgc3luY0ZpbGVTZWFy
;Y2hDbGVhclBpbGwoKTsKICB9CiAgZnVuY3Rpb24gY2xlYXJTZWFyY2goKSB7CiAgICBjbGVhclRpbWVvdXQoaGlzdElkbGVUaW1lcik7CiAgICBxRWwudmFs
;dWUgPSAnJzsKICAgIGlmIChhcHBNb2RlID09PSAnZmlsZScpIG1vZGVRdWVyeS5maWxlID0gJyc7CiAgICBlbHNlIGlmIChhcHBNb2RlID09PSAnaGFuZGxl
;JykgbW9kZVF1ZXJ5LmhhbmRsZSA9ICcnOwogICAgZWxzZSBpZiAoYXBwTW9kZSA9PT0gJ2luZm8nKSBtb2RlUXVlcnkuaW5mbyA9ICcnOwogICAgZWxzZSBp
;ZiAoYXBwTW9kZSA9PT0gJ2NvbmZpZycpIG1vZGVRdWVyeS5jb25maWcgPSAnJzsKICAgIHN5bmNDbGVhckJ0bigpOwogICAgc2V0SGlzdENocm9tZShmYWxz
;ZSk7CiAgICBxRWwuZm9jdXMoKTsKICAgIGlmIChhcHBNb2RlID09PSAnaGFuZGxlJykgewogICAgICAvLyDmuIXnqbrmnaHku7blkI7ku43mmL7npLrlhajp
;g6jov57mjqXvvIjkuI3mioogMC02NTUzNSDlhpnlm57ovpPlhaXmoYbvvIkKICAgICAgaWYgKGFjdGl2ZUhhbmRsZVRhZ0lkcyAmJiBhY3RpdmVIYW5kbGVU
;YWdJZHMuc2l6ZSkgewogICAgICAgIGFjdGl2ZUhhbmRsZVRhZ0lkcy5jbGVhcigpOwogICAgICAgIHNhdmVBY3RpdmVIYW5kbGVUYWdzKCk7CiAgICAgICAg
;cmVuZGVySGFuZGxlVGFnQmFyKCk7CiAgICAgIH0KICAgICAgcmVxdWVzdEhhbmRsZVNlYXJjaChjb21wb3NlSGFuZGxlU2VhcmNoUXVlcnkoKSk7CiAgICAg
;IHRyeSB7IHN5bmNGaWxlU2VhcmNoQ2xlYXJQaWxsKDApOyB9IGNhdGNoIChfKSB7fQogICAgICByZXR1cm47CiAgICB9CiAgICBpZiAoYXBwTW9kZSA9PT0g
;J2luZm8nKSByZXR1cm47CiAgICBpZiAoYXBwTW9kZSA9PT0gJ2NvbmZpZycpIHsKICAgICAgaWYgKHR5cGVvZiBjbGVhckNmZ1NlYXJjaCA9PT0gJ2Z1bmN0
;aW9uJykgY2xlYXJDZmdTZWFyY2goKTsKICAgICAgZWxzZSBpZiAodHlwZW9mIGFwcGx5Q29uZmlnU2VhcmNoID09PSAnZnVuY3Rpb24nKSBhcHBseUNvbmZp
;Z1NlYXJjaCgnJyk7CiAgICAgIHJldHVybjsKICAgIH0KICAgIGRvU2VhcmNoKCk7CiAgfQogIGJ0bkNsZWFyLm9uY2xpY2sgPSAoZSkgPT4gewogICAgZS5z
;dG9wUHJvcGFnYXRpb24oKTsKICAgIGNsZWFyU2VhcmNoKCk7CiAgfTsKICBjb25zdCBzZWFyY2hDbGVhclBpbGwgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJ
;ZCgnY2ZnLXNlYXJjaC1jbGVhcicpOwogIGlmIChzZWFyY2hDbGVhclBpbGwgJiYgIXNlYXJjaENsZWFyUGlsbC5kYXRhc2V0LmJvdW5kKSB7CiAgICBzZWFy
;Y2hDbGVhclBpbGwuZGF0YXNldC5ib3VuZCA9ICcxJzsKICAgIHNlYXJjaENsZWFyUGlsbC5hZGRFdmVudExpc3RlbmVyKCdjbGljaycsIChlKSA9PiB7CiAg
;ICAgIGUucHJldmVudERlZmF1bHQoKTsKICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgaWYgKGFwcE1vZGUgPT09ICdjb25maWcnKSB7CiAgICAg
;ICAgaWYgKHR5cGVvZiBjbGVhckNmZ1NlYXJjaCA9PT0gJ2Z1bmN0aW9uJykgY2xlYXJDZmdTZWFyY2goKTsKICAgICAgfSBlbHNlIGlmIChhcHBNb2RlID09
;PSAnaGFuZGxlJykgewogICAgICAgIGNsZWFySGFuZGxlU2VhcmNoQWxsKCk7CiAgICAgIH0gZWxzZSBpZiAoYXBwTW9kZSA9PT0gJ2ZpbGUnKSB7CiAgICAg
;ICAgY2xlYXJGaWxlU2VhcmNoQWxsKCk7CiAgICAgIH0KICAgICAgdHJ5IHsgcUVsLmZvY3VzKCk7IH0gY2F0Y2ggKF8pIHt9CiAgICB9KTsKICB9CgogIGZ1
;bmN0aW9uIGxvYWRIaXN0KCkgewogICAgdHJ5IHsKICAgICAgY29uc3Qga2V5ID0gKHR5cGVvZiBhcHBNb2RlICE9PSAndW5kZWZpbmVkJyAmJiBhcHBNb2Rl
;ID09PSAnY29uZmlnJykgPyBDT05GSUdfSElTVF9LRVkgOiBISVNUX0tFWTsKICAgICAgY29uc3QgcmF3ID0gbG9jYWxTdG9yYWdlLmdldEl0ZW0oa2V5KTsK
;ICAgICAgY29uc3QgYXJyID0gcmF3ID8gSlNPTi5wYXJzZShyYXcpIDogW107CiAgICAgIHJldHVybiBBcnJheS5pc0FycmF5KGFycikgPyBhcnIubWFwKHgg
;PT4gU3RyaW5nKHggfHwgJycpLnRyaW0oKSkuZmlsdGVyKEJvb2xlYW4pLnNsaWNlKDAsIEhJU1RfTUFYKSA6IFtdOwogICAgfSBjYXRjaCAoXykgeyByZXR1
;cm4gW107IH0KICB9CiAgZnVuY3Rpb24gc2F2ZUhpc3QobGlzdCkgewogICAgdHJ5IHsKICAgICAgY29uc3Qga2V5ID0gKHR5cGVvZiBhcHBNb2RlICE9PSAn
;dW5kZWZpbmVkJyAmJiBhcHBNb2RlID09PSAnY29uZmlnJykgPyBDT05GSUdfSElTVF9LRVkgOiBISVNUX0tFWTsKICAgICAgbG9jYWxTdG9yYWdlLnNldEl0
;ZW0oa2V5LCBKU09OLnN0cmluZ2lmeShsaXN0LnNsaWNlKDAsIEhJU1RfTUFYKSkpOwogICAgfSBjYXRjaCAoXykge30KICB9CiAgZnVuY3Rpb24gcHVzaEhp
;c3QocSkgewogICAgcSA9IFN0cmluZyhxIHx8ICcnKS50cmltKCk7CiAgICBpZiAoIXEpIHJldHVybjsKICAgIGlmICh0eXBlb2YgYXBwTW9kZSAhPT0gJ3Vu
;ZGVmaW5lZCcgJiYgYXBwTW9kZSA9PT0gJ2luZm8nKSByZXR1cm47CiAgICBpZiAodHlwZW9mIGFwcE1vZGUgIT09ICd1bmRlZmluZWQnICYmIGFwcE1vZGUg
;PT09ICdoYW5kbGUnKSB7CiAgICAgIGlmICh0eXBlb2Ygc2F2ZUhhbmRsZUhpc3QgPT09ICdmdW5jdGlvbicpIHNhdmVIYW5kbGVIaXN0KHEpOwogICAgICBp
;ZiAoaGlzdE1lbnUuY2xhc3NMaXN0LmNvbnRhaW5zKCdvbicpKSByZW5kZXJIaXN0TWVudSgpOwogICAgICByZXR1cm47CiAgICB9CiAgICBjb25zdCBsaXN0
;ID0gbG9hZEhpc3QoKS5maWx0ZXIoeCA9PiB4ICE9PSBxKTsKICAgIGxpc3QudW5zaGlmdChxKTsKICAgIHNhdmVIaXN0KGxpc3QpOwogICAgaWYgKGhpc3RN
;ZW51LmNsYXNzTGlzdC5jb250YWlucygnb24nKSkgcmVuZGVySGlzdE1lbnUoKTsKICB9CiAgZnVuY3Rpb24gZXNjYXBlQXR0cihzKSB7CiAgICByZXR1cm4g
;U3RyaW5nKHMgfHwgJycpLnJlcGxhY2UoLyYvZywgJyZhbXA7JykucmVwbGFjZSgvIi9nLCAnJnF1b3Q7JykucmVwbGFjZSgvPC9nLCAnJmx0OycpOwogIH0K
;ICBjb25zdCBISVNUX0lDT19TVkcgPSAnPHN2ZyBjbGFzcz0iaGlzdC1pY28iIHZpZXdCb3g9IjAgMCAxNiAxNiIgZmlsbD0ibm9uZSIgYXJpYS1oaWRkZW49
;InRydWUiPicKICAgICsgJzxjaXJjbGUgY3g9IjciIGN5PSI3IiByPSI0LjI1IiBzdHJva2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIxLjQiLz4n
;CiAgICArICc8cGF0aCBkPSJNMTAuMiAxMC4yTDEzLjQgMTMuNCIgc3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0cm9rZS13aWR0aD0iMS40IiBzdHJva2UtbGlu
;ZWNhcD0icm91bmQiLz4nCiAgICArICc8L3N2Zz4nOwogIGZ1bmN0aW9uIHJlbmRlckhpc3RNZW51KCkgewogICAgY29uc3QgaGFuZGxlTW9kZSA9IHR5cGVv
;ZiBhcHBNb2RlICE9PSAndW5kZWZpbmVkJyAmJiBhcHBNb2RlID09PSAnaGFuZGxlJzsKICAgIGNvbnN0IGNvbmZpZ01vZGUgPSB0eXBlb2YgYXBwTW9kZSAh
;PT0gJ3VuZGVmaW5lZCcgJiYgYXBwTW9kZSA9PT0gJ2NvbmZpZyc7CiAgICBjb25zdCBsaXN0ID0gaGFuZGxlTW9kZSAmJiB0eXBlb2YgbG9hZEhhbmRsZUhp
;c3QgPT09ICdmdW5jdGlvbicgPyBsb2FkSGFuZGxlSGlzdCgpIDogbG9hZEhpc3QoKTsKICAgIGlmICghbGlzdC5sZW5ndGgpIHsKICAgICAgY29uc3QgZW1w
;dHkgPSBoYW5kbGVNb2RlID8gJ+aaguaXoOWPpeafhC/nq6/lj6PmkJzntKLorrDlvZUnCiAgICAgICAgOiAoY29uZmlnTW9kZSA/ICfmmoLml6DphY3nva7m
;kJzntKLorrDlvZUnIDogJ+aaguaXoOacgOi/keaQnOe0oicpOwogICAgICBoaXN0TWVudS5pbm5lckhUTUwgPSAnPGRpdiBjbGFzcz0iaGlzdC1lbXB0eSI+
;JyArIGVtcHR5ICsgJzwvZGl2Pic7CiAgICAgIHJldHVybjsKICAgIH0KICAgIGhpc3RNZW51LmlubmVySFRNTCA9IGxpc3QubWFwKHEgPT4KICAgICAgJzxi
;dXR0b24gdHlwZT0iYnV0dG9uIiBkYXRhLXE9IicgKyBlc2NhcGVBdHRyKHEpICsgJyIgdGl0bGU9IicgKyBlc2NhcGVBdHRyKHEpICsgJyI+JwogICAgICAr
;IEhJU1RfSUNPX1NWRyArICc8c3BhbiBjbGFzcz0iaGlzdC10eHQiPicgKyBlc2NhcGVBdHRyKHEpICsgJzwvc3Bhbj48L2J1dHRvbj4nCiAgICApLmpvaW4o
;JycpOwogICAgaGlzdE1lbnUucXVlcnlTZWxlY3RvckFsbCgnYnV0dG9uJykuZm9yRWFjaChidG4gPT4gewogICAgICBidG4ub25jbGljayA9IChlKSA9PiB7
;CiAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICBjb25zdCBxID0gYnRuLmdldEF0dHJpYnV0ZSgnZGF0YS1xJykgfHwgJyc7CiAgICAgICAg
;Y2xvc2VIaXN0TWVudSgpOwogICAgICAgIHFFbC52YWx1ZSA9IHE7CiAgICAgICAgaWYgKGFwcE1vZGUgPT09ICdmaWxlJykgbW9kZVF1ZXJ5LmZpbGUgPSBx
;OwogICAgICAgIGVsc2UgaWYgKGFwcE1vZGUgPT09ICdoYW5kbGUnKSBtb2RlUXVlcnkuaGFuZGxlID0gcTsKICAgICAgICBlbHNlIGlmIChhcHBNb2RlID09
;PSAnY29uZmlnJykgbW9kZVF1ZXJ5LmNvbmZpZyA9IHE7CiAgICAgICAgcHVzaEhpc3QocSk7CiAgICAgICAgc3luY0NsZWFyQnRuKCk7CiAgICAgICAgaWYg
;KGFwcE1vZGUgPT09ICdjb25maWcnKSB7CiAgICAgICAgICBpZiAodHlwZW9mIGFwcGx5Q29uZmlnU2VhcmNoID09PSAnZnVuY3Rpb24nKSBhcHBseUNvbmZp
;Z1NlYXJjaChxKTsKICAgICAgICB9IGVsc2UgewogICAgICAgICAgZG9TZWFyY2goKTsKICAgICAgICB9CiAgICAgIH07CiAgICB9KTsKICB9CiAgYnRuRHJp
;dmUub25jbGljayA9IChlKSA9PiB7CiAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgY2xvc2VIaXN0TWVudSgpOwogICAgZHJpdmVNZW51LmNsYXNzTGlz
;dC50b2dnbGUoJ29uJyk7CiAgfTsKICBmdW5jdGlvbiBjbG9zZUhpc3RNZW51KCkgewogICAgc2V0SGlzdENocm9tZShmYWxzZSk7CiAgfQogIGZ1bmN0aW9u
;IG9wZW5IaXN0TWVudSgpIHsKICAgIGlmIChhcHBNb2RlID09PSAnaW5mbycpIHJldHVybjsKICAgIGRyaXZlTWVudS5jbGFzc0xpc3QucmVtb3ZlKCdvbicp
;OwogICAgcmVuZGVySGlzdE1lbnUoKTsKICAgIHNldEhpc3RDaHJvbWUodHJ1ZSk7CiAgfQogIGZ1bmN0aW9uIHRvZ2dsZUhpc3RNZW51KGUpIHsKICAgIGlm
;IChlKSBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgaWYgKGFwcE1vZGUgPT09ICdpbmZvJykgcmV0dXJuOwogICAgaWYgKGhpc3RNZW51LmNsYXNzTGlzdC5j
;b250YWlucygnb24nKSkgY2xvc2VIaXN0TWVudSgpOwogICAgZWxzZSBvcGVuSGlzdE1lbnUoKTsKICB9CiAgaWYgKHNlYXJjaEljbykgc2VhcmNoSWNvLmFk
;ZEV2ZW50TGlzdGVuZXIoJ2NsaWNrJywgdG9nZ2xlSGlzdE1lbnUpOwogIGlmIChidG5IaXN0KSBidG5IaXN0Lm9uY2xpY2sgPSB0b2dnbGVIaXN0TWVudTsK
;ICBoaXN0TWVudS5hZGRFdmVudExpc3RlbmVyKCdjbGljaycsIGUgPT4gZS5zdG9wUHJvcGFnYXRpb24oKSk7CiAgZG9jdW1lbnQuYWRkRXZlbnRMaXN0ZW5l
;cignY2xpY2snLCAoKSA9PiB7CiAgICBkcml2ZU1lbnUuY2xhc3NMaXN0LnJlbW92ZSgnb24nKTsKICAgIGNsb3NlSGlzdE1lbnUoKTsKICAgIGhpZGVDdHgo
;KTsKICB9KTsKICByZW5kZXJEcml2ZU1lbnUoKTsKICByZW5kZXJIaXN0TWVudSgpOwogIHN5bmNDbGVhckJ0bigpOwoKICAvLyBQcmltYXJ5IFVJ4oaSQUhL
;IGNoYW5uZWw6IGluLXBhZ2UgcXVldWUgZHJhaW5lZCBieSBBSEsgRXhlY3V0ZVNjcmlwdC4KICAvLyBOZXZlciB1c2UgaG9zdE9iamVjdHMuc3luYyDigJQg
;aXQgZGVhZGxvY2tzIFdlYlZpZXcyIGFuZCBibG9ja3MgcG9zdE1lc3NhZ2UgdG9vLgogIHdpbmRvdy5fX2Foa1EgPSB3aW5kb3cuX19haGtRIHx8IFtdOwog
;IGZ1bmN0aW9uIGVucXVldWUobXNnKSB7CiAgICB0cnkgewogICAgICB3aW5kb3cuX19haGtRLnB1c2goU3RyaW5nKG1zZykpOwogICAgICAvLyBUaXAgQUhL
;IHBvbGxlciB2aWEgdGl0bGUgY2hhbmdlIChvcHRpb25hbCBmYXN0IHBhdGgpCiAgICAgIHRyeSB7IGRvY3VtZW50LmRvY3VtZW50RWxlbWVudC5kYXRhc2V0
;LmFoa1BlbmRpbmcgPSBTdHJpbmcod2luZG93Ll9fYWhrUS5sZW5ndGgpOyB9IGNhdGNoIChfKSB7fQogICAgfSBjYXRjaCAoZSkgeyBjb25zb2xlLndhcm4o
;J2VucXVldWUnLCBlKTsgfQogIH0KICBmdW5jdGlvbiBwb3N0KG1zZykgewogICAgZW5xdWV1ZShtc2cpOwogICAgdHJ5IHsKICAgICAgaWYgKHdpbmRvdy5j
;aHJvbWUgJiYgY2hyb21lLndlYnZpZXcgJiYgdHlwZW9mIGNocm9tZS53ZWJ2aWV3LnBvc3RNZXNzYWdlID09PSAnZnVuY3Rpb24nKSB7CiAgICAgICAgY2hy
;b21lLndlYnZpZXcucG9zdE1lc3NhZ2UoU3RyaW5nKG1zZykpOwogICAgICAgIHJldHVybiB0cnVlOwogICAgICB9CiAgICB9IGNhdGNoIChlKSB7IGNvbnNv
;bGUud2FybigncG9zdCcsIGUpOyB9CiAgICByZXR1cm4gZmFsc2U7CiAgfQogIGZ1bmN0aW9uIGNhbGxIb3N0KG1ldGhvZCwgLi4uYXJncykgewogICAgbGV0
;IG1zZyA9ICcnOwogICAgaWYgKG1ldGhvZCA9PT0gJ3NlYXJjaCcpIHsKICAgICAgY29uc3QgW3EsIGMsIHMsIG9mZnNldF0gPSBhcmdzOwogICAgICBtc2cg
;PSAnc2VhcmNofCcgKyBKU09OLnN0cmluZ2lmeSh7CiAgICAgICAgcTogcSB8fCAnJywgY2F0OiBjIHx8ICdhbGwnLCBzb3J0OiBzIHx8ICdkYXRlLWRlc2Mn
;LAogICAgICAgIGRyaXZlOiBkcml2ZSB8fCAnJywKICAgICAgICBvZmZzZXQ6IE51bWJlcihvZmZzZXQpIHx8IDAsIGdlbjogKytnZW4KICAgICAgfSk7CiAg
;ICB9IGVsc2UgaWYgKG1ldGhvZCA9PT0gJ3ByZXZpZXcnKSB7CiAgICAgIG1zZyA9ICdwcmV2aWV3fCcgKyAoYXJnc1swXSB8fCAnJyk7CiAgICB9IGVsc2Ug
;aWYgKG1ldGhvZCA9PT0gJ29wZW4nKSB7CiAgICAgIG1zZyA9ICdvcGVufCcgKyAoYXJnc1swXSB8fCAnJyk7CiAgICB9IGVsc2UgaWYgKG1ldGhvZCA9PT0g
;J3JldmVhbCcpIHsKICAgICAgbXNnID0gJ3JldmVhbHwnICsgKGFyZ3NbMF0gfHwgJycpOwogICAgfSBlbHNlIGlmIChtZXRob2QgPT09ICdjb3B5RmlsZScp
;IHsKICAgICAgbXNnID0gJ2NvcHlGaWxlfCcgKyAoYXJnc1swXSB8fCAnJyk7CiAgICB9IGVsc2UgaWYgKG1ldGhvZCA9PT0gJ2NvcHlQYXRoJykgewogICAg
;ICBtc2cgPSAnY29weVBhdGh8JyArIChhcmdzWzBdIHx8ICcnKTsKICAgIH0gZWxzZSBpZiAobWV0aG9kID09PSAnY29weURpcicpIHsKICAgICAgbXNnID0g
;J2NvcHlEaXJ8JyArIChhcmdzWzBdIHx8ICcnKTsKICAgIH0gZWxzZSBpZiAobWV0aG9kID09PSAncmVjeWNsZScpIHsKICAgICAgbXNnID0gJ3JlY3ljbGV8
;JyArIChhcmdzWzBdIHx8ICcnKTsKICAgIH0gZWxzZSBpZiAobWV0aG9kID09PSAnY2xvc2UnIHx8IG1ldGhvZCA9PT0gJ21pbmltaXplJyB8fCBtZXRob2Qg
;PT09ICdtYXhpbWl6ZScgfHwgbWV0aG9kID09PSAnZHJhZycpIHsKICAgICAgbXNnID0gbWV0aG9kOwogICAgfSBlbHNlIHsKICAgICAgbXNnID0gbWV0aG9k
;ICsgJ3wnICsgYXJncy5tYXAoYSA9PiBTdHJpbmcoYSA/PyAnJykpLmpvaW4oJ3wnKTsKICAgIH0KICAgIHBvc3QobXNnKTsKICB9CgogIGZ1bmN0aW9uIHNl
;dEJvb3RQY3QocCkgewogICAgcCA9IE1hdGgubWF4KDAsIE1hdGgubWluKDEwMCwgTnVtYmVyKHApIHx8IDApKTsKICAgIGJvb3RQY3QudGV4dENvbnRlbnQg
;PSBNYXRoLnJvdW5kKHApICsgJyUnOwogICAgcmluZ0ZnLnN0eWxlLnN0cm9rZURhc2hhcnJheSA9IFN0cmluZyhDSVJDKTsKICAgIHJpbmdGZy5zdHlsZS5z
;dHJva2VEYXNob2Zmc2V0ID0gU3RyaW5nKENJUkMgKiAoMSAtIHAgLyAxMDApKTsKICB9CgogIGxldCBib290Q21kU2VxID0gMDsKICB3aW5kb3cuX19zZXRC
;b290ID0gKG9uLCBwY3QsIHNlcSkgPT4gewogICAgLy8g5b+955Wl5Lmx5bqP6L+f5Yiw55qEIEFISyBFeGVjdXRlU2NyaXB0QXN5bmPvvIzpgb/lhY3kuLvn
;lYzpnaLpl6rlm57ov5vluqbmnaEKICAgIGlmIChzZXEgIT0gbnVsbCAmJiBzZXEgIT09ICcnICYmICFOdW1iZXIuaXNOYU4oTnVtYmVyKHNlcSkpKSB7CiAg
;ICAgIHNlcSA9IE51bWJlcihzZXEpOwogICAgICBpZiAoc2VxIDwgYm9vdENtZFNlcSkgcmV0dXJuOwogICAgICBib290Q21kU2VxID0gc2VxOwogICAgfQog
;ICAgY29uc3Qgc2tpcEJvb3QgPSBkb2N1bWVudC5kb2N1bWVudEVsZW1lbnQuZ2V0QXR0cmlidXRlKCdkYXRhLXNraXAtYm9vdCcpID09PSAnMScKICAgICAg
;fHwgKHR5cGVvZiBhcHBNb2RlICE9PSAndW5kZWZpbmVkJyAmJiBhcHBNb2RlICE9PSAnZmlsZScpOwogICAgaWYgKG9uICYmIHNraXBCb290KSB7CiAgICAg
;IG9uID0gZmFsc2U7CiAgICAgIHBjdCA9IDEwMDsKICAgIH0KICAgIGlmIChvbikgewogICAgICBib290LmNsYXNzTGlzdC5hZGQoJ29uJyk7CiAgICAgIGNo
;cm9tZS5jbGFzc0xpc3QuYWRkKCdoaWRkZW4nKTsKICAgICAgaWYgKGFwcFJvb3QpIGFwcFJvb3QuY2xhc3NMaXN0LmFkZCgnYm9vdGluZycpOwogICAgICBz
;ZXRCb290UGN0KHBjdCk7CiAgICB9IGVsc2UgewogICAgICBib290LmNsYXNzTGlzdC5yZW1vdmUoJ29uJyk7CiAgICAgIGNocm9tZS5jbGFzc0xpc3QucmVt
;b3ZlKCdoaWRkZW4nKTsKICAgICAgaWYgKGFwcFJvb3QpIGFwcFJvb3QuY2xhc3NMaXN0LnJlbW92ZSgnYm9vdGluZycpOwogICAgICB0cnkgewogICAgICAg
;IGlmICh0eXBlb2YgYXBwTW9kZSA9PT0gJ3VuZGVmaW5lZCcgfHwgYXBwTW9kZSA9PT0gJ2ZpbGUnKQogICAgICAgICAgc2V0VGltZW91dCgoKSA9PiB7IHRy
;eSB7IGRvU2VhcmNoKCk7IH0gY2F0Y2ggKF8pIHt9IH0sIDYwKTsKICAgICAgfSBjYXRjaCAoXykge30KICAgIH0KICB9OwogIHdpbmRvdy5fX3NldEluZGV4
;UHJvZ3Jlc3MgPSAocGN0KSA9PiBzZXRCb290UGN0KHBjdCk7CgogIHdpbmRvdy5fX3NldENhdEljb25zID0gKHBheWxvYWQpID0+IHsKICAgIHRyeSB7CiAg
;ICAgIGNvbnN0IG1hcCA9IHR5cGVvZiBwYXlsb2FkID09PSAnc3RyaW5nJyA/IEpTT04ucGFyc2UocGF5bG9hZCkgOiBwYXlsb2FkOwogICAgICBpZiAoIW1h
;cCB8fCB0eXBlb2YgbWFwICE9PSAnb2JqZWN0JykgcmV0dXJuOwogICAgICBkb2N1bWVudC5xdWVyeVNlbGVjdG9yQWxsKCcuY2F0JykuZm9yRWFjaChidG4g
;PT4gewogICAgICAgIGNvbnN0IGtleSA9IGJ0bi5nZXRBdHRyaWJ1dGUoJ2RhdGEtY2F0Jyk7CiAgICAgICAgY29uc3QgdXJsID0gbWFwW2tleV07CiAgICAg
;ICAgaWYgKCF1cmwpIHJldHVybjsKICAgICAgICBsZXQgaW1nID0gYnRuLnF1ZXJ5U2VsZWN0b3IoJ2ltZy5pY28nKTsKICAgICAgICBpZiAoIWltZykgewog
;ICAgICAgICAgY29uc3Qgb2xkID0gYnRuLnF1ZXJ5U2VsZWN0b3IoJy5pY28sIFtkYXRhLWNhdC1pY29dJyk7CiAgICAgICAgICBpbWcgPSBkb2N1bWVudC5j
;cmVhdGVFbGVtZW50KCdpbWcnKTsKICAgICAgICAgIGltZy5jbGFzc05hbWUgPSAnaWNvJzsKICAgICAgICAgIGltZy5hbHQgPSAnJzsKICAgICAgICAgIGlm
;IChvbGQpIG9sZC5yZXBsYWNlV2l0aChpbWcpOwogICAgICAgICAgZWxzZSBidG4uaW5zZXJ0QmVmb3JlKGltZywgYnRuLmZpcnN0Q2hpbGQpOwogICAgICAg
;IH0KICAgICAgICBpbWcuc3JjID0gdXJsICsgKHVybC5pbmNsdWRlcygnPycpID8gJyYnIDogJz8nKSArICd0PScgKyBEYXRlLm5vdygpOwogICAgICB9KTsK
;ICAgIH0gY2F0Y2ggKGUpIHsgY29uc29sZS53YXJuKCdzZXRDYXRJY29ucycsIGUpOyB9CiAgfTsKCiAgZnVuY3Rpb24gZXh0T2YobmFtZSkgewogICAgY29u
;c3QgaSA9IFN0cmluZyhuYW1lIHx8ICcnKS5sYXN0SW5kZXhPZignLicpOwogICAgcmV0dXJuIGkgPiAwID8gbmFtZS5zbGljZShpICsgMSkudG9Mb3dlckNh
;c2UoKSA6ICcnOwogIH0KICBmdW5jdGlvbiBpY29uSHRtbChpdCkgewogICAgaWYgKGl0Lmljb24pIHsKICAgICAgcmV0dXJuICc8aW1nIHNyYz0iJyArIGVz
;Y2FwZUh0bWwoaXQuaWNvbikgKyAnIiBhbHQ9IiIgbG9hZGluZz0ibGF6eSIgZGVjb2Rpbmc9ImFzeW5jIiBvbmVycm9yPSJ0aGlzLm91dGVySFRNTD1cJzxz
;cGFuIGNsYXNzPWZpLWZhbGxiYWNrPvCfk4Q8L3NwYW4+XCciPic7CiAgICB9CiAgICBpZiAoaXQuaXNEaXIpIHJldHVybiAnPHNwYW4gY2xhc3M9ImZpLWZh
;bGxiYWNrIj7wn5OBPC9zcGFuPic7CiAgICByZXR1cm4gJzxzcGFuIGNsYXNzPSJmaS1mYWxsYmFjayI+8J+ThDwvc3Bhbj4nOwogIH0KICBmdW5jdGlvbiBo
;aWdobGlnaHRIdG1sKHRleHQpIHsKICAgIGNvbnN0IHJhdyA9IFN0cmluZyh0ZXh0ID8/ICcnKTsKICAgIGxldCBodG1sID0gZXNjYXBlSHRtbChyYXcpOwog
;ICAgY29uc3QgcSA9IChxRWwudmFsdWUgfHwgJycpLnRyaW0oKTsKICAgIGlmICghcSkgcmV0dXJuIGh0bWw7CiAgICBjb25zdCB0ZXJtcyA9IHEuc3BsaXQo
;L1x8XHx8XHwvKS5mbGF0TWFwKHMgPT4gcy5zcGxpdCgvXHMrLykpLm1hcCh0ID0+IHQudHJpbSgpKS5maWx0ZXIoQm9vbGVhbik7CiAgICAvLyBsb25nZXIg
;dGVybXMgZmlyc3QgdG8gYXZvaWQgcGFydGlhbCBvdmVybGFwIGlzc3VlcwogICAgdGVybXMuc29ydCgoYSwgYikgPT4gYi5sZW5ndGggLSBhLmxlbmd0aCk7
;CiAgICBmb3IgKGNvbnN0IHQgb2YgdGVybXMpIHsKICAgICAgaWYgKCF0KSBjb250aW51ZTsKICAgICAgY29uc3QgcmUgPSBuZXcgUmVnRXhwKHQucmVwbGFj
;ZSgvWy4qKz9eJHt9KCl8W1xdXFxdL2csICdcXCQmJyksICdnaScpOwogICAgICBodG1sID0gaHRtbC5yZXBsYWNlKHJlLCBtID0+ICc8bWFyaz4nICsgbSAr
;ICc8L21hcms+Jyk7CiAgICB9CiAgICByZXR1cm4gaHRtbDsKICB9CiAgZnVuY3Rpb24gcHJldHR5TmFtZShuYW1lKSB7CiAgICBuYW1lID0gU3RyaW5nKG5h
;bWUgfHwgJycpOwogICAgaWYgKCFuYW1lKSByZXR1cm4gJyc7CiAgICBjb25zdCBlID0gZXh0T2YobmFtZSk7CiAgICBpZiAoIWUgfHwgbmFtZS5zdGFydHNX
;aXRoKCcuJykpIHJldHVybiBoaWdobGlnaHRIdG1sKG5hbWUpOwogICAgY29uc3QgYmFzZSA9IG5hbWUuc2xpY2UoMCwgLShlLmxlbmd0aCArIDEpKTsKICAg
;IHJldHVybiBoaWdobGlnaHRIdG1sKGJhc2UpICsgJzxzcGFuIGNsYXNzPSJleHQiPi4nICsgZXNjYXBlSHRtbChlKSArICc8L3NwYW4+JzsKICB9CiAgZnVu
;Y3Rpb24gZGlzcGxheU5hbWUoaXQpIHsKICAgIGxldCBuID0gU3RyaW5nKGl0Lm5hbWUgfHwgJycpLnRyaW0oKTsKICAgIGlmIChuKSByZXR1cm4gbjsKICAg
;IC8vIGZhbGxiYWNrOiBsYXN0IHNlZ21lbnQgb2YgcGF0aAogICAgY29uc3QgcCA9IFN0cmluZyhpdC5wYXRoIHx8ICcnKS5yZXBsYWNlKC9bXFwvXSskLywg
;JycpOwogICAgY29uc3QgaSA9IE1hdGgubWF4KHAubGFzdEluZGV4T2YoJ1xcJyksIHAubGFzdEluZGV4T2YoJy8nKSk7CiAgICByZXR1cm4gaSA+PSAwID8g
;cC5zbGljZShpICsgMSkgOiBwOwogIH0KICBmdW5jdGlvbiBlc2NhcGVIdG1sKHMpIHsKICAgIHJldHVybiBTdHJpbmcocyA/PyAnJykucmVwbGFjZSgvJi9n
;LCcmYW1wOycpLnJlcGxhY2UoLzwvZywnJmx0OycpLnJlcGxhY2UoLz4vZywnJmd0OycpLnJlcGxhY2UoLyIvZywnJnF1b3Q7Jyk7CiAgfQogIGZ1bmN0aW9u
;IGhpZ2hsaWdodFNlYXJjaFRleHQodGV4dCwgcSkgewogICAgbGV0IGh0bWwgPSBlc2NhcGVIdG1sKFN0cmluZyh0ZXh0ID8/ICcnKSk7CiAgICBjb25zdCBy
;YXdRID0gU3RyaW5nKHEgfHwgJycpLnRyaW0oKTsKICAgIGlmICghcmF3USB8fCAhdGV4dFNlYXJjaE9uKSByZXR1cm4gaHRtbDsKICAgIGNvbnN0IHRlcm1z
;ID0gcmF3US5zcGxpdCgvW1xzfF0rLykubWFwKHQgPT4gdC50cmltKCkpLmZpbHRlcihCb29sZWFuKQogICAgICAuZmlsdGVyKHQgPT4gdCAhPT0gJ3x8JykK
;ICAgICAgLnNvcnQoKGEsIGIpID0+IGIubGVuZ3RoIC0gYS5sZW5ndGgpOwogICAgZm9yIChjb25zdCB0IG9mIHRlcm1zKSB7CiAgICAgIHRyeSB7CiAgICAg
;ICAgY29uc3QgcmUgPSBuZXcgUmVnRXhwKHQucmVwbGFjZSgvWy4qKz9eJHt9KCl8W1xdXFxdL2csICdcXCQmJyksICdnaScpOwogICAgICAgIGh0bWwgPSBo
;dG1sLnJlcGxhY2UocmUsIG0gPT4gJzxtYXJrPicgKyBtICsgJzwvbWFyaz4nKTsKICAgICAgfSBjYXRjaCAoXykge30KICAgIH0KICAgIHJldHVybiBodG1s
;OwogIH0KICBsZXQgdWlEbGdSZXNvbHZlciA9IG51bGw7CiAgZnVuY3Rpb24gY2xvc2VVaURpYWxvZyhyZXN1bHQpIHsKICAgIGNvbnN0IGRsZyA9IGRvY3Vt
;ZW50LmdldEVsZW1lbnRCeUlkKCd1aS1kbGcnKTsKICAgIGlmIChkbGcpIHsKICAgICAgZGxnLmNsYXNzTGlzdC5yZW1vdmUoJ29uJyk7CiAgICAgIGRsZy5z
;ZXRBdHRyaWJ1dGUoJ2FyaWEtaGlkZGVuJywgJ3RydWUnKTsKICAgIH0KICAgIGNvbnN0IHIgPSB1aURsZ1Jlc29sdmVyOwogICAgdWlEbGdSZXNvbHZlciA9
;IG51bGw7CiAgICBpZiAocikgcihyZXN1bHQpOwogIH0KICBmdW5jdGlvbiBzaG93VWlEaWFsb2cob3B0cykgewogICAgb3B0cyA9IG9wdHMgfHwge307CiAg
;ICBjb25zdCBkbGcgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgndWktZGxnJyk7CiAgICBjb25zdCB0aXRsZUVsID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5
;SWQoJ3VpLWRsZy10aXRsZScpOwogICAgY29uc3QgbXNnRWwgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgndWktZGxnLW1zZycpOwogICAgY29uc3QgaW5w
;dXRFbCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd1aS1kbGctaW5wdXQnKTsKICAgIGNvbnN0IG9rQnRuID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQo
;J3VpLWRsZy1vaycpOwogICAgY29uc3QgY2FuY2VsQnRuID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3VpLWRsZy1jYW5jZWwnKTsKICAgIGlmICghZGxn
;IHx8ICFva0J0biB8fCAhY2FuY2VsQnRuKSByZXR1cm4gUHJvbWlzZS5yZXNvbHZlKG9wdHMuaW5wdXQgPyBudWxsIDogZmFsc2UpOwogICAgaWYgKHVpRGxn
;UmVzb2x2ZXIpIGNsb3NlVWlEaWFsb2cob3B0cy5pbnB1dCA/IG51bGwgOiBmYWxzZSk7CiAgICB0aXRsZUVsLnRleHRDb250ZW50ID0gb3B0cy50aXRsZSB8
;fCAob3B0cy5pbnB1dCA/ICfovpPlhaUnIDogJ+ehruiupCcpOwogICAgbXNnRWwudGV4dENvbnRlbnQgPSBvcHRzLm1lc3NhZ2UgfHwgJyc7CiAgICBtc2dF
;bC5zdHlsZS5kaXNwbGF5ID0gb3B0cy5tZXNzYWdlID8gJycgOiAnbm9uZSc7CiAgICBjb25zdCB3YW50SW5wdXQgPSAhIW9wdHMuaW5wdXQ7CiAgICBpbnB1
;dEVsLmNsYXNzTGlzdC50b2dnbGUoJ29uJywgd2FudElucHV0KTsKICAgIGlucHV0RWwudmFsdWUgPSB3YW50SW5wdXQgPyBTdHJpbmcob3B0cy5kZWZhdWx0
;VmFsdWUgPz8gJycpIDogJyc7CiAgICBjYW5jZWxCdG4uc3R5bGUuZGlzcGxheSA9IG9wdHMuaGlkZUNhbmNlbCA/ICdub25lJyA6ICcnOwogICAgY2FuY2Vs
;QnRuLnRleHRDb250ZW50ID0gb3B0cy5jYW5jZWxUZXh0IHx8ICflj5bmtognOwogICAgb2tCdG4udGV4dENvbnRlbnQgPSBvcHRzLm9rVGV4dCB8fCAn56Gu
;5a6aJzsKICAgIG9rQnRuLmNsYXNzTmFtZSA9IG9wdHMuZGFuZ2VyID8gJ2RhbmdlcicgOiAncHJpbWFyeSc7CiAgICByZXR1cm4gbmV3IFByb21pc2UoKHJl
;c29sdmUpID0+IHsKICAgICAgdWlEbGdSZXNvbHZlciA9IHJlc29sdmU7CiAgICAgIGRsZy5jbGFzc0xpc3QuYWRkKCdvbicpOwogICAgICBkbGcuc2V0QXR0
;cmlidXRlKCdhcmlhLWhpZGRlbicsICdmYWxzZScpOwogICAgICBjb25zdCBmaW5pc2hPayA9ICgpID0+IHsKICAgICAgICBpZiAod2FudElucHV0KSBjbG9z
;ZVVpRGlhbG9nKGlucHV0RWwudmFsdWUpOwogICAgICAgIGVsc2UgY2xvc2VVaURpYWxvZyh0cnVlKTsKICAgICAgfTsKICAgICAgb2tCdG4ub25jbGljayA9
;IGZpbmlzaE9rOwogICAgICBjYW5jZWxCdG4ub25jbGljayA9ICgpID0+IGNsb3NlVWlEaWFsb2cod2FudElucHV0ID8gbnVsbCA6IGZhbHNlKTsKICAgICAg
;ZGxnLnF1ZXJ5U2VsZWN0b3IoJy51aS1kbGctbWFzaycpLm9uY2xpY2sgPSAoKSA9PiBjbG9zZVVpRGlhbG9nKHdhbnRJbnB1dCA/IG51bGwgOiBmYWxzZSk7
;CiAgICAgIGlucHV0RWwub25rZXlkb3duID0gKGUpID0+IHsKICAgICAgICBpZiAoZS5rZXkgPT09ICdFbnRlcicpIHsgZS5wcmV2ZW50RGVmYXVsdCgpOyBm
;aW5pc2hPaygpOyB9CiAgICAgICAgZWxzZSBpZiAoZS5rZXkgPT09ICdFc2NhcGUnKSB7IGUucHJldmVudERlZmF1bHQoKTsgY2xvc2VVaURpYWxvZyhudWxs
;KTsgfQogICAgICB9OwogICAgICBkbGcub25rZXlkb3duID0gKGUpID0+IHsKICAgICAgICBpZiAoZS5rZXkgPT09ICdFc2NhcGUnKSB7IGUucHJldmVudERl
;ZmF1bHQoKTsgY2xvc2VVaURpYWxvZyh3YW50SW5wdXQgPyBudWxsIDogZmFsc2UpOyB9CiAgICAgIH07CiAgICAgIHNldFRpbWVvdXQoKCkgPT4gewogICAg
;ICAgIHRyeSB7CiAgICAgICAgICBpZiAod2FudElucHV0KSB7IGlucHV0RWwuZm9jdXMoKTsgaW5wdXRFbC5zZWxlY3QoKTsgfQogICAgICAgICAgZWxzZSBv
;a0J0bi5mb2N1cygpOwogICAgICAgIH0gY2F0Y2ggKF8pIHt9CiAgICAgIH0sIDMwKTsKICAgIH0pOwogIH0KICBmdW5jdGlvbiB1aUNvbmZpcm0obWVzc2Fn
;ZSwgb3B0cykgewogICAgb3B0cyA9IG9wdHMgfHwge307CiAgICByZXR1cm4gc2hvd1VpRGlhbG9nKHsKICAgICAgdGl0bGU6IG9wdHMudGl0bGUgfHwgJ+eh
;ruiupCcsCiAgICAgIG1lc3NhZ2UsCiAgICAgIG9rVGV4dDogb3B0cy5va1RleHQgfHwgJ+ehruWumicsCiAgICAgIGNhbmNlbFRleHQ6IG9wdHMuY2FuY2Vs
;VGV4dCB8fCAn5Y+W5raIJywKICAgICAgZGFuZ2VyOiAhIW9wdHMuZGFuZ2VyCiAgICB9KTsKICB9CiAgZnVuY3Rpb24gdWlQcm9tcHQobWVzc2FnZSwgZGVm
;YXVsdFZhbHVlLCBvcHRzKSB7CiAgICBvcHRzID0gb3B0cyB8fCB7fTsKICAgIHJldHVybiBzaG93VWlEaWFsb2coewogICAgICB0aXRsZTogb3B0cy50aXRs
;ZSB8fCAn6L6T5YWlJywKICAgICAgbWVzc2FnZSwKICAgICAgaW5wdXQ6IHRydWUsCiAgICAgIGRlZmF1bHRWYWx1ZTogZGVmYXVsdFZhbHVlID09IG51bGwg
;PyAnJyA6IGRlZmF1bHRWYWx1ZSwKICAgICAgb2tUZXh0OiBvcHRzLm9rVGV4dCB8fCAn56Gu5a6aJywKICAgICAgY2FuY2VsVGV4dDogb3B0cy5jYW5jZWxU
;ZXh0IHx8ICflj5bmtognCiAgICB9KTsKICB9CiAgZnVuY3Rpb24gc2hvcnRQYXRoKHApIHsKICAgIHAgPSBTdHJpbmcocCB8fCAnJyk7CiAgICBpZiAocC5s
;ZW5ndGggPD0gNTYpIHJldHVybiBwOwogICAgcmV0dXJuIHAuc2xpY2UoMCwgMjgpICsgJy4uLicgKyBwLnNsaWNlKC0yNCk7CiAgfQoKICBmdW5jdGlvbiB1
;cGRhdGVDb3VudCgpIHsKICAgIGlmICh0eXBlb2YgYXBwTW9kZSAhPT0gJ3VuZGVmaW5lZCcgJiYgYXBwTW9kZSAhPT0gJ2ZpbGUnKSByZXR1cm47CiAgICBp
;ZiAoIWl0ZW1zLmxlbmd0aCkgewogICAgICBjb3VudEVsLnRleHRDb250ZW50ID0gJ+WFsSAwIOadoee7k+aenCc7CiAgICAgIHN5bmNGaWxlU2VhcmNoQ2xl
;YXJQaWxsKDApOwogICAgICByZXR1cm47CiAgICB9CiAgICBjb25zdCBzaG93biA9IGl0ZW1zLmxlbmd0aDsKICAgIGNvdW50RWwudGV4dENvbnRlbnQgPSB0
;b3RhbEhpdHMgPiBzaG93bgogICAgICA/ICgn5YWxICcgKyB0b3RhbEhpdHMudG9Mb2NhbGVTdHJpbmcoKSArICcg5p2h57uT5p6c77yI5bey5Yqg6L29ICcg
;KyBzaG93bi50b0xvY2FsZVN0cmluZygpICsgJyDmnaHvvIknKQogICAgICA6ICgn5YWxICcgKyBNYXRoLm1heCh0b3RhbEhpdHMsIHNob3duKS50b0xvY2Fs
;ZVN0cmluZygpICsgJyDmnaHnu5PmnpwnKTsKICAgIHN5bmNGaWxlU2VhcmNoQ2xlYXJQaWxsKE1hdGgubWF4KHRvdGFsSGl0cyB8fCAwLCBzaG93biB8fCAw
;KSk7CiAgfQogIGZ1bmN0aW9uIHN5bmNGaWxlU2VhcmNoQ2xlYXJQaWxsKGhpdE4pIHsKICAgIGNvbnN0IHBpbGwgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJ
;ZCgnY2ZnLXNlYXJjaC1jbGVhcicpOwogICAgY29uc3QgaGl0RWwgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnY2ZnLXNlYXJjaC1oaXQnKTsKICAgIGlm
;ICghcGlsbCkgcmV0dXJuOwogICAgaWYgKGFwcE1vZGUgPT09ICdjb25maWcnKSByZXR1cm47CiAgICBpZiAoYXBwTW9kZSA9PT0gJ2hhbmRsZScpIHsKICAg
;ICAgY29uc3QgaGFzUSA9ICEhKHFFbCAmJiBTdHJpbmcocUVsLnZhbHVlIHx8ICcnKS50cmltKCkpOwogICAgICBsZXQgaGFzVGFncyA9IGZhbHNlOwogICAg
;ICB0cnkgeyBoYXNUYWdzID0gISEoYWN0aXZlSGFuZGxlVGFnSWRzICYmIGFjdGl2ZUhhbmRsZVRhZ0lkcy5zaXplID4gMCk7IH0gY2F0Y2ggKF8pIHt9CiAg
;ICAgIGNvbnN0IHNob3cgPSBoYXNRIHx8IGhhc1RhZ3M7CiAgICAgIHBpbGwuY2xhc3NMaXN0LnRvZ2dsZSgnb24nLCAhIXNob3cpOwogICAgICBpZiAoaGl0
;RWwpIHsKICAgICAgICBpZiAoc2hvdykgewogICAgICAgICAgbGV0IG4gPSBoaXROOwogICAgICAgICAgaWYgKG4gPT0gbnVsbCkgewogICAgICAgICAgICB0
;cnkgeyBuID0gKGhhbmRsZUl0ZW1zICYmIGhhbmRsZUl0ZW1zLmxlbmd0aCkgfHwgMDsgfSBjYXRjaCAoXykgeyBuID0gMDsgfQogICAgICAgICAgfQogICAg
;ICAgICAgaGl0RWwudGV4dENvbnRlbnQgPSBOdW1iZXIobikudG9Mb2NhbGVTdHJpbmcoKSArICcg5p2hJzsKICAgICAgICB9IGVsc2UgewogICAgICAgICAg
;aGl0RWwudGV4dENvbnRlbnQgPSAnJzsKICAgICAgICB9CiAgICAgIH0KICAgICAgcmV0dXJuOwogICAgfQogICAgaWYgKGFwcE1vZGUgIT09ICdmaWxlJykg
;ewogICAgICBwaWxsLmNsYXNzTGlzdC5yZW1vdmUoJ29uJyk7CiAgICAgIGlmIChoaXRFbCkgaGl0RWwudGV4dENvbnRlbnQgPSAnJzsKICAgICAgcmV0dXJu
;OwogICAgfQogICAgY29uc3QgaGFzUSA9ICEhKHFFbCAmJiBTdHJpbmcocUVsLnZhbHVlIHx8ICcnKS50cmltKCkpOwogICAgbGV0IGhhc1RhZ3MgPSBmYWxz
;ZTsKICAgIHRyeSB7IGhhc1RhZ3MgPSAhIShhY3RpdmVGaWx0ZXJJZHMgJiYgYWN0aXZlRmlsdGVySWRzLnNpemUgPiAwKTsgfSBjYXRjaCAoXykge30KICAg
;IGNvbnN0IHNob3cgPSBoYXNRIHx8IGhhc1RhZ3M7CiAgICBwaWxsLmNsYXNzTGlzdC50b2dnbGUoJ29uJywgc2hvdyk7CiAgICBpZiAoaGl0RWwpIHsKICAg
;ICAgaWYgKHNob3cpIHsKICAgICAgICBjb25zdCBuID0gaGl0TiAhPSBudWxsID8gaGl0TiA6IE1hdGgubWF4KHRvdGFsSGl0cyB8fCAwLCBpdGVtcy5sZW5n
;dGggfHwgMCk7CiAgICAgICAgaGl0RWwudGV4dENvbnRlbnQgPSBOdW1iZXIobikudG9Mb2NhbGVTdHJpbmcoKSArICcg5p2hJzsKICAgICAgfSBlbHNlIHsK
;ICAgICAgICBoaXRFbC50ZXh0Q29udGVudCA9ICcnOwogICAgICB9CiAgICB9CiAgfQogIGZ1bmN0aW9uIGNsZWFySGFuZGxlU2VhcmNoQWxsKCkgewogICAg
;dHJ5IHsKICAgICAgaWYgKGFjdGl2ZUhhbmRsZVRhZ0lkcyAmJiBhY3RpdmVIYW5kbGVUYWdJZHMuc2l6ZSkgewogICAgICAgIGFjdGl2ZUhhbmRsZVRhZ0lk
;cy5jbGVhcigpOwogICAgICAgIGlmICh0eXBlb2Ygc2F2ZUFjdGl2ZUhhbmRsZVRhZ3MgPT09ICdmdW5jdGlvbicpIHNhdmVBY3RpdmVIYW5kbGVUYWdzKCk7
;CiAgICAgICAgaWYgKHR5cGVvZiByZW5kZXJIYW5kbGVUYWdCYXIgPT09ICdmdW5jdGlvbicpIHJlbmRlckhhbmRsZVRhZ0JhcigpOwogICAgICB9CiAgICB9
;IGNhdGNoIChfKSB7fQogICAgY2xlYXJUaW1lb3V0KGhpc3RJZGxlVGltZXIpOwogICAgaWYgKHFFbCkgcUVsLnZhbHVlID0gJyc7CiAgICBtb2RlUXVlcnku
;aGFuZGxlID0gJyc7CiAgICBzeW5jQ2xlYXJCdG4oKTsKICAgIHNldEhpc3RDaHJvbWUoZmFsc2UpOwogICAgdHJ5IHsgcUVsLmZvY3VzKCk7IH0gY2F0Y2gg
;KF8pIHt9CiAgICBpZiAodHlwZW9mIHJlcXVlc3RIYW5kbGVTZWFyY2ggPT09ICdmdW5jdGlvbicgJiYgdHlwZW9mIGNvbXBvc2VIYW5kbGVTZWFyY2hRdWVy
;eSA9PT0gJ2Z1bmN0aW9uJykKICAgICAgcmVxdWVzdEhhbmRsZVNlYXJjaChjb21wb3NlSGFuZGxlU2VhcmNoUXVlcnkoKSk7CiAgICBlbHNlIGlmICh0eXBl
;b2YgcmVxdWVzdEhhbmRsZVNlYXJjaCA9PT0gJ2Z1bmN0aW9uJykKICAgICAgcmVxdWVzdEhhbmRsZVNlYXJjaCgnJyk7CiAgICBzeW5jRmlsZVNlYXJjaENs
;ZWFyUGlsbCgwKTsKICAgIGlmICh0eXBlb2Ygc2F2ZVNlc3Npb25Tb29uID09PSAnZnVuY3Rpb24nKSBzYXZlU2Vzc2lvblNvb24oKTsKICB9CiAgZnVuY3Rp
;b24gY2xlYXJGaWxlU2VhcmNoQWxsKCkgewogICAgaWYgKGFjdGl2ZUZpbHRlcklkcykgewogICAgICBhY3RpdmVGaWx0ZXJJZHMuY2xlYXIoKTsKICAgICAg
;c2F2ZUFjdGl2ZUZpbHRlcnMoKTsKICAgICAgcmVuZGVyRmlsdGVyQmFyKCk7CiAgICB9CiAgICBjbGVhclRpbWVvdXQoaGlzdElkbGVUaW1lcik7CiAgICBp
;ZiAocUVsKSBxRWwudmFsdWUgPSAnJzsKICAgIG1vZGVRdWVyeS5maWxlID0gJyc7CiAgICBzeW5jQ2xlYXJCdG4oKTsKICAgIHNldEhpc3RDaHJvbWUoZmFs
;c2UpOwogICAgdHJ5IHsgcUVsLmZvY3VzKCk7IH0gY2F0Y2ggKF8pIHt9CiAgICBkb1NlYXJjaCgpOwogICAgc3luY0ZpbGVTZWFyY2hDbGVhclBpbGwoMCk7
;CiAgICBpZiAodHlwZW9mIHNhdmVTZXNzaW9uU29vbiA9PT0gJ2Z1bmN0aW9uJykgc2F2ZVNlc3Npb25Tb29uKCk7CiAgfQoKICBmdW5jdGlvbiBtYWtlUm93
;KGl0LCBpKSB7CiAgICBjb25zdCByb3cgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsKICAgIHJvdy5jbGFzc05hbWUgPSAncm93JyArIChpID09
;PSBzZWxlY3RlZCA/ICcgb24nIDogJycpOwogICAgY29uc3QgdGl0bGUgPSBkaXNwbGF5TmFtZShpdCk7CiAgICByb3cuaW5uZXJIVE1MID0gYDxkaXYgY2xh
;c3M9ImZpIj4ke2ljb25IdG1sKGl0KX08L2Rpdj4KICAgICAgPGRpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJuYW1lIj4ke3ByZXR0eU5hbWUodGl0bGUpfTwv
;ZGl2PgogICAgICAgIDxkaXYgY2xhc3M9InBhdGgiIHRpdGxlPSIke2VzY2FwZUh0bWwoaXQucGF0aCl9Ij4ke2VzY2FwZUh0bWwoc2hvcnRQYXRoKGl0LnBh
;dGgpKX08L2Rpdj4KICAgICAgPC9kaXY+YDsKICAgIHJvdy5vbmNsaWNrID0gKCkgPT4geyBoaWRlQ3R4KCk7IHNlbGVjdFJvdyhpKTsgfTsKICAgIHJvdy5v
;bmRibGNsaWNrID0gKCkgPT4gewogICAgICBoaWRlQ3R4KCk7CiAgICAgIHB1c2hIaXN0KHFFbC52YWx1ZSB8fCAnJyk7CiAgICAgIGNhbGxIb3N0KCdvcGVu
;JywgaXQucGF0aCk7CiAgICB9OwogICAgcm93Lm9uY29udGV4dG1lbnUgPSAoZSkgPT4gewogICAgICBlLnByZXZlbnREZWZhdWx0KCk7CiAgICAgIGUuc3Rv
;cFByb3BhZ2F0aW9uKCk7CiAgICAgIHNlbGVjdFJvdyhpKTsKICAgICAgc2hvd0N0eChlLmNsaWVudFgsIGUuY2xpZW50WSwgaXQucGF0aCk7CiAgICB9Owog
;ICAgcmV0dXJuIHJvdzsKICB9CgogIGNvbnN0IGN0eEVsID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2N0eCcpOwogIGxldCBjdHhQYXRoID0gJyc7CiAg
;ZnVuY3Rpb24gaGlkZUN0eCgpIHsKICAgIGN0eEVsLmNsYXNzTGlzdC5yZW1vdmUoJ29uJyk7CiAgICBjdHhQYXRoID0gJyc7CiAgfQogIGZ1bmN0aW9uIHNo
;b3dDdHgoeCwgeSwgcGF0aCkgewogICAgY3R4UGF0aCA9IFN0cmluZyhwYXRoIHx8ICcnKTsKICAgIGlmICghY3R4UGF0aCkgcmV0dXJuOwogICAgY3R4RWwu
;Y2xhc3NMaXN0LmFkZCgnb24nKTsKICAgIGNvbnN0IHBhZCA9IDY7CiAgICBjb25zdCB2dyA9IHdpbmRvdy5pbm5lcldpZHRoOwogICAgY29uc3QgdmggPSB3
;aW5kb3cuaW5uZXJIZWlnaHQ7CiAgICBjdHhFbC5zdHlsZS5sZWZ0ID0gJzBweCc7CiAgICBjdHhFbC5zdHlsZS50b3AgPSAnMHB4JzsKICAgIGNvbnN0IHJl
;Y3QgPSBjdHhFbC5nZXRCb3VuZGluZ0NsaWVudFJlY3QoKTsKICAgIGxldCBsZWZ0ID0geDsKICAgIGxldCB0b3AgPSB5OwogICAgaWYgKGxlZnQgKyByZWN0
;LndpZHRoID4gdncgLSBwYWQpIGxlZnQgPSBNYXRoLm1heChwYWQsIHZ3IC0gcmVjdC53aWR0aCAtIHBhZCk7CiAgICBpZiAodG9wICsgcmVjdC5oZWlnaHQg
;PiB2aCAtIHBhZCkgdG9wID0gTWF0aC5tYXgocGFkLCB2aCAtIHJlY3QuaGVpZ2h0IC0gcGFkKTsKICAgIGN0eEVsLnN0eWxlLmxlZnQgPSBsZWZ0ICsgJ3B4
;JzsKICAgIGN0eEVsLnN0eWxlLnRvcCA9IHRvcCArICdweCc7CiAgfQogIGN0eEVsLnF1ZXJ5U2VsZWN0b3JBbGwoJ2J1dHRvbltkYXRhLWFjdF0nKS5mb3JF
;YWNoKGJ0biA9PiB7CiAgICBidG4uYWRkRXZlbnRMaXN0ZW5lcignY2xpY2snLCAoZSkgPT4gewogICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgICBj
;b25zdCBhY3QgPSBidG4uZ2V0QXR0cmlidXRlKCdkYXRhLWFjdCcpOwogICAgICBjb25zdCBwYXRoID0gY3R4UGF0aDsKICAgICAgaGlkZUN0eCgpOwogICAg
;ICBpZiAoIXBhdGggfHwgIWFjdCkgcmV0dXJuOwogICAgICBpZiAoYWN0ID09PSAncmV2ZWFsJykgY2FsbEhvc3QoJ3JldmVhbCcsIHBhdGgpOwogICAgICBl
;bHNlIGlmIChhY3QgPT09ICdjb3B5JykgY2FsbEhvc3QoJ2NvcHlGaWxlJywgcGF0aCk7CiAgICAgIGVsc2UgaWYgKGFjdCA9PT0gJ2NvcHlQYXRoJykgY2Fs
;bEhvc3QoJ2NvcHlQYXRoJywgcGF0aCk7CiAgICAgIGVsc2UgaWYgKGFjdCA9PT0gJ2NvcHlEaXInKSBjYWxsSG9zdCgnY29weURpcicsIHBhdGgpOwogICAg
;ICBlbHNlIGlmIChhY3QgPT09ICdyZWN5Y2xlJykgY2FsbEhvc3QoJ3JlY3ljbGUnLCBwYXRoKTsKICAgIH0pOwogIH0pOwogIGRvY3VtZW50LmFkZEV2ZW50
;TGlzdGVuZXIoJ2NvbnRleHRtZW51JywgKGUpID0+IHsKICAgIGlmICghZS50YXJnZXQuY2xvc2VzdCgnI2xpc3QgLnJvdycpICYmICFlLnRhcmdldC5jbG9z
;ZXN0KCcjY3R4JykpIGhpZGVDdHgoKTsKICB9KTsKICB3aW5kb3cuYWRkRXZlbnRMaXN0ZW5lcignYmx1cicsIGhpZGVDdHgpOwogIHdpbmRvdy5hZGRFdmVu
;dExpc3RlbmVyKCdyZXNpemUnLCBoaWRlQ3R4KTsKICB3aW5kb3cuX19yZW1vdmVQYXRoID0gKHBhdGgpID0+IHsKICAgIHBhdGggPSBTdHJpbmcocGF0aCB8
;fCAnJyk7CiAgICBpZiAoIXBhdGgpIHJldHVybjsKICAgIGNvbnN0IHByZXZTZWwgPSBzZWxlY3RlZCA+PSAwID8gKGl0ZW1zW3NlbGVjdGVkXSAmJiBpdGVt
;c1tzZWxlY3RlZF0ucGF0aCkgOiAnJzsKICAgIGl0ZW1zID0gaXRlbXMuZmlsdGVyKGl0ID0+IFN0cmluZyhpdC5wYXRoIHx8ICcnKSAhPT0gcGF0aCk7CiAg
;ICBpZiAodG90YWxIaXRzID4gMCkgdG90YWxIaXRzID0gTWF0aC5tYXgoMCwgdG90YWxIaXRzIC0gMSk7CiAgICBzZWxlY3RlZCA9IC0xOwogICAgaWYgKHBy
;ZXZTZWwgJiYgcHJldlNlbCAhPT0gcGF0aCkgewogICAgICBzZWxlY3RlZCA9IGl0ZW1zLmZpbmRJbmRleChpdCA9PiBpdC5wYXRoID09PSBwcmV2U2VsKTsK
;ICAgIH0gZWxzZSBpZiAoaXRlbXMubGVuZ3RoKSB7CiAgICAgIHNlbGVjdGVkID0gTWF0aC5taW4oc2VsZWN0ZWQgPCAwID8gMCA6IHNlbGVjdGVkLCBpdGVt
;cy5sZW5ndGggLSAxKTsKICAgIH0KICAgIHJlbmRlckxpc3QoZmFsc2UpOwogICAgaWYgKHNlbGVjdGVkID49IDAgJiYgdGV4dFNlYXJjaE9uKSByZXF1ZXN0
;UHJldmlldyhpdGVtc1tzZWxlY3RlZF0pOwogICAgZWxzZSB7CiAgICAgIHB2TWV0YS50ZXh0Q29udGVudCA9ICfpgInmi6nmlofku7bku6XpooTop4gnOwog
;ICAgICBwdk1lZGlhLmlubmVySFRNTCA9ICc8ZGl2IGNsYXNzPSJwaCI+6aKE6KeI5Yy6PC9kaXY+JzsKICAgICAgcHZUZXh0LnN0eWxlLmRpc3BsYXkgPSAn
;bm9uZSc7CiAgICB9CiAgfTsKCiAgZnVuY3Rpb24gcmVuZGVyTGlzdChhcHBlbmQpIHsKICAgIGlmICghYXBwZW5kKSBsaXN0RWwuaW5uZXJIVE1MID0gJyc7
;CiAgICBpZiAoIWl0ZW1zLmxlbmd0aCkgewogICAgICBlbXB0eUVsLmNsYXNzTGlzdC5hZGQoJ29uJyk7CiAgICAgIHVwZGF0ZUNvdW50KCk7CiAgICAgIHJl
;dHVybjsKICAgIH0KICAgIGVtcHR5RWwuY2xhc3NMaXN0LnJlbW92ZSgnb24nKTsKICAgIGNvbnN0IHN0YXJ0ID0gYXBwZW5kID8gbGlzdEVsLnF1ZXJ5U2Vs
;ZWN0b3JBbGwoJy5yb3cnKS5sZW5ndGggOiAwOwogICAgY29uc3QgZnJhZyA9IGRvY3VtZW50LmNyZWF0ZURvY3VtZW50RnJhZ21lbnQoKTsKICAgIGZvciAo
;bGV0IGkgPSBzdGFydDsgaSA8IGl0ZW1zLmxlbmd0aDsgaSsrKQogICAgICBmcmFnLmFwcGVuZENoaWxkKG1ha2VSb3coaXRlbXNbaV0sIGkpKTsKICAgIGxp
;c3RFbC5hcHBlbmRDaGlsZChmcmFnKTsKICAgIHVwZGF0ZUNvdW50KCk7CiAgfQoKICBmdW5jdGlvbiBzZWxlY3RSb3coaSwgb3B0cykgewogICAgc2VsZWN0
;ZWQgPSBpOwogICAgY29uc3Qgcm93cyA9IGxpc3RFbC5jaGlsZHJlbjsKICAgIGZvciAobGV0IGlkeCA9IDA7IGlkeCA8IHJvd3MubGVuZ3RoOyBpZHgrKykK
;ICAgICAgcm93c1tpZHhdLmNsYXNzTGlzdC50b2dnbGUoJ29uJywgaWR4ID09PSBpKTsKICAgIGNvbnN0IGl0ID0gaXRlbXNbaV07CiAgICBpZiAoIWl0KSBy
;ZXR1cm47CiAgICBpZiAodGV4dFNlYXJjaE9uKSBzY2hlZHVsZVByZXZpZXcoaXQsIG9wdHMgJiYgb3B0cy5pbW1lZGlhdGUpOwogIH0KICBsZXQgcHJldmll
;d1RpbWVyID0gMDsKICBsZXQgcHJldmlld1Rva2VuID0gMDsKICBmdW5jdGlvbiBzY2hlZHVsZVByZXZpZXcoaXQsIGltbWVkaWF0ZSkgewogICAgY2xlYXJU
;aW1lb3V0KHByZXZpZXdUaW1lcik7CiAgICBjb25zdCB0b2sgPSArK3ByZXZpZXdUb2tlbjsKICAgIGNvbnN0IHBhdGggPSBpdCAmJiBpdC5wYXRoOwogICAg
;Y29uc3QgcnVuID0gKCkgPT4gewogICAgICBpZiAodG9rICE9PSBwcmV2aWV3VG9rZW4gfHwgIXRleHRTZWFyY2hPbikgcmV0dXJuOwogICAgICBpZiAoc2Vs
;ZWN0ZWQgPCAwIHx8ICFpdGVtc1tzZWxlY3RlZF0gfHwgaXRlbXNbc2VsZWN0ZWRdLnBhdGggIT09IHBhdGgpIHJldHVybjsKICAgICAgcmVxdWVzdFByZXZp
;ZXcoaXRlbXNbc2VsZWN0ZWRdKTsKICAgIH07CiAgICBpZiAoaW1tZWRpYXRlKSBydW4oKTsKICAgIGVsc2UgcHJldmlld1RpbWVyID0gc2V0VGltZW91dChy
;dW4sIDM2MCk7CiAgfQoKICBmdW5jdGlvbiByZXF1ZXN0UHJldmlldyhpdCkgewogICAgcHZNZXRhLmlubmVySFRNTCA9IGA8c3Bhbj7lkI3np7AgPGI+JHtl
;c2NhcGVIdG1sKGl0Lm5hbWUpfTwvYj48L3NwYW4+YDsKICAgIGlmIChwdkJvZHkpIHB2Qm9keS5jbGFzc0xpc3QucmVtb3ZlKCd0ZXh0LW1vZGUnKTsKICAg
;IHB2TWVkaWEuaW5uZXJIVE1MID0gJzxkaXYgY2xhc3M9InBoIj7liqDovb3pooTop4jigKY8L2Rpdj4nOwogICAgcHZUZXh0LnN0eWxlLmRpc3BsYXkgPSAn
;bm9uZSc7CiAgICBjYWxsSG9zdCgncHJldmlldycsIGl0LnBhdGgpOwogIH0KCiAgZnVuY3Rpb24gdHJ5TG9hZE1vcmUoKSB7CiAgICBpZiAoIWhhc01vcmUg
;fHwgbG9hZGluZ01vcmUpIHJldHVybjsKICAgIGxvYWRpbmdNb3JlID0gdHJ1ZTsKICAgIGNhbGxIb3N0KCdzZWFyY2gnLCBjb21wb3NlU2VhcmNoUXVlcnko
;KSwgY2F0LCBzb3J0LCBpdGVtcy5sZW5ndGgpOwogIH0KCiAgZnVuY3Rpb24gbWF5YmVGaWxsVmlld3BvcnQoKSB7CiAgICAvLyDpppblsY/lj6rmnIkgMTUg
;5p2h5pe25Y+v6IO95LiN5aSf5rua5Yqo77yM6Ieq5Yqo6KGl6aG155u05Yiw5Y+v5rua5oiW5rKh5pyJ5pu05aSaCiAgICBpZiAoIWhhc01vcmUgfHwgbG9h
;ZGluZ01vcmUpIHJldHVybjsKICAgIGlmIChsaXN0RWwuc2Nyb2xsSGVpZ2h0IDw9IGxpc3RFbC5jbGllbnRIZWlnaHQgKyA4KQogICAgICB0cnlMb2FkTW9y
;ZSgpOwogIH0KCiAgbGlzdEVsLmFkZEV2ZW50TGlzdGVuZXIoJ3Njcm9sbCcsICgpID0+IHsKICAgIGlmIChsaXN0RWwuc2Nyb2xsVG9wICsgbGlzdEVsLmNs
;aWVudEhlaWdodCA+PSBsaXN0RWwuc2Nyb2xsSGVpZ2h0IC0gMTIwKQogICAgICB0cnlMb2FkTW9yZSgpOwogIH0pOwoKICB3aW5kb3cuX191cGRhdGVSZXN1
;bHRzID0gKHBheWxvYWQpID0+IHsKICAgIHRyeSB7CiAgICAgIGlmICh0eXBlb2YgYXBwTW9kZSAhPT0gJ3VuZGVmaW5lZCcgJiYgYXBwTW9kZSAhPT0gJ2Zp
;bGUnKSByZXR1cm47CiAgICAgIGNvbnN0IGRhdGEgPSB0eXBlb2YgcGF5bG9hZCA9PT0gJ3N0cmluZycgPyBKU09OLnBhcnNlKHBheWxvYWQpIDogcGF5bG9h
;ZDsKICAgICAgY29uc3QgYmF0Y2ggPSBBcnJheS5pc0FycmF5KGRhdGEuaXRlbXMpID8gZGF0YS5pdGVtcyA6IFtdOwogICAgICBjb25zdCB0b3RhbCA9IE51
;bWJlcihkYXRhLnRvdGFsICE9IG51bGwgPyBkYXRhLnRvdGFsIDogMCkgfHwgMDsKICAgICAgY29uc3Qgb2Zmc2V0ID0gTnVtYmVyKGRhdGEub2Zmc2V0KSB8
;fCAwOwogICAgICBjb25zdCBhcHBlbmQgPSAhIWRhdGEuYXBwZW5kICYmIG9mZnNldCA+IDA7CiAgICAgIGNvbnN0IHBhZ2VTaXplID0gTWF0aC5tYXgoMSwg
;TnVtYmVyKGRhdGEucGFnZVNpemUpIHx8IDUwKTsKCiAgICAgIGlmICh0b3RhbCA+PSAwKQogICAgICAgIHRvdGFsSGl0cyA9IHRvdGFsOwogICAgICBpZiAo
;YXBwZW5kKSB7CiAgICAgICAgY29uc3Qgc2VlbiA9IG5ldyBTZXQoaXRlbXMubWFwKHggPT4geC5wYXRoKSk7CiAgICAgICAgZm9yIChjb25zdCBpdCBvZiBi
;YXRjaCkgewogICAgICAgICAgaWYgKCFzZWVuLmhhcyhpdC5wYXRoKSkgaXRlbXMucHVzaChpdCk7CiAgICAgICAgfQogICAgICAgIGxvYWRpbmdNb3JlID0g
;ZmFsc2U7CiAgICAgICAgLy8g5ruh6aG15bCx57un57ut5Yqg6L2977yb5ZCM5pe25Lul5pyN5Yqh56uv5oC75pWw5Li65YeGCiAgICAgICAgaGFzTW9yZSA9
;IGJhdGNoLmxlbmd0aCA+PSBwYWdlU2l6ZSB8fCAodG90YWxIaXRzID4gMCAmJiBpdGVtcy5sZW5ndGggPCB0b3RhbEhpdHMpOwogICAgICAgIHJlbmRlckxp
;c3QodHJ1ZSk7CiAgICAgIH0gZWxzZSB7CiAgICAgICAgaXRlbXMgPSBiYXRjaDsKICAgICAgICBsb2FkaW5nTW9yZSA9IGZhbHNlOwogICAgICAgIGhhc01v
;cmUgPSBiYXRjaC5sZW5ndGggPj0gcGFnZVNpemUgfHwgKHRvdGFsSGl0cyA+IDAgJiYgaXRlbXMubGVuZ3RoIDwgdG90YWxIaXRzKTsKICAgICAgICBzZWxl
;Y3RlZCA9IGl0ZW1zLmxlbmd0aCA/IDAgOiAtMTsKICAgICAgICByZW5kZXJMaXN0KGZhbHNlKTsKICAgICAgICBpZiAoc2VsZWN0ZWQgPj0gMCAmJiB0ZXh0
;U2VhcmNoT24pIHNjaGVkdWxlUHJldmlldyhpdGVtc1tzZWxlY3RlZF0pOwogICAgICAgIGVsc2UgaWYgKCFpdGVtcy5sZW5ndGgpIHsKICAgICAgICAgIGNs
;ZWFyVGltZW91dChwcmV2aWV3VGltZXIpOwogICAgICAgICAgcHJldmlld1Rva2VuICs9IDE7CiAgICAgICAgICBpZiAocHZCb2R5KSBwdkJvZHkuY2xhc3NM
;aXN0LnJlbW92ZSgndGV4dC1tb2RlJyk7CiAgICAgICAgICBwdk1ldGEudGV4dENvbnRlbnQgPSAn6YCJ5oup5paH5Lu25Lul6aKE6KeIJzsKICAgICAgICAg
;IHB2TWVkaWEuaW5uZXJIVE1MID0gJzxkaXYgY2xhc3M9InBoIj7pooTop4jljLo8L2Rpdj4nOwogICAgICAgICAgcHZUZXh0LnN0eWxlLmRpc3BsYXkgPSAn
;bm9uZSc7CiAgICAgICAgfQogICAgICB9CiAgICAgIHVwZGF0ZUNvdW50KCk7CiAgICAgIHJlcXVlc3RBbmltYXRpb25GcmFtZShtYXliZUZpbGxWaWV3cG9y
;dCk7CiAgICB9IGNhdGNoIChlKSB7CiAgICAgIGNvbnNvbGUuZXJyb3IoZSk7CiAgICAgIGxvYWRpbmdNb3JlID0gZmFsc2U7CiAgICAgIGNvdW50RWwudGV4
;dENvbnRlbnQgPSAn57uT5p6c5pu05paw5aSx6LSlJzsKICAgIH0KICB9OwoKICB3aW5kb3cuX19zZXRQcmV2aWV3ID0gKHBheWxvYWQpID0+IHsKICAgIHRy
;eSB7CiAgICAgIGNvbnN0IGRhdGEgPSB0eXBlb2YgcGF5bG9hZCA9PT0gJ3N0cmluZycgPyBKU09OLnBhcnNlKHBheWxvYWQpIDogcGF5bG9hZDsKICAgICAg
;Y29uc3Qga2luZCA9IGRhdGEua2luZCB8fCAnbm9uZSc7CiAgICAgIGNvbnN0IGJpdHMgPSBbXTsKICAgICAgY29uc3QgZHJ2TWF0Y2ggPSBTdHJpbmcoZGF0
;YS5wYXRoIHx8ICcnKS5tYXRjaCgvXihbQS1aYS16XSk6Lyk7CiAgICAgIGlmIChkcnZNYXRjaCkgewogICAgICAgIGNvbnN0IGxldHRlciA9IGRydk1hdGNo
;WzFdLnRvVXBwZXJDYXNlKCk7CiAgICAgICAgY29uc3QgaGl0ID0gKGRyaXZlTWV0YS5kcml2ZXMgfHwgW10pLmZpbmQoZCA9PiBTdHJpbmcoZC5sZXR0ZXIg
;fHwgJycpLnRvVXBwZXJDYXNlKCkgPT09IGxldHRlcik7CiAgICAgICAgY29uc3QgaWNvID0gKGhpdCAmJiBoaXQuaWNvbikgPyAoJzxpbWcgc3JjPSInICsg
;ZXNjYXBlSHRtbChoaXQuaWNvbikgKyAnIiBhbHQ9IiI+JykgOiAnJzsKICAgICAgICBjb25zdCBsYWJlbCA9IChoaXQgJiYgaGl0LmxhYmVsKSA/IGhpdC5s
;YWJlbCA6IChsZXR0ZXIgKyAnOicpOwogICAgICAgIGJpdHMucHVzaCgnPHNwYW4gY2xhc3M9ImRydiI+JyArIGljbyArIGVzY2FwZUh0bWwobGFiZWwpICsg
;Jzwvc3Bhbj4nKTsKICAgICAgfQogICAgICBpZiAoZGF0YS5lbmNvZGluZykgYml0cy5wdXNoKCfnvJbnoIEgPGI+JyArIGVzY2FwZUh0bWwoZGF0YS5lbmNv
;ZGluZykgKyAnPC9iPicpOwogICAgICBpZiAoZGF0YS5zaXplVGV4dCkgYml0cy5wdXNoKCflpKflsI8gPGI+JyArIGVzY2FwZUh0bWwoZGF0YS5zaXplVGV4
;dCkgKyAnPC9iPicpOwogICAgICBpZiAoZGF0YS5kaW1zKSBiaXRzLnB1c2goJ+WwuuWvuCA8Yj4nICsgZXNjYXBlSHRtbChkYXRhLmRpbXMpICsgJzwvYj4n
;KTsKICAgICAgaWYgKGRhdGEubXRpbWUpIGJpdHMucHVzaCgn5L+u5pS5IDxiPicgKyBlc2NhcGVIdG1sKGRhdGEubXRpbWUpICsgJzwvYj4nKTsKICAgICAg
;cHZNZXRhLmlubmVySFRNTCA9IGJpdHMuam9pbignPHNwYW4gc3R5bGU9Im9wYWNpdHk6LjM1Ij7Ctzwvc3Bhbj4nKSB8fCAn6aKE6KeIJzsKICAgICAgcHZU
;ZXh0LnN0eWxlLmRpc3BsYXkgPSAnbm9uZSc7CiAgICAgIGlmIChwdkJvZHkpIHB2Qm9keS5jbGFzc0xpc3QucmVtb3ZlKCd0ZXh0LW1vZGUnKTsKCiAgICAg
;IGlmIChraW5kID09PSAnaW1hZ2UnICYmIGRhdGEudXJsKSB7CiAgICAgICAgcHZNZWRpYS5pbm5lckhUTUwgPSAnJzsKICAgICAgICBjb25zdCBpbWcgPSBk
;b2N1bWVudC5jcmVhdGVFbGVtZW50KCdpbWcnKTsKICAgICAgICBpbWcuc3JjID0gZGF0YS51cmw7CiAgICAgICAgaW1nLmFsdCA9ICcnOwogICAgICAgIHB2
;TWVkaWEuYXBwZW5kQ2hpbGQoaW1nKTsKICAgICAgfSBlbHNlIGlmIChraW5kID09PSAndmlkZW8nKSB7CiAgICAgICAgcHZNZWRpYS5pbm5lckhUTUwgPSAn
;JzsKICAgICAgICBwdk1lZGlhLnN0eWxlLmZsZXhEaXJlY3Rpb24gPSAnY29sdW1uJzsKICAgICAgICBpZiAoZGF0YS51cmwpIHsKICAgICAgICAgIGNvbnN0
;IHYgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCd2aWRlbycpOwogICAgICAgICAgdi5jb250cm9scyA9IHRydWU7CiAgICAgICAgICB2LnByZWxvYWQgPSAn
;bWV0YWRhdGEnOwogICAgICAgICAgdi5zcmMgPSBkYXRhLnVybDsKICAgICAgICAgIHYuc3R5bGUubWF4V2lkdGggPSAnMTAwJSc7CiAgICAgICAgICB2LnN0
;eWxlLm1heEhlaWdodCA9IGRhdGEudGh1bWIgPyAnNzAlJyA6ICcxMDAlJzsKICAgICAgICAgIHYub25lcnJvciA9ICgpID0+IHsKICAgICAgICAgICAgaWYg
;KGRhdGEudGh1bWIpIHsKICAgICAgICAgICAgICB2LnJlcGxhY2VXaXRoKE9iamVjdC5hc3NpZ24oZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnaW1nJyksIHsK
;ICAgICAgICAgICAgICAgIHNyYzogZGF0YS50aHVtYiwgc3R5bGU6ICdtYXgtd2lkdGg6MTAwJTttYXgtaGVpZ2h0OjgwJTtvYmplY3QtZml0OmNvbnRhaW4n
;CiAgICAgICAgICAgICAgfSkpOwogICAgICAgICAgICB9CiAgICAgICAgICB9OwogICAgICAgICAgcHZNZWRpYS5hcHBlbmRDaGlsZCh2KTsKICAgICAgICB9
;IGVsc2UgaWYgKGRhdGEudGh1bWIpIHsKICAgICAgICAgIGNvbnN0IGltZyA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2ltZycpOwogICAgICAgICAgaW1n
;LnNyYyA9IGRhdGEudGh1bWI7CiAgICAgICAgICBpbWcuc3R5bGUubWF4V2lkdGggPSAnMTAwJSc7CiAgICAgICAgICBpbWcuc3R5bGUubWF4SGVpZ2h0ID0g
;JzgwJSc7CiAgICAgICAgICBpbWcuc3R5bGUub2JqZWN0Rml0ID0gJ2NvbnRhaW4nOwogICAgICAgICAgcHZNZWRpYS5hcHBlbmRDaGlsZChpbWcpOwogICAg
;ICAgIH0gZWxzZSB7CiAgICAgICAgICBwdk1lZGlhLmlubmVySFRNTCA9ICc8ZGl2IGNsYXNzPSJwaCI+5peg5rOV6aKE6KeI5q2k6KeG6aKR77yM6K+35Y+M
;5Ye75omT5byAPC9kaXY+JzsKICAgICAgICB9CiAgICAgIH0gZWxzZSBpZiAoa2luZCA9PT0gJ2F1ZGlvJykgewogICAgICAgIHB2TWVkaWEuaW5uZXJIVE1M
;ID0gJyc7CiAgICAgICAgY29uc3Qgd3JhcCA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOwogICAgICAgIHdyYXAuY2xhc3NOYW1lID0gJ3B2LWZp
;bGVpbmZvJzsKICAgICAgICB3cmFwLnN0eWxlLmJhY2tncm91bmQgPSAnIzNmNDQ1MCc7CiAgICAgICAgd3JhcC5zdHlsZS5jb2xvciA9ICcjZTVlN2ViJzsK
;ICAgICAgICBpZiAoZGF0YS5pY29uKSB3cmFwLmlubmVySFRNTCA9ICc8aW1nIGNsYXNzPSJiaWctaWNvIiBzcmM9IicgKyBlc2NhcGVIdG1sKGRhdGEuaWNv
;bikgKyAnIiBhbHQ9IiI+JzsKICAgICAgICB3cmFwLmlubmVySFRNTCArPSAnPGRpdiBjbGFzcz0iZm4iIHN0eWxlPSJjb2xvcjojZmZmIj4nICsgZXNjYXBl
;SHRtbChkYXRhLm5hbWUgfHwgJycpICsgJzwvZGl2Pic7CiAgICAgICAgcHZNZWRpYS5hcHBlbmRDaGlsZCh3cmFwKTsKICAgICAgICBpZiAoZGF0YS51cmwp
;IHsKICAgICAgICAgIGNvbnN0IGEgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdhdWRpbycpOwogICAgICAgICAgYS5jb250cm9scyA9IHRydWU7CiAgICAg
;ICAgICBhLnNyYyA9IGRhdGEudXJsOwogICAgICAgICAgYS5zdHlsZS53aWR0aCA9ICc4NiUnOwogICAgICAgICAgYS5zdHlsZS5tYXJnaW5Ub3AgPSAnMTJw
;eCc7CiAgICAgICAgICB3cmFwLmFwcGVuZENoaWxkKGEpOwogICAgICAgIH0KICAgICAgfSBlbHNlIGlmIChraW5kID09PSAncGRmJyAmJiBkYXRhLnVybCkg
;ewogICAgICAgIHB2TWVkaWEuaW5uZXJIVE1MID0gJyc7CiAgICAgICAgY29uc3QgZW1iID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnZW1iZWQnKTsKICAg
;ICAgICBlbWIuY2xhc3NOYW1lID0gJ3BkZic7CiAgICAgICAgZW1iLnR5cGUgPSAnYXBwbGljYXRpb24vcGRmJzsKICAgICAgICBlbWIuc3JjID0gZGF0YS51
;cmw7CiAgICAgICAgcHZNZWRpYS5hcHBlbmRDaGlsZChlbWIpOwogICAgICB9IGVsc2UgaWYgKGtpbmQgPT09ICd0ZXh0JykgewogICAgICAgIGlmIChwdkJv
;ZHkpIHB2Qm9keS5jbGFzc0xpc3QuYWRkKCd0ZXh0LW1vZGUnKTsKICAgICAgICBwdk1lZGlhLmlubmVySFRNTCA9ICcnOwogICAgICAgIHB2VGV4dC5zdHls
;ZS5kaXNwbGF5ID0gJ2ZsZXgnOwogICAgICAgIHB2VGV4dEhkLnRleHRDb250ZW50ID0gdGV4dFNlYXJjaE9uCiAgICAgICAgICA/IChkYXRhLnRleHRUaXRs
;ZSB8fCAn5paH5Lu25YaF5a6577yI5ZG95Lit5bey6auY5Lqu77yJJykKICAgICAgICAgIDogKGRhdGEudGV4dFRpdGxlIHx8ICfmlofku7blhoXlrrknKTsK
;ICAgICAgICB0cnkgewogICAgICAgICAgcHZQcmUuaW5uZXJIVE1MID0gaGlnaGxpZ2h0U2VhcmNoVGV4dChkYXRhLnRleHQgfHwgJycsIFN0cmluZyhxRWwg
;JiYgcUVsLnZhbHVlIHx8ICcnKSk7CiAgICAgICAgfSBjYXRjaCAoXykgewogICAgICAgICAgcHZQcmUudGV4dENvbnRlbnQgPSBkYXRhLnRleHQgfHwgJyc7
;CiAgICAgICAgfQogICAgICB9IGVsc2UgaWYgKGtpbmQgPT09ICdmb2xkZXInIHx8IGtpbmQgPT09ICdmaWxlaW5mbycpIHsKICAgICAgICAvLyBBbHdheXMg
;cHJlZmVyIGNsZWFuIHNoZWxsIGljb24g4oCUIG5ldmVyIHVzZSBibGFjay1tYXR0ZSB0aHVtYm5haWxzIGhlcmUKICAgICAgICBjb25zdCBpY29TcmMgPSBk
;YXRhLmljb24gfHwgJyc7CiAgICAgICAgY29uc3QgaWNvID0gaWNvU3JjCiAgICAgICAgICA/ICc8aW1nIGNsYXNzPSJiaWctaWNvIiBzcmM9IicgKyBlc2Nh
;cGVIdG1sKGljb1NyYykgKyAnIiBhbHQ9IiI+JwogICAgICAgICAgOiAnPGRpdiBjbGFzcz0iYmlnLWljbyIgc3R5bGU9ImZvbnQtc2l6ZTozNnB4O2xpbmUt
;aGVpZ2h0OjQ4cHgiPicgKyAoa2luZCA9PT0gJ2ZvbGRlcicgPyAn8J+TgScgOiAn8J+ThCcpICsgJzwvZGl2Pic7CiAgICAgICAgY29uc3Qgcm93cyA9IFtd
;OwogICAgICAgIGlmIChkYXRhLnNpemVUZXh0KSByb3dzLnB1c2goWyflpKflsI8nLCBkYXRhLnNpemVUZXh0XSk7CiAgICAgICAgaWYgKGRhdGEubXRpbWUp
;IHJvd3MucHVzaChbJ+S/ruaUueaXtumXtCcsIGRhdGEubXRpbWVdKTsKICAgICAgICBpZiAoZGF0YS5kaXIgfHwgZGF0YS5wYXRoKSByb3dzLnB1c2goWyfm
;iYDlnKjot6/lvoQnLCBkYXRhLmRpciB8fCBkYXRhLnBhdGhdKTsKICAgICAgICBjb25zdCBrdiA9IHJvd3MubGVuZ3RoCiAgICAgICAgICA/ICc8ZGl2IGNs
;YXNzPSJrdiI+JyArIHJvd3MubWFwKChbaywgdl0pID0+CiAgICAgICAgICAgICAgJzxkaXYgY2xhc3M9Imt2LXJvdyI+PHNwYW4gY2xhc3M9ImsiPicgKyBl
;c2NhcGVIdG1sKGspICsgJzwvc3Bhbj4nCiAgICAgICAgICAgICAgKyAnPHNwYW4gY2xhc3M9InYiPicgKyBlc2NhcGVIdG1sKHYpICsgJzwvc3Bhbj48L2Rp
;dj4nCiAgICAgICAgICAgICkuam9pbignJykgKyAnPC9kaXY+JwogICAgICAgICAgOiAnJzsKICAgICAgICBsZXQga2lkcyA9ICcnOwogICAgICAgIGlmIChB
;cnJheS5pc0FycmF5KGRhdGEuY2hpbGRyZW4pICYmIGRhdGEuY2hpbGRyZW4ubGVuZ3RoKSB7CiAgICAgICAgICBraWRzID0gJzxkaXYgY2xhc3M9ImtpZHMi
;PjxiPuWGheWuuemihOiniDwvYj48YnI+JwogICAgICAgICAgICArIGRhdGEuY2hpbGRyZW4ubWFwKGMgPT4gZXNjYXBlSHRtbChjKSkuam9pbignPGJyPicp
;ICsgJzwvZGl2Pic7CiAgICAgICAgfQogICAgICAgIGNvbnN0IGhpbnQgPSBkYXRhLmhpbnQKICAgICAgICAgID8gJzxkaXYgY2xhc3M9ImhpbnQiPicgKyBl
;c2NhcGVIdG1sKGRhdGEuaGludCkgKyAnPC9kaXY+JwogICAgICAgICAgOiAnJzsKICAgICAgICBwdk1lZGlhLnN0eWxlLmJhY2tncm91bmQgPSAnI2Y3Zjhm
;Yic7CiAgICAgICAgcHZNZWRpYS5pbm5lckhUTUwgPSAnPGRpdiBjbGFzcz0icHYtZmlsZWluZm8iPicgKyBpY28KICAgICAgICAgICsgJzxkaXYgY2xhc3M9
;ImZuIj4nICsgZXNjYXBlSHRtbChkYXRhLm5hbWUgfHwgJycpICsgJzwvZGl2PicKICAgICAgICAgICsgaGludCArIGt2ICsga2lkcyArICc8L2Rpdj4nOwog
;ICAgICB9IGVsc2UgewogICAgICAgIHB2TWVkaWEuaW5uZXJIVE1MID0gJzxkaXYgY2xhc3M9InBoIj4nICsgZXNjYXBlSHRtbChkYXRhLm1lc3NhZ2UgfHwg
;J+aXoOazlemihOiniOatpOexu+WeiycpICsgJzwvZGl2Pic7CiAgICAgIH0KICAgIH0gY2F0Y2ggKGUpIHt9CiAgfTsKCiAgZnVuY3Rpb24gZG9TZWFyY2go
;KSB7CiAgICBpZiAodHlwZW9mIGFwcE1vZGUgIT09ICd1bmRlZmluZWQnICYmIGFwcE1vZGUgPT09ICdoYW5kbGUnKSB7CiAgICAgIHJlcXVlc3RIYW5kbGVT
;ZWFyY2goY29tcG9zZUhhbmRsZVNlYXJjaFF1ZXJ5KCkpOwogICAgICByZXR1cm47CiAgICB9CiAgICBpZiAodHlwZW9mIGFwcE1vZGUgIT09ICd1bmRlZmlu
;ZWQnICYmIGFwcE1vZGUgPT09ICdpbmZvJykgewogICAgICByZXF1ZXN0U3lzSW5mbyhmYWxzZSk7CiAgICAgIHJldHVybjsKICAgIH0KICAgIGNvbnN0IHEg
;PSBjb21wb3NlU2VhcmNoUXVlcnkoKTsKICAgIGNvdW50RWwudGV4dENvbnRlbnQgPSAn5pCc57Si5Lit4oCmJzsKICAgIGxvYWRpbmdNb3JlID0gZmFsc2U7
;CiAgICBoYXNNb3JlID0gZmFsc2U7CiAgICBjYWxsSG9zdCgnc2VhcmNoJywgcSwgY2F0LCBzb3J0LCAwKTsKICB9CiAgZnVuY3Rpb24gc2NoZWR1bGVTZWFy
;Y2goKSB7CiAgICBpZiAodHlwZW9mIGFwcE1vZGUgIT09ICd1bmRlZmluZWQnICYmIGFwcE1vZGUgIT09ICdmaWxlJykgcmV0dXJuOwogICAgY2xlYXJUaW1l
;b3V0KHNlYXJjaFRpbWVyKTsKICAgIHNlYXJjaFRpbWVyID0gc2V0VGltZW91dChkb1NlYXJjaCwgMTIwKTsKICB9CgogIGRvY3VtZW50LnF1ZXJ5U2VsZWN0
;b3JBbGwoJy5jYXQnKS5mb3JFYWNoKGJ0biA9PiB7CiAgICBidG4uYWRkRXZlbnRMaXN0ZW5lcignY2xpY2snLCAoKSA9PiB7CiAgICAgIGRvY3VtZW50LnF1
;ZXJ5U2VsZWN0b3JBbGwoJy5jYXQnKS5mb3JFYWNoKGIgPT4gYi5jbGFzc0xpc3QucmVtb3ZlKCdvbicpKTsKICAgICAgYnRuLmNsYXNzTGlzdC5hZGQoJ29u
;Jyk7CiAgICAgIGNvbnN0IGMgPSBidG4uZGF0YXNldC5jYXQ7CiAgICAgIGlmIChjID09PSAnX19oYW5kbGUnKSB7CiAgICAgICAgc2V0QXBwTW9kZSgnaGFu
;ZGxlJyk7CiAgICAgICAgcmV0dXJuOwogICAgICB9CiAgICAgIGlmIChjID09PSAnX19pbmZvJykgewogICAgICAgIHNldEFwcE1vZGUoJ2luZm8nKTsKICAg
;ICAgICByZXR1cm47CiAgICAgIH0KICAgICAgaWYgKGMgPT09ICdfX2NvbmZpZycpIHsKICAgICAgICBzZXRBcHBNb2RlKCdjb25maWcnKTsKICAgICAgICBy
;ZXR1cm47CiAgICAgIH0KICAgICAgY2F0ID0gYzsKICAgICAgc2V0QXBwTW9kZSgnZmlsZScpOwogICAgICBkb1NlYXJjaCgpOwogICAgICBpZiAodHlwZW9m
;IHNhdmVTZXNzaW9uU29vbiA9PT0gJ2Z1bmN0aW9uJykgc2F2ZVNlc3Npb25Tb29uKCk7CiAgICB9KTsKICB9KTsKICBxRWwuYWRkRXZlbnRMaXN0ZW5lcign
;aW5wdXQnLCAoKSA9PiB7CiAgICBpZiAoYXBwTW9kZSA9PT0gJ2ZpbGUnKSBtb2RlUXVlcnkuZmlsZSA9IHFFbC52YWx1ZTsKICAgIGVsc2UgaWYgKGFwcE1v
;ZGUgPT09ICdoYW5kbGUnKSBtb2RlUXVlcnkuaGFuZGxlID0gcUVsLnZhbHVlOwogICAgZWxzZSBpZiAoYXBwTW9kZSA9PT0gJ2luZm8nKSBtb2RlUXVlcnku
;aW5mbyA9IHFFbC52YWx1ZTsKICAgIGVsc2UgaWYgKGFwcE1vZGUgPT09ICdjb25maWcnKSB7CiAgICAgIG1vZGVRdWVyeS5jb25maWcgPSBxRWwudmFsdWU7
;CiAgICAgIGlmICh0eXBlb2YgYXBwbHlDb25maWdTZWFyY2ggPT09ICdmdW5jdGlvbicpIGFwcGx5Q29uZmlnU2VhcmNoKHFFbC52YWx1ZSk7CiAgICAgIHN5
;bmNDbGVhckJ0bigpOwogICAgICBjbGVhclRpbWVvdXQoaGlzdElkbGVUaW1lcik7CiAgICAgIGhpc3RJZGxlVGltZXIgPSBzZXRUaW1lb3V0KCgpID0+IHsK
;ICAgICAgICBpZiAoYXBwTW9kZSA9PT0gJ2NvbmZpZycpIHB1c2hIaXN0KHFFbC52YWx1ZSB8fCAnJyk7CiAgICAgIH0sIDEyMDApOwogICAgICBpZiAodHlw
;ZW9mIHNhdmVTZXNzaW9uU29vbiA9PT0gJ2Z1bmN0aW9uJykgc2F2ZVNlc3Npb25Tb29uKCk7CiAgICAgIHJldHVybjsKICAgIH0KICAgIHN5bmNDbGVhckJ0
;bigpOwogICAgc2NoZWR1bGVTZWFyY2goKTsKICAgIGNsZWFyVGltZW91dChoaXN0SWRsZVRpbWVyKTsKICAgIGhpc3RJZGxlVGltZXIgPSBzZXRUaW1lb3V0
;KCgpID0+IHsKICAgICAgaWYgKGFwcE1vZGUgPT09ICdpbmZvJyB8fCBhcHBNb2RlID09PSAnY29uZmlnJykgcmV0dXJuOwogICAgICBwdXNoSGlzdChxRWwu
;dmFsdWUgfHwgJycpOwogICAgfSwgMTIwMCk7CiAgICBpZiAodHlwZW9mIHNhdmVTZXNzaW9uU29vbiA9PT0gJ2Z1bmN0aW9uJykgc2F2ZVNlc3Npb25Tb29u
;KCk7CiAgfSk7CiAgcUVsLmFkZEV2ZW50TGlzdGVuZXIoJ2tleWRvd24nLCBlID0+IHsKICAgIGlmIChhcHBNb2RlID09PSAnaW5mbycpIHJldHVybjsKICAg
;IGlmIChlLmtleSA9PT0gJ0VudGVyJykgewogICAgICBjbGVhclRpbWVvdXQoaGlzdElkbGVUaW1lcik7CiAgICAgIHB1c2hIaXN0KHFFbC52YWx1ZSB8fCAn
;Jyk7CiAgICAgIGlmIChhcHBNb2RlID09PSAnY29uZmlnJykgewogICAgICAgIGlmICh0eXBlb2YgYXBwbHlDb25maWdTZWFyY2ggPT09ICdmdW5jdGlvbicp
;IGFwcGx5Q29uZmlnU2VhcmNoKHFFbC52YWx1ZSk7CiAgICAgIH0gZWxzZSB7CiAgICAgICAgZG9TZWFyY2goKTsKICAgICAgfQogICAgfSBlbHNlIGlmIChl
;LmtleSA9PT0gJ0VzY2FwZScgJiYgKHFFbC52YWx1ZSB8fCAnJykpIHsKICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgY2xlYXJTZWFyY2goKTsK
;ICAgIH0KICB9KTsKICBxRWwuYWRkRXZlbnRMaXN0ZW5lcignYmx1cicsICgpID0+IHsKICAgIGNsZWFyVGltZW91dChoaXN0SWRsZVRpbWVyKTsKICAgIGlm
;IChhcHBNb2RlICE9PSAnaW5mbycpIHB1c2hIaXN0KHFFbC52YWx1ZSB8fCAnJyk7CiAgfSk7CgogIGZ1bmN0aW9uIGZvY3VzU2VhcmNoKHNlbGVjdEFsbCkg
;ewogICAgdHJ5IHsKICAgICAgcUVsLmZvY3VzKCk7CiAgICAgIGlmIChzZWxlY3RBbGwgIT09IGZhbHNlKQogICAgICAgIHFFbC5zZWxlY3QoKTsKICAgIH0g
;Y2F0Y2ggKF8pIHt9CiAgfQogIHdpbmRvdy5fX2ZvY3VzU2VhcmNoID0gZm9jdXNTZWFyY2g7CgogIGZ1bmN0aW9uIGlzVmlkZW9GdWxsc2NyZWVuKCkgewog
;ICAgY29uc3QgZnMgPSBkb2N1bWVudC5mdWxsc2NyZWVuRWxlbWVudCB8fCBkb2N1bWVudC53ZWJraXRGdWxsc2NyZWVuRWxlbWVudCB8fCBkb2N1bWVudC5t
;c0Z1bGxzY3JlZW5FbGVtZW50OwogICAgaWYgKGZzKSByZXR1cm4gdHJ1ZTsKICAgIGNvbnN0IHZpZHMgPSBkb2N1bWVudC5xdWVyeVNlbGVjdG9yQWxsKCd2
;aWRlbycpOwogICAgZm9yIChjb25zdCB2IG9mIHZpZHMpIHsKICAgICAgaWYgKHYud2Via2l0RGlzcGxheWluZ0Z1bGxzY3JlZW4gfHwgdi5tb3pGdWxsU2Ny
;ZWVuIHx8IHYubXNGdWxsc2NyZWVuRWxlbWVudCkgcmV0dXJuIHRydWU7CiAgICB9CiAgICByZXR1cm4gZmFsc2U7CiAgfQogIGZ1bmN0aW9uIGV4aXRWaWRl
;b0Z1bGxzY3JlZW4oKSB7CiAgICB0cnkgewogICAgICBpZiAoZG9jdW1lbnQuZnVsbHNjcmVlbkVsZW1lbnQgfHwgZG9jdW1lbnQud2Via2l0RnVsbHNjcmVl
;bkVsZW1lbnQpIHsKICAgICAgICBjb25zdCBwID0gZG9jdW1lbnQuZXhpdEZ1bGxzY3JlZW4gPyBkb2N1bWVudC5leGl0RnVsbHNjcmVlbigpCiAgICAgICAg
;ICA6IChkb2N1bWVudC53ZWJraXRFeGl0RnVsbHNjcmVlbiAmJiBkb2N1bWVudC53ZWJraXRFeGl0RnVsbHNjcmVlbigpKTsKICAgICAgICByZXR1cm4gdHJ1
;ZTsKICAgICAgfQogICAgfSBjYXRjaCAoXykge30KICAgIGNvbnN0IHZpZHMgPSBkb2N1bWVudC5xdWVyeVNlbGVjdG9yQWxsKCd2aWRlbycpOwogICAgZm9y
;IChjb25zdCB2IG9mIHZpZHMpIHsKICAgICAgdHJ5IHsKICAgICAgICBpZiAodi53ZWJraXREaXNwbGF5aW5nRnVsbHNjcmVlbiAmJiB2LndlYmtpdEV4aXRG
;dWxsc2NyZWVuKSB7CiAgICAgICAgICB2LndlYmtpdEV4aXRGdWxsc2NyZWVuKCk7CiAgICAgICAgICByZXR1cm4gdHJ1ZTsKICAgICAgICB9CiAgICAgICAg
;aWYgKHYuZXhpdEZ1bGxzY3JlZW4pIHsgdi5leGl0RnVsbHNjcmVlbigpOyByZXR1cm4gdHJ1ZTsgfQogICAgICB9IGNhdGNoIChfKSB7fQogICAgfQogICAg
;cmV0dXJuIGZhbHNlOwogIH0KICB3aW5kb3cuX19oYW5kbGVFc2MgPSAoKSA9PiB7CiAgICBpZiAoaXNWaWRlb0Z1bGxzY3JlZW4oKSB8fCBleGl0VmlkZW9G
;dWxsc2NyZWVuKCkpIHsKICAgICAgdHJ5IHsgZXhpdFZpZGVvRnVsbHNjcmVlbigpOyB9IGNhdGNoIChfKSB7fQogICAgICBwb3N0KCdlc2NDb25zdW1lZCcp
;OwogICAgICByZXR1cm4gdHJ1ZTsKICAgIH0KICAgIHBvc3QoJ2VzY0hpZGUnKTsKICAgIHJldHVybiBmYWxzZTsKICB9OwogIGRvY3VtZW50LmFkZEV2ZW50
;TGlzdGVuZXIoJ2tleWRvd24nLCBlID0+IHsKICAgIGlmICgoZS5jdHJsS2V5IHx8IGUubWV0YUtleSkgJiYgIWUuYWx0S2V5ICYmICFlLnNoaWZ0S2V5ICYm
;IFN0cmluZyhlLmtleSkudG9Mb3dlckNhc2UoKSA9PT0gJ2YnKSB7CiAgICAgIGUucHJldmVudERlZmF1bHQoKTsKICAgICAgZS5zdG9wUHJvcGFnYXRpb24o
;KTsKICAgICAgZm9jdXNTZWFyY2goKTsKICAgICAgcmV0dXJuOwogICAgfQogICAgaWYgKGUua2V5ID09PSAnRXNjYXBlJyB8fCBlLmtleSA9PT0gJ0VzYycp
;IHsKICAgICAgaWYgKGlzVmlkZW9GdWxsc2NyZWVuKCkpIHsKICAgICAgICBlLnByZXZlbnREZWZhdWx0KCk7CiAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24o
;KTsKICAgICAgICBleGl0VmlkZW9GdWxsc2NyZWVuKCk7CiAgICAgICAgcG9zdCgnZXNjQ29uc3VtZWQnKTsKICAgICAgfQogICAgfQogIH0sIHRydWUpOwog
;IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdidG4tc29ydCcpLm9uY2xpY2sgPSAoKSA9PiB7CiAgICBzb3J0ID0gc29ydCA9PT0gJ2RhdGUtZGVzYycgPyAn
;ZGF0ZS1hc2MnIDogKHNvcnQgPT09ICdkYXRlLWFzYycgPyAnbmFtZS1hc2MnIDogKHNvcnQgPT09ICduYW1lLWFzYycgPyAnc2l6ZS1kZXNjJyA6ICdkYXRl
;LWRlc2MnKSk7CiAgICBjb25zdCBtYXAgPSB7CiAgICAgICdkYXRlLWRlc2MnOiAn5oyJ5L+u5pS55pe26Ze06ZmN5bqPJywKICAgICAgJ2RhdGUtYXNjJzog
;J+aMieS/ruaUueaXtumXtOWNh+W6jycsCiAgICAgICduYW1lLWFzYyc6ICfmjInlkI3np7DljYfluo8nLAogICAgICAnc2l6ZS1kZXNjJzogJ+aMieWkp+Ww
;j+mZjeW6jycKICAgIH07CiAgICBzb3J0TGFiZWwudGV4dENvbnRlbnQgPSBtYXBbc29ydF0gfHwgc29ydDsKICAgIGRvU2VhcmNoKCk7CiAgICBpZiAodHlw
;ZW9mIHNhdmVTZXNzaW9uU29vbiA9PT0gJ2Z1bmN0aW9uJykgc2F2ZVNlc3Npb25Tb29uKCk7CiAgfTsKICBjaGtQcmV2aWV3LmFkZEV2ZW50TGlzdGVuZXIo
;J2NoYW5nZScsICgpID0+IHsKICAgIHRleHRTZWFyY2hPbiA9ICEhY2hrUHJldmlldy5jaGVja2VkOwogICAgcHJldmlldy5jbGFzc0xpc3QudG9nZ2xlKCdv
;ZmYnLCAhdGV4dFNlYXJjaE9uKTsKICAgIGlmICh0ZXh0U2VhcmNoT24pIHsKICAgICAgaWYgKHFFbCkgcUVsLnBsYWNlaG9sZGVyID0gJ+i+k+WFpeimgeaQ
;nOe0oueahOaWh+acrOWGheWuue+8m3wg6KGo56S65LiU77yMfHwg6KGo56S65oiWJzsKICAgIH0gZWxzZSBpZiAocUVsKSB7CiAgICAgIHFFbC5wbGFjZWhv
;bGRlciA9IFBMQUNFSE9MREVSX0ZJTEU7CiAgICB9CiAgICAvLyDlvIDlkK8v5YWz6Zet6YO956uL5Yi75oyJ5b2T5YmN5qih5byP6YeN5pCc77yI5byA5ZCv
;5pe255SoIGNvbnRlbnQ6IOaQnOi+k+WFpeahhuWGheWuue+8iQogICAgaWYgKGFwcE1vZGUgPT09ICdmaWxlJykgewogICAgICBkb1NlYXJjaCgpOwogICAg
;ICBpZiAodGV4dFNlYXJjaE9uICYmIHNlbGVjdGVkID49IDAgJiYgaXRlbXNbc2VsZWN0ZWRdKSByZXF1ZXN0UHJldmlldyhpdGVtc1tzZWxlY3RlZF0pOwog
;ICAgfQogICAgaWYgKHR5cGVvZiBzYXZlU2Vzc2lvblNvb24gPT09ICdmdW5jdGlvbicpIHNhdmVTZXNzaW9uU29vbigpOwogIH0pOwogIGRvY3VtZW50Lmdl
;dEVsZW1lbnRCeUlkKCdidG4tc2V0dGluZ3MnKS5vbmNsaWNrID0gKCkgPT4gb3BlbkZpbHRlclNldHRpbmdzKCk7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5
;SWQoJ3RvcCcpLmFkZEV2ZW50TGlzdGVuZXIoJ21vdXNlZG93bicsIGUgPT4gewogICAgaWYgKGUuYnV0dG9uICE9PSAwKSByZXR1cm47CiAgICBpZiAoZS50
;YXJnZXQuY2xvc2VzdCgnLm5vLWRyYWcnKSkgcmV0dXJuOwogICAgY2FsbEhvc3QoJ2RyYWcnKTsKICAgIHBvc3QoJ2RyYWcnKTsKICB9KTsKICBpZiAodGl0
;bGViYXIpIHsKICAgIHRpdGxlYmFyLmFkZEV2ZW50TGlzdGVuZXIoJ21vdXNlZG93bicsIGUgPT4gewogICAgICBpZiAoZS5idXR0b24gIT09IDApIHJldHVy
;bjsKICAgICAgaWYgKGUudGFyZ2V0LmNsb3Nlc3QoJy5uby1kcmFnJykpIHJldHVybjsKICAgICAgY2FsbEhvc3QoJ2RyYWcnKTsKICAgICAgcG9zdCgnZHJh
;ZycpOwogICAgfSk7CiAgICB0aXRsZWJhci5hZGRFdmVudExpc3RlbmVyKCdkYmxjbGljaycsIGUgPT4gewogICAgICBpZiAoZS50YXJnZXQuY2xvc2VzdCgn
;Lm5vLWRyYWcnKSkgcmV0dXJuOwogICAgICBjYWxsSG9zdCgnbWF4aW1pemUnKTsKICAgICAgcG9zdCgnbWF4aW1pemUnKTsKICAgIH0pOwogIH0KICBjb25z
;dCBidG5XaW5NaW4gPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYnRuLXdpbi1taW4nKTsKICBjb25zdCBidG5XaW5NYXggPSBkb2N1bWVudC5nZXRFbGVt
;ZW50QnlJZCgnYnRuLXdpbi1tYXgnKTsKICBjb25zdCBidG5XaW5DbG9zZSA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdidG4td2luLWNsb3NlJyk7CiAg
;aWYgKGJ0bldpbk1pbikgYnRuV2luTWluLm9uY2xpY2sgPSAoKSA9PiB7IGNhbGxIb3N0KCdtaW5pbWl6ZScpOyBwb3N0KCdtaW5pbWl6ZScpOyB9OwogIGlm
;IChidG5XaW5NYXgpIGJ0bldpbk1heC5vbmNsaWNrID0gKCkgPT4geyBjYWxsSG9zdCgnbWF4aW1pemUnKTsgcG9zdCgnbWF4aW1pemUnKTsgfTsKICBpZiAo
;YnRuV2luQ2xvc2UpIGJ0bldpbkNsb3NlLm9uY2xpY2sgPSAoKSA9PiB7IGNhbGxIb3N0KCdjbG9zZScpOyBwb3N0KCdjbG9zZScpOyB9OwoKICAvLyDilIDi
;lIAg5pCc57Si562b6YCJ77yI5ZCN56ew5qCH562+IC8g6Lev5b6E5qCH562+77yJ4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA
;4pSA4pSACiAgY29uc3QgRklMVEVSX1NUT1JFX0tFWSA9ICdsb2NhbF9zZWFyY2hfZmlsdGVyc192Myc7CiAgY29uc3QgRklMVEVSX1NUT1JFX0xFR0FDWV9W
;MiA9ICdsb2NhbF9zZWFyY2hfZmlsdGVyc192Mic7CiAgY29uc3QgRklMVEVSX1NUT1JFX0xFR0FDWSA9ICdsb2NhbF9zZWFyY2hfZmlsdGVyc192MSc7CiAg
;Y29uc3QgRklMVEVSX0FDVElWRV9LRVkgPSAnbG9jYWxfc2VhcmNoX2ZpbHRlcnNfYWN0aXZlX3YxJzsKICBjb25zdCBCVUlMVElOX0ZJTFRFUlMgPSBbCiAg
;ICB7IGlkOiAnemgnLCB0aXRsZTogJ+WQq+S4reaWhycsIGtpbmQ6ICduYW1lJywgcmVnZXg6ICdbXFx4ezRlMDB9LVxceHs5ZmZmfV0nLCBwYXRoOiAnJywg
;YnVpbHRpbjogdHJ1ZSwgZW5hYmxlZDogdHJ1ZSB9LAogICAgeyBpZDogJ25vdW5kZXInLCB0aXRsZTogJ+mdnuS4i+WIkue6v+W8gOWktCcsIGtpbmQ6ICdu
;YW1lJywgcmVnZXg6ICdeW15fXScsIHBhdGg6ICcnLCBidWlsdGluOiB0cnVlLCBlbmFibGVkOiB0cnVlIH0KICBdOwogIGNvbnN0IFNWR19YID0gJzxzdmcg
;dmlld0JveD0iMCAwIDEyIDEyIiBmaWxsPSJub25lIiBhcmlhLWhpZGRlbj0idHJ1ZSI+PHBhdGggZD0iTTMgM2w2IDZNOSAzTDMgOSIgc3Ryb2tlPSJjdXJy
;ZW50Q29sb3IiIHN0cm9rZS13aWR0aD0iMS40IiBzdHJva2UtbGluZWNhcD0icm91bmQiLz48L3N2Zz4nOwogIGNvbnN0IFNWR19VUCA9ICc8c3ZnIHZpZXdC
;b3g9IjAgMCAxMiAxMiIgZmlsbD0ibm9uZSIgYXJpYS1oaWRkZW49InRydWUiPjxwYXRoIGQ9Ik02IDMuMkwyLjggNy4yaDYuNEw2IDMuMnoiIGZpbGw9ImN1
;cnJlbnRDb2xvciIvPjwvc3ZnPic7CiAgY29uc3QgU1ZHX0ROID0gJzxzdmcgdmlld0JveD0iMCAwIDEyIDEyIiBmaWxsPSJub25lIiBhcmlhLWhpZGRlbj0i
;dHJ1ZSI+PHBhdGggZD0iTTYgOC44bDMuMi00SDIuOEw2IDguOHoiIGZpbGw9ImN1cnJlbnRDb2xvciIvPjwvc3ZnPic7CiAgY29uc3QgU1ZHX0NISVBfVEFH
;ID0gJzxzdmcgdmlld0JveD0iMCAwIDE2IDE2IiBmaWxsPSJub25lIiBzdHJva2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIxLjUiIHN0cm9rZS1s
;aW5lY2FwPSJyb3VuZCIgc3Ryb2tlLWxpbmVqb2luPSJyb3VuZCIgYXJpYS1oaWRkZW49InRydWUiPjxwYXRoIGQ9Ik0xMy43IDguN2wtNSA1YTEuNCAxLjQg
;MCAwIDEtMiAwTDIuMyA5LjNhMS40IDEuNCAwIDAgMSAwLTJMNy4zIDIuM2ExLjQgMS40IDAgMCAxIDEtLjRIMTJhMS40IDEuNCAwIDAgMSAxLjQgMS40djMu
;N2ExLjQgMS40IDAgMCAxLS40IDF6Ii8+PGNpcmNsZSBjeD0iMTAuNiIgY3k9IjUuNCIgcj0iMC45IiBmaWxsPSJjdXJyZW50Q29sb3IiIHN0cm9rZT0ibm9u
;ZSIvPjwvc3ZnPic7CiAgY29uc3QgU1ZHX0NISVBfRk9MREVSID0gJzxzdmcgdmlld0JveD0iMCAwIDE2IDE2IiBmaWxsPSJub25lIiBzdHJva2U9ImN1cnJl
;bnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIxLjUiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIgc3Ryb2tlLWxpbmVqb2luPSJyb3VuZCIgYXJpYS1oaWRkZW49InRy
;dWUiPjxwYXRoIGQ9Ik0yLjUgNS4yQTEuMiAxLjIgMCAwIDEgMy43IDRoMi4xbDEuMiAxLjJoNS4zQTEuMiAxLjIgMCAwIDEgMTMuNSA2LjR2NS40QTEuMiAx
;LjIgMCAwIDEgMTIuMyAxM0gzLjdBMS4yIDEuMiAwIDAgMSAyLjUgMTEuOFY1LjJ6Ii8+PC9zdmc+JzsKICBjb25zdCBmaWx0ZXJSYWlsID0gZG9jdW1lbnQu
;Z2V0RWxlbWVudEJ5SWQoJ2ZpbHRlci1yYWlsJyk7CiAgY29uc3QgZmlsdGVyQmFyID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2ZpbHRlci1iYXInKTsK
;ICBjb25zdCBmaWx0ZXJTZXR0aW5ncyA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdmaWx0ZXItc2V0dGluZ3MnKTsKICBsZXQgZmlsdGVySXRlbXMgPSBb
;XTsKICBsZXQgYWN0aXZlRmlsdGVySWRzID0gbmV3IFNldCgpOwogIGxldCBmc1RhYktpbmQgPSAnbmFtZSc7CgogIGZ1bmN0aW9uIGNsb25lQnVpbHRpbkRl
;ZmF1bHRzKCkgewogICAgcmV0dXJuIEJVSUxUSU5fRklMVEVSUy5tYXAoeCA9PiAoewogICAgICBpZDogeC5pZCwgdGl0bGU6IHgudGl0bGUsIGtpbmQ6ICdu
;YW1lJywgcmVnZXg6IHgucmVnZXgsIHBhdGg6ICcnLCBidWlsdGluOiB0cnVlLCBlbmFibGVkOiB0cnVlCiAgICB9KSk7CiAgfQogIGZ1bmN0aW9uIG5vcm1h
;bGl6ZUZpbHRlckl0ZW0oeCwgZm9yY2VCdWlsdGluKSB7CiAgICBpZiAoIXggfHwgIXguaWQgfHwgIXgudGl0bGUpIHJldHVybiBudWxsOwogICAgY29uc3Qg
;aWQgPSBTdHJpbmcoeC5pZCk7CiAgICBjb25zdCBraW5kID0gKHgua2luZCA9PT0gJ3BhdGgnKSA/ICdwYXRoJyA6ICduYW1lJzsKICAgIGNvbnN0IGJ1aWx0
;aW4gPSBmb3JjZUJ1aWx0aW4gIT0gbnVsbCA/ICEhZm9yY2VCdWlsdGluIDogKCEheC5idWlsdGluIHx8IGlkID09PSAnemgnIHx8IGlkID09PSAnbm91bmRl
;cicpOwogICAgaWYgKGtpbmQgPT09ICdwYXRoJykgewogICAgICBjb25zdCBwYXRoID0gU3RyaW5nKHgucGF0aCB8fCB4LnJlZ2V4IHx8ICcnKS50cmltKCku
;c2xpY2UoMCwgMjYwKTsKICAgICAgaWYgKCFwYXRoKSByZXR1cm4gbnVsbDsKICAgICAgcmV0dXJuIHsKICAgICAgICBpZCwKICAgICAgICB0aXRsZTogU3Ry
;aW5nKHgudGl0bGUpLnNsaWNlKDAsIDI0KSwKICAgICAgICBraW5kOiAncGF0aCcsCiAgICAgICAgcmVnZXg6ICcnLAogICAgICAgIHBhdGgsCiAgICAgICAg
;YnVpbHRpbjogZmFsc2UsCiAgICAgICAgZW5hYmxlZDogeC5lbmFibGVkICE9PSBmYWxzZQogICAgICB9OwogICAgfQogICAgaWYgKCF4LnJlZ2V4KSByZXR1
;cm4gbnVsbDsKICAgIHJldHVybiB7CiAgICAgIGlkLAogICAgICB0aXRsZTogU3RyaW5nKHgudGl0bGUpLnNsaWNlKDAsIDI0KSwKICAgICAga2luZDogJ25h
;bWUnLAogICAgICByZWdleDogU3RyaW5nKHgucmVnZXgpLnNsaWNlKDAsIDIwMCksCiAgICAgIHBhdGg6ICcnLAogICAgICBidWlsdGluLAogICAgICBlbmFi
;bGVkOiB4LmVuYWJsZWQgIT09IGZhbHNlCiAgICB9OwogIH0KICBmdW5jdGlvbiBsb2FkRmlsdGVyU3RhdGUoKSB7CiAgICBmaWx0ZXJJdGVtcyA9IFtdOwog
;ICAgdHJ5IHsKICAgICAgY29uc3QgcmF3ID0gbG9jYWxTdG9yYWdlLmdldEl0ZW0oRklMVEVSX1NUT1JFX0tFWSk7CiAgICAgIGlmIChyYXcpIHsKICAgICAg
;ICBjb25zdCBhcnIgPSBKU09OLnBhcnNlKHJhdyk7CiAgICAgICAgaWYgKEFycmF5LmlzQXJyYXkoYXJyKSAmJiBhcnIubGVuZ3RoKSB7CiAgICAgICAgICBm
;aWx0ZXJJdGVtcyA9IGFyci5tYXAoeCA9PiBub3JtYWxpemVGaWx0ZXJJdGVtKHgpKS5maWx0ZXIoQm9vbGVhbik7CiAgICAgICAgfQogICAgICB9CiAgICB9
;IGNhdGNoIChfKSB7IGZpbHRlckl0ZW1zID0gW107IH0KICAgIGlmICghZmlsdGVySXRlbXMubGVuZ3RoKSB7CiAgICAgIGxldCBsZWdhY3kgPSBbXTsKICAg
;ICAgdHJ5IHsKICAgICAgICBjb25zdCByYXcgPSBsb2NhbFN0b3JhZ2UuZ2V0SXRlbShGSUxURVJfU1RPUkVfTEVHQUNZX1YyKSB8fCBsb2NhbFN0b3JhZ2Uu
;Z2V0SXRlbShGSUxURVJfU1RPUkVfTEVHQUNZKTsKICAgICAgICBjb25zdCBhcnIgPSByYXcgPyBKU09OLnBhcnNlKHJhdykgOiBbXTsKICAgICAgICBsZWdh
;Y3kgPSBBcnJheS5pc0FycmF5KGFycikgPyBhcnIubWFwKHggPT4gbm9ybWFsaXplRmlsdGVySXRlbSh4KSkuZmlsdGVyKEJvb2xlYW4pIDogW107CiAgICAg
;IH0gY2F0Y2ggKF8pIHsgbGVnYWN5ID0gW107IH0KICAgICAgaWYgKGxlZ2FjeS5sZW5ndGgpIHsKICAgICAgICBjb25zdCBoYXNCdWlsdGluID0gbGVnYWN5
;LnNvbWUoeCA9PiB4LmJ1aWx0aW4pOwogICAgICAgIGZpbHRlckl0ZW1zID0gaGFzQnVpbHRpbiA/IGxlZ2FjeSA6IGNsb25lQnVpbHRpbkRlZmF1bHRzKCku
;Y29uY2F0KGxlZ2FjeSk7CiAgICAgIH0gZWxzZSB7CiAgICAgICAgZmlsdGVySXRlbXMgPSBjbG9uZUJ1aWx0aW5EZWZhdWx0cygpOwogICAgICB9CiAgICAg
;IHNhdmVGaWx0ZXJJdGVtcygpOwogICAgfQogICAgdHJ5IHsKICAgICAgY29uc3QgcmF3ID0gbG9jYWxTdG9yYWdlLmdldEl0ZW0oRklMVEVSX0FDVElWRV9L
;RVkpOwogICAgICBjb25zdCBhcnIgPSByYXcgPyBKU09OLnBhcnNlKHJhdykgOiBbXTsKICAgICAgYWN0aXZlRmlsdGVySWRzID0gbmV3IFNldChBcnJheS5p
;c0FycmF5KGFycikgPyBhcnIubWFwKFN0cmluZykgOiBbXSk7CiAgICB9IGNhdGNoIChfKSB7IGFjdGl2ZUZpbHRlcklkcyA9IG5ldyBTZXQoKTsgfQogIH0K
;ICBmdW5jdGlvbiBzYXZlRmlsdGVySXRlbXMoKSB7CiAgICB0cnkgeyBsb2NhbFN0b3JhZ2Uuc2V0SXRlbShGSUxURVJfU1RPUkVfS0VZLCBKU09OLnN0cmlu
;Z2lmeShmaWx0ZXJJdGVtcykpOyB9IGNhdGNoIChfKSB7fQogIH0KICBmdW5jdGlvbiBzYXZlQWN0aXZlRmlsdGVycygpIHsKICAgIHRyeSB7IGxvY2FsU3Rv
;cmFnZS5zZXRJdGVtKEZJTFRFUl9BQ1RJVkVfS0VZLCBKU09OLnN0cmluZ2lmeShBcnJheS5mcm9tKGFjdGl2ZUZpbHRlcklkcykpKTsgfSBjYXRjaCAoXykg
;e30KICB9CiAgZnVuY3Rpb24gdmlzaWJsZUZpbHRlcnMoKSB7CiAgICByZXR1cm4gZmlsdGVySXRlbXMuZmlsdGVyKGYgPT4gZi5lbmFibGVkICE9PSBmYWxz
;ZSk7CiAgfQogIGZ1bmN0aW9uIGRyaXZlTGV0dGVyRnJvbVBhdGgocCkgewogICAgY29uc3QgbSA9IFN0cmluZyhwIHx8ICcnKS50cmltKCkubWF0Y2goL14o
;W0EtWmEtel0pOi8pOwogICAgcmV0dXJuIG0gPyBtWzFdLnRvVXBwZXJDYXNlKCkgOiAnJzsKICB9CiAgZnVuY3Rpb24gc3luY0RyaXZlRnJvbVBhdGhUYWco
;ZikgewogICAgaWYgKCFmIHx8IGYua2luZCAhPT0gJ3BhdGgnKSByZXR1cm47CiAgICBjb25zdCBsZXR0ZXIgPSBkcml2ZUxldHRlckZyb21QYXRoKGYucGF0
;aCk7CiAgICBpZiAoIWxldHRlcikgcmV0dXJuOwogICAgZHJpdmUgPSBsZXR0ZXI7CiAgICB0cnkgeyBzeW5jRHJpdmVCdXR0b24oKTsgcmVuZGVyRHJpdmVN
;ZW51KCk7IH0gY2F0Y2ggKF8pIHt9CiAgfQogIGZ1bmN0aW9uIGNvbnRlbnRTZWFyY2hUZXJtKHEpIHsKICAgIGNvbnN0IHNhZmUgPSBTdHJpbmcocSB8fCAn
;JykudHJpbSgpLnJlcGxhY2UoLyIvZywgJycpOwogICAgaWYgKCFzYWZlKSByZXR1cm4gJyc7CiAgICBpZiAoL1xzLy50ZXN0KHNhZmUpKSByZXR1cm4gJ2Nv
;bnRlbnQ6IicgKyBzYWZlICsgJyInOwogICAgcmV0dXJuICdjb250ZW50OicgKyBzYWZlOwogIH0KICBmdW5jdGlvbiBjb21wb3NlU2VhcmNoUXVlcnkoKSB7
;CiAgICBjb25zdCBwYXJ0cyA9IFtdOwogICAgY29uc3QgcSA9IFN0cmluZyhxRWwudmFsdWUgfHwgJycpLnRyaW0oKTsKICAgIGlmIChxKSB7CiAgICAgIGlm
;ICh0ZXh0U2VhcmNoT24pIHsKICAgICAgICAvLyDmjInovpPlhaXmoYblhoXlrrnlgZogY29udGVudDog5pCc57Si77yIfCDkuJTvvIx8fCDmiJbvvIkKICAg
;ICAgICBpZiAocS5pbmRleE9mKCd8fCcpID49IDApIHsKICAgICAgICAgIGNvbnN0IGdyb3VwcyA9IHEuc3BsaXQoJ3x8JykubWFwKHMgPT4gcy50cmltKCkp
;LmZpbHRlcihCb29sZWFuKQogICAgICAgICAgICAubWFwKGNvbnRlbnRTZWFyY2hUZXJtKS5maWx0ZXIoQm9vbGVhbik7CiAgICAgICAgICBpZiAoZ3JvdXBz
;Lmxlbmd0aCkgcGFydHMucHVzaChncm91cHMuam9pbignfHwnKSk7CiAgICAgICAgfSBlbHNlIGlmIChxLmluZGV4T2YoJ3wnKSA+PSAwKSB7CiAgICAgICAg
;ICBxLnNwbGl0KCd8JykubWFwKHMgPT4gcy50cmltKCkpLmZpbHRlcihCb29sZWFuKS5mb3JFYWNoKHNlZyA9PiB7CiAgICAgICAgICAgIGNvbnN0IGN0ID0g
;Y29udGVudFNlYXJjaFRlcm0oc2VnKTsKICAgICAgICAgICAgaWYgKGN0KSBwYXJ0cy5wdXNoKGN0KTsKICAgICAgICAgIH0pOwogICAgICAgIH0gZWxzZSB7
;CiAgICAgICAgICBjb25zdCBjdCA9IGNvbnRlbnRTZWFyY2hUZXJtKHEpOwogICAgICAgICAgaWYgKGN0KSBwYXJ0cy5wdXNoKGN0KTsKICAgICAgICB9CiAg
;ICAgIH0gZWxzZSB7CiAgICAgICAgcGFydHMucHVzaChxKTsKICAgICAgfQogICAgfQogICAgZm9yIChjb25zdCBmIG9mIHZpc2libGVGaWx0ZXJzKCkpIHsK
;ICAgICAgaWYgKCFhY3RpdmVGaWx0ZXJJZHMuaGFzKGYuaWQpKSBjb250aW51ZTsKICAgICAgaWYgKGYua2luZCA9PT0gJ3BhdGgnKSB7CiAgICAgICAgY29u
;c3QgcCA9IFN0cmluZyhmLnBhdGggfHwgJycpLnRyaW0oKS5yZXBsYWNlKC8iL2csICcnKTsKICAgICAgICBpZiAoIXApIGNvbnRpbnVlOwogICAgICAgIC8v
;IOi3r+W+hOagh+etvu+8mumZkOWItuWcqOivpeebruW9lS/ot6/lvoTkuIsKICAgICAgICBwYXJ0cy5wdXNoKC9ccy8udGVzdChwKSA/ICgnIicgKyBwICsg
;JyInKSA6IHApOwogICAgICB9IGVsc2UgewogICAgICAgIGNvbnN0IHJlID0gU3RyaW5nKGYucmVnZXggfHwgJycpLnRyaW0oKTsKICAgICAgICBpZiAoIXJl
;KSBjb250aW51ZTsKICAgICAgICBwYXJ0cy5wdXNoKCdyZWdleDonICsgcmUucmVwbGFjZSgvXHMrL2csICcnKSk7CiAgICAgIH0KICAgIH0KICAgIHJldHVy
;biBwYXJ0cy5qb2luKCd8Jyk7CiAgfQogIGZ1bmN0aW9uIHN5bmNGaWx0ZXJUb2dnbGVVaSgpIHt9CiAgZnVuY3Rpb24gc3luY1RpdGxlUmFpbE1vZGUoKSB7
;CiAgICBpZiAoIWFwcFJvb3QpIHJldHVybjsKICAgIGFwcFJvb3QuY2xhc3NMaXN0LnJlbW92ZSgncmFpbC1maWxlJywgJ3JhaWwtaGFuZGxlJywgJ3JhaWwt
;Y29uZmlnJyk7CiAgICBpZiAoYXBwTW9kZSA9PT0gJ2ZpbGUnKSBhcHBSb290LmNsYXNzTGlzdC5hZGQoJ3JhaWwtZmlsZScpOwogICAgZWxzZSBpZiAoYXBw
;TW9kZSA9PT0gJ2hhbmRsZScpIGFwcFJvb3QuY2xhc3NMaXN0LmFkZCgncmFpbC1oYW5kbGUnKTsKICAgIGVsc2UgaWYgKGFwcE1vZGUgPT09ICdjb25maWcn
;KSBhcHBSb290LmNsYXNzTGlzdC5hZGQoJ3JhaWwtY29uZmlnJyk7CiAgICBjb25zdCBhZGRCdG4gPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnZmlsdGVy
;LWFkZCcpOwogICAgaWYgKGFkZEJ0bikgewogICAgICBpZiAoYXBwTW9kZSA9PT0gJ2hhbmRsZScpIGFkZEJ0bi50aXRsZSA9ICfnrqHnkIbmkJzntKLmoIfn
;rb4nOwogICAgICBlbHNlIGFkZEJ0bi50aXRsZSA9ICfnrqHnkIbnrZvpgInmoIfnrb4nOwogICAgfQogIH0KICBmdW5jdGlvbiByZW5kZXJGaWx0ZXJCYXIo
;KSB7CiAgICBpZiAoIWZpbHRlckJhcikgcmV0dXJuOwogICAgZmlsdGVyQmFyLmlubmVySFRNTCA9ICcnOwogICAgZm9yIChjb25zdCBmIG9mIHZpc2libGVG
;aWx0ZXJzKCkpIHsKICAgICAgY29uc3QgYnRuID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnYnV0dG9uJyk7CiAgICAgIGJ0bi50eXBlID0gJ2J1dHRvbic7
;CiAgICAgIGNvbnN0IGlzUGF0aCA9IGYua2luZCA9PT0gJ3BhdGgnOwogICAgICBidG4uY2xhc3NOYW1lID0gJ2ZpbHRlci1jaGlwJyArIChpc1BhdGggPyAn
;IHBhdGgtY2hpcCcgOiAnJykgKyAoYWN0aXZlRmlsdGVySWRzLmhhcyhmLmlkKSA/ICcgb24nIDogJycpOwogICAgICBidG4udGl0bGUgPSBpc1BhdGggPyAo
;J+i3r+W+hDogJyArIGYucGF0aCkgOiAoJ3JlZ2V4OicgKyBmLnJlZ2V4KTsKICAgICAgYnRuLmlubmVySFRNTCA9IChpc1BhdGggPyBTVkdfQ0hJUF9GT0xE
;RVIgOiBTVkdfQ0hJUF9UQUcpCiAgICAgICAgKyAnPHNwYW4+JyArIGVzY2FwZUh0bWwoZi50aXRsZSkgKyAnPC9zcGFuPic7CiAgICAgIGJ0bi5vbmNsaWNr
;ID0gKCkgPT4gewogICAgICAgIGlmIChhY3RpdmVGaWx0ZXJJZHMuaGFzKGYuaWQpKSBhY3RpdmVGaWx0ZXJJZHMuZGVsZXRlKGYuaWQpOwogICAgICAgIGVs
;c2UgewogICAgICAgICAgYWN0aXZlRmlsdGVySWRzLmFkZChmLmlkKTsKICAgICAgICAgIGlmIChpc1BhdGgpIHN5bmNEcml2ZUZyb21QYXRoVGFnKGYpOwog
;ICAgICAgIH0KICAgICAgICBzYXZlQWN0aXZlRmlsdGVycygpOwogICAgICAgIHJlbmRlckZpbHRlckJhcigpOwogICAgICAgIGlmIChhcHBNb2RlID09PSAn
;ZmlsZScpIHsKICAgICAgICAgIGRvU2VhcmNoKCk7CiAgICAgICAgICBzeW5jRmlsZVNlYXJjaENsZWFyUGlsbCgpOwogICAgICAgIH0KICAgICAgICBpZiAo
;dHlwZW9mIHNhdmVTZXNzaW9uU29vbiA9PT0gJ2Z1bmN0aW9uJykgc2F2ZVNlc3Npb25Tb29uKCk7CiAgICAgIH07CiAgICAgIGZpbHRlckJhci5hcHBlbmRD
;aGlsZChidG4pOwogICAgfQogICAgc3luY0ZpbHRlclRvZ2dsZVVpKCk7CiAgfQogIGZ1bmN0aW9uIHN5bmNGc1RhYlVpKCkgewogICAgaWYgKGZpbHRlclNl
;dHRpbmdzKSB7CiAgICAgIGZpbHRlclNldHRpbmdzLmNsYXNzTGlzdC50b2dnbGUoJ3RhYi1wYXRoJywgZnNUYWJLaW5kID09PSAncGF0aCcpOwogICAgICBm
;aWx0ZXJTZXR0aW5ncy5jbGFzc0xpc3QudG9nZ2xlKCd0YWItbmFtZScsIGZzVGFiS2luZCAhPT0gJ3BhdGgnKTsKICAgIH0KICAgIGRvY3VtZW50LnF1ZXJ5
;U2VsZWN0b3JBbGwoJy5mcy10YWJbZGF0YS1mcy10YWJdJykuZm9yRWFjaChiID0+IHsKICAgICAgYi5jbGFzc0xpc3QudG9nZ2xlKCdvbicsIGIuZ2V0QXR0
;cmlidXRlKCdkYXRhLWZzLXRhYicpID09PSBmc1RhYktpbmQpOwogICAgfSk7CiAgICBjb25zdCBobiA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdmcy1o
;aW50LW5hbWUnKTsKICAgIGNvbnN0IGhwID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2ZzLWhpbnQtcGF0aCcpOwogICAgaWYgKGhuKSBobi5zdHlsZS5k
;aXNwbGF5ID0gZnNUYWJLaW5kID09PSAncGF0aCcgPyAnbm9uZScgOiAnJzsKICAgIGlmIChocCkgaHAuc3R5bGUuZGlzcGxheSA9IGZzVGFiS2luZCA9PT0g
;J3BhdGgnID8gJycgOiAnbm9uZSc7CiAgICBjb25zdCB0aXRsZSA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdmcy10aXRsZScpOwogICAgaWYgKHRpdGxl
;KSB0aXRsZS5wbGFjZWhvbGRlciA9IGZzVGFiS2luZCA9PT0gJ3BhdGgnID8gJ+S+i+Wmgu+8muW3peS9nOebruW9lScgOiAn5L6L5aaC77ya5LiN5ZCr5Li0
;5pe25paH5Lu2JzsKICB9CiAgZnVuY3Rpb24gbW92ZUZpbHRlckluS2luZChraW5kLCBsb2NhbElkeCwgZGlyKSB7CiAgICBjb25zdCBpZHhzID0gW107CiAg
;ICBmaWx0ZXJJdGVtcy5mb3JFYWNoKChmLCBpKSA9PiB7CiAgICAgIGlmICgoZi5raW5kIHx8ICduYW1lJykgPT09IGtpbmQpIGlkeHMucHVzaChpKTsKICAg
;IH0pOwogICAgY29uc3QgYSA9IGlkeHNbbG9jYWxJZHhdOwogICAgY29uc3QgYiA9IGlkeHNbbG9jYWxJZHggKyBkaXJdOwogICAgaWYgKGEgPT0gbnVsbCB8
;fCBiID09IG51bGwpIHJldHVybjsKICAgIGNvbnN0IHQgPSBmaWx0ZXJJdGVtc1thXTsKICAgIGZpbHRlckl0ZW1zW2FdID0gZmlsdGVySXRlbXNbYl07CiAg
;ICBmaWx0ZXJJdGVtc1tiXSA9IHQ7CiAgICBzYXZlRmlsdGVySXRlbXMoKTsKICAgIHJlbmRlckZpbHRlckJhcigpOwogICAgcmVuZGVyRmlsdGVyU2V0dGlu
;Z3NMaXN0KCk7CiAgfQogIGZ1bmN0aW9uIHJlbmRlckZpbHRlclNldHRpbmdzTGlzdCgpIHsKICAgIGNvbnN0IGxpc3QgPSBkb2N1bWVudC5nZXRFbGVtZW50
;QnlJZCgnZnMtbGlzdCcpOwogICAgaWYgKCFsaXN0KSByZXR1cm47CiAgICBsaXN0LmlubmVySFRNTCA9ICcnOwogICAgY29uc3Qga2luZCA9IGZzVGFiS2lu
;ZDsKICAgIGNvbnN0IHJvd3MgPSBmaWx0ZXJJdGVtcy5tYXAoKGYsIGlkeCkgPT4gKHsgZiwgaWR4IH0pKS5maWx0ZXIoeCA9PiAoeC5mLmtpbmQgfHwgJ25h
;bWUnKSA9PT0ga2luZCk7CiAgICBpZiAoIXJvd3MubGVuZ3RoKSB7CiAgICAgIGxpc3QuaW5uZXJIVE1MID0gJzxkaXYgY2xhc3M9ImZzLWhpbnQiIHN0eWxl
;PSJtYXJnaW46MCI+JwogICAgICAgICsgKGtpbmQgPT09ICdwYXRoJyA/ICfmmoLml6Dot6/lvoTmoIfnrb7vvIzlnKjkuIvmlrnmt7vliqDjgIInIDogJ+aa
;guaXoOWQjeensOagh+etvuOAgicpCiAgICAgICAgKyAnPC9kaXY+JzsKICAgICAgcmV0dXJuOwogICAgfQogICAgcm93cy5mb3JFYWNoKChyb3dJbmZvLCBs
;b2NhbElkeCkgPT4gewogICAgICBjb25zdCBmID0gcm93SW5mby5mOwogICAgICBjb25zdCBpZHggPSByb3dJbmZvLmlkeDsKICAgICAgY29uc3Qgcm93ID0g
;ZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnZGl2Jyk7CiAgICAgIHJvdy5jbGFzc05hbWUgPSAnZnMtYmxvY2snICsgKGYuZW5hYmxlZCA9PT0gZmFsc2UgPyAn
;IG9mZicgOiAnJyk7CgogICAgICBjb25zdCBvcmQgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsKICAgICAgb3JkLmNsYXNzTmFtZSA9ICdmcy1v
;cmQnOwogICAgICBjb25zdCB1cCA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2J1dHRvbicpOwogICAgICB1cC50eXBlID0gJ2J1dHRvbic7CiAgICAgIHVw
;LnRpdGxlID0gJ+S4iuenuyc7CiAgICAgIHVwLmlubmVySFRNTCA9IFNWR19VUDsKICAgICAgdXAuZGlzYWJsZWQgPSBsb2NhbElkeCA9PT0gMDsKICAgICAg
;dXAub25jbGljayA9ICgpID0+IG1vdmVGaWx0ZXJJbktpbmQoa2luZCwgbG9jYWxJZHgsIC0xKTsKICAgICAgY29uc3QgZG4gPSBkb2N1bWVudC5jcmVhdGVF
;bGVtZW50KCdidXR0b24nKTsKICAgICAgZG4udHlwZSA9ICdidXR0b24nOwogICAgICBkbi50aXRsZSA9ICfkuIvnp7snOwogICAgICBkbi5pbm5lckhUTUwg
;PSBTVkdfRE47CiAgICAgIGRuLmRpc2FibGVkID0gbG9jYWxJZHggPT09IHJvd3MubGVuZ3RoIC0gMTsKICAgICAgZG4ub25jbGljayA9ICgpID0+IG1vdmVG
;aWx0ZXJJbktpbmQoa2luZCwgbG9jYWxJZHgsIDEpOwogICAgICBvcmQuYXBwZW5kQ2hpbGQodXApOwogICAgICBvcmQuYXBwZW5kQ2hpbGQoZG4pOwoKICAg
;ICAgY29uc3QgbWFpbiA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOwogICAgICBtYWluLmNsYXNzTmFtZSA9ICdmcy1tYWluJzsKICAgICAgY29u
;c3QgZGV0YWlsID0gZi5raW5kID09PSAncGF0aCcgPyAoZi5wYXRoIHx8ICcnKSA6IChmLnJlZ2V4IHx8ICcnKTsKICAgICAgbWFpbi5pbm5lckhUTUwgPSAn
;PGRpdiBjbGFzcz0iZnMtdGl0bGUtcm93Ij48c3BhbiBjbGFzcz0iZnMtdGl0bGUiPicgKyBlc2NhcGVIdG1sKGYudGl0bGUpICsgJzwvc3Bhbj4nCiAgICAg
;ICAgKyAoZi5idWlsdGluID8gJzxzcGFuIGNsYXNzPSJmcy10YWciPuWGhee9rjwvc3Bhbj4nIDogJycpCiAgICAgICAgKyAoZi5raW5kID09PSAncGF0aCcg
;PyAnPHNwYW4gY2xhc3M9ImZzLXRhZyI+6Lev5b6EPC9zcGFuPicgOiAnJykKICAgICAgICArICc8L2Rpdj48ZGl2IGNsYXNzPSJmcy1yZWdleCIgdGl0bGU9
;IicgKyBlc2NhcGVBdHRyKGRldGFpbCkgKyAnIj4nICsgZXNjYXBlSHRtbChkZXRhaWwpICsgJzwvZGl2Pic7CgogICAgICBjb25zdCBlbldyYXAgPSBkb2N1
;bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsKICAgICAgZW5XcmFwLmNsYXNzTmFtZSA9ICdmcy1lbic7CiAgICAgIGNvbnN0IGxhYiA9IGRvY3VtZW50LmNy
;ZWF0ZUVsZW1lbnQoJ3NwYW4nKTsKICAgICAgbGFiLmNsYXNzTmFtZSA9ICdmcy1lbi1sYWInOwogICAgICBsYWIudGV4dENvbnRlbnQgPSBmLmVuYWJsZWQg
;PT09IGZhbHNlID8gJ+W3suemgeeUqCcgOiAn5bey5ZCv55SoJzsKICAgICAgY29uc3Qgc3cgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdidXR0b24nKTsK
;ICAgICAgc3cudHlwZSA9ICdidXR0b24nOwogICAgICBzdy5jbGFzc05hbWUgPSAnZnMtc3dpdGNoJyArIChmLmVuYWJsZWQgPT09IGZhbHNlID8gJycgOiAn
;IG9uJyk7CiAgICAgIHN3LnRpdGxlID0gZi5lbmFibGVkID09PSBmYWxzZSA/ICflkK/nlKgnIDogJ+emgeeUqCc7CiAgICAgIHN3LnNldEF0dHJpYnV0ZSgn
;YXJpYS1wcmVzc2VkJywgZi5lbmFibGVkICE9PSBmYWxzZSA/ICd0cnVlJyA6ICdmYWxzZScpOwogICAgICBzdy5pbm5lckhUTUwgPSAnPGk+PC9pPic7CiAg
;ICAgIHN3Lm9uY2xpY2sgPSAoKSA9PiB7CiAgICAgICAgZi5lbmFibGVkID0gZi5lbmFibGVkID09PSBmYWxzZTsKICAgICAgICBpZiAoZi5lbmFibGVkID09
;PSBmYWxzZSkgYWN0aXZlRmlsdGVySWRzLmRlbGV0ZShmLmlkKTsKICAgICAgICBzYXZlRmlsdGVySXRlbXMoKTsKICAgICAgICBzYXZlQWN0aXZlRmlsdGVy
;cygpOwogICAgICAgIHJlbmRlckZpbHRlckJhcigpOwogICAgICAgIHJlbmRlckZpbHRlclNldHRpbmdzTGlzdCgpOwogICAgICAgIGlmIChhcHBNb2RlID09
;PSAnZmlsZScpIGRvU2VhcmNoKCk7CiAgICAgIH07CiAgICAgIGVuV3JhcC5hcHBlbmRDaGlsZChsYWIpOwogICAgICBlbldyYXAuYXBwZW5kQ2hpbGQoc3cp
;OwoKICAgICAgY29uc3QgZGVsID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnYnV0dG9uJyk7CiAgICAgIGRlbC50eXBlID0gJ2J1dHRvbic7CiAgICAgIGRl
;bC5jbGFzc05hbWUgPSAnZnMtZGVsJzsKICAgICAgZGVsLnRpdGxlID0gJ+WIoOmZpCc7CiAgICAgIGRlbC5pbm5lckhUTUwgPSBTVkdfWDsKICAgICAgZGVs
;Lm9uY2xpY2sgPSAoKSA9PiB7CiAgICAgICAgZmlsdGVySXRlbXMgPSBmaWx0ZXJJdGVtcy5maWx0ZXIoeCA9PiB4LmlkICE9PSBmLmlkKTsKICAgICAgICBh
;Y3RpdmVGaWx0ZXJJZHMuZGVsZXRlKGYuaWQpOwogICAgICAgIHNhdmVGaWx0ZXJJdGVtcygpOwogICAgICAgIHNhdmVBY3RpdmVGaWx0ZXJzKCk7CiAgICAg
;ICAgcmVuZGVyRmlsdGVyQmFyKCk7CiAgICAgICAgcmVuZGVyRmlsdGVyU2V0dGluZ3NMaXN0KCk7CiAgICAgICAgaWYgKGFwcE1vZGUgPT09ICdmaWxlJykg
;ZG9TZWFyY2goKTsKICAgICAgfTsKCiAgICAgIHJvdy5hcHBlbmRDaGlsZChvcmQpOwogICAgICByb3cuYXBwZW5kQ2hpbGQobWFpbik7CiAgICAgIHJvdy5h
;cHBlbmRDaGlsZChlbldyYXApOwogICAgICByb3cuYXBwZW5kQ2hpbGQoZGVsKTsKICAgICAgbGlzdC5hcHBlbmRDaGlsZChyb3cpOwogICAgfSk7CiAgfQog
;IGZ1bmN0aW9uIHJlc2V0RmlsdGVyc1RvRGVmYXVsdCgpIHsKICAgIGZpbHRlckl0ZW1zID0gY2xvbmVCdWlsdGluRGVmYXVsdHMoKTsKICAgIGFjdGl2ZUZp
;bHRlcklkcyA9IG5ldyBTZXQoKTsKICAgIHNhdmVGaWx0ZXJJdGVtcygpOwogICAgc2F2ZUFjdGl2ZUZpbHRlcnMoKTsKICAgIHJlbmRlckZpbHRlckJhcigp
;OwogICAgcmVuZGVyRmlsdGVyU2V0dGluZ3NMaXN0KCk7CiAgICBpZiAoYXBwTW9kZSA9PT0gJ2ZpbGUnKSBkb1NlYXJjaCgpOwogIH0KICBmdW5jdGlvbiBv
;cGVuRmlsdGVyU2V0dGluZ3MoKSB7CiAgICBzeW5jRnNUYWJVaSgpOwogICAgcmVuZGVyRmlsdGVyU2V0dGluZ3NMaXN0KCk7CiAgICBpZiAoZmlsdGVyU2V0
;dGluZ3MpIGZpbHRlclNldHRpbmdzLmNsYXNzTGlzdC5hZGQoJ29uJyk7CiAgfQogIGZ1bmN0aW9uIGNsb3NlRmlsdGVyU2V0dGluZ3MoKSB7CiAgICBpZiAo
;ZmlsdGVyU2V0dGluZ3MpIGZpbHRlclNldHRpbmdzLmNsYXNzTGlzdC5yZW1vdmUoJ29uJyk7CiAgfQogIGxvYWRGaWx0ZXJTdGF0ZSgpOwogIHJlbmRlckZp
;bHRlckJhcigpOwogIGNvbnN0IGZpbHRlckFkZEJ0biA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdmaWx0ZXItYWRkJyk7CiAgaWYgKGZpbHRlckFkZEJ0
;bikgewogICAgZmlsdGVyQWRkQnRuLm9uY2xpY2sgPSAoZSkgPT4gewogICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgICBpZiAoYXBwTW9kZSA9PT0g
;J2hhbmRsZScpIG9wZW5IYW5kbGVUYWdQb3AoKTsKICAgICAgZWxzZSBvcGVuRmlsdGVyU2V0dGluZ3MoKTsKICAgIH07CiAgfQogIGRvY3VtZW50LnF1ZXJ5
;U2VsZWN0b3JBbGwoJy5mcy10YWJbZGF0YS1mcy10YWJdJykuZm9yRWFjaChidG4gPT4gewogICAgYnRuLmFkZEV2ZW50TGlzdGVuZXIoJ2NsaWNrJywgKCkg
;PT4gewogICAgICBmc1RhYktpbmQgPSBidG4uZ2V0QXR0cmlidXRlKCdkYXRhLWZzLXRhYicpID09PSAncGF0aCcgPyAncGF0aCcgOiAnbmFtZSc7CiAgICAg
;IHN5bmNGc1RhYlVpKCk7CiAgICAgIHJlbmRlckZpbHRlclNldHRpbmdzTGlzdCgpOwogICAgfSk7CiAgfSk7CiAgY29uc3QgZnNDbG9zZSA9IGRvY3VtZW50
;LmdldEVsZW1lbnRCeUlkKCdmcy1jbG9zZScpOwogIGlmIChmc0Nsb3NlKSBmc0Nsb3NlLm9uY2xpY2sgPSAoKSA9PiBjbG9zZUZpbHRlclNldHRpbmdzKCk7
;CiAgaWYgKGZpbHRlclNldHRpbmdzKSB7CiAgICBmaWx0ZXJTZXR0aW5ncy5hZGRFdmVudExpc3RlbmVyKCdjbGljaycsIGUgPT4gewogICAgICBpZiAoZS50
;YXJnZXQgPT09IGZpbHRlclNldHRpbmdzKSBjbG9zZUZpbHRlclNldHRpbmdzKCk7CiAgICB9KTsKICB9CiAgY29uc3QgZnNBZGQgPSBkb2N1bWVudC5nZXRF
;bGVtZW50QnlJZCgnZnMtYWRkJyk7CiAgaWYgKGZzQWRkKSB7CiAgICBmc0FkZC5vbmNsaWNrID0gKCkgPT4gewogICAgICBjb25zdCB0aXRsZSA9IFN0cmlu
;ZygoZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2ZzLXRpdGxlJykgfHwge30pLnZhbHVlIHx8ICcnKS50cmltKCk7CiAgICAgIGlmICghdGl0bGUpIHsgdHJ5
;IHsgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2ZzLXRpdGxlJykuZm9jdXMoKTsgfSBjYXRjaCAoXykge30gcmV0dXJuOyB9CiAgICAgIGNvbnN0IGlkID0g
;J2NfJyArIERhdGUubm93KCkudG9TdHJpbmcoMzYpICsgTWF0aC5yYW5kb20oKS50b1N0cmluZygzNikuc2xpY2UoMiwgNik7CiAgICAgIGlmIChmc1RhYktp
;bmQgPT09ICdwYXRoJykgewogICAgICAgIGNvbnN0IHBhdGggPSBTdHJpbmcoKGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdmcy1wYXRoJykgfHwge30pLnZh
;bHVlIHx8ICcnKS50cmltKCk7CiAgICAgICAgaWYgKCFwYXRoKSB7IHRyeSB7IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdmcy1wYXRoJykuZm9jdXMoKTsg
;fSBjYXRjaCAoXykge30gcmV0dXJuOyB9CiAgICAgICAgY29uc3QgaXRlbSA9IHsgaWQsIHRpdGxlOiB0aXRsZS5zbGljZSgwLCAyNCksIGtpbmQ6ICdwYXRo
;JywgcmVnZXg6ICcnLCBwYXRoOiBwYXRoLnNsaWNlKDAsIDI2MCksIGJ1aWx0aW46IGZhbHNlLCBlbmFibGVkOiB0cnVlIH07CiAgICAgICAgZmlsdGVySXRl
;bXMucHVzaChpdGVtKTsKICAgICAgICBhY3RpdmVGaWx0ZXJJZHMuYWRkKGlkKTsKICAgICAgICBzeW5jRHJpdmVGcm9tUGF0aFRhZyhpdGVtKTsKICAgICAg
;ICBjb25zdCBwID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2ZzLXBhdGgnKTsKICAgICAgICBpZiAocCkgcC52YWx1ZSA9ICcnOwogICAgICB9IGVsc2Ug
;ewogICAgICAgIGNvbnN0IHJlZ2V4ID0gU3RyaW5nKChkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnZnMtcmVnZXgnKSB8fCB7fSkudmFsdWUgfHwgJycpLnRy
;aW0oKTsKICAgICAgICBpZiAoIXJlZ2V4KSB7IHRyeSB7IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdmcy1yZWdleCcpLmZvY3VzKCk7IH0gY2F0Y2ggKF8p
;IHt9IHJldHVybjsgfQogICAgICAgIGZpbHRlckl0ZW1zLnB1c2goeyBpZCwgdGl0bGU6IHRpdGxlLnNsaWNlKDAsIDI0KSwga2luZDogJ25hbWUnLCByZWdl
;eDogcmVnZXguc2xpY2UoMCwgMjAwKSwgcGF0aDogJycsIGJ1aWx0aW46IGZhbHNlLCBlbmFibGVkOiB0cnVlIH0pOwogICAgICAgIGNvbnN0IHIgPSBkb2N1
;bWVudC5nZXRFbGVtZW50QnlJZCgnZnMtcmVnZXgnKTsKICAgICAgICBpZiAocikgci52YWx1ZSA9ICcnOwogICAgICB9CiAgICAgIHNhdmVGaWx0ZXJJdGVt
;cygpOwogICAgICBzYXZlQWN0aXZlRmlsdGVycygpOwogICAgICByZW5kZXJGaWx0ZXJCYXIoKTsKICAgICAgcmVuZGVyRmlsdGVyU2V0dGluZ3NMaXN0KCk7
;CiAgICAgIGlmIChhcHBNb2RlID09PSAnZmlsZScpIGRvU2VhcmNoKCk7CiAgICAgIGNvbnN0IHQgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnZnMtdGl0
;bGUnKTsKICAgICAgaWYgKHQpIHQudmFsdWUgPSAnJzsKICAgIH07CiAgfQogIGNvbnN0IGZzRXYgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnZnMtZXYt
;b3B0cycpOwogIGlmIChmc0V2KSBmc0V2Lm9uY2xpY2sgPSAoKSA9PiBwb3N0KCdzZXR0aW5ncycpOwogIGNvbnN0IGZzUmVzZXQgPSBkb2N1bWVudC5nZXRF
;bGVtZW50QnlJZCgnZnMtcmVzZXQnKTsKICBpZiAoZnNSZXNldCkgewogICAgZnNSZXNldC5vbmNsaWNrID0gYXN5bmMgKCkgPT4gewogICAgICBjb25zdCBv
;ayA9IGF3YWl0IHVpQ29uZmlybSgn5bCG6L+Y5Y6f5YaF572u5ZCN56ew5qCH562+77yM5bm25riF6Zmk6Ieq5a6a5LmJ5ZCN56ewL+i3r+W+hOagh+etvuOA
;gicsIHsKICAgICAgICB0aXRsZTogJ+aBouWkjem7mOiupOetm+mAiScsIG9rVGV4dDogJ+aBouWkjScsIGRhbmdlcjogdHJ1ZQogICAgICB9KTsKICAgICAg
;aWYgKCFvaykgcmV0dXJuOwogICAgICByZXNldEZpbHRlcnNUb0RlZmF1bHQoKTsKICAgIH07CiAgfQogIGRvY3VtZW50LmFkZEV2ZW50TGlzdGVuZXIoJ2tl
;eWRvd24nLCBlID0+IHsKICAgIGlmIChlLmtleSA9PT0gJ0VzY2FwZScgJiYgZmlsdGVyU2V0dGluZ3MgJiYgZmlsdGVyU2V0dGluZ3MuY2xhc3NMaXN0LmNv
;bnRhaW5zKCdvbicpKSB7CiAgICAgIGNsb3NlRmlsdGVyU2V0dGluZ3MoKTsKICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgIH0KICB9LCB0cnVlKTsK
;CiAgLy8g55SoIFVSTCA/YnA9IOW4puWFpSBBSEsg5b2T5YmN6L+b5bqm77yb5LiK6ZmQIDg477yM6YG/5YWN6aaW5bGP55u05o6lIDEwMCUg5YaN6Zeq6L+b
;5Li755WM6Z2iCiAgdHJ5IHsKICAgIGNvbnN0IGJwID0gTWF0aC5tYXgoOCwgTWF0aC5taW4oODgsIHBhcnNlSW50KG5ldyBVUkxTZWFyY2hQYXJhbXMobG9j
;YXRpb24uc2VhcmNoKS5nZXQoJ2JwJykgfHwgJzIwJywgMTApIHx8IDIwKSk7CiAgICBzZXRCb290UGN0KGJwKTsKICAgIGNvbnN0IHQxID0gZG9jdW1lbnQu
;cXVlcnlTZWxlY3RvcignI2Jvb3QgLnQxJyk7CiAgICBpZiAodDEgJiYgYnAgPj0gODApIHQxLnRleHRDb250ZW50ID0gJ+WNs+WwhuWujOaIkCc7CiAgICBl
;bHNlIGlmICh0MSAmJiBicCA+PSA0MCkgdDEudGV4dENvbnRlbnQgPSAn56OB55uY57Si5byV5LitJzsKICAgIGVsc2UgaWYgKHQxKSB0MS50ZXh0Q29udGVu
;dCA9ICfmraPlnKjliqDovb0nOwogIH0gY2F0Y2ggKGUpIHt9CgogIC8vIOKUgOKUgCDlhbPogZTlj6Xmn4QgLyDmnKzmnLrkv6Hmga/vvIjltYzlhaXkuLvl
;iJfooajljLrvvInilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIAKICBjb25zdCBpbmZvUGFuZWwgPSBkb2N1bWVudC5nZXRF
;bGVtZW50QnlJZCgnaW5mby1wYW5lbCcpOwogIGNvbnN0IGhhbmRsZVBhbmVsID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2hhbmRsZS1wYW5lbCcpOwog
;IGNvbnN0IGhhbmRsZUJvZHkgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnaGFuZGxlLWJvZHknKTsKICBjb25zdCBoYW5kbGVCYW5uZXIgPSBkb2N1bWVu
;dC5nZXRFbGVtZW50QnlJZCgnaGFuZGxlLWJhbm5lcicpOwogIGNvbnN0IGhhbmRsZVN0YXR1cyA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdoYW5kbGUt
;c3RhdHVzJyk7CiAgY29uc3QgYnRuUG9ydE1hcmsgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYnRuLXBvcnQtbWFyaycpOwogIGNvbnN0IHBvcnRNYXJr
;UG9wID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3BvcnQtbWFyay1wb3AnKTsKICBjb25zdCBwb3J0TWFya1RhZ3MgPSBkb2N1bWVudC5nZXRFbGVtZW50
;QnlJZCgncG9ydC1tYXJrLXRhZ3MnKTsKICBjb25zdCBwb3J0TWFya0lucHV0ID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3BvcnQtbWFyay1pbnB1dCcp
;OwogIGNvbnN0IGhhbmRsZVRhZ0JhciA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdoYW5kbGUtdGFnLWJhcicpOwogIGNvbnN0IGhhbmRsZVRhZ1BvcCA9
;IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdoYW5kbGUtdGFnLXBvcCcpOwogIGNvbnN0IGhhbmRsZVRhZ01hbmFnZSA9IGRvY3VtZW50LmdldEVsZW1lbnRC
;eUlkKCdoYW5kbGUtdGFnLW1hbmFnZScpOwogIGNvbnN0IHByb2NNZW51ID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3Byb2MtbWVudScpOwogIGNvbnN0
;IGZpbGVSZXN1bHRzID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2ZpbGUtcmVzdWx0cycpOwogIGNvbnN0IG1haW5FbCA9IGRvY3VtZW50LmdldEVsZW1l
;bnRCeUlkKCdtYWluJyk7CiAgY29uc3QgYmFyRWwgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYmFyJyk7CiAgY29uc3QgTUFSS0VEX1BPUlRfS0VZID0g
;J2Foa19tYXJrZWRfcG9ydHNfdjEnOwogIGNvbnN0IERFRkFVTFRfTUFSS0VEX1BPUlRTID0gWzIxLCAyMiwgMjUsIDUzLCA4MCwgMTEwLCAxNDMsIDQ0Mywg
;NDQ1LCAzMzA2LCAzMzg5LCA1NDMyLCA2Mzc5LCA4MDgwLCA4NDQzLCAyNzAxN107CiAgY29uc3QgSEFORExFX1RBR19LRVkgPSAnYWhrX2hhbmRsZV9zZWFy
;Y2hfdGFnc192MSc7CiAgY29uc3QgSEFORExFX1RBR19BQ1RJVkVfS0VZID0gJ2Foa19oYW5kbGVfc2VhcmNoX3RhZ3NfYWN0aXZlX3YxJzsKICBsZXQgbWFy
;a2VkUG9ydHMgPSBsb2FkTWFya2VkUG9ydHMoKTsKICBsZXQgaGFuZGxlVGFnSXRlbXMgPSBbXTsKICBsZXQgYWN0aXZlSGFuZGxlVGFnSWRzID0gbmV3IFNl
;dCgpOwogIGZ1bmN0aW9uIGxvYWRNYXJrZWRQb3J0cygpIHsKICAgIHRyeSB7CiAgICAgIGNvbnN0IHJhdyA9IGxvY2FsU3RvcmFnZS5nZXRJdGVtKE1BUktF
;RF9QT1JUX0tFWSk7CiAgICAgIGlmIChyYXcgPT0gbnVsbCkgcmV0dXJuIERFRkFVTFRfTUFSS0VEX1BPUlRTLnNsaWNlKCk7CiAgICAgIGNvbnN0IGFyciA9
;IEpTT04ucGFyc2UocmF3KTsKICAgICAgaWYgKCFBcnJheS5pc0FycmF5KGFycikpIHJldHVybiBERUZBVUxUX01BUktFRF9QT1JUUy5zbGljZSgpOwogICAg
;ICBjb25zdCBvdXQgPSBbXSwgc2VlbiA9IG5ldyBTZXQoKTsKICAgICAgZm9yIChjb25zdCB4IG9mIGFycikgewogICAgICAgIGNvbnN0IHAgPSBwYXJzZUlu
;dCh4LCAxMCk7CiAgICAgICAgaWYgKCFOdW1iZXIuaXNJbnRlZ2VyKHApIHx8IHAgPCAwIHx8IHAgPiA2NTUzNSB8fCBzZWVuLmhhcyhwKSkgY29udGludWU7
;CiAgICAgICAgc2Vlbi5hZGQocCk7IG91dC5wdXNoKHApOwogICAgICB9CiAgICAgIHJldHVybiBvdXQuc29ydCgoYSwgYikgPT4gYSAtIGIpOwogICAgfSBj
;YXRjaCAoXykgeyByZXR1cm4gREVGQVVMVF9NQVJLRURfUE9SVFMuc2xpY2UoKTsgfQogIH0KICBmdW5jdGlvbiBzYXZlTWFya2VkUG9ydHMoKSB7CiAgICB0
;cnkgeyBsb2NhbFN0b3JhZ2Uuc2V0SXRlbShNQVJLRURfUE9SVF9LRVksIEpTT04uc3RyaW5naWZ5KG1hcmtlZFBvcnRzKSk7IH0gY2F0Y2ggKF8pIHt9CiAg
;fQogIGZ1bmN0aW9uIHBvcnRJc0hvdChwb3J0KSB7CiAgICBjb25zdCBwID0gTnVtYmVyKHBvcnQpOwogICAgcmV0dXJuIE51bWJlci5pc0Zpbml0ZShwKSAm
;JiBwID49IDAgJiYgbWFya2VkUG9ydHMuaW5jbHVkZXMocCk7CiAgfQogIGZ1bmN0aW9uIGNsb3NlUG9ydE1hcmtQb3AoKSB7CiAgICBpZiAocG9ydE1hcmtQ
;b3ApIHBvcnRNYXJrUG9wLmNsYXNzTGlzdC5yZW1vdmUoJ29uJyk7CiAgICBpZiAoYnRuUG9ydE1hcmspIGJ0blBvcnRNYXJrLmNsYXNzTGlzdC5yZW1vdmUo
;J29uJyk7CiAgfQogIGZ1bmN0aW9uIHJlbmRlck1hcmtlZFBvcnRUYWdzKCkgewogICAgaWYgKCFwb3J0TWFya1RhZ3MpIHJldHVybjsKICAgIGlmICghbWFy
;a2VkUG9ydHMubGVuZ3RoKSB7CiAgICAgIHBvcnRNYXJrVGFncy5pbm5lckhUTUwgPSAnPGRpdiBjbGFzcz0icG1wLWVtcHR5Ij7mmoLml6DmoIforrDnq6/l
;j6M8L2Rpdj4nOwogICAgICByZXR1cm47CiAgICB9CiAgICBwb3J0TWFya1RhZ3MuaW5uZXJIVE1MID0gbWFya2VkUG9ydHMubWFwKHAgPT4KICAgICAgJzxz
;cGFuIGNsYXNzPSJwbXAtdGFnIiBkYXRhLXBvcnQ9IicgKyBwICsgJyI+JyArIHAKICAgICAgKyAnPGJ1dHRvbiB0eXBlPSJidXR0b24iIHRpdGxlPSLnp7vp
;maQiIGRhdGEtcm09IicgKyBwICsgJyI+w5c8L2J1dHRvbj48L3NwYW4+JwogICAgKS5qb2luKCcnKTsKICAgIHBvcnRNYXJrVGFncy5xdWVyeVNlbGVjdG9y
;QWxsKCdidXR0b25bZGF0YS1ybV0nKS5mb3JFYWNoKGJ0biA9PiB7CiAgICAgIGJ0bi5vbmNsaWNrID0gKGUpID0+IHsKICAgICAgICBlLnN0b3BQcm9wYWdh
;dGlvbigpOwogICAgICAgIGNvbnN0IHAgPSBOdW1iZXIoYnRuLmdldEF0dHJpYnV0ZSgnZGF0YS1ybScpKTsKICAgICAgICBtYXJrZWRQb3J0cyA9IG1hcmtl
;ZFBvcnRzLmZpbHRlcih4ID0+IHggIT09IHApOwogICAgICAgIHNhdmVNYXJrZWRQb3J0cygpOwogICAgICAgIHJlbmRlck1hcmtlZFBvcnRUYWdzKCk7CiAg
;ICAgICAgaWYgKGFwcE1vZGUgPT09ICdoYW5kbGUnICYmIGhhbmRsZU1vZGUgPT09ICdwb3J0JykgcmVuZGVySGFuZGxlVGFibGUoKTsKICAgICAgfTsKICAg
;IH0pOwogIH0KICBmdW5jdGlvbiBhZGRNYXJrZWRQb3J0KHJhdykgewogICAgY29uc3QgcGFydHMgPSBTdHJpbmcocmF3IHx8ICcnKS5zcGxpdCgvWyx877yM
;XHNdKy8pLm1hcChzID0+IHMudHJpbSgpKS5maWx0ZXIoQm9vbGVhbik7CiAgICBsZXQgY2hhbmdlZCA9IGZhbHNlOwogICAgZm9yIChjb25zdCBwYXJ0IG9m
;IHBhcnRzKSB7CiAgICAgIGNvbnN0IHAgPSBwYXJzZUludChwYXJ0LCAxMCk7CiAgICAgIGlmICghTnVtYmVyLmlzSW50ZWdlcihwKSB8fCBwIDwgMCB8fCBw
;ID4gNjU1MzUpIGNvbnRpbnVlOwogICAgICBpZiAobWFya2VkUG9ydHMuaW5jbHVkZXMocCkpIGNvbnRpbnVlOwogICAgICBtYXJrZWRQb3J0cy5wdXNoKHAp
;OwogICAgICBjaGFuZ2VkID0gdHJ1ZTsKICAgIH0KICAgIGlmICghY2hhbmdlZCkgcmV0dXJuIGZhbHNlOwogICAgbWFya2VkUG9ydHMuc29ydCgoYSwgYikg
;PT4gYSAtIGIpOwogICAgc2F2ZU1hcmtlZFBvcnRzKCk7CiAgICByZW5kZXJNYXJrZWRQb3J0VGFncygpOwogICAgaWYgKGFwcE1vZGUgPT09ICdoYW5kbGUn
;ICYmIGhhbmRsZU1vZGUgPT09ICdwb3J0JykgcmVuZGVySGFuZGxlVGFibGUoKTsKICAgIHJldHVybiB0cnVlOwogIH0KICBmdW5jdGlvbiBvcGVuUG9ydE1h
;cmtQb3AoKSB7CiAgICByZW5kZXJNYXJrZWRQb3J0VGFncygpOwogICAgaWYgKHBvcnRNYXJrUG9wKSBwb3J0TWFya1BvcC5jbGFzc0xpc3QuYWRkKCdvbicp
;OwogICAgaWYgKGJ0blBvcnRNYXJrKSBidG5Qb3J0TWFyay5jbGFzc0xpc3QuYWRkKCdvbicpOwogICAgdHJ5IHsgcG9ydE1hcmtJbnB1dCAmJiBwb3J0TWFy
;a0lucHV0LmZvY3VzKCk7IH0gY2F0Y2ggKF8pIHt9CiAgfQogIGZ1bmN0aW9uIG5vcm1hbGl6ZUhhbmRsZVRhZyh4KSB7CiAgICBpZiAoIXggfHwgIXguaWQp
;IHJldHVybiBudWxsOwogICAgY29uc3QgdGl0bGUgPSBTdHJpbmcoeC50aXRsZSB8fCAnJykudHJpbSgpLnNsaWNlKDAsIDI0KTsKICAgIGNvbnN0IHF1ZXJ5
;ID0gU3RyaW5nKHgucXVlcnkgfHwgJycpLnRyaW0oKS5zbGljZSgwLCAxMjApOwogICAgaWYgKCF0aXRsZSB8fCAhcXVlcnkpIHJldHVybiBudWxsOwogICAg
;cmV0dXJuIHsgaWQ6IFN0cmluZyh4LmlkKSwgdGl0bGUsIHF1ZXJ5IH07CiAgfQogIGZ1bmN0aW9uIGxvYWRIYW5kbGVUYWdzKCkgewogICAgaGFuZGxlVGFn
;SXRlbXMgPSBbXTsKICAgIHRyeSB7CiAgICAgIGNvbnN0IHJhdyA9IGxvY2FsU3RvcmFnZS5nZXRJdGVtKEhBTkRMRV9UQUdfS0VZKTsKICAgICAgY29uc3Qg
;YXJyID0gcmF3ID8gSlNPTi5wYXJzZShyYXcpIDogW107CiAgICAgIGlmIChBcnJheS5pc0FycmF5KGFycikpIGhhbmRsZVRhZ0l0ZW1zID0gYXJyLm1hcChu
;b3JtYWxpemVIYW5kbGVUYWcpLmZpbHRlcihCb29sZWFuKTsKICAgIH0gY2F0Y2ggKF8pIHsgaGFuZGxlVGFnSXRlbXMgPSBbXTsgfQogICAgdHJ5IHsKICAg
;ICAgY29uc3QgcmF3ID0gbG9jYWxTdG9yYWdlLmdldEl0ZW0oSEFORExFX1RBR19BQ1RJVkVfS0VZKTsKICAgICAgY29uc3QgYXJyID0gcmF3ID8gSlNPTi5w
;YXJzZShyYXcpIDogW107CiAgICAgIGFjdGl2ZUhhbmRsZVRhZ0lkcyA9IG5ldyBTZXQoQXJyYXkuaXNBcnJheShhcnIpID8gYXJyLm1hcChTdHJpbmcpIDog
;W10pOwogICAgfSBjYXRjaCAoXykgeyBhY3RpdmVIYW5kbGVUYWdJZHMgPSBuZXcgU2V0KCk7IH0KICB9CiAgZnVuY3Rpb24gc2F2ZUhhbmRsZVRhZ3MoKSB7
;CiAgICB0cnkgeyBsb2NhbFN0b3JhZ2Uuc2V0SXRlbShIQU5ETEVfVEFHX0tFWSwgSlNPTi5zdHJpbmdpZnkoaGFuZGxlVGFnSXRlbXMpKTsgfSBjYXRjaCAo
;Xykge30KICB9CiAgZnVuY3Rpb24gc2F2ZUFjdGl2ZUhhbmRsZVRhZ3MoKSB7CiAgICB0cnkgeyBsb2NhbFN0b3JhZ2Uuc2V0SXRlbShIQU5ETEVfVEFHX0FD
;VElWRV9LRVksIEpTT04uc3RyaW5naWZ5KEFycmF5LmZyb20oYWN0aXZlSGFuZGxlVGFnSWRzKSkpOyB9IGNhdGNoIChfKSB7fQogIH0KICBmdW5jdGlvbiBj
;b21wb3NlSGFuZGxlU2VhcmNoUXVlcnkoKSB7CiAgICBjb25zdCBwYXJ0cyA9IFtdOwogICAgY29uc3QgcSA9IFN0cmluZyhxRWwudmFsdWUgfHwgJycpLnRy
;aW0oKTsKICAgIGlmIChxKSBwYXJ0cy5wdXNoKHEpOwogICAgZm9yIChjb25zdCB0IG9mIGhhbmRsZVRhZ0l0ZW1zKSB7CiAgICAgIGlmICghYWN0aXZlSGFu
;ZGxlVGFnSWRzLmhhcyh0LmlkKSkgY29udGludWU7CiAgICAgIGNvbnN0IHFxID0gU3RyaW5nKHQucXVlcnkgfHwgJycpLnRyaW0oKTsKICAgICAgaWYgKHFx
;KSBwYXJ0cy5wdXNoKHFxKTsKICAgIH0KICAgIHJldHVybiBwYXJ0cy5qb2luKCd8Jyk7CiAgfQogIGZ1bmN0aW9uIHJlbmRlckhhbmRsZVRhZ0JhcigpIHsK
;ICAgIGlmICghaGFuZGxlVGFnQmFyKSByZXR1cm47CiAgICBoYW5kbGVUYWdCYXIuaW5uZXJIVE1MID0gJyc7CiAgICBmb3IgKGNvbnN0IHQgb2YgaGFuZGxl
;VGFnSXRlbXMpIHsKICAgICAgY29uc3QgYnRuID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnYnV0dG9uJyk7CiAgICAgIGJ0bi50eXBlID0gJ2J1dHRvbic7
;CiAgICAgIGJ0bi5jbGFzc05hbWUgPSAnZmlsdGVyLWNoaXAnICsgKGFjdGl2ZUhhbmRsZVRhZ0lkcy5oYXModC5pZCkgPyAnIG9uJyA6ICcnKTsKICAgICAg
;YnRuLnRleHRDb250ZW50ID0gdC50aXRsZTsKICAgICAgYnRuLnRpdGxlID0gdC5xdWVyeTsKICAgICAgYnRuLm9uY2xpY2sgPSAoKSA9PiB7CiAgICAgICAg
;aWYgKGFjdGl2ZUhhbmRsZVRhZ0lkcy5oYXModC5pZCkpIGFjdGl2ZUhhbmRsZVRhZ0lkcy5kZWxldGUodC5pZCk7CiAgICAgICAgZWxzZSBhY3RpdmVIYW5k
;bGVUYWdJZHMuYWRkKHQuaWQpOwogICAgICAgIHNhdmVBY3RpdmVIYW5kbGVUYWdzKCk7CiAgICAgICAgcmVuZGVySGFuZGxlVGFnQmFyKCk7CiAgICAgICAg
;aWYgKGFwcE1vZGUgPT09ICdoYW5kbGUnKSByZXF1ZXN0SGFuZGxlU2VhcmNoKGNvbXBvc2VIYW5kbGVTZWFyY2hRdWVyeSgpKTsKICAgICAgICBpZiAodHlw
;ZW9mIHNhdmVTZXNzaW9uU29vbiA9PT0gJ2Z1bmN0aW9uJykgc2F2ZVNlc3Npb25Tb29uKCk7CiAgICAgIH07CiAgICAgIGhhbmRsZVRhZ0Jhci5hcHBlbmRD
;aGlsZChidG4pOwogICAgfQogIH0KICBmdW5jdGlvbiByZW5kZXJIYW5kbGVUYWdNYW5hZ2UoKSB7CiAgICBpZiAoIWhhbmRsZVRhZ01hbmFnZSkgcmV0dXJu
;OwogICAgaWYgKCFoYW5kbGVUYWdJdGVtcy5sZW5ndGgpIHsKICAgICAgaGFuZGxlVGFnTWFuYWdlLmlubmVySFRNTCA9ICc8ZGl2IGNsYXNzPSJodHAtZW1w
;dHkiPuaaguaXoOaQnOe0ouagh+etvu+8jOWcqOS4i+aWuea3u+WKoDwvZGl2Pic7CiAgICAgIHJldHVybjsKICAgIH0KICAgIGhhbmRsZVRhZ01hbmFnZS5p
;bm5lckhUTUwgPSBoYW5kbGVUYWdJdGVtcy5tYXAodCA9PgogICAgICAnPHNwYW4gY2xhc3M9Imh0cC10YWciIGRhdGEtaWQ9IicgKyBlc2NhcGVBdHRyKHQu
;aWQpICsgJyIgdGl0bGU9IicgKyBlc2NhcGVBdHRyKHQucXVlcnkpICsgJyI+JwogICAgICArIGVzY2FwZUh0bWwodC50aXRsZSkKICAgICAgKyAnPGJ1dHRv
;biB0eXBlPSJidXR0b24iIHRpdGxlPSLnp7vpmaQiIGRhdGEtcm09IicgKyBlc2NhcGVBdHRyKHQuaWQpICsgJyI+w5c8L2J1dHRvbj48L3NwYW4+JwogICAg
;KS5qb2luKCcnKTsKICAgIGhhbmRsZVRhZ01hbmFnZS5xdWVyeVNlbGVjdG9yQWxsKCdidXR0b25bZGF0YS1ybV0nKS5mb3JFYWNoKGJ0biA9PiB7CiAgICAg
;IGJ0bi5vbmNsaWNrID0gKGUpID0+IHsKICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgICAgIGNvbnN0IGlkID0gYnRuLmdldEF0dHJpYnV0ZSgn
;ZGF0YS1ybScpOwogICAgICAgIGhhbmRsZVRhZ0l0ZW1zID0gaGFuZGxlVGFnSXRlbXMuZmlsdGVyKHggPT4geC5pZCAhPT0gaWQpOwogICAgICAgIGFjdGl2
;ZUhhbmRsZVRhZ0lkcy5kZWxldGUoaWQpOwogICAgICAgIHNhdmVIYW5kbGVUYWdzKCk7CiAgICAgICAgc2F2ZUFjdGl2ZUhhbmRsZVRhZ3MoKTsKICAgICAg
;ICByZW5kZXJIYW5kbGVUYWdCYXIoKTsKICAgICAgICByZW5kZXJIYW5kbGVUYWdNYW5hZ2UoKTsKICAgICAgICBpZiAoYXBwTW9kZSA9PT0gJ2hhbmRsZScp
;IHJlcXVlc3RIYW5kbGVTZWFyY2goY29tcG9zZUhhbmRsZVNlYXJjaFF1ZXJ5KCkpOwogICAgICB9OwogICAgfSk7CiAgfQogIGZ1bmN0aW9uIGFkZEhhbmRs
;ZVRhZyh0aXRsZSwgcXVlcnkpIHsKICAgIHRpdGxlID0gU3RyaW5nKHRpdGxlIHx8ICcnKS50cmltKCkuc2xpY2UoMCwgMjQpOwogICAgcXVlcnkgPSBTdHJp
;bmcocXVlcnkgfHwgJycpLnRyaW0oKS5zbGljZSgwLCAxMjApOwogICAgaWYgKCF0aXRsZSB8fCAhcXVlcnkpIHJldHVybiBmYWxzZTsKICAgIGlmIChoYW5k
;bGVUYWdJdGVtcy5zb21lKHggPT4geC50aXRsZSA9PT0gdGl0bGUgJiYgeC5xdWVyeSA9PT0gcXVlcnkpKSByZXR1cm4gZmFsc2U7CiAgICBjb25zdCBpZCA9
;ICdoXycgKyBEYXRlLm5vdygpLnRvU3RyaW5nKDM2KSArIE1hdGgucmFuZG9tKCkudG9TdHJpbmcoMzYpLnNsaWNlKDIsIDYpOwogICAgaGFuZGxlVGFnSXRl
;bXMucHVzaCh7IGlkLCB0aXRsZSwgcXVlcnkgfSk7CiAgICBzYXZlSGFuZGxlVGFncygpOwogICAgcmVuZGVySGFuZGxlVGFnQmFyKCk7CiAgICByZW5kZXJI
;YW5kbGVUYWdNYW5hZ2UoKTsKICAgIHJldHVybiB0cnVlOwogIH0KICBmdW5jdGlvbiBvcGVuSGFuZGxlVGFnUG9wKCkgewogICAgcmVuZGVySGFuZGxlVGFn
;TWFuYWdlKCk7CiAgICBpZiAoaGFuZGxlVGFnUG9wKSBoYW5kbGVUYWdQb3AuY2xhc3NMaXN0LmFkZCgnb24nKTsKICAgIHRyeSB7CiAgICAgIGNvbnN0IHQg
;PSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnaHRwLXRpdGxlJyk7CiAgICAgIGlmICh0KSB0LmZvY3VzKCk7CiAgICB9IGNhdGNoIChfKSB7fQogIH0KICBm
;dW5jdGlvbiBjbG9zZUhhbmRsZVRhZ1BvcCgpIHsKICAgIGlmIChoYW5kbGVUYWdQb3ApIGhhbmRsZVRhZ1BvcC5jbGFzc0xpc3QucmVtb3ZlKCdvbicpOwog
;IH0KICBsb2FkSGFuZGxlVGFncygpOwogIHJlbmRlckhhbmRsZVRhZ0JhcigpOwogIGxldCBoYW5kbGVJdGVtcyA9IFtdOwogIGxldCBoYW5kbGVRdWVyeSA9
;ICcnOwogIGxldCBoYW5kbGVCdXN5ID0gZmFsc2U7CiAgbGV0IGluZm9EYXRhID0gbnVsbDsKICBsZXQgaW5mb1RleHQgPSAnJzsKICBsZXQgaW5mb1JlcUdl
;biA9IDA7CiAgbGV0IGluZm9Mb2FkVGltZXIgPSAwOwogIGxldCBtb25pdG9yVGFiID0gJ2ZpbGUnOwogIGxldCBoYW5kbGVNb2RlID0gJ2hhbmRsZSc7CiAg
;bGV0IGhhbmRsZVNvcnRLZXkgPSAnbHBvcnQnOwogIGxldCBoYW5kbGVTb3J0RGlyID0gMTsgLy8gMT3ljYfluo8gLTE96ZmN5bqPCiAgY29uc3QgREVGQVVM
;VF9QT1JUX1FVRVJZID0gJzAtNjU1MzUnOwogIGNvbnN0IGhhbmRsZUhlYWQgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnaGFuZGxlLWhlYWQnKTsKICBs
;ZXQgcHJvY01lbnVUYXJnZXRzID0gW107CiAgbGV0IGhhbmRsZVNlbEtleXMgPSBuZXcgU2V0KCk7CiAgbGV0IGhhbmRsZUFuY2hvcktleSA9ICcnOwogIC8v
;IOaXp+i/m+eoi+ebkeaOpyBVSSDlt7Lnp7vpmaTvvJrljaDkvY3pgb/lhY3mrovnlZnku6PnoIHmiqXplJkKICBjb25zdCBwcm9jSGVhZCA9IG51bGw7CiAg
;Y29uc3QgcHJvY0JvZHkgPSBudWxsOwogIGNvbnN0IHByb2NTY3JvbGwgPSBudWxsOwogIGNvbnN0IHByb2NDcHVUb3RhbCA9IG51bGw7CiAgY29uc3QgcHJv
;Y01lbVRvdGFsID0gbnVsbDsKICBsZXQgcHJvY0l0ZW1zID0gW107CiAgbGV0IHByb2NTaG93U3lzID0gZmFsc2U7CiAgbGV0IHByb2NTZWxLZXlzID0gbmV3
;IFNldCgpOwogIGxldCBwcm9jU2VsS2V5ID0gJyc7CiAgbGV0IHByb2NTZWxQaWQgPSAwOwogIGxldCBwcm9jQW5jaG9yS2V5ID0gJyc7CiAgbGV0IHByb2NT
;b3J0S2V5ID0gJ25hbWUnOwogIGxldCBwcm9jU29ydERpciA9IDE7CiAgY29uc3QgcHJvY1Jvd01hcCA9IG5ldyBNYXAoKTsKICBjb25zdCBwcm9jSWNvblN0
;YWJsZSA9IG5ldyBNYXAoKTsKCiAgZnVuY3Rpb24gc2V0QXBwTW9kZShtb2RlKSB7CiAgICBpZiAobW9kZSAhPT0gJ2hhbmRsZScgJiYgbW9kZSAhPT0gJ2lu
;Zm8nICYmIG1vZGUgIT09ICdjb25maWcnKSBtb2RlID0gJ2ZpbGUnOwogICAgLy8g56a75byA6YWN572u5YmN5YWI6Ieq5Yqo5L+d5a2YCiAgICBpZiAoYXBw
;TW9kZSA9PT0gJ2NvbmZpZycgJiYgbW9kZSAhPT0gJ2NvbmZpZycpIHsKICAgICAgdHJ5IHsgZmx1c2hDZmdBdXRvU2F2ZSgpOyB9IGNhdGNoIChfKSB7fQog
;ICAgfQogICAgLy8g56a75byA5b2T5YmN5qih5byP5YmN5YWI5a2Y5LiL5pCc57Si5qGGCiAgICBpZiAoYXBwTW9kZSA9PT0gJ2ZpbGUnKSBtb2RlUXVlcnku
;ZmlsZSA9IFN0cmluZyhxRWwudmFsdWUgfHwgJycpOwogICAgZWxzZSBpZiAoYXBwTW9kZSA9PT0gJ2hhbmRsZScpIG1vZGVRdWVyeS5oYW5kbGUgPSBTdHJp
;bmcocUVsLnZhbHVlIHx8ICcnKTsKICAgIGVsc2UgaWYgKGFwcE1vZGUgPT09ICdpbmZvJykgbW9kZVF1ZXJ5LmluZm8gPSBTdHJpbmcocUVsLnZhbHVlIHx8
;ICcnKTsKICAgIGVsc2UgaWYgKGFwcE1vZGUgPT09ICdjb25maWcnKSBtb2RlUXVlcnkuY29uZmlnID0gU3RyaW5nKHFFbC52YWx1ZSB8fCAnJyk7CiAgICBj
;b25zdCBwcmV2ID0gYXBwTW9kZTsKICAgIGFwcE1vZGUgPSBtb2RlOwogICAgbW9uaXRvclRhYiA9IG1vZGUgPT09ICdmaWxlJyA/ICdmaWxlJyA6IG1vZGU7
;CiAgICBjb25zdCBpc0ZpbGUgPSBtb2RlID09PSAnZmlsZSc7CiAgICBjb25zdCBpc0hhbmRsZSA9IG1vZGUgPT09ICdoYW5kbGUnOwogICAgY29uc3QgaXNJ
;bmZvID0gbW9kZSA9PT0gJ2luZm8nOwogICAgY29uc3QgaXNDb25maWcgPSBtb2RlID09PSAnY29uZmlnJzsKICAgIGlmIChpc0ZpbGUpCiAgICAgIGRvY3Vt
;ZW50LmRvY3VtZW50RWxlbWVudC5yZW1vdmVBdHRyaWJ1dGUoJ2RhdGEtc2tpcC1ib290Jyk7CiAgICBlbHNlCiAgICAgIGRvY3VtZW50LmRvY3VtZW50RWxl
;bWVudC5zZXRBdHRyaWJ1dGUoJ2RhdGEtc2tpcC1ib290JywgJzEnKTsKICAgIGNvbnN0IHRvcEVsID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3RvcCcp
;OwogICAgY29uc3QgY29uZmlnUGFuZWwgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnY29uZmlnLXBhbmVsJyk7CiAgICBpZiAobWFpbkVsKSB7CiAgICAg
;IG1haW5FbC5jbGFzc0xpc3QudG9nZ2xlKCdtb2RlLXRvb2wnLCAhaXNGaWxlKTsKICAgICAgbWFpbkVsLmNsYXNzTGlzdC50b2dnbGUoJ21vZGUtaGFuZGxl
;JywgaXNIYW5kbGUpOwogICAgICBtYWluRWwuY2xhc3NMaXN0LnRvZ2dsZSgnbW9kZS1pbmZvJywgaXNJbmZvKTsKICAgICAgbWFpbkVsLmNsYXNzTGlzdC50
;b2dnbGUoJ21vZGUtY29uZmlnJywgaXNDb25maWcpOwogICAgfQogICAgaWYgKGJhckVsKSB7CiAgICAgIGJhckVsLmNsYXNzTGlzdC50b2dnbGUoJ21vZGUt
;dG9vbCcsICFpc0ZpbGUpOwogICAgICBiYXJFbC5jbGFzc0xpc3QudG9nZ2xlKCdtb2RlLWluZm8nLCBpc0luZm8pOwogICAgICBiYXJFbC5jbGFzc0xpc3Qu
;dG9nZ2xlKCdtb2RlLWhhbmRsZScsIGlzSGFuZGxlKTsKICAgICAgYmFyRWwuY2xhc3NMaXN0LnRvZ2dsZSgnbW9kZS1jb25maWcnLCBpc0NvbmZpZyk7CiAg
;ICB9CiAgICBpZiAodG9wRWwpIHsKICAgICAgdG9wRWwuY2xhc3NMaXN0LnRvZ2dsZSgnbW9kZS10b29sJywgIWlzRmlsZSk7CiAgICAgIHRvcEVsLmNsYXNz
;TGlzdC50b2dnbGUoJ21vZGUtaGFuZGxlJywgaXNIYW5kbGUpOwogICAgICB0b3BFbC5jbGFzc0xpc3QudG9nZ2xlKCdtb2RlLWluZm8nLCBpc0luZm8pOwog
;ICAgICB0b3BFbC5jbGFzc0xpc3QudG9nZ2xlKCdtb2RlLWNvbmZpZycsIGlzQ29uZmlnKTsKICAgIH0KICAgIGlmIChhcHBSb290KSB7CiAgICAgIGFwcFJv
;b3QuY2xhc3NMaXN0LnRvZ2dsZSgnaGlkZS1maWx0ZXJzJywgIShpc0ZpbGUgfHwgaXNIYW5kbGUgfHwgaXNDb25maWcpKTsKICAgICAgc3luY1RpdGxlUmFp
;bE1vZGUoKTsKICAgIH0KICAgIGlmIChmaWxlUmVzdWx0cykgZmlsZVJlc3VsdHMuY2xhc3NMaXN0LnRvZ2dsZSgnaGlkZGVuJywgIWlzRmlsZSk7CiAgICBp
;ZiAoaGFuZGxlUGFuZWwpIGhhbmRsZVBhbmVsLmNsYXNzTGlzdC50b2dnbGUoJ2hpZGRlbicsICFpc0hhbmRsZSk7CiAgICBpZiAoaW5mb1BhbmVsKSBpbmZv
;UGFuZWwuY2xhc3NMaXN0LnRvZ2dsZSgnaGlkZGVuJywgIWlzSW5mbyk7CiAgICBpZiAoY29uZmlnUGFuZWwpIGNvbmZpZ1BhbmVsLmNsYXNzTGlzdC50b2dn
;bGUoJ2hpZGRlbicsICFpc0NvbmZpZyk7CiAgICBxRWwucmVhZE9ubHkgPSBpc0luZm87CiAgICBjbG9zZUhpc3RNZW51KCk7CiAgICBjbG9zZVBvcnRNYXJr
;UG9wKCk7CiAgICB0cnkgeyBjbG9zZUhhbmRsZVRhZ1BvcCgpOyB9IGNhdGNoIChfKSB7fQogICAgcG9zdCgncHJvY1ZpZXd8MCcpOwogICAgaWYgKGlzSGFu
;ZGxlKSB7CiAgICAgIHFFbC5wbGFjZWhvbGRlciA9IFBMQUNFSE9MREVSX0hBTkRMRTsKICAgICAgaGFuZGxlU29ydEtleSA9ICdscG9ydCc7CiAgICAgIGhh
;bmRsZVNvcnREaXIgPSAxOwogICAgICBxRWwudmFsdWUgPSBtb2RlUXVlcnkuaGFuZGxlOwogICAgICBzeW5jQ2xlYXJCdG4oKTsKICAgICAgcmVxdWVzdEhh
;bmRsZVNlYXJjaChjb21wb3NlSGFuZGxlU2VhcmNoUXVlcnkoKSk7CiAgICAgIHRyeSB7IHFFbC5mb2N1cygpOyB9IGNhdGNoIChfKSB7fQogICAgfSBlbHNl
;IGlmIChpc0luZm8pIHsKICAgICAgcUVsLnBsYWNlaG9sZGVyID0gUExBQ0VIT0xERVJfSU5GTzsKICAgICAgcUVsLnZhbHVlID0gbW9kZVF1ZXJ5LmluZm87
;CiAgICAgIHN5bmNDbGVhckJ0bigpOwogICAgICBjb3VudEVsLnRleHRDb250ZW50ID0gJ+acrOacuuS/oeaBryc7CiAgICAgIHJlcXVlc3RTeXNJbmZvKGZh
;bHNlKTsKICAgIH0gZWxzZSBpZiAoaXNDb25maWcpIHsKICAgICAgcUVsLnBsYWNlaG9sZGVyID0gUExBQ0VIT0xERVJfQ09ORklHOwogICAgICBxRWwudmFs
;dWUgPSBtb2RlUXVlcnkuY29uZmlnIHx8ICcnOwogICAgICBzeW5jQ2xlYXJCdG4oKTsKICAgICAgY291bnRFbC50ZXh0Q29udGVudCA9ICfov5DooYzphY3n
;va4nOwogICAgICBpZiAodHlwZW9mIGVuc3VyZUNvbmZpZ1VpID09PSAnZnVuY3Rpb24nKSBlbnN1cmVDb25maWdVaSgpOwogICAgICBpZiAodHlwZW9mIGFw
;cGx5Q29uZmlnU2VhcmNoID09PSAnZnVuY3Rpb24nKSBhcHBseUNvbmZpZ1NlYXJjaChtb2RlUXVlcnkuY29uZmlnIHx8ICcnKTsKICAgICAgaWYgKHR5cGVv
;ZiBsb2FkQWhrQ29uZmlnVGFiID09PSAnZnVuY3Rpb24nKSBsb2FkQWhrQ29uZmlnVGFiKGNmZ0FjdGl2ZVRhYiB8fCAncnVuY29uZmlnJywgZmFsc2UpOwog
;ICAgICB0cnkgeyBxRWwuZm9jdXMoKTsgfSBjYXRjaCAoXykge30KICAgIH0gZWxzZSB7CiAgICAgIHFFbC5wbGFjZWhvbGRlciA9IFBMQUNFSE9MREVSX0ZJ
;TEU7CiAgICAgIHFFbC52YWx1ZSA9IG1vZGVRdWVyeS5maWxlOwogICAgICBzeW5jQ2xlYXJCdG4oKTsKICAgICAgdHJ5IHsgcUVsLmZvY3VzKCk7IH0gY2F0
;Y2ggKF8pIHt9CiAgICAgIC8vIOS7juWFtuWug+aooeW8j+WIh+WbnuaWh+S7tu+8mueUqOacrOWcsOadoeS7tumHjeaQnO+8iOWQq+etm+mAie+8ie+8jOS4
;jeW4puWPpeafhOWFs+mUruWtlwogICAgICBpZiAocHJldiAhPT0gJ2ZpbGUnKSBkb1NlYXJjaCgpOwogICAgfQogICAgaWYgKHR5cGVvZiBzYXZlU2Vzc2lv
;blNvb24gPT09ICdmdW5jdGlvbicpIHNhdmVTZXNzaW9uU29vbigpOwogICAgdHJ5IHsgcG9zdCgnc2Vzc2lvbk1vZGV8JyArIG1vZGUpOyB9IGNhdGNoIChf
;KSB7fQogIH0KICBmdW5jdGlvbiBzZXRBcHBWaWV3KG5hbWUpIHsKICAgIC8vIOWFvOWuueaXp+WFpeWPo++8muWIh+WIsOS+p+agj+WvueW6lOmhuQogICAg
;aWYgKG5hbWUgPT09ICdoYW5kbGUnIHx8IG5hbWUgPT09ICdwcm9jJykgewogICAgICBkb2N1bWVudC5xdWVyeVNlbGVjdG9yQWxsKCcuY2F0JykuZm9yRWFj
;aChiID0+IGIuY2xhc3NMaXN0LnRvZ2dsZSgnb24nLCBiLmRhdGFzZXQuY2F0ID09PSAnX19oYW5kbGUnKSk7CiAgICAgIHNldEFwcE1vZGUoJ2hhbmRsZScp
;OwogICAgICByZXR1cm47CiAgICB9CiAgICBpZiAobmFtZSA9PT0gJ2luZm8nKSB7CiAgICAgIGRvY3VtZW50LnF1ZXJ5U2VsZWN0b3JBbGwoJy5jYXQnKS5m
;b3JFYWNoKGIgPT4gYi5jbGFzc0xpc3QudG9nZ2xlKCdvbicsIGIuZGF0YXNldC5jYXQgPT09ICdfX2luZm8nKSk7CiAgICAgIHNldEFwcE1vZGUoJ2luZm8n
;KTsKICAgICAgcmV0dXJuOwogICAgfQogICAgaWYgKG5hbWUgPT09ICdjb25maWcnKSB7CiAgICAgIGRvY3VtZW50LnF1ZXJ5U2VsZWN0b3JBbGwoJy5jYXQn
;KS5mb3JFYWNoKGIgPT4gYi5jbGFzc0xpc3QudG9nZ2xlKCdvbicsIGIuZGF0YXNldC5jYXQgPT09ICdfX2NvbmZpZycpKTsKICAgICAgc2V0QXBwTW9kZSgn
;Y29uZmlnJyk7CiAgICAgIHJldHVybjsKICAgIH0KICAgIGRvY3VtZW50LnF1ZXJ5U2VsZWN0b3JBbGwoJy5jYXQnKS5mb3JFYWNoKGIgPT4gYi5jbGFzc0xp
;c3QudG9nZ2xlKCdvbicsIGIuZGF0YXNldC5jYXQgPT09IGNhdCkpOwogICAgc2V0QXBwTW9kZSgnZmlsZScpOwogIH0KICBmdW5jdGlvbiBzeW5jUHJvY01v
;bml0b3JMaXZlKCkgeyBwb3N0KCdwcm9jVmlld3wwJyk7IH0KICBmdW5jdGlvbiByZXF1ZXN0UHJvY0xpc3QoKSB7IC8qIOW3suenu+mZpOmHjeWei+i/m+eo
;i+ebkeaOpyAqLyB9CiAgZnVuY3Rpb24gY2xlYXJJbmZvTG9hZFdhaXQoKSB7CiAgICBpZiAoaW5mb0xvYWRUaW1lcikgewogICAgICBjbGVhclRpbWVvdXQo
;aW5mb0xvYWRUaW1lcik7CiAgICAgIGluZm9Mb2FkVGltZXIgPSAwOwogICAgfQogIH0KICBmdW5jdGlvbiBzaG93SW5mb0xvYWRpbmcoKSB7CiAgICBpZiAo
;IWluZm9QYW5lbCB8fCBhcHBNb2RlICE9PSAnaW5mbycpIHJldHVybjsKICAgIGluZm9QYW5lbC5pbm5lckhUTUwgPSAnPGRpdiBjbGFzcz0iaW5mby1sb2Fk
;aW5nIj48ZGl2IGNsYXNzPSJpbmZvLXNwaW5uZXIiIGFyaWEtaGlkZGVuPSJ0cnVlIj48L2Rpdj48ZGl2Puato+WcqOivu+WPluacrOacuuS/oeaBr+KApjwv
;ZGl2PjwvZGl2Pic7CiAgICBpZiAoY291bnRFbCkgY291bnRFbC50ZXh0Q29udGVudCA9ICfliqDovb3kuK3igKYnOwogIH0KICBmdW5jdGlvbiByZXF1ZXN0
;U3lzSW5mbyhmb3JjZSkgewogICAgZm9yY2UgPSAhIWZvcmNlOwogICAgY29uc3QgbXlHZW4gPSArK2luZm9SZXFHZW47CiAgICBjbGVhckluZm9Mb2FkV2Fp
;dCgpOwogICAgLy8g57yT5a2Y5ZG95Lit6YCa5bi45b6I5b+r77yb6LaF6L+H57qmIDAuNHMg5YaN5Ye65Yqg6L295Yqo55S777yM6YG/5YWN6Zeq5LiA5LiL
;CiAgICBpZiAoZm9yY2UgfHwgIWluZm9EYXRhKSB7CiAgICAgIGluZm9Mb2FkVGltZXIgPSBzZXRUaW1lb3V0KCgpID0+IHsKICAgICAgICBpbmZvTG9hZFRp
;bWVyID0gMDsKICAgICAgICBpZiAobXlHZW4gIT09IGluZm9SZXFHZW4gfHwgYXBwTW9kZSAhPT0gJ2luZm8nKSByZXR1cm47CiAgICAgICAgc2hvd0luZm9M
;b2FkaW5nKCk7CiAgICAgIH0sIDQwMCk7CiAgICB9CiAgICBwb3N0KCdzeXNJbmZvfCcgKyAoZm9yY2UgPyAnMScgOiAnMCcpKTsKICB9CiAgY29uc3QgSEFO
;RExFX0hJU1RfS0VZID0gJ2Foa19oYW5kbGVfc2VhcmNoX2hpc3RfdjEnOwogIGNvbnN0IEhBTkRMRV9ISVNUX01BWCA9IDEwOwogIGNvbnN0IGhhbmRsZUhp
;c3RMaXN0ID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2hhbmRsZS1oaXN0LWxpc3QnKTsKICBmdW5jdGlvbiBsb2FkSGFuZGxlSGlzdCgpIHsKICAgIHRy
;eSB7CiAgICAgIGNvbnN0IHJhdyA9IGxvY2FsU3RvcmFnZS5nZXRJdGVtKEhBTkRMRV9ISVNUX0tFWSk7CiAgICAgIGNvbnN0IGFyciA9IHJhdyA/IEpTT04u
;cGFyc2UocmF3KSA6IFtdOwogICAgICByZXR1cm4gQXJyYXkuaXNBcnJheShhcnIpID8gYXJyLmZpbHRlcih4ID0+IFN0cmluZyh4IHx8ICcnKS50cmltKCkp
;IDogW107CiAgICB9IGNhdGNoIChfKSB7IHJldHVybiBbXTsgfQogIH0KICBmdW5jdGlvbiBzYXZlSGFuZGxlSGlzdChxKSB7CiAgICBxID0gU3RyaW5nKHEg
;fHwgJycpLnRyaW0oKTsKICAgIGlmICghcSkgcmV0dXJuOwogICAgbGV0IGFyciA9IGxvYWRIYW5kbGVIaXN0KCkuZmlsdGVyKHggPT4geCAhPT0gcSk7CiAg
;ICBhcnIudW5zaGlmdChxKTsKICAgIGlmIChhcnIubGVuZ3RoID4gSEFORExFX0hJU1RfTUFYKSBhcnIgPSBhcnIuc2xpY2UoMCwgSEFORExFX0hJU1RfTUFY
;KTsKICAgIHRyeSB7IGxvY2FsU3RvcmFnZS5zZXRJdGVtKEhBTkRMRV9ISVNUX0tFWSwgSlNPTi5zdHJpbmdpZnkoYXJyKSk7IH0gY2F0Y2ggKF8pIHt9CiAg
;ICByZW5kZXJIYW5kbGVIaXN0KCk7CiAgfQogIGZ1bmN0aW9uIHJlbmRlckhhbmRsZUhpc3QoKSB7CiAgICBpZiAoIWhhbmRsZUhpc3RMaXN0KSByZXR1cm47
;CiAgICBoYW5kbGVIaXN0TGlzdC5pbm5lckhUTUwgPSBsb2FkSGFuZGxlSGlzdCgpLm1hcChxID0+CiAgICAgICc8b3B0aW9uIHZhbHVlPSInICsgZXNjYXBl
;SHRtbChxKSArICciPjwvb3B0aW9uPicKICAgICkuam9pbignJyk7CiAgfQogIGZ1bmN0aW9uIG5vcm1hbGl6ZVBvcnRRdWVyeShxKSB7CiAgICBxID0gU3Ry
;aW5nKHEgfHwgJycpLnRyaW0oKTsKICAgIGNvbnN0IG0gPSBxLm1hdGNoKC9eXC/nq6/lj6NccyooLiopJC9pKSB8fCBxLm1hdGNoKC9eXC9wb3J0XHMqKC4q
;KSQvaSk7CiAgICBpZiAobSkgcSA9IFN0cmluZyhtWzFdIHx8ICcnKS50cmltKCk7CiAgICByZXR1cm4gcTsKICB9CiAgZnVuY3Rpb24gaXNQb3J0U2VhcmNo
;UXVlcnkocSkgewogICAgcSA9IG5vcm1hbGl6ZVBvcnRRdWVyeShxKTsKICAgIHJldHVybiAhIXEgJiYgL15bXGRcc3xcLV0rJC8udGVzdChxKSAmJiAvXGQv
;LnRlc3QocSk7CiAgfQogIGZ1bmN0aW9uIHBhcnNlUG9ydExpc3QocSkgewogICAgcSA9IG5vcm1hbGl6ZVBvcnRRdWVyeShxKTsKICAgIGNvbnN0IG91dCA9
;IFtdLCBzZWVuID0gbmV3IFNldCgpOwogICAgY29uc3QgYWRkID0gKHApID0+IHsKICAgICAgcCA9IE51bWJlcihwKTsKICAgICAgaWYgKCFOdW1iZXIuaXNJ
;bnRlZ2VyKHApIHx8IHAgPCAwIHx8IHAgPiA2NTUzNSB8fCBzZWVuLmhhcyhwKSkgcmV0dXJuOwogICAgICBzZWVuLmFkZChwKTsKICAgICAgb3V0LnB1c2go
;cCk7CiAgICB9OwogICAgZm9yIChjb25zdCBwYXJ0IG9mIFN0cmluZyhxKS5zcGxpdCgnfCcpKSB7CiAgICAgIGNvbnN0IHMgPSBTdHJpbmcocGFydCB8fCAn
;JykudHJpbSgpOwogICAgICBpZiAoIXMpIGNvbnRpbnVlOwogICAgICBjb25zdCBtID0gcy5tYXRjaCgvXihcZCspXHMqLVxzKihcZCspJC8pOwogICAgICBp
;ZiAobSkgewogICAgICAgIGxldCBhID0gcGFyc2VJbnQobVsxXSwgMTApLCBiID0gcGFyc2VJbnQobVsyXSwgMTApOwogICAgICAgIGlmIChhID4gYikgeyBj
;b25zdCB0ID0gYTsgYSA9IGI7IGIgPSB0OyB9CiAgICAgICAgYSA9IE1hdGgubWF4KDAsIE1hdGgubWluKDY1NTM1LCBhKSk7CiAgICAgICAgYiA9IE1hdGgu
;bWF4KDAsIE1hdGgubWluKDY1NTM1LCBiKSk7CiAgICAgICAgZm9yIChsZXQgcCA9IGE7IHAgPD0gYjsgcCsrKSBhZGQocCk7CiAgICAgIH0gZWxzZSBpZiAo
;L15cZCskLy50ZXN0KHMpKSB7CiAgICAgICAgYWRkKHBhcnNlSW50KHMsIDEwKSk7CiAgICAgIH0KICAgIH0KICAgIHJldHVybiBvdXQ7CiAgfQogIGZ1bmN0
;aW9uIGlzQWxsUG9ydHNRdWVyeVRleHQocSkgewogICAgcSA9IFN0cmluZyhxIHx8ICcnKS50cmltKCk7CiAgICByZXR1cm4gIXEgfHwgcSA9PT0gREVGQVVM
;VF9QT1JUX1FVRVJZIHx8IC9eMFxzKi1ccyo2NTUzNSQvLnRlc3QocSk7CiAgfQogIGZ1bmN0aW9uIHJlcXVlc3RIYW5kbGVTZWFyY2gocSkgewogICAgcSA9
;IFN0cmluZyhxIHx8ICcnKS50cmltKCk7CiAgICAvLyDnqbrmoYYgLyDlhajnq6/lj6Mg4oaSIOebtOaOpeaYvuekuuWFqOmDqOi/nuaOpe+8jOS4jeaKiuad
;oeS7tuWGmei/m+i+k+WFpeahhgogICAgaWYgKGlzQWxsUG9ydHNRdWVyeVRleHQocSkpIHsKICAgICAgaGFuZGxlUXVlcnkgPSBERUZBVUxUX1BPUlRfUVVF
;Ulk7CiAgICAgIGhhbmRsZU1vZGUgPSAncG9ydCc7CiAgICAgIGhhbmRsZUJ1c3kgPSB0cnVlOwogICAgICBpZiAoaGFuZGxlU3RhdHVzKSBoYW5kbGVTdGF0
;dXMudGV4dENvbnRlbnQgPSAn5q2j5Zyo5p+l6K+i4oCmJzsKICAgICAgaGFuZGxlQmFubmVyLmNsYXNzTGlzdC5hZGQoJ29uJyk7CiAgICAgIGhhbmRsZUJh
;bm5lci50ZXh0Q29udGVudCA9ICflhajpg6jov57mjqUnOwogICAgICBoYW5kbGVTZWxLZXlzLmNsZWFyKCk7CiAgICAgIGhhbmRsZUFuY2hvcktleSA9ICcn
;OwogICAgICBzeW5jSGFuZGxlQmFyKDApOwogICAgICBzaG93SGFuZGxlTG9hZGluZygn5q2j5Zyo5p+l6K+i56uv5Y+j5Y2g55So77yM6K+356iN5YCZ4oCm
;Jyk7CiAgICAgIHBvc3QoJ2hhbmRsZVNlYXJjaHwnICsgREVGQVVMVF9QT1JUX1FVRVJZKTsKICAgICAgcmV0dXJuOwogICAgfQogICAgaGFuZGxlUXVlcnkg
;PSBxOwogICAgaGFuZGxlTW9kZSA9IGlzUG9ydFNlYXJjaFF1ZXJ5KHEpID8gJ3BvcnQnIDogJ2hhbmRsZSc7CiAgICBpZiAoaGFuZGxlTW9kZSA9PT0gJ3Bv
;cnQnICYmICFwYXJzZVBvcnRMaXN0KHEpLmxlbmd0aCkgewogICAgICBoYW5kbGVJdGVtcyA9IFtdOwogICAgICByZW5kZXJIYW5kbGVUYWJsZSgn56uv5Y+j
;5peg5pWI77yM56S65L6L77yaODA4MHw4MCDmiJYgMC0zMDB8NTAwJyk7CiAgICAgIHJldHVybjsKICAgIH0KICAgIHNhdmVIYW5kbGVIaXN0KHEpOwogICAg
;aGFuZGxlQnVzeSA9IHRydWU7CiAgICBpZiAoaGFuZGxlU3RhdHVzKSBoYW5kbGVTdGF0dXMudGV4dENvbnRlbnQgPSAn5q2j5Zyo5p+l6K+i4oCmJzsKICAg
;IGhhbmRsZUJhbm5lci5jbGFzc0xpc3QuYWRkKCdvbicpOwogICAgaGFuZGxlQmFubmVyLnRleHRDb250ZW50ID0gJ+KAnCcgKyBxICsgJ+KAneeahOaQnOe0
;oue7k+aenCc7CiAgICBoYW5kbGVTZWxLZXlzLmNsZWFyKCk7CiAgICBoYW5kbGVBbmNob3JLZXkgPSAnJzsKICAgIHN5bmNIYW5kbGVCYXIoMCk7CiAgICBz
;aG93SGFuZGxlTG9hZGluZyhoYW5kbGVNb2RlID09PSAncG9ydCcgPyAn5q2j5Zyo5p+l6K+i56uv5Y+j5Y2g55So77yM6K+356iN5YCZ4oCmJyA6ICfmraPl
;nKjmn6Xor6Llj6Xmn4TvvIzor7fnqI3lgJnigKYnKTsKICAgIHBvc3QoJ2hhbmRsZVNlYXJjaHwnICsgcSk7CiAgfQogIGZ1bmN0aW9uIHNob3dIYW5kbGVM
;b2FkaW5nKG1zZykgewogICAgaGFuZGxlQm9keS5pbm5lckhUTUwgPSAnPGRpdiBjbGFzcz0iaGFuZGxlLWxvYWRpbmciPjxkaXYgY2xhc3M9ImhhbmRsZS1z
;cGlubmVyIiBhcmlhLWhpZGRlbj0idHJ1ZSI+PC9kaXY+PGRpdj4nCiAgICAgICsgZXNjYXBlSHRtbChtc2cgfHwgJ+ato+WcqOafpeivouWPpeafhO+8jOiv
;t+eojeWAmeKApicpICsgJzwvZGl2PjwvZGl2Pic7CiAgfQogIGZ1bmN0aW9uIHNvcnRIYW5kbGVJdGVtcyhpdGVtcykgewogICAgY29uc3Qga2V5ID0gaGFu
;ZGxlU29ydEtleSB8fCAoaGFuZGxlTW9kZSA9PT0gJ3BvcnQnID8gJ2xwb3J0JyA6ICduYW1lJyk7CiAgICBjb25zdCBkaXIgPSBoYW5kbGVTb3J0RGlyIHx8
;IDE7CiAgICByZXR1cm4gKGl0ZW1zIHx8IFtdKS5zbGljZSgpLnNvcnQoKGEsIGIpID0+IHsKICAgICAgbGV0IGNtcCA9IDA7CiAgICAgIGlmIChrZXkgPT09
;ICdwaWQnKSB7CiAgICAgICAgY21wID0gKE51bWJlcihhLnBpZCkgfHwgMCkgLSAoTnVtYmVyKGIucGlkKSB8fCAwKTsKICAgICAgfSBlbHNlIGlmIChrZXkg
;PT09ICdscG9ydCcpIHsKICAgICAgICBjbXAgPSAoTnVtYmVyKGEubG9jYWxQb3J0KSB8fCAwKSAtIChOdW1iZXIoYi5sb2NhbFBvcnQpIHx8IDApOwogICAg
;ICB9IGVsc2UgaWYgKGtleSA9PT0gJ3Jwb3J0JykgewogICAgICAgIGNtcCA9IChOdW1iZXIoYS5yZW1vdGVQb3J0KSB8fCAwKSAtIChOdW1iZXIoYi5yZW1v
;dGVQb3J0KSB8fCAwKTsKICAgICAgfSBlbHNlIGlmIChrZXkgPT09ICd0eXBlJykgewogICAgICAgIGNtcCA9IFN0cmluZyhhLnR5cGUgfHwgJycpLmxvY2Fs
;ZUNvbXBhcmUoU3RyaW5nKGIudHlwZSB8fCAnJyksICdlbicsIHsgc2Vuc2l0aXZpdHk6ICdiYXNlJyB9KTsKICAgICAgfSBlbHNlIGlmIChrZXkgPT09ICdo
;YW5kbGUnKSB7CiAgICAgICAgY21wID0gU3RyaW5nKGEuaGFuZGxlIHx8ICcnKS5sb2NhbGVDb21wYXJlKFN0cmluZyhiLmhhbmRsZSB8fCAnJyksICd6aC1D
;TicpOwogICAgICB9IGVsc2UgewogICAgICAgIGNtcCA9IGNvbXBhcmVQcm9jTmFtZShhLm5hbWUgfHwgJycsIGIubmFtZSB8fCAnJyk7CiAgICAgIH0KICAg
;ICAgaWYgKGNtcCkgcmV0dXJuIGNtcCAqIGRpcjsKICAgICAgLy8g5qyh6KaB6ZSu77ya56uv5Y+j5qih5byP5LyY5YWI5pys5py656uv5Y+j77yM5YaNIFBJ
;RCAvIOWQjeensAogICAgICBjb25zdCBscCA9IChOdW1iZXIoYS5sb2NhbFBvcnQpIHx8IDApIC0gKE51bWJlcihiLmxvY2FsUG9ydCkgfHwgMCk7CiAgICAg
;IGlmIChscCkgcmV0dXJuIGxwOwogICAgICBjb25zdCBwYSA9IChOdW1iZXIoYS5waWQpIHx8IDApIC0gKE51bWJlcihiLnBpZCkgfHwgMCk7CiAgICAgIGlm
;IChwYSkgcmV0dXJuIHBhOwogICAgICByZXR1cm4gY29tcGFyZVByb2NOYW1lKGEubmFtZSB8fCAnJywgYi5uYW1lIHx8ICcnKTsKICAgIH0pOwogIH0KICBm
;dW5jdGlvbiBzeW5jSGFuZGxlSGVhZFNvcnQoKSB7CiAgICBpZiAoIWhhbmRsZUhlYWQpIHJldHVybjsKICAgIGhhbmRsZUhlYWQucXVlcnlTZWxlY3RvckFs
;bCgnLmhhbmRsZS1oY2VsbFtkYXRhLXNvcnRdJykuZm9yRWFjaChjZWxsID0+IHsKICAgICAgY29uc3QgayA9IGNlbGwuZ2V0QXR0cmlidXRlKCdkYXRhLXNv
;cnQnKTsKICAgICAgY29uc3Qgb24gPSBrID09PSBoYW5kbGVTb3J0S2V5OwogICAgICBjZWxsLmNsYXNzTGlzdC50b2dnbGUoJ3NvcnRlZCcsIG9uKTsKICAg
;ICAgY2VsbC5jbGFzc0xpc3QudG9nZ2xlKCdhc2MnLCBvbiAmJiBoYW5kbGVTb3J0RGlyID4gMCk7CiAgICAgIGNlbGwuY2xhc3NMaXN0LnRvZ2dsZSgnZGVz
;YycsIG9uICYmIGhhbmRsZVNvcnREaXIgPCAwKTsKICAgIH0pOwogIH0KICBmdW5jdGlvbiBiaW5kSGFuZGxlSGVhZFNvcnQoKSB7CiAgICBpZiAoIWhhbmRs
;ZUhlYWQgfHwgaGFuZGxlSGVhZC5kYXRhc2V0LnNvcnRCb3VuZCA9PT0gJzEnKSByZXR1cm47CiAgICBoYW5kbGVIZWFkLmRhdGFzZXQuc29ydEJvdW5kID0g
;JzEnOwogICAgaGFuZGxlSGVhZC5xdWVyeVNlbGVjdG9yQWxsKCcuaGFuZGxlLWhjZWxsW2RhdGEtc29ydF0nKS5mb3JFYWNoKGNlbGwgPT4gewogICAgICBj
;ZWxsLmFkZEV2ZW50TGlzdGVuZXIoJ2NsaWNrJywgKGUpID0+IHsKICAgICAgICBlLnByZXZlbnREZWZhdWx0KCk7CiAgICAgICAgZS5zdG9wUHJvcGFnYXRp
;b24oKTsKICAgICAgICBjb25zdCBrID0gY2VsbC5nZXRBdHRyaWJ1dGUoJ2RhdGEtc29ydCcpOwogICAgICAgIGlmICghaykgcmV0dXJuOwogICAgICAgIGlm
;IChoYW5kbGVTb3J0S2V5ID09PSBrKSBoYW5kbGVTb3J0RGlyID0gLWhhbmRsZVNvcnREaXI7CiAgICAgICAgZWxzZSB7CiAgICAgICAgICBoYW5kbGVTb3J0
;S2V5ID0gazsKICAgICAgICAgIGhhbmRsZVNvcnREaXIgPSAoayA9PT0gJ2xwb3J0JyB8fCBrID09PSAncnBvcnQnIHx8IGsgPT09ICdwaWQnKSA/IDEgOiAx
;OwogICAgICAgIH0KICAgICAgICBpZiAoaGFuZGxlSXRlbXMubGVuZ3RoKSByZW5kZXJIYW5kbGVUYWJsZSgpOwogICAgICAgIGVsc2Ugc3luY0hhbmRsZUhl
;YWRTb3J0KCk7CiAgICAgIH0pOwogICAgfSk7CiAgfQogIGJpbmRIYW5kbGVIZWFkU29ydCgpOwogIGZ1bmN0aW9uIHBvcnRUaXBUZXh0KGl0KSB7CiAgICBj
;b25zdCBsaXAgPSBTdHJpbmcoaXQubG9jYWxJcCB8fCAnMC4wLjAuMCcpOwogICAgY29uc3QgbHBvcnQgPSAoaXQubG9jYWxQb3J0ID09IG51bGwgfHwgTnVt
;YmVyKGl0LmxvY2FsUG9ydCkgPCAwKSA/ICcnIDogU3RyaW5nKGl0LmxvY2FsUG9ydCk7CiAgICBjb25zdCByaXAgPSBTdHJpbmcoaXQucmVtb3RlSXAgfHwg
;JzAuMC4wLjAnKTsKICAgIGNvbnN0IHJwb3J0ID0gKGl0LnJlbW90ZVBvcnQgPT0gbnVsbCB8fCBOdW1iZXIoaXQucmVtb3RlUG9ydCkgPCAwKSA/ICcnIDog
;U3RyaW5nKGl0LnJlbW90ZVBvcnQpOwogICAgcmV0dXJuICfmnKzmnLrvvJonICsgbGlwICsgJzonICsgbHBvcnQgKyAnXG7ov5znqIvvvJonICsgcmlwICsg
;JzonICsgcnBvcnQ7CiAgfQogIGZ1bmN0aW9uIHNldEhhbmRsZVBvcnRNb2RlKG9uKSB7CiAgICBkb2N1bWVudC5xdWVyeVNlbGVjdG9yQWxsKCcuaGFuZGxl
;LWNvbHMnKS5mb3JFYWNoKGVsID0+IGVsLmNsYXNzTGlzdC50b2dnbGUoJ3BvcnQtbW9kZScsICEhb24pKTsKICAgIGRvY3VtZW50LnF1ZXJ5U2VsZWN0b3JB
;bGwoJy5oYW5kbGUtY29sLXBvcnQsLmhhbmRsZS1jb2wtcnBvcnQnKS5mb3JFYWNoKGVsID0+IGVsLmNsYXNzTGlzdC50b2dnbGUoJ2hpZGRlbicsICFvbikp
;OwogIH0KICBmdW5jdGlvbiBkZWR1cGVQb3J0SXRlbXMoaXRlbXMpIHsKICAgIGNvbnN0IG91dCA9IFtdLCBzZWVuID0gbmV3IFNldCgpOwogICAgZm9yIChj
;b25zdCBpdCBvZiBpdGVtcyB8fCBbXSkgewogICAgICBjb25zdCBrZXkgPSBbCiAgICAgICAgTnVtYmVyKGl0LnBpZCkgfHwgMCwKICAgICAgICBTdHJpbmco
;aXQudHlwZSB8fCAnJykudG9VcHBlckNhc2UoKSwKICAgICAgICBOdW1iZXIoaXQubG9jYWxQb3J0KSB8fCAwLAogICAgICAgIE51bWJlcihpdC5yZW1vdGVQ
;b3J0KSB8fCAwLAogICAgICAgIFN0cmluZyhpdC5oYW5kbGUgfHwgJycpCiAgICAgIF0uam9pbignfCcpOwogICAgICBpZiAoc2Vlbi5oYXMoa2V5KSkgY29u
;dGludWU7CiAgICAgIHNlZW4uYWRkKGtleSk7CiAgICAgIG91dC5wdXNoKGl0KTsKICAgIH0KICAgIHJldHVybiBvdXQ7CiAgfQogIGZ1bmN0aW9uIGZvcm1h
;dEhhbmRsZUJhbm5lcihxLCBwb3J0TW9kZSkgewogICAgY29uc3Qga2V5ID0gU3RyaW5nKHEgfHwgJycpLnRyaW0oKTsKICAgIGlmICgha2V5KSByZXR1cm4g
;Jyc7CiAgICBpZiAocG9ydE1vZGUgJiYgKGtleSA9PT0gREVGQVVMVF9QT1JUX1FVRVJZIHx8IC9eMFxzKi1ccyo2NTUzNSQvLnRlc3Qoa2V5KSkpCiAgICAg
;IHJldHVybiAn56uv5Y+j5pCc57Si77ya5YWo6YOo6L+e5o6lJzsKICAgIGlmIChwb3J0TW9kZSkKICAgICAgcmV0dXJuICfnq6/lj6PmkJzntKLlhbPplK7l
;rZfvvJonICsga2V5OwogICAgcmV0dXJuICflj6Xmn4TmkJzntKLlhbPplK7lrZfvvJonICsga2V5OwogIH0KICBmdW5jdGlvbiByZW5kZXJIYW5kbGVUYWJs
;ZShlbXB0eU1zZykgewogICAgY29uc3QgcSA9IGhhbmRsZVF1ZXJ5OwogICAgY29uc3QgcG9ydE1vZGUgPSBoYW5kbGVNb2RlID09PSAncG9ydCc7CiAgICBz
;ZXRIYW5kbGVQb3J0TW9kZShwb3J0TW9kZSk7CiAgICBpZiAocSkgewogICAgICBoYW5kbGVCYW5uZXIuY2xhc3NMaXN0LmFkZCgnb24nKTsKICAgICAgaGFu
;ZGxlQmFubmVyLnRleHRDb250ZW50ID0gZm9ybWF0SGFuZGxlQmFubmVyKHEsIHBvcnRNb2RlKTsKICAgIH0gZWxzZSB7CiAgICAgIGhhbmRsZUJhbm5lci5j
;bGFzc0xpc3QucmVtb3ZlKCdvbicpOwogICAgICBoYW5kbGVCYW5uZXIudGV4dENvbnRlbnQgPSAnJzsKICAgIH0KICAgIGlmIChoYW5kbGVCdXN5ICYmICFo
;YW5kbGVJdGVtcy5sZW5ndGgpIHsKICAgICAgc2hvd0hhbmRsZUxvYWRpbmcoZW1wdHlNc2cgfHwgKHBvcnRNb2RlID8gJ+ato+WcqOafpeivouerr+WPo+KA
;picgOiAn5q2j5Zyo5p+l6K+i5Y+l5p+E4oCmJykpOwogICAgICBzeW5jSGFuZGxlQmFyKDApOwogICAgICBzeW5jSGFuZGxlSGVhZFNvcnQoKTsKICAgICAg
;cmV0dXJuOwogICAgfQogICAgaWYgKHBvcnRNb2RlKSBoYW5kbGVJdGVtcyA9IGRlZHVwZVBvcnRJdGVtcyhoYW5kbGVJdGVtcyk7CiAgICBoYW5kbGVJdGVt
;cyA9IHNvcnRIYW5kbGVJdGVtcyhoYW5kbGVJdGVtcyk7CiAgICBzeW5jSGFuZGxlSGVhZFNvcnQoKTsKICAgIGNvbnN0IG4gPSBoYW5kbGVJdGVtcy5sZW5n
;dGg7CiAgICBzeW5jSGFuZGxlQmFyKG4pOwogICAgaWYgKCFuKSB7CiAgICAgIGNvbnN0IGRlZmF1bHRFbXB0eSA9IHEKICAgICAgICA/IChwb3J0TW9kZQog
;ICAgICAgICAgPyAoJ+err+WPo+aQnOe0ouWFs+mUruWtl++8micgKyBxICsgJyDigJQg5rKh5pyJ5Yy56YWN55qE56uv5Y+jJykKICAgICAgICAgIDogKCfl
;j6Xmn4TmkJzntKLlhbPplK7lrZfvvJonICsgcSArICcg4oCUIOayoeacieWMuemFjeeahOWPpeafhCcpKQogICAgICAgIDogKHBvcnRNb2RlCiAgICAgICAg
;ICA/ICfnq6/lj6PmkJzntKLvvJrovpPlhaXnq6/lj6PlpoIgODA4MHw4MCDmiJYgMC0zMDB8NTAwJwogICAgICAgICAgOiAn5Y+l5p+E5pCc57Si77ya6L6T
;5YWl5YWz6ZSu5a2X5pCc5paH5Lu25Y+l5p+EJyk7CiAgICAgIGhhbmRsZUJvZHkuaW5uZXJIVE1MID0gJzxkaXYgY2xhc3M9ImhhbmRsZS1lbXB0eSI+JyAr
;IGVzY2FwZUh0bWwoZW1wdHlNc2cgfHwgZGVmYXVsdEVtcHR5KSArICc8L2Rpdj4nOwogICAgICBoYW5kbGVTZWxLZXlzLmNsZWFyKCk7CiAgICAgIGhhbmRs
;ZUFuY2hvcktleSA9ICcnOwogICAgICByZXR1cm47CiAgICB9CiAgICBjb25zdCBrZWVwID0gbmV3IFNldCgpOwogICAgY29uc3QgZnJhZyA9IGRvY3VtZW50
;LmNyZWF0ZURvY3VtZW50RnJhZ21lbnQoKTsKICAgIGZvciAobGV0IGkgPSAwOyBpIDwgaGFuZGxlSXRlbXMubGVuZ3RoOyBpKyspIHsKICAgICAgY29uc3Qg
;aXQgPSBoYW5kbGVJdGVtc1tpXTsKICAgICAgY29uc3Qgcm93ID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnZGl2Jyk7CiAgICAgIGNvbnN0IGtleSA9IGhh
;bmRsZVJvd0tleShpdCwgaSk7CiAgICAgIGtlZXAuYWRkKGtleSk7CiAgICAgIHJvdy5jbGFzc05hbWUgPSAnaGFuZGxlLXJvdyBoYW5kbGUtY29scycgKyAo
;cG9ydE1vZGUgPyAnIHBvcnQtbW9kZScgOiAnJykgKyAoaGFuZGxlU2VsS2V5cy5oYXMoa2V5KSA/ICcgb24nIDogJycpOwogICAgICByb3cuc2V0QXR0cmli
;dXRlKCdkYXRhLWtleScsIGtleSk7CiAgICAgIHJvdy5zZXRBdHRyaWJ1dGUoJ2RhdGEtcGlkJywgU3RyaW5nKE51bWJlcihpdC5waWQpIHx8IDApKTsKICAg
;ICAgcm93LnNldEF0dHJpYnV0ZSgnZGF0YS1uYW1lJywgU3RyaW5nKGl0Lm5hbWUgfHwgJycpKTsKICAgICAgcm93LnNldEF0dHJpYnV0ZSgnZGF0YS1wYXRo
;JywgU3RyaW5nKGl0LnBhdGggfHwgJycpKTsKICAgICAgY29uc3QgbmFtZSA9IFN0cmluZyhpdC5uYW1lIHx8ICcnKTsKICAgICAgY29uc3QgcGlkTnVtID0g
;TnVtYmVyKGl0LnBpZCk7CiAgICAgIGNvbnN0IHBpZCA9IE51bWJlci5pc0Zpbml0ZShwaWROdW0pICYmIHBpZE51bSA+IDAgPyBTdHJpbmcocGlkTnVtKSA6
;ICcnOwogICAgICBjb25zdCB0eXAgPSBTdHJpbmcoaXQudHlwZSB8fCAnJyk7CiAgICAgIGNvbnN0IGhuYW1lID0gU3RyaW5nKGl0LmhhbmRsZSB8fCAnJyk7
;CiAgICAgIGNvbnN0IGxwb3J0ID0gKGl0LmxvY2FsUG9ydCA9PSBudWxsIHx8IE51bWJlcihpdC5sb2NhbFBvcnQpIDwgMCkgPyAnJyA6IFN0cmluZyhpdC5s
;b2NhbFBvcnQpOwogICAgICBjb25zdCBycG9ydE51bSA9IE51bWJlcihpdC5yZW1vdGVQb3J0KTsKICAgICAgY29uc3QgcnBvcnQgPSBOdW1iZXIuaXNGaW5p
;dGUocnBvcnROdW0pICYmIHJwb3J0TnVtID4gMCA/IFN0cmluZyhycG9ydE51bSkgOiAocG9ydE1vZGUgPyAn4oCUJyA6ICcnKTsKICAgICAgY29uc3QgdGlw
;ID0gcG9ydE1vZGUgPyBwb3J0VGlwVGV4dChpdCkgOiAoaXQucGF0aCB8fCBuYW1lKTsKICAgICAgY29uc3QgbEhvdCA9IHBvcnRNb2RlICYmIGxwb3J0ICE9
;PSAnJyAmJiBwb3J0SXNIb3QobHBvcnQpID8gJyBwb3J0LWhvdCcgOiAnJzsKICAgICAgY29uc3QgckhvdCA9IHBvcnRNb2RlICYmIHJwb3J0ICE9PSAn4oCU
;JyAmJiBycG9ydCAhPT0gJycgJiYgcG9ydElzSG90KHJwb3J0KSA/ICcgcG9ydC1ob3QnIDogJyc7CiAgICAgIGNvbnN0IGNvbm5lY3RlZCA9IHBvcnRNb2Rl
;ICYmIChobmFtZSA9PT0gJ+i/nuaOpScgfHwgL2VzdGFibGlzaGVkL2kudGVzdChobmFtZSkpOwogICAgICBjb25zdCBuZXREb3QgPSBjb25uZWN0ZWQgPyAn
;PHNwYW4gY2xhc3M9ImhhbmRsZS1uZXQtZG90IiB0aXRsZT0i5bey6L+e5o6lIj48L3NwYW4+JyA6ICcnOwogICAgICBjb25zdCBpY28gPSBpdC5pY29uCiAg
;ICAgICAgPyAnPGltZyBzcmM9IicgKyBlc2NhcGVIdG1sKFN0cmluZyhpdC5pY29uKSkgKyAnIiBhbHQ9IiIgb25lcnJvcj0idGhpcy5vbmVycm9yPW51bGw7
;dGhpcy5yZXBsYWNlV2l0aChPYmplY3QuYXNzaWduKGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoXCdzcGFuXCcpLHtjbGFzc05hbWU6XCdoYW5kbGUtaWNvLXBo
;XCd9KSkiPicKICAgICAgICA6ICc8c3BhbiBjbGFzcz0iaGFuZGxlLWljby1waCIgYXJpYS1oaWRkZW49InRydWUiPjwvc3Bhbj4nOwogICAgICByb3cuaW5u
;ZXJIVE1MID0KICAgICAgICAnPGRpdiBjbGFzcz0iaGFuZGxlLW5hbWUiIHRpdGxlPSInICsgZXNjYXBlSHRtbChpdC5wYXRoIHx8IG5hbWUpICsgJyI+JyAr
;IGljbyArICc8c3Bhbj4nICsgZXNjYXBlSHRtbChuYW1lKSArICc8L3NwYW4+PC9kaXY+JwogICAgICAgICsgJzxkaXY+JyArIGVzY2FwZUh0bWwocGlkKSAr
;ICc8L2Rpdj4nCiAgICAgICAgKyAocG9ydE1vZGUKICAgICAgICAgID8gKCc8ZGl2IGNsYXNzPSJoYW5kbGUtY29sLXBvcnQnICsgbEhvdCArICciIHRpdGxl
;PSInICsgZXNjYXBlSHRtbCh0aXApICsgJyI+JyArIGVzY2FwZUh0bWwobHBvcnQpICsgJzwvZGl2PicKICAgICAgICAgICAgKyAnPGRpdiBjbGFzcz0iaGFu
;ZGxlLWNvbC1ycG9ydCcgKyBySG90ICsgJyIgdGl0bGU9IicgKyBlc2NhcGVIdG1sKHRpcCkgKyAnIj4nICsgZXNjYXBlSHRtbChycG9ydCkgKyAnPC9kaXY+
;JykKICAgICAgICAgIDogJycpCiAgICAgICAgKyAnPGRpdj4nICsgZXNjYXBlSHRtbCh0eXApICsgJzwvZGl2PicKICAgICAgICArICc8ZGl2IGNsYXNzPSJo
;YW5kbGUtc3RhdGUiIHRpdGxlPSInICsgZXNjYXBlSHRtbChwb3J0TW9kZSA/IHRpcCA6IGhuYW1lKSArICciPicgKyBuZXREb3QgKyAnPHNwYW4+JyArIGVz
;Y2FwZUh0bWwoaG5hbWUpICsgJzwvc3Bhbj48L2Rpdj4nOwogICAgICBpZiAocG9ydE1vZGUpIHJvdy50aXRsZSA9IHRpcDsKICAgICAgcm93Lm9uY2xpY2sg
;PSAoZSkgPT4gc2VsZWN0SGFuZGxlRnJvbUV2ZW50KGUsIHJvdyk7CiAgICAgIHJvdy5vbmNvbnRleHRtZW51ID0gKGUpID0+IHsKICAgICAgICBlLnByZXZl
;bnREZWZhdWx0KCk7CiAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICBjb25zdCBrID0gcm93LmdldEF0dHJpYnV0ZSgnZGF0YS1rZXknKTsK
;ICAgICAgICBpZiAoIWhhbmRsZVNlbEtleXMuaGFzKGspKSB7CiAgICAgICAgICBoYW5kbGVTZWxLZXlzLmNsZWFyKCk7CiAgICAgICAgICBoYW5kbGVTZWxL
;ZXlzLmFkZChrKTsKICAgICAgICAgIGhhbmRsZUFuY2hvcktleSA9IGs7CiAgICAgICAgICByZWZyZXNoSGFuZGxlU2VsZWN0aW9uVUkoKTsKICAgICAgICB9
;CiAgICAgICAgc2hvd1Byb2NNZW51KGUuY2xpZW50WCwgZS5jbGllbnRZLCBjb2xsZWN0SGFuZGxlVGFyZ2V0cygpKTsKICAgICAgfTsKICAgICAgcm93Lm9u
;ZGJsY2xpY2sgPSAoKSA9PiB7CiAgICAgICAgY29uc3QgdCA9IHBvcnRNb2RlID8gdGlwIDogKGhuYW1lIHx8IG5hbWUpOwogICAgICAgIHRyeSB7IG5hdmln
;YXRvci5jbGlwYm9hcmQud3JpdGVUZXh0KHQpOyB9IGNhdGNoIChfKSB7IHBvc3QoJ2NvcHlUZXh0fCcgKyB0KTsgfQogICAgICB9OwogICAgICBmcmFnLmFw
;cGVuZENoaWxkKHJvdyk7CiAgICB9CiAgICBmb3IgKGNvbnN0IGsgb2YgQXJyYXkuZnJvbShoYW5kbGVTZWxLZXlzKSkgewogICAgICBpZiAoIWtlZXAuaGFz
;KGspKSBoYW5kbGVTZWxLZXlzLmRlbGV0ZShrKTsKICAgIH0KICAgIGhhbmRsZUJvZHkuaW5uZXJIVE1MID0gJyc7CiAgICBoYW5kbGVCb2R5LmFwcGVuZENo
;aWxkKGZyYWcpOwogIH0KICBmdW5jdGlvbiBzeW5jSGFuZGxlQmFyKG4pIHsKICAgIGlmIChhcHBNb2RlID09PSAnaGFuZGxlJykgewogICAgICBjb3VudEVs
;LnRleHRDb250ZW50ID0gJ+WFsSAnICsgKE51bWJlcihuKSB8fCAwKSArICcg5p2hJzsKICAgICAgdHJ5IHsgc3luY0ZpbGVTZWFyY2hDbGVhclBpbGwoTnVt
;YmVyKG4pIHx8IDApOyB9IGNhdGNoIChfKSB7fQogICAgfQogIH0KICBmdW5jdGlvbiBoYW5kbGVSb3dLZXkoaXQsIGlkeCkgewogICAgcmV0dXJuIFtpdC5w
;aWQsIGl0LnR5cGUsIGl0LmhhbmRsZSwgaXQubG9jYWxQb3J0LCBpdC5yZW1vdGVQb3J0LCBpZHhdLmpvaW4oJ3wnKTsKICB9CiAgZnVuY3Rpb24gcmVmcmVz
;aEhhbmRsZVNlbGVjdGlvblVJKCkgewogICAgaGFuZGxlQm9keS5xdWVyeVNlbGVjdG9yQWxsKCcuaGFuZGxlLXJvdycpLmZvckVhY2gocm93ID0+IHsKICAg
;ICAgcm93LmNsYXNzTGlzdC50b2dnbGUoJ29uJywgaGFuZGxlU2VsS2V5cy5oYXMocm93LmdldEF0dHJpYnV0ZSgnZGF0YS1rZXknKSkpOwogICAgfSk7CiAg
;fQogIGZ1bmN0aW9uIHNlbGVjdEhhbmRsZUZyb21FdmVudChlLCByb3cpIHsKICAgIGNvbnN0IGtleSA9IHJvdy5nZXRBdHRyaWJ1dGUoJ2RhdGEta2V5Jyk7
;CiAgICBjb25zdCByb3dzID0gQXJyYXkuZnJvbShoYW5kbGVCb2R5LnF1ZXJ5U2VsZWN0b3JBbGwoJy5oYW5kbGUtcm93JykpOwogICAgY29uc3QgaWR4ID0g
;cm93cy5pbmRleE9mKHJvdyk7CiAgICBpZiAoZS5zaGlmdEtleSAmJiBoYW5kbGVBbmNob3JLZXkpIHsKICAgICAgY29uc3QgYUlkeCA9IHJvd3MuZmluZElu
;ZGV4KHIgPT4gci5nZXRBdHRyaWJ1dGUoJ2RhdGEta2V5JykgPT09IGhhbmRsZUFuY2hvcktleSk7CiAgICAgIGlmIChhSWR4ID49IDAgJiYgaWR4ID49IDAp
;IHsKICAgICAgICBpZiAoIWUuY3RybEtleSkgaGFuZGxlU2VsS2V5cy5jbGVhcigpOwogICAgICAgIGNvbnN0IGxvID0gTWF0aC5taW4oYUlkeCwgaWR4KSwg
;aGkgPSBNYXRoLm1heChhSWR4LCBpZHgpOwogICAgICAgIGZvciAobGV0IGkgPSBsbzsgaSA8PSBoaTsgaSsrKSBoYW5kbGVTZWxLZXlzLmFkZChyb3dzW2ld
;LmdldEF0dHJpYnV0ZSgnZGF0YS1rZXknKSk7CiAgICAgIH0KICAgIH0gZWxzZSBpZiAoZS5jdHJsS2V5KSB7CiAgICAgIGlmIChoYW5kbGVTZWxLZXlzLmhh
;cyhrZXkpKSBoYW5kbGVTZWxLZXlzLmRlbGV0ZShrZXkpOwogICAgICBlbHNlIGhhbmRsZVNlbEtleXMuYWRkKGtleSk7CiAgICAgIGhhbmRsZUFuY2hvcktl
;eSA9IGtleTsKICAgIH0gZWxzZSB7CiAgICAgIGhhbmRsZVNlbEtleXMuY2xlYXIoKTsKICAgICAgaGFuZGxlU2VsS2V5cy5hZGQoa2V5KTsKICAgICAgaGFu
;ZGxlQW5jaG9yS2V5ID0ga2V5OwogICAgfQogICAgcmVmcmVzaEhhbmRsZVNlbGVjdGlvblVJKCk7CiAgfQogIGZ1bmN0aW9uIGNvbGxlY3RIYW5kbGVUYXJn
;ZXRzKCkgewogICAgY29uc3QgbWFwID0gbmV3IE1hcCgpOwogICAgaGFuZGxlQm9keS5xdWVyeVNlbGVjdG9yQWxsKCcuaGFuZGxlLXJvdycpLmZvckVhY2go
;cm93ID0+IHsKICAgICAgaWYgKCFoYW5kbGVTZWxLZXlzLmhhcyhyb3cuZ2V0QXR0cmlidXRlKCdkYXRhLWtleScpKSkgcmV0dXJuOwogICAgICBjb25zdCBw
;aWQgPSBOdW1iZXIocm93LmdldEF0dHJpYnV0ZSgnZGF0YS1waWQnKSkgfHwgMDsKICAgICAgaWYgKHBpZCA8PSAwIHx8IG1hcC5oYXMocGlkKSkgcmV0dXJu
;OwogICAgICBtYXAuc2V0KHBpZCwgewogICAgICAgIHBpZCwKICAgICAgICBuYW1lOiByb3cuZ2V0QXR0cmlidXRlKCdkYXRhLW5hbWUnKSB8fCAnJywKICAg
;ICAgICBwYXRoOiByb3cuZ2V0QXR0cmlidXRlKCdkYXRhLXBhdGgnKSB8fCAnJwogICAgICB9KTsKICAgIH0pOwogICAgcmV0dXJuIEFycmF5LmZyb20obWFw
;LnZhbHVlcygpKTsKICB9CiAgd2luZG93Ll9fb25Ib3N0SGlkZSA9ICgpID0+IHsgcG9zdCgncHJvY1ZpZXd8MCcpOyB9OwogIHdpbmRvdy5fX29uSG9zdFNo
;b3cgPSAoKSA9PiB7CiAgICB0cnkgeyBpZiAod2luZG93Ll9fcmVzeW5jU2VhcmNoKSB3aW5kb3cuX19yZXN5bmNTZWFyY2goKTsgfSBjYXRjaCAoXykge30K
;ICB9OwogIGRvY3VtZW50LmFkZEV2ZW50TGlzdGVuZXIoJ3Zpc2liaWxpdHljaGFuZ2UnLCAoKSA9PiB7CiAgICBpZiAoZG9jdW1lbnQuaGlkZGVuKSBwb3N0
;KCdwcm9jVmlld3wwJyk7CiAgfSk7CgogIGlmIChkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYnRuLWluZm8tcmVmcmVzaCcpKQogICAgZG9jdW1lbnQuZ2V0
;RWxlbWVudEJ5SWQoJ2J0bi1pbmZvLXJlZnJlc2gnKS5vbmNsaWNrID0gKCkgPT4gcmVxdWVzdFN5c0luZm8odHJ1ZSk7CiAgaWYgKGRvY3VtZW50LmdldEVs
;ZW1lbnRCeUlkKCdidG4taW5mby1jb3B5JykpCiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYnRuLWluZm8tY29weScpLm9uY2xpY2sgPSAoKSA9PiB7
;CiAgICAgIGNvbnN0IHQgPSBpbmZvVGV4dCB8fCAoaW5mb1BhbmVsICYmIGluZm9QYW5lbC5pbm5lclRleHQpIHx8ICcnOwogICAgICB0cnkgeyBuYXZpZ2F0
;b3IuY2xpcGJvYXJkLndyaXRlVGV4dCh0KTsgfSBjYXRjaCAoXykgeyBwb3N0KCdjb3B5VGV4dHwnICsgdCk7IH0KICAgIH07CiAgaWYgKGJ0blBvcnRNYXJr
;KSB7CiAgICBidG5Qb3J0TWFyay5vbmNsaWNrID0gKGUpID0+IHsKICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgaWYgKHBvcnRNYXJrUG9wICYm
;IHBvcnRNYXJrUG9wLmNsYXNzTGlzdC5jb250YWlucygnb24nKSkgY2xvc2VQb3J0TWFya1BvcCgpOwogICAgICBlbHNlIG9wZW5Qb3J0TWFya1BvcCgpOwog
;ICAgfTsKICB9CiAgaWYgKHBvcnRNYXJrUG9wKSBwb3J0TWFya1BvcC5hZGRFdmVudExpc3RlbmVyKCdjbGljaycsIGUgPT4gZS5zdG9wUHJvcGFnYXRpb24o
;KSk7CiAgY29uc3QgYnRuUG9ydE1hcmtBZGQgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgncG9ydC1tYXJrLWFkZCcpOwogIGNvbnN0IGJ0blBvcnRNYXJr
;UmVzZXQgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgncG9ydC1tYXJrLXJlc2V0Jyk7CiAgaWYgKGJ0blBvcnRNYXJrQWRkKSB7CiAgICBidG5Qb3J0TWFy
;a0FkZC5vbmNsaWNrID0gKGUpID0+IHsKICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgaWYgKGFkZE1hcmtlZFBvcnQocG9ydE1hcmtJbnB1dCAm
;JiBwb3J0TWFya0lucHV0LnZhbHVlKSkgewogICAgICAgIGlmIChwb3J0TWFya0lucHV0KSBwb3J0TWFya0lucHV0LnZhbHVlID0gJyc7CiAgICAgIH0KICAg
;IH07CiAgfQogIGlmIChwb3J0TWFya0lucHV0KSB7CiAgICBwb3J0TWFya0lucHV0LmFkZEV2ZW50TGlzdGVuZXIoJ2tleWRvd24nLCBlID0+IHsKICAgICAg
;aWYgKGUua2V5ID09PSAnRW50ZXInKSB7CiAgICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOwogICAgICAgIGlmIChhZGRNYXJrZWRQb3J0KHBvcnRNYXJrSW5w
;dXQudmFsdWUpKSBwb3J0TWFya0lucHV0LnZhbHVlID0gJyc7CiAgICAgIH0KICAgIH0pOwogIH0KICBpZiAoYnRuUG9ydE1hcmtSZXNldCkgewogICAgYnRu
;UG9ydE1hcmtSZXNldC5vbmNsaWNrID0gKGUpID0+IHsKICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgbWFya2VkUG9ydHMgPSBERUZBVUxUX01B
;UktFRF9QT1JUUy5zbGljZSgpOwogICAgICBzYXZlTWFya2VkUG9ydHMoKTsKICAgICAgcmVuZGVyTWFya2VkUG9ydFRhZ3MoKTsKICAgICAgaWYgKGFwcE1v
;ZGUgPT09ICdoYW5kbGUnICYmIGhhbmRsZU1vZGUgPT09ICdwb3J0JykgcmVuZGVySGFuZGxlVGFibGUoKTsKICAgIH07CiAgfQogIGRvY3VtZW50LmFkZEV2
;ZW50TGlzdGVuZXIoJ2NsaWNrJywgKCkgPT4gY2xvc2VQb3J0TWFya1BvcCgpKTsKICBjb25zdCBodHBDbG9zZSA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlk
;KCdodHAtY2xvc2UnKTsKICBpZiAoaHRwQ2xvc2UpIGh0cENsb3NlLm9uY2xpY2sgPSAoKSA9PiBjbG9zZUhhbmRsZVRhZ1BvcCgpOwogIGlmIChoYW5kbGVU
;YWdQb3ApIHsKICAgIGhhbmRsZVRhZ1BvcC5hZGRFdmVudExpc3RlbmVyKCdjbGljaycsIGUgPT4gewogICAgICBpZiAoZS50YXJnZXQgPT09IGhhbmRsZVRh
;Z1BvcCkgY2xvc2VIYW5kbGVUYWdQb3AoKTsKICAgIH0pOwogIH0KICBjb25zdCBodHBBZGQgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnaHRwLWFkZCcp
;OwogIGNvbnN0IGh0cFRpdGxlID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2h0cC10aXRsZScpOwogIGNvbnN0IGh0cFF1ZXJ5ID0gZG9jdW1lbnQuZ2V0
;RWxlbWVudEJ5SWQoJ2h0cC1xdWVyeScpOwogIGlmIChodHBBZGQpIHsKICAgIGh0cEFkZC5vbmNsaWNrID0gKGUpID0+IHsKICAgICAgZS5zdG9wUHJvcGFn
;YXRpb24oKTsKICAgICAgaWYgKGFkZEhhbmRsZVRhZyhodHBUaXRsZSAmJiBodHBUaXRsZS52YWx1ZSwgaHRwUXVlcnkgJiYgaHRwUXVlcnkudmFsdWUpKSB7
;CiAgICAgICAgaWYgKGh0cFRpdGxlKSBodHBUaXRsZS52YWx1ZSA9ICcnOwogICAgICAgIGlmIChodHBRdWVyeSkgaHRwUXVlcnkudmFsdWUgPSAnJzsKICAg
;ICAgICB0cnkgeyBpZiAoaHRwVGl0bGUpIGh0cFRpdGxlLmZvY3VzKCk7IH0gY2F0Y2ggKF8pIHt9CiAgICAgIH0gZWxzZSB7CiAgICAgICAgaWYgKCEoaHRw
;VGl0bGUgJiYgU3RyaW5nKGh0cFRpdGxlLnZhbHVlIHx8ICcnKS50cmltKCkpKSB7CiAgICAgICAgICB0cnkgeyBodHBUaXRsZSAmJiBodHBUaXRsZS5mb2N1
;cygpOyB9IGNhdGNoIChfKSB7fQogICAgICAgIH0gZWxzZSB7CiAgICAgICAgICB0cnkgeyBodHBRdWVyeSAmJiBodHBRdWVyeS5mb2N1cygpOyB9IGNhdGNo
;IChfKSB7fQogICAgICAgIH0KICAgICAgfQogICAgfTsKICB9CiAgaWYgKGh0cFF1ZXJ5KSB7CiAgICBodHBRdWVyeS5hZGRFdmVudExpc3RlbmVyKCdrZXlk
;b3duJywgZSA9PiB7CiAgICAgIGlmIChlLmtleSA9PT0gJ0VudGVyJykgewogICAgICAgIGUucHJldmVudERlZmF1bHQoKTsKICAgICAgICBpZiAoaHRwQWRk
;KSBodHBBZGQuY2xpY2soKTsKICAgICAgfQogICAgfSk7CiAgfQogIGlmIChodHBUaXRsZSkgewogICAgaHRwVGl0bGUuYWRkRXZlbnRMaXN0ZW5lcigna2V5
;ZG93bicsIGUgPT4gewogICAgICBpZiAoZS5rZXkgPT09ICdFbnRlcicpIHsKICAgICAgICBlLnByZXZlbnREZWZhdWx0KCk7CiAgICAgICAgdHJ5IHsgaHRw
;UXVlcnkgJiYgaHRwUXVlcnkuZm9jdXMoKTsgfSBjYXRjaCAoXykge30KICAgICAgfQogICAgfSk7CiAgfQogIGRvY3VtZW50LmFkZEV2ZW50TGlzdGVuZXIo
;J2tleWRvd24nLCBlID0+IHsKICAgIGlmIChlLmtleSAhPT0gJ0VzY2FwZScpIHJldHVybjsKICAgIGlmIChoYW5kbGVUYWdQb3AgJiYgaGFuZGxlVGFnUG9w
;LmNsYXNzTGlzdC5jb250YWlucygnb24nKSkgewogICAgICBjbG9zZUhhbmRsZVRhZ1BvcCgpOwogICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgfQog
;IH0sIHRydWUpOwogIHJlbmRlck1hcmtlZFBvcnRUYWdzKCk7CiAgcmVuZGVySGFuZGxlSGlzdCgpOwogIC8vIOS4u+aQnOe0ouahhue7n+S4gOaQnOe0ou+8
;m+WPpeafhOWOhuWPsui1sCDilr4g5LiL5ouJ77yI5LiO5paH5Lu25pCc57Si5LiA6Ie077yJCiAgdHJ5IHsgcUVsLnJlbW92ZUF0dHJpYnV0ZSgnbGlzdCcp
;OyB9IGNhdGNoIChfKSB7fQoKICBmdW5jdGlvbiBoaWRlUHJvY01lbnUoKSB7CiAgICBwcm9jTWVudS5jbGFzc0xpc3QucmVtb3ZlKCdvbicpOwogICAgcHJv
;Y01lbnVUYXJnZXRzID0gW107CiAgfQogIGZ1bmN0aW9uIHNob3dQcm9jTWVudSh4LCB5LCB0YXJnZXRzKSB7CiAgICBwcm9jTWVudVRhcmdldHMgPSBBcnJh
;eS5pc0FycmF5KHRhcmdldHMpID8gdGFyZ2V0cy5maWx0ZXIodCA9PiB0ICYmIE51bWJlcih0LnBpZCkgPiAwKSA6IFtdOwogICAgY29uc3QgbiA9IHByb2NN
;ZW51VGFyZ2V0cy5sZW5ndGg7CiAgICBjb25zdCBmaXJzdCA9IG4gPyBwcm9jTWVudVRhcmdldHNbMF0gOiBudWxsOwogICAgY29uc3QgbmFtZSA9IGZpcnN0
;ID8gU3RyaW5nKGZpcnN0Lm5hbWUgfHwgJycpLnRyaW0oKSA6ICcnOwogICAgY29uc3QgcGlkID0gZmlyc3QgPyBTdHJpbmcoTnVtYmVyKGZpcnN0LnBpZCkg
;fHwgJycpIDogJyc7CiAgICBjb25zdCBjb3B5TGJsID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3Byb2MtbWVudS1jb3B5Jyk7CiAgICBjb25zdCBwaWRM
;YmwgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgncHJvYy1tZW51LWNvcHlwaWQnKTsKICAgIGNvbnN0IGVuZExibCA9IGRvY3VtZW50LmdldEVsZW1lbnRC
;eUlkKCdwcm9jLW1lbnUtZW5kLWxhYmVsJyk7CiAgICBpZiAoY29weUxibCkgewogICAgICBpZiAobmFtZSAmJiBuID09PSAxKSBjb3B5TGJsLnRleHRDb250
;ZW50ID0gJ+WkjeWItui/m+eoi+WQjSAoICcgKyBuYW1lICsgJyApJzsKICAgICAgZWxzZSBpZiAobmFtZSAmJiBuID4gMSkgY29weUxibC50ZXh0Q29udGVu
;dCA9ICflpI3liLbov5vnqIvlkI0gKCAnICsgbmFtZSArICcg562JJyArIG4gKyAn5LiqICknOwogICAgICBlbHNlIGNvcHlMYmwudGV4dENvbnRlbnQgPSAn
;5aSN5Yi26L+b56iL5ZCNJzsKICAgIH0KICAgIGlmIChwaWRMYmwpIHsKICAgICAgaWYgKHBpZCAmJiBuID09PSAxKSBwaWRMYmwudGV4dENvbnRlbnQgPSAn
;5aSN5Yi26L+b56iL5Y+3ICggJyArIHBpZCArICcgKSc7CiAgICAgIGVsc2UgaWYgKHBpZCAmJiBuID4gMSkgcGlkTGJsLnRleHRDb250ZW50ID0gJ+WkjeWI
;tui/m+eoi+WPtyAoICcgKyBwaWQgKyAnIOetiScgKyBuICsgJ+S4qiApJzsKICAgICAgZWxzZSBwaWRMYmwudGV4dENvbnRlbnQgPSAn5aSN5Yi26L+b56iL
;5Y+3JzsKICAgIH0KICAgIGlmIChlbmRMYmwpIGVuZExibC50ZXh0Q29udGVudCA9ICflhbPpl63ov5vnqIsgKCAnICsgTWF0aC5tYXgobiwgMCkgKyAnICkn
;OwogICAgY29uc3QgaGFzUGF0aCA9IHByb2NNZW51VGFyZ2V0cy5zb21lKHQgPT4gdC5wYXRoKTsKICAgIHByb2NNZW51LnF1ZXJ5U2VsZWN0b3JBbGwoJ2J1
;dHRvbltkYXRhLXBhY3RdJykuZm9yRWFjaChidG4gPT4gewogICAgICBjb25zdCBhY3QgPSBidG4uZ2V0QXR0cmlidXRlKCdkYXRhLXBhY3QnKTsKICAgICAg
;aWYgKGFjdCA9PT0gJ3JldmVhbCcpIGJ0bi5kaXNhYmxlZCA9ICFoYXNQYXRoOwogICAgICBlbHNlIGJ0bi5kaXNhYmxlZCA9IG4gPCAxOwogICAgfSk7CiAg
;ICBwcm9jTWVudS5jbGFzc0xpc3QuYWRkKCdvbicpOwogICAgcHJvY01lbnUuc3R5bGUubGVmdCA9ICcwcHgnOwogICAgcHJvY01lbnUuc3R5bGUudG9wID0g
;JzBweCc7CiAgICBjb25zdCByZWN0ID0gcHJvY01lbnUuZ2V0Qm91bmRpbmdDbGllbnRSZWN0KCk7CiAgICBsZXQgbGVmdCA9IHgsIHRvcCA9IHk7CiAgICBp
;ZiAobGVmdCArIHJlY3Qud2lkdGggPiBpbm5lcldpZHRoIC0gNikgbGVmdCA9IE1hdGgubWF4KDYsIGlubmVyV2lkdGggLSByZWN0LndpZHRoIC0gNik7CiAg
;ICBpZiAodG9wICsgcmVjdC5oZWlnaHQgPiBpbm5lckhlaWdodCAtIDYpIHRvcCA9IE1hdGgubWF4KDYsIGlubmVySGVpZ2h0IC0gcmVjdC5oZWlnaHQgLSA2
;KTsKICAgIHByb2NNZW51LnN0eWxlLmxlZnQgPSBsZWZ0ICsgJ3B4JzsKICAgIHByb2NNZW51LnN0eWxlLnRvcCA9IHRvcCArICdweCc7CiAgfQogIGZ1bmN0
;aW9uIGNvcHlUZXh0U2FmZSh0ZXh0KSB7CiAgICB0ZXh0ID0gU3RyaW5nKHRleHQgfHwgJycpOwogICAgaWYgKCF0ZXh0KSByZXR1cm47CiAgICB0cnkgeyBu
;YXZpZ2F0b3IuY2xpcGJvYXJkLndyaXRlVGV4dCh0ZXh0KTsgfSBjYXRjaCAoXykgeyBwb3N0KCdjb3B5VGV4dHwnICsgdGV4dCk7IH0KICB9CiAgcHJvY01l
;bnUucXVlcnlTZWxlY3RvckFsbCgnYnV0dG9uW2RhdGEtcGFjdF0nKS5mb3JFYWNoKGJ0biA9PiB7CiAgICBidG4ub25jbGljayA9IChlKSA9PiB7CiAgICAg
;IGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAgIGNvbnN0IGFjdCA9IGJ0bi5nZXRBdHRyaWJ1dGUoJ2RhdGEtcGFjdCcpOwogICAgICBjb25zdCB0YXJnZXRz
;ID0gcHJvY01lbnVUYXJnZXRzLnNsaWNlKCk7CiAgICAgIGhpZGVQcm9jTWVudSgpOwogICAgICBpZiAoIXRhcmdldHMubGVuZ3RoKSByZXR1cm47CiAgICAg
;IGlmIChhY3QgPT09ICdlbmQnKSB7CiAgICAgICAgY29uc3QgcGlkcyA9IHRhcmdldHMubWFwKHQgPT4gTnVtYmVyKHQucGlkKSB8fCAwKS5maWx0ZXIocGlk
;ID0+IHBpZCA+IDApOwogICAgICAgIGlmIChwaWRzLmxlbmd0aCkgewogICAgICAgICAgLy8g5YWI5LuO55WM6Z2i56e76Zmk77yM5Li75py656Gu6K6k5ZCO
;5Lya5YaN5ZCM5q2l5LiA5qyhCiAgICAgICAgICByZW1vdmVSb3dzQnlQaWRzKHBpZHMpOwogICAgICAgICAgcG9zdCgncHJvY0tpbGx8JyArIHBpZHMuam9p
;bignLCcpKTsKICAgICAgICB9CiAgICAgIH0gZWxzZSBpZiAoYWN0ID09PSAncmV2ZWFsJykgewogICAgICAgIGNvbnN0IHNlZW4gPSBuZXcgU2V0KCk7CiAg
;ICAgICAgZm9yIChjb25zdCB0IG9mIHRhcmdldHMpIHsKICAgICAgICAgIGNvbnN0IHAgPSBTdHJpbmcodC5wYXRoIHx8ICcnKTsKICAgICAgICAgIGlmICgh
;cCB8fCBzZWVuLmhhcyhwLnRvTG93ZXJDYXNlKCkpKSBjb250aW51ZTsKICAgICAgICAgIHNlZW4uYWRkKHAudG9Mb3dlckNhc2UoKSk7CiAgICAgICAgICBj
;YWxsSG9zdCgncmV2ZWFsJywgcCk7CiAgICAgICAgfQogICAgICB9IGVsc2UgaWYgKGFjdCA9PT0gJ2NvcHknKSB7CiAgICAgICAgY29uc3QgbmFtZXMgPSBb
;XTsKICAgICAgICBjb25zdCBzZWVuID0gbmV3IFNldCgpOwogICAgICAgIGZvciAoY29uc3QgdCBvZiB0YXJnZXRzKSB7CiAgICAgICAgICBsZXQgbiA9IFN0
;cmluZyh0Lm5hbWUgfHwgJycpLnRyaW0oKTsKICAgICAgICAgIGlmICghbiAmJiB0LnBhdGgpIHsKICAgICAgICAgICAgY29uc3QgcCA9IFN0cmluZyh0LnBh
;dGgpLnJlcGxhY2UoL1tcXC9dKyQvLCAnJyk7CiAgICAgICAgICAgIGNvbnN0IGkgPSBNYXRoLm1heChwLmxhc3RJbmRleE9mKCdcXCcpLCBwLmxhc3RJbmRl
;eE9mKCcvJykpOwogICAgICAgICAgICBuID0gaSA+PSAwID8gcC5zbGljZShpICsgMSkgOiBwOwogICAgICAgICAgfQogICAgICAgICAgaWYgKCFuIHx8IHNl
;ZW4uaGFzKG4udG9Mb3dlckNhc2UoKSkpIGNvbnRpbnVlOwogICAgICAgICAgc2Vlbi5hZGQobi50b0xvd2VyQ2FzZSgpKTsKICAgICAgICAgIG5hbWVzLnB1
;c2gobik7CiAgICAgICAgfQogICAgICAgIGNvcHlUZXh0U2FmZShuYW1lcy5qb2luKCdcbicpKTsKICAgICAgfSBlbHNlIGlmIChhY3QgPT09ICdjb3B5UGlk
;JykgewogICAgICAgIGNvbnN0IHBpZHMgPSBbXTsKICAgICAgICBjb25zdCBzZWVuID0gbmV3IFNldCgpOwogICAgICAgIGZvciAoY29uc3QgdCBvZiB0YXJn
;ZXRzKSB7CiAgICAgICAgICBjb25zdCBwaWQgPSBOdW1iZXIodC5waWQpIHx8IDA7CiAgICAgICAgICBpZiAocGlkIDw9IDAgfHwgc2Vlbi5oYXMocGlkKSkg
;Y29udGludWU7CiAgICAgICAgICBzZWVuLmFkZChwaWQpOwogICAgICAgICAgcGlkcy5wdXNoKFN0cmluZyhwaWQpKTsKICAgICAgICB9CiAgICAgICAgY29w
;eVRleHRTYWZlKHBpZHMuam9pbignXG4nKSk7CiAgICAgIH0KICAgIH07CiAgfSk7CiAgZG9jdW1lbnQuYWRkRXZlbnRMaXN0ZW5lcignY2xpY2snLCAoKSA9
;PiBoaWRlUHJvY01lbnUoKSk7CiAgZG9jdW1lbnQuYWRkRXZlbnRMaXN0ZW5lcigna2V5ZG93bicsIChlKSA9PiB7CiAgICBpZiAoZS5rZXkgPT09ICdFc2Nh
;cGUnKSB7CiAgICAgIGhpZGVQcm9jTWVudSgpOwogICAgICBjbG9zZVBvcnRNYXJrUG9wKCk7CiAgICB9CiAgfSk7CgogIGZ1bmN0aW9uIHByb2NSb3dLZXko
;cCkgewogICAgcmV0dXJuIFtwLnByb3RvLCBwLmxvY2FsSXAsIHAubG9jYWxQb3J0LCBwLnJlbW90ZUlwLCBwLnJlbW90ZVBvcnQsIHAucGlkXS5qb2luKCd8
;Jyk7CiAgfQogIGZ1bmN0aW9uIHBvcnRzQ29udGVudFNpZyhpdGVtcykgewogICAgcmV0dXJuIChpdGVtcyB8fCBbXSkubWFwKHAgPT4KICAgICAgcHJvY1Jv
;d0tleShwKSArICdcdCcgKyAocC5wcm9jIHx8ICcnKSArICdcdCcgKyAocC5zdGF0ZSB8fCAnJykgKyAnXHQnICsgKHAucGF0aCB8fCAnJykKICAgICAgICAr
;ICdcdCcgKyAocC5wcGlkIHx8ICcnKSArICdcdCcgKyAocC5jcHUgfHwgJycpICsgJ1x0JyArIChwLm1lbSB8fCAnJykKICAgICkuam9pbignXG4nKTsKICB9
;CiAgZnVuY3Rpb24gcG9ydENlbGxUZXh0KHBvcnQpIHsKICAgIGlmIChwb3J0ID09PSAnJyB8fCBwb3J0ID09IG51bGwgfHwgTnVtYmVyKHBvcnQpIDwgMCkg
;cmV0dXJuICcnOwogICAgcmV0dXJuIFN0cmluZyhwb3J0KTsKICB9CiAgZnVuY3Rpb24gcHJvY0ljb25TdGFibGVLZXkocCkgewogICAgY29uc3QgcGF0aCA9
;IFN0cmluZygocCAmJiBwLnBhdGgpIHx8ICcnKTsKICAgIGlmIChwYXRoKSByZXR1cm4gJ3A6JyArIHBhdGgudG9Mb3dlckNhc2UoKTsKICAgIHJldHVybiAn
;aWQ6JyArIChOdW1iZXIocCAmJiBwLnBpZCkgfHwgMCk7CiAgfQogIGZ1bmN0aW9uIHNldFByb2NJY29uRWwobmFtZUJveCwgaWNvblVybCwgc3RhYmxlS2V5
;KSB7CiAgICBpZiAoIW5hbWVCb3gpIHJldHVybjsKICAgIGxldCBpbWcgPSBuYW1lQm94LnF1ZXJ5U2VsZWN0b3IoJ2ltZycpOwogICAgbGV0IHBoID0gbmFt
;ZUJveC5xdWVyeVNlbGVjdG9yKCcucHJvYy1pY28tcGgnKTsKICAgIGNvbnN0IHVybCA9IFN0cmluZyhpY29uVXJsIHx8ICcnKTsKICAgIC8vIOW3suacieeo
;s+WumuWbvuagh++8muepui/lkIwgc3JjIOmDveS4jeWKqO+8jOadnOe7nemXqueDgQogICAgaWYgKGltZykgewogICAgICBjb25zdCBjdXIgPSBpbWcuZ2V0
;QXR0cmlidXRlKCdzcmMnKSB8fCAnJzsKICAgICAgaWYgKCF1cmwgfHwgdXJsID09PSBjdXIpIHJldHVybjsKICAgICAgaW1nLnNldEF0dHJpYnV0ZSgnc3Jj
;JywgdXJsKTsKICAgICAgaWYgKHN0YWJsZUtleSkgcHJvY0ljb25TdGFibGUuc2V0KHN0YWJsZUtleSwgdXJsKTsKICAgICAgcmV0dXJuOwogICAgfQogICAg
;aWYgKCF1cmwpIHsKICAgICAgaWYgKCFwaCkgewogICAgICAgIHBoID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnc3BhbicpOwogICAgICAgIHBoLmNsYXNz
;TmFtZSA9ICdwcm9jLWljby1waCc7CiAgICAgICAgcGguc2V0QXR0cmlidXRlKCdhcmlhLWhpZGRlbicsICd0cnVlJyk7CiAgICAgICAgbmFtZUJveC5pbnNl
;cnRCZWZvcmUocGgsIG5hbWVCb3guZmlyc3RDaGlsZCk7CiAgICAgIH0KICAgICAgcmV0dXJuOwogICAgfQogICAgaW1nID0gZG9jdW1lbnQuY3JlYXRlRWxl
;bWVudCgnaW1nJyk7CiAgICBpbWcuYWx0ID0gJyc7CiAgICBpbWcuZGVjb2RpbmcgPSAnYXN5bmMnOwogICAgaW1nLnNyYyA9IHVybDsKICAgIGltZy5vbmVy
;cm9yID0gZnVuY3Rpb24gKCkgewogICAgICB0aGlzLm9uZXJyb3IgPSBudWxsOwogICAgICBjb25zdCBzID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnc3Bh
;bicpOwogICAgICBzLmNsYXNzTmFtZSA9ICdwcm9jLWljby1waCc7CiAgICAgIHMuc2V0QXR0cmlidXRlKCdhcmlhLWhpZGRlbicsICd0cnVlJyk7CiAgICAg
;IHRoaXMucmVwbGFjZVdpdGgocyk7CiAgICB9OwogICAgaWYgKHBoKSBuYW1lQm94LnJlcGxhY2VDaGlsZChpbWcsIHBoKTsKICAgIGVsc2UgbmFtZUJveC5p
;bnNlcnRCZWZvcmUoaW1nLCBuYW1lQm94LmZpcnN0Q2hpbGQpOwogICAgaWYgKHN0YWJsZUtleSkgcHJvY0ljb25TdGFibGUuc2V0KHN0YWJsZUtleSwgdXJs
;KTsKICB9CiAgZnVuY3Rpb24gZW5zdXJlUHJvY1JvdyhwKSB7CiAgICBjb25zdCByb3cgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsKICAgIHJv
;dy5jbGFzc05hbWUgPSAncHJvYy1yb3cgcHJvYy1jb2xzJzsKICAgIHJvdy5pbm5lckhUTUwgPQogICAgICAnPGRpdiBjbGFzcz0icHJvYy1jZWxsLW5hbWUi
;PjxkaXYgY2xhc3M9InByb2MtbmFtZSI+PHNwYW4gY2xhc3M9InByb2MtaWNvLXBoIiBhcmlhLWhpZGRlbj0idHJ1ZSI+PC9zcGFuPjxzcGFuIGNsYXNzPSJw
;cm9jLWxhYmVsIj48L3NwYW4+PC9kaXY+PC9kaXY+JwogICAgICArICc8ZGl2IGNsYXNzPSJwcm9jLW51bSBwcm9jLWNlbGwtY3B1IiBkYXRhLWY9ImNwdSI+
;PC9kaXY+JwogICAgICArICc8ZGl2IGNsYXNzPSJwcm9jLW51bSBwcm9jLWNlbGwtbWVtIiBkYXRhLWY9Im1lbSI+PC9kaXY+JwogICAgICArICc8ZGl2IGNs
;YXNzPSJwcm9jLW51bSBwcm9jLWNlbGwtcGlkIiBkYXRhLWY9InBpZCI+PC9kaXY+JwogICAgICArICc8ZGl2IGNsYXNzPSJwcm9jLW51bSBwcm9jLWNlbGwt
;cHJvdG8iIGRhdGEtZj0icHJvdG8iPjwvZGl2PicKICAgICAgKyAnPGRpdiBjbGFzcz0icHJvYy1udW0gcHJvYy1jZWxsLWlwIiBkYXRhLWY9ImxpcCI+PC9k
;aXY+JwogICAgICArICc8ZGl2IGNsYXNzPSJwcm9jLW51bSBwcm9jLWNlbGwtcG9ydCIgZGF0YS1mPSJscG9ydCI+PC9kaXY+JwogICAgICArICc8ZGl2IGNs
;YXNzPSJwcm9jLW51bSBwcm9jLWNlbGwtaXAiIGRhdGEtZj0icmlwIj48L2Rpdj4nCiAgICAgICsgJzxkaXYgY2xhc3M9InByb2MtbnVtIHByb2MtY2VsbC1w
;b3J0IiBkYXRhLWY9InJwb3J0Ij48L2Rpdj4nCiAgICAgICsgJzxkaXYgY2xhc3M9InByb2MtbnVtIHByb2MtY2VsbC1zdGF0ZSIgZGF0YS1mPSJzdGF0ZSI+
;PHNwYW4gY2xhc3M9InByb2MtbmV0LWRvdCBoaWRkZW4iIHRpdGxlPSLlt7Lov57mjqUiPjwvc3Bhbj48c3BhbiBjbGFzcz0icHJvYy1zdGF0ZS10eHQiPjwv
;c3Bhbj48L2Rpdj4nOwogICAgcm93Lm9uY2xpY2sgPSAoZSkgPT4gc2VsZWN0UHJvY0Zyb21FdmVudChlLCByb3cpOwogICAgcm93Lm9uY29udGV4dG1lbnUg
;PSAoZSkgPT4gewogICAgICBlLnByZXZlbnREZWZhdWx0KCk7CiAgICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAgIGNvbnN0IGtleSA9IHJvdy5nZXRB
;dHRyaWJ1dGUoJ2RhdGEta2V5Jyk7CiAgICAgIGlmICghcHJvY1NlbEtleXMuaGFzKGtleSkpIHsKICAgICAgICBzZWxlY3RQcm9jTmFtZUdyb3VwKHJvdyk7
;CiAgICAgIH0KICAgICAgc2hvd1Byb2NNZW51KGUuY2xpZW50WCwgZS5jbGllbnRZLCBjb2xsZWN0UHJvY1RhcmdldHMoKSk7CiAgICB9OwogICAgcmV0dXJu
;IHJvdzsKICB9CiAgZnVuY3Rpb24gaGVhdENvbG9yKGhvdCkgewogICAgcmV0dXJuIGhvdCA/ICcjODhmZmMxJyA6ICcjY2VmZmU1JzsKICB9CiAgZnVuY3Rp
;b24gcGFyc2VQY3QocykgewogICAgY29uc3QgbSA9IFN0cmluZyhzIHx8ICcnKS5tYXRjaCgvKFtcZC5dKykvKTsKICAgIHJldHVybiBtID8gTnVtYmVyKG1b
;MV0pIDogMDsKICB9CiAgZnVuY3Rpb24gdXBkYXRlSGVhZEhlYXQoY3B1VG90YWwsIG1lbVRvdGFsKSB7CiAgICBjb25zdCBjcHVDZWxsID0gcHJvY0hlYWQg
;JiYgcHJvY0hlYWQucXVlcnlTZWxlY3RvcignLnByb2MtaGNlbGxbZGF0YS1zb3J0PSJjcHUiXScpOwogICAgY29uc3QgbWVtQ2VsbCA9IHByb2NIZWFkICYm
;IHByb2NIZWFkLnF1ZXJ5U2VsZWN0b3IoJy5wcm9jLWhjZWxsW2RhdGEtc29ydD0ibWVtIl0nKTsKICAgIGNvbnN0IGNwdVBjdCA9IHBhcnNlUGN0KGNwdVRv
;dGFsKTsKICAgIGNvbnN0IG1lbVBjdCA9IHBhcnNlUGN0KG1lbVRvdGFsKTsKICAgIGlmIChjcHVDZWxsKSB7CiAgICAgIGNwdUNlbGwuY2xhc3NMaXN0LnRv
;Z2dsZSgnaG90JywgY3B1UGN0ID4gNSk7CiAgICAgIGNwdUNlbGwuc3R5bGUuYmFja2dyb3VuZCA9IGhlYXRDb2xvcihjcHVQY3QgPiA1KTsKICAgIH0KICAg
;IGlmIChtZW1DZWxsKSB7CiAgICAgIG1lbUNlbGwuY2xhc3NMaXN0LnRvZ2dsZSgnaG90JywgbWVtUGN0ID4gODApOwogICAgICBtZW1DZWxsLnN0eWxlLmJh
;Y2tncm91bmQgPSBoZWF0Q29sb3IobWVtUGN0ID4gODApOwogICAgfQogIH0KICBmdW5jdGlvbiB1cGRhdGVQcm9jUm93RGF0YShyb3csIHApIHsKICAgIGNv
;bnN0IGtleSA9IHByb2NSb3dLZXkocCk7CiAgICByb3cuc2V0QXR0cmlidXRlKCdkYXRhLWtleScsIGtleSk7CiAgICByb3cuc2V0QXR0cmlidXRlKCdkYXRh
;LXBpZCcsIFN0cmluZyhwLnBpZCB8fCAwKSk7CiAgICByb3cuc2V0QXR0cmlidXRlKCdkYXRhLW5hbWUnLCBTdHJpbmcocC5wcm9jIHx8ICcnKSk7CiAgICBy
;b3cuc2V0QXR0cmlidXRlKCdkYXRhLXBhdGgnLCBTdHJpbmcocC5wYXRoIHx8ICcnKSk7CiAgICBjb25zdCBuYW1lQm94ID0gcm93LnF1ZXJ5U2VsZWN0b3Io
;Jy5wcm9jLW5hbWUnKTsKICAgIGNvbnN0IGxhYmVsID0gcm93LnF1ZXJ5U2VsZWN0b3IoJy5wcm9jLWxhYmVsJyk7CiAgICBjb25zdCBuYW1lID0gcC5wcm9j
;IHx8IChwLnBpZCA/ICgnUElEICcgKyBwLnBpZCkgOiAnJyk7CiAgICBpZiAobGFiZWwgJiYgbGFiZWwudGV4dENvbnRlbnQgIT09IG5hbWUpIGxhYmVsLnRl
;eHRDb250ZW50ID0gbmFtZTsKICAgIGlmIChsYWJlbCkgbGFiZWwudGl0bGUgPSBwLnBhdGggfHwgbmFtZTsKICAgIGNvbnN0IHNrID0gcHJvY0ljb25TdGFi
;bGVLZXkocCk7CiAgICBsZXQgaWNvbiA9IFN0cmluZyhwLmljb24gfHwgJycpOwogICAgaWYgKCFpY29uICYmIHByb2NJY29uU3RhYmxlLmhhcyhzaykpCiAg
;ICAgIGljb24gPSBwcm9jSWNvblN0YWJsZS5nZXQoc2spOwogICAgc2V0UHJvY0ljb25FbChuYW1lQm94LCBpY29uLCBzayk7CiAgICBjb25zdCBzZXRUeHQg
;PSAoc2VsLCB2YWwsIHRpdGxlKSA9PiB7CiAgICAgIGNvbnN0IGVsID0gcm93LnF1ZXJ5U2VsZWN0b3Ioc2VsKTsKICAgICAgaWYgKCFlbCkgcmV0dXJuOwog
;ICAgICBjb25zdCB0ID0gdmFsID09IG51bGwgPyAnJyA6IFN0cmluZyh2YWwpOwogICAgICBpZiAoZWwudGV4dENvbnRlbnQgIT09IHQpIGVsLnRleHRDb250
;ZW50ID0gdDsKICAgICAgaWYgKHRpdGxlICE9IG51bGwpIGVsLnRpdGxlID0gdGl0bGU7CiAgICB9OwogICAgc2V0VHh0KCdbZGF0YS1mPSJjcHUiXScsIHAu
;Y3B1IHx8ICcwJScpOwogICAgc2V0VHh0KCdbZGF0YS1mPSJtZW0iXScsIHAubWVtIHx8ICcnKTsKICAgIHNldFR4dCgnW2RhdGEtZj0icGlkIl0nLCBwLnBp
;ZCB8fCAnJyk7CiAgICBzZXRUeHQoJ1tkYXRhLWY9InByb3RvIl0nLCBwLnByb3RvIHx8ICcnKTsKICAgIHNldFR4dCgnW2RhdGEtZj0ibGlwIl0nLCBwLmxv
;Y2FsSXAgfHwgJycsIHAubG9jYWxJcCB8fCAnJyk7CiAgICBjb25zdCBscG9ydCA9IHBvcnRDZWxsVGV4dChwLmxvY2FsUG9ydCk7CiAgICBzZXRUeHQoJ1tk
;YXRhLWY9Imxwb3J0Il0nLCBscG9ydCk7CiAgICBjb25zdCBscG9ydEVsID0gcm93LnF1ZXJ5U2VsZWN0b3IoJ1tkYXRhLWY9Imxwb3J0Il0nKTsKICAgIGlm
;IChscG9ydEVsKSBscG9ydEVsLmNsYXNzTGlzdC50b2dnbGUoJ3BvcnQtaG90JywgcG9ydElzSG90KHAubG9jYWxQb3J0KSAmJiBscG9ydCAhPT0gJycpOwog
;ICAgc2V0VHh0KCdbZGF0YS1mPSJyaXAiXScsIHAucmVtb3RlSXAgfHwgJycsIHAucmVtb3RlSXAgfHwgJycpOwogICAgY29uc3QgcnBvcnQgPSBwb3J0Q2Vs
;bFRleHQocC5yZW1vdGVQb3J0KTsKICAgIHNldFR4dCgnW2RhdGEtZj0icnBvcnQiXScsIHJwb3J0KTsKICAgIGNvbnN0IHJwb3J0RWwgPSByb3cucXVlcnlT
;ZWxlY3RvcignW2RhdGEtZj0icnBvcnQiXScpOwogICAgaWYgKHJwb3J0RWwpIHJwb3J0RWwuY2xhc3NMaXN0LnRvZ2dsZSgncG9ydC1ob3QnLCBwb3J0SXNI
;b3QocC5yZW1vdGVQb3J0KSAmJiBycG9ydCAhPT0gJycpOwogICAgY29uc3Qgc3QgPSBTdHJpbmcocC5zdGF0ZSB8fCAnJyk7CiAgICBjb25zdCBzdGF0ZVR4
;dCA9IHJvdy5xdWVyeVNlbGVjdG9yKCcucHJvYy1zdGF0ZS10eHQnKTsKICAgIGlmIChzdGF0ZVR4dCkgewogICAgICBpZiAoc3RhdGVUeHQudGV4dENvbnRl
;bnQgIT09IHN0KSBzdGF0ZVR4dC50ZXh0Q29udGVudCA9IHN0OwogICAgfSBlbHNlIHsKICAgICAgc2V0VHh0KCdbZGF0YS1mPSJzdGF0ZSJdJywgc3QpOwog
;ICAgfQogICAgY29uc3QgbmV0RG90ID0gcm93LnF1ZXJ5U2VsZWN0b3IoJy5wcm9jLW5ldC1kb3QnKTsKICAgIGlmIChuZXREb3QpIHsKICAgICAgY29uc3Qg
;Y29ubmVjdGVkID0gc3QgPT09ICfov57mjqUnIHx8IC9lc3RhYmxpc2hlZC9pLnRlc3Qoc3QpOwogICAgICBuZXREb3QuY2xhc3NMaXN0LnRvZ2dsZSgnaGlk
;ZGVuJywgIWNvbm5lY3RlZCk7CiAgICB9CiAgICBjb25zdCBjcHVFbCA9IHJvdy5xdWVyeVNlbGVjdG9yKCdbZGF0YS1mPSJjcHUiXScpOwogICAgY29uc3Qg
;bWVtRWwgPSByb3cucXVlcnlTZWxlY3RvcignW2RhdGEtZj0ibWVtIl0nKTsKICAgIGNvbnN0IGNwdUhvdCA9IChOdW1iZXIocC5jcHVOKSB8fCAwKSA+IDE7
;CiAgICBjb25zdCBtZW1Ib3QgPSAoTnVtYmVyKHAubWVtTikgfHwgMCkgPiAoNTEyICogMTAyNCAqIDEwMjQpOwogICAgaWYgKGNwdUVsKSB7CiAgICAgIGNw
;dUVsLmNsYXNzTGlzdC50b2dnbGUoJ2hvdCcsIGNwdUhvdCk7CiAgICAgIGNwdUVsLnN0eWxlLmJhY2tncm91bmQgPSBoZWF0Q29sb3IoY3B1SG90KTsKICAg
;IH0KICAgIGlmIChtZW1FbCkgewogICAgICBtZW1FbC5jbGFzc0xpc3QudG9nZ2xlKCdob3QnLCBtZW1Ib3QpOwogICAgICBtZW1FbC5zdHlsZS5iYWNrZ3Jv
;dW5kID0gaGVhdENvbG9yKG1lbUhvdCk7CiAgICB9CiAgfQogIC8vIOWtl+avjeaOkuW6j++8muWQjOWtl+avjSBhL0Eg5oyo5Zyo5LiA6LW377yM5LiUIGEg
;5ZyoIEEg5YmN77yIYeKApkHigKZi4oCmQuKApu+8iQogIGZ1bmN0aW9uIHByb2NOYW1lU29ydFJhbmsoY2gpIHsKICAgIGNvbnN0IGMgPSBTdHJpbmcoY2gg
;fHwgJycpOwogICAgaWYgKCFjKSByZXR1cm4gMDsKICAgIGNvbnN0IGNvZGUgPSBjLmNoYXJDb2RlQXQoMCk7CiAgICBpZiAoY29kZSA+PSA2NSAmJiBjb2Rl
;IDw9IDkwKSByZXR1cm4gKGNvZGUgLSA2NSkgKiAyICsgMTsKICAgIGlmIChjb2RlID49IDk3ICYmIGNvZGUgPD0gMTIyKSByZXR1cm4gKGNvZGUgLSA5Nykg
;KiAyOwogICAgcmV0dXJuIDIwMDAgKyBjb2RlOwogIH0KICBmdW5jdGlvbiBjb21wYXJlUHJvY05hbWUoYSwgYikgewogICAgY29uc3Qgc2EgPSBTdHJpbmco
;YSB8fCAnJyk7CiAgICBjb25zdCBzYiA9IFN0cmluZyhiIHx8ICcnKTsKICAgIGNvbnN0IG4gPSBNYXRoLm1heChzYS5sZW5ndGgsIHNiLmxlbmd0aCk7CiAg
;ICBmb3IgKGxldCBpID0gMDsgaSA8IG47IGkrKykgewogICAgICBjb25zdCBjYSA9IHNhW2ldIHx8ICcnOwogICAgICBjb25zdCBjYiA9IHNiW2ldIHx8ICcn
;OwogICAgICBpZiAoIWNhKSByZXR1cm4gLTE7CiAgICAgIGlmICghY2IpIHJldHVybiAxOwogICAgICBjb25zdCBsYSA9IGNhLnRvTG93ZXJDYXNlKCk7CiAg
;ICAgIGNvbnN0IGxiID0gY2IudG9Mb3dlckNhc2UoKTsKICAgICAgaWYgKC9bYS16XS9pLnRlc3QoY2EpICYmIC9bYS16XS9pLnRlc3QoY2IpKSB7CiAgICAg
;ICAgaWYgKGxhICE9PSBsYikgcmV0dXJuIGxhIDwgbGIgPyAtMSA6IDE7CiAgICAgICAgY29uc3QgcmEgPSBwcm9jTmFtZVNvcnRSYW5rKGNhKTsKICAgICAg
;ICBjb25zdCByYiA9IHByb2NOYW1lU29ydFJhbmsoY2IpOwogICAgICAgIGlmIChyYSAhPT0gcmIpIHJldHVybiByYSAtIHJiOwogICAgICAgIGNvbnRpbnVl
;OwogICAgICB9CiAgICAgIGNvbnN0IGNtcCA9IGNhLmxvY2FsZUNvbXBhcmUoY2IsICd6aC1DTicsIHsgbnVtZXJpYzogdHJ1ZSwgc2Vuc2l0aXZpdHk6ICd2
;YXJpYW50JyB9KTsKICAgICAgaWYgKGNtcCkgcmV0dXJuIGNtcDsKICAgIH0KICAgIHJldHVybiAwOwogIH0KICBmdW5jdGlvbiBzb3J0UHJvY1Jvd3NGbGF0
;KGl0ZW1zKSB7CiAgICBjb25zdCBkaXIgPSBwcm9jU29ydERpcjsKICAgIGNvbnN0IGtleSA9IHByb2NTb3J0S2V5OwogICAgcmV0dXJuIGl0ZW1zLnNsaWNl
;KCkuc29ydCgoYSwgYikgPT4gewogICAgICBsZXQgY21wID0gMDsKICAgICAgc3dpdGNoIChrZXkpIHsKICAgICAgICBjYXNlICdjcHUnOgogICAgICAgICAg
;Y21wID0gKE51bWJlcihhLmNwdU4pIHx8IDApIC0gKE51bWJlcihiLmNwdU4pIHx8IDApOwogICAgICAgICAgYnJlYWs7CiAgICAgICAgY2FzZSAnbWVtJzoK
;ICAgICAgICAgIGNtcCA9IChOdW1iZXIoYS5tZW1OKSB8fCAwKSAtIChOdW1iZXIoYi5tZW1OKSB8fCAwKTsKICAgICAgICAgIGJyZWFrOwogICAgICAgIGNh
;c2UgJ3BpZCc6CiAgICAgICAgICBjbXAgPSAoTnVtYmVyKGEucGlkKSB8fCAwKSAtIChOdW1iZXIoYi5waWQpIHx8IDApOwogICAgICAgICAgYnJlYWs7CiAg
;ICAgICAgY2FzZSAncHJvdG8nOgogICAgICAgICAgY21wID0gU3RyaW5nKGEucHJvdG8gfHwgJycpLmxvY2FsZUNvbXBhcmUoU3RyaW5nKGIucHJvdG8gfHwg
;JycpLCAnZW4nKTsKICAgICAgICAgIGJyZWFrOwogICAgICAgIGNhc2UgJ2xpcCc6CiAgICAgICAgICBjbXAgPSBTdHJpbmcoYS5sb2NhbElwIHx8ICcnKS5s
;b2NhbGVDb21wYXJlKFN0cmluZyhiLmxvY2FsSXAgfHwgJycpLCAnZW4nLCB7IG51bWVyaWM6IHRydWUgfSk7CiAgICAgICAgICBicmVhazsKICAgICAgICBj
;YXNlICdscG9ydCc6CiAgICAgICAgICBjbXAgPSAoTnVtYmVyKGEubG9jYWxQb3J0KSB8fCAwKSAtIChOdW1iZXIoYi5sb2NhbFBvcnQpIHx8IDApOwogICAg
;ICAgICAgYnJlYWs7CiAgICAgICAgY2FzZSAncmlwJzoKICAgICAgICAgIGNtcCA9IFN0cmluZyhhLnJlbW90ZUlwIHx8ICcnKS5sb2NhbGVDb21wYXJlKFN0
;cmluZyhiLnJlbW90ZUlwIHx8ICcnKSwgJ2VuJywgeyBudW1lcmljOiB0cnVlIH0pOwogICAgICAgICAgYnJlYWs7CiAgICAgICAgY2FzZSAncnBvcnQnOgog
;ICAgICAgICAgY21wID0gKE51bWJlcihhLnJlbW90ZVBvcnQpIHx8IDApIC0gKE51bWJlcihiLnJlbW90ZVBvcnQpIHx8IDApOwogICAgICAgICAgYnJlYWs7
;CiAgICAgICAgY2FzZSAnc3RhdGUnOgogICAgICAgICAgY21wID0gU3RyaW5nKGEuc3RhdGUgfHwgJycpLmxvY2FsZUNvbXBhcmUoU3RyaW5nKGIuc3RhdGUg
;fHwgJycpLCAnemgtQ04nKTsKICAgICAgICAgIGJyZWFrOwogICAgICAgIGNhc2UgJ25hbWUnOgogICAgICAgIGRlZmF1bHQ6CiAgICAgICAgICBjbXAgPSBj
;b21wYXJlUHJvY05hbWUoYS5wcm9jIHx8ICcnLCBiLnByb2MgfHwgJycpOwogICAgICAgICAgYnJlYWs7CiAgICAgIH0KICAgICAgaWYgKCFjbXAgJiYga2V5
;ICE9PSAnbmFtZScpCiAgICAgICAgY21wID0gY29tcGFyZVByb2NOYW1lKGEucHJvYyB8fCAnJywgYi5wcm9jIHx8ICcnKTsKICAgICAgaWYgKCFjbXApCiAg
;ICAgICAgY21wID0gKE51bWJlcihhLnBpZCkgfHwgMCkgLSAoTnVtYmVyKGIucGlkKSB8fCAwKTsKICAgICAgaWYgKCFjbXApCiAgICAgICAgY21wID0gKE51
;bWJlcihhLmxvY2FsUG9ydCkgfHwgMCkgLSAoTnVtYmVyKGIubG9jYWxQb3J0KSB8fCAwKTsKICAgICAgcmV0dXJuIGNtcCAqIGRpcjsKICAgIH0pOwogIH0K
;ICBmdW5jdGlvbiByZWZyZXNoUHJvY1NvcnRIZWFkZXJzKCkgewogICAgaWYgKCFwcm9jSGVhZCkgcmV0dXJuOwogICAgcHJvY0hlYWQucXVlcnlTZWxlY3Rv
;ckFsbCgnLnByb2MtaGNlbGxbZGF0YS1zb3J0XScpLmZvckVhY2goY2VsbCA9PiB7CiAgICAgIGNvbnN0IGsgPSBjZWxsLmdldEF0dHJpYnV0ZSgnZGF0YS1z
;b3J0Jyk7CiAgICAgIGNvbnN0IG9uID0gayA9PT0gcHJvY1NvcnRLZXk7CiAgICAgIGNlbGwuY2xhc3NMaXN0LnRvZ2dsZSgnc29ydGVkJywgb24pOwogICAg
;ICBjZWxsLmNsYXNzTGlzdC50b2dnbGUoJ2FzYycsIG9uICYmIHByb2NTb3J0RGlyID4gMCk7CiAgICAgIGNlbGwuY2xhc3NMaXN0LnRvZ2dsZSgnZGVzYycs
;IG9uICYmIHByb2NTb3J0RGlyIDwgMCk7CiAgICB9KTsKICB9CiAgaWYgKHByb2NIZWFkKSB7CiAgICBwcm9jSGVhZC5xdWVyeVNlbGVjdG9yQWxsKCcucHJv
;Yy1oY2VsbFtkYXRhLXNvcnRdJykuZm9yRWFjaChjZWxsID0+IHsKICAgICAgY2VsbC5hZGRFdmVudExpc3RlbmVyKCdjbGljaycsIChlKSA9PiB7CiAgICAg
;ICAgZS5wcmV2ZW50RGVmYXVsdCgpOwogICAgICAgIGNvbnN0IGsgPSBjZWxsLmdldEF0dHJpYnV0ZSgnZGF0YS1zb3J0Jyk7CiAgICAgICAgaWYgKCFrKSBy
;ZXR1cm47CiAgICAgICAgaWYgKHByb2NTb3J0S2V5ID09PSBrKSBwcm9jU29ydERpciA9IC1wcm9jU29ydERpcjsKICAgICAgICBlbHNlIHsKICAgICAgICAg
;IHByb2NTb3J0S2V5ID0gazsKICAgICAgICAgIC8vIOi1hOa6kOWIl+m7mOiupOmrmOKGkuS9ju+8jOWQjeensOm7mOiupCBh4oaSegogICAgICAgICAgcHJv
;Y1NvcnREaXIgPSAoayA9PT0gJ2NwdScgfHwgayA9PT0gJ21lbScgfHwgayA9PT0gJ2xwb3J0JyB8fCBrID09PSAncnBvcnQnKSA/IC0xIDogMTsKICAgICAg
;ICB9CiAgICAgICAgcmVmcmVzaFByb2NTb3J0SGVhZGVycygpOwogICAgICAgIHJlbmRlclByb2NUYWJsZSgpOwogICAgICB9KTsKICAgIH0pOwogICAgcmVm
;cmVzaFByb2NTb3J0SGVhZGVycygpOwogIH0KICBmdW5jdGlvbiBwYXRjaFByb2NJY29ucyhpdGVtcykgewogICAgbGV0IHBhdGNoZWQgPSAwOwogICAgZm9y
;IChjb25zdCBwIG9mIGl0ZW1zIHx8IFtdKSB7CiAgICAgIGlmICghcCB8fCAhcC5pY29uKSBjb250aW51ZTsKICAgICAgY29uc3Qga2V5ID0gcHJvY1Jvd0tl
;eShwKTsKICAgICAgY29uc3Qgcm93ID0gcHJvY1Jvd01hcC5nZXQoa2V5KSB8fCBwcm9jQm9keS5xdWVyeVNlbGVjdG9yKCcucHJvYy1yb3dbZGF0YS1rZXk9
;IicgKyBDU1MuZXNjYXBlKGtleSkgKyAnIl0nKTsKICAgICAgaWYgKCFyb3cpIGNvbnRpbnVlOwogICAgICBjb25zdCBuYW1lQm94ID0gcm93LnF1ZXJ5U2Vs
;ZWN0b3IoJy5wcm9jLW5hbWUnKTsKICAgICAgc2V0UHJvY0ljb25FbChuYW1lQm94LCBwLmljb24sIHByb2NJY29uU3RhYmxlS2V5KHApKTsKICAgICAgcGF0
;Y2hlZCsrOwogICAgfQogICAgcmV0dXJuIHBhdGNoZWQgPiAwIHx8IHByb2NSb3dNYXAuc2l6ZSA+IDA7CiAgfQogIGZ1bmN0aW9uIHNlbGVjdFByb2NOYW1l
;R3JvdXAocm93LCBhZGRpdGl2ZSkgewogICAgY29uc3Qga2V5ID0gcm93LmdldEF0dHJpYnV0ZSgnZGF0YS1rZXknKTsKICAgIGlmICghYWRkaXRpdmUpIHBy
;b2NTZWxLZXlzLmNsZWFyKCk7CiAgICBwcm9jU2VsS2V5cy5hZGQoa2V5KTsKICAgIHByb2NBbmNob3JLZXkgPSBrZXk7CiAgICBwcm9jU2VsS2V5ID0ga2V5
;OwogICAgcHJvY1NlbFBpZCA9IE51bWJlcihyb3cuZ2V0QXR0cmlidXRlKCdkYXRhLXBpZCcpKSB8fCAwOwogICAgcmVmcmVzaFByb2NTZWxlY3Rpb25VSSgp
;OwogIH0KICBmdW5jdGlvbiBzZWxlY3RQcm9jRnJvbUV2ZW50KGUsIHJvdykgewogICAgY29uc3Qga2V5ID0gcm93LmdldEF0dHJpYnV0ZSgnZGF0YS1rZXkn
;KTsKICAgIGNvbnN0IHBpZCA9IE51bWJlcihyb3cuZ2V0QXR0cmlidXRlKCdkYXRhLXBpZCcpKSB8fCAwOwogICAgY29uc3Qgcm93cyA9IEFycmF5LmZyb20o
;cHJvY0JvZHkucXVlcnlTZWxlY3RvckFsbCgnLnByb2Mtcm93JykpOwogICAgY29uc3QgaWR4ID0gcm93cy5pbmRleE9mKHJvdyk7CiAgICBpZiAoZS5zaGlm
;dEtleSAmJiBwcm9jQW5jaG9yS2V5KSB7CiAgICAgIGNvbnN0IGFJZHggPSByb3dzLmZpbmRJbmRleChyID0+IHIuZ2V0QXR0cmlidXRlKCdkYXRhLWtleScp
;ID09PSBwcm9jQW5jaG9yS2V5KTsKICAgICAgaWYgKGFJZHggPj0gMCAmJiBpZHggPj0gMCkgewogICAgICAgIGlmICghZS5jdHJsS2V5KSBwcm9jU2VsS2V5
;cy5jbGVhcigpOwogICAgICAgIGNvbnN0IGxvID0gTWF0aC5taW4oYUlkeCwgaWR4KSwgaGkgPSBNYXRoLm1heChhSWR4LCBpZHgpOwogICAgICAgIGZvciAo
;bGV0IGkgPSBsbzsgaSA8PSBoaTsgaSsrKSBwcm9jU2VsS2V5cy5hZGQocm93c1tpXS5nZXRBdHRyaWJ1dGUoJ2RhdGEta2V5JykpOwogICAgICB9CiAgICAg
;IHByb2NTZWxLZXkgPSBrZXk7CiAgICAgIHByb2NTZWxQaWQgPSBwaWQ7CiAgICAgIHJlZnJlc2hQcm9jU2VsZWN0aW9uVUkoKTsKICAgICAgcmV0dXJuOwog
;ICAgfQogICAgaWYgKGUuY3RybEtleSkgewogICAgICBpZiAocHJvY1NlbEtleXMuaGFzKGtleSkpIHByb2NTZWxLZXlzLmRlbGV0ZShrZXkpOwogICAgICBl
;bHNlIHByb2NTZWxLZXlzLmFkZChrZXkpOwogICAgICBwcm9jQW5jaG9yS2V5ID0ga2V5OwogICAgICBwcm9jU2VsS2V5ID0ga2V5OwogICAgICBwcm9jU2Vs
;UGlkID0gcGlkOwogICAgICByZWZyZXNoUHJvY1NlbGVjdGlvblVJKCk7CiAgICAgIHJldHVybjsKICAgIH0KICAgIC8vIOaZrumAmuWNleWHu++8muWPque7
;meeCueS4reeahOihjOW6leiJsu+8m+WQjOWQjeaVtOauteeUu+a3oee7v+WkluahhgogICAgc2VsZWN0UHJvY05hbWVHcm91cChyb3csIGZhbHNlKTsKICB9
;CiAgZnVuY3Rpb24gcmVmcmVzaFByb2NTZWxlY3Rpb25VSSgpIHsKICAgIGNvbnN0IHJvd3MgPSBBcnJheS5mcm9tKHByb2NCb2R5LnF1ZXJ5U2VsZWN0b3JB
;bGwoJy5wcm9jLXJvdycpKTsKICAgIGNvbnN0IEdSUCA9IFsnb24nLCAnZ3JwJywgJ2dycC1maXJzdCcsICdncnAtbWlkJywgJ2dycC1sYXN0JywgJ2dycC1v
;bmx5J107CiAgICBjb25zdCBzZWxlY3RlZE5hbWVzID0gbmV3IFNldCgpOwogICAgcm93cy5mb3JFYWNoKHJvdyA9PiB7CiAgICAgIEdSUC5mb3JFYWNoKGMg
;PT4gcm93LmNsYXNzTGlzdC5yZW1vdmUoYykpOwogICAgICBjb25zdCBrZXkgPSByb3cuZ2V0QXR0cmlidXRlKCdkYXRhLWtleScpOwogICAgICBpZiAocHJv
;Y1NlbEtleXMuaGFzKGtleSkpIHsKICAgICAgICByb3cuY2xhc3NMaXN0LmFkZCgnb24nKTsKICAgICAgICBjb25zdCBuYW1lID0gU3RyaW5nKHJvdy5nZXRB
;dHRyaWJ1dGUoJ2RhdGEtbmFtZScpIHx8ICcnKS50b0xvd2VyQ2FzZSgpOwogICAgICAgIGlmIChuYW1lKSBzZWxlY3RlZE5hbWVzLmFkZChuYW1lKTsKICAg
;ICAgfQogICAgfSk7CiAgICAvLyDmjInpgInkuK3ooYznmoTov5vnqIvlkI3vvIzmiorlkIzlkI3ov57nu63mrrXljIXmt6Hnu7/lpJbmoYbvvIjml6DlupXo
;ibLvvIkKICAgIGxldCBpID0gMDsKICAgIHdoaWxlIChpIDwgcm93cy5sZW5ndGgpIHsKICAgICAgY29uc3QgbmFtZSA9IFN0cmluZyhyb3dzW2ldLmdldEF0
;dHJpYnV0ZSgnZGF0YS1uYW1lJykgfHwgJycpLnRvTG93ZXJDYXNlKCk7CiAgICAgIGlmICghbmFtZSB8fCAhc2VsZWN0ZWROYW1lcy5oYXMobmFtZSkpIHsK
;ICAgICAgICBpKys7CiAgICAgICAgY29udGludWU7CiAgICAgIH0KICAgICAgbGV0IGogPSBpOwogICAgICB3aGlsZSAoaiArIDEgPCByb3dzLmxlbmd0aAog
;ICAgICAgICYmIFN0cmluZyhyb3dzW2ogKyAxXS5nZXRBdHRyaWJ1dGUoJ2RhdGEtbmFtZScpIHx8ICcnKS50b0xvd2VyQ2FzZSgpID09PSBuYW1lKSB7CiAg
;ICAgICAgaisrOwogICAgICB9CiAgICAgIGZvciAobGV0IGsgPSBpOyBrIDw9IGo7IGsrKykgewogICAgICAgIHJvd3Nba10uY2xhc3NMaXN0LmFkZCgnZ3Jw
;Jyk7CiAgICAgICAgaWYgKGkgPT09IGopIHJvd3Nba10uY2xhc3NMaXN0LmFkZCgnZ3JwLW9ubHknKTsKICAgICAgICBlbHNlIGlmIChrID09PSBpKSByb3dz
;W2tdLmNsYXNzTGlzdC5hZGQoJ2dycC1maXJzdCcpOwogICAgICAgIGVsc2UgaWYgKGsgPT09IGopIHJvd3Nba10uY2xhc3NMaXN0LmFkZCgnZ3JwLWxhc3Qn
;KTsKICAgICAgICBlbHNlIHJvd3Nba10uY2xhc3NMaXN0LmFkZCgnZ3JwLW1pZCcpOwogICAgICB9CiAgICAgIGkgPSBqICsgMTsKICAgIH0KICB9CiAgZnVu
;Y3Rpb24gY29sbGVjdFByb2NUYXJnZXRzKCkgewogICAgY29uc3QgbWFwID0gbmV3IE1hcCgpOwogICAgZm9yIChjb25zdCBrZXkgb2YgcHJvY1NlbEtleXMp
;IHsKICAgICAgY29uc3Qgcm93ID0gcHJvY1Jvd01hcC5nZXQoa2V5KSB8fCBwcm9jQm9keS5xdWVyeVNlbGVjdG9yKCcucHJvYy1yb3dbZGF0YS1rZXk9Iicg
;KyBDU1MuZXNjYXBlKGtleSkgKyAnIl0nKTsKICAgICAgbGV0IHBpZCA9IDAsIG5hbWUgPSAnJywgcGF0aCA9ICcnOwogICAgICBpZiAocm93KSB7CiAgICAg
;ICAgcGlkID0gTnVtYmVyKHJvdy5nZXRBdHRyaWJ1dGUoJ2RhdGEtcGlkJykpIHx8IDA7CiAgICAgICAgbmFtZSA9IHJvdy5nZXRBdHRyaWJ1dGUoJ2RhdGEt
;bmFtZScpIHx8ICcnOwogICAgICAgIHBhdGggPSByb3cuZ2V0QXR0cmlidXRlKCdkYXRhLXBhdGgnKSB8fCAnJzsKICAgICAgfSBlbHNlIHsKICAgICAgICBj
;b25zdCBwID0gcHJvY0l0ZW1zLmZpbmQoeCA9PiBwcm9jUm93S2V5KHgpID09PSBrZXkpOwogICAgICAgIGlmICghcCkgY29udGludWU7CiAgICAgICAgcGlk
;ID0gTnVtYmVyKHAucGlkKSB8fCAwOwogICAgICAgIG5hbWUgPSBwLnByb2MgfHwgJyc7CiAgICAgICAgcGF0aCA9IHAucGF0aCB8fCAnJzsKICAgICAgfQog
;ICAgICBpZiAocGlkIDw9IDAgfHwgbWFwLmhhcyhwaWQpKSBjb250aW51ZTsKICAgICAgaWYgKCFwYXRoKSB7CiAgICAgICAgY29uc3QgcCA9IHByb2NJdGVt
;cy5maW5kKHggPT4gTnVtYmVyKHgucGlkKSA9PT0gcGlkICYmIHgucGF0aCk7CiAgICAgICAgaWYgKHApIHBhdGggPSBwLnBhdGggfHwgJyc7CiAgICAgIH0K
;ICAgICAgbWFwLnNldChwaWQsIHsgcGlkLCBuYW1lLCBwYXRoIH0pOwogICAgfQogICAgcmV0dXJuIEFycmF5LmZyb20obWFwLnZhbHVlcygpKTsKICB9CiAg
;ZnVuY3Rpb24gcmVuZGVyUHJvY1RhYmxlKCkgewogICAgY29uc3QgcSA9IChwcm9jUS52YWx1ZSB8fCAnJykudHJpbSgpLnRvTG93ZXJDYXNlKCk7CiAgICBs
;ZXQgcm93cyA9IHByb2NJdGVtcy5zbGljZSgpOwogICAgaWYgKHEpIHsKICAgICAgcm93cyA9IHJvd3MuZmlsdGVyKHAgPT4gewogICAgICAgIGNvbnN0IGhh
;eSA9IFtwLnByb3RvLCBwLmxvY2FsSXAsIHAubG9jYWxQb3J0LCBwLnJlbW90ZUlwLCBwLnJlbW90ZVBvcnQsIHAuc3RhdGUsIHAucHJvYywgcC5waWQsIHAu
;cHBpZF0uam9pbignICcpLnRvTG93ZXJDYXNlKCk7CiAgICAgICAgcmV0dXJuIGhheS5pbmNsdWRlcyhxKTsKICAgICAgfSk7CiAgICB9CiAgICByb3dzID0g
;c29ydFByb2NSb3dzRmxhdChyb3dzKTsKICAgIGNvbnN0IHBpZFNldCA9IG5ldyBTZXQoKTsKICAgIGZvciAoY29uc3QgcCBvZiByb3dzKSB7CiAgICAgIGNv
;bnN0IGlkID0gTnVtYmVyKHAucGlkKSB8fCAwOwogICAgICBpZiAoaWQgPiAwKSBwaWRTZXQuYWRkKGlkKTsKICAgIH0KICAgIHByb2NDb3VudC50ZXh0Q29u
;dGVudCA9IFN0cmluZyhwaWRTZXQuc2l6ZSB8fCByb3dzLmxlbmd0aCk7CiAgICBpZiAoIXJvd3MubGVuZ3RoKSB7CiAgICAgIHByb2NCb2R5LmlubmVySFRN
;TCA9ICc8ZGl2IHN0eWxlPSJwYWRkaW5nOjI0cHg7dGV4dC1hbGlnbjpjZW50ZXI7Y29sb3I6IzlhYTFiMiI+5rKh5pyJ5Yy56YWN55qE6L+e5o6lPC9kaXY+
;JzsKICAgICAgcHJvY1Jvd01hcC5jbGVhcigpOwogICAgICBwcm9jU2VsS2V5cy5jbGVhcigpOwogICAgICBwcm9jQW5jaG9yS2V5ID0gJyc7CiAgICAgIHBy
;b2NTZWxLZXkgPSAnJzsKICAgICAgcHJvY1NlbFBpZCA9IDA7CiAgICAgIHJldHVybjsKICAgIH0KICAgIC8vIOWinumHj+abtOaWsO+8muWkjeeUqOihjOS4
;juWbvuagh+iKgueCue+8jOWPquaUueaWh+Wtl++8jOmBv+WFjeaVtOihqOmHjeW7uumXquWbvuaghwogICAgY29uc3Qga2VlcCA9IG5ldyBTZXQoKTsKICAg
;IGNvbnN0IGVtcHR5SGludCA9IHByb2NCb2R5LnF1ZXJ5U2VsZWN0b3IoJ2RpdltzdHlsZV0nKTsKICAgIGlmIChlbXB0eUhpbnQpIHsKICAgICAgcHJvY0Jv
;ZHkuaW5uZXJIVE1MID0gJyc7CiAgICAgIHByb2NSb3dNYXAuY2xlYXIoKTsKICAgIH0KICAgIGZvciAobGV0IGkgPSAwOyBpIDwgcm93cy5sZW5ndGg7IGkr
;KykgewogICAgICBjb25zdCBwID0gcm93c1tpXTsKICAgICAgY29uc3Qga2V5ID0gcHJvY1Jvd0tleShwKTsKICAgICAga2VlcC5hZGQoa2V5KTsKICAgICAg
;bGV0IHJvdyA9IHByb2NSb3dNYXAuZ2V0KGtleSk7CiAgICAgIGlmICghcm93IHx8ICFyb3cuaXNDb25uZWN0ZWQpIHsKICAgICAgICByb3cgPSBlbnN1cmVQ
;cm9jUm93KHApOwogICAgICAgIHByb2NSb3dNYXAuc2V0KGtleSwgcm93KTsKICAgICAgfQogICAgICB1cGRhdGVQcm9jUm93RGF0YShyb3csIHApOwogICAg
;ICBjb25zdCBhdCA9IHByb2NCb2R5LmNoaWxkcmVuW2ldOwogICAgICBpZiAoYXQgIT09IHJvdykgewogICAgICAgIGlmIChhdCkgcHJvY0JvZHkuaW5zZXJ0
;QmVmb3JlKHJvdywgYXQpOwogICAgICAgIGVsc2UgcHJvY0JvZHkuYXBwZW5kQ2hpbGQocm93KTsKICAgICAgfQogICAgfQogICAgLy8g5Yig5o6J5LiN5YaN
;5a2Y5Zyo55qE6KGMCiAgICBmb3IgKGNvbnN0IFtrZXksIHJvd10gb2YgQXJyYXkuZnJvbShwcm9jUm93TWFwLmVudHJpZXMoKSkpIHsKICAgICAgaWYgKGtl
;ZXAuaGFzKGtleSkpIGNvbnRpbnVlOwogICAgICBwcm9jUm93TWFwLmRlbGV0ZShrZXkpOwogICAgICBpZiAocm93ICYmIHJvdy5wYXJlbnROb2RlKSByb3cu
;cGFyZW50Tm9kZS5yZW1vdmVDaGlsZChyb3cpOwogICAgfQogICAgZm9yIChjb25zdCBrZXkgb2YgQXJyYXkuZnJvbShwcm9jU2VsS2V5cykpIHsKICAgICAg
;aWYgKCFrZWVwLmhhcyhrZXkpKSBwcm9jU2VsS2V5cy5kZWxldGUoa2V5KTsKICAgIH0KICAgIGlmIChwcm9jU2VsS2V5ICYmICFwcm9jU2VsS2V5cy5oYXMo
;cHJvY1NlbEtleSkpIHsKICAgICAgcHJvY1NlbEtleSA9IHByb2NTZWxLZXlzLnNpemUgPyBBcnJheS5mcm9tKHByb2NTZWxLZXlzKVswXSA6ICcnOwogICAg
;ICBwcm9jU2VsUGlkID0gMDsKICAgICAgaWYgKHByb2NTZWxLZXkpIHsKICAgICAgICBjb25zdCByID0gcHJvY1Jvd01hcC5nZXQocHJvY1NlbEtleSk7CiAg
;ICAgICAgcHJvY1NlbFBpZCA9IHIgPyAoTnVtYmVyKHIuZ2V0QXR0cmlidXRlKCdkYXRhLXBpZCcpKSB8fCAwKSA6IDA7CiAgICAgIH0KICAgIH0KICAgIHJl
;ZnJlc2hQcm9jU2VsZWN0aW9uVUkoKTsKICB9CiAgZnVuY3Rpb24gaW5mb1JvdyhsYWIsIHZhbEh0bWwsIGxpbmtIdG1sKSB7CiAgICByZXR1cm4gJzxkaXYg
;Y2xhc3M9ImluZm8tcm93Ij4nCiAgICAgICsgJzxkaXYgY2xhc3M9ImluZm8tbGFiIj4nICsgZXNjYXBlSHRtbChsYWIpICsgJzwvZGl2PicKICAgICAgKyAn
;PGRpdiBjbGFzcz0iaW5mby1kYXNoIj48L2Rpdj4nCiAgICAgICsgJzxkaXYgY2xhc3M9ImluZm8tdmFsIj4nICsgKHZhbEh0bWwgfHwgJycpICsgJzwvZGl2
;PicKICAgICAgKyAobGlua0h0bWwgfHwgJzxzcGFuPjwvc3Bhbj4nKQogICAgICArICc8L2Rpdj4nOwogIH0KICBmdW5jdGlvbiByZW5kZXJTeXNJbmZvKCkg
;ewogICAgY29uc3QgZCA9IGluZm9EYXRhIHx8IHt9OwogICAgbGV0IGh0bWwgPSAnJzsKICAgIGh0bWwgKz0gaW5mb1Jvdygn5pON5L2c57O757ufJywgZXNj
;YXBlSHRtbChkLm9zIHx8ICfmnKrnn6UnKSk7CiAgICBodG1sICs9IGluZm9Sb3coJ+S4u+advycsIGVzY2FwZUh0bWwoZC5ib2FyZCB8fCAn5pyq55+lJykp
;OwogICAgaHRtbCArPSBpbmZvUm93KCfmmL7npLrlmagnLCBlc2NhcGVIdG1sKGQubW9uaXRvciB8fCAn5pyq55+lJykpOwogICAgaHRtbCArPSBpbmZvUm93
;KCflpITnkIblmagnLCBlc2NhcGVIdG1sKGQuY3B1IHx8ICfmnKrnn6UnKSk7CiAgICBodG1sICs9IGluZm9Sb3coJ+WGheWtmCcsIGVzY2FwZUh0bWwoZC5t
;ZW1vcnkgfHwgJ+acquefpScpKTsKICAgIGh0bWwgKz0gaW5mb1Jvdygn56Gs55uYJywgZXNjYXBlSHRtbChkLmRpc2sgfHwgJ+acquefpScpKTsKICAgIGh0
;bWwgKz0gaW5mb1Jvdygn5pi+5Y2hJywgZXNjYXBlSHRtbChkLmdwdSB8fCAn5pyq55+lJykpOwogICAgY29uc3Qgc291bmRzID0gQXJyYXkuaXNBcnJheShk
;LnNvdW5kKSA/IGQuc291bmQgOiBbXTsKICAgIGh0bWwgKz0gaW5mb1Jvdygn5aOw5Y2hJywgc291bmRzLmxlbmd0aAogICAgICA/IHNvdW5kcy5tYXAocyA9
;PiAnPHNwYW4gY2xhc3M9ImxpbmUiPicgKyBlc2NhcGVIdG1sKHMpICsgJzwvc3Bhbj4nKS5qb2luKCcnKQogICAgICA6IGVzY2FwZUh0bWwoJ+acquefpScp
;KTsKICAgIGNvbnN0IG5ldHMgPSBBcnJheS5pc0FycmF5KGQubmljcykgPyBkLm5pY3MgOiBbXTsKICAgIGxldCBuZXRIdG1sID0gJ+acquefpSc7CiAgICBp
;ZiAobmV0cy5sZW5ndGgpIHsKICAgICAgbmV0SHRtbCA9IG5ldHMubWFwKG4gPT4gewogICAgICAgIGNvbnN0IG5hbWUgPSBlc2NhcGVIdG1sKG4ubmFtZSB8
;fCAnJyk7CiAgICAgICAgY29uc3QgbWFjID0gZXNjYXBlSHRtbChuLm1hYyB8fCAn4oCUJyk7CiAgICAgICAgY29uc3QgaXBSYXcgPSAobi5pcCAmJiBTdHJp
;bmcobi5pcCkudHJpbSgpKSA/IFN0cmluZyhuLmlwKS50cmltKCkgOiAnMC4wLjAuMCc7CiAgICAgICAgY29uc3QgaXAgPSBlc2NhcGVIdG1sKGlwUmF3ID09
;PSAn4oCUJyA/ICcwLjAuMC4wJyA6IGlwUmF3KTsKICAgICAgICByZXR1cm4gJzxkaXYgY2xhc3M9Im5ldC1saW5lIj48c3Bhbj4nICsgbmFtZSArICc8L3Nw
;YW4+JwogICAgICAgICAgKyAnPHNwYW4+PHNwYW4gY2xhc3M9ImsiPk1BQ+WcsOWdgDogPC9zcGFuPicgKyBtYWMgKyAnPC9zcGFuPicKICAgICAgICAgICsg
;JzxzcGFuPjxzcGFuIGNsYXNzPSJrIj5JUOWcsOWdgDogPC9zcGFuPicgKyBpcCArICc8L3NwYW4+PC9kaXY+JzsKICAgICAgfSkuam9pbignJyk7CiAgICB9
;CiAgICBodG1sICs9IGluZm9Sb3coJ+e9keWNoScsIG5ldEh0bWwpOwogICAgaHRtbCArPSBpbmZvUm93KCflpJbnvZFJUCcsIGVzY2FwZUh0bWwoZC53YW4g
;fHwgJ+acquefpScpKTsKICAgIGh0bWwgKz0gaW5mb1JvdygnSUXniYjmnKwnLCBlc2NhcGVIdG1sKGQuaWUgfHwgJ+acquefpScpKTsKICAgIGh0bWwgKz0g
;aW5mb1JvdygnRmxhc2jniYjmnKwnLCBlc2NhcGVIdG1sKGQuZmxhc2ggfHwgJ+acquefpScpKTsKICAgIGNvbnN0IGJvb3RFeHRyYSA9ICc8c3BhbiBjbGFz
;cz0ic3ViIj7ns7vnu5/lt7Lov5DooYw6IDxzcGFuIGlkPSJpbmZvLXVwdGltZSI+JwogICAgICArIGVzY2FwZUh0bWwoZm9ybWF0VXB0aW1lVGV4dChjdXJy
;ZW50VXB0aW1lU2VjKCkpKSArICc8L3NwYW4+PC9zcGFuPic7CiAgICBodG1sICs9IGluZm9Sb3coJ+W8gOacuuaXtumXtCcsIGVzY2FwZUh0bWwoZC5ib290
;IHx8ICfmnKrnn6UnKSArIGJvb3RFeHRyYSk7CiAgICBodG1sICs9IGluZm9Sb3coJ+S4iuasoeWFs+acuuaXtumXtCcsIGVzY2FwZUh0bWwoZC5zaHV0ZG93
;biB8fCAn5pyq55+lJykpOwogICAgaHRtbCArPSBpbmZvUm93KCfns7vnu5/lronoo4Xml6XmnJ8nLCBlc2NhcGVIdG1sKGQuaW5zdGFsbCB8fCAn5pyq55+l
;JykpOwogICAgaW5mb1BhbmVsLmlubmVySFRNTCA9IGh0bWw7CiAgfQogIGZ1bmN0aW9uIGN1cnJlbnRVcHRpbWVTZWMoKSB7CiAgICBjb25zdCBiYXNlID0g
;TnVtYmVyKGluZm9EYXRhICYmIGluZm9EYXRhLnVwdGltZVNlYykgfHwgMDsKICAgIGNvbnN0IHN5bmNlZCA9IE51bWJlcihpbmZvRGF0YSAmJiBpbmZvRGF0
;YS5fc3luY2VkQXQpIHx8IERhdGUubm93KCk7CiAgICByZXR1cm4gTWF0aC5tYXgoMCwgTWF0aC5mbG9vcihiYXNlICsgKERhdGUubm93KCkgLSBzeW5jZWQp
;IC8gMTAwMCkpOwogIH0KICBmdW5jdGlvbiBmb3JtYXRVcHRpbWVUZXh0KHNlYykgewogICAgc2VjID0gTWF0aC5tYXgoMCwgTWF0aC5mbG9vcihOdW1iZXIo
;c2VjKSB8fCAwKSk7CiAgICBjb25zdCBkID0gTWF0aC5mbG9vcihzZWMgLyA4NjQwMCk7CiAgICBjb25zdCBoID0gTWF0aC5mbG9vcigoc2VjICUgODY0MDAp
;IC8gMzYwMCk7CiAgICBjb25zdCBtaSA9IE1hdGguZmxvb3IoKHNlYyAlIDM2MDApIC8gNjApOwogICAgY29uc3QgcyA9IHNlYyAlIDYwOwogICAgcmV0dXJu
;IChkID4gMCA/IChkICsgJ+WkqScpIDogJycpICsgaCArICflsI/ml7YnICsgbWkgKyAn5YiG6ZKfJyArIHMgKyAn56eSJzsKICB9CiAgZnVuY3Rpb24gdGlj
;a0luZm9VcHRpbWUoKSB7CiAgICBpZiAobW9uaXRvclRhYiAhPT0gJ2luZm8nKSByZXR1cm47CiAgICBjb25zdCBlbCA9IGRvY3VtZW50LmdldEVsZW1lbnRC
;eUlkKCdpbmZvLXVwdGltZScpOwogICAgaWYgKCFlbCkgcmV0dXJuOwogICAgZWwudGV4dENvbnRlbnQgPSBmb3JtYXRVcHRpbWVUZXh0KGN1cnJlbnRVcHRp
;bWVTZWMoKSk7CiAgfQogIHNldEludGVydmFsKHRpY2tJbmZvVXB0aW1lLCAxMDAwKTsKCiAgd2luZG93Ll9fc2V0UHJvY2Vzc2VzID0gKHBheWxvYWQpID0+
;IHsKICAgIC8vIOi/m+eoi+ebkeaOp+W3suaUueS4uui/nuaOpeWIl+ihqO+8jOW/veeVpeaXp+i/m+eoi+aOqOmAgQogIH07CiAgd2luZG93Ll9fc2V0UG9y
;dHMgPSAocGF5bG9hZCkgPT4gewogICAgdHJ5IHsKICAgICAgY29uc3QgZGF0YSA9IHR5cGVvZiBwYXlsb2FkID09PSAnc3RyaW5nJyA/IEpTT04ucGFyc2Uo
;cGF5bG9hZCkgOiBwYXlsb2FkOwogICAgICBjb25zdCBuZXh0ID0gQXJyYXkuaXNBcnJheShkYXRhKSA/IGRhdGEgOiAoQXJyYXkuaXNBcnJheShkYXRhICYm
;IGRhdGEuaXRlbXMpID8gZGF0YS5pdGVtcyA6IFtdKTsKICAgICAgaWYgKGRhdGEgJiYgIUFycmF5LmlzQXJyYXkoZGF0YSkpIHsKICAgICAgICBpZiAocHJv
;Y0NwdVRvdGFsICYmIGRhdGEuY3B1VG90YWwgIT0gbnVsbCkgcHJvY0NwdVRvdGFsLnRleHRDb250ZW50ID0gU3RyaW5nKGRhdGEuY3B1VG90YWwpOwogICAg
;ICAgIGlmIChwcm9jTWVtVG90YWwgJiYgZGF0YS5tZW1Ub3RhbCAhPSBudWxsKSBwcm9jTWVtVG90YWwudGV4dENvbnRlbnQgPSBTdHJpbmcoZGF0YS5tZW1U
;b3RhbCk7CiAgICAgICAgdXBkYXRlSGVhZEhlYXQoZGF0YS5jcHVUb3RhbCwgZGF0YS5tZW1Ub3RhbCk7CiAgICAgIH0KICAgICAgY29uc3Qgc2Nyb2xsZXIg
;PSBwcm9jU2Nyb2xsIHx8IHByb2NCb2R5OwogICAgICBjb25zdCBwcmV2U2Nyb2xsID0gc2Nyb2xsZXIgPyBzY3JvbGxlci5zY3JvbGxUb3AgOiAwOwogICAg
;ICBjb25zdCBzYW1lQ29udGVudCA9IHBvcnRzQ29udGVudFNpZyhuZXh0KSA9PT0gcG9ydHNDb250ZW50U2lnKHByb2NJdGVtcyk7CiAgICAgIHByb2NJdGVt
;cyA9IG5leHQ7CiAgICAgIGlmIChtb25pdG9yVGFiICE9PSAncHJvYycpIHJldHVybjsKICAgICAgaWYgKHNhbWVDb250ZW50KSB7CiAgICAgICAgLy8g5Y+q
;6KGl5Zu+5qCH77yM5LiN6YeN5bu66KGMCiAgICAgICAgcGF0Y2hQcm9jSWNvbnMobmV4dCk7CiAgICAgICAgaWYgKHNjcm9sbGVyKSBzY3JvbGxlci5zY3Jv
;bGxUb3AgPSBwcmV2U2Nyb2xsOwogICAgICAgIHJldHVybjsKICAgICAgfQogICAgICByZW5kZXJQcm9jVGFibGUoKTsKICAgICAgaWYgKHNjcm9sbGVyKSBz
;Y3JvbGxlci5zY3JvbGxUb3AgPSBwcmV2U2Nyb2xsOwogICAgfSBjYXRjaCAoZSkgeyBjb25zb2xlLndhcm4oJ3NldFBvcnRzJywgZSk7IH0KICB9OwogIHdp
;bmRvdy5fX3NldEhhbmRsZXMgPSAocGF5bG9hZCkgPT4gewogICAgdHJ5IHsKICAgICAgY29uc3QgZGF0YSA9IHR5cGVvZiBwYXlsb2FkID09PSAnc3RyaW5n
;JyA/IEpTT04ucGFyc2UocGF5bG9hZCkgOiBwYXlsb2FkOwogICAgICBoYW5kbGVCdXN5ID0gZmFsc2U7CiAgICAgIGhhbmRsZUl0ZW1zID0gc29ydEhhbmRs
;ZUl0ZW1zKEFycmF5LmlzQXJyYXkoZGF0YSAmJiBkYXRhLml0ZW1zKSA/IGRhdGEuaXRlbXMgOiAoQXJyYXkuaXNBcnJheShkYXRhKSA/IGRhdGEgOiBbXSkp
;OwogICAgICBpZiAoZGF0YSAmJiBkYXRhLnEgIT0gbnVsbCkgaGFuZGxlUXVlcnkgPSBTdHJpbmcoZGF0YS5xKTsKICAgICAgaWYgKGRhdGEgJiYgZGF0YS5t
;b2RlKSBoYW5kbGVNb2RlID0gU3RyaW5nKGRhdGEubW9kZSkgPT09ICdwb3J0JyA/ICdwb3J0JyA6ICdoYW5kbGUnOwogICAgICBlbHNlIGhhbmRsZU1vZGUg
;PSBpc1BvcnRTZWFyY2hRdWVyeShoYW5kbGVRdWVyeSkgPyAncG9ydCcgOiAnaGFuZGxlJzsKICAgICAgY29uc3QgZXJyID0gZGF0YSAmJiBkYXRhLmVycm9y
;ID8gU3RyaW5nKGRhdGEuZXJyb3IpIDogJyc7CiAgICAgIGlmIChoYW5kbGVTdGF0dXMpIGhhbmRsZVN0YXR1cy50ZXh0Q29udGVudCA9IGVyciB8fCAoaGFu
;ZGxlSXRlbXMubGVuZ3RoID8gJycgOiAn5peg57uT5p6cJyk7CiAgICAgIGlmIChhcHBNb2RlID09PSAnaGFuZGxlJykgewogICAgICAgIHJlbmRlckhhbmRs
;ZVRhYmxlKGVyciB8fCAnJyk7CiAgICAgICAgY291bnRFbC50ZXh0Q29udGVudCA9ICflhbEgJyArIGhhbmRsZUl0ZW1zLmxlbmd0aCArICcg5p2hJzsKICAg
;ICAgfQogICAgfSBjYXRjaCAoZSkgewogICAgICBoYW5kbGVCdXN5ID0gZmFsc2U7CiAgICAgIGNvbnNvbGUud2Fybignc2V0SGFuZGxlcycsIGUpOwogICAg
;fQogIH07CiAgd2luZG93Ll9fcHJvY0tpbGxlZCA9IChwaWRzKSA9PiB7CiAgICB0cnkgewogICAgICBjb25zdCBsaXN0ID0gQXJyYXkuaXNBcnJheShwaWRz
;KSA/IHBpZHMgOiBbXTsKICAgICAgcmVtb3ZlUm93c0J5UGlkcyhsaXN0KTsKICAgIH0gY2F0Y2ggKGUpIHsgY29uc29sZS53YXJuKCdwcm9jS2lsbGVkJywg
;ZSk7IH0KICB9OwogIGZ1bmN0aW9uIHJlbW92ZVJvd3NCeVBpZHMocGlkcykgewogICAgY29uc3Qgc2V0ID0gbmV3IFNldCgocGlkcyB8fCBbXSkubWFwKG4g
;PT4gTnVtYmVyKG4pKS5maWx0ZXIobiA9PiBuID4gMCkpOwogICAgaWYgKCFzZXQuc2l6ZSkgcmV0dXJuOwogICAgY29uc3QgYmVmb3JlSCA9IGhhbmRsZUl0
;ZW1zLmxlbmd0aDsKICAgIGhhbmRsZUl0ZW1zID0gaGFuZGxlSXRlbXMuZmlsdGVyKGl0ID0+ICFzZXQuaGFzKE51bWJlcihpdC5waWQpIHx8IDApKTsKICAg
;IGlmIChoYW5kbGVJdGVtcy5sZW5ndGggIT09IGJlZm9yZUgpIHsKICAgICAgZm9yIChjb25zdCBrIG9mIEFycmF5LmZyb20oaGFuZGxlU2VsS2V5cykpIHsK
;ICAgICAgICBjb25zdCByb3cgPSBoYW5kbGVCb2R5LnF1ZXJ5U2VsZWN0b3IoJy5oYW5kbGUtcm93W2RhdGEta2V5PSInICsgQ1NTLmVzY2FwZShrKSArICci
;XScpOwogICAgICAgIGNvbnN0IHBpZCA9IHJvdyA/IChOdW1iZXIocm93LmdldEF0dHJpYnV0ZSgnZGF0YS1waWQnKSkgfHwgMCkgOiAwOwogICAgICAgIGlm
;IChzZXQuaGFzKHBpZCkpIGhhbmRsZVNlbEtleXMuZGVsZXRlKGspOwogICAgICB9CiAgICAgIGlmIChhcHBNb2RlID09PSAnaGFuZGxlJykKICAgICAgICBy
;ZW5kZXJIYW5kbGVUYWJsZSgnJyk7CiAgICAgIGlmIChhcHBNb2RlID09PSAnaGFuZGxlJykKICAgICAgICBjb3VudEVsLnRleHRDb250ZW50ID0gJ+WFsSAn
;ICsgaGFuZGxlSXRlbXMubGVuZ3RoICsgJyDmnaEnOwogICAgfQogIH07CiAgd2luZG93Ll9fc2V0U3lzSW5mbyA9IChwYXlsb2FkKSA9PiB7CiAgICB0cnkg
;ewogICAgICBpbmZvUmVxR2VuICs9IDE7CiAgICAgIGNsZWFySW5mb0xvYWRXYWl0KCk7CiAgICAgIGNvbnN0IGRhdGEgPSB0eXBlb2YgcGF5bG9hZCA9PT0g
;J3N0cmluZycgPyBKU09OLnBhcnNlKHBheWxvYWQpIDogcGF5bG9hZDsKICAgICAgY29uc3QgcHJldlNlYyA9IGluZm9EYXRhICYmIGluZm9EYXRhLnVwdGlt
;ZVNlYzsKICAgICAgY29uc3QgcHJldlN5bmMgPSBpbmZvRGF0YSAmJiBpbmZvRGF0YS5fc3luY2VkQXQ7CiAgICAgIGluZm9EYXRhID0gZGF0YSB8fCB7fTsK
;ICAgICAgLy8g5ZCM5LiA5Lu957yT5a2Y5YaN5qyh5o6o6YCB5pe25L+d55WZ5ZCM5q2l54K577yM6YG/5YWN6L+Q6KGM5pe26Ze06KKr6YeN572uCiAgICAg
;IGlmIChwcmV2U3luYyAmJiBwcmV2U2VjICE9IG51bGwgJiYgTnVtYmVyKGluZm9EYXRhLnVwdGltZVNlYykgPT09IE51bWJlcihwcmV2U2VjKSkKICAgICAg
;ICBpbmZvRGF0YS5fc3luY2VkQXQgPSBwcmV2U3luYzsKICAgICAgZWxzZQogICAgICAgIGluZm9EYXRhLl9zeW5jZWRBdCA9IERhdGUubm93KCk7CiAgICAg
;IGlmIChpbmZvRGF0YS51cHRpbWVTZWMgPT0gbnVsbCAmJiBpbmZvRGF0YS51cHRpbWUpCiAgICAgICAgaW5mb0RhdGEudXB0aW1lU2VjID0gMDsKICAgICAg
;aW5mb1RleHQgPSBTdHJpbmcoZGF0YSAmJiBkYXRhLnRleHQgfHwgJycpOwogICAgICBpZiAoYXBwTW9kZSA9PT0gJ2luZm8nKSB7CiAgICAgICAgcmVuZGVy
;U3lzSW5mbygpOwogICAgICAgIGlmIChjb3VudEVsKSBjb3VudEVsLnRleHRDb250ZW50ID0gJ+acrOacuuS/oeaBryc7CiAgICAgIH0KICAgIH0gY2F0Y2gg
;KGUpIHsgY29uc29sZS53YXJuKCdzZXRTeXNJbmZvJywgZSk7IH0KICB9OwoKICAvLyDilIDilIAg6L+Q6KGM6YWN572uIC8g5Y+W5YC86YWN572uIC8g57O7
;57uf6YWN572uIOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgAogIGNvbnN0IGNmZ0JvZHkgPSBkb2N1bWVudC5n
;ZXRFbGVtZW50QnlJZCgnY2ZnLWJvZHknKTsKICBjb25zdCBjZmdTdGF0dXMgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnY2ZnLXN0YXR1cycpOwogIGNv
;bnN0IGNmZ01lbnUgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnY2ZnLW1lbnUnKTsKICBjb25zdCBjZmdUaXBFbCA9IGRvY3VtZW50LmdldEVsZW1lbnRC
;eUlkKCdjZmctdGlwJyk7CiAgY29uc3QgY2ZnVGlwRWRpdEVsID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2NmZy10aXAtZWRpdCcpOwogIGNvbnN0IGNm
;Z1RpcFdyYXBFbCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjZmctdGlwLXdyYXAnKTsKICBjb25zdCBjZmdDYWNoZSA9IHsgcnVuY29uZmlnOiBudWxs
;LCBnZXRjb25maWc6IG51bGwsIHN5c2NvbmZpZzogbnVsbCB9OwogIGNvbnN0IGNmZ0RpcnR5ID0geyBydW5jb25maWc6IGZhbHNlLCBnZXRjb25maWc6IGZh
;bHNlLCBzeXNjb25maWc6IGZhbHNlIH07CiAgY29uc3QgY2ZnUGF0aHMgPSB7IHJ1bmNvbmZpZzogJycsIGdldGNvbmZpZzogJycsIHN5c2NvbmZpZzogJycg
;fTsKICBjb25zdCBDRkdfVElQX1NFUF9ERUZBVUxUID0gMTAxOwogIGNvbnN0IENGR19USVBfSEFTSF9ERUZBVUxUID0gMzsKICBjb25zdCBjZmdJY29uQ2Fj
;aGUgPSBuZXcgTWFwKCk7CiAgY29uc3QgY2ZnT3Blbk1hcCA9IE9iamVjdC5jcmVhdGUobnVsbCk7IC8vIHRhYiAtPiB7IFtnaV06IHRydWUgfQogIGxldCBj
;ZmdVaVJlYWR5ID0gZmFsc2U7CiAgbGV0IGNmZ1NlYXJjaCA9ICcnOwogIGxldCBjZmdTZWFyY2hTY29wZSA9IHsga2V5OiBmYWxzZSwgdmFsdWU6IGZhbHNl
;LCBlbmFibGVkOiBmYWxzZSwgZGlzYWJsZWQ6IGZhbHNlIH07CiAgY29uc3QgY2ZnU2VhcmNoSGl0RWwgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnY2Zn
;LXNlYXJjaC1oaXQnKTsKICBjb25zdCBjZmdTZWFyY2hDbGVhckVsID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2NmZy1zZWFyY2gtY2xlYXInKTsKICBs
;ZXQgY2ZnTG9hZEdlbiA9IDA7CiAgbGV0IGNmZ0ljb25TZXEgPSAwOwogIGxldCBjZmdTZWwgPSB7IGdpOiAtMSwgaWk6IC0xIH07CiAgbGV0IGNmZ01lbnVD
;dHggPSBudWxsOwogIGxldCBjZmdBZGREcmFmdEdpID0gLTE7CgogIGNvbnN0IENGR19TVkcgPSB7CiAgICB3ZWI6ICc8c3ZnIHZpZXdCb3g9IjAgMCAyNCAy
;NCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0cm9rZS13aWR0aD0iMS44Ij48Y2lyY2xlIGN4PSIxMiIgY3k9IjEyIiByPSI5Ii8+PHBh
;dGggZD0iTTMgMTJoMThNMTIgM2ExNCAxNCAwIDAgMSAwIDE4TTEyIDNhMTQgMTQgMCAwIDAgMCAxOCIvPjwvc3ZnPicsCiAgICBmb2xkZXI6ICc8c3ZnIHZp
;ZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0cm9rZS13aWR0aD0iMS44Ij48cGF0aCBkPSJNMyA3LjVBMS41
;IDEuNSAwIDAgMSA0LjUgNkg5bDIgMmg4LjVBMS41IDEuNSAwIDAgMSAyMSA5LjV2N0ExLjUgMS41IDAgMCAxIDE5LjUgMThoLTE1QTEuNSAxLjUgMCAwIDEg
;MyAxNi41di05eiIvPjwvc3ZnPicsCiAgICBjbWQ6ICc8c3ZnIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSJjdXJyZW50Q29sb3Ii
;IHN0cm9rZS13aWR0aD0iMS44Ij48cmVjdCB4PSIzIiB5PSI1IiB3aWR0aD0iMTgiIGhlaWdodD0iMTQiIHJ4PSIyIi8+PHBhdGggZD0iTTcgMTBsMyAyLTMg
;Mk0xMiAxNGg1Ii8+PC9zdmc+JywKICAgIGZpbGU6ICc8c3ZnIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSJjdXJyZW50Q29sb3Ii
;IHN0cm9rZS13aWR0aD0iMS44Ij48cGF0aCBkPSJNNyAzLjVoN2w0IDRWMjBhMS41IDEuNSAwIDAgMS0xLjUgMS41aC05LjVBMS41IDEuNSAwIDAgMSA1LjUg
;MjBWNUExLjUgMS41IDAgMCAxIDcgMy41eiIvPjxwYXRoIGQ9Ik0xNCAzLjVWOGg0LjUiLz48L3N2Zz4nCiAgfTsKCiAgZnVuY3Rpb24gdGV4dFRvQjY0KHMp
;IHsKICAgIHRyeSB7IHJldHVybiBidG9hKHVuZXNjYXBlKGVuY29kZVVSSUNvbXBvbmVudChTdHJpbmcocyB8fCAnJykpKSk7IH0KICAgIGNhdGNoIChfKSB7
;IHJldHVybiAnJzsgfQogIH0KICBsZXQgY2ZnU3RhdHVzVGltZXIgPSAwOwogIGZ1bmN0aW9uIHNldENmZ1N0YXR1cyhtc2csIGtpbmQpIHsKICAgIGlmICgh
;Y2ZnU3RhdHVzKSByZXR1cm47CiAgICBpZiAoY2ZnU3RhdHVzVGltZXIpIHsKICAgICAgY2xlYXJUaW1lb3V0KGNmZ1N0YXR1c1RpbWVyKTsKICAgICAgY2Zn
;U3RhdHVzVGltZXIgPSAwOwogICAgfQogICAgY29uc3QgdGV4dCA9IFN0cmluZyhtc2cgfHwgJycpLnRyaW0oKTsKICAgIGlmICghdGV4dCkgewogICAgICBj
;ZmdTdGF0dXMudGV4dENvbnRlbnQgPSAnJzsKICAgICAgY2ZnU3RhdHVzLmNsYXNzTmFtZSA9ICcnOwogICAgICByZXR1cm47CiAgICB9CiAgICBjb25zdCBr
;ID0ga2luZCA9PT0gJ29rJyA/ICdvaycgOiAoa2luZCA9PT0gJ2luZm8nID8gJ2luZm8nIDogJ2VycicpOwogICAgY2ZnU3RhdHVzLnRleHRDb250ZW50ID0g
;dGV4dDsKICAgIGNmZ1N0YXR1cy5jbGFzc05hbWUgPSBrOwogICAgaWYgKGsgPT09ICdvaycgfHwgayA9PT0gJ2luZm8nKSB7CiAgICAgIGNmZ1N0YXR1c1Rp
;bWVyID0gc2V0VGltZW91dCgoKSA9PiB7CiAgICAgICAgaWYgKGNmZ1N0YXR1cyAmJiBjZmdTdGF0dXMuY2xhc3NOYW1lID09PSBrICYmIGNmZ1N0YXR1cy50
;ZXh0Q29udGVudCA9PT0gdGV4dCkgewogICAgICAgICAgY2ZnU3RhdHVzLnRleHRDb250ZW50ID0gJyc7CiAgICAgICAgICBjZmdTdGF0dXMuY2xhc3NOYW1l
;ID0gJyc7CiAgICAgICAgfQogICAgICAgIGNmZ1N0YXR1c1RpbWVyID0gMDsKICAgICAgfSwgMzIwMCk7CiAgICB9CiAgfQogIGZ1bmN0aW9uIGxvb2tzTGlr
;ZVdpblBhdGgocykgewogICAgcyA9IFN0cmluZyhzIHx8ICcnKS50cmltKCk7CiAgICBpZiAoIXMpIHJldHVybiBmYWxzZTsKICAgIGlmICgvXltBLVphLXpd
;Oig/OltcXFwvXXwkKS8udGVzdChzKSkgcmV0dXJuIHRydWU7CiAgICBpZiAoL15cXFxcW15cXFwvXSsvLnRlc3QocykpIHJldHVybiB0cnVlOwogICAgaWYg
;KC8lW0EtWmEtel9dW0EtWmEtejAtOV9dKiUvLnRlc3QocykpIHJldHVybiB0cnVlOwogICAgcmV0dXJuIGZhbHNlOwogIH0KICBmdW5jdGlvbiBzcGxpdFdp
;blBhdGhQYXJ0cyhmdWxsKSB7CiAgICBsZXQgcyA9IFN0cmluZyhmdWxsIHx8ICcnKS5yZXBsYWNlKC9cLy9nLCAnXFwnKS50cmltKCk7CiAgICBpZiAoIXMp
;IHJldHVybiBbXTsKICAgIGNvbnN0IHBhcnRzID0gW107CiAgICBpZiAoL15cXFxcLy50ZXN0KHMpKSB7CiAgICAgIGNvbnN0IHJlc3QgPSBzLnJlcGxhY2Uo
;L15cXFxcLywgJycpLnNwbGl0KCdcXCcpLmZpbHRlcihCb29sZWFuKTsKICAgICAgaWYgKCFyZXN0Lmxlbmd0aCkgcmV0dXJuIFsnXFxcXCddOwogICAgICBw
;YXJ0cy5wdXNoKCdcXFxcJyArIHJlc3RbMF0pOwogICAgICBmb3IgKGxldCBpID0gMTsgaSA8IHJlc3QubGVuZ3RoOyBpKyspIHBhcnRzLnB1c2gocmVzdFtp
;XSk7CiAgICAgIHJldHVybiBwYXJ0czsKICAgIH0KICAgIGNvbnN0IG0gPSBzLm1hdGNoKC9eKFtBLVphLXpdOikoPzpcXCguKikpPyQvKTsKICAgIGlmICht
;KSB7CiAgICAgIHBhcnRzLnB1c2gobVsxXSk7CiAgICAgIGlmIChtWzJdKSBwYXJ0cy5wdXNoKC4uLm1bMl0uc3BsaXQoJ1xcJykuZmlsdGVyKEJvb2xlYW4p
;KTsKICAgICAgcmV0dXJuIHBhcnRzOwogICAgfQogICAgcmV0dXJuIHMuc3BsaXQoJ1xcJykuZmlsdGVyKEJvb2xlYW4pOwogIH0KICBmdW5jdGlvbiBqb2lu
;V2luUGF0aFBhcnRzKHBhcnRzLCB1cHRvKSB7CiAgICBpZiAoIXBhcnRzLmxlbmd0aCB8fCB1cHRvIDwgMCkgcmV0dXJuICcnOwogICAgY29uc3QgbiA9IE1h
;dGgubWluKHVwdG8gKyAxLCBwYXJ0cy5sZW5ndGgpOwogICAgY29uc3QgaGVhZCA9IHBhcnRzWzBdOwogICAgaWYgKC9eXFxcXC8udGVzdChoZWFkKSkgewog
;ICAgICBsZXQgb3V0ID0gaGVhZDsKICAgICAgZm9yIChsZXQgaSA9IDE7IGkgPCBuOyBpKyspIG91dCArPSAnXFwnICsgcGFydHNbaV07CiAgICAgIHJldHVy
;biBvdXQ7CiAgICB9CiAgICBpZiAoL15bQS1aYS16XTokLy50ZXN0KGhlYWQpKSB7CiAgICAgIGlmIChuID09PSAxKSByZXR1cm4gaGVhZCArICdcXCc7CiAg
;ICAgIHJldHVybiBoZWFkICsgJ1xcJyArIHBhcnRzLnNsaWNlKDEsIG4pLmpvaW4oJ1xcJyk7CiAgICB9CiAgICByZXR1cm4gcGFydHMuc2xpY2UoMCwgbiku
;am9pbignXFwnKTsKICB9CiAgZnVuY3Rpb24gb3BlbkNmZ1BhdGhTZWdtZW50KGZ1bGxQYXRoLCBpc0xhc3QpIHsKICAgIGxldCBwID0gU3RyaW5nKGZ1bGxQ
;YXRoIHx8ICcnKS50cmltKCk7CiAgICBpZiAoIXApIHJldHVybjsKICAgIGNvbnN0IGJhcmUgPSBwLnJlcGxhY2UoL1tcXFwvXSskLywgJycpOwogICAgaWYg
;KC9cLnR4dCQvaS50ZXN0KGJhcmUpKSB7CiAgICAgIGNhbGxIb3N0KCdvcGVuVHh0JywgYmFyZSk7CiAgICAgIHJldHVybjsKICAgIH0KICAgIGlmIChpc0xh
;c3QgJiYgL1wuW0EtWmEtejAtOV17MSwxMn0kLy50ZXN0KGJhcmUpKSB7CiAgICAgIGNhbGxIb3N0KCdyZXZlYWwnLCBiYXJlKTsKICAgICAgcmV0dXJuOwog
;ICAgfQogICAgaWYgKC9eW0EtWmEtel06XFw/JC8udGVzdChwKSkgcCA9IHAucmVwbGFjZSgvXFw/JC8sICcnKSArICdcXCc7CiAgICBlbHNlIHAgPSBiYXJl
;OwogICAgY2FsbEhvc3QoJ29wZW5QYXRoJywgcCk7CiAgfQogIGZ1bmN0aW9uIHJlbmRlckNmZ1BhdGhTZWdtZW50cyhwYXRoRWwsIHRleHQpIHsKICAgIHBh
;dGhFbC50ZXh0Q29udGVudCA9ICcnOwogICAgY29uc3QgZnVsbCA9IFN0cmluZyh0ZXh0IHx8ICcnKTsKICAgIGlmICghbG9va3NMaWtlV2luUGF0aChmdWxs
;KSkgewogICAgICBwYXRoRWwudGV4dENvbnRlbnQgPSBmdWxsOwogICAgICByZXR1cm47CiAgICB9CiAgICBjb25zdCBwYXJ0cyA9IHNwbGl0V2luUGF0aFBh
;cnRzKGZ1bGwpOwogICAgaWYgKCFwYXJ0cy5sZW5ndGgpIHsKICAgICAgcGF0aEVsLnRleHRDb250ZW50ID0gZnVsbDsKICAgICAgcmV0dXJuOwogICAgfQog
;ICAgcGFydHMuZm9yRWFjaCgocGFydCwgaSkgPT4gewogICAgICBpZiAoaSA+IDApIHsKICAgICAgICBjb25zdCBzZXAgPSBkb2N1bWVudC5jcmVhdGVFbGVt
;ZW50KCdzcGFuJyk7CiAgICAgICAgc2VwLmNsYXNzTmFtZSA9ICdjZmctc2VwJzsKICAgICAgICBzZXAudGV4dENvbnRlbnQgPSAnXFwnOwogICAgICAgIHBh
;dGhFbC5hcHBlbmRDaGlsZChzZXApOwogICAgICB9CiAgICAgIGNvbnN0IHNlZyA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ3NwYW4nKTsKICAgICAgc2Vn
;LmNsYXNzTmFtZSA9ICdjZmctc2VnJzsKICAgICAgc2VnLnRleHRDb250ZW50ID0gcGFydDsKICAgICAgY29uc3QgYWNjID0gam9pbldpblBhdGhQYXJ0cyhw
;YXJ0cywgaSk7CiAgICAgIHNlZy5kYXRhc2V0LnBhdGggPSBhY2M7CiAgICAgIHNlZy50aXRsZSA9IGFjYyArICfvvIhDdHJsK+eCueWHu+aJk+W8gO+8iSc7
;CiAgICAgIHNlZy5hZGRFdmVudExpc3RlbmVyKCdjbGljaycsIChlKSA9PiB7CiAgICAgICAgaWYgKCFlLmN0cmxLZXkpIHJldHVybjsKICAgICAgICBlLnBy
;ZXZlbnREZWZhdWx0KCk7CiAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICBvcGVuQ2ZnUGF0aFNlZ21lbnQoYWNjLCBpID09PSBwYXJ0cy5s
;ZW5ndGggLSAxKTsKICAgICAgfSk7CiAgICAgIHBhdGhFbC5hcHBlbmRDaGlsZChzZWcpOwogICAgfSk7CiAgfQogIGZ1bmN0aW9uIHN5bmNDZmdQYXRoQ3Ry
;bFVpKG9uKSB7CiAgICBjb25zdCBwYXRoRWwgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnY2ZnLXBhdGgtbGFiZWwnKTsKICAgIGlmIChwYXRoRWwpIHBh
;dGhFbC5jbGFzc0xpc3QudG9nZ2xlKCdjdHJsLWhlbGQnLCAhIW9uKTsKICB9CiAgZG9jdW1lbnQuYWRkRXZlbnRMaXN0ZW5lcigna2V5ZG93bicsIChlKSA9
;PiB7CiAgICBpZiAoZS5rZXkgPT09ICdDb250cm9sJykgc3luY0NmZ1BhdGhDdHJsVWkodHJ1ZSk7CiAgfSk7CiAgZG9jdW1lbnQuYWRkRXZlbnRMaXN0ZW5l
;cigna2V5dXAnLCAoZSkgPT4gewogICAgaWYgKGUua2V5ID09PSAnQ29udHJvbCcpIHN5bmNDZmdQYXRoQ3RybFVpKGZhbHNlKTsKICB9KTsKICB3aW5kb3cu
;YWRkRXZlbnRMaXN0ZW5lcignYmx1cicsICgpID0+IHN5bmNDZmdQYXRoQ3RybFVpKGZhbHNlKSk7CiAgZnVuY3Rpb24gdXBkYXRlQ2ZnUGF0aEJhcihleHRy
;YSkgewogICAgY29uc3QgcGF0aEVsID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2NmZy1wYXRoLWxhYmVsJyk7CiAgICBjb25zdCBmaWxlUGF0aCA9IGNm
;Z1BhdGhzW2NmZ0FjdGl2ZVRhYl0gfHwgKGNmZ0FjdGl2ZVRhYiArICcudHh0Jyk7CiAgICBjb25zdCB0aXAgPSBTdHJpbmcoZXh0cmEgfHwgJycpLnRyaW0o
;KTsKICAgIGNvbnN0IHRleHQgPSB0aXAgfHwgZmlsZVBhdGg7CiAgICBpZiAocGF0aEVsKSB7CiAgICAgIHBhdGhFbC5kYXRhc2V0LmZ1bGxQYXRoID0gdGV4
;dDsKICAgICAgcGF0aEVsLnRpdGxlID0gdGV4dCArIChsb29rc0xpa2VXaW5QYXRoKHRleHQpID8gJ++8iOaMieS9jyBDdHJsIOeCueWHu+i3r+W+hOavj+S4
;gOe6p+WPr+aJk+W8gO+8iScgOiAnJyk7CiAgICAgIHJlbmRlckNmZ1BhdGhTZWdtZW50cyhwYXRoRWwsIHRleHQpOwogICAgfQogICAgaWYgKGNvdW50RWwg
;JiYgYXBwTW9kZSA9PT0gJ2NvbmZpZycpIHsKICAgICAgY291bnRFbC50ZXh0Q29udGVudCA9ICcnOwogICAgfQogIH0KICBmdW5jdGlvbiBzeW5jQ2ZnVGlw
;VWkoKSB7CiAgICBjb25zdCB3cmFwID0gY2ZnVGlwV3JhcEVsIHx8IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjZmctdGlwLXdyYXAnKTsKICAgIGlmICgh
;Y2ZnVGlwRWwgfHwgIXdyYXApIHJldHVybjsKICAgIGVuZENmZ1RpcEVkaXQoZmFsc2UpOwogICAgY29uc3QgZCA9IGNmZ0RvYygpOwogICAgY29uc3QgdGlw
;ID0gZCA/IFN0cmluZyhkLnRpcCB8fCAnJykgOiAnJzsKICAgIGNvbnN0IHNob3cgPSBTdHJpbmcodGlwKS50cmltKCk7CiAgICBpZiAoIXNob3cpIHsKICAg
;ICAgY2ZnVGlwRWwudGV4dENvbnRlbnQgPSAnJzsKICAgICAgaWYgKGNmZ1RpcEVkaXRFbCkgY2ZnVGlwRWRpdEVsLnZhbHVlID0gJyc7CiAgICAgIHdyYXAu
;Y2xhc3NMaXN0LmFkZCgnaGlkZGVuJyk7CiAgICAgIHJldHVybjsKICAgIH0KICAgIGNmZ1RpcEVsLnRleHRDb250ZW50ID0gdGlwLnJlcGxhY2UoL15cbit8
;XG4rJC9nLCAnJyk7CiAgICBpZiAoY2ZnVGlwRWRpdEVsKSBjZmdUaXBFZGl0RWwudmFsdWUgPSBjZmdUaXBFbC50ZXh0Q29udGVudDsKICAgIHdyYXAuY2xh
;c3NMaXN0LnJlbW92ZSgnaGlkZGVuJyk7CiAgfQogIGZ1bmN0aW9uIGJlZ2luQ2ZnVGlwRWRpdCgpIHsKICAgIGNvbnN0IHdyYXAgPSBjZmdUaXBXcmFwRWwg
;fHwgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2NmZy10aXAtd3JhcCcpOwogICAgY29uc3QgZCA9IGNmZ0RvYygpOwogICAgaWYgKCF3cmFwIHx8ICFjZmdU
;aXBFZGl0RWwgfHwgIWQpIHJldHVybjsKICAgIGNmZ1RpcEVkaXRFbC52YWx1ZSA9IFN0cmluZyhkLnRpcCB8fCBjZmdUaXBFbC50ZXh0Q29udGVudCB8fCAn
;Jyk7CiAgICB3cmFwLmNsYXNzTGlzdC5hZGQoJ2VkaXRpbmcnKTsKICAgIHRyeSB7CiAgICAgIGNmZ1RpcEVkaXRFbC5mb2N1cygpOwogICAgICBjb25zdCBu
;ID0gY2ZnVGlwRWRpdEVsLnZhbHVlLmxlbmd0aDsKICAgICAgY2ZnVGlwRWRpdEVsLnNldFNlbGVjdGlvblJhbmdlKG4sIG4pOwogICAgfSBjYXRjaCAoXykg
;e30KICB9CiAgZnVuY3Rpb24gZW5kQ2ZnVGlwRWRpdChjb21taXQpIHsKICAgIGNvbnN0IHdyYXAgPSBjZmdUaXBXcmFwRWwgfHwgZG9jdW1lbnQuZ2V0RWxl
;bWVudEJ5SWQoJ2NmZy10aXAtd3JhcCcpOwogICAgaWYgKCF3cmFwIHx8ICF3cmFwLmNsYXNzTGlzdC5jb250YWlucygnZWRpdGluZycpKSByZXR1cm47CiAg
;ICBpZiAoY29tbWl0ICYmIGNmZ1RpcEVkaXRFbCkgewogICAgICBjb25zdCBkID0gY2ZnRG9jKCk7CiAgICAgIGlmIChkKSB7CiAgICAgICAgY29uc3QgbmV4
;dCA9IFN0cmluZyhjZmdUaXBFZGl0RWwudmFsdWUgfHwgJycpOwogICAgICAgIGlmIChTdHJpbmcoZC50aXAgfHwgJycpICE9PSBuZXh0KSB7CiAgICAgICAg
;ICBkLnRpcCA9IG5leHQ7CiAgICAgICAgICBtYXJrQ2ZnRGlydHkoKTsKICAgICAgICB9CiAgICAgICAgY2ZnVGlwRWwudGV4dENvbnRlbnQgPSBuZXh0LnJl
;cGxhY2UoL15cbit8XG4rJC9nLCAnJyk7CiAgICAgICAgaWYgKCFTdHJpbmcobmV4dCkudHJpbSgpKSB3cmFwLmNsYXNzTGlzdC5hZGQoJ2hpZGRlbicpOwog
;ICAgICAgIGVsc2Ugd3JhcC5jbGFzc0xpc3QucmVtb3ZlKCdoaWRkZW4nKTsKICAgICAgfQogICAgfQogICAgd3JhcC5jbGFzc0xpc3QucmVtb3ZlKCdlZGl0
;aW5nJyk7CiAgfQogIGZ1bmN0aW9uIGlzQ29uZmlnU2VwTGluZSh0KSB7IHJldHVybiAvXiN7OCx9XHMqJC8udGVzdCh0KTsgfQogIGZ1bmN0aW9uIGNvdW50
;TGVhZGluZ0hhc2godCkgewogICAgY29uc3QgbSA9IFN0cmluZyh0IHx8ICcnKS5tYXRjaCgvXigjKykvKTsKICAgIHJldHVybiBtID8gbVsxXS5sZW5ndGgg
;OiAwOwogIH0KICBmdW5jdGlvbiBpc0NvbmZpZ0dyb3VwTGluZSh0KSB7CiAgICBpZiAoIXQgfHwgdC5pbmRleE9mKCc9JykgPj0gMCkgcmV0dXJuIGZhbHNl
;OwogICAgcmV0dXJuIC9eI3szLH0uKuOAkFte44CRXSvjgJEvLnRlc3QodCk7CiAgfQogIGZ1bmN0aW9uIHBhcnNlQ29uZmlnR3JvdXBUaXRsZSh0KSB7CiAg
;ICBjb25zdCByYXcgPSB0LnJlcGxhY2UoL14jK1xzKi8sICcnKS50cmltKCk7CiAgICBjb25zdCBtID0gcmF3Lm1hdGNoKC/jgJAoW17jgJFdKynjgJEvKTsK
;ICAgIHJldHVybiBtID8gbVsxXS50cmltKCkgOiByYXc7CiAgfQogIGZ1bmN0aW9uIHN0cmlwRGVwcmVjYXRlZE1hcmsodmFsKSB7CiAgICBjb25zdCBzID0g
;U3RyaW5nKHZhbCA/PyAnJyk7CiAgICBjb25zdCBtID0gcy5tYXRjaCgvXiguKj8pXHMrI+W8g+eUqFxzKiQvKTsKICAgIHJldHVybiBtID8gbVsxXSA6IHM7
;CiAgfQogIGZ1bmN0aW9uIHBhcnNlRGlzYWJsZWRLdih0KSB7CiAgICBjb25zdCBtID0gdC5tYXRjaCgvXiNccyooW149XSs/KVxzKj1ccyooLiopJC8pOwog
;ICAgaWYgKCFtKSByZXR1cm4gbnVsbDsKICAgIGNvbnN0IGtleSA9IG1bMV0udHJpbSgpOwogICAgaWYgKCFrZXkpIHJldHVybiBudWxsOwogICAgcmV0dXJu
;IHsga2V5LCB2YWx1ZTogc3RyaXBEZXByZWNhdGVkTWFyayhtWzJdKS50cmltRW5kKCksIGVuYWJsZWQ6IGZhbHNlLCBjb21tZW50OiAnJyB9OwogIH0KICBm
;dW5jdGlvbiBwYXJzZUt2KHQpIHsKICAgIGNvbnN0IG0gPSB0Lm1hdGNoKC9eKFtePSNdW149XSo/KVxzKj1ccyooLiopJC8pOwogICAgaWYgKCFtKSByZXR1
;cm4gbnVsbDsKICAgIGNvbnN0IGtleSA9IG1bMV0udHJpbSgpOwogICAgaWYgKCFrZXkpIHJldHVybiBudWxsOwogICAgcmV0dXJuIHsga2V5LCB2YWx1ZTog
;c3RyaXBEZXByZWNhdGVkTWFyayhtWzJdKS50cmltRW5kKCksIGVuYWJsZWQ6IHRydWUsIGNvbW1lbnQ6ICcnIH07CiAgfQogIGZ1bmN0aW9uIG5vcm1hbGl6
;ZUl0ZW0oaXQpIHsKICAgIGlmICghaXQpIHJldHVybiBpdDsKICAgIGlmICh0eXBlb2YgaXQuZW5hYmxlZCAhPT0gJ2Jvb2xlYW4nKSBpdC5lbmFibGVkID0g
;IWl0LmRpc2FibGVkOwogICAgZGVsZXRlIGl0LmRpc2FibGVkOwogICAgcmV0dXJuIGl0OwogIH0KICBmdW5jdGlvbiBlbXB0eUNmZ0RvYygpIHsKICAgIHJl
;dHVybiB7CiAgICAgIHRpcDogJycsCiAgICAgIHRpcFNlcDogQ0ZHX1RJUF9TRVBfREVGQVVMVCwKICAgICAgdGlwSGFzaDogQ0ZHX1RJUF9IQVNIX0RFRkFV
;TFQsCiAgICAgIGdyb3VwczogW10KICAgIH07CiAgfQogIGZ1bmN0aW9uIHBhcnNlQWhrQ29uZmlnVGV4dCh0ZXh0KSB7CiAgICBjb25zdCBkb2MgPSBlbXB0
;eUNmZ0RvYygpOwogICAgY29uc3QgZ3JvdXBzID0gW3sgdGl0bGU6ICfpu5jorqQnLCBpdGVtczogW10gfV07CiAgICBsZXQgZ2kgPSAwOwogICAgbGV0IHBl
;bmRpbmdDb21tZW50ID0gJyc7CiAgICBjb25zdCBsaW5lcyA9IFN0cmluZyh0ZXh0IHx8ICcnKS5yZXBsYWNlKC9eXHVGRUZGLywgJycpLnNwbGl0KC9ccj9c
;bi8pOwogICAgbGV0IGkgPSAwOwogICAgLy8g6Lez6L+H5byA5aS056m66KGMCiAgICB3aGlsZSAoaSA8IGxpbmVzLmxlbmd0aCAmJiAhU3RyaW5nKGxpbmVz
;W2ldIHx8ICcnKS50cmltKCkpIGkrKzsKICAgIC8vIOaWh+S7tuWktOazqOmHiuWdl++8miMjIyMjIyMj4oCmIC8gIyMj6K+05piO4oCmIC8gIyMjIyMjIyPi
;gKYKICAgIGlmIChpIDwgbGluZXMubGVuZ3RoICYmIGlzQ29uZmlnU2VwTGluZShTdHJpbmcobGluZXNbaV0gfHwgJycpLnRyaW0oKSkpIHsKICAgICAgZG9j
;LnRpcFNlcCA9IGNvdW50TGVhZGluZ0hhc2goU3RyaW5nKGxpbmVzW2ldIHx8ICcnKS50cmltKCkpIHx8IENGR19USVBfU0VQX0RFRkFVTFQ7CiAgICAgIGkr
;KzsKICAgICAgY29uc3QgdGlwUGFydHMgPSBbXTsKICAgICAgbGV0IHRpcEhhc2ggPSAwOwogICAgICB3aGlsZSAoaSA8IGxpbmVzLmxlbmd0aCkgewogICAg
;ICAgIGNvbnN0IHJhdyA9IFN0cmluZyhsaW5lc1tpXSB8fCAnJyk7CiAgICAgICAgY29uc3QgdCA9IHJhdy50cmltKCk7CiAgICAgICAgaWYgKGlzQ29uZmln
;U2VwTGluZSh0KSkgeyBpKys7IGJyZWFrOyB9CiAgICAgICAgLy8g5YiG57uE5aS057uT5p2f6K+05piO5Z2X77yb5LiN6KaB55SoIHBhcnNlRGlzYWJsZWRL
;du+8iCMjI3g9eSDor7TmmI7ooYzkvJrooqvor6/liKTvvIkKICAgICAgICBpZiAoaXNDb25maWdHcm91cExpbmUodCkpIGJyZWFrOwogICAgICAgIGlmICh0
;LmNoYXJBdCgwKSA9PT0gJyMnKSB7CiAgICAgICAgICBjb25zdCBuID0gY291bnRMZWFkaW5nSGFzaCh0KTsKICAgICAgICAgIGlmICghdGlwSGFzaCAmJiBu
;ID4gMCkgdGlwSGFzaCA9IG47CiAgICAgICAgICB0aXBQYXJ0cy5wdXNoKHQucmVwbGFjZSgvXiMrLywgJycpKTsKICAgICAgICAgIGkrKzsKICAgICAgICAg
;IGNvbnRpbnVlOwogICAgICAgIH0KICAgICAgICAvLyDor7TmmI7lnZfmnKrpl63lkIjlsLHlh7rnjrDoo7gga2V5PXZhbHVl77yM57uT5p2f6K+05piOCiAg
;ICAgICAgaWYgKHBhcnNlS3YodCkpIGJyZWFrOwogICAgICAgIGlmICh0KSB0aXBQYXJ0cy5wdXNoKHQpOwogICAgICAgIGVsc2UgdGlwUGFydHMucHVzaCgn
;Jyk7CiAgICAgICAgaSsrOwogICAgICB9CiAgICAgIGRvYy50aXBIYXNoID0gdGlwSGFzaCB8fCBDRkdfVElQX0hBU0hfREVGQVVMVDsKICAgICAgd2hpbGUg
;KHRpcFBhcnRzLmxlbmd0aCAmJiAhU3RyaW5nKHRpcFBhcnRzWzBdKS50cmltKCkpIHRpcFBhcnRzLnNoaWZ0KCk7CiAgICAgIHdoaWxlICh0aXBQYXJ0cy5s
;ZW5ndGggJiYgIVN0cmluZyh0aXBQYXJ0c1t0aXBQYXJ0cy5sZW5ndGggLSAxXSkudHJpbSgpKSB0aXBQYXJ0cy5wb3AoKTsKICAgICAgZG9jLnRpcCA9IHRp
;cFBhcnRzLmpvaW4oJ1xuJyk7CiAgICB9CiAgICBmb3IgKDsgaSA8IGxpbmVzLmxlbmd0aDsgaSsrKSB7CiAgICAgIGNvbnN0IHQgPSBTdHJpbmcobGluZXNb
;aV0gfHwgJycpLnRyaW0oKTsKICAgICAgaWYgKCF0KSB7IHBlbmRpbmdDb21tZW50ID0gJyc7IGNvbnRpbnVlOyB9CiAgICAgIGlmIChpc0NvbmZpZ1NlcExp
;bmUodCkpIHsgcGVuZGluZ0NvbW1lbnQgPSAnJzsgY29udGludWU7IH0KICAgICAgaWYgKGlzQ29uZmlnR3JvdXBMaW5lKHQpKSB7CiAgICAgICAgZ3JvdXBz
;LnB1c2goeyB0aXRsZTogcGFyc2VDb25maWdHcm91cFRpdGxlKHQpIHx8ICfmnKrlkb3lkI3nu4QnLCBpdGVtczogW10gfSk7CiAgICAgICAgZ2kgPSBncm91
;cHMubGVuZ3RoIC0gMTsKICAgICAgICBwZW5kaW5nQ29tbWVudCA9ICcnOwogICAgICAgIGNvbnRpbnVlOwogICAgICB9CiAgICAgIGNvbnN0IGRpc2FibGVk
;S3YgPSBwYXJzZURpc2FibGVkS3YodCk7CiAgICAgIGlmIChkaXNhYmxlZEt2KSB7CiAgICAgICAgZGlzYWJsZWRLdi5jb21tZW50ID0gcGVuZGluZ0NvbW1l
;bnQ7CiAgICAgICAgZ3JvdXBzW2dpXS5pdGVtcy5wdXNoKGRpc2FibGVkS3YpOwogICAgICAgIHBlbmRpbmdDb21tZW50ID0gJyc7CiAgICAgICAgY29udGlu
;dWU7CiAgICAgIH0KICAgICAgaWYgKHQuY2hhckF0KDApID09PSAnIycpIHsKICAgICAgICBpZiAoL14jezIsfS8udGVzdCh0KSkgeyBwZW5kaW5nQ29tbWVu
;dCA9ICcnOyBjb250aW51ZTsgfQogICAgICAgIHBlbmRpbmdDb21tZW50ID0gdC5yZXBsYWNlKC9eI1xzKi8sICcnKS50cmltKCk7CiAgICAgICAgY29udGlu
;dWU7CiAgICAgIH0KICAgICAgY29uc3Qga3YgPSBwYXJzZUt2KHQpOwogICAgICBpZiAoIWt2KSB7IHBlbmRpbmdDb21tZW50ID0gJyc7IGNvbnRpbnVlOyB9
;CiAgICAgIGt2LmNvbW1lbnQgPSBwZW5kaW5nQ29tbWVudDsKICAgICAgZ3JvdXBzW2dpXS5pdGVtcy5wdXNoKGt2KTsKICAgICAgcGVuZGluZ0NvbW1lbnQg
;PSAnJzsKICAgIH0KICAgIGlmIChncm91cHMubGVuZ3RoID4gMSAmJiBncm91cHNbMF0udGl0bGUgPT09ICfpu5jorqQnICYmICFncm91cHNbMF0uaXRlbXMu
;bGVuZ3RoKSBncm91cHMuc2hpZnQoKTsKICAgIGdyb3Vwcy5mb3JFYWNoKGcgPT4gKGcuaXRlbXMgfHwgW10pLmZvckVhY2gobm9ybWFsaXplSXRlbSkpOwog
;ICAgZG9jLmdyb3VwcyA9IGdyb3VwczsKICAgIHJldHVybiBkb2M7CiAgfQogIGZ1bmN0aW9uIHNlcmlhbGl6ZUFoa0NvbmZpZyhkb2MpIHsKICAgIGNvbnN0
;IG91dCA9IFtdOwogICAgY29uc3QgdGlwU2VwID0gTWF0aC5tYXgoOCwgTnVtYmVyKGRvYyAmJiBkb2MudGlwU2VwKSB8fCBDRkdfVElQX1NFUF9ERUZBVUxU
;KTsKICAgIGNvbnN0IHRpcEhhc2ggPSBNYXRoLm1heCgxLCBOdW1iZXIoZG9jICYmIGRvYy50aXBIYXNoKSB8fCBDRkdfVElQX0hBU0hfREVGQVVMVCk7CiAg
;ICBjb25zdCBzZXAgPSAnIycucmVwZWF0KHRpcFNlcCk7CiAgICBjb25zdCBwcmVmaXggPSAnIycucmVwZWF0KHRpcEhhc2gpOwogICAgY29uc3QgdGlwVGV4
;dCA9IFN0cmluZyhkb2MgJiYgZG9jLnRpcCAhPSBudWxsID8gZG9jLnRpcCA6ICcnKTsKICAgIGNvbnN0IHRpcExpbmVzID0gdGlwVGV4dC5yZXBsYWNlKC9c
;clxuL2csICdcbicpLnJlcGxhY2UoL1xyL2csICdcbicpLnNwbGl0KCdcbicpOwogICAgb3V0LnB1c2goc2VwKTsKICAgIGlmICh0aXBMaW5lcy5sZW5ndGgg
;PT09IDEgJiYgIVN0cmluZyh0aXBMaW5lc1swXSkudHJpbSgpKSB7CiAgICAgIG91dC5wdXNoKHByZWZpeCArICfphY3nva7lj4LmlbDkuLprZXk9dmFsdWXl
;vaLlvI8nKTsKICAgIH0gZWxzZSB7CiAgICAgIHRpcExpbmVzLmZvckVhY2gobGluZSA9PiB7CiAgICAgICAgb3V0LnB1c2gocHJlZml4ICsgU3RyaW5nKGxp
;bmUgPz8gJycpKTsKICAgICAgfSk7CiAgICB9CiAgICBvdXQucHVzaChzZXApOwogICAgb3V0LnB1c2goJycpOwogICAgY29uc3QgZ3JvdXBzID0gKGRvYyAm
;JiBkb2MuZ3JvdXBzKSB8fCBbXTsKICAgIGdyb3Vwcy5mb3JFYWNoKChnLCBpZHgpID0+IHsKICAgICAgY29uc3QgdGl0bGUgPSBTdHJpbmcoZy50aXRsZSB8
;fCAnJykudHJpbSgpIHx8ICfmnKrlkb3lkI3nu4QnOwogICAgICBjb25zdCBpdGVtcyA9IEFycmF5LmlzQXJyYXkoZy5pdGVtcykgPyBnLml0ZW1zIDogW107
;CiAgICAgIGlmICghKGlkeCA9PT0gMCAmJiB0aXRsZSA9PT0gJ+m7mOiupCcpKSB7CiAgICAgICAgb3V0LnB1c2goJycpOwogICAgICAgIG91dC5wdXNoKCcj
;IyMjIyMjIyMjIyPjgJAnICsgdGl0bGUgKyAn44CRJyk7CiAgICAgIH0KICAgICAgaXRlbXMuZm9yRWFjaChpdCA9PiB7CiAgICAgICAgbm9ybWFsaXplSXRl
;bShpdCk7CiAgICAgICAgY29uc3Qga2V5ID0gU3RyaW5nKGl0LmtleSB8fCAnJykudHJpbSgpOwogICAgICAgIGlmICgha2V5KSByZXR1cm47CiAgICAgICAg
;Y29uc3QgdmFsID0gU3RyaW5nKGl0LnZhbHVlID8/ICcnKTsKICAgICAgICBjb25zdCBjb21tZW50ID0gU3RyaW5nKGl0LmNvbW1lbnQgfHwgJycpLnRyaW0o
;KTsKICAgICAgICBpZiAoY29tbWVudCkgb3V0LnB1c2goJyMnICsgY29tbWVudCk7CiAgICAgICAgaWYgKGl0LmVuYWJsZWQgPT09IGZhbHNlKSBvdXQucHVz
;aCgnIycgKyBrZXkgKyAnPScgKyB2YWwgKyAnICAgI+W8g+eUqCcpOwogICAgICAgIGVsc2Ugb3V0LnB1c2goa2V5ICsgJz0nICsgdmFsKTsKICAgICAgfSk7
;CiAgICB9KTsKICAgIG91dC5wdXNoKCcnKTsKICAgIHJldHVybiBvdXQuam9pbignXHJcbicpOwogIH0KICBmdW5jdGlvbiBjZmdEb2MoKSB7IHJldHVybiBj
;ZmdDYWNoZVtjZmdBY3RpdmVUYWJdOyB9CiAgZnVuY3Rpb24gY2ZnQ3VycmVudCgpIHsKICAgIGNvbnN0IGQgPSBjZmdEb2MoKTsKICAgIHJldHVybiBkICYm
;IGQuZ3JvdXBzOwogIH0KICBsZXQgY2ZnQXV0b1NhdmVUaW1lciA9IDA7CiAgbGV0IGNmZ0F1dG9TYXZpbmcgPSBmYWxzZTsKICBmdW5jdGlvbiBpc1N5c0Nv
;bmZpZ1RhYihuYW1lKSB7CiAgICByZXR1cm4gU3RyaW5nKG5hbWUgfHwgY2ZnQWN0aXZlVGFiIHx8ICcnKSA9PT0gJ3N5c2NvbmZpZyc7CiAgfQogIGZ1bmN0
;aW9uIHN5bmNDZmdTYXZlQnRuKCkgewogICAgY29uc3QgYnRuID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2NmZy1zYXZlJyk7CiAgICBpZiAoIWJ0bikg
;cmV0dXJuOwogICAgY29uc3Qgc2hvdyA9IGlzU3lzQ29uZmlnVGFiKCk7CiAgICBidG4uY2xhc3NMaXN0LnRvZ2dsZSgnb24nLCBzaG93KTsKICAgIGlmIChz
;aG93KSBidG4uZGlzYWJsZWQgPSAhY2ZnRGlydHkuc3lzY29uZmlnOwogIH0KICBmdW5jdGlvbiBtYXJrQ2ZnRGlydHkoKSB7CiAgICBjZmdEaXJ0eVtjZmdB
;Y3RpdmVUYWJdID0gdHJ1ZTsKICAgIHN5bmNDZmdTYXZlQnRuKCk7CiAgICBpZiAoIWlzU3lzQ29uZmlnVGFiKCkpIHNjaGVkdWxlQ2ZnQXV0b1NhdmUoKTsK
;ICB9CiAgZnVuY3Rpb24gc2NoZWR1bGVDZmdBdXRvU2F2ZShkZWxheSkgewogICAgaWYgKGFwcE1vZGUgIT09ICdjb25maWcnIHx8IGlzU3lzQ29uZmlnVGFi
;KCkpIHJldHVybjsKICAgIGNsZWFyVGltZW91dChjZmdBdXRvU2F2ZVRpbWVyKTsKICAgIGNmZ0F1dG9TYXZlVGltZXIgPSBzZXRUaW1lb3V0KCgpID0+IHsK
;ICAgICAgY2ZnQXV0b1NhdmVUaW1lciA9IDA7CiAgICAgIGlmIChpc1N5c0NvbmZpZ1RhYigpKSByZXR1cm47CiAgICAgIHNhdmVBaGtDb25maWdUYWIodHJ1
;ZSk7CiAgICB9LCBkZWxheSA9PSBudWxsID8gNjUwIDogZGVsYXkpOwogIH0KICBmdW5jdGlvbiBmbHVzaENmZ0F1dG9TYXZlKCkgewogICAgaWYgKGlzU3lz
;Q29uZmlnVGFiKCkpIHJldHVybjsKICAgIGlmICghY2ZnRGlydHlbY2ZnQWN0aXZlVGFiXSkgcmV0dXJuOwogICAgY2xlYXJUaW1lb3V0KGNmZ0F1dG9TYXZl
;VGltZXIpOwogICAgY2ZnQXV0b1NhdmVUaW1lciA9IDA7CiAgICBzYXZlQWhrQ29uZmlnVGFiKHRydWUpOwogIH0KICBmdW5jdGlvbiBzeW5jQ2ZnU2VhcmNo
;Q2hyb21lKCkgewogICAgZG9jdW1lbnQucXVlcnlTZWxlY3RvckFsbCgnLmNmZy1zdGFnW2RhdGEtY2ZnLXNjb3BlXScpLmZvckVhY2goYnRuID0+IHsKICAg
;ICAgY29uc3QgcyA9IGJ0bi5nZXRBdHRyaWJ1dGUoJ2RhdGEtY2ZnLXNjb3BlJyk7CiAgICAgIGJ0bi5jbGFzc0xpc3QudG9nZ2xlKCdvbicsICEhY2ZnU2Vh
;cmNoU2NvcGVbc10pOwogICAgfSk7CiAgICBpZiAoY2ZnU2VhcmNoQ2xlYXJFbCkgewogICAgICBjb25zdCBzaG93ID0gYXBwTW9kZSA9PT0gJ2NvbmZpZycg
;JiYgISEoCiAgICAgICAgY2ZnU2VhcmNoIHx8IGNmZ1NlYXJjaFNjb3BlLmtleSB8fCBjZmdTZWFyY2hTY29wZS52YWx1ZQogICAgICAgIHx8IGNmZ1NlYXJj
;aFNjb3BlLmVuYWJsZWQgfHwgY2ZnU2VhcmNoU2NvcGUuZGlzYWJsZWQKICAgICAgICB8fCBTdHJpbmcocUVsICYmIHFFbC52YWx1ZSB8fCAnJykudHJpbSgp
;CiAgICAgICk7CiAgICAgIGNmZ1NlYXJjaENsZWFyRWwuY2xhc3NMaXN0LnRvZ2dsZSgnb24nLCBzaG93KTsKICAgICAgaWYgKCFjZmdTZWFyY2ggJiYgY2Zn
;U2VhcmNoSGl0RWwpIGNmZ1NlYXJjaEhpdEVsLnRleHRDb250ZW50ID0gJyc7CiAgICB9CiAgfQogIGZ1bmN0aW9uIHVwZGF0ZUNmZ1NlYXJjaEhpdChuKSB7
;CiAgICBpZiAoIWNmZ1NlYXJjaEhpdEVsKSByZXR1cm47CiAgICBjb25zdCBmaWx0ZXJpbmcgPSBjZmdIYXNBY3RpdmVGaWx0ZXIoKTsKICAgIGlmIChhcHBN
;b2RlICE9PSAnY29uZmlnJyB8fCAhZmlsdGVyaW5nKSB7CiAgICAgIGNmZ1NlYXJjaEhpdEVsLnRleHRDb250ZW50ID0gJyc7CiAgICAgIHN5bmNDZmdTZWFy
;Y2hDaHJvbWUoKTsKICAgICAgcmV0dXJuOwogICAgfQogICAgY2ZnU2VhcmNoSGl0RWwudGV4dENvbnRlbnQgPSBTdHJpbmcobikgKyAnIOadoSc7CiAgICBz
;eW5jQ2ZnU2VhcmNoQ2hyb21lKCk7CiAgfQogIGZ1bmN0aW9uIGNsZWFyQ2ZnU2VhcmNoKCkgewogICAgY2ZnU2VhcmNoU2NvcGUgPSB7IGtleTogZmFsc2Us
;IHZhbHVlOiBmYWxzZSwgZW5hYmxlZDogZmFsc2UsIGRpc2FibGVkOiBmYWxzZSB9OwogICAgbW9kZVF1ZXJ5LmNvbmZpZyA9ICcnOwogICAgaWYgKHFFbCkg
;cUVsLnZhbHVlID0gJyc7CiAgICBhcHBseUNvbmZpZ1NlYXJjaCgnJyk7CiAgICBpZiAodHlwZW9mIHN5bmNDbGVhckJ0biA9PT0gJ2Z1bmN0aW9uJykgc3lu
;Y0NsZWFyQnRuKCk7CiAgICBpZiAodHlwZW9mIHNhdmVTZXNzaW9uU29vbiA9PT0gJ2Z1bmN0aW9uJykgc2F2ZVNlc3Npb25Tb29uKCk7CiAgfQogIGZ1bmN0
;aW9uIGFwcGx5Q29uZmlnU2VhcmNoKHEpIHsKICAgIGNvbnN0IHJhdyA9IHEgPT0gbnVsbCA/IFN0cmluZyhxRWwgJiYgcUVsLnZhbHVlIHx8ICcnKSA6IFN0
;cmluZyhxIHx8ICcnKTsKICAgIGNmZ1NlYXJjaCA9IHJhdy50cmltKCkudG9Mb3dlckNhc2UoKTsKICAgIG1vZGVRdWVyeS5jb25maWcgPSByYXc7CiAgICBp
;ZiAocUVsICYmIHFFbC52YWx1ZSAhPT0gcmF3KSBxRWwudmFsdWUgPSByYXc7CiAgICBzeW5jQ2ZnU2VhcmNoQ2hyb21lKCk7CiAgICBpZiAodHlwZW9mIHN5
;bmNDbGVhckJ0biA9PT0gJ2Z1bmN0aW9uJykgc3luY0NsZWFyQnRuKCk7CiAgICByZW5kZXJDb25maWdFZGl0b3IoKTsKICB9CiAgZnVuY3Rpb24gbW92ZUlu
;QXJyYXkoYXJyLCBpLCBkaXIpIHsKICAgIGNvbnN0IGogPSBpICsgZGlyOwogICAgaWYgKCFhcnIgfHwgaiA8IDAgfHwgaiA+PSBhcnIubGVuZ3RoKSByZXR1
;cm4gZmFsc2U7CiAgICBjb25zdCB0ID0gYXJyW2ldOyBhcnJbaV0gPSBhcnJbal07IGFycltqXSA9IHQ7CiAgICByZXR1cm4gdHJ1ZTsKICB9CiAgZnVuY3Rp
;b24gbW92ZVRvVG9wKGFyciwgaSkgewogICAgaWYgKCFhcnIgfHwgaSA8PSAwIHx8IGkgPj0gYXJyLmxlbmd0aCkgcmV0dXJuIGZhbHNlOwogICAgY29uc3Qg
;dCA9IGFyci5zcGxpY2UoaSwgMSlbMF07CiAgICBhcnIudW5zaGlmdCh0KTsKICAgIHJldHVybiB0cnVlOwogIH0KICBmdW5jdGlvbiBjbGFzc2lmeUNmZ1Zh
;bHVlKHZhbCkgewogICAgY29uc3QgdiA9IFN0cmluZyh2YWwgfHwgJycpLnRyaW0oKTsKICAgIGlmICghdikgcmV0dXJuIHsga2luZDogJycsIHBhdGg6ICcn
;IH07CiAgICBpZiAoL15cKC4qXCkkLy50ZXN0KHYpKSByZXR1cm4geyBraW5kOiAnY21kJywgcGF0aDogJycgfTsKICAgIGlmICgvXmh0dHBzPzpcL1wvL2ku
;dGVzdCh2KSB8fCAvXnd3d1wuL2kudGVzdCh2KSkgcmV0dXJuIHsga2luZDogJ3dlYicsIHBhdGg6IHYgfTsKICAgIGNvbnN0IGJhcmUgPSB2LnJlcGxhY2Uo
;L14iK3wiKyQvZywgJycpOwogICAgaWYgKC9eW2EtekEtWl06W1xcXC9dLy50ZXN0KGJhcmUpIHx8IGJhcmUuc3RhcnRzV2l0aCgnXFxcXCcpIHx8IC8lW14l
;XSslLy50ZXN0KGJhcmUpIHx8IGJhcmUuaW5kZXhPZignXFwnKSA+PSAwKSB7CiAgICAgIGNvbnN0IGxhc3QgPSBiYXJlLnNwbGl0KC9bXFxcL10vKS5wb3Ao
;KSB8fCAnJzsKICAgICAgaWYgKC9cLihleGV8bG5rKSQvaS50ZXN0KGxhc3QpKSByZXR1cm4geyBraW5kOiAnZXhlJywgcGF0aDogYmFyZSB9OwogICAgICBp
;ZiAoL1tcXFwvXSQvLnRlc3QoYmFyZSkgfHwgIS9cLlthLXowLTldezEsNn0kL2kudGVzdChsYXN0KSkgcmV0dXJuIHsga2luZDogJ2ZvbGRlcicsIHBhdGg6
;IGJhcmUgfTsKICAgICAgcmV0dXJuIHsga2luZDogJ2ZpbGUnLCBwYXRoOiBiYXJlIH07CiAgICB9CiAgICByZXR1cm4geyBraW5kOiAnJywgcGF0aDogJycg
;fTsKICB9CiAgZnVuY3Rpb24gc2V0Q2ZnVmljbyhlbCwga2luZCwgdXJsKSB7CiAgICBpZiAoIWVsKSByZXR1cm47CiAgICBpZiAodXJsKSB7CiAgICAgIGVs
;LmlubmVySFRNTCA9ICcnOwogICAgICBjb25zdCBpbWcgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdpbWcnKTsKICAgICAgaW1nLmFsdCA9ICcnOwogICAg
;ICBpbWcuc3JjID0gdXJsOwogICAgICBpbWcub25lcnJvciA9ICgpID0+IHsgZWwuaW5uZXJIVE1MID0gQ0ZHX1NWR1traW5kXSB8fCBDRkdfU1ZHLmZpbGUg
;fHwgJyc7IH07CiAgICAgIGVsLmFwcGVuZENoaWxkKGltZyk7CiAgICAgIHJldHVybjsKICAgIH0KICAgIGVsLmlubmVySFRNTCA9IENGR19TVkdba2luZF0g
;fHwgJyc7CiAgfQogIGZ1bmN0aW9uIHJlcXVlc3RDZmdJY29uKGVsLCBraW5kLCBwYXRoKSB7CiAgICBpZiAoIWVsIHx8ICFraW5kKSByZXR1cm47CiAgICBp
;ZiAoa2luZCA9PT0gJ3dlYicgfHwga2luZCA9PT0gJ2ZpbGUnKSB7CiAgICAgIHNldENmZ1ZpY28oZWwsIGtpbmQsICcnKTsKICAgICAgcmV0dXJuOwogICAg
;fQogICAgY29uc3QgY2FjaGVLZXkgPSBraW5kICsgJ3wnICsgU3RyaW5nKHBhdGggfHwgJycpOwogICAgaWYgKGNmZ0ljb25DYWNoZS5oYXMoY2FjaGVLZXkp
;KSB7CiAgICAgIGNvbnN0IHUgPSBjZmdJY29uQ2FjaGUuZ2V0KGNhY2hlS2V5KTsKICAgICAgc2V0Q2ZnVmljbyhlbCwga2luZCwgdSB8fCAnJyk7CiAgICAg
;IHJldHVybjsKICAgIH0KICAgIHNldENmZ1ZpY28oZWwsIGtpbmQgPT09ICdleGUnID8gJ2ZpbGUnIDoga2luZCwgJycpOwogICAgY29uc3QgcmVxSWQgPSAn
;YycgKyAoKytjZmdJY29uU2VxKTsKICAgIGVsLmRhdGFzZXQuaWNvblJlcSA9IHJlcUlkOwogICAgc2V0VGltZW91dCgoKSA9PiB7CiAgICAgIHRyeSB7IHBv
;c3QoJ2NmZ0ljb258JyArIHJlcUlkICsgJ3wnICsga2luZCArICd8JyArIHRleHRUb0I2NChwYXRoIHx8ICcnKSk7IH0gY2F0Y2ggKF8pIHt9CiAgICB9LCAw
;KTsKICB9CiAgZnVuY3Rpb24gaGlkZUNmZ01lbnUoKSB7CiAgICBpZiAoY2ZnTWVudSkgY2ZnTWVudS5jbGFzc0xpc3QucmVtb3ZlKCdvbicpOwogICAgY2Zn
;TWVudUN0eCA9IG51bGw7CiAgfQogIGZ1bmN0aW9uIHNob3dDZmdNZW51KHgsIHksIGN0eCkgewogICAgaWYgKCFjZmdNZW51KSByZXR1cm47CiAgICBjZmdN
;ZW51Q3R4ID0gY3R4OwogICAgY29uc3QgaXNHcm91cCA9IGN0eCAmJiBjdHgudHlwZSA9PT0gJ2dyb3VwJzsKICAgIGNmZ01lbnUucXVlcnlTZWxlY3RvckFs
;bCgnYnV0dG9uW2RhdGEtY2FjdF0nKS5mb3JFYWNoKGJ0biA9PiB7CiAgICAgIGNvbnN0IGEgPSBidG4uZ2V0QXR0cmlidXRlKCdkYXRhLWNhY3QnKTsKICAg
;ICAgY29uc3QgbGFiID0gYnRuLnF1ZXJ5U2VsZWN0b3IoJy5jYWN0LWxhYmVsJykgfHwgYnRuOwogICAgICBpZiAoYSA9PT0gJ2FkZCcpIGxhYi50ZXh0Q29u
;dGVudCA9ICfmt7vliqDmnaHnm64nOwogICAgICBlbHNlIGlmIChhID09PSAndG9wJykgbGFiLnRleHRDb250ZW50ID0gaXNHcm91cCA/ICfnu4Tnva7pobYn
;IDogJ+e9rumhtic7CiAgICAgIGVsc2UgaWYgKGEgPT09ICd1cCcpIGxhYi50ZXh0Q29udGVudCA9IGlzR3JvdXAgPyAn57uE5LiK56e7JyA6ICfkuIrnp7sn
;OwogICAgICBlbHNlIGlmIChhID09PSAnZG93bicpIGxhYi50ZXh0Q29udGVudCA9IGlzR3JvdXAgPyAn57uE5LiL56e7JyA6ICfkuIvnp7snOwogICAgICBl
;bHNlIGlmIChhID09PSAnZGVsJykgbGFiLnRleHRDb250ZW50ID0gaXNHcm91cCA/ICfliKDpmaTnu4QnIDogJ+WIoOmZpOadoeebric7CiAgICB9KTsKICAg
;IGNmZ01lbnUuY2xhc3NMaXN0LmFkZCgnb24nKTsKICAgIGNvbnN0IHBhZCA9IDY7CiAgICBjb25zdCByZWN0ID0gY2ZnTWVudS5nZXRCb3VuZGluZ0NsaWVu
;dFJlY3QoKTsKICAgIGxldCBsZWZ0ID0geCwgdG9wID0geTsKICAgIGlmIChsZWZ0ICsgcmVjdC53aWR0aCA+IHdpbmRvdy5pbm5lcldpZHRoIC0gcGFkKSBs
;ZWZ0ID0gTWF0aC5tYXgocGFkLCB3aW5kb3cuaW5uZXJXaWR0aCAtIHJlY3Qud2lkdGggLSBwYWQpOwogICAgaWYgKHRvcCArIHJlY3QuaGVpZ2h0ID4gd2lu
;ZG93LmlubmVySGVpZ2h0IC0gcGFkKSB0b3AgPSBNYXRoLm1heChwYWQsIHdpbmRvdy5pbm5lckhlaWdodCAtIHJlY3QuaGVpZ2h0IC0gcGFkKTsKICAgIGNm
;Z01lbnUuc3R5bGUubGVmdCA9IGxlZnQgKyAncHgnOwogICAgY2ZnTWVudS5zdHlsZS50b3AgPSB0b3AgKyAncHgnOwogIH0KICBmdW5jdGlvbiBpc0VtcHR5
;Q2ZnSXRlbShpdCkgewogICAgcmV0dXJuICFTdHJpbmcoKGl0ICYmIGl0LmtleSkgfHwgJycpLnRyaW0oKSAmJiAhU3RyaW5nKChpdCAmJiBpdC52YWx1ZSkg
;fHwgJycpLnRyaW0oKTsKICB9CiAgZnVuY3Rpb24gcmVhZENmZ0FkZERyYWZ0VmFsdWVzKGdpKSB7CiAgICBjb25zdCByb3cgPSBjZmdCb2R5ICYmIGNmZ0Jv
;ZHkucXVlcnlTZWxlY3RvcignLmNmZy1hZGQtZHJhZnRbZGF0YS1naT0iJyArIGdpICsgJyJdJyk7CiAgICBpZiAoIXJvdykgcmV0dXJuIHsga2V5OiAnJywg
;dmFsdWU6ICcnLCBjb21tZW50OiAnJywgZW1wdHk6IHRydWUgfTsKICAgIGNvbnN0IGtleSA9IFN0cmluZygocm93LnF1ZXJ5U2VsZWN0b3IoJ2lucHV0LmNm
;Zy1rZXknKSB8fCB7fSkudmFsdWUgfHwgJycpOwogICAgY29uc3QgdmFsdWUgPSBTdHJpbmcoKHJvdy5xdWVyeVNlbGVjdG9yKCdpbnB1dC5jZmctdmFsJykg
;fHwge30pLnZhbHVlIHx8ICcnKTsKICAgIGNvbnN0IGNvbW1lbnQgPSBTdHJpbmcoKHJvdy5xdWVyeVNlbGVjdG9yKCdpbnB1dC5jZmctY210JykgfHwge30p
;LnZhbHVlIHx8ICcnKTsKICAgIHJldHVybiB7CiAgICAgIGtleSwgdmFsdWUsIGNvbW1lbnQsCiAgICAgIGVtcHR5OiAha2V5LnRyaW0oKSAmJiAhdmFsdWUu
;dHJpbSgpICYmICFjb21tZW50LnRyaW0oKQogICAgfTsKICB9CiAgLy8g56a75byA56m66KGMIC8g56m65paw5aKe5qGG5pe255u05o6l5Lii5byD77yM5LiN
;5by556Gu6K6kCiAgZnVuY3Rpb24gZmx1c2hFbXB0eUNmZ09uTGVhdmUobmV4dEdpLCBuZXh0SWkpIHsKICAgIGxldCBjaGFuZ2VkID0gZmFsc2U7CiAgICBj
;b25zdCBwcmV2R2kgPSBjZmdTZWwuZ2k7CiAgICBjb25zdCBwcmV2SWkgPSBjZmdTZWwuaWk7CiAgICBpZiAoY2ZnQWRkRHJhZnRHaSA+PSAwKSB7CiAgICAg
;IGNvbnN0IGRyYWZ0R2kgPSBjZmdBZGREcmFmdEdpOwogICAgICBjb25zdCBkID0gcmVhZENmZ0FkZERyYWZ0VmFsdWVzKGRyYWZ0R2kpOwogICAgICBjb25z
;dCBsZWF2aW5nRHJhZnQgPSBuZXh0R2kgIT09IGRyYWZ0R2kgfHwgbmV4dElpID49IDA7CiAgICAgIGlmIChsZWF2aW5nRHJhZnQpIHsKICAgICAgICBpZiAo
;ZC5lbXB0eSkgewogICAgICAgICAgY2ZnQWRkRHJhZnRHaSA9IC0xOwogICAgICAgICAgY2hhbmdlZCA9IHRydWU7CiAgICAgICAgfSBlbHNlIHsKICAgICAg
;ICAgIGNvbW1pdENmZ0FkZERyYWZ0KGRyYWZ0R2ksIGQpOwogICAgICAgICAgcmV0dXJuIHsgY2hhbmdlZDogZmFsc2UsIG5leHRHaSwgbmV4dElpLCBjb21t
;aXR0ZWQ6IHRydWUgfTsKICAgICAgICB9CiAgICAgIH0KICAgIH0KICAgIGlmIChwcmV2SWkgPj0gMCAmJiAocHJldkdpICE9PSBuZXh0R2kgfHwgcHJldklp
;ICE9PSBuZXh0SWkpKSB7CiAgICAgIGNvbnN0IGdyb3VwcyA9IGNmZ0N1cnJlbnQoKTsKICAgICAgY29uc3QgaXQgPSBncm91cHMgJiYgZ3JvdXBzW3ByZXZH
;aV0gJiYgZ3JvdXBzW3ByZXZHaV0uaXRlbXMgJiYgZ3JvdXBzW3ByZXZHaV0uaXRlbXNbcHJldklpXTsKICAgICAgaWYgKGl0ICYmIGlzRW1wdHlDZmdJdGVt
;KGl0KSkgewogICAgICAgIGdyb3Vwc1twcmV2R2ldLml0ZW1zLnNwbGljZShwcmV2SWksIDEpOwogICAgICAgIG1hcmtDZmdEaXJ0eSgpOwogICAgICAgIGNo
;YW5nZWQgPSB0cnVlOwogICAgICAgIGlmIChwcmV2R2kgPT09IG5leHRHaSAmJiBuZXh0SWkgPiBwcmV2SWkpIG5leHRJaSAtPSAxOwogICAgICB9CiAgICB9
;CiAgICByZXR1cm4geyBjaGFuZ2VkLCBuZXh0R2ksIG5leHRJaSwgY29tbWl0dGVkOiBmYWxzZSB9OwogIH0KICBmdW5jdGlvbiBhcHBseUNmZ1NlbGVjdGlv
;bkhpZ2hsaWdodChnaSwgaWkpIHsKICAgIGlmICghY2ZnQm9keSkgcmV0dXJuOwogICAgY2ZnQm9keS5xdWVyeVNlbGVjdG9yQWxsKCcuY2ZnLWNhcmQub24n
;KS5mb3JFYWNoKGVsID0+IGVsLmNsYXNzTGlzdC5yZW1vdmUoJ29uJykpOwogICAgY2ZnQm9keS5xdWVyeVNlbGVjdG9yQWxsKCcuY2ZnLWl0ZW0ub24nKS5m
;b3JFYWNoKGVsID0+IGVsLmNsYXNzTGlzdC5yZW1vdmUoJ29uJykpOwogICAgY29uc3QgY2FyZCA9IGNmZ0JvZHkucXVlcnlTZWxlY3RvcignLmNmZy1jYXJk
;W2RhdGEtZ2k9IicgKyBnaSArICciXScpOwogICAgaWYgKGNhcmQpIGNhcmQuY2xhc3NMaXN0LmFkZCgnb24nKTsKICAgIGlmIChpaSA+PSAwKSB7CiAgICAg
;IGNvbnN0IGl0ZW0gPSBjZmdCb2R5LnF1ZXJ5U2VsZWN0b3IoJy5jZmctaXRlbVtkYXRhLWdpPSInICsgZ2kgKyAnIl1bZGF0YS1paT0iJyArIGlpICsgJyJd
;Jyk7CiAgICAgIGlmIChpdGVtKSBpdGVtLmNsYXNzTGlzdC5hZGQoJ29uJyk7CiAgICAgIGNvbnN0IGdyb3VwcyA9IGNmZ0N1cnJlbnQoKTsKICAgICAgY29u
;c3QgaXQgPSBncm91cHMgJiYgZ3JvdXBzW2dpXSAmJiBncm91cHNbZ2ldLml0ZW1zICYmIGdyb3Vwc1tnaV0uaXRlbXNbaWldOwogICAgICBpZiAoaXQpIHsK
;ICAgICAgICBjb25zdCBjbHMgPSBjbGFzc2lmeUNmZ1ZhbHVlKGl0LnZhbHVlKTsKICAgICAgICB1cGRhdGVDZmdQYXRoQmFyKGNscy5wYXRoIHx8IFN0cmlu
;ZyhpdC52YWx1ZSB8fCAnJykudHJpbSgpIHx8IGNmZ1BhdGhzW2NmZ0FjdGl2ZVRhYl0pOwogICAgICB9CiAgICB9IGVsc2UgewogICAgICB1cGRhdGVDZmdQ
;YXRoQmFyKGNmZ1BhdGhzW2NmZ0FjdGl2ZVRhYl0pOwogICAgfQogIH0KICBmdW5jdGlvbiBzZWxlY3RDZmdUYXJnZXQoZ2ksIGlpLCBvcHRzKSB7CiAgICBv
;cHRzID0gb3B0cyB8fCB7fTsKICAgIGlmICghb3B0cy5za2lwRmx1c2gpIHsKICAgICAgY29uc3QgciA9IGZsdXNoRW1wdHlDZmdPbkxlYXZlKGdpLCBpaSk7
;CiAgICAgIGlmIChyLmNvbW1pdHRlZCB8fCByLmNoYW5nZWQpIHsKICAgICAgICBjZmdTZWwgPSB7IGdpOiByLm5leHRHaSwgaWk6IHIubmV4dElpIH07CiAg
;ICAgICAgaWYgKHIuY2hhbmdlZCAmJiAhci5jb21taXR0ZWQpIHJlbmRlckNvbmZpZ0VkaXRvcigpOwogICAgICAgIGFwcGx5Q2ZnU2VsZWN0aW9uSGlnaGxp
;Z2h0KHIubmV4dEdpLCByLm5leHRJaSk7CiAgICAgICAgcmV0dXJuOwogICAgICB9CiAgICAgIGdpID0gci5uZXh0R2k7CiAgICAgIGlpID0gci5uZXh0SWk7
;CiAgICB9CiAgICBjZmdTZWwgPSB7IGdpLCBpaSB9OwogICAgYXBwbHlDZmdTZWxlY3Rpb25IaWdobGlnaHQoZ2ksIGlpKTsKICB9CiAgYXN5bmMgZnVuY3Rp
;b24gcnVuQ2ZnTWVudUFjdGlvbihhY3QpIHsKICAgIGNvbnN0IGN0eCA9IGNmZ01lbnVDdHg7CiAgICBoaWRlQ2ZnTWVudSgpOwogICAgaWYgKCFjdHggfHwg
;IWFjdCkgcmV0dXJuOwogICAgY29uc3QgZ3JvdXBzID0gY2ZnQ3VycmVudCgpOwogICAgaWYgKCFncm91cHMpIHJldHVybjsKICAgIGNvbnN0IGdpID0gY3R4
;LmdpOwogICAgaWYgKGdpIDwgMCB8fCBnaSA+PSBncm91cHMubGVuZ3RoKSByZXR1cm47CiAgICBjb25zdCBnID0gZ3JvdXBzW2dpXTsKICAgIGlmIChjdHgu
;dHlwZSA9PT0gJ2dyb3VwJykgewogICAgICBpZiAoYWN0ID09PSAnYWRkJykgewogICAgICAgIGJlZ2luQ2ZnQWRkRHJhZnQoZ2kpOwogICAgICAgIHJldHVy
;bjsKICAgICAgfQogICAgICBpZiAoYWN0ID09PSAndG9wJykgeyBpZiAobW92ZVRvVG9wKGdyb3VwcywgZ2kpKSB7IG1hcmtDZmdEaXJ0eSgpOyByZW5kZXJD
;b25maWdFZGl0b3IoKTsgc2VsZWN0Q2ZnVGFyZ2V0KDAsIC0xKTsgfSByZXR1cm47IH0KICAgICAgaWYgKGFjdCA9PT0gJ3VwJykgeyBpZiAobW92ZUluQXJy
;YXkoZ3JvdXBzLCBnaSwgLTEpKSB7IG1hcmtDZmdEaXJ0eSgpOyByZW5kZXJDb25maWdFZGl0b3IoKTsgc2VsZWN0Q2ZnVGFyZ2V0KGdpIC0gMSwgLTEpOyB9
;IHJldHVybjsgfQogICAgICBpZiAoYWN0ID09PSAnZG93bicpIHsgaWYgKG1vdmVJbkFycmF5KGdyb3VwcywgZ2ksIDEpKSB7IG1hcmtDZmdEaXJ0eSgpOyBy
;ZW5kZXJDb25maWdFZGl0b3IoKTsgc2VsZWN0Q2ZnVGFyZ2V0KGdpICsgMSwgLTEpOyB9IHJldHVybjsgfQogICAgICBpZiAoYWN0ID09PSAnZGVsJykgewog
;ICAgICAgIGNvbnN0IG9rID0gYXdhaXQgdWlDb25maXJtKCfliKDpmaTnu4TjgIwnICsgKGcudGl0bGUgfHwgJycpICsgJ+OAjeWPiuWFtuWFqOmDqOadoeeb
;ru+8nycsIHsKICAgICAgICAgIHRpdGxlOiAn5Yig6Zmk5YiG57uEJywgb2tUZXh0OiAn5Yig6ZmkJywgZGFuZ2VyOiB0cnVlCiAgICAgICAgfSk7CiAgICAg
;ICAgaWYgKCFvaykgcmV0dXJuOwogICAgICAgIGdyb3Vwcy5zcGxpY2UoZ2ksIDEpOwogICAgICAgIG1hcmtDZmdEaXJ0eSgpOwogICAgICAgIHJlbmRlckNv
;bmZpZ0VkaXRvcigpOwogICAgICAgIHJldHVybjsKICAgICAgfQogICAgICByZXR1cm47CiAgICB9CiAgICBjb25zdCBpaSA9IGN0eC5paTsKICAgIGlmIChp
;aSA8IDAgfHwgIWcuaXRlbXMgfHwgaWkgPj0gZy5pdGVtcy5sZW5ndGgpIHJldHVybjsKICAgIGlmIChhY3QgPT09ICdhZGQnKSB7CiAgICAgIGJlZ2luQ2Zn
;QWRkRHJhZnQoZ2kpOwogICAgICByZXR1cm47CiAgICB9CiAgICBpZiAoYWN0ID09PSAndG9wJykgeyBpZiAobW92ZVRvVG9wKGcuaXRlbXMsIGlpKSkgeyBt
;YXJrQ2ZnRGlydHkoKTsgcmVuZGVyQ29uZmlnRWRpdG9yKCk7IHNlbGVjdENmZ1RhcmdldChnaSwgMCk7IH0gcmV0dXJuOyB9CiAgICBpZiAoYWN0ID09PSAn
;dXAnKSB7IGlmIChtb3ZlSW5BcnJheShnLml0ZW1zLCBpaSwgLTEpKSB7IG1hcmtDZmdEaXJ0eSgpOyByZW5kZXJDb25maWdFZGl0b3IoKTsgc2VsZWN0Q2Zn
;VGFyZ2V0KGdpLCBpaSAtIDEpOyB9IHJldHVybjsgfQogICAgaWYgKGFjdCA9PT0gJ2Rvd24nKSB7IGlmIChtb3ZlSW5BcnJheShnLml0ZW1zLCBpaSwgMSkp
;IHsgbWFya0NmZ0RpcnR5KCk7IHJlbmRlckNvbmZpZ0VkaXRvcigpOyBzZWxlY3RDZmdUYXJnZXQoZ2ksIGlpICsgMSk7IH0gcmV0dXJuOyB9CiAgICBpZiAo
;YWN0ID09PSAnZGVsJykgewogICAgICBjb25zdCBpdCA9IGcuaXRlbXNbaWldOwogICAgICBjb25zdCBlbXB0eSA9ICFTdHJpbmcoKGl0ICYmIGl0LmtleSkg
;fHwgJycpLnRyaW0oKSAmJiAhU3RyaW5nKChpdCAmJiBpdC52YWx1ZSkgfHwgJycpLnRyaW0oKTsKICAgICAgaWYgKCFlbXB0eSkgewogICAgICAgIGNvbnN0
;IGxhYmVsID0gU3RyaW5nKChpdCAmJiBpdC5rZXkpIHx8ICcnKS50cmltKCkgfHwgKCfnrKwgJyArIChpaSArIDEpICsgJyDmnaEnKTsKICAgICAgICBjb25z
;dCBvayA9IGF3YWl0IHVpQ29uZmlybSgn56Gu5a6a5Yig6Zmk5p2h55uu44CMJyArIGxhYmVsICsgJ+OAje+8nycsIHsKICAgICAgICAgIHRpdGxlOiAn5Yig
;6Zmk5p2h55uuJywgb2tUZXh0OiAn5Yig6ZmkJywgZGFuZ2VyOiB0cnVlCiAgICAgICAgfSk7CiAgICAgICAgaWYgKCFvaykgcmV0dXJuOwogICAgICB9CiAg
;ICAgIGcuaXRlbXMuc3BsaWNlKGlpLCAxKTsKICAgICAgbWFya0NmZ0RpcnR5KCk7CiAgICAgIHJlbmRlckNvbmZpZ0VkaXRvcigpOwogICAgfQogIH0KICBm
;dW5jdGlvbiBwcnVuZUFsbEVtcHR5Q2ZnSXRlbXMoKSB7CiAgICBjb25zdCBncm91cHMgPSBjZmdDdXJyZW50KCk7CiAgICBpZiAoIWdyb3VwcykgcmV0dXJu
;OwogICAgbGV0IGNoYW5nZWQgPSBmYWxzZTsKICAgIGdyb3Vwcy5mb3JFYWNoKGcgPT4gewogICAgICBpZiAoIWcgfHwgIUFycmF5LmlzQXJyYXkoZy5pdGVt
;cykpIHJldHVybjsKICAgICAgY29uc3QgbmV4dCA9IGcuaXRlbXMuZmlsdGVyKGl0ID0+ICFpc0VtcHR5Q2ZnSXRlbShpdCkpOwogICAgICBpZiAobmV4dC5s
;ZW5ndGggIT09IGcuaXRlbXMubGVuZ3RoKSB7CiAgICAgICAgZy5pdGVtcyA9IG5leHQ7CiAgICAgICAgY2hhbmdlZCA9IHRydWU7CiAgICAgIH0KICAgIH0p
;OwogICAgaWYgKGNoYW5nZWQpIHsKICAgICAgaWYgKGNmZ1NlbC5paSA+PSAwKSBjZmdTZWwgPSB7IGdpOiBjZmdTZWwuZ2ksIGlpOiAtMSB9OwogICAgICBt
;YXJrQ2ZnRGlydHkoKTsKICAgICAgcmVuZGVyQ29uZmlnRWRpdG9yKCk7CiAgICB9CiAgfQogIGZ1bmN0aW9uIGJlZ2luQ2ZnQWRkRHJhZnQoZ2kpIHsKICAg
;IGlmIChjZmdBZGREcmFmdEdpID49IDAgJiYgY2ZnQWRkRHJhZnRHaSAhPT0gZ2kpIHsKICAgICAgY29uc3QgZCA9IHJlYWRDZmdBZGREcmFmdFZhbHVlcyhj
;ZmdBZGREcmFmdEdpKTsKICAgICAgaWYgKGQuZW1wdHkpIGNmZ0FkZERyYWZ0R2kgPSAtMTsKICAgICAgZWxzZSBjb21taXRDZmdBZGREcmFmdChjZmdBZGRE
;cmFmdEdpLCBkKTsKICAgIH0KICAgIGlmIChjZmdTZWwuaWkgPj0gMCkgewogICAgICBjb25zdCBncm91cHMgPSBjZmdDdXJyZW50KCk7CiAgICAgIGNvbnN0
;IGl0ID0gZ3JvdXBzICYmIGdyb3Vwc1tjZmdTZWwuZ2ldICYmIGdyb3Vwc1tjZmdTZWwuZ2ldLml0ZW1zICYmIGdyb3Vwc1tjZmdTZWwuZ2ldLml0ZW1zW2Nm
;Z1NlbC5paV07CiAgICAgIGlmIChpdCAmJiBpc0VtcHR5Q2ZnSXRlbShpdCkpIHsKICAgICAgICBncm91cHNbY2ZnU2VsLmdpXS5pdGVtcy5zcGxpY2UoY2Zn
;U2VsLmlpLCAxKTsKICAgICAgICBtYXJrQ2ZnRGlydHkoKTsKICAgICAgfQogICAgfQogICAgY2ZnQWRkRHJhZnRHaSA9IGdpOwogICAgY2ZnU2VsID0geyBn
;aSwgaWk6IC0xIH07CiAgICByZW5kZXJDb25maWdFZGl0b3IoKTsKICAgIHJlcXVlc3RBbmltYXRpb25GcmFtZSgoKSA9PiB7CiAgICAgIGNvbnN0IHJvdyA9
;IGNmZ0JvZHkgJiYgY2ZnQm9keS5xdWVyeVNlbGVjdG9yKCcuY2ZnLWFkZC1kcmFmdFtkYXRhLWdpPSInICsgZ2kgKyAnIl0nKTsKICAgICAgaWYgKCFyb3cp
;IHJldHVybjsKICAgICAgdHJ5IHsgcm93LnNjcm9sbEludG9WaWV3KHsgYmxvY2s6ICduZWFyZXN0JywgYmVoYXZpb3I6ICdzbW9vdGgnIH0pOyB9IGNhdGNo
;IChfKSB7fQogICAgICBjb25zdCBrZXlJbnAgPSByb3cucXVlcnlTZWxlY3RvcignaW5wdXQuY2ZnLWtleScpOwogICAgICB0cnkgeyBpZiAoa2V5SW5wKSB7
;IGtleUlucC5mb2N1cygpOyBrZXlJbnAuc2VsZWN0KCk7IH0gfSBjYXRjaCAoXykge30KICAgIH0pOwogIH0KICBmdW5jdGlvbiBjYW5jZWxDZmdBZGREcmFm
;dCgpIHsKICAgIGlmIChjZmdBZGREcmFmdEdpIDwgMCkgcmV0dXJuOwogICAgY2ZnQWRkRHJhZnRHaSA9IC0xOwogICAgcmVuZGVyQ29uZmlnRWRpdG9yKCk7
;CiAgfQogIGZ1bmN0aW9uIGNvbW1pdENmZ0FkZERyYWZ0KGdpLCBkYXRhKSB7CiAgICBjb25zdCBncm91cHMgPSBjZmdDdXJyZW50KCk7CiAgICBpZiAoIWdy
;b3VwcyB8fCAhZ3JvdXBzW2dpXSkgewogICAgICBjZmdBZGREcmFmdEdpID0gLTE7CiAgICAgIHJlbmRlckNvbmZpZ0VkaXRvcigpOwogICAgICByZXR1cm4g
;ZmFsc2U7CiAgICB9CiAgICBjb25zdCBrZXkgPSBTdHJpbmcoZGF0YSAmJiBkYXRhLmtleSB8fCAnJykudHJpbSgpOwogICAgY29uc3QgdmFsdWUgPSBTdHJp
;bmcoZGF0YSAmJiBkYXRhLnZhbHVlIHx8ICcnKTsKICAgIGNvbnN0IGNvbW1lbnQgPSBTdHJpbmcoZGF0YSAmJiBkYXRhLmNvbW1lbnQgfHwgJycpLnRyaW0o
;KTsKICAgIGNmZ0FkZERyYWZ0R2kgPSAtMTsKICAgIGlmICgha2V5ICYmICFTdHJpbmcodmFsdWUpLnRyaW0oKSAmJiAhY29tbWVudCkgewogICAgICByZW5k
;ZXJDb25maWdFZGl0b3IoKTsKICAgICAgcmV0dXJuIGZhbHNlOwogICAgfQogICAgY29uc3QgZyA9IGdyb3Vwc1tnaV07CiAgICBnLml0ZW1zID0gZy5pdGVt
;cyB8fCBbXTsKICAgIGcuaXRlbXMucHVzaCh7IGtleSwgdmFsdWUsIGNvbW1lbnQsIGVuYWJsZWQ6IHRydWUgfSk7CiAgICBtYXJrQ2ZnRGlydHkoKTsKICAg
;IHJlbmRlckNvbmZpZ0VkaXRvcigpOwogICAgcmV0dXJuIHRydWU7CiAgfQogIGZ1bmN0aW9uIGJ1aWxkQ2ZnQWRkRHJhZnRSb3coZ2kpIHsKICAgIGNvbnN0
;IHJvdyA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOwogICAgcm93LmNsYXNzTmFtZSA9ICdjZmctYWRkLWRyYWZ0JzsKICAgIHJvdy5kYXRhc2V0
;LmdpID0gU3RyaW5nKGdpKTsKICAgIGNvbnN0IGZpZWxkcyA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOwogICAgZmllbGRzLmNsYXNzTmFtZSA9
;ICdjZmctYWRkLWZpZWxkcyc7CiAgICBjb25zdCBkb3QgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdzcGFuJyk7CiAgICBkb3QuY2xhc3NOYW1lID0gJ2Nm
;Zy1kb3QnOwogICAgY29uc3Qga2V5SW5wID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnaW5wdXQnKTsKICAgIGtleUlucC50eXBlID0gJ3RleHQnOwogICAg
;a2V5SW5wLmNsYXNzTmFtZSA9ICdjZmcta2V5JzsKICAgIGtleUlucC5wbGFjZWhvbGRlciA9ICfmlrAga2V5JzsKICAgIGNvbnN0IGljb1BoID0gZG9jdW1l
;bnQuY3JlYXRlRWxlbWVudCgnc3BhbicpOwogICAgaWNvUGguY2xhc3NOYW1lID0gJ2NmZy12aWNvJzsKICAgIGNvbnN0IHZhbElucCA9IGRvY3VtZW50LmNy
;ZWF0ZUVsZW1lbnQoJ2lucHV0Jyk7CiAgICB2YWxJbnAudHlwZSA9ICd0ZXh0JzsKICAgIHZhbElucC5jbGFzc05hbWUgPSAnY2ZnLXZhbCc7CiAgICB2YWxJ
;bnAucGxhY2Vob2xkZXIgPSAndmFsdWUnOwogICAgY29uc3QgY210SW5wID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnaW5wdXQnKTsKICAgIGNtdElucC50
;eXBlID0gJ3RleHQnOwogICAgY210SW5wLmNsYXNzTmFtZSA9ICdjZmctY210JzsKICAgIGNtdElucC5wbGFjZWhvbGRlciA9ICflpIfms6gnOwogICAgY29u
;c3QgYWN0cyA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOwogICAgYWN0cy5jbGFzc05hbWUgPSAnY2ZnLWFkZC1hY3RzJzsKICAgIGNvbnN0IG9r
;QnRuID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnYnV0dG9uJyk7CiAgICBva0J0bi50eXBlID0gJ2J1dHRvbic7CiAgICBva0J0bi5jbGFzc05hbWUgPSAn
;Y2ZnLWFkZC1vayc7CiAgICBva0J0bi50aXRsZSA9ICfmt7vliqDliLDnu4TmnKvlsL4nOwogICAgb2tCdG4udGV4dENvbnRlbnQgPSAn5re75YqgJzsKICAg
;IGNvbnN0IGNhbmNlbEJ0biA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2J1dHRvbicpOwogICAgY2FuY2VsQnRuLnR5cGUgPSAnYnV0dG9uJzsKICAgIGNh
;bmNlbEJ0bi5jbGFzc05hbWUgPSAnY2ZnLWFkZC1jYW5jZWwnOwogICAgY2FuY2VsQnRuLnRpdGxlID0gJ+WPlua2iCc7CiAgICBjYW5jZWxCdG4udGV4dENv
;bnRlbnQgPSAn5Y+W5raIJzsKICAgIGNvbnN0IHJlYWREcmFmdCA9ICgpID0+ICh7CiAgICAgIGtleToga2V5SW5wLnZhbHVlLAogICAgICB2YWx1ZTogdmFs
;SW5wLnZhbHVlLAogICAgICBjb21tZW50OiBjbXRJbnAudmFsdWUKICAgIH0pOwogICAgY29uc3QgZG9Db21taXQgPSAoKSA9PiB7CiAgICAgIGNvbW1pdENm
;Z0FkZERyYWZ0KGdpLCByZWFkRHJhZnQoKSk7CiAgICAgIHNlbGVjdENmZ1RhcmdldChnaSwgLTEsIHsgc2tpcEZsdXNoOiB0cnVlIH0pOwogICAgfTsKICAg
;IG9rQnRuLm9uY2xpY2sgPSAoZSkgPT4geyBlLnByZXZlbnREZWZhdWx0KCk7IGUuc3RvcFByb3BhZ2F0aW9uKCk7IGRvQ29tbWl0KCk7IH07CiAgICBjYW5j
;ZWxCdG4ub25jbGljayA9IChlKSA9PiB7IGUucHJldmVudERlZmF1bHQoKTsgZS5zdG9wUHJvcGFnYXRpb24oKTsgY2FuY2VsQ2ZnQWRkRHJhZnQoKTsgfTsK
;ICAgIGNvbnN0IG9uS2V5ID0gKGUpID0+IHsKICAgICAgaWYgKGUua2V5ID09PSAnRW50ZXInKSB7CiAgICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOwogICAg
;ICAgIGRvQ29tbWl0KCk7CiAgICAgIH0gZWxzZSBpZiAoZS5rZXkgPT09ICdFc2NhcGUnKSB7CiAgICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOwogICAgICAg
;IGNhbmNlbENmZ0FkZERyYWZ0KCk7CiAgICAgIH0KICAgIH07CiAgICBrZXlJbnAub25rZXlkb3duID0gb25LZXk7CiAgICB2YWxJbnAub25rZXlkb3duID0g
;b25LZXk7CiAgICBjbXRJbnAub25rZXlkb3duID0gb25LZXk7CiAgICBhY3RzLmFwcGVuZENoaWxkKG9rQnRuKTsKICAgIGFjdHMuYXBwZW5kQ2hpbGQoY2Fu
;Y2VsQnRuKTsKICAgIGZpZWxkcy5hcHBlbmRDaGlsZChkb3QpOwogICAgZmllbGRzLmFwcGVuZENoaWxkKGtleUlucCk7CiAgICBmaWVsZHMuYXBwZW5kQ2hp
;bGQoaWNvUGgpOwogICAgZmllbGRzLmFwcGVuZENoaWxkKHZhbElucCk7CiAgICBmaWVsZHMuYXBwZW5kQ2hpbGQoY210SW5wKTsKICAgIHJvdy5hcHBlbmRD
;aGlsZChmaWVsZHMpOwogICAgcm93LmFwcGVuZENoaWxkKGFjdHMpOwogICAgcm93Lm9uY2xpY2sgPSAoZSkgPT4gZS5zdG9wUHJvcGFnYXRpb24oKTsKICAg
;IHJvdy5vbmNvbnRleHRtZW51ID0gKGUpID0+IHsgZS5wcmV2ZW50RGVmYXVsdCgpOyBlLnN0b3BQcm9wYWdhdGlvbigpOyB9OwogICAgcmV0dXJuIHJvdzsK
;ICB9CiAgZnVuY3Rpb24gZ2V0Q2ZnT3BlblN0YXRlKCkgewogICAgaWYgKCFjZmdPcGVuTWFwW2NmZ0FjdGl2ZVRhYl0pIGNmZ09wZW5NYXBbY2ZnQWN0aXZl
;VGFiXSA9IE9iamVjdC5jcmVhdGUobnVsbCk7CiAgICByZXR1cm4gY2ZnT3Blbk1hcFtjZmdBY3RpdmVUYWJdOwogIH0KICBmdW5jdGlvbiBpc0NmZ0dyb3Vw
;T3BlbihnaSwgZm9yY2VPcGVuKSB7CiAgICBpZiAoZm9yY2VPcGVuKSByZXR1cm4gdHJ1ZTsKICAgIHJldHVybiAhIWdldENmZ09wZW5TdGF0ZSgpW2dpXTsK
;ICB9CiAgZnVuY3Rpb24gdG9nZ2xlQ2ZnR3JvdXAoZ2kpIHsKICAgIGNvbnN0IG9wZW4gPSBnZXRDZmdPcGVuU3RhdGUoKTsKICAgIG9wZW5bZ2ldID0gIW9w
;ZW5bZ2ldOwogICAgcmVuZGVyQ29uZmlnRWRpdG9yKCk7CiAgICBzZWxlY3RDZmdUYXJnZXQoZ2ksIC0xKTsKICB9CiAgZnVuY3Rpb24gc2V0QWxsQ2ZnT3Bl
;bihvbikgewogICAgY29uc3QgZ3JvdXBzID0gY2ZnQ3VycmVudCgpOwogICAgY29uc3Qgb3BlbiA9IGdldENmZ09wZW5TdGF0ZSgpOwogICAgKGdyb3VwcyB8
;fCBbXSkuZm9yRWFjaCgoXywgZ2kpID0+IHsgb3BlbltnaV0gPSAhIW9uOyB9KTsKICAgIHJlbmRlckNvbmZpZ0VkaXRvcigpOwogIH0KICBmdW5jdGlvbiBh
;bnlDZmdHcm91cE9wZW4oKSB7CiAgICBjb25zdCBncm91cHMgPSBjZmdDdXJyZW50KCkgfHwgW107CiAgICBjb25zdCBvcGVuID0gZ2V0Q2ZnT3BlblN0YXRl
;KCk7CiAgICBmb3IgKGxldCBpID0gMDsgaSA8IGdyb3Vwcy5sZW5ndGg7IGkrKykgewogICAgICBpZiAob3BlbltpXSkgcmV0dXJuIHRydWU7CiAgICB9CiAg
;ICByZXR1cm4gZmFsc2U7CiAgfQogIGZ1bmN0aW9uIHN5bmNDZmdUb2dnbGVBbGxCdG4oKSB7CiAgICBjb25zdCBidG4gPSBkb2N1bWVudC5nZXRFbGVtZW50
;QnlJZCgnY2ZnLXRvZ2dsZS1hbGwnKTsKICAgIGlmICghYnRuKSByZXR1cm47CiAgICBjb25zdCBleHBhbmRlZCA9IGFueUNmZ0dyb3VwT3BlbigpOwogICAg
;YnRuLmNsYXNzTGlzdC50b2dnbGUoJ2lzLWV4cGFuZGVkJywgZXhwYW5kZWQpOwogICAgYnRuLnRpdGxlID0gZXhwYW5kZWQgPyAn5YWo6YOo5oqY5Y+gJyA6
;ICflhajpg6jlsZXlvIAnOwogICAgYnRuLnNldEF0dHJpYnV0ZSgnYXJpYS1leHBhbmRlZCcsIGV4cGFuZGVkID8gJ3RydWUnIDogJ2ZhbHNlJyk7CiAgfQog
;IGZ1bmN0aW9uIHRvZ2dsZUFsbENmZ0dyb3VwcygpIHsKICAgIGNvbnN0IG5leHQgPSAhYW55Q2ZnR3JvdXBPcGVuKCk7CiAgICBzZXRBbGxDZmdPcGVuKG5l
;eHQpOwogICAgc3luY0NmZ1RvZ2dsZUFsbEJ0bigpOwogIH0KICBmdW5jdGlvbiBlbnN1cmVDb25maWdVaSgpIHsKICAgIGlmIChjZmdVaVJlYWR5KSByZXR1
;cm47CiAgICBjZmdVaVJlYWR5ID0gdHJ1ZTsKICAgIGRvY3VtZW50LnF1ZXJ5U2VsZWN0b3JBbGwoJy5jZmctdGFiJykuZm9yRWFjaChidG4gPT4gewogICAg
;ICBidG4uYWRkRXZlbnRMaXN0ZW5lcignY2xpY2snLCBhc3luYyAoKSA9PiB7CiAgICAgICAgY29uc3QgbmFtZSA9IGJ0bi5kYXRhc2V0LmNmZzsKICAgICAg
;ICBpZiAoIW5hbWUgfHwgbmFtZSA9PT0gY2ZnQWN0aXZlVGFiKSByZXR1cm47CiAgICAgICAgLy8g56m65paw5aKe6KGMIC8g56m65p2h55uu5YWI5Lii5byD
;77yM5LiN5oyh5YiH5o2iCiAgICAgICAgaWYgKGNmZ0FkZERyYWZ0R2kgPj0gMCkgewogICAgICAgICAgY29uc3QgZCA9IHJlYWRDZmdBZGREcmFmdFZhbHVl
;cyhjZmdBZGREcmFmdEdpKTsKICAgICAgICAgIGlmIChkLmVtcHR5KSBjZmdBZGREcmFmdEdpID0gLTE7CiAgICAgICAgICBlbHNlIGNvbW1pdENmZ0FkZERy
;YWZ0KGNmZ0FkZERyYWZ0R2ksIGQpOwogICAgICAgIH0KICAgICAgICBwcnVuZUFsbEVtcHR5Q2ZnSXRlbXMoKTsKICAgICAgICBmbHVzaENmZ0F1dG9TYXZl
;KCk7CiAgICAgICAgaWYgKGNmZ0RpcnR5W2NmZ0FjdGl2ZVRhYl0pIHsKICAgICAgICAgIGNvbnN0IG9rID0gYXdhaXQgdWlDb25maXJtKCflvZPliY3phY3n
;va7mnInmnKrkv53lrZjkv67mlLnvvIzliIfmjaLlsIbkuKLlpLHmnKrkv53lrZjlhoXlrrnjgIInLCB7CiAgICAgICAgICAgIHRpdGxlOiAn5YiH5o2i6YWN
;572uJywgb2tUZXh0OiAn57un57ut5YiH5o2iJywgZGFuZ2VyOiB0cnVlCiAgICAgICAgICB9KTsKICAgICAgICAgIGlmICghb2spIHJldHVybjsKICAgICAg
;ICB9CiAgICAgICAgbG9hZEFoa0NvbmZpZ1RhYihuYW1lLCBmYWxzZSk7CiAgICAgIH0pOwogICAgfSk7CiAgICBjb25zdCBhZGRHID0gZG9jdW1lbnQuZ2V0
;RWxlbWVudEJ5SWQoJ2NmZy1hZGQtZ3JvdXAnKTsKICAgIGlmIChhZGRHKSBhZGRHLm9uY2xpY2sgPSBhc3luYyAoKSA9PiB7CiAgICAgIGNvbnN0IGcgPSBj
;ZmdDdXJyZW50KCk7CiAgICAgIGlmICghZykgcmV0dXJuOwogICAgICBjb25zdCB0aXRsZSA9IGF3YWl0IHVpUHJvbXB0KCfor7fovpPlhaXmlrDnu4TlkI3n
;p7AnLCAn5paw5YiG57uEJywgewogICAgICAgIHRpdGxlOiAn5re75Yqg5YiG57uEJywgb2tUZXh0OiAn5re75YqgJwogICAgICB9KTsKICAgICAgaWYgKHRp
;dGxlID09IG51bGwpIHJldHVybjsKICAgICAgZy5wdXNoKHsgdGl0bGU6IFN0cmluZyh0aXRsZSkudHJpbSgpIHx8ICfmlrDliIbnu4QnLCBpdGVtczogW10g
;fSk7CiAgICAgIG1hcmtDZmdEaXJ0eSgpOwogICAgICBjb25zdCBvcGVuID0gZ2V0Q2ZnT3BlblN0YXRlKCk7CiAgICAgIG9wZW5bZy5sZW5ndGggLSAxXSA9
;IHRydWU7CiAgICAgIHJlbmRlckNvbmZpZ0VkaXRvcigpOwogICAgICBzZWxlY3RDZmdUYXJnZXQoZy5sZW5ndGggLSAxLCAtMSk7CiAgICB9OwogICAgY29u
;c3QgdG9nZ2xlQWxsID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2NmZy10b2dnbGUtYWxsJyk7CiAgICBpZiAodG9nZ2xlQWxsKSB0b2dnbGVBbGwub25j
;bGljayA9ICgpID0+IHRvZ2dsZUFsbENmZ0dyb3VwcygpOwogICAgZG9jdW1lbnQucXVlcnlTZWxlY3RvckFsbCgnLmNmZy1zdGFnW2RhdGEtY2ZnLXNjb3Bl
;XScpLmZvckVhY2goYnRuID0+IHsKICAgICAgYnRuLmFkZEV2ZW50TGlzdGVuZXIoJ2NsaWNrJywgKCkgPT4gewogICAgICAgIGNvbnN0IHMgPSBidG4uZ2V0
;QXR0cmlidXRlKCdkYXRhLWNmZy1zY29wZScpOwogICAgICAgIGlmICghcykgcmV0dXJuOwogICAgICAgIC8vIOWQr+eUqCAvIOacquWQr+eUqOS6kuaWpe+8
;mueCueS4gOS4quWwseWFs+aOieWPpuS4gOS4qgogICAgICAgIGlmIChzID09PSAnZW5hYmxlZCcpIHsKICAgICAgICAgIGNmZ1NlYXJjaFNjb3BlLmVuYWJs
;ZWQgPSAhY2ZnU2VhcmNoU2NvcGUuZW5hYmxlZDsKICAgICAgICAgIGlmIChjZmdTZWFyY2hTY29wZS5lbmFibGVkKSBjZmdTZWFyY2hTY29wZS5kaXNhYmxl
;ZCA9IGZhbHNlOwogICAgICAgIH0gZWxzZSBpZiAocyA9PT0gJ2Rpc2FibGVkJykgewogICAgICAgICAgY2ZnU2VhcmNoU2NvcGUuZGlzYWJsZWQgPSAhY2Zn
;U2VhcmNoU2NvcGUuZGlzYWJsZWQ7CiAgICAgICAgICBpZiAoY2ZnU2VhcmNoU2NvcGUuZGlzYWJsZWQpIGNmZ1NlYXJjaFNjb3BlLmVuYWJsZWQgPSBmYWxz
;ZTsKICAgICAgICB9IGVsc2UgewogICAgICAgICAgY2ZnU2VhcmNoU2NvcGVbc10gPSAhY2ZnU2VhcmNoU2NvcGVbc107CiAgICAgICAgfQogICAgICAgIHN5
;bmNDZmdTZWFyY2hDaHJvbWUoKTsKICAgICAgICBpZiAoYXBwTW9kZSA9PT0gJ2NvbmZpZycpIHJlbmRlckNvbmZpZ0VkaXRvcigpOwogICAgICAgIGlmICh0
;eXBlb2Ygc2F2ZVNlc3Npb25Tb29uID09PSAnZnVuY3Rpb24nKSBzYXZlU2Vzc2lvblNvb24oKTsKICAgICAgfSk7CiAgICB9KTsKICAgIHN5bmNDZmdTZWFy
;Y2hDaHJvbWUoKTsKICAgIGlmIChjZmdUaXBFbCkgewogICAgICBjZmdUaXBFbC5hZGRFdmVudExpc3RlbmVyKCdkYmxjbGljaycsIChlKSA9PiB7CiAgICAg
;ICAgZS5wcmV2ZW50RGVmYXVsdCgpOwogICAgICAgIGJlZ2luQ2ZnVGlwRWRpdCgpOwogICAgICB9KTsKICAgIH0KICAgIGlmIChjZmdUaXBFZGl0RWwpIHsK
;ICAgICAgY2ZnVGlwRWRpdEVsLmFkZEV2ZW50TGlzdGVuZXIoJ2JsdXInLCAoKSA9PiBlbmRDZmdUaXBFZGl0KHRydWUpKTsKICAgICAgY2ZnVGlwRWRpdEVs
;LmFkZEV2ZW50TGlzdGVuZXIoJ2tleWRvd24nLCAoZSkgPT4gewogICAgICAgIGlmIChlLmtleSA9PT0gJ0VzY2FwZScpIHsKICAgICAgICAgIGUucHJldmVu
;dERlZmF1bHQoKTsKICAgICAgICAgIGVuZENmZ1RpcEVkaXQoZmFsc2UpOwogICAgICAgIH0gZWxzZSBpZiAoZS5rZXkgPT09ICdFbnRlcicgJiYgKGUuY3Ry
;bEtleSB8fCBlLm1ldGFLZXkpKSB7CiAgICAgICAgICBlLnByZXZlbnREZWZhdWx0KCk7CiAgICAgICAgICBlbmRDZmdUaXBFZGl0KHRydWUpOwogICAgICAg
;IH0KICAgICAgfSk7CiAgICB9CiAgICBjb25zdCByZWxvYWQgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnY2ZnLXJlbG9hZCcpOwogICAgaWYgKHJlbG9h
;ZCkgcmVsb2FkLm9uY2xpY2sgPSBhc3luYyAoKSA9PiB7CiAgICAgIGNsZWFyVGltZW91dChjZmdBdXRvU2F2ZVRpbWVyKTsKICAgICAgY2ZnQXV0b1NhdmVU
;aW1lciA9IDA7CiAgICAgIGlmIChjZmdEaXJ0eVtjZmdBY3RpdmVUYWJdKSB7CiAgICAgICAgY29uc3Qgb2sgPSBhd2FpdCB1aUNvbmZpcm0oJ+aUvuW8g+ac
;quS/neWtmOS/ruaUueW5tumHjeaWsOWKoOi9ve+8nycsIHsKICAgICAgICAgIHRpdGxlOiAn6YeN5paw5Yqg6L29Jywgb2tUZXh0OiAn5pS+5byD5bm25Yqg
;6L29JywgZGFuZ2VyOiB0cnVlCiAgICAgICAgfSk7CiAgICAgICAgaWYgKCFvaykgewogICAgICAgICAgaWYgKCFpc1N5c0NvbmZpZ1RhYigpKSBzY2hlZHVs
;ZUNmZ0F1dG9TYXZlKCk7CiAgICAgICAgICByZXR1cm47CiAgICAgICAgfQogICAgICB9CiAgICAgIGxvYWRBaGtDb25maWdUYWIoY2ZnQWN0aXZlVGFiLCB0
;cnVlKTsKICAgIH07CiAgICBjb25zdCBjZmdTYXZlQnRuID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2NmZy1zYXZlJyk7CiAgICBpZiAoY2ZnU2F2ZUJ0
;bikgewogICAgICBjZmdTYXZlQnRuLm9uY2xpY2sgPSBhc3luYyAoKSA9PiB7CiAgICAgICAgaWYgKCFpc1N5c0NvbmZpZ1RhYigpKSByZXR1cm47CiAgICAg
;ICAgaWYgKGNmZ0FkZERyYWZ0R2kgPj0gMCkgewogICAgICAgICAgY29uc3QgZCA9IHJlYWRDZmdBZGREcmFmdFZhbHVlcyhjZmdBZGREcmFmdEdpKTsKICAg
;ICAgICAgIGlmIChkLmVtcHR5KSBjZmdBZGREcmFmdEdpID0gLTE7CiAgICAgICAgICBlbHNlIGNvbW1pdENmZ0FkZERyYWZ0KGNmZ0FkZERyYWZ0R2ksIGQp
;OwogICAgICAgIH0KICAgICAgICBwcnVuZUFsbEVtcHR5Q2ZnSXRlbXMoKTsKICAgICAgICBpZiAoIWNmZ0RpcnR5LnN5c2NvbmZpZykgewogICAgICAgICAg
;c2V0Q2ZnU3RhdHVzKCfmsqHmnInpnIDopoHkv53lrZjnmoTkv67mlLknLCAnaW5mbycpOwogICAgICAgICAgc3luY0NmZ1NhdmVCdG4oKTsKICAgICAgICAg
;IHJldHVybjsKICAgICAgICB9CiAgICAgICAgY29uc3Qgb2sgPSBhd2FpdCB1aUNvbmZpcm0oJ+S/neWtmOezu+e7n+mFjee9ruWQjuWwhumHjeWQr+iEmuac
;rO+8jOaYr+WQpue7p+e7re+8nycsIHsKICAgICAgICAgIHRpdGxlOiAn5L+d5a2Y5bm26YeN5ZCvJywgb2tUZXh0OiAn5L+d5a2Y5bm26YeN5ZCvJywgZGFu
;Z2VyOiB0cnVlCiAgICAgICAgfSk7CiAgICAgICAgaWYgKCFvaykgcmV0dXJuOwogICAgICAgIHNhdmVBaGtDb25maWdUYWIoZmFsc2UpOwogICAgICB9Owog
;ICAgfQogICAgc3luY0NmZ1NhdmVCdG4oKTsKICAgIGlmIChjZmdNZW51KSB7CiAgICAgIGNmZ01lbnUucXVlcnlTZWxlY3RvckFsbCgnYnV0dG9uW2RhdGEt
;Y2FjdF0nKS5mb3JFYWNoKGJ0biA9PiB7CiAgICAgICAgYnRuLmFkZEV2ZW50TGlzdGVuZXIoJ2NsaWNrJywgKGUpID0+IHsKICAgICAgICAgIGUuc3RvcFBy
;b3BhZ2F0aW9uKCk7CiAgICAgICAgICBydW5DZmdNZW51QWN0aW9uKGJ0bi5nZXRBdHRyaWJ1dGUoJ2RhdGEtY2FjdCcpKTsKICAgICAgICB9KTsKICAgICAg
;fSk7CiAgICB9CiAgICBkb2N1bWVudC5hZGRFdmVudExpc3RlbmVyKCdjbGljaycsIChlKSA9PiB7CiAgICAgIGlmIChjZmdNZW51ICYmIGNmZ01lbnUuY2xh
;c3NMaXN0LmNvbnRhaW5zKCdvbicpICYmICFlLnRhcmdldC5jbG9zZXN0KCcjY2ZnLW1lbnUnKSkgaGlkZUNmZ01lbnUoKTsKICAgIH0pOwogICAgZG9jdW1l
;bnQuYWRkRXZlbnRMaXN0ZW5lcignY29udGV4dG1lbnUnLCAoZSkgPT4gewogICAgICBpZiAoIWUudGFyZ2V0LmNsb3Nlc3QoJyNjb25maWctcGFuZWwnKSAm
;JiAhZS50YXJnZXQuY2xvc2VzdCgnI2NmZy1tZW51JykpIGhpZGVDZmdNZW51KCk7CiAgICB9KTsKICAgIHdpbmRvdy5hZGRFdmVudExpc3RlbmVyKCdibHVy
;JywgaGlkZUNmZ01lbnUpOwogICAgd2luZG93LmFkZEV2ZW50TGlzdGVuZXIoJ3Jlc2l6ZScsIGhpZGVDZmdNZW51KTsKICB9CiAgZnVuY3Rpb24gbG9hZEFo
;a0NvbmZpZ1RhYihuYW1lLCBmb3JjZSkgewogICAgbmFtZSA9IFN0cmluZyhuYW1lIHx8ICdydW5jb25maWcnKTsKICAgIGNmZ0FjdGl2ZVRhYiA9IG5hbWU7
;CiAgICBjZmdBZGREcmFmdEdpID0gLTE7CiAgICBkb2N1bWVudC5xdWVyeVNlbGVjdG9yQWxsKCcuY2ZnLXRhYicpLmZvckVhY2goYiA9PiBiLmNsYXNzTGlz
;dC50b2dnbGUoJ29uJywgYi5kYXRhc2V0LmNmZyA9PT0gbmFtZSkpOwogICAgdXBkYXRlQ2ZnUGF0aEJhcihjZmdQYXRoc1tuYW1lXSB8fCAnJyk7CiAgICBz
;eW5jQ2ZnU2F2ZUJ0bigpOwogICAgaWYgKHR5cGVvZiBzYXZlU2Vzc2lvblNvb24gPT09ICdmdW5jdGlvbicpIHNhdmVTZXNzaW9uU29vbigpOwogICAgaWYg
;KCFmb3JjZSAmJiBjZmdDYWNoZVtuYW1lXSkgewogICAgICBjZmdEaXJ0eVtuYW1lXSA9IGZhbHNlOwogICAgICBzZXRDZmdTdGF0dXMoJycsICcnKTsKICAg
;ICAgc3luY0NmZ1RpcFVpKCk7CiAgICAgIHJlbmRlckNvbmZpZ0VkaXRvcigpOwogICAgICByZXR1cm47CiAgICB9CiAgICArK2NmZ0xvYWRHZW47CiAgICBz
;ZXRDZmdTdGF0dXMoJycsICcnKTsKICAgIHN5bmNDZmdUaXBVaSgpOwogICAgaWYgKGNmZ0JvZHkpIGNmZ0JvZHkuaW5uZXJIVE1MID0gJzxkaXYgY2xhc3M9
;ImNmZy1lbXB0eSI+5Yqg6L295Lit4oCmPC9kaXY+JzsKICAgIHBvc3QoJ2NvbmZpZ0xvYWR8JyArIG5hbWUpOwogIH0KICBmdW5jdGlvbiBzYXZlQWhrQ29u
;ZmlnVGFiKHNpbGVudCkgewogICAgZW5kQ2ZnVGlwRWRpdCh0cnVlKTsKICAgIGNvbnN0IGRvYyA9IGNmZ0RvYygpOwogICAgaWYgKCFkb2MgfHwgIWRvYy5n
;cm91cHMpIHsKICAgICAgaWYgKCFzaWxlbnQpIHNldENmZ1N0YXR1cygn5rKh5pyJ5Y+v5L+d5a2Y55qE5YaF5a65JywgJ2VycicpOwogICAgICByZXR1cm47
;CiAgICB9CiAgICBpZiAoIWNmZ0RpcnR5W2NmZ0FjdGl2ZVRhYl0gJiYgc2lsZW50KSByZXR1cm47CiAgICBjb25zdCB0ZXh0ID0gc2VyaWFsaXplQWhrQ29u
;ZmlnKGRvYyk7CiAgICBjb25zdCBiNjQgPSB0ZXh0VG9CNjQodGV4dCk7CiAgICBpZiAoIWI2NCkgewogICAgICBzZXRDZmdTdGF0dXMoJ+e8lueggeWksei0
;pScsICdlcnInKTsKICAgICAgcmV0dXJuOwogICAgfQogICAgY29uc3QgdGFiID0gY2ZnQWN0aXZlVGFiOwogICAgY2ZnRGlydHlbdGFiXSA9IGZhbHNlOwog
;ICAgY2ZnQXV0b1NhdmluZyA9IHRydWU7CiAgICBzZXRDZmdTdGF0dXMoc2lsZW50ID8gJ+iHquWKqOS/neWtmOS4reKApicgOiAn5q2j5Zyo5L+d5a2Y4oCm
;JywgJ2luZm8nKTsKICAgIHBvc3QoJ2NvbmZpZ1NhdmV8JyArIHRhYiArICd8JyArIGI2NCk7CiAgfQogIGZ1bmN0aW9uIGl0ZW1NYXRjaGVzU2VhcmNoKGl0
;LCBxKSB7CiAgICBjb25zdCBlbiA9IGl0LmVuYWJsZWQgIT09IGZhbHNlOwogICAgY29uc3Qgb25seU9uID0gY2ZnU2VhcmNoU2NvcGUuZW5hYmxlZCAmJiAh
;Y2ZnU2VhcmNoU2NvcGUuZGlzYWJsZWQ7CiAgICBjb25zdCBvbmx5T2ZmID0gY2ZnU2VhcmNoU2NvcGUuZGlzYWJsZWQgJiYgIWNmZ1NlYXJjaFNjb3BlLmVu
;YWJsZWQ7CiAgICBpZiAob25seU9uICYmICFlbikgcmV0dXJuIGZhbHNlOwogICAgaWYgKG9ubHlPZmYgJiYgZW4pIHJldHVybiBmYWxzZTsKICAgIGlmICgh
;cSkgcmV0dXJuIHRydWU7CiAgICBjb25zdCBrID0gU3RyaW5nKGl0LmtleSB8fCAnJykudG9Mb3dlckNhc2UoKTsKICAgIGNvbnN0IHYgPSBTdHJpbmcoaXQu
;dmFsdWUgfHwgJycpLnRvTG93ZXJDYXNlKCk7CiAgICBjb25zdCBjID0gU3RyaW5nKGl0LmNvbW1lbnQgfHwgJycpLnRvTG93ZXJDYXNlKCk7CiAgICBjb25z
;dCBvbmx5S2V5ID0gY2ZnU2VhcmNoU2NvcGUua2V5ICYmICFjZmdTZWFyY2hTY29wZS52YWx1ZTsKICAgIGNvbnN0IG9ubHlWYWwgPSBjZmdTZWFyY2hTY29w
;ZS52YWx1ZSAmJiAhY2ZnU2VhcmNoU2NvcGUua2V5OwogICAgY29uc3Qga2V5T3JWYWwgPSBjZmdTZWFyY2hTY29wZS5rZXkgJiYgY2ZnU2VhcmNoU2NvcGUu
;dmFsdWU7CiAgICBpZiAob25seUtleSkgcmV0dXJuIGsuaW5jbHVkZXMocSk7CiAgICBpZiAob25seVZhbCkgcmV0dXJuIHYuaW5jbHVkZXMocSk7CiAgICBp
;ZiAoa2V5T3JWYWwpIHJldHVybiBrLmluY2x1ZGVzKHEpIHx8IHYuaW5jbHVkZXMocSk7CiAgICByZXR1cm4gay5pbmNsdWRlcyhxKSB8fCB2LmluY2x1ZGVz
;KHEpIHx8IGMuaW5jbHVkZXMocSk7CiAgfQogIGZ1bmN0aW9uIGNmZ0hhc0FjdGl2ZUZpbHRlcigpIHsKICAgIHJldHVybiAhIShjZmdTZWFyY2ggfHwgY2Zn
;U2VhcmNoU2NvcGUuZW5hYmxlZCB8fCBjZmdTZWFyY2hTY29wZS5kaXNhYmxlZCk7CiAgfQogIGZ1bmN0aW9uIGdyb3VwVGl0bGVNYXRjaGVzKHRpdGxlLCBx
;KSB7CiAgICBpZiAoIXEpIHJldHVybiBmYWxzZTsKICAgIC8vIOmZkOWumiBrZXkvdmFsdWUg5pe25LiN5oyJ57uE5ZCN5Yy56YWNCiAgICBpZiAoY2ZnU2Vh
;cmNoU2NvcGUua2V5IHx8IGNmZ1NlYXJjaFNjb3BlLnZhbHVlKSByZXR1cm4gZmFsc2U7CiAgICByZXR1cm4gU3RyaW5nKHRpdGxlIHx8ICcnKS50b0xvd2Vy
;Q2FzZSgpLmluY2x1ZGVzKHEpOwogIH0KICBmdW5jdGlvbiBoaWdobGlnaHRDZmdIdG1sKHRleHQsIHEpIHsKICAgIGxldCBodG1sID0gZXNjYXBlSHRtbChT
;dHJpbmcodGV4dCA/PyAnJykpOwogICAgY29uc3QgcmF3USA9IFN0cmluZyhxIHx8ICcnKS50cmltKCk7CiAgICBpZiAoIXJhd1EpIHJldHVybiBodG1sOwog
;ICAgY29uc3QgdGVybXMgPSByYXdRLnNwbGl0KC9ccysvKS5tYXAodCA9PiB0LnRyaW0oKSkuZmlsdGVyKEJvb2xlYW4pCiAgICAgIC5zb3J0KChhLCBiKSA9
;PiBiLmxlbmd0aCAtIGEubGVuZ3RoKTsKICAgIGZvciAoY29uc3QgdCBvZiB0ZXJtcykgewogICAgICBjb25zdCByZSA9IG5ldyBSZWdFeHAodC5yZXBsYWNl
;KC9bLiorP14ke30oKXxbXF1cXF0vZywgJ1xcJCYnKSwgJ2dpJyk7CiAgICAgIGh0bWwgPSBodG1sLnJlcGxhY2UocmUsIG0gPT4gJzxtYXJrPicgKyBtICsg
;JzwvbWFyaz4nKTsKICAgIH0KICAgIHJldHVybiBodG1sOwogIH0KICBmdW5jdGlvbiBtYWtlQ2ZnSGxGaWVsZChjbGFzc05hbWUsIHZhbHVlLCBxLCBvbkNv
;bW1pdCwgb3B0cykgewogICAgb3B0cyA9IG9wdHMgfHwge307CiAgICBjb25zdCB3cmFwID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnZGl2Jyk7CiAgICB3
;cmFwLmNsYXNzTmFtZSA9ICdjZmctaGwtZmllbGQgJyArIGNsYXNzTmFtZTsKICAgIGNvbnN0IGlucCA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2lucHV0
;Jyk7CiAgICBpbnAudHlwZSA9ICd0ZXh0JzsKICAgIGlucC5jbGFzc05hbWUgPSBjbGFzc05hbWU7CiAgICBpbnAucGxhY2Vob2xkZXIgPSBvcHRzLnBsYWNl
;aG9sZGVyIHx8ICcnOwogICAgaW5wLnZhbHVlID0gdmFsdWUgfHwgJyc7CiAgICBpZiAoIXEpIHsKICAgICAgaW5wLm9uaW5wdXQgPSAoKSA9PiBvbkNvbW1p
;dChpbnAudmFsdWUpOwogICAgICB3cmFwLmFwcGVuZENoaWxkKGlucCk7CiAgICAgIHJldHVybiB7IHdyYXAsIGlucHV0OiBpbnAgfTsKICAgIH0KICAgIGNv
;bnN0IHZpZXcgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsKICAgIHZpZXcuY2xhc3NOYW1lID0gJ2NmZy1obC12aWV3JzsKICAgIGNvbnN0IHBo
;ID0gZXNjYXBlSHRtbChvcHRzLnBsYWNlaG9sZGVyIHx8ICcnKTsKICAgIHZpZXcuaW5uZXJIVE1MID0gaGlnaGxpZ2h0Q2ZnSHRtbCh2YWx1ZSB8fCAnJywg
;cSkgfHwgKCc8c3BhbiBzdHlsZT0iY29sb3I6Izk0YTNiOCI+JyArIHBoICsgJzwvc3Bhbj4nKTsKICAgIGNvbnN0IHNob3dWaWV3ID0gKCkgPT4gewogICAg
;ICBpbnAuc3R5bGUuZGlzcGxheSA9ICdub25lJzsKICAgICAgdmlldy5zdHlsZS5kaXNwbGF5ID0gJyc7CiAgICAgIHZpZXcuaW5uZXJIVE1MID0gaGlnaGxp
;Z2h0Q2ZnSHRtbChpbnAudmFsdWUgfHwgJycsIHEpIHx8ICgnPHNwYW4gc3R5bGU9ImNvbG9yOiM5NGEzYjgiPicgKyBwaCArICc8L3NwYW4+Jyk7CiAgICB9
;OwogICAgY29uc3Qgc2hvd0VkaXQgPSAoKSA9PiB7CiAgICAgIHZpZXcuc3R5bGUuZGlzcGxheSA9ICdub25lJzsKICAgICAgaW5wLnN0eWxlLmRpc3BsYXkg
;PSAnJzsKICAgICAgdHJ5IHsgaW5wLmZvY3VzKCk7IGlucC5zZWxlY3QoKTsgfSBjYXRjaCAoXykge30KICAgIH07CiAgICBpbnAuc3R5bGUuZGlzcGxheSA9
;ICdub25lJzsKICAgIGlucC5vbmlucHV0ID0gKCkgPT4gb25Db21taXQoaW5wLnZhbHVlKTsKICAgIGlucC5vbmJsdXIgPSAoKSA9PiB7IG9uQ29tbWl0KGlu
;cC52YWx1ZSk7IHNob3dWaWV3KCk7IH07CiAgICBpbnAub25rZXlkb3duID0gKGUpID0+IHsKICAgICAgaWYgKGUua2V5ID09PSAnRW50ZXInIHx8IGUua2V5
;ID09PSAnRXNjYXBlJykgeyBlLnByZXZlbnREZWZhdWx0KCk7IGlucC5ibHVyKCk7IH0KICAgIH07CiAgICB2aWV3Lm9uY2xpY2sgPSAoZSkgPT4geyBlLnN0
;b3BQcm9wYWdhdGlvbigpOyBzaG93RWRpdCgpOyB9OwogICAgd3JhcC5hcHBlbmRDaGlsZCh2aWV3KTsKICAgIHdyYXAuYXBwZW5kQ2hpbGQoaW5wKTsKICAg
;IHJldHVybiB7IHdyYXAsIGlucHV0OiBpbnAsIHZpZXcgfTsKICB9CiAgZnVuY3Rpb24gcmVuZGVyQ29uZmlnRWRpdG9yKCkgewogICAgaWYgKCFjZmdCb2R5
;KSByZXR1cm47CiAgICBjb25zdCBncm91cHMgPSBjZmdDdXJyZW50KCk7CiAgICBpZiAoIWdyb3VwcykgewogICAgICBjZmdCb2R5LmlubmVySFRNTCA9ICc8
;ZGl2IGNsYXNzPSJjZmctZW1wdHkiPuaaguaXoOaVsOaNrjwvZGl2Pic7CiAgICAgIHVwZGF0ZUNmZ1BhdGhCYXIoY2ZnUGF0aHNbY2ZnQWN0aXZlVGFiXSB8
;fCAnJyk7CiAgICAgIHVwZGF0ZUNmZ1NlYXJjaEhpdCgwKTsKICAgICAgc3luY0NmZ1NlYXJjaENocm9tZSgpOwogICAgICByZXR1cm47CiAgICB9CiAgICBj
;b25zdCBxID0gY2ZnU2VhcmNoOwogICAgY29uc3QgZmlsdGVyaW5nID0gY2ZnSGFzQWN0aXZlRmlsdGVyKCk7CiAgICBsZXQgdG90YWwgPSAwOwogICAgbGV0
;IHNob3duID0gMDsKICAgIGNmZ0JvZHkuaW5uZXJIVE1MID0gJyc7CiAgICBsZXQgYW55ID0gZmFsc2U7CiAgICBncm91cHMuZm9yRWFjaCgoZywgZ2kpID0+
;IHsKICAgICAgdG90YWwgKz0gKGcuaXRlbXMgfHwgW10pLmxlbmd0aDsKICAgICAgY29uc3QgdGl0bGVIaXQgPSBncm91cFRpdGxlTWF0Y2hlcyhnLnRpdGxl
;LCBxKTsKICAgICAgY29uc3QgbWF0Y2hlZEl0ZW1zID0gKGcuaXRlbXMgfHwgW10pLm1hcCgoaXQsIGlpKSA9PiAoeyBpdDogbm9ybWFsaXplSXRlbShpdCks
;IGlpIH0pKQogICAgICAgIC5maWx0ZXIoeCA9PiBpdGVtTWF0Y2hlc1NlYXJjaCh4Lml0LCBxKSk7CiAgICAgIGlmIChmaWx0ZXJpbmcgJiYgIW1hdGNoZWRJ
;dGVtcy5sZW5ndGggJiYgIXRpdGxlSGl0KSByZXR1cm47CiAgICAgIGFueSA9IHRydWU7CiAgICAgIGNvbnN0IHJvd3MgPSAhZmlsdGVyaW5nCiAgICAgICAg
;PyAoZy5pdGVtcyB8fCBbXSkubWFwKChpdCwgaWkpID0+ICh7IGl0OiBub3JtYWxpemVJdGVtKGl0KSwgaWkgfSkpCiAgICAgICAgOiAobWF0Y2hlZEl0ZW1z
;Lmxlbmd0aCB8fCAhdGl0bGVIaXQKICAgICAgICAgID8gbWF0Y2hlZEl0ZW1zCiAgICAgICAgICA6IChnLml0ZW1zIHx8IFtdKS5tYXAoKGl0LCBpaSkgPT4g
;KHsgaXQ6IG5vcm1hbGl6ZUl0ZW0oaXQpLCBpaSB9KSkuZmlsdGVyKHggPT4gaXRlbU1hdGNoZXNTZWFyY2goeC5pdCwgJycpKSk7CiAgICAgIHNob3duICs9
;IHJvd3MubGVuZ3RoOwogICAgICBjb25zdCBmb3JjZU9wZW4gPSBmaWx0ZXJpbmc7CiAgICAgIGNvbnN0IGlzT3BlbiA9IGlzQ2ZnR3JvdXBPcGVuKGdpLCBm
;b3JjZU9wZW4pOwogICAgICBjb25zdCBjYXJkID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnZGl2Jyk7CiAgICAgIGNhcmQuY2xhc3NOYW1lID0gJ2NmZy1j
;YXJkJwogICAgICAgICsgKGlzT3BlbiA/ICcgb3BlbicgOiAnJykKICAgICAgICArIChjZmdTZWwuZ2kgPT09IGdpID8gJyBvbicgOiAnJykKICAgICAgICAr
;ICh0aXRsZUhpdCA/ICcgaGl0JyA6ICcnKTsKICAgICAgY2FyZC5kYXRhc2V0LmdpID0gU3RyaW5nKGdpKTsKICAgICAgY29uc3QgaGQgPSBkb2N1bWVudC5j
;cmVhdGVFbGVtZW50KCdkaXYnKTsKICAgICAgaGQuY2xhc3NOYW1lID0gJ2NmZy1jYXJkLWhkJzsKICAgICAgY29uc3QgdGl0bGVJbnAgPSBkb2N1bWVudC5j
;cmVhdGVFbGVtZW50KCdpbnB1dCcpOwogICAgICB0aXRsZUlucC50eXBlID0gJ3RleHQnOwogICAgICB0aXRsZUlucC5jbGFzc05hbWUgPSAnY2ZnLWd0aXRs
;ZSc7CiAgICAgIHRpdGxlSW5wLnZhbHVlID0gZy50aXRsZSB8fCAnJzsKICAgICAgdGl0bGVJbnAucGxhY2Vob2xkZXIgPSAn57uE5ZCNJzsKICAgICAgdGl0
;bGVJbnAub25pbnB1dCA9ICgpID0+IHsgZy50aXRsZSA9IHRpdGxlSW5wLnZhbHVlOyBtYXJrQ2ZnRGlydHkoKTsgfTsKICAgICAgdGl0bGVJbnAub25mb2N1
;cyA9ICgpID0+IHNlbGVjdENmZ1RhcmdldChnaSwgLTEpOwogICAgICBpZiAocSAmJiBTdHJpbmcoZy50aXRsZSB8fCAnJykudG9Mb3dlckNhc2UoKS5pbmNs
;dWRlcyhxKSkgewogICAgICAgIGNvbnN0IHRpdGxlSGwgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsKICAgICAgICB0aXRsZUhsLmNsYXNzTmFt
;ZSA9ICdjZmctZ3RpdGxlLWhsJzsKICAgICAgICB0aXRsZUhsLmlubmVySFRNTCA9IGhpZ2hsaWdodENmZ0h0bWwoZy50aXRsZSB8fCAnJywgcSk7CiAgICAg
;ICAgdGl0bGVIbC50aXRsZSA9ICfngrnlh7vnvJbovpHnu4TlkI0nOwogICAgICAgIHRpdGxlSGwub25jbGljayA9IChlKSA9PiB7CiAgICAgICAgICBlLnN0
;b3BQcm9wYWdhdGlvbigpOwogICAgICAgICAgdGl0bGVIbC5yZXBsYWNlV2l0aCh0aXRsZUlucCk7CiAgICAgICAgICB0cnkgeyB0aXRsZUlucC5mb2N1cygp
;OyB0aXRsZUlucC5zZWxlY3QoKTsgfSBjYXRjaCAoXykge30KICAgICAgICB9OwogICAgICAgIHRpdGxlSW5wLm9uYmx1ciA9ICgpID0+IHsKICAgICAgICAg
;IGcudGl0bGUgPSB0aXRsZUlucC52YWx1ZTsKICAgICAgICAgIG1hcmtDZmdEaXJ0eSgpOwogICAgICAgICAgdGl0bGVIbC5pbm5lckhUTUwgPSBoaWdobGln
;aHRDZmdIdG1sKGcudGl0bGUgfHwgJycsIHEpOwogICAgICAgICAgaWYgKHRpdGxlSW5wLnBhcmVudE5vZGUpIHRpdGxlSW5wLnJlcGxhY2VXaXRoKHRpdGxl
;SGwpOwogICAgICAgIH07CiAgICAgICAgaGQuYXBwZW5kQ2hpbGQodGl0bGVIbCk7CiAgICAgIH0gZWxzZSB7CiAgICAgICAgaGQuYXBwZW5kQ2hpbGQodGl0
;bGVJbnApOwogICAgICB9CiAgICAgIGNvbnN0IGNvdW50ID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnYnV0dG9uJyk7CiAgICAgIGNvdW50LnR5cGUgPSAn
;YnV0dG9uJzsKICAgICAgY291bnQuY2xhc3NOYW1lID0gJ2NmZy1nY291bnQnOwogICAgICBjb3VudC50aXRsZSA9IGlzT3BlbiA/ICfngrnlh7vmipjlj6An
;IDogJ+eCueWHu+WxleW8gCc7CiAgICAgIGNvdW50LmlubmVySFRNTCA9ICc8c3BhbiBjbGFzcz0iY2ZnLWNoZXYiPicgKyAoaXNPcGVuID8gJ+KWvicgOiAn
;4pa4JykgKyAnPC9zcGFuPjxzcGFuPicgKyByb3dzLmxlbmd0aCArICcg6aG5PC9zcGFuPic7CiAgICAgIGNvdW50Lm9uY2xpY2sgPSAoZSkgPT4gewogICAg
;ICAgIGUucHJldmVudERlZmF1bHQoKTsKICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgICAgIHNlbGVjdENmZ1RhcmdldChnaSwgLTEpOwogICAg
;ICAgIGlmIChmb3JjZU9wZW4pIHJldHVybjsKICAgICAgICB0b2dnbGVDZmdHcm91cChnaSk7CiAgICAgIH07CiAgICAgIGhkLmFwcGVuZENoaWxkKGNvdW50
;KTsKICAgICAgaGQub25jb250ZXh0bWVudSA9IChlKSA9PiB7CiAgICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOwogICAgICAgIGUuc3RvcFByb3BhZ2F0aW9u
;KCk7CiAgICAgICAgc2VsZWN0Q2ZnVGFyZ2V0KGdpLCAtMSk7CiAgICAgICAgc2hvd0NmZ01lbnUoZS5jbGllbnRYLCBlLmNsaWVudFksIHsgdHlwZTogJ2dy
;b3VwJywgZ2kgfSk7CiAgICAgIH07CiAgICAgIGhkLm9uY2xpY2sgPSAoZSkgPT4gewogICAgICAgIGlmIChlLnRhcmdldC5jbG9zZXN0KCcuY2ZnLWdjb3Vu
;dCwgaW5wdXQsIC5jZmctZ3RpdGxlLWhsJykpIHJldHVybjsKICAgICAgICBzZWxlY3RDZmdUYXJnZXQoZ2ksIC0xKTsKICAgICAgfTsKICAgICAgY2FyZC5h
;cHBlbmRDaGlsZChoZCk7CiAgICAgIGlmIChjZmdBZGREcmFmdEdpID09PSBnaSkKICAgICAgICBjYXJkLmFwcGVuZENoaWxkKGJ1aWxkQ2ZnQWRkRHJhZnRS
;b3coZ2kpKTsKICAgICAgY29uc3QgbGlzdCA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOwogICAgICBsaXN0LmNsYXNzTmFtZSA9ICdjZmctbGlz
;dCc7CiAgICAgIGlmIChpc09wZW4pIHsKICAgICAgICBpZiAoIXJvd3MubGVuZ3RoKSB7CiAgICAgICAgICBjb25zdCBlbXB0eSA9IGRvY3VtZW50LmNyZWF0
;ZUVsZW1lbnQoJ2RpdicpOwogICAgICAgICAgZW1wdHkuY2xhc3NOYW1lID0gJ2NmZy1pdGVtLWVtcHR5JzsKICAgICAgICAgIGVtcHR5LnRleHRDb250ZW50
;ID0gcSA/ICfml6DljLnphY3mnaHnm64nIDogJ+WPs+mUruWIhue7hOagh+mimOWPr+a3u+WKoOadoeebric7CiAgICAgICAgICBsaXN0LmFwcGVuZENoaWxk
;KGVtcHR5KTsKICAgICAgICB9CiAgICAgICAgcm93cy5mb3JFYWNoKCh7IGl0LCBpaSB9KSA9PiB7CiAgICAgICAgICBjb25zdCByb3cgPSBkb2N1bWVudC5j
;cmVhdGVFbGVtZW50KCdkaXYnKTsKICAgICAgICAgIHJvdy5jbGFzc05hbWUgPSAnY2ZnLWl0ZW0nCiAgICAgICAgICAgICsgKGl0LmVuYWJsZWQgPT09IGZh
;bHNlID8gJyBvZmYnIDogJycpCiAgICAgICAgICAgICsgKGNmZ1NlbC5naSA9PT0gZ2kgJiYgY2ZnU2VsLmlpID09PSBpaSA/ICcgb24nIDogJycpOwogICAg
;ICAgICAgcm93LmRhdGFzZXQuZ2kgPSBTdHJpbmcoZ2kpOwogICAgICAgICAgcm93LmRhdGFzZXQuaWkgPSBTdHJpbmcoaWkpOwogICAgICAgICAgY29uc3Qg
;ZG90ID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnc3BhbicpOwogICAgICAgICAgZG90LmNsYXNzTmFtZSA9ICdjZmctZG90JzsKICAgICAgICAgIGNvbnN0
;IG9ubHlLZXkgPSBjZmdTZWFyY2hTY29wZS5rZXkgJiYgIWNmZ1NlYXJjaFNjb3BlLnZhbHVlOwogICAgICAgICAgY29uc3Qgb25seVZhbCA9IGNmZ1NlYXJj
;aFNjb3BlLnZhbHVlICYmICFjZmdTZWFyY2hTY29wZS5rZXk7CiAgICAgICAgICBjb25zdCBxS2V5ID0gKCFxIHx8IG9ubHlWYWwpID8gJycgOiBxOwogICAg
;ICAgICAgY29uc3QgcVZhbCA9ICghcSB8fCBvbmx5S2V5KSA/ICcnIDogcTsKICAgICAgICAgIGNvbnN0IHFDbXQgPSAoIXEgfHwgY2ZnU2VhcmNoU2NvcGUu
;a2V5IHx8IGNmZ1NlYXJjaFNjb3BlLnZhbHVlKSA/ICcnIDogcTsKICAgICAgICAgIGNvbnN0IGtleUZpZWxkID0gbWFrZUNmZ0hsRmllbGQoJ2NmZy1rZXkn
;LCBpdC5rZXkgfHwgJycsIHFLZXksICh2KSA9PiB7IGl0LmtleSA9IHY7IG1hcmtDZmdEaXJ0eSgpOyB9LCB7IHBsYWNlaG9sZGVyOiAna2V5JyB9KTsKICAg
;ICAgICAgIGNvbnN0IHZpY28gPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdzcGFuJyk7CiAgICAgICAgICB2aWNvLmNsYXNzTmFtZSA9ICdjZmctdmljbyc7
;CiAgICAgICAgICBjb25zdCB2YWxGaWVsZCA9IG1ha2VDZmdIbEZpZWxkKCdjZmctdmFsJywgaXQudmFsdWUgfHwgJycsIHFWYWwsICh2KSA9PiB7CiAgICAg
;ICAgICAgIGl0LnZhbHVlID0gdjsKICAgICAgICAgICAgbWFya0NmZ0RpcnR5KCk7CiAgICAgICAgICAgIGNvbnN0IGNscyA9IGNsYXNzaWZ5Q2ZnVmFsdWUo
;dik7CiAgICAgICAgICAgIHJlcXVlc3RDZmdJY29uKHZpY28sIGNscy5raW5kLCBjbHMucGF0aCk7CiAgICAgICAgICB9LCB7IHBsYWNlaG9sZGVyOiAndmFs
;dWUnIH0pOwogICAgICAgICAgY29uc3QgcmVmcmVzaEljbyA9ICgpID0+IHsKICAgICAgICAgICAgY29uc3QgY2xzID0gY2xhc3NpZnlDZmdWYWx1ZShpdC52
;YWx1ZSB8fCAnJyk7CiAgICAgICAgICAgIHJlcXVlc3RDZmdJY29uKHZpY28sIGNscy5raW5kLCBjbHMucGF0aCk7CiAgICAgICAgICB9OwogICAgICAgICAg
;Y29uc3QgZW5XcmFwID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnbGFiZWwnKTsKICAgICAgICAgIGVuV3JhcC5jbGFzc05hbWUgPSAnY2ZnLWVuJzsKICAg
;ICAgICAgIGVuV3JhcC50aXRsZSA9ICflj5bmtojli77pgInliJnkv53lrZjkuLrvvJoja2V5PXZhbHVlICAgI+W8g+eUqCc7CiAgICAgICAgICBjb25zdCBj
;aGsgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdpbnB1dCcpOwogICAgICAgICAgY2hrLnR5cGUgPSAnY2hlY2tib3gnOwogICAgICAgICAgY2hrLmNoZWNr
;ZWQgPSBpdC5lbmFibGVkICE9PSBmYWxzZTsKICAgICAgICAgIGNoay5vbmNoYW5nZSA9ICgpID0+IHsKICAgICAgICAgICAgaXQuZW5hYmxlZCA9ICEhY2hr
;LmNoZWNrZWQ7CiAgICAgICAgICAgIG1hcmtDZmdEaXJ0eSgpOwogICAgICAgICAgICByb3cuY2xhc3NMaXN0LnRvZ2dsZSgnb2ZmJywgIWl0LmVuYWJsZWQp
;OwogICAgICAgICAgfTsKICAgICAgICAgIGVuV3JhcC5hcHBlbmRDaGlsZChjaGspOwogICAgICAgICAgZW5XcmFwLmFwcGVuZENoaWxkKGRvY3VtZW50LmNy
;ZWF0ZVRleHROb2RlKCflkK/nlKgnKSk7CiAgICAgICAgICByb3cuYXBwZW5kQ2hpbGQoZG90KTsKICAgICAgICAgIHJvdy5hcHBlbmRDaGlsZChrZXlGaWVs
;ZC53cmFwKTsKICAgICAgICAgIHJvdy5hcHBlbmRDaGlsZCh2aWNvKTsKICAgICAgICAgIHJvdy5hcHBlbmRDaGlsZCh2YWxGaWVsZC53cmFwKTsKICAgICAg
;ICAgIGNvbnN0IGNtdEZpZWxkID0gbWFrZUNmZ0hsRmllbGQoJ2NmZy1jbXQnLCBpdC5jb21tZW50IHx8ICcnLCBxQ210LCAodikgPT4geyBpdC5jb21tZW50
;ID0gdjsgbWFya0NmZ0RpcnR5KCk7IH0sIHsgcGxhY2Vob2xkZXI6ICcj5rOo6YeKJyB9KTsKICAgICAgICAgIHJvdy5hcHBlbmRDaGlsZChjbXRGaWVsZC53
;cmFwKTsKICAgICAgICAgIHJvdy5hcHBlbmRDaGlsZChlbldyYXApOwogICAgICAgICAgcm93Lm9uY2xpY2sgPSAoZSkgPT4gewogICAgICAgICAgICBpZiAo
;ZS50YXJnZXQuY2xvc2VzdCgnaW5wdXQsbGFiZWwsYnV0dG9uLC5jZmctaGwtdmlldycpKSB7IHNlbGVjdENmZ1RhcmdldChnaSwgaWkpOyByZXR1cm47IH0K
;ICAgICAgICAgICAgc2VsZWN0Q2ZnVGFyZ2V0KGdpLCBpaSk7CiAgICAgICAgICB9OwogICAgICAgICAgcm93Lm9uY29udGV4dG1lbnUgPSAoZSkgPT4gewog
;ICAgICAgICAgICBlLnByZXZlbnREZWZhdWx0KCk7CiAgICAgICAgICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAgICAgICAgIHNlbGVjdENmZ1Rhcmdl
;dChnaSwgaWkpOwogICAgICAgICAgICBzaG93Q2ZnTWVudShlLmNsaWVudFgsIGUuY2xpZW50WSwgeyB0eXBlOiAnaXRlbScsIGdpLCBpaSB9KTsKICAgICAg
;ICAgIH07CiAgICAgICAgICBsaXN0LmFwcGVuZENoaWxkKHJvdyk7CiAgICAgICAgICByZWZyZXNoSWNvKCk7CiAgICAgICAgfSk7CiAgICAgIH0KICAgICAg
;Y2FyZC5hcHBlbmRDaGlsZChsaXN0KTsKICAgICAgY2ZnQm9keS5hcHBlbmRDaGlsZChjYXJkKTsKICAgIH0pOwogICAgaWYgKCFhbnkpIGNmZ0JvZHkuaW5u
;ZXJIVE1MID0gJzxkaXYgY2xhc3M9ImNmZy1lbXB0eSI+5peg5Yy56YWN57uT5p6cPC9kaXY+JzsKICAgIGlmIChjZmdTZWwuZ2kgPj0gMCkgc2VsZWN0Q2Zn
;VGFyZ2V0KGNmZ1NlbC5naSwgY2ZnU2VsLmlpLCB7IHNraXBGbHVzaDogdHJ1ZSB9KTsKICAgIGVsc2UgdXBkYXRlQ2ZnUGF0aEJhcihjZmdQYXRoc1tjZmdB
;Y3RpdmVUYWJdIHx8ICcnKTsKICAgIHN5bmNDZmdUb2dnbGVBbGxCdG4oKTsKICAgIHVwZGF0ZUNmZ1NlYXJjaEhpdChmaWx0ZXJpbmcgPyBzaG93biA6IDAp
;OwogICAgc3luY0NmZ1NlYXJjaENocm9tZSgpOwogIH0KCiAgd2luZG93Ll9fc2V0QWhrQ29uZmlnID0gKHBheWxvYWQpID0+IHsKICAgIHRyeSB7CiAgICAg
;IGNvbnN0IGRhdGEgPSB0eXBlb2YgcGF5bG9hZCA9PT0gJ3N0cmluZycgPyBKU09OLnBhcnNlKHBheWxvYWQpIDogcGF5bG9hZDsKICAgICAgY29uc3QgbmFt
;ZSA9IFN0cmluZyhkYXRhICYmIGRhdGEubmFtZSB8fCAnJyk7CiAgICAgIGNvbnN0IG9rID0gISEoZGF0YSAmJiBkYXRhLm9rKTsKICAgICAgY29uc3QgbXNn
;ID0gU3RyaW5nKGRhdGEgJiYgZGF0YS5tZXNzYWdlIHx8ICcnKTsKICAgICAgaWYgKGRhdGEgJiYgZGF0YS5wYXRoKSBjZmdQYXRoc1tuYW1lIHx8IGNmZ0Fj
;dGl2ZVRhYl0gPSBTdHJpbmcoZGF0YS5wYXRoKTsKICAgICAgY29uc3QgbmVlZEhvbWUgPSAvSEVMUE1FX0hPTUUvLnRlc3QobXNnKTsKICAgICAgaWYgKCFv
;aykgewogICAgICAgIGNmZ0F1dG9TYXZpbmcgPSBmYWxzZTsKICAgICAgICBpZiAobmFtZSkgY2ZnRGlydHlbbmFtZV0gPSB0cnVlOwogICAgICAgIGlmIChu
;ZWVkSG9tZSkgewogICAgICAgICAgaWYgKG5hbWUpIHsKICAgICAgICAgICAgY2ZnQ2FjaGVbbmFtZV0gPSBudWxsOwogICAgICAgICAgICBjZmdEaXJ0eVtu
;YW1lXSA9IGZhbHNlOwogICAgICAgICAgfQogICAgICAgICAgaWYgKG5hbWUgJiYgbmFtZSA9PT0gY2ZnQWN0aXZlVGFiKSB7CiAgICAgICAgICAgIGlmIChj
;ZmdCb2R5KSBjZmdCb2R5LmlubmVySFRNTCA9ICc8ZGl2IGNsYXNzPSJjZmctZW1wdHkiPuW/hemhu+iuvue9rueOr+Wig+WPmOmHjyBIRUxQTUVfSE9NRSDm
;iY3og73or7vlhpnov5DooYzphY3nva48L2Rpdj4nOwogICAgICAgICAgICB1cGRhdGVDZmdQYXRoQmFyKCcnKTsKICAgICAgICAgICAgc3luY0NmZ1RpcFVp
;KCk7CiAgICAgICAgICB9CiAgICAgICAgfQogICAgICAgIHNldENmZ1N0YXR1cyhtc2cgfHwgJ+aTjeS9nOWksei0pScsICdlcnInKTsKICAgICAgICByZXR1
;cm47CiAgICAgIH0KICAgICAgY29uc3QgaXNTYXZlID0gL+W3suS/neWtmHzkv53lrZjmiJDlip8vLnRlc3QobXNnKTsKICAgICAgY29uc3QgaXNMb2FkID0g
;L+W3suWKoOi9vS8udGVzdChtc2cpOwogICAgICBpZiAoZGF0YS50ZXh0ICE9IG51bGwpIHsKICAgICAgICBjZmdDYWNoZVtuYW1lXSA9IHBhcnNlQWhrQ29u
;ZmlnVGV4dChTdHJpbmcoZGF0YS50ZXh0IHx8ICcnKSk7CiAgICAgICAgY2ZnRGlydHlbbmFtZV0gPSBmYWxzZTsKICAgICAgfQogICAgICBpZiAobmFtZSAm
;JiBuYW1lID09PSBjZmdBY3RpdmVUYWIpIHsKICAgICAgICBzeW5jQ2ZnVGlwVWkoKTsKICAgICAgICByZW5kZXJDb25maWdFZGl0b3IoKTsKICAgICAgICBp
;ZiAoY2ZnU2VhcmNoKSBhcHBseUNvbmZpZ1NlYXJjaChjZmdTZWFyY2gpOwogICAgICAgIHVwZGF0ZUNmZ1BhdGhCYXIoY2ZnUGF0aHNbbmFtZV0gfHwgJycp
;OwogICAgICB9CiAgICAgIGlmIChpc1NhdmUpIHsKICAgICAgICBjZmdBdXRvU2F2aW5nID0gZmFsc2U7CiAgICAgICAgaWYgKG5hbWUgPT09ICdzeXNjb25m
;aWcnKSB7CiAgICAgICAgICBzZXRDZmdTdGF0dXMobXNnLmluZGV4T2YoJ+S/neWtmOaIkOWKnycpID49IDAgPyAn5L+d5a2Y5oiQ5Yqf77yM5Y2z5bCG6YeN
;5ZCv6ISa5pys4oCmJyA6IChtc2cgfHwgJ+S/neWtmOaIkOWKnycpLCAnb2snKTsKICAgICAgICAgIHN5bmNDZmdTYXZlQnRuKCk7CiAgICAgICAgfSBlbHNl
;IHsKICAgICAgICAgIHNldENmZ1N0YXR1cyhtc2cuaW5kZXhPZign5L+d5a2Y5oiQ5YqfJykgPj0gMCA/ICflt7Loh6rliqjkv53lrZgnIDogKG1zZyB8fCAn
;5L+d5a2Y5oiQ5YqfJyksICdvaycpOwogICAgICAgIH0KICAgICAgfSBlbHNlIGlmIChpc0xvYWQpIHsKICAgICAgICBzZXRDZmdTdGF0dXMobXNnIHx8ICfl
;iqDovb3miJDlip8nLCAnaW5mbycpOwogICAgICAgIHN5bmNDZmdTYXZlQnRuKCk7CiAgICAgIH0gZWxzZSBpZiAobXNnKSBzZXRDZmdTdGF0dXMobXNnLCAn
;b2snKTsKICAgICAgaWYgKCFpc1NhdmUpIHN5bmNDZmdTYXZlQnRuKCk7CiAgICB9IGNhdGNoIChlKSB7CiAgICAgIGNvbnNvbGUud2Fybignc2V0QWhrQ29u
;ZmlnJywgZSk7CiAgICAgIHNldENmZ1N0YXR1cygn6Kej5p6Q5aSx6LSlOiAnICsgKGUgJiYgZS5tZXNzYWdlIHx8IGUpLCAnZXJyJyk7CiAgICB9CiAgfTsK
;ICB3aW5kb3cuX19zZXRDZmdJY29uID0gKHBheWxvYWQpID0+IHsKICAgIHRyeSB7CiAgICAgIGNvbnN0IGRhdGEgPSB0eXBlb2YgcGF5bG9hZCA9PT0gJ3N0
;cmluZycgPyBKU09OLnBhcnNlKHBheWxvYWQpIDogcGF5bG9hZDsKICAgICAgY29uc3QgcmVxSWQgPSBTdHJpbmcoZGF0YSAmJiBkYXRhLmlkIHx8ICcnKTsK
;ICAgICAgY29uc3Qga2luZCA9IFN0cmluZyhkYXRhICYmIGRhdGEua2luZCB8fCAnJyk7CiAgICAgIGNvbnN0IHBhdGggPSBTdHJpbmcoZGF0YSAmJiBkYXRh
;LnBhdGggfHwgJycpOwogICAgICBjb25zdCB1cmwgPSBTdHJpbmcoZGF0YSAmJiBkYXRhLnVybCB8fCAnJyk7CiAgICAgIGNmZ0ljb25DYWNoZS5zZXQoa2lu
;ZCArICd8JyArIHBhdGgsIHVybCk7CiAgICAgIGlmICghY2ZnQm9keSB8fCAhcmVxSWQpIHJldHVybjsKICAgICAgY29uc3QgZWwgPSBjZmdCb2R5LnF1ZXJ5
;U2VsZWN0b3IoJy5jZmctdmljb1tkYXRhLWljb24tcmVxPSInICsgcmVxSWQgKyAnIl0nKTsKICAgICAgaWYgKGVsKSBzZXRDZmdWaWNvKGVsLCBraW5kLCB1
;cmwpOwogICAgfSBjYXRjaCAoZSkgeyBjb25zb2xlLndhcm4oJ3NldENmZ0ljb24nLCBlKTsgfQogIH07CgogIC8vIOKUgOKUgCDkvJror53orrDlv4bvvJrp
;obXpnaIgLyDmkJzntKLor40gLyB0YWcgLyDnm5jnrKYgLyDphY3nva7nrZvpgInpobkg4pSA4pSACiAgY29uc3QgU0VTU0lPTl9LRVkgPSAnbG9jYWxfc2Vh
;cmNoX3Nlc3Npb25fdjEnOwogIGxldCBzZXNzaW9uUmVhZHkgPSBmYWxzZTsKICBsZXQgc2F2ZVNlc3Npb25UaW1lciA9IDA7CiAgZnVuY3Rpb24gY2FwdHVy
;ZVNlc3Npb24oKSB7CiAgICB0cnkgewogICAgICBpZiAoYXBwTW9kZSA9PT0gJ2ZpbGUnKSBtb2RlUXVlcnkuZmlsZSA9IFN0cmluZyhxRWwudmFsdWUgfHwg
;JycpOwogICAgICBlbHNlIGlmIChhcHBNb2RlID09PSAnaGFuZGxlJykgbW9kZVF1ZXJ5LmhhbmRsZSA9IFN0cmluZyhxRWwudmFsdWUgfHwgJycpOwogICAg
;ICBlbHNlIGlmIChhcHBNb2RlID09PSAnaW5mbycpIG1vZGVRdWVyeS5pbmZvID0gU3RyaW5nKHFFbC52YWx1ZSB8fCAnJyk7CiAgICAgIGVsc2UgaWYgKGFw
;cE1vZGUgPT09ICdjb25maWcnKSBtb2RlUXVlcnkuY29uZmlnID0gU3RyaW5nKHFFbC52YWx1ZSB8fCAnJyk7CiAgICB9IGNhdGNoIChfKSB7fQogICAgcmV0
;dXJuIHsKICAgICAgdjogMSwKICAgICAgYXBwTW9kZTogYXBwTW9kZSwKICAgICAgY2F0OiBjYXQsCiAgICAgIGRyaXZlOiBkcml2ZSwKICAgICAgc29ydDog
;c29ydCwKICAgICAgdGV4dFNlYXJjaE9uOiAhIXRleHRTZWFyY2hPbiwKICAgICAgbW9kZVF1ZXJ5OiB7CiAgICAgICAgZmlsZTogU3RyaW5nKG1vZGVRdWVy
;eS5maWxlIHx8ICcnKSwKICAgICAgICBoYW5kbGU6IFN0cmluZyhtb2RlUXVlcnkuaGFuZGxlIHx8ICcnKSwKICAgICAgICBpbmZvOiBTdHJpbmcobW9kZVF1
;ZXJ5LmluZm8gfHwgJycpLAogICAgICAgIGNvbmZpZzogU3RyaW5nKG1vZGVRdWVyeS5jb25maWcgfHwgJycpCiAgICAgIH0sCiAgICAgIGNmZ0FjdGl2ZVRh
;YjogY2ZnQWN0aXZlVGFiIHx8ICdydW5jb25maWcnLAogICAgICBjZmdTZWFyY2hTY29wZTogewogICAgICAgIGtleTogISEoY2ZnU2VhcmNoU2NvcGUgJiYg
;Y2ZnU2VhcmNoU2NvcGUua2V5KSwKICAgICAgICB2YWx1ZTogISEoY2ZnU2VhcmNoU2NvcGUgJiYgY2ZnU2VhcmNoU2NvcGUudmFsdWUpLAogICAgICAgIGVu
;YWJsZWQ6ICEhKGNmZ1NlYXJjaFNjb3BlICYmIGNmZ1NlYXJjaFNjb3BlLmVuYWJsZWQpLAogICAgICAgIGRpc2FibGVkOiAhIShjZmdTZWFyY2hTY29wZSAm
;JiBjZmdTZWFyY2hTY29wZS5kaXNhYmxlZCkKICAgICAgfSwKICAgICAgYWN0aXZlRmlsdGVySWRzOiBBcnJheS5mcm9tKGFjdGl2ZUZpbHRlcklkcyB8fCBb
;XSkKICAgIH07CiAgfQogIGZ1bmN0aW9uIHNhdmVTZXNzaW9uTm93KCkgewogICAgaWYgKCFzZXNzaW9uUmVhZHkpIHJldHVybjsKICAgIHRyeSB7IGxvY2Fs
;U3RvcmFnZS5zZXRJdGVtKFNFU1NJT05fS0VZLCBKU09OLnN0cmluZ2lmeShjYXB0dXJlU2Vzc2lvbigpKSk7IH0gY2F0Y2ggKF8pIHt9CiAgfQogIGZ1bmN0
;aW9uIHNhdmVTZXNzaW9uU29vbigpIHsKICAgIGlmICghc2Vzc2lvblJlYWR5KSByZXR1cm47CiAgICBjbGVhclRpbWVvdXQoc2F2ZVNlc3Npb25UaW1lcik7
;CiAgICBzYXZlU2Vzc2lvblRpbWVyID0gc2V0VGltZW91dChzYXZlU2Vzc2lvbk5vdywgMTgwKTsKICB9CiAgZnVuY3Rpb24gcmVzdG9yZVNlc3Npb24oKSB7
;CiAgICBsZXQgcyA9IG51bGw7CiAgICB0cnkgeyBzID0gSlNPTi5wYXJzZShsb2NhbFN0b3JhZ2UuZ2V0SXRlbShTRVNTSU9OX0tFWSkgfHwgJ251bGwnKTsg
;fSBjYXRjaCAoXykgeyBzID0gbnVsbDsgfQogICAgaWYgKCFzIHx8IHR5cGVvZiBzICE9PSAnb2JqZWN0JykgcmV0dXJuIGZhbHNlOwogICAgdHJ5IHsKICAg
;ICAgaWYgKHMubW9kZVF1ZXJ5ICYmIHR5cGVvZiBzLm1vZGVRdWVyeSA9PT0gJ29iamVjdCcpIHsKICAgICAgICBtb2RlUXVlcnkuZmlsZSA9IFN0cmluZyhz
;Lm1vZGVRdWVyeS5maWxlIHx8ICcnKTsKICAgICAgICBtb2RlUXVlcnkuaGFuZGxlID0gU3RyaW5nKHMubW9kZVF1ZXJ5LmhhbmRsZSB8fCAnJyk7CiAgICAg
;ICAgbW9kZVF1ZXJ5LmluZm8gPSBTdHJpbmcocy5tb2RlUXVlcnkuaW5mbyB8fCAnJyk7CiAgICAgICAgbW9kZVF1ZXJ5LmNvbmZpZyA9IFN0cmluZyhzLm1v
;ZGVRdWVyeS5jb25maWcgfHwgJycpOwogICAgICB9CiAgICAgIGlmICh0eXBlb2Ygcy5kcml2ZSA9PT0gJ3N0cmluZycpIGRyaXZlID0gcy5kcml2ZTsKICAg
;ICAgaWYgKHMuc29ydCAmJiB0eXBlb2Ygcy5zb3J0ID09PSAnc3RyaW5nJykgewogICAgICAgIHNvcnQgPSBzLnNvcnQ7CiAgICAgICAgY29uc3QgbWFwID0g
;ewogICAgICAgICAgJ2RhdGUtZGVzYyc6ICfmjInkv67mlLnml7bpl7TpmY3luo8nLAogICAgICAgICAgJ2RhdGUtYXNjJzogJ+aMieS/ruaUueaXtumXtOWN
;h+W6jycsCiAgICAgICAgICAnbmFtZS1hc2MnOiAn5oyJ5ZCN56ew5Y2H5bqPJywKICAgICAgICAgICdzaXplLWRlc2MnOiAn5oyJ5aSn5bCP6ZmN5bqPJwog
;ICAgICAgIH07CiAgICAgICAgaWYgKHNvcnRMYWJlbCkgc29ydExhYmVsLnRleHRDb250ZW50ID0gbWFwW3NvcnRdIHx8IHNvcnQ7CiAgICAgIH0KICAgICAg
;aWYgKHR5cGVvZiBzLnRleHRTZWFyY2hPbiA9PT0gJ2Jvb2xlYW4nKSB7CiAgICAgICAgdGV4dFNlYXJjaE9uID0gISFzLnRleHRTZWFyY2hPbjsKICAgICAg
;ICBpZiAoY2hrUHJldmlldykgY2hrUHJldmlldy5jaGVja2VkID0gdGV4dFNlYXJjaE9uOwogICAgICAgIGlmIChwcmV2aWV3KSBwcmV2aWV3LmNsYXNzTGlz
;dC50b2dnbGUoJ29mZicsICF0ZXh0U2VhcmNoT24pOwogICAgICAgIGlmIChxRWwgJiYgYXBwTW9kZSA9PT0gJ2ZpbGUnKSB7CiAgICAgICAgICBxRWwucGxh
;Y2Vob2xkZXIgPSB0ZXh0U2VhcmNoT24KICAgICAgICAgICAgPyAn6L6T5YWl6KaB5pCc57Si55qE5paH5pys5YaF5a6577ybfCDooajnpLrkuJTvvIx8fCDo
;oajnpLrmiJYnCiAgICAgICAgICAgIDogUExBQ0VIT0xERVJfRklMRTsKICAgICAgICB9CiAgICAgIH0gZWxzZSB7CiAgICAgICAgLy8g5pen54mIIHByZXZp
;ZXdPbiDmmK/jgIzmlofku7bpooTop4jjgI3vvIzkuI3og73lvZPmiJDjgIzmkJzntKLmlofmnKzjgI0KICAgICAgICB0ZXh0U2VhcmNoT24gPSBmYWxzZTsK
;ICAgICAgICBpZiAoY2hrUHJldmlldykgY2hrUHJldmlldy5jaGVja2VkID0gZmFsc2U7CiAgICAgICAgaWYgKHByZXZpZXcpIHByZXZpZXcuY2xhc3NMaXN0
;LmFkZCgnb2ZmJyk7CiAgICAgIH0KICAgICAgaWYgKHMuY2ZnQWN0aXZlVGFiICYmIHR5cGVvZiBzLmNmZ0FjdGl2ZVRhYiA9PT0gJ3N0cmluZycpIGNmZ0Fj
;dGl2ZVRhYiA9IHMuY2ZnQWN0aXZlVGFiOwogICAgICBpZiAocy5jZmdTZWFyY2hTY29wZSAmJiB0eXBlb2Ygcy5jZmdTZWFyY2hTY29wZSA9PT0gJ29iamVj
;dCcpIHsKICAgICAgICBjZmdTZWFyY2hTY29wZS5rZXkgPSAhIXMuY2ZnU2VhcmNoU2NvcGUua2V5OwogICAgICAgIGNmZ1NlYXJjaFNjb3BlLnZhbHVlID0g
;ISFzLmNmZ1NlYXJjaFNjb3BlLnZhbHVlOwogICAgICAgIGNmZ1NlYXJjaFNjb3BlLmVuYWJsZWQgPSAhIXMuY2ZnU2VhcmNoU2NvcGUuZW5hYmxlZDsKICAg
;ICAgICBjZmdTZWFyY2hTY29wZS5kaXNhYmxlZCA9ICEhcy5jZmdTZWFyY2hTY29wZS5kaXNhYmxlZDsKICAgICAgfQogICAgICBpZiAoQXJyYXkuaXNBcnJh
;eShzLmFjdGl2ZUZpbHRlcklkcykpIHsKICAgICAgICBhY3RpdmVGaWx0ZXJJZHMgPSBuZXcgU2V0KHMuYWN0aXZlRmlsdGVySWRzLm1hcChTdHJpbmcpKTsK
;ICAgICAgICB0cnkgeyBzYXZlQWN0aXZlRmlsdGVycygpOyB9IGNhdGNoIChfKSB7fQogICAgICAgIHRyeSB7IHJlbmRlckZpbHRlckJhcigpOyB9IGNhdGNo
;IChfKSB7fQogICAgICB9CiAgICAgIGlmIChzLmNhdCAmJiB0eXBlb2Ygcy5jYXQgPT09ICdzdHJpbmcnICYmIHMuY2F0LmluZGV4T2YoJ19fJykgIT09IDAp
;IGNhdCA9IHMuY2F0OwogICAgICB0cnkgeyBzeW5jRHJpdmVCdXR0b24oKTsgcmVuZGVyRHJpdmVNZW51KCk7IH0gY2F0Y2ggKF8pIHt9CgogICAgICBjb25z
;dCBtb2RlID0gKHMuYXBwTW9kZSA9PT0gJ2hhbmRsZScgfHwgcy5hcHBNb2RlID09PSAnaW5mbycgfHwgcy5hcHBNb2RlID09PSAnY29uZmlnJykKICAgICAg
;ICA/IHMuYXBwTW9kZSA6ICdmaWxlJzsKICAgICAgZG9jdW1lbnQucXVlcnlTZWxlY3RvckFsbCgnLmNhdCcpLmZvckVhY2goYiA9PiB7CiAgICAgICAgY29u
;c3QgYyA9IGIuZGF0YXNldC5jYXQ7CiAgICAgICAgbGV0IG9uID0gZmFsc2U7CiAgICAgICAgaWYgKG1vZGUgPT09ICdoYW5kbGUnKSBvbiA9IGMgPT09ICdf
;X2hhbmRsZSc7CiAgICAgICAgZWxzZSBpZiAobW9kZSA9PT0gJ2luZm8nKSBvbiA9IGMgPT09ICdfX2luZm8nOwogICAgICAgIGVsc2UgaWYgKG1vZGUgPT09
;ICdjb25maWcnKSBvbiA9IGMgPT09ICdfX2NvbmZpZyc7CiAgICAgICAgZWxzZSBvbiA9IGMgPT09IGNhdDsKICAgICAgICBiLmNsYXNzTGlzdC50b2dnbGUo
;J29uJywgISFvbik7CiAgICAgIH0pOwogICAgICBzZXRBcHBNb2RlKG1vZGUpOwogICAgICBpZiAobW9kZSA9PT0gJ2ZpbGUnKSB7CiAgICAgICAgcUVsLnZh
;bHVlID0gbW9kZVF1ZXJ5LmZpbGUgfHwgJyc7CiAgICAgICAgc3luY0NsZWFyQnRuKCk7CiAgICAgICAgZG9TZWFyY2goKTsKICAgICAgfSBlbHNlIGlmICht
;b2RlID09PSAnY29uZmlnJykgewogICAgICAgIHRyeSB7IHN5bmNDZmdTZWFyY2hDaHJvbWUoKTsgfSBjYXRjaCAoXykge30KICAgICAgfQogICAgICByZXR1
;cm4gdHJ1ZTsKICAgIH0gY2F0Y2ggKGUpIHsKICAgICAgY29uc29sZS53YXJuKCdyZXN0b3JlU2Vzc2lvbicsIGUpOwogICAgICByZXR1cm4gZmFsc2U7CiAg
;ICB9CiAgfQoKICByZXN0b3JlU2Vzc2lvbigpOwogIHNlc3Npb25SZWFkeSA9IHRydWU7CiAgdHJ5IHsgc3luY1RpdGxlUmFpbE1vZGUoKTsgfSBjYXRjaCAo
;Xykge30KICBpZiAoYXBwUm9vdCAmJiAhYXBwUm9vdC5jbGFzc0xpc3QuY29udGFpbnMoJ3JhaWwtZmlsZScpCiAgICAgICYmICFhcHBSb290LmNsYXNzTGlz
;dC5jb250YWlucygncmFpbC1oYW5kbGUnKQogICAgICAmJiAhYXBwUm9vdC5jbGFzc0xpc3QuY29udGFpbnMoJ3JhaWwtY29uZmlnJykKICAgICAgJiYgYXBw
;TW9kZSAhPT0gJ2luZm8nKSB7CiAgICB0cnkgeyBzeW5jVGl0bGVSYWlsTW9kZSgpOyB9IGNhdGNoIChfKSB7fQogIH0KICBzYXZlU2Vzc2lvbk5vdygpOwog
;IHRyeSB7IHBvc3QoJ3Nlc3Npb25Nb2RlfCcgKyAoYXBwTW9kZSB8fCAnZmlsZScpKTsgfSBjYXRjaCAoXykge30KICB3aW5kb3cuYWRkRXZlbnRMaXN0ZW5l
;cigncGFnZWhpZGUnLCAoKSA9PiB7IHRyeSB7IGZsdXNoQ2ZnQXV0b1NhdmUoKTsgfSBjYXRjaCAoXykge30gc2F2ZVNlc3Npb25Ob3coKTsgfSk7CiAgd2lu
;ZG93LmFkZEV2ZW50TGlzdGVuZXIoJ2JlZm9yZXVubG9hZCcsICgpID0+IHsgdHJ5IHsgZmx1c2hDZmdBdXRvU2F2ZSgpOyB9IGNhdGNoIChfKSB7fSBzYXZl
;U2Vzc2lvbk5vdygpOyB9KTsKICBkb2N1bWVudC5hZGRFdmVudExpc3RlbmVyKCd2aXNpYmlsaXR5Y2hhbmdlJywgKCkgPT4gewogICAgaWYgKGRvY3VtZW50
;LnZpc2liaWxpdHlTdGF0ZSA9PT0gJ2hpZGRlbicpIHsKICAgICAgdHJ5IHsgZmx1c2hDZmdBdXRvU2F2ZSgpOyB9IGNhdGNoIChfKSB7fQogICAgICBzYXZl
;U2Vzc2lvbk5vdygpOwogICAgfQogIH0pOwoKICBwb3N0KCd1aVJlYWR5fCcgKyAoYXBwTW9kZSB8fCAnZmlsZScpKTsKICB3aW5kb3cuX19yZXN5bmNTZWFy
;Y2ggPSAoKSA9PiB7CiAgICB0cnkgewogICAgICBpZiAodHlwZW9mIGFwcE1vZGUgIT09ICd1bmRlZmluZWQnICYmIGFwcE1vZGUgIT09ICdmaWxlJykgcmV0
;dXJuOwogICAgICBkb1NlYXJjaCgpOwogICAgfSBjYXRjaCAoXykge30KICB9OwogIC8vIOi/m+WFpeaXtuiLpeW3suaciemAieS4reetm+mAie+8jOS4u+WK
;qOW4puadoeS7tuaQnOe0ou+8iOimhuebliBBSEsg56m65p+l6K+i77yJCiAgc2V0VGltZW91dCgoKSA9PiB7IHRyeSB7IHdpbmRvdy5fX3Jlc3luY1NlYXJj
;aCgpOyB9IGNhdGNoIChfKSB7fSB9LCAyODApOwogIHNldFRpbWVvdXQoKCkgPT4geyB0cnkgeyB3aW5kb3cuX19yZXN5bmNTZWFyY2goKTsgfSBjYXRjaCAo
;Xykge30gfSwgOTAwKTsKfSkoKTsKPC9zY3JpcHQ+CjwvYm9keT4KPC9odG1sPgo=
;########################################################################################################### local_search_index.html

;########################################################################################################### emoji.txt
;IyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMNCiMgYWhr55qE44CQ6KGo5oOF6YWN572u44CRDQojIGtleT3lhbPplK7lrZfvvIx2YWx1ZT3ooajmg4XmnKzouqvvvIjkvovlpoIg6J6D6J+5PfCfpoDvvIkNCiMg5YiG57uE55SoICMjIyMjIyMjIyMjI+OAkOe7hOWQjeOAke+8mycjJyDku6Pooajms6jph4oNCiMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjDQoNCg0KIyMjIyMjIyMjIyMj44CQ8J+ko+W4uOeUqOOAkQ0K6Z2S6JuZPfCfkLgNCuibhz3wn5CNDQrniIbnrJHnrJHlvpflnKjlnLDmnb/kuIrmiZPmu5o98J+kow0K5ouJ54Ku5b2p5bim5by55oGt5Zac5aSn5Zac5LqL5bqG56Wd5oiQ5YqfPfCfjokNCueBq+eureS4gOmjnuWGsuWkqei1t+mjnua2qOWBnD3wn5qADQrpnLjnjovpvpkg5oGQ6b6ZPfCfppYNCuicpeiEmuexu+aBkOm+mT3wn6aVDQrlnLDnkIM98J+Mjw0KDQojIyMjIyMjIyMjIyPjgJDwn5iA6KGo5oOF44CRDQrmoIflh4bnrJHohLjnpLzosozlvq7nrJHooajovr7lj4vlpb098J+YgA0K5aSn56yR55yf6K+a5byA5b+D5b+D5oOF5aW9PfCfmIQNCumcsum9v+eskeiwg+earuW+l+aEj+mcsum9v+Wkp+eskT3wn5iBDQrnnK/nnLznrJHlk4jlk4jlpKfnrJHmnoHluqblvIDlv4M98J+Yhg0K5rGX6aKc56yR5bC05bCs5Y+I5LiN5aSx56S86LKM55qE5b6u56yR6Jma5oOK5LiA5Zy6PfCfmIUNCueskeWTreS6hueskeWIsOmjmeazquaegeWFtuaQnueskT3wn5iCDQrniIbnrJHnrJHlvpflnKjlnLDmnb/kuIrmiZPmu5o98J+kow0K5bim5rOq5b6u56yR56C06Ziy5LqG5by66aKc5qyi56yR6Ium5Lit5L2c5LmQPfCfpbINCua4qeWSjOW+rueskeWus+e+nua4qeaaluWQq+iThD3imLrvuI8NCueUnOe+juW+rueskeW8gOW/g+a7oei2s+ihqOi+vuWWhOaEjz3wn5iKDQrlpKnkvb/nrJHkuZblt6flgYfoo4Xml6DovpzlgZrlloTkuos98J+Yhw0K5b6u56yR552A56S86LKM5pyJ5pe25bim54K56Zi06Ziz5oCq5rCU5oiW5peg5aWIPfCfmYINCuWAkuiEuOaXoOWliOmYtOmYs+aAquawlOWPkeeWr+aRhueDgj3wn5mDDQrnnKjnnLzlvIDnjqnnrJHlv4PnhafkuI3lrqPmipvlqprnnLw98J+YiQ0K6YeK5oCA5p2+5LqG5LiA5Y+j5rCU5a6J5b+D5YaF5b+D5bmz6Z2ZPfCfmIwNCue6ouW/g+ecvOiKseeXtOaegeW6puWWnOasouW/g+WKqD3wn5iNDQrmu6HohLjniLHlv4PooqvmuKnmmpbliLDmsonmtbjlnKjniLHmhI/kuK098J+lsA0K5ZC554ix5b+D6YCB5LiK5Lqy5Lqy6KGo6L6+5Zac54ixPfCfmJgNCuS6suS6suWYn+WYtOS6suS6sue6r+a0geeahOeIsT3wn5iXDQrlvq7nrJHkurLkurLlvIDlv4PkuJTkurLmmLU98J+YmQ0K6Zet55y85Lqy5Lqy5rex5oOF5oiW5rip5p+U55qE5Lqy5LqyPfCfmJoNCuWQkOiIjOWktOWlveWQg+mmi+S6huiwg+earj3wn5iLDQrlkJDoiIznuq/nsrnmiZPotqPmkJ7nrJE98J+Ymw0K55yo55y85ZCQ6IiM5o2J5byE5Lq65ruR56i9546p6Ze5PfCfmJwNCueWr+eLguiEuOeOqeWXqOS6huWPkeeWr+aQnuaAqj3wn6SqDQrnnK/nnLzlkJDoiIzlvIDnjqnnrJHmgbbkvZzliafmiJDlip898J+YnQ0K5Y+R6LSi55y855yL5Yiw6ZKx5LqG5oOz6LWa6ZKx6LSi6L+3PfCfpJENCui/veaYn+ecvOW0h+aLnOaDiuWPueecvOmHjOacieaYn+i+sOWkp+a1tz3wn6SpDQrmiLTmtL7lr7nluL3luobnpZ3ov4fnlJ/ml6Xni4LmrKI98J+lsw0K5omY6IWu5oCd6ICD6K6p5oiR5oOz5oOz5oCA55aR55Ci56OoPfCfpJQNCuaMkeecieihqOekuuaAgOeWkeS4jeS/oeecn+WBh+eahD3wn6SoDQrljZXniYfnnLzplZzku5Tnu4bnoJTnqbbogIPlr5/lj5HnjrDnjKvohbs98J+nkA0K55y86ZWc5aa55ZOl5a2m6Zy45p6B5a6i6KOF5oeCPfCfpJMNCuaItOWiqOmVnOijhemFt+a9h+a0kueos+S6hj3wn5iODQrkvKroo4Xoo4Xmia7kuZToo4XmiZPmia7mmpfkuK3op4Llr5898J+luA0K5Z2P56yR55yL56C05LiN6K+056C05Yu+5byV5YaF5ra1PfCfmI8NCuS4jeeIvee/u+eZveecvOWrjOW8g+S4jeW8gOW/gz3wn5iSDQrnv7vnmb3nnLzml6Dor63ml6DogYrmh5LlvpfnkIbkvaA98J+ZhA0K5ZKs54mZ5bC05bCs5o2P5LiA5oqK5rGX5aSn5LqL5LiN5aaZPfCfmKwNCumVv+m8u+WtkOWMueivuuabueaSkuiwjuivtOWBh+ivnT3wn6SlDQrpnaLml6Dooajmg4XlhrfmvKDml6Dor53lj6/or7Q98J+YkA0K6Zet55y85peg6K+t5b275bqV5rKh6IS+5rCU5peg6K+t6Iez5p6BPfCfmJENCuaXoOWYtOS/neaMgeayiem7mOaXoOWPr+WlieWRij3wn5i2DQromZrnur/ohLjpmpDouqvmsqHmnInlrZjlnKjmhJ/mg7PmtojlpLE98J+rpQ0K5LqR6Zu+6IS46L+36Iyr6LWw56We6ISR5a2Q5LiA54mH56m655m9PfCfmLbigI3wn4yr77iPDQrlj7nmsJTml6DlpYjntK/kuobmnb7kuIDlj6PmsJQ98J+YruKAjfCfkqgNCuaLiemTvuWYtOS/neWvhumXreWYtOe7neS4jeivtOa8j+WYtD3wn6SQDQrmsarmsarlpKfnnLzlj6/mgJzlt7Tlt7TmsYLmsYLkvaDkuobmhJ/liqg98J+lug0K5ZCr5rOq5oSf5Yqo6JC95rOq5by65b+N5rOq5rC0PfCfpbkNCuWwj+W8gOWYtOaEn+WIsOaEj+WkluWQg+aDij3wn5imDQrmg4rmgZDkuovmg4XkuI3lr7nlirLmi4Xlv6c98J+Ypw0K5Ya35rGX5ZCT5Ye65LiA6Lqr5Ya35rGXPfCfk4ENCueEpuiZkeWGt+axl+aFjOW8oOe0p+W8oOaegeS6hj3wn5iwDQrlpLHmnJvmsZfomZrmg4rkuIDlnLrkvYbku43lvojmsq7kuKc98J+YpQ0K5rWB5rOq6Zq+6L+H5aeU5bGI5b+D56KOPfCfmKINCuWkp+WTreWTh+WTh+Wkp+WTreaegeW6puW0qea6gz3wn5itDQrlsJblj6vlkJPmrbvkurrkuobpnIfmg4rmnoHkuoY98J+YsQ0K55eb6Ium57qg57uT6Zq+5Lul5b+N5Y+XPfCfmJYNCuW/jeiAkOWSrOeJmeWdmuaMgeeXm+iLpj3wn5ijDQrmsq7kuKflnoLlpLTkuKfmsJTlpLHokL098J+Yng0K5Ya35rGX5rGX5bel5L2c57Sv5LqG5Y6L5Yqb5aSnPfCfmJMNCueWsuaDq+e0r+WeruS6huW/q+aSkeS4jeS9j+S6hj3wn5ipDQrmipPni4Lnl5voi6blj6vllorlj5flpJ/kuoY98J+Yqw0K5omT5ZOI5qyg5Zuw5LqG5peg6IGK5oOz552h6KeJPfCfpbENCuWTvOawlOWCsuWoh+iDnOWIqeS4jeacjeawlD3wn5ikDQrnlJ/msJTlj5HmgJLmhKTmgJI98J+YoQ0K6aOZ6ISP6K+d5rCU5Yiw6aqC5Lq65pq05oCSPfCfpKwNCuWktOiEkeeCuOijgumioOimhuiupOefpeinguaYj+Wkqumch+aSvOS6hj3wn6SvDQrohLjnuqLlrrPnvp7kuI3lpb3mhI/mgJ3ooqvlkJPliLA98J+Ysw0K5Y+R54Ot5aSq54Ot5LqG6KKr5biF5Yiw576O5Yiw5Y+R54OrPfCfpbUNCuWPkeWGu+WGu+WDteS6huWGt+mFt+iiq+WQk+WGtz3wn6W2DQrono3ljJbng63niIbkuoblsLTlsKzlvpfmg7PpkrvlnLDnvJ3mkYbng4I98J+roA0K5oG25b+D5Y+N6IOD5oOz5ZCQ6IaI5bqUPfCfpKINCuWRleWQkOWQkOS6huaegeWFtuWPjeaEnz3wn6SuDQrmiZPllrflmo/mhJ/lhpLkuobov4fmlY898J+kpw0K6YeP5L2T5rip55Sf55eF5Y+R54On5Y+R54On5LitPfCfpJINCuWMheaJjuWktOWPl+S8pOS6huaMqOaJk+S6hj3wn6SVDQrlkKzkuI3muIXmsqHlkKzmuIXkvaDor7TllaU98J+njw0K552h6KeJ552h552A5LqG5Zuw5YCmPfCfmLQNCuaZleWktOi9rOWQkeaZleS6huaHteWciD3wn5i1DQronrrml4vnnLzooqvlgqznnKDkuobmnoHluqbmt7fkubE98J+YteKAjfCfkqsNCuWwj+S4keiHquWYsuWwj+S4keern+aYr+aIkeiHquW3sT3wn6ShDQroiKzoi6XmgbbprZTml6XmnKzmgbbprZTlh7bni6A98J+RuQ0K5aSp54uX5YKy5oWi55Sf5rCUPfCfkboNCuW5veeBtemsvOmtguW8gOeOqeeskeijhemsvD3wn5G7DQrlpJbmmJ/kurrlpYfokanohJHlm57ot6/muIXlpYc98J+RvQ0K5py65Zmo5Lq65py65qKw5YyW5q275p2/PfCfpJYNCuS+v+S+v+aQnueskei/kOWKv+Wxjui/kD3wn5KpDQoNCiMjIyMjIyMjIyMjI+OAkPCfkY3miYvlir/lkozluobnpZ3jgJENCuerluWkp+aLh+aMh+eCuei1nui1nuWQjOayoemXrumimOajkj3wn5GNDQrmi4fmjIflkJHkuIvlt67or4Tlj43lr7nkuI3ooYzouKk98J+Rjg0K6byT5o6M5ZWq5ZWq5ZWq6byT5o6M56Wd6LS657K+5b2pPfCfkY8NCuS4vuWPjOaJi+asouWRvOW6huelneWkquajkuS6huS4h+WygT3wn5mMDQrlvKDlvIDlj4zmiYvmi6XmirHlnabor5rlsZXnpLo98J+RkA0K5Y+M5o6M5ZCR5LiK56WI56W35o6l5pS256WI5rGCPfCfpLINCuaPoeaJi+WQiOS9nOaEieW/q+aIkOS6pOasoui/jui+vuaIkOWFseivhj3wn6SdDQrlh7rmi7PliqDmsrnmiZPmsJTlipvph4898J+Rig0K5o+h5ouz5Z2a5oyB5Yqg5rK55Y+N5oqX5Zui57uTPeKcig0K5bem5Yay5ouz5a+55ouz5omT5oub5ZG856Kw5ouzPfCfpJsNCuWPs+WGsuaLs+WvueaLs+WbnuW6lOe7hOWQiOS9v+eUqD3wn6ScDQrkuqTlj4nmiYvmjIfnpYjnpbflpb3ov5DorrjmhL9GaW5nZXJzY3Jvc3NlZD3wn6SeDQrliarliIDmiYvog5zliKnogLbog5zliKnmi43nhafnu4/lhbjlp7/lir894pyM77iPDQrniLHkvaDnmoTmiYvlir/mkYfmu5pJTG92ZVlvdeWkp+aLh+aMh+mjn+aMh+Wwj+aLh+aMh+W8oOW8gD3wn6SfDQrmkYfmu5rmiYvlir/mnIvlhYvph5HlsZ7ll6jotbfmnaXlj6rlvKDlvIDpo5/mjIflkozlsI/mi4fmjIc98J+kmA0K5o2P5omL5oyH5oSP5byP5omL5Yq/6KGo6L6+5L2g5oOz5oCO5qC35L2g5Zyo6K+05LuA5LmIPfCfpIwNCuaNj+S4gOeCueeCueS4gOeCueeCueW+ruWwj+WwseW3ruS4gOeCuT3wn6SPDQpPS+aJi+WKv+ayoemXrumimOWPr+S7pei1nuWQjD3wn5GMDQrlvKDlvIDkupTmjIflgZzmraI15Ye75o6MPfCflpDvuI8NCuS4vuaJi+WPkeiogOaPkOmXruaLkue7nT3inIsNCuaJi+iDjOacneWkluaMoeS9j+aLkue7neWBnOS4iz3wn6SaDQrmjKXmiYvkvaDlpb3lho3op4HmiZPmi5vlkbw98J+Riw0K5omT55S16K+dNjY26IGU57O75oiR6YW3NjY25aSP5aiB5aS36Zi/572X5ZOI5omL5Yq/PfCfpJkNCuaMh+WQkeWPs+W+gOWPs+eci+aOqOiNkOeCueWHu+i/memHjD3wn5GJDQrmjIflkJHlt6blvoDlt6bnnIvms6jmhI/ov5novrk98J+RiA0K5oyH5ZCR5L6n5LiK5b6A5LiK55yL55yL5LiK6Z2iPfCfkYYNCuaMh+WQkeS4i+W+gOS4i+eci+eci+ivhOiuuuWMuumZhOWbvj3wn5GHDQrnq5bpo5/mjIfms6jmhI/nrKwx562J5LiA5LiLPeKYne+4jw0K5oyH552A5L2g5bCx5piv5L2g5L2g5by654OI55qE5a+56LGh5oSfPfCfq7UNCuWGmeWtl+iusOeslOiusOWGmeS9nOS4muetvue9sj3inI3vuI8NCuiHquaLjeaLjeeFp+WPkeaci+WPi+WciOiHquaLjT3wn6SzDQrlkIjljYHnpYjnpbfmi5zmiZjmhJ/osKLnpYjnpbflubPlronkuZ/luLjkvZzkuLrosKLosKLkvb/nlKg98J+Zjw0K6Z6g6Lqs6YGT5q2J5oSf6LCi6Z2e5bi45oqx5q2JPfCfmYcNCueUtz3wn5mH4oCN4pmC77iPDQrlpbM98J+Zh+KAjeKZgO+4jw0K6IC46IKp5LiN55+l6YGT5peg5omA6LCT6ZqP5L6/5ZCnPfCfpLcNCueUt18yPfCfpLfigI3imYLvuI8NCuWls18yPfCfpLfigI3imYDvuI8NCuaNguiEuOaXoOivreayoeecvOeci+W0qea6gz3wn6SmDQrnlLdfMz3wn6Sm4oCN4pmC77iPDQrlpbNfMz3wn6Sm4oCN4pmA77iPDQrmtL7lr7nohLjov4fnlJ/ml6Xni4LmrKLll6jotbfmnaU98J+lsw0K5b2p55CD56KO6Iqx55CD5byA5Lia6IqC5bqG5aSn5ZCJ5aSn5YipPfCfjooNCuawlOeQg+eUn+aXpea0vuWvuea0u+WKqOijheaJrj3wn46IDQrnlJ/ml6Xom4vns5Xov4fnlJ/ml6XorrjmhL9IYXBweUJpcnRoZGF5PfCfjoINCuWIh+Wdl+ibi+ezleWQg+eUnOWTgeW6huelneWwj+ehruW5uD3wn42wDQrpppnmp5/lvIDpppnmp5/luobnpZ3og5zliKnpq5jnuqfmtL7lr7k98J+Nvg0K57qi6YWS56Kw5p2v5LyY6ZuF57qm5Lya5b6u6Ya6PfCfjbcNCum4oeWwvumFkumFkuWQp+WknOeUn+a0u+aUvuadvj3wn424DQrllaTphZLlubLmna/ogZrppJDlpJzluILng6fng6Q98J+Nug0K5ouJ54Ku5b2p5bim5by55oGt5Zac5aSn5Zac5LqL5bqG56Wd5oiQ5YqfPfCfjokNCueisOadr+W5suadr+elnei0uuaci+WPi+iBmuS8mj3wn427DQrng5/oirHmlrDlubTot6jlubTlpKflnovnm5vlhbg98J+Ohg0K57q/6aaZ6Iqx54Gr5omL5oyB54Of6Iqx5rWq5ryr5aSP5aSc5bqG5YW4PfCfjocNCue6ouWMhei/h+W5tOWPkee6ouWMheaBreWWnOWPkei0oj3wn6enDQrnuqLnga/nrLzlhYPlrrXoioLkuK3np4voioLkuK3lm73po4498J+Prg0K5Zyj6K+e5qCR5Zyj6K+e6IqC5Yas5pel54uC5qyiPfCfjoQNCuS4h+Wco+iKguWNl+eTnOS4h+Wco+iKguaQnuaAquS4jee7meezluWwseaNo+S5sT3wn46DDQrpu4TkuJ3luKbnpYjnpo/mgIDlv7XmlK/mjIE98J+Ol++4jw0K8J+On++4jz3wn46f77iPDQrpl6jnpajlvannpajnnIvmvJTllLHkvJrkuK3lpZbnnIvnlLXlvbE98J+Oqw0KDQojIyMjIyMjIyMjIyPjgJDwn5CI5Yqo54mp44CRDQronoPon7k98J+mgA0K6b6Z6Jm+PfCfpp4NCumynOiZvj3wn6aQDQrkuYzotLzpsb/psbw98J+mkQ0K56ug6bG8PfCfkJkNCumxvD3wn5CfDQrng63luKbpsbw98J+QoA0K5Yi66LGaPfCfkKENCumyqOmxvD3wn6aIDQrmtbfosZo98J+QrA0K5Za35rC06bK46bG8PfCfkLMNCumyuOmxvD3wn5CLDQrmtbfosbk98J+mrQ0K54uX5aS0PfCfkLYNCueLlz3wn5CVDQrnjKvlpLQ98J+QsQ0K54yrPfCfkIgNCum8oOWktD3wn5CtDQrpvKA98J+QgQ0K5LuT6bygPfCfkLkNCuWFlOWktD3wn5CwDQrlhZTlrZA98J+Qhw0K54uQ54u4PfCfpooNCueGij3wn5C7DQrnhornjKs98J+QvA0K5rW35rWqPfCfjIoNCuiAg+aLiT3wn5CoDQromY7lpLQ98J+Qrw0K6ICB6JmOPfCfkIUNCueLruWtkD3wn6aBDQrniZvlpLQ98J+Qrg0K5aW254mbPfCfkIQNCueMquWktD3wn5C3DQrnjKo98J+Qlg0K54y05aS0PfCfkLUNCueMtOWtkD3wn5CSDQrpqazlpLQ98J+QtA0K5Yy56amsPfCfkI4NCuWkp+ixoT3wn5CYDQrnioDniZs98J+mjw0K5rKz6amsPfCfppsNCumVv+miiOm5v+eLvD3wn6aSDQrwn5C6PfCfkLoNCua1o+eGij3wn6adDQroh63pvKw98J+mqA0K5qCR5oeSPfCfpqUNCuawtOeNrT3wn6amDQrooovpvKA98J+mmA0K6bih5aS0PfCfkJQNCuWFrOm4oT3wn5CTDQrlrbXlsI/puKE98J+QpQ0K5bCP6bihPfCfkKQNCum4reWtkD3wn6aGDQrpubA98J+mhQ0K6biu54yr5aS06bmwPfCfpokNCum5pum5iT3wn6acDQrngavng4jpuJ898J+mqQ0K5LyB6bmFPfCfkKcNCum4veWtkD3wn5WK77iPDQronJzonII98J+QnQ0K5q+b5q+b6JmrPfCfkJsNCuidtOidtj3wn6aLDQronJfniZs98J+QjA0K55Oi6JmrPfCfkJ4NCuiaguiagT3wn5CcDQronJjom5s98J+Vt++4jw0K5LmM6b6fPfCfkKINCuibhz3wn5CNDQronKXonLQ98J+mjg0K6bOE6bG8PfCfkIoNCumdkuibmT3wn5C4DQrlpKfnjKnnjKk98J+mjQ0K57qi5q+b54yp54ypPfCfpqcNCuWvvOebsueKrD3wn6auDQrmnI3liqHniqw98J+mug0K6LS15a6+54qsPfCfkKkNCum7keeMqz3irJsNCuixueWtkD3wn5CGDQrni6zop5Llhb098J+mhA0K5paR6amsPfCfppMNCum5vz3wn6aMDQrph47niZs98J+mrA0K5YWs54mbPfCfkIINCuawtOeJmz3wn5CDDQrph47njKo98J+Qlw0K54yq6by75a2QPfCfkL0NCuWFrOe+ij3wn5CPDQrnu7Xnvoo98J+QkQ0K5bGx576KPfCfkJANCuWNleWzsOmqhumpvD3wn5CqDQrlj4zls7Dpqobpqbw98J+Qqw0K576O5rSy6am8PfCfppkNCueMm+eKuOixoT3wn6ajDQrogJflrZA98J+QgA0K5p2+6bygPfCfkL/vuI8NCua1t+eLuD3wn6arDQrliLrnjKw98J+mlA0K6J2Z6J2gPfCfpocNCuWMl+aegeeGij3wn5C74oCN4p2E77iPDQrnjb498J+moQ0K54iq5Y2wPfCfkL4NCuWwj+m4oeegtOWjsz3wn5CjDQrpuJ898J+Qpg0K5aSp6bmFPfCfpqINCua4oea4oem4nz3wn6akDQrnvr3mr5s98J+qtg0K5a2U6ZuAPfCfppoNCueBq+m4oT3wn6aDDQrpuYU98J+qvw0K57+F6IaAPfCfqr0NCum+meWktD3wn5CyDQrpvpk98J+QiQ0K6Jyl6ISa57G75oGQ6b6ZPfCfppUNCumcuOeOi+m+mT3wn6aWDQrmtbfonro98J+Qmg0K54+K55GaPfCfqrgNCueJoeibjj3wn6aqDQrmsLTmr4098J+qvA0K55Sy6JmrPfCfqrINCuifi+ifgD3wn6aXDQron5HonoI98J+qsw0K6JyY6Jub572RPfCflbjvuI8NCuidjuWtkD3wn6aCDQromorlrZA98J+mnw0K6IuN6J2HPfCfqrANCuigleiZqz3wn6qxDQoNCiMjIyMjIyMjIyMjI+OAkPCfjLTmpI3nianjgJENCuWPkeiKveaWsOiKveaWsOeUn+WImuW8gOWni+W4jOacmz3wn4yxDQroja/ojYnojYnmnKzlpKnnhLbmnInmnLrojYnoja/muIXmlrA98J+Mvw0K5LiJ5Y+26I2J5bm46L+Q54ix5bCU5YWw57u/6ImyPeKYmO+4jw0K5Zub5Y+26I2J5p6B5bqm5bm46L+Q5aW96L+Q6L+e6L+ePfCfjYANCuebhuagveWupOWGhee7v+akjeWxheWutuWbreiJuuWFu+iKsT3wn6q0DQrpmo/po47po5jokL3nmoTlj7blrZDlvq7po47np4vlpKnoh6rnhLbovbvmnb498J+Ngw0K6JC95Y+256eL5aSp5YeL6Zu25oCA5pen5o2i5a2jPfCfjYINCuaeq+WPtueni+WkqeWKoOaLv+Wkp+e6ouWPtj3wn42BDQrmqLHoirHmmKXlpKnnmoTmtarmvKvml6XmnKzmqLHoirHlsJHlpbPlv4M98J+MuA0K6Iqx6aWw5aWW56ug5YuL56ug5bqG56WdPfCfj7XvuI8NCueOq+eRsOeOq+eRsOiKseeIseaDhea1qua8q+eDreeDiD3wn4y5DQrmnq/okI7nmoToirHlv4Pnoo7nu53mnJvpgJ3ljrvnmoTniLE98J+lgA0K5pyx5qe/5om25qGR6Iqx54Ot5bim6aOO5oOF5aSP5pel5bqm5YGHPfCfjLoNCuWQkeaXpeiRtemYs+WFieenr+aegea4qeaaluW4jOacmz3wn4y7DQrpm4/lvaLlsI/nmb3oirHnuq/mtIHlj6/niLHmuIXmlrA98J+MvA0K6YOB6YeR6aaZ5LyY6ZuF5pil5aSp6auY6LS1PfCfjLcNCuiKseadn+mAgeiKseelnei0uuaEn+iwoue7k+Wpmj3wn5KQDQrluLjpnZLmoJHmnb7moJHmo67mnpflpKfoh6rnhLblnZrpn6c98J+Msg0K6JC95Y+25qCR5aSn5qCR6YGu6I2r546v5L+d5qCR5pyoPfCfjLMNCuajleamiOagkeaksOWtkOagkea1t+a7qeeDreW4puW6puWBh+Wkj+WkqT3wn4y0DQrku5nkurrmjozmspnmvKDlnZrlvLrpmLLovpDlsITogJDml7E98J+MtQ0K5LiD5aSV56u56K645oS/56u55pel5pys5LiD5aSV6IqC56WI56aPPfCfjosNCumXqOadvuaXpeacrOaWsOW5tOijheaJruWQieelpeWmguaEjz3wn46NDQrnqLvnqZfpuqbnqZfkuLDmlLbnsq7po5/kuaHmnZHlhpzkuJromJHoj4c98J+Mvg0K5q+S6JiR6I+H6LaF57qn6JiR6I+H6YeH6JiR6I+H5ri45oiP6YGT5YW35Y+v54ixPfCfjYQNCueJm+ayueaenOmzhOaiqOWBpeW6t+mlrumjn+i9u+mjn+ayueiEguaenD3wn6WRDQrojITlrZDojITlrZDlnKjnvZHnu5zor63looPkuK3luLjkvZzkuLrnibnlrprmmpfnpLrnrKblj7c98J+Nhg0K5Zyf6LGG6ams6ZOD6Jav5Li76aOf56yo5ouZUG90YXRv6Jav5p2h5Y6f5paZPfCfpZQNCuiDoeiQneWNnOWFlOWtkOmjn+eJqeihpeWFhee7tOeUn+e0oOWlluWKseiDoeiQneWNnOS4juajkuWtkD3wn6WVDQrnjonnsbPlhpzkvZznianniIbnsbPoirHljp/mlpnnsq7po5898J+MvQ0K57qi6L6j5qSS6L6j54Ot5oOF54Gr54iG54Gr6L6jPfCfjLbvuI8NCumdkuakkuW9qeakkuiUrOiPnOaMkemjn+W+iOWkmuWwj+WtqeS4jeWQg+mdkuakkj3wn6uRDQrpu4Tnk5zmlbfpnaLohpzmuIXniL3nvo7lrrnlh4nmi4w98J+lkg0K57u/5Y+26I+c55Sf6I+c6JSs6I+c5rKZ5ouJ5YeP6ISC6aSQ5pyJ5py6PfCfpawNCuilv+WFsOiKseWBpeW6t+mjn+WTgeWwj+agkeiLl+mAoOWei+WBpei6q+mkkD3wn6WmDQrlpKfokpzosIPlkbPlk4HpqbHpgqrokpzpppk98J+nhA0K5rSL6JGx5Yml5rSL6JGx5YKs5rOq5Z+65bGC6LCD5ZGzPfCfp4UNCuiKseeUn+WdmuaenOiKseeUn+ayueiKseeUn+mFseaJozHpgIHoirHnlJ898J+lnA0K6LGG5a2Q57qi6LGG6LGG57G755u45oCd6LGG57qi6LGG5rKZ6KGl5YWF6JuL55m9PfCfq5gNCuagl+WtkOadv+agl+eni+WkqeezlueCkuagl+WtkOWdmuaenD3wn4ywDQrnlJ/lp5zlp5zpqbHlr5Llp5zojLbosIPlkbPmoLnojI498J+rmg0K6LGM6LGG6I2a6LGG6KeS6LGM6LGG57u/6Imy6JSs6I+cPfCfq5sNCuagueiMjuiUrOiPnOeUnOiPnOagueiKnOiPgeiQneWNnOetieWcn+mHjOmVv+WHuueahOWdl+aguT3wn6ucDQrokaHokITokaHokITokaHokITphZLlkIPokaHokITkuI3lkJDokaHokITnmq498J+Nhw0K5ZOI5a+G55Oc6aaZ55Oc55Sc55Oc5rC05p6c5rKZ5ouJPfCfjYgNCuilv+eTnOWkj+WkqeWQg+eTnOe+pOS8l+a4heWHieino+aakT3wn42JDQrmqZjlrZDmn5HmqZjlpKflkInlpKfliKnmn5HmqZjooaXlhYXnu7RDPfCfjYoNCuafoOaqrOmFuOafoOaqrOeyvumFuOS6hue+oeaFleWrieWmkj3wn42LDQrpnZLmn6DphbjmqZnpuKHlsL7phZLphY3mlpnkuJzljZfkuprpo47lkbM98J+Ni+KAjfCfn6kNCummmeiViemmmeiViea7keWAkuihpeWFhemSvuWFg+e0oD3wn42MDQroj6DokJ3lh6Tmoqjng63luKbmsLTmnpzoj6DokJ3ljIXlh6TmoqjphaU98J+NjQ0K6IqS5p6c6IqS5p6c6IqS5p6c5Yaw54Ot5bim6aOO5ZGzPfCfpa0NCue6ouiLueaenOWBpeW6t0FuYXBwbGVhZGF55bmz5a6J5aSc6Iu55p6c5YWs5Y+4PfCfjY4NCumdkuiLueaenOmdkua2qemFuOeUnOacquaIkOeGnz3wn42PDQrmoqjmoqjnprvliKvosJDpn7PmtqbogrrmoYPlrZA98J+NkA0K5qGD5a2Q5rC06Jyc5qGD5qGD5qGD6Iqx6L+Q5Zyo572R57uc6K+t5aKD5Lit5Lmf5oyH6IeA6YOoPfCfjZENCuaoseahg+aoseahg+i9puWOmOWtkOmrmOminOWAvD3wn42SDQrojYnojpPojYnojpPlsJHlpbPmhJ/nlJznvo498J+Nkw0K6JOd6I6T5oqk55y86JOd6I6T5bmy6LaF57qn6aOf54mpPfCfq5ANCueMleeMtOahg+Wlh+W8guaenOe7tEPkuYvnjovlpYflvILmnpw98J+lnQ0K55Wq6IyE6KW/57qi5p+/55Wq6IyE54KS6JuL5pei5piv5rC05p6c5Lmf5piv6JSs6I+cPfCfjYUNCuaphOamhOaphOamhOaeneWSjOW5s+aphOamhOayueWcsOS4rea1tz3wn6uSDQrmpLDlrZDng63luKbmpLDmsYHmtbfmu6nluqblgYc98J+lpQ0K5pyo5aS05p+054Gr5pyo5p2Q5qCR5bmy6Zyy6JCl54On5p+05qOV5qaIPfCfqrUNCum4n+W3ouW4puibi+akjeeJqeaeneadoeaQreW7uueahOeqneetkeW3ouWutj3wn6q6DQrnqbrpuJ/lt6Lnprvlt6LnrZHlt6Llh4blpIc98J+quQ0K6KSQ6Imy6aOf55So6I+M6aaZ6I+H5Y+j6JiR5pyo6ICz57G75bmz6I+HPfCfjYTigI3wn5+rDQoNCiMjIyMjIyMjIyMjI+OAkPCfmpfkuqTpgJrlt6XlhbfjgJENCuWwj+axvei9puiHqumpvuWHuuihjOS4iuePrT3wn5qXDQrwn6eMPfCfp4wNCui1m+i9pui3kei9pumjmei9pui/veaxgumAn+W6pj3wn4+O77iPDQroh6rooYzovabpqpHooYzkvY7norPnjq/kv53lgaXouqs98J+asg0K6LiP5p2/5pGp5omY55S15Yqo6L2m5aSW5Y2W6YCa5Yuk5pa55L6/PfCfm7UNCumjnuacuuWHuuW3ruWHuuWig+a4uOi1t+mjnj3inIjvuI8NCueBq+eureS4gOmjnuWGsuWkqei1t+mjnua2qOWBnD3wn5qADQrmiL/lsYvlrrblm57lrrbmuKnppqjmiL/lnLDkuqc98J+PoA0K5Yqe5YWs5aSn5qW85omT5bel5YWs5Y+45YaZ5a2X5qW8PfCfj6INCuWMu+mZoueci+eXheWBpeW6t+S9k+ajgD3wn4+lDQrlrabmoKHkuIrlrablvIDlrabmoKHlm63nlJ/mtLs98J+Pqw0K6ZOB5aGU5Zyw5qCH5peF5ri45be06buO5Lic5Lqs5omT5Y2hPfCfl7wNCuWHuuenn+i9pj3wn5qVDQrlhazkuqTovaY98J+ajA0K5Zyw6ZOBPfCfmocNCumrmOmTgT3wn5qEDQrnm7TljYfmnLo98J+agQ0K5pGp5omY6L2mPfCfj43vuI8NCui9ruiIuT3wn5qiDQrluIboiLk94pu1DQrkvr/liKnlupc98J+Pqg0K6YWS5bqXPfCfj6gNCuiHqueUseWls+elnuWDjz3wn5e9DQrmlZnloII94puqDQrmuIXnnJ/lr7o98J+VjA0K5rW35rupPfCfj5bvuI8NCumbquWxsT3wn4+U77iPDQrngavlsbE98J+Miw0K6Zyy6JClPfCfj5XvuI8NCg0KIyMjIyMjIyMjIyMj44CQ8J+NlOe+jumjn+S4jue+juWmhuOAkQ0K5rGJ5aCh5b+r6aSQ5Z6D5Zy+5b+r5LmQ6aOf5ZOB576O5byPPfCfjZQNCuaKq+iQqOiBmuS8muaKq+iQqOW/q+S5kOa6kOaziT3wn42VDQrolq/mnaHolq/mnaHov73liafpm7bpo5898J+Nnw0K54Ot54uX5b+r6aSQ6KGX5aS05bCP5ZCDPfCfjK0NCuS4ieaYjuayu+aXqemkkOeugOmkkOW3peS9nOmkkD3wn6WqDQrloZTlj6/loqjopb/lk6Xljbfppbzloqjopb/lk6Xpo47lkbNUYWNvPfCfjK4NCuaLiemdouaxpOmdouWQg+mdouWknOWuteeis+awtOW/q+S5kD3wn42cDQrlr7/lj7jml6Xmlpnnsr7oh7TppJDngrk98J+Now0K6aW65a2Q6L+H5bm05Zue5a625Lit5Zu9576O6aOfPfCfpZ8NCuePjeePoOWltuiMtue7reWRveawtOS4i+WNiOiMtueUnOWmueW/heWkhz3wn6eLDQrlkpbllaHmiZPlt6Xkurrnu63lkb3mj5DnpZ7ml6lDQ29mZmVlPeKYlQ0K57u/6Iy254Ot6Iy25Zad6Iy25YW755Sf5ZOB5ZGzPfCfjbUNCuWGsOa3h+a3i+Wkj+WkqeeUnOWTgeino+aakT3wn42mDQrnnLzplZzoo4XlrabpnLjnnIvmuIXmpZo98J+Rkw0K5aKo6ZWc6KOF6YW36YGu6ZizPfCflbbvuI8NCuihrOihq+mihuW4puato+ijheS4iuePreWVhuWKoT3wn5GUDQrov57ooaPoo5nlpbPoo4Xnqb/mkK3mvILkuq498J+Rlw0K6auY6Lef6Z6L5oCn5oSf5oiQ54af5pe25bCaPfCfkaANCui/kOWKqOmei+eQg+mei+a9rumei+i/kOWKqOS8kemXsj3wn5GfDQrnmoflhqDnjovogIXlpbPnjovnrKzkuIDpq5jotLU98J+RkQ0K5Y+j57qi576O5aaG5YyW5aaG57K+6Ie05aWz55SfPfCfkoQNCuaIkuaMh+axguWpmue7k+WpmuaJv+ivuuePoOWunT3wn5KNDQrlj4zogqnljIXkuIrlrablh7rmuLjog4zljIXlrqI98J+Okg0K57qi6Iu55p6cPfCfjY4NCummmeiViT3wn42MDQropb/nk5w98J+NiQ0K6JGh6JCEPfCfjYcNCuiNieiOkz3wn42TDQrmqLHmoYM98J+Nkg0K5qGD5a2QPfCfjZENCuiPoOiQnT3wn42NDQrnjJXnjLTmoYM98J+lnQ0K54mb5rK55p6cPfCfpZENCuexs+mlrT3wn42aDQrmhI/lpKfliKnpnaI98J+NnQ0K6JuL57OVPfCfjbANCueUnOeUnOWciD3wn42pDQrppbzlubI98J+Nqg0K5ZWk6YWSPfCfjboNCue6oumFkj3wn423DQrppa7mlpk98J+lpA0K6Z2i5YyFPfCfjZ4NCuW4pumqqOiCiT3wn42WDQrpuKHohb898J+Nlw0K54mb5o6SPfCfpakNCuWfueaguT3wn6WTDQrngrjomb498J+NpA0K5rKz6LGaPfCfkKENCuWSluWWsemlrT3wn42bDQrppa3lm6I98J+NmQ0K57K95a2QPfCfq5QNCua1heW6lemUheeCluiPnD3wn6WYDQroip3lo6vngavplIU98J+rlQ0K5Yio5YawPfCfjacNCuWGsOa3h+a3i+eQgz3wn42oDQrlhrDlnZc98J+nig0K54iG57Gz6IqxPfCfjb8NCuiKseeUnz3wn6WcDQrmoJflrZA98J+MsA0K6LGG5a2QPfCfq5gNCummmeannz3wn6WCDQrpuKHlsL7phZI98J+NuA0K55uS6KOF6aWu5paZPfCfp4MNCua4hemFkj3wn422DQrnhY7om4vng7nppao98J+Nsw0K6bih6JuLPfCfpZoNCum7hOayuT3wn6eIDQrlpbbphao98J+ngA0K5qmE5qaEPfCfq5INCuWkp+iSnD3wn6eEDQrmtIvokbE98J+nhQ0K54WO6aW8PfCfpZ4NCuaymeaLiT3wn6WXDQrnlJ/ml6Xom4vns5U98J+Ogg0K57q45p2v6JuL57OVPfCfp4ENCuW3p+WFi+WKmz3wn42rDQrns5bmnpw98J+NrA0K5qOS5qOS57OWPfCfja0NCuW4g+S4gT3wn42uDQrmtL498J+lpw0K5Zui5a2QPfCfjaENCuWNjuWkq+mlvD3wn6eHDQrlj6/pooI98J+lkA0K6LSd5p6cPfCfpa8NCg0KIyMjIyMjIyMjIyMj44CQ8J+Su+aXpeW4uOeJqeWTgeS4jueUteWtkOenkeaKgOOAkQ0K5omL5py65Y+R5b6u5L+h5Yi35omL5py66IGU57O75pa55byPPfCfk7ENCueslOiusOacrOeUteiEkeWKoOePreWGmeS7o+eggeWKnuWFrOaJk+a4uOaIjz3wn5K7DQrlj7DlvI/nlLXohJHlt6XkvZznq5nnlLXnq57miL898J+Wpe+4jw0K6ZSu55uY5omT5a2X6ZSu55uY5L6g5Yqe5YWsPeKMqO+4jw0K55u45py65pGE5b2x6K6w5b2V55Sf5rS75peF5ri45omT5Y2hPfCfk7cNCuiAs+acuuWQrOatjOayiea1uOW8j+ayieaAnT3wn46nDQrnga/ms6HmnInngbXmhJ/kuobngrnlrZDkuq7kuoY98J+SoQ0K5Lmm57GN5Lmm5pys5a2m5Lmg6K+75Lmm55+l6K+G6ICD56CUPfCfk5oNCumTheeslOWIkue6v+S/ruaUueiusOW9leiNieeovz3inI/vuI8NCumSpeWMmeWvhueggeino+WvhuWFs+mUruS6pOaIvz3wn5SRDQrpkrHooovlj5HotKLmmrTlr4zpooTnrpc98J+SsA0K5L+h55So5Y2h5Yi35Y2h5raI6LS55Lmw5Lmw5LmwPfCfkrMNCumXuemSn+aXqei1t+aJk+WNoeWCrOS/g+WAkuiuoeaXtj3ij7ANCuWMheijueW/q+mAkuaLhuW/q+mAkue9kei0reWvhOS7tj3wn5OmDQrnpLznianpgIHnpLzmg4rllpzoioLml6XnpLzniak98J+OgQ0K5omL6KGoPeKMmg0K55S15rGgPfCflIsNCuaPkuWktD3wn5SMDQrnlLXop4Y98J+Tug0K5aSH5b+Y5b2VPfCfk50NCuWbvumSiT3wn5OMDQrplIE98J+Ukg0K5L+h5bCBPeKcie+4jw0K5rCU55CDPfCfjogNCueBq+eEsD3wn5SlDQrpkrvnn7M98J+Sjg0K5ri45oiP5omL5p+EPfCfjq4NCuaRh+adhj3wn5W577iPDQrpnbblv4M98J+Orw0K6aqw5a2QPfCfjrINCuiAgeiZjuacuj3wn46wDQrlsI/kuJHniYznmb7mkK098J+Djw0K5aSW5pif5oCq54mp57uP5YW45ri45oiP5b2i6LGhPfCfkb4NCuacuuWZqOS6uj3wn6SWDQrlv7Xnj6Dlj6/nqb/miLTppbDlk4E98J+Tvw0K55y86ZWcPfCfkZMNCuWkqumYs+mVnD3wn5W277iPDQrmiqTnm67plZw98J+lvQ0K5omL55S1562SPfCflKYNCuicoeeDmz3wn5Wv77iPDQrmsrnnga898J+qlA0K5L2O55S16YeP55S15rGgPfCfqqsNCui9r+ebmD3wn5K+DQrlhYnnm5g98J+Svw0KRFZEPfCfk4ANCum6puWFi+mjjj3wn46kDQrmiazlo7Dlmag98J+Uig0K5Lit6Z+z6YePPfCflIkNCuS9jumfs+mHjz3wn5SIDQrpnZnpn7M98J+Uhw0K5Y2r5pif5aSp57q/PfCfk6ENCum8oOaghz3wn5ax77iPDQrmiZPljbDmnLo98J+WqO+4jw0K5bim6Zeq5YWJ54Gv55qE55u45py6PfCfk7gNCuaRhOWDj+acuj3wn46lDQrlvZXlg4/mnLo98J+TuQ0K5pS26Z+z5py6PfCfk7sNCueUteivneWQrOetkj3wn5OeDQrlm7rlrprnlLXor5094piO77iPDQrlr7vlkbzmnLo98J+Tnw0K5Lyg55yf5py6PfCfk6ANCuW4pueureWktOeahOaJi+acuj3wn5OyDQrlr7nor53msJTms6E98J+SrA0K5oyv5Yqo5qih5byPPfCfk7MNCuWFs+acuuaooeW8jz3wn5O0DQoNCiMjIyMjIyMjIyMjI+OAkOKYgO+4j+WkqeawlOS4jueIseW/g+OAkQ0K5aSq6Ziz5pm05aSp5aSn5pm05aSp6Ziz5YWJ5aW95b+D5oOFPeKYgO+4jw0K5byv5pyI5aSc5pma5pma5a6J54as5aSc5aSc54yr5a2QPfCfjJkNCumXqueDgeeahOaYn+aYn+S6ruecvOaDiuiJs+aYn+aYn+ecvD3wn4yfDQrph5HmmJ/kupTop5LmmJ/mlLbol4/miZPliIbkvJjnp4A94q2Q77iPDQrkuYzkupHpmLTlpKnlv4Pmg4XkvY7okL3pmLTlpKk94piB77iPDQrkuIvpm6jkuIvpm6jlpKnlv4Pmg4Xpg4Hpl7c98J+Mp++4jw0K6Zuq6Iqx5LiL6Zuq5Ya35Yas5aSp6ZmN5ripPeKdhO+4jw0K6Zeq55S16YCf5bqm5b+r6Zu35Ye76ZyH5oOK6Zeq546wPeKaoQ0K5b2p6Jm5576O5aW96Zuo6L+H5aSp5pm05aSa5YWD5YyF5a65PfCfjIgNCuS4i+mbqumZjembquWkqeawlD3wn4yo77iPDQrpm6rkurrml6DohLjlhqzlpKnpm6rmma894puEDQrpm6rkurrmnInohLjlhqzlpKnlnKPor57msJvlm7Q94piD77iPDQrpo47ohLjlkLnmsJTlr5Lpo47lkbzlkLg98J+MrO+4jw0K6Zu+6Zu+6Zy+6IO96KeB5bqm5L2OPfCfjKvvuI8NCmRhc2jnrKblj7flv6vpgJ/np7vliqjpo47lkbzmsJQ98J+SqA0K5rC05ru06Zuo5rC05rGX5rC055y85rOqPfCfkqcNCuaxl+a7tOWkp+mHj+axl+awtOWKquWKmz3wn5KmDQrpm6jkvJ7kuIvpm6jlpKnpmLLpm6g94piUDQrngavnhLDngo7ng63ngavngb7mtYHooYw98J+UpQ0K5rip5bqm6K6h6auY5rip5Y+R54On5rWL6YePPfCfjKHvuI8NCuaWsOaciOiEuOelnuenmOWwtOWwrOeahOihqOaDhT3wn4yaDQrkuIrlvKbmnIjohLjlpJzmmZrnnaHmhI898J+Mmw0K5LiL5bym5pyI6IS45aSc5pma54as5aScPfCfjJwNCua7oeaciOiEuOWchua7oeaYjuS6rj3wn4ydDQrlpKrpmLPohLjngo7ng63lvIDlv4PpmLPlhYk98J+Mng0K5pm06Ze05aSa5LqR5aSn6YOo5YiG5pm05aSp5bCR6YeP5LqRPfCfjKTvuI8NCuWkmuS6keWkqumYs+iiq+S6kemBruS9jz3im4UNCumYtOmXtOWkmuS6keWkp+mDqOWIhumYtOWkqeWBtuWwlOingeWkqumYsz3wn4yl77iPDQrmmbTpl7TpmLXpm6jlpKrpmLPlkozpm6jlkIzml7blh7rnjrA98J+Mpu+4jw0K6Zu36Zuo6Zu355S15Lqk5YqgPfCfjKnvuI8NCumbt+mbqOS6keW4pumXqueUteeahOenr+mbqOS6kT3im4jvuI8NCum+meWNt+mjjuaXi+mjjumjk+mjjj3wn4yq77iPDQrnuqLlv4Pnu4/lhbjng63ng4jnmoTniLHllpzmrKI94p2k77iPDQrmqZnlv4PmuKnmmpblj4vmg4Xku6XkuIo98J+noQ0K6buE5b+D55yf6K+a6Ziz5YWJ55qE54ixPfCfkpsNCue7v+W/g+WBpeW6t+eOr+S/neWrieWmkuiLseaWh+ailz3wn5KaDQrok53lv4Pnuq/mtIHkv6Hku7vlhrfphbfnmoTniLE98J+SmQ0K57Sr5b+D5rWq5ryr6auY6LS16L+35bm7PfCfkpwNCum7keW/g+WcsOeLseeskeivneiFuem7keS4pz3wn5akDQrnmb3lv4Pnuq/nnJ/lkozlubPml6DnkZU98J+kjQ0K5qOV5b+D6YaH5Y6a5YOP5ben5YWL5Yqb5LiA5qC355qE54ixPfCfpI4NCuW/g+eijuS8pOW/g+WIhuaJi+mavui/hz3wn5KUDQrnqbrlv4Plv4M94pmhDQrml4vovazlv4M94p2lDQrlv4PlvaLmhJ/lj7nlj7c94p2j77iPDQrkuKTpopflv4M98J+SlQ0K6Zeq6ICA55qE5b+DPfCfkpYNCui3s+WKqOeahOW/gz3wn5KXDQrlsITkuK3niLHlv4M98J+SmA0K57O75bim55qE5b+DPfCfkp0NCuaXi+i9rOeahOW/gz3wn5KeDQrmkI/liqjnmoTlv4M98J+Skw0K5b+D5b2i6KOF6aWwPfCfkp8NCg0KIyMjIyMjIyMjIyMj44CQ8J+Pg+i/kOWKqOS4juWBpei6q+OAkQ0K6Laz55CD5LiW55WM5p2v6L+Q5Yqo6Lii55CDPeKavQ0K56+u55CD5omT55CDTkJB6L+Q5YqoPfCfj4ANCue9keeQg+e9keeQg+i/kOWKqOWBpei6qz3wn46+DQrkuL7ph43lgaXouqvpk4Hkurrmkrjpk4HlgaXouqvmiL/miZPljaE98J+Pi++4jw0K55Gc5Ly95Yal5oOz5pS+5p2+5omT5Z2Q5b+D5oCB5bmz56izPfCfp5gNCui3keatpeW8gOa6nOi3keatpeWGsuWIuui1tuaXtumXtD3wn4+DDQrmuLjms7PlpI/lpKnop6PmmpHmuLjms7M98J+Pig0K5ri45oiP5omL5p+E5omT5ri45oiP55S156ue5byA6buRPfCfjq4NCumqsOWtkOaLvOi/kOawlOi1jOS4gOaKiumaj+acuj3wn46yDQrosIPoibLmnb/nu5jnlLvoibrmnK/orr7orqHnlLvnlLs98J+OqA0K6bqm5YWL6aOO5ZSx5q2MS1RW5ryU6K6y5pKt5a6iPfCfjqQNCumfs+espuWQrOatjOaciemfs+S5kOaEnz3wn461DQrlpJrpn7PnrKbmrKLlv6vnmoTpn7PkuZDllLHmrYw98J+Otg0K5ZCJ5LuW5pGH5rua5by55ZSx5rCR6LCjPfCfjrgNCumSoueQtOmUruebmOWPpOWFuOS5kOS8mOmbhee7g+eQtD3wn465DQrniLXlo6vpvJPmiZPlh7vkuZDoioLlpY/mhJ/ll6jotbfmnaU98J+lgQ0K6JCo5YWL5pav54i15aOr6aOO5rWq5ryr5aSc5bqXPfCfjrcNCuWwj+WPt+WQueWPt+i/m+WGm+Wuo+W4g+a2iOaBrz3wn466DQrlsI/mj5DnkLTpq5jpm4Xmi4nlvKbnhb3mg4XnvZHkuIrluLjnlKjmnaXooajovr7kuLrkvaDmi4nkuIDpppbmgrLkvKTnmoTmm7LlrZA98J+Ouw0K5qmE5qaE55CDPfCfj4gNCuajkueQgz3imr4NCuaOkueQgz3wn4+QDQrlj7DnkIM98J+OsQ0K5LmS5LmT55CDPfCfj5MNCue+veavm+eQgz3wn4+4DQrpnbblv4M98J+Orw0K5oiP5Ymn6Z2i5YW3PfCfjq0NCuiAs+acuj3wn46nDQrlnLrorrDmnb898J+OrA0K55u45py6PfCfk7cNCuW6huelnT3wn46JDQrlvannkIM98J+Oig0K5aWW5p2vPfCfj4YNCumHkeeJjD3wn6WHDQoNCiMjIyMjIyMjIyMjI+OAkOKaoO+4j+espuWPt+agh+iusOOAkQ0K6K2m5ZGK5rOo5oSP6aOO6Zmp5o+Q6YaS5pyJ5Z2RPeKaoO+4jw0K56aB5q2i5LiN6KGM5Lil56aB5omT5L2PPfCfmqsNCumUmeivr+WPieS4jeWvueaLkue7neWPlua2iD3inYwNCuato+ehruWLvuWujOaIkOmAmui/h+aQnuWumj3inIUNCjEwMOWIhuWkquajkuS6hua7oeWIhuecn+eQhuW8uueDiOi1nuWQjD3wn5KvDQrpl67lj7fmnInnlpHpl67nlpHmg5HllaU94p2TDQrmhJ/lj7nlj7flvLrosIPms6jmhI/ph43opoHmj5DphpI94p2XDQrmvKnmtqHmmZXov7fojKvmt7fkubHovazlnIg98J+MgA0K5peg6ZmQ5rC45oGS5peg56m35peg6ZmQ5Y+v6IO9PeKZvu+4jw0K57qi5ZyG5ZyI6YeN54K55pyq6K+75o+Q6YaS5b2V5Yi25LitPfCflLQNCue7v+WchuWciOWcqOe6v+mAmui/h+WuieWFqD3wn5+iDQrpu4TlnIblnIjlvoXlrprorablkYo98J+foQ0K56aB5q2i5qCH6K6w5pWP5oSf6ZmQ5Yi2PfCfiLINCuWFjei0ueagh+iusOemj+WIqUZyZWXoloXnvormr5s98J+Gkw0K5qCH562+5qCH54mM5qCH6K6w5qCH562+5Lu35qC854mMPfCfj7fvuI8NCuWVhuagh+espuWPt+WVhuagh+WTgeeJjOagh+ivhj3ihKLvuI8NCuazqOWGjOWVhuagh+W3suazqOWGjOWVhuaghz3Cru+4jw0K5YGc5q2i5qCH5b+X5YGc6L2m5qCH5b+X56aB5q2iPfCfm5ENCuWbnuaUtuagh+W/l+eOr+S/neW+queOr+WIqeeUqD3imbvvuI8NCuWMu+eWl+agh+W/l+ibh+adluWMu+Wtpuagh+W/lz3impXvuI8NCui9ruakheagh+ivhuaXoOmanOeijeaui+eWvuS6uuiuvuaWvT3imb8NCuagh+ivreeJjOaKl+iuruekuuWogeWFrOWRiueJjD3wn6qnDQrnmb3nvorluqdVMjY0OD3imYgNCumHkeeJm+W6p1UyNjQ5PeKZiQ0K5Y+M5a2Q5bqnVTI2NEE94pmKDQrlt6jon7nluqdVMjY0Qj3imYsNCueLruWtkOW6p1UyNjRDPeKZjA0K5aSE5aWz5bqnVTI2NEQ94pmNDQrlpKnnp6TluqdVMjY0RT3imY4NCuWkqeidjuW6p1UyNjRGPeKZjw0K5bCE5omL5bqnVTI2NTA94pmQDQrmkannvq/luqdVMjY1MT3imZENCuawtOeTtuW6p1UyNjUyPeKZkg0K5Y+M6bG85bqnVTI2NTM94pmTDQrom4flpKvluqdVMjZDRT3im44NCue6ouS4rT3wn4CEDQrlj5HotKI98J+AhQ0K55m95p2/PfCfgIYNCum7keahgz3imaANCuepuuW/g+e6ouahgz3imaENCuepuuW/g+aWueWdlz3imaINCuaiheiKsT3imaMNCuepuuW/g+m7keahgz3imaQNCue6ouahgz3imaUNCuaWueWdl1UyPeKZpg0K6buR5pa55YW15YW15Y2S5pyJ5b2p6ImyRW1vamnniYjmnKxVMjY1Rj3imZ8NCum7keahg+aJkeWFi+eJjOiKseiJsj3imaDvuI8NCue6ouW/g+aJkeWFi+eJjOiKseiJsj3imaXvuI8NCuaWueWdl+aJkeWFi+eJjOiKseiJsj3imabvuI8NCuaiheiKseaJkeWFi+eJjOiKseiJsuaJkeWFi+eJjEHmiZHlhYvniYxFbW9qaeWujOaVtDUy5byg5aSn5bCP546LPeKZo++4jw0K6ZKx6KKL6LSi5a+M6YeR6ZKxPfCfkrANCue+juWFg+e6uOW4gee+juWFg+eOsOmHkT3wn5K1DQrml6XlhYPnurjluIHml6XlhYPnjrDph5E98J+StA0K5qyn5YWD57q45biB5qyn5YWD546w6YeRPfCfkrYNCuiLsemVkee6uOW4geiLsemVkeeOsOmHkT3wn5K3DQrluKbnv4XohoDnmoTpkrHoirHpkrHotYTph5HmtYHlpLE98J+SuA0K5L+h55So5Y2h5pSv5LuY5Yi35Y2hPfCfkrMNCui0p+W4geWFkeaNouWkluaxh+aNouaxhz3wn5KxDQrph5HpkrHlmLTohLjlj5HotKLotKrotKI98J+kkQ0K6ZO26KGM6YeR6J6N5py65p6EPfCfj6YNCueZveaWueeOi+WbveeOi+aXoOS7tz3imZQNCueZveaWueWQjueOi+WQjue6pjnliIY94pmVDQrnmb3mlrnovabmiJjovabln47loKHnuqY15YiGPeKZlg0K55m95pa56LGh5Li75pWZ57qmM+WIhj3imZcNCueZveaWuemprOmqkeWjq+e6pjPliIY94pmYDQrnmb3mlrnlhbXlhbXljZIx5YiGPeKZmQ0K6buR5pa5546L5Zu9546LPeKZmg0K6buR5pa55ZCO546L5ZCOPeKZmw0K6buR5pa56L2m5oiY6L2m5Z+O5aChPeKZnA0K6buR5pa56LGh5Li75pWZPeKZnQ0K6buR5pa56ams6aqR5aOrPeKZng0K5omR5YWL54mMQeaJkeWFi+eJjEVtb2pp5a6M5pW0NTLlvKDlpKflsI/njos98J+CoQ0K5aSa57Gz6K+66aqo54mM5a6M5pW05aSa57Gz6K+654mM57uEPfCfgaMNCuWcsOeQgz3wn4yPDQrnrpfnm5g98J+nrg0K6L6Q5bCE5qCH5b+XPeKYou+4jw0K55Sf54mp5Y2x5a6zPeKYo++4jw0K5rip5rOJPeKZqO+4jw0KQ09PTD3wn4aSDQpORVc98J+GlQ0KVVA98J+GmQ0K54mI5p2DPcKp77iPDQrnlLfmgKc94pmC77iPDQrlpbPmgKc94pmA77iPDQrot6jmgKfliKs94pqn77iPDQrok53lnIY98J+UtQ0K57qi5pa55Z2XPfCfn6UNCuiTneaWueWdlz3wn5+mDQrnu7/mlrnlnZc98J+fqQ0K6buE5pa55Z2XPfCfn6gNCue6ouS4ieinkj3wn5S6DQrlgJLnuqLkuInop5I98J+Uuw0K6I+x5b2i5ZyG54K5PfCfkqANCueZveeyl+aWueahhj3wn5SzDQrpu5HlpKfmlrnlnZc94qybDQrnmb3lpKfmlrnlnZc94qycDQrpu5HkuK3mlrnlnZc94pe877iPDQrnmb3kuK3mlrnlnZc94pe777iPDQrlm5vliIbpn7PnrKY94pmpDQrlhavliIbpn7PnrKY94pmqDQrlj4zlhavliIbpn7PnrKY94pmrDQrljYHlha3liIbpn7PnrKY94pmsDQrpmY3lj7c94pmtDQrljYflj7c94pmvDQrlj4zmhJ/lj7nlj7c94oC877iPDQrmhJ/lj7npl67lj7c94oGJ77iPDQrnmb3oibLpl67lj7c94p2UDQrnmb3oibLmhJ/lj7nlj7c94p2VDQrms6Lmtarnur/pl7TpmpTlj7c944Cw77iPDQrmmJ/mmJ894q2QDQrpl6rkuq7nmoTmmJ898J+Mnw0K6Zeq54OBPeKcqA0K5pmV55yp5pifPfCfkqsNCumYtOW9seaYnz3inLANCuepuuW/g+aYnz3inKkNCuW4puWciOaYnz3inKoNCumYtOW9seaYn18yPeKcrw0K5YWt6IqS5pifPeKcoQ0K6Zuq6IqxPeKdhO+4jw0K5a6e5b+D6Zuq6IqxPeKdhg0K6Zuq6IqxXzI94p2FDQroirHmnLU94py/DQroirHmnLVfMj3inYANCuWbm+inkuaYnz3inKcNCuWbm+inkuaYn18yPeKcpg0K57KX5L2T5a+55Yu+PeKclO+4jw0K5Yu+6YCJ5qGGPeKYke+4jw0K5Y+J5Y+35qGGPeKYkg0K57u/6Imy5Y+J5Y+3PeKdjg0K57KX5L2T5LmY5Y+35Y+JPeKclu+4jw0K57uG5Y+JPeKclQ0K5pac5Y+JPeKclw0K57KX5pac5Y+JPeKcmA0K57qi6Imy5ZyG5ZyIPeKtlQ0K5Y2V6YCJ5oyJ6ZKuPfCflJgNCg0KIyMjIyMjIyMjIyMj44CQ8J+SiuWMu+iNr+OAkQ0K6I2v5Li45ZCD6I2v57ut5ZG95rK755eFPfCfkooNCuWQrOiviuWZqOWMu+eUn+ajgOafpeWBpeW6tz3wn6m6DQrms6jlsITlmajmiZPpkojnlqvoi5fmir3ooYDmiZPpkog98J+SiQ0K6KGA5ru054yu6KGA5Y+X5Lyk55Sf55CG5pyfPfCfqbgNCuWIm+WPr+i0tOWPl+S8pOatouihgOaKmuW5s+WIm+S8pD3wn6m5DQrogqXnmoLmtJfmiYvmuIXmtIHljavnlJ898J+nvA0K5Lmz5ray55O25rSX5omL5ray5raI5q+SPfCfp7QNCueJmeWIt+WPo+iFlOWNq+eUn+WIt+eJmT3wn6qlDQrpqazmobbljavnlJ/pl7TmjpLms4Q98J+avQ0K5reL5rW05rSX5r6h5riF5rSBPfCfmr8NCua1tOe8uOazoea+oea4hea0gT3wn5uBDQrnlJ/nianljbHlrrPnlJ/nianljbHpmannl4Xmr5LmsaHmn5M94pij77iPDQrovpDlsITmlL7lsITmgKfmoLjovpDlsIQ94pii77iPDQrpqrfpq4XkuqTlj4npqqjliafmr5LljbHpmanmrbvkuqE94pig77iPDQrorablkYrms6jmhI/orabnpLo94pqg77iPDQrlpKfohJHnpZ7nu4/nsr7npZ7lgaXlurfmmbrlips98J+noA0K54mZ6b2/54mZ56eR5Y+j6IWU5YGl5bq3PfCfprcNCumqqOWktOmqqOmqvOmqqOenkT3wn6a0DQrlv4PohI/op6PliZblv4PohI/lv4PooYDnrqHlgaXlurc98J+rgA0K6IK66ISP6IK66YOo5ZG85ZC457O757ufPfCfq4ENCuecvOedm+ecvOenkeinhuWKmz3wn5GB77iPDQpY5bCE57q/5ouN54mH5pS+5bCE5qOA5p+lPfCfqbsNCuaYvuW+rumVnOenkeeglOajgOa1i+inguWvnz3wn5SsDQrmuKnluqborqHkvZPmuKnlj5Hng6fmtYvph4898J+Moe+4jw0K5oi05Y+j572p55qE6IS455Sf55eF6Ziy5oqk55ar5oOFPfCfmLcNCuWQq+a4qeW6puiuoeeahOiEuOWPkeeDp+eUn+eXhT3wn6SSDQrmgbblv4PohLjmg7PlkJDkuI3pgII98J+kog0K5ZGV5ZCQ6IS45ZGV5ZCQ6aOf54mp5Lit5q+SPfCfpK4NCuaJk+WWt+Waj+eahOiEuOaEn+WGkui/h+aVjz3wn6SnDQrlpLTmmZXohLjnnKnmmZXphonphZLnpZ7lv5fkuI3muIU98J+ltA0K5b6u55Sf54mp55eF5q+S57uG6I+M55eF5q+S55ar5oOFPfCfpqANCuWPl+S8pOeahOiEuOWktOmDqOWPl+S8pOWMheaJjj3wn6SVDQrniIbngrjlpLTpnIfmg4rnsr7npZ7ltKnmuoM98J+krw0K5Yy76Zmi5bCx5Yy75L2P6Zmi5oCl6K+KPfCfj6UNCuaVkeaKpOi9puaApeaVkee0p+aApeWMu+eWlz3wn5qRDQror5XnrqHlrp7pqozljJbpqozmo4DmtYs98J+nqg0K5Z+55YW755q/57uG6I+M5Z+55YW75b6u55Sf54mp56CU56m2PfCfp6sNCkROQeWfuuWboOWfuuWboOmBl+S8oOeUn+eJqeaKgOacrz3wn6esDQrokrjppo/lmajljJblrabliLboja/ngrzph5HmnK894pqX77iPDQoNCiMjIyMjIyMjIyMjI+OAkPCfmqnml5fluJzjgJENCuaWueagvOaXl+e7iOeCueaXl+i1m+i9pue7iOeCueavlOi1m+e7k+adnz3wn4+BDQrkuInop5Lml5fmoIforrDlnLDngrnpq5jlsJTlpKvnkIPmtJ498J+aqQ0K6buR5peX5rW355uX5oqX6K6u6buR5pqXPfCfj7QNCueZveaXl+aKlemZjeWSjOW5sz3wn4+z77iPDQrlvanombnml5dMR0JUUemqhOWCsuaciD3wn4+z77iP4oCN8J+MiA0K6Leo5oCn5Yir5peX6Leo5oCn5Yir576k5L2T5aSa5YWD5oCn5YirPfCfj7PvuI/igI3imqfvuI8NCua1t+ebl+aXl+a1t+ebl+WGkumZqemqt+mrheaXlz3wn4+04oCN4pig77iPDQo=
;########################################################################################################### emoji.txt
