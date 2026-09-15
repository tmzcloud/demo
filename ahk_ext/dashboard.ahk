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
        A_TrayMenu.Add("退出", (*) => ExitDashboard())
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
    HideLoadSplash()
    guiWin := Gui("+Resize", "本地搜索")
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
            AdditionalBrowserArguments: "--enable-features=msWebView2EnableDraggableRegions --allow-file-access-from-files"
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
.fg{fill:none;stroke:#86efac;stroke-width:8;stroke-linecap:round;
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
    global wv, wvCore, HTML_FILE, SEARCH_DIR, APP_HOST, STORE_HOST, wvBuilding, APP_DIR, pageNavIssued, bootPct, bootStubShown
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
        ; 立刻画圆圈占位，再揭开窗口（点 X 重开不再先空白）
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
    global guiWin, wvBuilding, showWhenReady, wv, wvCore, uiReady, bootPct, mainUiEntered, bootCmdSeq, bootOn, bootRevealDone
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
    ; 已进过主界面：直接露出主 UI，不要再闪进度圈
    if uiReady && mainUiEntered && IsObject(wvCore) {
        bootOn := false
        bootCmdSeq += 1
        ApplyBootToPage(false, 100, "", "", bootCmdSeq)
        SetTimer(FocusSearchBox, -50)
        if evReady || EsAlive()
            SetTimer(() => RunSearch(lastQuery, lastCat, lastSort, 0), -30)
    } else if uiReady {
        SetTimer(RefreshUiOnShow, -1)
    } else
        ShowBootStub("正在加载本地搜索…", "正在加载", Max(8, Integer(bootPct)))
    AppLog("ShowWindow hwnd=" guiWin.Hwnd)
}

; 首次/未进主界面时的唤出同步
RefreshUiOnShow(*) {
    global wvCore, evReady, lastQuery, lastCat, lastSort, mainUiEntered, bootCmdSeq, bootOn, bootPct
    if !IsObject(wvCore) {
        HideLoadSplash()
        return
    }
    if mainUiEntered {
        bootOn := false
        bootPct := 100
        bootCmdSeq += 1
        ApplyBootToPage(false, 100, "", "", bootCmdSeq)
        if evReady || EsAlive()
            SetTimer(() => RunSearch(lastQuery, lastCat, lastSort, 0), -20)
        SetTimer(FocusSearchBox, -40)
        HideLoadSplash()
        return
    }
    SyncBootUi()
    try wvCore.ExecuteScriptAsync("try{document.body&&(document.body.offsetHeight,window.dispatchEvent(new Event('resize')))}catch(e){}")
    if evReady || EsAlive()
        SetTimer(() => RunSearch(lastQuery, lastCat, lastSort, 0), -40)
    SetTimer(FocusSearchBox, -60)
    SetTimer(HideLoadSplash, -80)
}

; 点标题栏 X / 页面关闭 → 只隐藏窗口（保留进程与 Everything，再开秒进）
; 真正退出：托盘「退出」→ ExitDashboard
OnDashboardClose(*) {
    HideWindow()
}

HideWindow() {
    global guiWin
    HideLoadSplash()
    if IsObject(guiWin)
        guiWin.Hide()
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
    global skipKillEverything
    if skipKillEverything
        return
    try StopEverythingService()
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
    ; 已有且版本匹配才跳过；旧黄圈 / 旧闪屏逻辑要强制覆盖（HELPME 数据目录常残留旧文件）
    if FileExist(HTML_FILE) {
        try {
            if FileGetSize(HTML_FILE) > 1000 {
                ; 只读文件头，避免每次 FileRead 整页卡住灰窗
                f := FileOpen(HTML_FILE, "r", "UTF-8")
                sample := IsObject(f) ? f.Read(1200) : ""
                if IsObject(f)
                    f.Close()
                if InStr(sample, "local_search_ui:2026-03-15b") && InStr(sample, "--ring: #86efac") {
                    AppLog("EnsureEmbeddedHtml reuse " HTML_FILE)
                    return
                }
                AppLog("EnsureEmbeddedHtml stale → rewrite " HTML_FILE)
            }
        }
    }
    ; 优先用脚本旁 data\local_search\index.html（避免旧内嵌 base64 覆盖新界面）
    ship := A_ScriptDir "\data\local_search\index.html"
    if FileExist(ship) {
        try {
            f := FileOpen(ship, "r", "UTF-8")
            sample := IsObject(f) ? f.Read(1200) : ""
            if IsObject(f)
                f.Close()
            if InStr(sample, "local_search_ui:2026-03-15b") && InStr(sample, "--ring: #86efac") {
                if ship != HTML_FILE
                    FileCopy(ship, HTML_FILE, 1)
                AppLog("EnsureEmbeddedHtml ship copy " HTML_FILE)
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
        if !EnsureEverythingFiles() {
            PushBoot(true, 8, "组件缺失", "Everything/ES 下载失败，请检查网络后重试。`n将下载到脚本旁 lib\everything\")
            TrayTip "本地搜索", "Everything/ES 组件缺失或下载失败，请检查网络后重试", "Iconx"
            AppLog("EnsureEverythingReady: components missing")
            return
        }
        PushBoot(true, 28, "启动服务", "正在启动 Everything…")
        HideEverythingTrayIcon()
        StartEverythingService()
        HideEverythingTrayIcon()
        PushBoot(true, 42, "磁盘索引中", "正在建立磁盘文件索引，完成后即可搜索。")
        ; IPC 一通即可进主界面；完整索引可在后台继续，不必干等
        if WaitEverythingIndexed(12) {
            evReady := true
            EnterMainUi()
            SetTimer(() => RunSearch("", "all", "date-desc", 0), -80)
        } else {
            SetTimer(PollIndexProgress, 400)
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
        SetTimer(() => RunSearch("", "all", "date-desc", 0), -100)
        return
    }
    if mainUiEntered
        return
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
    global wvCore, bootOn, bootPct, pendingBoot, pendingBootMsg, pendingBootHint, uiReady, mainUiEntered, bootCmdSeq, mainUiEntering
    pct := Integer(pct)
    ; 已进入主界面后禁止再打开 boot（迟到的 ExecuteScript / 轮询会造成闪一下）
    if on && mainUiEntered
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
    ; 已可见一段时间 / 进度已较高 → 短停即进，不再慢爬
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
        global uiReady, evReady, dashboardStandalone, mainUiEntered
        uiReady := true
        SetTimer(WatchUiReady, 0)
        ; 先同步进主界面/真实进度，再揭开遮罩，避免先闪 0%
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
        if evReady || mainUiEntered
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
;PCFET0NUWVBFIGh0bWw+DQo8aHRtbCBsYW5nPSJ6aC1DTiI+DQo8aGVhZD4NCjxtZXRhIGNoYXJzZXQ9IlVURi04Ij4NCjxtZXRhIG5hbWU9InZpZXdwb3J0IiBjb250ZW50PSJ3aWR0aD1kZXZpY2Utd2lkdGgsIGluaXRpYWwtc2NhbGU9MSI+DQo8dGl0bGU+5pys5Zyw5pCc57SiPC90aXRsZT4NCjwhLS0gbG9jYWxfc2VhcmNoX3VpOjIwMjYtMDMtMTVhIC0tPg0KPHN0eWxlPg0KOnJvb3Qgew0KICAtLWJnOiAjZjNmNGY3Ow0KICAtLXBhbmVsOiAjZmZmZmZmOw0KICAtLWxpbmU6ICNlNmU4ZWU7DQogIC0tdHh0OiAjMWYyNDMwOw0KICAtLXR4dDI6ICM2YjcyODU7DQogIC0tdHh0MzogIzlhYTFiMjsNCiAgLS1hY2M6ICMzYjgyZjY7DQogIC0tYWNjMjogIzI1NjNlYjsNCiAgLS1uYW1lOiAjMTExODI3Ow0KICAtLW5hbWUtZXh0OiAjZWE1ODBjOw0KICAtLWhsOiAjZmVmMDhhOw0KICAtLWhsLXRleHQ6ICM4NTRkMGU7DQogIC0tc2VsOiAjZWVmMWY2Ow0KICAtLXNpZGU6ICNmN2Y4ZmI7DQogIC0tc2lkZS13OiAxNDhweDsNCiAgLS1yaW5nOiAjODZlZmFjOw0KICAtLXNoYWRvdzogMCAxMHB4IDMwcHggcmdiYSgyMCwgMjgsIDQ1LCAuMDgpOw0KICAtLXI6IDEwcHg7DQogIGZvbnQtZmFtaWx5OiAiU2Vnb2UgVUkiLCAiTWljcm9zb2Z0IFlhSGVpIFVJIiwgIlBpbmdGYW5nIFNDIiwgc2Fucy1zZXJpZjsNCn0NCiogeyBib3gtc2l6aW5nOiBib3JkZXItYm94OyB9DQpodG1sLCBib2R5IHsgbWFyZ2luOiAwOyBoZWlnaHQ6IDEwMCU7IGJhY2tncm91bmQ6IHZhcigtLWJnKTsgY29sb3I6IHZhcigtLXR4dCk7IG92ZXJmbG93OiBoaWRkZW47IH0NCmJ1dHRvbiwgaW5wdXQgeyBmb250OiBpbmhlcml0OyB9DQojYXBwIHsgZGlzcGxheTogZmxleDsgZmxleC1kaXJlY3Rpb246IGNvbHVtbjsgaGVpZ2h0OiAxMDAlOyB9DQoNCi8qIGluZGV4aW5nICovDQojYm9vdCB7DQogIGRpc3BsYXk6IG5vbmU7IGZsZXg6IDE7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGp1c3RpZnktY29udGVudDogY2VudGVyOw0KICBmbGV4LWRpcmVjdGlvbjogY29sdW1uOyBnYXA6IDI4cHg7IGJhY2tncm91bmQ6ICNmZmY7DQp9DQojYm9vdC5vbiB7IGRpc3BsYXk6IGZsZXg7IH0NCi5yaW5nLXdyYXAgeyB3aWR0aDogMTY4cHg7IGhlaWdodDogMTY4cHg7IHBvc2l0aW9uOiByZWxhdGl2ZTsgfQ0KLnJpbmctd3JhcCBzdmcgeyB3aWR0aDogMTAwJTsgaGVpZ2h0OiAxMDAlOyB0cmFuc2Zvcm06IHJvdGF0ZSgtOTBkZWcpOyB9DQoucmluZy1iZyB7IGZpbGw6IG5vbmU7IHN0cm9rZTogI2VjZWZmNDsgc3Ryb2tlLXdpZHRoOiA4OyB9DQoucmluZy1mZyB7IGZpbGw6IG5vbmU7IHN0cm9rZTogdmFyKC0tcmluZyk7IHN0cm9rZS13aWR0aDogODsgc3Ryb2tlLWxpbmVjYXA6IHJvdW5kOw0KICB0cmFuc2l0aW9uOiBzdHJva2UtZGFzaG9mZnNldCAuMzVzIGVhc2U7IH0NCi5yaW5nLWxhYmVsIHsNCiAgcG9zaXRpb246IGFic29sdXRlOyBpbnNldDogMDsgZGlzcGxheTogZmxleDsgZmxleC1kaXJlY3Rpb246IGNvbHVtbjsNCiAgYWxpZ24taXRlbXM6IGNlbnRlcjsganVzdGlmeS1jb250ZW50OiBjZW50ZXI7IGdhcDogNnB4Ow0KfQ0KLnJpbmctbGFiZWwgLnQxIHsgZm9udC1zaXplOiAxNnB4OyBmb250LXdlaWdodDogNjAwOyB9DQoucmluZy1sYWJlbCAudDIgeyBmb250LXNpemU6IDI4cHg7IGZvbnQtd2VpZ2h0OiA3MDA7IGNvbG9yOiAjMTExODI3OyB9DQouYm9vdC1oaW50IHsgY29sb3I6IHZhcigtLXR4dDIpOyBmb250LXNpemU6IDEzcHg7IG1heC13aWR0aDogNTIwcHg7IHRleHQtYWxpZ246IGNlbnRlcjsgbGluZS1oZWlnaHQ6IDEuNjsgfQ0KLmJvb3QtaGludCBhIHsgY29sb3I6IHZhcigtLWFjYyk7IHRleHQtZGVjb3JhdGlvbjogbm9uZTsgY3Vyc29yOiBwb2ludGVyOyB9DQouYm9vdC1oaW50IGE6aG92ZXIgeyB0ZXh0LWRlY29yYXRpb246IHVuZGVybGluZTsgfQ0KDQovKiBjaHJvbWUgKi8NCiNjaHJvbWUgeyBkaXNwbGF5OiBmbGV4OyBmbGV4LWRpcmVjdGlvbjogY29sdW1uOyBmbGV4OiAxOyBtaW4taGVpZ2h0OiAwOyB9DQojY2hyb21lLmhpZGRlbiB7IGRpc3BsYXk6IG5vbmU7IH0NCiN0b3Agew0KICBoZWlnaHQ6IDQ4cHg7IGRpc3BsYXk6IGdyaWQ7DQogIGdyaWQtdGVtcGxhdGUtY29sdW1uczogdmFyKC0tc2lkZS13KSBtaW5tYXgoMjgwcHgsIDEuMWZyKSBtaW5tYXgoMzIwcHgsIDEuMmZyKTsNCiAgYWxpZ24taXRlbXM6IHN0cmV0Y2g7IHBhZGRpbmc6IDA7IGJhY2tncm91bmQ6ICNmZmY7DQogIGJvcmRlci1ib3R0b206IDFweCBzb2xpZCB2YXIoLS1saW5lKTsNCiAgLXdlYmtpdC1hcHAtcmVnaW9uOiBkcmFnOyBhcHAtcmVnaW9uOiBkcmFnOw0KfQ0KI3RvcCAubm8tZHJhZywgI3RvcCBidXR0b24sICN0b3AgaW5wdXQgew0KICAtd2Via2l0LWFwcC1yZWdpb246IG5vLWRyYWc7IGFwcC1yZWdpb246IG5vLWRyYWc7DQp9DQojZHJpdmUtd3JhcCB7DQogIHBvc2l0aW9uOiByZWxhdGl2ZTsgd2lkdGg6IDEwMCU7DQogIGJvcmRlci1yaWdodDogMXB4IHNvbGlkIHZhcigtLWxpbmUpOyBiYWNrZ3JvdW5kOiB2YXIoLS1zaWRlKTsNCiAgZGlzcGxheTogZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsNCn0NCiNidG4tZHJpdmUgew0KICBkaXNwbGF5OiBmbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBnYXA6IDhweDsNCiAgd2lkdGg6IDEwMCU7IGhlaWdodDogMTAwJTsgcGFkZGluZzogMCAxMHB4Ow0KICBib3JkZXI6IDA7IGJvcmRlci1yYWRpdXM6IDA7IGJhY2tncm91bmQ6IHRyYW5zcGFyZW50Ow0KICBjb2xvcjogdmFyKC0tdHh0KTsgZm9udC1zaXplOiAxMy41cHg7IGZvbnQtd2VpZ2h0OiA2MDA7DQogIGN1cnNvcjogcG9pbnRlcjsgdGV4dC1hbGlnbjogbGVmdDsNCn0NCiNidG4tZHJpdmU6aG92ZXIgeyBiYWNrZ3JvdW5kOiAjZWVmMWY2OyBjb2xvcjogdmFyKC0tYWNjMik7IH0NCiNidG4tZHJpdmUgLmRyaXZlLWljbyB7DQogIHdpZHRoOiAyMHB4OyBoZWlnaHQ6IDIwcHg7IG9iamVjdC1maXQ6IGNvbnRhaW47IGZsZXgtc2hyaW5rOiAwOw0KICBiYWNrZ3JvdW5kOiB0cmFuc3BhcmVudDsNCn0NCiNidG4tZHJpdmUgLmRyaXZlLWljby5oaWRkZW4geyBkaXNwbGF5OiBub25lOyB9DQojYnRuLWRyaXZlIC5jYXJldCB7IGZvbnQtc2l6ZTogMTBweDsgY29sb3I6IHZhcigtLXR4dDMpOyBtYXJnaW4tbGVmdDogYXV0bzsgfQ0KI2RyaXZlLWxhYmVsIHsgb3ZlcmZsb3c6IGhpZGRlbjsgdGV4dC1vdmVyZmxvdzogZWxsaXBzaXM7IHdoaXRlLXNwYWNlOiBub3dyYXA7IH0NCiNkcml2ZS1tZW51IHsNCiAgZGlzcGxheTogbm9uZTsgcG9zaXRpb246IGFic29sdXRlOyB0b3A6IDEwMCU7IGxlZnQ6IDA7IHJpZ2h0OiAwOyB6LWluZGV4OiA0MDsNCiAgd2lkdGg6IDEwMCU7IG1heC1oZWlnaHQ6IDMyMHB4OyBvdmVyZmxvdzogYXV0bzsNCiAgYmFja2dyb3VuZDogI2ZmZjsgYm9yZGVyOiAxcHggc29saWQgdmFyKC0tbGluZSk7IGJvcmRlci10b3A6IDA7DQogIGJveC1zaGFkb3c6IHZhcigtLXNoYWRvdyk7IHBhZGRpbmc6IDRweDsgYm9yZGVyLXJhZGl1czogMCAwIDhweCA4cHg7DQp9DQojZHJpdmUtbWVudS5vbiB7IGRpc3BsYXk6IGJsb2NrOyB9DQojZHJpdmUtbWVudSBidXR0b24gew0KICBkaXNwbGF5OiBmbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBnYXA6IDhweDsgd2lkdGg6IDEwMCU7DQogIHRleHQtYWxpZ246IGxlZnQ7IGJvcmRlcjogMDsgYmFja2dyb3VuZDogdHJhbnNwYXJlbnQ7DQogIHBhZGRpbmc6IDhweCAxMHB4OyBib3JkZXItcmFkaXVzOiA2cHg7IGN1cnNvcjogcG9pbnRlcjsgY29sb3I6IHZhcigtLXR4dCk7IGZvbnQtc2l6ZTogMTNweDsNCn0NCiNkcml2ZS1tZW51IGJ1dHRvbiBpbWcgew0KICB3aWR0aDogMjBweDsgaGVpZ2h0OiAyMHB4OyBvYmplY3QtZml0OiBjb250YWluOyBmbGV4LXNocmluazogMDsgYmFja2dyb3VuZDogdHJhbnNwYXJlbnQ7DQp9DQojZHJpdmUtbWVudSBidXR0b246aG92ZXIgeyBiYWNrZ3JvdW5kOiAjZWVmMmZmOyB9DQojZHJpdmUtbWVudSBidXR0b24ub24geyBiYWNrZ3JvdW5kOiAjZWZmNmZmOyBjb2xvcjogdmFyKC0tYWNjMik7IGZvbnQtd2VpZ2h0OiA2MDA7IH0NCiNzZWFyY2gtd3JhcCB7DQogIGRpc3BsYXk6IGZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IG1pbi13aWR0aDogMDsgaGVpZ2h0OiAxMDAlOw0KICBwYWRkaW5nOiAwIDEycHg7IGJvcmRlci1yaWdodDogMXB4IHNvbGlkIHZhcigtLWxpbmUpOw0KfQ0KI3NlYXJjaC1ib3ggew0KICBwb3NpdGlvbjogcmVsYXRpdmU7IGRpc3BsYXk6IGZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGdhcDogNHB4Ow0KICB3aWR0aDogMTAwJTsgaGVpZ2h0OiAzNHB4Ow0KICBib3JkZXI6IDFweCBzb2xpZCB2YXIoLS1saW5lKTsgYm9yZGVyLXJhZGl1czogOHB4Ow0KICBwYWRkaW5nOiAwIDRweCAwIDEwcHg7IGJhY2tncm91bmQ6ICNmYmZiZmQ7IG92ZXJmbG93OiB2aXNpYmxlOw0KfQ0KI3NlYXJjaC1ib3g6Zm9jdXMtd2l0aGluIHsNCiAgYm9yZGVyLWNvbG9yOiAjOTNjNWZkOw0KICBib3gtc2hhZG93OiAwIDAgMCAzcHggcmdiYSg1OSwxMzAsMjQ2LC4xNSk7DQogIGJhY2tncm91bmQ6ICNmZmY7DQp9DQojcSB7DQogIGZsZXg6IDE7IG1pbi13aWR0aDogMDsgaGVpZ2h0OiAxMDAlOw0KICBib3JkZXI6IDA7IGJvcmRlci1yYWRpdXM6IDA7IHBhZGRpbmc6IDA7IG91dGxpbmU6IG5vbmU7IGJhY2tncm91bmQ6IHRyYW5zcGFyZW50Ow0KICBmb250LXNpemU6IDEzLjVweDsgY29sb3I6IHZhcigtLXR4dCk7DQp9DQojcTo6cGxhY2Vob2xkZXIgeyBjb2xvcjogdmFyKC0tdHh0Myk7IH0NCiNidG4tY2xlYXIgew0KICBkaXNwbGF5OiBub25lOyBmbGV4LXNocmluazogMDsgaGVpZ2h0OiAyMnB4OyBwYWRkaW5nOiAwIDEwcHg7DQogIGJvcmRlcjogMDsgYm9yZGVyLXJhZGl1czogOTk5cHg7IGJhY2tncm91bmQ6ICNlZWYxZjY7DQogIGNvbG9yOiB2YXIoLS10eHQyKTsgZm9udC1zaXplOiAxMnB4OyBjdXJzb3I6IHBvaW50ZXI7IGxpbmUtaGVpZ2h0OiAyMnB4Ow0KfQ0KI2J0bi1jbGVhci5vbiB7IGRpc3BsYXk6IGlubGluZS1mbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBqdXN0aWZ5LWNvbnRlbnQ6IGNlbnRlcjsgfQ0KI2J0bi1jbGVhcjpob3ZlciB7IGJhY2tncm91bmQ6ICNlMmU4ZjA7IGNvbG9yOiB2YXIoLS10eHQpOyB9DQojYnRuLWhpc3Qgew0KICBmbGV4LXNocmluazogMDsgd2lkdGg6IDI0cHg7IGhlaWdodDogMjRweDsgYm9yZGVyOiAwOyBib3JkZXItcmFkaXVzOiA2cHg7DQogIGJhY2tncm91bmQ6IHRyYW5zcGFyZW50OyBjb2xvcjogdmFyKC0tdHh0Myk7IGZvbnQtc2l6ZTogMTBweDsNCiAgY3Vyc29yOiBwb2ludGVyOyBsaW5lLWhlaWdodDogMTsgcGFkZGluZzogMDsNCn0NCiNidG4taGlzdDpob3ZlciwgI2J0bi1oaXN0Lm9uIHsgYmFja2dyb3VuZDogI2VlZjJmZjsgY29sb3I6IHZhcigtLWFjYzIpOyB9DQojaGlzdC1tZW51IHsNCiAgZGlzcGxheTogbm9uZTsgcG9zaXRpb246IGFic29sdXRlOyB0b3A6IDEwMCU7IGxlZnQ6IC0xcHg7IHJpZ2h0OiAtMXB4OyB6LWluZGV4OiA0NTsNCiAgbWF4LWhlaWdodDogMjgwcHg7IG92ZXJmbG93OiBhdXRvOw0KICBiYWNrZ3JvdW5kOiAjZmZmOyBib3JkZXI6IDFweCBzb2xpZCB2YXIoLS1saW5lKTsgYm9yZGVyLXRvcDogMDsNCiAgYm94LXNoYWRvdzogMCA4cHggMThweCByZ2JhKDE1LCAyMywgNDIsIC4wOCk7IHBhZGRpbmc6IDJweCA0cHggNHB4Ow0KICBib3JkZXItcmFkaXVzOiAwIDAgOHB4IDhweDsNCn0NCiNoaXN0LW1lbnUub24geyBkaXNwbGF5OiBibG9jazsgfQ0KI3NlYXJjaC1ib3guaGlzdC1vcGVuIHsNCiAgYm9yZGVyLWJvdHRvbS1sZWZ0LXJhZGl1czogMDsgYm9yZGVyLWJvdHRvbS1yaWdodC1yYWRpdXM6IDA7DQp9DQojaGlzdC1tZW51IGJ1dHRvbiB7DQogIGRpc3BsYXk6IGJsb2NrOyB3aWR0aDogMTAwJTsgdGV4dC1hbGlnbjogbGVmdDsgYm9yZGVyOiAwOyBiYWNrZ3JvdW5kOiB0cmFuc3BhcmVudDsNCiAgcGFkZGluZzogOHB4IDEwcHg7IGJvcmRlci1yYWRpdXM6IDZweDsgY3Vyc29yOiBwb2ludGVyOyBjb2xvcjogdmFyKC0tdHh0KTsNCiAgZm9udC1zaXplOiAxM3B4OyBvdmVyZmxvdzogaGlkZGVuOyB0ZXh0LW92ZXJmbG93OiBlbGxpcHNpczsgd2hpdGUtc3BhY2U6IG5vd3JhcDsNCn0NCiNoaXN0LW1lbnUgYnV0dG9uOmhvdmVyIHsgYmFja2dyb3VuZDogI2YzZjRmNjsgfQ0KI2hpc3QtbWVudSAuaGlzdC1lbXB0eSB7DQogIHBhZGRpbmc6IDEwcHg7IGNvbG9yOiB2YXIoLS10eHQzKTsgZm9udC1zaXplOiAxMnB4OyB0ZXh0LWFsaWduOiBjZW50ZXI7DQp9DQojdG9wLXByZXZpZXcgew0KICBkaXNwbGF5OiBmbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBtaW4td2lkdGg6IDA7IHBhZGRpbmc6IDAgMTRweDsNCiAgYmFja2dyb3VuZDogI2ZmZjsgY29sb3I6IHZhcigtLXR4dDIpOyBmb250LXNpemU6IDEycHg7IG92ZXJmbG93OiBoaWRkZW47DQp9DQojdG9wLXByZXZpZXcgLnB2LW1ldGEgew0KICBib3JkZXI6IDA7IHBhZGRpbmc6IDA7IHdpZHRoOiAxMDAlOw0KICBmbGV4LXdyYXA6IG5vd3JhcDsgb3ZlcmZsb3c6IGhpZGRlbjsNCn0NCg0KI21haW4geyBmbGV4OiAxOyBkaXNwbGF5OiBncmlkOyBncmlkLXRlbXBsYXRlLWNvbHVtbnM6IHZhcigtLXNpZGUtdykgbWlubWF4KDI4MHB4LCAxLjFmcikgbWlubWF4KDMyMHB4LCAxLjJmcik7IG1pbi1oZWlnaHQ6IDA7IH0NCg0KLyogc2lkZSAqLw0KI3NpZGUgew0KICBiYWNrZ3JvdW5kOiB2YXIoLS1zaWRlKTsgYm9yZGVyLXJpZ2h0OiAxcHggc29saWQgdmFyKC0tbGluZSk7DQogIGRpc3BsYXk6IGZsZXg7IGZsZXgtZGlyZWN0aW9uOiBjb2x1bW47IHBhZGRpbmc6IDEwcHggOHB4OyBnYXA6IDJweDsNCn0NCi5jYXQgew0KICBkaXNwbGF5OiBmbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBnYXA6IDEwcHg7IGhlaWdodDogNDJweDsgcGFkZGluZzogMCAxMHB4Ow0KICBib3JkZXI6IDA7IGJvcmRlci1yYWRpdXM6IDhweDsgYmFja2dyb3VuZDogdHJhbnNwYXJlbnQ7IGNvbG9yOiB2YXIoLS10eHQpOyBjdXJzb3I6IHBvaW50ZXI7DQogIHRleHQtYWxpZ246IGxlZnQ7IHBvc2l0aW9uOiByZWxhdGl2ZTsNCn0NCi5jYXQ6aG92ZXIgeyBiYWNrZ3JvdW5kOiAjZWVmMWY2OyB9DQouY2F0Lm9uIHsgYmFja2dyb3VuZDogI2U4ZWJmMjsgZm9udC13ZWlnaHQ6IDYwMDsgfQ0KLmNhdC5vbjo6YmVmb3JlIHsNCiAgY29udGVudDogIiI7IHBvc2l0aW9uOiBhYnNvbHV0ZTsgbGVmdDogMDsgdG9wOiA4cHg7IGJvdHRvbTogOHB4OyB3aWR0aDogM3B4Ow0KICBib3JkZXItcmFkaXVzOiAycHg7IGJhY2tncm91bmQ6IHZhcigtLWFjYyk7DQp9DQouY2F0IC5pY28gew0KICB3aWR0aDogMzJweDsgaGVpZ2h0OiAzMnB4OyBmbGV4LXNocmluazogMDsNCiAgZGlzcGxheTogaW5saW5lLWZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGp1c3RpZnktY29udGVudDogY2VudGVyOw0KICBjb2xvcjogdmFyKC0tdHh0Mik7IGZvbnQtc2l6ZTogMTRweDsgbGluZS1oZWlnaHQ6IDE7DQp9DQouY2F0IGltZy5pY28gew0KICB3aWR0aDogMzJweDsgaGVpZ2h0OiAzMnB4Ow0KICBvYmplY3QtZml0OiBjb250YWluOyBpbWFnZS1yZW5kZXJpbmc6IGF1dG87DQp9DQojc2lkZS1mb290IHsgbWFyZ2luLXRvcDogYXV0bzsgcGFkZGluZzogOHB4IDZweDsgfQ0KI2J0bi1zZXR0aW5ncyB7DQogIHdpZHRoOiAzNHB4OyBoZWlnaHQ6IDM0cHg7IGJvcmRlcjogMDsgYm9yZGVyLXJhZGl1czogOHB4OyBiYWNrZ3JvdW5kOiB0cmFuc3BhcmVudDsNCiAgY29sb3I6IHZhcigtLXR4dDIpOyBjdXJzb3I6IHBvaW50ZXI7DQp9DQojYnRuLXNldHRpbmdzOmhvdmVyIHsgYmFja2dyb3VuZDogI2VlZjFmNjsgY29sb3I6IHZhcigtLXR4dCk7IH0NCg0KLyogbGlzdCAqLw0KI2xpc3QtcGFuZSB7DQogIGRpc3BsYXk6IGZsZXg7IGZsZXgtZGlyZWN0aW9uOiBjb2x1bW47IG1pbi13aWR0aDogMDsgbWluLWhlaWdodDogMDsNCiAgYmFja2dyb3VuZDogI2ZmZjsgYm9yZGVyLXJpZ2h0OiAxcHggc29saWQgdmFyKC0tbGluZSk7IG92ZXJmbG93OiBoaWRkZW47DQp9DQojbGlzdCB7DQogIGZsZXg6IDE7IG1pbi1oZWlnaHQ6IDA7IG92ZXJmbG93LXk6IGF1dG87IG92ZXJmbG93LXg6IGhpZGRlbjsgcGFkZGluZzogNHB4IDA7DQogIHNjcm9sbGJhci13aWR0aDogdGhpbjsgc2Nyb2xsYmFyLWNvbG9yOiAjYzVjOWQ0IHRyYW5zcGFyZW50Ow0KICAtd2Via2l0LW92ZXJmbG93LXNjcm9sbGluZzogdG91Y2g7DQp9DQojbGlzdDo6LXdlYmtpdC1zY3JvbGxiYXIgeyB3aWR0aDogOHB4OyB9DQojbGlzdDo6LXdlYmtpdC1zY3JvbGxiYXItdGh1bWIgeyBiYWNrZ3JvdW5kOiAjYzVjOWQ0OyBib3JkZXItcmFkaXVzOiA0cHg7IH0NCi5yb3cgew0KICBkaXNwbGF5OiBncmlkOyBncmlkLXRlbXBsYXRlLWNvbHVtbnM6IDQwcHggMWZyOyBnYXA6IDEwcHg7DQogIGFsaWduLWl0ZW1zOiBjZW50ZXI7IG1pbi1oZWlnaHQ6IDQ0cHg7DQogIHBhZGRpbmc6IDZweCAxNHB4OyBjdXJzb3I6IHBvaW50ZXI7IGJvcmRlci1sZWZ0OiAzcHggc29saWQgdHJhbnNwYXJlbnQ7DQp9DQoucm93OmhvdmVyIHsgYmFja2dyb3VuZDogI2Y3ZjhmYjsgfQ0KLnJvdy5vbiB7IGJhY2tncm91bmQ6IHZhcigtLXNlbCk7IGJvcmRlci1sZWZ0LWNvbG9yOiB2YXIoLS1hY2MpOyB9DQoucm93IC5maSB7DQogIHdpZHRoOiAzMnB4OyBoZWlnaHQ6IDMycHg7DQogIGNvbG9yOiB2YXIoLS10eHQyKTsgZGlzcGxheTogZ3JpZDsgcGxhY2UtaXRlbXM6IGNlbnRlcjsgZmxleC1zaHJpbms6IDA7DQp9DQoucm93IC5maSBpbWcgew0KICB3aWR0aDogMzJweDsgaGVpZ2h0OiAzMnB4Ow0KICBvYmplY3QtZml0OiBjb250YWluOyBkaXNwbGF5OiBibG9jazsgYmFja2dyb3VuZDogdHJhbnNwYXJlbnQ7DQogIGltYWdlLXJlbmRlcmluZzogYXV0bzsNCn0NCi5yb3cgLmZpIC5maS1mYWxsYmFjayB7IGZvbnQtc2l6ZTogMThweDsgbGluZS1oZWlnaHQ6IDE7IH0NCi5yb3cgLm5hbWUgeyBjb2xvcjogdmFyKC0tbmFtZSk7IGZvbnQtc2l6ZTogMTMuNXB4OyBmb250LXdlaWdodDogNjAwOyB3b3JkLWJyZWFrOiBicmVhay1hbGw7IGxpbmUtaGVpZ2h0OiAxLjM1OyB9DQoucm93IC5uYW1lIC5leHQgeyBjb2xvcjogdmFyKC0tbmFtZS1leHQpOyB9DQoucm93IC5uYW1lIG1hcmssIC5yb3cgLnBhdGggbWFyayB7DQogIGJhY2tncm91bmQ6IHZhcigtLWhsKTsgY29sb3I6IHZhcigtLWhsLXRleHQpOyBwYWRkaW5nOiAwIDFweDsgYm9yZGVyLXJhZGl1czogMnB4Ow0KICBmb250LXdlaWdodDogNzAwOw0KfQ0KLnJvdyAucGF0aCB7IGNvbG9yOiAjNGI1NTYzOyBmb250LXNpemU6IDEycHg7IG1hcmdpbi10b3A6IDJweDsgd29yZC1icmVhazogYnJlYWstYWxsOyB9DQojbGlzdC1lbXB0eSB7DQogIGRpc3BsYXk6IG5vbmU7IGZsZXg6IDE7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGp1c3RpZnktY29udGVudDogY2VudGVyOw0KICBjb2xvcjogdmFyKC0tdHh0Myk7IGZvbnQtc2l6ZTogMTRweDsNCn0NCiNsaXN0LWVtcHR5Lm9uIHsgZGlzcGxheTogZmxleDsgfQ0KDQovKiBwcmV2aWV3ICovDQojcHJldmlldyB7DQogIGJhY2tncm91bmQ6ICNmZmY7IG1pbi13aWR0aDogMDsgbWluLWhlaWdodDogMDsgZGlzcGxheTogZmxleDsgZmxleC1kaXJlY3Rpb246IGNvbHVtbjsgb3ZlcmZsb3c6IGhpZGRlbjsNCn0NCiNwcmV2aWV3Lm9mZiAucHYtYm9keSB7IGRpc3BsYXk6IG5vbmU7IH0NCiNwcmV2aWV3Lm9mZiAucHYtb2ZmIHsNCiAgZGlzcGxheTogZmxleDsgZmxleDogMTsgYWxpZ24taXRlbXM6IGNlbnRlcjsganVzdGlmeS1jb250ZW50OiBjZW50ZXI7IGNvbG9yOiB2YXIoLS10eHQzKTsNCn0NCi5wdi1vZmYgeyBkaXNwbGF5OiBub25lOyB9DQoucHYtbWV0YSB7DQogIGRpc3BsYXk6IGZsZXg7IGdhcDogMTRweDsgYWxpZ24taXRlbXM6IGNlbnRlcjsgcGFkZGluZzogMTBweCAxNHB4Ow0KICBib3JkZXItYm90dG9tOiAxcHggc29saWQgdmFyKC0tbGluZSk7IGNvbG9yOiB2YXIoLS10eHQyKTsgZm9udC1zaXplOiAxMnB4OyBmbGV4LXdyYXA6IHdyYXA7DQp9DQoucHYtbWV0YSBiIHsgY29sb3I6IHZhcigtLXR4dCk7IGZvbnQtd2VpZ2h0OiA2MDA7IH0NCi5wdi1tZXRhIC5kcnYgew0KICBkaXNwbGF5OiBpbmxpbmUtZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsgZ2FwOiA2cHg7DQogIGNvbG9yOiB2YXIoLS10eHQpOyBmb250LXdlaWdodDogNjAwOw0KfQ0KLnB2LW1ldGEgLmRydiBpbWcgew0KICB3aWR0aDogMTZweDsgaGVpZ2h0OiAxNnB4OyBvYmplY3QtZml0OiBjb250YWluOyBiYWNrZ3JvdW5kOiB0cmFuc3BhcmVudDsgZmxleC1zaHJpbms6IDA7DQp9DQoucHYtYm9keSB7IGZsZXg6IDE7IG1pbi1oZWlnaHQ6IDA7IGRpc3BsYXk6IGZsZXg7IGZsZXgtZGlyZWN0aW9uOiBjb2x1bW47IH0NCi5wdi1tZWRpYSB7DQogIGZsZXg6IDE7IG1pbi1oZWlnaHQ6IDA7IGJhY2tncm91bmQ6ICMzZjQ0NTA7IGRpc3BsYXk6IGZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGp1c3RpZnktY29udGVudDogY2VudGVyOw0KICBvdmVyZmxvdzogaGlkZGVuOyBwb3NpdGlvbjogcmVsYXRpdmU7DQp9DQoucHYtbWVkaWEuY29tcGFjdCB7DQogIGZsZXg6IDAgMCBhdXRvOyBtaW4taGVpZ2h0OiAwOyBoZWlnaHQ6IDA7IHBhZGRpbmc6IDA7IG92ZXJmbG93OiBoaWRkZW47DQogIGJvcmRlcjogMDsNCn0NCi5wdi1ib2R5LnRleHQtbW9kZSAucHYtbWVkaWEgeyBkaXNwbGF5OiBub25lOyB9DQoucHYtYm9keS50ZXh0LW1vZGUgLnB2LXRleHQgew0KICBmbGV4OiAxOyBkaXNwbGF5OiBmbGV4OyBib3JkZXItdG9wOiAwOyBtaW4taGVpZ2h0OiAwOw0KfQ0KLnB2LW1lZGlhIGltZywgLnB2LW1lZGlhIHZpZGVvIHsNCiAgbWF4LXdpZHRoOiAxMDAlOyBtYXgtaGVpZ2h0OiAxMDAlOyBvYmplY3QtZml0OiBjb250YWluOyBiYWNrZ3JvdW5kOiAjMTExOw0KfQ0KLnB2LW1lZGlhIC5wdi1maWxlaW5mbyBpbWcuYmlnLWljbyB7DQogIGJhY2tncm91bmQ6IHRyYW5zcGFyZW50ICFpbXBvcnRhbnQ7DQogIG1heC13aWR0aDogNDhweDsgbWF4LWhlaWdodDogNDhweDsNCn0NCi5wdi1tZWRpYSBlbWJlZC5wZGYsIC5wdi1tZWRpYSBpZnJhbWUucGRmIHsNCiAgd2lkdGg6IDEwMCU7IGhlaWdodDogMTAwJTsgYm9yZGVyOiAwOyBiYWNrZ3JvdW5kOiAjNTI1NjU5Ow0KfQ0KLnB2LW1lZGlhIC5waCB7IGNvbG9yOiAjY2JkNWUxOyBmb250LXNpemU6IDEzcHg7IH0NCi5wdi1maWxlaW5mbyB7DQogIGRpc3BsYXk6IGZsZXg7IGZsZXgtZGlyZWN0aW9uOiBjb2x1bW47IGFsaWduLWl0ZW1zOiBzdHJldGNoOyBqdXN0aWZ5LWNvbnRlbnQ6IGNlbnRlcjsNCiAgZ2FwOiAxMHB4OyBwYWRkaW5nOiAyOHB4IDI0cHg7IHRleHQtYWxpZ246IGxlZnQ7IHdpZHRoOiAxMDAlOyBoZWlnaHQ6IDEwMCU7DQogIGJveC1zaXppbmc6IGJvcmRlci1ib3g7IG92ZXJmbG93OiBhdXRvOw0KICBiYWNrZ3JvdW5kOiAjZjdmOGZiOyBjb2xvcjogdmFyKC0tdHh0KTsNCn0NCi5wdi1maWxlaW5mbyAuYmlnLWljbyB7DQogIHdpZHRoOiA0OHB4OyBoZWlnaHQ6IDQ4cHg7IG9iamVjdC1maXQ6IGNvbnRhaW47IGFsaWduLXNlbGY6IGNlbnRlcjsNCiAgYmFja2dyb3VuZDogdHJhbnNwYXJlbnQgIWltcG9ydGFudDsNCiAgaW1hZ2UtcmVuZGVyaW5nOiBhdXRvOyBmbGV4LXNocmluazogMDsNCn0NCi5wdi1tZWRpYTpoYXMoLnB2LWZpbGVpbmZvKSB7IGJhY2tncm91bmQ6ICNmN2Y4ZmI7IH0NCi5wdi1maWxlaW5mbyAuZm4gew0KICBmb250LXNpemU6IDE2cHg7IGZvbnQtd2VpZ2h0OiA2NTA7IGNvbG9yOiB2YXIoLS10eHQpOw0KICB3b3JkLWJyZWFrOiBicmVhay1hbGw7IHRleHQtYWxpZ246IGNlbnRlcjsgd2lkdGg6IDEwMCU7IGxpbmUtaGVpZ2h0OiAxLjM1Ow0KfQ0KLnB2LWZpbGVpbmZvIC50biB7DQogIGZvbnQtc2l6ZTogMTJweDsgY29sb3I6IHZhcigtLXR4dDIpOyB0ZXh0LWFsaWduOiBjZW50ZXI7IHdpZHRoOiAxMDAlOw0KfQ0KLnB2LWZpbGVpbmZvIC5oaW50IHsNCiAgZm9udC1zaXplOiAxMnB4OyBjb2xvcjogI2I0NTMwOTsgdGV4dC1hbGlnbjogY2VudGVyOyB3aWR0aDogMTAwJTsgbGluZS1oZWlnaHQ6IDEuNDU7DQp9DQoucHYtZmlsZWluZm8gLmt2IHsNCiAgZGlzcGxheTogZmxleDsgZmxleC1kaXJlY3Rpb246IGNvbHVtbjsgZ2FwOiA4cHg7DQogIG1hcmdpbi10b3A6IDZweDsgd2lkdGg6IDEwMCU7IGZvbnQtc2l6ZTogMTIuNXB4OyBjb2xvcjogdmFyKC0tdHh0Mik7DQp9DQoucHYtZmlsZWluZm8gLmt2LXJvdyB7DQogIGRpc3BsYXk6IGdyaWQ7IGdyaWQtdGVtcGxhdGUtY29sdW1uczogNC41ZW0gMWZyOyBnYXA6IDEycHg7IGFsaWduLWl0ZW1zOiBzdGFydDsNCiAgbGluZS1oZWlnaHQ6IDEuNTU7DQp9DQoucHYtZmlsZWluZm8gLmt2LXJvdyAuayB7IGNvbG9yOiB2YXIoLS10eHQyKTsgd2hpdGUtc3BhY2U6IG5vd3JhcDsgfQ0KLnB2LWZpbGVpbmZvIC5rdi1yb3cgLnYgeyBjb2xvcjogdmFyKC0tdHh0KTsgd29yZC1icmVhazogYnJlYWstYWxsOyBmb250LXdlaWdodDogNTAwOyB9DQoucHYtZmlsZWluZm8gLmtpZHMgew0KICBtYXJnaW4tdG9wOiA4cHg7IGZvbnQtc2l6ZTogMTIuNXB4OyBjb2xvcjogdmFyKC0tdHh0Mik7IGxpbmUtaGVpZ2h0OiAxLjY7DQogIHdvcmQtYnJlYWs6IGJyZWFrLWFsbDsNCn0NCi5wdi1maWxlaW5mbyAua2lkcyBiIHsgY29sb3I6IHZhcigtLXR4dCk7IGZvbnQtd2VpZ2h0OiA2MDA7IH0NCg0KLyogY29udGV4dCBtZW51ICovDQojY3R4IHsNCiAgZGlzcGxheTogbm9uZTsgcG9zaXRpb246IGZpeGVkOyB6LWluZGV4OiAyMDA7IG1pbi13aWR0aDogMTY4cHg7DQogIHBhZGRpbmc6IDRweDsgYmFja2dyb3VuZDogI2ZmZjsgYm9yZGVyOiAxcHggc29saWQgdmFyKC0tbGluZSk7DQogIGJvcmRlci1yYWRpdXM6IDhweDsgYm94LXNoYWRvdzogMCA4cHggMjRweCByZ2JhKDE1LDIzLDQyLC4xMik7DQp9DQojY3R4Lm9uIHsgZGlzcGxheTogYmxvY2s7IH0NCiNjdHggYnV0dG9uIHsNCiAgZGlzcGxheTogZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsgZ2FwOiAxMHB4OyB3aWR0aDogMTAwJTsNCiAgYm9yZGVyOiAwOyBiYWNrZ3JvdW5kOiB0cmFuc3BhcmVudDsgcGFkZGluZzogOHB4IDEwcHg7IGJvcmRlci1yYWRpdXM6IDZweDsNCiAgY3Vyc29yOiBwb2ludGVyOyBjb2xvcjogdmFyKC0tdHh0KTsgZm9udC1zaXplOiAxM3B4OyB0ZXh0LWFsaWduOiBsZWZ0Ow0KfQ0KI2N0eCBidXR0b246aG92ZXIgeyBiYWNrZ3JvdW5kOiAjZjNmNGY2OyB9DQojY3R4IGJ1dHRvbi5kYW5nZXIgeyBjb2xvcjogI2RjMjYyNjsgfQ0KI2N0eCBidXR0b24uZGFuZ2VyOmhvdmVyIHsgYmFja2dyb3VuZDogI2ZlZjJmMjsgfQ0KI2N0eCAuYy1pY28gew0KICB3aWR0aDogMTZweDsgaGVpZ2h0OiAxNnB4OyBmbGV4LXNocmluazogMDsNCiAgZGlzcGxheTogaW5saW5lLWZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGp1c3RpZnktY29udGVudDogY2VudGVyOw0KICBjb2xvcjogIzM3NDE1MTsNCn0NCiNjdHggYnV0dG9uLmRhbmdlciAuYy1pY28geyBjb2xvcjogI2RjMjYyNjsgfQ0KI2N0eCAuYy1pY28gc3ZnIHsgd2lkdGg6IDE2cHg7IGhlaWdodDogMTZweDsgZGlzcGxheTogYmxvY2s7IH0NCg0KLnB2LXRleHQgew0KICBmbGV4OiAxOyBtaW4taGVpZ2h0OiAwOyBkaXNwbGF5OiBmbGV4OyBmbGV4LWRpcmVjdGlvbjogY29sdW1uOyBib3JkZXItdG9wOiAxcHggc29saWQgdmFyKC0tbGluZSk7DQp9DQoucHYtdGV4dCAuaGQgew0KICBwYWRkaW5nOiA4cHggMTRweDsgZm9udC1zaXplOiAxMnB4OyBjb2xvcjogdmFyKC0tdHh0Mik7IGJhY2tncm91bmQ6ICNmYWZiZmM7IGJvcmRlci1ib3R0b206IDFweCBzb2xpZCB2YXIoLS1saW5lKTsNCn0NCi5wdi10ZXh0IHByZSB7DQogIG1hcmdpbjogMDsgZmxleDogMTsgb3ZlcmZsb3c6IGF1dG87IHBhZGRpbmc6IDEycHggMTRweDsgZm9udC1zaXplOiAxMnB4OyBsaW5lLWhlaWdodDogMS41Ow0KICB3aGl0ZS1zcGFjZTogcHJlLXdyYXA7IHdvcmQtYnJlYWs6IGJyZWFrLXdvcmQ7IGZvbnQtZmFtaWx5OiBDb25zb2xhcywgIlNhcmFzYSBNb25vIFNDIiwgbW9ub3NwYWNlOw0KICBiYWNrZ3JvdW5kOiAjZmZmOyBjb2xvcjogIzExMTgyNzsNCn0NCg0KLyogYm90dG9tICovDQojYmFyIHsNCiAgaGVpZ2h0OiA0MnB4OyBkaXNwbGF5OiBmbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBnYXA6IDE2cHg7DQogIHBhZGRpbmc6IDAgMTRweDsgYmFja2dyb3VuZDogI2ZmZjsgYm9yZGVyLXRvcDogMXB4IHNvbGlkIHZhcigtLWxpbmUpOyBmb250LXNpemU6IDEyLjVweDsgY29sb3I6IHZhcigtLXR4dDIpOw0KfQ0KI2JhciAuc29ydCB7IGRpc3BsYXk6IGlubGluZS1mbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBnYXA6IDZweDsgY3Vyc29yOiBwb2ludGVyOyBib3JkZXI6IDA7IGJhY2tncm91bmQ6IHRyYW5zcGFyZW50OyBjb2xvcjogaW5oZXJpdDsgfQ0KI2JhciAuc29ydDpob3ZlciB7IGNvbG9yOiB2YXIoLS10eHQpOyB9DQojYmFyIC5zcGFjZXIgeyBmbGV4OiAxOyB9DQoudG9nZ2xlIHsNCiAgZGlzcGxheTogaW5saW5lLWZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGdhcDogOHB4OyBjdXJzb3I6IHBvaW50ZXI7IHVzZXItc2VsZWN0OiBub25lOw0KfQ0KLnRvZ2dsZSBpbnB1dCB7IGRpc3BsYXk6IG5vbmU7IH0NCi50b2dnbGUgLnN3IHsNCiAgd2lkdGg6IDM2cHg7IGhlaWdodDogMjBweDsgYm9yZGVyLXJhZGl1czogOTk5cHg7IGJhY2tncm91bmQ6ICNkMWQ1ZGI7IHBvc2l0aW9uOiByZWxhdGl2ZTsgdHJhbnNpdGlvbjogLjJzOw0KfQ0KLnRvZ2dsZSAuc3c6OmFmdGVyIHsNCiAgY29udGVudDogIiI7IHBvc2l0aW9uOiBhYnNvbHV0ZTsgdG9wOiAycHg7IGxlZnQ6IDJweDsgd2lkdGg6IDE2cHg7IGhlaWdodDogMTZweDsNCiAgYm9yZGVyLXJhZGl1czogNTAlOyBiYWNrZ3JvdW5kOiAjZmZmOyB0cmFuc2l0aW9uOiAuMnM7IGJveC1zaGFkb3c6IDAgMXB4IDJweCByZ2JhKDAsMCwwLC4yKTsNCn0NCi50b2dnbGUgaW5wdXQ6Y2hlY2tlZCArIC5zdyB7IGJhY2tncm91bmQ6IHZhcigtLWFjYyk7IH0NCi50b2dnbGUgaW5wdXQ6Y2hlY2tlZCArIC5zdzo6YWZ0ZXIgeyBsZWZ0OiAxOHB4OyB9DQojY291bnQgeyBjb2xvcjogdmFyKC0tdHh0KTsgZm9udC12YXJpYW50LW51bWVyaWM6IHRhYnVsYXItbnVtczsgfQ0KPC9zdHlsZT4NCjwvaGVhZD4NCjxib2R5Pg0KPGRpdiBpZD0iYXBwIj4NCiAgPGRpdiBpZD0iYm9vdCIgY2xhc3M9Im9uIj4NCiAgICA8ZGl2IGNsYXNzPSJyaW5nLXdyYXAiPg0KICAgICAgPHN2ZyB2aWV3Qm94PSIwIDAgMTIwIDEyMCI+DQogICAgICAgIDxjaXJjbGUgY2xhc3M9InJpbmctYmciIGN4PSI2MCIgY3k9IjYwIiByPSI1MiI+PC9jaXJjbGU+DQogICAgICAgIDxjaXJjbGUgaWQ9InJpbmctZmciIGNsYXNzPSJyaW5nLWZnIiBjeD0iNjAiIGN5PSI2MCIgcj0iNTIiDQogICAgICAgICAgc3Ryb2tlLWRhc2hhcnJheT0iMzI2LjczIiBzdHJva2UtZGFzaG9mZnNldD0iMzI2LjczIj48L2NpcmNsZT4NCiAgICAgIDwvc3ZnPg0KICAgICAgPGRpdiBjbGFzcz0icmluZy1sYWJlbCI+DQogICAgICAgIDxkaXYgY2xhc3M9InQxIj7no4Hnm5jntKLlvJXkuK08L2Rpdj4NCiAgICAgICAgPGRpdiBjbGFzcz0idDIiIGlkPSJib290LXBjdCI+4oCmPC9kaXY+DQogICAgICA8L2Rpdj4NCiAgICA8L2Rpdj4NCiAgICA8ZGl2IGNsYXNzPSJib290LWhpbnQiPg0KICAgICAg5q2j5Zyo5bu656uL56OB55uY5paH5Lu257Si5byV77yM5a6M5oiQ5ZCO5Y2z5Y+v5pCc57Si44CCPGJyPg0KICAgICAg6Iul5pys5py65bey5a6J6KOFIEV2ZXJ5dGhpbmcg5bm25byA5py65ZCv5Yqo77yM5LiL5qyh5Lya5pu05b+r5bCx57uq44CCDQogICAgPC9kaXY+DQogIDwvZGl2Pg0KDQogIDxkaXYgaWQ9ImNocm9tZSIgY2xhc3M9ImhpZGRlbiI+DQogICAgPGRpdiBpZD0idG9wIj4NCiAgICAgIDxkaXYgaWQ9ImRyaXZlLXdyYXAiIGNsYXNzPSJuby1kcmFnIj4NCiAgICAgICAgPGJ1dHRvbiBpZD0iYnRuLWRyaXZlIiB0eXBlPSJidXR0b24iIHRpdGxlPSLpgInmi6nmkJzntKLno4Hnm5giPg0KICAgICAgICAgIDxpbWcgaWQ9ImRyaXZlLWJ0bi1pY28iIGNsYXNzPSJkcml2ZS1pY28gaGlkZGVuIiBhbHQ9IiIgd2lkdGg9IjIwIiBoZWlnaHQ9IjIwIj4NCiAgICAgICAgICA8c3BhbiBpZD0iZHJpdmUtbGFiZWwiPuWFqOebmOaQnOe0ojwvc3Bhbj48c3BhbiBjbGFzcz0iY2FyZXQiPuKWvjwvc3Bhbj4NCiAgICAgICAgPC9idXR0b24+DQogICAgICAgIDxkaXYgaWQ9ImRyaXZlLW1lbnUiIHJvbGU9Im1lbnUiPjwvZGl2Pg0KICAgICAgPC9kaXY+DQogICAgICA8ZGl2IGlkPSJzZWFyY2gtd3JhcCIgY2xhc3M9Im5vLWRyYWciPg0KICAgICAgICA8ZGl2IGlkPSJzZWFyY2gtYm94Ij4NCiAgICAgICAgICA8aW5wdXQgaWQ9InEiIHR5cGU9InRleHQiIHBsYWNlaG9sZGVyPSLovpPlhaXmlofku7blkI0gLyDmianlsZXlkI0gLyDot6/lvoTlhbPplK7lrZfvvJt8IOihqOekuuS4lO+8jHx8IOihqOekuuaIliIgYXV0b2NvbXBsZXRlPSJvZmYiIHNwZWxsY2hlY2s9ImZhbHNlIj4NCiAgICAgICAgICA8YnV0dG9uIGlkPSJidG4tY2xlYXIiIHR5cGU9ImJ1dHRvbiIgdGl0bGU9Iua4heepuuaQnOe0oiI+5riF56m6PC9idXR0b24+DQogICAgICAgICAgPGJ1dHRvbiBpZD0iYnRuLWhpc3QiIHR5cGU9ImJ1dHRvbiIgdGl0bGU9IuacgOi/keaQnOe0oiI+4pa+PC9idXR0b24+DQogICAgICAgICAgPGRpdiBpZD0iaGlzdC1tZW51IiByb2xlPSJtZW51Ij48L2Rpdj4NCiAgICAgICAgPC9kaXY+DQogICAgICA8L2Rpdj4NCiAgICAgIDxkaXYgaWQ9InRvcC1wcmV2aWV3IiBjbGFzcz0ibm8tZHJhZyI+DQogICAgICAgIDxkaXYgY2xhc3M9InB2LW1ldGEiIGlkPSJwdi1tZXRhIj7pgInmi6nmlofku7bku6XpooTop4g8L2Rpdj4NCiAgICAgIDwvZGl2Pg0KICAgIDwvZGl2Pg0KDQogICAgPGRpdiBpZD0ibWFpbiI+DQogICAgICA8YXNpZGUgaWQ9InNpZGUiPg0KICAgICAgICA8YnV0dG9uIGNsYXNzPSJjYXQgb24iIGRhdGEtY2F0PSJhbGwiPjxzcGFuIGNsYXNzPSJpY28iIGRhdGEtY2F0LWljbz0iYWxsIj7imLA8L3NwYW4+5YWo6YOoPC9idXR0b24+DQogICAgICAgIDxidXR0b24gY2xhc3M9ImNhdCIgZGF0YS1jYXQ9ImZvbGRlciI+PHNwYW4gY2xhc3M9ImljbyIgZGF0YS1jYXQtaWNvPSJmb2xkZXIiPvCfk4E8L3NwYW4+5paH5Lu25aS5PC9idXR0b24+DQogICAgICAgIDxidXR0b24gY2xhc3M9ImNhdCIgZGF0YS1jYXQ9ImV4Y2VsIj48c3BhbiBjbGFzcz0iaWNvIiBkYXRhLWNhdC1pY289ImV4Y2VsIj7wn5OKPC9zcGFuPkVYQ0VMPC9idXR0b24+DQogICAgICAgIDxidXR0b24gY2xhc3M9ImNhdCIgZGF0YS1jYXQ9IndvcmQiPjxzcGFuIGNsYXNzPSJpY28iIGRhdGEtY2F0LWljbz0id29yZCI+8J+ThDwvc3Bhbj5XT1JEPC9idXR0b24+DQogICAgICAgIDxidXR0b24gY2xhc3M9ImNhdCIgZGF0YS1jYXQ9InBwdCI+PHNwYW4gY2xhc3M9ImljbyIgZGF0YS1jYXQtaWNvPSJwcHQiPvCfk5E8L3NwYW4+UFBUPC9idXR0b24+DQogICAgICAgIDxidXR0b24gY2xhc3M9ImNhdCIgZGF0YS1jYXQ9InBkZiI+PHNwYW4gY2xhc3M9ImljbyIgZGF0YS1jYXQtaWNvPSJwZGYiPvCfk5U8L3NwYW4+UERGPC9idXR0b24+DQogICAgICAgIDxidXR0b24gY2xhc3M9ImNhdCIgZGF0YS1jYXQ9ImltYWdlIj48c3BhbiBjbGFzcz0iaWNvIiBkYXRhLWNhdC1pY289ImltYWdlIj7wn5a8PC9zcGFuPuWbvueJhzwvYnV0dG9uPg0KICAgICAgICA8YnV0dG9uIGNsYXNzPSJjYXQiIGRhdGEtY2F0PSJ2aWRlbyI+PHNwYW4gY2xhc3M9ImljbyIgZGF0YS1jYXQtaWNvPSJ2aWRlbyI+4pa2PC9zcGFuPuinhumikTwvYnV0dG9uPg0KICAgICAgICA8YnV0dG9uIGNsYXNzPSJjYXQiIGRhdGEtY2F0PSJhdWRpbyI+PHNwYW4gY2xhc3M9ImljbyIgZGF0YS1jYXQtaWNvPSJhdWRpbyI+4pmqPC9zcGFuPumfs+mikTwvYnV0dG9uPg0KICAgICAgICA8YnV0dG9uIGNsYXNzPSJjYXQiIGRhdGEtY2F0PSJ6aXAiPjxzcGFuIGNsYXNzPSJpY28iIGRhdGEtY2F0LWljbz0iemlwIj7wn5ecPC9zcGFuPuWOi+e8qeaWh+S7tjwvYnV0dG9uPg0KICAgICAgICA8ZGl2IGlkPSJzaWRlLWZvb3QiPg0KICAgICAgICAgIDxidXR0b24gaWQ9ImJ0bi1zZXR0aW5ncyIgdHlwZT0iYnV0dG9uIiB0aXRsZT0i6K6+572uIj7impk8L2J1dHRvbj4NCiAgICAgICAgPC9kaXY+DQogICAgICA8L2FzaWRlPg0KDQogICAgICA8c2VjdGlvbiBpZD0ibGlzdC1wYW5lIj4NCiAgICAgICAgPGRpdiBpZD0ibGlzdCI+PC9kaXY+DQogICAgICAgIDxkaXYgaWQ9Imxpc3QtZW1wdHkiPui+k+WFpeWFs+mUruWtl+W8gOWni+aQnOe0ou+8jOaIlumAieaLqeW3puS+p+WIhuexu+a1j+iniDwvZGl2Pg0KICAgICAgPC9zZWN0aW9uPg0KDQogICAgICA8c2VjdGlvbiBpZD0icHJldmlldyI+DQogICAgICAgIDxkaXYgY2xhc3M9InB2LWJvZHkiIGlkPSJwdi1ib2R5Ij4NCiAgICAgICAgICA8ZGl2IGNsYXNzPSJwdi1tZWRpYSIgaWQ9InB2LW1lZGlhIj48ZGl2IGNsYXNzPSJwaCI+6aKE6KeI5Yy6PC9kaXY+PC9kaXY+DQogICAgICAgICAgPGRpdiBjbGFzcz0icHYtdGV4dCIgaWQ9InB2LXRleHQiIHN0eWxlPSJkaXNwbGF5Om5vbmUiPg0KICAgICAgICAgICAgPGRpdiBjbGFzcz0iaGQiIGlkPSJwdi10ZXh0LWhkIj7pooTop4jliY0gMjBLQiDlhoXlrrk8L2Rpdj4NCiAgICAgICAgICAgIDxwcmUgaWQ9InB2LXByZSI+PC9wcmU+DQogICAgICAgICAgPC9kaXY+DQogICAgICAgIDwvZGl2Pg0KICAgICAgICA8ZGl2IGNsYXNzPSJwdi1vZmYiPuW3suWFs+mXreaWh+S7tumihOiniDwvZGl2Pg0KICAgICAgPC9zZWN0aW9uPg0KICAgIDwvZGl2Pg0KDQogICAgPGRpdiBpZD0iYmFyIj4NCiAgICAgIDxidXR0b24gY2xhc3M9InNvcnQiIGlkPSJidG4tc29ydCIgdHlwZT0iYnV0dG9uIiB0aXRsZT0i5YiH5o2i5o6S5bqPIj7ih4UgPHNwYW4gaWQ9InNvcnQtbGFiZWwiPuaMieS/ruaUueaXtumXtOmZjeW6jzwvc3Bhbj48L2J1dHRvbj4NCiAgICAgIDxsYWJlbCBjbGFzcz0idG9nZ2xlIiB0aXRsZT0i5byA5ZCvL+WFs+mXreWPs+S+p+mihOiniCI+DQogICAgICAgIDxpbnB1dCB0eXBlPSJjaGVja2JveCIgaWQ9ImNoay1wcmV2aWV3IiBjaGVja2VkPg0KICAgICAgICA8c3BhbiBjbGFzcz0ic3ciPjwvc3Bhbj4NCiAgICAgICAgPHNwYW4+5byA5ZCv5paH5Lu26aKE6KeIPC9zcGFuPg0KICAgICAgPC9sYWJlbD4NCiAgICAgIDxkaXYgY2xhc3M9InNwYWNlciI+PC9kaXY+DQogICAgICA8ZGl2IGlkPSJjb3VudCI+5YWxIDAg5p2h57uT5p6cPC9kaXY+DQogICAgPC9kaXY+DQogIDwvZGl2Pg0KDQogIDxkaXYgaWQ9ImN0eCIgcm9sZT0ibWVudSI+DQogICAgPGJ1dHRvbiB0eXBlPSJidXR0b24iIGRhdGEtYWN0PSJyZXZlYWwiPjxzcGFuIGNsYXNzPSJjLWljbyI+PHN2ZyB2aWV3Qm94PSIwIDAgMjQgMjQiIGZpbGw9Im5vbmUiIHN0cm9rZT0iY3VycmVudENvbG9yIiBzdHJva2Utd2lkdGg9IjEuOCI+PHBhdGggZD0iTTMgNy41QTEuNSAxLjUgMCAwIDEgNC41IDZIOWwyIDJoOC41QTEuNSAxLjUgMCAwIDEgMjEgOS41djdBMS41IDEuNSAwIDAgMSAxOS41IDE4aC0xNUExLjUgMS41IDAgMCAxIDMgMTYuNXYtOXoiLz48L3N2Zz48L3NwYW4+5paH5Lu25aS55Lit5pi+56S6PC9idXR0b24+DQogICAgPGJ1dHRvbiB0eXBlPSJidXR0b24iIGRhdGEtYWN0PSJjb3B5Ij48c3BhbiBjbGFzcz0iYy1pY28iPjxzdmcgdmlld0JveD0iMCAwIDI0IDI0IiBmaWxsPSJub25lIiBzdHJva2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIxLjgiPjxyZWN0IHg9IjgiIHk9IjgiIHdpZHRoPSIxMSIgaGVpZ2h0PSIxMSIgcng9IjEuNSIvPjxwYXRoIGQ9Ik01IDE1VjUuNUExLjUgMS41IDAgMCAxIDYuNSA0SDE1Ii8+PC9zdmc+PC9zcGFuPuWkjeWItjwvYnV0dG9uPg0KICAgIDxidXR0b24gdHlwZT0iYnV0dG9uIiBkYXRhLWFjdD0iY29weVBhdGgiPjxzcGFuIGNsYXNzPSJjLWljbyI+PHN2ZyB2aWV3Qm94PSIwIDAgMjQgMjQiIGZpbGw9Im5vbmUiIHN0cm9rZT0iY3VycmVudENvbG9yIiBzdHJva2Utd2lkdGg9IjEuOCI+PHBhdGggZD0iTTggMTJoOCIvPjxwYXRoIGQ9Ik0xMCA3SDcuNUEyLjUgMi41IDAgMCAwIDUgOS41djVBMi41IDIuNSAwIDAgMCA3LjUgMTdIMTAiLz48cGF0aCBkPSJNMTQgN2gyLjVBMi41IDIuNSAwIDAgMSAxOSA5LjV2NUEyLjUgMi41IDAgMCAxIDE2LjUgMTdIMTQiLz48L3N2Zz48L3NwYW4+5aSN5Yi26Lev5b6EPC9idXR0b24+DQogICAgPGJ1dHRvbiB0eXBlPSJidXR0b24iIGRhdGEtYWN0PSJjb3B5RGlyIj48c3BhbiBjbGFzcz0iYy1pY28iPjxzdmcgdmlld0JveD0iMCAwIDI0IDI0IiBmaWxsPSJub25lIiBzdHJva2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIxLjgiPjxwYXRoIGQ9Ik05IDguNWEzLjUgMy41IDAgMCAxIDUuNi0yLjhsMS43IDEuNGEzLjUgMy41IDAgMCAxLTIuMiA2LjJIMTMiLz48cGF0aCBkPSJNMTUgMTUuNWEzLjUgMy41IDAgMCAxLTUuNiAyLjhsLTEuNy0xLjRhMy41IDMuNSAwIDAgMSAyLjItNi4ySDExIi8+PC9zdmc+PC9zcGFuPuWkjeWItuaJgOWcqOi3r+W+hDwvYnV0dG9uPg0KICAgIDxidXR0b24gdHlwZT0iYnV0dG9uIiBkYXRhLWFjdD0icmVjeWNsZSIgY2xhc3M9ImRhbmdlciI+PHNwYW4gY2xhc3M9ImMtaWNvIj48c3ZnIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0cm9rZS13aWR0aD0iMS44Ij48cGF0aCBkPSJNNSA4aDE0Ii8+PHBhdGggZD0iTTkgOFY2LjVBMS41IDEuNSAwIDAgMSAxMC41IDVoM0ExLjUgMS41IDAgMCAxIDE1IDYuNVY4Ii8+PHBhdGggZD0iTTcuNSA4bC43IDExYTEuNSAxLjUgMCAwIDAgMS41IDEuNGg0LjZhMS41IDEuNSAwIDAgMCAxLjUtMS40bC43LTExIi8+PC9zdmc+PC9zcGFuPuWIoOmZpCjlm57mlLbnq5kpPC9idXR0b24+DQogIDwvZGl2Pg0KPC9kaXY+DQo8c2NyaXB0Pg0KKCgpID0+IHsNCiAgY29uc3QgYm9vdCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdib290Jyk7DQogIGNvbnN0IGNocm9tZSA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjaHJvbWUnKTsNCiAgY29uc3QgcmluZ0ZnID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3JpbmctZmcnKTsNCiAgY29uc3QgYm9vdFBjdCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdib290LXBjdCcpOw0KICBjb25zdCBxRWwgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgncScpOw0KICBjb25zdCBsaXN0RWwgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbGlzdCcpOw0KICBjb25zdCBlbXB0eUVsID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2xpc3QtZW1wdHknKTsNCiAgY29uc3QgY291bnRFbCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjb3VudCcpOw0KICBjb25zdCBwdk1ldGEgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgncHYtbWV0YScpOw0KICBjb25zdCBwdk1lZGlhID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3B2LW1lZGlhJyk7DQogIGNvbnN0IHB2VGV4dCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdwdi10ZXh0Jyk7DQogIGNvbnN0IHB2Qm9keSA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdwdi1ib2R5Jyk7DQogIGNvbnN0IHB2UHJlID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3B2LXByZScpOw0KICBjb25zdCBwdlRleHRIZCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdwdi10ZXh0LWhkJyk7DQogIGNvbnN0IHByZXZpZXcgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgncHJldmlldycpOw0KICBjb25zdCBjaGtQcmV2aWV3ID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2Noay1wcmV2aWV3Jyk7DQogIGNvbnN0IHNvcnRMYWJlbCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzb3J0LWxhYmVsJyk7DQogIGNvbnN0IENJUkMgPSAyICogTWF0aC5QSSAqIDUyOw0KDQogIGxldCBjYXQgPSAnYWxsJzsNCiAgbGV0IHNvcnQgPSAnZGF0ZS1kZXNjJzsNCiAgbGV0IGRyaXZlID0gJyc7IC8vICcnID0gYWxsIGRpc2tzLCAnQycgLyAnRCcgLyAuLi4NCiAgbGV0IGl0ZW1zID0gW107DQogIGxldCBzZWxlY3RlZCA9IC0xOw0KICBsZXQgcHJldmlld09uID0gdHJ1ZTsNCiAgbGV0IHNlYXJjaFRpbWVyID0gMDsNCiAgbGV0IGdlbiA9IDA7DQogIGxldCB0b3RhbEhpdHMgPSAwOw0KICBsZXQgbG9hZGluZ01vcmUgPSBmYWxzZTsNCiAgbGV0IGhhc01vcmUgPSBmYWxzZTsNCg0KICBjb25zdCBkcml2ZUxhYmVsID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2RyaXZlLWxhYmVsJyk7DQogIGNvbnN0IGRyaXZlTWVudSA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdkcml2ZS1tZW51Jyk7DQogIGNvbnN0IGJ0bkRyaXZlID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2J0bi1kcml2ZScpOw0KICBjb25zdCBkcml2ZUJ0bkljbyA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdkcml2ZS1idG4taWNvJyk7DQogIGxldCBkcml2ZU1ldGEgPSB7IGNvbXB1dGVyOiAnJywgZHJpdmVzOiBbXSB9Ow0KDQogIGZ1bmN0aW9uIGRyaXZlVGV4dCgpIHsNCiAgICBpZiAoIWRyaXZlKSByZXR1cm4gJ+WFqOebmOaQnOe0oic7DQogICAgY29uc3QgaGl0ID0gKGRyaXZlTWV0YS5kcml2ZXMgfHwgW10pLmZpbmQoZCA9PiBTdHJpbmcoZC5sZXR0ZXIgfHwgJycpLnRvVXBwZXJDYXNlKCkgPT09IGRyaXZlKTsNCiAgICBpZiAoaGl0ICYmIGhpdC5sYWJlbCkgcmV0dXJuIGhpdC5sYWJlbDsNCiAgICByZXR1cm4gZHJpdmUudG9VcHBlckNhc2UoKSArICcg55uYJzsNCiAgfQ0KICBmdW5jdGlvbiBzZXRCdG5JY29uKHVybCkgew0KICAgIGlmICh1cmwpIHsNCiAgICAgIGRyaXZlQnRuSWNvLnNyYyA9IHVybCArICh1cmwuaW5jbHVkZXMoJz8nKSA/ICcmJyA6ICc/JykgKyAndD0nICsgRGF0ZS5ub3coKTsNCiAgICAgIGRyaXZlQnRuSWNvLmNsYXNzTGlzdC5yZW1vdmUoJ2hpZGRlbicpOw0KICAgIH0gZWxzZSB7DQogICAgICBkcml2ZUJ0bkljby5yZW1vdmVBdHRyaWJ1dGUoJ3NyYycpOw0KICAgICAgZHJpdmVCdG5JY28uY2xhc3NMaXN0LmFkZCgnaGlkZGVuJyk7DQogICAgfQ0KICB9DQogIGZ1bmN0aW9uIHN5bmNEcml2ZUJ1dHRvbigpIHsNCiAgICBkcml2ZUxhYmVsLnRleHRDb250ZW50ID0gZHJpdmVUZXh0KCk7DQogICAgaWYgKCFkcml2ZSkgc2V0QnRuSWNvbihkcml2ZU1ldGEuY29tcHV0ZXIgfHwgJycpOw0KICAgIGVsc2Ugew0KICAgICAgY29uc3QgaGl0ID0gKGRyaXZlTWV0YS5kcml2ZXMgfHwgW10pLmZpbmQoZCA9PiBTdHJpbmcoZC5sZXR0ZXIgfHwgJycpLnRvVXBwZXJDYXNlKCkgPT09IGRyaXZlKTsNCiAgICAgIHNldEJ0bkljb24oKGhpdCAmJiBoaXQuaWNvbikgfHwgZHJpdmVNZXRhLmNvbXB1dGVyIHx8ICcnKTsNCiAgICB9DQogIH0NCiAgZnVuY3Rpb24gaWNvSHRtbCh1cmwpIHsNCiAgICByZXR1cm4gdXJsID8gJzxpbWcgc3JjPSInICsgU3RyaW5nKHVybCkucmVwbGFjZSgvIi9nLCAnJykgKyAnIiBhbHQ9IiI+JyA6ICcnOw0KICB9DQogIGZ1bmN0aW9uIHJlbmRlckRyaXZlTWVudSgpIHsNCiAgICBjb25zdCBkcml2ZXMgPSBBcnJheS5pc0FycmF5KGRyaXZlTWV0YS5kcml2ZXMpID8gZHJpdmVNZXRhLmRyaXZlcyA6IFtdOw0KICAgIGxldCBodG1sID0gJzxidXR0b24gdHlwZT0iYnV0dG9uIiBkYXRhLWRyaXZlPSIiJyArICghZHJpdmUgPyAnIGNsYXNzPSJvbiInIDogJycpICsgJz4nDQogICAgICArIGljb0h0bWwoZHJpdmVNZXRhLmNvbXB1dGVyKSArICc8c3Bhbj7lhajnm5jmkJzntKI8L3NwYW4+PC9idXR0b24+JzsNCiAgICBmb3IgKGNvbnN0IGQgb2YgZHJpdmVzKSB7DQogICAgICBjb25zdCBsZXR0ZXIgPSBTdHJpbmcoZC5sZXR0ZXIgfHwgZCB8fCAnJykucmVwbGFjZSgvOiQvLCAnJykudG9VcHBlckNhc2UoKTsNCiAgICAgIGlmICghbGV0dGVyKSBjb250aW51ZTsNCiAgICAgIGNvbnN0IGxhYmVsID0gZC5sYWJlbCB8fCAobGV0dGVyICsgJyDnm5gnKTsNCiAgICAgIGh0bWwgKz0gJzxidXR0b24gdHlwZT0iYnV0dG9uIiBkYXRhLWRyaXZlPSInICsgbGV0dGVyICsgJyInDQogICAgICAgICsgKGRyaXZlID09PSBsZXR0ZXIgPyAnIGNsYXNzPSJvbiInIDogJycpICsgJz4nDQogICAgICAgICsgaWNvSHRtbChkLmljb24gfHwgJycpICsgJzxzcGFuPicgKyBsYWJlbCArICc8L3NwYW4+PC9idXR0b24+JzsNCiAgICB9DQogICAgZHJpdmVNZW51LmlubmVySFRNTCA9IGh0bWw7DQogICAgZHJpdmVNZW51LnF1ZXJ5U2VsZWN0b3JBbGwoJ2J1dHRvbicpLmZvckVhY2goYnRuID0+IHsNCiAgICAgIGJ0bi5vbmNsaWNrID0gKGUpID0+IHsNCiAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsNCiAgICAgICAgZHJpdmUgPSBidG4uZ2V0QXR0cmlidXRlKCdkYXRhLWRyaXZlJykgfHwgJyc7DQogICAgICAgIGRyaXZlTWVudS5jbGFzc0xpc3QucmVtb3ZlKCdvbicpOw0KICAgICAgICBzeW5jRHJpdmVCdXR0b24oKTsNCiAgICAgICAgcmVuZGVyRHJpdmVNZW51KCk7DQogICAgICAgIGRvU2VhcmNoKCk7DQogICAgICB9Ow0KICAgIH0pOw0KICB9DQogIHdpbmRvdy5fX3NldERyaXZlcyA9IChwYXlsb2FkKSA9PiB7DQogICAgdHJ5IHsNCiAgICAgIGNvbnN0IGRhdGEgPSB0eXBlb2YgcGF5bG9hZCA9PT0gJ3N0cmluZycgPyBKU09OLnBhcnNlKHBheWxvYWQpIDogcGF5bG9hZDsNCiAgICAgIGlmIChBcnJheS5pc0FycmF5KGRhdGEpKSB7DQogICAgICAgIGRyaXZlTWV0YSA9IHsNCiAgICAgICAgICBjb21wdXRlcjogJycsDQogICAgICAgICAgZHJpdmVzOiBkYXRhLm1hcCh4ID0+IHR5cGVvZiB4ID09PSAnc3RyaW5nJw0KICAgICAgICAgICAgPyAoeyBsZXR0ZXI6IHgsIGljb246ICcnLCBsYWJlbDogU3RyaW5nKHgpLnRvVXBwZXJDYXNlKCkgKyAnIOebmCcgfSkNCiAgICAgICAgICAgIDogeCkNCiAgICAgICAgfTsNCiAgICAgIH0gZWxzZSB7DQogICAgICAgIGRyaXZlTWV0YSA9IHsNCiAgICAgICAgICBjb21wdXRlcjogKGRhdGEgJiYgZGF0YS5jb21wdXRlcikgfHwgJycsDQogICAgICAgICAgZHJpdmVzOiBBcnJheS5pc0FycmF5KGRhdGEgJiYgZGF0YS5kcml2ZXMpID8gZGF0YS5kcml2ZXMgOiBbXQ0KICAgICAgICB9Ow0KICAgICAgfQ0KICAgICAgc3luY0RyaXZlQnV0dG9uKCk7DQogICAgICByZW5kZXJEcml2ZU1lbnUoKTsNCiAgICB9IGNhdGNoIChlKSB7IGNvbnNvbGUud2Fybignc2V0RHJpdmVzJywgZSk7IH0NCiAgfTsNCg0KICBjb25zdCBISVNUX0tFWSA9ICdsb2NhbF9zZWFyY2hfaGlzdF92MSc7DQogIGNvbnN0IEhJU1RfTUFYID0gMTA7DQogIGNvbnN0IHNlYXJjaEJveCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzZWFyY2gtYm94Jyk7DQogIGNvbnN0IGhpc3RNZW51ID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2hpc3QtbWVudScpOw0KICBjb25zdCBidG5IaXN0ID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2J0bi1oaXN0Jyk7DQogIGNvbnN0IGJ0bkNsZWFyID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2J0bi1jbGVhcicpOw0KICBsZXQgaGlzdElkbGVUaW1lciA9IDA7DQoNCiAgZnVuY3Rpb24gc3luY0NsZWFyQnRuKCkgew0KICAgIGJ0bkNsZWFyLmNsYXNzTGlzdC50b2dnbGUoJ29uJywgISEocUVsLnZhbHVlIHx8ICcnKS50cmltKCkpOw0KICB9DQogIGZ1bmN0aW9uIGNsZWFyU2VhcmNoKCkgew0KICAgIGNsZWFyVGltZW91dChoaXN0SWRsZVRpbWVyKTsNCiAgICBxRWwudmFsdWUgPSAnJzsNCiAgICBzeW5jQ2xlYXJCdG4oKTsNCiAgICBoaXN0TWVudS5jbGFzc0xpc3QucmVtb3ZlKCdvbicpOw0KICAgIHNlYXJjaEJveC5jbGFzc0xpc3QucmVtb3ZlKCdoaXN0LW9wZW4nKTsNCiAgICBidG5IaXN0LmNsYXNzTGlzdC5yZW1vdmUoJ29uJyk7DQogICAgcUVsLmZvY3VzKCk7DQogICAgZG9TZWFyY2goKTsNCiAgfQ0KICBidG5DbGVhci5vbmNsaWNrID0gKGUpID0+IHsNCiAgICBlLnN0b3BQcm9wYWdhdGlvbigpOw0KICAgIGNsZWFyU2VhcmNoKCk7DQogIH07DQoNCiAgZnVuY3Rpb24gbG9hZEhpc3QoKSB7DQogICAgdHJ5IHsNCiAgICAgIGNvbnN0IHJhdyA9IGxvY2FsU3RvcmFnZS5nZXRJdGVtKEhJU1RfS0VZKTsNCiAgICAgIGNvbnN0IGFyciA9IHJhdyA/IEpTT04ucGFyc2UocmF3KSA6IFtdOw0KICAgICAgcmV0dXJuIEFycmF5LmlzQXJyYXkoYXJyKSA/IGFyci5tYXAoeCA9PiBTdHJpbmcoeCB8fCAnJykudHJpbSgpKS5maWx0ZXIoQm9vbGVhbikuc2xpY2UoMCwgSElTVF9NQVgpIDogW107DQogICAgfSBjYXRjaCAoXykgeyByZXR1cm4gW107IH0NCiAgfQ0KICBmdW5jdGlvbiBzYXZlSGlzdChsaXN0KSB7DQogICAgdHJ5IHsgbG9jYWxTdG9yYWdlLnNldEl0ZW0oSElTVF9LRVksIEpTT04uc3RyaW5naWZ5KGxpc3Quc2xpY2UoMCwgSElTVF9NQVgpKSk7IH0gY2F0Y2ggKF8pIHt9DQogIH0NCiAgZnVuY3Rpb24gcHVzaEhpc3QocSkgew0KICAgIHEgPSBTdHJpbmcocSB8fCAnJykudHJpbSgpOw0KICAgIGlmICghcSkgcmV0dXJuOw0KICAgIGNvbnN0IGxpc3QgPSBsb2FkSGlzdCgpLmZpbHRlcih4ID0+IHggIT09IHEpOw0KICAgIGxpc3QudW5zaGlmdChxKTsNCiAgICBzYXZlSGlzdChsaXN0KTsNCiAgICBpZiAoaGlzdE1lbnUuY2xhc3NMaXN0LmNvbnRhaW5zKCdvbicpKSByZW5kZXJIaXN0TWVudSgpOw0KICB9DQogIGZ1bmN0aW9uIGVzY2FwZUF0dHIocykgew0KICAgIHJldHVybiBTdHJpbmcocyB8fCAnJykucmVwbGFjZSgvJi9nLCAnJmFtcDsnKS5yZXBsYWNlKC8iL2csICcmcXVvdDsnKS5yZXBsYWNlKC88L2csICcmbHQ7Jyk7DQogIH0NCiAgZnVuY3Rpb24gcmVuZGVySGlzdE1lbnUoKSB7DQogICAgY29uc3QgbGlzdCA9IGxvYWRIaXN0KCk7DQogICAgaWYgKCFsaXN0Lmxlbmd0aCkgew0KICAgICAgaGlzdE1lbnUuaW5uZXJIVE1MID0gJzxkaXYgY2xhc3M9Imhpc3QtZW1wdHkiPuaaguaXoOacgOi/keaQnOe0ojwvZGl2Pic7DQogICAgICByZXR1cm47DQogICAgfQ0KICAgIGhpc3RNZW51LmlubmVySFRNTCA9IGxpc3QubWFwKHEgPT4NCiAgICAgICc8YnV0dG9uIHR5cGU9ImJ1dHRvbiIgZGF0YS1xPSInICsgZXNjYXBlQXR0cihxKSArICciIHRpdGxlPSInICsgZXNjYXBlQXR0cihxKSArICciPicNCiAgICAgICsgZXNjYXBlQXR0cihxKSArICc8L2J1dHRvbj4nDQogICAgKS5qb2luKCcnKTsNCiAgICBoaXN0TWVudS5xdWVyeVNlbGVjdG9yQWxsKCdidXR0b24nKS5mb3JFYWNoKGJ0biA9PiB7DQogICAgICBidG4ub25jbGljayA9IChlKSA9PiB7DQogICAgICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7DQogICAgICAgIGNvbnN0IHEgPSBidG4uZ2V0QXR0cmlidXRlKCdkYXRhLXEnKSB8fCAnJzsNCiAgICAgICAgaGlzdE1lbnUuY2xhc3NMaXN0LnJlbW92ZSgnb24nKTsNCiAgICAgICAgc2VhcmNoQm94LmNsYXNzTGlzdC5yZW1vdmUoJ2hpc3Qtb3BlbicpOw0KICAgICAgICBidG5IaXN0LmNsYXNzTGlzdC5yZW1vdmUoJ29uJyk7DQogICAgICAgIHFFbC52YWx1ZSA9IHE7DQogICAgICAgIHB1c2hIaXN0KHEpOw0KICAgICAgICBzeW5jQ2xlYXJCdG4oKTsNCiAgICAgICAgZG9TZWFyY2goKTsNCiAgICAgIH07DQogICAgfSk7DQogIH0NCiAgYnRuRHJpdmUub25jbGljayA9IChlKSA9PiB7DQogICAgZS5zdG9wUHJvcGFnYXRpb24oKTsNCiAgICBjbG9zZUhpc3RNZW51KCk7DQogICAgZHJpdmVNZW51LmNsYXNzTGlzdC50b2dnbGUoJ29uJyk7DQogIH07DQogIGZ1bmN0aW9uIGNsb3NlSGlzdE1lbnUoKSB7DQogICAgaGlzdE1lbnUuY2xhc3NMaXN0LnJlbW92ZSgnb24nKTsNCiAgICBzZWFyY2hCb3guY2xhc3NMaXN0LnJlbW92ZSgnaGlzdC1vcGVuJyk7DQogICAgYnRuSGlzdC5jbGFzc0xpc3QucmVtb3ZlKCdvbicpOw0KICB9DQogIGZ1bmN0aW9uIG9wZW5IaXN0TWVudSgpIHsNCiAgICBkcml2ZU1lbnUuY2xhc3NMaXN0LnJlbW92ZSgnb24nKTsNCiAgICByZW5kZXJIaXN0TWVudSgpOw0KICAgIGhpc3RNZW51LmNsYXNzTGlzdC5hZGQoJ29uJyk7DQogICAgc2VhcmNoQm94LmNsYXNzTGlzdC5hZGQoJ2hpc3Qtb3BlbicpOw0KICAgIGJ0bkhpc3QuY2xhc3NMaXN0LmFkZCgnb24nKTsNCiAgfQ0KICBidG5IaXN0Lm9uY2xpY2sgPSAoZSkgPT4gew0KICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7DQogICAgaWYgKGhpc3RNZW51LmNsYXNzTGlzdC5jb250YWlucygnb24nKSkgY2xvc2VIaXN0TWVudSgpOw0KICAgIGVsc2Ugb3Blbkhpc3RNZW51KCk7DQogIH07DQogIGhpc3RNZW51LmFkZEV2ZW50TGlzdGVuZXIoJ2NsaWNrJywgZSA9PiBlLnN0b3BQcm9wYWdhdGlvbigpKTsNCiAgZG9jdW1lbnQuYWRkRXZlbnRMaXN0ZW5lcignY2xpY2snLCAoKSA9PiB7DQogICAgZHJpdmVNZW51LmNsYXNzTGlzdC5yZW1vdmUoJ29uJyk7DQogICAgY2xvc2VIaXN0TWVudSgpOw0KICAgIGhpZGVDdHgoKTsNCiAgfSk7DQogIHJlbmRlckRyaXZlTWVudSgpOw0KICByZW5kZXJIaXN0TWVudSgpOw0KICBzeW5jQ2xlYXJCdG4oKTsNCg0KICAvLyBQcmltYXJ5IFVJ4oaSQUhLIGNoYW5uZWw6IGluLXBhZ2UgcXVldWUgZHJhaW5lZCBieSBBSEsgRXhlY3V0ZVNjcmlwdC4NCiAgLy8gTmV2ZXIgdXNlIGhvc3RPYmplY3RzLnN5bmMg4oCUIGl0IGRlYWRsb2NrcyBXZWJWaWV3MiBhbmQgYmxvY2tzIHBvc3RNZXNzYWdlIHRvby4NCiAgd2luZG93Ll9fYWhrUSA9IHdpbmRvdy5fX2Foa1EgfHwgW107DQogIGZ1bmN0aW9uIGVucXVldWUobXNnKSB7DQogICAgdHJ5IHsNCiAgICAgIHdpbmRvdy5fX2Foa1EucHVzaChTdHJpbmcobXNnKSk7DQogICAgICAvLyBUaXAgQUhLIHBvbGxlciB2aWEgdGl0bGUgY2hhbmdlIChvcHRpb25hbCBmYXN0IHBhdGgpDQogICAgICB0cnkgeyBkb2N1bWVudC5kb2N1bWVudEVsZW1lbnQuZGF0YXNldC5haGtQZW5kaW5nID0gU3RyaW5nKHdpbmRvdy5fX2Foa1EubGVuZ3RoKTsgfSBjYXRjaCAoXykge30NCiAgICB9IGNhdGNoIChlKSB7IGNvbnNvbGUud2FybignZW5xdWV1ZScsIGUpOyB9DQogIH0NCiAgZnVuY3Rpb24gcG9zdChtc2cpIHsNCiAgICBlbnF1ZXVlKG1zZyk7DQogICAgdHJ5IHsNCiAgICAgIGlmICh3aW5kb3cuY2hyb21lICYmIGNocm9tZS53ZWJ2aWV3ICYmIHR5cGVvZiBjaHJvbWUud2Vidmlldy5wb3N0TWVzc2FnZSA9PT0gJ2Z1bmN0aW9uJykgew0KICAgICAgICBjaHJvbWUud2Vidmlldy5wb3N0TWVzc2FnZShTdHJpbmcobXNnKSk7DQogICAgICAgIHJldHVybiB0cnVlOw0KICAgICAgfQ0KICAgIH0gY2F0Y2ggKGUpIHsgY29uc29sZS53YXJuKCdwb3N0JywgZSk7IH0NCiAgICByZXR1cm4gZmFsc2U7DQogIH0NCiAgZnVuY3Rpb24gY2FsbEhvc3QobWV0aG9kLCAuLi5hcmdzKSB7DQogICAgbGV0IG1zZyA9ICcnOw0KICAgIGlmIChtZXRob2QgPT09ICdzZWFyY2gnKSB7DQogICAgICBjb25zdCBbcSwgYywgcywgb2Zmc2V0XSA9IGFyZ3M7DQogICAgICBtc2cgPSAnc2VhcmNofCcgKyBKU09OLnN0cmluZ2lmeSh7DQogICAgICAgIHE6IHEgfHwgJycsIGNhdDogYyB8fCAnYWxsJywgc29ydDogcyB8fCAnZGF0ZS1kZXNjJywNCiAgICAgICAgZHJpdmU6IGRyaXZlIHx8ICcnLA0KICAgICAgICBvZmZzZXQ6IE51bWJlcihvZmZzZXQpIHx8IDAsIGdlbjogKytnZW4NCiAgICAgIH0pOw0KICAgIH0gZWxzZSBpZiAobWV0aG9kID09PSAncHJldmlldycpIHsNCiAgICAgIG1zZyA9ICdwcmV2aWV3fCcgKyAoYXJnc1swXSB8fCAnJyk7DQogICAgfSBlbHNlIGlmIChtZXRob2QgPT09ICdvcGVuJykgew0KICAgICAgbXNnID0gJ29wZW58JyArIChhcmdzWzBdIHx8ICcnKTsNCiAgICB9IGVsc2UgaWYgKG1ldGhvZCA9PT0gJ3JldmVhbCcpIHsNCiAgICAgIG1zZyA9ICdyZXZlYWx8JyArIChhcmdzWzBdIHx8ICcnKTsNCiAgICB9IGVsc2UgaWYgKG1ldGhvZCA9PT0gJ2NvcHlGaWxlJykgew0KICAgICAgbXNnID0gJ2NvcHlGaWxlfCcgKyAoYXJnc1swXSB8fCAnJyk7DQogICAgfSBlbHNlIGlmIChtZXRob2QgPT09ICdjb3B5UGF0aCcpIHsNCiAgICAgIG1zZyA9ICdjb3B5UGF0aHwnICsgKGFyZ3NbMF0gfHwgJycpOw0KICAgIH0gZWxzZSBpZiAobWV0aG9kID09PSAnY29weURpcicpIHsNCiAgICAgIG1zZyA9ICdjb3B5RGlyfCcgKyAoYXJnc1swXSB8fCAnJyk7DQogICAgfSBlbHNlIGlmIChtZXRob2QgPT09ICdyZWN5Y2xlJykgew0KICAgICAgbXNnID0gJ3JlY3ljbGV8JyArIChhcmdzWzBdIHx8ICcnKTsNCiAgICB9IGVsc2UgaWYgKG1ldGhvZCA9PT0gJ2Nsb3NlJyB8fCBtZXRob2QgPT09ICdtaW5pbWl6ZScgfHwgbWV0aG9kID09PSAnZHJhZycpIHsNCiAgICAgIG1zZyA9IG1ldGhvZDsNCiAgICB9IGVsc2Ugew0KICAgICAgbXNnID0gbWV0aG9kICsgJ3wnICsgYXJncy5tYXAoYSA9PiBTdHJpbmcoYSA/PyAnJykpLmpvaW4oJ3wnKTsNCiAgICB9DQogICAgcG9zdChtc2cpOw0KICB9DQoNCiAgZnVuY3Rpb24gc2V0Qm9vdFBjdChwKSB7DQogICAgcCA9IE1hdGgubWF4KDAsIE1hdGgubWluKDEwMCwgTnVtYmVyKHApIHx8IDApKTsNCiAgICBib290UGN0LnRleHRDb250ZW50ID0gTWF0aC5yb3VuZChwKSArICclJzsNCiAgICByaW5nRmcuc3R5bGUuc3Ryb2tlRGFzaGFycmF5ID0gU3RyaW5nKENJUkMpOw0KICAgIHJpbmdGZy5zdHlsZS5zdHJva2VEYXNob2Zmc2V0ID0gU3RyaW5nKENJUkMgKiAoMSAtIHAgLyAxMDApKTsNCiAgfQ0KDQogIGxldCBib290Q21kU2VxID0gMDsNCiAgd2luZG93Ll9fc2V0Qm9vdCA9IChvbiwgcGN0LCBzZXEpID0+IHsNCiAgICAvLyDlv73nlaXkubHluo/ov5/liLDnmoQgQUhLIEV4ZWN1dGVTY3JpcHRBc3luY++8jOmBv+WFjeS4u+eVjOmdoumXquWbnui/m+W6puadoQ0KICAgIGlmIChzZXEgIT0gbnVsbCAmJiBzZXEgIT09ICcnICYmICFOdW1iZXIuaXNOYU4oTnVtYmVyKHNlcSkpKSB7DQogICAgICBzZXEgPSBOdW1iZXIoc2VxKTsNCiAgICAgIGlmIChzZXEgPCBib290Q21kU2VxKSByZXR1cm47DQogICAgICBib290Q21kU2VxID0gc2VxOw0KICAgIH0NCiAgICBpZiAob24pIHsNCiAgICAgIGJvb3QuY2xhc3NMaXN0LmFkZCgnb24nKTsNCiAgICAgIGNocm9tZS5jbGFzc0xpc3QuYWRkKCdoaWRkZW4nKTsNCiAgICAgIHNldEJvb3RQY3QocGN0KTsNCiAgICB9IGVsc2Ugew0KICAgICAgYm9vdC5jbGFzc0xpc3QucmVtb3ZlKCdvbicpOw0KICAgICAgY2hyb21lLmNsYXNzTGlzdC5yZW1vdmUoJ2hpZGRlbicpOw0KICAgIH0NCiAgfTsNCiAgd2luZG93Ll9fc2V0SW5kZXhQcm9ncmVzcyA9IChwY3QpID0+IHNldEJvb3RQY3QocGN0KTsNCg0KICB3aW5kb3cuX19zZXRDYXRJY29ucyA9IChwYXlsb2FkKSA9PiB7DQogICAgdHJ5IHsNCiAgICAgIGNvbnN0IG1hcCA9IHR5cGVvZiBwYXlsb2FkID09PSAnc3RyaW5nJyA/IEpTT04ucGFyc2UocGF5bG9hZCkgOiBwYXlsb2FkOw0KICAgICAgaWYgKCFtYXAgfHwgdHlwZW9mIG1hcCAhPT0gJ29iamVjdCcpIHJldHVybjsNCiAgICAgIGRvY3VtZW50LnF1ZXJ5U2VsZWN0b3JBbGwoJy5jYXQnKS5mb3JFYWNoKGJ0biA9PiB7DQogICAgICAgIGNvbnN0IGtleSA9IGJ0bi5nZXRBdHRyaWJ1dGUoJ2RhdGEtY2F0Jyk7DQogICAgICAgIGNvbnN0IHVybCA9IG1hcFtrZXldOw0KICAgICAgICBpZiAoIXVybCkgcmV0dXJuOw0KICAgICAgICBsZXQgaW1nID0gYnRuLnF1ZXJ5U2VsZWN0b3IoJ2ltZy5pY28nKTsNCiAgICAgICAgaWYgKCFpbWcpIHsNCiAgICAgICAgICBjb25zdCBvbGQgPSBidG4ucXVlcnlTZWxlY3RvcignLmljbywgW2RhdGEtY2F0LWljb10nKTsNCiAgICAgICAgICBpbWcgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdpbWcnKTsNCiAgICAgICAgICBpbWcuY2xhc3NOYW1lID0gJ2ljbyc7DQogICAgICAgICAgaW1nLmFsdCA9ICcnOw0KICAgICAgICAgIGlmIChvbGQpIG9sZC5yZXBsYWNlV2l0aChpbWcpOw0KICAgICAgICAgIGVsc2UgYnRuLmluc2VydEJlZm9yZShpbWcsIGJ0bi5maXJzdENoaWxkKTsNCiAgICAgICAgfQ0KICAgICAgICBpbWcuc3JjID0gdXJsICsgKHVybC5pbmNsdWRlcygnPycpID8gJyYnIDogJz8nKSArICd0PScgKyBEYXRlLm5vdygpOw0KICAgICAgfSk7DQogICAgfSBjYXRjaCAoZSkgeyBjb25zb2xlLndhcm4oJ3NldENhdEljb25zJywgZSk7IH0NCiAgfTsNCg0KICBmdW5jdGlvbiBleHRPZihuYW1lKSB7DQogICAgY29uc3QgaSA9IFN0cmluZyhuYW1lIHx8ICcnKS5sYXN0SW5kZXhPZignLicpOw0KICAgIHJldHVybiBpID4gMCA/IG5hbWUuc2xpY2UoaSArIDEpLnRvTG93ZXJDYXNlKCkgOiAnJzsNCiAgfQ0KICBmdW5jdGlvbiBpY29uSHRtbChpdCkgew0KICAgIGlmIChpdC5pY29uKSB7DQogICAgICByZXR1cm4gJzxpbWcgc3JjPSInICsgZXNjYXBlSHRtbChpdC5pY29uKSArICciIGFsdD0iIiBsb2FkaW5nPSJsYXp5IiBkZWNvZGluZz0iYXN5bmMiIG9uZXJyb3I9InRoaXMub3V0ZXJIVE1MPVwnPHNwYW4gY2xhc3M9ZmktZmFsbGJhY2s+8J+ThDwvc3Bhbj5cJyI+JzsNCiAgICB9DQogICAgaWYgKGl0LmlzRGlyKSByZXR1cm4gJzxzcGFuIGNsYXNzPSJmaS1mYWxsYmFjayI+8J+TgTwvc3Bhbj4nOw0KICAgIHJldHVybiAnPHNwYW4gY2xhc3M9ImZpLWZhbGxiYWNrIj7wn5OEPC9zcGFuPic7DQogIH0NCiAgZnVuY3Rpb24gaGlnaGxpZ2h0SHRtbCh0ZXh0KSB7DQogICAgY29uc3QgcmF3ID0gU3RyaW5nKHRleHQgPz8gJycpOw0KICAgIGxldCBodG1sID0gZXNjYXBlSHRtbChyYXcpOw0KICAgIGNvbnN0IHEgPSAocUVsLnZhbHVlIHx8ICcnKS50cmltKCk7DQogICAgaWYgKCFxKSByZXR1cm4gaHRtbDsNCiAgICBjb25zdCB0ZXJtcyA9IHEuc3BsaXQoL1x8XHx8XHwvKS5mbGF0TWFwKHMgPT4gcy5zcGxpdCgvXHMrLykpLm1hcCh0ID0+IHQudHJpbSgpKS5maWx0ZXIoQm9vbGVhbik7DQogICAgLy8gbG9uZ2VyIHRlcm1zIGZpcnN0IHRvIGF2b2lkIHBhcnRpYWwgb3ZlcmxhcCBpc3N1ZXMNCiAgICB0ZXJtcy5zb3J0KChhLCBiKSA9PiBiLmxlbmd0aCAtIGEubGVuZ3RoKTsNCiAgICBmb3IgKGNvbnN0IHQgb2YgdGVybXMpIHsNCiAgICAgIGlmICghdCkgY29udGludWU7DQogICAgICBjb25zdCByZSA9IG5ldyBSZWdFeHAodC5yZXBsYWNlKC9bLiorP14ke30oKXxbXF1cXF0vZywgJ1xcJCYnKSwgJ2dpJyk7DQogICAgICBodG1sID0gaHRtbC5yZXBsYWNlKHJlLCBtID0+ICc8bWFyaz4nICsgbSArICc8L21hcms+Jyk7DQogICAgfQ0KICAgIHJldHVybiBodG1sOw0KICB9DQogIGZ1bmN0aW9uIHByZXR0eU5hbWUobmFtZSkgew0KICAgIG5hbWUgPSBTdHJpbmcobmFtZSB8fCAnJyk7DQogICAgaWYgKCFuYW1lKSByZXR1cm4gJyc7DQogICAgY29uc3QgZSA9IGV4dE9mKG5hbWUpOw0KICAgIGlmICghZSB8fCBuYW1lLnN0YXJ0c1dpdGgoJy4nKSkgcmV0dXJuIGhpZ2hsaWdodEh0bWwobmFtZSk7DQogICAgY29uc3QgYmFzZSA9IG5hbWUuc2xpY2UoMCwgLShlLmxlbmd0aCArIDEpKTsNCiAgICByZXR1cm4gaGlnaGxpZ2h0SHRtbChiYXNlKSArICc8c3BhbiBjbGFzcz0iZXh0Ij4uJyArIGVzY2FwZUh0bWwoZSkgKyAnPC9zcGFuPic7DQogIH0NCiAgZnVuY3Rpb24gZGlzcGxheU5hbWUoaXQpIHsNCiAgICBsZXQgbiA9IFN0cmluZyhpdC5uYW1lIHx8ICcnKS50cmltKCk7DQogICAgaWYgKG4pIHJldHVybiBuOw0KICAgIC8vIGZhbGxiYWNrOiBsYXN0IHNlZ21lbnQgb2YgcGF0aA0KICAgIGNvbnN0IHAgPSBTdHJpbmcoaXQucGF0aCB8fCAnJykucmVwbGFjZSgvW1xcL10rJC8sICcnKTsNCiAgICBjb25zdCBpID0gTWF0aC5tYXgocC5sYXN0SW5kZXhPZignXFwnKSwgcC5sYXN0SW5kZXhPZignLycpKTsNCiAgICByZXR1cm4gaSA+PSAwID8gcC5zbGljZShpICsgMSkgOiBwOw0KICB9DQogIGZ1bmN0aW9uIGVzY2FwZUh0bWwocykgew0KICAgIHJldHVybiBTdHJpbmcocyA/PyAnJykucmVwbGFjZSgvJi9nLCcmYW1wOycpLnJlcGxhY2UoLzwvZywnJmx0OycpLnJlcGxhY2UoLz4vZywnJmd0OycpLnJlcGxhY2UoLyIvZywnJnF1b3Q7Jyk7DQogIH0NCiAgZnVuY3Rpb24gc2hvcnRQYXRoKHApIHsNCiAgICBwID0gU3RyaW5nKHAgfHwgJycpOw0KICAgIGlmIChwLmxlbmd0aCA8PSA1NikgcmV0dXJuIHA7DQogICAgcmV0dXJuIHAuc2xpY2UoMCwgMjgpICsgJy4uLicgKyBwLnNsaWNlKC0yNCk7DQogIH0NCg0KICBmdW5jdGlvbiB1cGRhdGVDb3VudCgpIHsNCiAgICBpZiAoIWl0ZW1zLmxlbmd0aCkgew0KICAgICAgY291bnRFbC50ZXh0Q29udGVudCA9ICflhbEgMCDmnaHnu5PmnpwnOw0KICAgICAgcmV0dXJuOw0KICAgIH0NCiAgICBjb25zdCBzaG93biA9IGl0ZW1zLmxlbmd0aDsNCiAgICBjb3VudEVsLnRleHRDb250ZW50ID0gdG90YWxIaXRzID4gc2hvd24NCiAgICAgID8gKCflhbEgJyArIHRvdGFsSGl0cy50b0xvY2FsZVN0cmluZygpICsgJyDmnaHnu5PmnpzvvIjlt7LliqDovb0gJyArIHNob3duLnRvTG9jYWxlU3RyaW5nKCkgKyAnIOadoe+8iScpDQogICAgICA6ICgn5YWxICcgKyBNYXRoLm1heCh0b3RhbEhpdHMsIHNob3duKS50b0xvY2FsZVN0cmluZygpICsgJyDmnaHnu5PmnpwnKTsNCiAgfQ0KDQogIGZ1bmN0aW9uIG1ha2VSb3coaXQsIGkpIHsNCiAgICBjb25zdCByb3cgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsNCiAgICByb3cuY2xhc3NOYW1lID0gJ3JvdycgKyAoaSA9PT0gc2VsZWN0ZWQgPyAnIG9uJyA6ICcnKTsNCiAgICBjb25zdCB0aXRsZSA9IGRpc3BsYXlOYW1lKGl0KTsNCiAgICByb3cuaW5uZXJIVE1MID0gYDxkaXYgY2xhc3M9ImZpIj4ke2ljb25IdG1sKGl0KX08L2Rpdj4NCiAgICAgIDxkaXY+DQogICAgICAgIDxkaXYgY2xhc3M9Im5hbWUiPiR7cHJldHR5TmFtZSh0aXRsZSl9PC9kaXY+DQogICAgICAgIDxkaXYgY2xhc3M9InBhdGgiIHRpdGxlPSIke2VzY2FwZUh0bWwoaXQucGF0aCl9Ij4ke2hpZ2hsaWdodEh0bWwoc2hvcnRQYXRoKGl0LnBhdGgpKX08L2Rpdj4NCiAgICAgIDwvZGl2PmA7DQogICAgcm93Lm9uY2xpY2sgPSAoKSA9PiB7IGhpZGVDdHgoKTsgc2VsZWN0Um93KGkpOyB9Ow0KICAgIHJvdy5vbmRibGNsaWNrID0gKCkgPT4gew0KICAgICAgaGlkZUN0eCgpOw0KICAgICAgcHVzaEhpc3QocUVsLnZhbHVlIHx8ICcnKTsNCiAgICAgIGNhbGxIb3N0KCdvcGVuJywgaXQucGF0aCk7DQogICAgfTsNCiAgICByb3cub25jb250ZXh0bWVudSA9IChlKSA9PiB7DQogICAgICBlLnByZXZlbnREZWZhdWx0KCk7DQogICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOw0KICAgICAgc2VsZWN0Um93KGkpOw0KICAgICAgc2hvd0N0eChlLmNsaWVudFgsIGUuY2xpZW50WSwgaXQucGF0aCk7DQogICAgfTsNCiAgICByZXR1cm4gcm93Ow0KICB9DQoNCiAgY29uc3QgY3R4RWwgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnY3R4Jyk7DQogIGxldCBjdHhQYXRoID0gJyc7DQogIGZ1bmN0aW9uIGhpZGVDdHgoKSB7DQogICAgY3R4RWwuY2xhc3NMaXN0LnJlbW92ZSgnb24nKTsNCiAgICBjdHhQYXRoID0gJyc7DQogIH0NCiAgZnVuY3Rpb24gc2hvd0N0eCh4LCB5LCBwYXRoKSB7DQogICAgY3R4UGF0aCA9IFN0cmluZyhwYXRoIHx8ICcnKTsNCiAgICBpZiAoIWN0eFBhdGgpIHJldHVybjsNCiAgICBjdHhFbC5jbGFzc0xpc3QuYWRkKCdvbicpOw0KICAgIGNvbnN0IHBhZCA9IDY7DQogICAgY29uc3QgdncgPSB3aW5kb3cuaW5uZXJXaWR0aDsNCiAgICBjb25zdCB2aCA9IHdpbmRvdy5pbm5lckhlaWdodDsNCiAgICBjdHhFbC5zdHlsZS5sZWZ0ID0gJzBweCc7DQogICAgY3R4RWwuc3R5bGUudG9wID0gJzBweCc7DQogICAgY29uc3QgcmVjdCA9IGN0eEVsLmdldEJvdW5kaW5nQ2xpZW50UmVjdCgpOw0KICAgIGxldCBsZWZ0ID0geDsNCiAgICBsZXQgdG9wID0geTsNCiAgICBpZiAobGVmdCArIHJlY3Qud2lkdGggPiB2dyAtIHBhZCkgbGVmdCA9IE1hdGgubWF4KHBhZCwgdncgLSByZWN0LndpZHRoIC0gcGFkKTsNCiAgICBpZiAodG9wICsgcmVjdC5oZWlnaHQgPiB2aCAtIHBhZCkgdG9wID0gTWF0aC5tYXgocGFkLCB2aCAtIHJlY3QuaGVpZ2h0IC0gcGFkKTsNCiAgICBjdHhFbC5zdHlsZS5sZWZ0ID0gbGVmdCArICdweCc7DQogICAgY3R4RWwuc3R5bGUudG9wID0gdG9wICsgJ3B4JzsNCiAgfQ0KICBjdHhFbC5xdWVyeVNlbGVjdG9yQWxsKCdidXR0b25bZGF0YS1hY3RdJykuZm9yRWFjaChidG4gPT4gew0KICAgIGJ0bi5hZGRFdmVudExpc3RlbmVyKCdjbGljaycsIChlKSA9PiB7DQogICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOw0KICAgICAgY29uc3QgYWN0ID0gYnRuLmdldEF0dHJpYnV0ZSgnZGF0YS1hY3QnKTsNCiAgICAgIGNvbnN0IHBhdGggPSBjdHhQYXRoOw0KICAgICAgaGlkZUN0eCgpOw0KICAgICAgaWYgKCFwYXRoIHx8ICFhY3QpIHJldHVybjsNCiAgICAgIGlmIChhY3QgPT09ICdyZXZlYWwnKSBjYWxsSG9zdCgncmV2ZWFsJywgcGF0aCk7DQogICAgICBlbHNlIGlmIChhY3QgPT09ICdjb3B5JykgY2FsbEhvc3QoJ2NvcHlGaWxlJywgcGF0aCk7DQogICAgICBlbHNlIGlmIChhY3QgPT09ICdjb3B5UGF0aCcpIGNhbGxIb3N0KCdjb3B5UGF0aCcsIHBhdGgpOw0KICAgICAgZWxzZSBpZiAoYWN0ID09PSAnY29weURpcicpIGNhbGxIb3N0KCdjb3B5RGlyJywgcGF0aCk7DQogICAgICBlbHNlIGlmIChhY3QgPT09ICdyZWN5Y2xlJykgY2FsbEhvc3QoJ3JlY3ljbGUnLCBwYXRoKTsNCiAgICB9KTsNCiAgfSk7DQogIGRvY3VtZW50LmFkZEV2ZW50TGlzdGVuZXIoJ2NvbnRleHRtZW51JywgKGUpID0+IHsNCiAgICBpZiAoIWUudGFyZ2V0LmNsb3Nlc3QoJyNsaXN0IC5yb3cnKSAmJiAhZS50YXJnZXQuY2xvc2VzdCgnI2N0eCcpKSBoaWRlQ3R4KCk7DQogIH0pOw0KICB3aW5kb3cuYWRkRXZlbnRMaXN0ZW5lcignYmx1cicsIGhpZGVDdHgpOw0KICB3aW5kb3cuYWRkRXZlbnRMaXN0ZW5lcigncmVzaXplJywgaGlkZUN0eCk7DQogIHdpbmRvdy5fX3JlbW92ZVBhdGggPSAocGF0aCkgPT4gew0KICAgIHBhdGggPSBTdHJpbmcocGF0aCB8fCAnJyk7DQogICAgaWYgKCFwYXRoKSByZXR1cm47DQogICAgY29uc3QgcHJldlNlbCA9IHNlbGVjdGVkID49IDAgPyAoaXRlbXNbc2VsZWN0ZWRdICYmIGl0ZW1zW3NlbGVjdGVkXS5wYXRoKSA6ICcnOw0KICAgIGl0ZW1zID0gaXRlbXMuZmlsdGVyKGl0ID0+IFN0cmluZyhpdC5wYXRoIHx8ICcnKSAhPT0gcGF0aCk7DQogICAgaWYgKHRvdGFsSGl0cyA+IDApIHRvdGFsSGl0cyA9IE1hdGgubWF4KDAsIHRvdGFsSGl0cyAtIDEpOw0KICAgIHNlbGVjdGVkID0gLTE7DQogICAgaWYgKHByZXZTZWwgJiYgcHJldlNlbCAhPT0gcGF0aCkgew0KICAgICAgc2VsZWN0ZWQgPSBpdGVtcy5maW5kSW5kZXgoaXQgPT4gaXQucGF0aCA9PT0gcHJldlNlbCk7DQogICAgfSBlbHNlIGlmIChpdGVtcy5sZW5ndGgpIHsNCiAgICAgIHNlbGVjdGVkID0gTWF0aC5taW4oc2VsZWN0ZWQgPCAwID8gMCA6IHNlbGVjdGVkLCBpdGVtcy5sZW5ndGggLSAxKTsNCiAgICB9DQogICAgcmVuZGVyTGlzdChmYWxzZSk7DQogICAgaWYgKHNlbGVjdGVkID49IDAgJiYgcHJldmlld09uKSByZXF1ZXN0UHJldmlldyhpdGVtc1tzZWxlY3RlZF0pOw0KICAgIGVsc2Ugew0KICAgICAgcHZNZXRhLnRleHRDb250ZW50ID0gJ+mAieaLqeaWh+S7tuS7pemihOiniCc7DQogICAgICBwdk1lZGlhLmlubmVySFRNTCA9ICc8ZGl2IGNsYXNzPSJwaCI+6aKE6KeI5Yy6PC9kaXY+JzsNCiAgICAgIHB2VGV4dC5zdHlsZS5kaXNwbGF5ID0gJ25vbmUnOw0KICAgIH0NCiAgfTsNCg0KICBmdW5jdGlvbiByZW5kZXJMaXN0KGFwcGVuZCkgew0KICAgIGlmICghYXBwZW5kKSBsaXN0RWwuaW5uZXJIVE1MID0gJyc7DQogICAgaWYgKCFpdGVtcy5sZW5ndGgpIHsNCiAgICAgIGVtcHR5RWwuY2xhc3NMaXN0LmFkZCgnb24nKTsNCiAgICAgIHVwZGF0ZUNvdW50KCk7DQogICAgICByZXR1cm47DQogICAgfQ0KICAgIGVtcHR5RWwuY2xhc3NMaXN0LnJlbW92ZSgnb24nKTsNCiAgICBjb25zdCBzdGFydCA9IGFwcGVuZCA/IGxpc3RFbC5xdWVyeVNlbGVjdG9yQWxsKCcucm93JykubGVuZ3RoIDogMDsNCiAgICBjb25zdCBmcmFnID0gZG9jdW1lbnQuY3JlYXRlRG9jdW1lbnRGcmFnbWVudCgpOw0KICAgIGZvciAobGV0IGkgPSBzdGFydDsgaSA8IGl0ZW1zLmxlbmd0aDsgaSsrKQ0KICAgICAgZnJhZy5hcHBlbmRDaGlsZChtYWtlUm93KGl0ZW1zW2ldLCBpKSk7DQogICAgbGlzdEVsLmFwcGVuZENoaWxkKGZyYWcpOw0KICAgIHVwZGF0ZUNvdW50KCk7DQogIH0NCg0KICBmdW5jdGlvbiBzZWxlY3RSb3coaSkgew0KICAgIHNlbGVjdGVkID0gaTsNCiAgICBsaXN0RWwucXVlcnlTZWxlY3RvckFsbCgnLnJvdycpLmZvckVhY2goKGVsLCBpZHgpID0+IGVsLmNsYXNzTGlzdC50b2dnbGUoJ29uJywgaWR4ID09PSBpKSk7DQogICAgY29uc3QgaXQgPSBpdGVtc1tpXTsNCiAgICBpZiAoIWl0KSByZXR1cm47DQogICAgaWYgKHByZXZpZXdPbikgcmVxdWVzdFByZXZpZXcoaXQpOw0KICB9DQoNCiAgZnVuY3Rpb24gcmVxdWVzdFByZXZpZXcoaXQpIHsNCiAgICBwdk1ldGEuaW5uZXJIVE1MID0gYDxzcGFuPuWQjeensCA8Yj4ke2VzY2FwZUh0bWwoaXQubmFtZSl9PC9iPjwvc3Bhbj5gOw0KICAgIGlmIChwdkJvZHkpIHB2Qm9keS5jbGFzc0xpc3QucmVtb3ZlKCd0ZXh0LW1vZGUnKTsNCiAgICBwdk1lZGlhLmlubmVySFRNTCA9ICc8ZGl2IGNsYXNzPSJwaCI+5Yqg6L296aKE6KeI4oCmPC9kaXY+JzsNCiAgICBwdlRleHQuc3R5bGUuZGlzcGxheSA9ICdub25lJzsNCiAgICBjYWxsSG9zdCgncHJldmlldycsIGl0LnBhdGgpOw0KICB9DQoNCiAgZnVuY3Rpb24gdHJ5TG9hZE1vcmUoKSB7DQogICAgaWYgKCFoYXNNb3JlIHx8IGxvYWRpbmdNb3JlKSByZXR1cm47DQogICAgbG9hZGluZ01vcmUgPSB0cnVlOw0KICAgIGNhbGxIb3N0KCdzZWFyY2gnLCBxRWwudmFsdWUgfHwgJycsIGNhdCwgc29ydCwgaXRlbXMubGVuZ3RoKTsNCiAgfQ0KDQogIGZ1bmN0aW9uIG1heWJlRmlsbFZpZXdwb3J0KCkgew0KICAgIC8vIOmmluWxj+WPquaciSAxNSDmnaHml7blj6/og73kuI3lpJ/mu5rliqjvvIzoh6rliqjooaXpobXnm7TliLDlj6/mu5rmiJbmsqHmnInmm7TlpJoNCiAgICBpZiAoIWhhc01vcmUgfHwgbG9hZGluZ01vcmUpIHJldHVybjsNCiAgICBpZiAobGlzdEVsLnNjcm9sbEhlaWdodCA8PSBsaXN0RWwuY2xpZW50SGVpZ2h0ICsgOCkNCiAgICAgIHRyeUxvYWRNb3JlKCk7DQogIH0NCg0KICBsaXN0RWwuYWRkRXZlbnRMaXN0ZW5lcignc2Nyb2xsJywgKCkgPT4gew0KICAgIGlmIChsaXN0RWwuc2Nyb2xsVG9wICsgbGlzdEVsLmNsaWVudEhlaWdodCA+PSBsaXN0RWwuc2Nyb2xsSGVpZ2h0IC0gMTIwKQ0KICAgICAgdHJ5TG9hZE1vcmUoKTsNCiAgfSk7DQoNCiAgd2luZG93Ll9fdXBkYXRlUmVzdWx0cyA9IChwYXlsb2FkKSA9PiB7DQogICAgdHJ5IHsNCiAgICAgIGNvbnN0IGRhdGEgPSB0eXBlb2YgcGF5bG9hZCA9PT0gJ3N0cmluZycgPyBKU09OLnBhcnNlKHBheWxvYWQpIDogcGF5bG9hZDsNCiAgICAgIGNvbnN0IGJhdGNoID0gQXJyYXkuaXNBcnJheShkYXRhLml0ZW1zKSA/IGRhdGEuaXRlbXMgOiBbXTsNCiAgICAgIGNvbnN0IHRvdGFsID0gTnVtYmVyKGRhdGEudG90YWwgIT0gbnVsbCA/IGRhdGEudG90YWwgOiAwKSB8fCAwOw0KICAgICAgY29uc3Qgb2Zmc2V0ID0gTnVtYmVyKGRhdGEub2Zmc2V0KSB8fCAwOw0KICAgICAgY29uc3QgYXBwZW5kID0gISFkYXRhLmFwcGVuZCAmJiBvZmZzZXQgPiAwOw0KDQogICAgICB0b3RhbEhpdHMgPSAodG90YWwgPj0gMCA/IHRvdGFsIDogdG90YWxIaXRzKSB8fCB0b3RhbEhpdHM7DQogICAgICBpZiAoYXBwZW5kKSB7DQogICAgICAgIGNvbnN0IHNlZW4gPSBuZXcgU2V0KGl0ZW1zLm1hcCh4ID0+IHgucGF0aCkpOw0KICAgICAgICBmb3IgKGNvbnN0IGl0IG9mIGJhdGNoKSB7DQogICAgICAgICAgaWYgKCFzZWVuLmhhcyhpdC5wYXRoKSkgaXRlbXMucHVzaChpdCk7DQogICAgICAgIH0NCiAgICAgICAgbG9hZGluZ01vcmUgPSBmYWxzZTsNCiAgICAgICAgaGFzTW9yZSA9IGJhdGNoLmxlbmd0aCA+IDAgJiYgaXRlbXMubGVuZ3RoIDwgdG90YWxIaXRzOw0KICAgICAgICByZW5kZXJMaXN0KHRydWUpOw0KICAgICAgfSBlbHNlIHsNCiAgICAgICAgaXRlbXMgPSBiYXRjaDsNCiAgICAgICAgbG9hZGluZ01vcmUgPSBmYWxzZTsNCiAgICAgICAgaGFzTW9yZSA9IGJhdGNoLmxlbmd0aCA+IDAgJiYgaXRlbXMubGVuZ3RoIDwgdG90YWxIaXRzOw0KICAgICAgICBzZWxlY3RlZCA9IGl0ZW1zLmxlbmd0aCA/IDAgOiAtMTsNCiAgICAgICAgcmVuZGVyTGlzdChmYWxzZSk7DQogICAgICAgIGlmIChzZWxlY3RlZCA+PSAwICYmIHByZXZpZXdPbikgcmVxdWVzdFByZXZpZXcoaXRlbXNbc2VsZWN0ZWRdKTsNCiAgICAgICAgZWxzZSBpZiAoIWl0ZW1zLmxlbmd0aCkgew0KICAgICAgICAgIGlmIChwdkJvZHkpIHB2Qm9keS5jbGFzc0xpc3QucmVtb3ZlKCd0ZXh0LW1vZGUnKTsNCiAgICAgICAgICBwdk1ldGEudGV4dENvbnRlbnQgPSAn6YCJ5oup5paH5Lu25Lul6aKE6KeIJzsNCiAgICAgICAgICBwdk1lZGlhLmlubmVySFRNTCA9ICc8ZGl2IGNsYXNzPSJwaCI+6aKE6KeI5Yy6PC9kaXY+JzsNCiAgICAgICAgICBwdlRleHQuc3R5bGUuZGlzcGxheSA9ICdub25lJzsNCiAgICAgICAgfQ0KICAgICAgfQ0KICAgICAgdXBkYXRlQ291bnQoKTsNCiAgICAgIHJlcXVlc3RBbmltYXRpb25GcmFtZShtYXliZUZpbGxWaWV3cG9ydCk7DQogICAgfSBjYXRjaCAoZSkgew0KICAgICAgY29uc29sZS5lcnJvcihlKTsNCiAgICAgIGxvYWRpbmdNb3JlID0gZmFsc2U7DQogICAgICBjb3VudEVsLnRleHRDb250ZW50ID0gJ+e7k+aenOabtOaWsOWksei0pSc7DQogICAgfQ0KICB9Ow0KDQogIHdpbmRvdy5fX3NldFByZXZpZXcgPSAocGF5bG9hZCkgPT4gew0KICAgIHRyeSB7DQogICAgICBjb25zdCBkYXRhID0gdHlwZW9mIHBheWxvYWQgPT09ICdzdHJpbmcnID8gSlNPTi5wYXJzZShwYXlsb2FkKSA6IHBheWxvYWQ7DQogICAgICBjb25zdCBraW5kID0gZGF0YS5raW5kIHx8ICdub25lJzsNCiAgICAgIGNvbnN0IGJpdHMgPSBbXTsNCiAgICAgIGNvbnN0IGRydk1hdGNoID0gU3RyaW5nKGRhdGEucGF0aCB8fCAnJykubWF0Y2goL14oW0EtWmEtel0pOi8pOw0KICAgICAgaWYgKGRydk1hdGNoKSB7DQogICAgICAgIGNvbnN0IGxldHRlciA9IGRydk1hdGNoWzFdLnRvVXBwZXJDYXNlKCk7DQogICAgICAgIGNvbnN0IGhpdCA9IChkcml2ZU1ldGEuZHJpdmVzIHx8IFtdKS5maW5kKGQgPT4gU3RyaW5nKGQubGV0dGVyIHx8ICcnKS50b1VwcGVyQ2FzZSgpID09PSBsZXR0ZXIpOw0KICAgICAgICBjb25zdCBpY28gPSAoaGl0ICYmIGhpdC5pY29uKSA/ICgnPGltZyBzcmM9IicgKyBlc2NhcGVIdG1sKGhpdC5pY29uKSArICciIGFsdD0iIj4nKSA6ICcnOw0KICAgICAgICBjb25zdCBsYWJlbCA9IChoaXQgJiYgaGl0LmxhYmVsKSA/IGhpdC5sYWJlbCA6IChsZXR0ZXIgKyAnOicpOw0KICAgICAgICBiaXRzLnB1c2goJzxzcGFuIGNsYXNzPSJkcnYiPicgKyBpY28gKyBlc2NhcGVIdG1sKGxhYmVsKSArICc8L3NwYW4+Jyk7DQogICAgICB9DQogICAgICBpZiAoZGF0YS5lbmNvZGluZykgYml0cy5wdXNoKCfnvJbnoIEgPGI+JyArIGVzY2FwZUh0bWwoZGF0YS5lbmNvZGluZykgKyAnPC9iPicpOw0KICAgICAgaWYgKGRhdGEuc2l6ZVRleHQpIGJpdHMucHVzaCgn5aSn5bCPIDxiPicgKyBlc2NhcGVIdG1sKGRhdGEuc2l6ZVRleHQpICsgJzwvYj4nKTsNCiAgICAgIGlmIChkYXRhLmRpbXMpIGJpdHMucHVzaCgn5bC65a+4IDxiPicgKyBlc2NhcGVIdG1sKGRhdGEuZGltcykgKyAnPC9iPicpOw0KICAgICAgaWYgKGRhdGEubXRpbWUpIGJpdHMucHVzaCgn5L+u5pS5IDxiPicgKyBlc2NhcGVIdG1sKGRhdGEubXRpbWUpICsgJzwvYj4nKTsNCiAgICAgIHB2TWV0YS5pbm5lckhUTUwgPSBiaXRzLmpvaW4oJzxzcGFuIHN0eWxlPSJvcGFjaXR5Oi4zNSI+wrc8L3NwYW4+JykgfHwgJ+mihOiniCc7DQogICAgICBwdlRleHQuc3R5bGUuZGlzcGxheSA9ICdub25lJzsNCiAgICAgIGlmIChwdkJvZHkpIHB2Qm9keS5jbGFzc0xpc3QucmVtb3ZlKCd0ZXh0LW1vZGUnKTsNCg0KICAgICAgaWYgKGtpbmQgPT09ICdpbWFnZScgJiYgZGF0YS51cmwpIHsNCiAgICAgICAgcHZNZWRpYS5pbm5lckhUTUwgPSAnJzsNCiAgICAgICAgY29uc3QgaW1nID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnaW1nJyk7DQogICAgICAgIGltZy5zcmMgPSBkYXRhLnVybDsNCiAgICAgICAgaW1nLmFsdCA9ICcnOw0KICAgICAgICBwdk1lZGlhLmFwcGVuZENoaWxkKGltZyk7DQogICAgICB9IGVsc2UgaWYgKGtpbmQgPT09ICd2aWRlbycpIHsNCiAgICAgICAgcHZNZWRpYS5pbm5lckhUTUwgPSAnJzsNCiAgICAgICAgcHZNZWRpYS5zdHlsZS5mbGV4RGlyZWN0aW9uID0gJ2NvbHVtbic7DQogICAgICAgIGlmIChkYXRhLnVybCkgew0KICAgICAgICAgIGNvbnN0IHYgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCd2aWRlbycpOw0KICAgICAgICAgIHYuY29udHJvbHMgPSB0cnVlOw0KICAgICAgICAgIHYucHJlbG9hZCA9ICdtZXRhZGF0YSc7DQogICAgICAgICAgdi5zcmMgPSBkYXRhLnVybDsNCiAgICAgICAgICB2LnN0eWxlLm1heFdpZHRoID0gJzEwMCUnOw0KICAgICAgICAgIHYuc3R5bGUubWF4SGVpZ2h0ID0gZGF0YS50aHVtYiA/ICc3MCUnIDogJzEwMCUnOw0KICAgICAgICAgIHYub25lcnJvciA9ICgpID0+IHsNCiAgICAgICAgICAgIGlmIChkYXRhLnRodW1iKSB7DQogICAgICAgICAgICAgIHYucmVwbGFjZVdpdGgoT2JqZWN0LmFzc2lnbihkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdpbWcnKSwgew0KICAgICAgICAgICAgICAgIHNyYzogZGF0YS50aHVtYiwgc3R5bGU6ICdtYXgtd2lkdGg6MTAwJTttYXgtaGVpZ2h0OjgwJTtvYmplY3QtZml0OmNvbnRhaW4nDQogICAgICAgICAgICAgIH0pKTsNCiAgICAgICAgICAgIH0NCiAgICAgICAgICB9Ow0KICAgICAgICAgIHB2TWVkaWEuYXBwZW5kQ2hpbGQodik7DQogICAgICAgIH0gZWxzZSBpZiAoZGF0YS50aHVtYikgew0KICAgICAgICAgIGNvbnN0IGltZyA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2ltZycpOw0KICAgICAgICAgIGltZy5zcmMgPSBkYXRhLnRodW1iOw0KICAgICAgICAgIGltZy5zdHlsZS5tYXhXaWR0aCA9ICcxMDAlJzsNCiAgICAgICAgICBpbWcuc3R5bGUubWF4SGVpZ2h0ID0gJzgwJSc7DQogICAgICAgICAgaW1nLnN0eWxlLm9iamVjdEZpdCA9ICdjb250YWluJzsNCiAgICAgICAgICBwdk1lZGlhLmFwcGVuZENoaWxkKGltZyk7DQogICAgICAgIH0gZWxzZSB7DQogICAgICAgICAgcHZNZWRpYS5pbm5lckhUTUwgPSAnPGRpdiBjbGFzcz0icGgiPuaXoOazlemihOiniOatpOinhumike+8jOivt+WPjOWHu+aJk+W8gDwvZGl2Pic7DQogICAgICAgIH0NCiAgICAgIH0gZWxzZSBpZiAoa2luZCA9PT0gJ2F1ZGlvJykgew0KICAgICAgICBwdk1lZGlhLmlubmVySFRNTCA9ICcnOw0KICAgICAgICBjb25zdCB3cmFwID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnZGl2Jyk7DQogICAgICAgIHdyYXAuY2xhc3NOYW1lID0gJ3B2LWZpbGVpbmZvJzsNCiAgICAgICAgd3JhcC5zdHlsZS5iYWNrZ3JvdW5kID0gJyMzZjQ0NTAnOw0KICAgICAgICB3cmFwLnN0eWxlLmNvbG9yID0gJyNlNWU3ZWInOw0KICAgICAgICBpZiAoZGF0YS5pY29uKSB3cmFwLmlubmVySFRNTCA9ICc8aW1nIGNsYXNzPSJiaWctaWNvIiBzcmM9IicgKyBlc2NhcGVIdG1sKGRhdGEuaWNvbikgKyAnIiBhbHQ9IiI+JzsNCiAgICAgICAgd3JhcC5pbm5lckhUTUwgKz0gJzxkaXYgY2xhc3M9ImZuIiBzdHlsZT0iY29sb3I6I2ZmZiI+JyArIGVzY2FwZUh0bWwoZGF0YS5uYW1lIHx8ICcnKSArICc8L2Rpdj4nOw0KICAgICAgICBwdk1lZGlhLmFwcGVuZENoaWxkKHdyYXApOw0KICAgICAgICBpZiAoZGF0YS51cmwpIHsNCiAgICAgICAgICBjb25zdCBhID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnYXVkaW8nKTsNCiAgICAgICAgICBhLmNvbnRyb2xzID0gdHJ1ZTsNCiAgICAgICAgICBhLnNyYyA9IGRhdGEudXJsOw0KICAgICAgICAgIGEuc3R5bGUud2lkdGggPSAnODYlJzsNCiAgICAgICAgICBhLnN0eWxlLm1hcmdpblRvcCA9ICcxMnB4JzsNCiAgICAgICAgICB3cmFwLmFwcGVuZENoaWxkKGEpOw0KICAgICAgICB9DQogICAgICB9IGVsc2UgaWYgKGtpbmQgPT09ICdwZGYnICYmIGRhdGEudXJsKSB7DQogICAgICAgIHB2TWVkaWEuaW5uZXJIVE1MID0gJyc7DQogICAgICAgIGNvbnN0IGVtYiA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2VtYmVkJyk7DQogICAgICAgIGVtYi5jbGFzc05hbWUgPSAncGRmJzsNCiAgICAgICAgZW1iLnR5cGUgPSAnYXBwbGljYXRpb24vcGRmJzsNCiAgICAgICAgZW1iLnNyYyA9IGRhdGEudXJsOw0KICAgICAgICBwdk1lZGlhLmFwcGVuZENoaWxkKGVtYik7DQogICAgICB9IGVsc2UgaWYgKGtpbmQgPT09ICd0ZXh0Jykgew0KICAgICAgICBpZiAocHZCb2R5KSBwdkJvZHkuY2xhc3NMaXN0LmFkZCgndGV4dC1tb2RlJyk7DQogICAgICAgIHB2TWVkaWEuaW5uZXJIVE1MID0gJyc7DQogICAgICAgIHB2VGV4dC5zdHlsZS5kaXNwbGF5ID0gJ2ZsZXgnOw0KICAgICAgICBwdlRleHRIZC50ZXh0Q29udGVudCA9IGRhdGEudGV4dFRpdGxlIHx8ICfpooTop4jliY0gMjBLQiDlhoXlrrknOw0KICAgICAgICBwdlByZS50ZXh0Q29udGVudCA9IGRhdGEudGV4dCB8fCAnJzsNCiAgICAgIH0gZWxzZSBpZiAoa2luZCA9PT0gJ2ZvbGRlcicgfHwga2luZCA9PT0gJ2ZpbGVpbmZvJykgew0KICAgICAgICAvLyBBbHdheXMgcHJlZmVyIGNsZWFuIHNoZWxsIGljb24g4oCUIG5ldmVyIHVzZSBibGFjay1tYXR0ZSB0aHVtYm5haWxzIGhlcmUNCiAgICAgICAgY29uc3QgaWNvU3JjID0gZGF0YS5pY29uIHx8ICcnOw0KICAgICAgICBjb25zdCBpY28gPSBpY29TcmMNCiAgICAgICAgICA/ICc8aW1nIGNsYXNzPSJiaWctaWNvIiBzcmM9IicgKyBlc2NhcGVIdG1sKGljb1NyYykgKyAnIiBhbHQ9IiI+Jw0KICAgICAgICAgIDogJzxkaXYgY2xhc3M9ImJpZy1pY28iIHN0eWxlPSJmb250LXNpemU6MzZweDtsaW5lLWhlaWdodDo0OHB4Ij4nICsgKGtpbmQgPT09ICdmb2xkZXInID8gJ/Cfk4EnIDogJ/Cfk4QnKSArICc8L2Rpdj4nOw0KICAgICAgICBjb25zdCByb3dzID0gW107DQogICAgICAgIGlmIChkYXRhLnNpemVUZXh0KSByb3dzLnB1c2goWyflpKflsI8nLCBkYXRhLnNpemVUZXh0XSk7DQogICAgICAgIGlmIChkYXRhLm10aW1lKSByb3dzLnB1c2goWyfkv67mlLnml7bpl7QnLCBkYXRhLm10aW1lXSk7DQogICAgICAgIGlmIChkYXRhLmRpciB8fCBkYXRhLnBhdGgpIHJvd3MucHVzaChbJ+aJgOWcqOi3r+W+hCcsIGRhdGEuZGlyIHx8IGRhdGEucGF0aF0pOw0KICAgICAgICBjb25zdCBrdiA9IHJvd3MubGVuZ3RoDQogICAgICAgICAgPyAnPGRpdiBjbGFzcz0ia3YiPicgKyByb3dzLm1hcCgoW2ssIHZdKSA9Pg0KICAgICAgICAgICAgICAnPGRpdiBjbGFzcz0ia3Ytcm93Ij48c3BhbiBjbGFzcz0iayI+JyArIGVzY2FwZUh0bWwoaykgKyAnPC9zcGFuPicNCiAgICAgICAgICAgICAgKyAnPHNwYW4gY2xhc3M9InYiPicgKyBlc2NhcGVIdG1sKHYpICsgJzwvc3Bhbj48L2Rpdj4nDQogICAgICAgICAgICApLmpvaW4oJycpICsgJzwvZGl2PicNCiAgICAgICAgICA6ICcnOw0KICAgICAgICBsZXQga2lkcyA9ICcnOw0KICAgICAgICBpZiAoQXJyYXkuaXNBcnJheShkYXRhLmNoaWxkcmVuKSAmJiBkYXRhLmNoaWxkcmVuLmxlbmd0aCkgew0KICAgICAgICAgIGtpZHMgPSAnPGRpdiBjbGFzcz0ia2lkcyI+PGI+5YaF5a656aKE6KeIPC9iPjxicj4nDQogICAgICAgICAgICArIGRhdGEuY2hpbGRyZW4ubWFwKGMgPT4gZXNjYXBlSHRtbChjKSkuam9pbignPGJyPicpICsgJzwvZGl2Pic7DQogICAgICAgIH0NCiAgICAgICAgY29uc3QgaGludCA9IGRhdGEuaGludA0KICAgICAgICAgID8gJzxkaXYgY2xhc3M9ImhpbnQiPicgKyBlc2NhcGVIdG1sKGRhdGEuaGludCkgKyAnPC9kaXY+Jw0KICAgICAgICAgIDogJyc7DQogICAgICAgIHB2TWVkaWEuc3R5bGUuYmFja2dyb3VuZCA9ICcjZjdmOGZiJzsNCiAgICAgICAgcHZNZWRpYS5pbm5lckhUTUwgPSAnPGRpdiBjbGFzcz0icHYtZmlsZWluZm8iPicgKyBpY28NCiAgICAgICAgICArICc8ZGl2IGNsYXNzPSJmbiI+JyArIGVzY2FwZUh0bWwoZGF0YS5uYW1lIHx8ICcnKSArICc8L2Rpdj4nDQogICAgICAgICAgKyBoaW50ICsga3YgKyBraWRzICsgJzwvZGl2Pic7DQogICAgICB9IGVsc2Ugew0KICAgICAgICBwdk1lZGlhLmlubmVySFRNTCA9ICc8ZGl2IGNsYXNzPSJwaCI+JyArIGVzY2FwZUh0bWwoZGF0YS5tZXNzYWdlIHx8ICfml6Dms5XpooTop4jmraTnsbvlnosnKSArICc8L2Rpdj4nOw0KICAgICAgfQ0KICAgIH0gY2F0Y2ggKGUpIHt9DQogIH07DQoNCiAgZnVuY3Rpb24gZG9TZWFyY2goKSB7DQogICAgY29uc3QgcSA9IHFFbC52YWx1ZSB8fCAnJzsNCiAgICBjb3VudEVsLnRleHRDb250ZW50ID0gJ+aQnOe0ouS4reKApic7DQogICAgbG9hZGluZ01vcmUgPSBmYWxzZTsNCiAgICBoYXNNb3JlID0gZmFsc2U7DQogICAgY2FsbEhvc3QoJ3NlYXJjaCcsIHEsIGNhdCwgc29ydCwgMCk7DQogIH0NCiAgZnVuY3Rpb24gc2NoZWR1bGVTZWFyY2goKSB7DQogICAgY2xlYXJUaW1lb3V0KHNlYXJjaFRpbWVyKTsNCiAgICBzZWFyY2hUaW1lciA9IHNldFRpbWVvdXQoZG9TZWFyY2gsIDE4MCk7DQogIH0NCg0KICBkb2N1bWVudC5xdWVyeVNlbGVjdG9yQWxsKCcuY2F0JykuZm9yRWFjaChidG4gPT4gew0KICAgIGJ0bi5hZGRFdmVudExpc3RlbmVyKCdjbGljaycsICgpID0+IHsNCiAgICAgIGRvY3VtZW50LnF1ZXJ5U2VsZWN0b3JBbGwoJy5jYXQnKS5mb3JFYWNoKGIgPT4gYi5jbGFzc0xpc3QucmVtb3ZlKCdvbicpKTsNCiAgICAgIGJ0bi5jbGFzc0xpc3QuYWRkKCdvbicpOw0KICAgICAgY2F0ID0gYnRuLmRhdGFzZXQuY2F0Ow0KICAgICAgZG9TZWFyY2goKTsNCiAgICB9KTsNCiAgfSk7DQogIHFFbC5hZGRFdmVudExpc3RlbmVyKCdpbnB1dCcsICgpID0+IHsNCiAgICBzeW5jQ2xlYXJCdG4oKTsNCiAgICBzY2hlZHVsZVNlYXJjaCgpOw0KICAgIGNsZWFyVGltZW91dChoaXN0SWRsZVRpbWVyKTsNCiAgICBoaXN0SWRsZVRpbWVyID0gc2V0VGltZW91dCgoKSA9PiBwdXNoSGlzdChxRWwudmFsdWUgfHwgJycpLCAxMjAwKTsNCiAgfSk7DQogIHFFbC5hZGRFdmVudExpc3RlbmVyKCdrZXlkb3duJywgZSA9PiB7DQogICAgaWYgKGUua2V5ID09PSAnRW50ZXInKSB7DQogICAgICBjbGVhclRpbWVvdXQoaGlzdElkbGVUaW1lcik7DQogICAgICBwdXNoSGlzdChxRWwudmFsdWUgfHwgJycpOw0KICAgICAgZG9TZWFyY2goKTsNCiAgICB9IGVsc2UgaWYgKGUua2V5ID09PSAnRXNjYXBlJyAmJiAocUVsLnZhbHVlIHx8ICcnKSkgew0KICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsNCiAgICAgIGNsZWFyU2VhcmNoKCk7DQogICAgfQ0KICB9KTsNCiAgcUVsLmFkZEV2ZW50TGlzdGVuZXIoJ2JsdXInLCAoKSA9PiB7DQogICAgY2xlYXJUaW1lb3V0KGhpc3RJZGxlVGltZXIpOw0KICAgIHB1c2hIaXN0KHFFbC52YWx1ZSB8fCAnJyk7DQogIH0pOw0KDQogIGZ1bmN0aW9uIGZvY3VzU2VhcmNoKCkgew0KICAgIHRyeSB7DQogICAgICBxRWwuZm9jdXMoKTsNCiAgICAgIHFFbC5zZWxlY3QoKTsNCiAgICB9IGNhdGNoIChfKSB7fQ0KICB9DQogIHdpbmRvdy5fX2ZvY3VzU2VhcmNoID0gZm9jdXNTZWFyY2g7DQoNCiAgZnVuY3Rpb24gaXNWaWRlb0Z1bGxzY3JlZW4oKSB7DQogICAgY29uc3QgZnMgPSBkb2N1bWVudC5mdWxsc2NyZWVuRWxlbWVudCB8fCBkb2N1bWVudC53ZWJraXRGdWxsc2NyZWVuRWxlbWVudCB8fCBkb2N1bWVudC5tc0Z1bGxzY3JlZW5FbGVtZW50Ow0KICAgIGlmIChmcykgcmV0dXJuIHRydWU7DQogICAgY29uc3QgdmlkcyA9IGRvY3VtZW50LnF1ZXJ5U2VsZWN0b3JBbGwoJ3ZpZGVvJyk7DQogICAgZm9yIChjb25zdCB2IG9mIHZpZHMpIHsNCiAgICAgIGlmICh2LndlYmtpdERpc3BsYXlpbmdGdWxsc2NyZWVuIHx8IHYubW96RnVsbFNjcmVlbiB8fCB2Lm1zRnVsbHNjcmVlbkVsZW1lbnQpIHJldHVybiB0cnVlOw0KICAgIH0NCiAgICByZXR1cm4gZmFsc2U7DQogIH0NCiAgZnVuY3Rpb24gZXhpdFZpZGVvRnVsbHNjcmVlbigpIHsNCiAgICB0cnkgew0KICAgICAgaWYgKGRvY3VtZW50LmZ1bGxzY3JlZW5FbGVtZW50IHx8IGRvY3VtZW50LndlYmtpdEZ1bGxzY3JlZW5FbGVtZW50KSB7DQogICAgICAgIGNvbnN0IHAgPSBkb2N1bWVudC5leGl0RnVsbHNjcmVlbiA/IGRvY3VtZW50LmV4aXRGdWxsc2NyZWVuKCkNCiAgICAgICAgICA6IChkb2N1bWVudC53ZWJraXRFeGl0RnVsbHNjcmVlbiAmJiBkb2N1bWVudC53ZWJraXRFeGl0RnVsbHNjcmVlbigpKTsNCiAgICAgICAgcmV0dXJuIHRydWU7DQogICAgICB9DQogICAgfSBjYXRjaCAoXykge30NCiAgICBjb25zdCB2aWRzID0gZG9jdW1lbnQucXVlcnlTZWxlY3RvckFsbCgndmlkZW8nKTsNCiAgICBmb3IgKGNvbnN0IHYgb2Ygdmlkcykgew0KICAgICAgdHJ5IHsNCiAgICAgICAgaWYgKHYud2Via2l0RGlzcGxheWluZ0Z1bGxzY3JlZW4gJiYgdi53ZWJraXRFeGl0RnVsbHNjcmVlbikgew0KICAgICAgICAgIHYud2Via2l0RXhpdEZ1bGxzY3JlZW4oKTsNCiAgICAgICAgICByZXR1cm4gdHJ1ZTsNCiAgICAgICAgfQ0KICAgICAgICBpZiAodi5leGl0RnVsbHNjcmVlbikgeyB2LmV4aXRGdWxsc2NyZWVuKCk7IHJldHVybiB0cnVlOyB9DQogICAgICB9IGNhdGNoIChfKSB7fQ0KICAgIH0NCiAgICByZXR1cm4gZmFsc2U7DQogIH0NCiAgd2luZG93Ll9faGFuZGxlRXNjID0gKCkgPT4gew0KICAgIGlmIChpc1ZpZGVvRnVsbHNjcmVlbigpIHx8IGV4aXRWaWRlb0Z1bGxzY3JlZW4oKSkgew0KICAgICAgdHJ5IHsgZXhpdFZpZGVvRnVsbHNjcmVlbigpOyB9IGNhdGNoIChfKSB7fQ0KICAgICAgcG9zdCgnZXNjQ29uc3VtZWQnKTsNCiAgICAgIHJldHVybiB0cnVlOw0KICAgIH0NCiAgICBwb3N0KCdlc2NIaWRlJyk7DQogICAgcmV0dXJuIGZhbHNlOw0KICB9Ow0KICBkb2N1bWVudC5hZGRFdmVudExpc3RlbmVyKCdrZXlkb3duJywgZSA9PiB7DQogICAgaWYgKChlLmN0cmxLZXkgfHwgZS5tZXRhS2V5KSAmJiAhZS5hbHRLZXkgJiYgIWUuc2hpZnRLZXkgJiYgU3RyaW5nKGUua2V5KS50b0xvd2VyQ2FzZSgpID09PSAnZicpIHsNCiAgICAgIGUucHJldmVudERlZmF1bHQoKTsNCiAgICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7DQogICAgICBmb2N1c1NlYXJjaCgpOw0KICAgICAgcmV0dXJuOw0KICAgIH0NCiAgICBpZiAoZS5rZXkgPT09ICdFc2NhcGUnIHx8IGUua2V5ID09PSAnRXNjJykgew0KICAgICAgaWYgKGlzVmlkZW9GdWxsc2NyZWVuKCkpIHsNCiAgICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOw0KICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOw0KICAgICAgICBleGl0VmlkZW9GdWxsc2NyZWVuKCk7DQogICAgICAgIHBvc3QoJ2VzY0NvbnN1bWVkJyk7DQogICAgICB9DQogICAgfQ0KICB9LCB0cnVlKTsNCiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2J0bi1zb3J0Jykub25jbGljayA9ICgpID0+IHsNCiAgICBzb3J0ID0gc29ydCA9PT0gJ2RhdGUtZGVzYycgPyAnZGF0ZS1hc2MnIDogKHNvcnQgPT09ICdkYXRlLWFzYycgPyAnbmFtZS1hc2MnIDogKHNvcnQgPT09ICduYW1lLWFzYycgPyAnc2l6ZS1kZXNjJyA6ICdkYXRlLWRlc2MnKSk7DQogICAgY29uc3QgbWFwID0gew0KICAgICAgJ2RhdGUtZGVzYyc6ICfmjInkv67mlLnml7bpl7TpmY3luo8nLA0KICAgICAgJ2RhdGUtYXNjJzogJ+aMieS/ruaUueaXtumXtOWNh+W6jycsDQogICAgICAnbmFtZS1hc2MnOiAn5oyJ5ZCN56ew5Y2H5bqPJywNCiAgICAgICdzaXplLWRlc2MnOiAn5oyJ5aSn5bCP6ZmN5bqPJw0KICAgIH07DQogICAgc29ydExhYmVsLnRleHRDb250ZW50ID0gbWFwW3NvcnRdIHx8IHNvcnQ7DQogICAgZG9TZWFyY2goKTsNCiAgfTsNCiAgY2hrUHJldmlldy5hZGRFdmVudExpc3RlbmVyKCdjaGFuZ2UnLCAoKSA9PiB7DQogICAgcHJldmlld09uID0gISFjaGtQcmV2aWV3LmNoZWNrZWQ7DQogICAgcHJldmlldy5jbGFzc0xpc3QudG9nZ2xlKCdvZmYnLCAhcHJldmlld09uKTsNCiAgICBpZiAocHJldmlld09uICYmIHNlbGVjdGVkID49IDApIHJlcXVlc3RQcmV2aWV3KGl0ZW1zW3NlbGVjdGVkXSk7DQogIH0pOw0KICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYnRuLXNldHRpbmdzJykub25jbGljayA9ICgpID0+IHBvc3QoJ3NldHRpbmdzJyk7DQogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd0b3AnKS5hZGRFdmVudExpc3RlbmVyKCdtb3VzZWRvd24nLCBlID0+IHsNCiAgICBpZiAoZS5idXR0b24gIT09IDApIHJldHVybjsNCiAgICBpZiAoZS50YXJnZXQuY2xvc2VzdCgnLm5vLWRyYWcnKSkgcmV0dXJuOw0KICAgIGNhbGxIb3N0KCdkcmFnJyk7DQogICAgcG9zdCgnZHJhZycpOw0KICB9KTsNCg0KICAvLyDnlKggVVJMID9icD0g5bim5YWlIEFISyDlvZPliY3ov5vluqbvvIzpgb/lhY3lhYjpl6ogMCUg5YaN56uL5Yi76L+b5Li755WM6Z2iDQogIHRyeSB7DQogICAgY29uc3QgYnAgPSBNYXRoLm1heCgxLCBNYXRoLm1pbig5OSwgcGFyc2VJbnQobmV3IFVSTFNlYXJjaFBhcmFtcyhsb2NhdGlvbi5zZWFyY2gpLmdldCgnYnAnKSB8fCAnMjAnLCAxMCkgfHwgMjApKTsNCiAgICBzZXRCb290UGN0KGJwKTsNCiAgICBjb25zdCB0MSA9IGRvY3VtZW50LnF1ZXJ5U2VsZWN0b3IoJyNib290IC50MScpOw0KICAgIGlmICh0MSAmJiBicCA+PSA5MCkgdDEudGV4dENvbnRlbnQgPSAn5Y2z5bCG5a6M5oiQJzsNCiAgICBlbHNlIGlmICh0MSAmJiBicCA+PSA0MCkgdDEudGV4dENvbnRlbnQgPSAn56OB55uY57Si5byV5LitJzsNCiAgfSBjYXRjaCAoZSkge30NCiAgcG9zdCgndWlSZWFkeScpOw0KfSkoKTsNCjwvc2NyaXB0Pg0KPC9ib2R5Pg0KPC9odG1sPg0K
;########################################################################################################### local_search_index.html

