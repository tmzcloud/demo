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
        SetTimer(RequestFrontendSearch, -40)
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

ToggleMaximizeWindow() {
    global guiWin
    if !IsObject(guiWin)
        return
    try {
        if WinGetMinMax("ahk_id " guiWin.Hwnd) = 1
            WinRestore("ahk_id " guiWin.Hwnd)
        else
            WinMaximize("ahk_id " guiWin.Hwnd)
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
    ; Space = AND in Everything. Keep regex:… as one token (do not split inside).
    qSafe := StrReplace(qTrim, '"', "")
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
    ; 首屏取真实总数，否则滚动会在「假总数」处提前停住（例如只剩 60）
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
    PushResults(items, total, offset, offset > 0, limit)
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

PushResults(items, total, offset := 0, append := false, pageSize := 50) {
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

; ── AHK run/get/sys config files (HELPME_HOME\command_ext\ahk\config) ──
ResolveAhkConfigDir() {
    home := ""
    try home := EnvGet("HELPME_HOME")
    home := Trim(String(home))
    if home != ""
        return RTrim(home, "\/") "\command_ext\ahk\config"
    ; fallback: sibling of ahk_ext
    return A_ScriptDir "\..\ahk\config"
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
    path := AhkConfigPath(n)
    if !FileExist(path) {
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
    path := AhkConfigPath(n)
    dir := ResolveAhkConfigDir()
    try DirCreate dir
    text := B64DecodeToUtf8Text(b64)
    ; normalize newlines
    text := StrReplace(text, "`r`n", "`n")
    text := StrReplace(text, "`r", "`n")
    text := StrReplace(text, "`n", "`r`n")
    enc := DetectAhkConfigWriteEnc(path)
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
    } catch as e {
        EmitAhkConfigResult(n, false, "保存失败: " e.Message)
    }
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
        try FileOpen(SEARCH_DIR "\last_ui_mode.txt", "w", "UTF-8").Write(mode)
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
;77u/PCFET0NUWVBFIGh0bWw+CjxodG1sIGxhbmc9InpoLUNOIj4KPGhlYWQ+CjxtZXRhIGNoYXJzZXQ9IlVURi04Ij4KPG1ldGEgbmFtZT0idmlld3BvcnQi
;IGNvbnRlbnQ9IndpZHRoPWRldmljZS13aWR0aCwgaW5pdGlhbC1zY2FsZT0xIj4KPHRpdGxlPuS7quihqOebmDwvdGl0bGU+CjwhLS0gbG9jYWxfc2VhcmNo
;X3VpOjIwMjYtMDktMTdhbSAtLT4KPHN0eWxlPgo6cm9vdCB7CiAgLS1iZzogI2YzZjRmNzsKICAtLXBhbmVsOiAjZmZmZmZmOwogIC0tbGluZTogI2U2ZThl
;ZTsKICAtLXR4dDogIzFmMjQzMDsKICAtLXR4dDI6ICM2YjcyODU7CiAgLS10eHQzOiAjOWFhMWIyOwogIC0tYWNjOiAjM2I4MmY2OwogIC0tYWNjMjogIzI1
;NjNlYjsKICAtLW5hbWU6ICMxMTE4Mjc7CiAgLS1uYW1lLWV4dDogI2VhNTgwYzsKICAtLWhsOiAjZmVmMDhhOwogIC0taGwtdGV4dDogIzg1NGQwZTsKICAt
;LXNlbDogI2VlZjFmNjsKICAtLXNpZGU6ICNmNWY2Zjk7CiAgLS1jaHJvbWU6ICNmNWY2Zjk7CiAgLS1zaWRlLXc6IDE0OHB4OwogIC0tcmluZzogI2U0MjA3
;OTsKICAtLXNoYWRvdzogMCAxMHB4IDMwcHggcmdiYSgyMCwgMjgsIDQ1LCAuMDgpOwogIC0tcjogMTBweDsKICBmb250LWZhbWlseTogIlNlZ29lIFVJIiwg
;Ik1pY3Jvc29mdCBZYUhlaSBVSSIsICJQaW5nRmFuZyBTQyIsIHNhbnMtc2VyaWY7Cn0KKiB7IGJveC1zaXppbmc6IGJvcmRlci1ib3g7IH0KaHRtbCwgYm9k
;eSB7IG1hcmdpbjogMDsgaGVpZ2h0OiAxMDAlOyBiYWNrZ3JvdW5kOiB2YXIoLS1iZyk7IGNvbG9yOiB2YXIoLS10eHQpOyBvdmVyZmxvdzogaGlkZGVuOyB9
;CmJ1dHRvbiwgaW5wdXQgeyBmb250OiBpbmhlcml0OyB9CiNhcHAgeyBkaXNwbGF5OiBmbGV4OyBmbGV4LWRpcmVjdGlvbjogY29sdW1uOyBoZWlnaHQ6IDEw
;MCU7IH0KCi8qIOWFqOWxgO+8mueugOe6pue6pOe7hue6teWQkea7muWKqOadoSAqLwoqIHsKICBzY3JvbGxiYXItd2lkdGg6IHRoaW47CiAgc2Nyb2xsYmFy
;LWNvbG9yOiAjYzBjNGNjIHRyYW5zcGFyZW50Owp9Cio6Oi13ZWJraXQtc2Nyb2xsYmFyIHsgd2lkdGg6IDRweDsgaGVpZ2h0OiA0cHg7IH0KKjo6LXdlYmtp
;dC1zY3JvbGxiYXItdHJhY2sgeyBiYWNrZ3JvdW5kOiB0cmFuc3BhcmVudDsgfQoqOjotd2Via2l0LXNjcm9sbGJhci10aHVtYiB7CiAgYmFja2dyb3VuZDog
;I2MwYzRjYzsgYm9yZGVyLXJhZGl1czogOTk5cHg7IGJvcmRlcjogMDsKICBtaW4taGVpZ2h0OiAyNHB4Owp9Cio6Oi13ZWJraXQtc2Nyb2xsYmFyLXRodW1i
;OmhvdmVyIHsgYmFja2dyb3VuZDogIzlhYTFiMjsgfQoqOjotd2Via2l0LXNjcm9sbGJhci1jb3JuZXIgeyBiYWNrZ3JvdW5kOiB0cmFuc3BhcmVudDsgfQoK
;LyogaW5kZXhpbmcgKi8KI2Jvb3QgewogIGRpc3BsYXk6IG5vbmU7IGZsZXg6IDE7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGp1c3RpZnktY29udGVudDogY2Vu
;dGVyOwogIGZsZXgtZGlyZWN0aW9uOiBjb2x1bW47IGdhcDogMjhweDsgYmFja2dyb3VuZDogI2ZmZjsKfQojYm9vdC5vbiB7IGRpc3BsYXk6IGZsZXg7IH0K
;LnJpbmctd3JhcCB7IHdpZHRoOiAxNjhweDsgaGVpZ2h0OiAxNjhweDsgcG9zaXRpb246IHJlbGF0aXZlOyB9Ci5yaW5nLXdyYXAgc3ZnIHsgd2lkdGg6IDEw
;MCU7IGhlaWdodDogMTAwJTsgdHJhbnNmb3JtOiByb3RhdGUoLTkwZGVnKTsgfQoucmluZy1iZyB7IGZpbGw6IG5vbmU7IHN0cm9rZTogI2VjZWZmNDsgc3Ry
;b2tlLXdpZHRoOiA4OyB9Ci5yaW5nLWZnIHsgZmlsbDogbm9uZTsgc3Ryb2tlOiB2YXIoLS1yaW5nKTsgc3Ryb2tlLXdpZHRoOiA4OyBzdHJva2UtbGluZWNh
;cDogcm91bmQ7CiAgdHJhbnNpdGlvbjogc3Ryb2tlLWRhc2hvZmZzZXQgLjM1cyBlYXNlOyB9Ci5yaW5nLWxhYmVsIHsKICBwb3NpdGlvbjogYWJzb2x1dGU7
;IGluc2V0OiAwOyBkaXNwbGF5OiBmbGV4OyBmbGV4LWRpcmVjdGlvbjogY29sdW1uOwogIGFsaWduLWl0ZW1zOiBjZW50ZXI7IGp1c3RpZnktY29udGVudDog
;Y2VudGVyOyBnYXA6IDZweDsKfQoucmluZy1sYWJlbCAudDEgeyBmb250LXNpemU6IDE2cHg7IGZvbnQtd2VpZ2h0OiA2MDA7IH0KLnJpbmctbGFiZWwgLnQy
;IHsgZm9udC1zaXplOiAyOHB4OyBmb250LXdlaWdodDogNzAwOyBjb2xvcjogIzExMTgyNzsgfQouYm9vdC1oaW50IHsgY29sb3I6IHZhcigtLXR4dDIpOyBm
;b250LXNpemU6IDEzcHg7IG1heC13aWR0aDogNTIwcHg7IHRleHQtYWxpZ246IGNlbnRlcjsgbGluZS1oZWlnaHQ6IDEuNjsgfQouYm9vdC1oaW50IGEgeyBj
;b2xvcjogdmFyKC0tYWNjKTsgdGV4dC1kZWNvcmF0aW9uOiBub25lOyBjdXJzb3I6IHBvaW50ZXI7IH0KLmJvb3QtaGludCBhOmhvdmVyIHsgdGV4dC1kZWNv
;cmF0aW9uOiB1bmRlcmxpbmU7IH0KCi8qIHRpdGxlYmFyID0g5Luq6KGo55uY6YKj5LiA6KGM77yb5oqY5Y+g566t5aS05LiO5LiL5pa55pCc57Si5qGG5YiX
;5a+56b2QICovCiN0aXRsZWJhciB7CiAgZGlzcGxheTogZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsgZ2FwOiAwOyBmbGV4LXNocmluazogMDsKICBtaW4t
;aGVpZ2h0OiAzNnB4OyBwYWRkaW5nOiAwOyBib3gtc2l6aW5nOiBib3JkZXItYm94OwogIGJhY2tncm91bmQ6IHZhcigtLWNocm9tZSk7IGJvcmRlci1ib3R0
;b206IDA7CiAgLXdlYmtpdC1hcHAtcmVnaW9uOiBkcmFnOyBhcHAtcmVnaW9uOiBkcmFnOyB1c2VyLXNlbGVjdDogbm9uZTsKfQojdGl0bGViYXIgLm5vLWRy
;YWcsICN0aXRsZWJhciBidXR0b24gewogIC13ZWJraXQtYXBwLXJlZ2lvbjogbm8tZHJhZzsgYXBwLXJlZ2lvbjogbm8tZHJhZzsKfQojdGl0bGViYXIgLnRi
;LWJyYW5kIHsKICBkaXNwbGF5OiBpbmxpbmUtZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsgZ2FwOiA4cHg7IGZsZXgtc2hyaW5rOiAwOwogIHdpZHRoOiB2
;YXIoLS1zaWRlLXcpOyBwYWRkaW5nOiAwIDEwcHg7IGJveC1zaXppbmc6IGJvcmRlci1ib3g7CiAgY29sb3I6IHZhcigtLXR4dCk7IGZvbnQtc2l6ZTogMTNw
;eDsgZm9udC13ZWlnaHQ6IDY1MDsgbGV0dGVyLXNwYWNpbmc6IC4wMWVtOwp9CiN0aXRsZWJhciAudGItaWNvIHsKICB3aWR0aDogMTZweDsgaGVpZ2h0OiAx
;NnB4OyBkaXNwbGF5OiBibG9jazsgY29sb3I6ICMwNDc4NTc7IGZsZXgtc2hyaW5rOiAwOwp9CiN0aXRsZWJhciAudGItc3BhY2UgeyBmbGV4OiAxOyBtaW4t
;d2lkdGg6IDhweDsgYWxpZ24tc2VsZjogc3RyZXRjaDsgfQojdGl0bGViYXIgLnRiLXdpbiB7CiAgZGlzcGxheTogZmxleDsgYWxpZ24taXRlbXM6IHN0cmV0
;Y2g7IGZsZXgtc2hyaW5rOiAwOyBoZWlnaHQ6IDM2cHg7Cn0KI3RpdGxlYmFyIC50Yi13aW4gYnV0dG9uIHsKICB3aWR0aDogNDZweDsgaGVpZ2h0OiAxMDAl
;OyBwYWRkaW5nOiAwOyBib3JkZXI6IDA7IGJhY2tncm91bmQ6IHRyYW5zcGFyZW50OwogIGNvbG9yOiB2YXIoLS10eHQyKTsgY3Vyc29yOiBwb2ludGVyOwog
;IGRpc3BsYXk6IGlubGluZS1mbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBqdXN0aWZ5LWNvbnRlbnQ6IGNlbnRlcjsKfQojdGl0bGViYXIgLnRiLXdpbiBi
;dXR0b246aG92ZXIgeyBiYWNrZ3JvdW5kOiAjZThlYmYwOyBjb2xvcjogdmFyKC0tdHh0KTsgfQojdGl0bGViYXIgLnRiLXdpbiAjYnRuLXdpbi1jbG9zZTpo
;b3ZlciB7IGJhY2tncm91bmQ6ICNlODExMjM7IGNvbG9yOiAjZmZmOyB9CiN0aXRsZWJhciAudGItd2luIGJ1dHRvbiBzdmcgeyB3aWR0aDogMTBweDsgaGVp
;Z2h0OiAxMHB4OyBkaXNwbGF5OiBibG9jazsgfQojZmlsdGVyLXJhaWwgewogIGRpc3BsYXk6IGZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGdhcDogOHB4
;OyBmbGV4LXNocmluazogMTsgbWluLXdpZHRoOiAwOwogIHBhZGRpbmc6IDRweCAwOyBtYXJnaW46IDA7Cn0KI2FwcC5ib290aW5nICNmaWx0ZXItcmFpbCwK
;I2FwcC5oaWRlLWZpbHRlcnMgI2ZpbHRlci1yYWlsIHsgZGlzcGxheTogbm9uZSAhaW1wb3J0YW50OyB9CiNmaWx0ZXItYmFyIHsKICBkaXNwbGF5OiBmbGV4
;OyBmbGV4LXdyYXA6IHdyYXA7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGdhcDogNnB4OyBtaW4td2lkdGg6IDA7Cn0KLmZpbHRlci1jaGlwIHsKICBoZWlnaHQ6
;IDIycHg7IHBhZGRpbmc6IDAgMTBweDsgYm9yZGVyOiAxcHggc29saWQgdmFyKC0tbGluZSk7CiAgYm9yZGVyLXJhZGl1czogOTk5cHg7IGJhY2tncm91bmQ6
;ICNmYmZiZmQ7IGNvbG9yOiB2YXIoLS10eHQyKTsKICBmb250LXNpemU6IDEycHg7IGN1cnNvcjogcG9pbnRlcjsgbGluZS1oZWlnaHQ6IDIwcHg7IHdoaXRl
;LXNwYWNlOiBub3dyYXA7Cn0KLmZpbHRlci1jaGlwOmhvdmVyIHsgYmFja2dyb3VuZDogI2VlZjFmNjsgY29sb3I6IHZhcigtLXR4dCk7IH0KLmZpbHRlci1j
;aGlwLm9uIHsKICBiYWNrZ3JvdW5kOiAjZWNmZGY1OyBib3JkZXItY29sb3I6ICM4NmVmYWM7IGNvbG9yOiAjMDQ3ODU3OyBmb250LXdlaWdodDogNjAwOwp9
;CgovKiBjaHJvbWUgKi8KI2Nocm9tZSB7IGRpc3BsYXk6IGZsZXg7IGZsZXgtZGlyZWN0aW9uOiBjb2x1bW47IGZsZXg6IDE7IG1pbi1oZWlnaHQ6IDA7IH0K
;I2Nocm9tZS5oaWRkZW4geyBkaXNwbGF5OiBub25lOyB9CiN0b3AgewogIGhlaWdodDogNDhweDsgZGlzcGxheTogZ3JpZDsKICBncmlkLXRlbXBsYXRlLWNv
;bHVtbnM6IHZhcigtLXNpZGUtdykgbWlubWF4KDAsIDFmcik7CiAgYWxpZ24taXRlbXM6IHN0cmV0Y2g7IHBhZGRpbmc6IDAgMTBweCAwIDA7IGJhY2tncm91
;bmQ6IHZhcigtLWNocm9tZSk7CiAgYm9yZGVyLWJvdHRvbTogMDsgYm94LXNpemluZzogYm9yZGVyLWJveDsKICAtd2Via2l0LWFwcC1yZWdpb246IGRyYWc7
;IGFwcC1yZWdpb246IGRyYWc7Cn0KI3RvcCAubm8tZHJhZywgI3RvcCBidXR0b24sICN0b3AgaW5wdXQgewogIC13ZWJraXQtYXBwLXJlZ2lvbjogbm8tZHJh
;ZzsgYXBwLXJlZ2lvbjogbm8tZHJhZzsKfQojZHJpdmUtd3JhcCB7CiAgcG9zaXRpb246IHJlbGF0aXZlOyB3aWR0aDogMTAwJTsKICBib3JkZXItcmlnaHQ6
;IDA7IGJhY2tncm91bmQ6IHZhcigtLWNocm9tZSk7CiAgZGlzcGxheTogZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsKfQojYnRuLWRyaXZlIHsKICBkaXNw
;bGF5OiBmbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBnYXA6IDhweDsKICB3aWR0aDogMTAwJTsgaGVpZ2h0OiAxMDAlOyBwYWRkaW5nOiAwIDEwcHg7CiAg
;Ym9yZGVyOiAwOyBib3JkZXItcmFkaXVzOiAwOyBiYWNrZ3JvdW5kOiB0cmFuc3BhcmVudDsKICBjb2xvcjogdmFyKC0tdHh0KTsgZm9udC1zaXplOiAxMy41
;cHg7IGZvbnQtd2VpZ2h0OiA2MDA7CiAgY3Vyc29yOiBwb2ludGVyOyB0ZXh0LWFsaWduOiBsZWZ0Owp9CiNidG4tZHJpdmU6aG92ZXIgeyBiYWNrZ3JvdW5k
;OiAjZWVmMWY2OyBjb2xvcjogdmFyKC0tYWNjMik7IH0KI2J0bi1kcml2ZSAuZHJpdmUtaWNvIHsKICB3aWR0aDogMjBweDsgaGVpZ2h0OiAyMHB4OyBvYmpl
;Y3QtZml0OiBjb250YWluOyBmbGV4LXNocmluazogMDsKICBiYWNrZ3JvdW5kOiB0cmFuc3BhcmVudDsKfQojYnRuLWRyaXZlIC5kcml2ZS1pY28uaGlkZGVu
;IHsgZGlzcGxheTogbm9uZTsgfQojYnRuLWRyaXZlIC5jYXJldCB7IGZvbnQtc2l6ZTogMTBweDsgY29sb3I6IHZhcigtLXR4dDMpOyBtYXJnaW4tbGVmdDog
;YXV0bzsgfQojZHJpdmUtbGFiZWwgeyBvdmVyZmxvdzogaGlkZGVuOyB0ZXh0LW92ZXJmbG93OiBlbGxpcHNpczsgd2hpdGUtc3BhY2U6IG5vd3JhcDsgfQoj
;ZHJpdmUtbWVudSB7CiAgZGlzcGxheTogbm9uZTsgcG9zaXRpb246IGFic29sdXRlOyB0b3A6IDEwMCU7IGxlZnQ6IDA7IHJpZ2h0OiAwOyB6LWluZGV4OiA0
;MDsKICB3aWR0aDogMTAwJTsgbWF4LWhlaWdodDogMzIwcHg7IG92ZXJmbG93OiBhdXRvOwogIGJhY2tncm91bmQ6ICNmZmY7IGJvcmRlcjogMXB4IHNvbGlk
;IHZhcigtLWxpbmUpOyBib3JkZXItdG9wOiAwOwogIGJveC1zaGFkb3c6IHZhcigtLXNoYWRvdyk7IHBhZGRpbmc6IDRweDsgYm9yZGVyLXJhZGl1czogMCAw
;IDhweCA4cHg7Cn0KI2RyaXZlLW1lbnUub24geyBkaXNwbGF5OiBibG9jazsgfQojZHJpdmUtbWVudSBidXR0b24gewogIGRpc3BsYXk6IGZsZXg7IGFsaWdu
;LWl0ZW1zOiBjZW50ZXI7IGdhcDogOHB4OyB3aWR0aDogMTAwJTsKICB0ZXh0LWFsaWduOiBsZWZ0OyBib3JkZXI6IDA7IGJhY2tncm91bmQ6IHRyYW5zcGFy
;ZW50OwogIHBhZGRpbmc6IDhweCAxMHB4OyBib3JkZXItcmFkaXVzOiA2cHg7IGN1cnNvcjogcG9pbnRlcjsgY29sb3I6IHZhcigtLXR4dCk7IGZvbnQtc2l6
;ZTogMTNweDsKfQojZHJpdmUtbWVudSBidXR0b24gaW1nIHsKICB3aWR0aDogMjBweDsgaGVpZ2h0OiAyMHB4OyBvYmplY3QtZml0OiBjb250YWluOyBmbGV4
;LXNocmluazogMDsgYmFja2dyb3VuZDogdHJhbnNwYXJlbnQ7Cn0KI2RyaXZlLW1lbnUgYnV0dG9uOmhvdmVyIHsgYmFja2dyb3VuZDogI2VlZjJmZjsgfQoj
;ZHJpdmUtbWVudSBidXR0b24ub24geyBiYWNrZ3JvdW5kOiAjZWZmNmZmOyBjb2xvcjogdmFyKC0tYWNjMik7IGZvbnQtd2VpZ2h0OiA2MDA7IH0KI3RvcC1y
;ZXN0IHsKICBkaXNwbGF5OiBncmlkOwogIGdyaWQtdGVtcGxhdGUtY29sdW1uczogbWlubWF4KDI4MHB4LCAxLjFmcikgbWlubWF4KDMyMHB4LCAxLjJmcik7
;CiAgYWxpZ24taXRlbXM6IHN0cmV0Y2g7IG1pbi13aWR0aDogMDsgbWluLWhlaWdodDogMDsKICBiYWNrZ3JvdW5kOiB2YXIoLS1jaHJvbWUpOwp9CiN0b3Au
;bW9kZS10b29sICN0b3AtcmVzdCB7CiAgZ3JpZC10ZW1wbGF0ZS1jb2x1bW5zOiAxZnI7Cn0KLyog5YWz6IGU5Y+l5p+E77ya5LuF5pCc57Si5qGG5Y2g5LiA
;5Y2K77yM5YiX6KGo5LuN5YWo5a69ICovCiN0b3AubW9kZS1oYW5kbGUgI3RvcC1yZXN0IHsKICBncmlkLXRlbXBsYXRlLWNvbHVtbnM6IG1pbm1heCgyODBw
;eCwgNTAlKTsKICBqdXN0aWZ5LWNvbnRlbnQ6IHN0YXJ0Owp9CiNzZWFyY2gtd3JhcCB7CiAgZGlzcGxheTogZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsg
;bWluLXdpZHRoOiAwOyBoZWlnaHQ6IDEwMCU7CiAgcGFkZGluZzogMDsgYm9yZGVyLXJpZ2h0OiAwOyBiYWNrZ3JvdW5kOiB2YXIoLS1jaHJvbWUpOwp9CiNm
;aWx0ZXItc2V0dGluZ3MgewogIGRpc3BsYXk6IG5vbmU7IHBvc2l0aW9uOiBmaXhlZDsgaW5zZXQ6IDA7IHotaW5kZXg6IDMwMDsKICBiYWNrZ3JvdW5kOiBy
;Z2JhKDE1LCAyMywgNDIsIC4yOCk7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGp1c3RpZnktY29udGVudDogY2VudGVyOwp9CiNmaWx0ZXItc2V0dGluZ3Mub24g
;eyBkaXNwbGF5OiBmbGV4OyB9CiNmaWx0ZXItc2V0dGluZ3MgLmZzLWNhcmQgewogIHdpZHRoOiBtaW4oNDYwcHgsIDkydncpOyBtYXgtaGVpZ2h0OiBtaW4o
;NjIwcHgsIDg4dmgpOwogIGJhY2tncm91bmQ6ICNmZmY7IGJvcmRlci1yYWRpdXM6IDE0cHg7IGJvcmRlcjogMXB4IHNvbGlkIHZhcigtLWxpbmUpOwogIGJv
;eC1zaGFkb3c6IDAgMThweCA0MHB4IHJnYmEoMTUsIDIzLCA0MiwgLjE4KTsKICBkaXNwbGF5OiBmbGV4OyBmbGV4LWRpcmVjdGlvbjogY29sdW1uOyBvdmVy
;ZmxvdzogaGlkZGVuOwp9CiNmaWx0ZXItc2V0dGluZ3MgLmZzLWhkIHsKICBkaXNwbGF5OiBmbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBqdXN0aWZ5LWNv
;bnRlbnQ6IHNwYWNlLWJldHdlZW47CiAgcGFkZGluZzogMTRweCAxNnB4OyBib3JkZXItYm90dG9tOiAxcHggc29saWQgdmFyKC0tbGluZSk7IGZvbnQtd2Vp
;Z2h0OiA2MDA7Cn0KI2ZpbHRlci1zZXR0aW5ncyAuZnMtaGQgYnV0dG9uIHsKICBib3JkZXI6IDA7IGJhY2tncm91bmQ6IHRyYW5zcGFyZW50OyBjb2xvcjog
;dmFyKC0tdHh0Mik7IGN1cnNvcjogcG9pbnRlcjsgZm9udC1zaXplOiAxOHB4OyBsaW5lLWhlaWdodDogMTsKfQojZmlsdGVyLXNldHRpbmdzIC5mcy1iZCB7
;CiAgcGFkZGluZzogMTRweCAxNnB4OyBvdmVyZmxvdzogYXV0bzsgZGlzcGxheTogZmxleDsgZmxleC1kaXJlY3Rpb246IGNvbHVtbjsgZ2FwOiAxMnB4Owp9
;CiNmaWx0ZXItc2V0dGluZ3MgLmZzLWhpbnQgeyBmb250LXNpemU6IDEycHg7IGNvbG9yOiB2YXIoLS10eHQzKTsgbGluZS1oZWlnaHQ6IDEuNTsgfQojZmls
;dGVyLXNldHRpbmdzIC5mcy1saXN0IHsgZGlzcGxheTogZmxleDsgZmxleC1kaXJlY3Rpb246IGNvbHVtbjsgZ2FwOiAxMHB4OyB9CiNmaWx0ZXItc2V0dGlu
;Z3MgLmZzLWJsb2NrIHsKICBwb3NpdGlvbjogcmVsYXRpdmU7IGRpc3BsYXk6IGdyaWQ7CiAgZ3JpZC10ZW1wbGF0ZS1jb2x1bW5zOiAyOHB4IG1pbm1heCgw
;LCAxZnIpIGF1dG87CiAgZ2FwOiA4cHggMTBweDsgYWxpZ24taXRlbXM6IHN0YXJ0OwogIHBhZGRpbmc6IDE0cHggMzZweCAxMnB4IDEycHg7CiAgYm9yZGVy
;OiAxcHggc29saWQgI2Q3ZGRlODsgYm9yZGVyLXJhZGl1czogMTJweDsKICBiYWNrZ3JvdW5kOiBsaW5lYXItZ3JhZGllbnQoMTgwZGVnLCAjZmZmZmZmIDAl
;LCAjZjdmOWZjIDEwMCUpOwogIGJveC1zaGFkb3c6IDAgMXB4IDAgcmdiYSgyNTUsMjU1LDI1NSwuOSkgaW5zZXQsIDAgNHB4IDEycHggcmdiYSgxNSwgMjMs
;IDQyLCAuMDUpOwogIGJvcmRlci1sZWZ0OiAzcHggc29saWQgIzg2ZWZhYzsKfQojZmlsdGVyLXNldHRpbmdzIC5mcy1ibG9jay5vZmYgewogIG9wYWNpdHk6
;IC42MjsgYm9yZGVyLWxlZnQtY29sb3I6ICNjYmQ1ZTE7CiAgYmFja2dyb3VuZDogbGluZWFyLWdyYWRpZW50KDE4MGRlZywgI2Y4ZmFmYyAwJSwgI2YxZjVm
;OSAxMDAlKTsKfQojZmlsdGVyLXNldHRpbmdzIC5mcy1ibG9jayAuZnMtZGVsIHsKICBwb3NpdGlvbjogYWJzb2x1dGU7IHRvcDogOHB4OyByaWdodDogOHB4
;OwogIHdpZHRoOiAyMnB4OyBoZWlnaHQ6IDIycHg7IHBhZGRpbmc6IDA7IGJvcmRlcjogMDsgYm9yZGVyLXJhZGl1czogNnB4OwogIGJhY2tncm91bmQ6IHRy
;YW5zcGFyZW50OyBjb2xvcjogdmFyKC0tdHh0Myk7IGN1cnNvcjogcG9pbnRlcjsKICBkaXNwbGF5OiBpbmxpbmUtZmxleDsgYWxpZ24taXRlbXM6IGNlbnRl
;cjsganVzdGlmeS1jb250ZW50OiBjZW50ZXI7Cn0KI2ZpbHRlci1zZXR0aW5ncyAuZnMtYmxvY2sgLmZzLWRlbDpob3ZlciB7IGJhY2tncm91bmQ6ICNmZWUy
;ZTI7IGNvbG9yOiAjYjkxYzFjOyB9CiNmaWx0ZXItc2V0dGluZ3MgLmZzLWJsb2NrIC5mcy1kZWwgc3ZnIHsgd2lkdGg6IDEycHg7IGhlaWdodDogMTJweDsg
;ZGlzcGxheTogYmxvY2s7IH0KI2ZpbHRlci1zZXR0aW5ncyAuZnMtb3JkIHsKICBkaXNwbGF5OiBmbGV4OyBmbGV4LWRpcmVjdGlvbjogY29sdW1uOyBnYXA6
;IDJweDsgcGFkZGluZy10b3A6IDJweDsKfQojZmlsdGVyLXNldHRpbmdzIC5mcy1vcmQgYnV0dG9uIHsKICB3aWR0aDogMjRweDsgaGVpZ2h0OiAyMHB4OyBw
;YWRkaW5nOiAwOyBib3JkZXI6IDA7IGJvcmRlci1yYWRpdXM6IDVweDsKICBiYWNrZ3JvdW5kOiAjZWVmMmY3OyBjb2xvcjogdmFyKC0tdHh0Mik7IGN1cnNv
;cjogcG9pbnRlcjsKICBkaXNwbGF5OiBpbmxpbmUtZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsganVzdGlmeS1jb250ZW50OiBjZW50ZXI7Cn0KI2ZpbHRl
;ci1zZXR0aW5ncyAuZnMtb3JkIGJ1dHRvbjpob3ZlciB7IGJhY2tncm91bmQ6ICNlMmU4ZjA7IGNvbG9yOiB2YXIoLS10eHQpOyB9CiNmaWx0ZXItc2V0dGlu
;Z3MgLmZzLW9yZCBidXR0b246ZGlzYWJsZWQgeyBvcGFjaXR5OiAuMjg7IGN1cnNvcjogZGVmYXVsdDsgfQojZmlsdGVyLXNldHRpbmdzIC5mcy1vcmQgYnV0
;dG9uIHN2ZyB7IHdpZHRoOiAxMXB4OyBoZWlnaHQ6IDExcHg7IGRpc3BsYXk6IGJsb2NrOyB9CiNmaWx0ZXItc2V0dGluZ3MgLmZzLW1haW4geyBtaW4td2lk
;dGg6IDA7IGRpc3BsYXk6IGZsZXg7IGZsZXgtZGlyZWN0aW9uOiBjb2x1bW47IGdhcDogNHB4OyB9CiNmaWx0ZXItc2V0dGluZ3MgLmZzLXRpdGxlLXJvdyB7
;CiAgZGlzcGxheTogZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsgZ2FwOiA4cHg7IG1pbi13aWR0aDogMDsKfQojZmlsdGVyLXNldHRpbmdzIC5mcy10aXRs
;ZSB7CiAgZm9udC1zaXplOiAxMy41cHg7IGZvbnQtd2VpZ2h0OiA3MDA7IGNvbG9yOiB2YXIoLS10eHQpOwogIG92ZXJmbG93OiBoaWRkZW47IHRleHQtb3Zl
;cmZsb3c6IGVsbGlwc2lzOyB3aGl0ZS1zcGFjZTogbm93cmFwOwp9CiNmaWx0ZXItc2V0dGluZ3MgLmZzLXRhZyB7CiAgZmxleC1zaHJpbms6IDA7IGZvbnQt
;c2l6ZTogMTBweDsgZm9udC13ZWlnaHQ6IDYwMDsgbGluZS1oZWlnaHQ6IDE7CiAgcGFkZGluZzogM3B4IDZweDsgYm9yZGVyLXJhZGl1czogOTk5cHg7CiAg
;YmFja2dyb3VuZDogI2VjZmRmNTsgY29sb3I6ICMwNDc4NTc7IGJvcmRlcjogMXB4IHNvbGlkICNhN2YzZDA7Cn0KI2ZpbHRlci1zZXR0aW5ncyAuZnMtYmxv
;Y2sub2ZmIC5mcy10YWcgewogIGJhY2tncm91bmQ6ICNmMWY1Zjk7IGNvbG9yOiAjNjQ3NDhiOyBib3JkZXItY29sb3I6ICNlMmU4ZjA7Cn0KI2ZpbHRlci1z
;ZXR0aW5ncyAuZnMtcmVnZXggewogIGZvbnQtc2l6ZTogMTFweDsgY29sb3I6IHZhcigtLXR4dDMpOyBsaW5lLWhlaWdodDogMS4zNTsKICB3b3JkLWJyZWFr
;OiBicmVhay1hbGw7IGZvbnQtZmFtaWx5OiBDb25zb2xhcywgIkNhc2NhZGlhIE1vbm8iLCBtb25vc3BhY2U7Cn0KI2ZpbHRlci1zZXR0aW5ncyAuZnMtZW4g
;ewogIGRpc3BsYXk6IGZsZXg7IGZsZXgtZGlyZWN0aW9uOiBjb2x1bW47IGFsaWduLWl0ZW1zOiBmbGV4LWVuZDsgZ2FwOiA0cHg7CiAgcGFkZGluZy10b3A6
;IDJweDsgcGFkZGluZy1yaWdodDogNHB4Owp9CiNmaWx0ZXItc2V0dGluZ3MgLmZzLWVuIC5mcy1lbi1sYWIgewogIGZvbnQtc2l6ZTogMTBweDsgY29sb3I6
;IHZhcigtLXR4dDMpOyBsaW5lLWhlaWdodDogMTsgd2hpdGUtc3BhY2U6IG5vd3JhcDsKfQojZmlsdGVyLXNldHRpbmdzIC5mcy1zd2l0Y2ggewogIHBvc2l0
;aW9uOiByZWxhdGl2ZTsgd2lkdGg6IDM2cHg7IGhlaWdodDogMjBweDsgZmxleC1zaHJpbms6IDA7CiAgYm9yZGVyOiAwOyBib3JkZXItcmFkaXVzOiA5OTlw
;eDsgYmFja2dyb3VuZDogI2NiZDVlMTsgY3Vyc29yOiBwb2ludGVyOyBwYWRkaW5nOiAwOwp9CiNmaWx0ZXItc2V0dGluZ3MgLmZzLXN3aXRjaC5vbiB7IGJh
;Y2tncm91bmQ6ICMzNGQzOTk7IH0KI2ZpbHRlci1zZXR0aW5ncyAuZnMtc3dpdGNoIGkgewogIHBvc2l0aW9uOiBhYnNvbHV0ZTsgdG9wOiAycHg7IGxlZnQ6
;IDJweDsgd2lkdGg6IDE2cHg7IGhlaWdodDogMTZweDsKICBib3JkZXItcmFkaXVzOiA1MCU7IGJhY2tncm91bmQ6ICNmZmY7IGJveC1zaGFkb3c6IDAgMXB4
;IDNweCByZ2JhKDE1LDIzLDQyLC4yKTsKICB0cmFuc2l0aW9uOiB0cmFuc2Zvcm0gLjE1cyBlYXNlOyBwb2ludGVyLWV2ZW50czogbm9uZTsKfQojZmlsdGVy
;LXNldHRpbmdzIC5mcy1zd2l0Y2gub24gaSB7IHRyYW5zZm9ybTogdHJhbnNsYXRlWCgxNnB4KTsgfQojZmlsdGVyLXNldHRpbmdzIC5mcy1mb3JtIHsKICBk
;aXNwbGF5OiBncmlkOyBnYXA6IDhweDsgcGFkZGluZzogMTJweDsgYm9yZGVyLXJhZGl1czogMTJweDsKICBib3JkZXI6IDFweCBkYXNoZWQgI2M1Y2VkZDsg
;YmFja2dyb3VuZDogI2ZhZmJmZDsKfQojZmlsdGVyLXNldHRpbmdzIGxhYmVsIHsgZm9udC1zaXplOiAxMnB4OyBjb2xvcjogdmFyKC0tdHh0Mik7IH0KI2Zp
;bHRlci1zZXR0aW5ncyBpbnB1dCB7CiAgd2lkdGg6IDEwMCU7IGhlaWdodDogMzRweDsgYm9yZGVyOiAxcHggc29saWQgdmFyKC0tbGluZSk7IGJvcmRlci1y
;YWRpdXM6IDhweDsKICBwYWRkaW5nOiAwIDEwcHg7IGZvbnQtc2l6ZTogMTNweDsgYm94LXNpemluZzogYm9yZGVyLWJveDsgb3V0bGluZTogbm9uZTsKfQoj
;ZmlsdGVyLXNldHRpbmdzIGlucHV0OmZvY3VzIHsgYm9yZGVyLWNvbG9yOiAjOTNjNWZkOyBib3gtc2hhZG93OiAwIDAgMCAzcHggcmdiYSg1OSwxMzAsMjQ2
;LC4xMik7IH0KI2ZpbHRlci1zZXR0aW5ncyAuZnMtYWN0aW9ucyB7IGRpc3BsYXk6IGZsZXg7IGdhcDogOHB4OyBqdXN0aWZ5LWNvbnRlbnQ6IGZsZXgtZW5k
;OyBtYXJnaW4tdG9wOiA0cHg7IH0KI2ZpbHRlci1zZXR0aW5ncyAuZnMtYWN0aW9ucyBidXR0b24gewogIGhlaWdodDogMzJweDsgcGFkZGluZzogMCAxNHB4
;OyBib3JkZXItcmFkaXVzOiA4cHg7IGJvcmRlcjogMXB4IHNvbGlkIHZhcigtLWxpbmUpOwogIGJhY2tncm91bmQ6ICNmZmY7IGN1cnNvcjogcG9pbnRlcjsg
;Zm9udC1zaXplOiAxM3B4Owp9CiNmaWx0ZXItc2V0dGluZ3MgLmZzLWFjdGlvbnMgLnByaW1hcnkgewogIGJhY2tncm91bmQ6IHZhcigtLWFjYyk7IGJvcmRl
;ci1jb2xvcjogdmFyKC0tYWNjKTsgY29sb3I6ICNmZmY7Cn0KI2ZpbHRlci1zZXR0aW5ncyAuZnMtYWN0aW9ucyAucHJpbWFyeTpob3ZlciB7IGJhY2tncm91
;bmQ6IHZhcigtLWFjYzIpOyB9CiNmaWx0ZXItc2V0dGluZ3MgLmZzLWZvb3QgewogIGRpc3BsYXk6IGZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGp1c3Rp
;ZnktY29udGVudDogc3BhY2UtYmV0d2VlbjsgZ2FwOiAxMnB4OwogIHBhZGRpbmc6IDEwcHggMTZweCAxNHB4OyBib3JkZXItdG9wOiAxcHggc29saWQgdmFy
;KC0tbGluZSk7Cn0KI2ZpbHRlci1zZXR0aW5ncyAuZnMtZm9vdCBidXR0b24gewogIGJvcmRlcjogMDsgYmFja2dyb3VuZDogdHJhbnNwYXJlbnQ7IGNvbG9y
;OiB2YXIoLS1hY2MyKTsgY3Vyc29yOiBwb2ludGVyOyBmb250LXNpemU6IDEycHg7IHBhZGRpbmc6IDA7Cn0KI2ZpbHRlci1zZXR0aW5ncyAuZnMtZm9vdCAj
;ZnMtcmVzZXQgewogIGNvbG9yOiB2YXIoLS10eHQyKTsKfQojZmlsdGVyLXNldHRpbmdzIC5mcy1mb290ICNmcy1yZXNldDpob3ZlciB7IGNvbG9yOiAjYjkx
;YzFjOyB9CiN0b3AubW9kZS10b29sICNzZWFyY2gtd3JhcCB7IHBhZGRpbmctcmlnaHQ6IDA7IH0KI3RvcC5tb2RlLXRvb2wgI3RvcC1wcmV2aWV3IHsgZGlz
;cGxheTogbm9uZTsgfQojdG9wLm1vZGUtaGFuZGxlICN0b3AtcHJldmlldyB7IGRpc3BsYXk6IG5vbmU7IH0KI3RvcC5tb2RlLWluZm8gI3NlYXJjaC13cmFw
;IHsgZGlzcGxheTogbm9uZSAhaW1wb3J0YW50OyB9CiN0b3AubW9kZS1pbmZvICN0b3AtcHJldmlldyB7IGRpc3BsYXk6IG5vbmU7IH0KI3RvcC5tb2RlLWlu
;Zm8gI3RvcC1yZXN0IHsgZ3JpZC10ZW1wbGF0ZS1jb2x1bW5zOiAxZnI7IG1pbi1oZWlnaHQ6IDA7IH0KI3RvcC5tb2RlLWNvbmZpZyAjdG9wLXByZXZpZXcg
;eyBkaXNwbGF5OiBub25lOyB9CiN0b3AubW9kZS1jb25maWcgI3RvcC1yZXN0IHsKICBncmlkLXRlbXBsYXRlLWNvbHVtbnM6IG1pbm1heCgyNDBweCwgNTAl
;KTsKICBqdXN0aWZ5LWNvbnRlbnQ6IHN0YXJ0Owp9CiN0b3AubW9kZS1jb25maWcgI3NlYXJjaC13cmFwIHsKICBwYWRkaW5nLXJpZ2h0OiAwOyBnYXA6IDhw
;eDsKfQojY2ZnLXNlYXJjaC10YWdzIHsKICBkaXNwbGF5OiBub25lOyBhbGlnbi1pdGVtczogY2VudGVyOyBnYXA6IDZweDsgZmxleC1zaHJpbms6IDA7Cn0K
;I3RvcC5tb2RlLWNvbmZpZyAjY2ZnLXNlYXJjaC10YWdzIHsgZGlzcGxheTogZmxleDsgfQouY2ZnLXN0YWcgewogIGhlaWdodDogMjZweDsgcGFkZGluZzog
;MCAxMHB4OyBib3JkZXI6IDFweCBzb2xpZCAjZTJlOGYwOyBib3JkZXItcmFkaXVzOiA5OTlweDsKICBiYWNrZ3JvdW5kOiAjZmZmOyBjb2xvcjogIzY0NzQ4
;YjsgZm9udC1zaXplOiAxMnB4OyBjdXJzb3I6IHBvaW50ZXI7CiAgdXNlci1zZWxlY3Q6IG5vbmU7IHdoaXRlLXNwYWNlOiBub3dyYXA7Cn0KLmNmZy1zdGFn
;OmhvdmVyIHsgYmFja2dyb3VuZDogI2Y4ZmFmYzsgY29sb3I6ICMzMzQxNTU7IH0KLmNmZy1zdGFnLm9uIHsKICBiYWNrZ3JvdW5kOiAjZjBmZGY0OyBib3Jk
;ZXItY29sb3I6ICM4NmVmYWM7IGNvbG9yOiAjMTU4MDNkOyBmb250LXdlaWdodDogNjAwOwp9CiNjZmctc2VhcmNoLWNsZWFyIHsKICBkaXNwbGF5OiBub25l
;OyBmbGV4LXNocmluazogMDsgYWxpZ24taXRlbXM6IGNlbnRlcjsgZ2FwOiA0cHg7CiAgaGVpZ2h0OiAyMnB4OyBwYWRkaW5nOiAwIDZweCAwIDhweDsgbWFy
;Z2luLXJpZ2h0OiAycHg7CiAgYm9yZGVyOiAwOyBib3JkZXItcmFkaXVzOiA5OTlweDsKICBiYWNrZ3JvdW5kOiAjZWNmZGY1OyBjb2xvcjogIzZiNzI4MDsK
;ICBjdXJzb3I6IHBvaW50ZXI7IHVzZXItc2VsZWN0OiBub25lOyB3aGl0ZS1zcGFjZTogbm93cmFwOwogIGZvbnQtc2l6ZTogMTEuNXB4OyBmb250LXdlaWdo
;dDogNTAwOyBmb250LXZhcmlhbnQtbnVtZXJpYzogdGFidWxhci1udW1zOwogIGxpbmUtaGVpZ2h0OiAxOwp9CiNjZmctc2VhcmNoLWNsZWFyLm9uIHsgZGlz
;cGxheTogaW5saW5lLWZsZXg7IH0KI2NmZy1zZWFyY2gtY2xlYXI6aG92ZXIgeyBiYWNrZ3JvdW5kOiAjZDFmYWU1OyBjb2xvcjogIzRiNTU2MzsgfQojY2Zn
;LXNlYXJjaC1jbGVhciAjY2ZnLXNlYXJjaC1oaXQgeyBkaXNwbGF5OiBpbmxpbmU7IHBhZGRpbmc6IDA7IGNvbG9yOiBpbmhlcml0OyBmb250OiBpbmhlcml0
;OyBvcGFjaXR5OiAuNzI7IH0KI2NmZy1zZWFyY2gtY2xlYXI6aG92ZXIgI2NmZy1zZWFyY2gtaGl0IHsgb3BhY2l0eTogLjg1OyB9CiNjZmctc2VhcmNoLWNs
;ZWFyIC5jZmcteCB7CiAgd2lkdGg6IDE0cHg7IGhlaWdodDogMTRweDsgZGlzcGxheTogYmxvY2s7IGZsZXgtc2hyaW5rOiAwOyBjb2xvcjogIzljYTNhZjsK
;fQojY2ZnLXNlYXJjaC1jbGVhcjpob3ZlciAuY2ZnLXggeyBjb2xvcjogIzZiNzI4MDsgfQojY2ZnLXNlYXJjaC1jbGVhci5vbiB+ICNidG4tY2xlYXIsCiN0
;b3AubW9kZS1jb25maWcgI2J0bi1jbGVhciB7IGRpc3BsYXk6IG5vbmUgIWltcG9ydGFudDsgfQojc2VhcmNoLWJveCB7CiAgcG9zaXRpb246IHJlbGF0aXZl
;OyBkaXNwbGF5OiBmbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBnYXA6IDRweDsKICB3aWR0aDogMTAwJTsgaGVpZ2h0OiAzNHB4OwogIGJvcmRlcjogMXB4
;IHNvbGlkIHZhcigtLWxpbmUpOyBib3JkZXItcmFkaXVzOiA4cHg7CiAgcGFkZGluZzogMCA0cHggMCA4cHg7IGJhY2tncm91bmQ6ICNmYmZiZmQ7IG92ZXJm
;bG93OiB2aXNpYmxlOwp9CiNzZWFyY2gtYm94OmZvY3VzLXdpdGhpbiB7CiAgYm9yZGVyLWNvbG9yOiAjOTNjNWZkOwogIGJveC1zaGFkb3c6IDAgMCAwIDNw
;eCByZ2JhKDU5LDEzMCwyNDYsLjE1KTsKICBiYWNrZ3JvdW5kOiAjZmZmOwp9CiNzZWFyY2gtaWNvIHsKICBmbGV4LXNocmluazogMDsgd2lkdGg6IDI0cHg7
;IGhlaWdodDogMjRweDsgbWFyZ2luOiAwIDFweCAwIC0ycHg7IHBhZGRpbmc6IDA7CiAgYm9yZGVyOiAwOyBib3JkZXItcmFkaXVzOiA2cHg7IGJhY2tncm91
;bmQ6IHRyYW5zcGFyZW50OwogIGNvbG9yOiB2YXIoLS10eHQzKTsgZGlzcGxheTogaW5saW5lLWZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGp1c3RpZnkt
;Y29udGVudDogY2VudGVyOwogIGN1cnNvcjogcG9pbnRlcjsgbGluZS1oZWlnaHQ6IDA7Cn0KI3NlYXJjaC1pY28gc3ZnIHsgd2lkdGg6IDE1cHg7IGhlaWdo
;dDogMTVweDsgZGlzcGxheTogYmxvY2s7IH0KI3NlYXJjaC1pY286aG92ZXIsICNzZWFyY2gtaWNvLm9uIHsgYmFja2dyb3VuZDogI2VlZjJmZjsgY29sb3I6
;IHZhcigtLWFjYzIpOyB9CiNzZWFyY2gtYm94OmZvY3VzLXdpdGhpbiAjc2VhcmNoLWljbyB7IGNvbG9yOiAjNjQ3NDhiOyB9CiNzZWFyY2gtYm94OmZvY3Vz
;LXdpdGhpbiAjc2VhcmNoLWljbzpob3ZlciwKI3NlYXJjaC1ib3g6Zm9jdXMtd2l0aGluICNzZWFyY2gtaWNvLm9uIHsgY29sb3I6IHZhcigtLWFjYzIpOyB9
;CiNxIHsKICBmbGV4OiAxOyBtaW4td2lkdGg6IDA7IGhlaWdodDogMTAwJTsKICBib3JkZXI6IDA7IGJvcmRlci1yYWRpdXM6IDA7IHBhZGRpbmc6IDA7IG91
;dGxpbmU6IG5vbmU7IGJhY2tncm91bmQ6IHRyYW5zcGFyZW50OwogIGZvbnQtc2l6ZTogMTMuNXB4OyBjb2xvcjogdmFyKC0tdHh0KTsKfQojcTo6cGxhY2Vo
;b2xkZXIgeyBjb2xvcjogdmFyKC0tdHh0Myk7IH0KI2J0bi1jbGVhciB7CiAgZGlzcGxheTogbm9uZTsgZmxleC1zaHJpbms6IDA7IGhlaWdodDogMjJweDsg
;cGFkZGluZzogMCAxMHB4OwogIGJvcmRlcjogMDsgYm9yZGVyLXJhZGl1czogOTk5cHg7IGJhY2tncm91bmQ6ICNlZWYxZjY7CiAgY29sb3I6IHZhcigtLXR4
;dDIpOyBmb250LXNpemU6IDEycHg7IGN1cnNvcjogcG9pbnRlcjsgbGluZS1oZWlnaHQ6IDIycHg7Cn0KI2J0bi1jbGVhci5vbiB7IGRpc3BsYXk6IGlubGlu
;ZS1mbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBqdXN0aWZ5LWNvbnRlbnQ6IGNlbnRlcjsgfQojYnRuLWNsZWFyOmhvdmVyIHsgYmFja2dyb3VuZDogI2Uy
;ZThmMDsgY29sb3I6IHZhcigtLXR4dCk7IH0KI2J0bi1oaXN0IHsgZGlzcGxheTogbm9uZSAhaW1wb3J0YW50OyB9CiNoaXN0LW1lbnUgewogIGRpc3BsYXk6
;IG5vbmU7IHBvc2l0aW9uOiBhYnNvbHV0ZTsgdG9wOiAxMDAlOyBsZWZ0OiAtMXB4OyByaWdodDogLTFweDsgei1pbmRleDogNDU7CiAgbWF4LWhlaWdodDog
;MjgwcHg7IG92ZXJmbG93OiBhdXRvOwogIGJhY2tncm91bmQ6ICNmZmY7IGJvcmRlcjogMXB4IHNvbGlkIHZhcigtLWxpbmUpOyBib3JkZXItdG9wOiAwOwog
;IGJveC1zaGFkb3c6IDAgOHB4IDE4cHggcmdiYSgxNSwgMjMsIDQyLCAuMDgpOyBwYWRkaW5nOiAycHggNHB4IDRweDsKICBib3JkZXItcmFkaXVzOiAwIDAg
;OHB4IDhweDsKfQojaGlzdC1tZW51Lm9uIHsgZGlzcGxheTogYmxvY2s7IH0KI3NlYXJjaC1ib3guaGlzdC1vcGVuIHsKICBib3JkZXItYm90dG9tLWxlZnQt
;cmFkaXVzOiAwOyBib3JkZXItYm90dG9tLXJpZ2h0LXJhZGl1czogMDsKfQojaGlzdC1tZW51IGJ1dHRvbiB7CiAgZGlzcGxheTogZmxleDsgYWxpZ24taXRl
;bXM6IGNlbnRlcjsgZ2FwOiA4cHg7IHdpZHRoOiAxMDAlOyB0ZXh0LWFsaWduOiBsZWZ0OwogIGJvcmRlcjogMDsgYmFja2dyb3VuZDogdHJhbnNwYXJlbnQ7
;IHBhZGRpbmc6IDdweCAxMHB4OyBib3JkZXItcmFkaXVzOiA2cHg7CiAgY3Vyc29yOiBwb2ludGVyOyBjb2xvcjogdmFyKC0tdHh0KTsgZm9udC1zaXplOiAx
;M3B4Owp9CiNoaXN0LW1lbnUgYnV0dG9uOmhvdmVyIHsgYmFja2dyb3VuZDogI2YzZjRmNjsgfQojaGlzdC1tZW51IGJ1dHRvbiAuaGlzdC1pY28gewogIGZs
;ZXgtc2hyaW5rOiAwOyB3aWR0aDogMTRweDsgaGVpZ2h0OiAxNHB4OyBjb2xvcjogdmFyKC0tdHh0Myk7IGRpc3BsYXk6IGJsb2NrOwp9CiNoaXN0LW1lbnUg
;YnV0dG9uOmhvdmVyIC5oaXN0LWljbyB7IGNvbG9yOiB2YXIoLS1hY2MyKTsgfQojaGlzdC1tZW51IGJ1dHRvbiAuaGlzdC10eHQgewogIGZsZXg6IDE7IG1p
;bi13aWR0aDogMDsgb3ZlcmZsb3c6IGhpZGRlbjsgdGV4dC1vdmVyZmxvdzogZWxsaXBzaXM7IHdoaXRlLXNwYWNlOiBub3dyYXA7Cn0KI2hpc3QtbWVudSAu
;aGlzdC1lbXB0eSB7CiAgcGFkZGluZzogMTBweDsgY29sb3I6IHZhcigtLXR4dDMpOyBmb250LXNpemU6IDEycHg7IHRleHQtYWxpZ246IGNlbnRlcjsKfQoj
;dG9wLXByZXZpZXcgewogIGRpc3BsYXk6IGZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGdhcDogMTBweDsgbWluLXdpZHRoOiAwOyBwYWRkaW5nOiAwIDEy
;cHg7CiAgYmFja2dyb3VuZDogdmFyKC0tY2hyb21lKTsgY29sb3I6IHZhcigtLXR4dDIpOyBmb250LXNpemU6IDEycHg7IG92ZXJmbG93OiBoaWRkZW47Cn0K
;I3RvcC1wcmV2aWV3IC5wdi1tZXRhIHsKICBib3JkZXI6IDA7IHBhZGRpbmc6IDA7IGZsZXg6IDE7IG1pbi13aWR0aDogMDsKICBmbGV4LXdyYXA6IG5vd3Jh
;cDsgb3ZlcmZsb3c6IGhpZGRlbjsKfQojYnRuLWdvdG8tcHJvYyB7CiAgZmxleC1zaHJpbms6IDA7IGhlaWdodDogMzBweDsgcGFkZGluZzogMCAxMnB4Owog
;IGJvcmRlcjogMDsgYm9yZGVyLXJhZGl1czogOTk5cHg7IGN1cnNvcjogcG9pbnRlcjsKICBiYWNrZ3JvdW5kOiAjZThmMWZmOyBjb2xvcjogIzFkNGVkODsg
;Zm9udC1zaXplOiAxMi41cHg7IGZvbnQtd2VpZ2h0OiA2MDA7Cn0KI2J0bi1nb3RvLXByb2M6aG92ZXIgeyBiYWNrZ3JvdW5kOiAjZGJlYWZlOyB9Cgojdmll
;dy1zZWFyY2ggeyBkaXNwbGF5OiBmbGV4OyBmbGV4LWRpcmVjdGlvbjogY29sdW1uOyBmbGV4OiAxOyBtaW4taGVpZ2h0OiAwOyB9CiN2aWV3LXNlYXJjaC5o
;aWRkZW4geyBkaXNwbGF5OiBub25lOyB9CiN2aWV3LXByb2MgewogIGRpc3BsYXk6IG5vbmU7IGZsZXgtZGlyZWN0aW9uOiBjb2x1bW47IGZsZXg6IDE7IG1p
;bi1oZWlnaHQ6IDA7CiAgYmFja2dyb3VuZDogI2YwZjJmNTsKfQojdmlldy1wcm9jLm9uIHsgZGlzcGxheTogZmxleDsgfQoucHJvYy10b3AgewogIGRpc3Bs
;YXk6IGZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGdhcDogMTBweDsgcGFkZGluZzogMTBweCAxNHB4IDhweDsKICBiYWNrZ3JvdW5kOiAjZmZmOyBib3Jk
;ZXItYm90dG9tOiAxcHggc29saWQgdmFyKC0tbGluZSk7CiAgLXdlYmtpdC1hcHAtcmVnaW9uOiBkcmFnOyBhcHAtcmVnaW9uOiBkcmFnOwp9Ci5wcm9jLXRv
;cCAubm8tZHJhZywgLnByb2MtdG9wIGJ1dHRvbiwgLnByb2MtdG9wIGlucHV0IHsKICAtd2Via2l0LWFwcC1yZWdpb246IG5vLWRyYWc7IGFwcC1yZWdpb246
;IG5vLWRyYWc7Cn0KLnByb2MtdGFicyB7IGRpc3BsYXk6IGZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGdhcDogOHB4OyBmbGV4LXdyYXA6IHdyYXA7IH0K
;LnByb2MtdGFiIHsKICBoZWlnaHQ6IDMwcHg7IHBhZGRpbmc6IDAgMTRweDsgYm9yZGVyOiAwOyBib3JkZXItcmFkaXVzOiA5OTlweDsKICBiYWNrZ3JvdW5k
;OiAjZWNlZmYzOyBjb2xvcjogIzRiNTU2MzsgZm9udC1zaXplOiAxM3B4OyBjdXJzb3I6IHBvaW50ZXI7Cn0KLnByb2MtdGFiLm9uIHsgYmFja2dyb3VuZDog
;IzNiODJmNjsgY29sb3I6ICNmZmY7IGZvbnQtd2VpZ2h0OiA2MDA7IH0KLnByb2MtdGFiOmRpc2FibGVkIHsgb3BhY2l0eTogLjU1OyBjdXJzb3I6IGRlZmF1
;bHQ7IH0KLnByb2MtdG9wLXJpZ2h0IHsgbWFyZ2luLWxlZnQ6IGF1dG87IGRpc3BsYXk6IGZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGdhcDogOHB4OyB9
;CiNidG4tYmFjay1zZWFyY2ggewogIGhlaWdodDogMzBweDsgcGFkZGluZzogMCAxMnB4OyBib3JkZXI6IDA7IGJvcmRlci1yYWRpdXM6IDk5OXB4OwogIGJh
;Y2tncm91bmQ6ICNmM2Y0ZjY7IGNvbG9yOiB2YXIoLS10eHQpOyBmb250LXNpemU6IDEyLjVweDsgY3Vyc29yOiBwb2ludGVyOwp9CiNidG4tYmFjay1zZWFy
;Y2g6aG92ZXIgeyBiYWNrZ3JvdW5kOiAjZTVlN2ViOyB9Ci5wcm9jLXNlYXJjaCB7CiAgZGlzcGxheTogZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsgZ2Fw
;OiA4cHg7IHBhZGRpbmc6IDhweCAxNHB4OwogIGJhY2tncm91bmQ6ICNmZmY7IGJvcmRlci1ib3R0b206IDFweCBzb2xpZCB2YXIoLS1saW5lKTsKfQoucHJv
;Yy1zZWFyY2ggaW5wdXQgewogIGZsZXg6IDE7IGhlaWdodDogMzJweDsgYm9yZGVyOiAxcHggc29saWQgdmFyKC0tbGluZSk7IGJvcmRlci1yYWRpdXM6IDhw
;eDsKICBwYWRkaW5nOiAwIDEycHg7IG91dGxpbmU6IG5vbmU7IGJhY2tncm91bmQ6ICNmYmZiZmQ7IGZvbnQtc2l6ZTogMTNweDsKfQoucHJvYy1zZWFyY2gg
;aW5wdXQ6Zm9jdXMgewogIGJvcmRlci1jb2xvcjogIzkzYzVmZDsgYm94LXNoYWRvdzogMCAwIDAgM3B4IHJnYmEoNTksMTMwLDI0NiwuMTUpOyBiYWNrZ3Jv
;dW5kOiAjZmZmOwp9Ci5wcm9jLXRhYmxlLXdyYXAgewogIGZsZXg6IDE7IG1pbi1oZWlnaHQ6IDA7IG1hcmdpbjogMCAxMHB4IDhweDsgYm9yZGVyOiAxcHgg
;c29saWQgI2Q0ZDRkNDsKICBib3JkZXItcmFkaXVzOiAwOyBvdmVyZmxvdzogaGlkZGVuOyBiYWNrZ3JvdW5kOiAjZmZmOwogIGRpc3BsYXk6IGZsZXg7IGZs
;ZXgtZGlyZWN0aW9uOiBjb2x1bW47Cn0KLnByb2MtdGFibGUtd3JhcC5oaWRkZW4geyBkaXNwbGF5OiBub25lOyB9Ci8qIOe7n+S4gOWIl+Wuve+8muihqOWk
;tOS4juaVsOaNruWQjOS4gOWll+aooeadv++8jOmBv+WFjea7muWKqOadoemUmeS9jSAqLwoucHJvYy1jb2xzIHsKICAtLWMtbmFtZTogbWlubWF4KDE4MHB4
;LCAxLjZmcik7CiAgLS1jLWNwdTogNzJweDsKICAtLWMtbWVtOiA5NnB4OwogIC0tYy1waWQ6IDgwcHg7CiAgLS1jLXByb3RvOiA2OHB4OwogIC0tYy1saXA6
;IG1pbm1heCgxMTBweCwgMWZyKTsKICAtLWMtbHBvcnQ6IDc2cHg7CiAgLS1jLXJpcDogbWlubWF4KDExMHB4LCAxZnIpOwogIC0tYy1ycG9ydDogNzZweDsK
;ICAtLWMtc3RhdGU6IDg4cHg7CiAgZGlzcGxheTogZ3JpZDsKICBncmlkLXRlbXBsYXRlLWNvbHVtbnM6IHZhcigtLWMtbmFtZSkgdmFyKC0tYy1jcHUpIHZh
;cigtLWMtbWVtKSB2YXIoLS1jLXBpZCkgdmFyKC0tYy1wcm90bykgdmFyKC0tYy1saXApIHZhcigtLWMtbHBvcnQpIHZhcigtLWMtcmlwKSB2YXIoLS1jLXJw
;b3J0KSB2YXIoLS1jLXN0YXRlKTsKICBnYXA6IDA7CiAgYWxpZ24taXRlbXM6IHN0cmV0Y2g7CiAgd2lkdGg6IDEwMCU7CiAgYm94LXNpemluZzogYm9yZGVy
;LWJveDsKfQoucHJvYy1zY3JvbGwgewogIGZsZXg6IDE7IG1pbi1oZWlnaHQ6IDA7IG92ZXJmbG93OiBhdXRvOwogIHNjcm9sbGJhci1ndXR0ZXI6IHN0YWJs
;ZTsKfQovKiBXaW4xMSDku7vliqHnrqHnkIblmajpo47moLzlj4zlsYLooajlpLTvvJrnmb3lupXjgIHkuIrkuIvlsYXkuK3lr7npvZAgKi8KLnByb2MtaGVh
;ZCB7CiAgcG9zaXRpb246IHN0aWNreTsgdG9wOiAwOyB6LWluZGV4OiAyOwogIGJhY2tncm91bmQ6ICNmZmY7IGNvbG9yOiAjNWE1YTVhOwogIGhlaWdodDog
;NDhweDsgbWluLWhlaWdodDogNDhweDsgcGFkZGluZzogMDsKICBib3JkZXItYm90dG9tOiAxcHggc29saWQgI2U1ZTVlNTsKfQoucHJvYy1oY2VsbCB7CiAg
;ZGlzcGxheTogZmxleDsgZmxleC1kaXJlY3Rpb246IGNvbHVtbjsganVzdGlmeS1jb250ZW50OiBzcGFjZS1iZXR3ZWVuOwogIGFsaWduLWl0ZW1zOiBzdHJl
;dGNoOwogIG1pbi13aWR0aDogMDsgaGVpZ2h0OiAxMDAlOyBwYWRkaW5nOiA2cHggOHB4IDdweDsKICBib3JkZXItcmlnaHQ6IDFweCBzb2xpZCAjZTVlNWU1
;OyBib3gtc2l6aW5nOiBib3JkZXItYm94OwogIGN1cnNvcjogcG9pbnRlcjsgdXNlci1zZWxlY3Q6IG5vbmU7CiAgYmFja2dyb3VuZDogI2ZmZjsKfQoucHJv
;Yy1oY2VsbDpsYXN0LWNoaWxkIHsgYm9yZGVyLXJpZ2h0OiAwOyB9Ci5wcm9jLWhjZWxsOmhvdmVyIHsgYmFja2dyb3VuZDogI2Y3ZjdmNzsgfQoucHJvYy1o
;Y2VsbC5zb3J0ZWQgeyBiYWNrZ3JvdW5kOiAjZmZmOyB9Ci5wcm9jLWgtdG9wIHsKICBmbGV4OiAxOwogIG1pbi1oZWlnaHQ6IDE4cHg7CiAgZm9udC1zaXpl
;OiAxM3B4OyBmb250LXdlaWdodDogNjAwOwogIGNvbG9yOiAjMWIxYjFiOyB3aGl0ZS1zcGFjZTogbm93cmFwOwogIGRpc3BsYXk6IGZsZXg7IGFsaWduLWl0
;ZW1zOiBmbGV4LXN0YXJ0OyBqdXN0aWZ5LWNvbnRlbnQ6IGNlbnRlcjsKICBnYXA6IDRweDsgbGluZS1oZWlnaHQ6IDEuMjsKICBwb3NpdGlvbjogcmVsYXRp
;dmU7Cn0KLnByb2MtY2VsbC1uYW1lIC5wcm9jLWgtdG9wIHsganVzdGlmeS1jb250ZW50OiBjZW50ZXI7IH0KLnByb2MtaC1sYWIgewogIGZsZXg6IDAgMCBh
;dXRvOwogIGZvbnQtc2l6ZTogMTJweDsgZm9udC13ZWlnaHQ6IDQwMDsKICBjb2xvcjogIzVhNWE1YTsgdGV4dC1hbGlnbjogY2VudGVyOyB3aGl0ZS1zcGFj
;ZTogbm93cmFwOwogIGxpbmUtaGVpZ2h0OiAxLjI7Cn0KLnByb2MtY2VsbC1uYW1lIC5wcm9jLWgtbGFiIHsgdGV4dC1hbGlnbjogbGVmdDsgfQoucHJvYy1o
;LXNvcnQgewogIGRpc3BsYXk6IGlubGluZS1ibG9jazsgd2lkdGg6IDA7IGhlaWdodDogMDsKICBib3JkZXItbGVmdDogNHB4IHNvbGlkIHRyYW5zcGFyZW50
;OyBib3JkZXItcmlnaHQ6IDRweCBzb2xpZCB0cmFuc3BhcmVudDsKICBvcGFjaXR5OiAwOyBmbGV4LXNocmluazogMDsKfQoucHJvYy1oY2VsbC5zb3J0ZWQg
;LnByb2MtaC1zb3J0IHsgb3BhY2l0eTogMTsgfQoucHJvYy1oY2VsbC5zb3J0ZWQuYXNjIC5wcm9jLWgtc29ydCB7CiAgYm9yZGVyLWJvdHRvbTogNXB4IHNv
;bGlkICMxYjFiMWI7IGJvcmRlci10b3A6IDA7Cn0KLnByb2MtaGNlbGwuc29ydGVkLmRlc2MgLnByb2MtaC1zb3J0IHsKICBib3JkZXItdG9wOiA1cHggc29s
;aWQgIzFiMWIxYjsgYm9yZGVyLWJvdHRvbTogMDsKfQoucHJvYy1ib2R5IHsgZGlzcGxheTogYmxvY2s7IH0KLnByb2Mtcm93IHsKICBtaW4taGVpZ2h0OiAy
;OHB4OyBoZWlnaHQ6IDI4cHg7IHBhZGRpbmc6IDA7CiAgZm9udC1zaXplOiAxMnB4OyBjb2xvcjogIzFiMWIxYjsKICBib3JkZXItYm90dG9tOiAwOwogIGN1
;cnNvcjogZGVmYXVsdDsgYmFja2dyb3VuZDogI2ZmZjsgdXNlci1zZWxlY3Q6IG5vbmU7CiAgcG9zaXRpb246IHJlbGF0aXZlOwp9Ci5wcm9jLXJvdzpob3Zl
;ciB7IGJhY2tncm91bmQ6ICNmNWY4ZmI7IH0KLnByb2Mtcm93Lm9uLCAucHJvYy1yb3cub246aG92ZXIgeyBiYWNrZ3JvdW5kOiAjY2NlOGZmOyB9Ci8qIOWQ
;jOWQjei/m+eoi+i/nue7reaute+8muS7hea3oee7v+iJsuWkluahhu+8jOaXoOW6leiJsiAqLwoucHJvYy1yb3cuZ3JwLWZpcnN0IHsKICBib3gtc2hhZG93
;OiBpbnNldCAwIDJweCAwICM4OGZmYzEsIGluc2V0IDJweCAwIDAgIzg4ZmZjMSwgaW5zZXQgLTJweCAwIDAgIzg4ZmZjMTsKICBib3JkZXItcmFkaXVzOiA0
;cHggNHB4IDAgMDsKfQoucHJvYy1yb3cuZ3JwLW1pZCB7CiAgYm94LXNoYWRvdzogaW5zZXQgMnB4IDAgMCAjODhmZmMxLCBpbnNldCAtMnB4IDAgMCAjODhm
;ZmMxOwogIGJvcmRlci1yYWRpdXM6IDA7Cn0KLnByb2Mtcm93LmdycC1sYXN0IHsKICBib3gtc2hhZG93OiBpbnNldCAwIC0ycHggMCAjODhmZmMxLCBpbnNl
;dCAycHggMCAwICM4OGZmYzEsIGluc2V0IC0ycHggMCAwICM4OGZmYzE7CiAgYm9yZGVyLXJhZGl1czogMCAwIDRweCA0cHg7Cn0KLnByb2Mtcm93LmdycC1v
;bmx5LAoucHJvYy1yb3cuZ3JwLWZpcnN0LmdycC1sYXN0IHsKICBib3gtc2hhZG93OiBpbnNldCAwIDAgMCAycHggIzg4ZmZjMTsKICBib3JkZXItcmFkaXVz
;OiA0cHg7Cn0KLyog57uE5YaF6Z2e54Sm54K56KGM5L+d5oyB55m95bqV77yb55yf5q2j54K55Lit55qE6YKj5LiA6KGM5L+d55WZ6JOd6Imy5bqVICovCi5w
;cm9jLXJvdy5ncnA6bm90KC5vbikgeyBiYWNrZ3JvdW5kOiAjZmZmOyB9Ci5wcm9jLXJvdy5ncnA6bm90KC5vbik6aG92ZXIgeyBiYWNrZ3JvdW5kOiAjZjVm
;OGZiOyB9Ci8qIFdpbmRvd3Mg5reh56uW57q/77yb5Y2V5YWD5qC85ZCM5a695ZCM5Z6r77yM6KGo5aS05LiO5pWw5o2u5Lil5qC85a+56b2QICovCi5wcm9j
;LXJvdyA+IGRpdiB7CiAgZGlzcGxheTogZmxleDsKICBhbGlnbi1pdGVtczogY2VudGVyOwogIG1pbi13aWR0aDogMDsKICBoZWlnaHQ6IDEwMCU7CiAgcGFk
;ZGluZzogMCA4cHg7CiAgYm9yZGVyLXJpZ2h0OiAxcHggc29saWQgI2U1ZTVlNTsKICBib3gtc2l6aW5nOiBib3JkZXItYm94OwogIG92ZXJmbG93OiBoaWRk
;ZW47CiAgd2hpdGUtc3BhY2U6IG5vd3JhcDsKfQoucHJvYy1yb3cgPiBkaXY6bGFzdC1jaGlsZCB7IGJvcmRlci1yaWdodDogMDsgfQoucHJvYy1jZWxsLW5h
;bWUgeyBqdXN0aWZ5LWNvbnRlbnQ6IGZsZXgtc3RhcnQ7IH0KLnByb2MtY2VsbC1waWQsCi5wcm9jLWNlbGwtcG9ydCwKLnByb2MtY2VsbC1jcHUsCi5wcm9j
;LWNlbGwtbWVtIHsganVzdGlmeS1jb250ZW50OiBmbGV4LWVuZDsgfQoucHJvYy1jZWxsLXByb3RvIHsganVzdGlmeS1jb250ZW50OiBjZW50ZXI7IH0KLnBy
;b2MtY2VsbC1zdGF0ZSB7IGp1c3RpZnktY29udGVudDogZmxleC1zdGFydDsgZ2FwOiA2cHg7IH0KLnByb2MtY2VsbC1pcCB7IGp1c3RpZnktY29udGVudDog
;ZmxleC1zdGFydDsgfQoucHJvYy1jZWxsLWNwdSwgLnByb2MtY2VsbC1tZW0gewogIGJhY2tncm91bmQ6ICNjZWZmZTU7Cn0KLnByb2MtY2VsbC1jcHUuaG90
;LCAucHJvYy1jZWxsLW1lbS5ob3QgewogIGJhY2tncm91bmQ6ICM4OGZmYzE7Cn0KLnByb2Mtcm93Lm9uIC5wcm9jLWNlbGwtY3B1LAoucHJvYy1yb3cub24g
;LnByb2MtY2VsbC1tZW0gewogIGJhY2tncm91bmQ6ICNjZWZmZTU7Cn0KLnByb2Mtcm93Lm9uIC5wcm9jLWNlbGwtY3B1LmhvdCwKLnByb2Mtcm93Lm9uIC5w
;cm9jLWNlbGwtbWVtLmhvdCB7CiAgYmFja2dyb3VuZDogIzg4ZmZjMTsKfQoucHJvYy1oY2VsbC5wcm9jLWNlbGwtY3B1LAoucHJvYy1oY2VsbC5wcm9jLWNl
;bGwtbWVtIHsKICBiYWNrZ3JvdW5kOiAjZmZmOwp9Ci5wcm9jLWhjZWxsLnByb2MtY2VsbC1jcHUuaG90LAoucHJvYy1oY2VsbC5wcm9jLWNlbGwtbWVtLmhv
;dCB7CiAgYmFja2dyb3VuZDogIzg4ZmZjMTsKfQoucHJvYy1oY2VsbC5wcm9jLWNlbGwtY3B1Om5vdCguaG90KSwKLnByb2MtaGNlbGwucHJvYy1jZWxsLW1l
;bTpub3QoLmhvdCkgewogIGJhY2tncm91bmQ6ICNjZWZmZTU7Cn0KLnByb2MtbmFtZSB7CiAgZGlzcGxheTogZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsg
;Z2FwOiA4cHg7CiAgbWluLXdpZHRoOiAwOyB3aWR0aDogMTAwJTsgb3ZlcmZsb3c6IGhpZGRlbjsKfQoucHJvYy1uYW1lIGltZywgLnByb2MtbmFtZSAucHJv
;Yy1pY28tcGggewogIHdpZHRoOiAxNnB4OyBoZWlnaHQ6IDE2cHg7IG9iamVjdC1maXQ6IGNvbnRhaW47IGZsZXgtc2hyaW5rOiAwOwp9Ci5wcm9jLW5hbWUg
;LnByb2MtaWNvLXBoIHsKICBkaXNwbGF5OiBpbmxpbmUtYmxvY2s7IGJhY2tncm91bmQ6ICNlOGVhZWQ7IGJvcmRlci1yYWRpdXM6IDJweDsKICBib3JkZXI6
;IDFweCBzb2xpZCAjZDBkNGRhOwp9Ci5wcm9jLW5hbWUgLnByb2MtbGFiZWwgewogIG92ZXJmbG93OiBoaWRkZW47IHRleHQtb3ZlcmZsb3c6IGVsbGlwc2lz
;OyB3aGl0ZS1zcGFjZTogbm93cmFwOyBtaW4td2lkdGg6IDA7Cn0KLnByb2MtbmV0LWRvdCB7CiAgd2lkdGg6IDdweDsgaGVpZ2h0OiA3cHg7IGJvcmRlci1y
;YWRpdXM6IDUwJTsgZmxleC1zaHJpbms6IDA7CiAgYmFja2dyb3VuZDogIzIyYzU1ZTsgYm94LXNoYWRvdzogMCAwIDAgMnB4IHJnYmEoMzQsIDE5NywgOTQs
;IC4yKTsKfQoucHJvYy1uZXQtZG90LmhpZGRlbiB7IGRpc3BsYXk6IG5vbmU7IH0KLnByb2MtbnVtIHsKICBmb250LXZhcmlhbnQtbnVtZXJpYzogdGFidWxh
;ci1udW1zOyBjb2xvcjogIzFiMWIxYjsKICB3aWR0aDogMTAwJTsKfQoucHJvYy1udW0ucG9ydC1ob3QgewogIGNvbG9yOiAjYzI0MTBjOwogIGZvbnQtd2Vp
;Z2h0OiA3MDA7Cn0KLyog4pSA4pSAIOWFs+iBlOWPpeafhO+8iOeOsOS7o+i9u+mHj+ihqOagvO+8ieKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKU
;gOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgCAqLwojaGFuZGxlLXBhbmVsIHsKICBmbGV4OiAxOyBtaW4taGVpZ2h0OiAwOyBt
;YXJnaW46IDA7IGJvcmRlcjogMDsKICBiYWNrZ3JvdW5kOiAjZmZmOyBkaXNwbGF5OiBmbGV4OyBmbGV4LWRpcmVjdGlvbjogY29sdW1uOyBvdmVyZmxvdzog
;aGlkZGVuOwp9CiNoYW5kbGUtcGFuZWwuaGlkZGVuIHsgZGlzcGxheTogbm9uZTsgfQouaGFuZGxlLWJhbm5lciB7CiAgZGlzcGxheTogbm9uZTsgYWxpZ24t
;aXRlbXM6IGNlbnRlcjsgZ2FwOiA4cHg7CiAgbWFyZ2luOiAwOyBwYWRkaW5nOiA4cHggMTRweDsKICBiYWNrZ3JvdW5kOiAjZjBmN2ZmOyBib3JkZXI6IDA7
;IGJvcmRlci1yYWRpdXM6IDA7CiAgY29sb3I6ICMxZTNhNWY7IGZvbnQtc2l6ZTogMTIuNXB4OyBmbGV4LXNocmluazogMDsKfQouaGFuZGxlLWJhbm5lci5v
;biB7IGRpc3BsYXk6IGZsZXg7IH0KLmhhbmRsZS1iYW5uZXI6OmJlZm9yZSB7CiAgY29udGVudDogIiI7IHdpZHRoOiA2cHg7IGhlaWdodDogNnB4OyBib3Jk
;ZXItcmFkaXVzOiA1MCU7CiAgYmFja2dyb3VuZDogIzNiODJmNjsgZmxleC1zaHJpbms6IDA7Cn0KLmhhbmRsZS1jb2xzIHsKICAtLWgtbmFtZTogbWlubWF4
;KDE0MHB4LCAxLjJmcik7CiAgLS1oLXBpZDogODhweDsKICAtLWgtcG9ydDogODRweDsKICAtLWgtcnBvcnQ6IDg0cHg7CiAgLS1oLXR5cGU6IDcycHg7CiAg
;LS1oLXBhdGg6IG1pbm1heCgxNjBweCwgMmZyKTsKICBkaXNwbGF5OiBncmlkOwogIGdyaWQtdGVtcGxhdGUtY29sdW1uczogdmFyKC0taC1uYW1lKSB2YXIo
;LS1oLXBpZCkgdmFyKC0taC10eXBlKSB2YXIoLS1oLXBhdGgpOwogIGdhcDogMDsgd2lkdGg6IDEwMCU7IGJveC1zaXppbmc6IGJvcmRlci1ib3g7IGFsaWdu
;LWl0ZW1zOiBzdHJldGNoOwp9Ci5oYW5kbGUtY29scy5wb3J0LW1vZGUgewogIGdyaWQtdGVtcGxhdGUtY29sdW1uczogdmFyKC0taC1uYW1lKSB2YXIoLS1o
;LXBpZCkgdmFyKC0taC1wb3J0KSB2YXIoLS1oLXJwb3J0KSB2YXIoLS1oLXR5cGUpIHZhcigtLWgtcGF0aCk7Cn0KLmhhbmRsZS1jb2wtcG9ydC5oaWRkZW4s
;IC5oYW5kbGUtY29sLXJwb3J0LmhpZGRlbiB7IGRpc3BsYXk6IG5vbmUgIWltcG9ydGFudDsgfQouaGFuZGxlLWNvbHMucG9ydC1tb2RlIC5oYW5kbGUtY29s
;LXBvcnQuaGlkZGVuLAouaGFuZGxlLWNvbHMucG9ydC1tb2RlIC5oYW5kbGUtY29sLXJwb3J0LmhpZGRlbiB7IGRpc3BsYXk6IGZsZXggIWltcG9ydGFudDsg
;fQouaGFuZGxlLXNjcm9sbCB7IGZsZXg6IDE7IG1pbi1oZWlnaHQ6IDA7IG92ZXJmbG93OiBhdXRvOyBwYWRkaW5nOiAwIDhweCA4cHg7IH0KLmhhbmRsZS1o
;ZWFkIHsKICBwb3NpdGlvbjogc3RpY2t5OyB0b3A6IDA7IHotaW5kZXg6IDI7IGhlaWdodDogMzRweDsgbWluLWhlaWdodDogMzRweDsKICBiYWNrZ3JvdW5k
;OiAjZmZmOyBjb2xvcjogdmFyKC0tdHh0Mik7IGZvbnQtc2l6ZTogMTJweDsgZm9udC13ZWlnaHQ6IDYwMDsKICBib3JkZXItYm90dG9tOiAxcHggc29saWQg
;dmFyKC0tbGluZSk7Cn0KLmhhbmRsZS1oY2VsbCB7CiAgY3Vyc29yOiBwb2ludGVyOyB1c2VyLXNlbGVjdDogbm9uZTsgZ2FwOiA2cHg7Cn0KLmhhbmRsZS1o
;Y2VsbDpob3ZlciB7IGJhY2tncm91bmQ6ICNmNWY3ZmI7IGNvbG9yOiB2YXIoLS10eHQpOyB9Ci5oYW5kbGUtaGNlbGwuc29ydGVkIHsgY29sb3I6IHZhcigt
;LXR4dCk7IH0KLmhhbmRsZS1oY2VsbCAuaC1zb3J0IHsKICBkaXNwbGF5OiBpbmxpbmUtYmxvY2s7IHdpZHRoOiAwOyBoZWlnaHQ6IDA7CiAgYm9yZGVyLWxl
;ZnQ6IDRweCBzb2xpZCB0cmFuc3BhcmVudDsgYm9yZGVyLXJpZ2h0OiA0cHggc29saWQgdHJhbnNwYXJlbnQ7CiAgb3BhY2l0eTogMDsgZmxleC1zaHJpbms6
;IDA7Cn0KLmhhbmRsZS1oY2VsbC5zb3J0ZWQgLmgtc29ydCB7IG9wYWNpdHk6IDE7IH0KLmhhbmRsZS1oY2VsbC5zb3J0ZWQuYXNjIC5oLXNvcnQgewogIGJv
;cmRlci1ib3R0b206IDVweCBzb2xpZCAjMWIxYjFiOyBib3JkZXItdG9wOiAwOwp9Ci5oYW5kbGUtaGNlbGwuc29ydGVkLmRlc2MgLmgtc29ydCB7CiAgYm9y
;ZGVyLXRvcDogNXB4IHNvbGlkICMxYjFiMWI7IGJvcmRlci1ib3R0b206IDA7Cn0KLmhhbmRsZS1ib2R5IHsgZGlzcGxheTogYmxvY2s7IHBhZGRpbmctdG9w
;OiAycHg7IH0KLmhhbmRsZS1yb3cgewogIG1pbi1oZWlnaHQ6IDM2cHg7IGhlaWdodDogMzZweDsgZm9udC1zaXplOiAxM3B4OyBjb2xvcjogdmFyKC0tdHh0
;KTsKICBib3JkZXI6IDA7IGJvcmRlci1yYWRpdXM6IDhweDsgYmFja2dyb3VuZDogdHJhbnNwYXJlbnQ7IGN1cnNvcjogZGVmYXVsdDsgdXNlci1zZWxlY3Q6
;IG5vbmU7CiAgbWFyZ2luOiAxcHggMDsKfQouaGFuZGxlLXJvdzpob3ZlciB7IGJhY2tncm91bmQ6ICNmNWY3ZmI7IH0KLmhhbmRsZS1yb3cub24sIC5oYW5k
;bGUtcm93Lm9uOmhvdmVyIHsgYmFja2dyb3VuZDogdmFyKC0tc2VsKTsgfQouaGFuZGxlLWhlYWQgPiBkaXYsCi5oYW5kbGUtcm93ID4gZGl2IHsKICBkaXNw
;bGF5OiBmbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBtaW4td2lkdGg6IDA7IGhlaWdodDogMTAwJTsKICBwYWRkaW5nOiAwIDEycHg7IGJvcmRlcjogMDsg
;Ym94LXNpemluZzogYm9yZGVyLWJveDsKICBvdmVyZmxvdzogaGlkZGVuOyB3aGl0ZS1zcGFjZTogbm93cmFwOyB0ZXh0LW92ZXJmbG93OiBlbGxpcHNpczsK
;fQouaGFuZGxlLW5hbWUgewogIGRpc3BsYXk6IGZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGdhcDogMTBweDsgbWluLXdpZHRoOiAwOyB3aWR0aDogMTAw
;JTsgb3ZlcmZsb3c6IGhpZGRlbjsKfQouaGFuZGxlLW5hbWUgaW1nLCAuaGFuZGxlLW5hbWUgLmhhbmRsZS1pY28tcGggewogIHdpZHRoOiAxOHB4OyBoZWln
;aHQ6IDE4cHg7IG9iamVjdC1maXQ6IGNvbnRhaW47IGZsZXgtc2hyaW5rOiAwOwp9Ci5oYW5kbGUtbmFtZSAuaGFuZGxlLWljby1waCB7CiAgZGlzcGxheTog
;aW5saW5lLWJsb2NrOyBiYWNrZ3JvdW5kOiAjZWVmMWY2OyBib3JkZXItcmFkaXVzOiA0cHg7IGJvcmRlcjogMDsKfQouaGFuZGxlLW5hbWUgc3BhbiB7CiAg
;b3ZlcmZsb3c6IGhpZGRlbjsgdGV4dC1vdmVyZmxvdzogZWxsaXBzaXM7IHdoaXRlLXNwYWNlOiBub3dyYXA7IG1pbi13aWR0aDogMDsgZm9udC13ZWlnaHQ6
;IDUwMDsKfQouaGFuZGxlLW5ldC1kb3QgewogIHdpZHRoOiA3cHg7IGhlaWdodDogN3B4OyBib3JkZXItcmFkaXVzOiA1MCU7IGZsZXgtc2hyaW5rOiAwOwog
;IGJhY2tncm91bmQ6ICMyMmM1NWU7IGJveC1zaGFkb3c6IDAgMCAwIDJweCByZ2JhKDM0LCAxOTcsIDk0LCAuMik7Cn0KLmhhbmRsZS1zdGF0ZSB7CiAgZGlz
;cGxheTogZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsgZ2FwOiA2cHg7IG1pbi13aWR0aDogMDsKfQouaGFuZGxlLWVtcHR5IHsKICBwYWRkaW5nOiA0OHB4
;IDE2cHg7IHRleHQtYWxpZ246IGNlbnRlcjsgY29sb3I6IHZhcigtLXR4dDMpOyBmb250LXNpemU6IDEzLjVweDsgbGluZS1oZWlnaHQ6IDEuNjsKfQouaGFu
;ZGxlLWxvYWRpbmcgewogIGRpc3BsYXk6IGZsZXg7IGZsZXgtZGlyZWN0aW9uOiBjb2x1bW47IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGp1c3RpZnktY29udGVu
;dDogY2VudGVyOwogIGdhcDogMTRweDsgcGFkZGluZzogNjRweCAxNnB4OyBjb2xvcjogdmFyKC0tdHh0Mik7IGZvbnQtc2l6ZTogMTNweDsKfQouaGFuZGxl
;LXNwaW5uZXIgewogIHdpZHRoOiAyNnB4OyBoZWlnaHQ6IDI2cHg7IGJvcmRlci1yYWRpdXM6IDUwJTsgYm94LXNpemluZzogYm9yZGVyLWJveDsKICBib3Jk
;ZXI6IDIuNXB4IHNvbGlkICNlNWU3ZWI7IGJvcmRlci10b3AtY29sb3I6ICNlNDIwNzk7CiAgYW5pbWF0aW9uOiBoYW5kbGUtc3BpbiAuN3MgbGluZWFyIGlu
;ZmluaXRlOwp9CkBrZXlmcmFtZXMgaGFuZGxlLXNwaW4gewogIHRvIHsgdHJhbnNmb3JtOiByb3RhdGUoMzYwZGVnKTsgfQp9Ci5pbmZvLWxvYWRpbmcgewog
;IGRpc3BsYXk6IGZsZXg7IGZsZXgtZGlyZWN0aW9uOiBjb2x1bW47IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGp1c3RpZnktY29udGVudDogY2VudGVyOwogIGdh
;cDogMTRweDsgbWluLWhlaWdodDogMjQwcHg7IHBhZGRpbmc6IDY0cHggMTZweDsgY29sb3I6IHZhcigtLXR4dDIpOyBmb250LXNpemU6IDEzcHg7CiAgYm94
;LXNpemluZzogYm9yZGVyLWJveDsKfQouaW5mby1zcGlubmVyIHsKICB3aWR0aDogMjhweDsgaGVpZ2h0OiAyOHB4OyBib3JkZXItcmFkaXVzOiA1MCU7IGJv
;eC1zaXppbmc6IGJvcmRlci1ib3g7CiAgYm9yZGVyOiAyLjVweCBzb2xpZCAjZTVlN2ViOyBib3JkZXItdG9wLWNvbG9yOiAjZTQyMDc5OwogIGFuaW1hdGlv
;bjogaGFuZGxlLXNwaW4gLjdzIGxpbmVhciBpbmZpbml0ZTsKfQojYmFyLWhhbmRsZS1hY3Rpb25zIHsKICBkaXNwbGF5OiBub25lOyBhbGlnbi1pdGVtczog
;Y2VudGVyOyBnYXA6IDEwcHg7IG1hcmdpbi1yaWdodDogOHB4OyBtaW4td2lkdGg6IDA7CiAgcG9zaXRpb246IHJlbGF0aXZlOwp9CiNiYXIubW9kZS1oYW5k
;bGUgI2Jhci1oYW5kbGUtYWN0aW9ucyB7IGRpc3BsYXk6IGlubGluZS1mbGV4OyB9CiNiYXItaGFuZGxlLWFjdGlvbnMgI2hhbmRsZS1zdGF0dXMgewogIGNv
;bG9yOiB2YXIoLS10eHQzKTsgZm9udC1zaXplOiAxMnB4OyBtYXgtd2lkdGg6IDI0MHB4OwogIG92ZXJmbG93OiBoaWRkZW47IHRleHQtb3ZlcmZsb3c6IGVs
;bGlwc2lzOyB3aGl0ZS1zcGFjZTogbm93cmFwOwp9CiNidG4tcG9ydC1tYXJrIHsKICB3aWR0aDogMjhweDsgaGVpZ2h0OiAyOHB4OyBib3JkZXI6IDA7IGJv
;cmRlci1yYWRpdXM6IDhweDsKICBiYWNrZ3JvdW5kOiB0cmFuc3BhcmVudDsgY29sb3I6IHZhcigtLXR4dDIpOyBmb250LXNpemU6IDE1cHg7CiAgY3Vyc29y
;OiBwb2ludGVyOyBsaW5lLWhlaWdodDogMTsgZmxleC1zaHJpbms6IDA7Cn0KI2J0bi1wb3J0LW1hcms6aG92ZXIsICNidG4tcG9ydC1tYXJrLm9uIHsKICBi
;YWNrZ3JvdW5kOiAjZWVmMWY2OyBjb2xvcjogdmFyKC0tdHh0KTsKfQojYmFyLm1vZGUtaGFuZGxlIC5zb3J0LCAjYmFyLm1vZGUtaGFuZGxlIC50b2dnbGUg
;eyBkaXNwbGF5OiBub25lOyB9Ci5oYW5kbGUtY29sLXBvcnQucG9ydC1ob3QsCi5oYW5kbGUtY29sLXJwb3J0LnBvcnQtaG90IHsKICBjb2xvcjogI2MyNDEw
;YzsgZm9udC13ZWlnaHQ6IDcwMDsKfQojcG9ydC1tYXJrLXBvcCB7CiAgZGlzcGxheTogbm9uZTsgcG9zaXRpb246IGFic29sdXRlOyByaWdodDogMDsgYm90
;dG9tOiBjYWxjKDEwMCUgKyA4cHgpOwogIHdpZHRoOiAzMDBweDsgei1pbmRleDogODA7IHBhZGRpbmc6IDEycHg7CiAgYmFja2dyb3VuZDogI2ZmZjsgYm9y
;ZGVyOiAxcHggc29saWQgdmFyKC0tbGluZSk7IGJvcmRlci1yYWRpdXM6IDEycHg7CiAgYm94LXNoYWRvdzogMCAxMnB4IDI4cHggcmdiYSgxNSwgMjMsIDQy
;LCAuMTIpOwp9CiNwb3J0LW1hcmstcG9wLm9uIHsgZGlzcGxheTogYmxvY2s7IH0KLnBtcC1oZCB7IGZvbnQtc2l6ZTogMTMuNXB4OyBmb250LXdlaWdodDog
;NjUwOyBjb2xvcjogdmFyKC0tdHh0KTsgbWFyZ2luLWJvdHRvbTogNHB4OyB9Ci5wbXAtaGludCB7IGZvbnQtc2l6ZTogMTJweDsgY29sb3I6IHZhcigtLXR4
;dDMpOyBtYXJnaW4tYm90dG9tOiAxMHB4OyBsaW5lLWhlaWdodDogMS40OyB9Ci5wbXAtdGFncyB7CiAgZGlzcGxheTogZmxleDsgZmxleC13cmFwOiB3cmFw
;OyBnYXA6IDZweDsgbWluLWhlaWdodDogMzJweDsKICBtYXgtaGVpZ2h0OiAxNDBweDsgb3ZlcmZsb3c6IGF1dG87IG1hcmdpbi1ib3R0b206IDEwcHg7Cn0K
;LnBtcC10YWcgewogIGRpc3BsYXk6IGlubGluZS1mbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBnYXA6IDRweDsKICBoZWlnaHQ6IDI2cHg7IHBhZGRpbmc6
;IDAgNHB4IDAgMTBweDsgYm9yZGVyLXJhZGl1czogOTk5cHg7CiAgYmFja2dyb3VuZDogI2ZmZjdlZDsgY29sb3I6ICNjMjQxMGM7IGZvbnQtc2l6ZTogMTIu
;NXB4OyBmb250LXdlaWdodDogNjAwOwogIGZvbnQtdmFyaWFudC1udW1lcmljOiB0YWJ1bGFyLW51bXM7Cn0KLnBtcC10YWcgYnV0dG9uIHsKICB3aWR0aDog
;MjBweDsgaGVpZ2h0OiAyMHB4OyBib3JkZXI6IDA7IGJvcmRlci1yYWRpdXM6IDUwJTsKICBiYWNrZ3JvdW5kOiB0cmFuc3BhcmVudDsgY29sb3I6ICNlYTU4
;MGM7IGN1cnNvcjogcG9pbnRlcjsgZm9udC1zaXplOiAxNHB4OyBsaW5lLWhlaWdodDogMTsKfQoucG1wLXRhZyBidXR0b246aG92ZXIgeyBiYWNrZ3JvdW5k
;OiAjZmZlZGQ1OyB9Ci5wbXAtZW1wdHkgeyBjb2xvcjogdmFyKC0tdHh0Myk7IGZvbnQtc2l6ZTogMTJweDsgcGFkZGluZzogNnB4IDJweDsgfQoucG1wLWFk
;ZCB7IGRpc3BsYXk6IGZsZXg7IGdhcDogOHB4OyBhbGlnbi1pdGVtczogY2VudGVyOyBtYXJnaW4tYm90dG9tOiA4cHg7IH0KLnBtcC1hZGQgaW5wdXQgewog
;IGZsZXg6IDE7IG1pbi13aWR0aDogMDsgaGVpZ2h0OiAzMnB4OyBib3JkZXI6IDFweCBzb2xpZCB2YXIoLS1saW5lKTsgYm9yZGVyLXJhZGl1czogOHB4Owog
;IHBhZGRpbmc6IDAgMTBweDsgb3V0bGluZTogbm9uZTsgZm9udC1zaXplOiAxM3B4OyBiYWNrZ3JvdW5kOiAjZmJmYmZkOwp9Ci5wbXAtYWRkIGlucHV0OmZv
;Y3VzIHsgYm9yZGVyLWNvbG9yOiAjOTNjNWZkOyBiYWNrZ3JvdW5kOiAjZmZmOyB9Ci5wbXAtYWRkIGJ1dHRvbiwgLnBtcC1yZXNldCB7CiAgaGVpZ2h0OiAz
;MnB4OyBwYWRkaW5nOiAwIDEycHg7IGJvcmRlcjogMDsgYm9yZGVyLXJhZGl1czogOHB4OwogIGJhY2tncm91bmQ6ICNlZmY2ZmY7IGNvbG9yOiAjMWQ0ZWQ4
;OyBmb250LXNpemU6IDEyLjVweDsgZm9udC13ZWlnaHQ6IDYwMDsgY3Vyc29yOiBwb2ludGVyOwp9Ci5wbXAtYWRkIGJ1dHRvbjpob3ZlciB7IGJhY2tncm91
;bmQ6ICNkYmVhZmU7IH0KLnBtcC1yZXNldCB7CiAgd2lkdGg6IDEwMCU7IGJhY2tncm91bmQ6IHRyYW5zcGFyZW50OyBjb2xvcjogdmFyKC0tdHh0Mik7IGZv
;bnQtd2VpZ2h0OiA1MDA7Cn0KLnBtcC1yZXNldDpob3ZlciB7IGJhY2tncm91bmQ6ICNmM2Y0ZjY7IGNvbG9yOiB2YXIoLS10eHQpOyB9Ci5wcm9jLWFjdCB7
;CiAgd2lkdGg6IDIycHg7IGhlaWdodDogMjJweDsgYm9yZGVyOiAwOyBib3JkZXItcmFkaXVzOiA0cHg7IGJhY2tncm91bmQ6IHRyYW5zcGFyZW50OwogIGNv
;bG9yOiAjOWFhMWIyOyBjdXJzb3I6IHBvaW50ZXI7IGZvbnQtc2l6ZTogMTJweDsgbGluZS1oZWlnaHQ6IDE7Cn0KLnByb2MtYWN0OmhvdmVyIHsgYmFja2dy
;b3VuZDogI2U1ZTdlYjsgY29sb3I6ICMxMTE4Mjc7IH0KLnByb2MtZm9vdCB7CiAgZGlzcGxheTogZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsganVzdGlm
;eS1jb250ZW50OiBmbGV4LWVuZDsgZ2FwOiAxNHB4OwogIHBhZGRpbmc6IDZweCAxNnB4IDEwcHg7IGNvbG9yOiAjM2I4MmY2OyBmb250LXNpemU6IDEyLjVw
;eDsKfQoucHJvYy1mb290LmhpZGRlbiB7IGRpc3BsYXk6IG5vbmU7IH0KLnByb2Mtc3lzLXRvZyB7CiAgZGlzcGxheTogaW5saW5lLWZsZXg7IGFsaWduLWl0
;ZW1zOiBjZW50ZXI7IGdhcDogOHB4OyBjdXJzb3I6IHBvaW50ZXI7CiAgdXNlci1zZWxlY3Q6IG5vbmU7IGNvbG9yOiAjM2I4MmY2OyBmb250LXNpemU6IDEy
;LjVweDsKfQoucHJvYy1zeXMtdG9nIGlucHV0IHsgcG9zaXRpb246IGFic29sdXRlOyBvcGFjaXR5OiAwOyB3aWR0aDogMDsgaGVpZ2h0OiAwOyB9Ci5wcm9j
;LXN5cy10b2cgLnRvZyB7CiAgd2lkdGg6IDM2cHg7IGhlaWdodDogMjBweDsgYm9yZGVyLXJhZGl1czogOTk5cHg7IGJhY2tncm91bmQ6ICNkMWQ1ZGI7CiAg
;cG9zaXRpb246IHJlbGF0aXZlOyBmbGV4LXNocmluazogMDsgdHJhbnNpdGlvbjogYmFja2dyb3VuZCAuMTVzIGVhc2U7Cn0KLnByb2Mtc3lzLXRvZyAudG9n
;OjphZnRlciB7CiAgY29udGVudDogIiI7IHBvc2l0aW9uOiBhYnNvbHV0ZTsgdG9wOiAycHg7IGxlZnQ6IDJweDsKICB3aWR0aDogMTZweDsgaGVpZ2h0OiAx
;NnB4OyBib3JkZXItcmFkaXVzOiA1MCU7IGJhY2tncm91bmQ6ICNmZmY7CiAgYm94LXNoYWRvdzogMCAxcHggMnB4IHJnYmEoMCwwLDAsLjE4KTsgdHJhbnNp
;dGlvbjogdHJhbnNmb3JtIC4xNXMgZWFzZTsKfQoucHJvYy1zeXMtdG9nIGlucHV0OmNoZWNrZWQgKyAudG9nIHsgYmFja2dyb3VuZDogIzNiODJmNjsgfQou
;cHJvYy1zeXMtdG9nIGlucHV0OmNoZWNrZWQgKyAudG9nOjphZnRlciB7IHRyYW5zZm9ybTogdHJhbnNsYXRlWCgxNnB4KTsgfQojcHJvYy1jb3VudCB7CiAg
;Y29sb3I6ICM2YjcyODA7IGZvbnQtdmFyaWFudC1udW1lcmljOiB0YWJ1bGFyLW51bXM7IG1pbi13aWR0aDogMi41ZW07IHRleHQtYWxpZ246IHJpZ2h0Owp9
;CiNpbmZvLXBhbmVsIHsKICBmbGV4OiAxOyBtaW4taGVpZ2h0OiAwOyBtYXJnaW46IDA7IGJvcmRlcjogMDsgYm9yZGVyLXJhZGl1czogMDsKICBvdmVyZmxv
;dzogYXV0bzsgYmFja2dyb3VuZDogI2ZmZjsKICBkaXNwbGF5OiBibG9jazsgLyog5Yu/55SoIGZsZXgg5YiX77ya5aSa6KGM572R5Y2h5Lya6KKr5Y6L55+u
;5Y+g5a2XICovCn0KI2luZm8tcGFuZWwuaGlkZGVuIHsgZGlzcGxheTogbm9uZTsgfQouaW5mby1yb3cgewogIGRpc3BsYXk6IGdyaWQ7IGdyaWQtdGVtcGxh
;dGUtY29sdW1uczogMTA4cHggMThweCAxZnIgYXV0bzsKICBnYXA6IDAgOHB4OyBhbGlnbi1pdGVtczogc3RhcnQ7IG1pbi1oZWlnaHQ6IDM2cHg7IGhlaWdo
;dDogYXV0bzsKICBwYWRkaW5nOiA4cHggMTRweDsgYm9yZGVyLWJvdHRvbTogMXB4IHNvbGlkICNlZWYwZjQ7CiAgZmxleC1zaHJpbms6IDA7IG92ZXJmbG93
;OiB2aXNpYmxlOwp9Ci5pbmZvLXJvdzpudGgtY2hpbGQoZXZlbikgeyBiYWNrZ3JvdW5kOiAjZjdmOGZhOyB9Ci5pbmZvLWxhYiB7CiAgY29sb3I6ICMzYjgy
;ZjY7IGZvbnQtc2l6ZTogMTNweDsgdGV4dC1hbGlnbjogcmlnaHQ7IHBhZGRpbmctdG9wOiAycHg7CiAgd2hpdGUtc3BhY2U6IG5vd3JhcDsKfQouaW5mby1k
;YXNoIHsKICBoZWlnaHQ6IDFweDsgYmFja2dyb3VuZDogI2QxZDVkYjsgbWFyZ2luLXRvcDogMTJweDsgYWxpZ24tc2VsZjogc3RhcnQ7Cn0KLmluZm8tdmFs
;IHsKICBjb2xvcjogIzExMTgyNzsgZm9udC1zaXplOiAxM3B4OyBsaW5lLWhlaWdodDogMS41NTsgd29yZC1icmVhazogYnJlYWstd29yZDsKICBwYWRkaW5n
;LXRvcDogMXB4OyBtaW4td2lkdGg6IDA7IG92ZXJmbG93OiB2aXNpYmxlOwp9Ci5pbmZvLXZhbCAuc3ViIHsKICBjb2xvcjogIzM3NDE1MTsgbWFyZ2luLWxl
;ZnQ6IDI0cHg7IHdoaXRlLXNwYWNlOiBub3dyYXA7Cn0KI2luZm8tdXB0aW1lIHsKICBjb2xvcjogIzM3NDE1MTsgZm9udC12YXJpYW50LW51bWVyaWM6IHRh
;YnVsYXItbnVtczsKfQouaW5mby12YWwgLmxpbmUgeyBkaXNwbGF5OiBibG9jazsgfQouaW5mby12YWwgLm5ldC1saW5lIHsKICBkaXNwbGF5OiBncmlkOyBn
;cmlkLXRlbXBsYXRlLWNvbHVtbnM6IG1pbm1heCgxNDBweCwgMS41ZnIpIG1pbm1heCgxNTBweCwgMWZyKSBtaW5tYXgoMTEwcHgsIDAuODVmcik7CiAgZ2Fw
;OiA0cHggMTJweDsgYWxpZ24taXRlbXM6IGJhc2VsaW5lOyBtYXJnaW46IDAgMCA2cHg7IG1pbi13aWR0aDogMDsKfQouaW5mby12YWwgLm5ldC1saW5lOmxh
;c3QtY2hpbGQgeyBtYXJnaW4tYm90dG9tOiAwOyB9Ci5pbmZvLXZhbCAubmV0LWxpbmUgPiBzcGFuIHsgbWluLXdpZHRoOiAwOyBvdmVyZmxvdy13cmFwOiBh
;bnl3aGVyZTsgfQouaW5mby12YWwgLm5ldC1saW5lIC5rIHsgY29sb3I6ICM2YjcyODA7IH0KLmluZm8tbGluayB7CiAgYm9yZGVyOiAwOyBiYWNrZ3JvdW5k
;OiB0cmFuc3BhcmVudDsgY29sb3I6ICMzYjgyZjY7IGZvbnQtc2l6ZTogMTIuNXB4OwogIGN1cnNvcjogcG9pbnRlcjsgcGFkZGluZzogMnB4IDA7IHdoaXRl
;LXNwYWNlOiBub3dyYXA7IGFsaWduLXNlbGY6IHN0YXJ0Owp9Ci5pbmZvLWxpbms6aG92ZXIgeyB0ZXh0LWRlY29yYXRpb246IHVuZGVybGluZTsgfQojYmFy
;LWluZm8tYWN0aW9ucyB7CiAgZGlzcGxheTogbm9uZTsgYWxpZ24taXRlbXM6IGNlbnRlcjsgZ2FwOiAxNnB4OyBtYXJnaW4tcmlnaHQ6IDhweDsKfQojYmFy
;Lm1vZGUtaW5mbyAjYmFyLWluZm8tYWN0aW9ucyB7IGRpc3BsYXk6IGlubGluZS1mbGV4OyB9CiNiYXItaW5mby1hY3Rpb25zIGJ1dHRvbiB7CiAgYm9yZGVy
;OiAwOyBiYWNrZ3JvdW5kOiB0cmFuc3BhcmVudDsgY29sb3I6ICMzYjgyZjY7IGZvbnQtc2l6ZTogMTIuNXB4OyBjdXJzb3I6IHBvaW50ZXI7IHBhZGRpbmc6
;IDA7Cn0KI2Jhci1pbmZvLWFjdGlvbnMgYnV0dG9uOmhvdmVyIHsgdGV4dC1kZWNvcmF0aW9uOiB1bmRlcmxpbmU7IH0KI2Jhci5tb2RlLWluZm8gI2NvdW50
;IHsgY29sb3I6IHZhcigtLXR4dDIpOyB9CiNiYXIubW9kZS1jb25maWcgI2NvdW50IHsgZGlzcGxheTogbm9uZTsgfQojYmFyLWNvbmZpZy1hY3Rpb25zIHsK
;ICBkaXNwbGF5OiBub25lOyBhbGlnbi1pdGVtczogY2VudGVyOyBnYXA6IDhweDsgbWluLXdpZHRoOiAwOyBtYXgtd2lkdGg6IG1pbig3MnZ3LCA3NjBweCk7
;Cn0KI2Jhci5tb2RlLWNvbmZpZyAjYmFyLWNvbmZpZy1hY3Rpb25zIHsgZGlzcGxheTogaW5saW5lLWZsZXg7IH0KI2NmZy1wYXRoLWxhYmVsIHsKICBtaW4t
;d2lkdGg6IDA7IG92ZXJmbG93OiBoaWRkZW47IHRleHQtb3ZlcmZsb3c6IGVsbGlwc2lzOyB3aGl0ZS1zcGFjZTogbm93cmFwOwogIGZvbnQtZmFtaWx5OiBD
;b25zb2xhcywgIkNhc2NhZGlhIE1vbm8iLCBtb25vc3BhY2U7IGZvbnQtc2l6ZTogMTJweDsgY29sb3I6IHZhcigtLXR4dDIpOwp9CiNjZmctcmVsb2FkIHsK
;ICB3aWR0aDogMjhweDsgaGVpZ2h0OiAyOHB4OyBmbGV4LXNocmluazogMDsgYm9yZGVyOiAwOyBib3JkZXItcmFkaXVzOiA2cHg7CiAgYmFja2dyb3VuZDog
;dHJhbnNwYXJlbnQ7IGNvbG9yOiB2YXIoLS10eHQyKTsgY3Vyc29yOiBwb2ludGVyOwogIGRpc3BsYXk6IGlubGluZS1mbGV4OyBhbGlnbi1pdGVtczogY2Vu
;dGVyOyBqdXN0aWZ5LWNvbnRlbnQ6IGNlbnRlcjsgcGFkZGluZzogMDsKfQojY2ZnLXJlbG9hZDpob3ZlciB7IGJhY2tncm91bmQ6ICNlZWYxZjY7IGNvbG9y
;OiB2YXIoLS10eHQpOyB9CiNjZmctcmVsb2FkIHN2ZyB7IHdpZHRoOiAxNnB4OyBoZWlnaHQ6IDE2cHg7IGRpc3BsYXk6IGJsb2NrOyB9CiNiYXIubW9kZS1j
;b25maWcgLnNvcnQsICNiYXIubW9kZS1jb25maWcgLnRvZ2dsZSB7IGRpc3BsYXk6IG5vbmU7IH0KI2Jhci5tb2RlLWluZm8gLnNvcnQsICNiYXIubW9kZS1p
;bmZvIC50b2dnbGUgeyBkaXNwbGF5OiBub25lOyB9CgovKiDilIDilIAg6L+Q6KGM6YWN572u57yW6L6R5Zmo77yI5YiG57uE5Y2h54mH77yJIOKUgOKUgOKU
;gOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgCAqLwojY29uZmlnLXBhbmVsIHsKICBmbGV4OiAxIDEgMDsgbWluLWhlaWdodDogMDsgbWFyZ2luOiAwOyBib3Jk
;ZXI6IDA7CiAgYmFja2dyb3VuZDogI2Y0ZjZmOTsgZGlzcGxheTogZmxleDsgZmxleC1kaXJlY3Rpb246IGNvbHVtbjsgb3ZlcmZsb3c6IGhpZGRlbjsKfQoj
;Y29uZmlnLXBhbmVsLmhpZGRlbiB7IGRpc3BsYXk6IG5vbmU7IH0KLmNmZy10b3AgewogIGZsZXgtc2hyaW5rOiAwOyBkaXNwbGF5OiBmbGV4OyBhbGlnbi1p
;dGVtczogY2VudGVyOyBqdXN0aWZ5LWNvbnRlbnQ6IHNwYWNlLWJldHdlZW47CiAgZ2FwOiAxMHB4OyBmbGV4LXdyYXA6IHdyYXA7CiAgcGFkZGluZzogMTBw
;eCAxNHB4OyBib3JkZXItYm90dG9tOiAxcHggc29saWQgdmFyKC0tbGluZSk7IGJhY2tncm91bmQ6ICNmZmY7Cn0KLmNmZy10YWJzIHsgZGlzcGxheTogZmxl
;eDsgZ2FwOiA4cHg7IGZsZXgtd3JhcDogd3JhcDsgZmxleC1zaHJpbms6IDA7IH0KLmNmZy10YWIgewogIGhlaWdodDogMzBweDsgcGFkZGluZzogMCAxNHB4
;OyBib3JkZXI6IDA7IGJvcmRlci1yYWRpdXM6IDk5OXB4OwogIGJhY2tncm91bmQ6ICNlZWYxZjY7IGNvbG9yOiB2YXIoLS10eHQyKTsgY3Vyc29yOiBwb2lu
;dGVyOyBmb250LXNpemU6IDEzcHg7Cn0KLmNmZy10YWI6aG92ZXIgeyBiYWNrZ3JvdW5kOiAjZTJlOGYwOyBjb2xvcjogdmFyKC0tdHh0KTsgfQouY2ZnLXRh
;Yi5vbiB7IGJhY2tncm91bmQ6ICMxNmEzNGE7IGNvbG9yOiAjZmZmOyBmb250LXdlaWdodDogNjAwOyB9Ci5jZmctdG9vbHMgeyBkaXNwbGF5OiBmbGV4OyBn
;YXA6IDhweDsgYWxpZ24taXRlbXM6IGNlbnRlcjsgZmxleC13cmFwOiB3cmFwOyBmbGV4LXNocmluazogMDsgbWFyZ2luLWxlZnQ6IGF1dG87IH0KLmNmZy10
;b29scyBidXR0b24gewogIGhlaWdodDogMzBweDsgcGFkZGluZzogMCAxMnB4OyBib3JkZXI6IDFweCBzb2xpZCB2YXIoLS1saW5lKTsgYm9yZGVyLXJhZGl1
;czogNnB4OwogIGJhY2tncm91bmQ6ICNmZmY7IGNvbG9yOiB2YXIoLS10eHQpOyBjdXJzb3I6IHBvaW50ZXI7IGZvbnQtc2l6ZTogMTIuNXB4OwogIGRpc3Bs
;YXk6IGlubGluZS1mbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBnYXA6IDVweDsKfQouY2ZnLXRvb2xzIGJ1dHRvbjpob3ZlciB7IGJhY2tncm91bmQ6ICNm
;M2Y0ZjY7IH0KLmNmZy10b29scyBidXR0b24ucHJpbWFyeSB7CiAgYmFja2dyb3VuZDogIzE2YTM0YTsgYm9yZGVyLWNvbG9yOiAjMTZhMzRhOyBjb2xvcjog
;I2ZmZjsKfQouY2ZnLXRvb2xzIGJ1dHRvbi5wcmltYXJ5OmhvdmVyIHsgYmFja2dyb3VuZDogIzE1ODAzZDsgYm9yZGVyLWNvbG9yOiAjMTU4MDNkOyB9Ci5j
;ZmctdG9vbHMgYnV0dG9uLmNmZy1pY28tYnRuIHsKICB3aWR0aDogMzBweDsgcGFkZGluZzogMDsganVzdGlmeS1jb250ZW50OiBjZW50ZXI7IHBvc2l0aW9u
;OiByZWxhdGl2ZTsKfQouY2ZnLXRvb2xzIGJ1dHRvbi5jZmctaWNvLWJ0biBzdmcgewogIHdpZHRoOiAxNXB4OyBoZWlnaHQ6IDE1cHg7IGRpc3BsYXk6IGJs
;b2NrOyBmbGV4LXNocmluazogMDsKICB0cmFuc2l0aW9uOiB0cmFuc2Zvcm0gLjE4cyBlYXNlOwp9Ci5jZmctdG9vbHMgYnV0dG9uLmNmZy1pY28tYnRuIC5p
;Y28tY29sbGFwc2UgeyBkaXNwbGF5OiBub25lOyB9Ci5jZmctdG9vbHMgYnV0dG9uLmNmZy1pY28tYnRuLmlzLWV4cGFuZGVkIC5pY28tZXhwYW5kIHsgZGlz
;cGxheTogbm9uZTsgfQouY2ZnLXRvb2xzIGJ1dHRvbi5jZmctaWNvLWJ0bi5pcy1leHBhbmRlZCAuaWNvLWNvbGxhcHNlIHsgZGlzcGxheTogYmxvY2s7IH0K
;I3VpLWRsZyB7CiAgZGlzcGxheTogbm9uZTsgcG9zaXRpb246IGZpeGVkOyBpbnNldDogMDsgei1pbmRleDogNDAwOwogIGFsaWduLWl0ZW1zOiBjZW50ZXI7
;IGp1c3RpZnktY29udGVudDogY2VudGVyOwp9CiN1aS1kbGcub24geyBkaXNwbGF5OiBmbGV4OyB9Ci51aS1kbGctbWFzayB7CiAgcG9zaXRpb246IGFic29s
;dXRlOyBpbnNldDogMDsgYmFja2dyb3VuZDogcmdiYSgxNSwgMjMsIDQyLCAuMjgpOwogIGJhY2tkcm9wLWZpbHRlcjogYmx1cigycHgpOwp9Ci51aS1kbGct
;Y2FyZCB7CiAgcG9zaXRpb246IHJlbGF0aXZlOyB6LWluZGV4OiAxOyB3aWR0aDogbWluKDM4MHB4LCBjYWxjKDEwMHZ3IC0gMzJweCkpOwogIGJhY2tncm91
;bmQ6ICNmZmY7IGJvcmRlci1yYWRpdXM6IDEycHg7IGJvcmRlcjogMXB4IHNvbGlkICNlMmU4ZjA7CiAgYm94LXNoYWRvdzogMCAxOHB4IDQ4cHggcmdiYSgx
;NSwgMjMsIDQyLCAuMTgpOwogIHBhZGRpbmc6IDE4cHggMThweCAxNHB4OyBhbmltYXRpb246IHVpRGxnSW4gLjE2cyBlYXNlLW91dDsKfQpAa2V5ZnJhbWVz
;IHVpRGxnSW4gewogIGZyb20geyBvcGFjaXR5OiAwOyB0cmFuc2Zvcm06IHRyYW5zbGF0ZVkoNnB4KSBzY2FsZSguOTgpOyB9CiAgdG8geyBvcGFjaXR5OiAx
;OyB0cmFuc2Zvcm06IG5vbmU7IH0KfQoudWktZGxnLXRpdGxlIHsKICBmb250LXNpemU6IDE1cHg7IGZvbnQtd2VpZ2h0OiA2NTA7IGNvbG9yOiAjMTExODI3
;OyBtYXJnaW46IDAgMCA4cHg7Cn0KLnVpLWRsZy1tc2cgewogIGZvbnQtc2l6ZTogMTNweDsgbGluZS1oZWlnaHQ6IDEuNTU7IGNvbG9yOiAjNGI1NTYzOyBt
;YXJnaW46IDAgMCAxNHB4OwogIHdoaXRlLXNwYWNlOiBwcmUtd3JhcDsgd29yZC1icmVhazogYnJlYWstd29yZDsKfQoudWktZGxnLWlucHV0IHsKICBkaXNw
;bGF5OiBub25lOyB3aWR0aDogMTAwJTsgYm94LXNpemluZzogYm9yZGVyLWJveDsgaGVpZ2h0OiAzNnB4OwogIG1hcmdpbjogLTRweCAwIDE0cHg7IHBhZGRp
;bmc6IDAgMTJweDsKICBib3JkZXI6IDFweCBzb2xpZCAjY2JkNWUxOyBib3JkZXItcmFkaXVzOiA4cHg7IGJhY2tncm91bmQ6ICNmOGZhZmM7CiAgY29sb3I6
;IHZhcigtLXR4dCk7IGZvbnQtc2l6ZTogMTMuNXB4OyBvdXRsaW5lOiBub25lOwp9Ci51aS1kbGctaW5wdXQub24geyBkaXNwbGF5OiBibG9jazsgfQoudWkt
;ZGxnLWlucHV0OmZvY3VzIHsKICBib3JkZXItY29sb3I6ICM5M2M1ZmQ7IGJhY2tncm91bmQ6ICNmZmY7CiAgYm94LXNoYWRvdzogMCAwIDAgM3B4IHJnYmEo
;NTksMTMwLDI0NiwuMTQpOwp9Ci51aS1kbGctYWN0aW9ucyB7CiAgZGlzcGxheTogZmxleDsganVzdGlmeS1jb250ZW50OiBmbGV4LWVuZDsgZ2FwOiA4cHg7
;Cn0KLnVpLWRsZy1hY3Rpb25zIGJ1dHRvbiB7CiAgbWluLXdpZHRoOiA3MnB4OyBoZWlnaHQ6IDMycHg7IHBhZGRpbmc6IDAgMTRweDsKICBib3JkZXI6IDFw
;eCBzb2xpZCAjZTJlOGYwOyBib3JkZXItcmFkaXVzOiA4cHg7CiAgYmFja2dyb3VuZDogI2ZmZjsgY29sb3I6ICMzNzQxNTE7IGZvbnQtc2l6ZTogMTNweDsg
;Y3Vyc29yOiBwb2ludGVyOwp9Ci51aS1kbGctYWN0aW9ucyBidXR0b246aG92ZXIgeyBiYWNrZ3JvdW5kOiAjZjNmNGY2OyB9Ci51aS1kbGctYWN0aW9ucyBi
;dXR0b24ucHJpbWFyeSB7CiAgYmFja2dyb3VuZDogIzNiODJmNjsgYm9yZGVyLWNvbG9yOiAjM2I4MmY2OyBjb2xvcjogI2ZmZjsKfQoudWktZGxnLWFjdGlv
;bnMgYnV0dG9uLnByaW1hcnk6aG92ZXIgeyBiYWNrZ3JvdW5kOiAjMjU2M2ViOyB9Ci51aS1kbGctYWN0aW9ucyBidXR0b24uZGFuZ2VyIHsKICBiYWNrZ3Jv
;dW5kOiAjZGMyNjI2OyBib3JkZXItY29sb3I6ICNkYzI2MjY7IGNvbG9yOiAjZmZmOwp9Ci51aS1kbGctYWN0aW9ucyBidXR0b24uZGFuZ2VyOmhvdmVyIHsg
;YmFja2dyb3VuZDogI2I5MWMxYzsgfQojY2ZnLXN0YXR1cyB7CiAgZGlzcGxheTogbm9uZTsgZmxleC1zaHJpbms6IDA7IHBhZGRpbmc6IDhweCAxNHB4OyBm
;b250LXNpemU6IDEyLjVweDsgZm9udC13ZWlnaHQ6IDU1MDsKfQojY2ZnLXN0YXR1cy5lcnIgeyBkaXNwbGF5OiBibG9jazsgY29sb3I6ICNiOTFjMWM7IGJh
;Y2tncm91bmQ6ICNmZWYyZjI7IH0KI2NmZy1zdGF0dXMub2sgeyBkaXNwbGF5OiBibG9jazsgY29sb3I6ICMxNTgwM2Q7IGJhY2tncm91bmQ6ICNmMGZkZjQ7
;IH0KI2NmZy1zdGF0dXMuaW5mbyB7IGRpc3BsYXk6IGJsb2NrOyBjb2xvcjogIzFkNGVkODsgYmFja2dyb3VuZDogI2VmZjZmZjsgfQojY2ZnLXRpcC13cmFw
;IHsKICBmbGV4LXNocmluazogMDsgZGlzcGxheTogZmxleDsgYWxpZ24taXRlbXM6IGZsZXgtc3RhcnQ7IGdhcDogOHB4OwogIHBhZGRpbmc6IDEycHggMTZw
;eCA2cHg7IGJhY2tncm91bmQ6ICNmNGY2Zjk7IGJvcmRlci1ib3R0b206IDA7Cn0KI2NmZy10aXAtd3JhcC5oaWRkZW4geyBkaXNwbGF5OiBub25lOyB9Ci5j
;ZmctdGlwLWljbyB7CiAgZmxleC1zaHJpbms6IDA7IHdpZHRoOiAxOHB4OyBoZWlnaHQ6IDE4cHg7IG1hcmdpbi10b3A6IDJweDsgY29sb3I6ICM5NGEzYjg7
;Cn0KLmNmZy10aXAtaWNvIHN2ZyB7IHdpZHRoOiAxOHB4OyBoZWlnaHQ6IDE4cHg7IGRpc3BsYXk6IGJsb2NrOyB9Ci5jZmctdGlwLWJvZHkgeyBmbGV4OiAx
;OyBtaW4td2lkdGg6IDA7IH0KI2NmZy10aXAgewogIG1hcmdpbjogMDsgcGFkZGluZzogMCAwIDAgMTBweDsKICBib3JkZXI6IDA7IGJvcmRlci1sZWZ0OiAy
;cHggc29saWQgI2NiZDVlMTsgYm9yZGVyLXJhZGl1czogMDsKICBiYWNrZ3JvdW5kOiB0cmFuc3BhcmVudDsKICBjb2xvcjogIzY0NzQ4YjsgZm9udC1zaXpl
;OiAxMi41cHg7IGxpbmUtaGVpZ2h0OiAxLjg1OwogIGxldHRlci1zcGFjaW5nOiAuMDRlbTsKICBmb250LWZhbWlseTogIlNlZ29lIFVJIiwgIlBpbmdGYW5n
;IFNDIiwgIkhpcmFnaW5vIFNhbnMgR0IiLCAiTWljcm9zb2Z0IFlhSGVpIFVJIiwgc2Fucy1zZXJpZjsKICB3aGl0ZS1zcGFjZTogcHJlLXdyYXA7IHdvcmQt
;YnJlYWs6IGJyZWFrLXdvcmQ7CiAgdXNlci1zZWxlY3Q6IHRleHQ7IGN1cnNvcjogZGVmYXVsdDsKfQojY2ZnLXRpcDpob3ZlciB7IGNvbG9yOiAjNDc1NTY5
;OyB9CiNjZmctdGlwLWVkaXQgewogIGRpc3BsYXk6IG5vbmU7IHdpZHRoOiAxMDAlOyBtaW4taGVpZ2h0OiA3MnB4OyBtYXgtaGVpZ2h0OiAxNjBweDsgcmVz
;aXplOiB2ZXJ0aWNhbDsKICBib3gtc2l6aW5nOiBib3JkZXItYm94OyBtYXJnaW46IDA7IHBhZGRpbmc6IDZweCA4cHggNnB4IDEwcHg7CiAgYm9yZGVyOiAx
;cHggc29saWQgI2NiZDVlMTsgYm9yZGVyLWxlZnQ6IDJweCBzb2xpZCAjOTRhM2I4OyBib3JkZXItcmFkaXVzOiAwIDZweCA2cHggMDsKICBiYWNrZ3JvdW5k
;OiAjZmZmOwogIGNvbG9yOiAjNDc1NTY5OyBmb250LXNpemU6IDEyLjVweDsgbGluZS1oZWlnaHQ6IDEuODU7IGxldHRlci1zcGFjaW5nOiAuMDRlbTsKICBm
;b250LWZhbWlseTogIlNlZ29lIFVJIiwgIlBpbmdGYW5nIFNDIiwgIkhpcmFnaW5vIFNhbnMgR0IiLCAiTWljcm9zb2Z0IFlhSGVpIFVJIiwgc2Fucy1zZXJp
;ZjsKICBvdXRsaW5lOiBub25lOwp9CiNjZmctdGlwLWVkaXQ6Zm9jdXMgewogIGJvcmRlci1jb2xvcjogIzkzYzVmZDsgYm94LXNoYWRvdzogMCAwIDAgM3B4
;IHJnYmEoNTksMTMwLDI0NiwuMTIpOwp9CiNjZmctdGlwLXdyYXAuZWRpdGluZyAjY2ZnLXRpcCB7IGRpc3BsYXk6IG5vbmU7IH0KI2NmZy10aXAtd3JhcC5l
;ZGl0aW5nICNjZmctdGlwLWVkaXQgeyBkaXNwbGF5OiBibG9jazsgfQojY2ZnLXRpcC13cmFwLmVkaXRpbmcgLmNmZy10aXAtaWNvIHsgY29sb3I6ICM2NDc0
;OGI7IH0KI2NmZy1ib2R5IHsKICBmbGV4OiAxIDEgMDsgbWluLWhlaWdodDogMDsgaGVpZ2h0OiAwOwogIG92ZXJmbG93LXg6IGhpZGRlbjsgb3ZlcmZsb3ct
;eTogc2Nyb2xsOyBvdmVyc2Nyb2xsLWJlaGF2aW9yOiBjb250YWluOwogIHBhZGRpbmc6IDhweCAxNHB4IDIwcHg7CiAgZGlzcGxheTogZmxleDsgZmxleC1k
;aXJlY3Rpb246IGNvbHVtbjsgZ2FwOiAxMHB4OyBiYWNrZ3JvdW5kOiAjZjRmNmY5OwogIHNjcm9sbGJhci1ndXR0ZXI6IHN0YWJsZTsKfQouY2ZnLWVtcHR5
;IHsKICBwYWRkaW5nOiA0MHB4IDE2cHg7IHRleHQtYWxpZ246IGNlbnRlcjsgY29sb3I6IHZhcigtLXR4dDMpOyBmb250LXNpemU6IDEzcHg7Cn0KLmNmZy1j
;YXJkIHsKICBiYWNrZ3JvdW5kOiAjZmZmOyBib3JkZXI6IDFweCBzb2xpZCAjZTJlOGYwOyBib3JkZXItcmFkaXVzOiA4cHg7CiAgYm94LXNoYWRvdzogbm9u
;ZTsgb3ZlcmZsb3c6IGhpZGRlbjsgZmxleC1zaHJpbms6IDA7Cn0KLmNmZy1jYXJkLmRpbSB7IG9wYWNpdHk6IC41NTsgfQouY2ZnLWNhcmQub24geyBib3Jk
;ZXItY29sb3I6ICNiZmRiZmU7IH0KLmNmZy1jYXJkLm9wZW4geyBib3JkZXItY29sb3I6ICNjYmQ1ZTE7IGJvcmRlci1sZWZ0LWNvbG9yOiAjY2JkNWUxOyB9
;Ci5jZmctY2FyZDpub3QoLm9wZW4pIHsgYm9yZGVyLWxlZnQ6IDNweCBzb2xpZCAjMjJjNTVlOyB9Ci5jZmctY2FyZDpub3QoLm9wZW4pLm9uIHsgYm9yZGVy
;LWxlZnQtY29sb3I6ICMxNmEzNGE7IH0KLmNmZy1jYXJkLmhpdCA+IC5jZmctY2FyZC1oZCB7IGJhY2tncm91bmQ6ICNmZmZiZWI7IH0KLmNmZy1jYXJkLWhk
;IHsKICBkaXNwbGF5OiBmbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBnYXA6IDEwcHg7IHBhZGRpbmc6IDhweCAxMnB4OwogIGJhY2tncm91bmQ6ICNmOGZh
;ZmM7IGJvcmRlci1ib3R0b206IDFweCBzb2xpZCB0cmFuc3BhcmVudDsKICBjdXJzb3I6IGNvbnRleHQtbWVudTsgdXNlci1zZWxlY3Q6IG5vbmU7Cn0KLmNm
;Zy1jYXJkLm9wZW4gPiAuY2ZnLWNhcmQtaGQgeyBib3JkZXItYm90dG9tLWNvbG9yOiAjZWVmMmY3OyB9Ci5jZmctY2FyZC1oZCAuY2ZnLWd0aXRsZSB7CiAg
;ZmxleDogMTsgbWluLXdpZHRoOiAwOyBoZWlnaHQ6IDI4cHg7IGJvcmRlcjogMDsgYm9yZGVyLXJhZGl1czogNnB4OwogIHBhZGRpbmc6IDAgOHB4OyBiYWNr
;Z3JvdW5kOiB0cmFuc3BhcmVudDsKICBmb250LXNpemU6IDEzLjVweDsgZm9udC13ZWlnaHQ6IDcwMDsgY29sb3I6ICMzMzQxNTU7IG91dGxpbmU6IG5vbmU7
;Cn0KLmNmZy1jYXJkLWhkIC5jZmctZ3RpdGxlOjpwbGFjZWhvbGRlciB7IGNvbG9yOiAjOTRhM2I4OyB9Ci5jZmctY2FyZC1oZCAuY2ZnLWd0aXRsZTpmb2N1
;cyB7IGJhY2tncm91bmQ6ICNmZmY7IGJveC1zaGFkb3c6IDAgMCAwIDFweCAjY2JkNWUxIGluc2V0OyB9Ci5jZmctY2FyZC1oZCAuY2ZnLWdjb3VudCB7CiAg
;ZmxleC1zaHJpbms6IDA7IGZvbnQtc2l6ZTogMTFweDsgZm9udC13ZWlnaHQ6IDYwMDsgbGluZS1oZWlnaHQ6IDE7CiAgY29sb3I6ICM2NDc0OGI7IHBhZGRp
;bmc6IDVweCAxMHB4OyBib3JkZXItcmFkaXVzOiA5OTlweDsKICBiYWNrZ3JvdW5kOiAjZWVmMmY3OyBib3JkZXI6IDFweCBzb2xpZCAjZTJlOGYwOyBjdXJz
;b3I6IHBvaW50ZXI7CiAgZGlzcGxheTogaW5saW5lLWZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGdhcDogNHB4Owp9Ci5jZmctY2FyZC1oZCAuY2ZnLWdj
;b3VudDpob3ZlciB7IGJhY2tncm91bmQ6ICNlMmU4ZjA7IGNvbG9yOiAjMzM0MTU1OyB9Ci5jZmctY2FyZC1oZCAuY2ZnLWdjb3VudCAuY2ZnLWNoZXYgeyBm
;b250LXNpemU6IDEwcHg7IGNvbG9yOiAjOTRhM2I4OyB9Ci5jZmctbGlzdCB7IGRpc3BsYXk6IG5vbmU7IGZsZXgtZGlyZWN0aW9uOiBjb2x1bW47IH0KLmNm
;Zy1jYXJkLm9wZW4gPiAuY2ZnLWxpc3QgeyBkaXNwbGF5OiBmbGV4OyB9Ci5jZmctaXRlbSB7CiAgZGlzcGxheTogZ3JpZDsKICBncmlkLXRlbXBsYXRlLWNv
;bHVtbnM6IDE4cHggbWlubWF4KDkwcHgsIDE0MHB4KSAyMnB4IG1pbm1heCgwLCAxLjJmcikgbWlubWF4KDUwcHgsIDAuNDJmcikgNTZweDsKICBnYXA6IDhw
;eDsgYWxpZ24taXRlbXM6IGNlbnRlcjsKICBwYWRkaW5nOiA4cHggMTJweDsgYm9yZGVyLXRvcDogMXB4IHNvbGlkICNlZWYxZjY7CiAgY3Vyc29yOiBjb250
;ZXh0LW1lbnU7IGJhY2tncm91bmQ6ICNmZmY7Cn0KLmNmZy1pdGVtOm50aC1jaGlsZChldmVuKSB7IGJhY2tncm91bmQ6ICNmYWZiZmQ7IH0KLmNmZy1pdGVt
;OmhvdmVyIHsgYmFja2dyb3VuZDogI2YwZjdmZjsgfQouY2ZnLWl0ZW0ub24geyBiYWNrZ3JvdW5kOiAjZWZmNmZmOyBvdXRsaW5lOiAxcHggc29saWQgI2Jm
;ZGJmZTsgb3V0bGluZS1vZmZzZXQ6IC0xcHg7IH0KLmNmZy1pdGVtLm9mZiB7IG9wYWNpdHk6IC41NTsgfQouY2ZnLWl0ZW0ub2ZmIC5jZmcta2V5LCAuY2Zn
;LWl0ZW0ub2ZmIC5jZmctdmFsIHsgdGV4dC1kZWNvcmF0aW9uOiBsaW5lLXRocm91Z2g7IGNvbG9yOiAjOTRhM2I4ICFpbXBvcnRhbnQ7IH0KLmNmZy1pdGVt
;IGlucHV0W3R5cGU9InRleHQiXSB7CiAgd2lkdGg6IDEwMCU7IGhlaWdodDogMzBweDsgYm9yZGVyOiAxcHggc29saWQgdHJhbnNwYXJlbnQ7IGJvcmRlci1y
;YWRpdXM6IDVweDsKICBwYWRkaW5nOiAwIDhweDsgZm9udC1zaXplOiAxM3B4OyBvdXRsaW5lOiBub25lOyBiYWNrZ3JvdW5kOiB0cmFuc3BhcmVudDsgYm94
;LXNpemluZzogYm9yZGVyLWJveDsKfQouY2ZnLWl0ZW0gaW5wdXRbdHlwZT0idGV4dCJdOmhvdmVyIHsgYm9yZGVyLWNvbG9yOiAjZTJlOGYwOyBiYWNrZ3Jv
;dW5kOiAjZmZmOyB9Ci5jZmctaXRlbSBpbnB1dFt0eXBlPSJ0ZXh0Il06Zm9jdXMgewogIGJvcmRlci1jb2xvcjogIzkzYzVmZDsgYmFja2dyb3VuZDogI2Zm
;ZjsgYm94LXNoYWRvdzogMCAwIDAgMnB4IHJnYmEoNTksMTMwLDI0NiwuMTIpOwp9Ci5jZmctaXRlbSAuY2ZnLWtleSB7CiAgZm9udC1mYW1pbHk6IENvbnNv
;bGFzLCAiQ2FzY2FkaWEgTW9ubyIsICJTZWdvZSBVSSIsIG1vbm9zcGFjZTsKICBmb250LXdlaWdodDogNjUwOyBjb2xvcjogI2I0NTMwOTsKfQouY2ZnLWl0
;ZW0gLmNmZy12YWwgeyBjb2xvcjogIzNiODJmNjsgfQouY2ZnLWl0ZW0gLmNmZy1jbXQgewogIGhlaWdodDogMzBweCAhaW1wb3J0YW50OyBmb250LXNpemU6
;IDEycHggIWltcG9ydGFudDsKICBjb2xvcjogIzY0NzQ4YjsgYm9yZGVyOiAwICFpbXBvcnRhbnQ7IGJveC1zaGFkb3c6IG5vbmUgIWltcG9ydGFudDsKICBi
;YWNrZ3JvdW5kOiB0cmFuc3BhcmVudCAhaW1wb3J0YW50Owp9Ci5jZmctaXRlbSBpbnB1dC5jZmctY210OmhvdmVyLAouY2ZnLWl0ZW0gaW5wdXQuY2ZnLWNt
;dDpmb2N1cyB7CiAgYm9yZGVyOiAwICFpbXBvcnRhbnQ7IGJveC1zaGFkb3c6IG5vbmUgIWltcG9ydGFudDsgYmFja2dyb3VuZDogdHJhbnNwYXJlbnQgIWlt
;cG9ydGFudDsKfQouY2ZnLWhsLWZpZWxkLmNmZy1jbXQgLmNmZy1obC12aWV3IHsKICBtaW4taGVpZ2h0OiAzMHB4OyBmb250LXNpemU6IDEycHg7IGNvbG9y
;OiAjNjQ3NDhiOwogIGJveC1zaGFkb3c6IG5vbmUgIWltcG9ydGFudDsgYmFja2dyb3VuZDogdHJhbnNwYXJlbnQgIWltcG9ydGFudDsKfQouY2ZnLWhsLWZp
;ZWxkLmNmZy1jbXQgLmNmZy1obC12aWV3OmhvdmVyIHsKICBiYWNrZ3JvdW5kOiB0cmFuc3BhcmVudCAhaW1wb3J0YW50OyBib3gtc2hhZG93OiBub25lICFp
;bXBvcnRhbnQ7Cn0KLmNmZy1obC1maWVsZCB7CiAgcG9zaXRpb246IHJlbGF0aXZlOyBtaW4td2lkdGg6IDA7IHdpZHRoOiAxMDAlOwp9Ci5jZmctaGwtdmll
;dyB7CiAgbWluLWhlaWdodDogMzBweDsgZGlzcGxheTogZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsKICBwYWRkaW5nOiAwIDhweDsgYm9yZGVyLXJhZGl1
;czogNXB4OyBib3gtc2l6aW5nOiBib3JkZXItYm94OwogIGZvbnQtc2l6ZTogMTNweDsgbGluZS1oZWlnaHQ6IDEuMzU7IHdvcmQtYnJlYWs6IGJyZWFrLWFs
;bDsKICBjdXJzb3I6IHRleHQ7IHdoaXRlLXNwYWNlOiBwcmUtd3JhcDsKfQouY2ZnLWhsLXZpZXc6aG92ZXIgeyBiYWNrZ3JvdW5kOiAjZmZmOyBib3gtc2hh
;ZG93OiAwIDAgMCAxcHggI2UyZThmMCBpbnNldDsgfQouY2ZnLWhsLWZpZWxkLmNmZy1rZXkgLmNmZy1obC12aWV3IHsKICBmb250LWZhbWlseTogQ29uc29s
;YXMsICJDYXNjYWRpYSBNb25vIiwgIlNlZ29lIFVJIiwgbW9ub3NwYWNlOwogIGZvbnQtd2VpZ2h0OiA2NTA7IGNvbG9yOiAjYjQ1MzA5Owp9Ci5jZmctaGwt
;ZmllbGQuY2ZnLXZhbCAuY2ZnLWhsLXZpZXcgeyBjb2xvcjogIzNiODJmNjsgfQouY2ZnLWNhcmQtaGQgLmNmZy1ndGl0bGUtaGwgewogIGZsZXg6IDE7IG1p
;bi13aWR0aDogMDsgbWluLWhlaWdodDogMjhweDsgZGlzcGxheTogZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsKICBwYWRkaW5nOiAwIDhweDsgYm9yZGVy
;LXJhZGl1czogNnB4OwogIGZvbnQtc2l6ZTogMTMuNXB4OyBmb250LXdlaWdodDogNzAwOyBjb2xvcjogIzMzNDE1NTsgY3Vyc29yOiB0ZXh0Owp9Ci5jZmct
;Y2FyZC1oZCAuY2ZnLWd0aXRsZS1obDpob3ZlciB7IGJhY2tncm91bmQ6ICNmZmY7IGJveC1zaGFkb3c6IDAgMCAwIDFweCAjY2JkNWUxIGluc2V0OyB9Ci5j
;ZmctaGwtdmlldyBtYXJrLCAuY2ZnLWd0aXRsZS1obCBtYXJrIHsKICBiYWNrZ3JvdW5kOiB2YXIoLS1obCk7IGNvbG9yOiB2YXIoLS1obC10ZXh0KTsgcGFk
;ZGluZzogMCAxcHg7IGJvcmRlci1yYWRpdXM6IDJweDsKICBmb250LXdlaWdodDogNzAwOwp9Ci5jZmctZW4gewogIGRpc3BsYXk6IGlubGluZS1mbGV4OyBh
;bGlnbi1pdGVtczogY2VudGVyOyBqdXN0aWZ5LWNvbnRlbnQ6IGNlbnRlcjsgZ2FwOiAzcHg7CiAgZm9udC1zaXplOiAxMXB4OyBjb2xvcjogdmFyKC0tdHh0
;Mik7IHVzZXItc2VsZWN0OiBub25lOyB3aGl0ZS1zcGFjZTogbm93cmFwOwp9Ci5jZmctZW4gaW5wdXQgewogIHdpZHRoOiAxNHB4OyBoZWlnaHQ6IDE0cHg7
;IGN1cnNvcjogcG9pbnRlcjsgbWFyZ2luOiAwOwogIGFjY2VudC1jb2xvcjogIzE2YTM0YTsKfQouY2ZnLXZpY28geyB3aWR0aDogMThweDsgaGVpZ2h0OiAx
;OHB4OyBkaXNwbGF5OiBncmlkOyBwbGFjZS1pdGVtczogY2VudGVyOyBjb2xvcjogIzY0NzQ4YjsgfQouY2ZnLXZpY28gaW1nIHsgd2lkdGg6IDE2cHg7IGhl
;aWdodDogMTZweDsgb2JqZWN0LWZpdDogY29udGFpbjsgZGlzcGxheTogYmxvY2s7IH0KLmNmZy12aWNvIHN2ZyB7IHdpZHRoOiAxNXB4OyBoZWlnaHQ6IDE1
;cHg7IGRpc3BsYXk6IGJsb2NrOyB9Ci5jZmctZG90IHsgd2lkdGg6IDhweDsgaGVpZ2h0OiA4cHg7IGJvcmRlci1yYWRpdXM6IDUwJTsgYmFja2dyb3VuZDog
;I2NiZDVlMTsganVzdGlmeS1zZWxmOiBjZW50ZXI7IH0KLmNmZy1pdGVtLm9uIC5jZmctZG90IHsgYmFja2dyb3VuZDogIzNiODJmNjsgfQouY2ZnLWl0ZW0t
;ZW1wdHkgeyBwYWRkaW5nOiAxNHB4IDE2cHg7IGNvbG9yOiB2YXIoLS10eHQzKTsgZm9udC1zaXplOiAxMnB4OyBib3JkZXItdG9wOiAxcHggc29saWQgI2Vl
;ZjFmNjsgfQojY2ZnLW1lbnUgewogIGRpc3BsYXk6IG5vbmU7IHBvc2l0aW9uOiBmaXhlZDsgei1pbmRleDogMjQwOyBtaW4td2lkdGg6IDE2OHB4OwogIHBh
;ZGRpbmc6IDRweDsgYmFja2dyb3VuZDogI2ZmZjsgYm9yZGVyOiAxcHggc29saWQgdmFyKC0tbGluZSk7CiAgYm9yZGVyLXJhZGl1czogOHB4OyBib3gtc2hh
;ZG93OiB2YXIoLS1zaGFkb3cpOwp9CiNjZmctbWVudS5vbiB7IGRpc3BsYXk6IGJsb2NrOyB9CiNjZmctbWVudSBidXR0b24gewogIGRpc3BsYXk6IGZsZXg7
;IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGdhcDogOHB4OyB3aWR0aDogMTAwJTsKICB0ZXh0LWFsaWduOiBsZWZ0OyBib3JkZXI6IDA7IGJhY2tncm91bmQ6IHRy
;YW5zcGFyZW50OwogIHBhZGRpbmc6IDhweCAxMHB4OyBib3JkZXItcmFkaXVzOiA2cHg7IGN1cnNvcjogcG9pbnRlcjsgY29sb3I6IHZhcigtLXR4dCk7IGZv
;bnQtc2l6ZTogMTNweDsKfQojY2ZnLW1lbnUgYnV0dG9uOmhvdmVyIHsgYmFja2dyb3VuZDogI2YzZjRmNjsgfQojY2ZnLW1lbnUgYnV0dG9uLmRhbmdlciB7
;IGNvbG9yOiAjZGMyNjI2OyB9CiNjZmctbWVudSBidXR0b24uZGFuZ2VyOmhvdmVyIHsgYmFja2dyb3VuZDogI2ZlZjJmMjsgfQojY2ZnLW1lbnUgYnV0dG9u
;OmRpc2FibGVkIHsgb3BhY2l0eTogLjQ7IGN1cnNvcjogZGVmYXVsdDsgfQojY2ZnLW1lbnUgLmMtaWNvIHsKICB3aWR0aDogMTZweDsgaGVpZ2h0OiAxNnB4
;OyBmbGV4LXNocmluazogMDsgY29sb3I6ICM2NDc0OGI7CiAgZGlzcGxheTogaW5saW5lLWZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGp1c3RpZnktY29u
;dGVudDogY2VudGVyOwp9CiNjZmctbWVudSBidXR0b24uZGFuZ2VyIC5jLWljbyB7IGNvbG9yOiAjZGMyNjI2OyB9CiNjZmctbWVudSAuYy1pY28gc3ZnIHsg
;d2lkdGg6IDE2cHg7IGhlaWdodDogMTZweDsgZGlzcGxheTogYmxvY2s7IH0KI2NmZy1tZW51IC5jYWN0LWxhYmVsIHsgZmxleDogMTsgbWluLXdpZHRoOiAw
;OyB9CiNjZmctbWVudSBociB7IGJvcmRlcjogMDsgYm9yZGVyLXRvcDogMXB4IHNvbGlkICNlZWYxZjY7IG1hcmdpbjogNHB4IDZweDsgfQoucHJvYy1zZWFy
;Y2guaGlkZGVuIHsgZGlzcGxheTogbm9uZSAhaW1wb3J0YW50OyB9CiNwcm9jLW1lbnUgewogIGRpc3BsYXk6IG5vbmU7IHBvc2l0aW9uOiBmaXhlZDsgei1p
;bmRleDogMjIwOyBtaW4td2lkdGg6IDE4OHB4OwogIHBhZGRpbmc6IDRweDsgYmFja2dyb3VuZDogI2ZmZjsgYm9yZGVyOiAxcHggc29saWQgdmFyKC0tbGlu
;ZSk7CiAgYm9yZGVyLXJhZGl1czogOHB4OyBib3gtc2hhZG93OiB2YXIoLS1zaGFkb3cpOwp9CiNwcm9jLW1lbnUub24geyBkaXNwbGF5OiBibG9jazsgfQoj
;cHJvYy1tZW51IGJ1dHRvbiB7CiAgZGlzcGxheTogZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsgZ2FwOiAxMHB4OyB3aWR0aDogMTAwJTsKICB0ZXh0LWFs
;aWduOiBsZWZ0OyBib3JkZXI6IDA7IGJhY2tncm91bmQ6IHRyYW5zcGFyZW50OwogIHBhZGRpbmc6IDhweCAxMHB4OyBib3JkZXItcmFkaXVzOiA2cHg7IGN1
;cnNvcjogcG9pbnRlcjsgY29sb3I6IHZhcigtLXR4dCk7IGZvbnQtc2l6ZTogMTNweDsKfQojcHJvYy1tZW51IGJ1dHRvbjpob3ZlciB7IGJhY2tncm91bmQ6
;ICNmM2Y0ZjY7IH0KI3Byb2MtbWVudSBidXR0b24uZGFuZ2VyIHsgY29sb3I6ICNkYzI2MjY7IH0KI3Byb2MtbWVudSBidXR0b24uZGFuZ2VyOmhvdmVyIHsg
;YmFja2dyb3VuZDogI2ZlZjJmMjsgfQojcHJvYy1tZW51IGJ1dHRvbjpkaXNhYmxlZCB7IG9wYWNpdHk6IC40NTsgY3Vyc29yOiBkZWZhdWx0OyB9CiNwcm9j
;LW1lbnUgLmMtaWNvIHsKICB3aWR0aDogMTZweDsgaGVpZ2h0OiAxNnB4OyBmbGV4LXNocmluazogMDsKICBkaXNwbGF5OiBpbmxpbmUtZmxleDsgYWxpZ24t
;aXRlbXM6IGNlbnRlcjsganVzdGlmeS1jb250ZW50OiBjZW50ZXI7CiAgY29sb3I6ICMzNzQxNTE7Cn0KI3Byb2MtbWVudSBidXR0b24uZGFuZ2VyIC5jLWlj
;byB7IGNvbG9yOiAjZGMyNjI2OyB9CiNwcm9jLW1lbnUgLmMtaWNvIHN2ZyB7IHdpZHRoOiAxNnB4OyBoZWlnaHQ6IDE2cHg7IGRpc3BsYXk6IGJsb2NrOyB9
;CiNwcm9jLW1lbnUgLnBhY3QtbGFiZWwgewogIGZsZXg6IDE7IG1pbi13aWR0aDogMDsgb3ZlcmZsb3c6IGhpZGRlbjsgdGV4dC1vdmVyZmxvdzogZWxsaXBz
;aXM7IHdoaXRlLXNwYWNlOiBub3dyYXA7Cn0KCiNtYWluIHsgZmxleDogMTsgZGlzcGxheTogZ3JpZDsgZ3JpZC10ZW1wbGF0ZS1jb2x1bW5zOiB2YXIoLS1z
;aWRlLXcpIG1pbm1heCgwLCAxZnIpOyBtaW4taGVpZ2h0OiAwOyBiYWNrZ3JvdW5kOiB2YXIoLS1jaHJvbWUpOyBwYWRkaW5nOiAwIDEwcHggMCAwOyBib3gt
;c2l6aW5nOiBib3JkZXItYm94OyB9CiNjb250ZW50LXBhbmUgewogIGRpc3BsYXk6IGdyaWQ7CiAgZ3JpZC10ZW1wbGF0ZS1jb2x1bW5zOiBtaW5tYXgoMjgw
;cHgsIDEuMWZyKSBtaW5tYXgoMzIwcHgsIDEuMmZyKTsKICBtaW4td2lkdGg6IDA7IG1pbi1oZWlnaHQ6IDA7CiAgYmFja2dyb3VuZDogI2ZmZjsKICBib3Jk
;ZXI6IDFweCBzb2xpZCAjZDhkZGU2OwogIGJvcmRlci1yYWRpdXM6IDRweDsKICBvdmVyZmxvdzogaGlkZGVuOwp9CiNtYWluLm1vZGUtdG9vbCAjY29udGVu
;dC1wYW5lIHsKICBncmlkLXRlbXBsYXRlLWNvbHVtbnM6IDFmcjsKfQojbWFpbi5tb2RlLWhhbmRsZSAjcHJldmlldyB7IGRpc3BsYXk6IG5vbmU7IH0KCi8q
;IHNpZGUgKi8KI3NpZGUgewogIGJhY2tncm91bmQ6IHZhcigtLWNocm9tZSk7IGJvcmRlci1yaWdodDogMDsKICBkaXNwbGF5OiBmbGV4OyBmbGV4LWRpcmVj
;dGlvbjogY29sdW1uOyBwYWRkaW5nOiAxMHB4IDhweDsgZ2FwOiAycHg7Cn0KLmNhdCB7CiAgZGlzcGxheTogZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsg
;Z2FwOiAxMHB4OyBoZWlnaHQ6IDQycHg7IHBhZGRpbmc6IDAgMTBweDsKICBib3JkZXI6IDA7IGJvcmRlci1yYWRpdXM6IDhweDsgYmFja2dyb3VuZDogdHJh
;bnNwYXJlbnQ7IGNvbG9yOiB2YXIoLS10eHQpOyBjdXJzb3I6IHBvaW50ZXI7CiAgdGV4dC1hbGlnbjogbGVmdDsgcG9zaXRpb246IHJlbGF0aXZlOwp9Ci5j
;YXQ6aG92ZXIgeyBiYWNrZ3JvdW5kOiAjZWVmMWY2OyB9Ci5jYXQub24geyBiYWNrZ3JvdW5kOiAjZThlYmYyOyBmb250LXdlaWdodDogNjAwOyB9Ci5jYXQu
;b246OmJlZm9yZSB7CiAgY29udGVudDogIiI7IHBvc2l0aW9uOiBhYnNvbHV0ZTsgbGVmdDogMDsgdG9wOiA4cHg7IGJvdHRvbTogOHB4OyB3aWR0aDogM3B4
;OwogIGJvcmRlci1yYWRpdXM6IDJweDsgYmFja2dyb3VuZDogdmFyKC0tYWNjKTsKfQouY2F0IC5pY28gewogIHdpZHRoOiAzMnB4OyBoZWlnaHQ6IDMycHg7
;IGZsZXgtc2hyaW5rOiAwOwogIGRpc3BsYXk6IGlubGluZS1mbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBqdXN0aWZ5LWNvbnRlbnQ6IGNlbnRlcjsKICBj
;b2xvcjogdmFyKC0tdHh0Mik7IGZvbnQtc2l6ZTogMTRweDsgbGluZS1oZWlnaHQ6IDE7Cn0KLmNhdCBpbWcuaWNvIHsKICB3aWR0aDogMzJweDsgaGVpZ2h0
;OiAzMnB4OwogIG9iamVjdC1maXQ6IGNvbnRhaW47IGltYWdlLXJlbmRlcmluZzogYXV0bzsKfQoKLnNpZGUtc2VwIHsKICBoZWlnaHQ6IDFweDsgbWFyZ2lu
;OiA4cHggMTBweDsgYmFja2dyb3VuZDogdmFyKC0tbGluZSk7IGZsZXgtc2hyaW5rOiAwOwp9CiNsaXN0LXBhbmUgeyBwb3NpdGlvbjogcmVsYXRpdmU7IH0K
;I2ZpbGUtcmVzdWx0cyB7IGRpc3BsYXk6IGZsZXg7IGZsZXgtZGlyZWN0aW9uOiBjb2x1bW47IGZsZXg6IDE7IG1pbi1oZWlnaHQ6IDA7IH0KI2ZpbGUtcmVz
;dWx0cy5oaWRkZW4geyBkaXNwbGF5OiBub25lICFpbXBvcnRhbnQ7IH0KI2hhbmRsZS1wYW5lbC5lbWJlZGRlZCB7CiAgZmxleDogMTsgbWluLWhlaWdodDog
;MDsgbWFyZ2luOiAwOyBib3JkZXI6IDA7IGJvcmRlci1yYWRpdXM6IDA7CiAgZGlzcGxheTogZmxleDsgZmxleC1kaXJlY3Rpb246IGNvbHVtbjsgb3ZlcmZs
;b3c6IGhpZGRlbjsgYmFja2dyb3VuZDogI2ZmZjsKfQojaGFuZGxlLXBhbmVsLmVtYmVkZGVkLmhpZGRlbiB7IGRpc3BsYXk6IG5vbmUgIWltcG9ydGFudDsg
;fQojaW5mby1wYW5lbC5lbWJlZGRlZCB7CiAgZmxleDogMTsgbWluLWhlaWdodDogMDsgb3ZlcmZsb3c6IGF1dG87IHBhZGRpbmc6IDhweCAxNnB4IDEycHg7
;IGJhY2tncm91bmQ6ICNmZmY7CiAgYm9yZGVyOiAwOyBtYXJnaW46IDA7Cn0KI2luZm8tcGFuZWwuZW1iZWRkZWQuaGlkZGVuIHsgZGlzcGxheTogbm9uZSAh
;aW1wb3J0YW50OyB9CiNjb25maWctcGFuZWwuZW1iZWRkZWQgewogIGZsZXg6IDEgMSAwOyBtaW4taGVpZ2h0OiAwOyBoZWlnaHQ6IDEwMCU7IG1hcmdpbjog
;MDsgYm9yZGVyOiAwOyBib3JkZXItcmFkaXVzOiAwOwogIGRpc3BsYXk6IGZsZXg7IGZsZXgtZGlyZWN0aW9uOiBjb2x1bW47IG92ZXJmbG93OiBoaWRkZW47
;IGJhY2tncm91bmQ6ICNmNGY2Zjk7Cn0KI2NvbmZpZy1wYW5lbC5lbWJlZGRlZC5oaWRkZW4geyBkaXNwbGF5OiBub25lICFpbXBvcnRhbnQ7IH0KI21haW4u
;bW9kZS10b29sICNwcmV2aWV3IHsgZGlzcGxheTogbm9uZTsgfQojbWFpbi5tb2RlLXRvb2wgewogIGdyaWQtdGVtcGxhdGUtY29sdW1uczogdmFyKC0tc2lk
;ZS13KSBtaW5tYXgoMCwgMWZyKTsKfQojYmFyLm1vZGUtdG9vbCAuc29ydCwgI2Jhci5tb2RlLXRvb2wgLnRvZ2dsZSB7IGRpc3BsYXk6IG5vbmU7IH0KI2Jh
;ci5tb2RlLWluZm8gLnNvcnQsICNiYXIubW9kZS1pbmZvIC50b2dnbGUgeyBkaXNwbGF5OiBub25lOyB9CiN2aWV3LXByb2MgeyBkaXNwbGF5OiBub25lICFp
;bXBvcnRhbnQ7IH0KI2J0bi1nb3RvLXByb2MgeyBkaXNwbGF5OiBub25lICFpbXBvcnRhbnQ7IH0KI3NpZGUtZm9vdCB7IGRpc3BsYXk6IG5vbmU7IH0KI2J0
;bi1zZXR0aW5ncyB7CiAgd2lkdGg6IDM0cHg7IGhlaWdodDogMzRweDsgYm9yZGVyOiAwOyBib3JkZXItcmFkaXVzOiA4cHg7IGJhY2tncm91bmQ6IHRyYW5z
;cGFyZW50OwogIGNvbG9yOiB2YXIoLS10eHQyKTsgY3Vyc29yOiBwb2ludGVyOwp9CiNidG4tc2V0dGluZ3M6aG92ZXIgeyBiYWNrZ3JvdW5kOiAjZWVmMWY2
;OyBjb2xvcjogdmFyKC0tdHh0KTsgfQoKLyogbGlzdCAqLwojbGlzdC1wYW5lIHsKICBkaXNwbGF5OiBmbGV4OyBmbGV4LWRpcmVjdGlvbjogY29sdW1uOyBt
;aW4td2lkdGg6IDA7IG1pbi1oZWlnaHQ6IDA7IGhlaWdodDogMTAwJTsKICBiYWNrZ3JvdW5kOiAjZmZmOyBib3JkZXI6IDA7IG92ZXJmbG93OiBoaWRkZW47
;CiAgYm9yZGVyLXJhZGl1czogMDsgYm94LXNoYWRvdzogbm9uZTsgb3V0bGluZTogbm9uZTsKfQojbGlzdCB7CiAgZmxleDogMTsgbWluLWhlaWdodDogMDsg
;b3ZlcmZsb3cteTogYXV0bzsgb3ZlcmZsb3cteDogaGlkZGVuOyBwYWRkaW5nOiA0cHggMDsKICAtd2Via2l0LW92ZXJmbG93LXNjcm9sbGluZzogdG91Y2g7
;Cn0KLnJvdyB7CiAgZGlzcGxheTogZ3JpZDsgZ3JpZC10ZW1wbGF0ZS1jb2x1bW5zOiA0MHB4IDFmcjsgZ2FwOiAxMHB4OwogIGFsaWduLWl0ZW1zOiBjZW50
;ZXI7IG1pbi1oZWlnaHQ6IDQ0cHg7CiAgcGFkZGluZzogNnB4IDE0cHg7IGN1cnNvcjogcG9pbnRlcjsgYm9yZGVyLWxlZnQ6IDNweCBzb2xpZCB0cmFuc3Bh
;cmVudDsKfQoucm93OmhvdmVyIHsgYmFja2dyb3VuZDogI2Y3ZjhmYjsgfQoucm93Lm9uIHsgYmFja2dyb3VuZDogdmFyKC0tc2VsKTsgYm9yZGVyLWxlZnQt
;Y29sb3I6IHZhcigtLWFjYyk7IH0KLnJvdyAuZmkgewogIHdpZHRoOiAzMnB4OyBoZWlnaHQ6IDMycHg7CiAgY29sb3I6IHZhcigtLXR4dDIpOyBkaXNwbGF5
;OiBncmlkOyBwbGFjZS1pdGVtczogY2VudGVyOyBmbGV4LXNocmluazogMDsKfQoucm93IC5maSBpbWcgewogIHdpZHRoOiAzMnB4OyBoZWlnaHQ6IDMycHg7
;CiAgb2JqZWN0LWZpdDogY29udGFpbjsgZGlzcGxheTogYmxvY2s7IGJhY2tncm91bmQ6IHRyYW5zcGFyZW50OwogIGltYWdlLXJlbmRlcmluZzogYXV0bzsK
;fQoucm93IC5maSAuZmktZmFsbGJhY2sgeyBmb250LXNpemU6IDE4cHg7IGxpbmUtaGVpZ2h0OiAxOyB9Ci5yb3cgLm5hbWUgeyBjb2xvcjogdmFyKC0tbmFt
;ZSk7IGZvbnQtc2l6ZTogMTMuNXB4OyBmb250LXdlaWdodDogNjAwOyB3b3JkLWJyZWFrOiBicmVhay1hbGw7IGxpbmUtaGVpZ2h0OiAxLjM1OyB9Ci5yb3cg
;Lm5hbWUgLmV4dCB7IGNvbG9yOiB2YXIoLS1uYW1lLWV4dCk7IH0KLnJvdyAubmFtZSBtYXJrLCAucm93IC5wYXRoIG1hcmsgewogIGJhY2tncm91bmQ6IHZh
;cigtLWhsKTsgY29sb3I6IHZhcigtLWhsLXRleHQpOyBwYWRkaW5nOiAwIDFweDsgYm9yZGVyLXJhZGl1czogMnB4OwogIGZvbnQtd2VpZ2h0OiA3MDA7Cn0K
;LnJvdyAucGF0aCB7IGNvbG9yOiAjNGI1NTYzOyBmb250LXNpemU6IDEycHg7IG1hcmdpbi10b3A6IDJweDsgd29yZC1icmVhazogYnJlYWstYWxsOyB9CiNs
;aXN0LWVtcHR5IHsKICBkaXNwbGF5OiBub25lOyBmbGV4OiAxOyBhbGlnbi1pdGVtczogY2VudGVyOyBqdXN0aWZ5LWNvbnRlbnQ6IGNlbnRlcjsKICBjb2xv
;cjogdmFyKC0tdHh0Myk7IGZvbnQtc2l6ZTogMTRweDsKfQojbGlzdC1lbXB0eS5vbiB7IGRpc3BsYXk6IGZsZXg7IH0KCi8qIHByZXZpZXcgKi8KI3ByZXZp
;ZXcgewogIGJhY2tncm91bmQ6ICNmZmY7IG1pbi13aWR0aDogMDsgbWluLWhlaWdodDogMDsgZGlzcGxheTogZmxleDsgZmxleC1kaXJlY3Rpb246IGNvbHVt
;bjsgb3ZlcmZsb3c6IGhpZGRlbjsKICBib3JkZXI6IDA7IGJvcmRlci1yYWRpdXM6IDA7IGJveC1zaGFkb3c6IG5vbmU7IG91dGxpbmU6IG5vbmU7Cn0KI3By
;ZXZpZXcub2ZmIC5wdi1ib2R5IHsgZGlzcGxheTogbm9uZTsgfQojcHJldmlldy5vZmYgLnB2LW9mZiB7CiAgZGlzcGxheTogZmxleDsgZmxleDogMTsgYWxp
;Z24taXRlbXM6IGNlbnRlcjsganVzdGlmeS1jb250ZW50OiBjZW50ZXI7IGNvbG9yOiB2YXIoLS10eHQzKTsKfQoucHYtb2ZmIHsgZGlzcGxheTogbm9uZTsg
;fQoucHYtbWV0YSB7CiAgZGlzcGxheTogZmxleDsgZ2FwOiAxNHB4OyBhbGlnbi1pdGVtczogY2VudGVyOyBwYWRkaW5nOiAxMHB4IDE0cHg7CiAgYm9yZGVy
;LWJvdHRvbTogMXB4IHNvbGlkIHZhcigtLWxpbmUpOyBjb2xvcjogdmFyKC0tdHh0Mik7IGZvbnQtc2l6ZTogMTJweDsgZmxleC13cmFwOiB3cmFwOwp9Ci5w
;di1tZXRhIGIgeyBjb2xvcjogdmFyKC0tdHh0KTsgZm9udC13ZWlnaHQ6IDYwMDsgfQoucHYtbWV0YSAuZHJ2IHsKICBkaXNwbGF5OiBpbmxpbmUtZmxleDsg
;YWxpZ24taXRlbXM6IGNlbnRlcjsgZ2FwOiA2cHg7CiAgY29sb3I6IHZhcigtLXR4dCk7IGZvbnQtd2VpZ2h0OiA2MDA7Cn0KLnB2LW1ldGEgLmRydiBpbWcg
;ewogIHdpZHRoOiAxNnB4OyBoZWlnaHQ6IDE2cHg7IG9iamVjdC1maXQ6IGNvbnRhaW47IGJhY2tncm91bmQ6IHRyYW5zcGFyZW50OyBmbGV4LXNocmluazog
;MDsKfQoucHYtYm9keSB7IGZsZXg6IDE7IG1pbi1oZWlnaHQ6IDA7IGRpc3BsYXk6IGZsZXg7IGZsZXgtZGlyZWN0aW9uOiBjb2x1bW47IH0KLnB2LW1lZGlh
;IHsKICBmbGV4OiAxOyBtaW4taGVpZ2h0OiAwOyBiYWNrZ3JvdW5kOiAjM2Y0NDUwOyBkaXNwbGF5OiBmbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBqdXN0
;aWZ5LWNvbnRlbnQ6IGNlbnRlcjsKICBvdmVyZmxvdzogaGlkZGVuOyBwb3NpdGlvbjogcmVsYXRpdmU7Cn0KLnB2LW1lZGlhLmNvbXBhY3QgewogIGZsZXg6
;IDAgMCBhdXRvOyBtaW4taGVpZ2h0OiAwOyBoZWlnaHQ6IDA7IHBhZGRpbmc6IDA7IG92ZXJmbG93OiBoaWRkZW47CiAgYm9yZGVyOiAwOwp9Ci5wdi1ib2R5
;LnRleHQtbW9kZSAucHYtbWVkaWEgeyBkaXNwbGF5OiBub25lOyB9Ci5wdi1ib2R5LnRleHQtbW9kZSAucHYtdGV4dCB7CiAgZmxleDogMTsgZGlzcGxheTog
;ZmxleDsgYm9yZGVyLXRvcDogMDsgbWluLWhlaWdodDogMDsKfQoucHYtbWVkaWEgaW1nLCAucHYtbWVkaWEgdmlkZW8gewogIG1heC13aWR0aDogMTAwJTsg
;bWF4LWhlaWdodDogMTAwJTsgb2JqZWN0LWZpdDogY29udGFpbjsgYmFja2dyb3VuZDogIzExMTsKfQoucHYtbWVkaWEgLnB2LWZpbGVpbmZvIGltZy5iaWct
;aWNvIHsKICBiYWNrZ3JvdW5kOiB0cmFuc3BhcmVudCAhaW1wb3J0YW50OwogIG1heC13aWR0aDogNDhweDsgbWF4LWhlaWdodDogNDhweDsKfQoucHYtbWVk
;aWEgZW1iZWQucGRmLCAucHYtbWVkaWEgaWZyYW1lLnBkZiB7CiAgd2lkdGg6IDEwMCU7IGhlaWdodDogMTAwJTsgYm9yZGVyOiAwOyBiYWNrZ3JvdW5kOiAj
;NTI1NjU5Owp9Ci5wdi1tZWRpYSAucGggeyBjb2xvcjogI2NiZDVlMTsgZm9udC1zaXplOiAxM3B4OyB9Ci5wdi1maWxlaW5mbyB7CiAgZGlzcGxheTogZmxl
;eDsgZmxleC1kaXJlY3Rpb246IGNvbHVtbjsgYWxpZ24taXRlbXM6IHN0cmV0Y2g7IGp1c3RpZnktY29udGVudDogY2VudGVyOwogIGdhcDogMTBweDsgcGFk
;ZGluZzogMjhweCAyNHB4OyB0ZXh0LWFsaWduOiBsZWZ0OyB3aWR0aDogMTAwJTsgaGVpZ2h0OiAxMDAlOwogIGJveC1zaXppbmc6IGJvcmRlci1ib3g7IG92
;ZXJmbG93OiBhdXRvOwogIGJhY2tncm91bmQ6ICNmN2Y4ZmI7IGNvbG9yOiB2YXIoLS10eHQpOwp9Ci5wdi1maWxlaW5mbyAuYmlnLWljbyB7CiAgd2lkdGg6
;IDQ4cHg7IGhlaWdodDogNDhweDsgb2JqZWN0LWZpdDogY29udGFpbjsgYWxpZ24tc2VsZjogY2VudGVyOwogIGJhY2tncm91bmQ6IHRyYW5zcGFyZW50ICFp
;bXBvcnRhbnQ7CiAgaW1hZ2UtcmVuZGVyaW5nOiBhdXRvOyBmbGV4LXNocmluazogMDsKfQoucHYtbWVkaWE6aGFzKC5wdi1maWxlaW5mbykgeyBiYWNrZ3Jv
;dW5kOiAjZjdmOGZiOyB9Ci5wdi1maWxlaW5mbyAuZm4gewogIGZvbnQtc2l6ZTogMTZweDsgZm9udC13ZWlnaHQ6IDY1MDsgY29sb3I6IHZhcigtLXR4dCk7
;CiAgd29yZC1icmVhazogYnJlYWstYWxsOyB0ZXh0LWFsaWduOiBjZW50ZXI7IHdpZHRoOiAxMDAlOyBsaW5lLWhlaWdodDogMS4zNTsKfQoucHYtZmlsZWlu
;Zm8gLnRuIHsKICBmb250LXNpemU6IDEycHg7IGNvbG9yOiB2YXIoLS10eHQyKTsgdGV4dC1hbGlnbjogY2VudGVyOyB3aWR0aDogMTAwJTsKfQoucHYtZmls
;ZWluZm8gLmhpbnQgewogIGZvbnQtc2l6ZTogMTJweDsgY29sb3I6ICNiNDUzMDk7IHRleHQtYWxpZ246IGNlbnRlcjsgd2lkdGg6IDEwMCU7IGxpbmUtaGVp
;Z2h0OiAxLjQ1Owp9Ci5wdi1maWxlaW5mbyAua3YgewogIGRpc3BsYXk6IGZsZXg7IGZsZXgtZGlyZWN0aW9uOiBjb2x1bW47IGdhcDogOHB4OwogIG1hcmdp
;bi10b3A6IDZweDsgd2lkdGg6IDEwMCU7IGZvbnQtc2l6ZTogMTIuNXB4OyBjb2xvcjogdmFyKC0tdHh0Mik7Cn0KLnB2LWZpbGVpbmZvIC5rdi1yb3cgewog
;IGRpc3BsYXk6IGdyaWQ7IGdyaWQtdGVtcGxhdGUtY29sdW1uczogNC41ZW0gMWZyOyBnYXA6IDEycHg7IGFsaWduLWl0ZW1zOiBzdGFydDsKICBsaW5lLWhl
;aWdodDogMS41NTsKfQoucHYtZmlsZWluZm8gLmt2LXJvdyAuayB7IGNvbG9yOiB2YXIoLS10eHQyKTsgd2hpdGUtc3BhY2U6IG5vd3JhcDsgfQoucHYtZmls
;ZWluZm8gLmt2LXJvdyAudiB7IGNvbG9yOiB2YXIoLS10eHQpOyB3b3JkLWJyZWFrOiBicmVhay1hbGw7IGZvbnQtd2VpZ2h0OiA1MDA7IH0KLnB2LWZpbGVp
;bmZvIC5raWRzIHsKICBtYXJnaW4tdG9wOiA4cHg7IGZvbnQtc2l6ZTogMTIuNXB4OyBjb2xvcjogdmFyKC0tdHh0Mik7IGxpbmUtaGVpZ2h0OiAxLjY7CiAg
;d29yZC1icmVhazogYnJlYWstYWxsOwp9Ci5wdi1maWxlaW5mbyAua2lkcyBiIHsgY29sb3I6IHZhcigtLXR4dCk7IGZvbnQtd2VpZ2h0OiA2MDA7IH0KCi8q
;IGNvbnRleHQgbWVudSAqLwojY3R4IHsKICBkaXNwbGF5OiBub25lOyBwb3NpdGlvbjogZml4ZWQ7IHotaW5kZXg6IDIwMDsgbWluLXdpZHRoOiAxNjhweDsK
;ICBwYWRkaW5nOiA0cHg7IGJhY2tncm91bmQ6ICNmZmY7IGJvcmRlcjogMXB4IHNvbGlkIHZhcigtLWxpbmUpOwogIGJvcmRlci1yYWRpdXM6IDhweDsgYm94
;LXNoYWRvdzogMCA4cHggMjRweCByZ2JhKDE1LDIzLDQyLC4xMik7Cn0KI2N0eC5vbiB7IGRpc3BsYXk6IGJsb2NrOyB9CiNjdHggYnV0dG9uIHsKICBkaXNw
;bGF5OiBmbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBnYXA6IDEwcHg7IHdpZHRoOiAxMDAlOwogIGJvcmRlcjogMDsgYmFja2dyb3VuZDogdHJhbnNwYXJl
;bnQ7IHBhZGRpbmc6IDhweCAxMHB4OyBib3JkZXItcmFkaXVzOiA2cHg7CiAgY3Vyc29yOiBwb2ludGVyOyBjb2xvcjogdmFyKC0tdHh0KTsgZm9udC1zaXpl
;OiAxM3B4OyB0ZXh0LWFsaWduOiBsZWZ0Owp9CiNjdHggYnV0dG9uOmhvdmVyIHsgYmFja2dyb3VuZDogI2YzZjRmNjsgfQojY3R4IGJ1dHRvbi5kYW5nZXIg
;eyBjb2xvcjogI2RjMjYyNjsgfQojY3R4IGJ1dHRvbi5kYW5nZXI6aG92ZXIgeyBiYWNrZ3JvdW5kOiAjZmVmMmYyOyB9CiNjdHggLmMtaWNvIHsKICB3aWR0
;aDogMTZweDsgaGVpZ2h0OiAxNnB4OyBmbGV4LXNocmluazogMDsKICBkaXNwbGF5OiBpbmxpbmUtZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsganVzdGlm
;eS1jb250ZW50OiBjZW50ZXI7CiAgY29sb3I6ICMzNzQxNTE7Cn0KI2N0eCBidXR0b24uZGFuZ2VyIC5jLWljbyB7IGNvbG9yOiAjZGMyNjI2OyB9CiNjdHgg
;LmMtaWNvIHN2ZyB7IHdpZHRoOiAxNnB4OyBoZWlnaHQ6IDE2cHg7IGRpc3BsYXk6IGJsb2NrOyB9CgoucHYtdGV4dCB7CiAgZmxleDogMTsgbWluLWhlaWdo
;dDogMDsgZGlzcGxheTogZmxleDsgZmxleC1kaXJlY3Rpb246IGNvbHVtbjsgYm9yZGVyLXRvcDogMXB4IHNvbGlkIHZhcigtLWxpbmUpOwp9Ci5wdi10ZXh0
;IC5oZCB7CiAgcGFkZGluZzogOHB4IDE0cHg7IGZvbnQtc2l6ZTogMTJweDsgY29sb3I6IHZhcigtLXR4dDIpOyBiYWNrZ3JvdW5kOiAjZmFmYmZjOyBib3Jk
;ZXItYm90dG9tOiAxcHggc29saWQgdmFyKC0tbGluZSk7Cn0KLnB2LXRleHQgcHJlIHsKICBtYXJnaW46IDA7IGZsZXg6IDE7IG92ZXJmbG93OiBhdXRvOyBw
;YWRkaW5nOiAxMnB4IDE0cHg7IGZvbnQtc2l6ZTogMTJweDsgbGluZS1oZWlnaHQ6IDEuNTsKICB3aGl0ZS1zcGFjZTogcHJlLXdyYXA7IHdvcmQtYnJlYWs6
;IGJyZWFrLXdvcmQ7IGZvbnQtZmFtaWx5OiBDb25zb2xhcywgIlNhcmFzYSBNb25vIFNDIiwgbW9ub3NwYWNlOwogIGJhY2tncm91bmQ6ICNmZmY7IGNvbG9y
;OiAjMTExODI3Owp9CgovKiBib3R0b23vvJrorr7nva7lnKjlt6bkuIvop5LvvIzmjpLluo8v6aKE6KeI57Sn5oyo6K6+572u5bm255WZ56m66ZqZICovCiNi
;YXIgewogIGhlaWdodDogNDJweDsgZGlzcGxheTogZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsgZ2FwOiAwOwogIHBhZGRpbmc6IDAgMTRweCAwIDEwcHg7
;IGJhY2tncm91bmQ6IHZhcigtLWNocm9tZSk7IGJvcmRlci10b3A6IDA7IGZvbnQtc2l6ZTogMTIuNXB4OyBjb2xvcjogdmFyKC0tdHh0Mik7Cn0KI2JhciAu
;YmFyLWxlZnQgewogIGZsZXgtc2hyaW5rOiAwOyBoZWlnaHQ6IDEwMCU7CiAgZGlzcGxheTogZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsKfQojYmFyIC5i
;YXItbWFpbiB7CiAgZmxleDogMTsgbWluLXdpZHRoOiAwOyBoZWlnaHQ6IDEwMCU7CiAgZGlzcGxheTogZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsgZ2Fw
;OiAxNnB4OwogIG1hcmdpbi1sZWZ0OiAxOHB4OyBib3gtc2l6aW5nOiBib3JkZXItYm94Owp9CiNiYXIgLnNvcnQgeyBkaXNwbGF5OiBpbmxpbmUtZmxleDsg
;YWxpZ24taXRlbXM6IGNlbnRlcjsgZ2FwOiA2cHg7IGN1cnNvcjogcG9pbnRlcjsgYm9yZGVyOiAwOyBiYWNrZ3JvdW5kOiB0cmFuc3BhcmVudDsgY29sb3I6
;IGluaGVyaXQ7IH0KI2JhciAuc29ydDpob3ZlciB7IGNvbG9yOiB2YXIoLS10eHQpOyB9CiNiYXIgLnNwYWNlciB7IGZsZXg6IDE7IH0KLnRvZ2dsZSB7CiAg
;ZGlzcGxheTogaW5saW5lLWZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGdhcDogOHB4OyBjdXJzb3I6IHBvaW50ZXI7IHVzZXItc2VsZWN0OiBub25lOwp9
;Ci50b2dnbGUgaW5wdXQgeyBkaXNwbGF5OiBub25lOyB9Ci50b2dnbGUgLnN3IHsKICB3aWR0aDogMzZweDsgaGVpZ2h0OiAyMHB4OyBib3JkZXItcmFkaXVz
;OiA5OTlweDsgYmFja2dyb3VuZDogI2QxZDVkYjsgcG9zaXRpb246IHJlbGF0aXZlOyB0cmFuc2l0aW9uOiAuMnM7Cn0KLnRvZ2dsZSAuc3c6OmFmdGVyIHsK
;ICBjb250ZW50OiAiIjsgcG9zaXRpb246IGFic29sdXRlOyB0b3A6IDJweDsgbGVmdDogMnB4OyB3aWR0aDogMTZweDsgaGVpZ2h0OiAxNnB4OwogIGJvcmRl
;ci1yYWRpdXM6IDUwJTsgYmFja2dyb3VuZDogI2ZmZjsgdHJhbnNpdGlvbjogLjJzOyBib3gtc2hhZG93OiAwIDFweCAycHggcmdiYSgwLDAsMCwuMik7Cn0K
;LnRvZ2dsZSBpbnB1dDpjaGVja2VkICsgLnN3IHsgYmFja2dyb3VuZDogdmFyKC0tYWNjKTsgfQoudG9nZ2xlIGlucHV0OmNoZWNrZWQgKyAuc3c6OmFmdGVy
;IHsgbGVmdDogMThweDsgfQojY291bnQgeyBjb2xvcjogdmFyKC0tdHh0KTsgZm9udC12YXJpYW50LW51bWVyaWM6IHRhYnVsYXItbnVtczsgfQo8L3N0eWxl
;Pgo8L2hlYWQ+Cjxib2R5Pgo8ZGl2IGlkPSJhcHAiIGNsYXNzPSJib290aW5nIj4KICA8ZGl2IGlkPSJ0aXRsZWJhciI+CiAgICA8ZGl2IGNsYXNzPSJ0Yi1i
;cmFuZCBuby1kcmFnIiB0aXRsZT0i5Luq6KGo55uYIj4KICAgICAgPHN2ZyBjbGFzcz0idGItaWNvIiB2aWV3Qm94PSIwIDAgMTYgMTYiIGZpbGw9Im5vbmUi
;IGFyaWEtaGlkZGVuPSJ0cnVlIj4KICAgICAgICA8Y2lyY2xlIGN4PSI4IiBjeT0iOSIgcj0iNS4yIiBzdHJva2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdp
;ZHRoPSIxLjQiLz4KICAgICAgICA8cGF0aCBkPSJNOCA5bDMuMi0zLjIiIHN0cm9rZT0iY3VycmVudENvbG9yIiBzdHJva2Utd2lkdGg9IjEuNCIgc3Ryb2tl
;LWxpbmVjYXA9InJvdW5kIi8+CiAgICAgICAgPGNpcmNsZSBjeD0iOCIgY3k9IjkiIHI9IjEuMTUiIGZpbGw9ImN1cnJlbnRDb2xvciIvPgogICAgICA8L3N2
;Zz4KICAgICAgPHNwYW4gY2xhc3M9InRiLW5hbWUiPuS7quihqOebmDwvc3Bhbj4KICAgIDwvZGl2PgogICAgPGRpdiBpZD0iZmlsdGVyLXJhaWwiIGNsYXNz
;PSJuby1kcmFnIj4KICAgICAgPGRpdiBpZD0iZmlsdGVyLWJhciIgYXJpYS1sYWJlbD0i5pCc57Si562b6YCJIj48L2Rpdj4KICAgIDwvZGl2PgogICAgPGRp
;diBjbGFzcz0idGItc3BhY2UiIGlkPSJ0aXRsZWJhci1kcmFnIj48L2Rpdj4KICAgIDxkaXYgY2xhc3M9InRiLXdpbiBuby1kcmFnIj4KICAgICAgPGJ1dHRv
;biB0eXBlPSJidXR0b24iIGlkPSJidG4td2luLW1pbiIgdGl0bGU9IuacgOWwj+WMliIgYXJpYS1sYWJlbD0i5pyA5bCP5YyWIj4KICAgICAgICA8c3ZnIHZp
;ZXdCb3g9IjAgMCAxMCAxMCIgZmlsbD0ibm9uZSIgYXJpYS1oaWRkZW49InRydWUiPjxwYXRoIGQ9Ik0xLjUgNWg3IiBzdHJva2U9ImN1cnJlbnRDb2xvciIg
;c3Ryb2tlLXdpZHRoPSIxLjIiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIvPjwvc3ZnPgogICAgICA8L2J1dHRvbj4KICAgICAgPGJ1dHRvbiB0eXBlPSJidXR0
;b24iIGlkPSJidG4td2luLW1heCIgdGl0bGU9IuacgOWkp+WMliIgYXJpYS1sYWJlbD0i5pyA5aSn5YyWIj4KICAgICAgICA8c3ZnIHZpZXdCb3g9IjAgMCAx
;MCAxMCIgZmlsbD0ibm9uZSIgYXJpYS1oaWRkZW49InRydWUiPjxyZWN0IHg9IjEuNiIgeT0iMS42IiB3aWR0aD0iNi44IiBoZWlnaHQ9IjYuOCIgcng9IjAu
;NiIgc3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0cm9rZS13aWR0aD0iMS4yIi8+PC9zdmc+CiAgICAgIDwvYnV0dG9uPgogICAgICA8YnV0dG9uIHR5cGU9ImJ1
;dHRvbiIgaWQ9ImJ0bi13aW4tY2xvc2UiIHRpdGxlPSLlhbPpl60iIGFyaWEtbGFiZWw9IuWFs+mXrSI+CiAgICAgICAgPHN2ZyB2aWV3Qm94PSIwIDAgMTAg
;MTAiIGZpbGw9Im5vbmUiIGFyaWEtaGlkZGVuPSJ0cnVlIj48cGF0aCBkPSJNMiAybDYgNk04IDJMMiA4IiBzdHJva2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tl
;LXdpZHRoPSIxLjIiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIvPjwvc3ZnPgogICAgICA8L2J1dHRvbj4KICAgIDwvZGl2PgogIDwvZGl2PgogIDxkaXYgaWQ9
;ImJvb3QiIGNsYXNzPSJvbiI+CiAgICA8ZGl2IGNsYXNzPSJyaW5nLXdyYXAiPgogICAgICA8c3ZnIHZpZXdCb3g9IjAgMCAxMjAgMTIwIj4KICAgICAgICA8
;Y2lyY2xlIGNsYXNzPSJyaW5nLWJnIiBjeD0iNjAiIGN5PSI2MCIgcj0iNTIiPjwvY2lyY2xlPgogICAgICAgIDxjaXJjbGUgaWQ9InJpbmctZmciIGNsYXNz
;PSJyaW5nLWZnIiBjeD0iNjAiIGN5PSI2MCIgcj0iNTIiCiAgICAgICAgICBzdHJva2UtZGFzaGFycmF5PSIzMjYuNzMiIHN0cm9rZS1kYXNob2Zmc2V0PSIz
;MjYuNzMiPjwvY2lyY2xlPgogICAgICA8L3N2Zz4KICAgICAgPGRpdiBjbGFzcz0icmluZy1sYWJlbCI+CiAgICAgICAgPGRpdiBjbGFzcz0idDEiPuejgeeb
;mOe0ouW8leS4rTwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9InQyIiBpZD0iYm9vdC1wY3QiPuKApjwvZGl2PgogICAgICA8L2Rpdj4KICAgIDwvZGl2Pgog
;ICAgPGRpdiBjbGFzcz0iYm9vdC1oaW50Ij4KICAgICAg5q2j5Zyo5bu656uL56OB55uY5paH5Lu257Si5byV77yM5a6M5oiQ5ZCO5Y2z5Y+v5pCc57Si44CC
;PGJyPgogICAgICDoi6XmnKzmnLrlt7Llronoo4UgRXZlcnl0aGluZyDlubblvIDmnLrlkK/liqjvvIzkuIvmrKHkvJrmm7Tlv6vlsLHnu6rjgIIKICAgIDwv
;ZGl2PgogIDwvZGl2PgoKICA8ZGl2IGlkPSJjaHJvbWUiIGNsYXNzPSJoaWRkZW4iPgogICAgPGRpdiBpZD0idmlldy1zZWFyY2giPgogICAgPGRpdiBpZD0i
;dG9wIj4KICAgICAgPGRpdiBpZD0iZHJpdmUtd3JhcCIgY2xhc3M9Im5vLWRyYWciPgogICAgICAgIDxidXR0b24gaWQ9ImJ0bi1kcml2ZSIgdHlwZT0iYnV0
;dG9uIiB0aXRsZT0i6YCJ5oup5pCc57Si56OB55uYIj4KICAgICAgICAgIDxpbWcgaWQ9ImRyaXZlLWJ0bi1pY28iIGNsYXNzPSJkcml2ZS1pY28gaGlkZGVu
;IiBhbHQ9IiIgd2lkdGg9IjIwIiBoZWlnaHQ9IjIwIj4KICAgICAgICAgIDxzcGFuIGlkPSJkcml2ZS1sYWJlbCI+5YWo55uY5pCc57SiPC9zcGFuPjxzcGFu
;IGNsYXNzPSJjYXJldCI+4pa+PC9zcGFuPgogICAgICAgIDwvYnV0dG9uPgogICAgICAgIDxkaXYgaWQ9ImRyaXZlLW1lbnUiIHJvbGU9Im1lbnUiPjwvZGl2
;PgogICAgICA8L2Rpdj4KICAgICAgPGRpdiBpZD0idG9wLXJlc3QiPgogICAgICAgIDxkaXYgaWQ9InNlYXJjaC13cmFwIiBjbGFzcz0ibm8tZHJhZyI+CiAg
;ICAgICAgICA8ZGl2IGlkPSJzZWFyY2gtYm94Ij4KICAgICAgICAgICAgPGJ1dHRvbiB0eXBlPSJidXR0b24iIGlkPSJzZWFyY2gtaWNvIiB0aXRsZT0i5pyA
;6L+R5pCc57SiIiBhcmlhLWxhYmVsPSLmnIDov5HmkJzntKIiPgogICAgICAgICAgICAgIDxzdmcgdmlld0JveD0iMCAwIDE2IDE2IiBmaWxsPSJub25lIiBh
;cmlhLWhpZGRlbj0idHJ1ZSI+CiAgICAgICAgICAgICAgICA8Y2lyY2xlIGN4PSI3IiBjeT0iNyIgcj0iNC4yNSIgc3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0
;cm9rZS13aWR0aD0iMS40Ii8+CiAgICAgICAgICAgICAgICA8cGF0aCBkPSJNMTAuMiAxMC4yTDEzLjQgMTMuNCIgc3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0
;cm9rZS13aWR0aD0iMS40IiBzdHJva2UtbGluZWNhcD0icm91bmQiLz4KICAgICAgICAgICAgICA8L3N2Zz4KICAgICAgICAgICAgPC9idXR0b24+CiAgICAg
;ICAgICAgIDxpbnB1dCBpZD0icSIgdHlwZT0idGV4dCIgcGxhY2Vob2xkZXI9Iui+k+WFpeaWh+S7tuWQjSAvIOaJqeWxleWQjSAvIOi3r+W+hOWFs+mUruWt
;l++8m3wg6KGo56S65LiU77yMfHwg6KGo56S65oiWIiBhdXRvY29tcGxldGU9Im9mZiIgc3BlbGxjaGVjaz0iZmFsc2UiPgogICAgICAgICAgICA8YnV0dG9u
;IHR5cGU9ImJ1dHRvbiIgaWQ9ImNmZy1zZWFyY2gtY2xlYXIiIHRpdGxlPSLmuIXnqbrmkJzntKLmnaHku7YiIGFyaWEtbGFiZWw9Iua4heepuuaQnOe0oiI+
;CiAgICAgICAgICAgICAgPHNwYW4gaWQ9ImNmZy1zZWFyY2gtaGl0Ij48L3NwYW4+CiAgICAgICAgICAgICAgPHN2ZyBjbGFzcz0iY2ZnLXgiIHZpZXdCb3g9
;IjAgMCAyNCAyNCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0cm9rZS13aWR0aD0iMi4yIiBzdHJva2UtbGluZWNhcD0icm91bmQiIGFy
;aWEtaGlkZGVuPSJ0cnVlIj48cGF0aCBkPSJNNiA2bDEyIDEyTTE4IDZMNiAxOCIvPjwvc3ZnPgogICAgICAgICAgICA8L2J1dHRvbj4KICAgICAgICAgICAg
;PGJ1dHRvbiBpZD0iYnRuLWNsZWFyIiB0eXBlPSJidXR0b24iIHRpdGxlPSLmuIXnqbrmkJzntKIiPua4heepujwvYnV0dG9uPgogICAgICAgICAgICA8ZGl2
;IGlkPSJoaXN0LW1lbnUiIHJvbGU9Im1lbnUiPjwvZGl2PgogICAgICAgICAgPC9kaXY+CiAgICAgICAgICA8ZGl2IGlkPSJjZmctc2VhcmNoLXRhZ3MiIHJv
;bGU9Imdyb3VwIiBhcmlhLWxhYmVsPSLmkJzntKLojIPlm7QiPgogICAgICAgICAgICA8YnV0dG9uIHR5cGU9ImJ1dHRvbiIgY2xhc3M9ImNmZy1zdGFnIiBk
;YXRhLWNmZy1zY29wZT0ia2V5IiB0aXRsZT0i5Y+q5pCcIGtleSI+5LuFIGtleTwvYnV0dG9uPgogICAgICAgICAgICA8YnV0dG9uIHR5cGU9ImJ1dHRvbiIg
;Y2xhc3M9ImNmZy1zdGFnIiBkYXRhLWNmZy1zY29wZT0idmFsdWUiIHRpdGxlPSLlj6rmkJwgdmFsdWUiPuS7hSB2YWx1ZTwvYnV0dG9uPgogICAgICAgICAg
;ICA8YnV0dG9uIHR5cGU9ImJ1dHRvbiIgY2xhc3M9ImNmZy1zdGFnIiBkYXRhLWNmZy1zY29wZT0iZW5hYmxlZCIgdGl0bGU9IuWPqueci+W3suWQr+eUqCI+
;5ZCv55SoPC9idXR0b24+CiAgICAgICAgICAgIDxidXR0b24gdHlwZT0iYnV0dG9uIiBjbGFzcz0iY2ZnLXN0YWciIGRhdGEtY2ZnLXNjb3BlPSJkaXNhYmxl
;ZCIgdGl0bGU9IuWPqueci+acquWQr+eUqCI+5pyq5ZCv55SoPC9idXR0b24+CiAgICAgICAgICA8L2Rpdj4KICAgICAgICA8L2Rpdj4KICAgICAgICA8ZGl2
;IGlkPSJ0b3AtcHJldmlldyIgY2xhc3M9Im5vLWRyYWciPgogICAgICAgICAgPGRpdiBjbGFzcz0icHYtbWV0YSIgaWQ9InB2LW1ldGEiPumAieaLqeaWh+S7
;tuS7pemihOiniDwvZGl2PgogICAgICAgIDwvZGl2PgogICAgICA8L2Rpdj4KICAgIDwvZGl2PgoKICAgIDxkaXYgaWQ9Im1haW4iPgogICAgICA8YXNpZGUg
;aWQ9InNpZGUiPgogICAgICAgIDxidXR0b24gY2xhc3M9ImNhdCBvbiIgZGF0YS1jYXQ9ImFsbCI+PHNwYW4gY2xhc3M9ImljbyIgZGF0YS1jYXQtaWNvPSJh
;bGwiPuKYsDwvc3Bhbj7lhajpg6g8L2J1dHRvbj4KICAgICAgICA8YnV0dG9uIGNsYXNzPSJjYXQiIGRhdGEtY2F0PSJmb2xkZXIiPjxzcGFuIGNsYXNzPSJp
;Y28iIGRhdGEtY2F0LWljbz0iZm9sZGVyIj7wn5OBPC9zcGFuPuaWh+S7tuWkuTwvYnV0dG9uPgogICAgICAgIDxidXR0b24gY2xhc3M9ImNhdCIgZGF0YS1j
;YXQ9ImV4Y2VsIj48c3BhbiBjbGFzcz0iaWNvIiBkYXRhLWNhdC1pY289ImV4Y2VsIj7wn5OKPC9zcGFuPkVYQ0VMPC9idXR0b24+CiAgICAgICAgPGJ1dHRv
;biBjbGFzcz0iY2F0IiBkYXRhLWNhdD0id29yZCI+PHNwYW4gY2xhc3M9ImljbyIgZGF0YS1jYXQtaWNvPSJ3b3JkIj7wn5OEPC9zcGFuPldPUkQ8L2J1dHRv
;bj4KICAgICAgICA8YnV0dG9uIGNsYXNzPSJjYXQiIGRhdGEtY2F0PSJwcHQiPjxzcGFuIGNsYXNzPSJpY28iIGRhdGEtY2F0LWljbz0icHB0Ij7wn5ORPC9z
;cGFuPlBQVDwvYnV0dG9uPgogICAgICAgIDxidXR0b24gY2xhc3M9ImNhdCIgZGF0YS1jYXQ9InBkZiI+PHNwYW4gY2xhc3M9ImljbyIgZGF0YS1jYXQtaWNv
;PSJwZGYiPvCfk5U8L3NwYW4+UERGPC9idXR0b24+CiAgICAgICAgPGJ1dHRvbiBjbGFzcz0iY2F0IiBkYXRhLWNhdD0iaW1hZ2UiPjxzcGFuIGNsYXNzPSJp
;Y28iIGRhdGEtY2F0LWljbz0iaW1hZ2UiPvCflrw8L3NwYW4+5Zu+54mHPC9idXR0b24+CiAgICAgICAgPGJ1dHRvbiBjbGFzcz0iY2F0IiBkYXRhLWNhdD0i
;dmlkZW8iPjxzcGFuIGNsYXNzPSJpY28iIGRhdGEtY2F0LWljbz0idmlkZW8iPuKWtjwvc3Bhbj7op4bpopE8L2J1dHRvbj4KICAgICAgICA8YnV0dG9uIGNs
;YXNzPSJjYXQiIGRhdGEtY2F0PSJhdWRpbyI+PHNwYW4gY2xhc3M9ImljbyIgZGF0YS1jYXQtaWNvPSJhdWRpbyI+4pmqPC9zcGFuPumfs+mikTwvYnV0dG9u
;PgogICAgICAgIDxidXR0b24gY2xhc3M9ImNhdCIgZGF0YS1jYXQ9InppcCI+PHNwYW4gY2xhc3M9ImljbyIgZGF0YS1jYXQtaWNvPSJ6aXAiPvCfl5w8L3Nw
;YW4+5Y6L57yp5paH5Lu2PC9idXR0b24+CiAgICAgICAgPGRpdiBjbGFzcz0ic2lkZS1zZXAiIHJvbGU9InNlcGFyYXRvciI+PC9kaXY+CiAgICAgICAgPGJ1
;dHRvbiBjbGFzcz0iY2F0IiBkYXRhLWNhdD0iX19oYW5kbGUiIHR5cGU9ImJ1dHRvbiI+PHNwYW4gY2xhc3M9ImljbyI+4puTPC9zcGFuPuWFs+iBlOWPpeaf
;hDwvYnV0dG9uPgogICAgICAgIDxidXR0b24gY2xhc3M9ImNhdCIgZGF0YS1jYXQ9Il9faW5mbyIgdHlwZT0iYnV0dG9uIj48c3BhbiBjbGFzcz0iaWNvIj7i
;hLk8L3NwYW4+5pys5py65L+h5oGvPC9idXR0b24+CiAgICAgICAgPGRpdiBjbGFzcz0ic2lkZS1zZXAiIHJvbGU9InNlcGFyYXRvciI+PC9kaXY+CiAgICAg
;ICAgPGJ1dHRvbiBjbGFzcz0iY2F0IiBkYXRhLWNhdD0iX19jb25maWciIHR5cGU9ImJ1dHRvbiI+PHNwYW4gY2xhc3M9ImljbyI+4pqZPC9zcGFuPui/kOih
;jOmFjee9rjwvYnV0dG9uPgogICAgICAgIDxkaXYgaWQ9InNpZGUtZm9vdCI+PC9kaXY+CiAgICAgIDwvYXNpZGU+CgogICAgICA8ZGl2IGlkPSJjb250ZW50
;LXBhbmUiPgogICAgICAgIDxzZWN0aW9uIGlkPSJsaXN0LXBhbmUiPgogICAgICAgICAgPGRpdiBpZD0iZmlsZS1yZXN1bHRzIj4KICAgICAgICAgICAgPGRp
;diBpZD0ibGlzdCI+PC9kaXY+CiAgICAgICAgICAgIDxkaXYgaWQ9Imxpc3QtZW1wdHkiPui+k+WFpeWFs+mUruWtl+W8gOWni+aQnOe0ou+8jOaIlumAieaL
;qeW3puS+p+WIhuexu+a1j+iniDwvZGl2PgogICAgICAgICAgPC9kaXY+CiAgICAgICAgICA8ZGl2IGlkPSJoYW5kbGUtcGFuZWwiIGNsYXNzPSJoaWRkZW4g
;bm8tZHJhZyBlbWJlZGRlZCI+CiAgICAgICAgICAgIDxkaXYgY2xhc3M9ImhhbmRsZS1iYW5uZXIiIGlkPSJoYW5kbGUtYmFubmVyIj48L2Rpdj4KICAgICAg
;ICAgICAgPGRpdiBjbGFzcz0iaGFuZGxlLXNjcm9sbCIgaWQ9ImhhbmRsZS1zY3JvbGwiPgogICAgICAgICAgICAgIDxkaXYgY2xhc3M9ImhhbmRsZS1oZWFk
;IGhhbmRsZS1jb2xzIiBpZD0iaGFuZGxlLWhlYWQiPgogICAgICAgICAgICAgICAgPGRpdiBjbGFzcz0iaGFuZGxlLWhjZWxsIiBkYXRhLXNvcnQ9Im5hbWUi
;PuWQjeensDxzcGFuIGNsYXNzPSJoLXNvcnQiPjwvc3Bhbj48L2Rpdj4KICAgICAgICAgICAgICAgIDxkaXYgY2xhc3M9ImhhbmRsZS1oY2VsbCIgZGF0YS1z
;b3J0PSJwaWQiPlBJRDxzcGFuIGNsYXNzPSJoLXNvcnQiPjwvc3Bhbj48L2Rpdj4KICAgICAgICAgICAgICAgIDxkaXYgY2xhc3M9ImhhbmRsZS1oY2VsbCBo
;YW5kbGUtY29sLXBvcnQgaGlkZGVuIiBkYXRhLXNvcnQ9Imxwb3J0Ij7mnKzmnLrnq6/lj6M8c3BhbiBjbGFzcz0iaC1zb3J0Ij48L3NwYW4+PC9kaXY+CiAg
;ICAgICAgICAgICAgICA8ZGl2IGNsYXNzPSJoYW5kbGUtaGNlbGwgaGFuZGxlLWNvbC1ycG9ydCBoaWRkZW4iIGRhdGEtc29ydD0icnBvcnQiPui/nOeoi+er
;r+WPozxzcGFuIGNsYXNzPSJoLXNvcnQiPjwvc3Bhbj48L2Rpdj4KICAgICAgICAgICAgICAgIDxkaXYgY2xhc3M9ImhhbmRsZS1oY2VsbCIgZGF0YS1zb3J0
;PSJ0eXBlIj7nsbvlnos8c3BhbiBjbGFzcz0iaC1zb3J0Ij48L3NwYW4+PC9kaXY+CiAgICAgICAgICAgICAgICA8ZGl2IGNsYXNzPSJoYW5kbGUtaGNlbGwi
;IGRhdGEtc29ydD0iaGFuZGxlIj7lj6Xmn4TlkI3np7A8c3BhbiBjbGFzcz0iaC1zb3J0Ij48L3NwYW4+PC9kaXY+CiAgICAgICAgICAgICAgPC9kaXY+CiAg
;ICAgICAgICAgICAgPGRpdiBjbGFzcz0iaGFuZGxlLWJvZHkiIGlkPSJoYW5kbGUtYm9keSI+CiAgICAgICAgICAgICAgICA8ZGl2IGNsYXNzPSJoYW5kbGUt
;ZW1wdHkiPuWPpeafhOaQnOe0ou+8mui+k+WFpeWFs+mUruWtl++8m+err+WPo+aQnOe0ou+8mjgwODB8ODAg5oiWIDAtMzAwfDUwMDwvZGl2PgogICAgICAg
;ICAgICAgIDwvZGl2PgogICAgICAgICAgICA8L2Rpdj4KICAgICAgICAgIDwvZGl2PgogICAgICAgICAgPGRpdiBpZD0iaW5mby1wYW5lbCIgY2xhc3M9Imhp
;ZGRlbiBuby1kcmFnIGVtYmVkZGVkIj48L2Rpdj4KICAgICAgICAgIDxkaXYgaWQ9ImNvbmZpZy1wYW5lbCIgY2xhc3M9ImhpZGRlbiBuby1kcmFnIGVtYmVk
;ZGVkIj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0iY2ZnLXRvcCI+CiAgICAgICAgICAgICAgPGRpdiBjbGFzcz0iY2ZnLXRhYnMiIHJvbGU9InRhYmxpc3Qi
;PgogICAgICAgICAgICAgICAgPGJ1dHRvbiB0eXBlPSJidXR0b24iIGNsYXNzPSJjZmctdGFiIG9uIiBkYXRhLWNmZz0icnVuY29uZmlnIj7ov5DooYzphY3n
;va48L2J1dHRvbj4KICAgICAgICAgICAgICAgIDxidXR0b24gdHlwZT0iYnV0dG9uIiBjbGFzcz0iY2ZnLXRhYiIgZGF0YS1jZmc9ImdldGNvbmZpZyI+5Y+W
;5YC86YWN572uPC9idXR0b24+CiAgICAgICAgICAgICAgICA8YnV0dG9uIHR5cGU9ImJ1dHRvbiIgY2xhc3M9ImNmZy10YWIiIGRhdGEtY2ZnPSJzeXNjb25m
;aWciPuezu+e7n+mFjee9rjwvYnV0dG9uPgogICAgICAgICAgICAgIDwvZGl2PgogICAgICAgICAgICAgIDxkaXYgY2xhc3M9ImNmZy10b29scyI+CiAgICAg
;ICAgICAgICAgICA8YnV0dG9uIHR5cGU9ImJ1dHRvbiIgaWQ9ImNmZy10b2dnbGUtYWxsIiBjbGFzcz0iY2ZnLWljby1idG4iIHRpdGxlPSLlhajpg6jlsZXl
;vIAiIGFyaWEtZXhwYW5kZWQ9ImZhbHNlIj4KICAgICAgICAgICAgICAgICAgPHN2ZyBjbGFzcz0iaWNvLWV4cGFuZCIgdmlld0JveD0iMCAwIDI0IDI0IiBm
;aWxsPSJub25lIiBzdHJva2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIxLjkiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIgc3Ryb2tlLWxpbmVqb2lu
;PSJyb3VuZCIgYXJpYS1oaWRkZW49InRydWUiPjxwYXRoIGQ9Ik03IDhsNSA1IDUtNSIvPjxwYXRoIGQ9Ik03IDEzbDUgNSA1LTUiLz48L3N2Zz4KICAgICAg
;ICAgICAgICAgICAgPHN2ZyBjbGFzcz0iaWNvLWNvbGxhcHNlIiB2aWV3Qm94PSIwIDAgMjQgMjQiIGZpbGw9Im5vbmUiIHN0cm9rZT0iY3VycmVudENvbG9y
;IiBzdHJva2Utd2lkdGg9IjEuOSIgc3Ryb2tlLWxpbmVjYXA9InJvdW5kIiBzdHJva2UtbGluZWpvaW49InJvdW5kIiBhcmlhLWhpZGRlbj0idHJ1ZSI+PHBh
;dGggZD0iTTcgMTZsNS01IDUgNSIvPjxwYXRoIGQ9Ik03IDExbDUtNSA1IDUiLz48L3N2Zz4KICAgICAgICAgICAgICAgIDwvYnV0dG9uPgogICAgICAgICAg
;ICAgICAgPGJ1dHRvbiB0eXBlPSJidXR0b24iIGlkPSJjZmctYWRkLWdyb3VwIiB0aXRsZT0i5re75Yqg57uEIj48c3BhbiBhcmlhLWhpZGRlbj0idHJ1ZSI+
;Kzwvc3Bhbj7mt7vliqDnu4Q8L2J1dHRvbj4KICAgICAgICAgICAgICAgIDxidXR0b24gdHlwZT0iYnV0dG9uIiBpZD0iY2ZnLXNhdmUiIGNsYXNzPSJwcmlt
;YXJ5Ij7kv53lrZg8L2J1dHRvbj4KICAgICAgICAgICAgICA8L2Rpdj4KICAgICAgICAgICAgPC9kaXY+CiAgICAgICAgICAgIDxkaXYgaWQ9ImNmZy1zdGF0
;dXMiPjwvZGl2PgogICAgICAgICAgICA8ZGl2IGlkPSJjZmctdGlwLXdyYXAiIGNsYXNzPSJoaWRkZW4iPgogICAgICAgICAgICAgIDxzcGFuIGNsYXNzPSJj
;ZmctdGlwLWljbyIgYXJpYS1oaWRkZW49InRydWUiIHRpdGxlPSLor7TmmI4iPgogICAgICAgICAgICAgICAgPHN2ZyB2aWV3Qm94PSIwIDAgMjQgMjQiIGZp
;bGw9Im5vbmUiIHN0cm9rZT0iY3VycmVudENvbG9yIiBzdHJva2Utd2lkdGg9IjEuNyIgc3Ryb2tlLWxpbmVjYXA9InJvdW5kIiBzdHJva2UtbGluZWpvaW49
;InJvdW5kIj48Y2lyY2xlIGN4PSIxMiIgY3k9IjEyIiByPSI5Ii8+PHBhdGggZD0iTTEyIDExdjZNMTIgOGguMDEiLz48L3N2Zz4KICAgICAgICAgICAgICA8
;L3NwYW4+CiAgICAgICAgICAgICAgPGRpdiBjbGFzcz0iY2ZnLXRpcC1ib2R5Ij4KICAgICAgICAgICAgICAgIDxkaXYgaWQ9ImNmZy10aXAiIHRpdGxlPSLl
;j4zlh7vnvJbovpEiPjwvZGl2PgogICAgICAgICAgICAgICAgPHRleHRhcmVhIGlkPSJjZmctdGlwLWVkaXQiIHNwZWxsY2hlY2s9ImZhbHNlIiBhcmlhLWxh
;YmVsPSLnvJbovpHmlofku7bor7TmmI4iPjwvdGV4dGFyZWE+CiAgICAgICAgICAgICAgPC9kaXY+CiAgICAgICAgICAgIDwvZGl2PgogICAgICAgICAgICA8
;ZGl2IGlkPSJjZmctYm9keSI+PC9kaXY+CiAgICAgICAgICA8L2Rpdj4KICAgICAgICA8L3NlY3Rpb24+CgogICAgICAgIDxzZWN0aW9uIGlkPSJwcmV2aWV3
;Ij4KICAgICAgICAgIDxkaXYgY2xhc3M9InB2LWJvZHkiIGlkPSJwdi1ib2R5Ij4KICAgICAgICAgICAgPGRpdiBjbGFzcz0icHYtbWVkaWEiIGlkPSJwdi1t
;ZWRpYSI+PGRpdiBjbGFzcz0icGgiPumihOiniOWMujwvZGl2PjwvZGl2PgogICAgICAgICAgICA8ZGl2IGNsYXNzPSJwdi10ZXh0IiBpZD0icHYtdGV4dCIg
;c3R5bGU9ImRpc3BsYXk6bm9uZSI+CiAgICAgICAgICAgICAgPGRpdiBjbGFzcz0iaGQiIGlkPSJwdi10ZXh0LWhkIj7pooTop4jliY0gMjBLQiDlhoXlrrk8
;L2Rpdj4KICAgICAgICAgICAgICA8cHJlIGlkPSJwdi1wcmUiPjwvcHJlPgogICAgICAgICAgICA8L2Rpdj4KICAgICAgICAgIDwvZGl2PgogICAgICAgICAg
;PGRpdiBjbGFzcz0icHYtb2ZmIj7lt7LlhbPpl63mlofku7bpooTop4g8L2Rpdj4KICAgICAgICA8L3NlY3Rpb24+CiAgICAgIDwvZGl2PgogICAgPC9kaXY+
;CgogICAgPGRpdiBpZD0iYmFyIj4KICAgICAgPGRpdiBjbGFzcz0iYmFyLWxlZnQiPgogICAgICAgIDxidXR0b24gaWQ9ImJ0bi1zZXR0aW5ncyIgdHlwZT0i
;YnV0dG9uIiB0aXRsZT0i6K6+572uIj7impk8L2J1dHRvbj4KICAgICAgPC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9ImJhci1tYWluIj4KICAgICAgICA8YnV0
;dG9uIGNsYXNzPSJzb3J0IiBpZD0iYnRuLXNvcnQiIHR5cGU9ImJ1dHRvbiIgdGl0bGU9IuWIh+aNouaOkuW6jyI+4oeFIDxzcGFuIGlkPSJzb3J0LWxhYmVs
;Ij7mjInkv67mlLnml7bpl7TpmY3luo88L3NwYW4+PC9idXR0b24+CiAgICAgICAgPGxhYmVsIGNsYXNzPSJ0b2dnbGUiIHRpdGxlPSLlvIDlkK8v5YWz6Zet
;5Y+z5L6n6aKE6KeIIj4KICAgICAgICAgIDxpbnB1dCB0eXBlPSJjaGVja2JveCIgaWQ9ImNoay1wcmV2aWV3IiBjaGVja2VkPgogICAgICAgICAgPHNwYW4g
;Y2xhc3M9InN3Ij48L3NwYW4+CiAgICAgICAgICA8c3Bhbj7lvIDlkK/mlofku7bpooTop4g8L3NwYW4+CiAgICAgICAgPC9sYWJlbD4KICAgICAgICA8ZGl2
;IGNsYXNzPSJzcGFjZXIiPjwvZGl2PgogICAgICAgIDxkaXYgaWQ9ImJhci1oYW5kbGUtYWN0aW9ucyIgY2xhc3M9Im5vLWRyYWciPgogICAgICAgICAgPHNw
;YW4gaWQ9ImhhbmRsZS1zdGF0dXMiPjwvc3Bhbj4KICAgICAgICAgIDxidXR0b24gaWQ9ImJ0bi1wb3J0LW1hcmsiIHR5cGU9ImJ1dHRvbiIgdGl0bGU9Iuag
;h+iusOerr+WPoyI+4pqZPC9idXR0b24+CiAgICAgICAgICA8ZGl2IGlkPSJwb3J0LW1hcmstcG9wIiBjbGFzcz0ibm8tZHJhZyI+CiAgICAgICAgICAgIDxk
;aXYgY2xhc3M9InBtcC1oZCI+5qCH6K6w56uv5Y+jPC9kaXY+CiAgICAgICAgICAgIDxkaXYgY2xhc3M9InBtcC1oaW50Ij7ljLnphY3nmoTmnKzmnLov6L+c
;56iL56uv5Y+j5Lya6auY5Lqu5pi+56S677yM5Y+v6Ieq6KGM5re75YqgPC9kaXY+CiAgICAgICAgICAgIDxkaXYgY2xhc3M9InBtcC10YWdzIiBpZD0icG9y
;dC1tYXJrLXRhZ3MiPjwvZGl2PgogICAgICAgICAgICA8ZGl2IGNsYXNzPSJwbXAtYWRkIj4KICAgICAgICAgICAgICA8aW5wdXQgaWQ9InBvcnQtbWFyay1p
;bnB1dCIgdHlwZT0idGV4dCIgaW5wdXRtb2RlPSJudW1lcmljIiBwbGFjZWhvbGRlcj0i56uv5Y+j5Y+377yM5aaCIDkwMDAiIGF1dG9jb21wbGV0ZT0ib2Zm
;IiBzcGVsbGNoZWNrPSJmYWxzZSI+CiAgICAgICAgICAgICAgPGJ1dHRvbiBpZD0icG9ydC1tYXJrLWFkZCIgdHlwZT0iYnV0dG9uIj7mt7vliqA8L2J1dHRv
;bj4KICAgICAgICAgICAgPC9kaXY+CiAgICAgICAgICAgIDxidXR0b24gaWQ9InBvcnQtbWFyay1yZXNldCIgdHlwZT0iYnV0dG9uIiBjbGFzcz0icG1wLXJl
;c2V0Ij7mgaLlpI3pu5jorqQ8L2J1dHRvbj4KICAgICAgICAgIDwvZGl2PgogICAgICAgIDwvZGl2PgogICAgICAgIDxkaXYgaWQ9ImJhci1pbmZvLWFjdGlv
;bnMiIGNsYXNzPSJuby1kcmFnIj4KICAgICAgICAgIDxidXR0b24gaWQ9ImJ0bi1pbmZvLXJlZnJlc2giIHR5cGU9ImJ1dHRvbiI+5Yi35pawPC9idXR0b24+
;CiAgICAgICAgICA8YnV0dG9uIGlkPSJidG4taW5mby1jb3B5IiB0eXBlPSJidXR0b24iPuWkjeWItjwvYnV0dG9uPgogICAgICAgIDwvZGl2PgogICAgICAg
;IDxkaXYgaWQ9ImJhci1jb25maWctYWN0aW9ucyIgY2xhc3M9Im5vLWRyYWciPgogICAgICAgICAgPHNwYW4gaWQ9ImNmZy1wYXRoLWxhYmVsIj48L3NwYW4+
;CiAgICAgICAgICA8YnV0dG9uIHR5cGU9ImJ1dHRvbiIgaWQ9ImNmZy1yZWxvYWQiIHRpdGxlPSLph43mlrDliqDovb0iPgogICAgICAgICAgICA8c3ZnIHZp
;ZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0cm9rZS13aWR0aD0iMS44IiBzdHJva2UtbGluZWNhcD0icm91
;bmQiIHN0cm9rZS1saW5lam9pbj0icm91bmQiIGFyaWEtaGlkZGVuPSJ0cnVlIj48cGF0aCBkPSJNMjAgMTJhOCA4IDAgMSAxLTIuMi01LjUiLz48cGF0aCBk
;PSJNMjAgNHY1aC01Ii8+PC9zdmc+CiAgICAgICAgICA8L2J1dHRvbj4KICAgICAgICA8L2Rpdj4KICAgICAgICA8ZGl2IGlkPSJjb3VudCI+5YWxIDAg5p2h
;57uT5p6cPC9kaXY+CiAgICAgIDwvZGl2PgogICAgPC9kaXY+CiAgICA8L2Rpdj4KCiAgICA8ZGl2IGlkPSJmaWx0ZXItc2V0dGluZ3MiIGNsYXNzPSJuby1k
;cmFnIiByb2xlPSJkaWFsb2ciIGFyaWEtbW9kYWw9InRydWUiIGFyaWEtbGFiZWw9Iuetm+mAieiuvue9riI+CiAgICAgIDxkaXYgY2xhc3M9ImZzLWNhcmQi
;PgogICAgICAgIDxkaXYgY2xhc3M9ImZzLWhkIj4KICAgICAgICAgIDxzcGFuPuetm+mAieadoeS7tjwvc3Bhbj4KICAgICAgICAgIDxidXR0b24gdHlwZT0i
;YnV0dG9uIiBpZD0iZnMtY2xvc2UiIHRpdGxlPSLlhbPpl60iPsOXPC9idXR0b24+CiAgICAgICAgPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0iZnMtYmQi
;PgogICAgICAgICAgPGRpdiBjbGFzcz0iZnMtaGludCI+5ZCv55So55qE6aG55Lya5Ye6546w5Zyo6aG26YOo77yb54K55Lit5ZCO5oqK5a+55bqU5q2j5YiZ
;5Yqg5YWl5pCc57Si77yIRXZlcnl0aGluZyA8Y29kZT5yZWdleDo8L2NvZGU+77yJ44CC5Y+v5o6S5bqP44CB56aB55So5oiW5Yig6Zmk77yb5Yig6Zmk5ZCO
;5Y+v55So44CM5oGi5aSN6buY6K6k44CN6L+Y5Y6f5YaF572u6aG544CCPC9kaXY+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJmcy1saXN0IiBpZD0iZnMtbGlz
;dCI+PC9kaXY+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJmcy1mb3JtIj4KICAgICAgICAgICAgPGRpdj4KICAgICAgICAgICAgICA8bGFiZWwgZm9yPSJmcy10
;aXRsZSI+5qCH6aKYPC9sYWJlbD4KICAgICAgICAgICAgICA8aW5wdXQgaWQ9ImZzLXRpdGxlIiB0eXBlPSJ0ZXh0IiBtYXhsZW5ndGg9IjI0IiBwbGFjZWhv
;bGRlcj0i5L6L5aaC77ya5LiN5ZCr5Li05pe25paH5Lu2IiBhdXRvY29tcGxldGU9Im9mZiI+CiAgICAgICAgICAgIDwvZGl2PgogICAgICAgICAgICA8ZGl2
;PgogICAgICAgICAgICAgIDxsYWJlbCBmb3I9ImZzLXJlZ2V4Ij7mraPliJnooajovr7lvI88L2xhYmVsPgogICAgICAgICAgICAgIDxpbnB1dCBpZD0iZnMt
;cmVnZXgiIHR5cGU9InRleHQiIG1heGxlbmd0aD0iMjAwIiBwbGFjZWhvbGRlcj0i5L6L5aaC77yaKD9pKVwudG1wJCIgYXV0b2NvbXBsZXRlPSJvZmYiIHNw
;ZWxsY2hlY2s9ImZhbHNlIj4KICAgICAgICAgICAgPC9kaXY+CiAgICAgICAgICAgIDxkaXYgY2xhc3M9ImZzLWFjdGlvbnMiPgogICAgICAgICAgICAgIDxi
;dXR0b24gdHlwZT0iYnV0dG9uIiBjbGFzcz0icHJpbWFyeSIgaWQ9ImZzLWFkZCI+5Yqg5YWl562b6YCJPC9idXR0b24+CiAgICAgICAgICAgIDwvZGl2Pgog
;ICAgICAgICAgPC9kaXY+CiAgICAgICAgPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0iZnMtZm9vdCI+CiAgICAgICAgICA8YnV0dG9uIHR5cGU9ImJ1dHRv
;biIgaWQ9ImZzLWV2LW9wdHMiPuaJk+W8gCBFdmVyeXRoaW5nIOmAiemhueKApjwvYnV0dG9uPgogICAgICAgICAgPGJ1dHRvbiB0eXBlPSJidXR0b24iIGlk
;PSJmcy1yZXNldCIgdGl0bGU9IuaBouWkjeWGhee9ruetm+mAieW5tua4heepuuiHquWumuS5iSI+5oGi5aSN6buY6K6kPC9idXR0b24+CiAgICAgICAgPC9k
;aXY+CiAgICAgIDwvZGl2PgogICAgPC9kaXY+CgogICAgICAgIDxkaXYgaWQ9InByb2MtbWVudSIgcm9sZT0ibWVudSI+CiAgICAgIDxidXR0b24gdHlwZT0i
;YnV0dG9uIiBkYXRhLXBhY3Q9InJldmVhbCI+PHNwYW4gY2xhc3M9ImMtaWNvIiBhcmlhLWhpZGRlbj0idHJ1ZSI+PHN2ZyB2aWV3Qm94PSIwIDAgMjQgMjQi
;IGZpbGw9Im5vbmUiIHN0cm9rZT0iY3VycmVudENvbG9yIiBzdHJva2Utd2lkdGg9IjEuOCI+PHBhdGggZD0iTTMgNy41QTEuNSAxLjUgMCAwIDEgNC41IDZI
;OWwyIDJoOC41QTEuNSAxLjUgMCAwIDEgMjEgOS41djdBMS41IDEuNSAwIDAgMSAxOS41IDE4aC0xNUExLjUgMS41IDAgMCAxIDMgMTYuNXYtOXoiLz48L3N2
;Zz48L3NwYW4+PHNwYW4gY2xhc3M9InBhY3QtbGFiZWwiPuaJk+W8gOi/m+eoi+aJgOWcqOS9jee9rjwvc3Bhbj48L2J1dHRvbj4KICAgICAgPGJ1dHRvbiB0
;eXBlPSJidXR0b24iIGRhdGEtcGFjdD0iY29weSI+PHNwYW4gY2xhc3M9ImMtaWNvIiBhcmlhLWhpZGRlbj0idHJ1ZSI+PHN2ZyB2aWV3Qm94PSIwIDAgMjQg
;MjQiIGZpbGw9Im5vbmUiIHN0cm9rZT0iY3VycmVudENvbG9yIiBzdHJva2Utd2lkdGg9IjEuOCI+PHJlY3QgeD0iOCIgeT0iOCIgd2lkdGg9IjExIiBoZWln
;aHQ9IjExIiByeD0iMS41Ii8+PHBhdGggZD0iTTUgMTVWNS41QTEuNSAxLjUgMCAwIDEgNi41IDRIMTUiLz48L3N2Zz48L3NwYW4+PHNwYW4gY2xhc3M9InBh
;Y3QtbGFiZWwiIGlkPSJwcm9jLW1lbnUtY29weSI+5aSN5Yi26L+b56iL5ZCNPC9zcGFuPjwvYnV0dG9uPgogICAgICA8YnV0dG9uIHR5cGU9ImJ1dHRvbiIg
;ZGF0YS1wYWN0PSJjb3B5UGlkIj48c3BhbiBjbGFzcz0iYy1pY28iIGFyaWEtaGlkZGVuPSJ0cnVlIj48c3ZnIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0i
;bm9uZSIgc3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0cm9rZS13aWR0aD0iMS44Ij48cGF0aCBkPSJNNyA3aDR2NEg3ek0xMyA3aDR2NGgtNHpNNyAxM2g0djRI
;N3pNMTMgMTNoNHY0aC00eiIvPjwvc3ZnPjwvc3Bhbj48c3BhbiBjbGFzcz0icGFjdC1sYWJlbCIgaWQ9InByb2MtbWVudS1jb3B5cGlkIj7lpI3liLbov5vn
;qIvlj7c8L3NwYW4+PC9idXR0b24+CiAgICAgIDxidXR0b24gdHlwZT0iYnV0dG9uIiBkYXRhLXBhY3Q9ImVuZCIgY2xhc3M9ImRhbmdlciIgaWQ9InByb2Mt
;bWVudS1lbmQiPjxzcGFuIGNsYXNzPSJjLWljbyIgYXJpYS1oaWRkZW49InRydWUiPjxzdmcgdmlld0JveD0iMCAwIDI0IDI0IiBmaWxsPSJub25lIiBzdHJv
;a2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIxLjgiPjxjaXJjbGUgY3g9IjEyIiBjeT0iMTIiIHI9IjguNSIvPjxwYXRoIGQ9Ik05IDlsNiA2TTE1
;IDlsLTYgNiIvPjwvc3ZnPjwvc3Bhbj48c3BhbiBjbGFzcz0icGFjdC1sYWJlbCIgaWQ9InByb2MtbWVudS1lbmQtbGFiZWwiPuWFs+mXrei/m+eoizwvc3Bh
;bj48L2J1dHRvbj4KICAgIDwvZGl2PgogICAgPGRhdGFsaXN0IGlkPSJoYW5kbGUtaGlzdC1saXN0Ij48L2RhdGFsaXN0Pgo8L2Rpdj4KCiAgICA8ZGl2IGlk
;PSJ1aS1kbGciIGFyaWEtaGlkZGVuPSJ0cnVlIj4KICAgICAgPGRpdiBjbGFzcz0idWktZGxnLW1hc2siIGRhdGEtdWktZGxnLWRpc21pc3M9IjEiPjwvZGl2
;PgogICAgICA8ZGl2IGNsYXNzPSJ1aS1kbGctY2FyZCIgcm9sZT0iZGlhbG9nIiBhcmlhLW1vZGFsPSJ0cnVlIiBhcmlhLWxhYmVsbGVkYnk9InVpLWRsZy10
;aXRsZSI+CiAgICAgICAgPGRpdiBjbGFzcz0idWktZGxnLXRpdGxlIiBpZD0idWktZGxnLXRpdGxlIj7mj5DnpLo8L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNz
;PSJ1aS1kbGctbXNnIiBpZD0idWktZGxnLW1zZyI+PC9kaXY+CiAgICAgICAgPGlucHV0IHR5cGU9InRleHQiIGNsYXNzPSJ1aS1kbGctaW5wdXQiIGlkPSJ1
;aS1kbGctaW5wdXQiIHNwZWxsY2hlY2s9ImZhbHNlIiBhdXRvY29tcGxldGU9Im9mZiI+CiAgICAgICAgPGRpdiBjbGFzcz0idWktZGxnLWFjdGlvbnMiPgog
;ICAgICAgICAgPGJ1dHRvbiB0eXBlPSJidXR0b24iIGlkPSJ1aS1kbGctY2FuY2VsIj7lj5bmtog8L2J1dHRvbj4KICAgICAgICAgIDxidXR0b24gdHlwZT0i
;YnV0dG9uIiBpZD0idWktZGxnLW9rIiBjbGFzcz0icHJpbWFyeSI+56Gu5a6aPC9idXR0b24+CiAgICAgICAgPC9kaXY+CiAgICAgIDwvZGl2PgogICAgPC9k
;aXY+CiAgICA8ZGl2IGlkPSJjZmctbWVudSIgcm9sZT0ibWVudSI+CiAgICAgIDxidXR0b24gdHlwZT0iYnV0dG9uIiBkYXRhLWNhY3Q9ImFkZCI+PHNwYW4g
;Y2xhc3M9ImMtaWNvIiBhcmlhLWhpZGRlbj0idHJ1ZSI+PHN2ZyB2aWV3Qm94PSIwIDAgMjQgMjQiIGZpbGw9Im5vbmUiIHN0cm9rZT0iY3VycmVudENvbG9y
;IiBzdHJva2Utd2lkdGg9IjEuOCIgc3Ryb2tlLWxpbmVjYXA9InJvdW5kIj48cGF0aCBkPSJNMTIgNXYxNE01IDEyaDE0Ii8+PC9zdmc+PC9zcGFuPjxzcGFu
;IGNsYXNzPSJjYWN0LWxhYmVsIj7mt7vliqDmnaHnm648L3NwYW4+PC9idXR0b24+CiAgICAgIDxidXR0b24gdHlwZT0iYnV0dG9uIiBkYXRhLWNhY3Q9InRv
;cCI+PHNwYW4gY2xhc3M9ImMtaWNvIiBhcmlhLWhpZGRlbj0idHJ1ZSI+PHN2ZyB2aWV3Qm94PSIwIDAgMjQgMjQiIGZpbGw9Im5vbmUiIHN0cm9rZT0iY3Vy
;cmVudENvbG9yIiBzdHJva2Utd2lkdGg9IjEuOCIgc3Ryb2tlLWxpbmVjYXA9InJvdW5kIiBzdHJva2UtbGluZWpvaW49InJvdW5kIj48cGF0aCBkPSJNMTIg
;MTlWN003IDExbDUtNSA1IDVNNSA1aDE0Ii8+PC9zdmc+PC9zcGFuPjxzcGFuIGNsYXNzPSJjYWN0LWxhYmVsIj7nva7pobY8L3NwYW4+PC9idXR0b24+CiAg
;ICAgIDxidXR0b24gdHlwZT0iYnV0dG9uIiBkYXRhLWNhY3Q9InVwIj48c3BhbiBjbGFzcz0iYy1pY28iIGFyaWEtaGlkZGVuPSJ0cnVlIj48c3ZnIHZpZXdC
;b3g9IjAgMCAyNCAyNCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0cm9rZS13aWR0aD0iMS44IiBzdHJva2UtbGluZWNhcD0icm91bmQi
;IHN0cm9rZS1saW5lam9pbj0icm91bmQiPjxwYXRoIGQ9Ik0xMiAxOVY2TTcgMTBsNS01IDUgNSIvPjwvc3ZnPjwvc3Bhbj48c3BhbiBjbGFzcz0iY2FjdC1s
;YWJlbCI+5LiK56e7PC9zcGFuPjwvYnV0dG9uPgogICAgICA8YnV0dG9uIHR5cGU9ImJ1dHRvbiIgZGF0YS1jYWN0PSJkb3duIj48c3BhbiBjbGFzcz0iYy1p
;Y28iIGFyaWEtaGlkZGVuPSJ0cnVlIj48c3ZnIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0cm9rZS13
;aWR0aD0iMS44IiBzdHJva2UtbGluZWNhcD0icm91bmQiIHN0cm9rZS1saW5lam9pbj0icm91bmQiPjxwYXRoIGQ9Ik0xMiA1djEzTTcgMTRsNSA1IDUtNSIv
;Pjwvc3ZnPjwvc3Bhbj48c3BhbiBjbGFzcz0iY2FjdC1sYWJlbCI+5LiL56e7PC9zcGFuPjwvYnV0dG9uPgogICAgICA8aHI+CiAgICAgIDxidXR0b24gdHlw
;ZT0iYnV0dG9uIiBkYXRhLWNhY3Q9ImRlbCIgY2xhc3M9ImRhbmdlciI+PHNwYW4gY2xhc3M9ImMtaWNvIiBhcmlhLWhpZGRlbj0idHJ1ZSI+PHN2ZyB2aWV3
;Qm94PSIwIDAgMjQgMjQiIGZpbGw9Im5vbmUiIHN0cm9rZT0iY3VycmVudENvbG9yIiBzdHJva2Utd2lkdGg9IjEuOCIgc3Ryb2tlLWxpbmVjYXA9InJvdW5k
;IiBzdHJva2UtbGluZWpvaW49InJvdW5kIj48cGF0aCBkPSJNNSA4aDE0Ii8+PHBhdGggZD0iTTkgOFY2LjVBMS41IDEuNSAwIDAgMSAxMC41IDVoM0ExLjUg
;MS41IDAgMCAxIDE1IDYuNVY4Ii8+PHBhdGggZD0iTTcuNSA4bC43IDExYTEuNSAxLjUgMCAwIDAgMS41IDEuNGg0LjZhMS41IDEuNSAwIDAgMCAxLjUtMS40
;bC43LTExIi8+PC9zdmc+PC9zcGFuPjxzcGFuIGNsYXNzPSJjYWN0LWxhYmVsIj7liKDpmaQ8L3NwYW4+PC9idXR0b24+CiAgICA8L2Rpdj4KICA8ZGl2IGlk
;PSJjdHgiIHJvbGU9Im1lbnUiPgogICAgPGJ1dHRvbiB0eXBlPSJidXR0b24iIGRhdGEtYWN0PSJyZXZlYWwiPjxzcGFuIGNsYXNzPSJjLWljbyI+PHN2ZyB2
;aWV3Qm94PSIwIDAgMjQgMjQiIGZpbGw9Im5vbmUiIHN0cm9rZT0iY3VycmVudENvbG9yIiBzdHJva2Utd2lkdGg9IjEuOCI+PHBhdGggZD0iTTMgNy41QTEu
;NSAxLjUgMCAwIDEgNC41IDZIOWwyIDJoOC41QTEuNSAxLjUgMCAwIDEgMjEgOS41djdBMS41IDEuNSAwIDAgMSAxOS41IDE4aC0xNUExLjUgMS41IDAgMCAx
;IDMgMTYuNXYtOXoiLz48L3N2Zz48L3NwYW4+5paH5Lu25aS55Lit5pi+56S6PC9idXR0b24+CiAgICA8YnV0dG9uIHR5cGU9ImJ1dHRvbiIgZGF0YS1hY3Q9
;ImNvcHkiPjxzcGFuIGNsYXNzPSJjLWljbyI+PHN2ZyB2aWV3Qm94PSIwIDAgMjQgMjQiIGZpbGw9Im5vbmUiIHN0cm9rZT0iY3VycmVudENvbG9yIiBzdHJv
;a2Utd2lkdGg9IjEuOCI+PHJlY3QgeD0iOCIgeT0iOCIgd2lkdGg9IjExIiBoZWlnaHQ9IjExIiByeD0iMS41Ii8+PHBhdGggZD0iTTUgMTVWNS41QTEuNSAx
;LjUgMCAwIDEgNi41IDRIMTUiLz48L3N2Zz48L3NwYW4+5aSN5Yi2PC9idXR0b24+CiAgICA8YnV0dG9uIHR5cGU9ImJ1dHRvbiIgZGF0YS1hY3Q9ImNvcHlQ
;YXRoIj48c3BhbiBjbGFzcz0iYy1pY28iPjxzdmcgdmlld0JveD0iMCAwIDI0IDI0IiBmaWxsPSJub25lIiBzdHJva2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tl
;LXdpZHRoPSIxLjgiPjxwYXRoIGQ9Ik04IDEyaDgiLz48cGF0aCBkPSJNMTAgN0g3LjVBMi41IDIuNSAwIDAgMCA1IDkuNXY1QTIuNSAyLjUgMCAwIDAgNy41
;IDE3SDEwIi8+PHBhdGggZD0iTTE0IDdoMi41QTIuNSAyLjUgMCAwIDEgMTkgOS41djVBMi41IDIuNSAwIDAgMSAxNi41IDE3SDE0Ii8+PC9zdmc+PC9zcGFu
;PuWkjeWItui3r+W+hDwvYnV0dG9uPgogICAgPGJ1dHRvbiB0eXBlPSJidXR0b24iIGRhdGEtYWN0PSJjb3B5RGlyIj48c3BhbiBjbGFzcz0iYy1pY28iPjxz
;dmcgdmlld0JveD0iMCAwIDI0IDI0IiBmaWxsPSJub25lIiBzdHJva2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIxLjgiPjxwYXRoIGQ9Ik05IDgu
;NWEzLjUgMy41IDAgMCAxIDUuNi0yLjhsMS43IDEuNGEzLjUgMy41IDAgMCAxLTIuMiA2LjJIMTMiLz48cGF0aCBkPSJNMTUgMTUuNWEzLjUgMy41IDAgMCAx
;LTUuNiAyLjhsLTEuNy0xLjRhMy41IDMuNSAwIDAgMSAyLjItNi4ySDExIi8+PC9zdmc+PC9zcGFuPuWkjeWItuaJgOWcqOi3r+W+hDwvYnV0dG9uPgogICAg
;PGJ1dHRvbiB0eXBlPSJidXR0b24iIGRhdGEtYWN0PSJyZWN5Y2xlIiBjbGFzcz0iZGFuZ2VyIj48c3BhbiBjbGFzcz0iYy1pY28iPjxzdmcgdmlld0JveD0i
;MCAwIDI0IDI0IiBmaWxsPSJub25lIiBzdHJva2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIxLjgiPjxwYXRoIGQ9Ik01IDhoMTQiLz48cGF0aCBk
;PSJNOSA4VjYuNUExLjUgMS41IDAgMCAxIDEwLjUgNWgzQTEuNSAxLjUgMCAwIDEgMTUgNi41VjgiLz48cGF0aCBkPSJNNy41IDhsLjcgMTFhMS41IDEuNSAw
;IDAgMCAxLjUgMS40aDQuNmExLjUgMS41IDAgMCAwIDEuNS0xLjRsLjctMTEiLz48L3N2Zz48L3NwYW4+5Yig6ZmkKOWbnuaUtuermSk8L2J1dHRvbj4KICA8
;L2Rpdj4KPC9kaXY+CjxzY3JpcHQ+CigoKSA9PiB7CiAgLy8g5YWo5bGA5bGP6JS95rWP6KeI5Zmo6buY6K6k5Y+z6ZSu6I+c5Y2V77yb6aG16Z2i5YaF6Ieq
;5a6a5LmJ6I+c5Y2V6Ieq6KGMIHByZXZlbnREZWZhdWx0IOWQjuW8ueWHugogIGRvY3VtZW50LmFkZEV2ZW50TGlzdGVuZXIoJ2NvbnRleHRtZW51JywgKGUp
;ID0+IHsgZS5wcmV2ZW50RGVmYXVsdCgpOyB9LCB0cnVlKTsKICBjb25zdCBib290ID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2Jvb3QnKTsKICBjb25z
;dCBjaHJvbWUgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnY2hyb21lJyk7CiAgY29uc3QgYXBwUm9vdCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdh
;cHAnKTsKICBjb25zdCB0aXRsZWJhciA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd0aXRsZWJhcicpOwogIGNvbnN0IHJpbmdGZyA9IGRvY3VtZW50Lmdl
;dEVsZW1lbnRCeUlkKCdyaW5nLWZnJyk7CiAgY29uc3QgYm9vdFBjdCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdib290LXBjdCcpOwogIGNvbnN0IHFF
;bCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdxJyk7CiAgY29uc3QgbGlzdEVsID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2xpc3QnKTsKICBjb25z
;dCBlbXB0eUVsID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2xpc3QtZW1wdHknKTsKICBjb25zdCBjb3VudEVsID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5
;SWQoJ2NvdW50Jyk7CiAgY29uc3QgcHZNZXRhID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3B2LW1ldGEnKTsKICBjb25zdCBwdk1lZGlhID0gZG9jdW1l
;bnQuZ2V0RWxlbWVudEJ5SWQoJ3B2LW1lZGlhJyk7CiAgY29uc3QgcHZUZXh0ID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3B2LXRleHQnKTsKICBjb25z
;dCBwdkJvZHkgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgncHYtYm9keScpOwogIGNvbnN0IHB2UHJlID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3B2
;LXByZScpOwogIGNvbnN0IHB2VGV4dEhkID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3B2LXRleHQtaGQnKTsKICBjb25zdCBwcmV2aWV3ID0gZG9jdW1l
;bnQuZ2V0RWxlbWVudEJ5SWQoJ3ByZXZpZXcnKTsKICBjb25zdCBjaGtQcmV2aWV3ID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2Noay1wcmV2aWV3Jyk7
;CiAgY29uc3Qgc29ydExhYmVsID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NvcnQtbGFiZWwnKTsKICBjb25zdCBDSVJDID0gMiAqIE1hdGguUEkgKiA1
;MjsKCiAgbGV0IGNhdCA9ICdhbGwnOwogIGxldCBhcHBNb2RlID0gJ2ZpbGUnOyAvLyBmaWxlIHwgaGFuZGxlIHwgaW5mbyB8IGNvbmZpZwogIGNvbnN0IFBM
;QUNFSE9MREVSX0ZJTEUgPSAn6L6T5YWl5paH5Lu25ZCNIC8g5omp5bGV5ZCNIC8g6Lev5b6E5YWz6ZSu5a2X77ybfCDooajnpLrkuJTvvIx8fCDooajnpLrm
;iJYnOwogIGNvbnN0IFBMQUNFSE9MREVSX0hBTkRMRSA9ICfmlofku7blj6Xmn4TlhbPplK7lrZfvvIzmiJbnq6/lj6MgODA4MHw4MOOAgTAtMzAwfDUwMCc7
;CiAgY29uc3QgUExBQ0VIT0xERVJfSU5GTyA9ICfmnKzmnLrkv6Hmga/ml6DpnIDlhbPplK7lrZfvvIzngrnlt6bkvqfljbPlj6/mn6XnnIsnOwogIGNvbnN0
;IFBMQUNFSE9MREVSX0NPTkZJRyA9ICfov5DooYzphY3nva7vvJrlj6/mkJzntKIga2V5IC8gdmFsdWUnOwogIC8vIOacrOWcsOaQnOe0oiAvIOWPpeafhOaQ
;nOe0ouWQhOiHquS/neeVmei+k+WFpeadoeS7tu+8jOS6kuS4jeS4suWPsAogIGNvbnN0IG1vZGVRdWVyeSA9IHsgZmlsZTogJycsIGhhbmRsZTogJycsIGlu
;Zm86ICcnLCBjb25maWc6ICcnIH07CiAgbGV0IGNmZ0FjdGl2ZVRhYiA9ICdydW5jb25maWcnOwogIGxldCBzb3J0ID0gJ2RhdGUtZGVzYyc7CiAgbGV0IGRy
;aXZlID0gJyc7IC8vICcnID0gYWxsIGRpc2tzLCAnQycgLyAnRCcgLyAuLi4KICBsZXQgaXRlbXMgPSBbXTsKICBsZXQgc2VsZWN0ZWQgPSAtMTsKICBsZXQg
;cHJldmlld09uID0gdHJ1ZTsKICBsZXQgc2VhcmNoVGltZXIgPSAwOwogIGxldCBnZW4gPSAwOwogIGxldCB0b3RhbEhpdHMgPSAwOwogIGxldCBsb2FkaW5n
;TW9yZSA9IGZhbHNlOwogIGxldCBoYXNNb3JlID0gZmFsc2U7CgogIGNvbnN0IGRyaXZlTGFiZWwgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnZHJpdmUt
;bGFiZWwnKTsKICBjb25zdCBkcml2ZU1lbnUgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnZHJpdmUtbWVudScpOwogIGNvbnN0IGJ0bkRyaXZlID0gZG9j
;dW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2J0bi1kcml2ZScpOwogIGNvbnN0IGRyaXZlQnRuSWNvID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2RyaXZlLWJ0
;bi1pY28nKTsKICBsZXQgZHJpdmVNZXRhID0geyBjb21wdXRlcjogJycsIGRyaXZlczogW10gfTsKCiAgZnVuY3Rpb24gZHJpdmVUZXh0KCkgewogICAgaWYg
;KCFkcml2ZSkgcmV0dXJuICflhajnm5jmkJzntKInOwogICAgY29uc3QgaGl0ID0gKGRyaXZlTWV0YS5kcml2ZXMgfHwgW10pLmZpbmQoZCA9PiBTdHJpbmco
;ZC5sZXR0ZXIgfHwgJycpLnRvVXBwZXJDYXNlKCkgPT09IGRyaXZlKTsKICAgIGlmIChoaXQgJiYgaGl0LmxhYmVsKSByZXR1cm4gaGl0LmxhYmVsOwogICAg
;cmV0dXJuIGRyaXZlLnRvVXBwZXJDYXNlKCkgKyAnIOebmCc7CiAgfQogIGZ1bmN0aW9uIHNldEJ0bkljb24odXJsKSB7CiAgICBpZiAodXJsKSB7CiAgICAg
;IGRyaXZlQnRuSWNvLnNyYyA9IHVybCArICh1cmwuaW5jbHVkZXMoJz8nKSA/ICcmJyA6ICc/JykgKyAndD0nICsgRGF0ZS5ub3coKTsKICAgICAgZHJpdmVC
;dG5JY28uY2xhc3NMaXN0LnJlbW92ZSgnaGlkZGVuJyk7CiAgICB9IGVsc2UgewogICAgICBkcml2ZUJ0bkljby5yZW1vdmVBdHRyaWJ1dGUoJ3NyYycpOwog
;ICAgICBkcml2ZUJ0bkljby5jbGFzc0xpc3QuYWRkKCdoaWRkZW4nKTsKICAgIH0KICB9CiAgZnVuY3Rpb24gc3luY0RyaXZlQnV0dG9uKCkgewogICAgZHJp
;dmVMYWJlbC50ZXh0Q29udGVudCA9IGRyaXZlVGV4dCgpOwogICAgaWYgKCFkcml2ZSkgc2V0QnRuSWNvbihkcml2ZU1ldGEuY29tcHV0ZXIgfHwgJycpOwog
;ICAgZWxzZSB7CiAgICAgIGNvbnN0IGhpdCA9IChkcml2ZU1ldGEuZHJpdmVzIHx8IFtdKS5maW5kKGQgPT4gU3RyaW5nKGQubGV0dGVyIHx8ICcnKS50b1Vw
;cGVyQ2FzZSgpID09PSBkcml2ZSk7CiAgICAgIHNldEJ0bkljb24oKGhpdCAmJiBoaXQuaWNvbikgfHwgZHJpdmVNZXRhLmNvbXB1dGVyIHx8ICcnKTsKICAg
;IH0KICB9CiAgZnVuY3Rpb24gaWNvSHRtbCh1cmwpIHsKICAgIHJldHVybiB1cmwgPyAnPGltZyBzcmM9IicgKyBTdHJpbmcodXJsKS5yZXBsYWNlKC8iL2cs
;ICcnKSArICciIGFsdD0iIj4nIDogJyc7CiAgfQogIGZ1bmN0aW9uIHJlbmRlckRyaXZlTWVudSgpIHsKICAgIGNvbnN0IGRyaXZlcyA9IEFycmF5LmlzQXJy
;YXkoZHJpdmVNZXRhLmRyaXZlcykgPyBkcml2ZU1ldGEuZHJpdmVzIDogW107CiAgICBsZXQgaHRtbCA9ICc8YnV0dG9uIHR5cGU9ImJ1dHRvbiIgZGF0YS1k
;cml2ZT0iIicgKyAoIWRyaXZlID8gJyBjbGFzcz0ib24iJyA6ICcnKSArICc+JwogICAgICArIGljb0h0bWwoZHJpdmVNZXRhLmNvbXB1dGVyKSArICc8c3Bh
;bj7lhajnm5jmkJzntKI8L3NwYW4+PC9idXR0b24+JzsKICAgIGZvciAoY29uc3QgZCBvZiBkcml2ZXMpIHsKICAgICAgY29uc3QgbGV0dGVyID0gU3RyaW5n
;KGQubGV0dGVyIHx8IGQgfHwgJycpLnJlcGxhY2UoLzokLywgJycpLnRvVXBwZXJDYXNlKCk7CiAgICAgIGlmICghbGV0dGVyKSBjb250aW51ZTsKICAgICAg
;Y29uc3QgbGFiZWwgPSBkLmxhYmVsIHx8IChsZXR0ZXIgKyAnIOebmCcpOwogICAgICBodG1sICs9ICc8YnV0dG9uIHR5cGU9ImJ1dHRvbiIgZGF0YS1kcml2
;ZT0iJyArIGxldHRlciArICciJwogICAgICAgICsgKGRyaXZlID09PSBsZXR0ZXIgPyAnIGNsYXNzPSJvbiInIDogJycpICsgJz4nCiAgICAgICAgKyBpY29I
;dG1sKGQuaWNvbiB8fCAnJykgKyAnPHNwYW4+JyArIGxhYmVsICsgJzwvc3Bhbj48L2J1dHRvbj4nOwogICAgfQogICAgZHJpdmVNZW51LmlubmVySFRNTCA9
;IGh0bWw7CiAgICBkcml2ZU1lbnUucXVlcnlTZWxlY3RvckFsbCgnYnV0dG9uJykuZm9yRWFjaChidG4gPT4gewogICAgICBidG4ub25jbGljayA9IChlKSA9
;PiB7CiAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICBkcml2ZSA9IGJ0bi5nZXRBdHRyaWJ1dGUoJ2RhdGEtZHJpdmUnKSB8fCAnJzsKICAg
;ICAgICBkcml2ZU1lbnUuY2xhc3NMaXN0LnJlbW92ZSgnb24nKTsKICAgICAgICBzeW5jRHJpdmVCdXR0b24oKTsKICAgICAgICByZW5kZXJEcml2ZU1lbnUo
;KTsKICAgICAgICBkb1NlYXJjaCgpOwogICAgICAgIGlmICh0eXBlb2Ygc2F2ZVNlc3Npb25Tb29uID09PSAnZnVuY3Rpb24nKSBzYXZlU2Vzc2lvblNvb24o
;KTsKICAgICAgfTsKICAgIH0pOwogIH0KICB3aW5kb3cuX19zZXREcml2ZXMgPSAocGF5bG9hZCkgPT4gewogICAgdHJ5IHsKICAgICAgY29uc3QgZGF0YSA9
;IHR5cGVvZiBwYXlsb2FkID09PSAnc3RyaW5nJyA/IEpTT04ucGFyc2UocGF5bG9hZCkgOiBwYXlsb2FkOwogICAgICBpZiAoQXJyYXkuaXNBcnJheShkYXRh
;KSkgewogICAgICAgIGRyaXZlTWV0YSA9IHsKICAgICAgICAgIGNvbXB1dGVyOiAnJywKICAgICAgICAgIGRyaXZlczogZGF0YS5tYXAoeCA9PiB0eXBlb2Yg
;eCA9PT0gJ3N0cmluZycKICAgICAgICAgICAgPyAoeyBsZXR0ZXI6IHgsIGljb246ICcnLCBsYWJlbDogU3RyaW5nKHgpLnRvVXBwZXJDYXNlKCkgKyAnIOeb
;mCcgfSkKICAgICAgICAgICAgOiB4KQogICAgICAgIH07CiAgICAgIH0gZWxzZSB7CiAgICAgICAgZHJpdmVNZXRhID0gewogICAgICAgICAgY29tcHV0ZXI6
;IChkYXRhICYmIGRhdGEuY29tcHV0ZXIpIHx8ICcnLAogICAgICAgICAgZHJpdmVzOiBBcnJheS5pc0FycmF5KGRhdGEgJiYgZGF0YS5kcml2ZXMpID8gZGF0
;YS5kcml2ZXMgOiBbXQogICAgICAgIH07CiAgICAgIH0KICAgICAgc3luY0RyaXZlQnV0dG9uKCk7CiAgICAgIHJlbmRlckRyaXZlTWVudSgpOwogICAgfSBj
;YXRjaCAoZSkgeyBjb25zb2xlLndhcm4oJ3NldERyaXZlcycsIGUpOyB9CiAgfTsKCiAgY29uc3QgSElTVF9LRVkgPSAnbG9jYWxfc2VhcmNoX2hpc3RfdjEn
;OwogIGNvbnN0IENPTkZJR19ISVNUX0tFWSA9ICdsb2NhbF9zZWFyY2hfY29uZmlnX2hpc3RfdjEnOwogIGNvbnN0IEhJU1RfTUFYID0gMTA7CiAgY29uc3Qg
;c2VhcmNoQm94ID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NlYXJjaC1ib3gnKTsKICBjb25zdCBoaXN0TWVudSA9IGRvY3VtZW50LmdldEVsZW1lbnRC
;eUlkKCdoaXN0LW1lbnUnKTsKICBjb25zdCBidG5IaXN0ID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2J0bi1oaXN0Jyk7CiAgY29uc3QgYnRuQ2xlYXIg
;PSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYnRuLWNsZWFyJyk7CiAgY29uc3Qgc2VhcmNoSWNvID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NlYXJj
;aC1pY28nKTsKICBsZXQgaGlzdElkbGVUaW1lciA9IDA7CgogIGZ1bmN0aW9uIHNldEhpc3RDaHJvbWUob24pIHsKICAgIHNlYXJjaEJveC5jbGFzc0xpc3Qu
;dG9nZ2xlKCdoaXN0LW9wZW4nLCAhIW9uKTsKICAgIGhpc3RNZW51LmNsYXNzTGlzdC50b2dnbGUoJ29uJywgISFvbik7CiAgICBpZiAoc2VhcmNoSWNvKSBz
;ZWFyY2hJY28uY2xhc3NMaXN0LnRvZ2dsZSgnb24nLCAhIW9uKTsKICAgIGlmIChidG5IaXN0KSBidG5IaXN0LmNsYXNzTGlzdC50b2dnbGUoJ29uJywgISFv
;bik7CiAgfQoKICBmdW5jdGlvbiBzeW5jQ2xlYXJCdG4oKSB7CiAgICBidG5DbGVhci5jbGFzc0xpc3QudG9nZ2xlKCdvbicsICEhKHFFbC52YWx1ZSB8fCAn
;JykudHJpbSgpKTsKICAgIGlmICh0eXBlb2Ygc3luY0ZpbGVTZWFyY2hDbGVhclBpbGwgPT09ICdmdW5jdGlvbicpIHN5bmNGaWxlU2VhcmNoQ2xlYXJQaWxs
;KCk7CiAgfQogIGZ1bmN0aW9uIGNsZWFyU2VhcmNoKCkgewogICAgY2xlYXJUaW1lb3V0KGhpc3RJZGxlVGltZXIpOwogICAgcUVsLnZhbHVlID0gJyc7CiAg
;ICBpZiAoYXBwTW9kZSA9PT0gJ2ZpbGUnKSBtb2RlUXVlcnkuZmlsZSA9ICcnOwogICAgZWxzZSBpZiAoYXBwTW9kZSA9PT0gJ2hhbmRsZScpIG1vZGVRdWVy
;eS5oYW5kbGUgPSAnJzsKICAgIGVsc2UgaWYgKGFwcE1vZGUgPT09ICdpbmZvJykgbW9kZVF1ZXJ5LmluZm8gPSAnJzsKICAgIGVsc2UgaWYgKGFwcE1vZGUg
;PT09ICdjb25maWcnKSBtb2RlUXVlcnkuY29uZmlnID0gJyc7CiAgICBzeW5jQ2xlYXJCdG4oKTsKICAgIHNldEhpc3RDaHJvbWUoZmFsc2UpOwogICAgcUVs
;LmZvY3VzKCk7CiAgICBpZiAoYXBwTW9kZSA9PT0gJ2hhbmRsZScpIHsKICAgICAgLy8g5riF56m65p2h5Lu25ZCO5LuN5pi+56S65YWo6YOo6L+e5o6l77yI
;5LiN5oqKIDAtNjU1MzUg5YaZ5Zue6L6T5YWl5qGG77yJCiAgICAgIHJlcXVlc3RIYW5kbGVTZWFyY2goJycpOwogICAgICByZXR1cm47CiAgICB9CiAgICBp
;ZiAoYXBwTW9kZSA9PT0gJ2luZm8nKSByZXR1cm47CiAgICBpZiAoYXBwTW9kZSA9PT0gJ2NvbmZpZycpIHsKICAgICAgaWYgKHR5cGVvZiBjbGVhckNmZ1Nl
;YXJjaCA9PT0gJ2Z1bmN0aW9uJykgY2xlYXJDZmdTZWFyY2goKTsKICAgICAgZWxzZSBpZiAodHlwZW9mIGFwcGx5Q29uZmlnU2VhcmNoID09PSAnZnVuY3Rp
;b24nKSBhcHBseUNvbmZpZ1NlYXJjaCgnJyk7CiAgICAgIHJldHVybjsKICAgIH0KICAgIGRvU2VhcmNoKCk7CiAgfQogIGJ0bkNsZWFyLm9uY2xpY2sgPSAo
;ZSkgPT4gewogICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgIGNsZWFyU2VhcmNoKCk7CiAgfTsKICBjb25zdCBzZWFyY2hDbGVhclBpbGwgPSBkb2N1bWVu
;dC5nZXRFbGVtZW50QnlJZCgnY2ZnLXNlYXJjaC1jbGVhcicpOwogIGlmIChzZWFyY2hDbGVhclBpbGwgJiYgIXNlYXJjaENsZWFyUGlsbC5kYXRhc2V0LmJv
;dW5kKSB7CiAgICBzZWFyY2hDbGVhclBpbGwuZGF0YXNldC5ib3VuZCA9ICcxJzsKICAgIHNlYXJjaENsZWFyUGlsbC5hZGRFdmVudExpc3RlbmVyKCdjbGlj
;aycsIChlKSA9PiB7CiAgICAgIGUucHJldmVudERlZmF1bHQoKTsKICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgaWYgKGFwcE1vZGUgPT09ICdj
;b25maWcnKSB7CiAgICAgICAgaWYgKHR5cGVvZiBjbGVhckNmZ1NlYXJjaCA9PT0gJ2Z1bmN0aW9uJykgY2xlYXJDZmdTZWFyY2goKTsKICAgICAgfSBlbHNl
;IGlmIChhcHBNb2RlID09PSAnZmlsZScpIHsKICAgICAgICBjbGVhckZpbGVTZWFyY2hBbGwoKTsKICAgICAgfQogICAgICB0cnkgeyBxRWwuZm9jdXMoKTsg
;fSBjYXRjaCAoXykge30KICAgIH0pOwogIH0KCiAgZnVuY3Rpb24gbG9hZEhpc3QoKSB7CiAgICB0cnkgewogICAgICBjb25zdCBrZXkgPSAodHlwZW9mIGFw
;cE1vZGUgIT09ICd1bmRlZmluZWQnICYmIGFwcE1vZGUgPT09ICdjb25maWcnKSA/IENPTkZJR19ISVNUX0tFWSA6IEhJU1RfS0VZOwogICAgICBjb25zdCBy
;YXcgPSBsb2NhbFN0b3JhZ2UuZ2V0SXRlbShrZXkpOwogICAgICBjb25zdCBhcnIgPSByYXcgPyBKU09OLnBhcnNlKHJhdykgOiBbXTsKICAgICAgcmV0dXJu
;IEFycmF5LmlzQXJyYXkoYXJyKSA/IGFyci5tYXAoeCA9PiBTdHJpbmcoeCB8fCAnJykudHJpbSgpKS5maWx0ZXIoQm9vbGVhbikuc2xpY2UoMCwgSElTVF9N
;QVgpIDogW107CiAgICB9IGNhdGNoIChfKSB7IHJldHVybiBbXTsgfQogIH0KICBmdW5jdGlvbiBzYXZlSGlzdChsaXN0KSB7CiAgICB0cnkgewogICAgICBj
;b25zdCBrZXkgPSAodHlwZW9mIGFwcE1vZGUgIT09ICd1bmRlZmluZWQnICYmIGFwcE1vZGUgPT09ICdjb25maWcnKSA/IENPTkZJR19ISVNUX0tFWSA6IEhJ
;U1RfS0VZOwogICAgICBsb2NhbFN0b3JhZ2Uuc2V0SXRlbShrZXksIEpTT04uc3RyaW5naWZ5KGxpc3Quc2xpY2UoMCwgSElTVF9NQVgpKSk7CiAgICB9IGNh
;dGNoIChfKSB7fQogIH0KICBmdW5jdGlvbiBwdXNoSGlzdChxKSB7CiAgICBxID0gU3RyaW5nKHEgfHwgJycpLnRyaW0oKTsKICAgIGlmICghcSkgcmV0dXJu
;OwogICAgaWYgKHR5cGVvZiBhcHBNb2RlICE9PSAndW5kZWZpbmVkJyAmJiBhcHBNb2RlID09PSAnaW5mbycpIHJldHVybjsKICAgIGlmICh0eXBlb2YgYXBw
;TW9kZSAhPT0gJ3VuZGVmaW5lZCcgJiYgYXBwTW9kZSA9PT0gJ2hhbmRsZScpIHsKICAgICAgaWYgKHR5cGVvZiBzYXZlSGFuZGxlSGlzdCA9PT0gJ2Z1bmN0
;aW9uJykgc2F2ZUhhbmRsZUhpc3QocSk7CiAgICAgIGlmIChoaXN0TWVudS5jbGFzc0xpc3QuY29udGFpbnMoJ29uJykpIHJlbmRlckhpc3RNZW51KCk7CiAg
;ICAgIHJldHVybjsKICAgIH0KICAgIGNvbnN0IGxpc3QgPSBsb2FkSGlzdCgpLmZpbHRlcih4ID0+IHggIT09IHEpOwogICAgbGlzdC51bnNoaWZ0KHEpOwog
;ICAgc2F2ZUhpc3QobGlzdCk7CiAgICBpZiAoaGlzdE1lbnUuY2xhc3NMaXN0LmNvbnRhaW5zKCdvbicpKSByZW5kZXJIaXN0TWVudSgpOwogIH0KICBmdW5j
;dGlvbiBlc2NhcGVBdHRyKHMpIHsKICAgIHJldHVybiBTdHJpbmcocyB8fCAnJykucmVwbGFjZSgvJi9nLCAnJmFtcDsnKS5yZXBsYWNlKC8iL2csICcmcXVv
;dDsnKS5yZXBsYWNlKC88L2csICcmbHQ7Jyk7CiAgfQogIGNvbnN0IEhJU1RfSUNPX1NWRyA9ICc8c3ZnIGNsYXNzPSJoaXN0LWljbyIgdmlld0JveD0iMCAw
;IDE2IDE2IiBmaWxsPSJub25lIiBhcmlhLWhpZGRlbj0idHJ1ZSI+JwogICAgKyAnPGNpcmNsZSBjeD0iNyIgY3k9IjciIHI9IjQuMjUiIHN0cm9rZT0iY3Vy
;cmVudENvbG9yIiBzdHJva2Utd2lkdGg9IjEuNCIvPicKICAgICsgJzxwYXRoIGQ9Ik0xMC4yIDEwLjJMMTMuNCAxMy40IiBzdHJva2U9ImN1cnJlbnRDb2xv
;ciIgc3Ryb2tlLXdpZHRoPSIxLjQiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIvPicKICAgICsgJzwvc3ZnPic7CiAgZnVuY3Rpb24gcmVuZGVySGlzdE1lbnUo
;KSB7CiAgICBjb25zdCBoYW5kbGVNb2RlID0gdHlwZW9mIGFwcE1vZGUgIT09ICd1bmRlZmluZWQnICYmIGFwcE1vZGUgPT09ICdoYW5kbGUnOwogICAgY29u
;c3QgY29uZmlnTW9kZSA9IHR5cGVvZiBhcHBNb2RlICE9PSAndW5kZWZpbmVkJyAmJiBhcHBNb2RlID09PSAnY29uZmlnJzsKICAgIGNvbnN0IGxpc3QgPSBo
;YW5kbGVNb2RlICYmIHR5cGVvZiBsb2FkSGFuZGxlSGlzdCA9PT0gJ2Z1bmN0aW9uJyA/IGxvYWRIYW5kbGVIaXN0KCkgOiBsb2FkSGlzdCgpOwogICAgaWYg
;KCFsaXN0Lmxlbmd0aCkgewogICAgICBjb25zdCBlbXB0eSA9IGhhbmRsZU1vZGUgPyAn5pqC5peg5Y+l5p+EL+err+WPo+aQnOe0ouiusOW9lScKICAgICAg
;ICA6IChjb25maWdNb2RlID8gJ+aaguaXoOmFjee9ruaQnOe0ouiusOW9lScgOiAn5pqC5peg5pyA6L+R5pCc57SiJyk7CiAgICAgIGhpc3RNZW51LmlubmVy
;SFRNTCA9ICc8ZGl2IGNsYXNzPSJoaXN0LWVtcHR5Ij4nICsgZW1wdHkgKyAnPC9kaXY+JzsKICAgICAgcmV0dXJuOwogICAgfQogICAgaGlzdE1lbnUuaW5u
;ZXJIVE1MID0gbGlzdC5tYXAocSA9PgogICAgICAnPGJ1dHRvbiB0eXBlPSJidXR0b24iIGRhdGEtcT0iJyArIGVzY2FwZUF0dHIocSkgKyAnIiB0aXRsZT0i
;JyArIGVzY2FwZUF0dHIocSkgKyAnIj4nCiAgICAgICsgSElTVF9JQ09fU1ZHICsgJzxzcGFuIGNsYXNzPSJoaXN0LXR4dCI+JyArIGVzY2FwZUF0dHIocSkg
;KyAnPC9zcGFuPjwvYnV0dG9uPicKICAgICkuam9pbignJyk7CiAgICBoaXN0TWVudS5xdWVyeVNlbGVjdG9yQWxsKCdidXR0b24nKS5mb3JFYWNoKGJ0biA9
;PiB7CiAgICAgIGJ0bi5vbmNsaWNrID0gKGUpID0+IHsKICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgICAgIGNvbnN0IHEgPSBidG4uZ2V0QXR0
;cmlidXRlKCdkYXRhLXEnKSB8fCAnJzsKICAgICAgICBjbG9zZUhpc3RNZW51KCk7CiAgICAgICAgcUVsLnZhbHVlID0gcTsKICAgICAgICBpZiAoYXBwTW9k
;ZSA9PT0gJ2ZpbGUnKSBtb2RlUXVlcnkuZmlsZSA9IHE7CiAgICAgICAgZWxzZSBpZiAoYXBwTW9kZSA9PT0gJ2hhbmRsZScpIG1vZGVRdWVyeS5oYW5kbGUg
;PSBxOwogICAgICAgIGVsc2UgaWYgKGFwcE1vZGUgPT09ICdjb25maWcnKSBtb2RlUXVlcnkuY29uZmlnID0gcTsKICAgICAgICBwdXNoSGlzdChxKTsKICAg
;ICAgICBzeW5jQ2xlYXJCdG4oKTsKICAgICAgICBpZiAoYXBwTW9kZSA9PT0gJ2NvbmZpZycpIHsKICAgICAgICAgIGlmICh0eXBlb2YgYXBwbHlDb25maWdT
;ZWFyY2ggPT09ICdmdW5jdGlvbicpIGFwcGx5Q29uZmlnU2VhcmNoKHEpOwogICAgICAgIH0gZWxzZSB7CiAgICAgICAgICBkb1NlYXJjaCgpOwogICAgICAg
;IH0KICAgICAgfTsKICAgIH0pOwogIH0KICBidG5Ecml2ZS5vbmNsaWNrID0gKGUpID0+IHsKICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICBjbG9zZUhp
;c3RNZW51KCk7CiAgICBkcml2ZU1lbnUuY2xhc3NMaXN0LnRvZ2dsZSgnb24nKTsKICB9OwogIGZ1bmN0aW9uIGNsb3NlSGlzdE1lbnUoKSB7CiAgICBzZXRI
;aXN0Q2hyb21lKGZhbHNlKTsKICB9CiAgZnVuY3Rpb24gb3Blbkhpc3RNZW51KCkgewogICAgaWYgKGFwcE1vZGUgPT09ICdpbmZvJykgcmV0dXJuOwogICAg
;ZHJpdmVNZW51LmNsYXNzTGlzdC5yZW1vdmUoJ29uJyk7CiAgICByZW5kZXJIaXN0TWVudSgpOwogICAgc2V0SGlzdENocm9tZSh0cnVlKTsKICB9CiAgZnVu
;Y3Rpb24gdG9nZ2xlSGlzdE1lbnUoZSkgewogICAgaWYgKGUpIGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICBpZiAoYXBwTW9kZSA9PT0gJ2luZm8nKSByZXR1
;cm47CiAgICBpZiAoaGlzdE1lbnUuY2xhc3NMaXN0LmNvbnRhaW5zKCdvbicpKSBjbG9zZUhpc3RNZW51KCk7CiAgICBlbHNlIG9wZW5IaXN0TWVudSgpOwog
;IH0KICBpZiAoc2VhcmNoSWNvKSBzZWFyY2hJY28uYWRkRXZlbnRMaXN0ZW5lcignY2xpY2snLCB0b2dnbGVIaXN0TWVudSk7CiAgaWYgKGJ0bkhpc3QpIGJ0
;bkhpc3Qub25jbGljayA9IHRvZ2dsZUhpc3RNZW51OwogIGhpc3RNZW51LmFkZEV2ZW50TGlzdGVuZXIoJ2NsaWNrJywgZSA9PiBlLnN0b3BQcm9wYWdhdGlv
;bigpKTsKICBkb2N1bWVudC5hZGRFdmVudExpc3RlbmVyKCdjbGljaycsICgpID0+IHsKICAgIGRyaXZlTWVudS5jbGFzc0xpc3QucmVtb3ZlKCdvbicpOwog
;ICAgY2xvc2VIaXN0TWVudSgpOwogICAgaGlkZUN0eCgpOwogIH0pOwogIHJlbmRlckRyaXZlTWVudSgpOwogIHJlbmRlckhpc3RNZW51KCk7CiAgc3luY0Ns
;ZWFyQnRuKCk7CgogIC8vIFByaW1hcnkgVUnihpJBSEsgY2hhbm5lbDogaW4tcGFnZSBxdWV1ZSBkcmFpbmVkIGJ5IEFISyBFeGVjdXRlU2NyaXB0LgogIC8v
;IE5ldmVyIHVzZSBob3N0T2JqZWN0cy5zeW5jIOKAlCBpdCBkZWFkbG9ja3MgV2ViVmlldzIgYW5kIGJsb2NrcyBwb3N0TWVzc2FnZSB0b28uCiAgd2luZG93
;Ll9fYWhrUSA9IHdpbmRvdy5fX2Foa1EgfHwgW107CiAgZnVuY3Rpb24gZW5xdWV1ZShtc2cpIHsKICAgIHRyeSB7CiAgICAgIHdpbmRvdy5fX2Foa1EucHVz
;aChTdHJpbmcobXNnKSk7CiAgICAgIC8vIFRpcCBBSEsgcG9sbGVyIHZpYSB0aXRsZSBjaGFuZ2UgKG9wdGlvbmFsIGZhc3QgcGF0aCkKICAgICAgdHJ5IHsg
;ZG9jdW1lbnQuZG9jdW1lbnRFbGVtZW50LmRhdGFzZXQuYWhrUGVuZGluZyA9IFN0cmluZyh3aW5kb3cuX19haGtRLmxlbmd0aCk7IH0gY2F0Y2ggKF8pIHt9
;CiAgICB9IGNhdGNoIChlKSB7IGNvbnNvbGUud2FybignZW5xdWV1ZScsIGUpOyB9CiAgfQogIGZ1bmN0aW9uIHBvc3QobXNnKSB7CiAgICBlbnF1ZXVlKG1z
;Zyk7CiAgICB0cnkgewogICAgICBpZiAod2luZG93LmNocm9tZSAmJiBjaHJvbWUud2VidmlldyAmJiB0eXBlb2YgY2hyb21lLndlYnZpZXcucG9zdE1lc3Nh
;Z2UgPT09ICdmdW5jdGlvbicpIHsKICAgICAgICBjaHJvbWUud2Vidmlldy5wb3N0TWVzc2FnZShTdHJpbmcobXNnKSk7CiAgICAgICAgcmV0dXJuIHRydWU7
;CiAgICAgIH0KICAgIH0gY2F0Y2ggKGUpIHsgY29uc29sZS53YXJuKCdwb3N0JywgZSk7IH0KICAgIHJldHVybiBmYWxzZTsKICB9CiAgZnVuY3Rpb24gY2Fs
;bEhvc3QobWV0aG9kLCAuLi5hcmdzKSB7CiAgICBsZXQgbXNnID0gJyc7CiAgICBpZiAobWV0aG9kID09PSAnc2VhcmNoJykgewogICAgICBjb25zdCBbcSwg
;Yywgcywgb2Zmc2V0XSA9IGFyZ3M7CiAgICAgIG1zZyA9ICdzZWFyY2h8JyArIEpTT04uc3RyaW5naWZ5KHsKICAgICAgICBxOiBxIHx8ICcnLCBjYXQ6IGMg
;fHwgJ2FsbCcsIHNvcnQ6IHMgfHwgJ2RhdGUtZGVzYycsCiAgICAgICAgZHJpdmU6IGRyaXZlIHx8ICcnLAogICAgICAgIG9mZnNldDogTnVtYmVyKG9mZnNl
;dCkgfHwgMCwgZ2VuOiArK2dlbgogICAgICB9KTsKICAgIH0gZWxzZSBpZiAobWV0aG9kID09PSAncHJldmlldycpIHsKICAgICAgbXNnID0gJ3ByZXZpZXd8
;JyArIChhcmdzWzBdIHx8ICcnKTsKICAgIH0gZWxzZSBpZiAobWV0aG9kID09PSAnb3BlbicpIHsKICAgICAgbXNnID0gJ29wZW58JyArIChhcmdzWzBdIHx8
;ICcnKTsKICAgIH0gZWxzZSBpZiAobWV0aG9kID09PSAncmV2ZWFsJykgewogICAgICBtc2cgPSAncmV2ZWFsfCcgKyAoYXJnc1swXSB8fCAnJyk7CiAgICB9
;IGVsc2UgaWYgKG1ldGhvZCA9PT0gJ2NvcHlGaWxlJykgewogICAgICBtc2cgPSAnY29weUZpbGV8JyArIChhcmdzWzBdIHx8ICcnKTsKICAgIH0gZWxzZSBp
;ZiAobWV0aG9kID09PSAnY29weVBhdGgnKSB7CiAgICAgIG1zZyA9ICdjb3B5UGF0aHwnICsgKGFyZ3NbMF0gfHwgJycpOwogICAgfSBlbHNlIGlmIChtZXRo
;b2QgPT09ICdjb3B5RGlyJykgewogICAgICBtc2cgPSAnY29weURpcnwnICsgKGFyZ3NbMF0gfHwgJycpOwogICAgfSBlbHNlIGlmIChtZXRob2QgPT09ICdy
;ZWN5Y2xlJykgewogICAgICBtc2cgPSAncmVjeWNsZXwnICsgKGFyZ3NbMF0gfHwgJycpOwogICAgfSBlbHNlIGlmIChtZXRob2QgPT09ICdjbG9zZScgfHwg
;bWV0aG9kID09PSAnbWluaW1pemUnIHx8IG1ldGhvZCA9PT0gJ21heGltaXplJyB8fCBtZXRob2QgPT09ICdkcmFnJykgewogICAgICBtc2cgPSBtZXRob2Q7
;CiAgICB9IGVsc2UgewogICAgICBtc2cgPSBtZXRob2QgKyAnfCcgKyBhcmdzLm1hcChhID0+IFN0cmluZyhhID8/ICcnKSkuam9pbignfCcpOwogICAgfQog
;ICAgcG9zdChtc2cpOwogIH0KCiAgZnVuY3Rpb24gc2V0Qm9vdFBjdChwKSB7CiAgICBwID0gTWF0aC5tYXgoMCwgTWF0aC5taW4oMTAwLCBOdW1iZXIocCkg
;fHwgMCkpOwogICAgYm9vdFBjdC50ZXh0Q29udGVudCA9IE1hdGgucm91bmQocCkgKyAnJSc7CiAgICByaW5nRmcuc3R5bGUuc3Ryb2tlRGFzaGFycmF5ID0g
;U3RyaW5nKENJUkMpOwogICAgcmluZ0ZnLnN0eWxlLnN0cm9rZURhc2hvZmZzZXQgPSBTdHJpbmcoQ0lSQyAqICgxIC0gcCAvIDEwMCkpOwogIH0KCiAgbGV0
;IGJvb3RDbWRTZXEgPSAwOwogIHdpbmRvdy5fX3NldEJvb3QgPSAob24sIHBjdCwgc2VxKSA9PiB7CiAgICAvLyDlv73nlaXkubHluo/ov5/liLDnmoQgQUhL
;IEV4ZWN1dGVTY3JpcHRBc3luY++8jOmBv+WFjeS4u+eVjOmdoumXquWbnui/m+W6puadoQogICAgaWYgKHNlcSAhPSBudWxsICYmIHNlcSAhPT0gJycgJiYg
;IU51bWJlci5pc05hTihOdW1iZXIoc2VxKSkpIHsKICAgICAgc2VxID0gTnVtYmVyKHNlcSk7CiAgICAgIGlmIChzZXEgPCBib290Q21kU2VxKSByZXR1cm47
;CiAgICAgIGJvb3RDbWRTZXEgPSBzZXE7CiAgICB9CiAgICBpZiAob24pIHsKICAgICAgYm9vdC5jbGFzc0xpc3QuYWRkKCdvbicpOwogICAgICBjaHJvbWUu
;Y2xhc3NMaXN0LmFkZCgnaGlkZGVuJyk7CiAgICAgIGlmIChhcHBSb290KSBhcHBSb290LmNsYXNzTGlzdC5hZGQoJ2Jvb3RpbmcnKTsKICAgICAgc2V0Qm9v
;dFBjdChwY3QpOwogICAgfSBlbHNlIHsKICAgICAgYm9vdC5jbGFzc0xpc3QucmVtb3ZlKCdvbicpOwogICAgICBjaHJvbWUuY2xhc3NMaXN0LnJlbW92ZSgn
;aGlkZGVuJyk7CiAgICAgIGlmIChhcHBSb290KSBhcHBSb290LmNsYXNzTGlzdC5yZW1vdmUoJ2Jvb3RpbmcnKTsKICAgICAgdHJ5IHsKICAgICAgICBpZiAo
;dHlwZW9mIGFwcE1vZGUgPT09ICd1bmRlZmluZWQnIHx8IGFwcE1vZGUgPT09ICdmaWxlJykKICAgICAgICAgIHNldFRpbWVvdXQoKCkgPT4geyB0cnkgeyBk
;b1NlYXJjaCgpOyB9IGNhdGNoIChfKSB7fSB9LCA2MCk7CiAgICAgIH0gY2F0Y2ggKF8pIHt9CiAgICB9CiAgfTsKICB3aW5kb3cuX19zZXRJbmRleFByb2dy
;ZXNzID0gKHBjdCkgPT4gc2V0Qm9vdFBjdChwY3QpOwoKICB3aW5kb3cuX19zZXRDYXRJY29ucyA9IChwYXlsb2FkKSA9PiB7CiAgICB0cnkgewogICAgICBj
;b25zdCBtYXAgPSB0eXBlb2YgcGF5bG9hZCA9PT0gJ3N0cmluZycgPyBKU09OLnBhcnNlKHBheWxvYWQpIDogcGF5bG9hZDsKICAgICAgaWYgKCFtYXAgfHwg
;dHlwZW9mIG1hcCAhPT0gJ29iamVjdCcpIHJldHVybjsKICAgICAgZG9jdW1lbnQucXVlcnlTZWxlY3RvckFsbCgnLmNhdCcpLmZvckVhY2goYnRuID0+IHsK
;ICAgICAgICBjb25zdCBrZXkgPSBidG4uZ2V0QXR0cmlidXRlKCdkYXRhLWNhdCcpOwogICAgICAgIGNvbnN0IHVybCA9IG1hcFtrZXldOwogICAgICAgIGlm
;ICghdXJsKSByZXR1cm47CiAgICAgICAgbGV0IGltZyA9IGJ0bi5xdWVyeVNlbGVjdG9yKCdpbWcuaWNvJyk7CiAgICAgICAgaWYgKCFpbWcpIHsKICAgICAg
;ICAgIGNvbnN0IG9sZCA9IGJ0bi5xdWVyeVNlbGVjdG9yKCcuaWNvLCBbZGF0YS1jYXQtaWNvXScpOwogICAgICAgICAgaW1nID0gZG9jdW1lbnQuY3JlYXRl
;RWxlbWVudCgnaW1nJyk7CiAgICAgICAgICBpbWcuY2xhc3NOYW1lID0gJ2ljbyc7CiAgICAgICAgICBpbWcuYWx0ID0gJyc7CiAgICAgICAgICBpZiAob2xk
;KSBvbGQucmVwbGFjZVdpdGgoaW1nKTsKICAgICAgICAgIGVsc2UgYnRuLmluc2VydEJlZm9yZShpbWcsIGJ0bi5maXJzdENoaWxkKTsKICAgICAgICB9CiAg
;ICAgICAgaW1nLnNyYyA9IHVybCArICh1cmwuaW5jbHVkZXMoJz8nKSA/ICcmJyA6ICc/JykgKyAndD0nICsgRGF0ZS5ub3coKTsKICAgICAgfSk7CiAgICB9
;IGNhdGNoIChlKSB7IGNvbnNvbGUud2Fybignc2V0Q2F0SWNvbnMnLCBlKTsgfQogIH07CgogIGZ1bmN0aW9uIGV4dE9mKG5hbWUpIHsKICAgIGNvbnN0IGkg
;PSBTdHJpbmcobmFtZSB8fCAnJykubGFzdEluZGV4T2YoJy4nKTsKICAgIHJldHVybiBpID4gMCA/IG5hbWUuc2xpY2UoaSArIDEpLnRvTG93ZXJDYXNlKCkg
;OiAnJzsKICB9CiAgZnVuY3Rpb24gaWNvbkh0bWwoaXQpIHsKICAgIGlmIChpdC5pY29uKSB7CiAgICAgIHJldHVybiAnPGltZyBzcmM9IicgKyBlc2NhcGVI
;dG1sKGl0Lmljb24pICsgJyIgYWx0PSIiIGxvYWRpbmc9ImxhenkiIGRlY29kaW5nPSJhc3luYyIgb25lcnJvcj0idGhpcy5vdXRlckhUTUw9XCc8c3BhbiBj
;bGFzcz1maS1mYWxsYmFjaz7wn5OEPC9zcGFuPlwnIj4nOwogICAgfQogICAgaWYgKGl0LmlzRGlyKSByZXR1cm4gJzxzcGFuIGNsYXNzPSJmaS1mYWxsYmFj
;ayI+8J+TgTwvc3Bhbj4nOwogICAgcmV0dXJuICc8c3BhbiBjbGFzcz0iZmktZmFsbGJhY2siPvCfk4Q8L3NwYW4+JzsKICB9CiAgZnVuY3Rpb24gaGlnaGxp
;Z2h0SHRtbCh0ZXh0KSB7CiAgICBjb25zdCByYXcgPSBTdHJpbmcodGV4dCA/PyAnJyk7CiAgICBsZXQgaHRtbCA9IGVzY2FwZUh0bWwocmF3KTsKICAgIGNv
;bnN0IHEgPSAocUVsLnZhbHVlIHx8ICcnKS50cmltKCk7CiAgICBpZiAoIXEpIHJldHVybiBodG1sOwogICAgY29uc3QgdGVybXMgPSBxLnNwbGl0KC9cfFx8
;fFx8LykuZmxhdE1hcChzID0+IHMuc3BsaXQoL1xzKy8pKS5tYXAodCA9PiB0LnRyaW0oKSkuZmlsdGVyKEJvb2xlYW4pOwogICAgLy8gbG9uZ2VyIHRlcm1z
;IGZpcnN0IHRvIGF2b2lkIHBhcnRpYWwgb3ZlcmxhcCBpc3N1ZXMKICAgIHRlcm1zLnNvcnQoKGEsIGIpID0+IGIubGVuZ3RoIC0gYS5sZW5ndGgpOwogICAg
;Zm9yIChjb25zdCB0IG9mIHRlcm1zKSB7CiAgICAgIGlmICghdCkgY29udGludWU7CiAgICAgIGNvbnN0IHJlID0gbmV3IFJlZ0V4cCh0LnJlcGxhY2UoL1su
;Kis/XiR7fSgpfFtcXVxcXS9nLCAnXFwkJicpLCAnZ2knKTsKICAgICAgaHRtbCA9IGh0bWwucmVwbGFjZShyZSwgbSA9PiAnPG1hcms+JyArIG0gKyAnPC9t
;YXJrPicpOwogICAgfQogICAgcmV0dXJuIGh0bWw7CiAgfQogIGZ1bmN0aW9uIHByZXR0eU5hbWUobmFtZSkgewogICAgbmFtZSA9IFN0cmluZyhuYW1lIHx8
;ICcnKTsKICAgIGlmICghbmFtZSkgcmV0dXJuICcnOwogICAgY29uc3QgZSA9IGV4dE9mKG5hbWUpOwogICAgaWYgKCFlIHx8IG5hbWUuc3RhcnRzV2l0aCgn
;LicpKSByZXR1cm4gaGlnaGxpZ2h0SHRtbChuYW1lKTsKICAgIGNvbnN0IGJhc2UgPSBuYW1lLnNsaWNlKDAsIC0oZS5sZW5ndGggKyAxKSk7CiAgICByZXR1
;cm4gaGlnaGxpZ2h0SHRtbChiYXNlKSArICc8c3BhbiBjbGFzcz0iZXh0Ij4uJyArIGVzY2FwZUh0bWwoZSkgKyAnPC9zcGFuPic7CiAgfQogIGZ1bmN0aW9u
;IGRpc3BsYXlOYW1lKGl0KSB7CiAgICBsZXQgbiA9IFN0cmluZyhpdC5uYW1lIHx8ICcnKS50cmltKCk7CiAgICBpZiAobikgcmV0dXJuIG47CiAgICAvLyBm
;YWxsYmFjazogbGFzdCBzZWdtZW50IG9mIHBhdGgKICAgIGNvbnN0IHAgPSBTdHJpbmcoaXQucGF0aCB8fCAnJykucmVwbGFjZSgvW1xcL10rJC8sICcnKTsK
;ICAgIGNvbnN0IGkgPSBNYXRoLm1heChwLmxhc3RJbmRleE9mKCdcXCcpLCBwLmxhc3RJbmRleE9mKCcvJykpOwogICAgcmV0dXJuIGkgPj0gMCA/IHAuc2xp
;Y2UoaSArIDEpIDogcDsKICB9CiAgZnVuY3Rpb24gZXNjYXBlSHRtbChzKSB7CiAgICByZXR1cm4gU3RyaW5nKHMgPz8gJycpLnJlcGxhY2UoLyYvZywnJmFt
;cDsnKS5yZXBsYWNlKC88L2csJyZsdDsnKS5yZXBsYWNlKC8+L2csJyZndDsnKS5yZXBsYWNlKC8iL2csJyZxdW90OycpOwogIH0KICBsZXQgdWlEbGdSZXNv
;bHZlciA9IG51bGw7CiAgZnVuY3Rpb24gY2xvc2VVaURpYWxvZyhyZXN1bHQpIHsKICAgIGNvbnN0IGRsZyA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd1
;aS1kbGcnKTsKICAgIGlmIChkbGcpIHsKICAgICAgZGxnLmNsYXNzTGlzdC5yZW1vdmUoJ29uJyk7CiAgICAgIGRsZy5zZXRBdHRyaWJ1dGUoJ2FyaWEtaGlk
;ZGVuJywgJ3RydWUnKTsKICAgIH0KICAgIGNvbnN0IHIgPSB1aURsZ1Jlc29sdmVyOwogICAgdWlEbGdSZXNvbHZlciA9IG51bGw7CiAgICBpZiAocikgcihy
;ZXN1bHQpOwogIH0KICBmdW5jdGlvbiBzaG93VWlEaWFsb2cob3B0cykgewogICAgb3B0cyA9IG9wdHMgfHwge307CiAgICBjb25zdCBkbGcgPSBkb2N1bWVu
;dC5nZXRFbGVtZW50QnlJZCgndWktZGxnJyk7CiAgICBjb25zdCB0aXRsZUVsID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3VpLWRsZy10aXRsZScpOwog
;ICAgY29uc3QgbXNnRWwgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgndWktZGxnLW1zZycpOwogICAgY29uc3QgaW5wdXRFbCA9IGRvY3VtZW50LmdldEVs
;ZW1lbnRCeUlkKCd1aS1kbGctaW5wdXQnKTsKICAgIGNvbnN0IG9rQnRuID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3VpLWRsZy1vaycpOwogICAgY29u
;c3QgY2FuY2VsQnRuID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3VpLWRsZy1jYW5jZWwnKTsKICAgIGlmICghZGxnIHx8ICFva0J0biB8fCAhY2FuY2Vs
;QnRuKSByZXR1cm4gUHJvbWlzZS5yZXNvbHZlKG9wdHMuaW5wdXQgPyBudWxsIDogZmFsc2UpOwogICAgaWYgKHVpRGxnUmVzb2x2ZXIpIGNsb3NlVWlEaWFs
;b2cob3B0cy5pbnB1dCA/IG51bGwgOiBmYWxzZSk7CiAgICB0aXRsZUVsLnRleHRDb250ZW50ID0gb3B0cy50aXRsZSB8fCAob3B0cy5pbnB1dCA/ICfovpPl
;haUnIDogJ+ehruiupCcpOwogICAgbXNnRWwudGV4dENvbnRlbnQgPSBvcHRzLm1lc3NhZ2UgfHwgJyc7CiAgICBtc2dFbC5zdHlsZS5kaXNwbGF5ID0gb3B0
;cy5tZXNzYWdlID8gJycgOiAnbm9uZSc7CiAgICBjb25zdCB3YW50SW5wdXQgPSAhIW9wdHMuaW5wdXQ7CiAgICBpbnB1dEVsLmNsYXNzTGlzdC50b2dnbGUo
;J29uJywgd2FudElucHV0KTsKICAgIGlucHV0RWwudmFsdWUgPSB3YW50SW5wdXQgPyBTdHJpbmcob3B0cy5kZWZhdWx0VmFsdWUgPz8gJycpIDogJyc7CiAg
;ICBjYW5jZWxCdG4uc3R5bGUuZGlzcGxheSA9IG9wdHMuaGlkZUNhbmNlbCA/ICdub25lJyA6ICcnOwogICAgY2FuY2VsQnRuLnRleHRDb250ZW50ID0gb3B0
;cy5jYW5jZWxUZXh0IHx8ICflj5bmtognOwogICAgb2tCdG4udGV4dENvbnRlbnQgPSBvcHRzLm9rVGV4dCB8fCAn56Gu5a6aJzsKICAgIG9rQnRuLmNsYXNz
;TmFtZSA9IG9wdHMuZGFuZ2VyID8gJ2RhbmdlcicgOiAncHJpbWFyeSc7CiAgICByZXR1cm4gbmV3IFByb21pc2UoKHJlc29sdmUpID0+IHsKICAgICAgdWlE
;bGdSZXNvbHZlciA9IHJlc29sdmU7CiAgICAgIGRsZy5jbGFzc0xpc3QuYWRkKCdvbicpOwogICAgICBkbGcuc2V0QXR0cmlidXRlKCdhcmlhLWhpZGRlbics
;ICdmYWxzZScpOwogICAgICBjb25zdCBmaW5pc2hPayA9ICgpID0+IHsKICAgICAgICBpZiAod2FudElucHV0KSBjbG9zZVVpRGlhbG9nKGlucHV0RWwudmFs
;dWUpOwogICAgICAgIGVsc2UgY2xvc2VVaURpYWxvZyh0cnVlKTsKICAgICAgfTsKICAgICAgb2tCdG4ub25jbGljayA9IGZpbmlzaE9rOwogICAgICBjYW5j
;ZWxCdG4ub25jbGljayA9ICgpID0+IGNsb3NlVWlEaWFsb2cod2FudElucHV0ID8gbnVsbCA6IGZhbHNlKTsKICAgICAgZGxnLnF1ZXJ5U2VsZWN0b3IoJy51
;aS1kbGctbWFzaycpLm9uY2xpY2sgPSAoKSA9PiBjbG9zZVVpRGlhbG9nKHdhbnRJbnB1dCA/IG51bGwgOiBmYWxzZSk7CiAgICAgIGlucHV0RWwub25rZXlk
;b3duID0gKGUpID0+IHsKICAgICAgICBpZiAoZS5rZXkgPT09ICdFbnRlcicpIHsgZS5wcmV2ZW50RGVmYXVsdCgpOyBmaW5pc2hPaygpOyB9CiAgICAgICAg
;ZWxzZSBpZiAoZS5rZXkgPT09ICdFc2NhcGUnKSB7IGUucHJldmVudERlZmF1bHQoKTsgY2xvc2VVaURpYWxvZyhudWxsKTsgfQogICAgICB9OwogICAgICBk
;bGcub25rZXlkb3duID0gKGUpID0+IHsKICAgICAgICBpZiAoZS5rZXkgPT09ICdFc2NhcGUnKSB7IGUucHJldmVudERlZmF1bHQoKTsgY2xvc2VVaURpYWxv
;Zyh3YW50SW5wdXQgPyBudWxsIDogZmFsc2UpOyB9CiAgICAgIH07CiAgICAgIHNldFRpbWVvdXQoKCkgPT4gewogICAgICAgIHRyeSB7CiAgICAgICAgICBp
;ZiAod2FudElucHV0KSB7IGlucHV0RWwuZm9jdXMoKTsgaW5wdXRFbC5zZWxlY3QoKTsgfQogICAgICAgICAgZWxzZSBva0J0bi5mb2N1cygpOwogICAgICAg
;IH0gY2F0Y2ggKF8pIHt9CiAgICAgIH0sIDMwKTsKICAgIH0pOwogIH0KICBmdW5jdGlvbiB1aUNvbmZpcm0obWVzc2FnZSwgb3B0cykgewogICAgb3B0cyA9
;IG9wdHMgfHwge307CiAgICByZXR1cm4gc2hvd1VpRGlhbG9nKHsKICAgICAgdGl0bGU6IG9wdHMudGl0bGUgfHwgJ+ehruiupCcsCiAgICAgIG1lc3NhZ2Us
;CiAgICAgIG9rVGV4dDogb3B0cy5va1RleHQgfHwgJ+ehruWumicsCiAgICAgIGNhbmNlbFRleHQ6IG9wdHMuY2FuY2VsVGV4dCB8fCAn5Y+W5raIJywKICAg
;ICAgZGFuZ2VyOiAhIW9wdHMuZGFuZ2VyCiAgICB9KTsKICB9CiAgZnVuY3Rpb24gdWlQcm9tcHQobWVzc2FnZSwgZGVmYXVsdFZhbHVlLCBvcHRzKSB7CiAg
;ICBvcHRzID0gb3B0cyB8fCB7fTsKICAgIHJldHVybiBzaG93VWlEaWFsb2coewogICAgICB0aXRsZTogb3B0cy50aXRsZSB8fCAn6L6T5YWlJywKICAgICAg
;bWVzc2FnZSwKICAgICAgaW5wdXQ6IHRydWUsCiAgICAgIGRlZmF1bHRWYWx1ZTogZGVmYXVsdFZhbHVlID09IG51bGwgPyAnJyA6IGRlZmF1bHRWYWx1ZSwK
;ICAgICAgb2tUZXh0OiBvcHRzLm9rVGV4dCB8fCAn56Gu5a6aJywKICAgICAgY2FuY2VsVGV4dDogb3B0cy5jYW5jZWxUZXh0IHx8ICflj5bmtognCiAgICB9
;KTsKICB9CiAgZnVuY3Rpb24gc2hvcnRQYXRoKHApIHsKICAgIHAgPSBTdHJpbmcocCB8fCAnJyk7CiAgICBpZiAocC5sZW5ndGggPD0gNTYpIHJldHVybiBw
;OwogICAgcmV0dXJuIHAuc2xpY2UoMCwgMjgpICsgJy4uLicgKyBwLnNsaWNlKC0yNCk7CiAgfQoKICBmdW5jdGlvbiB1cGRhdGVDb3VudCgpIHsKICAgIGlm
;ICh0eXBlb2YgYXBwTW9kZSAhPT0gJ3VuZGVmaW5lZCcgJiYgYXBwTW9kZSAhPT0gJ2ZpbGUnKSByZXR1cm47CiAgICBpZiAoIWl0ZW1zLmxlbmd0aCkgewog
;ICAgICBjb3VudEVsLnRleHRDb250ZW50ID0gJ+WFsSAwIOadoee7k+aenCc7CiAgICAgIHN5bmNGaWxlU2VhcmNoQ2xlYXJQaWxsKDApOwogICAgICByZXR1
;cm47CiAgICB9CiAgICBjb25zdCBzaG93biA9IGl0ZW1zLmxlbmd0aDsKICAgIGNvdW50RWwudGV4dENvbnRlbnQgPSB0b3RhbEhpdHMgPiBzaG93bgogICAg
;ICA/ICgn5YWxICcgKyB0b3RhbEhpdHMudG9Mb2NhbGVTdHJpbmcoKSArICcg5p2h57uT5p6c77yI5bey5Yqg6L29ICcgKyBzaG93bi50b0xvY2FsZVN0cmlu
;ZygpICsgJyDmnaHvvIknKQogICAgICA6ICgn5YWxICcgKyBNYXRoLm1heCh0b3RhbEhpdHMsIHNob3duKS50b0xvY2FsZVN0cmluZygpICsgJyDmnaHnu5Pm
;npwnKTsKICAgIHN5bmNGaWxlU2VhcmNoQ2xlYXJQaWxsKE1hdGgubWF4KHRvdGFsSGl0cyB8fCAwLCBzaG93biB8fCAwKSk7CiAgfQogIGZ1bmN0aW9uIHN5
;bmNGaWxlU2VhcmNoQ2xlYXJQaWxsKGhpdE4pIHsKICAgIGNvbnN0IHBpbGwgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnY2ZnLXNlYXJjaC1jbGVhcicp
;OwogICAgY29uc3QgaGl0RWwgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnY2ZnLXNlYXJjaC1oaXQnKTsKICAgIGlmICghcGlsbCkgcmV0dXJuOwogICAg
;aWYgKGFwcE1vZGUgPT09ICdjb25maWcnKSByZXR1cm47CiAgICBpZiAoYXBwTW9kZSAhPT0gJ2ZpbGUnKSB7CiAgICAgIHBpbGwuY2xhc3NMaXN0LnJlbW92
;ZSgnb24nKTsKICAgICAgaWYgKGhpdEVsKSBoaXRFbC50ZXh0Q29udGVudCA9ICcnOwogICAgICByZXR1cm47CiAgICB9CiAgICBjb25zdCBoYXNRID0gISEo
;cUVsICYmIFN0cmluZyhxRWwudmFsdWUgfHwgJycpLnRyaW0oKSk7CiAgICBsZXQgaGFzVGFncyA9IGZhbHNlOwogICAgdHJ5IHsgaGFzVGFncyA9ICEhKGFj
;dGl2ZUZpbHRlcklkcyAmJiBhY3RpdmVGaWx0ZXJJZHMuc2l6ZSA+IDApOyB9IGNhdGNoIChfKSB7fQogICAgY29uc3Qgc2hvdyA9IGhhc1EgfHwgaGFzVGFn
;czsKICAgIHBpbGwuY2xhc3NMaXN0LnRvZ2dsZSgnb24nLCBzaG93KTsKICAgIGlmIChoaXRFbCkgewogICAgICBpZiAoc2hvdykgewogICAgICAgIGNvbnN0
;IG4gPSBoaXROICE9IG51bGwgPyBoaXROIDogTWF0aC5tYXgodG90YWxIaXRzIHx8IDAsIGl0ZW1zLmxlbmd0aCB8fCAwKTsKICAgICAgICBoaXRFbC50ZXh0
;Q29udGVudCA9IE51bWJlcihuKS50b0xvY2FsZVN0cmluZygpICsgJyDmnaEnOwogICAgICB9IGVsc2UgewogICAgICAgIGhpdEVsLnRleHRDb250ZW50ID0g
;Jyc7CiAgICAgIH0KICAgIH0KICB9CiAgZnVuY3Rpb24gY2xlYXJGaWxlU2VhcmNoQWxsKCkgewogICAgaWYgKGFjdGl2ZUZpbHRlcklkcykgewogICAgICBh
;Y3RpdmVGaWx0ZXJJZHMuY2xlYXIoKTsKICAgICAgc2F2ZUFjdGl2ZUZpbHRlcnMoKTsKICAgICAgcmVuZGVyRmlsdGVyQmFyKCk7CiAgICB9CiAgICBjbGVh
;clRpbWVvdXQoaGlzdElkbGVUaW1lcik7CiAgICBpZiAocUVsKSBxRWwudmFsdWUgPSAnJzsKICAgIG1vZGVRdWVyeS5maWxlID0gJyc7CiAgICBzeW5jQ2xl
;YXJCdG4oKTsKICAgIHNldEhpc3RDaHJvbWUoZmFsc2UpOwogICAgdHJ5IHsgcUVsLmZvY3VzKCk7IH0gY2F0Y2ggKF8pIHt9CiAgICBkb1NlYXJjaCgpOwog
;ICAgc3luY0ZpbGVTZWFyY2hDbGVhclBpbGwoMCk7CiAgICBpZiAodHlwZW9mIHNhdmVTZXNzaW9uU29vbiA9PT0gJ2Z1bmN0aW9uJykgc2F2ZVNlc3Npb25T
;b29uKCk7CiAgfQoKICBmdW5jdGlvbiBtYWtlUm93KGl0LCBpKSB7CiAgICBjb25zdCByb3cgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsKICAg
;IHJvdy5jbGFzc05hbWUgPSAncm93JyArIChpID09PSBzZWxlY3RlZCA/ICcgb24nIDogJycpOwogICAgY29uc3QgdGl0bGUgPSBkaXNwbGF5TmFtZShpdCk7
;CiAgICByb3cuaW5uZXJIVE1MID0gYDxkaXYgY2xhc3M9ImZpIj4ke2ljb25IdG1sKGl0KX08L2Rpdj4KICAgICAgPGRpdj4KICAgICAgICA8ZGl2IGNsYXNz
;PSJuYW1lIj4ke3ByZXR0eU5hbWUodGl0bGUpfTwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9InBhdGgiIHRpdGxlPSIke2VzY2FwZUh0bWwoaXQucGF0aCl9
;Ij4ke2VzY2FwZUh0bWwoc2hvcnRQYXRoKGl0LnBhdGgpKX08L2Rpdj4KICAgICAgPC9kaXY+YDsKICAgIHJvdy5vbmNsaWNrID0gKCkgPT4geyBoaWRlQ3R4
;KCk7IHNlbGVjdFJvdyhpKTsgfTsKICAgIHJvdy5vbmRibGNsaWNrID0gKCkgPT4gewogICAgICBoaWRlQ3R4KCk7CiAgICAgIHB1c2hIaXN0KHFFbC52YWx1
;ZSB8fCAnJyk7CiAgICAgIGNhbGxIb3N0KCdvcGVuJywgaXQucGF0aCk7CiAgICB9OwogICAgcm93Lm9uY29udGV4dG1lbnUgPSAoZSkgPT4gewogICAgICBl
;LnByZXZlbnREZWZhdWx0KCk7CiAgICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAgIHNlbGVjdFJvdyhpKTsKICAgICAgc2hvd0N0eChlLmNsaWVudFgs
;IGUuY2xpZW50WSwgaXQucGF0aCk7CiAgICB9OwogICAgcmV0dXJuIHJvdzsKICB9CgogIGNvbnN0IGN0eEVsID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQo
;J2N0eCcpOwogIGxldCBjdHhQYXRoID0gJyc7CiAgZnVuY3Rpb24gaGlkZUN0eCgpIHsKICAgIGN0eEVsLmNsYXNzTGlzdC5yZW1vdmUoJ29uJyk7CiAgICBj
;dHhQYXRoID0gJyc7CiAgfQogIGZ1bmN0aW9uIHNob3dDdHgoeCwgeSwgcGF0aCkgewogICAgY3R4UGF0aCA9IFN0cmluZyhwYXRoIHx8ICcnKTsKICAgIGlm
;ICghY3R4UGF0aCkgcmV0dXJuOwogICAgY3R4RWwuY2xhc3NMaXN0LmFkZCgnb24nKTsKICAgIGNvbnN0IHBhZCA9IDY7CiAgICBjb25zdCB2dyA9IHdpbmRv
;dy5pbm5lcldpZHRoOwogICAgY29uc3QgdmggPSB3aW5kb3cuaW5uZXJIZWlnaHQ7CiAgICBjdHhFbC5zdHlsZS5sZWZ0ID0gJzBweCc7CiAgICBjdHhFbC5z
;dHlsZS50b3AgPSAnMHB4JzsKICAgIGNvbnN0IHJlY3QgPSBjdHhFbC5nZXRCb3VuZGluZ0NsaWVudFJlY3QoKTsKICAgIGxldCBsZWZ0ID0geDsKICAgIGxl
;dCB0b3AgPSB5OwogICAgaWYgKGxlZnQgKyByZWN0LndpZHRoID4gdncgLSBwYWQpIGxlZnQgPSBNYXRoLm1heChwYWQsIHZ3IC0gcmVjdC53aWR0aCAtIHBh
;ZCk7CiAgICBpZiAodG9wICsgcmVjdC5oZWlnaHQgPiB2aCAtIHBhZCkgdG9wID0gTWF0aC5tYXgocGFkLCB2aCAtIHJlY3QuaGVpZ2h0IC0gcGFkKTsKICAg
;IGN0eEVsLnN0eWxlLmxlZnQgPSBsZWZ0ICsgJ3B4JzsKICAgIGN0eEVsLnN0eWxlLnRvcCA9IHRvcCArICdweCc7CiAgfQogIGN0eEVsLnF1ZXJ5U2VsZWN0
;b3JBbGwoJ2J1dHRvbltkYXRhLWFjdF0nKS5mb3JFYWNoKGJ0biA9PiB7CiAgICBidG4uYWRkRXZlbnRMaXN0ZW5lcignY2xpY2snLCAoZSkgPT4gewogICAg
;ICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgICBjb25zdCBhY3QgPSBidG4uZ2V0QXR0cmlidXRlKCdkYXRhLWFjdCcpOwogICAgICBjb25zdCBwYXRoID0g
;Y3R4UGF0aDsKICAgICAgaGlkZUN0eCgpOwogICAgICBpZiAoIXBhdGggfHwgIWFjdCkgcmV0dXJuOwogICAgICBpZiAoYWN0ID09PSAncmV2ZWFsJykgY2Fs
;bEhvc3QoJ3JldmVhbCcsIHBhdGgpOwogICAgICBlbHNlIGlmIChhY3QgPT09ICdjb3B5JykgY2FsbEhvc3QoJ2NvcHlGaWxlJywgcGF0aCk7CiAgICAgIGVs
;c2UgaWYgKGFjdCA9PT0gJ2NvcHlQYXRoJykgY2FsbEhvc3QoJ2NvcHlQYXRoJywgcGF0aCk7CiAgICAgIGVsc2UgaWYgKGFjdCA9PT0gJ2NvcHlEaXInKSBj
;YWxsSG9zdCgnY29weURpcicsIHBhdGgpOwogICAgICBlbHNlIGlmIChhY3QgPT09ICdyZWN5Y2xlJykgY2FsbEhvc3QoJ3JlY3ljbGUnLCBwYXRoKTsKICAg
;IH0pOwogIH0pOwogIGRvY3VtZW50LmFkZEV2ZW50TGlzdGVuZXIoJ2NvbnRleHRtZW51JywgKGUpID0+IHsKICAgIGlmICghZS50YXJnZXQuY2xvc2VzdCgn
;I2xpc3QgLnJvdycpICYmICFlLnRhcmdldC5jbG9zZXN0KCcjY3R4JykpIGhpZGVDdHgoKTsKICB9KTsKICB3aW5kb3cuYWRkRXZlbnRMaXN0ZW5lcignYmx1
;cicsIGhpZGVDdHgpOwogIHdpbmRvdy5hZGRFdmVudExpc3RlbmVyKCdyZXNpemUnLCBoaWRlQ3R4KTsKICB3aW5kb3cuX19yZW1vdmVQYXRoID0gKHBhdGgp
;ID0+IHsKICAgIHBhdGggPSBTdHJpbmcocGF0aCB8fCAnJyk7CiAgICBpZiAoIXBhdGgpIHJldHVybjsKICAgIGNvbnN0IHByZXZTZWwgPSBzZWxlY3RlZCA+
;PSAwID8gKGl0ZW1zW3NlbGVjdGVkXSAmJiBpdGVtc1tzZWxlY3RlZF0ucGF0aCkgOiAnJzsKICAgIGl0ZW1zID0gaXRlbXMuZmlsdGVyKGl0ID0+IFN0cmlu
;ZyhpdC5wYXRoIHx8ICcnKSAhPT0gcGF0aCk7CiAgICBpZiAodG90YWxIaXRzID4gMCkgdG90YWxIaXRzID0gTWF0aC5tYXgoMCwgdG90YWxIaXRzIC0gMSk7
;CiAgICBzZWxlY3RlZCA9IC0xOwogICAgaWYgKHByZXZTZWwgJiYgcHJldlNlbCAhPT0gcGF0aCkgewogICAgICBzZWxlY3RlZCA9IGl0ZW1zLmZpbmRJbmRl
;eChpdCA9PiBpdC5wYXRoID09PSBwcmV2U2VsKTsKICAgIH0gZWxzZSBpZiAoaXRlbXMubGVuZ3RoKSB7CiAgICAgIHNlbGVjdGVkID0gTWF0aC5taW4oc2Vs
;ZWN0ZWQgPCAwID8gMCA6IHNlbGVjdGVkLCBpdGVtcy5sZW5ndGggLSAxKTsKICAgIH0KICAgIHJlbmRlckxpc3QoZmFsc2UpOwogICAgaWYgKHNlbGVjdGVk
;ID49IDAgJiYgcHJldmlld09uKSByZXF1ZXN0UHJldmlldyhpdGVtc1tzZWxlY3RlZF0pOwogICAgZWxzZSB7CiAgICAgIHB2TWV0YS50ZXh0Q29udGVudCA9
;ICfpgInmi6nmlofku7bku6XpooTop4gnOwogICAgICBwdk1lZGlhLmlubmVySFRNTCA9ICc8ZGl2IGNsYXNzPSJwaCI+6aKE6KeI5Yy6PC9kaXY+JzsKICAg
;ICAgcHZUZXh0LnN0eWxlLmRpc3BsYXkgPSAnbm9uZSc7CiAgICB9CiAgfTsKCiAgZnVuY3Rpb24gcmVuZGVyTGlzdChhcHBlbmQpIHsKICAgIGlmICghYXBw
;ZW5kKSBsaXN0RWwuaW5uZXJIVE1MID0gJyc7CiAgICBpZiAoIWl0ZW1zLmxlbmd0aCkgewogICAgICBlbXB0eUVsLmNsYXNzTGlzdC5hZGQoJ29uJyk7CiAg
;ICAgIHVwZGF0ZUNvdW50KCk7CiAgICAgIHJldHVybjsKICAgIH0KICAgIGVtcHR5RWwuY2xhc3NMaXN0LnJlbW92ZSgnb24nKTsKICAgIGNvbnN0IHN0YXJ0
;ID0gYXBwZW5kID8gbGlzdEVsLnF1ZXJ5U2VsZWN0b3JBbGwoJy5yb3cnKS5sZW5ndGggOiAwOwogICAgY29uc3QgZnJhZyA9IGRvY3VtZW50LmNyZWF0ZURv
;Y3VtZW50RnJhZ21lbnQoKTsKICAgIGZvciAobGV0IGkgPSBzdGFydDsgaSA8IGl0ZW1zLmxlbmd0aDsgaSsrKQogICAgICBmcmFnLmFwcGVuZENoaWxkKG1h
;a2VSb3coaXRlbXNbaV0sIGkpKTsKICAgIGxpc3RFbC5hcHBlbmRDaGlsZChmcmFnKTsKICAgIHVwZGF0ZUNvdW50KCk7CiAgfQoKICBmdW5jdGlvbiBzZWxl
;Y3RSb3coaSwgb3B0cykgewogICAgc2VsZWN0ZWQgPSBpOwogICAgY29uc3Qgcm93cyA9IGxpc3RFbC5jaGlsZHJlbjsKICAgIGZvciAobGV0IGlkeCA9IDA7
;IGlkeCA8IHJvd3MubGVuZ3RoOyBpZHgrKykKICAgICAgcm93c1tpZHhdLmNsYXNzTGlzdC50b2dnbGUoJ29uJywgaWR4ID09PSBpKTsKICAgIGNvbnN0IGl0
;ID0gaXRlbXNbaV07CiAgICBpZiAoIWl0KSByZXR1cm47CiAgICBpZiAocHJldmlld09uKSBzY2hlZHVsZVByZXZpZXcoaXQsIG9wdHMgJiYgb3B0cy5pbW1l
;ZGlhdGUpOwogIH0KICBsZXQgcHJldmlld1RpbWVyID0gMDsKICBsZXQgcHJldmlld1Rva2VuID0gMDsKICBmdW5jdGlvbiBzY2hlZHVsZVByZXZpZXcoaXQs
;IGltbWVkaWF0ZSkgewogICAgY2xlYXJUaW1lb3V0KHByZXZpZXdUaW1lcik7CiAgICBjb25zdCB0b2sgPSArK3ByZXZpZXdUb2tlbjsKICAgIGNvbnN0IHBh
;dGggPSBpdCAmJiBpdC5wYXRoOwogICAgY29uc3QgcnVuID0gKCkgPT4gewogICAgICBpZiAodG9rICE9PSBwcmV2aWV3VG9rZW4gfHwgIXByZXZpZXdPbikg
;cmV0dXJuOwogICAgICBpZiAoc2VsZWN0ZWQgPCAwIHx8ICFpdGVtc1tzZWxlY3RlZF0gfHwgaXRlbXNbc2VsZWN0ZWRdLnBhdGggIT09IHBhdGgpIHJldHVy
;bjsKICAgICAgcmVxdWVzdFByZXZpZXcoaXRlbXNbc2VsZWN0ZWRdKTsKICAgIH07CiAgICBpZiAoaW1tZWRpYXRlKSBydW4oKTsKICAgIGVsc2UgcHJldmll
;d1RpbWVyID0gc2V0VGltZW91dChydW4sIDM2MCk7CiAgfQoKICBmdW5jdGlvbiByZXF1ZXN0UHJldmlldyhpdCkgewogICAgcHZNZXRhLmlubmVySFRNTCA9
;IGA8c3Bhbj7lkI3np7AgPGI+JHtlc2NhcGVIdG1sKGl0Lm5hbWUpfTwvYj48L3NwYW4+YDsKICAgIGlmIChwdkJvZHkpIHB2Qm9keS5jbGFzc0xpc3QucmVt
;b3ZlKCd0ZXh0LW1vZGUnKTsKICAgIHB2TWVkaWEuaW5uZXJIVE1MID0gJzxkaXYgY2xhc3M9InBoIj7liqDovb3pooTop4jigKY8L2Rpdj4nOwogICAgcHZU
;ZXh0LnN0eWxlLmRpc3BsYXkgPSAnbm9uZSc7CiAgICBjYWxsSG9zdCgncHJldmlldycsIGl0LnBhdGgpOwogIH0KCiAgZnVuY3Rpb24gdHJ5TG9hZE1vcmUo
;KSB7CiAgICBpZiAoIWhhc01vcmUgfHwgbG9hZGluZ01vcmUpIHJldHVybjsKICAgIGxvYWRpbmdNb3JlID0gdHJ1ZTsKICAgIGNhbGxIb3N0KCdzZWFyY2gn
;LCBjb21wb3NlU2VhcmNoUXVlcnkoKSwgY2F0LCBzb3J0LCBpdGVtcy5sZW5ndGgpOwogIH0KCiAgZnVuY3Rpb24gbWF5YmVGaWxsVmlld3BvcnQoKSB7CiAg
;ICAvLyDpppblsY/lj6rmnIkgMTUg5p2h5pe25Y+v6IO95LiN5aSf5rua5Yqo77yM6Ieq5Yqo6KGl6aG155u05Yiw5Y+v5rua5oiW5rKh5pyJ5pu05aSaCiAg
;ICBpZiAoIWhhc01vcmUgfHwgbG9hZGluZ01vcmUpIHJldHVybjsKICAgIGlmIChsaXN0RWwuc2Nyb2xsSGVpZ2h0IDw9IGxpc3RFbC5jbGllbnRIZWlnaHQg
;KyA4KQogICAgICB0cnlMb2FkTW9yZSgpOwogIH0KCiAgbGlzdEVsLmFkZEV2ZW50TGlzdGVuZXIoJ3Njcm9sbCcsICgpID0+IHsKICAgIGlmIChsaXN0RWwu
;c2Nyb2xsVG9wICsgbGlzdEVsLmNsaWVudEhlaWdodCA+PSBsaXN0RWwuc2Nyb2xsSGVpZ2h0IC0gMTIwKQogICAgICB0cnlMb2FkTW9yZSgpOwogIH0pOwoK
;ICB3aW5kb3cuX191cGRhdGVSZXN1bHRzID0gKHBheWxvYWQpID0+IHsKICAgIHRyeSB7CiAgICAgIGlmICh0eXBlb2YgYXBwTW9kZSAhPT0gJ3VuZGVmaW5l
;ZCcgJiYgYXBwTW9kZSAhPT0gJ2ZpbGUnKSByZXR1cm47CiAgICAgIGNvbnN0IGRhdGEgPSB0eXBlb2YgcGF5bG9hZCA9PT0gJ3N0cmluZycgPyBKU09OLnBh
;cnNlKHBheWxvYWQpIDogcGF5bG9hZDsKICAgICAgY29uc3QgYmF0Y2ggPSBBcnJheS5pc0FycmF5KGRhdGEuaXRlbXMpID8gZGF0YS5pdGVtcyA6IFtdOwog
;ICAgICBjb25zdCB0b3RhbCA9IE51bWJlcihkYXRhLnRvdGFsICE9IG51bGwgPyBkYXRhLnRvdGFsIDogMCkgfHwgMDsKICAgICAgY29uc3Qgb2Zmc2V0ID0g
;TnVtYmVyKGRhdGEub2Zmc2V0KSB8fCAwOwogICAgICBjb25zdCBhcHBlbmQgPSAhIWRhdGEuYXBwZW5kICYmIG9mZnNldCA+IDA7CiAgICAgIGNvbnN0IHBh
;Z2VTaXplID0gTWF0aC5tYXgoMSwgTnVtYmVyKGRhdGEucGFnZVNpemUpIHx8IDUwKTsKCiAgICAgIGlmICh0b3RhbCA+PSAwKQogICAgICAgIHRvdGFsSGl0
;cyA9IHRvdGFsOwogICAgICBpZiAoYXBwZW5kKSB7CiAgICAgICAgY29uc3Qgc2VlbiA9IG5ldyBTZXQoaXRlbXMubWFwKHggPT4geC5wYXRoKSk7CiAgICAg
;ICAgZm9yIChjb25zdCBpdCBvZiBiYXRjaCkgewogICAgICAgICAgaWYgKCFzZWVuLmhhcyhpdC5wYXRoKSkgaXRlbXMucHVzaChpdCk7CiAgICAgICAgfQog
;ICAgICAgIGxvYWRpbmdNb3JlID0gZmFsc2U7CiAgICAgICAgLy8g5ruh6aG15bCx57un57ut5Yqg6L2977yb5ZCM5pe25Lul5pyN5Yqh56uv5oC75pWw5Li6
;5YeGCiAgICAgICAgaGFzTW9yZSA9IGJhdGNoLmxlbmd0aCA+PSBwYWdlU2l6ZSB8fCAodG90YWxIaXRzID4gMCAmJiBpdGVtcy5sZW5ndGggPCB0b3RhbEhp
;dHMpOwogICAgICAgIHJlbmRlckxpc3QodHJ1ZSk7CiAgICAgIH0gZWxzZSB7CiAgICAgICAgaXRlbXMgPSBiYXRjaDsKICAgICAgICBsb2FkaW5nTW9yZSA9
;IGZhbHNlOwogICAgICAgIGhhc01vcmUgPSBiYXRjaC5sZW5ndGggPj0gcGFnZVNpemUgfHwgKHRvdGFsSGl0cyA+IDAgJiYgaXRlbXMubGVuZ3RoIDwgdG90
;YWxIaXRzKTsKICAgICAgICBzZWxlY3RlZCA9IGl0ZW1zLmxlbmd0aCA/IDAgOiAtMTsKICAgICAgICByZW5kZXJMaXN0KGZhbHNlKTsKICAgICAgICBpZiAo
;c2VsZWN0ZWQgPj0gMCAmJiBwcmV2aWV3T24pIHNjaGVkdWxlUHJldmlldyhpdGVtc1tzZWxlY3RlZF0pOwogICAgICAgIGVsc2UgaWYgKCFpdGVtcy5sZW5n
;dGgpIHsKICAgICAgICAgIGNsZWFyVGltZW91dChwcmV2aWV3VGltZXIpOwogICAgICAgICAgcHJldmlld1Rva2VuICs9IDE7CiAgICAgICAgICBpZiAocHZC
;b2R5KSBwdkJvZHkuY2xhc3NMaXN0LnJlbW92ZSgndGV4dC1tb2RlJyk7CiAgICAgICAgICBwdk1ldGEudGV4dENvbnRlbnQgPSAn6YCJ5oup5paH5Lu25Lul
;6aKE6KeIJzsKICAgICAgICAgIHB2TWVkaWEuaW5uZXJIVE1MID0gJzxkaXYgY2xhc3M9InBoIj7pooTop4jljLo8L2Rpdj4nOwogICAgICAgICAgcHZUZXh0
;LnN0eWxlLmRpc3BsYXkgPSAnbm9uZSc7CiAgICAgICAgfQogICAgICB9CiAgICAgIHVwZGF0ZUNvdW50KCk7CiAgICAgIHJlcXVlc3RBbmltYXRpb25GcmFt
;ZShtYXliZUZpbGxWaWV3cG9ydCk7CiAgICB9IGNhdGNoIChlKSB7CiAgICAgIGNvbnNvbGUuZXJyb3IoZSk7CiAgICAgIGxvYWRpbmdNb3JlID0gZmFsc2U7
;CiAgICAgIGNvdW50RWwudGV4dENvbnRlbnQgPSAn57uT5p6c5pu05paw5aSx6LSlJzsKICAgIH0KICB9OwoKICB3aW5kb3cuX19zZXRQcmV2aWV3ID0gKHBh
;eWxvYWQpID0+IHsKICAgIHRyeSB7CiAgICAgIGNvbnN0IGRhdGEgPSB0eXBlb2YgcGF5bG9hZCA9PT0gJ3N0cmluZycgPyBKU09OLnBhcnNlKHBheWxvYWQp
;IDogcGF5bG9hZDsKICAgICAgY29uc3Qga2luZCA9IGRhdGEua2luZCB8fCAnbm9uZSc7CiAgICAgIGNvbnN0IGJpdHMgPSBbXTsKICAgICAgY29uc3QgZHJ2
;TWF0Y2ggPSBTdHJpbmcoZGF0YS5wYXRoIHx8ICcnKS5tYXRjaCgvXihbQS1aYS16XSk6Lyk7CiAgICAgIGlmIChkcnZNYXRjaCkgewogICAgICAgIGNvbnN0
;IGxldHRlciA9IGRydk1hdGNoWzFdLnRvVXBwZXJDYXNlKCk7CiAgICAgICAgY29uc3QgaGl0ID0gKGRyaXZlTWV0YS5kcml2ZXMgfHwgW10pLmZpbmQoZCA9
;PiBTdHJpbmcoZC5sZXR0ZXIgfHwgJycpLnRvVXBwZXJDYXNlKCkgPT09IGxldHRlcik7CiAgICAgICAgY29uc3QgaWNvID0gKGhpdCAmJiBoaXQuaWNvbikg
;PyAoJzxpbWcgc3JjPSInICsgZXNjYXBlSHRtbChoaXQuaWNvbikgKyAnIiBhbHQ9IiI+JykgOiAnJzsKICAgICAgICBjb25zdCBsYWJlbCA9IChoaXQgJiYg
;aGl0LmxhYmVsKSA/IGhpdC5sYWJlbCA6IChsZXR0ZXIgKyAnOicpOwogICAgICAgIGJpdHMucHVzaCgnPHNwYW4gY2xhc3M9ImRydiI+JyArIGljbyArIGVz
;Y2FwZUh0bWwobGFiZWwpICsgJzwvc3Bhbj4nKTsKICAgICAgfQogICAgICBpZiAoZGF0YS5lbmNvZGluZykgYml0cy5wdXNoKCfnvJbnoIEgPGI+JyArIGVz
;Y2FwZUh0bWwoZGF0YS5lbmNvZGluZykgKyAnPC9iPicpOwogICAgICBpZiAoZGF0YS5zaXplVGV4dCkgYml0cy5wdXNoKCflpKflsI8gPGI+JyArIGVzY2Fw
;ZUh0bWwoZGF0YS5zaXplVGV4dCkgKyAnPC9iPicpOwogICAgICBpZiAoZGF0YS5kaW1zKSBiaXRzLnB1c2goJ+WwuuWvuCA8Yj4nICsgZXNjYXBlSHRtbChk
;YXRhLmRpbXMpICsgJzwvYj4nKTsKICAgICAgaWYgKGRhdGEubXRpbWUpIGJpdHMucHVzaCgn5L+u5pS5IDxiPicgKyBlc2NhcGVIdG1sKGRhdGEubXRpbWUp
;ICsgJzwvYj4nKTsKICAgICAgcHZNZXRhLmlubmVySFRNTCA9IGJpdHMuam9pbignPHNwYW4gc3R5bGU9Im9wYWNpdHk6LjM1Ij7Ctzwvc3Bhbj4nKSB8fCAn
;6aKE6KeIJzsKICAgICAgcHZUZXh0LnN0eWxlLmRpc3BsYXkgPSAnbm9uZSc7CiAgICAgIGlmIChwdkJvZHkpIHB2Qm9keS5jbGFzc0xpc3QucmVtb3ZlKCd0
;ZXh0LW1vZGUnKTsKCiAgICAgIGlmIChraW5kID09PSAnaW1hZ2UnICYmIGRhdGEudXJsKSB7CiAgICAgICAgcHZNZWRpYS5pbm5lckhUTUwgPSAnJzsKICAg
;ICAgICBjb25zdCBpbWcgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdpbWcnKTsKICAgICAgICBpbWcuc3JjID0gZGF0YS51cmw7CiAgICAgICAgaW1nLmFs
;dCA9ICcnOwogICAgICAgIHB2TWVkaWEuYXBwZW5kQ2hpbGQoaW1nKTsKICAgICAgfSBlbHNlIGlmIChraW5kID09PSAndmlkZW8nKSB7CiAgICAgICAgcHZN
;ZWRpYS5pbm5lckhUTUwgPSAnJzsKICAgICAgICBwdk1lZGlhLnN0eWxlLmZsZXhEaXJlY3Rpb24gPSAnY29sdW1uJzsKICAgICAgICBpZiAoZGF0YS51cmwp
;IHsKICAgICAgICAgIGNvbnN0IHYgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCd2aWRlbycpOwogICAgICAgICAgdi5jb250cm9scyA9IHRydWU7CiAgICAg
;ICAgICB2LnByZWxvYWQgPSAnbWV0YWRhdGEnOwogICAgICAgICAgdi5zcmMgPSBkYXRhLnVybDsKICAgICAgICAgIHYuc3R5bGUubWF4V2lkdGggPSAnMTAw
;JSc7CiAgICAgICAgICB2LnN0eWxlLm1heEhlaWdodCA9IGRhdGEudGh1bWIgPyAnNzAlJyA6ICcxMDAlJzsKICAgICAgICAgIHYub25lcnJvciA9ICgpID0+
;IHsKICAgICAgICAgICAgaWYgKGRhdGEudGh1bWIpIHsKICAgICAgICAgICAgICB2LnJlcGxhY2VXaXRoKE9iamVjdC5hc3NpZ24oZG9jdW1lbnQuY3JlYXRl
;RWxlbWVudCgnaW1nJyksIHsKICAgICAgICAgICAgICAgIHNyYzogZGF0YS50aHVtYiwgc3R5bGU6ICdtYXgtd2lkdGg6MTAwJTttYXgtaGVpZ2h0OjgwJTtv
;YmplY3QtZml0OmNvbnRhaW4nCiAgICAgICAgICAgICAgfSkpOwogICAgICAgICAgICB9CiAgICAgICAgICB9OwogICAgICAgICAgcHZNZWRpYS5hcHBlbmRD
;aGlsZCh2KTsKICAgICAgICB9IGVsc2UgaWYgKGRhdGEudGh1bWIpIHsKICAgICAgICAgIGNvbnN0IGltZyA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2lt
;ZycpOwogICAgICAgICAgaW1nLnNyYyA9IGRhdGEudGh1bWI7CiAgICAgICAgICBpbWcuc3R5bGUubWF4V2lkdGggPSAnMTAwJSc7CiAgICAgICAgICBpbWcu
;c3R5bGUubWF4SGVpZ2h0ID0gJzgwJSc7CiAgICAgICAgICBpbWcuc3R5bGUub2JqZWN0Rml0ID0gJ2NvbnRhaW4nOwogICAgICAgICAgcHZNZWRpYS5hcHBl
;bmRDaGlsZChpbWcpOwogICAgICAgIH0gZWxzZSB7CiAgICAgICAgICBwdk1lZGlhLmlubmVySFRNTCA9ICc8ZGl2IGNsYXNzPSJwaCI+5peg5rOV6aKE6KeI
;5q2k6KeG6aKR77yM6K+35Y+M5Ye75omT5byAPC9kaXY+JzsKICAgICAgICB9CiAgICAgIH0gZWxzZSBpZiAoa2luZCA9PT0gJ2F1ZGlvJykgewogICAgICAg
;IHB2TWVkaWEuaW5uZXJIVE1MID0gJyc7CiAgICAgICAgY29uc3Qgd3JhcCA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOwogICAgICAgIHdyYXAu
;Y2xhc3NOYW1lID0gJ3B2LWZpbGVpbmZvJzsKICAgICAgICB3cmFwLnN0eWxlLmJhY2tncm91bmQgPSAnIzNmNDQ1MCc7CiAgICAgICAgd3JhcC5zdHlsZS5j
;b2xvciA9ICcjZTVlN2ViJzsKICAgICAgICBpZiAoZGF0YS5pY29uKSB3cmFwLmlubmVySFRNTCA9ICc8aW1nIGNsYXNzPSJiaWctaWNvIiBzcmM9IicgKyBl
;c2NhcGVIdG1sKGRhdGEuaWNvbikgKyAnIiBhbHQ9IiI+JzsKICAgICAgICB3cmFwLmlubmVySFRNTCArPSAnPGRpdiBjbGFzcz0iZm4iIHN0eWxlPSJjb2xv
;cjojZmZmIj4nICsgZXNjYXBlSHRtbChkYXRhLm5hbWUgfHwgJycpICsgJzwvZGl2Pic7CiAgICAgICAgcHZNZWRpYS5hcHBlbmRDaGlsZCh3cmFwKTsKICAg
;ICAgICBpZiAoZGF0YS51cmwpIHsKICAgICAgICAgIGNvbnN0IGEgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdhdWRpbycpOwogICAgICAgICAgYS5jb250
;cm9scyA9IHRydWU7CiAgICAgICAgICBhLnNyYyA9IGRhdGEudXJsOwogICAgICAgICAgYS5zdHlsZS53aWR0aCA9ICc4NiUnOwogICAgICAgICAgYS5zdHls
;ZS5tYXJnaW5Ub3AgPSAnMTJweCc7CiAgICAgICAgICB3cmFwLmFwcGVuZENoaWxkKGEpOwogICAgICAgIH0KICAgICAgfSBlbHNlIGlmIChraW5kID09PSAn
;cGRmJyAmJiBkYXRhLnVybCkgewogICAgICAgIHB2TWVkaWEuaW5uZXJIVE1MID0gJyc7CiAgICAgICAgY29uc3QgZW1iID0gZG9jdW1lbnQuY3JlYXRlRWxl
;bWVudCgnZW1iZWQnKTsKICAgICAgICBlbWIuY2xhc3NOYW1lID0gJ3BkZic7CiAgICAgICAgZW1iLnR5cGUgPSAnYXBwbGljYXRpb24vcGRmJzsKICAgICAg
;ICBlbWIuc3JjID0gZGF0YS51cmw7CiAgICAgICAgcHZNZWRpYS5hcHBlbmRDaGlsZChlbWIpOwogICAgICB9IGVsc2UgaWYgKGtpbmQgPT09ICd0ZXh0Jykg
;ewogICAgICAgIGlmIChwdkJvZHkpIHB2Qm9keS5jbGFzc0xpc3QuYWRkKCd0ZXh0LW1vZGUnKTsKICAgICAgICBwdk1lZGlhLmlubmVySFRNTCA9ICcnOwog
;ICAgICAgIHB2VGV4dC5zdHlsZS5kaXNwbGF5ID0gJ2ZsZXgnOwogICAgICAgIHB2VGV4dEhkLnRleHRDb250ZW50ID0gZGF0YS50ZXh0VGl0bGUgfHwgJ+mi
;hOiniOWJjSAyMEtCIOWGheWuuSc7CiAgICAgICAgcHZQcmUudGV4dENvbnRlbnQgPSBkYXRhLnRleHQgfHwgJyc7CiAgICAgIH0gZWxzZSBpZiAoa2luZCA9
;PT0gJ2ZvbGRlcicgfHwga2luZCA9PT0gJ2ZpbGVpbmZvJykgewogICAgICAgIC8vIEFsd2F5cyBwcmVmZXIgY2xlYW4gc2hlbGwgaWNvbiDigJQgbmV2ZXIg
;dXNlIGJsYWNrLW1hdHRlIHRodW1ibmFpbHMgaGVyZQogICAgICAgIGNvbnN0IGljb1NyYyA9IGRhdGEuaWNvbiB8fCAnJzsKICAgICAgICBjb25zdCBpY28g
;PSBpY29TcmMKICAgICAgICAgID8gJzxpbWcgY2xhc3M9ImJpZy1pY28iIHNyYz0iJyArIGVzY2FwZUh0bWwoaWNvU3JjKSArICciIGFsdD0iIj4nCiAgICAg
;ICAgICA6ICc8ZGl2IGNsYXNzPSJiaWctaWNvIiBzdHlsZT0iZm9udC1zaXplOjM2cHg7bGluZS1oZWlnaHQ6NDhweCI+JyArIChraW5kID09PSAnZm9sZGVy
;JyA/ICfwn5OBJyA6ICfwn5OEJykgKyAnPC9kaXY+JzsKICAgICAgICBjb25zdCByb3dzID0gW107CiAgICAgICAgaWYgKGRhdGEuc2l6ZVRleHQpIHJvd3Mu
;cHVzaChbJ+Wkp+WwjycsIGRhdGEuc2l6ZVRleHRdKTsKICAgICAgICBpZiAoZGF0YS5tdGltZSkgcm93cy5wdXNoKFsn5L+u5pS55pe26Ze0JywgZGF0YS5t
;dGltZV0pOwogICAgICAgIGlmIChkYXRhLmRpciB8fCBkYXRhLnBhdGgpIHJvd3MucHVzaChbJ+aJgOWcqOi3r+W+hCcsIGRhdGEuZGlyIHx8IGRhdGEucGF0
;aF0pOwogICAgICAgIGNvbnN0IGt2ID0gcm93cy5sZW5ndGgKICAgICAgICAgID8gJzxkaXYgY2xhc3M9Imt2Ij4nICsgcm93cy5tYXAoKFtrLCB2XSkgPT4K
;ICAgICAgICAgICAgICAnPGRpdiBjbGFzcz0ia3Ytcm93Ij48c3BhbiBjbGFzcz0iayI+JyArIGVzY2FwZUh0bWwoaykgKyAnPC9zcGFuPicKICAgICAgICAg
;ICAgICArICc8c3BhbiBjbGFzcz0idiI+JyArIGVzY2FwZUh0bWwodikgKyAnPC9zcGFuPjwvZGl2PicKICAgICAgICAgICAgKS5qb2luKCcnKSArICc8L2Rp
;dj4nCiAgICAgICAgICA6ICcnOwogICAgICAgIGxldCBraWRzID0gJyc7CiAgICAgICAgaWYgKEFycmF5LmlzQXJyYXkoZGF0YS5jaGlsZHJlbikgJiYgZGF0
;YS5jaGlsZHJlbi5sZW5ndGgpIHsKICAgICAgICAgIGtpZHMgPSAnPGRpdiBjbGFzcz0ia2lkcyI+PGI+5YaF5a656aKE6KeIPC9iPjxicj4nCiAgICAgICAg
;ICAgICsgZGF0YS5jaGlsZHJlbi5tYXAoYyA9PiBlc2NhcGVIdG1sKGMpKS5qb2luKCc8YnI+JykgKyAnPC9kaXY+JzsKICAgICAgICB9CiAgICAgICAgY29u
;c3QgaGludCA9IGRhdGEuaGludAogICAgICAgICAgPyAnPGRpdiBjbGFzcz0iaGludCI+JyArIGVzY2FwZUh0bWwoZGF0YS5oaW50KSArICc8L2Rpdj4nCiAg
;ICAgICAgICA6ICcnOwogICAgICAgIHB2TWVkaWEuc3R5bGUuYmFja2dyb3VuZCA9ICcjZjdmOGZiJzsKICAgICAgICBwdk1lZGlhLmlubmVySFRNTCA9ICc8
;ZGl2IGNsYXNzPSJwdi1maWxlaW5mbyI+JyArIGljbwogICAgICAgICAgKyAnPGRpdiBjbGFzcz0iZm4iPicgKyBlc2NhcGVIdG1sKGRhdGEubmFtZSB8fCAn
;JykgKyAnPC9kaXY+JwogICAgICAgICAgKyBoaW50ICsga3YgKyBraWRzICsgJzwvZGl2Pic7CiAgICAgIH0gZWxzZSB7CiAgICAgICAgcHZNZWRpYS5pbm5l
;ckhUTUwgPSAnPGRpdiBjbGFzcz0icGgiPicgKyBlc2NhcGVIdG1sKGRhdGEubWVzc2FnZSB8fCAn5peg5rOV6aKE6KeI5q2k57G75Z6LJykgKyAnPC9kaXY+
;JzsKICAgICAgfQogICAgfSBjYXRjaCAoZSkge30KICB9OwoKICBmdW5jdGlvbiBkb1NlYXJjaCgpIHsKICAgIGlmICh0eXBlb2YgYXBwTW9kZSAhPT0gJ3Vu
;ZGVmaW5lZCcgJiYgYXBwTW9kZSA9PT0gJ2hhbmRsZScpIHsKICAgICAgcmVxdWVzdEhhbmRsZVNlYXJjaChxRWwudmFsdWUgfHwgJycpOwogICAgICByZXR1
;cm47CiAgICB9CiAgICBpZiAodHlwZW9mIGFwcE1vZGUgIT09ICd1bmRlZmluZWQnICYmIGFwcE1vZGUgPT09ICdpbmZvJykgewogICAgICByZXF1ZXN0U3lz
;SW5mbyhmYWxzZSk7CiAgICAgIHJldHVybjsKICAgIH0KICAgIGNvbnN0IHEgPSBjb21wb3NlU2VhcmNoUXVlcnkoKTsKICAgIGNvdW50RWwudGV4dENvbnRl
;bnQgPSAn5pCc57Si5Lit4oCmJzsKICAgIGxvYWRpbmdNb3JlID0gZmFsc2U7CiAgICBoYXNNb3JlID0gZmFsc2U7CiAgICBjYWxsSG9zdCgnc2VhcmNoJywg
;cSwgY2F0LCBzb3J0LCAwKTsKICB9CiAgZnVuY3Rpb24gc2NoZWR1bGVTZWFyY2goKSB7CiAgICBpZiAodHlwZW9mIGFwcE1vZGUgIT09ICd1bmRlZmluZWQn
;ICYmIGFwcE1vZGUgIT09ICdmaWxlJykgcmV0dXJuOwogICAgY2xlYXJUaW1lb3V0KHNlYXJjaFRpbWVyKTsKICAgIHNlYXJjaFRpbWVyID0gc2V0VGltZW91
;dChkb1NlYXJjaCwgMTIwKTsKICB9CgogIGRvY3VtZW50LnF1ZXJ5U2VsZWN0b3JBbGwoJy5jYXQnKS5mb3JFYWNoKGJ0biA9PiB7CiAgICBidG4uYWRkRXZl
;bnRMaXN0ZW5lcignY2xpY2snLCAoKSA9PiB7CiAgICAgIGRvY3VtZW50LnF1ZXJ5U2VsZWN0b3JBbGwoJy5jYXQnKS5mb3JFYWNoKGIgPT4gYi5jbGFzc0xp
;c3QucmVtb3ZlKCdvbicpKTsKICAgICAgYnRuLmNsYXNzTGlzdC5hZGQoJ29uJyk7CiAgICAgIGNvbnN0IGMgPSBidG4uZGF0YXNldC5jYXQ7CiAgICAgIGlm
;IChjID09PSAnX19oYW5kbGUnKSB7CiAgICAgICAgc2V0QXBwTW9kZSgnaGFuZGxlJyk7CiAgICAgICAgcmV0dXJuOwogICAgICB9CiAgICAgIGlmIChjID09
;PSAnX19pbmZvJykgewogICAgICAgIHNldEFwcE1vZGUoJ2luZm8nKTsKICAgICAgICByZXR1cm47CiAgICAgIH0KICAgICAgaWYgKGMgPT09ICdfX2NvbmZp
;ZycpIHsKICAgICAgICBzZXRBcHBNb2RlKCdjb25maWcnKTsKICAgICAgICByZXR1cm47CiAgICAgIH0KICAgICAgY2F0ID0gYzsKICAgICAgc2V0QXBwTW9k
;ZSgnZmlsZScpOwogICAgICBkb1NlYXJjaCgpOwogICAgICBpZiAodHlwZW9mIHNhdmVTZXNzaW9uU29vbiA9PT0gJ2Z1bmN0aW9uJykgc2F2ZVNlc3Npb25T
;b29uKCk7CiAgICB9KTsKICB9KTsKICBxRWwuYWRkRXZlbnRMaXN0ZW5lcignaW5wdXQnLCAoKSA9PiB7CiAgICBpZiAoYXBwTW9kZSA9PT0gJ2ZpbGUnKSBt
;b2RlUXVlcnkuZmlsZSA9IHFFbC52YWx1ZTsKICAgIGVsc2UgaWYgKGFwcE1vZGUgPT09ICdoYW5kbGUnKSBtb2RlUXVlcnkuaGFuZGxlID0gcUVsLnZhbHVl
;OwogICAgZWxzZSBpZiAoYXBwTW9kZSA9PT0gJ2luZm8nKSBtb2RlUXVlcnkuaW5mbyA9IHFFbC52YWx1ZTsKICAgIGVsc2UgaWYgKGFwcE1vZGUgPT09ICdj
;b25maWcnKSB7CiAgICAgIG1vZGVRdWVyeS5jb25maWcgPSBxRWwudmFsdWU7CiAgICAgIGlmICh0eXBlb2YgYXBwbHlDb25maWdTZWFyY2ggPT09ICdmdW5j
;dGlvbicpIGFwcGx5Q29uZmlnU2VhcmNoKHFFbC52YWx1ZSk7CiAgICAgIHN5bmNDbGVhckJ0bigpOwogICAgICBjbGVhclRpbWVvdXQoaGlzdElkbGVUaW1l
;cik7CiAgICAgIGhpc3RJZGxlVGltZXIgPSBzZXRUaW1lb3V0KCgpID0+IHsKICAgICAgICBpZiAoYXBwTW9kZSA9PT0gJ2NvbmZpZycpIHB1c2hIaXN0KHFF
;bC52YWx1ZSB8fCAnJyk7CiAgICAgIH0sIDEyMDApOwogICAgICBpZiAodHlwZW9mIHNhdmVTZXNzaW9uU29vbiA9PT0gJ2Z1bmN0aW9uJykgc2F2ZVNlc3Np
;b25Tb29uKCk7CiAgICAgIHJldHVybjsKICAgIH0KICAgIHN5bmNDbGVhckJ0bigpOwogICAgc2NoZWR1bGVTZWFyY2goKTsKICAgIGNsZWFyVGltZW91dCho
;aXN0SWRsZVRpbWVyKTsKICAgIGhpc3RJZGxlVGltZXIgPSBzZXRUaW1lb3V0KCgpID0+IHsKICAgICAgaWYgKGFwcE1vZGUgPT09ICdpbmZvJyB8fCBhcHBN
;b2RlID09PSAnY29uZmlnJykgcmV0dXJuOwogICAgICBwdXNoSGlzdChxRWwudmFsdWUgfHwgJycpOwogICAgfSwgMTIwMCk7CiAgICBpZiAodHlwZW9mIHNh
;dmVTZXNzaW9uU29vbiA9PT0gJ2Z1bmN0aW9uJykgc2F2ZVNlc3Npb25Tb29uKCk7CiAgfSk7CiAgcUVsLmFkZEV2ZW50TGlzdGVuZXIoJ2tleWRvd24nLCBl
;ID0+IHsKICAgIGlmIChhcHBNb2RlID09PSAnaW5mbycpIHJldHVybjsKICAgIGlmIChlLmtleSA9PT0gJ0VudGVyJykgewogICAgICBjbGVhclRpbWVvdXQo
;aGlzdElkbGVUaW1lcik7CiAgICAgIHB1c2hIaXN0KHFFbC52YWx1ZSB8fCAnJyk7CiAgICAgIGlmIChhcHBNb2RlID09PSAnY29uZmlnJykgewogICAgICAg
;IGlmICh0eXBlb2YgYXBwbHlDb25maWdTZWFyY2ggPT09ICdmdW5jdGlvbicpIGFwcGx5Q29uZmlnU2VhcmNoKHFFbC52YWx1ZSk7CiAgICAgIH0gZWxzZSB7
;CiAgICAgICAgZG9TZWFyY2goKTsKICAgICAgfQogICAgfSBlbHNlIGlmIChlLmtleSA9PT0gJ0VzY2FwZScgJiYgKHFFbC52YWx1ZSB8fCAnJykpIHsKICAg
;ICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgY2xlYXJTZWFyY2goKTsKICAgIH0KICB9KTsKICBxRWwuYWRkRXZlbnRMaXN0ZW5lcignYmx1cicsICgp
;ID0+IHsKICAgIGNsZWFyVGltZW91dChoaXN0SWRsZVRpbWVyKTsKICAgIGlmIChhcHBNb2RlICE9PSAnaW5mbycpIHB1c2hIaXN0KHFFbC52YWx1ZSB8fCAn
;Jyk7CiAgfSk7CgogIGZ1bmN0aW9uIGZvY3VzU2VhcmNoKHNlbGVjdEFsbCkgewogICAgdHJ5IHsKICAgICAgcUVsLmZvY3VzKCk7CiAgICAgIGlmIChzZWxl
;Y3RBbGwgIT09IGZhbHNlKQogICAgICAgIHFFbC5zZWxlY3QoKTsKICAgIH0gY2F0Y2ggKF8pIHt9CiAgfQogIHdpbmRvdy5fX2ZvY3VzU2VhcmNoID0gZm9j
;dXNTZWFyY2g7CgogIGZ1bmN0aW9uIGlzVmlkZW9GdWxsc2NyZWVuKCkgewogICAgY29uc3QgZnMgPSBkb2N1bWVudC5mdWxsc2NyZWVuRWxlbWVudCB8fCBk
;b2N1bWVudC53ZWJraXRGdWxsc2NyZWVuRWxlbWVudCB8fCBkb2N1bWVudC5tc0Z1bGxzY3JlZW5FbGVtZW50OwogICAgaWYgKGZzKSByZXR1cm4gdHJ1ZTsK
;ICAgIGNvbnN0IHZpZHMgPSBkb2N1bWVudC5xdWVyeVNlbGVjdG9yQWxsKCd2aWRlbycpOwogICAgZm9yIChjb25zdCB2IG9mIHZpZHMpIHsKICAgICAgaWYg
;KHYud2Via2l0RGlzcGxheWluZ0Z1bGxzY3JlZW4gfHwgdi5tb3pGdWxsU2NyZWVuIHx8IHYubXNGdWxsc2NyZWVuRWxlbWVudCkgcmV0dXJuIHRydWU7CiAg
;ICB9CiAgICByZXR1cm4gZmFsc2U7CiAgfQogIGZ1bmN0aW9uIGV4aXRWaWRlb0Z1bGxzY3JlZW4oKSB7CiAgICB0cnkgewogICAgICBpZiAoZG9jdW1lbnQu
;ZnVsbHNjcmVlbkVsZW1lbnQgfHwgZG9jdW1lbnQud2Via2l0RnVsbHNjcmVlbkVsZW1lbnQpIHsKICAgICAgICBjb25zdCBwID0gZG9jdW1lbnQuZXhpdEZ1
;bGxzY3JlZW4gPyBkb2N1bWVudC5leGl0RnVsbHNjcmVlbigpCiAgICAgICAgICA6IChkb2N1bWVudC53ZWJraXRFeGl0RnVsbHNjcmVlbiAmJiBkb2N1bWVu
;dC53ZWJraXRFeGl0RnVsbHNjcmVlbigpKTsKICAgICAgICByZXR1cm4gdHJ1ZTsKICAgICAgfQogICAgfSBjYXRjaCAoXykge30KICAgIGNvbnN0IHZpZHMg
;PSBkb2N1bWVudC5xdWVyeVNlbGVjdG9yQWxsKCd2aWRlbycpOwogICAgZm9yIChjb25zdCB2IG9mIHZpZHMpIHsKICAgICAgdHJ5IHsKICAgICAgICBpZiAo
;di53ZWJraXREaXNwbGF5aW5nRnVsbHNjcmVlbiAmJiB2LndlYmtpdEV4aXRGdWxsc2NyZWVuKSB7CiAgICAgICAgICB2LndlYmtpdEV4aXRGdWxsc2NyZWVu
;KCk7CiAgICAgICAgICByZXR1cm4gdHJ1ZTsKICAgICAgICB9CiAgICAgICAgaWYgKHYuZXhpdEZ1bGxzY3JlZW4pIHsgdi5leGl0RnVsbHNjcmVlbigpOyBy
;ZXR1cm4gdHJ1ZTsgfQogICAgICB9IGNhdGNoIChfKSB7fQogICAgfQogICAgcmV0dXJuIGZhbHNlOwogIH0KICB3aW5kb3cuX19oYW5kbGVFc2MgPSAoKSA9
;PiB7CiAgICBpZiAoaXNWaWRlb0Z1bGxzY3JlZW4oKSB8fCBleGl0VmlkZW9GdWxsc2NyZWVuKCkpIHsKICAgICAgdHJ5IHsgZXhpdFZpZGVvRnVsbHNjcmVl
;bigpOyB9IGNhdGNoIChfKSB7fQogICAgICBwb3N0KCdlc2NDb25zdW1lZCcpOwogICAgICByZXR1cm4gdHJ1ZTsKICAgIH0KICAgIHBvc3QoJ2VzY0hpZGUn
;KTsKICAgIHJldHVybiBmYWxzZTsKICB9OwogIGRvY3VtZW50LmFkZEV2ZW50TGlzdGVuZXIoJ2tleWRvd24nLCBlID0+IHsKICAgIGlmICgoZS5jdHJsS2V5
;IHx8IGUubWV0YUtleSkgJiYgIWUuYWx0S2V5ICYmICFlLnNoaWZ0S2V5ICYmIFN0cmluZyhlLmtleSkudG9Mb3dlckNhc2UoKSA9PT0gJ2YnKSB7CiAgICAg
;IGUucHJldmVudERlZmF1bHQoKTsKICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgZm9jdXNTZWFyY2goKTsKICAgICAgcmV0dXJuOwogICAgfQog
;ICAgaWYgKGUua2V5ID09PSAnRXNjYXBlJyB8fCBlLmtleSA9PT0gJ0VzYycpIHsKICAgICAgaWYgKGlzVmlkZW9GdWxsc2NyZWVuKCkpIHsKICAgICAgICBl
;LnByZXZlbnREZWZhdWx0KCk7CiAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICBleGl0VmlkZW9GdWxsc2NyZWVuKCk7CiAgICAgICAgcG9z
;dCgnZXNjQ29uc3VtZWQnKTsKICAgICAgfQogICAgfQogIH0sIHRydWUpOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdidG4tc29ydCcpLm9uY2xpY2sg
;PSAoKSA9PiB7CiAgICBzb3J0ID0gc29ydCA9PT0gJ2RhdGUtZGVzYycgPyAnZGF0ZS1hc2MnIDogKHNvcnQgPT09ICdkYXRlLWFzYycgPyAnbmFtZS1hc2Mn
;IDogKHNvcnQgPT09ICduYW1lLWFzYycgPyAnc2l6ZS1kZXNjJyA6ICdkYXRlLWRlc2MnKSk7CiAgICBjb25zdCBtYXAgPSB7CiAgICAgICdkYXRlLWRlc2Mn
;OiAn5oyJ5L+u5pS55pe26Ze06ZmN5bqPJywKICAgICAgJ2RhdGUtYXNjJzogJ+aMieS/ruaUueaXtumXtOWNh+W6jycsCiAgICAgICduYW1lLWFzYyc6ICfm
;jInlkI3np7DljYfluo8nLAogICAgICAnc2l6ZS1kZXNjJzogJ+aMieWkp+Wwj+mZjeW6jycKICAgIH07CiAgICBzb3J0TGFiZWwudGV4dENvbnRlbnQgPSBt
;YXBbc29ydF0gfHwgc29ydDsKICAgIGRvU2VhcmNoKCk7CiAgICBpZiAodHlwZW9mIHNhdmVTZXNzaW9uU29vbiA9PT0gJ2Z1bmN0aW9uJykgc2F2ZVNlc3Np
;b25Tb29uKCk7CiAgfTsKICBjaGtQcmV2aWV3LmFkZEV2ZW50TGlzdGVuZXIoJ2NoYW5nZScsICgpID0+IHsKICAgIHByZXZpZXdPbiA9ICEhY2hrUHJldmll
;dy5jaGVja2VkOwogICAgcHJldmlldy5jbGFzc0xpc3QudG9nZ2xlKCdvZmYnLCAhcHJldmlld09uKTsKICAgIGlmIChwcmV2aWV3T24gJiYgc2VsZWN0ZWQg
;Pj0gMCkgcmVxdWVzdFByZXZpZXcoaXRlbXNbc2VsZWN0ZWRdKTsKICAgIGlmICh0eXBlb2Ygc2F2ZVNlc3Npb25Tb29uID09PSAnZnVuY3Rpb24nKSBzYXZl
;U2Vzc2lvblNvb24oKTsKICB9KTsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYnRuLXNldHRpbmdzJykub25jbGljayA9ICgpID0+IG9wZW5GaWx0ZXJT
;ZXR0aW5ncygpOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd0b3AnKS5hZGRFdmVudExpc3RlbmVyKCdtb3VzZWRvd24nLCBlID0+IHsKICAgIGlmIChl
;LmJ1dHRvbiAhPT0gMCkgcmV0dXJuOwogICAgaWYgKGUudGFyZ2V0LmNsb3Nlc3QoJy5uby1kcmFnJykpIHJldHVybjsKICAgIGNhbGxIb3N0KCdkcmFnJyk7
;CiAgICBwb3N0KCdkcmFnJyk7CiAgfSk7CiAgaWYgKHRpdGxlYmFyKSB7CiAgICB0aXRsZWJhci5hZGRFdmVudExpc3RlbmVyKCdtb3VzZWRvd24nLCBlID0+
;IHsKICAgICAgaWYgKGUuYnV0dG9uICE9PSAwKSByZXR1cm47CiAgICAgIGlmIChlLnRhcmdldC5jbG9zZXN0KCcubm8tZHJhZycpKSByZXR1cm47CiAgICAg
;IGNhbGxIb3N0KCdkcmFnJyk7CiAgICAgIHBvc3QoJ2RyYWcnKTsKICAgIH0pOwogICAgdGl0bGViYXIuYWRkRXZlbnRMaXN0ZW5lcignZGJsY2xpY2snLCBl
;ID0+IHsKICAgICAgaWYgKGUudGFyZ2V0LmNsb3Nlc3QoJy5uby1kcmFnJykpIHJldHVybjsKICAgICAgY2FsbEhvc3QoJ21heGltaXplJyk7CiAgICAgIHBv
;c3QoJ21heGltaXplJyk7CiAgICB9KTsKICB9CiAgY29uc3QgYnRuV2luTWluID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2J0bi13aW4tbWluJyk7CiAg
;Y29uc3QgYnRuV2luTWF4ID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2J0bi13aW4tbWF4Jyk7CiAgY29uc3QgYnRuV2luQ2xvc2UgPSBkb2N1bWVudC5n
;ZXRFbGVtZW50QnlJZCgnYnRuLXdpbi1jbG9zZScpOwogIGlmIChidG5XaW5NaW4pIGJ0bldpbk1pbi5vbmNsaWNrID0gKCkgPT4geyBjYWxsSG9zdCgnbWlu
;aW1pemUnKTsgcG9zdCgnbWluaW1pemUnKTsgfTsKICBpZiAoYnRuV2luTWF4KSBidG5XaW5NYXgub25jbGljayA9ICgpID0+IHsgY2FsbEhvc3QoJ21heGlt
;aXplJyk7IHBvc3QoJ21heGltaXplJyk7IH07CiAgaWYgKGJ0bldpbkNsb3NlKSBidG5XaW5DbG9zZS5vbmNsaWNrID0gKCkgPT4geyBjYWxsSG9zdCgnY2xv
;c2UnKTsgcG9zdCgnY2xvc2UnKTsgfTsKCiAgLy8g4pSA4pSAIOaQnOe0ouetm+mAie+8iOKAuiDlsZXlvIAgKyDlt6bkuIvop5Lorr7nva7vvInilIDilIDi
;lIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIAKICBjb25zdCBGSUxURVJfU1RPUkVfS0VZID0gJ2xvY2FsX3NlYXJjaF9maWx0ZXJz
;X3YyJzsKICBjb25zdCBGSUxURVJfU1RPUkVfTEVHQUNZID0gJ2xvY2FsX3NlYXJjaF9maWx0ZXJzX3YxJzsKICBjb25zdCBGSUxURVJfQUNUSVZFX0tFWSA9
;ICdsb2NhbF9zZWFyY2hfZmlsdGVyc19hY3RpdmVfdjEnOwogIGNvbnN0IEJVSUxUSU5fRklMVEVSUyA9IFsKICAgIHsgaWQ6ICd6aCcsIHRpdGxlOiAn5ZCr
;5Lit5paHJywgcmVnZXg6ICdbXFx4ezRlMDB9LVxceHs5ZmZmfV0nLCBidWlsdGluOiB0cnVlLCBlbmFibGVkOiB0cnVlIH0sCiAgICB7IGlkOiAnbm91bmRl
;cicsIHRpdGxlOiAn6Z2e5LiL5YiS57q/5byA5aS0JywgcmVnZXg6ICdeW15fXScsIGJ1aWx0aW46IHRydWUsIGVuYWJsZWQ6IHRydWUgfQogIF07CiAgY29u
;c3QgU1ZHX1ggPSAnPHN2ZyB2aWV3Qm94PSIwIDAgMTIgMTIiIGZpbGw9Im5vbmUiIGFyaWEtaGlkZGVuPSJ0cnVlIj48cGF0aCBkPSJNMyAzbDYgNk05IDNM
;MyA5IiBzdHJva2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIxLjQiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIvPjwvc3ZnPic7CiAgY29uc3QgU1ZH
;X1VQID0gJzxzdmcgdmlld0JveD0iMCAwIDEyIDEyIiBmaWxsPSJub25lIiBhcmlhLWhpZGRlbj0idHJ1ZSI+PHBhdGggZD0iTTYgMy4yTDIuOCA3LjJoNi40
;TDYgMy4yeiIgZmlsbD0iY3VycmVudENvbG9yIi8+PC9zdmc+JzsKICBjb25zdCBTVkdfRE4gPSAnPHN2ZyB2aWV3Qm94PSIwIDAgMTIgMTIiIGZpbGw9Im5v
;bmUiIGFyaWEtaGlkZGVuPSJ0cnVlIj48cGF0aCBkPSJNNiA4LjhsMy4yLTRIMi44TDYgOC44eiIgZmlsbD0iY3VycmVudENvbG9yIi8+PC9zdmc+JzsKICBj
;b25zdCBmaWx0ZXJSYWlsID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2ZpbHRlci1yYWlsJyk7CiAgY29uc3QgZmlsdGVyQmFyID0gZG9jdW1lbnQuZ2V0
;RWxlbWVudEJ5SWQoJ2ZpbHRlci1iYXInKTsKICBjb25zdCBmaWx0ZXJTZXR0aW5ncyA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdmaWx0ZXItc2V0dGlu
;Z3MnKTsKICBsZXQgZmlsdGVySXRlbXMgPSBbXTsKICBsZXQgYWN0aXZlRmlsdGVySWRzID0gbmV3IFNldCgpOwoKICBmdW5jdGlvbiBjbG9uZUJ1aWx0aW5E
;ZWZhdWx0cygpIHsKICAgIHJldHVybiBCVUlMVElOX0ZJTFRFUlMubWFwKHggPT4gKHsKICAgICAgaWQ6IHguaWQsIHRpdGxlOiB4LnRpdGxlLCByZWdleDog
;eC5yZWdleCwgYnVpbHRpbjogdHJ1ZSwgZW5hYmxlZDogdHJ1ZQogICAgfSkpOwogIH0KICBmdW5jdGlvbiBub3JtYWxpemVGaWx0ZXJJdGVtKHgsIGZvcmNl
;QnVpbHRpbikgewogICAgaWYgKCF4IHx8ICF4LmlkIHx8ICF4LnRpdGxlIHx8ICF4LnJlZ2V4KSByZXR1cm4gbnVsbDsKICAgIGNvbnN0IGlkID0gU3RyaW5n
;KHguaWQpOwogICAgY29uc3QgYnVpbHRpbiA9IGZvcmNlQnVpbHRpbiAhPSBudWxsID8gISFmb3JjZUJ1aWx0aW4gOiAoISF4LmJ1aWx0aW4gfHwgaWQgPT09
;ICd6aCcgfHwgaWQgPT09ICdub3VuZGVyJyk7CiAgICByZXR1cm4gewogICAgICBpZCwKICAgICAgdGl0bGU6IFN0cmluZyh4LnRpdGxlKS5zbGljZSgwLCAy
;NCksCiAgICAgIHJlZ2V4OiBTdHJpbmcoeC5yZWdleCkuc2xpY2UoMCwgMjAwKSwKICAgICAgYnVpbHRpbiwKICAgICAgZW5hYmxlZDogeC5lbmFibGVkICE9
;PSBmYWxzZQogICAgfTsKICB9CiAgZnVuY3Rpb24gbG9hZEZpbHRlclN0YXRlKCkgewogICAgZmlsdGVySXRlbXMgPSBbXTsKICAgIHRyeSB7CiAgICAgIGNv
;bnN0IHJhdyA9IGxvY2FsU3RvcmFnZS5nZXRJdGVtKEZJTFRFUl9TVE9SRV9LRVkpOwogICAgICBpZiAocmF3KSB7CiAgICAgICAgY29uc3QgYXJyID0gSlNP
;Ti5wYXJzZShyYXcpOwogICAgICAgIGlmIChBcnJheS5pc0FycmF5KGFycikgJiYgYXJyLmxlbmd0aCkgewogICAgICAgICAgZmlsdGVySXRlbXMgPSBhcnIu
;bWFwKHggPT4gbm9ybWFsaXplRmlsdGVySXRlbSh4KSkuZmlsdGVyKEJvb2xlYW4pOwogICAgICAgIH0KICAgICAgfQogICAgfSBjYXRjaCAoXykgeyBmaWx0
;ZXJJdGVtcyA9IFtdOyB9CiAgICBpZiAoIWZpbHRlckl0ZW1zLmxlbmd0aCkgewogICAgICAvLyDlhbzlrrkgdjHvvJrlhoXnva4gKyDoh6rlrprkuYkKICAg
;ICAgbGV0IGN1c3RvbXMgPSBbXTsKICAgICAgdHJ5IHsKICAgICAgICBjb25zdCByYXcgPSBsb2NhbFN0b3JhZ2UuZ2V0SXRlbShGSUxURVJfU1RPUkVfTEVH
;QUNZKTsKICAgICAgICBjb25zdCBhcnIgPSByYXcgPyBKU09OLnBhcnNlKHJhdykgOiBbXTsKICAgICAgICBjdXN0b21zID0gQXJyYXkuaXNBcnJheShhcnIp
;ID8gYXJyLm1hcCh4ID0+IG5vcm1hbGl6ZUZpbHRlckl0ZW0oeCwgZmFsc2UpKS5maWx0ZXIoQm9vbGVhbikgOiBbXTsKICAgICAgfSBjYXRjaCAoXykgeyBj
;dXN0b21zID0gW107IH0KICAgICAgZmlsdGVySXRlbXMgPSBjbG9uZUJ1aWx0aW5EZWZhdWx0cygpLmNvbmNhdChjdXN0b21zKTsKICAgICAgc2F2ZUZpbHRl
;ckl0ZW1zKCk7CiAgICB9CiAgICB0cnkgewogICAgICBjb25zdCByYXcgPSBsb2NhbFN0b3JhZ2UuZ2V0SXRlbShGSUxURVJfQUNUSVZFX0tFWSk7CiAgICAg
;IGNvbnN0IGFyciA9IHJhdyA/IEpTT04ucGFyc2UocmF3KSA6IFtdOwogICAgICBhY3RpdmVGaWx0ZXJJZHMgPSBuZXcgU2V0KEFycmF5LmlzQXJyYXkoYXJy
;KSA/IGFyci5tYXAoU3RyaW5nKSA6IFtdKTsKICAgIH0gY2F0Y2ggKF8pIHsgYWN0aXZlRmlsdGVySWRzID0gbmV3IFNldCgpOyB9CiAgfQogIGZ1bmN0aW9u
;IHNhdmVGaWx0ZXJJdGVtcygpIHsKICAgIHRyeSB7IGxvY2FsU3RvcmFnZS5zZXRJdGVtKEZJTFRFUl9TVE9SRV9LRVksIEpTT04uc3RyaW5naWZ5KGZpbHRl
;ckl0ZW1zKSk7IH0gY2F0Y2ggKF8pIHt9CiAgfQogIGZ1bmN0aW9uIHNhdmVBY3RpdmVGaWx0ZXJzKCkgewogICAgdHJ5IHsgbG9jYWxTdG9yYWdlLnNldEl0
;ZW0oRklMVEVSX0FDVElWRV9LRVksIEpTT04uc3RyaW5naWZ5KEFycmF5LmZyb20oYWN0aXZlRmlsdGVySWRzKSkpOyB9IGNhdGNoIChfKSB7fQogIH0KICBm
;dW5jdGlvbiBhbGxGaWx0ZXJzKCkgewogICAgcmV0dXJuIGZpbHRlckl0ZW1zLnNsaWNlKCk7CiAgfQogIGZ1bmN0aW9uIHZpc2libGVGaWx0ZXJzKCkgewog
;ICAgcmV0dXJuIGZpbHRlckl0ZW1zLmZpbHRlcihmID0+IGYuZW5hYmxlZCAhPT0gZmFsc2UpOwogIH0KICBmdW5jdGlvbiBjb21wb3NlU2VhcmNoUXVlcnko
;KSB7CiAgICBjb25zdCBwYXJ0cyA9IFtdOwogICAgY29uc3QgcSA9IFN0cmluZyhxRWwudmFsdWUgfHwgJycpLnRyaW0oKTsKICAgIGlmIChxKSBwYXJ0cy5w
;dXNoKHEpOwogICAgZm9yIChjb25zdCBmIG9mIHZpc2libGVGaWx0ZXJzKCkpIHsKICAgICAgaWYgKCFhY3RpdmVGaWx0ZXJJZHMuaGFzKGYuaWQpKSBjb250
;aW51ZTsKICAgICAgY29uc3QgcmUgPSBTdHJpbmcoZi5yZWdleCB8fCAnJykudHJpbSgpOwogICAgICBpZiAoIXJlKSBjb250aW51ZTsKICAgICAgcGFydHMu
;cHVzaCgncmVnZXg6JyArIHJlLnJlcGxhY2UoL1xzKy9nLCAnJykpOwogICAgfQogICAgcmV0dXJuIHBhcnRzLmpvaW4oJ3wnKTsKICB9CiAgZnVuY3Rpb24g
;c3luY0ZpbHRlclRvZ2dsZVVpKCkgewogICAgLy8g562b6YCJ6Iqv54mH5bi45pi+77yM5LiN5YaN5L2/55So6aG26YOo5oqY5Y+g5oyJ6ZKuCiAgfQogIGZ1
;bmN0aW9uIHJlbmRlckZpbHRlckJhcigpIHsKICAgIGlmICghZmlsdGVyQmFyKSByZXR1cm47CiAgICBmaWx0ZXJCYXIuaW5uZXJIVE1MID0gJyc7CiAgICBm
;b3IgKGNvbnN0IGYgb2YgdmlzaWJsZUZpbHRlcnMoKSkgewogICAgICBjb25zdCBidG4gPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdidXR0b24nKTsKICAg
;ICAgYnRuLnR5cGUgPSAnYnV0dG9uJzsKICAgICAgYnRuLmNsYXNzTmFtZSA9ICdmaWx0ZXItY2hpcCcgKyAoYWN0aXZlRmlsdGVySWRzLmhhcyhmLmlkKSA/
;ICcgb24nIDogJycpOwogICAgICBidG4udGV4dENvbnRlbnQgPSBmLnRpdGxlOwogICAgICBidG4udGl0bGUgPSAncmVnZXg6JyArIGYucmVnZXg7CiAgICAg
;IGJ0bi5vbmNsaWNrID0gKCkgPT4gewogICAgICAgIGlmIChhY3RpdmVGaWx0ZXJJZHMuaGFzKGYuaWQpKSBhY3RpdmVGaWx0ZXJJZHMuZGVsZXRlKGYuaWQp
;OwogICAgICAgIGVsc2UgYWN0aXZlRmlsdGVySWRzLmFkZChmLmlkKTsKICAgICAgICBzYXZlQWN0aXZlRmlsdGVycygpOwogICAgICAgIHJlbmRlckZpbHRl
;ckJhcigpOwogICAgICAgIGlmIChhcHBNb2RlID09PSAnZmlsZScpIHsKICAgICAgICAgIGRvU2VhcmNoKCk7CiAgICAgICAgICBzeW5jRmlsZVNlYXJjaENs
;ZWFyUGlsbCgpOwogICAgICAgIH0KICAgICAgICBpZiAodHlwZW9mIHNhdmVTZXNzaW9uU29vbiA9PT0gJ2Z1bmN0aW9uJykgc2F2ZVNlc3Npb25Tb29uKCk7
;CiAgICAgIH07CiAgICAgIGZpbHRlckJhci5hcHBlbmRDaGlsZChidG4pOwogICAgfQogICAgc3luY0ZpbHRlclRvZ2dsZVVpKCk7CiAgfQogIGZ1bmN0aW9u
;IG1vdmVGaWx0ZXIoaWR4LCBkaXIpIHsKICAgIGNvbnN0IGogPSBpZHggKyBkaXI7CiAgICBpZiAoaiA8IDAgfHwgaiA+PSBmaWx0ZXJJdGVtcy5sZW5ndGgp
;IHJldHVybjsKICAgIGNvbnN0IHQgPSBmaWx0ZXJJdGVtc1tpZHhdOwogICAgZmlsdGVySXRlbXNbaWR4XSA9IGZpbHRlckl0ZW1zW2pdOwogICAgZmlsdGVy
;SXRlbXNbal0gPSB0OwogICAgc2F2ZUZpbHRlckl0ZW1zKCk7CiAgICByZW5kZXJGaWx0ZXJCYXIoKTsKICAgIHJlbmRlckZpbHRlclNldHRpbmdzTGlzdCgp
;OwogIH0KICBmdW5jdGlvbiByZW5kZXJGaWx0ZXJTZXR0aW5nc0xpc3QoKSB7CiAgICBjb25zdCBsaXN0ID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2Zz
;LWxpc3QnKTsKICAgIGlmICghbGlzdCkgcmV0dXJuOwogICAgbGlzdC5pbm5lckhUTUwgPSAnJzsKICAgIGZpbHRlckl0ZW1zLmZvckVhY2goKGYsIGlkeCkg
;PT4gewogICAgICBjb25zdCByb3cgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsKICAgICAgcm93LmNsYXNzTmFtZSA9ICdmcy1ibG9jaycgKyAo
;Zi5lbmFibGVkID09PSBmYWxzZSA/ICcgb2ZmJyA6ICcnKTsKCiAgICAgIGNvbnN0IG9yZCA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOwogICAg
;ICBvcmQuY2xhc3NOYW1lID0gJ2ZzLW9yZCc7CiAgICAgIGNvbnN0IHVwID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnYnV0dG9uJyk7CiAgICAgIHVwLnR5
;cGUgPSAnYnV0dG9uJzsKICAgICAgdXAudGl0bGUgPSAn5LiK56e7JzsKICAgICAgdXAuaW5uZXJIVE1MID0gU1ZHX1VQOwogICAgICB1cC5kaXNhYmxlZCA9
;IGlkeCA9PT0gMDsKICAgICAgdXAub25jbGljayA9ICgpID0+IG1vdmVGaWx0ZXIoaWR4LCAtMSk7CiAgICAgIGNvbnN0IGRuID0gZG9jdW1lbnQuY3JlYXRl
;RWxlbWVudCgnYnV0dG9uJyk7CiAgICAgIGRuLnR5cGUgPSAnYnV0dG9uJzsKICAgICAgZG4udGl0bGUgPSAn5LiL56e7JzsKICAgICAgZG4uaW5uZXJIVE1M
;ID0gU1ZHX0ROOwogICAgICBkbi5kaXNhYmxlZCA9IGlkeCA9PT0gZmlsdGVySXRlbXMubGVuZ3RoIC0gMTsKICAgICAgZG4ub25jbGljayA9ICgpID0+IG1v
;dmVGaWx0ZXIoaWR4LCAxKTsKICAgICAgb3JkLmFwcGVuZENoaWxkKHVwKTsKICAgICAgb3JkLmFwcGVuZENoaWxkKGRuKTsKCiAgICAgIGNvbnN0IG1haW4g
;PSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsKICAgICAgbWFpbi5jbGFzc05hbWUgPSAnZnMtbWFpbic7CiAgICAgIG1haW4uaW5uZXJIVE1MID0g
;JzxkaXYgY2xhc3M9ImZzLXRpdGxlLXJvdyI+PHNwYW4gY2xhc3M9ImZzLXRpdGxlIj4nICsgZXNjYXBlSHRtbChmLnRpdGxlKSArICc8L3NwYW4+JwogICAg
;ICAgICsgKGYuYnVpbHRpbiA/ICc8c3BhbiBjbGFzcz0iZnMtdGFnIj7lhoXnva48L3NwYW4+JyA6ICcnKQogICAgICAgICsgJzwvZGl2PjxkaXYgY2xhc3M9
;ImZzLXJlZ2V4IiB0aXRsZT0iJyArIGVzY2FwZUF0dHIoZi5yZWdleCkgKyAnIj4nICsgZXNjYXBlSHRtbChmLnJlZ2V4KSArICc8L2Rpdj4nOwoKICAgICAg
;Y29uc3QgZW5XcmFwID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnZGl2Jyk7CiAgICAgIGVuV3JhcC5jbGFzc05hbWUgPSAnZnMtZW4nOwogICAgICBjb25z
;dCBsYWIgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdzcGFuJyk7CiAgICAgIGxhYi5jbGFzc05hbWUgPSAnZnMtZW4tbGFiJzsKICAgICAgbGFiLnRleHRD
;b250ZW50ID0gZi5lbmFibGVkID09PSBmYWxzZSA/ICflt7LnpoHnlKgnIDogJ+W3suWQr+eUqCc7CiAgICAgIGNvbnN0IHN3ID0gZG9jdW1lbnQuY3JlYXRl
;RWxlbWVudCgnYnV0dG9uJyk7CiAgICAgIHN3LnR5cGUgPSAnYnV0dG9uJzsKICAgICAgc3cuY2xhc3NOYW1lID0gJ2ZzLXN3aXRjaCcgKyAoZi5lbmFibGVk
;ID09PSBmYWxzZSA/ICcnIDogJyBvbicpOwogICAgICBzdy50aXRsZSA9IGYuZW5hYmxlZCA9PT0gZmFsc2UgPyAn5ZCv55SoJyA6ICfnpoHnlKgnOwogICAg
;ICBzdy5zZXRBdHRyaWJ1dGUoJ2FyaWEtcHJlc3NlZCcsIGYuZW5hYmxlZCAhPT0gZmFsc2UgPyAndHJ1ZScgOiAnZmFsc2UnKTsKICAgICAgc3cuaW5uZXJI
;VE1MID0gJzxpPjwvaT4nOwogICAgICBzdy5vbmNsaWNrID0gKCkgPT4gewogICAgICAgIGYuZW5hYmxlZCA9IGYuZW5hYmxlZCA9PT0gZmFsc2U7CiAgICAg
;ICAgaWYgKGYuZW5hYmxlZCA9PT0gZmFsc2UpIGFjdGl2ZUZpbHRlcklkcy5kZWxldGUoZi5pZCk7CiAgICAgICAgc2F2ZUZpbHRlckl0ZW1zKCk7CiAgICAg
;ICAgc2F2ZUFjdGl2ZUZpbHRlcnMoKTsKICAgICAgICByZW5kZXJGaWx0ZXJCYXIoKTsKICAgICAgICByZW5kZXJGaWx0ZXJTZXR0aW5nc0xpc3QoKTsKICAg
;ICAgICBpZiAoYXBwTW9kZSA9PT0gJ2ZpbGUnKSBkb1NlYXJjaCgpOwogICAgICB9OwogICAgICBlbldyYXAuYXBwZW5kQ2hpbGQobGFiKTsKICAgICAgZW5X
;cmFwLmFwcGVuZENoaWxkKHN3KTsKCiAgICAgIGNvbnN0IGRlbCA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2J1dHRvbicpOwogICAgICBkZWwudHlwZSA9
;ICdidXR0b24nOwogICAgICBkZWwuY2xhc3NOYW1lID0gJ2ZzLWRlbCc7CiAgICAgIGRlbC50aXRsZSA9ICfliKDpmaQnOwogICAgICBkZWwuaW5uZXJIVE1M
;ID0gU1ZHX1g7CiAgICAgIGRlbC5vbmNsaWNrID0gKCkgPT4gewogICAgICAgIGZpbHRlckl0ZW1zID0gZmlsdGVySXRlbXMuZmlsdGVyKHggPT4geC5pZCAh
;PT0gZi5pZCk7CiAgICAgICAgYWN0aXZlRmlsdGVySWRzLmRlbGV0ZShmLmlkKTsKICAgICAgICBzYXZlRmlsdGVySXRlbXMoKTsKICAgICAgICBzYXZlQWN0
;aXZlRmlsdGVycygpOwogICAgICAgIHJlbmRlckZpbHRlckJhcigpOwogICAgICAgIHJlbmRlckZpbHRlclNldHRpbmdzTGlzdCgpOwogICAgICAgIGlmIChh
;cHBNb2RlID09PSAnZmlsZScpIGRvU2VhcmNoKCk7CiAgICAgIH07CgogICAgICByb3cuYXBwZW5kQ2hpbGQob3JkKTsKICAgICAgcm93LmFwcGVuZENoaWxk
;KG1haW4pOwogICAgICByb3cuYXBwZW5kQ2hpbGQoZW5XcmFwKTsKICAgICAgcm93LmFwcGVuZENoaWxkKGRlbCk7CiAgICAgIGxpc3QuYXBwZW5kQ2hpbGQo
;cm93KTsKICAgIH0pOwogIH0KICBmdW5jdGlvbiByZXNldEZpbHRlcnNUb0RlZmF1bHQoKSB7CiAgICBmaWx0ZXJJdGVtcyA9IGNsb25lQnVpbHRpbkRlZmF1
;bHRzKCk7CiAgICBhY3RpdmVGaWx0ZXJJZHMgPSBuZXcgU2V0KCk7CiAgICBzYXZlRmlsdGVySXRlbXMoKTsKICAgIHNhdmVBY3RpdmVGaWx0ZXJzKCk7CiAg
;ICByZW5kZXJGaWx0ZXJCYXIoKTsKICAgIHJlbmRlckZpbHRlclNldHRpbmdzTGlzdCgpOwogICAgaWYgKGFwcE1vZGUgPT09ICdmaWxlJykgZG9TZWFyY2go
;KTsKICB9CiAgZnVuY3Rpb24gb3BlbkZpbHRlclNldHRpbmdzKCkgewogICAgcmVuZGVyRmlsdGVyU2V0dGluZ3NMaXN0KCk7CiAgICBpZiAoZmlsdGVyU2V0
;dGluZ3MpIGZpbHRlclNldHRpbmdzLmNsYXNzTGlzdC5hZGQoJ29uJyk7CiAgfQogIGZ1bmN0aW9uIGNsb3NlRmlsdGVyU2V0dGluZ3MoKSB7CiAgICBpZiAo
;ZmlsdGVyU2V0dGluZ3MpIGZpbHRlclNldHRpbmdzLmNsYXNzTGlzdC5yZW1vdmUoJ29uJyk7CiAgfQogIGxvYWRGaWx0ZXJTdGF0ZSgpOwogIHJlbmRlckZp
;bHRlckJhcigpOwogIGNvbnN0IGZzQ2xvc2UgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnZnMtY2xvc2UnKTsKICBpZiAoZnNDbG9zZSkgZnNDbG9zZS5v
;bmNsaWNrID0gKCkgPT4gY2xvc2VGaWx0ZXJTZXR0aW5ncygpOwogIGlmIChmaWx0ZXJTZXR0aW5ncykgewogICAgZmlsdGVyU2V0dGluZ3MuYWRkRXZlbnRM
;aXN0ZW5lcignY2xpY2snLCBlID0+IHsKICAgICAgaWYgKGUudGFyZ2V0ID09PSBmaWx0ZXJTZXR0aW5ncykgY2xvc2VGaWx0ZXJTZXR0aW5ncygpOwogICAg
;fSk7CiAgfQogIGNvbnN0IGZzQWRkID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2ZzLWFkZCcpOwogIGlmIChmc0FkZCkgewogICAgZnNBZGQub25jbGlj
;ayA9ICgpID0+IHsKICAgICAgY29uc3QgdGl0bGUgPSBTdHJpbmcoKGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdmcy10aXRsZScpIHx8IHt9KS52YWx1ZSB8
;fCAnJykudHJpbSgpOwogICAgICBjb25zdCByZWdleCA9IFN0cmluZygoZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2ZzLXJlZ2V4JykgfHwge30pLnZhbHVl
;IHx8ICcnKS50cmltKCk7CiAgICAgIGlmICghdGl0bGUpIHsgdHJ5IHsgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2ZzLXRpdGxlJykuZm9jdXMoKTsgfSBj
;YXRjaCAoXykge30gcmV0dXJuOyB9CiAgICAgIGlmICghcmVnZXgpIHsgdHJ5IHsgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2ZzLXJlZ2V4JykuZm9jdXMo
;KTsgfSBjYXRjaCAoXykge30gcmV0dXJuOyB9CiAgICAgIGNvbnN0IGlkID0gJ2NfJyArIERhdGUubm93KCkudG9TdHJpbmcoMzYpICsgTWF0aC5yYW5kb20o
;KS50b1N0cmluZygzNikuc2xpY2UoMiwgNik7CiAgICAgIGZpbHRlckl0ZW1zLnB1c2goeyBpZCwgdGl0bGU6IHRpdGxlLnNsaWNlKDAsIDI0KSwgcmVnZXg6
;IHJlZ2V4LnNsaWNlKDAsIDIwMCksIGJ1aWx0aW46IGZhbHNlLCBlbmFibGVkOiB0cnVlIH0pOwogICAgICBzYXZlRmlsdGVySXRlbXMoKTsKICAgICAgcmVu
;ZGVyRmlsdGVyQmFyKCk7CiAgICAgIHJlbmRlckZpbHRlclNldHRpbmdzTGlzdCgpOwogICAgICBjb25zdCB0ID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQo
;J2ZzLXRpdGxlJyk7CiAgICAgIGNvbnN0IHIgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnZnMtcmVnZXgnKTsKICAgICAgaWYgKHQpIHQudmFsdWUgPSAn
;JzsKICAgICAgaWYgKHIpIHIudmFsdWUgPSAnJzsKICAgIH07CiAgfQogIGNvbnN0IGZzRXYgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnZnMtZXYtb3B0
;cycpOwogIGlmIChmc0V2KSBmc0V2Lm9uY2xpY2sgPSAoKSA9PiBwb3N0KCdzZXR0aW5ncycpOwogIGNvbnN0IGZzUmVzZXQgPSBkb2N1bWVudC5nZXRFbGVt
;ZW50QnlJZCgnZnMtcmVzZXQnKTsKICBpZiAoZnNSZXNldCkgewogICAgZnNSZXNldC5vbmNsaWNrID0gYXN5bmMgKCkgPT4gewogICAgICBjb25zdCBvayA9
;IGF3YWl0IHVpQ29uZmlybSgn5bCG6L+Y5Y6f44CM5ZCr5Lit5paHIC8g6Z2e5LiL5YiS57q/5byA5aS044CN77yM5bm25riF6Zmk6Ieq5a6a5LmJ6aG544CC
;JywgewogICAgICAgIHRpdGxlOiAn5oGi5aSN6buY6K6k562b6YCJJywgb2tUZXh0OiAn5oGi5aSNJywgZGFuZ2VyOiB0cnVlCiAgICAgIH0pOwogICAgICBp
;ZiAoIW9rKSByZXR1cm47CiAgICAgIHJlc2V0RmlsdGVyc1RvRGVmYXVsdCgpOwogICAgfTsKICB9CiAgZG9jdW1lbnQuYWRkRXZlbnRMaXN0ZW5lcigna2V5
;ZG93bicsIGUgPT4gewogICAgaWYgKGUua2V5ID09PSAnRXNjYXBlJyAmJiBmaWx0ZXJTZXR0aW5ncyAmJiBmaWx0ZXJTZXR0aW5ncy5jbGFzc0xpc3QuY29u
;dGFpbnMoJ29uJykpIHsKICAgICAgY2xvc2VGaWx0ZXJTZXR0aW5ncygpOwogICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgfQogIH0sIHRydWUpOwoK
;ICAvLyDnlKggVVJMID9icD0g5bim5YWlIEFISyDlvZPliY3ov5vluqbvvJvkuIrpmZAgODjvvIzpgb/lhY3pppblsY/nm7TmjqUgMTAwJSDlho3pl6rov5vk
;uLvnlYzpnaIKICB0cnkgewogICAgY29uc3QgYnAgPSBNYXRoLm1heCg4LCBNYXRoLm1pbig4OCwgcGFyc2VJbnQobmV3IFVSTFNlYXJjaFBhcmFtcyhsb2Nh
;dGlvbi5zZWFyY2gpLmdldCgnYnAnKSB8fCAnMjAnLCAxMCkgfHwgMjApKTsKICAgIHNldEJvb3RQY3QoYnApOwogICAgY29uc3QgdDEgPSBkb2N1bWVudC5x
;dWVyeVNlbGVjdG9yKCcjYm9vdCAudDEnKTsKICAgIGlmICh0MSAmJiBicCA+PSA4MCkgdDEudGV4dENvbnRlbnQgPSAn5Y2z5bCG5a6M5oiQJzsKICAgIGVs
;c2UgaWYgKHQxICYmIGJwID49IDQwKSB0MS50ZXh0Q29udGVudCA9ICfno4Hnm5jntKLlvJXkuK0nOwogICAgZWxzZSBpZiAodDEpIHQxLnRleHRDb250ZW50
;ID0gJ+ato+WcqOWKoOi9vSc7CiAgfSBjYXRjaCAoZSkge30KCiAgLy8g4pSA4pSAIOWFs+iBlOWPpeafhCAvIOacrOacuuS/oeaBr++8iOW1jOWFpeS4u+WI
;l+ihqOWMuu+8ieKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgAogIGNvbnN0IGluZm9QYW5lbCA9IGRvY3VtZW50LmdldEVs
;ZW1lbnRCeUlkKCdpbmZvLXBhbmVsJyk7CiAgY29uc3QgaGFuZGxlUGFuZWwgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnaGFuZGxlLXBhbmVsJyk7CiAg
;Y29uc3QgaGFuZGxlQm9keSA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdoYW5kbGUtYm9keScpOwogIGNvbnN0IGhhbmRsZUJhbm5lciA9IGRvY3VtZW50
;LmdldEVsZW1lbnRCeUlkKCdoYW5kbGUtYmFubmVyJyk7CiAgY29uc3QgaGFuZGxlU3RhdHVzID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2hhbmRsZS1z
;dGF0dXMnKTsKICBjb25zdCBidG5Qb3J0TWFyayA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdidG4tcG9ydC1tYXJrJyk7CiAgY29uc3QgcG9ydE1hcmtQ
;b3AgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgncG9ydC1tYXJrLXBvcCcpOwogIGNvbnN0IHBvcnRNYXJrVGFncyA9IGRvY3VtZW50LmdldEVsZW1lbnRC
;eUlkKCdwb3J0LW1hcmstdGFncycpOwogIGNvbnN0IHBvcnRNYXJrSW5wdXQgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgncG9ydC1tYXJrLWlucHV0Jyk7
;CiAgY29uc3QgcHJvY01lbnUgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgncHJvYy1tZW51Jyk7CiAgY29uc3QgZmlsZVJlc3VsdHMgPSBkb2N1bWVudC5n
;ZXRFbGVtZW50QnlJZCgnZmlsZS1yZXN1bHRzJyk7CiAgY29uc3QgbWFpbkVsID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ21haW4nKTsKICBjb25zdCBi
;YXJFbCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdiYXInKTsKICBjb25zdCBNQVJLRURfUE9SVF9LRVkgPSAnYWhrX21hcmtlZF9wb3J0c192MSc7CiAg
;Y29uc3QgREVGQVVMVF9NQVJLRURfUE9SVFMgPSBbMjEsIDIyLCAyNSwgNTMsIDgwLCAxMTAsIDE0MywgNDQzLCA0NDUsIDMzMDYsIDMzODksIDU0MzIsIDYz
;NzksIDgwODAsIDg0NDMsIDI3MDE3XTsKICBsZXQgbWFya2VkUG9ydHMgPSBsb2FkTWFya2VkUG9ydHMoKTsKICBmdW5jdGlvbiBsb2FkTWFya2VkUG9ydHMo
;KSB7CiAgICB0cnkgewogICAgICBjb25zdCByYXcgPSBsb2NhbFN0b3JhZ2UuZ2V0SXRlbShNQVJLRURfUE9SVF9LRVkpOwogICAgICBpZiAocmF3ID09IG51
;bGwpIHJldHVybiBERUZBVUxUX01BUktFRF9QT1JUUy5zbGljZSgpOwogICAgICBjb25zdCBhcnIgPSBKU09OLnBhcnNlKHJhdyk7CiAgICAgIGlmICghQXJy
;YXkuaXNBcnJheShhcnIpKSByZXR1cm4gREVGQVVMVF9NQVJLRURfUE9SVFMuc2xpY2UoKTsKICAgICAgY29uc3Qgb3V0ID0gW10sIHNlZW4gPSBuZXcgU2V0
;KCk7CiAgICAgIGZvciAoY29uc3QgeCBvZiBhcnIpIHsKICAgICAgICBjb25zdCBwID0gcGFyc2VJbnQoeCwgMTApOwogICAgICAgIGlmICghTnVtYmVyLmlz
;SW50ZWdlcihwKSB8fCBwIDwgMCB8fCBwID4gNjU1MzUgfHwgc2Vlbi5oYXMocCkpIGNvbnRpbnVlOwogICAgICAgIHNlZW4uYWRkKHApOyBvdXQucHVzaChw
;KTsKICAgICAgfQogICAgICByZXR1cm4gb3V0LnNvcnQoKGEsIGIpID0+IGEgLSBiKTsKICAgIH0gY2F0Y2ggKF8pIHsgcmV0dXJuIERFRkFVTFRfTUFSS0VE
;X1BPUlRTLnNsaWNlKCk7IH0KICB9CiAgZnVuY3Rpb24gc2F2ZU1hcmtlZFBvcnRzKCkgewogICAgdHJ5IHsgbG9jYWxTdG9yYWdlLnNldEl0ZW0oTUFSS0VE
;X1BPUlRfS0VZLCBKU09OLnN0cmluZ2lmeShtYXJrZWRQb3J0cykpOyB9IGNhdGNoIChfKSB7fQogIH0KICBmdW5jdGlvbiBwb3J0SXNIb3QocG9ydCkgewog
;ICAgY29uc3QgcCA9IE51bWJlcihwb3J0KTsKICAgIHJldHVybiBOdW1iZXIuaXNGaW5pdGUocCkgJiYgcCA+PSAwICYmIG1hcmtlZFBvcnRzLmluY2x1ZGVz
;KHApOwogIH0KICBmdW5jdGlvbiBjbG9zZVBvcnRNYXJrUG9wKCkgewogICAgaWYgKHBvcnRNYXJrUG9wKSBwb3J0TWFya1BvcC5jbGFzc0xpc3QucmVtb3Zl
;KCdvbicpOwogICAgaWYgKGJ0blBvcnRNYXJrKSBidG5Qb3J0TWFyay5jbGFzc0xpc3QucmVtb3ZlKCdvbicpOwogIH0KICBmdW5jdGlvbiByZW5kZXJNYXJr
;ZWRQb3J0VGFncygpIHsKICAgIGlmICghcG9ydE1hcmtUYWdzKSByZXR1cm47CiAgICBpZiAoIW1hcmtlZFBvcnRzLmxlbmd0aCkgewogICAgICBwb3J0TWFy
;a1RhZ3MuaW5uZXJIVE1MID0gJzxkaXYgY2xhc3M9InBtcC1lbXB0eSI+5pqC5peg5qCH6K6w56uv5Y+jPC9kaXY+JzsKICAgICAgcmV0dXJuOwogICAgfQog
;ICAgcG9ydE1hcmtUYWdzLmlubmVySFRNTCA9IG1hcmtlZFBvcnRzLm1hcChwID0+CiAgICAgICc8c3BhbiBjbGFzcz0icG1wLXRhZyIgZGF0YS1wb3J0PSIn
;ICsgcCArICciPicgKyBwCiAgICAgICsgJzxidXR0b24gdHlwZT0iYnV0dG9uIiB0aXRsZT0i56e76ZmkIiBkYXRhLXJtPSInICsgcCArICciPsOXPC9idXR0
;b24+PC9zcGFuPicKICAgICkuam9pbignJyk7CiAgICBwb3J0TWFya1RhZ3MucXVlcnlTZWxlY3RvckFsbCgnYnV0dG9uW2RhdGEtcm1dJykuZm9yRWFjaChi
;dG4gPT4gewogICAgICBidG4ub25jbGljayA9IChlKSA9PiB7CiAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICBjb25zdCBwID0gTnVtYmVy
;KGJ0bi5nZXRBdHRyaWJ1dGUoJ2RhdGEtcm0nKSk7CiAgICAgICAgbWFya2VkUG9ydHMgPSBtYXJrZWRQb3J0cy5maWx0ZXIoeCA9PiB4ICE9PSBwKTsKICAg
;ICAgICBzYXZlTWFya2VkUG9ydHMoKTsKICAgICAgICByZW5kZXJNYXJrZWRQb3J0VGFncygpOwogICAgICAgIGlmIChhcHBNb2RlID09PSAnaGFuZGxlJyAm
;JiBoYW5kbGVNb2RlID09PSAncG9ydCcpIHJlbmRlckhhbmRsZVRhYmxlKCk7CiAgICAgIH07CiAgICB9KTsKICB9CiAgZnVuY3Rpb24gYWRkTWFya2VkUG9y
;dChyYXcpIHsKICAgIGNvbnN0IHBhcnRzID0gU3RyaW5nKHJhdyB8fCAnJykuc3BsaXQoL1ssfO+8jFxzXSsvKS5tYXAocyA9PiBzLnRyaW0oKSkuZmlsdGVy
;KEJvb2xlYW4pOwogICAgbGV0IGNoYW5nZWQgPSBmYWxzZTsKICAgIGZvciAoY29uc3QgcGFydCBvZiBwYXJ0cykgewogICAgICBjb25zdCBwID0gcGFyc2VJ
;bnQocGFydCwgMTApOwogICAgICBpZiAoIU51bWJlci5pc0ludGVnZXIocCkgfHwgcCA8IDAgfHwgcCA+IDY1NTM1KSBjb250aW51ZTsKICAgICAgaWYgKG1h
;cmtlZFBvcnRzLmluY2x1ZGVzKHApKSBjb250aW51ZTsKICAgICAgbWFya2VkUG9ydHMucHVzaChwKTsKICAgICAgY2hhbmdlZCA9IHRydWU7CiAgICB9CiAg
;ICBpZiAoIWNoYW5nZWQpIHJldHVybiBmYWxzZTsKICAgIG1hcmtlZFBvcnRzLnNvcnQoKGEsIGIpID0+IGEgLSBiKTsKICAgIHNhdmVNYXJrZWRQb3J0cygp
;OwogICAgcmVuZGVyTWFya2VkUG9ydFRhZ3MoKTsKICAgIGlmIChhcHBNb2RlID09PSAnaGFuZGxlJyAmJiBoYW5kbGVNb2RlID09PSAncG9ydCcpIHJlbmRl
;ckhhbmRsZVRhYmxlKCk7CiAgICByZXR1cm4gdHJ1ZTsKICB9CiAgZnVuY3Rpb24gb3BlblBvcnRNYXJrUG9wKCkgewogICAgcmVuZGVyTWFya2VkUG9ydFRh
;Z3MoKTsKICAgIGlmIChwb3J0TWFya1BvcCkgcG9ydE1hcmtQb3AuY2xhc3NMaXN0LmFkZCgnb24nKTsKICAgIGlmIChidG5Qb3J0TWFyaykgYnRuUG9ydE1h
;cmsuY2xhc3NMaXN0LmFkZCgnb24nKTsKICAgIHRyeSB7IHBvcnRNYXJrSW5wdXQgJiYgcG9ydE1hcmtJbnB1dC5mb2N1cygpOyB9IGNhdGNoIChfKSB7fQog
;IH0KICBsZXQgaGFuZGxlSXRlbXMgPSBbXTsKICBsZXQgaGFuZGxlUXVlcnkgPSAnJzsKICBsZXQgaGFuZGxlQnVzeSA9IGZhbHNlOwogIGxldCBpbmZvRGF0
;YSA9IG51bGw7CiAgbGV0IGluZm9UZXh0ID0gJyc7CiAgbGV0IGluZm9SZXFHZW4gPSAwOwogIGxldCBpbmZvTG9hZFRpbWVyID0gMDsKICBsZXQgbW9uaXRv
;clRhYiA9ICdmaWxlJzsKICBsZXQgaGFuZGxlTW9kZSA9ICdoYW5kbGUnOwogIGxldCBoYW5kbGVTb3J0S2V5ID0gJ2xwb3J0JzsKICBsZXQgaGFuZGxlU29y
;dERpciA9IDE7IC8vIDE95Y2H5bqPIC0xPemZjeW6jwogIGNvbnN0IERFRkFVTFRfUE9SVF9RVUVSWSA9ICcwLTY1NTM1JzsKICBjb25zdCBoYW5kbGVIZWFk
;ID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2hhbmRsZS1oZWFkJyk7CiAgbGV0IHByb2NNZW51VGFyZ2V0cyA9IFtdOwogIGxldCBoYW5kbGVTZWxLZXlz
;ID0gbmV3IFNldCgpOwogIGxldCBoYW5kbGVBbmNob3JLZXkgPSAnJzsKICAvLyDml6fov5vnqIvnm5HmjqcgVUkg5bey56e76Zmk77ya5Y2g5L2N6YG/5YWN
;5q6L55WZ5Luj56CB5oql6ZSZCiAgY29uc3QgcHJvY0hlYWQgPSBudWxsOwogIGNvbnN0IHByb2NCb2R5ID0gbnVsbDsKICBjb25zdCBwcm9jU2Nyb2xsID0g
;bnVsbDsKICBjb25zdCBwcm9jQ3B1VG90YWwgPSBudWxsOwogIGNvbnN0IHByb2NNZW1Ub3RhbCA9IG51bGw7CiAgbGV0IHByb2NJdGVtcyA9IFtdOwogIGxl
;dCBwcm9jU2hvd1N5cyA9IGZhbHNlOwogIGxldCBwcm9jU2VsS2V5cyA9IG5ldyBTZXQoKTsKICBsZXQgcHJvY1NlbEtleSA9ICcnOwogIGxldCBwcm9jU2Vs
;UGlkID0gMDsKICBsZXQgcHJvY0FuY2hvcktleSA9ICcnOwogIGxldCBwcm9jU29ydEtleSA9ICduYW1lJzsKICBsZXQgcHJvY1NvcnREaXIgPSAxOwogIGNv
;bnN0IHByb2NSb3dNYXAgPSBuZXcgTWFwKCk7CiAgY29uc3QgcHJvY0ljb25TdGFibGUgPSBuZXcgTWFwKCk7CgogIGZ1bmN0aW9uIHNldEFwcE1vZGUobW9k
;ZSkgewogICAgaWYgKG1vZGUgIT09ICdoYW5kbGUnICYmIG1vZGUgIT09ICdpbmZvJyAmJiBtb2RlICE9PSAnY29uZmlnJykgbW9kZSA9ICdmaWxlJzsKICAg
;IC8vIOemu+W8gOW9k+WJjeaooeW8j+WJjeWFiOWtmOS4i+aQnOe0ouahhgogICAgaWYgKGFwcE1vZGUgPT09ICdmaWxlJykgbW9kZVF1ZXJ5LmZpbGUgPSBT
;dHJpbmcocUVsLnZhbHVlIHx8ICcnKTsKICAgIGVsc2UgaWYgKGFwcE1vZGUgPT09ICdoYW5kbGUnKSBtb2RlUXVlcnkuaGFuZGxlID0gU3RyaW5nKHFFbC52
;YWx1ZSB8fCAnJyk7CiAgICBlbHNlIGlmIChhcHBNb2RlID09PSAnaW5mbycpIG1vZGVRdWVyeS5pbmZvID0gU3RyaW5nKHFFbC52YWx1ZSB8fCAnJyk7CiAg
;ICBlbHNlIGlmIChhcHBNb2RlID09PSAnY29uZmlnJykgbW9kZVF1ZXJ5LmNvbmZpZyA9IFN0cmluZyhxRWwudmFsdWUgfHwgJycpOwogICAgY29uc3QgcHJl
;diA9IGFwcE1vZGU7CiAgICBhcHBNb2RlID0gbW9kZTsKICAgIG1vbml0b3JUYWIgPSBtb2RlID09PSAnZmlsZScgPyAnZmlsZScgOiBtb2RlOwogICAgY29u
;c3QgaXNGaWxlID0gbW9kZSA9PT0gJ2ZpbGUnOwogICAgY29uc3QgaXNIYW5kbGUgPSBtb2RlID09PSAnaGFuZGxlJzsKICAgIGNvbnN0IGlzSW5mbyA9IG1v
;ZGUgPT09ICdpbmZvJzsKICAgIGNvbnN0IGlzQ29uZmlnID0gbW9kZSA9PT0gJ2NvbmZpZyc7CiAgICBjb25zdCB0b3BFbCA9IGRvY3VtZW50LmdldEVsZW1l
;bnRCeUlkKCd0b3AnKTsKICAgIGNvbnN0IGNvbmZpZ1BhbmVsID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2NvbmZpZy1wYW5lbCcpOwogICAgaWYgKG1h
;aW5FbCkgewogICAgICBtYWluRWwuY2xhc3NMaXN0LnRvZ2dsZSgnbW9kZS10b29sJywgIWlzRmlsZSk7CiAgICAgIG1haW5FbC5jbGFzc0xpc3QudG9nZ2xl
;KCdtb2RlLWhhbmRsZScsIGlzSGFuZGxlKTsKICAgICAgbWFpbkVsLmNsYXNzTGlzdC50b2dnbGUoJ21vZGUtaW5mbycsIGlzSW5mbyk7CiAgICAgIG1haW5F
;bC5jbGFzc0xpc3QudG9nZ2xlKCdtb2RlLWNvbmZpZycsIGlzQ29uZmlnKTsKICAgIH0KICAgIGlmIChiYXJFbCkgewogICAgICBiYXJFbC5jbGFzc0xpc3Qu
;dG9nZ2xlKCdtb2RlLXRvb2wnLCAhaXNGaWxlKTsKICAgICAgYmFyRWwuY2xhc3NMaXN0LnRvZ2dsZSgnbW9kZS1pbmZvJywgaXNJbmZvKTsKICAgICAgYmFy
;RWwuY2xhc3NMaXN0LnRvZ2dsZSgnbW9kZS1oYW5kbGUnLCBpc0hhbmRsZSk7CiAgICAgIGJhckVsLmNsYXNzTGlzdC50b2dnbGUoJ21vZGUtY29uZmlnJywg
;aXNDb25maWcpOwogICAgfQogICAgaWYgKHRvcEVsKSB7CiAgICAgIHRvcEVsLmNsYXNzTGlzdC50b2dnbGUoJ21vZGUtdG9vbCcsICFpc0ZpbGUpOwogICAg
;ICB0b3BFbC5jbGFzc0xpc3QudG9nZ2xlKCdtb2RlLWhhbmRsZScsIGlzSGFuZGxlKTsKICAgICAgdG9wRWwuY2xhc3NMaXN0LnRvZ2dsZSgnbW9kZS1pbmZv
;JywgaXNJbmZvKTsKICAgICAgdG9wRWwuY2xhc3NMaXN0LnRvZ2dsZSgnbW9kZS1jb25maWcnLCBpc0NvbmZpZyk7CiAgICB9CiAgICBpZiAoYXBwUm9vdCkg
;YXBwUm9vdC5jbGFzc0xpc3QudG9nZ2xlKCdoaWRlLWZpbHRlcnMnLCAhaXNGaWxlKTsKICAgIGlmIChmaWxlUmVzdWx0cykgZmlsZVJlc3VsdHMuY2xhc3NM
;aXN0LnRvZ2dsZSgnaGlkZGVuJywgIWlzRmlsZSk7CiAgICBpZiAoaGFuZGxlUGFuZWwpIGhhbmRsZVBhbmVsLmNsYXNzTGlzdC50b2dnbGUoJ2hpZGRlbics
;ICFpc0hhbmRsZSk7CiAgICBpZiAoaW5mb1BhbmVsKSBpbmZvUGFuZWwuY2xhc3NMaXN0LnRvZ2dsZSgnaGlkZGVuJywgIWlzSW5mbyk7CiAgICBpZiAoY29u
;ZmlnUGFuZWwpIGNvbmZpZ1BhbmVsLmNsYXNzTGlzdC50b2dnbGUoJ2hpZGRlbicsICFpc0NvbmZpZyk7CiAgICBxRWwucmVhZE9ubHkgPSBpc0luZm87CiAg
;ICBjbG9zZUhpc3RNZW51KCk7CiAgICBjbG9zZVBvcnRNYXJrUG9wKCk7CiAgICBwb3N0KCdwcm9jVmlld3wwJyk7CiAgICBpZiAoaXNIYW5kbGUpIHsKICAg
;ICAgcUVsLnBsYWNlaG9sZGVyID0gUExBQ0VIT0xERVJfSEFORExFOwogICAgICBoYW5kbGVTb3J0S2V5ID0gJ2xwb3J0JzsKICAgICAgaGFuZGxlU29ydERp
;ciA9IDE7CiAgICAgIHFFbC52YWx1ZSA9IG1vZGVRdWVyeS5oYW5kbGU7CiAgICAgIHN5bmNDbGVhckJ0bigpOwogICAgICByZXF1ZXN0SGFuZGxlU2VhcmNo
;KG1vZGVRdWVyeS5oYW5kbGUpOwogICAgICB0cnkgeyBxRWwuZm9jdXMoKTsgfSBjYXRjaCAoXykge30KICAgIH0gZWxzZSBpZiAoaXNJbmZvKSB7CiAgICAg
;IHFFbC5wbGFjZWhvbGRlciA9IFBMQUNFSE9MREVSX0lORk87CiAgICAgIHFFbC52YWx1ZSA9IG1vZGVRdWVyeS5pbmZvOwogICAgICBzeW5jQ2xlYXJCdG4o
;KTsKICAgICAgY291bnRFbC50ZXh0Q29udGVudCA9ICfmnKzmnLrkv6Hmga8nOwogICAgICByZXF1ZXN0U3lzSW5mbyhmYWxzZSk7CiAgICB9IGVsc2UgaWYg
;KGlzQ29uZmlnKSB7CiAgICAgIHFFbC5wbGFjZWhvbGRlciA9IFBMQUNFSE9MREVSX0NPTkZJRzsKICAgICAgcUVsLnZhbHVlID0gbW9kZVF1ZXJ5LmNvbmZp
;ZyB8fCAnJzsKICAgICAgc3luY0NsZWFyQnRuKCk7CiAgICAgIGNvdW50RWwudGV4dENvbnRlbnQgPSAn6L+Q6KGM6YWN572uJzsKICAgICAgaWYgKHR5cGVv
;ZiBlbnN1cmVDb25maWdVaSA9PT0gJ2Z1bmN0aW9uJykgZW5zdXJlQ29uZmlnVWkoKTsKICAgICAgaWYgKHR5cGVvZiBhcHBseUNvbmZpZ1NlYXJjaCA9PT0g
;J2Z1bmN0aW9uJykgYXBwbHlDb25maWdTZWFyY2gobW9kZVF1ZXJ5LmNvbmZpZyB8fCAnJyk7CiAgICAgIGlmICh0eXBlb2YgbG9hZEFoa0NvbmZpZ1RhYiA9
;PT0gJ2Z1bmN0aW9uJykgbG9hZEFoa0NvbmZpZ1RhYihjZmdBY3RpdmVUYWIgfHwgJ3J1bmNvbmZpZycsIGZhbHNlKTsKICAgICAgdHJ5IHsgcUVsLmZvY3Vz
;KCk7IH0gY2F0Y2ggKF8pIHt9CiAgICB9IGVsc2UgewogICAgICBxRWwucGxhY2Vob2xkZXIgPSBQTEFDRUhPTERFUl9GSUxFOwogICAgICBxRWwudmFsdWUg
;PSBtb2RlUXVlcnkuZmlsZTsKICAgICAgc3luY0NsZWFyQnRuKCk7CiAgICAgIHRyeSB7IHFFbC5mb2N1cygpOyB9IGNhdGNoIChfKSB7fQogICAgICAvLyDk
;u47lhbblroPmqKHlvI/liIflm57mlofku7bvvJrnlKjmnKzlnLDmnaHku7bph43mkJzvvIjlkKvnrZvpgInvvInvvIzkuI3luKblj6Xmn4TlhbPplK7lrZcK
;ICAgICAgaWYgKHByZXYgIT09ICdmaWxlJykgZG9TZWFyY2goKTsKICAgIH0KICAgIGlmICh0eXBlb2Ygc2F2ZVNlc3Npb25Tb29uID09PSAnZnVuY3Rpb24n
;KSBzYXZlU2Vzc2lvblNvb24oKTsKICB9CiAgZnVuY3Rpb24gc2V0QXBwVmlldyhuYW1lKSB7CiAgICAvLyDlhbzlrrnml6flhaXlj6PvvJrliIfliLDkvqfm
;oI/lr7nlupTpobkKICAgIGlmIChuYW1lID09PSAnaGFuZGxlJyB8fCBuYW1lID09PSAncHJvYycpIHsKICAgICAgZG9jdW1lbnQucXVlcnlTZWxlY3RvckFs
;bCgnLmNhdCcpLmZvckVhY2goYiA9PiBiLmNsYXNzTGlzdC50b2dnbGUoJ29uJywgYi5kYXRhc2V0LmNhdCA9PT0gJ19faGFuZGxlJykpOwogICAgICBzZXRB
;cHBNb2RlKCdoYW5kbGUnKTsKICAgICAgcmV0dXJuOwogICAgfQogICAgaWYgKG5hbWUgPT09ICdpbmZvJykgewogICAgICBkb2N1bWVudC5xdWVyeVNlbGVj
;dG9yQWxsKCcuY2F0JykuZm9yRWFjaChiID0+IGIuY2xhc3NMaXN0LnRvZ2dsZSgnb24nLCBiLmRhdGFzZXQuY2F0ID09PSAnX19pbmZvJykpOwogICAgICBz
;ZXRBcHBNb2RlKCdpbmZvJyk7CiAgICAgIHJldHVybjsKICAgIH0KICAgIGlmIChuYW1lID09PSAnY29uZmlnJykgewogICAgICBkb2N1bWVudC5xdWVyeVNl
;bGVjdG9yQWxsKCcuY2F0JykuZm9yRWFjaChiID0+IGIuY2xhc3NMaXN0LnRvZ2dsZSgnb24nLCBiLmRhdGFzZXQuY2F0ID09PSAnX19jb25maWcnKSk7CiAg
;ICAgIHNldEFwcE1vZGUoJ2NvbmZpZycpOwogICAgICByZXR1cm47CiAgICB9CiAgICBkb2N1bWVudC5xdWVyeVNlbGVjdG9yQWxsKCcuY2F0JykuZm9yRWFj
;aChiID0+IGIuY2xhc3NMaXN0LnRvZ2dsZSgnb24nLCBiLmRhdGFzZXQuY2F0ID09PSBjYXQpKTsKICAgIHNldEFwcE1vZGUoJ2ZpbGUnKTsKICB9CiAgZnVu
;Y3Rpb24gc3luY1Byb2NNb25pdG9yTGl2ZSgpIHsgcG9zdCgncHJvY1ZpZXd8MCcpOyB9CiAgZnVuY3Rpb24gcmVxdWVzdFByb2NMaXN0KCkgeyAvKiDlt7Ln
;p7vpmaTph43lnovov5vnqIvnm5HmjqcgKi8gfQogIGZ1bmN0aW9uIGNsZWFySW5mb0xvYWRXYWl0KCkgewogICAgaWYgKGluZm9Mb2FkVGltZXIpIHsKICAg
;ICAgY2xlYXJUaW1lb3V0KGluZm9Mb2FkVGltZXIpOwogICAgICBpbmZvTG9hZFRpbWVyID0gMDsKICAgIH0KICB9CiAgZnVuY3Rpb24gc2hvd0luZm9Mb2Fk
;aW5nKCkgewogICAgaWYgKCFpbmZvUGFuZWwgfHwgYXBwTW9kZSAhPT0gJ2luZm8nKSByZXR1cm47CiAgICBpbmZvUGFuZWwuaW5uZXJIVE1MID0gJzxkaXYg
;Y2xhc3M9ImluZm8tbG9hZGluZyI+PGRpdiBjbGFzcz0iaW5mby1zcGlubmVyIiBhcmlhLWhpZGRlbj0idHJ1ZSI+PC9kaXY+PGRpdj7mraPlnKjor7vlj5bm
;nKzmnLrkv6Hmga/igKY8L2Rpdj48L2Rpdj4nOwogICAgaWYgKGNvdW50RWwpIGNvdW50RWwudGV4dENvbnRlbnQgPSAn5Yqg6L295Lit4oCmJzsKICB9CiAg
;ZnVuY3Rpb24gcmVxdWVzdFN5c0luZm8oZm9yY2UpIHsKICAgIGZvcmNlID0gISFmb3JjZTsKICAgIGNvbnN0IG15R2VuID0gKytpbmZvUmVxR2VuOwogICAg
;Y2xlYXJJbmZvTG9hZFdhaXQoKTsKICAgIC8vIOe8k+WtmOWRveS4remAmuW4uOW+iOW/q++8m+i2hei/h+e6piAwLjRzIOWGjeWHuuWKoOi9veWKqOeUu++8
;jOmBv+WFjemXquS4gOS4iwogICAgaWYgKGZvcmNlIHx8ICFpbmZvRGF0YSkgewogICAgICBpbmZvTG9hZFRpbWVyID0gc2V0VGltZW91dCgoKSA9PiB7CiAg
;ICAgICAgaW5mb0xvYWRUaW1lciA9IDA7CiAgICAgICAgaWYgKG15R2VuICE9PSBpbmZvUmVxR2VuIHx8IGFwcE1vZGUgIT09ICdpbmZvJykgcmV0dXJuOwog
;ICAgICAgIHNob3dJbmZvTG9hZGluZygpOwogICAgICB9LCA0MDApOwogICAgfQogICAgcG9zdCgnc3lzSW5mb3wnICsgKGZvcmNlID8gJzEnIDogJzAnKSk7
;CiAgfQogIGNvbnN0IEhBTkRMRV9ISVNUX0tFWSA9ICdhaGtfaGFuZGxlX3NlYXJjaF9oaXN0X3YxJzsKICBjb25zdCBIQU5ETEVfSElTVF9NQVggPSAxMDsK
;ICBjb25zdCBoYW5kbGVIaXN0TGlzdCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdoYW5kbGUtaGlzdC1saXN0Jyk7CiAgZnVuY3Rpb24gbG9hZEhhbmRs
;ZUhpc3QoKSB7CiAgICB0cnkgewogICAgICBjb25zdCByYXcgPSBsb2NhbFN0b3JhZ2UuZ2V0SXRlbShIQU5ETEVfSElTVF9LRVkpOwogICAgICBjb25zdCBh
;cnIgPSByYXcgPyBKU09OLnBhcnNlKHJhdykgOiBbXTsKICAgICAgcmV0dXJuIEFycmF5LmlzQXJyYXkoYXJyKSA/IGFyci5maWx0ZXIoeCA9PiBTdHJpbmco
;eCB8fCAnJykudHJpbSgpKSA6IFtdOwogICAgfSBjYXRjaCAoXykgeyByZXR1cm4gW107IH0KICB9CiAgZnVuY3Rpb24gc2F2ZUhhbmRsZUhpc3QocSkgewog
;ICAgcSA9IFN0cmluZyhxIHx8ICcnKS50cmltKCk7CiAgICBpZiAoIXEpIHJldHVybjsKICAgIGxldCBhcnIgPSBsb2FkSGFuZGxlSGlzdCgpLmZpbHRlcih4
;ID0+IHggIT09IHEpOwogICAgYXJyLnVuc2hpZnQocSk7CiAgICBpZiAoYXJyLmxlbmd0aCA+IEhBTkRMRV9ISVNUX01BWCkgYXJyID0gYXJyLnNsaWNlKDAs
;IEhBTkRMRV9ISVNUX01BWCk7CiAgICB0cnkgeyBsb2NhbFN0b3JhZ2Uuc2V0SXRlbShIQU5ETEVfSElTVF9LRVksIEpTT04uc3RyaW5naWZ5KGFycikpOyB9
;IGNhdGNoIChfKSB7fQogICAgcmVuZGVySGFuZGxlSGlzdCgpOwogIH0KICBmdW5jdGlvbiByZW5kZXJIYW5kbGVIaXN0KCkgewogICAgaWYgKCFoYW5kbGVI
;aXN0TGlzdCkgcmV0dXJuOwogICAgaGFuZGxlSGlzdExpc3QuaW5uZXJIVE1MID0gbG9hZEhhbmRsZUhpc3QoKS5tYXAocSA9PgogICAgICAnPG9wdGlvbiB2
;YWx1ZT0iJyArIGVzY2FwZUh0bWwocSkgKyAnIj48L29wdGlvbj4nCiAgICApLmpvaW4oJycpOwogIH0KICBmdW5jdGlvbiBub3JtYWxpemVQb3J0UXVlcnko
;cSkgewogICAgcSA9IFN0cmluZyhxIHx8ICcnKS50cmltKCk7CiAgICBjb25zdCBtID0gcS5tYXRjaCgvXlwv56uv5Y+jXHMqKC4qKSQvaSkgfHwgcS5tYXRj
;aCgvXlwvcG9ydFxzKiguKikkL2kpOwogICAgaWYgKG0pIHEgPSBTdHJpbmcobVsxXSB8fCAnJykudHJpbSgpOwogICAgcmV0dXJuIHE7CiAgfQogIGZ1bmN0
;aW9uIGlzUG9ydFNlYXJjaFF1ZXJ5KHEpIHsKICAgIHEgPSBub3JtYWxpemVQb3J0UXVlcnkocSk7CiAgICByZXR1cm4gISFxICYmIC9eW1xkXHN8XC1dKyQv
;LnRlc3QocSkgJiYgL1xkLy50ZXN0KHEpOwogIH0KICBmdW5jdGlvbiBwYXJzZVBvcnRMaXN0KHEpIHsKICAgIHEgPSBub3JtYWxpemVQb3J0UXVlcnkocSk7
;CiAgICBjb25zdCBvdXQgPSBbXSwgc2VlbiA9IG5ldyBTZXQoKTsKICAgIGNvbnN0IGFkZCA9IChwKSA9PiB7CiAgICAgIHAgPSBOdW1iZXIocCk7CiAgICAg
;IGlmICghTnVtYmVyLmlzSW50ZWdlcihwKSB8fCBwIDwgMCB8fCBwID4gNjU1MzUgfHwgc2Vlbi5oYXMocCkpIHJldHVybjsKICAgICAgc2Vlbi5hZGQocCk7
;CiAgICAgIG91dC5wdXNoKHApOwogICAgfTsKICAgIGZvciAoY29uc3QgcGFydCBvZiBTdHJpbmcocSkuc3BsaXQoJ3wnKSkgewogICAgICBjb25zdCBzID0g
;U3RyaW5nKHBhcnQgfHwgJycpLnRyaW0oKTsKICAgICAgaWYgKCFzKSBjb250aW51ZTsKICAgICAgY29uc3QgbSA9IHMubWF0Y2goL14oXGQrKVxzKi1ccyoo
;XGQrKSQvKTsKICAgICAgaWYgKG0pIHsKICAgICAgICBsZXQgYSA9IHBhcnNlSW50KG1bMV0sIDEwKSwgYiA9IHBhcnNlSW50KG1bMl0sIDEwKTsKICAgICAg
;ICBpZiAoYSA+IGIpIHsgY29uc3QgdCA9IGE7IGEgPSBiOyBiID0gdDsgfQogICAgICAgIGEgPSBNYXRoLm1heCgwLCBNYXRoLm1pbig2NTUzNSwgYSkpOwog
;ICAgICAgIGIgPSBNYXRoLm1heCgwLCBNYXRoLm1pbig2NTUzNSwgYikpOwogICAgICAgIGZvciAobGV0IHAgPSBhOyBwIDw9IGI7IHArKykgYWRkKHApOwog
;ICAgICB9IGVsc2UgaWYgKC9eXGQrJC8udGVzdChzKSkgewogICAgICAgIGFkZChwYXJzZUludChzLCAxMCkpOwogICAgICB9CiAgICB9CiAgICByZXR1cm4g
;b3V0OwogIH0KICBmdW5jdGlvbiBpc0FsbFBvcnRzUXVlcnlUZXh0KHEpIHsKICAgIHEgPSBTdHJpbmcocSB8fCAnJykudHJpbSgpOwogICAgcmV0dXJuICFx
;IHx8IHEgPT09IERFRkFVTFRfUE9SVF9RVUVSWSB8fCAvXjBccyotXHMqNjU1MzUkLy50ZXN0KHEpOwogIH0KICBmdW5jdGlvbiByZXF1ZXN0SGFuZGxlU2Vh
;cmNoKHEpIHsKICAgIHEgPSBTdHJpbmcocSB8fCAnJykudHJpbSgpOwogICAgLy8g56m65qGGIC8g5YWo56uv5Y+jIOKGkiDnm7TmjqXmmL7npLrlhajpg6jo
;v57mjqXvvIzkuI3miormnaHku7blhpnov5vovpPlhaXmoYYKICAgIGlmIChpc0FsbFBvcnRzUXVlcnlUZXh0KHEpKSB7CiAgICAgIGhhbmRsZVF1ZXJ5ID0g
;REVGQVVMVF9QT1JUX1FVRVJZOwogICAgICBoYW5kbGVNb2RlID0gJ3BvcnQnOwogICAgICBoYW5kbGVCdXN5ID0gdHJ1ZTsKICAgICAgaWYgKGhhbmRsZVN0
;YXR1cykgaGFuZGxlU3RhdHVzLnRleHRDb250ZW50ID0gJ+ato+WcqOafpeivouKApic7CiAgICAgIGhhbmRsZUJhbm5lci5jbGFzc0xpc3QuYWRkKCdvbicp
;OwogICAgICBoYW5kbGVCYW5uZXIudGV4dENvbnRlbnQgPSAn5YWo6YOo6L+e5o6lJzsKICAgICAgaGFuZGxlU2VsS2V5cy5jbGVhcigpOwogICAgICBoYW5k
;bGVBbmNob3JLZXkgPSAnJzsKICAgICAgc3luY0hhbmRsZUJhcigwKTsKICAgICAgc2hvd0hhbmRsZUxvYWRpbmcoJ+ato+WcqOafpeivouerr+WPo+WNoOeU
;qO+8jOivt+eojeWAmeKApicpOwogICAgICBwb3N0KCdoYW5kbGVTZWFyY2h8JyArIERFRkFVTFRfUE9SVF9RVUVSWSk7CiAgICAgIHJldHVybjsKICAgIH0K
;ICAgIGhhbmRsZVF1ZXJ5ID0gcTsKICAgIGhhbmRsZU1vZGUgPSBpc1BvcnRTZWFyY2hRdWVyeShxKSA/ICdwb3J0JyA6ICdoYW5kbGUnOwogICAgaWYgKGhh
;bmRsZU1vZGUgPT09ICdwb3J0JyAmJiAhcGFyc2VQb3J0TGlzdChxKS5sZW5ndGgpIHsKICAgICAgaGFuZGxlSXRlbXMgPSBbXTsKICAgICAgcmVuZGVySGFu
;ZGxlVGFibGUoJ+err+WPo+aXoOaViO+8jOekuuS+i++8mjgwODB8ODAg5oiWIDAtMzAwfDUwMCcpOwogICAgICByZXR1cm47CiAgICB9CiAgICBzYXZlSGFu
;ZGxlSGlzdChxKTsKICAgIGhhbmRsZUJ1c3kgPSB0cnVlOwogICAgaWYgKGhhbmRsZVN0YXR1cykgaGFuZGxlU3RhdHVzLnRleHRDb250ZW50ID0gJ+ato+Wc
;qOafpeivouKApic7CiAgICBoYW5kbGVCYW5uZXIuY2xhc3NMaXN0LmFkZCgnb24nKTsKICAgIGhhbmRsZUJhbm5lci50ZXh0Q29udGVudCA9ICfigJwnICsg
;cSArICfigJ3nmoTmkJzntKLnu5PmnpwnOwogICAgaGFuZGxlU2VsS2V5cy5jbGVhcigpOwogICAgaGFuZGxlQW5jaG9yS2V5ID0gJyc7CiAgICBzeW5jSGFu
;ZGxlQmFyKDApOwogICAgc2hvd0hhbmRsZUxvYWRpbmcoaGFuZGxlTW9kZSA9PT0gJ3BvcnQnID8gJ+ato+WcqOafpeivouerr+WPo+WNoOeUqO+8jOivt+eo
;jeWAmeKApicgOiAn5q2j5Zyo5p+l6K+i5Y+l5p+E77yM6K+356iN5YCZ4oCmJyk7CiAgICBwb3N0KCdoYW5kbGVTZWFyY2h8JyArIHEpOwogIH0KICBmdW5j
;dGlvbiBzaG93SGFuZGxlTG9hZGluZyhtc2cpIHsKICAgIGhhbmRsZUJvZHkuaW5uZXJIVE1MID0gJzxkaXYgY2xhc3M9ImhhbmRsZS1sb2FkaW5nIj48ZGl2
;IGNsYXNzPSJoYW5kbGUtc3Bpbm5lciIgYXJpYS1oaWRkZW49InRydWUiPjwvZGl2PjxkaXY+JwogICAgICArIGVzY2FwZUh0bWwobXNnIHx8ICfmraPlnKjm
;n6Xor6Llj6Xmn4TvvIzor7fnqI3lgJnigKYnKSArICc8L2Rpdj48L2Rpdj4nOwogIH0KICBmdW5jdGlvbiBzb3J0SGFuZGxlSXRlbXMoaXRlbXMpIHsKICAg
;IGNvbnN0IGtleSA9IGhhbmRsZVNvcnRLZXkgfHwgKGhhbmRsZU1vZGUgPT09ICdwb3J0JyA/ICdscG9ydCcgOiAnbmFtZScpOwogICAgY29uc3QgZGlyID0g
;aGFuZGxlU29ydERpciB8fCAxOwogICAgcmV0dXJuIChpdGVtcyB8fCBbXSkuc2xpY2UoKS5zb3J0KChhLCBiKSA9PiB7CiAgICAgIGxldCBjbXAgPSAwOwog
;ICAgICBpZiAoa2V5ID09PSAncGlkJykgewogICAgICAgIGNtcCA9IChOdW1iZXIoYS5waWQpIHx8IDApIC0gKE51bWJlcihiLnBpZCkgfHwgMCk7CiAgICAg
;IH0gZWxzZSBpZiAoa2V5ID09PSAnbHBvcnQnKSB7CiAgICAgICAgY21wID0gKE51bWJlcihhLmxvY2FsUG9ydCkgfHwgMCkgLSAoTnVtYmVyKGIubG9jYWxQ
;b3J0KSB8fCAwKTsKICAgICAgfSBlbHNlIGlmIChrZXkgPT09ICdycG9ydCcpIHsKICAgICAgICBjbXAgPSAoTnVtYmVyKGEucmVtb3RlUG9ydCkgfHwgMCkg
;LSAoTnVtYmVyKGIucmVtb3RlUG9ydCkgfHwgMCk7CiAgICAgIH0gZWxzZSBpZiAoa2V5ID09PSAndHlwZScpIHsKICAgICAgICBjbXAgPSBTdHJpbmcoYS50
;eXBlIHx8ICcnKS5sb2NhbGVDb21wYXJlKFN0cmluZyhiLnR5cGUgfHwgJycpLCAnZW4nLCB7IHNlbnNpdGl2aXR5OiAnYmFzZScgfSk7CiAgICAgIH0gZWxz
;ZSBpZiAoa2V5ID09PSAnaGFuZGxlJykgewogICAgICAgIGNtcCA9IFN0cmluZyhhLmhhbmRsZSB8fCAnJykubG9jYWxlQ29tcGFyZShTdHJpbmcoYi5oYW5k
;bGUgfHwgJycpLCAnemgtQ04nKTsKICAgICAgfSBlbHNlIHsKICAgICAgICBjbXAgPSBjb21wYXJlUHJvY05hbWUoYS5uYW1lIHx8ICcnLCBiLm5hbWUgfHwg
;JycpOwogICAgICB9CiAgICAgIGlmIChjbXApIHJldHVybiBjbXAgKiBkaXI7CiAgICAgIC8vIOasoeimgemUru+8muerr+WPo+aooeW8j+S8mOWFiOacrOac
;uuerr+WPo++8jOWGjSBQSUQgLyDlkI3np7AKICAgICAgY29uc3QgbHAgPSAoTnVtYmVyKGEubG9jYWxQb3J0KSB8fCAwKSAtIChOdW1iZXIoYi5sb2NhbFBv
;cnQpIHx8IDApOwogICAgICBpZiAobHApIHJldHVybiBscDsKICAgICAgY29uc3QgcGEgPSAoTnVtYmVyKGEucGlkKSB8fCAwKSAtIChOdW1iZXIoYi5waWQp
;IHx8IDApOwogICAgICBpZiAocGEpIHJldHVybiBwYTsKICAgICAgcmV0dXJuIGNvbXBhcmVQcm9jTmFtZShhLm5hbWUgfHwgJycsIGIubmFtZSB8fCAnJyk7
;CiAgICB9KTsKICB9CiAgZnVuY3Rpb24gc3luY0hhbmRsZUhlYWRTb3J0KCkgewogICAgaWYgKCFoYW5kbGVIZWFkKSByZXR1cm47CiAgICBoYW5kbGVIZWFk
;LnF1ZXJ5U2VsZWN0b3JBbGwoJy5oYW5kbGUtaGNlbGxbZGF0YS1zb3J0XScpLmZvckVhY2goY2VsbCA9PiB7CiAgICAgIGNvbnN0IGsgPSBjZWxsLmdldEF0
;dHJpYnV0ZSgnZGF0YS1zb3J0Jyk7CiAgICAgIGNvbnN0IG9uID0gayA9PT0gaGFuZGxlU29ydEtleTsKICAgICAgY2VsbC5jbGFzc0xpc3QudG9nZ2xlKCdz
;b3J0ZWQnLCBvbik7CiAgICAgIGNlbGwuY2xhc3NMaXN0LnRvZ2dsZSgnYXNjJywgb24gJiYgaGFuZGxlU29ydERpciA+IDApOwogICAgICBjZWxsLmNsYXNz
;TGlzdC50b2dnbGUoJ2Rlc2MnLCBvbiAmJiBoYW5kbGVTb3J0RGlyIDwgMCk7CiAgICB9KTsKICB9CiAgZnVuY3Rpb24gYmluZEhhbmRsZUhlYWRTb3J0KCkg
;ewogICAgaWYgKCFoYW5kbGVIZWFkIHx8IGhhbmRsZUhlYWQuZGF0YXNldC5zb3J0Qm91bmQgPT09ICcxJykgcmV0dXJuOwogICAgaGFuZGxlSGVhZC5kYXRh
;c2V0LnNvcnRCb3VuZCA9ICcxJzsKICAgIGhhbmRsZUhlYWQucXVlcnlTZWxlY3RvckFsbCgnLmhhbmRsZS1oY2VsbFtkYXRhLXNvcnRdJykuZm9yRWFjaChj
;ZWxsID0+IHsKICAgICAgY2VsbC5hZGRFdmVudExpc3RlbmVyKCdjbGljaycsIChlKSA9PiB7CiAgICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOwogICAgICAg
;IGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAgICAgY29uc3QgayA9IGNlbGwuZ2V0QXR0cmlidXRlKCdkYXRhLXNvcnQnKTsKICAgICAgICBpZiAoIWspIHJl
;dHVybjsKICAgICAgICBpZiAoaGFuZGxlU29ydEtleSA9PT0gaykgaGFuZGxlU29ydERpciA9IC1oYW5kbGVTb3J0RGlyOwogICAgICAgIGVsc2UgewogICAg
;ICAgICAgaGFuZGxlU29ydEtleSA9IGs7CiAgICAgICAgICBoYW5kbGVTb3J0RGlyID0gKGsgPT09ICdscG9ydCcgfHwgayA9PT0gJ3Jwb3J0JyB8fCBrID09
;PSAncGlkJykgPyAxIDogMTsKICAgICAgICB9CiAgICAgICAgaWYgKGhhbmRsZUl0ZW1zLmxlbmd0aCkgcmVuZGVySGFuZGxlVGFibGUoKTsKICAgICAgICBl
;bHNlIHN5bmNIYW5kbGVIZWFkU29ydCgpOwogICAgICB9KTsKICAgIH0pOwogIH0KICBiaW5kSGFuZGxlSGVhZFNvcnQoKTsKICBmdW5jdGlvbiBwb3J0VGlw
;VGV4dChpdCkgewogICAgY29uc3QgbGlwID0gU3RyaW5nKGl0LmxvY2FsSXAgfHwgJzAuMC4wLjAnKTsKICAgIGNvbnN0IGxwb3J0ID0gKGl0LmxvY2FsUG9y
;dCA9PSBudWxsIHx8IE51bWJlcihpdC5sb2NhbFBvcnQpIDwgMCkgPyAnJyA6IFN0cmluZyhpdC5sb2NhbFBvcnQpOwogICAgY29uc3QgcmlwID0gU3RyaW5n
;KGl0LnJlbW90ZUlwIHx8ICcwLjAuMC4wJyk7CiAgICBjb25zdCBycG9ydCA9IChpdC5yZW1vdGVQb3J0ID09IG51bGwgfHwgTnVtYmVyKGl0LnJlbW90ZVBv
;cnQpIDwgMCkgPyAnJyA6IFN0cmluZyhpdC5yZW1vdGVQb3J0KTsKICAgIHJldHVybiAn5pys5py677yaJyArIGxpcCArICc6JyArIGxwb3J0ICsgJ1xu6L+c
;56iL77yaJyArIHJpcCArICc6JyArIHJwb3J0OwogIH0KICBmdW5jdGlvbiBzZXRIYW5kbGVQb3J0TW9kZShvbikgewogICAgZG9jdW1lbnQucXVlcnlTZWxl
;Y3RvckFsbCgnLmhhbmRsZS1jb2xzJykuZm9yRWFjaChlbCA9PiBlbC5jbGFzc0xpc3QudG9nZ2xlKCdwb3J0LW1vZGUnLCAhIW9uKSk7CiAgICBkb2N1bWVu
;dC5xdWVyeVNlbGVjdG9yQWxsKCcuaGFuZGxlLWNvbC1wb3J0LC5oYW5kbGUtY29sLXJwb3J0JykuZm9yRWFjaChlbCA9PiBlbC5jbGFzc0xpc3QudG9nZ2xl
;KCdoaWRkZW4nLCAhb24pKTsKICB9CiAgZnVuY3Rpb24gZGVkdXBlUG9ydEl0ZW1zKGl0ZW1zKSB7CiAgICBjb25zdCBvdXQgPSBbXSwgc2VlbiA9IG5ldyBT
;ZXQoKTsKICAgIGZvciAoY29uc3QgaXQgb2YgaXRlbXMgfHwgW10pIHsKICAgICAgY29uc3Qga2V5ID0gWwogICAgICAgIE51bWJlcihpdC5waWQpIHx8IDAs
;CiAgICAgICAgU3RyaW5nKGl0LnR5cGUgfHwgJycpLnRvVXBwZXJDYXNlKCksCiAgICAgICAgTnVtYmVyKGl0LmxvY2FsUG9ydCkgfHwgMCwKICAgICAgICBO
;dW1iZXIoaXQucmVtb3RlUG9ydCkgfHwgMCwKICAgICAgICBTdHJpbmcoaXQuaGFuZGxlIHx8ICcnKQogICAgICBdLmpvaW4oJ3wnKTsKICAgICAgaWYgKHNl
;ZW4uaGFzKGtleSkpIGNvbnRpbnVlOwogICAgICBzZWVuLmFkZChrZXkpOwogICAgICBvdXQucHVzaChpdCk7CiAgICB9CiAgICByZXR1cm4gb3V0OwogIH0K
;ICBmdW5jdGlvbiBmb3JtYXRIYW5kbGVCYW5uZXIocSwgcG9ydE1vZGUpIHsKICAgIGNvbnN0IGtleSA9IFN0cmluZyhxIHx8ICcnKS50cmltKCk7CiAgICBp
;ZiAoIWtleSkgcmV0dXJuICcnOwogICAgaWYgKHBvcnRNb2RlICYmIChrZXkgPT09IERFRkFVTFRfUE9SVF9RVUVSWSB8fCAvXjBccyotXHMqNjU1MzUkLy50
;ZXN0KGtleSkpKQogICAgICByZXR1cm4gJ+err+WPo+aQnOe0ou+8muWFqOmDqOi/nuaOpSc7CiAgICBpZiAocG9ydE1vZGUpCiAgICAgIHJldHVybiAn56uv
;5Y+j5pCc57Si5YWz6ZSu5a2X77yaJyArIGtleTsKICAgIHJldHVybiAn5Y+l5p+E5pCc57Si5YWz6ZSu5a2X77yaJyArIGtleTsKICB9CiAgZnVuY3Rpb24g
;cmVuZGVySGFuZGxlVGFibGUoZW1wdHlNc2cpIHsKICAgIGNvbnN0IHEgPSBoYW5kbGVRdWVyeTsKICAgIGNvbnN0IHBvcnRNb2RlID0gaGFuZGxlTW9kZSA9
;PT0gJ3BvcnQnOwogICAgc2V0SGFuZGxlUG9ydE1vZGUocG9ydE1vZGUpOwogICAgaWYgKHEpIHsKICAgICAgaGFuZGxlQmFubmVyLmNsYXNzTGlzdC5hZGQo
;J29uJyk7CiAgICAgIGhhbmRsZUJhbm5lci50ZXh0Q29udGVudCA9IGZvcm1hdEhhbmRsZUJhbm5lcihxLCBwb3J0TW9kZSk7CiAgICB9IGVsc2UgewogICAg
;ICBoYW5kbGVCYW5uZXIuY2xhc3NMaXN0LnJlbW92ZSgnb24nKTsKICAgICAgaGFuZGxlQmFubmVyLnRleHRDb250ZW50ID0gJyc7CiAgICB9CiAgICBpZiAo
;aGFuZGxlQnVzeSAmJiAhaGFuZGxlSXRlbXMubGVuZ3RoKSB7CiAgICAgIHNob3dIYW5kbGVMb2FkaW5nKGVtcHR5TXNnIHx8IChwb3J0TW9kZSA/ICfmraPl
;nKjmn6Xor6Lnq6/lj6PigKYnIDogJ+ato+WcqOafpeivouWPpeafhOKApicpKTsKICAgICAgc3luY0hhbmRsZUJhcigwKTsKICAgICAgc3luY0hhbmRsZUhl
;YWRTb3J0KCk7CiAgICAgIHJldHVybjsKICAgIH0KICAgIGlmIChwb3J0TW9kZSkgaGFuZGxlSXRlbXMgPSBkZWR1cGVQb3J0SXRlbXMoaGFuZGxlSXRlbXMp
;OwogICAgaGFuZGxlSXRlbXMgPSBzb3J0SGFuZGxlSXRlbXMoaGFuZGxlSXRlbXMpOwogICAgc3luY0hhbmRsZUhlYWRTb3J0KCk7CiAgICBjb25zdCBuID0g
;aGFuZGxlSXRlbXMubGVuZ3RoOwogICAgc3luY0hhbmRsZUJhcihuKTsKICAgIGlmICghbikgewogICAgICBjb25zdCBkZWZhdWx0RW1wdHkgPSBxCiAgICAg
;ICAgPyAocG9ydE1vZGUKICAgICAgICAgID8gKCfnq6/lj6PmkJzntKLlhbPplK7lrZfvvJonICsgcSArICcg4oCUIOayoeacieWMuemFjeeahOerr+WPoycp
;CiAgICAgICAgICA6ICgn5Y+l5p+E5pCc57Si5YWz6ZSu5a2X77yaJyArIHEgKyAnIOKAlCDmsqHmnInljLnphY3nmoTlj6Xmn4QnKSkKICAgICAgICA6IChw
;b3J0TW9kZQogICAgICAgICAgPyAn56uv5Y+j5pCc57Si77ya6L6T5YWl56uv5Y+j5aaCIDgwODB8ODAg5oiWIDAtMzAwfDUwMCcKICAgICAgICAgIDogJ+WP
;peafhOaQnOe0ou+8mui+k+WFpeWFs+mUruWtl+aQnOaWh+S7tuWPpeafhCcpOwogICAgICBoYW5kbGVCb2R5LmlubmVySFRNTCA9ICc8ZGl2IGNsYXNzPSJo
;YW5kbGUtZW1wdHkiPicgKyBlc2NhcGVIdG1sKGVtcHR5TXNnIHx8IGRlZmF1bHRFbXB0eSkgKyAnPC9kaXY+JzsKICAgICAgaGFuZGxlU2VsS2V5cy5jbGVh
;cigpOwogICAgICBoYW5kbGVBbmNob3JLZXkgPSAnJzsKICAgICAgcmV0dXJuOwogICAgfQogICAgY29uc3Qga2VlcCA9IG5ldyBTZXQoKTsKICAgIGNvbnN0
;IGZyYWcgPSBkb2N1bWVudC5jcmVhdGVEb2N1bWVudEZyYWdtZW50KCk7CiAgICBmb3IgKGxldCBpID0gMDsgaSA8IGhhbmRsZUl0ZW1zLmxlbmd0aDsgaSsr
;KSB7CiAgICAgIGNvbnN0IGl0ID0gaGFuZGxlSXRlbXNbaV07CiAgICAgIGNvbnN0IHJvdyA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOwogICAg
;ICBjb25zdCBrZXkgPSBoYW5kbGVSb3dLZXkoaXQsIGkpOwogICAgICBrZWVwLmFkZChrZXkpOwogICAgICByb3cuY2xhc3NOYW1lID0gJ2hhbmRsZS1yb3cg
;aGFuZGxlLWNvbHMnICsgKHBvcnRNb2RlID8gJyBwb3J0LW1vZGUnIDogJycpICsgKGhhbmRsZVNlbEtleXMuaGFzKGtleSkgPyAnIG9uJyA6ICcnKTsKICAg
;ICAgcm93LnNldEF0dHJpYnV0ZSgnZGF0YS1rZXknLCBrZXkpOwogICAgICByb3cuc2V0QXR0cmlidXRlKCdkYXRhLXBpZCcsIFN0cmluZyhOdW1iZXIoaXQu
;cGlkKSB8fCAwKSk7CiAgICAgIHJvdy5zZXRBdHRyaWJ1dGUoJ2RhdGEtbmFtZScsIFN0cmluZyhpdC5uYW1lIHx8ICcnKSk7CiAgICAgIHJvdy5zZXRBdHRy
;aWJ1dGUoJ2RhdGEtcGF0aCcsIFN0cmluZyhpdC5wYXRoIHx8ICcnKSk7CiAgICAgIGNvbnN0IG5hbWUgPSBTdHJpbmcoaXQubmFtZSB8fCAnJyk7CiAgICAg
;IGNvbnN0IHBpZE51bSA9IE51bWJlcihpdC5waWQpOwogICAgICBjb25zdCBwaWQgPSBOdW1iZXIuaXNGaW5pdGUocGlkTnVtKSAmJiBwaWROdW0gPiAwID8g
;U3RyaW5nKHBpZE51bSkgOiAnJzsKICAgICAgY29uc3QgdHlwID0gU3RyaW5nKGl0LnR5cGUgfHwgJycpOwogICAgICBjb25zdCBobmFtZSA9IFN0cmluZyhp
;dC5oYW5kbGUgfHwgJycpOwogICAgICBjb25zdCBscG9ydCA9IChpdC5sb2NhbFBvcnQgPT0gbnVsbCB8fCBOdW1iZXIoaXQubG9jYWxQb3J0KSA8IDApID8g
;JycgOiBTdHJpbmcoaXQubG9jYWxQb3J0KTsKICAgICAgY29uc3QgcnBvcnROdW0gPSBOdW1iZXIoaXQucmVtb3RlUG9ydCk7CiAgICAgIGNvbnN0IHJwb3J0
;ID0gTnVtYmVyLmlzRmluaXRlKHJwb3J0TnVtKSAmJiBycG9ydE51bSA+IDAgPyBTdHJpbmcocnBvcnROdW0pIDogKHBvcnRNb2RlID8gJ+KAlCcgOiAnJyk7
;CiAgICAgIGNvbnN0IHRpcCA9IHBvcnRNb2RlID8gcG9ydFRpcFRleHQoaXQpIDogKGl0LnBhdGggfHwgbmFtZSk7CiAgICAgIGNvbnN0IGxIb3QgPSBwb3J0
;TW9kZSAmJiBscG9ydCAhPT0gJycgJiYgcG9ydElzSG90KGxwb3J0KSA/ICcgcG9ydC1ob3QnIDogJyc7CiAgICAgIGNvbnN0IHJIb3QgPSBwb3J0TW9kZSAm
;JiBycG9ydCAhPT0gJ+KAlCcgJiYgcnBvcnQgIT09ICcnICYmIHBvcnRJc0hvdChycG9ydCkgPyAnIHBvcnQtaG90JyA6ICcnOwogICAgICBjb25zdCBjb25u
;ZWN0ZWQgPSBwb3J0TW9kZSAmJiAoaG5hbWUgPT09ICfov57mjqUnIHx8IC9lc3RhYmxpc2hlZC9pLnRlc3QoaG5hbWUpKTsKICAgICAgY29uc3QgbmV0RG90
;ID0gY29ubmVjdGVkID8gJzxzcGFuIGNsYXNzPSJoYW5kbGUtbmV0LWRvdCIgdGl0bGU9IuW3sui/nuaOpSI+PC9zcGFuPicgOiAnJzsKICAgICAgY29uc3Qg
;aWNvID0gaXQuaWNvbgogICAgICAgID8gJzxpbWcgc3JjPSInICsgZXNjYXBlSHRtbChTdHJpbmcoaXQuaWNvbikpICsgJyIgYWx0PSIiIG9uZXJyb3I9InRo
;aXMub25lcnJvcj1udWxsO3RoaXMucmVwbGFjZVdpdGgoT2JqZWN0LmFzc2lnbihkb2N1bWVudC5jcmVhdGVFbGVtZW50KFwnc3BhblwnKSx7Y2xhc3NOYW1l
;OlwnaGFuZGxlLWljby1waFwnfSkpIj4nCiAgICAgICAgOiAnPHNwYW4gY2xhc3M9ImhhbmRsZS1pY28tcGgiIGFyaWEtaGlkZGVuPSJ0cnVlIj48L3NwYW4+
;JzsKICAgICAgcm93LmlubmVySFRNTCA9CiAgICAgICAgJzxkaXYgY2xhc3M9ImhhbmRsZS1uYW1lIiB0aXRsZT0iJyArIGVzY2FwZUh0bWwoaXQucGF0aCB8
;fCBuYW1lKSArICciPicgKyBpY28gKyAnPHNwYW4+JyArIGVzY2FwZUh0bWwobmFtZSkgKyAnPC9zcGFuPjwvZGl2PicKICAgICAgICArICc8ZGl2PicgKyBl
;c2NhcGVIdG1sKHBpZCkgKyAnPC9kaXY+JwogICAgICAgICsgKHBvcnRNb2RlCiAgICAgICAgICA/ICgnPGRpdiBjbGFzcz0iaGFuZGxlLWNvbC1wb3J0JyAr
;IGxIb3QgKyAnIiB0aXRsZT0iJyArIGVzY2FwZUh0bWwodGlwKSArICciPicgKyBlc2NhcGVIdG1sKGxwb3J0KSArICc8L2Rpdj4nCiAgICAgICAgICAgICsg
;JzxkaXYgY2xhc3M9ImhhbmRsZS1jb2wtcnBvcnQnICsgckhvdCArICciIHRpdGxlPSInICsgZXNjYXBlSHRtbCh0aXApICsgJyI+JyArIGVzY2FwZUh0bWwo
;cnBvcnQpICsgJzwvZGl2PicpCiAgICAgICAgICA6ICcnKQogICAgICAgICsgJzxkaXY+JyArIGVzY2FwZUh0bWwodHlwKSArICc8L2Rpdj4nCiAgICAgICAg
;KyAnPGRpdiBjbGFzcz0iaGFuZGxlLXN0YXRlIiB0aXRsZT0iJyArIGVzY2FwZUh0bWwocG9ydE1vZGUgPyB0aXAgOiBobmFtZSkgKyAnIj4nICsgbmV0RG90
;ICsgJzxzcGFuPicgKyBlc2NhcGVIdG1sKGhuYW1lKSArICc8L3NwYW4+PC9kaXY+JzsKICAgICAgaWYgKHBvcnRNb2RlKSByb3cudGl0bGUgPSB0aXA7CiAg
;ICAgIHJvdy5vbmNsaWNrID0gKGUpID0+IHNlbGVjdEhhbmRsZUZyb21FdmVudChlLCByb3cpOwogICAgICByb3cub25jb250ZXh0bWVudSA9IChlKSA9PiB7
;CiAgICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOwogICAgICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAgICAgY29uc3QgayA9IHJvdy5nZXRBdHRyaWJ1
;dGUoJ2RhdGEta2V5Jyk7CiAgICAgICAgaWYgKCFoYW5kbGVTZWxLZXlzLmhhcyhrKSkgewogICAgICAgICAgaGFuZGxlU2VsS2V5cy5jbGVhcigpOwogICAg
;ICAgICAgaGFuZGxlU2VsS2V5cy5hZGQoayk7CiAgICAgICAgICBoYW5kbGVBbmNob3JLZXkgPSBrOwogICAgICAgICAgcmVmcmVzaEhhbmRsZVNlbGVjdGlv
;blVJKCk7CiAgICAgICAgfQogICAgICAgIHNob3dQcm9jTWVudShlLmNsaWVudFgsIGUuY2xpZW50WSwgY29sbGVjdEhhbmRsZVRhcmdldHMoKSk7CiAgICAg
;IH07CiAgICAgIHJvdy5vbmRibGNsaWNrID0gKCkgPT4gewogICAgICAgIGNvbnN0IHQgPSBwb3J0TW9kZSA/IHRpcCA6IChobmFtZSB8fCBuYW1lKTsKICAg
;ICAgICB0cnkgeyBuYXZpZ2F0b3IuY2xpcGJvYXJkLndyaXRlVGV4dCh0KTsgfSBjYXRjaCAoXykgeyBwb3N0KCdjb3B5VGV4dHwnICsgdCk7IH0KICAgICAg
;fTsKICAgICAgZnJhZy5hcHBlbmRDaGlsZChyb3cpOwogICAgfQogICAgZm9yIChjb25zdCBrIG9mIEFycmF5LmZyb20oaGFuZGxlU2VsS2V5cykpIHsKICAg
;ICAgaWYgKCFrZWVwLmhhcyhrKSkgaGFuZGxlU2VsS2V5cy5kZWxldGUoayk7CiAgICB9CiAgICBoYW5kbGVCb2R5LmlubmVySFRNTCA9ICcnOwogICAgaGFu
;ZGxlQm9keS5hcHBlbmRDaGlsZChmcmFnKTsKICB9CiAgZnVuY3Rpb24gc3luY0hhbmRsZUJhcihuKSB7CiAgICBpZiAoYXBwTW9kZSA9PT0gJ2hhbmRsZScp
;CiAgICAgIGNvdW50RWwudGV4dENvbnRlbnQgPSAn5YWxICcgKyAoTnVtYmVyKG4pIHx8IDApICsgJyDmnaEnOwogIH0KICBmdW5jdGlvbiBoYW5kbGVSb3dL
;ZXkoaXQsIGlkeCkgewogICAgcmV0dXJuIFtpdC5waWQsIGl0LnR5cGUsIGl0LmhhbmRsZSwgaXQubG9jYWxQb3J0LCBpdC5yZW1vdGVQb3J0LCBpZHhdLmpv
;aW4oJ3wnKTsKICB9CiAgZnVuY3Rpb24gcmVmcmVzaEhhbmRsZVNlbGVjdGlvblVJKCkgewogICAgaGFuZGxlQm9keS5xdWVyeVNlbGVjdG9yQWxsKCcuaGFu
;ZGxlLXJvdycpLmZvckVhY2gocm93ID0+IHsKICAgICAgcm93LmNsYXNzTGlzdC50b2dnbGUoJ29uJywgaGFuZGxlU2VsS2V5cy5oYXMocm93LmdldEF0dHJp
;YnV0ZSgnZGF0YS1rZXknKSkpOwogICAgfSk7CiAgfQogIGZ1bmN0aW9uIHNlbGVjdEhhbmRsZUZyb21FdmVudChlLCByb3cpIHsKICAgIGNvbnN0IGtleSA9
;IHJvdy5nZXRBdHRyaWJ1dGUoJ2RhdGEta2V5Jyk7CiAgICBjb25zdCByb3dzID0gQXJyYXkuZnJvbShoYW5kbGVCb2R5LnF1ZXJ5U2VsZWN0b3JBbGwoJy5o
;YW5kbGUtcm93JykpOwogICAgY29uc3QgaWR4ID0gcm93cy5pbmRleE9mKHJvdyk7CiAgICBpZiAoZS5zaGlmdEtleSAmJiBoYW5kbGVBbmNob3JLZXkpIHsK
;ICAgICAgY29uc3QgYUlkeCA9IHJvd3MuZmluZEluZGV4KHIgPT4gci5nZXRBdHRyaWJ1dGUoJ2RhdGEta2V5JykgPT09IGhhbmRsZUFuY2hvcktleSk7CiAg
;ICAgIGlmIChhSWR4ID49IDAgJiYgaWR4ID49IDApIHsKICAgICAgICBpZiAoIWUuY3RybEtleSkgaGFuZGxlU2VsS2V5cy5jbGVhcigpOwogICAgICAgIGNv
;bnN0IGxvID0gTWF0aC5taW4oYUlkeCwgaWR4KSwgaGkgPSBNYXRoLm1heChhSWR4LCBpZHgpOwogICAgICAgIGZvciAobGV0IGkgPSBsbzsgaSA8PSBoaTsg
;aSsrKSBoYW5kbGVTZWxLZXlzLmFkZChyb3dzW2ldLmdldEF0dHJpYnV0ZSgnZGF0YS1rZXknKSk7CiAgICAgIH0KICAgIH0gZWxzZSBpZiAoZS5jdHJsS2V5
;KSB7CiAgICAgIGlmIChoYW5kbGVTZWxLZXlzLmhhcyhrZXkpKSBoYW5kbGVTZWxLZXlzLmRlbGV0ZShrZXkpOwogICAgICBlbHNlIGhhbmRsZVNlbEtleXMu
;YWRkKGtleSk7CiAgICAgIGhhbmRsZUFuY2hvcktleSA9IGtleTsKICAgIH0gZWxzZSB7CiAgICAgIGhhbmRsZVNlbEtleXMuY2xlYXIoKTsKICAgICAgaGFu
;ZGxlU2VsS2V5cy5hZGQoa2V5KTsKICAgICAgaGFuZGxlQW5jaG9yS2V5ID0ga2V5OwogICAgfQogICAgcmVmcmVzaEhhbmRsZVNlbGVjdGlvblVJKCk7CiAg
;fQogIGZ1bmN0aW9uIGNvbGxlY3RIYW5kbGVUYXJnZXRzKCkgewogICAgY29uc3QgbWFwID0gbmV3IE1hcCgpOwogICAgaGFuZGxlQm9keS5xdWVyeVNlbGVj
;dG9yQWxsKCcuaGFuZGxlLXJvdycpLmZvckVhY2gocm93ID0+IHsKICAgICAgaWYgKCFoYW5kbGVTZWxLZXlzLmhhcyhyb3cuZ2V0QXR0cmlidXRlKCdkYXRh
;LWtleScpKSkgcmV0dXJuOwogICAgICBjb25zdCBwaWQgPSBOdW1iZXIocm93LmdldEF0dHJpYnV0ZSgnZGF0YS1waWQnKSkgfHwgMDsKICAgICAgaWYgKHBp
;ZCA8PSAwIHx8IG1hcC5oYXMocGlkKSkgcmV0dXJuOwogICAgICBtYXAuc2V0KHBpZCwgewogICAgICAgIHBpZCwKICAgICAgICBuYW1lOiByb3cuZ2V0QXR0
;cmlidXRlKCdkYXRhLW5hbWUnKSB8fCAnJywKICAgICAgICBwYXRoOiByb3cuZ2V0QXR0cmlidXRlKCdkYXRhLXBhdGgnKSB8fCAnJwogICAgICB9KTsKICAg
;IH0pOwogICAgcmV0dXJuIEFycmF5LmZyb20obWFwLnZhbHVlcygpKTsKICB9CiAgd2luZG93Ll9fb25Ib3N0SGlkZSA9ICgpID0+IHsgcG9zdCgncHJvY1Zp
;ZXd8MCcpOyB9OwogIHdpbmRvdy5fX29uSG9zdFNob3cgPSAoKSA9PiB7CiAgICB0cnkgeyBpZiAod2luZG93Ll9fcmVzeW5jU2VhcmNoKSB3aW5kb3cuX19y
;ZXN5bmNTZWFyY2goKTsgfSBjYXRjaCAoXykge30KICB9OwogIGRvY3VtZW50LmFkZEV2ZW50TGlzdGVuZXIoJ3Zpc2liaWxpdHljaGFuZ2UnLCAoKSA9PiB7
;CiAgICBpZiAoZG9jdW1lbnQuaGlkZGVuKSBwb3N0KCdwcm9jVmlld3wwJyk7CiAgfSk7CgogIGlmIChkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYnRuLWlu
;Zm8tcmVmcmVzaCcpKQogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2J0bi1pbmZvLXJlZnJlc2gnKS5vbmNsaWNrID0gKCkgPT4gcmVxdWVzdFN5c0lu
;Zm8odHJ1ZSk7CiAgaWYgKGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdidG4taW5mby1jb3B5JykpCiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYnRu
;LWluZm8tY29weScpLm9uY2xpY2sgPSAoKSA9PiB7CiAgICAgIGNvbnN0IHQgPSBpbmZvVGV4dCB8fCAoaW5mb1BhbmVsICYmIGluZm9QYW5lbC5pbm5lclRl
;eHQpIHx8ICcnOwogICAgICB0cnkgeyBuYXZpZ2F0b3IuY2xpcGJvYXJkLndyaXRlVGV4dCh0KTsgfSBjYXRjaCAoXykgeyBwb3N0KCdjb3B5VGV4dHwnICsg
;dCk7IH0KICAgIH07CiAgaWYgKGJ0blBvcnRNYXJrKSB7CiAgICBidG5Qb3J0TWFyay5vbmNsaWNrID0gKGUpID0+IHsKICAgICAgZS5zdG9wUHJvcGFnYXRp
;b24oKTsKICAgICAgaWYgKHBvcnRNYXJrUG9wICYmIHBvcnRNYXJrUG9wLmNsYXNzTGlzdC5jb250YWlucygnb24nKSkgY2xvc2VQb3J0TWFya1BvcCgpOwog
;ICAgICBlbHNlIG9wZW5Qb3J0TWFya1BvcCgpOwogICAgfTsKICB9CiAgaWYgKHBvcnRNYXJrUG9wKSBwb3J0TWFya1BvcC5hZGRFdmVudExpc3RlbmVyKCdj
;bGljaycsIGUgPT4gZS5zdG9wUHJvcGFnYXRpb24oKSk7CiAgY29uc3QgYnRuUG9ydE1hcmtBZGQgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgncG9ydC1t
;YXJrLWFkZCcpOwogIGNvbnN0IGJ0blBvcnRNYXJrUmVzZXQgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgncG9ydC1tYXJrLXJlc2V0Jyk7CiAgaWYgKGJ0
;blBvcnRNYXJrQWRkKSB7CiAgICBidG5Qb3J0TWFya0FkZC5vbmNsaWNrID0gKGUpID0+IHsKICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgaWYg
;KGFkZE1hcmtlZFBvcnQocG9ydE1hcmtJbnB1dCAmJiBwb3J0TWFya0lucHV0LnZhbHVlKSkgewogICAgICAgIGlmIChwb3J0TWFya0lucHV0KSBwb3J0TWFy
;a0lucHV0LnZhbHVlID0gJyc7CiAgICAgIH0KICAgIH07CiAgfQogIGlmIChwb3J0TWFya0lucHV0KSB7CiAgICBwb3J0TWFya0lucHV0LmFkZEV2ZW50TGlz
;dGVuZXIoJ2tleWRvd24nLCBlID0+IHsKICAgICAgaWYgKGUua2V5ID09PSAnRW50ZXInKSB7CiAgICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOwogICAgICAg
;IGlmIChhZGRNYXJrZWRQb3J0KHBvcnRNYXJrSW5wdXQudmFsdWUpKSBwb3J0TWFya0lucHV0LnZhbHVlID0gJyc7CiAgICAgIH0KICAgIH0pOwogIH0KICBp
;ZiAoYnRuUG9ydE1hcmtSZXNldCkgewogICAgYnRuUG9ydE1hcmtSZXNldC5vbmNsaWNrID0gKGUpID0+IHsKICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsK
;ICAgICAgbWFya2VkUG9ydHMgPSBERUZBVUxUX01BUktFRF9QT1JUUy5zbGljZSgpOwogICAgICBzYXZlTWFya2VkUG9ydHMoKTsKICAgICAgcmVuZGVyTWFy
;a2VkUG9ydFRhZ3MoKTsKICAgICAgaWYgKGFwcE1vZGUgPT09ICdoYW5kbGUnICYmIGhhbmRsZU1vZGUgPT09ICdwb3J0JykgcmVuZGVySGFuZGxlVGFibGUo
;KTsKICAgIH07CiAgfQogIGRvY3VtZW50LmFkZEV2ZW50TGlzdGVuZXIoJ2NsaWNrJywgKCkgPT4gY2xvc2VQb3J0TWFya1BvcCgpKTsKICByZW5kZXJNYXJr
;ZWRQb3J0VGFncygpOwogIHJlbmRlckhhbmRsZUhpc3QoKTsKICAvLyDkuLvmkJzntKLmoYbnu5/kuIDmkJzntKLvvJvlj6Xmn4Tljoblj7LotbAg4pa+IOS4
;i+aLie+8iOS4juaWh+S7tuaQnOe0ouS4gOiHtO+8iQogIHRyeSB7IHFFbC5yZW1vdmVBdHRyaWJ1dGUoJ2xpc3QnKTsgfSBjYXRjaCAoXykge30KCiAgZnVu
;Y3Rpb24gaGlkZVByb2NNZW51KCkgewogICAgcHJvY01lbnUuY2xhc3NMaXN0LnJlbW92ZSgnb24nKTsKICAgIHByb2NNZW51VGFyZ2V0cyA9IFtdOwogIH0K
;ICBmdW5jdGlvbiBzaG93UHJvY01lbnUoeCwgeSwgdGFyZ2V0cykgewogICAgcHJvY01lbnVUYXJnZXRzID0gQXJyYXkuaXNBcnJheSh0YXJnZXRzKSA/IHRh
;cmdldHMuZmlsdGVyKHQgPT4gdCAmJiBOdW1iZXIodC5waWQpID4gMCkgOiBbXTsKICAgIGNvbnN0IG4gPSBwcm9jTWVudVRhcmdldHMubGVuZ3RoOwogICAg
;Y29uc3QgZmlyc3QgPSBuID8gcHJvY01lbnVUYXJnZXRzWzBdIDogbnVsbDsKICAgIGNvbnN0IG5hbWUgPSBmaXJzdCA/IFN0cmluZyhmaXJzdC5uYW1lIHx8
;ICcnKS50cmltKCkgOiAnJzsKICAgIGNvbnN0IHBpZCA9IGZpcnN0ID8gU3RyaW5nKE51bWJlcihmaXJzdC5waWQpIHx8ICcnKSA6ICcnOwogICAgY29uc3Qg
;Y29weUxibCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdwcm9jLW1lbnUtY29weScpOwogICAgY29uc3QgcGlkTGJsID0gZG9jdW1lbnQuZ2V0RWxlbWVu
;dEJ5SWQoJ3Byb2MtbWVudS1jb3B5cGlkJyk7CiAgICBjb25zdCBlbmRMYmwgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgncHJvYy1tZW51LWVuZC1sYWJl
;bCcpOwogICAgaWYgKGNvcHlMYmwpIHsKICAgICAgaWYgKG5hbWUgJiYgbiA9PT0gMSkgY29weUxibC50ZXh0Q29udGVudCA9ICflpI3liLbov5vnqIvlkI0g
;KCAnICsgbmFtZSArICcgKSc7CiAgICAgIGVsc2UgaWYgKG5hbWUgJiYgbiA+IDEpIGNvcHlMYmwudGV4dENvbnRlbnQgPSAn5aSN5Yi26L+b56iL5ZCNICgg
;JyArIG5hbWUgKyAnIOetiScgKyBuICsgJ+S4qiApJzsKICAgICAgZWxzZSBjb3B5TGJsLnRleHRDb250ZW50ID0gJ+WkjeWItui/m+eoi+WQjSc7CiAgICB9
;CiAgICBpZiAocGlkTGJsKSB7CiAgICAgIGlmIChwaWQgJiYgbiA9PT0gMSkgcGlkTGJsLnRleHRDb250ZW50ID0gJ+WkjeWItui/m+eoi+WPtyAoICcgKyBw
;aWQgKyAnICknOwogICAgICBlbHNlIGlmIChwaWQgJiYgbiA+IDEpIHBpZExibC50ZXh0Q29udGVudCA9ICflpI3liLbov5vnqIvlj7cgKCAnICsgcGlkICsg
;JyDnrYknICsgbiArICfkuKogKSc7CiAgICAgIGVsc2UgcGlkTGJsLnRleHRDb250ZW50ID0gJ+WkjeWItui/m+eoi+WPtyc7CiAgICB9CiAgICBpZiAoZW5k
;TGJsKSBlbmRMYmwudGV4dENvbnRlbnQgPSAn5YWz6Zet6L+b56iLICggJyArIE1hdGgubWF4KG4sIDApICsgJyApJzsKICAgIGNvbnN0IGhhc1BhdGggPSBw
;cm9jTWVudVRhcmdldHMuc29tZSh0ID0+IHQucGF0aCk7CiAgICBwcm9jTWVudS5xdWVyeVNlbGVjdG9yQWxsKCdidXR0b25bZGF0YS1wYWN0XScpLmZvckVh
;Y2goYnRuID0+IHsKICAgICAgY29uc3QgYWN0ID0gYnRuLmdldEF0dHJpYnV0ZSgnZGF0YS1wYWN0Jyk7CiAgICAgIGlmIChhY3QgPT09ICdyZXZlYWwnKSBi
;dG4uZGlzYWJsZWQgPSAhaGFzUGF0aDsKICAgICAgZWxzZSBidG4uZGlzYWJsZWQgPSBuIDwgMTsKICAgIH0pOwogICAgcHJvY01lbnUuY2xhc3NMaXN0LmFk
;ZCgnb24nKTsKICAgIHByb2NNZW51LnN0eWxlLmxlZnQgPSAnMHB4JzsKICAgIHByb2NNZW51LnN0eWxlLnRvcCA9ICcwcHgnOwogICAgY29uc3QgcmVjdCA9
;IHByb2NNZW51LmdldEJvdW5kaW5nQ2xpZW50UmVjdCgpOwogICAgbGV0IGxlZnQgPSB4LCB0b3AgPSB5OwogICAgaWYgKGxlZnQgKyByZWN0LndpZHRoID4g
;aW5uZXJXaWR0aCAtIDYpIGxlZnQgPSBNYXRoLm1heCg2LCBpbm5lcldpZHRoIC0gcmVjdC53aWR0aCAtIDYpOwogICAgaWYgKHRvcCArIHJlY3QuaGVpZ2h0
;ID4gaW5uZXJIZWlnaHQgLSA2KSB0b3AgPSBNYXRoLm1heCg2LCBpbm5lckhlaWdodCAtIHJlY3QuaGVpZ2h0IC0gNik7CiAgICBwcm9jTWVudS5zdHlsZS5s
;ZWZ0ID0gbGVmdCArICdweCc7CiAgICBwcm9jTWVudS5zdHlsZS50b3AgPSB0b3AgKyAncHgnOwogIH0KICBmdW5jdGlvbiBjb3B5VGV4dFNhZmUodGV4dCkg
;ewogICAgdGV4dCA9IFN0cmluZyh0ZXh0IHx8ICcnKTsKICAgIGlmICghdGV4dCkgcmV0dXJuOwogICAgdHJ5IHsgbmF2aWdhdG9yLmNsaXBib2FyZC53cml0
;ZVRleHQodGV4dCk7IH0gY2F0Y2ggKF8pIHsgcG9zdCgnY29weVRleHR8JyArIHRleHQpOyB9CiAgfQogIHByb2NNZW51LnF1ZXJ5U2VsZWN0b3JBbGwoJ2J1
;dHRvbltkYXRhLXBhY3RdJykuZm9yRWFjaChidG4gPT4gewogICAgYnRuLm9uY2xpY2sgPSAoZSkgPT4gewogICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwog
;ICAgICBjb25zdCBhY3QgPSBidG4uZ2V0QXR0cmlidXRlKCdkYXRhLXBhY3QnKTsKICAgICAgY29uc3QgdGFyZ2V0cyA9IHByb2NNZW51VGFyZ2V0cy5zbGlj
;ZSgpOwogICAgICBoaWRlUHJvY01lbnUoKTsKICAgICAgaWYgKCF0YXJnZXRzLmxlbmd0aCkgcmV0dXJuOwogICAgICBpZiAoYWN0ID09PSAnZW5kJykgewog
;ICAgICAgIGNvbnN0IHBpZHMgPSB0YXJnZXRzLm1hcCh0ID0+IE51bWJlcih0LnBpZCkgfHwgMCkuZmlsdGVyKHBpZCA9PiBwaWQgPiAwKTsKICAgICAgICBp
;ZiAocGlkcy5sZW5ndGgpIHsKICAgICAgICAgIC8vIOWFiOS7jueVjOmdouenu+mZpO+8jOS4u+acuuehruiupOWQjuS8muWGjeWQjOatpeS4gOasoQogICAg
;ICAgICAgcmVtb3ZlUm93c0J5UGlkcyhwaWRzKTsKICAgICAgICAgIHBvc3QoJ3Byb2NLaWxsfCcgKyBwaWRzLmpvaW4oJywnKSk7CiAgICAgICAgfQogICAg
;ICB9IGVsc2UgaWYgKGFjdCA9PT0gJ3JldmVhbCcpIHsKICAgICAgICBjb25zdCBzZWVuID0gbmV3IFNldCgpOwogICAgICAgIGZvciAoY29uc3QgdCBvZiB0
;YXJnZXRzKSB7CiAgICAgICAgICBjb25zdCBwID0gU3RyaW5nKHQucGF0aCB8fCAnJyk7CiAgICAgICAgICBpZiAoIXAgfHwgc2Vlbi5oYXMocC50b0xvd2Vy
;Q2FzZSgpKSkgY29udGludWU7CiAgICAgICAgICBzZWVuLmFkZChwLnRvTG93ZXJDYXNlKCkpOwogICAgICAgICAgY2FsbEhvc3QoJ3JldmVhbCcsIHApOwog
;ICAgICAgIH0KICAgICAgfSBlbHNlIGlmIChhY3QgPT09ICdjb3B5JykgewogICAgICAgIGNvbnN0IG5hbWVzID0gW107CiAgICAgICAgY29uc3Qgc2VlbiA9
;IG5ldyBTZXQoKTsKICAgICAgICBmb3IgKGNvbnN0IHQgb2YgdGFyZ2V0cykgewogICAgICAgICAgbGV0IG4gPSBTdHJpbmcodC5uYW1lIHx8ICcnKS50cmlt
;KCk7CiAgICAgICAgICBpZiAoIW4gJiYgdC5wYXRoKSB7CiAgICAgICAgICAgIGNvbnN0IHAgPSBTdHJpbmcodC5wYXRoKS5yZXBsYWNlKC9bXFwvXSskLywg
;JycpOwogICAgICAgICAgICBjb25zdCBpID0gTWF0aC5tYXgocC5sYXN0SW5kZXhPZignXFwnKSwgcC5sYXN0SW5kZXhPZignLycpKTsKICAgICAgICAgICAg
;biA9IGkgPj0gMCA/IHAuc2xpY2UoaSArIDEpIDogcDsKICAgICAgICAgIH0KICAgICAgICAgIGlmICghbiB8fCBzZWVuLmhhcyhuLnRvTG93ZXJDYXNlKCkp
;KSBjb250aW51ZTsKICAgICAgICAgIHNlZW4uYWRkKG4udG9Mb3dlckNhc2UoKSk7CiAgICAgICAgICBuYW1lcy5wdXNoKG4pOwogICAgICAgIH0KICAgICAg
;ICBjb3B5VGV4dFNhZmUobmFtZXMuam9pbignXG4nKSk7CiAgICAgIH0gZWxzZSBpZiAoYWN0ID09PSAnY29weVBpZCcpIHsKICAgICAgICBjb25zdCBwaWRz
;ID0gW107CiAgICAgICAgY29uc3Qgc2VlbiA9IG5ldyBTZXQoKTsKICAgICAgICBmb3IgKGNvbnN0IHQgb2YgdGFyZ2V0cykgewogICAgICAgICAgY29uc3Qg
;cGlkID0gTnVtYmVyKHQucGlkKSB8fCAwOwogICAgICAgICAgaWYgKHBpZCA8PSAwIHx8IHNlZW4uaGFzKHBpZCkpIGNvbnRpbnVlOwogICAgICAgICAgc2Vl
;bi5hZGQocGlkKTsKICAgICAgICAgIHBpZHMucHVzaChTdHJpbmcocGlkKSk7CiAgICAgICAgfQogICAgICAgIGNvcHlUZXh0U2FmZShwaWRzLmpvaW4oJ1xu
;JykpOwogICAgICB9CiAgICB9OwogIH0pOwogIGRvY3VtZW50LmFkZEV2ZW50TGlzdGVuZXIoJ2NsaWNrJywgKCkgPT4gaGlkZVByb2NNZW51KCkpOwogIGRv
;Y3VtZW50LmFkZEV2ZW50TGlzdGVuZXIoJ2tleWRvd24nLCAoZSkgPT4gewogICAgaWYgKGUua2V5ID09PSAnRXNjYXBlJykgewogICAgICBoaWRlUHJvY01l
;bnUoKTsKICAgICAgY2xvc2VQb3J0TWFya1BvcCgpOwogICAgfQogIH0pOwoKICBmdW5jdGlvbiBwcm9jUm93S2V5KHApIHsKICAgIHJldHVybiBbcC5wcm90
;bywgcC5sb2NhbElwLCBwLmxvY2FsUG9ydCwgcC5yZW1vdGVJcCwgcC5yZW1vdGVQb3J0LCBwLnBpZF0uam9pbignfCcpOwogIH0KICBmdW5jdGlvbiBwb3J0
;c0NvbnRlbnRTaWcoaXRlbXMpIHsKICAgIHJldHVybiAoaXRlbXMgfHwgW10pLm1hcChwID0+CiAgICAgIHByb2NSb3dLZXkocCkgKyAnXHQnICsgKHAucHJv
;YyB8fCAnJykgKyAnXHQnICsgKHAuc3RhdGUgfHwgJycpICsgJ1x0JyArIChwLnBhdGggfHwgJycpCiAgICAgICAgKyAnXHQnICsgKHAucHBpZCB8fCAnJykg
;KyAnXHQnICsgKHAuY3B1IHx8ICcnKSArICdcdCcgKyAocC5tZW0gfHwgJycpCiAgICApLmpvaW4oJ1xuJyk7CiAgfQogIGZ1bmN0aW9uIHBvcnRDZWxsVGV4
;dChwb3J0KSB7CiAgICBpZiAocG9ydCA9PT0gJycgfHwgcG9ydCA9PSBudWxsIHx8IE51bWJlcihwb3J0KSA8IDApIHJldHVybiAnJzsKICAgIHJldHVybiBT
;dHJpbmcocG9ydCk7CiAgfQogIGZ1bmN0aW9uIHByb2NJY29uU3RhYmxlS2V5KHApIHsKICAgIGNvbnN0IHBhdGggPSBTdHJpbmcoKHAgJiYgcC5wYXRoKSB8
;fCAnJyk7CiAgICBpZiAocGF0aCkgcmV0dXJuICdwOicgKyBwYXRoLnRvTG93ZXJDYXNlKCk7CiAgICByZXR1cm4gJ2lkOicgKyAoTnVtYmVyKHAgJiYgcC5w
;aWQpIHx8IDApOwogIH0KICBmdW5jdGlvbiBzZXRQcm9jSWNvbkVsKG5hbWVCb3gsIGljb25VcmwsIHN0YWJsZUtleSkgewogICAgaWYgKCFuYW1lQm94KSBy
;ZXR1cm47CiAgICBsZXQgaW1nID0gbmFtZUJveC5xdWVyeVNlbGVjdG9yKCdpbWcnKTsKICAgIGxldCBwaCA9IG5hbWVCb3gucXVlcnlTZWxlY3RvcignLnBy
;b2MtaWNvLXBoJyk7CiAgICBjb25zdCB1cmwgPSBTdHJpbmcoaWNvblVybCB8fCAnJyk7CiAgICAvLyDlt7LmnInnqLPlrprlm77moIfvvJrnqbov5ZCMIHNy
;YyDpg73kuI3liqjvvIzmnZznu53pl6rng4EKICAgIGlmIChpbWcpIHsKICAgICAgY29uc3QgY3VyID0gaW1nLmdldEF0dHJpYnV0ZSgnc3JjJykgfHwgJyc7
;CiAgICAgIGlmICghdXJsIHx8IHVybCA9PT0gY3VyKSByZXR1cm47CiAgICAgIGltZy5zZXRBdHRyaWJ1dGUoJ3NyYycsIHVybCk7CiAgICAgIGlmIChzdGFi
;bGVLZXkpIHByb2NJY29uU3RhYmxlLnNldChzdGFibGVLZXksIHVybCk7CiAgICAgIHJldHVybjsKICAgIH0KICAgIGlmICghdXJsKSB7CiAgICAgIGlmICgh
;cGgpIHsKICAgICAgICBwaCA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ3NwYW4nKTsKICAgICAgICBwaC5jbGFzc05hbWUgPSAncHJvYy1pY28tcGgnOwog
;ICAgICAgIHBoLnNldEF0dHJpYnV0ZSgnYXJpYS1oaWRkZW4nLCAndHJ1ZScpOwogICAgICAgIG5hbWVCb3guaW5zZXJ0QmVmb3JlKHBoLCBuYW1lQm94LmZp
;cnN0Q2hpbGQpOwogICAgICB9CiAgICAgIHJldHVybjsKICAgIH0KICAgIGltZyA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2ltZycpOwogICAgaW1nLmFs
;dCA9ICcnOwogICAgaW1nLmRlY29kaW5nID0gJ2FzeW5jJzsKICAgIGltZy5zcmMgPSB1cmw7CiAgICBpbWcub25lcnJvciA9IGZ1bmN0aW9uICgpIHsKICAg
;ICAgdGhpcy5vbmVycm9yID0gbnVsbDsKICAgICAgY29uc3QgcyA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ3NwYW4nKTsKICAgICAgcy5jbGFzc05hbWUg
;PSAncHJvYy1pY28tcGgnOwogICAgICBzLnNldEF0dHJpYnV0ZSgnYXJpYS1oaWRkZW4nLCAndHJ1ZScpOwogICAgICB0aGlzLnJlcGxhY2VXaXRoKHMpOwog
;ICAgfTsKICAgIGlmIChwaCkgbmFtZUJveC5yZXBsYWNlQ2hpbGQoaW1nLCBwaCk7CiAgICBlbHNlIG5hbWVCb3guaW5zZXJ0QmVmb3JlKGltZywgbmFtZUJv
;eC5maXJzdENoaWxkKTsKICAgIGlmIChzdGFibGVLZXkpIHByb2NJY29uU3RhYmxlLnNldChzdGFibGVLZXksIHVybCk7CiAgfQogIGZ1bmN0aW9uIGVuc3Vy
;ZVByb2NSb3cocCkgewogICAgY29uc3Qgcm93ID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnZGl2Jyk7CiAgICByb3cuY2xhc3NOYW1lID0gJ3Byb2Mtcm93
;IHByb2MtY29scyc7CiAgICByb3cuaW5uZXJIVE1MID0KICAgICAgJzxkaXYgY2xhc3M9InByb2MtY2VsbC1uYW1lIj48ZGl2IGNsYXNzPSJwcm9jLW5hbWUi
;PjxzcGFuIGNsYXNzPSJwcm9jLWljby1waCIgYXJpYS1oaWRkZW49InRydWUiPjwvc3Bhbj48c3BhbiBjbGFzcz0icHJvYy1sYWJlbCI+PC9zcGFuPjwvZGl2
;PjwvZGl2PicKICAgICAgKyAnPGRpdiBjbGFzcz0icHJvYy1udW0gcHJvYy1jZWxsLWNwdSIgZGF0YS1mPSJjcHUiPjwvZGl2PicKICAgICAgKyAnPGRpdiBj
;bGFzcz0icHJvYy1udW0gcHJvYy1jZWxsLW1lbSIgZGF0YS1mPSJtZW0iPjwvZGl2PicKICAgICAgKyAnPGRpdiBjbGFzcz0icHJvYy1udW0gcHJvYy1jZWxs
;LXBpZCIgZGF0YS1mPSJwaWQiPjwvZGl2PicKICAgICAgKyAnPGRpdiBjbGFzcz0icHJvYy1udW0gcHJvYy1jZWxsLXByb3RvIiBkYXRhLWY9InByb3RvIj48
;L2Rpdj4nCiAgICAgICsgJzxkaXYgY2xhc3M9InByb2MtbnVtIHByb2MtY2VsbC1pcCIgZGF0YS1mPSJsaXAiPjwvZGl2PicKICAgICAgKyAnPGRpdiBjbGFz
;cz0icHJvYy1udW0gcHJvYy1jZWxsLXBvcnQiIGRhdGEtZj0ibHBvcnQiPjwvZGl2PicKICAgICAgKyAnPGRpdiBjbGFzcz0icHJvYy1udW0gcHJvYy1jZWxs
;LWlwIiBkYXRhLWY9InJpcCI+PC9kaXY+JwogICAgICArICc8ZGl2IGNsYXNzPSJwcm9jLW51bSBwcm9jLWNlbGwtcG9ydCIgZGF0YS1mPSJycG9ydCI+PC9k
;aXY+JwogICAgICArICc8ZGl2IGNsYXNzPSJwcm9jLW51bSBwcm9jLWNlbGwtc3RhdGUiIGRhdGEtZj0ic3RhdGUiPjxzcGFuIGNsYXNzPSJwcm9jLW5ldC1k
;b3QgaGlkZGVuIiB0aXRsZT0i5bey6L+e5o6lIj48L3NwYW4+PHNwYW4gY2xhc3M9InByb2Mtc3RhdGUtdHh0Ij48L3NwYW4+PC9kaXY+JzsKICAgIHJvdy5v
;bmNsaWNrID0gKGUpID0+IHNlbGVjdFByb2NGcm9tRXZlbnQoZSwgcm93KTsKICAgIHJvdy5vbmNvbnRleHRtZW51ID0gKGUpID0+IHsKICAgICAgZS5wcmV2
;ZW50RGVmYXVsdCgpOwogICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgICBjb25zdCBrZXkgPSByb3cuZ2V0QXR0cmlidXRlKCdkYXRhLWtleScpOwog
;ICAgICBpZiAoIXByb2NTZWxLZXlzLmhhcyhrZXkpKSB7CiAgICAgICAgc2VsZWN0UHJvY05hbWVHcm91cChyb3cpOwogICAgICB9CiAgICAgIHNob3dQcm9j
;TWVudShlLmNsaWVudFgsIGUuY2xpZW50WSwgY29sbGVjdFByb2NUYXJnZXRzKCkpOwogICAgfTsKICAgIHJldHVybiByb3c7CiAgfQogIGZ1bmN0aW9uIGhl
;YXRDb2xvcihob3QpIHsKICAgIHJldHVybiBob3QgPyAnIzg4ZmZjMScgOiAnI2NlZmZlNSc7CiAgfQogIGZ1bmN0aW9uIHBhcnNlUGN0KHMpIHsKICAgIGNv
;bnN0IG0gPSBTdHJpbmcocyB8fCAnJykubWF0Y2goLyhbXGQuXSspLyk7CiAgICByZXR1cm4gbSA/IE51bWJlcihtWzFdKSA6IDA7CiAgfQogIGZ1bmN0aW9u
;IHVwZGF0ZUhlYWRIZWF0KGNwdVRvdGFsLCBtZW1Ub3RhbCkgewogICAgY29uc3QgY3B1Q2VsbCA9IHByb2NIZWFkICYmIHByb2NIZWFkLnF1ZXJ5U2VsZWN0
;b3IoJy5wcm9jLWhjZWxsW2RhdGEtc29ydD0iY3B1Il0nKTsKICAgIGNvbnN0IG1lbUNlbGwgPSBwcm9jSGVhZCAmJiBwcm9jSGVhZC5xdWVyeVNlbGVjdG9y
;KCcucHJvYy1oY2VsbFtkYXRhLXNvcnQ9Im1lbSJdJyk7CiAgICBjb25zdCBjcHVQY3QgPSBwYXJzZVBjdChjcHVUb3RhbCk7CiAgICBjb25zdCBtZW1QY3Qg
;PSBwYXJzZVBjdChtZW1Ub3RhbCk7CiAgICBpZiAoY3B1Q2VsbCkgewogICAgICBjcHVDZWxsLmNsYXNzTGlzdC50b2dnbGUoJ2hvdCcsIGNwdVBjdCA+IDUp
;OwogICAgICBjcHVDZWxsLnN0eWxlLmJhY2tncm91bmQgPSBoZWF0Q29sb3IoY3B1UGN0ID4gNSk7CiAgICB9CiAgICBpZiAobWVtQ2VsbCkgewogICAgICBt
;ZW1DZWxsLmNsYXNzTGlzdC50b2dnbGUoJ2hvdCcsIG1lbVBjdCA+IDgwKTsKICAgICAgbWVtQ2VsbC5zdHlsZS5iYWNrZ3JvdW5kID0gaGVhdENvbG9yKG1l
;bVBjdCA+IDgwKTsKICAgIH0KICB9CiAgZnVuY3Rpb24gdXBkYXRlUHJvY1Jvd0RhdGEocm93LCBwKSB7CiAgICBjb25zdCBrZXkgPSBwcm9jUm93S2V5KHAp
;OwogICAgcm93LnNldEF0dHJpYnV0ZSgnZGF0YS1rZXknLCBrZXkpOwogICAgcm93LnNldEF0dHJpYnV0ZSgnZGF0YS1waWQnLCBTdHJpbmcocC5waWQgfHwg
;MCkpOwogICAgcm93LnNldEF0dHJpYnV0ZSgnZGF0YS1uYW1lJywgU3RyaW5nKHAucHJvYyB8fCAnJykpOwogICAgcm93LnNldEF0dHJpYnV0ZSgnZGF0YS1w
;YXRoJywgU3RyaW5nKHAucGF0aCB8fCAnJykpOwogICAgY29uc3QgbmFtZUJveCA9IHJvdy5xdWVyeVNlbGVjdG9yKCcucHJvYy1uYW1lJyk7CiAgICBjb25z
;dCBsYWJlbCA9IHJvdy5xdWVyeVNlbGVjdG9yKCcucHJvYy1sYWJlbCcpOwogICAgY29uc3QgbmFtZSA9IHAucHJvYyB8fCAocC5waWQgPyAoJ1BJRCAnICsg
;cC5waWQpIDogJycpOwogICAgaWYgKGxhYmVsICYmIGxhYmVsLnRleHRDb250ZW50ICE9PSBuYW1lKSBsYWJlbC50ZXh0Q29udGVudCA9IG5hbWU7CiAgICBp
;ZiAobGFiZWwpIGxhYmVsLnRpdGxlID0gcC5wYXRoIHx8IG5hbWU7CiAgICBjb25zdCBzayA9IHByb2NJY29uU3RhYmxlS2V5KHApOwogICAgbGV0IGljb24g
;PSBTdHJpbmcocC5pY29uIHx8ICcnKTsKICAgIGlmICghaWNvbiAmJiBwcm9jSWNvblN0YWJsZS5oYXMoc2spKQogICAgICBpY29uID0gcHJvY0ljb25TdGFi
;bGUuZ2V0KHNrKTsKICAgIHNldFByb2NJY29uRWwobmFtZUJveCwgaWNvbiwgc2spOwogICAgY29uc3Qgc2V0VHh0ID0gKHNlbCwgdmFsLCB0aXRsZSkgPT4g
;ewogICAgICBjb25zdCBlbCA9IHJvdy5xdWVyeVNlbGVjdG9yKHNlbCk7CiAgICAgIGlmICghZWwpIHJldHVybjsKICAgICAgY29uc3QgdCA9IHZhbCA9PSBu
;dWxsID8gJycgOiBTdHJpbmcodmFsKTsKICAgICAgaWYgKGVsLnRleHRDb250ZW50ICE9PSB0KSBlbC50ZXh0Q29udGVudCA9IHQ7CiAgICAgIGlmICh0aXRs
;ZSAhPSBudWxsKSBlbC50aXRsZSA9IHRpdGxlOwogICAgfTsKICAgIHNldFR4dCgnW2RhdGEtZj0iY3B1Il0nLCBwLmNwdSB8fCAnMCUnKTsKICAgIHNldFR4
;dCgnW2RhdGEtZj0ibWVtIl0nLCBwLm1lbSB8fCAnJyk7CiAgICBzZXRUeHQoJ1tkYXRhLWY9InBpZCJdJywgcC5waWQgfHwgJycpOwogICAgc2V0VHh0KCdb
;ZGF0YS1mPSJwcm90byJdJywgcC5wcm90byB8fCAnJyk7CiAgICBzZXRUeHQoJ1tkYXRhLWY9ImxpcCJdJywgcC5sb2NhbElwIHx8ICcnLCBwLmxvY2FsSXAg
;fHwgJycpOwogICAgY29uc3QgbHBvcnQgPSBwb3J0Q2VsbFRleHQocC5sb2NhbFBvcnQpOwogICAgc2V0VHh0KCdbZGF0YS1mPSJscG9ydCJdJywgbHBvcnQp
;OwogICAgY29uc3QgbHBvcnRFbCA9IHJvdy5xdWVyeVNlbGVjdG9yKCdbZGF0YS1mPSJscG9ydCJdJyk7CiAgICBpZiAobHBvcnRFbCkgbHBvcnRFbC5jbGFz
;c0xpc3QudG9nZ2xlKCdwb3J0LWhvdCcsIHBvcnRJc0hvdChwLmxvY2FsUG9ydCkgJiYgbHBvcnQgIT09ICcnKTsKICAgIHNldFR4dCgnW2RhdGEtZj0icmlw
;Il0nLCBwLnJlbW90ZUlwIHx8ICcnLCBwLnJlbW90ZUlwIHx8ICcnKTsKICAgIGNvbnN0IHJwb3J0ID0gcG9ydENlbGxUZXh0KHAucmVtb3RlUG9ydCk7CiAg
;ICBzZXRUeHQoJ1tkYXRhLWY9InJwb3J0Il0nLCBycG9ydCk7CiAgICBjb25zdCBycG9ydEVsID0gcm93LnF1ZXJ5U2VsZWN0b3IoJ1tkYXRhLWY9InJwb3J0
;Il0nKTsKICAgIGlmIChycG9ydEVsKSBycG9ydEVsLmNsYXNzTGlzdC50b2dnbGUoJ3BvcnQtaG90JywgcG9ydElzSG90KHAucmVtb3RlUG9ydCkgJiYgcnBv
;cnQgIT09ICcnKTsKICAgIGNvbnN0IHN0ID0gU3RyaW5nKHAuc3RhdGUgfHwgJycpOwogICAgY29uc3Qgc3RhdGVUeHQgPSByb3cucXVlcnlTZWxlY3Rvcign
;LnByb2Mtc3RhdGUtdHh0Jyk7CiAgICBpZiAoc3RhdGVUeHQpIHsKICAgICAgaWYgKHN0YXRlVHh0LnRleHRDb250ZW50ICE9PSBzdCkgc3RhdGVUeHQudGV4
;dENvbnRlbnQgPSBzdDsKICAgIH0gZWxzZSB7CiAgICAgIHNldFR4dCgnW2RhdGEtZj0ic3RhdGUiXScsIHN0KTsKICAgIH0KICAgIGNvbnN0IG5ldERvdCA9
;IHJvdy5xdWVyeVNlbGVjdG9yKCcucHJvYy1uZXQtZG90Jyk7CiAgICBpZiAobmV0RG90KSB7CiAgICAgIGNvbnN0IGNvbm5lY3RlZCA9IHN0ID09PSAn6L+e
;5o6lJyB8fCAvZXN0YWJsaXNoZWQvaS50ZXN0KHN0KTsKICAgICAgbmV0RG90LmNsYXNzTGlzdC50b2dnbGUoJ2hpZGRlbicsICFjb25uZWN0ZWQpOwogICAg
;fQogICAgY29uc3QgY3B1RWwgPSByb3cucXVlcnlTZWxlY3RvcignW2RhdGEtZj0iY3B1Il0nKTsKICAgIGNvbnN0IG1lbUVsID0gcm93LnF1ZXJ5U2VsZWN0
;b3IoJ1tkYXRhLWY9Im1lbSJdJyk7CiAgICBjb25zdCBjcHVIb3QgPSAoTnVtYmVyKHAuY3B1TikgfHwgMCkgPiAxOwogICAgY29uc3QgbWVtSG90ID0gKE51
;bWJlcihwLm1lbU4pIHx8IDApID4gKDUxMiAqIDEwMjQgKiAxMDI0KTsKICAgIGlmIChjcHVFbCkgewogICAgICBjcHVFbC5jbGFzc0xpc3QudG9nZ2xlKCdo
;b3QnLCBjcHVIb3QpOwogICAgICBjcHVFbC5zdHlsZS5iYWNrZ3JvdW5kID0gaGVhdENvbG9yKGNwdUhvdCk7CiAgICB9CiAgICBpZiAobWVtRWwpIHsKICAg
;ICAgbWVtRWwuY2xhc3NMaXN0LnRvZ2dsZSgnaG90JywgbWVtSG90KTsKICAgICAgbWVtRWwuc3R5bGUuYmFja2dyb3VuZCA9IGhlYXRDb2xvcihtZW1Ib3Qp
;OwogICAgfQogIH0KICAvLyDlrZfmr43mjpLluo/vvJrlkIzlrZfmr40gYS9BIOaMqOWcqOS4gOi1t++8jOS4lCBhIOWcqCBBIOWJje+8iGHigKZB4oCmYuKA
;pkLigKbvvIkKICBmdW5jdGlvbiBwcm9jTmFtZVNvcnRSYW5rKGNoKSB7CiAgICBjb25zdCBjID0gU3RyaW5nKGNoIHx8ICcnKTsKICAgIGlmICghYykgcmV0
;dXJuIDA7CiAgICBjb25zdCBjb2RlID0gYy5jaGFyQ29kZUF0KDApOwogICAgaWYgKGNvZGUgPj0gNjUgJiYgY29kZSA8PSA5MCkgcmV0dXJuIChjb2RlIC0g
;NjUpICogMiArIDE7CiAgICBpZiAoY29kZSA+PSA5NyAmJiBjb2RlIDw9IDEyMikgcmV0dXJuIChjb2RlIC0gOTcpICogMjsKICAgIHJldHVybiAyMDAwICsg
;Y29kZTsKICB9CiAgZnVuY3Rpb24gY29tcGFyZVByb2NOYW1lKGEsIGIpIHsKICAgIGNvbnN0IHNhID0gU3RyaW5nKGEgfHwgJycpOwogICAgY29uc3Qgc2Ig
;PSBTdHJpbmcoYiB8fCAnJyk7CiAgICBjb25zdCBuID0gTWF0aC5tYXgoc2EubGVuZ3RoLCBzYi5sZW5ndGgpOwogICAgZm9yIChsZXQgaSA9IDA7IGkgPCBu
;OyBpKyspIHsKICAgICAgY29uc3QgY2EgPSBzYVtpXSB8fCAnJzsKICAgICAgY29uc3QgY2IgPSBzYltpXSB8fCAnJzsKICAgICAgaWYgKCFjYSkgcmV0dXJu
;IC0xOwogICAgICBpZiAoIWNiKSByZXR1cm4gMTsKICAgICAgY29uc3QgbGEgPSBjYS50b0xvd2VyQ2FzZSgpOwogICAgICBjb25zdCBsYiA9IGNiLnRvTG93
;ZXJDYXNlKCk7CiAgICAgIGlmICgvW2Etel0vaS50ZXN0KGNhKSAmJiAvW2Etel0vaS50ZXN0KGNiKSkgewogICAgICAgIGlmIChsYSAhPT0gbGIpIHJldHVy
;biBsYSA8IGxiID8gLTEgOiAxOwogICAgICAgIGNvbnN0IHJhID0gcHJvY05hbWVTb3J0UmFuayhjYSk7CiAgICAgICAgY29uc3QgcmIgPSBwcm9jTmFtZVNv
;cnRSYW5rKGNiKTsKICAgICAgICBpZiAocmEgIT09IHJiKSByZXR1cm4gcmEgLSByYjsKICAgICAgICBjb250aW51ZTsKICAgICAgfQogICAgICBjb25zdCBj
;bXAgPSBjYS5sb2NhbGVDb21wYXJlKGNiLCAnemgtQ04nLCB7IG51bWVyaWM6IHRydWUsIHNlbnNpdGl2aXR5OiAndmFyaWFudCcgfSk7CiAgICAgIGlmIChj
;bXApIHJldHVybiBjbXA7CiAgICB9CiAgICByZXR1cm4gMDsKICB9CiAgZnVuY3Rpb24gc29ydFByb2NSb3dzRmxhdChpdGVtcykgewogICAgY29uc3QgZGly
;ID0gcHJvY1NvcnREaXI7CiAgICBjb25zdCBrZXkgPSBwcm9jU29ydEtleTsKICAgIHJldHVybiBpdGVtcy5zbGljZSgpLnNvcnQoKGEsIGIpID0+IHsKICAg
;ICAgbGV0IGNtcCA9IDA7CiAgICAgIHN3aXRjaCAoa2V5KSB7CiAgICAgICAgY2FzZSAnY3B1JzoKICAgICAgICAgIGNtcCA9IChOdW1iZXIoYS5jcHVOKSB8
;fCAwKSAtIChOdW1iZXIoYi5jcHVOKSB8fCAwKTsKICAgICAgICAgIGJyZWFrOwogICAgICAgIGNhc2UgJ21lbSc6CiAgICAgICAgICBjbXAgPSAoTnVtYmVy
;KGEubWVtTikgfHwgMCkgLSAoTnVtYmVyKGIubWVtTikgfHwgMCk7CiAgICAgICAgICBicmVhazsKICAgICAgICBjYXNlICdwaWQnOgogICAgICAgICAgY21w
;ID0gKE51bWJlcihhLnBpZCkgfHwgMCkgLSAoTnVtYmVyKGIucGlkKSB8fCAwKTsKICAgICAgICAgIGJyZWFrOwogICAgICAgIGNhc2UgJ3Byb3RvJzoKICAg
;ICAgICAgIGNtcCA9IFN0cmluZyhhLnByb3RvIHx8ICcnKS5sb2NhbGVDb21wYXJlKFN0cmluZyhiLnByb3RvIHx8ICcnKSwgJ2VuJyk7CiAgICAgICAgICBi
;cmVhazsKICAgICAgICBjYXNlICdsaXAnOgogICAgICAgICAgY21wID0gU3RyaW5nKGEubG9jYWxJcCB8fCAnJykubG9jYWxlQ29tcGFyZShTdHJpbmcoYi5s
;b2NhbElwIHx8ICcnKSwgJ2VuJywgeyBudW1lcmljOiB0cnVlIH0pOwogICAgICAgICAgYnJlYWs7CiAgICAgICAgY2FzZSAnbHBvcnQnOgogICAgICAgICAg
;Y21wID0gKE51bWJlcihhLmxvY2FsUG9ydCkgfHwgMCkgLSAoTnVtYmVyKGIubG9jYWxQb3J0KSB8fCAwKTsKICAgICAgICAgIGJyZWFrOwogICAgICAgIGNh
;c2UgJ3JpcCc6CiAgICAgICAgICBjbXAgPSBTdHJpbmcoYS5yZW1vdGVJcCB8fCAnJykubG9jYWxlQ29tcGFyZShTdHJpbmcoYi5yZW1vdGVJcCB8fCAnJyks
;ICdlbicsIHsgbnVtZXJpYzogdHJ1ZSB9KTsKICAgICAgICAgIGJyZWFrOwogICAgICAgIGNhc2UgJ3Jwb3J0JzoKICAgICAgICAgIGNtcCA9IChOdW1iZXIo
;YS5yZW1vdGVQb3J0KSB8fCAwKSAtIChOdW1iZXIoYi5yZW1vdGVQb3J0KSB8fCAwKTsKICAgICAgICAgIGJyZWFrOwogICAgICAgIGNhc2UgJ3N0YXRlJzoK
;ICAgICAgICAgIGNtcCA9IFN0cmluZyhhLnN0YXRlIHx8ICcnKS5sb2NhbGVDb21wYXJlKFN0cmluZyhiLnN0YXRlIHx8ICcnKSwgJ3poLUNOJyk7CiAgICAg
;ICAgICBicmVhazsKICAgICAgICBjYXNlICduYW1lJzoKICAgICAgICBkZWZhdWx0OgogICAgICAgICAgY21wID0gY29tcGFyZVByb2NOYW1lKGEucHJvYyB8
;fCAnJywgYi5wcm9jIHx8ICcnKTsKICAgICAgICAgIGJyZWFrOwogICAgICB9CiAgICAgIGlmICghY21wICYmIGtleSAhPT0gJ25hbWUnKQogICAgICAgIGNt
;cCA9IGNvbXBhcmVQcm9jTmFtZShhLnByb2MgfHwgJycsIGIucHJvYyB8fCAnJyk7CiAgICAgIGlmICghY21wKQogICAgICAgIGNtcCA9IChOdW1iZXIoYS5w
;aWQpIHx8IDApIC0gKE51bWJlcihiLnBpZCkgfHwgMCk7CiAgICAgIGlmICghY21wKQogICAgICAgIGNtcCA9IChOdW1iZXIoYS5sb2NhbFBvcnQpIHx8IDAp
;IC0gKE51bWJlcihiLmxvY2FsUG9ydCkgfHwgMCk7CiAgICAgIHJldHVybiBjbXAgKiBkaXI7CiAgICB9KTsKICB9CiAgZnVuY3Rpb24gcmVmcmVzaFByb2NT
;b3J0SGVhZGVycygpIHsKICAgIGlmICghcHJvY0hlYWQpIHJldHVybjsKICAgIHByb2NIZWFkLnF1ZXJ5U2VsZWN0b3JBbGwoJy5wcm9jLWhjZWxsW2RhdGEt
;c29ydF0nKS5mb3JFYWNoKGNlbGwgPT4gewogICAgICBjb25zdCBrID0gY2VsbC5nZXRBdHRyaWJ1dGUoJ2RhdGEtc29ydCcpOwogICAgICBjb25zdCBvbiA9
;IGsgPT09IHByb2NTb3J0S2V5OwogICAgICBjZWxsLmNsYXNzTGlzdC50b2dnbGUoJ3NvcnRlZCcsIG9uKTsKICAgICAgY2VsbC5jbGFzc0xpc3QudG9nZ2xl
;KCdhc2MnLCBvbiAmJiBwcm9jU29ydERpciA+IDApOwogICAgICBjZWxsLmNsYXNzTGlzdC50b2dnbGUoJ2Rlc2MnLCBvbiAmJiBwcm9jU29ydERpciA8IDAp
;OwogICAgfSk7CiAgfQogIGlmIChwcm9jSGVhZCkgewogICAgcHJvY0hlYWQucXVlcnlTZWxlY3RvckFsbCgnLnByb2MtaGNlbGxbZGF0YS1zb3J0XScpLmZv
;ckVhY2goY2VsbCA9PiB7CiAgICAgIGNlbGwuYWRkRXZlbnRMaXN0ZW5lcignY2xpY2snLCAoZSkgPT4gewogICAgICAgIGUucHJldmVudERlZmF1bHQoKTsK
;ICAgICAgICBjb25zdCBrID0gY2VsbC5nZXRBdHRyaWJ1dGUoJ2RhdGEtc29ydCcpOwogICAgICAgIGlmICghaykgcmV0dXJuOwogICAgICAgIGlmIChwcm9j
;U29ydEtleSA9PT0gaykgcHJvY1NvcnREaXIgPSAtcHJvY1NvcnREaXI7CiAgICAgICAgZWxzZSB7CiAgICAgICAgICBwcm9jU29ydEtleSA9IGs7CiAgICAg
;ICAgICAvLyDotYTmupDliJfpu5jorqTpq5jihpLkvY7vvIzlkI3np7Dpu5jorqQgYeKGknoKICAgICAgICAgIHByb2NTb3J0RGlyID0gKGsgPT09ICdjcHUn
;IHx8IGsgPT09ICdtZW0nIHx8IGsgPT09ICdscG9ydCcgfHwgayA9PT0gJ3Jwb3J0JykgPyAtMSA6IDE7CiAgICAgICAgfQogICAgICAgIHJlZnJlc2hQcm9j
;U29ydEhlYWRlcnMoKTsKICAgICAgICByZW5kZXJQcm9jVGFibGUoKTsKICAgICAgfSk7CiAgICB9KTsKICAgIHJlZnJlc2hQcm9jU29ydEhlYWRlcnMoKTsK
;ICB9CiAgZnVuY3Rpb24gcGF0Y2hQcm9jSWNvbnMoaXRlbXMpIHsKICAgIGxldCBwYXRjaGVkID0gMDsKICAgIGZvciAoY29uc3QgcCBvZiBpdGVtcyB8fCBb
;XSkgewogICAgICBpZiAoIXAgfHwgIXAuaWNvbikgY29udGludWU7CiAgICAgIGNvbnN0IGtleSA9IHByb2NSb3dLZXkocCk7CiAgICAgIGNvbnN0IHJvdyA9
;IHByb2NSb3dNYXAuZ2V0KGtleSkgfHwgcHJvY0JvZHkucXVlcnlTZWxlY3RvcignLnByb2Mtcm93W2RhdGEta2V5PSInICsgQ1NTLmVzY2FwZShrZXkpICsg
;JyJdJyk7CiAgICAgIGlmICghcm93KSBjb250aW51ZTsKICAgICAgY29uc3QgbmFtZUJveCA9IHJvdy5xdWVyeVNlbGVjdG9yKCcucHJvYy1uYW1lJyk7CiAg
;ICAgIHNldFByb2NJY29uRWwobmFtZUJveCwgcC5pY29uLCBwcm9jSWNvblN0YWJsZUtleShwKSk7CiAgICAgIHBhdGNoZWQrKzsKICAgIH0KICAgIHJldHVy
;biBwYXRjaGVkID4gMCB8fCBwcm9jUm93TWFwLnNpemUgPiAwOwogIH0KICBmdW5jdGlvbiBzZWxlY3RQcm9jTmFtZUdyb3VwKHJvdywgYWRkaXRpdmUpIHsK
;ICAgIGNvbnN0IGtleSA9IHJvdy5nZXRBdHRyaWJ1dGUoJ2RhdGEta2V5Jyk7CiAgICBpZiAoIWFkZGl0aXZlKSBwcm9jU2VsS2V5cy5jbGVhcigpOwogICAg
;cHJvY1NlbEtleXMuYWRkKGtleSk7CiAgICBwcm9jQW5jaG9yS2V5ID0ga2V5OwogICAgcHJvY1NlbEtleSA9IGtleTsKICAgIHByb2NTZWxQaWQgPSBOdW1i
;ZXIocm93LmdldEF0dHJpYnV0ZSgnZGF0YS1waWQnKSkgfHwgMDsKICAgIHJlZnJlc2hQcm9jU2VsZWN0aW9uVUkoKTsKICB9CiAgZnVuY3Rpb24gc2VsZWN0
;UHJvY0Zyb21FdmVudChlLCByb3cpIHsKICAgIGNvbnN0IGtleSA9IHJvdy5nZXRBdHRyaWJ1dGUoJ2RhdGEta2V5Jyk7CiAgICBjb25zdCBwaWQgPSBOdW1i
;ZXIocm93LmdldEF0dHJpYnV0ZSgnZGF0YS1waWQnKSkgfHwgMDsKICAgIGNvbnN0IHJvd3MgPSBBcnJheS5mcm9tKHByb2NCb2R5LnF1ZXJ5U2VsZWN0b3JB
;bGwoJy5wcm9jLXJvdycpKTsKICAgIGNvbnN0IGlkeCA9IHJvd3MuaW5kZXhPZihyb3cpOwogICAgaWYgKGUuc2hpZnRLZXkgJiYgcHJvY0FuY2hvcktleSkg
;ewogICAgICBjb25zdCBhSWR4ID0gcm93cy5maW5kSW5kZXgociA9PiByLmdldEF0dHJpYnV0ZSgnZGF0YS1rZXknKSA9PT0gcHJvY0FuY2hvcktleSk7CiAg
;ICAgIGlmIChhSWR4ID49IDAgJiYgaWR4ID49IDApIHsKICAgICAgICBpZiAoIWUuY3RybEtleSkgcHJvY1NlbEtleXMuY2xlYXIoKTsKICAgICAgICBjb25z
;dCBsbyA9IE1hdGgubWluKGFJZHgsIGlkeCksIGhpID0gTWF0aC5tYXgoYUlkeCwgaWR4KTsKICAgICAgICBmb3IgKGxldCBpID0gbG87IGkgPD0gaGk7IGkr
;KykgcHJvY1NlbEtleXMuYWRkKHJvd3NbaV0uZ2V0QXR0cmlidXRlKCdkYXRhLWtleScpKTsKICAgICAgfQogICAgICBwcm9jU2VsS2V5ID0ga2V5OwogICAg
;ICBwcm9jU2VsUGlkID0gcGlkOwogICAgICByZWZyZXNoUHJvY1NlbGVjdGlvblVJKCk7CiAgICAgIHJldHVybjsKICAgIH0KICAgIGlmIChlLmN0cmxLZXkp
;IHsKICAgICAgaWYgKHByb2NTZWxLZXlzLmhhcyhrZXkpKSBwcm9jU2VsS2V5cy5kZWxldGUoa2V5KTsKICAgICAgZWxzZSBwcm9jU2VsS2V5cy5hZGQoa2V5
;KTsKICAgICAgcHJvY0FuY2hvcktleSA9IGtleTsKICAgICAgcHJvY1NlbEtleSA9IGtleTsKICAgICAgcHJvY1NlbFBpZCA9IHBpZDsKICAgICAgcmVmcmVz
;aFByb2NTZWxlY3Rpb25VSSgpOwogICAgICByZXR1cm47CiAgICB9CiAgICAvLyDmma7pgJrljZXlh7vvvJrlj6rnu5nngrnkuK3nmoTooYzlupXoibLvvJvl
;kIzlkI3mlbTmrrXnlLvmt6Hnu7/lpJbmoYYKICAgIHNlbGVjdFByb2NOYW1lR3JvdXAocm93LCBmYWxzZSk7CiAgfQogIGZ1bmN0aW9uIHJlZnJlc2hQcm9j
;U2VsZWN0aW9uVUkoKSB7CiAgICBjb25zdCByb3dzID0gQXJyYXkuZnJvbShwcm9jQm9keS5xdWVyeVNlbGVjdG9yQWxsKCcucHJvYy1yb3cnKSk7CiAgICBj
;b25zdCBHUlAgPSBbJ29uJywgJ2dycCcsICdncnAtZmlyc3QnLCAnZ3JwLW1pZCcsICdncnAtbGFzdCcsICdncnAtb25seSddOwogICAgY29uc3Qgc2VsZWN0
;ZWROYW1lcyA9IG5ldyBTZXQoKTsKICAgIHJvd3MuZm9yRWFjaChyb3cgPT4gewogICAgICBHUlAuZm9yRWFjaChjID0+IHJvdy5jbGFzc0xpc3QucmVtb3Zl
;KGMpKTsKICAgICAgY29uc3Qga2V5ID0gcm93LmdldEF0dHJpYnV0ZSgnZGF0YS1rZXknKTsKICAgICAgaWYgKHByb2NTZWxLZXlzLmhhcyhrZXkpKSB7CiAg
;ICAgICAgcm93LmNsYXNzTGlzdC5hZGQoJ29uJyk7CiAgICAgICAgY29uc3QgbmFtZSA9IFN0cmluZyhyb3cuZ2V0QXR0cmlidXRlKCdkYXRhLW5hbWUnKSB8
;fCAnJykudG9Mb3dlckNhc2UoKTsKICAgICAgICBpZiAobmFtZSkgc2VsZWN0ZWROYW1lcy5hZGQobmFtZSk7CiAgICAgIH0KICAgIH0pOwogICAgLy8g5oyJ
;6YCJ5Lit6KGM55qE6L+b56iL5ZCN77yM5oqK5ZCM5ZCN6L+e57ut5q615YyF5reh57u/5aSW5qGG77yI5peg5bqV6Imy77yJCiAgICBsZXQgaSA9IDA7CiAg
;ICB3aGlsZSAoaSA8IHJvd3MubGVuZ3RoKSB7CiAgICAgIGNvbnN0IG5hbWUgPSBTdHJpbmcocm93c1tpXS5nZXRBdHRyaWJ1dGUoJ2RhdGEtbmFtZScpIHx8
;ICcnKS50b0xvd2VyQ2FzZSgpOwogICAgICBpZiAoIW5hbWUgfHwgIXNlbGVjdGVkTmFtZXMuaGFzKG5hbWUpKSB7CiAgICAgICAgaSsrOwogICAgICAgIGNv
;bnRpbnVlOwogICAgICB9CiAgICAgIGxldCBqID0gaTsKICAgICAgd2hpbGUgKGogKyAxIDwgcm93cy5sZW5ndGgKICAgICAgICAmJiBTdHJpbmcocm93c1tq
;ICsgMV0uZ2V0QXR0cmlidXRlKCdkYXRhLW5hbWUnKSB8fCAnJykudG9Mb3dlckNhc2UoKSA9PT0gbmFtZSkgewogICAgICAgIGorKzsKICAgICAgfQogICAg
;ICBmb3IgKGxldCBrID0gaTsgayA8PSBqOyBrKyspIHsKICAgICAgICByb3dzW2tdLmNsYXNzTGlzdC5hZGQoJ2dycCcpOwogICAgICAgIGlmIChpID09PSBq
;KSByb3dzW2tdLmNsYXNzTGlzdC5hZGQoJ2dycC1vbmx5Jyk7CiAgICAgICAgZWxzZSBpZiAoayA9PT0gaSkgcm93c1trXS5jbGFzc0xpc3QuYWRkKCdncnAt
;Zmlyc3QnKTsKICAgICAgICBlbHNlIGlmIChrID09PSBqKSByb3dzW2tdLmNsYXNzTGlzdC5hZGQoJ2dycC1sYXN0Jyk7CiAgICAgICAgZWxzZSByb3dzW2td
;LmNsYXNzTGlzdC5hZGQoJ2dycC1taWQnKTsKICAgICAgfQogICAgICBpID0gaiArIDE7CiAgICB9CiAgfQogIGZ1bmN0aW9uIGNvbGxlY3RQcm9jVGFyZ2V0
;cygpIHsKICAgIGNvbnN0IG1hcCA9IG5ldyBNYXAoKTsKICAgIGZvciAoY29uc3Qga2V5IG9mIHByb2NTZWxLZXlzKSB7CiAgICAgIGNvbnN0IHJvdyA9IHBy
;b2NSb3dNYXAuZ2V0KGtleSkgfHwgcHJvY0JvZHkucXVlcnlTZWxlY3RvcignLnByb2Mtcm93W2RhdGEta2V5PSInICsgQ1NTLmVzY2FwZShrZXkpICsgJyJd
;Jyk7CiAgICAgIGxldCBwaWQgPSAwLCBuYW1lID0gJycsIHBhdGggPSAnJzsKICAgICAgaWYgKHJvdykgewogICAgICAgIHBpZCA9IE51bWJlcihyb3cuZ2V0
;QXR0cmlidXRlKCdkYXRhLXBpZCcpKSB8fCAwOwogICAgICAgIG5hbWUgPSByb3cuZ2V0QXR0cmlidXRlKCdkYXRhLW5hbWUnKSB8fCAnJzsKICAgICAgICBw
;YXRoID0gcm93LmdldEF0dHJpYnV0ZSgnZGF0YS1wYXRoJykgfHwgJyc7CiAgICAgIH0gZWxzZSB7CiAgICAgICAgY29uc3QgcCA9IHByb2NJdGVtcy5maW5k
;KHggPT4gcHJvY1Jvd0tleSh4KSA9PT0ga2V5KTsKICAgICAgICBpZiAoIXApIGNvbnRpbnVlOwogICAgICAgIHBpZCA9IE51bWJlcihwLnBpZCkgfHwgMDsK
;ICAgICAgICBuYW1lID0gcC5wcm9jIHx8ICcnOwogICAgICAgIHBhdGggPSBwLnBhdGggfHwgJyc7CiAgICAgIH0KICAgICAgaWYgKHBpZCA8PSAwIHx8IG1h
;cC5oYXMocGlkKSkgY29udGludWU7CiAgICAgIGlmICghcGF0aCkgewogICAgICAgIGNvbnN0IHAgPSBwcm9jSXRlbXMuZmluZCh4ID0+IE51bWJlcih4LnBp
;ZCkgPT09IHBpZCAmJiB4LnBhdGgpOwogICAgICAgIGlmIChwKSBwYXRoID0gcC5wYXRoIHx8ICcnOwogICAgICB9CiAgICAgIG1hcC5zZXQocGlkLCB7IHBp
;ZCwgbmFtZSwgcGF0aCB9KTsKICAgIH0KICAgIHJldHVybiBBcnJheS5mcm9tKG1hcC52YWx1ZXMoKSk7CiAgfQogIGZ1bmN0aW9uIHJlbmRlclByb2NUYWJs
;ZSgpIHsKICAgIGNvbnN0IHEgPSAocHJvY1EudmFsdWUgfHwgJycpLnRyaW0oKS50b0xvd2VyQ2FzZSgpOwogICAgbGV0IHJvd3MgPSBwcm9jSXRlbXMuc2xp
;Y2UoKTsKICAgIGlmIChxKSB7CiAgICAgIHJvd3MgPSByb3dzLmZpbHRlcihwID0+IHsKICAgICAgICBjb25zdCBoYXkgPSBbcC5wcm90bywgcC5sb2NhbElw
;LCBwLmxvY2FsUG9ydCwgcC5yZW1vdGVJcCwgcC5yZW1vdGVQb3J0LCBwLnN0YXRlLCBwLnByb2MsIHAucGlkLCBwLnBwaWRdLmpvaW4oJyAnKS50b0xvd2Vy
;Q2FzZSgpOwogICAgICAgIHJldHVybiBoYXkuaW5jbHVkZXMocSk7CiAgICAgIH0pOwogICAgfQogICAgcm93cyA9IHNvcnRQcm9jUm93c0ZsYXQocm93cyk7
;CiAgICBjb25zdCBwaWRTZXQgPSBuZXcgU2V0KCk7CiAgICBmb3IgKGNvbnN0IHAgb2Ygcm93cykgewogICAgICBjb25zdCBpZCA9IE51bWJlcihwLnBpZCkg
;fHwgMDsKICAgICAgaWYgKGlkID4gMCkgcGlkU2V0LmFkZChpZCk7CiAgICB9CiAgICBwcm9jQ291bnQudGV4dENvbnRlbnQgPSBTdHJpbmcocGlkU2V0LnNp
;emUgfHwgcm93cy5sZW5ndGgpOwogICAgaWYgKCFyb3dzLmxlbmd0aCkgewogICAgICBwcm9jQm9keS5pbm5lckhUTUwgPSAnPGRpdiBzdHlsZT0icGFkZGlu
;ZzoyNHB4O3RleHQtYWxpZ246Y2VudGVyO2NvbG9yOiM5YWExYjIiPuayoeacieWMuemFjeeahOi/nuaOpTwvZGl2Pic7CiAgICAgIHByb2NSb3dNYXAuY2xl
;YXIoKTsKICAgICAgcHJvY1NlbEtleXMuY2xlYXIoKTsKICAgICAgcHJvY0FuY2hvcktleSA9ICcnOwogICAgICBwcm9jU2VsS2V5ID0gJyc7CiAgICAgIHBy
;b2NTZWxQaWQgPSAwOwogICAgICByZXR1cm47CiAgICB9CiAgICAvLyDlop7ph4/mm7TmlrDvvJrlpI3nlKjooYzkuI7lm77moIfoioLngrnvvIzlj6rmlLnm
;loflrZfvvIzpgb/lhY3mlbTooajph43lu7rpl6rlm77moIcKICAgIGNvbnN0IGtlZXAgPSBuZXcgU2V0KCk7CiAgICBjb25zdCBlbXB0eUhpbnQgPSBwcm9j
;Qm9keS5xdWVyeVNlbGVjdG9yKCdkaXZbc3R5bGVdJyk7CiAgICBpZiAoZW1wdHlIaW50KSB7CiAgICAgIHByb2NCb2R5LmlubmVySFRNTCA9ICcnOwogICAg
;ICBwcm9jUm93TWFwLmNsZWFyKCk7CiAgICB9CiAgICBmb3IgKGxldCBpID0gMDsgaSA8IHJvd3MubGVuZ3RoOyBpKyspIHsKICAgICAgY29uc3QgcCA9IHJv
;d3NbaV07CiAgICAgIGNvbnN0IGtleSA9IHByb2NSb3dLZXkocCk7CiAgICAgIGtlZXAuYWRkKGtleSk7CiAgICAgIGxldCByb3cgPSBwcm9jUm93TWFwLmdl
;dChrZXkpOwogICAgICBpZiAoIXJvdyB8fCAhcm93LmlzQ29ubmVjdGVkKSB7CiAgICAgICAgcm93ID0gZW5zdXJlUHJvY1JvdyhwKTsKICAgICAgICBwcm9j
;Um93TWFwLnNldChrZXksIHJvdyk7CiAgICAgIH0KICAgICAgdXBkYXRlUHJvY1Jvd0RhdGEocm93LCBwKTsKICAgICAgY29uc3QgYXQgPSBwcm9jQm9keS5j
;aGlsZHJlbltpXTsKICAgICAgaWYgKGF0ICE9PSByb3cpIHsKICAgICAgICBpZiAoYXQpIHByb2NCb2R5Lmluc2VydEJlZm9yZShyb3csIGF0KTsKICAgICAg
;ICBlbHNlIHByb2NCb2R5LmFwcGVuZENoaWxkKHJvdyk7CiAgICAgIH0KICAgIH0KICAgIC8vIOWIoOaOieS4jeWGjeWtmOWcqOeahOihjAogICAgZm9yIChj
;b25zdCBba2V5LCByb3ddIG9mIEFycmF5LmZyb20ocHJvY1Jvd01hcC5lbnRyaWVzKCkpKSB7CiAgICAgIGlmIChrZWVwLmhhcyhrZXkpKSBjb250aW51ZTsK
;ICAgICAgcHJvY1Jvd01hcC5kZWxldGUoa2V5KTsKICAgICAgaWYgKHJvdyAmJiByb3cucGFyZW50Tm9kZSkgcm93LnBhcmVudE5vZGUucmVtb3ZlQ2hpbGQo
;cm93KTsKICAgIH0KICAgIGZvciAoY29uc3Qga2V5IG9mIEFycmF5LmZyb20ocHJvY1NlbEtleXMpKSB7CiAgICAgIGlmICgha2VlcC5oYXMoa2V5KSkgcHJv
;Y1NlbEtleXMuZGVsZXRlKGtleSk7CiAgICB9CiAgICBpZiAocHJvY1NlbEtleSAmJiAhcHJvY1NlbEtleXMuaGFzKHByb2NTZWxLZXkpKSB7CiAgICAgIHBy
;b2NTZWxLZXkgPSBwcm9jU2VsS2V5cy5zaXplID8gQXJyYXkuZnJvbShwcm9jU2VsS2V5cylbMF0gOiAnJzsKICAgICAgcHJvY1NlbFBpZCA9IDA7CiAgICAg
;IGlmIChwcm9jU2VsS2V5KSB7CiAgICAgICAgY29uc3QgciA9IHByb2NSb3dNYXAuZ2V0KHByb2NTZWxLZXkpOwogICAgICAgIHByb2NTZWxQaWQgPSByID8g
;KE51bWJlcihyLmdldEF0dHJpYnV0ZSgnZGF0YS1waWQnKSkgfHwgMCkgOiAwOwogICAgICB9CiAgICB9CiAgICByZWZyZXNoUHJvY1NlbGVjdGlvblVJKCk7
;CiAgfQogIGZ1bmN0aW9uIGluZm9Sb3cobGFiLCB2YWxIdG1sLCBsaW5rSHRtbCkgewogICAgcmV0dXJuICc8ZGl2IGNsYXNzPSJpbmZvLXJvdyI+JwogICAg
;ICArICc8ZGl2IGNsYXNzPSJpbmZvLWxhYiI+JyArIGVzY2FwZUh0bWwobGFiKSArICc8L2Rpdj4nCiAgICAgICsgJzxkaXYgY2xhc3M9ImluZm8tZGFzaCI+
;PC9kaXY+JwogICAgICArICc8ZGl2IGNsYXNzPSJpbmZvLXZhbCI+JyArICh2YWxIdG1sIHx8ICcnKSArICc8L2Rpdj4nCiAgICAgICsgKGxpbmtIdG1sIHx8
;ICc8c3Bhbj48L3NwYW4+JykKICAgICAgKyAnPC9kaXY+JzsKICB9CiAgZnVuY3Rpb24gcmVuZGVyU3lzSW5mbygpIHsKICAgIGNvbnN0IGQgPSBpbmZvRGF0
;YSB8fCB7fTsKICAgIGxldCBodG1sID0gJyc7CiAgICBodG1sICs9IGluZm9Sb3coJ+aTjeS9nOezu+e7nycsIGVzY2FwZUh0bWwoZC5vcyB8fCAn5pyq55+l
;JykpOwogICAgaHRtbCArPSBpbmZvUm93KCfkuLvmnb8nLCBlc2NhcGVIdG1sKGQuYm9hcmQgfHwgJ+acquefpScpKTsKICAgIGh0bWwgKz0gaW5mb1Jvdygn
;5pi+56S65ZmoJywgZXNjYXBlSHRtbChkLm1vbml0b3IgfHwgJ+acquefpScpKTsKICAgIGh0bWwgKz0gaW5mb1Jvdygn5aSE55CG5ZmoJywgZXNjYXBlSHRt
;bChkLmNwdSB8fCAn5pyq55+lJykpOwogICAgaHRtbCArPSBpbmZvUm93KCflhoXlrZgnLCBlc2NhcGVIdG1sKGQubWVtb3J5IHx8ICfmnKrnn6UnKSk7CiAg
;ICBodG1sICs9IGluZm9Sb3coJ+ehrOebmCcsIGVzY2FwZUh0bWwoZC5kaXNrIHx8ICfmnKrnn6UnKSk7CiAgICBodG1sICs9IGluZm9Sb3coJ+aYvuWNoScs
;IGVzY2FwZUh0bWwoZC5ncHUgfHwgJ+acquefpScpKTsKICAgIGNvbnN0IHNvdW5kcyA9IEFycmF5LmlzQXJyYXkoZC5zb3VuZCkgPyBkLnNvdW5kIDogW107
;CiAgICBodG1sICs9IGluZm9Sb3coJ+WjsOWNoScsIHNvdW5kcy5sZW5ndGgKICAgICAgPyBzb3VuZHMubWFwKHMgPT4gJzxzcGFuIGNsYXNzPSJsaW5lIj4n
;ICsgZXNjYXBlSHRtbChzKSArICc8L3NwYW4+Jykuam9pbignJykKICAgICAgOiBlc2NhcGVIdG1sKCfmnKrnn6UnKSk7CiAgICBjb25zdCBuZXRzID0gQXJy
;YXkuaXNBcnJheShkLm5pY3MpID8gZC5uaWNzIDogW107CiAgICBsZXQgbmV0SHRtbCA9ICfmnKrnn6UnOwogICAgaWYgKG5ldHMubGVuZ3RoKSB7CiAgICAg
;IG5ldEh0bWwgPSBuZXRzLm1hcChuID0+IHsKICAgICAgICBjb25zdCBuYW1lID0gZXNjYXBlSHRtbChuLm5hbWUgfHwgJycpOwogICAgICAgIGNvbnN0IG1h
;YyA9IGVzY2FwZUh0bWwobi5tYWMgfHwgJ+KAlCcpOwogICAgICAgIGNvbnN0IGlwUmF3ID0gKG4uaXAgJiYgU3RyaW5nKG4uaXApLnRyaW0oKSkgPyBTdHJp
;bmcobi5pcCkudHJpbSgpIDogJzAuMC4wLjAnOwogICAgICAgIGNvbnN0IGlwID0gZXNjYXBlSHRtbChpcFJhdyA9PT0gJ+KAlCcgPyAnMC4wLjAuMCcgOiBp
;cFJhdyk7CiAgICAgICAgcmV0dXJuICc8ZGl2IGNsYXNzPSJuZXQtbGluZSI+PHNwYW4+JyArIG5hbWUgKyAnPC9zcGFuPicKICAgICAgICAgICsgJzxzcGFu
;PjxzcGFuIGNsYXNzPSJrIj5NQUPlnLDlnYA6IDwvc3Bhbj4nICsgbWFjICsgJzwvc3Bhbj4nCiAgICAgICAgICArICc8c3Bhbj48c3BhbiBjbGFzcz0iayI+
;SVDlnLDlnYA6IDwvc3Bhbj4nICsgaXAgKyAnPC9zcGFuPjwvZGl2Pic7CiAgICAgIH0pLmpvaW4oJycpOwogICAgfQogICAgaHRtbCArPSBpbmZvUm93KCfn
;vZHljaEnLCBuZXRIdG1sKTsKICAgIGh0bWwgKz0gaW5mb1Jvdygn5aSW572RSVAnLCBlc2NhcGVIdG1sKGQud2FuIHx8ICfmnKrnn6UnKSk7CiAgICBodG1s
;ICs9IGluZm9Sb3coJ0lF54mI5pysJywgZXNjYXBlSHRtbChkLmllIHx8ICfmnKrnn6UnKSk7CiAgICBodG1sICs9IGluZm9Sb3coJ0ZsYXNo54mI5pysJywg
;ZXNjYXBlSHRtbChkLmZsYXNoIHx8ICfmnKrnn6UnKSk7CiAgICBjb25zdCBib290RXh0cmEgPSAnPHNwYW4gY2xhc3M9InN1YiI+57O757uf5bey6L+Q6KGM
;OiA8c3BhbiBpZD0iaW5mby11cHRpbWUiPicKICAgICAgKyBlc2NhcGVIdG1sKGZvcm1hdFVwdGltZVRleHQoY3VycmVudFVwdGltZVNlYygpKSkgKyAnPC9z
;cGFuPjwvc3Bhbj4nOwogICAgaHRtbCArPSBpbmZvUm93KCflvIDmnLrml7bpl7QnLCBlc2NhcGVIdG1sKGQuYm9vdCB8fCAn5pyq55+lJykgKyBib290RXh0
;cmEpOwogICAgaHRtbCArPSBpbmZvUm93KCfkuIrmrKHlhbPmnLrml7bpl7QnLCBlc2NhcGVIdG1sKGQuc2h1dGRvd24gfHwgJ+acquefpScpKTsKICAgIGh0
;bWwgKz0gaW5mb1Jvdygn57O757uf5a6J6KOF5pel5pyfJywgZXNjYXBlSHRtbChkLmluc3RhbGwgfHwgJ+acquefpScpKTsKICAgIGluZm9QYW5lbC5pbm5l
;ckhUTUwgPSBodG1sOwogIH0KICBmdW5jdGlvbiBjdXJyZW50VXB0aW1lU2VjKCkgewogICAgY29uc3QgYmFzZSA9IE51bWJlcihpbmZvRGF0YSAmJiBpbmZv
;RGF0YS51cHRpbWVTZWMpIHx8IDA7CiAgICBjb25zdCBzeW5jZWQgPSBOdW1iZXIoaW5mb0RhdGEgJiYgaW5mb0RhdGEuX3N5bmNlZEF0KSB8fCBEYXRlLm5v
;dygpOwogICAgcmV0dXJuIE1hdGgubWF4KDAsIE1hdGguZmxvb3IoYmFzZSArIChEYXRlLm5vdygpIC0gc3luY2VkKSAvIDEwMDApKTsKICB9CiAgZnVuY3Rp
;b24gZm9ybWF0VXB0aW1lVGV4dChzZWMpIHsKICAgIHNlYyA9IE1hdGgubWF4KDAsIE1hdGguZmxvb3IoTnVtYmVyKHNlYykgfHwgMCkpOwogICAgY29uc3Qg
;ZCA9IE1hdGguZmxvb3Ioc2VjIC8gODY0MDApOwogICAgY29uc3QgaCA9IE1hdGguZmxvb3IoKHNlYyAlIDg2NDAwKSAvIDM2MDApOwogICAgY29uc3QgbWkg
;PSBNYXRoLmZsb29yKChzZWMgJSAzNjAwKSAvIDYwKTsKICAgIGNvbnN0IHMgPSBzZWMgJSA2MDsKICAgIHJldHVybiAoZCA+IDAgPyAoZCArICflpKknKSA6
;ICcnKSArIGggKyAn5bCP5pe2JyArIG1pICsgJ+WIhumSnycgKyBzICsgJ+enkic7CiAgfQogIGZ1bmN0aW9uIHRpY2tJbmZvVXB0aW1lKCkgewogICAgaWYg
;KG1vbml0b3JUYWIgIT09ICdpbmZvJykgcmV0dXJuOwogICAgY29uc3QgZWwgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnaW5mby11cHRpbWUnKTsKICAg
;IGlmICghZWwpIHJldHVybjsKICAgIGVsLnRleHRDb250ZW50ID0gZm9ybWF0VXB0aW1lVGV4dChjdXJyZW50VXB0aW1lU2VjKCkpOwogIH0KICBzZXRJbnRl
;cnZhbCh0aWNrSW5mb1VwdGltZSwgMTAwMCk7CgogIHdpbmRvdy5fX3NldFByb2Nlc3NlcyA9IChwYXlsb2FkKSA9PiB7CiAgICAvLyDov5vnqIvnm5Hmjqfl
;t7LmlLnkuLrov57mjqXliJfooajvvIzlv73nlaXml6fov5vnqIvmjqjpgIEKICB9OwogIHdpbmRvdy5fX3NldFBvcnRzID0gKHBheWxvYWQpID0+IHsKICAg
;IHRyeSB7CiAgICAgIGNvbnN0IGRhdGEgPSB0eXBlb2YgcGF5bG9hZCA9PT0gJ3N0cmluZycgPyBKU09OLnBhcnNlKHBheWxvYWQpIDogcGF5bG9hZDsKICAg
;ICAgY29uc3QgbmV4dCA9IEFycmF5LmlzQXJyYXkoZGF0YSkgPyBkYXRhIDogKEFycmF5LmlzQXJyYXkoZGF0YSAmJiBkYXRhLml0ZW1zKSA/IGRhdGEuaXRl
;bXMgOiBbXSk7CiAgICAgIGlmIChkYXRhICYmICFBcnJheS5pc0FycmF5KGRhdGEpKSB7CiAgICAgICAgaWYgKHByb2NDcHVUb3RhbCAmJiBkYXRhLmNwdVRv
;dGFsICE9IG51bGwpIHByb2NDcHVUb3RhbC50ZXh0Q29udGVudCA9IFN0cmluZyhkYXRhLmNwdVRvdGFsKTsKICAgICAgICBpZiAocHJvY01lbVRvdGFsICYm
;IGRhdGEubWVtVG90YWwgIT0gbnVsbCkgcHJvY01lbVRvdGFsLnRleHRDb250ZW50ID0gU3RyaW5nKGRhdGEubWVtVG90YWwpOwogICAgICAgIHVwZGF0ZUhl
;YWRIZWF0KGRhdGEuY3B1VG90YWwsIGRhdGEubWVtVG90YWwpOwogICAgICB9CiAgICAgIGNvbnN0IHNjcm9sbGVyID0gcHJvY1Njcm9sbCB8fCBwcm9jQm9k
;eTsKICAgICAgY29uc3QgcHJldlNjcm9sbCA9IHNjcm9sbGVyID8gc2Nyb2xsZXIuc2Nyb2xsVG9wIDogMDsKICAgICAgY29uc3Qgc2FtZUNvbnRlbnQgPSBw
;b3J0c0NvbnRlbnRTaWcobmV4dCkgPT09IHBvcnRzQ29udGVudFNpZyhwcm9jSXRlbXMpOwogICAgICBwcm9jSXRlbXMgPSBuZXh0OwogICAgICBpZiAobW9u
;aXRvclRhYiAhPT0gJ3Byb2MnKSByZXR1cm47CiAgICAgIGlmIChzYW1lQ29udGVudCkgewogICAgICAgIC8vIOWPquihpeWbvuagh++8jOS4jemHjeW7uuih
;jAogICAgICAgIHBhdGNoUHJvY0ljb25zKG5leHQpOwogICAgICAgIGlmIChzY3JvbGxlcikgc2Nyb2xsZXIuc2Nyb2xsVG9wID0gcHJldlNjcm9sbDsKICAg
;ICAgICByZXR1cm47CiAgICAgIH0KICAgICAgcmVuZGVyUHJvY1RhYmxlKCk7CiAgICAgIGlmIChzY3JvbGxlcikgc2Nyb2xsZXIuc2Nyb2xsVG9wID0gcHJl
;dlNjcm9sbDsKICAgIH0gY2F0Y2ggKGUpIHsgY29uc29sZS53YXJuKCdzZXRQb3J0cycsIGUpOyB9CiAgfTsKICB3aW5kb3cuX19zZXRIYW5kbGVzID0gKHBh
;eWxvYWQpID0+IHsKICAgIHRyeSB7CiAgICAgIGNvbnN0IGRhdGEgPSB0eXBlb2YgcGF5bG9hZCA9PT0gJ3N0cmluZycgPyBKU09OLnBhcnNlKHBheWxvYWQp
;IDogcGF5bG9hZDsKICAgICAgaGFuZGxlQnVzeSA9IGZhbHNlOwogICAgICBoYW5kbGVJdGVtcyA9IHNvcnRIYW5kbGVJdGVtcyhBcnJheS5pc0FycmF5KGRh
;dGEgJiYgZGF0YS5pdGVtcykgPyBkYXRhLml0ZW1zIDogKEFycmF5LmlzQXJyYXkoZGF0YSkgPyBkYXRhIDogW10pKTsKICAgICAgaWYgKGRhdGEgJiYgZGF0
;YS5xICE9IG51bGwpIGhhbmRsZVF1ZXJ5ID0gU3RyaW5nKGRhdGEucSk7CiAgICAgIGlmIChkYXRhICYmIGRhdGEubW9kZSkgaGFuZGxlTW9kZSA9IFN0cmlu
;ZyhkYXRhLm1vZGUpID09PSAncG9ydCcgPyAncG9ydCcgOiAnaGFuZGxlJzsKICAgICAgZWxzZSBoYW5kbGVNb2RlID0gaXNQb3J0U2VhcmNoUXVlcnkoaGFu
;ZGxlUXVlcnkpID8gJ3BvcnQnIDogJ2hhbmRsZSc7CiAgICAgIGNvbnN0IGVyciA9IGRhdGEgJiYgZGF0YS5lcnJvciA/IFN0cmluZyhkYXRhLmVycm9yKSA6
;ICcnOwogICAgICBpZiAoaGFuZGxlU3RhdHVzKSBoYW5kbGVTdGF0dXMudGV4dENvbnRlbnQgPSBlcnIgfHwgKGhhbmRsZUl0ZW1zLmxlbmd0aCA/ICcnIDog
;J+aXoOe7k+aenCcpOwogICAgICBpZiAoYXBwTW9kZSA9PT0gJ2hhbmRsZScpIHsKICAgICAgICByZW5kZXJIYW5kbGVUYWJsZShlcnIgfHwgJycpOwogICAg
;ICAgIGNvdW50RWwudGV4dENvbnRlbnQgPSAn5YWxICcgKyBoYW5kbGVJdGVtcy5sZW5ndGggKyAnIOadoSc7CiAgICAgIH0KICAgIH0gY2F0Y2ggKGUpIHsK
;ICAgICAgaGFuZGxlQnVzeSA9IGZhbHNlOwogICAgICBjb25zb2xlLndhcm4oJ3NldEhhbmRsZXMnLCBlKTsKICAgIH0KICB9OwogIHdpbmRvdy5fX3Byb2NL
;aWxsZWQgPSAocGlkcykgPT4gewogICAgdHJ5IHsKICAgICAgY29uc3QgbGlzdCA9IEFycmF5LmlzQXJyYXkocGlkcykgPyBwaWRzIDogW107CiAgICAgIHJl
;bW92ZVJvd3NCeVBpZHMobGlzdCk7CiAgICB9IGNhdGNoIChlKSB7IGNvbnNvbGUud2FybigncHJvY0tpbGxlZCcsIGUpOyB9CiAgfTsKICBmdW5jdGlvbiBy
;ZW1vdmVSb3dzQnlQaWRzKHBpZHMpIHsKICAgIGNvbnN0IHNldCA9IG5ldyBTZXQoKHBpZHMgfHwgW10pLm1hcChuID0+IE51bWJlcihuKSkuZmlsdGVyKG4g
;PT4gbiA+IDApKTsKICAgIGlmICghc2V0LnNpemUpIHJldHVybjsKICAgIGNvbnN0IGJlZm9yZUggPSBoYW5kbGVJdGVtcy5sZW5ndGg7CiAgICBoYW5kbGVJ
;dGVtcyA9IGhhbmRsZUl0ZW1zLmZpbHRlcihpdCA9PiAhc2V0LmhhcyhOdW1iZXIoaXQucGlkKSB8fCAwKSk7CiAgICBpZiAoaGFuZGxlSXRlbXMubGVuZ3Ro
;ICE9PSBiZWZvcmVIKSB7CiAgICAgIGZvciAoY29uc3QgayBvZiBBcnJheS5mcm9tKGhhbmRsZVNlbEtleXMpKSB7CiAgICAgICAgY29uc3Qgcm93ID0gaGFu
;ZGxlQm9keS5xdWVyeVNlbGVjdG9yKCcuaGFuZGxlLXJvd1tkYXRhLWtleT0iJyArIENTUy5lc2NhcGUoaykgKyAnIl0nKTsKICAgICAgICBjb25zdCBwaWQg
;PSByb3cgPyAoTnVtYmVyKHJvdy5nZXRBdHRyaWJ1dGUoJ2RhdGEtcGlkJykpIHx8IDApIDogMDsKICAgICAgICBpZiAoc2V0LmhhcyhwaWQpKSBoYW5kbGVT
;ZWxLZXlzLmRlbGV0ZShrKTsKICAgICAgfQogICAgICBpZiAoYXBwTW9kZSA9PT0gJ2hhbmRsZScpCiAgICAgICAgcmVuZGVySGFuZGxlVGFibGUoJycpOwog
;ICAgICBpZiAoYXBwTW9kZSA9PT0gJ2hhbmRsZScpCiAgICAgICAgY291bnRFbC50ZXh0Q29udGVudCA9ICflhbEgJyArIGhhbmRsZUl0ZW1zLmxlbmd0aCAr
;ICcg5p2hJzsKICAgIH0KICB9OwogIHdpbmRvdy5fX3NldFN5c0luZm8gPSAocGF5bG9hZCkgPT4gewogICAgdHJ5IHsKICAgICAgaW5mb1JlcUdlbiArPSAx
;OwogICAgICBjbGVhckluZm9Mb2FkV2FpdCgpOwogICAgICBjb25zdCBkYXRhID0gdHlwZW9mIHBheWxvYWQgPT09ICdzdHJpbmcnID8gSlNPTi5wYXJzZShw
;YXlsb2FkKSA6IHBheWxvYWQ7CiAgICAgIGNvbnN0IHByZXZTZWMgPSBpbmZvRGF0YSAmJiBpbmZvRGF0YS51cHRpbWVTZWM7CiAgICAgIGNvbnN0IHByZXZT
;eW5jID0gaW5mb0RhdGEgJiYgaW5mb0RhdGEuX3N5bmNlZEF0OwogICAgICBpbmZvRGF0YSA9IGRhdGEgfHwge307CiAgICAgIC8vIOWQjOS4gOS7vee8k+Wt
;mOWGjeasoeaOqOmAgeaXtuS/neeVmeWQjOatpeeCue+8jOmBv+WFjei/kOihjOaXtumXtOiiq+mHjee9rgogICAgICBpZiAocHJldlN5bmMgJiYgcHJldlNl
;YyAhPSBudWxsICYmIE51bWJlcihpbmZvRGF0YS51cHRpbWVTZWMpID09PSBOdW1iZXIocHJldlNlYykpCiAgICAgICAgaW5mb0RhdGEuX3N5bmNlZEF0ID0g
;cHJldlN5bmM7CiAgICAgIGVsc2UKICAgICAgICBpbmZvRGF0YS5fc3luY2VkQXQgPSBEYXRlLm5vdygpOwogICAgICBpZiAoaW5mb0RhdGEudXB0aW1lU2Vj
;ID09IG51bGwgJiYgaW5mb0RhdGEudXB0aW1lKQogICAgICAgIGluZm9EYXRhLnVwdGltZVNlYyA9IDA7CiAgICAgIGluZm9UZXh0ID0gU3RyaW5nKGRhdGEg
;JiYgZGF0YS50ZXh0IHx8ICcnKTsKICAgICAgaWYgKGFwcE1vZGUgPT09ICdpbmZvJykgewogICAgICAgIHJlbmRlclN5c0luZm8oKTsKICAgICAgICBpZiAo
;Y291bnRFbCkgY291bnRFbC50ZXh0Q29udGVudCA9ICfmnKzmnLrkv6Hmga8nOwogICAgICB9CiAgICB9IGNhdGNoIChlKSB7IGNvbnNvbGUud2Fybignc2V0
;U3lzSW5mbycsIGUpOyB9CiAgfTsKCiAgLy8g4pSA4pSAIOi/kOihjOmFjee9riAvIOWPluWAvOmFjee9riAvIOezu+e7n+mFjee9riDilIDilIDilIDilIDi
;lIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIAKICBjb25zdCBjZmdCb2R5ID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2NmZy1ib2R5
;Jyk7CiAgY29uc3QgY2ZnU3RhdHVzID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2NmZy1zdGF0dXMnKTsKICBjb25zdCBjZmdNZW51ID0gZG9jdW1lbnQu
;Z2V0RWxlbWVudEJ5SWQoJ2NmZy1tZW51Jyk7CiAgY29uc3QgY2ZnVGlwRWwgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnY2ZnLXRpcCcpOwogIGNvbnN0
;IGNmZ1RpcEVkaXRFbCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjZmctdGlwLWVkaXQnKTsKICBjb25zdCBjZmdUaXBXcmFwRWwgPSBkb2N1bWVudC5n
;ZXRFbGVtZW50QnlJZCgnY2ZnLXRpcC13cmFwJyk7CiAgY29uc3QgY2ZnQ2FjaGUgPSB7IHJ1bmNvbmZpZzogbnVsbCwgZ2V0Y29uZmlnOiBudWxsLCBzeXNj
;b25maWc6IG51bGwgfTsKICBjb25zdCBjZmdEaXJ0eSA9IHsgcnVuY29uZmlnOiBmYWxzZSwgZ2V0Y29uZmlnOiBmYWxzZSwgc3lzY29uZmlnOiBmYWxzZSB9
;OwogIGNvbnN0IGNmZ1BhdGhzID0geyBydW5jb25maWc6ICcnLCBnZXRjb25maWc6ICcnLCBzeXNjb25maWc6ICcnIH07CiAgY29uc3QgQ0ZHX1RJUF9TRVBf
;REVGQVVMVCA9IDEwMTsKICBjb25zdCBDRkdfVElQX0hBU0hfREVGQVVMVCA9IDM7CiAgY29uc3QgY2ZnSWNvbkNhY2hlID0gbmV3IE1hcCgpOwogIGNvbnN0
;IGNmZ09wZW5NYXAgPSBPYmplY3QuY3JlYXRlKG51bGwpOyAvLyB0YWIgLT4geyBbZ2ldOiB0cnVlIH0KICBsZXQgY2ZnVWlSZWFkeSA9IGZhbHNlOwogIGxl
;dCBjZmdTZWFyY2ggPSAnJzsKICBsZXQgY2ZnU2VhcmNoU2NvcGUgPSB7IGtleTogZmFsc2UsIHZhbHVlOiBmYWxzZSwgZW5hYmxlZDogZmFsc2UsIGRpc2Fi
;bGVkOiBmYWxzZSB9OwogIGNvbnN0IGNmZ1NlYXJjaEhpdEVsID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2NmZy1zZWFyY2gtaGl0Jyk7CiAgY29uc3Qg
;Y2ZnU2VhcmNoQ2xlYXJFbCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjZmctc2VhcmNoLWNsZWFyJyk7CiAgbGV0IGNmZ0xvYWRHZW4gPSAwOwogIGxl
;dCBjZmdJY29uU2VxID0gMDsKICBsZXQgY2ZnU2VsID0geyBnaTogLTEsIGlpOiAtMSB9OwogIGxldCBjZmdNZW51Q3R4ID0gbnVsbDsKCiAgY29uc3QgQ0ZH
;X1NWRyA9IHsKICAgIHdlYjogJzxzdmcgdmlld0JveD0iMCAwIDI0IDI0IiBmaWxsPSJub25lIiBzdHJva2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRo
;PSIxLjgiPjxjaXJjbGUgY3g9IjEyIiBjeT0iMTIiIHI9IjkiLz48cGF0aCBkPSJNMyAxMmgxOE0xMiAzYTE0IDE0IDAgMCAxIDAgMThNMTIgM2ExNCAxNCAw
;IDAgMCAwIDE4Ii8+PC9zdmc+JywKICAgIGZvbGRlcjogJzxzdmcgdmlld0JveD0iMCAwIDI0IDI0IiBmaWxsPSJub25lIiBzdHJva2U9ImN1cnJlbnRDb2xv
;ciIgc3Ryb2tlLXdpZHRoPSIxLjgiPjxwYXRoIGQ9Ik0zIDcuNUExLjUgMS41IDAgMCAxIDQuNSA2SDlsMiAyaDguNUExLjUgMS41IDAgMCAxIDIxIDkuNXY3
;QTEuNSAxLjUgMCAwIDEgMTkuNSAxOGgtMTVBMS41IDEuNSAwIDAgMSAzIDE2LjV2LTl6Ii8+PC9zdmc+JywKICAgIGNtZDogJzxzdmcgdmlld0JveD0iMCAw
;IDI0IDI0IiBmaWxsPSJub25lIiBzdHJva2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIxLjgiPjxyZWN0IHg9IjMiIHk9IjUiIHdpZHRoPSIxOCIg
;aGVpZ2h0PSIxNCIgcng9IjIiLz48cGF0aCBkPSJNNyAxMGwzIDItMyAyTTEyIDE0aDUiLz48L3N2Zz4nLAogICAgZmlsZTogJzxzdmcgdmlld0JveD0iMCAw
;IDI0IDI0IiBmaWxsPSJub25lIiBzdHJva2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIxLjgiPjxwYXRoIGQ9Ik03IDMuNWg3bDQgNFYyMGExLjUg
;MS41IDAgMCAxLTEuNSAxLjVoLTkuNUExLjUgMS41IDAgMCAxIDUuNSAyMFY1QTEuNSAxLjUgMCAwIDEgNyAzLjV6Ii8+PHBhdGggZD0iTTE0IDMuNVY4aDQu
;NSIvPjwvc3ZnPicKICB9OwoKICBmdW5jdGlvbiB0ZXh0VG9CNjQocykgewogICAgdHJ5IHsgcmV0dXJuIGJ0b2EodW5lc2NhcGUoZW5jb2RlVVJJQ29tcG9u
;ZW50KFN0cmluZyhzIHx8ICcnKSkpKTsgfQogICAgY2F0Y2ggKF8pIHsgcmV0dXJuICcnOyB9CiAgfQogIGxldCBjZmdTdGF0dXNUaW1lciA9IDA7CiAgZnVu
;Y3Rpb24gc2V0Q2ZnU3RhdHVzKG1zZywga2luZCkgewogICAgaWYgKCFjZmdTdGF0dXMpIHJldHVybjsKICAgIGlmIChjZmdTdGF0dXNUaW1lcikgewogICAg
;ICBjbGVhclRpbWVvdXQoY2ZnU3RhdHVzVGltZXIpOwogICAgICBjZmdTdGF0dXNUaW1lciA9IDA7CiAgICB9CiAgICBjb25zdCB0ZXh0ID0gU3RyaW5nKG1z
;ZyB8fCAnJykudHJpbSgpOwogICAgaWYgKCF0ZXh0KSB7CiAgICAgIGNmZ1N0YXR1cy50ZXh0Q29udGVudCA9ICcnOwogICAgICBjZmdTdGF0dXMuY2xhc3NO
;YW1lID0gJyc7CiAgICAgIHJldHVybjsKICAgIH0KICAgIGNvbnN0IGsgPSBraW5kID09PSAnb2snID8gJ29rJyA6IChraW5kID09PSAnaW5mbycgPyAnaW5m
;bycgOiAnZXJyJyk7CiAgICBjZmdTdGF0dXMudGV4dENvbnRlbnQgPSB0ZXh0OwogICAgY2ZnU3RhdHVzLmNsYXNzTmFtZSA9IGs7CiAgICBpZiAoayA9PT0g
;J29rJyB8fCBrID09PSAnaW5mbycpIHsKICAgICAgY2ZnU3RhdHVzVGltZXIgPSBzZXRUaW1lb3V0KCgpID0+IHsKICAgICAgICBpZiAoY2ZnU3RhdHVzICYm
;IGNmZ1N0YXR1cy5jbGFzc05hbWUgPT09IGsgJiYgY2ZnU3RhdHVzLnRleHRDb250ZW50ID09PSB0ZXh0KSB7CiAgICAgICAgICBjZmdTdGF0dXMudGV4dENv
;bnRlbnQgPSAnJzsKICAgICAgICAgIGNmZ1N0YXR1cy5jbGFzc05hbWUgPSAnJzsKICAgICAgICB9CiAgICAgICAgY2ZnU3RhdHVzVGltZXIgPSAwOwogICAg
;ICB9LCAzMjAwKTsKICAgIH0KICB9CiAgZnVuY3Rpb24gdXBkYXRlQ2ZnUGF0aEJhcihleHRyYSkgewogICAgY29uc3QgcGF0aEVsID0gZG9jdW1lbnQuZ2V0
;RWxlbWVudEJ5SWQoJ2NmZy1wYXRoLWxhYmVsJyk7CiAgICBjb25zdCBmaWxlUGF0aCA9IGNmZ1BhdGhzW2NmZ0FjdGl2ZVRhYl0gfHwgKGNmZ0FjdGl2ZVRh
;YiArICcudHh0Jyk7CiAgICBjb25zdCB0aXAgPSBTdHJpbmcoZXh0cmEgfHwgJycpLnRyaW0oKTsKICAgIGNvbnN0IHRleHQgPSB0aXAgfHwgZmlsZVBhdGg7
;CiAgICBpZiAocGF0aEVsKSB7CiAgICAgIHBhdGhFbC50ZXh0Q29udGVudCA9IHRleHQ7CiAgICAgIHBhdGhFbC50aXRsZSA9IHRleHQ7CiAgICB9CiAgICBp
;ZiAoY291bnRFbCAmJiBhcHBNb2RlID09PSAnY29uZmlnJykgewogICAgICBjb3VudEVsLnRleHRDb250ZW50ID0gJyc7CiAgICB9CiAgfQogIGZ1bmN0aW9u
;IHN5bmNDZmdUaXBVaSgpIHsKICAgIGNvbnN0IHdyYXAgPSBjZmdUaXBXcmFwRWwgfHwgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2NmZy10aXAtd3JhcCcp
;OwogICAgaWYgKCFjZmdUaXBFbCB8fCAhd3JhcCkgcmV0dXJuOwogICAgZW5kQ2ZnVGlwRWRpdChmYWxzZSk7CiAgICBjb25zdCBkID0gY2ZnRG9jKCk7CiAg
;ICBjb25zdCB0aXAgPSBkID8gU3RyaW5nKGQudGlwIHx8ICcnKSA6ICcnOwogICAgY29uc3Qgc2hvdyA9IFN0cmluZyh0aXApLnRyaW0oKTsKICAgIGlmICgh
;c2hvdykgewogICAgICBjZmdUaXBFbC50ZXh0Q29udGVudCA9ICcnOwogICAgICBpZiAoY2ZnVGlwRWRpdEVsKSBjZmdUaXBFZGl0RWwudmFsdWUgPSAnJzsK
;ICAgICAgd3JhcC5jbGFzc0xpc3QuYWRkKCdoaWRkZW4nKTsKICAgICAgcmV0dXJuOwogICAgfQogICAgY2ZnVGlwRWwudGV4dENvbnRlbnQgPSB0aXAucmVw
;bGFjZSgvXlxuK3xcbiskL2csICcnKTsKICAgIGlmIChjZmdUaXBFZGl0RWwpIGNmZ1RpcEVkaXRFbC52YWx1ZSA9IGNmZ1RpcEVsLnRleHRDb250ZW50Owog
;ICAgd3JhcC5jbGFzc0xpc3QucmVtb3ZlKCdoaWRkZW4nKTsKICB9CiAgZnVuY3Rpb24gYmVnaW5DZmdUaXBFZGl0KCkgewogICAgY29uc3Qgd3JhcCA9IGNm
;Z1RpcFdyYXBFbCB8fCBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnY2ZnLXRpcC13cmFwJyk7CiAgICBjb25zdCBkID0gY2ZnRG9jKCk7CiAgICBpZiAoIXdy
;YXAgfHwgIWNmZ1RpcEVkaXRFbCB8fCAhZCkgcmV0dXJuOwogICAgY2ZnVGlwRWRpdEVsLnZhbHVlID0gU3RyaW5nKGQudGlwIHx8IGNmZ1RpcEVsLnRleHRD
;b250ZW50IHx8ICcnKTsKICAgIHdyYXAuY2xhc3NMaXN0LmFkZCgnZWRpdGluZycpOwogICAgdHJ5IHsKICAgICAgY2ZnVGlwRWRpdEVsLmZvY3VzKCk7CiAg
;ICAgIGNvbnN0IG4gPSBjZmdUaXBFZGl0RWwudmFsdWUubGVuZ3RoOwogICAgICBjZmdUaXBFZGl0RWwuc2V0U2VsZWN0aW9uUmFuZ2Uobiwgbik7CiAgICB9
;IGNhdGNoIChfKSB7fQogIH0KICBmdW5jdGlvbiBlbmRDZmdUaXBFZGl0KGNvbW1pdCkgewogICAgY29uc3Qgd3JhcCA9IGNmZ1RpcFdyYXBFbCB8fCBkb2N1
;bWVudC5nZXRFbGVtZW50QnlJZCgnY2ZnLXRpcC13cmFwJyk7CiAgICBpZiAoIXdyYXAgfHwgIXdyYXAuY2xhc3NMaXN0LmNvbnRhaW5zKCdlZGl0aW5nJykp
;IHJldHVybjsKICAgIGlmIChjb21taXQgJiYgY2ZnVGlwRWRpdEVsKSB7CiAgICAgIGNvbnN0IGQgPSBjZmdEb2MoKTsKICAgICAgaWYgKGQpIHsKICAgICAg
;ICBjb25zdCBuZXh0ID0gU3RyaW5nKGNmZ1RpcEVkaXRFbC52YWx1ZSB8fCAnJyk7CiAgICAgICAgaWYgKFN0cmluZyhkLnRpcCB8fCAnJykgIT09IG5leHQp
;IHsKICAgICAgICAgIGQudGlwID0gbmV4dDsKICAgICAgICAgIG1hcmtDZmdEaXJ0eSgpOwogICAgICAgIH0KICAgICAgICBjZmdUaXBFbC50ZXh0Q29udGVu
;dCA9IG5leHQucmVwbGFjZSgvXlxuK3xcbiskL2csICcnKTsKICAgICAgICBpZiAoIVN0cmluZyhuZXh0KS50cmltKCkpIHdyYXAuY2xhc3NMaXN0LmFkZCgn
;aGlkZGVuJyk7CiAgICAgICAgZWxzZSB3cmFwLmNsYXNzTGlzdC5yZW1vdmUoJ2hpZGRlbicpOwogICAgICB9CiAgICB9CiAgICB3cmFwLmNsYXNzTGlzdC5y
;ZW1vdmUoJ2VkaXRpbmcnKTsKICB9CiAgZnVuY3Rpb24gaXNDb25maWdTZXBMaW5lKHQpIHsgcmV0dXJuIC9eI3s4LH1ccyokLy50ZXN0KHQpOyB9CiAgZnVu
;Y3Rpb24gY291bnRMZWFkaW5nSGFzaCh0KSB7CiAgICBjb25zdCBtID0gU3RyaW5nKHQgfHwgJycpLm1hdGNoKC9eKCMrKS8pOwogICAgcmV0dXJuIG0gPyBt
;WzFdLmxlbmd0aCA6IDA7CiAgfQogIGZ1bmN0aW9uIGlzQ29uZmlnR3JvdXBMaW5lKHQpIHsKICAgIGlmICghdCB8fCB0LmluZGV4T2YoJz0nKSA+PSAwKSBy
;ZXR1cm4gZmFsc2U7CiAgICByZXR1cm4gL14jezMsfS4q44CQW17jgJFdK+OAkS8udGVzdCh0KTsKICB9CiAgZnVuY3Rpb24gcGFyc2VDb25maWdHcm91cFRp
;dGxlKHQpIHsKICAgIGNvbnN0IHJhdyA9IHQucmVwbGFjZSgvXiMrXHMqLywgJycpLnRyaW0oKTsKICAgIGNvbnN0IG0gPSByYXcubWF0Y2goL+OAkChbXuOA
;kV0rKeOAkS8pOwogICAgcmV0dXJuIG0gPyBtWzFdLnRyaW0oKSA6IHJhdzsKICB9CiAgZnVuY3Rpb24gc3RyaXBEZXByZWNhdGVkTWFyayh2YWwpIHsKICAg
;IGNvbnN0IHMgPSBTdHJpbmcodmFsID8/ICcnKTsKICAgIGNvbnN0IG0gPSBzLm1hdGNoKC9eKC4qPylccysj5byD55SoXHMqJC8pOwogICAgcmV0dXJuIG0g
;PyBtWzFdIDogczsKICB9CiAgZnVuY3Rpb24gcGFyc2VEaXNhYmxlZEt2KHQpIHsKICAgIGNvbnN0IG0gPSB0Lm1hdGNoKC9eI1xzKihbXj1dKz8pXHMqPVxz
;KiguKikkLyk7CiAgICBpZiAoIW0pIHJldHVybiBudWxsOwogICAgY29uc3Qga2V5ID0gbVsxXS50cmltKCk7CiAgICBpZiAoIWtleSkgcmV0dXJuIG51bGw7
;CiAgICByZXR1cm4geyBrZXksIHZhbHVlOiBzdHJpcERlcHJlY2F0ZWRNYXJrKG1bMl0pLnRyaW1FbmQoKSwgZW5hYmxlZDogZmFsc2UsIGNvbW1lbnQ6ICcn
;IH07CiAgfQogIGZ1bmN0aW9uIHBhcnNlS3YodCkgewogICAgY29uc3QgbSA9IHQubWF0Y2goL14oW149I11bXj1dKj8pXHMqPVxzKiguKikkLyk7CiAgICBp
;ZiAoIW0pIHJldHVybiBudWxsOwogICAgY29uc3Qga2V5ID0gbVsxXS50cmltKCk7CiAgICBpZiAoIWtleSkgcmV0dXJuIG51bGw7CiAgICByZXR1cm4geyBr
;ZXksIHZhbHVlOiBzdHJpcERlcHJlY2F0ZWRNYXJrKG1bMl0pLnRyaW1FbmQoKSwgZW5hYmxlZDogdHJ1ZSwgY29tbWVudDogJycgfTsKICB9CiAgZnVuY3Rp
;b24gbm9ybWFsaXplSXRlbShpdCkgewogICAgaWYgKCFpdCkgcmV0dXJuIGl0OwogICAgaWYgKHR5cGVvZiBpdC5lbmFibGVkICE9PSAnYm9vbGVhbicpIGl0
;LmVuYWJsZWQgPSAhaXQuZGlzYWJsZWQ7CiAgICBkZWxldGUgaXQuZGlzYWJsZWQ7CiAgICByZXR1cm4gaXQ7CiAgfQogIGZ1bmN0aW9uIGVtcHR5Q2ZnRG9j
;KCkgewogICAgcmV0dXJuIHsKICAgICAgdGlwOiAnJywKICAgICAgdGlwU2VwOiBDRkdfVElQX1NFUF9ERUZBVUxULAogICAgICB0aXBIYXNoOiBDRkdfVElQ
;X0hBU0hfREVGQVVMVCwKICAgICAgZ3JvdXBzOiBbXQogICAgfTsKICB9CiAgZnVuY3Rpb24gcGFyc2VBaGtDb25maWdUZXh0KHRleHQpIHsKICAgIGNvbnN0
;IGRvYyA9IGVtcHR5Q2ZnRG9jKCk7CiAgICBjb25zdCBncm91cHMgPSBbeyB0aXRsZTogJ+m7mOiupCcsIGl0ZW1zOiBbXSB9XTsKICAgIGxldCBnaSA9IDA7
;CiAgICBsZXQgcGVuZGluZ0NvbW1lbnQgPSAnJzsKICAgIGNvbnN0IGxpbmVzID0gU3RyaW5nKHRleHQgfHwgJycpLnJlcGxhY2UoL15cdUZFRkYvLCAnJyku
;c3BsaXQoL1xyP1xuLyk7CiAgICBsZXQgaSA9IDA7CiAgICAvLyDot7Pov4flvIDlpLTnqbrooYwKICAgIHdoaWxlIChpIDwgbGluZXMubGVuZ3RoICYmICFT
;dHJpbmcobGluZXNbaV0gfHwgJycpLnRyaW0oKSkgaSsrOwogICAgLy8g5paH5Lu25aS05rOo6YeK5Z2X77yaIyMjIyMjIyPigKYgLyAjIyPor7TmmI7igKYg
;LyAjIyMjIyMjI+KApgogICAgaWYgKGkgPCBsaW5lcy5sZW5ndGggJiYgaXNDb25maWdTZXBMaW5lKFN0cmluZyhsaW5lc1tpXSB8fCAnJykudHJpbSgpKSkg
;ewogICAgICBkb2MudGlwU2VwID0gY291bnRMZWFkaW5nSGFzaChTdHJpbmcobGluZXNbaV0gfHwgJycpLnRyaW0oKSkgfHwgQ0ZHX1RJUF9TRVBfREVGQVVM
;VDsKICAgICAgaSsrOwogICAgICBjb25zdCB0aXBQYXJ0cyA9IFtdOwogICAgICBsZXQgdGlwSGFzaCA9IDA7CiAgICAgIHdoaWxlIChpIDwgbGluZXMubGVu
;Z3RoKSB7CiAgICAgICAgY29uc3QgcmF3ID0gU3RyaW5nKGxpbmVzW2ldIHx8ICcnKTsKICAgICAgICBjb25zdCB0ID0gcmF3LnRyaW0oKTsKICAgICAgICBp
;ZiAoaXNDb25maWdTZXBMaW5lKHQpKSB7IGkrKzsgYnJlYWs7IH0KICAgICAgICAvLyDliIbnu4TlpLTnu5PmnZ/or7TmmI7lnZfvvJvkuI3opoHnlKggcGFy
;c2VEaXNhYmxlZEt277yIIyMjeD15IOivtOaYjuihjOS8muiiq+ivr+WIpO+8iQogICAgICAgIGlmIChpc0NvbmZpZ0dyb3VwTGluZSh0KSkgYnJlYWs7CiAg
;ICAgICAgaWYgKHQuY2hhckF0KDApID09PSAnIycpIHsKICAgICAgICAgIGNvbnN0IG4gPSBjb3VudExlYWRpbmdIYXNoKHQpOwogICAgICAgICAgaWYgKCF0
;aXBIYXNoICYmIG4gPiAwKSB0aXBIYXNoID0gbjsKICAgICAgICAgIHRpcFBhcnRzLnB1c2godC5yZXBsYWNlKC9eIysvLCAnJykpOwogICAgICAgICAgaSsr
;OwogICAgICAgICAgY29udGludWU7CiAgICAgICAgfQogICAgICAgIC8vIOivtOaYjuWdl+acqumXreWQiOWwseWHuueOsOijuCBrZXk9dmFsdWXvvIznu5Pm
;nZ/or7TmmI4KICAgICAgICBpZiAocGFyc2VLdih0KSkgYnJlYWs7CiAgICAgICAgaWYgKHQpIHRpcFBhcnRzLnB1c2godCk7CiAgICAgICAgZWxzZSB0aXBQ
;YXJ0cy5wdXNoKCcnKTsKICAgICAgICBpKys7CiAgICAgIH0KICAgICAgZG9jLnRpcEhhc2ggPSB0aXBIYXNoIHx8IENGR19USVBfSEFTSF9ERUZBVUxUOwog
;ICAgICB3aGlsZSAodGlwUGFydHMubGVuZ3RoICYmICFTdHJpbmcodGlwUGFydHNbMF0pLnRyaW0oKSkgdGlwUGFydHMuc2hpZnQoKTsKICAgICAgd2hpbGUg
;KHRpcFBhcnRzLmxlbmd0aCAmJiAhU3RyaW5nKHRpcFBhcnRzW3RpcFBhcnRzLmxlbmd0aCAtIDFdKS50cmltKCkpIHRpcFBhcnRzLnBvcCgpOwogICAgICBk
;b2MudGlwID0gdGlwUGFydHMuam9pbignXG4nKTsKICAgIH0KICAgIGZvciAoOyBpIDwgbGluZXMubGVuZ3RoOyBpKyspIHsKICAgICAgY29uc3QgdCA9IFN0
;cmluZyhsaW5lc1tpXSB8fCAnJykudHJpbSgpOwogICAgICBpZiAoIXQpIHsgcGVuZGluZ0NvbW1lbnQgPSAnJzsgY29udGludWU7IH0KICAgICAgaWYgKGlz
;Q29uZmlnU2VwTGluZSh0KSkgeyBwZW5kaW5nQ29tbWVudCA9ICcnOyBjb250aW51ZTsgfQogICAgICBpZiAoaXNDb25maWdHcm91cExpbmUodCkpIHsKICAg
;ICAgICBncm91cHMucHVzaCh7IHRpdGxlOiBwYXJzZUNvbmZpZ0dyb3VwVGl0bGUodCkgfHwgJ+acquWRveWQjee7hCcsIGl0ZW1zOiBbXSB9KTsKICAgICAg
;ICBnaSA9IGdyb3Vwcy5sZW5ndGggLSAxOwogICAgICAgIHBlbmRpbmdDb21tZW50ID0gJyc7CiAgICAgICAgY29udGludWU7CiAgICAgIH0KICAgICAgY29u
;c3QgZGlzYWJsZWRLdiA9IHBhcnNlRGlzYWJsZWRLdih0KTsKICAgICAgaWYgKGRpc2FibGVkS3YpIHsKICAgICAgICBkaXNhYmxlZEt2LmNvbW1lbnQgPSBw
;ZW5kaW5nQ29tbWVudDsKICAgICAgICBncm91cHNbZ2ldLml0ZW1zLnB1c2goZGlzYWJsZWRLdik7CiAgICAgICAgcGVuZGluZ0NvbW1lbnQgPSAnJzsKICAg
;ICAgICBjb250aW51ZTsKICAgICAgfQogICAgICBpZiAodC5jaGFyQXQoMCkgPT09ICcjJykgewogICAgICAgIGlmICgvXiN7Mix9Ly50ZXN0KHQpKSB7IHBl
;bmRpbmdDb21tZW50ID0gJyc7IGNvbnRpbnVlOyB9CiAgICAgICAgcGVuZGluZ0NvbW1lbnQgPSB0LnJlcGxhY2UoL14jXHMqLywgJycpLnRyaW0oKTsKICAg
;ICAgICBjb250aW51ZTsKICAgICAgfQogICAgICBjb25zdCBrdiA9IHBhcnNlS3YodCk7CiAgICAgIGlmICgha3YpIHsgcGVuZGluZ0NvbW1lbnQgPSAnJzsg
;Y29udGludWU7IH0KICAgICAga3YuY29tbWVudCA9IHBlbmRpbmdDb21tZW50OwogICAgICBncm91cHNbZ2ldLml0ZW1zLnB1c2goa3YpOwogICAgICBwZW5k
;aW5nQ29tbWVudCA9ICcnOwogICAgfQogICAgaWYgKGdyb3Vwcy5sZW5ndGggPiAxICYmIGdyb3Vwc1swXS50aXRsZSA9PT0gJ+m7mOiupCcgJiYgIWdyb3Vw
;c1swXS5pdGVtcy5sZW5ndGgpIGdyb3Vwcy5zaGlmdCgpOwogICAgZ3JvdXBzLmZvckVhY2goZyA9PiAoZy5pdGVtcyB8fCBbXSkuZm9yRWFjaChub3JtYWxp
;emVJdGVtKSk7CiAgICBkb2MuZ3JvdXBzID0gZ3JvdXBzOwogICAgcmV0dXJuIGRvYzsKICB9CiAgZnVuY3Rpb24gc2VyaWFsaXplQWhrQ29uZmlnKGRvYykg
;ewogICAgY29uc3Qgb3V0ID0gW107CiAgICBjb25zdCB0aXBTZXAgPSBNYXRoLm1heCg4LCBOdW1iZXIoZG9jICYmIGRvYy50aXBTZXApIHx8IENGR19USVBf
;U0VQX0RFRkFVTFQpOwogICAgY29uc3QgdGlwSGFzaCA9IE1hdGgubWF4KDEsIE51bWJlcihkb2MgJiYgZG9jLnRpcEhhc2gpIHx8IENGR19USVBfSEFTSF9E
;RUZBVUxUKTsKICAgIGNvbnN0IHNlcCA9ICcjJy5yZXBlYXQodGlwU2VwKTsKICAgIGNvbnN0IHByZWZpeCA9ICcjJy5yZXBlYXQodGlwSGFzaCk7CiAgICBj
;b25zdCB0aXBUZXh0ID0gU3RyaW5nKGRvYyAmJiBkb2MudGlwICE9IG51bGwgPyBkb2MudGlwIDogJycpOwogICAgY29uc3QgdGlwTGluZXMgPSB0aXBUZXh0
;LnJlcGxhY2UoL1xyXG4vZywgJ1xuJykucmVwbGFjZSgvXHIvZywgJ1xuJykuc3BsaXQoJ1xuJyk7CiAgICBvdXQucHVzaChzZXApOwogICAgaWYgKHRpcExp
;bmVzLmxlbmd0aCA9PT0gMSAmJiAhU3RyaW5nKHRpcExpbmVzWzBdKS50cmltKCkpIHsKICAgICAgb3V0LnB1c2gocHJlZml4ICsgJ+mFjee9ruWPguaVsOS4
;umtleT12YWx1ZeW9ouW8jycpOwogICAgfSBlbHNlIHsKICAgICAgdGlwTGluZXMuZm9yRWFjaChsaW5lID0+IHsKICAgICAgICBvdXQucHVzaChwcmVmaXgg
;KyBTdHJpbmcobGluZSA/PyAnJykpOwogICAgICB9KTsKICAgIH0KICAgIG91dC5wdXNoKHNlcCk7CiAgICBvdXQucHVzaCgnJyk7CiAgICBjb25zdCBncm91
;cHMgPSAoZG9jICYmIGRvYy5ncm91cHMpIHx8IFtdOwogICAgZ3JvdXBzLmZvckVhY2goKGcsIGlkeCkgPT4gewogICAgICBjb25zdCB0aXRsZSA9IFN0cmlu
;ZyhnLnRpdGxlIHx8ICcnKS50cmltKCkgfHwgJ+acquWRveWQjee7hCc7CiAgICAgIGNvbnN0IGl0ZW1zID0gQXJyYXkuaXNBcnJheShnLml0ZW1zKSA/IGcu
;aXRlbXMgOiBbXTsKICAgICAgaWYgKCEoaWR4ID09PSAwICYmIHRpdGxlID09PSAn6buY6K6kJykpIHsKICAgICAgICBvdXQucHVzaCgnJyk7CiAgICAgICAg
;b3V0LnB1c2goJyMjIyMjIyMjIyMjI+OAkCcgKyB0aXRsZSArICfjgJEnKTsKICAgICAgfQogICAgICBpdGVtcy5mb3JFYWNoKGl0ID0+IHsKICAgICAgICBu
;b3JtYWxpemVJdGVtKGl0KTsKICAgICAgICBjb25zdCBrZXkgPSBTdHJpbmcoaXQua2V5IHx8ICcnKS50cmltKCk7CiAgICAgICAgaWYgKCFrZXkpIHJldHVy
;bjsKICAgICAgICBjb25zdCB2YWwgPSBTdHJpbmcoaXQudmFsdWUgPz8gJycpOwogICAgICAgIGNvbnN0IGNvbW1lbnQgPSBTdHJpbmcoaXQuY29tbWVudCB8
;fCAnJykudHJpbSgpOwogICAgICAgIGlmIChjb21tZW50KSBvdXQucHVzaCgnIycgKyBjb21tZW50KTsKICAgICAgICBpZiAoaXQuZW5hYmxlZCA9PT0gZmFs
;c2UpIG91dC5wdXNoKCcjJyArIGtleSArICc9JyArIHZhbCArICcgICAj5byD55SoJyk7CiAgICAgICAgZWxzZSBvdXQucHVzaChrZXkgKyAnPScgKyB2YWwp
;OwogICAgICB9KTsKICAgIH0pOwogICAgb3V0LnB1c2goJycpOwogICAgcmV0dXJuIG91dC5qb2luKCdcclxuJyk7CiAgfQogIGZ1bmN0aW9uIGNmZ0RvYygp
;IHsgcmV0dXJuIGNmZ0NhY2hlW2NmZ0FjdGl2ZVRhYl07IH0KICBmdW5jdGlvbiBjZmdDdXJyZW50KCkgewogICAgY29uc3QgZCA9IGNmZ0RvYygpOwogICAg
;cmV0dXJuIGQgJiYgZC5ncm91cHM7CiAgfQogIGZ1bmN0aW9uIG1hcmtDZmdEaXJ0eSgpIHsKICAgIGNmZ0RpcnR5W2NmZ0FjdGl2ZVRhYl0gPSB0cnVlOwog
;IH0KICBmdW5jdGlvbiBzeW5jQ2ZnU2VhcmNoQ2hyb21lKCkgewogICAgZG9jdW1lbnQucXVlcnlTZWxlY3RvckFsbCgnLmNmZy1zdGFnW2RhdGEtY2ZnLXNj
;b3BlXScpLmZvckVhY2goYnRuID0+IHsKICAgICAgY29uc3QgcyA9IGJ0bi5nZXRBdHRyaWJ1dGUoJ2RhdGEtY2ZnLXNjb3BlJyk7CiAgICAgIGJ0bi5jbGFz
;c0xpc3QudG9nZ2xlKCdvbicsICEhY2ZnU2VhcmNoU2NvcGVbc10pOwogICAgfSk7CiAgICBpZiAoY2ZnU2VhcmNoQ2xlYXJFbCkgewogICAgICBjb25zdCBz
;aG93ID0gYXBwTW9kZSA9PT0gJ2NvbmZpZycgJiYgISEoCiAgICAgICAgY2ZnU2VhcmNoIHx8IGNmZ1NlYXJjaFNjb3BlLmtleSB8fCBjZmdTZWFyY2hTY29w
;ZS52YWx1ZQogICAgICAgIHx8IGNmZ1NlYXJjaFNjb3BlLmVuYWJsZWQgfHwgY2ZnU2VhcmNoU2NvcGUuZGlzYWJsZWQKICAgICAgICB8fCBTdHJpbmcocUVs
;ICYmIHFFbC52YWx1ZSB8fCAnJykudHJpbSgpCiAgICAgICk7CiAgICAgIGNmZ1NlYXJjaENsZWFyRWwuY2xhc3NMaXN0LnRvZ2dsZSgnb24nLCBzaG93KTsK
;ICAgICAgaWYgKCFjZmdTZWFyY2ggJiYgY2ZnU2VhcmNoSGl0RWwpIGNmZ1NlYXJjaEhpdEVsLnRleHRDb250ZW50ID0gJyc7CiAgICB9CiAgfQogIGZ1bmN0
;aW9uIHVwZGF0ZUNmZ1NlYXJjaEhpdChuKSB7CiAgICBpZiAoIWNmZ1NlYXJjaEhpdEVsKSByZXR1cm47CiAgICBjb25zdCBmaWx0ZXJpbmcgPSBjZmdIYXNB
;Y3RpdmVGaWx0ZXIoKTsKICAgIGlmIChhcHBNb2RlICE9PSAnY29uZmlnJyB8fCAhZmlsdGVyaW5nKSB7CiAgICAgIGNmZ1NlYXJjaEhpdEVsLnRleHRDb250
;ZW50ID0gJyc7CiAgICAgIHN5bmNDZmdTZWFyY2hDaHJvbWUoKTsKICAgICAgcmV0dXJuOwogICAgfQogICAgY2ZnU2VhcmNoSGl0RWwudGV4dENvbnRlbnQg
;PSBTdHJpbmcobikgKyAnIOadoSc7CiAgICBzeW5jQ2ZnU2VhcmNoQ2hyb21lKCk7CiAgfQogIGZ1bmN0aW9uIGNsZWFyQ2ZnU2VhcmNoKCkgewogICAgY2Zn
;U2VhcmNoU2NvcGUgPSB7IGtleTogZmFsc2UsIHZhbHVlOiBmYWxzZSwgZW5hYmxlZDogZmFsc2UsIGRpc2FibGVkOiBmYWxzZSB9OwogICAgbW9kZVF1ZXJ5
;LmNvbmZpZyA9ICcnOwogICAgaWYgKHFFbCkgcUVsLnZhbHVlID0gJyc7CiAgICBhcHBseUNvbmZpZ1NlYXJjaCgnJyk7CiAgICBpZiAodHlwZW9mIHN5bmND
;bGVhckJ0biA9PT0gJ2Z1bmN0aW9uJykgc3luY0NsZWFyQnRuKCk7CiAgICBpZiAodHlwZW9mIHNhdmVTZXNzaW9uU29vbiA9PT0gJ2Z1bmN0aW9uJykgc2F2
;ZVNlc3Npb25Tb29uKCk7CiAgfQogIGZ1bmN0aW9uIGFwcGx5Q29uZmlnU2VhcmNoKHEpIHsKICAgIGNvbnN0IHJhdyA9IHEgPT0gbnVsbCA/IFN0cmluZyhx
;RWwgJiYgcUVsLnZhbHVlIHx8ICcnKSA6IFN0cmluZyhxIHx8ICcnKTsKICAgIGNmZ1NlYXJjaCA9IHJhdy50cmltKCkudG9Mb3dlckNhc2UoKTsKICAgIG1v
;ZGVRdWVyeS5jb25maWcgPSByYXc7CiAgICBpZiAocUVsICYmIHFFbC52YWx1ZSAhPT0gcmF3KSBxRWwudmFsdWUgPSByYXc7CiAgICBzeW5jQ2ZnU2VhcmNo
;Q2hyb21lKCk7CiAgICBpZiAodHlwZW9mIHN5bmNDbGVhckJ0biA9PT0gJ2Z1bmN0aW9uJykgc3luY0NsZWFyQnRuKCk7CiAgICByZW5kZXJDb25maWdFZGl0
;b3IoKTsKICB9CiAgZnVuY3Rpb24gbW92ZUluQXJyYXkoYXJyLCBpLCBkaXIpIHsKICAgIGNvbnN0IGogPSBpICsgZGlyOwogICAgaWYgKCFhcnIgfHwgaiA8
;IDAgfHwgaiA+PSBhcnIubGVuZ3RoKSByZXR1cm4gZmFsc2U7CiAgICBjb25zdCB0ID0gYXJyW2ldOyBhcnJbaV0gPSBhcnJbal07IGFycltqXSA9IHQ7CiAg
;ICByZXR1cm4gdHJ1ZTsKICB9CiAgZnVuY3Rpb24gbW92ZVRvVG9wKGFyciwgaSkgewogICAgaWYgKCFhcnIgfHwgaSA8PSAwIHx8IGkgPj0gYXJyLmxlbmd0
;aCkgcmV0dXJuIGZhbHNlOwogICAgY29uc3QgdCA9IGFyci5zcGxpY2UoaSwgMSlbMF07CiAgICBhcnIudW5zaGlmdCh0KTsKICAgIHJldHVybiB0cnVlOwog
;IH0KICBmdW5jdGlvbiBjbGFzc2lmeUNmZ1ZhbHVlKHZhbCkgewogICAgY29uc3QgdiA9IFN0cmluZyh2YWwgfHwgJycpLnRyaW0oKTsKICAgIGlmICghdikg
;cmV0dXJuIHsga2luZDogJycsIHBhdGg6ICcnIH07CiAgICBpZiAoL15cKC4qXCkkLy50ZXN0KHYpKSByZXR1cm4geyBraW5kOiAnY21kJywgcGF0aDogJycg
;fTsKICAgIGlmICgvXmh0dHBzPzpcL1wvL2kudGVzdCh2KSB8fCAvXnd3d1wuL2kudGVzdCh2KSkgcmV0dXJuIHsga2luZDogJ3dlYicsIHBhdGg6IHYgfTsK
;ICAgIGNvbnN0IGJhcmUgPSB2LnJlcGxhY2UoL14iK3wiKyQvZywgJycpOwogICAgaWYgKC9eW2EtekEtWl06W1xcXC9dLy50ZXN0KGJhcmUpIHx8IGJhcmUu
;c3RhcnRzV2l0aCgnXFxcXCcpIHx8IC8lW14lXSslLy50ZXN0KGJhcmUpIHx8IGJhcmUuaW5kZXhPZignXFwnKSA+PSAwKSB7CiAgICAgIGNvbnN0IGxhc3Qg
;PSBiYXJlLnNwbGl0KC9bXFxcL10vKS5wb3AoKSB8fCAnJzsKICAgICAgaWYgKC9cLihleGV8bG5rKSQvaS50ZXN0KGxhc3QpKSByZXR1cm4geyBraW5kOiAn
;ZXhlJywgcGF0aDogYmFyZSB9OwogICAgICBpZiAoL1tcXFwvXSQvLnRlc3QoYmFyZSkgfHwgIS9cLlthLXowLTldezEsNn0kL2kudGVzdChsYXN0KSkgcmV0
;dXJuIHsga2luZDogJ2ZvbGRlcicsIHBhdGg6IGJhcmUgfTsKICAgICAgcmV0dXJuIHsga2luZDogJ2ZpbGUnLCBwYXRoOiBiYXJlIH07CiAgICB9CiAgICBy
;ZXR1cm4geyBraW5kOiAnJywgcGF0aDogJycgfTsKICB9CiAgZnVuY3Rpb24gc2V0Q2ZnVmljbyhlbCwga2luZCwgdXJsKSB7CiAgICBpZiAoIWVsKSByZXR1
;cm47CiAgICBpZiAodXJsKSB7CiAgICAgIGVsLmlubmVySFRNTCA9ICcnOwogICAgICBjb25zdCBpbWcgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdpbWcn
;KTsKICAgICAgaW1nLmFsdCA9ICcnOwogICAgICBpbWcuc3JjID0gdXJsOwogICAgICBpbWcub25lcnJvciA9ICgpID0+IHsgZWwuaW5uZXJIVE1MID0gQ0ZH
;X1NWR1traW5kXSB8fCBDRkdfU1ZHLmZpbGUgfHwgJyc7IH07CiAgICAgIGVsLmFwcGVuZENoaWxkKGltZyk7CiAgICAgIHJldHVybjsKICAgIH0KICAgIGVs
;LmlubmVySFRNTCA9IENGR19TVkdba2luZF0gfHwgJyc7CiAgfQogIGZ1bmN0aW9uIHJlcXVlc3RDZmdJY29uKGVsLCBraW5kLCBwYXRoKSB7CiAgICBpZiAo
;IWVsIHx8ICFraW5kKSByZXR1cm47CiAgICBpZiAoa2luZCA9PT0gJ3dlYicgfHwga2luZCA9PT0gJ2ZpbGUnKSB7CiAgICAgIHNldENmZ1ZpY28oZWwsIGtp
;bmQsICcnKTsKICAgICAgcmV0dXJuOwogICAgfQogICAgY29uc3QgY2FjaGVLZXkgPSBraW5kICsgJ3wnICsgU3RyaW5nKHBhdGggfHwgJycpOwogICAgaWYg
;KGNmZ0ljb25DYWNoZS5oYXMoY2FjaGVLZXkpKSB7CiAgICAgIGNvbnN0IHUgPSBjZmdJY29uQ2FjaGUuZ2V0KGNhY2hlS2V5KTsKICAgICAgc2V0Q2ZnVmlj
;byhlbCwga2luZCwgdSB8fCAnJyk7CiAgICAgIHJldHVybjsKICAgIH0KICAgIHNldENmZ1ZpY28oZWwsIGtpbmQgPT09ICdleGUnID8gJ2ZpbGUnIDoga2lu
;ZCwgJycpOwogICAgY29uc3QgcmVxSWQgPSAnYycgKyAoKytjZmdJY29uU2VxKTsKICAgIGVsLmRhdGFzZXQuaWNvblJlcSA9IHJlcUlkOwogICAgc2V0VGlt
;ZW91dCgoKSA9PiB7CiAgICAgIHRyeSB7IHBvc3QoJ2NmZ0ljb258JyArIHJlcUlkICsgJ3wnICsga2luZCArICd8JyArIHRleHRUb0I2NChwYXRoIHx8ICcn
;KSk7IH0gY2F0Y2ggKF8pIHt9CiAgICB9LCAwKTsKICB9CiAgZnVuY3Rpb24gaGlkZUNmZ01lbnUoKSB7CiAgICBpZiAoY2ZnTWVudSkgY2ZnTWVudS5jbGFz
;c0xpc3QucmVtb3ZlKCdvbicpOwogICAgY2ZnTWVudUN0eCA9IG51bGw7CiAgfQogIGZ1bmN0aW9uIHNob3dDZmdNZW51KHgsIHksIGN0eCkgewogICAgaWYg
;KCFjZmdNZW51KSByZXR1cm47CiAgICBjZmdNZW51Q3R4ID0gY3R4OwogICAgY29uc3QgaXNHcm91cCA9IGN0eCAmJiBjdHgudHlwZSA9PT0gJ2dyb3VwJzsK
;ICAgIGNmZ01lbnUucXVlcnlTZWxlY3RvckFsbCgnYnV0dG9uW2RhdGEtY2FjdF0nKS5mb3JFYWNoKGJ0biA9PiB7CiAgICAgIGNvbnN0IGEgPSBidG4uZ2V0
;QXR0cmlidXRlKCdkYXRhLWNhY3QnKTsKICAgICAgY29uc3QgbGFiID0gYnRuLnF1ZXJ5U2VsZWN0b3IoJy5jYWN0LWxhYmVsJykgfHwgYnRuOwogICAgICBp
;ZiAoYSA9PT0gJ2FkZCcpIGxhYi50ZXh0Q29udGVudCA9ICfmt7vliqDmnaHnm64nOwogICAgICBlbHNlIGlmIChhID09PSAndG9wJykgbGFiLnRleHRDb250
;ZW50ID0gaXNHcm91cCA/ICfnu4Tnva7pobYnIDogJ+e9rumhtic7CiAgICAgIGVsc2UgaWYgKGEgPT09ICd1cCcpIGxhYi50ZXh0Q29udGVudCA9IGlzR3Jv
;dXAgPyAn57uE5LiK56e7JyA6ICfkuIrnp7snOwogICAgICBlbHNlIGlmIChhID09PSAnZG93bicpIGxhYi50ZXh0Q29udGVudCA9IGlzR3JvdXAgPyAn57uE
;5LiL56e7JyA6ICfkuIvnp7snOwogICAgICBlbHNlIGlmIChhID09PSAnZGVsJykgbGFiLnRleHRDb250ZW50ID0gaXNHcm91cCA/ICfliKDpmaTnu4QnIDog
;J+WIoOmZpOadoeebric7CiAgICB9KTsKICAgIGNmZ01lbnUuY2xhc3NMaXN0LmFkZCgnb24nKTsKICAgIGNvbnN0IHBhZCA9IDY7CiAgICBjb25zdCByZWN0
;ID0gY2ZnTWVudS5nZXRCb3VuZGluZ0NsaWVudFJlY3QoKTsKICAgIGxldCBsZWZ0ID0geCwgdG9wID0geTsKICAgIGlmIChsZWZ0ICsgcmVjdC53aWR0aCA+
;IHdpbmRvdy5pbm5lcldpZHRoIC0gcGFkKSBsZWZ0ID0gTWF0aC5tYXgocGFkLCB3aW5kb3cuaW5uZXJXaWR0aCAtIHJlY3Qud2lkdGggLSBwYWQpOwogICAg
;aWYgKHRvcCArIHJlY3QuaGVpZ2h0ID4gd2luZG93LmlubmVySGVpZ2h0IC0gcGFkKSB0b3AgPSBNYXRoLm1heChwYWQsIHdpbmRvdy5pbm5lckhlaWdodCAt
;IHJlY3QuaGVpZ2h0IC0gcGFkKTsKICAgIGNmZ01lbnUuc3R5bGUubGVmdCA9IGxlZnQgKyAncHgnOwogICAgY2ZnTWVudS5zdHlsZS50b3AgPSB0b3AgKyAn
;cHgnOwogIH0KICBmdW5jdGlvbiBzZWxlY3RDZmdUYXJnZXQoZ2ksIGlpKSB7CiAgICBjZmdTZWwgPSB7IGdpLCBpaSB9OwogICAgaWYgKCFjZmdCb2R5KSBy
;ZXR1cm47CiAgICBjZmdCb2R5LnF1ZXJ5U2VsZWN0b3JBbGwoJy5jZmctY2FyZC5vbicpLmZvckVhY2goZWwgPT4gZWwuY2xhc3NMaXN0LnJlbW92ZSgnb24n
;KSk7CiAgICBjZmdCb2R5LnF1ZXJ5U2VsZWN0b3JBbGwoJy5jZmctaXRlbS5vbicpLmZvckVhY2goZWwgPT4gZWwuY2xhc3NMaXN0LnJlbW92ZSgnb24nKSk7
;CiAgICBjb25zdCBjYXJkID0gY2ZnQm9keS5xdWVyeVNlbGVjdG9yKCcuY2ZnLWNhcmRbZGF0YS1naT0iJyArIGdpICsgJyJdJyk7CiAgICBpZiAoY2FyZCkg
;Y2FyZC5jbGFzc0xpc3QuYWRkKCdvbicpOwogICAgaWYgKGlpID49IDApIHsKICAgICAgY29uc3QgaXRlbSA9IGNmZ0JvZHkucXVlcnlTZWxlY3RvcignLmNm
;Zy1pdGVtW2RhdGEtZ2k9IicgKyBnaSArICciXVtkYXRhLWlpPSInICsgaWkgKyAnIl0nKTsKICAgICAgaWYgKGl0ZW0pIGl0ZW0uY2xhc3NMaXN0LmFkZCgn
;b24nKTsKICAgICAgY29uc3QgZ3JvdXBzID0gY2ZnQ3VycmVudCgpOwogICAgICBjb25zdCBpdCA9IGdyb3VwcyAmJiBncm91cHNbZ2ldICYmIGdyb3Vwc1tn
;aV0uaXRlbXMgJiYgZ3JvdXBzW2dpXS5pdGVtc1tpaV07CiAgICAgIGlmIChpdCkgewogICAgICAgIGNvbnN0IGNscyA9IGNsYXNzaWZ5Q2ZnVmFsdWUoaXQu
;dmFsdWUpOwogICAgICAgIHVwZGF0ZUNmZ1BhdGhCYXIoY2xzLnBhdGggfHwgU3RyaW5nKGl0LnZhbHVlIHx8ICcnKS50cmltKCkgfHwgY2ZnUGF0aHNbY2Zn
;QWN0aXZlVGFiXSk7CiAgICAgIH0KICAgIH0gZWxzZSB7CiAgICAgIHVwZGF0ZUNmZ1BhdGhCYXIoY2ZnUGF0aHNbY2ZnQWN0aXZlVGFiXSk7CiAgICB9CiAg
;fQogIGFzeW5jIGZ1bmN0aW9uIHJ1bkNmZ01lbnVBY3Rpb24oYWN0KSB7CiAgICBjb25zdCBjdHggPSBjZmdNZW51Q3R4OwogICAgaGlkZUNmZ01lbnUoKTsK
;ICAgIGlmICghY3R4IHx8ICFhY3QpIHJldHVybjsKICAgIGNvbnN0IGdyb3VwcyA9IGNmZ0N1cnJlbnQoKTsKICAgIGlmICghZ3JvdXBzKSByZXR1cm47CiAg
;ICBjb25zdCBnaSA9IGN0eC5naTsKICAgIGlmIChnaSA8IDAgfHwgZ2kgPj0gZ3JvdXBzLmxlbmd0aCkgcmV0dXJuOwogICAgY29uc3QgZyA9IGdyb3Vwc1tn
;aV07CiAgICBpZiAoY3R4LnR5cGUgPT09ICdncm91cCcpIHsKICAgICAgaWYgKGFjdCA9PT0gJ2FkZCcpIHsKICAgICAgICBnLml0ZW1zID0gZy5pdGVtcyB8
;fCBbXTsKICAgICAgICBnLml0ZW1zLnB1c2goeyBrZXk6ICcnLCB2YWx1ZTogJycsIGNvbW1lbnQ6ICcnLCBlbmFibGVkOiB0cnVlIH0pOwogICAgICAgIG1h
;cmtDZmdEaXJ0eSgpOwogICAgICAgIHJlbmRlckNvbmZpZ0VkaXRvcigpOwogICAgICAgIHNlbGVjdENmZ1RhcmdldChnaSwgZy5pdGVtcy5sZW5ndGggLSAx
;KTsKICAgICAgICByZXR1cm47CiAgICAgIH0KICAgICAgaWYgKGFjdCA9PT0gJ3RvcCcpIHsgaWYgKG1vdmVUb1RvcChncm91cHMsIGdpKSkgeyBtYXJrQ2Zn
;RGlydHkoKTsgcmVuZGVyQ29uZmlnRWRpdG9yKCk7IHNlbGVjdENmZ1RhcmdldCgwLCAtMSk7IH0gcmV0dXJuOyB9CiAgICAgIGlmIChhY3QgPT09ICd1cCcp
;IHsgaWYgKG1vdmVJbkFycmF5KGdyb3VwcywgZ2ksIC0xKSkgeyBtYXJrQ2ZnRGlydHkoKTsgcmVuZGVyQ29uZmlnRWRpdG9yKCk7IHNlbGVjdENmZ1Rhcmdl
;dChnaSAtIDEsIC0xKTsgfSByZXR1cm47IH0KICAgICAgaWYgKGFjdCA9PT0gJ2Rvd24nKSB7IGlmIChtb3ZlSW5BcnJheShncm91cHMsIGdpLCAxKSkgeyBt
;YXJrQ2ZnRGlydHkoKTsgcmVuZGVyQ29uZmlnRWRpdG9yKCk7IHNlbGVjdENmZ1RhcmdldChnaSArIDEsIC0xKTsgfSByZXR1cm47IH0KICAgICAgaWYgKGFj
;dCA9PT0gJ2RlbCcpIHsKICAgICAgICBjb25zdCBvayA9IGF3YWl0IHVpQ29uZmlybSgn5Yig6Zmk57uE44CMJyArIChnLnRpdGxlIHx8ICcnKSArICfjgI3l
;j4rlhbblhajpg6jmnaHnm67vvJ8nLCB7CiAgICAgICAgICB0aXRsZTogJ+WIoOmZpOWIhue7hCcsIG9rVGV4dDogJ+WIoOmZpCcsIGRhbmdlcjogdHJ1ZQog
;ICAgICAgIH0pOwogICAgICAgIGlmICghb2spIHJldHVybjsKICAgICAgICBncm91cHMuc3BsaWNlKGdpLCAxKTsKICAgICAgICBtYXJrQ2ZnRGlydHkoKTsK
;ICAgICAgICByZW5kZXJDb25maWdFZGl0b3IoKTsKICAgICAgICByZXR1cm47CiAgICAgIH0KICAgICAgcmV0dXJuOwogICAgfQogICAgY29uc3QgaWkgPSBj
;dHguaWk7CiAgICBpZiAoaWkgPCAwIHx8ICFnLml0ZW1zIHx8IGlpID49IGcuaXRlbXMubGVuZ3RoKSByZXR1cm47CiAgICBpZiAoYWN0ID09PSAnYWRkJykg
;ewogICAgICBnLml0ZW1zLnNwbGljZShpaSArIDEsIDAsIHsga2V5OiAnJywgdmFsdWU6ICcnLCBjb21tZW50OiAnJywgZW5hYmxlZDogdHJ1ZSB9KTsKICAg
;ICAgbWFya0NmZ0RpcnR5KCk7CiAgICAgIHJlbmRlckNvbmZpZ0VkaXRvcigpOwogICAgICBzZWxlY3RDZmdUYXJnZXQoZ2ksIGlpICsgMSk7CiAgICAgIHJl
;dHVybjsKICAgIH0KICAgIGlmIChhY3QgPT09ICd0b3AnKSB7IGlmIChtb3ZlVG9Ub3AoZy5pdGVtcywgaWkpKSB7IG1hcmtDZmdEaXJ0eSgpOyByZW5kZXJD
;b25maWdFZGl0b3IoKTsgc2VsZWN0Q2ZnVGFyZ2V0KGdpLCAwKTsgfSByZXR1cm47IH0KICAgIGlmIChhY3QgPT09ICd1cCcpIHsgaWYgKG1vdmVJbkFycmF5
;KGcuaXRlbXMsIGlpLCAtMSkpIHsgbWFya0NmZ0RpcnR5KCk7IHJlbmRlckNvbmZpZ0VkaXRvcigpOyBzZWxlY3RDZmdUYXJnZXQoZ2ksIGlpIC0gMSk7IH0g
;cmV0dXJuOyB9CiAgICBpZiAoYWN0ID09PSAnZG93bicpIHsgaWYgKG1vdmVJbkFycmF5KGcuaXRlbXMsIGlpLCAxKSkgeyBtYXJrQ2ZnRGlydHkoKTsgcmVu
;ZGVyQ29uZmlnRWRpdG9yKCk7IHNlbGVjdENmZ1RhcmdldChnaSwgaWkgKyAxKTsgfSByZXR1cm47IH0KICAgIGlmIChhY3QgPT09ICdkZWwnKSB7CiAgICAg
;IGNvbnN0IGl0ID0gZy5pdGVtc1tpaV07CiAgICAgIGNvbnN0IGxhYmVsID0gU3RyaW5nKChpdCAmJiBpdC5rZXkpIHx8ICcnKS50cmltKCkgfHwgKCfnrKwg
;JyArIChpaSArIDEpICsgJyDmnaEnKTsKICAgICAgY29uc3Qgb2sgPSBhd2FpdCB1aUNvbmZpcm0oJ+ehruWumuWIoOmZpOadoeebruOAjCcgKyBsYWJlbCAr
;ICfjgI3vvJ8nLCB7CiAgICAgICAgdGl0bGU6ICfliKDpmaTmnaHnm64nLCBva1RleHQ6ICfliKDpmaQnLCBkYW5nZXI6IHRydWUKICAgICAgfSk7CiAgICAg
;IGlmICghb2spIHJldHVybjsKICAgICAgZy5pdGVtcy5zcGxpY2UoaWksIDEpOwogICAgICBtYXJrQ2ZnRGlydHkoKTsKICAgICAgcmVuZGVyQ29uZmlnRWRp
;dG9yKCk7CiAgICB9CiAgfQogIGZ1bmN0aW9uIGdldENmZ09wZW5TdGF0ZSgpIHsKICAgIGlmICghY2ZnT3Blbk1hcFtjZmdBY3RpdmVUYWJdKSBjZmdPcGVu
;TWFwW2NmZ0FjdGl2ZVRhYl0gPSBPYmplY3QuY3JlYXRlKG51bGwpOwogICAgcmV0dXJuIGNmZ09wZW5NYXBbY2ZnQWN0aXZlVGFiXTsKICB9CiAgZnVuY3Rp
;b24gaXNDZmdHcm91cE9wZW4oZ2ksIGZvcmNlT3BlbikgewogICAgaWYgKGZvcmNlT3BlbikgcmV0dXJuIHRydWU7CiAgICByZXR1cm4gISFnZXRDZmdPcGVu
;U3RhdGUoKVtnaV07CiAgfQogIGZ1bmN0aW9uIHRvZ2dsZUNmZ0dyb3VwKGdpKSB7CiAgICBjb25zdCBvcGVuID0gZ2V0Q2ZnT3BlblN0YXRlKCk7CiAgICBv
;cGVuW2dpXSA9ICFvcGVuW2dpXTsKICAgIHJlbmRlckNvbmZpZ0VkaXRvcigpOwogICAgc2VsZWN0Q2ZnVGFyZ2V0KGdpLCAtMSk7CiAgfQogIGZ1bmN0aW9u
;IHNldEFsbENmZ09wZW4ob24pIHsKICAgIGNvbnN0IGdyb3VwcyA9IGNmZ0N1cnJlbnQoKTsKICAgIGNvbnN0IG9wZW4gPSBnZXRDZmdPcGVuU3RhdGUoKTsK
;ICAgIChncm91cHMgfHwgW10pLmZvckVhY2goKF8sIGdpKSA9PiB7IG9wZW5bZ2ldID0gISFvbjsgfSk7CiAgICByZW5kZXJDb25maWdFZGl0b3IoKTsKICB9
;CiAgZnVuY3Rpb24gYW55Q2ZnR3JvdXBPcGVuKCkgewogICAgY29uc3QgZ3JvdXBzID0gY2ZnQ3VycmVudCgpIHx8IFtdOwogICAgY29uc3Qgb3BlbiA9IGdl
;dENmZ09wZW5TdGF0ZSgpOwogICAgZm9yIChsZXQgaSA9IDA7IGkgPCBncm91cHMubGVuZ3RoOyBpKyspIHsKICAgICAgaWYgKG9wZW5baV0pIHJldHVybiB0
;cnVlOwogICAgfQogICAgcmV0dXJuIGZhbHNlOwogIH0KICBmdW5jdGlvbiBzeW5jQ2ZnVG9nZ2xlQWxsQnRuKCkgewogICAgY29uc3QgYnRuID0gZG9jdW1l
;bnQuZ2V0RWxlbWVudEJ5SWQoJ2NmZy10b2dnbGUtYWxsJyk7CiAgICBpZiAoIWJ0bikgcmV0dXJuOwogICAgY29uc3QgZXhwYW5kZWQgPSBhbnlDZmdHcm91
;cE9wZW4oKTsKICAgIGJ0bi5jbGFzc0xpc3QudG9nZ2xlKCdpcy1leHBhbmRlZCcsIGV4cGFuZGVkKTsKICAgIGJ0bi50aXRsZSA9IGV4cGFuZGVkID8gJ+WF
;qOmDqOaKmOWPoCcgOiAn5YWo6YOo5bGV5byAJzsKICAgIGJ0bi5zZXRBdHRyaWJ1dGUoJ2FyaWEtZXhwYW5kZWQnLCBleHBhbmRlZCA/ICd0cnVlJyA6ICdm
;YWxzZScpOwogIH0KICBmdW5jdGlvbiB0b2dnbGVBbGxDZmdHcm91cHMoKSB7CiAgICBjb25zdCBuZXh0ID0gIWFueUNmZ0dyb3VwT3BlbigpOwogICAgc2V0
;QWxsQ2ZnT3BlbihuZXh0KTsKICAgIHN5bmNDZmdUb2dnbGVBbGxCdG4oKTsKICB9CiAgZnVuY3Rpb24gZW5zdXJlQ29uZmlnVWkoKSB7CiAgICBpZiAoY2Zn
;VWlSZWFkeSkgcmV0dXJuOwogICAgY2ZnVWlSZWFkeSA9IHRydWU7CiAgICBkb2N1bWVudC5xdWVyeVNlbGVjdG9yQWxsKCcuY2ZnLXRhYicpLmZvckVhY2go
;YnRuID0+IHsKICAgICAgYnRuLmFkZEV2ZW50TGlzdGVuZXIoJ2NsaWNrJywgYXN5bmMgKCkgPT4gewogICAgICAgIGNvbnN0IG5hbWUgPSBidG4uZGF0YXNl
;dC5jZmc7CiAgICAgICAgaWYgKCFuYW1lIHx8IG5hbWUgPT09IGNmZ0FjdGl2ZVRhYikgcmV0dXJuOwogICAgICAgIGlmIChjZmdEaXJ0eVtjZmdBY3RpdmVU
;YWJdKSB7CiAgICAgICAgICBjb25zdCBvayA9IGF3YWl0IHVpQ29uZmlybSgn5b2T5YmN6YWN572u5pyJ5pyq5L+d5a2Y5L+u5pS577yM5YiH5o2i5bCG5Lii
;5aSx5pyq5L+d5a2Y5YaF5a6544CCJywgewogICAgICAgICAgICB0aXRsZTogJ+WIh+aNoumFjee9ricsIG9rVGV4dDogJ+e7p+e7reWIh+aNoicsIGRhbmdl
;cjogdHJ1ZQogICAgICAgICAgfSk7CiAgICAgICAgICBpZiAoIW9rKSByZXR1cm47CiAgICAgICAgfQogICAgICAgIGxvYWRBaGtDb25maWdUYWIobmFtZSwg
;ZmFsc2UpOwogICAgICB9KTsKICAgIH0pOwogICAgY29uc3QgYWRkRyA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjZmctYWRkLWdyb3VwJyk7CiAgICBp
;ZiAoYWRkRykgYWRkRy5vbmNsaWNrID0gYXN5bmMgKCkgPT4gewogICAgICBjb25zdCBnID0gY2ZnQ3VycmVudCgpOwogICAgICBpZiAoIWcpIHJldHVybjsK
;ICAgICAgY29uc3QgdGl0bGUgPSBhd2FpdCB1aVByb21wdCgn6K+36L6T5YWl5paw57uE5ZCN56ewJywgJ+aWsOWIhue7hCcsIHsKICAgICAgICB0aXRsZTog
;J+a3u+WKoOWIhue7hCcsIG9rVGV4dDogJ+a3u+WKoCcKICAgICAgfSk7CiAgICAgIGlmICh0aXRsZSA9PSBudWxsKSByZXR1cm47CiAgICAgIGcucHVzaCh7
;IHRpdGxlOiBTdHJpbmcodGl0bGUpLnRyaW0oKSB8fCAn5paw5YiG57uEJywgaXRlbXM6IFtdIH0pOwogICAgICBtYXJrQ2ZnRGlydHkoKTsKICAgICAgY29u
;c3Qgb3BlbiA9IGdldENmZ09wZW5TdGF0ZSgpOwogICAgICBvcGVuW2cubGVuZ3RoIC0gMV0gPSB0cnVlOwogICAgICByZW5kZXJDb25maWdFZGl0b3IoKTsK
;ICAgICAgc2VsZWN0Q2ZnVGFyZ2V0KGcubGVuZ3RoIC0gMSwgLTEpOwogICAgfTsKICAgIGNvbnN0IHRvZ2dsZUFsbCA9IGRvY3VtZW50LmdldEVsZW1lbnRC
;eUlkKCdjZmctdG9nZ2xlLWFsbCcpOwogICAgaWYgKHRvZ2dsZUFsbCkgdG9nZ2xlQWxsLm9uY2xpY2sgPSAoKSA9PiB0b2dnbGVBbGxDZmdHcm91cHMoKTsK
;ICAgIGRvY3VtZW50LnF1ZXJ5U2VsZWN0b3JBbGwoJy5jZmctc3RhZ1tkYXRhLWNmZy1zY29wZV0nKS5mb3JFYWNoKGJ0biA9PiB7CiAgICAgIGJ0bi5hZGRF
;dmVudExpc3RlbmVyKCdjbGljaycsICgpID0+IHsKICAgICAgICBjb25zdCBzID0gYnRuLmdldEF0dHJpYnV0ZSgnZGF0YS1jZmctc2NvcGUnKTsKICAgICAg
;ICBpZiAoIXMpIHJldHVybjsKICAgICAgICAvLyDlkK/nlKggLyDmnKrlkK/nlKjkupLmlqXvvJrngrnkuIDkuKrlsLHlhbPmjonlj6bkuIDkuKoKICAgICAg
;ICBpZiAocyA9PT0gJ2VuYWJsZWQnKSB7CiAgICAgICAgICBjZmdTZWFyY2hTY29wZS5lbmFibGVkID0gIWNmZ1NlYXJjaFNjb3BlLmVuYWJsZWQ7CiAgICAg
;ICAgICBpZiAoY2ZnU2VhcmNoU2NvcGUuZW5hYmxlZCkgY2ZnU2VhcmNoU2NvcGUuZGlzYWJsZWQgPSBmYWxzZTsKICAgICAgICB9IGVsc2UgaWYgKHMgPT09
;ICdkaXNhYmxlZCcpIHsKICAgICAgICAgIGNmZ1NlYXJjaFNjb3BlLmRpc2FibGVkID0gIWNmZ1NlYXJjaFNjb3BlLmRpc2FibGVkOwogICAgICAgICAgaWYg
;KGNmZ1NlYXJjaFNjb3BlLmRpc2FibGVkKSBjZmdTZWFyY2hTY29wZS5lbmFibGVkID0gZmFsc2U7CiAgICAgICAgfSBlbHNlIHsKICAgICAgICAgIGNmZ1Nl
;YXJjaFNjb3BlW3NdID0gIWNmZ1NlYXJjaFNjb3BlW3NdOwogICAgICAgIH0KICAgICAgICBzeW5jQ2ZnU2VhcmNoQ2hyb21lKCk7CiAgICAgICAgaWYgKGFw
;cE1vZGUgPT09ICdjb25maWcnKSByZW5kZXJDb25maWdFZGl0b3IoKTsKICAgICAgICBpZiAodHlwZW9mIHNhdmVTZXNzaW9uU29vbiA9PT0gJ2Z1bmN0aW9u
;Jykgc2F2ZVNlc3Npb25Tb29uKCk7CiAgICAgIH0pOwogICAgfSk7CiAgICBzeW5jQ2ZnU2VhcmNoQ2hyb21lKCk7CiAgICBpZiAoY2ZnVGlwRWwpIHsKICAg
;ICAgY2ZnVGlwRWwuYWRkRXZlbnRMaXN0ZW5lcignZGJsY2xpY2snLCAoZSkgPT4gewogICAgICAgIGUucHJldmVudERlZmF1bHQoKTsKICAgICAgICBiZWdp
;bkNmZ1RpcEVkaXQoKTsKICAgICAgfSk7CiAgICB9CiAgICBpZiAoY2ZnVGlwRWRpdEVsKSB7CiAgICAgIGNmZ1RpcEVkaXRFbC5hZGRFdmVudExpc3RlbmVy
;KCdibHVyJywgKCkgPT4gZW5kQ2ZnVGlwRWRpdCh0cnVlKSk7CiAgICAgIGNmZ1RpcEVkaXRFbC5hZGRFdmVudExpc3RlbmVyKCdrZXlkb3duJywgKGUpID0+
;IHsKICAgICAgICBpZiAoZS5rZXkgPT09ICdFc2NhcGUnKSB7CiAgICAgICAgICBlLnByZXZlbnREZWZhdWx0KCk7CiAgICAgICAgICBlbmRDZmdUaXBFZGl0
;KGZhbHNlKTsKICAgICAgICB9IGVsc2UgaWYgKGUua2V5ID09PSAnRW50ZXInICYmIChlLmN0cmxLZXkgfHwgZS5tZXRhS2V5KSkgewogICAgICAgICAgZS5w
;cmV2ZW50RGVmYXVsdCgpOwogICAgICAgICAgZW5kQ2ZnVGlwRWRpdCh0cnVlKTsKICAgICAgICB9CiAgICAgIH0pOwogICAgfQogICAgY29uc3QgcmVsb2Fk
;ID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2NmZy1yZWxvYWQnKTsKICAgIGlmIChyZWxvYWQpIHJlbG9hZC5vbmNsaWNrID0gYXN5bmMgKCkgPT4gewog
;ICAgICBpZiAoY2ZnRGlydHlbY2ZnQWN0aXZlVGFiXSkgewogICAgICAgIGNvbnN0IG9rID0gYXdhaXQgdWlDb25maXJtKCfmlL7lvIPmnKrkv53lrZjkv67m
;lLnlubbph43mlrDliqDovb3vvJ8nLCB7CiAgICAgICAgICB0aXRsZTogJ+mHjeaWsOWKoOi9vScsIG9rVGV4dDogJ+aUvuW8g+W5tuWKoOi9vScsIGRhbmdl
;cjogdHJ1ZQogICAgICAgIH0pOwogICAgICAgIGlmICghb2spIHJldHVybjsKICAgICAgfQogICAgICBsb2FkQWhrQ29uZmlnVGFiKGNmZ0FjdGl2ZVRhYiwg
;dHJ1ZSk7CiAgICB9OwogICAgY29uc3Qgc2F2ZSA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjZmctc2F2ZScpOwogICAgaWYgKHNhdmUpIHNhdmUub25j
;bGljayA9ICgpID0+IHNhdmVBaGtDb25maWdUYWIoKTsKICAgIGlmIChjZmdNZW51KSB7CiAgICAgIGNmZ01lbnUucXVlcnlTZWxlY3RvckFsbCgnYnV0dG9u
;W2RhdGEtY2FjdF0nKS5mb3JFYWNoKGJ0biA9PiB7CiAgICAgICAgYnRuLmFkZEV2ZW50TGlzdGVuZXIoJ2NsaWNrJywgKGUpID0+IHsKICAgICAgICAgIGUu
;c3RvcFByb3BhZ2F0aW9uKCk7CiAgICAgICAgICBydW5DZmdNZW51QWN0aW9uKGJ0bi5nZXRBdHRyaWJ1dGUoJ2RhdGEtY2FjdCcpKTsKICAgICAgICB9KTsK
;ICAgICAgfSk7CiAgICB9CiAgICBkb2N1bWVudC5hZGRFdmVudExpc3RlbmVyKCdjbGljaycsIChlKSA9PiB7CiAgICAgIGlmIChjZmdNZW51ICYmIGNmZ01l
;bnUuY2xhc3NMaXN0LmNvbnRhaW5zKCdvbicpICYmICFlLnRhcmdldC5jbG9zZXN0KCcjY2ZnLW1lbnUnKSkgaGlkZUNmZ01lbnUoKTsKICAgIH0pOwogICAg
;ZG9jdW1lbnQuYWRkRXZlbnRMaXN0ZW5lcignY29udGV4dG1lbnUnLCAoZSkgPT4gewogICAgICBpZiAoIWUudGFyZ2V0LmNsb3Nlc3QoJyNjb25maWctcGFu
;ZWwnKSAmJiAhZS50YXJnZXQuY2xvc2VzdCgnI2NmZy1tZW51JykpIGhpZGVDZmdNZW51KCk7CiAgICB9KTsKICAgIHdpbmRvdy5hZGRFdmVudExpc3RlbmVy
;KCdibHVyJywgaGlkZUNmZ01lbnUpOwogICAgd2luZG93LmFkZEV2ZW50TGlzdGVuZXIoJ3Jlc2l6ZScsIGhpZGVDZmdNZW51KTsKICB9CiAgZnVuY3Rpb24g
;bG9hZEFoa0NvbmZpZ1RhYihuYW1lLCBmb3JjZSkgewogICAgbmFtZSA9IFN0cmluZyhuYW1lIHx8ICdydW5jb25maWcnKTsKICAgIGNmZ0FjdGl2ZVRhYiA9
;IG5hbWU7CiAgICBkb2N1bWVudC5xdWVyeVNlbGVjdG9yQWxsKCcuY2ZnLXRhYicpLmZvckVhY2goYiA9PiBiLmNsYXNzTGlzdC50b2dnbGUoJ29uJywgYi5k
;YXRhc2V0LmNmZyA9PT0gbmFtZSkpOwogICAgdXBkYXRlQ2ZnUGF0aEJhcihjZmdQYXRoc1tuYW1lXSB8fCAnJyk7CiAgICBpZiAodHlwZW9mIHNhdmVTZXNz
;aW9uU29vbiA9PT0gJ2Z1bmN0aW9uJykgc2F2ZVNlc3Npb25Tb29uKCk7CiAgICBpZiAoIWZvcmNlICYmIGNmZ0NhY2hlW25hbWVdKSB7CiAgICAgIGNmZ0Rp
;cnR5W25hbWVdID0gZmFsc2U7CiAgICAgIHNldENmZ1N0YXR1cygnJywgJycpOwogICAgICBzeW5jQ2ZnVGlwVWkoKTsKICAgICAgcmVuZGVyQ29uZmlnRWRp
;dG9yKCk7CiAgICAgIHJldHVybjsKICAgIH0KICAgICsrY2ZnTG9hZEdlbjsKICAgIHNldENmZ1N0YXR1cygnJywgJycpOwogICAgc3luY0NmZ1RpcFVpKCk7
;CiAgICBpZiAoY2ZnQm9keSkgY2ZnQm9keS5pbm5lckhUTUwgPSAnPGRpdiBjbGFzcz0iY2ZnLWVtcHR5Ij7liqDovb3kuK3igKY8L2Rpdj4nOwogICAgcG9z
;dCgnY29uZmlnTG9hZHwnICsgbmFtZSk7CiAgfQogIGZ1bmN0aW9uIHNhdmVBaGtDb25maWdUYWIoKSB7CiAgICBlbmRDZmdUaXBFZGl0KHRydWUpOwogICAg
;Y29uc3QgZG9jID0gY2ZnRG9jKCk7CiAgICBpZiAoIWRvYyB8fCAhZG9jLmdyb3VwcykgeyBzZXRDZmdTdGF0dXMoJ+ayoeacieWPr+S/neWtmOeahOWGheWu
;uScsICdlcnInKTsgcmV0dXJuOyB9CiAgICBjb25zdCB0ZXh0ID0gc2VyaWFsaXplQWhrQ29uZmlnKGRvYyk7CiAgICBjb25zdCBiNjQgPSB0ZXh0VG9CNjQo
;dGV4dCk7CiAgICBpZiAoIWI2NCkgeyBzZXRDZmdTdGF0dXMoJ+e8lueggeWksei0pScsICdlcnInKTsgcmV0dXJuOyB9CiAgICBzZXRDZmdTdGF0dXMoJ+at
;o+WcqOS/neWtmOKApicsICdpbmZvJyk7CiAgICBwb3N0KCdjb25maWdTYXZlfCcgKyBjZmdBY3RpdmVUYWIgKyAnfCcgKyBiNjQpOwogIH0KICBmdW5jdGlv
;biBpdGVtTWF0Y2hlc1NlYXJjaChpdCwgcSkgewogICAgY29uc3QgZW4gPSBpdC5lbmFibGVkICE9PSBmYWxzZTsKICAgIGNvbnN0IG9ubHlPbiA9IGNmZ1Nl
;YXJjaFNjb3BlLmVuYWJsZWQgJiYgIWNmZ1NlYXJjaFNjb3BlLmRpc2FibGVkOwogICAgY29uc3Qgb25seU9mZiA9IGNmZ1NlYXJjaFNjb3BlLmRpc2FibGVk
;ICYmICFjZmdTZWFyY2hTY29wZS5lbmFibGVkOwogICAgaWYgKG9ubHlPbiAmJiAhZW4pIHJldHVybiBmYWxzZTsKICAgIGlmIChvbmx5T2ZmICYmIGVuKSBy
;ZXR1cm4gZmFsc2U7CiAgICBpZiAoIXEpIHJldHVybiB0cnVlOwogICAgY29uc3QgayA9IFN0cmluZyhpdC5rZXkgfHwgJycpLnRvTG93ZXJDYXNlKCk7CiAg
;ICBjb25zdCB2ID0gU3RyaW5nKGl0LnZhbHVlIHx8ICcnKS50b0xvd2VyQ2FzZSgpOwogICAgY29uc3QgYyA9IFN0cmluZyhpdC5jb21tZW50IHx8ICcnKS50
;b0xvd2VyQ2FzZSgpOwogICAgY29uc3Qgb25seUtleSA9IGNmZ1NlYXJjaFNjb3BlLmtleSAmJiAhY2ZnU2VhcmNoU2NvcGUudmFsdWU7CiAgICBjb25zdCBv
;bmx5VmFsID0gY2ZnU2VhcmNoU2NvcGUudmFsdWUgJiYgIWNmZ1NlYXJjaFNjb3BlLmtleTsKICAgIGNvbnN0IGtleU9yVmFsID0gY2ZnU2VhcmNoU2NvcGUu
;a2V5ICYmIGNmZ1NlYXJjaFNjb3BlLnZhbHVlOwogICAgaWYgKG9ubHlLZXkpIHJldHVybiBrLmluY2x1ZGVzKHEpOwogICAgaWYgKG9ubHlWYWwpIHJldHVy
;biB2LmluY2x1ZGVzKHEpOwogICAgaWYgKGtleU9yVmFsKSByZXR1cm4gay5pbmNsdWRlcyhxKSB8fCB2LmluY2x1ZGVzKHEpOwogICAgcmV0dXJuIGsuaW5j
;bHVkZXMocSkgfHwgdi5pbmNsdWRlcyhxKSB8fCBjLmluY2x1ZGVzKHEpOwogIH0KICBmdW5jdGlvbiBjZmdIYXNBY3RpdmVGaWx0ZXIoKSB7CiAgICByZXR1
;cm4gISEoY2ZnU2VhcmNoIHx8IGNmZ1NlYXJjaFNjb3BlLmVuYWJsZWQgfHwgY2ZnU2VhcmNoU2NvcGUuZGlzYWJsZWQpOwogIH0KICBmdW5jdGlvbiBncm91
;cFRpdGxlTWF0Y2hlcyh0aXRsZSwgcSkgewogICAgaWYgKCFxKSByZXR1cm4gZmFsc2U7CiAgICAvLyDpmZDlrpoga2V5L3ZhbHVlIOaXtuS4jeaMiee7hOWQ
;jeWMuemFjQogICAgaWYgKGNmZ1NlYXJjaFNjb3BlLmtleSB8fCBjZmdTZWFyY2hTY29wZS52YWx1ZSkgcmV0dXJuIGZhbHNlOwogICAgcmV0dXJuIFN0cmlu
;Zyh0aXRsZSB8fCAnJykudG9Mb3dlckNhc2UoKS5pbmNsdWRlcyhxKTsKICB9CiAgZnVuY3Rpb24gaGlnaGxpZ2h0Q2ZnSHRtbCh0ZXh0LCBxKSB7CiAgICBs
;ZXQgaHRtbCA9IGVzY2FwZUh0bWwoU3RyaW5nKHRleHQgPz8gJycpKTsKICAgIGNvbnN0IHJhd1EgPSBTdHJpbmcocSB8fCAnJykudHJpbSgpOwogICAgaWYg
;KCFyYXdRKSByZXR1cm4gaHRtbDsKICAgIGNvbnN0IHRlcm1zID0gcmF3US5zcGxpdCgvXHMrLykubWFwKHQgPT4gdC50cmltKCkpLmZpbHRlcihCb29sZWFu
;KQogICAgICAuc29ydCgoYSwgYikgPT4gYi5sZW5ndGggLSBhLmxlbmd0aCk7CiAgICBmb3IgKGNvbnN0IHQgb2YgdGVybXMpIHsKICAgICAgY29uc3QgcmUg
;PSBuZXcgUmVnRXhwKHQucmVwbGFjZSgvWy4qKz9eJHt9KCl8W1xdXFxdL2csICdcXCQmJyksICdnaScpOwogICAgICBodG1sID0gaHRtbC5yZXBsYWNlKHJl
;LCBtID0+ICc8bWFyaz4nICsgbSArICc8L21hcms+Jyk7CiAgICB9CiAgICByZXR1cm4gaHRtbDsKICB9CiAgZnVuY3Rpb24gbWFrZUNmZ0hsRmllbGQoY2xh
;c3NOYW1lLCB2YWx1ZSwgcSwgb25Db21taXQsIG9wdHMpIHsKICAgIG9wdHMgPSBvcHRzIHx8IHt9OwogICAgY29uc3Qgd3JhcCA9IGRvY3VtZW50LmNyZWF0
;ZUVsZW1lbnQoJ2RpdicpOwogICAgd3JhcC5jbGFzc05hbWUgPSAnY2ZnLWhsLWZpZWxkICcgKyBjbGFzc05hbWU7CiAgICBjb25zdCBpbnAgPSBkb2N1bWVu
;dC5jcmVhdGVFbGVtZW50KCdpbnB1dCcpOwogICAgaW5wLnR5cGUgPSAndGV4dCc7CiAgICBpbnAuY2xhc3NOYW1lID0gY2xhc3NOYW1lOwogICAgaW5wLnBs
;YWNlaG9sZGVyID0gb3B0cy5wbGFjZWhvbGRlciB8fCAnJzsKICAgIGlucC52YWx1ZSA9IHZhbHVlIHx8ICcnOwogICAgaWYgKCFxKSB7CiAgICAgIGlucC5v
;bmlucHV0ID0gKCkgPT4gb25Db21taXQoaW5wLnZhbHVlKTsKICAgICAgd3JhcC5hcHBlbmRDaGlsZChpbnApOwogICAgICByZXR1cm4geyB3cmFwLCBpbnB1
;dDogaW5wIH07CiAgICB9CiAgICBjb25zdCB2aWV3ID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnZGl2Jyk7CiAgICB2aWV3LmNsYXNzTmFtZSA9ICdjZmct
;aGwtdmlldyc7CiAgICBjb25zdCBwaCA9IGVzY2FwZUh0bWwob3B0cy5wbGFjZWhvbGRlciB8fCAnJyk7CiAgICB2aWV3LmlubmVySFRNTCA9IGhpZ2hsaWdo
;dENmZ0h0bWwodmFsdWUgfHwgJycsIHEpIHx8ICgnPHNwYW4gc3R5bGU9ImNvbG9yOiM5NGEzYjgiPicgKyBwaCArICc8L3NwYW4+Jyk7CiAgICBjb25zdCBz
;aG93VmlldyA9ICgpID0+IHsKICAgICAgaW5wLnN0eWxlLmRpc3BsYXkgPSAnbm9uZSc7CiAgICAgIHZpZXcuc3R5bGUuZGlzcGxheSA9ICcnOwogICAgICB2
;aWV3LmlubmVySFRNTCA9IGhpZ2hsaWdodENmZ0h0bWwoaW5wLnZhbHVlIHx8ICcnLCBxKSB8fCAoJzxzcGFuIHN0eWxlPSJjb2xvcjojOTRhM2I4Ij4nICsg
;cGggKyAnPC9zcGFuPicpOwogICAgfTsKICAgIGNvbnN0IHNob3dFZGl0ID0gKCkgPT4gewogICAgICB2aWV3LnN0eWxlLmRpc3BsYXkgPSAnbm9uZSc7CiAg
;ICAgIGlucC5zdHlsZS5kaXNwbGF5ID0gJyc7CiAgICAgIHRyeSB7IGlucC5mb2N1cygpOyBpbnAuc2VsZWN0KCk7IH0gY2F0Y2ggKF8pIHt9CiAgICB9Owog
;ICAgaW5wLnN0eWxlLmRpc3BsYXkgPSAnbm9uZSc7CiAgICBpbnAub25pbnB1dCA9ICgpID0+IG9uQ29tbWl0KGlucC52YWx1ZSk7CiAgICBpbnAub25ibHVy
;ID0gKCkgPT4geyBvbkNvbW1pdChpbnAudmFsdWUpOyBzaG93VmlldygpOyB9OwogICAgaW5wLm9ua2V5ZG93biA9IChlKSA9PiB7CiAgICAgIGlmIChlLmtl
;eSA9PT0gJ0VudGVyJyB8fCBlLmtleSA9PT0gJ0VzY2FwZScpIHsgZS5wcmV2ZW50RGVmYXVsdCgpOyBpbnAuYmx1cigpOyB9CiAgICB9OwogICAgdmlldy5v
;bmNsaWNrID0gKGUpID0+IHsgZS5zdG9wUHJvcGFnYXRpb24oKTsgc2hvd0VkaXQoKTsgfTsKICAgIHdyYXAuYXBwZW5kQ2hpbGQodmlldyk7CiAgICB3cmFw
;LmFwcGVuZENoaWxkKGlucCk7CiAgICByZXR1cm4geyB3cmFwLCBpbnB1dDogaW5wLCB2aWV3IH07CiAgfQogIGZ1bmN0aW9uIHJlbmRlckNvbmZpZ0VkaXRv
;cigpIHsKICAgIGlmICghY2ZnQm9keSkgcmV0dXJuOwogICAgY29uc3QgZ3JvdXBzID0gY2ZnQ3VycmVudCgpOwogICAgaWYgKCFncm91cHMpIHsKICAgICAg
;Y2ZnQm9keS5pbm5lckhUTUwgPSAnPGRpdiBjbGFzcz0iY2ZnLWVtcHR5Ij7mmoLml6DmlbDmja48L2Rpdj4nOwogICAgICB1cGRhdGVDZmdQYXRoQmFyKGNm
;Z1BhdGhzW2NmZ0FjdGl2ZVRhYl0gfHwgJycpOwogICAgICB1cGRhdGVDZmdTZWFyY2hIaXQoMCk7CiAgICAgIHN5bmNDZmdTZWFyY2hDaHJvbWUoKTsKICAg
;ICAgcmV0dXJuOwogICAgfQogICAgY29uc3QgcSA9IGNmZ1NlYXJjaDsKICAgIGNvbnN0IGZpbHRlcmluZyA9IGNmZ0hhc0FjdGl2ZUZpbHRlcigpOwogICAg
;bGV0IHRvdGFsID0gMDsKICAgIGxldCBzaG93biA9IDA7CiAgICBjZmdCb2R5LmlubmVySFRNTCA9ICcnOwogICAgbGV0IGFueSA9IGZhbHNlOwogICAgZ3Jv
;dXBzLmZvckVhY2goKGcsIGdpKSA9PiB7CiAgICAgIHRvdGFsICs9IChnLml0ZW1zIHx8IFtdKS5sZW5ndGg7CiAgICAgIGNvbnN0IHRpdGxlSGl0ID0gZ3Jv
;dXBUaXRsZU1hdGNoZXMoZy50aXRsZSwgcSk7CiAgICAgIGNvbnN0IG1hdGNoZWRJdGVtcyA9IChnLml0ZW1zIHx8IFtdKS5tYXAoKGl0LCBpaSkgPT4gKHsg
;aXQ6IG5vcm1hbGl6ZUl0ZW0oaXQpLCBpaSB9KSkKICAgICAgICAuZmlsdGVyKHggPT4gaXRlbU1hdGNoZXNTZWFyY2goeC5pdCwgcSkpOwogICAgICBpZiAo
;ZmlsdGVyaW5nICYmICFtYXRjaGVkSXRlbXMubGVuZ3RoICYmICF0aXRsZUhpdCkgcmV0dXJuOwogICAgICBhbnkgPSB0cnVlOwogICAgICBjb25zdCByb3dz
;ID0gIWZpbHRlcmluZwogICAgICAgID8gKGcuaXRlbXMgfHwgW10pLm1hcCgoaXQsIGlpKSA9PiAoeyBpdDogbm9ybWFsaXplSXRlbShpdCksIGlpIH0pKQog
;ICAgICAgIDogKG1hdGNoZWRJdGVtcy5sZW5ndGggfHwgIXRpdGxlSGl0CiAgICAgICAgICA/IG1hdGNoZWRJdGVtcwogICAgICAgICAgOiAoZy5pdGVtcyB8
;fCBbXSkubWFwKChpdCwgaWkpID0+ICh7IGl0OiBub3JtYWxpemVJdGVtKGl0KSwgaWkgfSkpLmZpbHRlcih4ID0+IGl0ZW1NYXRjaGVzU2VhcmNoKHguaXQs
;ICcnKSkpOwogICAgICBzaG93biArPSByb3dzLmxlbmd0aDsKICAgICAgY29uc3QgZm9yY2VPcGVuID0gZmlsdGVyaW5nOwogICAgICBjb25zdCBpc09wZW4g
;PSBpc0NmZ0dyb3VwT3BlbihnaSwgZm9yY2VPcGVuKTsKICAgICAgY29uc3QgY2FyZCA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOwogICAgICBj
;YXJkLmNsYXNzTmFtZSA9ICdjZmctY2FyZCcKICAgICAgICArIChpc09wZW4gPyAnIG9wZW4nIDogJycpCiAgICAgICAgKyAoY2ZnU2VsLmdpID09PSBnaSA/
;ICcgb24nIDogJycpCiAgICAgICAgKyAodGl0bGVIaXQgPyAnIGhpdCcgOiAnJyk7CiAgICAgIGNhcmQuZGF0YXNldC5naSA9IFN0cmluZyhnaSk7CiAgICAg
;IGNvbnN0IGhkID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnZGl2Jyk7CiAgICAgIGhkLmNsYXNzTmFtZSA9ICdjZmctY2FyZC1oZCc7CiAgICAgIGNvbnN0
;IHRpdGxlSW5wID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnaW5wdXQnKTsKICAgICAgdGl0bGVJbnAudHlwZSA9ICd0ZXh0JzsKICAgICAgdGl0bGVJbnAu
;Y2xhc3NOYW1lID0gJ2NmZy1ndGl0bGUnOwogICAgICB0aXRsZUlucC52YWx1ZSA9IGcudGl0bGUgfHwgJyc7CiAgICAgIHRpdGxlSW5wLnBsYWNlaG9sZGVy
;ID0gJ+e7hOWQjSc7CiAgICAgIHRpdGxlSW5wLm9uaW5wdXQgPSAoKSA9PiB7IGcudGl0bGUgPSB0aXRsZUlucC52YWx1ZTsgbWFya0NmZ0RpcnR5KCk7IH07
;CiAgICAgIHRpdGxlSW5wLm9uZm9jdXMgPSAoKSA9PiBzZWxlY3RDZmdUYXJnZXQoZ2ksIC0xKTsKICAgICAgaWYgKHEgJiYgU3RyaW5nKGcudGl0bGUgfHwg
;JycpLnRvTG93ZXJDYXNlKCkuaW5jbHVkZXMocSkpIHsKICAgICAgICBjb25zdCB0aXRsZUhsID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnZGl2Jyk7CiAg
;ICAgICAgdGl0bGVIbC5jbGFzc05hbWUgPSAnY2ZnLWd0aXRsZS1obCc7CiAgICAgICAgdGl0bGVIbC5pbm5lckhUTUwgPSBoaWdobGlnaHRDZmdIdG1sKGcu
;dGl0bGUgfHwgJycsIHEpOwogICAgICAgIHRpdGxlSGwudGl0bGUgPSAn54K55Ye757yW6L6R57uE5ZCNJzsKICAgICAgICB0aXRsZUhsLm9uY2xpY2sgPSAo
;ZSkgPT4gewogICAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICAgIHRpdGxlSGwucmVwbGFjZVdpdGgodGl0bGVJbnApOwogICAgICAgICAg
;dHJ5IHsgdGl0bGVJbnAuZm9jdXMoKTsgdGl0bGVJbnAuc2VsZWN0KCk7IH0gY2F0Y2ggKF8pIHt9CiAgICAgICAgfTsKICAgICAgICB0aXRsZUlucC5vbmJs
;dXIgPSAoKSA9PiB7CiAgICAgICAgICBnLnRpdGxlID0gdGl0bGVJbnAudmFsdWU7CiAgICAgICAgICBtYXJrQ2ZnRGlydHkoKTsKICAgICAgICAgIHRpdGxl
;SGwuaW5uZXJIVE1MID0gaGlnaGxpZ2h0Q2ZnSHRtbChnLnRpdGxlIHx8ICcnLCBxKTsKICAgICAgICAgIGlmICh0aXRsZUlucC5wYXJlbnROb2RlKSB0aXRs
;ZUlucC5yZXBsYWNlV2l0aCh0aXRsZUhsKTsKICAgICAgICB9OwogICAgICAgIGhkLmFwcGVuZENoaWxkKHRpdGxlSGwpOwogICAgICB9IGVsc2UgewogICAg
;ICAgIGhkLmFwcGVuZENoaWxkKHRpdGxlSW5wKTsKICAgICAgfQogICAgICBjb25zdCBjb3VudCA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2J1dHRvbicp
;OwogICAgICBjb3VudC50eXBlID0gJ2J1dHRvbic7CiAgICAgIGNvdW50LmNsYXNzTmFtZSA9ICdjZmctZ2NvdW50JzsKICAgICAgY291bnQudGl0bGUgPSBp
;c09wZW4gPyAn54K55Ye75oqY5Y+gJyA6ICfngrnlh7vlsZXlvIAnOwogICAgICBjb3VudC5pbm5lckhUTUwgPSAnPHNwYW4gY2xhc3M9ImNmZy1jaGV2Ij4n
;ICsgKGlzT3BlbiA/ICfilr4nIDogJ+KWuCcpICsgJzwvc3Bhbj48c3Bhbj4nICsgcm93cy5sZW5ndGggKyAnIOmhuTwvc3Bhbj4nOwogICAgICBjb3VudC5v
;bmNsaWNrID0gKGUpID0+IHsKICAgICAgICBlLnByZXZlbnREZWZhdWx0KCk7CiAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICBzZWxlY3RD
;ZmdUYXJnZXQoZ2ksIC0xKTsKICAgICAgICBpZiAoZm9yY2VPcGVuKSByZXR1cm47CiAgICAgICAgdG9nZ2xlQ2ZnR3JvdXAoZ2kpOwogICAgICB9OwogICAg
;ICBoZC5hcHBlbmRDaGlsZChjb3VudCk7CiAgICAgIGhkLm9uY29udGV4dG1lbnUgPSAoZSkgPT4gewogICAgICAgIGUucHJldmVudERlZmF1bHQoKTsKICAg
;ICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgICAgIHNlbGVjdENmZ1RhcmdldChnaSwgLTEpOwogICAgICAgIHNob3dDZmdNZW51KGUuY2xpZW50WCwg
;ZS5jbGllbnRZLCB7IHR5cGU6ICdncm91cCcsIGdpIH0pOwogICAgICB9OwogICAgICBoZC5vbmNsaWNrID0gKGUpID0+IHsKICAgICAgICBpZiAoZS50YXJn
;ZXQuY2xvc2VzdCgnLmNmZy1nY291bnQsIGlucHV0LCAuY2ZnLWd0aXRsZS1obCcpKSByZXR1cm47CiAgICAgICAgc2VsZWN0Q2ZnVGFyZ2V0KGdpLCAtMSk7
;CiAgICAgIH07CiAgICAgIGNhcmQuYXBwZW5kQ2hpbGQoaGQpOwogICAgICBjb25zdCBsaXN0ID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnZGl2Jyk7CiAg
;ICAgIGxpc3QuY2xhc3NOYW1lID0gJ2NmZy1saXN0JzsKICAgICAgaWYgKGlzT3BlbikgewogICAgICAgIGlmICghcm93cy5sZW5ndGgpIHsKICAgICAgICAg
;IGNvbnN0IGVtcHR5ID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnZGl2Jyk7CiAgICAgICAgICBlbXB0eS5jbGFzc05hbWUgPSAnY2ZnLWl0ZW0tZW1wdHkn
;OwogICAgICAgICAgZW1wdHkudGV4dENvbnRlbnQgPSBxID8gJ+aXoOWMuemFjeadoeebricgOiAn5Y+z6ZSu5YiG57uE5qCH6aKY5Y+v5re75Yqg5p2h55uu
;JzsKICAgICAgICAgIGxpc3QuYXBwZW5kQ2hpbGQoZW1wdHkpOwogICAgICAgIH0KICAgICAgICByb3dzLmZvckVhY2goKHsgaXQsIGlpIH0pID0+IHsKICAg
;ICAgICAgIGNvbnN0IHJvdyA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOwogICAgICAgICAgcm93LmNsYXNzTmFtZSA9ICdjZmctaXRlbScKICAg
;ICAgICAgICAgKyAoaXQuZW5hYmxlZCA9PT0gZmFsc2UgPyAnIG9mZicgOiAnJykKICAgICAgICAgICAgKyAoY2ZnU2VsLmdpID09PSBnaSAmJiBjZmdTZWwu
;aWkgPT09IGlpID8gJyBvbicgOiAnJyk7CiAgICAgICAgICByb3cuZGF0YXNldC5naSA9IFN0cmluZyhnaSk7CiAgICAgICAgICByb3cuZGF0YXNldC5paSA9
;IFN0cmluZyhpaSk7CiAgICAgICAgICBjb25zdCBkb3QgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdzcGFuJyk7CiAgICAgICAgICBkb3QuY2xhc3NOYW1l
;ID0gJ2NmZy1kb3QnOwogICAgICAgICAgY29uc3Qgb25seUtleSA9IGNmZ1NlYXJjaFNjb3BlLmtleSAmJiAhY2ZnU2VhcmNoU2NvcGUudmFsdWU7CiAgICAg
;ICAgICBjb25zdCBvbmx5VmFsID0gY2ZnU2VhcmNoU2NvcGUudmFsdWUgJiYgIWNmZ1NlYXJjaFNjb3BlLmtleTsKICAgICAgICAgIGNvbnN0IHFLZXkgPSAo
;IXEgfHwgb25seVZhbCkgPyAnJyA6IHE7CiAgICAgICAgICBjb25zdCBxVmFsID0gKCFxIHx8IG9ubHlLZXkpID8gJycgOiBxOwogICAgICAgICAgY29uc3Qg
;cUNtdCA9ICghcSB8fCBjZmdTZWFyY2hTY29wZS5rZXkgfHwgY2ZnU2VhcmNoU2NvcGUudmFsdWUpID8gJycgOiBxOwogICAgICAgICAgY29uc3Qga2V5Rmll
;bGQgPSBtYWtlQ2ZnSGxGaWVsZCgnY2ZnLWtleScsIGl0LmtleSB8fCAnJywgcUtleSwgKHYpID0+IHsgaXQua2V5ID0gdjsgbWFya0NmZ0RpcnR5KCk7IH0s
;IHsgcGxhY2Vob2xkZXI6ICdrZXknIH0pOwogICAgICAgICAgY29uc3QgdmljbyA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ3NwYW4nKTsKICAgICAgICAg
;IHZpY28uY2xhc3NOYW1lID0gJ2NmZy12aWNvJzsKICAgICAgICAgIGNvbnN0IHZhbEZpZWxkID0gbWFrZUNmZ0hsRmllbGQoJ2NmZy12YWwnLCBpdC52YWx1
;ZSB8fCAnJywgcVZhbCwgKHYpID0+IHsKICAgICAgICAgICAgaXQudmFsdWUgPSB2OwogICAgICAgICAgICBtYXJrQ2ZnRGlydHkoKTsKICAgICAgICAgICAg
;Y29uc3QgY2xzID0gY2xhc3NpZnlDZmdWYWx1ZSh2KTsKICAgICAgICAgICAgcmVxdWVzdENmZ0ljb24odmljbywgY2xzLmtpbmQsIGNscy5wYXRoKTsKICAg
;ICAgICAgIH0sIHsgcGxhY2Vob2xkZXI6ICd2YWx1ZScgfSk7CiAgICAgICAgICBjb25zdCByZWZyZXNoSWNvID0gKCkgPT4gewogICAgICAgICAgICBjb25z
;dCBjbHMgPSBjbGFzc2lmeUNmZ1ZhbHVlKGl0LnZhbHVlIHx8ICcnKTsKICAgICAgICAgICAgcmVxdWVzdENmZ0ljb24odmljbywgY2xzLmtpbmQsIGNscy5w
;YXRoKTsKICAgICAgICAgIH07CiAgICAgICAgICBjb25zdCBlbldyYXAgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdsYWJlbCcpOwogICAgICAgICAgZW5X
;cmFwLmNsYXNzTmFtZSA9ICdjZmctZW4nOwogICAgICAgICAgZW5XcmFwLnRpdGxlID0gJ+WPlua2iOWLvumAieWImeS/neWtmOS4uu+8miNrZXk9dmFsdWUg
;ICAj5byD55SoJzsKICAgICAgICAgIGNvbnN0IGNoayA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2lucHV0Jyk7CiAgICAgICAgICBjaGsudHlwZSA9ICdj
;aGVja2JveCc7CiAgICAgICAgICBjaGsuY2hlY2tlZCA9IGl0LmVuYWJsZWQgIT09IGZhbHNlOwogICAgICAgICAgY2hrLm9uY2hhbmdlID0gKCkgPT4gewog
;ICAgICAgICAgICBpdC5lbmFibGVkID0gISFjaGsuY2hlY2tlZDsKICAgICAgICAgICAgbWFya0NmZ0RpcnR5KCk7CiAgICAgICAgICAgIHJvdy5jbGFzc0xp
;c3QudG9nZ2xlKCdvZmYnLCAhaXQuZW5hYmxlZCk7CiAgICAgICAgICB9OwogICAgICAgICAgZW5XcmFwLmFwcGVuZENoaWxkKGNoayk7CiAgICAgICAgICBl
;bldyYXAuYXBwZW5kQ2hpbGQoZG9jdW1lbnQuY3JlYXRlVGV4dE5vZGUoJ+WQr+eUqCcpKTsKICAgICAgICAgIHJvdy5hcHBlbmRDaGlsZChkb3QpOwogICAg
;ICAgICAgcm93LmFwcGVuZENoaWxkKGtleUZpZWxkLndyYXApOwogICAgICAgICAgcm93LmFwcGVuZENoaWxkKHZpY28pOwogICAgICAgICAgcm93LmFwcGVu
;ZENoaWxkKHZhbEZpZWxkLndyYXApOwogICAgICAgICAgY29uc3QgY210RmllbGQgPSBtYWtlQ2ZnSGxGaWVsZCgnY2ZnLWNtdCcsIGl0LmNvbW1lbnQgfHwg
;JycsIHFDbXQsICh2KSA9PiB7IGl0LmNvbW1lbnQgPSB2OyBtYXJrQ2ZnRGlydHkoKTsgfSwgeyBwbGFjZWhvbGRlcjogJyPms6jph4onIH0pOwogICAgICAg
;ICAgcm93LmFwcGVuZENoaWxkKGNtdEZpZWxkLndyYXApOwogICAgICAgICAgcm93LmFwcGVuZENoaWxkKGVuV3JhcCk7CiAgICAgICAgICByb3cub25jbGlj
;ayA9IChlKSA9PiB7CiAgICAgICAgICAgIGlmIChlLnRhcmdldC5jbG9zZXN0KCdpbnB1dCxsYWJlbCxidXR0b24sLmNmZy1obC12aWV3JykpIHsgc2VsZWN0
;Q2ZnVGFyZ2V0KGdpLCBpaSk7IHJldHVybjsgfQogICAgICAgICAgICBzZWxlY3RDZmdUYXJnZXQoZ2ksIGlpKTsKICAgICAgICAgIH07CiAgICAgICAgICBy
;b3cub25jb250ZXh0bWVudSA9IChlKSA9PiB7CiAgICAgICAgICAgIGUucHJldmVudERlZmF1bHQoKTsKICAgICAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24o
;KTsKICAgICAgICAgICAgc2VsZWN0Q2ZnVGFyZ2V0KGdpLCBpaSk7CiAgICAgICAgICAgIHNob3dDZmdNZW51KGUuY2xpZW50WCwgZS5jbGllbnRZLCB7IHR5
;cGU6ICdpdGVtJywgZ2ksIGlpIH0pOwogICAgICAgICAgfTsKICAgICAgICAgIGxpc3QuYXBwZW5kQ2hpbGQocm93KTsKICAgICAgICAgIHJlZnJlc2hJY28o
;KTsKICAgICAgICB9KTsKICAgICAgfQogICAgICBjYXJkLmFwcGVuZENoaWxkKGxpc3QpOwogICAgICBjZmdCb2R5LmFwcGVuZENoaWxkKGNhcmQpOwogICAg
;fSk7CiAgICBpZiAoIWFueSkgY2ZnQm9keS5pbm5lckhUTUwgPSAnPGRpdiBjbGFzcz0iY2ZnLWVtcHR5Ij7ml6DljLnphY3nu5Pmnpw8L2Rpdj4nOwogICAg
;aWYgKGNmZ1NlbC5naSA+PSAwKSBzZWxlY3RDZmdUYXJnZXQoY2ZnU2VsLmdpLCBjZmdTZWwuaWkpOwogICAgZWxzZSB1cGRhdGVDZmdQYXRoQmFyKGNmZ1Bh
;dGhzW2NmZ0FjdGl2ZVRhYl0gfHwgJycpOwogICAgc3luY0NmZ1RvZ2dsZUFsbEJ0bigpOwogICAgdXBkYXRlQ2ZnU2VhcmNoSGl0KGZpbHRlcmluZyA/IHNo
;b3duIDogMCk7CiAgICBzeW5jQ2ZnU2VhcmNoQ2hyb21lKCk7CiAgfQoKICB3aW5kb3cuX19zZXRBaGtDb25maWcgPSAocGF5bG9hZCkgPT4gewogICAgdHJ5
;IHsKICAgICAgY29uc3QgZGF0YSA9IHR5cGVvZiBwYXlsb2FkID09PSAnc3RyaW5nJyA/IEpTT04ucGFyc2UocGF5bG9hZCkgOiBwYXlsb2FkOwogICAgICBj
;b25zdCBuYW1lID0gU3RyaW5nKGRhdGEgJiYgZGF0YS5uYW1lIHx8ICcnKTsKICAgICAgY29uc3Qgb2sgPSAhIShkYXRhICYmIGRhdGEub2spOwogICAgICBj
;b25zdCBtc2cgPSBTdHJpbmcoZGF0YSAmJiBkYXRhLm1lc3NhZ2UgfHwgJycpOwogICAgICBpZiAoZGF0YSAmJiBkYXRhLnBhdGgpIGNmZ1BhdGhzW25hbWUg
;fHwgY2ZnQWN0aXZlVGFiXSA9IFN0cmluZyhkYXRhLnBhdGgpOwogICAgICBpZiAoIW9rKSB7IHNldENmZ1N0YXR1cyhtc2cgfHwgJ+aTjeS9nOWksei0pScs
;ICdlcnInKTsgcmV0dXJuOyB9CiAgICAgIGNvbnN0IGlzU2F2ZSA9IC/lt7Lkv53lrZh85L+d5a2Y5oiQ5YqfLy50ZXN0KG1zZyk7CiAgICAgIGNvbnN0IGlz
;TG9hZCA9IC/lt7LliqDovb0vLnRlc3QobXNnKTsKICAgICAgaWYgKGRhdGEudGV4dCAhPSBudWxsKSB7CiAgICAgICAgY2ZnQ2FjaGVbbmFtZV0gPSBwYXJz
;ZUFoa0NvbmZpZ1RleHQoU3RyaW5nKGRhdGEudGV4dCB8fCAnJykpOwogICAgICAgIGNmZ0RpcnR5W25hbWVdID0gZmFsc2U7CiAgICAgIH0KICAgICAgaWYg
;KG5hbWUgJiYgbmFtZSA9PT0gY2ZnQWN0aXZlVGFiKSB7CiAgICAgICAgc3luY0NmZ1RpcFVpKCk7CiAgICAgICAgcmVuZGVyQ29uZmlnRWRpdG9yKCk7CiAg
;ICAgICAgaWYgKGNmZ1NlYXJjaCkgYXBwbHlDb25maWdTZWFyY2goY2ZnU2VhcmNoKTsKICAgICAgICB1cGRhdGVDZmdQYXRoQmFyKGNmZ1BhdGhzW25hbWVd
;IHx8ICcnKTsKICAgICAgfQogICAgICBpZiAoaXNTYXZlKSBzZXRDZmdTdGF0dXMobXNnIHx8ICfkv53lrZjmiJDlip8nLCAnb2snKTsKICAgICAgZWxzZSBp
;ZiAoaXNMb2FkKSBzZXRDZmdTdGF0dXMobXNnIHx8ICfliqDovb3miJDlip8nLCAnaW5mbycpOwogICAgICBlbHNlIGlmIChtc2cpIHNldENmZ1N0YXR1cyht
;c2csICdvaycpOwogICAgfSBjYXRjaCAoZSkgewogICAgICBjb25zb2xlLndhcm4oJ3NldEFoa0NvbmZpZycsIGUpOwogICAgICBzZXRDZmdTdGF0dXMoJ+in
;o+aekOWksei0pTogJyArIChlICYmIGUubWVzc2FnZSB8fCBlKSwgJ2VycicpOwogICAgfQogIH07CiAgd2luZG93Ll9fc2V0Q2ZnSWNvbiA9IChwYXlsb2Fk
;KSA9PiB7CiAgICB0cnkgewogICAgICBjb25zdCBkYXRhID0gdHlwZW9mIHBheWxvYWQgPT09ICdzdHJpbmcnID8gSlNPTi5wYXJzZShwYXlsb2FkKSA6IHBh
;eWxvYWQ7CiAgICAgIGNvbnN0IHJlcUlkID0gU3RyaW5nKGRhdGEgJiYgZGF0YS5pZCB8fCAnJyk7CiAgICAgIGNvbnN0IGtpbmQgPSBTdHJpbmcoZGF0YSAm
;JiBkYXRhLmtpbmQgfHwgJycpOwogICAgICBjb25zdCBwYXRoID0gU3RyaW5nKGRhdGEgJiYgZGF0YS5wYXRoIHx8ICcnKTsKICAgICAgY29uc3QgdXJsID0g
;U3RyaW5nKGRhdGEgJiYgZGF0YS51cmwgfHwgJycpOwogICAgICBjZmdJY29uQ2FjaGUuc2V0KGtpbmQgKyAnfCcgKyBwYXRoLCB1cmwpOwogICAgICBpZiAo
;IWNmZ0JvZHkgfHwgIXJlcUlkKSByZXR1cm47CiAgICAgIGNvbnN0IGVsID0gY2ZnQm9keS5xdWVyeVNlbGVjdG9yKCcuY2ZnLXZpY29bZGF0YS1pY29uLXJl
;cT0iJyArIHJlcUlkICsgJyJdJyk7CiAgICAgIGlmIChlbCkgc2V0Q2ZnVmljbyhlbCwga2luZCwgdXJsKTsKICAgIH0gY2F0Y2ggKGUpIHsgY29uc29sZS53
;YXJuKCdzZXRDZmdJY29uJywgZSk7IH0KICB9OwoKICAvLyDilIDilIAg5Lya6K+d6K6w5b+G77ya6aG16Z2iIC8g5pCc57Si6K+NIC8gdGFnIC8g55uY56ym
;IC8g6YWN572u562b6YCJ6aG5IOKUgOKUgAogIGNvbnN0IFNFU1NJT05fS0VZID0gJ2xvY2FsX3NlYXJjaF9zZXNzaW9uX3YxJzsKICBsZXQgc2Vzc2lvblJl
;YWR5ID0gZmFsc2U7CiAgbGV0IHNhdmVTZXNzaW9uVGltZXIgPSAwOwogIGZ1bmN0aW9uIGNhcHR1cmVTZXNzaW9uKCkgewogICAgdHJ5IHsKICAgICAgaWYg
;KGFwcE1vZGUgPT09ICdmaWxlJykgbW9kZVF1ZXJ5LmZpbGUgPSBTdHJpbmcocUVsLnZhbHVlIHx8ICcnKTsKICAgICAgZWxzZSBpZiAoYXBwTW9kZSA9PT0g
;J2hhbmRsZScpIG1vZGVRdWVyeS5oYW5kbGUgPSBTdHJpbmcocUVsLnZhbHVlIHx8ICcnKTsKICAgICAgZWxzZSBpZiAoYXBwTW9kZSA9PT0gJ2luZm8nKSBt
;b2RlUXVlcnkuaW5mbyA9IFN0cmluZyhxRWwudmFsdWUgfHwgJycpOwogICAgICBlbHNlIGlmIChhcHBNb2RlID09PSAnY29uZmlnJykgbW9kZVF1ZXJ5LmNv
;bmZpZyA9IFN0cmluZyhxRWwudmFsdWUgfHwgJycpOwogICAgfSBjYXRjaCAoXykge30KICAgIHJldHVybiB7CiAgICAgIHY6IDEsCiAgICAgIGFwcE1vZGU6
;IGFwcE1vZGUsCiAgICAgIGNhdDogY2F0LAogICAgICBkcml2ZTogZHJpdmUsCiAgICAgIHNvcnQ6IHNvcnQsCiAgICAgIHByZXZpZXdPbjogISFwcmV2aWV3
;T24sCiAgICAgIG1vZGVRdWVyeTogewogICAgICAgIGZpbGU6IFN0cmluZyhtb2RlUXVlcnkuZmlsZSB8fCAnJyksCiAgICAgICAgaGFuZGxlOiBTdHJpbmco
;bW9kZVF1ZXJ5LmhhbmRsZSB8fCAnJyksCiAgICAgICAgaW5mbzogU3RyaW5nKG1vZGVRdWVyeS5pbmZvIHx8ICcnKSwKICAgICAgICBjb25maWc6IFN0cmlu
;Zyhtb2RlUXVlcnkuY29uZmlnIHx8ICcnKQogICAgICB9LAogICAgICBjZmdBY3RpdmVUYWI6IGNmZ0FjdGl2ZVRhYiB8fCAncnVuY29uZmlnJywKICAgICAg
;Y2ZnU2VhcmNoU2NvcGU6IHsKICAgICAgICBrZXk6ICEhKGNmZ1NlYXJjaFNjb3BlICYmIGNmZ1NlYXJjaFNjb3BlLmtleSksCiAgICAgICAgdmFsdWU6ICEh
;KGNmZ1NlYXJjaFNjb3BlICYmIGNmZ1NlYXJjaFNjb3BlLnZhbHVlKSwKICAgICAgICBlbmFibGVkOiAhIShjZmdTZWFyY2hTY29wZSAmJiBjZmdTZWFyY2hT
;Y29wZS5lbmFibGVkKSwKICAgICAgICBkaXNhYmxlZDogISEoY2ZnU2VhcmNoU2NvcGUgJiYgY2ZnU2VhcmNoU2NvcGUuZGlzYWJsZWQpCiAgICAgIH0sCiAg
;ICAgIGFjdGl2ZUZpbHRlcklkczogQXJyYXkuZnJvbShhY3RpdmVGaWx0ZXJJZHMgfHwgW10pCiAgICB9OwogIH0KICBmdW5jdGlvbiBzYXZlU2Vzc2lvbk5v
;dygpIHsKICAgIGlmICghc2Vzc2lvblJlYWR5KSByZXR1cm47CiAgICB0cnkgeyBsb2NhbFN0b3JhZ2Uuc2V0SXRlbShTRVNTSU9OX0tFWSwgSlNPTi5zdHJp
;bmdpZnkoY2FwdHVyZVNlc3Npb24oKSkpOyB9IGNhdGNoIChfKSB7fQogIH0KICBmdW5jdGlvbiBzYXZlU2Vzc2lvblNvb24oKSB7CiAgICBpZiAoIXNlc3Np
;b25SZWFkeSkgcmV0dXJuOwogICAgY2xlYXJUaW1lb3V0KHNhdmVTZXNzaW9uVGltZXIpOwogICAgc2F2ZVNlc3Npb25UaW1lciA9IHNldFRpbWVvdXQoc2F2
;ZVNlc3Npb25Ob3csIDE4MCk7CiAgfQogIGZ1bmN0aW9uIHJlc3RvcmVTZXNzaW9uKCkgewogICAgbGV0IHMgPSBudWxsOwogICAgdHJ5IHsgcyA9IEpTT04u
;cGFyc2UobG9jYWxTdG9yYWdlLmdldEl0ZW0oU0VTU0lPTl9LRVkpIHx8ICdudWxsJyk7IH0gY2F0Y2ggKF8pIHsgcyA9IG51bGw7IH0KICAgIGlmICghcyB8
;fCB0eXBlb2YgcyAhPT0gJ29iamVjdCcpIHJldHVybiBmYWxzZTsKICAgIHRyeSB7CiAgICAgIGlmIChzLm1vZGVRdWVyeSAmJiB0eXBlb2Ygcy5tb2RlUXVl
;cnkgPT09ICdvYmplY3QnKSB7CiAgICAgICAgbW9kZVF1ZXJ5LmZpbGUgPSBTdHJpbmcocy5tb2RlUXVlcnkuZmlsZSB8fCAnJyk7CiAgICAgICAgbW9kZVF1
;ZXJ5LmhhbmRsZSA9IFN0cmluZyhzLm1vZGVRdWVyeS5oYW5kbGUgfHwgJycpOwogICAgICAgIG1vZGVRdWVyeS5pbmZvID0gU3RyaW5nKHMubW9kZVF1ZXJ5
;LmluZm8gfHwgJycpOwogICAgICAgIG1vZGVRdWVyeS5jb25maWcgPSBTdHJpbmcocy5tb2RlUXVlcnkuY29uZmlnIHx8ICcnKTsKICAgICAgfQogICAgICBp
;ZiAodHlwZW9mIHMuZHJpdmUgPT09ICdzdHJpbmcnKSBkcml2ZSA9IHMuZHJpdmU7CiAgICAgIGlmIChzLnNvcnQgJiYgdHlwZW9mIHMuc29ydCA9PT0gJ3N0
;cmluZycpIHsKICAgICAgICBzb3J0ID0gcy5zb3J0OwogICAgICAgIGNvbnN0IG1hcCA9IHsKICAgICAgICAgICdkYXRlLWRlc2MnOiAn5oyJ5L+u5pS55pe2
;6Ze06ZmN5bqPJywKICAgICAgICAgICdkYXRlLWFzYyc6ICfmjInkv67mlLnml7bpl7TljYfluo8nLAogICAgICAgICAgJ25hbWUtYXNjJzogJ+aMieWQjeen
;sOWNh+W6jycsCiAgICAgICAgICAnc2l6ZS1kZXNjJzogJ+aMieWkp+Wwj+mZjeW6jycKICAgICAgICB9OwogICAgICAgIGlmIChzb3J0TGFiZWwpIHNvcnRM
;YWJlbC50ZXh0Q29udGVudCA9IG1hcFtzb3J0XSB8fCBzb3J0OwogICAgICB9CiAgICAgIGlmICh0eXBlb2Ygcy5wcmV2aWV3T24gPT09ICdib29sZWFuJykg
;ewogICAgICAgIHByZXZpZXdPbiA9IHMucHJldmlld09uOwogICAgICAgIGlmIChjaGtQcmV2aWV3KSBjaGtQcmV2aWV3LmNoZWNrZWQgPSBwcmV2aWV3T247
;CiAgICAgICAgaWYgKHByZXZpZXcpIHByZXZpZXcuY2xhc3NMaXN0LnRvZ2dsZSgnb2ZmJywgIXByZXZpZXdPbik7CiAgICAgIH0KICAgICAgaWYgKHMuY2Zn
;QWN0aXZlVGFiICYmIHR5cGVvZiBzLmNmZ0FjdGl2ZVRhYiA9PT0gJ3N0cmluZycpIGNmZ0FjdGl2ZVRhYiA9IHMuY2ZnQWN0aXZlVGFiOwogICAgICBpZiAo
;cy5jZmdTZWFyY2hTY29wZSAmJiB0eXBlb2Ygcy5jZmdTZWFyY2hTY29wZSA9PT0gJ29iamVjdCcpIHsKICAgICAgICBjZmdTZWFyY2hTY29wZS5rZXkgPSAh
;IXMuY2ZnU2VhcmNoU2NvcGUua2V5OwogICAgICAgIGNmZ1NlYXJjaFNjb3BlLnZhbHVlID0gISFzLmNmZ1NlYXJjaFNjb3BlLnZhbHVlOwogICAgICAgIGNm
;Z1NlYXJjaFNjb3BlLmVuYWJsZWQgPSAhIXMuY2ZnU2VhcmNoU2NvcGUuZW5hYmxlZDsKICAgICAgICBjZmdTZWFyY2hTY29wZS5kaXNhYmxlZCA9ICEhcy5j
;ZmdTZWFyY2hTY29wZS5kaXNhYmxlZDsKICAgICAgfQogICAgICBpZiAoQXJyYXkuaXNBcnJheShzLmFjdGl2ZUZpbHRlcklkcykpIHsKICAgICAgICBhY3Rp
;dmVGaWx0ZXJJZHMgPSBuZXcgU2V0KHMuYWN0aXZlRmlsdGVySWRzLm1hcChTdHJpbmcpKTsKICAgICAgICB0cnkgeyBzYXZlQWN0aXZlRmlsdGVycygpOyB9
;IGNhdGNoIChfKSB7fQogICAgICAgIHRyeSB7IHJlbmRlckZpbHRlckJhcigpOyB9IGNhdGNoIChfKSB7fQogICAgICB9CiAgICAgIGlmIChzLmNhdCAmJiB0
;eXBlb2Ygcy5jYXQgPT09ICdzdHJpbmcnICYmIHMuY2F0LmluZGV4T2YoJ19fJykgIT09IDApIGNhdCA9IHMuY2F0OwogICAgICB0cnkgeyBzeW5jRHJpdmVC
;dXR0b24oKTsgcmVuZGVyRHJpdmVNZW51KCk7IH0gY2F0Y2ggKF8pIHt9CgogICAgICBjb25zdCBtb2RlID0gKHMuYXBwTW9kZSA9PT0gJ2hhbmRsZScgfHwg
;cy5hcHBNb2RlID09PSAnaW5mbycgfHwgcy5hcHBNb2RlID09PSAnY29uZmlnJykKICAgICAgICA/IHMuYXBwTW9kZSA6ICdmaWxlJzsKICAgICAgZG9jdW1l
;bnQucXVlcnlTZWxlY3RvckFsbCgnLmNhdCcpLmZvckVhY2goYiA9PiB7CiAgICAgICAgY29uc3QgYyA9IGIuZGF0YXNldC5jYXQ7CiAgICAgICAgbGV0IG9u
;ID0gZmFsc2U7CiAgICAgICAgaWYgKG1vZGUgPT09ICdoYW5kbGUnKSBvbiA9IGMgPT09ICdfX2hhbmRsZSc7CiAgICAgICAgZWxzZSBpZiAobW9kZSA9PT0g
;J2luZm8nKSBvbiA9IGMgPT09ICdfX2luZm8nOwogICAgICAgIGVsc2UgaWYgKG1vZGUgPT09ICdjb25maWcnKSBvbiA9IGMgPT09ICdfX2NvbmZpZyc7CiAg
;ICAgICAgZWxzZSBvbiA9IGMgPT09IGNhdDsKICAgICAgICBiLmNsYXNzTGlzdC50b2dnbGUoJ29uJywgISFvbik7CiAgICAgIH0pOwogICAgICBzZXRBcHBN
;b2RlKG1vZGUpOwogICAgICBpZiAobW9kZSA9PT0gJ2ZpbGUnKSB7CiAgICAgICAgcUVsLnZhbHVlID0gbW9kZVF1ZXJ5LmZpbGUgfHwgJyc7CiAgICAgICAg
;c3luY0NsZWFyQnRuKCk7CiAgICAgICAgZG9TZWFyY2goKTsKICAgICAgfSBlbHNlIGlmIChtb2RlID09PSAnY29uZmlnJykgewogICAgICAgIHRyeSB7IHN5
;bmNDZmdTZWFyY2hDaHJvbWUoKTsgfSBjYXRjaCAoXykge30KICAgICAgfQogICAgICByZXR1cm4gdHJ1ZTsKICAgIH0gY2F0Y2ggKGUpIHsKICAgICAgY29u
;c29sZS53YXJuKCdyZXN0b3JlU2Vzc2lvbicsIGUpOwogICAgICByZXR1cm4gZmFsc2U7CiAgICB9CiAgfQoKICByZXN0b3JlU2Vzc2lvbigpOwogIHNlc3Np
;b25SZWFkeSA9IHRydWU7CiAgc2F2ZVNlc3Npb25Ob3coKTsKICB3aW5kb3cuYWRkRXZlbnRMaXN0ZW5lcigncGFnZWhpZGUnLCBzYXZlU2Vzc2lvbk5vdyk7
;CiAgd2luZG93LmFkZEV2ZW50TGlzdGVuZXIoJ2JlZm9yZXVubG9hZCcsIHNhdmVTZXNzaW9uTm93KTsKICBkb2N1bWVudC5hZGRFdmVudExpc3RlbmVyKCd2
;aXNpYmlsaXR5Y2hhbmdlJywgKCkgPT4gewogICAgaWYgKGRvY3VtZW50LnZpc2liaWxpdHlTdGF0ZSA9PT0gJ2hpZGRlbicpIHNhdmVTZXNzaW9uTm93KCk7
;CiAgfSk7CgogIHBvc3QoJ3VpUmVhZHknKTsKICB3aW5kb3cuX19yZXN5bmNTZWFyY2ggPSAoKSA9PiB7CiAgICB0cnkgewogICAgICBpZiAodHlwZW9mIGFw
;cE1vZGUgIT09ICd1bmRlZmluZWQnICYmIGFwcE1vZGUgIT09ICdmaWxlJykgcmV0dXJuOwogICAgICBkb1NlYXJjaCgpOwogICAgfSBjYXRjaCAoXykge30K
;ICB9OwogIC8vIOi/m+WFpeaXtuiLpeW3suaciemAieS4reetm+mAie+8jOS4u+WKqOW4puadoeS7tuaQnOe0ou+8iOimhuebliBBSEsg56m65p+l6K+i77yJ
;CiAgc2V0VGltZW91dCgoKSA9PiB7IHRyeSB7IHdpbmRvdy5fX3Jlc3luY1NlYXJjaCgpOyB9IGNhdGNoIChfKSB7fSB9LCAyODApOwogIHNldFRpbWVvdXQo
;KCkgPT4geyB0cnkgeyB3aW5kb3cuX19yZXN5bmNTZWFyY2goKTsgfSBjYXRjaCAoXykge30gfSwgOTAwKTsKfSkoKTsKPC9zY3JpcHQ+CjwvYm9keT4KPC9o
;dG1sPgo=
;########################################################################################################### local_search_index.html
