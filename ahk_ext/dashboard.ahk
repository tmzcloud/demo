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
;PCFET0NUWVBFIGh0bWw+CjxodG1sIGxhbmc9InpoLUNOIj4KPGhlYWQ+CjxtZXRhIGNoYXJzZXQ9IlVURi04Ij4KPG1ldGEgbmFt
;ZT0idmlld3BvcnQiIGNvbnRlbnQ9IndpZHRoPWRldmljZS13aWR0aCwgaW5pdGlhbC1zY2FsZT0xIj4KPHRpdGxlPuS7quihqOeb
;mDwvdGl0bGU+CjwhLS0gbG9jYWxfc2VhcmNoX3VpOjIwMjYtMDktMTdhIC0tPgo8c3R5bGU+Cjpyb290IHsKICAtLWJnOiAjZjNm
;NGY3OwogIC0tcGFuZWw6ICNmZmZmZmY7CiAgLS1saW5lOiAjZTZlOGVlOwogIC0tdHh0OiAjMWYyNDMwOwogIC0tdHh0MjogIzZi
;NzI4NTsKICAtLXR4dDM6ICM5YWExYjI7CiAgLS1hY2M6ICMzYjgyZjY7CiAgLS1hY2MyOiAjMjU2M2ViOwogIC0tbmFtZTogIzEx
;MTgyNzsKICAtLW5hbWUtZXh0OiAjZWE1ODBjOwogIC0taGw6ICNmZWYwOGE7CiAgLS1obC10ZXh0OiAjODU0ZDBlOwogIC0tc2Vs
;OiAjZWVmMWY2OwogIC0tc2lkZTogI2Y1ZjZmOTsKICAtLWNocm9tZTogI2Y1ZjZmOTsKICAtLXNpZGUtdzogMTQ4cHg7CiAgLS1y
;aW5nOiAjZTQyMDc5OwogIC0tc2hhZG93OiAwIDEwcHggMzBweCByZ2JhKDIwLCAyOCwgNDUsIC4wOCk7CiAgLS1yOiAxMHB4Owog
;IGZvbnQtZmFtaWx5OiAiU2Vnb2UgVUkiLCAiTWljcm9zb2Z0IFlhSGVpIFVJIiwgIlBpbmdGYW5nIFNDIiwgc2Fucy1zZXJpZjsK
;fQoqIHsgYm94LXNpemluZzogYm9yZGVyLWJveDsgfQpodG1sLCBib2R5IHsgbWFyZ2luOiAwOyBoZWlnaHQ6IDEwMCU7IGJhY2tn
;cm91bmQ6IHZhcigtLWJnKTsgY29sb3I6IHZhcigtLXR4dCk7IG92ZXJmbG93OiBoaWRkZW47IH0KYnV0dG9uLCBpbnB1dCB7IGZv
;bnQ6IGluaGVyaXQ7IH0KI2FwcCB7IGRpc3BsYXk6IGZsZXg7IGZsZXgtZGlyZWN0aW9uOiBjb2x1bW47IGhlaWdodDogMTAwJTsg
;fQoKLyog5YWo5bGA77ya566A57qm57qk57uG57q15ZCR5rua5Yqo5p2hICovCiogewogIHNjcm9sbGJhci13aWR0aDogdGhpbjsK
;ICBzY3JvbGxiYXItY29sb3I6ICNjMGM0Y2MgdHJhbnNwYXJlbnQ7Cn0KKjo6LXdlYmtpdC1zY3JvbGxiYXIgeyB3aWR0aDogNHB4
;OyBoZWlnaHQ6IDRweDsgfQoqOjotd2Via2l0LXNjcm9sbGJhci10cmFjayB7IGJhY2tncm91bmQ6IHRyYW5zcGFyZW50OyB9Cio6
;Oi13ZWJraXQtc2Nyb2xsYmFyLXRodW1iIHsKICBiYWNrZ3JvdW5kOiAjYzBjNGNjOyBib3JkZXItcmFkaXVzOiA5OTlweDsgYm9y
;ZGVyOiAwOwogIG1pbi1oZWlnaHQ6IDI0cHg7Cn0KKjo6LXdlYmtpdC1zY3JvbGxiYXItdGh1bWI6aG92ZXIgeyBiYWNrZ3JvdW5k
;OiAjOWFhMWIyOyB9Cio6Oi13ZWJraXQtc2Nyb2xsYmFyLWNvcm5lciB7IGJhY2tncm91bmQ6IHRyYW5zcGFyZW50OyB9CgovKiBp
;bmRleGluZyAqLwojYm9vdCB7CiAgZGlzcGxheTogbm9uZTsgZmxleDogMTsgYWxpZ24taXRlbXM6IGNlbnRlcjsganVzdGlmeS1j
;b250ZW50OiBjZW50ZXI7CiAgZmxleC1kaXJlY3Rpb246IGNvbHVtbjsgZ2FwOiAyOHB4OyBiYWNrZ3JvdW5kOiAjZmZmOwp9CiNi
;b290Lm9uIHsgZGlzcGxheTogZmxleDsgfQoucmluZy13cmFwIHsgd2lkdGg6IDE2OHB4OyBoZWlnaHQ6IDE2OHB4OyBwb3NpdGlv
;bjogcmVsYXRpdmU7IH0KLnJpbmctd3JhcCBzdmcgeyB3aWR0aDogMTAwJTsgaGVpZ2h0OiAxMDAlOyB0cmFuc2Zvcm06IHJvdGF0
;ZSgtOTBkZWcpOyB9Ci5yaW5nLWJnIHsgZmlsbDogbm9uZTsgc3Ryb2tlOiAjZWNlZmY0OyBzdHJva2Utd2lkdGg6IDg7IH0KLnJp
;bmctZmcgeyBmaWxsOiBub25lOyBzdHJva2U6IHZhcigtLXJpbmcpOyBzdHJva2Utd2lkdGg6IDg7IHN0cm9rZS1saW5lY2FwOiBy
;b3VuZDsKICB0cmFuc2l0aW9uOiBzdHJva2UtZGFzaG9mZnNldCAuMzVzIGVhc2U7IH0KLnJpbmctbGFiZWwgewogIHBvc2l0aW9u
;OiBhYnNvbHV0ZTsgaW5zZXQ6IDA7IGRpc3BsYXk6IGZsZXg7IGZsZXgtZGlyZWN0aW9uOiBjb2x1bW47CiAgYWxpZ24taXRlbXM6
;IGNlbnRlcjsganVzdGlmeS1jb250ZW50OiBjZW50ZXI7IGdhcDogNnB4Owp9Ci5yaW5nLWxhYmVsIC50MSB7IGZvbnQtc2l6ZTog
;MTZweDsgZm9udC13ZWlnaHQ6IDYwMDsgfQoucmluZy1sYWJlbCAudDIgeyBmb250LXNpemU6IDI4cHg7IGZvbnQtd2VpZ2h0OiA3
;MDA7IGNvbG9yOiAjMTExODI3OyB9Ci5ib290LWhpbnQgeyBjb2xvcjogdmFyKC0tdHh0Mik7IGZvbnQtc2l6ZTogMTNweDsgbWF4
;LXdpZHRoOiA1MjBweDsgdGV4dC1hbGlnbjogY2VudGVyOyBsaW5lLWhlaWdodDogMS42OyB9Ci5ib290LWhpbnQgYSB7IGNvbG9y
;OiB2YXIoLS1hY2MpOyB0ZXh0LWRlY29yYXRpb246IG5vbmU7IGN1cnNvcjogcG9pbnRlcjsgfQouYm9vdC1oaW50IGE6aG92ZXIg
;eyB0ZXh0LWRlY29yYXRpb246IHVuZGVybGluZTsgfQoKLyogdGl0bGViYXIgPSDku6rooajnm5jpgqPkuIDooYzvvJvmipjlj6Dn
;rq3lpLTkuI7kuIvmlrnmkJzntKLmoYbliJflr7npvZAgKi8KI3RpdGxlYmFyIHsKICBkaXNwbGF5OiBmbGV4OyBhbGlnbi1pdGVt
;czogY2VudGVyOyBnYXA6IDA7IGZsZXgtc2hyaW5rOiAwOwogIG1pbi1oZWlnaHQ6IDM2cHg7IHBhZGRpbmc6IDA7IGJveC1zaXpp
;bmc6IGJvcmRlci1ib3g7CiAgYmFja2dyb3VuZDogdmFyKC0tY2hyb21lKTsgYm9yZGVyLWJvdHRvbTogMDsKICAtd2Via2l0LWFw
;cC1yZWdpb246IGRyYWc7IGFwcC1yZWdpb246IGRyYWc7IHVzZXItc2VsZWN0OiBub25lOwp9CiN0aXRsZWJhciAubm8tZHJhZywg
;I3RpdGxlYmFyIGJ1dHRvbiB7CiAgLXdlYmtpdC1hcHAtcmVnaW9uOiBuby1kcmFnOyBhcHAtcmVnaW9uOiBuby1kcmFnOwp9CiN0
;aXRsZWJhciAudGItYnJhbmQgewogIGRpc3BsYXk6IGlubGluZS1mbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBnYXA6IDhweDsg
;ZmxleC1zaHJpbms6IDA7CiAgd2lkdGg6IHZhcigtLXNpZGUtdyk7IHBhZGRpbmc6IDAgMTBweDsgYm94LXNpemluZzogYm9yZGVy
;LWJveDsKICBjb2xvcjogdmFyKC0tdHh0KTsgZm9udC1zaXplOiAxM3B4OyBmb250LXdlaWdodDogNjUwOyBsZXR0ZXItc3BhY2lu
;ZzogLjAxZW07Cn0KI3RpdGxlYmFyIC50Yi1pY28gewogIHdpZHRoOiAxNnB4OyBoZWlnaHQ6IDE2cHg7IGRpc3BsYXk6IGJsb2Nr
;OyBjb2xvcjogIzA0Nzg1NzsgZmxleC1zaHJpbms6IDA7Cn0KI3RpdGxlYmFyIC50Yi1zcGFjZSB7IGZsZXg6IDE7IG1pbi13aWR0
;aDogOHB4OyBhbGlnbi1zZWxmOiBzdHJldGNoOyB9CiN0aXRsZWJhciAudGItd2luIHsKICBkaXNwbGF5OiBmbGV4OyBhbGlnbi1p
;dGVtczogc3RyZXRjaDsgZmxleC1zaHJpbms6IDA7IGhlaWdodDogMzZweDsKfQojdGl0bGViYXIgLnRiLXdpbiBidXR0b24gewog
;IHdpZHRoOiA0NnB4OyBoZWlnaHQ6IDEwMCU7IHBhZGRpbmc6IDA7IGJvcmRlcjogMDsgYmFja2dyb3VuZDogdHJhbnNwYXJlbnQ7
;CiAgY29sb3I6IHZhcigtLXR4dDIpOyBjdXJzb3I6IHBvaW50ZXI7CiAgZGlzcGxheTogaW5saW5lLWZsZXg7IGFsaWduLWl0ZW1z
;OiBjZW50ZXI7IGp1c3RpZnktY29udGVudDogY2VudGVyOwp9CiN0aXRsZWJhciAudGItd2luIGJ1dHRvbjpob3ZlciB7IGJhY2tn
;cm91bmQ6ICNlOGViZjA7IGNvbG9yOiB2YXIoLS10eHQpOyB9CiN0aXRsZWJhciAudGItd2luICNidG4td2luLWNsb3NlOmhvdmVy
;IHsgYmFja2dyb3VuZDogI2U4MTEyMzsgY29sb3I6ICNmZmY7IH0KI3RpdGxlYmFyIC50Yi13aW4gYnV0dG9uIHN2ZyB7IHdpZHRo
;OiAxMHB4OyBoZWlnaHQ6IDEwcHg7IGRpc3BsYXk6IGJsb2NrOyB9CiNmaWx0ZXItcmFpbCB7CiAgZGlzcGxheTogZmxleDsgYWxp
;Z24taXRlbXM6IGNlbnRlcjsgZ2FwOiA4cHg7IGZsZXgtc2hyaW5rOiAxOyBtaW4td2lkdGg6IDA7CiAgcGFkZGluZzogNHB4IDA7
;IG1hcmdpbjogMDsKfQojYXBwLmJvb3RpbmcgI2ZpbHRlci1yYWlsLAojYXBwLmhpZGUtZmlsdGVycyAjZmlsdGVyLXJhaWwgeyBk
;aXNwbGF5OiBub25lICFpbXBvcnRhbnQ7IH0KI2J0bi1maWx0ZXItdG9nZ2xlIHsKICBmbGV4LXNocmluazogMDsgd2lkdGg6IDIy
;cHg7IGhlaWdodDogMjJweDsgcGFkZGluZzogMDsKICBib3JkZXI6IDA7IGJvcmRlci1yYWRpdXM6IDZweDsgYmFja2dyb3VuZDog
;dHJhbnNwYXJlbnQ7CiAgY29sb3I6IHZhcigtLXR4dDMpOyBjdXJzb3I6IHBvaW50ZXI7CiAgZGlzcGxheTogaW5saW5lLWZsZXg7
;IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGp1c3RpZnktY29udGVudDogY2VudGVyOwp9CiNidG4tZmlsdGVyLXRvZ2dsZTpob3ZlciB7
;IGJhY2tncm91bmQ6ICNlZWYxZjY7IGNvbG9yOiB2YXIoLS10eHQpOyB9CiNidG4tZmlsdGVyLXRvZ2dsZS5vcGVuIHsgY29sb3I6
;ICMwNDc4NTc7IGJhY2tncm91bmQ6ICNlY2ZkZjU7IH0KI2J0bi1maWx0ZXItdG9nZ2xlLmhhcy1hY3RpdmUgewogIGNvbG9yOiAj
;ZmZmOyBiYWNrZ3JvdW5kOiAjMTZhMzRhOwp9CiNidG4tZmlsdGVyLXRvZ2dsZS5oYXMtYWN0aXZlOmhvdmVyIHsgYmFja2dyb3Vu
;ZDogIzE1ODAzZDsgY29sb3I6ICNmZmY7IH0KI2J0bi1maWx0ZXItdG9nZ2xlLmhhcy1hY3RpdmUub3BlbiB7IGNvbG9yOiAjZmZm
;OyBiYWNrZ3JvdW5kOiAjMTZhMzRhOyB9CiNidG4tZmlsdGVyLXRvZ2dsZSBzdmcgewogIHdpZHRoOiAxMnB4OyBoZWlnaHQ6IDEy
;cHg7IGRpc3BsYXk6IGJsb2NrOwogIHRyYW5zaXRpb246IHRyYW5zZm9ybSAuMTVzIGVhc2U7CiAgdHJhbnNmb3JtOiByb3RhdGUo
;LTkwZGVnKTsKfQojYnRuLWZpbHRlci10b2dnbGUub3BlbiBzdmcgeyB0cmFuc2Zvcm06IHJvdGF0ZSgwZGVnKTsgfQojZmlsdGVy
;LWJhciB7CiAgZGlzcGxheTogbm9uZTsgZmxleC13cmFwOiB3cmFwOyBhbGlnbi1pdGVtczogY2VudGVyOyBnYXA6IDZweDsgbWlu
;LXdpZHRoOiAwOwp9CiNmaWx0ZXItcmFpbC5vcGVuICNmaWx0ZXItYmFyIHsgZGlzcGxheTogZmxleDsgfQouZmlsdGVyLWNoaXAg
;ewogIGhlaWdodDogMjJweDsgcGFkZGluZzogMCAxMHB4OyBib3JkZXI6IDFweCBzb2xpZCB2YXIoLS1saW5lKTsKICBib3JkZXIt
;cmFkaXVzOiA5OTlweDsgYmFja2dyb3VuZDogI2ZiZmJmZDsgY29sb3I6IHZhcigtLXR4dDIpOwogIGZvbnQtc2l6ZTogMTJweDsg
;Y3Vyc29yOiBwb2ludGVyOyBsaW5lLWhlaWdodDogMjBweDsgd2hpdGUtc3BhY2U6IG5vd3JhcDsKfQouZmlsdGVyLWNoaXA6aG92
;ZXIgeyBiYWNrZ3JvdW5kOiAjZWVmMWY2OyBjb2xvcjogdmFyKC0tdHh0KTsgfQouZmlsdGVyLWNoaXAub24gewogIGJhY2tncm91
;bmQ6ICNlY2ZkZjU7IGJvcmRlci1jb2xvcjogIzg2ZWZhYzsgY29sb3I6ICMwNDc4NTc7IGZvbnQtd2VpZ2h0OiA2MDA7Cn0KCi8q
;IGNocm9tZSAqLwojY2hyb21lIHsgZGlzcGxheTogZmxleDsgZmxleC1kaXJlY3Rpb246IGNvbHVtbjsgZmxleDogMTsgbWluLWhl
;aWdodDogMDsgfQojY2hyb21lLmhpZGRlbiB7IGRpc3BsYXk6IG5vbmU7IH0KI3RvcCB7CiAgaGVpZ2h0OiA0OHB4OyBkaXNwbGF5
;OiBncmlkOwogIGdyaWQtdGVtcGxhdGUtY29sdW1uczogdmFyKC0tc2lkZS13KSBtaW5tYXgoMCwgMWZyKTsKICBhbGlnbi1pdGVt
;czogc3RyZXRjaDsgcGFkZGluZzogMCAxMHB4IDAgMDsgYmFja2dyb3VuZDogdmFyKC0tY2hyb21lKTsKICBib3JkZXItYm90dG9t
;OiAwOyBib3gtc2l6aW5nOiBib3JkZXItYm94OwogIC13ZWJraXQtYXBwLXJlZ2lvbjogZHJhZzsgYXBwLXJlZ2lvbjogZHJhZzsK
;fQojdG9wIC5uby1kcmFnLCAjdG9wIGJ1dHRvbiwgI3RvcCBpbnB1dCB7CiAgLXdlYmtpdC1hcHAtcmVnaW9uOiBuby1kcmFnOyBh
;cHAtcmVnaW9uOiBuby1kcmFnOwp9CiNkcml2ZS13cmFwIHsKICBwb3NpdGlvbjogcmVsYXRpdmU7IHdpZHRoOiAxMDAlOwogIGJv
;cmRlci1yaWdodDogMDsgYmFja2dyb3VuZDogdmFyKC0tY2hyb21lKTsKICBkaXNwbGF5OiBmbGV4OyBhbGlnbi1pdGVtczogY2Vu
;dGVyOwp9CiNidG4tZHJpdmUgewogIGRpc3BsYXk6IGZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGdhcDogOHB4OwogIHdpZHRo
;OiAxMDAlOyBoZWlnaHQ6IDEwMCU7IHBhZGRpbmc6IDAgMTBweDsKICBib3JkZXI6IDA7IGJvcmRlci1yYWRpdXM6IDA7IGJhY2tn
;cm91bmQ6IHRyYW5zcGFyZW50OwogIGNvbG9yOiB2YXIoLS10eHQpOyBmb250LXNpemU6IDEzLjVweDsgZm9udC13ZWlnaHQ6IDYw
;MDsKICBjdXJzb3I6IHBvaW50ZXI7IHRleHQtYWxpZ246IGxlZnQ7Cn0KI2J0bi1kcml2ZTpob3ZlciB7IGJhY2tncm91bmQ6ICNl
;ZWYxZjY7IGNvbG9yOiB2YXIoLS1hY2MyKTsgfQojYnRuLWRyaXZlIC5kcml2ZS1pY28gewogIHdpZHRoOiAyMHB4OyBoZWlnaHQ6
;IDIwcHg7IG9iamVjdC1maXQ6IGNvbnRhaW47IGZsZXgtc2hyaW5rOiAwOwogIGJhY2tncm91bmQ6IHRyYW5zcGFyZW50Owp9CiNi
;dG4tZHJpdmUgLmRyaXZlLWljby5oaWRkZW4geyBkaXNwbGF5OiBub25lOyB9CiNidG4tZHJpdmUgLmNhcmV0IHsgZm9udC1zaXpl
;OiAxMHB4OyBjb2xvcjogdmFyKC0tdHh0Myk7IG1hcmdpbi1sZWZ0OiBhdXRvOyB9CiNkcml2ZS1sYWJlbCB7IG92ZXJmbG93OiBo
;aWRkZW47IHRleHQtb3ZlcmZsb3c6IGVsbGlwc2lzOyB3aGl0ZS1zcGFjZTogbm93cmFwOyB9CiNkcml2ZS1tZW51IHsKICBkaXNw
;bGF5OiBub25lOyBwb3NpdGlvbjogYWJzb2x1dGU7IHRvcDogMTAwJTsgbGVmdDogMDsgcmlnaHQ6IDA7IHotaW5kZXg6IDQwOwog
;IHdpZHRoOiAxMDAlOyBtYXgtaGVpZ2h0OiAzMjBweDsgb3ZlcmZsb3c6IGF1dG87CiAgYmFja2dyb3VuZDogI2ZmZjsgYm9yZGVy
;OiAxcHggc29saWQgdmFyKC0tbGluZSk7IGJvcmRlci10b3A6IDA7CiAgYm94LXNoYWRvdzogdmFyKC0tc2hhZG93KTsgcGFkZGlu
;ZzogNHB4OyBib3JkZXItcmFkaXVzOiAwIDAgOHB4IDhweDsKfQojZHJpdmUtbWVudS5vbiB7IGRpc3BsYXk6IGJsb2NrOyB9CiNk
;cml2ZS1tZW51IGJ1dHRvbiB7CiAgZGlzcGxheTogZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsgZ2FwOiA4cHg7IHdpZHRoOiAx
;MDAlOwogIHRleHQtYWxpZ246IGxlZnQ7IGJvcmRlcjogMDsgYmFja2dyb3VuZDogdHJhbnNwYXJlbnQ7CiAgcGFkZGluZzogOHB4
;IDEwcHg7IGJvcmRlci1yYWRpdXM6IDZweDsgY3Vyc29yOiBwb2ludGVyOyBjb2xvcjogdmFyKC0tdHh0KTsgZm9udC1zaXplOiAx
;M3B4Owp9CiNkcml2ZS1tZW51IGJ1dHRvbiBpbWcgewogIHdpZHRoOiAyMHB4OyBoZWlnaHQ6IDIwcHg7IG9iamVjdC1maXQ6IGNv
;bnRhaW47IGZsZXgtc2hyaW5rOiAwOyBiYWNrZ3JvdW5kOiB0cmFuc3BhcmVudDsKfQojZHJpdmUtbWVudSBidXR0b246aG92ZXIg
;eyBiYWNrZ3JvdW5kOiAjZWVmMmZmOyB9CiNkcml2ZS1tZW51IGJ1dHRvbi5vbiB7IGJhY2tncm91bmQ6ICNlZmY2ZmY7IGNvbG9y
;OiB2YXIoLS1hY2MyKTsgZm9udC13ZWlnaHQ6IDYwMDsgfQojdG9wLXJlc3QgewogIGRpc3BsYXk6IGdyaWQ7CiAgZ3JpZC10ZW1w
;bGF0ZS1jb2x1bW5zOiBtaW5tYXgoMjgwcHgsIDEuMWZyKSBtaW5tYXgoMzIwcHgsIDEuMmZyKTsKICBhbGlnbi1pdGVtczogc3Ry
;ZXRjaDsgbWluLXdpZHRoOiAwOyBtaW4taGVpZ2h0OiAwOwogIGJhY2tncm91bmQ6IHZhcigtLWNocm9tZSk7Cn0KI3RvcC5tb2Rl
;LXRvb2wgI3RvcC1yZXN0IHsKICBncmlkLXRlbXBsYXRlLWNvbHVtbnM6IDFmcjsKfQovKiDlhbPogZTlj6Xmn4TvvJrku4XmkJzn
;tKLmoYbljaDkuIDljYrvvIzliJfooajku43lhajlrr0gKi8KI3RvcC5tb2RlLWhhbmRsZSAjdG9wLXJlc3QgewogIGdyaWQtdGVt
;cGxhdGUtY29sdW1uczogbWlubWF4KDI4MHB4LCA1MCUpOwogIGp1c3RpZnktY29udGVudDogc3RhcnQ7Cn0KI3NlYXJjaC13cmFw
;IHsKICBkaXNwbGF5OiBmbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBtaW4td2lkdGg6IDA7IGhlaWdodDogMTAwJTsKICBwYWRk
;aW5nOiAwOyBib3JkZXItcmlnaHQ6IDA7IGJhY2tncm91bmQ6IHZhcigtLWNocm9tZSk7Cn0KI2ZpbHRlci1zZXR0aW5ncyB7CiAg
;ZGlzcGxheTogbm9uZTsgcG9zaXRpb246IGZpeGVkOyBpbnNldDogMDsgei1pbmRleDogMzAwOwogIGJhY2tncm91bmQ6IHJnYmEo
;MTUsIDIzLCA0MiwgLjI4KTsgYWxpZ24taXRlbXM6IGNlbnRlcjsganVzdGlmeS1jb250ZW50OiBjZW50ZXI7Cn0KI2ZpbHRlci1z
;ZXR0aW5ncy5vbiB7IGRpc3BsYXk6IGZsZXg7IH0KI2ZpbHRlci1zZXR0aW5ncyAuZnMtY2FyZCB7CiAgd2lkdGg6IG1pbig0NjBw
;eCwgOTJ2dyk7IG1heC1oZWlnaHQ6IG1pbig2MjBweCwgODh2aCk7CiAgYmFja2dyb3VuZDogI2ZmZjsgYm9yZGVyLXJhZGl1czog
;MTRweDsgYm9yZGVyOiAxcHggc29saWQgdmFyKC0tbGluZSk7CiAgYm94LXNoYWRvdzogMCAxOHB4IDQwcHggcmdiYSgxNSwgMjMs
;IDQyLCAuMTgpOwogIGRpc3BsYXk6IGZsZXg7IGZsZXgtZGlyZWN0aW9uOiBjb2x1bW47IG92ZXJmbG93OiBoaWRkZW47Cn0KI2Zp
;bHRlci1zZXR0aW5ncyAuZnMtaGQgewogIGRpc3BsYXk6IGZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGp1c3RpZnktY29udGVu
;dDogc3BhY2UtYmV0d2VlbjsKICBwYWRkaW5nOiAxNHB4IDE2cHg7IGJvcmRlci1ib3R0b206IDFweCBzb2xpZCB2YXIoLS1saW5l
;KTsgZm9udC13ZWlnaHQ6IDYwMDsKfQojZmlsdGVyLXNldHRpbmdzIC5mcy1oZCBidXR0b24gewogIGJvcmRlcjogMDsgYmFja2dy
;b3VuZDogdHJhbnNwYXJlbnQ7IGNvbG9yOiB2YXIoLS10eHQyKTsgY3Vyc29yOiBwb2ludGVyOyBmb250LXNpemU6IDE4cHg7IGxp
;bmUtaGVpZ2h0OiAxOwp9CiNmaWx0ZXItc2V0dGluZ3MgLmZzLWJkIHsKICBwYWRkaW5nOiAxNHB4IDE2cHg7IG92ZXJmbG93OiBh
;dXRvOyBkaXNwbGF5OiBmbGV4OyBmbGV4LWRpcmVjdGlvbjogY29sdW1uOyBnYXA6IDEycHg7Cn0KI2ZpbHRlci1zZXR0aW5ncyAu
;ZnMtaGludCB7IGZvbnQtc2l6ZTogMTJweDsgY29sb3I6IHZhcigtLXR4dDMpOyBsaW5lLWhlaWdodDogMS41OyB9CiNmaWx0ZXIt
;c2V0dGluZ3MgLmZzLWxpc3QgeyBkaXNwbGF5OiBmbGV4OyBmbGV4LWRpcmVjdGlvbjogY29sdW1uOyBnYXA6IDEwcHg7IH0KI2Zp
;bHRlci1zZXR0aW5ncyAuZnMtYmxvY2sgewogIHBvc2l0aW9uOiByZWxhdGl2ZTsgZGlzcGxheTogZ3JpZDsKICBncmlkLXRlbXBs
;YXRlLWNvbHVtbnM6IDI4cHggbWlubWF4KDAsIDFmcikgYXV0bzsKICBnYXA6IDhweCAxMHB4OyBhbGlnbi1pdGVtczogc3RhcnQ7
;CiAgcGFkZGluZzogMTRweCAzNnB4IDEycHggMTJweDsKICBib3JkZXI6IDFweCBzb2xpZCAjZDdkZGU4OyBib3JkZXItcmFkaXVz
;OiAxMnB4OwogIGJhY2tncm91bmQ6IGxpbmVhci1ncmFkaWVudCgxODBkZWcsICNmZmZmZmYgMCUsICNmN2Y5ZmMgMTAwJSk7CiAg
;Ym94LXNoYWRvdzogMCAxcHggMCByZ2JhKDI1NSwyNTUsMjU1LC45KSBpbnNldCwgMCA0cHggMTJweCByZ2JhKDE1LCAyMywgNDIs
;IC4wNSk7CiAgYm9yZGVyLWxlZnQ6IDNweCBzb2xpZCAjODZlZmFjOwp9CiNmaWx0ZXItc2V0dGluZ3MgLmZzLWJsb2NrLm9mZiB7
;CiAgb3BhY2l0eTogLjYyOyBib3JkZXItbGVmdC1jb2xvcjogI2NiZDVlMTsKICBiYWNrZ3JvdW5kOiBsaW5lYXItZ3JhZGllbnQo
;MTgwZGVnLCAjZjhmYWZjIDAlLCAjZjFmNWY5IDEwMCUpOwp9CiNmaWx0ZXItc2V0dGluZ3MgLmZzLWJsb2NrIC5mcy1kZWwgewog
;IHBvc2l0aW9uOiBhYnNvbHV0ZTsgdG9wOiA4cHg7IHJpZ2h0OiA4cHg7CiAgd2lkdGg6IDIycHg7IGhlaWdodDogMjJweDsgcGFk
;ZGluZzogMDsgYm9yZGVyOiAwOyBib3JkZXItcmFkaXVzOiA2cHg7CiAgYmFja2dyb3VuZDogdHJhbnNwYXJlbnQ7IGNvbG9yOiB2
;YXIoLS10eHQzKTsgY3Vyc29yOiBwb2ludGVyOwogIGRpc3BsYXk6IGlubGluZS1mbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBq
;dXN0aWZ5LWNvbnRlbnQ6IGNlbnRlcjsKfQojZmlsdGVyLXNldHRpbmdzIC5mcy1ibG9jayAuZnMtZGVsOmhvdmVyIHsgYmFja2dy
;b3VuZDogI2ZlZTJlMjsgY29sb3I6ICNiOTFjMWM7IH0KI2ZpbHRlci1zZXR0aW5ncyAuZnMtYmxvY2sgLmZzLWRlbCBzdmcgeyB3
;aWR0aDogMTJweDsgaGVpZ2h0OiAxMnB4OyBkaXNwbGF5OiBibG9jazsgfQojZmlsdGVyLXNldHRpbmdzIC5mcy1vcmQgewogIGRp
;c3BsYXk6IGZsZXg7IGZsZXgtZGlyZWN0aW9uOiBjb2x1bW47IGdhcDogMnB4OyBwYWRkaW5nLXRvcDogMnB4Owp9CiNmaWx0ZXIt
;c2V0dGluZ3MgLmZzLW9yZCBidXR0b24gewogIHdpZHRoOiAyNHB4OyBoZWlnaHQ6IDIwcHg7IHBhZGRpbmc6IDA7IGJvcmRlcjog
;MDsgYm9yZGVyLXJhZGl1czogNXB4OwogIGJhY2tncm91bmQ6ICNlZWYyZjc7IGNvbG9yOiB2YXIoLS10eHQyKTsgY3Vyc29yOiBw
;b2ludGVyOwogIGRpc3BsYXk6IGlubGluZS1mbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBqdXN0aWZ5LWNvbnRlbnQ6IGNlbnRl
;cjsKfQojZmlsdGVyLXNldHRpbmdzIC5mcy1vcmQgYnV0dG9uOmhvdmVyIHsgYmFja2dyb3VuZDogI2UyZThmMDsgY29sb3I6IHZh
;cigtLXR4dCk7IH0KI2ZpbHRlci1zZXR0aW5ncyAuZnMtb3JkIGJ1dHRvbjpkaXNhYmxlZCB7IG9wYWNpdHk6IC4yODsgY3Vyc29y
;OiBkZWZhdWx0OyB9CiNmaWx0ZXItc2V0dGluZ3MgLmZzLW9yZCBidXR0b24gc3ZnIHsgd2lkdGg6IDExcHg7IGhlaWdodDogMTFw
;eDsgZGlzcGxheTogYmxvY2s7IH0KI2ZpbHRlci1zZXR0aW5ncyAuZnMtbWFpbiB7IG1pbi13aWR0aDogMDsgZGlzcGxheTogZmxl
;eDsgZmxleC1kaXJlY3Rpb246IGNvbHVtbjsgZ2FwOiA0cHg7IH0KI2ZpbHRlci1zZXR0aW5ncyAuZnMtdGl0bGUtcm93IHsKICBk
;aXNwbGF5OiBmbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBnYXA6IDhweDsgbWluLXdpZHRoOiAwOwp9CiNmaWx0ZXItc2V0dGlu
;Z3MgLmZzLXRpdGxlIHsKICBmb250LXNpemU6IDEzLjVweDsgZm9udC13ZWlnaHQ6IDcwMDsgY29sb3I6IHZhcigtLXR4dCk7CiAg
;b3ZlcmZsb3c6IGhpZGRlbjsgdGV4dC1vdmVyZmxvdzogZWxsaXBzaXM7IHdoaXRlLXNwYWNlOiBub3dyYXA7Cn0KI2ZpbHRlci1z
;ZXR0aW5ncyAuZnMtdGFnIHsKICBmbGV4LXNocmluazogMDsgZm9udC1zaXplOiAxMHB4OyBmb250LXdlaWdodDogNjAwOyBsaW5l
;LWhlaWdodDogMTsKICBwYWRkaW5nOiAzcHggNnB4OyBib3JkZXItcmFkaXVzOiA5OTlweDsKICBiYWNrZ3JvdW5kOiAjZWNmZGY1
;OyBjb2xvcjogIzA0Nzg1NzsgYm9yZGVyOiAxcHggc29saWQgI2E3ZjNkMDsKfQojZmlsdGVyLXNldHRpbmdzIC5mcy1ibG9jay5v
;ZmYgLmZzLXRhZyB7CiAgYmFja2dyb3VuZDogI2YxZjVmOTsgY29sb3I6ICM2NDc0OGI7IGJvcmRlci1jb2xvcjogI2UyZThmMDsK
;fQojZmlsdGVyLXNldHRpbmdzIC5mcy1yZWdleCB7CiAgZm9udC1zaXplOiAxMXB4OyBjb2xvcjogdmFyKC0tdHh0Myk7IGxpbmUt
;aGVpZ2h0OiAxLjM1OwogIHdvcmQtYnJlYWs6IGJyZWFrLWFsbDsgZm9udC1mYW1pbHk6IENvbnNvbGFzLCAiQ2FzY2FkaWEgTW9u
;byIsIG1vbm9zcGFjZTsKfQojZmlsdGVyLXNldHRpbmdzIC5mcy1lbiB7CiAgZGlzcGxheTogZmxleDsgZmxleC1kaXJlY3Rpb246
;IGNvbHVtbjsgYWxpZ24taXRlbXM6IGZsZXgtZW5kOyBnYXA6IDRweDsKICBwYWRkaW5nLXRvcDogMnB4OyBwYWRkaW5nLXJpZ2h0
;OiA0cHg7Cn0KI2ZpbHRlci1zZXR0aW5ncyAuZnMtZW4gLmZzLWVuLWxhYiB7CiAgZm9udC1zaXplOiAxMHB4OyBjb2xvcjogdmFy
;KC0tdHh0Myk7IGxpbmUtaGVpZ2h0OiAxOyB3aGl0ZS1zcGFjZTogbm93cmFwOwp9CiNmaWx0ZXItc2V0dGluZ3MgLmZzLXN3aXRj
;aCB7CiAgcG9zaXRpb246IHJlbGF0aXZlOyB3aWR0aDogMzZweDsgaGVpZ2h0OiAyMHB4OyBmbGV4LXNocmluazogMDsKICBib3Jk
;ZXI6IDA7IGJvcmRlci1yYWRpdXM6IDk5OXB4OyBiYWNrZ3JvdW5kOiAjY2JkNWUxOyBjdXJzb3I6IHBvaW50ZXI7IHBhZGRpbmc6
;IDA7Cn0KI2ZpbHRlci1zZXR0aW5ncyAuZnMtc3dpdGNoLm9uIHsgYmFja2dyb3VuZDogIzM0ZDM5OTsgfQojZmlsdGVyLXNldHRp
;bmdzIC5mcy1zd2l0Y2ggaSB7CiAgcG9zaXRpb246IGFic29sdXRlOyB0b3A6IDJweDsgbGVmdDogMnB4OyB3aWR0aDogMTZweDsg
;aGVpZ2h0OiAxNnB4OwogIGJvcmRlci1yYWRpdXM6IDUwJTsgYmFja2dyb3VuZDogI2ZmZjsgYm94LXNoYWRvdzogMCAxcHggM3B4
;IHJnYmEoMTUsMjMsNDIsLjIpOwogIHRyYW5zaXRpb246IHRyYW5zZm9ybSAuMTVzIGVhc2U7IHBvaW50ZXItZXZlbnRzOiBub25l
;Owp9CiNmaWx0ZXItc2V0dGluZ3MgLmZzLXN3aXRjaC5vbiBpIHsgdHJhbnNmb3JtOiB0cmFuc2xhdGVYKDE2cHgpOyB9CiNmaWx0
;ZXItc2V0dGluZ3MgLmZzLWZvcm0gewogIGRpc3BsYXk6IGdyaWQ7IGdhcDogOHB4OyBwYWRkaW5nOiAxMnB4OyBib3JkZXItcmFk
;aXVzOiAxMnB4OwogIGJvcmRlcjogMXB4IGRhc2hlZCAjYzVjZWRkOyBiYWNrZ3JvdW5kOiAjZmFmYmZkOwp9CiNmaWx0ZXItc2V0
;dGluZ3MgbGFiZWwgeyBmb250LXNpemU6IDEycHg7IGNvbG9yOiB2YXIoLS10eHQyKTsgfQojZmlsdGVyLXNldHRpbmdzIGlucHV0
;IHsKICB3aWR0aDogMTAwJTsgaGVpZ2h0OiAzNHB4OyBib3JkZXI6IDFweCBzb2xpZCB2YXIoLS1saW5lKTsgYm9yZGVyLXJhZGl1
;czogOHB4OwogIHBhZGRpbmc6IDAgMTBweDsgZm9udC1zaXplOiAxM3B4OyBib3gtc2l6aW5nOiBib3JkZXItYm94OyBvdXRsaW5l
;OiBub25lOwp9CiNmaWx0ZXItc2V0dGluZ3MgaW5wdXQ6Zm9jdXMgeyBib3JkZXItY29sb3I6ICM5M2M1ZmQ7IGJveC1zaGFkb3c6
;IDAgMCAwIDNweCByZ2JhKDU5LDEzMCwyNDYsLjEyKTsgfQojZmlsdGVyLXNldHRpbmdzIC5mcy1hY3Rpb25zIHsgZGlzcGxheTog
;ZmxleDsgZ2FwOiA4cHg7IGp1c3RpZnktY29udGVudDogZmxleC1lbmQ7IG1hcmdpbi10b3A6IDRweDsgfQojZmlsdGVyLXNldHRp
;bmdzIC5mcy1hY3Rpb25zIGJ1dHRvbiB7CiAgaGVpZ2h0OiAzMnB4OyBwYWRkaW5nOiAwIDE0cHg7IGJvcmRlci1yYWRpdXM6IDhw
;eDsgYm9yZGVyOiAxcHggc29saWQgdmFyKC0tbGluZSk7CiAgYmFja2dyb3VuZDogI2ZmZjsgY3Vyc29yOiBwb2ludGVyOyBmb250
;LXNpemU6IDEzcHg7Cn0KI2ZpbHRlci1zZXR0aW5ncyAuZnMtYWN0aW9ucyAucHJpbWFyeSB7CiAgYmFja2dyb3VuZDogdmFyKC0t
;YWNjKTsgYm9yZGVyLWNvbG9yOiB2YXIoLS1hY2MpOyBjb2xvcjogI2ZmZjsKfQojZmlsdGVyLXNldHRpbmdzIC5mcy1hY3Rpb25z
;IC5wcmltYXJ5OmhvdmVyIHsgYmFja2dyb3VuZDogdmFyKC0tYWNjMik7IH0KI2ZpbHRlci1zZXR0aW5ncyAuZnMtZm9vdCB7CiAg
;ZGlzcGxheTogZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsganVzdGlmeS1jb250ZW50OiBzcGFjZS1iZXR3ZWVuOyBnYXA6IDEy
;cHg7CiAgcGFkZGluZzogMTBweCAxNnB4IDE0cHg7IGJvcmRlci10b3A6IDFweCBzb2xpZCB2YXIoLS1saW5lKTsKfQojZmlsdGVy
;LXNldHRpbmdzIC5mcy1mb290IGJ1dHRvbiB7CiAgYm9yZGVyOiAwOyBiYWNrZ3JvdW5kOiB0cmFuc3BhcmVudDsgY29sb3I6IHZh
;cigtLWFjYzIpOyBjdXJzb3I6IHBvaW50ZXI7IGZvbnQtc2l6ZTogMTJweDsgcGFkZGluZzogMDsKfQojZmlsdGVyLXNldHRpbmdz
;IC5mcy1mb290ICNmcy1yZXNldCB7CiAgY29sb3I6IHZhcigtLXR4dDIpOwp9CiNmaWx0ZXItc2V0dGluZ3MgLmZzLWZvb3QgI2Zz
;LXJlc2V0OmhvdmVyIHsgY29sb3I6ICNiOTFjMWM7IH0KI3RvcC5tb2RlLXRvb2wgI3NlYXJjaC13cmFwIHsgcGFkZGluZy1yaWdo
;dDogMDsgfQojdG9wLm1vZGUtdG9vbCAjdG9wLXByZXZpZXcgeyBkaXNwbGF5OiBub25lOyB9CiN0b3AubW9kZS1oYW5kbGUgI3Rv
;cC1wcmV2aWV3IHsgZGlzcGxheTogbm9uZTsgfQojdG9wLm1vZGUtaW5mbyAjc2VhcmNoLXdyYXAgeyBkaXNwbGF5OiBub25lICFp
;bXBvcnRhbnQ7IH0KI3RvcC5tb2RlLWluZm8gI3RvcC1wcmV2aWV3IHsgZGlzcGxheTogbm9uZTsgfQojdG9wLm1vZGUtaW5mbyAj
;dG9wLXJlc3QgeyBncmlkLXRlbXBsYXRlLWNvbHVtbnM6IDFmcjsgbWluLWhlaWdodDogMDsgfQojc2VhcmNoLWJveCB7CiAgcG9z
;aXRpb246IHJlbGF0aXZlOyBkaXNwbGF5OiBmbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBnYXA6IDRweDsKICB3aWR0aDogMTAw
;JTsgaGVpZ2h0OiAzNHB4OwogIGJvcmRlcjogMXB4IHNvbGlkIHZhcigtLWxpbmUpOyBib3JkZXItcmFkaXVzOiA4cHg7CiAgcGFk
;ZGluZzogMCA0cHggMCA4cHg7IGJhY2tncm91bmQ6ICNmYmZiZmQ7IG92ZXJmbG93OiB2aXNpYmxlOwp9CiNzZWFyY2gtYm94OmZv
;Y3VzLXdpdGhpbiB7CiAgYm9yZGVyLWNvbG9yOiAjOTNjNWZkOwogIGJveC1zaGFkb3c6IDAgMCAwIDNweCByZ2JhKDU5LDEzMCwy
;NDYsLjE1KTsKICBiYWNrZ3JvdW5kOiAjZmZmOwp9CiNzZWFyY2gtaWNvIHsKICBmbGV4LXNocmluazogMDsgd2lkdGg6IDE1cHg7
;IGhlaWdodDogMTVweDsgbWFyZ2luLXJpZ2h0OiAycHg7CiAgY29sb3I6IHZhcigtLXR4dDMpOyBkaXNwbGF5OiBibG9jazsgcG9p
;bnRlci1ldmVudHM6IG5vbmU7Cn0KI3NlYXJjaC1ib3g6Zm9jdXMtd2l0aGluICNzZWFyY2gtaWNvIHsgY29sb3I6ICM2NDc0OGI7
;IH0KI3EgewogIGZsZXg6IDE7IG1pbi13aWR0aDogMDsgaGVpZ2h0OiAxMDAlOwogIGJvcmRlcjogMDsgYm9yZGVyLXJhZGl1czog
;MDsgcGFkZGluZzogMDsgb3V0bGluZTogbm9uZTsgYmFja2dyb3VuZDogdHJhbnNwYXJlbnQ7CiAgZm9udC1zaXplOiAxMy41cHg7
;IGNvbG9yOiB2YXIoLS10eHQpOwp9CiNxOjpwbGFjZWhvbGRlciB7IGNvbG9yOiB2YXIoLS10eHQzKTsgfQojYnRuLWNsZWFyIHsK
;ICBkaXNwbGF5OiBub25lOyBmbGV4LXNocmluazogMDsgaGVpZ2h0OiAyMnB4OyBwYWRkaW5nOiAwIDEwcHg7CiAgYm9yZGVyOiAw
;OyBib3JkZXItcmFkaXVzOiA5OTlweDsgYmFja2dyb3VuZDogI2VlZjFmNjsKICBjb2xvcjogdmFyKC0tdHh0Mik7IGZvbnQtc2l6
;ZTogMTJweDsgY3Vyc29yOiBwb2ludGVyOyBsaW5lLWhlaWdodDogMjJweDsKfQojYnRuLWNsZWFyLm9uIHsgZGlzcGxheTogaW5s
;aW5lLWZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGp1c3RpZnktY29udGVudDogY2VudGVyOyB9CiNidG4tY2xlYXI6aG92ZXIg
;eyBiYWNrZ3JvdW5kOiAjZTJlOGYwOyBjb2xvcjogdmFyKC0tdHh0KTsgfQojYnRuLWhpc3QgewogIGZsZXgtc2hyaW5rOiAwOyB3
;aWR0aDogMjRweDsgaGVpZ2h0OiAyNHB4OyBib3JkZXI6IDA7IGJvcmRlci1yYWRpdXM6IDZweDsKICBiYWNrZ3JvdW5kOiB0cmFu
;c3BhcmVudDsgY29sb3I6IHZhcigtLXR4dDMpOyBmb250LXNpemU6IDEwcHg7CiAgY3Vyc29yOiBwb2ludGVyOyBsaW5lLWhlaWdo
;dDogMTsgcGFkZGluZzogMDsKfQojYnRuLWhpc3Q6aG92ZXIsICNidG4taGlzdC5vbiB7IGJhY2tncm91bmQ6ICNlZWYyZmY7IGNv
;bG9yOiB2YXIoLS1hY2MyKTsgfQojaGlzdC1tZW51IHsKICBkaXNwbGF5OiBub25lOyBwb3NpdGlvbjogYWJzb2x1dGU7IHRvcDog
;MTAwJTsgbGVmdDogLTFweDsgcmlnaHQ6IC0xcHg7IHotaW5kZXg6IDQ1OwogIG1heC1oZWlnaHQ6IDI4MHB4OyBvdmVyZmxvdzog
;YXV0bzsKICBiYWNrZ3JvdW5kOiAjZmZmOyBib3JkZXI6IDFweCBzb2xpZCB2YXIoLS1saW5lKTsgYm9yZGVyLXRvcDogMDsKICBi
;b3gtc2hhZG93OiAwIDhweCAxOHB4IHJnYmEoMTUsIDIzLCA0MiwgLjA4KTsgcGFkZGluZzogMnB4IDRweCA0cHg7CiAgYm9yZGVy
;LXJhZGl1czogMCAwIDhweCA4cHg7Cn0KI2hpc3QtbWVudS5vbiB7IGRpc3BsYXk6IGJsb2NrOyB9CiNzZWFyY2gtYm94Lmhpc3Qt
;b3BlbiB7CiAgYm9yZGVyLWJvdHRvbS1sZWZ0LXJhZGl1czogMDsgYm9yZGVyLWJvdHRvbS1yaWdodC1yYWRpdXM6IDA7Cn0KI2hp
;c3QtbWVudSBidXR0b24gewogIGRpc3BsYXk6IGJsb2NrOyB3aWR0aDogMTAwJTsgdGV4dC1hbGlnbjogbGVmdDsgYm9yZGVyOiAw
;OyBiYWNrZ3JvdW5kOiB0cmFuc3BhcmVudDsKICBwYWRkaW5nOiA4cHggMTBweDsgYm9yZGVyLXJhZGl1czogNnB4OyBjdXJzb3I6
;IHBvaW50ZXI7IGNvbG9yOiB2YXIoLS10eHQpOwogIGZvbnQtc2l6ZTogMTNweDsgb3ZlcmZsb3c6IGhpZGRlbjsgdGV4dC1vdmVy
;ZmxvdzogZWxsaXBzaXM7IHdoaXRlLXNwYWNlOiBub3dyYXA7Cn0KI2hpc3QtbWVudSBidXR0b246aG92ZXIgeyBiYWNrZ3JvdW5k
;OiAjZjNmNGY2OyB9CiNoaXN0LW1lbnUgLmhpc3QtZW1wdHkgewogIHBhZGRpbmc6IDEwcHg7IGNvbG9yOiB2YXIoLS10eHQzKTsg
;Zm9udC1zaXplOiAxMnB4OyB0ZXh0LWFsaWduOiBjZW50ZXI7Cn0KI3RvcC1wcmV2aWV3IHsKICBkaXNwbGF5OiBmbGV4OyBhbGln
;bi1pdGVtczogY2VudGVyOyBnYXA6IDEwcHg7IG1pbi13aWR0aDogMDsgcGFkZGluZzogMCAxMnB4OwogIGJhY2tncm91bmQ6IHZh
;cigtLWNocm9tZSk7IGNvbG9yOiB2YXIoLS10eHQyKTsgZm9udC1zaXplOiAxMnB4OyBvdmVyZmxvdzogaGlkZGVuOwp9CiN0b3At
;cHJldmlldyAucHYtbWV0YSB7CiAgYm9yZGVyOiAwOyBwYWRkaW5nOiAwOyBmbGV4OiAxOyBtaW4td2lkdGg6IDA7CiAgZmxleC13
;cmFwOiBub3dyYXA7IG92ZXJmbG93OiBoaWRkZW47Cn0KI2J0bi1nb3RvLXByb2MgewogIGZsZXgtc2hyaW5rOiAwOyBoZWlnaHQ6
;IDMwcHg7IHBhZGRpbmc6IDAgMTJweDsKICBib3JkZXI6IDA7IGJvcmRlci1yYWRpdXM6IDk5OXB4OyBjdXJzb3I6IHBvaW50ZXI7
;CiAgYmFja2dyb3VuZDogI2U4ZjFmZjsgY29sb3I6ICMxZDRlZDg7IGZvbnQtc2l6ZTogMTIuNXB4OyBmb250LXdlaWdodDogNjAw
;Owp9CiNidG4tZ290by1wcm9jOmhvdmVyIHsgYmFja2dyb3VuZDogI2RiZWFmZTsgfQoKI3ZpZXctc2VhcmNoIHsgZGlzcGxheTog
;ZmxleDsgZmxleC1kaXJlY3Rpb246IGNvbHVtbjsgZmxleDogMTsgbWluLWhlaWdodDogMDsgfQojdmlldy1zZWFyY2guaGlkZGVu
;IHsgZGlzcGxheTogbm9uZTsgfQojdmlldy1wcm9jIHsKICBkaXNwbGF5OiBub25lOyBmbGV4LWRpcmVjdGlvbjogY29sdW1uOyBm
;bGV4OiAxOyBtaW4taGVpZ2h0OiAwOwogIGJhY2tncm91bmQ6ICNmMGYyZjU7Cn0KI3ZpZXctcHJvYy5vbiB7IGRpc3BsYXk6IGZs
;ZXg7IH0KLnByb2MtdG9wIHsKICBkaXNwbGF5OiBmbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBnYXA6IDEwcHg7IHBhZGRpbmc6
;IDEwcHggMTRweCA4cHg7CiAgYmFja2dyb3VuZDogI2ZmZjsgYm9yZGVyLWJvdHRvbTogMXB4IHNvbGlkIHZhcigtLWxpbmUpOwog
;IC13ZWJraXQtYXBwLXJlZ2lvbjogZHJhZzsgYXBwLXJlZ2lvbjogZHJhZzsKfQoucHJvYy10b3AgLm5vLWRyYWcsIC5wcm9jLXRv
;cCBidXR0b24sIC5wcm9jLXRvcCBpbnB1dCB7CiAgLXdlYmtpdC1hcHAtcmVnaW9uOiBuby1kcmFnOyBhcHAtcmVnaW9uOiBuby1k
;cmFnOwp9Ci5wcm9jLXRhYnMgeyBkaXNwbGF5OiBmbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBnYXA6IDhweDsgZmxleC13cmFw
;OiB3cmFwOyB9Ci5wcm9jLXRhYiB7CiAgaGVpZ2h0OiAzMHB4OyBwYWRkaW5nOiAwIDE0cHg7IGJvcmRlcjogMDsgYm9yZGVyLXJh
;ZGl1czogOTk5cHg7CiAgYmFja2dyb3VuZDogI2VjZWZmMzsgY29sb3I6ICM0YjU1NjM7IGZvbnQtc2l6ZTogMTNweDsgY3Vyc29y
;OiBwb2ludGVyOwp9Ci5wcm9jLXRhYi5vbiB7IGJhY2tncm91bmQ6ICMzYjgyZjY7IGNvbG9yOiAjZmZmOyBmb250LXdlaWdodDog
;NjAwOyB9Ci5wcm9jLXRhYjpkaXNhYmxlZCB7IG9wYWNpdHk6IC41NTsgY3Vyc29yOiBkZWZhdWx0OyB9Ci5wcm9jLXRvcC1yaWdo
;dCB7IG1hcmdpbi1sZWZ0OiBhdXRvOyBkaXNwbGF5OiBmbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBnYXA6IDhweDsgfQojYnRu
;LWJhY2stc2VhcmNoIHsKICBoZWlnaHQ6IDMwcHg7IHBhZGRpbmc6IDAgMTJweDsgYm9yZGVyOiAwOyBib3JkZXItcmFkaXVzOiA5
;OTlweDsKICBiYWNrZ3JvdW5kOiAjZjNmNGY2OyBjb2xvcjogdmFyKC0tdHh0KTsgZm9udC1zaXplOiAxMi41cHg7IGN1cnNvcjog
;cG9pbnRlcjsKfQojYnRuLWJhY2stc2VhcmNoOmhvdmVyIHsgYmFja2dyb3VuZDogI2U1ZTdlYjsgfQoucHJvYy1zZWFyY2ggewog
;IGRpc3BsYXk6IGZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGdhcDogOHB4OyBwYWRkaW5nOiA4cHggMTRweDsKICBiYWNrZ3Jv
;dW5kOiAjZmZmOyBib3JkZXItYm90dG9tOiAxcHggc29saWQgdmFyKC0tbGluZSk7Cn0KLnByb2Mtc2VhcmNoIGlucHV0IHsKICBm
;bGV4OiAxOyBoZWlnaHQ6IDMycHg7IGJvcmRlcjogMXB4IHNvbGlkIHZhcigtLWxpbmUpOyBib3JkZXItcmFkaXVzOiA4cHg7CiAg
;cGFkZGluZzogMCAxMnB4OyBvdXRsaW5lOiBub25lOyBiYWNrZ3JvdW5kOiAjZmJmYmZkOyBmb250LXNpemU6IDEzcHg7Cn0KLnBy
;b2Mtc2VhcmNoIGlucHV0OmZvY3VzIHsKICBib3JkZXItY29sb3I6ICM5M2M1ZmQ7IGJveC1zaGFkb3c6IDAgMCAwIDNweCByZ2Jh
;KDU5LDEzMCwyNDYsLjE1KTsgYmFja2dyb3VuZDogI2ZmZjsKfQoucHJvYy10YWJsZS13cmFwIHsKICBmbGV4OiAxOyBtaW4taGVp
;Z2h0OiAwOyBtYXJnaW46IDAgMTBweCA4cHg7IGJvcmRlcjogMXB4IHNvbGlkICNkNGQ0ZDQ7CiAgYm9yZGVyLXJhZGl1czogMDsg
;b3ZlcmZsb3c6IGhpZGRlbjsgYmFja2dyb3VuZDogI2ZmZjsKICBkaXNwbGF5OiBmbGV4OyBmbGV4LWRpcmVjdGlvbjogY29sdW1u
;Owp9Ci5wcm9jLXRhYmxlLXdyYXAuaGlkZGVuIHsgZGlzcGxheTogbm9uZTsgfQovKiDnu5/kuIDliJflrr3vvJrooajlpLTkuI7m
;lbDmja7lkIzkuIDlpZfmqKHmnb/vvIzpgb/lhY3mu5rliqjmnaHplJnkvY0gKi8KLnByb2MtY29scyB7CiAgLS1jLW5hbWU6IG1p
;bm1heCgxODBweCwgMS42ZnIpOwogIC0tYy1jcHU6IDcycHg7CiAgLS1jLW1lbTogOTZweDsKICAtLWMtcGlkOiA4MHB4OwogIC0t
;Yy1wcm90bzogNjhweDsKICAtLWMtbGlwOiBtaW5tYXgoMTEwcHgsIDFmcik7CiAgLS1jLWxwb3J0OiA3NnB4OwogIC0tYy1yaXA6
;IG1pbm1heCgxMTBweCwgMWZyKTsKICAtLWMtcnBvcnQ6IDc2cHg7CiAgLS1jLXN0YXRlOiA4OHB4OwogIGRpc3BsYXk6IGdyaWQ7
;CiAgZ3JpZC10ZW1wbGF0ZS1jb2x1bW5zOiB2YXIoLS1jLW5hbWUpIHZhcigtLWMtY3B1KSB2YXIoLS1jLW1lbSkgdmFyKC0tYy1w
;aWQpIHZhcigtLWMtcHJvdG8pIHZhcigtLWMtbGlwKSB2YXIoLS1jLWxwb3J0KSB2YXIoLS1jLXJpcCkgdmFyKC0tYy1ycG9ydCkg
;dmFyKC0tYy1zdGF0ZSk7CiAgZ2FwOiAwOwogIGFsaWduLWl0ZW1zOiBzdHJldGNoOwogIHdpZHRoOiAxMDAlOwogIGJveC1zaXpp
;bmc6IGJvcmRlci1ib3g7Cn0KLnByb2Mtc2Nyb2xsIHsKICBmbGV4OiAxOyBtaW4taGVpZ2h0OiAwOyBvdmVyZmxvdzogYXV0bzsK
;ICBzY3JvbGxiYXItZ3V0dGVyOiBzdGFibGU7Cn0KLyogV2luMTEg5Lu75Yqh566h55CG5Zmo6aOO5qC85Y+M5bGC6KGo5aS077ya
;55m95bqV44CB5LiK5LiL5bGF5Lit5a+56b2QICovCi5wcm9jLWhlYWQgewogIHBvc2l0aW9uOiBzdGlja3k7IHRvcDogMDsgei1p
;bmRleDogMjsKICBiYWNrZ3JvdW5kOiAjZmZmOyBjb2xvcjogIzVhNWE1YTsKICBoZWlnaHQ6IDQ4cHg7IG1pbi1oZWlnaHQ6IDQ4
;cHg7IHBhZGRpbmc6IDA7CiAgYm9yZGVyLWJvdHRvbTogMXB4IHNvbGlkICNlNWU1ZTU7Cn0KLnByb2MtaGNlbGwgewogIGRpc3Bs
;YXk6IGZsZXg7IGZsZXgtZGlyZWN0aW9uOiBjb2x1bW47IGp1c3RpZnktY29udGVudDogc3BhY2UtYmV0d2VlbjsKICBhbGlnbi1p
;dGVtczogc3RyZXRjaDsKICBtaW4td2lkdGg6IDA7IGhlaWdodDogMTAwJTsgcGFkZGluZzogNnB4IDhweCA3cHg7CiAgYm9yZGVy
;LXJpZ2h0OiAxcHggc29saWQgI2U1ZTVlNTsgYm94LXNpemluZzogYm9yZGVyLWJveDsKICBjdXJzb3I6IHBvaW50ZXI7IHVzZXIt
;c2VsZWN0OiBub25lOwogIGJhY2tncm91bmQ6ICNmZmY7Cn0KLnByb2MtaGNlbGw6bGFzdC1jaGlsZCB7IGJvcmRlci1yaWdodDog
;MDsgfQoucHJvYy1oY2VsbDpob3ZlciB7IGJhY2tncm91bmQ6ICNmN2Y3Zjc7IH0KLnByb2MtaGNlbGwuc29ydGVkIHsgYmFja2dy
;b3VuZDogI2ZmZjsgfQoucHJvYy1oLXRvcCB7CiAgZmxleDogMTsKICBtaW4taGVpZ2h0OiAxOHB4OwogIGZvbnQtc2l6ZTogMTNw
;eDsgZm9udC13ZWlnaHQ6IDYwMDsKICBjb2xvcjogIzFiMWIxYjsgd2hpdGUtc3BhY2U6IG5vd3JhcDsKICBkaXNwbGF5OiBmbGV4
;OyBhbGlnbi1pdGVtczogZmxleC1zdGFydDsganVzdGlmeS1jb250ZW50OiBjZW50ZXI7CiAgZ2FwOiA0cHg7IGxpbmUtaGVpZ2h0
;OiAxLjI7CiAgcG9zaXRpb246IHJlbGF0aXZlOwp9Ci5wcm9jLWNlbGwtbmFtZSAucHJvYy1oLXRvcCB7IGp1c3RpZnktY29udGVu
;dDogY2VudGVyOyB9Ci5wcm9jLWgtbGFiIHsKICBmbGV4OiAwIDAgYXV0bzsKICBmb250LXNpemU6IDEycHg7IGZvbnQtd2VpZ2h0
;OiA0MDA7CiAgY29sb3I6ICM1YTVhNWE7IHRleHQtYWxpZ246IGNlbnRlcjsgd2hpdGUtc3BhY2U6IG5vd3JhcDsKICBsaW5lLWhl
;aWdodDogMS4yOwp9Ci5wcm9jLWNlbGwtbmFtZSAucHJvYy1oLWxhYiB7IHRleHQtYWxpZ246IGxlZnQ7IH0KLnByb2MtaC1zb3J0
;IHsKICBkaXNwbGF5OiBpbmxpbmUtYmxvY2s7IHdpZHRoOiAwOyBoZWlnaHQ6IDA7CiAgYm9yZGVyLWxlZnQ6IDRweCBzb2xpZCB0
;cmFuc3BhcmVudDsgYm9yZGVyLXJpZ2h0OiA0cHggc29saWQgdHJhbnNwYXJlbnQ7CiAgb3BhY2l0eTogMDsgZmxleC1zaHJpbms6
;IDA7Cn0KLnByb2MtaGNlbGwuc29ydGVkIC5wcm9jLWgtc29ydCB7IG9wYWNpdHk6IDE7IH0KLnByb2MtaGNlbGwuc29ydGVkLmFz
;YyAucHJvYy1oLXNvcnQgewogIGJvcmRlci1ib3R0b206IDVweCBzb2xpZCAjMWIxYjFiOyBib3JkZXItdG9wOiAwOwp9Ci5wcm9j
;LWhjZWxsLnNvcnRlZC5kZXNjIC5wcm9jLWgtc29ydCB7CiAgYm9yZGVyLXRvcDogNXB4IHNvbGlkICMxYjFiMWI7IGJvcmRlci1i
;b3R0b206IDA7Cn0KLnByb2MtYm9keSB7IGRpc3BsYXk6IGJsb2NrOyB9Ci5wcm9jLXJvdyB7CiAgbWluLWhlaWdodDogMjhweDsg
;aGVpZ2h0OiAyOHB4OyBwYWRkaW5nOiAwOwogIGZvbnQtc2l6ZTogMTJweDsgY29sb3I6ICMxYjFiMWI7CiAgYm9yZGVyLWJvdHRv
;bTogMDsKICBjdXJzb3I6IGRlZmF1bHQ7IGJhY2tncm91bmQ6ICNmZmY7IHVzZXItc2VsZWN0OiBub25lOwogIHBvc2l0aW9uOiBy
;ZWxhdGl2ZTsKfQoucHJvYy1yb3c6aG92ZXIgeyBiYWNrZ3JvdW5kOiAjZjVmOGZiOyB9Ci5wcm9jLXJvdy5vbiwgLnByb2Mtcm93
;Lm9uOmhvdmVyIHsgYmFja2dyb3VuZDogI2NjZThmZjsgfQovKiDlkIzlkI3ov5vnqIvov57nu63mrrXvvJrku4Xmt6Hnu7/oibLl
;pJbmoYbvvIzml6DlupXoibIgKi8KLnByb2Mtcm93LmdycC1maXJzdCB7CiAgYm94LXNoYWRvdzogaW5zZXQgMCAycHggMCAjODhm
;ZmMxLCBpbnNldCAycHggMCAwICM4OGZmYzEsIGluc2V0IC0ycHggMCAwICM4OGZmYzE7CiAgYm9yZGVyLXJhZGl1czogNHB4IDRw
;eCAwIDA7Cn0KLnByb2Mtcm93LmdycC1taWQgewogIGJveC1zaGFkb3c6IGluc2V0IDJweCAwIDAgIzg4ZmZjMSwgaW5zZXQgLTJw
;eCAwIDAgIzg4ZmZjMTsKICBib3JkZXItcmFkaXVzOiAwOwp9Ci5wcm9jLXJvdy5ncnAtbGFzdCB7CiAgYm94LXNoYWRvdzogaW5z
;ZXQgMCAtMnB4IDAgIzg4ZmZjMSwgaW5zZXQgMnB4IDAgMCAjODhmZmMxLCBpbnNldCAtMnB4IDAgMCAjODhmZmMxOwogIGJvcmRl
;ci1yYWRpdXM6IDAgMCA0cHggNHB4Owp9Ci5wcm9jLXJvdy5ncnAtb25seSwKLnByb2Mtcm93LmdycC1maXJzdC5ncnAtbGFzdCB7
;CiAgYm94LXNoYWRvdzogaW5zZXQgMCAwIDAgMnB4ICM4OGZmYzE7CiAgYm9yZGVyLXJhZGl1czogNHB4Owp9Ci8qIOe7hOWGhemd
;nueEpueCueihjOS/neaMgeeZveW6le+8m+ecn+ato+eCueS4reeahOmCo+S4gOihjOS/neeVmeiTneiJsuW6lSAqLwoucHJvYy1y
;b3cuZ3JwOm5vdCgub24pIHsgYmFja2dyb3VuZDogI2ZmZjsgfQoucHJvYy1yb3cuZ3JwOm5vdCgub24pOmhvdmVyIHsgYmFja2dy
;b3VuZDogI2Y1ZjhmYjsgfQovKiBXaW5kb3dzIOa3oeerlue6v++8m+WNleWFg+agvOWQjOWuveWQjOWeq++8jOihqOWktOS4juaV
;sOaNruS4peagvOWvuem9kCAqLwoucHJvYy1yb3cgPiBkaXYgewogIGRpc3BsYXk6IGZsZXg7CiAgYWxpZ24taXRlbXM6IGNlbnRl
;cjsKICBtaW4td2lkdGg6IDA7CiAgaGVpZ2h0OiAxMDAlOwogIHBhZGRpbmc6IDAgOHB4OwogIGJvcmRlci1yaWdodDogMXB4IHNv
;bGlkICNlNWU1ZTU7CiAgYm94LXNpemluZzogYm9yZGVyLWJveDsKICBvdmVyZmxvdzogaGlkZGVuOwogIHdoaXRlLXNwYWNlOiBu
;b3dyYXA7Cn0KLnByb2Mtcm93ID4gZGl2Omxhc3QtY2hpbGQgeyBib3JkZXItcmlnaHQ6IDA7IH0KLnByb2MtY2VsbC1uYW1lIHsg
;anVzdGlmeS1jb250ZW50OiBmbGV4LXN0YXJ0OyB9Ci5wcm9jLWNlbGwtcGlkLAoucHJvYy1jZWxsLXBvcnQsCi5wcm9jLWNlbGwt
;Y3B1LAoucHJvYy1jZWxsLW1lbSB7IGp1c3RpZnktY29udGVudDogZmxleC1lbmQ7IH0KLnByb2MtY2VsbC1wcm90byB7IGp1c3Rp
;ZnktY29udGVudDogY2VudGVyOyB9Ci5wcm9jLWNlbGwtc3RhdGUgeyBqdXN0aWZ5LWNvbnRlbnQ6IGZsZXgtc3RhcnQ7IGdhcDog
;NnB4OyB9Ci5wcm9jLWNlbGwtaXAgeyBqdXN0aWZ5LWNvbnRlbnQ6IGZsZXgtc3RhcnQ7IH0KLnByb2MtY2VsbC1jcHUsIC5wcm9j
;LWNlbGwtbWVtIHsKICBiYWNrZ3JvdW5kOiAjY2VmZmU1Owp9Ci5wcm9jLWNlbGwtY3B1LmhvdCwgLnByb2MtY2VsbC1tZW0uaG90
;IHsKICBiYWNrZ3JvdW5kOiAjODhmZmMxOwp9Ci5wcm9jLXJvdy5vbiAucHJvYy1jZWxsLWNwdSwKLnByb2Mtcm93Lm9uIC5wcm9j
;LWNlbGwtbWVtIHsKICBiYWNrZ3JvdW5kOiAjY2VmZmU1Owp9Ci5wcm9jLXJvdy5vbiAucHJvYy1jZWxsLWNwdS5ob3QsCi5wcm9j
;LXJvdy5vbiAucHJvYy1jZWxsLW1lbS5ob3QgewogIGJhY2tncm91bmQ6ICM4OGZmYzE7Cn0KLnByb2MtaGNlbGwucHJvYy1jZWxs
;LWNwdSwKLnByb2MtaGNlbGwucHJvYy1jZWxsLW1lbSB7CiAgYmFja2dyb3VuZDogI2ZmZjsKfQoucHJvYy1oY2VsbC5wcm9jLWNl
;bGwtY3B1LmhvdCwKLnByb2MtaGNlbGwucHJvYy1jZWxsLW1lbS5ob3QgewogIGJhY2tncm91bmQ6ICM4OGZmYzE7Cn0KLnByb2Mt
;aGNlbGwucHJvYy1jZWxsLWNwdTpub3QoLmhvdCksCi5wcm9jLWhjZWxsLnByb2MtY2VsbC1tZW06bm90KC5ob3QpIHsKICBiYWNr
;Z3JvdW5kOiAjY2VmZmU1Owp9Ci5wcm9jLW5hbWUgewogIGRpc3BsYXk6IGZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGdhcDog
;OHB4OwogIG1pbi13aWR0aDogMDsgd2lkdGg6IDEwMCU7IG92ZXJmbG93OiBoaWRkZW47Cn0KLnByb2MtbmFtZSBpbWcsIC5wcm9j
;LW5hbWUgLnByb2MtaWNvLXBoIHsKICB3aWR0aDogMTZweDsgaGVpZ2h0OiAxNnB4OyBvYmplY3QtZml0OiBjb250YWluOyBmbGV4
;LXNocmluazogMDsKfQoucHJvYy1uYW1lIC5wcm9jLWljby1waCB7CiAgZGlzcGxheTogaW5saW5lLWJsb2NrOyBiYWNrZ3JvdW5k
;OiAjZThlYWVkOyBib3JkZXItcmFkaXVzOiAycHg7CiAgYm9yZGVyOiAxcHggc29saWQgI2QwZDRkYTsKfQoucHJvYy1uYW1lIC5w
;cm9jLWxhYmVsIHsKICBvdmVyZmxvdzogaGlkZGVuOyB0ZXh0LW92ZXJmbG93OiBlbGxpcHNpczsgd2hpdGUtc3BhY2U6IG5vd3Jh
;cDsgbWluLXdpZHRoOiAwOwp9Ci5wcm9jLW5ldC1kb3QgewogIHdpZHRoOiA3cHg7IGhlaWdodDogN3B4OyBib3JkZXItcmFkaXVz
;OiA1MCU7IGZsZXgtc2hyaW5rOiAwOwogIGJhY2tncm91bmQ6ICMyMmM1NWU7IGJveC1zaGFkb3c6IDAgMCAwIDJweCByZ2JhKDM0
;LCAxOTcsIDk0LCAuMik7Cn0KLnByb2MtbmV0LWRvdC5oaWRkZW4geyBkaXNwbGF5OiBub25lOyB9Ci5wcm9jLW51bSB7CiAgZm9u
;dC12YXJpYW50LW51bWVyaWM6IHRhYnVsYXItbnVtczsgY29sb3I6ICMxYjFiMWI7CiAgd2lkdGg6IDEwMCU7Cn0KLnByb2MtbnVt
;LnBvcnQtaG90IHsKICBjb2xvcjogI2MyNDEwYzsKICBmb250LXdlaWdodDogNzAwOwp9Ci8qIOKUgOKUgCDlhbPogZTlj6Xmn4Tv
;vIjnjrDku6Povbvph4/ooajmoLzvvInilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDi
;lIDilIDilIDilIDilIDilIDilIDilIAgKi8KI2hhbmRsZS1wYW5lbCB7CiAgZmxleDogMTsgbWluLWhlaWdodDogMDsgbWFyZ2lu
;OiAwOyBib3JkZXI6IDA7CiAgYmFja2dyb3VuZDogI2ZmZjsgZGlzcGxheTogZmxleDsgZmxleC1kaXJlY3Rpb246IGNvbHVtbjsg
;b3ZlcmZsb3c6IGhpZGRlbjsKfQojaGFuZGxlLXBhbmVsLmhpZGRlbiB7IGRpc3BsYXk6IG5vbmU7IH0KLmhhbmRsZS1iYW5uZXIg
;ewogIGRpc3BsYXk6IG5vbmU7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGdhcDogOHB4OwogIG1hcmdpbjogMDsgcGFkZGluZzogOHB4
;IDE0cHg7CiAgYmFja2dyb3VuZDogI2YwZjdmZjsgYm9yZGVyOiAwOyBib3JkZXItcmFkaXVzOiAwOwogIGNvbG9yOiAjMWUzYTVm
;OyBmb250LXNpemU6IDEyLjVweDsgZmxleC1zaHJpbms6IDA7Cn0KLmhhbmRsZS1iYW5uZXIub24geyBkaXNwbGF5OiBmbGV4OyB9
;Ci5oYW5kbGUtYmFubmVyOjpiZWZvcmUgewogIGNvbnRlbnQ6ICIiOyB3aWR0aDogNnB4OyBoZWlnaHQ6IDZweDsgYm9yZGVyLXJh
;ZGl1czogNTAlOwogIGJhY2tncm91bmQ6ICMzYjgyZjY7IGZsZXgtc2hyaW5rOiAwOwp9Ci5oYW5kbGUtY29scyB7CiAgLS1oLW5h
;bWU6IG1pbm1heCgxNDBweCwgMS4yZnIpOwogIC0taC1waWQ6IDg4cHg7CiAgLS1oLXBvcnQ6IDg0cHg7CiAgLS1oLXJwb3J0OiA4
;NHB4OwogIC0taC10eXBlOiA3MnB4OwogIC0taC1wYXRoOiBtaW5tYXgoMTYwcHgsIDJmcik7CiAgZGlzcGxheTogZ3JpZDsKICBn
;cmlkLXRlbXBsYXRlLWNvbHVtbnM6IHZhcigtLWgtbmFtZSkgdmFyKC0taC1waWQpIHZhcigtLWgtdHlwZSkgdmFyKC0taC1wYXRo
;KTsKICBnYXA6IDA7IHdpZHRoOiAxMDAlOyBib3gtc2l6aW5nOiBib3JkZXItYm94OyBhbGlnbi1pdGVtczogc3RyZXRjaDsKfQou
;aGFuZGxlLWNvbHMucG9ydC1tb2RlIHsKICBncmlkLXRlbXBsYXRlLWNvbHVtbnM6IHZhcigtLWgtbmFtZSkgdmFyKC0taC1waWQp
;IHZhcigtLWgtcG9ydCkgdmFyKC0taC1ycG9ydCkgdmFyKC0taC10eXBlKSB2YXIoLS1oLXBhdGgpOwp9Ci5oYW5kbGUtY29sLXBv
;cnQuaGlkZGVuLCAuaGFuZGxlLWNvbC1ycG9ydC5oaWRkZW4geyBkaXNwbGF5OiBub25lICFpbXBvcnRhbnQ7IH0KLmhhbmRsZS1j
;b2xzLnBvcnQtbW9kZSAuaGFuZGxlLWNvbC1wb3J0LmhpZGRlbiwKLmhhbmRsZS1jb2xzLnBvcnQtbW9kZSAuaGFuZGxlLWNvbC1y
;cG9ydC5oaWRkZW4geyBkaXNwbGF5OiBmbGV4ICFpbXBvcnRhbnQ7IH0KLmhhbmRsZS1zY3JvbGwgeyBmbGV4OiAxOyBtaW4taGVp
;Z2h0OiAwOyBvdmVyZmxvdzogYXV0bzsgcGFkZGluZzogMCA4cHggOHB4OyB9Ci5oYW5kbGUtaGVhZCB7CiAgcG9zaXRpb246IHN0
;aWNreTsgdG9wOiAwOyB6LWluZGV4OiAyOyBoZWlnaHQ6IDM0cHg7IG1pbi1oZWlnaHQ6IDM0cHg7CiAgYmFja2dyb3VuZDogI2Zm
;ZjsgY29sb3I6IHZhcigtLXR4dDIpOyBmb250LXNpemU6IDEycHg7IGZvbnQtd2VpZ2h0OiA2MDA7CiAgYm9yZGVyLWJvdHRvbTog
;MXB4IHNvbGlkIHZhcigtLWxpbmUpOwp9Ci5oYW5kbGUtaGNlbGwgewogIGN1cnNvcjogcG9pbnRlcjsgdXNlci1zZWxlY3Q6IG5v
;bmU7IGdhcDogNnB4Owp9Ci5oYW5kbGUtaGNlbGw6aG92ZXIgeyBiYWNrZ3JvdW5kOiAjZjVmN2ZiOyBjb2xvcjogdmFyKC0tdHh0
;KTsgfQouaGFuZGxlLWhjZWxsLnNvcnRlZCB7IGNvbG9yOiB2YXIoLS10eHQpOyB9Ci5oYW5kbGUtaGNlbGwgLmgtc29ydCB7CiAg
;ZGlzcGxheTogaW5saW5lLWJsb2NrOyB3aWR0aDogMDsgaGVpZ2h0OiAwOwogIGJvcmRlci1sZWZ0OiA0cHggc29saWQgdHJhbnNw
;YXJlbnQ7IGJvcmRlci1yaWdodDogNHB4IHNvbGlkIHRyYW5zcGFyZW50OwogIG9wYWNpdHk6IDA7IGZsZXgtc2hyaW5rOiAwOwp9
;Ci5oYW5kbGUtaGNlbGwuc29ydGVkIC5oLXNvcnQgeyBvcGFjaXR5OiAxOyB9Ci5oYW5kbGUtaGNlbGwuc29ydGVkLmFzYyAuaC1z
;b3J0IHsKICBib3JkZXItYm90dG9tOiA1cHggc29saWQgIzFiMWIxYjsgYm9yZGVyLXRvcDogMDsKfQouaGFuZGxlLWhjZWxsLnNv
;cnRlZC5kZXNjIC5oLXNvcnQgewogIGJvcmRlci10b3A6IDVweCBzb2xpZCAjMWIxYjFiOyBib3JkZXItYm90dG9tOiAwOwp9Ci5o
;YW5kbGUtYm9keSB7IGRpc3BsYXk6IGJsb2NrOyBwYWRkaW5nLXRvcDogMnB4OyB9Ci5oYW5kbGUtcm93IHsKICBtaW4taGVpZ2h0
;OiAzNnB4OyBoZWlnaHQ6IDM2cHg7IGZvbnQtc2l6ZTogMTNweDsgY29sb3I6IHZhcigtLXR4dCk7CiAgYm9yZGVyOiAwOyBib3Jk
;ZXItcmFkaXVzOiA4cHg7IGJhY2tncm91bmQ6IHRyYW5zcGFyZW50OyBjdXJzb3I6IGRlZmF1bHQ7IHVzZXItc2VsZWN0OiBub25l
;OwogIG1hcmdpbjogMXB4IDA7Cn0KLmhhbmRsZS1yb3c6aG92ZXIgeyBiYWNrZ3JvdW5kOiAjZjVmN2ZiOyB9Ci5oYW5kbGUtcm93
;Lm9uLCAuaGFuZGxlLXJvdy5vbjpob3ZlciB7IGJhY2tncm91bmQ6IHZhcigtLXNlbCk7IH0KLmhhbmRsZS1oZWFkID4gZGl2LAou
;aGFuZGxlLXJvdyA+IGRpdiB7CiAgZGlzcGxheTogZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsgbWluLXdpZHRoOiAwOyBoZWln
;aHQ6IDEwMCU7CiAgcGFkZGluZzogMCAxMnB4OyBib3JkZXI6IDA7IGJveC1zaXppbmc6IGJvcmRlci1ib3g7CiAgb3ZlcmZsb3c6
;IGhpZGRlbjsgd2hpdGUtc3BhY2U6IG5vd3JhcDsgdGV4dC1vdmVyZmxvdzogZWxsaXBzaXM7Cn0KLmhhbmRsZS1uYW1lIHsKICBk
;aXNwbGF5OiBmbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBnYXA6IDEwcHg7IG1pbi13aWR0aDogMDsgd2lkdGg6IDEwMCU7IG92
;ZXJmbG93OiBoaWRkZW47Cn0KLmhhbmRsZS1uYW1lIGltZywgLmhhbmRsZS1uYW1lIC5oYW5kbGUtaWNvLXBoIHsKICB3aWR0aDog
;MThweDsgaGVpZ2h0OiAxOHB4OyBvYmplY3QtZml0OiBjb250YWluOyBmbGV4LXNocmluazogMDsKfQouaGFuZGxlLW5hbWUgLmhh
;bmRsZS1pY28tcGggewogIGRpc3BsYXk6IGlubGluZS1ibG9jazsgYmFja2dyb3VuZDogI2VlZjFmNjsgYm9yZGVyLXJhZGl1czog
;NHB4OyBib3JkZXI6IDA7Cn0KLmhhbmRsZS1uYW1lIHNwYW4gewogIG92ZXJmbG93OiBoaWRkZW47IHRleHQtb3ZlcmZsb3c6IGVs
;bGlwc2lzOyB3aGl0ZS1zcGFjZTogbm93cmFwOyBtaW4td2lkdGg6IDA7IGZvbnQtd2VpZ2h0OiA1MDA7Cn0KLmhhbmRsZS1uZXQt
;ZG90IHsKICB3aWR0aDogN3B4OyBoZWlnaHQ6IDdweDsgYm9yZGVyLXJhZGl1czogNTAlOyBmbGV4LXNocmluazogMDsKICBiYWNr
;Z3JvdW5kOiAjMjJjNTVlOyBib3gtc2hhZG93OiAwIDAgMCAycHggcmdiYSgzNCwgMTk3LCA5NCwgLjIpOwp9Ci5oYW5kbGUtc3Rh
;dGUgewogIGRpc3BsYXk6IGZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGdhcDogNnB4OyBtaW4td2lkdGg6IDA7Cn0KLmhhbmRs
;ZS1lbXB0eSB7CiAgcGFkZGluZzogNDhweCAxNnB4OyB0ZXh0LWFsaWduOiBjZW50ZXI7IGNvbG9yOiB2YXIoLS10eHQzKTsgZm9u
;dC1zaXplOiAxMy41cHg7IGxpbmUtaGVpZ2h0OiAxLjY7Cn0KLmhhbmRsZS1sb2FkaW5nIHsKICBkaXNwbGF5OiBmbGV4OyBmbGV4
;LWRpcmVjdGlvbjogY29sdW1uOyBhbGlnbi1pdGVtczogY2VudGVyOyBqdXN0aWZ5LWNvbnRlbnQ6IGNlbnRlcjsKICBnYXA6IDE0
;cHg7IHBhZGRpbmc6IDY0cHggMTZweDsgY29sb3I6IHZhcigtLXR4dDIpOyBmb250LXNpemU6IDEzcHg7Cn0KLmhhbmRsZS1zcGlu
;bmVyIHsKICB3aWR0aDogMjZweDsgaGVpZ2h0OiAyNnB4OyBib3JkZXItcmFkaXVzOiA1MCU7IGJveC1zaXppbmc6IGJvcmRlci1i
;b3g7CiAgYm9yZGVyOiAyLjVweCBzb2xpZCAjZTVlN2ViOyBib3JkZXItdG9wLWNvbG9yOiAjZTQyMDc5OwogIGFuaW1hdGlvbjog
;aGFuZGxlLXNwaW4gLjdzIGxpbmVhciBpbmZpbml0ZTsKfQpAa2V5ZnJhbWVzIGhhbmRsZS1zcGluIHsKICB0byB7IHRyYW5zZm9y
;bTogcm90YXRlKDM2MGRlZyk7IH0KfQouaW5mby1sb2FkaW5nIHsKICBkaXNwbGF5OiBmbGV4OyBmbGV4LWRpcmVjdGlvbjogY29s
;dW1uOyBhbGlnbi1pdGVtczogY2VudGVyOyBqdXN0aWZ5LWNvbnRlbnQ6IGNlbnRlcjsKICBnYXA6IDE0cHg7IG1pbi1oZWlnaHQ6
;IDI0MHB4OyBwYWRkaW5nOiA2NHB4IDE2cHg7IGNvbG9yOiB2YXIoLS10eHQyKTsgZm9udC1zaXplOiAxM3B4OwogIGJveC1zaXpp
;bmc6IGJvcmRlci1ib3g7Cn0KLmluZm8tc3Bpbm5lciB7CiAgd2lkdGg6IDI4cHg7IGhlaWdodDogMjhweDsgYm9yZGVyLXJhZGl1
;czogNTAlOyBib3gtc2l6aW5nOiBib3JkZXItYm94OwogIGJvcmRlcjogMi41cHggc29saWQgI2U1ZTdlYjsgYm9yZGVyLXRvcC1j
;b2xvcjogI2U0MjA3OTsKICBhbmltYXRpb246IGhhbmRsZS1zcGluIC43cyBsaW5lYXIgaW5maW5pdGU7Cn0KI2Jhci1oYW5kbGUt
;YWN0aW9ucyB7CiAgZGlzcGxheTogbm9uZTsgYWxpZ24taXRlbXM6IGNlbnRlcjsgZ2FwOiAxMHB4OyBtYXJnaW4tcmlnaHQ6IDhw
;eDsgbWluLXdpZHRoOiAwOwogIHBvc2l0aW9uOiByZWxhdGl2ZTsKfQojYmFyLm1vZGUtaGFuZGxlICNiYXItaGFuZGxlLWFjdGlv
;bnMgeyBkaXNwbGF5OiBpbmxpbmUtZmxleDsgfQojYmFyLWhhbmRsZS1hY3Rpb25zICNoYW5kbGUtc3RhdHVzIHsKICBjb2xvcjog
;dmFyKC0tdHh0Myk7IGZvbnQtc2l6ZTogMTJweDsgbWF4LXdpZHRoOiAyNDBweDsKICBvdmVyZmxvdzogaGlkZGVuOyB0ZXh0LW92
;ZXJmbG93OiBlbGxpcHNpczsgd2hpdGUtc3BhY2U6IG5vd3JhcDsKfQojYnRuLXBvcnQtbWFyayB7CiAgd2lkdGg6IDI4cHg7IGhl
;aWdodDogMjhweDsgYm9yZGVyOiAwOyBib3JkZXItcmFkaXVzOiA4cHg7CiAgYmFja2dyb3VuZDogdHJhbnNwYXJlbnQ7IGNvbG9y
;OiB2YXIoLS10eHQyKTsgZm9udC1zaXplOiAxNXB4OwogIGN1cnNvcjogcG9pbnRlcjsgbGluZS1oZWlnaHQ6IDE7IGZsZXgtc2hy
;aW5rOiAwOwp9CiNidG4tcG9ydC1tYXJrOmhvdmVyLCAjYnRuLXBvcnQtbWFyay5vbiB7CiAgYmFja2dyb3VuZDogI2VlZjFmNjsg
;Y29sb3I6IHZhcigtLXR4dCk7Cn0KI2Jhci5tb2RlLWhhbmRsZSAuc29ydCwgI2Jhci5tb2RlLWhhbmRsZSAudG9nZ2xlIHsgZGlz
;cGxheTogbm9uZTsgfQouaGFuZGxlLWNvbC1wb3J0LnBvcnQtaG90LAouaGFuZGxlLWNvbC1ycG9ydC5wb3J0LWhvdCB7CiAgY29s
;b3I6ICNjMjQxMGM7IGZvbnQtd2VpZ2h0OiA3MDA7Cn0KI3BvcnQtbWFyay1wb3AgewogIGRpc3BsYXk6IG5vbmU7IHBvc2l0aW9u
;OiBhYnNvbHV0ZTsgcmlnaHQ6IDA7IGJvdHRvbTogY2FsYygxMDAlICsgOHB4KTsKICB3aWR0aDogMzAwcHg7IHotaW5kZXg6IDgw
;OyBwYWRkaW5nOiAxMnB4OwogIGJhY2tncm91bmQ6ICNmZmY7IGJvcmRlcjogMXB4IHNvbGlkIHZhcigtLWxpbmUpOyBib3JkZXIt
;cmFkaXVzOiAxMnB4OwogIGJveC1zaGFkb3c6IDAgMTJweCAyOHB4IHJnYmEoMTUsIDIzLCA0MiwgLjEyKTsKfQojcG9ydC1tYXJr
;LXBvcC5vbiB7IGRpc3BsYXk6IGJsb2NrOyB9Ci5wbXAtaGQgeyBmb250LXNpemU6IDEzLjVweDsgZm9udC13ZWlnaHQ6IDY1MDsg
;Y29sb3I6IHZhcigtLXR4dCk7IG1hcmdpbi1ib3R0b206IDRweDsgfQoucG1wLWhpbnQgeyBmb250LXNpemU6IDEycHg7IGNvbG9y
;OiB2YXIoLS10eHQzKTsgbWFyZ2luLWJvdHRvbTogMTBweDsgbGluZS1oZWlnaHQ6IDEuNDsgfQoucG1wLXRhZ3MgewogIGRpc3Bs
;YXk6IGZsZXg7IGZsZXgtd3JhcDogd3JhcDsgZ2FwOiA2cHg7IG1pbi1oZWlnaHQ6IDMycHg7CiAgbWF4LWhlaWdodDogMTQwcHg7
;IG92ZXJmbG93OiBhdXRvOyBtYXJnaW4tYm90dG9tOiAxMHB4Owp9Ci5wbXAtdGFnIHsKICBkaXNwbGF5OiBpbmxpbmUtZmxleDsg
;YWxpZ24taXRlbXM6IGNlbnRlcjsgZ2FwOiA0cHg7CiAgaGVpZ2h0OiAyNnB4OyBwYWRkaW5nOiAwIDRweCAwIDEwcHg7IGJvcmRl
;ci1yYWRpdXM6IDk5OXB4OwogIGJhY2tncm91bmQ6ICNmZmY3ZWQ7IGNvbG9yOiAjYzI0MTBjOyBmb250LXNpemU6IDEyLjVweDsg
;Zm9udC13ZWlnaHQ6IDYwMDsKICBmb250LXZhcmlhbnQtbnVtZXJpYzogdGFidWxhci1udW1zOwp9Ci5wbXAtdGFnIGJ1dHRvbiB7
;CiAgd2lkdGg6IDIwcHg7IGhlaWdodDogMjBweDsgYm9yZGVyOiAwOyBib3JkZXItcmFkaXVzOiA1MCU7CiAgYmFja2dyb3VuZDog
;dHJhbnNwYXJlbnQ7IGNvbG9yOiAjZWE1ODBjOyBjdXJzb3I6IHBvaW50ZXI7IGZvbnQtc2l6ZTogMTRweDsgbGluZS1oZWlnaHQ6
;IDE7Cn0KLnBtcC10YWcgYnV0dG9uOmhvdmVyIHsgYmFja2dyb3VuZDogI2ZmZWRkNTsgfQoucG1wLWVtcHR5IHsgY29sb3I6IHZh
;cigtLXR4dDMpOyBmb250LXNpemU6IDEycHg7IHBhZGRpbmc6IDZweCAycHg7IH0KLnBtcC1hZGQgeyBkaXNwbGF5OiBmbGV4OyBn
;YXA6IDhweDsgYWxpZ24taXRlbXM6IGNlbnRlcjsgbWFyZ2luLWJvdHRvbTogOHB4OyB9Ci5wbXAtYWRkIGlucHV0IHsKICBmbGV4
;OiAxOyBtaW4td2lkdGg6IDA7IGhlaWdodDogMzJweDsgYm9yZGVyOiAxcHggc29saWQgdmFyKC0tbGluZSk7IGJvcmRlci1yYWRp
;dXM6IDhweDsKICBwYWRkaW5nOiAwIDEwcHg7IG91dGxpbmU6IG5vbmU7IGZvbnQtc2l6ZTogMTNweDsgYmFja2dyb3VuZDogI2Zi
;ZmJmZDsKfQoucG1wLWFkZCBpbnB1dDpmb2N1cyB7IGJvcmRlci1jb2xvcjogIzkzYzVmZDsgYmFja2dyb3VuZDogI2ZmZjsgfQou
;cG1wLWFkZCBidXR0b24sIC5wbXAtcmVzZXQgewogIGhlaWdodDogMzJweDsgcGFkZGluZzogMCAxMnB4OyBib3JkZXI6IDA7IGJv
;cmRlci1yYWRpdXM6IDhweDsKICBiYWNrZ3JvdW5kOiAjZWZmNmZmOyBjb2xvcjogIzFkNGVkODsgZm9udC1zaXplOiAxMi41cHg7
;IGZvbnQtd2VpZ2h0OiA2MDA7IGN1cnNvcjogcG9pbnRlcjsKfQoucG1wLWFkZCBidXR0b246aG92ZXIgeyBiYWNrZ3JvdW5kOiAj
;ZGJlYWZlOyB9Ci5wbXAtcmVzZXQgewogIHdpZHRoOiAxMDAlOyBiYWNrZ3JvdW5kOiB0cmFuc3BhcmVudDsgY29sb3I6IHZhcigt
;LXR4dDIpOyBmb250LXdlaWdodDogNTAwOwp9Ci5wbXAtcmVzZXQ6aG92ZXIgeyBiYWNrZ3JvdW5kOiAjZjNmNGY2OyBjb2xvcjog
;dmFyKC0tdHh0KTsgfQoucHJvYy1hY3QgewogIHdpZHRoOiAyMnB4OyBoZWlnaHQ6IDIycHg7IGJvcmRlcjogMDsgYm9yZGVyLXJh
;ZGl1czogNHB4OyBiYWNrZ3JvdW5kOiB0cmFuc3BhcmVudDsKICBjb2xvcjogIzlhYTFiMjsgY3Vyc29yOiBwb2ludGVyOyBmb250
;LXNpemU6IDEycHg7IGxpbmUtaGVpZ2h0OiAxOwp9Ci5wcm9jLWFjdDpob3ZlciB7IGJhY2tncm91bmQ6ICNlNWU3ZWI7IGNvbG9y
;OiAjMTExODI3OyB9Ci5wcm9jLWZvb3QgewogIGRpc3BsYXk6IGZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGp1c3RpZnktY29u
;dGVudDogZmxleC1lbmQ7IGdhcDogMTRweDsKICBwYWRkaW5nOiA2cHggMTZweCAxMHB4OyBjb2xvcjogIzNiODJmNjsgZm9udC1z
;aXplOiAxMi41cHg7Cn0KLnByb2MtZm9vdC5oaWRkZW4geyBkaXNwbGF5OiBub25lOyB9Ci5wcm9jLXN5cy10b2cgewogIGRpc3Bs
;YXk6IGlubGluZS1mbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBnYXA6IDhweDsgY3Vyc29yOiBwb2ludGVyOwogIHVzZXItc2Vs
;ZWN0OiBub25lOyBjb2xvcjogIzNiODJmNjsgZm9udC1zaXplOiAxMi41cHg7Cn0KLnByb2Mtc3lzLXRvZyBpbnB1dCB7IHBvc2l0
;aW9uOiBhYnNvbHV0ZTsgb3BhY2l0eTogMDsgd2lkdGg6IDA7IGhlaWdodDogMDsgfQoucHJvYy1zeXMtdG9nIC50b2cgewogIHdp
;ZHRoOiAzNnB4OyBoZWlnaHQ6IDIwcHg7IGJvcmRlci1yYWRpdXM6IDk5OXB4OyBiYWNrZ3JvdW5kOiAjZDFkNWRiOwogIHBvc2l0
;aW9uOiByZWxhdGl2ZTsgZmxleC1zaHJpbms6IDA7IHRyYW5zaXRpb246IGJhY2tncm91bmQgLjE1cyBlYXNlOwp9Ci5wcm9jLXN5
;cy10b2cgLnRvZzo6YWZ0ZXIgewogIGNvbnRlbnQ6ICIiOyBwb3NpdGlvbjogYWJzb2x1dGU7IHRvcDogMnB4OyBsZWZ0OiAycHg7
;CiAgd2lkdGg6IDE2cHg7IGhlaWdodDogMTZweDsgYm9yZGVyLXJhZGl1czogNTAlOyBiYWNrZ3JvdW5kOiAjZmZmOwogIGJveC1z
;aGFkb3c6IDAgMXB4IDJweCByZ2JhKDAsMCwwLC4xOCk7IHRyYW5zaXRpb246IHRyYW5zZm9ybSAuMTVzIGVhc2U7Cn0KLnByb2Mt
;c3lzLXRvZyBpbnB1dDpjaGVja2VkICsgLnRvZyB7IGJhY2tncm91bmQ6ICMzYjgyZjY7IH0KLnByb2Mtc3lzLXRvZyBpbnB1dDpj
;aGVja2VkICsgLnRvZzo6YWZ0ZXIgeyB0cmFuc2Zvcm06IHRyYW5zbGF0ZVgoMTZweCk7IH0KI3Byb2MtY291bnQgewogIGNvbG9y
;OiAjNmI3MjgwOyBmb250LXZhcmlhbnQtbnVtZXJpYzogdGFidWxhci1udW1zOyBtaW4td2lkdGg6IDIuNWVtOyB0ZXh0LWFsaWdu
;OiByaWdodDsKfQojaW5mby1wYW5lbCB7CiAgZmxleDogMTsgbWluLWhlaWdodDogMDsgbWFyZ2luOiAwOyBib3JkZXI6IDA7IGJv
;cmRlci1yYWRpdXM6IDA7CiAgb3ZlcmZsb3c6IGF1dG87IGJhY2tncm91bmQ6ICNmZmY7CiAgZGlzcGxheTogYmxvY2s7IC8qIOWL
;v+eUqCBmbGV4IOWIl++8muWkmuihjOe9keWNoeS8muiiq+WOi+efruWPoOWtlyAqLwp9CiNpbmZvLXBhbmVsLmhpZGRlbiB7IGRp
;c3BsYXk6IG5vbmU7IH0KLmluZm8tcm93IHsKICBkaXNwbGF5OiBncmlkOyBncmlkLXRlbXBsYXRlLWNvbHVtbnM6IDEwOHB4IDE4
;cHggMWZyIGF1dG87CiAgZ2FwOiAwIDhweDsgYWxpZ24taXRlbXM6IHN0YXJ0OyBtaW4taGVpZ2h0OiAzNnB4OyBoZWlnaHQ6IGF1
;dG87CiAgcGFkZGluZzogOHB4IDE0cHg7IGJvcmRlci1ib3R0b206IDFweCBzb2xpZCAjZWVmMGY0OwogIGZsZXgtc2hyaW5rOiAw
;OyBvdmVyZmxvdzogdmlzaWJsZTsKfQouaW5mby1yb3c6bnRoLWNoaWxkKGV2ZW4pIHsgYmFja2dyb3VuZDogI2Y3ZjhmYTsgfQou
;aW5mby1sYWIgewogIGNvbG9yOiAjM2I4MmY2OyBmb250LXNpemU6IDEzcHg7IHRleHQtYWxpZ246IHJpZ2h0OyBwYWRkaW5nLXRv
;cDogMnB4OwogIHdoaXRlLXNwYWNlOiBub3dyYXA7Cn0KLmluZm8tZGFzaCB7CiAgaGVpZ2h0OiAxcHg7IGJhY2tncm91bmQ6ICNk
;MWQ1ZGI7IG1hcmdpbi10b3A6IDEycHg7IGFsaWduLXNlbGY6IHN0YXJ0Owp9Ci5pbmZvLXZhbCB7CiAgY29sb3I6ICMxMTE4Mjc7
;IGZvbnQtc2l6ZTogMTNweDsgbGluZS1oZWlnaHQ6IDEuNTU7IHdvcmQtYnJlYWs6IGJyZWFrLXdvcmQ7CiAgcGFkZGluZy10b3A6
;IDFweDsgbWluLXdpZHRoOiAwOyBvdmVyZmxvdzogdmlzaWJsZTsKfQouaW5mby12YWwgLnN1YiB7CiAgY29sb3I6ICMzNzQxNTE7
;IG1hcmdpbi1sZWZ0OiAyNHB4OyB3aGl0ZS1zcGFjZTogbm93cmFwOwp9CiNpbmZvLXVwdGltZSB7CiAgY29sb3I6ICMzNzQxNTE7
;IGZvbnQtdmFyaWFudC1udW1lcmljOiB0YWJ1bGFyLW51bXM7Cn0KLmluZm8tdmFsIC5saW5lIHsgZGlzcGxheTogYmxvY2s7IH0K
;LmluZm8tdmFsIC5uZXQtbGluZSB7CiAgZGlzcGxheTogZ3JpZDsgZ3JpZC10ZW1wbGF0ZS1jb2x1bW5zOiBtaW5tYXgoMTQwcHgs
;IDEuNWZyKSBtaW5tYXgoMTUwcHgsIDFmcikgbWlubWF4KDExMHB4LCAwLjg1ZnIpOwogIGdhcDogNHB4IDEycHg7IGFsaWduLWl0
;ZW1zOiBiYXNlbGluZTsgbWFyZ2luOiAwIDAgNnB4OyBtaW4td2lkdGg6IDA7Cn0KLmluZm8tdmFsIC5uZXQtbGluZTpsYXN0LWNo
;aWxkIHsgbWFyZ2luLWJvdHRvbTogMDsgfQouaW5mby12YWwgLm5ldC1saW5lID4gc3BhbiB7IG1pbi13aWR0aDogMDsgb3ZlcmZs
;b3ctd3JhcDogYW55d2hlcmU7IH0KLmluZm8tdmFsIC5uZXQtbGluZSAuayB7IGNvbG9yOiAjNmI3MjgwOyB9Ci5pbmZvLWxpbmsg
;ewogIGJvcmRlcjogMDsgYmFja2dyb3VuZDogdHJhbnNwYXJlbnQ7IGNvbG9yOiAjM2I4MmY2OyBmb250LXNpemU6IDEyLjVweDsK
;ICBjdXJzb3I6IHBvaW50ZXI7IHBhZGRpbmc6IDJweCAwOyB3aGl0ZS1zcGFjZTogbm93cmFwOyBhbGlnbi1zZWxmOiBzdGFydDsK
;fQouaW5mby1saW5rOmhvdmVyIHsgdGV4dC1kZWNvcmF0aW9uOiB1bmRlcmxpbmU7IH0KI2Jhci1pbmZvLWFjdGlvbnMgewogIGRp
;c3BsYXk6IG5vbmU7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGdhcDogMTZweDsgbWFyZ2luLXJpZ2h0OiA4cHg7Cn0KI2Jhci5tb2Rl
;LWluZm8gI2Jhci1pbmZvLWFjdGlvbnMgeyBkaXNwbGF5OiBpbmxpbmUtZmxleDsgfQojYmFyLWluZm8tYWN0aW9ucyBidXR0b24g
;ewogIGJvcmRlcjogMDsgYmFja2dyb3VuZDogdHJhbnNwYXJlbnQ7IGNvbG9yOiAjM2I4MmY2OyBmb250LXNpemU6IDEyLjVweDsg
;Y3Vyc29yOiBwb2ludGVyOyBwYWRkaW5nOiAwOwp9CiNiYXItaW5mby1hY3Rpb25zIGJ1dHRvbjpob3ZlciB7IHRleHQtZGVjb3Jh
;dGlvbjogdW5kZXJsaW5lOyB9CiNiYXIubW9kZS1pbmZvICNjb3VudCB7IGNvbG9yOiB2YXIoLS10eHQyKTsgfQoucHJvYy1zZWFy
;Y2guaGlkZGVuIHsgZGlzcGxheTogbm9uZSAhaW1wb3J0YW50OyB9CiNwcm9jLW1lbnUgewogIGRpc3BsYXk6IG5vbmU7IHBvc2l0
;aW9uOiBmaXhlZDsgei1pbmRleDogMjIwOyBtaW4td2lkdGg6IDE4OHB4OwogIHBhZGRpbmc6IDRweDsgYmFja2dyb3VuZDogI2Zm
;ZjsgYm9yZGVyOiAxcHggc29saWQgdmFyKC0tbGluZSk7CiAgYm9yZGVyLXJhZGl1czogOHB4OyBib3gtc2hhZG93OiB2YXIoLS1z
;aGFkb3cpOwp9CiNwcm9jLW1lbnUub24geyBkaXNwbGF5OiBibG9jazsgfQojcHJvYy1tZW51IGJ1dHRvbiB7CiAgZGlzcGxheTog
;ZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsgZ2FwOiAxMHB4OyB3aWR0aDogMTAwJTsKICB0ZXh0LWFsaWduOiBsZWZ0OyBib3Jk
;ZXI6IDA7IGJhY2tncm91bmQ6IHRyYW5zcGFyZW50OwogIHBhZGRpbmc6IDhweCAxMHB4OyBib3JkZXItcmFkaXVzOiA2cHg7IGN1
;cnNvcjogcG9pbnRlcjsgY29sb3I6IHZhcigtLXR4dCk7IGZvbnQtc2l6ZTogMTNweDsKfQojcHJvYy1tZW51IGJ1dHRvbjpob3Zl
;ciB7IGJhY2tncm91bmQ6ICNmM2Y0ZjY7IH0KI3Byb2MtbWVudSBidXR0b24uZGFuZ2VyIHsgY29sb3I6ICNkYzI2MjY7IH0KI3By
;b2MtbWVudSBidXR0b24uZGFuZ2VyOmhvdmVyIHsgYmFja2dyb3VuZDogI2ZlZjJmMjsgfQojcHJvYy1tZW51IGJ1dHRvbjpkaXNh
;YmxlZCB7IG9wYWNpdHk6IC40NTsgY3Vyc29yOiBkZWZhdWx0OyB9CiNwcm9jLW1lbnUgLmMtaWNvIHsKICB3aWR0aDogMTZweDsg
;aGVpZ2h0OiAxNnB4OyBmbGV4LXNocmluazogMDsKICBkaXNwbGF5OiBpbmxpbmUtZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsg
;anVzdGlmeS1jb250ZW50OiBjZW50ZXI7CiAgY29sb3I6ICMzNzQxNTE7Cn0KI3Byb2MtbWVudSBidXR0b24uZGFuZ2VyIC5jLWlj
;byB7IGNvbG9yOiAjZGMyNjI2OyB9CiNwcm9jLW1lbnUgLmMtaWNvIHN2ZyB7IHdpZHRoOiAxNnB4OyBoZWlnaHQ6IDE2cHg7IGRp
;c3BsYXk6IGJsb2NrOyB9CiNwcm9jLW1lbnUgLnBhY3QtbGFiZWwgewogIGZsZXg6IDE7IG1pbi13aWR0aDogMDsgb3ZlcmZsb3c6
;IGhpZGRlbjsgdGV4dC1vdmVyZmxvdzogZWxsaXBzaXM7IHdoaXRlLXNwYWNlOiBub3dyYXA7Cn0KCiNtYWluIHsgZmxleDogMTsg
;ZGlzcGxheTogZ3JpZDsgZ3JpZC10ZW1wbGF0ZS1jb2x1bW5zOiB2YXIoLS1zaWRlLXcpIG1pbm1heCgwLCAxZnIpOyBtaW4taGVp
;Z2h0OiAwOyBiYWNrZ3JvdW5kOiB2YXIoLS1jaHJvbWUpOyBwYWRkaW5nOiAwIDEwcHggMCAwOyBib3gtc2l6aW5nOiBib3JkZXIt
;Ym94OyB9CiNjb250ZW50LXBhbmUgewogIGRpc3BsYXk6IGdyaWQ7CiAgZ3JpZC10ZW1wbGF0ZS1jb2x1bW5zOiBtaW5tYXgoMjgw
;cHgsIDEuMWZyKSBtaW5tYXgoMzIwcHgsIDEuMmZyKTsKICBtaW4td2lkdGg6IDA7IG1pbi1oZWlnaHQ6IDA7CiAgYmFja2dyb3Vu
;ZDogI2ZmZjsKICBib3JkZXI6IDFweCBzb2xpZCAjZDhkZGU2OwogIGJvcmRlci1yYWRpdXM6IDRweDsKICBvdmVyZmxvdzogaGlk
;ZGVuOwp9CiNtYWluLm1vZGUtdG9vbCAjY29udGVudC1wYW5lIHsKICBncmlkLXRlbXBsYXRlLWNvbHVtbnM6IDFmcjsKfQojbWFp
;bi5tb2RlLWhhbmRsZSAjcHJldmlldyB7IGRpc3BsYXk6IG5vbmU7IH0KCi8qIHNpZGUgKi8KI3NpZGUgewogIGJhY2tncm91bmQ6
;IHZhcigtLWNocm9tZSk7IGJvcmRlci1yaWdodDogMDsKICBkaXNwbGF5OiBmbGV4OyBmbGV4LWRpcmVjdGlvbjogY29sdW1uOyBw
;YWRkaW5nOiAxMHB4IDhweDsgZ2FwOiAycHg7Cn0KLmNhdCB7CiAgZGlzcGxheTogZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsg
;Z2FwOiAxMHB4OyBoZWlnaHQ6IDQycHg7IHBhZGRpbmc6IDAgMTBweDsKICBib3JkZXI6IDA7IGJvcmRlci1yYWRpdXM6IDhweDsg
;YmFja2dyb3VuZDogdHJhbnNwYXJlbnQ7IGNvbG9yOiB2YXIoLS10eHQpOyBjdXJzb3I6IHBvaW50ZXI7CiAgdGV4dC1hbGlnbjog
;bGVmdDsgcG9zaXRpb246IHJlbGF0aXZlOwp9Ci5jYXQ6aG92ZXIgeyBiYWNrZ3JvdW5kOiAjZWVmMWY2OyB9Ci5jYXQub24geyBi
;YWNrZ3JvdW5kOiAjZThlYmYyOyBmb250LXdlaWdodDogNjAwOyB9Ci5jYXQub246OmJlZm9yZSB7CiAgY29udGVudDogIiI7IHBv
;c2l0aW9uOiBhYnNvbHV0ZTsgbGVmdDogMDsgdG9wOiA4cHg7IGJvdHRvbTogOHB4OyB3aWR0aDogM3B4OwogIGJvcmRlci1yYWRp
;dXM6IDJweDsgYmFja2dyb3VuZDogdmFyKC0tYWNjKTsKfQouY2F0IC5pY28gewogIHdpZHRoOiAzMnB4OyBoZWlnaHQ6IDMycHg7
;IGZsZXgtc2hyaW5rOiAwOwogIGRpc3BsYXk6IGlubGluZS1mbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBqdXN0aWZ5LWNvbnRl
;bnQ6IGNlbnRlcjsKICBjb2xvcjogdmFyKC0tdHh0Mik7IGZvbnQtc2l6ZTogMTRweDsgbGluZS1oZWlnaHQ6IDE7Cn0KLmNhdCBp
;bWcuaWNvIHsKICB3aWR0aDogMzJweDsgaGVpZ2h0OiAzMnB4OwogIG9iamVjdC1maXQ6IGNvbnRhaW47IGltYWdlLXJlbmRlcmlu
;ZzogYXV0bzsKfQoKLnNpZGUtc2VwIHsKICBoZWlnaHQ6IDFweDsgbWFyZ2luOiA4cHggMTBweDsgYmFja2dyb3VuZDogdmFyKC0t
;bGluZSk7IGZsZXgtc2hyaW5rOiAwOwp9CiNsaXN0LXBhbmUgeyBwb3NpdGlvbjogcmVsYXRpdmU7IH0KI2ZpbGUtcmVzdWx0cyB7
;IGRpc3BsYXk6IGZsZXg7IGZsZXgtZGlyZWN0aW9uOiBjb2x1bW47IGZsZXg6IDE7IG1pbi1oZWlnaHQ6IDA7IH0KI2ZpbGUtcmVz
;dWx0cy5oaWRkZW4geyBkaXNwbGF5OiBub25lICFpbXBvcnRhbnQ7IH0KI2hhbmRsZS1wYW5lbC5lbWJlZGRlZCB7CiAgZmxleDog
;MTsgbWluLWhlaWdodDogMDsgbWFyZ2luOiAwOyBib3JkZXI6IDA7IGJvcmRlci1yYWRpdXM6IDA7CiAgZGlzcGxheTogZmxleDsg
;ZmxleC1kaXJlY3Rpb246IGNvbHVtbjsgb3ZlcmZsb3c6IGhpZGRlbjsgYmFja2dyb3VuZDogI2ZmZjsKfQojaGFuZGxlLXBhbmVs
;LmVtYmVkZGVkLmhpZGRlbiB7IGRpc3BsYXk6IG5vbmUgIWltcG9ydGFudDsgfQojaW5mby1wYW5lbC5lbWJlZGRlZCB7CiAgZmxl
;eDogMTsgbWluLWhlaWdodDogMDsgb3ZlcmZsb3c6IGF1dG87IHBhZGRpbmc6IDhweCAxNnB4IDEycHg7IGJhY2tncm91bmQ6ICNm
;ZmY7CiAgYm9yZGVyOiAwOyBtYXJnaW46IDA7Cn0KI2luZm8tcGFuZWwuZW1iZWRkZWQuaGlkZGVuIHsgZGlzcGxheTogbm9uZSAh
;aW1wb3J0YW50OyB9CiNtYWluLm1vZGUtdG9vbCAjcHJldmlldyB7IGRpc3BsYXk6IG5vbmU7IH0KI21haW4ubW9kZS10b29sIHsK
;ICBncmlkLXRlbXBsYXRlLWNvbHVtbnM6IHZhcigtLXNpZGUtdykgbWlubWF4KDAsIDFmcik7Cn0KI2Jhci5tb2RlLXRvb2wgLnNv
;cnQsICNiYXIubW9kZS10b29sIC50b2dnbGUgeyBkaXNwbGF5OiBub25lOyB9CiNiYXIubW9kZS1pbmZvIC5zb3J0LCAjYmFyLm1v
;ZGUtaW5mbyAudG9nZ2xlIHsgZGlzcGxheTogbm9uZTsgfQojdmlldy1wcm9jIHsgZGlzcGxheTogbm9uZSAhaW1wb3J0YW50OyB9
;CiNidG4tZ290by1wcm9jIHsgZGlzcGxheTogbm9uZSAhaW1wb3J0YW50OyB9CiNzaWRlLWZvb3QgeyBkaXNwbGF5OiBub25lOyB9
;CiNidG4tc2V0dGluZ3MgewogIHdpZHRoOiAzNHB4OyBoZWlnaHQ6IDM0cHg7IGJvcmRlcjogMDsgYm9yZGVyLXJhZGl1czogOHB4
;OyBiYWNrZ3JvdW5kOiB0cmFuc3BhcmVudDsKICBjb2xvcjogdmFyKC0tdHh0Mik7IGN1cnNvcjogcG9pbnRlcjsKfQojYnRuLXNl
;dHRpbmdzOmhvdmVyIHsgYmFja2dyb3VuZDogI2VlZjFmNjsgY29sb3I6IHZhcigtLXR4dCk7IH0KCi8qIGxpc3QgKi8KI2xpc3Qt
;cGFuZSB7CiAgZGlzcGxheTogZmxleDsgZmxleC1kaXJlY3Rpb246IGNvbHVtbjsgbWluLXdpZHRoOiAwOyBtaW4taGVpZ2h0OiAw
;OwogIGJhY2tncm91bmQ6ICNmZmY7IGJvcmRlcjogMDsgb3ZlcmZsb3c6IGhpZGRlbjsKICBib3JkZXItcmFkaXVzOiAwOyBib3gt
;c2hhZG93OiBub25lOyBvdXRsaW5lOiBub25lOwp9CiNsaXN0IHsKICBmbGV4OiAxOyBtaW4taGVpZ2h0OiAwOyBvdmVyZmxvdy15
;OiBhdXRvOyBvdmVyZmxvdy14OiBoaWRkZW47IHBhZGRpbmc6IDRweCAwOwogIC13ZWJraXQtb3ZlcmZsb3ctc2Nyb2xsaW5nOiB0
;b3VjaDsKfQoucm93IHsKICBkaXNwbGF5OiBncmlkOyBncmlkLXRlbXBsYXRlLWNvbHVtbnM6IDQwcHggMWZyOyBnYXA6IDEwcHg7
;CiAgYWxpZ24taXRlbXM6IGNlbnRlcjsgbWluLWhlaWdodDogNDRweDsKICBwYWRkaW5nOiA2cHggMTRweDsgY3Vyc29yOiBwb2lu
;dGVyOyBib3JkZXItbGVmdDogM3B4IHNvbGlkIHRyYW5zcGFyZW50Owp9Ci5yb3c6aG92ZXIgeyBiYWNrZ3JvdW5kOiAjZjdmOGZi
;OyB9Ci5yb3cub24geyBiYWNrZ3JvdW5kOiB2YXIoLS1zZWwpOyBib3JkZXItbGVmdC1jb2xvcjogdmFyKC0tYWNjKTsgfQoucm93
;IC5maSB7CiAgd2lkdGg6IDMycHg7IGhlaWdodDogMzJweDsKICBjb2xvcjogdmFyKC0tdHh0Mik7IGRpc3BsYXk6IGdyaWQ7IHBs
;YWNlLWl0ZW1zOiBjZW50ZXI7IGZsZXgtc2hyaW5rOiAwOwp9Ci5yb3cgLmZpIGltZyB7CiAgd2lkdGg6IDMycHg7IGhlaWdodDog
;MzJweDsKICBvYmplY3QtZml0OiBjb250YWluOyBkaXNwbGF5OiBibG9jazsgYmFja2dyb3VuZDogdHJhbnNwYXJlbnQ7CiAgaW1h
;Z2UtcmVuZGVyaW5nOiBhdXRvOwp9Ci5yb3cgLmZpIC5maS1mYWxsYmFjayB7IGZvbnQtc2l6ZTogMThweDsgbGluZS1oZWlnaHQ6
;IDE7IH0KLnJvdyAubmFtZSB7IGNvbG9yOiB2YXIoLS1uYW1lKTsgZm9udC1zaXplOiAxMy41cHg7IGZvbnQtd2VpZ2h0OiA2MDA7
;IHdvcmQtYnJlYWs6IGJyZWFrLWFsbDsgbGluZS1oZWlnaHQ6IDEuMzU7IH0KLnJvdyAubmFtZSAuZXh0IHsgY29sb3I6IHZhcigt
;LW5hbWUtZXh0KTsgfQoucm93IC5uYW1lIG1hcmssIC5yb3cgLnBhdGggbWFyayB7CiAgYmFja2dyb3VuZDogdmFyKC0taGwpOyBj
;b2xvcjogdmFyKC0taGwtdGV4dCk7IHBhZGRpbmc6IDAgMXB4OyBib3JkZXItcmFkaXVzOiAycHg7CiAgZm9udC13ZWlnaHQ6IDcw
;MDsKfQoucm93IC5wYXRoIHsgY29sb3I6ICM0YjU1NjM7IGZvbnQtc2l6ZTogMTJweDsgbWFyZ2luLXRvcDogMnB4OyB3b3JkLWJy
;ZWFrOiBicmVhay1hbGw7IH0KI2xpc3QtZW1wdHkgewogIGRpc3BsYXk6IG5vbmU7IGZsZXg6IDE7IGFsaWduLWl0ZW1zOiBjZW50
;ZXI7IGp1c3RpZnktY29udGVudDogY2VudGVyOwogIGNvbG9yOiB2YXIoLS10eHQzKTsgZm9udC1zaXplOiAxNHB4Owp9CiNsaXN0
;LWVtcHR5Lm9uIHsgZGlzcGxheTogZmxleDsgfQoKLyogcHJldmlldyAqLwojcHJldmlldyB7CiAgYmFja2dyb3VuZDogI2ZmZjsg
;bWluLXdpZHRoOiAwOyBtaW4taGVpZ2h0OiAwOyBkaXNwbGF5OiBmbGV4OyBmbGV4LWRpcmVjdGlvbjogY29sdW1uOyBvdmVyZmxv
;dzogaGlkZGVuOwogIGJvcmRlcjogMDsgYm9yZGVyLXJhZGl1czogMDsgYm94LXNoYWRvdzogbm9uZTsgb3V0bGluZTogbm9uZTsK
;fQojcHJldmlldy5vZmYgLnB2LWJvZHkgeyBkaXNwbGF5OiBub25lOyB9CiNwcmV2aWV3Lm9mZiAucHYtb2ZmIHsKICBkaXNwbGF5
;OiBmbGV4OyBmbGV4OiAxOyBhbGlnbi1pdGVtczogY2VudGVyOyBqdXN0aWZ5LWNvbnRlbnQ6IGNlbnRlcjsgY29sb3I6IHZhcigt
;LXR4dDMpOwp9Ci5wdi1vZmYgeyBkaXNwbGF5OiBub25lOyB9Ci5wdi1tZXRhIHsKICBkaXNwbGF5OiBmbGV4OyBnYXA6IDE0cHg7
;IGFsaWduLWl0ZW1zOiBjZW50ZXI7IHBhZGRpbmc6IDEwcHggMTRweDsKICBib3JkZXItYm90dG9tOiAxcHggc29saWQgdmFyKC0t
;bGluZSk7IGNvbG9yOiB2YXIoLS10eHQyKTsgZm9udC1zaXplOiAxMnB4OyBmbGV4LXdyYXA6IHdyYXA7Cn0KLnB2LW1ldGEgYiB7
;IGNvbG9yOiB2YXIoLS10eHQpOyBmb250LXdlaWdodDogNjAwOyB9Ci5wdi1tZXRhIC5kcnYgewogIGRpc3BsYXk6IGlubGluZS1m
;bGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBnYXA6IDZweDsKICBjb2xvcjogdmFyKC0tdHh0KTsgZm9udC13ZWlnaHQ6IDYwMDsK
;fQoucHYtbWV0YSAuZHJ2IGltZyB7CiAgd2lkdGg6IDE2cHg7IGhlaWdodDogMTZweDsgb2JqZWN0LWZpdDogY29udGFpbjsgYmFj
;a2dyb3VuZDogdHJhbnNwYXJlbnQ7IGZsZXgtc2hyaW5rOiAwOwp9Ci5wdi1ib2R5IHsgZmxleDogMTsgbWluLWhlaWdodDogMDsg
;ZGlzcGxheTogZmxleDsgZmxleC1kaXJlY3Rpb246IGNvbHVtbjsgfQoucHYtbWVkaWEgewogIGZsZXg6IDE7IG1pbi1oZWlnaHQ6
;IDA7IGJhY2tncm91bmQ6ICMzZjQ0NTA7IGRpc3BsYXk6IGZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGp1c3RpZnktY29udGVu
;dDogY2VudGVyOwogIG92ZXJmbG93OiBoaWRkZW47IHBvc2l0aW9uOiByZWxhdGl2ZTsKfQoucHYtbWVkaWEuY29tcGFjdCB7CiAg
;ZmxleDogMCAwIGF1dG87IG1pbi1oZWlnaHQ6IDA7IGhlaWdodDogMDsgcGFkZGluZzogMDsgb3ZlcmZsb3c6IGhpZGRlbjsKICBi
;b3JkZXI6IDA7Cn0KLnB2LWJvZHkudGV4dC1tb2RlIC5wdi1tZWRpYSB7IGRpc3BsYXk6IG5vbmU7IH0KLnB2LWJvZHkudGV4dC1t
;b2RlIC5wdi10ZXh0IHsKICBmbGV4OiAxOyBkaXNwbGF5OiBmbGV4OyBib3JkZXItdG9wOiAwOyBtaW4taGVpZ2h0OiAwOwp9Ci5w
;di1tZWRpYSBpbWcsIC5wdi1tZWRpYSB2aWRlbyB7CiAgbWF4LXdpZHRoOiAxMDAlOyBtYXgtaGVpZ2h0OiAxMDAlOyBvYmplY3Qt
;Zml0OiBjb250YWluOyBiYWNrZ3JvdW5kOiAjMTExOwp9Ci5wdi1tZWRpYSAucHYtZmlsZWluZm8gaW1nLmJpZy1pY28gewogIGJh
;Y2tncm91bmQ6IHRyYW5zcGFyZW50ICFpbXBvcnRhbnQ7CiAgbWF4LXdpZHRoOiA0OHB4OyBtYXgtaGVpZ2h0OiA0OHB4Owp9Ci5w
;di1tZWRpYSBlbWJlZC5wZGYsIC5wdi1tZWRpYSBpZnJhbWUucGRmIHsKICB3aWR0aDogMTAwJTsgaGVpZ2h0OiAxMDAlOyBib3Jk
;ZXI6IDA7IGJhY2tncm91bmQ6ICM1MjU2NTk7Cn0KLnB2LW1lZGlhIC5waCB7IGNvbG9yOiAjY2JkNWUxOyBmb250LXNpemU6IDEz
;cHg7IH0KLnB2LWZpbGVpbmZvIHsKICBkaXNwbGF5OiBmbGV4OyBmbGV4LWRpcmVjdGlvbjogY29sdW1uOyBhbGlnbi1pdGVtczog
;c3RyZXRjaDsganVzdGlmeS1jb250ZW50OiBjZW50ZXI7CiAgZ2FwOiAxMHB4OyBwYWRkaW5nOiAyOHB4IDI0cHg7IHRleHQtYWxp
;Z246IGxlZnQ7IHdpZHRoOiAxMDAlOyBoZWlnaHQ6IDEwMCU7CiAgYm94LXNpemluZzogYm9yZGVyLWJveDsgb3ZlcmZsb3c6IGF1
;dG87CiAgYmFja2dyb3VuZDogI2Y3ZjhmYjsgY29sb3I6IHZhcigtLXR4dCk7Cn0KLnB2LWZpbGVpbmZvIC5iaWctaWNvIHsKICB3
;aWR0aDogNDhweDsgaGVpZ2h0OiA0OHB4OyBvYmplY3QtZml0OiBjb250YWluOyBhbGlnbi1zZWxmOiBjZW50ZXI7CiAgYmFja2dy
;b3VuZDogdHJhbnNwYXJlbnQgIWltcG9ydGFudDsKICBpbWFnZS1yZW5kZXJpbmc6IGF1dG87IGZsZXgtc2hyaW5rOiAwOwp9Ci5w
;di1tZWRpYTpoYXMoLnB2LWZpbGVpbmZvKSB7IGJhY2tncm91bmQ6ICNmN2Y4ZmI7IH0KLnB2LWZpbGVpbmZvIC5mbiB7CiAgZm9u
;dC1zaXplOiAxNnB4OyBmb250LXdlaWdodDogNjUwOyBjb2xvcjogdmFyKC0tdHh0KTsKICB3b3JkLWJyZWFrOiBicmVhay1hbGw7
;IHRleHQtYWxpZ246IGNlbnRlcjsgd2lkdGg6IDEwMCU7IGxpbmUtaGVpZ2h0OiAxLjM1Owp9Ci5wdi1maWxlaW5mbyAudG4gewog
;IGZvbnQtc2l6ZTogMTJweDsgY29sb3I6IHZhcigtLXR4dDIpOyB0ZXh0LWFsaWduOiBjZW50ZXI7IHdpZHRoOiAxMDAlOwp9Ci5w
;di1maWxlaW5mbyAuaGludCB7CiAgZm9udC1zaXplOiAxMnB4OyBjb2xvcjogI2I0NTMwOTsgdGV4dC1hbGlnbjogY2VudGVyOyB3
;aWR0aDogMTAwJTsgbGluZS1oZWlnaHQ6IDEuNDU7Cn0KLnB2LWZpbGVpbmZvIC5rdiB7CiAgZGlzcGxheTogZmxleDsgZmxleC1k
;aXJlY3Rpb246IGNvbHVtbjsgZ2FwOiA4cHg7CiAgbWFyZ2luLXRvcDogNnB4OyB3aWR0aDogMTAwJTsgZm9udC1zaXplOiAxMi41
;cHg7IGNvbG9yOiB2YXIoLS10eHQyKTsKfQoucHYtZmlsZWluZm8gLmt2LXJvdyB7CiAgZGlzcGxheTogZ3JpZDsgZ3JpZC10ZW1w
;bGF0ZS1jb2x1bW5zOiA0LjVlbSAxZnI7IGdhcDogMTJweDsgYWxpZ24taXRlbXM6IHN0YXJ0OwogIGxpbmUtaGVpZ2h0OiAxLjU1
;Owp9Ci5wdi1maWxlaW5mbyAua3Ytcm93IC5rIHsgY29sb3I6IHZhcigtLXR4dDIpOyB3aGl0ZS1zcGFjZTogbm93cmFwOyB9Ci5w
;di1maWxlaW5mbyAua3Ytcm93IC52IHsgY29sb3I6IHZhcigtLXR4dCk7IHdvcmQtYnJlYWs6IGJyZWFrLWFsbDsgZm9udC13ZWln
;aHQ6IDUwMDsgfQoucHYtZmlsZWluZm8gLmtpZHMgewogIG1hcmdpbi10b3A6IDhweDsgZm9udC1zaXplOiAxMi41cHg7IGNvbG9y
;OiB2YXIoLS10eHQyKTsgbGluZS1oZWlnaHQ6IDEuNjsKICB3b3JkLWJyZWFrOiBicmVhay1hbGw7Cn0KLnB2LWZpbGVpbmZvIC5r
;aWRzIGIgeyBjb2xvcjogdmFyKC0tdHh0KTsgZm9udC13ZWlnaHQ6IDYwMDsgfQoKLyogY29udGV4dCBtZW51ICovCiNjdHggewog
;IGRpc3BsYXk6IG5vbmU7IHBvc2l0aW9uOiBmaXhlZDsgei1pbmRleDogMjAwOyBtaW4td2lkdGg6IDE2OHB4OwogIHBhZGRpbmc6
;IDRweDsgYmFja2dyb3VuZDogI2ZmZjsgYm9yZGVyOiAxcHggc29saWQgdmFyKC0tbGluZSk7CiAgYm9yZGVyLXJhZGl1czogOHB4
;OyBib3gtc2hhZG93OiAwIDhweCAyNHB4IHJnYmEoMTUsMjMsNDIsLjEyKTsKfQojY3R4Lm9uIHsgZGlzcGxheTogYmxvY2s7IH0K
;I2N0eCBidXR0b24gewogIGRpc3BsYXk6IGZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGdhcDogMTBweDsgd2lkdGg6IDEwMCU7
;CiAgYm9yZGVyOiAwOyBiYWNrZ3JvdW5kOiB0cmFuc3BhcmVudDsgcGFkZGluZzogOHB4IDEwcHg7IGJvcmRlci1yYWRpdXM6IDZw
;eDsKICBjdXJzb3I6IHBvaW50ZXI7IGNvbG9yOiB2YXIoLS10eHQpOyBmb250LXNpemU6IDEzcHg7IHRleHQtYWxpZ246IGxlZnQ7
;Cn0KI2N0eCBidXR0b246aG92ZXIgeyBiYWNrZ3JvdW5kOiAjZjNmNGY2OyB9CiNjdHggYnV0dG9uLmRhbmdlciB7IGNvbG9yOiAj
;ZGMyNjI2OyB9CiNjdHggYnV0dG9uLmRhbmdlcjpob3ZlciB7IGJhY2tncm91bmQ6ICNmZWYyZjI7IH0KI2N0eCAuYy1pY28gewog
;IHdpZHRoOiAxNnB4OyBoZWlnaHQ6IDE2cHg7IGZsZXgtc2hyaW5rOiAwOwogIGRpc3BsYXk6IGlubGluZS1mbGV4OyBhbGlnbi1p
;dGVtczogY2VudGVyOyBqdXN0aWZ5LWNvbnRlbnQ6IGNlbnRlcjsKICBjb2xvcjogIzM3NDE1MTsKfQojY3R4IGJ1dHRvbi5kYW5n
;ZXIgLmMtaWNvIHsgY29sb3I6ICNkYzI2MjY7IH0KI2N0eCAuYy1pY28gc3ZnIHsgd2lkdGg6IDE2cHg7IGhlaWdodDogMTZweDsg
;ZGlzcGxheTogYmxvY2s7IH0KCi5wdi10ZXh0IHsKICBmbGV4OiAxOyBtaW4taGVpZ2h0OiAwOyBkaXNwbGF5OiBmbGV4OyBmbGV4
;LWRpcmVjdGlvbjogY29sdW1uOyBib3JkZXItdG9wOiAxcHggc29saWQgdmFyKC0tbGluZSk7Cn0KLnB2LXRleHQgLmhkIHsKICBw
;YWRkaW5nOiA4cHggMTRweDsgZm9udC1zaXplOiAxMnB4OyBjb2xvcjogdmFyKC0tdHh0Mik7IGJhY2tncm91bmQ6ICNmYWZiZmM7
;IGJvcmRlci1ib3R0b206IDFweCBzb2xpZCB2YXIoLS1saW5lKTsKfQoucHYtdGV4dCBwcmUgewogIG1hcmdpbjogMDsgZmxleDog
;MTsgb3ZlcmZsb3c6IGF1dG87IHBhZGRpbmc6IDEycHggMTRweDsgZm9udC1zaXplOiAxMnB4OyBsaW5lLWhlaWdodDogMS41Owog
;IHdoaXRlLXNwYWNlOiBwcmUtd3JhcDsgd29yZC1icmVhazogYnJlYWstd29yZDsgZm9udC1mYW1pbHk6IENvbnNvbGFzLCAiU2Fy
;YXNhIE1vbm8gU0MiLCBtb25vc3BhY2U7CiAgYmFja2dyb3VuZDogI2ZmZjsgY29sb3I6ICMxMTE4Mjc7Cn0KCi8qIGJvdHRvbe+8
;muiuvue9ruWcqOW3puS4i+inku+8jOaOkuW6jy/pooTop4jntKfmjKjorr7nva7lubbnlZnnqbrpmpkgKi8KI2JhciB7CiAgaGVp
;Z2h0OiA0MnB4OyBkaXNwbGF5OiBmbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBnYXA6IDA7CiAgcGFkZGluZzogMCAxNHB4IDAg
;MTBweDsgYmFja2dyb3VuZDogdmFyKC0tY2hyb21lKTsgYm9yZGVyLXRvcDogMDsgZm9udC1zaXplOiAxMi41cHg7IGNvbG9yOiB2
;YXIoLS10eHQyKTsKfQojYmFyIC5iYXItbGVmdCB7CiAgZmxleC1zaHJpbms6IDA7IGhlaWdodDogMTAwJTsKICBkaXNwbGF5OiBm
;bGV4OyBhbGlnbi1pdGVtczogY2VudGVyOwp9CiNiYXIgLmJhci1tYWluIHsKICBmbGV4OiAxOyBtaW4td2lkdGg6IDA7IGhlaWdo
;dDogMTAwJTsKICBkaXNwbGF5OiBmbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBnYXA6IDE2cHg7CiAgbWFyZ2luLWxlZnQ6IDE4
;cHg7IGJveC1zaXppbmc6IGJvcmRlci1ib3g7Cn0KI2JhciAuc29ydCB7IGRpc3BsYXk6IGlubGluZS1mbGV4OyBhbGlnbi1pdGVt
;czogY2VudGVyOyBnYXA6IDZweDsgY3Vyc29yOiBwb2ludGVyOyBib3JkZXI6IDA7IGJhY2tncm91bmQ6IHRyYW5zcGFyZW50OyBj
;b2xvcjogaW5oZXJpdDsgfQojYmFyIC5zb3J0OmhvdmVyIHsgY29sb3I6IHZhcigtLXR4dCk7IH0KI2JhciAuc3BhY2VyIHsgZmxl
;eDogMTsgfQoudG9nZ2xlIHsKICBkaXNwbGF5OiBpbmxpbmUtZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsgZ2FwOiA4cHg7IGN1
;cnNvcjogcG9pbnRlcjsgdXNlci1zZWxlY3Q6IG5vbmU7Cn0KLnRvZ2dsZSBpbnB1dCB7IGRpc3BsYXk6IG5vbmU7IH0KLnRvZ2ds
;ZSAuc3cgewogIHdpZHRoOiAzNnB4OyBoZWlnaHQ6IDIwcHg7IGJvcmRlci1yYWRpdXM6IDk5OXB4OyBiYWNrZ3JvdW5kOiAjZDFk
;NWRiOyBwb3NpdGlvbjogcmVsYXRpdmU7IHRyYW5zaXRpb246IC4yczsKfQoudG9nZ2xlIC5zdzo6YWZ0ZXIgewogIGNvbnRlbnQ6
;ICIiOyBwb3NpdGlvbjogYWJzb2x1dGU7IHRvcDogMnB4OyBsZWZ0OiAycHg7IHdpZHRoOiAxNnB4OyBoZWlnaHQ6IDE2cHg7CiAg
;Ym9yZGVyLXJhZGl1czogNTAlOyBiYWNrZ3JvdW5kOiAjZmZmOyB0cmFuc2l0aW9uOiAuMnM7IGJveC1zaGFkb3c6IDAgMXB4IDJw
;eCByZ2JhKDAsMCwwLC4yKTsKfQoudG9nZ2xlIGlucHV0OmNoZWNrZWQgKyAuc3cgeyBiYWNrZ3JvdW5kOiB2YXIoLS1hY2MpOyB9
;Ci50b2dnbGUgaW5wdXQ6Y2hlY2tlZCArIC5zdzo6YWZ0ZXIgeyBsZWZ0OiAxOHB4OyB9CiNjb3VudCB7IGNvbG9yOiB2YXIoLS10
;eHQpOyBmb250LXZhcmlhbnQtbnVtZXJpYzogdGFidWxhci1udW1zOyB9Cjwvc3R5bGU+CjwvaGVhZD4KPGJvZHk+CjxkaXYgaWQ9
;ImFwcCIgY2xhc3M9ImJvb3RpbmciPgogIDxkaXYgaWQ9InRpdGxlYmFyIj4KICAgIDxkaXYgY2xhc3M9InRiLWJyYW5kIG5vLWRy
;YWciIHRpdGxlPSLku6rooajnm5giPgogICAgICA8c3ZnIGNsYXNzPSJ0Yi1pY28iIHZpZXdCb3g9IjAgMCAxNiAxNiIgZmlsbD0i
;bm9uZSIgYXJpYS1oaWRkZW49InRydWUiPgogICAgICAgIDxjaXJjbGUgY3g9IjgiIGN5PSI5IiByPSI1LjIiIHN0cm9rZT0iY3Vy
;cmVudENvbG9yIiBzdHJva2Utd2lkdGg9IjEuNCIvPgogICAgICAgIDxwYXRoIGQ9Ik04IDlsMy4yLTMuMiIgc3Ryb2tlPSJjdXJy
;ZW50Q29sb3IiIHN0cm9rZS13aWR0aD0iMS40IiBzdHJva2UtbGluZWNhcD0icm91bmQiLz4KICAgICAgICA8Y2lyY2xlIGN4PSI4
;IiBjeT0iOSIgcj0iMS4xNSIgZmlsbD0iY3VycmVudENvbG9yIi8+CiAgICAgIDwvc3ZnPgogICAgICA8c3BhbiBjbGFzcz0idGIt
;bmFtZSI+5Luq6KGo55uYPC9zcGFuPgogICAgPC9kaXY+CiAgICA8ZGl2IGlkPSJmaWx0ZXItcmFpbCIgY2xhc3M9Im5vLWRyYWci
;PgogICAgICA8YnV0dG9uIGlkPSJidG4tZmlsdGVyLXRvZ2dsZSIgdHlwZT0iYnV0dG9uIiB0aXRsZT0i5bGV5byA562b6YCJ5p2h
;5Lu2IiBhcmlhLWxhYmVsPSLlsZXlvIDnrZvpgInmnaHku7YiPgogICAgICAgIDxzdmcgdmlld0JveD0iMCAwIDE2IDE2IiBmaWxs
;PSJub25lIiBhcmlhLWhpZGRlbj0idHJ1ZSI+CiAgICAgICAgICA8cGF0aCBkPSJNNSA2IEw4IDkgTDExIDYiIHN0cm9rZT0iY3Vy
;cmVudENvbG9yIiBzdHJva2Utd2lkdGg9IjEuMzUiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIgc3Ryb2tlLWxpbmVqb2luPSJyb3Vu
;ZCIvPgogICAgICAgIDwvc3ZnPgogICAgICA8L2J1dHRvbj4KICAgICAgPGRpdiBpZD0iZmlsdGVyLWJhciIgYXJpYS1sYWJlbD0i
;5pCc57Si562b6YCJIj48L2Rpdj4KICAgIDwvZGl2PgogICAgPGRpdiBjbGFzcz0idGItc3BhY2UiIGlkPSJ0aXRsZWJhci1kcmFn
;Ij48L2Rpdj4KICAgIDxkaXYgY2xhc3M9InRiLXdpbiBuby1kcmFnIj4KICAgICAgPGJ1dHRvbiB0eXBlPSJidXR0b24iIGlkPSJi
;dG4td2luLW1pbiIgdGl0bGU9IuacgOWwj+WMliIgYXJpYS1sYWJlbD0i5pyA5bCP5YyWIj4KICAgICAgICA8c3ZnIHZpZXdCb3g9
;IjAgMCAxMCAxMCIgZmlsbD0ibm9uZSIgYXJpYS1oaWRkZW49InRydWUiPjxwYXRoIGQ9Ik0xLjUgNWg3IiBzdHJva2U9ImN1cnJl
;bnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIxLjIiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIvPjwvc3ZnPgogICAgICA8L2J1dHRvbj4K
;ICAgICAgPGJ1dHRvbiB0eXBlPSJidXR0b24iIGlkPSJidG4td2luLW1heCIgdGl0bGU9IuacgOWkp+WMliIgYXJpYS1sYWJlbD0i
;5pyA5aSn5YyWIj4KICAgICAgICA8c3ZnIHZpZXdCb3g9IjAgMCAxMCAxMCIgZmlsbD0ibm9uZSIgYXJpYS1oaWRkZW49InRydWUi
;PjxyZWN0IHg9IjEuNiIgeT0iMS42IiB3aWR0aD0iNi44IiBoZWlnaHQ9IjYuOCIgcng9IjAuNiIgc3Ryb2tlPSJjdXJyZW50Q29s
;b3IiIHN0cm9rZS13aWR0aD0iMS4yIi8+PC9zdmc+CiAgICAgIDwvYnV0dG9uPgogICAgICA8YnV0dG9uIHR5cGU9ImJ1dHRvbiIg
;aWQ9ImJ0bi13aW4tY2xvc2UiIHRpdGxlPSLlhbPpl60iIGFyaWEtbGFiZWw9IuWFs+mXrSI+CiAgICAgICAgPHN2ZyB2aWV3Qm94
;PSIwIDAgMTAgMTAiIGZpbGw9Im5vbmUiIGFyaWEtaGlkZGVuPSJ0cnVlIj48cGF0aCBkPSJNMiAybDYgNk04IDJMMiA4IiBzdHJv
;a2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIxLjIiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIvPjwvc3ZnPgogICAgICA8
;L2J1dHRvbj4KICAgIDwvZGl2PgogIDwvZGl2PgogIDxkaXYgaWQ9ImJvb3QiIGNsYXNzPSJvbiI+CiAgICA8ZGl2IGNsYXNzPSJy
;aW5nLXdyYXAiPgogICAgICA8c3ZnIHZpZXdCb3g9IjAgMCAxMjAgMTIwIj4KICAgICAgICA8Y2lyY2xlIGNsYXNzPSJyaW5nLWJn
;IiBjeD0iNjAiIGN5PSI2MCIgcj0iNTIiPjwvY2lyY2xlPgogICAgICAgIDxjaXJjbGUgaWQ9InJpbmctZmciIGNsYXNzPSJyaW5n
;LWZnIiBjeD0iNjAiIGN5PSI2MCIgcj0iNTIiCiAgICAgICAgICBzdHJva2UtZGFzaGFycmF5PSIzMjYuNzMiIHN0cm9rZS1kYXNo
;b2Zmc2V0PSIzMjYuNzMiPjwvY2lyY2xlPgogICAgICA8L3N2Zz4KICAgICAgPGRpdiBjbGFzcz0icmluZy1sYWJlbCI+CiAgICAg
;ICAgPGRpdiBjbGFzcz0idDEiPuejgeebmOe0ouW8leS4rTwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9InQyIiBpZD0iYm9vdC1w
;Y3QiPuKApjwvZGl2PgogICAgICA8L2Rpdj4KICAgIDwvZGl2PgogICAgPGRpdiBjbGFzcz0iYm9vdC1oaW50Ij4KICAgICAg5q2j
;5Zyo5bu656uL56OB55uY5paH5Lu257Si5byV77yM5a6M5oiQ5ZCO5Y2z5Y+v5pCc57Si44CCPGJyPgogICAgICDoi6XmnKzmnLrl
;t7Llronoo4UgRXZlcnl0aGluZyDlubblvIDmnLrlkK/liqjvvIzkuIvmrKHkvJrmm7Tlv6vlsLHnu6rjgIIKICAgIDwvZGl2Pgog
;IDwvZGl2PgoKICA8ZGl2IGlkPSJjaHJvbWUiIGNsYXNzPSJoaWRkZW4iPgogICAgPGRpdiBpZD0idmlldy1zZWFyY2giPgogICAg
;PGRpdiBpZD0idG9wIj4KICAgICAgPGRpdiBpZD0iZHJpdmUtd3JhcCIgY2xhc3M9Im5vLWRyYWciPgogICAgICAgIDxidXR0b24g
;aWQ9ImJ0bi1kcml2ZSIgdHlwZT0iYnV0dG9uIiB0aXRsZT0i6YCJ5oup5pCc57Si56OB55uYIj4KICAgICAgICAgIDxpbWcgaWQ9
;ImRyaXZlLWJ0bi1pY28iIGNsYXNzPSJkcml2ZS1pY28gaGlkZGVuIiBhbHQ9IiIgd2lkdGg9IjIwIiBoZWlnaHQ9IjIwIj4KICAg
;ICAgICAgIDxzcGFuIGlkPSJkcml2ZS1sYWJlbCI+5YWo55uY5pCc57SiPC9zcGFuPjxzcGFuIGNsYXNzPSJjYXJldCI+4pa+PC9z
;cGFuPgogICAgICAgIDwvYnV0dG9uPgogICAgICAgIDxkaXYgaWQ9ImRyaXZlLW1lbnUiIHJvbGU9Im1lbnUiPjwvZGl2PgogICAg
;ICA8L2Rpdj4KICAgICAgPGRpdiBpZD0idG9wLXJlc3QiPgogICAgICAgIDxkaXYgaWQ9InNlYXJjaC13cmFwIiBjbGFzcz0ibm8t
;ZHJhZyI+CiAgICAgICAgICA8ZGl2IGlkPSJzZWFyY2gtYm94Ij4KICAgICAgICAgICAgPHN2ZyBpZD0ic2VhcmNoLWljbyIgdmll
;d0JveD0iMCAwIDE2IDE2IiBmaWxsPSJub25lIiBhcmlhLWhpZGRlbj0idHJ1ZSI+CiAgICAgICAgICAgICAgPGNpcmNsZSBjeD0i
;NyIgY3k9IjciIHI9IjQuMjUiIHN0cm9rZT0iY3VycmVudENvbG9yIiBzdHJva2Utd2lkdGg9IjEuNCIvPgogICAgICAgICAgICAg
;IDxwYXRoIGQ9Ik0xMC4yIDEwLjJMMTMuNCAxMy40IiBzdHJva2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIxLjQiIHN0
;cm9rZS1saW5lY2FwPSJyb3VuZCIvPgogICAgICAgICAgICA8L3N2Zz4KICAgICAgICAgICAgPGlucHV0IGlkPSJxIiB0eXBlPSJ0
;ZXh0IiBwbGFjZWhvbGRlcj0i6L6T5YWl5paH5Lu25ZCNIC8g5omp5bGV5ZCNIC8g6Lev5b6E5YWz6ZSu5a2X77ybfCDooajnpLrk
;uJTvvIx8fCDooajnpLrmiJYiIGF1dG9jb21wbGV0ZT0ib2ZmIiBzcGVsbGNoZWNrPSJmYWxzZSI+CiAgICAgICAgICAgIDxidXR0
;b24gaWQ9ImJ0bi1jbGVhciIgdHlwZT0iYnV0dG9uIiB0aXRsZT0i5riF56m65pCc57SiIj7muIXnqbo8L2J1dHRvbj4KICAgICAg
;ICAgICAgPGJ1dHRvbiBpZD0iYnRuLWhpc3QiIHR5cGU9ImJ1dHRvbiIgdGl0bGU9IuacgOi/keaQnOe0oiI+4pa+PC9idXR0b24+
;CiAgICAgICAgICAgIDxkaXYgaWQ9Imhpc3QtbWVudSIgcm9sZT0ibWVudSI+PC9kaXY+CiAgICAgICAgICA8L2Rpdj4KICAgICAg
;ICA8L2Rpdj4KICAgICAgICA8ZGl2IGlkPSJ0b3AtcHJldmlldyIgY2xhc3M9Im5vLWRyYWciPgogICAgICAgICAgPGRpdiBjbGFz
;cz0icHYtbWV0YSIgaWQ9InB2LW1ldGEiPumAieaLqeaWh+S7tuS7pemihOiniDwvZGl2PgogICAgICAgIDwvZGl2PgogICAgICA8
;L2Rpdj4KICAgIDwvZGl2PgoKICAgIDxkaXYgaWQ9Im1haW4iPgogICAgICA8YXNpZGUgaWQ9InNpZGUiPgogICAgICAgIDxidXR0
;b24gY2xhc3M9ImNhdCBvbiIgZGF0YS1jYXQ9ImFsbCI+PHNwYW4gY2xhc3M9ImljbyIgZGF0YS1jYXQtaWNvPSJhbGwiPuKYsDwv
;c3Bhbj7lhajpg6g8L2J1dHRvbj4KICAgICAgICA8YnV0dG9uIGNsYXNzPSJjYXQiIGRhdGEtY2F0PSJmb2xkZXIiPjxzcGFuIGNs
;YXNzPSJpY28iIGRhdGEtY2F0LWljbz0iZm9sZGVyIj7wn5OBPC9zcGFuPuaWh+S7tuWkuTwvYnV0dG9uPgogICAgICAgIDxidXR0
;b24gY2xhc3M9ImNhdCIgZGF0YS1jYXQ9ImV4Y2VsIj48c3BhbiBjbGFzcz0iaWNvIiBkYXRhLWNhdC1pY289ImV4Y2VsIj7wn5OK
;PC9zcGFuPkVYQ0VMPC9idXR0b24+CiAgICAgICAgPGJ1dHRvbiBjbGFzcz0iY2F0IiBkYXRhLWNhdD0id29yZCI+PHNwYW4gY2xh
;c3M9ImljbyIgZGF0YS1jYXQtaWNvPSJ3b3JkIj7wn5OEPC9zcGFuPldPUkQ8L2J1dHRvbj4KICAgICAgICA8YnV0dG9uIGNsYXNz
;PSJjYXQiIGRhdGEtY2F0PSJwcHQiPjxzcGFuIGNsYXNzPSJpY28iIGRhdGEtY2F0LWljbz0icHB0Ij7wn5ORPC9zcGFuPlBQVDwv
;YnV0dG9uPgogICAgICAgIDxidXR0b24gY2xhc3M9ImNhdCIgZGF0YS1jYXQ9InBkZiI+PHNwYW4gY2xhc3M9ImljbyIgZGF0YS1j
;YXQtaWNvPSJwZGYiPvCfk5U8L3NwYW4+UERGPC9idXR0b24+CiAgICAgICAgPGJ1dHRvbiBjbGFzcz0iY2F0IiBkYXRhLWNhdD0i
;aW1hZ2UiPjxzcGFuIGNsYXNzPSJpY28iIGRhdGEtY2F0LWljbz0iaW1hZ2UiPvCflrw8L3NwYW4+5Zu+54mHPC9idXR0b24+CiAg
;ICAgICAgPGJ1dHRvbiBjbGFzcz0iY2F0IiBkYXRhLWNhdD0idmlkZW8iPjxzcGFuIGNsYXNzPSJpY28iIGRhdGEtY2F0LWljbz0i
;dmlkZW8iPuKWtjwvc3Bhbj7op4bpopE8L2J1dHRvbj4KICAgICAgICA8YnV0dG9uIGNsYXNzPSJjYXQiIGRhdGEtY2F0PSJhdWRp
;byI+PHNwYW4gY2xhc3M9ImljbyIgZGF0YS1jYXQtaWNvPSJhdWRpbyI+4pmqPC9zcGFuPumfs+mikTwvYnV0dG9uPgogICAgICAg
;IDxidXR0b24gY2xhc3M9ImNhdCIgZGF0YS1jYXQ9InppcCI+PHNwYW4gY2xhc3M9ImljbyIgZGF0YS1jYXQtaWNvPSJ6aXAiPvCf
;l5w8L3NwYW4+5Y6L57yp5paH5Lu2PC9idXR0b24+CiAgICAgICAgPGRpdiBjbGFzcz0ic2lkZS1zZXAiIHJvbGU9InNlcGFyYXRv
;ciI+PC9kaXY+CiAgICAgICAgPGJ1dHRvbiBjbGFzcz0iY2F0IiBkYXRhLWNhdD0iX19oYW5kbGUiIHR5cGU9ImJ1dHRvbiI+PHNw
;YW4gY2xhc3M9ImljbyI+4puTPC9zcGFuPuWFs+iBlOWPpeafhDwvYnV0dG9uPgogICAgICAgIDxidXR0b24gY2xhc3M9ImNhdCIg
;ZGF0YS1jYXQ9Il9faW5mbyIgdHlwZT0iYnV0dG9uIj48c3BhbiBjbGFzcz0iaWNvIj7ihLk8L3NwYW4+5pys5py65L+h5oGvPC9i
;dXR0b24+CiAgICAgICAgPGRpdiBpZD0ic2lkZS1mb290Ij48L2Rpdj4KICAgICAgPC9hc2lkZT4KCiAgICAgIDxkaXYgaWQ9ImNv
;bnRlbnQtcGFuZSI+CiAgICAgICAgPHNlY3Rpb24gaWQ9Imxpc3QtcGFuZSI+CiAgICAgICAgICA8ZGl2IGlkPSJmaWxlLXJlc3Vs
;dHMiPgogICAgICAgICAgICA8ZGl2IGlkPSJsaXN0Ij48L2Rpdj4KICAgICAgICAgICAgPGRpdiBpZD0ibGlzdC1lbXB0eSI+6L6T
;5YWl5YWz6ZSu5a2X5byA5aeL5pCc57Si77yM5oiW6YCJ5oup5bem5L6n5YiG57G75rWP6KeIPC9kaXY+CiAgICAgICAgICA8L2Rp
;dj4KICAgICAgICAgIDxkaXYgaWQ9ImhhbmRsZS1wYW5lbCIgY2xhc3M9ImhpZGRlbiBuby1kcmFnIGVtYmVkZGVkIj4KICAgICAg
;ICAgICAgPGRpdiBjbGFzcz0iaGFuZGxlLWJhbm5lciIgaWQ9ImhhbmRsZS1iYW5uZXIiPjwvZGl2PgogICAgICAgICAgICA8ZGl2
;IGNsYXNzPSJoYW5kbGUtc2Nyb2xsIiBpZD0iaGFuZGxlLXNjcm9sbCI+CiAgICAgICAgICAgICAgPGRpdiBjbGFzcz0iaGFuZGxl
;LWhlYWQgaGFuZGxlLWNvbHMiIGlkPSJoYW5kbGUtaGVhZCI+CiAgICAgICAgICAgICAgICA8ZGl2IGNsYXNzPSJoYW5kbGUtaGNl
;bGwiIGRhdGEtc29ydD0ibmFtZSI+5ZCN56ewPHNwYW4gY2xhc3M9Imgtc29ydCI+PC9zcGFuPjwvZGl2PgogICAgICAgICAgICAg
;ICAgPGRpdiBjbGFzcz0iaGFuZGxlLWhjZWxsIiBkYXRhLXNvcnQ9InBpZCI+UElEPHNwYW4gY2xhc3M9Imgtc29ydCI+PC9zcGFu
;PjwvZGl2PgogICAgICAgICAgICAgICAgPGRpdiBjbGFzcz0iaGFuZGxlLWhjZWxsIGhhbmRsZS1jb2wtcG9ydCBoaWRkZW4iIGRh
;dGEtc29ydD0ibHBvcnQiPuacrOacuuerr+WPozxzcGFuIGNsYXNzPSJoLXNvcnQiPjwvc3Bhbj48L2Rpdj4KICAgICAgICAgICAg
;ICAgIDxkaXYgY2xhc3M9ImhhbmRsZS1oY2VsbCBoYW5kbGUtY29sLXJwb3J0IGhpZGRlbiIgZGF0YS1zb3J0PSJycG9ydCI+6L+c
;56iL56uv5Y+jPHNwYW4gY2xhc3M9Imgtc29ydCI+PC9zcGFuPjwvZGl2PgogICAgICAgICAgICAgICAgPGRpdiBjbGFzcz0iaGFu
;ZGxlLWhjZWxsIiBkYXRhLXNvcnQ9InR5cGUiPuexu+WeizxzcGFuIGNsYXNzPSJoLXNvcnQiPjwvc3Bhbj48L2Rpdj4KICAgICAg
;ICAgICAgICAgIDxkaXYgY2xhc3M9ImhhbmRsZS1oY2VsbCIgZGF0YS1zb3J0PSJoYW5kbGUiPuWPpeafhOWQjeensDxzcGFuIGNs
;YXNzPSJoLXNvcnQiPjwvc3Bhbj48L2Rpdj4KICAgICAgICAgICAgICA8L2Rpdj4KICAgICAgICAgICAgICA8ZGl2IGNsYXNzPSJo
;YW5kbGUtYm9keSIgaWQ9ImhhbmRsZS1ib2R5Ij4KICAgICAgICAgICAgICAgIDxkaXYgY2xhc3M9ImhhbmRsZS1lbXB0eSI+6L6T
;5YWl5YWz6ZSu5a2X5pCc5paH5Lu25Y+l5p+E77yb56uv5Y+j56S65L6LIDgwODB8ODAg5oiWIDAtMzAwfDUwMDwvZGl2PgogICAg
;ICAgICAgICAgIDwvZGl2PgogICAgICAgICAgICA8L2Rpdj4KICAgICAgICAgIDwvZGl2PgogICAgICAgICAgPGRpdiBpZD0iaW5m
;by1wYW5lbCIgY2xhc3M9ImhpZGRlbiBuby1kcmFnIGVtYmVkZGVkIj48L2Rpdj4KICAgICAgICA8L3NlY3Rpb24+CgogICAgICAg
;IDxzZWN0aW9uIGlkPSJwcmV2aWV3Ij4KICAgICAgICAgIDxkaXYgY2xhc3M9InB2LWJvZHkiIGlkPSJwdi1ib2R5Ij4KICAgICAg
;ICAgICAgPGRpdiBjbGFzcz0icHYtbWVkaWEiIGlkPSJwdi1tZWRpYSI+PGRpdiBjbGFzcz0icGgiPumihOiniOWMujwvZGl2Pjwv
;ZGl2PgogICAgICAgICAgICA8ZGl2IGNsYXNzPSJwdi10ZXh0IiBpZD0icHYtdGV4dCIgc3R5bGU9ImRpc3BsYXk6bm9uZSI+CiAg
;ICAgICAgICAgICAgPGRpdiBjbGFzcz0iaGQiIGlkPSJwdi10ZXh0LWhkIj7pooTop4jliY0gMjBLQiDlhoXlrrk8L2Rpdj4KICAg
;ICAgICAgICAgICA8cHJlIGlkPSJwdi1wcmUiPjwvcHJlPgogICAgICAgICAgICA8L2Rpdj4KICAgICAgICAgIDwvZGl2PgogICAg
;ICAgICAgPGRpdiBjbGFzcz0icHYtb2ZmIj7lt7LlhbPpl63mlofku7bpooTop4g8L2Rpdj4KICAgICAgICA8L3NlY3Rpb24+CiAg
;ICAgIDwvZGl2PgogICAgPC9kaXY+CgogICAgPGRpdiBpZD0iYmFyIj4KICAgICAgPGRpdiBjbGFzcz0iYmFyLWxlZnQiPgogICAg
;ICAgIDxidXR0b24gaWQ9ImJ0bi1zZXR0aW5ncyIgdHlwZT0iYnV0dG9uIiB0aXRsZT0i6K6+572uIj7impk8L2J1dHRvbj4KICAg
;ICAgPC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9ImJhci1tYWluIj4KICAgICAgICA8YnV0dG9uIGNsYXNzPSJzb3J0IiBpZD0iYnRu
;LXNvcnQiIHR5cGU9ImJ1dHRvbiIgdGl0bGU9IuWIh+aNouaOkuW6jyI+4oeFIDxzcGFuIGlkPSJzb3J0LWxhYmVsIj7mjInkv67m
;lLnml7bpl7TpmY3luo88L3NwYW4+PC9idXR0b24+CiAgICAgICAgPGxhYmVsIGNsYXNzPSJ0b2dnbGUiIHRpdGxlPSLlvIDlkK8v
;5YWz6Zet5Y+z5L6n6aKE6KeIIj4KICAgICAgICAgIDxpbnB1dCB0eXBlPSJjaGVja2JveCIgaWQ9ImNoay1wcmV2aWV3IiBjaGVj
;a2VkPgogICAgICAgICAgPHNwYW4gY2xhc3M9InN3Ij48L3NwYW4+CiAgICAgICAgICA8c3Bhbj7lvIDlkK/mlofku7bpooTop4g8
;L3NwYW4+CiAgICAgICAgPC9sYWJlbD4KICAgICAgICA8ZGl2IGNsYXNzPSJzcGFjZXIiPjwvZGl2PgogICAgICAgIDxkaXYgaWQ9
;ImJhci1oYW5kbGUtYWN0aW9ucyIgY2xhc3M9Im5vLWRyYWciPgogICAgICAgICAgPHNwYW4gaWQ9ImhhbmRsZS1zdGF0dXMiPjwv
;c3Bhbj4KICAgICAgICAgIDxidXR0b24gaWQ9ImJ0bi1wb3J0LW1hcmsiIHR5cGU9ImJ1dHRvbiIgdGl0bGU9Iuagh+iusOerr+WP
;oyI+4pqZPC9idXR0b24+CiAgICAgICAgICA8ZGl2IGlkPSJwb3J0LW1hcmstcG9wIiBjbGFzcz0ibm8tZHJhZyI+CiAgICAgICAg
;ICAgIDxkaXYgY2xhc3M9InBtcC1oZCI+5qCH6K6w56uv5Y+jPC9kaXY+CiAgICAgICAgICAgIDxkaXYgY2xhc3M9InBtcC1oaW50
;Ij7ljLnphY3nmoTmnKzmnLov6L+c56iL56uv5Y+j5Lya6auY5Lqu5pi+56S677yM5Y+v6Ieq6KGM5re75YqgPC9kaXY+CiAgICAg
;ICAgICAgIDxkaXYgY2xhc3M9InBtcC10YWdzIiBpZD0icG9ydC1tYXJrLXRhZ3MiPjwvZGl2PgogICAgICAgICAgICA8ZGl2IGNs
;YXNzPSJwbXAtYWRkIj4KICAgICAgICAgICAgICA8aW5wdXQgaWQ9InBvcnQtbWFyay1pbnB1dCIgdHlwZT0idGV4dCIgaW5wdXRt
;b2RlPSJudW1lcmljIiBwbGFjZWhvbGRlcj0i56uv5Y+j5Y+377yM5aaCIDkwMDAiIGF1dG9jb21wbGV0ZT0ib2ZmIiBzcGVsbGNo
;ZWNrPSJmYWxzZSI+CiAgICAgICAgICAgICAgPGJ1dHRvbiBpZD0icG9ydC1tYXJrLWFkZCIgdHlwZT0iYnV0dG9uIj7mt7vliqA8
;L2J1dHRvbj4KICAgICAgICAgICAgPC9kaXY+CiAgICAgICAgICAgIDxidXR0b24gaWQ9InBvcnQtbWFyay1yZXNldCIgdHlwZT0i
;YnV0dG9uIiBjbGFzcz0icG1wLXJlc2V0Ij7mgaLlpI3pu5jorqQ8L2J1dHRvbj4KICAgICAgICAgIDwvZGl2PgogICAgICAgIDwv
;ZGl2PgogICAgICAgIDxkaXYgaWQ9ImJhci1pbmZvLWFjdGlvbnMiIGNsYXNzPSJuby1kcmFnIj4KICAgICAgICAgIDxidXR0b24g
;aWQ9ImJ0bi1pbmZvLXJlZnJlc2giIHR5cGU9ImJ1dHRvbiI+5Yi35pawPC9idXR0b24+CiAgICAgICAgICA8YnV0dG9uIGlkPSJi
;dG4taW5mby1jb3B5IiB0eXBlPSJidXR0b24iPuWkjeWItjwvYnV0dG9uPgogICAgICAgIDwvZGl2PgogICAgICAgIDxkaXYgaWQ9
;ImNvdW50Ij7lhbEgMCDmnaHnu5Pmnpw8L2Rpdj4KICAgICAgPC9kaXY+CiAgICA8L2Rpdj4KICAgIDwvZGl2PgoKICAgIDxkaXYg
;aWQ9ImZpbHRlci1zZXR0aW5ncyIgY2xhc3M9Im5vLWRyYWciIHJvbGU9ImRpYWxvZyIgYXJpYS1tb2RhbD0idHJ1ZSIgYXJpYS1s
;YWJlbD0i562b6YCJ6K6+572uIj4KICAgICAgPGRpdiBjbGFzcz0iZnMtY2FyZCI+CiAgICAgICAgPGRpdiBjbGFzcz0iZnMtaGQi
;PgogICAgICAgICAgPHNwYW4+562b6YCJ5p2h5Lu2PC9zcGFuPgogICAgICAgICAgPGJ1dHRvbiB0eXBlPSJidXR0b24iIGlkPSJm
;cy1jbG9zZSIgdGl0bGU9IuWFs+mXrSI+w5c8L2J1dHRvbj4KICAgICAgICA8L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJmcy1i
;ZCI+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJmcy1oaW50Ij7lkK/nlKjnmoTpobnkvJrlh7rnjrDlnKjpobbpg6jvvJvngrnkuK3l
;kI7miorlr7nlupTmraPliJnliqDlhaXmkJzntKLvvIhFdmVyeXRoaW5nIDxjb2RlPnJlZ2V4OjwvY29kZT7vvInjgILlj6/mjpLl
;uo/jgIHnpoHnlKjmiJbliKDpmaTvvJvliKDpmaTlkI7lj6/nlKjjgIzmgaLlpI3pu5jorqTjgI3ov5jljp/lhoXnva7pobnjgII8
;L2Rpdj4KICAgICAgICAgIDxkaXYgY2xhc3M9ImZzLWxpc3QiIGlkPSJmcy1saXN0Ij48L2Rpdj4KICAgICAgICAgIDxkaXYgY2xh
;c3M9ImZzLWZvcm0iPgogICAgICAgICAgICA8ZGl2PgogICAgICAgICAgICAgIDxsYWJlbCBmb3I9ImZzLXRpdGxlIj7moIfpopg8
;L2xhYmVsPgogICAgICAgICAgICAgIDxpbnB1dCBpZD0iZnMtdGl0bGUiIHR5cGU9InRleHQiIG1heGxlbmd0aD0iMjQiIHBsYWNl
;aG9sZGVyPSLkvovlpoLvvJrkuI3lkKvkuLTml7bmlofku7YiIGF1dG9jb21wbGV0ZT0ib2ZmIj4KICAgICAgICAgICAgPC9kaXY+
;CiAgICAgICAgICAgIDxkaXY+CiAgICAgICAgICAgICAgPGxhYmVsIGZvcj0iZnMtcmVnZXgiPuato+WImeihqOi+vuW8jzwvbGFi
;ZWw+CiAgICAgICAgICAgICAgPGlucHV0IGlkPSJmcy1yZWdleCIgdHlwZT0idGV4dCIgbWF4bGVuZ3RoPSIyMDAiIHBsYWNlaG9s
;ZGVyPSLkvovlpoLvvJooP2kpXC50bXAkIiBhdXRvY29tcGxldGU9Im9mZiIgc3BlbGxjaGVjaz0iZmFsc2UiPgogICAgICAgICAg
;ICA8L2Rpdj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0iZnMtYWN0aW9ucyI+CiAgICAgICAgICAgICAgPGJ1dHRvbiB0eXBlPSJi
;dXR0b24iIGNsYXNzPSJwcmltYXJ5IiBpZD0iZnMtYWRkIj7liqDlhaXnrZvpgIk8L2J1dHRvbj4KICAgICAgICAgICAgPC9kaXY+
;CiAgICAgICAgICA8L2Rpdj4KICAgICAgICA8L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJmcy1mb290Ij4KICAgICAgICAgIDxi
;dXR0b24gdHlwZT0iYnV0dG9uIiBpZD0iZnMtZXYtb3B0cyI+5omT5byAIEV2ZXJ5dGhpbmcg6YCJ6aG54oCmPC9idXR0b24+CiAg
;ICAgICAgICA8YnV0dG9uIHR5cGU9ImJ1dHRvbiIgaWQ9ImZzLXJlc2V0IiB0aXRsZT0i5oGi5aSN5YaF572u562b6YCJ5bm25riF
;56m66Ieq5a6a5LmJIj7mgaLlpI3pu5jorqQ8L2J1dHRvbj4KICAgICAgICA8L2Rpdj4KICAgICAgPC9kaXY+CiAgICA8L2Rpdj4K
;CiAgICAgICAgPGRpdiBpZD0icHJvYy1tZW51IiByb2xlPSJtZW51Ij4KICAgICAgPGJ1dHRvbiB0eXBlPSJidXR0b24iIGRhdGEt
;cGFjdD0icmV2ZWFsIj48c3BhbiBjbGFzcz0iYy1pY28iIGFyaWEtaGlkZGVuPSJ0cnVlIj48c3ZnIHZpZXdCb3g9IjAgMCAyNCAy
;NCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0cm9rZS13aWR0aD0iMS44Ij48cGF0aCBkPSJNMyA3LjVBMS41
;IDEuNSAwIDAgMSA0LjUgNkg5bDIgMmg4LjVBMS41IDEuNSAwIDAgMSAyMSA5LjV2N0ExLjUgMS41IDAgMCAxIDE5LjUgMThoLTE1
;QTEuNSAxLjUgMCAwIDEgMyAxNi41di05eiIvPjwvc3ZnPjwvc3Bhbj48c3BhbiBjbGFzcz0icGFjdC1sYWJlbCI+5omT5byA6L+b
;56iL5omA5Zyo5L2N572uPC9zcGFuPjwvYnV0dG9uPgogICAgICA8YnV0dG9uIHR5cGU9ImJ1dHRvbiIgZGF0YS1wYWN0PSJjb3B5
;Ij48c3BhbiBjbGFzcz0iYy1pY28iIGFyaWEtaGlkZGVuPSJ0cnVlIj48c3ZnIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0ibm9u
;ZSIgc3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0cm9rZS13aWR0aD0iMS44Ij48cmVjdCB4PSI4IiB5PSI4IiB3aWR0aD0iMTEiIGhl
;aWdodD0iMTEiIHJ4PSIxLjUiLz48cGF0aCBkPSJNNSAxNVY1LjVBMS41IDEuNSAwIDAgMSA2LjUgNEgxNSIvPjwvc3ZnPjwvc3Bh
;bj48c3BhbiBjbGFzcz0icGFjdC1sYWJlbCIgaWQ9InByb2MtbWVudS1jb3B5Ij7lpI3liLbov5vnqIvlkI08L3NwYW4+PC9idXR0
;b24+CiAgICAgIDxidXR0b24gdHlwZT0iYnV0dG9uIiBkYXRhLXBhY3Q9ImNvcHlQaWQiPjxzcGFuIGNsYXNzPSJjLWljbyIgYXJp
;YS1oaWRkZW49InRydWUiPjxzdmcgdmlld0JveD0iMCAwIDI0IDI0IiBmaWxsPSJub25lIiBzdHJva2U9ImN1cnJlbnRDb2xvciIg
;c3Ryb2tlLXdpZHRoPSIxLjgiPjxwYXRoIGQ9Ik03IDdoNHY0SDd6TTEzIDdoNHY0aC00ek03IDEzaDR2NEg3ek0xMyAxM2g0djRo
;LTR6Ii8+PC9zdmc+PC9zcGFuPjxzcGFuIGNsYXNzPSJwYWN0LWxhYmVsIiBpZD0icHJvYy1tZW51LWNvcHlwaWQiPuWkjeWItui/
;m+eoi+WPtzwvc3Bhbj48L2J1dHRvbj4KICAgICAgPGJ1dHRvbiB0eXBlPSJidXR0b24iIGRhdGEtcGFjdD0iZW5kIiBjbGFzcz0i
;ZGFuZ2VyIiBpZD0icHJvYy1tZW51LWVuZCI+PHNwYW4gY2xhc3M9ImMtaWNvIiBhcmlhLWhpZGRlbj0idHJ1ZSI+PHN2ZyB2aWV3
;Qm94PSIwIDAgMjQgMjQiIGZpbGw9Im5vbmUiIHN0cm9rZT0iY3VycmVudENvbG9yIiBzdHJva2Utd2lkdGg9IjEuOCI+PGNpcmNs
;ZSBjeD0iMTIiIGN5PSIxMiIgcj0iOC41Ii8+PHBhdGggZD0iTTkgOWw2IDZNMTUgOWwtNiA2Ii8+PC9zdmc+PC9zcGFuPjxzcGFu
;IGNsYXNzPSJwYWN0LWxhYmVsIiBpZD0icHJvYy1tZW51LWVuZC1sYWJlbCI+5YWz6Zet6L+b56iLPC9zcGFuPjwvYnV0dG9uPgog
;ICAgPC9kaXY+CiAgICA8ZGF0YWxpc3QgaWQ9ImhhbmRsZS1oaXN0LWxpc3QiPjwvZGF0YWxpc3Q+CjwvZGl2PgoKICA8ZGl2IGlk
;PSJjdHgiIHJvbGU9Im1lbnUiPgogICAgPGJ1dHRvbiB0eXBlPSJidXR0b24iIGRhdGEtYWN0PSJyZXZlYWwiPjxzcGFuIGNsYXNz
;PSJjLWljbyI+PHN2ZyB2aWV3Qm94PSIwIDAgMjQgMjQiIGZpbGw9Im5vbmUiIHN0cm9rZT0iY3VycmVudENvbG9yIiBzdHJva2Ut
;d2lkdGg9IjEuOCI+PHBhdGggZD0iTTMgNy41QTEuNSAxLjUgMCAwIDEgNC41IDZIOWwyIDJoOC41QTEuNSAxLjUgMCAwIDEgMjEg
;OS41djdBMS41IDEuNSAwIDAgMSAxOS41IDE4aC0xNUExLjUgMS41IDAgMCAxIDMgMTYuNXYtOXoiLz48L3N2Zz48L3NwYW4+5paH
;5Lu25aS55Lit5pi+56S6PC9idXR0b24+CiAgICA8YnV0dG9uIHR5cGU9ImJ1dHRvbiIgZGF0YS1hY3Q9ImNvcHkiPjxzcGFuIGNs
;YXNzPSJjLWljbyI+PHN2ZyB2aWV3Qm94PSIwIDAgMjQgMjQiIGZpbGw9Im5vbmUiIHN0cm9rZT0iY3VycmVudENvbG9yIiBzdHJv
;a2Utd2lkdGg9IjEuOCI+PHJlY3QgeD0iOCIgeT0iOCIgd2lkdGg9IjExIiBoZWlnaHQ9IjExIiByeD0iMS41Ii8+PHBhdGggZD0i
;TTUgMTVWNS41QTEuNSAxLjUgMCAwIDEgNi41IDRIMTUiLz48L3N2Zz48L3NwYW4+5aSN5Yi2PC9idXR0b24+CiAgICA8YnV0dG9u
;IHR5cGU9ImJ1dHRvbiIgZGF0YS1hY3Q9ImNvcHlQYXRoIj48c3BhbiBjbGFzcz0iYy1pY28iPjxzdmcgdmlld0JveD0iMCAwIDI0
;IDI0IiBmaWxsPSJub25lIiBzdHJva2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIxLjgiPjxwYXRoIGQ9Ik04IDEyaDgi
;Lz48cGF0aCBkPSJNMTAgN0g3LjVBMi41IDIuNSAwIDAgMCA1IDkuNXY1QTIuNSAyLjUgMCAwIDAgNy41IDE3SDEwIi8+PHBhdGgg
;ZD0iTTE0IDdoMi41QTIuNSAyLjUgMCAwIDEgMTkgOS41djVBMi41IDIuNSAwIDAgMSAxNi41IDE3SDE0Ii8+PC9zdmc+PC9zcGFu
;PuWkjeWItui3r+W+hDwvYnV0dG9uPgogICAgPGJ1dHRvbiB0eXBlPSJidXR0b24iIGRhdGEtYWN0PSJjb3B5RGlyIj48c3BhbiBj
;bGFzcz0iYy1pY28iPjxzdmcgdmlld0JveD0iMCAwIDI0IDI0IiBmaWxsPSJub25lIiBzdHJva2U9ImN1cnJlbnRDb2xvciIgc3Ry
;b2tlLXdpZHRoPSIxLjgiPjxwYXRoIGQ9Ik05IDguNWEzLjUgMy41IDAgMCAxIDUuNi0yLjhsMS43IDEuNGEzLjUgMy41IDAgMCAx
;LTIuMiA2LjJIMTMiLz48cGF0aCBkPSJNMTUgMTUuNWEzLjUgMy41IDAgMCAxLTUuNiAyLjhsLTEuNy0xLjRhMy41IDMuNSAwIDAg
;MSAyLjItNi4ySDExIi8+PC9zdmc+PC9zcGFuPuWkjeWItuaJgOWcqOi3r+W+hDwvYnV0dG9uPgogICAgPGJ1dHRvbiB0eXBlPSJi
;dXR0b24iIGRhdGEtYWN0PSJyZWN5Y2xlIiBjbGFzcz0iZGFuZ2VyIj48c3BhbiBjbGFzcz0iYy1pY28iPjxzdmcgdmlld0JveD0i
;MCAwIDI0IDI0IiBmaWxsPSJub25lIiBzdHJva2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIxLjgiPjxwYXRoIGQ9Ik01
;IDhoMTQiLz48cGF0aCBkPSJNOSA4VjYuNUExLjUgMS41IDAgMCAxIDEwLjUgNWgzQTEuNSAxLjUgMCAwIDEgMTUgNi41VjgiLz48
;cGF0aCBkPSJNNy41IDhsLjcgMTFhMS41IDEuNSAwIDAgMCAxLjUgMS40aDQuNmExLjUgMS41IDAgMCAwIDEuNS0xLjRsLjctMTEi
;Lz48L3N2Zz48L3NwYW4+5Yig6ZmkKOWbnuaUtuermSk8L2J1dHRvbj4KICA8L2Rpdj4KPC9kaXY+CjxzY3JpcHQ+CigoKSA9PiB7
;CiAgY29uc3QgYm9vdCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdib290Jyk7CiAgY29uc3QgY2hyb21lID0gZG9jdW1lbnQu
;Z2V0RWxlbWVudEJ5SWQoJ2Nocm9tZScpOwogIGNvbnN0IGFwcFJvb3QgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYXBwJyk7
;CiAgY29uc3QgdGl0bGViYXIgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgndGl0bGViYXInKTsKICBjb25zdCByaW5nRmcgPSBk
;b2N1bWVudC5nZXRFbGVtZW50QnlJZCgncmluZy1mZycpOwogIGNvbnN0IGJvb3RQY3QgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJ
;ZCgnYm9vdC1wY3QnKTsKICBjb25zdCBxRWwgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgncScpOwogIGNvbnN0IGxpc3RFbCA9
;IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdsaXN0Jyk7CiAgY29uc3QgZW1wdHlFbCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlk
;KCdsaXN0LWVtcHR5Jyk7CiAgY29uc3QgY291bnRFbCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjb3VudCcpOwogIGNvbnN0
;IHB2TWV0YSA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdwdi1tZXRhJyk7CiAgY29uc3QgcHZNZWRpYSA9IGRvY3VtZW50Lmdl
;dEVsZW1lbnRCeUlkKCdwdi1tZWRpYScpOwogIGNvbnN0IHB2VGV4dCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdwdi10ZXh0
;Jyk7CiAgY29uc3QgcHZCb2R5ID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3B2LWJvZHknKTsKICBjb25zdCBwdlByZSA9IGRv
;Y3VtZW50LmdldEVsZW1lbnRCeUlkKCdwdi1wcmUnKTsKICBjb25zdCBwdlRleHRIZCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlk
;KCdwdi10ZXh0LWhkJyk7CiAgY29uc3QgcHJldmlldyA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdwcmV2aWV3Jyk7CiAgY29u
;c3QgY2hrUHJldmlldyA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjaGstcHJldmlldycpOwogIGNvbnN0IHNvcnRMYWJlbCA9
;IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzb3J0LWxhYmVsJyk7CiAgY29uc3QgQ0lSQyA9IDIgKiBNYXRoLlBJICogNTI7Cgog
;IGxldCBjYXQgPSAnYWxsJzsKICBsZXQgYXBwTW9kZSA9ICdmaWxlJzsgLy8gZmlsZSB8IGhhbmRsZSB8IGluZm8KICBjb25zdCBQ
;TEFDRUhPTERFUl9GSUxFID0gJ+i+k+WFpeaWh+S7tuWQjSAvIOaJqeWxleWQjSAvIOi3r+W+hOWFs+mUruWtl++8m3wg6KGo56S6
;5LiU77yMfHwg6KGo56S65oiWJzsKICBjb25zdCBQTEFDRUhPTERFUl9IQU5ETEUgPSAn5paH5Lu25Y+l5p+E5YWz6ZSu5a2X77yM
;5oiW56uv5Y+jIDgwODB8ODDjgIEwLTMwMHw1MDAnOwogIGNvbnN0IFBMQUNFSE9MREVSX0lORk8gPSAn5pys5py65L+h5oGv5peg
;6ZyA5YWz6ZSu5a2X77yM54K55bem5L6n5Y2z5Y+v5p+l55yLJzsKICAvLyDmnKzlnLDmkJzntKIgLyDlj6Xmn4TmkJzntKLlkITo
;h6rkv53nlZnovpPlhaXmnaHku7bvvIzkupLkuI3kuLLlj7AKICBjb25zdCBtb2RlUXVlcnkgPSB7IGZpbGU6ICcnLCBoYW5kbGU6
;ICcnLCBpbmZvOiAnJyB9OwogIGxldCBzb3J0ID0gJ2RhdGUtZGVzYyc7CiAgbGV0IGRyaXZlID0gJyc7IC8vICcnID0gYWxsIGRp
;c2tzLCAnQycgLyAnRCcgLyAuLi4KICBsZXQgaXRlbXMgPSBbXTsKICBsZXQgc2VsZWN0ZWQgPSAtMTsKICBsZXQgcHJldmlld09u
;ID0gdHJ1ZTsKICBsZXQgc2VhcmNoVGltZXIgPSAwOwogIGxldCBnZW4gPSAwOwogIGxldCB0b3RhbEhpdHMgPSAwOwogIGxldCBs
;b2FkaW5nTW9yZSA9IGZhbHNlOwogIGxldCBoYXNNb3JlID0gZmFsc2U7CgogIGNvbnN0IGRyaXZlTGFiZWwgPSBkb2N1bWVudC5n
;ZXRFbGVtZW50QnlJZCgnZHJpdmUtbGFiZWwnKTsKICBjb25zdCBkcml2ZU1lbnUgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgn
;ZHJpdmUtbWVudScpOwogIGNvbnN0IGJ0bkRyaXZlID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2J0bi1kcml2ZScpOwogIGNv
;bnN0IGRyaXZlQnRuSWNvID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2RyaXZlLWJ0bi1pY28nKTsKICBsZXQgZHJpdmVNZXRh
;ID0geyBjb21wdXRlcjogJycsIGRyaXZlczogW10gfTsKCiAgZnVuY3Rpb24gZHJpdmVUZXh0KCkgewogICAgaWYgKCFkcml2ZSkg
;cmV0dXJuICflhajnm5jmkJzntKInOwogICAgY29uc3QgaGl0ID0gKGRyaXZlTWV0YS5kcml2ZXMgfHwgW10pLmZpbmQoZCA9PiBT
;dHJpbmcoZC5sZXR0ZXIgfHwgJycpLnRvVXBwZXJDYXNlKCkgPT09IGRyaXZlKTsKICAgIGlmIChoaXQgJiYgaGl0LmxhYmVsKSBy
;ZXR1cm4gaGl0LmxhYmVsOwogICAgcmV0dXJuIGRyaXZlLnRvVXBwZXJDYXNlKCkgKyAnIOebmCc7CiAgfQogIGZ1bmN0aW9uIHNl
;dEJ0bkljb24odXJsKSB7CiAgICBpZiAodXJsKSB7CiAgICAgIGRyaXZlQnRuSWNvLnNyYyA9IHVybCArICh1cmwuaW5jbHVkZXMo
;Jz8nKSA/ICcmJyA6ICc/JykgKyAndD0nICsgRGF0ZS5ub3coKTsKICAgICAgZHJpdmVCdG5JY28uY2xhc3NMaXN0LnJlbW92ZSgn
;aGlkZGVuJyk7CiAgICB9IGVsc2UgewogICAgICBkcml2ZUJ0bkljby5yZW1vdmVBdHRyaWJ1dGUoJ3NyYycpOwogICAgICBkcml2
;ZUJ0bkljby5jbGFzc0xpc3QuYWRkKCdoaWRkZW4nKTsKICAgIH0KICB9CiAgZnVuY3Rpb24gc3luY0RyaXZlQnV0dG9uKCkgewog
;ICAgZHJpdmVMYWJlbC50ZXh0Q29udGVudCA9IGRyaXZlVGV4dCgpOwogICAgaWYgKCFkcml2ZSkgc2V0QnRuSWNvbihkcml2ZU1l
;dGEuY29tcHV0ZXIgfHwgJycpOwogICAgZWxzZSB7CiAgICAgIGNvbnN0IGhpdCA9IChkcml2ZU1ldGEuZHJpdmVzIHx8IFtdKS5m
;aW5kKGQgPT4gU3RyaW5nKGQubGV0dGVyIHx8ICcnKS50b1VwcGVyQ2FzZSgpID09PSBkcml2ZSk7CiAgICAgIHNldEJ0bkljb24o
;KGhpdCAmJiBoaXQuaWNvbikgfHwgZHJpdmVNZXRhLmNvbXB1dGVyIHx8ICcnKTsKICAgIH0KICB9CiAgZnVuY3Rpb24gaWNvSHRt
;bCh1cmwpIHsKICAgIHJldHVybiB1cmwgPyAnPGltZyBzcmM9IicgKyBTdHJpbmcodXJsKS5yZXBsYWNlKC8iL2csICcnKSArICci
;IGFsdD0iIj4nIDogJyc7CiAgfQogIGZ1bmN0aW9uIHJlbmRlckRyaXZlTWVudSgpIHsKICAgIGNvbnN0IGRyaXZlcyA9IEFycmF5
;LmlzQXJyYXkoZHJpdmVNZXRhLmRyaXZlcykgPyBkcml2ZU1ldGEuZHJpdmVzIDogW107CiAgICBsZXQgaHRtbCA9ICc8YnV0dG9u
;IHR5cGU9ImJ1dHRvbiIgZGF0YS1kcml2ZT0iIicgKyAoIWRyaXZlID8gJyBjbGFzcz0ib24iJyA6ICcnKSArICc+JwogICAgICAr
;IGljb0h0bWwoZHJpdmVNZXRhLmNvbXB1dGVyKSArICc8c3Bhbj7lhajnm5jmkJzntKI8L3NwYW4+PC9idXR0b24+JzsKICAgIGZv
;ciAoY29uc3QgZCBvZiBkcml2ZXMpIHsKICAgICAgY29uc3QgbGV0dGVyID0gU3RyaW5nKGQubGV0dGVyIHx8IGQgfHwgJycpLnJl
;cGxhY2UoLzokLywgJycpLnRvVXBwZXJDYXNlKCk7CiAgICAgIGlmICghbGV0dGVyKSBjb250aW51ZTsKICAgICAgY29uc3QgbGFi
;ZWwgPSBkLmxhYmVsIHx8IChsZXR0ZXIgKyAnIOebmCcpOwogICAgICBodG1sICs9ICc8YnV0dG9uIHR5cGU9ImJ1dHRvbiIgZGF0
;YS1kcml2ZT0iJyArIGxldHRlciArICciJwogICAgICAgICsgKGRyaXZlID09PSBsZXR0ZXIgPyAnIGNsYXNzPSJvbiInIDogJycp
;ICsgJz4nCiAgICAgICAgKyBpY29IdG1sKGQuaWNvbiB8fCAnJykgKyAnPHNwYW4+JyArIGxhYmVsICsgJzwvc3Bhbj48L2J1dHRv
;bj4nOwogICAgfQogICAgZHJpdmVNZW51LmlubmVySFRNTCA9IGh0bWw7CiAgICBkcml2ZU1lbnUucXVlcnlTZWxlY3RvckFsbCgn
;YnV0dG9uJykuZm9yRWFjaChidG4gPT4gewogICAgICBidG4ub25jbGljayA9IChlKSA9PiB7CiAgICAgICAgZS5zdG9wUHJvcGFn
;YXRpb24oKTsKICAgICAgICBkcml2ZSA9IGJ0bi5nZXRBdHRyaWJ1dGUoJ2RhdGEtZHJpdmUnKSB8fCAnJzsKICAgICAgICBkcml2
;ZU1lbnUuY2xhc3NMaXN0LnJlbW92ZSgnb24nKTsKICAgICAgICBzeW5jRHJpdmVCdXR0b24oKTsKICAgICAgICByZW5kZXJEcml2
;ZU1lbnUoKTsKICAgICAgICBkb1NlYXJjaCgpOwogICAgICB9OwogICAgfSk7CiAgfQogIHdpbmRvdy5fX3NldERyaXZlcyA9IChw
;YXlsb2FkKSA9PiB7CiAgICB0cnkgewogICAgICBjb25zdCBkYXRhID0gdHlwZW9mIHBheWxvYWQgPT09ICdzdHJpbmcnID8gSlNP
;Ti5wYXJzZShwYXlsb2FkKSA6IHBheWxvYWQ7CiAgICAgIGlmIChBcnJheS5pc0FycmF5KGRhdGEpKSB7CiAgICAgICAgZHJpdmVN
;ZXRhID0gewogICAgICAgICAgY29tcHV0ZXI6ICcnLAogICAgICAgICAgZHJpdmVzOiBkYXRhLm1hcCh4ID0+IHR5cGVvZiB4ID09
;PSAnc3RyaW5nJwogICAgICAgICAgICA/ICh7IGxldHRlcjogeCwgaWNvbjogJycsIGxhYmVsOiBTdHJpbmcoeCkudG9VcHBlckNh
;c2UoKSArICcg55uYJyB9KQogICAgICAgICAgICA6IHgpCiAgICAgICAgfTsKICAgICAgfSBlbHNlIHsKICAgICAgICBkcml2ZU1l
;dGEgPSB7CiAgICAgICAgICBjb21wdXRlcjogKGRhdGEgJiYgZGF0YS5jb21wdXRlcikgfHwgJycsCiAgICAgICAgICBkcml2ZXM6
;IEFycmF5LmlzQXJyYXkoZGF0YSAmJiBkYXRhLmRyaXZlcykgPyBkYXRhLmRyaXZlcyA6IFtdCiAgICAgICAgfTsKICAgICAgfQog
;ICAgICBzeW5jRHJpdmVCdXR0b24oKTsKICAgICAgcmVuZGVyRHJpdmVNZW51KCk7CiAgICB9IGNhdGNoIChlKSB7IGNvbnNvbGUu
;d2Fybignc2V0RHJpdmVzJywgZSk7IH0KICB9OwoKICBjb25zdCBISVNUX0tFWSA9ICdsb2NhbF9zZWFyY2hfaGlzdF92MSc7CiAg
;Y29uc3QgSElTVF9NQVggPSAxMDsKICBjb25zdCBzZWFyY2hCb3ggPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc2VhcmNoLWJv
;eCcpOwogIGNvbnN0IGhpc3RNZW51ID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2hpc3QtbWVudScpOwogIGNvbnN0IGJ0bkhp
;c3QgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYnRuLWhpc3QnKTsKICBjb25zdCBidG5DbGVhciA9IGRvY3VtZW50LmdldEVs
;ZW1lbnRCeUlkKCdidG4tY2xlYXInKTsKICBsZXQgaGlzdElkbGVUaW1lciA9IDA7CgogIGZ1bmN0aW9uIHN5bmNDbGVhckJ0bigp
;IHsKICAgIGJ0bkNsZWFyLmNsYXNzTGlzdC50b2dnbGUoJ29uJywgISEocUVsLnZhbHVlIHx8ICcnKS50cmltKCkpOwogIH0KICBm
;dW5jdGlvbiBjbGVhclNlYXJjaCgpIHsKICAgIGNsZWFyVGltZW91dChoaXN0SWRsZVRpbWVyKTsKICAgIHFFbC52YWx1ZSA9ICcn
;OwogICAgaWYgKGFwcE1vZGUgPT09ICdmaWxlJykgbW9kZVF1ZXJ5LmZpbGUgPSAnJzsKICAgIGVsc2UgaWYgKGFwcE1vZGUgPT09
;ICdoYW5kbGUnKSBtb2RlUXVlcnkuaGFuZGxlID0gJyc7CiAgICBlbHNlIGlmIChhcHBNb2RlID09PSAnaW5mbycpIG1vZGVRdWVy
;eS5pbmZvID0gJyc7CiAgICBzeW5jQ2xlYXJCdG4oKTsKICAgIGhpc3RNZW51LmNsYXNzTGlzdC5yZW1vdmUoJ29uJyk7CiAgICBz
;ZWFyY2hCb3guY2xhc3NMaXN0LnJlbW92ZSgnaGlzdC1vcGVuJyk7CiAgICBidG5IaXN0LmNsYXNzTGlzdC5yZW1vdmUoJ29uJyk7
;CiAgICBxRWwuZm9jdXMoKTsKICAgIGlmIChhcHBNb2RlID09PSAnaGFuZGxlJykgewogICAgICAvLyDmuIXnqbrmnaHku7blkI7k
;u43mmL7npLrlhajpg6jov57mjqXvvIjkuI3mioogMC02NTUzNSDlhpnlm57ovpPlhaXmoYbvvIkKICAgICAgcmVxdWVzdEhhbmRs
;ZVNlYXJjaCgnJyk7CiAgICAgIHJldHVybjsKICAgIH0KICAgIGlmIChhcHBNb2RlID09PSAnaW5mbycpIHJldHVybjsKICAgIGRv
;U2VhcmNoKCk7CiAgfQogIGJ0bkNsZWFyLm9uY2xpY2sgPSAoZSkgPT4gewogICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgIGNs
;ZWFyU2VhcmNoKCk7CiAgfTsKCiAgZnVuY3Rpb24gbG9hZEhpc3QoKSB7CiAgICB0cnkgewogICAgICBjb25zdCByYXcgPSBsb2Nh
;bFN0b3JhZ2UuZ2V0SXRlbShISVNUX0tFWSk7CiAgICAgIGNvbnN0IGFyciA9IHJhdyA/IEpTT04ucGFyc2UocmF3KSA6IFtdOwog
;ICAgICByZXR1cm4gQXJyYXkuaXNBcnJheShhcnIpID8gYXJyLm1hcCh4ID0+IFN0cmluZyh4IHx8ICcnKS50cmltKCkpLmZpbHRl
;cihCb29sZWFuKS5zbGljZSgwLCBISVNUX01BWCkgOiBbXTsKICAgIH0gY2F0Y2ggKF8pIHsgcmV0dXJuIFtdOyB9CiAgfQogIGZ1
;bmN0aW9uIHNhdmVIaXN0KGxpc3QpIHsKICAgIHRyeSB7IGxvY2FsU3RvcmFnZS5zZXRJdGVtKEhJU1RfS0VZLCBKU09OLnN0cmlu
;Z2lmeShsaXN0LnNsaWNlKDAsIEhJU1RfTUFYKSkpOyB9IGNhdGNoIChfKSB7fQogIH0KICBmdW5jdGlvbiBwdXNoSGlzdChxKSB7
;CiAgICBxID0gU3RyaW5nKHEgfHwgJycpLnRyaW0oKTsKICAgIGlmICghcSkgcmV0dXJuOwogICAgaWYgKHR5cGVvZiBhcHBNb2Rl
;ICE9PSAndW5kZWZpbmVkJyAmJiBhcHBNb2RlID09PSAnaW5mbycpIHJldHVybjsKICAgIGlmICh0eXBlb2YgYXBwTW9kZSAhPT0g
;J3VuZGVmaW5lZCcgJiYgYXBwTW9kZSA9PT0gJ2hhbmRsZScpIHsKICAgICAgaWYgKHR5cGVvZiBzYXZlSGFuZGxlSGlzdCA9PT0g
;J2Z1bmN0aW9uJykgc2F2ZUhhbmRsZUhpc3QocSk7CiAgICAgIGlmIChoaXN0TWVudS5jbGFzc0xpc3QuY29udGFpbnMoJ29uJykp
;IHJlbmRlckhpc3RNZW51KCk7CiAgICAgIHJldHVybjsKICAgIH0KICAgIGNvbnN0IGxpc3QgPSBsb2FkSGlzdCgpLmZpbHRlcih4
;ID0+IHggIT09IHEpOwogICAgbGlzdC51bnNoaWZ0KHEpOwogICAgc2F2ZUhpc3QobGlzdCk7CiAgICBpZiAoaGlzdE1lbnUuY2xh
;c3NMaXN0LmNvbnRhaW5zKCdvbicpKSByZW5kZXJIaXN0TWVudSgpOwogIH0KICBmdW5jdGlvbiBlc2NhcGVBdHRyKHMpIHsKICAg
;IHJldHVybiBTdHJpbmcocyB8fCAnJykucmVwbGFjZSgvJi9nLCAnJmFtcDsnKS5yZXBsYWNlKC8iL2csICcmcXVvdDsnKS5yZXBs
;YWNlKC88L2csICcmbHQ7Jyk7CiAgfQogIGZ1bmN0aW9uIHJlbmRlckhpc3RNZW51KCkgewogICAgY29uc3QgaGFuZGxlTW9kZSA9
;IHR5cGVvZiBhcHBNb2RlICE9PSAndW5kZWZpbmVkJyAmJiBhcHBNb2RlID09PSAnaGFuZGxlJzsKICAgIGNvbnN0IGxpc3QgPSBo
;YW5kbGVNb2RlICYmIHR5cGVvZiBsb2FkSGFuZGxlSGlzdCA9PT0gJ2Z1bmN0aW9uJyA/IGxvYWRIYW5kbGVIaXN0KCkgOiBsb2Fk
;SGlzdCgpOwogICAgaWYgKCFsaXN0Lmxlbmd0aCkgewogICAgICBoaXN0TWVudS5pbm5lckhUTUwgPSAnPGRpdiBjbGFzcz0iaGlz
;dC1lbXB0eSI+JyArIChoYW5kbGVNb2RlID8gJ+aaguaXoOWPpeafhC/nq6/lj6PmkJzntKLorrDlvZUnIDogJ+aaguaXoOacgOi/
;keaQnOe0oicpICsgJzwvZGl2Pic7CiAgICAgIHJldHVybjsKICAgIH0KICAgIGhpc3RNZW51LmlubmVySFRNTCA9IGxpc3QubWFw
;KHEgPT4KICAgICAgJzxidXR0b24gdHlwZT0iYnV0dG9uIiBkYXRhLXE9IicgKyBlc2NhcGVBdHRyKHEpICsgJyIgdGl0bGU9Iicg
;KyBlc2NhcGVBdHRyKHEpICsgJyI+JwogICAgICArIGVzY2FwZUF0dHIocSkgKyAnPC9idXR0b24+JwogICAgKS5qb2luKCcnKTsK
;ICAgIGhpc3RNZW51LnF1ZXJ5U2VsZWN0b3JBbGwoJ2J1dHRvbicpLmZvckVhY2goYnRuID0+IHsKICAgICAgYnRuLm9uY2xpY2sg
;PSAoZSkgPT4gewogICAgICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAgICAgY29uc3QgcSA9IGJ0bi5nZXRBdHRyaWJ1dGUo
;J2RhdGEtcScpIHx8ICcnOwogICAgICAgIGhpc3RNZW51LmNsYXNzTGlzdC5yZW1vdmUoJ29uJyk7CiAgICAgICAgc2VhcmNoQm94
;LmNsYXNzTGlzdC5yZW1vdmUoJ2hpc3Qtb3BlbicpOwogICAgICAgIGJ0bkhpc3QuY2xhc3NMaXN0LnJlbW92ZSgnb24nKTsKICAg
;ICAgICBxRWwudmFsdWUgPSBxOwogICAgICAgIGlmIChhcHBNb2RlID09PSAnZmlsZScpIG1vZGVRdWVyeS5maWxlID0gcTsKICAg
;ICAgICBlbHNlIGlmIChhcHBNb2RlID09PSAnaGFuZGxlJykgbW9kZVF1ZXJ5LmhhbmRsZSA9IHE7CiAgICAgICAgcHVzaEhpc3Qo
;cSk7CiAgICAgICAgc3luY0NsZWFyQnRuKCk7CiAgICAgICAgZG9TZWFyY2goKTsKICAgICAgfTsKICAgIH0pOwogIH0KICBidG5E
;cml2ZS5vbmNsaWNrID0gKGUpID0+IHsKICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICBjbG9zZUhpc3RNZW51KCk7CiAgICBk
;cml2ZU1lbnUuY2xhc3NMaXN0LnRvZ2dsZSgnb24nKTsKICB9OwogIGZ1bmN0aW9uIGNsb3NlSGlzdE1lbnUoKSB7CiAgICBoaXN0
;TWVudS5jbGFzc0xpc3QucmVtb3ZlKCdvbicpOwogICAgc2VhcmNoQm94LmNsYXNzTGlzdC5yZW1vdmUoJ2hpc3Qtb3BlbicpOwog
;ICAgYnRuSGlzdC5jbGFzc0xpc3QucmVtb3ZlKCdvbicpOwogIH0KICBmdW5jdGlvbiBvcGVuSGlzdE1lbnUoKSB7CiAgICBpZiAo
;YXBwTW9kZSA9PT0gJ2luZm8nKSByZXR1cm47CiAgICBkcml2ZU1lbnUuY2xhc3NMaXN0LnJlbW92ZSgnb24nKTsKICAgIHJlbmRl
;ckhpc3RNZW51KCk7CiAgICBoaXN0TWVudS5jbGFzc0xpc3QuYWRkKCdvbicpOwogICAgc2VhcmNoQm94LmNsYXNzTGlzdC5hZGQo
;J2hpc3Qtb3BlbicpOwogICAgYnRuSGlzdC5jbGFzc0xpc3QuYWRkKCdvbicpOwogIH0KICBidG5IaXN0Lm9uY2xpY2sgPSAoZSkg
;PT4gewogICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgIGlmIChoaXN0TWVudS5jbGFzc0xpc3QuY29udGFpbnMoJ29uJykpIGNs
;b3NlSGlzdE1lbnUoKTsKICAgIGVsc2Ugb3Blbkhpc3RNZW51KCk7CiAgfTsKICBoaXN0TWVudS5hZGRFdmVudExpc3RlbmVyKCdj
;bGljaycsIGUgPT4gZS5zdG9wUHJvcGFnYXRpb24oKSk7CiAgZG9jdW1lbnQuYWRkRXZlbnRMaXN0ZW5lcignY2xpY2snLCAoKSA9
;PiB7CiAgICBkcml2ZU1lbnUuY2xhc3NMaXN0LnJlbW92ZSgnb24nKTsKICAgIGNsb3NlSGlzdE1lbnUoKTsKICAgIGhpZGVDdHgo
;KTsKICB9KTsKICByZW5kZXJEcml2ZU1lbnUoKTsKICByZW5kZXJIaXN0TWVudSgpOwogIHN5bmNDbGVhckJ0bigpOwoKICAvLyBQ
;cmltYXJ5IFVJ4oaSQUhLIGNoYW5uZWw6IGluLXBhZ2UgcXVldWUgZHJhaW5lZCBieSBBSEsgRXhlY3V0ZVNjcmlwdC4KICAvLyBO
;ZXZlciB1c2UgaG9zdE9iamVjdHMuc3luYyDigJQgaXQgZGVhZGxvY2tzIFdlYlZpZXcyIGFuZCBibG9ja3MgcG9zdE1lc3NhZ2Ug
;dG9vLgogIHdpbmRvdy5fX2Foa1EgPSB3aW5kb3cuX19haGtRIHx8IFtdOwogIGZ1bmN0aW9uIGVucXVldWUobXNnKSB7CiAgICB0
;cnkgewogICAgICB3aW5kb3cuX19haGtRLnB1c2goU3RyaW5nKG1zZykpOwogICAgICAvLyBUaXAgQUhLIHBvbGxlciB2aWEgdGl0
;bGUgY2hhbmdlIChvcHRpb25hbCBmYXN0IHBhdGgpCiAgICAgIHRyeSB7IGRvY3VtZW50LmRvY3VtZW50RWxlbWVudC5kYXRhc2V0
;LmFoa1BlbmRpbmcgPSBTdHJpbmcod2luZG93Ll9fYWhrUS5sZW5ndGgpOyB9IGNhdGNoIChfKSB7fQogICAgfSBjYXRjaCAoZSkg
;eyBjb25zb2xlLndhcm4oJ2VucXVldWUnLCBlKTsgfQogIH0KICBmdW5jdGlvbiBwb3N0KG1zZykgewogICAgZW5xdWV1ZShtc2cp
;OwogICAgdHJ5IHsKICAgICAgaWYgKHdpbmRvdy5jaHJvbWUgJiYgY2hyb21lLndlYnZpZXcgJiYgdHlwZW9mIGNocm9tZS53ZWJ2
;aWV3LnBvc3RNZXNzYWdlID09PSAnZnVuY3Rpb24nKSB7CiAgICAgICAgY2hyb21lLndlYnZpZXcucG9zdE1lc3NhZ2UoU3RyaW5n
;KG1zZykpOwogICAgICAgIHJldHVybiB0cnVlOwogICAgICB9CiAgICB9IGNhdGNoIChlKSB7IGNvbnNvbGUud2FybigncG9zdCcs
;IGUpOyB9CiAgICByZXR1cm4gZmFsc2U7CiAgfQogIGZ1bmN0aW9uIGNhbGxIb3N0KG1ldGhvZCwgLi4uYXJncykgewogICAgbGV0
;IG1zZyA9ICcnOwogICAgaWYgKG1ldGhvZCA9PT0gJ3NlYXJjaCcpIHsKICAgICAgY29uc3QgW3EsIGMsIHMsIG9mZnNldF0gPSBh
;cmdzOwogICAgICBtc2cgPSAnc2VhcmNofCcgKyBKU09OLnN0cmluZ2lmeSh7CiAgICAgICAgcTogcSB8fCAnJywgY2F0OiBjIHx8
;ICdhbGwnLCBzb3J0OiBzIHx8ICdkYXRlLWRlc2MnLAogICAgICAgIGRyaXZlOiBkcml2ZSB8fCAnJywKICAgICAgICBvZmZzZXQ6
;IE51bWJlcihvZmZzZXQpIHx8IDAsIGdlbjogKytnZW4KICAgICAgfSk7CiAgICB9IGVsc2UgaWYgKG1ldGhvZCA9PT0gJ3ByZXZp
;ZXcnKSB7CiAgICAgIG1zZyA9ICdwcmV2aWV3fCcgKyAoYXJnc1swXSB8fCAnJyk7CiAgICB9IGVsc2UgaWYgKG1ldGhvZCA9PT0g
;J29wZW4nKSB7CiAgICAgIG1zZyA9ICdvcGVufCcgKyAoYXJnc1swXSB8fCAnJyk7CiAgICB9IGVsc2UgaWYgKG1ldGhvZCA9PT0g
;J3JldmVhbCcpIHsKICAgICAgbXNnID0gJ3JldmVhbHwnICsgKGFyZ3NbMF0gfHwgJycpOwogICAgfSBlbHNlIGlmIChtZXRob2Qg
;PT09ICdjb3B5RmlsZScpIHsKICAgICAgbXNnID0gJ2NvcHlGaWxlfCcgKyAoYXJnc1swXSB8fCAnJyk7CiAgICB9IGVsc2UgaWYg
;KG1ldGhvZCA9PT0gJ2NvcHlQYXRoJykgewogICAgICBtc2cgPSAnY29weVBhdGh8JyArIChhcmdzWzBdIHx8ICcnKTsKICAgIH0g
;ZWxzZSBpZiAobWV0aG9kID09PSAnY29weURpcicpIHsKICAgICAgbXNnID0gJ2NvcHlEaXJ8JyArIChhcmdzWzBdIHx8ICcnKTsK
;ICAgIH0gZWxzZSBpZiAobWV0aG9kID09PSAncmVjeWNsZScpIHsKICAgICAgbXNnID0gJ3JlY3ljbGV8JyArIChhcmdzWzBdIHx8
;ICcnKTsKICAgIH0gZWxzZSBpZiAobWV0aG9kID09PSAnY2xvc2UnIHx8IG1ldGhvZCA9PT0gJ21pbmltaXplJyB8fCBtZXRob2Qg
;PT09ICdtYXhpbWl6ZScgfHwgbWV0aG9kID09PSAnZHJhZycpIHsKICAgICAgbXNnID0gbWV0aG9kOwogICAgfSBlbHNlIHsKICAg
;ICAgbXNnID0gbWV0aG9kICsgJ3wnICsgYXJncy5tYXAoYSA9PiBTdHJpbmcoYSA/PyAnJykpLmpvaW4oJ3wnKTsKICAgIH0KICAg
;IHBvc3QobXNnKTsKICB9CgogIGZ1bmN0aW9uIHNldEJvb3RQY3QocCkgewogICAgcCA9IE1hdGgubWF4KDAsIE1hdGgubWluKDEw
;MCwgTnVtYmVyKHApIHx8IDApKTsKICAgIGJvb3RQY3QudGV4dENvbnRlbnQgPSBNYXRoLnJvdW5kKHApICsgJyUnOwogICAgcmlu
;Z0ZnLnN0eWxlLnN0cm9rZURhc2hhcnJheSA9IFN0cmluZyhDSVJDKTsKICAgIHJpbmdGZy5zdHlsZS5zdHJva2VEYXNob2Zmc2V0
;ID0gU3RyaW5nKENJUkMgKiAoMSAtIHAgLyAxMDApKTsKICB9CgogIGxldCBib290Q21kU2VxID0gMDsKICB3aW5kb3cuX19zZXRC
;b290ID0gKG9uLCBwY3QsIHNlcSkgPT4gewogICAgLy8g5b+955Wl5Lmx5bqP6L+f5Yiw55qEIEFISyBFeGVjdXRlU2NyaXB0QXN5
;bmPvvIzpgb/lhY3kuLvnlYzpnaLpl6rlm57ov5vluqbmnaEKICAgIGlmIChzZXEgIT0gbnVsbCAmJiBzZXEgIT09ICcnICYmICFO
;dW1iZXIuaXNOYU4oTnVtYmVyKHNlcSkpKSB7CiAgICAgIHNlcSA9IE51bWJlcihzZXEpOwogICAgICBpZiAoc2VxIDwgYm9vdENt
;ZFNlcSkgcmV0dXJuOwogICAgICBib290Q21kU2VxID0gc2VxOwogICAgfQogICAgaWYgKG9uKSB7CiAgICAgIGJvb3QuY2xhc3NM
;aXN0LmFkZCgnb24nKTsKICAgICAgY2hyb21lLmNsYXNzTGlzdC5hZGQoJ2hpZGRlbicpOwogICAgICBpZiAoYXBwUm9vdCkgYXBw
;Um9vdC5jbGFzc0xpc3QuYWRkKCdib290aW5nJyk7CiAgICAgIHNldEJvb3RQY3QocGN0KTsKICAgIH0gZWxzZSB7CiAgICAgIGJv
;b3QuY2xhc3NMaXN0LnJlbW92ZSgnb24nKTsKICAgICAgY2hyb21lLmNsYXNzTGlzdC5yZW1vdmUoJ2hpZGRlbicpOwogICAgICBp
;ZiAoYXBwUm9vdCkgYXBwUm9vdC5jbGFzc0xpc3QucmVtb3ZlKCdib290aW5nJyk7CiAgICAgIHRyeSB7CiAgICAgICAgaWYgKHR5
;cGVvZiBhcHBNb2RlID09PSAndW5kZWZpbmVkJyB8fCBhcHBNb2RlID09PSAnZmlsZScpCiAgICAgICAgICBzZXRUaW1lb3V0KCgp
;ID0+IHsgdHJ5IHsgZG9TZWFyY2goKTsgfSBjYXRjaCAoXykge30gfSwgNjApOwogICAgICB9IGNhdGNoIChfKSB7fQogICAgfQog
;IH07CiAgd2luZG93Ll9fc2V0SW5kZXhQcm9ncmVzcyA9IChwY3QpID0+IHNldEJvb3RQY3QocGN0KTsKCiAgd2luZG93Ll9fc2V0
;Q2F0SWNvbnMgPSAocGF5bG9hZCkgPT4gewogICAgdHJ5IHsKICAgICAgY29uc3QgbWFwID0gdHlwZW9mIHBheWxvYWQgPT09ICdz
;dHJpbmcnID8gSlNPTi5wYXJzZShwYXlsb2FkKSA6IHBheWxvYWQ7CiAgICAgIGlmICghbWFwIHx8IHR5cGVvZiBtYXAgIT09ICdv
;YmplY3QnKSByZXR1cm47CiAgICAgIGRvY3VtZW50LnF1ZXJ5U2VsZWN0b3JBbGwoJy5jYXQnKS5mb3JFYWNoKGJ0biA9PiB7CiAg
;ICAgICAgY29uc3Qga2V5ID0gYnRuLmdldEF0dHJpYnV0ZSgnZGF0YS1jYXQnKTsKICAgICAgICBjb25zdCB1cmwgPSBtYXBba2V5
;XTsKICAgICAgICBpZiAoIXVybCkgcmV0dXJuOwogICAgICAgIGxldCBpbWcgPSBidG4ucXVlcnlTZWxlY3RvcignaW1nLmljbycp
;OwogICAgICAgIGlmICghaW1nKSB7CiAgICAgICAgICBjb25zdCBvbGQgPSBidG4ucXVlcnlTZWxlY3RvcignLmljbywgW2RhdGEt
;Y2F0LWljb10nKTsKICAgICAgICAgIGltZyA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2ltZycpOwogICAgICAgICAgaW1nLmNs
;YXNzTmFtZSA9ICdpY28nOwogICAgICAgICAgaW1nLmFsdCA9ICcnOwogICAgICAgICAgaWYgKG9sZCkgb2xkLnJlcGxhY2VXaXRo
;KGltZyk7CiAgICAgICAgICBlbHNlIGJ0bi5pbnNlcnRCZWZvcmUoaW1nLCBidG4uZmlyc3RDaGlsZCk7CiAgICAgICAgfQogICAg
;ICAgIGltZy5zcmMgPSB1cmwgKyAodXJsLmluY2x1ZGVzKCc/JykgPyAnJicgOiAnPycpICsgJ3Q9JyArIERhdGUubm93KCk7CiAg
;ICAgIH0pOwogICAgfSBjYXRjaCAoZSkgeyBjb25zb2xlLndhcm4oJ3NldENhdEljb25zJywgZSk7IH0KICB9OwoKICBmdW5jdGlv
;biBleHRPZihuYW1lKSB7CiAgICBjb25zdCBpID0gU3RyaW5nKG5hbWUgfHwgJycpLmxhc3RJbmRleE9mKCcuJyk7CiAgICByZXR1
;cm4gaSA+IDAgPyBuYW1lLnNsaWNlKGkgKyAxKS50b0xvd2VyQ2FzZSgpIDogJyc7CiAgfQogIGZ1bmN0aW9uIGljb25IdG1sKGl0
;KSB7CiAgICBpZiAoaXQuaWNvbikgewogICAgICByZXR1cm4gJzxpbWcgc3JjPSInICsgZXNjYXBlSHRtbChpdC5pY29uKSArICci
;IGFsdD0iIiBsb2FkaW5nPSJsYXp5IiBkZWNvZGluZz0iYXN5bmMiIG9uZXJyb3I9InRoaXMub3V0ZXJIVE1MPVwnPHNwYW4gY2xh
;c3M9ZmktZmFsbGJhY2s+8J+ThDwvc3Bhbj5cJyI+JzsKICAgIH0KICAgIGlmIChpdC5pc0RpcikgcmV0dXJuICc8c3BhbiBjbGFz
;cz0iZmktZmFsbGJhY2siPvCfk4E8L3NwYW4+JzsKICAgIHJldHVybiAnPHNwYW4gY2xhc3M9ImZpLWZhbGxiYWNrIj7wn5OEPC9z
;cGFuPic7CiAgfQogIGZ1bmN0aW9uIGhpZ2hsaWdodEh0bWwodGV4dCkgewogICAgY29uc3QgcmF3ID0gU3RyaW5nKHRleHQgPz8g
;JycpOwogICAgbGV0IGh0bWwgPSBlc2NhcGVIdG1sKHJhdyk7CiAgICBjb25zdCBxID0gKHFFbC52YWx1ZSB8fCAnJykudHJpbSgp
;OwogICAgaWYgKCFxKSByZXR1cm4gaHRtbDsKICAgIGNvbnN0IHRlcm1zID0gcS5zcGxpdCgvXHxcfHxcfC8pLmZsYXRNYXAocyA9
;PiBzLnNwbGl0KC9ccysvKSkubWFwKHQgPT4gdC50cmltKCkpLmZpbHRlcihCb29sZWFuKTsKICAgIC8vIGxvbmdlciB0ZXJtcyBm
;aXJzdCB0byBhdm9pZCBwYXJ0aWFsIG92ZXJsYXAgaXNzdWVzCiAgICB0ZXJtcy5zb3J0KChhLCBiKSA9PiBiLmxlbmd0aCAtIGEu
;bGVuZ3RoKTsKICAgIGZvciAoY29uc3QgdCBvZiB0ZXJtcykgewogICAgICBpZiAoIXQpIGNvbnRpbnVlOwogICAgICBjb25zdCBy
;ZSA9IG5ldyBSZWdFeHAodC5yZXBsYWNlKC9bLiorP14ke30oKXxbXF1cXF0vZywgJ1xcJCYnKSwgJ2dpJyk7CiAgICAgIGh0bWwg
;PSBodG1sLnJlcGxhY2UocmUsIG0gPT4gJzxtYXJrPicgKyBtICsgJzwvbWFyaz4nKTsKICAgIH0KICAgIHJldHVybiBodG1sOwog
;IH0KICBmdW5jdGlvbiBwcmV0dHlOYW1lKG5hbWUpIHsKICAgIG5hbWUgPSBTdHJpbmcobmFtZSB8fCAnJyk7CiAgICBpZiAoIW5h
;bWUpIHJldHVybiAnJzsKICAgIGNvbnN0IGUgPSBleHRPZihuYW1lKTsKICAgIGlmICghZSB8fCBuYW1lLnN0YXJ0c1dpdGgoJy4n
;KSkgcmV0dXJuIGhpZ2hsaWdodEh0bWwobmFtZSk7CiAgICBjb25zdCBiYXNlID0gbmFtZS5zbGljZSgwLCAtKGUubGVuZ3RoICsg
;MSkpOwogICAgcmV0dXJuIGhpZ2hsaWdodEh0bWwoYmFzZSkgKyAnPHNwYW4gY2xhc3M9ImV4dCI+LicgKyBlc2NhcGVIdG1sKGUp
;ICsgJzwvc3Bhbj4nOwogIH0KICBmdW5jdGlvbiBkaXNwbGF5TmFtZShpdCkgewogICAgbGV0IG4gPSBTdHJpbmcoaXQubmFtZSB8
;fCAnJykudHJpbSgpOwogICAgaWYgKG4pIHJldHVybiBuOwogICAgLy8gZmFsbGJhY2s6IGxhc3Qgc2VnbWVudCBvZiBwYXRoCiAg
;ICBjb25zdCBwID0gU3RyaW5nKGl0LnBhdGggfHwgJycpLnJlcGxhY2UoL1tcXC9dKyQvLCAnJyk7CiAgICBjb25zdCBpID0gTWF0
;aC5tYXgocC5sYXN0SW5kZXhPZignXFwnKSwgcC5sYXN0SW5kZXhPZignLycpKTsKICAgIHJldHVybiBpID49IDAgPyBwLnNsaWNl
;KGkgKyAxKSA6IHA7CiAgfQogIGZ1bmN0aW9uIGVzY2FwZUh0bWwocykgewogICAgcmV0dXJuIFN0cmluZyhzID8/ICcnKS5yZXBs
;YWNlKC8mL2csJyZhbXA7JykucmVwbGFjZSgvPC9nLCcmbHQ7JykucmVwbGFjZSgvPi9nLCcmZ3Q7JykucmVwbGFjZSgvIi9nLCcm
;cXVvdDsnKTsKICB9CiAgZnVuY3Rpb24gc2hvcnRQYXRoKHApIHsKICAgIHAgPSBTdHJpbmcocCB8fCAnJyk7CiAgICBpZiAocC5s
;ZW5ndGggPD0gNTYpIHJldHVybiBwOwogICAgcmV0dXJuIHAuc2xpY2UoMCwgMjgpICsgJy4uLicgKyBwLnNsaWNlKC0yNCk7CiAg
;fQoKICBmdW5jdGlvbiB1cGRhdGVDb3VudCgpIHsKICAgIGlmICghaXRlbXMubGVuZ3RoKSB7CiAgICAgIGNvdW50RWwudGV4dENv
;bnRlbnQgPSAn5YWxIDAg5p2h57uT5p6cJzsKICAgICAgcmV0dXJuOwogICAgfQogICAgY29uc3Qgc2hvd24gPSBpdGVtcy5sZW5n
;dGg7CiAgICBjb3VudEVsLnRleHRDb250ZW50ID0gdG90YWxIaXRzID4gc2hvd24KICAgICAgPyAoJ+WFsSAnICsgdG90YWxIaXRz
;LnRvTG9jYWxlU3RyaW5nKCkgKyAnIOadoee7k+aenO+8iOW3suWKoOi9vSAnICsgc2hvd24udG9Mb2NhbGVTdHJpbmcoKSArICcg
;5p2h77yJJykKICAgICAgOiAoJ+WFsSAnICsgTWF0aC5tYXgodG90YWxIaXRzLCBzaG93bikudG9Mb2NhbGVTdHJpbmcoKSArICcg
;5p2h57uT5p6cJyk7CiAgfQoKICBmdW5jdGlvbiBtYWtlUm93KGl0LCBpKSB7CiAgICBjb25zdCByb3cgPSBkb2N1bWVudC5jcmVh
;dGVFbGVtZW50KCdkaXYnKTsKICAgIHJvdy5jbGFzc05hbWUgPSAncm93JyArIChpID09PSBzZWxlY3RlZCA/ICcgb24nIDogJycp
;OwogICAgY29uc3QgdGl0bGUgPSBkaXNwbGF5TmFtZShpdCk7CiAgICByb3cuaW5uZXJIVE1MID0gYDxkaXYgY2xhc3M9ImZpIj4k
;e2ljb25IdG1sKGl0KX08L2Rpdj4KICAgICAgPGRpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJuYW1lIj4ke3ByZXR0eU5hbWUodGl0
;bGUpfTwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9InBhdGgiIHRpdGxlPSIke2VzY2FwZUh0bWwoaXQucGF0aCl9Ij4ke2VzY2Fw
;ZUh0bWwoc2hvcnRQYXRoKGl0LnBhdGgpKX08L2Rpdj4KICAgICAgPC9kaXY+YDsKICAgIHJvdy5vbmNsaWNrID0gKCkgPT4geyBo
;aWRlQ3R4KCk7IHNlbGVjdFJvdyhpKTsgfTsKICAgIHJvdy5vbmRibGNsaWNrID0gKCkgPT4gewogICAgICBoaWRlQ3R4KCk7CiAg
;ICAgIHB1c2hIaXN0KHFFbC52YWx1ZSB8fCAnJyk7CiAgICAgIGNhbGxIb3N0KCdvcGVuJywgaXQucGF0aCk7CiAgICB9OwogICAg
;cm93Lm9uY29udGV4dG1lbnUgPSAoZSkgPT4gewogICAgICBlLnByZXZlbnREZWZhdWx0KCk7CiAgICAgIGUuc3RvcFByb3BhZ2F0
;aW9uKCk7CiAgICAgIHNlbGVjdFJvdyhpKTsKICAgICAgc2hvd0N0eChlLmNsaWVudFgsIGUuY2xpZW50WSwgaXQucGF0aCk7CiAg
;ICB9OwogICAgcmV0dXJuIHJvdzsKICB9CgogIGNvbnN0IGN0eEVsID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2N0eCcpOwog
;IGxldCBjdHhQYXRoID0gJyc7CiAgZnVuY3Rpb24gaGlkZUN0eCgpIHsKICAgIGN0eEVsLmNsYXNzTGlzdC5yZW1vdmUoJ29uJyk7
;CiAgICBjdHhQYXRoID0gJyc7CiAgfQogIGZ1bmN0aW9uIHNob3dDdHgoeCwgeSwgcGF0aCkgewogICAgY3R4UGF0aCA9IFN0cmlu
;ZyhwYXRoIHx8ICcnKTsKICAgIGlmICghY3R4UGF0aCkgcmV0dXJuOwogICAgY3R4RWwuY2xhc3NMaXN0LmFkZCgnb24nKTsKICAg
;IGNvbnN0IHBhZCA9IDY7CiAgICBjb25zdCB2dyA9IHdpbmRvdy5pbm5lcldpZHRoOwogICAgY29uc3QgdmggPSB3aW5kb3cuaW5u
;ZXJIZWlnaHQ7CiAgICBjdHhFbC5zdHlsZS5sZWZ0ID0gJzBweCc7CiAgICBjdHhFbC5zdHlsZS50b3AgPSAnMHB4JzsKICAgIGNv
;bnN0IHJlY3QgPSBjdHhFbC5nZXRCb3VuZGluZ0NsaWVudFJlY3QoKTsKICAgIGxldCBsZWZ0ID0geDsKICAgIGxldCB0b3AgPSB5
;OwogICAgaWYgKGxlZnQgKyByZWN0LndpZHRoID4gdncgLSBwYWQpIGxlZnQgPSBNYXRoLm1heChwYWQsIHZ3IC0gcmVjdC53aWR0
;aCAtIHBhZCk7CiAgICBpZiAodG9wICsgcmVjdC5oZWlnaHQgPiB2aCAtIHBhZCkgdG9wID0gTWF0aC5tYXgocGFkLCB2aCAtIHJl
;Y3QuaGVpZ2h0IC0gcGFkKTsKICAgIGN0eEVsLnN0eWxlLmxlZnQgPSBsZWZ0ICsgJ3B4JzsKICAgIGN0eEVsLnN0eWxlLnRvcCA9
;IHRvcCArICdweCc7CiAgfQogIGN0eEVsLnF1ZXJ5U2VsZWN0b3JBbGwoJ2J1dHRvbltkYXRhLWFjdF0nKS5mb3JFYWNoKGJ0biA9
;PiB7CiAgICBidG4uYWRkRXZlbnRMaXN0ZW5lcignY2xpY2snLCAoZSkgPT4gewogICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwog
;ICAgICBjb25zdCBhY3QgPSBidG4uZ2V0QXR0cmlidXRlKCdkYXRhLWFjdCcpOwogICAgICBjb25zdCBwYXRoID0gY3R4UGF0aDsK
;ICAgICAgaGlkZUN0eCgpOwogICAgICBpZiAoIXBhdGggfHwgIWFjdCkgcmV0dXJuOwogICAgICBpZiAoYWN0ID09PSAncmV2ZWFs
;JykgY2FsbEhvc3QoJ3JldmVhbCcsIHBhdGgpOwogICAgICBlbHNlIGlmIChhY3QgPT09ICdjb3B5JykgY2FsbEhvc3QoJ2NvcHlG
;aWxlJywgcGF0aCk7CiAgICAgIGVsc2UgaWYgKGFjdCA9PT0gJ2NvcHlQYXRoJykgY2FsbEhvc3QoJ2NvcHlQYXRoJywgcGF0aCk7
;CiAgICAgIGVsc2UgaWYgKGFjdCA9PT0gJ2NvcHlEaXInKSBjYWxsSG9zdCgnY29weURpcicsIHBhdGgpOwogICAgICBlbHNlIGlm
;IChhY3QgPT09ICdyZWN5Y2xlJykgY2FsbEhvc3QoJ3JlY3ljbGUnLCBwYXRoKTsKICAgIH0pOwogIH0pOwogIGRvY3VtZW50LmFk
;ZEV2ZW50TGlzdGVuZXIoJ2NvbnRleHRtZW51JywgKGUpID0+IHsKICAgIGlmICghZS50YXJnZXQuY2xvc2VzdCgnI2xpc3QgLnJv
;dycpICYmICFlLnRhcmdldC5jbG9zZXN0KCcjY3R4JykpIGhpZGVDdHgoKTsKICB9KTsKICB3aW5kb3cuYWRkRXZlbnRMaXN0ZW5l
;cignYmx1cicsIGhpZGVDdHgpOwogIHdpbmRvdy5hZGRFdmVudExpc3RlbmVyKCdyZXNpemUnLCBoaWRlQ3R4KTsKICB3aW5kb3cu
;X19yZW1vdmVQYXRoID0gKHBhdGgpID0+IHsKICAgIHBhdGggPSBTdHJpbmcocGF0aCB8fCAnJyk7CiAgICBpZiAoIXBhdGgpIHJl
;dHVybjsKICAgIGNvbnN0IHByZXZTZWwgPSBzZWxlY3RlZCA+PSAwID8gKGl0ZW1zW3NlbGVjdGVkXSAmJiBpdGVtc1tzZWxlY3Rl
;ZF0ucGF0aCkgOiAnJzsKICAgIGl0ZW1zID0gaXRlbXMuZmlsdGVyKGl0ID0+IFN0cmluZyhpdC5wYXRoIHx8ICcnKSAhPT0gcGF0
;aCk7CiAgICBpZiAodG90YWxIaXRzID4gMCkgdG90YWxIaXRzID0gTWF0aC5tYXgoMCwgdG90YWxIaXRzIC0gMSk7CiAgICBzZWxl
;Y3RlZCA9IC0xOwogICAgaWYgKHByZXZTZWwgJiYgcHJldlNlbCAhPT0gcGF0aCkgewogICAgICBzZWxlY3RlZCA9IGl0ZW1zLmZp
;bmRJbmRleChpdCA9PiBpdC5wYXRoID09PSBwcmV2U2VsKTsKICAgIH0gZWxzZSBpZiAoaXRlbXMubGVuZ3RoKSB7CiAgICAgIHNl
;bGVjdGVkID0gTWF0aC5taW4oc2VsZWN0ZWQgPCAwID8gMCA6IHNlbGVjdGVkLCBpdGVtcy5sZW5ndGggLSAxKTsKICAgIH0KICAg
;IHJlbmRlckxpc3QoZmFsc2UpOwogICAgaWYgKHNlbGVjdGVkID49IDAgJiYgcHJldmlld09uKSByZXF1ZXN0UHJldmlldyhpdGVt
;c1tzZWxlY3RlZF0pOwogICAgZWxzZSB7CiAgICAgIHB2TWV0YS50ZXh0Q29udGVudCA9ICfpgInmi6nmlofku7bku6XpooTop4gn
;OwogICAgICBwdk1lZGlhLmlubmVySFRNTCA9ICc8ZGl2IGNsYXNzPSJwaCI+6aKE6KeI5Yy6PC9kaXY+JzsKICAgICAgcHZUZXh0
;LnN0eWxlLmRpc3BsYXkgPSAnbm9uZSc7CiAgICB9CiAgfTsKCiAgZnVuY3Rpb24gcmVuZGVyTGlzdChhcHBlbmQpIHsKICAgIGlm
;ICghYXBwZW5kKSBsaXN0RWwuaW5uZXJIVE1MID0gJyc7CiAgICBpZiAoIWl0ZW1zLmxlbmd0aCkgewogICAgICBlbXB0eUVsLmNs
;YXNzTGlzdC5hZGQoJ29uJyk7CiAgICAgIHVwZGF0ZUNvdW50KCk7CiAgICAgIHJldHVybjsKICAgIH0KICAgIGVtcHR5RWwuY2xh
;c3NMaXN0LnJlbW92ZSgnb24nKTsKICAgIGNvbnN0IHN0YXJ0ID0gYXBwZW5kID8gbGlzdEVsLnF1ZXJ5U2VsZWN0b3JBbGwoJy5y
;b3cnKS5sZW5ndGggOiAwOwogICAgY29uc3QgZnJhZyA9IGRvY3VtZW50LmNyZWF0ZURvY3VtZW50RnJhZ21lbnQoKTsKICAgIGZv
;ciAobGV0IGkgPSBzdGFydDsgaSA8IGl0ZW1zLmxlbmd0aDsgaSsrKQogICAgICBmcmFnLmFwcGVuZENoaWxkKG1ha2VSb3coaXRl
;bXNbaV0sIGkpKTsKICAgIGxpc3RFbC5hcHBlbmRDaGlsZChmcmFnKTsKICAgIHVwZGF0ZUNvdW50KCk7CiAgfQoKICBmdW5jdGlv
;biBzZWxlY3RSb3coaSwgb3B0cykgewogICAgc2VsZWN0ZWQgPSBpOwogICAgY29uc3Qgcm93cyA9IGxpc3RFbC5jaGlsZHJlbjsK
;ICAgIGZvciAobGV0IGlkeCA9IDA7IGlkeCA8IHJvd3MubGVuZ3RoOyBpZHgrKykKICAgICAgcm93c1tpZHhdLmNsYXNzTGlzdC50
;b2dnbGUoJ29uJywgaWR4ID09PSBpKTsKICAgIGNvbnN0IGl0ID0gaXRlbXNbaV07CiAgICBpZiAoIWl0KSByZXR1cm47CiAgICBp
;ZiAocHJldmlld09uKSBzY2hlZHVsZVByZXZpZXcoaXQsIG9wdHMgJiYgb3B0cy5pbW1lZGlhdGUpOwogIH0KICBsZXQgcHJldmll
;d1RpbWVyID0gMDsKICBsZXQgcHJldmlld1Rva2VuID0gMDsKICBmdW5jdGlvbiBzY2hlZHVsZVByZXZpZXcoaXQsIGltbWVkaWF0
;ZSkgewogICAgY2xlYXJUaW1lb3V0KHByZXZpZXdUaW1lcik7CiAgICBjb25zdCB0b2sgPSArK3ByZXZpZXdUb2tlbjsKICAgIGNv
;bnN0IHBhdGggPSBpdCAmJiBpdC5wYXRoOwogICAgY29uc3QgcnVuID0gKCkgPT4gewogICAgICBpZiAodG9rICE9PSBwcmV2aWV3
;VG9rZW4gfHwgIXByZXZpZXdPbikgcmV0dXJuOwogICAgICBpZiAoc2VsZWN0ZWQgPCAwIHx8ICFpdGVtc1tzZWxlY3RlZF0gfHwg
;aXRlbXNbc2VsZWN0ZWRdLnBhdGggIT09IHBhdGgpIHJldHVybjsKICAgICAgcmVxdWVzdFByZXZpZXcoaXRlbXNbc2VsZWN0ZWRd
;KTsKICAgIH07CiAgICBpZiAoaW1tZWRpYXRlKSBydW4oKTsKICAgIGVsc2UgcHJldmlld1RpbWVyID0gc2V0VGltZW91dChydW4s
;IDM2MCk7CiAgfQoKICBmdW5jdGlvbiByZXF1ZXN0UHJldmlldyhpdCkgewogICAgcHZNZXRhLmlubmVySFRNTCA9IGA8c3Bhbj7l
;kI3np7AgPGI+JHtlc2NhcGVIdG1sKGl0Lm5hbWUpfTwvYj48L3NwYW4+YDsKICAgIGlmIChwdkJvZHkpIHB2Qm9keS5jbGFzc0xp
;c3QucmVtb3ZlKCd0ZXh0LW1vZGUnKTsKICAgIHB2TWVkaWEuaW5uZXJIVE1MID0gJzxkaXYgY2xhc3M9InBoIj7liqDovb3pooTo
;p4jigKY8L2Rpdj4nOwogICAgcHZUZXh0LnN0eWxlLmRpc3BsYXkgPSAnbm9uZSc7CiAgICBjYWxsSG9zdCgncHJldmlldycsIGl0
;LnBhdGgpOwogIH0KCiAgZnVuY3Rpb24gdHJ5TG9hZE1vcmUoKSB7CiAgICBpZiAoIWhhc01vcmUgfHwgbG9hZGluZ01vcmUpIHJl
;dHVybjsKICAgIGxvYWRpbmdNb3JlID0gdHJ1ZTsKICAgIGNhbGxIb3N0KCdzZWFyY2gnLCBjb21wb3NlU2VhcmNoUXVlcnkoKSwg
;Y2F0LCBzb3J0LCBpdGVtcy5sZW5ndGgpOwogIH0KCiAgZnVuY3Rpb24gbWF5YmVGaWxsVmlld3BvcnQoKSB7CiAgICAvLyDpppbl
;sY/lj6rmnIkgMTUg5p2h5pe25Y+v6IO95LiN5aSf5rua5Yqo77yM6Ieq5Yqo6KGl6aG155u05Yiw5Y+v5rua5oiW5rKh5pyJ5pu0
;5aSaCiAgICBpZiAoIWhhc01vcmUgfHwgbG9hZGluZ01vcmUpIHJldHVybjsKICAgIGlmIChsaXN0RWwuc2Nyb2xsSGVpZ2h0IDw9
;IGxpc3RFbC5jbGllbnRIZWlnaHQgKyA4KQogICAgICB0cnlMb2FkTW9yZSgpOwogIH0KCiAgbGlzdEVsLmFkZEV2ZW50TGlzdGVu
;ZXIoJ3Njcm9sbCcsICgpID0+IHsKICAgIGlmIChsaXN0RWwuc2Nyb2xsVG9wICsgbGlzdEVsLmNsaWVudEhlaWdodCA+PSBsaXN0
;RWwuc2Nyb2xsSGVpZ2h0IC0gMTIwKQogICAgICB0cnlMb2FkTW9yZSgpOwogIH0pOwoKICB3aW5kb3cuX191cGRhdGVSZXN1bHRz
;ID0gKHBheWxvYWQpID0+IHsKICAgIHRyeSB7CiAgICAgIGNvbnN0IGRhdGEgPSB0eXBlb2YgcGF5bG9hZCA9PT0gJ3N0cmluZycg
;PyBKU09OLnBhcnNlKHBheWxvYWQpIDogcGF5bG9hZDsKICAgICAgY29uc3QgYmF0Y2ggPSBBcnJheS5pc0FycmF5KGRhdGEuaXRl
;bXMpID8gZGF0YS5pdGVtcyA6IFtdOwogICAgICBjb25zdCB0b3RhbCA9IE51bWJlcihkYXRhLnRvdGFsICE9IG51bGwgPyBkYXRh
;LnRvdGFsIDogMCkgfHwgMDsKICAgICAgY29uc3Qgb2Zmc2V0ID0gTnVtYmVyKGRhdGEub2Zmc2V0KSB8fCAwOwogICAgICBjb25z
;dCBhcHBlbmQgPSAhIWRhdGEuYXBwZW5kICYmIG9mZnNldCA+IDA7CiAgICAgIGNvbnN0IHBhZ2VTaXplID0gTWF0aC5tYXgoMSwg
;TnVtYmVyKGRhdGEucGFnZVNpemUpIHx8IDUwKTsKCiAgICAgIGlmICh0b3RhbCA+PSAwKQogICAgICAgIHRvdGFsSGl0cyA9IHRv
;dGFsOwogICAgICBpZiAoYXBwZW5kKSB7CiAgICAgICAgY29uc3Qgc2VlbiA9IG5ldyBTZXQoaXRlbXMubWFwKHggPT4geC5wYXRo
;KSk7CiAgICAgICAgZm9yIChjb25zdCBpdCBvZiBiYXRjaCkgewogICAgICAgICAgaWYgKCFzZWVuLmhhcyhpdC5wYXRoKSkgaXRl
;bXMucHVzaChpdCk7CiAgICAgICAgfQogICAgICAgIGxvYWRpbmdNb3JlID0gZmFsc2U7CiAgICAgICAgLy8g5ruh6aG15bCx57un
;57ut5Yqg6L2977yb5ZCM5pe25Lul5pyN5Yqh56uv5oC75pWw5Li65YeGCiAgICAgICAgaGFzTW9yZSA9IGJhdGNoLmxlbmd0aCA+
;PSBwYWdlU2l6ZSB8fCAodG90YWxIaXRzID4gMCAmJiBpdGVtcy5sZW5ndGggPCB0b3RhbEhpdHMpOwogICAgICAgIHJlbmRlckxp
;c3QodHJ1ZSk7CiAgICAgIH0gZWxzZSB7CiAgICAgICAgaXRlbXMgPSBiYXRjaDsKICAgICAgICBsb2FkaW5nTW9yZSA9IGZhbHNl
;OwogICAgICAgIGhhc01vcmUgPSBiYXRjaC5sZW5ndGggPj0gcGFnZVNpemUgfHwgKHRvdGFsSGl0cyA+IDAgJiYgaXRlbXMubGVu
;Z3RoIDwgdG90YWxIaXRzKTsKICAgICAgICBzZWxlY3RlZCA9IGl0ZW1zLmxlbmd0aCA/IDAgOiAtMTsKICAgICAgICByZW5kZXJM
;aXN0KGZhbHNlKTsKICAgICAgICBpZiAoc2VsZWN0ZWQgPj0gMCAmJiBwcmV2aWV3T24pIHNjaGVkdWxlUHJldmlldyhpdGVtc1tz
;ZWxlY3RlZF0pOwogICAgICAgIGVsc2UgaWYgKCFpdGVtcy5sZW5ndGgpIHsKICAgICAgICAgIGNsZWFyVGltZW91dChwcmV2aWV3
;VGltZXIpOwogICAgICAgICAgcHJldmlld1Rva2VuICs9IDE7CiAgICAgICAgICBpZiAocHZCb2R5KSBwdkJvZHkuY2xhc3NMaXN0
;LnJlbW92ZSgndGV4dC1tb2RlJyk7CiAgICAgICAgICBwdk1ldGEudGV4dENvbnRlbnQgPSAn6YCJ5oup5paH5Lu25Lul6aKE6KeI
;JzsKICAgICAgICAgIHB2TWVkaWEuaW5uZXJIVE1MID0gJzxkaXYgY2xhc3M9InBoIj7pooTop4jljLo8L2Rpdj4nOwogICAgICAg
;ICAgcHZUZXh0LnN0eWxlLmRpc3BsYXkgPSAnbm9uZSc7CiAgICAgICAgfQogICAgICB9CiAgICAgIHVwZGF0ZUNvdW50KCk7CiAg
;ICAgIHJlcXVlc3RBbmltYXRpb25GcmFtZShtYXliZUZpbGxWaWV3cG9ydCk7CiAgICB9IGNhdGNoIChlKSB7CiAgICAgIGNvbnNv
;bGUuZXJyb3IoZSk7CiAgICAgIGxvYWRpbmdNb3JlID0gZmFsc2U7CiAgICAgIGNvdW50RWwudGV4dENvbnRlbnQgPSAn57uT5p6c
;5pu05paw5aSx6LSlJzsKICAgIH0KICB9OwoKICB3aW5kb3cuX19zZXRQcmV2aWV3ID0gKHBheWxvYWQpID0+IHsKICAgIHRyeSB7
;CiAgICAgIGNvbnN0IGRhdGEgPSB0eXBlb2YgcGF5bG9hZCA9PT0gJ3N0cmluZycgPyBKU09OLnBhcnNlKHBheWxvYWQpIDogcGF5
;bG9hZDsKICAgICAgY29uc3Qga2luZCA9IGRhdGEua2luZCB8fCAnbm9uZSc7CiAgICAgIGNvbnN0IGJpdHMgPSBbXTsKICAgICAg
;Y29uc3QgZHJ2TWF0Y2ggPSBTdHJpbmcoZGF0YS5wYXRoIHx8ICcnKS5tYXRjaCgvXihbQS1aYS16XSk6Lyk7CiAgICAgIGlmIChk
;cnZNYXRjaCkgewogICAgICAgIGNvbnN0IGxldHRlciA9IGRydk1hdGNoWzFdLnRvVXBwZXJDYXNlKCk7CiAgICAgICAgY29uc3Qg
;aGl0ID0gKGRyaXZlTWV0YS5kcml2ZXMgfHwgW10pLmZpbmQoZCA9PiBTdHJpbmcoZC5sZXR0ZXIgfHwgJycpLnRvVXBwZXJDYXNl
;KCkgPT09IGxldHRlcik7CiAgICAgICAgY29uc3QgaWNvID0gKGhpdCAmJiBoaXQuaWNvbikgPyAoJzxpbWcgc3JjPSInICsgZXNj
;YXBlSHRtbChoaXQuaWNvbikgKyAnIiBhbHQ9IiI+JykgOiAnJzsKICAgICAgICBjb25zdCBsYWJlbCA9IChoaXQgJiYgaGl0Lmxh
;YmVsKSA/IGhpdC5sYWJlbCA6IChsZXR0ZXIgKyAnOicpOwogICAgICAgIGJpdHMucHVzaCgnPHNwYW4gY2xhc3M9ImRydiI+JyAr
;IGljbyArIGVzY2FwZUh0bWwobGFiZWwpICsgJzwvc3Bhbj4nKTsKICAgICAgfQogICAgICBpZiAoZGF0YS5lbmNvZGluZykgYml0
;cy5wdXNoKCfnvJbnoIEgPGI+JyArIGVzY2FwZUh0bWwoZGF0YS5lbmNvZGluZykgKyAnPC9iPicpOwogICAgICBpZiAoZGF0YS5z
;aXplVGV4dCkgYml0cy5wdXNoKCflpKflsI8gPGI+JyArIGVzY2FwZUh0bWwoZGF0YS5zaXplVGV4dCkgKyAnPC9iPicpOwogICAg
;ICBpZiAoZGF0YS5kaW1zKSBiaXRzLnB1c2goJ+WwuuWvuCA8Yj4nICsgZXNjYXBlSHRtbChkYXRhLmRpbXMpICsgJzwvYj4nKTsK
;ICAgICAgaWYgKGRhdGEubXRpbWUpIGJpdHMucHVzaCgn5L+u5pS5IDxiPicgKyBlc2NhcGVIdG1sKGRhdGEubXRpbWUpICsgJzwv
;Yj4nKTsKICAgICAgcHZNZXRhLmlubmVySFRNTCA9IGJpdHMuam9pbignPHNwYW4gc3R5bGU9Im9wYWNpdHk6LjM1Ij7Ctzwvc3Bh
;bj4nKSB8fCAn6aKE6KeIJzsKICAgICAgcHZUZXh0LnN0eWxlLmRpc3BsYXkgPSAnbm9uZSc7CiAgICAgIGlmIChwdkJvZHkpIHB2
;Qm9keS5jbGFzc0xpc3QucmVtb3ZlKCd0ZXh0LW1vZGUnKTsKCiAgICAgIGlmIChraW5kID09PSAnaW1hZ2UnICYmIGRhdGEudXJs
;KSB7CiAgICAgICAgcHZNZWRpYS5pbm5lckhUTUwgPSAnJzsKICAgICAgICBjb25zdCBpbWcgPSBkb2N1bWVudC5jcmVhdGVFbGVt
;ZW50KCdpbWcnKTsKICAgICAgICBpbWcuc3JjID0gZGF0YS51cmw7CiAgICAgICAgaW1nLmFsdCA9ICcnOwogICAgICAgIHB2TWVk
;aWEuYXBwZW5kQ2hpbGQoaW1nKTsKICAgICAgfSBlbHNlIGlmIChraW5kID09PSAndmlkZW8nKSB7CiAgICAgICAgcHZNZWRpYS5p
;bm5lckhUTUwgPSAnJzsKICAgICAgICBwdk1lZGlhLnN0eWxlLmZsZXhEaXJlY3Rpb24gPSAnY29sdW1uJzsKICAgICAgICBpZiAo
;ZGF0YS51cmwpIHsKICAgICAgICAgIGNvbnN0IHYgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCd2aWRlbycpOwogICAgICAgICAg
;di5jb250cm9scyA9IHRydWU7CiAgICAgICAgICB2LnByZWxvYWQgPSAnbWV0YWRhdGEnOwogICAgICAgICAgdi5zcmMgPSBkYXRh
;LnVybDsKICAgICAgICAgIHYuc3R5bGUubWF4V2lkdGggPSAnMTAwJSc7CiAgICAgICAgICB2LnN0eWxlLm1heEhlaWdodCA9IGRh
;dGEudGh1bWIgPyAnNzAlJyA6ICcxMDAlJzsKICAgICAgICAgIHYub25lcnJvciA9ICgpID0+IHsKICAgICAgICAgICAgaWYgKGRh
;dGEudGh1bWIpIHsKICAgICAgICAgICAgICB2LnJlcGxhY2VXaXRoKE9iamVjdC5hc3NpZ24oZG9jdW1lbnQuY3JlYXRlRWxlbWVu
;dCgnaW1nJyksIHsKICAgICAgICAgICAgICAgIHNyYzogZGF0YS50aHVtYiwgc3R5bGU6ICdtYXgtd2lkdGg6MTAwJTttYXgtaGVp
;Z2h0OjgwJTtvYmplY3QtZml0OmNvbnRhaW4nCiAgICAgICAgICAgICAgfSkpOwogICAgICAgICAgICB9CiAgICAgICAgICB9Owog
;ICAgICAgICAgcHZNZWRpYS5hcHBlbmRDaGlsZCh2KTsKICAgICAgICB9IGVsc2UgaWYgKGRhdGEudGh1bWIpIHsKICAgICAgICAg
;IGNvbnN0IGltZyA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2ltZycpOwogICAgICAgICAgaW1nLnNyYyA9IGRhdGEudGh1bWI7
;CiAgICAgICAgICBpbWcuc3R5bGUubWF4V2lkdGggPSAnMTAwJSc7CiAgICAgICAgICBpbWcuc3R5bGUubWF4SGVpZ2h0ID0gJzgw
;JSc7CiAgICAgICAgICBpbWcuc3R5bGUub2JqZWN0Rml0ID0gJ2NvbnRhaW4nOwogICAgICAgICAgcHZNZWRpYS5hcHBlbmRDaGls
;ZChpbWcpOwogICAgICAgIH0gZWxzZSB7CiAgICAgICAgICBwdk1lZGlhLmlubmVySFRNTCA9ICc8ZGl2IGNsYXNzPSJwaCI+5peg
;5rOV6aKE6KeI5q2k6KeG6aKR77yM6K+35Y+M5Ye75omT5byAPC9kaXY+JzsKICAgICAgICB9CiAgICAgIH0gZWxzZSBpZiAoa2lu
;ZCA9PT0gJ2F1ZGlvJykgewogICAgICAgIHB2TWVkaWEuaW5uZXJIVE1MID0gJyc7CiAgICAgICAgY29uc3Qgd3JhcCA9IGRvY3Vt
;ZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOwogICAgICAgIHdyYXAuY2xhc3NOYW1lID0gJ3B2LWZpbGVpbmZvJzsKICAgICAgICB3
;cmFwLnN0eWxlLmJhY2tncm91bmQgPSAnIzNmNDQ1MCc7CiAgICAgICAgd3JhcC5zdHlsZS5jb2xvciA9ICcjZTVlN2ViJzsKICAg
;ICAgICBpZiAoZGF0YS5pY29uKSB3cmFwLmlubmVySFRNTCA9ICc8aW1nIGNsYXNzPSJiaWctaWNvIiBzcmM9IicgKyBlc2NhcGVI
;dG1sKGRhdGEuaWNvbikgKyAnIiBhbHQ9IiI+JzsKICAgICAgICB3cmFwLmlubmVySFRNTCArPSAnPGRpdiBjbGFzcz0iZm4iIHN0
;eWxlPSJjb2xvcjojZmZmIj4nICsgZXNjYXBlSHRtbChkYXRhLm5hbWUgfHwgJycpICsgJzwvZGl2Pic7CiAgICAgICAgcHZNZWRp
;YS5hcHBlbmRDaGlsZCh3cmFwKTsKICAgICAgICBpZiAoZGF0YS51cmwpIHsKICAgICAgICAgIGNvbnN0IGEgPSBkb2N1bWVudC5j
;cmVhdGVFbGVtZW50KCdhdWRpbycpOwogICAgICAgICAgYS5jb250cm9scyA9IHRydWU7CiAgICAgICAgICBhLnNyYyA9IGRhdGEu
;dXJsOwogICAgICAgICAgYS5zdHlsZS53aWR0aCA9ICc4NiUnOwogICAgICAgICAgYS5zdHlsZS5tYXJnaW5Ub3AgPSAnMTJweCc7
;CiAgICAgICAgICB3cmFwLmFwcGVuZENoaWxkKGEpOwogICAgICAgIH0KICAgICAgfSBlbHNlIGlmIChraW5kID09PSAncGRmJyAm
;JiBkYXRhLnVybCkgewogICAgICAgIHB2TWVkaWEuaW5uZXJIVE1MID0gJyc7CiAgICAgICAgY29uc3QgZW1iID0gZG9jdW1lbnQu
;Y3JlYXRlRWxlbWVudCgnZW1iZWQnKTsKICAgICAgICBlbWIuY2xhc3NOYW1lID0gJ3BkZic7CiAgICAgICAgZW1iLnR5cGUgPSAn
;YXBwbGljYXRpb24vcGRmJzsKICAgICAgICBlbWIuc3JjID0gZGF0YS51cmw7CiAgICAgICAgcHZNZWRpYS5hcHBlbmRDaGlsZChl
;bWIpOwogICAgICB9IGVsc2UgaWYgKGtpbmQgPT09ICd0ZXh0JykgewogICAgICAgIGlmIChwdkJvZHkpIHB2Qm9keS5jbGFzc0xp
;c3QuYWRkKCd0ZXh0LW1vZGUnKTsKICAgICAgICBwdk1lZGlhLmlubmVySFRNTCA9ICcnOwogICAgICAgIHB2VGV4dC5zdHlsZS5k
;aXNwbGF5ID0gJ2ZsZXgnOwogICAgICAgIHB2VGV4dEhkLnRleHRDb250ZW50ID0gZGF0YS50ZXh0VGl0bGUgfHwgJ+mihOiniOWJ
;jSAyMEtCIOWGheWuuSc7CiAgICAgICAgcHZQcmUudGV4dENvbnRlbnQgPSBkYXRhLnRleHQgfHwgJyc7CiAgICAgIH0gZWxzZSBp
;ZiAoa2luZCA9PT0gJ2ZvbGRlcicgfHwga2luZCA9PT0gJ2ZpbGVpbmZvJykgewogICAgICAgIC8vIEFsd2F5cyBwcmVmZXIgY2xl
;YW4gc2hlbGwgaWNvbiDigJQgbmV2ZXIgdXNlIGJsYWNrLW1hdHRlIHRodW1ibmFpbHMgaGVyZQogICAgICAgIGNvbnN0IGljb1Ny
;YyA9IGRhdGEuaWNvbiB8fCAnJzsKICAgICAgICBjb25zdCBpY28gPSBpY29TcmMKICAgICAgICAgID8gJzxpbWcgY2xhc3M9ImJp
;Zy1pY28iIHNyYz0iJyArIGVzY2FwZUh0bWwoaWNvU3JjKSArICciIGFsdD0iIj4nCiAgICAgICAgICA6ICc8ZGl2IGNsYXNzPSJi
;aWctaWNvIiBzdHlsZT0iZm9udC1zaXplOjM2cHg7bGluZS1oZWlnaHQ6NDhweCI+JyArIChraW5kID09PSAnZm9sZGVyJyA/ICfw
;n5OBJyA6ICfwn5OEJykgKyAnPC9kaXY+JzsKICAgICAgICBjb25zdCByb3dzID0gW107CiAgICAgICAgaWYgKGRhdGEuc2l6ZVRl
;eHQpIHJvd3MucHVzaChbJ+Wkp+WwjycsIGRhdGEuc2l6ZVRleHRdKTsKICAgICAgICBpZiAoZGF0YS5tdGltZSkgcm93cy5wdXNo
;KFsn5L+u5pS55pe26Ze0JywgZGF0YS5tdGltZV0pOwogICAgICAgIGlmIChkYXRhLmRpciB8fCBkYXRhLnBhdGgpIHJvd3MucHVz
;aChbJ+aJgOWcqOi3r+W+hCcsIGRhdGEuZGlyIHx8IGRhdGEucGF0aF0pOwogICAgICAgIGNvbnN0IGt2ID0gcm93cy5sZW5ndGgK
;ICAgICAgICAgID8gJzxkaXYgY2xhc3M9Imt2Ij4nICsgcm93cy5tYXAoKFtrLCB2XSkgPT4KICAgICAgICAgICAgICAnPGRpdiBj
;bGFzcz0ia3Ytcm93Ij48c3BhbiBjbGFzcz0iayI+JyArIGVzY2FwZUh0bWwoaykgKyAnPC9zcGFuPicKICAgICAgICAgICAgICAr
;ICc8c3BhbiBjbGFzcz0idiI+JyArIGVzY2FwZUh0bWwodikgKyAnPC9zcGFuPjwvZGl2PicKICAgICAgICAgICAgKS5qb2luKCcn
;KSArICc8L2Rpdj4nCiAgICAgICAgICA6ICcnOwogICAgICAgIGxldCBraWRzID0gJyc7CiAgICAgICAgaWYgKEFycmF5LmlzQXJy
;YXkoZGF0YS5jaGlsZHJlbikgJiYgZGF0YS5jaGlsZHJlbi5sZW5ndGgpIHsKICAgICAgICAgIGtpZHMgPSAnPGRpdiBjbGFzcz0i
;a2lkcyI+PGI+5YaF5a656aKE6KeIPC9iPjxicj4nCiAgICAgICAgICAgICsgZGF0YS5jaGlsZHJlbi5tYXAoYyA9PiBlc2NhcGVI
;dG1sKGMpKS5qb2luKCc8YnI+JykgKyAnPC9kaXY+JzsKICAgICAgICB9CiAgICAgICAgY29uc3QgaGludCA9IGRhdGEuaGludAog
;ICAgICAgICAgPyAnPGRpdiBjbGFzcz0iaGludCI+JyArIGVzY2FwZUh0bWwoZGF0YS5oaW50KSArICc8L2Rpdj4nCiAgICAgICAg
;ICA6ICcnOwogICAgICAgIHB2TWVkaWEuc3R5bGUuYmFja2dyb3VuZCA9ICcjZjdmOGZiJzsKICAgICAgICBwdk1lZGlhLmlubmVy
;SFRNTCA9ICc8ZGl2IGNsYXNzPSJwdi1maWxlaW5mbyI+JyArIGljbwogICAgICAgICAgKyAnPGRpdiBjbGFzcz0iZm4iPicgKyBl
;c2NhcGVIdG1sKGRhdGEubmFtZSB8fCAnJykgKyAnPC9kaXY+JwogICAgICAgICAgKyBoaW50ICsga3YgKyBraWRzICsgJzwvZGl2
;Pic7CiAgICAgIH0gZWxzZSB7CiAgICAgICAgcHZNZWRpYS5pbm5lckhUTUwgPSAnPGRpdiBjbGFzcz0icGgiPicgKyBlc2NhcGVI
;dG1sKGRhdGEubWVzc2FnZSB8fCAn5peg5rOV6aKE6KeI5q2k57G75Z6LJykgKyAnPC9kaXY+JzsKICAgICAgfQogICAgfSBjYXRj
;aCAoZSkge30KICB9OwoKICBmdW5jdGlvbiBkb1NlYXJjaCgpIHsKICAgIGlmICh0eXBlb2YgYXBwTW9kZSAhPT0gJ3VuZGVmaW5l
;ZCcgJiYgYXBwTW9kZSA9PT0gJ2hhbmRsZScpIHsKICAgICAgcmVxdWVzdEhhbmRsZVNlYXJjaChxRWwudmFsdWUgfHwgJycpOwog
;ICAgICByZXR1cm47CiAgICB9CiAgICBpZiAodHlwZW9mIGFwcE1vZGUgIT09ICd1bmRlZmluZWQnICYmIGFwcE1vZGUgPT09ICdp
;bmZvJykgewogICAgICByZXF1ZXN0U3lzSW5mbyhmYWxzZSk7CiAgICAgIHJldHVybjsKICAgIH0KICAgIGNvbnN0IHEgPSBjb21w
;b3NlU2VhcmNoUXVlcnkoKTsKICAgIGNvdW50RWwudGV4dENvbnRlbnQgPSAn5pCc57Si5Lit4oCmJzsKICAgIGxvYWRpbmdNb3Jl
;ID0gZmFsc2U7CiAgICBoYXNNb3JlID0gZmFsc2U7CiAgICBjYWxsSG9zdCgnc2VhcmNoJywgcSwgY2F0LCBzb3J0LCAwKTsKICB9
;CiAgZnVuY3Rpb24gc2NoZWR1bGVTZWFyY2goKSB7CiAgICBpZiAodHlwZW9mIGFwcE1vZGUgIT09ICd1bmRlZmluZWQnICYmIGFw
;cE1vZGUgIT09ICdmaWxlJykgcmV0dXJuOwogICAgY2xlYXJUaW1lb3V0KHNlYXJjaFRpbWVyKTsKICAgIHNlYXJjaFRpbWVyID0g
;c2V0VGltZW91dChkb1NlYXJjaCwgMTIwKTsKICB9CgogIGRvY3VtZW50LnF1ZXJ5U2VsZWN0b3JBbGwoJy5jYXQnKS5mb3JFYWNo
;KGJ0biA9PiB7CiAgICBidG4uYWRkRXZlbnRMaXN0ZW5lcignY2xpY2snLCAoKSA9PiB7CiAgICAgIGRvY3VtZW50LnF1ZXJ5U2Vs
;ZWN0b3JBbGwoJy5jYXQnKS5mb3JFYWNoKGIgPT4gYi5jbGFzc0xpc3QucmVtb3ZlKCdvbicpKTsKICAgICAgYnRuLmNsYXNzTGlz
;dC5hZGQoJ29uJyk7CiAgICAgIGNvbnN0IGMgPSBidG4uZGF0YXNldC5jYXQ7CiAgICAgIGlmIChjID09PSAnX19oYW5kbGUnKSB7
;CiAgICAgICAgc2V0QXBwTW9kZSgnaGFuZGxlJyk7CiAgICAgICAgcmV0dXJuOwogICAgICB9CiAgICAgIGlmIChjID09PSAnX19p
;bmZvJykgewogICAgICAgIHNldEFwcE1vZGUoJ2luZm8nKTsKICAgICAgICByZXR1cm47CiAgICAgIH0KICAgICAgY2F0ID0gYzsK
;ICAgICAgc2V0QXBwTW9kZSgnZmlsZScpOwogICAgICBkb1NlYXJjaCgpOwogICAgfSk7CiAgfSk7CiAgcUVsLmFkZEV2ZW50TGlz
;dGVuZXIoJ2lucHV0JywgKCkgPT4gewogICAgaWYgKGFwcE1vZGUgPT09ICdmaWxlJykgbW9kZVF1ZXJ5LmZpbGUgPSBxRWwudmFs
;dWU7CiAgICBlbHNlIGlmIChhcHBNb2RlID09PSAnaGFuZGxlJykgbW9kZVF1ZXJ5LmhhbmRsZSA9IHFFbC52YWx1ZTsKICAgIGVs
;c2UgaWYgKGFwcE1vZGUgPT09ICdpbmZvJykgbW9kZVF1ZXJ5LmluZm8gPSBxRWwudmFsdWU7CiAgICBzeW5jQ2xlYXJCdG4oKTsK
;ICAgIHNjaGVkdWxlU2VhcmNoKCk7CiAgICBjbGVhclRpbWVvdXQoaGlzdElkbGVUaW1lcik7CiAgICBoaXN0SWRsZVRpbWVyID0g
;c2V0VGltZW91dCgoKSA9PiB7CiAgICAgIGlmIChhcHBNb2RlID09PSAnaW5mbycpIHJldHVybjsKICAgICAgcHVzaEhpc3QocUVs
;LnZhbHVlIHx8ICcnKTsKICAgIH0sIDEyMDApOwogIH0pOwogIHFFbC5hZGRFdmVudExpc3RlbmVyKCdrZXlkb3duJywgZSA9PiB7
;CiAgICBpZiAoYXBwTW9kZSA9PT0gJ2luZm8nKSByZXR1cm47CiAgICBpZiAoZS5rZXkgPT09ICdFbnRlcicpIHsKICAgICAgY2xl
;YXJUaW1lb3V0KGhpc3RJZGxlVGltZXIpOwogICAgICBwdXNoSGlzdChxRWwudmFsdWUgfHwgJycpOwogICAgICBkb1NlYXJjaCgp
;OwogICAgfSBlbHNlIGlmIChlLmtleSA9PT0gJ0VzY2FwZScgJiYgKHFFbC52YWx1ZSB8fCAnJykpIHsKICAgICAgZS5zdG9wUHJv
;cGFnYXRpb24oKTsKICAgICAgY2xlYXJTZWFyY2goKTsKICAgIH0KICB9KTsKICBxRWwuYWRkRXZlbnRMaXN0ZW5lcignYmx1cics
;ICgpID0+IHsKICAgIGNsZWFyVGltZW91dChoaXN0SWRsZVRpbWVyKTsKICAgIGlmIChhcHBNb2RlICE9PSAnaW5mbycpIHB1c2hI
;aXN0KHFFbC52YWx1ZSB8fCAnJyk7CiAgfSk7CgogIGZ1bmN0aW9uIGZvY3VzU2VhcmNoKHNlbGVjdEFsbCkgewogICAgdHJ5IHsK
;ICAgICAgcUVsLmZvY3VzKCk7CiAgICAgIGlmIChzZWxlY3RBbGwgIT09IGZhbHNlKQogICAgICAgIHFFbC5zZWxlY3QoKTsKICAg
;IH0gY2F0Y2ggKF8pIHt9CiAgfQogIHdpbmRvdy5fX2ZvY3VzU2VhcmNoID0gZm9jdXNTZWFyY2g7CgogIGZ1bmN0aW9uIGlzVmlk
;ZW9GdWxsc2NyZWVuKCkgewogICAgY29uc3QgZnMgPSBkb2N1bWVudC5mdWxsc2NyZWVuRWxlbWVudCB8fCBkb2N1bWVudC53ZWJr
;aXRGdWxsc2NyZWVuRWxlbWVudCB8fCBkb2N1bWVudC5tc0Z1bGxzY3JlZW5FbGVtZW50OwogICAgaWYgKGZzKSByZXR1cm4gdHJ1
;ZTsKICAgIGNvbnN0IHZpZHMgPSBkb2N1bWVudC5xdWVyeVNlbGVjdG9yQWxsKCd2aWRlbycpOwogICAgZm9yIChjb25zdCB2IG9m
;IHZpZHMpIHsKICAgICAgaWYgKHYud2Via2l0RGlzcGxheWluZ0Z1bGxzY3JlZW4gfHwgdi5tb3pGdWxsU2NyZWVuIHx8IHYubXNG
;dWxsc2NyZWVuRWxlbWVudCkgcmV0dXJuIHRydWU7CiAgICB9CiAgICByZXR1cm4gZmFsc2U7CiAgfQogIGZ1bmN0aW9uIGV4aXRW
;aWRlb0Z1bGxzY3JlZW4oKSB7CiAgICB0cnkgewogICAgICBpZiAoZG9jdW1lbnQuZnVsbHNjcmVlbkVsZW1lbnQgfHwgZG9jdW1l
;bnQud2Via2l0RnVsbHNjcmVlbkVsZW1lbnQpIHsKICAgICAgICBjb25zdCBwID0gZG9jdW1lbnQuZXhpdEZ1bGxzY3JlZW4gPyBk
;b2N1bWVudC5leGl0RnVsbHNjcmVlbigpCiAgICAgICAgICA6IChkb2N1bWVudC53ZWJraXRFeGl0RnVsbHNjcmVlbiAmJiBkb2N1
;bWVudC53ZWJraXRFeGl0RnVsbHNjcmVlbigpKTsKICAgICAgICByZXR1cm4gdHJ1ZTsKICAgICAgfQogICAgfSBjYXRjaCAoXykg
;e30KICAgIGNvbnN0IHZpZHMgPSBkb2N1bWVudC5xdWVyeVNlbGVjdG9yQWxsKCd2aWRlbycpOwogICAgZm9yIChjb25zdCB2IG9m
;IHZpZHMpIHsKICAgICAgdHJ5IHsKICAgICAgICBpZiAodi53ZWJraXREaXNwbGF5aW5nRnVsbHNjcmVlbiAmJiB2LndlYmtpdEV4
;aXRGdWxsc2NyZWVuKSB7CiAgICAgICAgICB2LndlYmtpdEV4aXRGdWxsc2NyZWVuKCk7CiAgICAgICAgICByZXR1cm4gdHJ1ZTsK
;ICAgICAgICB9CiAgICAgICAgaWYgKHYuZXhpdEZ1bGxzY3JlZW4pIHsgdi5leGl0RnVsbHNjcmVlbigpOyByZXR1cm4gdHJ1ZTsg
;fQogICAgICB9IGNhdGNoIChfKSB7fQogICAgfQogICAgcmV0dXJuIGZhbHNlOwogIH0KICB3aW5kb3cuX19oYW5kbGVFc2MgPSAo
;KSA9PiB7CiAgICBpZiAoaXNWaWRlb0Z1bGxzY3JlZW4oKSB8fCBleGl0VmlkZW9GdWxsc2NyZWVuKCkpIHsKICAgICAgdHJ5IHsg
;ZXhpdFZpZGVvRnVsbHNjcmVlbigpOyB9IGNhdGNoIChfKSB7fQogICAgICBwb3N0KCdlc2NDb25zdW1lZCcpOwogICAgICByZXR1
;cm4gdHJ1ZTsKICAgIH0KICAgIHBvc3QoJ2VzY0hpZGUnKTsKICAgIHJldHVybiBmYWxzZTsKICB9OwogIGRvY3VtZW50LmFkZEV2
;ZW50TGlzdGVuZXIoJ2tleWRvd24nLCBlID0+IHsKICAgIGlmICgoZS5jdHJsS2V5IHx8IGUubWV0YUtleSkgJiYgIWUuYWx0S2V5
;ICYmICFlLnNoaWZ0S2V5ICYmIFN0cmluZyhlLmtleSkudG9Mb3dlckNhc2UoKSA9PT0gJ2YnKSB7CiAgICAgIGUucHJldmVudERl
;ZmF1bHQoKTsKICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgZm9jdXNTZWFyY2goKTsKICAgICAgcmV0dXJuOwogICAg
;fQogICAgaWYgKGUua2V5ID09PSAnRXNjYXBlJyB8fCBlLmtleSA9PT0gJ0VzYycpIHsKICAgICAgaWYgKGlzVmlkZW9GdWxsc2Ny
;ZWVuKCkpIHsKICAgICAgICBlLnByZXZlbnREZWZhdWx0KCk7CiAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICBl
;eGl0VmlkZW9GdWxsc2NyZWVuKCk7CiAgICAgICAgcG9zdCgnZXNjQ29uc3VtZWQnKTsKICAgICAgfQogICAgfQogIH0sIHRydWUp
;OwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdidG4tc29ydCcpLm9uY2xpY2sgPSAoKSA9PiB7CiAgICBzb3J0ID0gc29ydCA9
;PT0gJ2RhdGUtZGVzYycgPyAnZGF0ZS1hc2MnIDogKHNvcnQgPT09ICdkYXRlLWFzYycgPyAnbmFtZS1hc2MnIDogKHNvcnQgPT09
;ICduYW1lLWFzYycgPyAnc2l6ZS1kZXNjJyA6ICdkYXRlLWRlc2MnKSk7CiAgICBjb25zdCBtYXAgPSB7CiAgICAgICdkYXRlLWRl
;c2MnOiAn5oyJ5L+u5pS55pe26Ze06ZmN5bqPJywKICAgICAgJ2RhdGUtYXNjJzogJ+aMieS/ruaUueaXtumXtOWNh+W6jycsCiAg
;ICAgICduYW1lLWFzYyc6ICfmjInlkI3np7DljYfluo8nLAogICAgICAnc2l6ZS1kZXNjJzogJ+aMieWkp+Wwj+mZjeW6jycKICAg
;IH07CiAgICBzb3J0TGFiZWwudGV4dENvbnRlbnQgPSBtYXBbc29ydF0gfHwgc29ydDsKICAgIGRvU2VhcmNoKCk7CiAgfTsKICBj
;aGtQcmV2aWV3LmFkZEV2ZW50TGlzdGVuZXIoJ2NoYW5nZScsICgpID0+IHsKICAgIHByZXZpZXdPbiA9ICEhY2hrUHJldmlldy5j
;aGVja2VkOwogICAgcHJldmlldy5jbGFzc0xpc3QudG9nZ2xlKCdvZmYnLCAhcHJldmlld09uKTsKICAgIGlmIChwcmV2aWV3T24g
;JiYgc2VsZWN0ZWQgPj0gMCkgcmVxdWVzdFByZXZpZXcoaXRlbXNbc2VsZWN0ZWRdKTsKICB9KTsKICBkb2N1bWVudC5nZXRFbGVt
;ZW50QnlJZCgnYnRuLXNldHRpbmdzJykub25jbGljayA9ICgpID0+IG9wZW5GaWx0ZXJTZXR0aW5ncygpOwogIGRvY3VtZW50Lmdl
;dEVsZW1lbnRCeUlkKCd0b3AnKS5hZGRFdmVudExpc3RlbmVyKCdtb3VzZWRvd24nLCBlID0+IHsKICAgIGlmIChlLmJ1dHRvbiAh
;PT0gMCkgcmV0dXJuOwogICAgaWYgKGUudGFyZ2V0LmNsb3Nlc3QoJy5uby1kcmFnJykpIHJldHVybjsKICAgIGNhbGxIb3N0KCdk
;cmFnJyk7CiAgICBwb3N0KCdkcmFnJyk7CiAgfSk7CiAgaWYgKHRpdGxlYmFyKSB7CiAgICB0aXRsZWJhci5hZGRFdmVudExpc3Rl
;bmVyKCdtb3VzZWRvd24nLCBlID0+IHsKICAgICAgaWYgKGUuYnV0dG9uICE9PSAwKSByZXR1cm47CiAgICAgIGlmIChlLnRhcmdl
;dC5jbG9zZXN0KCcubm8tZHJhZycpKSByZXR1cm47CiAgICAgIGNhbGxIb3N0KCdkcmFnJyk7CiAgICAgIHBvc3QoJ2RyYWcnKTsK
;ICAgIH0pOwogICAgdGl0bGViYXIuYWRkRXZlbnRMaXN0ZW5lcignZGJsY2xpY2snLCBlID0+IHsKICAgICAgaWYgKGUudGFyZ2V0
;LmNsb3Nlc3QoJy5uby1kcmFnJykpIHJldHVybjsKICAgICAgY2FsbEhvc3QoJ21heGltaXplJyk7CiAgICAgIHBvc3QoJ21heGlt
;aXplJyk7CiAgICB9KTsKICB9CiAgY29uc3QgYnRuV2luTWluID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2J0bi13aW4tbWlu
;Jyk7CiAgY29uc3QgYnRuV2luTWF4ID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2J0bi13aW4tbWF4Jyk7CiAgY29uc3QgYnRu
;V2luQ2xvc2UgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYnRuLXdpbi1jbG9zZScpOwogIGlmIChidG5XaW5NaW4pIGJ0bldp
;bk1pbi5vbmNsaWNrID0gKCkgPT4geyBjYWxsSG9zdCgnbWluaW1pemUnKTsgcG9zdCgnbWluaW1pemUnKTsgfTsKICBpZiAoYnRu
;V2luTWF4KSBidG5XaW5NYXgub25jbGljayA9ICgpID0+IHsgY2FsbEhvc3QoJ21heGltaXplJyk7IHBvc3QoJ21heGltaXplJyk7
;IH07CiAgaWYgKGJ0bldpbkNsb3NlKSBidG5XaW5DbG9zZS5vbmNsaWNrID0gKCkgPT4geyBjYWxsSG9zdCgnY2xvc2UnKTsgcG9z
;dCgnY2xvc2UnKTsgfTsKCiAgLy8g4pSA4pSAIOaQnOe0ouetm+mAie+8iOKAuiDlsZXlvIAgKyDlt6bkuIvop5Lorr7nva7vvIni
;lIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIAKICBjb25zdCBGSUxURVJfU1RPUkVfS0VZID0g
;J2xvY2FsX3NlYXJjaF9maWx0ZXJzX3YyJzsKICBjb25zdCBGSUxURVJfU1RPUkVfTEVHQUNZID0gJ2xvY2FsX3NlYXJjaF9maWx0
;ZXJzX3YxJzsKICBjb25zdCBGSUxURVJfQUNUSVZFX0tFWSA9ICdsb2NhbF9zZWFyY2hfZmlsdGVyc19hY3RpdmVfdjEnOwogIGNv
;bnN0IEJVSUxUSU5fRklMVEVSUyA9IFsKICAgIHsgaWQ6ICd6aCcsIHRpdGxlOiAn5ZCr5Lit5paHJywgcmVnZXg6ICdbXFx4ezRl
;MDB9LVxceHs5ZmZmfV0nLCBidWlsdGluOiB0cnVlLCBlbmFibGVkOiB0cnVlIH0sCiAgICB7IGlkOiAnbm91bmRlcicsIHRpdGxl
;OiAn6Z2e5LiL5YiS57q/5byA5aS0JywgcmVnZXg6ICdeW15fXScsIGJ1aWx0aW46IHRydWUsIGVuYWJsZWQ6IHRydWUgfQogIF07
;CiAgY29uc3QgU1ZHX1ggPSAnPHN2ZyB2aWV3Qm94PSIwIDAgMTIgMTIiIGZpbGw9Im5vbmUiIGFyaWEtaGlkZGVuPSJ0cnVlIj48
;cGF0aCBkPSJNMyAzbDYgNk05IDNMMyA5IiBzdHJva2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIxLjQiIHN0cm9rZS1s
;aW5lY2FwPSJyb3VuZCIvPjwvc3ZnPic7CiAgY29uc3QgU1ZHX1VQID0gJzxzdmcgdmlld0JveD0iMCAwIDEyIDEyIiBmaWxsPSJu
;b25lIiBhcmlhLWhpZGRlbj0idHJ1ZSI+PHBhdGggZD0iTTYgMy4yTDIuOCA3LjJoNi40TDYgMy4yeiIgZmlsbD0iY3VycmVudENv
;bG9yIi8+PC9zdmc+JzsKICBjb25zdCBTVkdfRE4gPSAnPHN2ZyB2aWV3Qm94PSIwIDAgMTIgMTIiIGZpbGw9Im5vbmUiIGFyaWEt
;aGlkZGVuPSJ0cnVlIj48cGF0aCBkPSJNNiA4LjhsMy4yLTRIMi44TDYgOC44eiIgZmlsbD0iY3VycmVudENvbG9yIi8+PC9zdmc+
;JzsKICBjb25zdCBmaWx0ZXJSYWlsID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2ZpbHRlci1yYWlsJyk7CiAgY29uc3QgZmls
;dGVyQmFyID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2ZpbHRlci1iYXInKTsKICBjb25zdCBidG5GaWx0ZXJUb2dnbGUgPSBk
;b2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYnRuLWZpbHRlci10b2dnbGUnKTsKICBjb25zdCBmaWx0ZXJTZXR0aW5ncyA9IGRvY3Vt
;ZW50LmdldEVsZW1lbnRCeUlkKCdmaWx0ZXItc2V0dGluZ3MnKTsKICBsZXQgZmlsdGVySXRlbXMgPSBbXTsKICBsZXQgYWN0aXZl
;RmlsdGVySWRzID0gbmV3IFNldCgpOwogIGxldCBmaWx0ZXJzT3BlbiA9IGZhbHNlOwoKICBmdW5jdGlvbiBjbG9uZUJ1aWx0aW5E
;ZWZhdWx0cygpIHsKICAgIHJldHVybiBCVUlMVElOX0ZJTFRFUlMubWFwKHggPT4gKHsKICAgICAgaWQ6IHguaWQsIHRpdGxlOiB4
;LnRpdGxlLCByZWdleDogeC5yZWdleCwgYnVpbHRpbjogdHJ1ZSwgZW5hYmxlZDogdHJ1ZQogICAgfSkpOwogIH0KICBmdW5jdGlv
;biBub3JtYWxpemVGaWx0ZXJJdGVtKHgsIGZvcmNlQnVpbHRpbikgewogICAgaWYgKCF4IHx8ICF4LmlkIHx8ICF4LnRpdGxlIHx8
;ICF4LnJlZ2V4KSByZXR1cm4gbnVsbDsKICAgIGNvbnN0IGlkID0gU3RyaW5nKHguaWQpOwogICAgY29uc3QgYnVpbHRpbiA9IGZv
;cmNlQnVpbHRpbiAhPSBudWxsID8gISFmb3JjZUJ1aWx0aW4gOiAoISF4LmJ1aWx0aW4gfHwgaWQgPT09ICd6aCcgfHwgaWQgPT09
;ICdub3VuZGVyJyk7CiAgICByZXR1cm4gewogICAgICBpZCwKICAgICAgdGl0bGU6IFN0cmluZyh4LnRpdGxlKS5zbGljZSgwLCAy
;NCksCiAgICAgIHJlZ2V4OiBTdHJpbmcoeC5yZWdleCkuc2xpY2UoMCwgMjAwKSwKICAgICAgYnVpbHRpbiwKICAgICAgZW5hYmxl
;ZDogeC5lbmFibGVkICE9PSBmYWxzZQogICAgfTsKICB9CiAgZnVuY3Rpb24gbG9hZEZpbHRlclN0YXRlKCkgewogICAgZmlsdGVy
;SXRlbXMgPSBbXTsKICAgIHRyeSB7CiAgICAgIGNvbnN0IHJhdyA9IGxvY2FsU3RvcmFnZS5nZXRJdGVtKEZJTFRFUl9TVE9SRV9L
;RVkpOwogICAgICBpZiAocmF3KSB7CiAgICAgICAgY29uc3QgYXJyID0gSlNPTi5wYXJzZShyYXcpOwogICAgICAgIGlmIChBcnJh
;eS5pc0FycmF5KGFycikgJiYgYXJyLmxlbmd0aCkgewogICAgICAgICAgZmlsdGVySXRlbXMgPSBhcnIubWFwKHggPT4gbm9ybWFs
;aXplRmlsdGVySXRlbSh4KSkuZmlsdGVyKEJvb2xlYW4pOwogICAgICAgIH0KICAgICAgfQogICAgfSBjYXRjaCAoXykgeyBmaWx0
;ZXJJdGVtcyA9IFtdOyB9CiAgICBpZiAoIWZpbHRlckl0ZW1zLmxlbmd0aCkgewogICAgICAvLyDlhbzlrrkgdjHvvJrlhoXnva4g
;KyDoh6rlrprkuYkKICAgICAgbGV0IGN1c3RvbXMgPSBbXTsKICAgICAgdHJ5IHsKICAgICAgICBjb25zdCByYXcgPSBsb2NhbFN0
;b3JhZ2UuZ2V0SXRlbShGSUxURVJfU1RPUkVfTEVHQUNZKTsKICAgICAgICBjb25zdCBhcnIgPSByYXcgPyBKU09OLnBhcnNlKHJh
;dykgOiBbXTsKICAgICAgICBjdXN0b21zID0gQXJyYXkuaXNBcnJheShhcnIpID8gYXJyLm1hcCh4ID0+IG5vcm1hbGl6ZUZpbHRl
;ckl0ZW0oeCwgZmFsc2UpKS5maWx0ZXIoQm9vbGVhbikgOiBbXTsKICAgICAgfSBjYXRjaCAoXykgeyBjdXN0b21zID0gW107IH0K
;ICAgICAgZmlsdGVySXRlbXMgPSBjbG9uZUJ1aWx0aW5EZWZhdWx0cygpLmNvbmNhdChjdXN0b21zKTsKICAgICAgc2F2ZUZpbHRl
;ckl0ZW1zKCk7CiAgICB9CiAgICB0cnkgewogICAgICBjb25zdCByYXcgPSBsb2NhbFN0b3JhZ2UuZ2V0SXRlbShGSUxURVJfQUNU
;SVZFX0tFWSk7CiAgICAgIGNvbnN0IGFyciA9IHJhdyA/IEpTT04ucGFyc2UocmF3KSA6IFtdOwogICAgICBhY3RpdmVGaWx0ZXJJ
;ZHMgPSBuZXcgU2V0KEFycmF5LmlzQXJyYXkoYXJyKSA/IGFyci5tYXAoU3RyaW5nKSA6IFtdKTsKICAgIH0gY2F0Y2ggKF8pIHsg
;YWN0aXZlRmlsdGVySWRzID0gbmV3IFNldCgpOyB9CiAgfQogIGZ1bmN0aW9uIHNhdmVGaWx0ZXJJdGVtcygpIHsKICAgIHRyeSB7
;IGxvY2FsU3RvcmFnZS5zZXRJdGVtKEZJTFRFUl9TVE9SRV9LRVksIEpTT04uc3RyaW5naWZ5KGZpbHRlckl0ZW1zKSk7IH0gY2F0
;Y2ggKF8pIHt9CiAgfQogIGZ1bmN0aW9uIHNhdmVBY3RpdmVGaWx0ZXJzKCkgewogICAgdHJ5IHsgbG9jYWxTdG9yYWdlLnNldEl0
;ZW0oRklMVEVSX0FDVElWRV9LRVksIEpTT04uc3RyaW5naWZ5KEFycmF5LmZyb20oYWN0aXZlRmlsdGVySWRzKSkpOyB9IGNhdGNo
;IChfKSB7fQogIH0KICBmdW5jdGlvbiBhbGxGaWx0ZXJzKCkgewogICAgcmV0dXJuIGZpbHRlckl0ZW1zLnNsaWNlKCk7CiAgfQog
;IGZ1bmN0aW9uIHZpc2libGVGaWx0ZXJzKCkgewogICAgcmV0dXJuIGZpbHRlckl0ZW1zLmZpbHRlcihmID0+IGYuZW5hYmxlZCAh
;PT0gZmFsc2UpOwogIH0KICBmdW5jdGlvbiBjb21wb3NlU2VhcmNoUXVlcnkoKSB7CiAgICBjb25zdCBwYXJ0cyA9IFtdOwogICAg
;Y29uc3QgcSA9IFN0cmluZyhxRWwudmFsdWUgfHwgJycpLnRyaW0oKTsKICAgIGlmIChxKSBwYXJ0cy5wdXNoKHEpOwogICAgZm9y
;IChjb25zdCBmIG9mIHZpc2libGVGaWx0ZXJzKCkpIHsKICAgICAgaWYgKCFhY3RpdmVGaWx0ZXJJZHMuaGFzKGYuaWQpKSBjb250
;aW51ZTsKICAgICAgY29uc3QgcmUgPSBTdHJpbmcoZi5yZWdleCB8fCAnJykudHJpbSgpOwogICAgICBpZiAoIXJlKSBjb250aW51
;ZTsKICAgICAgcGFydHMucHVzaCgncmVnZXg6JyArIHJlLnJlcGxhY2UoL1xzKy9nLCAnJykpOwogICAgfQogICAgcmV0dXJuIHBh
;cnRzLmpvaW4oJ3wnKTsKICB9CiAgZnVuY3Rpb24gc3luY0ZpbHRlclRvZ2dsZVVpKCkgewogICAgaWYgKGZpbHRlclJhaWwpIGZp
;bHRlclJhaWwuY2xhc3NMaXN0LnRvZ2dsZSgnb3BlbicsICEhZmlsdGVyc09wZW4pOwogICAgaWYgKGJ0bkZpbHRlclRvZ2dsZSkg
;ewogICAgICBidG5GaWx0ZXJUb2dnbGUuY2xhc3NMaXN0LnRvZ2dsZSgnb3BlbicsICEhZmlsdGVyc09wZW4pOwogICAgICBjb25z
;dCBoYXNBY3RpdmUgPSB2aXNpYmxlRmlsdGVycygpLnNvbWUoZiA9PiBhY3RpdmVGaWx0ZXJJZHMuaGFzKGYuaWQpKTsKICAgICAg
;YnRuRmlsdGVyVG9nZ2xlLmNsYXNzTGlzdC50b2dnbGUoJ2hhcy1hY3RpdmUnLCBoYXNBY3RpdmUpOwogICAgICBidG5GaWx0ZXJU
;b2dnbGUudGl0bGUgPSBmaWx0ZXJzT3BlbiA/ICfmlLbotbfnrZvpgInmnaHku7YnIDogKGhhc0FjdGl2ZSA/ICflsZXlvIDnrZvp
;gInmnaHku7bvvIjlt7LpgInvvIknIDogJ+WxleW8gOetm+mAieadoeS7ticpOwogICAgICBidG5GaWx0ZXJUb2dnbGUuc2V0QXR0
;cmlidXRlKCdhcmlhLWxhYmVsJywgYnRuRmlsdGVyVG9nZ2xlLnRpdGxlKTsKICAgIH0KICB9CiAgZnVuY3Rpb24gcmVuZGVyRmls
;dGVyQmFyKCkgewogICAgaWYgKCFmaWx0ZXJCYXIpIHJldHVybjsKICAgIGZpbHRlckJhci5pbm5lckhUTUwgPSAnJzsKICAgIGZv
;ciAoY29uc3QgZiBvZiB2aXNpYmxlRmlsdGVycygpKSB7CiAgICAgIGNvbnN0IGJ0biA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQo
;J2J1dHRvbicpOwogICAgICBidG4udHlwZSA9ICdidXR0b24nOwogICAgICBidG4uY2xhc3NOYW1lID0gJ2ZpbHRlci1jaGlwJyAr
;IChhY3RpdmVGaWx0ZXJJZHMuaGFzKGYuaWQpID8gJyBvbicgOiAnJyk7CiAgICAgIGJ0bi50ZXh0Q29udGVudCA9IGYudGl0bGU7
;CiAgICAgIGJ0bi50aXRsZSA9ICdyZWdleDonICsgZi5yZWdleDsKICAgICAgYnRuLm9uY2xpY2sgPSAoKSA9PiB7CiAgICAgICAg
;aWYgKGFjdGl2ZUZpbHRlcklkcy5oYXMoZi5pZCkpIGFjdGl2ZUZpbHRlcklkcy5kZWxldGUoZi5pZCk7CiAgICAgICAgZWxzZSBh
;Y3RpdmVGaWx0ZXJJZHMuYWRkKGYuaWQpOwogICAgICAgIHNhdmVBY3RpdmVGaWx0ZXJzKCk7CiAgICAgICAgcmVuZGVyRmlsdGVy
;QmFyKCk7CiAgICAgICAgaWYgKGFwcE1vZGUgPT09ICdmaWxlJykgZG9TZWFyY2goKTsKICAgICAgfTsKICAgICAgZmlsdGVyQmFy
;LmFwcGVuZENoaWxkKGJ0bik7CiAgICB9CiAgICBzeW5jRmlsdGVyVG9nZ2xlVWkoKTsKICB9CiAgZnVuY3Rpb24gbW92ZUZpbHRl
;cihpZHgsIGRpcikgewogICAgY29uc3QgaiA9IGlkeCArIGRpcjsKICAgIGlmIChqIDwgMCB8fCBqID49IGZpbHRlckl0ZW1zLmxl
;bmd0aCkgcmV0dXJuOwogICAgY29uc3QgdCA9IGZpbHRlckl0ZW1zW2lkeF07CiAgICBmaWx0ZXJJdGVtc1tpZHhdID0gZmlsdGVy
;SXRlbXNbal07CiAgICBmaWx0ZXJJdGVtc1tqXSA9IHQ7CiAgICBzYXZlRmlsdGVySXRlbXMoKTsKICAgIHJlbmRlckZpbHRlckJh
;cigpOwogICAgcmVuZGVyRmlsdGVyU2V0dGluZ3NMaXN0KCk7CiAgfQogIGZ1bmN0aW9uIHJlbmRlckZpbHRlclNldHRpbmdzTGlz
;dCgpIHsKICAgIGNvbnN0IGxpc3QgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnZnMtbGlzdCcpOwogICAgaWYgKCFsaXN0KSBy
;ZXR1cm47CiAgICBsaXN0LmlubmVySFRNTCA9ICcnOwogICAgZmlsdGVySXRlbXMuZm9yRWFjaCgoZiwgaWR4KSA9PiB7CiAgICAg
;IGNvbnN0IHJvdyA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOwogICAgICByb3cuY2xhc3NOYW1lID0gJ2ZzLWJsb2Nr
;JyArIChmLmVuYWJsZWQgPT09IGZhbHNlID8gJyBvZmYnIDogJycpOwoKICAgICAgY29uc3Qgb3JkID0gZG9jdW1lbnQuY3JlYXRl
;RWxlbWVudCgnZGl2Jyk7CiAgICAgIG9yZC5jbGFzc05hbWUgPSAnZnMtb3JkJzsKICAgICAgY29uc3QgdXAgPSBkb2N1bWVudC5j
;cmVhdGVFbGVtZW50KCdidXR0b24nKTsKICAgICAgdXAudHlwZSA9ICdidXR0b24nOwogICAgICB1cC50aXRsZSA9ICfkuIrnp7sn
;OwogICAgICB1cC5pbm5lckhUTUwgPSBTVkdfVVA7CiAgICAgIHVwLmRpc2FibGVkID0gaWR4ID09PSAwOwogICAgICB1cC5vbmNs
;aWNrID0gKCkgPT4gbW92ZUZpbHRlcihpZHgsIC0xKTsKICAgICAgY29uc3QgZG4gPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdi
;dXR0b24nKTsKICAgICAgZG4udHlwZSA9ICdidXR0b24nOwogICAgICBkbi50aXRsZSA9ICfkuIvnp7snOwogICAgICBkbi5pbm5l
;ckhUTUwgPSBTVkdfRE47CiAgICAgIGRuLmRpc2FibGVkID0gaWR4ID09PSBmaWx0ZXJJdGVtcy5sZW5ndGggLSAxOwogICAgICBk
;bi5vbmNsaWNrID0gKCkgPT4gbW92ZUZpbHRlcihpZHgsIDEpOwogICAgICBvcmQuYXBwZW5kQ2hpbGQodXApOwogICAgICBvcmQu
;YXBwZW5kQ2hpbGQoZG4pOwoKICAgICAgY29uc3QgbWFpbiA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOwogICAgICBt
;YWluLmNsYXNzTmFtZSA9ICdmcy1tYWluJzsKICAgICAgbWFpbi5pbm5lckhUTUwgPSAnPGRpdiBjbGFzcz0iZnMtdGl0bGUtcm93
;Ij48c3BhbiBjbGFzcz0iZnMtdGl0bGUiPicgKyBlc2NhcGVIdG1sKGYudGl0bGUpICsgJzwvc3Bhbj4nCiAgICAgICAgKyAoZi5i
;dWlsdGluID8gJzxzcGFuIGNsYXNzPSJmcy10YWciPuWGhee9rjwvc3Bhbj4nIDogJycpCiAgICAgICAgKyAnPC9kaXY+PGRpdiBj
;bGFzcz0iZnMtcmVnZXgiIHRpdGxlPSInICsgZXNjYXBlQXR0cihmLnJlZ2V4KSArICciPicgKyBlc2NhcGVIdG1sKGYucmVnZXgp
;ICsgJzwvZGl2Pic7CgogICAgICBjb25zdCBlbldyYXAgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsKICAgICAgZW5X
;cmFwLmNsYXNzTmFtZSA9ICdmcy1lbic7CiAgICAgIGNvbnN0IGxhYiA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ3NwYW4nKTsK
;ICAgICAgbGFiLmNsYXNzTmFtZSA9ICdmcy1lbi1sYWInOwogICAgICBsYWIudGV4dENvbnRlbnQgPSBmLmVuYWJsZWQgPT09IGZh
;bHNlID8gJ+W3suemgeeUqCcgOiAn5bey5ZCv55SoJzsKICAgICAgY29uc3Qgc3cgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdi
;dXR0b24nKTsKICAgICAgc3cudHlwZSA9ICdidXR0b24nOwogICAgICBzdy5jbGFzc05hbWUgPSAnZnMtc3dpdGNoJyArIChmLmVu
;YWJsZWQgPT09IGZhbHNlID8gJycgOiAnIG9uJyk7CiAgICAgIHN3LnRpdGxlID0gZi5lbmFibGVkID09PSBmYWxzZSA/ICflkK/n
;lKgnIDogJ+emgeeUqCc7CiAgICAgIHN3LnNldEF0dHJpYnV0ZSgnYXJpYS1wcmVzc2VkJywgZi5lbmFibGVkICE9PSBmYWxzZSA/
;ICd0cnVlJyA6ICdmYWxzZScpOwogICAgICBzdy5pbm5lckhUTUwgPSAnPGk+PC9pPic7CiAgICAgIHN3Lm9uY2xpY2sgPSAoKSA9
;PiB7CiAgICAgICAgZi5lbmFibGVkID0gZi5lbmFibGVkID09PSBmYWxzZTsKICAgICAgICBpZiAoZi5lbmFibGVkID09PSBmYWxz
;ZSkgYWN0aXZlRmlsdGVySWRzLmRlbGV0ZShmLmlkKTsKICAgICAgICBzYXZlRmlsdGVySXRlbXMoKTsKICAgICAgICBzYXZlQWN0
;aXZlRmlsdGVycygpOwogICAgICAgIHJlbmRlckZpbHRlckJhcigpOwogICAgICAgIHJlbmRlckZpbHRlclNldHRpbmdzTGlzdCgp
;OwogICAgICAgIGlmIChhcHBNb2RlID09PSAnZmlsZScpIGRvU2VhcmNoKCk7CiAgICAgIH07CiAgICAgIGVuV3JhcC5hcHBlbmRD
;aGlsZChsYWIpOwogICAgICBlbldyYXAuYXBwZW5kQ2hpbGQoc3cpOwoKICAgICAgY29uc3QgZGVsID0gZG9jdW1lbnQuY3JlYXRl
;RWxlbWVudCgnYnV0dG9uJyk7CiAgICAgIGRlbC50eXBlID0gJ2J1dHRvbic7CiAgICAgIGRlbC5jbGFzc05hbWUgPSAnZnMtZGVs
;JzsKICAgICAgZGVsLnRpdGxlID0gJ+WIoOmZpCc7CiAgICAgIGRlbC5pbm5lckhUTUwgPSBTVkdfWDsKICAgICAgZGVsLm9uY2xp
;Y2sgPSAoKSA9PiB7CiAgICAgICAgZmlsdGVySXRlbXMgPSBmaWx0ZXJJdGVtcy5maWx0ZXIoeCA9PiB4LmlkICE9PSBmLmlkKTsK
;ICAgICAgICBhY3RpdmVGaWx0ZXJJZHMuZGVsZXRlKGYuaWQpOwogICAgICAgIHNhdmVGaWx0ZXJJdGVtcygpOwogICAgICAgIHNh
;dmVBY3RpdmVGaWx0ZXJzKCk7CiAgICAgICAgcmVuZGVyRmlsdGVyQmFyKCk7CiAgICAgICAgcmVuZGVyRmlsdGVyU2V0dGluZ3NM
;aXN0KCk7CiAgICAgICAgaWYgKGFwcE1vZGUgPT09ICdmaWxlJykgZG9TZWFyY2goKTsKICAgICAgfTsKCiAgICAgIHJvdy5hcHBl
;bmRDaGlsZChvcmQpOwogICAgICByb3cuYXBwZW5kQ2hpbGQobWFpbik7CiAgICAgIHJvdy5hcHBlbmRDaGlsZChlbldyYXApOwog
;ICAgICByb3cuYXBwZW5kQ2hpbGQoZGVsKTsKICAgICAgbGlzdC5hcHBlbmRDaGlsZChyb3cpOwogICAgfSk7CiAgfQogIGZ1bmN0
;aW9uIHJlc2V0RmlsdGVyc1RvRGVmYXVsdCgpIHsKICAgIGZpbHRlckl0ZW1zID0gY2xvbmVCdWlsdGluRGVmYXVsdHMoKTsKICAg
;IGFjdGl2ZUZpbHRlcklkcyA9IG5ldyBTZXQoKTsKICAgIHNhdmVGaWx0ZXJJdGVtcygpOwogICAgc2F2ZUFjdGl2ZUZpbHRlcnMo
;KTsKICAgIHJlbmRlckZpbHRlckJhcigpOwogICAgcmVuZGVyRmlsdGVyU2V0dGluZ3NMaXN0KCk7CiAgICBpZiAoYXBwTW9kZSA9
;PT0gJ2ZpbGUnKSBkb1NlYXJjaCgpOwogIH0KICBmdW5jdGlvbiBvcGVuRmlsdGVyU2V0dGluZ3MoKSB7CiAgICByZW5kZXJGaWx0
;ZXJTZXR0aW5nc0xpc3QoKTsKICAgIGlmIChmaWx0ZXJTZXR0aW5ncykgZmlsdGVyU2V0dGluZ3MuY2xhc3NMaXN0LmFkZCgnb24n
;KTsKICB9CiAgZnVuY3Rpb24gY2xvc2VGaWx0ZXJTZXR0aW5ncygpIHsKICAgIGlmIChmaWx0ZXJTZXR0aW5ncykgZmlsdGVyU2V0
;dGluZ3MuY2xhc3NMaXN0LnJlbW92ZSgnb24nKTsKICB9CiAgbG9hZEZpbHRlclN0YXRlKCk7CiAgcmVuZGVyRmlsdGVyQmFyKCk7
;CiAgaWYgKGJ0bkZpbHRlclRvZ2dsZSkgewogICAgYnRuRmlsdGVyVG9nZ2xlLm9uY2xpY2sgPSAoZSkgPT4gewogICAgICBlLnN0
;b3BQcm9wYWdhdGlvbigpOwogICAgICBmaWx0ZXJzT3BlbiA9ICFmaWx0ZXJzT3BlbjsKICAgICAgc3luY0ZpbHRlclRvZ2dsZVVp
;KCk7CiAgICB9OwogIH0KICBjb25zdCBmc0Nsb3NlID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2ZzLWNsb3NlJyk7CiAgaWYg
;KGZzQ2xvc2UpIGZzQ2xvc2Uub25jbGljayA9ICgpID0+IGNsb3NlRmlsdGVyU2V0dGluZ3MoKTsKICBpZiAoZmlsdGVyU2V0dGlu
;Z3MpIHsKICAgIGZpbHRlclNldHRpbmdzLmFkZEV2ZW50TGlzdGVuZXIoJ2NsaWNrJywgZSA9PiB7CiAgICAgIGlmIChlLnRhcmdl
;dCA9PT0gZmlsdGVyU2V0dGluZ3MpIGNsb3NlRmlsdGVyU2V0dGluZ3MoKTsKICAgIH0pOwogIH0KICBjb25zdCBmc0FkZCA9IGRv
;Y3VtZW50LmdldEVsZW1lbnRCeUlkKCdmcy1hZGQnKTsKICBpZiAoZnNBZGQpIHsKICAgIGZzQWRkLm9uY2xpY2sgPSAoKSA9PiB7
;CiAgICAgIGNvbnN0IHRpdGxlID0gU3RyaW5nKChkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnZnMtdGl0bGUnKSB8fCB7fSkudmFs
;dWUgfHwgJycpLnRyaW0oKTsKICAgICAgY29uc3QgcmVnZXggPSBTdHJpbmcoKGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdmcy1y
;ZWdleCcpIHx8IHt9KS52YWx1ZSB8fCAnJykudHJpbSgpOwogICAgICBpZiAoIXRpdGxlKSB7IHRyeSB7IGRvY3VtZW50LmdldEVs
;ZW1lbnRCeUlkKCdmcy10aXRsZScpLmZvY3VzKCk7IH0gY2F0Y2ggKF8pIHt9IHJldHVybjsgfQogICAgICBpZiAoIXJlZ2V4KSB7
;IHRyeSB7IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdmcy1yZWdleCcpLmZvY3VzKCk7IH0gY2F0Y2ggKF8pIHt9IHJldHVybjsg
;fQogICAgICBjb25zdCBpZCA9ICdjXycgKyBEYXRlLm5vdygpLnRvU3RyaW5nKDM2KSArIE1hdGgucmFuZG9tKCkudG9TdHJpbmco
;MzYpLnNsaWNlKDIsIDYpOwogICAgICBmaWx0ZXJJdGVtcy5wdXNoKHsgaWQsIHRpdGxlOiB0aXRsZS5zbGljZSgwLCAyNCksIHJl
;Z2V4OiByZWdleC5zbGljZSgwLCAyMDApLCBidWlsdGluOiBmYWxzZSwgZW5hYmxlZDogdHJ1ZSB9KTsKICAgICAgc2F2ZUZpbHRl
;ckl0ZW1zKCk7CiAgICAgIGZpbHRlcnNPcGVuID0gdHJ1ZTsKICAgICAgcmVuZGVyRmlsdGVyQmFyKCk7CiAgICAgIHJlbmRlckZp
;bHRlclNldHRpbmdzTGlzdCgpOwogICAgICBjb25zdCB0ID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2ZzLXRpdGxlJyk7CiAg
;ICAgIGNvbnN0IHIgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnZnMtcmVnZXgnKTsKICAgICAgaWYgKHQpIHQudmFsdWUgPSAn
;JzsKICAgICAgaWYgKHIpIHIudmFsdWUgPSAnJzsKICAgIH07CiAgfQogIGNvbnN0IGZzRXYgPSBkb2N1bWVudC5nZXRFbGVtZW50
;QnlJZCgnZnMtZXYtb3B0cycpOwogIGlmIChmc0V2KSBmc0V2Lm9uY2xpY2sgPSAoKSA9PiBwb3N0KCdzZXR0aW5ncycpOwogIGNv
;bnN0IGZzUmVzZXQgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnZnMtcmVzZXQnKTsKICBpZiAoZnNSZXNldCkgewogICAgZnNS
;ZXNldC5vbmNsaWNrID0gKCkgPT4gewogICAgICBpZiAoIWNvbmZpcm0oJ+aBouWkjem7mOiupOetm+mAie+8n+Wwhui/mOWOn+OA
;jOWQq+S4reaWhyAvIOmdnuS4i+WIkue6v+W8gOWktOOAje+8jOW5tua4hemZpOiHquWumuS5iemhueOAgicpKSByZXR1cm47CiAg
;ICAgIHJlc2V0RmlsdGVyc1RvRGVmYXVsdCgpOwogICAgfTsKICB9CiAgZG9jdW1lbnQuYWRkRXZlbnRMaXN0ZW5lcigna2V5ZG93
;bicsIGUgPT4gewogICAgaWYgKGUua2V5ID09PSAnRXNjYXBlJyAmJiBmaWx0ZXJTZXR0aW5ncyAmJiBmaWx0ZXJTZXR0aW5ncy5j
;bGFzc0xpc3QuY29udGFpbnMoJ29uJykpIHsKICAgICAgY2xvc2VGaWx0ZXJTZXR0aW5ncygpOwogICAgICBlLnN0b3BQcm9wYWdh
;dGlvbigpOwogICAgfQogIH0sIHRydWUpOwoKICAvLyDnlKggVVJMID9icD0g5bim5YWlIEFISyDlvZPliY3ov5vluqbvvJvkuIrp
;mZAgODjvvIzpgb/lhY3pppblsY/nm7TmjqUgMTAwJSDlho3pl6rov5vkuLvnlYzpnaIKICB0cnkgewogICAgY29uc3QgYnAgPSBN
;YXRoLm1heCg4LCBNYXRoLm1pbig4OCwgcGFyc2VJbnQobmV3IFVSTFNlYXJjaFBhcmFtcyhsb2NhdGlvbi5zZWFyY2gpLmdldCgn
;YnAnKSB8fCAnMjAnLCAxMCkgfHwgMjApKTsKICAgIHNldEJvb3RQY3QoYnApOwogICAgY29uc3QgdDEgPSBkb2N1bWVudC5xdWVy
;eVNlbGVjdG9yKCcjYm9vdCAudDEnKTsKICAgIGlmICh0MSAmJiBicCA+PSA4MCkgdDEudGV4dENvbnRlbnQgPSAn5Y2z5bCG5a6M
;5oiQJzsKICAgIGVsc2UgaWYgKHQxICYmIGJwID49IDQwKSB0MS50ZXh0Q29udGVudCA9ICfno4Hnm5jntKLlvJXkuK0nOwogICAg
;ZWxzZSBpZiAodDEpIHQxLnRleHRDb250ZW50ID0gJ+ato+WcqOWKoOi9vSc7CiAgfSBjYXRjaCAoZSkge30KCiAgLy8g4pSA4pSA
;IOWFs+iBlOWPpeafhCAvIOacrOacuuS/oeaBr++8iOW1jOWFpeS4u+WIl+ihqOWMuu+8ieKUgOKUgOKUgOKUgOKUgOKUgOKUgOKU
;gOKUgOKUgOKUgOKUgOKUgOKUgOKUgAogIGNvbnN0IGluZm9QYW5lbCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdpbmZvLXBh
;bmVsJyk7CiAgY29uc3QgaGFuZGxlUGFuZWwgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnaGFuZGxlLXBhbmVsJyk7CiAgY29u
;c3QgaGFuZGxlQm9keSA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdoYW5kbGUtYm9keScpOwogIGNvbnN0IGhhbmRsZUJhbm5l
;ciA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdoYW5kbGUtYmFubmVyJyk7CiAgY29uc3QgaGFuZGxlU3RhdHVzID0gZG9jdW1l
;bnQuZ2V0RWxlbWVudEJ5SWQoJ2hhbmRsZS1zdGF0dXMnKTsKICBjb25zdCBidG5Qb3J0TWFyayA9IGRvY3VtZW50LmdldEVsZW1l
;bnRCeUlkKCdidG4tcG9ydC1tYXJrJyk7CiAgY29uc3QgcG9ydE1hcmtQb3AgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgncG9y
;dC1tYXJrLXBvcCcpOwogIGNvbnN0IHBvcnRNYXJrVGFncyA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdwb3J0LW1hcmstdGFn
;cycpOwogIGNvbnN0IHBvcnRNYXJrSW5wdXQgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgncG9ydC1tYXJrLWlucHV0Jyk7CiAg
;Y29uc3QgcHJvY01lbnUgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgncHJvYy1tZW51Jyk7CiAgY29uc3QgZmlsZVJlc3VsdHMg
;PSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnZmlsZS1yZXN1bHRzJyk7CiAgY29uc3QgbWFpbkVsID0gZG9jdW1lbnQuZ2V0RWxl
;bWVudEJ5SWQoJ21haW4nKTsKICBjb25zdCBiYXJFbCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdiYXInKTsKICBjb25zdCBN
;QVJLRURfUE9SVF9LRVkgPSAnYWhrX21hcmtlZF9wb3J0c192MSc7CiAgY29uc3QgREVGQVVMVF9NQVJLRURfUE9SVFMgPSBbMjEs
;IDIyLCAyNSwgNTMsIDgwLCAxMTAsIDE0MywgNDQzLCA0NDUsIDMzMDYsIDMzODksIDU0MzIsIDYzNzksIDgwODAsIDg0NDMsIDI3
;MDE3XTsKICBsZXQgbWFya2VkUG9ydHMgPSBsb2FkTWFya2VkUG9ydHMoKTsKICBmdW5jdGlvbiBsb2FkTWFya2VkUG9ydHMoKSB7
;CiAgICB0cnkgewogICAgICBjb25zdCByYXcgPSBsb2NhbFN0b3JhZ2UuZ2V0SXRlbShNQVJLRURfUE9SVF9LRVkpOwogICAgICBp
;ZiAocmF3ID09IG51bGwpIHJldHVybiBERUZBVUxUX01BUktFRF9QT1JUUy5zbGljZSgpOwogICAgICBjb25zdCBhcnIgPSBKU09O
;LnBhcnNlKHJhdyk7CiAgICAgIGlmICghQXJyYXkuaXNBcnJheShhcnIpKSByZXR1cm4gREVGQVVMVF9NQVJLRURfUE9SVFMuc2xp
;Y2UoKTsKICAgICAgY29uc3Qgb3V0ID0gW10sIHNlZW4gPSBuZXcgU2V0KCk7CiAgICAgIGZvciAoY29uc3QgeCBvZiBhcnIpIHsK
;ICAgICAgICBjb25zdCBwID0gcGFyc2VJbnQoeCwgMTApOwogICAgICAgIGlmICghTnVtYmVyLmlzSW50ZWdlcihwKSB8fCBwIDwg
;MCB8fCBwID4gNjU1MzUgfHwgc2Vlbi5oYXMocCkpIGNvbnRpbnVlOwogICAgICAgIHNlZW4uYWRkKHApOyBvdXQucHVzaChwKTsK
;ICAgICAgfQogICAgICByZXR1cm4gb3V0LnNvcnQoKGEsIGIpID0+IGEgLSBiKTsKICAgIH0gY2F0Y2ggKF8pIHsgcmV0dXJuIERF
;RkFVTFRfTUFSS0VEX1BPUlRTLnNsaWNlKCk7IH0KICB9CiAgZnVuY3Rpb24gc2F2ZU1hcmtlZFBvcnRzKCkgewogICAgdHJ5IHsg
;bG9jYWxTdG9yYWdlLnNldEl0ZW0oTUFSS0VEX1BPUlRfS0VZLCBKU09OLnN0cmluZ2lmeShtYXJrZWRQb3J0cykpOyB9IGNhdGNo
;IChfKSB7fQogIH0KICBmdW5jdGlvbiBwb3J0SXNIb3QocG9ydCkgewogICAgY29uc3QgcCA9IE51bWJlcihwb3J0KTsKICAgIHJl
;dHVybiBOdW1iZXIuaXNGaW5pdGUocCkgJiYgcCA+PSAwICYmIG1hcmtlZFBvcnRzLmluY2x1ZGVzKHApOwogIH0KICBmdW5jdGlv
;biBjbG9zZVBvcnRNYXJrUG9wKCkgewogICAgaWYgKHBvcnRNYXJrUG9wKSBwb3J0TWFya1BvcC5jbGFzc0xpc3QucmVtb3ZlKCdv
;bicpOwogICAgaWYgKGJ0blBvcnRNYXJrKSBidG5Qb3J0TWFyay5jbGFzc0xpc3QucmVtb3ZlKCdvbicpOwogIH0KICBmdW5jdGlv
;biByZW5kZXJNYXJrZWRQb3J0VGFncygpIHsKICAgIGlmICghcG9ydE1hcmtUYWdzKSByZXR1cm47CiAgICBpZiAoIW1hcmtlZFBv
;cnRzLmxlbmd0aCkgewogICAgICBwb3J0TWFya1RhZ3MuaW5uZXJIVE1MID0gJzxkaXYgY2xhc3M9InBtcC1lbXB0eSI+5pqC5peg
;5qCH6K6w56uv5Y+jPC9kaXY+JzsKICAgICAgcmV0dXJuOwogICAgfQogICAgcG9ydE1hcmtUYWdzLmlubmVySFRNTCA9IG1hcmtl
;ZFBvcnRzLm1hcChwID0+CiAgICAgICc8c3BhbiBjbGFzcz0icG1wLXRhZyIgZGF0YS1wb3J0PSInICsgcCArICciPicgKyBwCiAg
;ICAgICsgJzxidXR0b24gdHlwZT0iYnV0dG9uIiB0aXRsZT0i56e76ZmkIiBkYXRhLXJtPSInICsgcCArICciPsOXPC9idXR0b24+
;PC9zcGFuPicKICAgICkuam9pbignJyk7CiAgICBwb3J0TWFya1RhZ3MucXVlcnlTZWxlY3RvckFsbCgnYnV0dG9uW2RhdGEtcm1d
;JykuZm9yRWFjaChidG4gPT4gewogICAgICBidG4ub25jbGljayA9IChlKSA9PiB7CiAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24o
;KTsKICAgICAgICBjb25zdCBwID0gTnVtYmVyKGJ0bi5nZXRBdHRyaWJ1dGUoJ2RhdGEtcm0nKSk7CiAgICAgICAgbWFya2VkUG9y
;dHMgPSBtYXJrZWRQb3J0cy5maWx0ZXIoeCA9PiB4ICE9PSBwKTsKICAgICAgICBzYXZlTWFya2VkUG9ydHMoKTsKICAgICAgICBy
;ZW5kZXJNYXJrZWRQb3J0VGFncygpOwogICAgICAgIGlmIChhcHBNb2RlID09PSAnaGFuZGxlJyAmJiBoYW5kbGVNb2RlID09PSAn
;cG9ydCcpIHJlbmRlckhhbmRsZVRhYmxlKCk7CiAgICAgIH07CiAgICB9KTsKICB9CiAgZnVuY3Rpb24gYWRkTWFya2VkUG9ydChy
;YXcpIHsKICAgIGNvbnN0IHBhcnRzID0gU3RyaW5nKHJhdyB8fCAnJykuc3BsaXQoL1ssfO+8jFxzXSsvKS5tYXAocyA9PiBzLnRy
;aW0oKSkuZmlsdGVyKEJvb2xlYW4pOwogICAgbGV0IGNoYW5nZWQgPSBmYWxzZTsKICAgIGZvciAoY29uc3QgcGFydCBvZiBwYXJ0
;cykgewogICAgICBjb25zdCBwID0gcGFyc2VJbnQocGFydCwgMTApOwogICAgICBpZiAoIU51bWJlci5pc0ludGVnZXIocCkgfHwg
;cCA8IDAgfHwgcCA+IDY1NTM1KSBjb250aW51ZTsKICAgICAgaWYgKG1hcmtlZFBvcnRzLmluY2x1ZGVzKHApKSBjb250aW51ZTsK
;ICAgICAgbWFya2VkUG9ydHMucHVzaChwKTsKICAgICAgY2hhbmdlZCA9IHRydWU7CiAgICB9CiAgICBpZiAoIWNoYW5nZWQpIHJl
;dHVybiBmYWxzZTsKICAgIG1hcmtlZFBvcnRzLnNvcnQoKGEsIGIpID0+IGEgLSBiKTsKICAgIHNhdmVNYXJrZWRQb3J0cygpOwog
;ICAgcmVuZGVyTWFya2VkUG9ydFRhZ3MoKTsKICAgIGlmIChhcHBNb2RlID09PSAnaGFuZGxlJyAmJiBoYW5kbGVNb2RlID09PSAn
;cG9ydCcpIHJlbmRlckhhbmRsZVRhYmxlKCk7CiAgICByZXR1cm4gdHJ1ZTsKICB9CiAgZnVuY3Rpb24gb3BlblBvcnRNYXJrUG9w
;KCkgewogICAgcmVuZGVyTWFya2VkUG9ydFRhZ3MoKTsKICAgIGlmIChwb3J0TWFya1BvcCkgcG9ydE1hcmtQb3AuY2xhc3NMaXN0
;LmFkZCgnb24nKTsKICAgIGlmIChidG5Qb3J0TWFyaykgYnRuUG9ydE1hcmsuY2xhc3NMaXN0LmFkZCgnb24nKTsKICAgIHRyeSB7
;IHBvcnRNYXJrSW5wdXQgJiYgcG9ydE1hcmtJbnB1dC5mb2N1cygpOyB9IGNhdGNoIChfKSB7fQogIH0KICBsZXQgaGFuZGxlSXRl
;bXMgPSBbXTsKICBsZXQgaGFuZGxlUXVlcnkgPSAnJzsKICBsZXQgaGFuZGxlQnVzeSA9IGZhbHNlOwogIGxldCBpbmZvRGF0YSA9
;IG51bGw7CiAgbGV0IGluZm9UZXh0ID0gJyc7CiAgbGV0IGluZm9SZXFHZW4gPSAwOwogIGxldCBpbmZvTG9hZFRpbWVyID0gMDsK
;ICBsZXQgbW9uaXRvclRhYiA9ICdmaWxlJzsKICBsZXQgaGFuZGxlTW9kZSA9ICdoYW5kbGUnOwogIGxldCBoYW5kbGVTb3J0S2V5
;ID0gJ2xwb3J0JzsKICBsZXQgaGFuZGxlU29ydERpciA9IDE7IC8vIDE95Y2H5bqPIC0xPemZjeW6jwogIGNvbnN0IERFRkFVTFRf
;UE9SVF9RVUVSWSA9ICcwLTY1NTM1JzsKICBjb25zdCBoYW5kbGVIZWFkID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2hhbmRs
;ZS1oZWFkJyk7CiAgbGV0IHByb2NNZW51VGFyZ2V0cyA9IFtdOwogIGxldCBoYW5kbGVTZWxLZXlzID0gbmV3IFNldCgpOwogIGxl
;dCBoYW5kbGVBbmNob3JLZXkgPSAnJzsKICAvLyDml6fov5vnqIvnm5HmjqcgVUkg5bey56e76Zmk77ya5Y2g5L2N6YG/5YWN5q6L
;55WZ5Luj56CB5oql6ZSZCiAgY29uc3QgcHJvY0hlYWQgPSBudWxsOwogIGNvbnN0IHByb2NCb2R5ID0gbnVsbDsKICBjb25zdCBw
;cm9jU2Nyb2xsID0gbnVsbDsKICBjb25zdCBwcm9jQ3B1VG90YWwgPSBudWxsOwogIGNvbnN0IHByb2NNZW1Ub3RhbCA9IG51bGw7
;CiAgbGV0IHByb2NJdGVtcyA9IFtdOwogIGxldCBwcm9jU2hvd1N5cyA9IGZhbHNlOwogIGxldCBwcm9jU2VsS2V5cyA9IG5ldyBT
;ZXQoKTsKICBsZXQgcHJvY1NlbEtleSA9ICcnOwogIGxldCBwcm9jU2VsUGlkID0gMDsKICBsZXQgcHJvY0FuY2hvcktleSA9ICcn
;OwogIGxldCBwcm9jU29ydEtleSA9ICduYW1lJzsKICBsZXQgcHJvY1NvcnREaXIgPSAxOwogIGNvbnN0IHByb2NSb3dNYXAgPSBu
;ZXcgTWFwKCk7CiAgY29uc3QgcHJvY0ljb25TdGFibGUgPSBuZXcgTWFwKCk7CgogIGZ1bmN0aW9uIHNldEFwcE1vZGUobW9kZSkg
;ewogICAgaWYgKG1vZGUgIT09ICdoYW5kbGUnICYmIG1vZGUgIT09ICdpbmZvJykgbW9kZSA9ICdmaWxlJzsKICAgIC8vIOemu+W8
;gOW9k+WJjeaooeW8j+WJjeWFiOWtmOS4i+aQnOe0ouahhgogICAgaWYgKGFwcE1vZGUgPT09ICdmaWxlJykgbW9kZVF1ZXJ5LmZp
;bGUgPSBTdHJpbmcocUVsLnZhbHVlIHx8ICcnKTsKICAgIGVsc2UgaWYgKGFwcE1vZGUgPT09ICdoYW5kbGUnKSBtb2RlUXVlcnku
;aGFuZGxlID0gU3RyaW5nKHFFbC52YWx1ZSB8fCAnJyk7CiAgICBlbHNlIGlmIChhcHBNb2RlID09PSAnaW5mbycpIG1vZGVRdWVy
;eS5pbmZvID0gU3RyaW5nKHFFbC52YWx1ZSB8fCAnJyk7CiAgICBjb25zdCBwcmV2ID0gYXBwTW9kZTsKICAgIGFwcE1vZGUgPSBt
;b2RlOwogICAgbW9uaXRvclRhYiA9IG1vZGUgPT09ICdmaWxlJyA/ICdmaWxlJyA6IG1vZGU7CiAgICBjb25zdCBpc0ZpbGUgPSBt
;b2RlID09PSAnZmlsZSc7CiAgICBjb25zdCBpc0hhbmRsZSA9IG1vZGUgPT09ICdoYW5kbGUnOwogICAgY29uc3QgaXNJbmZvID0g
;bW9kZSA9PT0gJ2luZm8nOwogICAgY29uc3QgdG9wRWwgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgndG9wJyk7CiAgICBpZiAo
;bWFpbkVsKSB7CiAgICAgIG1haW5FbC5jbGFzc0xpc3QudG9nZ2xlKCdtb2RlLXRvb2wnLCAhaXNGaWxlKTsKICAgICAgbWFpbkVs
;LmNsYXNzTGlzdC50b2dnbGUoJ21vZGUtaGFuZGxlJywgaXNIYW5kbGUpOwogICAgICBtYWluRWwuY2xhc3NMaXN0LnRvZ2dsZSgn
;bW9kZS1pbmZvJywgaXNJbmZvKTsKICAgIH0KICAgIGlmIChiYXJFbCkgewogICAgICBiYXJFbC5jbGFzc0xpc3QudG9nZ2xlKCdt
;b2RlLXRvb2wnLCAhaXNGaWxlKTsKICAgICAgYmFyRWwuY2xhc3NMaXN0LnRvZ2dsZSgnbW9kZS1pbmZvJywgaXNJbmZvKTsKICAg
;ICAgYmFyRWwuY2xhc3NMaXN0LnRvZ2dsZSgnbW9kZS1oYW5kbGUnLCBpc0hhbmRsZSk7CiAgICB9CiAgICBpZiAodG9wRWwpIHsK
;ICAgICAgdG9wRWwuY2xhc3NMaXN0LnRvZ2dsZSgnbW9kZS10b29sJywgIWlzRmlsZSk7CiAgICAgIHRvcEVsLmNsYXNzTGlzdC50
;b2dnbGUoJ21vZGUtaGFuZGxlJywgaXNIYW5kbGUpOwogICAgICB0b3BFbC5jbGFzc0xpc3QudG9nZ2xlKCdtb2RlLWluZm8nLCBp
;c0luZm8pOwogICAgfQogICAgaWYgKGFwcFJvb3QpIGFwcFJvb3QuY2xhc3NMaXN0LnRvZ2dsZSgnaGlkZS1maWx0ZXJzJywgIWlz
;RmlsZSk7CiAgICBpZiAoZmlsZVJlc3VsdHMpIGZpbGVSZXN1bHRzLmNsYXNzTGlzdC50b2dnbGUoJ2hpZGRlbicsICFpc0ZpbGUp
;OwogICAgaWYgKGhhbmRsZVBhbmVsKSBoYW5kbGVQYW5lbC5jbGFzc0xpc3QudG9nZ2xlKCdoaWRkZW4nLCAhaXNIYW5kbGUpOwog
;ICAgaWYgKGluZm9QYW5lbCkgaW5mb1BhbmVsLmNsYXNzTGlzdC50b2dnbGUoJ2hpZGRlbicsICFpc0luZm8pOwogICAgcUVsLnJl
;YWRPbmx5ID0gaXNJbmZvOwogICAgY2xvc2VIaXN0TWVudSgpOwogICAgY2xvc2VQb3J0TWFya1BvcCgpOwogICAgcG9zdCgncHJv
;Y1ZpZXd8MCcpOwogICAgaWYgKGlzSGFuZGxlKSB7CiAgICAgIHFFbC5wbGFjZWhvbGRlciA9IFBMQUNFSE9MREVSX0hBTkRMRTsK
;ICAgICAgaGFuZGxlU29ydEtleSA9ICdscG9ydCc7CiAgICAgIGhhbmRsZVNvcnREaXIgPSAxOwogICAgICBxRWwudmFsdWUgPSBt
;b2RlUXVlcnkuaGFuZGxlOwogICAgICBzeW5jQ2xlYXJCdG4oKTsKICAgICAgcmVxdWVzdEhhbmRsZVNlYXJjaChtb2RlUXVlcnku
;aGFuZGxlKTsKICAgICAgdHJ5IHsgcUVsLmZvY3VzKCk7IH0gY2F0Y2ggKF8pIHt9CiAgICB9IGVsc2UgaWYgKGlzSW5mbykgewog
;ICAgICBxRWwucGxhY2Vob2xkZXIgPSBQTEFDRUhPTERFUl9JTkZPOwogICAgICBxRWwudmFsdWUgPSBtb2RlUXVlcnkuaW5mbzsK
;ICAgICAgc3luY0NsZWFyQnRuKCk7CiAgICAgIGNvdW50RWwudGV4dENvbnRlbnQgPSAn5pys5py65L+h5oGvJzsKICAgICAgcmVx
;dWVzdFN5c0luZm8oZmFsc2UpOwogICAgfSBlbHNlIHsKICAgICAgcUVsLnBsYWNlaG9sZGVyID0gUExBQ0VIT0xERVJfRklMRTsK
;ICAgICAgcUVsLnZhbHVlID0gbW9kZVF1ZXJ5LmZpbGU7CiAgICAgIHN5bmNDbGVhckJ0bigpOwogICAgICB0cnkgeyBxRWwuZm9j
;dXMoKTsgfSBjYXRjaCAoXykge30KICAgICAgLy8g5LuO5YW25a6D5qih5byP5YiH5Zue5paH5Lu277ya55So5pys5Zyw5p2h5Lu2
;6YeN5pCc77yI5ZCr562b6YCJ77yJ77yM5LiN5bim5Y+l5p+E5YWz6ZSu5a2XCiAgICAgIGlmIChwcmV2ICE9PSAnZmlsZScpIGRv
;U2VhcmNoKCk7CiAgICB9CiAgfQogIGZ1bmN0aW9uIHNldEFwcFZpZXcobmFtZSkgewogICAgLy8g5YW85a655pen5YWl5Y+j77ya
;5YiH5Yiw5L6n5qCP5a+55bqU6aG5CiAgICBpZiAobmFtZSA9PT0gJ2hhbmRsZScgfHwgbmFtZSA9PT0gJ3Byb2MnKSB7CiAgICAg
;IGRvY3VtZW50LnF1ZXJ5U2VsZWN0b3JBbGwoJy5jYXQnKS5mb3JFYWNoKGIgPT4gYi5jbGFzc0xpc3QudG9nZ2xlKCdvbicsIGIu
;ZGF0YXNldC5jYXQgPT09ICdfX2hhbmRsZScpKTsKICAgICAgc2V0QXBwTW9kZSgnaGFuZGxlJyk7CiAgICAgIHJldHVybjsKICAg
;IH0KICAgIGlmIChuYW1lID09PSAnaW5mbycpIHsKICAgICAgZG9jdW1lbnQucXVlcnlTZWxlY3RvckFsbCgnLmNhdCcpLmZvckVh
;Y2goYiA9PiBiLmNsYXNzTGlzdC50b2dnbGUoJ29uJywgYi5kYXRhc2V0LmNhdCA9PT0gJ19faW5mbycpKTsKICAgICAgc2V0QXBw
;TW9kZSgnaW5mbycpOwogICAgICByZXR1cm47CiAgICB9CiAgICBkb2N1bWVudC5xdWVyeVNlbGVjdG9yQWxsKCcuY2F0JykuZm9y
;RWFjaChiID0+IGIuY2xhc3NMaXN0LnRvZ2dsZSgnb24nLCBiLmRhdGFzZXQuY2F0ID09PSBjYXQpKTsKICAgIHNldEFwcE1vZGUo
;J2ZpbGUnKTsKICB9CiAgZnVuY3Rpb24gc3luY1Byb2NNb25pdG9yTGl2ZSgpIHsgcG9zdCgncHJvY1ZpZXd8MCcpOyB9CiAgZnVu
;Y3Rpb24gcmVxdWVzdFByb2NMaXN0KCkgeyAvKiDlt7Lnp7vpmaTph43lnovov5vnqIvnm5HmjqcgKi8gfQogIGZ1bmN0aW9uIGNs
;ZWFySW5mb0xvYWRXYWl0KCkgewogICAgaWYgKGluZm9Mb2FkVGltZXIpIHsKICAgICAgY2xlYXJUaW1lb3V0KGluZm9Mb2FkVGlt
;ZXIpOwogICAgICBpbmZvTG9hZFRpbWVyID0gMDsKICAgIH0KICB9CiAgZnVuY3Rpb24gc2hvd0luZm9Mb2FkaW5nKCkgewogICAg
;aWYgKCFpbmZvUGFuZWwgfHwgYXBwTW9kZSAhPT0gJ2luZm8nKSByZXR1cm47CiAgICBpbmZvUGFuZWwuaW5uZXJIVE1MID0gJzxk
;aXYgY2xhc3M9ImluZm8tbG9hZGluZyI+PGRpdiBjbGFzcz0iaW5mby1zcGlubmVyIiBhcmlhLWhpZGRlbj0idHJ1ZSI+PC9kaXY+
;PGRpdj7mraPlnKjor7vlj5bmnKzmnLrkv6Hmga/igKY8L2Rpdj48L2Rpdj4nOwogICAgaWYgKGNvdW50RWwpIGNvdW50RWwudGV4
;dENvbnRlbnQgPSAn5Yqg6L295Lit4oCmJzsKICB9CiAgZnVuY3Rpb24gcmVxdWVzdFN5c0luZm8oZm9yY2UpIHsKICAgIGZvcmNl
;ID0gISFmb3JjZTsKICAgIGNvbnN0IG15R2VuID0gKytpbmZvUmVxR2VuOwogICAgY2xlYXJJbmZvTG9hZFdhaXQoKTsKICAgIC8v
;IOe8k+WtmOWRveS4remAmuW4uOW+iOW/q++8m+i2hei/h+e6piAwLjRzIOWGjeWHuuWKoOi9veWKqOeUu++8jOmBv+WFjemXquS4
;gOS4iwogICAgaWYgKGZvcmNlIHx8ICFpbmZvRGF0YSkgewogICAgICBpbmZvTG9hZFRpbWVyID0gc2V0VGltZW91dCgoKSA9PiB7
;CiAgICAgICAgaW5mb0xvYWRUaW1lciA9IDA7CiAgICAgICAgaWYgKG15R2VuICE9PSBpbmZvUmVxR2VuIHx8IGFwcE1vZGUgIT09
;ICdpbmZvJykgcmV0dXJuOwogICAgICAgIHNob3dJbmZvTG9hZGluZygpOwogICAgICB9LCA0MDApOwogICAgfQogICAgcG9zdCgn
;c3lzSW5mb3wnICsgKGZvcmNlID8gJzEnIDogJzAnKSk7CiAgfQogIGNvbnN0IEhBTkRMRV9ISVNUX0tFWSA9ICdhaGtfaGFuZGxl
;X3NlYXJjaF9oaXN0X3YxJzsKICBjb25zdCBIQU5ETEVfSElTVF9NQVggPSAxMDsKICBjb25zdCBoYW5kbGVIaXN0TGlzdCA9IGRv
;Y3VtZW50LmdldEVsZW1lbnRCeUlkKCdoYW5kbGUtaGlzdC1saXN0Jyk7CiAgZnVuY3Rpb24gbG9hZEhhbmRsZUhpc3QoKSB7CiAg
;ICB0cnkgewogICAgICBjb25zdCByYXcgPSBsb2NhbFN0b3JhZ2UuZ2V0SXRlbShIQU5ETEVfSElTVF9LRVkpOwogICAgICBjb25z
;dCBhcnIgPSByYXcgPyBKU09OLnBhcnNlKHJhdykgOiBbXTsKICAgICAgcmV0dXJuIEFycmF5LmlzQXJyYXkoYXJyKSA/IGFyci5m
;aWx0ZXIoeCA9PiBTdHJpbmcoeCB8fCAnJykudHJpbSgpKSA6IFtdOwogICAgfSBjYXRjaCAoXykgeyByZXR1cm4gW107IH0KICB9
;CiAgZnVuY3Rpb24gc2F2ZUhhbmRsZUhpc3QocSkgewogICAgcSA9IFN0cmluZyhxIHx8ICcnKS50cmltKCk7CiAgICBpZiAoIXEp
;IHJldHVybjsKICAgIGxldCBhcnIgPSBsb2FkSGFuZGxlSGlzdCgpLmZpbHRlcih4ID0+IHggIT09IHEpOwogICAgYXJyLnVuc2hp
;ZnQocSk7CiAgICBpZiAoYXJyLmxlbmd0aCA+IEhBTkRMRV9ISVNUX01BWCkgYXJyID0gYXJyLnNsaWNlKDAsIEhBTkRMRV9ISVNU
;X01BWCk7CiAgICB0cnkgeyBsb2NhbFN0b3JhZ2Uuc2V0SXRlbShIQU5ETEVfSElTVF9LRVksIEpTT04uc3RyaW5naWZ5KGFycikp
;OyB9IGNhdGNoIChfKSB7fQogICAgcmVuZGVySGFuZGxlSGlzdCgpOwogIH0KICBmdW5jdGlvbiByZW5kZXJIYW5kbGVIaXN0KCkg
;ewogICAgaWYgKCFoYW5kbGVIaXN0TGlzdCkgcmV0dXJuOwogICAgaGFuZGxlSGlzdExpc3QuaW5uZXJIVE1MID0gbG9hZEhhbmRs
;ZUhpc3QoKS5tYXAocSA9PgogICAgICAnPG9wdGlvbiB2YWx1ZT0iJyArIGVzY2FwZUh0bWwocSkgKyAnIj48L29wdGlvbj4nCiAg
;ICApLmpvaW4oJycpOwogIH0KICBmdW5jdGlvbiBub3JtYWxpemVQb3J0UXVlcnkocSkgewogICAgcSA9IFN0cmluZyhxIHx8ICcn
;KS50cmltKCk7CiAgICBjb25zdCBtID0gcS5tYXRjaCgvXlwv56uv5Y+jXHMqKC4qKSQvaSkgfHwgcS5tYXRjaCgvXlwvcG9ydFxz
;KiguKikkL2kpOwogICAgaWYgKG0pIHEgPSBTdHJpbmcobVsxXSB8fCAnJykudHJpbSgpOwogICAgcmV0dXJuIHE7CiAgfQogIGZ1
;bmN0aW9uIGlzUG9ydFNlYXJjaFF1ZXJ5KHEpIHsKICAgIHEgPSBub3JtYWxpemVQb3J0UXVlcnkocSk7CiAgICByZXR1cm4gISFx
;ICYmIC9eW1xkXHN8XC1dKyQvLnRlc3QocSkgJiYgL1xkLy50ZXN0KHEpOwogIH0KICBmdW5jdGlvbiBwYXJzZVBvcnRMaXN0KHEp
;IHsKICAgIHEgPSBub3JtYWxpemVQb3J0UXVlcnkocSk7CiAgICBjb25zdCBvdXQgPSBbXSwgc2VlbiA9IG5ldyBTZXQoKTsKICAg
;IGNvbnN0IGFkZCA9IChwKSA9PiB7CiAgICAgIHAgPSBOdW1iZXIocCk7CiAgICAgIGlmICghTnVtYmVyLmlzSW50ZWdlcihwKSB8
;fCBwIDwgMCB8fCBwID4gNjU1MzUgfHwgc2Vlbi5oYXMocCkpIHJldHVybjsKICAgICAgc2Vlbi5hZGQocCk7CiAgICAgIG91dC5w
;dXNoKHApOwogICAgfTsKICAgIGZvciAoY29uc3QgcGFydCBvZiBTdHJpbmcocSkuc3BsaXQoJ3wnKSkgewogICAgICBjb25zdCBz
;ID0gU3RyaW5nKHBhcnQgfHwgJycpLnRyaW0oKTsKICAgICAgaWYgKCFzKSBjb250aW51ZTsKICAgICAgY29uc3QgbSA9IHMubWF0
;Y2goL14oXGQrKVxzKi1ccyooXGQrKSQvKTsKICAgICAgaWYgKG0pIHsKICAgICAgICBsZXQgYSA9IHBhcnNlSW50KG1bMV0sIDEw
;KSwgYiA9IHBhcnNlSW50KG1bMl0sIDEwKTsKICAgICAgICBpZiAoYSA+IGIpIHsgY29uc3QgdCA9IGE7IGEgPSBiOyBiID0gdDsg
;fQogICAgICAgIGEgPSBNYXRoLm1heCgwLCBNYXRoLm1pbig2NTUzNSwgYSkpOwogICAgICAgIGIgPSBNYXRoLm1heCgwLCBNYXRo
;Lm1pbig2NTUzNSwgYikpOwogICAgICAgIGZvciAobGV0IHAgPSBhOyBwIDw9IGI7IHArKykgYWRkKHApOwogICAgICB9IGVsc2Ug
;aWYgKC9eXGQrJC8udGVzdChzKSkgewogICAgICAgIGFkZChwYXJzZUludChzLCAxMCkpOwogICAgICB9CiAgICB9CiAgICByZXR1
;cm4gb3V0OwogIH0KICBmdW5jdGlvbiBpc0FsbFBvcnRzUXVlcnlUZXh0KHEpIHsKICAgIHEgPSBTdHJpbmcocSB8fCAnJykudHJp
;bSgpOwogICAgcmV0dXJuICFxIHx8IHEgPT09IERFRkFVTFRfUE9SVF9RVUVSWSB8fCAvXjBccyotXHMqNjU1MzUkLy50ZXN0KHEp
;OwogIH0KICBmdW5jdGlvbiByZXF1ZXN0SGFuZGxlU2VhcmNoKHEpIHsKICAgIHEgPSBTdHJpbmcocSB8fCAnJykudHJpbSgpOwog
;ICAgLy8g56m65qGGIC8g5YWo56uv5Y+jIOKGkiDnm7TmjqXmmL7npLrlhajpg6jov57mjqXvvIzkuI3miormnaHku7blhpnov5vo
;vpPlhaXmoYYKICAgIGlmIChpc0FsbFBvcnRzUXVlcnlUZXh0KHEpKSB7CiAgICAgIGhhbmRsZVF1ZXJ5ID0gREVGQVVMVF9QT1JU
;X1FVRVJZOwogICAgICBoYW5kbGVNb2RlID0gJ3BvcnQnOwogICAgICBoYW5kbGVCdXN5ID0gdHJ1ZTsKICAgICAgaWYgKGhhbmRs
;ZVN0YXR1cykgaGFuZGxlU3RhdHVzLnRleHRDb250ZW50ID0gJ+ato+WcqOafpeivouKApic7CiAgICAgIGhhbmRsZUJhbm5lci5j
;bGFzc0xpc3QuYWRkKCdvbicpOwogICAgICBoYW5kbGVCYW5uZXIudGV4dENvbnRlbnQgPSAn5YWo6YOo6L+e5o6lJzsKICAgICAg
;aGFuZGxlU2VsS2V5cy5jbGVhcigpOwogICAgICBoYW5kbGVBbmNob3JLZXkgPSAnJzsKICAgICAgc3luY0hhbmRsZUJhcigwKTsK
;ICAgICAgc2hvd0hhbmRsZUxvYWRpbmcoJ+ato+WcqOafpeivouerr+WPo+WNoOeUqO+8jOivt+eojeWAmeKApicpOwogICAgICBw
;b3N0KCdoYW5kbGVTZWFyY2h8JyArIERFRkFVTFRfUE9SVF9RVUVSWSk7CiAgICAgIHJldHVybjsKICAgIH0KICAgIGhhbmRsZVF1
;ZXJ5ID0gcTsKICAgIGhhbmRsZU1vZGUgPSBpc1BvcnRTZWFyY2hRdWVyeShxKSA/ICdwb3J0JyA6ICdoYW5kbGUnOwogICAgaWYg
;KGhhbmRsZU1vZGUgPT09ICdwb3J0JyAmJiAhcGFyc2VQb3J0TGlzdChxKS5sZW5ndGgpIHsKICAgICAgaGFuZGxlSXRlbXMgPSBb
;XTsKICAgICAgcmVuZGVySGFuZGxlVGFibGUoJ+err+WPo+aXoOaViO+8jOekuuS+i++8mjgwODB8ODAg5oiWIDAtMzAwfDUwMCcp
;OwogICAgICByZXR1cm47CiAgICB9CiAgICBzYXZlSGFuZGxlSGlzdChxKTsKICAgIGhhbmRsZUJ1c3kgPSB0cnVlOwogICAgaWYg
;KGhhbmRsZVN0YXR1cykgaGFuZGxlU3RhdHVzLnRleHRDb250ZW50ID0gJ+ato+WcqOafpeivouKApic7CiAgICBoYW5kbGVCYW5u
;ZXIuY2xhc3NMaXN0LmFkZCgnb24nKTsKICAgIGhhbmRsZUJhbm5lci50ZXh0Q29udGVudCA9ICfigJwnICsgcSArICfigJ3nmoTm
;kJzntKLnu5PmnpwnOwogICAgaGFuZGxlU2VsS2V5cy5jbGVhcigpOwogICAgaGFuZGxlQW5jaG9yS2V5ID0gJyc7CiAgICBzeW5j
;SGFuZGxlQmFyKDApOwogICAgc2hvd0hhbmRsZUxvYWRpbmcoaGFuZGxlTW9kZSA9PT0gJ3BvcnQnID8gJ+ato+WcqOafpeivouer
;r+WPo+WNoOeUqO+8jOivt+eojeWAmeKApicgOiAn5q2j5Zyo5p+l6K+i5Y+l5p+E77yM6K+356iN5YCZ4oCmJyk7CiAgICBwb3N0
;KCdoYW5kbGVTZWFyY2h8JyArIHEpOwogIH0KICBmdW5jdGlvbiBzaG93SGFuZGxlTG9hZGluZyhtc2cpIHsKICAgIGhhbmRsZUJv
;ZHkuaW5uZXJIVE1MID0gJzxkaXYgY2xhc3M9ImhhbmRsZS1sb2FkaW5nIj48ZGl2IGNsYXNzPSJoYW5kbGUtc3Bpbm5lciIgYXJp
;YS1oaWRkZW49InRydWUiPjwvZGl2PjxkaXY+JwogICAgICArIGVzY2FwZUh0bWwobXNnIHx8ICfmraPlnKjmn6Xor6Llj6Xmn4Tv
;vIzor7fnqI3lgJnigKYnKSArICc8L2Rpdj48L2Rpdj4nOwogIH0KICBmdW5jdGlvbiBzb3J0SGFuZGxlSXRlbXMoaXRlbXMpIHsK
;ICAgIGNvbnN0IGtleSA9IGhhbmRsZVNvcnRLZXkgfHwgKGhhbmRsZU1vZGUgPT09ICdwb3J0JyA/ICdscG9ydCcgOiAnbmFtZScp
;OwogICAgY29uc3QgZGlyID0gaGFuZGxlU29ydERpciB8fCAxOwogICAgcmV0dXJuIChpdGVtcyB8fCBbXSkuc2xpY2UoKS5zb3J0
;KChhLCBiKSA9PiB7CiAgICAgIGxldCBjbXAgPSAwOwogICAgICBpZiAoa2V5ID09PSAncGlkJykgewogICAgICAgIGNtcCA9IChO
;dW1iZXIoYS5waWQpIHx8IDApIC0gKE51bWJlcihiLnBpZCkgfHwgMCk7CiAgICAgIH0gZWxzZSBpZiAoa2V5ID09PSAnbHBvcnQn
;KSB7CiAgICAgICAgY21wID0gKE51bWJlcihhLmxvY2FsUG9ydCkgfHwgMCkgLSAoTnVtYmVyKGIubG9jYWxQb3J0KSB8fCAwKTsK
;ICAgICAgfSBlbHNlIGlmIChrZXkgPT09ICdycG9ydCcpIHsKICAgICAgICBjbXAgPSAoTnVtYmVyKGEucmVtb3RlUG9ydCkgfHwg
;MCkgLSAoTnVtYmVyKGIucmVtb3RlUG9ydCkgfHwgMCk7CiAgICAgIH0gZWxzZSBpZiAoa2V5ID09PSAndHlwZScpIHsKICAgICAg
;ICBjbXAgPSBTdHJpbmcoYS50eXBlIHx8ICcnKS5sb2NhbGVDb21wYXJlKFN0cmluZyhiLnR5cGUgfHwgJycpLCAnZW4nLCB7IHNl
;bnNpdGl2aXR5OiAnYmFzZScgfSk7CiAgICAgIH0gZWxzZSBpZiAoa2V5ID09PSAnaGFuZGxlJykgewogICAgICAgIGNtcCA9IFN0
;cmluZyhhLmhhbmRsZSB8fCAnJykubG9jYWxlQ29tcGFyZShTdHJpbmcoYi5oYW5kbGUgfHwgJycpLCAnemgtQ04nKTsKICAgICAg
;fSBlbHNlIHsKICAgICAgICBjbXAgPSBjb21wYXJlUHJvY05hbWUoYS5uYW1lIHx8ICcnLCBiLm5hbWUgfHwgJycpOwogICAgICB9
;CiAgICAgIGlmIChjbXApIHJldHVybiBjbXAgKiBkaXI7CiAgICAgIC8vIOasoeimgemUru+8muerr+WPo+aooeW8j+S8mOWFiOac
;rOacuuerr+WPo++8jOWGjSBQSUQgLyDlkI3np7AKICAgICAgY29uc3QgbHAgPSAoTnVtYmVyKGEubG9jYWxQb3J0KSB8fCAwKSAt
;IChOdW1iZXIoYi5sb2NhbFBvcnQpIHx8IDApOwogICAgICBpZiAobHApIHJldHVybiBscDsKICAgICAgY29uc3QgcGEgPSAoTnVt
;YmVyKGEucGlkKSB8fCAwKSAtIChOdW1iZXIoYi5waWQpIHx8IDApOwogICAgICBpZiAocGEpIHJldHVybiBwYTsKICAgICAgcmV0
;dXJuIGNvbXBhcmVQcm9jTmFtZShhLm5hbWUgfHwgJycsIGIubmFtZSB8fCAnJyk7CiAgICB9KTsKICB9CiAgZnVuY3Rpb24gc3lu
;Y0hhbmRsZUhlYWRTb3J0KCkgewogICAgaWYgKCFoYW5kbGVIZWFkKSByZXR1cm47CiAgICBoYW5kbGVIZWFkLnF1ZXJ5U2VsZWN0
;b3JBbGwoJy5oYW5kbGUtaGNlbGxbZGF0YS1zb3J0XScpLmZvckVhY2goY2VsbCA9PiB7CiAgICAgIGNvbnN0IGsgPSBjZWxsLmdl
;dEF0dHJpYnV0ZSgnZGF0YS1zb3J0Jyk7CiAgICAgIGNvbnN0IG9uID0gayA9PT0gaGFuZGxlU29ydEtleTsKICAgICAgY2VsbC5j
;bGFzc0xpc3QudG9nZ2xlKCdzb3J0ZWQnLCBvbik7CiAgICAgIGNlbGwuY2xhc3NMaXN0LnRvZ2dsZSgnYXNjJywgb24gJiYgaGFu
;ZGxlU29ydERpciA+IDApOwogICAgICBjZWxsLmNsYXNzTGlzdC50b2dnbGUoJ2Rlc2MnLCBvbiAmJiBoYW5kbGVTb3J0RGlyIDwg
;MCk7CiAgICB9KTsKICB9CiAgZnVuY3Rpb24gYmluZEhhbmRsZUhlYWRTb3J0KCkgewogICAgaWYgKCFoYW5kbGVIZWFkIHx8IGhh
;bmRsZUhlYWQuZGF0YXNldC5zb3J0Qm91bmQgPT09ICcxJykgcmV0dXJuOwogICAgaGFuZGxlSGVhZC5kYXRhc2V0LnNvcnRCb3Vu
;ZCA9ICcxJzsKICAgIGhhbmRsZUhlYWQucXVlcnlTZWxlY3RvckFsbCgnLmhhbmRsZS1oY2VsbFtkYXRhLXNvcnRdJykuZm9yRWFj
;aChjZWxsID0+IHsKICAgICAgY2VsbC5hZGRFdmVudExpc3RlbmVyKCdjbGljaycsIChlKSA9PiB7CiAgICAgICAgZS5wcmV2ZW50
;RGVmYXVsdCgpOwogICAgICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAgICAgY29uc3QgayA9IGNlbGwuZ2V0QXR0cmlidXRl
;KCdkYXRhLXNvcnQnKTsKICAgICAgICBpZiAoIWspIHJldHVybjsKICAgICAgICBpZiAoaGFuZGxlU29ydEtleSA9PT0gaykgaGFu
;ZGxlU29ydERpciA9IC1oYW5kbGVTb3J0RGlyOwogICAgICAgIGVsc2UgewogICAgICAgICAgaGFuZGxlU29ydEtleSA9IGs7CiAg
;ICAgICAgICBoYW5kbGVTb3J0RGlyID0gKGsgPT09ICdscG9ydCcgfHwgayA9PT0gJ3Jwb3J0JyB8fCBrID09PSAncGlkJykgPyAx
;IDogMTsKICAgICAgICB9CiAgICAgICAgaWYgKGhhbmRsZUl0ZW1zLmxlbmd0aCkgcmVuZGVySGFuZGxlVGFibGUoKTsKICAgICAg
;ICBlbHNlIHN5bmNIYW5kbGVIZWFkU29ydCgpOwogICAgICB9KTsKICAgIH0pOwogIH0KICBiaW5kSGFuZGxlSGVhZFNvcnQoKTsK
;ICBmdW5jdGlvbiBwb3J0VGlwVGV4dChpdCkgewogICAgY29uc3QgbGlwID0gU3RyaW5nKGl0LmxvY2FsSXAgfHwgJzAuMC4wLjAn
;KTsKICAgIGNvbnN0IGxwb3J0ID0gKGl0LmxvY2FsUG9ydCA9PSBudWxsIHx8IE51bWJlcihpdC5sb2NhbFBvcnQpIDwgMCkgPyAn
;JyA6IFN0cmluZyhpdC5sb2NhbFBvcnQpOwogICAgY29uc3QgcmlwID0gU3RyaW5nKGl0LnJlbW90ZUlwIHx8ICcwLjAuMC4wJyk7
;CiAgICBjb25zdCBycG9ydCA9IChpdC5yZW1vdGVQb3J0ID09IG51bGwgfHwgTnVtYmVyKGl0LnJlbW90ZVBvcnQpIDwgMCkgPyAn
;JyA6IFN0cmluZyhpdC5yZW1vdGVQb3J0KTsKICAgIHJldHVybiAn5pys5py677yaJyArIGxpcCArICc6JyArIGxwb3J0ICsgJ1xu
;6L+c56iL77yaJyArIHJpcCArICc6JyArIHJwb3J0OwogIH0KICBmdW5jdGlvbiBzZXRIYW5kbGVQb3J0TW9kZShvbikgewogICAg
;ZG9jdW1lbnQucXVlcnlTZWxlY3RvckFsbCgnLmhhbmRsZS1jb2xzJykuZm9yRWFjaChlbCA9PiBlbC5jbGFzc0xpc3QudG9nZ2xl
;KCdwb3J0LW1vZGUnLCAhIW9uKSk7CiAgICBkb2N1bWVudC5xdWVyeVNlbGVjdG9yQWxsKCcuaGFuZGxlLWNvbC1wb3J0LC5oYW5k
;bGUtY29sLXJwb3J0JykuZm9yRWFjaChlbCA9PiBlbC5jbGFzc0xpc3QudG9nZ2xlKCdoaWRkZW4nLCAhb24pKTsKICB9CiAgZnVu
;Y3Rpb24gZGVkdXBlUG9ydEl0ZW1zKGl0ZW1zKSB7CiAgICBjb25zdCBvdXQgPSBbXSwgc2VlbiA9IG5ldyBTZXQoKTsKICAgIGZv
;ciAoY29uc3QgaXQgb2YgaXRlbXMgfHwgW10pIHsKICAgICAgY29uc3Qga2V5ID0gWwogICAgICAgIE51bWJlcihpdC5waWQpIHx8
;IDAsCiAgICAgICAgU3RyaW5nKGl0LnR5cGUgfHwgJycpLnRvVXBwZXJDYXNlKCksCiAgICAgICAgTnVtYmVyKGl0LmxvY2FsUG9y
;dCkgfHwgMCwKICAgICAgICBOdW1iZXIoaXQucmVtb3RlUG9ydCkgfHwgMCwKICAgICAgICBTdHJpbmcoaXQuaGFuZGxlIHx8ICcn
;KQogICAgICBdLmpvaW4oJ3wnKTsKICAgICAgaWYgKHNlZW4uaGFzKGtleSkpIGNvbnRpbnVlOwogICAgICBzZWVuLmFkZChrZXkp
;OwogICAgICBvdXQucHVzaChpdCk7CiAgICB9CiAgICByZXR1cm4gb3V0OwogIH0KICBmdW5jdGlvbiByZW5kZXJIYW5kbGVUYWJs
;ZShlbXB0eU1zZykgewogICAgY29uc3QgcSA9IGhhbmRsZVF1ZXJ5OwogICAgY29uc3QgcG9ydE1vZGUgPSBoYW5kbGVNb2RlID09
;PSAncG9ydCc7CiAgICBzZXRIYW5kbGVQb3J0TW9kZShwb3J0TW9kZSk7CiAgICBpZiAocSkgewogICAgICBoYW5kbGVCYW5uZXIu
;Y2xhc3NMaXN0LmFkZCgnb24nKTsKICAgICAgaWYgKHBvcnRNb2RlICYmIChxID09PSBERUZBVUxUX1BPUlRfUVVFUlkgfHwgL14w
;XHMqLVxzKjY1NTM1JC8udGVzdChxKSkpCiAgICAgICAgaGFuZGxlQmFubmVyLnRleHRDb250ZW50ID0gJ+WFqOmDqOi/nuaOpSc7
;CiAgICAgIGVsc2UKICAgICAgICBoYW5kbGVCYW5uZXIudGV4dENvbnRlbnQgPSAocG9ydE1vZGUgPyAn56uv5Y+jICcgOiAnJykg
;KyAn4oCcJyArIHEgKyAn4oCd55qE5pCc57Si57uT5p6cJzsKICAgIH0gZWxzZSB7CiAgICAgIGhhbmRsZUJhbm5lci5jbGFzc0xp
;c3QucmVtb3ZlKCdvbicpOwogICAgICBoYW5kbGVCYW5uZXIudGV4dENvbnRlbnQgPSAnJzsKICAgIH0KICAgIGlmIChoYW5kbGVC
;dXN5ICYmICFoYW5kbGVJdGVtcy5sZW5ndGgpIHsKICAgICAgc2hvd0hhbmRsZUxvYWRpbmcoZW1wdHlNc2cgfHwgKHBvcnRNb2Rl
;ID8gJ+ato+WcqOafpeivouerr+WPo+KApicgOiAn5q2j5Zyo5p+l6K+i5Y+l5p+E4oCmJykpOwogICAgICBzeW5jSGFuZGxlQmFy
;KDApOwogICAgICBzeW5jSGFuZGxlSGVhZFNvcnQoKTsKICAgICAgcmV0dXJuOwogICAgfQogICAgaWYgKHBvcnRNb2RlKSBoYW5k
;bGVJdGVtcyA9IGRlZHVwZVBvcnRJdGVtcyhoYW5kbGVJdGVtcyk7CiAgICBoYW5kbGVJdGVtcyA9IHNvcnRIYW5kbGVJdGVtcyho
;YW5kbGVJdGVtcyk7CiAgICBzeW5jSGFuZGxlSGVhZFNvcnQoKTsKICAgIGNvbnN0IG4gPSBoYW5kbGVJdGVtcy5sZW5ndGg7CiAg
;ICBzeW5jSGFuZGxlQmFyKG4pOwogICAgaWYgKCFuKSB7CiAgICAgIGhhbmRsZUJvZHkuaW5uZXJIVE1MID0gJzxkaXYgY2xhc3M9
;ImhhbmRsZS1lbXB0eSI+JyArIGVzY2FwZUh0bWwoZW1wdHlNc2cgfHwgKHBvcnRNb2RlID8gJ+ayoeacieWMuemFjeeahOerr+WP
;oycgOiAn5rKh5pyJ5Yy56YWN55qE5Y+l5p+EJykpICsgJzwvZGl2Pic7CiAgICAgIGhhbmRsZVNlbEtleXMuY2xlYXIoKTsKICAg
;ICAgaGFuZGxlQW5jaG9yS2V5ID0gJyc7CiAgICAgIHJldHVybjsKICAgIH0KICAgIGNvbnN0IGtlZXAgPSBuZXcgU2V0KCk7CiAg
;ICBjb25zdCBmcmFnID0gZG9jdW1lbnQuY3JlYXRlRG9jdW1lbnRGcmFnbWVudCgpOwogICAgZm9yIChsZXQgaSA9IDA7IGkgPCBo
;YW5kbGVJdGVtcy5sZW5ndGg7IGkrKykgewogICAgICBjb25zdCBpdCA9IGhhbmRsZUl0ZW1zW2ldOwogICAgICBjb25zdCByb3cg
;PSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsKICAgICAgY29uc3Qga2V5ID0gaGFuZGxlUm93S2V5KGl0LCBpKTsKICAg
;ICAga2VlcC5hZGQoa2V5KTsKICAgICAgcm93LmNsYXNzTmFtZSA9ICdoYW5kbGUtcm93IGhhbmRsZS1jb2xzJyArIChwb3J0TW9k
;ZSA/ICcgcG9ydC1tb2RlJyA6ICcnKSArIChoYW5kbGVTZWxLZXlzLmhhcyhrZXkpID8gJyBvbicgOiAnJyk7CiAgICAgIHJvdy5z
;ZXRBdHRyaWJ1dGUoJ2RhdGEta2V5Jywga2V5KTsKICAgICAgcm93LnNldEF0dHJpYnV0ZSgnZGF0YS1waWQnLCBTdHJpbmcoTnVt
;YmVyKGl0LnBpZCkgfHwgMCkpOwogICAgICByb3cuc2V0QXR0cmlidXRlKCdkYXRhLW5hbWUnLCBTdHJpbmcoaXQubmFtZSB8fCAn
;JykpOwogICAgICByb3cuc2V0QXR0cmlidXRlKCdkYXRhLXBhdGgnLCBTdHJpbmcoaXQucGF0aCB8fCAnJykpOwogICAgICBjb25z
;dCBuYW1lID0gU3RyaW5nKGl0Lm5hbWUgfHwgJycpOwogICAgICBjb25zdCBwaWROdW0gPSBOdW1iZXIoaXQucGlkKTsKICAgICAg
;Y29uc3QgcGlkID0gTnVtYmVyLmlzRmluaXRlKHBpZE51bSkgJiYgcGlkTnVtID4gMCA/IFN0cmluZyhwaWROdW0pIDogJyc7CiAg
;ICAgIGNvbnN0IHR5cCA9IFN0cmluZyhpdC50eXBlIHx8ICcnKTsKICAgICAgY29uc3QgaG5hbWUgPSBTdHJpbmcoaXQuaGFuZGxl
;IHx8ICcnKTsKICAgICAgY29uc3QgbHBvcnQgPSAoaXQubG9jYWxQb3J0ID09IG51bGwgfHwgTnVtYmVyKGl0LmxvY2FsUG9ydCkg
;PCAwKSA/ICcnIDogU3RyaW5nKGl0LmxvY2FsUG9ydCk7CiAgICAgIGNvbnN0IHJwb3J0TnVtID0gTnVtYmVyKGl0LnJlbW90ZVBv
;cnQpOwogICAgICBjb25zdCBycG9ydCA9IE51bWJlci5pc0Zpbml0ZShycG9ydE51bSkgJiYgcnBvcnROdW0gPiAwID8gU3RyaW5n
;KHJwb3J0TnVtKSA6IChwb3J0TW9kZSA/ICfigJQnIDogJycpOwogICAgICBjb25zdCB0aXAgPSBwb3J0TW9kZSA/IHBvcnRUaXBU
;ZXh0KGl0KSA6IChpdC5wYXRoIHx8IG5hbWUpOwogICAgICBjb25zdCBsSG90ID0gcG9ydE1vZGUgJiYgbHBvcnQgIT09ICcnICYm
;IHBvcnRJc0hvdChscG9ydCkgPyAnIHBvcnQtaG90JyA6ICcnOwogICAgICBjb25zdCBySG90ID0gcG9ydE1vZGUgJiYgcnBvcnQg
;IT09ICfigJQnICYmIHJwb3J0ICE9PSAnJyAmJiBwb3J0SXNIb3QocnBvcnQpID8gJyBwb3J0LWhvdCcgOiAnJzsKICAgICAgY29u
;c3QgY29ubmVjdGVkID0gcG9ydE1vZGUgJiYgKGhuYW1lID09PSAn6L+e5o6lJyB8fCAvZXN0YWJsaXNoZWQvaS50ZXN0KGhuYW1l
;KSk7CiAgICAgIGNvbnN0IG5ldERvdCA9IGNvbm5lY3RlZCA/ICc8c3BhbiBjbGFzcz0iaGFuZGxlLW5ldC1kb3QiIHRpdGxlPSLl
;t7Lov57mjqUiPjwvc3Bhbj4nIDogJyc7CiAgICAgIGNvbnN0IGljbyA9IGl0Lmljb24KICAgICAgICA/ICc8aW1nIHNyYz0iJyAr
;IGVzY2FwZUh0bWwoU3RyaW5nKGl0Lmljb24pKSArICciIGFsdD0iIiBvbmVycm9yPSJ0aGlzLm9uZXJyb3I9bnVsbDt0aGlzLnJl
;cGxhY2VXaXRoKE9iamVjdC5hc3NpZ24oZG9jdW1lbnQuY3JlYXRlRWxlbWVudChcJ3NwYW5cJykse2NsYXNzTmFtZTpcJ2hhbmRs
;ZS1pY28tcGhcJ30pKSI+JwogICAgICAgIDogJzxzcGFuIGNsYXNzPSJoYW5kbGUtaWNvLXBoIiBhcmlhLWhpZGRlbj0idHJ1ZSI+
;PC9zcGFuPic7CiAgICAgIHJvdy5pbm5lckhUTUwgPQogICAgICAgICc8ZGl2IGNsYXNzPSJoYW5kbGUtbmFtZSIgdGl0bGU9Iicg
;KyBlc2NhcGVIdG1sKGl0LnBhdGggfHwgbmFtZSkgKyAnIj4nICsgaWNvICsgJzxzcGFuPicgKyBlc2NhcGVIdG1sKG5hbWUpICsg
;Jzwvc3Bhbj48L2Rpdj4nCiAgICAgICAgKyAnPGRpdj4nICsgZXNjYXBlSHRtbChwaWQpICsgJzwvZGl2PicKICAgICAgICArIChw
;b3J0TW9kZQogICAgICAgICAgPyAoJzxkaXYgY2xhc3M9ImhhbmRsZS1jb2wtcG9ydCcgKyBsSG90ICsgJyIgdGl0bGU9IicgKyBl
;c2NhcGVIdG1sKHRpcCkgKyAnIj4nICsgZXNjYXBlSHRtbChscG9ydCkgKyAnPC9kaXY+JwogICAgICAgICAgICArICc8ZGl2IGNs
;YXNzPSJoYW5kbGUtY29sLXJwb3J0JyArIHJIb3QgKyAnIiB0aXRsZT0iJyArIGVzY2FwZUh0bWwodGlwKSArICciPicgKyBlc2Nh
;cGVIdG1sKHJwb3J0KSArICc8L2Rpdj4nKQogICAgICAgICAgOiAnJykKICAgICAgICArICc8ZGl2PicgKyBlc2NhcGVIdG1sKHR5
;cCkgKyAnPC9kaXY+JwogICAgICAgICsgJzxkaXYgY2xhc3M9ImhhbmRsZS1zdGF0ZSIgdGl0bGU9IicgKyBlc2NhcGVIdG1sKHBv
;cnRNb2RlID8gdGlwIDogaG5hbWUpICsgJyI+JyArIG5ldERvdCArICc8c3Bhbj4nICsgZXNjYXBlSHRtbChobmFtZSkgKyAnPC9z
;cGFuPjwvZGl2Pic7CiAgICAgIGlmIChwb3J0TW9kZSkgcm93LnRpdGxlID0gdGlwOwogICAgICByb3cub25jbGljayA9IChlKSA9
;PiBzZWxlY3RIYW5kbGVGcm9tRXZlbnQoZSwgcm93KTsKICAgICAgcm93Lm9uY29udGV4dG1lbnUgPSAoZSkgPT4gewogICAgICAg
;IGUucHJldmVudERlZmF1bHQoKTsKICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgICAgIGNvbnN0IGsgPSByb3cuZ2V0
;QXR0cmlidXRlKCdkYXRhLWtleScpOwogICAgICAgIGlmICghaGFuZGxlU2VsS2V5cy5oYXMoaykpIHsKICAgICAgICAgIGhhbmRs
;ZVNlbEtleXMuY2xlYXIoKTsKICAgICAgICAgIGhhbmRsZVNlbEtleXMuYWRkKGspOwogICAgICAgICAgaGFuZGxlQW5jaG9yS2V5
;ID0gazsKICAgICAgICAgIHJlZnJlc2hIYW5kbGVTZWxlY3Rpb25VSSgpOwogICAgICAgIH0KICAgICAgICBzaG93UHJvY01lbnUo
;ZS5jbGllbnRYLCBlLmNsaWVudFksIGNvbGxlY3RIYW5kbGVUYXJnZXRzKCkpOwogICAgICB9OwogICAgICByb3cub25kYmxjbGlj
;ayA9ICgpID0+IHsKICAgICAgICBjb25zdCB0ID0gcG9ydE1vZGUgPyB0aXAgOiAoaG5hbWUgfHwgbmFtZSk7CiAgICAgICAgdHJ5
;IHsgbmF2aWdhdG9yLmNsaXBib2FyZC53cml0ZVRleHQodCk7IH0gY2F0Y2ggKF8pIHsgcG9zdCgnY29weVRleHR8JyArIHQpOyB9
;CiAgICAgIH07CiAgICAgIGZyYWcuYXBwZW5kQ2hpbGQocm93KTsKICAgIH0KICAgIGZvciAoY29uc3QgayBvZiBBcnJheS5mcm9t
;KGhhbmRsZVNlbEtleXMpKSB7CiAgICAgIGlmICgha2VlcC5oYXMoaykpIGhhbmRsZVNlbEtleXMuZGVsZXRlKGspOwogICAgfQog
;ICAgaGFuZGxlQm9keS5pbm5lckhUTUwgPSAnJzsKICAgIGhhbmRsZUJvZHkuYXBwZW5kQ2hpbGQoZnJhZyk7CiAgfQogIGZ1bmN0
;aW9uIHN5bmNIYW5kbGVCYXIobikgewogICAgaWYgKGFwcE1vZGUgPT09ICdoYW5kbGUnKQogICAgICBjb3VudEVsLnRleHRDb250
;ZW50ID0gJ+WFsSAnICsgKE51bWJlcihuKSB8fCAwKSArICcg5p2hJzsKICB9CiAgZnVuY3Rpb24gaGFuZGxlUm93S2V5KGl0LCBp
;ZHgpIHsKICAgIHJldHVybiBbaXQucGlkLCBpdC50eXBlLCBpdC5oYW5kbGUsIGl0LmxvY2FsUG9ydCwgaXQucmVtb3RlUG9ydCwg
;aWR4XS5qb2luKCd8Jyk7CiAgfQogIGZ1bmN0aW9uIHJlZnJlc2hIYW5kbGVTZWxlY3Rpb25VSSgpIHsKICAgIGhhbmRsZUJvZHku
;cXVlcnlTZWxlY3RvckFsbCgnLmhhbmRsZS1yb3cnKS5mb3JFYWNoKHJvdyA9PiB7CiAgICAgIHJvdy5jbGFzc0xpc3QudG9nZ2xl
;KCdvbicsIGhhbmRsZVNlbEtleXMuaGFzKHJvdy5nZXRBdHRyaWJ1dGUoJ2RhdGEta2V5JykpKTsKICAgIH0pOwogIH0KICBmdW5j
;dGlvbiBzZWxlY3RIYW5kbGVGcm9tRXZlbnQoZSwgcm93KSB7CiAgICBjb25zdCBrZXkgPSByb3cuZ2V0QXR0cmlidXRlKCdkYXRh
;LWtleScpOwogICAgY29uc3Qgcm93cyA9IEFycmF5LmZyb20oaGFuZGxlQm9keS5xdWVyeVNlbGVjdG9yQWxsKCcuaGFuZGxlLXJv
;dycpKTsKICAgIGNvbnN0IGlkeCA9IHJvd3MuaW5kZXhPZihyb3cpOwogICAgaWYgKGUuc2hpZnRLZXkgJiYgaGFuZGxlQW5jaG9y
;S2V5KSB7CiAgICAgIGNvbnN0IGFJZHggPSByb3dzLmZpbmRJbmRleChyID0+IHIuZ2V0QXR0cmlidXRlKCdkYXRhLWtleScpID09
;PSBoYW5kbGVBbmNob3JLZXkpOwogICAgICBpZiAoYUlkeCA+PSAwICYmIGlkeCA+PSAwKSB7CiAgICAgICAgaWYgKCFlLmN0cmxL
;ZXkpIGhhbmRsZVNlbEtleXMuY2xlYXIoKTsKICAgICAgICBjb25zdCBsbyA9IE1hdGgubWluKGFJZHgsIGlkeCksIGhpID0gTWF0
;aC5tYXgoYUlkeCwgaWR4KTsKICAgICAgICBmb3IgKGxldCBpID0gbG87IGkgPD0gaGk7IGkrKykgaGFuZGxlU2VsS2V5cy5hZGQo
;cm93c1tpXS5nZXRBdHRyaWJ1dGUoJ2RhdGEta2V5JykpOwogICAgICB9CiAgICB9IGVsc2UgaWYgKGUuY3RybEtleSkgewogICAg
;ICBpZiAoaGFuZGxlU2VsS2V5cy5oYXMoa2V5KSkgaGFuZGxlU2VsS2V5cy5kZWxldGUoa2V5KTsKICAgICAgZWxzZSBoYW5kbGVT
;ZWxLZXlzLmFkZChrZXkpOwogICAgICBoYW5kbGVBbmNob3JLZXkgPSBrZXk7CiAgICB9IGVsc2UgewogICAgICBoYW5kbGVTZWxL
;ZXlzLmNsZWFyKCk7CiAgICAgIGhhbmRsZVNlbEtleXMuYWRkKGtleSk7CiAgICAgIGhhbmRsZUFuY2hvcktleSA9IGtleTsKICAg
;IH0KICAgIHJlZnJlc2hIYW5kbGVTZWxlY3Rpb25VSSgpOwogIH0KICBmdW5jdGlvbiBjb2xsZWN0SGFuZGxlVGFyZ2V0cygpIHsK
;ICAgIGNvbnN0IG1hcCA9IG5ldyBNYXAoKTsKICAgIGhhbmRsZUJvZHkucXVlcnlTZWxlY3RvckFsbCgnLmhhbmRsZS1yb3cnKS5m
;b3JFYWNoKHJvdyA9PiB7CiAgICAgIGlmICghaGFuZGxlU2VsS2V5cy5oYXMocm93LmdldEF0dHJpYnV0ZSgnZGF0YS1rZXknKSkp
;IHJldHVybjsKICAgICAgY29uc3QgcGlkID0gTnVtYmVyKHJvdy5nZXRBdHRyaWJ1dGUoJ2RhdGEtcGlkJykpIHx8IDA7CiAgICAg
;IGlmIChwaWQgPD0gMCB8fCBtYXAuaGFzKHBpZCkpIHJldHVybjsKICAgICAgbWFwLnNldChwaWQsIHsKICAgICAgICBwaWQsCiAg
;ICAgICAgbmFtZTogcm93LmdldEF0dHJpYnV0ZSgnZGF0YS1uYW1lJykgfHwgJycsCiAgICAgICAgcGF0aDogcm93LmdldEF0dHJp
;YnV0ZSgnZGF0YS1wYXRoJykgfHwgJycKICAgICAgfSk7CiAgICB9KTsKICAgIHJldHVybiBBcnJheS5mcm9tKG1hcC52YWx1ZXMo
;KSk7CiAgfQogIHdpbmRvdy5fX29uSG9zdEhpZGUgPSAoKSA9PiB7IHBvc3QoJ3Byb2NWaWV3fDAnKTsgfTsKICB3aW5kb3cuX19v
;bkhvc3RTaG93ID0gKCkgPT4gewogICAgdHJ5IHsgaWYgKHdpbmRvdy5fX3Jlc3luY1NlYXJjaCkgd2luZG93Ll9fcmVzeW5jU2Vh
;cmNoKCk7IH0gY2F0Y2ggKF8pIHt9CiAgfTsKICBkb2N1bWVudC5hZGRFdmVudExpc3RlbmVyKCd2aXNpYmlsaXR5Y2hhbmdlJywg
;KCkgPT4gewogICAgaWYgKGRvY3VtZW50LmhpZGRlbikgcG9zdCgncHJvY1ZpZXd8MCcpOwogIH0pOwoKICBpZiAoZG9jdW1lbnQu
;Z2V0RWxlbWVudEJ5SWQoJ2J0bi1pbmZvLXJlZnJlc2gnKSkKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdidG4taW5mby1y
;ZWZyZXNoJykub25jbGljayA9ICgpID0+IHJlcXVlc3RTeXNJbmZvKHRydWUpOwogIGlmIChkb2N1bWVudC5nZXRFbGVtZW50QnlJ
;ZCgnYnRuLWluZm8tY29weScpKQogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2J0bi1pbmZvLWNvcHknKS5vbmNsaWNrID0g
;KCkgPT4gewogICAgICBjb25zdCB0ID0gaW5mb1RleHQgfHwgKGluZm9QYW5lbCAmJiBpbmZvUGFuZWwuaW5uZXJUZXh0KSB8fCAn
;JzsKICAgICAgdHJ5IHsgbmF2aWdhdG9yLmNsaXBib2FyZC53cml0ZVRleHQodCk7IH0gY2F0Y2ggKF8pIHsgcG9zdCgnY29weVRl
;eHR8JyArIHQpOyB9CiAgICB9OwogIGlmIChidG5Qb3J0TWFyaykgewogICAgYnRuUG9ydE1hcmsub25jbGljayA9IChlKSA9PiB7
;CiAgICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAgIGlmIChwb3J0TWFya1BvcCAmJiBwb3J0TWFya1BvcC5jbGFzc0xpc3Qu
;Y29udGFpbnMoJ29uJykpIGNsb3NlUG9ydE1hcmtQb3AoKTsKICAgICAgZWxzZSBvcGVuUG9ydE1hcmtQb3AoKTsKICAgIH07CiAg
;fQogIGlmIChwb3J0TWFya1BvcCkgcG9ydE1hcmtQb3AuYWRkRXZlbnRMaXN0ZW5lcignY2xpY2snLCBlID0+IGUuc3RvcFByb3Bh
;Z2F0aW9uKCkpOwogIGNvbnN0IGJ0blBvcnRNYXJrQWRkID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3BvcnQtbWFyay1hZGQn
;KTsKICBjb25zdCBidG5Qb3J0TWFya1Jlc2V0ID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3BvcnQtbWFyay1yZXNldCcpOwog
;IGlmIChidG5Qb3J0TWFya0FkZCkgewogICAgYnRuUG9ydE1hcmtBZGQub25jbGljayA9IChlKSA9PiB7CiAgICAgIGUuc3RvcFBy
;b3BhZ2F0aW9uKCk7CiAgICAgIGlmIChhZGRNYXJrZWRQb3J0KHBvcnRNYXJrSW5wdXQgJiYgcG9ydE1hcmtJbnB1dC52YWx1ZSkp
;IHsKICAgICAgICBpZiAocG9ydE1hcmtJbnB1dCkgcG9ydE1hcmtJbnB1dC52YWx1ZSA9ICcnOwogICAgICB9CiAgICB9OwogIH0K
;ICBpZiAocG9ydE1hcmtJbnB1dCkgewogICAgcG9ydE1hcmtJbnB1dC5hZGRFdmVudExpc3RlbmVyKCdrZXlkb3duJywgZSA9PiB7
;CiAgICAgIGlmIChlLmtleSA9PT0gJ0VudGVyJykgewogICAgICAgIGUucHJldmVudERlZmF1bHQoKTsKICAgICAgICBpZiAoYWRk
;TWFya2VkUG9ydChwb3J0TWFya0lucHV0LnZhbHVlKSkgcG9ydE1hcmtJbnB1dC52YWx1ZSA9ICcnOwogICAgICB9CiAgICB9KTsK
;ICB9CiAgaWYgKGJ0blBvcnRNYXJrUmVzZXQpIHsKICAgIGJ0blBvcnRNYXJrUmVzZXQub25jbGljayA9IChlKSA9PiB7CiAgICAg
;IGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAgIG1hcmtlZFBvcnRzID0gREVGQVVMVF9NQVJLRURfUE9SVFMuc2xpY2UoKTsKICAg
;ICAgc2F2ZU1hcmtlZFBvcnRzKCk7CiAgICAgIHJlbmRlck1hcmtlZFBvcnRUYWdzKCk7CiAgICAgIGlmIChhcHBNb2RlID09PSAn
;aGFuZGxlJyAmJiBoYW5kbGVNb2RlID09PSAncG9ydCcpIHJlbmRlckhhbmRsZVRhYmxlKCk7CiAgICB9OwogIH0KICBkb2N1bWVu
;dC5hZGRFdmVudExpc3RlbmVyKCdjbGljaycsICgpID0+IGNsb3NlUG9ydE1hcmtQb3AoKSk7CiAgcmVuZGVyTWFya2VkUG9ydFRh
;Z3MoKTsKICByZW5kZXJIYW5kbGVIaXN0KCk7CiAgLy8g5Li75pCc57Si5qGG57uf5LiA5pCc57Si77yb5Y+l5p+E5Y6G5Y+y6LWw
;IOKWviDkuIvmi4nvvIjkuI7mlofku7bmkJzntKLkuIDoh7TvvIkKICB0cnkgeyBxRWwucmVtb3ZlQXR0cmlidXRlKCdsaXN0Jyk7
;IH0gY2F0Y2ggKF8pIHt9CgogIGZ1bmN0aW9uIGhpZGVQcm9jTWVudSgpIHsKICAgIHByb2NNZW51LmNsYXNzTGlzdC5yZW1vdmUo
;J29uJyk7CiAgICBwcm9jTWVudVRhcmdldHMgPSBbXTsKICB9CiAgZnVuY3Rpb24gc2hvd1Byb2NNZW51KHgsIHksIHRhcmdldHMp
;IHsKICAgIHByb2NNZW51VGFyZ2V0cyA9IEFycmF5LmlzQXJyYXkodGFyZ2V0cykgPyB0YXJnZXRzLmZpbHRlcih0ID0+IHQgJiYg
;TnVtYmVyKHQucGlkKSA+IDApIDogW107CiAgICBjb25zdCBuID0gcHJvY01lbnVUYXJnZXRzLmxlbmd0aDsKICAgIGNvbnN0IGZp
;cnN0ID0gbiA/IHByb2NNZW51VGFyZ2V0c1swXSA6IG51bGw7CiAgICBjb25zdCBuYW1lID0gZmlyc3QgPyBTdHJpbmcoZmlyc3Qu
;bmFtZSB8fCAnJykudHJpbSgpIDogJyc7CiAgICBjb25zdCBwaWQgPSBmaXJzdCA/IFN0cmluZyhOdW1iZXIoZmlyc3QucGlkKSB8
;fCAnJykgOiAnJzsKICAgIGNvbnN0IGNvcHlMYmwgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgncHJvYy1tZW51LWNvcHknKTsK
;ICAgIGNvbnN0IHBpZExibCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdwcm9jLW1lbnUtY29weXBpZCcpOwogICAgY29uc3Qg
;ZW5kTGJsID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3Byb2MtbWVudS1lbmQtbGFiZWwnKTsKICAgIGlmIChjb3B5TGJsKSB7
;CiAgICAgIGlmIChuYW1lICYmIG4gPT09IDEpIGNvcHlMYmwudGV4dENvbnRlbnQgPSAn5aSN5Yi26L+b56iL5ZCNICggJyArIG5h
;bWUgKyAnICknOwogICAgICBlbHNlIGlmIChuYW1lICYmIG4gPiAxKSBjb3B5TGJsLnRleHRDb250ZW50ID0gJ+WkjeWItui/m+eo
;i+WQjSAoICcgKyBuYW1lICsgJyDnrYknICsgbiArICfkuKogKSc7CiAgICAgIGVsc2UgY29weUxibC50ZXh0Q29udGVudCA9ICfl
;pI3liLbov5vnqIvlkI0nOwogICAgfQogICAgaWYgKHBpZExibCkgewogICAgICBpZiAocGlkICYmIG4gPT09IDEpIHBpZExibC50
;ZXh0Q29udGVudCA9ICflpI3liLbov5vnqIvlj7cgKCAnICsgcGlkICsgJyApJzsKICAgICAgZWxzZSBpZiAocGlkICYmIG4gPiAx
;KSBwaWRMYmwudGV4dENvbnRlbnQgPSAn5aSN5Yi26L+b56iL5Y+3ICggJyArIHBpZCArICcg562JJyArIG4gKyAn5LiqICknOwog
;ICAgICBlbHNlIHBpZExibC50ZXh0Q29udGVudCA9ICflpI3liLbov5vnqIvlj7cnOwogICAgfQogICAgaWYgKGVuZExibCkgZW5k
;TGJsLnRleHRDb250ZW50ID0gJ+WFs+mXrei/m+eoiyAoICcgKyBNYXRoLm1heChuLCAwKSArICcgKSc7CiAgICBjb25zdCBoYXNQ
;YXRoID0gcHJvY01lbnVUYXJnZXRzLnNvbWUodCA9PiB0LnBhdGgpOwogICAgcHJvY01lbnUucXVlcnlTZWxlY3RvckFsbCgnYnV0
;dG9uW2RhdGEtcGFjdF0nKS5mb3JFYWNoKGJ0biA9PiB7CiAgICAgIGNvbnN0IGFjdCA9IGJ0bi5nZXRBdHRyaWJ1dGUoJ2RhdGEt
;cGFjdCcpOwogICAgICBpZiAoYWN0ID09PSAncmV2ZWFsJykgYnRuLmRpc2FibGVkID0gIWhhc1BhdGg7CiAgICAgIGVsc2UgYnRu
;LmRpc2FibGVkID0gbiA8IDE7CiAgICB9KTsKICAgIHByb2NNZW51LmNsYXNzTGlzdC5hZGQoJ29uJyk7CiAgICBwcm9jTWVudS5z
;dHlsZS5sZWZ0ID0gJzBweCc7CiAgICBwcm9jTWVudS5zdHlsZS50b3AgPSAnMHB4JzsKICAgIGNvbnN0IHJlY3QgPSBwcm9jTWVu
;dS5nZXRCb3VuZGluZ0NsaWVudFJlY3QoKTsKICAgIGxldCBsZWZ0ID0geCwgdG9wID0geTsKICAgIGlmIChsZWZ0ICsgcmVjdC53
;aWR0aCA+IGlubmVyV2lkdGggLSA2KSBsZWZ0ID0gTWF0aC5tYXgoNiwgaW5uZXJXaWR0aCAtIHJlY3Qud2lkdGggLSA2KTsKICAg
;IGlmICh0b3AgKyByZWN0LmhlaWdodCA+IGlubmVySGVpZ2h0IC0gNikgdG9wID0gTWF0aC5tYXgoNiwgaW5uZXJIZWlnaHQgLSBy
;ZWN0LmhlaWdodCAtIDYpOwogICAgcHJvY01lbnUuc3R5bGUubGVmdCA9IGxlZnQgKyAncHgnOwogICAgcHJvY01lbnUuc3R5bGUu
;dG9wID0gdG9wICsgJ3B4JzsKICB9CiAgZnVuY3Rpb24gY29weVRleHRTYWZlKHRleHQpIHsKICAgIHRleHQgPSBTdHJpbmcodGV4
;dCB8fCAnJyk7CiAgICBpZiAoIXRleHQpIHJldHVybjsKICAgIHRyeSB7IG5hdmlnYXRvci5jbGlwYm9hcmQud3JpdGVUZXh0KHRl
;eHQpOyB9IGNhdGNoIChfKSB7IHBvc3QoJ2NvcHlUZXh0fCcgKyB0ZXh0KTsgfQogIH0KICBwcm9jTWVudS5xdWVyeVNlbGVjdG9y
;QWxsKCdidXR0b25bZGF0YS1wYWN0XScpLmZvckVhY2goYnRuID0+IHsKICAgIGJ0bi5vbmNsaWNrID0gKGUpID0+IHsKICAgICAg
;ZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgY29uc3QgYWN0ID0gYnRuLmdldEF0dHJpYnV0ZSgnZGF0YS1wYWN0Jyk7CiAgICAg
;IGNvbnN0IHRhcmdldHMgPSBwcm9jTWVudVRhcmdldHMuc2xpY2UoKTsKICAgICAgaGlkZVByb2NNZW51KCk7CiAgICAgIGlmICgh
;dGFyZ2V0cy5sZW5ndGgpIHJldHVybjsKICAgICAgaWYgKGFjdCA9PT0gJ2VuZCcpIHsKICAgICAgICBjb25zdCBwaWRzID0gdGFy
;Z2V0cy5tYXAodCA9PiBOdW1iZXIodC5waWQpIHx8IDApLmZpbHRlcihwaWQgPT4gcGlkID4gMCk7CiAgICAgICAgaWYgKHBpZHMu
;bGVuZ3RoKSB7CiAgICAgICAgICAvLyDlhYjku47nlYzpnaLnp7vpmaTvvIzkuLvmnLrnoa7orqTlkI7kvJrlho3lkIzmraXkuIDm
;rKEKICAgICAgICAgIHJlbW92ZVJvd3NCeVBpZHMocGlkcyk7CiAgICAgICAgICBwb3N0KCdwcm9jS2lsbHwnICsgcGlkcy5qb2lu
;KCcsJykpOwogICAgICAgIH0KICAgICAgfSBlbHNlIGlmIChhY3QgPT09ICdyZXZlYWwnKSB7CiAgICAgICAgY29uc3Qgc2VlbiA9
;IG5ldyBTZXQoKTsKICAgICAgICBmb3IgKGNvbnN0IHQgb2YgdGFyZ2V0cykgewogICAgICAgICAgY29uc3QgcCA9IFN0cmluZyh0
;LnBhdGggfHwgJycpOwogICAgICAgICAgaWYgKCFwIHx8IHNlZW4uaGFzKHAudG9Mb3dlckNhc2UoKSkpIGNvbnRpbnVlOwogICAg
;ICAgICAgc2Vlbi5hZGQocC50b0xvd2VyQ2FzZSgpKTsKICAgICAgICAgIGNhbGxIb3N0KCdyZXZlYWwnLCBwKTsKICAgICAgICB9
;CiAgICAgIH0gZWxzZSBpZiAoYWN0ID09PSAnY29weScpIHsKICAgICAgICBjb25zdCBuYW1lcyA9IFtdOwogICAgICAgIGNvbnN0
;IHNlZW4gPSBuZXcgU2V0KCk7CiAgICAgICAgZm9yIChjb25zdCB0IG9mIHRhcmdldHMpIHsKICAgICAgICAgIGxldCBuID0gU3Ry
;aW5nKHQubmFtZSB8fCAnJykudHJpbSgpOwogICAgICAgICAgaWYgKCFuICYmIHQucGF0aCkgewogICAgICAgICAgICBjb25zdCBw
;ID0gU3RyaW5nKHQucGF0aCkucmVwbGFjZSgvW1xcL10rJC8sICcnKTsKICAgICAgICAgICAgY29uc3QgaSA9IE1hdGgubWF4KHAu
;bGFzdEluZGV4T2YoJ1xcJyksIHAubGFzdEluZGV4T2YoJy8nKSk7CiAgICAgICAgICAgIG4gPSBpID49IDAgPyBwLnNsaWNlKGkg
;KyAxKSA6IHA7CiAgICAgICAgICB9CiAgICAgICAgICBpZiAoIW4gfHwgc2Vlbi5oYXMobi50b0xvd2VyQ2FzZSgpKSkgY29udGlu
;dWU7CiAgICAgICAgICBzZWVuLmFkZChuLnRvTG93ZXJDYXNlKCkpOwogICAgICAgICAgbmFtZXMucHVzaChuKTsKICAgICAgICB9
;CiAgICAgICAgY29weVRleHRTYWZlKG5hbWVzLmpvaW4oJ1xuJykpOwogICAgICB9IGVsc2UgaWYgKGFjdCA9PT0gJ2NvcHlQaWQn
;KSB7CiAgICAgICAgY29uc3QgcGlkcyA9IFtdOwogICAgICAgIGNvbnN0IHNlZW4gPSBuZXcgU2V0KCk7CiAgICAgICAgZm9yIChj
;b25zdCB0IG9mIHRhcmdldHMpIHsKICAgICAgICAgIGNvbnN0IHBpZCA9IE51bWJlcih0LnBpZCkgfHwgMDsKICAgICAgICAgIGlm
;IChwaWQgPD0gMCB8fCBzZWVuLmhhcyhwaWQpKSBjb250aW51ZTsKICAgICAgICAgIHNlZW4uYWRkKHBpZCk7CiAgICAgICAgICBw
;aWRzLnB1c2goU3RyaW5nKHBpZCkpOwogICAgICAgIH0KICAgICAgICBjb3B5VGV4dFNhZmUocGlkcy5qb2luKCdcbicpKTsKICAg
;ICAgfQogICAgfTsKICB9KTsKICBkb2N1bWVudC5hZGRFdmVudExpc3RlbmVyKCdjbGljaycsICgpID0+IGhpZGVQcm9jTWVudSgp
;KTsKICBkb2N1bWVudC5hZGRFdmVudExpc3RlbmVyKCdrZXlkb3duJywgKGUpID0+IHsKICAgIGlmIChlLmtleSA9PT0gJ0VzY2Fw
;ZScpIHsKICAgICAgaGlkZVByb2NNZW51KCk7CiAgICAgIGNsb3NlUG9ydE1hcmtQb3AoKTsKICAgIH0KICB9KTsKCiAgZnVuY3Rp
;b24gcHJvY1Jvd0tleShwKSB7CiAgICByZXR1cm4gW3AucHJvdG8sIHAubG9jYWxJcCwgcC5sb2NhbFBvcnQsIHAucmVtb3RlSXAs
;IHAucmVtb3RlUG9ydCwgcC5waWRdLmpvaW4oJ3wnKTsKICB9CiAgZnVuY3Rpb24gcG9ydHNDb250ZW50U2lnKGl0ZW1zKSB7CiAg
;ICByZXR1cm4gKGl0ZW1zIHx8IFtdKS5tYXAocCA9PgogICAgICBwcm9jUm93S2V5KHApICsgJ1x0JyArIChwLnByb2MgfHwgJycp
;ICsgJ1x0JyArIChwLnN0YXRlIHx8ICcnKSArICdcdCcgKyAocC5wYXRoIHx8ICcnKQogICAgICAgICsgJ1x0JyArIChwLnBwaWQg
;fHwgJycpICsgJ1x0JyArIChwLmNwdSB8fCAnJykgKyAnXHQnICsgKHAubWVtIHx8ICcnKQogICAgKS5qb2luKCdcbicpOwogIH0K
;ICBmdW5jdGlvbiBwb3J0Q2VsbFRleHQocG9ydCkgewogICAgaWYgKHBvcnQgPT09ICcnIHx8IHBvcnQgPT0gbnVsbCB8fCBOdW1i
;ZXIocG9ydCkgPCAwKSByZXR1cm4gJyc7CiAgICByZXR1cm4gU3RyaW5nKHBvcnQpOwogIH0KICBmdW5jdGlvbiBwcm9jSWNvblN0
;YWJsZUtleShwKSB7CiAgICBjb25zdCBwYXRoID0gU3RyaW5nKChwICYmIHAucGF0aCkgfHwgJycpOwogICAgaWYgKHBhdGgpIHJl
;dHVybiAncDonICsgcGF0aC50b0xvd2VyQ2FzZSgpOwogICAgcmV0dXJuICdpZDonICsgKE51bWJlcihwICYmIHAucGlkKSB8fCAw
;KTsKICB9CiAgZnVuY3Rpb24gc2V0UHJvY0ljb25FbChuYW1lQm94LCBpY29uVXJsLCBzdGFibGVLZXkpIHsKICAgIGlmICghbmFt
;ZUJveCkgcmV0dXJuOwogICAgbGV0IGltZyA9IG5hbWVCb3gucXVlcnlTZWxlY3RvcignaW1nJyk7CiAgICBsZXQgcGggPSBuYW1l
;Qm94LnF1ZXJ5U2VsZWN0b3IoJy5wcm9jLWljby1waCcpOwogICAgY29uc3QgdXJsID0gU3RyaW5nKGljb25VcmwgfHwgJycpOwog
;ICAgLy8g5bey5pyJ56iz5a6a5Zu+5qCH77ya56m6L+WQjCBzcmMg6YO95LiN5Yqo77yM5p2c57ud6Zeq54OBCiAgICBpZiAoaW1n
;KSB7CiAgICAgIGNvbnN0IGN1ciA9IGltZy5nZXRBdHRyaWJ1dGUoJ3NyYycpIHx8ICcnOwogICAgICBpZiAoIXVybCB8fCB1cmwg
;PT09IGN1cikgcmV0dXJuOwogICAgICBpbWcuc2V0QXR0cmlidXRlKCdzcmMnLCB1cmwpOwogICAgICBpZiAoc3RhYmxlS2V5KSBw
;cm9jSWNvblN0YWJsZS5zZXQoc3RhYmxlS2V5LCB1cmwpOwogICAgICByZXR1cm47CiAgICB9CiAgICBpZiAoIXVybCkgewogICAg
;ICBpZiAoIXBoKSB7CiAgICAgICAgcGggPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdzcGFuJyk7CiAgICAgICAgcGguY2xhc3NO
;YW1lID0gJ3Byb2MtaWNvLXBoJzsKICAgICAgICBwaC5zZXRBdHRyaWJ1dGUoJ2FyaWEtaGlkZGVuJywgJ3RydWUnKTsKICAgICAg
;ICBuYW1lQm94Lmluc2VydEJlZm9yZShwaCwgbmFtZUJveC5maXJzdENoaWxkKTsKICAgICAgfQogICAgICByZXR1cm47CiAgICB9
;CiAgICBpbWcgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdpbWcnKTsKICAgIGltZy5hbHQgPSAnJzsKICAgIGltZy5kZWNvZGlu
;ZyA9ICdhc3luYyc7CiAgICBpbWcuc3JjID0gdXJsOwogICAgaW1nLm9uZXJyb3IgPSBmdW5jdGlvbiAoKSB7CiAgICAgIHRoaXMu
;b25lcnJvciA9IG51bGw7CiAgICAgIGNvbnN0IHMgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdzcGFuJyk7CiAgICAgIHMuY2xh
;c3NOYW1lID0gJ3Byb2MtaWNvLXBoJzsKICAgICAgcy5zZXRBdHRyaWJ1dGUoJ2FyaWEtaGlkZGVuJywgJ3RydWUnKTsKICAgICAg
;dGhpcy5yZXBsYWNlV2l0aChzKTsKICAgIH07CiAgICBpZiAocGgpIG5hbWVCb3gucmVwbGFjZUNoaWxkKGltZywgcGgpOwogICAg
;ZWxzZSBuYW1lQm94Lmluc2VydEJlZm9yZShpbWcsIG5hbWVCb3guZmlyc3RDaGlsZCk7CiAgICBpZiAoc3RhYmxlS2V5KSBwcm9j
;SWNvblN0YWJsZS5zZXQoc3RhYmxlS2V5LCB1cmwpOwogIH0KICBmdW5jdGlvbiBlbnN1cmVQcm9jUm93KHApIHsKICAgIGNvbnN0
;IHJvdyA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOwogICAgcm93LmNsYXNzTmFtZSA9ICdwcm9jLXJvdyBwcm9jLWNv
;bHMnOwogICAgcm93LmlubmVySFRNTCA9CiAgICAgICc8ZGl2IGNsYXNzPSJwcm9jLWNlbGwtbmFtZSI+PGRpdiBjbGFzcz0icHJv
;Yy1uYW1lIj48c3BhbiBjbGFzcz0icHJvYy1pY28tcGgiIGFyaWEtaGlkZGVuPSJ0cnVlIj48L3NwYW4+PHNwYW4gY2xhc3M9InBy
;b2MtbGFiZWwiPjwvc3Bhbj48L2Rpdj48L2Rpdj4nCiAgICAgICsgJzxkaXYgY2xhc3M9InByb2MtbnVtIHByb2MtY2VsbC1jcHUi
;IGRhdGEtZj0iY3B1Ij48L2Rpdj4nCiAgICAgICsgJzxkaXYgY2xhc3M9InByb2MtbnVtIHByb2MtY2VsbC1tZW0iIGRhdGEtZj0i
;bWVtIj48L2Rpdj4nCiAgICAgICsgJzxkaXYgY2xhc3M9InByb2MtbnVtIHByb2MtY2VsbC1waWQiIGRhdGEtZj0icGlkIj48L2Rp
;dj4nCiAgICAgICsgJzxkaXYgY2xhc3M9InByb2MtbnVtIHByb2MtY2VsbC1wcm90byIgZGF0YS1mPSJwcm90byI+PC9kaXY+Jwog
;ICAgICArICc8ZGl2IGNsYXNzPSJwcm9jLW51bSBwcm9jLWNlbGwtaXAiIGRhdGEtZj0ibGlwIj48L2Rpdj4nCiAgICAgICsgJzxk
;aXYgY2xhc3M9InByb2MtbnVtIHByb2MtY2VsbC1wb3J0IiBkYXRhLWY9Imxwb3J0Ij48L2Rpdj4nCiAgICAgICsgJzxkaXYgY2xh
;c3M9InByb2MtbnVtIHByb2MtY2VsbC1pcCIgZGF0YS1mPSJyaXAiPjwvZGl2PicKICAgICAgKyAnPGRpdiBjbGFzcz0icHJvYy1u
;dW0gcHJvYy1jZWxsLXBvcnQiIGRhdGEtZj0icnBvcnQiPjwvZGl2PicKICAgICAgKyAnPGRpdiBjbGFzcz0icHJvYy1udW0gcHJv
;Yy1jZWxsLXN0YXRlIiBkYXRhLWY9InN0YXRlIj48c3BhbiBjbGFzcz0icHJvYy1uZXQtZG90IGhpZGRlbiIgdGl0bGU9IuW3sui/
;nuaOpSI+PC9zcGFuPjxzcGFuIGNsYXNzPSJwcm9jLXN0YXRlLXR4dCI+PC9zcGFuPjwvZGl2Pic7CiAgICByb3cub25jbGljayA9
;IChlKSA9PiBzZWxlY3RQcm9jRnJvbUV2ZW50KGUsIHJvdyk7CiAgICByb3cub25jb250ZXh0bWVudSA9IChlKSA9PiB7CiAgICAg
;IGUucHJldmVudERlZmF1bHQoKTsKICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgY29uc3Qga2V5ID0gcm93LmdldEF0
;dHJpYnV0ZSgnZGF0YS1rZXknKTsKICAgICAgaWYgKCFwcm9jU2VsS2V5cy5oYXMoa2V5KSkgewogICAgICAgIHNlbGVjdFByb2NO
;YW1lR3JvdXAocm93KTsKICAgICAgfQogICAgICBzaG93UHJvY01lbnUoZS5jbGllbnRYLCBlLmNsaWVudFksIGNvbGxlY3RQcm9j
;VGFyZ2V0cygpKTsKICAgIH07CiAgICByZXR1cm4gcm93OwogIH0KICBmdW5jdGlvbiBoZWF0Q29sb3IoaG90KSB7CiAgICByZXR1
;cm4gaG90ID8gJyM4OGZmYzEnIDogJyNjZWZmZTUnOwogIH0KICBmdW5jdGlvbiBwYXJzZVBjdChzKSB7CiAgICBjb25zdCBtID0g
;U3RyaW5nKHMgfHwgJycpLm1hdGNoKC8oW1xkLl0rKS8pOwogICAgcmV0dXJuIG0gPyBOdW1iZXIobVsxXSkgOiAwOwogIH0KICBm
;dW5jdGlvbiB1cGRhdGVIZWFkSGVhdChjcHVUb3RhbCwgbWVtVG90YWwpIHsKICAgIGNvbnN0IGNwdUNlbGwgPSBwcm9jSGVhZCAm
;JiBwcm9jSGVhZC5xdWVyeVNlbGVjdG9yKCcucHJvYy1oY2VsbFtkYXRhLXNvcnQ9ImNwdSJdJyk7CiAgICBjb25zdCBtZW1DZWxs
;ID0gcHJvY0hlYWQgJiYgcHJvY0hlYWQucXVlcnlTZWxlY3RvcignLnByb2MtaGNlbGxbZGF0YS1zb3J0PSJtZW0iXScpOwogICAg
;Y29uc3QgY3B1UGN0ID0gcGFyc2VQY3QoY3B1VG90YWwpOwogICAgY29uc3QgbWVtUGN0ID0gcGFyc2VQY3QobWVtVG90YWwpOwog
;ICAgaWYgKGNwdUNlbGwpIHsKICAgICAgY3B1Q2VsbC5jbGFzc0xpc3QudG9nZ2xlKCdob3QnLCBjcHVQY3QgPiA1KTsKICAgICAg
;Y3B1Q2VsbC5zdHlsZS5iYWNrZ3JvdW5kID0gaGVhdENvbG9yKGNwdVBjdCA+IDUpOwogICAgfQogICAgaWYgKG1lbUNlbGwpIHsK
;ICAgICAgbWVtQ2VsbC5jbGFzc0xpc3QudG9nZ2xlKCdob3QnLCBtZW1QY3QgPiA4MCk7CiAgICAgIG1lbUNlbGwuc3R5bGUuYmFj
;a2dyb3VuZCA9IGhlYXRDb2xvcihtZW1QY3QgPiA4MCk7CiAgICB9CiAgfQogIGZ1bmN0aW9uIHVwZGF0ZVByb2NSb3dEYXRhKHJv
;dywgcCkgewogICAgY29uc3Qga2V5ID0gcHJvY1Jvd0tleShwKTsKICAgIHJvdy5zZXRBdHRyaWJ1dGUoJ2RhdGEta2V5Jywga2V5
;KTsKICAgIHJvdy5zZXRBdHRyaWJ1dGUoJ2RhdGEtcGlkJywgU3RyaW5nKHAucGlkIHx8IDApKTsKICAgIHJvdy5zZXRBdHRyaWJ1
;dGUoJ2RhdGEtbmFtZScsIFN0cmluZyhwLnByb2MgfHwgJycpKTsKICAgIHJvdy5zZXRBdHRyaWJ1dGUoJ2RhdGEtcGF0aCcsIFN0
;cmluZyhwLnBhdGggfHwgJycpKTsKICAgIGNvbnN0IG5hbWVCb3ggPSByb3cucXVlcnlTZWxlY3RvcignLnByb2MtbmFtZScpOwog
;ICAgY29uc3QgbGFiZWwgPSByb3cucXVlcnlTZWxlY3RvcignLnByb2MtbGFiZWwnKTsKICAgIGNvbnN0IG5hbWUgPSBwLnByb2Mg
;fHwgKHAucGlkID8gKCdQSUQgJyArIHAucGlkKSA6ICcnKTsKICAgIGlmIChsYWJlbCAmJiBsYWJlbC50ZXh0Q29udGVudCAhPT0g
;bmFtZSkgbGFiZWwudGV4dENvbnRlbnQgPSBuYW1lOwogICAgaWYgKGxhYmVsKSBsYWJlbC50aXRsZSA9IHAucGF0aCB8fCBuYW1l
;OwogICAgY29uc3Qgc2sgPSBwcm9jSWNvblN0YWJsZUtleShwKTsKICAgIGxldCBpY29uID0gU3RyaW5nKHAuaWNvbiB8fCAnJyk7
;CiAgICBpZiAoIWljb24gJiYgcHJvY0ljb25TdGFibGUuaGFzKHNrKSkKICAgICAgaWNvbiA9IHByb2NJY29uU3RhYmxlLmdldChz
;ayk7CiAgICBzZXRQcm9jSWNvbkVsKG5hbWVCb3gsIGljb24sIHNrKTsKICAgIGNvbnN0IHNldFR4dCA9IChzZWwsIHZhbCwgdGl0
;bGUpID0+IHsKICAgICAgY29uc3QgZWwgPSByb3cucXVlcnlTZWxlY3RvcihzZWwpOwogICAgICBpZiAoIWVsKSByZXR1cm47CiAg
;ICAgIGNvbnN0IHQgPSB2YWwgPT0gbnVsbCA/ICcnIDogU3RyaW5nKHZhbCk7CiAgICAgIGlmIChlbC50ZXh0Q29udGVudCAhPT0g
;dCkgZWwudGV4dENvbnRlbnQgPSB0OwogICAgICBpZiAodGl0bGUgIT0gbnVsbCkgZWwudGl0bGUgPSB0aXRsZTsKICAgIH07CiAg
;ICBzZXRUeHQoJ1tkYXRhLWY9ImNwdSJdJywgcC5jcHUgfHwgJzAlJyk7CiAgICBzZXRUeHQoJ1tkYXRhLWY9Im1lbSJdJywgcC5t
;ZW0gfHwgJycpOwogICAgc2V0VHh0KCdbZGF0YS1mPSJwaWQiXScsIHAucGlkIHx8ICcnKTsKICAgIHNldFR4dCgnW2RhdGEtZj0i
;cHJvdG8iXScsIHAucHJvdG8gfHwgJycpOwogICAgc2V0VHh0KCdbZGF0YS1mPSJsaXAiXScsIHAubG9jYWxJcCB8fCAnJywgcC5s
;b2NhbElwIHx8ICcnKTsKICAgIGNvbnN0IGxwb3J0ID0gcG9ydENlbGxUZXh0KHAubG9jYWxQb3J0KTsKICAgIHNldFR4dCgnW2Rh
;dGEtZj0ibHBvcnQiXScsIGxwb3J0KTsKICAgIGNvbnN0IGxwb3J0RWwgPSByb3cucXVlcnlTZWxlY3RvcignW2RhdGEtZj0ibHBv
;cnQiXScpOwogICAgaWYgKGxwb3J0RWwpIGxwb3J0RWwuY2xhc3NMaXN0LnRvZ2dsZSgncG9ydC1ob3QnLCBwb3J0SXNIb3QocC5s
;b2NhbFBvcnQpICYmIGxwb3J0ICE9PSAnJyk7CiAgICBzZXRUeHQoJ1tkYXRhLWY9InJpcCJdJywgcC5yZW1vdGVJcCB8fCAnJywg
;cC5yZW1vdGVJcCB8fCAnJyk7CiAgICBjb25zdCBycG9ydCA9IHBvcnRDZWxsVGV4dChwLnJlbW90ZVBvcnQpOwogICAgc2V0VHh0
;KCdbZGF0YS1mPSJycG9ydCJdJywgcnBvcnQpOwogICAgY29uc3QgcnBvcnRFbCA9IHJvdy5xdWVyeVNlbGVjdG9yKCdbZGF0YS1m
;PSJycG9ydCJdJyk7CiAgICBpZiAocnBvcnRFbCkgcnBvcnRFbC5jbGFzc0xpc3QudG9nZ2xlKCdwb3J0LWhvdCcsIHBvcnRJc0hv
;dChwLnJlbW90ZVBvcnQpICYmIHJwb3J0ICE9PSAnJyk7CiAgICBjb25zdCBzdCA9IFN0cmluZyhwLnN0YXRlIHx8ICcnKTsKICAg
;IGNvbnN0IHN0YXRlVHh0ID0gcm93LnF1ZXJ5U2VsZWN0b3IoJy5wcm9jLXN0YXRlLXR4dCcpOwogICAgaWYgKHN0YXRlVHh0KSB7
;CiAgICAgIGlmIChzdGF0ZVR4dC50ZXh0Q29udGVudCAhPT0gc3QpIHN0YXRlVHh0LnRleHRDb250ZW50ID0gc3Q7CiAgICB9IGVs
;c2UgewogICAgICBzZXRUeHQoJ1tkYXRhLWY9InN0YXRlIl0nLCBzdCk7CiAgICB9CiAgICBjb25zdCBuZXREb3QgPSByb3cucXVl
;cnlTZWxlY3RvcignLnByb2MtbmV0LWRvdCcpOwogICAgaWYgKG5ldERvdCkgewogICAgICBjb25zdCBjb25uZWN0ZWQgPSBzdCA9
;PT0gJ+i/nuaOpScgfHwgL2VzdGFibGlzaGVkL2kudGVzdChzdCk7CiAgICAgIG5ldERvdC5jbGFzc0xpc3QudG9nZ2xlKCdoaWRk
;ZW4nLCAhY29ubmVjdGVkKTsKICAgIH0KICAgIGNvbnN0IGNwdUVsID0gcm93LnF1ZXJ5U2VsZWN0b3IoJ1tkYXRhLWY9ImNwdSJd
;Jyk7CiAgICBjb25zdCBtZW1FbCA9IHJvdy5xdWVyeVNlbGVjdG9yKCdbZGF0YS1mPSJtZW0iXScpOwogICAgY29uc3QgY3B1SG90
;ID0gKE51bWJlcihwLmNwdU4pIHx8IDApID4gMTsKICAgIGNvbnN0IG1lbUhvdCA9IChOdW1iZXIocC5tZW1OKSB8fCAwKSA+ICg1
;MTIgKiAxMDI0ICogMTAyNCk7CiAgICBpZiAoY3B1RWwpIHsKICAgICAgY3B1RWwuY2xhc3NMaXN0LnRvZ2dsZSgnaG90JywgY3B1
;SG90KTsKICAgICAgY3B1RWwuc3R5bGUuYmFja2dyb3VuZCA9IGhlYXRDb2xvcihjcHVIb3QpOwogICAgfQogICAgaWYgKG1lbUVs
;KSB7CiAgICAgIG1lbUVsLmNsYXNzTGlzdC50b2dnbGUoJ2hvdCcsIG1lbUhvdCk7CiAgICAgIG1lbUVsLnN0eWxlLmJhY2tncm91
;bmQgPSBoZWF0Q29sb3IobWVtSG90KTsKICAgIH0KICB9CiAgLy8g5a2X5q+N5o6S5bqP77ya5ZCM5a2X5q+NIGEvQSDmjKjlnKjk
;uIDotbfvvIzkuJQgYSDlnKggQSDliY3vvIhh4oCmQeKApmLigKZC4oCm77yJCiAgZnVuY3Rpb24gcHJvY05hbWVTb3J0UmFuayhj
;aCkgewogICAgY29uc3QgYyA9IFN0cmluZyhjaCB8fCAnJyk7CiAgICBpZiAoIWMpIHJldHVybiAwOwogICAgY29uc3QgY29kZSA9
;IGMuY2hhckNvZGVBdCgwKTsKICAgIGlmIChjb2RlID49IDY1ICYmIGNvZGUgPD0gOTApIHJldHVybiAoY29kZSAtIDY1KSAqIDIg
;KyAxOwogICAgaWYgKGNvZGUgPj0gOTcgJiYgY29kZSA8PSAxMjIpIHJldHVybiAoY29kZSAtIDk3KSAqIDI7CiAgICByZXR1cm4g
;MjAwMCArIGNvZGU7CiAgfQogIGZ1bmN0aW9uIGNvbXBhcmVQcm9jTmFtZShhLCBiKSB7CiAgICBjb25zdCBzYSA9IFN0cmluZyhh
;IHx8ICcnKTsKICAgIGNvbnN0IHNiID0gU3RyaW5nKGIgfHwgJycpOwogICAgY29uc3QgbiA9IE1hdGgubWF4KHNhLmxlbmd0aCwg
;c2IubGVuZ3RoKTsKICAgIGZvciAobGV0IGkgPSAwOyBpIDwgbjsgaSsrKSB7CiAgICAgIGNvbnN0IGNhID0gc2FbaV0gfHwgJyc7
;CiAgICAgIGNvbnN0IGNiID0gc2JbaV0gfHwgJyc7CiAgICAgIGlmICghY2EpIHJldHVybiAtMTsKICAgICAgaWYgKCFjYikgcmV0
;dXJuIDE7CiAgICAgIGNvbnN0IGxhID0gY2EudG9Mb3dlckNhc2UoKTsKICAgICAgY29uc3QgbGIgPSBjYi50b0xvd2VyQ2FzZSgp
;OwogICAgICBpZiAoL1thLXpdL2kudGVzdChjYSkgJiYgL1thLXpdL2kudGVzdChjYikpIHsKICAgICAgICBpZiAobGEgIT09IGxi
;KSByZXR1cm4gbGEgPCBsYiA/IC0xIDogMTsKICAgICAgICBjb25zdCByYSA9IHByb2NOYW1lU29ydFJhbmsoY2EpOwogICAgICAg
;IGNvbnN0IHJiID0gcHJvY05hbWVTb3J0UmFuayhjYik7CiAgICAgICAgaWYgKHJhICE9PSByYikgcmV0dXJuIHJhIC0gcmI7CiAg
;ICAgICAgY29udGludWU7CiAgICAgIH0KICAgICAgY29uc3QgY21wID0gY2EubG9jYWxlQ29tcGFyZShjYiwgJ3poLUNOJywgeyBu
;dW1lcmljOiB0cnVlLCBzZW5zaXRpdml0eTogJ3ZhcmlhbnQnIH0pOwogICAgICBpZiAoY21wKSByZXR1cm4gY21wOwogICAgfQog
;ICAgcmV0dXJuIDA7CiAgfQogIGZ1bmN0aW9uIHNvcnRQcm9jUm93c0ZsYXQoaXRlbXMpIHsKICAgIGNvbnN0IGRpciA9IHByb2NT
;b3J0RGlyOwogICAgY29uc3Qga2V5ID0gcHJvY1NvcnRLZXk7CiAgICByZXR1cm4gaXRlbXMuc2xpY2UoKS5zb3J0KChhLCBiKSA9
;PiB7CiAgICAgIGxldCBjbXAgPSAwOwogICAgICBzd2l0Y2ggKGtleSkgewogICAgICAgIGNhc2UgJ2NwdSc6CiAgICAgICAgICBj
;bXAgPSAoTnVtYmVyKGEuY3B1TikgfHwgMCkgLSAoTnVtYmVyKGIuY3B1TikgfHwgMCk7CiAgICAgICAgICBicmVhazsKICAgICAg
;ICBjYXNlICdtZW0nOgogICAgICAgICAgY21wID0gKE51bWJlcihhLm1lbU4pIHx8IDApIC0gKE51bWJlcihiLm1lbU4pIHx8IDAp
;OwogICAgICAgICAgYnJlYWs7CiAgICAgICAgY2FzZSAncGlkJzoKICAgICAgICAgIGNtcCA9IChOdW1iZXIoYS5waWQpIHx8IDAp
;IC0gKE51bWJlcihiLnBpZCkgfHwgMCk7CiAgICAgICAgICBicmVhazsKICAgICAgICBjYXNlICdwcm90byc6CiAgICAgICAgICBj
;bXAgPSBTdHJpbmcoYS5wcm90byB8fCAnJykubG9jYWxlQ29tcGFyZShTdHJpbmcoYi5wcm90byB8fCAnJyksICdlbicpOwogICAg
;ICAgICAgYnJlYWs7CiAgICAgICAgY2FzZSAnbGlwJzoKICAgICAgICAgIGNtcCA9IFN0cmluZyhhLmxvY2FsSXAgfHwgJycpLmxv
;Y2FsZUNvbXBhcmUoU3RyaW5nKGIubG9jYWxJcCB8fCAnJyksICdlbicsIHsgbnVtZXJpYzogdHJ1ZSB9KTsKICAgICAgICAgIGJy
;ZWFrOwogICAgICAgIGNhc2UgJ2xwb3J0JzoKICAgICAgICAgIGNtcCA9IChOdW1iZXIoYS5sb2NhbFBvcnQpIHx8IDApIC0gKE51
;bWJlcihiLmxvY2FsUG9ydCkgfHwgMCk7CiAgICAgICAgICBicmVhazsKICAgICAgICBjYXNlICdyaXAnOgogICAgICAgICAgY21w
;ID0gU3RyaW5nKGEucmVtb3RlSXAgfHwgJycpLmxvY2FsZUNvbXBhcmUoU3RyaW5nKGIucmVtb3RlSXAgfHwgJycpLCAnZW4nLCB7
;IG51bWVyaWM6IHRydWUgfSk7CiAgICAgICAgICBicmVhazsKICAgICAgICBjYXNlICdycG9ydCc6CiAgICAgICAgICBjbXAgPSAo
;TnVtYmVyKGEucmVtb3RlUG9ydCkgfHwgMCkgLSAoTnVtYmVyKGIucmVtb3RlUG9ydCkgfHwgMCk7CiAgICAgICAgICBicmVhazsK
;ICAgICAgICBjYXNlICdzdGF0ZSc6CiAgICAgICAgICBjbXAgPSBTdHJpbmcoYS5zdGF0ZSB8fCAnJykubG9jYWxlQ29tcGFyZShT
;dHJpbmcoYi5zdGF0ZSB8fCAnJyksICd6aC1DTicpOwogICAgICAgICAgYnJlYWs7CiAgICAgICAgY2FzZSAnbmFtZSc6CiAgICAg
;ICAgZGVmYXVsdDoKICAgICAgICAgIGNtcCA9IGNvbXBhcmVQcm9jTmFtZShhLnByb2MgfHwgJycsIGIucHJvYyB8fCAnJyk7CiAg
;ICAgICAgICBicmVhazsKICAgICAgfQogICAgICBpZiAoIWNtcCAmJiBrZXkgIT09ICduYW1lJykKICAgICAgICBjbXAgPSBjb21w
;YXJlUHJvY05hbWUoYS5wcm9jIHx8ICcnLCBiLnByb2MgfHwgJycpOwogICAgICBpZiAoIWNtcCkKICAgICAgICBjbXAgPSAoTnVt
;YmVyKGEucGlkKSB8fCAwKSAtIChOdW1iZXIoYi5waWQpIHx8IDApOwogICAgICBpZiAoIWNtcCkKICAgICAgICBjbXAgPSAoTnVt
;YmVyKGEubG9jYWxQb3J0KSB8fCAwKSAtIChOdW1iZXIoYi5sb2NhbFBvcnQpIHx8IDApOwogICAgICByZXR1cm4gY21wICogZGly
;OwogICAgfSk7CiAgfQogIGZ1bmN0aW9uIHJlZnJlc2hQcm9jU29ydEhlYWRlcnMoKSB7CiAgICBpZiAoIXByb2NIZWFkKSByZXR1
;cm47CiAgICBwcm9jSGVhZC5xdWVyeVNlbGVjdG9yQWxsKCcucHJvYy1oY2VsbFtkYXRhLXNvcnRdJykuZm9yRWFjaChjZWxsID0+
;IHsKICAgICAgY29uc3QgayA9IGNlbGwuZ2V0QXR0cmlidXRlKCdkYXRhLXNvcnQnKTsKICAgICAgY29uc3Qgb24gPSBrID09PSBw
;cm9jU29ydEtleTsKICAgICAgY2VsbC5jbGFzc0xpc3QudG9nZ2xlKCdzb3J0ZWQnLCBvbik7CiAgICAgIGNlbGwuY2xhc3NMaXN0
;LnRvZ2dsZSgnYXNjJywgb24gJiYgcHJvY1NvcnREaXIgPiAwKTsKICAgICAgY2VsbC5jbGFzc0xpc3QudG9nZ2xlKCdkZXNjJywg
;b24gJiYgcHJvY1NvcnREaXIgPCAwKTsKICAgIH0pOwogIH0KICBpZiAocHJvY0hlYWQpIHsKICAgIHByb2NIZWFkLnF1ZXJ5U2Vs
;ZWN0b3JBbGwoJy5wcm9jLWhjZWxsW2RhdGEtc29ydF0nKS5mb3JFYWNoKGNlbGwgPT4gewogICAgICBjZWxsLmFkZEV2ZW50TGlz
;dGVuZXIoJ2NsaWNrJywgKGUpID0+IHsKICAgICAgICBlLnByZXZlbnREZWZhdWx0KCk7CiAgICAgICAgY29uc3QgayA9IGNlbGwu
;Z2V0QXR0cmlidXRlKCdkYXRhLXNvcnQnKTsKICAgICAgICBpZiAoIWspIHJldHVybjsKICAgICAgICBpZiAocHJvY1NvcnRLZXkg
;PT09IGspIHByb2NTb3J0RGlyID0gLXByb2NTb3J0RGlyOwogICAgICAgIGVsc2UgewogICAgICAgICAgcHJvY1NvcnRLZXkgPSBr
;OwogICAgICAgICAgLy8g6LWE5rqQ5YiX6buY6K6k6auY4oaS5L2O77yM5ZCN56ew6buY6K6kIGHihpJ6CiAgICAgICAgICBwcm9j
;U29ydERpciA9IChrID09PSAnY3B1JyB8fCBrID09PSAnbWVtJyB8fCBrID09PSAnbHBvcnQnIHx8IGsgPT09ICdycG9ydCcpID8g
;LTEgOiAxOwogICAgICAgIH0KICAgICAgICByZWZyZXNoUHJvY1NvcnRIZWFkZXJzKCk7CiAgICAgICAgcmVuZGVyUHJvY1RhYmxl
;KCk7CiAgICAgIH0pOwogICAgfSk7CiAgICByZWZyZXNoUHJvY1NvcnRIZWFkZXJzKCk7CiAgfQogIGZ1bmN0aW9uIHBhdGNoUHJv
;Y0ljb25zKGl0ZW1zKSB7CiAgICBsZXQgcGF0Y2hlZCA9IDA7CiAgICBmb3IgKGNvbnN0IHAgb2YgaXRlbXMgfHwgW10pIHsKICAg
;ICAgaWYgKCFwIHx8ICFwLmljb24pIGNvbnRpbnVlOwogICAgICBjb25zdCBrZXkgPSBwcm9jUm93S2V5KHApOwogICAgICBjb25z
;dCByb3cgPSBwcm9jUm93TWFwLmdldChrZXkpIHx8IHByb2NCb2R5LnF1ZXJ5U2VsZWN0b3IoJy5wcm9jLXJvd1tkYXRhLWtleT0i
;JyArIENTUy5lc2NhcGUoa2V5KSArICciXScpOwogICAgICBpZiAoIXJvdykgY29udGludWU7CiAgICAgIGNvbnN0IG5hbWVCb3gg
;PSByb3cucXVlcnlTZWxlY3RvcignLnByb2MtbmFtZScpOwogICAgICBzZXRQcm9jSWNvbkVsKG5hbWVCb3gsIHAuaWNvbiwgcHJv
;Y0ljb25TdGFibGVLZXkocCkpOwogICAgICBwYXRjaGVkKys7CiAgICB9CiAgICByZXR1cm4gcGF0Y2hlZCA+IDAgfHwgcHJvY1Jv
;d01hcC5zaXplID4gMDsKICB9CiAgZnVuY3Rpb24gc2VsZWN0UHJvY05hbWVHcm91cChyb3csIGFkZGl0aXZlKSB7CiAgICBjb25z
;dCBrZXkgPSByb3cuZ2V0QXR0cmlidXRlKCdkYXRhLWtleScpOwogICAgaWYgKCFhZGRpdGl2ZSkgcHJvY1NlbEtleXMuY2xlYXIo
;KTsKICAgIHByb2NTZWxLZXlzLmFkZChrZXkpOwogICAgcHJvY0FuY2hvcktleSA9IGtleTsKICAgIHByb2NTZWxLZXkgPSBrZXk7
;CiAgICBwcm9jU2VsUGlkID0gTnVtYmVyKHJvdy5nZXRBdHRyaWJ1dGUoJ2RhdGEtcGlkJykpIHx8IDA7CiAgICByZWZyZXNoUHJv
;Y1NlbGVjdGlvblVJKCk7CiAgfQogIGZ1bmN0aW9uIHNlbGVjdFByb2NGcm9tRXZlbnQoZSwgcm93KSB7CiAgICBjb25zdCBrZXkg
;PSByb3cuZ2V0QXR0cmlidXRlKCdkYXRhLWtleScpOwogICAgY29uc3QgcGlkID0gTnVtYmVyKHJvdy5nZXRBdHRyaWJ1dGUoJ2Rh
;dGEtcGlkJykpIHx8IDA7CiAgICBjb25zdCByb3dzID0gQXJyYXkuZnJvbShwcm9jQm9keS5xdWVyeVNlbGVjdG9yQWxsKCcucHJv
;Yy1yb3cnKSk7CiAgICBjb25zdCBpZHggPSByb3dzLmluZGV4T2Yocm93KTsKICAgIGlmIChlLnNoaWZ0S2V5ICYmIHByb2NBbmNo
;b3JLZXkpIHsKICAgICAgY29uc3QgYUlkeCA9IHJvd3MuZmluZEluZGV4KHIgPT4gci5nZXRBdHRyaWJ1dGUoJ2RhdGEta2V5Jykg
;PT09IHByb2NBbmNob3JLZXkpOwogICAgICBpZiAoYUlkeCA+PSAwICYmIGlkeCA+PSAwKSB7CiAgICAgICAgaWYgKCFlLmN0cmxL
;ZXkpIHByb2NTZWxLZXlzLmNsZWFyKCk7CiAgICAgICAgY29uc3QgbG8gPSBNYXRoLm1pbihhSWR4LCBpZHgpLCBoaSA9IE1hdGgu
;bWF4KGFJZHgsIGlkeCk7CiAgICAgICAgZm9yIChsZXQgaSA9IGxvOyBpIDw9IGhpOyBpKyspIHByb2NTZWxLZXlzLmFkZChyb3dz
;W2ldLmdldEF0dHJpYnV0ZSgnZGF0YS1rZXknKSk7CiAgICAgIH0KICAgICAgcHJvY1NlbEtleSA9IGtleTsKICAgICAgcHJvY1Nl
;bFBpZCA9IHBpZDsKICAgICAgcmVmcmVzaFByb2NTZWxlY3Rpb25VSSgpOwogICAgICByZXR1cm47CiAgICB9CiAgICBpZiAoZS5j
;dHJsS2V5KSB7CiAgICAgIGlmIChwcm9jU2VsS2V5cy5oYXMoa2V5KSkgcHJvY1NlbEtleXMuZGVsZXRlKGtleSk7CiAgICAgIGVs
;c2UgcHJvY1NlbEtleXMuYWRkKGtleSk7CiAgICAgIHByb2NBbmNob3JLZXkgPSBrZXk7CiAgICAgIHByb2NTZWxLZXkgPSBrZXk7
;CiAgICAgIHByb2NTZWxQaWQgPSBwaWQ7CiAgICAgIHJlZnJlc2hQcm9jU2VsZWN0aW9uVUkoKTsKICAgICAgcmV0dXJuOwogICAg
;fQogICAgLy8g5pmu6YCa5Y2V5Ye777ya5Y+q57uZ54K55Lit55qE6KGM5bqV6Imy77yb5ZCM5ZCN5pW05q6155S75reh57u/5aSW
;5qGGCiAgICBzZWxlY3RQcm9jTmFtZUdyb3VwKHJvdywgZmFsc2UpOwogIH0KICBmdW5jdGlvbiByZWZyZXNoUHJvY1NlbGVjdGlv
;blVJKCkgewogICAgY29uc3Qgcm93cyA9IEFycmF5LmZyb20ocHJvY0JvZHkucXVlcnlTZWxlY3RvckFsbCgnLnByb2Mtcm93Jykp
;OwogICAgY29uc3QgR1JQID0gWydvbicsICdncnAnLCAnZ3JwLWZpcnN0JywgJ2dycC1taWQnLCAnZ3JwLWxhc3QnLCAnZ3JwLW9u
;bHknXTsKICAgIGNvbnN0IHNlbGVjdGVkTmFtZXMgPSBuZXcgU2V0KCk7CiAgICByb3dzLmZvckVhY2gocm93ID0+IHsKICAgICAg
;R1JQLmZvckVhY2goYyA9PiByb3cuY2xhc3NMaXN0LnJlbW92ZShjKSk7CiAgICAgIGNvbnN0IGtleSA9IHJvdy5nZXRBdHRyaWJ1
;dGUoJ2RhdGEta2V5Jyk7CiAgICAgIGlmIChwcm9jU2VsS2V5cy5oYXMoa2V5KSkgewogICAgICAgIHJvdy5jbGFzc0xpc3QuYWRk
;KCdvbicpOwogICAgICAgIGNvbnN0IG5hbWUgPSBTdHJpbmcocm93LmdldEF0dHJpYnV0ZSgnZGF0YS1uYW1lJykgfHwgJycpLnRv
;TG93ZXJDYXNlKCk7CiAgICAgICAgaWYgKG5hbWUpIHNlbGVjdGVkTmFtZXMuYWRkKG5hbWUpOwogICAgICB9CiAgICB9KTsKICAg
;IC8vIOaMiemAieS4reihjOeahOi/m+eoi+WQje+8jOaKiuWQjOWQjei/nue7reauteWMhea3oee7v+Wkluahhu+8iOaXoOW6leiJ
;su+8iQogICAgbGV0IGkgPSAwOwogICAgd2hpbGUgKGkgPCByb3dzLmxlbmd0aCkgewogICAgICBjb25zdCBuYW1lID0gU3RyaW5n
;KHJvd3NbaV0uZ2V0QXR0cmlidXRlKCdkYXRhLW5hbWUnKSB8fCAnJykudG9Mb3dlckNhc2UoKTsKICAgICAgaWYgKCFuYW1lIHx8
;ICFzZWxlY3RlZE5hbWVzLmhhcyhuYW1lKSkgewogICAgICAgIGkrKzsKICAgICAgICBjb250aW51ZTsKICAgICAgfQogICAgICBs
;ZXQgaiA9IGk7CiAgICAgIHdoaWxlIChqICsgMSA8IHJvd3MubGVuZ3RoCiAgICAgICAgJiYgU3RyaW5nKHJvd3NbaiArIDFdLmdl
;dEF0dHJpYnV0ZSgnZGF0YS1uYW1lJykgfHwgJycpLnRvTG93ZXJDYXNlKCkgPT09IG5hbWUpIHsKICAgICAgICBqKys7CiAgICAg
;IH0KICAgICAgZm9yIChsZXQgayA9IGk7IGsgPD0gajsgaysrKSB7CiAgICAgICAgcm93c1trXS5jbGFzc0xpc3QuYWRkKCdncnAn
;KTsKICAgICAgICBpZiAoaSA9PT0gaikgcm93c1trXS5jbGFzc0xpc3QuYWRkKCdncnAtb25seScpOwogICAgICAgIGVsc2UgaWYg
;KGsgPT09IGkpIHJvd3Nba10uY2xhc3NMaXN0LmFkZCgnZ3JwLWZpcnN0Jyk7CiAgICAgICAgZWxzZSBpZiAoayA9PT0gaikgcm93
;c1trXS5jbGFzc0xpc3QuYWRkKCdncnAtbGFzdCcpOwogICAgICAgIGVsc2Ugcm93c1trXS5jbGFzc0xpc3QuYWRkKCdncnAtbWlk
;Jyk7CiAgICAgIH0KICAgICAgaSA9IGogKyAxOwogICAgfQogIH0KICBmdW5jdGlvbiBjb2xsZWN0UHJvY1RhcmdldHMoKSB7CiAg
;ICBjb25zdCBtYXAgPSBuZXcgTWFwKCk7CiAgICBmb3IgKGNvbnN0IGtleSBvZiBwcm9jU2VsS2V5cykgewogICAgICBjb25zdCBy
;b3cgPSBwcm9jUm93TWFwLmdldChrZXkpIHx8IHByb2NCb2R5LnF1ZXJ5U2VsZWN0b3IoJy5wcm9jLXJvd1tkYXRhLWtleT0iJyAr
;IENTUy5lc2NhcGUoa2V5KSArICciXScpOwogICAgICBsZXQgcGlkID0gMCwgbmFtZSA9ICcnLCBwYXRoID0gJyc7CiAgICAgIGlm
;IChyb3cpIHsKICAgICAgICBwaWQgPSBOdW1iZXIocm93LmdldEF0dHJpYnV0ZSgnZGF0YS1waWQnKSkgfHwgMDsKICAgICAgICBu
;YW1lID0gcm93LmdldEF0dHJpYnV0ZSgnZGF0YS1uYW1lJykgfHwgJyc7CiAgICAgICAgcGF0aCA9IHJvdy5nZXRBdHRyaWJ1dGUo
;J2RhdGEtcGF0aCcpIHx8ICcnOwogICAgICB9IGVsc2UgewogICAgICAgIGNvbnN0IHAgPSBwcm9jSXRlbXMuZmluZCh4ID0+IHBy
;b2NSb3dLZXkoeCkgPT09IGtleSk7CiAgICAgICAgaWYgKCFwKSBjb250aW51ZTsKICAgICAgICBwaWQgPSBOdW1iZXIocC5waWQp
;IHx8IDA7CiAgICAgICAgbmFtZSA9IHAucHJvYyB8fCAnJzsKICAgICAgICBwYXRoID0gcC5wYXRoIHx8ICcnOwogICAgICB9CiAg
;ICAgIGlmIChwaWQgPD0gMCB8fCBtYXAuaGFzKHBpZCkpIGNvbnRpbnVlOwogICAgICBpZiAoIXBhdGgpIHsKICAgICAgICBjb25z
;dCBwID0gcHJvY0l0ZW1zLmZpbmQoeCA9PiBOdW1iZXIoeC5waWQpID09PSBwaWQgJiYgeC5wYXRoKTsKICAgICAgICBpZiAocCkg
;cGF0aCA9IHAucGF0aCB8fCAnJzsKICAgICAgfQogICAgICBtYXAuc2V0KHBpZCwgeyBwaWQsIG5hbWUsIHBhdGggfSk7CiAgICB9
;CiAgICByZXR1cm4gQXJyYXkuZnJvbShtYXAudmFsdWVzKCkpOwogIH0KICBmdW5jdGlvbiByZW5kZXJQcm9jVGFibGUoKSB7CiAg
;ICBjb25zdCBxID0gKHByb2NRLnZhbHVlIHx8ICcnKS50cmltKCkudG9Mb3dlckNhc2UoKTsKICAgIGxldCByb3dzID0gcHJvY0l0
;ZW1zLnNsaWNlKCk7CiAgICBpZiAocSkgewogICAgICByb3dzID0gcm93cy5maWx0ZXIocCA9PiB7CiAgICAgICAgY29uc3QgaGF5
;ID0gW3AucHJvdG8sIHAubG9jYWxJcCwgcC5sb2NhbFBvcnQsIHAucmVtb3RlSXAsIHAucmVtb3RlUG9ydCwgcC5zdGF0ZSwgcC5w
;cm9jLCBwLnBpZCwgcC5wcGlkXS5qb2luKCcgJykudG9Mb3dlckNhc2UoKTsKICAgICAgICByZXR1cm4gaGF5LmluY2x1ZGVzKHEp
;OwogICAgICB9KTsKICAgIH0KICAgIHJvd3MgPSBzb3J0UHJvY1Jvd3NGbGF0KHJvd3MpOwogICAgY29uc3QgcGlkU2V0ID0gbmV3
;IFNldCgpOwogICAgZm9yIChjb25zdCBwIG9mIHJvd3MpIHsKICAgICAgY29uc3QgaWQgPSBOdW1iZXIocC5waWQpIHx8IDA7CiAg
;ICAgIGlmIChpZCA+IDApIHBpZFNldC5hZGQoaWQpOwogICAgfQogICAgcHJvY0NvdW50LnRleHRDb250ZW50ID0gU3RyaW5nKHBp
;ZFNldC5zaXplIHx8IHJvd3MubGVuZ3RoKTsKICAgIGlmICghcm93cy5sZW5ndGgpIHsKICAgICAgcHJvY0JvZHkuaW5uZXJIVE1M
;ID0gJzxkaXYgc3R5bGU9InBhZGRpbmc6MjRweDt0ZXh0LWFsaWduOmNlbnRlcjtjb2xvcjojOWFhMWIyIj7msqHmnInljLnphY3n
;moTov57mjqU8L2Rpdj4nOwogICAgICBwcm9jUm93TWFwLmNsZWFyKCk7CiAgICAgIHByb2NTZWxLZXlzLmNsZWFyKCk7CiAgICAg
;IHByb2NBbmNob3JLZXkgPSAnJzsKICAgICAgcHJvY1NlbEtleSA9ICcnOwogICAgICBwcm9jU2VsUGlkID0gMDsKICAgICAgcmV0
;dXJuOwogICAgfQogICAgLy8g5aKe6YeP5pu05paw77ya5aSN55So6KGM5LiO5Zu+5qCH6IqC54K577yM5Y+q5pS55paH5a2X77yM
;6YG/5YWN5pW06KGo6YeN5bu66Zeq5Zu+5qCHCiAgICBjb25zdCBrZWVwID0gbmV3IFNldCgpOwogICAgY29uc3QgZW1wdHlIaW50
;ID0gcHJvY0JvZHkucXVlcnlTZWxlY3RvcignZGl2W3N0eWxlXScpOwogICAgaWYgKGVtcHR5SGludCkgewogICAgICBwcm9jQm9k
;eS5pbm5lckhUTUwgPSAnJzsKICAgICAgcHJvY1Jvd01hcC5jbGVhcigpOwogICAgfQogICAgZm9yIChsZXQgaSA9IDA7IGkgPCBy
;b3dzLmxlbmd0aDsgaSsrKSB7CiAgICAgIGNvbnN0IHAgPSByb3dzW2ldOwogICAgICBjb25zdCBrZXkgPSBwcm9jUm93S2V5KHAp
;OwogICAgICBrZWVwLmFkZChrZXkpOwogICAgICBsZXQgcm93ID0gcHJvY1Jvd01hcC5nZXQoa2V5KTsKICAgICAgaWYgKCFyb3cg
;fHwgIXJvdy5pc0Nvbm5lY3RlZCkgewogICAgICAgIHJvdyA9IGVuc3VyZVByb2NSb3cocCk7CiAgICAgICAgcHJvY1Jvd01hcC5z
;ZXQoa2V5LCByb3cpOwogICAgICB9CiAgICAgIHVwZGF0ZVByb2NSb3dEYXRhKHJvdywgcCk7CiAgICAgIGNvbnN0IGF0ID0gcHJv
;Y0JvZHkuY2hpbGRyZW5baV07CiAgICAgIGlmIChhdCAhPT0gcm93KSB7CiAgICAgICAgaWYgKGF0KSBwcm9jQm9keS5pbnNlcnRC
;ZWZvcmUocm93LCBhdCk7CiAgICAgICAgZWxzZSBwcm9jQm9keS5hcHBlbmRDaGlsZChyb3cpOwogICAgICB9CiAgICB9CiAgICAv
;LyDliKDmjonkuI3lho3lrZjlnKjnmoTooYwKICAgIGZvciAoY29uc3QgW2tleSwgcm93XSBvZiBBcnJheS5mcm9tKHByb2NSb3dN
;YXAuZW50cmllcygpKSkgewogICAgICBpZiAoa2VlcC5oYXMoa2V5KSkgY29udGludWU7CiAgICAgIHByb2NSb3dNYXAuZGVsZXRl
;KGtleSk7CiAgICAgIGlmIChyb3cgJiYgcm93LnBhcmVudE5vZGUpIHJvdy5wYXJlbnROb2RlLnJlbW92ZUNoaWxkKHJvdyk7CiAg
;ICB9CiAgICBmb3IgKGNvbnN0IGtleSBvZiBBcnJheS5mcm9tKHByb2NTZWxLZXlzKSkgewogICAgICBpZiAoIWtlZXAuaGFzKGtl
;eSkpIHByb2NTZWxLZXlzLmRlbGV0ZShrZXkpOwogICAgfQogICAgaWYgKHByb2NTZWxLZXkgJiYgIXByb2NTZWxLZXlzLmhhcyhw
;cm9jU2VsS2V5KSkgewogICAgICBwcm9jU2VsS2V5ID0gcHJvY1NlbEtleXMuc2l6ZSA/IEFycmF5LmZyb20ocHJvY1NlbEtleXMp
;WzBdIDogJyc7CiAgICAgIHByb2NTZWxQaWQgPSAwOwogICAgICBpZiAocHJvY1NlbEtleSkgewogICAgICAgIGNvbnN0IHIgPSBw
;cm9jUm93TWFwLmdldChwcm9jU2VsS2V5KTsKICAgICAgICBwcm9jU2VsUGlkID0gciA/IChOdW1iZXIoci5nZXRBdHRyaWJ1dGUo
;J2RhdGEtcGlkJykpIHx8IDApIDogMDsKICAgICAgfQogICAgfQogICAgcmVmcmVzaFByb2NTZWxlY3Rpb25VSSgpOwogIH0KICBm
;dW5jdGlvbiBpbmZvUm93KGxhYiwgdmFsSHRtbCwgbGlua0h0bWwpIHsKICAgIHJldHVybiAnPGRpdiBjbGFzcz0iaW5mby1yb3ci
;PicKICAgICAgKyAnPGRpdiBjbGFzcz0iaW5mby1sYWIiPicgKyBlc2NhcGVIdG1sKGxhYikgKyAnPC9kaXY+JwogICAgICArICc8
;ZGl2IGNsYXNzPSJpbmZvLWRhc2giPjwvZGl2PicKICAgICAgKyAnPGRpdiBjbGFzcz0iaW5mby12YWwiPicgKyAodmFsSHRtbCB8
;fCAnJykgKyAnPC9kaXY+JwogICAgICArIChsaW5rSHRtbCB8fCAnPHNwYW4+PC9zcGFuPicpCiAgICAgICsgJzwvZGl2Pic7CiAg
;fQogIGZ1bmN0aW9uIHJlbmRlclN5c0luZm8oKSB7CiAgICBjb25zdCBkID0gaW5mb0RhdGEgfHwge307CiAgICBsZXQgaHRtbCA9
;ICcnOwogICAgaHRtbCArPSBpbmZvUm93KCfmk43kvZzns7vnu58nLCBlc2NhcGVIdG1sKGQub3MgfHwgJ+acquefpScpKTsKICAg
;IGh0bWwgKz0gaW5mb1Jvdygn5Li75p2/JywgZXNjYXBlSHRtbChkLmJvYXJkIHx8ICfmnKrnn6UnKSk7CiAgICBodG1sICs9IGlu
;Zm9Sb3coJ+aYvuekuuWZqCcsIGVzY2FwZUh0bWwoZC5tb25pdG9yIHx8ICfmnKrnn6UnKSk7CiAgICBodG1sICs9IGluZm9Sb3co
;J+WkhOeQhuWZqCcsIGVzY2FwZUh0bWwoZC5jcHUgfHwgJ+acquefpScpKTsKICAgIGh0bWwgKz0gaW5mb1Jvdygn5YaF5a2YJywg
;ZXNjYXBlSHRtbChkLm1lbW9yeSB8fCAn5pyq55+lJykpOwogICAgaHRtbCArPSBpbmZvUm93KCfnoaznm5gnLCBlc2NhcGVIdG1s
;KGQuZGlzayB8fCAn5pyq55+lJykpOwogICAgaHRtbCArPSBpbmZvUm93KCfmmL7ljaEnLCBlc2NhcGVIdG1sKGQuZ3B1IHx8ICfm
;nKrnn6UnKSk7CiAgICBjb25zdCBzb3VuZHMgPSBBcnJheS5pc0FycmF5KGQuc291bmQpID8gZC5zb3VuZCA6IFtdOwogICAgaHRt
;bCArPSBpbmZvUm93KCflo7DljaEnLCBzb3VuZHMubGVuZ3RoCiAgICAgID8gc291bmRzLm1hcChzID0+ICc8c3BhbiBjbGFzcz0i
;bGluZSI+JyArIGVzY2FwZUh0bWwocykgKyAnPC9zcGFuPicpLmpvaW4oJycpCiAgICAgIDogZXNjYXBlSHRtbCgn5pyq55+lJykp
;OwogICAgY29uc3QgbmV0cyA9IEFycmF5LmlzQXJyYXkoZC5uaWNzKSA/IGQubmljcyA6IFtdOwogICAgbGV0IG5ldEh0bWwgPSAn
;5pyq55+lJzsKICAgIGlmIChuZXRzLmxlbmd0aCkgewogICAgICBuZXRIdG1sID0gbmV0cy5tYXAobiA9PiB7CiAgICAgICAgY29u
;c3QgbmFtZSA9IGVzY2FwZUh0bWwobi5uYW1lIHx8ICcnKTsKICAgICAgICBjb25zdCBtYWMgPSBlc2NhcGVIdG1sKG4ubWFjIHx8
;ICfigJQnKTsKICAgICAgICBjb25zdCBpcFJhdyA9IChuLmlwICYmIFN0cmluZyhuLmlwKS50cmltKCkpID8gU3RyaW5nKG4uaXAp
;LnRyaW0oKSA6ICcwLjAuMC4wJzsKICAgICAgICBjb25zdCBpcCA9IGVzY2FwZUh0bWwoaXBSYXcgPT09ICfigJQnID8gJzAuMC4w
;LjAnIDogaXBSYXcpOwogICAgICAgIHJldHVybiAnPGRpdiBjbGFzcz0ibmV0LWxpbmUiPjxzcGFuPicgKyBuYW1lICsgJzwvc3Bh
;bj4nCiAgICAgICAgICArICc8c3Bhbj48c3BhbiBjbGFzcz0iayI+TUFD5Zyw5Z2AOiA8L3NwYW4+JyArIG1hYyArICc8L3NwYW4+
;JwogICAgICAgICAgKyAnPHNwYW4+PHNwYW4gY2xhc3M9ImsiPklQ5Zyw5Z2AOiA8L3NwYW4+JyArIGlwICsgJzwvc3Bhbj48L2Rp
;dj4nOwogICAgICB9KS5qb2luKCcnKTsKICAgIH0KICAgIGh0bWwgKz0gaW5mb1Jvdygn572R5Y2hJywgbmV0SHRtbCk7CiAgICBo
;dG1sICs9IGluZm9Sb3coJ+Wklue9kUlQJywgZXNjYXBlSHRtbChkLndhbiB8fCAn5pyq55+lJykpOwogICAgaHRtbCArPSBpbmZv
;Um93KCdJReeJiOacrCcsIGVzY2FwZUh0bWwoZC5pZSB8fCAn5pyq55+lJykpOwogICAgaHRtbCArPSBpbmZvUm93KCdGbGFzaOeJ
;iOacrCcsIGVzY2FwZUh0bWwoZC5mbGFzaCB8fCAn5pyq55+lJykpOwogICAgY29uc3QgYm9vdEV4dHJhID0gJzxzcGFuIGNsYXNz
;PSJzdWIiPuezu+e7n+W3sui/kOihjDogPHNwYW4gaWQ9ImluZm8tdXB0aW1lIj4nCiAgICAgICsgZXNjYXBlSHRtbChmb3JtYXRV
;cHRpbWVUZXh0KGN1cnJlbnRVcHRpbWVTZWMoKSkpICsgJzwvc3Bhbj48L3NwYW4+JzsKICAgIGh0bWwgKz0gaW5mb1Jvdygn5byA
;5py65pe26Ze0JywgZXNjYXBlSHRtbChkLmJvb3QgfHwgJ+acquefpScpICsgYm9vdEV4dHJhKTsKICAgIGh0bWwgKz0gaW5mb1Jv
;dygn5LiK5qyh5YWz5py65pe26Ze0JywgZXNjYXBlSHRtbChkLnNodXRkb3duIHx8ICfmnKrnn6UnKSk7CiAgICBodG1sICs9IGlu
;Zm9Sb3coJ+ezu+e7n+WuieijheaXpeacnycsIGVzY2FwZUh0bWwoZC5pbnN0YWxsIHx8ICfmnKrnn6UnKSk7CiAgICBpbmZvUGFu
;ZWwuaW5uZXJIVE1MID0gaHRtbDsKICB9CiAgZnVuY3Rpb24gY3VycmVudFVwdGltZVNlYygpIHsKICAgIGNvbnN0IGJhc2UgPSBO
;dW1iZXIoaW5mb0RhdGEgJiYgaW5mb0RhdGEudXB0aW1lU2VjKSB8fCAwOwogICAgY29uc3Qgc3luY2VkID0gTnVtYmVyKGluZm9E
;YXRhICYmIGluZm9EYXRhLl9zeW5jZWRBdCkgfHwgRGF0ZS5ub3coKTsKICAgIHJldHVybiBNYXRoLm1heCgwLCBNYXRoLmZsb29y
;KGJhc2UgKyAoRGF0ZS5ub3coKSAtIHN5bmNlZCkgLyAxMDAwKSk7CiAgfQogIGZ1bmN0aW9uIGZvcm1hdFVwdGltZVRleHQoc2Vj
;KSB7CiAgICBzZWMgPSBNYXRoLm1heCgwLCBNYXRoLmZsb29yKE51bWJlcihzZWMpIHx8IDApKTsKICAgIGNvbnN0IGQgPSBNYXRo
;LmZsb29yKHNlYyAvIDg2NDAwKTsKICAgIGNvbnN0IGggPSBNYXRoLmZsb29yKChzZWMgJSA4NjQwMCkgLyAzNjAwKTsKICAgIGNv
;bnN0IG1pID0gTWF0aC5mbG9vcigoc2VjICUgMzYwMCkgLyA2MCk7CiAgICBjb25zdCBzID0gc2VjICUgNjA7CiAgICByZXR1cm4g
;KGQgPiAwID8gKGQgKyAn5aSpJykgOiAnJykgKyBoICsgJ+Wwj+aXticgKyBtaSArICfliIbpkp8nICsgcyArICfnp5InOwogIH0K
;ICBmdW5jdGlvbiB0aWNrSW5mb1VwdGltZSgpIHsKICAgIGlmIChtb25pdG9yVGFiICE9PSAnaW5mbycpIHJldHVybjsKICAgIGNv
;bnN0IGVsID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2luZm8tdXB0aW1lJyk7CiAgICBpZiAoIWVsKSByZXR1cm47CiAgICBl
;bC50ZXh0Q29udGVudCA9IGZvcm1hdFVwdGltZVRleHQoY3VycmVudFVwdGltZVNlYygpKTsKICB9CiAgc2V0SW50ZXJ2YWwodGlj
;a0luZm9VcHRpbWUsIDEwMDApOwoKICB3aW5kb3cuX19zZXRQcm9jZXNzZXMgPSAocGF5bG9hZCkgPT4gewogICAgLy8g6L+b56iL
;55uR5o6n5bey5pS55Li66L+e5o6l5YiX6KGo77yM5b+955Wl5pen6L+b56iL5o6o6YCBCiAgfTsKICB3aW5kb3cuX19zZXRQb3J0
;cyA9IChwYXlsb2FkKSA9PiB7CiAgICB0cnkgewogICAgICBjb25zdCBkYXRhID0gdHlwZW9mIHBheWxvYWQgPT09ICdzdHJpbmcn
;ID8gSlNPTi5wYXJzZShwYXlsb2FkKSA6IHBheWxvYWQ7CiAgICAgIGNvbnN0IG5leHQgPSBBcnJheS5pc0FycmF5KGRhdGEpID8g
;ZGF0YSA6IChBcnJheS5pc0FycmF5KGRhdGEgJiYgZGF0YS5pdGVtcykgPyBkYXRhLml0ZW1zIDogW10pOwogICAgICBpZiAoZGF0
;YSAmJiAhQXJyYXkuaXNBcnJheShkYXRhKSkgewogICAgICAgIGlmIChwcm9jQ3B1VG90YWwgJiYgZGF0YS5jcHVUb3RhbCAhPSBu
;dWxsKSBwcm9jQ3B1VG90YWwudGV4dENvbnRlbnQgPSBTdHJpbmcoZGF0YS5jcHVUb3RhbCk7CiAgICAgICAgaWYgKHByb2NNZW1U
;b3RhbCAmJiBkYXRhLm1lbVRvdGFsICE9IG51bGwpIHByb2NNZW1Ub3RhbC50ZXh0Q29udGVudCA9IFN0cmluZyhkYXRhLm1lbVRv
;dGFsKTsKICAgICAgICB1cGRhdGVIZWFkSGVhdChkYXRhLmNwdVRvdGFsLCBkYXRhLm1lbVRvdGFsKTsKICAgICAgfQogICAgICBj
;b25zdCBzY3JvbGxlciA9IHByb2NTY3JvbGwgfHwgcHJvY0JvZHk7CiAgICAgIGNvbnN0IHByZXZTY3JvbGwgPSBzY3JvbGxlciA/
;IHNjcm9sbGVyLnNjcm9sbFRvcCA6IDA7CiAgICAgIGNvbnN0IHNhbWVDb250ZW50ID0gcG9ydHNDb250ZW50U2lnKG5leHQpID09
;PSBwb3J0c0NvbnRlbnRTaWcocHJvY0l0ZW1zKTsKICAgICAgcHJvY0l0ZW1zID0gbmV4dDsKICAgICAgaWYgKG1vbml0b3JUYWIg
;IT09ICdwcm9jJykgcmV0dXJuOwogICAgICBpZiAoc2FtZUNvbnRlbnQpIHsKICAgICAgICAvLyDlj6rooaXlm77moIfvvIzkuI3p
;h43lu7rooYwKICAgICAgICBwYXRjaFByb2NJY29ucyhuZXh0KTsKICAgICAgICBpZiAoc2Nyb2xsZXIpIHNjcm9sbGVyLnNjcm9s
;bFRvcCA9IHByZXZTY3JvbGw7CiAgICAgICAgcmV0dXJuOwogICAgICB9CiAgICAgIHJlbmRlclByb2NUYWJsZSgpOwogICAgICBp
;ZiAoc2Nyb2xsZXIpIHNjcm9sbGVyLnNjcm9sbFRvcCA9IHByZXZTY3JvbGw7CiAgICB9IGNhdGNoIChlKSB7IGNvbnNvbGUud2Fy
;bignc2V0UG9ydHMnLCBlKTsgfQogIH07CiAgd2luZG93Ll9fc2V0SGFuZGxlcyA9IChwYXlsb2FkKSA9PiB7CiAgICB0cnkgewog
;ICAgICBjb25zdCBkYXRhID0gdHlwZW9mIHBheWxvYWQgPT09ICdzdHJpbmcnID8gSlNPTi5wYXJzZShwYXlsb2FkKSA6IHBheWxv
;YWQ7CiAgICAgIGhhbmRsZUJ1c3kgPSBmYWxzZTsKICAgICAgaGFuZGxlSXRlbXMgPSBzb3J0SGFuZGxlSXRlbXMoQXJyYXkuaXNB
;cnJheShkYXRhICYmIGRhdGEuaXRlbXMpID8gZGF0YS5pdGVtcyA6IChBcnJheS5pc0FycmF5KGRhdGEpID8gZGF0YSA6IFtdKSk7
;CiAgICAgIGlmIChkYXRhICYmIGRhdGEucSAhPSBudWxsKSBoYW5kbGVRdWVyeSA9IFN0cmluZyhkYXRhLnEpOwogICAgICBpZiAo
;ZGF0YSAmJiBkYXRhLm1vZGUpIGhhbmRsZU1vZGUgPSBTdHJpbmcoZGF0YS5tb2RlKSA9PT0gJ3BvcnQnID8gJ3BvcnQnIDogJ2hh
;bmRsZSc7CiAgICAgIGVsc2UgaGFuZGxlTW9kZSA9IGlzUG9ydFNlYXJjaFF1ZXJ5KGhhbmRsZVF1ZXJ5KSA/ICdwb3J0JyA6ICdo
;YW5kbGUnOwogICAgICBjb25zdCBlcnIgPSBkYXRhICYmIGRhdGEuZXJyb3IgPyBTdHJpbmcoZGF0YS5lcnJvcikgOiAnJzsKICAg
;ICAgaWYgKGhhbmRsZVN0YXR1cykgaGFuZGxlU3RhdHVzLnRleHRDb250ZW50ID0gZXJyIHx8IChoYW5kbGVJdGVtcy5sZW5ndGgg
;PyAnJyA6ICfml6Dnu5PmnpwnKTsKICAgICAgaWYgKGFwcE1vZGUgPT09ICdoYW5kbGUnKSB7CiAgICAgICAgcmVuZGVySGFuZGxl
;VGFibGUoZXJyIHx8IChoYW5kbGVNb2RlID09PSAncG9ydCcgPyAn5rKh5pyJ5Yy56YWN55qE56uv5Y+jJyA6ICfmsqHmnInljLnp
;hY3nmoTlj6Xmn4QnKSk7CiAgICAgICAgY291bnRFbC50ZXh0Q29udGVudCA9ICflhbEgJyArIGhhbmRsZUl0ZW1zLmxlbmd0aCAr
;ICcg5p2hJzsKICAgICAgfQogICAgfSBjYXRjaCAoZSkgewogICAgICBoYW5kbGVCdXN5ID0gZmFsc2U7CiAgICAgIGNvbnNvbGUu
;d2Fybignc2V0SGFuZGxlcycsIGUpOwogICAgfQogIH07CiAgd2luZG93Ll9fcHJvY0tpbGxlZCA9IChwaWRzKSA9PiB7CiAgICB0
;cnkgewogICAgICBjb25zdCBsaXN0ID0gQXJyYXkuaXNBcnJheShwaWRzKSA/IHBpZHMgOiBbXTsKICAgICAgcmVtb3ZlUm93c0J5
;UGlkcyhsaXN0KTsKICAgIH0gY2F0Y2ggKGUpIHsgY29uc29sZS53YXJuKCdwcm9jS2lsbGVkJywgZSk7IH0KICB9OwogIGZ1bmN0
;aW9uIHJlbW92ZVJvd3NCeVBpZHMocGlkcykgewogICAgY29uc3Qgc2V0ID0gbmV3IFNldCgocGlkcyB8fCBbXSkubWFwKG4gPT4g
;TnVtYmVyKG4pKS5maWx0ZXIobiA9PiBuID4gMCkpOwogICAgaWYgKCFzZXQuc2l6ZSkgcmV0dXJuOwogICAgY29uc3QgYmVmb3Jl
;SCA9IGhhbmRsZUl0ZW1zLmxlbmd0aDsKICAgIGhhbmRsZUl0ZW1zID0gaGFuZGxlSXRlbXMuZmlsdGVyKGl0ID0+ICFzZXQuaGFz
;KE51bWJlcihpdC5waWQpIHx8IDApKTsKICAgIGlmIChoYW5kbGVJdGVtcy5sZW5ndGggIT09IGJlZm9yZUgpIHsKICAgICAgZm9y
;IChjb25zdCBrIG9mIEFycmF5LmZyb20oaGFuZGxlU2VsS2V5cykpIHsKICAgICAgICBjb25zdCByb3cgPSBoYW5kbGVCb2R5LnF1
;ZXJ5U2VsZWN0b3IoJy5oYW5kbGUtcm93W2RhdGEta2V5PSInICsgQ1NTLmVzY2FwZShrKSArICciXScpOwogICAgICAgIGNvbnN0
;IHBpZCA9IHJvdyA/IChOdW1iZXIocm93LmdldEF0dHJpYnV0ZSgnZGF0YS1waWQnKSkgfHwgMCkgOiAwOwogICAgICAgIGlmIChz
;ZXQuaGFzKHBpZCkpIGhhbmRsZVNlbEtleXMuZGVsZXRlKGspOwogICAgICB9CiAgICAgIGlmIChhcHBNb2RlID09PSAnaGFuZGxl
;JykKICAgICAgICByZW5kZXJIYW5kbGVUYWJsZShoYW5kbGVJdGVtcy5sZW5ndGggPyAnJyA6IChoYW5kbGVNb2RlID09PSAncG9y
;dCcgPyAn5rKh5pyJ5Yy56YWN55qE56uv5Y+jJyA6ICfmsqHmnInljLnphY3nmoTlj6Xmn4QnKSk7CiAgICAgIGlmIChhcHBNb2Rl
;ID09PSAnaGFuZGxlJykKICAgICAgICBjb3VudEVsLnRleHRDb250ZW50ID0gJ+WFsSAnICsgaGFuZGxlSXRlbXMubGVuZ3RoICsg
;JyDmnaEnOwogICAgfQogIH07CiAgd2luZG93Ll9fc2V0U3lzSW5mbyA9IChwYXlsb2FkKSA9PiB7CiAgICB0cnkgewogICAgICBp
;bmZvUmVxR2VuICs9IDE7CiAgICAgIGNsZWFySW5mb0xvYWRXYWl0KCk7CiAgICAgIGNvbnN0IGRhdGEgPSB0eXBlb2YgcGF5bG9h
;ZCA9PT0gJ3N0cmluZycgPyBKU09OLnBhcnNlKHBheWxvYWQpIDogcGF5bG9hZDsKICAgICAgY29uc3QgcHJldlNlYyA9IGluZm9E
;YXRhICYmIGluZm9EYXRhLnVwdGltZVNlYzsKICAgICAgY29uc3QgcHJldlN5bmMgPSBpbmZvRGF0YSAmJiBpbmZvRGF0YS5fc3lu
;Y2VkQXQ7CiAgICAgIGluZm9EYXRhID0gZGF0YSB8fCB7fTsKICAgICAgLy8g5ZCM5LiA5Lu957yT5a2Y5YaN5qyh5o6o6YCB5pe2
;5L+d55WZ5ZCM5q2l54K577yM6YG/5YWN6L+Q6KGM5pe26Ze06KKr6YeN572uCiAgICAgIGlmIChwcmV2U3luYyAmJiBwcmV2U2Vj
;ICE9IG51bGwgJiYgTnVtYmVyKGluZm9EYXRhLnVwdGltZVNlYykgPT09IE51bWJlcihwcmV2U2VjKSkKICAgICAgICBpbmZvRGF0
;YS5fc3luY2VkQXQgPSBwcmV2U3luYzsKICAgICAgZWxzZQogICAgICAgIGluZm9EYXRhLl9zeW5jZWRBdCA9IERhdGUubm93KCk7
;CiAgICAgIGlmIChpbmZvRGF0YS51cHRpbWVTZWMgPT0gbnVsbCAmJiBpbmZvRGF0YS51cHRpbWUpCiAgICAgICAgaW5mb0RhdGEu
;dXB0aW1lU2VjID0gMDsKICAgICAgaW5mb1RleHQgPSBTdHJpbmcoZGF0YSAmJiBkYXRhLnRleHQgfHwgJycpOwogICAgICBpZiAo
;YXBwTW9kZSA9PT0gJ2luZm8nKSB7CiAgICAgICAgcmVuZGVyU3lzSW5mbygpOwogICAgICAgIGlmIChjb3VudEVsKSBjb3VudEVs
;LnRleHRDb250ZW50ID0gJ+acrOacuuS/oeaBryc7CiAgICAgIH0KICAgIH0gY2F0Y2ggKGUpIHsgY29uc29sZS53YXJuKCdzZXRT
;eXNJbmZvJywgZSk7IH0KICB9OwoKICBwb3N0KCd1aVJlYWR5Jyk7CiAgd2luZG93Ll9fcmVzeW5jU2VhcmNoID0gKCkgPT4gewog
;ICAgdHJ5IHsKICAgICAgaWYgKHR5cGVvZiBhcHBNb2RlICE9PSAndW5kZWZpbmVkJyAmJiBhcHBNb2RlICE9PSAnZmlsZScpIHJl
;dHVybjsKICAgICAgZG9TZWFyY2goKTsKICAgIH0gY2F0Y2ggKF8pIHt9CiAgfTsKICAvLyDov5vlhaXml7boi6Xlt7LmnInpgInk
;uK3nrZvpgInvvIzkuLvliqjluKbmnaHku7bmkJzntKLvvIjopobnm5YgQUhLIOepuuafpeivou+8iQogIHNldFRpbWVvdXQoKCkg
;PT4geyB0cnkgeyB3aW5kb3cuX19yZXN5bmNTZWFyY2goKTsgfSBjYXRjaCAoXykge30gfSwgMjgwKTsKICBzZXRUaW1lb3V0KCgp
;ID0+IHsgdHJ5IHsgd2luZG93Ll9fcmVzeW5jU2VhcmNoKCk7IH0gY2F0Y2ggKF8pIHt9IH0sIDkwMCk7Cn0pKCk7Cjwvc2NyaXB0
;Pgo8L2JvZHk+CjwvaHRtbD4K
;########################################################################################################### local_search_index.html

