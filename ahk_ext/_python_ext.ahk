#Requires AutoHotkey v2.0
#SingleInstance Force
#NoTrayIcon
; _python_ext.ahk — 按需启动（快捷键4 跳过 _ 开头脚本）；无托盘图标
; hosted：部署 aria2c + Python Embeddable，日志 → data\image_proc\ext.log
; until=<nodeId>：只部署到该节点（含前置）；不传 until 时若 hosted 则仅检测/退出不自动全量下载

global EXT_HOSTED := false
global EXT_UNTIL := ""
global EXT_LOG_FILE := ""
global EXT_LOG_POS_FILE := ""
global PIP_CACHE_DIR := ""
global PIP_TMP_DIR := ""
global PIP_PROG_LAST_SZ := 0
global PIP_PROG_LAST_TICK := 0
global PIP_PROG_MAP := Map()

for a in A_Args {
    t := Trim(a)
    tl := StrLower(t)
    if tl = "hosted"
        EXT_HOSTED := true
    else if RegExMatch(t, "i)^until=(.+)$", &m)
        EXT_UNTIL := StrLower(Trim(m[1]))
}

; 部署节点顺序（点击后面节点时前置全部要跑）
DeployStepOrder() {
    return ["aria2c", "python", "getpip", "wheels", "model", "pip", "script"]
}
ShouldRunDeployStep(id) {
    global EXT_UNTIL
    id := StrLower(String(id))
    if EXT_UNTIL = ""
        return true
    order := DeployStepOrder()
    target := StrLower(EXT_UNTIL)
    want := []
    for s in order {
        want.Push(s)
        if s = target
            break
    }
    if target = "model" || target = "pip" || target = "script" {
        want := ["aria2c", "python", "getpip", "wheels", "model", "pip", "script"]
        trimmed := []
        for s in want {
            trimmed.Push(s)
            if s = target
                break
        }
        want := trimmed
    }
    for s in want {
        if s = id
            return true
    }
    return false
}

; 有 HELPME_HOME → %HELPME_HOME%\ahk_ext\data；否则脚本旁 data\
ResolveExtDataRoot() {
    home := ""
    try home := EnvGet("HELPME_HOME")
    home := Trim(String(home))
    if home != "" {
        home := RTrim(home, "\/")
        dir := home "\ahk_ext\data"
        try DirCreate dir
        return dir
    }
    dir := A_ScriptDir "\data"
    try DirCreate dir
    return dir
}

; AI 资源根：有 HELPME_HOME → …\ahk_ext\ai\；否则脚本旁 ai\
;   python\  便携 Python
;   model\   大模型 / wheel
;   source\  第三方源码目录
;   script\  本地运行脚本（如 remove_bg.py）
ResolveAiRoot() {
    home := ""
    try home := EnvGet("HELPME_HOME")
    home := Trim(String(home))
    if home != ""
        dir := RTrim(home, "\/") "\ahk_ext\ai"
    else
        dir := A_ScriptDir "\ai"
    try DirCreate dir
    for sub in ["python", "model", "source", "script"] {
        try DirCreate(dir "\" sub)
    }
    return dir
}
ResolveTargetDir() {
    return ResolveAiRoot()
}

InitExtLog() {
    global EXT_LOG_FILE, EXT_LOG_POS_FILE
    root := ResolveExtDataRoot()
    dir := root "\image_proc"
    try DirCreate dir
    EXT_LOG_FILE := dir "\ext.log"
    EXT_LOG_POS_FILE := dir "\ext.log.pos"
    try FileDelete EXT_LOG_FILE
    try FileDelete EXT_LOG_POS_FILE
    try FileAppend "", EXT_LOG_FILE, "UTF-8"
}

Log(text) {
    global EXT_LOG_FILE, EXT_HOSTED
    line := "[" FormatTime(, "HH:mm:ss") "] " String(text)
    try {
        if EXT_LOG_FILE != ""
            FileAppend line "`n", EXT_LOG_FILE, "UTF-8"
    } catch {
    }
    if !EXT_HOSTED {
        try FileAppend line "`n", "*", "UTF-8"
    }
}

; 流程节点信令（UI 解析，不展示明细）；state=active|done|error|skip
Pipe(id, state := "active") {
    Log("[PIPE] " String(id) "|" String(state))
}

; pip 子包进度（UI 在节点后打勾）；不进日志正文
PipePkg(stepId, pkg, state := "done") {
    Log("[PIPEPKG] " String(stepId) "|" String(pkg) "|" String(state))
}

PipPkgName(spec) {
    spec := Trim(String(spec))
    if spec = ""
        return ""
    if RegExMatch(spec, "i)^([A-Za-z0-9_.-]+)", &m)
        return m[1]
    return spec
}

MarkPipePkgs(stepId, pkgList, state := "done") {
    for spec in pkgList {
        name := PipPkgName(spec)
        if name != ""
            PipePkg(stepId, name, state)
    }
}

; 每个包单独 pip install，装完立刻打勾
PipInstallPackages(pyExe, pyDir, outLog, pkgList, mirrors, stepId, extraFlags := "") {
    n := pkgList.Length
    i := 0
    for spec in pkgList {
        i += 1
        name := PipPkgName(spec)
        if StrLower(name) = "opencv-python-headless" && !InStr(spec, "=")
            spec := "opencv-python-headless==4.10.0.84"
        PipePkg(stepId, name, "active")
        Log("[>] pip 安装 " name " [" i "/" n "]")
        if StrLower(name) = "opencv-python-headless" {
            if PipInstallOpencvWheel(pyExe, pyDir, outLog) {
                PipePkg(stepId, name, "done")
                Log("[√] " name " 已安装")
                continue
            }
            Log("[!] aria2c 拉 opencv wheel 失败，改用阿里云 pip…")
            spec := "opencv-python-headless==4.10.0.84"
            mirrors := ['-i https://mirrors.aliyun.com/pypi/simple/ --trusted-host mirrors.aliyun.com', '-i https://pypi.org/simple']
        }
        ok := false
        mi := 0
        flags := extraFlags
        global PIP_CACHE_DIR, PIP_TMP_DIR
        PIP_CACHE_DIR := pyDir "\pip_cache"
        PIP_TMP_DIR := pyDir "\pip_tmp"
        try DirCreate PIP_CACHE_DIR
        try DirCreate PIP_TMP_DIR
        flags := Trim(flags ' --cache-dir "' PIP_CACHE_DIR '"')
        if StrLower(name) = "facexlib" {
            flags := Trim(flags " --no-deps")
            Log("[i] facexlib 复用已装的 opencv-python-headless，跳过 opencv-python 5")
        }
        ; open-clip / openai-clip 会从 PyPI 拉 CPU 版 torch，冲掉 cu118 —— 禁止带依赖装
        if StrLower(name) = "open-clip-torch" || StrLower(name) = "openai-clip" || StrLower(name) = "clip" {
            if !InStr(flags, "--no-deps")
                flags := Trim(flags " --no-deps")
            Log("[i] " name " 使用 --no-deps，保留已装 CUDA torch")
        }
        for mirror in mirrors {
            mi += 1
            args := Trim(Format(
                '-u -m pip install --no-warn-script-location --progress-bar on --default-timeout=120 {1} "{2}" {3}',
                flags, spec, mirror))
            tip := "pip " name " [" i "/" n "]"
            if mirrors.Length > 1
                tip .= " 源" mi "/" mirrors.Length
            code := RunPyLogged(pyExe, args, pyDir, outLog, true, tip)
            if code = 0 {
                ok := true
                break
            }
            LogPipFailExcerpt(outLog)
            if mi < mirrors.Length
                Log("[!] " name " 失败，换源重试…")
        }
        if !ok {
            PipePkg(stepId, name, "error")
            throw Error("pip 安装 " spec " 失败")
        }
        PipePkg(stepId, name, "done")
        Log("[√] " name " 已安装")
    }
}

; 大 wheel 走 aria2c，避免 pip 静默下 38MB 还显示「解析依赖」
PipInstallOpencvWheel(pyExe, pyDir, outLog) {
    targetDir := ResolveTargetDir()
    aria2c := targetDir "\aria2c.exe"
    destDir := targetDir "\model"
    dest := destDir "\opencv_python_headless-4.10.0.84-cp37-abi3-win_amd64.whl"
    hashPath := "26/d0/22f68eb23eea053a31655960f133c0be9726c6a881547e6e9e7e2a946c4f/opencv_python_headless-4.10.0.84-cp37-abi3-win_amd64.whl"
    urls := [
        "https://mirrors.aliyun.com/pypi/packages/" hashPath,
        "https://mirrors.cloud.tencent.com/pypi/packages/" hashPath,
        "https://pypi.tuna.tsinghua.edu.cn/packages/" hashPath,
        "https://files.pythonhosted.org/packages/" hashPath,
        "https://ghfast.top/https://files.pythonhosted.org/packages/" hashPath
    ]
    try DirCreate destDir
    minBytes := 30 * 1024 * 1024
    if !(FileExist(dest) && FileGetSize(dest) >= minBytes) {
        Log("[*] aria2c 下载 opencv-python-headless 4.10.0.84（38.8 MB）…")
        if !DownloadFileSmart(dest, urls, aria2c, minBytes, 16, true)
            return false
    } else
        Log("[√] opencv wheel 已在本地，跳过下载")
    args := Format('-u -m pip install --no-warn-script-location --no-deps --progress-bar on "{1}"', dest)
    code := RunPyLogged(pyExe, args, pyDir, outLog, true, "pip install opencv wheel")
    if code != 0 {
        LogPipFailExcerpt(outLog)
        return false
    }
    MarkOpencvPythonSatisfied(pyDir)
    return true
}

; facexlib 依赖 opencv-python（带 GUI），与 headless 同提供 cv2；写假元数据避免再拉 5.x
MarkOpencvPythonSatisfied(pyDir) {
    site := RTrim(String(pyDir), "\/") "\Lib\site-packages"
    src := ""
    loop files site "\opencv_python_headless-*.dist-info", "D" {
        src := A_LoopFileFullPath
        break
    }
    ver := "4.10.0.84"
    if src != "" && RegExMatch(src, "i)opencv_python_headless-([0-9.]+)\.dist-info", &m)
        ver := m[1]
    dest := site "\opencv_python-" ver ".dist-info"
    if DirExist(dest)
        return
    try DirCreate dest
    meta := "Metadata-Version: 2.1`r`nName: opencv-python`r`nVersion: " ver "`r`n"
    try FileAppend meta, dest "\METADATA", "UTF-8-RAW"
    try FileAppend "pip`r`n", dest "\INSTALLER", "UTF-8-RAW"
    Log("[i] 已标记 opencv-python " ver "（复用 headless，不再下载）")
}

; ── 部署流程配置（deploy_pipe.json ↔ 脚本末尾 base64）────────────────
global DEPLOY_PIPE_TAG := "deploy_pipe.json"
global DEPLOY_PIPE_JSON := ""
global DEPLOY_PIPE_PATH := ""
global REMOVE_BG_TAG := "remove_bg.py"

DefaultDeployPipeJson() {
    return (
        "{"
        . '"version":1,'
        . '"steps":{'
        . '"aria2c":{"label":"aria2c 下载器","title":"aria2c 下载器","size":"~2.5 MB","local":"aria2c.exe","urls":['
        . '"https://gh.tszai.cn/https://github.com/aria2/aria2/releases/download/release-1.37.0/aria2-1.37.0-win-64bit-build1.zip",'
        . '"https://ghproxy.net/https://github.com/aria2/aria2/releases/download/release-1.37.0/aria2-1.37.0-win-64bit-build1.zip",'
        . '"https://github.com/aria2/aria2/releases/download/release-1.37.0/aria2-1.37.0-win-64bit-build1.zip"'
        . ']},'
        . '"python":{"label":"Python 3.10.11","title":"Python Embeddable 3.10.11","size":"~15-20 MB","local":"python\\python.exe","urls":['
        . '"https://www.python.org/ftp/python/3.10.11/python-3.10.11-embed-amd64.zip",'
        . '"https://mirrors.huaweicloud.com/python/3.10.11/python-3.10.11-embed-amd64.zip"'
        . ']},'
        . '"getpip":{"label":"pip 24.3","title":"安装 pip 24.3 (get-pip)","size":"~2 MB","local":"python\\Scripts\\pip.exe","note":"为便携 Python 安装 pip","urls":['
        . '"https://bootstrap.pypa.io/pip/3.10/get-pip.py",'
        . '"https://bootstrap.pypa.io/get-pip.py",'
        . '"https://mirrors.aliyun.com/pypi/get-pip.py",'
        . '"https://ghfast.top/https://bootstrap.pypa.io/get-pip.py"'
        . ']},'
        . '"wheels":{"label":"显卡加速","title":"PyTorch CUDA 11.8","size":"torch~2.5GB","local":"model\\torch-2.1.2+cu118-cp310-cp310-win_amd64.whl","urls":['
        . '"https://download.pytorch.org/whl/cu118/torch-2.1.2%2Bcu118-cp310-cp310-win_amd64.whl",'
        . '"https://download.pytorch.org/whl/cu118/torchvision-0.16.2%2Bcu118-cp310-cp310-win_amd64.whl"'
        . ']},'
        . '"model":{"label":"模型(BiRefNet)","title":"BiRefNet 权重","size":"~445 MB","local":"model\\model.safetensors","urls":['
        . '"https://hf-mirror.com/ZhengPeng7/BiRefNet/resolve/main/model.safetensors",'
        . '"https://huggingface.co/ZhengPeng7/BiRefNet/resolve/main/model.safetensors"'
        . ']},'
        . '"pip":{"label":"pip 依赖","title":"BiRefNet 推理依赖","size":"~100-200 MB","local":"python\\Lib\\site-packages","packages":['
        . '"typing_extensions","transformers==4.46.3","timm","einops","pillow","scipy","kornia"'
        . ']},'
        . '"script":{"label":"脚本","title":"remove_bg.py","size":"BiRefNet CLI","local":"script\\remove_bg.py","kind":"script","note":"可编辑脚本，保存后双向同步"}'
        . '}}'
    )
}

PortableCommentMark(tag) {
    return ";########################################################################################################### " String(tag)
}

ReadEmbeddedCommentB64(tag) {
    try content := FileRead(A_ScriptFullPath, "UTF-8")
    catch {
        return ""
    }
    mark := PortableCommentMark(tag)
    p1 := InStr(content, mark)
    if !p1
        return ""
    p2 := InStr(content, mark, false, p1 + StrLen(mark))
    if !p2
        return ""
    body := SubStr(content, p1 + StrLen(mark), p2 - p1 - StrLen(mark))
    body := RegExReplace(body, "^\s*;?", "")
    body := RegExReplace(body, "[\r\n;]+", "")
    body := RegExReplace(body, "\s+", "")
    if body = "" || body = "xxxxx"
        return ""
    return body
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

B64EncodeUtf8Text(text) {
    raw := StrReplace(String(text), "`r`n", "`n")
    raw := StrReplace(raw, "`r", "`n")
    buf := Buffer(StrPut(raw, "UTF-8") - 1)
    StrPut(raw, buf, "UTF-8")
    cch := 0
    if !DllCall("crypt32\CryptBinaryToStringW", "Ptr", buf, "UInt", buf.Size, "UInt", 0x40000001, "Ptr", 0, "UInt*", &cch)
        return ""
    wbuf := Buffer(cch * 2, 0)
    if !DllCall("crypt32\CryptBinaryToStringW", "Ptr", buf, "UInt", buf.Size, "UInt", 0x40000001, "Ptr", wbuf, "UInt*", &cch)
        return ""
    return RegExReplace(StrGet(wbuf, "UTF-16"), "[\r\n\s]+")
}

UpdateEmbeddedCommentB64(tag, newB64) {
    path := A_ScriptFullPath
    try content := FileRead(path, "UTF-8")
    catch {
        return
    }
    mark := PortableCommentMark(tag)
    b64 := RegExReplace(String(newB64), "\s+")
    if b64 = ""
        b64 := "xxxxx"
    replacement := mark "`n;" b64 "`n" mark
    p1 := InStr(content, mark)
    if !p1 {
        if !RegExMatch(content, "`r?`n$")
            content .= "`n"
        content .= "`n" replacement "`n"
} else {
        p2 := InStr(content, mark, false, p1 + StrLen(mark))
        if !p2
            content := SubStr(content, 1, p1 - 1) . replacement . SubStr(content, p1 + StrLen(mark))
        else
            content := SubStr(content, 1, p1 - 1) . replacement . SubStr(content, p2 + StrLen(mark))
    }
    try {
        f := FileOpen(path, "w", "UTF-8")
        f.Write(content)
        f.Close()
    } catch {
    }
}

SplitJsonQuotedStrings(inner) {
    arr := []
    pos := 1
    while RegExMatch(inner, '"((?:\\.|[^"\\])*)"', &m, pos) {
        s := m[1]
        s := StrReplace(s, "\\/", "/")
        s := StrReplace(s, "\\n", "`n")
        s := StrReplace(s, '\\"', '"')
        s := StrReplace(s, "\\\\", "\")
        arr.Push(s)
        pos := m.Pos + m.Len
    }
    return arr
}

CfgStepList(stepId, key := "urls") {
    global DEPLOY_PIPE_JSON
    raw := DEPLOY_PIPE_JSON
    if raw = ""
        raw := DefaultDeployPipeJson()
    stepId := String(stepId)
    key := String(key)
    if !RegExMatch(raw, '"' stepId '"\s*:\s*\{', &sm)
        return []
    sub := SubStr(raw, sm.Pos, 4000)
    if !RegExMatch(sub, '"' key '"\s*:\s*\[([^\]]*)\]', &am)
        return []
    return SplitJsonQuotedStrings(am[1])
}

; 旧配置若仍含 SUPIR 步骤则剥掉（模型已弃用）
MergeMissingDeployPipeSteps() {
    global DEPLOY_PIPE_JSON
    if DEPLOY_PIPE_JSON = ""
        return
    if !InStr(DEPLOY_PIPE_JSON, '"supir_')
        return
    for id in ["supir_repo", "supir_pip", "supir_script", "supir_weights"] {
        DEPLOY_PIPE_JSON := RegExReplace(DEPLOY_PIPE_JSON, ',"' id '"\s*:\s*\{[^{}]*\}', "")
        DEPLOY_PIPE_JSON := RegExReplace(DEPLOY_PIPE_JSON, '"' id '"\s*:\s*\{[^{}]*\},?', "")
    }
}

SyncDeployPipeConfig() {
    global DEPLOY_PIPE_TAG, DEPLOY_PIPE_JSON, DEPLOY_PIPE_PATH, EXT_LOG_FILE
    root := ResolveExtDataRoot()
    dir := root "\image_proc"
    try DirCreate dir
    DEPLOY_PIPE_PATH := dir "\deploy_pipe.json"
    if FileExist(DEPLOY_PIPE_PATH) {
        try DEPLOY_PIPE_JSON := FileRead(DEPLOY_PIPE_PATH, "UTF-8")
        catch {
            DEPLOY_PIPE_JSON := ""
        }
        if DEPLOY_PIPE_JSON != "" {
            MergeMissingDeployPipeSteps()
            try {
                f := FileOpen(DEPLOY_PIPE_PATH, "w", "UTF-8")
                f.Write(DEPLOY_PIPE_JSON)
                f.Close()
            } catch {
            }
            b64 := B64EncodeUtf8Text(DEPLOY_PIPE_JSON)
            cur := ReadEmbeddedCommentB64(DEPLOY_PIPE_TAG)
            if b64 != "" && b64 != cur
                UpdateEmbeddedCommentB64(DEPLOY_PIPE_TAG, b64)
            return
        }
    }
    emb := ReadEmbeddedCommentB64(DEPLOY_PIPE_TAG)
    txt := (emb != "") ? B64DecodeToUtf8Text(emb) : ""
    if txt = ""
        txt := DefaultDeployPipeJson()
    DEPLOY_PIPE_JSON := txt
    MergeMissingDeployPipeSteps()
    try {
        f := FileOpen(DEPLOY_PIPE_PATH, "w", "UTF-8")
        f.Write(DEPLOY_PIPE_JSON)
        f.Close()
    } catch {
    }
    b64 := B64EncodeUtf8Text(txt)
    if b64 != ""
        UpdateEmbeddedCommentB64(DEPLOY_PIPE_TAG, b64)
}

; remove_bg.py：磁盘优先，否则从嵌入块还原，再双向写回
SyncRemoveBgPy() {
    global REMOVE_BG_TAG
    targetDir := ResolveTargetDir()
    dest := targetDir "\script\remove_bg.py"
    ship := A_ScriptDir "\ai\script\remove_bg.py"
    try DirCreate(targetDir "\script")
    txt := ""
    if FileExist(dest) {
        try txt := FileRead(dest, "UTF-8")
        catch {
            txt := ""
        }
    }
    if txt = "" && FileExist(ship) {
        try txt := FileRead(ship, "UTF-8")
        catch {
            txt := ""
        }
    }
    if txt = "" {
        emb := ReadEmbeddedCommentB64(REMOVE_BG_TAG)
        if emb != ""
            txt := B64DecodeToUtf8Text(emb)
    }
    if txt = ""
        throw Error("缺少 remove_bg.py（磁盘与嵌入块均无）")
    try {
        if !DirExist(targetDir)
            DirCreate targetDir
        f := FileOpen(dest, "w", "UTF-8")
        f.Write(txt)
        f.Close()
    } catch as e {
        throw Error("写入 " dest " 失败: " e.Message)
    }
    if ship != dest {
        try {
            f := FileOpen(ship, "w", "UTF-8")
            f.Write(txt)
            f.Close()
        } catch {
        }
    }
    b64 := B64EncodeUtf8Text(txt)
    if b64 != ""
        UpdateEmbeddedCommentB64(REMOVE_BG_TAG, b64)
    Log("[√] remove_bg.py 已同步")
}

; ── 启动 ──────────────────────────────────────────────
if !EXT_HOSTED
    try DllCall("AllocConsole")

InitExtLog()
SyncDeployPipeConfig()
; 不再 Pipe(reset)：避免点某一节点时把其它已完成节点状态清零；UI 保留绿点，本脚本按步骤再发 active/done/skip

; hosted 且未指定 until=：不自动全量下载，仅提示后退出（主页按节点点击再下）
if EXT_HOSTED && EXT_UNTIL = "" {
    Log("[i] 未指定 until= 节点，跳过自动部署（默认不下载）")
    Pipe("all", "done")
    SetTimer(ExtIdleExit, -2000)
} else {

Log("[*] 开始部署扩展环境…" (EXT_UNTIL != "" ? (" → until=" EXT_UNTIL) : ""))

targetDir := ResolveTargetDir()
if !DirExist(targetDir)
    DirCreate(targetDir)

aria2cExe := targetDir "\aria2c.exe"
if ShouldRunDeployStep("aria2c") {
    try {
        Pipe("aria2c", "active")
        if FileExist(aria2cExe) {
            Log("[√] aria2c 已就绪")
            Pipe("aria2c", "skip")
        } else {
        EnsureAria2cNative(targetDir)
            Log("[√] aria2c 部署完成")
            Pipe("aria2c", "done")
        }
    } catch as Err {
        Log("[X] aria2c 部署失败: " Err.Message)
        Pipe("aria2c", "error")
    }
}

; Python Embeddable（依赖 aria2c；失败不阻断进程）
if ShouldRunDeployStep("python") {
    try {
        Pipe("python", "active")
        EnsurePythonEnv(targetDir)
        Pipe("python", "done")
    } catch as Err {
        Log("[X] Python 环境部署失败: " Err.Message)
        Pipe("python", "error")
    }
}

; 为 embed Python 安装 pip（get-pip）
if ShouldRunDeployStep("getpip") {
    try {
        Pipe("getpip", "active")
        EnsureGetPip(targetDir)
        Pipe("getpip", "done")
    } catch as Err {
        Log("[X] pip 安装失败: " Err.Message)
        Pipe("getpip", "error")
    }
}

; PyTorch CUDA 11.8 wheel → model\，再用 embed python 安装
; 点后面节点（pip/model…）时：只要已能 import torch 就跳过，避免误重装显卡加速卡住
if ShouldRunDeployStep("wheels") {
    try {
        Pipe("wheels", "active")
        if EXT_UNTIL != "" && EXT_UNTIL != "wheels" && TorchPackagePresent(targetDir) {
            Log("[√] 已检测到 torch，跳过显卡加速（本次目标 until=" EXT_UNTIL "）")
            Pipe("wheels", "skip")
        } else {
            EnsureTorchCuda118(targetDir)
            Pipe("wheels", "done")
        }
    } catch as Err {
        Log("[X] PyTorch CUDA 11.8 部署失败: " Err.Message)
        Pipe("wheels", "error")
    }
}

; BiRefNet 权重（aria2c 16 线程，国内 hf-mirror）
if ShouldRunDeployStep("model") {
    try {
        Pipe("model", "active")
        EnsureBiRefNetModel(targetDir)
        Pipe("model", "done")
    } catch as Err {
        Log("[X] BiRefNet 模型下载失败: " Err.Message)
        Pipe("model", "error")
    }
}

; BiRefNet 推理依赖（transformers / timm / einops / pillow / scipy）
if ShouldRunDeployStep("pip") {
    try {
        Pipe("pip", "active")
        EnsureBiRefNetDeps(targetDir)
        Pipe("pip", "done")
    } catch as Err {
        Log("[X] BiRefNet 依赖安装失败: " Err.Message)
        Pipe("pip", "error")
    }
}

; 抠图脚本 remove_bg.py（磁盘 ↔ 嵌入块）
if ShouldRunDeployStep("script") {
    try {
        Pipe("script", "active")
        SyncRemoveBgPy()
        if FileExist(targetDir "\script\remove_bg.py")
            Pipe("script", "done")
        else
            Pipe("script", "error")
    } catch as Err {
        Log("[X] remove_bg.py 同步失败: " Err.Message)
        Pipe("script", "error")
    }
}

Pipe("all", "done")
Log("[OK] 全部任务结束")
if EXT_HOSTED {
    SetTimer(ExtIdleExit, -15000)
} else {
    Log("[*] 按回车退出…")
    try FileOpen("*", "r").ReadLine()
ExitApp()
}
} ; end else (has until= or interactive)

ExtIdleExit(*) {
    ExitApp()
}

; =====================================================================
; aria2c 下载（多 URL 回退）；成功返回 true
; =====================================================================
; connections: 并发连接数（大文件建议 16）；resume=true 断点续传不删半成品
Aria2Download(aria2c, destFile, urls, minBytes := 100000, connections := 8, resume := false) {
    if !IsObject(urls)
        urls := [String(urls)]
    SplitPath destFile, &outName, &outDir
    if outDir = ""
        outDir := A_WorkingDir
    try DirCreate outDir
    conn := Max(1, Integer(connections))
    tipName := outName != "" ? outName : "文件"
    for idx, url in urls {
        if urls.Length > 1
            Log("[>] 下载 " tipName " 进行中… [" idx "/" urls.Length "]")
        else
            Log("[>] 下载 " tipName " 进行中…")
        if !resume {
            try {
                if FileExist(destFile)
                    FileDelete destFile
            } catch {
            }
        }
        ; -c 续传；大文件加长 timeout
        cmd := Format('"{1}" -c -x {2} -s {2} -k 1M --connect-timeout=20 --timeout=300 --max-tries=5 --allow-overwrite=true --auto-file-renaming=false --check-certificate=false --user-agent="Mozilla/5.0" --show-console-readout=false --summary-interval=1 --console-log-level=notice -d "{3}" -o "{4}" "{5}"'
            , aria2c, conn, outDir, outName, url)
        srcHint := urls.Length > 1 ? ("[" idx "/" urls.Length "]") : ""
        exitCode := Aria2RunWithProgress(cmd, outDir, destFile, minBytes, tipName, srcHint)
        if FileExist(destFile) {
            got := FileGetSize(destFile)
            if got >= minBytes {
                Log("[√] " tipName " 下载完成")
                return true
            }
            Log("[!] " tipName " 不完整，换源重试…")
        } else {
            Log("[!] " tipName " 下载失败，换源重试…")
        }
        if !resume {
            try {
                if FileExist(destFile)
                    FileDelete destFile
            } catch {
            }
        }
    }
    return false
}

FmtDlBytes(n) {
    n := Number(n)
    if n < 0
        return "?"
    if n >= 1073741824
        return Round(n / 1073741824, 2) " GB"
    if n >= 1048576
        return Round(n / 1048576, 2) " MB"
    if n >= 1024
        return Round(n / 1024, 1) " KB"
    return Round(n) " B"
}

FmtDlSpeed(bps) {
    if bps < 0
        return "—"
    return FmtDlBytes(bps) "/s"
}

ParseAria2SizeToken(tok) {
    tok := Trim(String(tok))
    m := ""
    if !RegExMatch(tok, "i)^([\d.]+)\s*([KMGT]i?B|B)$", &m)
        return -1
    n := Number(m[1])
    u := StrUpper(m[2])
    if u = "B"
        return n
    if InStr(u, "K")
        return n * 1024
    if InStr(u, "M")
        return n * 1048576
    if InStr(u, "G")
        return n * 1073741824
    if InStr(u, "T")
        return n * 1099511627776
    return -1
}

ReadFileTail(path, maxBytes := 8192) {
    if path = "" || !FileExist(path)
        return ""
    f := FileOpen(path, "r")
    if !f
        return ""
    try {
        sz := f.Length
        if sz > maxBytes
            f.Pos := sz - maxBytes
        return f.Read()
    } finally {
        f.Close()
    }
}

ParseAria2Progress(logPath) {
    info := Map("got", -1, "total", -1, "pct", -1, "speed", -1, "eta", "", "cn", -1, "done", false)
    txt := ReadFileTail(logPath)
    if txt = ""
        return info
    if RegExMatch(txt, "i)download completed|\(OK\):download completed|Download Results:")
        info["done"] := true
    last := ""
    loop parse txt, "`n", "`r" {
        line := Trim(A_LoopField)
        if InStr(line, "[#") && (InStr(line, "DL:") || InStr(line, "/"))
            last := line
    }
    if last = ""
        return info
    m := ""
    if RegExMatch(last, "i)\[#[^\s\]]+\s+([0-9.]+[KMGT]i?B)\/([0-9.]+[KMGT]i?B)(?:\((\d+)%\))?", &m) {
        info["got"] := ParseAria2SizeToken(m[1])
        info["total"] := ParseAria2SizeToken(m[2])
        if m.Count >= 3 && m[3] != ""
            info["pct"] := Integer(m[3])
    }
    m2 := ""
    if RegExMatch(last, "i)DL:([0-9.]+[KMGT]i?B)", &m2)
        info["speed"] := ParseAria2SizeToken(m2[1])
    m3 := ""
    if RegExMatch(last, "i)ETA:([0-9hms]+)", &m3)
        info["eta"] := m3[1]
    m4 := ""
    if RegExMatch(last, "i)CN:(\d+)", &m4)
        info["cn"] := Integer(m4[1])
    return info
}

; 后台跑 aria2；每 2 秒刷已下/总量/速度；收尾写明在合并还是退出
Aria2RunWithProgress(cmd, workDir, destFile, minBytes, label := "文件", srcHint := "") {
    pid := 0
    logPath := destFile ".dl.log"
    try FileDelete logPath
    wrapped := Format('{1} /s /c "{2} 1> "{3}" 2>&1"', A_ComSpec, cmd, logPath)
    try Run(wrapped, workDir, "Hide", &pid)
    catch as e {
        Log("[!] 下载启动失败: " e.Message)
        return 1
    }
    if !pid {
        try return RunWait(cmd, workDir, "Hide")
        catch {
            return 1
        }
    }
    lastSz := 0
    lastSzTick := A_TickCount
    fileSpeed := 0
    stallSince := 0
    prevPollSz := -1
    lastBeat := 0
    t0 := A_TickCount
    prefix := Trim("[>] 下载 " label (srcHint != "" ? " " srcHint : ""))
    loop {
        if !ProcessExist(pid)
            break
        Sleep 2000
        sz := 0
        hasFile := false
        try {
            if FileExist(destFile) {
                hasFile := true
                sz := FileGetSize(destFile)
            }
        } catch {
        }
        now := A_TickCount
        dt := (now - lastSzTick) / 1000
        if dt >= 1 {
            if sz >= lastSz
                fileSpeed := (sz - lastSz) / dt
            lastSz := sz
            lastSzTick := now
        }
        if hasFile && sz > 0 && sz = prevPollSz {
            if stallSince = 0
                stallSince := now
        } else {
            stallSince := 0
        }
        prevPollSz := sz
        if (now - lastBeat) < 2000
            continue
        lastBeat := now
        aria := ParseAria2Progress(logPath)
        got := aria["got"] >= 0 ? aria["got"] : (hasFile ? sz : -1)
        total := aria["total"]
        spd := aria["speed"] >= 0 ? aria["speed"] : fileSpeed
        hasCtrl := FileExist(destFile ".aria2")
        pct := aria["pct"]
        if pct < 0 && total > 0 && got >= 0
            pct := Min(100, Floor(got * 100 / total))
        finishing := aria["done"] || pct >= 100 || (stallSince > 0 && (now - stallSince) >= 6000 && sz > 0)
        if (now - t0) > 7200000 {
            Log("[!] 下载超时")
            try ProcessClose(pid)
            break
        }
        if finishing {
            why := ""
            if aria["done"] || pct >= 100
                why := "传输已到 100%，aria2 正在写盘并退出"
            else if hasCtrl
                why := "文件大小暂时停住，控制文件 .aria2 还在，正在合并分片/刷盘"
            else
                why := "文件大小已停在 " FmtDlBytes(sz) "，等待 aria2 进程退出"
            extra := ""
            if got >= 0 {
                extra := " 已下 " FmtDlBytes(got)
                if total > 0
                    extra .= " / 共 " FmtDlBytes(total)
            }
            Log("[>] " label " 收尾：" why extra)
            continue
        }
        if got < 0 || (got = 0 && total <= 0)
            Log(prefix " 进行中… 正在连接源站 / 等待首包")
        else {
            bits := prefix " 进行中… 已下 " FmtDlBytes(got)
            if total > 0
                bits .= " / 共 " FmtDlBytes(total)
            else
                bits .= " / 总量未知"
            if pct >= 0
                bits .= " (" pct "%)"
            bits .= "  速度 " FmtDlSpeed(spd)
            if aria["eta"] != ""
                bits .= "  剩余 " aria["eta"]
            if aria["cn"] >= 0
                bits .= "  连接 " aria["cn"]
            Log(bits)
        }
    }
    try ProcessWaitClose(pid, 8)
    if FileExist(destFile) && FileGetSize(destFile) >= minBytes {
        try FileDelete logPath
        return 0
    }
    lastErr := ""
    tail := ReadFileTail(logPath)
    if tail != "" {
        loop parse tail, "`n", "`r" {
            line := Trim(A_LoopField)
            if line != "" && (InStr(line, "ERROR") || InStr(line, "error") || InStr(line, "failed") || InStr(line, "403") || InStr(line, "404"))
                lastErr := line
        }
        if lastErr != ""
            Log("[!] aria2: " lastErr)
    }
    try FileDelete logPath
    return 1
}

CurlDownload(destFile, urls, minBytes := 100000) {
    if !IsObject(urls)
        urls := [String(urls)]
    SplitPath destFile, &outName
    tipName := outName != "" ? outName : "文件"
    for idx, url in urls {
        hint := urls.Length > 1 ? ("[" idx "/" urls.Length "]") : ""
        Log("[>] 下载 " tipName " 进行中…（curl）" (hint != "" ? " " hint : ""))
        try {
            if FileExist(destFile)
                FileDelete destFile
        } catch {
        }
        ; -A / -L：pytorch S3 对部分客户端较挑剔；--fail 让 HTTP 错误变非 0
        cmd := 'curl.exe -L --fail --connect-timeout 15 --max-time 600 -A "Mozilla/5.0" -o "' destFile '" "' url '"'
        pid := 0
        exitCode := 1
        try Run(A_ComSpec ' /s /c "' cmd '"', , "Hide", &pid)
        catch as e {
            Log("[!] curl 异常: " e.Message)
            continue
        }
        lastSz := 0
        lastTick := A_TickCount
        t0 := A_TickCount
        lastBeat := 0
        if pid {
            loop {
                if !ProcessExist(pid)
                    break
                Sleep 2000
                sz := 0
                try {
                    if FileExist(destFile)
                        sz := FileGetSize(destFile)
                } catch {
                }
                now := A_TickCount
                spd := 0
                dt := (now - lastTick) / 1000
                if dt >= 1 {
                    spd := Max(0, sz - lastSz) / dt
                    lastSz := sz
                    lastTick := now
                }
                if (now - lastBeat) >= 2000 {
                    lastBeat := now
                    if sz <= 0
                        Log("[>] 下载 " tipName " 进行中…（curl） 正在连接 / 等待首包")
                    else
                        Log("[>] 下载 " tipName " 进行中…（curl） 已下 " FmtDlBytes(sz) " / 总量未知  速度 " FmtDlSpeed(spd))
                }
                if (now - t0) > 7200000 {
                    Log("[!] 下载超时")
                    try ProcessClose(pid)
                    break
                }
            }
            try exitCode := ProcessWaitClose(pid, 8)
            catch {
                exitCode := 1
            }
        }
        if FileExist(destFile) {
            got := FileGetSize(destFile)
            if got >= minBytes {
                Log("[√] " tipName " 下载完成")
                return true
            }
        }
        Log("[!] " tipName " 下载失败，换源重试…")
        try {
            if FileExist(destFile)
                FileDelete destFile
        } catch {
        }
    }
    return false
}

DownloadFileSmart(destFile, urls, aria2c := "", minBytes := 100000, connections := 8, resume := false) {
    if aria2c != "" && FileExist(aria2c) {
        if Aria2Download(aria2c, destFile, urls, minBytes, connections, resume)
            return true
        Log("[!] aria2c 全部节点失败，改用 curl…")
    }
    return CurlDownload(destFile, urls, minBytes)
}

; =====================================================================
; BiRefNet model.safetensors → ai\model\
; 优先 hf-mirror.com，16 线程
; =====================================================================
EnsureBiRefNetModel(targetDir) {
    aria2c := targetDir "\aria2c.exe"
    modelDir := targetDir "\model"
    birefDir := modelDir "\BiRefNet"
    dest := modelDir "\model.safetensors"
    destPacked := birefDir "\model.safetensors"
    ; FP16 权重约 444MB
    minBytes := 400 * 1024 * 1024

    Log("[*] 部署 BiRefNet 模型…")
    try DirCreate modelDir
    try DirCreate birefDir

    if !(FileExist(dest) && FileGetSize(dest) >= minBytes) {
        if !FileExist(aria2c)
            throw Error("未找到 aria2c.exe，无法高速拉取模型")
        urls := CfgStepList("model", "urls")
        if urls.Length < 1
    urls := [
                "https://hf-mirror.com/ZhengPeng7/BiRefNet/resolve/main/model.safetensors",
                "https://huggingface.co/ZhengPeng7/BiRefNet/resolve/main/model.safetensors"
            ]
        if !DownloadFileSmart(dest, urls, aria2c, minBytes, 16, true)
            throw Error("BiRefNet model.safetensors 下载失败")
    } else {
        Log("[√] BiRefNet 权重已就绪")
    }

    ; from_pretrained 需要完整目录：config.json / birefnet.py / BiRefNet_config.py + 权重
    if !(FileExist(destPacked) && FileGetSize(destPacked) >= minBytes) {
        try FileCopy dest, destPacked, true
        catch {
            ; 同卷优先硬链接省空间
            try RunWait(A_ComSpec ' /c mklink /H "' destPacked '" "' dest '"', , "Hide")
        }
    }
    EnsureBiRefNetSidecars(birefDir)
    Log("[√] BiRefNet 模型就绪")
}

EnsureBiRefNetSidecars(birefDir) {
    try DirCreate birefDir
    files := Map(
        "config.json", 100,
        "birefnet.py", 10000,
        "BiRefNet_config.py", 100,
        "handler.py", 1000
    )
    for name, minSz in files {
        dest := birefDir "\" name
        if FileExist(dest) && FileGetSize(dest) >= minSz
            continue
        urls := [
            "https://hf-mirror.com/ZhengPeng7/BiRefNet/resolve/main/" name,
            "https://huggingface.co/ZhengPeng7/BiRefNet/resolve/main/" name
        ]
        Log("[>] 拉取 " name "…")
        if !CurlDownload(dest, urls, minSz)
            throw Error("BiRefNet 缺少 " name)
        Log("[√] " name)
    }
}

; 是否已有可 import 的 torch（不要求 CUDA；供「装后面节点」时跳过 wheels）
TorchPackagePresent(targetDir) {
    pyExe := targetDir "\python\python.exe"
    if !FileExist(pyExe)
        return false
    probe := targetDir "\model\_torch_present_probe.py"
    try FileDelete probe
    try FileAppend(
        "import sys`r`n"
        "try:`r`n"
        "    import torch`r`n"
        "    print(getattr(torch,'__version__',''))`r`n"
        "    sys.exit(0)`r`n"
        "except Exception:`r`n"
        "    sys.exit(1)`r`n",
        probe, "UTF-8-RAW")
    catch {
        return false
    }
    code := 1
    try code := RunWait('"' pyExe '" -u "' probe '"', targetDir "\python", "Hide")
    catch {
        code := 1
    }
    try FileDelete probe
    return code = 0
}

; wheel 是否完整 zip（缺 EOCD 的半成品会导致 pip invalid 并卡死）
TorchWheelLooksValid(path, minBytes) {
    path := String(path)
    if !FileExist(path)
        return false
    try {
        if FileGetSize(path) < minBytes
            return false
    } catch {
        return false
    }
    ; 读文件尾 22 字节，ZIP EOCD 签名应为 50 4B 05 06
    try {
        f := FileOpen(path, "r")
        if !IsObject(f)
            return false
        if f.Length < 22 {
            f.Close()
            return false
        }
        f.Pos := f.Length - 22
        sig := f.ReadUInt()
        f.Close()
        ; ReadUInt 小端：0x06054B50
        return (sig & 0xFFFFFFFF) = 0x06054B50
    } catch {
        return false
    }
}

; =====================================================================
; PyTorch CUDA 11.8（方案 A）wheel → ahk_ext\ai\model\
; aria2c -s16 -x16 -k1M，再用 python 本地 pip 安装
; =====================================================================
EnsureTorchCuda118(targetDir) {
    aria2c := targetDir "\aria2c.exe"
    pyExe := targetDir "\python\python.exe"
    modelDir := targetDir "\model"
    torchWhl := modelDir "\torch-2.1.2+cu118-cp310-cp310-win_amd64.whl"
    visionWhl := modelDir "\torchvision-0.16.2+cu118-cp310-cp310-win_amd64.whl"
    ; torch 实测约 2.5–2.6GB；torchvision cu118 whl 实测约 4.9MB（不是 15MB）
    torchMin := 2400 * 1024 * 1024
    visionMin := 3 * 1024 * 1024

    Log("[*] 部署 PyTorch CUDA 11.8…")
    try DirCreate modelDir

    if !FileExist(aria2c)
        throw Error("未找到 aria2c.exe")
    if !FileExist(pyExe)
        throw Error("未找到 python\python.exe，请先完成 Python 部署")

    wheelUrls := CfgStepList("wheels", "urls")
    torchUrls := []
    visionUrls := []
    for u in wheelUrls {
        if InStr(StrLower(u), "torchvision")
            visionUrls.Push(u)
        else if InStr(StrLower(u), "torch")
            torchUrls.Push(u)
    }
    if torchUrls.Length < 1
        torchUrls := ["https://download.pytorch.org/whl/cu118/torch-2.1.2%2Bcu118-cp310-cp310-win_amd64.whl"]
    if visionUrls.Length < 1
        visionUrls := ["https://download.pytorch.org/whl/cu118/torchvision-0.16.2%2Bcu118-cp310-cp310-win_amd64.whl"]

    if TorchWheelLooksValid(torchWhl, torchMin) {
        Log("[√] torch wheel 已就绪")
        } else {
        if FileExist(torchWhl) {
            Log("[!] torch wheel 损坏或不完整，删除后重下…")
            try FileDelete torchWhl
        }
        if !DownloadFileSmart(torchWhl, torchUrls, aria2c, torchMin, 16, true)
            throw Error("torch wheel 下载失败")
        if !TorchWheelLooksValid(torchWhl, torchMin)
            throw Error("torch wheel 下载后仍无效")
    }

    if FileExist(visionWhl) && FileGetSize(visionWhl) >= visionMin {
        Log("[√] torchvision wheel 已就绪")
    } else {
        if !DownloadFileSmart(visionWhl, visionUrls, aria2c, visionMin, 16, true)
            throw Error("torchvision wheel 下载失败")
    }

    Log("[>] 检测 torch / CUDA…")
    probePy := modelDir "\_torch_probe.py"
    try FileDelete probePy
    FileAppend (
        "import sys`r`n"
        "try:`r`n"
        "    import torch`r`n"
        "    print(torch.__version__)`r`n"
        "    print(torch.cuda.is_available())`r`n"
        "    sys.exit(0)`r`n"
        "except Exception as e:`r`n"
        "    print('ERR', e)`r`n"
        "    sys.exit(1)`r`n"
    ), probePy, "UTF-8-RAW"

    already := false
    try {
        chkLog := modelDir "\torch_probe.out.log"
        code := RunPyLogged(pyExe, '"' probePy '"', targetDir "\python", chkLog, true, "检测 torch")
        if code = 0 && FileExist(chkLog) {
            body := FileRead(chkLog, "UTF-8")
            if InStr(body, "2.1.2") && RegExMatch(body, "i)True")
                already := true
        }
    } catch as e {
        Log("[!] 检测失败: " e.Message)
    }
    if already {
        Log("[√] torch 2.1.2+CUDA 已可用，跳过安装")
        try FileDelete probePy
        return
    }

    outLog := modelDir "\torch_pip.out.log"
    argsTorch := Format('-u -m pip install --no-warn-script-location --no-cache-dir --progress-bar off "{1}"', torchWhl)
    exitCode := RunPyLogged(pyExe, argsTorch, targetDir "\python", outLog, true, "pip install torch-2.1.2+cu118")
    if exitCode != 0
        throw Error("pip 安装 torch 失败 exit=" exitCode)
    Log("[√] torch 安装完成")

    argsVision := Format('-u -m pip install --no-warn-script-location --no-cache-dir --progress-bar off "{1}"', visionWhl)
    exitCode := RunPyLogged(pyExe, argsVision, targetDir "\python", outLog, true, "pip install torchvision-0.16.2+cu118")
    if exitCode != 0
        throw Error("pip 安装 torchvision 失败 exit=" exitCode)
    Log("[√] torchvision 安装完成")

    ; torch 2.1.x 与 NumPy 2.x ABI 不兼容，强制锁到 1.x
    argsNumpy := '-u -m pip install --no-warn-script-location --no-cache-dir --progress-bar off "numpy<2"'
    exitCode := RunPyLogged(pyExe, argsNumpy, targetDir "\python", outLog, true, "pip install numpy<2")
    if exitCode != 0
        Log("[!] numpy 固定失败，继续校验…")
    else
        Log("[√] numpy<2 就绪")

    Log("[>] 校验 torch / CUDA…")
    try FileDelete probePy
    FileAppend (
        "import torch, torchvision`r`n"
        "print('torch', torch.__version__)`r`n"
        "print('tv', torchvision.__version__)`r`n"
        "print('cuda', torch.cuda.is_available())`r`n"
        "print('device', torch.cuda.get_device_name(0) if torch.cuda.is_available() else 'n/a')`r`n"
    ), probePy, "UTF-8-RAW"
    verify := RunPyLogged(pyExe, '"' probePy '"', targetDir "\python", modelDir "\torch_verify.out.log", true, "校验 torch")
    try FileDelete probePy
    if verify != 0
        Log("[!] 校验异常")
    else
        Log("[√] PyTorch CUDA 11.8 就绪")
}

; BiRefNet：transformers（结构）/ timm（骨干）/ einops / pillow / scipy
EnsureBiRefNetDeps(targetDir) {
    pyExe := targetDir "\python\python.exe"
    modelDir := targetDir "\model"
    pyDir := targetDir "\python"
    if !FileExist(pyExe)
        throw Error("未找到 python\python.exe")
    try DirCreate modelDir

    Log("[*] 安装 BiRefNet 推理依赖…")

    probePy := modelDir "\_biref_deps_probe.py"
    try FileDelete probePy
    FileAppend (
        "import importlib, sys`r`n"
        "mods = ['typing_extensions','transformers','timm','einops','PIL','scipy','kornia']`r`n"
        "miss = []`r`n"
        "for m in mods:`r`n"
        "    try:`r`n"
        "        mod = importlib.import_module(m)`r`n"
        "        ver = getattr(mod, '__version__', '?')`r`n"
        "        print('OK', m, ver)`r`n"
        "    except Exception as e:`r`n"
        "        miss.append(m)`r`n"
        "        print('MISS', m, e)`r`n"
        "try:`r`n"
        "    import transformers`r`n"
        "    from transformers.utils import is_torch_available`r`n"
        "    ok = is_torch_available()`r`n"
        "    print('torch_backend', ok)`r`n"
        "    if not ok:`r`n"
        "        miss.append('transformers_torch')`r`n"
        "except Exception as e:`r`n"
        "    print('torch_backend_err', e)`r`n"
        "    miss.append('transformers_torch')`r`n"
        "print('MISS_COUNT', len(miss))`r`n"
        "raise SystemExit(0 if not miss else 1)`r`n"
    ), probePy, "UTF-8-RAW"

    chkLog := modelDir "\biref_deps_probe.out.log"
    pkgList := CfgStepList("pip", "packages")
    if pkgList.Length < 1
        pkgList := ["typing_extensions", "transformers==4.46.3", "timm", "einops", "pillow", "scipy", "kornia"]
    ; 旧配置缺 typing_extensions 时补上（torch/transformers 硬依赖）
    hasTe := false
    for p in pkgList {
        if InStr(StrLower(String(p)), "typing_extensions") {
            hasTe := true
            break
        }
    }
    if !hasTe
        pkgList.InsertAt(1, "typing_extensions")
    if RunPyLogged(pyExe, '"' probePy '"', pyDir, chkLog) = 0 {
        Log("[√] BiRefNet 依赖已齐全，跳过 pip")
        MarkPipePkgs("pip", pkgList, "done")
        try FileDelete probePy
        return
    }

    ; transformers 5.x 要求 torch>=2.6，与 cu118 的 2.1.2 不兼容 → 钉 4.46.3
    ; 官方源优先（部分国内镜像对本机返回 versions: none）
    outLog := modelDir "\biref_deps_pip.out.log"
    mirrors := [
        '-i https://pypi.org/simple',
        '-i https://mirrors.aliyun.com/pypi/simple/ --trusted-host mirrors.aliyun.com',
        '-i https://pypi.tuna.tsinghua.edu.cn/simple --trusted-host pypi.tuna.tsinghua.edu.cn'
    ]
    PipInstallPackages(pyExe, pyDir, outLog, pkgList, mirrors, "pip")

    ; 装完后再探针
    verify := RunPyLogged(pyExe, '"' probePy '"', pyDir, chkLog, false, "校验依赖")
    try FileDelete probePy
    if verify != 0 {
        Log("[!] 依赖校验未通过")
        throw Error("BiRefNet 依赖校验失败")
    }
    Log("[√] BiRefNet 依赖就绪")
}

; =====================================================================
EnsureAria2cNative(outDir) {
    tempZip := outDir "\aria2_temp.zip"
    targetExe := outDir "\aria2c.exe"
    urls := CfgStepList("aria2c", "urls")
    if urls.Length < 1
        urls := [
            "https://gh.tszai.cn/https://github.com/aria2/aria2/releases/download/release-1.37.0/aria2-1.37.0-win-64bit-build1.zip",
            "https://ghproxy.net/https://github.com/aria2/aria2/releases/download/release-1.37.0/aria2-1.37.0-win-64bit-build1.zip",
            "https://github.com/aria2/aria2/releases/download/release-1.37.0/aria2-1.37.0-win-64bit-build1.zip"
        ]
    if !CurlDownload(tempZip, urls, 1000000)
        throw Error("aria2c 压缩包下载失败")

    Log("[>] aria2c 正在解压中…")
    tempExtractDir := outDir "\aria2_temp_dir"
    try {
    if DirExist(tempExtractDir)
            DirDelete(tempExtractDir, true)
    } catch {
    }
    DirCreate(tempExtractDir)
    cmdExtract := 'tar.exe -xf "' tempZip '" -C "' tempExtractDir '"'
    try RunWait(A_ComSpec ' /c "' cmdExtract '"', , "Hide")
    catch as e {
        throw Error("解压失败: " e.Message)
    }

    found := false
    Loop Files, tempExtractDir "\aria2c.exe", "R" {
        FileCopy(A_LoopFileFullPath, targetExe, true)
        found := true
        break
    }

    try {
        if DirExist(tempExtractDir)
            DirDelete(tempExtractDir, true)
    } catch {
    }
    try {
    if FileExist(tempZip)
            FileDelete tempZip
    } catch {
    }

    if !found || !FileExist(targetExe)
        throw Error("压缩包中未找到 aria2c.exe")
}

; =====================================================================
; 2. Python Embeddable 3.10.11（不含 get-pip，见 EnsureGetPip）
; =====================================================================
EnsurePythonEnv(targetDir) {
    aria2c := targetDir "\aria2c.exe"
    pyDir := targetDir "\python"
    pyExe := pyDir "\python.exe"
    pthFile := pyDir "\python310._pth"
    zipPath := targetDir "\python-3.10.11-embed-amd64.zip"

    Log("[*] 部署 Python 3.10.11…")

    if FileExist(pyExe) && FileExist(pthFile) {
        PatchPythonPth(pthFile)
        Log("[√] Python 已就绪")
        return
    }

    pyUrls := CfgStepList("python", "urls")
    if pyUrls.Length < 1
        pyUrls := [
            "https://www.python.org/ftp/python/3.10.11/python-3.10.11-embed-amd64.zip",
            "https://mirrors.huaweicloud.com/python/3.10.11/python-3.10.11-embed-amd64.zip",
            "https://npmmirror.com/mirrors/python-release/3.10.11/python-3.10.11-embed-amd64.zip"
        ]

    if !DownloadFileSmart(zipPath, pyUrls, aria2c, 5000000)
        throw Error("Python embed zip 下载失败")

    Log("[>] python-3.10.11 正在解压中…")
    try {
        if DirExist(pyDir)
            DirDelete(pyDir, true)
    } catch {
    }
    DirCreate(pyDir)

    ; tar 可直接解 zip 到目标目录
    cmdExtract := 'tar.exe -xf "' zipPath '" -C "' pyDir '"'
    exitCode := 1
    try exitCode := RunWait(A_ComSpec ' /c "' cmdExtract '"', , "Hide")
    catch as e {
        throw Error("解压 Python 失败: " e.Message)
    }
    if exitCode != 0 || !FileExist(pyExe) {
        Log("[>] 改用 Expand-Archive 解压中…")
        ps := Format("Expand-Archive -LiteralPath '{1}' -DestinationPath '{2}' -Force"
            , StrReplace(zipPath, "'", "''"), StrReplace(pyDir, "'", "''"))
        try RunWait(A_ComSpec ' /c powershell -NoProfile -ExecutionPolicy Bypass -Command "' ps '"', , "Hide")
        catch as e {
            throw Error("Expand-Archive 失败: " e.Message)
        }
    }
    if !FileExist(pyExe)
        throw Error("解压后未找到 python.exe")

    Log("[√] Python 解压完成")
    PatchPythonPth(pthFile)

    try {
        if FileExist(zipPath)
            FileDelete zipPath
    } catch {
    }
    Log("[√] Python 环境就绪")
}

; 单独节点：为 embed Python 安装 pip
EnsureGetPip(targetDir) {
    aria2c := targetDir "\aria2c.exe"
    pyDir := targetDir "\python"
    pyExe := pyDir "\python.exe"
    if !FileExist(pyExe)
        throw Error("未找到 python.exe，请先完成 Python 节点")
    if FileExist(pyDir "\Scripts\pip.exe") || FileExist(pyDir "\Lib\site-packages\pip\__init__.py") {
        Log("[√] pip 已就绪，跳过 get-pip")
        return
    }
    InstallGetPip(pyDir, pyExe, aria2c)
}

; 写入干净可用的 python310._pth（无 BOM），并创建 site-packages
PatchPythonPth(pthFile) {
    pyDir := ""
    SplitPath pthFile, , &pyDir
    siteDir := pyDir "\Lib\site-packages"
    try DirCreate siteDir

    ; embed 标准可用配置：路径在前，import site 在最后；UTF-8-RAW 避免 BOM 导致解析失败
    content := "python310.zip`r`n"
        . ".`r`n"
        . "Lib\site-packages`r`n"
        . "import site`r`n"
    try FileDelete pthFile
    FileAppend content, pthFile, "UTF-8-RAW"
}

; 跑命令；live=true 只刷简短「xxx 进行中…」，详细输出仅写 outLog 文件
RunPyLogged(pyExe, args, workDir, outLog, live := false, statusTip := "") {
    try {
        if FileExist(outLog)
            FileDelete outLog
    } catch {
    }
    try FileAppend "", outLog, "UTF-8-RAW"
    bat := workDir "\_py_run_tmp.cmd"
    try FileDelete bat
    ecFile := workDir "\_py_run_exit.txt"
    try FileDelete ecFile
    tip := Trim(String(statusTip))
    if tip = ""
        tip := "任务"
    global PIP_TMP_DIR
    tmpSet := ""
    if PIP_TMP_DIR != "" {
        tmpSet := "set TEMP=" PIP_TMP_DIR "`r`nset TMP=" PIP_TMP_DIR "`r`n"
    }
    batBody := Format(
        "@echo off`r`nset PYTHONUNBUFFERED=1`r`nset PYTHONIOENCODING=utf-8`r`nset HF_ENDPOINT=https://hf-mirror.com`r`n{5}"
        . '"{1}" {2} > "{3}" 2>&1`r`n'
        . "set EC=%ERRORLEVEL%`r`n"
        . '> "{4}" echo %EC%`r`n'
        . "exit /b %EC%`r`n",
        pyExe, args, outLog, ecFile, tmpSet)
    FileAppend batBody, bat, "UTF-8-RAW"

    if !live {
        if tip != "任务"
            Log("[>] " tip " 进行中…")
        exitCode := 1
        try exitCode := RunWait(bat, workDir, "Hide")
        catch as e {
            Log("[!] 进程异常: " e.Message)
            exitCode := 1
        }
        try FileDelete bat
        return exitCode
    }

    global PIP_PROG_LAST_SZ, PIP_PROG_LAST_TICK, PIP_PROG_MAP
    PIP_PROG_LAST_SZ := 0
    PIP_PROG_LAST_TICK := 0
    PIP_PROG_MAP := Map()
    Log("[>] " tip " 进行中…")
    pid := 0
    try Run(bat, workDir, "Hide", &pid)
    catch as e {
        Log("[!] 启动失败: " e.Message)
        try FileDelete bat
        return 1
    }
    lastBeat := A_TickCount
    t0 := A_TickCount
    loop {
        if pid && !ProcessExist(pid)
            break
        if (A_TickCount - lastBeat) > 4000 {
            lastBeat := A_TickCount
            Log("[>] " tip " 进行中…" PipLiveStatus(outLog))
        }
        Sleep 400
        if (A_TickCount - t0) > 3600000 {
            Log("[!] 命令超时")
            try ProcessClose(pid)
            break
        }
    }
    try ProcessWaitClose(pid, 15)
    Sleep 200

    exitCode := ReadExitCodeFile(ecFile, 1)
    if exitCode != 0 && PipLogLooksSuccessful(outLog)
        exitCode := 0
    try FileDelete bat
    try FileDelete ecFile
    return exitCode
}

ReadExitCodeFile(ecFile, defaultCode := 1) {
    loop 20 {
        if FileExist(ecFile) {
            try {
                raw := FileRead(ecFile, "UTF-8")
                raw := Trim(raw, " `t`r`n")
                if RegExMatch(raw, "^\d+$", &m)
                    return Integer(m[0])
            } catch {
            }
        }
        Sleep 50
    }
    return defaultCode
}

PipParseSizeToBytes(tok) {
    tok := Trim(String(tok))
    m := ""
    if !RegExMatch(tok, "i)^([\d.]+)\s*(GB|MB|KB|B)$", &m)
        return 0
    n := Number(m[1])
    u := StrUpper(m[2])
    if u = "GB"
        return n * 1073741824
    if u = "MB"
        return n * 1048576
    if u = "KB"
        return n * 1024
    return n
}

PipGrowingBytes(total := 0, nameHint := "") {
    global PIP_CACHE_DIR, PIP_TMP_DIR, PIP_PROG_MAP
    dirs := []
    if PIP_TMP_DIR != ""
        dirs.Push(PIP_TMP_DIR)
    if PIP_CACHE_DIR != ""
        dirs.Push(PIP_CACHE_DIR)
    dirs.Push(A_Temp)
    hint := ""
    hm := ""
    if RegExMatch(String(nameHint), "i)^([A-Za-z0-9]+(?:_[A-Za-z0-9]+)*)", &hm)
        hint := StrLower(hm[1])
    bestSz := 0
    bestDelta := 0
    seen := Map()
    for dir in dirs {
        if dir = "" || !DirExist(dir)
            continue
        loop files dir "\*", "R" {
            path := A_LoopFileFullPath
            if seen.Has(path)
                continue
            seen[path] := true
            try {
                sz := FileGetSize(path)
            } catch {
                continue
            }
            if sz < 8192
                continue
            if total > 0 && sz > total * 1.08
                continue
            old := PIP_PROG_MAP.Has(path) ? PIP_PROG_MAP[path] : 0
            PIP_PROG_MAP[path] := sz
            delta := sz - old
            hit := (hint != "" && InStr(StrLower(path), hint))
            if delta > 0 {
                score := delta + (hit ? 100000000 : 0)
                if score > bestDelta {
                    bestDelta := score
                    bestSz := sz
                }
            } else if hit && sz > bestSz && bestDelta = 0 {
                bestSz := sz
            }
        }
    }
    return bestSz
}

PipLiveStatus(outLog) {
    global PIP_PROG_LAST_SZ, PIP_PROG_LAST_TICK
    txt := ReadFileTail(outLog, 6000)
    lastDl := ""
    lastAct := ""
    total := 0
    fname := ""
    if txt != "" {
        txt := StrReplace(txt, "`r", "`n")
        loop parse txt, "`n" {
            line := Trim(A_LoopField)
            if line = ""
                continue
            m := ""
            if RegExMatch(line, "i)Downloading\s+(\S+)\s+\(([^)]+)\)", &m) {
                fname := m[1]
                lastDl := " 下载 " m[1] " (" m[2] ")"
                lastAct := " 传输中"
                total := PipParseSizeToBytes(m[2])
            }
            if InStr(line, "Installing collected")
                lastAct := " 正在写入 site-packages"
            else if InStr(line, "Successfully installed")
                lastAct := " 安装完成"
            else if InStr(line, "Building wheel") || InStr(line, "Preparing metadata")
                lastAct := " 正在准备元数据"
            else if lastDl = "" && InStr(line, "Collecting")
                lastAct := " 正在解析依赖"
        }
    }
    got := PipGrowingBytes(total, fname)
    now := A_TickCount
    spd := -1
    if got > 0 {
        if PIP_PROG_LAST_TICK > 0 && now > PIP_PROG_LAST_TICK {
            dt := (now - PIP_PROG_LAST_TICK) / 1000
            if dt >= 0.5
                spd := Max(0, got - PIP_PROG_LAST_SZ) / dt
        }
        PIP_PROG_LAST_SZ := got
        PIP_PROG_LAST_TICK := now
        bits := lastDl " 已下 " FmtDlBytes(got)
        if total > 0 {
            bits .= " / 共 " FmtDlBytes(total)
            bits .= " (" Min(99, Floor(got * 100 / total)) "%)"
        }
        if spd > 256
            bits .= "  速度 " FmtDlSpeed(spd)
        return bits
    }
    if lastDl != "" {
        extra := total > 0 ? " 共 " FmtDlBytes(total) : ""
        return lastDl extra " 正在从镜像拉取（未落到本地缓存前无法计量）"
    }
    if lastAct = ""
        lastAct := " 传输中"
    return lastAct
}

LogPipFailExcerpt(outLog) {
    txt := ReadFileTail(outLog, 8000)
    if txt = ""
        return
    txt := StrReplace(txt, "`r", "`n")
    last := ""
    loop parse txt, "`n" {
        line := Trim(A_LoopField)
        if line = ""
            continue
        if RegExMatch(line, "i)ERROR:|Could not|No matching|ResolutionImpossible|conflict|HTTP")
            last := line
    }
    if last != ""
        Log("[!] pip: " last)
}

PipLogLooksSuccessful(outLog) {
    if !FileExist(outLog)
        return false
    try {
        body := FileRead(outLog, "UTF-8")
        if RegExMatch(body, "i)Successfully installed|Requirement already satisfied")
            && !RegExMatch(body, "i)ERROR:|Could not install|No matching distribution") {
            return true
        }
    } catch {
    }
    return false
}

InstallGetPip(pyDir, pyExe, aria2c) {
    getPip := pyDir "\get-pip.py"
    outLog := pyDir "\get-pip.out.log"
    PatchPythonPth(pyDir "\python310._pth")

    probe := RunPyLogged(pyExe, '-c "import sys; print(sys.version)"', pyDir, pyDir "\probe.out.log", false, "检测 python")
    if probe != 0
        throw Error("python.exe 无法启动 (exit=" probe ")")

    pipUrls := CfgStepList("getpip", "urls")
    if pipUrls.Length < 1
        pipUrls := [
            "https://bootstrap.pypa.io/pip/3.10/get-pip.py",
            "https://bootstrap.pypa.io/get-pip.py",
            "https://mirrors.aliyun.com/pypi/get-pip.py",
            "https://ghfast.top/https://bootstrap.pypa.io/get-pip.py"
        ]
    if !DownloadFileSmart(getPip, pipUrls, aria2c, 50000)
        throw Error("get-pip.py 下载失败")

    args1 := Format('"{1}" --no-warn-script-location -i https://pypi.tuna.tsinghua.edu.cn/simple --trusted-host pypi.tuna.tsinghua.edu.cn --trusted-host files.pythonhosted.org'
        , getPip)
    exitCode := RunPyLogged(pyExe, args1, pyDir, outLog, true, "安装 pip")

    if exitCode != 0 {
        args2 := Format('"{1}" --no-warn-script-location', getPip)
        exitCode := RunPyLogged(pyExe, args2, pyDir, outLog, true, "安装 pip（官方源）")
    }

    if exitCode != 0
        exitCode := RunPyLogged(pyExe, "-m ensurepip --upgrade --default-pip", pyDir, outLog, true, "ensurepip")

    if exitCode != 0
        throw Error("get-pip 安装失败 exit=" exitCode)

    ok := (RunPyLogged(pyExe, "-m pip --version", pyDir, pyDir "\pipver.out.log", false, "校验 pip") = 0)
    if ok
        Log("[√] pip 就绪")
    else
        Log("[!] pip 校验未通过")

    try {
        if FileExist(getPip)
            FileDelete getPip
    } catch {
    }
}

;########################################################################################################### deploy_pipe.json
;eyJ2ZXJzaW9uIjoxLCJzdGVwcyI6eyJhcmlhMmMiOnsibGFiZWwiOiJhcmlhMmMg5LiL6L295ZmoIiwidGl0bGUiOiJhcmlhMmMg5LiL6L295ZmoIiwic2l6ZSI6In4yLjUgTUIiLCJsb2NhbCI6ImFyaWEyYy5leGUiLCJ1cmxzIjpbImh0dHBzOi8vZ2gudHN6YWkuY24vaHR0cHM6Ly9naXRodWIuY29tL2FyaWEyL2FyaWEyL3JlbGVhc2VzL2Rvd25sb2FkL3JlbGVhc2UtMS4zNy4wL2FyaWEyLTEuMzcuMC13aW4tNjRiaXQtYnVpbGQxLnppcCIsImh0dHBzOi8vZ2hwcm94eS5uZXQvaHR0cHM6Ly9naXRodWIuY29tL2FyaWEyL2FyaWEyL3JlbGVhc2VzL2Rvd25sb2FkL3JlbGVhc2UtMS4zNy4wL2FyaWEyLTEuMzcuMC13aW4tNjRiaXQtYnVpbGQxLnppcCIsImh0dHBzOi8vZ2l0aHViLmNvbS9hcmlhMi9hcmlhMi9yZWxlYXNlcy9kb3dubG9hZC9yZWxlYXNlLTEuMzcuMC9hcmlhMi0xLjM3LjAtd2luLTY0Yml0LWJ1aWxkMS56aXAiXX0sInB5dGhvbiI6eyJsYWJlbCI6IlB5dGhvbiAzLjEwLjExIiwidGl0bGUiOiJQeXRob24gRW1iZWRkYWJsZSAzLjEwLjExIiwic2l6ZSI6In4xNS0yMCBNQiIsImxvY2FsIjoicHl0aG9uX2VtYmVkXFxweXRob24uZXhlIiwidXJscyI6WyJodHRwczovL3d3dy5weXRob24ub3JnL2Z0cC9weXRob24vMy4xMC4xMS9weXRob24tMy4xMC4xMS1lbWJlZC1hbWQ2NC56aXAiLCJodHRwczovL21pcnJvcnMuaHVhd2VpY2xvdWQuY29tL3B5dGhvbi8zLjEwLjExL3B5dGhvbi0zLjEwLjExLWVtYmVkLWFtZDY0LnppcCJdfSwiZ2V0cGlwIjp7ImxhYmVsIjoicGlwIDI0LjMiLCJ0aXRsZSI6IuWuieijhSBwaXAgMjQuMyAoZ2V0LXBpcCkiLCJzaXplIjoifjIgTUIiLCJsb2NhbCI6InB5dGhvbl9lbWJlZFxcU2NyaXB0c1xccGlwLmV4ZSIsIm5vdGUiOiLkuLogZW1iZWQgUHl0aG9uIOWuieijhSBwaXAiLCJ1cmxzIjpbImh0dHBzOi8vYm9vdHN0cmFwLnB5cGEuaW8vcGlwLzMuMTAvZ2V0LXBpcC5weSIsImh0dHBzOi8vYm9vdHN0cmFwLnB5cGEuaW8vZ2V0LXBpcC5weSIsImh0dHBzOi8vbWlycm9ycy5hbGl5dW4uY29tL3B5cGkvZ2V0LXBpcC5weSIsImh0dHBzOi8vZ2hmYXN0LnRvcC9odHRwczovL2Jvb3RzdHJhcC5weXBhLmlvL2dldC1waXAucHkiXX0sIndoZWVscyI6eyJsYWJlbCI6IuaYvuWNoeWKoOmAnyIsInRpdGxlIjoiUHlUb3JjaCBDVURBIDExLjgiLCJzaXplIjoidG9yY2h+Mi41R0IiLCJsb2NhbCI6Im1vZGVsXFx0b3JjaC0yLjEuMitjdTExOC1jcDMxMC1jcDMxMC13aW5fYW1kNjQud2hsIiwidXJscyI6WyJodHRwczovL2Rvd25sb2FkLnB5dG9yY2gub3JnL3dobC9jdTExOC90b3JjaC0yLjEuMiUyQmN1MTE4LWNwMzEwLWNwMzEwLXdpbl9hbWQ2NC53aGwiLCJodHRwczovL2Rvd25sb2FkLnB5dG9yY2gub3JnL3dobC9jdTExOC90b3JjaHZpc2lvbi0wLjE2LjIlMkJjdTExOC1jcDMxMC1jcDMxMC13aW5fYW1kNjQud2hsIl19LCJtb2RlbCI6eyJsYWJlbCI6IuaooeWeiyhCaVJlZk5ldCkiLCJ0aXRsZSI6IkJpUmVmTmV0IOadg+mHjSIsInNpemUiOiJ+NDQ1IE1CIiwibG9jYWwiOiJtb2RlbFxcbW9kZWwuc2FmZXRlbnNvcnMiLCJ1cmxzIjpbImh0dHBzOi8vaGYtbWlycm9yLmNvbS9aaGVuZ1Blbmc3L0JpUmVmTmV0L3Jlc29sdmUvbWFpbi9tb2RlbC5zYWZldGVuc29ycyIsImh0dHBzOi8vaHVnZ2luZ2ZhY2UuY28vWmhlbmdQZW5nNy9CaVJlZk5ldC9yZXNvbHZlL21haW4vbW9kZWwuc2FmZXRlbnNvcnMiXX0sInBpcCI6eyJsYWJlbCI6InBpcCDkvp3otZYiLCJ0aXRsZSI6IkJpUmVmTmV0IOaOqOeQhuS+nei1liIsInNpemUiOiJ+MTAwLTIwMCBNQiIsImxvY2FsIjoicHl0aG9uX2VtYmVkXFxMaWJcXHNpdGUtcGFja2FnZXMiLCJwYWNrYWdlcyI6WyJ0cmFuc2Zvcm1lcnM9PTQuNDYuMyIsInRpbW0iLCJlaW5vcHMiLCJwaWxsb3ciLCJzY2lweSIsImtvcm5pYSJdfSwic2NyaXB0Ijp7ImxhYmVsIjoi6ISa5pysIiwidGl0bGUiOiJyZW1vdmVfYmcucHkiLCJzaXplIjoiQmlSZWZOZXQgQ0xJIiwibG9jYWwiOiJzY3JpcHRcXHJlbW92ZV9iZy5weSIsImtpbmQiOiJzY3JpcHQiLCJub3RlIjoi5Y+v57yW6L6R6ISa5pys77yM5L+d5a2Y5ZCO5Y+M5ZCR5ZCM5q2lIn0sInN1cGlyX3JlcG8iOnsibGFiZWwiOiJTVVBJUiDku6PnoIEiLCJ0aXRsZSI6IuWumOaWuSBTVVBJUiDku5PlupMgemlwIiwic2l6ZSI6In7mlbDljYEgTUIiLCJsb2NhbCI6IlNVUElSXFxcXG9wdGlvbnNcXFxcU1VQSVJfdjAueWFtbCIsIm5vdGUiOiJhcmlhMmMg5ouJIEdpdEh1YiB6aXDvvIzkuI3kvp3otZbmnKzmnLogZ2l0IiwidXJscyI6WyJodHRwczovL2doLnRzemFpLmNuL2h0dHBzOi8vZ2l0aHViLmNvbS9GYW5naHVhLVl1L1NVUElSL2FyY2hpdmUvcmVmcy9oZWFkcy9tYXN0ZXIuemlwIiwiaHR0cHM6Ly9naHByb3h5Lm5ldC9odHRwczovL2dpdGh1Yi5jb20vRmFuZ2h1YS1ZdS9TVVBJUi9hcmNoaXZlL3JlZnMvaGVhZHMvbWFzdGVyLnppcCIsImh0dHBzOi8vZ2l0aHViLmNvbS9GYW5naHVhLVl1L1NVUElSL2FyY2hpdmUvcmVmcy9oZWFkcy9tYXN0ZXIuemlwIl19LCJzdXBpcl9waXAiOnsibGFiZWwiOiJTVVBJUiDkvp3otZYiLCJ0aXRsZSI6IuS4jeWQqyB0b3JjaO+8iOWkjeeUqCBjdTExOO+8iSIsInNpemUiOiJ+MjAwIE1CIiwibG9jYWwiOiJweXRob25fZW1iZWRcXFxcTGliXFxcXHNpdGUtcGFja2FnZXMiLCJub3RlIjoi5LiN6KOFIHRvcmNoL3RyaXRvbi94Zm9ybWVycyIsInBhY2thZ2VzIjpbInNldHVwdG9vbHNcdTAwM2U9NjUsXHUwMDNjODEiLCJvbWVnYWNvbmYiLCJlaW5vcHMtZXh0cyIsIm9wZW4tY2xpcC10b3JjaCIsIm9wZW5jdi1weXRob24taGVhZGxlc3M9PTQuMTAuMC44NCIsImh1Z2dpbmdmYWNlX2h1Ylx1MDAzZT0wLjIzLjIsXHUwMDNjMS4wIiwiZGlmZnVzZXJzXHUwMDNlPTAuMjUsXHUwMDNjMC4zMiIsImFjY2VsZXJhdGVcdTAwM2U9MC4yNSxcdTAwM2MxLjEiLCJweXRvcmNoLWxpZ2h0bmluZyIsIlB5WUFNTCIsImZhY2V4bGliIiwibWF0cGxvdGxpYiIsInRxZG0iLCJzY2lraXQtbGVhcm4iLCJvcGVuYWktY2xpcCIsIndlYmRhdGFzZXQiLCJrLWRpZmZ1c2lvbiJdfSwic3VwaXJfd2VpZ2h0cyI6eyJsYWJlbCI6IlNVUElSIOadg+mHjSIsInRpdGxlIjoiU0RYTCArIFNVUElSLXYwUSArIENMSVAtRyIsInNpemUiOiLnuqYgMTLigJMxNiBHQiIsImxvY2FsIjoiU1VQSVJcXFxcbW9kZWxzIiwibm90ZSI6ImFyaWEyYyAteDE2IOWFqOmAn++8m+aaguS4jeS4iyBMTGFWQSIsInVybHMiOlsiaHR0cHM6Ly9oZi1taXJyb3IuY29tL3N0YWJpbGl0eWFpL3N0YWJsZS1kaWZmdXNpb24teGwtYmFzZS0xLjAvcmVzb2x2ZS9tYWluL3NkX3hsX2Jhc2VfMS4wXzAuOXZhZS5zYWZldGVuc29ycyIsImh0dHBzOi8vaHVnZ2luZ2ZhY2UuY28vc3RhYmlsaXR5YWkvc3RhYmxlLWRpZmZ1c2lvbi14bC1iYXNlLTEuMC9yZXNvbHZlL21haW4vc2RfeGxfYmFzZV8xLjBfMC45dmFlLnNhZmV0ZW5zb3JzIiwiaHR0cHM6Ly9oZi1taXJyb3IuY29tL2NhbWVuZHVydS9TVVBJUi9yZXNvbHZlL21haW4vU1VQSVItdjBRLmNrcHQiLCJodHRwczovL2h1Z2dpbmdmYWNlLmNvL2NhbWVuZHVydS9TVVBJUi9yZXNvbHZlL21haW4vU1VQSVItdjBRLmNrcHQiLCJodHRwczovL2hmLW1pcnJvci5jb20vbGFpb24vQ0xJUC1WaVQtYmlnRy0xNC1sYWlvbjJCLTM5Qi1iMTYway9yZXNvbHZlL21haW4vb3Blbl9jbGlwX3B5dG9yY2hfbW9kZWwuYmluIiwiaHR0cHM6Ly9odWdnaW5nZmFjZS5jby9sYWlvbi9DTElQLVZpVC1iaWdHLTE0LWxhaW9uMkItMzlCLWIxNjBrL3Jlc29sdmUvbWFpbi9vcGVuX2NsaXBfcHl0b3JjaF9tb2RlbC5iaW4iXX0sIm9jcl9waXAiOnsibGFiZWwiOiJQYWRkbGVPQ1IiLCJ0aXRsZSI6Ik9DUiBDUFUg5L6d6LWW77yIUGFkZGxlUGFkZGxlICsgUGFkZGxlT0NS77yJIiwic2l6ZSI6In4yMDAtNDAwIE1CIiwibG9jYWwiOiJweXRob25cXExpYlxcc2l0ZS1wYWNrYWdlcyIsIm5vdGUiOiJDUFUg54mI77yM5riF5Y2O5rqQ5LyY5YWI77yb6ZyA5YWI5pyJIFB5dGhvbiArIHBpcCIsInBhY2thZ2VzIjpbInBhZGRsZXBhZGRsZSIsInBhZGRsZW9jciIsInBpbGxvdyIsIm51bXB5Il19fX0=
;########################################################################################################### deploy_pipe.json

;########################################################################################################### remove_bg.py
;IyAtKi0gY29kaW5nOiB1dGYtOCAtKi0KIiIiQmlSZWZOZXQg5oqg5Zu+IENMSe+8muacrOWcsOaooeWei+ebruW9lSDihpIg6YCP5piOIFBOR+OAgiIiIgpmcm9tIF9fZnV0dXJlX18gaW1wb3J0IGFubm90YXRpb25zCgppbXBvcnQgYXJncGFyc2UKaW1wb3J0IGN0eXBlcwppbXBvcnQgZ2MKaW1wb3J0IG9zCmltcG9ydCBzdWJwcm9jZXNzCmltcG9ydCBzeXMKaW1wb3J0IHRpbWUKZnJvbSBwYXRobGliIGltcG9ydCBQYXRoCgojIOWHj+i9u+e8k+WtmOWIhumFjeWZqOeijueJh++8iOmhu+WcqCBpbXBvcnQgdG9yY2gg5YmN77yJCm9zLmVudmlyb24uc2V0ZGVmYXVsdCgiUFlUT1JDSF9DVURBX0FMTE9DX0NPTkYiLCAibWF4X3NwbGl0X3NpemVfbWI6MTI4IikKCmltcG9ydCB0b3JjaApmcm9tIFBJTCBpbXBvcnQgSW1hZ2UKZnJvbSB0b3JjaHZpc2lvbiBpbXBvcnQgdHJhbnNmb3Jtcwpmcm9tIHRyYW5zZm9ybWVycyBpbXBvcnQgQXV0b01vZGVsRm9ySW1hZ2VTZWdtZW50YXRpb24KCgpkZWYgbG9nKG1zZzogc3RyKSAtPiBOb25lOgogICAgcHJpbnQobXNnLCBmbHVzaD1UcnVlKQoKCmRlZiBpc19jdWRhX2ZhaWwoZXhjOiBCYXNlRXhjZXB0aW9uKSAtPiBib29sOgogICAgcyA9IHN0cihleGMpLmxvd2VyKCkKICAgIG5hbWUgPSB0eXBlKGV4YykuX19uYW1lX18ubG93ZXIoKQogICAga2V5cyA9ICgKICAgICAgICAib3V0IG9mIG1lbW9yeSIsCiAgICAgICAgImN1ZGEgZXJyb3IiLAogICAgICAgICJ1bmtub3duIGVycm9yIiwKICAgICAgICAibWVtb3J5IGFsbG9jYXRpb24gZmFpbHVyZSIsCiAgICAgICAgImN1ZG5uIiwKICAgICAgICAiY3VibGFzIiwKICAgICkKICAgIHJldHVybiAiY3VkYSIgaW4gbmFtZSBvciBhbnkoayBpbiBzIGZvciBrIGluIGtleXMpCgoKZGVmIGN1ZGFfY2xlYXIobGFiZWw6IHN0ciA9ICIiKSAtPiBOb25lOgogICAgIiIi5Zue5pS25byV55SoICsg5b2S6L+YIFB5VG9yY2gg57yT5a2Y5Z2X44CCIiIiCiAgICBnYy5jb2xsZWN0KCkKICAgIGlmIG5vdCB0b3JjaC5jdWRhLmlzX2F2YWlsYWJsZSgpOgogICAgICAgIHJldHVybgogICAgdHJ5OgogICAgICAgIHRvcmNoLmN1ZGEuc3luY2hyb25pemUoKQogICAgZXhjZXB0IEV4Y2VwdGlvbjoKICAgICAgICBwYXNzCiAgICB0cnk6CiAgICAgICAgdG9yY2guY3VkYS5lbXB0eV9jYWNoZSgpCiAgICAgICAgdG9yY2guY3VkYS5pcGNfY29sbGVjdCgpCiAgICBleGNlcHQgRXhjZXB0aW9uOgogICAgICAgIHBhc3MKICAgIHRyeToKICAgICAgICB0b3JjaC5jdWRhLnJlc2V0X3BlYWtfbWVtb3J5X3N0YXRzKCkKICAgICAgICB0b3JjaC5jdWRhLnJlc2V0X2FjY3VtdWxhdGVkX21lbW9yeV9zdGF0cygpCiAgICBleGNlcHQgRXhjZXB0aW9uOgogICAgICAgIHBhc3MKICAgIGlmIGxhYmVsOgogICAgICAgIHRyeToKICAgICAgICAgICAgYWxsb2MgPSB0b3JjaC5jdWRhLm1lbW9yeV9hbGxvY2F0ZWQoKSAvICgxMDI0ICoqIDIpCiAgICAgICAgICAgIHJlc2VydmVkID0gdG9yY2guY3VkYS5tZW1vcnlfcmVzZXJ2ZWQoKSAvICgxMDI0ICoqIDIpCiAgICAgICAgICAgIGxvZyhmIltpXSBDVURBIOa4heeQhntsYWJlbH06IGFsbG9jPXthbGxvYzouMGZ9TUIgcmVzZXJ2ZWQ9e3Jlc2VydmVkOi4wZn1NQiIpCiAgICAgICAgZXhjZXB0IEV4Y2VwdGlvbjoKICAgICAgICAgICAgbG9nKGYiW2ldIENVREEg5riF55CGe2xhYmVsfSIpCgoKZGVmIGN1ZGFfZGV2aWNlX3Jlc2V0KGxhYmVsOiBzdHIgPSAiIikgLT4gTm9uZToKICAgICIiIgogICAg6amx5Yqo57qn6YeN572u5b2T5YmNIENVREEgZGV2aWNl44CCCiAgICDkuIrmrKEgT09NIOWQjuS4iuS4i+aWh+W4uOS8muWdj+aOie+8jOe7p+e7rei3keS8muWPmCBDVURBIHVua25vd24gZXJyb3LvvJsKICAgIOW/hemhu+WFiOS4ouaOieaJgOaciSB0b3JjaCBDVURBIOWvueixoe+8jOWGjSByZXNldO+8jOWGjemHjeaWsOWKoOi9veaooeWei+OAggogICAgIiIiCiAgICBnYy5jb2xsZWN0KCkKICAgIHRyeToKICAgICAgICB0b3JjaC5jdWRhLnN5bmNocm9uaXplKCkKICAgIGV4Y2VwdCBFeGNlcHRpb246CiAgICAgICAgcGFzcwogICAgdHJ5OgogICAgICAgIHRvcmNoLmN1ZGEuZW1wdHlfY2FjaGUoKQogICAgZXhjZXB0IEV4Y2VwdGlvbjoKICAgICAgICBwYXNzCgogICAgZXJyID0gLTEKICAgIHRyeToKICAgICAgICBkbGwgPSBQYXRoKHRvcmNoLl9fZmlsZV9fKS5yZXNvbHZlKCkucGFyZW50IC8gImxpYiIgLyAiY3VkYXJ0NjRfMTEwLmRsbCIKICAgICAgICBjdWRhcnQgPSBjdHlwZXMuQ0RMTChzdHIoZGxsKSkKICAgICAgICBjdWRhcnQuY3VkYURldmljZVJlc2V0LnJlc3R5cGUgPSBjdHlwZXMuY19pbnQKICAgICAgICBlcnIgPSBpbnQoY3VkYXJ0LmN1ZGFEZXZpY2VSZXNldCgpKQogICAgZXhjZXB0IEV4Y2VwdGlvbiBhcyBlOgogICAgICAgIGxvZyhmIlshXSBjdWRhRGV2aWNlUmVzZXQg6LCD55So5aSx6LSlOiB7ZX0iKQogICAgICAgIGN1ZGFfY2xlYXIobGFiZWwgb3IgIu+8iOi9r+a4heeQhu+8iSIpCiAgICAgICAgcmV0dXJuCgogICAgIyByZXNldCDlkI7lvLrliLYgdG9yY2gg6YeN5paw5Yid5aeL5YyWIGRldmljZQogICAgdHJ5OgogICAgICAgIGlmIGhhc2F0dHIodG9yY2guY3VkYSwgImlzX2luaXRpYWxpemVkIikgYW5kIHRvcmNoLmN1ZGEuaXNfaW5pdGlhbGl6ZWQoKToKICAgICAgICAgICAgIyDmuIXlhoXpg6jnirbmgIHvvJrkuIvkuIDmrKEgQ1VEQSDosIPnlKjkvJrph43mlrAgaW5pdAogICAgICAgICAgICB0b3JjaC5jdWRhLl9sYXp5X2luaXQoKQogICAgZXhjZXB0IEV4Y2VwdGlvbjoKICAgICAgICBwYXNzCiAgICB0cnk6CiAgICAgICAgXyA9IHRvcmNoLnplcm9zKDEsIGRldmljZT0iY3VkYSIpCiAgICAgICAgZGVsIF8KICAgICAgICB0b3JjaC5jdWRhLmVtcHR5X2NhY2hlKCkKICAgIGV4Y2VwdCBFeGNlcHRpb24gYXMgZToKICAgICAgICBsb2coZiJbIV0gcmVzZXQg5ZCOIENVREEg5aSN5qOAOiB7ZX0iKQoKICAgIGxvZyhmIltpXSBjdWRhRGV2aWNlUmVzZXQ9e2Vycn17bGFiZWx9IikKCgpkZWYgbG9nX3N5c3RlbV9ncHUoKSAtPiBOb25lOgogICAgdHJ5OgogICAgICAgIG91dCA9IHN1YnByb2Nlc3MuY2hlY2tfb3V0cHV0KAogICAgICAgICAgICBbCiAgICAgICAgICAgICAgICAibnZpZGlhLXNtaSIsCiAgICAgICAgICAgICAgICAiLS1xdWVyeS1ncHU9bWVtb3J5LnVzZWQsbWVtb3J5LmZyZWUsbWVtb3J5LnRvdGFsIiwKICAgICAgICAgICAgICAgICItLWZvcm1hdD1jc3Ysbm9oZWFkZXIsbm91bml0cyIsCiAgICAgICAgICAgIF0sCiAgICAgICAgICAgIHN0ZGVycj1zdWJwcm9jZXNzLkRFVk5VTEwsCiAgICAgICAgICAgIHRleHQ9VHJ1ZSwKICAgICAgICAgICAgdGltZW91dD01LAogICAgICAgICkuc3RyaXAoKQogICAgICAgIHVzZWQsIGZyZWUsIHRvdGFsID0gW3guc3RyaXAoKSBmb3IgeCBpbiBvdXQuc3BsaXQoIiwiKV0KICAgICAgICBsb2coZiJbaV0g5pW05py65pi+5a2YIHVzZWQ9e3VzZWR9TWlCIGZyZWU9e2ZyZWV9TWlCIHRvdGFsPXt0b3RhbH1NaULvvIjlkKvmoYzpnaIv5rWP6KeI5Zmo562J77yJIikKICAgIGV4Y2VwdCBFeGNlcHRpb246CiAgICAgICAgcGFzcwoKCmRlZiBidWlsZF90cmFuc2Zvcm0oc2l6ZTogaW50ID0gMTAyNCk6CiAgICByZXR1cm4gdHJhbnNmb3Jtcy5Db21wb3NlKAogICAgICAgIFsKICAgICAgICAgICAgdHJhbnNmb3Jtcy5SZXNpemUoKHNpemUsIHNpemUpLCBpbnRlcnBvbGF0aW9uPXRyYW5zZm9ybXMuSW50ZXJwb2xhdGlvbk1vZGUuQklDVUJJQyksCiAgICAgICAgICAgIHRyYW5zZm9ybXMuVG9UZW5zb3IoKSwKICAgICAgICAgICAgdHJhbnNmb3Jtcy5Ob3JtYWxpemUoWzAuNDg1LCAwLjQ1NiwgMC40MDZdLCBbMC4yMjksIDAuMjI0LCAwLjIyNV0pLAogICAgICAgIF0KICAgICkKCgpkZWYgcmVmaW5lX21hc2sobWFza19pbWc6IEltYWdlLkltYWdlLCBmZWF0aGVyOiBmbG9hdCA9IDAuOCkgLT4gSW1hZ2UuSW1hZ2U6CiAgICBpZiBmZWF0aGVyIDw9IDA6CiAgICAgICAgcmV0dXJuIG1hc2tfaW1nCiAgICB0cnk6CiAgICAgICAgaW1wb3J0IG51bXB5IGFzIG5wCiAgICAgICAgZnJvbSBzY2lweS5uZGltYWdlIGltcG9ydCBnYXVzc2lhbl9maWx0ZXIKICAgIGV4Y2VwdCBFeGNlcHRpb246CiAgICAgICAgcmV0dXJuIG1hc2tfaW1nCiAgICBhcnIgPSBucC5hc2FycmF5KG1hc2tfaW1nLCBkdHlwZT1ucC5mbG9hdDMyKSAvIDI1NS4wCiAgICBhcnIgPSBnYXVzc2lhbl9maWx0ZXIoYXJyLCBzaWdtYT1mbG9hdChmZWF0aGVyKSkKICAgIGFyciA9IG5wLmNsaXAoYXJyLCAwLjAsIDEuMCkKICAgIHJldHVybiBJbWFnZS5mcm9tYXJyYXkoKGFyciAqIDI1NS4wICsgMC41KS5hc3R5cGUoInVpbnQ4IiksIG1vZGU9IkwiKQoKCmRlZiBwcm9jZXNzX2ltYWdlKG1vZGVsLCBpbWFnZTogSW1hZ2UuSW1hZ2UsIGRldmljZTogdG9yY2guZGV2aWNlLCBzaXplOiBpbnQgPSAxMDI0LCBmZWF0aGVyOiBmbG9hdCA9IDAuOCk6CiAgICByZ2IgPSBpbWFnZS5jb252ZXJ0KCJSR0IiKQogICAgdGZtID0gYnVpbGRfdHJhbnNmb3JtKHNpemUpCiAgICB1c2VfY3VkYSA9IGRldmljZS50eXBlID09ICJjdWRhIgoKICAgIGlmIHVzZV9jdWRhOgogICAgICAgIGN1ZGFfY2xlYXIoIu+8iOaOqOeQhuWJje+8iSIpCgogICAgeCA9IHRmbShyZ2IpLnVuc3F1ZWV6ZSgwKQogICAgaWYgdXNlX2N1ZGE6CiAgICAgICAgeCA9IHgudG8oZGV2aWNlPWRldmljZSwgZHR5cGU9dG9yY2guZmxvYXQxNiwgbm9uX2Jsb2NraW5nPVRydWUpCiAgICBlbHNlOgogICAgICAgIHggPSB4LnRvKGRldmljZSkKCiAgICBwcmVkcyA9IE5vbmUKICAgIHByZWQgPSBOb25lCiAgICB0cnk6CiAgICAgICAgd2l0aCB0b3JjaC5pbmZlcmVuY2VfbW9kZSgpOgogICAgICAgICAgICBvdXRzID0gbW9kZWwoeCkKICAgICAgICAgICAgbGFzdCA9IG91dHNbLTFdIGlmIGlzaW5zdGFuY2Uob3V0cywgKGxpc3QsIHR1cGxlKSkgZWxzZSBvdXRzCiAgICAgICAgICAgIGRlbCBvdXRzCiAgICAgICAgICAgIHByZWRzID0gbGFzdC5zaWdtb2lkKCkKICAgICAgICAgICAgZGVsIGxhc3QKICAgICAgICAgICAgcHJlZCA9IHByZWRzWzBdLnNxdWVlemUoKS5kZXRhY2goKS5mbG9hdCgpLmNwdSgpLmNvbnRpZ3VvdXMoKQogICAgICAgICAgICBkZWwgcHJlZHMKICAgICAgICAgICAgcHJlZHMgPSBOb25lCiAgICAgICAgICAgIGlmIHVzZV9jdWRhOgogICAgICAgICAgICAgICAgdG9yY2guY3VkYS5zeW5jaHJvbml6ZSgpCiAgICBmaW5hbGx5OgogICAgICAgIGRlbCB4CiAgICAgICAgaWYgcHJlZHMgaXMgbm90IE5vbmU6CiAgICAgICAgICAgIGRlbCBwcmVkcwogICAgICAgIGlmIHVzZV9jdWRhOgogICAgICAgICAgICBjdWRhX2NsZWFyKCLvvIjmjqjnkIblkI7vvIkiKQoKICAgIG1hc2sgPSB0cmFuc2Zvcm1zLlRvUElMSW1hZ2UoKShwcmVkKS5yZXNpemUocmdiLnNpemUsIEltYWdlLkJJTElORUFSKQogICAgZGVsIHByZWQKICAgIG1hc2sgPSByZWZpbmVfbWFzayhtYXNrLCBmZWF0aGVyPWZlYXRoZXIpCiAgICBvdXQgPSByZ2IuY29weSgpCiAgICBvdXQucHV0YWxwaGEobWFzaykKICAgIHJldHVybiBvdXQKCgpkZWYgbG9hZF9tb2RlbChtb2RlbF9kaXI6IFBhdGgsIGRldmljZTogdG9yY2guZGV2aWNlKToKICAgIGxvZyhmIlsqXSDliqDovb0gQmlSZWZOZXQ6IHttb2RlbF9kaXJ9IikKICAgIGlmIG5vdCAobW9kZWxfZGlyIC8gImNvbmZpZy5qc29uIikuaXNfZmlsZSgpOgogICAgICAgIHJhaXNlIEZpbGVOb3RGb3VuZEVycm9yKGYi5qih5Z6L55uu5b2V57y65bCRIGNvbmZpZy5qc29uOiB7bW9kZWxfZGlyfSIpCiAgICBpZiBub3QgKG1vZGVsX2RpciAvICJtb2RlbC5zYWZldGVuc29ycyIpLmlzX2ZpbGUoKSBhbmQgbm90IChtb2RlbF9kaXIgLyAicHl0b3JjaF9tb2RlbC5iaW4iKS5pc19maWxlKCk6CiAgICAgICAgcmFpc2UgRmlsZU5vdEZvdW5kRXJyb3IoZiLmqKHlnovnm67lvZXnvLrlsJHmnYPph43mlofku7Y6IHttb2RlbF9kaXJ9IikKCiAgICBpZiBkZXZpY2UudHlwZSA9PSAiY3VkYSI6CiAgICAgICAgY3VkYV9jbGVhcigi77yI5Yqg6L295YmN77yJIikKCiAgICBtb2RlbCA9IEF1dG9Nb2RlbEZvckltYWdlU2VnbWVudGF0aW9uLmZyb21fcHJldHJhaW5lZCgKICAgICAgICBzdHIobW9kZWxfZGlyKSwKICAgICAgICB0cnVzdF9yZW1vdGVfY29kZT1UcnVlLAogICAgICAgIHRvcmNoX2R0eXBlPXRvcmNoLmZsb2F0MTYgaWYgZGV2aWNlLnR5cGUgPT0gImN1ZGEiIGVsc2UgdG9yY2guZmxvYXQzMiwKICAgICkKICAgIG1vZGVsID0gbW9kZWwudG8oZGV2aWNlKQogICAgaWYgZGV2aWNlLnR5cGUgPT0gImN1ZGEiOgogICAgICAgIG1vZGVsID0gbW9kZWwuaGFsZigpCiAgICBtb2RlbC5ldmFsKCkKICAgIGZvciBwIGluIG1vZGVsLnBhcmFtZXRlcnMoKToKICAgICAgICBwLnJlcXVpcmVzX2dyYWRfKEZhbHNlKQoKICAgIGlmIGRldmljZS50eXBlID09ICJjdWRhIjoKICAgICAgICBjdWRhX2NsZWFyKCLvvIjliqDovb3lkI7vvIkiKQogICAgcmV0dXJuIG1vZGVsCgoKZGVmIGluZmVyX2tlZXBfc2l6ZShtb2RlbCwgbW9kZWxfZGlyLCBpbWFnZSwgZGV2aWNlLCBzaXplLCBmZWF0aGVyKToKICAgICIiIuS/neaMgeWIhui+qOeOh++8m0NVREEg5aSx6LSl5YiZIGRldmljZSByZXNldCArIOmHjei9veaooeWei+WGjeivleS4gOasoeOAgiIiIgogICAgdHJ5OgogICAgICAgIHJldHVybiBwcm9jZXNzX2ltYWdlKG1vZGVsLCBpbWFnZSwgZGV2aWNlLCBzaXplPXNpemUsIGZlYXRoZXI9ZmVhdGhlciksIG1vZGVsCiAgICBleGNlcHQgRXhjZXB0aW9uIGFzIGU6CiAgICAgICAgaWYgZGV2aWNlLnR5cGUgIT0gImN1ZGEiIG9yIG5vdCBpc19jdWRhX2ZhaWwoZSk6CiAgICAgICAgICAgIHJhaXNlCiAgICAgICAgbG9nKGYiWyFdIENVREEg5byC5bi477yI5L+d5oyBIHtzaXplfXh7c2l6ZX3vvIk6IHtlfSIpCiAgICAgICAgbG9nKCJbKl0g5Lii5byD5qih5Z6LIOKGkiBjdWRhRGV2aWNlUmVzZXQg4oaSIOmHjei9vSDihpIg5Y6f5YiG6L6o546H6YeN6K+V4oCmIikKICAgICAgICB0cnk6CiAgICAgICAgICAgIGRlbCBtb2RlbAogICAgICAgIGV4Y2VwdCBFeGNlcHRpb246CiAgICAgICAgICAgIHBhc3MKICAgICAgICBtb2RlbCA9IE5vbmUKICAgICAgICBnYy5jb2xsZWN0KCkKICAgICAgICBjdWRhX2RldmljZV9yZXNldCgi77yI6YeN6K+V5YmN77yJIikKICAgICAgICBsb2dfc3lzdGVtX2dwdSgpCiAgICAgICAgbW9kZWwgPSBsb2FkX21vZGVsKG1vZGVsX2RpciwgZGV2aWNlKQogICAgICAgIG91dCA9IHByb2Nlc3NfaW1hZ2UobW9kZWwsIGltYWdlLCBkZXZpY2UsIHNpemU9c2l6ZSwgZmVhdGhlcj1mZWF0aGVyKQogICAgICAgIHJldHVybiBvdXQsIG1vZGVsCgoKZGVmIG1haW4oKSAtPiBpbnQ6CiAgICBpZiBoYXNhdHRyKHN5cy5zdGRvdXQsICJyZWNvbmZpZ3VyZSIpOgogICAgICAgIHRyeToKICAgICAgICAgICAgc3lzLnN0ZG91dC5yZWNvbmZpZ3VyZShlbmNvZGluZz0idXRmLTgiLCBlcnJvcnM9InJlcGxhY2UiKQogICAgICAgICAgICBzeXMuc3RkZXJyLnJlY29uZmlndXJlKGVuY29kaW5nPSJ1dGYtOCIsIGVycm9ycz0icmVwbGFjZSIpCiAgICAgICAgZXhjZXB0IEV4Y2VwdGlvbjoKICAgICAgICAgICAgcGFzcwoKICAgIHBhcnNlciA9IGFyZ3BhcnNlLkFyZ3VtZW50UGFyc2VyKGRlc2NyaXB0aW9uPSJCaVJlZk5ldCBCRyBSZW1vdmVyIENMSSIpCiAgICBwYXJzZXIuYWRkX2FyZ3VtZW50KCItaSIsICItLWlucHV0IiwgcmVxdWlyZWQ9VHJ1ZSwgaGVscD0iSW5wdXQgaW1hZ2UgcGF0aCIpCiAgICBwYXJzZXIuYWRkX2FyZ3VtZW50KCItbyIsICItLW91dHB1dCIsIHJlcXVpcmVkPVRydWUsIGhlbHA9Ik91dHB1dCBQTkcgcGF0aCIpCiAgICBwYXJzZXIuYWRkX2FyZ3VtZW50KCItbSIsICItLW1vZGVsX2RpciIsIHJlcXVpcmVkPVRydWUsIGhlbHA9IkxvY2FsIEJpUmVmTmV0IG1vZGVsIGRpcmVjdG9yeSIpCiAgICBwYXJzZXIuYWRkX2FyZ3VtZW50KCItLXNpemUiLCB0eXBlPWludCwgZGVmYXVsdD0xMDI0LCBoZWxwPSJJbmZlcmVuY2Ugc2l6ZSAoZGVmYXVsdCAxMDI0KSIpCiAgICBwYXJzZXIuYWRkX2FyZ3VtZW50KCItLWZlYXRoZXIiLCB0eXBlPWZsb2F0LCBkZWZhdWx0PTAuOCwgaGVscD0iRWRnZSBmZWF0aGVyIHNpZ21hICgwPW9mZikiKQogICAgcGFyc2VyLmFkZF9hcmd1bWVudCgiLS1jcHUiLCBhY3Rpb249InN0b3JlX3RydWUiLCBoZWxwPSJGb3JjZSBDUFUiKQogICAgYXJncyA9IHBhcnNlci5wYXJzZV9hcmdzKCkKCiAgICBpbnB1dF9wYXRoID0gUGF0aChhcmdzLmlucHV0KQogICAgb3V0cHV0X3BhdGggPSBQYXRoKGFyZ3Mub3V0cHV0KQogICAgbW9kZWxfZGlyID0gUGF0aChhcmdzLm1vZGVsX2RpcikKCiAgICBpZiBub3QgaW5wdXRfcGF0aC5pc19maWxlKCk6CiAgICAgICAgbG9nKGYiW1hdIOi+k+WFpeWbvueJh+S4jeWtmOWcqDoge2lucHV0X3BhdGh9IikKICAgICAgICByZXR1cm4gMQogICAgaWYgbm90IG1vZGVsX2Rpci5pc19kaXIoKToKICAgICAgICBsb2coZiJbWF0g5qih5Z6L55uu5b2V5LiN5a2Y5ZyoOiB7bW9kZWxfZGlyfSIpCiAgICAgICAgcmV0dXJuIDEKCiAgICBpZiBhcmdzLmNwdSBvciBub3QgdG9yY2guY3VkYS5pc19hdmFpbGFibGUoKToKICAgICAgICBkZXZpY2UgPSB0b3JjaC5kZXZpY2UoImNwdSIpCiAgICBlbHNlOgogICAgICAgIGRldmljZSA9IHRvcmNoLmRldmljZSgiY3VkYSIpCgogICAgbG9nKGYiWypdIOiuvuWkhzoge2RldmljZX0iICsgKGYiICh7dG9yY2guY3VkYS5nZXRfZGV2aWNlX25hbWUoMCl9KSIgaWYgZGV2aWNlLnR5cGUgPT0gImN1ZGEiIGVsc2UgIiIpKQogICAgaWYgZGV2aWNlLnR5cGUgPT0gImN1ZGEiOgogICAgICAgIHRvdGFsID0gdG9yY2guY3VkYS5nZXRfZGV2aWNlX3Byb3BlcnRpZXMoMCkudG90YWxfbWVtb3J5IC8gKDEwMjQgKiogMykKICAgICAgICBsb2coZiJbaV0g5pi+5a2Y5oC76YePIHt0b3RhbDouMWZ9IEdpQu+8m0FMTE9DX0NPTkY9e29zLmVudmlyb24uZ2V0KCdQWVRPUkNIX0NVREFfQUxMT0NfQ09ORicpfSIpCiAgICAgICAgIyDlvIDot5HliY3lhYjnoazph43nva7kuIDmrKHvvIzmuIXmjonkuIrkuIDmrKHov5vnqIvmrovnlZnnmoTlnY/kuIrkuIvmlocKICAgICAgICBjdWRhX2RldmljZV9yZXNldCgi77yI5ZCv5Yqo77yJIikKICAgICAgICBsb2dfc3lzdGVtX2dwdSgpCgogICAgdDAgPSB0aW1lLnRpbWUoKQogICAgbW9kZWwgPSBOb25lCiAgICByZXN1bHQgPSBOb25lCiAgICB0cnk6CiAgICAgICAgbW9kZWwgPSBsb2FkX21vZGVsKG1vZGVsX2RpciwgZGV2aWNlKQogICAgICAgIGxvZyhmIlviiJpdIOaooeWei+Wwsee7qiAoe3RpbWUudGltZSgpIC0gdDA6LjFmfXMpIikKCiAgICAgICAgbG9nKGYiWypdIOivu+WPljoge2lucHV0X3BhdGh9IikKICAgICAgICBpbWFnZSA9IEltYWdlLm9wZW4oaW5wdXRfcGF0aCkKICAgICAgICBpbWFnZS5sb2FkKCkKICAgICAgICBsb2coZiJbaV0g5bC65a+4IHtpbWFnZS5zaXplWzBdfXh7aW1hZ2Uuc2l6ZVsxXX0g4oaSIOaOqOeQhiB7YXJncy5zaXplfXh7YXJncy5zaXplfSIpCgogICAgICAgIGxvZygiWypdIOaKoOWbvuS4reKApiIpCiAgICAgICAgdDEgPSB0aW1lLnRpbWUoKQogICAgICAgIHJlc3VsdCwgbW9kZWwgPSBpbmZlcl9rZWVwX3NpemUobW9kZWwsIG1vZGVsX2RpciwgaW1hZ2UsIGRldmljZSwgYXJncy5zaXplLCBhcmdzLmZlYXRoZXIpCiAgICAgICAgbG9nKGYiW+KIml0g5o6o55CG5a6M5oiQICh7dGltZS50aW1lKCkgLSB0MTouMWZ9cykiKQogICAgZXhjZXB0IEV4Y2VwdGlvbiBhcyBlOgogICAgICAgIGxvZyhmIltYXSDmjqjnkIblpLHotKU6IHtlfSIpCiAgICAgICAgaWYgZGV2aWNlLnR5cGUgPT0gImN1ZGEiOgogICAgICAgICAgICB0cnk6CiAgICAgICAgICAgICAgICBkZWwgbW9kZWwKICAgICAgICAgICAgZXhjZXB0IEV4Y2VwdGlvbjoKICAgICAgICAgICAgICAgIHBhc3MKICAgICAgICAgICAgbW9kZWwgPSBOb25lCiAgICAgICAgICAgIGN1ZGFfZGV2aWNlX3Jlc2V0KCLvvIjlpLHotKXmlLblsL7vvIkiKQogICAgICAgIHJldHVybiAxCiAgICBmaW5hbGx5OgogICAgICAgIHRyeToKICAgICAgICAgICAgZGVsIG1vZGVsCiAgICAgICAgZXhjZXB0IEV4Y2VwdGlvbjoKICAgICAgICAgICAgcGFzcwogICAgICAgIGlmIGRldmljZS50eXBlID09ICJjdWRhIjoKICAgICAgICAgICAgY3VkYV9jbGVhcigi77yI5pS25bC+77yJIikKCiAgICBpZiByZXN1bHQgaXMgTm9uZToKICAgICAgICByZXR1cm4gMQoKICAgIG91dHB1dF9wYXRoLnBhcmVudC5ta2RpcihwYXJlbnRzPVRydWUsIGV4aXN0X29rPVRydWUpCiAgICB0cnk6CiAgICAgICAgcmVzdWx0LnNhdmUob3V0cHV0X3BhdGgsICJQTkciLCBvcHRpbWl6ZT1UcnVlKQogICAgZXhjZXB0IEV4Y2VwdGlvbiBhcyBlOgogICAgICAgIGxvZyhmIltYXSDkv53lrZjlpLHotKU6IHtlfSIpCiAgICAgICAgcmV0dXJuIDEKCiAgICBsb2coZiJb4oiaXSDlt7Lkv53lrZjpgI/mmI7lm746IHtvdXRwdXRfcGF0aH0iKQogICAgbG9nKGYiW2ldIOaAu+iAl+aXtiB7dGltZS50aW1lKCkgLSB0MDouMWZ9cyAgc2l6ZT17b3V0cHV0X3BhdGguc3RhdCgpLnN0X3NpemV9IikKICAgIHJldHVybiAwCgoKaWYgX19uYW1lX18gPT0gIl9fbWFpbl9fIjoKICAgIHJhaXNlIFN5c3RlbUV4aXQobWFpbigpKQo=
;########################################################################################################### remove_bg.py
