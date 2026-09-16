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
    ; 已有且版本匹配才跳过；旧黄圈 / 旧闪屏逻辑要强制覆盖（HELPME 数据目录常残留旧文件）
    if FileExist(HTML_FILE) {
        try {
            if FileGetSize(HTML_FILE) > 1000 {
                ; 只读文件头，避免每次 FileRead 整页卡住灰窗
                f := FileOpen(HTML_FILE, "r", "UTF-8")
                sample := IsObject(f) ? f.Read(1200) : ""
                if IsObject(f)
                    f.Close()
                if InStr(sample, "local_search_ui:2026-03-18s") && InStr(sample, "--ring: #e42079") {
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
            if InStr(sample, "local_search_ui:2026-03-18s") && InStr(sample, "--ring: #e42079") {
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
            SetTimer(RequestFrontendSearch, -150)
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
;PCFET0NUWVBFIGh0bWw+CjxodG1sIGxhbmc9InpoLUNOIj4KPGhlYWQ+CjxtZXRhIGNoYXJzZXQ9IlVURi04Ij4KPG1ldGEgbmFtZT0idmlld3BvcnQiIGNv
;bnRlbnQ9IndpZHRoPWRldmljZS13aWR0aCwgaW5pdGlhbC1zY2FsZT0xIj4KPHRpdGxlPuS7quihqOebmDwvdGl0bGU+CjwhLS0gbG9jYWxfc2VhcmNoX3Vp
;OjIwMjYtMDMtMThzIC0tPgo8c3R5bGU+Cjpyb290IHsKICAtLWJnOiAjZjNmNGY3OwogIC0tcGFuZWw6ICNmZmZmZmY7CiAgLS1saW5lOiAjZTZlOGVlOwog
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
;b246IHVuZGVybGluZTsgfQoKLyogdGl0bGViYXIgPSDku6rooajnm5jpgqPkuIDooYzvvJvmipjlj6Dnrq3lpLTkuI7kuIvmlrnmkJzntKLmoYbliJflr7np
;vZAgKi8KI3RpdGxlYmFyIHsKICBkaXNwbGF5OiBmbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBnYXA6IDA7IGZsZXgtc2hyaW5rOiAwOwogIG1pbi1oZWln
;aHQ6IDM2cHg7IHBhZGRpbmc6IDA7IGJveC1zaXppbmc6IGJvcmRlci1ib3g7CiAgYmFja2dyb3VuZDogdmFyKC0tY2hyb21lKTsgYm9yZGVyLWJvdHRvbTog
;MXB4IHNvbGlkIHZhcigtLWxpbmUpOwogIC13ZWJraXQtYXBwLXJlZ2lvbjogZHJhZzsgYXBwLXJlZ2lvbjogZHJhZzsgdXNlci1zZWxlY3Q6IG5vbmU7Cn0K
;I3RpdGxlYmFyIC5uby1kcmFnLCAjdGl0bGViYXIgYnV0dG9uIHsKICAtd2Via2l0LWFwcC1yZWdpb246IG5vLWRyYWc7IGFwcC1yZWdpb246IG5vLWRyYWc7
;Cn0KI3RpdGxlYmFyIC50Yi1icmFuZCB7CiAgZGlzcGxheTogaW5saW5lLWZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGdhcDogOHB4OyBmbGV4LXNocmlu
;azogMDsKICB3aWR0aDogdmFyKC0tc2lkZS13KTsgcGFkZGluZzogMCAxMHB4OyBib3gtc2l6aW5nOiBib3JkZXItYm94OwogIGNvbG9yOiB2YXIoLS10eHQp
;OyBmb250LXNpemU6IDEzcHg7IGZvbnQtd2VpZ2h0OiA2NTA7IGxldHRlci1zcGFjaW5nOiAuMDFlbTsKfQojdGl0bGViYXIgLnRiLWljbyB7CiAgd2lkdGg6
;IDE2cHg7IGhlaWdodDogMTZweDsgZGlzcGxheTogYmxvY2s7IGNvbG9yOiAjMDQ3ODU3OyBmbGV4LXNocmluazogMDsKfQojdGl0bGViYXIgLnRiLXNwYWNl
;IHsgZmxleDogMTsgbWluLXdpZHRoOiA4cHg7IGFsaWduLXNlbGY6IHN0cmV0Y2g7IH0KI3RpdGxlYmFyIC50Yi13aW4gewogIGRpc3BsYXk6IGZsZXg7IGFs
;aWduLWl0ZW1zOiBzdHJldGNoOyBmbGV4LXNocmluazogMDsgaGVpZ2h0OiAzNnB4Owp9CiN0aXRsZWJhciAudGItd2luIGJ1dHRvbiB7CiAgd2lkdGg6IDQ2
;cHg7IGhlaWdodDogMTAwJTsgcGFkZGluZzogMDsgYm9yZGVyOiAwOyBiYWNrZ3JvdW5kOiB0cmFuc3BhcmVudDsKICBjb2xvcjogdmFyKC0tdHh0Mik7IGN1
;cnNvcjogcG9pbnRlcjsKICBkaXNwbGF5OiBpbmxpbmUtZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsganVzdGlmeS1jb250ZW50OiBjZW50ZXI7Cn0KI3Rp
;dGxlYmFyIC50Yi13aW4gYnV0dG9uOmhvdmVyIHsgYmFja2dyb3VuZDogI2U4ZWJmMDsgY29sb3I6IHZhcigtLXR4dCk7IH0KI3RpdGxlYmFyIC50Yi13aW4g
;I2J0bi13aW4tY2xvc2U6aG92ZXIgeyBiYWNrZ3JvdW5kOiAjZTgxMTIzOyBjb2xvcjogI2ZmZjsgfQojdGl0bGViYXIgLnRiLXdpbiBidXR0b24gc3ZnIHsg
;d2lkdGg6IDEwcHg7IGhlaWdodDogMTBweDsgZGlzcGxheTogYmxvY2s7IH0KI2ZpbHRlci1yYWlsIHsKICBkaXNwbGF5OiBmbGV4OyBhbGlnbi1pdGVtczog
;Y2VudGVyOyBnYXA6IDhweDsgZmxleC1zaHJpbms6IDE7IG1pbi13aWR0aDogMDsKICBwYWRkaW5nOiA0cHggMDsgbWFyZ2luOiAwOwp9CiNhcHAuYm9vdGlu
;ZyAjZmlsdGVyLXJhaWwsCiNhcHAuaGlkZS1maWx0ZXJzICNmaWx0ZXItcmFpbCB7IGRpc3BsYXk6IG5vbmUgIWltcG9ydGFudDsgfQojYnRuLWZpbHRlci10
;b2dnbGUgewogIGZsZXgtc2hyaW5rOiAwOyB3aWR0aDogMjJweDsgaGVpZ2h0OiAyMnB4OyBwYWRkaW5nOiAwOwogIGJvcmRlcjogMDsgYm9yZGVyLXJhZGl1
;czogNnB4OyBiYWNrZ3JvdW5kOiB0cmFuc3BhcmVudDsKICBjb2xvcjogdmFyKC0tdHh0Myk7IGN1cnNvcjogcG9pbnRlcjsKICBkaXNwbGF5OiBpbmxpbmUt
;ZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsganVzdGlmeS1jb250ZW50OiBjZW50ZXI7Cn0KI2J0bi1maWx0ZXItdG9nZ2xlOmhvdmVyIHsgYmFja2dyb3Vu
;ZDogI2VlZjFmNjsgY29sb3I6IHZhcigtLXR4dCk7IH0KI2J0bi1maWx0ZXItdG9nZ2xlLm9wZW4geyBjb2xvcjogIzA0Nzg1NzsgYmFja2dyb3VuZDogI2Vj
;ZmRmNTsgfQojYnRuLWZpbHRlci10b2dnbGUuaGFzLWFjdGl2ZSB7CiAgY29sb3I6ICNmZmY7IGJhY2tncm91bmQ6ICMxNmEzNGE7Cn0KI2J0bi1maWx0ZXIt
;dG9nZ2xlLmhhcy1hY3RpdmU6aG92ZXIgeyBiYWNrZ3JvdW5kOiAjMTU4MDNkOyBjb2xvcjogI2ZmZjsgfQojYnRuLWZpbHRlci10b2dnbGUuaGFzLWFjdGl2
;ZS5vcGVuIHsgY29sb3I6ICNmZmY7IGJhY2tncm91bmQ6ICMxNmEzNGE7IH0KI2J0bi1maWx0ZXItdG9nZ2xlIHN2ZyB7CiAgd2lkdGg6IDEycHg7IGhlaWdo
;dDogMTJweDsgZGlzcGxheTogYmxvY2s7CiAgdHJhbnNpdGlvbjogdHJhbnNmb3JtIC4xNXMgZWFzZTsKICB0cmFuc2Zvcm06IHJvdGF0ZSgtOTBkZWcpOwp9
;CiNidG4tZmlsdGVyLXRvZ2dsZS5vcGVuIHN2ZyB7IHRyYW5zZm9ybTogcm90YXRlKDBkZWcpOyB9CiNmaWx0ZXItYmFyIHsKICBkaXNwbGF5OiBub25lOyBm
;bGV4LXdyYXA6IHdyYXA7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGdhcDogNnB4OyBtaW4td2lkdGg6IDA7Cn0KI2ZpbHRlci1yYWlsLm9wZW4gI2ZpbHRlci1i
;YXIgeyBkaXNwbGF5OiBmbGV4OyB9Ci5maWx0ZXItY2hpcCB7CiAgaGVpZ2h0OiAyMnB4OyBwYWRkaW5nOiAwIDEwcHg7IGJvcmRlcjogMXB4IHNvbGlkIHZh
;cigtLWxpbmUpOwogIGJvcmRlci1yYWRpdXM6IDk5OXB4OyBiYWNrZ3JvdW5kOiAjZmJmYmZkOyBjb2xvcjogdmFyKC0tdHh0Mik7CiAgZm9udC1zaXplOiAx
;MnB4OyBjdXJzb3I6IHBvaW50ZXI7IGxpbmUtaGVpZ2h0OiAyMHB4OyB3aGl0ZS1zcGFjZTogbm93cmFwOwp9Ci5maWx0ZXItY2hpcDpob3ZlciB7IGJhY2tn
;cm91bmQ6ICNlZWYxZjY7IGNvbG9yOiB2YXIoLS10eHQpOyB9Ci5maWx0ZXItY2hpcC5vbiB7CiAgYmFja2dyb3VuZDogI2VjZmRmNTsgYm9yZGVyLWNvbG9y
;OiAjODZlZmFjOyBjb2xvcjogIzA0Nzg1NzsgZm9udC13ZWlnaHQ6IDYwMDsKfQoKLyogY2hyb21lICovCiNjaHJvbWUgeyBkaXNwbGF5OiBmbGV4OyBmbGV4
;LWRpcmVjdGlvbjogY29sdW1uOyBmbGV4OiAxOyBtaW4taGVpZ2h0OiAwOyB9CiNjaHJvbWUuaGlkZGVuIHsgZGlzcGxheTogbm9uZTsgfQojdG9wIHsKICBo
;ZWlnaHQ6IDQ4cHg7IGRpc3BsYXk6IGdyaWQ7CiAgZ3JpZC10ZW1wbGF0ZS1jb2x1bW5zOiB2YXIoLS1zaWRlLXcpIG1pbm1heCgwLCAxZnIpOwogIGFsaWdu
;LWl0ZW1zOiBzdHJldGNoOyBwYWRkaW5nOiAwIDEwcHggMCAwOyBiYWNrZ3JvdW5kOiB2YXIoLS1jaHJvbWUpOwogIGJvcmRlci1ib3R0b206IDA7IGJveC1z
;aXppbmc6IGJvcmRlci1ib3g7CiAgLXdlYmtpdC1hcHAtcmVnaW9uOiBkcmFnOyBhcHAtcmVnaW9uOiBkcmFnOwp9CiN0b3AgLm5vLWRyYWcsICN0b3AgYnV0
;dG9uLCAjdG9wIGlucHV0IHsKICAtd2Via2l0LWFwcC1yZWdpb246IG5vLWRyYWc7IGFwcC1yZWdpb246IG5vLWRyYWc7Cn0KI2RyaXZlLXdyYXAgewogIHBv
;c2l0aW9uOiByZWxhdGl2ZTsgd2lkdGg6IDEwMCU7CiAgYm9yZGVyLXJpZ2h0OiAwOyBiYWNrZ3JvdW5kOiB2YXIoLS1jaHJvbWUpOwogIGRpc3BsYXk6IGZs
;ZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7Cn0KI2J0bi1kcml2ZSB7CiAgZGlzcGxheTogZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsgZ2FwOiA4cHg7CiAg
;d2lkdGg6IDEwMCU7IGhlaWdodDogMTAwJTsgcGFkZGluZzogMCAxMHB4OwogIGJvcmRlcjogMDsgYm9yZGVyLXJhZGl1czogMDsgYmFja2dyb3VuZDogdHJh
;bnNwYXJlbnQ7CiAgY29sb3I6IHZhcigtLXR4dCk7IGZvbnQtc2l6ZTogMTMuNXB4OyBmb250LXdlaWdodDogNjAwOwogIGN1cnNvcjogcG9pbnRlcjsgdGV4
;dC1hbGlnbjogbGVmdDsKfQojYnRuLWRyaXZlOmhvdmVyIHsgYmFja2dyb3VuZDogI2VlZjFmNjsgY29sb3I6IHZhcigtLWFjYzIpOyB9CiNidG4tZHJpdmUg
;LmRyaXZlLWljbyB7CiAgd2lkdGg6IDIwcHg7IGhlaWdodDogMjBweDsgb2JqZWN0LWZpdDogY29udGFpbjsgZmxleC1zaHJpbms6IDA7CiAgYmFja2dyb3Vu
;ZDogdHJhbnNwYXJlbnQ7Cn0KI2J0bi1kcml2ZSAuZHJpdmUtaWNvLmhpZGRlbiB7IGRpc3BsYXk6IG5vbmU7IH0KI2J0bi1kcml2ZSAuY2FyZXQgeyBmb250
;LXNpemU6IDEwcHg7IGNvbG9yOiB2YXIoLS10eHQzKTsgbWFyZ2luLWxlZnQ6IGF1dG87IH0KI2RyaXZlLWxhYmVsIHsgb3ZlcmZsb3c6IGhpZGRlbjsgdGV4
;dC1vdmVyZmxvdzogZWxsaXBzaXM7IHdoaXRlLXNwYWNlOiBub3dyYXA7IH0KI2RyaXZlLW1lbnUgewogIGRpc3BsYXk6IG5vbmU7IHBvc2l0aW9uOiBhYnNv
;bHV0ZTsgdG9wOiAxMDAlOyBsZWZ0OiAwOyByaWdodDogMDsgei1pbmRleDogNDA7CiAgd2lkdGg6IDEwMCU7IG1heC1oZWlnaHQ6IDMyMHB4OyBvdmVyZmxv
;dzogYXV0bzsKICBiYWNrZ3JvdW5kOiAjZmZmOyBib3JkZXI6IDFweCBzb2xpZCB2YXIoLS1saW5lKTsgYm9yZGVyLXRvcDogMDsKICBib3gtc2hhZG93OiB2
;YXIoLS1zaGFkb3cpOyBwYWRkaW5nOiA0cHg7IGJvcmRlci1yYWRpdXM6IDAgMCA4cHggOHB4Owp9CiNkcml2ZS1tZW51Lm9uIHsgZGlzcGxheTogYmxvY2s7
;IH0KI2RyaXZlLW1lbnUgYnV0dG9uIHsKICBkaXNwbGF5OiBmbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBnYXA6IDhweDsgd2lkdGg6IDEwMCU7CiAgdGV4
;dC1hbGlnbjogbGVmdDsgYm9yZGVyOiAwOyBiYWNrZ3JvdW5kOiB0cmFuc3BhcmVudDsKICBwYWRkaW5nOiA4cHggMTBweDsgYm9yZGVyLXJhZGl1czogNnB4
;OyBjdXJzb3I6IHBvaW50ZXI7IGNvbG9yOiB2YXIoLS10eHQpOyBmb250LXNpemU6IDEzcHg7Cn0KI2RyaXZlLW1lbnUgYnV0dG9uIGltZyB7CiAgd2lkdGg6
;IDIwcHg7IGhlaWdodDogMjBweDsgb2JqZWN0LWZpdDogY29udGFpbjsgZmxleC1zaHJpbms6IDA7IGJhY2tncm91bmQ6IHRyYW5zcGFyZW50Owp9CiNkcml2
;ZS1tZW51IGJ1dHRvbjpob3ZlciB7IGJhY2tncm91bmQ6ICNlZWYyZmY7IH0KI2RyaXZlLW1lbnUgYnV0dG9uLm9uIHsgYmFja2dyb3VuZDogI2VmZjZmZjsg
;Y29sb3I6IHZhcigtLWFjYzIpOyBmb250LXdlaWdodDogNjAwOyB9CiN0b3AtcmVzdCB7CiAgZGlzcGxheTogZ3JpZDsKICBncmlkLXRlbXBsYXRlLWNvbHVt
;bnM6IG1pbm1heCgyODBweCwgMS4xZnIpIG1pbm1heCgzMjBweCwgMS4yZnIpOwogIGFsaWduLWl0ZW1zOiBzdHJldGNoOyBtaW4td2lkdGg6IDA7IG1pbi1o
;ZWlnaHQ6IDA7CiAgYmFja2dyb3VuZDogdmFyKC0tY2hyb21lKTsKfQojdG9wLm1vZGUtdG9vbCAjdG9wLXJlc3QgewogIGdyaWQtdGVtcGxhdGUtY29sdW1u
;czogMWZyOwp9Ci8qIOWFs+iBlOWPpeafhO+8muS7heaQnOe0ouahhuWNoOS4gOWNiu+8jOWIl+ihqOS7jeWFqOWuvSAqLwojdG9wLm1vZGUtaGFuZGxlICN0
;b3AtcmVzdCB7CiAgZ3JpZC10ZW1wbGF0ZS1jb2x1bW5zOiBtaW5tYXgoMjgwcHgsIDUwJSk7CiAganVzdGlmeS1jb250ZW50OiBzdGFydDsKfQojc2VhcmNo
;LXdyYXAgewogIGRpc3BsYXk6IGZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IG1pbi13aWR0aDogMDsgaGVpZ2h0OiAxMDAlOwogIHBhZGRpbmc6IDA7IGJv
;cmRlci1yaWdodDogMDsgYmFja2dyb3VuZDogdmFyKC0tY2hyb21lKTsKfQojZmlsdGVyLXNldHRpbmdzIHsKICBkaXNwbGF5OiBub25lOyBwb3NpdGlvbjog
;Zml4ZWQ7IGluc2V0OiAwOyB6LWluZGV4OiAzMDA7CiAgYmFja2dyb3VuZDogcmdiYSgxNSwgMjMsIDQyLCAuMjgpOyBhbGlnbi1pdGVtczogY2VudGVyOyBq
;dXN0aWZ5LWNvbnRlbnQ6IGNlbnRlcjsKfQojZmlsdGVyLXNldHRpbmdzLm9uIHsgZGlzcGxheTogZmxleDsgfQojZmlsdGVyLXNldHRpbmdzIC5mcy1jYXJk
;IHsKICB3aWR0aDogbWluKDQ2MHB4LCA5MnZ3KTsgbWF4LWhlaWdodDogbWluKDYyMHB4LCA4OHZoKTsKICBiYWNrZ3JvdW5kOiAjZmZmOyBib3JkZXItcmFk
;aXVzOiAxNHB4OyBib3JkZXI6IDFweCBzb2xpZCB2YXIoLS1saW5lKTsKICBib3gtc2hhZG93OiAwIDE4cHggNDBweCByZ2JhKDE1LCAyMywgNDIsIC4xOCk7
;CiAgZGlzcGxheTogZmxleDsgZmxleC1kaXJlY3Rpb246IGNvbHVtbjsgb3ZlcmZsb3c6IGhpZGRlbjsKfQojZmlsdGVyLXNldHRpbmdzIC5mcy1oZCB7CiAg
;ZGlzcGxheTogZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsganVzdGlmeS1jb250ZW50OiBzcGFjZS1iZXR3ZWVuOwogIHBhZGRpbmc6IDE0cHggMTZweDsg
;Ym9yZGVyLWJvdHRvbTogMXB4IHNvbGlkIHZhcigtLWxpbmUpOyBmb250LXdlaWdodDogNjAwOwp9CiNmaWx0ZXItc2V0dGluZ3MgLmZzLWhkIGJ1dHRvbiB7
;CiAgYm9yZGVyOiAwOyBiYWNrZ3JvdW5kOiB0cmFuc3BhcmVudDsgY29sb3I6IHZhcigtLXR4dDIpOyBjdXJzb3I6IHBvaW50ZXI7IGZvbnQtc2l6ZTogMThw
;eDsgbGluZS1oZWlnaHQ6IDE7Cn0KI2ZpbHRlci1zZXR0aW5ncyAuZnMtYmQgewogIHBhZGRpbmc6IDE0cHggMTZweDsgb3ZlcmZsb3c6IGF1dG87IGRpc3Bs
;YXk6IGZsZXg7IGZsZXgtZGlyZWN0aW9uOiBjb2x1bW47IGdhcDogMTJweDsKfQojZmlsdGVyLXNldHRpbmdzIC5mcy1oaW50IHsgZm9udC1zaXplOiAxMnB4
;OyBjb2xvcjogdmFyKC0tdHh0Myk7IGxpbmUtaGVpZ2h0OiAxLjU7IH0KI2ZpbHRlci1zZXR0aW5ncyAuZnMtbGlzdCB7IGRpc3BsYXk6IGZsZXg7IGZsZXgt
;ZGlyZWN0aW9uOiBjb2x1bW47IGdhcDogMTBweDsgfQojZmlsdGVyLXNldHRpbmdzIC5mcy1ibG9jayB7CiAgcG9zaXRpb246IHJlbGF0aXZlOyBkaXNwbGF5
;OiBncmlkOwogIGdyaWQtdGVtcGxhdGUtY29sdW1uczogMjhweCBtaW5tYXgoMCwgMWZyKSBhdXRvOwogIGdhcDogOHB4IDEwcHg7IGFsaWduLWl0ZW1zOiBz
;dGFydDsKICBwYWRkaW5nOiAxNHB4IDM2cHggMTJweCAxMnB4OwogIGJvcmRlcjogMXB4IHNvbGlkICNkN2RkZTg7IGJvcmRlci1yYWRpdXM6IDEycHg7CiAg
;YmFja2dyb3VuZDogbGluZWFyLWdyYWRpZW50KDE4MGRlZywgI2ZmZmZmZiAwJSwgI2Y3ZjlmYyAxMDAlKTsKICBib3gtc2hhZG93OiAwIDFweCAwIHJnYmEo
;MjU1LDI1NSwyNTUsLjkpIGluc2V0LCAwIDRweCAxMnB4IHJnYmEoMTUsIDIzLCA0MiwgLjA1KTsKICBib3JkZXItbGVmdDogM3B4IHNvbGlkICM4NmVmYWM7
;Cn0KI2ZpbHRlci1zZXR0aW5ncyAuZnMtYmxvY2sub2ZmIHsKICBvcGFjaXR5OiAuNjI7IGJvcmRlci1sZWZ0LWNvbG9yOiAjY2JkNWUxOwogIGJhY2tncm91
;bmQ6IGxpbmVhci1ncmFkaWVudCgxODBkZWcsICNmOGZhZmMgMCUsICNmMWY1ZjkgMTAwJSk7Cn0KI2ZpbHRlci1zZXR0aW5ncyAuZnMtYmxvY2sgLmZzLWRl
;bCB7CiAgcG9zaXRpb246IGFic29sdXRlOyB0b3A6IDhweDsgcmlnaHQ6IDhweDsKICB3aWR0aDogMjJweDsgaGVpZ2h0OiAyMnB4OyBwYWRkaW5nOiAwOyBi
;b3JkZXI6IDA7IGJvcmRlci1yYWRpdXM6IDZweDsKICBiYWNrZ3JvdW5kOiB0cmFuc3BhcmVudDsgY29sb3I6IHZhcigtLXR4dDMpOyBjdXJzb3I6IHBvaW50
;ZXI7CiAgZGlzcGxheTogaW5saW5lLWZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGp1c3RpZnktY29udGVudDogY2VudGVyOwp9CiNmaWx0ZXItc2V0dGlu
;Z3MgLmZzLWJsb2NrIC5mcy1kZWw6aG92ZXIgeyBiYWNrZ3JvdW5kOiAjZmVlMmUyOyBjb2xvcjogI2I5MWMxYzsgfQojZmlsdGVyLXNldHRpbmdzIC5mcy1i
;bG9jayAuZnMtZGVsIHN2ZyB7IHdpZHRoOiAxMnB4OyBoZWlnaHQ6IDEycHg7IGRpc3BsYXk6IGJsb2NrOyB9CiNmaWx0ZXItc2V0dGluZ3MgLmZzLW9yZCB7
;CiAgZGlzcGxheTogZmxleDsgZmxleC1kaXJlY3Rpb246IGNvbHVtbjsgZ2FwOiAycHg7IHBhZGRpbmctdG9wOiAycHg7Cn0KI2ZpbHRlci1zZXR0aW5ncyAu
;ZnMtb3JkIGJ1dHRvbiB7CiAgd2lkdGg6IDI0cHg7IGhlaWdodDogMjBweDsgcGFkZGluZzogMDsgYm9yZGVyOiAwOyBib3JkZXItcmFkaXVzOiA1cHg7CiAg
;YmFja2dyb3VuZDogI2VlZjJmNzsgY29sb3I6IHZhcigtLXR4dDIpOyBjdXJzb3I6IHBvaW50ZXI7CiAgZGlzcGxheTogaW5saW5lLWZsZXg7IGFsaWduLWl0
;ZW1zOiBjZW50ZXI7IGp1c3RpZnktY29udGVudDogY2VudGVyOwp9CiNmaWx0ZXItc2V0dGluZ3MgLmZzLW9yZCBidXR0b246aG92ZXIgeyBiYWNrZ3JvdW5k
;OiAjZTJlOGYwOyBjb2xvcjogdmFyKC0tdHh0KTsgfQojZmlsdGVyLXNldHRpbmdzIC5mcy1vcmQgYnV0dG9uOmRpc2FibGVkIHsgb3BhY2l0eTogLjI4OyBj
;dXJzb3I6IGRlZmF1bHQ7IH0KI2ZpbHRlci1zZXR0aW5ncyAuZnMtb3JkIGJ1dHRvbiBzdmcgeyB3aWR0aDogMTFweDsgaGVpZ2h0OiAxMXB4OyBkaXNwbGF5
;OiBibG9jazsgfQojZmlsdGVyLXNldHRpbmdzIC5mcy1tYWluIHsgbWluLXdpZHRoOiAwOyBkaXNwbGF5OiBmbGV4OyBmbGV4LWRpcmVjdGlvbjogY29sdW1u
;OyBnYXA6IDRweDsgfQojZmlsdGVyLXNldHRpbmdzIC5mcy10aXRsZS1yb3cgewogIGRpc3BsYXk6IGZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGdhcDog
;OHB4OyBtaW4td2lkdGg6IDA7Cn0KI2ZpbHRlci1zZXR0aW5ncyAuZnMtdGl0bGUgewogIGZvbnQtc2l6ZTogMTMuNXB4OyBmb250LXdlaWdodDogNzAwOyBj
;b2xvcjogdmFyKC0tdHh0KTsKICBvdmVyZmxvdzogaGlkZGVuOyB0ZXh0LW92ZXJmbG93OiBlbGxpcHNpczsgd2hpdGUtc3BhY2U6IG5vd3JhcDsKfQojZmls
;dGVyLXNldHRpbmdzIC5mcy10YWcgewogIGZsZXgtc2hyaW5rOiAwOyBmb250LXNpemU6IDEwcHg7IGZvbnQtd2VpZ2h0OiA2MDA7IGxpbmUtaGVpZ2h0OiAx
;OwogIHBhZGRpbmc6IDNweCA2cHg7IGJvcmRlci1yYWRpdXM6IDk5OXB4OwogIGJhY2tncm91bmQ6ICNlY2ZkZjU7IGNvbG9yOiAjMDQ3ODU3OyBib3JkZXI6
;IDFweCBzb2xpZCAjYTdmM2QwOwp9CiNmaWx0ZXItc2V0dGluZ3MgLmZzLWJsb2NrLm9mZiAuZnMtdGFnIHsKICBiYWNrZ3JvdW5kOiAjZjFmNWY5OyBjb2xv
;cjogIzY0NzQ4YjsgYm9yZGVyLWNvbG9yOiAjZTJlOGYwOwp9CiNmaWx0ZXItc2V0dGluZ3MgLmZzLXJlZ2V4IHsKICBmb250LXNpemU6IDExcHg7IGNvbG9y
;OiB2YXIoLS10eHQzKTsgbGluZS1oZWlnaHQ6IDEuMzU7CiAgd29yZC1icmVhazogYnJlYWstYWxsOyBmb250LWZhbWlseTogQ29uc29sYXMsICJDYXNjYWRp
;YSBNb25vIiwgbW9ub3NwYWNlOwp9CiNmaWx0ZXItc2V0dGluZ3MgLmZzLWVuIHsKICBkaXNwbGF5OiBmbGV4OyBmbGV4LWRpcmVjdGlvbjogY29sdW1uOyBh
;bGlnbi1pdGVtczogZmxleC1lbmQ7IGdhcDogNHB4OwogIHBhZGRpbmctdG9wOiAycHg7IHBhZGRpbmctcmlnaHQ6IDRweDsKfQojZmlsdGVyLXNldHRpbmdz
;IC5mcy1lbiAuZnMtZW4tbGFiIHsKICBmb250LXNpemU6IDEwcHg7IGNvbG9yOiB2YXIoLS10eHQzKTsgbGluZS1oZWlnaHQ6IDE7IHdoaXRlLXNwYWNlOiBu
;b3dyYXA7Cn0KI2ZpbHRlci1zZXR0aW5ncyAuZnMtc3dpdGNoIHsKICBwb3NpdGlvbjogcmVsYXRpdmU7IHdpZHRoOiAzNnB4OyBoZWlnaHQ6IDIwcHg7IGZs
;ZXgtc2hyaW5rOiAwOwogIGJvcmRlcjogMDsgYm9yZGVyLXJhZGl1czogOTk5cHg7IGJhY2tncm91bmQ6ICNjYmQ1ZTE7IGN1cnNvcjogcG9pbnRlcjsgcGFk
;ZGluZzogMDsKfQojZmlsdGVyLXNldHRpbmdzIC5mcy1zd2l0Y2gub24geyBiYWNrZ3JvdW5kOiAjMzRkMzk5OyB9CiNmaWx0ZXItc2V0dGluZ3MgLmZzLXN3
;aXRjaCBpIHsKICBwb3NpdGlvbjogYWJzb2x1dGU7IHRvcDogMnB4OyBsZWZ0OiAycHg7IHdpZHRoOiAxNnB4OyBoZWlnaHQ6IDE2cHg7CiAgYm9yZGVyLXJh
;ZGl1czogNTAlOyBiYWNrZ3JvdW5kOiAjZmZmOyBib3gtc2hhZG93OiAwIDFweCAzcHggcmdiYSgxNSwyMyw0MiwuMik7CiAgdHJhbnNpdGlvbjogdHJhbnNm
;b3JtIC4xNXMgZWFzZTsgcG9pbnRlci1ldmVudHM6IG5vbmU7Cn0KI2ZpbHRlci1zZXR0aW5ncyAuZnMtc3dpdGNoLm9uIGkgeyB0cmFuc2Zvcm06IHRyYW5z
;bGF0ZVgoMTZweCk7IH0KI2ZpbHRlci1zZXR0aW5ncyAuZnMtZm9ybSB7CiAgZGlzcGxheTogZ3JpZDsgZ2FwOiA4cHg7IHBhZGRpbmc6IDEycHg7IGJvcmRl
;ci1yYWRpdXM6IDEycHg7CiAgYm9yZGVyOiAxcHggZGFzaGVkICNjNWNlZGQ7IGJhY2tncm91bmQ6ICNmYWZiZmQ7Cn0KI2ZpbHRlci1zZXR0aW5ncyBsYWJl
;bCB7IGZvbnQtc2l6ZTogMTJweDsgY29sb3I6IHZhcigtLXR4dDIpOyB9CiNmaWx0ZXItc2V0dGluZ3MgaW5wdXQgewogIHdpZHRoOiAxMDAlOyBoZWlnaHQ6
;IDM0cHg7IGJvcmRlcjogMXB4IHNvbGlkIHZhcigtLWxpbmUpOyBib3JkZXItcmFkaXVzOiA4cHg7CiAgcGFkZGluZzogMCAxMHB4OyBmb250LXNpemU6IDEz
;cHg7IGJveC1zaXppbmc6IGJvcmRlci1ib3g7IG91dGxpbmU6IG5vbmU7Cn0KI2ZpbHRlci1zZXR0aW5ncyBpbnB1dDpmb2N1cyB7IGJvcmRlci1jb2xvcjog
;IzkzYzVmZDsgYm94LXNoYWRvdzogMCAwIDAgM3B4IHJnYmEoNTksMTMwLDI0NiwuMTIpOyB9CiNmaWx0ZXItc2V0dGluZ3MgLmZzLWFjdGlvbnMgeyBkaXNw
;bGF5OiBmbGV4OyBnYXA6IDhweDsganVzdGlmeS1jb250ZW50OiBmbGV4LWVuZDsgbWFyZ2luLXRvcDogNHB4OyB9CiNmaWx0ZXItc2V0dGluZ3MgLmZzLWFj
;dGlvbnMgYnV0dG9uIHsKICBoZWlnaHQ6IDMycHg7IHBhZGRpbmc6IDAgMTRweDsgYm9yZGVyLXJhZGl1czogOHB4OyBib3JkZXI6IDFweCBzb2xpZCB2YXIo
;LS1saW5lKTsKICBiYWNrZ3JvdW5kOiAjZmZmOyBjdXJzb3I6IHBvaW50ZXI7IGZvbnQtc2l6ZTogMTNweDsKfQojZmlsdGVyLXNldHRpbmdzIC5mcy1hY3Rp
;b25zIC5wcmltYXJ5IHsKICBiYWNrZ3JvdW5kOiB2YXIoLS1hY2MpOyBib3JkZXItY29sb3I6IHZhcigtLWFjYyk7IGNvbG9yOiAjZmZmOwp9CiNmaWx0ZXIt
;c2V0dGluZ3MgLmZzLWFjdGlvbnMgLnByaW1hcnk6aG92ZXIgeyBiYWNrZ3JvdW5kOiB2YXIoLS1hY2MyKTsgfQojZmlsdGVyLXNldHRpbmdzIC5mcy1mb290
;IHsKICBkaXNwbGF5OiBmbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBqdXN0aWZ5LWNvbnRlbnQ6IHNwYWNlLWJldHdlZW47IGdhcDogMTJweDsKICBwYWRk
;aW5nOiAxMHB4IDE2cHggMTRweDsgYm9yZGVyLXRvcDogMXB4IHNvbGlkIHZhcigtLWxpbmUpOwp9CiNmaWx0ZXItc2V0dGluZ3MgLmZzLWZvb3QgYnV0dG9u
;IHsKICBib3JkZXI6IDA7IGJhY2tncm91bmQ6IHRyYW5zcGFyZW50OyBjb2xvcjogdmFyKC0tYWNjMik7IGN1cnNvcjogcG9pbnRlcjsgZm9udC1zaXplOiAx
;MnB4OyBwYWRkaW5nOiAwOwp9CiNmaWx0ZXItc2V0dGluZ3MgLmZzLWZvb3QgI2ZzLXJlc2V0IHsKICBjb2xvcjogdmFyKC0tdHh0Mik7Cn0KI2ZpbHRlci1z
;ZXR0aW5ncyAuZnMtZm9vdCAjZnMtcmVzZXQ6aG92ZXIgeyBjb2xvcjogI2I5MWMxYzsgfQojdG9wLm1vZGUtdG9vbCAjc2VhcmNoLXdyYXAgeyBwYWRkaW5n
;LXJpZ2h0OiAwOyB9CiN0b3AubW9kZS10b29sICN0b3AtcHJldmlldyB7IGRpc3BsYXk6IG5vbmU7IH0KI3RvcC5tb2RlLWhhbmRsZSAjdG9wLXByZXZpZXcg
;eyBkaXNwbGF5OiBub25lOyB9CiN0b3AubW9kZS1pbmZvICNzZWFyY2gtd3JhcCB7IGRpc3BsYXk6IG5vbmUgIWltcG9ydGFudDsgfQojdG9wLm1vZGUtaW5m
;byAjdG9wLXByZXZpZXcgeyBkaXNwbGF5OiBub25lOyB9CiN0b3AubW9kZS1pbmZvICN0b3AtcmVzdCB7IGdyaWQtdGVtcGxhdGUtY29sdW1uczogMWZyOyBt
;aW4taGVpZ2h0OiAwOyB9CiNzZWFyY2gtYm94IHsKICBwb3NpdGlvbjogcmVsYXRpdmU7IGRpc3BsYXk6IGZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGdh
;cDogNHB4OwogIHdpZHRoOiAxMDAlOyBoZWlnaHQ6IDM0cHg7CiAgYm9yZGVyOiAxcHggc29saWQgdmFyKC0tbGluZSk7IGJvcmRlci1yYWRpdXM6IDhweDsK
;ICBwYWRkaW5nOiAwIDRweCAwIDEwcHg7IGJhY2tncm91bmQ6ICNmYmZiZmQ7IG92ZXJmbG93OiB2aXNpYmxlOwp9CiNzZWFyY2gtYm94OmZvY3VzLXdpdGhp
;biB7CiAgYm9yZGVyLWNvbG9yOiAjOTNjNWZkOwogIGJveC1zaGFkb3c6IDAgMCAwIDNweCByZ2JhKDU5LDEzMCwyNDYsLjE1KTsKICBiYWNrZ3JvdW5kOiAj
;ZmZmOwp9CiNxIHsKICBmbGV4OiAxOyBtaW4td2lkdGg6IDA7IGhlaWdodDogMTAwJTsKICBib3JkZXI6IDA7IGJvcmRlci1yYWRpdXM6IDA7IHBhZGRpbmc6
;IDA7IG91dGxpbmU6IG5vbmU7IGJhY2tncm91bmQ6IHRyYW5zcGFyZW50OwogIGZvbnQtc2l6ZTogMTMuNXB4OyBjb2xvcjogdmFyKC0tdHh0KTsKfQojcTo6
;cGxhY2Vob2xkZXIgeyBjb2xvcjogdmFyKC0tdHh0Myk7IH0KI2J0bi1jbGVhciB7CiAgZGlzcGxheTogbm9uZTsgZmxleC1zaHJpbms6IDA7IGhlaWdodDog
;MjJweDsgcGFkZGluZzogMCAxMHB4OwogIGJvcmRlcjogMDsgYm9yZGVyLXJhZGl1czogOTk5cHg7IGJhY2tncm91bmQ6ICNlZWYxZjY7CiAgY29sb3I6IHZh
;cigtLXR4dDIpOyBmb250LXNpemU6IDEycHg7IGN1cnNvcjogcG9pbnRlcjsgbGluZS1oZWlnaHQ6IDIycHg7Cn0KI2J0bi1jbGVhci5vbiB7IGRpc3BsYXk6
;IGlubGluZS1mbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBqdXN0aWZ5LWNvbnRlbnQ6IGNlbnRlcjsgfQojYnRuLWNsZWFyOmhvdmVyIHsgYmFja2dyb3Vu
;ZDogI2UyZThmMDsgY29sb3I6IHZhcigtLXR4dCk7IH0KI2J0bi1oaXN0IHsKICBmbGV4LXNocmluazogMDsgd2lkdGg6IDI0cHg7IGhlaWdodDogMjRweDsg
;Ym9yZGVyOiAwOyBib3JkZXItcmFkaXVzOiA2cHg7CiAgYmFja2dyb3VuZDogdHJhbnNwYXJlbnQ7IGNvbG9yOiB2YXIoLS10eHQzKTsgZm9udC1zaXplOiAx
;MHB4OwogIGN1cnNvcjogcG9pbnRlcjsgbGluZS1oZWlnaHQ6IDE7IHBhZGRpbmc6IDA7Cn0KI2J0bi1oaXN0OmhvdmVyLCAjYnRuLWhpc3Qub24geyBiYWNr
;Z3JvdW5kOiAjZWVmMmZmOyBjb2xvcjogdmFyKC0tYWNjMik7IH0KI2hpc3QtbWVudSB7CiAgZGlzcGxheTogbm9uZTsgcG9zaXRpb246IGFic29sdXRlOyB0
;b3A6IDEwMCU7IGxlZnQ6IC0xcHg7IHJpZ2h0OiAtMXB4OyB6LWluZGV4OiA0NTsKICBtYXgtaGVpZ2h0OiAyODBweDsgb3ZlcmZsb3c6IGF1dG87CiAgYmFj
;a2dyb3VuZDogI2ZmZjsgYm9yZGVyOiAxcHggc29saWQgdmFyKC0tbGluZSk7IGJvcmRlci10b3A6IDA7CiAgYm94LXNoYWRvdzogMCA4cHggMThweCByZ2Jh
;KDE1LCAyMywgNDIsIC4wOCk7IHBhZGRpbmc6IDJweCA0cHggNHB4OwogIGJvcmRlci1yYWRpdXM6IDAgMCA4cHggOHB4Owp9CiNoaXN0LW1lbnUub24geyBk
;aXNwbGF5OiBibG9jazsgfQojc2VhcmNoLWJveC5oaXN0LW9wZW4gewogIGJvcmRlci1ib3R0b20tbGVmdC1yYWRpdXM6IDA7IGJvcmRlci1ib3R0b20tcmln
;aHQtcmFkaXVzOiAwOwp9CiNoaXN0LW1lbnUgYnV0dG9uIHsKICBkaXNwbGF5OiBibG9jazsgd2lkdGg6IDEwMCU7IHRleHQtYWxpZ246IGxlZnQ7IGJvcmRl
;cjogMDsgYmFja2dyb3VuZDogdHJhbnNwYXJlbnQ7CiAgcGFkZGluZzogOHB4IDEwcHg7IGJvcmRlci1yYWRpdXM6IDZweDsgY3Vyc29yOiBwb2ludGVyOyBj
;b2xvcjogdmFyKC0tdHh0KTsKICBmb250LXNpemU6IDEzcHg7IG92ZXJmbG93OiBoaWRkZW47IHRleHQtb3ZlcmZsb3c6IGVsbGlwc2lzOyB3aGl0ZS1zcGFj
;ZTogbm93cmFwOwp9CiNoaXN0LW1lbnUgYnV0dG9uOmhvdmVyIHsgYmFja2dyb3VuZDogI2YzZjRmNjsgfQojaGlzdC1tZW51IC5oaXN0LWVtcHR5IHsKICBw
;YWRkaW5nOiAxMHB4OyBjb2xvcjogdmFyKC0tdHh0Myk7IGZvbnQtc2l6ZTogMTJweDsgdGV4dC1hbGlnbjogY2VudGVyOwp9CiN0b3AtcHJldmlldyB7CiAg
;ZGlzcGxheTogZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsgZ2FwOiAxMHB4OyBtaW4td2lkdGg6IDA7IHBhZGRpbmc6IDAgMTJweDsKICBiYWNrZ3JvdW5k
;OiB2YXIoLS1jaHJvbWUpOyBjb2xvcjogdmFyKC0tdHh0Mik7IGZvbnQtc2l6ZTogMTJweDsgb3ZlcmZsb3c6IGhpZGRlbjsKfQojdG9wLXByZXZpZXcgLnB2
;LW1ldGEgewogIGJvcmRlcjogMDsgcGFkZGluZzogMDsgZmxleDogMTsgbWluLXdpZHRoOiAwOwogIGZsZXgtd3JhcDogbm93cmFwOyBvdmVyZmxvdzogaGlk
;ZGVuOwp9CiNidG4tZ290by1wcm9jIHsKICBmbGV4LXNocmluazogMDsgaGVpZ2h0OiAzMHB4OyBwYWRkaW5nOiAwIDEycHg7CiAgYm9yZGVyOiAwOyBib3Jk
;ZXItcmFkaXVzOiA5OTlweDsgY3Vyc29yOiBwb2ludGVyOwogIGJhY2tncm91bmQ6ICNlOGYxZmY7IGNvbG9yOiAjMWQ0ZWQ4OyBmb250LXNpemU6IDEyLjVw
;eDsgZm9udC13ZWlnaHQ6IDYwMDsKfQojYnRuLWdvdG8tcHJvYzpob3ZlciB7IGJhY2tncm91bmQ6ICNkYmVhZmU7IH0KCiN2aWV3LXNlYXJjaCB7IGRpc3Bs
;YXk6IGZsZXg7IGZsZXgtZGlyZWN0aW9uOiBjb2x1bW47IGZsZXg6IDE7IG1pbi1oZWlnaHQ6IDA7IH0KI3ZpZXctc2VhcmNoLmhpZGRlbiB7IGRpc3BsYXk6
;IG5vbmU7IH0KI3ZpZXctcHJvYyB7CiAgZGlzcGxheTogbm9uZTsgZmxleC1kaXJlY3Rpb246IGNvbHVtbjsgZmxleDogMTsgbWluLWhlaWdodDogMDsKICBi
;YWNrZ3JvdW5kOiAjZjBmMmY1Owp9CiN2aWV3LXByb2Mub24geyBkaXNwbGF5OiBmbGV4OyB9Ci5wcm9jLXRvcCB7CiAgZGlzcGxheTogZmxleDsgYWxpZ24t
;aXRlbXM6IGNlbnRlcjsgZ2FwOiAxMHB4OyBwYWRkaW5nOiAxMHB4IDE0cHggOHB4OwogIGJhY2tncm91bmQ6ICNmZmY7IGJvcmRlci1ib3R0b206IDFweCBz
;b2xpZCB2YXIoLS1saW5lKTsKICAtd2Via2l0LWFwcC1yZWdpb246IGRyYWc7IGFwcC1yZWdpb246IGRyYWc7Cn0KLnByb2MtdG9wIC5uby1kcmFnLCAucHJv
;Yy10b3AgYnV0dG9uLCAucHJvYy10b3AgaW5wdXQgewogIC13ZWJraXQtYXBwLXJlZ2lvbjogbm8tZHJhZzsgYXBwLXJlZ2lvbjogbm8tZHJhZzsKfQoucHJv
;Yy10YWJzIHsgZGlzcGxheTogZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsgZ2FwOiA4cHg7IGZsZXgtd3JhcDogd3JhcDsgfQoucHJvYy10YWIgewogIGhl
;aWdodDogMzBweDsgcGFkZGluZzogMCAxNHB4OyBib3JkZXI6IDA7IGJvcmRlci1yYWRpdXM6IDk5OXB4OwogIGJhY2tncm91bmQ6ICNlY2VmZjM7IGNvbG9y
;OiAjNGI1NTYzOyBmb250LXNpemU6IDEzcHg7IGN1cnNvcjogcG9pbnRlcjsKfQoucHJvYy10YWIub24geyBiYWNrZ3JvdW5kOiAjM2I4MmY2OyBjb2xvcjog
;I2ZmZjsgZm9udC13ZWlnaHQ6IDYwMDsgfQoucHJvYy10YWI6ZGlzYWJsZWQgeyBvcGFjaXR5OiAuNTU7IGN1cnNvcjogZGVmYXVsdDsgfQoucHJvYy10b3At
;cmlnaHQgeyBtYXJnaW4tbGVmdDogYXV0bzsgZGlzcGxheTogZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsgZ2FwOiA4cHg7IH0KI2J0bi1iYWNrLXNlYXJj
;aCB7CiAgaGVpZ2h0OiAzMHB4OyBwYWRkaW5nOiAwIDEycHg7IGJvcmRlcjogMDsgYm9yZGVyLXJhZGl1czogOTk5cHg7CiAgYmFja2dyb3VuZDogI2YzZjRm
;NjsgY29sb3I6IHZhcigtLXR4dCk7IGZvbnQtc2l6ZTogMTIuNXB4OyBjdXJzb3I6IHBvaW50ZXI7Cn0KI2J0bi1iYWNrLXNlYXJjaDpob3ZlciB7IGJhY2tn
;cm91bmQ6ICNlNWU3ZWI7IH0KLnByb2Mtc2VhcmNoIHsKICBkaXNwbGF5OiBmbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBnYXA6IDhweDsgcGFkZGluZzog
;OHB4IDE0cHg7CiAgYmFja2dyb3VuZDogI2ZmZjsgYm9yZGVyLWJvdHRvbTogMXB4IHNvbGlkIHZhcigtLWxpbmUpOwp9Ci5wcm9jLXNlYXJjaCBpbnB1dCB7
;CiAgZmxleDogMTsgaGVpZ2h0OiAzMnB4OyBib3JkZXI6IDFweCBzb2xpZCB2YXIoLS1saW5lKTsgYm9yZGVyLXJhZGl1czogOHB4OwogIHBhZGRpbmc6IDAg
;MTJweDsgb3V0bGluZTogbm9uZTsgYmFja2dyb3VuZDogI2ZiZmJmZDsgZm9udC1zaXplOiAxM3B4Owp9Ci5wcm9jLXNlYXJjaCBpbnB1dDpmb2N1cyB7CiAg
;Ym9yZGVyLWNvbG9yOiAjOTNjNWZkOyBib3gtc2hhZG93OiAwIDAgMCAzcHggcmdiYSg1OSwxMzAsMjQ2LC4xNSk7IGJhY2tncm91bmQ6ICNmZmY7Cn0KLnBy
;b2MtdGFibGUtd3JhcCB7CiAgZmxleDogMTsgbWluLWhlaWdodDogMDsgbWFyZ2luOiAwIDEwcHggOHB4OyBib3JkZXI6IDFweCBzb2xpZCAjZDRkNGQ0Owog
;IGJvcmRlci1yYWRpdXM6IDA7IG92ZXJmbG93OiBoaWRkZW47IGJhY2tncm91bmQ6ICNmZmY7CiAgZGlzcGxheTogZmxleDsgZmxleC1kaXJlY3Rpb246IGNv
;bHVtbjsKfQoucHJvYy10YWJsZS13cmFwLmhpZGRlbiB7IGRpc3BsYXk6IG5vbmU7IH0KLyog57uf5LiA5YiX5a6977ya6KGo5aS05LiO5pWw5o2u5ZCM5LiA
;5aWX5qih5p2/77yM6YG/5YWN5rua5Yqo5p2h6ZSZ5L2NICovCi5wcm9jLWNvbHMgewogIC0tYy1uYW1lOiBtaW5tYXgoMTgwcHgsIDEuNmZyKTsKICAtLWMt
;Y3B1OiA3MnB4OwogIC0tYy1tZW06IDk2cHg7CiAgLS1jLXBpZDogODBweDsKICAtLWMtcHJvdG86IDY4cHg7CiAgLS1jLWxpcDogbWlubWF4KDExMHB4LCAx
;ZnIpOwogIC0tYy1scG9ydDogNzZweDsKICAtLWMtcmlwOiBtaW5tYXgoMTEwcHgsIDFmcik7CiAgLS1jLXJwb3J0OiA3NnB4OwogIC0tYy1zdGF0ZTogODhw
;eDsKICBkaXNwbGF5OiBncmlkOwogIGdyaWQtdGVtcGxhdGUtY29sdW1uczogdmFyKC0tYy1uYW1lKSB2YXIoLS1jLWNwdSkgdmFyKC0tYy1tZW0pIHZhcigt
;LWMtcGlkKSB2YXIoLS1jLXByb3RvKSB2YXIoLS1jLWxpcCkgdmFyKC0tYy1scG9ydCkgdmFyKC0tYy1yaXApIHZhcigtLWMtcnBvcnQpIHZhcigtLWMtc3Rh
;dGUpOwogIGdhcDogMDsKICBhbGlnbi1pdGVtczogc3RyZXRjaDsKICB3aWR0aDogMTAwJTsKICBib3gtc2l6aW5nOiBib3JkZXItYm94Owp9Ci5wcm9jLXNj
;cm9sbCB7CiAgZmxleDogMTsgbWluLWhlaWdodDogMDsgb3ZlcmZsb3c6IGF1dG87CiAgc2Nyb2xsYmFyLWd1dHRlcjogc3RhYmxlOwp9Ci8qIFdpbjExIOS7
;u+WKoeeuoeeQhuWZqOmjjuagvOWPjOWxguihqOWktO+8mueZveW6leOAgeS4iuS4i+WxheS4reWvuem9kCAqLwoucHJvYy1oZWFkIHsKICBwb3NpdGlvbjog
;c3RpY2t5OyB0b3A6IDA7IHotaW5kZXg6IDI7CiAgYmFja2dyb3VuZDogI2ZmZjsgY29sb3I6ICM1YTVhNWE7CiAgaGVpZ2h0OiA0OHB4OyBtaW4taGVpZ2h0
;OiA0OHB4OyBwYWRkaW5nOiAwOwogIGJvcmRlci1ib3R0b206IDFweCBzb2xpZCAjZTVlNWU1Owp9Ci5wcm9jLWhjZWxsIHsKICBkaXNwbGF5OiBmbGV4OyBm
;bGV4LWRpcmVjdGlvbjogY29sdW1uOyBqdXN0aWZ5LWNvbnRlbnQ6IHNwYWNlLWJldHdlZW47CiAgYWxpZ24taXRlbXM6IHN0cmV0Y2g7CiAgbWluLXdpZHRo
;OiAwOyBoZWlnaHQ6IDEwMCU7IHBhZGRpbmc6IDZweCA4cHggN3B4OwogIGJvcmRlci1yaWdodDogMXB4IHNvbGlkICNlNWU1ZTU7IGJveC1zaXppbmc6IGJv
;cmRlci1ib3g7CiAgY3Vyc29yOiBwb2ludGVyOyB1c2VyLXNlbGVjdDogbm9uZTsKICBiYWNrZ3JvdW5kOiAjZmZmOwp9Ci5wcm9jLWhjZWxsOmxhc3QtY2hp
;bGQgeyBib3JkZXItcmlnaHQ6IDA7IH0KLnByb2MtaGNlbGw6aG92ZXIgeyBiYWNrZ3JvdW5kOiAjZjdmN2Y3OyB9Ci5wcm9jLWhjZWxsLnNvcnRlZCB7IGJh
;Y2tncm91bmQ6ICNmZmY7IH0KLnByb2MtaC10b3AgewogIGZsZXg6IDE7CiAgbWluLWhlaWdodDogMThweDsKICBmb250LXNpemU6IDEzcHg7IGZvbnQtd2Vp
;Z2h0OiA2MDA7CiAgY29sb3I6ICMxYjFiMWI7IHdoaXRlLXNwYWNlOiBub3dyYXA7CiAgZGlzcGxheTogZmxleDsgYWxpZ24taXRlbXM6IGZsZXgtc3RhcnQ7
;IGp1c3RpZnktY29udGVudDogY2VudGVyOwogIGdhcDogNHB4OyBsaW5lLWhlaWdodDogMS4yOwogIHBvc2l0aW9uOiByZWxhdGl2ZTsKfQoucHJvYy1jZWxs
;LW5hbWUgLnByb2MtaC10b3AgeyBqdXN0aWZ5LWNvbnRlbnQ6IGNlbnRlcjsgfQoucHJvYy1oLWxhYiB7CiAgZmxleDogMCAwIGF1dG87CiAgZm9udC1zaXpl
;OiAxMnB4OyBmb250LXdlaWdodDogNDAwOwogIGNvbG9yOiAjNWE1YTVhOyB0ZXh0LWFsaWduOiBjZW50ZXI7IHdoaXRlLXNwYWNlOiBub3dyYXA7CiAgbGlu
;ZS1oZWlnaHQ6IDEuMjsKfQoucHJvYy1jZWxsLW5hbWUgLnByb2MtaC1sYWIgeyB0ZXh0LWFsaWduOiBsZWZ0OyB9Ci5wcm9jLWgtc29ydCB7CiAgZGlzcGxh
;eTogaW5saW5lLWJsb2NrOyB3aWR0aDogMDsgaGVpZ2h0OiAwOwogIGJvcmRlci1sZWZ0OiA0cHggc29saWQgdHJhbnNwYXJlbnQ7IGJvcmRlci1yaWdodDog
;NHB4IHNvbGlkIHRyYW5zcGFyZW50OwogIG9wYWNpdHk6IDA7IGZsZXgtc2hyaW5rOiAwOwp9Ci5wcm9jLWhjZWxsLnNvcnRlZCAucHJvYy1oLXNvcnQgeyBv
;cGFjaXR5OiAxOyB9Ci5wcm9jLWhjZWxsLnNvcnRlZC5hc2MgLnByb2MtaC1zb3J0IHsKICBib3JkZXItYm90dG9tOiA1cHggc29saWQgIzFiMWIxYjsgYm9y
;ZGVyLXRvcDogMDsKfQoucHJvYy1oY2VsbC5zb3J0ZWQuZGVzYyAucHJvYy1oLXNvcnQgewogIGJvcmRlci10b3A6IDVweCBzb2xpZCAjMWIxYjFiOyBib3Jk
;ZXItYm90dG9tOiAwOwp9Ci5wcm9jLWJvZHkgeyBkaXNwbGF5OiBibG9jazsgfQoucHJvYy1yb3cgewogIG1pbi1oZWlnaHQ6IDI4cHg7IGhlaWdodDogMjhw
;eDsgcGFkZGluZzogMDsKICBmb250LXNpemU6IDEycHg7IGNvbG9yOiAjMWIxYjFiOwogIGJvcmRlci1ib3R0b206IDA7CiAgY3Vyc29yOiBkZWZhdWx0OyBi
;YWNrZ3JvdW5kOiAjZmZmOyB1c2VyLXNlbGVjdDogbm9uZTsKICBwb3NpdGlvbjogcmVsYXRpdmU7Cn0KLnByb2Mtcm93OmhvdmVyIHsgYmFja2dyb3VuZDog
;I2Y1ZjhmYjsgfQoucHJvYy1yb3cub24sIC5wcm9jLXJvdy5vbjpob3ZlciB7IGJhY2tncm91bmQ6ICNjY2U4ZmY7IH0KLyog5ZCM5ZCN6L+b56iL6L+e57ut
;5q6177ya5LuF5reh57u/6Imy5aSW5qGG77yM5peg5bqV6ImyICovCi5wcm9jLXJvdy5ncnAtZmlyc3QgewogIGJveC1zaGFkb3c6IGluc2V0IDAgMnB4IDAg
;Izg4ZmZjMSwgaW5zZXQgMnB4IDAgMCAjODhmZmMxLCBpbnNldCAtMnB4IDAgMCAjODhmZmMxOwogIGJvcmRlci1yYWRpdXM6IDRweCA0cHggMCAwOwp9Ci5w
;cm9jLXJvdy5ncnAtbWlkIHsKICBib3gtc2hhZG93OiBpbnNldCAycHggMCAwICM4OGZmYzEsIGluc2V0IC0ycHggMCAwICM4OGZmYzE7CiAgYm9yZGVyLXJh
;ZGl1czogMDsKfQoucHJvYy1yb3cuZ3JwLWxhc3QgewogIGJveC1zaGFkb3c6IGluc2V0IDAgLTJweCAwICM4OGZmYzEsIGluc2V0IDJweCAwIDAgIzg4ZmZj
;MSwgaW5zZXQgLTJweCAwIDAgIzg4ZmZjMTsKICBib3JkZXItcmFkaXVzOiAwIDAgNHB4IDRweDsKfQoucHJvYy1yb3cuZ3JwLW9ubHksCi5wcm9jLXJvdy5n
;cnAtZmlyc3QuZ3JwLWxhc3QgewogIGJveC1zaGFkb3c6IGluc2V0IDAgMCAwIDJweCAjODhmZmMxOwogIGJvcmRlci1yYWRpdXM6IDRweDsKfQovKiDnu4Tl
;hoXpnZ7nhKbngrnooYzkv53mjIHnmb3lupXvvJvnnJ/mraPngrnkuK3nmoTpgqPkuIDooYzkv53nlZnok53oibLlupUgKi8KLnByb2Mtcm93LmdycDpub3Qo
;Lm9uKSB7IGJhY2tncm91bmQ6ICNmZmY7IH0KLnByb2Mtcm93LmdycDpub3QoLm9uKTpob3ZlciB7IGJhY2tncm91bmQ6ICNmNWY4ZmI7IH0KLyogV2luZG93
;cyDmt6Hnq5bnur/vvJvljZXlhYPmoLzlkIzlrr3lkIzlnqvvvIzooajlpLTkuI7mlbDmja7kuKXmoLzlr7npvZAgKi8KLnByb2Mtcm93ID4gZGl2IHsKICBk
;aXNwbGF5OiBmbGV4OwogIGFsaWduLWl0ZW1zOiBjZW50ZXI7CiAgbWluLXdpZHRoOiAwOwogIGhlaWdodDogMTAwJTsKICBwYWRkaW5nOiAwIDhweDsKICBi
;b3JkZXItcmlnaHQ6IDFweCBzb2xpZCAjZTVlNWU1OwogIGJveC1zaXppbmc6IGJvcmRlci1ib3g7CiAgb3ZlcmZsb3c6IGhpZGRlbjsKICB3aGl0ZS1zcGFj
;ZTogbm93cmFwOwp9Ci5wcm9jLXJvdyA+IGRpdjpsYXN0LWNoaWxkIHsgYm9yZGVyLXJpZ2h0OiAwOyB9Ci5wcm9jLWNlbGwtbmFtZSB7IGp1c3RpZnktY29u
;dGVudDogZmxleC1zdGFydDsgfQoucHJvYy1jZWxsLXBpZCwKLnByb2MtY2VsbC1wb3J0LAoucHJvYy1jZWxsLWNwdSwKLnByb2MtY2VsbC1tZW0geyBqdXN0
;aWZ5LWNvbnRlbnQ6IGZsZXgtZW5kOyB9Ci5wcm9jLWNlbGwtcHJvdG8geyBqdXN0aWZ5LWNvbnRlbnQ6IGNlbnRlcjsgfQoucHJvYy1jZWxsLXN0YXRlIHsg
;anVzdGlmeS1jb250ZW50OiBmbGV4LXN0YXJ0OyBnYXA6IDZweDsgfQoucHJvYy1jZWxsLWlwIHsganVzdGlmeS1jb250ZW50OiBmbGV4LXN0YXJ0OyB9Ci5w
;cm9jLWNlbGwtY3B1LCAucHJvYy1jZWxsLW1lbSB7CiAgYmFja2dyb3VuZDogI2NlZmZlNTsKfQoucHJvYy1jZWxsLWNwdS5ob3QsIC5wcm9jLWNlbGwtbWVt
;LmhvdCB7CiAgYmFja2dyb3VuZDogIzg4ZmZjMTsKfQoucHJvYy1yb3cub24gLnByb2MtY2VsbC1jcHUsCi5wcm9jLXJvdy5vbiAucHJvYy1jZWxsLW1lbSB7
;CiAgYmFja2dyb3VuZDogI2NlZmZlNTsKfQoucHJvYy1yb3cub24gLnByb2MtY2VsbC1jcHUuaG90LAoucHJvYy1yb3cub24gLnByb2MtY2VsbC1tZW0uaG90
;IHsKICBiYWNrZ3JvdW5kOiAjODhmZmMxOwp9Ci5wcm9jLWhjZWxsLnByb2MtY2VsbC1jcHUsCi5wcm9jLWhjZWxsLnByb2MtY2VsbC1tZW0gewogIGJhY2tn
;cm91bmQ6ICNmZmY7Cn0KLnByb2MtaGNlbGwucHJvYy1jZWxsLWNwdS5ob3QsCi5wcm9jLWhjZWxsLnByb2MtY2VsbC1tZW0uaG90IHsKICBiYWNrZ3JvdW5k
;OiAjODhmZmMxOwp9Ci5wcm9jLWhjZWxsLnByb2MtY2VsbC1jcHU6bm90KC5ob3QpLAoucHJvYy1oY2VsbC5wcm9jLWNlbGwtbWVtOm5vdCguaG90KSB7CiAg
;YmFja2dyb3VuZDogI2NlZmZlNTsKfQoucHJvYy1uYW1lIHsKICBkaXNwbGF5OiBmbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBnYXA6IDhweDsKICBtaW4t
;d2lkdGg6IDA7IHdpZHRoOiAxMDAlOyBvdmVyZmxvdzogaGlkZGVuOwp9Ci5wcm9jLW5hbWUgaW1nLCAucHJvYy1uYW1lIC5wcm9jLWljby1waCB7CiAgd2lk
;dGg6IDE2cHg7IGhlaWdodDogMTZweDsgb2JqZWN0LWZpdDogY29udGFpbjsgZmxleC1zaHJpbms6IDA7Cn0KLnByb2MtbmFtZSAucHJvYy1pY28tcGggewog
;IGRpc3BsYXk6IGlubGluZS1ibG9jazsgYmFja2dyb3VuZDogI2U4ZWFlZDsgYm9yZGVyLXJhZGl1czogMnB4OwogIGJvcmRlcjogMXB4IHNvbGlkICNkMGQ0
;ZGE7Cn0KLnByb2MtbmFtZSAucHJvYy1sYWJlbCB7CiAgb3ZlcmZsb3c6IGhpZGRlbjsgdGV4dC1vdmVyZmxvdzogZWxsaXBzaXM7IHdoaXRlLXNwYWNlOiBu
;b3dyYXA7IG1pbi13aWR0aDogMDsKfQoucHJvYy1uZXQtZG90IHsKICB3aWR0aDogN3B4OyBoZWlnaHQ6IDdweDsgYm9yZGVyLXJhZGl1czogNTAlOyBmbGV4
;LXNocmluazogMDsKICBiYWNrZ3JvdW5kOiAjMjJjNTVlOyBib3gtc2hhZG93OiAwIDAgMCAycHggcmdiYSgzNCwgMTk3LCA5NCwgLjIpOwp9Ci5wcm9jLW5l
;dC1kb3QuaGlkZGVuIHsgZGlzcGxheTogbm9uZTsgfQoucHJvYy1udW0gewogIGZvbnQtdmFyaWFudC1udW1lcmljOiB0YWJ1bGFyLW51bXM7IGNvbG9yOiAj
;MWIxYjFiOwogIHdpZHRoOiAxMDAlOwp9Ci5wcm9jLW51bS5wb3J0LWhvdCB7CiAgY29sb3I6ICNjMjQxMGM7CiAgZm9udC13ZWlnaHQ6IDcwMDsKfQovKiDi
;lIDilIAg5YWz6IGU5Y+l5p+E77yI546w5Luj6L276YeP6KGo5qC877yJ4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA
;4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSAICovCiNoYW5kbGUtcGFuZWwgewogIGZsZXg6IDE7IG1pbi1oZWlnaHQ6IDA7IG1hcmdpbjogMDsgYm9yZGVy
;OiAwOwogIGJhY2tncm91bmQ6ICNmZmY7IGRpc3BsYXk6IGZsZXg7IGZsZXgtZGlyZWN0aW9uOiBjb2x1bW47IG92ZXJmbG93OiBoaWRkZW47Cn0KI2hhbmRs
;ZS1wYW5lbC5oaWRkZW4geyBkaXNwbGF5OiBub25lOyB9Ci5oYW5kbGUtYmFubmVyIHsKICBkaXNwbGF5OiBub25lOyBhbGlnbi1pdGVtczogY2VudGVyOyBn
;YXA6IDhweDsKICBtYXJnaW46IDA7IHBhZGRpbmc6IDhweCAxNHB4OwogIGJhY2tncm91bmQ6ICNmMGY3ZmY7IGJvcmRlcjogMDsgYm9yZGVyLXJhZGl1czog
;MDsKICBjb2xvcjogIzFlM2E1ZjsgZm9udC1zaXplOiAxMi41cHg7IGZsZXgtc2hyaW5rOiAwOwp9Ci5oYW5kbGUtYmFubmVyLm9uIHsgZGlzcGxheTogZmxl
;eDsgfQouaGFuZGxlLWJhbm5lcjo6YmVmb3JlIHsKICBjb250ZW50OiAiIjsgd2lkdGg6IDZweDsgaGVpZ2h0OiA2cHg7IGJvcmRlci1yYWRpdXM6IDUwJTsK
;ICBiYWNrZ3JvdW5kOiAjM2I4MmY2OyBmbGV4LXNocmluazogMDsKfQouaGFuZGxlLWNvbHMgewogIC0taC1uYW1lOiBtaW5tYXgoMTQwcHgsIDEuMmZyKTsK
;ICAtLWgtcGlkOiA4OHB4OwogIC0taC1wb3J0OiA4NHB4OwogIC0taC1ycG9ydDogODRweDsKICAtLWgtdHlwZTogNzJweDsKICAtLWgtcGF0aDogbWlubWF4
;KDE2MHB4LCAyZnIpOwogIGRpc3BsYXk6IGdyaWQ7CiAgZ3JpZC10ZW1wbGF0ZS1jb2x1bW5zOiB2YXIoLS1oLW5hbWUpIHZhcigtLWgtcGlkKSB2YXIoLS1o
;LXR5cGUpIHZhcigtLWgtcGF0aCk7CiAgZ2FwOiAwOyB3aWR0aDogMTAwJTsgYm94LXNpemluZzogYm9yZGVyLWJveDsgYWxpZ24taXRlbXM6IHN0cmV0Y2g7
;Cn0KLmhhbmRsZS1jb2xzLnBvcnQtbW9kZSB7CiAgZ3JpZC10ZW1wbGF0ZS1jb2x1bW5zOiB2YXIoLS1oLW5hbWUpIHZhcigtLWgtcGlkKSB2YXIoLS1oLXBv
;cnQpIHZhcigtLWgtcnBvcnQpIHZhcigtLWgtdHlwZSkgdmFyKC0taC1wYXRoKTsKfQouaGFuZGxlLWNvbC1wb3J0LmhpZGRlbiwgLmhhbmRsZS1jb2wtcnBv
;cnQuaGlkZGVuIHsgZGlzcGxheTogbm9uZSAhaW1wb3J0YW50OyB9Ci5oYW5kbGUtY29scy5wb3J0LW1vZGUgLmhhbmRsZS1jb2wtcG9ydC5oaWRkZW4sCi5o
;YW5kbGUtY29scy5wb3J0LW1vZGUgLmhhbmRsZS1jb2wtcnBvcnQuaGlkZGVuIHsgZGlzcGxheTogZmxleCAhaW1wb3J0YW50OyB9Ci5oYW5kbGUtc2Nyb2xs
;IHsgZmxleDogMTsgbWluLWhlaWdodDogMDsgb3ZlcmZsb3c6IGF1dG87IHBhZGRpbmc6IDAgOHB4IDhweDsgfQouaGFuZGxlLWhlYWQgewogIHBvc2l0aW9u
;OiBzdGlja3k7IHRvcDogMDsgei1pbmRleDogMjsgaGVpZ2h0OiAzNHB4OyBtaW4taGVpZ2h0OiAzNHB4OwogIGJhY2tncm91bmQ6ICNmZmY7IGNvbG9yOiB2
;YXIoLS10eHQyKTsgZm9udC1zaXplOiAxMnB4OyBmb250LXdlaWdodDogNjAwOwogIGJvcmRlci1ib3R0b206IDFweCBzb2xpZCB2YXIoLS1saW5lKTsKfQou
;aGFuZGxlLWhjZWxsIHsKICBjdXJzb3I6IHBvaW50ZXI7IHVzZXItc2VsZWN0OiBub25lOyBnYXA6IDZweDsKfQouaGFuZGxlLWhjZWxsOmhvdmVyIHsgYmFj
;a2dyb3VuZDogI2Y1ZjdmYjsgY29sb3I6IHZhcigtLXR4dCk7IH0KLmhhbmRsZS1oY2VsbC5zb3J0ZWQgeyBjb2xvcjogdmFyKC0tdHh0KTsgfQouaGFuZGxl
;LWhjZWxsIC5oLXNvcnQgewogIGRpc3BsYXk6IGlubGluZS1ibG9jazsgd2lkdGg6IDA7IGhlaWdodDogMDsKICBib3JkZXItbGVmdDogNHB4IHNvbGlkIHRy
;YW5zcGFyZW50OyBib3JkZXItcmlnaHQ6IDRweCBzb2xpZCB0cmFuc3BhcmVudDsKICBvcGFjaXR5OiAwOyBmbGV4LXNocmluazogMDsKfQouaGFuZGxlLWhj
;ZWxsLnNvcnRlZCAuaC1zb3J0IHsgb3BhY2l0eTogMTsgfQouaGFuZGxlLWhjZWxsLnNvcnRlZC5hc2MgLmgtc29ydCB7CiAgYm9yZGVyLWJvdHRvbTogNXB4
;IHNvbGlkICMxYjFiMWI7IGJvcmRlci10b3A6IDA7Cn0KLmhhbmRsZS1oY2VsbC5zb3J0ZWQuZGVzYyAuaC1zb3J0IHsKICBib3JkZXItdG9wOiA1cHggc29s
;aWQgIzFiMWIxYjsgYm9yZGVyLWJvdHRvbTogMDsKfQouaGFuZGxlLWJvZHkgeyBkaXNwbGF5OiBibG9jazsgcGFkZGluZy10b3A6IDJweDsgfQouaGFuZGxl
;LXJvdyB7CiAgbWluLWhlaWdodDogMzZweDsgaGVpZ2h0OiAzNnB4OyBmb250LXNpemU6IDEzcHg7IGNvbG9yOiB2YXIoLS10eHQpOwogIGJvcmRlcjogMDsg
;Ym9yZGVyLXJhZGl1czogOHB4OyBiYWNrZ3JvdW5kOiB0cmFuc3BhcmVudDsgY3Vyc29yOiBkZWZhdWx0OyB1c2VyLXNlbGVjdDogbm9uZTsKICBtYXJnaW46
;IDFweCAwOwp9Ci5oYW5kbGUtcm93OmhvdmVyIHsgYmFja2dyb3VuZDogI2Y1ZjdmYjsgfQouaGFuZGxlLXJvdy5vbiwgLmhhbmRsZS1yb3cub246aG92ZXIg
;eyBiYWNrZ3JvdW5kOiB2YXIoLS1zZWwpOyB9Ci5oYW5kbGUtaGVhZCA+IGRpdiwKLmhhbmRsZS1yb3cgPiBkaXYgewogIGRpc3BsYXk6IGZsZXg7IGFsaWdu
;LWl0ZW1zOiBjZW50ZXI7IG1pbi13aWR0aDogMDsgaGVpZ2h0OiAxMDAlOwogIHBhZGRpbmc6IDAgMTJweDsgYm9yZGVyOiAwOyBib3gtc2l6aW5nOiBib3Jk
;ZXItYm94OwogIG92ZXJmbG93OiBoaWRkZW47IHdoaXRlLXNwYWNlOiBub3dyYXA7IHRleHQtb3ZlcmZsb3c6IGVsbGlwc2lzOwp9Ci5oYW5kbGUtbmFtZSB7
;CiAgZGlzcGxheTogZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsgZ2FwOiAxMHB4OyBtaW4td2lkdGg6IDA7IHdpZHRoOiAxMDAlOyBvdmVyZmxvdzogaGlk
;ZGVuOwp9Ci5oYW5kbGUtbmFtZSBpbWcsIC5oYW5kbGUtbmFtZSAuaGFuZGxlLWljby1waCB7CiAgd2lkdGg6IDE4cHg7IGhlaWdodDogMThweDsgb2JqZWN0
;LWZpdDogY29udGFpbjsgZmxleC1zaHJpbms6IDA7Cn0KLmhhbmRsZS1uYW1lIC5oYW5kbGUtaWNvLXBoIHsKICBkaXNwbGF5OiBpbmxpbmUtYmxvY2s7IGJh
;Y2tncm91bmQ6ICNlZWYxZjY7IGJvcmRlci1yYWRpdXM6IDRweDsgYm9yZGVyOiAwOwp9Ci5oYW5kbGUtbmFtZSBzcGFuIHsKICBvdmVyZmxvdzogaGlkZGVu
;OyB0ZXh0LW92ZXJmbG93OiBlbGxpcHNpczsgd2hpdGUtc3BhY2U6IG5vd3JhcDsgbWluLXdpZHRoOiAwOyBmb250LXdlaWdodDogNTAwOwp9Ci5oYW5kbGUt
;bmV0LWRvdCB7CiAgd2lkdGg6IDdweDsgaGVpZ2h0OiA3cHg7IGJvcmRlci1yYWRpdXM6IDUwJTsgZmxleC1zaHJpbms6IDA7CiAgYmFja2dyb3VuZDogIzIy
;YzU1ZTsgYm94LXNoYWRvdzogMCAwIDAgMnB4IHJnYmEoMzQsIDE5NywgOTQsIC4yKTsKfQouaGFuZGxlLXN0YXRlIHsKICBkaXNwbGF5OiBmbGV4OyBhbGln
;bi1pdGVtczogY2VudGVyOyBnYXA6IDZweDsgbWluLXdpZHRoOiAwOwp9Ci5oYW5kbGUtZW1wdHkgewogIHBhZGRpbmc6IDQ4cHggMTZweDsgdGV4dC1hbGln
;bjogY2VudGVyOyBjb2xvcjogdmFyKC0tdHh0Myk7IGZvbnQtc2l6ZTogMTMuNXB4OyBsaW5lLWhlaWdodDogMS42Owp9Ci5oYW5kbGUtbG9hZGluZyB7CiAg
;ZGlzcGxheTogZmxleDsgZmxleC1kaXJlY3Rpb246IGNvbHVtbjsgYWxpZ24taXRlbXM6IGNlbnRlcjsganVzdGlmeS1jb250ZW50OiBjZW50ZXI7CiAgZ2Fw
;OiAxNHB4OyBwYWRkaW5nOiA2NHB4IDE2cHg7IGNvbG9yOiB2YXIoLS10eHQyKTsgZm9udC1zaXplOiAxM3B4Owp9Ci5oYW5kbGUtc3Bpbm5lciB7CiAgd2lk
;dGg6IDI2cHg7IGhlaWdodDogMjZweDsgYm9yZGVyLXJhZGl1czogNTAlOyBib3gtc2l6aW5nOiBib3JkZXItYm94OwogIGJvcmRlcjogMi41cHggc29saWQg
;I2U1ZTdlYjsgYm9yZGVyLXRvcC1jb2xvcjogI2U0MjA3OTsKICBhbmltYXRpb246IGhhbmRsZS1zcGluIC43cyBsaW5lYXIgaW5maW5pdGU7Cn0KQGtleWZy
;YW1lcyBoYW5kbGUtc3BpbiB7CiAgdG8geyB0cmFuc2Zvcm06IHJvdGF0ZSgzNjBkZWcpOyB9Cn0KLmluZm8tbG9hZGluZyB7CiAgZGlzcGxheTogZmxleDsg
;ZmxleC1kaXJlY3Rpb246IGNvbHVtbjsgYWxpZ24taXRlbXM6IGNlbnRlcjsganVzdGlmeS1jb250ZW50OiBjZW50ZXI7CiAgZ2FwOiAxNHB4OyBtaW4taGVp
;Z2h0OiAyNDBweDsgcGFkZGluZzogNjRweCAxNnB4OyBjb2xvcjogdmFyKC0tdHh0Mik7IGZvbnQtc2l6ZTogMTNweDsKICBib3gtc2l6aW5nOiBib3JkZXIt
;Ym94Owp9Ci5pbmZvLXNwaW5uZXIgewogIHdpZHRoOiAyOHB4OyBoZWlnaHQ6IDI4cHg7IGJvcmRlci1yYWRpdXM6IDUwJTsgYm94LXNpemluZzogYm9yZGVy
;LWJveDsKICBib3JkZXI6IDIuNXB4IHNvbGlkICNlNWU3ZWI7IGJvcmRlci10b3AtY29sb3I6ICNlNDIwNzk7CiAgYW5pbWF0aW9uOiBoYW5kbGUtc3BpbiAu
;N3MgbGluZWFyIGluZmluaXRlOwp9CiNiYXItaGFuZGxlLWFjdGlvbnMgewogIGRpc3BsYXk6IG5vbmU7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGdhcDogMTBw
;eDsgbWFyZ2luLXJpZ2h0OiA4cHg7IG1pbi13aWR0aDogMDsKICBwb3NpdGlvbjogcmVsYXRpdmU7Cn0KI2Jhci5tb2RlLWhhbmRsZSAjYmFyLWhhbmRsZS1h
;Y3Rpb25zIHsgZGlzcGxheTogaW5saW5lLWZsZXg7IH0KI2Jhci1oYW5kbGUtYWN0aW9ucyAjaGFuZGxlLXN0YXR1cyB7CiAgY29sb3I6IHZhcigtLXR4dDMp
;OyBmb250LXNpemU6IDEycHg7IG1heC13aWR0aDogMjQwcHg7CiAgb3ZlcmZsb3c6IGhpZGRlbjsgdGV4dC1vdmVyZmxvdzogZWxsaXBzaXM7IHdoaXRlLXNw
;YWNlOiBub3dyYXA7Cn0KI2J0bi1wb3J0LW1hcmsgewogIHdpZHRoOiAyOHB4OyBoZWlnaHQ6IDI4cHg7IGJvcmRlcjogMDsgYm9yZGVyLXJhZGl1czogOHB4
;OwogIGJhY2tncm91bmQ6IHRyYW5zcGFyZW50OyBjb2xvcjogdmFyKC0tdHh0Mik7IGZvbnQtc2l6ZTogMTVweDsKICBjdXJzb3I6IHBvaW50ZXI7IGxpbmUt
;aGVpZ2h0OiAxOyBmbGV4LXNocmluazogMDsKfQojYnRuLXBvcnQtbWFyazpob3ZlciwgI2J0bi1wb3J0LW1hcmsub24gewogIGJhY2tncm91bmQ6ICNlZWYx
;ZjY7IGNvbG9yOiB2YXIoLS10eHQpOwp9CiNiYXIubW9kZS1oYW5kbGUgLnNvcnQsICNiYXIubW9kZS1oYW5kbGUgLnRvZ2dsZSB7IGRpc3BsYXk6IG5vbmU7
;IH0KLmhhbmRsZS1jb2wtcG9ydC5wb3J0LWhvdCwKLmhhbmRsZS1jb2wtcnBvcnQucG9ydC1ob3QgewogIGNvbG9yOiAjYzI0MTBjOyBmb250LXdlaWdodDog
;NzAwOwp9CiNwb3J0LW1hcmstcG9wIHsKICBkaXNwbGF5OiBub25lOyBwb3NpdGlvbjogYWJzb2x1dGU7IHJpZ2h0OiAwOyBib3R0b206IGNhbGMoMTAwJSAr
;IDhweCk7CiAgd2lkdGg6IDMwMHB4OyB6LWluZGV4OiA4MDsgcGFkZGluZzogMTJweDsKICBiYWNrZ3JvdW5kOiAjZmZmOyBib3JkZXI6IDFweCBzb2xpZCB2
;YXIoLS1saW5lKTsgYm9yZGVyLXJhZGl1czogMTJweDsKICBib3gtc2hhZG93OiAwIDEycHggMjhweCByZ2JhKDE1LCAyMywgNDIsIC4xMik7Cn0KI3BvcnQt
;bWFyay1wb3Aub24geyBkaXNwbGF5OiBibG9jazsgfQoucG1wLWhkIHsgZm9udC1zaXplOiAxMy41cHg7IGZvbnQtd2VpZ2h0OiA2NTA7IGNvbG9yOiB2YXIo
;LS10eHQpOyBtYXJnaW4tYm90dG9tOiA0cHg7IH0KLnBtcC1oaW50IHsgZm9udC1zaXplOiAxMnB4OyBjb2xvcjogdmFyKC0tdHh0Myk7IG1hcmdpbi1ib3R0
;b206IDEwcHg7IGxpbmUtaGVpZ2h0OiAxLjQ7IH0KLnBtcC10YWdzIHsKICBkaXNwbGF5OiBmbGV4OyBmbGV4LXdyYXA6IHdyYXA7IGdhcDogNnB4OyBtaW4t
;aGVpZ2h0OiAzMnB4OwogIG1heC1oZWlnaHQ6IDE0MHB4OyBvdmVyZmxvdzogYXV0bzsgbWFyZ2luLWJvdHRvbTogMTBweDsKfQoucG1wLXRhZyB7CiAgZGlz
;cGxheTogaW5saW5lLWZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGdhcDogNHB4OwogIGhlaWdodDogMjZweDsgcGFkZGluZzogMCA0cHggMCAxMHB4OyBi
;b3JkZXItcmFkaXVzOiA5OTlweDsKICBiYWNrZ3JvdW5kOiAjZmZmN2VkOyBjb2xvcjogI2MyNDEwYzsgZm9udC1zaXplOiAxMi41cHg7IGZvbnQtd2VpZ2h0
;OiA2MDA7CiAgZm9udC12YXJpYW50LW51bWVyaWM6IHRhYnVsYXItbnVtczsKfQoucG1wLXRhZyBidXR0b24gewogIHdpZHRoOiAyMHB4OyBoZWlnaHQ6IDIw
;cHg7IGJvcmRlcjogMDsgYm9yZGVyLXJhZGl1czogNTAlOwogIGJhY2tncm91bmQ6IHRyYW5zcGFyZW50OyBjb2xvcjogI2VhNTgwYzsgY3Vyc29yOiBwb2lu
;dGVyOyBmb250LXNpemU6IDE0cHg7IGxpbmUtaGVpZ2h0OiAxOwp9Ci5wbXAtdGFnIGJ1dHRvbjpob3ZlciB7IGJhY2tncm91bmQ6ICNmZmVkZDU7IH0KLnBt
;cC1lbXB0eSB7IGNvbG9yOiB2YXIoLS10eHQzKTsgZm9udC1zaXplOiAxMnB4OyBwYWRkaW5nOiA2cHggMnB4OyB9Ci5wbXAtYWRkIHsgZGlzcGxheTogZmxl
;eDsgZ2FwOiA4cHg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IG1hcmdpbi1ib3R0b206IDhweDsgfQoucG1wLWFkZCBpbnB1dCB7CiAgZmxleDogMTsgbWluLXdp
;ZHRoOiAwOyBoZWlnaHQ6IDMycHg7IGJvcmRlcjogMXB4IHNvbGlkIHZhcigtLWxpbmUpOyBib3JkZXItcmFkaXVzOiA4cHg7CiAgcGFkZGluZzogMCAxMHB4
;OyBvdXRsaW5lOiBub25lOyBmb250LXNpemU6IDEzcHg7IGJhY2tncm91bmQ6ICNmYmZiZmQ7Cn0KLnBtcC1hZGQgaW5wdXQ6Zm9jdXMgeyBib3JkZXItY29s
;b3I6ICM5M2M1ZmQ7IGJhY2tncm91bmQ6ICNmZmY7IH0KLnBtcC1hZGQgYnV0dG9uLCAucG1wLXJlc2V0IHsKICBoZWlnaHQ6IDMycHg7IHBhZGRpbmc6IDAg
;MTJweDsgYm9yZGVyOiAwOyBib3JkZXItcmFkaXVzOiA4cHg7CiAgYmFja2dyb3VuZDogI2VmZjZmZjsgY29sb3I6ICMxZDRlZDg7IGZvbnQtc2l6ZTogMTIu
;NXB4OyBmb250LXdlaWdodDogNjAwOyBjdXJzb3I6IHBvaW50ZXI7Cn0KLnBtcC1hZGQgYnV0dG9uOmhvdmVyIHsgYmFja2dyb3VuZDogI2RiZWFmZTsgfQou
;cG1wLXJlc2V0IHsKICB3aWR0aDogMTAwJTsgYmFja2dyb3VuZDogdHJhbnNwYXJlbnQ7IGNvbG9yOiB2YXIoLS10eHQyKTsgZm9udC13ZWlnaHQ6IDUwMDsK
;fQoucG1wLXJlc2V0OmhvdmVyIHsgYmFja2dyb3VuZDogI2YzZjRmNjsgY29sb3I6IHZhcigtLXR4dCk7IH0KLnByb2MtYWN0IHsKICB3aWR0aDogMjJweDsg
;aGVpZ2h0OiAyMnB4OyBib3JkZXI6IDA7IGJvcmRlci1yYWRpdXM6IDRweDsgYmFja2dyb3VuZDogdHJhbnNwYXJlbnQ7CiAgY29sb3I6ICM5YWExYjI7IGN1
;cnNvcjogcG9pbnRlcjsgZm9udC1zaXplOiAxMnB4OyBsaW5lLWhlaWdodDogMTsKfQoucHJvYy1hY3Q6aG92ZXIgeyBiYWNrZ3JvdW5kOiAjZTVlN2ViOyBj
;b2xvcjogIzExMTgyNzsgfQoucHJvYy1mb290IHsKICBkaXNwbGF5OiBmbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBqdXN0aWZ5LWNvbnRlbnQ6IGZsZXgt
;ZW5kOyBnYXA6IDE0cHg7CiAgcGFkZGluZzogNnB4IDE2cHggMTBweDsgY29sb3I6ICMzYjgyZjY7IGZvbnQtc2l6ZTogMTIuNXB4Owp9Ci5wcm9jLWZvb3Qu
;aGlkZGVuIHsgZGlzcGxheTogbm9uZTsgfQoucHJvYy1zeXMtdG9nIHsKICBkaXNwbGF5OiBpbmxpbmUtZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsgZ2Fw
;OiA4cHg7IGN1cnNvcjogcG9pbnRlcjsKICB1c2VyLXNlbGVjdDogbm9uZTsgY29sb3I6ICMzYjgyZjY7IGZvbnQtc2l6ZTogMTIuNXB4Owp9Ci5wcm9jLXN5
;cy10b2cgaW5wdXQgeyBwb3NpdGlvbjogYWJzb2x1dGU7IG9wYWNpdHk6IDA7IHdpZHRoOiAwOyBoZWlnaHQ6IDA7IH0KLnByb2Mtc3lzLXRvZyAudG9nIHsK
;ICB3aWR0aDogMzZweDsgaGVpZ2h0OiAyMHB4OyBib3JkZXItcmFkaXVzOiA5OTlweDsgYmFja2dyb3VuZDogI2QxZDVkYjsKICBwb3NpdGlvbjogcmVsYXRp
;dmU7IGZsZXgtc2hyaW5rOiAwOyB0cmFuc2l0aW9uOiBiYWNrZ3JvdW5kIC4xNXMgZWFzZTsKfQoucHJvYy1zeXMtdG9nIC50b2c6OmFmdGVyIHsKICBjb250
;ZW50OiAiIjsgcG9zaXRpb246IGFic29sdXRlOyB0b3A6IDJweDsgbGVmdDogMnB4OwogIHdpZHRoOiAxNnB4OyBoZWlnaHQ6IDE2cHg7IGJvcmRlci1yYWRp
;dXM6IDUwJTsgYmFja2dyb3VuZDogI2ZmZjsKICBib3gtc2hhZG93OiAwIDFweCAycHggcmdiYSgwLDAsMCwuMTgpOyB0cmFuc2l0aW9uOiB0cmFuc2Zvcm0g
;LjE1cyBlYXNlOwp9Ci5wcm9jLXN5cy10b2cgaW5wdXQ6Y2hlY2tlZCArIC50b2cgeyBiYWNrZ3JvdW5kOiAjM2I4MmY2OyB9Ci5wcm9jLXN5cy10b2cgaW5w
;dXQ6Y2hlY2tlZCArIC50b2c6OmFmdGVyIHsgdHJhbnNmb3JtOiB0cmFuc2xhdGVYKDE2cHgpOyB9CiNwcm9jLWNvdW50IHsKICBjb2xvcjogIzZiNzI4MDsg
;Zm9udC12YXJpYW50LW51bWVyaWM6IHRhYnVsYXItbnVtczsgbWluLXdpZHRoOiAyLjVlbTsgdGV4dC1hbGlnbjogcmlnaHQ7Cn0KI2luZm8tcGFuZWwgewog
;IGZsZXg6IDE7IG1pbi1oZWlnaHQ6IDA7IG1hcmdpbjogMDsgYm9yZGVyOiAwOyBib3JkZXItcmFkaXVzOiAwOwogIG92ZXJmbG93OiBhdXRvOyBiYWNrZ3Jv
;dW5kOiAjZmZmOwogIGRpc3BsYXk6IGJsb2NrOyAvKiDli7/nlKggZmxleCDliJfvvJrlpJrooYznvZHljaHkvJrooqvljovnn67lj6DlrZcgKi8KfQojaW5m
;by1wYW5lbC5oaWRkZW4geyBkaXNwbGF5OiBub25lOyB9Ci5pbmZvLXJvdyB7CiAgZGlzcGxheTogZ3JpZDsgZ3JpZC10ZW1wbGF0ZS1jb2x1bW5zOiAxMDhw
;eCAxOHB4IDFmciBhdXRvOwogIGdhcDogMCA4cHg7IGFsaWduLWl0ZW1zOiBzdGFydDsgbWluLWhlaWdodDogMzZweDsgaGVpZ2h0OiBhdXRvOwogIHBhZGRp
;bmc6IDhweCAxNHB4OyBib3JkZXItYm90dG9tOiAxcHggc29saWQgI2VlZjBmNDsKICBmbGV4LXNocmluazogMDsgb3ZlcmZsb3c6IHZpc2libGU7Cn0KLmlu
;Zm8tcm93Om50aC1jaGlsZChldmVuKSB7IGJhY2tncm91bmQ6ICNmN2Y4ZmE7IH0KLmluZm8tbGFiIHsKICBjb2xvcjogIzNiODJmNjsgZm9udC1zaXplOiAx
;M3B4OyB0ZXh0LWFsaWduOiByaWdodDsgcGFkZGluZy10b3A6IDJweDsKICB3aGl0ZS1zcGFjZTogbm93cmFwOwp9Ci5pbmZvLWRhc2ggewogIGhlaWdodDog
;MXB4OyBiYWNrZ3JvdW5kOiAjZDFkNWRiOyBtYXJnaW4tdG9wOiAxMnB4OyBhbGlnbi1zZWxmOiBzdGFydDsKfQouaW5mby12YWwgewogIGNvbG9yOiAjMTEx
;ODI3OyBmb250LXNpemU6IDEzcHg7IGxpbmUtaGVpZ2h0OiAxLjU1OyB3b3JkLWJyZWFrOiBicmVhay13b3JkOwogIHBhZGRpbmctdG9wOiAxcHg7IG1pbi13
;aWR0aDogMDsgb3ZlcmZsb3c6IHZpc2libGU7Cn0KLmluZm8tdmFsIC5zdWIgewogIGNvbG9yOiAjMzc0MTUxOyBtYXJnaW4tbGVmdDogMjRweDsgd2hpdGUt
;c3BhY2U6IG5vd3JhcDsKfQojaW5mby11cHRpbWUgewogIGNvbG9yOiAjMzc0MTUxOyBmb250LXZhcmlhbnQtbnVtZXJpYzogdGFidWxhci1udW1zOwp9Ci5p
;bmZvLXZhbCAubGluZSB7IGRpc3BsYXk6IGJsb2NrOyB9Ci5pbmZvLXZhbCAubmV0LWxpbmUgewogIGRpc3BsYXk6IGdyaWQ7IGdyaWQtdGVtcGxhdGUtY29s
;dW1uczogbWlubWF4KDE0MHB4LCAxLjVmcikgbWlubWF4KDE1MHB4LCAxZnIpIG1pbm1heCgxMTBweCwgMC44NWZyKTsKICBnYXA6IDRweCAxMnB4OyBhbGln
;bi1pdGVtczogYmFzZWxpbmU7IG1hcmdpbjogMCAwIDZweDsgbWluLXdpZHRoOiAwOwp9Ci5pbmZvLXZhbCAubmV0LWxpbmU6bGFzdC1jaGlsZCB7IG1hcmdp
;bi1ib3R0b206IDA7IH0KLmluZm8tdmFsIC5uZXQtbGluZSA+IHNwYW4geyBtaW4td2lkdGg6IDA7IG92ZXJmbG93LXdyYXA6IGFueXdoZXJlOyB9Ci5pbmZv
;LXZhbCAubmV0LWxpbmUgLmsgeyBjb2xvcjogIzZiNzI4MDsgfQouaW5mby1saW5rIHsKICBib3JkZXI6IDA7IGJhY2tncm91bmQ6IHRyYW5zcGFyZW50OyBj
;b2xvcjogIzNiODJmNjsgZm9udC1zaXplOiAxMi41cHg7CiAgY3Vyc29yOiBwb2ludGVyOyBwYWRkaW5nOiAycHggMDsgd2hpdGUtc3BhY2U6IG5vd3JhcDsg
;YWxpZ24tc2VsZjogc3RhcnQ7Cn0KLmluZm8tbGluazpob3ZlciB7IHRleHQtZGVjb3JhdGlvbjogdW5kZXJsaW5lOyB9CiNiYXItaW5mby1hY3Rpb25zIHsK
;ICBkaXNwbGF5OiBub25lOyBhbGlnbi1pdGVtczogY2VudGVyOyBnYXA6IDE2cHg7IG1hcmdpbi1yaWdodDogOHB4Owp9CiNiYXIubW9kZS1pbmZvICNiYXIt
;aW5mby1hY3Rpb25zIHsgZGlzcGxheTogaW5saW5lLWZsZXg7IH0KI2Jhci1pbmZvLWFjdGlvbnMgYnV0dG9uIHsKICBib3JkZXI6IDA7IGJhY2tncm91bmQ6
;IHRyYW5zcGFyZW50OyBjb2xvcjogIzNiODJmNjsgZm9udC1zaXplOiAxMi41cHg7IGN1cnNvcjogcG9pbnRlcjsgcGFkZGluZzogMDsKfQojYmFyLWluZm8t
;YWN0aW9ucyBidXR0b246aG92ZXIgeyB0ZXh0LWRlY29yYXRpb246IHVuZGVybGluZTsgfQojYmFyLm1vZGUtaW5mbyAjY291bnQgeyBjb2xvcjogdmFyKC0t
;dHh0Mik7IH0KLnByb2Mtc2VhcmNoLmhpZGRlbiB7IGRpc3BsYXk6IG5vbmUgIWltcG9ydGFudDsgfQojcHJvYy1tZW51IHsKICBkaXNwbGF5OiBub25lOyBw
;b3NpdGlvbjogZml4ZWQ7IHotaW5kZXg6IDIyMDsgbWluLXdpZHRoOiAxODhweDsKICBwYWRkaW5nOiA0cHg7IGJhY2tncm91bmQ6ICNmZmY7IGJvcmRlcjog
;MXB4IHNvbGlkIHZhcigtLWxpbmUpOwogIGJvcmRlci1yYWRpdXM6IDhweDsgYm94LXNoYWRvdzogdmFyKC0tc2hhZG93KTsKfQojcHJvYy1tZW51Lm9uIHsg
;ZGlzcGxheTogYmxvY2s7IH0KI3Byb2MtbWVudSBidXR0b24gewogIGRpc3BsYXk6IGZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGdhcDogMTBweDsgd2lk
;dGg6IDEwMCU7CiAgdGV4dC1hbGlnbjogbGVmdDsgYm9yZGVyOiAwOyBiYWNrZ3JvdW5kOiB0cmFuc3BhcmVudDsKICBwYWRkaW5nOiA4cHggMTBweDsgYm9y
;ZGVyLXJhZGl1czogNnB4OyBjdXJzb3I6IHBvaW50ZXI7IGNvbG9yOiB2YXIoLS10eHQpOyBmb250LXNpemU6IDEzcHg7Cn0KI3Byb2MtbWVudSBidXR0b246
;aG92ZXIgeyBiYWNrZ3JvdW5kOiAjZjNmNGY2OyB9CiNwcm9jLW1lbnUgYnV0dG9uLmRhbmdlciB7IGNvbG9yOiAjZGMyNjI2OyB9CiNwcm9jLW1lbnUgYnV0
;dG9uLmRhbmdlcjpob3ZlciB7IGJhY2tncm91bmQ6ICNmZWYyZjI7IH0KI3Byb2MtbWVudSBidXR0b246ZGlzYWJsZWQgeyBvcGFjaXR5OiAuNDU7IGN1cnNv
;cjogZGVmYXVsdDsgfQojcHJvYy1tZW51IC5jLWljbyB7CiAgd2lkdGg6IDE2cHg7IGhlaWdodDogMTZweDsgZmxleC1zaHJpbms6IDA7CiAgZGlzcGxheTog
;aW5saW5lLWZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGp1c3RpZnktY29udGVudDogY2VudGVyOwogIGNvbG9yOiAjMzc0MTUxOwp9CiNwcm9jLW1lbnUg
;YnV0dG9uLmRhbmdlciAuYy1pY28geyBjb2xvcjogI2RjMjYyNjsgfQojcHJvYy1tZW51IC5jLWljbyBzdmcgeyB3aWR0aDogMTZweDsgaGVpZ2h0OiAxNnB4
;OyBkaXNwbGF5OiBibG9jazsgfQojcHJvYy1tZW51IC5wYWN0LWxhYmVsIHsKICBmbGV4OiAxOyBtaW4td2lkdGg6IDA7IG92ZXJmbG93OiBoaWRkZW47IHRl
;eHQtb3ZlcmZsb3c6IGVsbGlwc2lzOyB3aGl0ZS1zcGFjZTogbm93cmFwOwp9CgojbWFpbiB7IGZsZXg6IDE7IGRpc3BsYXk6IGdyaWQ7IGdyaWQtdGVtcGxh
;dGUtY29sdW1uczogdmFyKC0tc2lkZS13KSBtaW5tYXgoMCwgMWZyKTsgbWluLWhlaWdodDogMDsgYmFja2dyb3VuZDogdmFyKC0tY2hyb21lKTsgcGFkZGlu
;ZzogMCAxMHB4IDAgMDsgYm94LXNpemluZzogYm9yZGVyLWJveDsgfQojY29udGVudC1wYW5lIHsKICBkaXNwbGF5OiBncmlkOwogIGdyaWQtdGVtcGxhdGUt
;Y29sdW1uczogbWlubWF4KDI4MHB4LCAxLjFmcikgbWlubWF4KDMyMHB4LCAxLjJmcik7CiAgbWluLXdpZHRoOiAwOyBtaW4taGVpZ2h0OiAwOwogIGJhY2tn
;cm91bmQ6ICNmZmY7CiAgYm9yZGVyOiAxcHggc29saWQgI2Q4ZGRlNjsKICBib3JkZXItcmFkaXVzOiA0cHg7CiAgb3ZlcmZsb3c6IGhpZGRlbjsKfQojbWFp
;bi5tb2RlLXRvb2wgI2NvbnRlbnQtcGFuZSB7CiAgZ3JpZC10ZW1wbGF0ZS1jb2x1bW5zOiAxZnI7Cn0KI21haW4ubW9kZS1oYW5kbGUgI3ByZXZpZXcgeyBk
;aXNwbGF5OiBub25lOyB9CgovKiBzaWRlICovCiNzaWRlIHsKICBiYWNrZ3JvdW5kOiB2YXIoLS1jaHJvbWUpOyBib3JkZXItcmlnaHQ6IDA7CiAgZGlzcGxh
;eTogZmxleDsgZmxleC1kaXJlY3Rpb246IGNvbHVtbjsgcGFkZGluZzogMTBweCA4cHg7IGdhcDogMnB4Owp9Ci5jYXQgewogIGRpc3BsYXk6IGZsZXg7IGFs
;aWduLWl0ZW1zOiBjZW50ZXI7IGdhcDogMTBweDsgaGVpZ2h0OiA0MnB4OyBwYWRkaW5nOiAwIDEwcHg7CiAgYm9yZGVyOiAwOyBib3JkZXItcmFkaXVzOiA4
;cHg7IGJhY2tncm91bmQ6IHRyYW5zcGFyZW50OyBjb2xvcjogdmFyKC0tdHh0KTsgY3Vyc29yOiBwb2ludGVyOwogIHRleHQtYWxpZ246IGxlZnQ7IHBvc2l0
;aW9uOiByZWxhdGl2ZTsKfQouY2F0OmhvdmVyIHsgYmFja2dyb3VuZDogI2VlZjFmNjsgfQouY2F0Lm9uIHsgYmFja2dyb3VuZDogI2U4ZWJmMjsgZm9udC13
;ZWlnaHQ6IDYwMDsgfQouY2F0Lm9uOjpiZWZvcmUgewogIGNvbnRlbnQ6ICIiOyBwb3NpdGlvbjogYWJzb2x1dGU7IGxlZnQ6IDA7IHRvcDogOHB4OyBib3R0
;b206IDhweDsgd2lkdGg6IDNweDsKICBib3JkZXItcmFkaXVzOiAycHg7IGJhY2tncm91bmQ6IHZhcigtLWFjYyk7Cn0KLmNhdCAuaWNvIHsKICB3aWR0aDog
;MzJweDsgaGVpZ2h0OiAzMnB4OyBmbGV4LXNocmluazogMDsKICBkaXNwbGF5OiBpbmxpbmUtZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsganVzdGlmeS1j
;b250ZW50OiBjZW50ZXI7CiAgY29sb3I6IHZhcigtLXR4dDIpOyBmb250LXNpemU6IDE0cHg7IGxpbmUtaGVpZ2h0OiAxOwp9Ci5jYXQgaW1nLmljbyB7CiAg
;d2lkdGg6IDMycHg7IGhlaWdodDogMzJweDsKICBvYmplY3QtZml0OiBjb250YWluOyBpbWFnZS1yZW5kZXJpbmc6IGF1dG87Cn0KCi5zaWRlLXNlcCB7CiAg
;aGVpZ2h0OiAxcHg7IG1hcmdpbjogOHB4IDEwcHg7IGJhY2tncm91bmQ6IHZhcigtLWxpbmUpOyBmbGV4LXNocmluazogMDsKfQojbGlzdC1wYW5lIHsgcG9z
;aXRpb246IHJlbGF0aXZlOyB9CiNmaWxlLXJlc3VsdHMgeyBkaXNwbGF5OiBmbGV4OyBmbGV4LWRpcmVjdGlvbjogY29sdW1uOyBmbGV4OiAxOyBtaW4taGVp
;Z2h0OiAwOyB9CiNmaWxlLXJlc3VsdHMuaGlkZGVuIHsgZGlzcGxheTogbm9uZSAhaW1wb3J0YW50OyB9CiNoYW5kbGUtcGFuZWwuZW1iZWRkZWQgewogIGZs
;ZXg6IDE7IG1pbi1oZWlnaHQ6IDA7IG1hcmdpbjogMDsgYm9yZGVyOiAwOyBib3JkZXItcmFkaXVzOiAwOwogIGRpc3BsYXk6IGZsZXg7IGZsZXgtZGlyZWN0
;aW9uOiBjb2x1bW47IG92ZXJmbG93OiBoaWRkZW47IGJhY2tncm91bmQ6ICNmZmY7Cn0KI2hhbmRsZS1wYW5lbC5lbWJlZGRlZC5oaWRkZW4geyBkaXNwbGF5
;OiBub25lICFpbXBvcnRhbnQ7IH0KI2luZm8tcGFuZWwuZW1iZWRkZWQgewogIGZsZXg6IDE7IG1pbi1oZWlnaHQ6IDA7IG92ZXJmbG93OiBhdXRvOyBwYWRk
;aW5nOiA4cHggMTZweCAxMnB4OyBiYWNrZ3JvdW5kOiAjZmZmOwogIGJvcmRlcjogMDsgbWFyZ2luOiAwOwp9CiNpbmZvLXBhbmVsLmVtYmVkZGVkLmhpZGRl
;biB7IGRpc3BsYXk6IG5vbmUgIWltcG9ydGFudDsgfQojbWFpbi5tb2RlLXRvb2wgI3ByZXZpZXcgeyBkaXNwbGF5OiBub25lOyB9CiNtYWluLm1vZGUtdG9v
;bCB7CiAgZ3JpZC10ZW1wbGF0ZS1jb2x1bW5zOiB2YXIoLS1zaWRlLXcpIG1pbm1heCgwLCAxZnIpOwp9CiNiYXIubW9kZS10b29sIC5zb3J0LCAjYmFyLm1v
;ZGUtdG9vbCAudG9nZ2xlIHsgZGlzcGxheTogbm9uZTsgfQojYmFyLm1vZGUtaW5mbyAuc29ydCwgI2Jhci5tb2RlLWluZm8gLnRvZ2dsZSB7IGRpc3BsYXk6
;IG5vbmU7IH0KI3ZpZXctcHJvYyB7IGRpc3BsYXk6IG5vbmUgIWltcG9ydGFudDsgfQojYnRuLWdvdG8tcHJvYyB7IGRpc3BsYXk6IG5vbmUgIWltcG9ydGFu
;dDsgfQojc2lkZS1mb290IHsgZGlzcGxheTogbm9uZTsgfQojYnRuLXNldHRpbmdzIHsKICB3aWR0aDogMzRweDsgaGVpZ2h0OiAzNHB4OyBib3JkZXI6IDA7
;IGJvcmRlci1yYWRpdXM6IDhweDsgYmFja2dyb3VuZDogdHJhbnNwYXJlbnQ7CiAgY29sb3I6IHZhcigtLXR4dDIpOyBjdXJzb3I6IHBvaW50ZXI7Cn0KI2J0
;bi1zZXR0aW5nczpob3ZlciB7IGJhY2tncm91bmQ6ICNlZWYxZjY7IGNvbG9yOiB2YXIoLS10eHQpOyB9CgovKiBsaXN0ICovCiNsaXN0LXBhbmUgewogIGRp
;c3BsYXk6IGZsZXg7IGZsZXgtZGlyZWN0aW9uOiBjb2x1bW47IG1pbi13aWR0aDogMDsgbWluLWhlaWdodDogMDsKICBiYWNrZ3JvdW5kOiAjZmZmOyBib3Jk
;ZXI6IDA7IG92ZXJmbG93OiBoaWRkZW47CiAgYm9yZGVyLXJhZGl1czogMDsgYm94LXNoYWRvdzogbm9uZTsgb3V0bGluZTogbm9uZTsKfQojbGlzdCB7CiAg
;ZmxleDogMTsgbWluLWhlaWdodDogMDsgb3ZlcmZsb3cteTogYXV0bzsgb3ZlcmZsb3cteDogaGlkZGVuOyBwYWRkaW5nOiA0cHggMDsKICAtd2Via2l0LW92
;ZXJmbG93LXNjcm9sbGluZzogdG91Y2g7Cn0KLnJvdyB7CiAgZGlzcGxheTogZ3JpZDsgZ3JpZC10ZW1wbGF0ZS1jb2x1bW5zOiA0MHB4IDFmcjsgZ2FwOiAx
;MHB4OwogIGFsaWduLWl0ZW1zOiBjZW50ZXI7IG1pbi1oZWlnaHQ6IDQ0cHg7CiAgcGFkZGluZzogNnB4IDE0cHg7IGN1cnNvcjogcG9pbnRlcjsgYm9yZGVy
;LWxlZnQ6IDNweCBzb2xpZCB0cmFuc3BhcmVudDsKfQoucm93OmhvdmVyIHsgYmFja2dyb3VuZDogI2Y3ZjhmYjsgfQoucm93Lm9uIHsgYmFja2dyb3VuZDog
;dmFyKC0tc2VsKTsgYm9yZGVyLWxlZnQtY29sb3I6IHZhcigtLWFjYyk7IH0KLnJvdyAuZmkgewogIHdpZHRoOiAzMnB4OyBoZWlnaHQ6IDMycHg7CiAgY29s
;b3I6IHZhcigtLXR4dDIpOyBkaXNwbGF5OiBncmlkOyBwbGFjZS1pdGVtczogY2VudGVyOyBmbGV4LXNocmluazogMDsKfQoucm93IC5maSBpbWcgewogIHdp
;ZHRoOiAzMnB4OyBoZWlnaHQ6IDMycHg7CiAgb2JqZWN0LWZpdDogY29udGFpbjsgZGlzcGxheTogYmxvY2s7IGJhY2tncm91bmQ6IHRyYW5zcGFyZW50Owog
;IGltYWdlLXJlbmRlcmluZzogYXV0bzsKfQoucm93IC5maSAuZmktZmFsbGJhY2sgeyBmb250LXNpemU6IDE4cHg7IGxpbmUtaGVpZ2h0OiAxOyB9Ci5yb3cg
;Lm5hbWUgeyBjb2xvcjogdmFyKC0tbmFtZSk7IGZvbnQtc2l6ZTogMTMuNXB4OyBmb250LXdlaWdodDogNjAwOyB3b3JkLWJyZWFrOiBicmVhay1hbGw7IGxp
;bmUtaGVpZ2h0OiAxLjM1OyB9Ci5yb3cgLm5hbWUgLmV4dCB7IGNvbG9yOiB2YXIoLS1uYW1lLWV4dCk7IH0KLnJvdyAubmFtZSBtYXJrLCAucm93IC5wYXRo
;IG1hcmsgewogIGJhY2tncm91bmQ6IHZhcigtLWhsKTsgY29sb3I6IHZhcigtLWhsLXRleHQpOyBwYWRkaW5nOiAwIDFweDsgYm9yZGVyLXJhZGl1czogMnB4
;OwogIGZvbnQtd2VpZ2h0OiA3MDA7Cn0KLnJvdyAucGF0aCB7IGNvbG9yOiAjNGI1NTYzOyBmb250LXNpemU6IDEycHg7IG1hcmdpbi10b3A6IDJweDsgd29y
;ZC1icmVhazogYnJlYWstYWxsOyB9CiNsaXN0LWVtcHR5IHsKICBkaXNwbGF5OiBub25lOyBmbGV4OiAxOyBhbGlnbi1pdGVtczogY2VudGVyOyBqdXN0aWZ5
;LWNvbnRlbnQ6IGNlbnRlcjsKICBjb2xvcjogdmFyKC0tdHh0Myk7IGZvbnQtc2l6ZTogMTRweDsKfQojbGlzdC1lbXB0eS5vbiB7IGRpc3BsYXk6IGZsZXg7
;IH0KCi8qIHByZXZpZXcgKi8KI3ByZXZpZXcgewogIGJhY2tncm91bmQ6ICNmZmY7IG1pbi13aWR0aDogMDsgbWluLWhlaWdodDogMDsgZGlzcGxheTogZmxl
;eDsgZmxleC1kaXJlY3Rpb246IGNvbHVtbjsgb3ZlcmZsb3c6IGhpZGRlbjsKICBib3JkZXI6IDA7IGJvcmRlci1yYWRpdXM6IDA7IGJveC1zaGFkb3c6IG5v
;bmU7IG91dGxpbmU6IG5vbmU7Cn0KI3ByZXZpZXcub2ZmIC5wdi1ib2R5IHsgZGlzcGxheTogbm9uZTsgfQojcHJldmlldy5vZmYgLnB2LW9mZiB7CiAgZGlz
;cGxheTogZmxleDsgZmxleDogMTsgYWxpZ24taXRlbXM6IGNlbnRlcjsganVzdGlmeS1jb250ZW50OiBjZW50ZXI7IGNvbG9yOiB2YXIoLS10eHQzKTsKfQou
;cHYtb2ZmIHsgZGlzcGxheTogbm9uZTsgfQoucHYtbWV0YSB7CiAgZGlzcGxheTogZmxleDsgZ2FwOiAxNHB4OyBhbGlnbi1pdGVtczogY2VudGVyOyBwYWRk
;aW5nOiAxMHB4IDE0cHg7CiAgYm9yZGVyLWJvdHRvbTogMXB4IHNvbGlkIHZhcigtLWxpbmUpOyBjb2xvcjogdmFyKC0tdHh0Mik7IGZvbnQtc2l6ZTogMTJw
;eDsgZmxleC13cmFwOiB3cmFwOwp9Ci5wdi1tZXRhIGIgeyBjb2xvcjogdmFyKC0tdHh0KTsgZm9udC13ZWlnaHQ6IDYwMDsgfQoucHYtbWV0YSAuZHJ2IHsK
;ICBkaXNwbGF5OiBpbmxpbmUtZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsgZ2FwOiA2cHg7CiAgY29sb3I6IHZhcigtLXR4dCk7IGZvbnQtd2VpZ2h0OiA2
;MDA7Cn0KLnB2LW1ldGEgLmRydiBpbWcgewogIHdpZHRoOiAxNnB4OyBoZWlnaHQ6IDE2cHg7IG9iamVjdC1maXQ6IGNvbnRhaW47IGJhY2tncm91bmQ6IHRy
;YW5zcGFyZW50OyBmbGV4LXNocmluazogMDsKfQoucHYtYm9keSB7IGZsZXg6IDE7IG1pbi1oZWlnaHQ6IDA7IGRpc3BsYXk6IGZsZXg7IGZsZXgtZGlyZWN0
;aW9uOiBjb2x1bW47IH0KLnB2LW1lZGlhIHsKICBmbGV4OiAxOyBtaW4taGVpZ2h0OiAwOyBiYWNrZ3JvdW5kOiAjM2Y0NDUwOyBkaXNwbGF5OiBmbGV4OyBh
;bGlnbi1pdGVtczogY2VudGVyOyBqdXN0aWZ5LWNvbnRlbnQ6IGNlbnRlcjsKICBvdmVyZmxvdzogaGlkZGVuOyBwb3NpdGlvbjogcmVsYXRpdmU7Cn0KLnB2
;LW1lZGlhLmNvbXBhY3QgewogIGZsZXg6IDAgMCBhdXRvOyBtaW4taGVpZ2h0OiAwOyBoZWlnaHQ6IDA7IHBhZGRpbmc6IDA7IG92ZXJmbG93OiBoaWRkZW47
;CiAgYm9yZGVyOiAwOwp9Ci5wdi1ib2R5LnRleHQtbW9kZSAucHYtbWVkaWEgeyBkaXNwbGF5OiBub25lOyB9Ci5wdi1ib2R5LnRleHQtbW9kZSAucHYtdGV4
;dCB7CiAgZmxleDogMTsgZGlzcGxheTogZmxleDsgYm9yZGVyLXRvcDogMDsgbWluLWhlaWdodDogMDsKfQoucHYtbWVkaWEgaW1nLCAucHYtbWVkaWEgdmlk
;ZW8gewogIG1heC13aWR0aDogMTAwJTsgbWF4LWhlaWdodDogMTAwJTsgb2JqZWN0LWZpdDogY29udGFpbjsgYmFja2dyb3VuZDogIzExMTsKfQoucHYtbWVk
;aWEgLnB2LWZpbGVpbmZvIGltZy5iaWctaWNvIHsKICBiYWNrZ3JvdW5kOiB0cmFuc3BhcmVudCAhaW1wb3J0YW50OwogIG1heC13aWR0aDogNDhweDsgbWF4
;LWhlaWdodDogNDhweDsKfQoucHYtbWVkaWEgZW1iZWQucGRmLCAucHYtbWVkaWEgaWZyYW1lLnBkZiB7CiAgd2lkdGg6IDEwMCU7IGhlaWdodDogMTAwJTsg
;Ym9yZGVyOiAwOyBiYWNrZ3JvdW5kOiAjNTI1NjU5Owp9Ci5wdi1tZWRpYSAucGggeyBjb2xvcjogI2NiZDVlMTsgZm9udC1zaXplOiAxM3B4OyB9Ci5wdi1m
;aWxlaW5mbyB7CiAgZGlzcGxheTogZmxleDsgZmxleC1kaXJlY3Rpb246IGNvbHVtbjsgYWxpZ24taXRlbXM6IHN0cmV0Y2g7IGp1c3RpZnktY29udGVudDog
;Y2VudGVyOwogIGdhcDogMTBweDsgcGFkZGluZzogMjhweCAyNHB4OyB0ZXh0LWFsaWduOiBsZWZ0OyB3aWR0aDogMTAwJTsgaGVpZ2h0OiAxMDAlOwogIGJv
;eC1zaXppbmc6IGJvcmRlci1ib3g7IG92ZXJmbG93OiBhdXRvOwogIGJhY2tncm91bmQ6ICNmN2Y4ZmI7IGNvbG9yOiB2YXIoLS10eHQpOwp9Ci5wdi1maWxl
;aW5mbyAuYmlnLWljbyB7CiAgd2lkdGg6IDQ4cHg7IGhlaWdodDogNDhweDsgb2JqZWN0LWZpdDogY29udGFpbjsgYWxpZ24tc2VsZjogY2VudGVyOwogIGJh
;Y2tncm91bmQ6IHRyYW5zcGFyZW50ICFpbXBvcnRhbnQ7CiAgaW1hZ2UtcmVuZGVyaW5nOiBhdXRvOyBmbGV4LXNocmluazogMDsKfQoucHYtbWVkaWE6aGFz
;KC5wdi1maWxlaW5mbykgeyBiYWNrZ3JvdW5kOiAjZjdmOGZiOyB9Ci5wdi1maWxlaW5mbyAuZm4gewogIGZvbnQtc2l6ZTogMTZweDsgZm9udC13ZWlnaHQ6
;IDY1MDsgY29sb3I6IHZhcigtLXR4dCk7CiAgd29yZC1icmVhazogYnJlYWstYWxsOyB0ZXh0LWFsaWduOiBjZW50ZXI7IHdpZHRoOiAxMDAlOyBsaW5lLWhl
;aWdodDogMS4zNTsKfQoucHYtZmlsZWluZm8gLnRuIHsKICBmb250LXNpemU6IDEycHg7IGNvbG9yOiB2YXIoLS10eHQyKTsgdGV4dC1hbGlnbjogY2VudGVy
;OyB3aWR0aDogMTAwJTsKfQoucHYtZmlsZWluZm8gLmhpbnQgewogIGZvbnQtc2l6ZTogMTJweDsgY29sb3I6ICNiNDUzMDk7IHRleHQtYWxpZ246IGNlbnRl
;cjsgd2lkdGg6IDEwMCU7IGxpbmUtaGVpZ2h0OiAxLjQ1Owp9Ci5wdi1maWxlaW5mbyAua3YgewogIGRpc3BsYXk6IGZsZXg7IGZsZXgtZGlyZWN0aW9uOiBj
;b2x1bW47IGdhcDogOHB4OwogIG1hcmdpbi10b3A6IDZweDsgd2lkdGg6IDEwMCU7IGZvbnQtc2l6ZTogMTIuNXB4OyBjb2xvcjogdmFyKC0tdHh0Mik7Cn0K
;LnB2LWZpbGVpbmZvIC5rdi1yb3cgewogIGRpc3BsYXk6IGdyaWQ7IGdyaWQtdGVtcGxhdGUtY29sdW1uczogNC41ZW0gMWZyOyBnYXA6IDEycHg7IGFsaWdu
;LWl0ZW1zOiBzdGFydDsKICBsaW5lLWhlaWdodDogMS41NTsKfQoucHYtZmlsZWluZm8gLmt2LXJvdyAuayB7IGNvbG9yOiB2YXIoLS10eHQyKTsgd2hpdGUt
;c3BhY2U6IG5vd3JhcDsgfQoucHYtZmlsZWluZm8gLmt2LXJvdyAudiB7IGNvbG9yOiB2YXIoLS10eHQpOyB3b3JkLWJyZWFrOiBicmVhay1hbGw7IGZvbnQt
;d2VpZ2h0OiA1MDA7IH0KLnB2LWZpbGVpbmZvIC5raWRzIHsKICBtYXJnaW4tdG9wOiA4cHg7IGZvbnQtc2l6ZTogMTIuNXB4OyBjb2xvcjogdmFyKC0tdHh0
;Mik7IGxpbmUtaGVpZ2h0OiAxLjY7CiAgd29yZC1icmVhazogYnJlYWstYWxsOwp9Ci5wdi1maWxlaW5mbyAua2lkcyBiIHsgY29sb3I6IHZhcigtLXR4dCk7
;IGZvbnQtd2VpZ2h0OiA2MDA7IH0KCi8qIGNvbnRleHQgbWVudSAqLwojY3R4IHsKICBkaXNwbGF5OiBub25lOyBwb3NpdGlvbjogZml4ZWQ7IHotaW5kZXg6
;IDIwMDsgbWluLXdpZHRoOiAxNjhweDsKICBwYWRkaW5nOiA0cHg7IGJhY2tncm91bmQ6ICNmZmY7IGJvcmRlcjogMXB4IHNvbGlkIHZhcigtLWxpbmUpOwog
;IGJvcmRlci1yYWRpdXM6IDhweDsgYm94LXNoYWRvdzogMCA4cHggMjRweCByZ2JhKDE1LDIzLDQyLC4xMik7Cn0KI2N0eC5vbiB7IGRpc3BsYXk6IGJsb2Nr
;OyB9CiNjdHggYnV0dG9uIHsKICBkaXNwbGF5OiBmbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBnYXA6IDEwcHg7IHdpZHRoOiAxMDAlOwogIGJvcmRlcjog
;MDsgYmFja2dyb3VuZDogdHJhbnNwYXJlbnQ7IHBhZGRpbmc6IDhweCAxMHB4OyBib3JkZXItcmFkaXVzOiA2cHg7CiAgY3Vyc29yOiBwb2ludGVyOyBjb2xv
;cjogdmFyKC0tdHh0KTsgZm9udC1zaXplOiAxM3B4OyB0ZXh0LWFsaWduOiBsZWZ0Owp9CiNjdHggYnV0dG9uOmhvdmVyIHsgYmFja2dyb3VuZDogI2YzZjRm
;NjsgfQojY3R4IGJ1dHRvbi5kYW5nZXIgeyBjb2xvcjogI2RjMjYyNjsgfQojY3R4IGJ1dHRvbi5kYW5nZXI6aG92ZXIgeyBiYWNrZ3JvdW5kOiAjZmVmMmYy
;OyB9CiNjdHggLmMtaWNvIHsKICB3aWR0aDogMTZweDsgaGVpZ2h0OiAxNnB4OyBmbGV4LXNocmluazogMDsKICBkaXNwbGF5OiBpbmxpbmUtZmxleDsgYWxp
;Z24taXRlbXM6IGNlbnRlcjsganVzdGlmeS1jb250ZW50OiBjZW50ZXI7CiAgY29sb3I6ICMzNzQxNTE7Cn0KI2N0eCBidXR0b24uZGFuZ2VyIC5jLWljbyB7
;IGNvbG9yOiAjZGMyNjI2OyB9CiNjdHggLmMtaWNvIHN2ZyB7IHdpZHRoOiAxNnB4OyBoZWlnaHQ6IDE2cHg7IGRpc3BsYXk6IGJsb2NrOyB9CgoucHYtdGV4
;dCB7CiAgZmxleDogMTsgbWluLWhlaWdodDogMDsgZGlzcGxheTogZmxleDsgZmxleC1kaXJlY3Rpb246IGNvbHVtbjsgYm9yZGVyLXRvcDogMXB4IHNvbGlk
;IHZhcigtLWxpbmUpOwp9Ci5wdi10ZXh0IC5oZCB7CiAgcGFkZGluZzogOHB4IDE0cHg7IGZvbnQtc2l6ZTogMTJweDsgY29sb3I6IHZhcigtLXR4dDIpOyBi
;YWNrZ3JvdW5kOiAjZmFmYmZjOyBib3JkZXItYm90dG9tOiAxcHggc29saWQgdmFyKC0tbGluZSk7Cn0KLnB2LXRleHQgcHJlIHsKICBtYXJnaW46IDA7IGZs
;ZXg6IDE7IG92ZXJmbG93OiBhdXRvOyBwYWRkaW5nOiAxMnB4IDE0cHg7IGZvbnQtc2l6ZTogMTJweDsgbGluZS1oZWlnaHQ6IDEuNTsKICB3aGl0ZS1zcGFj
;ZTogcHJlLXdyYXA7IHdvcmQtYnJlYWs6IGJyZWFrLXdvcmQ7IGZvbnQtZmFtaWx5OiBDb25zb2xhcywgIlNhcmFzYSBNb25vIFNDIiwgbW9ub3NwYWNlOwog
;IGJhY2tncm91bmQ6ICNmZmY7IGNvbG9yOiAjMTExODI3Owp9CgovKiBib3R0b23vvJrorr7nva7lnKjlt6bkuIvop5LvvIzmjpLluo8v6aKE6KeI57Sn5oyo
;6K6+572u5bm255WZ56m66ZqZICovCiNiYXIgewogIGhlaWdodDogNDJweDsgZGlzcGxheTogZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsgZ2FwOiAwOwog
;IHBhZGRpbmc6IDAgMTRweCAwIDEwcHg7IGJhY2tncm91bmQ6IHZhcigtLWNocm9tZSk7IGJvcmRlci10b3A6IDA7IGZvbnQtc2l6ZTogMTIuNXB4OyBjb2xv
;cjogdmFyKC0tdHh0Mik7Cn0KI2JhciAuYmFyLWxlZnQgewogIGZsZXgtc2hyaW5rOiAwOyBoZWlnaHQ6IDEwMCU7CiAgZGlzcGxheTogZmxleDsgYWxpZ24t
;aXRlbXM6IGNlbnRlcjsKfQojYmFyIC5iYXItbWFpbiB7CiAgZmxleDogMTsgbWluLXdpZHRoOiAwOyBoZWlnaHQ6IDEwMCU7CiAgZGlzcGxheTogZmxleDsg
;YWxpZ24taXRlbXM6IGNlbnRlcjsgZ2FwOiAxNnB4OwogIG1hcmdpbi1sZWZ0OiAxOHB4OyBib3gtc2l6aW5nOiBib3JkZXItYm94Owp9CiNiYXIgLnNvcnQg
;eyBkaXNwbGF5OiBpbmxpbmUtZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsgZ2FwOiA2cHg7IGN1cnNvcjogcG9pbnRlcjsgYm9yZGVyOiAwOyBiYWNrZ3Jv
;dW5kOiB0cmFuc3BhcmVudDsgY29sb3I6IGluaGVyaXQ7IH0KI2JhciAuc29ydDpob3ZlciB7IGNvbG9yOiB2YXIoLS10eHQpOyB9CiNiYXIgLnNwYWNlciB7
;IGZsZXg6IDE7IH0KLnRvZ2dsZSB7CiAgZGlzcGxheTogaW5saW5lLWZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGdhcDogOHB4OyBjdXJzb3I6IHBvaW50
;ZXI7IHVzZXItc2VsZWN0OiBub25lOwp9Ci50b2dnbGUgaW5wdXQgeyBkaXNwbGF5OiBub25lOyB9Ci50b2dnbGUgLnN3IHsKICB3aWR0aDogMzZweDsgaGVp
;Z2h0OiAyMHB4OyBib3JkZXItcmFkaXVzOiA5OTlweDsgYmFja2dyb3VuZDogI2QxZDVkYjsgcG9zaXRpb246IHJlbGF0aXZlOyB0cmFuc2l0aW9uOiAuMnM7
;Cn0KLnRvZ2dsZSAuc3c6OmFmdGVyIHsKICBjb250ZW50OiAiIjsgcG9zaXRpb246IGFic29sdXRlOyB0b3A6IDJweDsgbGVmdDogMnB4OyB3aWR0aDogMTZw
;eDsgaGVpZ2h0OiAxNnB4OwogIGJvcmRlci1yYWRpdXM6IDUwJTsgYmFja2dyb3VuZDogI2ZmZjsgdHJhbnNpdGlvbjogLjJzOyBib3gtc2hhZG93OiAwIDFw
;eCAycHggcmdiYSgwLDAsMCwuMik7Cn0KLnRvZ2dsZSBpbnB1dDpjaGVja2VkICsgLnN3IHsgYmFja2dyb3VuZDogdmFyKC0tYWNjKTsgfQoudG9nZ2xlIGlu
;cHV0OmNoZWNrZWQgKyAuc3c6OmFmdGVyIHsgbGVmdDogMThweDsgfQojY291bnQgeyBjb2xvcjogdmFyKC0tdHh0KTsgZm9udC12YXJpYW50LW51bWVyaWM6
;IHRhYnVsYXItbnVtczsgfQo8L3N0eWxlPgo8L2hlYWQ+Cjxib2R5Pgo8ZGl2IGlkPSJhcHAiIGNsYXNzPSJib290aW5nIj4KICA8ZGl2IGlkPSJ0aXRsZWJh
;ciI+CiAgICA8ZGl2IGNsYXNzPSJ0Yi1icmFuZCBuby1kcmFnIiB0aXRsZT0i5Luq6KGo55uYIj4KICAgICAgPHN2ZyBjbGFzcz0idGItaWNvIiB2aWV3Qm94
;PSIwIDAgMTYgMTYiIGZpbGw9Im5vbmUiIGFyaWEtaGlkZGVuPSJ0cnVlIj4KICAgICAgICA8Y2lyY2xlIGN4PSI4IiBjeT0iOSIgcj0iNS4yIiBzdHJva2U9
;ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIxLjQiLz4KICAgICAgICA8cGF0aCBkPSJNOCA5bDMuMi0zLjIiIHN0cm9rZT0iY3VycmVudENvbG9yIiBz
;dHJva2Utd2lkdGg9IjEuNCIgc3Ryb2tlLWxpbmVjYXA9InJvdW5kIi8+CiAgICAgICAgPGNpcmNsZSBjeD0iOCIgY3k9IjkiIHI9IjEuMTUiIGZpbGw9ImN1
;cnJlbnRDb2xvciIvPgogICAgICA8L3N2Zz4KICAgICAgPHNwYW4gY2xhc3M9InRiLW5hbWUiPuS7quihqOebmDwvc3Bhbj4KICAgIDwvZGl2PgogICAgPGRp
;diBpZD0iZmlsdGVyLXJhaWwiIGNsYXNzPSJuby1kcmFnIj4KICAgICAgPGJ1dHRvbiBpZD0iYnRuLWZpbHRlci10b2dnbGUiIHR5cGU9ImJ1dHRvbiIgdGl0
;bGU9IuWxleW8gOetm+mAieadoeS7tiIgYXJpYS1sYWJlbD0i5bGV5byA562b6YCJ5p2h5Lu2Ij4KICAgICAgICA8c3ZnIHZpZXdCb3g9IjAgMCAxNiAxNiIg
;ZmlsbD0ibm9uZSIgYXJpYS1oaWRkZW49InRydWUiPgogICAgICAgICAgPHBhdGggZD0iTTUgNiBMOCA5IEwxMSA2IiBzdHJva2U9ImN1cnJlbnRDb2xvciIg
;c3Ryb2tlLXdpZHRoPSIxLjM1IiBzdHJva2UtbGluZWNhcD0icm91bmQiIHN0cm9rZS1saW5lam9pbj0icm91bmQiLz4KICAgICAgICA8L3N2Zz4KICAgICAg
;PC9idXR0b24+CiAgICAgIDxkaXYgaWQ9ImZpbHRlci1iYXIiIGFyaWEtbGFiZWw9IuaQnOe0ouetm+mAiSI+PC9kaXY+CiAgICA8L2Rpdj4KICAgIDxkaXYg
;Y2xhc3M9InRiLXNwYWNlIiBpZD0idGl0bGViYXItZHJhZyI+PC9kaXY+CiAgICA8ZGl2IGNsYXNzPSJ0Yi13aW4gbm8tZHJhZyI+CiAgICAgIDxidXR0b24g
;dHlwZT0iYnV0dG9uIiBpZD0iYnRuLXdpbi1taW4iIHRpdGxlPSLmnIDlsI/ljJYiIGFyaWEtbGFiZWw9IuacgOWwj+WMliI+CiAgICAgICAgPHN2ZyB2aWV3
;Qm94PSIwIDAgMTAgMTAiIGZpbGw9Im5vbmUiIGFyaWEtaGlkZGVuPSJ0cnVlIj48cGF0aCBkPSJNMS41IDVoNyIgc3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0
;cm9rZS13aWR0aD0iMS4yIiBzdHJva2UtbGluZWNhcD0icm91bmQiLz48L3N2Zz4KICAgICAgPC9idXR0b24+CiAgICAgIDxidXR0b24gdHlwZT0iYnV0dG9u
;IiBpZD0iYnRuLXdpbi1tYXgiIHRpdGxlPSLmnIDlpKfljJYiIGFyaWEtbGFiZWw9IuacgOWkp+WMliI+CiAgICAgICAgPHN2ZyB2aWV3Qm94PSIwIDAgMTAg
;MTAiIGZpbGw9Im5vbmUiIGFyaWEtaGlkZGVuPSJ0cnVlIj48cmVjdCB4PSIxLjYiIHk9IjEuNiIgd2lkdGg9IjYuOCIgaGVpZ2h0PSI2LjgiIHJ4PSIwLjYi
;IHN0cm9rZT0iY3VycmVudENvbG9yIiBzdHJva2Utd2lkdGg9IjEuMiIvPjwvc3ZnPgogICAgICA8L2J1dHRvbj4KICAgICAgPGJ1dHRvbiB0eXBlPSJidXR0
;b24iIGlkPSJidG4td2luLWNsb3NlIiB0aXRsZT0i5YWz6ZetIiBhcmlhLWxhYmVsPSLlhbPpl60iPgogICAgICAgIDxzdmcgdmlld0JveD0iMCAwIDEwIDEw
;IiBmaWxsPSJub25lIiBhcmlhLWhpZGRlbj0idHJ1ZSI+PHBhdGggZD0iTTIgMmw2IDZNOCAyTDIgOCIgc3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0cm9rZS13
;aWR0aD0iMS4yIiBzdHJva2UtbGluZWNhcD0icm91bmQiLz48L3N2Zz4KICAgICAgPC9idXR0b24+CiAgICA8L2Rpdj4KICA8L2Rpdj4KICA8ZGl2IGlkPSJi
;b290IiBjbGFzcz0ib24iPgogICAgPGRpdiBjbGFzcz0icmluZy13cmFwIj4KICAgICAgPHN2ZyB2aWV3Qm94PSIwIDAgMTIwIDEyMCI+CiAgICAgICAgPGNp
;cmNsZSBjbGFzcz0icmluZy1iZyIgY3g9IjYwIiBjeT0iNjAiIHI9IjUyIj48L2NpcmNsZT4KICAgICAgICA8Y2lyY2xlIGlkPSJyaW5nLWZnIiBjbGFzcz0i
;cmluZy1mZyIgY3g9IjYwIiBjeT0iNjAiIHI9IjUyIgogICAgICAgICAgc3Ryb2tlLWRhc2hhcnJheT0iMzI2LjczIiBzdHJva2UtZGFzaG9mZnNldD0iMzI2
;LjczIj48L2NpcmNsZT4KICAgICAgPC9zdmc+CiAgICAgIDxkaXYgY2xhc3M9InJpbmctbGFiZWwiPgogICAgICAgIDxkaXYgY2xhc3M9InQxIj7no4Hnm5jn
;tKLlvJXkuK08L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJ0MiIgaWQ9ImJvb3QtcGN0Ij7igKY8L2Rpdj4KICAgICAgPC9kaXY+CiAgICA8L2Rpdj4KICAg
;IDxkaXYgY2xhc3M9ImJvb3QtaGludCI+CiAgICAgIOato+WcqOW7uueri+ejgeebmOaWh+S7tue0ouW8le+8jOWujOaIkOWQjuWNs+WPr+aQnOe0ouOAgjxi
;cj4KICAgICAg6Iul5pys5py65bey5a6J6KOFIEV2ZXJ5dGhpbmcg5bm25byA5py65ZCv5Yqo77yM5LiL5qyh5Lya5pu05b+r5bCx57uq44CCCiAgICA8L2Rp
;dj4KICA8L2Rpdj4KCiAgPGRpdiBpZD0iY2hyb21lIiBjbGFzcz0iaGlkZGVuIj4KICAgIDxkaXYgaWQ9InZpZXctc2VhcmNoIj4KICAgIDxkaXYgaWQ9InRv
;cCI+CiAgICAgIDxkaXYgaWQ9ImRyaXZlLXdyYXAiIGNsYXNzPSJuby1kcmFnIj4KICAgICAgICA8YnV0dG9uIGlkPSJidG4tZHJpdmUiIHR5cGU9ImJ1dHRv
;biIgdGl0bGU9IumAieaLqeaQnOe0ouejgeebmCI+CiAgICAgICAgICA8aW1nIGlkPSJkcml2ZS1idG4taWNvIiBjbGFzcz0iZHJpdmUtaWNvIGhpZGRlbiIg
;YWx0PSIiIHdpZHRoPSIyMCIgaGVpZ2h0PSIyMCI+CiAgICAgICAgICA8c3BhbiBpZD0iZHJpdmUtbGFiZWwiPuWFqOebmOaQnOe0ojwvc3Bhbj48c3BhbiBj
;bGFzcz0iY2FyZXQiPuKWvjwvc3Bhbj4KICAgICAgICA8L2J1dHRvbj4KICAgICAgICA8ZGl2IGlkPSJkcml2ZS1tZW51IiByb2xlPSJtZW51Ij48L2Rpdj4K
;ICAgICAgPC9kaXY+CiAgICAgIDxkaXYgaWQ9InRvcC1yZXN0Ij4KICAgICAgICA8ZGl2IGlkPSJzZWFyY2gtd3JhcCIgY2xhc3M9Im5vLWRyYWciPgogICAg
;ICAgICAgPGRpdiBpZD0ic2VhcmNoLWJveCI+CiAgICAgICAgICAgIDxpbnB1dCBpZD0icSIgdHlwZT0idGV4dCIgcGxhY2Vob2xkZXI9Iui+k+WFpeaWh+S7
;tuWQjSAvIOaJqeWxleWQjSAvIOi3r+W+hOWFs+mUruWtl++8m3wg6KGo56S65LiU77yMfHwg6KGo56S65oiWIiBhdXRvY29tcGxldGU9Im9mZiIgc3BlbGxj
;aGVjaz0iZmFsc2UiPgogICAgICAgICAgICA8YnV0dG9uIGlkPSJidG4tY2xlYXIiIHR5cGU9ImJ1dHRvbiIgdGl0bGU9Iua4heepuuaQnOe0oiI+5riF56m6
;PC9idXR0b24+CiAgICAgICAgICAgIDxidXR0b24gaWQ9ImJ0bi1oaXN0IiB0eXBlPSJidXR0b24iIHRpdGxlPSLmnIDov5HmkJzntKIiPuKWvjwvYnV0dG9u
;PgogICAgICAgICAgICA8ZGl2IGlkPSJoaXN0LW1lbnUiIHJvbGU9Im1lbnUiPjwvZGl2PgogICAgICAgICAgPC9kaXY+CiAgICAgICAgPC9kaXY+CiAgICAg
;ICAgPGRpdiBpZD0idG9wLXByZXZpZXciIGNsYXNzPSJuby1kcmFnIj4KICAgICAgICAgIDxkaXYgY2xhc3M9InB2LW1ldGEiIGlkPSJwdi1tZXRhIj7pgInm
;i6nmlofku7bku6XpooTop4g8L2Rpdj4KICAgICAgICA8L2Rpdj4KICAgICAgPC9kaXY+CiAgICA8L2Rpdj4KCiAgICA8ZGl2IGlkPSJtYWluIj4KICAgICAg
;PGFzaWRlIGlkPSJzaWRlIj4KICAgICAgICA8YnV0dG9uIGNsYXNzPSJjYXQgb24iIGRhdGEtY2F0PSJhbGwiPjxzcGFuIGNsYXNzPSJpY28iIGRhdGEtY2F0
;LWljbz0iYWxsIj7imLA8L3NwYW4+5YWo6YOoPC9idXR0b24+CiAgICAgICAgPGJ1dHRvbiBjbGFzcz0iY2F0IiBkYXRhLWNhdD0iZm9sZGVyIj48c3BhbiBj
;bGFzcz0iaWNvIiBkYXRhLWNhdC1pY289ImZvbGRlciI+8J+TgTwvc3Bhbj7mlofku7blpLk8L2J1dHRvbj4KICAgICAgICA8YnV0dG9uIGNsYXNzPSJjYXQi
;IGRhdGEtY2F0PSJleGNlbCI+PHNwYW4gY2xhc3M9ImljbyIgZGF0YS1jYXQtaWNvPSJleGNlbCI+8J+Tijwvc3Bhbj5FWENFTDwvYnV0dG9uPgogICAgICAg
;IDxidXR0b24gY2xhc3M9ImNhdCIgZGF0YS1jYXQ9IndvcmQiPjxzcGFuIGNsYXNzPSJpY28iIGRhdGEtY2F0LWljbz0id29yZCI+8J+ThDwvc3Bhbj5XT1JE
;PC9idXR0b24+CiAgICAgICAgPGJ1dHRvbiBjbGFzcz0iY2F0IiBkYXRhLWNhdD0icHB0Ij48c3BhbiBjbGFzcz0iaWNvIiBkYXRhLWNhdC1pY289InBwdCI+
;8J+TkTwvc3Bhbj5QUFQ8L2J1dHRvbj4KICAgICAgICA8YnV0dG9uIGNsYXNzPSJjYXQiIGRhdGEtY2F0PSJwZGYiPjxzcGFuIGNsYXNzPSJpY28iIGRhdGEt
;Y2F0LWljbz0icGRmIj7wn5OVPC9zcGFuPlBERjwvYnV0dG9uPgogICAgICAgIDxidXR0b24gY2xhc3M9ImNhdCIgZGF0YS1jYXQ9ImltYWdlIj48c3BhbiBj
;bGFzcz0iaWNvIiBkYXRhLWNhdC1pY289ImltYWdlIj7wn5a8PC9zcGFuPuWbvueJhzwvYnV0dG9uPgogICAgICAgIDxidXR0b24gY2xhc3M9ImNhdCIgZGF0
;YS1jYXQ9InZpZGVvIj48c3BhbiBjbGFzcz0iaWNvIiBkYXRhLWNhdC1pY289InZpZGVvIj7ilrY8L3NwYW4+6KeG6aKRPC9idXR0b24+CiAgICAgICAgPGJ1
;dHRvbiBjbGFzcz0iY2F0IiBkYXRhLWNhdD0iYXVkaW8iPjxzcGFuIGNsYXNzPSJpY28iIGRhdGEtY2F0LWljbz0iYXVkaW8iPuKZqjwvc3Bhbj7pn7PpopE8
;L2J1dHRvbj4KICAgICAgICA8YnV0dG9uIGNsYXNzPSJjYXQiIGRhdGEtY2F0PSJ6aXAiPjxzcGFuIGNsYXNzPSJpY28iIGRhdGEtY2F0LWljbz0iemlwIj7w
;n5ecPC9zcGFuPuWOi+e8qeaWh+S7tjwvYnV0dG9uPgogICAgICAgIDxkaXYgY2xhc3M9InNpZGUtc2VwIiByb2xlPSJzZXBhcmF0b3IiPjwvZGl2PgogICAg
;ICAgIDxidXR0b24gY2xhc3M9ImNhdCIgZGF0YS1jYXQ9Il9faGFuZGxlIiB0eXBlPSJidXR0b24iPjxzcGFuIGNsYXNzPSJpY28iPuKbkzwvc3Bhbj7lhbPo
;gZTlj6Xmn4Q8L2J1dHRvbj4KICAgICAgICA8YnV0dG9uIGNsYXNzPSJjYXQiIGRhdGEtY2F0PSJfX2luZm8iIHR5cGU9ImJ1dHRvbiI+PHNwYW4gY2xhc3M9
;ImljbyI+4oS5PC9zcGFuPuacrOacuuS/oeaBrzwvYnV0dG9uPgogICAgICAgIDxkaXYgaWQ9InNpZGUtZm9vdCI+PC9kaXY+CiAgICAgIDwvYXNpZGU+Cgog
;ICAgICA8ZGl2IGlkPSJjb250ZW50LXBhbmUiPgogICAgICAgIDxzZWN0aW9uIGlkPSJsaXN0LXBhbmUiPgogICAgICAgICAgPGRpdiBpZD0iZmlsZS1yZXN1
;bHRzIj4KICAgICAgICAgICAgPGRpdiBpZD0ibGlzdCI+PC9kaXY+CiAgICAgICAgICAgIDxkaXYgaWQ9Imxpc3QtZW1wdHkiPui+k+WFpeWFs+mUruWtl+W8
;gOWni+aQnOe0ou+8jOaIlumAieaLqeW3puS+p+WIhuexu+a1j+iniDwvZGl2PgogICAgICAgICAgPC9kaXY+CiAgICAgICAgICA8ZGl2IGlkPSJoYW5kbGUt
;cGFuZWwiIGNsYXNzPSJoaWRkZW4gbm8tZHJhZyBlbWJlZGRlZCI+CiAgICAgICAgICAgIDxkaXYgY2xhc3M9ImhhbmRsZS1iYW5uZXIiIGlkPSJoYW5kbGUt
;YmFubmVyIj48L2Rpdj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0iaGFuZGxlLXNjcm9sbCIgaWQ9ImhhbmRsZS1zY3JvbGwiPgogICAgICAgICAgICAgIDxk
;aXYgY2xhc3M9ImhhbmRsZS1oZWFkIGhhbmRsZS1jb2xzIiBpZD0iaGFuZGxlLWhlYWQiPgogICAgICAgICAgICAgICAgPGRpdiBjbGFzcz0iaGFuZGxlLWhj
;ZWxsIiBkYXRhLXNvcnQ9Im5hbWUiPuWQjeensDxzcGFuIGNsYXNzPSJoLXNvcnQiPjwvc3Bhbj48L2Rpdj4KICAgICAgICAgICAgICAgIDxkaXYgY2xhc3M9
;ImhhbmRsZS1oY2VsbCIgZGF0YS1zb3J0PSJwaWQiPlBJRDxzcGFuIGNsYXNzPSJoLXNvcnQiPjwvc3Bhbj48L2Rpdj4KICAgICAgICAgICAgICAgIDxkaXYg
;Y2xhc3M9ImhhbmRsZS1oY2VsbCBoYW5kbGUtY29sLXBvcnQgaGlkZGVuIiBkYXRhLXNvcnQ9Imxwb3J0Ij7mnKzmnLrnq6/lj6M8c3BhbiBjbGFzcz0iaC1z
;b3J0Ij48L3NwYW4+PC9kaXY+CiAgICAgICAgICAgICAgICA8ZGl2IGNsYXNzPSJoYW5kbGUtaGNlbGwgaGFuZGxlLWNvbC1ycG9ydCBoaWRkZW4iIGRhdGEt
;c29ydD0icnBvcnQiPui/nOeoi+err+WPozxzcGFuIGNsYXNzPSJoLXNvcnQiPjwvc3Bhbj48L2Rpdj4KICAgICAgICAgICAgICAgIDxkaXYgY2xhc3M9Imhh
;bmRsZS1oY2VsbCIgZGF0YS1zb3J0PSJ0eXBlIj7nsbvlnos8c3BhbiBjbGFzcz0iaC1zb3J0Ij48L3NwYW4+PC9kaXY+CiAgICAgICAgICAgICAgICA8ZGl2
;IGNsYXNzPSJoYW5kbGUtaGNlbGwiIGRhdGEtc29ydD0iaGFuZGxlIj7lj6Xmn4TlkI3np7A8c3BhbiBjbGFzcz0iaC1zb3J0Ij48L3NwYW4+PC9kaXY+CiAg
;ICAgICAgICAgICAgPC9kaXY+CiAgICAgICAgICAgICAgPGRpdiBjbGFzcz0iaGFuZGxlLWJvZHkiIGlkPSJoYW5kbGUtYm9keSI+CiAgICAgICAgICAgICAg
;ICA8ZGl2IGNsYXNzPSJoYW5kbGUtZW1wdHkiPui+k+WFpeWFs+mUruWtl+aQnOaWh+S7tuWPpeafhO+8m+err+WPo+ekuuS+iyA4MDgwfDgwIOaIliAwLTMw
;MHw1MDA8L2Rpdj4KICAgICAgICAgICAgICA8L2Rpdj4KICAgICAgICAgICAgPC9kaXY+CiAgICAgICAgICA8L2Rpdj4KICAgICAgICAgIDxkaXYgaWQ9Imlu
;Zm8tcGFuZWwiIGNsYXNzPSJoaWRkZW4gbm8tZHJhZyBlbWJlZGRlZCI+PC9kaXY+CiAgICAgICAgPC9zZWN0aW9uPgoKICAgICAgICA8c2VjdGlvbiBpZD0i
;cHJldmlldyI+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJwdi1ib2R5IiBpZD0icHYtYm9keSI+CiAgICAgICAgICAgIDxkaXYgY2xhc3M9InB2LW1lZGlhIiBp
;ZD0icHYtbWVkaWEiPjxkaXYgY2xhc3M9InBoIj7pooTop4jljLo8L2Rpdj48L2Rpdj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0icHYtdGV4dCIgaWQ9InB2
;LXRleHQiIHN0eWxlPSJkaXNwbGF5Om5vbmUiPgogICAgICAgICAgICAgIDxkaXYgY2xhc3M9ImhkIiBpZD0icHYtdGV4dC1oZCI+6aKE6KeI5YmNIDIwS0Ig
;5YaF5a65PC9kaXY+CiAgICAgICAgICAgICAgPHByZSBpZD0icHYtcHJlIj48L3ByZT4KICAgICAgICAgICAgPC9kaXY+CiAgICAgICAgICA8L2Rpdj4KICAg
;ICAgICAgIDxkaXYgY2xhc3M9InB2LW9mZiI+5bey5YWz6Zet5paH5Lu26aKE6KeIPC9kaXY+CiAgICAgICAgPC9zZWN0aW9uPgogICAgICA8L2Rpdj4KICAg
;IDwvZGl2PgoKICAgIDxkaXYgaWQ9ImJhciI+CiAgICAgIDxkaXYgY2xhc3M9ImJhci1sZWZ0Ij4KICAgICAgICA8YnV0dG9uIGlkPSJidG4tc2V0dGluZ3Mi
;IHR5cGU9ImJ1dHRvbiIgdGl0bGU9Iuiuvue9riI+4pqZPC9idXR0b24+CiAgICAgIDwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJiYXItbWFpbiI+CiAgICAg
;ICAgPGJ1dHRvbiBjbGFzcz0ic29ydCIgaWQ9ImJ0bi1zb3J0IiB0eXBlPSJidXR0b24iIHRpdGxlPSLliIfmjaLmjpLluo8iPuKHhSA8c3BhbiBpZD0ic29y
;dC1sYWJlbCI+5oyJ5L+u5pS55pe26Ze06ZmN5bqPPC9zcGFuPjwvYnV0dG9uPgogICAgICAgIDxsYWJlbCBjbGFzcz0idG9nZ2xlIiB0aXRsZT0i5byA5ZCv
;L+WFs+mXreWPs+S+p+mihOiniCI+CiAgICAgICAgICA8aW5wdXQgdHlwZT0iY2hlY2tib3giIGlkPSJjaGstcHJldmlldyIgY2hlY2tlZD4KICAgICAgICAg
;IDxzcGFuIGNsYXNzPSJzdyI+PC9zcGFuPgogICAgICAgICAgPHNwYW4+5byA5ZCv5paH5Lu26aKE6KeIPC9zcGFuPgogICAgICAgIDwvbGFiZWw+CiAgICAg
;ICAgPGRpdiBjbGFzcz0ic3BhY2VyIj48L2Rpdj4KICAgICAgICA8ZGl2IGlkPSJiYXItaGFuZGxlLWFjdGlvbnMiIGNsYXNzPSJuby1kcmFnIj4KICAgICAg
;ICAgIDxzcGFuIGlkPSJoYW5kbGUtc3RhdHVzIj48L3NwYW4+CiAgICAgICAgICA8YnV0dG9uIGlkPSJidG4tcG9ydC1tYXJrIiB0eXBlPSJidXR0b24iIHRp
;dGxlPSLmoIforrDnq6/lj6MiPuKamTwvYnV0dG9uPgogICAgICAgICAgPGRpdiBpZD0icG9ydC1tYXJrLXBvcCIgY2xhc3M9Im5vLWRyYWciPgogICAgICAg
;ICAgICA8ZGl2IGNsYXNzPSJwbXAtaGQiPuagh+iusOerr+WPozwvZGl2PgogICAgICAgICAgICA8ZGl2IGNsYXNzPSJwbXAtaGludCI+5Yy56YWN55qE5pys
;5py6L+i/nOeoi+err+WPo+S8mumrmOS6ruaYvuekuu+8jOWPr+iHquihjOa3u+WKoDwvZGl2PgogICAgICAgICAgICA8ZGl2IGNsYXNzPSJwbXAtdGFncyIg
;aWQ9InBvcnQtbWFyay10YWdzIj48L2Rpdj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0icG1wLWFkZCI+CiAgICAgICAgICAgICAgPGlucHV0IGlkPSJwb3J0
;LW1hcmstaW5wdXQiIHR5cGU9InRleHQiIGlucHV0bW9kZT0ibnVtZXJpYyIgcGxhY2Vob2xkZXI9Iuerr+WPo+WPt++8jOWmgiA5MDAwIiBhdXRvY29tcGxl
;dGU9Im9mZiIgc3BlbGxjaGVjaz0iZmFsc2UiPgogICAgICAgICAgICAgIDxidXR0b24gaWQ9InBvcnQtbWFyay1hZGQiIHR5cGU9ImJ1dHRvbiI+5re75Yqg
;PC9idXR0b24+CiAgICAgICAgICAgIDwvZGl2PgogICAgICAgICAgICA8YnV0dG9uIGlkPSJwb3J0LW1hcmstcmVzZXQiIHR5cGU9ImJ1dHRvbiIgY2xhc3M9
;InBtcC1yZXNldCI+5oGi5aSN6buY6K6kPC9idXR0b24+CiAgICAgICAgICA8L2Rpdj4KICAgICAgICA8L2Rpdj4KICAgICAgICA8ZGl2IGlkPSJiYXItaW5m
;by1hY3Rpb25zIiBjbGFzcz0ibm8tZHJhZyI+CiAgICAgICAgICA8YnV0dG9uIGlkPSJidG4taW5mby1yZWZyZXNoIiB0eXBlPSJidXR0b24iPuWIt+aWsDwv
;YnV0dG9uPgogICAgICAgICAgPGJ1dHRvbiBpZD0iYnRuLWluZm8tY29weSIgdHlwZT0iYnV0dG9uIj7lpI3liLY8L2J1dHRvbj4KICAgICAgICA8L2Rpdj4K
;ICAgICAgICA8ZGl2IGlkPSJjb3VudCI+5YWxIDAg5p2h57uT5p6cPC9kaXY+CiAgICAgIDwvZGl2PgogICAgPC9kaXY+CiAgICA8L2Rpdj4KCiAgICA8ZGl2
;IGlkPSJmaWx0ZXItc2V0dGluZ3MiIGNsYXNzPSJuby1kcmFnIiByb2xlPSJkaWFsb2ciIGFyaWEtbW9kYWw9InRydWUiIGFyaWEtbGFiZWw9Iuetm+mAieiu
;vue9riI+CiAgICAgIDxkaXYgY2xhc3M9ImZzLWNhcmQiPgogICAgICAgIDxkaXYgY2xhc3M9ImZzLWhkIj4KICAgICAgICAgIDxzcGFuPuetm+mAieadoeS7
;tjwvc3Bhbj4KICAgICAgICAgIDxidXR0b24gdHlwZT0iYnV0dG9uIiBpZD0iZnMtY2xvc2UiIHRpdGxlPSLlhbPpl60iPsOXPC9idXR0b24+CiAgICAgICAg
;PC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0iZnMtYmQiPgogICAgICAgICAgPGRpdiBjbGFzcz0iZnMtaGludCI+5ZCv55So55qE6aG55Lya5Ye6546w5Zyo
;6aG26YOo77yb54K55Lit5ZCO5oqK5a+55bqU5q2j5YiZ5Yqg5YWl5pCc57Si77yIRXZlcnl0aGluZyA8Y29kZT5yZWdleDo8L2NvZGU+77yJ44CC5Y+v5o6S
;5bqP44CB56aB55So5oiW5Yig6Zmk77yb5Yig6Zmk5ZCO5Y+v55So44CM5oGi5aSN6buY6K6k44CN6L+Y5Y6f5YaF572u6aG544CCPC9kaXY+CiAgICAgICAg
;ICA8ZGl2IGNsYXNzPSJmcy1saXN0IiBpZD0iZnMtbGlzdCI+PC9kaXY+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJmcy1mb3JtIj4KICAgICAgICAgICAgPGRp
;dj4KICAgICAgICAgICAgICA8bGFiZWwgZm9yPSJmcy10aXRsZSI+5qCH6aKYPC9sYWJlbD4KICAgICAgICAgICAgICA8aW5wdXQgaWQ9ImZzLXRpdGxlIiB0
;eXBlPSJ0ZXh0IiBtYXhsZW5ndGg9IjI0IiBwbGFjZWhvbGRlcj0i5L6L5aaC77ya5LiN5ZCr5Li05pe25paH5Lu2IiBhdXRvY29tcGxldGU9Im9mZiI+CiAg
;ICAgICAgICAgIDwvZGl2PgogICAgICAgICAgICA8ZGl2PgogICAgICAgICAgICAgIDxsYWJlbCBmb3I9ImZzLXJlZ2V4Ij7mraPliJnooajovr7lvI88L2xh
;YmVsPgogICAgICAgICAgICAgIDxpbnB1dCBpZD0iZnMtcmVnZXgiIHR5cGU9InRleHQiIG1heGxlbmd0aD0iMjAwIiBwbGFjZWhvbGRlcj0i5L6L5aaC77ya
;KD9pKVwudG1wJCIgYXV0b2NvbXBsZXRlPSJvZmYiIHNwZWxsY2hlY2s9ImZhbHNlIj4KICAgICAgICAgICAgPC9kaXY+CiAgICAgICAgICAgIDxkaXYgY2xh
;c3M9ImZzLWFjdGlvbnMiPgogICAgICAgICAgICAgIDxidXR0b24gdHlwZT0iYnV0dG9uIiBjbGFzcz0icHJpbWFyeSIgaWQ9ImZzLWFkZCI+5Yqg5YWl562b
;6YCJPC9idXR0b24+CiAgICAgICAgICAgIDwvZGl2PgogICAgICAgICAgPC9kaXY+CiAgICAgICAgPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0iZnMtZm9v
;dCI+CiAgICAgICAgICA8YnV0dG9uIHR5cGU9ImJ1dHRvbiIgaWQ9ImZzLWV2LW9wdHMiPuaJk+W8gCBFdmVyeXRoaW5nIOmAiemhueKApjwvYnV0dG9uPgog
;ICAgICAgICAgPGJ1dHRvbiB0eXBlPSJidXR0b24iIGlkPSJmcy1yZXNldCIgdGl0bGU9IuaBouWkjeWGhee9ruetm+mAieW5tua4heepuuiHquWumuS5iSI+
;5oGi5aSN6buY6K6kPC9idXR0b24+CiAgICAgICAgPC9kaXY+CiAgICAgIDwvZGl2PgogICAgPC9kaXY+CgogICAgICAgIDxkaXYgaWQ9InByb2MtbWVudSIg
;cm9sZT0ibWVudSI+CiAgICAgIDxidXR0b24gdHlwZT0iYnV0dG9uIiBkYXRhLXBhY3Q9InJldmVhbCI+PHNwYW4gY2xhc3M9ImMtaWNvIiBhcmlhLWhpZGRl
;bj0idHJ1ZSI+PHN2ZyB2aWV3Qm94PSIwIDAgMjQgMjQiIGZpbGw9Im5vbmUiIHN0cm9rZT0iY3VycmVudENvbG9yIiBzdHJva2Utd2lkdGg9IjEuOCI+PHBh
;dGggZD0iTTMgNy41QTEuNSAxLjUgMCAwIDEgNC41IDZIOWwyIDJoOC41QTEuNSAxLjUgMCAwIDEgMjEgOS41djdBMS41IDEuNSAwIDAgMSAxOS41IDE4aC0x
;NUExLjUgMS41IDAgMCAxIDMgMTYuNXYtOXoiLz48L3N2Zz48L3NwYW4+PHNwYW4gY2xhc3M9InBhY3QtbGFiZWwiPuaJk+W8gOi/m+eoi+aJgOWcqOS9jee9
;rjwvc3Bhbj48L2J1dHRvbj4KICAgICAgPGJ1dHRvbiB0eXBlPSJidXR0b24iIGRhdGEtcGFjdD0iY29weSI+PHNwYW4gY2xhc3M9ImMtaWNvIiBhcmlhLWhp
;ZGRlbj0idHJ1ZSI+PHN2ZyB2aWV3Qm94PSIwIDAgMjQgMjQiIGZpbGw9Im5vbmUiIHN0cm9rZT0iY3VycmVudENvbG9yIiBzdHJva2Utd2lkdGg9IjEuOCI+
;PHJlY3QgeD0iOCIgeT0iOCIgd2lkdGg9IjExIiBoZWlnaHQ9IjExIiByeD0iMS41Ii8+PHBhdGggZD0iTTUgMTVWNS41QTEuNSAxLjUgMCAwIDEgNi41IDRI
;MTUiLz48L3N2Zz48L3NwYW4+PHNwYW4gY2xhc3M9InBhY3QtbGFiZWwiIGlkPSJwcm9jLW1lbnUtY29weSI+5aSN5Yi26L+b56iL5ZCNPC9zcGFuPjwvYnV0
;dG9uPgogICAgICA8YnV0dG9uIHR5cGU9ImJ1dHRvbiIgZGF0YS1wYWN0PSJjb3B5UGlkIj48c3BhbiBjbGFzcz0iYy1pY28iIGFyaWEtaGlkZGVuPSJ0cnVl
;Ij48c3ZnIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0cm9rZS13aWR0aD0iMS44Ij48cGF0aCBkPSJN
;NyA3aDR2NEg3ek0xMyA3aDR2NGgtNHpNNyAxM2g0djRIN3pNMTMgMTNoNHY0aC00eiIvPjwvc3ZnPjwvc3Bhbj48c3BhbiBjbGFzcz0icGFjdC1sYWJlbCIg
;aWQ9InByb2MtbWVudS1jb3B5cGlkIj7lpI3liLbov5vnqIvlj7c8L3NwYW4+PC9idXR0b24+CiAgICAgIDxidXR0b24gdHlwZT0iYnV0dG9uIiBkYXRhLXBh
;Y3Q9ImVuZCIgY2xhc3M9ImRhbmdlciIgaWQ9InByb2MtbWVudS1lbmQiPjxzcGFuIGNsYXNzPSJjLWljbyIgYXJpYS1oaWRkZW49InRydWUiPjxzdmcgdmll
;d0JveD0iMCAwIDI0IDI0IiBmaWxsPSJub25lIiBzdHJva2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIxLjgiPjxjaXJjbGUgY3g9IjEyIiBjeT0i
;MTIiIHI9IjguNSIvPjxwYXRoIGQ9Ik05IDlsNiA2TTE1IDlsLTYgNiIvPjwvc3ZnPjwvc3Bhbj48c3BhbiBjbGFzcz0icGFjdC1sYWJlbCIgaWQ9InByb2Mt
;bWVudS1lbmQtbGFiZWwiPuWFs+mXrei/m+eoizwvc3Bhbj48L2J1dHRvbj4KICAgIDwvZGl2PgogICAgPGRhdGFsaXN0IGlkPSJoYW5kbGUtaGlzdC1saXN0
;Ij48L2RhdGFsaXN0Pgo8L2Rpdj4KCiAgPGRpdiBpZD0iY3R4IiByb2xlPSJtZW51Ij4KICAgIDxidXR0b24gdHlwZT0iYnV0dG9uIiBkYXRhLWFjdD0icmV2
;ZWFsIj48c3BhbiBjbGFzcz0iYy1pY28iPjxzdmcgdmlld0JveD0iMCAwIDI0IDI0IiBmaWxsPSJub25lIiBzdHJva2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tl
;LXdpZHRoPSIxLjgiPjxwYXRoIGQ9Ik0zIDcuNUExLjUgMS41IDAgMCAxIDQuNSA2SDlsMiAyaDguNUExLjUgMS41IDAgMCAxIDIxIDkuNXY3QTEuNSAxLjUg
;MCAwIDEgMTkuNSAxOGgtMTVBMS41IDEuNSAwIDAgMSAzIDE2LjV2LTl6Ii8+PC9zdmc+PC9zcGFuPuaWh+S7tuWkueS4reaYvuekujwvYnV0dG9uPgogICAg
;PGJ1dHRvbiB0eXBlPSJidXR0b24iIGRhdGEtYWN0PSJjb3B5Ij48c3BhbiBjbGFzcz0iYy1pY28iPjxzdmcgdmlld0JveD0iMCAwIDI0IDI0IiBmaWxsPSJu
;b25lIiBzdHJva2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIxLjgiPjxyZWN0IHg9IjgiIHk9IjgiIHdpZHRoPSIxMSIgaGVpZ2h0PSIxMSIgcng9
;IjEuNSIvPjxwYXRoIGQ9Ik01IDE1VjUuNUExLjUgMS41IDAgMCAxIDYuNSA0SDE1Ii8+PC9zdmc+PC9zcGFuPuWkjeWItjwvYnV0dG9uPgogICAgPGJ1dHRv
;biB0eXBlPSJidXR0b24iIGRhdGEtYWN0PSJjb3B5UGF0aCI+PHNwYW4gY2xhc3M9ImMtaWNvIj48c3ZnIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0ibm9u
;ZSIgc3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0cm9rZS13aWR0aD0iMS44Ij48cGF0aCBkPSJNOCAxMmg4Ii8+PHBhdGggZD0iTTEwIDdINy41QTIuNSAyLjUg
;MCAwIDAgNSA5LjV2NUEyLjUgMi41IDAgMCAwIDcuNSAxN0gxMCIvPjxwYXRoIGQ9Ik0xNCA3aDIuNUEyLjUgMi41IDAgMCAxIDE5IDkuNXY1QTIuNSAyLjUg
;MCAwIDEgMTYuNSAxN0gxNCIvPjwvc3ZnPjwvc3Bhbj7lpI3liLbot6/lvoQ8L2J1dHRvbj4KICAgIDxidXR0b24gdHlwZT0iYnV0dG9uIiBkYXRhLWFjdD0i
;Y29weURpciI+PHNwYW4gY2xhc3M9ImMtaWNvIj48c3ZnIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0
;cm9rZS13aWR0aD0iMS44Ij48cGF0aCBkPSJNOSA4LjVhMy41IDMuNSAwIDAgMSA1LjYtMi44bDEuNyAxLjRhMy41IDMuNSAwIDAgMS0yLjIgNi4ySDEzIi8+
;PHBhdGggZD0iTTE1IDE1LjVhMy41IDMuNSAwIDAgMS01LjYgMi44bC0xLjctMS40YTMuNSAzLjUgMCAwIDEgMi4yLTYuMkgxMSIvPjwvc3ZnPjwvc3Bhbj7l
;pI3liLbmiYDlnKjot6/lvoQ8L2J1dHRvbj4KICAgIDxidXR0b24gdHlwZT0iYnV0dG9uIiBkYXRhLWFjdD0icmVjeWNsZSIgY2xhc3M9ImRhbmdlciI+PHNw
;YW4gY2xhc3M9ImMtaWNvIj48c3ZnIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0cm9rZS13aWR0aD0i
;MS44Ij48cGF0aCBkPSJNNSA4aDE0Ii8+PHBhdGggZD0iTTkgOFY2LjVBMS41IDEuNSAwIDAgMSAxMC41IDVoM0ExLjUgMS41IDAgMCAxIDE1IDYuNVY4Ii8+
;PHBhdGggZD0iTTcuNSA4bC43IDExYTEuNSAxLjUgMCAwIDAgMS41IDEuNGg0LjZhMS41IDEuNSAwIDAgMCAxLjUtMS40bC43LTExIi8+PC9zdmc+PC9zcGFu
;PuWIoOmZpCjlm57mlLbnq5kpPC9idXR0b24+CiAgPC9kaXY+CjwvZGl2Pgo8c2NyaXB0PgooKCkgPT4gewogIGNvbnN0IGJvb3QgPSBkb2N1bWVudC5nZXRF
;bGVtZW50QnlJZCgnYm9vdCcpOwogIGNvbnN0IGNocm9tZSA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjaHJvbWUnKTsKICBjb25zdCBhcHBSb290ID0g
;ZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2FwcCcpOwogIGNvbnN0IHRpdGxlYmFyID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3RpdGxlYmFyJyk7CiAg
;Y29uc3QgcmluZ0ZnID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3JpbmctZmcnKTsKICBjb25zdCBib290UGN0ID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5
;SWQoJ2Jvb3QtcGN0Jyk7CiAgY29uc3QgcUVsID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3EnKTsKICBjb25zdCBsaXN0RWwgPSBkb2N1bWVudC5nZXRF
;bGVtZW50QnlJZCgnbGlzdCcpOwogIGNvbnN0IGVtcHR5RWwgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbGlzdC1lbXB0eScpOwogIGNvbnN0IGNvdW50
;RWwgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnY291bnQnKTsKICBjb25zdCBwdk1ldGEgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgncHYtbWV0YScp
;OwogIGNvbnN0IHB2TWVkaWEgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgncHYtbWVkaWEnKTsKICBjb25zdCBwdlRleHQgPSBkb2N1bWVudC5nZXRFbGVt
;ZW50QnlJZCgncHYtdGV4dCcpOwogIGNvbnN0IHB2Qm9keSA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdwdi1ib2R5Jyk7CiAgY29uc3QgcHZQcmUgPSBk
;b2N1bWVudC5nZXRFbGVtZW50QnlJZCgncHYtcHJlJyk7CiAgY29uc3QgcHZUZXh0SGQgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgncHYtdGV4dC1oZCcp
;OwogIGNvbnN0IHByZXZpZXcgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgncHJldmlldycpOwogIGNvbnN0IGNoa1ByZXZpZXcgPSBkb2N1bWVudC5nZXRF
;bGVtZW50QnlJZCgnY2hrLXByZXZpZXcnKTsKICBjb25zdCBzb3J0TGFiZWwgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc29ydC1sYWJlbCcpOwogIGNv
;bnN0IENJUkMgPSAyICogTWF0aC5QSSAqIDUyOwoKICBsZXQgY2F0ID0gJ2FsbCc7CiAgbGV0IGFwcE1vZGUgPSAnZmlsZSc7IC8vIGZpbGUgfCBoYW5kbGUg
;fCBpbmZvCiAgY29uc3QgUExBQ0VIT0xERVJfRklMRSA9ICfovpPlhaXmlofku7blkI0gLyDmianlsZXlkI0gLyDot6/lvoTlhbPplK7lrZfvvJt8IOihqOek
;uuS4lO+8jHx8IOihqOekuuaIlic7CiAgY29uc3QgUExBQ0VIT0xERVJfSEFORExFID0gJ+aWh+S7tuWPpeafhOWFs+mUruWtl++8jOaIluerr+WPoyA4MDgw
;fDgw44CBMC0zMDB8NTAwJzsKICBjb25zdCBQTEFDRUhPTERFUl9JTkZPID0gJ+acrOacuuS/oeaBr+aXoOmcgOWFs+mUruWtl++8jOeCueW3puS+p+WNs+WP
;r+afpeeciyc7CiAgLy8g5pys5Zyw5pCc57SiIC8g5Y+l5p+E5pCc57Si5ZCE6Ieq5L+d55WZ6L6T5YWl5p2h5Lu277yM5LqS5LiN5Liy5Y+wCiAgY29uc3Qg
;bW9kZVF1ZXJ5ID0geyBmaWxlOiAnJywgaGFuZGxlOiAnJywgaW5mbzogJycgfTsKICBsZXQgc29ydCA9ICdkYXRlLWRlc2MnOwogIGxldCBkcml2ZSA9ICcn
;OyAvLyAnJyA9IGFsbCBkaXNrcywgJ0MnIC8gJ0QnIC8gLi4uCiAgbGV0IGl0ZW1zID0gW107CiAgbGV0IHNlbGVjdGVkID0gLTE7CiAgbGV0IHByZXZpZXdP
;biA9IHRydWU7CiAgbGV0IHNlYXJjaFRpbWVyID0gMDsKICBsZXQgZ2VuID0gMDsKICBsZXQgdG90YWxIaXRzID0gMDsKICBsZXQgbG9hZGluZ01vcmUgPSBm
;YWxzZTsKICBsZXQgaGFzTW9yZSA9IGZhbHNlOwoKICBjb25zdCBkcml2ZUxhYmVsID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2RyaXZlLWxhYmVsJyk7
;CiAgY29uc3QgZHJpdmVNZW51ID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2RyaXZlLW1lbnUnKTsKICBjb25zdCBidG5Ecml2ZSA9IGRvY3VtZW50Lmdl
;dEVsZW1lbnRCeUlkKCdidG4tZHJpdmUnKTsKICBjb25zdCBkcml2ZUJ0bkljbyA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdkcml2ZS1idG4taWNvJyk7
;CiAgbGV0IGRyaXZlTWV0YSA9IHsgY29tcHV0ZXI6ICcnLCBkcml2ZXM6IFtdIH07CgogIGZ1bmN0aW9uIGRyaXZlVGV4dCgpIHsKICAgIGlmICghZHJpdmUp
;IHJldHVybiAn5YWo55uY5pCc57SiJzsKICAgIGNvbnN0IGhpdCA9IChkcml2ZU1ldGEuZHJpdmVzIHx8IFtdKS5maW5kKGQgPT4gU3RyaW5nKGQubGV0dGVy
;IHx8ICcnKS50b1VwcGVyQ2FzZSgpID09PSBkcml2ZSk7CiAgICBpZiAoaGl0ICYmIGhpdC5sYWJlbCkgcmV0dXJuIGhpdC5sYWJlbDsKICAgIHJldHVybiBk
;cml2ZS50b1VwcGVyQ2FzZSgpICsgJyDnm5gnOwogIH0KICBmdW5jdGlvbiBzZXRCdG5JY29uKHVybCkgewogICAgaWYgKHVybCkgewogICAgICBkcml2ZUJ0
;bkljby5zcmMgPSB1cmwgKyAodXJsLmluY2x1ZGVzKCc/JykgPyAnJicgOiAnPycpICsgJ3Q9JyArIERhdGUubm93KCk7CiAgICAgIGRyaXZlQnRuSWNvLmNs
;YXNzTGlzdC5yZW1vdmUoJ2hpZGRlbicpOwogICAgfSBlbHNlIHsKICAgICAgZHJpdmVCdG5JY28ucmVtb3ZlQXR0cmlidXRlKCdzcmMnKTsKICAgICAgZHJp
;dmVCdG5JY28uY2xhc3NMaXN0LmFkZCgnaGlkZGVuJyk7CiAgICB9CiAgfQogIGZ1bmN0aW9uIHN5bmNEcml2ZUJ1dHRvbigpIHsKICAgIGRyaXZlTGFiZWwu
;dGV4dENvbnRlbnQgPSBkcml2ZVRleHQoKTsKICAgIGlmICghZHJpdmUpIHNldEJ0bkljb24oZHJpdmVNZXRhLmNvbXB1dGVyIHx8ICcnKTsKICAgIGVsc2Ug
;ewogICAgICBjb25zdCBoaXQgPSAoZHJpdmVNZXRhLmRyaXZlcyB8fCBbXSkuZmluZChkID0+IFN0cmluZyhkLmxldHRlciB8fCAnJykudG9VcHBlckNhc2Uo
;KSA9PT0gZHJpdmUpOwogICAgICBzZXRCdG5JY29uKChoaXQgJiYgaGl0Lmljb24pIHx8IGRyaXZlTWV0YS5jb21wdXRlciB8fCAnJyk7CiAgICB9CiAgfQog
;IGZ1bmN0aW9uIGljb0h0bWwodXJsKSB7CiAgICByZXR1cm4gdXJsID8gJzxpbWcgc3JjPSInICsgU3RyaW5nKHVybCkucmVwbGFjZSgvIi9nLCAnJykgKyAn
;IiBhbHQ9IiI+JyA6ICcnOwogIH0KICBmdW5jdGlvbiByZW5kZXJEcml2ZU1lbnUoKSB7CiAgICBjb25zdCBkcml2ZXMgPSBBcnJheS5pc0FycmF5KGRyaXZl
;TWV0YS5kcml2ZXMpID8gZHJpdmVNZXRhLmRyaXZlcyA6IFtdOwogICAgbGV0IGh0bWwgPSAnPGJ1dHRvbiB0eXBlPSJidXR0b24iIGRhdGEtZHJpdmU9IiIn
;ICsgKCFkcml2ZSA/ICcgY2xhc3M9Im9uIicgOiAnJykgKyAnPicKICAgICAgKyBpY29IdG1sKGRyaXZlTWV0YS5jb21wdXRlcikgKyAnPHNwYW4+5YWo55uY
;5pCc57SiPC9zcGFuPjwvYnV0dG9uPic7CiAgICBmb3IgKGNvbnN0IGQgb2YgZHJpdmVzKSB7CiAgICAgIGNvbnN0IGxldHRlciA9IFN0cmluZyhkLmxldHRl
;ciB8fCBkIHx8ICcnKS5yZXBsYWNlKC86JC8sICcnKS50b1VwcGVyQ2FzZSgpOwogICAgICBpZiAoIWxldHRlcikgY29udGludWU7CiAgICAgIGNvbnN0IGxh
;YmVsID0gZC5sYWJlbCB8fCAobGV0dGVyICsgJyDnm5gnKTsKICAgICAgaHRtbCArPSAnPGJ1dHRvbiB0eXBlPSJidXR0b24iIGRhdGEtZHJpdmU9IicgKyBs
;ZXR0ZXIgKyAnIicKICAgICAgICArIChkcml2ZSA9PT0gbGV0dGVyID8gJyBjbGFzcz0ib24iJyA6ICcnKSArICc+JwogICAgICAgICsgaWNvSHRtbChkLmlj
;b24gfHwgJycpICsgJzxzcGFuPicgKyBsYWJlbCArICc8L3NwYW4+PC9idXR0b24+JzsKICAgIH0KICAgIGRyaXZlTWVudS5pbm5lckhUTUwgPSBodG1sOwog
;ICAgZHJpdmVNZW51LnF1ZXJ5U2VsZWN0b3JBbGwoJ2J1dHRvbicpLmZvckVhY2goYnRuID0+IHsKICAgICAgYnRuLm9uY2xpY2sgPSAoZSkgPT4gewogICAg
;ICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAgICAgZHJpdmUgPSBidG4uZ2V0QXR0cmlidXRlKCdkYXRhLWRyaXZlJykgfHwgJyc7CiAgICAgICAgZHJp
;dmVNZW51LmNsYXNzTGlzdC5yZW1vdmUoJ29uJyk7CiAgICAgICAgc3luY0RyaXZlQnV0dG9uKCk7CiAgICAgICAgcmVuZGVyRHJpdmVNZW51KCk7CiAgICAg
;ICAgZG9TZWFyY2goKTsKICAgICAgfTsKICAgIH0pOwogIH0KICB3aW5kb3cuX19zZXREcml2ZXMgPSAocGF5bG9hZCkgPT4gewogICAgdHJ5IHsKICAgICAg
;Y29uc3QgZGF0YSA9IHR5cGVvZiBwYXlsb2FkID09PSAnc3RyaW5nJyA/IEpTT04ucGFyc2UocGF5bG9hZCkgOiBwYXlsb2FkOwogICAgICBpZiAoQXJyYXku
;aXNBcnJheShkYXRhKSkgewogICAgICAgIGRyaXZlTWV0YSA9IHsKICAgICAgICAgIGNvbXB1dGVyOiAnJywKICAgICAgICAgIGRyaXZlczogZGF0YS5tYXAo
;eCA9PiB0eXBlb2YgeCA9PT0gJ3N0cmluZycKICAgICAgICAgICAgPyAoeyBsZXR0ZXI6IHgsIGljb246ICcnLCBsYWJlbDogU3RyaW5nKHgpLnRvVXBwZXJD
;YXNlKCkgKyAnIOebmCcgfSkKICAgICAgICAgICAgOiB4KQogICAgICAgIH07CiAgICAgIH0gZWxzZSB7CiAgICAgICAgZHJpdmVNZXRhID0gewogICAgICAg
;ICAgY29tcHV0ZXI6IChkYXRhICYmIGRhdGEuY29tcHV0ZXIpIHx8ICcnLAogICAgICAgICAgZHJpdmVzOiBBcnJheS5pc0FycmF5KGRhdGEgJiYgZGF0YS5k
;cml2ZXMpID8gZGF0YS5kcml2ZXMgOiBbXQogICAgICAgIH07CiAgICAgIH0KICAgICAgc3luY0RyaXZlQnV0dG9uKCk7CiAgICAgIHJlbmRlckRyaXZlTWVu
;dSgpOwogICAgfSBjYXRjaCAoZSkgeyBjb25zb2xlLndhcm4oJ3NldERyaXZlcycsIGUpOyB9CiAgfTsKCiAgY29uc3QgSElTVF9LRVkgPSAnbG9jYWxfc2Vh
;cmNoX2hpc3RfdjEnOwogIGNvbnN0IEhJU1RfTUFYID0gMTA7CiAgY29uc3Qgc2VhcmNoQm94ID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NlYXJjaC1i
;b3gnKTsKICBjb25zdCBoaXN0TWVudSA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdoaXN0LW1lbnUnKTsKICBjb25zdCBidG5IaXN0ID0gZG9jdW1lbnQu
;Z2V0RWxlbWVudEJ5SWQoJ2J0bi1oaXN0Jyk7CiAgY29uc3QgYnRuQ2xlYXIgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYnRuLWNsZWFyJyk7CiAgbGV0
;IGhpc3RJZGxlVGltZXIgPSAwOwoKICBmdW5jdGlvbiBzeW5jQ2xlYXJCdG4oKSB7CiAgICBidG5DbGVhci5jbGFzc0xpc3QudG9nZ2xlKCdvbicsICEhKHFF
;bC52YWx1ZSB8fCAnJykudHJpbSgpKTsKICB9CiAgZnVuY3Rpb24gY2xlYXJTZWFyY2goKSB7CiAgICBjbGVhclRpbWVvdXQoaGlzdElkbGVUaW1lcik7CiAg
;ICBxRWwudmFsdWUgPSAnJzsKICAgIGlmIChhcHBNb2RlID09PSAnZmlsZScpIG1vZGVRdWVyeS5maWxlID0gJyc7CiAgICBlbHNlIGlmIChhcHBNb2RlID09
;PSAnaGFuZGxlJykgbW9kZVF1ZXJ5LmhhbmRsZSA9ICcnOwogICAgZWxzZSBpZiAoYXBwTW9kZSA9PT0gJ2luZm8nKSBtb2RlUXVlcnkuaW5mbyA9ICcnOwog
;ICAgc3luY0NsZWFyQnRuKCk7CiAgICBoaXN0TWVudS5jbGFzc0xpc3QucmVtb3ZlKCdvbicpOwogICAgc2VhcmNoQm94LmNsYXNzTGlzdC5yZW1vdmUoJ2hp
;c3Qtb3BlbicpOwogICAgYnRuSGlzdC5jbGFzc0xpc3QucmVtb3ZlKCdvbicpOwogICAgcUVsLmZvY3VzKCk7CiAgICBpZiAoYXBwTW9kZSA9PT0gJ2hhbmRs
;ZScpIHsKICAgICAgLy8g5riF56m65p2h5Lu25ZCO5LuN5pi+56S65YWo6YOo6L+e5o6l77yI5LiN5oqKIDAtNjU1MzUg5YaZ5Zue6L6T5YWl5qGG77yJCiAg
;ICAgIHJlcXVlc3RIYW5kbGVTZWFyY2goJycpOwogICAgICByZXR1cm47CiAgICB9CiAgICBpZiAoYXBwTW9kZSA9PT0gJ2luZm8nKSByZXR1cm47CiAgICBk
;b1NlYXJjaCgpOwogIH0KICBidG5DbGVhci5vbmNsaWNrID0gKGUpID0+IHsKICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICBjbGVhclNlYXJjaCgpOwog
;IH07CgogIGZ1bmN0aW9uIGxvYWRIaXN0KCkgewogICAgdHJ5IHsKICAgICAgY29uc3QgcmF3ID0gbG9jYWxTdG9yYWdlLmdldEl0ZW0oSElTVF9LRVkpOwog
;ICAgICBjb25zdCBhcnIgPSByYXcgPyBKU09OLnBhcnNlKHJhdykgOiBbXTsKICAgICAgcmV0dXJuIEFycmF5LmlzQXJyYXkoYXJyKSA/IGFyci5tYXAoeCA9
;PiBTdHJpbmcoeCB8fCAnJykudHJpbSgpKS5maWx0ZXIoQm9vbGVhbikuc2xpY2UoMCwgSElTVF9NQVgpIDogW107CiAgICB9IGNhdGNoIChfKSB7IHJldHVy
;biBbXTsgfQogIH0KICBmdW5jdGlvbiBzYXZlSGlzdChsaXN0KSB7CiAgICB0cnkgeyBsb2NhbFN0b3JhZ2Uuc2V0SXRlbShISVNUX0tFWSwgSlNPTi5zdHJp
;bmdpZnkobGlzdC5zbGljZSgwLCBISVNUX01BWCkpKTsgfSBjYXRjaCAoXykge30KICB9CiAgZnVuY3Rpb24gcHVzaEhpc3QocSkgewogICAgcSA9IFN0cmlu
;ZyhxIHx8ICcnKS50cmltKCk7CiAgICBpZiAoIXEpIHJldHVybjsKICAgIGlmICh0eXBlb2YgYXBwTW9kZSAhPT0gJ3VuZGVmaW5lZCcgJiYgYXBwTW9kZSA9
;PT0gJ2luZm8nKSByZXR1cm47CiAgICBpZiAodHlwZW9mIGFwcE1vZGUgIT09ICd1bmRlZmluZWQnICYmIGFwcE1vZGUgPT09ICdoYW5kbGUnKSB7CiAgICAg
;IGlmICh0eXBlb2Ygc2F2ZUhhbmRsZUhpc3QgPT09ICdmdW5jdGlvbicpIHNhdmVIYW5kbGVIaXN0KHEpOwogICAgICBpZiAoaGlzdE1lbnUuY2xhc3NMaXN0
;LmNvbnRhaW5zKCdvbicpKSByZW5kZXJIaXN0TWVudSgpOwogICAgICByZXR1cm47CiAgICB9CiAgICBjb25zdCBsaXN0ID0gbG9hZEhpc3QoKS5maWx0ZXIo
;eCA9PiB4ICE9PSBxKTsKICAgIGxpc3QudW5zaGlmdChxKTsKICAgIHNhdmVIaXN0KGxpc3QpOwogICAgaWYgKGhpc3RNZW51LmNsYXNzTGlzdC5jb250YWlu
;cygnb24nKSkgcmVuZGVySGlzdE1lbnUoKTsKICB9CiAgZnVuY3Rpb24gZXNjYXBlQXR0cihzKSB7CiAgICByZXR1cm4gU3RyaW5nKHMgfHwgJycpLnJlcGxh
;Y2UoLyYvZywgJyZhbXA7JykucmVwbGFjZSgvIi9nLCAnJnF1b3Q7JykucmVwbGFjZSgvPC9nLCAnJmx0OycpOwogIH0KICBmdW5jdGlvbiByZW5kZXJIaXN0
;TWVudSgpIHsKICAgIGNvbnN0IGhhbmRsZU1vZGUgPSB0eXBlb2YgYXBwTW9kZSAhPT0gJ3VuZGVmaW5lZCcgJiYgYXBwTW9kZSA9PT0gJ2hhbmRsZSc7CiAg
;ICBjb25zdCBsaXN0ID0gaGFuZGxlTW9kZSAmJiB0eXBlb2YgbG9hZEhhbmRsZUhpc3QgPT09ICdmdW5jdGlvbicgPyBsb2FkSGFuZGxlSGlzdCgpIDogbG9h
;ZEhpc3QoKTsKICAgIGlmICghbGlzdC5sZW5ndGgpIHsKICAgICAgaGlzdE1lbnUuaW5uZXJIVE1MID0gJzxkaXYgY2xhc3M9Imhpc3QtZW1wdHkiPicgKyAo
;aGFuZGxlTW9kZSA/ICfmmoLml6Dlj6Xmn4Qv56uv5Y+j5pCc57Si6K6w5b2VJyA6ICfmmoLml6DmnIDov5HmkJzntKInKSArICc8L2Rpdj4nOwogICAgICBy
;ZXR1cm47CiAgICB9CiAgICBoaXN0TWVudS5pbm5lckhUTUwgPSBsaXN0Lm1hcChxID0+CiAgICAgICc8YnV0dG9uIHR5cGU9ImJ1dHRvbiIgZGF0YS1xPSIn
;ICsgZXNjYXBlQXR0cihxKSArICciIHRpdGxlPSInICsgZXNjYXBlQXR0cihxKSArICciPicKICAgICAgKyBlc2NhcGVBdHRyKHEpICsgJzwvYnV0dG9uPicK
;ICAgICkuam9pbignJyk7CiAgICBoaXN0TWVudS5xdWVyeVNlbGVjdG9yQWxsKCdidXR0b24nKS5mb3JFYWNoKGJ0biA9PiB7CiAgICAgIGJ0bi5vbmNsaWNr
;ID0gKGUpID0+IHsKICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgICAgIGNvbnN0IHEgPSBidG4uZ2V0QXR0cmlidXRlKCdkYXRhLXEnKSB8fCAn
;JzsKICAgICAgICBoaXN0TWVudS5jbGFzc0xpc3QucmVtb3ZlKCdvbicpOwogICAgICAgIHNlYXJjaEJveC5jbGFzc0xpc3QucmVtb3ZlKCdoaXN0LW9wZW4n
;KTsKICAgICAgICBidG5IaXN0LmNsYXNzTGlzdC5yZW1vdmUoJ29uJyk7CiAgICAgICAgcUVsLnZhbHVlID0gcTsKICAgICAgICBpZiAoYXBwTW9kZSA9PT0g
;J2ZpbGUnKSBtb2RlUXVlcnkuZmlsZSA9IHE7CiAgICAgICAgZWxzZSBpZiAoYXBwTW9kZSA9PT0gJ2hhbmRsZScpIG1vZGVRdWVyeS5oYW5kbGUgPSBxOwog
;ICAgICAgIHB1c2hIaXN0KHEpOwogICAgICAgIHN5bmNDbGVhckJ0bigpOwogICAgICAgIGRvU2VhcmNoKCk7CiAgICAgIH07CiAgICB9KTsKICB9CiAgYnRu
;RHJpdmUub25jbGljayA9IChlKSA9PiB7CiAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgY2xvc2VIaXN0TWVudSgpOwogICAgZHJpdmVNZW51LmNsYXNz
;TGlzdC50b2dnbGUoJ29uJyk7CiAgfTsKICBmdW5jdGlvbiBjbG9zZUhpc3RNZW51KCkgewogICAgaGlzdE1lbnUuY2xhc3NMaXN0LnJlbW92ZSgnb24nKTsK
;ICAgIHNlYXJjaEJveC5jbGFzc0xpc3QucmVtb3ZlKCdoaXN0LW9wZW4nKTsKICAgIGJ0bkhpc3QuY2xhc3NMaXN0LnJlbW92ZSgnb24nKTsKICB9CiAgZnVu
;Y3Rpb24gb3Blbkhpc3RNZW51KCkgewogICAgaWYgKGFwcE1vZGUgPT09ICdpbmZvJykgcmV0dXJuOwogICAgZHJpdmVNZW51LmNsYXNzTGlzdC5yZW1vdmUo
;J29uJyk7CiAgICByZW5kZXJIaXN0TWVudSgpOwogICAgaGlzdE1lbnUuY2xhc3NMaXN0LmFkZCgnb24nKTsKICAgIHNlYXJjaEJveC5jbGFzc0xpc3QuYWRk
;KCdoaXN0LW9wZW4nKTsKICAgIGJ0bkhpc3QuY2xhc3NMaXN0LmFkZCgnb24nKTsKICB9CiAgYnRuSGlzdC5vbmNsaWNrID0gKGUpID0+IHsKICAgIGUuc3Rv
;cFByb3BhZ2F0aW9uKCk7CiAgICBpZiAoaGlzdE1lbnUuY2xhc3NMaXN0LmNvbnRhaW5zKCdvbicpKSBjbG9zZUhpc3RNZW51KCk7CiAgICBlbHNlIG9wZW5I
;aXN0TWVudSgpOwogIH07CiAgaGlzdE1lbnUuYWRkRXZlbnRMaXN0ZW5lcignY2xpY2snLCBlID0+IGUuc3RvcFByb3BhZ2F0aW9uKCkpOwogIGRvY3VtZW50
;LmFkZEV2ZW50TGlzdGVuZXIoJ2NsaWNrJywgKCkgPT4gewogICAgZHJpdmVNZW51LmNsYXNzTGlzdC5yZW1vdmUoJ29uJyk7CiAgICBjbG9zZUhpc3RNZW51
;KCk7CiAgICBoaWRlQ3R4KCk7CiAgfSk7CiAgcmVuZGVyRHJpdmVNZW51KCk7CiAgcmVuZGVySGlzdE1lbnUoKTsKICBzeW5jQ2xlYXJCdG4oKTsKCiAgLy8g
;UHJpbWFyeSBVSeKGkkFISyBjaGFubmVsOiBpbi1wYWdlIHF1ZXVlIGRyYWluZWQgYnkgQUhLIEV4ZWN1dGVTY3JpcHQuCiAgLy8gTmV2ZXIgdXNlIGhvc3RP
;YmplY3RzLnN5bmMg4oCUIGl0IGRlYWRsb2NrcyBXZWJWaWV3MiBhbmQgYmxvY2tzIHBvc3RNZXNzYWdlIHRvby4KICB3aW5kb3cuX19haGtRID0gd2luZG93
;Ll9fYWhrUSB8fCBbXTsKICBmdW5jdGlvbiBlbnF1ZXVlKG1zZykgewogICAgdHJ5IHsKICAgICAgd2luZG93Ll9fYWhrUS5wdXNoKFN0cmluZyhtc2cpKTsK
;ICAgICAgLy8gVGlwIEFISyBwb2xsZXIgdmlhIHRpdGxlIGNoYW5nZSAob3B0aW9uYWwgZmFzdCBwYXRoKQogICAgICB0cnkgeyBkb2N1bWVudC5kb2N1bWVu
;dEVsZW1lbnQuZGF0YXNldC5haGtQZW5kaW5nID0gU3RyaW5nKHdpbmRvdy5fX2Foa1EubGVuZ3RoKTsgfSBjYXRjaCAoXykge30KICAgIH0gY2F0Y2ggKGUp
;IHsgY29uc29sZS53YXJuKCdlbnF1ZXVlJywgZSk7IH0KICB9CiAgZnVuY3Rpb24gcG9zdChtc2cpIHsKICAgIGVucXVldWUobXNnKTsKICAgIHRyeSB7CiAg
;ICAgIGlmICh3aW5kb3cuY2hyb21lICYmIGNocm9tZS53ZWJ2aWV3ICYmIHR5cGVvZiBjaHJvbWUud2Vidmlldy5wb3N0TWVzc2FnZSA9PT0gJ2Z1bmN0aW9u
;JykgewogICAgICAgIGNocm9tZS53ZWJ2aWV3LnBvc3RNZXNzYWdlKFN0cmluZyhtc2cpKTsKICAgICAgICByZXR1cm4gdHJ1ZTsKICAgICAgfQogICAgfSBj
;YXRjaCAoZSkgeyBjb25zb2xlLndhcm4oJ3Bvc3QnLCBlKTsgfQogICAgcmV0dXJuIGZhbHNlOwogIH0KICBmdW5jdGlvbiBjYWxsSG9zdChtZXRob2QsIC4u
;LmFyZ3MpIHsKICAgIGxldCBtc2cgPSAnJzsKICAgIGlmIChtZXRob2QgPT09ICdzZWFyY2gnKSB7CiAgICAgIGNvbnN0IFtxLCBjLCBzLCBvZmZzZXRdID0g
;YXJnczsKICAgICAgbXNnID0gJ3NlYXJjaHwnICsgSlNPTi5zdHJpbmdpZnkoewogICAgICAgIHE6IHEgfHwgJycsIGNhdDogYyB8fCAnYWxsJywgc29ydDog
;cyB8fCAnZGF0ZS1kZXNjJywKICAgICAgICBkcml2ZTogZHJpdmUgfHwgJycsCiAgICAgICAgb2Zmc2V0OiBOdW1iZXIob2Zmc2V0KSB8fCAwLCBnZW46ICsr
;Z2VuCiAgICAgIH0pOwogICAgfSBlbHNlIGlmIChtZXRob2QgPT09ICdwcmV2aWV3JykgewogICAgICBtc2cgPSAncHJldmlld3wnICsgKGFyZ3NbMF0gfHwg
;JycpOwogICAgfSBlbHNlIGlmIChtZXRob2QgPT09ICdvcGVuJykgewogICAgICBtc2cgPSAnb3BlbnwnICsgKGFyZ3NbMF0gfHwgJycpOwogICAgfSBlbHNl
;IGlmIChtZXRob2QgPT09ICdyZXZlYWwnKSB7CiAgICAgIG1zZyA9ICdyZXZlYWx8JyArIChhcmdzWzBdIHx8ICcnKTsKICAgIH0gZWxzZSBpZiAobWV0aG9k
;ID09PSAnY29weUZpbGUnKSB7CiAgICAgIG1zZyA9ICdjb3B5RmlsZXwnICsgKGFyZ3NbMF0gfHwgJycpOwogICAgfSBlbHNlIGlmIChtZXRob2QgPT09ICdj
;b3B5UGF0aCcpIHsKICAgICAgbXNnID0gJ2NvcHlQYXRofCcgKyAoYXJnc1swXSB8fCAnJyk7CiAgICB9IGVsc2UgaWYgKG1ldGhvZCA9PT0gJ2NvcHlEaXIn
;KSB7CiAgICAgIG1zZyA9ICdjb3B5RGlyfCcgKyAoYXJnc1swXSB8fCAnJyk7CiAgICB9IGVsc2UgaWYgKG1ldGhvZCA9PT0gJ3JlY3ljbGUnKSB7CiAgICAg
;IG1zZyA9ICdyZWN5Y2xlfCcgKyAoYXJnc1swXSB8fCAnJyk7CiAgICB9IGVsc2UgaWYgKG1ldGhvZCA9PT0gJ2Nsb3NlJyB8fCBtZXRob2QgPT09ICdtaW5p
;bWl6ZScgfHwgbWV0aG9kID09PSAnbWF4aW1pemUnIHx8IG1ldGhvZCA9PT0gJ2RyYWcnKSB7CiAgICAgIG1zZyA9IG1ldGhvZDsKICAgIH0gZWxzZSB7CiAg
;ICAgIG1zZyA9IG1ldGhvZCArICd8JyArIGFyZ3MubWFwKGEgPT4gU3RyaW5nKGEgPz8gJycpKS5qb2luKCd8Jyk7CiAgICB9CiAgICBwb3N0KG1zZyk7CiAg
;fQoKICBmdW5jdGlvbiBzZXRCb290UGN0KHApIHsKICAgIHAgPSBNYXRoLm1heCgwLCBNYXRoLm1pbigxMDAsIE51bWJlcihwKSB8fCAwKSk7CiAgICBib290
;UGN0LnRleHRDb250ZW50ID0gTWF0aC5yb3VuZChwKSArICclJzsKICAgIHJpbmdGZy5zdHlsZS5zdHJva2VEYXNoYXJyYXkgPSBTdHJpbmcoQ0lSQyk7CiAg
;ICByaW5nRmcuc3R5bGUuc3Ryb2tlRGFzaG9mZnNldCA9IFN0cmluZyhDSVJDICogKDEgLSBwIC8gMTAwKSk7CiAgfQoKICBsZXQgYm9vdENtZFNlcSA9IDA7
;CiAgd2luZG93Ll9fc2V0Qm9vdCA9IChvbiwgcGN0LCBzZXEpID0+IHsKICAgIC8vIOW/veeVpeS5seW6j+i/n+WIsOeahCBBSEsgRXhlY3V0ZVNjcmlwdEFz
;eW5j77yM6YG/5YWN5Li755WM6Z2i6Zeq5Zue6L+b5bqm5p2hCiAgICBpZiAoc2VxICE9IG51bGwgJiYgc2VxICE9PSAnJyAmJiAhTnVtYmVyLmlzTmFOKE51
;bWJlcihzZXEpKSkgewogICAgICBzZXEgPSBOdW1iZXIoc2VxKTsKICAgICAgaWYgKHNlcSA8IGJvb3RDbWRTZXEpIHJldHVybjsKICAgICAgYm9vdENtZFNl
;cSA9IHNlcTsKICAgIH0KICAgIGlmIChvbikgewogICAgICBib290LmNsYXNzTGlzdC5hZGQoJ29uJyk7CiAgICAgIGNocm9tZS5jbGFzc0xpc3QuYWRkKCdo
;aWRkZW4nKTsKICAgICAgaWYgKGFwcFJvb3QpIGFwcFJvb3QuY2xhc3NMaXN0LmFkZCgnYm9vdGluZycpOwogICAgICBzZXRCb290UGN0KHBjdCk7CiAgICB9
;IGVsc2UgewogICAgICBib290LmNsYXNzTGlzdC5yZW1vdmUoJ29uJyk7CiAgICAgIGNocm9tZS5jbGFzc0xpc3QucmVtb3ZlKCdoaWRkZW4nKTsKICAgICAg
;aWYgKGFwcFJvb3QpIGFwcFJvb3QuY2xhc3NMaXN0LnJlbW92ZSgnYm9vdGluZycpOwogICAgICB0cnkgewogICAgICAgIGlmICh0eXBlb2YgYXBwTW9kZSA9
;PT0gJ3VuZGVmaW5lZCcgfHwgYXBwTW9kZSA9PT0gJ2ZpbGUnKQogICAgICAgICAgc2V0VGltZW91dCgoKSA9PiB7IHRyeSB7IGRvU2VhcmNoKCk7IH0gY2F0
;Y2ggKF8pIHt9IH0sIDYwKTsKICAgICAgfSBjYXRjaCAoXykge30KICAgIH0KICB9OwogIHdpbmRvdy5fX3NldEluZGV4UHJvZ3Jlc3MgPSAocGN0KSA9PiBz
;ZXRCb290UGN0KHBjdCk7CgogIHdpbmRvdy5fX3NldENhdEljb25zID0gKHBheWxvYWQpID0+IHsKICAgIHRyeSB7CiAgICAgIGNvbnN0IG1hcCA9IHR5cGVv
;ZiBwYXlsb2FkID09PSAnc3RyaW5nJyA/IEpTT04ucGFyc2UocGF5bG9hZCkgOiBwYXlsb2FkOwogICAgICBpZiAoIW1hcCB8fCB0eXBlb2YgbWFwICE9PSAn
;b2JqZWN0JykgcmV0dXJuOwogICAgICBkb2N1bWVudC5xdWVyeVNlbGVjdG9yQWxsKCcuY2F0JykuZm9yRWFjaChidG4gPT4gewogICAgICAgIGNvbnN0IGtl
;eSA9IGJ0bi5nZXRBdHRyaWJ1dGUoJ2RhdGEtY2F0Jyk7CiAgICAgICAgY29uc3QgdXJsID0gbWFwW2tleV07CiAgICAgICAgaWYgKCF1cmwpIHJldHVybjsK
;ICAgICAgICBsZXQgaW1nID0gYnRuLnF1ZXJ5U2VsZWN0b3IoJ2ltZy5pY28nKTsKICAgICAgICBpZiAoIWltZykgewogICAgICAgICAgY29uc3Qgb2xkID0g
;YnRuLnF1ZXJ5U2VsZWN0b3IoJy5pY28sIFtkYXRhLWNhdC1pY29dJyk7CiAgICAgICAgICBpbWcgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdpbWcnKTsK
;ICAgICAgICAgIGltZy5jbGFzc05hbWUgPSAnaWNvJzsKICAgICAgICAgIGltZy5hbHQgPSAnJzsKICAgICAgICAgIGlmIChvbGQpIG9sZC5yZXBsYWNlV2l0
;aChpbWcpOwogICAgICAgICAgZWxzZSBidG4uaW5zZXJ0QmVmb3JlKGltZywgYnRuLmZpcnN0Q2hpbGQpOwogICAgICAgIH0KICAgICAgICBpbWcuc3JjID0g
;dXJsICsgKHVybC5pbmNsdWRlcygnPycpID8gJyYnIDogJz8nKSArICd0PScgKyBEYXRlLm5vdygpOwogICAgICB9KTsKICAgIH0gY2F0Y2ggKGUpIHsgY29u
;c29sZS53YXJuKCdzZXRDYXRJY29ucycsIGUpOyB9CiAgfTsKCiAgZnVuY3Rpb24gZXh0T2YobmFtZSkgewogICAgY29uc3QgaSA9IFN0cmluZyhuYW1lIHx8
;ICcnKS5sYXN0SW5kZXhPZignLicpOwogICAgcmV0dXJuIGkgPiAwID8gbmFtZS5zbGljZShpICsgMSkudG9Mb3dlckNhc2UoKSA6ICcnOwogIH0KICBmdW5j
;dGlvbiBpY29uSHRtbChpdCkgewogICAgaWYgKGl0Lmljb24pIHsKICAgICAgcmV0dXJuICc8aW1nIHNyYz0iJyArIGVzY2FwZUh0bWwoaXQuaWNvbikgKyAn
;IiBhbHQ9IiIgbG9hZGluZz0ibGF6eSIgZGVjb2Rpbmc9ImFzeW5jIiBvbmVycm9yPSJ0aGlzLm91dGVySFRNTD1cJzxzcGFuIGNsYXNzPWZpLWZhbGxiYWNr
;PvCfk4Q8L3NwYW4+XCciPic7CiAgICB9CiAgICBpZiAoaXQuaXNEaXIpIHJldHVybiAnPHNwYW4gY2xhc3M9ImZpLWZhbGxiYWNrIj7wn5OBPC9zcGFuPic7
;CiAgICByZXR1cm4gJzxzcGFuIGNsYXNzPSJmaS1mYWxsYmFjayI+8J+ThDwvc3Bhbj4nOwogIH0KICBmdW5jdGlvbiBoaWdobGlnaHRIdG1sKHRleHQpIHsK
;ICAgIGNvbnN0IHJhdyA9IFN0cmluZyh0ZXh0ID8/ICcnKTsKICAgIGxldCBodG1sID0gZXNjYXBlSHRtbChyYXcpOwogICAgY29uc3QgcSA9IChxRWwudmFs
;dWUgfHwgJycpLnRyaW0oKTsKICAgIGlmICghcSkgcmV0dXJuIGh0bWw7CiAgICBjb25zdCB0ZXJtcyA9IHEuc3BsaXQoL1x8XHx8XHwvKS5mbGF0TWFwKHMg
;PT4gcy5zcGxpdCgvXHMrLykpLm1hcCh0ID0+IHQudHJpbSgpKS5maWx0ZXIoQm9vbGVhbik7CiAgICAvLyBsb25nZXIgdGVybXMgZmlyc3QgdG8gYXZvaWQg
;cGFydGlhbCBvdmVybGFwIGlzc3VlcwogICAgdGVybXMuc29ydCgoYSwgYikgPT4gYi5sZW5ndGggLSBhLmxlbmd0aCk7CiAgICBmb3IgKGNvbnN0IHQgb2Yg
;dGVybXMpIHsKICAgICAgaWYgKCF0KSBjb250aW51ZTsKICAgICAgY29uc3QgcmUgPSBuZXcgUmVnRXhwKHQucmVwbGFjZSgvWy4qKz9eJHt9KCl8W1xdXFxd
;L2csICdcXCQmJyksICdnaScpOwogICAgICBodG1sID0gaHRtbC5yZXBsYWNlKHJlLCBtID0+ICc8bWFyaz4nICsgbSArICc8L21hcms+Jyk7CiAgICB9CiAg
;ICByZXR1cm4gaHRtbDsKICB9CiAgZnVuY3Rpb24gcHJldHR5TmFtZShuYW1lKSB7CiAgICBuYW1lID0gU3RyaW5nKG5hbWUgfHwgJycpOwogICAgaWYgKCFu
;YW1lKSByZXR1cm4gJyc7CiAgICBjb25zdCBlID0gZXh0T2YobmFtZSk7CiAgICBpZiAoIWUgfHwgbmFtZS5zdGFydHNXaXRoKCcuJykpIHJldHVybiBoaWdo
;bGlnaHRIdG1sKG5hbWUpOwogICAgY29uc3QgYmFzZSA9IG5hbWUuc2xpY2UoMCwgLShlLmxlbmd0aCArIDEpKTsKICAgIHJldHVybiBoaWdobGlnaHRIdG1s
;KGJhc2UpICsgJzxzcGFuIGNsYXNzPSJleHQiPi4nICsgZXNjYXBlSHRtbChlKSArICc8L3NwYW4+JzsKICB9CiAgZnVuY3Rpb24gZGlzcGxheU5hbWUoaXQp
;IHsKICAgIGxldCBuID0gU3RyaW5nKGl0Lm5hbWUgfHwgJycpLnRyaW0oKTsKICAgIGlmIChuKSByZXR1cm4gbjsKICAgIC8vIGZhbGxiYWNrOiBsYXN0IHNl
;Z21lbnQgb2YgcGF0aAogICAgY29uc3QgcCA9IFN0cmluZyhpdC5wYXRoIHx8ICcnKS5yZXBsYWNlKC9bXFwvXSskLywgJycpOwogICAgY29uc3QgaSA9IE1h
;dGgubWF4KHAubGFzdEluZGV4T2YoJ1xcJyksIHAubGFzdEluZGV4T2YoJy8nKSk7CiAgICByZXR1cm4gaSA+PSAwID8gcC5zbGljZShpICsgMSkgOiBwOwog
;IH0KICBmdW5jdGlvbiBlc2NhcGVIdG1sKHMpIHsKICAgIHJldHVybiBTdHJpbmcocyA/PyAnJykucmVwbGFjZSgvJi9nLCcmYW1wOycpLnJlcGxhY2UoLzwv
;ZywnJmx0OycpLnJlcGxhY2UoLz4vZywnJmd0OycpLnJlcGxhY2UoLyIvZywnJnF1b3Q7Jyk7CiAgfQogIGZ1bmN0aW9uIHNob3J0UGF0aChwKSB7CiAgICBw
;ID0gU3RyaW5nKHAgfHwgJycpOwogICAgaWYgKHAubGVuZ3RoIDw9IDU2KSByZXR1cm4gcDsKICAgIHJldHVybiBwLnNsaWNlKDAsIDI4KSArICcuLi4nICsg
;cC5zbGljZSgtMjQpOwogIH0KCiAgZnVuY3Rpb24gdXBkYXRlQ291bnQoKSB7CiAgICBpZiAoIWl0ZW1zLmxlbmd0aCkgewogICAgICBjb3VudEVsLnRleHRD
;b250ZW50ID0gJ+WFsSAwIOadoee7k+aenCc7CiAgICAgIHJldHVybjsKICAgIH0KICAgIGNvbnN0IHNob3duID0gaXRlbXMubGVuZ3RoOwogICAgY291bnRF
;bC50ZXh0Q29udGVudCA9IHRvdGFsSGl0cyA+IHNob3duCiAgICAgID8gKCflhbEgJyArIHRvdGFsSGl0cy50b0xvY2FsZVN0cmluZygpICsgJyDmnaHnu5Pm
;npzvvIjlt7LliqDovb0gJyArIHNob3duLnRvTG9jYWxlU3RyaW5nKCkgKyAnIOadoe+8iScpCiAgICAgIDogKCflhbEgJyArIE1hdGgubWF4KHRvdGFsSGl0
;cywgc2hvd24pLnRvTG9jYWxlU3RyaW5nKCkgKyAnIOadoee7k+aenCcpOwogIH0KCiAgZnVuY3Rpb24gbWFrZVJvdyhpdCwgaSkgewogICAgY29uc3Qgcm93
;ID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnZGl2Jyk7CiAgICByb3cuY2xhc3NOYW1lID0gJ3JvdycgKyAoaSA9PT0gc2VsZWN0ZWQgPyAnIG9uJyA6ICcn
;KTsKICAgIGNvbnN0IHRpdGxlID0gZGlzcGxheU5hbWUoaXQpOwogICAgcm93LmlubmVySFRNTCA9IGA8ZGl2IGNsYXNzPSJmaSI+JHtpY29uSHRtbChpdCl9
;PC9kaXY+CiAgICAgIDxkaXY+CiAgICAgICAgPGRpdiBjbGFzcz0ibmFtZSI+JHtwcmV0dHlOYW1lKHRpdGxlKX08L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNz
;PSJwYXRoIiB0aXRsZT0iJHtlc2NhcGVIdG1sKGl0LnBhdGgpfSI+JHtlc2NhcGVIdG1sKHNob3J0UGF0aChpdC5wYXRoKSl9PC9kaXY+CiAgICAgIDwvZGl2
;PmA7CiAgICByb3cub25jbGljayA9ICgpID0+IHsgaGlkZUN0eCgpOyBzZWxlY3RSb3coaSk7IH07CiAgICByb3cub25kYmxjbGljayA9ICgpID0+IHsKICAg
;ICAgaGlkZUN0eCgpOwogICAgICBwdXNoSGlzdChxRWwudmFsdWUgfHwgJycpOwogICAgICBjYWxsSG9zdCgnb3BlbicsIGl0LnBhdGgpOwogICAgfTsKICAg
;IHJvdy5vbmNvbnRleHRtZW51ID0gKGUpID0+IHsKICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOwogICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgICBz
;ZWxlY3RSb3coaSk7CiAgICAgIHNob3dDdHgoZS5jbGllbnRYLCBlLmNsaWVudFksIGl0LnBhdGgpOwogICAgfTsKICAgIHJldHVybiByb3c7CiAgfQoKICBj
;b25zdCBjdHhFbCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjdHgnKTsKICBsZXQgY3R4UGF0aCA9ICcnOwogIGZ1bmN0aW9uIGhpZGVDdHgoKSB7CiAg
;ICBjdHhFbC5jbGFzc0xpc3QucmVtb3ZlKCdvbicpOwogICAgY3R4UGF0aCA9ICcnOwogIH0KICBmdW5jdGlvbiBzaG93Q3R4KHgsIHksIHBhdGgpIHsKICAg
;IGN0eFBhdGggPSBTdHJpbmcocGF0aCB8fCAnJyk7CiAgICBpZiAoIWN0eFBhdGgpIHJldHVybjsKICAgIGN0eEVsLmNsYXNzTGlzdC5hZGQoJ29uJyk7CiAg
;ICBjb25zdCBwYWQgPSA2OwogICAgY29uc3QgdncgPSB3aW5kb3cuaW5uZXJXaWR0aDsKICAgIGNvbnN0IHZoID0gd2luZG93LmlubmVySGVpZ2h0OwogICAg
;Y3R4RWwuc3R5bGUubGVmdCA9ICcwcHgnOwogICAgY3R4RWwuc3R5bGUudG9wID0gJzBweCc7CiAgICBjb25zdCByZWN0ID0gY3R4RWwuZ2V0Qm91bmRpbmdD
;bGllbnRSZWN0KCk7CiAgICBsZXQgbGVmdCA9IHg7CiAgICBsZXQgdG9wID0geTsKICAgIGlmIChsZWZ0ICsgcmVjdC53aWR0aCA+IHZ3IC0gcGFkKSBsZWZ0
;ID0gTWF0aC5tYXgocGFkLCB2dyAtIHJlY3Qud2lkdGggLSBwYWQpOwogICAgaWYgKHRvcCArIHJlY3QuaGVpZ2h0ID4gdmggLSBwYWQpIHRvcCA9IE1hdGgu
;bWF4KHBhZCwgdmggLSByZWN0LmhlaWdodCAtIHBhZCk7CiAgICBjdHhFbC5zdHlsZS5sZWZ0ID0gbGVmdCArICdweCc7CiAgICBjdHhFbC5zdHlsZS50b3Ag
;PSB0b3AgKyAncHgnOwogIH0KICBjdHhFbC5xdWVyeVNlbGVjdG9yQWxsKCdidXR0b25bZGF0YS1hY3RdJykuZm9yRWFjaChidG4gPT4gewogICAgYnRuLmFk
;ZEV2ZW50TGlzdGVuZXIoJ2NsaWNrJywgKGUpID0+IHsKICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgY29uc3QgYWN0ID0gYnRuLmdldEF0dHJp
;YnV0ZSgnZGF0YS1hY3QnKTsKICAgICAgY29uc3QgcGF0aCA9IGN0eFBhdGg7CiAgICAgIGhpZGVDdHgoKTsKICAgICAgaWYgKCFwYXRoIHx8ICFhY3QpIHJl
;dHVybjsKICAgICAgaWYgKGFjdCA9PT0gJ3JldmVhbCcpIGNhbGxIb3N0KCdyZXZlYWwnLCBwYXRoKTsKICAgICAgZWxzZSBpZiAoYWN0ID09PSAnY29weScp
;IGNhbGxIb3N0KCdjb3B5RmlsZScsIHBhdGgpOwogICAgICBlbHNlIGlmIChhY3QgPT09ICdjb3B5UGF0aCcpIGNhbGxIb3N0KCdjb3B5UGF0aCcsIHBhdGgp
;OwogICAgICBlbHNlIGlmIChhY3QgPT09ICdjb3B5RGlyJykgY2FsbEhvc3QoJ2NvcHlEaXInLCBwYXRoKTsKICAgICAgZWxzZSBpZiAoYWN0ID09PSAncmVj
;eWNsZScpIGNhbGxIb3N0KCdyZWN5Y2xlJywgcGF0aCk7CiAgICB9KTsKICB9KTsKICBkb2N1bWVudC5hZGRFdmVudExpc3RlbmVyKCdjb250ZXh0bWVudScs
;IChlKSA9PiB7CiAgICBpZiAoIWUudGFyZ2V0LmNsb3Nlc3QoJyNsaXN0IC5yb3cnKSAmJiAhZS50YXJnZXQuY2xvc2VzdCgnI2N0eCcpKSBoaWRlQ3R4KCk7
;CiAgfSk7CiAgd2luZG93LmFkZEV2ZW50TGlzdGVuZXIoJ2JsdXInLCBoaWRlQ3R4KTsKICB3aW5kb3cuYWRkRXZlbnRMaXN0ZW5lcigncmVzaXplJywgaGlk
;ZUN0eCk7CiAgd2luZG93Ll9fcmVtb3ZlUGF0aCA9IChwYXRoKSA9PiB7CiAgICBwYXRoID0gU3RyaW5nKHBhdGggfHwgJycpOwogICAgaWYgKCFwYXRoKSBy
;ZXR1cm47CiAgICBjb25zdCBwcmV2U2VsID0gc2VsZWN0ZWQgPj0gMCA/IChpdGVtc1tzZWxlY3RlZF0gJiYgaXRlbXNbc2VsZWN0ZWRdLnBhdGgpIDogJyc7
;CiAgICBpdGVtcyA9IGl0ZW1zLmZpbHRlcihpdCA9PiBTdHJpbmcoaXQucGF0aCB8fCAnJykgIT09IHBhdGgpOwogICAgaWYgKHRvdGFsSGl0cyA+IDApIHRv
;dGFsSGl0cyA9IE1hdGgubWF4KDAsIHRvdGFsSGl0cyAtIDEpOwogICAgc2VsZWN0ZWQgPSAtMTsKICAgIGlmIChwcmV2U2VsICYmIHByZXZTZWwgIT09IHBh
;dGgpIHsKICAgICAgc2VsZWN0ZWQgPSBpdGVtcy5maW5kSW5kZXgoaXQgPT4gaXQucGF0aCA9PT0gcHJldlNlbCk7CiAgICB9IGVsc2UgaWYgKGl0ZW1zLmxl
;bmd0aCkgewogICAgICBzZWxlY3RlZCA9IE1hdGgubWluKHNlbGVjdGVkIDwgMCA/IDAgOiBzZWxlY3RlZCwgaXRlbXMubGVuZ3RoIC0gMSk7CiAgICB9CiAg
;ICByZW5kZXJMaXN0KGZhbHNlKTsKICAgIGlmIChzZWxlY3RlZCA+PSAwICYmIHByZXZpZXdPbikgcmVxdWVzdFByZXZpZXcoaXRlbXNbc2VsZWN0ZWRdKTsK
;ICAgIGVsc2UgewogICAgICBwdk1ldGEudGV4dENvbnRlbnQgPSAn6YCJ5oup5paH5Lu25Lul6aKE6KeIJzsKICAgICAgcHZNZWRpYS5pbm5lckhUTUwgPSAn
;PGRpdiBjbGFzcz0icGgiPumihOiniOWMujwvZGl2Pic7CiAgICAgIHB2VGV4dC5zdHlsZS5kaXNwbGF5ID0gJ25vbmUnOwogICAgfQogIH07CgogIGZ1bmN0
;aW9uIHJlbmRlckxpc3QoYXBwZW5kKSB7CiAgICBpZiAoIWFwcGVuZCkgbGlzdEVsLmlubmVySFRNTCA9ICcnOwogICAgaWYgKCFpdGVtcy5sZW5ndGgpIHsK
;ICAgICAgZW1wdHlFbC5jbGFzc0xpc3QuYWRkKCdvbicpOwogICAgICB1cGRhdGVDb3VudCgpOwogICAgICByZXR1cm47CiAgICB9CiAgICBlbXB0eUVsLmNs
;YXNzTGlzdC5yZW1vdmUoJ29uJyk7CiAgICBjb25zdCBzdGFydCA9IGFwcGVuZCA/IGxpc3RFbC5xdWVyeVNlbGVjdG9yQWxsKCcucm93JykubGVuZ3RoIDog
;MDsKICAgIGNvbnN0IGZyYWcgPSBkb2N1bWVudC5jcmVhdGVEb2N1bWVudEZyYWdtZW50KCk7CiAgICBmb3IgKGxldCBpID0gc3RhcnQ7IGkgPCBpdGVtcy5s
;ZW5ndGg7IGkrKykKICAgICAgZnJhZy5hcHBlbmRDaGlsZChtYWtlUm93KGl0ZW1zW2ldLCBpKSk7CiAgICBsaXN0RWwuYXBwZW5kQ2hpbGQoZnJhZyk7CiAg
;ICB1cGRhdGVDb3VudCgpOwogIH0KCiAgZnVuY3Rpb24gc2VsZWN0Um93KGksIG9wdHMpIHsKICAgIHNlbGVjdGVkID0gaTsKICAgIGNvbnN0IHJvd3MgPSBs
;aXN0RWwuY2hpbGRyZW47CiAgICBmb3IgKGxldCBpZHggPSAwOyBpZHggPCByb3dzLmxlbmd0aDsgaWR4KyspCiAgICAgIHJvd3NbaWR4XS5jbGFzc0xpc3Qu
;dG9nZ2xlKCdvbicsIGlkeCA9PT0gaSk7CiAgICBjb25zdCBpdCA9IGl0ZW1zW2ldOwogICAgaWYgKCFpdCkgcmV0dXJuOwogICAgaWYgKHByZXZpZXdPbikg
;c2NoZWR1bGVQcmV2aWV3KGl0LCBvcHRzICYmIG9wdHMuaW1tZWRpYXRlKTsKICB9CiAgbGV0IHByZXZpZXdUaW1lciA9IDA7CiAgbGV0IHByZXZpZXdUb2tl
;biA9IDA7CiAgZnVuY3Rpb24gc2NoZWR1bGVQcmV2aWV3KGl0LCBpbW1lZGlhdGUpIHsKICAgIGNsZWFyVGltZW91dChwcmV2aWV3VGltZXIpOwogICAgY29u
;c3QgdG9rID0gKytwcmV2aWV3VG9rZW47CiAgICBjb25zdCBwYXRoID0gaXQgJiYgaXQucGF0aDsKICAgIGNvbnN0IHJ1biA9ICgpID0+IHsKICAgICAgaWYg
;KHRvayAhPT0gcHJldmlld1Rva2VuIHx8ICFwcmV2aWV3T24pIHJldHVybjsKICAgICAgaWYgKHNlbGVjdGVkIDwgMCB8fCAhaXRlbXNbc2VsZWN0ZWRdIHx8
;IGl0ZW1zW3NlbGVjdGVkXS5wYXRoICE9PSBwYXRoKSByZXR1cm47CiAgICAgIHJlcXVlc3RQcmV2aWV3KGl0ZW1zW3NlbGVjdGVkXSk7CiAgICB9OwogICAg
;aWYgKGltbWVkaWF0ZSkgcnVuKCk7CiAgICBlbHNlIHByZXZpZXdUaW1lciA9IHNldFRpbWVvdXQocnVuLCAzNjApOwogIH0KCiAgZnVuY3Rpb24gcmVxdWVz
;dFByZXZpZXcoaXQpIHsKICAgIHB2TWV0YS5pbm5lckhUTUwgPSBgPHNwYW4+5ZCN56ewIDxiPiR7ZXNjYXBlSHRtbChpdC5uYW1lKX08L2I+PC9zcGFuPmA7
;CiAgICBpZiAocHZCb2R5KSBwdkJvZHkuY2xhc3NMaXN0LnJlbW92ZSgndGV4dC1tb2RlJyk7CiAgICBwdk1lZGlhLmlubmVySFRNTCA9ICc8ZGl2IGNsYXNz
;PSJwaCI+5Yqg6L296aKE6KeI4oCmPC9kaXY+JzsKICAgIHB2VGV4dC5zdHlsZS5kaXNwbGF5ID0gJ25vbmUnOwogICAgY2FsbEhvc3QoJ3ByZXZpZXcnLCBp
;dC5wYXRoKTsKICB9CgogIGZ1bmN0aW9uIHRyeUxvYWRNb3JlKCkgewogICAgaWYgKCFoYXNNb3JlIHx8IGxvYWRpbmdNb3JlKSByZXR1cm47CiAgICBsb2Fk
;aW5nTW9yZSA9IHRydWU7CiAgICBjYWxsSG9zdCgnc2VhcmNoJywgY29tcG9zZVNlYXJjaFF1ZXJ5KCksIGNhdCwgc29ydCwgaXRlbXMubGVuZ3RoKTsKICB9
;CgogIGZ1bmN0aW9uIG1heWJlRmlsbFZpZXdwb3J0KCkgewogICAgLy8g6aaW5bGP5Y+q5pyJIDE1IOadoeaXtuWPr+iDveS4jeWkn+a7muWKqO+8jOiHquWK
;qOihpemhteebtOWIsOWPr+a7muaIluayoeacieabtOWkmgogICAgaWYgKCFoYXNNb3JlIHx8IGxvYWRpbmdNb3JlKSByZXR1cm47CiAgICBpZiAobGlzdEVs
;LnNjcm9sbEhlaWdodCA8PSBsaXN0RWwuY2xpZW50SGVpZ2h0ICsgOCkKICAgICAgdHJ5TG9hZE1vcmUoKTsKICB9CgogIGxpc3RFbC5hZGRFdmVudExpc3Rl
;bmVyKCdzY3JvbGwnLCAoKSA9PiB7CiAgICBpZiAobGlzdEVsLnNjcm9sbFRvcCArIGxpc3RFbC5jbGllbnRIZWlnaHQgPj0gbGlzdEVsLnNjcm9sbEhlaWdo
;dCAtIDEyMCkKICAgICAgdHJ5TG9hZE1vcmUoKTsKICB9KTsKCiAgd2luZG93Ll9fdXBkYXRlUmVzdWx0cyA9IChwYXlsb2FkKSA9PiB7CiAgICB0cnkgewog
;ICAgICBjb25zdCBkYXRhID0gdHlwZW9mIHBheWxvYWQgPT09ICdzdHJpbmcnID8gSlNPTi5wYXJzZShwYXlsb2FkKSA6IHBheWxvYWQ7CiAgICAgIGNvbnN0
;IGJhdGNoID0gQXJyYXkuaXNBcnJheShkYXRhLml0ZW1zKSA/IGRhdGEuaXRlbXMgOiBbXTsKICAgICAgY29uc3QgdG90YWwgPSBOdW1iZXIoZGF0YS50b3Rh
;bCAhPSBudWxsID8gZGF0YS50b3RhbCA6IDApIHx8IDA7CiAgICAgIGNvbnN0IG9mZnNldCA9IE51bWJlcihkYXRhLm9mZnNldCkgfHwgMDsKICAgICAgY29u
;c3QgYXBwZW5kID0gISFkYXRhLmFwcGVuZCAmJiBvZmZzZXQgPiAwOwogICAgICBjb25zdCBwYWdlU2l6ZSA9IE1hdGgubWF4KDEsIE51bWJlcihkYXRhLnBh
;Z2VTaXplKSB8fCA1MCk7CgogICAgICBpZiAodG90YWwgPj0gMCkKICAgICAgICB0b3RhbEhpdHMgPSB0b3RhbDsKICAgICAgaWYgKGFwcGVuZCkgewogICAg
;ICAgIGNvbnN0IHNlZW4gPSBuZXcgU2V0KGl0ZW1zLm1hcCh4ID0+IHgucGF0aCkpOwogICAgICAgIGZvciAoY29uc3QgaXQgb2YgYmF0Y2gpIHsKICAgICAg
;ICAgIGlmICghc2Vlbi5oYXMoaXQucGF0aCkpIGl0ZW1zLnB1c2goaXQpOwogICAgICAgIH0KICAgICAgICBsb2FkaW5nTW9yZSA9IGZhbHNlOwogICAgICAg
;IC8vIOa7oemhteWwsee7p+e7reWKoOi9ve+8m+WQjOaXtuS7peacjeWKoeerr+aAu+aVsOS4uuWHhgogICAgICAgIGhhc01vcmUgPSBiYXRjaC5sZW5ndGgg
;Pj0gcGFnZVNpemUgfHwgKHRvdGFsSGl0cyA+IDAgJiYgaXRlbXMubGVuZ3RoIDwgdG90YWxIaXRzKTsKICAgICAgICByZW5kZXJMaXN0KHRydWUpOwogICAg
;ICB9IGVsc2UgewogICAgICAgIGl0ZW1zID0gYmF0Y2g7CiAgICAgICAgbG9hZGluZ01vcmUgPSBmYWxzZTsKICAgICAgICBoYXNNb3JlID0gYmF0Y2gubGVu
;Z3RoID49IHBhZ2VTaXplIHx8ICh0b3RhbEhpdHMgPiAwICYmIGl0ZW1zLmxlbmd0aCA8IHRvdGFsSGl0cyk7CiAgICAgICAgc2VsZWN0ZWQgPSBpdGVtcy5s
;ZW5ndGggPyAwIDogLTE7CiAgICAgICAgcmVuZGVyTGlzdChmYWxzZSk7CiAgICAgICAgaWYgKHNlbGVjdGVkID49IDAgJiYgcHJldmlld09uKSBzY2hlZHVs
;ZVByZXZpZXcoaXRlbXNbc2VsZWN0ZWRdKTsKICAgICAgICBlbHNlIGlmICghaXRlbXMubGVuZ3RoKSB7CiAgICAgICAgICBjbGVhclRpbWVvdXQocHJldmll
;d1RpbWVyKTsKICAgICAgICAgIHByZXZpZXdUb2tlbiArPSAxOwogICAgICAgICAgaWYgKHB2Qm9keSkgcHZCb2R5LmNsYXNzTGlzdC5yZW1vdmUoJ3RleHQt
;bW9kZScpOwogICAgICAgICAgcHZNZXRhLnRleHRDb250ZW50ID0gJ+mAieaLqeaWh+S7tuS7pemihOiniCc7CiAgICAgICAgICBwdk1lZGlhLmlubmVySFRN
;TCA9ICc8ZGl2IGNsYXNzPSJwaCI+6aKE6KeI5Yy6PC9kaXY+JzsKICAgICAgICAgIHB2VGV4dC5zdHlsZS5kaXNwbGF5ID0gJ25vbmUnOwogICAgICAgIH0K
;ICAgICAgfQogICAgICB1cGRhdGVDb3VudCgpOwogICAgICByZXF1ZXN0QW5pbWF0aW9uRnJhbWUobWF5YmVGaWxsVmlld3BvcnQpOwogICAgfSBjYXRjaCAo
;ZSkgewogICAgICBjb25zb2xlLmVycm9yKGUpOwogICAgICBsb2FkaW5nTW9yZSA9IGZhbHNlOwogICAgICBjb3VudEVsLnRleHRDb250ZW50ID0gJ+e7k+ae
;nOabtOaWsOWksei0pSc7CiAgICB9CiAgfTsKCiAgd2luZG93Ll9fc2V0UHJldmlldyA9IChwYXlsb2FkKSA9PiB7CiAgICB0cnkgewogICAgICBjb25zdCBk
;YXRhID0gdHlwZW9mIHBheWxvYWQgPT09ICdzdHJpbmcnID8gSlNPTi5wYXJzZShwYXlsb2FkKSA6IHBheWxvYWQ7CiAgICAgIGNvbnN0IGtpbmQgPSBkYXRh
;LmtpbmQgfHwgJ25vbmUnOwogICAgICBjb25zdCBiaXRzID0gW107CiAgICAgIGNvbnN0IGRydk1hdGNoID0gU3RyaW5nKGRhdGEucGF0aCB8fCAnJykubWF0
;Y2goL14oW0EtWmEtel0pOi8pOwogICAgICBpZiAoZHJ2TWF0Y2gpIHsKICAgICAgICBjb25zdCBsZXR0ZXIgPSBkcnZNYXRjaFsxXS50b1VwcGVyQ2FzZSgp
;OwogICAgICAgIGNvbnN0IGhpdCA9IChkcml2ZU1ldGEuZHJpdmVzIHx8IFtdKS5maW5kKGQgPT4gU3RyaW5nKGQubGV0dGVyIHx8ICcnKS50b1VwcGVyQ2Fz
;ZSgpID09PSBsZXR0ZXIpOwogICAgICAgIGNvbnN0IGljbyA9IChoaXQgJiYgaGl0Lmljb24pID8gKCc8aW1nIHNyYz0iJyArIGVzY2FwZUh0bWwoaGl0Lmlj
;b24pICsgJyIgYWx0PSIiPicpIDogJyc7CiAgICAgICAgY29uc3QgbGFiZWwgPSAoaGl0ICYmIGhpdC5sYWJlbCkgPyBoaXQubGFiZWwgOiAobGV0dGVyICsg
;JzonKTsKICAgICAgICBiaXRzLnB1c2goJzxzcGFuIGNsYXNzPSJkcnYiPicgKyBpY28gKyBlc2NhcGVIdG1sKGxhYmVsKSArICc8L3NwYW4+Jyk7CiAgICAg
;IH0KICAgICAgaWYgKGRhdGEuZW5jb2RpbmcpIGJpdHMucHVzaCgn57yW56CBIDxiPicgKyBlc2NhcGVIdG1sKGRhdGEuZW5jb2RpbmcpICsgJzwvYj4nKTsK
;ICAgICAgaWYgKGRhdGEuc2l6ZVRleHQpIGJpdHMucHVzaCgn5aSn5bCPIDxiPicgKyBlc2NhcGVIdG1sKGRhdGEuc2l6ZVRleHQpICsgJzwvYj4nKTsKICAg
;ICAgaWYgKGRhdGEuZGltcykgYml0cy5wdXNoKCflsLrlr7ggPGI+JyArIGVzY2FwZUh0bWwoZGF0YS5kaW1zKSArICc8L2I+Jyk7CiAgICAgIGlmIChkYXRh
;Lm10aW1lKSBiaXRzLnB1c2goJ+S/ruaUuSA8Yj4nICsgZXNjYXBlSHRtbChkYXRhLm10aW1lKSArICc8L2I+Jyk7CiAgICAgIHB2TWV0YS5pbm5lckhUTUwg
;PSBiaXRzLmpvaW4oJzxzcGFuIHN0eWxlPSJvcGFjaXR5Oi4zNSI+wrc8L3NwYW4+JykgfHwgJ+mihOiniCc7CiAgICAgIHB2VGV4dC5zdHlsZS5kaXNwbGF5
;ID0gJ25vbmUnOwogICAgICBpZiAocHZCb2R5KSBwdkJvZHkuY2xhc3NMaXN0LnJlbW92ZSgndGV4dC1tb2RlJyk7CgogICAgICBpZiAoa2luZCA9PT0gJ2lt
;YWdlJyAmJiBkYXRhLnVybCkgewogICAgICAgIHB2TWVkaWEuaW5uZXJIVE1MID0gJyc7CiAgICAgICAgY29uc3QgaW1nID0gZG9jdW1lbnQuY3JlYXRlRWxl
;bWVudCgnaW1nJyk7CiAgICAgICAgaW1nLnNyYyA9IGRhdGEudXJsOwogICAgICAgIGltZy5hbHQgPSAnJzsKICAgICAgICBwdk1lZGlhLmFwcGVuZENoaWxk
;KGltZyk7CiAgICAgIH0gZWxzZSBpZiAoa2luZCA9PT0gJ3ZpZGVvJykgewogICAgICAgIHB2TWVkaWEuaW5uZXJIVE1MID0gJyc7CiAgICAgICAgcHZNZWRp
;YS5zdHlsZS5mbGV4RGlyZWN0aW9uID0gJ2NvbHVtbic7CiAgICAgICAgaWYgKGRhdGEudXJsKSB7CiAgICAgICAgICBjb25zdCB2ID0gZG9jdW1lbnQuY3Jl
;YXRlRWxlbWVudCgndmlkZW8nKTsKICAgICAgICAgIHYuY29udHJvbHMgPSB0cnVlOwogICAgICAgICAgdi5wcmVsb2FkID0gJ21ldGFkYXRhJzsKICAgICAg
;ICAgIHYuc3JjID0gZGF0YS51cmw7CiAgICAgICAgICB2LnN0eWxlLm1heFdpZHRoID0gJzEwMCUnOwogICAgICAgICAgdi5zdHlsZS5tYXhIZWlnaHQgPSBk
;YXRhLnRodW1iID8gJzcwJScgOiAnMTAwJSc7CiAgICAgICAgICB2Lm9uZXJyb3IgPSAoKSA9PiB7CiAgICAgICAgICAgIGlmIChkYXRhLnRodW1iKSB7CiAg
;ICAgICAgICAgICAgdi5yZXBsYWNlV2l0aChPYmplY3QuYXNzaWduKGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2ltZycpLCB7CiAgICAgICAgICAgICAgICBz
;cmM6IGRhdGEudGh1bWIsIHN0eWxlOiAnbWF4LXdpZHRoOjEwMCU7bWF4LWhlaWdodDo4MCU7b2JqZWN0LWZpdDpjb250YWluJwogICAgICAgICAgICAgIH0p
;KTsKICAgICAgICAgICAgfQogICAgICAgICAgfTsKICAgICAgICAgIHB2TWVkaWEuYXBwZW5kQ2hpbGQodik7CiAgICAgICAgfSBlbHNlIGlmIChkYXRhLnRo
;dW1iKSB7CiAgICAgICAgICBjb25zdCBpbWcgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdpbWcnKTsKICAgICAgICAgIGltZy5zcmMgPSBkYXRhLnRodW1i
;OwogICAgICAgICAgaW1nLnN0eWxlLm1heFdpZHRoID0gJzEwMCUnOwogICAgICAgICAgaW1nLnN0eWxlLm1heEhlaWdodCA9ICc4MCUnOwogICAgICAgICAg
;aW1nLnN0eWxlLm9iamVjdEZpdCA9ICdjb250YWluJzsKICAgICAgICAgIHB2TWVkaWEuYXBwZW5kQ2hpbGQoaW1nKTsKICAgICAgICB9IGVsc2UgewogICAg
;ICAgICAgcHZNZWRpYS5pbm5lckhUTUwgPSAnPGRpdiBjbGFzcz0icGgiPuaXoOazlemihOiniOatpOinhumike+8jOivt+WPjOWHu+aJk+W8gDwvZGl2Pic7
;CiAgICAgICAgfQogICAgICB9IGVsc2UgaWYgKGtpbmQgPT09ICdhdWRpbycpIHsKICAgICAgICBwdk1lZGlhLmlubmVySFRNTCA9ICcnOwogICAgICAgIGNv
;bnN0IHdyYXAgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsKICAgICAgICB3cmFwLmNsYXNzTmFtZSA9ICdwdi1maWxlaW5mbyc7CiAgICAgICAg
;d3JhcC5zdHlsZS5iYWNrZ3JvdW5kID0gJyMzZjQ0NTAnOwogICAgICAgIHdyYXAuc3R5bGUuY29sb3IgPSAnI2U1ZTdlYic7CiAgICAgICAgaWYgKGRhdGEu
;aWNvbikgd3JhcC5pbm5lckhUTUwgPSAnPGltZyBjbGFzcz0iYmlnLWljbyIgc3JjPSInICsgZXNjYXBlSHRtbChkYXRhLmljb24pICsgJyIgYWx0PSIiPic7
;CiAgICAgICAgd3JhcC5pbm5lckhUTUwgKz0gJzxkaXYgY2xhc3M9ImZuIiBzdHlsZT0iY29sb3I6I2ZmZiI+JyArIGVzY2FwZUh0bWwoZGF0YS5uYW1lIHx8
;ICcnKSArICc8L2Rpdj4nOwogICAgICAgIHB2TWVkaWEuYXBwZW5kQ2hpbGQod3JhcCk7CiAgICAgICAgaWYgKGRhdGEudXJsKSB7CiAgICAgICAgICBjb25z
;dCBhID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnYXVkaW8nKTsKICAgICAgICAgIGEuY29udHJvbHMgPSB0cnVlOwogICAgICAgICAgYS5zcmMgPSBkYXRh
;LnVybDsKICAgICAgICAgIGEuc3R5bGUud2lkdGggPSAnODYlJzsKICAgICAgICAgIGEuc3R5bGUubWFyZ2luVG9wID0gJzEycHgnOwogICAgICAgICAgd3Jh
;cC5hcHBlbmRDaGlsZChhKTsKICAgICAgICB9CiAgICAgIH0gZWxzZSBpZiAoa2luZCA9PT0gJ3BkZicgJiYgZGF0YS51cmwpIHsKICAgICAgICBwdk1lZGlh
;LmlubmVySFRNTCA9ICcnOwogICAgICAgIGNvbnN0IGVtYiA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2VtYmVkJyk7CiAgICAgICAgZW1iLmNsYXNzTmFt
;ZSA9ICdwZGYnOwogICAgICAgIGVtYi50eXBlID0gJ2FwcGxpY2F0aW9uL3BkZic7CiAgICAgICAgZW1iLnNyYyA9IGRhdGEudXJsOwogICAgICAgIHB2TWVk
;aWEuYXBwZW5kQ2hpbGQoZW1iKTsKICAgICAgfSBlbHNlIGlmIChraW5kID09PSAndGV4dCcpIHsKICAgICAgICBpZiAocHZCb2R5KSBwdkJvZHkuY2xhc3NM
;aXN0LmFkZCgndGV4dC1tb2RlJyk7CiAgICAgICAgcHZNZWRpYS5pbm5lckhUTUwgPSAnJzsKICAgICAgICBwdlRleHQuc3R5bGUuZGlzcGxheSA9ICdmbGV4
;JzsKICAgICAgICBwdlRleHRIZC50ZXh0Q29udGVudCA9IGRhdGEudGV4dFRpdGxlIHx8ICfpooTop4jliY0gMjBLQiDlhoXlrrknOwogICAgICAgIHB2UHJl
;LnRleHRDb250ZW50ID0gZGF0YS50ZXh0IHx8ICcnOwogICAgICB9IGVsc2UgaWYgKGtpbmQgPT09ICdmb2xkZXInIHx8IGtpbmQgPT09ICdmaWxlaW5mbycp
;IHsKICAgICAgICAvLyBBbHdheXMgcHJlZmVyIGNsZWFuIHNoZWxsIGljb24g4oCUIG5ldmVyIHVzZSBibGFjay1tYXR0ZSB0aHVtYm5haWxzIGhlcmUKICAg
;ICAgICBjb25zdCBpY29TcmMgPSBkYXRhLmljb24gfHwgJyc7CiAgICAgICAgY29uc3QgaWNvID0gaWNvU3JjCiAgICAgICAgICA/ICc8aW1nIGNsYXNzPSJi
;aWctaWNvIiBzcmM9IicgKyBlc2NhcGVIdG1sKGljb1NyYykgKyAnIiBhbHQ9IiI+JwogICAgICAgICAgOiAnPGRpdiBjbGFzcz0iYmlnLWljbyIgc3R5bGU9
;ImZvbnQtc2l6ZTozNnB4O2xpbmUtaGVpZ2h0OjQ4cHgiPicgKyAoa2luZCA9PT0gJ2ZvbGRlcicgPyAn8J+TgScgOiAn8J+ThCcpICsgJzwvZGl2Pic7CiAg
;ICAgICAgY29uc3Qgcm93cyA9IFtdOwogICAgICAgIGlmIChkYXRhLnNpemVUZXh0KSByb3dzLnB1c2goWyflpKflsI8nLCBkYXRhLnNpemVUZXh0XSk7CiAg
;ICAgICAgaWYgKGRhdGEubXRpbWUpIHJvd3MucHVzaChbJ+S/ruaUueaXtumXtCcsIGRhdGEubXRpbWVdKTsKICAgICAgICBpZiAoZGF0YS5kaXIgfHwgZGF0
;YS5wYXRoKSByb3dzLnB1c2goWyfmiYDlnKjot6/lvoQnLCBkYXRhLmRpciB8fCBkYXRhLnBhdGhdKTsKICAgICAgICBjb25zdCBrdiA9IHJvd3MubGVuZ3Ro
;CiAgICAgICAgICA/ICc8ZGl2IGNsYXNzPSJrdiI+JyArIHJvd3MubWFwKChbaywgdl0pID0+CiAgICAgICAgICAgICAgJzxkaXYgY2xhc3M9Imt2LXJvdyI+
;PHNwYW4gY2xhc3M9ImsiPicgKyBlc2NhcGVIdG1sKGspICsgJzwvc3Bhbj4nCiAgICAgICAgICAgICAgKyAnPHNwYW4gY2xhc3M9InYiPicgKyBlc2NhcGVI
;dG1sKHYpICsgJzwvc3Bhbj48L2Rpdj4nCiAgICAgICAgICAgICkuam9pbignJykgKyAnPC9kaXY+JwogICAgICAgICAgOiAnJzsKICAgICAgICBsZXQga2lk
;cyA9ICcnOwogICAgICAgIGlmIChBcnJheS5pc0FycmF5KGRhdGEuY2hpbGRyZW4pICYmIGRhdGEuY2hpbGRyZW4ubGVuZ3RoKSB7CiAgICAgICAgICBraWRz
;ID0gJzxkaXYgY2xhc3M9ImtpZHMiPjxiPuWGheWuuemihOiniDwvYj48YnI+JwogICAgICAgICAgICArIGRhdGEuY2hpbGRyZW4ubWFwKGMgPT4gZXNjYXBl
;SHRtbChjKSkuam9pbignPGJyPicpICsgJzwvZGl2Pic7CiAgICAgICAgfQogICAgICAgIGNvbnN0IGhpbnQgPSBkYXRhLmhpbnQKICAgICAgICAgID8gJzxk
;aXYgY2xhc3M9ImhpbnQiPicgKyBlc2NhcGVIdG1sKGRhdGEuaGludCkgKyAnPC9kaXY+JwogICAgICAgICAgOiAnJzsKICAgICAgICBwdk1lZGlhLnN0eWxl
;LmJhY2tncm91bmQgPSAnI2Y3ZjhmYic7CiAgICAgICAgcHZNZWRpYS5pbm5lckhUTUwgPSAnPGRpdiBjbGFzcz0icHYtZmlsZWluZm8iPicgKyBpY28KICAg
;ICAgICAgICsgJzxkaXYgY2xhc3M9ImZuIj4nICsgZXNjYXBlSHRtbChkYXRhLm5hbWUgfHwgJycpICsgJzwvZGl2PicKICAgICAgICAgICsgaGludCArIGt2
;ICsga2lkcyArICc8L2Rpdj4nOwogICAgICB9IGVsc2UgewogICAgICAgIHB2TWVkaWEuaW5uZXJIVE1MID0gJzxkaXYgY2xhc3M9InBoIj4nICsgZXNjYXBl
;SHRtbChkYXRhLm1lc3NhZ2UgfHwgJ+aXoOazlemihOiniOatpOexu+WeiycpICsgJzwvZGl2Pic7CiAgICAgIH0KICAgIH0gY2F0Y2ggKGUpIHt9CiAgfTsK
;CiAgZnVuY3Rpb24gZG9TZWFyY2goKSB7CiAgICBpZiAodHlwZW9mIGFwcE1vZGUgIT09ICd1bmRlZmluZWQnICYmIGFwcE1vZGUgPT09ICdoYW5kbGUnKSB7
;CiAgICAgIHJlcXVlc3RIYW5kbGVTZWFyY2gocUVsLnZhbHVlIHx8ICcnKTsKICAgICAgcmV0dXJuOwogICAgfQogICAgaWYgKHR5cGVvZiBhcHBNb2RlICE9
;PSAndW5kZWZpbmVkJyAmJiBhcHBNb2RlID09PSAnaW5mbycpIHsKICAgICAgcmVxdWVzdFN5c0luZm8oZmFsc2UpOwogICAgICByZXR1cm47CiAgICB9CiAg
;ICBjb25zdCBxID0gY29tcG9zZVNlYXJjaFF1ZXJ5KCk7CiAgICBjb3VudEVsLnRleHRDb250ZW50ID0gJ+aQnOe0ouS4reKApic7CiAgICBsb2FkaW5nTW9y
;ZSA9IGZhbHNlOwogICAgaGFzTW9yZSA9IGZhbHNlOwogICAgY2FsbEhvc3QoJ3NlYXJjaCcsIHEsIGNhdCwgc29ydCwgMCk7CiAgfQogIGZ1bmN0aW9uIHNj
;aGVkdWxlU2VhcmNoKCkgewogICAgaWYgKHR5cGVvZiBhcHBNb2RlICE9PSAndW5kZWZpbmVkJyAmJiBhcHBNb2RlICE9PSAnZmlsZScpIHJldHVybjsKICAg
;IGNsZWFyVGltZW91dChzZWFyY2hUaW1lcik7CiAgICBzZWFyY2hUaW1lciA9IHNldFRpbWVvdXQoZG9TZWFyY2gsIDEyMCk7CiAgfQoKICBkb2N1bWVudC5x
;dWVyeVNlbGVjdG9yQWxsKCcuY2F0JykuZm9yRWFjaChidG4gPT4gewogICAgYnRuLmFkZEV2ZW50TGlzdGVuZXIoJ2NsaWNrJywgKCkgPT4gewogICAgICBk
;b2N1bWVudC5xdWVyeVNlbGVjdG9yQWxsKCcuY2F0JykuZm9yRWFjaChiID0+IGIuY2xhc3NMaXN0LnJlbW92ZSgnb24nKSk7CiAgICAgIGJ0bi5jbGFzc0xp
;c3QuYWRkKCdvbicpOwogICAgICBjb25zdCBjID0gYnRuLmRhdGFzZXQuY2F0OwogICAgICBpZiAoYyA9PT0gJ19faGFuZGxlJykgewogICAgICAgIHNldEFw
;cE1vZGUoJ2hhbmRsZScpOwogICAgICAgIHJldHVybjsKICAgICAgfQogICAgICBpZiAoYyA9PT0gJ19faW5mbycpIHsKICAgICAgICBzZXRBcHBNb2RlKCdp
;bmZvJyk7CiAgICAgICAgcmV0dXJuOwogICAgICB9CiAgICAgIGNhdCA9IGM7CiAgICAgIHNldEFwcE1vZGUoJ2ZpbGUnKTsKICAgICAgZG9TZWFyY2goKTsK
;ICAgIH0pOwogIH0pOwogIHFFbC5hZGRFdmVudExpc3RlbmVyKCdpbnB1dCcsICgpID0+IHsKICAgIGlmIChhcHBNb2RlID09PSAnZmlsZScpIG1vZGVRdWVy
;eS5maWxlID0gcUVsLnZhbHVlOwogICAgZWxzZSBpZiAoYXBwTW9kZSA9PT0gJ2hhbmRsZScpIG1vZGVRdWVyeS5oYW5kbGUgPSBxRWwudmFsdWU7CiAgICBl
;bHNlIGlmIChhcHBNb2RlID09PSAnaW5mbycpIG1vZGVRdWVyeS5pbmZvID0gcUVsLnZhbHVlOwogICAgc3luY0NsZWFyQnRuKCk7CiAgICBzY2hlZHVsZVNl
;YXJjaCgpOwogICAgY2xlYXJUaW1lb3V0KGhpc3RJZGxlVGltZXIpOwogICAgaGlzdElkbGVUaW1lciA9IHNldFRpbWVvdXQoKCkgPT4gewogICAgICBpZiAo
;YXBwTW9kZSA9PT0gJ2luZm8nKSByZXR1cm47CiAgICAgIHB1c2hIaXN0KHFFbC52YWx1ZSB8fCAnJyk7CiAgICB9LCAxMjAwKTsKICB9KTsKICBxRWwuYWRk
;RXZlbnRMaXN0ZW5lcigna2V5ZG93bicsIGUgPT4gewogICAgaWYgKGFwcE1vZGUgPT09ICdpbmZvJykgcmV0dXJuOwogICAgaWYgKGUua2V5ID09PSAnRW50
;ZXInKSB7CiAgICAgIGNsZWFyVGltZW91dChoaXN0SWRsZVRpbWVyKTsKICAgICAgcHVzaEhpc3QocUVsLnZhbHVlIHx8ICcnKTsKICAgICAgZG9TZWFyY2go
;KTsKICAgIH0gZWxzZSBpZiAoZS5rZXkgPT09ICdFc2NhcGUnICYmIChxRWwudmFsdWUgfHwgJycpKSB7CiAgICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAg
;ICAgIGNsZWFyU2VhcmNoKCk7CiAgICB9CiAgfSk7CiAgcUVsLmFkZEV2ZW50TGlzdGVuZXIoJ2JsdXInLCAoKSA9PiB7CiAgICBjbGVhclRpbWVvdXQoaGlz
;dElkbGVUaW1lcik7CiAgICBpZiAoYXBwTW9kZSAhPT0gJ2luZm8nKSBwdXNoSGlzdChxRWwudmFsdWUgfHwgJycpOwogIH0pOwoKICBmdW5jdGlvbiBmb2N1
;c1NlYXJjaChzZWxlY3RBbGwpIHsKICAgIHRyeSB7CiAgICAgIHFFbC5mb2N1cygpOwogICAgICBpZiAoc2VsZWN0QWxsICE9PSBmYWxzZSkKICAgICAgICBx
;RWwuc2VsZWN0KCk7CiAgICB9IGNhdGNoIChfKSB7fQogIH0KICB3aW5kb3cuX19mb2N1c1NlYXJjaCA9IGZvY3VzU2VhcmNoOwoKICBmdW5jdGlvbiBpc1Zp
;ZGVvRnVsbHNjcmVlbigpIHsKICAgIGNvbnN0IGZzID0gZG9jdW1lbnQuZnVsbHNjcmVlbkVsZW1lbnQgfHwgZG9jdW1lbnQud2Via2l0RnVsbHNjcmVlbkVs
;ZW1lbnQgfHwgZG9jdW1lbnQubXNGdWxsc2NyZWVuRWxlbWVudDsKICAgIGlmIChmcykgcmV0dXJuIHRydWU7CiAgICBjb25zdCB2aWRzID0gZG9jdW1lbnQu
;cXVlcnlTZWxlY3RvckFsbCgndmlkZW8nKTsKICAgIGZvciAoY29uc3QgdiBvZiB2aWRzKSB7CiAgICAgIGlmICh2LndlYmtpdERpc3BsYXlpbmdGdWxsc2Ny
;ZWVuIHx8IHYubW96RnVsbFNjcmVlbiB8fCB2Lm1zRnVsbHNjcmVlbkVsZW1lbnQpIHJldHVybiB0cnVlOwogICAgfQogICAgcmV0dXJuIGZhbHNlOwogIH0K
;ICBmdW5jdGlvbiBleGl0VmlkZW9GdWxsc2NyZWVuKCkgewogICAgdHJ5IHsKICAgICAgaWYgKGRvY3VtZW50LmZ1bGxzY3JlZW5FbGVtZW50IHx8IGRvY3Vt
;ZW50LndlYmtpdEZ1bGxzY3JlZW5FbGVtZW50KSB7CiAgICAgICAgY29uc3QgcCA9IGRvY3VtZW50LmV4aXRGdWxsc2NyZWVuID8gZG9jdW1lbnQuZXhpdEZ1
;bGxzY3JlZW4oKQogICAgICAgICAgOiAoZG9jdW1lbnQud2Via2l0RXhpdEZ1bGxzY3JlZW4gJiYgZG9jdW1lbnQud2Via2l0RXhpdEZ1bGxzY3JlZW4oKSk7
;CiAgICAgICAgcmV0dXJuIHRydWU7CiAgICAgIH0KICAgIH0gY2F0Y2ggKF8pIHt9CiAgICBjb25zdCB2aWRzID0gZG9jdW1lbnQucXVlcnlTZWxlY3RvckFs
;bCgndmlkZW8nKTsKICAgIGZvciAoY29uc3QgdiBvZiB2aWRzKSB7CiAgICAgIHRyeSB7CiAgICAgICAgaWYgKHYud2Via2l0RGlzcGxheWluZ0Z1bGxzY3Jl
;ZW4gJiYgdi53ZWJraXRFeGl0RnVsbHNjcmVlbikgewogICAgICAgICAgdi53ZWJraXRFeGl0RnVsbHNjcmVlbigpOwogICAgICAgICAgcmV0dXJuIHRydWU7
;CiAgICAgICAgfQogICAgICAgIGlmICh2LmV4aXRGdWxsc2NyZWVuKSB7IHYuZXhpdEZ1bGxzY3JlZW4oKTsgcmV0dXJuIHRydWU7IH0KICAgICAgfSBjYXRj
;aCAoXykge30KICAgIH0KICAgIHJldHVybiBmYWxzZTsKICB9CiAgd2luZG93Ll9faGFuZGxlRXNjID0gKCkgPT4gewogICAgaWYgKGlzVmlkZW9GdWxsc2Ny
;ZWVuKCkgfHwgZXhpdFZpZGVvRnVsbHNjcmVlbigpKSB7CiAgICAgIHRyeSB7IGV4aXRWaWRlb0Z1bGxzY3JlZW4oKTsgfSBjYXRjaCAoXykge30KICAgICAg
;cG9zdCgnZXNjQ29uc3VtZWQnKTsKICAgICAgcmV0dXJuIHRydWU7CiAgICB9CiAgICBwb3N0KCdlc2NIaWRlJyk7CiAgICByZXR1cm4gZmFsc2U7CiAgfTsK
;ICBkb2N1bWVudC5hZGRFdmVudExpc3RlbmVyKCdrZXlkb3duJywgZSA9PiB7CiAgICBpZiAoKGUuY3RybEtleSB8fCBlLm1ldGFLZXkpICYmICFlLmFsdEtl
;eSAmJiAhZS5zaGlmdEtleSAmJiBTdHJpbmcoZS5rZXkpLnRvTG93ZXJDYXNlKCkgPT09ICdmJykgewogICAgICBlLnByZXZlbnREZWZhdWx0KCk7CiAgICAg
;IGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAgIGZvY3VzU2VhcmNoKCk7CiAgICAgIHJldHVybjsKICAgIH0KICAgIGlmIChlLmtleSA9PT0gJ0VzY2FwZScg
;fHwgZS5rZXkgPT09ICdFc2MnKSB7CiAgICAgIGlmIChpc1ZpZGVvRnVsbHNjcmVlbigpKSB7CiAgICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOwogICAgICAg
;IGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAgICAgZXhpdFZpZGVvRnVsbHNjcmVlbigpOwogICAgICAgIHBvc3QoJ2VzY0NvbnN1bWVkJyk7CiAgICAgIH0K
;ICAgIH0KICB9LCB0cnVlKTsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYnRuLXNvcnQnKS5vbmNsaWNrID0gKCkgPT4gewogICAgc29ydCA9IHNvcnQg
;PT09ICdkYXRlLWRlc2MnID8gJ2RhdGUtYXNjJyA6IChzb3J0ID09PSAnZGF0ZS1hc2MnID8gJ25hbWUtYXNjJyA6IChzb3J0ID09PSAnbmFtZS1hc2MnID8g
;J3NpemUtZGVzYycgOiAnZGF0ZS1kZXNjJykpOwogICAgY29uc3QgbWFwID0gewogICAgICAnZGF0ZS1kZXNjJzogJ+aMieS/ruaUueaXtumXtOmZjeW6jycs
;CiAgICAgICdkYXRlLWFzYyc6ICfmjInkv67mlLnml7bpl7TljYfluo8nLAogICAgICAnbmFtZS1hc2MnOiAn5oyJ5ZCN56ew5Y2H5bqPJywKICAgICAgJ3Np
;emUtZGVzYyc6ICfmjInlpKflsI/pmY3luo8nCiAgICB9OwogICAgc29ydExhYmVsLnRleHRDb250ZW50ID0gbWFwW3NvcnRdIHx8IHNvcnQ7CiAgICBkb1Nl
;YXJjaCgpOwogIH07CiAgY2hrUHJldmlldy5hZGRFdmVudExpc3RlbmVyKCdjaGFuZ2UnLCAoKSA9PiB7CiAgICBwcmV2aWV3T24gPSAhIWNoa1ByZXZpZXcu
;Y2hlY2tlZDsKICAgIHByZXZpZXcuY2xhc3NMaXN0LnRvZ2dsZSgnb2ZmJywgIXByZXZpZXdPbik7CiAgICBpZiAocHJldmlld09uICYmIHNlbGVjdGVkID49
;IDApIHJlcXVlc3RQcmV2aWV3KGl0ZW1zW3NlbGVjdGVkXSk7CiAgfSk7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2J0bi1zZXR0aW5ncycpLm9uY2xp
;Y2sgPSAoKSA9PiBvcGVuRmlsdGVyU2V0dGluZ3MoKTsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgndG9wJykuYWRkRXZlbnRMaXN0ZW5lcignbW91c2Vk
;b3duJywgZSA9PiB7CiAgICBpZiAoZS5idXR0b24gIT09IDApIHJldHVybjsKICAgIGlmIChlLnRhcmdldC5jbG9zZXN0KCcubm8tZHJhZycpKSByZXR1cm47
;CiAgICBjYWxsSG9zdCgnZHJhZycpOwogICAgcG9zdCgnZHJhZycpOwogIH0pOwogIGlmICh0aXRsZWJhcikgewogICAgdGl0bGViYXIuYWRkRXZlbnRMaXN0
;ZW5lcignbW91c2Vkb3duJywgZSA9PiB7CiAgICAgIGlmIChlLmJ1dHRvbiAhPT0gMCkgcmV0dXJuOwogICAgICBpZiAoZS50YXJnZXQuY2xvc2VzdCgnLm5v
;LWRyYWcnKSkgcmV0dXJuOwogICAgICBjYWxsSG9zdCgnZHJhZycpOwogICAgICBwb3N0KCdkcmFnJyk7CiAgICB9KTsKICAgIHRpdGxlYmFyLmFkZEV2ZW50
;TGlzdGVuZXIoJ2RibGNsaWNrJywgZSA9PiB7CiAgICAgIGlmIChlLnRhcmdldC5jbG9zZXN0KCcubm8tZHJhZycpKSByZXR1cm47CiAgICAgIGNhbGxIb3N0
;KCdtYXhpbWl6ZScpOwogICAgICBwb3N0KCdtYXhpbWl6ZScpOwogICAgfSk7CiAgfQogIGNvbnN0IGJ0bldpbk1pbiA9IGRvY3VtZW50LmdldEVsZW1lbnRC
;eUlkKCdidG4td2luLW1pbicpOwogIGNvbnN0IGJ0bldpbk1heCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdidG4td2luLW1heCcpOwogIGNvbnN0IGJ0
;bldpbkNsb3NlID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2J0bi13aW4tY2xvc2UnKTsKICBpZiAoYnRuV2luTWluKSBidG5XaW5NaW4ub25jbGljayA9
;ICgpID0+IHsgY2FsbEhvc3QoJ21pbmltaXplJyk7IHBvc3QoJ21pbmltaXplJyk7IH07CiAgaWYgKGJ0bldpbk1heCkgYnRuV2luTWF4Lm9uY2xpY2sgPSAo
;KSA9PiB7IGNhbGxIb3N0KCdtYXhpbWl6ZScpOyBwb3N0KCdtYXhpbWl6ZScpOyB9OwogIGlmIChidG5XaW5DbG9zZSkgYnRuV2luQ2xvc2Uub25jbGljayA9
;ICgpID0+IHsgY2FsbEhvc3QoJ2Nsb3NlJyk7IHBvc3QoJ2Nsb3NlJyk7IH07CgogIC8vIOKUgOKUgCDmkJzntKLnrZvpgInvvIjigLog5bGV5byAICsg5bem
;5LiL6KeS6K6+572u77yJ4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSACiAgY29uc3QgRklMVEVSX1NUT1JFX0tFWSA9
;ICdsb2NhbF9zZWFyY2hfZmlsdGVyc192Mic7CiAgY29uc3QgRklMVEVSX1NUT1JFX0xFR0FDWSA9ICdsb2NhbF9zZWFyY2hfZmlsdGVyc192MSc7CiAgY29u
;c3QgRklMVEVSX0FDVElWRV9LRVkgPSAnbG9jYWxfc2VhcmNoX2ZpbHRlcnNfYWN0aXZlX3YxJzsKICBjb25zdCBCVUlMVElOX0ZJTFRFUlMgPSBbCiAgICB7
;IGlkOiAnemgnLCB0aXRsZTogJ+WQq+S4reaWhycsIHJlZ2V4OiAnW1xceHs0ZTAwfS1cXHh7OWZmZn1dJywgYnVpbHRpbjogdHJ1ZSwgZW5hYmxlZDogdHJ1
;ZSB9LAogICAgeyBpZDogJ25vdW5kZXInLCB0aXRsZTogJ+mdnuS4i+WIkue6v+W8gOWktCcsIHJlZ2V4OiAnXlteX10nLCBidWlsdGluOiB0cnVlLCBlbmFi
;bGVkOiB0cnVlIH0KICBdOwogIGNvbnN0IFNWR19YID0gJzxzdmcgdmlld0JveD0iMCAwIDEyIDEyIiBmaWxsPSJub25lIiBhcmlhLWhpZGRlbj0idHJ1ZSI+
;PHBhdGggZD0iTTMgM2w2IDZNOSAzTDMgOSIgc3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0cm9rZS13aWR0aD0iMS40IiBzdHJva2UtbGluZWNhcD0icm91bmQi
;Lz48L3N2Zz4nOwogIGNvbnN0IFNWR19VUCA9ICc8c3ZnIHZpZXdCb3g9IjAgMCAxMiAxMiIgZmlsbD0ibm9uZSIgYXJpYS1oaWRkZW49InRydWUiPjxwYXRo
;IGQ9Ik02IDMuMkwyLjggNy4yaDYuNEw2IDMuMnoiIGZpbGw9ImN1cnJlbnRDb2xvciIvPjwvc3ZnPic7CiAgY29uc3QgU1ZHX0ROID0gJzxzdmcgdmlld0Jv
;eD0iMCAwIDEyIDEyIiBmaWxsPSJub25lIiBhcmlhLWhpZGRlbj0idHJ1ZSI+PHBhdGggZD0iTTYgOC44bDMuMi00SDIuOEw2IDguOHoiIGZpbGw9ImN1cnJl
;bnRDb2xvciIvPjwvc3ZnPic7CiAgY29uc3QgZmlsdGVyUmFpbCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdmaWx0ZXItcmFpbCcpOwogIGNvbnN0IGZp
;bHRlckJhciA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdmaWx0ZXItYmFyJyk7CiAgY29uc3QgYnRuRmlsdGVyVG9nZ2xlID0gZG9jdW1lbnQuZ2V0RWxl
;bWVudEJ5SWQoJ2J0bi1maWx0ZXItdG9nZ2xlJyk7CiAgY29uc3QgZmlsdGVyU2V0dGluZ3MgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnZmlsdGVyLXNl
;dHRpbmdzJyk7CiAgbGV0IGZpbHRlckl0ZW1zID0gW107CiAgbGV0IGFjdGl2ZUZpbHRlcklkcyA9IG5ldyBTZXQoKTsKICBsZXQgZmlsdGVyc09wZW4gPSBm
;YWxzZTsKCiAgZnVuY3Rpb24gY2xvbmVCdWlsdGluRGVmYXVsdHMoKSB7CiAgICByZXR1cm4gQlVJTFRJTl9GSUxURVJTLm1hcCh4ID0+ICh7CiAgICAgIGlk
;OiB4LmlkLCB0aXRsZTogeC50aXRsZSwgcmVnZXg6IHgucmVnZXgsIGJ1aWx0aW46IHRydWUsIGVuYWJsZWQ6IHRydWUKICAgIH0pKTsKICB9CiAgZnVuY3Rp
;b24gbm9ybWFsaXplRmlsdGVySXRlbSh4LCBmb3JjZUJ1aWx0aW4pIHsKICAgIGlmICgheCB8fCAheC5pZCB8fCAheC50aXRsZSB8fCAheC5yZWdleCkgcmV0
;dXJuIG51bGw7CiAgICBjb25zdCBpZCA9IFN0cmluZyh4LmlkKTsKICAgIGNvbnN0IGJ1aWx0aW4gPSBmb3JjZUJ1aWx0aW4gIT0gbnVsbCA/ICEhZm9yY2VC
;dWlsdGluIDogKCEheC5idWlsdGluIHx8IGlkID09PSAnemgnIHx8IGlkID09PSAnbm91bmRlcicpOwogICAgcmV0dXJuIHsKICAgICAgaWQsCiAgICAgIHRp
;dGxlOiBTdHJpbmcoeC50aXRsZSkuc2xpY2UoMCwgMjQpLAogICAgICByZWdleDogU3RyaW5nKHgucmVnZXgpLnNsaWNlKDAsIDIwMCksCiAgICAgIGJ1aWx0
;aW4sCiAgICAgIGVuYWJsZWQ6IHguZW5hYmxlZCAhPT0gZmFsc2UKICAgIH07CiAgfQogIGZ1bmN0aW9uIGxvYWRGaWx0ZXJTdGF0ZSgpIHsKICAgIGZpbHRl
;ckl0ZW1zID0gW107CiAgICB0cnkgewogICAgICBjb25zdCByYXcgPSBsb2NhbFN0b3JhZ2UuZ2V0SXRlbShGSUxURVJfU1RPUkVfS0VZKTsKICAgICAgaWYg
;KHJhdykgewogICAgICAgIGNvbnN0IGFyciA9IEpTT04ucGFyc2UocmF3KTsKICAgICAgICBpZiAoQXJyYXkuaXNBcnJheShhcnIpICYmIGFyci5sZW5ndGgp
;IHsKICAgICAgICAgIGZpbHRlckl0ZW1zID0gYXJyLm1hcCh4ID0+IG5vcm1hbGl6ZUZpbHRlckl0ZW0oeCkpLmZpbHRlcihCb29sZWFuKTsKICAgICAgICB9
;CiAgICAgIH0KICAgIH0gY2F0Y2ggKF8pIHsgZmlsdGVySXRlbXMgPSBbXTsgfQogICAgaWYgKCFmaWx0ZXJJdGVtcy5sZW5ndGgpIHsKICAgICAgLy8g5YW8
;5a65IHYx77ya5YaF572uICsg6Ieq5a6a5LmJCiAgICAgIGxldCBjdXN0b21zID0gW107CiAgICAgIHRyeSB7CiAgICAgICAgY29uc3QgcmF3ID0gbG9jYWxT
;dG9yYWdlLmdldEl0ZW0oRklMVEVSX1NUT1JFX0xFR0FDWSk7CiAgICAgICAgY29uc3QgYXJyID0gcmF3ID8gSlNPTi5wYXJzZShyYXcpIDogW107CiAgICAg
;ICAgY3VzdG9tcyA9IEFycmF5LmlzQXJyYXkoYXJyKSA/IGFyci5tYXAoeCA9PiBub3JtYWxpemVGaWx0ZXJJdGVtKHgsIGZhbHNlKSkuZmlsdGVyKEJvb2xl
;YW4pIDogW107CiAgICAgIH0gY2F0Y2ggKF8pIHsgY3VzdG9tcyA9IFtdOyB9CiAgICAgIGZpbHRlckl0ZW1zID0gY2xvbmVCdWlsdGluRGVmYXVsdHMoKS5j
;b25jYXQoY3VzdG9tcyk7CiAgICAgIHNhdmVGaWx0ZXJJdGVtcygpOwogICAgfQogICAgdHJ5IHsKICAgICAgY29uc3QgcmF3ID0gbG9jYWxTdG9yYWdlLmdl
;dEl0ZW0oRklMVEVSX0FDVElWRV9LRVkpOwogICAgICBjb25zdCBhcnIgPSByYXcgPyBKU09OLnBhcnNlKHJhdykgOiBbXTsKICAgICAgYWN0aXZlRmlsdGVy
;SWRzID0gbmV3IFNldChBcnJheS5pc0FycmF5KGFycikgPyBhcnIubWFwKFN0cmluZykgOiBbXSk7CiAgICB9IGNhdGNoIChfKSB7IGFjdGl2ZUZpbHRlcklk
;cyA9IG5ldyBTZXQoKTsgfQogIH0KICBmdW5jdGlvbiBzYXZlRmlsdGVySXRlbXMoKSB7CiAgICB0cnkgeyBsb2NhbFN0b3JhZ2Uuc2V0SXRlbShGSUxURVJf
;U1RPUkVfS0VZLCBKU09OLnN0cmluZ2lmeShmaWx0ZXJJdGVtcykpOyB9IGNhdGNoIChfKSB7fQogIH0KICBmdW5jdGlvbiBzYXZlQWN0aXZlRmlsdGVycygp
;IHsKICAgIHRyeSB7IGxvY2FsU3RvcmFnZS5zZXRJdGVtKEZJTFRFUl9BQ1RJVkVfS0VZLCBKU09OLnN0cmluZ2lmeShBcnJheS5mcm9tKGFjdGl2ZUZpbHRl
;cklkcykpKTsgfSBjYXRjaCAoXykge30KICB9CiAgZnVuY3Rpb24gYWxsRmlsdGVycygpIHsKICAgIHJldHVybiBmaWx0ZXJJdGVtcy5zbGljZSgpOwogIH0K
;ICBmdW5jdGlvbiB2aXNpYmxlRmlsdGVycygpIHsKICAgIHJldHVybiBmaWx0ZXJJdGVtcy5maWx0ZXIoZiA9PiBmLmVuYWJsZWQgIT09IGZhbHNlKTsKICB9
;CiAgZnVuY3Rpb24gY29tcG9zZVNlYXJjaFF1ZXJ5KCkgewogICAgY29uc3QgcGFydHMgPSBbXTsKICAgIGNvbnN0IHEgPSBTdHJpbmcocUVsLnZhbHVlIHx8
;ICcnKS50cmltKCk7CiAgICBpZiAocSkgcGFydHMucHVzaChxKTsKICAgIGZvciAoY29uc3QgZiBvZiB2aXNpYmxlRmlsdGVycygpKSB7CiAgICAgIGlmICgh
;YWN0aXZlRmlsdGVySWRzLmhhcyhmLmlkKSkgY29udGludWU7CiAgICAgIGNvbnN0IHJlID0gU3RyaW5nKGYucmVnZXggfHwgJycpLnRyaW0oKTsKICAgICAg
;aWYgKCFyZSkgY29udGludWU7CiAgICAgIHBhcnRzLnB1c2goJ3JlZ2V4OicgKyByZS5yZXBsYWNlKC9ccysvZywgJycpKTsKICAgIH0KICAgIHJldHVybiBw
;YXJ0cy5qb2luKCd8Jyk7CiAgfQogIGZ1bmN0aW9uIHN5bmNGaWx0ZXJUb2dnbGVVaSgpIHsKICAgIGlmIChmaWx0ZXJSYWlsKSBmaWx0ZXJSYWlsLmNsYXNz
;TGlzdC50b2dnbGUoJ29wZW4nLCAhIWZpbHRlcnNPcGVuKTsKICAgIGlmIChidG5GaWx0ZXJUb2dnbGUpIHsKICAgICAgYnRuRmlsdGVyVG9nZ2xlLmNsYXNz
;TGlzdC50b2dnbGUoJ29wZW4nLCAhIWZpbHRlcnNPcGVuKTsKICAgICAgY29uc3QgaGFzQWN0aXZlID0gdmlzaWJsZUZpbHRlcnMoKS5zb21lKGYgPT4gYWN0
;aXZlRmlsdGVySWRzLmhhcyhmLmlkKSk7CiAgICAgIGJ0bkZpbHRlclRvZ2dsZS5jbGFzc0xpc3QudG9nZ2xlKCdoYXMtYWN0aXZlJywgaGFzQWN0aXZlKTsK
;ICAgICAgYnRuRmlsdGVyVG9nZ2xlLnRpdGxlID0gZmlsdGVyc09wZW4gPyAn5pS26LW3562b6YCJ5p2h5Lu2JyA6IChoYXNBY3RpdmUgPyAn5bGV5byA562b
;6YCJ5p2h5Lu277yI5bey6YCJ77yJJyA6ICflsZXlvIDnrZvpgInmnaHku7YnKTsKICAgICAgYnRuRmlsdGVyVG9nZ2xlLnNldEF0dHJpYnV0ZSgnYXJpYS1s
;YWJlbCcsIGJ0bkZpbHRlclRvZ2dsZS50aXRsZSk7CiAgICB9CiAgfQogIGZ1bmN0aW9uIHJlbmRlckZpbHRlckJhcigpIHsKICAgIGlmICghZmlsdGVyQmFy
;KSByZXR1cm47CiAgICBmaWx0ZXJCYXIuaW5uZXJIVE1MID0gJyc7CiAgICBmb3IgKGNvbnN0IGYgb2YgdmlzaWJsZUZpbHRlcnMoKSkgewogICAgICBjb25z
;dCBidG4gPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdidXR0b24nKTsKICAgICAgYnRuLnR5cGUgPSAnYnV0dG9uJzsKICAgICAgYnRuLmNsYXNzTmFtZSA9
;ICdmaWx0ZXItY2hpcCcgKyAoYWN0aXZlRmlsdGVySWRzLmhhcyhmLmlkKSA/ICcgb24nIDogJycpOwogICAgICBidG4udGV4dENvbnRlbnQgPSBmLnRpdGxl
;OwogICAgICBidG4udGl0bGUgPSAncmVnZXg6JyArIGYucmVnZXg7CiAgICAgIGJ0bi5vbmNsaWNrID0gKCkgPT4gewogICAgICAgIGlmIChhY3RpdmVGaWx0
;ZXJJZHMuaGFzKGYuaWQpKSBhY3RpdmVGaWx0ZXJJZHMuZGVsZXRlKGYuaWQpOwogICAgICAgIGVsc2UgYWN0aXZlRmlsdGVySWRzLmFkZChmLmlkKTsKICAg
;ICAgICBzYXZlQWN0aXZlRmlsdGVycygpOwogICAgICAgIHJlbmRlckZpbHRlckJhcigpOwogICAgICAgIGlmIChhcHBNb2RlID09PSAnZmlsZScpIGRvU2Vh
;cmNoKCk7CiAgICAgIH07CiAgICAgIGZpbHRlckJhci5hcHBlbmRDaGlsZChidG4pOwogICAgfQogICAgc3luY0ZpbHRlclRvZ2dsZVVpKCk7CiAgfQogIGZ1
;bmN0aW9uIG1vdmVGaWx0ZXIoaWR4LCBkaXIpIHsKICAgIGNvbnN0IGogPSBpZHggKyBkaXI7CiAgICBpZiAoaiA8IDAgfHwgaiA+PSBmaWx0ZXJJdGVtcy5s
;ZW5ndGgpIHJldHVybjsKICAgIGNvbnN0IHQgPSBmaWx0ZXJJdGVtc1tpZHhdOwogICAgZmlsdGVySXRlbXNbaWR4XSA9IGZpbHRlckl0ZW1zW2pdOwogICAg
;ZmlsdGVySXRlbXNbal0gPSB0OwogICAgc2F2ZUZpbHRlckl0ZW1zKCk7CiAgICByZW5kZXJGaWx0ZXJCYXIoKTsKICAgIHJlbmRlckZpbHRlclNldHRpbmdz
;TGlzdCgpOwogIH0KICBmdW5jdGlvbiByZW5kZXJGaWx0ZXJTZXR0aW5nc0xpc3QoKSB7CiAgICBjb25zdCBsaXN0ID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5
;SWQoJ2ZzLWxpc3QnKTsKICAgIGlmICghbGlzdCkgcmV0dXJuOwogICAgbGlzdC5pbm5lckhUTUwgPSAnJzsKICAgIGZpbHRlckl0ZW1zLmZvckVhY2goKGYs
;IGlkeCkgPT4gewogICAgICBjb25zdCByb3cgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsKICAgICAgcm93LmNsYXNzTmFtZSA9ICdmcy1ibG9j
;aycgKyAoZi5lbmFibGVkID09PSBmYWxzZSA/ICcgb2ZmJyA6ICcnKTsKCiAgICAgIGNvbnN0IG9yZCA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2Rpdicp
;OwogICAgICBvcmQuY2xhc3NOYW1lID0gJ2ZzLW9yZCc7CiAgICAgIGNvbnN0IHVwID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnYnV0dG9uJyk7CiAgICAg
;IHVwLnR5cGUgPSAnYnV0dG9uJzsKICAgICAgdXAudGl0bGUgPSAn5LiK56e7JzsKICAgICAgdXAuaW5uZXJIVE1MID0gU1ZHX1VQOwogICAgICB1cC5kaXNh
;YmxlZCA9IGlkeCA9PT0gMDsKICAgICAgdXAub25jbGljayA9ICgpID0+IG1vdmVGaWx0ZXIoaWR4LCAtMSk7CiAgICAgIGNvbnN0IGRuID0gZG9jdW1lbnQu
;Y3JlYXRlRWxlbWVudCgnYnV0dG9uJyk7CiAgICAgIGRuLnR5cGUgPSAnYnV0dG9uJzsKICAgICAgZG4udGl0bGUgPSAn5LiL56e7JzsKICAgICAgZG4uaW5u
;ZXJIVE1MID0gU1ZHX0ROOwogICAgICBkbi5kaXNhYmxlZCA9IGlkeCA9PT0gZmlsdGVySXRlbXMubGVuZ3RoIC0gMTsKICAgICAgZG4ub25jbGljayA9ICgp
;ID0+IG1vdmVGaWx0ZXIoaWR4LCAxKTsKICAgICAgb3JkLmFwcGVuZENoaWxkKHVwKTsKICAgICAgb3JkLmFwcGVuZENoaWxkKGRuKTsKCiAgICAgIGNvbnN0
;IG1haW4gPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsKICAgICAgbWFpbi5jbGFzc05hbWUgPSAnZnMtbWFpbic7CiAgICAgIG1haW4uaW5uZXJI
;VE1MID0gJzxkaXYgY2xhc3M9ImZzLXRpdGxlLXJvdyI+PHNwYW4gY2xhc3M9ImZzLXRpdGxlIj4nICsgZXNjYXBlSHRtbChmLnRpdGxlKSArICc8L3NwYW4+
;JwogICAgICAgICsgKGYuYnVpbHRpbiA/ICc8c3BhbiBjbGFzcz0iZnMtdGFnIj7lhoXnva48L3NwYW4+JyA6ICcnKQogICAgICAgICsgJzwvZGl2PjxkaXYg
;Y2xhc3M9ImZzLXJlZ2V4IiB0aXRsZT0iJyArIGVzY2FwZUF0dHIoZi5yZWdleCkgKyAnIj4nICsgZXNjYXBlSHRtbChmLnJlZ2V4KSArICc8L2Rpdj4nOwoK
;ICAgICAgY29uc3QgZW5XcmFwID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnZGl2Jyk7CiAgICAgIGVuV3JhcC5jbGFzc05hbWUgPSAnZnMtZW4nOwogICAg
;ICBjb25zdCBsYWIgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdzcGFuJyk7CiAgICAgIGxhYi5jbGFzc05hbWUgPSAnZnMtZW4tbGFiJzsKICAgICAgbGFi
;LnRleHRDb250ZW50ID0gZi5lbmFibGVkID09PSBmYWxzZSA/ICflt7LnpoHnlKgnIDogJ+W3suWQr+eUqCc7CiAgICAgIGNvbnN0IHN3ID0gZG9jdW1lbnQu
;Y3JlYXRlRWxlbWVudCgnYnV0dG9uJyk7CiAgICAgIHN3LnR5cGUgPSAnYnV0dG9uJzsKICAgICAgc3cuY2xhc3NOYW1lID0gJ2ZzLXN3aXRjaCcgKyAoZi5l
;bmFibGVkID09PSBmYWxzZSA/ICcnIDogJyBvbicpOwogICAgICBzdy50aXRsZSA9IGYuZW5hYmxlZCA9PT0gZmFsc2UgPyAn5ZCv55SoJyA6ICfnpoHnlKgn
;OwogICAgICBzdy5zZXRBdHRyaWJ1dGUoJ2FyaWEtcHJlc3NlZCcsIGYuZW5hYmxlZCAhPT0gZmFsc2UgPyAndHJ1ZScgOiAnZmFsc2UnKTsKICAgICAgc3cu
;aW5uZXJIVE1MID0gJzxpPjwvaT4nOwogICAgICBzdy5vbmNsaWNrID0gKCkgPT4gewogICAgICAgIGYuZW5hYmxlZCA9IGYuZW5hYmxlZCA9PT0gZmFsc2U7
;CiAgICAgICAgaWYgKGYuZW5hYmxlZCA9PT0gZmFsc2UpIGFjdGl2ZUZpbHRlcklkcy5kZWxldGUoZi5pZCk7CiAgICAgICAgc2F2ZUZpbHRlckl0ZW1zKCk7
;CiAgICAgICAgc2F2ZUFjdGl2ZUZpbHRlcnMoKTsKICAgICAgICByZW5kZXJGaWx0ZXJCYXIoKTsKICAgICAgICByZW5kZXJGaWx0ZXJTZXR0aW5nc0xpc3Qo
;KTsKICAgICAgICBpZiAoYXBwTW9kZSA9PT0gJ2ZpbGUnKSBkb1NlYXJjaCgpOwogICAgICB9OwogICAgICBlbldyYXAuYXBwZW5kQ2hpbGQobGFiKTsKICAg
;ICAgZW5XcmFwLmFwcGVuZENoaWxkKHN3KTsKCiAgICAgIGNvbnN0IGRlbCA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2J1dHRvbicpOwogICAgICBkZWwu
;dHlwZSA9ICdidXR0b24nOwogICAgICBkZWwuY2xhc3NOYW1lID0gJ2ZzLWRlbCc7CiAgICAgIGRlbC50aXRsZSA9ICfliKDpmaQnOwogICAgICBkZWwuaW5u
;ZXJIVE1MID0gU1ZHX1g7CiAgICAgIGRlbC5vbmNsaWNrID0gKCkgPT4gewogICAgICAgIGZpbHRlckl0ZW1zID0gZmlsdGVySXRlbXMuZmlsdGVyKHggPT4g
;eC5pZCAhPT0gZi5pZCk7CiAgICAgICAgYWN0aXZlRmlsdGVySWRzLmRlbGV0ZShmLmlkKTsKICAgICAgICBzYXZlRmlsdGVySXRlbXMoKTsKICAgICAgICBz
;YXZlQWN0aXZlRmlsdGVycygpOwogICAgICAgIHJlbmRlckZpbHRlckJhcigpOwogICAgICAgIHJlbmRlckZpbHRlclNldHRpbmdzTGlzdCgpOwogICAgICAg
;IGlmIChhcHBNb2RlID09PSAnZmlsZScpIGRvU2VhcmNoKCk7CiAgICAgIH07CgogICAgICByb3cuYXBwZW5kQ2hpbGQob3JkKTsKICAgICAgcm93LmFwcGVu
;ZENoaWxkKG1haW4pOwogICAgICByb3cuYXBwZW5kQ2hpbGQoZW5XcmFwKTsKICAgICAgcm93LmFwcGVuZENoaWxkKGRlbCk7CiAgICAgIGxpc3QuYXBwZW5k
;Q2hpbGQocm93KTsKICAgIH0pOwogIH0KICBmdW5jdGlvbiByZXNldEZpbHRlcnNUb0RlZmF1bHQoKSB7CiAgICBmaWx0ZXJJdGVtcyA9IGNsb25lQnVpbHRp
;bkRlZmF1bHRzKCk7CiAgICBhY3RpdmVGaWx0ZXJJZHMgPSBuZXcgU2V0KCk7CiAgICBzYXZlRmlsdGVySXRlbXMoKTsKICAgIHNhdmVBY3RpdmVGaWx0ZXJz
;KCk7CiAgICByZW5kZXJGaWx0ZXJCYXIoKTsKICAgIHJlbmRlckZpbHRlclNldHRpbmdzTGlzdCgpOwogICAgaWYgKGFwcE1vZGUgPT09ICdmaWxlJykgZG9T
;ZWFyY2goKTsKICB9CiAgZnVuY3Rpb24gb3BlbkZpbHRlclNldHRpbmdzKCkgewogICAgcmVuZGVyRmlsdGVyU2V0dGluZ3NMaXN0KCk7CiAgICBpZiAoZmls
;dGVyU2V0dGluZ3MpIGZpbHRlclNldHRpbmdzLmNsYXNzTGlzdC5hZGQoJ29uJyk7CiAgfQogIGZ1bmN0aW9uIGNsb3NlRmlsdGVyU2V0dGluZ3MoKSB7CiAg
;ICBpZiAoZmlsdGVyU2V0dGluZ3MpIGZpbHRlclNldHRpbmdzLmNsYXNzTGlzdC5yZW1vdmUoJ29uJyk7CiAgfQogIGxvYWRGaWx0ZXJTdGF0ZSgpOwogIHJl
;bmRlckZpbHRlckJhcigpOwogIGlmIChidG5GaWx0ZXJUb2dnbGUpIHsKICAgIGJ0bkZpbHRlclRvZ2dsZS5vbmNsaWNrID0gKGUpID0+IHsKICAgICAgZS5z
;dG9wUHJvcGFnYXRpb24oKTsKICAgICAgZmlsdGVyc09wZW4gPSAhZmlsdGVyc09wZW47CiAgICAgIHN5bmNGaWx0ZXJUb2dnbGVVaSgpOwogICAgfTsKICB9
;CiAgY29uc3QgZnNDbG9zZSA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdmcy1jbG9zZScpOwogIGlmIChmc0Nsb3NlKSBmc0Nsb3NlLm9uY2xpY2sgPSAo
;KSA9PiBjbG9zZUZpbHRlclNldHRpbmdzKCk7CiAgaWYgKGZpbHRlclNldHRpbmdzKSB7CiAgICBmaWx0ZXJTZXR0aW5ncy5hZGRFdmVudExpc3RlbmVyKCdj
;bGljaycsIGUgPT4gewogICAgICBpZiAoZS50YXJnZXQgPT09IGZpbHRlclNldHRpbmdzKSBjbG9zZUZpbHRlclNldHRpbmdzKCk7CiAgICB9KTsKICB9CiAg
;Y29uc3QgZnNBZGQgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnZnMtYWRkJyk7CiAgaWYgKGZzQWRkKSB7CiAgICBmc0FkZC5vbmNsaWNrID0gKCkgPT4g
;ewogICAgICBjb25zdCB0aXRsZSA9IFN0cmluZygoZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2ZzLXRpdGxlJykgfHwge30pLnZhbHVlIHx8ICcnKS50cmlt
;KCk7CiAgICAgIGNvbnN0IHJlZ2V4ID0gU3RyaW5nKChkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnZnMtcmVnZXgnKSB8fCB7fSkudmFsdWUgfHwgJycpLnRy
;aW0oKTsKICAgICAgaWYgKCF0aXRsZSkgeyB0cnkgeyBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnZnMtdGl0bGUnKS5mb2N1cygpOyB9IGNhdGNoIChfKSB7
;fSByZXR1cm47IH0KICAgICAgaWYgKCFyZWdleCkgeyB0cnkgeyBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnZnMtcmVnZXgnKS5mb2N1cygpOyB9IGNhdGNo
;IChfKSB7fSByZXR1cm47IH0KICAgICAgY29uc3QgaWQgPSAnY18nICsgRGF0ZS5ub3coKS50b1N0cmluZygzNikgKyBNYXRoLnJhbmRvbSgpLnRvU3RyaW5n
;KDM2KS5zbGljZSgyLCA2KTsKICAgICAgZmlsdGVySXRlbXMucHVzaCh7IGlkLCB0aXRsZTogdGl0bGUuc2xpY2UoMCwgMjQpLCByZWdleDogcmVnZXguc2xp
;Y2UoMCwgMjAwKSwgYnVpbHRpbjogZmFsc2UsIGVuYWJsZWQ6IHRydWUgfSk7CiAgICAgIHNhdmVGaWx0ZXJJdGVtcygpOwogICAgICBmaWx0ZXJzT3BlbiA9
;IHRydWU7CiAgICAgIHJlbmRlckZpbHRlckJhcigpOwogICAgICByZW5kZXJGaWx0ZXJTZXR0aW5nc0xpc3QoKTsKICAgICAgY29uc3QgdCA9IGRvY3VtZW50
;LmdldEVsZW1lbnRCeUlkKCdmcy10aXRsZScpOwogICAgICBjb25zdCByID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2ZzLXJlZ2V4Jyk7CiAgICAgIGlm
;ICh0KSB0LnZhbHVlID0gJyc7CiAgICAgIGlmIChyKSByLnZhbHVlID0gJyc7CiAgICB9OwogIH0KICBjb25zdCBmc0V2ID0gZG9jdW1lbnQuZ2V0RWxlbWVu
;dEJ5SWQoJ2ZzLWV2LW9wdHMnKTsKICBpZiAoZnNFdikgZnNFdi5vbmNsaWNrID0gKCkgPT4gcG9zdCgnc2V0dGluZ3MnKTsKICBjb25zdCBmc1Jlc2V0ID0g
;ZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2ZzLXJlc2V0Jyk7CiAgaWYgKGZzUmVzZXQpIHsKICAgIGZzUmVzZXQub25jbGljayA9ICgpID0+IHsKICAgICAg
;aWYgKCFjb25maXJtKCfmgaLlpI3pu5jorqTnrZvpgInvvJ/lsIbov5jljp/jgIzlkKvkuK3mlocgLyDpnZ7kuIvliJLnur/lvIDlpLTjgI3vvIzlubbmuIXp
;maToh6rlrprkuYnpobnjgIInKSkgcmV0dXJuOwogICAgICByZXNldEZpbHRlcnNUb0RlZmF1bHQoKTsKICAgIH07CiAgfQogIGRvY3VtZW50LmFkZEV2ZW50
;TGlzdGVuZXIoJ2tleWRvd24nLCBlID0+IHsKICAgIGlmIChlLmtleSA9PT0gJ0VzY2FwZScgJiYgZmlsdGVyU2V0dGluZ3MgJiYgZmlsdGVyU2V0dGluZ3Mu
;Y2xhc3NMaXN0LmNvbnRhaW5zKCdvbicpKSB7CiAgICAgIGNsb3NlRmlsdGVyU2V0dGluZ3MoKTsKICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgIH0K
;ICB9LCB0cnVlKTsKCiAgLy8g55SoIFVSTCA/YnA9IOW4puWFpSBBSEsg5b2T5YmN6L+b5bqm77yb5LiK6ZmQIDg477yM6YG/5YWN6aaW5bGP55u05o6lIDEw
;MCUg5YaN6Zeq6L+b5Li755WM6Z2iCiAgdHJ5IHsKICAgIGNvbnN0IGJwID0gTWF0aC5tYXgoOCwgTWF0aC5taW4oODgsIHBhcnNlSW50KG5ldyBVUkxTZWFy
;Y2hQYXJhbXMobG9jYXRpb24uc2VhcmNoKS5nZXQoJ2JwJykgfHwgJzIwJywgMTApIHx8IDIwKSk7CiAgICBzZXRCb290UGN0KGJwKTsKICAgIGNvbnN0IHQx
;ID0gZG9jdW1lbnQucXVlcnlTZWxlY3RvcignI2Jvb3QgLnQxJyk7CiAgICBpZiAodDEgJiYgYnAgPj0gODApIHQxLnRleHRDb250ZW50ID0gJ+WNs+WwhuWu
;jOaIkCc7CiAgICBlbHNlIGlmICh0MSAmJiBicCA+PSA0MCkgdDEudGV4dENvbnRlbnQgPSAn56OB55uY57Si5byV5LitJzsKICAgIGVsc2UgaWYgKHQxKSB0
;MS50ZXh0Q29udGVudCA9ICfmraPlnKjliqDovb0nOwogIH0gY2F0Y2ggKGUpIHt9CgogIC8vIOKUgOKUgCDlhbPogZTlj6Xmn4QgLyDmnKzmnLrkv6Hmga/v
;vIjltYzlhaXkuLvliJfooajljLrvvInilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIAKICBjb25zdCBpbmZvUGFuZWwgPSBk
;b2N1bWVudC5nZXRFbGVtZW50QnlJZCgnaW5mby1wYW5lbCcpOwogIGNvbnN0IGhhbmRsZVBhbmVsID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2hhbmRs
;ZS1wYW5lbCcpOwogIGNvbnN0IGhhbmRsZUJvZHkgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnaGFuZGxlLWJvZHknKTsKICBjb25zdCBoYW5kbGVCYW5u
;ZXIgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnaGFuZGxlLWJhbm5lcicpOwogIGNvbnN0IGhhbmRsZVN0YXR1cyA9IGRvY3VtZW50LmdldEVsZW1lbnRC
;eUlkKCdoYW5kbGUtc3RhdHVzJyk7CiAgY29uc3QgYnRuUG9ydE1hcmsgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYnRuLXBvcnQtbWFyaycpOwogIGNv
;bnN0IHBvcnRNYXJrUG9wID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3BvcnQtbWFyay1wb3AnKTsKICBjb25zdCBwb3J0TWFya1RhZ3MgPSBkb2N1bWVu
;dC5nZXRFbGVtZW50QnlJZCgncG9ydC1tYXJrLXRhZ3MnKTsKICBjb25zdCBwb3J0TWFya0lucHV0ID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3BvcnQt
;bWFyay1pbnB1dCcpOwogIGNvbnN0IHByb2NNZW51ID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3Byb2MtbWVudScpOwogIGNvbnN0IGZpbGVSZXN1bHRz
;ID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2ZpbGUtcmVzdWx0cycpOwogIGNvbnN0IG1haW5FbCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdtYWlu
;Jyk7CiAgY29uc3QgYmFyRWwgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYmFyJyk7CiAgY29uc3QgTUFSS0VEX1BPUlRfS0VZID0gJ2Foa19tYXJrZWRf
;cG9ydHNfdjEnOwogIGNvbnN0IERFRkFVTFRfTUFSS0VEX1BPUlRTID0gWzIxLCAyMiwgMjUsIDUzLCA4MCwgMTEwLCAxNDMsIDQ0MywgNDQ1LCAzMzA2LCAz
;Mzg5LCA1NDMyLCA2Mzc5LCA4MDgwLCA4NDQzLCAyNzAxN107CiAgbGV0IG1hcmtlZFBvcnRzID0gbG9hZE1hcmtlZFBvcnRzKCk7CiAgZnVuY3Rpb24gbG9h
;ZE1hcmtlZFBvcnRzKCkgewogICAgdHJ5IHsKICAgICAgY29uc3QgcmF3ID0gbG9jYWxTdG9yYWdlLmdldEl0ZW0oTUFSS0VEX1BPUlRfS0VZKTsKICAgICAg
;aWYgKHJhdyA9PSBudWxsKSByZXR1cm4gREVGQVVMVF9NQVJLRURfUE9SVFMuc2xpY2UoKTsKICAgICAgY29uc3QgYXJyID0gSlNPTi5wYXJzZShyYXcpOwog
;ICAgICBpZiAoIUFycmF5LmlzQXJyYXkoYXJyKSkgcmV0dXJuIERFRkFVTFRfTUFSS0VEX1BPUlRTLnNsaWNlKCk7CiAgICAgIGNvbnN0IG91dCA9IFtdLCBz
;ZWVuID0gbmV3IFNldCgpOwogICAgICBmb3IgKGNvbnN0IHggb2YgYXJyKSB7CiAgICAgICAgY29uc3QgcCA9IHBhcnNlSW50KHgsIDEwKTsKICAgICAgICBp
;ZiAoIU51bWJlci5pc0ludGVnZXIocCkgfHwgcCA8IDAgfHwgcCA+IDY1NTM1IHx8IHNlZW4uaGFzKHApKSBjb250aW51ZTsKICAgICAgICBzZWVuLmFkZChw
;KTsgb3V0LnB1c2gocCk7CiAgICAgIH0KICAgICAgcmV0dXJuIG91dC5zb3J0KChhLCBiKSA9PiBhIC0gYik7CiAgICB9IGNhdGNoIChfKSB7IHJldHVybiBE
;RUZBVUxUX01BUktFRF9QT1JUUy5zbGljZSgpOyB9CiAgfQogIGZ1bmN0aW9uIHNhdmVNYXJrZWRQb3J0cygpIHsKICAgIHRyeSB7IGxvY2FsU3RvcmFnZS5z
;ZXRJdGVtKE1BUktFRF9QT1JUX0tFWSwgSlNPTi5zdHJpbmdpZnkobWFya2VkUG9ydHMpKTsgfSBjYXRjaCAoXykge30KICB9CiAgZnVuY3Rpb24gcG9ydElz
;SG90KHBvcnQpIHsKICAgIGNvbnN0IHAgPSBOdW1iZXIocG9ydCk7CiAgICByZXR1cm4gTnVtYmVyLmlzRmluaXRlKHApICYmIHAgPj0gMCAmJiBtYXJrZWRQ
;b3J0cy5pbmNsdWRlcyhwKTsKICB9CiAgZnVuY3Rpb24gY2xvc2VQb3J0TWFya1BvcCgpIHsKICAgIGlmIChwb3J0TWFya1BvcCkgcG9ydE1hcmtQb3AuY2xh
;c3NMaXN0LnJlbW92ZSgnb24nKTsKICAgIGlmIChidG5Qb3J0TWFyaykgYnRuUG9ydE1hcmsuY2xhc3NMaXN0LnJlbW92ZSgnb24nKTsKICB9CiAgZnVuY3Rp
;b24gcmVuZGVyTWFya2VkUG9ydFRhZ3MoKSB7CiAgICBpZiAoIXBvcnRNYXJrVGFncykgcmV0dXJuOwogICAgaWYgKCFtYXJrZWRQb3J0cy5sZW5ndGgpIHsK
;ICAgICAgcG9ydE1hcmtUYWdzLmlubmVySFRNTCA9ICc8ZGl2IGNsYXNzPSJwbXAtZW1wdHkiPuaaguaXoOagh+iusOerr+WPozwvZGl2Pic7CiAgICAgIHJl
;dHVybjsKICAgIH0KICAgIHBvcnRNYXJrVGFncy5pbm5lckhUTUwgPSBtYXJrZWRQb3J0cy5tYXAocCA9PgogICAgICAnPHNwYW4gY2xhc3M9InBtcC10YWci
;IGRhdGEtcG9ydD0iJyArIHAgKyAnIj4nICsgcAogICAgICArICc8YnV0dG9uIHR5cGU9ImJ1dHRvbiIgdGl0bGU9Iuenu+mZpCIgZGF0YS1ybT0iJyArIHAg
;KyAnIj7DlzwvYnV0dG9uPjwvc3Bhbj4nCiAgICApLmpvaW4oJycpOwogICAgcG9ydE1hcmtUYWdzLnF1ZXJ5U2VsZWN0b3JBbGwoJ2J1dHRvbltkYXRhLXJt
;XScpLmZvckVhY2goYnRuID0+IHsKICAgICAgYnRuLm9uY2xpY2sgPSAoZSkgPT4gewogICAgICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAgICAgY29u
;c3QgcCA9IE51bWJlcihidG4uZ2V0QXR0cmlidXRlKCdkYXRhLXJtJykpOwogICAgICAgIG1hcmtlZFBvcnRzID0gbWFya2VkUG9ydHMuZmlsdGVyKHggPT4g
;eCAhPT0gcCk7CiAgICAgICAgc2F2ZU1hcmtlZFBvcnRzKCk7CiAgICAgICAgcmVuZGVyTWFya2VkUG9ydFRhZ3MoKTsKICAgICAgICBpZiAoYXBwTW9kZSA9
;PT0gJ2hhbmRsZScgJiYgaGFuZGxlTW9kZSA9PT0gJ3BvcnQnKSByZW5kZXJIYW5kbGVUYWJsZSgpOwogICAgICB9OwogICAgfSk7CiAgfQogIGZ1bmN0aW9u
;IGFkZE1hcmtlZFBvcnQocmF3KSB7CiAgICBjb25zdCBwYXJ0cyA9IFN0cmluZyhyYXcgfHwgJycpLnNwbGl0KC9bLHzvvIxcc10rLykubWFwKHMgPT4gcy50
;cmltKCkpLmZpbHRlcihCb29sZWFuKTsKICAgIGxldCBjaGFuZ2VkID0gZmFsc2U7CiAgICBmb3IgKGNvbnN0IHBhcnQgb2YgcGFydHMpIHsKICAgICAgY29u
;c3QgcCA9IHBhcnNlSW50KHBhcnQsIDEwKTsKICAgICAgaWYgKCFOdW1iZXIuaXNJbnRlZ2VyKHApIHx8IHAgPCAwIHx8IHAgPiA2NTUzNSkgY29udGludWU7
;CiAgICAgIGlmIChtYXJrZWRQb3J0cy5pbmNsdWRlcyhwKSkgY29udGludWU7CiAgICAgIG1hcmtlZFBvcnRzLnB1c2gocCk7CiAgICAgIGNoYW5nZWQgPSB0
;cnVlOwogICAgfQogICAgaWYgKCFjaGFuZ2VkKSByZXR1cm4gZmFsc2U7CiAgICBtYXJrZWRQb3J0cy5zb3J0KChhLCBiKSA9PiBhIC0gYik7CiAgICBzYXZl
;TWFya2VkUG9ydHMoKTsKICAgIHJlbmRlck1hcmtlZFBvcnRUYWdzKCk7CiAgICBpZiAoYXBwTW9kZSA9PT0gJ2hhbmRsZScgJiYgaGFuZGxlTW9kZSA9PT0g
;J3BvcnQnKSByZW5kZXJIYW5kbGVUYWJsZSgpOwogICAgcmV0dXJuIHRydWU7CiAgfQogIGZ1bmN0aW9uIG9wZW5Qb3J0TWFya1BvcCgpIHsKICAgIHJlbmRl
;ck1hcmtlZFBvcnRUYWdzKCk7CiAgICBpZiAocG9ydE1hcmtQb3ApIHBvcnRNYXJrUG9wLmNsYXNzTGlzdC5hZGQoJ29uJyk7CiAgICBpZiAoYnRuUG9ydE1h
;cmspIGJ0blBvcnRNYXJrLmNsYXNzTGlzdC5hZGQoJ29uJyk7CiAgICB0cnkgeyBwb3J0TWFya0lucHV0ICYmIHBvcnRNYXJrSW5wdXQuZm9jdXMoKTsgfSBj
;YXRjaCAoXykge30KICB9CiAgbGV0IGhhbmRsZUl0ZW1zID0gW107CiAgbGV0IGhhbmRsZVF1ZXJ5ID0gJyc7CiAgbGV0IGhhbmRsZUJ1c3kgPSBmYWxzZTsK
;ICBsZXQgaW5mb0RhdGEgPSBudWxsOwogIGxldCBpbmZvVGV4dCA9ICcnOwogIGxldCBpbmZvUmVxR2VuID0gMDsKICBsZXQgaW5mb0xvYWRUaW1lciA9IDA7
;CiAgbGV0IG1vbml0b3JUYWIgPSAnZmlsZSc7CiAgbGV0IGhhbmRsZU1vZGUgPSAnaGFuZGxlJzsKICBsZXQgaGFuZGxlU29ydEtleSA9ICdscG9ydCc7CiAg
;bGV0IGhhbmRsZVNvcnREaXIgPSAxOyAvLyAxPeWNh+W6jyAtMT3pmY3luo8KICBjb25zdCBERUZBVUxUX1BPUlRfUVVFUlkgPSAnMC02NTUzNSc7CiAgY29u
;c3QgaGFuZGxlSGVhZCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdoYW5kbGUtaGVhZCcpOwogIGxldCBwcm9jTWVudVRhcmdldHMgPSBbXTsKICBsZXQg
;aGFuZGxlU2VsS2V5cyA9IG5ldyBTZXQoKTsKICBsZXQgaGFuZGxlQW5jaG9yS2V5ID0gJyc7CiAgLy8g5pen6L+b56iL55uR5o6nIFVJIOW3suenu+mZpO+8
;muWNoOS9jemBv+WFjeaui+eVmeS7o+eggeaKpemUmQogIGNvbnN0IHByb2NIZWFkID0gbnVsbDsKICBjb25zdCBwcm9jQm9keSA9IG51bGw7CiAgY29uc3Qg
;cHJvY1Njcm9sbCA9IG51bGw7CiAgY29uc3QgcHJvY0NwdVRvdGFsID0gbnVsbDsKICBjb25zdCBwcm9jTWVtVG90YWwgPSBudWxsOwogIGxldCBwcm9jSXRl
;bXMgPSBbXTsKICBsZXQgcHJvY1Nob3dTeXMgPSBmYWxzZTsKICBsZXQgcHJvY1NlbEtleXMgPSBuZXcgU2V0KCk7CiAgbGV0IHByb2NTZWxLZXkgPSAnJzsK
;ICBsZXQgcHJvY1NlbFBpZCA9IDA7CiAgbGV0IHByb2NBbmNob3JLZXkgPSAnJzsKICBsZXQgcHJvY1NvcnRLZXkgPSAnbmFtZSc7CiAgbGV0IHByb2NTb3J0
;RGlyID0gMTsKICBjb25zdCBwcm9jUm93TWFwID0gbmV3IE1hcCgpOwogIGNvbnN0IHByb2NJY29uU3RhYmxlID0gbmV3IE1hcCgpOwoKICBmdW5jdGlvbiBz
;ZXRBcHBNb2RlKG1vZGUpIHsKICAgIGlmIChtb2RlICE9PSAnaGFuZGxlJyAmJiBtb2RlICE9PSAnaW5mbycpIG1vZGUgPSAnZmlsZSc7CiAgICAvLyDnprvl
;vIDlvZPliY3mqKHlvI/liY3lhYjlrZjkuIvmkJzntKLmoYYKICAgIGlmIChhcHBNb2RlID09PSAnZmlsZScpIG1vZGVRdWVyeS5maWxlID0gU3RyaW5nKHFF
;bC52YWx1ZSB8fCAnJyk7CiAgICBlbHNlIGlmIChhcHBNb2RlID09PSAnaGFuZGxlJykgbW9kZVF1ZXJ5LmhhbmRsZSA9IFN0cmluZyhxRWwudmFsdWUgfHwg
;JycpOwogICAgZWxzZSBpZiAoYXBwTW9kZSA9PT0gJ2luZm8nKSBtb2RlUXVlcnkuaW5mbyA9IFN0cmluZyhxRWwudmFsdWUgfHwgJycpOwogICAgY29uc3Qg
;cHJldiA9IGFwcE1vZGU7CiAgICBhcHBNb2RlID0gbW9kZTsKICAgIG1vbml0b3JUYWIgPSBtb2RlID09PSAnZmlsZScgPyAnZmlsZScgOiBtb2RlOwogICAg
;Y29uc3QgaXNGaWxlID0gbW9kZSA9PT0gJ2ZpbGUnOwogICAgY29uc3QgaXNIYW5kbGUgPSBtb2RlID09PSAnaGFuZGxlJzsKICAgIGNvbnN0IGlzSW5mbyA9
;IG1vZGUgPT09ICdpbmZvJzsKICAgIGNvbnN0IHRvcEVsID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3RvcCcpOwogICAgaWYgKG1haW5FbCkgewogICAg
;ICBtYWluRWwuY2xhc3NMaXN0LnRvZ2dsZSgnbW9kZS10b29sJywgIWlzRmlsZSk7CiAgICAgIG1haW5FbC5jbGFzc0xpc3QudG9nZ2xlKCdtb2RlLWhhbmRs
;ZScsIGlzSGFuZGxlKTsKICAgICAgbWFpbkVsLmNsYXNzTGlzdC50b2dnbGUoJ21vZGUtaW5mbycsIGlzSW5mbyk7CiAgICB9CiAgICBpZiAoYmFyRWwpIHsK
;ICAgICAgYmFyRWwuY2xhc3NMaXN0LnRvZ2dsZSgnbW9kZS10b29sJywgIWlzRmlsZSk7CiAgICAgIGJhckVsLmNsYXNzTGlzdC50b2dnbGUoJ21vZGUtaW5m
;bycsIGlzSW5mbyk7CiAgICAgIGJhckVsLmNsYXNzTGlzdC50b2dnbGUoJ21vZGUtaGFuZGxlJywgaXNIYW5kbGUpOwogICAgfQogICAgaWYgKHRvcEVsKSB7
;CiAgICAgIHRvcEVsLmNsYXNzTGlzdC50b2dnbGUoJ21vZGUtdG9vbCcsICFpc0ZpbGUpOwogICAgICB0b3BFbC5jbGFzc0xpc3QudG9nZ2xlKCdtb2RlLWhh
;bmRsZScsIGlzSGFuZGxlKTsKICAgICAgdG9wRWwuY2xhc3NMaXN0LnRvZ2dsZSgnbW9kZS1pbmZvJywgaXNJbmZvKTsKICAgIH0KICAgIGlmIChhcHBSb290
;KSBhcHBSb290LmNsYXNzTGlzdC50b2dnbGUoJ2hpZGUtZmlsdGVycycsICFpc0ZpbGUpOwogICAgaWYgKGZpbGVSZXN1bHRzKSBmaWxlUmVzdWx0cy5jbGFz
;c0xpc3QudG9nZ2xlKCdoaWRkZW4nLCAhaXNGaWxlKTsKICAgIGlmIChoYW5kbGVQYW5lbCkgaGFuZGxlUGFuZWwuY2xhc3NMaXN0LnRvZ2dsZSgnaGlkZGVu
;JywgIWlzSGFuZGxlKTsKICAgIGlmIChpbmZvUGFuZWwpIGluZm9QYW5lbC5jbGFzc0xpc3QudG9nZ2xlKCdoaWRkZW4nLCAhaXNJbmZvKTsKICAgIHFFbC5y
;ZWFkT25seSA9IGlzSW5mbzsKICAgIGNsb3NlSGlzdE1lbnUoKTsKICAgIGNsb3NlUG9ydE1hcmtQb3AoKTsKICAgIHBvc3QoJ3Byb2NWaWV3fDAnKTsKICAg
;IGlmIChpc0hhbmRsZSkgewogICAgICBxRWwucGxhY2Vob2xkZXIgPSBQTEFDRUhPTERFUl9IQU5ETEU7CiAgICAgIGhhbmRsZVNvcnRLZXkgPSAnbHBvcnQn
;OwogICAgICBoYW5kbGVTb3J0RGlyID0gMTsKICAgICAgcUVsLnZhbHVlID0gbW9kZVF1ZXJ5LmhhbmRsZTsKICAgICAgc3luY0NsZWFyQnRuKCk7CiAgICAg
;IHJlcXVlc3RIYW5kbGVTZWFyY2gobW9kZVF1ZXJ5LmhhbmRsZSk7CiAgICAgIHRyeSB7IHFFbC5mb2N1cygpOyB9IGNhdGNoIChfKSB7fQogICAgfSBlbHNl
;IGlmIChpc0luZm8pIHsKICAgICAgcUVsLnBsYWNlaG9sZGVyID0gUExBQ0VIT0xERVJfSU5GTzsKICAgICAgcUVsLnZhbHVlID0gbW9kZVF1ZXJ5LmluZm87
;CiAgICAgIHN5bmNDbGVhckJ0bigpOwogICAgICBjb3VudEVsLnRleHRDb250ZW50ID0gJ+acrOacuuS/oeaBryc7CiAgICAgIHJlcXVlc3RTeXNJbmZvKGZh
;bHNlKTsKICAgIH0gZWxzZSB7CiAgICAgIHFFbC5wbGFjZWhvbGRlciA9IFBMQUNFSE9MREVSX0ZJTEU7CiAgICAgIHFFbC52YWx1ZSA9IG1vZGVRdWVyeS5m
;aWxlOwogICAgICBzeW5jQ2xlYXJCdG4oKTsKICAgICAgdHJ5IHsgcUVsLmZvY3VzKCk7IH0gY2F0Y2ggKF8pIHt9CiAgICAgIC8vIOS7juWFtuWug+aooeW8
;j+WIh+WbnuaWh+S7tu+8mueUqOacrOWcsOadoeS7tumHjeaQnO+8iOWQq+etm+mAie+8ie+8jOS4jeW4puWPpeafhOWFs+mUruWtlwogICAgICBpZiAocHJl
;diAhPT0gJ2ZpbGUnKSBkb1NlYXJjaCgpOwogICAgfQogIH0KICBmdW5jdGlvbiBzZXRBcHBWaWV3KG5hbWUpIHsKICAgIC8vIOWFvOWuueaXp+WFpeWPo++8
;muWIh+WIsOS+p+agj+WvueW6lOmhuQogICAgaWYgKG5hbWUgPT09ICdoYW5kbGUnIHx8IG5hbWUgPT09ICdwcm9jJykgewogICAgICBkb2N1bWVudC5xdWVy
;eVNlbGVjdG9yQWxsKCcuY2F0JykuZm9yRWFjaChiID0+IGIuY2xhc3NMaXN0LnRvZ2dsZSgnb24nLCBiLmRhdGFzZXQuY2F0ID09PSAnX19oYW5kbGUnKSk7
;CiAgICAgIHNldEFwcE1vZGUoJ2hhbmRsZScpOwogICAgICByZXR1cm47CiAgICB9CiAgICBpZiAobmFtZSA9PT0gJ2luZm8nKSB7CiAgICAgIGRvY3VtZW50
;LnF1ZXJ5U2VsZWN0b3JBbGwoJy5jYXQnKS5mb3JFYWNoKGIgPT4gYi5jbGFzc0xpc3QudG9nZ2xlKCdvbicsIGIuZGF0YXNldC5jYXQgPT09ICdfX2luZm8n
;KSk7CiAgICAgIHNldEFwcE1vZGUoJ2luZm8nKTsKICAgICAgcmV0dXJuOwogICAgfQogICAgZG9jdW1lbnQucXVlcnlTZWxlY3RvckFsbCgnLmNhdCcpLmZv
;ckVhY2goYiA9PiBiLmNsYXNzTGlzdC50b2dnbGUoJ29uJywgYi5kYXRhc2V0LmNhdCA9PT0gY2F0KSk7CiAgICBzZXRBcHBNb2RlKCdmaWxlJyk7CiAgfQog
;IGZ1bmN0aW9uIHN5bmNQcm9jTW9uaXRvckxpdmUoKSB7IHBvc3QoJ3Byb2NWaWV3fDAnKTsgfQogIGZ1bmN0aW9uIHJlcXVlc3RQcm9jTGlzdCgpIHsgLyog
;5bey56e76Zmk6YeN5Z6L6L+b56iL55uR5o6nICovIH0KICBmdW5jdGlvbiBjbGVhckluZm9Mb2FkV2FpdCgpIHsKICAgIGlmIChpbmZvTG9hZFRpbWVyKSB7
;CiAgICAgIGNsZWFyVGltZW91dChpbmZvTG9hZFRpbWVyKTsKICAgICAgaW5mb0xvYWRUaW1lciA9IDA7CiAgICB9CiAgfQogIGZ1bmN0aW9uIHNob3dJbmZv
;TG9hZGluZygpIHsKICAgIGlmICghaW5mb1BhbmVsIHx8IGFwcE1vZGUgIT09ICdpbmZvJykgcmV0dXJuOwogICAgaW5mb1BhbmVsLmlubmVySFRNTCA9ICc8
;ZGl2IGNsYXNzPSJpbmZvLWxvYWRpbmciPjxkaXYgY2xhc3M9ImluZm8tc3Bpbm5lciIgYXJpYS1oaWRkZW49InRydWUiPjwvZGl2PjxkaXY+5q2j5Zyo6K+7
;5Y+W5pys5py65L+h5oGv4oCmPC9kaXY+PC9kaXY+JzsKICAgIGlmIChjb3VudEVsKSBjb3VudEVsLnRleHRDb250ZW50ID0gJ+WKoOi9veS4reKApic7CiAg
;fQogIGZ1bmN0aW9uIHJlcXVlc3RTeXNJbmZvKGZvcmNlKSB7CiAgICBmb3JjZSA9ICEhZm9yY2U7CiAgICBjb25zdCBteUdlbiA9ICsraW5mb1JlcUdlbjsK
;ICAgIGNsZWFySW5mb0xvYWRXYWl0KCk7CiAgICAvLyDnvJPlrZjlkb3kuK3pgJrluLjlvojlv6vvvJvotoXov4fnuqYgMC40cyDlho3lh7rliqDovb3liqjn
;lLvvvIzpgb/lhY3pl6rkuIDkuIsKICAgIGlmIChmb3JjZSB8fCAhaW5mb0RhdGEpIHsKICAgICAgaW5mb0xvYWRUaW1lciA9IHNldFRpbWVvdXQoKCkgPT4g
;ewogICAgICAgIGluZm9Mb2FkVGltZXIgPSAwOwogICAgICAgIGlmIChteUdlbiAhPT0gaW5mb1JlcUdlbiB8fCBhcHBNb2RlICE9PSAnaW5mbycpIHJldHVy
;bjsKICAgICAgICBzaG93SW5mb0xvYWRpbmcoKTsKICAgICAgfSwgNDAwKTsKICAgIH0KICAgIHBvc3QoJ3N5c0luZm98JyArIChmb3JjZSA/ICcxJyA6ICcw
;JykpOwogIH0KICBjb25zdCBIQU5ETEVfSElTVF9LRVkgPSAnYWhrX2hhbmRsZV9zZWFyY2hfaGlzdF92MSc7CiAgY29uc3QgSEFORExFX0hJU1RfTUFYID0g
;MTA7CiAgY29uc3QgaGFuZGxlSGlzdExpc3QgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnaGFuZGxlLWhpc3QtbGlzdCcpOwogIGZ1bmN0aW9uIGxvYWRI
;YW5kbGVIaXN0KCkgewogICAgdHJ5IHsKICAgICAgY29uc3QgcmF3ID0gbG9jYWxTdG9yYWdlLmdldEl0ZW0oSEFORExFX0hJU1RfS0VZKTsKICAgICAgY29u
;c3QgYXJyID0gcmF3ID8gSlNPTi5wYXJzZShyYXcpIDogW107CiAgICAgIHJldHVybiBBcnJheS5pc0FycmF5KGFycikgPyBhcnIuZmlsdGVyKHggPT4gU3Ry
;aW5nKHggfHwgJycpLnRyaW0oKSkgOiBbXTsKICAgIH0gY2F0Y2ggKF8pIHsgcmV0dXJuIFtdOyB9CiAgfQogIGZ1bmN0aW9uIHNhdmVIYW5kbGVIaXN0KHEp
;IHsKICAgIHEgPSBTdHJpbmcocSB8fCAnJykudHJpbSgpOwogICAgaWYgKCFxKSByZXR1cm47CiAgICBsZXQgYXJyID0gbG9hZEhhbmRsZUhpc3QoKS5maWx0
;ZXIoeCA9PiB4ICE9PSBxKTsKICAgIGFyci51bnNoaWZ0KHEpOwogICAgaWYgKGFyci5sZW5ndGggPiBIQU5ETEVfSElTVF9NQVgpIGFyciA9IGFyci5zbGlj
;ZSgwLCBIQU5ETEVfSElTVF9NQVgpOwogICAgdHJ5IHsgbG9jYWxTdG9yYWdlLnNldEl0ZW0oSEFORExFX0hJU1RfS0VZLCBKU09OLnN0cmluZ2lmeShhcnIp
;KTsgfSBjYXRjaCAoXykge30KICAgIHJlbmRlckhhbmRsZUhpc3QoKTsKICB9CiAgZnVuY3Rpb24gcmVuZGVySGFuZGxlSGlzdCgpIHsKICAgIGlmICghaGFu
;ZGxlSGlzdExpc3QpIHJldHVybjsKICAgIGhhbmRsZUhpc3RMaXN0LmlubmVySFRNTCA9IGxvYWRIYW5kbGVIaXN0KCkubWFwKHEgPT4KICAgICAgJzxvcHRp
;b24gdmFsdWU9IicgKyBlc2NhcGVIdG1sKHEpICsgJyI+PC9vcHRpb24+JwogICAgKS5qb2luKCcnKTsKICB9CiAgZnVuY3Rpb24gbm9ybWFsaXplUG9ydFF1
;ZXJ5KHEpIHsKICAgIHEgPSBTdHJpbmcocSB8fCAnJykudHJpbSgpOwogICAgY29uc3QgbSA9IHEubWF0Y2goL15cL+err+WPo1xzKiguKikkL2kpIHx8IHEu
;bWF0Y2goL15cL3BvcnRccyooLiopJC9pKTsKICAgIGlmIChtKSBxID0gU3RyaW5nKG1bMV0gfHwgJycpLnRyaW0oKTsKICAgIHJldHVybiBxOwogIH0KICBm
;dW5jdGlvbiBpc1BvcnRTZWFyY2hRdWVyeShxKSB7CiAgICBxID0gbm9ybWFsaXplUG9ydFF1ZXJ5KHEpOwogICAgcmV0dXJuICEhcSAmJiAvXltcZFxzfFwt
;XSskLy50ZXN0KHEpICYmIC9cZC8udGVzdChxKTsKICB9CiAgZnVuY3Rpb24gcGFyc2VQb3J0TGlzdChxKSB7CiAgICBxID0gbm9ybWFsaXplUG9ydFF1ZXJ5
;KHEpOwogICAgY29uc3Qgb3V0ID0gW10sIHNlZW4gPSBuZXcgU2V0KCk7CiAgICBjb25zdCBhZGQgPSAocCkgPT4gewogICAgICBwID0gTnVtYmVyKHApOwog
;ICAgICBpZiAoIU51bWJlci5pc0ludGVnZXIocCkgfHwgcCA8IDAgfHwgcCA+IDY1NTM1IHx8IHNlZW4uaGFzKHApKSByZXR1cm47CiAgICAgIHNlZW4uYWRk
;KHApOwogICAgICBvdXQucHVzaChwKTsKICAgIH07CiAgICBmb3IgKGNvbnN0IHBhcnQgb2YgU3RyaW5nKHEpLnNwbGl0KCd8JykpIHsKICAgICAgY29uc3Qg
;cyA9IFN0cmluZyhwYXJ0IHx8ICcnKS50cmltKCk7CiAgICAgIGlmICghcykgY29udGludWU7CiAgICAgIGNvbnN0IG0gPSBzLm1hdGNoKC9eKFxkKylccyot
;XHMqKFxkKykkLyk7CiAgICAgIGlmIChtKSB7CiAgICAgICAgbGV0IGEgPSBwYXJzZUludChtWzFdLCAxMCksIGIgPSBwYXJzZUludChtWzJdLCAxMCk7CiAg
;ICAgICAgaWYgKGEgPiBiKSB7IGNvbnN0IHQgPSBhOyBhID0gYjsgYiA9IHQ7IH0KICAgICAgICBhID0gTWF0aC5tYXgoMCwgTWF0aC5taW4oNjU1MzUsIGEp
;KTsKICAgICAgICBiID0gTWF0aC5tYXgoMCwgTWF0aC5taW4oNjU1MzUsIGIpKTsKICAgICAgICBmb3IgKGxldCBwID0gYTsgcCA8PSBiOyBwKyspIGFkZChw
;KTsKICAgICAgfSBlbHNlIGlmICgvXlxkKyQvLnRlc3QocykpIHsKICAgICAgICBhZGQocGFyc2VJbnQocywgMTApKTsKICAgICAgfQogICAgfQogICAgcmV0
;dXJuIG91dDsKICB9CiAgZnVuY3Rpb24gaXNBbGxQb3J0c1F1ZXJ5VGV4dChxKSB7CiAgICBxID0gU3RyaW5nKHEgfHwgJycpLnRyaW0oKTsKICAgIHJldHVy
;biAhcSB8fCBxID09PSBERUZBVUxUX1BPUlRfUVVFUlkgfHwgL14wXHMqLVxzKjY1NTM1JC8udGVzdChxKTsKICB9CiAgZnVuY3Rpb24gcmVxdWVzdEhhbmRs
;ZVNlYXJjaChxKSB7CiAgICBxID0gU3RyaW5nKHEgfHwgJycpLnRyaW0oKTsKICAgIC8vIOepuuahhiAvIOWFqOerr+WPoyDihpIg55u05o6l5pi+56S65YWo
;6YOo6L+e5o6l77yM5LiN5oqK5p2h5Lu25YaZ6L+b6L6T5YWl5qGGCiAgICBpZiAoaXNBbGxQb3J0c1F1ZXJ5VGV4dChxKSkgewogICAgICBoYW5kbGVRdWVy
;eSA9IERFRkFVTFRfUE9SVF9RVUVSWTsKICAgICAgaGFuZGxlTW9kZSA9ICdwb3J0JzsKICAgICAgaGFuZGxlQnVzeSA9IHRydWU7CiAgICAgIGlmIChoYW5k
;bGVTdGF0dXMpIGhhbmRsZVN0YXR1cy50ZXh0Q29udGVudCA9ICfmraPlnKjmn6Xor6LigKYnOwogICAgICBoYW5kbGVCYW5uZXIuY2xhc3NMaXN0LmFkZCgn
;b24nKTsKICAgICAgaGFuZGxlQmFubmVyLnRleHRDb250ZW50ID0gJ+WFqOmDqOi/nuaOpSc7CiAgICAgIGhhbmRsZVNlbEtleXMuY2xlYXIoKTsKICAgICAg
;aGFuZGxlQW5jaG9yS2V5ID0gJyc7CiAgICAgIHN5bmNIYW5kbGVCYXIoMCk7CiAgICAgIHNob3dIYW5kbGVMb2FkaW5nKCfmraPlnKjmn6Xor6Lnq6/lj6Pl
;jaDnlKjvvIzor7fnqI3lgJnigKYnKTsKICAgICAgcG9zdCgnaGFuZGxlU2VhcmNofCcgKyBERUZBVUxUX1BPUlRfUVVFUlkpOwogICAgICByZXR1cm47CiAg
;ICB9CiAgICBoYW5kbGVRdWVyeSA9IHE7CiAgICBoYW5kbGVNb2RlID0gaXNQb3J0U2VhcmNoUXVlcnkocSkgPyAncG9ydCcgOiAnaGFuZGxlJzsKICAgIGlm
;IChoYW5kbGVNb2RlID09PSAncG9ydCcgJiYgIXBhcnNlUG9ydExpc3QocSkubGVuZ3RoKSB7CiAgICAgIGhhbmRsZUl0ZW1zID0gW107CiAgICAgIHJlbmRl
;ckhhbmRsZVRhYmxlKCfnq6/lj6Pml6DmlYjvvIznpLrkvovvvJo4MDgwfDgwIOaIliAwLTMwMHw1MDAnKTsKICAgICAgcmV0dXJuOwogICAgfQogICAgc2F2
;ZUhhbmRsZUhpc3QocSk7CiAgICBoYW5kbGVCdXN5ID0gdHJ1ZTsKICAgIGlmIChoYW5kbGVTdGF0dXMpIGhhbmRsZVN0YXR1cy50ZXh0Q29udGVudCA9ICfm
;raPlnKjmn6Xor6LigKYnOwogICAgaGFuZGxlQmFubmVyLmNsYXNzTGlzdC5hZGQoJ29uJyk7CiAgICBoYW5kbGVCYW5uZXIudGV4dENvbnRlbnQgPSAn4oCc
;JyArIHEgKyAn4oCd55qE5pCc57Si57uT5p6cJzsKICAgIGhhbmRsZVNlbEtleXMuY2xlYXIoKTsKICAgIGhhbmRsZUFuY2hvcktleSA9ICcnOwogICAgc3lu
;Y0hhbmRsZUJhcigwKTsKICAgIHNob3dIYW5kbGVMb2FkaW5nKGhhbmRsZU1vZGUgPT09ICdwb3J0JyA/ICfmraPlnKjmn6Xor6Lnq6/lj6PljaDnlKjvvIzo
;r7fnqI3lgJnigKYnIDogJ+ato+WcqOafpeivouWPpeafhO+8jOivt+eojeWAmeKApicpOwogICAgcG9zdCgnaGFuZGxlU2VhcmNofCcgKyBxKTsKICB9CiAg
;ZnVuY3Rpb24gc2hvd0hhbmRsZUxvYWRpbmcobXNnKSB7CiAgICBoYW5kbGVCb2R5LmlubmVySFRNTCA9ICc8ZGl2IGNsYXNzPSJoYW5kbGUtbG9hZGluZyI+
;PGRpdiBjbGFzcz0iaGFuZGxlLXNwaW5uZXIiIGFyaWEtaGlkZGVuPSJ0cnVlIj48L2Rpdj48ZGl2PicKICAgICAgKyBlc2NhcGVIdG1sKG1zZyB8fCAn5q2j
;5Zyo5p+l6K+i5Y+l5p+E77yM6K+356iN5YCZ4oCmJykgKyAnPC9kaXY+PC9kaXY+JzsKICB9CiAgZnVuY3Rpb24gc29ydEhhbmRsZUl0ZW1zKGl0ZW1zKSB7
;CiAgICBjb25zdCBrZXkgPSBoYW5kbGVTb3J0S2V5IHx8IChoYW5kbGVNb2RlID09PSAncG9ydCcgPyAnbHBvcnQnIDogJ25hbWUnKTsKICAgIGNvbnN0IGRp
;ciA9IGhhbmRsZVNvcnREaXIgfHwgMTsKICAgIHJldHVybiAoaXRlbXMgfHwgW10pLnNsaWNlKCkuc29ydCgoYSwgYikgPT4gewogICAgICBsZXQgY21wID0g
;MDsKICAgICAgaWYgKGtleSA9PT0gJ3BpZCcpIHsKICAgICAgICBjbXAgPSAoTnVtYmVyKGEucGlkKSB8fCAwKSAtIChOdW1iZXIoYi5waWQpIHx8IDApOwog
;ICAgICB9IGVsc2UgaWYgKGtleSA9PT0gJ2xwb3J0JykgewogICAgICAgIGNtcCA9IChOdW1iZXIoYS5sb2NhbFBvcnQpIHx8IDApIC0gKE51bWJlcihiLmxv
;Y2FsUG9ydCkgfHwgMCk7CiAgICAgIH0gZWxzZSBpZiAoa2V5ID09PSAncnBvcnQnKSB7CiAgICAgICAgY21wID0gKE51bWJlcihhLnJlbW90ZVBvcnQpIHx8
;IDApIC0gKE51bWJlcihiLnJlbW90ZVBvcnQpIHx8IDApOwogICAgICB9IGVsc2UgaWYgKGtleSA9PT0gJ3R5cGUnKSB7CiAgICAgICAgY21wID0gU3RyaW5n
;KGEudHlwZSB8fCAnJykubG9jYWxlQ29tcGFyZShTdHJpbmcoYi50eXBlIHx8ICcnKSwgJ2VuJywgeyBzZW5zaXRpdml0eTogJ2Jhc2UnIH0pOwogICAgICB9
;IGVsc2UgaWYgKGtleSA9PT0gJ2hhbmRsZScpIHsKICAgICAgICBjbXAgPSBTdHJpbmcoYS5oYW5kbGUgfHwgJycpLmxvY2FsZUNvbXBhcmUoU3RyaW5nKGIu
;aGFuZGxlIHx8ICcnKSwgJ3poLUNOJyk7CiAgICAgIH0gZWxzZSB7CiAgICAgICAgY21wID0gY29tcGFyZVByb2NOYW1lKGEubmFtZSB8fCAnJywgYi5uYW1l
;IHx8ICcnKTsKICAgICAgfQogICAgICBpZiAoY21wKSByZXR1cm4gY21wICogZGlyOwogICAgICAvLyDmrKHopoHplK7vvJrnq6/lj6PmqKHlvI/kvJjlhYjm
;nKzmnLrnq6/lj6PvvIzlho0gUElEIC8g5ZCN56ewCiAgICAgIGNvbnN0IGxwID0gKE51bWJlcihhLmxvY2FsUG9ydCkgfHwgMCkgLSAoTnVtYmVyKGIubG9j
;YWxQb3J0KSB8fCAwKTsKICAgICAgaWYgKGxwKSByZXR1cm4gbHA7CiAgICAgIGNvbnN0IHBhID0gKE51bWJlcihhLnBpZCkgfHwgMCkgLSAoTnVtYmVyKGIu
;cGlkKSB8fCAwKTsKICAgICAgaWYgKHBhKSByZXR1cm4gcGE7CiAgICAgIHJldHVybiBjb21wYXJlUHJvY05hbWUoYS5uYW1lIHx8ICcnLCBiLm5hbWUgfHwg
;JycpOwogICAgfSk7CiAgfQogIGZ1bmN0aW9uIHN5bmNIYW5kbGVIZWFkU29ydCgpIHsKICAgIGlmICghaGFuZGxlSGVhZCkgcmV0dXJuOwogICAgaGFuZGxl
;SGVhZC5xdWVyeVNlbGVjdG9yQWxsKCcuaGFuZGxlLWhjZWxsW2RhdGEtc29ydF0nKS5mb3JFYWNoKGNlbGwgPT4gewogICAgICBjb25zdCBrID0gY2VsbC5n
;ZXRBdHRyaWJ1dGUoJ2RhdGEtc29ydCcpOwogICAgICBjb25zdCBvbiA9IGsgPT09IGhhbmRsZVNvcnRLZXk7CiAgICAgIGNlbGwuY2xhc3NMaXN0LnRvZ2ds
;ZSgnc29ydGVkJywgb24pOwogICAgICBjZWxsLmNsYXNzTGlzdC50b2dnbGUoJ2FzYycsIG9uICYmIGhhbmRsZVNvcnREaXIgPiAwKTsKICAgICAgY2VsbC5j
;bGFzc0xpc3QudG9nZ2xlKCdkZXNjJywgb24gJiYgaGFuZGxlU29ydERpciA8IDApOwogICAgfSk7CiAgfQogIGZ1bmN0aW9uIGJpbmRIYW5kbGVIZWFkU29y
;dCgpIHsKICAgIGlmICghaGFuZGxlSGVhZCB8fCBoYW5kbGVIZWFkLmRhdGFzZXQuc29ydEJvdW5kID09PSAnMScpIHJldHVybjsKICAgIGhhbmRsZUhlYWQu
;ZGF0YXNldC5zb3J0Qm91bmQgPSAnMSc7CiAgICBoYW5kbGVIZWFkLnF1ZXJ5U2VsZWN0b3JBbGwoJy5oYW5kbGUtaGNlbGxbZGF0YS1zb3J0XScpLmZvckVh
;Y2goY2VsbCA9PiB7CiAgICAgIGNlbGwuYWRkRXZlbnRMaXN0ZW5lcignY2xpY2snLCAoZSkgPT4gewogICAgICAgIGUucHJldmVudERlZmF1bHQoKTsKICAg
;ICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgICAgIGNvbnN0IGsgPSBjZWxsLmdldEF0dHJpYnV0ZSgnZGF0YS1zb3J0Jyk7CiAgICAgICAgaWYgKCFr
;KSByZXR1cm47CiAgICAgICAgaWYgKGhhbmRsZVNvcnRLZXkgPT09IGspIGhhbmRsZVNvcnREaXIgPSAtaGFuZGxlU29ydERpcjsKICAgICAgICBlbHNlIHsK
;ICAgICAgICAgIGhhbmRsZVNvcnRLZXkgPSBrOwogICAgICAgICAgaGFuZGxlU29ydERpciA9IChrID09PSAnbHBvcnQnIHx8IGsgPT09ICdycG9ydCcgfHwg
;ayA9PT0gJ3BpZCcpID8gMSA6IDE7CiAgICAgICAgfQogICAgICAgIGlmIChoYW5kbGVJdGVtcy5sZW5ndGgpIHJlbmRlckhhbmRsZVRhYmxlKCk7CiAgICAg
;ICAgZWxzZSBzeW5jSGFuZGxlSGVhZFNvcnQoKTsKICAgICAgfSk7CiAgICB9KTsKICB9CiAgYmluZEhhbmRsZUhlYWRTb3J0KCk7CiAgZnVuY3Rpb24gcG9y
;dFRpcFRleHQoaXQpIHsKICAgIGNvbnN0IGxpcCA9IFN0cmluZyhpdC5sb2NhbElwIHx8ICcwLjAuMC4wJyk7CiAgICBjb25zdCBscG9ydCA9IChpdC5sb2Nh
;bFBvcnQgPT0gbnVsbCB8fCBOdW1iZXIoaXQubG9jYWxQb3J0KSA8IDApID8gJycgOiBTdHJpbmcoaXQubG9jYWxQb3J0KTsKICAgIGNvbnN0IHJpcCA9IFN0
;cmluZyhpdC5yZW1vdGVJcCB8fCAnMC4wLjAuMCcpOwogICAgY29uc3QgcnBvcnQgPSAoaXQucmVtb3RlUG9ydCA9PSBudWxsIHx8IE51bWJlcihpdC5yZW1v
;dGVQb3J0KSA8IDApID8gJycgOiBTdHJpbmcoaXQucmVtb3RlUG9ydCk7CiAgICByZXR1cm4gJ+acrOacuu+8micgKyBsaXAgKyAnOicgKyBscG9ydCArICdc
;bui/nOeoi++8micgKyByaXAgKyAnOicgKyBycG9ydDsKICB9CiAgZnVuY3Rpb24gc2V0SGFuZGxlUG9ydE1vZGUob24pIHsKICAgIGRvY3VtZW50LnF1ZXJ5
;U2VsZWN0b3JBbGwoJy5oYW5kbGUtY29scycpLmZvckVhY2goZWwgPT4gZWwuY2xhc3NMaXN0LnRvZ2dsZSgncG9ydC1tb2RlJywgISFvbikpOwogICAgZG9j
;dW1lbnQucXVlcnlTZWxlY3RvckFsbCgnLmhhbmRsZS1jb2wtcG9ydCwuaGFuZGxlLWNvbC1ycG9ydCcpLmZvckVhY2goZWwgPT4gZWwuY2xhc3NMaXN0LnRv
;Z2dsZSgnaGlkZGVuJywgIW9uKSk7CiAgfQogIGZ1bmN0aW9uIGRlZHVwZVBvcnRJdGVtcyhpdGVtcykgewogICAgY29uc3Qgb3V0ID0gW10sIHNlZW4gPSBu
;ZXcgU2V0KCk7CiAgICBmb3IgKGNvbnN0IGl0IG9mIGl0ZW1zIHx8IFtdKSB7CiAgICAgIGNvbnN0IGtleSA9IFsKICAgICAgICBOdW1iZXIoaXQucGlkKSB8
;fCAwLAogICAgICAgIFN0cmluZyhpdC50eXBlIHx8ICcnKS50b1VwcGVyQ2FzZSgpLAogICAgICAgIE51bWJlcihpdC5sb2NhbFBvcnQpIHx8IDAsCiAgICAg
;ICAgTnVtYmVyKGl0LnJlbW90ZVBvcnQpIHx8IDAsCiAgICAgICAgU3RyaW5nKGl0LmhhbmRsZSB8fCAnJykKICAgICAgXS5qb2luKCd8Jyk7CiAgICAgIGlm
;IChzZWVuLmhhcyhrZXkpKSBjb250aW51ZTsKICAgICAgc2Vlbi5hZGQoa2V5KTsKICAgICAgb3V0LnB1c2goaXQpOwogICAgfQogICAgcmV0dXJuIG91dDsK
;ICB9CiAgZnVuY3Rpb24gcmVuZGVySGFuZGxlVGFibGUoZW1wdHlNc2cpIHsKICAgIGNvbnN0IHEgPSBoYW5kbGVRdWVyeTsKICAgIGNvbnN0IHBvcnRNb2Rl
;ID0gaGFuZGxlTW9kZSA9PT0gJ3BvcnQnOwogICAgc2V0SGFuZGxlUG9ydE1vZGUocG9ydE1vZGUpOwogICAgaWYgKHEpIHsKICAgICAgaGFuZGxlQmFubmVy
;LmNsYXNzTGlzdC5hZGQoJ29uJyk7CiAgICAgIGlmIChwb3J0TW9kZSAmJiAocSA9PT0gREVGQVVMVF9QT1JUX1FVRVJZIHx8IC9eMFxzKi1ccyo2NTUzNSQv
;LnRlc3QocSkpKQogICAgICAgIGhhbmRsZUJhbm5lci50ZXh0Q29udGVudCA9ICflhajpg6jov57mjqUnOwogICAgICBlbHNlCiAgICAgICAgaGFuZGxlQmFu
;bmVyLnRleHRDb250ZW50ID0gKHBvcnRNb2RlID8gJ+err+WPoyAnIDogJycpICsgJ+KAnCcgKyBxICsgJ+KAneeahOaQnOe0oue7k+aenCc7CiAgICB9IGVs
;c2UgewogICAgICBoYW5kbGVCYW5uZXIuY2xhc3NMaXN0LnJlbW92ZSgnb24nKTsKICAgICAgaGFuZGxlQmFubmVyLnRleHRDb250ZW50ID0gJyc7CiAgICB9
;CiAgICBpZiAoaGFuZGxlQnVzeSAmJiAhaGFuZGxlSXRlbXMubGVuZ3RoKSB7CiAgICAgIHNob3dIYW5kbGVMb2FkaW5nKGVtcHR5TXNnIHx8IChwb3J0TW9k
;ZSA/ICfmraPlnKjmn6Xor6Lnq6/lj6PigKYnIDogJ+ato+WcqOafpeivouWPpeafhOKApicpKTsKICAgICAgc3luY0hhbmRsZUJhcigwKTsKICAgICAgc3lu
;Y0hhbmRsZUhlYWRTb3J0KCk7CiAgICAgIHJldHVybjsKICAgIH0KICAgIGlmIChwb3J0TW9kZSkgaGFuZGxlSXRlbXMgPSBkZWR1cGVQb3J0SXRlbXMoaGFu
;ZGxlSXRlbXMpOwogICAgaGFuZGxlSXRlbXMgPSBzb3J0SGFuZGxlSXRlbXMoaGFuZGxlSXRlbXMpOwogICAgc3luY0hhbmRsZUhlYWRTb3J0KCk7CiAgICBj
;b25zdCBuID0gaGFuZGxlSXRlbXMubGVuZ3RoOwogICAgc3luY0hhbmRsZUJhcihuKTsKICAgIGlmICghbikgewogICAgICBoYW5kbGVCb2R5LmlubmVySFRN
;TCA9ICc8ZGl2IGNsYXNzPSJoYW5kbGUtZW1wdHkiPicgKyBlc2NhcGVIdG1sKGVtcHR5TXNnIHx8IChwb3J0TW9kZSA/ICfmsqHmnInljLnphY3nmoTnq6/l
;j6MnIDogJ+ayoeacieWMuemFjeeahOWPpeafhCcpKSArICc8L2Rpdj4nOwogICAgICBoYW5kbGVTZWxLZXlzLmNsZWFyKCk7CiAgICAgIGhhbmRsZUFuY2hv
;cktleSA9ICcnOwogICAgICByZXR1cm47CiAgICB9CiAgICBjb25zdCBrZWVwID0gbmV3IFNldCgpOwogICAgY29uc3QgZnJhZyA9IGRvY3VtZW50LmNyZWF0
;ZURvY3VtZW50RnJhZ21lbnQoKTsKICAgIGZvciAobGV0IGkgPSAwOyBpIDwgaGFuZGxlSXRlbXMubGVuZ3RoOyBpKyspIHsKICAgICAgY29uc3QgaXQgPSBo
;YW5kbGVJdGVtc1tpXTsKICAgICAgY29uc3Qgcm93ID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnZGl2Jyk7CiAgICAgIGNvbnN0IGtleSA9IGhhbmRsZVJv
;d0tleShpdCwgaSk7CiAgICAgIGtlZXAuYWRkKGtleSk7CiAgICAgIHJvdy5jbGFzc05hbWUgPSAnaGFuZGxlLXJvdyBoYW5kbGUtY29scycgKyAocG9ydE1v
;ZGUgPyAnIHBvcnQtbW9kZScgOiAnJykgKyAoaGFuZGxlU2VsS2V5cy5oYXMoa2V5KSA/ICcgb24nIDogJycpOwogICAgICByb3cuc2V0QXR0cmlidXRlKCdk
;YXRhLWtleScsIGtleSk7CiAgICAgIHJvdy5zZXRBdHRyaWJ1dGUoJ2RhdGEtcGlkJywgU3RyaW5nKE51bWJlcihpdC5waWQpIHx8IDApKTsKICAgICAgcm93
;LnNldEF0dHJpYnV0ZSgnZGF0YS1uYW1lJywgU3RyaW5nKGl0Lm5hbWUgfHwgJycpKTsKICAgICAgcm93LnNldEF0dHJpYnV0ZSgnZGF0YS1wYXRoJywgU3Ry
;aW5nKGl0LnBhdGggfHwgJycpKTsKICAgICAgY29uc3QgbmFtZSA9IFN0cmluZyhpdC5uYW1lIHx8ICcnKTsKICAgICAgY29uc3QgcGlkTnVtID0gTnVtYmVy
;KGl0LnBpZCk7CiAgICAgIGNvbnN0IHBpZCA9IE51bWJlci5pc0Zpbml0ZShwaWROdW0pICYmIHBpZE51bSA+IDAgPyBTdHJpbmcocGlkTnVtKSA6ICcnOwog
;ICAgICBjb25zdCB0eXAgPSBTdHJpbmcoaXQudHlwZSB8fCAnJyk7CiAgICAgIGNvbnN0IGhuYW1lID0gU3RyaW5nKGl0LmhhbmRsZSB8fCAnJyk7CiAgICAg
;IGNvbnN0IGxwb3J0ID0gKGl0LmxvY2FsUG9ydCA9PSBudWxsIHx8IE51bWJlcihpdC5sb2NhbFBvcnQpIDwgMCkgPyAnJyA6IFN0cmluZyhpdC5sb2NhbFBv
;cnQpOwogICAgICBjb25zdCBycG9ydE51bSA9IE51bWJlcihpdC5yZW1vdGVQb3J0KTsKICAgICAgY29uc3QgcnBvcnQgPSBOdW1iZXIuaXNGaW5pdGUocnBv
;cnROdW0pICYmIHJwb3J0TnVtID4gMCA/IFN0cmluZyhycG9ydE51bSkgOiAocG9ydE1vZGUgPyAn4oCUJyA6ICcnKTsKICAgICAgY29uc3QgdGlwID0gcG9y
;dE1vZGUgPyBwb3J0VGlwVGV4dChpdCkgOiAoaXQucGF0aCB8fCBuYW1lKTsKICAgICAgY29uc3QgbEhvdCA9IHBvcnRNb2RlICYmIGxwb3J0ICE9PSAnJyAm
;JiBwb3J0SXNIb3QobHBvcnQpID8gJyBwb3J0LWhvdCcgOiAnJzsKICAgICAgY29uc3QgckhvdCA9IHBvcnRNb2RlICYmIHJwb3J0ICE9PSAn4oCUJyAmJiBy
;cG9ydCAhPT0gJycgJiYgcG9ydElzSG90KHJwb3J0KSA/ICcgcG9ydC1ob3QnIDogJyc7CiAgICAgIGNvbnN0IGNvbm5lY3RlZCA9IHBvcnRNb2RlICYmICho
;bmFtZSA9PT0gJ+i/nuaOpScgfHwgL2VzdGFibGlzaGVkL2kudGVzdChobmFtZSkpOwogICAgICBjb25zdCBuZXREb3QgPSBjb25uZWN0ZWQgPyAnPHNwYW4g
;Y2xhc3M9ImhhbmRsZS1uZXQtZG90IiB0aXRsZT0i5bey6L+e5o6lIj48L3NwYW4+JyA6ICcnOwogICAgICBjb25zdCBpY28gPSBpdC5pY29uCiAgICAgICAg
;PyAnPGltZyBzcmM9IicgKyBlc2NhcGVIdG1sKFN0cmluZyhpdC5pY29uKSkgKyAnIiBhbHQ9IiIgb25lcnJvcj0idGhpcy5vbmVycm9yPW51bGw7dGhpcy5y
;ZXBsYWNlV2l0aChPYmplY3QuYXNzaWduKGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoXCdzcGFuXCcpLHtjbGFzc05hbWU6XCdoYW5kbGUtaWNvLXBoXCd9KSki
;PicKICAgICAgICA6ICc8c3BhbiBjbGFzcz0iaGFuZGxlLWljby1waCIgYXJpYS1oaWRkZW49InRydWUiPjwvc3Bhbj4nOwogICAgICByb3cuaW5uZXJIVE1M
;ID0KICAgICAgICAnPGRpdiBjbGFzcz0iaGFuZGxlLW5hbWUiIHRpdGxlPSInICsgZXNjYXBlSHRtbChpdC5wYXRoIHx8IG5hbWUpICsgJyI+JyArIGljbyAr
;ICc8c3Bhbj4nICsgZXNjYXBlSHRtbChuYW1lKSArICc8L3NwYW4+PC9kaXY+JwogICAgICAgICsgJzxkaXY+JyArIGVzY2FwZUh0bWwocGlkKSArICc8L2Rp
;dj4nCiAgICAgICAgKyAocG9ydE1vZGUKICAgICAgICAgID8gKCc8ZGl2IGNsYXNzPSJoYW5kbGUtY29sLXBvcnQnICsgbEhvdCArICciIHRpdGxlPSInICsg
;ZXNjYXBlSHRtbCh0aXApICsgJyI+JyArIGVzY2FwZUh0bWwobHBvcnQpICsgJzwvZGl2PicKICAgICAgICAgICAgKyAnPGRpdiBjbGFzcz0iaGFuZGxlLWNv
;bC1ycG9ydCcgKyBySG90ICsgJyIgdGl0bGU9IicgKyBlc2NhcGVIdG1sKHRpcCkgKyAnIj4nICsgZXNjYXBlSHRtbChycG9ydCkgKyAnPC9kaXY+JykKICAg
;ICAgICAgIDogJycpCiAgICAgICAgKyAnPGRpdj4nICsgZXNjYXBlSHRtbCh0eXApICsgJzwvZGl2PicKICAgICAgICArICc8ZGl2IGNsYXNzPSJoYW5kbGUt
;c3RhdGUiIHRpdGxlPSInICsgZXNjYXBlSHRtbChwb3J0TW9kZSA/IHRpcCA6IGhuYW1lKSArICciPicgKyBuZXREb3QgKyAnPHNwYW4+JyArIGVzY2FwZUh0
;bWwoaG5hbWUpICsgJzwvc3Bhbj48L2Rpdj4nOwogICAgICBpZiAocG9ydE1vZGUpIHJvdy50aXRsZSA9IHRpcDsKICAgICAgcm93Lm9uY2xpY2sgPSAoZSkg
;PT4gc2VsZWN0SGFuZGxlRnJvbUV2ZW50KGUsIHJvdyk7CiAgICAgIHJvdy5vbmNvbnRleHRtZW51ID0gKGUpID0+IHsKICAgICAgICBlLnByZXZlbnREZWZh
;dWx0KCk7CiAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICBjb25zdCBrID0gcm93LmdldEF0dHJpYnV0ZSgnZGF0YS1rZXknKTsKICAgICAg
;ICBpZiAoIWhhbmRsZVNlbEtleXMuaGFzKGspKSB7CiAgICAgICAgICBoYW5kbGVTZWxLZXlzLmNsZWFyKCk7CiAgICAgICAgICBoYW5kbGVTZWxLZXlzLmFk
;ZChrKTsKICAgICAgICAgIGhhbmRsZUFuY2hvcktleSA9IGs7CiAgICAgICAgICByZWZyZXNoSGFuZGxlU2VsZWN0aW9uVUkoKTsKICAgICAgICB9CiAgICAg
;ICAgc2hvd1Byb2NNZW51KGUuY2xpZW50WCwgZS5jbGllbnRZLCBjb2xsZWN0SGFuZGxlVGFyZ2V0cygpKTsKICAgICAgfTsKICAgICAgcm93Lm9uZGJsY2xp
;Y2sgPSAoKSA9PiB7CiAgICAgICAgY29uc3QgdCA9IHBvcnRNb2RlID8gdGlwIDogKGhuYW1lIHx8IG5hbWUpOwogICAgICAgIHRyeSB7IG5hdmlnYXRvci5j
;bGlwYm9hcmQud3JpdGVUZXh0KHQpOyB9IGNhdGNoIChfKSB7IHBvc3QoJ2NvcHlUZXh0fCcgKyB0KTsgfQogICAgICB9OwogICAgICBmcmFnLmFwcGVuZENo
;aWxkKHJvdyk7CiAgICB9CiAgICBmb3IgKGNvbnN0IGsgb2YgQXJyYXkuZnJvbShoYW5kbGVTZWxLZXlzKSkgewogICAgICBpZiAoIWtlZXAuaGFzKGspKSBo
;YW5kbGVTZWxLZXlzLmRlbGV0ZShrKTsKICAgIH0KICAgIGhhbmRsZUJvZHkuaW5uZXJIVE1MID0gJyc7CiAgICBoYW5kbGVCb2R5LmFwcGVuZENoaWxkKGZy
;YWcpOwogIH0KICBmdW5jdGlvbiBzeW5jSGFuZGxlQmFyKG4pIHsKICAgIGlmIChhcHBNb2RlID09PSAnaGFuZGxlJykKICAgICAgY291bnRFbC50ZXh0Q29u
;dGVudCA9ICflhbEgJyArIChOdW1iZXIobikgfHwgMCkgKyAnIOadoSc7CiAgfQogIGZ1bmN0aW9uIGhhbmRsZVJvd0tleShpdCwgaWR4KSB7CiAgICByZXR1
;cm4gW2l0LnBpZCwgaXQudHlwZSwgaXQuaGFuZGxlLCBpdC5sb2NhbFBvcnQsIGl0LnJlbW90ZVBvcnQsIGlkeF0uam9pbignfCcpOwogIH0KICBmdW5jdGlv
;biByZWZyZXNoSGFuZGxlU2VsZWN0aW9uVUkoKSB7CiAgICBoYW5kbGVCb2R5LnF1ZXJ5U2VsZWN0b3JBbGwoJy5oYW5kbGUtcm93JykuZm9yRWFjaChyb3cg
;PT4gewogICAgICByb3cuY2xhc3NMaXN0LnRvZ2dsZSgnb24nLCBoYW5kbGVTZWxLZXlzLmhhcyhyb3cuZ2V0QXR0cmlidXRlKCdkYXRhLWtleScpKSk7CiAg
;ICB9KTsKICB9CiAgZnVuY3Rpb24gc2VsZWN0SGFuZGxlRnJvbUV2ZW50KGUsIHJvdykgewogICAgY29uc3Qga2V5ID0gcm93LmdldEF0dHJpYnV0ZSgnZGF0
;YS1rZXknKTsKICAgIGNvbnN0IHJvd3MgPSBBcnJheS5mcm9tKGhhbmRsZUJvZHkucXVlcnlTZWxlY3RvckFsbCgnLmhhbmRsZS1yb3cnKSk7CiAgICBjb25z
;dCBpZHggPSByb3dzLmluZGV4T2Yocm93KTsKICAgIGlmIChlLnNoaWZ0S2V5ICYmIGhhbmRsZUFuY2hvcktleSkgewogICAgICBjb25zdCBhSWR4ID0gcm93
;cy5maW5kSW5kZXgociA9PiByLmdldEF0dHJpYnV0ZSgnZGF0YS1rZXknKSA9PT0gaGFuZGxlQW5jaG9yS2V5KTsKICAgICAgaWYgKGFJZHggPj0gMCAmJiBp
;ZHggPj0gMCkgewogICAgICAgIGlmICghZS5jdHJsS2V5KSBoYW5kbGVTZWxLZXlzLmNsZWFyKCk7CiAgICAgICAgY29uc3QgbG8gPSBNYXRoLm1pbihhSWR4
;LCBpZHgpLCBoaSA9IE1hdGgubWF4KGFJZHgsIGlkeCk7CiAgICAgICAgZm9yIChsZXQgaSA9IGxvOyBpIDw9IGhpOyBpKyspIGhhbmRsZVNlbEtleXMuYWRk
;KHJvd3NbaV0uZ2V0QXR0cmlidXRlKCdkYXRhLWtleScpKTsKICAgICAgfQogICAgfSBlbHNlIGlmIChlLmN0cmxLZXkpIHsKICAgICAgaWYgKGhhbmRsZVNl
;bEtleXMuaGFzKGtleSkpIGhhbmRsZVNlbEtleXMuZGVsZXRlKGtleSk7CiAgICAgIGVsc2UgaGFuZGxlU2VsS2V5cy5hZGQoa2V5KTsKICAgICAgaGFuZGxl
;QW5jaG9yS2V5ID0ga2V5OwogICAgfSBlbHNlIHsKICAgICAgaGFuZGxlU2VsS2V5cy5jbGVhcigpOwogICAgICBoYW5kbGVTZWxLZXlzLmFkZChrZXkpOwog
;ICAgICBoYW5kbGVBbmNob3JLZXkgPSBrZXk7CiAgICB9CiAgICByZWZyZXNoSGFuZGxlU2VsZWN0aW9uVUkoKTsKICB9CiAgZnVuY3Rpb24gY29sbGVjdEhh
;bmRsZVRhcmdldHMoKSB7CiAgICBjb25zdCBtYXAgPSBuZXcgTWFwKCk7CiAgICBoYW5kbGVCb2R5LnF1ZXJ5U2VsZWN0b3JBbGwoJy5oYW5kbGUtcm93Jyku
;Zm9yRWFjaChyb3cgPT4gewogICAgICBpZiAoIWhhbmRsZVNlbEtleXMuaGFzKHJvdy5nZXRBdHRyaWJ1dGUoJ2RhdGEta2V5JykpKSByZXR1cm47CiAgICAg
;IGNvbnN0IHBpZCA9IE51bWJlcihyb3cuZ2V0QXR0cmlidXRlKCdkYXRhLXBpZCcpKSB8fCAwOwogICAgICBpZiAocGlkIDw9IDAgfHwgbWFwLmhhcyhwaWQp
;KSByZXR1cm47CiAgICAgIG1hcC5zZXQocGlkLCB7CiAgICAgICAgcGlkLAogICAgICAgIG5hbWU6IHJvdy5nZXRBdHRyaWJ1dGUoJ2RhdGEtbmFtZScpIHx8
;ICcnLAogICAgICAgIHBhdGg6IHJvdy5nZXRBdHRyaWJ1dGUoJ2RhdGEtcGF0aCcpIHx8ICcnCiAgICAgIH0pOwogICAgfSk7CiAgICByZXR1cm4gQXJyYXku
;ZnJvbShtYXAudmFsdWVzKCkpOwogIH0KICB3aW5kb3cuX19vbkhvc3RIaWRlID0gKCkgPT4geyBwb3N0KCdwcm9jVmlld3wwJyk7IH07CiAgd2luZG93Ll9f
;b25Ib3N0U2hvdyA9ICgpID0+IHsKICAgIHRyeSB7IGlmICh3aW5kb3cuX19yZXN5bmNTZWFyY2gpIHdpbmRvdy5fX3Jlc3luY1NlYXJjaCgpOyB9IGNhdGNo
;IChfKSB7fQogIH07CiAgZG9jdW1lbnQuYWRkRXZlbnRMaXN0ZW5lcigndmlzaWJpbGl0eWNoYW5nZScsICgpID0+IHsKICAgIGlmIChkb2N1bWVudC5oaWRk
;ZW4pIHBvc3QoJ3Byb2NWaWV3fDAnKTsKICB9KTsKCiAgaWYgKGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdidG4taW5mby1yZWZyZXNoJykpCiAgICBkb2N1
;bWVudC5nZXRFbGVtZW50QnlJZCgnYnRuLWluZm8tcmVmcmVzaCcpLm9uY2xpY2sgPSAoKSA9PiByZXF1ZXN0U3lzSW5mbyh0cnVlKTsKICBpZiAoZG9jdW1l
;bnQuZ2V0RWxlbWVudEJ5SWQoJ2J0bi1pbmZvLWNvcHknKSkKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdidG4taW5mby1jb3B5Jykub25jbGljayA9
;ICgpID0+IHsKICAgICAgY29uc3QgdCA9IGluZm9UZXh0IHx8IChpbmZvUGFuZWwgJiYgaW5mb1BhbmVsLmlubmVyVGV4dCkgfHwgJyc7CiAgICAgIHRyeSB7
;IG5hdmlnYXRvci5jbGlwYm9hcmQud3JpdGVUZXh0KHQpOyB9IGNhdGNoIChfKSB7IHBvc3QoJ2NvcHlUZXh0fCcgKyB0KTsgfQogICAgfTsKICBpZiAoYnRu
;UG9ydE1hcmspIHsKICAgIGJ0blBvcnRNYXJrLm9uY2xpY2sgPSAoZSkgPT4gewogICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgICBpZiAocG9ydE1h
;cmtQb3AgJiYgcG9ydE1hcmtQb3AuY2xhc3NMaXN0LmNvbnRhaW5zKCdvbicpKSBjbG9zZVBvcnRNYXJrUG9wKCk7CiAgICAgIGVsc2Ugb3BlblBvcnRNYXJr
;UG9wKCk7CiAgICB9OwogIH0KICBpZiAocG9ydE1hcmtQb3ApIHBvcnRNYXJrUG9wLmFkZEV2ZW50TGlzdGVuZXIoJ2NsaWNrJywgZSA9PiBlLnN0b3BQcm9w
;YWdhdGlvbigpKTsKICBjb25zdCBidG5Qb3J0TWFya0FkZCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdwb3J0LW1hcmstYWRkJyk7CiAgY29uc3QgYnRu
;UG9ydE1hcmtSZXNldCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdwb3J0LW1hcmstcmVzZXQnKTsKICBpZiAoYnRuUG9ydE1hcmtBZGQpIHsKICAgIGJ0
;blBvcnRNYXJrQWRkLm9uY2xpY2sgPSAoZSkgPT4gewogICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgICBpZiAoYWRkTWFya2VkUG9ydChwb3J0TWFy
;a0lucHV0ICYmIHBvcnRNYXJrSW5wdXQudmFsdWUpKSB7CiAgICAgICAgaWYgKHBvcnRNYXJrSW5wdXQpIHBvcnRNYXJrSW5wdXQudmFsdWUgPSAnJzsKICAg
;ICAgfQogICAgfTsKICB9CiAgaWYgKHBvcnRNYXJrSW5wdXQpIHsKICAgIHBvcnRNYXJrSW5wdXQuYWRkRXZlbnRMaXN0ZW5lcigna2V5ZG93bicsIGUgPT4g
;ewogICAgICBpZiAoZS5rZXkgPT09ICdFbnRlcicpIHsKICAgICAgICBlLnByZXZlbnREZWZhdWx0KCk7CiAgICAgICAgaWYgKGFkZE1hcmtlZFBvcnQocG9y
;dE1hcmtJbnB1dC52YWx1ZSkpIHBvcnRNYXJrSW5wdXQudmFsdWUgPSAnJzsKICAgICAgfQogICAgfSk7CiAgfQogIGlmIChidG5Qb3J0TWFya1Jlc2V0KSB7
;CiAgICBidG5Qb3J0TWFya1Jlc2V0Lm9uY2xpY2sgPSAoZSkgPT4gewogICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgICBtYXJrZWRQb3J0cyA9IERF
;RkFVTFRfTUFSS0VEX1BPUlRTLnNsaWNlKCk7CiAgICAgIHNhdmVNYXJrZWRQb3J0cygpOwogICAgICByZW5kZXJNYXJrZWRQb3J0VGFncygpOwogICAgICBp
;ZiAoYXBwTW9kZSA9PT0gJ2hhbmRsZScgJiYgaGFuZGxlTW9kZSA9PT0gJ3BvcnQnKSByZW5kZXJIYW5kbGVUYWJsZSgpOwogICAgfTsKICB9CiAgZG9jdW1l
;bnQuYWRkRXZlbnRMaXN0ZW5lcignY2xpY2snLCAoKSA9PiBjbG9zZVBvcnRNYXJrUG9wKCkpOwogIHJlbmRlck1hcmtlZFBvcnRUYWdzKCk7CiAgcmVuZGVy
;SGFuZGxlSGlzdCgpOwogIC8vIOS4u+aQnOe0ouahhue7n+S4gOaQnOe0ou+8m+WPpeafhOWOhuWPsui1sCDilr4g5LiL5ouJ77yI5LiO5paH5Lu25pCc57Si
;5LiA6Ie077yJCiAgdHJ5IHsgcUVsLnJlbW92ZUF0dHJpYnV0ZSgnbGlzdCcpOyB9IGNhdGNoIChfKSB7fQoKICBmdW5jdGlvbiBoaWRlUHJvY01lbnUoKSB7
;CiAgICBwcm9jTWVudS5jbGFzc0xpc3QucmVtb3ZlKCdvbicpOwogICAgcHJvY01lbnVUYXJnZXRzID0gW107CiAgfQogIGZ1bmN0aW9uIHNob3dQcm9jTWVu
;dSh4LCB5LCB0YXJnZXRzKSB7CiAgICBwcm9jTWVudVRhcmdldHMgPSBBcnJheS5pc0FycmF5KHRhcmdldHMpID8gdGFyZ2V0cy5maWx0ZXIodCA9PiB0ICYm
;IE51bWJlcih0LnBpZCkgPiAwKSA6IFtdOwogICAgY29uc3QgbiA9IHByb2NNZW51VGFyZ2V0cy5sZW5ndGg7CiAgICBjb25zdCBmaXJzdCA9IG4gPyBwcm9j
;TWVudVRhcmdldHNbMF0gOiBudWxsOwogICAgY29uc3QgbmFtZSA9IGZpcnN0ID8gU3RyaW5nKGZpcnN0Lm5hbWUgfHwgJycpLnRyaW0oKSA6ICcnOwogICAg
;Y29uc3QgcGlkID0gZmlyc3QgPyBTdHJpbmcoTnVtYmVyKGZpcnN0LnBpZCkgfHwgJycpIDogJyc7CiAgICBjb25zdCBjb3B5TGJsID0gZG9jdW1lbnQuZ2V0
;RWxlbWVudEJ5SWQoJ3Byb2MtbWVudS1jb3B5Jyk7CiAgICBjb25zdCBwaWRMYmwgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgncHJvYy1tZW51LWNvcHlw
;aWQnKTsKICAgIGNvbnN0IGVuZExibCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdwcm9jLW1lbnUtZW5kLWxhYmVsJyk7CiAgICBpZiAoY29weUxibCkg
;ewogICAgICBpZiAobmFtZSAmJiBuID09PSAxKSBjb3B5TGJsLnRleHRDb250ZW50ID0gJ+WkjeWItui/m+eoi+WQjSAoICcgKyBuYW1lICsgJyApJzsKICAg
;ICAgZWxzZSBpZiAobmFtZSAmJiBuID4gMSkgY29weUxibC50ZXh0Q29udGVudCA9ICflpI3liLbov5vnqIvlkI0gKCAnICsgbmFtZSArICcg562JJyArIG4g
;KyAn5LiqICknOwogICAgICBlbHNlIGNvcHlMYmwudGV4dENvbnRlbnQgPSAn5aSN5Yi26L+b56iL5ZCNJzsKICAgIH0KICAgIGlmIChwaWRMYmwpIHsKICAg
;ICAgaWYgKHBpZCAmJiBuID09PSAxKSBwaWRMYmwudGV4dENvbnRlbnQgPSAn5aSN5Yi26L+b56iL5Y+3ICggJyArIHBpZCArICcgKSc7CiAgICAgIGVsc2Ug
;aWYgKHBpZCAmJiBuID4gMSkgcGlkTGJsLnRleHRDb250ZW50ID0gJ+WkjeWItui/m+eoi+WPtyAoICcgKyBwaWQgKyAnIOetiScgKyBuICsgJ+S4qiApJzsK
;ICAgICAgZWxzZSBwaWRMYmwudGV4dENvbnRlbnQgPSAn5aSN5Yi26L+b56iL5Y+3JzsKICAgIH0KICAgIGlmIChlbmRMYmwpIGVuZExibC50ZXh0Q29udGVu
;dCA9ICflhbPpl63ov5vnqIsgKCAnICsgTWF0aC5tYXgobiwgMCkgKyAnICknOwogICAgY29uc3QgaGFzUGF0aCA9IHByb2NNZW51VGFyZ2V0cy5zb21lKHQg
;PT4gdC5wYXRoKTsKICAgIHByb2NNZW51LnF1ZXJ5U2VsZWN0b3JBbGwoJ2J1dHRvbltkYXRhLXBhY3RdJykuZm9yRWFjaChidG4gPT4gewogICAgICBjb25z
;dCBhY3QgPSBidG4uZ2V0QXR0cmlidXRlKCdkYXRhLXBhY3QnKTsKICAgICAgaWYgKGFjdCA9PT0gJ3JldmVhbCcpIGJ0bi5kaXNhYmxlZCA9ICFoYXNQYXRo
;OwogICAgICBlbHNlIGJ0bi5kaXNhYmxlZCA9IG4gPCAxOwogICAgfSk7CiAgICBwcm9jTWVudS5jbGFzc0xpc3QuYWRkKCdvbicpOwogICAgcHJvY01lbnUu
;c3R5bGUubGVmdCA9ICcwcHgnOwogICAgcHJvY01lbnUuc3R5bGUudG9wID0gJzBweCc7CiAgICBjb25zdCByZWN0ID0gcHJvY01lbnUuZ2V0Qm91bmRpbmdD
;bGllbnRSZWN0KCk7CiAgICBsZXQgbGVmdCA9IHgsIHRvcCA9IHk7CiAgICBpZiAobGVmdCArIHJlY3Qud2lkdGggPiBpbm5lcldpZHRoIC0gNikgbGVmdCA9
;IE1hdGgubWF4KDYsIGlubmVyV2lkdGggLSByZWN0LndpZHRoIC0gNik7CiAgICBpZiAodG9wICsgcmVjdC5oZWlnaHQgPiBpbm5lckhlaWdodCAtIDYpIHRv
;cCA9IE1hdGgubWF4KDYsIGlubmVySGVpZ2h0IC0gcmVjdC5oZWlnaHQgLSA2KTsKICAgIHByb2NNZW51LnN0eWxlLmxlZnQgPSBsZWZ0ICsgJ3B4JzsKICAg
;IHByb2NNZW51LnN0eWxlLnRvcCA9IHRvcCArICdweCc7CiAgfQogIGZ1bmN0aW9uIGNvcHlUZXh0U2FmZSh0ZXh0KSB7CiAgICB0ZXh0ID0gU3RyaW5nKHRl
;eHQgfHwgJycpOwogICAgaWYgKCF0ZXh0KSByZXR1cm47CiAgICB0cnkgeyBuYXZpZ2F0b3IuY2xpcGJvYXJkLndyaXRlVGV4dCh0ZXh0KTsgfSBjYXRjaCAo
;XykgeyBwb3N0KCdjb3B5VGV4dHwnICsgdGV4dCk7IH0KICB9CiAgcHJvY01lbnUucXVlcnlTZWxlY3RvckFsbCgnYnV0dG9uW2RhdGEtcGFjdF0nKS5mb3JF
;YWNoKGJ0biA9PiB7CiAgICBidG4ub25jbGljayA9IChlKSA9PiB7CiAgICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAgIGNvbnN0IGFjdCA9IGJ0bi5n
;ZXRBdHRyaWJ1dGUoJ2RhdGEtcGFjdCcpOwogICAgICBjb25zdCB0YXJnZXRzID0gcHJvY01lbnVUYXJnZXRzLnNsaWNlKCk7CiAgICAgIGhpZGVQcm9jTWVu
;dSgpOwogICAgICBpZiAoIXRhcmdldHMubGVuZ3RoKSByZXR1cm47CiAgICAgIGlmIChhY3QgPT09ICdlbmQnKSB7CiAgICAgICAgY29uc3QgcGlkcyA9IHRh
;cmdldHMubWFwKHQgPT4gTnVtYmVyKHQucGlkKSB8fCAwKS5maWx0ZXIocGlkID0+IHBpZCA+IDApOwogICAgICAgIGlmIChwaWRzLmxlbmd0aCkgewogICAg
;ICAgICAgLy8g5YWI5LuO55WM6Z2i56e76Zmk77yM5Li75py656Gu6K6k5ZCO5Lya5YaN5ZCM5q2l5LiA5qyhCiAgICAgICAgICByZW1vdmVSb3dzQnlQaWRz
;KHBpZHMpOwogICAgICAgICAgcG9zdCgncHJvY0tpbGx8JyArIHBpZHMuam9pbignLCcpKTsKICAgICAgICB9CiAgICAgIH0gZWxzZSBpZiAoYWN0ID09PSAn
;cmV2ZWFsJykgewogICAgICAgIGNvbnN0IHNlZW4gPSBuZXcgU2V0KCk7CiAgICAgICAgZm9yIChjb25zdCB0IG9mIHRhcmdldHMpIHsKICAgICAgICAgIGNv
;bnN0IHAgPSBTdHJpbmcodC5wYXRoIHx8ICcnKTsKICAgICAgICAgIGlmICghcCB8fCBzZWVuLmhhcyhwLnRvTG93ZXJDYXNlKCkpKSBjb250aW51ZTsKICAg
;ICAgICAgIHNlZW4uYWRkKHAudG9Mb3dlckNhc2UoKSk7CiAgICAgICAgICBjYWxsSG9zdCgncmV2ZWFsJywgcCk7CiAgICAgICAgfQogICAgICB9IGVsc2Ug
;aWYgKGFjdCA9PT0gJ2NvcHknKSB7CiAgICAgICAgY29uc3QgbmFtZXMgPSBbXTsKICAgICAgICBjb25zdCBzZWVuID0gbmV3IFNldCgpOwogICAgICAgIGZv
;ciAoY29uc3QgdCBvZiB0YXJnZXRzKSB7CiAgICAgICAgICBsZXQgbiA9IFN0cmluZyh0Lm5hbWUgfHwgJycpLnRyaW0oKTsKICAgICAgICAgIGlmICghbiAm
;JiB0LnBhdGgpIHsKICAgICAgICAgICAgY29uc3QgcCA9IFN0cmluZyh0LnBhdGgpLnJlcGxhY2UoL1tcXC9dKyQvLCAnJyk7CiAgICAgICAgICAgIGNvbnN0
;IGkgPSBNYXRoLm1heChwLmxhc3RJbmRleE9mKCdcXCcpLCBwLmxhc3RJbmRleE9mKCcvJykpOwogICAgICAgICAgICBuID0gaSA+PSAwID8gcC5zbGljZShp
;ICsgMSkgOiBwOwogICAgICAgICAgfQogICAgICAgICAgaWYgKCFuIHx8IHNlZW4uaGFzKG4udG9Mb3dlckNhc2UoKSkpIGNvbnRpbnVlOwogICAgICAgICAg
;c2Vlbi5hZGQobi50b0xvd2VyQ2FzZSgpKTsKICAgICAgICAgIG5hbWVzLnB1c2gobik7CiAgICAgICAgfQogICAgICAgIGNvcHlUZXh0U2FmZShuYW1lcy5q
;b2luKCdcbicpKTsKICAgICAgfSBlbHNlIGlmIChhY3QgPT09ICdjb3B5UGlkJykgewogICAgICAgIGNvbnN0IHBpZHMgPSBbXTsKICAgICAgICBjb25zdCBz
;ZWVuID0gbmV3IFNldCgpOwogICAgICAgIGZvciAoY29uc3QgdCBvZiB0YXJnZXRzKSB7CiAgICAgICAgICBjb25zdCBwaWQgPSBOdW1iZXIodC5waWQpIHx8
;IDA7CiAgICAgICAgICBpZiAocGlkIDw9IDAgfHwgc2Vlbi5oYXMocGlkKSkgY29udGludWU7CiAgICAgICAgICBzZWVuLmFkZChwaWQpOwogICAgICAgICAg
;cGlkcy5wdXNoKFN0cmluZyhwaWQpKTsKICAgICAgICB9CiAgICAgICAgY29weVRleHRTYWZlKHBpZHMuam9pbignXG4nKSk7CiAgICAgIH0KICAgIH07CiAg
;fSk7CiAgZG9jdW1lbnQuYWRkRXZlbnRMaXN0ZW5lcignY2xpY2snLCAoKSA9PiBoaWRlUHJvY01lbnUoKSk7CiAgZG9jdW1lbnQuYWRkRXZlbnRMaXN0ZW5l
;cigna2V5ZG93bicsIChlKSA9PiB7CiAgICBpZiAoZS5rZXkgPT09ICdFc2NhcGUnKSB7CiAgICAgIGhpZGVQcm9jTWVudSgpOwogICAgICBjbG9zZVBvcnRN
;YXJrUG9wKCk7CiAgICB9CiAgfSk7CgogIGZ1bmN0aW9uIHByb2NSb3dLZXkocCkgewogICAgcmV0dXJuIFtwLnByb3RvLCBwLmxvY2FsSXAsIHAubG9jYWxQ
;b3J0LCBwLnJlbW90ZUlwLCBwLnJlbW90ZVBvcnQsIHAucGlkXS5qb2luKCd8Jyk7CiAgfQogIGZ1bmN0aW9uIHBvcnRzQ29udGVudFNpZyhpdGVtcykgewog
;ICAgcmV0dXJuIChpdGVtcyB8fCBbXSkubWFwKHAgPT4KICAgICAgcHJvY1Jvd0tleShwKSArICdcdCcgKyAocC5wcm9jIHx8ICcnKSArICdcdCcgKyAocC5z
;dGF0ZSB8fCAnJykgKyAnXHQnICsgKHAucGF0aCB8fCAnJykKICAgICAgICArICdcdCcgKyAocC5wcGlkIHx8ICcnKSArICdcdCcgKyAocC5jcHUgfHwgJycp
;ICsgJ1x0JyArIChwLm1lbSB8fCAnJykKICAgICkuam9pbignXG4nKTsKICB9CiAgZnVuY3Rpb24gcG9ydENlbGxUZXh0KHBvcnQpIHsKICAgIGlmIChwb3J0
;ID09PSAnJyB8fCBwb3J0ID09IG51bGwgfHwgTnVtYmVyKHBvcnQpIDwgMCkgcmV0dXJuICcnOwogICAgcmV0dXJuIFN0cmluZyhwb3J0KTsKICB9CiAgZnVu
;Y3Rpb24gcHJvY0ljb25TdGFibGVLZXkocCkgewogICAgY29uc3QgcGF0aCA9IFN0cmluZygocCAmJiBwLnBhdGgpIHx8ICcnKTsKICAgIGlmIChwYXRoKSBy
;ZXR1cm4gJ3A6JyArIHBhdGgudG9Mb3dlckNhc2UoKTsKICAgIHJldHVybiAnaWQ6JyArIChOdW1iZXIocCAmJiBwLnBpZCkgfHwgMCk7CiAgfQogIGZ1bmN0
;aW9uIHNldFByb2NJY29uRWwobmFtZUJveCwgaWNvblVybCwgc3RhYmxlS2V5KSB7CiAgICBpZiAoIW5hbWVCb3gpIHJldHVybjsKICAgIGxldCBpbWcgPSBu
;YW1lQm94LnF1ZXJ5U2VsZWN0b3IoJ2ltZycpOwogICAgbGV0IHBoID0gbmFtZUJveC5xdWVyeVNlbGVjdG9yKCcucHJvYy1pY28tcGgnKTsKICAgIGNvbnN0
;IHVybCA9IFN0cmluZyhpY29uVXJsIHx8ICcnKTsKICAgIC8vIOW3suacieeos+WumuWbvuagh++8muepui/lkIwgc3JjIOmDveS4jeWKqO+8jOadnOe7nemX
;queDgQogICAgaWYgKGltZykgewogICAgICBjb25zdCBjdXIgPSBpbWcuZ2V0QXR0cmlidXRlKCdzcmMnKSB8fCAnJzsKICAgICAgaWYgKCF1cmwgfHwgdXJs
;ID09PSBjdXIpIHJldHVybjsKICAgICAgaW1nLnNldEF0dHJpYnV0ZSgnc3JjJywgdXJsKTsKICAgICAgaWYgKHN0YWJsZUtleSkgcHJvY0ljb25TdGFibGUu
;c2V0KHN0YWJsZUtleSwgdXJsKTsKICAgICAgcmV0dXJuOwogICAgfQogICAgaWYgKCF1cmwpIHsKICAgICAgaWYgKCFwaCkgewogICAgICAgIHBoID0gZG9j
;dW1lbnQuY3JlYXRlRWxlbWVudCgnc3BhbicpOwogICAgICAgIHBoLmNsYXNzTmFtZSA9ICdwcm9jLWljby1waCc7CiAgICAgICAgcGguc2V0QXR0cmlidXRl
;KCdhcmlhLWhpZGRlbicsICd0cnVlJyk7CiAgICAgICAgbmFtZUJveC5pbnNlcnRCZWZvcmUocGgsIG5hbWVCb3guZmlyc3RDaGlsZCk7CiAgICAgIH0KICAg
;ICAgcmV0dXJuOwogICAgfQogICAgaW1nID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnaW1nJyk7CiAgICBpbWcuYWx0ID0gJyc7CiAgICBpbWcuZGVjb2Rp
;bmcgPSAnYXN5bmMnOwogICAgaW1nLnNyYyA9IHVybDsKICAgIGltZy5vbmVycm9yID0gZnVuY3Rpb24gKCkgewogICAgICB0aGlzLm9uZXJyb3IgPSBudWxs
;OwogICAgICBjb25zdCBzID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnc3BhbicpOwogICAgICBzLmNsYXNzTmFtZSA9ICdwcm9jLWljby1waCc7CiAgICAg
;IHMuc2V0QXR0cmlidXRlKCdhcmlhLWhpZGRlbicsICd0cnVlJyk7CiAgICAgIHRoaXMucmVwbGFjZVdpdGgocyk7CiAgICB9OwogICAgaWYgKHBoKSBuYW1l
;Qm94LnJlcGxhY2VDaGlsZChpbWcsIHBoKTsKICAgIGVsc2UgbmFtZUJveC5pbnNlcnRCZWZvcmUoaW1nLCBuYW1lQm94LmZpcnN0Q2hpbGQpOwogICAgaWYg
;KHN0YWJsZUtleSkgcHJvY0ljb25TdGFibGUuc2V0KHN0YWJsZUtleSwgdXJsKTsKICB9CiAgZnVuY3Rpb24gZW5zdXJlUHJvY1JvdyhwKSB7CiAgICBjb25z
;dCByb3cgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsKICAgIHJvdy5jbGFzc05hbWUgPSAncHJvYy1yb3cgcHJvYy1jb2xzJzsKICAgIHJvdy5p
;bm5lckhUTUwgPQogICAgICAnPGRpdiBjbGFzcz0icHJvYy1jZWxsLW5hbWUiPjxkaXYgY2xhc3M9InByb2MtbmFtZSI+PHNwYW4gY2xhc3M9InByb2MtaWNv
;LXBoIiBhcmlhLWhpZGRlbj0idHJ1ZSI+PC9zcGFuPjxzcGFuIGNsYXNzPSJwcm9jLWxhYmVsIj48L3NwYW4+PC9kaXY+PC9kaXY+JwogICAgICArICc8ZGl2
;IGNsYXNzPSJwcm9jLW51bSBwcm9jLWNlbGwtY3B1IiBkYXRhLWY9ImNwdSI+PC9kaXY+JwogICAgICArICc8ZGl2IGNsYXNzPSJwcm9jLW51bSBwcm9jLWNl
;bGwtbWVtIiBkYXRhLWY9Im1lbSI+PC9kaXY+JwogICAgICArICc8ZGl2IGNsYXNzPSJwcm9jLW51bSBwcm9jLWNlbGwtcGlkIiBkYXRhLWY9InBpZCI+PC9k
;aXY+JwogICAgICArICc8ZGl2IGNsYXNzPSJwcm9jLW51bSBwcm9jLWNlbGwtcHJvdG8iIGRhdGEtZj0icHJvdG8iPjwvZGl2PicKICAgICAgKyAnPGRpdiBj
;bGFzcz0icHJvYy1udW0gcHJvYy1jZWxsLWlwIiBkYXRhLWY9ImxpcCI+PC9kaXY+JwogICAgICArICc8ZGl2IGNsYXNzPSJwcm9jLW51bSBwcm9jLWNlbGwt
;cG9ydCIgZGF0YS1mPSJscG9ydCI+PC9kaXY+JwogICAgICArICc8ZGl2IGNsYXNzPSJwcm9jLW51bSBwcm9jLWNlbGwtaXAiIGRhdGEtZj0icmlwIj48L2Rp
;dj4nCiAgICAgICsgJzxkaXYgY2xhc3M9InByb2MtbnVtIHByb2MtY2VsbC1wb3J0IiBkYXRhLWY9InJwb3J0Ij48L2Rpdj4nCiAgICAgICsgJzxkaXYgY2xh
;c3M9InByb2MtbnVtIHByb2MtY2VsbC1zdGF0ZSIgZGF0YS1mPSJzdGF0ZSI+PHNwYW4gY2xhc3M9InByb2MtbmV0LWRvdCBoaWRkZW4iIHRpdGxlPSLlt7Lo
;v57mjqUiPjwvc3Bhbj48c3BhbiBjbGFzcz0icHJvYy1zdGF0ZS10eHQiPjwvc3Bhbj48L2Rpdj4nOwogICAgcm93Lm9uY2xpY2sgPSAoZSkgPT4gc2VsZWN0
;UHJvY0Zyb21FdmVudChlLCByb3cpOwogICAgcm93Lm9uY29udGV4dG1lbnUgPSAoZSkgPT4gewogICAgICBlLnByZXZlbnREZWZhdWx0KCk7CiAgICAgIGUu
;c3RvcFByb3BhZ2F0aW9uKCk7CiAgICAgIGNvbnN0IGtleSA9IHJvdy5nZXRBdHRyaWJ1dGUoJ2RhdGEta2V5Jyk7CiAgICAgIGlmICghcHJvY1NlbEtleXMu
;aGFzKGtleSkpIHsKICAgICAgICBzZWxlY3RQcm9jTmFtZUdyb3VwKHJvdyk7CiAgICAgIH0KICAgICAgc2hvd1Byb2NNZW51KGUuY2xpZW50WCwgZS5jbGll
;bnRZLCBjb2xsZWN0UHJvY1RhcmdldHMoKSk7CiAgICB9OwogICAgcmV0dXJuIHJvdzsKICB9CiAgZnVuY3Rpb24gaGVhdENvbG9yKGhvdCkgewogICAgcmV0
;dXJuIGhvdCA/ICcjODhmZmMxJyA6ICcjY2VmZmU1JzsKICB9CiAgZnVuY3Rpb24gcGFyc2VQY3QocykgewogICAgY29uc3QgbSA9IFN0cmluZyhzIHx8ICcn
;KS5tYXRjaCgvKFtcZC5dKykvKTsKICAgIHJldHVybiBtID8gTnVtYmVyKG1bMV0pIDogMDsKICB9CiAgZnVuY3Rpb24gdXBkYXRlSGVhZEhlYXQoY3B1VG90
;YWwsIG1lbVRvdGFsKSB7CiAgICBjb25zdCBjcHVDZWxsID0gcHJvY0hlYWQgJiYgcHJvY0hlYWQucXVlcnlTZWxlY3RvcignLnByb2MtaGNlbGxbZGF0YS1z
;b3J0PSJjcHUiXScpOwogICAgY29uc3QgbWVtQ2VsbCA9IHByb2NIZWFkICYmIHByb2NIZWFkLnF1ZXJ5U2VsZWN0b3IoJy5wcm9jLWhjZWxsW2RhdGEtc29y
;dD0ibWVtIl0nKTsKICAgIGNvbnN0IGNwdVBjdCA9IHBhcnNlUGN0KGNwdVRvdGFsKTsKICAgIGNvbnN0IG1lbVBjdCA9IHBhcnNlUGN0KG1lbVRvdGFsKTsK
;ICAgIGlmIChjcHVDZWxsKSB7CiAgICAgIGNwdUNlbGwuY2xhc3NMaXN0LnRvZ2dsZSgnaG90JywgY3B1UGN0ID4gNSk7CiAgICAgIGNwdUNlbGwuc3R5bGUu
;YmFja2dyb3VuZCA9IGhlYXRDb2xvcihjcHVQY3QgPiA1KTsKICAgIH0KICAgIGlmIChtZW1DZWxsKSB7CiAgICAgIG1lbUNlbGwuY2xhc3NMaXN0LnRvZ2ds
;ZSgnaG90JywgbWVtUGN0ID4gODApOwogICAgICBtZW1DZWxsLnN0eWxlLmJhY2tncm91bmQgPSBoZWF0Q29sb3IobWVtUGN0ID4gODApOwogICAgfQogIH0K
;ICBmdW5jdGlvbiB1cGRhdGVQcm9jUm93RGF0YShyb3csIHApIHsKICAgIGNvbnN0IGtleSA9IHByb2NSb3dLZXkocCk7CiAgICByb3cuc2V0QXR0cmlidXRl
;KCdkYXRhLWtleScsIGtleSk7CiAgICByb3cuc2V0QXR0cmlidXRlKCdkYXRhLXBpZCcsIFN0cmluZyhwLnBpZCB8fCAwKSk7CiAgICByb3cuc2V0QXR0cmli
;dXRlKCdkYXRhLW5hbWUnLCBTdHJpbmcocC5wcm9jIHx8ICcnKSk7CiAgICByb3cuc2V0QXR0cmlidXRlKCdkYXRhLXBhdGgnLCBTdHJpbmcocC5wYXRoIHx8
;ICcnKSk7CiAgICBjb25zdCBuYW1lQm94ID0gcm93LnF1ZXJ5U2VsZWN0b3IoJy5wcm9jLW5hbWUnKTsKICAgIGNvbnN0IGxhYmVsID0gcm93LnF1ZXJ5U2Vs
;ZWN0b3IoJy5wcm9jLWxhYmVsJyk7CiAgICBjb25zdCBuYW1lID0gcC5wcm9jIHx8IChwLnBpZCA/ICgnUElEICcgKyBwLnBpZCkgOiAnJyk7CiAgICBpZiAo
;bGFiZWwgJiYgbGFiZWwudGV4dENvbnRlbnQgIT09IG5hbWUpIGxhYmVsLnRleHRDb250ZW50ID0gbmFtZTsKICAgIGlmIChsYWJlbCkgbGFiZWwudGl0bGUg
;PSBwLnBhdGggfHwgbmFtZTsKICAgIGNvbnN0IHNrID0gcHJvY0ljb25TdGFibGVLZXkocCk7CiAgICBsZXQgaWNvbiA9IFN0cmluZyhwLmljb24gfHwgJycp
;OwogICAgaWYgKCFpY29uICYmIHByb2NJY29uU3RhYmxlLmhhcyhzaykpCiAgICAgIGljb24gPSBwcm9jSWNvblN0YWJsZS5nZXQoc2spOwogICAgc2V0UHJv
;Y0ljb25FbChuYW1lQm94LCBpY29uLCBzayk7CiAgICBjb25zdCBzZXRUeHQgPSAoc2VsLCB2YWwsIHRpdGxlKSA9PiB7CiAgICAgIGNvbnN0IGVsID0gcm93
;LnF1ZXJ5U2VsZWN0b3Ioc2VsKTsKICAgICAgaWYgKCFlbCkgcmV0dXJuOwogICAgICBjb25zdCB0ID0gdmFsID09IG51bGwgPyAnJyA6IFN0cmluZyh2YWwp
;OwogICAgICBpZiAoZWwudGV4dENvbnRlbnQgIT09IHQpIGVsLnRleHRDb250ZW50ID0gdDsKICAgICAgaWYgKHRpdGxlICE9IG51bGwpIGVsLnRpdGxlID0g
;dGl0bGU7CiAgICB9OwogICAgc2V0VHh0KCdbZGF0YS1mPSJjcHUiXScsIHAuY3B1IHx8ICcwJScpOwogICAgc2V0VHh0KCdbZGF0YS1mPSJtZW0iXScsIHAu
;bWVtIHx8ICcnKTsKICAgIHNldFR4dCgnW2RhdGEtZj0icGlkIl0nLCBwLnBpZCB8fCAnJyk7CiAgICBzZXRUeHQoJ1tkYXRhLWY9InByb3RvIl0nLCBwLnBy
;b3RvIHx8ICcnKTsKICAgIHNldFR4dCgnW2RhdGEtZj0ibGlwIl0nLCBwLmxvY2FsSXAgfHwgJycsIHAubG9jYWxJcCB8fCAnJyk7CiAgICBjb25zdCBscG9y
;dCA9IHBvcnRDZWxsVGV4dChwLmxvY2FsUG9ydCk7CiAgICBzZXRUeHQoJ1tkYXRhLWY9Imxwb3J0Il0nLCBscG9ydCk7CiAgICBjb25zdCBscG9ydEVsID0g
;cm93LnF1ZXJ5U2VsZWN0b3IoJ1tkYXRhLWY9Imxwb3J0Il0nKTsKICAgIGlmIChscG9ydEVsKSBscG9ydEVsLmNsYXNzTGlzdC50b2dnbGUoJ3BvcnQtaG90
;JywgcG9ydElzSG90KHAubG9jYWxQb3J0KSAmJiBscG9ydCAhPT0gJycpOwogICAgc2V0VHh0KCdbZGF0YS1mPSJyaXAiXScsIHAucmVtb3RlSXAgfHwgJycs
;IHAucmVtb3RlSXAgfHwgJycpOwogICAgY29uc3QgcnBvcnQgPSBwb3J0Q2VsbFRleHQocC5yZW1vdGVQb3J0KTsKICAgIHNldFR4dCgnW2RhdGEtZj0icnBv
;cnQiXScsIHJwb3J0KTsKICAgIGNvbnN0IHJwb3J0RWwgPSByb3cucXVlcnlTZWxlY3RvcignW2RhdGEtZj0icnBvcnQiXScpOwogICAgaWYgKHJwb3J0RWwp
;IHJwb3J0RWwuY2xhc3NMaXN0LnRvZ2dsZSgncG9ydC1ob3QnLCBwb3J0SXNIb3QocC5yZW1vdGVQb3J0KSAmJiBycG9ydCAhPT0gJycpOwogICAgY29uc3Qg
;c3QgPSBTdHJpbmcocC5zdGF0ZSB8fCAnJyk7CiAgICBjb25zdCBzdGF0ZVR4dCA9IHJvdy5xdWVyeVNlbGVjdG9yKCcucHJvYy1zdGF0ZS10eHQnKTsKICAg
;IGlmIChzdGF0ZVR4dCkgewogICAgICBpZiAoc3RhdGVUeHQudGV4dENvbnRlbnQgIT09IHN0KSBzdGF0ZVR4dC50ZXh0Q29udGVudCA9IHN0OwogICAgfSBl
;bHNlIHsKICAgICAgc2V0VHh0KCdbZGF0YS1mPSJzdGF0ZSJdJywgc3QpOwogICAgfQogICAgY29uc3QgbmV0RG90ID0gcm93LnF1ZXJ5U2VsZWN0b3IoJy5w
;cm9jLW5ldC1kb3QnKTsKICAgIGlmIChuZXREb3QpIHsKICAgICAgY29uc3QgY29ubmVjdGVkID0gc3QgPT09ICfov57mjqUnIHx8IC9lc3RhYmxpc2hlZC9p
;LnRlc3Qoc3QpOwogICAgICBuZXREb3QuY2xhc3NMaXN0LnRvZ2dsZSgnaGlkZGVuJywgIWNvbm5lY3RlZCk7CiAgICB9CiAgICBjb25zdCBjcHVFbCA9IHJv
;dy5xdWVyeVNlbGVjdG9yKCdbZGF0YS1mPSJjcHUiXScpOwogICAgY29uc3QgbWVtRWwgPSByb3cucXVlcnlTZWxlY3RvcignW2RhdGEtZj0ibWVtIl0nKTsK
;ICAgIGNvbnN0IGNwdUhvdCA9IChOdW1iZXIocC5jcHVOKSB8fCAwKSA+IDE7CiAgICBjb25zdCBtZW1Ib3QgPSAoTnVtYmVyKHAubWVtTikgfHwgMCkgPiAo
;NTEyICogMTAyNCAqIDEwMjQpOwogICAgaWYgKGNwdUVsKSB7CiAgICAgIGNwdUVsLmNsYXNzTGlzdC50b2dnbGUoJ2hvdCcsIGNwdUhvdCk7CiAgICAgIGNw
;dUVsLnN0eWxlLmJhY2tncm91bmQgPSBoZWF0Q29sb3IoY3B1SG90KTsKICAgIH0KICAgIGlmIChtZW1FbCkgewogICAgICBtZW1FbC5jbGFzc0xpc3QudG9n
;Z2xlKCdob3QnLCBtZW1Ib3QpOwogICAgICBtZW1FbC5zdHlsZS5iYWNrZ3JvdW5kID0gaGVhdENvbG9yKG1lbUhvdCk7CiAgICB9CiAgfQogIC8vIOWtl+av
;jeaOkuW6j++8muWQjOWtl+avjSBhL0Eg5oyo5Zyo5LiA6LW377yM5LiUIGEg5ZyoIEEg5YmN77yIYeKApkHigKZi4oCmQuKApu+8iQogIGZ1bmN0aW9uIHBy
;b2NOYW1lU29ydFJhbmsoY2gpIHsKICAgIGNvbnN0IGMgPSBTdHJpbmcoY2ggfHwgJycpOwogICAgaWYgKCFjKSByZXR1cm4gMDsKICAgIGNvbnN0IGNvZGUg
;PSBjLmNoYXJDb2RlQXQoMCk7CiAgICBpZiAoY29kZSA+PSA2NSAmJiBjb2RlIDw9IDkwKSByZXR1cm4gKGNvZGUgLSA2NSkgKiAyICsgMTsKICAgIGlmIChj
;b2RlID49IDk3ICYmIGNvZGUgPD0gMTIyKSByZXR1cm4gKGNvZGUgLSA5NykgKiAyOwogICAgcmV0dXJuIDIwMDAgKyBjb2RlOwogIH0KICBmdW5jdGlvbiBj
;b21wYXJlUHJvY05hbWUoYSwgYikgewogICAgY29uc3Qgc2EgPSBTdHJpbmcoYSB8fCAnJyk7CiAgICBjb25zdCBzYiA9IFN0cmluZyhiIHx8ICcnKTsKICAg
;IGNvbnN0IG4gPSBNYXRoLm1heChzYS5sZW5ndGgsIHNiLmxlbmd0aCk7CiAgICBmb3IgKGxldCBpID0gMDsgaSA8IG47IGkrKykgewogICAgICBjb25zdCBj
;YSA9IHNhW2ldIHx8ICcnOwogICAgICBjb25zdCBjYiA9IHNiW2ldIHx8ICcnOwogICAgICBpZiAoIWNhKSByZXR1cm4gLTE7CiAgICAgIGlmICghY2IpIHJl
;dHVybiAxOwogICAgICBjb25zdCBsYSA9IGNhLnRvTG93ZXJDYXNlKCk7CiAgICAgIGNvbnN0IGxiID0gY2IudG9Mb3dlckNhc2UoKTsKICAgICAgaWYgKC9b
;YS16XS9pLnRlc3QoY2EpICYmIC9bYS16XS9pLnRlc3QoY2IpKSB7CiAgICAgICAgaWYgKGxhICE9PSBsYikgcmV0dXJuIGxhIDwgbGIgPyAtMSA6IDE7CiAg
;ICAgICAgY29uc3QgcmEgPSBwcm9jTmFtZVNvcnRSYW5rKGNhKTsKICAgICAgICBjb25zdCByYiA9IHByb2NOYW1lU29ydFJhbmsoY2IpOwogICAgICAgIGlm
;IChyYSAhPT0gcmIpIHJldHVybiByYSAtIHJiOwogICAgICAgIGNvbnRpbnVlOwogICAgICB9CiAgICAgIGNvbnN0IGNtcCA9IGNhLmxvY2FsZUNvbXBhcmUo
;Y2IsICd6aC1DTicsIHsgbnVtZXJpYzogdHJ1ZSwgc2Vuc2l0aXZpdHk6ICd2YXJpYW50JyB9KTsKICAgICAgaWYgKGNtcCkgcmV0dXJuIGNtcDsKICAgIH0K
;ICAgIHJldHVybiAwOwogIH0KICBmdW5jdGlvbiBzb3J0UHJvY1Jvd3NGbGF0KGl0ZW1zKSB7CiAgICBjb25zdCBkaXIgPSBwcm9jU29ydERpcjsKICAgIGNv
;bnN0IGtleSA9IHByb2NTb3J0S2V5OwogICAgcmV0dXJuIGl0ZW1zLnNsaWNlKCkuc29ydCgoYSwgYikgPT4gewogICAgICBsZXQgY21wID0gMDsKICAgICAg
;c3dpdGNoIChrZXkpIHsKICAgICAgICBjYXNlICdjcHUnOgogICAgICAgICAgY21wID0gKE51bWJlcihhLmNwdU4pIHx8IDApIC0gKE51bWJlcihiLmNwdU4p
;IHx8IDApOwogICAgICAgICAgYnJlYWs7CiAgICAgICAgY2FzZSAnbWVtJzoKICAgICAgICAgIGNtcCA9IChOdW1iZXIoYS5tZW1OKSB8fCAwKSAtIChOdW1i
;ZXIoYi5tZW1OKSB8fCAwKTsKICAgICAgICAgIGJyZWFrOwogICAgICAgIGNhc2UgJ3BpZCc6CiAgICAgICAgICBjbXAgPSAoTnVtYmVyKGEucGlkKSB8fCAw
;KSAtIChOdW1iZXIoYi5waWQpIHx8IDApOwogICAgICAgICAgYnJlYWs7CiAgICAgICAgY2FzZSAncHJvdG8nOgogICAgICAgICAgY21wID0gU3RyaW5nKGEu
;cHJvdG8gfHwgJycpLmxvY2FsZUNvbXBhcmUoU3RyaW5nKGIucHJvdG8gfHwgJycpLCAnZW4nKTsKICAgICAgICAgIGJyZWFrOwogICAgICAgIGNhc2UgJ2xp
;cCc6CiAgICAgICAgICBjbXAgPSBTdHJpbmcoYS5sb2NhbElwIHx8ICcnKS5sb2NhbGVDb21wYXJlKFN0cmluZyhiLmxvY2FsSXAgfHwgJycpLCAnZW4nLCB7
;IG51bWVyaWM6IHRydWUgfSk7CiAgICAgICAgICBicmVhazsKICAgICAgICBjYXNlICdscG9ydCc6CiAgICAgICAgICBjbXAgPSAoTnVtYmVyKGEubG9jYWxQ
;b3J0KSB8fCAwKSAtIChOdW1iZXIoYi5sb2NhbFBvcnQpIHx8IDApOwogICAgICAgICAgYnJlYWs7CiAgICAgICAgY2FzZSAncmlwJzoKICAgICAgICAgIGNt
;cCA9IFN0cmluZyhhLnJlbW90ZUlwIHx8ICcnKS5sb2NhbGVDb21wYXJlKFN0cmluZyhiLnJlbW90ZUlwIHx8ICcnKSwgJ2VuJywgeyBudW1lcmljOiB0cnVl
;IH0pOwogICAgICAgICAgYnJlYWs7CiAgICAgICAgY2FzZSAncnBvcnQnOgogICAgICAgICAgY21wID0gKE51bWJlcihhLnJlbW90ZVBvcnQpIHx8IDApIC0g
;KE51bWJlcihiLnJlbW90ZVBvcnQpIHx8IDApOwogICAgICAgICAgYnJlYWs7CiAgICAgICAgY2FzZSAnc3RhdGUnOgogICAgICAgICAgY21wID0gU3RyaW5n
;KGEuc3RhdGUgfHwgJycpLmxvY2FsZUNvbXBhcmUoU3RyaW5nKGIuc3RhdGUgfHwgJycpLCAnemgtQ04nKTsKICAgICAgICAgIGJyZWFrOwogICAgICAgIGNh
;c2UgJ25hbWUnOgogICAgICAgIGRlZmF1bHQ6CiAgICAgICAgICBjbXAgPSBjb21wYXJlUHJvY05hbWUoYS5wcm9jIHx8ICcnLCBiLnByb2MgfHwgJycpOwog
;ICAgICAgICAgYnJlYWs7CiAgICAgIH0KICAgICAgaWYgKCFjbXAgJiYga2V5ICE9PSAnbmFtZScpCiAgICAgICAgY21wID0gY29tcGFyZVByb2NOYW1lKGEu
;cHJvYyB8fCAnJywgYi5wcm9jIHx8ICcnKTsKICAgICAgaWYgKCFjbXApCiAgICAgICAgY21wID0gKE51bWJlcihhLnBpZCkgfHwgMCkgLSAoTnVtYmVyKGIu
;cGlkKSB8fCAwKTsKICAgICAgaWYgKCFjbXApCiAgICAgICAgY21wID0gKE51bWJlcihhLmxvY2FsUG9ydCkgfHwgMCkgLSAoTnVtYmVyKGIubG9jYWxQb3J0
;KSB8fCAwKTsKICAgICAgcmV0dXJuIGNtcCAqIGRpcjsKICAgIH0pOwogIH0KICBmdW5jdGlvbiByZWZyZXNoUHJvY1NvcnRIZWFkZXJzKCkgewogICAgaWYg
;KCFwcm9jSGVhZCkgcmV0dXJuOwogICAgcHJvY0hlYWQucXVlcnlTZWxlY3RvckFsbCgnLnByb2MtaGNlbGxbZGF0YS1zb3J0XScpLmZvckVhY2goY2VsbCA9
;PiB7CiAgICAgIGNvbnN0IGsgPSBjZWxsLmdldEF0dHJpYnV0ZSgnZGF0YS1zb3J0Jyk7CiAgICAgIGNvbnN0IG9uID0gayA9PT0gcHJvY1NvcnRLZXk7CiAg
;ICAgIGNlbGwuY2xhc3NMaXN0LnRvZ2dsZSgnc29ydGVkJywgb24pOwogICAgICBjZWxsLmNsYXNzTGlzdC50b2dnbGUoJ2FzYycsIG9uICYmIHByb2NTb3J0
;RGlyID4gMCk7CiAgICAgIGNlbGwuY2xhc3NMaXN0LnRvZ2dsZSgnZGVzYycsIG9uICYmIHByb2NTb3J0RGlyIDwgMCk7CiAgICB9KTsKICB9CiAgaWYgKHBy
;b2NIZWFkKSB7CiAgICBwcm9jSGVhZC5xdWVyeVNlbGVjdG9yQWxsKCcucHJvYy1oY2VsbFtkYXRhLXNvcnRdJykuZm9yRWFjaChjZWxsID0+IHsKICAgICAg
;Y2VsbC5hZGRFdmVudExpc3RlbmVyKCdjbGljaycsIChlKSA9PiB7CiAgICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOwogICAgICAgIGNvbnN0IGsgPSBjZWxs
;LmdldEF0dHJpYnV0ZSgnZGF0YS1zb3J0Jyk7CiAgICAgICAgaWYgKCFrKSByZXR1cm47CiAgICAgICAgaWYgKHByb2NTb3J0S2V5ID09PSBrKSBwcm9jU29y
;dERpciA9IC1wcm9jU29ydERpcjsKICAgICAgICBlbHNlIHsKICAgICAgICAgIHByb2NTb3J0S2V5ID0gazsKICAgICAgICAgIC8vIOi1hOa6kOWIl+m7mOiu
;pOmrmOKGkuS9ju+8jOWQjeensOm7mOiupCBh4oaSegogICAgICAgICAgcHJvY1NvcnREaXIgPSAoayA9PT0gJ2NwdScgfHwgayA9PT0gJ21lbScgfHwgayA9
;PT0gJ2xwb3J0JyB8fCBrID09PSAncnBvcnQnKSA/IC0xIDogMTsKICAgICAgICB9CiAgICAgICAgcmVmcmVzaFByb2NTb3J0SGVhZGVycygpOwogICAgICAg
;IHJlbmRlclByb2NUYWJsZSgpOwogICAgICB9KTsKICAgIH0pOwogICAgcmVmcmVzaFByb2NTb3J0SGVhZGVycygpOwogIH0KICBmdW5jdGlvbiBwYXRjaFBy
;b2NJY29ucyhpdGVtcykgewogICAgbGV0IHBhdGNoZWQgPSAwOwogICAgZm9yIChjb25zdCBwIG9mIGl0ZW1zIHx8IFtdKSB7CiAgICAgIGlmICghcCB8fCAh
;cC5pY29uKSBjb250aW51ZTsKICAgICAgY29uc3Qga2V5ID0gcHJvY1Jvd0tleShwKTsKICAgICAgY29uc3Qgcm93ID0gcHJvY1Jvd01hcC5nZXQoa2V5KSB8
;fCBwcm9jQm9keS5xdWVyeVNlbGVjdG9yKCcucHJvYy1yb3dbZGF0YS1rZXk9IicgKyBDU1MuZXNjYXBlKGtleSkgKyAnIl0nKTsKICAgICAgaWYgKCFyb3cp
;IGNvbnRpbnVlOwogICAgICBjb25zdCBuYW1lQm94ID0gcm93LnF1ZXJ5U2VsZWN0b3IoJy5wcm9jLW5hbWUnKTsKICAgICAgc2V0UHJvY0ljb25FbChuYW1l
;Qm94LCBwLmljb24sIHByb2NJY29uU3RhYmxlS2V5KHApKTsKICAgICAgcGF0Y2hlZCsrOwogICAgfQogICAgcmV0dXJuIHBhdGNoZWQgPiAwIHx8IHByb2NS
;b3dNYXAuc2l6ZSA+IDA7CiAgfQogIGZ1bmN0aW9uIHNlbGVjdFByb2NOYW1lR3JvdXAocm93LCBhZGRpdGl2ZSkgewogICAgY29uc3Qga2V5ID0gcm93Lmdl
;dEF0dHJpYnV0ZSgnZGF0YS1rZXknKTsKICAgIGlmICghYWRkaXRpdmUpIHByb2NTZWxLZXlzLmNsZWFyKCk7CiAgICBwcm9jU2VsS2V5cy5hZGQoa2V5KTsK
;ICAgIHByb2NBbmNob3JLZXkgPSBrZXk7CiAgICBwcm9jU2VsS2V5ID0ga2V5OwogICAgcHJvY1NlbFBpZCA9IE51bWJlcihyb3cuZ2V0QXR0cmlidXRlKCdk
;YXRhLXBpZCcpKSB8fCAwOwogICAgcmVmcmVzaFByb2NTZWxlY3Rpb25VSSgpOwogIH0KICBmdW5jdGlvbiBzZWxlY3RQcm9jRnJvbUV2ZW50KGUsIHJvdykg
;ewogICAgY29uc3Qga2V5ID0gcm93LmdldEF0dHJpYnV0ZSgnZGF0YS1rZXknKTsKICAgIGNvbnN0IHBpZCA9IE51bWJlcihyb3cuZ2V0QXR0cmlidXRlKCdk
;YXRhLXBpZCcpKSB8fCAwOwogICAgY29uc3Qgcm93cyA9IEFycmF5LmZyb20ocHJvY0JvZHkucXVlcnlTZWxlY3RvckFsbCgnLnByb2Mtcm93JykpOwogICAg
;Y29uc3QgaWR4ID0gcm93cy5pbmRleE9mKHJvdyk7CiAgICBpZiAoZS5zaGlmdEtleSAmJiBwcm9jQW5jaG9yS2V5KSB7CiAgICAgIGNvbnN0IGFJZHggPSBy
;b3dzLmZpbmRJbmRleChyID0+IHIuZ2V0QXR0cmlidXRlKCdkYXRhLWtleScpID09PSBwcm9jQW5jaG9yS2V5KTsKICAgICAgaWYgKGFJZHggPj0gMCAmJiBp
;ZHggPj0gMCkgewogICAgICAgIGlmICghZS5jdHJsS2V5KSBwcm9jU2VsS2V5cy5jbGVhcigpOwogICAgICAgIGNvbnN0IGxvID0gTWF0aC5taW4oYUlkeCwg
;aWR4KSwgaGkgPSBNYXRoLm1heChhSWR4LCBpZHgpOwogICAgICAgIGZvciAobGV0IGkgPSBsbzsgaSA8PSBoaTsgaSsrKSBwcm9jU2VsS2V5cy5hZGQocm93
;c1tpXS5nZXRBdHRyaWJ1dGUoJ2RhdGEta2V5JykpOwogICAgICB9CiAgICAgIHByb2NTZWxLZXkgPSBrZXk7CiAgICAgIHByb2NTZWxQaWQgPSBwaWQ7CiAg
;ICAgIHJlZnJlc2hQcm9jU2VsZWN0aW9uVUkoKTsKICAgICAgcmV0dXJuOwogICAgfQogICAgaWYgKGUuY3RybEtleSkgewogICAgICBpZiAocHJvY1NlbEtl
;eXMuaGFzKGtleSkpIHByb2NTZWxLZXlzLmRlbGV0ZShrZXkpOwogICAgICBlbHNlIHByb2NTZWxLZXlzLmFkZChrZXkpOwogICAgICBwcm9jQW5jaG9yS2V5
;ID0ga2V5OwogICAgICBwcm9jU2VsS2V5ID0ga2V5OwogICAgICBwcm9jU2VsUGlkID0gcGlkOwogICAgICByZWZyZXNoUHJvY1NlbGVjdGlvblVJKCk7CiAg
;ICAgIHJldHVybjsKICAgIH0KICAgIC8vIOaZrumAmuWNleWHu++8muWPque7meeCueS4reeahOihjOW6leiJsu+8m+WQjOWQjeaVtOauteeUu+a3oee7v+Wk
;luahhgogICAgc2VsZWN0UHJvY05hbWVHcm91cChyb3csIGZhbHNlKTsKICB9CiAgZnVuY3Rpb24gcmVmcmVzaFByb2NTZWxlY3Rpb25VSSgpIHsKICAgIGNv
;bnN0IHJvd3MgPSBBcnJheS5mcm9tKHByb2NCb2R5LnF1ZXJ5U2VsZWN0b3JBbGwoJy5wcm9jLXJvdycpKTsKICAgIGNvbnN0IEdSUCA9IFsnb24nLCAnZ3Jw
;JywgJ2dycC1maXJzdCcsICdncnAtbWlkJywgJ2dycC1sYXN0JywgJ2dycC1vbmx5J107CiAgICBjb25zdCBzZWxlY3RlZE5hbWVzID0gbmV3IFNldCgpOwog
;ICAgcm93cy5mb3JFYWNoKHJvdyA9PiB7CiAgICAgIEdSUC5mb3JFYWNoKGMgPT4gcm93LmNsYXNzTGlzdC5yZW1vdmUoYykpOwogICAgICBjb25zdCBrZXkg
;PSByb3cuZ2V0QXR0cmlidXRlKCdkYXRhLWtleScpOwogICAgICBpZiAocHJvY1NlbEtleXMuaGFzKGtleSkpIHsKICAgICAgICByb3cuY2xhc3NMaXN0LmFk
;ZCgnb24nKTsKICAgICAgICBjb25zdCBuYW1lID0gU3RyaW5nKHJvdy5nZXRBdHRyaWJ1dGUoJ2RhdGEtbmFtZScpIHx8ICcnKS50b0xvd2VyQ2FzZSgpOwog
;ICAgICAgIGlmIChuYW1lKSBzZWxlY3RlZE5hbWVzLmFkZChuYW1lKTsKICAgICAgfQogICAgfSk7CiAgICAvLyDmjInpgInkuK3ooYznmoTov5vnqIvlkI3v
;vIzmiorlkIzlkI3ov57nu63mrrXljIXmt6Hnu7/lpJbmoYbvvIjml6DlupXoibLvvIkKICAgIGxldCBpID0gMDsKICAgIHdoaWxlIChpIDwgcm93cy5sZW5n
;dGgpIHsKICAgICAgY29uc3QgbmFtZSA9IFN0cmluZyhyb3dzW2ldLmdldEF0dHJpYnV0ZSgnZGF0YS1uYW1lJykgfHwgJycpLnRvTG93ZXJDYXNlKCk7CiAg
;ICAgIGlmICghbmFtZSB8fCAhc2VsZWN0ZWROYW1lcy5oYXMobmFtZSkpIHsKICAgICAgICBpKys7CiAgICAgICAgY29udGludWU7CiAgICAgIH0KICAgICAg
;bGV0IGogPSBpOwogICAgICB3aGlsZSAoaiArIDEgPCByb3dzLmxlbmd0aAogICAgICAgICYmIFN0cmluZyhyb3dzW2ogKyAxXS5nZXRBdHRyaWJ1dGUoJ2Rh
;dGEtbmFtZScpIHx8ICcnKS50b0xvd2VyQ2FzZSgpID09PSBuYW1lKSB7CiAgICAgICAgaisrOwogICAgICB9CiAgICAgIGZvciAobGV0IGsgPSBpOyBrIDw9
;IGo7IGsrKykgewogICAgICAgIHJvd3Nba10uY2xhc3NMaXN0LmFkZCgnZ3JwJyk7CiAgICAgICAgaWYgKGkgPT09IGopIHJvd3Nba10uY2xhc3NMaXN0LmFk
;ZCgnZ3JwLW9ubHknKTsKICAgICAgICBlbHNlIGlmIChrID09PSBpKSByb3dzW2tdLmNsYXNzTGlzdC5hZGQoJ2dycC1maXJzdCcpOwogICAgICAgIGVsc2Ug
;aWYgKGsgPT09IGopIHJvd3Nba10uY2xhc3NMaXN0LmFkZCgnZ3JwLWxhc3QnKTsKICAgICAgICBlbHNlIHJvd3Nba10uY2xhc3NMaXN0LmFkZCgnZ3JwLW1p
;ZCcpOwogICAgICB9CiAgICAgIGkgPSBqICsgMTsKICAgIH0KICB9CiAgZnVuY3Rpb24gY29sbGVjdFByb2NUYXJnZXRzKCkgewogICAgY29uc3QgbWFwID0g
;bmV3IE1hcCgpOwogICAgZm9yIChjb25zdCBrZXkgb2YgcHJvY1NlbEtleXMpIHsKICAgICAgY29uc3Qgcm93ID0gcHJvY1Jvd01hcC5nZXQoa2V5KSB8fCBw
;cm9jQm9keS5xdWVyeVNlbGVjdG9yKCcucHJvYy1yb3dbZGF0YS1rZXk9IicgKyBDU1MuZXNjYXBlKGtleSkgKyAnIl0nKTsKICAgICAgbGV0IHBpZCA9IDAs
;IG5hbWUgPSAnJywgcGF0aCA9ICcnOwogICAgICBpZiAocm93KSB7CiAgICAgICAgcGlkID0gTnVtYmVyKHJvdy5nZXRBdHRyaWJ1dGUoJ2RhdGEtcGlkJykp
;IHx8IDA7CiAgICAgICAgbmFtZSA9IHJvdy5nZXRBdHRyaWJ1dGUoJ2RhdGEtbmFtZScpIHx8ICcnOwogICAgICAgIHBhdGggPSByb3cuZ2V0QXR0cmlidXRl
;KCdkYXRhLXBhdGgnKSB8fCAnJzsKICAgICAgfSBlbHNlIHsKICAgICAgICBjb25zdCBwID0gcHJvY0l0ZW1zLmZpbmQoeCA9PiBwcm9jUm93S2V5KHgpID09
;PSBrZXkpOwogICAgICAgIGlmICghcCkgY29udGludWU7CiAgICAgICAgcGlkID0gTnVtYmVyKHAucGlkKSB8fCAwOwogICAgICAgIG5hbWUgPSBwLnByb2Mg
;fHwgJyc7CiAgICAgICAgcGF0aCA9IHAucGF0aCB8fCAnJzsKICAgICAgfQogICAgICBpZiAocGlkIDw9IDAgfHwgbWFwLmhhcyhwaWQpKSBjb250aW51ZTsK
;ICAgICAgaWYgKCFwYXRoKSB7CiAgICAgICAgY29uc3QgcCA9IHByb2NJdGVtcy5maW5kKHggPT4gTnVtYmVyKHgucGlkKSA9PT0gcGlkICYmIHgucGF0aCk7
;CiAgICAgICAgaWYgKHApIHBhdGggPSBwLnBhdGggfHwgJyc7CiAgICAgIH0KICAgICAgbWFwLnNldChwaWQsIHsgcGlkLCBuYW1lLCBwYXRoIH0pOwogICAg
;fQogICAgcmV0dXJuIEFycmF5LmZyb20obWFwLnZhbHVlcygpKTsKICB9CiAgZnVuY3Rpb24gcmVuZGVyUHJvY1RhYmxlKCkgewogICAgY29uc3QgcSA9IChw
;cm9jUS52YWx1ZSB8fCAnJykudHJpbSgpLnRvTG93ZXJDYXNlKCk7CiAgICBsZXQgcm93cyA9IHByb2NJdGVtcy5zbGljZSgpOwogICAgaWYgKHEpIHsKICAg
;ICAgcm93cyA9IHJvd3MuZmlsdGVyKHAgPT4gewogICAgICAgIGNvbnN0IGhheSA9IFtwLnByb3RvLCBwLmxvY2FsSXAsIHAubG9jYWxQb3J0LCBwLnJlbW90
;ZUlwLCBwLnJlbW90ZVBvcnQsIHAuc3RhdGUsIHAucHJvYywgcC5waWQsIHAucHBpZF0uam9pbignICcpLnRvTG93ZXJDYXNlKCk7CiAgICAgICAgcmV0dXJu
;IGhheS5pbmNsdWRlcyhxKTsKICAgICAgfSk7CiAgICB9CiAgICByb3dzID0gc29ydFByb2NSb3dzRmxhdChyb3dzKTsKICAgIGNvbnN0IHBpZFNldCA9IG5l
;dyBTZXQoKTsKICAgIGZvciAoY29uc3QgcCBvZiByb3dzKSB7CiAgICAgIGNvbnN0IGlkID0gTnVtYmVyKHAucGlkKSB8fCAwOwogICAgICBpZiAoaWQgPiAw
;KSBwaWRTZXQuYWRkKGlkKTsKICAgIH0KICAgIHByb2NDb3VudC50ZXh0Q29udGVudCA9IFN0cmluZyhwaWRTZXQuc2l6ZSB8fCByb3dzLmxlbmd0aCk7CiAg
;ICBpZiAoIXJvd3MubGVuZ3RoKSB7CiAgICAgIHByb2NCb2R5LmlubmVySFRNTCA9ICc8ZGl2IHN0eWxlPSJwYWRkaW5nOjI0cHg7dGV4dC1hbGlnbjpjZW50
;ZXI7Y29sb3I6IzlhYTFiMiI+5rKh5pyJ5Yy56YWN55qE6L+e5o6lPC9kaXY+JzsKICAgICAgcHJvY1Jvd01hcC5jbGVhcigpOwogICAgICBwcm9jU2VsS2V5
;cy5jbGVhcigpOwogICAgICBwcm9jQW5jaG9yS2V5ID0gJyc7CiAgICAgIHByb2NTZWxLZXkgPSAnJzsKICAgICAgcHJvY1NlbFBpZCA9IDA7CiAgICAgIHJl
;dHVybjsKICAgIH0KICAgIC8vIOWinumHj+abtOaWsO+8muWkjeeUqOihjOS4juWbvuagh+iKgueCue+8jOWPquaUueaWh+Wtl++8jOmBv+WFjeaVtOihqOmH
;jeW7uumXquWbvuaghwogICAgY29uc3Qga2VlcCA9IG5ldyBTZXQoKTsKICAgIGNvbnN0IGVtcHR5SGludCA9IHByb2NCb2R5LnF1ZXJ5U2VsZWN0b3IoJ2Rp
;dltzdHlsZV0nKTsKICAgIGlmIChlbXB0eUhpbnQpIHsKICAgICAgcHJvY0JvZHkuaW5uZXJIVE1MID0gJyc7CiAgICAgIHByb2NSb3dNYXAuY2xlYXIoKTsK
;ICAgIH0KICAgIGZvciAobGV0IGkgPSAwOyBpIDwgcm93cy5sZW5ndGg7IGkrKykgewogICAgICBjb25zdCBwID0gcm93c1tpXTsKICAgICAgY29uc3Qga2V5
;ID0gcHJvY1Jvd0tleShwKTsKICAgICAga2VlcC5hZGQoa2V5KTsKICAgICAgbGV0IHJvdyA9IHByb2NSb3dNYXAuZ2V0KGtleSk7CiAgICAgIGlmICghcm93
;IHx8ICFyb3cuaXNDb25uZWN0ZWQpIHsKICAgICAgICByb3cgPSBlbnN1cmVQcm9jUm93KHApOwogICAgICAgIHByb2NSb3dNYXAuc2V0KGtleSwgcm93KTsK
;ICAgICAgfQogICAgICB1cGRhdGVQcm9jUm93RGF0YShyb3csIHApOwogICAgICBjb25zdCBhdCA9IHByb2NCb2R5LmNoaWxkcmVuW2ldOwogICAgICBpZiAo
;YXQgIT09IHJvdykgewogICAgICAgIGlmIChhdCkgcHJvY0JvZHkuaW5zZXJ0QmVmb3JlKHJvdywgYXQpOwogICAgICAgIGVsc2UgcHJvY0JvZHkuYXBwZW5k
;Q2hpbGQocm93KTsKICAgICAgfQogICAgfQogICAgLy8g5Yig5o6J5LiN5YaN5a2Y5Zyo55qE6KGMCiAgICBmb3IgKGNvbnN0IFtrZXksIHJvd10gb2YgQXJy
;YXkuZnJvbShwcm9jUm93TWFwLmVudHJpZXMoKSkpIHsKICAgICAgaWYgKGtlZXAuaGFzKGtleSkpIGNvbnRpbnVlOwogICAgICBwcm9jUm93TWFwLmRlbGV0
;ZShrZXkpOwogICAgICBpZiAocm93ICYmIHJvdy5wYXJlbnROb2RlKSByb3cucGFyZW50Tm9kZS5yZW1vdmVDaGlsZChyb3cpOwogICAgfQogICAgZm9yIChj
;b25zdCBrZXkgb2YgQXJyYXkuZnJvbShwcm9jU2VsS2V5cykpIHsKICAgICAgaWYgKCFrZWVwLmhhcyhrZXkpKSBwcm9jU2VsS2V5cy5kZWxldGUoa2V5KTsK
;ICAgIH0KICAgIGlmIChwcm9jU2VsS2V5ICYmICFwcm9jU2VsS2V5cy5oYXMocHJvY1NlbEtleSkpIHsKICAgICAgcHJvY1NlbEtleSA9IHByb2NTZWxLZXlz
;LnNpemUgPyBBcnJheS5mcm9tKHByb2NTZWxLZXlzKVswXSA6ICcnOwogICAgICBwcm9jU2VsUGlkID0gMDsKICAgICAgaWYgKHByb2NTZWxLZXkpIHsKICAg
;ICAgICBjb25zdCByID0gcHJvY1Jvd01hcC5nZXQocHJvY1NlbEtleSk7CiAgICAgICAgcHJvY1NlbFBpZCA9IHIgPyAoTnVtYmVyKHIuZ2V0QXR0cmlidXRl
;KCdkYXRhLXBpZCcpKSB8fCAwKSA6IDA7CiAgICAgIH0KICAgIH0KICAgIHJlZnJlc2hQcm9jU2VsZWN0aW9uVUkoKTsKICB9CiAgZnVuY3Rpb24gaW5mb1Jv
;dyhsYWIsIHZhbEh0bWwsIGxpbmtIdG1sKSB7CiAgICByZXR1cm4gJzxkaXYgY2xhc3M9ImluZm8tcm93Ij4nCiAgICAgICsgJzxkaXYgY2xhc3M9ImluZm8t
;bGFiIj4nICsgZXNjYXBlSHRtbChsYWIpICsgJzwvZGl2PicKICAgICAgKyAnPGRpdiBjbGFzcz0iaW5mby1kYXNoIj48L2Rpdj4nCiAgICAgICsgJzxkaXYg
;Y2xhc3M9ImluZm8tdmFsIj4nICsgKHZhbEh0bWwgfHwgJycpICsgJzwvZGl2PicKICAgICAgKyAobGlua0h0bWwgfHwgJzxzcGFuPjwvc3Bhbj4nKQogICAg
;ICArICc8L2Rpdj4nOwogIH0KICBmdW5jdGlvbiByZW5kZXJTeXNJbmZvKCkgewogICAgY29uc3QgZCA9IGluZm9EYXRhIHx8IHt9OwogICAgbGV0IGh0bWwg
;PSAnJzsKICAgIGh0bWwgKz0gaW5mb1Jvdygn5pON5L2c57O757ufJywgZXNjYXBlSHRtbChkLm9zIHx8ICfmnKrnn6UnKSk7CiAgICBodG1sICs9IGluZm9S
;b3coJ+S4u+advycsIGVzY2FwZUh0bWwoZC5ib2FyZCB8fCAn5pyq55+lJykpOwogICAgaHRtbCArPSBpbmZvUm93KCfmmL7npLrlmagnLCBlc2NhcGVIdG1s
;KGQubW9uaXRvciB8fCAn5pyq55+lJykpOwogICAgaHRtbCArPSBpbmZvUm93KCflpITnkIblmagnLCBlc2NhcGVIdG1sKGQuY3B1IHx8ICfmnKrnn6UnKSk7
;CiAgICBodG1sICs9IGluZm9Sb3coJ+WGheWtmCcsIGVzY2FwZUh0bWwoZC5tZW1vcnkgfHwgJ+acquefpScpKTsKICAgIGh0bWwgKz0gaW5mb1Jvdygn56Gs
;55uYJywgZXNjYXBlSHRtbChkLmRpc2sgfHwgJ+acquefpScpKTsKICAgIGh0bWwgKz0gaW5mb1Jvdygn5pi+5Y2hJywgZXNjYXBlSHRtbChkLmdwdSB8fCAn
;5pyq55+lJykpOwogICAgY29uc3Qgc291bmRzID0gQXJyYXkuaXNBcnJheShkLnNvdW5kKSA/IGQuc291bmQgOiBbXTsKICAgIGh0bWwgKz0gaW5mb1Jvdygn
;5aOw5Y2hJywgc291bmRzLmxlbmd0aAogICAgICA/IHNvdW5kcy5tYXAocyA9PiAnPHNwYW4gY2xhc3M9ImxpbmUiPicgKyBlc2NhcGVIdG1sKHMpICsgJzwv
;c3Bhbj4nKS5qb2luKCcnKQogICAgICA6IGVzY2FwZUh0bWwoJ+acquefpScpKTsKICAgIGNvbnN0IG5ldHMgPSBBcnJheS5pc0FycmF5KGQubmljcykgPyBk
;Lm5pY3MgOiBbXTsKICAgIGxldCBuZXRIdG1sID0gJ+acquefpSc7CiAgICBpZiAobmV0cy5sZW5ndGgpIHsKICAgICAgbmV0SHRtbCA9IG5ldHMubWFwKG4g
;PT4gewogICAgICAgIGNvbnN0IG5hbWUgPSBlc2NhcGVIdG1sKG4ubmFtZSB8fCAnJyk7CiAgICAgICAgY29uc3QgbWFjID0gZXNjYXBlSHRtbChuLm1hYyB8
;fCAn4oCUJyk7CiAgICAgICAgY29uc3QgaXBSYXcgPSAobi5pcCAmJiBTdHJpbmcobi5pcCkudHJpbSgpKSA/IFN0cmluZyhuLmlwKS50cmltKCkgOiAnMC4w
;LjAuMCc7CiAgICAgICAgY29uc3QgaXAgPSBlc2NhcGVIdG1sKGlwUmF3ID09PSAn4oCUJyA/ICcwLjAuMC4wJyA6IGlwUmF3KTsKICAgICAgICByZXR1cm4g
;JzxkaXYgY2xhc3M9Im5ldC1saW5lIj48c3Bhbj4nICsgbmFtZSArICc8L3NwYW4+JwogICAgICAgICAgKyAnPHNwYW4+PHNwYW4gY2xhc3M9ImsiPk1BQ+Wc
;sOWdgDogPC9zcGFuPicgKyBtYWMgKyAnPC9zcGFuPicKICAgICAgICAgICsgJzxzcGFuPjxzcGFuIGNsYXNzPSJrIj5JUOWcsOWdgDogPC9zcGFuPicgKyBp
;cCArICc8L3NwYW4+PC9kaXY+JzsKICAgICAgfSkuam9pbignJyk7CiAgICB9CiAgICBodG1sICs9IGluZm9Sb3coJ+e9keWNoScsIG5ldEh0bWwpOwogICAg
;aHRtbCArPSBpbmZvUm93KCflpJbnvZFJUCcsIGVzY2FwZUh0bWwoZC53YW4gfHwgJ+acquefpScpKTsKICAgIGh0bWwgKz0gaW5mb1JvdygnSUXniYjmnKwn
;LCBlc2NhcGVIdG1sKGQuaWUgfHwgJ+acquefpScpKTsKICAgIGh0bWwgKz0gaW5mb1JvdygnRmxhc2jniYjmnKwnLCBlc2NhcGVIdG1sKGQuZmxhc2ggfHwg
;J+acquefpScpKTsKICAgIGNvbnN0IGJvb3RFeHRyYSA9ICc8c3BhbiBjbGFzcz0ic3ViIj7ns7vnu5/lt7Lov5DooYw6IDxzcGFuIGlkPSJpbmZvLXVwdGlt
;ZSI+JwogICAgICArIGVzY2FwZUh0bWwoZm9ybWF0VXB0aW1lVGV4dChjdXJyZW50VXB0aW1lU2VjKCkpKSArICc8L3NwYW4+PC9zcGFuPic7CiAgICBodG1s
;ICs9IGluZm9Sb3coJ+W8gOacuuaXtumXtCcsIGVzY2FwZUh0bWwoZC5ib290IHx8ICfmnKrnn6UnKSArIGJvb3RFeHRyYSk7CiAgICBodG1sICs9IGluZm9S
;b3coJ+S4iuasoeWFs+acuuaXtumXtCcsIGVzY2FwZUh0bWwoZC5zaHV0ZG93biB8fCAn5pyq55+lJykpOwogICAgaHRtbCArPSBpbmZvUm93KCfns7vnu5/l
;ronoo4Xml6XmnJ8nLCBlc2NhcGVIdG1sKGQuaW5zdGFsbCB8fCAn5pyq55+lJykpOwogICAgaW5mb1BhbmVsLmlubmVySFRNTCA9IGh0bWw7CiAgfQogIGZ1
;bmN0aW9uIGN1cnJlbnRVcHRpbWVTZWMoKSB7CiAgICBjb25zdCBiYXNlID0gTnVtYmVyKGluZm9EYXRhICYmIGluZm9EYXRhLnVwdGltZVNlYykgfHwgMDsK
;ICAgIGNvbnN0IHN5bmNlZCA9IE51bWJlcihpbmZvRGF0YSAmJiBpbmZvRGF0YS5fc3luY2VkQXQpIHx8IERhdGUubm93KCk7CiAgICByZXR1cm4gTWF0aC5t
;YXgoMCwgTWF0aC5mbG9vcihiYXNlICsgKERhdGUubm93KCkgLSBzeW5jZWQpIC8gMTAwMCkpOwogIH0KICBmdW5jdGlvbiBmb3JtYXRVcHRpbWVUZXh0KHNl
;YykgewogICAgc2VjID0gTWF0aC5tYXgoMCwgTWF0aC5mbG9vcihOdW1iZXIoc2VjKSB8fCAwKSk7CiAgICBjb25zdCBkID0gTWF0aC5mbG9vcihzZWMgLyA4
;NjQwMCk7CiAgICBjb25zdCBoID0gTWF0aC5mbG9vcigoc2VjICUgODY0MDApIC8gMzYwMCk7CiAgICBjb25zdCBtaSA9IE1hdGguZmxvb3IoKHNlYyAlIDM2
;MDApIC8gNjApOwogICAgY29uc3QgcyA9IHNlYyAlIDYwOwogICAgcmV0dXJuIChkID4gMCA/IChkICsgJ+WkqScpIDogJycpICsgaCArICflsI/ml7YnICsg
;bWkgKyAn5YiG6ZKfJyArIHMgKyAn56eSJzsKICB9CiAgZnVuY3Rpb24gdGlja0luZm9VcHRpbWUoKSB7CiAgICBpZiAobW9uaXRvclRhYiAhPT0gJ2luZm8n
;KSByZXR1cm47CiAgICBjb25zdCBlbCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdpbmZvLXVwdGltZScpOwogICAgaWYgKCFlbCkgcmV0dXJuOwogICAg
;ZWwudGV4dENvbnRlbnQgPSBmb3JtYXRVcHRpbWVUZXh0KGN1cnJlbnRVcHRpbWVTZWMoKSk7CiAgfQogIHNldEludGVydmFsKHRpY2tJbmZvVXB0aW1lLCAx
;MDAwKTsKCiAgd2luZG93Ll9fc2V0UHJvY2Vzc2VzID0gKHBheWxvYWQpID0+IHsKICAgIC8vIOi/m+eoi+ebkeaOp+W3suaUueS4uui/nuaOpeWIl+ihqO+8
;jOW/veeVpeaXp+i/m+eoi+aOqOmAgQogIH07CiAgd2luZG93Ll9fc2V0UG9ydHMgPSAocGF5bG9hZCkgPT4gewogICAgdHJ5IHsKICAgICAgY29uc3QgZGF0
;YSA9IHR5cGVvZiBwYXlsb2FkID09PSAnc3RyaW5nJyA/IEpTT04ucGFyc2UocGF5bG9hZCkgOiBwYXlsb2FkOwogICAgICBjb25zdCBuZXh0ID0gQXJyYXku
;aXNBcnJheShkYXRhKSA/IGRhdGEgOiAoQXJyYXkuaXNBcnJheShkYXRhICYmIGRhdGEuaXRlbXMpID8gZGF0YS5pdGVtcyA6IFtdKTsKICAgICAgaWYgKGRh
;dGEgJiYgIUFycmF5LmlzQXJyYXkoZGF0YSkpIHsKICAgICAgICBpZiAocHJvY0NwdVRvdGFsICYmIGRhdGEuY3B1VG90YWwgIT0gbnVsbCkgcHJvY0NwdVRv
;dGFsLnRleHRDb250ZW50ID0gU3RyaW5nKGRhdGEuY3B1VG90YWwpOwogICAgICAgIGlmIChwcm9jTWVtVG90YWwgJiYgZGF0YS5tZW1Ub3RhbCAhPSBudWxs
;KSBwcm9jTWVtVG90YWwudGV4dENvbnRlbnQgPSBTdHJpbmcoZGF0YS5tZW1Ub3RhbCk7CiAgICAgICAgdXBkYXRlSGVhZEhlYXQoZGF0YS5jcHVUb3RhbCwg
;ZGF0YS5tZW1Ub3RhbCk7CiAgICAgIH0KICAgICAgY29uc3Qgc2Nyb2xsZXIgPSBwcm9jU2Nyb2xsIHx8IHByb2NCb2R5OwogICAgICBjb25zdCBwcmV2U2Ny
;b2xsID0gc2Nyb2xsZXIgPyBzY3JvbGxlci5zY3JvbGxUb3AgOiAwOwogICAgICBjb25zdCBzYW1lQ29udGVudCA9IHBvcnRzQ29udGVudFNpZyhuZXh0KSA9
;PT0gcG9ydHNDb250ZW50U2lnKHByb2NJdGVtcyk7CiAgICAgIHByb2NJdGVtcyA9IG5leHQ7CiAgICAgIGlmIChtb25pdG9yVGFiICE9PSAncHJvYycpIHJl
;dHVybjsKICAgICAgaWYgKHNhbWVDb250ZW50KSB7CiAgICAgICAgLy8g5Y+q6KGl5Zu+5qCH77yM5LiN6YeN5bu66KGMCiAgICAgICAgcGF0Y2hQcm9jSWNv
;bnMobmV4dCk7CiAgICAgICAgaWYgKHNjcm9sbGVyKSBzY3JvbGxlci5zY3JvbGxUb3AgPSBwcmV2U2Nyb2xsOwogICAgICAgIHJldHVybjsKICAgICAgfQog
;ICAgICByZW5kZXJQcm9jVGFibGUoKTsKICAgICAgaWYgKHNjcm9sbGVyKSBzY3JvbGxlci5zY3JvbGxUb3AgPSBwcmV2U2Nyb2xsOwogICAgfSBjYXRjaCAo
;ZSkgeyBjb25zb2xlLndhcm4oJ3NldFBvcnRzJywgZSk7IH0KICB9OwogIHdpbmRvdy5fX3NldEhhbmRsZXMgPSAocGF5bG9hZCkgPT4gewogICAgdHJ5IHsK
;ICAgICAgY29uc3QgZGF0YSA9IHR5cGVvZiBwYXlsb2FkID09PSAnc3RyaW5nJyA/IEpTT04ucGFyc2UocGF5bG9hZCkgOiBwYXlsb2FkOwogICAgICBoYW5k
;bGVCdXN5ID0gZmFsc2U7CiAgICAgIGhhbmRsZUl0ZW1zID0gc29ydEhhbmRsZUl0ZW1zKEFycmF5LmlzQXJyYXkoZGF0YSAmJiBkYXRhLml0ZW1zKSA/IGRh
;dGEuaXRlbXMgOiAoQXJyYXkuaXNBcnJheShkYXRhKSA/IGRhdGEgOiBbXSkpOwogICAgICBpZiAoZGF0YSAmJiBkYXRhLnEgIT0gbnVsbCkgaGFuZGxlUXVl
;cnkgPSBTdHJpbmcoZGF0YS5xKTsKICAgICAgaWYgKGRhdGEgJiYgZGF0YS5tb2RlKSBoYW5kbGVNb2RlID0gU3RyaW5nKGRhdGEubW9kZSkgPT09ICdwb3J0
;JyA/ICdwb3J0JyA6ICdoYW5kbGUnOwogICAgICBlbHNlIGhhbmRsZU1vZGUgPSBpc1BvcnRTZWFyY2hRdWVyeShoYW5kbGVRdWVyeSkgPyAncG9ydCcgOiAn
;aGFuZGxlJzsKICAgICAgY29uc3QgZXJyID0gZGF0YSAmJiBkYXRhLmVycm9yID8gU3RyaW5nKGRhdGEuZXJyb3IpIDogJyc7CiAgICAgIGlmIChoYW5kbGVT
;dGF0dXMpIGhhbmRsZVN0YXR1cy50ZXh0Q29udGVudCA9IGVyciB8fCAoaGFuZGxlSXRlbXMubGVuZ3RoID8gJycgOiAn5peg57uT5p6cJyk7CiAgICAgIGlm
;IChhcHBNb2RlID09PSAnaGFuZGxlJykgewogICAgICAgIHJlbmRlckhhbmRsZVRhYmxlKGVyciB8fCAoaGFuZGxlTW9kZSA9PT0gJ3BvcnQnID8gJ+ayoeac
;ieWMuemFjeeahOerr+WPoycgOiAn5rKh5pyJ5Yy56YWN55qE5Y+l5p+EJykpOwogICAgICAgIGNvdW50RWwudGV4dENvbnRlbnQgPSAn5YWxICcgKyBoYW5k
;bGVJdGVtcy5sZW5ndGggKyAnIOadoSc7CiAgICAgIH0KICAgIH0gY2F0Y2ggKGUpIHsKICAgICAgaGFuZGxlQnVzeSA9IGZhbHNlOwogICAgICBjb25zb2xl
;Lndhcm4oJ3NldEhhbmRsZXMnLCBlKTsKICAgIH0KICB9OwogIHdpbmRvdy5fX3Byb2NLaWxsZWQgPSAocGlkcykgPT4gewogICAgdHJ5IHsKICAgICAgY29u
;c3QgbGlzdCA9IEFycmF5LmlzQXJyYXkocGlkcykgPyBwaWRzIDogW107CiAgICAgIHJlbW92ZVJvd3NCeVBpZHMobGlzdCk7CiAgICB9IGNhdGNoIChlKSB7
;IGNvbnNvbGUud2FybigncHJvY0tpbGxlZCcsIGUpOyB9CiAgfTsKICBmdW5jdGlvbiByZW1vdmVSb3dzQnlQaWRzKHBpZHMpIHsKICAgIGNvbnN0IHNldCA9
;IG5ldyBTZXQoKHBpZHMgfHwgW10pLm1hcChuID0+IE51bWJlcihuKSkuZmlsdGVyKG4gPT4gbiA+IDApKTsKICAgIGlmICghc2V0LnNpemUpIHJldHVybjsK
;ICAgIGNvbnN0IGJlZm9yZUggPSBoYW5kbGVJdGVtcy5sZW5ndGg7CiAgICBoYW5kbGVJdGVtcyA9IGhhbmRsZUl0ZW1zLmZpbHRlcihpdCA9PiAhc2V0Lmhh
;cyhOdW1iZXIoaXQucGlkKSB8fCAwKSk7CiAgICBpZiAoaGFuZGxlSXRlbXMubGVuZ3RoICE9PSBiZWZvcmVIKSB7CiAgICAgIGZvciAoY29uc3QgayBvZiBB
;cnJheS5mcm9tKGhhbmRsZVNlbEtleXMpKSB7CiAgICAgICAgY29uc3Qgcm93ID0gaGFuZGxlQm9keS5xdWVyeVNlbGVjdG9yKCcuaGFuZGxlLXJvd1tkYXRh
;LWtleT0iJyArIENTUy5lc2NhcGUoaykgKyAnIl0nKTsKICAgICAgICBjb25zdCBwaWQgPSByb3cgPyAoTnVtYmVyKHJvdy5nZXRBdHRyaWJ1dGUoJ2RhdGEt
;cGlkJykpIHx8IDApIDogMDsKICAgICAgICBpZiAoc2V0LmhhcyhwaWQpKSBoYW5kbGVTZWxLZXlzLmRlbGV0ZShrKTsKICAgICAgfQogICAgICBpZiAoYXBw
;TW9kZSA9PT0gJ2hhbmRsZScpCiAgICAgICAgcmVuZGVySGFuZGxlVGFibGUoaGFuZGxlSXRlbXMubGVuZ3RoID8gJycgOiAoaGFuZGxlTW9kZSA9PT0gJ3Bv
;cnQnID8gJ+ayoeacieWMuemFjeeahOerr+WPoycgOiAn5rKh5pyJ5Yy56YWN55qE5Y+l5p+EJykpOwogICAgICBpZiAoYXBwTW9kZSA9PT0gJ2hhbmRsZScp
;CiAgICAgICAgY291bnRFbC50ZXh0Q29udGVudCA9ICflhbEgJyArIGhhbmRsZUl0ZW1zLmxlbmd0aCArICcg5p2hJzsKICAgIH0KICB9OwogIHdpbmRvdy5f
;X3NldFN5c0luZm8gPSAocGF5bG9hZCkgPT4gewogICAgdHJ5IHsKICAgICAgaW5mb1JlcUdlbiArPSAxOwogICAgICBjbGVhckluZm9Mb2FkV2FpdCgpOwog
;ICAgICBjb25zdCBkYXRhID0gdHlwZW9mIHBheWxvYWQgPT09ICdzdHJpbmcnID8gSlNPTi5wYXJzZShwYXlsb2FkKSA6IHBheWxvYWQ7CiAgICAgIGNvbnN0
;IHByZXZTZWMgPSBpbmZvRGF0YSAmJiBpbmZvRGF0YS51cHRpbWVTZWM7CiAgICAgIGNvbnN0IHByZXZTeW5jID0gaW5mb0RhdGEgJiYgaW5mb0RhdGEuX3N5
;bmNlZEF0OwogICAgICBpbmZvRGF0YSA9IGRhdGEgfHwge307CiAgICAgIC8vIOWQjOS4gOS7vee8k+WtmOWGjeasoeaOqOmAgeaXtuS/neeVmeWQjOatpeeC
;ue+8jOmBv+WFjei/kOihjOaXtumXtOiiq+mHjee9rgogICAgICBpZiAocHJldlN5bmMgJiYgcHJldlNlYyAhPSBudWxsICYmIE51bWJlcihpbmZvRGF0YS51
;cHRpbWVTZWMpID09PSBOdW1iZXIocHJldlNlYykpCiAgICAgICAgaW5mb0RhdGEuX3N5bmNlZEF0ID0gcHJldlN5bmM7CiAgICAgIGVsc2UKICAgICAgICBp
;bmZvRGF0YS5fc3luY2VkQXQgPSBEYXRlLm5vdygpOwogICAgICBpZiAoaW5mb0RhdGEudXB0aW1lU2VjID09IG51bGwgJiYgaW5mb0RhdGEudXB0aW1lKQog
;ICAgICAgIGluZm9EYXRhLnVwdGltZVNlYyA9IDA7CiAgICAgIGluZm9UZXh0ID0gU3RyaW5nKGRhdGEgJiYgZGF0YS50ZXh0IHx8ICcnKTsKICAgICAgaWYg
;KGFwcE1vZGUgPT09ICdpbmZvJykgewogICAgICAgIHJlbmRlclN5c0luZm8oKTsKICAgICAgICBpZiAoY291bnRFbCkgY291bnRFbC50ZXh0Q29udGVudCA9
;ICfmnKzmnLrkv6Hmga8nOwogICAgICB9CiAgICB9IGNhdGNoIChlKSB7IGNvbnNvbGUud2Fybignc2V0U3lzSW5mbycsIGUpOyB9CiAgfTsKCiAgcG9zdCgn
;dWlSZWFkeScpOwogIHdpbmRvdy5fX3Jlc3luY1NlYXJjaCA9ICgpID0+IHsKICAgIHRyeSB7CiAgICAgIGlmICh0eXBlb2YgYXBwTW9kZSAhPT0gJ3VuZGVm
;aW5lZCcgJiYgYXBwTW9kZSAhPT0gJ2ZpbGUnKSByZXR1cm47CiAgICAgIGRvU2VhcmNoKCk7CiAgICB9IGNhdGNoIChfKSB7fQogIH07CiAgLy8g6L+b5YWl
;5pe26Iul5bey5pyJ6YCJ5Lit562b6YCJ77yM5Li75Yqo5bim5p2h5Lu25pCc57Si77yI6KaG55uWIEFISyDnqbrmn6Xor6LvvIkKICBzZXRUaW1lb3V0KCgp
;ID0+IHsgdHJ5IHsgd2luZG93Ll9fcmVzeW5jU2VhcmNoKCk7IH0gY2F0Y2ggKF8pIHt9IH0sIDI4MCk7CiAgc2V0VGltZW91dCgoKSA9PiB7IHRyeSB7IHdp
;bmRvdy5fX3Jlc3luY1NlYXJjaCgpOyB9IGNhdGNoIChfKSB7fSB9LCA5MDApOwp9KSgpOwo8L3NjcmlwdD4KPC9ib2R5Pgo8L2h0bWw+Cg==
;########################################################################################################### local_search_index.html

