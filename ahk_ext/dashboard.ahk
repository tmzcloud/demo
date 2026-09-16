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
        ; 与快捷键4 托盘 icon1 同款红心
        TraySetIcon("HICON: " Base64PngToHIcon(AppHeartIconB64(), 16))
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
global lastQuery := "", lastCat := "all", lastSort := "date-desc", lastDrive := ""
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
    guiWin := Gui("+Resize", "仪表盘")
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
    global wv, wvCore, HTML_FILE, SEARCH_DIR, APP_HOST, STORE_HOST, wvBuilding, APP_DIR, pageNavIssued, bootPct, bootStubShown, guiWin
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
        SetTimer(() => RunSearch(lastQuery, lastCat, lastSort, 0, 0, lastDrive), -40)
    SetTimer(FocusSearchBox, -60)
    SetTimer(HideLoadSplash, -80)
}

; 点标题栏 X / Esc / 页面关闭 → 释放 WebView2 省内存；Everything 继续跑，下次打开秒搜
; 真正退出：托盘「退出」→ ExitDashboard（才会停 Everything）
OnDashboardClose(*) {
    TearDownDashboardUi()
}

HideWindow() {
    TearDownDashboardUi()
}

; 关闭界面并结束本窗口的 msedgewebview2（不动 Everything、不误杀剪贴板 WebView）
TearDownDashboardUi(*) {
    global guiWin, wv, wvCore, wvBuilding, uiReady, mainUiEntered, mainUiEntering
    global pageNavIssued, bootRevealDone, bootStubShown, bootOn, webMsgSub, showWhenReady
    static tearing := false
    if tearing
        return
    tearing := true
    try {
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
                if InStr(sample, "local_search_ui:2026-03-17g") && InStr(sample, "--ring: #e42079") {
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
            if InStr(sample, "local_search_ui:2026-03-17g") && InStr(sample, "--ring: #e42079") {
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

; 与快捷键4 getResourceBase64("icon1") 同款红心 PNG（托盘初始图标）
AppHeartIconB64() {
    return "iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAACXBIWXMAAA7EAAAOxAGVKw4bAAACUklEQVQ4y22Ry2udVRTFf2ufcxMfoCDqQB35aFUwtCLOJOrEuVikKE5Do6DoyL9ArFMNhYsTxYEiDkQQFEQLFoSqVWIkCKIdFNHUZ9Le3PudvRx83y3RZsGGs89Ze5+19hYD3rn7CLfmzVWmqpF/lsn04c0TAHywdIxbLl6xYBOdW/f91X90T337JgACOH3wWF306Mma5WnMAcPvKb/XjfKlJHOxqy9Wx6O2r0/8YyvttVltb9y7sTbVqdtW4poYvbxAfb64hiwwNJIseabhbsFxXzgASExTy065dlGzZ+tVpT5YXZ4r1CguhIUNIZGpQxUoFGQhIEmEQtlWXfRhrY6VolpLBpHqiRZIhGKYUK9KFiFwCFCMnCt1RCyFhXIIhqLBiodBieHsoDhBopilSEjNGRJ7IUxgsPfc9VHoLUXDZ2wPPxn+1wKEhsZzFSnTlOyW7qtI57iRmTIZiZWXtZnDGEeSMl10+U/dHUeLPNnR3k11ZPQE1CvyXLqHYvXvLRo7dfb++dj+SABf37F605Uafbbgenu4EBmoBZeE2xDGSrpo7NTdn86PJsvL6+OzAXD4h7VzM7WjM+UvVvZWSi+1l21SSaoxKdOt7bL7xPL6+Cww3xncs/nq6d3SHp+q+zXVyGgQiaPh6PPtOt36rV44+tb0k1PzurJ3SDduffHzwRvuPyl4JNC1KV3yvVNn5/6uk8c+5vNPj29u/mdPl+GbO585sNjq25U4BHChzDb+KpMjD3w33mCfRe+LL+9ava64vjJTq9tl8sJD669v7cf7FyA9OlKNwUFpAAAAAElFTkSuQmCC"
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

; 窗口/托盘用快捷键4 红心图标
SetWindowAppIcon(hwnd) {
    global hAppIconBig, hAppIconSmall
    if !hwnd
        return
    try {
        if !hAppIconBig {
            b64 := AppHeartIconB64()
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
            SetTimer(() => RunSearch("", "all", "date-desc", 0), -80)
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
        SetTimer(() => RunSearch("", "all", "date-desc", 0), -100)
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
        PushIndexPendingHint()
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
            SetTimer(() => RunSearch("", "all", "date-desc", 0), -150)
        else
            SetTimer(PushIndexPendingHint, -200)
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
    global pendingSearch, searchBusy, searchSeq, lastQuery, lastCat, lastSort, lastDrive
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
; PCFET0NUWVBFIGh0bWw+DQo8aHRtbCBsYW5nPSJ6aC1DTiI+DQo8aGVhZD4NCjxtZXRhIGNoYXJzZXQ9IlVURi04Ij4NCjxtZXRhIG5hbWU9InZpZXdwb3J0IiBjb250ZW50PSJ3aWR0aD1kZXZpY2Utd2lkdGgsIGluaXRpYWwtc2NhbGU9MSI+DQo8dGl0bGU+5Luq6KGo55uYPC90aXRsZT4NCjwhLS0gbG9jYWxfc2VhcmNoX3VpOjIwMjYtMDMtMTdnIC0tPg0KPHN0eWxlPg0KOnJvb3Qgew0KICAtLWJnOiAjZjNmNGY3Ow0KICAtLXBhbmVsOiAjZmZmZmZmOw0KICAtLWxpbmU6ICNlNmU4ZWU7DQogIC0tdHh0OiAjMWYyNDMwOw0KICAtLXR4dDI6ICM2YjcyODU7DQogIC0tdHh0MzogIzlhYTFiMjsNCiAgLS1hY2M6ICMzYjgyZjY7DQogIC0tYWNjMjogIzI1NjNlYjsNCiAgLS1uYW1lOiAjMTExODI3Ow0KICAtLW5hbWUtZXh0OiAjZWE1ODBjOw0KICAtLWhsOiAjZmVmMDhhOw0KICAtLWhsLXRleHQ6ICM4NTRkMGU7DQogIC0tc2VsOiAjZWVmMWY2Ow0KICAtLXNpZGU6ICNmNWY2Zjk7DQogIC0tY2hyb21lOiAjZjVmNmY5Ow0KICAtLXNpZGUtdzogMTQ4cHg7DQogIC0tcmluZzogI2U0MjA3OTsNCiAgLS1zaGFkb3c6IDAgMTBweCAzMHB4IHJnYmEoMjAsIDI4LCA0NSwgLjA4KTsNCiAgLS1yOiAxMHB4Ow0KICBmb250LWZhbWlseTogIlNlZ29lIFVJIiwgIk1pY3Jvc29mdCBZYUhlaSBVSSIsICJQaW5nRmFuZyBTQyIsIHNhbnMtc2VyaWY7DQp9DQoqIHsgYm94LXNpemluZzogYm9yZGVyLWJveDsgfQ0KaHRtbCwgYm9keSB7IG1hcmdpbjogMDsgaGVpZ2h0OiAxMDAlOyBiYWNrZ3JvdW5kOiB2YXIoLS1iZyk7IGNvbG9yOiB2YXIoLS10eHQpOyBvdmVyZmxvdzogaGlkZGVuOyB9DQpidXR0b24sIGlucHV0IHsgZm9udDogaW5oZXJpdDsgfQ0KI2FwcCB7IGRpc3BsYXk6IGZsZXg7IGZsZXgtZGlyZWN0aW9uOiBjb2x1bW47IGhlaWdodDogMTAwJTsgfQ0KDQovKiBpbmRleGluZyAqLw0KI2Jvb3Qgew0KICBkaXNwbGF5OiBub25lOyBmbGV4OiAxOyBhbGlnbi1pdGVtczogY2VudGVyOyBqdXN0aWZ5LWNvbnRlbnQ6IGNlbnRlcjsNCiAgZmxleC1kaXJlY3Rpb246IGNvbHVtbjsgZ2FwOiAyOHB4OyBiYWNrZ3JvdW5kOiAjZmZmOw0KfQ0KI2Jvb3Qub24geyBkaXNwbGF5OiBmbGV4OyB9DQoucmluZy13cmFwIHsgd2lkdGg6IDE2OHB4OyBoZWlnaHQ6IDE2OHB4OyBwb3NpdGlvbjogcmVsYXRpdmU7IH0NCi5yaW5nLXdyYXAgc3ZnIHsgd2lkdGg6IDEwMCU7IGhlaWdodDogMTAwJTsgdHJhbnNmb3JtOiByb3RhdGUoLTkwZGVnKTsgfQ0KLnJpbmctYmcgeyBmaWxsOiBub25lOyBzdHJva2U6ICNlY2VmZjQ7IHN0cm9rZS13aWR0aDogODsgfQ0KLnJpbmctZmcgeyBmaWxsOiBub25lOyBzdHJva2U6IHZhcigtLXJpbmcpOyBzdHJva2Utd2lkdGg6IDg7IHN0cm9rZS1saW5lY2FwOiByb3VuZDsNCiAgdHJhbnNpdGlvbjogc3Ryb2tlLWRhc2hvZmZzZXQgLjM1cyBlYXNlOyB9DQoucmluZy1sYWJlbCB7DQogIHBvc2l0aW9uOiBhYnNvbHV0ZTsgaW5zZXQ6IDA7IGRpc3BsYXk6IGZsZXg7IGZsZXgtZGlyZWN0aW9uOiBjb2x1bW47DQogIGFsaWduLWl0ZW1zOiBjZW50ZXI7IGp1c3RpZnktY29udGVudDogY2VudGVyOyBnYXA6IDZweDsNCn0NCi5yaW5nLWxhYmVsIC50MSB7IGZvbnQtc2l6ZTogMTZweDsgZm9udC13ZWlnaHQ6IDYwMDsgfQ0KLnJpbmctbGFiZWwgLnQyIHsgZm9udC1zaXplOiAyOHB4OyBmb250LXdlaWdodDogNzAwOyBjb2xvcjogIzExMTgyNzsgfQ0KLmJvb3QtaGludCB7IGNvbG9yOiB2YXIoLS10eHQyKTsgZm9udC1zaXplOiAxM3B4OyBtYXgtd2lkdGg6IDUyMHB4OyB0ZXh0LWFsaWduOiBjZW50ZXI7IGxpbmUtaGVpZ2h0OiAxLjY7IH0NCi5ib290LWhpbnQgYSB7IGNvbG9yOiB2YXIoLS1hY2MpOyB0ZXh0LWRlY29yYXRpb246IG5vbmU7IGN1cnNvcjogcG9pbnRlcjsgfQ0KLmJvb3QtaGludCBhOmhvdmVyIHsgdGV4dC1kZWNvcmF0aW9uOiB1bmRlcmxpbmU7IH0NCg0KLyogY2hyb21lICovDQojY2hyb21lIHsgZGlzcGxheTogZmxleDsgZmxleC1kaXJlY3Rpb246IGNvbHVtbjsgZmxleDogMTsgbWluLWhlaWdodDogMDsgfQ0KI2Nocm9tZS5oaWRkZW4geyBkaXNwbGF5OiBub25lOyB9DQojdG9wIHsNCiAgaGVpZ2h0OiA0OHB4OyBkaXNwbGF5OiBncmlkOw0KICBncmlkLXRlbXBsYXRlLWNvbHVtbnM6IHZhcigtLXNpZGUtdykgbWlubWF4KDAsIDFmcik7DQogIGFsaWduLWl0ZW1zOiBzdHJldGNoOyBwYWRkaW5nOiAwIDEwcHggMCAwOyBiYWNrZ3JvdW5kOiB2YXIoLS1jaHJvbWUpOw0KICBib3JkZXItYm90dG9tOiAwOyBib3gtc2l6aW5nOiBib3JkZXItYm94Ow0KICAtd2Via2l0LWFwcC1yZWdpb246IGRyYWc7IGFwcC1yZWdpb246IGRyYWc7DQp9DQojdG9wIC5uby1kcmFnLCAjdG9wIGJ1dHRvbiwgI3RvcCBpbnB1dCB7DQogIC13ZWJraXQtYXBwLXJlZ2lvbjogbm8tZHJhZzsgYXBwLXJlZ2lvbjogbm8tZHJhZzsNCn0NCiNkcml2ZS13cmFwIHsNCiAgcG9zaXRpb246IHJlbGF0aXZlOyB3aWR0aDogMTAwJTsNCiAgYm9yZGVyLXJpZ2h0OiAwOyBiYWNrZ3JvdW5kOiB2YXIoLS1jaHJvbWUpOw0KICBkaXNwbGF5OiBmbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOw0KfQ0KI2J0bi1kcml2ZSB7DQogIGRpc3BsYXk6IGZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGdhcDogOHB4Ow0KICB3aWR0aDogMTAwJTsgaGVpZ2h0OiAxMDAlOyBwYWRkaW5nOiAwIDEwcHg7DQogIGJvcmRlcjogMDsgYm9yZGVyLXJhZGl1czogMDsgYmFja2dyb3VuZDogdHJhbnNwYXJlbnQ7DQogIGNvbG9yOiB2YXIoLS10eHQpOyBmb250LXNpemU6IDEzLjVweDsgZm9udC13ZWlnaHQ6IDYwMDsNCiAgY3Vyc29yOiBwb2ludGVyOyB0ZXh0LWFsaWduOiBsZWZ0Ow0KfQ0KI2J0bi1kcml2ZTpob3ZlciB7IGJhY2tncm91bmQ6ICNlZWYxZjY7IGNvbG9yOiB2YXIoLS1hY2MyKTsgfQ0KI2J0bi1kcml2ZSAuZHJpdmUtaWNvIHsNCiAgd2lkdGg6IDIwcHg7IGhlaWdodDogMjBweDsgb2JqZWN0LWZpdDogY29udGFpbjsgZmxleC1zaHJpbms6IDA7DQogIGJhY2tncm91bmQ6IHRyYW5zcGFyZW50Ow0KfQ0KI2J0bi1kcml2ZSAuZHJpdmUtaWNvLmhpZGRlbiB7IGRpc3BsYXk6IG5vbmU7IH0NCiNidG4tZHJpdmUgLmNhcmV0IHsgZm9udC1zaXplOiAxMHB4OyBjb2xvcjogdmFyKC0tdHh0Myk7IG1hcmdpbi1sZWZ0OiBhdXRvOyB9DQojZHJpdmUtbGFiZWwgeyBvdmVyZmxvdzogaGlkZGVuOyB0ZXh0LW92ZXJmbG93OiBlbGxpcHNpczsgd2hpdGUtc3BhY2U6IG5vd3JhcDsgfQ0KI2RyaXZlLW1lbnUgew0KICBkaXNwbGF5OiBub25lOyBwb3NpdGlvbjogYWJzb2x1dGU7IHRvcDogMTAwJTsgbGVmdDogMDsgcmlnaHQ6IDA7IHotaW5kZXg6IDQwOw0KICB3aWR0aDogMTAwJTsgbWF4LWhlaWdodDogMzIwcHg7IG92ZXJmbG93OiBhdXRvOw0KICBiYWNrZ3JvdW5kOiAjZmZmOyBib3JkZXI6IDFweCBzb2xpZCB2YXIoLS1saW5lKTsgYm9yZGVyLXRvcDogMDsNCiAgYm94LXNoYWRvdzogdmFyKC0tc2hhZG93KTsgcGFkZGluZzogNHB4OyBib3JkZXItcmFkaXVzOiAwIDAgOHB4IDhweDsNCn0NCiNkcml2ZS1tZW51Lm9uIHsgZGlzcGxheTogYmxvY2s7IH0NCiNkcml2ZS1tZW51IGJ1dHRvbiB7DQogIGRpc3BsYXk6IGZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGdhcDogOHB4OyB3aWR0aDogMTAwJTsNCiAgdGV4dC1hbGlnbjogbGVmdDsgYm9yZGVyOiAwOyBiYWNrZ3JvdW5kOiB0cmFuc3BhcmVudDsNCiAgcGFkZGluZzogOHB4IDEwcHg7IGJvcmRlci1yYWRpdXM6IDZweDsgY3Vyc29yOiBwb2ludGVyOyBjb2xvcjogdmFyKC0tdHh0KTsgZm9udC1zaXplOiAxM3B4Ow0KfQ0KI2RyaXZlLW1lbnUgYnV0dG9uIGltZyB7DQogIHdpZHRoOiAyMHB4OyBoZWlnaHQ6IDIwcHg7IG9iamVjdC1maXQ6IGNvbnRhaW47IGZsZXgtc2hyaW5rOiAwOyBiYWNrZ3JvdW5kOiB0cmFuc3BhcmVudDsNCn0NCiNkcml2ZS1tZW51IGJ1dHRvbjpob3ZlciB7IGJhY2tncm91bmQ6ICNlZWYyZmY7IH0NCiNkcml2ZS1tZW51IGJ1dHRvbi5vbiB7IGJhY2tncm91bmQ6ICNlZmY2ZmY7IGNvbG9yOiB2YXIoLS1hY2MyKTsgZm9udC13ZWlnaHQ6IDYwMDsgfQ0KI3RvcC1yZXN0IHsNCiAgZGlzcGxheTogZ3JpZDsNCiAgZ3JpZC10ZW1wbGF0ZS1jb2x1bW5zOiBtaW5tYXgoMjgwcHgsIDEuMWZyKSBtaW5tYXgoMzIwcHgsIDEuMmZyKTsNCiAgYWxpZ24taXRlbXM6IHN0cmV0Y2g7IG1pbi13aWR0aDogMDsgbWluLWhlaWdodDogMDsNCiAgYmFja2dyb3VuZDogdmFyKC0tY2hyb21lKTsNCn0NCiN0b3AubW9kZS10b29sICN0b3AtcmVzdCB7DQogIGdyaWQtdGVtcGxhdGUtY29sdW1uczogMWZyOw0KfQ0KLyog5YWz6IGU5Y+l5p+E77ya5LuF5pCc57Si5qGG5Y2g5LiA5Y2K77yM5YiX6KGo5LuN5YWo5a69ICovDQojdG9wLm1vZGUtaGFuZGxlICN0b3AtcmVzdCB7DQogIGdyaWQtdGVtcGxhdGUtY29sdW1uczogbWlubWF4KDI4MHB4LCA1MCUpOw0KICBqdXN0aWZ5LWNvbnRlbnQ6IHN0YXJ0Ow0KfQ0KI3NlYXJjaC13cmFwIHsNCiAgZGlzcGxheTogZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsgbWluLXdpZHRoOiAwOyBoZWlnaHQ6IDEwMCU7DQogIHBhZGRpbmc6IDA7IGJvcmRlci1yaWdodDogMDsgYmFja2dyb3VuZDogdmFyKC0tY2hyb21lKTsNCn0NCiN0b3AubW9kZS10b29sICNzZWFyY2gtd3JhcCB7IHBhZGRpbmctcmlnaHQ6IDA7IH0NCiN0b3AubW9kZS10b29sICN0b3AtcHJldmlldyB7IGRpc3BsYXk6IG5vbmU7IH0NCiN0b3AubW9kZS1oYW5kbGUgI3RvcC1wcmV2aWV3IHsgZGlzcGxheTogbm9uZTsgfQ0KI3RvcC5tb2RlLWluZm8gI3NlYXJjaC13cmFwIHsgZGlzcGxheTogbm9uZSAhaW1wb3J0YW50OyB9DQojdG9wLm1vZGUtaW5mbyAjdG9wLXByZXZpZXcgeyBkaXNwbGF5OiBub25lOyB9DQojdG9wLm1vZGUtaW5mbyAjdG9wLXJlc3QgeyBncmlkLXRlbXBsYXRlLWNvbHVtbnM6IDFmcjsgbWluLWhlaWdodDogMDsgfQ0KI3NlYXJjaC1ib3ggew0KICBwb3NpdGlvbjogcmVsYXRpdmU7IGRpc3BsYXk6IGZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGdhcDogNHB4Ow0KICB3aWR0aDogMTAwJTsgaGVpZ2h0OiAzNHB4Ow0KICBib3JkZXI6IDFweCBzb2xpZCB2YXIoLS1saW5lKTsgYm9yZGVyLXJhZGl1czogOHB4Ow0KICBwYWRkaW5nOiAwIDRweCAwIDEwcHg7IGJhY2tncm91bmQ6ICNmYmZiZmQ7IG92ZXJmbG93OiB2aXNpYmxlOw0KfQ0KI3NlYXJjaC1ib3g6Zm9jdXMtd2l0aGluIHsNCiAgYm9yZGVyLWNvbG9yOiAjOTNjNWZkOw0KICBib3gtc2hhZG93OiAwIDAgMCAzcHggcmdiYSg1OSwxMzAsMjQ2LC4xNSk7DQogIGJhY2tncm91bmQ6ICNmZmY7DQp9DQojcSB7DQogIGZsZXg6IDE7IG1pbi13aWR0aDogMDsgaGVpZ2h0OiAxMDAlOw0KICBib3JkZXI6IDA7IGJvcmRlci1yYWRpdXM6IDA7IHBhZGRpbmc6IDA7IG91dGxpbmU6IG5vbmU7IGJhY2tncm91bmQ6IHRyYW5zcGFyZW50Ow0KICBmb250LXNpemU6IDEzLjVweDsgY29sb3I6IHZhcigtLXR4dCk7DQp9DQojcTo6cGxhY2Vob2xkZXIgeyBjb2xvcjogdmFyKC0tdHh0Myk7IH0NCiNidG4tY2xlYXIgew0KICBkaXNwbGF5OiBub25lOyBmbGV4LXNocmluazogMDsgaGVpZ2h0OiAyMnB4OyBwYWRkaW5nOiAwIDEwcHg7DQogIGJvcmRlcjogMDsgYm9yZGVyLXJhZGl1czogOTk5cHg7IGJhY2tncm91bmQ6ICNlZWYxZjY7DQogIGNvbG9yOiB2YXIoLS10eHQyKTsgZm9udC1zaXplOiAxMnB4OyBjdXJzb3I6IHBvaW50ZXI7IGxpbmUtaGVpZ2h0OiAyMnB4Ow0KfQ0KI2J0bi1jbGVhci5vbiB7IGRpc3BsYXk6IGlubGluZS1mbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBqdXN0aWZ5LWNvbnRlbnQ6IGNlbnRlcjsgfQ0KI2J0bi1jbGVhcjpob3ZlciB7IGJhY2tncm91bmQ6ICNlMmU4ZjA7IGNvbG9yOiB2YXIoLS10eHQpOyB9DQojYnRuLWhpc3Qgew0KICBmbGV4LXNocmluazogMDsgd2lkdGg6IDI0cHg7IGhlaWdodDogMjRweDsgYm9yZGVyOiAwOyBib3JkZXItcmFkaXVzOiA2cHg7DQogIGJhY2tncm91bmQ6IHRyYW5zcGFyZW50OyBjb2xvcjogdmFyKC0tdHh0Myk7IGZvbnQtc2l6ZTogMTBweDsNCiAgY3Vyc29yOiBwb2ludGVyOyBsaW5lLWhlaWdodDogMTsgcGFkZGluZzogMDsNCn0NCiNidG4taGlzdDpob3ZlciwgI2J0bi1oaXN0Lm9uIHsgYmFja2dyb3VuZDogI2VlZjJmZjsgY29sb3I6IHZhcigtLWFjYzIpOyB9DQojaGlzdC1tZW51IHsNCiAgZGlzcGxheTogbm9uZTsgcG9zaXRpb246IGFic29sdXRlOyB0b3A6IDEwMCU7IGxlZnQ6IC0xcHg7IHJpZ2h0OiAtMXB4OyB6LWluZGV4OiA0NTsNCiAgbWF4LWhlaWdodDogMjgwcHg7IG92ZXJmbG93OiBhdXRvOw0KICBiYWNrZ3JvdW5kOiAjZmZmOyBib3JkZXI6IDFweCBzb2xpZCB2YXIoLS1saW5lKTsgYm9yZGVyLXRvcDogMDsNCiAgYm94LXNoYWRvdzogMCA4cHggMThweCByZ2JhKDE1LCAyMywgNDIsIC4wOCk7IHBhZGRpbmc6IDJweCA0cHggNHB4Ow0KICBib3JkZXItcmFkaXVzOiAwIDAgOHB4IDhweDsNCn0NCiNoaXN0LW1lbnUub24geyBkaXNwbGF5OiBibG9jazsgfQ0KI3NlYXJjaC1ib3guaGlzdC1vcGVuIHsNCiAgYm9yZGVyLWJvdHRvbS1sZWZ0LXJhZGl1czogMDsgYm9yZGVyLWJvdHRvbS1yaWdodC1yYWRpdXM6IDA7DQp9DQojaGlzdC1tZW51IGJ1dHRvbiB7DQogIGRpc3BsYXk6IGJsb2NrOyB3aWR0aDogMTAwJTsgdGV4dC1hbGlnbjogbGVmdDsgYm9yZGVyOiAwOyBiYWNrZ3JvdW5kOiB0cmFuc3BhcmVudDsNCiAgcGFkZGluZzogOHB4IDEwcHg7IGJvcmRlci1yYWRpdXM6IDZweDsgY3Vyc29yOiBwb2ludGVyOyBjb2xvcjogdmFyKC0tdHh0KTsNCiAgZm9udC1zaXplOiAxM3B4OyBvdmVyZmxvdzogaGlkZGVuOyB0ZXh0LW92ZXJmbG93OiBlbGxpcHNpczsgd2hpdGUtc3BhY2U6IG5vd3JhcDsNCn0NCiNoaXN0LW1lbnUgYnV0dG9uOmhvdmVyIHsgYmFja2dyb3VuZDogI2YzZjRmNjsgfQ0KI2hpc3QtbWVudSAuaGlzdC1lbXB0eSB7DQogIHBhZGRpbmc6IDEwcHg7IGNvbG9yOiB2YXIoLS10eHQzKTsgZm9udC1zaXplOiAxMnB4OyB0ZXh0LWFsaWduOiBjZW50ZXI7DQp9DQojdG9wLXByZXZpZXcgew0KICBkaXNwbGF5OiBmbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBnYXA6IDEwcHg7IG1pbi13aWR0aDogMDsgcGFkZGluZzogMCAxMnB4Ow0KICBiYWNrZ3JvdW5kOiB2YXIoLS1jaHJvbWUpOyBjb2xvcjogdmFyKC0tdHh0Mik7IGZvbnQtc2l6ZTogMTJweDsgb3ZlcmZsb3c6IGhpZGRlbjsNCn0NCiN0b3AtcHJldmlldyAucHYtbWV0YSB7DQogIGJvcmRlcjogMDsgcGFkZGluZzogMDsgZmxleDogMTsgbWluLXdpZHRoOiAwOw0KICBmbGV4LXdyYXA6IG5vd3JhcDsgb3ZlcmZsb3c6IGhpZGRlbjsNCn0NCiNidG4tZ290by1wcm9jIHsNCiAgZmxleC1zaHJpbms6IDA7IGhlaWdodDogMzBweDsgcGFkZGluZzogMCAxMnB4Ow0KICBib3JkZXI6IDA7IGJvcmRlci1yYWRpdXM6IDk5OXB4OyBjdXJzb3I6IHBvaW50ZXI7DQogIGJhY2tncm91bmQ6ICNlOGYxZmY7IGNvbG9yOiAjMWQ0ZWQ4OyBmb250LXNpemU6IDEyLjVweDsgZm9udC13ZWlnaHQ6IDYwMDsNCn0NCiNidG4tZ290by1wcm9jOmhvdmVyIHsgYmFja2dyb3VuZDogI2RiZWFmZTsgfQ0KDQojdmlldy1zZWFyY2ggeyBkaXNwbGF5OiBmbGV4OyBmbGV4LWRpcmVjdGlvbjogY29sdW1uOyBmbGV4OiAxOyBtaW4taGVpZ2h0OiAwOyB9DQojdmlldy1zZWFyY2guaGlkZGVuIHsgZGlzcGxheTogbm9uZTsgfQ0KI3ZpZXctcHJvYyB7DQogIGRpc3BsYXk6IG5vbmU7IGZsZXgtZGlyZWN0aW9uOiBjb2x1bW47IGZsZXg6IDE7IG1pbi1oZWlnaHQ6IDA7DQogIGJhY2tncm91bmQ6ICNmMGYyZjU7DQp9DQojdmlldy1wcm9jLm9uIHsgZGlzcGxheTogZmxleDsgfQ0KLnByb2MtdG9wIHsNCiAgZGlzcGxheTogZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsgZ2FwOiAxMHB4OyBwYWRkaW5nOiAxMHB4IDE0cHggOHB4Ow0KICBiYWNrZ3JvdW5kOiAjZmZmOyBib3JkZXItYm90dG9tOiAxcHggc29saWQgdmFyKC0tbGluZSk7DQogIC13ZWJraXQtYXBwLXJlZ2lvbjogZHJhZzsgYXBwLXJlZ2lvbjogZHJhZzsNCn0NCi5wcm9jLXRvcCAubm8tZHJhZywgLnByb2MtdG9wIGJ1dHRvbiwgLnByb2MtdG9wIGlucHV0IHsNCiAgLXdlYmtpdC1hcHAtcmVnaW9uOiBuby1kcmFnOyBhcHAtcmVnaW9uOiBuby1kcmFnOw0KfQ0KLnByb2MtdGFicyB7IGRpc3BsYXk6IGZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGdhcDogOHB4OyBmbGV4LXdyYXA6IHdyYXA7IH0NCi5wcm9jLXRhYiB7DQogIGhlaWdodDogMzBweDsgcGFkZGluZzogMCAxNHB4OyBib3JkZXI6IDA7IGJvcmRlci1yYWRpdXM6IDk5OXB4Ow0KICBiYWNrZ3JvdW5kOiAjZWNlZmYzOyBjb2xvcjogIzRiNTU2MzsgZm9udC1zaXplOiAxM3B4OyBjdXJzb3I6IHBvaW50ZXI7DQp9DQoucHJvYy10YWIub24geyBiYWNrZ3JvdW5kOiAjM2I4MmY2OyBjb2xvcjogI2ZmZjsgZm9udC13ZWlnaHQ6IDYwMDsgfQ0KLnByb2MtdGFiOmRpc2FibGVkIHsgb3BhY2l0eTogLjU1OyBjdXJzb3I6IGRlZmF1bHQ7IH0NCi5wcm9jLXRvcC1yaWdodCB7IG1hcmdpbi1sZWZ0OiBhdXRvOyBkaXNwbGF5OiBmbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBnYXA6IDhweDsgfQ0KI2J0bi1iYWNrLXNlYXJjaCB7DQogIGhlaWdodDogMzBweDsgcGFkZGluZzogMCAxMnB4OyBib3JkZXI6IDA7IGJvcmRlci1yYWRpdXM6IDk5OXB4Ow0KICBiYWNrZ3JvdW5kOiAjZjNmNGY2OyBjb2xvcjogdmFyKC0tdHh0KTsgZm9udC1zaXplOiAxMi41cHg7IGN1cnNvcjogcG9pbnRlcjsNCn0NCiNidG4tYmFjay1zZWFyY2g6aG92ZXIgeyBiYWNrZ3JvdW5kOiAjZTVlN2ViOyB9DQoucHJvYy1zZWFyY2ggew0KICBkaXNwbGF5OiBmbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBnYXA6IDhweDsgcGFkZGluZzogOHB4IDE0cHg7DQogIGJhY2tncm91bmQ6ICNmZmY7IGJvcmRlci1ib3R0b206IDFweCBzb2xpZCB2YXIoLS1saW5lKTsNCn0NCi5wcm9jLXNlYXJjaCBpbnB1dCB7DQogIGZsZXg6IDE7IGhlaWdodDogMzJweDsgYm9yZGVyOiAxcHggc29saWQgdmFyKC0tbGluZSk7IGJvcmRlci1yYWRpdXM6IDhweDsNCiAgcGFkZGluZzogMCAxMnB4OyBvdXRsaW5lOiBub25lOyBiYWNrZ3JvdW5kOiAjZmJmYmZkOyBmb250LXNpemU6IDEzcHg7DQp9DQoucHJvYy1zZWFyY2ggaW5wdXQ6Zm9jdXMgew0KICBib3JkZXItY29sb3I6ICM5M2M1ZmQ7IGJveC1zaGFkb3c6IDAgMCAwIDNweCByZ2JhKDU5LDEzMCwyNDYsLjE1KTsgYmFja2dyb3VuZDogI2ZmZjsNCn0NCi5wcm9jLXRhYmxlLXdyYXAgew0KICBmbGV4OiAxOyBtaW4taGVpZ2h0OiAwOyBtYXJnaW46IDAgMTBweCA4cHg7IGJvcmRlcjogMXB4IHNvbGlkICNkNGQ0ZDQ7DQogIGJvcmRlci1yYWRpdXM6IDA7IG92ZXJmbG93OiBoaWRkZW47IGJhY2tncm91bmQ6ICNmZmY7DQogIGRpc3BsYXk6IGZsZXg7IGZsZXgtZGlyZWN0aW9uOiBjb2x1bW47DQp9DQoucHJvYy10YWJsZS13cmFwLmhpZGRlbiB7IGRpc3BsYXk6IG5vbmU7IH0NCi8qIOe7n+S4gOWIl+Wuve+8muihqOWktOS4juaVsOaNruWQjOS4gOWll+aooeadv++8jOmBv+WFjea7muWKqOadoemUmeS9jSAqLw0KLnByb2MtY29scyB7DQogIC0tYy1uYW1lOiBtaW5tYXgoMTgwcHgsIDEuNmZyKTsNCiAgLS1jLWNwdTogNzJweDsNCiAgLS1jLW1lbTogOTZweDsNCiAgLS1jLXBpZDogODBweDsNCiAgLS1jLXByb3RvOiA2OHB4Ow0KICAtLWMtbGlwOiBtaW5tYXgoMTEwcHgsIDFmcik7DQogIC0tYy1scG9ydDogNzZweDsNCiAgLS1jLXJpcDogbWlubWF4KDExMHB4LCAxZnIpOw0KICAtLWMtcnBvcnQ6IDc2cHg7DQogIC0tYy1zdGF0ZTogODhweDsNCiAgZGlzcGxheTogZ3JpZDsNCiAgZ3JpZC10ZW1wbGF0ZS1jb2x1bW5zOiB2YXIoLS1jLW5hbWUpIHZhcigtLWMtY3B1KSB2YXIoLS1jLW1lbSkgdmFyKC0tYy1waWQpIHZhcigtLWMtcHJvdG8pIHZhcigtLWMtbGlwKSB2YXIoLS1jLWxwb3J0KSB2YXIoLS1jLXJpcCkgdmFyKC0tYy1ycG9ydCkgdmFyKC0tYy1zdGF0ZSk7DQogIGdhcDogMDsNCiAgYWxpZ24taXRlbXM6IHN0cmV0Y2g7DQogIHdpZHRoOiAxMDAlOw0KICBib3gtc2l6aW5nOiBib3JkZXItYm94Ow0KfQ0KLnByb2Mtc2Nyb2xsIHsNCiAgZmxleDogMTsgbWluLWhlaWdodDogMDsgb3ZlcmZsb3c6IGF1dG87DQogIHNjcm9sbGJhci1ndXR0ZXI6IHN0YWJsZTsNCn0NCi8qIFdpbjExIOS7u+WKoeeuoeeQhuWZqOmjjuagvOWPjOWxguihqOWktO+8mueZveW6leOAgeS4iuS4i+WxheS4reWvuem9kCAqLw0KLnByb2MtaGVhZCB7DQogIHBvc2l0aW9uOiBzdGlja3k7IHRvcDogMDsgei1pbmRleDogMjsNCiAgYmFja2dyb3VuZDogI2ZmZjsgY29sb3I6ICM1YTVhNWE7DQogIGhlaWdodDogNDhweDsgbWluLWhlaWdodDogNDhweDsgcGFkZGluZzogMDsNCiAgYm9yZGVyLWJvdHRvbTogMXB4IHNvbGlkICNlNWU1ZTU7DQp9DQoucHJvYy1oY2VsbCB7DQogIGRpc3BsYXk6IGZsZXg7IGZsZXgtZGlyZWN0aW9uOiBjb2x1bW47IGp1c3RpZnktY29udGVudDogc3BhY2UtYmV0d2VlbjsNCiAgYWxpZ24taXRlbXM6IHN0cmV0Y2g7DQogIG1pbi13aWR0aDogMDsgaGVpZ2h0OiAxMDAlOyBwYWRkaW5nOiA2cHggOHB4IDdweDsNCiAgYm9yZGVyLXJpZ2h0OiAxcHggc29saWQgI2U1ZTVlNTsgYm94LXNpemluZzogYm9yZGVyLWJveDsNCiAgY3Vyc29yOiBwb2ludGVyOyB1c2VyLXNlbGVjdDogbm9uZTsNCiAgYmFja2dyb3VuZDogI2ZmZjsNCn0NCi5wcm9jLWhjZWxsOmxhc3QtY2hpbGQgeyBib3JkZXItcmlnaHQ6IDA7IH0NCi5wcm9jLWhjZWxsOmhvdmVyIHsgYmFja2dyb3VuZDogI2Y3ZjdmNzsgfQ0KLnByb2MtaGNlbGwuc29ydGVkIHsgYmFja2dyb3VuZDogI2ZmZjsgfQ0KLnByb2MtaC10b3Agew0KICBmbGV4OiAxOw0KICBtaW4taGVpZ2h0OiAxOHB4Ow0KICBmb250LXNpemU6IDEzcHg7IGZvbnQtd2VpZ2h0OiA2MDA7DQogIGNvbG9yOiAjMWIxYjFiOyB3aGl0ZS1zcGFjZTogbm93cmFwOw0KICBkaXNwbGF5OiBmbGV4OyBhbGlnbi1pdGVtczogZmxleC1zdGFydDsganVzdGlmeS1jb250ZW50OiBjZW50ZXI7DQogIGdhcDogNHB4OyBsaW5lLWhlaWdodDogMS4yOw0KICBwb3NpdGlvbjogcmVsYXRpdmU7DQp9DQoucHJvYy1jZWxsLW5hbWUgLnByb2MtaC10b3AgeyBqdXN0aWZ5LWNvbnRlbnQ6IGNlbnRlcjsgfQ0KLnByb2MtaC1sYWIgew0KICBmbGV4OiAwIDAgYXV0bzsNCiAgZm9udC1zaXplOiAxMnB4OyBmb250LXdlaWdodDogNDAwOw0KICBjb2xvcjogIzVhNWE1YTsgdGV4dC1hbGlnbjogY2VudGVyOyB3aGl0ZS1zcGFjZTogbm93cmFwOw0KICBsaW5lLWhlaWdodDogMS4yOw0KfQ0KLnByb2MtY2VsbC1uYW1lIC5wcm9jLWgtbGFiIHsgdGV4dC1hbGlnbjogbGVmdDsgfQ0KLnByb2MtaC1zb3J0IHsNCiAgZGlzcGxheTogaW5saW5lLWJsb2NrOyB3aWR0aDogMDsgaGVpZ2h0OiAwOw0KICBib3JkZXItbGVmdDogNHB4IHNvbGlkIHRyYW5zcGFyZW50OyBib3JkZXItcmlnaHQ6IDRweCBzb2xpZCB0cmFuc3BhcmVudDsNCiAgb3BhY2l0eTogMDsgZmxleC1zaHJpbms6IDA7DQp9DQoucHJvYy1oY2VsbC5zb3J0ZWQgLnByb2MtaC1zb3J0IHsgb3BhY2l0eTogMTsgfQ0KLnByb2MtaGNlbGwuc29ydGVkLmFzYyAucHJvYy1oLXNvcnQgew0KICBib3JkZXItYm90dG9tOiA1cHggc29saWQgIzFiMWIxYjsgYm9yZGVyLXRvcDogMDsNCn0NCi5wcm9jLWhjZWxsLnNvcnRlZC5kZXNjIC5wcm9jLWgtc29ydCB7DQogIGJvcmRlci10b3A6IDVweCBzb2xpZCAjMWIxYjFiOyBib3JkZXItYm90dG9tOiAwOw0KfQ0KLnByb2MtYm9keSB7IGRpc3BsYXk6IGJsb2NrOyB9DQoucHJvYy1yb3cgew0KICBtaW4taGVpZ2h0OiAyOHB4OyBoZWlnaHQ6IDI4cHg7IHBhZGRpbmc6IDA7DQogIGZvbnQtc2l6ZTogMTJweDsgY29sb3I6ICMxYjFiMWI7DQogIGJvcmRlci1ib3R0b206IDA7DQogIGN1cnNvcjogZGVmYXVsdDsgYmFja2dyb3VuZDogI2ZmZjsgdXNlci1zZWxlY3Q6IG5vbmU7DQogIHBvc2l0aW9uOiByZWxhdGl2ZTsNCn0NCi5wcm9jLXJvdzpob3ZlciB7IGJhY2tncm91bmQ6ICNmNWY4ZmI7IH0NCi5wcm9jLXJvdy5vbiwgLnByb2Mtcm93Lm9uOmhvdmVyIHsgYmFja2dyb3VuZDogI2NjZThmZjsgfQ0KLyog5ZCM5ZCN6L+b56iL6L+e57ut5q6177ya5LuF5reh57u/6Imy5aSW5qGG77yM5peg5bqV6ImyICovDQoucHJvYy1yb3cuZ3JwLWZpcnN0IHsNCiAgYm94LXNoYWRvdzogaW5zZXQgMCAycHggMCAjODhmZmMxLCBpbnNldCAycHggMCAwICM4OGZmYzEsIGluc2V0IC0ycHggMCAwICM4OGZmYzE7DQogIGJvcmRlci1yYWRpdXM6IDRweCA0cHggMCAwOw0KfQ0KLnByb2Mtcm93LmdycC1taWQgew0KICBib3gtc2hhZG93OiBpbnNldCAycHggMCAwICM4OGZmYzEsIGluc2V0IC0ycHggMCAwICM4OGZmYzE7DQogIGJvcmRlci1yYWRpdXM6IDA7DQp9DQoucHJvYy1yb3cuZ3JwLWxhc3Qgew0KICBib3gtc2hhZG93OiBpbnNldCAwIC0ycHggMCAjODhmZmMxLCBpbnNldCAycHggMCAwICM4OGZmYzEsIGluc2V0IC0ycHggMCAwICM4OGZmYzE7DQogIGJvcmRlci1yYWRpdXM6IDAgMCA0cHggNHB4Ow0KfQ0KLnByb2Mtcm93LmdycC1vbmx5LA0KLnByb2Mtcm93LmdycC1maXJzdC5ncnAtbGFzdCB7DQogIGJveC1zaGFkb3c6IGluc2V0IDAgMCAwIDJweCAjODhmZmMxOw0KICBib3JkZXItcmFkaXVzOiA0cHg7DQp9DQovKiDnu4TlhoXpnZ7nhKbngrnooYzkv53mjIHnmb3lupXvvJvnnJ/mraPngrnkuK3nmoTpgqPkuIDooYzkv53nlZnok53oibLlupUgKi8NCi5wcm9jLXJvdy5ncnA6bm90KC5vbikgeyBiYWNrZ3JvdW5kOiAjZmZmOyB9DQoucHJvYy1yb3cuZ3JwOm5vdCgub24pOmhvdmVyIHsgYmFja2dyb3VuZDogI2Y1ZjhmYjsgfQ0KLyogV2luZG93cyDmt6Hnq5bnur/vvJvljZXlhYPmoLzlkIzlrr3lkIzlnqvvvIzooajlpLTkuI7mlbDmja7kuKXmoLzlr7npvZAgKi8NCi5wcm9jLXJvdyA+IGRpdiB7DQogIGRpc3BsYXk6IGZsZXg7DQogIGFsaWduLWl0ZW1zOiBjZW50ZXI7DQogIG1pbi13aWR0aDogMDsNCiAgaGVpZ2h0OiAxMDAlOw0KICBwYWRkaW5nOiAwIDhweDsNCiAgYm9yZGVyLXJpZ2h0OiAxcHggc29saWQgI2U1ZTVlNTsNCiAgYm94LXNpemluZzogYm9yZGVyLWJveDsNCiAgb3ZlcmZsb3c6IGhpZGRlbjsNCiAgd2hpdGUtc3BhY2U6IG5vd3JhcDsNCn0NCi5wcm9jLXJvdyA+IGRpdjpsYXN0LWNoaWxkIHsgYm9yZGVyLXJpZ2h0OiAwOyB9DQoucHJvYy1jZWxsLW5hbWUgeyBqdXN0aWZ5LWNvbnRlbnQ6IGZsZXgtc3RhcnQ7IH0NCi5wcm9jLWNlbGwtcGlkLA0KLnByb2MtY2VsbC1wb3J0LA0KLnByb2MtY2VsbC1jcHUsDQoucHJvYy1jZWxsLW1lbSB7IGp1c3RpZnktY29udGVudDogZmxleC1lbmQ7IH0NCi5wcm9jLWNlbGwtcHJvdG8geyBqdXN0aWZ5LWNvbnRlbnQ6IGNlbnRlcjsgfQ0KLnByb2MtY2VsbC1zdGF0ZSB7IGp1c3RpZnktY29udGVudDogZmxleC1zdGFydDsgZ2FwOiA2cHg7IH0NCi5wcm9jLWNlbGwtaXAgeyBqdXN0aWZ5LWNvbnRlbnQ6IGZsZXgtc3RhcnQ7IH0NCi5wcm9jLWNlbGwtY3B1LCAucHJvYy1jZWxsLW1lbSB7DQogIGJhY2tncm91bmQ6ICNjZWZmZTU7DQp9DQoucHJvYy1jZWxsLWNwdS5ob3QsIC5wcm9jLWNlbGwtbWVtLmhvdCB7DQogIGJhY2tncm91bmQ6ICM4OGZmYzE7DQp9DQoucHJvYy1yb3cub24gLnByb2MtY2VsbC1jcHUsDQoucHJvYy1yb3cub24gLnByb2MtY2VsbC1tZW0gew0KICBiYWNrZ3JvdW5kOiAjY2VmZmU1Ow0KfQ0KLnByb2Mtcm93Lm9uIC5wcm9jLWNlbGwtY3B1LmhvdCwNCi5wcm9jLXJvdy5vbiAucHJvYy1jZWxsLW1lbS5ob3Qgew0KICBiYWNrZ3JvdW5kOiAjODhmZmMxOw0KfQ0KLnByb2MtaGNlbGwucHJvYy1jZWxsLWNwdSwNCi5wcm9jLWhjZWxsLnByb2MtY2VsbC1tZW0gew0KICBiYWNrZ3JvdW5kOiAjZmZmOw0KfQ0KLnByb2MtaGNlbGwucHJvYy1jZWxsLWNwdS5ob3QsDQoucHJvYy1oY2VsbC5wcm9jLWNlbGwtbWVtLmhvdCB7DQogIGJhY2tncm91bmQ6ICM4OGZmYzE7DQp9DQoucHJvYy1oY2VsbC5wcm9jLWNlbGwtY3B1Om5vdCguaG90KSwNCi5wcm9jLWhjZWxsLnByb2MtY2VsbC1tZW06bm90KC5ob3QpIHsNCiAgYmFja2dyb3VuZDogI2NlZmZlNTsNCn0NCi5wcm9jLW5hbWUgew0KICBkaXNwbGF5OiBmbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBnYXA6IDhweDsNCiAgbWluLXdpZHRoOiAwOyB3aWR0aDogMTAwJTsgb3ZlcmZsb3c6IGhpZGRlbjsNCn0NCi5wcm9jLW5hbWUgaW1nLCAucHJvYy1uYW1lIC5wcm9jLWljby1waCB7DQogIHdpZHRoOiAxNnB4OyBoZWlnaHQ6IDE2cHg7IG9iamVjdC1maXQ6IGNvbnRhaW47IGZsZXgtc2hyaW5rOiAwOw0KfQ0KLnByb2MtbmFtZSAucHJvYy1pY28tcGggew0KICBkaXNwbGF5OiBpbmxpbmUtYmxvY2s7IGJhY2tncm91bmQ6ICNlOGVhZWQ7IGJvcmRlci1yYWRpdXM6IDJweDsNCiAgYm9yZGVyOiAxcHggc29saWQgI2QwZDRkYTsNCn0NCi5wcm9jLW5hbWUgLnByb2MtbGFiZWwgew0KICBvdmVyZmxvdzogaGlkZGVuOyB0ZXh0LW92ZXJmbG93OiBlbGxpcHNpczsgd2hpdGUtc3BhY2U6IG5vd3JhcDsgbWluLXdpZHRoOiAwOw0KfQ0KLnByb2MtbmV0LWRvdCB7DQogIHdpZHRoOiA3cHg7IGhlaWdodDogN3B4OyBib3JkZXItcmFkaXVzOiA1MCU7IGZsZXgtc2hyaW5rOiAwOw0KICBiYWNrZ3JvdW5kOiAjMjJjNTVlOyBib3gtc2hhZG93OiAwIDAgMCAycHggcmdiYSgzNCwgMTk3LCA5NCwgLjIpOw0KfQ0KLnByb2MtbmV0LWRvdC5oaWRkZW4geyBkaXNwbGF5OiBub25lOyB9DQoucHJvYy1udW0gew0KICBmb250LXZhcmlhbnQtbnVtZXJpYzogdGFidWxhci1udW1zOyBjb2xvcjogIzFiMWIxYjsNCiAgd2lkdGg6IDEwMCU7DQp9DQoucHJvYy1udW0ucG9ydC1ob3Qgew0KICBjb2xvcjogI2MyNDEwYzsNCiAgZm9udC13ZWlnaHQ6IDcwMDsNCn0NCi8qIOKUgOKUgCDlhbPogZTlj6Xmn4TvvIjnjrDku6Povbvph4/ooajmoLzvvInilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIAgKi8NCiNoYW5kbGUtcGFuZWwgew0KICBmbGV4OiAxOyBtaW4taGVpZ2h0OiAwOyBtYXJnaW46IDA7IGJvcmRlcjogMDsNCiAgYmFja2dyb3VuZDogI2ZmZjsgZGlzcGxheTogZmxleDsgZmxleC1kaXJlY3Rpb246IGNvbHVtbjsgb3ZlcmZsb3c6IGhpZGRlbjsNCn0NCiNoYW5kbGUtcGFuZWwuaGlkZGVuIHsgZGlzcGxheTogbm9uZTsgfQ0KLmhhbmRsZS1iYW5uZXIgew0KICBkaXNwbGF5OiBub25lOyBhbGlnbi1pdGVtczogY2VudGVyOyBnYXA6IDhweDsNCiAgbWFyZ2luOiAwOyBwYWRkaW5nOiA4cHggMTRweDsNCiAgYmFja2dyb3VuZDogI2YwZjdmZjsgYm9yZGVyOiAwOyBib3JkZXItcmFkaXVzOiAwOw0KICBjb2xvcjogIzFlM2E1ZjsgZm9udC1zaXplOiAxMi41cHg7IGZsZXgtc2hyaW5rOiAwOw0KfQ0KLmhhbmRsZS1iYW5uZXIub24geyBkaXNwbGF5OiBmbGV4OyB9DQouaGFuZGxlLWJhbm5lcjo6YmVmb3JlIHsNCiAgY29udGVudDogIiI7IHdpZHRoOiA2cHg7IGhlaWdodDogNnB4OyBib3JkZXItcmFkaXVzOiA1MCU7DQogIGJhY2tncm91bmQ6ICMzYjgyZjY7IGZsZXgtc2hyaW5rOiAwOw0KfQ0KLmhhbmRsZS1jb2xzIHsNCiAgLS1oLW5hbWU6IG1pbm1heCgxNDBweCwgMS4yZnIpOw0KICAtLWgtcGlkOiA4OHB4Ow0KICAtLWgtcG9ydDogODRweDsNCiAgLS1oLXJwb3J0OiA4NHB4Ow0KICAtLWgtdHlwZTogNzJweDsNCiAgLS1oLXBhdGg6IG1pbm1heCgxNjBweCwgMmZyKTsNCiAgZGlzcGxheTogZ3JpZDsNCiAgZ3JpZC10ZW1wbGF0ZS1jb2x1bW5zOiB2YXIoLS1oLW5hbWUpIHZhcigtLWgtcGlkKSB2YXIoLS1oLXR5cGUpIHZhcigtLWgtcGF0aCk7DQogIGdhcDogMDsgd2lkdGg6IDEwMCU7IGJveC1zaXppbmc6IGJvcmRlci1ib3g7IGFsaWduLWl0ZW1zOiBzdHJldGNoOw0KfQ0KLmhhbmRsZS1jb2xzLnBvcnQtbW9kZSB7DQogIGdyaWQtdGVtcGxhdGUtY29sdW1uczogdmFyKC0taC1uYW1lKSB2YXIoLS1oLXBpZCkgdmFyKC0taC1wb3J0KSB2YXIoLS1oLXJwb3J0KSB2YXIoLS1oLXR5cGUpIHZhcigtLWgtcGF0aCk7DQp9DQouaGFuZGxlLWNvbC1wb3J0LmhpZGRlbiwgLmhhbmRsZS1jb2wtcnBvcnQuaGlkZGVuIHsgZGlzcGxheTogbm9uZSAhaW1wb3J0YW50OyB9DQouaGFuZGxlLWNvbHMucG9ydC1tb2RlIC5oYW5kbGUtY29sLXBvcnQuaGlkZGVuLA0KLmhhbmRsZS1jb2xzLnBvcnQtbW9kZSAuaGFuZGxlLWNvbC1ycG9ydC5oaWRkZW4geyBkaXNwbGF5OiBmbGV4ICFpbXBvcnRhbnQ7IH0NCi5oYW5kbGUtc2Nyb2xsIHsgZmxleDogMTsgbWluLWhlaWdodDogMDsgb3ZlcmZsb3c6IGF1dG87IHBhZGRpbmc6IDAgOHB4IDhweDsgfQ0KLmhhbmRsZS1oZWFkIHsNCiAgcG9zaXRpb246IHN0aWNreTsgdG9wOiAwOyB6LWluZGV4OiAyOyBoZWlnaHQ6IDM0cHg7IG1pbi1oZWlnaHQ6IDM0cHg7DQogIGJhY2tncm91bmQ6ICNmZmY7IGNvbG9yOiB2YXIoLS10eHQyKTsgZm9udC1zaXplOiAxMnB4OyBmb250LXdlaWdodDogNjAwOw0KICBib3JkZXItYm90dG9tOiAxcHggc29saWQgdmFyKC0tbGluZSk7DQp9DQouaGFuZGxlLWhjZWxsIHsNCiAgY3Vyc29yOiBwb2ludGVyOyB1c2VyLXNlbGVjdDogbm9uZTsgZ2FwOiA2cHg7DQp9DQouaGFuZGxlLWhjZWxsOmhvdmVyIHsgYmFja2dyb3VuZDogI2Y1ZjdmYjsgY29sb3I6IHZhcigtLXR4dCk7IH0NCi5oYW5kbGUtaGNlbGwuc29ydGVkIHsgY29sb3I6IHZhcigtLXR4dCk7IH0NCi5oYW5kbGUtaGNlbGwgLmgtc29ydCB7DQogIGRpc3BsYXk6IGlubGluZS1ibG9jazsgd2lkdGg6IDA7IGhlaWdodDogMDsNCiAgYm9yZGVyLWxlZnQ6IDRweCBzb2xpZCB0cmFuc3BhcmVudDsgYm9yZGVyLXJpZ2h0OiA0cHggc29saWQgdHJhbnNwYXJlbnQ7DQogIG9wYWNpdHk6IDA7IGZsZXgtc2hyaW5rOiAwOw0KfQ0KLmhhbmRsZS1oY2VsbC5zb3J0ZWQgLmgtc29ydCB7IG9wYWNpdHk6IDE7IH0NCi5oYW5kbGUtaGNlbGwuc29ydGVkLmFzYyAuaC1zb3J0IHsNCiAgYm9yZGVyLWJvdHRvbTogNXB4IHNvbGlkICMxYjFiMWI7IGJvcmRlci10b3A6IDA7DQp9DQouaGFuZGxlLWhjZWxsLnNvcnRlZC5kZXNjIC5oLXNvcnQgew0KICBib3JkZXItdG9wOiA1cHggc29saWQgIzFiMWIxYjsgYm9yZGVyLWJvdHRvbTogMDsNCn0NCi5oYW5kbGUtYm9keSB7IGRpc3BsYXk6IGJsb2NrOyBwYWRkaW5nLXRvcDogMnB4OyB9DQouaGFuZGxlLXJvdyB7DQogIG1pbi1oZWlnaHQ6IDM2cHg7IGhlaWdodDogMzZweDsgZm9udC1zaXplOiAxM3B4OyBjb2xvcjogdmFyKC0tdHh0KTsNCiAgYm9yZGVyOiAwOyBib3JkZXItcmFkaXVzOiA4cHg7IGJhY2tncm91bmQ6IHRyYW5zcGFyZW50OyBjdXJzb3I6IGRlZmF1bHQ7IHVzZXItc2VsZWN0OiBub25lOw0KICBtYXJnaW46IDFweCAwOw0KfQ0KLmhhbmRsZS1yb3c6aG92ZXIgeyBiYWNrZ3JvdW5kOiAjZjVmN2ZiOyB9DQouaGFuZGxlLXJvdy5vbiwgLmhhbmRsZS1yb3cub246aG92ZXIgeyBiYWNrZ3JvdW5kOiB2YXIoLS1zZWwpOyB9DQouaGFuZGxlLWhlYWQgPiBkaXYsDQouaGFuZGxlLXJvdyA+IGRpdiB7DQogIGRpc3BsYXk6IGZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IG1pbi13aWR0aDogMDsgaGVpZ2h0OiAxMDAlOw0KICBwYWRkaW5nOiAwIDEycHg7IGJvcmRlcjogMDsgYm94LXNpemluZzogYm9yZGVyLWJveDsNCiAgb3ZlcmZsb3c6IGhpZGRlbjsgd2hpdGUtc3BhY2U6IG5vd3JhcDsgdGV4dC1vdmVyZmxvdzogZWxsaXBzaXM7DQp9DQouaGFuZGxlLW5hbWUgew0KICBkaXNwbGF5OiBmbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBnYXA6IDEwcHg7IG1pbi13aWR0aDogMDsgd2lkdGg6IDEwMCU7IG92ZXJmbG93OiBoaWRkZW47DQp9DQouaGFuZGxlLW5hbWUgaW1nLCAuaGFuZGxlLW5hbWUgLmhhbmRsZS1pY28tcGggew0KICB3aWR0aDogMThweDsgaGVpZ2h0OiAxOHB4OyBvYmplY3QtZml0OiBjb250YWluOyBmbGV4LXNocmluazogMDsNCn0NCi5oYW5kbGUtbmFtZSAuaGFuZGxlLWljby1waCB7DQogIGRpc3BsYXk6IGlubGluZS1ibG9jazsgYmFja2dyb3VuZDogI2VlZjFmNjsgYm9yZGVyLXJhZGl1czogNHB4OyBib3JkZXI6IDA7DQp9DQouaGFuZGxlLW5hbWUgc3BhbiB7DQogIG92ZXJmbG93OiBoaWRkZW47IHRleHQtb3ZlcmZsb3c6IGVsbGlwc2lzOyB3aGl0ZS1zcGFjZTogbm93cmFwOyBtaW4td2lkdGg6IDA7IGZvbnQtd2VpZ2h0OiA1MDA7DQp9DQouaGFuZGxlLW5ldC1kb3Qgew0KICB3aWR0aDogN3B4OyBoZWlnaHQ6IDdweDsgYm9yZGVyLXJhZGl1czogNTAlOyBmbGV4LXNocmluazogMDsNCiAgYmFja2dyb3VuZDogIzIyYzU1ZTsgYm94LXNoYWRvdzogMCAwIDAgMnB4IHJnYmEoMzQsIDE5NywgOTQsIC4yKTsNCn0NCi5oYW5kbGUtc3RhdGUgew0KICBkaXNwbGF5OiBmbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBnYXA6IDZweDsgbWluLXdpZHRoOiAwOw0KfQ0KLmhhbmRsZS1lbXB0eSB7DQogIHBhZGRpbmc6IDQ4cHggMTZweDsgdGV4dC1hbGlnbjogY2VudGVyOyBjb2xvcjogdmFyKC0tdHh0Myk7IGZvbnQtc2l6ZTogMTMuNXB4OyBsaW5lLWhlaWdodDogMS42Ow0KfQ0KLmhhbmRsZS1sb2FkaW5nIHsNCiAgZGlzcGxheTogZmxleDsgZmxleC1kaXJlY3Rpb246IGNvbHVtbjsgYWxpZ24taXRlbXM6IGNlbnRlcjsganVzdGlmeS1jb250ZW50OiBjZW50ZXI7DQogIGdhcDogMTRweDsgcGFkZGluZzogNjRweCAxNnB4OyBjb2xvcjogdmFyKC0tdHh0Mik7IGZvbnQtc2l6ZTogMTNweDsNCn0NCi5oYW5kbGUtc3Bpbm5lciB7DQogIHdpZHRoOiAyNnB4OyBoZWlnaHQ6IDI2cHg7IGJvcmRlci1yYWRpdXM6IDUwJTsgYm94LXNpemluZzogYm9yZGVyLWJveDsNCiAgYm9yZGVyOiAyLjVweCBzb2xpZCAjZTVlN2ViOyBib3JkZXItdG9wLWNvbG9yOiAjZTQyMDc5Ow0KICBhbmltYXRpb246IGhhbmRsZS1zcGluIC43cyBsaW5lYXIgaW5maW5pdGU7DQp9DQpAa2V5ZnJhbWVzIGhhbmRsZS1zcGluIHsNCiAgdG8geyB0cmFuc2Zvcm06IHJvdGF0ZSgzNjBkZWcpOyB9DQp9DQouaW5mby1sb2FkaW5nIHsNCiAgZGlzcGxheTogZmxleDsgZmxleC1kaXJlY3Rpb246IGNvbHVtbjsgYWxpZ24taXRlbXM6IGNlbnRlcjsganVzdGlmeS1jb250ZW50OiBjZW50ZXI7DQogIGdhcDogMTRweDsgbWluLWhlaWdodDogMjQwcHg7IHBhZGRpbmc6IDY0cHggMTZweDsgY29sb3I6IHZhcigtLXR4dDIpOyBmb250LXNpemU6IDEzcHg7DQogIGJveC1zaXppbmc6IGJvcmRlci1ib3g7DQp9DQouaW5mby1zcGlubmVyIHsNCiAgd2lkdGg6IDI4cHg7IGhlaWdodDogMjhweDsgYm9yZGVyLXJhZGl1czogNTAlOyBib3gtc2l6aW5nOiBib3JkZXItYm94Ow0KICBib3JkZXI6IDIuNXB4IHNvbGlkICNlNWU3ZWI7IGJvcmRlci10b3AtY29sb3I6ICNlNDIwNzk7DQogIGFuaW1hdGlvbjogaGFuZGxlLXNwaW4gLjdzIGxpbmVhciBpbmZpbml0ZTsNCn0NCiNiYXItaGFuZGxlLWFjdGlvbnMgew0KICBkaXNwbGF5OiBub25lOyBhbGlnbi1pdGVtczogY2VudGVyOyBnYXA6IDEwcHg7IG1hcmdpbi1yaWdodDogOHB4OyBtaW4td2lkdGg6IDA7DQogIHBvc2l0aW9uOiByZWxhdGl2ZTsNCn0NCiNiYXIubW9kZS1oYW5kbGUgI2Jhci1oYW5kbGUtYWN0aW9ucyB7IGRpc3BsYXk6IGlubGluZS1mbGV4OyB9DQojYmFyLWhhbmRsZS1hY3Rpb25zICNoYW5kbGUtc3RhdHVzIHsNCiAgY29sb3I6IHZhcigtLXR4dDMpOyBmb250LXNpemU6IDEycHg7IG1heC13aWR0aDogMjQwcHg7DQogIG92ZXJmbG93OiBoaWRkZW47IHRleHQtb3ZlcmZsb3c6IGVsbGlwc2lzOyB3aGl0ZS1zcGFjZTogbm93cmFwOw0KfQ0KI2J0bi1wb3J0LW1hcmsgew0KICB3aWR0aDogMjhweDsgaGVpZ2h0OiAyOHB4OyBib3JkZXI6IDA7IGJvcmRlci1yYWRpdXM6IDhweDsNCiAgYmFja2dyb3VuZDogdHJhbnNwYXJlbnQ7IGNvbG9yOiB2YXIoLS10eHQyKTsgZm9udC1zaXplOiAxNXB4Ow0KICBjdXJzb3I6IHBvaW50ZXI7IGxpbmUtaGVpZ2h0OiAxOyBmbGV4LXNocmluazogMDsNCn0NCiNidG4tcG9ydC1tYXJrOmhvdmVyLCAjYnRuLXBvcnQtbWFyay5vbiB7DQogIGJhY2tncm91bmQ6ICNlZWYxZjY7IGNvbG9yOiB2YXIoLS10eHQpOw0KfQ0KI2Jhci5tb2RlLWhhbmRsZSAuc29ydCwgI2Jhci5tb2RlLWhhbmRsZSAudG9nZ2xlIHsgZGlzcGxheTogbm9uZTsgfQ0KLmhhbmRsZS1jb2wtcG9ydC5wb3J0LWhvdCwNCi5oYW5kbGUtY29sLXJwb3J0LnBvcnQtaG90IHsNCiAgY29sb3I6ICNjMjQxMGM7IGZvbnQtd2VpZ2h0OiA3MDA7DQp9DQojcG9ydC1tYXJrLXBvcCB7DQogIGRpc3BsYXk6IG5vbmU7IHBvc2l0aW9uOiBhYnNvbHV0ZTsgcmlnaHQ6IDA7IGJvdHRvbTogY2FsYygxMDAlICsgOHB4KTsNCiAgd2lkdGg6IDMwMHB4OyB6LWluZGV4OiA4MDsgcGFkZGluZzogMTJweDsNCiAgYmFja2dyb3VuZDogI2ZmZjsgYm9yZGVyOiAxcHggc29saWQgdmFyKC0tbGluZSk7IGJvcmRlci1yYWRpdXM6IDEycHg7DQogIGJveC1zaGFkb3c6IDAgMTJweCAyOHB4IHJnYmEoMTUsIDIzLCA0MiwgLjEyKTsNCn0NCiNwb3J0LW1hcmstcG9wLm9uIHsgZGlzcGxheTogYmxvY2s7IH0NCi5wbXAtaGQgeyBmb250LXNpemU6IDEzLjVweDsgZm9udC13ZWlnaHQ6IDY1MDsgY29sb3I6IHZhcigtLXR4dCk7IG1hcmdpbi1ib3R0b206IDRweDsgfQ0KLnBtcC1oaW50IHsgZm9udC1zaXplOiAxMnB4OyBjb2xvcjogdmFyKC0tdHh0Myk7IG1hcmdpbi1ib3R0b206IDEwcHg7IGxpbmUtaGVpZ2h0OiAxLjQ7IH0NCi5wbXAtdGFncyB7DQogIGRpc3BsYXk6IGZsZXg7IGZsZXgtd3JhcDogd3JhcDsgZ2FwOiA2cHg7IG1pbi1oZWlnaHQ6IDMycHg7DQogIG1heC1oZWlnaHQ6IDE0MHB4OyBvdmVyZmxvdzogYXV0bzsgbWFyZ2luLWJvdHRvbTogMTBweDsNCn0NCi5wbXAtdGFnIHsNCiAgZGlzcGxheTogaW5saW5lLWZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGdhcDogNHB4Ow0KICBoZWlnaHQ6IDI2cHg7IHBhZGRpbmc6IDAgNHB4IDAgMTBweDsgYm9yZGVyLXJhZGl1czogOTk5cHg7DQogIGJhY2tncm91bmQ6ICNmZmY3ZWQ7IGNvbG9yOiAjYzI0MTBjOyBmb250LXNpemU6IDEyLjVweDsgZm9udC13ZWlnaHQ6IDYwMDsNCiAgZm9udC12YXJpYW50LW51bWVyaWM6IHRhYnVsYXItbnVtczsNCn0NCi5wbXAtdGFnIGJ1dHRvbiB7DQogIHdpZHRoOiAyMHB4OyBoZWlnaHQ6IDIwcHg7IGJvcmRlcjogMDsgYm9yZGVyLXJhZGl1czogNTAlOw0KICBiYWNrZ3JvdW5kOiB0cmFuc3BhcmVudDsgY29sb3I6ICNlYTU4MGM7IGN1cnNvcjogcG9pbnRlcjsgZm9udC1zaXplOiAxNHB4OyBsaW5lLWhlaWdodDogMTsNCn0NCi5wbXAtdGFnIGJ1dHRvbjpob3ZlciB7IGJhY2tncm91bmQ6ICNmZmVkZDU7IH0NCi5wbXAtZW1wdHkgeyBjb2xvcjogdmFyKC0tdHh0Myk7IGZvbnQtc2l6ZTogMTJweDsgcGFkZGluZzogNnB4IDJweDsgfQ0KLnBtcC1hZGQgeyBkaXNwbGF5OiBmbGV4OyBnYXA6IDhweDsgYWxpZ24taXRlbXM6IGNlbnRlcjsgbWFyZ2luLWJvdHRvbTogOHB4OyB9DQoucG1wLWFkZCBpbnB1dCB7DQogIGZsZXg6IDE7IG1pbi13aWR0aDogMDsgaGVpZ2h0OiAzMnB4OyBib3JkZXI6IDFweCBzb2xpZCB2YXIoLS1saW5lKTsgYm9yZGVyLXJhZGl1czogOHB4Ow0KICBwYWRkaW5nOiAwIDEwcHg7IG91dGxpbmU6IG5vbmU7IGZvbnQtc2l6ZTogMTNweDsgYmFja2dyb3VuZDogI2ZiZmJmZDsNCn0NCi5wbXAtYWRkIGlucHV0OmZvY3VzIHsgYm9yZGVyLWNvbG9yOiAjOTNjNWZkOyBiYWNrZ3JvdW5kOiAjZmZmOyB9DQoucG1wLWFkZCBidXR0b24sIC5wbXAtcmVzZXQgew0KICBoZWlnaHQ6IDMycHg7IHBhZGRpbmc6IDAgMTJweDsgYm9yZGVyOiAwOyBib3JkZXItcmFkaXVzOiA4cHg7DQogIGJhY2tncm91bmQ6ICNlZmY2ZmY7IGNvbG9yOiAjMWQ0ZWQ4OyBmb250LXNpemU6IDEyLjVweDsgZm9udC13ZWlnaHQ6IDYwMDsgY3Vyc29yOiBwb2ludGVyOw0KfQ0KLnBtcC1hZGQgYnV0dG9uOmhvdmVyIHsgYmFja2dyb3VuZDogI2RiZWFmZTsgfQ0KLnBtcC1yZXNldCB7DQogIHdpZHRoOiAxMDAlOyBiYWNrZ3JvdW5kOiB0cmFuc3BhcmVudDsgY29sb3I6IHZhcigtLXR4dDIpOyBmb250LXdlaWdodDogNTAwOw0KfQ0KLnBtcC1yZXNldDpob3ZlciB7IGJhY2tncm91bmQ6ICNmM2Y0ZjY7IGNvbG9yOiB2YXIoLS10eHQpOyB9DQoucHJvYy1hY3Qgew0KICB3aWR0aDogMjJweDsgaGVpZ2h0OiAyMnB4OyBib3JkZXI6IDA7IGJvcmRlci1yYWRpdXM6IDRweDsgYmFja2dyb3VuZDogdHJhbnNwYXJlbnQ7DQogIGNvbG9yOiAjOWFhMWIyOyBjdXJzb3I6IHBvaW50ZXI7IGZvbnQtc2l6ZTogMTJweDsgbGluZS1oZWlnaHQ6IDE7DQp9DQoucHJvYy1hY3Q6aG92ZXIgeyBiYWNrZ3JvdW5kOiAjZTVlN2ViOyBjb2xvcjogIzExMTgyNzsgfQ0KLnByb2MtZm9vdCB7DQogIGRpc3BsYXk6IGZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGp1c3RpZnktY29udGVudDogZmxleC1lbmQ7IGdhcDogMTRweDsNCiAgcGFkZGluZzogNnB4IDE2cHggMTBweDsgY29sb3I6ICMzYjgyZjY7IGZvbnQtc2l6ZTogMTIuNXB4Ow0KfQ0KLnByb2MtZm9vdC5oaWRkZW4geyBkaXNwbGF5OiBub25lOyB9DQoucHJvYy1zeXMtdG9nIHsNCiAgZGlzcGxheTogaW5saW5lLWZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGdhcDogOHB4OyBjdXJzb3I6IHBvaW50ZXI7DQogIHVzZXItc2VsZWN0OiBub25lOyBjb2xvcjogIzNiODJmNjsgZm9udC1zaXplOiAxMi41cHg7DQp9DQoucHJvYy1zeXMtdG9nIGlucHV0IHsgcG9zaXRpb246IGFic29sdXRlOyBvcGFjaXR5OiAwOyB3aWR0aDogMDsgaGVpZ2h0OiAwOyB9DQoucHJvYy1zeXMtdG9nIC50b2cgew0KICB3aWR0aDogMzZweDsgaGVpZ2h0OiAyMHB4OyBib3JkZXItcmFkaXVzOiA5OTlweDsgYmFja2dyb3VuZDogI2QxZDVkYjsNCiAgcG9zaXRpb246IHJlbGF0aXZlOyBmbGV4LXNocmluazogMDsgdHJhbnNpdGlvbjogYmFja2dyb3VuZCAuMTVzIGVhc2U7DQp9DQoucHJvYy1zeXMtdG9nIC50b2c6OmFmdGVyIHsNCiAgY29udGVudDogIiI7IHBvc2l0aW9uOiBhYnNvbHV0ZTsgdG9wOiAycHg7IGxlZnQ6IDJweDsNCiAgd2lkdGg6IDE2cHg7IGhlaWdodDogMTZweDsgYm9yZGVyLXJhZGl1czogNTAlOyBiYWNrZ3JvdW5kOiAjZmZmOw0KICBib3gtc2hhZG93OiAwIDFweCAycHggcmdiYSgwLDAsMCwuMTgpOyB0cmFuc2l0aW9uOiB0cmFuc2Zvcm0gLjE1cyBlYXNlOw0KfQ0KLnByb2Mtc3lzLXRvZyBpbnB1dDpjaGVja2VkICsgLnRvZyB7IGJhY2tncm91bmQ6ICMzYjgyZjY7IH0NCi5wcm9jLXN5cy10b2cgaW5wdXQ6Y2hlY2tlZCArIC50b2c6OmFmdGVyIHsgdHJhbnNmb3JtOiB0cmFuc2xhdGVYKDE2cHgpOyB9DQojcHJvYy1jb3VudCB7DQogIGNvbG9yOiAjNmI3MjgwOyBmb250LXZhcmlhbnQtbnVtZXJpYzogdGFidWxhci1udW1zOyBtaW4td2lkdGg6IDIuNWVtOyB0ZXh0LWFsaWduOiByaWdodDsNCn0NCiNpbmZvLXBhbmVsIHsNCiAgZmxleDogMTsgbWluLWhlaWdodDogMDsgbWFyZ2luOiAwOyBib3JkZXI6IDA7IGJvcmRlci1yYWRpdXM6IDA7DQogIG92ZXJmbG93OiBhdXRvOyBiYWNrZ3JvdW5kOiAjZmZmOw0KICBkaXNwbGF5OiBibG9jazsgLyog5Yu/55SoIGZsZXgg5YiX77ya5aSa6KGM572R5Y2h5Lya6KKr5Y6L55+u5Y+g5a2XICovDQp9DQojaW5mby1wYW5lbC5oaWRkZW4geyBkaXNwbGF5OiBub25lOyB9DQouaW5mby1yb3cgew0KICBkaXNwbGF5OiBncmlkOyBncmlkLXRlbXBsYXRlLWNvbHVtbnM6IDEwOHB4IDE4cHggMWZyIGF1dG87DQogIGdhcDogMCA4cHg7IGFsaWduLWl0ZW1zOiBzdGFydDsgbWluLWhlaWdodDogMzZweDsgaGVpZ2h0OiBhdXRvOw0KICBwYWRkaW5nOiA4cHggMTRweDsgYm9yZGVyLWJvdHRvbTogMXB4IHNvbGlkICNlZWYwZjQ7DQogIGZsZXgtc2hyaW5rOiAwOyBvdmVyZmxvdzogdmlzaWJsZTsNCn0NCi5pbmZvLXJvdzpudGgtY2hpbGQoZXZlbikgeyBiYWNrZ3JvdW5kOiAjZjdmOGZhOyB9DQouaW5mby1sYWIgew0KICBjb2xvcjogIzNiODJmNjsgZm9udC1zaXplOiAxM3B4OyB0ZXh0LWFsaWduOiByaWdodDsgcGFkZGluZy10b3A6IDJweDsNCiAgd2hpdGUtc3BhY2U6IG5vd3JhcDsNCn0NCi5pbmZvLWRhc2ggew0KICBoZWlnaHQ6IDFweDsgYmFja2dyb3VuZDogI2QxZDVkYjsgbWFyZ2luLXRvcDogMTJweDsgYWxpZ24tc2VsZjogc3RhcnQ7DQp9DQouaW5mby12YWwgew0KICBjb2xvcjogIzExMTgyNzsgZm9udC1zaXplOiAxM3B4OyBsaW5lLWhlaWdodDogMS41NTsgd29yZC1icmVhazogYnJlYWstd29yZDsNCiAgcGFkZGluZy10b3A6IDFweDsgbWluLXdpZHRoOiAwOyBvdmVyZmxvdzogdmlzaWJsZTsNCn0NCi5pbmZvLXZhbCAuc3ViIHsNCiAgY29sb3I6ICMzNzQxNTE7IG1hcmdpbi1sZWZ0OiAyNHB4OyB3aGl0ZS1zcGFjZTogbm93cmFwOw0KfQ0KI2luZm8tdXB0aW1lIHsNCiAgY29sb3I6ICMzNzQxNTE7IGZvbnQtdmFyaWFudC1udW1lcmljOiB0YWJ1bGFyLW51bXM7DQp9DQouaW5mby12YWwgLmxpbmUgeyBkaXNwbGF5OiBibG9jazsgfQ0KLmluZm8tdmFsIC5uZXQtbGluZSB7DQogIGRpc3BsYXk6IGdyaWQ7IGdyaWQtdGVtcGxhdGUtY29sdW1uczogbWlubWF4KDE0MHB4LCAxLjVmcikgbWlubWF4KDE1MHB4LCAxZnIpIG1pbm1heCgxMTBweCwgMC44NWZyKTsNCiAgZ2FwOiA0cHggMTJweDsgYWxpZ24taXRlbXM6IGJhc2VsaW5lOyBtYXJnaW46IDAgMCA2cHg7IG1pbi13aWR0aDogMDsNCn0NCi5pbmZvLXZhbCAubmV0LWxpbmU6bGFzdC1jaGlsZCB7IG1hcmdpbi1ib3R0b206IDA7IH0NCi5pbmZvLXZhbCAubmV0LWxpbmUgPiBzcGFuIHsgbWluLXdpZHRoOiAwOyBvdmVyZmxvdy13cmFwOiBhbnl3aGVyZTsgfQ0KLmluZm8tdmFsIC5uZXQtbGluZSAuayB7IGNvbG9yOiAjNmI3MjgwOyB9DQouaW5mby1saW5rIHsNCiAgYm9yZGVyOiAwOyBiYWNrZ3JvdW5kOiB0cmFuc3BhcmVudDsgY29sb3I6ICMzYjgyZjY7IGZvbnQtc2l6ZTogMTIuNXB4Ow0KICBjdXJzb3I6IHBvaW50ZXI7IHBhZGRpbmc6IDJweCAwOyB3aGl0ZS1zcGFjZTogbm93cmFwOyBhbGlnbi1zZWxmOiBzdGFydDsNCn0NCi5pbmZvLWxpbms6aG92ZXIgeyB0ZXh0LWRlY29yYXRpb246IHVuZGVybGluZTsgfQ0KI2Jhci1pbmZvLWFjdGlvbnMgew0KICBkaXNwbGF5OiBub25lOyBhbGlnbi1pdGVtczogY2VudGVyOyBnYXA6IDE2cHg7IG1hcmdpbi1yaWdodDogOHB4Ow0KfQ0KI2Jhci5tb2RlLWluZm8gI2Jhci1pbmZvLWFjdGlvbnMgeyBkaXNwbGF5OiBpbmxpbmUtZmxleDsgfQ0KI2Jhci1pbmZvLWFjdGlvbnMgYnV0dG9uIHsNCiAgYm9yZGVyOiAwOyBiYWNrZ3JvdW5kOiB0cmFuc3BhcmVudDsgY29sb3I6ICMzYjgyZjY7IGZvbnQtc2l6ZTogMTIuNXB4OyBjdXJzb3I6IHBvaW50ZXI7IHBhZGRpbmc6IDA7DQp9DQojYmFyLWluZm8tYWN0aW9ucyBidXR0b246aG92ZXIgeyB0ZXh0LWRlY29yYXRpb246IHVuZGVybGluZTsgfQ0KI2Jhci5tb2RlLWluZm8gI2NvdW50IHsgY29sb3I6IHZhcigtLXR4dDIpOyB9DQoucHJvYy1zZWFyY2guaGlkZGVuIHsgZGlzcGxheTogbm9uZSAhaW1wb3J0YW50OyB9DQojcHJvYy1tZW51IHsNCiAgZGlzcGxheTogbm9uZTsgcG9zaXRpb246IGZpeGVkOyB6LWluZGV4OiAyMjA7IG1pbi13aWR0aDogMTg4cHg7DQogIHBhZGRpbmc6IDRweDsgYmFja2dyb3VuZDogI2ZmZjsgYm9yZGVyOiAxcHggc29saWQgdmFyKC0tbGluZSk7DQogIGJvcmRlci1yYWRpdXM6IDhweDsgYm94LXNoYWRvdzogdmFyKC0tc2hhZG93KTsNCn0NCiNwcm9jLW1lbnUub24geyBkaXNwbGF5OiBibG9jazsgfQ0KI3Byb2MtbWVudSBidXR0b24gew0KICBkaXNwbGF5OiBmbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBnYXA6IDEwcHg7IHdpZHRoOiAxMDAlOw0KICB0ZXh0LWFsaWduOiBsZWZ0OyBib3JkZXI6IDA7IGJhY2tncm91bmQ6IHRyYW5zcGFyZW50Ow0KICBwYWRkaW5nOiA4cHggMTBweDsgYm9yZGVyLXJhZGl1czogNnB4OyBjdXJzb3I6IHBvaW50ZXI7IGNvbG9yOiB2YXIoLS10eHQpOyBmb250LXNpemU6IDEzcHg7DQp9DQojcHJvYy1tZW51IGJ1dHRvbjpob3ZlciB7IGJhY2tncm91bmQ6ICNmM2Y0ZjY7IH0NCiNwcm9jLW1lbnUgYnV0dG9uLmRhbmdlciB7IGNvbG9yOiAjZGMyNjI2OyB9DQojcHJvYy1tZW51IGJ1dHRvbi5kYW5nZXI6aG92ZXIgeyBiYWNrZ3JvdW5kOiAjZmVmMmYyOyB9DQojcHJvYy1tZW51IGJ1dHRvbjpkaXNhYmxlZCB7IG9wYWNpdHk6IC40NTsgY3Vyc29yOiBkZWZhdWx0OyB9DQojcHJvYy1tZW51IC5jLWljbyB7DQogIHdpZHRoOiAxNnB4OyBoZWlnaHQ6IDE2cHg7IGZsZXgtc2hyaW5rOiAwOw0KICBkaXNwbGF5OiBpbmxpbmUtZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsganVzdGlmeS1jb250ZW50OiBjZW50ZXI7DQogIGNvbG9yOiAjMzc0MTUxOw0KfQ0KI3Byb2MtbWVudSBidXR0b24uZGFuZ2VyIC5jLWljbyB7IGNvbG9yOiAjZGMyNjI2OyB9DQojcHJvYy1tZW51IC5jLWljbyBzdmcgeyB3aWR0aDogMTZweDsgaGVpZ2h0OiAxNnB4OyBkaXNwbGF5OiBibG9jazsgfQ0KI3Byb2MtbWVudSAucGFjdC1sYWJlbCB7DQogIGZsZXg6IDE7IG1pbi13aWR0aDogMDsgb3ZlcmZsb3c6IGhpZGRlbjsgdGV4dC1vdmVyZmxvdzogZWxsaXBzaXM7IHdoaXRlLXNwYWNlOiBub3dyYXA7DQp9DQoNCiNtYWluIHsgZmxleDogMTsgZGlzcGxheTogZ3JpZDsgZ3JpZC10ZW1wbGF0ZS1jb2x1bW5zOiB2YXIoLS1zaWRlLXcpIG1pbm1heCgwLCAxZnIpOyBtaW4taGVpZ2h0OiAwOyBiYWNrZ3JvdW5kOiB2YXIoLS1jaHJvbWUpOyBwYWRkaW5nOiAwIDEwcHggMCAwOyBib3gtc2l6aW5nOiBib3JkZXItYm94OyB9DQojY29udGVudC1wYW5lIHsNCiAgZGlzcGxheTogZ3JpZDsNCiAgZ3JpZC10ZW1wbGF0ZS1jb2x1bW5zOiBtaW5tYXgoMjgwcHgsIDEuMWZyKSBtaW5tYXgoMzIwcHgsIDEuMmZyKTsNCiAgbWluLXdpZHRoOiAwOyBtaW4taGVpZ2h0OiAwOw0KICBiYWNrZ3JvdW5kOiAjZmZmOw0KICBib3JkZXI6IDFweCBzb2xpZCAjZDhkZGU2Ow0KICBib3JkZXItcmFkaXVzOiA0cHg7DQogIG92ZXJmbG93OiBoaWRkZW47DQp9DQojbWFpbi5tb2RlLXRvb2wgI2NvbnRlbnQtcGFuZSB7DQogIGdyaWQtdGVtcGxhdGUtY29sdW1uczogMWZyOw0KfQ0KI21haW4ubW9kZS1oYW5kbGUgI3ByZXZpZXcgeyBkaXNwbGF5OiBub25lOyB9DQoNCi8qIHNpZGUgKi8NCiNzaWRlIHsNCiAgYmFja2dyb3VuZDogdmFyKC0tY2hyb21lKTsgYm9yZGVyLXJpZ2h0OiAwOw0KICBkaXNwbGF5OiBmbGV4OyBmbGV4LWRpcmVjdGlvbjogY29sdW1uOyBwYWRkaW5nOiAxMHB4IDhweDsgZ2FwOiAycHg7DQp9DQouY2F0IHsNCiAgZGlzcGxheTogZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsgZ2FwOiAxMHB4OyBoZWlnaHQ6IDQycHg7IHBhZGRpbmc6IDAgMTBweDsNCiAgYm9yZGVyOiAwOyBib3JkZXItcmFkaXVzOiA4cHg7IGJhY2tncm91bmQ6IHRyYW5zcGFyZW50OyBjb2xvcjogdmFyKC0tdHh0KTsgY3Vyc29yOiBwb2ludGVyOw0KICB0ZXh0LWFsaWduOiBsZWZ0OyBwb3NpdGlvbjogcmVsYXRpdmU7DQp9DQouY2F0OmhvdmVyIHsgYmFja2dyb3VuZDogI2VlZjFmNjsgfQ0KLmNhdC5vbiB7IGJhY2tncm91bmQ6ICNlOGViZjI7IGZvbnQtd2VpZ2h0OiA2MDA7IH0NCi5jYXQub246OmJlZm9yZSB7DQogIGNvbnRlbnQ6ICIiOyBwb3NpdGlvbjogYWJzb2x1dGU7IGxlZnQ6IDA7IHRvcDogOHB4OyBib3R0b206IDhweDsgd2lkdGg6IDNweDsNCiAgYm9yZGVyLXJhZGl1czogMnB4OyBiYWNrZ3JvdW5kOiB2YXIoLS1hY2MpOw0KfQ0KLmNhdCAuaWNvIHsNCiAgd2lkdGg6IDMycHg7IGhlaWdodDogMzJweDsgZmxleC1zaHJpbms6IDA7DQogIGRpc3BsYXk6IGlubGluZS1mbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBqdXN0aWZ5LWNvbnRlbnQ6IGNlbnRlcjsNCiAgY29sb3I6IHZhcigtLXR4dDIpOyBmb250LXNpemU6IDE0cHg7IGxpbmUtaGVpZ2h0OiAxOw0KfQ0KLmNhdCBpbWcuaWNvIHsNCiAgd2lkdGg6IDMycHg7IGhlaWdodDogMzJweDsNCiAgb2JqZWN0LWZpdDogY29udGFpbjsgaW1hZ2UtcmVuZGVyaW5nOiBhdXRvOw0KfQ0KDQouc2lkZS1zZXAgew0KICBoZWlnaHQ6IDFweDsgbWFyZ2luOiA4cHggMTBweDsgYmFja2dyb3VuZDogdmFyKC0tbGluZSk7IGZsZXgtc2hyaW5rOiAwOw0KfQ0KI2xpc3QtcGFuZSB7IHBvc2l0aW9uOiByZWxhdGl2ZTsgfQ0KI2ZpbGUtcmVzdWx0cyB7IGRpc3BsYXk6IGZsZXg7IGZsZXgtZGlyZWN0aW9uOiBjb2x1bW47IGZsZXg6IDE7IG1pbi1oZWlnaHQ6IDA7IH0NCiNmaWxlLXJlc3VsdHMuaGlkZGVuIHsgZGlzcGxheTogbm9uZSAhaW1wb3J0YW50OyB9DQojaGFuZGxlLXBhbmVsLmVtYmVkZGVkIHsNCiAgZmxleDogMTsgbWluLWhlaWdodDogMDsgbWFyZ2luOiAwOyBib3JkZXI6IDA7IGJvcmRlci1yYWRpdXM6IDA7DQogIGRpc3BsYXk6IGZsZXg7IGZsZXgtZGlyZWN0aW9uOiBjb2x1bW47IG92ZXJmbG93OiBoaWRkZW47IGJhY2tncm91bmQ6ICNmZmY7DQp9DQojaGFuZGxlLXBhbmVsLmVtYmVkZGVkLmhpZGRlbiB7IGRpc3BsYXk6IG5vbmUgIWltcG9ydGFudDsgfQ0KI2luZm8tcGFuZWwuZW1iZWRkZWQgew0KICBmbGV4OiAxOyBtaW4taGVpZ2h0OiAwOyBvdmVyZmxvdzogYXV0bzsgcGFkZGluZzogOHB4IDE2cHggMTJweDsgYmFja2dyb3VuZDogI2ZmZjsNCiAgYm9yZGVyOiAwOyBtYXJnaW46IDA7DQp9DQojaW5mby1wYW5lbC5lbWJlZGRlZC5oaWRkZW4geyBkaXNwbGF5OiBub25lICFpbXBvcnRhbnQ7IH0NCiNtYWluLm1vZGUtdG9vbCAjcHJldmlldyB7IGRpc3BsYXk6IG5vbmU7IH0NCiNtYWluLm1vZGUtdG9vbCB7DQogIGdyaWQtdGVtcGxhdGUtY29sdW1uczogdmFyKC0tc2lkZS13KSBtaW5tYXgoMCwgMWZyKTsNCn0NCiNiYXIubW9kZS10b29sIC5zb3J0LCAjYmFyLm1vZGUtdG9vbCAudG9nZ2xlIHsgZGlzcGxheTogbm9uZTsgfQ0KI2Jhci5tb2RlLWluZm8gLnNvcnQsICNiYXIubW9kZS1pbmZvIC50b2dnbGUgeyBkaXNwbGF5OiBub25lOyB9DQojdmlldy1wcm9jIHsgZGlzcGxheTogbm9uZSAhaW1wb3J0YW50OyB9DQojYnRuLWdvdG8tcHJvYyB7IGRpc3BsYXk6IG5vbmUgIWltcG9ydGFudDsgfQ0KI3NpZGUtZm9vdCB7IG1hcmdpbi10b3A6IGF1dG87IHBhZGRpbmc6IDhweCA2cHg7IH0NCiNidG4tc2V0dGluZ3Mgew0KICB3aWR0aDogMzRweDsgaGVpZ2h0OiAzNHB4OyBib3JkZXI6IDA7IGJvcmRlci1yYWRpdXM6IDhweDsgYmFja2dyb3VuZDogdHJhbnNwYXJlbnQ7DQogIGNvbG9yOiB2YXIoLS10eHQyKTsgY3Vyc29yOiBwb2ludGVyOw0KfQ0KI2J0bi1zZXR0aW5nczpob3ZlciB7IGJhY2tncm91bmQ6ICNlZWYxZjY7IGNvbG9yOiB2YXIoLS10eHQpOyB9DQoNCi8qIGxpc3QgKi8NCiNsaXN0LXBhbmUgew0KICBkaXNwbGF5OiBmbGV4OyBmbGV4LWRpcmVjdGlvbjogY29sdW1uOyBtaW4td2lkdGg6IDA7IG1pbi1oZWlnaHQ6IDA7DQogIGJhY2tncm91bmQ6ICNmZmY7IGJvcmRlcjogMDsgb3ZlcmZsb3c6IGhpZGRlbjsNCiAgYm9yZGVyLXJhZGl1czogMDsgYm94LXNoYWRvdzogbm9uZTsgb3V0bGluZTogbm9uZTsNCn0NCiNsaXN0IHsNCiAgZmxleDogMTsgbWluLWhlaWdodDogMDsgb3ZlcmZsb3cteTogYXV0bzsgb3ZlcmZsb3cteDogaGlkZGVuOyBwYWRkaW5nOiA0cHggMDsNCiAgc2Nyb2xsYmFyLXdpZHRoOiB0aGluOyBzY3JvbGxiYXItY29sb3I6ICNjNWM5ZDQgdHJhbnNwYXJlbnQ7DQogIC13ZWJraXQtb3ZlcmZsb3ctc2Nyb2xsaW5nOiB0b3VjaDsNCn0NCiNsaXN0Ojotd2Via2l0LXNjcm9sbGJhciB7IHdpZHRoOiA4cHg7IH0NCiNsaXN0Ojotd2Via2l0LXNjcm9sbGJhci10aHVtYiB7IGJhY2tncm91bmQ6ICNjNWM5ZDQ7IGJvcmRlci1yYWRpdXM6IDRweDsgfQ0KLnJvdyB7DQogIGRpc3BsYXk6IGdyaWQ7IGdyaWQtdGVtcGxhdGUtY29sdW1uczogNDBweCAxZnI7IGdhcDogMTBweDsNCiAgYWxpZ24taXRlbXM6IGNlbnRlcjsgbWluLWhlaWdodDogNDRweDsNCiAgcGFkZGluZzogNnB4IDE0cHg7IGN1cnNvcjogcG9pbnRlcjsgYm9yZGVyLWxlZnQ6IDNweCBzb2xpZCB0cmFuc3BhcmVudDsNCn0NCi5yb3c6aG92ZXIgeyBiYWNrZ3JvdW5kOiAjZjdmOGZiOyB9DQoucm93Lm9uIHsgYmFja2dyb3VuZDogdmFyKC0tc2VsKTsgYm9yZGVyLWxlZnQtY29sb3I6IHZhcigtLWFjYyk7IH0NCi5yb3cgLmZpIHsNCiAgd2lkdGg6IDMycHg7IGhlaWdodDogMzJweDsNCiAgY29sb3I6IHZhcigtLXR4dDIpOyBkaXNwbGF5OiBncmlkOyBwbGFjZS1pdGVtczogY2VudGVyOyBmbGV4LXNocmluazogMDsNCn0NCi5yb3cgLmZpIGltZyB7DQogIHdpZHRoOiAzMnB4OyBoZWlnaHQ6IDMycHg7DQogIG9iamVjdC1maXQ6IGNvbnRhaW47IGRpc3BsYXk6IGJsb2NrOyBiYWNrZ3JvdW5kOiB0cmFuc3BhcmVudDsNCiAgaW1hZ2UtcmVuZGVyaW5nOiBhdXRvOw0KfQ0KLnJvdyAuZmkgLmZpLWZhbGxiYWNrIHsgZm9udC1zaXplOiAxOHB4OyBsaW5lLWhlaWdodDogMTsgfQ0KLnJvdyAubmFtZSB7IGNvbG9yOiB2YXIoLS1uYW1lKTsgZm9udC1zaXplOiAxMy41cHg7IGZvbnQtd2VpZ2h0OiA2MDA7IHdvcmQtYnJlYWs6IGJyZWFrLWFsbDsgbGluZS1oZWlnaHQ6IDEuMzU7IH0NCi5yb3cgLm5hbWUgLmV4dCB7IGNvbG9yOiB2YXIoLS1uYW1lLWV4dCk7IH0NCi5yb3cgLm5hbWUgbWFyaywgLnJvdyAucGF0aCBtYXJrIHsNCiAgYmFja2dyb3VuZDogdmFyKC0taGwpOyBjb2xvcjogdmFyKC0taGwtdGV4dCk7IHBhZGRpbmc6IDAgMXB4OyBib3JkZXItcmFkaXVzOiAycHg7DQogIGZvbnQtd2VpZ2h0OiA3MDA7DQp9DQoucm93IC5wYXRoIHsgY29sb3I6ICM0YjU1NjM7IGZvbnQtc2l6ZTogMTJweDsgbWFyZ2luLXRvcDogMnB4OyB3b3JkLWJyZWFrOiBicmVhay1hbGw7IH0NCiNsaXN0LWVtcHR5IHsNCiAgZGlzcGxheTogbm9uZTsgZmxleDogMTsgYWxpZ24taXRlbXM6IGNlbnRlcjsganVzdGlmeS1jb250ZW50OiBjZW50ZXI7DQogIGNvbG9yOiB2YXIoLS10eHQzKTsgZm9udC1zaXplOiAxNHB4Ow0KfQ0KI2xpc3QtZW1wdHkub24geyBkaXNwbGF5OiBmbGV4OyB9DQoNCi8qIHByZXZpZXcgKi8NCiNwcmV2aWV3IHsNCiAgYmFja2dyb3VuZDogI2ZmZjsgbWluLXdpZHRoOiAwOyBtaW4taGVpZ2h0OiAwOyBkaXNwbGF5OiBmbGV4OyBmbGV4LWRpcmVjdGlvbjogY29sdW1uOyBvdmVyZmxvdzogaGlkZGVuOw0KICBib3JkZXI6IDA7IGJvcmRlci1yYWRpdXM6IDA7IGJveC1zaGFkb3c6IG5vbmU7IG91dGxpbmU6IG5vbmU7DQp9DQojcHJldmlldy5vZmYgLnB2LWJvZHkgeyBkaXNwbGF5OiBub25lOyB9DQojcHJldmlldy5vZmYgLnB2LW9mZiB7DQogIGRpc3BsYXk6IGZsZXg7IGZsZXg6IDE7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGp1c3RpZnktY29udGVudDogY2VudGVyOyBjb2xvcjogdmFyKC0tdHh0Myk7DQp9DQoucHYtb2ZmIHsgZGlzcGxheTogbm9uZTsgfQ0KLnB2LW1ldGEgew0KICBkaXNwbGF5OiBmbGV4OyBnYXA6IDE0cHg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IHBhZGRpbmc6IDEwcHggMTRweDsNCiAgYm9yZGVyLWJvdHRvbTogMXB4IHNvbGlkIHZhcigtLWxpbmUpOyBjb2xvcjogdmFyKC0tdHh0Mik7IGZvbnQtc2l6ZTogMTJweDsgZmxleC13cmFwOiB3cmFwOw0KfQ0KLnB2LW1ldGEgYiB7IGNvbG9yOiB2YXIoLS10eHQpOyBmb250LXdlaWdodDogNjAwOyB9DQoucHYtbWV0YSAuZHJ2IHsNCiAgZGlzcGxheTogaW5saW5lLWZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGdhcDogNnB4Ow0KICBjb2xvcjogdmFyKC0tdHh0KTsgZm9udC13ZWlnaHQ6IDYwMDsNCn0NCi5wdi1tZXRhIC5kcnYgaW1nIHsNCiAgd2lkdGg6IDE2cHg7IGhlaWdodDogMTZweDsgb2JqZWN0LWZpdDogY29udGFpbjsgYmFja2dyb3VuZDogdHJhbnNwYXJlbnQ7IGZsZXgtc2hyaW5rOiAwOw0KfQ0KLnB2LWJvZHkgeyBmbGV4OiAxOyBtaW4taGVpZ2h0OiAwOyBkaXNwbGF5OiBmbGV4OyBmbGV4LWRpcmVjdGlvbjogY29sdW1uOyB9DQoucHYtbWVkaWEgew0KICBmbGV4OiAxOyBtaW4taGVpZ2h0OiAwOyBiYWNrZ3JvdW5kOiAjM2Y0NDUwOyBkaXNwbGF5OiBmbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBqdXN0aWZ5LWNvbnRlbnQ6IGNlbnRlcjsNCiAgb3ZlcmZsb3c6IGhpZGRlbjsgcG9zaXRpb246IHJlbGF0aXZlOw0KfQ0KLnB2LW1lZGlhLmNvbXBhY3Qgew0KICBmbGV4OiAwIDAgYXV0bzsgbWluLWhlaWdodDogMDsgaGVpZ2h0OiAwOyBwYWRkaW5nOiAwOyBvdmVyZmxvdzogaGlkZGVuOw0KICBib3JkZXI6IDA7DQp9DQoucHYtYm9keS50ZXh0LW1vZGUgLnB2LW1lZGlhIHsgZGlzcGxheTogbm9uZTsgfQ0KLnB2LWJvZHkudGV4dC1tb2RlIC5wdi10ZXh0IHsNCiAgZmxleDogMTsgZGlzcGxheTogZmxleDsgYm9yZGVyLXRvcDogMDsgbWluLWhlaWdodDogMDsNCn0NCi5wdi1tZWRpYSBpbWcsIC5wdi1tZWRpYSB2aWRlbyB7DQogIG1heC13aWR0aDogMTAwJTsgbWF4LWhlaWdodDogMTAwJTsgb2JqZWN0LWZpdDogY29udGFpbjsgYmFja2dyb3VuZDogIzExMTsNCn0NCi5wdi1tZWRpYSAucHYtZmlsZWluZm8gaW1nLmJpZy1pY28gew0KICBiYWNrZ3JvdW5kOiB0cmFuc3BhcmVudCAhaW1wb3J0YW50Ow0KICBtYXgtd2lkdGg6IDQ4cHg7IG1heC1oZWlnaHQ6IDQ4cHg7DQp9DQoucHYtbWVkaWEgZW1iZWQucGRmLCAucHYtbWVkaWEgaWZyYW1lLnBkZiB7DQogIHdpZHRoOiAxMDAlOyBoZWlnaHQ6IDEwMCU7IGJvcmRlcjogMDsgYmFja2dyb3VuZDogIzUyNTY1OTsNCn0NCi5wdi1tZWRpYSAucGggeyBjb2xvcjogI2NiZDVlMTsgZm9udC1zaXplOiAxM3B4OyB9DQoucHYtZmlsZWluZm8gew0KICBkaXNwbGF5OiBmbGV4OyBmbGV4LWRpcmVjdGlvbjogY29sdW1uOyBhbGlnbi1pdGVtczogc3RyZXRjaDsganVzdGlmeS1jb250ZW50OiBjZW50ZXI7DQogIGdhcDogMTBweDsgcGFkZGluZzogMjhweCAyNHB4OyB0ZXh0LWFsaWduOiBsZWZ0OyB3aWR0aDogMTAwJTsgaGVpZ2h0OiAxMDAlOw0KICBib3gtc2l6aW5nOiBib3JkZXItYm94OyBvdmVyZmxvdzogYXV0bzsNCiAgYmFja2dyb3VuZDogI2Y3ZjhmYjsgY29sb3I6IHZhcigtLXR4dCk7DQp9DQoucHYtZmlsZWluZm8gLmJpZy1pY28gew0KICB3aWR0aDogNDhweDsgaGVpZ2h0OiA0OHB4OyBvYmplY3QtZml0OiBjb250YWluOyBhbGlnbi1zZWxmOiBjZW50ZXI7DQogIGJhY2tncm91bmQ6IHRyYW5zcGFyZW50ICFpbXBvcnRhbnQ7DQogIGltYWdlLXJlbmRlcmluZzogYXV0bzsgZmxleC1zaHJpbms6IDA7DQp9DQoucHYtbWVkaWE6aGFzKC5wdi1maWxlaW5mbykgeyBiYWNrZ3JvdW5kOiAjZjdmOGZiOyB9DQoucHYtZmlsZWluZm8gLmZuIHsNCiAgZm9udC1zaXplOiAxNnB4OyBmb250LXdlaWdodDogNjUwOyBjb2xvcjogdmFyKC0tdHh0KTsNCiAgd29yZC1icmVhazogYnJlYWstYWxsOyB0ZXh0LWFsaWduOiBjZW50ZXI7IHdpZHRoOiAxMDAlOyBsaW5lLWhlaWdodDogMS4zNTsNCn0NCi5wdi1maWxlaW5mbyAudG4gew0KICBmb250LXNpemU6IDEycHg7IGNvbG9yOiB2YXIoLS10eHQyKTsgdGV4dC1hbGlnbjogY2VudGVyOyB3aWR0aDogMTAwJTsNCn0NCi5wdi1maWxlaW5mbyAuaGludCB7DQogIGZvbnQtc2l6ZTogMTJweDsgY29sb3I6ICNiNDUzMDk7IHRleHQtYWxpZ246IGNlbnRlcjsgd2lkdGg6IDEwMCU7IGxpbmUtaGVpZ2h0OiAxLjQ1Ow0KfQ0KLnB2LWZpbGVpbmZvIC5rdiB7DQogIGRpc3BsYXk6IGZsZXg7IGZsZXgtZGlyZWN0aW9uOiBjb2x1bW47IGdhcDogOHB4Ow0KICBtYXJnaW4tdG9wOiA2cHg7IHdpZHRoOiAxMDAlOyBmb250LXNpemU6IDEyLjVweDsgY29sb3I6IHZhcigtLXR4dDIpOw0KfQ0KLnB2LWZpbGVpbmZvIC5rdi1yb3cgew0KICBkaXNwbGF5OiBncmlkOyBncmlkLXRlbXBsYXRlLWNvbHVtbnM6IDQuNWVtIDFmcjsgZ2FwOiAxMnB4OyBhbGlnbi1pdGVtczogc3RhcnQ7DQogIGxpbmUtaGVpZ2h0OiAxLjU1Ow0KfQ0KLnB2LWZpbGVpbmZvIC5rdi1yb3cgLmsgeyBjb2xvcjogdmFyKC0tdHh0Mik7IHdoaXRlLXNwYWNlOiBub3dyYXA7IH0NCi5wdi1maWxlaW5mbyAua3Ytcm93IC52IHsgY29sb3I6IHZhcigtLXR4dCk7IHdvcmQtYnJlYWs6IGJyZWFrLWFsbDsgZm9udC13ZWlnaHQ6IDUwMDsgfQ0KLnB2LWZpbGVpbmZvIC5raWRzIHsNCiAgbWFyZ2luLXRvcDogOHB4OyBmb250LXNpemU6IDEyLjVweDsgY29sb3I6IHZhcigtLXR4dDIpOyBsaW5lLWhlaWdodDogMS42Ow0KICB3b3JkLWJyZWFrOiBicmVhay1hbGw7DQp9DQoucHYtZmlsZWluZm8gLmtpZHMgYiB7IGNvbG9yOiB2YXIoLS10eHQpOyBmb250LXdlaWdodDogNjAwOyB9DQoNCi8qIGNvbnRleHQgbWVudSAqLw0KI2N0eCB7DQogIGRpc3BsYXk6IG5vbmU7IHBvc2l0aW9uOiBmaXhlZDsgei1pbmRleDogMjAwOyBtaW4td2lkdGg6IDE2OHB4Ow0KICBwYWRkaW5nOiA0cHg7IGJhY2tncm91bmQ6ICNmZmY7IGJvcmRlcjogMXB4IHNvbGlkIHZhcigtLWxpbmUpOw0KICBib3JkZXItcmFkaXVzOiA4cHg7IGJveC1zaGFkb3c6IDAgOHB4IDI0cHggcmdiYSgxNSwyMyw0MiwuMTIpOw0KfQ0KI2N0eC5vbiB7IGRpc3BsYXk6IGJsb2NrOyB9DQojY3R4IGJ1dHRvbiB7DQogIGRpc3BsYXk6IGZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGdhcDogMTBweDsgd2lkdGg6IDEwMCU7DQogIGJvcmRlcjogMDsgYmFja2dyb3VuZDogdHJhbnNwYXJlbnQ7IHBhZGRpbmc6IDhweCAxMHB4OyBib3JkZXItcmFkaXVzOiA2cHg7DQogIGN1cnNvcjogcG9pbnRlcjsgY29sb3I6IHZhcigtLXR4dCk7IGZvbnQtc2l6ZTogMTNweDsgdGV4dC1hbGlnbjogbGVmdDsNCn0NCiNjdHggYnV0dG9uOmhvdmVyIHsgYmFja2dyb3VuZDogI2YzZjRmNjsgfQ0KI2N0eCBidXR0b24uZGFuZ2VyIHsgY29sb3I6ICNkYzI2MjY7IH0NCiNjdHggYnV0dG9uLmRhbmdlcjpob3ZlciB7IGJhY2tncm91bmQ6ICNmZWYyZjI7IH0NCiNjdHggLmMtaWNvIHsNCiAgd2lkdGg6IDE2cHg7IGhlaWdodDogMTZweDsgZmxleC1zaHJpbms6IDA7DQogIGRpc3BsYXk6IGlubGluZS1mbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBqdXN0aWZ5LWNvbnRlbnQ6IGNlbnRlcjsNCiAgY29sb3I6ICMzNzQxNTE7DQp9DQojY3R4IGJ1dHRvbi5kYW5nZXIgLmMtaWNvIHsgY29sb3I6ICNkYzI2MjY7IH0NCiNjdHggLmMtaWNvIHN2ZyB7IHdpZHRoOiAxNnB4OyBoZWlnaHQ6IDE2cHg7IGRpc3BsYXk6IGJsb2NrOyB9DQoNCi5wdi10ZXh0IHsNCiAgZmxleDogMTsgbWluLWhlaWdodDogMDsgZGlzcGxheTogZmxleDsgZmxleC1kaXJlY3Rpb246IGNvbHVtbjsgYm9yZGVyLXRvcDogMXB4IHNvbGlkIHZhcigtLWxpbmUpOw0KfQ0KLnB2LXRleHQgLmhkIHsNCiAgcGFkZGluZzogOHB4IDE0cHg7IGZvbnQtc2l6ZTogMTJweDsgY29sb3I6IHZhcigtLXR4dDIpOyBiYWNrZ3JvdW5kOiAjZmFmYmZjOyBib3JkZXItYm90dG9tOiAxcHggc29saWQgdmFyKC0tbGluZSk7DQp9DQoucHYtdGV4dCBwcmUgew0KICBtYXJnaW46IDA7IGZsZXg6IDE7IG92ZXJmbG93OiBhdXRvOyBwYWRkaW5nOiAxMnB4IDE0cHg7IGZvbnQtc2l6ZTogMTJweDsgbGluZS1oZWlnaHQ6IDEuNTsNCiAgd2hpdGUtc3BhY2U6IHByZS13cmFwOyB3b3JkLWJyZWFrOiBicmVhay13b3JkOyBmb250LWZhbWlseTogQ29uc29sYXMsICJTYXJhc2EgTW9ubyBTQyIsIG1vbm9zcGFjZTsNCiAgYmFja2dyb3VuZDogI2ZmZjsgY29sb3I6ICMxMTE4Mjc7DQp9DQoNCi8qIGJvdHRvbSAqLw0KI2JhciB7DQogIGhlaWdodDogNDJweDsgZGlzcGxheTogZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsgZ2FwOiAxNnB4Ow0KICBwYWRkaW5nOiAwIDE0cHg7IGJhY2tncm91bmQ6IHZhcigtLWNocm9tZSk7IGJvcmRlci10b3A6IDA7IGZvbnQtc2l6ZTogMTIuNXB4OyBjb2xvcjogdmFyKC0tdHh0Mik7DQp9DQojYmFyIC5zb3J0IHsgZGlzcGxheTogaW5saW5lLWZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGdhcDogNnB4OyBjdXJzb3I6IHBvaW50ZXI7IGJvcmRlcjogMDsgYmFja2dyb3VuZDogdHJhbnNwYXJlbnQ7IGNvbG9yOiBpbmhlcml0OyB9DQojYmFyIC5zb3J0OmhvdmVyIHsgY29sb3I6IHZhcigtLXR4dCk7IH0NCiNiYXIgLnNwYWNlciB7IGZsZXg6IDE7IH0NCi50b2dnbGUgew0KICBkaXNwbGF5OiBpbmxpbmUtZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsgZ2FwOiA4cHg7IGN1cnNvcjogcG9pbnRlcjsgdXNlci1zZWxlY3Q6IG5vbmU7DQp9DQoudG9nZ2xlIGlucHV0IHsgZGlzcGxheTogbm9uZTsgfQ0KLnRvZ2dsZSAuc3cgew0KICB3aWR0aDogMzZweDsgaGVpZ2h0OiAyMHB4OyBib3JkZXItcmFkaXVzOiA5OTlweDsgYmFja2dyb3VuZDogI2QxZDVkYjsgcG9zaXRpb246IHJlbGF0aXZlOyB0cmFuc2l0aW9uOiAuMnM7DQp9DQoudG9nZ2xlIC5zdzo6YWZ0ZXIgew0KICBjb250ZW50OiAiIjsgcG9zaXRpb246IGFic29sdXRlOyB0b3A6IDJweDsgbGVmdDogMnB4OyB3aWR0aDogMTZweDsgaGVpZ2h0OiAxNnB4Ow0KICBib3JkZXItcmFkaXVzOiA1MCU7IGJhY2tncm91bmQ6ICNmZmY7IHRyYW5zaXRpb246IC4yczsgYm94LXNoYWRvdzogMCAxcHggMnB4IHJnYmEoMCwwLDAsLjIpOw0KfQ0KLnRvZ2dsZSBpbnB1dDpjaGVja2VkICsgLnN3IHsgYmFja2dyb3VuZDogdmFyKC0tYWNjKTsgfQ0KLnRvZ2dsZSBpbnB1dDpjaGVja2VkICsgLnN3OjphZnRlciB7IGxlZnQ6IDE4cHg7IH0NCiNjb3VudCB7IGNvbG9yOiB2YXIoLS10eHQpOyBmb250LXZhcmlhbnQtbnVtZXJpYzogdGFidWxhci1udW1zOyB9DQo8L3N0eWxlPg0KPC9oZWFkPg0KPGJvZHk+DQo8ZGl2IGlkPSJhcHAiPg0KICA8ZGl2IGlkPSJib290IiBjbGFzcz0ib24iPg0KICAgIDxkaXYgY2xhc3M9InJpbmctd3JhcCI+DQogICAgICA8c3ZnIHZpZXdCb3g9IjAgMCAxMjAgMTIwIj4NCiAgICAgICAgPGNpcmNsZSBjbGFzcz0icmluZy1iZyIgY3g9IjYwIiBjeT0iNjAiIHI9IjUyIj48L2NpcmNsZT4NCiAgICAgICAgPGNpcmNsZSBpZD0icmluZy1mZyIgY2xhc3M9InJpbmctZmciIGN4PSI2MCIgY3k9IjYwIiByPSI1MiINCiAgICAgICAgICBzdHJva2UtZGFzaGFycmF5PSIzMjYuNzMiIHN0cm9rZS1kYXNob2Zmc2V0PSIzMjYuNzMiPjwvY2lyY2xlPg0KICAgICAgPC9zdmc+DQogICAgICA8ZGl2IGNsYXNzPSJyaW5nLWxhYmVsIj4NCiAgICAgICAgPGRpdiBjbGFzcz0idDEiPuejgeebmOe0ouW8leS4rTwvZGl2Pg0KICAgICAgICA8ZGl2IGNsYXNzPSJ0MiIgaWQ9ImJvb3QtcGN0Ij7igKY8L2Rpdj4NCiAgICAgIDwvZGl2Pg0KICAgIDwvZGl2Pg0KICAgIDxkaXYgY2xhc3M9ImJvb3QtaGludCI+DQogICAgICDmraPlnKjlu7rnq4vno4Hnm5jmlofku7bntKLlvJXvvIzlrozmiJDlkI7ljbPlj6/mkJzntKLjgII8YnI+DQogICAgICDoi6XmnKzmnLrlt7Llronoo4UgRXZlcnl0aGluZyDlubblvIDmnLrlkK/liqjvvIzkuIvmrKHkvJrmm7Tlv6vlsLHnu6rjgIINCiAgICA8L2Rpdj4NCiAgPC9kaXY+DQoNCiAgPGRpdiBpZD0iY2hyb21lIiBjbGFzcz0iaGlkZGVuIj4NCiAgICA8ZGl2IGlkPSJ2aWV3LXNlYXJjaCI+DQogICAgPGRpdiBpZD0idG9wIj4NCiAgICAgIDxkaXYgaWQ9ImRyaXZlLXdyYXAiIGNsYXNzPSJuby1kcmFnIj4NCiAgICAgICAgPGJ1dHRvbiBpZD0iYnRuLWRyaXZlIiB0eXBlPSJidXR0b24iIHRpdGxlPSLpgInmi6nmkJzntKLno4Hnm5giPg0KICAgICAgICAgIDxpbWcgaWQ9ImRyaXZlLWJ0bi1pY28iIGNsYXNzPSJkcml2ZS1pY28gaGlkZGVuIiBhbHQ9IiIgd2lkdGg9IjIwIiBoZWlnaHQ9IjIwIj4NCiAgICAgICAgICA8c3BhbiBpZD0iZHJpdmUtbGFiZWwiPuWFqOebmOaQnOe0ojwvc3Bhbj48c3BhbiBjbGFzcz0iY2FyZXQiPuKWvjwvc3Bhbj4NCiAgICAgICAgPC9idXR0b24+DQogICAgICAgIDxkaXYgaWQ9ImRyaXZlLW1lbnUiIHJvbGU9Im1lbnUiPjwvZGl2Pg0KICAgICAgPC9kaXY+DQogICAgICA8ZGl2IGlkPSJ0b3AtcmVzdCI+DQogICAgICAgIDxkaXYgaWQ9InNlYXJjaC13cmFwIiBjbGFzcz0ibm8tZHJhZyI+DQogICAgICAgICAgPGRpdiBpZD0ic2VhcmNoLWJveCI+DQogICAgICAgICAgICA8aW5wdXQgaWQ9InEiIHR5cGU9InRleHQiIHBsYWNlaG9sZGVyPSLovpPlhaXmlofku7blkI0gLyDmianlsZXlkI0gLyDot6/lvoTlhbPplK7lrZfvvJt8IOihqOekuuS4lO+8jHx8IOihqOekuuaIliIgYXV0b2NvbXBsZXRlPSJvZmYiIHNwZWxsY2hlY2s9ImZhbHNlIj4NCiAgICAgICAgICAgIDxidXR0b24gaWQ9ImJ0bi1jbGVhciIgdHlwZT0iYnV0dG9uIiB0aXRsZT0i5riF56m65pCc57SiIj7muIXnqbo8L2J1dHRvbj4NCiAgICAgICAgICAgIDxidXR0b24gaWQ9ImJ0bi1oaXN0IiB0eXBlPSJidXR0b24iIHRpdGxlPSLmnIDov5HmkJzntKIiPuKWvjwvYnV0dG9uPg0KICAgICAgICAgICAgPGRpdiBpZD0iaGlzdC1tZW51IiByb2xlPSJtZW51Ij48L2Rpdj4NCiAgICAgICAgICA8L2Rpdj4NCiAgICAgICAgPC9kaXY+DQogICAgICAgIDxkaXYgaWQ9InRvcC1wcmV2aWV3IiBjbGFzcz0ibm8tZHJhZyI+DQogICAgICAgICAgPGRpdiBjbGFzcz0icHYtbWV0YSIgaWQ9InB2LW1ldGEiPumAieaLqeaWh+S7tuS7pemihOiniDwvZGl2Pg0KICAgICAgICA8L2Rpdj4NCiAgICAgIDwvZGl2Pg0KICAgIDwvZGl2Pg0KDQogICAgPGRpdiBpZD0ibWFpbiI+DQogICAgICA8YXNpZGUgaWQ9InNpZGUiPg0KICAgICAgICA8YnV0dG9uIGNsYXNzPSJjYXQgb24iIGRhdGEtY2F0PSJhbGwiPjxzcGFuIGNsYXNzPSJpY28iIGRhdGEtY2F0LWljbz0iYWxsIj7imLA8L3NwYW4+5YWo6YOoPC9idXR0b24+DQogICAgICAgIDxidXR0b24gY2xhc3M9ImNhdCIgZGF0YS1jYXQ9ImZvbGRlciI+PHNwYW4gY2xhc3M9ImljbyIgZGF0YS1jYXQtaWNvPSJmb2xkZXIiPvCfk4E8L3NwYW4+5paH5Lu25aS5PC9idXR0b24+DQogICAgICAgIDxidXR0b24gY2xhc3M9ImNhdCIgZGF0YS1jYXQ9ImV4Y2VsIj48c3BhbiBjbGFzcz0iaWNvIiBkYXRhLWNhdC1pY289ImV4Y2VsIj7wn5OKPC9zcGFuPkVYQ0VMPC9idXR0b24+DQogICAgICAgIDxidXR0b24gY2xhc3M9ImNhdCIgZGF0YS1jYXQ9IndvcmQiPjxzcGFuIGNsYXNzPSJpY28iIGRhdGEtY2F0LWljbz0id29yZCI+8J+ThDwvc3Bhbj5XT1JEPC9idXR0b24+DQogICAgICAgIDxidXR0b24gY2xhc3M9ImNhdCIgZGF0YS1jYXQ9InBwdCI+PHNwYW4gY2xhc3M9ImljbyIgZGF0YS1jYXQtaWNvPSJwcHQiPvCfk5E8L3NwYW4+UFBUPC9idXR0b24+DQogICAgICAgIDxidXR0b24gY2xhc3M9ImNhdCIgZGF0YS1jYXQ9InBkZiI+PHNwYW4gY2xhc3M9ImljbyIgZGF0YS1jYXQtaWNvPSJwZGYiPvCfk5U8L3NwYW4+UERGPC9idXR0b24+DQogICAgICAgIDxidXR0b24gY2xhc3M9ImNhdCIgZGF0YS1jYXQ9ImltYWdlIj48c3BhbiBjbGFzcz0iaWNvIiBkYXRhLWNhdC1pY289ImltYWdlIj7wn5a8PC9zcGFuPuWbvueJhzwvYnV0dG9uPg0KICAgICAgICA8YnV0dG9uIGNsYXNzPSJjYXQiIGRhdGEtY2F0PSJ2aWRlbyI+PHNwYW4gY2xhc3M9ImljbyIgZGF0YS1jYXQtaWNvPSJ2aWRlbyI+4pa2PC9zcGFuPuinhumikTwvYnV0dG9uPg0KICAgICAgICA8YnV0dG9uIGNsYXNzPSJjYXQiIGRhdGEtY2F0PSJhdWRpbyI+PHNwYW4gY2xhc3M9ImljbyIgZGF0YS1jYXQtaWNvPSJhdWRpbyI+4pmqPC9zcGFuPumfs+mikTwvYnV0dG9uPg0KICAgICAgICA8YnV0dG9uIGNsYXNzPSJjYXQiIGRhdGEtY2F0PSJ6aXAiPjxzcGFuIGNsYXNzPSJpY28iIGRhdGEtY2F0LWljbz0iemlwIj7wn5ecPC9zcGFuPuWOi+e8qeaWh+S7tjwvYnV0dG9uPg0KICAgICAgICA8ZGl2IGNsYXNzPSJzaWRlLXNlcCIgcm9sZT0ic2VwYXJhdG9yIj48L2Rpdj4NCiAgICAgICAgPGJ1dHRvbiBjbGFzcz0iY2F0IiBkYXRhLWNhdD0iX19oYW5kbGUiIHR5cGU9ImJ1dHRvbiI+PHNwYW4gY2xhc3M9ImljbyI+4puTPC9zcGFuPuWFs+iBlOWPpeafhDwvYnV0dG9uPg0KICAgICAgICA8YnV0dG9uIGNsYXNzPSJjYXQiIGRhdGEtY2F0PSJfX2luZm8iIHR5cGU9ImJ1dHRvbiI+PHNwYW4gY2xhc3M9ImljbyI+4oS5PC9zcGFuPuacrOacuuS/oeaBrzwvYnV0dG9uPg0KICAgICAgICA8ZGl2IGlkPSJzaWRlLWZvb3QiPg0KICAgICAgICAgIDxidXR0b24gaWQ9ImJ0bi1zZXR0aW5ncyIgdHlwZT0iYnV0dG9uIiB0aXRsZT0i6K6+572uIj7impk8L2J1dHRvbj4NCiAgICAgICAgPC9kaXY+DQogICAgICA8L2FzaWRlPg0KDQogICAgICA8ZGl2IGlkPSJjb250ZW50LXBhbmUiPg0KICAgICAgICA8c2VjdGlvbiBpZD0ibGlzdC1wYW5lIj4NCiAgICAgICAgICA8ZGl2IGlkPSJmaWxlLXJlc3VsdHMiPg0KICAgICAgICAgICAgPGRpdiBpZD0ibGlzdCI+PC9kaXY+DQogICAgICAgICAgICA8ZGl2IGlkPSJsaXN0LWVtcHR5Ij7ovpPlhaXlhbPplK7lrZflvIDlp4vmkJzntKLvvIzmiJbpgInmi6nlt6bkvqfliIbnsbvmtY/op4g8L2Rpdj4NCiAgICAgICAgICA8L2Rpdj4NCiAgICAgICAgICA8ZGl2IGlkPSJoYW5kbGUtcGFuZWwiIGNsYXNzPSJoaWRkZW4gbm8tZHJhZyBlbWJlZGRlZCI+DQogICAgICAgICAgICA8ZGl2IGNsYXNzPSJoYW5kbGUtYmFubmVyIiBpZD0iaGFuZGxlLWJhbm5lciI+PC9kaXY+DQogICAgICAgICAgICA8ZGl2IGNsYXNzPSJoYW5kbGUtc2Nyb2xsIiBpZD0iaGFuZGxlLXNjcm9sbCI+DQogICAgICAgICAgICAgIDxkaXYgY2xhc3M9ImhhbmRsZS1oZWFkIGhhbmRsZS1jb2xzIiBpZD0iaGFuZGxlLWhlYWQiPg0KICAgICAgICAgICAgICAgIDxkaXYgY2xhc3M9ImhhbmRsZS1oY2VsbCIgZGF0YS1zb3J0PSJuYW1lIj7lkI3np7A8c3BhbiBjbGFzcz0iaC1zb3J0Ij48L3NwYW4+PC9kaXY+DQogICAgICAgICAgICAgICAgPGRpdiBjbGFzcz0iaGFuZGxlLWhjZWxsIiBkYXRhLXNvcnQ9InBpZCI+UElEPHNwYW4gY2xhc3M9Imgtc29ydCI+PC9zcGFuPjwvZGl2Pg0KICAgICAgICAgICAgICAgIDxkaXYgY2xhc3M9ImhhbmRsZS1oY2VsbCBoYW5kbGUtY29sLXBvcnQgaGlkZGVuIiBkYXRhLXNvcnQ9Imxwb3J0Ij7mnKzmnLrnq6/lj6M8c3BhbiBjbGFzcz0iaC1zb3J0Ij48L3NwYW4+PC9kaXY+DQogICAgICAgICAgICAgICAgPGRpdiBjbGFzcz0iaGFuZGxlLWhjZWxsIGhhbmRsZS1jb2wtcnBvcnQgaGlkZGVuIiBkYXRhLXNvcnQ9InJwb3J0Ij7ov5znqIvnq6/lj6M8c3BhbiBjbGFzcz0iaC1zb3J0Ij48L3NwYW4+PC9kaXY+DQogICAgICAgICAgICAgICAgPGRpdiBjbGFzcz0iaGFuZGxlLWhjZWxsIiBkYXRhLXNvcnQ9InR5cGUiPuexu+WeizxzcGFuIGNsYXNzPSJoLXNvcnQiPjwvc3Bhbj48L2Rpdj4NCiAgICAgICAgICAgICAgICA8ZGl2IGNsYXNzPSJoYW5kbGUtaGNlbGwiIGRhdGEtc29ydD0iaGFuZGxlIj7lj6Xmn4TlkI3np7A8c3BhbiBjbGFzcz0iaC1zb3J0Ij48L3NwYW4+PC9kaXY+DQogICAgICAgICAgICAgIDwvZGl2Pg0KICAgICAgICAgICAgICA8ZGl2IGNsYXNzPSJoYW5kbGUtYm9keSIgaWQ9ImhhbmRsZS1ib2R5Ij4NCiAgICAgICAgICAgICAgICA8ZGl2IGNsYXNzPSJoYW5kbGUtZW1wdHkiPui+k+WFpeWFs+mUruWtl+aQnOaWh+S7tuWPpeafhO+8m+err+WPo+ekuuS+iyA4MDgwfDgwIOaIliAwLTMwMHw1MDA8L2Rpdj4NCiAgICAgICAgICAgICAgPC9kaXY+DQogICAgICAgICAgICA8L2Rpdj4NCiAgICAgICAgICA8L2Rpdj4NCiAgICAgICAgICA8ZGl2IGlkPSJpbmZvLXBhbmVsIiBjbGFzcz0iaGlkZGVuIG5vLWRyYWcgZW1iZWRkZWQiPjwvZGl2Pg0KICAgICAgICA8L3NlY3Rpb24+DQoNCiAgICAgICAgPHNlY3Rpb24gaWQ9InByZXZpZXciPg0KICAgICAgICAgIDxkaXYgY2xhc3M9InB2LWJvZHkiIGlkPSJwdi1ib2R5Ij4NCiAgICAgICAgICAgIDxkaXYgY2xhc3M9InB2LW1lZGlhIiBpZD0icHYtbWVkaWEiPjxkaXYgY2xhc3M9InBoIj7pooTop4jljLo8L2Rpdj48L2Rpdj4NCiAgICAgICAgICAgIDxkaXYgY2xhc3M9InB2LXRleHQiIGlkPSJwdi10ZXh0IiBzdHlsZT0iZGlzcGxheTpub25lIj4NCiAgICAgICAgICAgICAgPGRpdiBjbGFzcz0iaGQiIGlkPSJwdi10ZXh0LWhkIj7pooTop4jliY0gMjBLQiDlhoXlrrk8L2Rpdj4NCiAgICAgICAgICAgICAgPHByZSBpZD0icHYtcHJlIj48L3ByZT4NCiAgICAgICAgICAgIDwvZGl2Pg0KICAgICAgICAgIDwvZGl2Pg0KICAgICAgICAgIDxkaXYgY2xhc3M9InB2LW9mZiI+5bey5YWz6Zet5paH5Lu26aKE6KeIPC9kaXY+DQogICAgICAgIDwvc2VjdGlvbj4NCiAgICAgIDwvZGl2Pg0KICAgIDwvZGl2Pg0KDQogICAgPGRpdiBpZD0iYmFyIj4NCiAgICAgIDxidXR0b24gY2xhc3M9InNvcnQiIGlkPSJidG4tc29ydCIgdHlwZT0iYnV0dG9uIiB0aXRsZT0i5YiH5o2i5o6S5bqPIj7ih4UgPHNwYW4gaWQ9InNvcnQtbGFiZWwiPuaMieS/ruaUueaXtumXtOmZjeW6jzwvc3Bhbj48L2J1dHRvbj4NCiAgICAgIDxsYWJlbCBjbGFzcz0idG9nZ2xlIiB0aXRsZT0i5byA5ZCvL+WFs+mXreWPs+S+p+mihOiniCI+DQogICAgICAgIDxpbnB1dCB0eXBlPSJjaGVja2JveCIgaWQ9ImNoay1wcmV2aWV3IiBjaGVja2VkPg0KICAgICAgICA8c3BhbiBjbGFzcz0ic3ciPjwvc3Bhbj4NCiAgICAgICAgPHNwYW4+5byA5ZCv5paH5Lu26aKE6KeIPC9zcGFuPg0KICAgICAgPC9sYWJlbD4NCiAgICAgIDxkaXYgY2xhc3M9InNwYWNlciI+PC9kaXY+DQogICAgICA8ZGl2IGlkPSJiYXItaGFuZGxlLWFjdGlvbnMiIGNsYXNzPSJuby1kcmFnIj4NCiAgICAgICAgPHNwYW4gaWQ9ImhhbmRsZS1zdGF0dXMiPjwvc3Bhbj4NCiAgICAgICAgPGJ1dHRvbiBpZD0iYnRuLXBvcnQtbWFyayIgdHlwZT0iYnV0dG9uIiB0aXRsZT0i5qCH6K6w56uv5Y+jIj7impk8L2J1dHRvbj4NCiAgICAgICAgPGRpdiBpZD0icG9ydC1tYXJrLXBvcCIgY2xhc3M9Im5vLWRyYWciPg0KICAgICAgICAgIDxkaXYgY2xhc3M9InBtcC1oZCI+5qCH6K6w56uv5Y+jPC9kaXY+DQogICAgICAgICAgPGRpdiBjbGFzcz0icG1wLWhpbnQiPuWMuemFjeeahOacrOacui/ov5znqIvnq6/lj6PkvJrpq5jkuq7mmL7npLrvvIzlj6/oh6rooYzmt7vliqA8L2Rpdj4NCiAgICAgICAgICA8ZGl2IGNsYXNzPSJwbXAtdGFncyIgaWQ9InBvcnQtbWFyay10YWdzIj48L2Rpdj4NCiAgICAgICAgICA8ZGl2IGNsYXNzPSJwbXAtYWRkIj4NCiAgICAgICAgICAgIDxpbnB1dCBpZD0icG9ydC1tYXJrLWlucHV0IiB0eXBlPSJ0ZXh0IiBpbnB1dG1vZGU9Im51bWVyaWMiIHBsYWNlaG9sZGVyPSLnq6/lj6Plj7fvvIzlpoIgOTAwMCIgYXV0b2NvbXBsZXRlPSJvZmYiIHNwZWxsY2hlY2s9ImZhbHNlIj4NCiAgICAgICAgICAgIDxidXR0b24gaWQ9InBvcnQtbWFyay1hZGQiIHR5cGU9ImJ1dHRvbiI+5re75YqgPC9idXR0b24+DQogICAgICAgICAgPC9kaXY+DQogICAgICAgICAgPGJ1dHRvbiBpZD0icG9ydC1tYXJrLXJlc2V0IiB0eXBlPSJidXR0b24iIGNsYXNzPSJwbXAtcmVzZXQiPuaBouWkjem7mOiupDwvYnV0dG9uPg0KICAgICAgICA8L2Rpdj4NCiAgICAgIDwvZGl2Pg0KICAgICAgPGRpdiBpZD0iYmFyLWluZm8tYWN0aW9ucyIgY2xhc3M9Im5vLWRyYWciPg0KICAgICAgICA8YnV0dG9uIGlkPSJidG4taW5mby1yZWZyZXNoIiB0eXBlPSJidXR0b24iPuWIt+aWsDwvYnV0dG9uPg0KICAgICAgICA8YnV0dG9uIGlkPSJidG4taW5mby1jb3B5IiB0eXBlPSJidXR0b24iPuWkjeWItjwvYnV0dG9uPg0KICAgICAgPC9kaXY+DQogICAgICA8ZGl2IGlkPSJjb3VudCI+5YWxIDAg5p2h57uT5p6cPC9kaXY+DQogICAgPC9kaXY+DQogICAgPC9kaXY+DQoNCiAgICAgICAgPGRpdiBpZD0icHJvYy1tZW51IiByb2xlPSJtZW51Ij4NCiAgICAgIDxidXR0b24gdHlwZT0iYnV0dG9uIiBkYXRhLXBhY3Q9InJldmVhbCI+PHNwYW4gY2xhc3M9ImMtaWNvIiBhcmlhLWhpZGRlbj0idHJ1ZSI+PHN2ZyB2aWV3Qm94PSIwIDAgMjQgMjQiIGZpbGw9Im5vbmUiIHN0cm9rZT0iY3VycmVudENvbG9yIiBzdHJva2Utd2lkdGg9IjEuOCI+PHBhdGggZD0iTTMgNy41QTEuNSAxLjUgMCAwIDEgNC41IDZIOWwyIDJoOC41QTEuNSAxLjUgMCAwIDEgMjEgOS41djdBMS41IDEuNSAwIDAgMSAxOS41IDE4aC0xNUExLjUgMS41IDAgMCAxIDMgMTYuNXYtOXoiLz48L3N2Zz48L3NwYW4+PHNwYW4gY2xhc3M9InBhY3QtbGFiZWwiPuaJk+W8gOi/m+eoi+aJgOWcqOS9jee9rjwvc3Bhbj48L2J1dHRvbj4NCiAgICAgIDxidXR0b24gdHlwZT0iYnV0dG9uIiBkYXRhLXBhY3Q9ImNvcHkiPjxzcGFuIGNsYXNzPSJjLWljbyIgYXJpYS1oaWRkZW49InRydWUiPjxzdmcgdmlld0JveD0iMCAwIDI0IDI0IiBmaWxsPSJub25lIiBzdHJva2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIxLjgiPjxyZWN0IHg9IjgiIHk9IjgiIHdpZHRoPSIxMSIgaGVpZ2h0PSIxMSIgcng9IjEuNSIvPjxwYXRoIGQ9Ik01IDE1VjUuNUExLjUgMS41IDAgMCAxIDYuNSA0SDE1Ii8+PC9zdmc+PC9zcGFuPjxzcGFuIGNsYXNzPSJwYWN0LWxhYmVsIiBpZD0icHJvYy1tZW51LWNvcHkiPuWkjeWItui/m+eoi+WQjTwvc3Bhbj48L2J1dHRvbj4NCiAgICAgIDxidXR0b24gdHlwZT0iYnV0dG9uIiBkYXRhLXBhY3Q9ImNvcHlQaWQiPjxzcGFuIGNsYXNzPSJjLWljbyIgYXJpYS1oaWRkZW49InRydWUiPjxzdmcgdmlld0JveD0iMCAwIDI0IDI0IiBmaWxsPSJub25lIiBzdHJva2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIxLjgiPjxwYXRoIGQ9Ik03IDdoNHY0SDd6TTEzIDdoNHY0aC00ek03IDEzaDR2NEg3ek0xMyAxM2g0djRoLTR6Ii8+PC9zdmc+PC9zcGFuPjxzcGFuIGNsYXNzPSJwYWN0LWxhYmVsIiBpZD0icHJvYy1tZW51LWNvcHlwaWQiPuWkjeWItui/m+eoi+WPtzwvc3Bhbj48L2J1dHRvbj4NCiAgICAgIDxidXR0b24gdHlwZT0iYnV0dG9uIiBkYXRhLXBhY3Q9ImVuZCIgY2xhc3M9ImRhbmdlciIgaWQ9InByb2MtbWVudS1lbmQiPjxzcGFuIGNsYXNzPSJjLWljbyIgYXJpYS1oaWRkZW49InRydWUiPjxzdmcgdmlld0JveD0iMCAwIDI0IDI0IiBmaWxsPSJub25lIiBzdHJva2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIxLjgiPjxjaXJjbGUgY3g9IjEyIiBjeT0iMTIiIHI9IjguNSIvPjxwYXRoIGQ9Ik05IDlsNiA2TTE1IDlsLTYgNiIvPjwvc3ZnPjwvc3Bhbj48c3BhbiBjbGFzcz0icGFjdC1sYWJlbCIgaWQ9InByb2MtbWVudS1lbmQtbGFiZWwiPuWFs+mXrei/m+eoizwvc3Bhbj48L2J1dHRvbj4NCiAgICA8L2Rpdj4NCiAgICA8ZGF0YWxpc3QgaWQ9ImhhbmRsZS1oaXN0LWxpc3QiPjwvZGF0YWxpc3Q+DQo8L2Rpdj4NCg0KICA8ZGl2IGlkPSJjdHgiIHJvbGU9Im1lbnUiPg0KICAgIDxidXR0b24gdHlwZT0iYnV0dG9uIiBkYXRhLWFjdD0icmV2ZWFsIj48c3BhbiBjbGFzcz0iYy1pY28iPjxzdmcgdmlld0JveD0iMCAwIDI0IDI0IiBmaWxsPSJub25lIiBzdHJva2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIxLjgiPjxwYXRoIGQ9Ik0zIDcuNUExLjUgMS41IDAgMCAxIDQuNSA2SDlsMiAyaDguNUExLjUgMS41IDAgMCAxIDIxIDkuNXY3QTEuNSAxLjUgMCAwIDEgMTkuNSAxOGgtMTVBMS41IDEuNSAwIDAgMSAzIDE2LjV2LTl6Ii8+PC9zdmc+PC9zcGFuPuaWh+S7tuWkueS4reaYvuekujwvYnV0dG9uPg0KICAgIDxidXR0b24gdHlwZT0iYnV0dG9uIiBkYXRhLWFjdD0iY29weSI+PHNwYW4gY2xhc3M9ImMtaWNvIj48c3ZnIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0cm9rZS13aWR0aD0iMS44Ij48cmVjdCB4PSI4IiB5PSI4IiB3aWR0aD0iMTEiIGhlaWdodD0iMTEiIHJ4PSIxLjUiLz48cGF0aCBkPSJNNSAxNVY1LjVBMS41IDEuNSAwIDAgMSA2LjUgNEgxNSIvPjwvc3ZnPjwvc3Bhbj7lpI3liLY8L2J1dHRvbj4NCiAgICA8YnV0dG9uIHR5cGU9ImJ1dHRvbiIgZGF0YS1hY3Q9ImNvcHlQYXRoIj48c3BhbiBjbGFzcz0iYy1pY28iPjxzdmcgdmlld0JveD0iMCAwIDI0IDI0IiBmaWxsPSJub25lIiBzdHJva2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIxLjgiPjxwYXRoIGQ9Ik04IDEyaDgiLz48cGF0aCBkPSJNMTAgN0g3LjVBMi41IDIuNSAwIDAgMCA1IDkuNXY1QTIuNSAyLjUgMCAwIDAgNy41IDE3SDEwIi8+PHBhdGggZD0iTTE0IDdoMi41QTIuNSAyLjUgMCAwIDEgMTkgOS41djVBMi41IDIuNSAwIDAgMSAxNi41IDE3SDE0Ii8+PC9zdmc+PC9zcGFuPuWkjeWItui3r+W+hDwvYnV0dG9uPg0KICAgIDxidXR0b24gdHlwZT0iYnV0dG9uIiBkYXRhLWFjdD0iY29weURpciI+PHNwYW4gY2xhc3M9ImMtaWNvIj48c3ZnIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0cm9rZS13aWR0aD0iMS44Ij48cGF0aCBkPSJNOSA4LjVhMy41IDMuNSAwIDAgMSA1LjYtMi44bDEuNyAxLjRhMy41IDMuNSAwIDAgMS0yLjIgNi4ySDEzIi8+PHBhdGggZD0iTTE1IDE1LjVhMy41IDMuNSAwIDAgMS01LjYgMi44bC0xLjctMS40YTMuNSAzLjUgMCAwIDEgMi4yLTYuMkgxMSIvPjwvc3ZnPjwvc3Bhbj7lpI3liLbmiYDlnKjot6/lvoQ8L2J1dHRvbj4NCiAgICA8YnV0dG9uIHR5cGU9ImJ1dHRvbiIgZGF0YS1hY3Q9InJlY3ljbGUiIGNsYXNzPSJkYW5nZXIiPjxzcGFuIGNsYXNzPSJjLWljbyI+PHN2ZyB2aWV3Qm94PSIwIDAgMjQgMjQiIGZpbGw9Im5vbmUiIHN0cm9rZT0iY3VycmVudENvbG9yIiBzdHJva2Utd2lkdGg9IjEuOCI+PHBhdGggZD0iTTUgOGgxNCIvPjxwYXRoIGQ9Ik05IDhWNi41QTEuNSAxLjUgMCAwIDEgMTAuNSA1aDNBMS41IDEuNSAwIDAgMSAxNSA2LjVWOCIvPjxwYXRoIGQ9Ik03LjUgOGwuNyAxMWExLjUgMS41IDAgMCAwIDEuNSAxLjRoNC42YTEuNSAxLjUgMCAwIDAgMS41LTEuNGwuNy0xMSIvPjwvc3ZnPjwvc3Bhbj7liKDpmaQo5Zue5pS256uZKTwvYnV0dG9uPg0KICA8L2Rpdj4NCjwvZGl2Pg0KPHNjcmlwdD4NCigoKSA9PiB7DQogIGNvbnN0IGJvb3QgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYm9vdCcpOw0KICBjb25zdCBjaHJvbWUgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnY2hyb21lJyk7DQogIGNvbnN0IHJpbmdGZyA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdyaW5nLWZnJyk7DQogIGNvbnN0IGJvb3RQY3QgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYm9vdC1wY3QnKTsNCiAgY29uc3QgcUVsID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3EnKTsNCiAgY29uc3QgbGlzdEVsID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2xpc3QnKTsNCiAgY29uc3QgZW1wdHlFbCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdsaXN0LWVtcHR5Jyk7DQogIGNvbnN0IGNvdW50RWwgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnY291bnQnKTsNCiAgY29uc3QgcHZNZXRhID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3B2LW1ldGEnKTsNCiAgY29uc3QgcHZNZWRpYSA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdwdi1tZWRpYScpOw0KICBjb25zdCBwdlRleHQgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgncHYtdGV4dCcpOw0KICBjb25zdCBwdkJvZHkgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgncHYtYm9keScpOw0KICBjb25zdCBwdlByZSA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdwdi1wcmUnKTsNCiAgY29uc3QgcHZUZXh0SGQgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgncHYtdGV4dC1oZCcpOw0KICBjb25zdCBwcmV2aWV3ID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3ByZXZpZXcnKTsNCiAgY29uc3QgY2hrUHJldmlldyA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjaGstcHJldmlldycpOw0KICBjb25zdCBzb3J0TGFiZWwgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc29ydC1sYWJlbCcpOw0KICBjb25zdCBDSVJDID0gMiAqIE1hdGguUEkgKiA1MjsNCg0KICBsZXQgY2F0ID0gJ2FsbCc7DQogIGxldCBhcHBNb2RlID0gJ2ZpbGUnOyAvLyBmaWxlIHwgaGFuZGxlIHwgaW5mbw0KICBjb25zdCBQTEFDRUhPTERFUl9GSUxFID0gJ+i+k+WFpeaWh+S7tuWQjSAvIOaJqeWxleWQjSAvIOi3r+W+hOWFs+mUruWtl++8m3wg6KGo56S65LiU77yMfHwg6KGo56S65oiWJzsNCiAgY29uc3QgUExBQ0VIT0xERVJfSEFORExFID0gJ+aWh+S7tuWPpeafhOWFs+mUruWtl++8jOaIluerr+WPoyA4MDgwfDgw44CBMC0zMDB8NTAwJzsNCiAgY29uc3QgUExBQ0VIT0xERVJfSU5GTyA9ICfmnKzmnLrkv6Hmga/ml6DpnIDlhbPplK7lrZfvvIzngrnlt6bkvqfljbPlj6/mn6XnnIsnOw0KICBsZXQgc29ydCA9ICdkYXRlLWRlc2MnOw0KICBsZXQgZHJpdmUgPSAnJzsgLy8gJycgPSBhbGwgZGlza3MsICdDJyAvICdEJyAvIC4uLg0KICBsZXQgaXRlbXMgPSBbXTsNCiAgbGV0IHNlbGVjdGVkID0gLTE7DQogIGxldCBwcmV2aWV3T24gPSB0cnVlOw0KICBsZXQgc2VhcmNoVGltZXIgPSAwOw0KICBsZXQgZ2VuID0gMDsNCiAgbGV0IHRvdGFsSGl0cyA9IDA7DQogIGxldCBsb2FkaW5nTW9yZSA9IGZhbHNlOw0KICBsZXQgaGFzTW9yZSA9IGZhbHNlOw0KDQogIGNvbnN0IGRyaXZlTGFiZWwgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnZHJpdmUtbGFiZWwnKTsNCiAgY29uc3QgZHJpdmVNZW51ID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2RyaXZlLW1lbnUnKTsNCiAgY29uc3QgYnRuRHJpdmUgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYnRuLWRyaXZlJyk7DQogIGNvbnN0IGRyaXZlQnRuSWNvID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2RyaXZlLWJ0bi1pY28nKTsNCiAgbGV0IGRyaXZlTWV0YSA9IHsgY29tcHV0ZXI6ICcnLCBkcml2ZXM6IFtdIH07DQoNCiAgZnVuY3Rpb24gZHJpdmVUZXh0KCkgew0KICAgIGlmICghZHJpdmUpIHJldHVybiAn5YWo55uY5pCc57SiJzsNCiAgICBjb25zdCBoaXQgPSAoZHJpdmVNZXRhLmRyaXZlcyB8fCBbXSkuZmluZChkID0+IFN0cmluZyhkLmxldHRlciB8fCAnJykudG9VcHBlckNhc2UoKSA9PT0gZHJpdmUpOw0KICAgIGlmIChoaXQgJiYgaGl0LmxhYmVsKSByZXR1cm4gaGl0LmxhYmVsOw0KICAgIHJldHVybiBkcml2ZS50b1VwcGVyQ2FzZSgpICsgJyDnm5gnOw0KICB9DQogIGZ1bmN0aW9uIHNldEJ0bkljb24odXJsKSB7DQogICAgaWYgKHVybCkgew0KICAgICAgZHJpdmVCdG5JY28uc3JjID0gdXJsICsgKHVybC5pbmNsdWRlcygnPycpID8gJyYnIDogJz8nKSArICd0PScgKyBEYXRlLm5vdygpOw0KICAgICAgZHJpdmVCdG5JY28uY2xhc3NMaXN0LnJlbW92ZSgnaGlkZGVuJyk7DQogICAgfSBlbHNlIHsNCiAgICAgIGRyaXZlQnRuSWNvLnJlbW92ZUF0dHJpYnV0ZSgnc3JjJyk7DQogICAgICBkcml2ZUJ0bkljby5jbGFzc0xpc3QuYWRkKCdoaWRkZW4nKTsNCiAgICB9DQogIH0NCiAgZnVuY3Rpb24gc3luY0RyaXZlQnV0dG9uKCkgew0KICAgIGRyaXZlTGFiZWwudGV4dENvbnRlbnQgPSBkcml2ZVRleHQoKTsNCiAgICBpZiAoIWRyaXZlKSBzZXRCdG5JY29uKGRyaXZlTWV0YS5jb21wdXRlciB8fCAnJyk7DQogICAgZWxzZSB7DQogICAgICBjb25zdCBoaXQgPSAoZHJpdmVNZXRhLmRyaXZlcyB8fCBbXSkuZmluZChkID0+IFN0cmluZyhkLmxldHRlciB8fCAnJykudG9VcHBlckNhc2UoKSA9PT0gZHJpdmUpOw0KICAgICAgc2V0QnRuSWNvbigoaGl0ICYmIGhpdC5pY29uKSB8fCBkcml2ZU1ldGEuY29tcHV0ZXIgfHwgJycpOw0KICAgIH0NCiAgfQ0KICBmdW5jdGlvbiBpY29IdG1sKHVybCkgew0KICAgIHJldHVybiB1cmwgPyAnPGltZyBzcmM9IicgKyBTdHJpbmcodXJsKS5yZXBsYWNlKC8iL2csICcnKSArICciIGFsdD0iIj4nIDogJyc7DQogIH0NCiAgZnVuY3Rpb24gcmVuZGVyRHJpdmVNZW51KCkgew0KICAgIGNvbnN0IGRyaXZlcyA9IEFycmF5LmlzQXJyYXkoZHJpdmVNZXRhLmRyaXZlcykgPyBkcml2ZU1ldGEuZHJpdmVzIDogW107DQogICAgbGV0IGh0bWwgPSAnPGJ1dHRvbiB0eXBlPSJidXR0b24iIGRhdGEtZHJpdmU9IiInICsgKCFkcml2ZSA/ICcgY2xhc3M9Im9uIicgOiAnJykgKyAnPicNCiAgICAgICsgaWNvSHRtbChkcml2ZU1ldGEuY29tcHV0ZXIpICsgJzxzcGFuPuWFqOebmOaQnOe0ojwvc3Bhbj48L2J1dHRvbj4nOw0KICAgIGZvciAoY29uc3QgZCBvZiBkcml2ZXMpIHsNCiAgICAgIGNvbnN0IGxldHRlciA9IFN0cmluZyhkLmxldHRlciB8fCBkIHx8ICcnKS5yZXBsYWNlKC86JC8sICcnKS50b1VwcGVyQ2FzZSgpOw0KICAgICAgaWYgKCFsZXR0ZXIpIGNvbnRpbnVlOw0KICAgICAgY29uc3QgbGFiZWwgPSBkLmxhYmVsIHx8IChsZXR0ZXIgKyAnIOebmCcpOw0KICAgICAgaHRtbCArPSAnPGJ1dHRvbiB0eXBlPSJidXR0b24iIGRhdGEtZHJpdmU9IicgKyBsZXR0ZXIgKyAnIicNCiAgICAgICAgKyAoZHJpdmUgPT09IGxldHRlciA/ICcgY2xhc3M9Im9uIicgOiAnJykgKyAnPicNCiAgICAgICAgKyBpY29IdG1sKGQuaWNvbiB8fCAnJykgKyAnPHNwYW4+JyArIGxhYmVsICsgJzwvc3Bhbj48L2J1dHRvbj4nOw0KICAgIH0NCiAgICBkcml2ZU1lbnUuaW5uZXJIVE1MID0gaHRtbDsNCiAgICBkcml2ZU1lbnUucXVlcnlTZWxlY3RvckFsbCgnYnV0dG9uJykuZm9yRWFjaChidG4gPT4gew0KICAgICAgYnRuLm9uY2xpY2sgPSAoZSkgPT4gew0KICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOw0KICAgICAgICBkcml2ZSA9IGJ0bi5nZXRBdHRyaWJ1dGUoJ2RhdGEtZHJpdmUnKSB8fCAnJzsNCiAgICAgICAgZHJpdmVNZW51LmNsYXNzTGlzdC5yZW1vdmUoJ29uJyk7DQogICAgICAgIHN5bmNEcml2ZUJ1dHRvbigpOw0KICAgICAgICByZW5kZXJEcml2ZU1lbnUoKTsNCiAgICAgICAgZG9TZWFyY2goKTsNCiAgICAgIH07DQogICAgfSk7DQogIH0NCiAgd2luZG93Ll9fc2V0RHJpdmVzID0gKHBheWxvYWQpID0+IHsNCiAgICB0cnkgew0KICAgICAgY29uc3QgZGF0YSA9IHR5cGVvZiBwYXlsb2FkID09PSAnc3RyaW5nJyA/IEpTT04ucGFyc2UocGF5bG9hZCkgOiBwYXlsb2FkOw0KICAgICAgaWYgKEFycmF5LmlzQXJyYXkoZGF0YSkpIHsNCiAgICAgICAgZHJpdmVNZXRhID0gew0KICAgICAgICAgIGNvbXB1dGVyOiAnJywNCiAgICAgICAgICBkcml2ZXM6IGRhdGEubWFwKHggPT4gdHlwZW9mIHggPT09ICdzdHJpbmcnDQogICAgICAgICAgICA/ICh7IGxldHRlcjogeCwgaWNvbjogJycsIGxhYmVsOiBTdHJpbmcoeCkudG9VcHBlckNhc2UoKSArICcg55uYJyB9KQ0KICAgICAgICAgICAgOiB4KQ0KICAgICAgICB9Ow0KICAgICAgfSBlbHNlIHsNCiAgICAgICAgZHJpdmVNZXRhID0gew0KICAgICAgICAgIGNvbXB1dGVyOiAoZGF0YSAmJiBkYXRhLmNvbXB1dGVyKSB8fCAnJywNCiAgICAgICAgICBkcml2ZXM6IEFycmF5LmlzQXJyYXkoZGF0YSAmJiBkYXRhLmRyaXZlcykgPyBkYXRhLmRyaXZlcyA6IFtdDQogICAgICAgIH07DQogICAgICB9DQogICAgICBzeW5jRHJpdmVCdXR0b24oKTsNCiAgICAgIHJlbmRlckRyaXZlTWVudSgpOw0KICAgIH0gY2F0Y2ggKGUpIHsgY29uc29sZS53YXJuKCdzZXREcml2ZXMnLCBlKTsgfQ0KICB9Ow0KDQogIGNvbnN0IEhJU1RfS0VZID0gJ2xvY2FsX3NlYXJjaF9oaXN0X3YxJzsNCiAgY29uc3QgSElTVF9NQVggPSAxMDsNCiAgY29uc3Qgc2VhcmNoQm94ID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NlYXJjaC1ib3gnKTsNCiAgY29uc3QgaGlzdE1lbnUgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnaGlzdC1tZW51Jyk7DQogIGNvbnN0IGJ0bkhpc3QgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYnRuLWhpc3QnKTsNCiAgY29uc3QgYnRuQ2xlYXIgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYnRuLWNsZWFyJyk7DQogIGxldCBoaXN0SWRsZVRpbWVyID0gMDsNCg0KICBmdW5jdGlvbiBzeW5jQ2xlYXJCdG4oKSB7DQogICAgYnRuQ2xlYXIuY2xhc3NMaXN0LnRvZ2dsZSgnb24nLCAhIShxRWwudmFsdWUgfHwgJycpLnRyaW0oKSk7DQogIH0NCiAgZnVuY3Rpb24gY2xlYXJTZWFyY2goKSB7DQogICAgY2xlYXJUaW1lb3V0KGhpc3RJZGxlVGltZXIpOw0KICAgIHFFbC52YWx1ZSA9ICcnOw0KICAgIHN5bmNDbGVhckJ0bigpOw0KICAgIGhpc3RNZW51LmNsYXNzTGlzdC5yZW1vdmUoJ29uJyk7DQogICAgc2VhcmNoQm94LmNsYXNzTGlzdC5yZW1vdmUoJ2hpc3Qtb3BlbicpOw0KICAgIGJ0bkhpc3QuY2xhc3NMaXN0LnJlbW92ZSgnb24nKTsNCiAgICBxRWwuZm9jdXMoKTsNCiAgICBpZiAoYXBwTW9kZSA9PT0gJ2hhbmRsZScpIHsNCiAgICAgIC8vIOa4heepuuadoeS7tuWQjuS7jeaYvuekuuWFqOmDqOi/nuaOpe+8iOS4jeaKiiAwLTY1NTM1IOWGmeWbnui+k+WFpeahhu+8iQ0KICAgICAgcmVxdWVzdEhhbmRsZVNlYXJjaCgnJyk7DQogICAgICByZXR1cm47DQogICAgfQ0KICAgIGlmIChhcHBNb2RlID09PSAnaW5mbycpIHJldHVybjsNCiAgICBkb1NlYXJjaCgpOw0KICB9DQogIGJ0bkNsZWFyLm9uY2xpY2sgPSAoZSkgPT4gew0KICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7DQogICAgY2xlYXJTZWFyY2goKTsNCiAgfTsNCg0KICBmdW5jdGlvbiBsb2FkSGlzdCgpIHsNCiAgICB0cnkgew0KICAgICAgY29uc3QgcmF3ID0gbG9jYWxTdG9yYWdlLmdldEl0ZW0oSElTVF9LRVkpOw0KICAgICAgY29uc3QgYXJyID0gcmF3ID8gSlNPTi5wYXJzZShyYXcpIDogW107DQogICAgICByZXR1cm4gQXJyYXkuaXNBcnJheShhcnIpID8gYXJyLm1hcCh4ID0+IFN0cmluZyh4IHx8ICcnKS50cmltKCkpLmZpbHRlcihCb29sZWFuKS5zbGljZSgwLCBISVNUX01BWCkgOiBbXTsNCiAgICB9IGNhdGNoIChfKSB7IHJldHVybiBbXTsgfQ0KICB9DQogIGZ1bmN0aW9uIHNhdmVIaXN0KGxpc3QpIHsNCiAgICB0cnkgeyBsb2NhbFN0b3JhZ2Uuc2V0SXRlbShISVNUX0tFWSwgSlNPTi5zdHJpbmdpZnkobGlzdC5zbGljZSgwLCBISVNUX01BWCkpKTsgfSBjYXRjaCAoXykge30NCiAgfQ0KICBmdW5jdGlvbiBwdXNoSGlzdChxKSB7DQogICAgcSA9IFN0cmluZyhxIHx8ICcnKS50cmltKCk7DQogICAgaWYgKCFxKSByZXR1cm47DQogICAgaWYgKHR5cGVvZiBhcHBNb2RlICE9PSAndW5kZWZpbmVkJyAmJiBhcHBNb2RlID09PSAnaW5mbycpIHJldHVybjsNCiAgICBpZiAodHlwZW9mIGFwcE1vZGUgIT09ICd1bmRlZmluZWQnICYmIGFwcE1vZGUgPT09ICdoYW5kbGUnKSB7DQogICAgICBpZiAodHlwZW9mIHNhdmVIYW5kbGVIaXN0ID09PSAnZnVuY3Rpb24nKSBzYXZlSGFuZGxlSGlzdChxKTsNCiAgICAgIGlmIChoaXN0TWVudS5jbGFzc0xpc3QuY29udGFpbnMoJ29uJykpIHJlbmRlckhpc3RNZW51KCk7DQogICAgICByZXR1cm47DQogICAgfQ0KICAgIGNvbnN0IGxpc3QgPSBsb2FkSGlzdCgpLmZpbHRlcih4ID0+IHggIT09IHEpOw0KICAgIGxpc3QudW5zaGlmdChxKTsNCiAgICBzYXZlSGlzdChsaXN0KTsNCiAgICBpZiAoaGlzdE1lbnUuY2xhc3NMaXN0LmNvbnRhaW5zKCdvbicpKSByZW5kZXJIaXN0TWVudSgpOw0KICB9DQogIGZ1bmN0aW9uIGVzY2FwZUF0dHIocykgew0KICAgIHJldHVybiBTdHJpbmcocyB8fCAnJykucmVwbGFjZSgvJi9nLCAnJmFtcDsnKS5yZXBsYWNlKC8iL2csICcmcXVvdDsnKS5yZXBsYWNlKC88L2csICcmbHQ7Jyk7DQogIH0NCiAgZnVuY3Rpb24gcmVuZGVySGlzdE1lbnUoKSB7DQogICAgY29uc3QgaGFuZGxlTW9kZSA9IHR5cGVvZiBhcHBNb2RlICE9PSAndW5kZWZpbmVkJyAmJiBhcHBNb2RlID09PSAnaGFuZGxlJzsNCiAgICBjb25zdCBsaXN0ID0gaGFuZGxlTW9kZSAmJiB0eXBlb2YgbG9hZEhhbmRsZUhpc3QgPT09ICdmdW5jdGlvbicgPyBsb2FkSGFuZGxlSGlzdCgpIDogbG9hZEhpc3QoKTsNCiAgICBpZiAoIWxpc3QubGVuZ3RoKSB7DQogICAgICBoaXN0TWVudS5pbm5lckhUTUwgPSAnPGRpdiBjbGFzcz0iaGlzdC1lbXB0eSI+JyArIChoYW5kbGVNb2RlID8gJ+aaguaXoOWPpeafhC/nq6/lj6PmkJzntKLorrDlvZUnIDogJ+aaguaXoOacgOi/keaQnOe0oicpICsgJzwvZGl2Pic7DQogICAgICByZXR1cm47DQogICAgfQ0KICAgIGhpc3RNZW51LmlubmVySFRNTCA9IGxpc3QubWFwKHEgPT4NCiAgICAgICc8YnV0dG9uIHR5cGU9ImJ1dHRvbiIgZGF0YS1xPSInICsgZXNjYXBlQXR0cihxKSArICciIHRpdGxlPSInICsgZXNjYXBlQXR0cihxKSArICciPicNCiAgICAgICsgZXNjYXBlQXR0cihxKSArICc8L2J1dHRvbj4nDQogICAgKS5qb2luKCcnKTsNCiAgICBoaXN0TWVudS5xdWVyeVNlbGVjdG9yQWxsKCdidXR0b24nKS5mb3JFYWNoKGJ0biA9PiB7DQogICAgICBidG4ub25jbGljayA9IChlKSA9PiB7DQogICAgICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7DQogICAgICAgIGNvbnN0IHEgPSBidG4uZ2V0QXR0cmlidXRlKCdkYXRhLXEnKSB8fCAnJzsNCiAgICAgICAgaGlzdE1lbnUuY2xhc3NMaXN0LnJlbW92ZSgnb24nKTsNCiAgICAgICAgc2VhcmNoQm94LmNsYXNzTGlzdC5yZW1vdmUoJ2hpc3Qtb3BlbicpOw0KICAgICAgICBidG5IaXN0LmNsYXNzTGlzdC5yZW1vdmUoJ29uJyk7DQogICAgICAgIHFFbC52YWx1ZSA9IHE7DQogICAgICAgIHB1c2hIaXN0KHEpOw0KICAgICAgICBzeW5jQ2xlYXJCdG4oKTsNCiAgICAgICAgZG9TZWFyY2goKTsNCiAgICAgIH07DQogICAgfSk7DQogIH0NCiAgYnRuRHJpdmUub25jbGljayA9IChlKSA9PiB7DQogICAgZS5zdG9wUHJvcGFnYXRpb24oKTsNCiAgICBjbG9zZUhpc3RNZW51KCk7DQogICAgZHJpdmVNZW51LmNsYXNzTGlzdC50b2dnbGUoJ29uJyk7DQogIH07DQogIGZ1bmN0aW9uIGNsb3NlSGlzdE1lbnUoKSB7DQogICAgaGlzdE1lbnUuY2xhc3NMaXN0LnJlbW92ZSgnb24nKTsNCiAgICBzZWFyY2hCb3guY2xhc3NMaXN0LnJlbW92ZSgnaGlzdC1vcGVuJyk7DQogICAgYnRuSGlzdC5jbGFzc0xpc3QucmVtb3ZlKCdvbicpOw0KICB9DQogIGZ1bmN0aW9uIG9wZW5IaXN0TWVudSgpIHsNCiAgICBpZiAoYXBwTW9kZSA9PT0gJ2luZm8nKSByZXR1cm47DQogICAgZHJpdmVNZW51LmNsYXNzTGlzdC5yZW1vdmUoJ29uJyk7DQogICAgcmVuZGVySGlzdE1lbnUoKTsNCiAgICBoaXN0TWVudS5jbGFzc0xpc3QuYWRkKCdvbicpOw0KICAgIHNlYXJjaEJveC5jbGFzc0xpc3QuYWRkKCdoaXN0LW9wZW4nKTsNCiAgICBidG5IaXN0LmNsYXNzTGlzdC5hZGQoJ29uJyk7DQogIH0NCiAgYnRuSGlzdC5vbmNsaWNrID0gKGUpID0+IHsNCiAgICBlLnN0b3BQcm9wYWdhdGlvbigpOw0KICAgIGlmIChoaXN0TWVudS5jbGFzc0xpc3QuY29udGFpbnMoJ29uJykpIGNsb3NlSGlzdE1lbnUoKTsNCiAgICBlbHNlIG9wZW5IaXN0TWVudSgpOw0KICB9Ow0KICBoaXN0TWVudS5hZGRFdmVudExpc3RlbmVyKCdjbGljaycsIGUgPT4gZS5zdG9wUHJvcGFnYXRpb24oKSk7DQogIGRvY3VtZW50LmFkZEV2ZW50TGlzdGVuZXIoJ2NsaWNrJywgKCkgPT4gew0KICAgIGRyaXZlTWVudS5jbGFzc0xpc3QucmVtb3ZlKCdvbicpOw0KICAgIGNsb3NlSGlzdE1lbnUoKTsNCiAgICBoaWRlQ3R4KCk7DQogIH0pOw0KICByZW5kZXJEcml2ZU1lbnUoKTsNCiAgcmVuZGVySGlzdE1lbnUoKTsNCiAgc3luY0NsZWFyQnRuKCk7DQoNCiAgLy8gUHJpbWFyeSBVSeKGkkFISyBjaGFubmVsOiBpbi1wYWdlIHF1ZXVlIGRyYWluZWQgYnkgQUhLIEV4ZWN1dGVTY3JpcHQuDQogIC8vIE5ldmVyIHVzZSBob3N0T2JqZWN0cy5zeW5jIOKAlCBpdCBkZWFkbG9ja3MgV2ViVmlldzIgYW5kIGJsb2NrcyBwb3N0TWVzc2FnZSB0b28uDQogIHdpbmRvdy5fX2Foa1EgPSB3aW5kb3cuX19haGtRIHx8IFtdOw0KICBmdW5jdGlvbiBlbnF1ZXVlKG1zZykgew0KICAgIHRyeSB7DQogICAgICB3aW5kb3cuX19haGtRLnB1c2goU3RyaW5nKG1zZykpOw0KICAgICAgLy8gVGlwIEFISyBwb2xsZXIgdmlhIHRpdGxlIGNoYW5nZSAob3B0aW9uYWwgZmFzdCBwYXRoKQ0KICAgICAgdHJ5IHsgZG9jdW1lbnQuZG9jdW1lbnRFbGVtZW50LmRhdGFzZXQuYWhrUGVuZGluZyA9IFN0cmluZyh3aW5kb3cuX19haGtRLmxlbmd0aCk7IH0gY2F0Y2ggKF8pIHt9DQogICAgfSBjYXRjaCAoZSkgeyBjb25zb2xlLndhcm4oJ2VucXVldWUnLCBlKTsgfQ0KICB9DQogIGZ1bmN0aW9uIHBvc3QobXNnKSB7DQogICAgZW5xdWV1ZShtc2cpOw0KICAgIHRyeSB7DQogICAgICBpZiAod2luZG93LmNocm9tZSAmJiBjaHJvbWUud2VidmlldyAmJiB0eXBlb2YgY2hyb21lLndlYnZpZXcucG9zdE1lc3NhZ2UgPT09ICdmdW5jdGlvbicpIHsNCiAgICAgICAgY2hyb21lLndlYnZpZXcucG9zdE1lc3NhZ2UoU3RyaW5nKG1zZykpOw0KICAgICAgICByZXR1cm4gdHJ1ZTsNCiAgICAgIH0NCiAgICB9IGNhdGNoIChlKSB7IGNvbnNvbGUud2FybigncG9zdCcsIGUpOyB9DQogICAgcmV0dXJuIGZhbHNlOw0KICB9DQogIGZ1bmN0aW9uIGNhbGxIb3N0KG1ldGhvZCwgLi4uYXJncykgew0KICAgIGxldCBtc2cgPSAnJzsNCiAgICBpZiAobWV0aG9kID09PSAnc2VhcmNoJykgew0KICAgICAgY29uc3QgW3EsIGMsIHMsIG9mZnNldF0gPSBhcmdzOw0KICAgICAgbXNnID0gJ3NlYXJjaHwnICsgSlNPTi5zdHJpbmdpZnkoew0KICAgICAgICBxOiBxIHx8ICcnLCBjYXQ6IGMgfHwgJ2FsbCcsIHNvcnQ6IHMgfHwgJ2RhdGUtZGVzYycsDQogICAgICAgIGRyaXZlOiBkcml2ZSB8fCAnJywNCiAgICAgICAgb2Zmc2V0OiBOdW1iZXIob2Zmc2V0KSB8fCAwLCBnZW46ICsrZ2VuDQogICAgICB9KTsNCiAgICB9IGVsc2UgaWYgKG1ldGhvZCA9PT0gJ3ByZXZpZXcnKSB7DQogICAgICBtc2cgPSAncHJldmlld3wnICsgKGFyZ3NbMF0gfHwgJycpOw0KICAgIH0gZWxzZSBpZiAobWV0aG9kID09PSAnb3BlbicpIHsNCiAgICAgIG1zZyA9ICdvcGVufCcgKyAoYXJnc1swXSB8fCAnJyk7DQogICAgfSBlbHNlIGlmIChtZXRob2QgPT09ICdyZXZlYWwnKSB7DQogICAgICBtc2cgPSAncmV2ZWFsfCcgKyAoYXJnc1swXSB8fCAnJyk7DQogICAgfSBlbHNlIGlmIChtZXRob2QgPT09ICdjb3B5RmlsZScpIHsNCiAgICAgIG1zZyA9ICdjb3B5RmlsZXwnICsgKGFyZ3NbMF0gfHwgJycpOw0KICAgIH0gZWxzZSBpZiAobWV0aG9kID09PSAnY29weVBhdGgnKSB7DQogICAgICBtc2cgPSAnY29weVBhdGh8JyArIChhcmdzWzBdIHx8ICcnKTsNCiAgICB9IGVsc2UgaWYgKG1ldGhvZCA9PT0gJ2NvcHlEaXInKSB7DQogICAgICBtc2cgPSAnY29weURpcnwnICsgKGFyZ3NbMF0gfHwgJycpOw0KICAgIH0gZWxzZSBpZiAobWV0aG9kID09PSAncmVjeWNsZScpIHsNCiAgICAgIG1zZyA9ICdyZWN5Y2xlfCcgKyAoYXJnc1swXSB8fCAnJyk7DQogICAgfSBlbHNlIGlmIChtZXRob2QgPT09ICdjbG9zZScgfHwgbWV0aG9kID09PSAnbWluaW1pemUnIHx8IG1ldGhvZCA9PT0gJ2RyYWcnKSB7DQogICAgICBtc2cgPSBtZXRob2Q7DQogICAgfSBlbHNlIHsNCiAgICAgIG1zZyA9IG1ldGhvZCArICd8JyArIGFyZ3MubWFwKGEgPT4gU3RyaW5nKGEgPz8gJycpKS5qb2luKCd8Jyk7DQogICAgfQ0KICAgIHBvc3QobXNnKTsNCiAgfQ0KDQogIGZ1bmN0aW9uIHNldEJvb3RQY3QocCkgew0KICAgIHAgPSBNYXRoLm1heCgwLCBNYXRoLm1pbigxMDAsIE51bWJlcihwKSB8fCAwKSk7DQogICAgYm9vdFBjdC50ZXh0Q29udGVudCA9IE1hdGgucm91bmQocCkgKyAnJSc7DQogICAgcmluZ0ZnLnN0eWxlLnN0cm9rZURhc2hhcnJheSA9IFN0cmluZyhDSVJDKTsNCiAgICByaW5nRmcuc3R5bGUuc3Ryb2tlRGFzaG9mZnNldCA9IFN0cmluZyhDSVJDICogKDEgLSBwIC8gMTAwKSk7DQogIH0NCg0KICBsZXQgYm9vdENtZFNlcSA9IDA7DQogIHdpbmRvdy5fX3NldEJvb3QgPSAob24sIHBjdCwgc2VxKSA9PiB7DQogICAgLy8g5b+955Wl5Lmx5bqP6L+f5Yiw55qEIEFISyBFeGVjdXRlU2NyaXB0QXN5bmPvvIzpgb/lhY3kuLvnlYzpnaLpl6rlm57ov5vluqbmnaENCiAgICBpZiAoc2VxICE9IG51bGwgJiYgc2VxICE9PSAnJyAmJiAhTnVtYmVyLmlzTmFOKE51bWJlcihzZXEpKSkgew0KICAgICAgc2VxID0gTnVtYmVyKHNlcSk7DQogICAgICBpZiAoc2VxIDwgYm9vdENtZFNlcSkgcmV0dXJuOw0KICAgICAgYm9vdENtZFNlcSA9IHNlcTsNCiAgICB9DQogICAgaWYgKG9uKSB7DQogICAgICBib290LmNsYXNzTGlzdC5hZGQoJ29uJyk7DQogICAgICBjaHJvbWUuY2xhc3NMaXN0LmFkZCgnaGlkZGVuJyk7DQogICAgICBzZXRCb290UGN0KHBjdCk7DQogICAgfSBlbHNlIHsNCiAgICAgIGJvb3QuY2xhc3NMaXN0LnJlbW92ZSgnb24nKTsNCiAgICAgIGNocm9tZS5jbGFzc0xpc3QucmVtb3ZlKCdoaWRkZW4nKTsNCiAgICB9DQogIH07DQogIHdpbmRvdy5fX3NldEluZGV4UHJvZ3Jlc3MgPSAocGN0KSA9PiBzZXRCb290UGN0KHBjdCk7DQoNCiAgd2luZG93Ll9fc2V0Q2F0SWNvbnMgPSAocGF5bG9hZCkgPT4gew0KICAgIHRyeSB7DQogICAgICBjb25zdCBtYXAgPSB0eXBlb2YgcGF5bG9hZCA9PT0gJ3N0cmluZycgPyBKU09OLnBhcnNlKHBheWxvYWQpIDogcGF5bG9hZDsNCiAgICAgIGlmICghbWFwIHx8IHR5cGVvZiBtYXAgIT09ICdvYmplY3QnKSByZXR1cm47DQogICAgICBkb2N1bWVudC5xdWVyeVNlbGVjdG9yQWxsKCcuY2F0JykuZm9yRWFjaChidG4gPT4gew0KICAgICAgICBjb25zdCBrZXkgPSBidG4uZ2V0QXR0cmlidXRlKCdkYXRhLWNhdCcpOw0KICAgICAgICBjb25zdCB1cmwgPSBtYXBba2V5XTsNCiAgICAgICAgaWYgKCF1cmwpIHJldHVybjsNCiAgICAgICAgbGV0IGltZyA9IGJ0bi5xdWVyeVNlbGVjdG9yKCdpbWcuaWNvJyk7DQogICAgICAgIGlmICghaW1nKSB7DQogICAgICAgICAgY29uc3Qgb2xkID0gYnRuLnF1ZXJ5U2VsZWN0b3IoJy5pY28sIFtkYXRhLWNhdC1pY29dJyk7DQogICAgICAgICAgaW1nID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnaW1nJyk7DQogICAgICAgICAgaW1nLmNsYXNzTmFtZSA9ICdpY28nOw0KICAgICAgICAgIGltZy5hbHQgPSAnJzsNCiAgICAgICAgICBpZiAob2xkKSBvbGQucmVwbGFjZVdpdGgoaW1nKTsNCiAgICAgICAgICBlbHNlIGJ0bi5pbnNlcnRCZWZvcmUoaW1nLCBidG4uZmlyc3RDaGlsZCk7DQogICAgICAgIH0NCiAgICAgICAgaW1nLnNyYyA9IHVybCArICh1cmwuaW5jbHVkZXMoJz8nKSA/ICcmJyA6ICc/JykgKyAndD0nICsgRGF0ZS5ub3coKTsNCiAgICAgIH0pOw0KICAgIH0gY2F0Y2ggKGUpIHsgY29uc29sZS53YXJuKCdzZXRDYXRJY29ucycsIGUpOyB9DQogIH07DQoNCiAgZnVuY3Rpb24gZXh0T2YobmFtZSkgew0KICAgIGNvbnN0IGkgPSBTdHJpbmcobmFtZSB8fCAnJykubGFzdEluZGV4T2YoJy4nKTsNCiAgICByZXR1cm4gaSA+IDAgPyBuYW1lLnNsaWNlKGkgKyAxKS50b0xvd2VyQ2FzZSgpIDogJyc7DQogIH0NCiAgZnVuY3Rpb24gaWNvbkh0bWwoaXQpIHsNCiAgICBpZiAoaXQuaWNvbikgew0KICAgICAgcmV0dXJuICc8aW1nIHNyYz0iJyArIGVzY2FwZUh0bWwoaXQuaWNvbikgKyAnIiBhbHQ9IiIgbG9hZGluZz0ibGF6eSIgZGVjb2Rpbmc9ImFzeW5jIiBvbmVycm9yPSJ0aGlzLm91dGVySFRNTD1cJzxzcGFuIGNsYXNzPWZpLWZhbGxiYWNrPvCfk4Q8L3NwYW4+XCciPic7DQogICAgfQ0KICAgIGlmIChpdC5pc0RpcikgcmV0dXJuICc8c3BhbiBjbGFzcz0iZmktZmFsbGJhY2siPvCfk4E8L3NwYW4+JzsNCiAgICByZXR1cm4gJzxzcGFuIGNsYXNzPSJmaS1mYWxsYmFjayI+8J+ThDwvc3Bhbj4nOw0KICB9DQogIGZ1bmN0aW9uIGhpZ2hsaWdodEh0bWwodGV4dCkgew0KICAgIGNvbnN0IHJhdyA9IFN0cmluZyh0ZXh0ID8/ICcnKTsNCiAgICBsZXQgaHRtbCA9IGVzY2FwZUh0bWwocmF3KTsNCiAgICBjb25zdCBxID0gKHFFbC52YWx1ZSB8fCAnJykudHJpbSgpOw0KICAgIGlmICghcSkgcmV0dXJuIGh0bWw7DQogICAgY29uc3QgdGVybXMgPSBxLnNwbGl0KC9cfFx8fFx8LykuZmxhdE1hcChzID0+IHMuc3BsaXQoL1xzKy8pKS5tYXAodCA9PiB0LnRyaW0oKSkuZmlsdGVyKEJvb2xlYW4pOw0KICAgIC8vIGxvbmdlciB0ZXJtcyBmaXJzdCB0byBhdm9pZCBwYXJ0aWFsIG92ZXJsYXAgaXNzdWVzDQogICAgdGVybXMuc29ydCgoYSwgYikgPT4gYi5sZW5ndGggLSBhLmxlbmd0aCk7DQogICAgZm9yIChjb25zdCB0IG9mIHRlcm1zKSB7DQogICAgICBpZiAoIXQpIGNvbnRpbnVlOw0KICAgICAgY29uc3QgcmUgPSBuZXcgUmVnRXhwKHQucmVwbGFjZSgvWy4qKz9eJHt9KCl8W1xdXFxdL2csICdcXCQmJyksICdnaScpOw0KICAgICAgaHRtbCA9IGh0bWwucmVwbGFjZShyZSwgbSA9PiAnPG1hcms+JyArIG0gKyAnPC9tYXJrPicpOw0KICAgIH0NCiAgICByZXR1cm4gaHRtbDsNCiAgfQ0KICBmdW5jdGlvbiBwcmV0dHlOYW1lKG5hbWUpIHsNCiAgICBuYW1lID0gU3RyaW5nKG5hbWUgfHwgJycpOw0KICAgIGlmICghbmFtZSkgcmV0dXJuICcnOw0KICAgIGNvbnN0IGUgPSBleHRPZihuYW1lKTsNCiAgICBpZiAoIWUgfHwgbmFtZS5zdGFydHNXaXRoKCcuJykpIHJldHVybiBoaWdobGlnaHRIdG1sKG5hbWUpOw0KICAgIGNvbnN0IGJhc2UgPSBuYW1lLnNsaWNlKDAsIC0oZS5sZW5ndGggKyAxKSk7DQogICAgcmV0dXJuIGhpZ2hsaWdodEh0bWwoYmFzZSkgKyAnPHNwYW4gY2xhc3M9ImV4dCI+LicgKyBlc2NhcGVIdG1sKGUpICsgJzwvc3Bhbj4nOw0KICB9DQogIGZ1bmN0aW9uIGRpc3BsYXlOYW1lKGl0KSB7DQogICAgbGV0IG4gPSBTdHJpbmcoaXQubmFtZSB8fCAnJykudHJpbSgpOw0KICAgIGlmIChuKSByZXR1cm4gbjsNCiAgICAvLyBmYWxsYmFjazogbGFzdCBzZWdtZW50IG9mIHBhdGgNCiAgICBjb25zdCBwID0gU3RyaW5nKGl0LnBhdGggfHwgJycpLnJlcGxhY2UoL1tcXC9dKyQvLCAnJyk7DQogICAgY29uc3QgaSA9IE1hdGgubWF4KHAubGFzdEluZGV4T2YoJ1xcJyksIHAubGFzdEluZGV4T2YoJy8nKSk7DQogICAgcmV0dXJuIGkgPj0gMCA/IHAuc2xpY2UoaSArIDEpIDogcDsNCiAgfQ0KICBmdW5jdGlvbiBlc2NhcGVIdG1sKHMpIHsNCiAgICByZXR1cm4gU3RyaW5nKHMgPz8gJycpLnJlcGxhY2UoLyYvZywnJmFtcDsnKS5yZXBsYWNlKC88L2csJyZsdDsnKS5yZXBsYWNlKC8+L2csJyZndDsnKS5yZXBsYWNlKC8iL2csJyZxdW90OycpOw0KICB9DQogIGZ1bmN0aW9uIHNob3J0UGF0aChwKSB7DQogICAgcCA9IFN0cmluZyhwIHx8ICcnKTsNCiAgICBpZiAocC5sZW5ndGggPD0gNTYpIHJldHVybiBwOw0KICAgIHJldHVybiBwLnNsaWNlKDAsIDI4KSArICcuLi4nICsgcC5zbGljZSgtMjQpOw0KICB9DQoNCiAgZnVuY3Rpb24gdXBkYXRlQ291bnQoKSB7DQogICAgaWYgKCFpdGVtcy5sZW5ndGgpIHsNCiAgICAgIGNvdW50RWwudGV4dENvbnRlbnQgPSAn5YWxIDAg5p2h57uT5p6cJzsNCiAgICAgIHJldHVybjsNCiAgICB9DQogICAgY29uc3Qgc2hvd24gPSBpdGVtcy5sZW5ndGg7DQogICAgY291bnRFbC50ZXh0Q29udGVudCA9IHRvdGFsSGl0cyA+IHNob3duDQogICAgICA/ICgn5YWxICcgKyB0b3RhbEhpdHMudG9Mb2NhbGVTdHJpbmcoKSArICcg5p2h57uT5p6c77yI5bey5Yqg6L29ICcgKyBzaG93bi50b0xvY2FsZVN0cmluZygpICsgJyDmnaHvvIknKQ0KICAgICAgOiAoJ+WFsSAnICsgTWF0aC5tYXgodG90YWxIaXRzLCBzaG93bikudG9Mb2NhbGVTdHJpbmcoKSArICcg5p2h57uT5p6cJyk7DQogIH0NCg0KICBmdW5jdGlvbiBtYWtlUm93KGl0LCBpKSB7DQogICAgY29uc3Qgcm93ID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnZGl2Jyk7DQogICAgcm93LmNsYXNzTmFtZSA9ICdyb3cnICsgKGkgPT09IHNlbGVjdGVkID8gJyBvbicgOiAnJyk7DQogICAgY29uc3QgdGl0bGUgPSBkaXNwbGF5TmFtZShpdCk7DQogICAgcm93LmlubmVySFRNTCA9IGA8ZGl2IGNsYXNzPSJmaSI+JHtpY29uSHRtbChpdCl9PC9kaXY+DQogICAgICA8ZGl2Pg0KICAgICAgICA8ZGl2IGNsYXNzPSJuYW1lIj4ke3ByZXR0eU5hbWUodGl0bGUpfTwvZGl2Pg0KICAgICAgICA8ZGl2IGNsYXNzPSJwYXRoIiB0aXRsZT0iJHtlc2NhcGVIdG1sKGl0LnBhdGgpfSI+JHtoaWdobGlnaHRIdG1sKHNob3J0UGF0aChpdC5wYXRoKSl9PC9kaXY+DQogICAgICA8L2Rpdj5gOw0KICAgIHJvdy5vbmNsaWNrID0gKCkgPT4geyBoaWRlQ3R4KCk7IHNlbGVjdFJvdyhpKTsgfTsNCiAgICByb3cub25kYmxjbGljayA9ICgpID0+IHsNCiAgICAgIGhpZGVDdHgoKTsNCiAgICAgIHB1c2hIaXN0KHFFbC52YWx1ZSB8fCAnJyk7DQogICAgICBjYWxsSG9zdCgnb3BlbicsIGl0LnBhdGgpOw0KICAgIH07DQogICAgcm93Lm9uY29udGV4dG1lbnUgPSAoZSkgPT4gew0KICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOw0KICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsNCiAgICAgIHNlbGVjdFJvdyhpKTsNCiAgICAgIHNob3dDdHgoZS5jbGllbnRYLCBlLmNsaWVudFksIGl0LnBhdGgpOw0KICAgIH07DQogICAgcmV0dXJuIHJvdzsNCiAgfQ0KDQogIGNvbnN0IGN0eEVsID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2N0eCcpOw0KICBsZXQgY3R4UGF0aCA9ICcnOw0KICBmdW5jdGlvbiBoaWRlQ3R4KCkgew0KICAgIGN0eEVsLmNsYXNzTGlzdC5yZW1vdmUoJ29uJyk7DQogICAgY3R4UGF0aCA9ICcnOw0KICB9DQogIGZ1bmN0aW9uIHNob3dDdHgoeCwgeSwgcGF0aCkgew0KICAgIGN0eFBhdGggPSBTdHJpbmcocGF0aCB8fCAnJyk7DQogICAgaWYgKCFjdHhQYXRoKSByZXR1cm47DQogICAgY3R4RWwuY2xhc3NMaXN0LmFkZCgnb24nKTsNCiAgICBjb25zdCBwYWQgPSA2Ow0KICAgIGNvbnN0IHZ3ID0gd2luZG93LmlubmVyV2lkdGg7DQogICAgY29uc3QgdmggPSB3aW5kb3cuaW5uZXJIZWlnaHQ7DQogICAgY3R4RWwuc3R5bGUubGVmdCA9ICcwcHgnOw0KICAgIGN0eEVsLnN0eWxlLnRvcCA9ICcwcHgnOw0KICAgIGNvbnN0IHJlY3QgPSBjdHhFbC5nZXRCb3VuZGluZ0NsaWVudFJlY3QoKTsNCiAgICBsZXQgbGVmdCA9IHg7DQogICAgbGV0IHRvcCA9IHk7DQogICAgaWYgKGxlZnQgKyByZWN0LndpZHRoID4gdncgLSBwYWQpIGxlZnQgPSBNYXRoLm1heChwYWQsIHZ3IC0gcmVjdC53aWR0aCAtIHBhZCk7DQogICAgaWYgKHRvcCArIHJlY3QuaGVpZ2h0ID4gdmggLSBwYWQpIHRvcCA9IE1hdGgubWF4KHBhZCwgdmggLSByZWN0LmhlaWdodCAtIHBhZCk7DQogICAgY3R4RWwuc3R5bGUubGVmdCA9IGxlZnQgKyAncHgnOw0KICAgIGN0eEVsLnN0eWxlLnRvcCA9IHRvcCArICdweCc7DQogIH0NCiAgY3R4RWwucXVlcnlTZWxlY3RvckFsbCgnYnV0dG9uW2RhdGEtYWN0XScpLmZvckVhY2goYnRuID0+IHsNCiAgICBidG4uYWRkRXZlbnRMaXN0ZW5lcignY2xpY2snLCAoZSkgPT4gew0KICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsNCiAgICAgIGNvbnN0IGFjdCA9IGJ0bi5nZXRBdHRyaWJ1dGUoJ2RhdGEtYWN0Jyk7DQogICAgICBjb25zdCBwYXRoID0gY3R4UGF0aDsNCiAgICAgIGhpZGVDdHgoKTsNCiAgICAgIGlmICghcGF0aCB8fCAhYWN0KSByZXR1cm47DQogICAgICBpZiAoYWN0ID09PSAncmV2ZWFsJykgY2FsbEhvc3QoJ3JldmVhbCcsIHBhdGgpOw0KICAgICAgZWxzZSBpZiAoYWN0ID09PSAnY29weScpIGNhbGxIb3N0KCdjb3B5RmlsZScsIHBhdGgpOw0KICAgICAgZWxzZSBpZiAoYWN0ID09PSAnY29weVBhdGgnKSBjYWxsSG9zdCgnY29weVBhdGgnLCBwYXRoKTsNCiAgICAgIGVsc2UgaWYgKGFjdCA9PT0gJ2NvcHlEaXInKSBjYWxsSG9zdCgnY29weURpcicsIHBhdGgpOw0KICAgICAgZWxzZSBpZiAoYWN0ID09PSAncmVjeWNsZScpIGNhbGxIb3N0KCdyZWN5Y2xlJywgcGF0aCk7DQogICAgfSk7DQogIH0pOw0KICBkb2N1bWVudC5hZGRFdmVudExpc3RlbmVyKCdjb250ZXh0bWVudScsIChlKSA9PiB7DQogICAgaWYgKCFlLnRhcmdldC5jbG9zZXN0KCcjbGlzdCAucm93JykgJiYgIWUudGFyZ2V0LmNsb3Nlc3QoJyNjdHgnKSkgaGlkZUN0eCgpOw0KICB9KTsNCiAgd2luZG93LmFkZEV2ZW50TGlzdGVuZXIoJ2JsdXInLCBoaWRlQ3R4KTsNCiAgd2luZG93LmFkZEV2ZW50TGlzdGVuZXIoJ3Jlc2l6ZScsIGhpZGVDdHgpOw0KICB3aW5kb3cuX19yZW1vdmVQYXRoID0gKHBhdGgpID0+IHsNCiAgICBwYXRoID0gU3RyaW5nKHBhdGggfHwgJycpOw0KICAgIGlmICghcGF0aCkgcmV0dXJuOw0KICAgIGNvbnN0IHByZXZTZWwgPSBzZWxlY3RlZCA+PSAwID8gKGl0ZW1zW3NlbGVjdGVkXSAmJiBpdGVtc1tzZWxlY3RlZF0ucGF0aCkgOiAnJzsNCiAgICBpdGVtcyA9IGl0ZW1zLmZpbHRlcihpdCA9PiBTdHJpbmcoaXQucGF0aCB8fCAnJykgIT09IHBhdGgpOw0KICAgIGlmICh0b3RhbEhpdHMgPiAwKSB0b3RhbEhpdHMgPSBNYXRoLm1heCgwLCB0b3RhbEhpdHMgLSAxKTsNCiAgICBzZWxlY3RlZCA9IC0xOw0KICAgIGlmIChwcmV2U2VsICYmIHByZXZTZWwgIT09IHBhdGgpIHsNCiAgICAgIHNlbGVjdGVkID0gaXRlbXMuZmluZEluZGV4KGl0ID0+IGl0LnBhdGggPT09IHByZXZTZWwpOw0KICAgIH0gZWxzZSBpZiAoaXRlbXMubGVuZ3RoKSB7DQogICAgICBzZWxlY3RlZCA9IE1hdGgubWluKHNlbGVjdGVkIDwgMCA/IDAgOiBzZWxlY3RlZCwgaXRlbXMubGVuZ3RoIC0gMSk7DQogICAgfQ0KICAgIHJlbmRlckxpc3QoZmFsc2UpOw0KICAgIGlmIChzZWxlY3RlZCA+PSAwICYmIHByZXZpZXdPbikgcmVxdWVzdFByZXZpZXcoaXRlbXNbc2VsZWN0ZWRdKTsNCiAgICBlbHNlIHsNCiAgICAgIHB2TWV0YS50ZXh0Q29udGVudCA9ICfpgInmi6nmlofku7bku6XpooTop4gnOw0KICAgICAgcHZNZWRpYS5pbm5lckhUTUwgPSAnPGRpdiBjbGFzcz0icGgiPumihOiniOWMujwvZGl2Pic7DQogICAgICBwdlRleHQuc3R5bGUuZGlzcGxheSA9ICdub25lJzsNCiAgICB9DQogIH07DQoNCiAgZnVuY3Rpb24gcmVuZGVyTGlzdChhcHBlbmQpIHsNCiAgICBpZiAoIWFwcGVuZCkgbGlzdEVsLmlubmVySFRNTCA9ICcnOw0KICAgIGlmICghaXRlbXMubGVuZ3RoKSB7DQogICAgICBlbXB0eUVsLmNsYXNzTGlzdC5hZGQoJ29uJyk7DQogICAgICB1cGRhdGVDb3VudCgpOw0KICAgICAgcmV0dXJuOw0KICAgIH0NCiAgICBlbXB0eUVsLmNsYXNzTGlzdC5yZW1vdmUoJ29uJyk7DQogICAgY29uc3Qgc3RhcnQgPSBhcHBlbmQgPyBsaXN0RWwucXVlcnlTZWxlY3RvckFsbCgnLnJvdycpLmxlbmd0aCA6IDA7DQogICAgY29uc3QgZnJhZyA9IGRvY3VtZW50LmNyZWF0ZURvY3VtZW50RnJhZ21lbnQoKTsNCiAgICBmb3IgKGxldCBpID0gc3RhcnQ7IGkgPCBpdGVtcy5sZW5ndGg7IGkrKykNCiAgICAgIGZyYWcuYXBwZW5kQ2hpbGQobWFrZVJvdyhpdGVtc1tpXSwgaSkpOw0KICAgIGxpc3RFbC5hcHBlbmRDaGlsZChmcmFnKTsNCiAgICB1cGRhdGVDb3VudCgpOw0KICB9DQoNCiAgZnVuY3Rpb24gc2VsZWN0Um93KGkpIHsNCiAgICBzZWxlY3RlZCA9IGk7DQogICAgbGlzdEVsLnF1ZXJ5U2VsZWN0b3JBbGwoJy5yb3cnKS5mb3JFYWNoKChlbCwgaWR4KSA9PiBlbC5jbGFzc0xpc3QudG9nZ2xlKCdvbicsIGlkeCA9PT0gaSkpOw0KICAgIGNvbnN0IGl0ID0gaXRlbXNbaV07DQogICAgaWYgKCFpdCkgcmV0dXJuOw0KICAgIGlmIChwcmV2aWV3T24pIHJlcXVlc3RQcmV2aWV3KGl0KTsNCiAgfQ0KDQogIGZ1bmN0aW9uIHJlcXVlc3RQcmV2aWV3KGl0KSB7DQogICAgcHZNZXRhLmlubmVySFRNTCA9IGA8c3Bhbj7lkI3np7AgPGI+JHtlc2NhcGVIdG1sKGl0Lm5hbWUpfTwvYj48L3NwYW4+YDsNCiAgICBpZiAocHZCb2R5KSBwdkJvZHkuY2xhc3NMaXN0LnJlbW92ZSgndGV4dC1tb2RlJyk7DQogICAgcHZNZWRpYS5pbm5lckhUTUwgPSAnPGRpdiBjbGFzcz0icGgiPuWKoOi9vemihOiniOKApjwvZGl2Pic7DQogICAgcHZUZXh0LnN0eWxlLmRpc3BsYXkgPSAnbm9uZSc7DQogICAgY2FsbEhvc3QoJ3ByZXZpZXcnLCBpdC5wYXRoKTsNCiAgfQ0KDQogIGZ1bmN0aW9uIHRyeUxvYWRNb3JlKCkgew0KICAgIGlmICghaGFzTW9yZSB8fCBsb2FkaW5nTW9yZSkgcmV0dXJuOw0KICAgIGxvYWRpbmdNb3JlID0gdHJ1ZTsNCiAgICBjYWxsSG9zdCgnc2VhcmNoJywgcUVsLnZhbHVlIHx8ICcnLCBjYXQsIHNvcnQsIGl0ZW1zLmxlbmd0aCk7DQogIH0NCg0KICBmdW5jdGlvbiBtYXliZUZpbGxWaWV3cG9ydCgpIHsNCiAgICAvLyDpppblsY/lj6rmnIkgMTUg5p2h5pe25Y+v6IO95LiN5aSf5rua5Yqo77yM6Ieq5Yqo6KGl6aG155u05Yiw5Y+v5rua5oiW5rKh5pyJ5pu05aSaDQogICAgaWYgKCFoYXNNb3JlIHx8IGxvYWRpbmdNb3JlKSByZXR1cm47DQogICAgaWYgKGxpc3RFbC5zY3JvbGxIZWlnaHQgPD0gbGlzdEVsLmNsaWVudEhlaWdodCArIDgpDQogICAgICB0cnlMb2FkTW9yZSgpOw0KICB9DQoNCiAgbGlzdEVsLmFkZEV2ZW50TGlzdGVuZXIoJ3Njcm9sbCcsICgpID0+IHsNCiAgICBpZiAobGlzdEVsLnNjcm9sbFRvcCArIGxpc3RFbC5jbGllbnRIZWlnaHQgPj0gbGlzdEVsLnNjcm9sbEhlaWdodCAtIDEyMCkNCiAgICAgIHRyeUxvYWRNb3JlKCk7DQogIH0pOw0KDQogIHdpbmRvdy5fX3VwZGF0ZVJlc3VsdHMgPSAocGF5bG9hZCkgPT4gew0KICAgIHRyeSB7DQogICAgICBjb25zdCBkYXRhID0gdHlwZW9mIHBheWxvYWQgPT09ICdzdHJpbmcnID8gSlNPTi5wYXJzZShwYXlsb2FkKSA6IHBheWxvYWQ7DQogICAgICBjb25zdCBiYXRjaCA9IEFycmF5LmlzQXJyYXkoZGF0YS5pdGVtcykgPyBkYXRhLml0ZW1zIDogW107DQogICAgICBjb25zdCB0b3RhbCA9IE51bWJlcihkYXRhLnRvdGFsICE9IG51bGwgPyBkYXRhLnRvdGFsIDogMCkgfHwgMDsNCiAgICAgIGNvbnN0IG9mZnNldCA9IE51bWJlcihkYXRhLm9mZnNldCkgfHwgMDsNCiAgICAgIGNvbnN0IGFwcGVuZCA9ICEhZGF0YS5hcHBlbmQgJiYgb2Zmc2V0ID4gMDsNCg0KICAgICAgdG90YWxIaXRzID0gKHRvdGFsID49IDAgPyB0b3RhbCA6IHRvdGFsSGl0cykgfHwgdG90YWxIaXRzOw0KICAgICAgaWYgKGFwcGVuZCkgew0KICAgICAgICBjb25zdCBzZWVuID0gbmV3IFNldChpdGVtcy5tYXAoeCA9PiB4LnBhdGgpKTsNCiAgICAgICAgZm9yIChjb25zdCBpdCBvZiBiYXRjaCkgew0KICAgICAgICAgIGlmICghc2Vlbi5oYXMoaXQucGF0aCkpIGl0ZW1zLnB1c2goaXQpOw0KICAgICAgICB9DQogICAgICAgIGxvYWRpbmdNb3JlID0gZmFsc2U7DQogICAgICAgIGhhc01vcmUgPSBiYXRjaC5sZW5ndGggPiAwICYmIGl0ZW1zLmxlbmd0aCA8IHRvdGFsSGl0czsNCiAgICAgICAgcmVuZGVyTGlzdCh0cnVlKTsNCiAgICAgIH0gZWxzZSB7DQogICAgICAgIGl0ZW1zID0gYmF0Y2g7DQogICAgICAgIGxvYWRpbmdNb3JlID0gZmFsc2U7DQogICAgICAgIGhhc01vcmUgPSBiYXRjaC5sZW5ndGggPiAwICYmIGl0ZW1zLmxlbmd0aCA8IHRvdGFsSGl0czsNCiAgICAgICAgc2VsZWN0ZWQgPSBpdGVtcy5sZW5ndGggPyAwIDogLTE7DQogICAgICAgIHJlbmRlckxpc3QoZmFsc2UpOw0KICAgICAgICBpZiAoc2VsZWN0ZWQgPj0gMCAmJiBwcmV2aWV3T24pIHJlcXVlc3RQcmV2aWV3KGl0ZW1zW3NlbGVjdGVkXSk7DQogICAgICAgIGVsc2UgaWYgKCFpdGVtcy5sZW5ndGgpIHsNCiAgICAgICAgICBpZiAocHZCb2R5KSBwdkJvZHkuY2xhc3NMaXN0LnJlbW92ZSgndGV4dC1tb2RlJyk7DQogICAgICAgICAgcHZNZXRhLnRleHRDb250ZW50ID0gJ+mAieaLqeaWh+S7tuS7pemihOiniCc7DQogICAgICAgICAgcHZNZWRpYS5pbm5lckhUTUwgPSAnPGRpdiBjbGFzcz0icGgiPumihOiniOWMujwvZGl2Pic7DQogICAgICAgICAgcHZUZXh0LnN0eWxlLmRpc3BsYXkgPSAnbm9uZSc7DQogICAgICAgIH0NCiAgICAgIH0NCiAgICAgIHVwZGF0ZUNvdW50KCk7DQogICAgICByZXF1ZXN0QW5pbWF0aW9uRnJhbWUobWF5YmVGaWxsVmlld3BvcnQpOw0KICAgIH0gY2F0Y2ggKGUpIHsNCiAgICAgIGNvbnNvbGUuZXJyb3IoZSk7DQogICAgICBsb2FkaW5nTW9yZSA9IGZhbHNlOw0KICAgICAgY291bnRFbC50ZXh0Q29udGVudCA9ICfnu5Pmnpzmm7TmlrDlpLHotKUnOw0KICAgIH0NCiAgfTsNCg0KICB3aW5kb3cuX19zZXRQcmV2aWV3ID0gKHBheWxvYWQpID0+IHsNCiAgICB0cnkgew0KICAgICAgY29uc3QgZGF0YSA9IHR5cGVvZiBwYXlsb2FkID09PSAnc3RyaW5nJyA/IEpTT04ucGFyc2UocGF5bG9hZCkgOiBwYXlsb2FkOw0KICAgICAgY29uc3Qga2luZCA9IGRhdGEua2luZCB8fCAnbm9uZSc7DQogICAgICBjb25zdCBiaXRzID0gW107DQogICAgICBjb25zdCBkcnZNYXRjaCA9IFN0cmluZyhkYXRhLnBhdGggfHwgJycpLm1hdGNoKC9eKFtBLVphLXpdKTovKTsNCiAgICAgIGlmIChkcnZNYXRjaCkgew0KICAgICAgICBjb25zdCBsZXR0ZXIgPSBkcnZNYXRjaFsxXS50b1VwcGVyQ2FzZSgpOw0KICAgICAgICBjb25zdCBoaXQgPSAoZHJpdmVNZXRhLmRyaXZlcyB8fCBbXSkuZmluZChkID0+IFN0cmluZyhkLmxldHRlciB8fCAnJykudG9VcHBlckNhc2UoKSA9PT0gbGV0dGVyKTsNCiAgICAgICAgY29uc3QgaWNvID0gKGhpdCAmJiBoaXQuaWNvbikgPyAoJzxpbWcgc3JjPSInICsgZXNjYXBlSHRtbChoaXQuaWNvbikgKyAnIiBhbHQ9IiI+JykgOiAnJzsNCiAgICAgICAgY29uc3QgbGFiZWwgPSAoaGl0ICYmIGhpdC5sYWJlbCkgPyBoaXQubGFiZWwgOiAobGV0dGVyICsgJzonKTsNCiAgICAgICAgYml0cy5wdXNoKCc8c3BhbiBjbGFzcz0iZHJ2Ij4nICsgaWNvICsgZXNjYXBlSHRtbChsYWJlbCkgKyAnPC9zcGFuPicpOw0KICAgICAgfQ0KICAgICAgaWYgKGRhdGEuZW5jb2RpbmcpIGJpdHMucHVzaCgn57yW56CBIDxiPicgKyBlc2NhcGVIdG1sKGRhdGEuZW5jb2RpbmcpICsgJzwvYj4nKTsNCiAgICAgIGlmIChkYXRhLnNpemVUZXh0KSBiaXRzLnB1c2goJ+Wkp+WwjyA8Yj4nICsgZXNjYXBlSHRtbChkYXRhLnNpemVUZXh0KSArICc8L2I+Jyk7DQogICAgICBpZiAoZGF0YS5kaW1zKSBiaXRzLnB1c2goJ+WwuuWvuCA8Yj4nICsgZXNjYXBlSHRtbChkYXRhLmRpbXMpICsgJzwvYj4nKTsNCiAgICAgIGlmIChkYXRhLm10aW1lKSBiaXRzLnB1c2goJ+S/ruaUuSA8Yj4nICsgZXNjYXBlSHRtbChkYXRhLm10aW1lKSArICc8L2I+Jyk7DQogICAgICBwdk1ldGEuaW5uZXJIVE1MID0gYml0cy5qb2luKCc8c3BhbiBzdHlsZT0ib3BhY2l0eTouMzUiPsK3PC9zcGFuPicpIHx8ICfpooTop4gnOw0KICAgICAgcHZUZXh0LnN0eWxlLmRpc3BsYXkgPSAnbm9uZSc7DQogICAgICBpZiAocHZCb2R5KSBwdkJvZHkuY2xhc3NMaXN0LnJlbW92ZSgndGV4dC1tb2RlJyk7DQoNCiAgICAgIGlmIChraW5kID09PSAnaW1hZ2UnICYmIGRhdGEudXJsKSB7DQogICAgICAgIHB2TWVkaWEuaW5uZXJIVE1MID0gJyc7DQogICAgICAgIGNvbnN0IGltZyA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2ltZycpOw0KICAgICAgICBpbWcuc3JjID0gZGF0YS51cmw7DQogICAgICAgIGltZy5hbHQgPSAnJzsNCiAgICAgICAgcHZNZWRpYS5hcHBlbmRDaGlsZChpbWcpOw0KICAgICAgfSBlbHNlIGlmIChraW5kID09PSAndmlkZW8nKSB7DQogICAgICAgIHB2TWVkaWEuaW5uZXJIVE1MID0gJyc7DQogICAgICAgIHB2TWVkaWEuc3R5bGUuZmxleERpcmVjdGlvbiA9ICdjb2x1bW4nOw0KICAgICAgICBpZiAoZGF0YS51cmwpIHsNCiAgICAgICAgICBjb25zdCB2ID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgndmlkZW8nKTsNCiAgICAgICAgICB2LmNvbnRyb2xzID0gdHJ1ZTsNCiAgICAgICAgICB2LnByZWxvYWQgPSAnbWV0YWRhdGEnOw0KICAgICAgICAgIHYuc3JjID0gZGF0YS51cmw7DQogICAgICAgICAgdi5zdHlsZS5tYXhXaWR0aCA9ICcxMDAlJzsNCiAgICAgICAgICB2LnN0eWxlLm1heEhlaWdodCA9IGRhdGEudGh1bWIgPyAnNzAlJyA6ICcxMDAlJzsNCiAgICAgICAgICB2Lm9uZXJyb3IgPSAoKSA9PiB7DQogICAgICAgICAgICBpZiAoZGF0YS50aHVtYikgew0KICAgICAgICAgICAgICB2LnJlcGxhY2VXaXRoKE9iamVjdC5hc3NpZ24oZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnaW1nJyksIHsNCiAgICAgICAgICAgICAgICBzcmM6IGRhdGEudGh1bWIsIHN0eWxlOiAnbWF4LXdpZHRoOjEwMCU7bWF4LWhlaWdodDo4MCU7b2JqZWN0LWZpdDpjb250YWluJw0KICAgICAgICAgICAgICB9KSk7DQogICAgICAgICAgICB9DQogICAgICAgICAgfTsNCiAgICAgICAgICBwdk1lZGlhLmFwcGVuZENoaWxkKHYpOw0KICAgICAgICB9IGVsc2UgaWYgKGRhdGEudGh1bWIpIHsNCiAgICAgICAgICBjb25zdCBpbWcgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdpbWcnKTsNCiAgICAgICAgICBpbWcuc3JjID0gZGF0YS50aHVtYjsNCiAgICAgICAgICBpbWcuc3R5bGUubWF4V2lkdGggPSAnMTAwJSc7DQogICAgICAgICAgaW1nLnN0eWxlLm1heEhlaWdodCA9ICc4MCUnOw0KICAgICAgICAgIGltZy5zdHlsZS5vYmplY3RGaXQgPSAnY29udGFpbic7DQogICAgICAgICAgcHZNZWRpYS5hcHBlbmRDaGlsZChpbWcpOw0KICAgICAgICB9IGVsc2Ugew0KICAgICAgICAgIHB2TWVkaWEuaW5uZXJIVE1MID0gJzxkaXYgY2xhc3M9InBoIj7ml6Dms5XpooTop4jmraTop4bpopHvvIzor7flj4zlh7vmiZPlvIA8L2Rpdj4nOw0KICAgICAgICB9DQogICAgICB9IGVsc2UgaWYgKGtpbmQgPT09ICdhdWRpbycpIHsNCiAgICAgICAgcHZNZWRpYS5pbm5lckhUTUwgPSAnJzsNCiAgICAgICAgY29uc3Qgd3JhcCA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOw0KICAgICAgICB3cmFwLmNsYXNzTmFtZSA9ICdwdi1maWxlaW5mbyc7DQogICAgICAgIHdyYXAuc3R5bGUuYmFja2dyb3VuZCA9ICcjM2Y0NDUwJzsNCiAgICAgICAgd3JhcC5zdHlsZS5jb2xvciA9ICcjZTVlN2ViJzsNCiAgICAgICAgaWYgKGRhdGEuaWNvbikgd3JhcC5pbm5lckhUTUwgPSAnPGltZyBjbGFzcz0iYmlnLWljbyIgc3JjPSInICsgZXNjYXBlSHRtbChkYXRhLmljb24pICsgJyIgYWx0PSIiPic7DQogICAgICAgIHdyYXAuaW5uZXJIVE1MICs9ICc8ZGl2IGNsYXNzPSJmbiIgc3R5bGU9ImNvbG9yOiNmZmYiPicgKyBlc2NhcGVIdG1sKGRhdGEubmFtZSB8fCAnJykgKyAnPC9kaXY+JzsNCiAgICAgICAgcHZNZWRpYS5hcHBlbmRDaGlsZCh3cmFwKTsNCiAgICAgICAgaWYgKGRhdGEudXJsKSB7DQogICAgICAgICAgY29uc3QgYSA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2F1ZGlvJyk7DQogICAgICAgICAgYS5jb250cm9scyA9IHRydWU7DQogICAgICAgICAgYS5zcmMgPSBkYXRhLnVybDsNCiAgICAgICAgICBhLnN0eWxlLndpZHRoID0gJzg2JSc7DQogICAgICAgICAgYS5zdHlsZS5tYXJnaW5Ub3AgPSAnMTJweCc7DQogICAgICAgICAgd3JhcC5hcHBlbmRDaGlsZChhKTsNCiAgICAgICAgfQ0KICAgICAgfSBlbHNlIGlmIChraW5kID09PSAncGRmJyAmJiBkYXRhLnVybCkgew0KICAgICAgICBwdk1lZGlhLmlubmVySFRNTCA9ICcnOw0KICAgICAgICBjb25zdCBlbWIgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdlbWJlZCcpOw0KICAgICAgICBlbWIuY2xhc3NOYW1lID0gJ3BkZic7DQogICAgICAgIGVtYi50eXBlID0gJ2FwcGxpY2F0aW9uL3BkZic7DQogICAgICAgIGVtYi5zcmMgPSBkYXRhLnVybDsNCiAgICAgICAgcHZNZWRpYS5hcHBlbmRDaGlsZChlbWIpOw0KICAgICAgfSBlbHNlIGlmIChraW5kID09PSAndGV4dCcpIHsNCiAgICAgICAgaWYgKHB2Qm9keSkgcHZCb2R5LmNsYXNzTGlzdC5hZGQoJ3RleHQtbW9kZScpOw0KICAgICAgICBwdk1lZGlhLmlubmVySFRNTCA9ICcnOw0KICAgICAgICBwdlRleHQuc3R5bGUuZGlzcGxheSA9ICdmbGV4JzsNCiAgICAgICAgcHZUZXh0SGQudGV4dENvbnRlbnQgPSBkYXRhLnRleHRUaXRsZSB8fCAn6aKE6KeI5YmNIDIwS0Ig5YaF5a65JzsNCiAgICAgICAgcHZQcmUudGV4dENvbnRlbnQgPSBkYXRhLnRleHQgfHwgJyc7DQogICAgICB9IGVsc2UgaWYgKGtpbmQgPT09ICdmb2xkZXInIHx8IGtpbmQgPT09ICdmaWxlaW5mbycpIHsNCiAgICAgICAgLy8gQWx3YXlzIHByZWZlciBjbGVhbiBzaGVsbCBpY29uIOKAlCBuZXZlciB1c2UgYmxhY2stbWF0dGUgdGh1bWJuYWlscyBoZXJlDQogICAgICAgIGNvbnN0IGljb1NyYyA9IGRhdGEuaWNvbiB8fCAnJzsNCiAgICAgICAgY29uc3QgaWNvID0gaWNvU3JjDQogICAgICAgICAgPyAnPGltZyBjbGFzcz0iYmlnLWljbyIgc3JjPSInICsgZXNjYXBlSHRtbChpY29TcmMpICsgJyIgYWx0PSIiPicNCiAgICAgICAgICA6ICc8ZGl2IGNsYXNzPSJiaWctaWNvIiBzdHlsZT0iZm9udC1zaXplOjM2cHg7bGluZS1oZWlnaHQ6NDhweCI+JyArIChraW5kID09PSAnZm9sZGVyJyA/ICfwn5OBJyA6ICfwn5OEJykgKyAnPC9kaXY+JzsNCiAgICAgICAgY29uc3Qgcm93cyA9IFtdOw0KICAgICAgICBpZiAoZGF0YS5zaXplVGV4dCkgcm93cy5wdXNoKFsn5aSn5bCPJywgZGF0YS5zaXplVGV4dF0pOw0KICAgICAgICBpZiAoZGF0YS5tdGltZSkgcm93cy5wdXNoKFsn5L+u5pS55pe26Ze0JywgZGF0YS5tdGltZV0pOw0KICAgICAgICBpZiAoZGF0YS5kaXIgfHwgZGF0YS5wYXRoKSByb3dzLnB1c2goWyfmiYDlnKjot6/lvoQnLCBkYXRhLmRpciB8fCBkYXRhLnBhdGhdKTsNCiAgICAgICAgY29uc3Qga3YgPSByb3dzLmxlbmd0aA0KICAgICAgICAgID8gJzxkaXYgY2xhc3M9Imt2Ij4nICsgcm93cy5tYXAoKFtrLCB2XSkgPT4NCiAgICAgICAgICAgICAgJzxkaXYgY2xhc3M9Imt2LXJvdyI+PHNwYW4gY2xhc3M9ImsiPicgKyBlc2NhcGVIdG1sKGspICsgJzwvc3Bhbj4nDQogICAgICAgICAgICAgICsgJzxzcGFuIGNsYXNzPSJ2Ij4nICsgZXNjYXBlSHRtbCh2KSArICc8L3NwYW4+PC9kaXY+Jw0KICAgICAgICAgICAgKS5qb2luKCcnKSArICc8L2Rpdj4nDQogICAgICAgICAgOiAnJzsNCiAgICAgICAgbGV0IGtpZHMgPSAnJzsNCiAgICAgICAgaWYgKEFycmF5LmlzQXJyYXkoZGF0YS5jaGlsZHJlbikgJiYgZGF0YS5jaGlsZHJlbi5sZW5ndGgpIHsNCiAgICAgICAgICBraWRzID0gJzxkaXYgY2xhc3M9ImtpZHMiPjxiPuWGheWuuemihOiniDwvYj48YnI+Jw0KICAgICAgICAgICAgKyBkYXRhLmNoaWxkcmVuLm1hcChjID0+IGVzY2FwZUh0bWwoYykpLmpvaW4oJzxicj4nKSArICc8L2Rpdj4nOw0KICAgICAgICB9DQogICAgICAgIGNvbnN0IGhpbnQgPSBkYXRhLmhpbnQNCiAgICAgICAgICA/ICc8ZGl2IGNsYXNzPSJoaW50Ij4nICsgZXNjYXBlSHRtbChkYXRhLmhpbnQpICsgJzwvZGl2PicNCiAgICAgICAgICA6ICcnOw0KICAgICAgICBwdk1lZGlhLnN0eWxlLmJhY2tncm91bmQgPSAnI2Y3ZjhmYic7DQogICAgICAgIHB2TWVkaWEuaW5uZXJIVE1MID0gJzxkaXYgY2xhc3M9InB2LWZpbGVpbmZvIj4nICsgaWNvDQogICAgICAgICAgKyAnPGRpdiBjbGFzcz0iZm4iPicgKyBlc2NhcGVIdG1sKGRhdGEubmFtZSB8fCAnJykgKyAnPC9kaXY+Jw0KICAgICAgICAgICsgaGludCArIGt2ICsga2lkcyArICc8L2Rpdj4nOw0KICAgICAgfSBlbHNlIHsNCiAgICAgICAgcHZNZWRpYS5pbm5lckhUTUwgPSAnPGRpdiBjbGFzcz0icGgiPicgKyBlc2NhcGVIdG1sKGRhdGEubWVzc2FnZSB8fCAn5peg5rOV6aKE6KeI5q2k57G75Z6LJykgKyAnPC9kaXY+JzsNCiAgICAgIH0NCiAgICB9IGNhdGNoIChlKSB7fQ0KICB9Ow0KDQogIGZ1bmN0aW9uIGRvU2VhcmNoKCkgew0KICAgIGlmICh0eXBlb2YgYXBwTW9kZSAhPT0gJ3VuZGVmaW5lZCcgJiYgYXBwTW9kZSA9PT0gJ2hhbmRsZScpIHsNCiAgICAgIHJlcXVlc3RIYW5kbGVTZWFyY2gocUVsLnZhbHVlIHx8ICcnKTsNCiAgICAgIHJldHVybjsNCiAgICB9DQogICAgaWYgKHR5cGVvZiBhcHBNb2RlICE9PSAndW5kZWZpbmVkJyAmJiBhcHBNb2RlID09PSAnaW5mbycpIHsNCiAgICAgIHJlcXVlc3RTeXNJbmZvKGZhbHNlKTsNCiAgICAgIHJldHVybjsNCiAgICB9DQogICAgY29uc3QgcSA9IHFFbC52YWx1ZSB8fCAnJzsNCiAgICBjb3VudEVsLnRleHRDb250ZW50ID0gJ+aQnOe0ouS4reKApic7DQogICAgbG9hZGluZ01vcmUgPSBmYWxzZTsNCiAgICBoYXNNb3JlID0gZmFsc2U7DQogICAgY2FsbEhvc3QoJ3NlYXJjaCcsIHEsIGNhdCwgc29ydCwgMCk7DQogIH0NCiAgZnVuY3Rpb24gc2NoZWR1bGVTZWFyY2goKSB7DQogICAgaWYgKHR5cGVvZiBhcHBNb2RlICE9PSAndW5kZWZpbmVkJyAmJiBhcHBNb2RlICE9PSAnZmlsZScpIHJldHVybjsNCiAgICBjbGVhclRpbWVvdXQoc2VhcmNoVGltZXIpOw0KICAgIHNlYXJjaFRpbWVyID0gc2V0VGltZW91dChkb1NlYXJjaCwgMTgwKTsNCiAgfQ0KDQogIGRvY3VtZW50LnF1ZXJ5U2VsZWN0b3JBbGwoJy5jYXQnKS5mb3JFYWNoKGJ0biA9PiB7DQogICAgYnRuLmFkZEV2ZW50TGlzdGVuZXIoJ2NsaWNrJywgKCkgPT4gew0KICAgICAgZG9jdW1lbnQucXVlcnlTZWxlY3RvckFsbCgnLmNhdCcpLmZvckVhY2goYiA9PiBiLmNsYXNzTGlzdC5yZW1vdmUoJ29uJykpOw0KICAgICAgYnRuLmNsYXNzTGlzdC5hZGQoJ29uJyk7DQogICAgICBjb25zdCBjID0gYnRuLmRhdGFzZXQuY2F0Ow0KICAgICAgaWYgKGMgPT09ICdfX2hhbmRsZScpIHsNCiAgICAgICAgc2V0QXBwTW9kZSgnaGFuZGxlJyk7DQogICAgICAgIHJldHVybjsNCiAgICAgIH0NCiAgICAgIGlmIChjID09PSAnX19pbmZvJykgew0KICAgICAgICBzZXRBcHBNb2RlKCdpbmZvJyk7DQogICAgICAgIHJldHVybjsNCiAgICAgIH0NCiAgICAgIGNhdCA9IGM7DQogICAgICBzZXRBcHBNb2RlKCdmaWxlJyk7DQogICAgICBkb1NlYXJjaCgpOw0KICAgIH0pOw0KICB9KTsNCiAgcUVsLmFkZEV2ZW50TGlzdGVuZXIoJ2lucHV0JywgKCkgPT4gew0KICAgIHN5bmNDbGVhckJ0bigpOw0KICAgIHNjaGVkdWxlU2VhcmNoKCk7DQogICAgY2xlYXJUaW1lb3V0KGhpc3RJZGxlVGltZXIpOw0KICAgIGhpc3RJZGxlVGltZXIgPSBzZXRUaW1lb3V0KCgpID0+IHsNCiAgICAgIGlmIChhcHBNb2RlID09PSAnaW5mbycpIHJldHVybjsNCiAgICAgIHB1c2hIaXN0KHFFbC52YWx1ZSB8fCAnJyk7DQogICAgfSwgMTIwMCk7DQogIH0pOw0KICBxRWwuYWRkRXZlbnRMaXN0ZW5lcigna2V5ZG93bicsIGUgPT4gew0KICAgIGlmIChhcHBNb2RlID09PSAnaW5mbycpIHJldHVybjsNCiAgICBpZiAoZS5rZXkgPT09ICdFbnRlcicpIHsNCiAgICAgIGNsZWFyVGltZW91dChoaXN0SWRsZVRpbWVyKTsNCiAgICAgIHB1c2hIaXN0KHFFbC52YWx1ZSB8fCAnJyk7DQogICAgICBkb1NlYXJjaCgpOw0KICAgIH0gZWxzZSBpZiAoZS5rZXkgPT09ICdFc2NhcGUnICYmIChxRWwudmFsdWUgfHwgJycpKSB7DQogICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOw0KICAgICAgY2xlYXJTZWFyY2goKTsNCiAgICB9DQogIH0pOw0KICBxRWwuYWRkRXZlbnRMaXN0ZW5lcignYmx1cicsICgpID0+IHsNCiAgICBjbGVhclRpbWVvdXQoaGlzdElkbGVUaW1lcik7DQogICAgaWYgKGFwcE1vZGUgIT09ICdpbmZvJykgcHVzaEhpc3QocUVsLnZhbHVlIHx8ICcnKTsNCiAgfSk7DQoNCiAgZnVuY3Rpb24gZm9jdXNTZWFyY2goc2VsZWN0QWxsKSB7DQogICAgdHJ5IHsNCiAgICAgIHFFbC5mb2N1cygpOw0KICAgICAgaWYgKHNlbGVjdEFsbCAhPT0gZmFsc2UpDQogICAgICAgIHFFbC5zZWxlY3QoKTsNCiAgICB9IGNhdGNoIChfKSB7fQ0KICB9DQogIHdpbmRvdy5fX2ZvY3VzU2VhcmNoID0gZm9jdXNTZWFyY2g7DQoNCiAgZnVuY3Rpb24gaXNWaWRlb0Z1bGxzY3JlZW4oKSB7DQogICAgY29uc3QgZnMgPSBkb2N1bWVudC5mdWxsc2NyZWVuRWxlbWVudCB8fCBkb2N1bWVudC53ZWJraXRGdWxsc2NyZWVuRWxlbWVudCB8fCBkb2N1bWVudC5tc0Z1bGxzY3JlZW5FbGVtZW50Ow0KICAgIGlmIChmcykgcmV0dXJuIHRydWU7DQogICAgY29uc3QgdmlkcyA9IGRvY3VtZW50LnF1ZXJ5U2VsZWN0b3JBbGwoJ3ZpZGVvJyk7DQogICAgZm9yIChjb25zdCB2IG9mIHZpZHMpIHsNCiAgICAgIGlmICh2LndlYmtpdERpc3BsYXlpbmdGdWxsc2NyZWVuIHx8IHYubW96RnVsbFNjcmVlbiB8fCB2Lm1zRnVsbHNjcmVlbkVsZW1lbnQpIHJldHVybiB0cnVlOw0KICAgIH0NCiAgICByZXR1cm4gZmFsc2U7DQogIH0NCiAgZnVuY3Rpb24gZXhpdFZpZGVvRnVsbHNjcmVlbigpIHsNCiAgICB0cnkgew0KICAgICAgaWYgKGRvY3VtZW50LmZ1bGxzY3JlZW5FbGVtZW50IHx8IGRvY3VtZW50LndlYmtpdEZ1bGxzY3JlZW5FbGVtZW50KSB7DQogICAgICAgIGNvbnN0IHAgPSBkb2N1bWVudC5leGl0RnVsbHNjcmVlbiA/IGRvY3VtZW50LmV4aXRGdWxsc2NyZWVuKCkNCiAgICAgICAgICA6IChkb2N1bWVudC53ZWJraXRFeGl0RnVsbHNjcmVlbiAmJiBkb2N1bWVudC53ZWJraXRFeGl0RnVsbHNjcmVlbigpKTsNCiAgICAgICAgcmV0dXJuIHRydWU7DQogICAgICB9DQogICAgfSBjYXRjaCAoXykge30NCiAgICBjb25zdCB2aWRzID0gZG9jdW1lbnQucXVlcnlTZWxlY3RvckFsbCgndmlkZW8nKTsNCiAgICBmb3IgKGNvbnN0IHYgb2Ygdmlkcykgew0KICAgICAgdHJ5IHsNCiAgICAgICAgaWYgKHYud2Via2l0RGlzcGxheWluZ0Z1bGxzY3JlZW4gJiYgdi53ZWJraXRFeGl0RnVsbHNjcmVlbikgew0KICAgICAgICAgIHYud2Via2l0RXhpdEZ1bGxzY3JlZW4oKTsNCiAgICAgICAgICByZXR1cm4gdHJ1ZTsNCiAgICAgICAgfQ0KICAgICAgICBpZiAodi5leGl0RnVsbHNjcmVlbikgeyB2LmV4aXRGdWxsc2NyZWVuKCk7IHJldHVybiB0cnVlOyB9DQogICAgICB9IGNhdGNoIChfKSB7fQ0KICAgIH0NCiAgICByZXR1cm4gZmFsc2U7DQogIH0NCiAgd2luZG93Ll9faGFuZGxlRXNjID0gKCkgPT4gew0KICAgIGlmIChpc1ZpZGVvRnVsbHNjcmVlbigpIHx8IGV4aXRWaWRlb0Z1bGxzY3JlZW4oKSkgew0KICAgICAgdHJ5IHsgZXhpdFZpZGVvRnVsbHNjcmVlbigpOyB9IGNhdGNoIChfKSB7fQ0KICAgICAgcG9zdCgnZXNjQ29uc3VtZWQnKTsNCiAgICAgIHJldHVybiB0cnVlOw0KICAgIH0NCiAgICBwb3N0KCdlc2NIaWRlJyk7DQogICAgcmV0dXJuIGZhbHNlOw0KICB9Ow0KICBkb2N1bWVudC5hZGRFdmVudExpc3RlbmVyKCdrZXlkb3duJywgZSA9PiB7DQogICAgaWYgKChlLmN0cmxLZXkgfHwgZS5tZXRhS2V5KSAmJiAhZS5hbHRLZXkgJiYgIWUuc2hpZnRLZXkgJiYgU3RyaW5nKGUua2V5KS50b0xvd2VyQ2FzZSgpID09PSAnZicpIHsNCiAgICAgIGUucHJldmVudERlZmF1bHQoKTsNCiAgICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7DQogICAgICBmb2N1c1NlYXJjaCgpOw0KICAgICAgcmV0dXJuOw0KICAgIH0NCiAgICBpZiAoZS5rZXkgPT09ICdFc2NhcGUnIHx8IGUua2V5ID09PSAnRXNjJykgew0KICAgICAgaWYgKGlzVmlkZW9GdWxsc2NyZWVuKCkpIHsNCiAgICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOw0KICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOw0KICAgICAgICBleGl0VmlkZW9GdWxsc2NyZWVuKCk7DQogICAgICAgIHBvc3QoJ2VzY0NvbnN1bWVkJyk7DQogICAgICB9DQogICAgfQ0KICB9LCB0cnVlKTsNCiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2J0bi1zb3J0Jykub25jbGljayA9ICgpID0+IHsNCiAgICBzb3J0ID0gc29ydCA9PT0gJ2RhdGUtZGVzYycgPyAnZGF0ZS1hc2MnIDogKHNvcnQgPT09ICdkYXRlLWFzYycgPyAnbmFtZS1hc2MnIDogKHNvcnQgPT09ICduYW1lLWFzYycgPyAnc2l6ZS1kZXNjJyA6ICdkYXRlLWRlc2MnKSk7DQogICAgY29uc3QgbWFwID0gew0KICAgICAgJ2RhdGUtZGVzYyc6ICfmjInkv67mlLnml7bpl7TpmY3luo8nLA0KICAgICAgJ2RhdGUtYXNjJzogJ+aMieS/ruaUueaXtumXtOWNh+W6jycsDQogICAgICAnbmFtZS1hc2MnOiAn5oyJ5ZCN56ew5Y2H5bqPJywNCiAgICAgICdzaXplLWRlc2MnOiAn5oyJ5aSn5bCP6ZmN5bqPJw0KICAgIH07DQogICAgc29ydExhYmVsLnRleHRDb250ZW50ID0gbWFwW3NvcnRdIHx8IHNvcnQ7DQogICAgZG9TZWFyY2goKTsNCiAgfTsNCiAgY2hrUHJldmlldy5hZGRFdmVudExpc3RlbmVyKCdjaGFuZ2UnLCAoKSA9PiB7DQogICAgcHJldmlld09uID0gISFjaGtQcmV2aWV3LmNoZWNrZWQ7DQogICAgcHJldmlldy5jbGFzc0xpc3QudG9nZ2xlKCdvZmYnLCAhcHJldmlld09uKTsNCiAgICBpZiAocHJldmlld09uICYmIHNlbGVjdGVkID49IDApIHJlcXVlc3RQcmV2aWV3KGl0ZW1zW3NlbGVjdGVkXSk7DQogIH0pOw0KICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYnRuLXNldHRpbmdzJykub25jbGljayA9ICgpID0+IHBvc3QoJ3NldHRpbmdzJyk7DQogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd0b3AnKS5hZGRFdmVudExpc3RlbmVyKCdtb3VzZWRvd24nLCBlID0+IHsNCiAgICBpZiAoZS5idXR0b24gIT09IDApIHJldHVybjsNCiAgICBpZiAoZS50YXJnZXQuY2xvc2VzdCgnLm5vLWRyYWcnKSkgcmV0dXJuOw0KICAgIGNhbGxIb3N0KCdkcmFnJyk7DQogICAgcG9zdCgnZHJhZycpOw0KICB9KTsNCg0KICAvLyDnlKggVVJMID9icD0g5bim5YWlIEFISyDlvZPliY3ov5vluqbvvJvkuIrpmZAgODjvvIzpgb/lhY3pppblsY/nm7TmjqUgMTAwJSDlho3pl6rov5vkuLvnlYzpnaINCiAgdHJ5IHsNCiAgICBjb25zdCBicCA9IE1hdGgubWF4KDgsIE1hdGgubWluKDg4LCBwYXJzZUludChuZXcgVVJMU2VhcmNoUGFyYW1zKGxvY2F0aW9uLnNlYXJjaCkuZ2V0KCdicCcpIHx8ICcyMCcsIDEwKSB8fCAyMCkpOw0KICAgIHNldEJvb3RQY3QoYnApOw0KICAgIGNvbnN0IHQxID0gZG9jdW1lbnQucXVlcnlTZWxlY3RvcignI2Jvb3QgLnQxJyk7DQogICAgaWYgKHQxICYmIGJwID49IDgwKSB0MS50ZXh0Q29udGVudCA9ICfljbPlsIblrozmiJAnOw0KICAgIGVsc2UgaWYgKHQxICYmIGJwID49IDQwKSB0MS50ZXh0Q29udGVudCA9ICfno4Hnm5jntKLlvJXkuK0nOw0KICAgIGVsc2UgaWYgKHQxKSB0MS50ZXh0Q29udGVudCA9ICfmraPlnKjliqDovb0nOw0KICB9IGNhdGNoIChlKSB7fQ0KDQogIC8vIOKUgOKUgCDlhbPogZTlj6Xmn4QgLyDmnKzmnLrkv6Hmga/vvIjltYzlhaXkuLvliJfooajljLrvvInilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIANCiAgY29uc3QgaW5mb1BhbmVsID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2luZm8tcGFuZWwnKTsNCiAgY29uc3QgaGFuZGxlUGFuZWwgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnaGFuZGxlLXBhbmVsJyk7DQogIGNvbnN0IGhhbmRsZUJvZHkgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnaGFuZGxlLWJvZHknKTsNCiAgY29uc3QgaGFuZGxlQmFubmVyID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2hhbmRsZS1iYW5uZXInKTsNCiAgY29uc3QgaGFuZGxlU3RhdHVzID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2hhbmRsZS1zdGF0dXMnKTsNCiAgY29uc3QgYnRuUG9ydE1hcmsgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYnRuLXBvcnQtbWFyaycpOw0KICBjb25zdCBwb3J0TWFya1BvcCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdwb3J0LW1hcmstcG9wJyk7DQogIGNvbnN0IHBvcnRNYXJrVGFncyA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdwb3J0LW1hcmstdGFncycpOw0KICBjb25zdCBwb3J0TWFya0lucHV0ID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3BvcnQtbWFyay1pbnB1dCcpOw0KICBjb25zdCBwcm9jTWVudSA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdwcm9jLW1lbnUnKTsNCiAgY29uc3QgZmlsZVJlc3VsdHMgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnZmlsZS1yZXN1bHRzJyk7DQogIGNvbnN0IG1haW5FbCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdtYWluJyk7DQogIGNvbnN0IGJhckVsID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2JhcicpOw0KICBjb25zdCBNQVJLRURfUE9SVF9LRVkgPSAnYWhrX21hcmtlZF9wb3J0c192MSc7DQogIGNvbnN0IERFRkFVTFRfTUFSS0VEX1BPUlRTID0gWzIxLCAyMiwgMjUsIDUzLCA4MCwgMTEwLCAxNDMsIDQ0MywgNDQ1LCAzMzA2LCAzMzg5LCA1NDMyLCA2Mzc5LCA4MDgwLCA4NDQzLCAyNzAxN107DQogIGxldCBtYXJrZWRQb3J0cyA9IGxvYWRNYXJrZWRQb3J0cygpOw0KICBmdW5jdGlvbiBsb2FkTWFya2VkUG9ydHMoKSB7DQogICAgdHJ5IHsNCiAgICAgIGNvbnN0IHJhdyA9IGxvY2FsU3RvcmFnZS5nZXRJdGVtKE1BUktFRF9QT1JUX0tFWSk7DQogICAgICBpZiAocmF3ID09IG51bGwpIHJldHVybiBERUZBVUxUX01BUktFRF9QT1JUUy5zbGljZSgpOw0KICAgICAgY29uc3QgYXJyID0gSlNPTi5wYXJzZShyYXcpOw0KICAgICAgaWYgKCFBcnJheS5pc0FycmF5KGFycikpIHJldHVybiBERUZBVUxUX01BUktFRF9QT1JUUy5zbGljZSgpOw0KICAgICAgY29uc3Qgb3V0ID0gW10sIHNlZW4gPSBuZXcgU2V0KCk7DQogICAgICBmb3IgKGNvbnN0IHggb2YgYXJyKSB7DQogICAgICAgIGNvbnN0IHAgPSBwYXJzZUludCh4LCAxMCk7DQogICAgICAgIGlmICghTnVtYmVyLmlzSW50ZWdlcihwKSB8fCBwIDwgMCB8fCBwID4gNjU1MzUgfHwgc2Vlbi5oYXMocCkpIGNvbnRpbnVlOw0KICAgICAgICBzZWVuLmFkZChwKTsgb3V0LnB1c2gocCk7DQogICAgICB9DQogICAgICByZXR1cm4gb3V0LnNvcnQoKGEsIGIpID0+IGEgLSBiKTsNCiAgICB9IGNhdGNoIChfKSB7IHJldHVybiBERUZBVUxUX01BUktFRF9QT1JUUy5zbGljZSgpOyB9DQogIH0NCiAgZnVuY3Rpb24gc2F2ZU1hcmtlZFBvcnRzKCkgew0KICAgIHRyeSB7IGxvY2FsU3RvcmFnZS5zZXRJdGVtKE1BUktFRF9QT1JUX0tFWSwgSlNPTi5zdHJpbmdpZnkobWFya2VkUG9ydHMpKTsgfSBjYXRjaCAoXykge30NCiAgfQ0KICBmdW5jdGlvbiBwb3J0SXNIb3QocG9ydCkgew0KICAgIGNvbnN0IHAgPSBOdW1iZXIocG9ydCk7DQogICAgcmV0dXJuIE51bWJlci5pc0Zpbml0ZShwKSAmJiBwID49IDAgJiYgbWFya2VkUG9ydHMuaW5jbHVkZXMocCk7DQogIH0NCiAgZnVuY3Rpb24gY2xvc2VQb3J0TWFya1BvcCgpIHsNCiAgICBpZiAocG9ydE1hcmtQb3ApIHBvcnRNYXJrUG9wLmNsYXNzTGlzdC5yZW1vdmUoJ29uJyk7DQogICAgaWYgKGJ0blBvcnRNYXJrKSBidG5Qb3J0TWFyay5jbGFzc0xpc3QucmVtb3ZlKCdvbicpOw0KICB9DQogIGZ1bmN0aW9uIHJlbmRlck1hcmtlZFBvcnRUYWdzKCkgew0KICAgIGlmICghcG9ydE1hcmtUYWdzKSByZXR1cm47DQogICAgaWYgKCFtYXJrZWRQb3J0cy5sZW5ndGgpIHsNCiAgICAgIHBvcnRNYXJrVGFncy5pbm5lckhUTUwgPSAnPGRpdiBjbGFzcz0icG1wLWVtcHR5Ij7mmoLml6DmoIforrDnq6/lj6M8L2Rpdj4nOw0KICAgICAgcmV0dXJuOw0KICAgIH0NCiAgICBwb3J0TWFya1RhZ3MuaW5uZXJIVE1MID0gbWFya2VkUG9ydHMubWFwKHAgPT4NCiAgICAgICc8c3BhbiBjbGFzcz0icG1wLXRhZyIgZGF0YS1wb3J0PSInICsgcCArICciPicgKyBwDQogICAgICArICc8YnV0dG9uIHR5cGU9ImJ1dHRvbiIgdGl0bGU9Iuenu+mZpCIgZGF0YS1ybT0iJyArIHAgKyAnIj7DlzwvYnV0dG9uPjwvc3Bhbj4nDQogICAgKS5qb2luKCcnKTsNCiAgICBwb3J0TWFya1RhZ3MucXVlcnlTZWxlY3RvckFsbCgnYnV0dG9uW2RhdGEtcm1dJykuZm9yRWFjaChidG4gPT4gew0KICAgICAgYnRuLm9uY2xpY2sgPSAoZSkgPT4gew0KICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOw0KICAgICAgICBjb25zdCBwID0gTnVtYmVyKGJ0bi5nZXRBdHRyaWJ1dGUoJ2RhdGEtcm0nKSk7DQogICAgICAgIG1hcmtlZFBvcnRzID0gbWFya2VkUG9ydHMuZmlsdGVyKHggPT4geCAhPT0gcCk7DQogICAgICAgIHNhdmVNYXJrZWRQb3J0cygpOw0KICAgICAgICByZW5kZXJNYXJrZWRQb3J0VGFncygpOw0KICAgICAgICBpZiAoYXBwTW9kZSA9PT0gJ2hhbmRsZScgJiYgaGFuZGxlTW9kZSA9PT0gJ3BvcnQnKSByZW5kZXJIYW5kbGVUYWJsZSgpOw0KICAgICAgfTsNCiAgICB9KTsNCiAgfQ0KICBmdW5jdGlvbiBhZGRNYXJrZWRQb3J0KHJhdykgew0KICAgIGNvbnN0IHBhcnRzID0gU3RyaW5nKHJhdyB8fCAnJykuc3BsaXQoL1ssfO+8jFxzXSsvKS5tYXAocyA9PiBzLnRyaW0oKSkuZmlsdGVyKEJvb2xlYW4pOw0KICAgIGxldCBjaGFuZ2VkID0gZmFsc2U7DQogICAgZm9yIChjb25zdCBwYXJ0IG9mIHBhcnRzKSB7DQogICAgICBjb25zdCBwID0gcGFyc2VJbnQocGFydCwgMTApOw0KICAgICAgaWYgKCFOdW1iZXIuaXNJbnRlZ2VyKHApIHx8IHAgPCAwIHx8IHAgPiA2NTUzNSkgY29udGludWU7DQogICAgICBpZiAobWFya2VkUG9ydHMuaW5jbHVkZXMocCkpIGNvbnRpbnVlOw0KICAgICAgbWFya2VkUG9ydHMucHVzaChwKTsNCiAgICAgIGNoYW5nZWQgPSB0cnVlOw0KICAgIH0NCiAgICBpZiAoIWNoYW5nZWQpIHJldHVybiBmYWxzZTsNCiAgICBtYXJrZWRQb3J0cy5zb3J0KChhLCBiKSA9PiBhIC0gYik7DQogICAgc2F2ZU1hcmtlZFBvcnRzKCk7DQogICAgcmVuZGVyTWFya2VkUG9ydFRhZ3MoKTsNCiAgICBpZiAoYXBwTW9kZSA9PT0gJ2hhbmRsZScgJiYgaGFuZGxlTW9kZSA9PT0gJ3BvcnQnKSByZW5kZXJIYW5kbGVUYWJsZSgpOw0KICAgIHJldHVybiB0cnVlOw0KICB9DQogIGZ1bmN0aW9uIG9wZW5Qb3J0TWFya1BvcCgpIHsNCiAgICByZW5kZXJNYXJrZWRQb3J0VGFncygpOw0KICAgIGlmIChwb3J0TWFya1BvcCkgcG9ydE1hcmtQb3AuY2xhc3NMaXN0LmFkZCgnb24nKTsNCiAgICBpZiAoYnRuUG9ydE1hcmspIGJ0blBvcnRNYXJrLmNsYXNzTGlzdC5hZGQoJ29uJyk7DQogICAgdHJ5IHsgcG9ydE1hcmtJbnB1dCAmJiBwb3J0TWFya0lucHV0LmZvY3VzKCk7IH0gY2F0Y2ggKF8pIHt9DQogIH0NCiAgbGV0IGhhbmRsZUl0ZW1zID0gW107DQogIGxldCBoYW5kbGVRdWVyeSA9ICcnOw0KICBsZXQgaGFuZGxlQnVzeSA9IGZhbHNlOw0KICBsZXQgaW5mb0RhdGEgPSBudWxsOw0KICBsZXQgaW5mb1RleHQgPSAnJzsNCiAgbGV0IGluZm9SZXFHZW4gPSAwOw0KICBsZXQgaW5mb0xvYWRUaW1lciA9IDA7DQogIGxldCBtb25pdG9yVGFiID0gJ2ZpbGUnOw0KICBsZXQgaGFuZGxlTW9kZSA9ICdoYW5kbGUnOw0KICBsZXQgaGFuZGxlU29ydEtleSA9ICdscG9ydCc7DQogIGxldCBoYW5kbGVTb3J0RGlyID0gMTsgLy8gMT3ljYfluo8gLTE96ZmN5bqPDQogIGNvbnN0IERFRkFVTFRfUE9SVF9RVUVSWSA9ICcwLTY1NTM1JzsNCiAgY29uc3QgaGFuZGxlSGVhZCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdoYW5kbGUtaGVhZCcpOw0KICBsZXQgcHJvY01lbnVUYXJnZXRzID0gW107DQogIGxldCBoYW5kbGVTZWxLZXlzID0gbmV3IFNldCgpOw0KICBsZXQgaGFuZGxlQW5jaG9yS2V5ID0gJyc7DQogIC8vIOaXp+i/m+eoi+ebkeaOpyBVSSDlt7Lnp7vpmaTvvJrljaDkvY3pgb/lhY3mrovnlZnku6PnoIHmiqXplJkNCiAgY29uc3QgcHJvY0hlYWQgPSBudWxsOw0KICBjb25zdCBwcm9jQm9keSA9IG51bGw7DQogIGNvbnN0IHByb2NTY3JvbGwgPSBudWxsOw0KICBjb25zdCBwcm9jQ3B1VG90YWwgPSBudWxsOw0KICBjb25zdCBwcm9jTWVtVG90YWwgPSBudWxsOw0KICBsZXQgcHJvY0l0ZW1zID0gW107DQogIGxldCBwcm9jU2hvd1N5cyA9IGZhbHNlOw0KICBsZXQgcHJvY1NlbEtleXMgPSBuZXcgU2V0KCk7DQogIGxldCBwcm9jU2VsS2V5ID0gJyc7DQogIGxldCBwcm9jU2VsUGlkID0gMDsNCiAgbGV0IHByb2NBbmNob3JLZXkgPSAnJzsNCiAgbGV0IHByb2NTb3J0S2V5ID0gJ25hbWUnOw0KICBsZXQgcHJvY1NvcnREaXIgPSAxOw0KICBjb25zdCBwcm9jUm93TWFwID0gbmV3IE1hcCgpOw0KICBjb25zdCBwcm9jSWNvblN0YWJsZSA9IG5ldyBNYXAoKTsNCg0KICBmdW5jdGlvbiBzZXRBcHBNb2RlKG1vZGUpIHsNCiAgICBpZiAobW9kZSAhPT0gJ2hhbmRsZScgJiYgbW9kZSAhPT0gJ2luZm8nKSBtb2RlID0gJ2ZpbGUnOw0KICAgIGFwcE1vZGUgPSBtb2RlOw0KICAgIG1vbml0b3JUYWIgPSBtb2RlID09PSAnZmlsZScgPyAnZmlsZScgOiBtb2RlOw0KICAgIGNvbnN0IGlzRmlsZSA9IG1vZGUgPT09ICdmaWxlJzsNCiAgICBjb25zdCBpc0hhbmRsZSA9IG1vZGUgPT09ICdoYW5kbGUnOw0KICAgIGNvbnN0IGlzSW5mbyA9IG1vZGUgPT09ICdpbmZvJzsNCiAgICBjb25zdCB0b3BFbCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd0b3AnKTsNCiAgICBpZiAobWFpbkVsKSB7DQogICAgICBtYWluRWwuY2xhc3NMaXN0LnRvZ2dsZSgnbW9kZS10b29sJywgIWlzRmlsZSk7DQogICAgICBtYWluRWwuY2xhc3NMaXN0LnRvZ2dsZSgnbW9kZS1oYW5kbGUnLCBpc0hhbmRsZSk7DQogICAgICBtYWluRWwuY2xhc3NMaXN0LnRvZ2dsZSgnbW9kZS1pbmZvJywgaXNJbmZvKTsNCiAgICB9DQogICAgaWYgKGJhckVsKSB7DQogICAgICBiYXJFbC5jbGFzc0xpc3QudG9nZ2xlKCdtb2RlLXRvb2wnLCAhaXNGaWxlKTsNCiAgICAgIGJhckVsLmNsYXNzTGlzdC50b2dnbGUoJ21vZGUtaW5mbycsIGlzSW5mbyk7DQogICAgICBiYXJFbC5jbGFzc0xpc3QudG9nZ2xlKCdtb2RlLWhhbmRsZScsIGlzSGFuZGxlKTsNCiAgICB9DQogICAgaWYgKHRvcEVsKSB7DQogICAgICB0b3BFbC5jbGFzc0xpc3QudG9nZ2xlKCdtb2RlLXRvb2wnLCAhaXNGaWxlKTsNCiAgICAgIHRvcEVsLmNsYXNzTGlzdC50b2dnbGUoJ21vZGUtaGFuZGxlJywgaXNIYW5kbGUpOw0KICAgICAgdG9wRWwuY2xhc3NMaXN0LnRvZ2dsZSgnbW9kZS1pbmZvJywgaXNJbmZvKTsNCiAgICB9DQogICAgaWYgKGZpbGVSZXN1bHRzKSBmaWxlUmVzdWx0cy5jbGFzc0xpc3QudG9nZ2xlKCdoaWRkZW4nLCAhaXNGaWxlKTsNCiAgICBpZiAoaGFuZGxlUGFuZWwpIGhhbmRsZVBhbmVsLmNsYXNzTGlzdC50b2dnbGUoJ2hpZGRlbicsICFpc0hhbmRsZSk7DQogICAgaWYgKGluZm9QYW5lbCkgaW5mb1BhbmVsLmNsYXNzTGlzdC50b2dnbGUoJ2hpZGRlbicsICFpc0luZm8pOw0KICAgIHFFbC5yZWFkT25seSA9IGlzSW5mbzsNCiAgICBjbG9zZUhpc3RNZW51KCk7DQogICAgY2xvc2VQb3J0TWFya1BvcCgpOw0KICAgIHBvc3QoJ3Byb2NWaWV3fDAnKTsNCiAgICBpZiAoaXNIYW5kbGUpIHsNCiAgICAgIHFFbC5wbGFjZWhvbGRlciA9IFBMQUNFSE9MREVSX0hBTkRMRTsNCiAgICAgIGhhbmRsZVNvcnRLZXkgPSAnbHBvcnQnOw0KICAgICAgaGFuZGxlU29ydERpciA9IDE7DQogICAgICAvLyDov5vlhaXljbPmmL7npLrlhajpg6jov57mjqXvvJvmkJzntKLmoYbkv53mjIHnqbrnmb3vvIzpgb/lhY0gMC02NTUzNSDooqvluKblm57mnKzlnLDmkJzntKINCiAgICAgIHFFbC52YWx1ZSA9ICcnOw0KICAgICAgc3luY0NsZWFyQnRuKCk7DQogICAgICByZXF1ZXN0SGFuZGxlU2VhcmNoKCcnKTsNCiAgICAgIHRyeSB7IHFFbC5mb2N1cygpOyB9IGNhdGNoIChfKSB7fQ0KICAgIH0gZWxzZSBpZiAoaXNJbmZvKSB7DQogICAgICBxRWwucGxhY2Vob2xkZXIgPSBQTEFDRUhPTERFUl9JTkZPOw0KICAgICAgY291bnRFbC50ZXh0Q29udGVudCA9ICfmnKzmnLrkv6Hmga8nOw0KICAgICAgcmVxdWVzdFN5c0luZm8oZmFsc2UpOw0KICAgIH0gZWxzZSB7DQogICAgICBxRWwucGxhY2Vob2xkZXIgPSBQTEFDRUhPTERFUl9GSUxFOw0KICAgICAgLy8g6Iul5qGG6YeM6L+Y5piv5YWo56uv5Y+j5p2h5Lu277yM5riF5o6J77yM6YG/5YWN5bim6L+b5pys5Zyw5paH5Lu25pCc57SiDQogICAgICBpZiAoaXNBbGxQb3J0c1F1ZXJ5VGV4dChxRWwudmFsdWUpKSB7DQogICAgICAgIHFFbC52YWx1ZSA9ICcnOw0KICAgICAgICBzeW5jQ2xlYXJCdG4oKTsNCiAgICAgIH0NCiAgICAgIHRyeSB7IHFFbC5mb2N1cygpOyB9IGNhdGNoIChfKSB7fQ0KICAgIH0NCiAgfQ0KICBmdW5jdGlvbiBzZXRBcHBWaWV3KG5hbWUpIHsNCiAgICAvLyDlhbzlrrnml6flhaXlj6PvvJrliIfliLDkvqfmoI/lr7nlupTpobkNCiAgICBpZiAobmFtZSA9PT0gJ2hhbmRsZScgfHwgbmFtZSA9PT0gJ3Byb2MnKSB7DQogICAgICBkb2N1bWVudC5xdWVyeVNlbGVjdG9yQWxsKCcuY2F0JykuZm9yRWFjaChiID0+IGIuY2xhc3NMaXN0LnRvZ2dsZSgnb24nLCBiLmRhdGFzZXQuY2F0ID09PSAnX19oYW5kbGUnKSk7DQogICAgICBzZXRBcHBNb2RlKCdoYW5kbGUnKTsNCiAgICAgIHJldHVybjsNCiAgICB9DQogICAgaWYgKG5hbWUgPT09ICdpbmZvJykgew0KICAgICAgZG9jdW1lbnQucXVlcnlTZWxlY3RvckFsbCgnLmNhdCcpLmZvckVhY2goYiA9PiBiLmNsYXNzTGlzdC50b2dnbGUoJ29uJywgYi5kYXRhc2V0LmNhdCA9PT0gJ19faW5mbycpKTsNCiAgICAgIHNldEFwcE1vZGUoJ2luZm8nKTsNCiAgICAgIHJldHVybjsNCiAgICB9DQogICAgZG9jdW1lbnQucXVlcnlTZWxlY3RvckFsbCgnLmNhdCcpLmZvckVhY2goYiA9PiBiLmNsYXNzTGlzdC50b2dnbGUoJ29uJywgYi5kYXRhc2V0LmNhdCA9PT0gY2F0KSk7DQogICAgc2V0QXBwTW9kZSgnZmlsZScpOw0KICB9DQogIGZ1bmN0aW9uIHN5bmNQcm9jTW9uaXRvckxpdmUoKSB7IHBvc3QoJ3Byb2NWaWV3fDAnKTsgfQ0KICBmdW5jdGlvbiByZXF1ZXN0UHJvY0xpc3QoKSB7IC8qIOW3suenu+mZpOmHjeWei+i/m+eoi+ebkeaOpyAqLyB9DQogIGZ1bmN0aW9uIGNsZWFySW5mb0xvYWRXYWl0KCkgew0KICAgIGlmIChpbmZvTG9hZFRpbWVyKSB7DQogICAgICBjbGVhclRpbWVvdXQoaW5mb0xvYWRUaW1lcik7DQogICAgICBpbmZvTG9hZFRpbWVyID0gMDsNCiAgICB9DQogIH0NCiAgZnVuY3Rpb24gc2hvd0luZm9Mb2FkaW5nKCkgew0KICAgIGlmICghaW5mb1BhbmVsIHx8IGFwcE1vZGUgIT09ICdpbmZvJykgcmV0dXJuOw0KICAgIGluZm9QYW5lbC5pbm5lckhUTUwgPSAnPGRpdiBjbGFzcz0iaW5mby1sb2FkaW5nIj48ZGl2IGNsYXNzPSJpbmZvLXNwaW5uZXIiIGFyaWEtaGlkZGVuPSJ0cnVlIj48L2Rpdj48ZGl2Puato+WcqOivu+WPluacrOacuuS/oeaBr+KApjwvZGl2PjwvZGl2Pic7DQogICAgaWYgKGNvdW50RWwpIGNvdW50RWwudGV4dENvbnRlbnQgPSAn5Yqg6L295Lit4oCmJzsNCiAgfQ0KICBmdW5jdGlvbiByZXF1ZXN0U3lzSW5mbyhmb3JjZSkgew0KICAgIGZvcmNlID0gISFmb3JjZTsNCiAgICBjb25zdCBteUdlbiA9ICsraW5mb1JlcUdlbjsNCiAgICBjbGVhckluZm9Mb2FkV2FpdCgpOw0KICAgIC8vIOe8k+WtmOWRveS4remAmuW4uOW+iOW/q++8m+i2hei/h+e6piAwLjRzIOWGjeWHuuWKoOi9veWKqOeUu++8jOmBv+WFjemXquS4gOS4iw0KICAgIGlmIChmb3JjZSB8fCAhaW5mb0RhdGEpIHsNCiAgICAgIGluZm9Mb2FkVGltZXIgPSBzZXRUaW1lb3V0KCgpID0+IHsNCiAgICAgICAgaW5mb0xvYWRUaW1lciA9IDA7DQogICAgICAgIGlmIChteUdlbiAhPT0gaW5mb1JlcUdlbiB8fCBhcHBNb2RlICE9PSAnaW5mbycpIHJldHVybjsNCiAgICAgICAgc2hvd0luZm9Mb2FkaW5nKCk7DQogICAgICB9LCA0MDApOw0KICAgIH0NCiAgICBwb3N0KCdzeXNJbmZvfCcgKyAoZm9yY2UgPyAnMScgOiAnMCcpKTsNCiAgfQ0KICBjb25zdCBIQU5ETEVfSElTVF9LRVkgPSAnYWhrX2hhbmRsZV9zZWFyY2hfaGlzdF92MSc7DQogIGNvbnN0IEhBTkRMRV9ISVNUX01BWCA9IDEwOw0KICBjb25zdCBoYW5kbGVIaXN0TGlzdCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdoYW5kbGUtaGlzdC1saXN0Jyk7DQogIGZ1bmN0aW9uIGxvYWRIYW5kbGVIaXN0KCkgew0KICAgIHRyeSB7DQogICAgICBjb25zdCByYXcgPSBsb2NhbFN0b3JhZ2UuZ2V0SXRlbShIQU5ETEVfSElTVF9LRVkpOw0KICAgICAgY29uc3QgYXJyID0gcmF3ID8gSlNPTi5wYXJzZShyYXcpIDogW107DQogICAgICByZXR1cm4gQXJyYXkuaXNBcnJheShhcnIpID8gYXJyLmZpbHRlcih4ID0+IFN0cmluZyh4IHx8ICcnKS50cmltKCkpIDogW107DQogICAgfSBjYXRjaCAoXykgeyByZXR1cm4gW107IH0NCiAgfQ0KICBmdW5jdGlvbiBzYXZlSGFuZGxlSGlzdChxKSB7DQogICAgcSA9IFN0cmluZyhxIHx8ICcnKS50cmltKCk7DQogICAgaWYgKCFxKSByZXR1cm47DQogICAgbGV0IGFyciA9IGxvYWRIYW5kbGVIaXN0KCkuZmlsdGVyKHggPT4geCAhPT0gcSk7DQogICAgYXJyLnVuc2hpZnQocSk7DQogICAgaWYgKGFyci5sZW5ndGggPiBIQU5ETEVfSElTVF9NQVgpIGFyciA9IGFyci5zbGljZSgwLCBIQU5ETEVfSElTVF9NQVgpOw0KICAgIHRyeSB7IGxvY2FsU3RvcmFnZS5zZXRJdGVtKEhBTkRMRV9ISVNUX0tFWSwgSlNPTi5zdHJpbmdpZnkoYXJyKSk7IH0gY2F0Y2ggKF8pIHt9DQogICAgcmVuZGVySGFuZGxlSGlzdCgpOw0KICB9DQogIGZ1bmN0aW9uIHJlbmRlckhhbmRsZUhpc3QoKSB7DQogICAgaWYgKCFoYW5kbGVIaXN0TGlzdCkgcmV0dXJuOw0KICAgIGhhbmRsZUhpc3RMaXN0LmlubmVySFRNTCA9IGxvYWRIYW5kbGVIaXN0KCkubWFwKHEgPT4NCiAgICAgICc8b3B0aW9uIHZhbHVlPSInICsgZXNjYXBlSHRtbChxKSArICciPjwvb3B0aW9uPicNCiAgICApLmpvaW4oJycpOw0KICB9DQogIGZ1bmN0aW9uIG5vcm1hbGl6ZVBvcnRRdWVyeShxKSB7DQogICAgcSA9IFN0cmluZyhxIHx8ICcnKS50cmltKCk7DQogICAgY29uc3QgbSA9IHEubWF0Y2goL15cL+err+WPo1xzKiguKikkL2kpIHx8IHEubWF0Y2goL15cL3BvcnRccyooLiopJC9pKTsNCiAgICBpZiAobSkgcSA9IFN0cmluZyhtWzFdIHx8ICcnKS50cmltKCk7DQogICAgcmV0dXJuIHE7DQogIH0NCiAgZnVuY3Rpb24gaXNQb3J0U2VhcmNoUXVlcnkocSkgew0KICAgIHEgPSBub3JtYWxpemVQb3J0UXVlcnkocSk7DQogICAgcmV0dXJuICEhcSAmJiAvXltcZFxzfFwtXSskLy50ZXN0KHEpICYmIC9cZC8udGVzdChxKTsNCiAgfQ0KICBmdW5jdGlvbiBwYXJzZVBvcnRMaXN0KHEpIHsNCiAgICBxID0gbm9ybWFsaXplUG9ydFF1ZXJ5KHEpOw0KICAgIGNvbnN0IG91dCA9IFtdLCBzZWVuID0gbmV3IFNldCgpOw0KICAgIGNvbnN0IGFkZCA9IChwKSA9PiB7DQogICAgICBwID0gTnVtYmVyKHApOw0KICAgICAgaWYgKCFOdW1iZXIuaXNJbnRlZ2VyKHApIHx8IHAgPCAwIHx8IHAgPiA2NTUzNSB8fCBzZWVuLmhhcyhwKSkgcmV0dXJuOw0KICAgICAgc2Vlbi5hZGQocCk7DQogICAgICBvdXQucHVzaChwKTsNCiAgICB9Ow0KICAgIGZvciAoY29uc3QgcGFydCBvZiBTdHJpbmcocSkuc3BsaXQoJ3wnKSkgew0KICAgICAgY29uc3QgcyA9IFN0cmluZyhwYXJ0IHx8ICcnKS50cmltKCk7DQogICAgICBpZiAoIXMpIGNvbnRpbnVlOw0KICAgICAgY29uc3QgbSA9IHMubWF0Y2goL14oXGQrKVxzKi1ccyooXGQrKSQvKTsNCiAgICAgIGlmIChtKSB7DQogICAgICAgIGxldCBhID0gcGFyc2VJbnQobVsxXSwgMTApLCBiID0gcGFyc2VJbnQobVsyXSwgMTApOw0KICAgICAgICBpZiAoYSA+IGIpIHsgY29uc3QgdCA9IGE7IGEgPSBiOyBiID0gdDsgfQ0KICAgICAgICBhID0gTWF0aC5tYXgoMCwgTWF0aC5taW4oNjU1MzUsIGEpKTsNCiAgICAgICAgYiA9IE1hdGgubWF4KDAsIE1hdGgubWluKDY1NTM1LCBiKSk7DQogICAgICAgIGZvciAobGV0IHAgPSBhOyBwIDw9IGI7IHArKykgYWRkKHApOw0KICAgICAgfSBlbHNlIGlmICgvXlxkKyQvLnRlc3QocykpIHsNCiAgICAgICAgYWRkKHBhcnNlSW50KHMsIDEwKSk7DQogICAgICB9DQogICAgfQ0KICAgIHJldHVybiBvdXQ7DQogIH0NCiAgZnVuY3Rpb24gaXNBbGxQb3J0c1F1ZXJ5VGV4dChxKSB7DQogICAgcSA9IFN0cmluZyhxIHx8ICcnKS50cmltKCk7DQogICAgcmV0dXJuICFxIHx8IHEgPT09IERFRkFVTFRfUE9SVF9RVUVSWSB8fCAvXjBccyotXHMqNjU1MzUkLy50ZXN0KHEpOw0KICB9DQogIGZ1bmN0aW9uIHJlcXVlc3RIYW5kbGVTZWFyY2gocSkgew0KICAgIHEgPSBTdHJpbmcocSB8fCAnJykudHJpbSgpOw0KICAgIC8vIOepuuahhiAvIOWFqOerr+WPoyDihpIg55u05o6l5pi+56S65YWo6YOo6L+e5o6l77yM5LiN5oqK5p2h5Lu25YaZ6L+b6L6T5YWl5qGGDQogICAgaWYgKGlzQWxsUG9ydHNRdWVyeVRleHQocSkpIHsNCiAgICAgIGhhbmRsZVF1ZXJ5ID0gREVGQVVMVF9QT1JUX1FVRVJZOw0KICAgICAgaGFuZGxlTW9kZSA9ICdwb3J0JzsNCiAgICAgIGhhbmRsZUJ1c3kgPSB0cnVlOw0KICAgICAgaWYgKGhhbmRsZVN0YXR1cykgaGFuZGxlU3RhdHVzLnRleHRDb250ZW50ID0gJ+ato+WcqOafpeivouKApic7DQogICAgICBoYW5kbGVCYW5uZXIuY2xhc3NMaXN0LmFkZCgnb24nKTsNCiAgICAgIGhhbmRsZUJhbm5lci50ZXh0Q29udGVudCA9ICflhajpg6jov57mjqUnOw0KICAgICAgaGFuZGxlU2VsS2V5cy5jbGVhcigpOw0KICAgICAgaGFuZGxlQW5jaG9yS2V5ID0gJyc7DQogICAgICBzeW5jSGFuZGxlQmFyKDApOw0KICAgICAgc2hvd0hhbmRsZUxvYWRpbmcoJ+ato+WcqOafpeivouerr+WPo+WNoOeUqO+8jOivt+eojeWAmeKApicpOw0KICAgICAgcG9zdCgnaGFuZGxlU2VhcmNofCcgKyBERUZBVUxUX1BPUlRfUVVFUlkpOw0KICAgICAgcmV0dXJuOw0KICAgIH0NCiAgICBoYW5kbGVRdWVyeSA9IHE7DQogICAgaGFuZGxlTW9kZSA9IGlzUG9ydFNlYXJjaFF1ZXJ5KHEpID8gJ3BvcnQnIDogJ2hhbmRsZSc7DQogICAgaWYgKGhhbmRsZU1vZGUgPT09ICdwb3J0JyAmJiAhcGFyc2VQb3J0TGlzdChxKS5sZW5ndGgpIHsNCiAgICAgIGhhbmRsZUl0ZW1zID0gW107DQogICAgICByZW5kZXJIYW5kbGVUYWJsZSgn56uv5Y+j5peg5pWI77yM56S65L6L77yaODA4MHw4MCDmiJYgMC0zMDB8NTAwJyk7DQogICAgICByZXR1cm47DQogICAgfQ0KICAgIHNhdmVIYW5kbGVIaXN0KHEpOw0KICAgIGhhbmRsZUJ1c3kgPSB0cnVlOw0KICAgIGlmIChoYW5kbGVTdGF0dXMpIGhhbmRsZVN0YXR1cy50ZXh0Q29udGVudCA9ICfmraPlnKjmn6Xor6LigKYnOw0KICAgIGhhbmRsZUJhbm5lci5jbGFzc0xpc3QuYWRkKCdvbicpOw0KICAgIGhhbmRsZUJhbm5lci50ZXh0Q29udGVudCA9ICfigJwnICsgcSArICfigJ3nmoTmkJzntKLnu5PmnpwnOw0KICAgIGhhbmRsZVNlbEtleXMuY2xlYXIoKTsNCiAgICBoYW5kbGVBbmNob3JLZXkgPSAnJzsNCiAgICBzeW5jSGFuZGxlQmFyKDApOw0KICAgIHNob3dIYW5kbGVMb2FkaW5nKGhhbmRsZU1vZGUgPT09ICdwb3J0JyA/ICfmraPlnKjmn6Xor6Lnq6/lj6PljaDnlKjvvIzor7fnqI3lgJnigKYnIDogJ+ato+WcqOafpeivouWPpeafhO+8jOivt+eojeWAmeKApicpOw0KICAgIHBvc3QoJ2hhbmRsZVNlYXJjaHwnICsgcSk7DQogIH0NCiAgZnVuY3Rpb24gc2hvd0hhbmRsZUxvYWRpbmcobXNnKSB7DQogICAgaGFuZGxlQm9keS5pbm5lckhUTUwgPSAnPGRpdiBjbGFzcz0iaGFuZGxlLWxvYWRpbmciPjxkaXYgY2xhc3M9ImhhbmRsZS1zcGlubmVyIiBhcmlhLWhpZGRlbj0idHJ1ZSI+PC9kaXY+PGRpdj4nDQogICAgICArIGVzY2FwZUh0bWwobXNnIHx8ICfmraPlnKjmn6Xor6Llj6Xmn4TvvIzor7fnqI3lgJnigKYnKSArICc8L2Rpdj48L2Rpdj4nOw0KICB9DQogIGZ1bmN0aW9uIHNvcnRIYW5kbGVJdGVtcyhpdGVtcykgew0KICAgIGNvbnN0IGtleSA9IGhhbmRsZVNvcnRLZXkgfHwgKGhhbmRsZU1vZGUgPT09ICdwb3J0JyA/ICdscG9ydCcgOiAnbmFtZScpOw0KICAgIGNvbnN0IGRpciA9IGhhbmRsZVNvcnREaXIgfHwgMTsNCiAgICByZXR1cm4gKGl0ZW1zIHx8IFtdKS5zbGljZSgpLnNvcnQoKGEsIGIpID0+IHsNCiAgICAgIGxldCBjbXAgPSAwOw0KICAgICAgaWYgKGtleSA9PT0gJ3BpZCcpIHsNCiAgICAgICAgY21wID0gKE51bWJlcihhLnBpZCkgfHwgMCkgLSAoTnVtYmVyKGIucGlkKSB8fCAwKTsNCiAgICAgIH0gZWxzZSBpZiAoa2V5ID09PSAnbHBvcnQnKSB7DQogICAgICAgIGNtcCA9IChOdW1iZXIoYS5sb2NhbFBvcnQpIHx8IDApIC0gKE51bWJlcihiLmxvY2FsUG9ydCkgfHwgMCk7DQogICAgICB9IGVsc2UgaWYgKGtleSA9PT0gJ3Jwb3J0Jykgew0KICAgICAgICBjbXAgPSAoTnVtYmVyKGEucmVtb3RlUG9ydCkgfHwgMCkgLSAoTnVtYmVyKGIucmVtb3RlUG9ydCkgfHwgMCk7DQogICAgICB9IGVsc2UgaWYgKGtleSA9PT0gJ3R5cGUnKSB7DQogICAgICAgIGNtcCA9IFN0cmluZyhhLnR5cGUgfHwgJycpLmxvY2FsZUNvbXBhcmUoU3RyaW5nKGIudHlwZSB8fCAnJyksICdlbicsIHsgc2Vuc2l0aXZpdHk6ICdiYXNlJyB9KTsNCiAgICAgIH0gZWxzZSBpZiAoa2V5ID09PSAnaGFuZGxlJykgew0KICAgICAgICBjbXAgPSBTdHJpbmcoYS5oYW5kbGUgfHwgJycpLmxvY2FsZUNvbXBhcmUoU3RyaW5nKGIuaGFuZGxlIHx8ICcnKSwgJ3poLUNOJyk7DQogICAgICB9IGVsc2Ugew0KICAgICAgICBjbXAgPSBjb21wYXJlUHJvY05hbWUoYS5uYW1lIHx8ICcnLCBiLm5hbWUgfHwgJycpOw0KICAgICAgfQ0KICAgICAgaWYgKGNtcCkgcmV0dXJuIGNtcCAqIGRpcjsNCiAgICAgIC8vIOasoeimgemUru+8muerr+WPo+aooeW8j+S8mOWFiOacrOacuuerr+WPo++8jOWGjSBQSUQgLyDlkI3np7ANCiAgICAgIGNvbnN0IGxwID0gKE51bWJlcihhLmxvY2FsUG9ydCkgfHwgMCkgLSAoTnVtYmVyKGIubG9jYWxQb3J0KSB8fCAwKTsNCiAgICAgIGlmIChscCkgcmV0dXJuIGxwOw0KICAgICAgY29uc3QgcGEgPSAoTnVtYmVyKGEucGlkKSB8fCAwKSAtIChOdW1iZXIoYi5waWQpIHx8IDApOw0KICAgICAgaWYgKHBhKSByZXR1cm4gcGE7DQogICAgICByZXR1cm4gY29tcGFyZVByb2NOYW1lKGEubmFtZSB8fCAnJywgYi5uYW1lIHx8ICcnKTsNCiAgICB9KTsNCiAgfQ0KICBmdW5jdGlvbiBzeW5jSGFuZGxlSGVhZFNvcnQoKSB7DQogICAgaWYgKCFoYW5kbGVIZWFkKSByZXR1cm47DQogICAgaGFuZGxlSGVhZC5xdWVyeVNlbGVjdG9yQWxsKCcuaGFuZGxlLWhjZWxsW2RhdGEtc29ydF0nKS5mb3JFYWNoKGNlbGwgPT4gew0KICAgICAgY29uc3QgayA9IGNlbGwuZ2V0QXR0cmlidXRlKCdkYXRhLXNvcnQnKTsNCiAgICAgIGNvbnN0IG9uID0gayA9PT0gaGFuZGxlU29ydEtleTsNCiAgICAgIGNlbGwuY2xhc3NMaXN0LnRvZ2dsZSgnc29ydGVkJywgb24pOw0KICAgICAgY2VsbC5jbGFzc0xpc3QudG9nZ2xlKCdhc2MnLCBvbiAmJiBoYW5kbGVTb3J0RGlyID4gMCk7DQogICAgICBjZWxsLmNsYXNzTGlzdC50b2dnbGUoJ2Rlc2MnLCBvbiAmJiBoYW5kbGVTb3J0RGlyIDwgMCk7DQogICAgfSk7DQogIH0NCiAgZnVuY3Rpb24gYmluZEhhbmRsZUhlYWRTb3J0KCkgew0KICAgIGlmICghaGFuZGxlSGVhZCB8fCBoYW5kbGVIZWFkLmRhdGFzZXQuc29ydEJvdW5kID09PSAnMScpIHJldHVybjsNCiAgICBoYW5kbGVIZWFkLmRhdGFzZXQuc29ydEJvdW5kID0gJzEnOw0KICAgIGhhbmRsZUhlYWQucXVlcnlTZWxlY3RvckFsbCgnLmhhbmRsZS1oY2VsbFtkYXRhLXNvcnRdJykuZm9yRWFjaChjZWxsID0+IHsNCiAgICAgIGNlbGwuYWRkRXZlbnRMaXN0ZW5lcignY2xpY2snLCAoZSkgPT4gew0KICAgICAgICBlLnByZXZlbnREZWZhdWx0KCk7DQogICAgICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7DQogICAgICAgIGNvbnN0IGsgPSBjZWxsLmdldEF0dHJpYnV0ZSgnZGF0YS1zb3J0Jyk7DQogICAgICAgIGlmICghaykgcmV0dXJuOw0KICAgICAgICBpZiAoaGFuZGxlU29ydEtleSA9PT0gaykgaGFuZGxlU29ydERpciA9IC1oYW5kbGVTb3J0RGlyOw0KICAgICAgICBlbHNlIHsNCiAgICAgICAgICBoYW5kbGVTb3J0S2V5ID0gazsNCiAgICAgICAgICBoYW5kbGVTb3J0RGlyID0gKGsgPT09ICdscG9ydCcgfHwgayA9PT0gJ3Jwb3J0JyB8fCBrID09PSAncGlkJykgPyAxIDogMTsNCiAgICAgICAgfQ0KICAgICAgICBpZiAoaGFuZGxlSXRlbXMubGVuZ3RoKSByZW5kZXJIYW5kbGVUYWJsZSgpOw0KICAgICAgICBlbHNlIHN5bmNIYW5kbGVIZWFkU29ydCgpOw0KICAgICAgfSk7DQogICAgfSk7DQogIH0NCiAgYmluZEhhbmRsZUhlYWRTb3J0KCk7DQogIGZ1bmN0aW9uIHBvcnRUaXBUZXh0KGl0KSB7DQogICAgY29uc3QgbGlwID0gU3RyaW5nKGl0LmxvY2FsSXAgfHwgJzAuMC4wLjAnKTsNCiAgICBjb25zdCBscG9ydCA9IChpdC5sb2NhbFBvcnQgPT0gbnVsbCB8fCBOdW1iZXIoaXQubG9jYWxQb3J0KSA8IDApID8gJycgOiBTdHJpbmcoaXQubG9jYWxQb3J0KTsNCiAgICBjb25zdCByaXAgPSBTdHJpbmcoaXQucmVtb3RlSXAgfHwgJzAuMC4wLjAnKTsNCiAgICBjb25zdCBycG9ydCA9IChpdC5yZW1vdGVQb3J0ID09IG51bGwgfHwgTnVtYmVyKGl0LnJlbW90ZVBvcnQpIDwgMCkgPyAnJyA6IFN0cmluZyhpdC5yZW1vdGVQb3J0KTsNCiAgICByZXR1cm4gJ+acrOacuu+8micgKyBsaXAgKyAnOicgKyBscG9ydCArICdcbui/nOeoi++8micgKyByaXAgKyAnOicgKyBycG9ydDsNCiAgfQ0KICBmdW5jdGlvbiBzZXRIYW5kbGVQb3J0TW9kZShvbikgew0KICAgIGRvY3VtZW50LnF1ZXJ5U2VsZWN0b3JBbGwoJy5oYW5kbGUtY29scycpLmZvckVhY2goZWwgPT4gZWwuY2xhc3NMaXN0LnRvZ2dsZSgncG9ydC1tb2RlJywgISFvbikpOw0KICAgIGRvY3VtZW50LnF1ZXJ5U2VsZWN0b3JBbGwoJy5oYW5kbGUtY29sLXBvcnQsLmhhbmRsZS1jb2wtcnBvcnQnKS5mb3JFYWNoKGVsID0+IGVsLmNsYXNzTGlzdC50b2dnbGUoJ2hpZGRlbicsICFvbikpOw0KICB9DQogIGZ1bmN0aW9uIGRlZHVwZVBvcnRJdGVtcyhpdGVtcykgew0KICAgIGNvbnN0IG91dCA9IFtdLCBzZWVuID0gbmV3IFNldCgpOw0KICAgIGZvciAoY29uc3QgaXQgb2YgaXRlbXMgfHwgW10pIHsNCiAgICAgIGNvbnN0IGtleSA9IFsNCiAgICAgICAgTnVtYmVyKGl0LnBpZCkgfHwgMCwNCiAgICAgICAgU3RyaW5nKGl0LnR5cGUgfHwgJycpLnRvVXBwZXJDYXNlKCksDQogICAgICAgIE51bWJlcihpdC5sb2NhbFBvcnQpIHx8IDAsDQogICAgICAgIE51bWJlcihpdC5yZW1vdGVQb3J0KSB8fCAwLA0KICAgICAgICBTdHJpbmcoaXQuaGFuZGxlIHx8ICcnKQ0KICAgICAgXS5qb2luKCd8Jyk7DQogICAgICBpZiAoc2Vlbi5oYXMoa2V5KSkgY29udGludWU7DQogICAgICBzZWVuLmFkZChrZXkpOw0KICAgICAgb3V0LnB1c2goaXQpOw0KICAgIH0NCiAgICByZXR1cm4gb3V0Ow0KICB9DQogIGZ1bmN0aW9uIHJlbmRlckhhbmRsZVRhYmxlKGVtcHR5TXNnKSB7DQogICAgY29uc3QgcSA9IGhhbmRsZVF1ZXJ5Ow0KICAgIGNvbnN0IHBvcnRNb2RlID0gaGFuZGxlTW9kZSA9PT0gJ3BvcnQnOw0KICAgIHNldEhhbmRsZVBvcnRNb2RlKHBvcnRNb2RlKTsNCiAgICBpZiAocSkgew0KICAgICAgaGFuZGxlQmFubmVyLmNsYXNzTGlzdC5hZGQoJ29uJyk7DQogICAgICBpZiAocG9ydE1vZGUgJiYgKHEgPT09IERFRkFVTFRfUE9SVF9RVUVSWSB8fCAvXjBccyotXHMqNjU1MzUkLy50ZXN0KHEpKSkNCiAgICAgICAgaGFuZGxlQmFubmVyLnRleHRDb250ZW50ID0gJ+WFqOmDqOi/nuaOpSc7DQogICAgICBlbHNlDQogICAgICAgIGhhbmRsZUJhbm5lci50ZXh0Q29udGVudCA9IChwb3J0TW9kZSA/ICfnq6/lj6MgJyA6ICcnKSArICfigJwnICsgcSArICfigJ3nmoTmkJzntKLnu5PmnpwnOw0KICAgIH0gZWxzZSB7DQogICAgICBoYW5kbGVCYW5uZXIuY2xhc3NMaXN0LnJlbW92ZSgnb24nKTsNCiAgICAgIGhhbmRsZUJhbm5lci50ZXh0Q29udGVudCA9ICcnOw0KICAgIH0NCiAgICBpZiAoaGFuZGxlQnVzeSAmJiAhaGFuZGxlSXRlbXMubGVuZ3RoKSB7DQogICAgICBzaG93SGFuZGxlTG9hZGluZyhlbXB0eU1zZyB8fCAocG9ydE1vZGUgPyAn5q2j5Zyo5p+l6K+i56uv5Y+j4oCmJyA6ICfmraPlnKjmn6Xor6Llj6Xmn4TigKYnKSk7DQogICAgICBzeW5jSGFuZGxlQmFyKDApOw0KICAgICAgc3luY0hhbmRsZUhlYWRTb3J0KCk7DQogICAgICByZXR1cm47DQogICAgfQ0KICAgIGlmIChwb3J0TW9kZSkgaGFuZGxlSXRlbXMgPSBkZWR1cGVQb3J0SXRlbXMoaGFuZGxlSXRlbXMpOw0KICAgIGhhbmRsZUl0ZW1zID0gc29ydEhhbmRsZUl0ZW1zKGhhbmRsZUl0ZW1zKTsNCiAgICBzeW5jSGFuZGxlSGVhZFNvcnQoKTsNCiAgICBjb25zdCBuID0gaGFuZGxlSXRlbXMubGVuZ3RoOw0KICAgIHN5bmNIYW5kbGVCYXIobik7DQogICAgaWYgKCFuKSB7DQogICAgICBoYW5kbGVCb2R5LmlubmVySFRNTCA9ICc8ZGl2IGNsYXNzPSJoYW5kbGUtZW1wdHkiPicgKyBlc2NhcGVIdG1sKGVtcHR5TXNnIHx8IChwb3J0TW9kZSA/ICfmsqHmnInljLnphY3nmoTnq6/lj6MnIDogJ+ayoeacieWMuemFjeeahOWPpeafhCcpKSArICc8L2Rpdj4nOw0KICAgICAgaGFuZGxlU2VsS2V5cy5jbGVhcigpOw0KICAgICAgaGFuZGxlQW5jaG9yS2V5ID0gJyc7DQogICAgICByZXR1cm47DQogICAgfQ0KICAgIGNvbnN0IGtlZXAgPSBuZXcgU2V0KCk7DQogICAgY29uc3QgZnJhZyA9IGRvY3VtZW50LmNyZWF0ZURvY3VtZW50RnJhZ21lbnQoKTsNCiAgICBmb3IgKGxldCBpID0gMDsgaSA8IGhhbmRsZUl0ZW1zLmxlbmd0aDsgaSsrKSB7DQogICAgICBjb25zdCBpdCA9IGhhbmRsZUl0ZW1zW2ldOw0KICAgICAgY29uc3Qgcm93ID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnZGl2Jyk7DQogICAgICBjb25zdCBrZXkgPSBoYW5kbGVSb3dLZXkoaXQsIGkpOw0KICAgICAga2VlcC5hZGQoa2V5KTsNCiAgICAgIHJvdy5jbGFzc05hbWUgPSAnaGFuZGxlLXJvdyBoYW5kbGUtY29scycgKyAocG9ydE1vZGUgPyAnIHBvcnQtbW9kZScgOiAnJykgKyAoaGFuZGxlU2VsS2V5cy5oYXMoa2V5KSA/ICcgb24nIDogJycpOw0KICAgICAgcm93LnNldEF0dHJpYnV0ZSgnZGF0YS1rZXknLCBrZXkpOw0KICAgICAgcm93LnNldEF0dHJpYnV0ZSgnZGF0YS1waWQnLCBTdHJpbmcoTnVtYmVyKGl0LnBpZCkgfHwgMCkpOw0KICAgICAgcm93LnNldEF0dHJpYnV0ZSgnZGF0YS1uYW1lJywgU3RyaW5nKGl0Lm5hbWUgfHwgJycpKTsNCiAgICAgIHJvdy5zZXRBdHRyaWJ1dGUoJ2RhdGEtcGF0aCcsIFN0cmluZyhpdC5wYXRoIHx8ICcnKSk7DQogICAgICBjb25zdCBuYW1lID0gU3RyaW5nKGl0Lm5hbWUgfHwgJycpOw0KICAgICAgY29uc3QgcGlkTnVtID0gTnVtYmVyKGl0LnBpZCk7DQogICAgICBjb25zdCBwaWQgPSBOdW1iZXIuaXNGaW5pdGUocGlkTnVtKSAmJiBwaWROdW0gPiAwID8gU3RyaW5nKHBpZE51bSkgOiAnJzsNCiAgICAgIGNvbnN0IHR5cCA9IFN0cmluZyhpdC50eXBlIHx8ICcnKTsNCiAgICAgIGNvbnN0IGhuYW1lID0gU3RyaW5nKGl0LmhhbmRsZSB8fCAnJyk7DQogICAgICBjb25zdCBscG9ydCA9IChpdC5sb2NhbFBvcnQgPT0gbnVsbCB8fCBOdW1iZXIoaXQubG9jYWxQb3J0KSA8IDApID8gJycgOiBTdHJpbmcoaXQubG9jYWxQb3J0KTsNCiAgICAgIGNvbnN0IHJwb3J0TnVtID0gTnVtYmVyKGl0LnJlbW90ZVBvcnQpOw0KICAgICAgY29uc3QgcnBvcnQgPSBOdW1iZXIuaXNGaW5pdGUocnBvcnROdW0pICYmIHJwb3J0TnVtID4gMCA/IFN0cmluZyhycG9ydE51bSkgOiAocG9ydE1vZGUgPyAn4oCUJyA6ICcnKTsNCiAgICAgIGNvbnN0IHRpcCA9IHBvcnRNb2RlID8gcG9ydFRpcFRleHQoaXQpIDogKGl0LnBhdGggfHwgbmFtZSk7DQogICAgICBjb25zdCBsSG90ID0gcG9ydE1vZGUgJiYgbHBvcnQgIT09ICcnICYmIHBvcnRJc0hvdChscG9ydCkgPyAnIHBvcnQtaG90JyA6ICcnOw0KICAgICAgY29uc3QgckhvdCA9IHBvcnRNb2RlICYmIHJwb3J0ICE9PSAn4oCUJyAmJiBycG9ydCAhPT0gJycgJiYgcG9ydElzSG90KHJwb3J0KSA/ICcgcG9ydC1ob3QnIDogJyc7DQogICAgICBjb25zdCBjb25uZWN0ZWQgPSBwb3J0TW9kZSAmJiAoaG5hbWUgPT09ICfov57mjqUnIHx8IC9lc3RhYmxpc2hlZC9pLnRlc3QoaG5hbWUpKTsNCiAgICAgIGNvbnN0IG5ldERvdCA9IGNvbm5lY3RlZCA/ICc8c3BhbiBjbGFzcz0iaGFuZGxlLW5ldC1kb3QiIHRpdGxlPSLlt7Lov57mjqUiPjwvc3Bhbj4nIDogJyc7DQogICAgICBjb25zdCBpY28gPSBpdC5pY29uDQogICAgICAgID8gJzxpbWcgc3JjPSInICsgZXNjYXBlSHRtbChTdHJpbmcoaXQuaWNvbikpICsgJyIgYWx0PSIiIG9uZXJyb3I9InRoaXMub25lcnJvcj1udWxsO3RoaXMucmVwbGFjZVdpdGgoT2JqZWN0LmFzc2lnbihkb2N1bWVudC5jcmVhdGVFbGVtZW50KFwnc3BhblwnKSx7Y2xhc3NOYW1lOlwnaGFuZGxlLWljby1waFwnfSkpIj4nDQogICAgICAgIDogJzxzcGFuIGNsYXNzPSJoYW5kbGUtaWNvLXBoIiBhcmlhLWhpZGRlbj0idHJ1ZSI+PC9zcGFuPic7DQogICAgICByb3cuaW5uZXJIVE1MID0NCiAgICAgICAgJzxkaXYgY2xhc3M9ImhhbmRsZS1uYW1lIiB0aXRsZT0iJyArIGVzY2FwZUh0bWwoaXQucGF0aCB8fCBuYW1lKSArICciPicgKyBpY28gKyAnPHNwYW4+JyArIGVzY2FwZUh0bWwobmFtZSkgKyAnPC9zcGFuPjwvZGl2PicNCiAgICAgICAgKyAnPGRpdj4nICsgZXNjYXBlSHRtbChwaWQpICsgJzwvZGl2PicNCiAgICAgICAgKyAocG9ydE1vZGUNCiAgICAgICAgICA/ICgnPGRpdiBjbGFzcz0iaGFuZGxlLWNvbC1wb3J0JyArIGxIb3QgKyAnIiB0aXRsZT0iJyArIGVzY2FwZUh0bWwodGlwKSArICciPicgKyBlc2NhcGVIdG1sKGxwb3J0KSArICc8L2Rpdj4nDQogICAgICAgICAgICArICc8ZGl2IGNsYXNzPSJoYW5kbGUtY29sLXJwb3J0JyArIHJIb3QgKyAnIiB0aXRsZT0iJyArIGVzY2FwZUh0bWwodGlwKSArICciPicgKyBlc2NhcGVIdG1sKHJwb3J0KSArICc8L2Rpdj4nKQ0KICAgICAgICAgIDogJycpDQogICAgICAgICsgJzxkaXY+JyArIGVzY2FwZUh0bWwodHlwKSArICc8L2Rpdj4nDQogICAgICAgICsgJzxkaXYgY2xhc3M9ImhhbmRsZS1zdGF0ZSIgdGl0bGU9IicgKyBlc2NhcGVIdG1sKHBvcnRNb2RlID8gdGlwIDogaG5hbWUpICsgJyI+JyArIG5ldERvdCArICc8c3Bhbj4nICsgZXNjYXBlSHRtbChobmFtZSkgKyAnPC9zcGFuPjwvZGl2Pic7DQogICAgICBpZiAocG9ydE1vZGUpIHJvdy50aXRsZSA9IHRpcDsNCiAgICAgIHJvdy5vbmNsaWNrID0gKGUpID0+IHNlbGVjdEhhbmRsZUZyb21FdmVudChlLCByb3cpOw0KICAgICAgcm93Lm9uY29udGV4dG1lbnUgPSAoZSkgPT4gew0KICAgICAgICBlLnByZXZlbnREZWZhdWx0KCk7DQogICAgICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7DQogICAgICAgIGNvbnN0IGsgPSByb3cuZ2V0QXR0cmlidXRlKCdkYXRhLWtleScpOw0KICAgICAgICBpZiAoIWhhbmRsZVNlbEtleXMuaGFzKGspKSB7DQogICAgICAgICAgaGFuZGxlU2VsS2V5cy5jbGVhcigpOw0KICAgICAgICAgIGhhbmRsZVNlbEtleXMuYWRkKGspOw0KICAgICAgICAgIGhhbmRsZUFuY2hvcktleSA9IGs7DQogICAgICAgICAgcmVmcmVzaEhhbmRsZVNlbGVjdGlvblVJKCk7DQogICAgICAgIH0NCiAgICAgICAgc2hvd1Byb2NNZW51KGUuY2xpZW50WCwgZS5jbGllbnRZLCBjb2xsZWN0SGFuZGxlVGFyZ2V0cygpKTsNCiAgICAgIH07DQogICAgICByb3cub25kYmxjbGljayA9ICgpID0+IHsNCiAgICAgICAgY29uc3QgdCA9IHBvcnRNb2RlID8gdGlwIDogKGhuYW1lIHx8IG5hbWUpOw0KICAgICAgICB0cnkgeyBuYXZpZ2F0b3IuY2xpcGJvYXJkLndyaXRlVGV4dCh0KTsgfSBjYXRjaCAoXykgeyBwb3N0KCdjb3B5VGV4dHwnICsgdCk7IH0NCiAgICAgIH07DQogICAgICBmcmFnLmFwcGVuZENoaWxkKHJvdyk7DQogICAgfQ0KICAgIGZvciAoY29uc3QgayBvZiBBcnJheS5mcm9tKGhhbmRsZVNlbEtleXMpKSB7DQogICAgICBpZiAoIWtlZXAuaGFzKGspKSBoYW5kbGVTZWxLZXlzLmRlbGV0ZShrKTsNCiAgICB9DQogICAgaGFuZGxlQm9keS5pbm5lckhUTUwgPSAnJzsNCiAgICBoYW5kbGVCb2R5LmFwcGVuZENoaWxkKGZyYWcpOw0KICB9DQogIGZ1bmN0aW9uIHN5bmNIYW5kbGVCYXIobikgew0KICAgIGlmIChhcHBNb2RlID09PSAnaGFuZGxlJykNCiAgICAgIGNvdW50RWwudGV4dENvbnRlbnQgPSAn5YWxICcgKyAoTnVtYmVyKG4pIHx8IDApICsgJyDmnaEnOw0KICB9DQogIGZ1bmN0aW9uIGhhbmRsZVJvd0tleShpdCwgaWR4KSB7DQogICAgcmV0dXJuIFtpdC5waWQsIGl0LnR5cGUsIGl0LmhhbmRsZSwgaXQubG9jYWxQb3J0LCBpdC5yZW1vdGVQb3J0LCBpZHhdLmpvaW4oJ3wnKTsNCiAgfQ0KICBmdW5jdGlvbiByZWZyZXNoSGFuZGxlU2VsZWN0aW9uVUkoKSB7DQogICAgaGFuZGxlQm9keS5xdWVyeVNlbGVjdG9yQWxsKCcuaGFuZGxlLXJvdycpLmZvckVhY2gocm93ID0+IHsNCiAgICAgIHJvdy5jbGFzc0xpc3QudG9nZ2xlKCdvbicsIGhhbmRsZVNlbEtleXMuaGFzKHJvdy5nZXRBdHRyaWJ1dGUoJ2RhdGEta2V5JykpKTsNCiAgICB9KTsNCiAgfQ0KICBmdW5jdGlvbiBzZWxlY3RIYW5kbGVGcm9tRXZlbnQoZSwgcm93KSB7DQogICAgY29uc3Qga2V5ID0gcm93LmdldEF0dHJpYnV0ZSgnZGF0YS1rZXknKTsNCiAgICBjb25zdCByb3dzID0gQXJyYXkuZnJvbShoYW5kbGVCb2R5LnF1ZXJ5U2VsZWN0b3JBbGwoJy5oYW5kbGUtcm93JykpOw0KICAgIGNvbnN0IGlkeCA9IHJvd3MuaW5kZXhPZihyb3cpOw0KICAgIGlmIChlLnNoaWZ0S2V5ICYmIGhhbmRsZUFuY2hvcktleSkgew0KICAgICAgY29uc3QgYUlkeCA9IHJvd3MuZmluZEluZGV4KHIgPT4gci5nZXRBdHRyaWJ1dGUoJ2RhdGEta2V5JykgPT09IGhhbmRsZUFuY2hvcktleSk7DQogICAgICBpZiAoYUlkeCA+PSAwICYmIGlkeCA+PSAwKSB7DQogICAgICAgIGlmICghZS5jdHJsS2V5KSBoYW5kbGVTZWxLZXlzLmNsZWFyKCk7DQogICAgICAgIGNvbnN0IGxvID0gTWF0aC5taW4oYUlkeCwgaWR4KSwgaGkgPSBNYXRoLm1heChhSWR4LCBpZHgpOw0KICAgICAgICBmb3IgKGxldCBpID0gbG87IGkgPD0gaGk7IGkrKykgaGFuZGxlU2VsS2V5cy5hZGQocm93c1tpXS5nZXRBdHRyaWJ1dGUoJ2RhdGEta2V5JykpOw0KICAgICAgfQ0KICAgIH0gZWxzZSBpZiAoZS5jdHJsS2V5KSB7DQogICAgICBpZiAoaGFuZGxlU2VsS2V5cy5oYXMoa2V5KSkgaGFuZGxlU2VsS2V5cy5kZWxldGUoa2V5KTsNCiAgICAgIGVsc2UgaGFuZGxlU2VsS2V5cy5hZGQoa2V5KTsNCiAgICAgIGhhbmRsZUFuY2hvcktleSA9IGtleTsNCiAgICB9IGVsc2Ugew0KICAgICAgaGFuZGxlU2VsS2V5cy5jbGVhcigpOw0KICAgICAgaGFuZGxlU2VsS2V5cy5hZGQoa2V5KTsNCiAgICAgIGhhbmRsZUFuY2hvcktleSA9IGtleTsNCiAgICB9DQogICAgcmVmcmVzaEhhbmRsZVNlbGVjdGlvblVJKCk7DQogIH0NCiAgZnVuY3Rpb24gY29sbGVjdEhhbmRsZVRhcmdldHMoKSB7DQogICAgY29uc3QgbWFwID0gbmV3IE1hcCgpOw0KICAgIGhhbmRsZUJvZHkucXVlcnlTZWxlY3RvckFsbCgnLmhhbmRsZS1yb3cnKS5mb3JFYWNoKHJvdyA9PiB7DQogICAgICBpZiAoIWhhbmRsZVNlbEtleXMuaGFzKHJvdy5nZXRBdHRyaWJ1dGUoJ2RhdGEta2V5JykpKSByZXR1cm47DQogICAgICBjb25zdCBwaWQgPSBOdW1iZXIocm93LmdldEF0dHJpYnV0ZSgnZGF0YS1waWQnKSkgfHwgMDsNCiAgICAgIGlmIChwaWQgPD0gMCB8fCBtYXAuaGFzKHBpZCkpIHJldHVybjsNCiAgICAgIG1hcC5zZXQocGlkLCB7DQogICAgICAgIHBpZCwNCiAgICAgICAgbmFtZTogcm93LmdldEF0dHJpYnV0ZSgnZGF0YS1uYW1lJykgfHwgJycsDQogICAgICAgIHBhdGg6IHJvdy5nZXRBdHRyaWJ1dGUoJ2RhdGEtcGF0aCcpIHx8ICcnDQogICAgICB9KTsNCiAgICB9KTsNCiAgICByZXR1cm4gQXJyYXkuZnJvbShtYXAudmFsdWVzKCkpOw0KICB9DQogIHdpbmRvdy5fX29uSG9zdEhpZGUgPSAoKSA9PiB7IHBvc3QoJ3Byb2NWaWV3fDAnKTsgfTsNCiAgd2luZG93Ll9fb25Ib3N0U2hvdyA9ICgpID0+IHt9Ow0KICBkb2N1bWVudC5hZGRFdmVudExpc3RlbmVyKCd2aXNpYmlsaXR5Y2hhbmdlJywgKCkgPT4gew0KICAgIGlmIChkb2N1bWVudC5oaWRkZW4pIHBvc3QoJ3Byb2NWaWV3fDAnKTsNCiAgfSk7DQoNCiAgaWYgKGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdidG4taW5mby1yZWZyZXNoJykpDQogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2J0bi1pbmZvLXJlZnJlc2gnKS5vbmNsaWNrID0gKCkgPT4gcmVxdWVzdFN5c0luZm8odHJ1ZSk7DQogIGlmIChkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYnRuLWluZm8tY29weScpKQ0KICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdidG4taW5mby1jb3B5Jykub25jbGljayA9ICgpID0+IHsNCiAgICAgIGNvbnN0IHQgPSBpbmZvVGV4dCB8fCAoaW5mb1BhbmVsICYmIGluZm9QYW5lbC5pbm5lclRleHQpIHx8ICcnOw0KICAgICAgdHJ5IHsgbmF2aWdhdG9yLmNsaXBib2FyZC53cml0ZVRleHQodCk7IH0gY2F0Y2ggKF8pIHsgcG9zdCgnY29weVRleHR8JyArIHQpOyB9DQogICAgfTsNCiAgaWYgKGJ0blBvcnRNYXJrKSB7DQogICAgYnRuUG9ydE1hcmsub25jbGljayA9IChlKSA9PiB7DQogICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOw0KICAgICAgaWYgKHBvcnRNYXJrUG9wICYmIHBvcnRNYXJrUG9wLmNsYXNzTGlzdC5jb250YWlucygnb24nKSkgY2xvc2VQb3J0TWFya1BvcCgpOw0KICAgICAgZWxzZSBvcGVuUG9ydE1hcmtQb3AoKTsNCiAgICB9Ow0KICB9DQogIGlmIChwb3J0TWFya1BvcCkgcG9ydE1hcmtQb3AuYWRkRXZlbnRMaXN0ZW5lcignY2xpY2snLCBlID0+IGUuc3RvcFByb3BhZ2F0aW9uKCkpOw0KICBjb25zdCBidG5Qb3J0TWFya0FkZCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdwb3J0LW1hcmstYWRkJyk7DQogIGNvbnN0IGJ0blBvcnRNYXJrUmVzZXQgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgncG9ydC1tYXJrLXJlc2V0Jyk7DQogIGlmIChidG5Qb3J0TWFya0FkZCkgew0KICAgIGJ0blBvcnRNYXJrQWRkLm9uY2xpY2sgPSAoZSkgPT4gew0KICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsNCiAgICAgIGlmIChhZGRNYXJrZWRQb3J0KHBvcnRNYXJrSW5wdXQgJiYgcG9ydE1hcmtJbnB1dC52YWx1ZSkpIHsNCiAgICAgICAgaWYgKHBvcnRNYXJrSW5wdXQpIHBvcnRNYXJrSW5wdXQudmFsdWUgPSAnJzsNCiAgICAgIH0NCiAgICB9Ow0KICB9DQogIGlmIChwb3J0TWFya0lucHV0KSB7DQogICAgcG9ydE1hcmtJbnB1dC5hZGRFdmVudExpc3RlbmVyKCdrZXlkb3duJywgZSA9PiB7DQogICAgICBpZiAoZS5rZXkgPT09ICdFbnRlcicpIHsNCiAgICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOw0KICAgICAgICBpZiAoYWRkTWFya2VkUG9ydChwb3J0TWFya0lucHV0LnZhbHVlKSkgcG9ydE1hcmtJbnB1dC52YWx1ZSA9ICcnOw0KICAgICAgfQ0KICAgIH0pOw0KICB9DQogIGlmIChidG5Qb3J0TWFya1Jlc2V0KSB7DQogICAgYnRuUG9ydE1hcmtSZXNldC5vbmNsaWNrID0gKGUpID0+IHsNCiAgICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7DQogICAgICBtYXJrZWRQb3J0cyA9IERFRkFVTFRfTUFSS0VEX1BPUlRTLnNsaWNlKCk7DQogICAgICBzYXZlTWFya2VkUG9ydHMoKTsNCiAgICAgIHJlbmRlck1hcmtlZFBvcnRUYWdzKCk7DQogICAgICBpZiAoYXBwTW9kZSA9PT0gJ2hhbmRsZScgJiYgaGFuZGxlTW9kZSA9PT0gJ3BvcnQnKSByZW5kZXJIYW5kbGVUYWJsZSgpOw0KICAgIH07DQogIH0NCiAgZG9jdW1lbnQuYWRkRXZlbnRMaXN0ZW5lcignY2xpY2snLCAoKSA9PiBjbG9zZVBvcnRNYXJrUG9wKCkpOw0KICByZW5kZXJNYXJrZWRQb3J0VGFncygpOw0KICByZW5kZXJIYW5kbGVIaXN0KCk7DQogIC8vIOS4u+aQnOe0ouahhue7n+S4gOaQnOe0ou+8m+WPpeafhOWOhuWPsui1sCDilr4g5LiL5ouJ77yI5LiO5paH5Lu25pCc57Si5LiA6Ie077yJDQogIHRyeSB7IHFFbC5yZW1vdmVBdHRyaWJ1dGUoJ2xpc3QnKTsgfSBjYXRjaCAoXykge30NCg0KICBmdW5jdGlvbiBoaWRlUHJvY01lbnUoKSB7DQogICAgcHJvY01lbnUuY2xhc3NMaXN0LnJlbW92ZSgnb24nKTsNCiAgICBwcm9jTWVudVRhcmdldHMgPSBbXTsNCiAgfQ0KICBmdW5jdGlvbiBzaG93UHJvY01lbnUoeCwgeSwgdGFyZ2V0cykgew0KICAgIHByb2NNZW51VGFyZ2V0cyA9IEFycmF5LmlzQXJyYXkodGFyZ2V0cykgPyB0YXJnZXRzLmZpbHRlcih0ID0+IHQgJiYgTnVtYmVyKHQucGlkKSA+IDApIDogW107DQogICAgY29uc3QgbiA9IHByb2NNZW51VGFyZ2V0cy5sZW5ndGg7DQogICAgY29uc3QgZmlyc3QgPSBuID8gcHJvY01lbnVUYXJnZXRzWzBdIDogbnVsbDsNCiAgICBjb25zdCBuYW1lID0gZmlyc3QgPyBTdHJpbmcoZmlyc3QubmFtZSB8fCAnJykudHJpbSgpIDogJyc7DQogICAgY29uc3QgcGlkID0gZmlyc3QgPyBTdHJpbmcoTnVtYmVyKGZpcnN0LnBpZCkgfHwgJycpIDogJyc7DQogICAgY29uc3QgY29weUxibCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdwcm9jLW1lbnUtY29weScpOw0KICAgIGNvbnN0IHBpZExibCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdwcm9jLW1lbnUtY29weXBpZCcpOw0KICAgIGNvbnN0IGVuZExibCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdwcm9jLW1lbnUtZW5kLWxhYmVsJyk7DQogICAgaWYgKGNvcHlMYmwpIHsNCiAgICAgIGlmIChuYW1lICYmIG4gPT09IDEpIGNvcHlMYmwudGV4dENvbnRlbnQgPSAn5aSN5Yi26L+b56iL5ZCNICggJyArIG5hbWUgKyAnICknOw0KICAgICAgZWxzZSBpZiAobmFtZSAmJiBuID4gMSkgY29weUxibC50ZXh0Q29udGVudCA9ICflpI3liLbov5vnqIvlkI0gKCAnICsgbmFtZSArICcg562JJyArIG4gKyAn5LiqICknOw0KICAgICAgZWxzZSBjb3B5TGJsLnRleHRDb250ZW50ID0gJ+WkjeWItui/m+eoi+WQjSc7DQogICAgfQ0KICAgIGlmIChwaWRMYmwpIHsNCiAgICAgIGlmIChwaWQgJiYgbiA9PT0gMSkgcGlkTGJsLnRleHRDb250ZW50ID0gJ+WkjeWItui/m+eoi+WPtyAoICcgKyBwaWQgKyAnICknOw0KICAgICAgZWxzZSBpZiAocGlkICYmIG4gPiAxKSBwaWRMYmwudGV4dENvbnRlbnQgPSAn5aSN5Yi26L+b56iL5Y+3ICggJyArIHBpZCArICcg562JJyArIG4gKyAn5LiqICknOw0KICAgICAgZWxzZSBwaWRMYmwudGV4dENvbnRlbnQgPSAn5aSN5Yi26L+b56iL5Y+3JzsNCiAgICB9DQogICAgaWYgKGVuZExibCkgZW5kTGJsLnRleHRDb250ZW50ID0gJ+WFs+mXrei/m+eoiyAoICcgKyBNYXRoLm1heChuLCAwKSArICcgKSc7DQogICAgY29uc3QgaGFzUGF0aCA9IHByb2NNZW51VGFyZ2V0cy5zb21lKHQgPT4gdC5wYXRoKTsNCiAgICBwcm9jTWVudS5xdWVyeVNlbGVjdG9yQWxsKCdidXR0b25bZGF0YS1wYWN0XScpLmZvckVhY2goYnRuID0+IHsNCiAgICAgIGNvbnN0IGFjdCA9IGJ0bi5nZXRBdHRyaWJ1dGUoJ2RhdGEtcGFjdCcpOw0KICAgICAgaWYgKGFjdCA9PT0gJ3JldmVhbCcpIGJ0bi5kaXNhYmxlZCA9ICFoYXNQYXRoOw0KICAgICAgZWxzZSBidG4uZGlzYWJsZWQgPSBuIDwgMTsNCiAgICB9KTsNCiAgICBwcm9jTWVudS5jbGFzc0xpc3QuYWRkKCdvbicpOw0KICAgIHByb2NNZW51LnN0eWxlLmxlZnQgPSAnMHB4JzsNCiAgICBwcm9jTWVudS5zdHlsZS50b3AgPSAnMHB4JzsNCiAgICBjb25zdCByZWN0ID0gcHJvY01lbnUuZ2V0Qm91bmRpbmdDbGllbnRSZWN0KCk7DQogICAgbGV0IGxlZnQgPSB4LCB0b3AgPSB5Ow0KICAgIGlmIChsZWZ0ICsgcmVjdC53aWR0aCA+IGlubmVyV2lkdGggLSA2KSBsZWZ0ID0gTWF0aC5tYXgoNiwgaW5uZXJXaWR0aCAtIHJlY3Qud2lkdGggLSA2KTsNCiAgICBpZiAodG9wICsgcmVjdC5oZWlnaHQgPiBpbm5lckhlaWdodCAtIDYpIHRvcCA9IE1hdGgubWF4KDYsIGlubmVySGVpZ2h0IC0gcmVjdC5oZWlnaHQgLSA2KTsNCiAgICBwcm9jTWVudS5zdHlsZS5sZWZ0ID0gbGVmdCArICdweCc7DQogICAgcHJvY01lbnUuc3R5bGUudG9wID0gdG9wICsgJ3B4JzsNCiAgfQ0KICBmdW5jdGlvbiBjb3B5VGV4dFNhZmUodGV4dCkgew0KICAgIHRleHQgPSBTdHJpbmcodGV4dCB8fCAnJyk7DQogICAgaWYgKCF0ZXh0KSByZXR1cm47DQogICAgdHJ5IHsgbmF2aWdhdG9yLmNsaXBib2FyZC53cml0ZVRleHQodGV4dCk7IH0gY2F0Y2ggKF8pIHsgcG9zdCgnY29weVRleHR8JyArIHRleHQpOyB9DQogIH0NCiAgcHJvY01lbnUucXVlcnlTZWxlY3RvckFsbCgnYnV0dG9uW2RhdGEtcGFjdF0nKS5mb3JFYWNoKGJ0biA9PiB7DQogICAgYnRuLm9uY2xpY2sgPSAoZSkgPT4gew0KICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsNCiAgICAgIGNvbnN0IGFjdCA9IGJ0bi5nZXRBdHRyaWJ1dGUoJ2RhdGEtcGFjdCcpOw0KICAgICAgY29uc3QgdGFyZ2V0cyA9IHByb2NNZW51VGFyZ2V0cy5zbGljZSgpOw0KICAgICAgaGlkZVByb2NNZW51KCk7DQogICAgICBpZiAoIXRhcmdldHMubGVuZ3RoKSByZXR1cm47DQogICAgICBpZiAoYWN0ID09PSAnZW5kJykgew0KICAgICAgICBjb25zdCBwaWRzID0gdGFyZ2V0cy5tYXAodCA9PiBOdW1iZXIodC5waWQpIHx8IDApLmZpbHRlcihwaWQgPT4gcGlkID4gMCk7DQogICAgICAgIGlmIChwaWRzLmxlbmd0aCkgew0KICAgICAgICAgIC8vIOWFiOS7jueVjOmdouenu+mZpO+8jOS4u+acuuehruiupOWQjuS8muWGjeWQjOatpeS4gOasoQ0KICAgICAgICAgIHJlbW92ZVJvd3NCeVBpZHMocGlkcyk7DQogICAgICAgICAgcG9zdCgncHJvY0tpbGx8JyArIHBpZHMuam9pbignLCcpKTsNCiAgICAgICAgfQ0KICAgICAgfSBlbHNlIGlmIChhY3QgPT09ICdyZXZlYWwnKSB7DQogICAgICAgIGNvbnN0IHNlZW4gPSBuZXcgU2V0KCk7DQogICAgICAgIGZvciAoY29uc3QgdCBvZiB0YXJnZXRzKSB7DQogICAgICAgICAgY29uc3QgcCA9IFN0cmluZyh0LnBhdGggfHwgJycpOw0KICAgICAgICAgIGlmICghcCB8fCBzZWVuLmhhcyhwLnRvTG93ZXJDYXNlKCkpKSBjb250aW51ZTsNCiAgICAgICAgICBzZWVuLmFkZChwLnRvTG93ZXJDYXNlKCkpOw0KICAgICAgICAgIGNhbGxIb3N0KCdyZXZlYWwnLCBwKTsNCiAgICAgICAgfQ0KICAgICAgfSBlbHNlIGlmIChhY3QgPT09ICdjb3B5Jykgew0KICAgICAgICBjb25zdCBuYW1lcyA9IFtdOw0KICAgICAgICBjb25zdCBzZWVuID0gbmV3IFNldCgpOw0KICAgICAgICBmb3IgKGNvbnN0IHQgb2YgdGFyZ2V0cykgew0KICAgICAgICAgIGxldCBuID0gU3RyaW5nKHQubmFtZSB8fCAnJykudHJpbSgpOw0KICAgICAgICAgIGlmICghbiAmJiB0LnBhdGgpIHsNCiAgICAgICAgICAgIGNvbnN0IHAgPSBTdHJpbmcodC5wYXRoKS5yZXBsYWNlKC9bXFwvXSskLywgJycpOw0KICAgICAgICAgICAgY29uc3QgaSA9IE1hdGgubWF4KHAubGFzdEluZGV4T2YoJ1xcJyksIHAubGFzdEluZGV4T2YoJy8nKSk7DQogICAgICAgICAgICBuID0gaSA+PSAwID8gcC5zbGljZShpICsgMSkgOiBwOw0KICAgICAgICAgIH0NCiAgICAgICAgICBpZiAoIW4gfHwgc2Vlbi5oYXMobi50b0xvd2VyQ2FzZSgpKSkgY29udGludWU7DQogICAgICAgICAgc2Vlbi5hZGQobi50b0xvd2VyQ2FzZSgpKTsNCiAgICAgICAgICBuYW1lcy5wdXNoKG4pOw0KICAgICAgICB9DQogICAgICAgIGNvcHlUZXh0U2FmZShuYW1lcy5qb2luKCdcbicpKTsNCiAgICAgIH0gZWxzZSBpZiAoYWN0ID09PSAnY29weVBpZCcpIHsNCiAgICAgICAgY29uc3QgcGlkcyA9IFtdOw0KICAgICAgICBjb25zdCBzZWVuID0gbmV3IFNldCgpOw0KICAgICAgICBmb3IgKGNvbnN0IHQgb2YgdGFyZ2V0cykgew0KICAgICAgICAgIGNvbnN0IHBpZCA9IE51bWJlcih0LnBpZCkgfHwgMDsNCiAgICAgICAgICBpZiAocGlkIDw9IDAgfHwgc2Vlbi5oYXMocGlkKSkgY29udGludWU7DQogICAgICAgICAgc2Vlbi5hZGQocGlkKTsNCiAgICAgICAgICBwaWRzLnB1c2goU3RyaW5nKHBpZCkpOw0KICAgICAgICB9DQogICAgICAgIGNvcHlUZXh0U2FmZShwaWRzLmpvaW4oJ1xuJykpOw0KICAgICAgfQ0KICAgIH07DQogIH0pOw0KICBkb2N1bWVudC5hZGRFdmVudExpc3RlbmVyKCdjbGljaycsICgpID0+IGhpZGVQcm9jTWVudSgpKTsNCiAgZG9jdW1lbnQuYWRkRXZlbnRMaXN0ZW5lcigna2V5ZG93bicsIChlKSA9PiB7DQogICAgaWYgKGUua2V5ID09PSAnRXNjYXBlJykgew0KICAgICAgaGlkZVByb2NNZW51KCk7DQogICAgICBjbG9zZVBvcnRNYXJrUG9wKCk7DQogICAgfQ0KICB9KTsNCg0KICBmdW5jdGlvbiBwcm9jUm93S2V5KHApIHsNCiAgICByZXR1cm4gW3AucHJvdG8sIHAubG9jYWxJcCwgcC5sb2NhbFBvcnQsIHAucmVtb3RlSXAsIHAucmVtb3RlUG9ydCwgcC5waWRdLmpvaW4oJ3wnKTsNCiAgfQ0KICBmdW5jdGlvbiBwb3J0c0NvbnRlbnRTaWcoaXRlbXMpIHsNCiAgICByZXR1cm4gKGl0ZW1zIHx8IFtdKS5tYXAocCA9Pg0KICAgICAgcHJvY1Jvd0tleShwKSArICdcdCcgKyAocC5wcm9jIHx8ICcnKSArICdcdCcgKyAocC5zdGF0ZSB8fCAnJykgKyAnXHQnICsgKHAucGF0aCB8fCAnJykNCiAgICAgICAgKyAnXHQnICsgKHAucHBpZCB8fCAnJykgKyAnXHQnICsgKHAuY3B1IHx8ICcnKSArICdcdCcgKyAocC5tZW0gfHwgJycpDQogICAgKS5qb2luKCdcbicpOw0KICB9DQogIGZ1bmN0aW9uIHBvcnRDZWxsVGV4dChwb3J0KSB7DQogICAgaWYgKHBvcnQgPT09ICcnIHx8IHBvcnQgPT0gbnVsbCB8fCBOdW1iZXIocG9ydCkgPCAwKSByZXR1cm4gJyc7DQogICAgcmV0dXJuIFN0cmluZyhwb3J0KTsNCiAgfQ0KICBmdW5jdGlvbiBwcm9jSWNvblN0YWJsZUtleShwKSB7DQogICAgY29uc3QgcGF0aCA9IFN0cmluZygocCAmJiBwLnBhdGgpIHx8ICcnKTsNCiAgICBpZiAocGF0aCkgcmV0dXJuICdwOicgKyBwYXRoLnRvTG93ZXJDYXNlKCk7DQogICAgcmV0dXJuICdpZDonICsgKE51bWJlcihwICYmIHAucGlkKSB8fCAwKTsNCiAgfQ0KICBmdW5jdGlvbiBzZXRQcm9jSWNvbkVsKG5hbWVCb3gsIGljb25VcmwsIHN0YWJsZUtleSkgew0KICAgIGlmICghbmFtZUJveCkgcmV0dXJuOw0KICAgIGxldCBpbWcgPSBuYW1lQm94LnF1ZXJ5U2VsZWN0b3IoJ2ltZycpOw0KICAgIGxldCBwaCA9IG5hbWVCb3gucXVlcnlTZWxlY3RvcignLnByb2MtaWNvLXBoJyk7DQogICAgY29uc3QgdXJsID0gU3RyaW5nKGljb25VcmwgfHwgJycpOw0KICAgIC8vIOW3suacieeos+WumuWbvuagh++8muepui/lkIwgc3JjIOmDveS4jeWKqO+8jOadnOe7nemXqueDgQ0KICAgIGlmIChpbWcpIHsNCiAgICAgIGNvbnN0IGN1ciA9IGltZy5nZXRBdHRyaWJ1dGUoJ3NyYycpIHx8ICcnOw0KICAgICAgaWYgKCF1cmwgfHwgdXJsID09PSBjdXIpIHJldHVybjsNCiAgICAgIGltZy5zZXRBdHRyaWJ1dGUoJ3NyYycsIHVybCk7DQogICAgICBpZiAoc3RhYmxlS2V5KSBwcm9jSWNvblN0YWJsZS5zZXQoc3RhYmxlS2V5LCB1cmwpOw0KICAgICAgcmV0dXJuOw0KICAgIH0NCiAgICBpZiAoIXVybCkgew0KICAgICAgaWYgKCFwaCkgew0KICAgICAgICBwaCA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ3NwYW4nKTsNCiAgICAgICAgcGguY2xhc3NOYW1lID0gJ3Byb2MtaWNvLXBoJzsNCiAgICAgICAgcGguc2V0QXR0cmlidXRlKCdhcmlhLWhpZGRlbicsICd0cnVlJyk7DQogICAgICAgIG5hbWVCb3guaW5zZXJ0QmVmb3JlKHBoLCBuYW1lQm94LmZpcnN0Q2hpbGQpOw0KICAgICAgfQ0KICAgICAgcmV0dXJuOw0KICAgIH0NCiAgICBpbWcgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdpbWcnKTsNCiAgICBpbWcuYWx0ID0gJyc7DQogICAgaW1nLmRlY29kaW5nID0gJ2FzeW5jJzsNCiAgICBpbWcuc3JjID0gdXJsOw0KICAgIGltZy5vbmVycm9yID0gZnVuY3Rpb24gKCkgew0KICAgICAgdGhpcy5vbmVycm9yID0gbnVsbDsNCiAgICAgIGNvbnN0IHMgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdzcGFuJyk7DQogICAgICBzLmNsYXNzTmFtZSA9ICdwcm9jLWljby1waCc7DQogICAgICBzLnNldEF0dHJpYnV0ZSgnYXJpYS1oaWRkZW4nLCAndHJ1ZScpOw0KICAgICAgdGhpcy5yZXBsYWNlV2l0aChzKTsNCiAgICB9Ow0KICAgIGlmIChwaCkgbmFtZUJveC5yZXBsYWNlQ2hpbGQoaW1nLCBwaCk7DQogICAgZWxzZSBuYW1lQm94Lmluc2VydEJlZm9yZShpbWcsIG5hbWVCb3guZmlyc3RDaGlsZCk7DQogICAgaWYgKHN0YWJsZUtleSkgcHJvY0ljb25TdGFibGUuc2V0KHN0YWJsZUtleSwgdXJsKTsNCiAgfQ0KICBmdW5jdGlvbiBlbnN1cmVQcm9jUm93KHApIHsNCiAgICBjb25zdCByb3cgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsNCiAgICByb3cuY2xhc3NOYW1lID0gJ3Byb2Mtcm93IHByb2MtY29scyc7DQogICAgcm93LmlubmVySFRNTCA9DQogICAgICAnPGRpdiBjbGFzcz0icHJvYy1jZWxsLW5hbWUiPjxkaXYgY2xhc3M9InByb2MtbmFtZSI+PHNwYW4gY2xhc3M9InByb2MtaWNvLXBoIiBhcmlhLWhpZGRlbj0idHJ1ZSI+PC9zcGFuPjxzcGFuIGNsYXNzPSJwcm9jLWxhYmVsIj48L3NwYW4+PC9kaXY+PC9kaXY+Jw0KICAgICAgKyAnPGRpdiBjbGFzcz0icHJvYy1udW0gcHJvYy1jZWxsLWNwdSIgZGF0YS1mPSJjcHUiPjwvZGl2PicNCiAgICAgICsgJzxkaXYgY2xhc3M9InByb2MtbnVtIHByb2MtY2VsbC1tZW0iIGRhdGEtZj0ibWVtIj48L2Rpdj4nDQogICAgICArICc8ZGl2IGNsYXNzPSJwcm9jLW51bSBwcm9jLWNlbGwtcGlkIiBkYXRhLWY9InBpZCI+PC9kaXY+Jw0KICAgICAgKyAnPGRpdiBjbGFzcz0icHJvYy1udW0gcHJvYy1jZWxsLXByb3RvIiBkYXRhLWY9InByb3RvIj48L2Rpdj4nDQogICAgICArICc8ZGl2IGNsYXNzPSJwcm9jLW51bSBwcm9jLWNlbGwtaXAiIGRhdGEtZj0ibGlwIj48L2Rpdj4nDQogICAgICArICc8ZGl2IGNsYXNzPSJwcm9jLW51bSBwcm9jLWNlbGwtcG9ydCIgZGF0YS1mPSJscG9ydCI+PC9kaXY+Jw0KICAgICAgKyAnPGRpdiBjbGFzcz0icHJvYy1udW0gcHJvYy1jZWxsLWlwIiBkYXRhLWY9InJpcCI+PC9kaXY+Jw0KICAgICAgKyAnPGRpdiBjbGFzcz0icHJvYy1udW0gcHJvYy1jZWxsLXBvcnQiIGRhdGEtZj0icnBvcnQiPjwvZGl2PicNCiAgICAgICsgJzxkaXYgY2xhc3M9InByb2MtbnVtIHByb2MtY2VsbC1zdGF0ZSIgZGF0YS1mPSJzdGF0ZSI+PHNwYW4gY2xhc3M9InByb2MtbmV0LWRvdCBoaWRkZW4iIHRpdGxlPSLlt7Lov57mjqUiPjwvc3Bhbj48c3BhbiBjbGFzcz0icHJvYy1zdGF0ZS10eHQiPjwvc3Bhbj48L2Rpdj4nOw0KICAgIHJvdy5vbmNsaWNrID0gKGUpID0+IHNlbGVjdFByb2NGcm9tRXZlbnQoZSwgcm93KTsNCiAgICByb3cub25jb250ZXh0bWVudSA9IChlKSA9PiB7DQogICAgICBlLnByZXZlbnREZWZhdWx0KCk7DQogICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOw0KICAgICAgY29uc3Qga2V5ID0gcm93LmdldEF0dHJpYnV0ZSgnZGF0YS1rZXknKTsNCiAgICAgIGlmICghcHJvY1NlbEtleXMuaGFzKGtleSkpIHsNCiAgICAgICAgc2VsZWN0UHJvY05hbWVHcm91cChyb3cpOw0KICAgICAgfQ0KICAgICAgc2hvd1Byb2NNZW51KGUuY2xpZW50WCwgZS5jbGllbnRZLCBjb2xsZWN0UHJvY1RhcmdldHMoKSk7DQogICAgfTsNCiAgICByZXR1cm4gcm93Ow0KICB9DQogIGZ1bmN0aW9uIGhlYXRDb2xvcihob3QpIHsNCiAgICByZXR1cm4gaG90ID8gJyM4OGZmYzEnIDogJyNjZWZmZTUnOw0KICB9DQogIGZ1bmN0aW9uIHBhcnNlUGN0KHMpIHsNCiAgICBjb25zdCBtID0gU3RyaW5nKHMgfHwgJycpLm1hdGNoKC8oW1xkLl0rKS8pOw0KICAgIHJldHVybiBtID8gTnVtYmVyKG1bMV0pIDogMDsNCiAgfQ0KICBmdW5jdGlvbiB1cGRhdGVIZWFkSGVhdChjcHVUb3RhbCwgbWVtVG90YWwpIHsNCiAgICBjb25zdCBjcHVDZWxsID0gcHJvY0hlYWQgJiYgcHJvY0hlYWQucXVlcnlTZWxlY3RvcignLnByb2MtaGNlbGxbZGF0YS1zb3J0PSJjcHUiXScpOw0KICAgIGNvbnN0IG1lbUNlbGwgPSBwcm9jSGVhZCAmJiBwcm9jSGVhZC5xdWVyeVNlbGVjdG9yKCcucHJvYy1oY2VsbFtkYXRhLXNvcnQ9Im1lbSJdJyk7DQogICAgY29uc3QgY3B1UGN0ID0gcGFyc2VQY3QoY3B1VG90YWwpOw0KICAgIGNvbnN0IG1lbVBjdCA9IHBhcnNlUGN0KG1lbVRvdGFsKTsNCiAgICBpZiAoY3B1Q2VsbCkgew0KICAgICAgY3B1Q2VsbC5jbGFzc0xpc3QudG9nZ2xlKCdob3QnLCBjcHVQY3QgPiA1KTsNCiAgICAgIGNwdUNlbGwuc3R5bGUuYmFja2dyb3VuZCA9IGhlYXRDb2xvcihjcHVQY3QgPiA1KTsNCiAgICB9DQogICAgaWYgKG1lbUNlbGwpIHsNCiAgICAgIG1lbUNlbGwuY2xhc3NMaXN0LnRvZ2dsZSgnaG90JywgbWVtUGN0ID4gODApOw0KICAgICAgbWVtQ2VsbC5zdHlsZS5iYWNrZ3JvdW5kID0gaGVhdENvbG9yKG1lbVBjdCA+IDgwKTsNCiAgICB9DQogIH0NCiAgZnVuY3Rpb24gdXBkYXRlUHJvY1Jvd0RhdGEocm93LCBwKSB7DQogICAgY29uc3Qga2V5ID0gcHJvY1Jvd0tleShwKTsNCiAgICByb3cuc2V0QXR0cmlidXRlKCdkYXRhLWtleScsIGtleSk7DQogICAgcm93LnNldEF0dHJpYnV0ZSgnZGF0YS1waWQnLCBTdHJpbmcocC5waWQgfHwgMCkpOw0KICAgIHJvdy5zZXRBdHRyaWJ1dGUoJ2RhdGEtbmFtZScsIFN0cmluZyhwLnByb2MgfHwgJycpKTsNCiAgICByb3cuc2V0QXR0cmlidXRlKCdkYXRhLXBhdGgnLCBTdHJpbmcocC5wYXRoIHx8ICcnKSk7DQogICAgY29uc3QgbmFtZUJveCA9IHJvdy5xdWVyeVNlbGVjdG9yKCcucHJvYy1uYW1lJyk7DQogICAgY29uc3QgbGFiZWwgPSByb3cucXVlcnlTZWxlY3RvcignLnByb2MtbGFiZWwnKTsNCiAgICBjb25zdCBuYW1lID0gcC5wcm9jIHx8IChwLnBpZCA/ICgnUElEICcgKyBwLnBpZCkgOiAnJyk7DQogICAgaWYgKGxhYmVsICYmIGxhYmVsLnRleHRDb250ZW50ICE9PSBuYW1lKSBsYWJlbC50ZXh0Q29udGVudCA9IG5hbWU7DQogICAgaWYgKGxhYmVsKSBsYWJlbC50aXRsZSA9IHAucGF0aCB8fCBuYW1lOw0KICAgIGNvbnN0IHNrID0gcHJvY0ljb25TdGFibGVLZXkocCk7DQogICAgbGV0IGljb24gPSBTdHJpbmcocC5pY29uIHx8ICcnKTsNCiAgICBpZiAoIWljb24gJiYgcHJvY0ljb25TdGFibGUuaGFzKHNrKSkNCiAgICAgIGljb24gPSBwcm9jSWNvblN0YWJsZS5nZXQoc2spOw0KICAgIHNldFByb2NJY29uRWwobmFtZUJveCwgaWNvbiwgc2spOw0KICAgIGNvbnN0IHNldFR4dCA9IChzZWwsIHZhbCwgdGl0bGUpID0+IHsNCiAgICAgIGNvbnN0IGVsID0gcm93LnF1ZXJ5U2VsZWN0b3Ioc2VsKTsNCiAgICAgIGlmICghZWwpIHJldHVybjsNCiAgICAgIGNvbnN0IHQgPSB2YWwgPT0gbnVsbCA/ICcnIDogU3RyaW5nKHZhbCk7DQogICAgICBpZiAoZWwudGV4dENvbnRlbnQgIT09IHQpIGVsLnRleHRDb250ZW50ID0gdDsNCiAgICAgIGlmICh0aXRsZSAhPSBudWxsKSBlbC50aXRsZSA9IHRpdGxlOw0KICAgIH07DQogICAgc2V0VHh0KCdbZGF0YS1mPSJjcHUiXScsIHAuY3B1IHx8ICcwJScpOw0KICAgIHNldFR4dCgnW2RhdGEtZj0ibWVtIl0nLCBwLm1lbSB8fCAnJyk7DQogICAgc2V0VHh0KCdbZGF0YS1mPSJwaWQiXScsIHAucGlkIHx8ICcnKTsNCiAgICBzZXRUeHQoJ1tkYXRhLWY9InByb3RvIl0nLCBwLnByb3RvIHx8ICcnKTsNCiAgICBzZXRUeHQoJ1tkYXRhLWY9ImxpcCJdJywgcC5sb2NhbElwIHx8ICcnLCBwLmxvY2FsSXAgfHwgJycpOw0KICAgIGNvbnN0IGxwb3J0ID0gcG9ydENlbGxUZXh0KHAubG9jYWxQb3J0KTsNCiAgICBzZXRUeHQoJ1tkYXRhLWY9Imxwb3J0Il0nLCBscG9ydCk7DQogICAgY29uc3QgbHBvcnRFbCA9IHJvdy5xdWVyeVNlbGVjdG9yKCdbZGF0YS1mPSJscG9ydCJdJyk7DQogICAgaWYgKGxwb3J0RWwpIGxwb3J0RWwuY2xhc3NMaXN0LnRvZ2dsZSgncG9ydC1ob3QnLCBwb3J0SXNIb3QocC5sb2NhbFBvcnQpICYmIGxwb3J0ICE9PSAnJyk7DQogICAgc2V0VHh0KCdbZGF0YS1mPSJyaXAiXScsIHAucmVtb3RlSXAgfHwgJycsIHAucmVtb3RlSXAgfHwgJycpOw0KICAgIGNvbnN0IHJwb3J0ID0gcG9ydENlbGxUZXh0KHAucmVtb3RlUG9ydCk7DQogICAgc2V0VHh0KCdbZGF0YS1mPSJycG9ydCJdJywgcnBvcnQpOw0KICAgIGNvbnN0IHJwb3J0RWwgPSByb3cucXVlcnlTZWxlY3RvcignW2RhdGEtZj0icnBvcnQiXScpOw0KICAgIGlmIChycG9ydEVsKSBycG9ydEVsLmNsYXNzTGlzdC50b2dnbGUoJ3BvcnQtaG90JywgcG9ydElzSG90KHAucmVtb3RlUG9ydCkgJiYgcnBvcnQgIT09ICcnKTsNCiAgICBjb25zdCBzdCA9IFN0cmluZyhwLnN0YXRlIHx8ICcnKTsNCiAgICBjb25zdCBzdGF0ZVR4dCA9IHJvdy5xdWVyeVNlbGVjdG9yKCcucHJvYy1zdGF0ZS10eHQnKTsNCiAgICBpZiAoc3RhdGVUeHQpIHsNCiAgICAgIGlmIChzdGF0ZVR4dC50ZXh0Q29udGVudCAhPT0gc3QpIHN0YXRlVHh0LnRleHRDb250ZW50ID0gc3Q7DQogICAgfSBlbHNlIHsNCiAgICAgIHNldFR4dCgnW2RhdGEtZj0ic3RhdGUiXScsIHN0KTsNCiAgICB9DQogICAgY29uc3QgbmV0RG90ID0gcm93LnF1ZXJ5U2VsZWN0b3IoJy5wcm9jLW5ldC1kb3QnKTsNCiAgICBpZiAobmV0RG90KSB7DQogICAgICBjb25zdCBjb25uZWN0ZWQgPSBzdCA9PT0gJ+i/nuaOpScgfHwgL2VzdGFibGlzaGVkL2kudGVzdChzdCk7DQogICAgICBuZXREb3QuY2xhc3NMaXN0LnRvZ2dsZSgnaGlkZGVuJywgIWNvbm5lY3RlZCk7DQogICAgfQ0KICAgIGNvbnN0IGNwdUVsID0gcm93LnF1ZXJ5U2VsZWN0b3IoJ1tkYXRhLWY9ImNwdSJdJyk7DQogICAgY29uc3QgbWVtRWwgPSByb3cucXVlcnlTZWxlY3RvcignW2RhdGEtZj0ibWVtIl0nKTsNCiAgICBjb25zdCBjcHVIb3QgPSAoTnVtYmVyKHAuY3B1TikgfHwgMCkgPiAxOw0KICAgIGNvbnN0IG1lbUhvdCA9IChOdW1iZXIocC5tZW1OKSB8fCAwKSA+ICg1MTIgKiAxMDI0ICogMTAyNCk7DQogICAgaWYgKGNwdUVsKSB7DQogICAgICBjcHVFbC5jbGFzc0xpc3QudG9nZ2xlKCdob3QnLCBjcHVIb3QpOw0KICAgICAgY3B1RWwuc3R5bGUuYmFja2dyb3VuZCA9IGhlYXRDb2xvcihjcHVIb3QpOw0KICAgIH0NCiAgICBpZiAobWVtRWwpIHsNCiAgICAgIG1lbUVsLmNsYXNzTGlzdC50b2dnbGUoJ2hvdCcsIG1lbUhvdCk7DQogICAgICBtZW1FbC5zdHlsZS5iYWNrZ3JvdW5kID0gaGVhdENvbG9yKG1lbUhvdCk7DQogICAgfQ0KICB9DQogIC8vIOWtl+avjeaOkuW6j++8muWQjOWtl+avjSBhL0Eg5oyo5Zyo5LiA6LW377yM5LiUIGEg5ZyoIEEg5YmN77yIYeKApkHigKZi4oCmQuKApu+8iQ0KICBmdW5jdGlvbiBwcm9jTmFtZVNvcnRSYW5rKGNoKSB7DQogICAgY29uc3QgYyA9IFN0cmluZyhjaCB8fCAnJyk7DQogICAgaWYgKCFjKSByZXR1cm4gMDsNCiAgICBjb25zdCBjb2RlID0gYy5jaGFyQ29kZUF0KDApOw0KICAgIGlmIChjb2RlID49IDY1ICYmIGNvZGUgPD0gOTApIHJldHVybiAoY29kZSAtIDY1KSAqIDIgKyAxOw0KICAgIGlmIChjb2RlID49IDk3ICYmIGNvZGUgPD0gMTIyKSByZXR1cm4gKGNvZGUgLSA5NykgKiAyOw0KICAgIHJldHVybiAyMDAwICsgY29kZTsNCiAgfQ0KICBmdW5jdGlvbiBjb21wYXJlUHJvY05hbWUoYSwgYikgew0KICAgIGNvbnN0IHNhID0gU3RyaW5nKGEgfHwgJycpOw0KICAgIGNvbnN0IHNiID0gU3RyaW5nKGIgfHwgJycpOw0KICAgIGNvbnN0IG4gPSBNYXRoLm1heChzYS5sZW5ndGgsIHNiLmxlbmd0aCk7DQogICAgZm9yIChsZXQgaSA9IDA7IGkgPCBuOyBpKyspIHsNCiAgICAgIGNvbnN0IGNhID0gc2FbaV0gfHwgJyc7DQogICAgICBjb25zdCBjYiA9IHNiW2ldIHx8ICcnOw0KICAgICAgaWYgKCFjYSkgcmV0dXJuIC0xOw0KICAgICAgaWYgKCFjYikgcmV0dXJuIDE7DQogICAgICBjb25zdCBsYSA9IGNhLnRvTG93ZXJDYXNlKCk7DQogICAgICBjb25zdCBsYiA9IGNiLnRvTG93ZXJDYXNlKCk7DQogICAgICBpZiAoL1thLXpdL2kudGVzdChjYSkgJiYgL1thLXpdL2kudGVzdChjYikpIHsNCiAgICAgICAgaWYgKGxhICE9PSBsYikgcmV0dXJuIGxhIDwgbGIgPyAtMSA6IDE7DQogICAgICAgIGNvbnN0IHJhID0gcHJvY05hbWVTb3J0UmFuayhjYSk7DQogICAgICAgIGNvbnN0IHJiID0gcHJvY05hbWVTb3J0UmFuayhjYik7DQogICAgICAgIGlmIChyYSAhPT0gcmIpIHJldHVybiByYSAtIHJiOw0KICAgICAgICBjb250aW51ZTsNCiAgICAgIH0NCiAgICAgIGNvbnN0IGNtcCA9IGNhLmxvY2FsZUNvbXBhcmUoY2IsICd6aC1DTicsIHsgbnVtZXJpYzogdHJ1ZSwgc2Vuc2l0aXZpdHk6ICd2YXJpYW50JyB9KTsNCiAgICAgIGlmIChjbXApIHJldHVybiBjbXA7DQogICAgfQ0KICAgIHJldHVybiAwOw0KICB9DQogIGZ1bmN0aW9uIHNvcnRQcm9jUm93c0ZsYXQoaXRlbXMpIHsNCiAgICBjb25zdCBkaXIgPSBwcm9jU29ydERpcjsNCiAgICBjb25zdCBrZXkgPSBwcm9jU29ydEtleTsNCiAgICByZXR1cm4gaXRlbXMuc2xpY2UoKS5zb3J0KChhLCBiKSA9PiB7DQogICAgICBsZXQgY21wID0gMDsNCiAgICAgIHN3aXRjaCAoa2V5KSB7DQogICAgICAgIGNhc2UgJ2NwdSc6DQogICAgICAgICAgY21wID0gKE51bWJlcihhLmNwdU4pIHx8IDApIC0gKE51bWJlcihiLmNwdU4pIHx8IDApOw0KICAgICAgICAgIGJyZWFrOw0KICAgICAgICBjYXNlICdtZW0nOg0KICAgICAgICAgIGNtcCA9IChOdW1iZXIoYS5tZW1OKSB8fCAwKSAtIChOdW1iZXIoYi5tZW1OKSB8fCAwKTsNCiAgICAgICAgICBicmVhazsNCiAgICAgICAgY2FzZSAncGlkJzoNCiAgICAgICAgICBjbXAgPSAoTnVtYmVyKGEucGlkKSB8fCAwKSAtIChOdW1iZXIoYi5waWQpIHx8IDApOw0KICAgICAgICAgIGJyZWFrOw0KICAgICAgICBjYXNlICdwcm90byc6DQogICAgICAgICAgY21wID0gU3RyaW5nKGEucHJvdG8gfHwgJycpLmxvY2FsZUNvbXBhcmUoU3RyaW5nKGIucHJvdG8gfHwgJycpLCAnZW4nKTsNCiAgICAgICAgICBicmVhazsNCiAgICAgICAgY2FzZSAnbGlwJzoNCiAgICAgICAgICBjbXAgPSBTdHJpbmcoYS5sb2NhbElwIHx8ICcnKS5sb2NhbGVDb21wYXJlKFN0cmluZyhiLmxvY2FsSXAgfHwgJycpLCAnZW4nLCB7IG51bWVyaWM6IHRydWUgfSk7DQogICAgICAgICAgYnJlYWs7DQogICAgICAgIGNhc2UgJ2xwb3J0JzoNCiAgICAgICAgICBjbXAgPSAoTnVtYmVyKGEubG9jYWxQb3J0KSB8fCAwKSAtIChOdW1iZXIoYi5sb2NhbFBvcnQpIHx8IDApOw0KICAgICAgICAgIGJyZWFrOw0KICAgICAgICBjYXNlICdyaXAnOg0KICAgICAgICAgIGNtcCA9IFN0cmluZyhhLnJlbW90ZUlwIHx8ICcnKS5sb2NhbGVDb21wYXJlKFN0cmluZyhiLnJlbW90ZUlwIHx8ICcnKSwgJ2VuJywgeyBudW1lcmljOiB0cnVlIH0pOw0KICAgICAgICAgIGJyZWFrOw0KICAgICAgICBjYXNlICdycG9ydCc6DQogICAgICAgICAgY21wID0gKE51bWJlcihhLnJlbW90ZVBvcnQpIHx8IDApIC0gKE51bWJlcihiLnJlbW90ZVBvcnQpIHx8IDApOw0KICAgICAgICAgIGJyZWFrOw0KICAgICAgICBjYXNlICdzdGF0ZSc6DQogICAgICAgICAgY21wID0gU3RyaW5nKGEuc3RhdGUgfHwgJycpLmxvY2FsZUNvbXBhcmUoU3RyaW5nKGIuc3RhdGUgfHwgJycpLCAnemgtQ04nKTsNCiAgICAgICAgICBicmVhazsNCiAgICAgICAgY2FzZSAnbmFtZSc6DQogICAgICAgIGRlZmF1bHQ6DQogICAgICAgICAgY21wID0gY29tcGFyZVByb2NOYW1lKGEucHJvYyB8fCAnJywgYi5wcm9jIHx8ICcnKTsNCiAgICAgICAgICBicmVhazsNCiAgICAgIH0NCiAgICAgIGlmICghY21wICYmIGtleSAhPT0gJ25hbWUnKQ0KICAgICAgICBjbXAgPSBjb21wYXJlUHJvY05hbWUoYS5wcm9jIHx8ICcnLCBiLnByb2MgfHwgJycpOw0KICAgICAgaWYgKCFjbXApDQogICAgICAgIGNtcCA9IChOdW1iZXIoYS5waWQpIHx8IDApIC0gKE51bWJlcihiLnBpZCkgfHwgMCk7DQogICAgICBpZiAoIWNtcCkNCiAgICAgICAgY21wID0gKE51bWJlcihhLmxvY2FsUG9ydCkgfHwgMCkgLSAoTnVtYmVyKGIubG9jYWxQb3J0KSB8fCAwKTsNCiAgICAgIHJldHVybiBjbXAgKiBkaXI7DQogICAgfSk7DQogIH0NCiAgZnVuY3Rpb24gcmVmcmVzaFByb2NTb3J0SGVhZGVycygpIHsNCiAgICBpZiAoIXByb2NIZWFkKSByZXR1cm47DQogICAgcHJvY0hlYWQucXVlcnlTZWxlY3RvckFsbCgnLnByb2MtaGNlbGxbZGF0YS1zb3J0XScpLmZvckVhY2goY2VsbCA9PiB7DQogICAgICBjb25zdCBrID0gY2VsbC5nZXRBdHRyaWJ1dGUoJ2RhdGEtc29ydCcpOw0KICAgICAgY29uc3Qgb24gPSBrID09PSBwcm9jU29ydEtleTsNCiAgICAgIGNlbGwuY2xhc3NMaXN0LnRvZ2dsZSgnc29ydGVkJywgb24pOw0KICAgICAgY2VsbC5jbGFzc0xpc3QudG9nZ2xlKCdhc2MnLCBvbiAmJiBwcm9jU29ydERpciA+IDApOw0KICAgICAgY2VsbC5jbGFzc0xpc3QudG9nZ2xlKCdkZXNjJywgb24gJiYgcHJvY1NvcnREaXIgPCAwKTsNCiAgICB9KTsNCiAgfQ0KICBpZiAocHJvY0hlYWQpIHsNCiAgICBwcm9jSGVhZC5xdWVyeVNlbGVjdG9yQWxsKCcucHJvYy1oY2VsbFtkYXRhLXNvcnRdJykuZm9yRWFjaChjZWxsID0+IHsNCiAgICAgIGNlbGwuYWRkRXZlbnRMaXN0ZW5lcignY2xpY2snLCAoZSkgPT4gew0KICAgICAgICBlLnByZXZlbnREZWZhdWx0KCk7DQogICAgICAgIGNvbnN0IGsgPSBjZWxsLmdldEF0dHJpYnV0ZSgnZGF0YS1zb3J0Jyk7DQogICAgICAgIGlmICghaykgcmV0dXJuOw0KICAgICAgICBpZiAocHJvY1NvcnRLZXkgPT09IGspIHByb2NTb3J0RGlyID0gLXByb2NTb3J0RGlyOw0KICAgICAgICBlbHNlIHsNCiAgICAgICAgICBwcm9jU29ydEtleSA9IGs7DQogICAgICAgICAgLy8g6LWE5rqQ5YiX6buY6K6k6auY4oaS5L2O77yM5ZCN56ew6buY6K6kIGHihpJ6DQogICAgICAgICAgcHJvY1NvcnREaXIgPSAoayA9PT0gJ2NwdScgfHwgayA9PT0gJ21lbScgfHwgayA9PT0gJ2xwb3J0JyB8fCBrID09PSAncnBvcnQnKSA/IC0xIDogMTsNCiAgICAgICAgfQ0KICAgICAgICByZWZyZXNoUHJvY1NvcnRIZWFkZXJzKCk7DQogICAgICAgIHJlbmRlclByb2NUYWJsZSgpOw0KICAgICAgfSk7DQogICAgfSk7DQogICAgcmVmcmVzaFByb2NTb3J0SGVhZGVycygpOw0KICB9DQogIGZ1bmN0aW9uIHBhdGNoUHJvY0ljb25zKGl0ZW1zKSB7DQogICAgbGV0IHBhdGNoZWQgPSAwOw0KICAgIGZvciAoY29uc3QgcCBvZiBpdGVtcyB8fCBbXSkgew0KICAgICAgaWYgKCFwIHx8ICFwLmljb24pIGNvbnRpbnVlOw0KICAgICAgY29uc3Qga2V5ID0gcHJvY1Jvd0tleShwKTsNCiAgICAgIGNvbnN0IHJvdyA9IHByb2NSb3dNYXAuZ2V0KGtleSkgfHwgcHJvY0JvZHkucXVlcnlTZWxlY3RvcignLnByb2Mtcm93W2RhdGEta2V5PSInICsgQ1NTLmVzY2FwZShrZXkpICsgJyJdJyk7DQogICAgICBpZiAoIXJvdykgY29udGludWU7DQogICAgICBjb25zdCBuYW1lQm94ID0gcm93LnF1ZXJ5U2VsZWN0b3IoJy5wcm9jLW5hbWUnKTsNCiAgICAgIHNldFByb2NJY29uRWwobmFtZUJveCwgcC5pY29uLCBwcm9jSWNvblN0YWJsZUtleShwKSk7DQogICAgICBwYXRjaGVkKys7DQogICAgfQ0KICAgIHJldHVybiBwYXRjaGVkID4gMCB8fCBwcm9jUm93TWFwLnNpemUgPiAwOw0KICB9DQogIGZ1bmN0aW9uIHNlbGVjdFByb2NOYW1lR3JvdXAocm93LCBhZGRpdGl2ZSkgew0KICAgIGNvbnN0IGtleSA9IHJvdy5nZXRBdHRyaWJ1dGUoJ2RhdGEta2V5Jyk7DQogICAgaWYgKCFhZGRpdGl2ZSkgcHJvY1NlbEtleXMuY2xlYXIoKTsNCiAgICBwcm9jU2VsS2V5cy5hZGQoa2V5KTsNCiAgICBwcm9jQW5jaG9yS2V5ID0ga2V5Ow0KICAgIHByb2NTZWxLZXkgPSBrZXk7DQogICAgcHJvY1NlbFBpZCA9IE51bWJlcihyb3cuZ2V0QXR0cmlidXRlKCdkYXRhLXBpZCcpKSB8fCAwOw0KICAgIHJlZnJlc2hQcm9jU2VsZWN0aW9uVUkoKTsNCiAgfQ0KICBmdW5jdGlvbiBzZWxlY3RQcm9jRnJvbUV2ZW50KGUsIHJvdykgew0KICAgIGNvbnN0IGtleSA9IHJvdy5nZXRBdHRyaWJ1dGUoJ2RhdGEta2V5Jyk7DQogICAgY29uc3QgcGlkID0gTnVtYmVyKHJvdy5nZXRBdHRyaWJ1dGUoJ2RhdGEtcGlkJykpIHx8IDA7DQogICAgY29uc3Qgcm93cyA9IEFycmF5LmZyb20ocHJvY0JvZHkucXVlcnlTZWxlY3RvckFsbCgnLnByb2Mtcm93JykpOw0KICAgIGNvbnN0IGlkeCA9IHJvd3MuaW5kZXhPZihyb3cpOw0KICAgIGlmIChlLnNoaWZ0S2V5ICYmIHByb2NBbmNob3JLZXkpIHsNCiAgICAgIGNvbnN0IGFJZHggPSByb3dzLmZpbmRJbmRleChyID0+IHIuZ2V0QXR0cmlidXRlKCdkYXRhLWtleScpID09PSBwcm9jQW5jaG9yS2V5KTsNCiAgICAgIGlmIChhSWR4ID49IDAgJiYgaWR4ID49IDApIHsNCiAgICAgICAgaWYgKCFlLmN0cmxLZXkpIHByb2NTZWxLZXlzLmNsZWFyKCk7DQogICAgICAgIGNvbnN0IGxvID0gTWF0aC5taW4oYUlkeCwgaWR4KSwgaGkgPSBNYXRoLm1heChhSWR4LCBpZHgpOw0KICAgICAgICBmb3IgKGxldCBpID0gbG87IGkgPD0gaGk7IGkrKykgcHJvY1NlbEtleXMuYWRkKHJvd3NbaV0uZ2V0QXR0cmlidXRlKCdkYXRhLWtleScpKTsNCiAgICAgIH0NCiAgICAgIHByb2NTZWxLZXkgPSBrZXk7DQogICAgICBwcm9jU2VsUGlkID0gcGlkOw0KICAgICAgcmVmcmVzaFByb2NTZWxlY3Rpb25VSSgpOw0KICAgICAgcmV0dXJuOw0KICAgIH0NCiAgICBpZiAoZS5jdHJsS2V5KSB7DQogICAgICBpZiAocHJvY1NlbEtleXMuaGFzKGtleSkpIHByb2NTZWxLZXlzLmRlbGV0ZShrZXkpOw0KICAgICAgZWxzZSBwcm9jU2VsS2V5cy5hZGQoa2V5KTsNCiAgICAgIHByb2NBbmNob3JLZXkgPSBrZXk7DQogICAgICBwcm9jU2VsS2V5ID0ga2V5Ow0KICAgICAgcHJvY1NlbFBpZCA9IHBpZDsNCiAgICAgIHJlZnJlc2hQcm9jU2VsZWN0aW9uVUkoKTsNCiAgICAgIHJldHVybjsNCiAgICB9DQogICAgLy8g5pmu6YCa5Y2V5Ye777ya5Y+q57uZ54K55Lit55qE6KGM5bqV6Imy77yb5ZCM5ZCN5pW05q6155S75reh57u/5aSW5qGGDQogICAgc2VsZWN0UHJvY05hbWVHcm91cChyb3csIGZhbHNlKTsNCiAgfQ0KICBmdW5jdGlvbiByZWZyZXNoUHJvY1NlbGVjdGlvblVJKCkgew0KICAgIGNvbnN0IHJvd3MgPSBBcnJheS5mcm9tKHByb2NCb2R5LnF1ZXJ5U2VsZWN0b3JBbGwoJy5wcm9jLXJvdycpKTsNCiAgICBjb25zdCBHUlAgPSBbJ29uJywgJ2dycCcsICdncnAtZmlyc3QnLCAnZ3JwLW1pZCcsICdncnAtbGFzdCcsICdncnAtb25seSddOw0KICAgIGNvbnN0IHNlbGVjdGVkTmFtZXMgPSBuZXcgU2V0KCk7DQogICAgcm93cy5mb3JFYWNoKHJvdyA9PiB7DQogICAgICBHUlAuZm9yRWFjaChjID0+IHJvdy5jbGFzc0xpc3QucmVtb3ZlKGMpKTsNCiAgICAgIGNvbnN0IGtleSA9IHJvdy5nZXRBdHRyaWJ1dGUoJ2RhdGEta2V5Jyk7DQogICAgICBpZiAocHJvY1NlbEtleXMuaGFzKGtleSkpIHsNCiAgICAgICAgcm93LmNsYXNzTGlzdC5hZGQoJ29uJyk7DQogICAgICAgIGNvbnN0IG5hbWUgPSBTdHJpbmcocm93LmdldEF0dHJpYnV0ZSgnZGF0YS1uYW1lJykgfHwgJycpLnRvTG93ZXJDYXNlKCk7DQogICAgICAgIGlmIChuYW1lKSBzZWxlY3RlZE5hbWVzLmFkZChuYW1lKTsNCiAgICAgIH0NCiAgICB9KTsNCiAgICAvLyDmjInpgInkuK3ooYznmoTov5vnqIvlkI3vvIzmiorlkIzlkI3ov57nu63mrrXljIXmt6Hnu7/lpJbmoYbvvIjml6DlupXoibLvvIkNCiAgICBsZXQgaSA9IDA7DQogICAgd2hpbGUgKGkgPCByb3dzLmxlbmd0aCkgew0KICAgICAgY29uc3QgbmFtZSA9IFN0cmluZyhyb3dzW2ldLmdldEF0dHJpYnV0ZSgnZGF0YS1uYW1lJykgfHwgJycpLnRvTG93ZXJDYXNlKCk7DQogICAgICBpZiAoIW5hbWUgfHwgIXNlbGVjdGVkTmFtZXMuaGFzKG5hbWUpKSB7DQogICAgICAgIGkrKzsNCiAgICAgICAgY29udGludWU7DQogICAgICB9DQogICAgICBsZXQgaiA9IGk7DQogICAgICB3aGlsZSAoaiArIDEgPCByb3dzLmxlbmd0aA0KICAgICAgICAmJiBTdHJpbmcocm93c1tqICsgMV0uZ2V0QXR0cmlidXRlKCdkYXRhLW5hbWUnKSB8fCAnJykudG9Mb3dlckNhc2UoKSA9PT0gbmFtZSkgew0KICAgICAgICBqKys7DQogICAgICB9DQogICAgICBmb3IgKGxldCBrID0gaTsgayA8PSBqOyBrKyspIHsNCiAgICAgICAgcm93c1trXS5jbGFzc0xpc3QuYWRkKCdncnAnKTsNCiAgICAgICAgaWYgKGkgPT09IGopIHJvd3Nba10uY2xhc3NMaXN0LmFkZCgnZ3JwLW9ubHknKTsNCiAgICAgICAgZWxzZSBpZiAoayA9PT0gaSkgcm93c1trXS5jbGFzc0xpc3QuYWRkKCdncnAtZmlyc3QnKTsNCiAgICAgICAgZWxzZSBpZiAoayA9PT0gaikgcm93c1trXS5jbGFzc0xpc3QuYWRkKCdncnAtbGFzdCcpOw0KICAgICAgICBlbHNlIHJvd3Nba10uY2xhc3NMaXN0LmFkZCgnZ3JwLW1pZCcpOw0KICAgICAgfQ0KICAgICAgaSA9IGogKyAxOw0KICAgIH0NCiAgfQ0KICBmdW5jdGlvbiBjb2xsZWN0UHJvY1RhcmdldHMoKSB7DQogICAgY29uc3QgbWFwID0gbmV3IE1hcCgpOw0KICAgIGZvciAoY29uc3Qga2V5IG9mIHByb2NTZWxLZXlzKSB7DQogICAgICBjb25zdCByb3cgPSBwcm9jUm93TWFwLmdldChrZXkpIHx8IHByb2NCb2R5LnF1ZXJ5U2VsZWN0b3IoJy5wcm9jLXJvd1tkYXRhLWtleT0iJyArIENTUy5lc2NhcGUoa2V5KSArICciXScpOw0KICAgICAgbGV0IHBpZCA9IDAsIG5hbWUgPSAnJywgcGF0aCA9ICcnOw0KICAgICAgaWYgKHJvdykgew0KICAgICAgICBwaWQgPSBOdW1iZXIocm93LmdldEF0dHJpYnV0ZSgnZGF0YS1waWQnKSkgfHwgMDsNCiAgICAgICAgbmFtZSA9IHJvdy5nZXRBdHRyaWJ1dGUoJ2RhdGEtbmFtZScpIHx8ICcnOw0KICAgICAgICBwYXRoID0gcm93LmdldEF0dHJpYnV0ZSgnZGF0YS1wYXRoJykgfHwgJyc7DQogICAgICB9IGVsc2Ugew0KICAgICAgICBjb25zdCBwID0gcHJvY0l0ZW1zLmZpbmQoeCA9PiBwcm9jUm93S2V5KHgpID09PSBrZXkpOw0KICAgICAgICBpZiAoIXApIGNvbnRpbnVlOw0KICAgICAgICBwaWQgPSBOdW1iZXIocC5waWQpIHx8IDA7DQogICAgICAgIG5hbWUgPSBwLnByb2MgfHwgJyc7DQogICAgICAgIHBhdGggPSBwLnBhdGggfHwgJyc7DQogICAgICB9DQogICAgICBpZiAocGlkIDw9IDAgfHwgbWFwLmhhcyhwaWQpKSBjb250aW51ZTsNCiAgICAgIGlmICghcGF0aCkgew0KICAgICAgICBjb25zdCBwID0gcHJvY0l0ZW1zLmZpbmQoeCA9PiBOdW1iZXIoeC5waWQpID09PSBwaWQgJiYgeC5wYXRoKTsNCiAgICAgICAgaWYgKHApIHBhdGggPSBwLnBhdGggfHwgJyc7DQogICAgICB9DQogICAgICBtYXAuc2V0KHBpZCwgeyBwaWQsIG5hbWUsIHBhdGggfSk7DQogICAgfQ0KICAgIHJldHVybiBBcnJheS5mcm9tKG1hcC52YWx1ZXMoKSk7DQogIH0NCiAgZnVuY3Rpb24gcmVuZGVyUHJvY1RhYmxlKCkgew0KICAgIGNvbnN0IHEgPSAocHJvY1EudmFsdWUgfHwgJycpLnRyaW0oKS50b0xvd2VyQ2FzZSgpOw0KICAgIGxldCByb3dzID0gcHJvY0l0ZW1zLnNsaWNlKCk7DQogICAgaWYgKHEpIHsNCiAgICAgIHJvd3MgPSByb3dzLmZpbHRlcihwID0+IHsNCiAgICAgICAgY29uc3QgaGF5ID0gW3AucHJvdG8sIHAubG9jYWxJcCwgcC5sb2NhbFBvcnQsIHAucmVtb3RlSXAsIHAucmVtb3RlUG9ydCwgcC5zdGF0ZSwgcC5wcm9jLCBwLnBpZCwgcC5wcGlkXS5qb2luKCcgJykudG9Mb3dlckNhc2UoKTsNCiAgICAgICAgcmV0dXJuIGhheS5pbmNsdWRlcyhxKTsNCiAgICAgIH0pOw0KICAgIH0NCiAgICByb3dzID0gc29ydFByb2NSb3dzRmxhdChyb3dzKTsNCiAgICBjb25zdCBwaWRTZXQgPSBuZXcgU2V0KCk7DQogICAgZm9yIChjb25zdCBwIG9mIHJvd3MpIHsNCiAgICAgIGNvbnN0IGlkID0gTnVtYmVyKHAucGlkKSB8fCAwOw0KICAgICAgaWYgKGlkID4gMCkgcGlkU2V0LmFkZChpZCk7DQogICAgfQ0KICAgIHByb2NDb3VudC50ZXh0Q29udGVudCA9IFN0cmluZyhwaWRTZXQuc2l6ZSB8fCByb3dzLmxlbmd0aCk7DQogICAgaWYgKCFyb3dzLmxlbmd0aCkgew0KICAgICAgcHJvY0JvZHkuaW5uZXJIVE1MID0gJzxkaXYgc3R5bGU9InBhZGRpbmc6MjRweDt0ZXh0LWFsaWduOmNlbnRlcjtjb2xvcjojOWFhMWIyIj7msqHmnInljLnphY3nmoTov57mjqU8L2Rpdj4nOw0KICAgICAgcHJvY1Jvd01hcC5jbGVhcigpOw0KICAgICAgcHJvY1NlbEtleXMuY2xlYXIoKTsNCiAgICAgIHByb2NBbmNob3JLZXkgPSAnJzsNCiAgICAgIHByb2NTZWxLZXkgPSAnJzsNCiAgICAgIHByb2NTZWxQaWQgPSAwOw0KICAgICAgcmV0dXJuOw0KICAgIH0NCiAgICAvLyDlop7ph4/mm7TmlrDvvJrlpI3nlKjooYzkuI7lm77moIfoioLngrnvvIzlj6rmlLnmloflrZfvvIzpgb/lhY3mlbTooajph43lu7rpl6rlm77moIcNCiAgICBjb25zdCBrZWVwID0gbmV3IFNldCgpOw0KICAgIGNvbnN0IGVtcHR5SGludCA9IHByb2NCb2R5LnF1ZXJ5U2VsZWN0b3IoJ2RpdltzdHlsZV0nKTsNCiAgICBpZiAoZW1wdHlIaW50KSB7DQogICAgICBwcm9jQm9keS5pbm5lckhUTUwgPSAnJzsNCiAgICAgIHByb2NSb3dNYXAuY2xlYXIoKTsNCiAgICB9DQogICAgZm9yIChsZXQgaSA9IDA7IGkgPCByb3dzLmxlbmd0aDsgaSsrKSB7DQogICAgICBjb25zdCBwID0gcm93c1tpXTsNCiAgICAgIGNvbnN0IGtleSA9IHByb2NSb3dLZXkocCk7DQogICAgICBrZWVwLmFkZChrZXkpOw0KICAgICAgbGV0IHJvdyA9IHByb2NSb3dNYXAuZ2V0KGtleSk7DQogICAgICBpZiAoIXJvdyB8fCAhcm93LmlzQ29ubmVjdGVkKSB7DQogICAgICAgIHJvdyA9IGVuc3VyZVByb2NSb3cocCk7DQogICAgICAgIHByb2NSb3dNYXAuc2V0KGtleSwgcm93KTsNCiAgICAgIH0NCiAgICAgIHVwZGF0ZVByb2NSb3dEYXRhKHJvdywgcCk7DQogICAgICBjb25zdCBhdCA9IHByb2NCb2R5LmNoaWxkcmVuW2ldOw0KICAgICAgaWYgKGF0ICE9PSByb3cpIHsNCiAgICAgICAgaWYgKGF0KSBwcm9jQm9keS5pbnNlcnRCZWZvcmUocm93LCBhdCk7DQogICAgICAgIGVsc2UgcHJvY0JvZHkuYXBwZW5kQ2hpbGQocm93KTsNCiAgICAgIH0NCiAgICB9DQogICAgLy8g5Yig5o6J5LiN5YaN5a2Y5Zyo55qE6KGMDQogICAgZm9yIChjb25zdCBba2V5LCByb3ddIG9mIEFycmF5LmZyb20ocHJvY1Jvd01hcC5lbnRyaWVzKCkpKSB7DQogICAgICBpZiAoa2VlcC5oYXMoa2V5KSkgY29udGludWU7DQogICAgICBwcm9jUm93TWFwLmRlbGV0ZShrZXkpOw0KICAgICAgaWYgKHJvdyAmJiByb3cucGFyZW50Tm9kZSkgcm93LnBhcmVudE5vZGUucmVtb3ZlQ2hpbGQocm93KTsNCiAgICB9DQogICAgZm9yIChjb25zdCBrZXkgb2YgQXJyYXkuZnJvbShwcm9jU2VsS2V5cykpIHsNCiAgICAgIGlmICgha2VlcC5oYXMoa2V5KSkgcHJvY1NlbEtleXMuZGVsZXRlKGtleSk7DQogICAgfQ0KICAgIGlmIChwcm9jU2VsS2V5ICYmICFwcm9jU2VsS2V5cy5oYXMocHJvY1NlbEtleSkpIHsNCiAgICAgIHByb2NTZWxLZXkgPSBwcm9jU2VsS2V5cy5zaXplID8gQXJyYXkuZnJvbShwcm9jU2VsS2V5cylbMF0gOiAnJzsNCiAgICAgIHByb2NTZWxQaWQgPSAwOw0KICAgICAgaWYgKHByb2NTZWxLZXkpIHsNCiAgICAgICAgY29uc3QgciA9IHByb2NSb3dNYXAuZ2V0KHByb2NTZWxLZXkpOw0KICAgICAgICBwcm9jU2VsUGlkID0gciA/IChOdW1iZXIoci5nZXRBdHRyaWJ1dGUoJ2RhdGEtcGlkJykpIHx8IDApIDogMDsNCiAgICAgIH0NCiAgICB9DQogICAgcmVmcmVzaFByb2NTZWxlY3Rpb25VSSgpOw0KICB9DQogIGZ1bmN0aW9uIGluZm9Sb3cobGFiLCB2YWxIdG1sLCBsaW5rSHRtbCkgew0KICAgIHJldHVybiAnPGRpdiBjbGFzcz0iaW5mby1yb3ciPicNCiAgICAgICsgJzxkaXYgY2xhc3M9ImluZm8tbGFiIj4nICsgZXNjYXBlSHRtbChsYWIpICsgJzwvZGl2PicNCiAgICAgICsgJzxkaXYgY2xhc3M9ImluZm8tZGFzaCI+PC9kaXY+Jw0KICAgICAgKyAnPGRpdiBjbGFzcz0iaW5mby12YWwiPicgKyAodmFsSHRtbCB8fCAnJykgKyAnPC9kaXY+Jw0KICAgICAgKyAobGlua0h0bWwgfHwgJzxzcGFuPjwvc3Bhbj4nKQ0KICAgICAgKyAnPC9kaXY+JzsNCiAgfQ0KICBmdW5jdGlvbiByZW5kZXJTeXNJbmZvKCkgew0KICAgIGNvbnN0IGQgPSBpbmZvRGF0YSB8fCB7fTsNCiAgICBsZXQgaHRtbCA9ICcnOw0KICAgIGh0bWwgKz0gaW5mb1Jvdygn5pON5L2c57O757ufJywgZXNjYXBlSHRtbChkLm9zIHx8ICfmnKrnn6UnKSk7DQogICAgaHRtbCArPSBpbmZvUm93KCfkuLvmnb8nLCBlc2NhcGVIdG1sKGQuYm9hcmQgfHwgJ+acquefpScpKTsNCiAgICBodG1sICs9IGluZm9Sb3coJ+aYvuekuuWZqCcsIGVzY2FwZUh0bWwoZC5tb25pdG9yIHx8ICfmnKrnn6UnKSk7DQogICAgaHRtbCArPSBpbmZvUm93KCflpITnkIblmagnLCBlc2NhcGVIdG1sKGQuY3B1IHx8ICfmnKrnn6UnKSk7DQogICAgaHRtbCArPSBpbmZvUm93KCflhoXlrZgnLCBlc2NhcGVIdG1sKGQubWVtb3J5IHx8ICfmnKrnn6UnKSk7DQogICAgaHRtbCArPSBpbmZvUm93KCfnoaznm5gnLCBlc2NhcGVIdG1sKGQuZGlzayB8fCAn5pyq55+lJykpOw0KICAgIGh0bWwgKz0gaW5mb1Jvdygn5pi+5Y2hJywgZXNjYXBlSHRtbChkLmdwdSB8fCAn5pyq55+lJykpOw0KICAgIGNvbnN0IHNvdW5kcyA9IEFycmF5LmlzQXJyYXkoZC5zb3VuZCkgPyBkLnNvdW5kIDogW107DQogICAgaHRtbCArPSBpbmZvUm93KCflo7DljaEnLCBzb3VuZHMubGVuZ3RoDQogICAgICA/IHNvdW5kcy5tYXAocyA9PiAnPHNwYW4gY2xhc3M9ImxpbmUiPicgKyBlc2NhcGVIdG1sKHMpICsgJzwvc3Bhbj4nKS5qb2luKCcnKQ0KICAgICAgOiBlc2NhcGVIdG1sKCfmnKrnn6UnKSk7DQogICAgY29uc3QgbmV0cyA9IEFycmF5LmlzQXJyYXkoZC5uaWNzKSA/IGQubmljcyA6IFtdOw0KICAgIGxldCBuZXRIdG1sID0gJ+acquefpSc7DQogICAgaWYgKG5ldHMubGVuZ3RoKSB7DQogICAgICBuZXRIdG1sID0gbmV0cy5tYXAobiA9PiB7DQogICAgICAgIGNvbnN0IG5hbWUgPSBlc2NhcGVIdG1sKG4ubmFtZSB8fCAnJyk7DQogICAgICAgIGNvbnN0IG1hYyA9IGVzY2FwZUh0bWwobi5tYWMgfHwgJ+KAlCcpOw0KICAgICAgICBjb25zdCBpcFJhdyA9IChuLmlwICYmIFN0cmluZyhuLmlwKS50cmltKCkpID8gU3RyaW5nKG4uaXApLnRyaW0oKSA6ICcwLjAuMC4wJzsNCiAgICAgICAgY29uc3QgaXAgPSBlc2NhcGVIdG1sKGlwUmF3ID09PSAn4oCUJyA/ICcwLjAuMC4wJyA6IGlwUmF3KTsNCiAgICAgICAgcmV0dXJuICc8ZGl2IGNsYXNzPSJuZXQtbGluZSI+PHNwYW4+JyArIG5hbWUgKyAnPC9zcGFuPicNCiAgICAgICAgICArICc8c3Bhbj48c3BhbiBjbGFzcz0iayI+TUFD5Zyw5Z2AOiA8L3NwYW4+JyArIG1hYyArICc8L3NwYW4+Jw0KICAgICAgICAgICsgJzxzcGFuPjxzcGFuIGNsYXNzPSJrIj5JUOWcsOWdgDogPC9zcGFuPicgKyBpcCArICc8L3NwYW4+PC9kaXY+JzsNCiAgICAgIH0pLmpvaW4oJycpOw0KICAgIH0NCiAgICBodG1sICs9IGluZm9Sb3coJ+e9keWNoScsIG5ldEh0bWwpOw0KICAgIGh0bWwgKz0gaW5mb1Jvdygn5aSW572RSVAnLCBlc2NhcGVIdG1sKGQud2FuIHx8ICfmnKrnn6UnKSk7DQogICAgaHRtbCArPSBpbmZvUm93KCdJReeJiOacrCcsIGVzY2FwZUh0bWwoZC5pZSB8fCAn5pyq55+lJykpOw0KICAgIGh0bWwgKz0gaW5mb1JvdygnRmxhc2jniYjmnKwnLCBlc2NhcGVIdG1sKGQuZmxhc2ggfHwgJ+acquefpScpKTsNCiAgICBjb25zdCBib290RXh0cmEgPSAnPHNwYW4gY2xhc3M9InN1YiI+57O757uf5bey6L+Q6KGMOiA8c3BhbiBpZD0iaW5mby11cHRpbWUiPicNCiAgICAgICsgZXNjYXBlSHRtbChmb3JtYXRVcHRpbWVUZXh0KGN1cnJlbnRVcHRpbWVTZWMoKSkpICsgJzwvc3Bhbj48L3NwYW4+JzsNCiAgICBodG1sICs9IGluZm9Sb3coJ+W8gOacuuaXtumXtCcsIGVzY2FwZUh0bWwoZC5ib290IHx8ICfmnKrnn6UnKSArIGJvb3RFeHRyYSk7DQogICAgaHRtbCArPSBpbmZvUm93KCfkuIrmrKHlhbPmnLrml7bpl7QnLCBlc2NhcGVIdG1sKGQuc2h1dGRvd24gfHwgJ+acquefpScpKTsNCiAgICBodG1sICs9IGluZm9Sb3coJ+ezu+e7n+WuieijheaXpeacnycsIGVzY2FwZUh0bWwoZC5pbnN0YWxsIHx8ICfmnKrnn6UnKSk7DQogICAgaW5mb1BhbmVsLmlubmVySFRNTCA9IGh0bWw7DQogIH0NCiAgZnVuY3Rpb24gY3VycmVudFVwdGltZVNlYygpIHsNCiAgICBjb25zdCBiYXNlID0gTnVtYmVyKGluZm9EYXRhICYmIGluZm9EYXRhLnVwdGltZVNlYykgfHwgMDsNCiAgICBjb25zdCBzeW5jZWQgPSBOdW1iZXIoaW5mb0RhdGEgJiYgaW5mb0RhdGEuX3N5bmNlZEF0KSB8fCBEYXRlLm5vdygpOw0KICAgIHJldHVybiBNYXRoLm1heCgwLCBNYXRoLmZsb29yKGJhc2UgKyAoRGF0ZS5ub3coKSAtIHN5bmNlZCkgLyAxMDAwKSk7DQogIH0NCiAgZnVuY3Rpb24gZm9ybWF0VXB0aW1lVGV4dChzZWMpIHsNCiAgICBzZWMgPSBNYXRoLm1heCgwLCBNYXRoLmZsb29yKE51bWJlcihzZWMpIHx8IDApKTsNCiAgICBjb25zdCBkID0gTWF0aC5mbG9vcihzZWMgLyA4NjQwMCk7DQogICAgY29uc3QgaCA9IE1hdGguZmxvb3IoKHNlYyAlIDg2NDAwKSAvIDM2MDApOw0KICAgIGNvbnN0IG1pID0gTWF0aC5mbG9vcigoc2VjICUgMzYwMCkgLyA2MCk7DQogICAgY29uc3QgcyA9IHNlYyAlIDYwOw0KICAgIHJldHVybiAoZCA+IDAgPyAoZCArICflpKknKSA6ICcnKSArIGggKyAn5bCP5pe2JyArIG1pICsgJ+WIhumSnycgKyBzICsgJ+enkic7DQogIH0NCiAgZnVuY3Rpb24gdGlja0luZm9VcHRpbWUoKSB7DQogICAgaWYgKG1vbml0b3JUYWIgIT09ICdpbmZvJykgcmV0dXJuOw0KICAgIGNvbnN0IGVsID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2luZm8tdXB0aW1lJyk7DQogICAgaWYgKCFlbCkgcmV0dXJuOw0KICAgIGVsLnRleHRDb250ZW50ID0gZm9ybWF0VXB0aW1lVGV4dChjdXJyZW50VXB0aW1lU2VjKCkpOw0KICB9DQogIHNldEludGVydmFsKHRpY2tJbmZvVXB0aW1lLCAxMDAwKTsNCg0KICB3aW5kb3cuX19zZXRQcm9jZXNzZXMgPSAocGF5bG9hZCkgPT4gew0KICAgIC8vIOi/m+eoi+ebkeaOp+W3suaUueS4uui/nuaOpeWIl+ihqO+8jOW/veeVpeaXp+i/m+eoi+aOqOmAgQ0KICB9Ow0KICB3aW5kb3cuX19zZXRQb3J0cyA9IChwYXlsb2FkKSA9PiB7DQogICAgdHJ5IHsNCiAgICAgIGNvbnN0IGRhdGEgPSB0eXBlb2YgcGF5bG9hZCA9PT0gJ3N0cmluZycgPyBKU09OLnBhcnNlKHBheWxvYWQpIDogcGF5bG9hZDsNCiAgICAgIGNvbnN0IG5leHQgPSBBcnJheS5pc0FycmF5KGRhdGEpID8gZGF0YSA6IChBcnJheS5pc0FycmF5KGRhdGEgJiYgZGF0YS5pdGVtcykgPyBkYXRhLml0ZW1zIDogW10pOw0KICAgICAgaWYgKGRhdGEgJiYgIUFycmF5LmlzQXJyYXkoZGF0YSkpIHsNCiAgICAgICAgaWYgKHByb2NDcHVUb3RhbCAmJiBkYXRhLmNwdVRvdGFsICE9IG51bGwpIHByb2NDcHVUb3RhbC50ZXh0Q29udGVudCA9IFN0cmluZyhkYXRhLmNwdVRvdGFsKTsNCiAgICAgICAgaWYgKHByb2NNZW1Ub3RhbCAmJiBkYXRhLm1lbVRvdGFsICE9IG51bGwpIHByb2NNZW1Ub3RhbC50ZXh0Q29udGVudCA9IFN0cmluZyhkYXRhLm1lbVRvdGFsKTsNCiAgICAgICAgdXBkYXRlSGVhZEhlYXQoZGF0YS5jcHVUb3RhbCwgZGF0YS5tZW1Ub3RhbCk7DQogICAgICB9DQogICAgICBjb25zdCBzY3JvbGxlciA9IHByb2NTY3JvbGwgfHwgcHJvY0JvZHk7DQogICAgICBjb25zdCBwcmV2U2Nyb2xsID0gc2Nyb2xsZXIgPyBzY3JvbGxlci5zY3JvbGxUb3AgOiAwOw0KICAgICAgY29uc3Qgc2FtZUNvbnRlbnQgPSBwb3J0c0NvbnRlbnRTaWcobmV4dCkgPT09IHBvcnRzQ29udGVudFNpZyhwcm9jSXRlbXMpOw0KICAgICAgcHJvY0l0ZW1zID0gbmV4dDsNCiAgICAgIGlmIChtb25pdG9yVGFiICE9PSAncHJvYycpIHJldHVybjsNCiAgICAgIGlmIChzYW1lQ29udGVudCkgew0KICAgICAgICAvLyDlj6rooaXlm77moIfvvIzkuI3ph43lu7rooYwNCiAgICAgICAgcGF0Y2hQcm9jSWNvbnMobmV4dCk7DQogICAgICAgIGlmIChzY3JvbGxlcikgc2Nyb2xsZXIuc2Nyb2xsVG9wID0gcHJldlNjcm9sbDsNCiAgICAgICAgcmV0dXJuOw0KICAgICAgfQ0KICAgICAgcmVuZGVyUHJvY1RhYmxlKCk7DQogICAgICBpZiAoc2Nyb2xsZXIpIHNjcm9sbGVyLnNjcm9sbFRvcCA9IHByZXZTY3JvbGw7DQogICAgfSBjYXRjaCAoZSkgeyBjb25zb2xlLndhcm4oJ3NldFBvcnRzJywgZSk7IH0NCiAgfTsNCiAgd2luZG93Ll9fc2V0SGFuZGxlcyA9IChwYXlsb2FkKSA9PiB7DQogICAgdHJ5IHsNCiAgICAgIGNvbnN0IGRhdGEgPSB0eXBlb2YgcGF5bG9hZCA9PT0gJ3N0cmluZycgPyBKU09OLnBhcnNlKHBheWxvYWQpIDogcGF5bG9hZDsNCiAgICAgIGhhbmRsZUJ1c3kgPSBmYWxzZTsNCiAgICAgIGhhbmRsZUl0ZW1zID0gc29ydEhhbmRsZUl0ZW1zKEFycmF5LmlzQXJyYXkoZGF0YSAmJiBkYXRhLml0ZW1zKSA/IGRhdGEuaXRlbXMgOiAoQXJyYXkuaXNBcnJheShkYXRhKSA/IGRhdGEgOiBbXSkpOw0KICAgICAgaWYgKGRhdGEgJiYgZGF0YS5xICE9IG51bGwpIGhhbmRsZVF1ZXJ5ID0gU3RyaW5nKGRhdGEucSk7DQogICAgICBpZiAoZGF0YSAmJiBkYXRhLm1vZGUpIGhhbmRsZU1vZGUgPSBTdHJpbmcoZGF0YS5tb2RlKSA9PT0gJ3BvcnQnID8gJ3BvcnQnIDogJ2hhbmRsZSc7DQogICAgICBlbHNlIGhhbmRsZU1vZGUgPSBpc1BvcnRTZWFyY2hRdWVyeShoYW5kbGVRdWVyeSkgPyAncG9ydCcgOiAnaGFuZGxlJzsNCiAgICAgIGNvbnN0IGVyciA9IGRhdGEgJiYgZGF0YS5lcnJvciA/IFN0cmluZyhkYXRhLmVycm9yKSA6ICcnOw0KICAgICAgaWYgKGhhbmRsZVN0YXR1cykgaGFuZGxlU3RhdHVzLnRleHRDb250ZW50ID0gZXJyIHx8IChoYW5kbGVJdGVtcy5sZW5ndGggPyAnJyA6ICfml6Dnu5PmnpwnKTsNCiAgICAgIGlmIChhcHBNb2RlID09PSAnaGFuZGxlJykgew0KICAgICAgICByZW5kZXJIYW5kbGVUYWJsZShlcnIgfHwgKGhhbmRsZU1vZGUgPT09ICdwb3J0JyA/ICfmsqHmnInljLnphY3nmoTnq6/lj6MnIDogJ+ayoeacieWMuemFjeeahOWPpeafhCcpKTsNCiAgICAgICAgY291bnRFbC50ZXh0Q29udGVudCA9ICflhbEgJyArIGhhbmRsZUl0ZW1zLmxlbmd0aCArICcg5p2hJzsNCiAgICAgIH0NCiAgICB9IGNhdGNoIChlKSB7DQogICAgICBoYW5kbGVCdXN5ID0gZmFsc2U7DQogICAgICBjb25zb2xlLndhcm4oJ3NldEhhbmRsZXMnLCBlKTsNCiAgICB9DQogIH07DQogIHdpbmRvdy5fX3Byb2NLaWxsZWQgPSAocGlkcykgPT4gew0KICAgIHRyeSB7DQogICAgICBjb25zdCBsaXN0ID0gQXJyYXkuaXNBcnJheShwaWRzKSA/IHBpZHMgOiBbXTsNCiAgICAgIHJlbW92ZVJvd3NCeVBpZHMobGlzdCk7DQogICAgfSBjYXRjaCAoZSkgeyBjb25zb2xlLndhcm4oJ3Byb2NLaWxsZWQnLCBlKTsgfQ0KICB9Ow0KICBmdW5jdGlvbiByZW1vdmVSb3dzQnlQaWRzKHBpZHMpIHsNCiAgICBjb25zdCBzZXQgPSBuZXcgU2V0KChwaWRzIHx8IFtdKS5tYXAobiA9PiBOdW1iZXIobikpLmZpbHRlcihuID0+IG4gPiAwKSk7DQogICAgaWYgKCFzZXQuc2l6ZSkgcmV0dXJuOw0KICAgIGNvbnN0IGJlZm9yZUggPSBoYW5kbGVJdGVtcy5sZW5ndGg7DQogICAgaGFuZGxlSXRlbXMgPSBoYW5kbGVJdGVtcy5maWx0ZXIoaXQgPT4gIXNldC5oYXMoTnVtYmVyKGl0LnBpZCkgfHwgMCkpOw0KICAgIGlmIChoYW5kbGVJdGVtcy5sZW5ndGggIT09IGJlZm9yZUgpIHsNCiAgICAgIGZvciAoY29uc3QgayBvZiBBcnJheS5mcm9tKGhhbmRsZVNlbEtleXMpKSB7DQogICAgICAgIGNvbnN0IHJvdyA9IGhhbmRsZUJvZHkucXVlcnlTZWxlY3RvcignLmhhbmRsZS1yb3dbZGF0YS1rZXk9IicgKyBDU1MuZXNjYXBlKGspICsgJyJdJyk7DQogICAgICAgIGNvbnN0IHBpZCA9IHJvdyA/IChOdW1iZXIocm93LmdldEF0dHJpYnV0ZSgnZGF0YS1waWQnKSkgfHwgMCkgOiAwOw0KICAgICAgICBpZiAoc2V0LmhhcyhwaWQpKSBoYW5kbGVTZWxLZXlzLmRlbGV0ZShrKTsNCiAgICAgIH0NCiAgICAgIGlmIChhcHBNb2RlID09PSAnaGFuZGxlJykNCiAgICAgICAgcmVuZGVySGFuZGxlVGFibGUoaGFuZGxlSXRlbXMubGVuZ3RoID8gJycgOiAoaGFuZGxlTW9kZSA9PT0gJ3BvcnQnID8gJ+ayoeacieWMuemFjeeahOerr+WPoycgOiAn5rKh5pyJ5Yy56YWN55qE5Y+l5p+EJykpOw0KICAgICAgaWYgKGFwcE1vZGUgPT09ICdoYW5kbGUnKQ0KICAgICAgICBjb3VudEVsLnRleHRDb250ZW50ID0gJ+WFsSAnICsgaGFuZGxlSXRlbXMubGVuZ3RoICsgJyDmnaEnOw0KICAgIH0NCiAgfTsNCiAgd2luZG93Ll9fc2V0U3lzSW5mbyA9IChwYXlsb2FkKSA9PiB7DQogICAgdHJ5IHsNCiAgICAgIGluZm9SZXFHZW4gKz0gMTsNCiAgICAgIGNsZWFySW5mb0xvYWRXYWl0KCk7DQogICAgICBjb25zdCBkYXRhID0gdHlwZW9mIHBheWxvYWQgPT09ICdzdHJpbmcnID8gSlNPTi5wYXJzZShwYXlsb2FkKSA6IHBheWxvYWQ7DQogICAgICBjb25zdCBwcmV2U2VjID0gaW5mb0RhdGEgJiYgaW5mb0RhdGEudXB0aW1lU2VjOw0KICAgICAgY29uc3QgcHJldlN5bmMgPSBpbmZvRGF0YSAmJiBpbmZvRGF0YS5fc3luY2VkQXQ7DQogICAgICBpbmZvRGF0YSA9IGRhdGEgfHwge307DQogICAgICAvLyDlkIzkuIDku73nvJPlrZjlho3mrKHmjqjpgIHml7bkv53nlZnlkIzmraXngrnvvIzpgb/lhY3ov5DooYzml7bpl7Tooqvph43nva4NCiAgICAgIGlmIChwcmV2U3luYyAmJiBwcmV2U2VjICE9IG51bGwgJiYgTnVtYmVyKGluZm9EYXRhLnVwdGltZVNlYykgPT09IE51bWJlcihwcmV2U2VjKSkNCiAgICAgICAgaW5mb0RhdGEuX3N5bmNlZEF0ID0gcHJldlN5bmM7DQogICAgICBlbHNlDQogICAgICAgIGluZm9EYXRhLl9zeW5jZWRBdCA9IERhdGUubm93KCk7DQogICAgICBpZiAoaW5mb0RhdGEudXB0aW1lU2VjID09IG51bGwgJiYgaW5mb0RhdGEudXB0aW1lKQ0KICAgICAgICBpbmZvRGF0YS51cHRpbWVTZWMgPSAwOw0KICAgICAgaW5mb1RleHQgPSBTdHJpbmcoZGF0YSAmJiBkYXRhLnRleHQgfHwgJycpOw0KICAgICAgaWYgKGFwcE1vZGUgPT09ICdpbmZvJykgew0KICAgICAgICByZW5kZXJTeXNJbmZvKCk7DQogICAgICAgIGlmIChjb3VudEVsKSBjb3VudEVsLnRleHRDb250ZW50ID0gJ+acrOacuuS/oeaBryc7DQogICAgICB9DQogICAgfSBjYXRjaCAoZSkgeyBjb25zb2xlLndhcm4oJ3NldFN5c0luZm8nLCBlKTsgfQ0KICB9Ow0KDQogIHBvc3QoJ3VpUmVhZHknKTsNCn0pKCk7DQo8L3NjcmlwdD4NCjwvYm9keT4NCjwvaHRtbD4NCg==
;########################################################################################################### local_search_index.html

