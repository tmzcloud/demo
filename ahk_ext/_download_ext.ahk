; 下载页：aria2c + 用户自设 Git 镜像 / 保存目录
#Requires AutoHotkey v2.0

global DL_JOBS := Map()
global DL_POLL_ON := false
global DL_DIR := ""
global DL_SETTINGS := ""

DlSettingsPath() {
    global SEARCH_DIR
    base := ""
    try base := SEARCH_DIR
    if base = ""
        base := A_ScriptDir "\data\local_search"
    try DirCreate base
    return base "\download_settings.json"
}

DlDefaultDownloadsDir() {
    d := ""
    try d := EnvGet("USERPROFILE") "\Downloads"
    if d = "" || !DirExist(d) {
        try d := A_MyDocuments
    }
    if d = "" || !DirExist(d)
        d := A_Desktop
    return d
}

DlDefaultSettings() {
    return {
        dir: DlDefaultDownloadsDir(),
        mirrors: ["https://gh.tszai.cn"],
        failover: true,
        conn: 16
    }
}

DlLoadSettings() {
    global DL_SETTINGS, DL_DIR
    def := DlDefaultSettings()
    path := DlSettingsPath()
    raw := ""
    try {
        if FileExist(path)
            raw := Trim(FileRead(path, "UTF-8"))
    }
    s := def
    if raw != "" {
        try {
            ; 极简解析：dir / failover / conn / mirrors
            if RegExMatch(raw, 'i)"dir"\s*:\s*"([^"]*)"', &m)
                s.dir := StrReplace(StrReplace(m[1], "\\", "\"), "\/", "/")
            if RegExMatch(raw, 'i)"failover"\s*:\s*(true|false)', &m)
                s.failover := (StrLower(m[1]) = "true")
            if RegExMatch(raw, 'i)"conn"\s*:\s*(\d+)', &m)
                s.conn := Max(1, Min(32, Integer(m[1])))
            mirrors := []
            if RegExMatch(raw, 'i)"mirrors"\s*:\s*\[([^\]]*)\]', &mm) {
                body := mm[1]
                pos := 1
                while RegExMatch(body, '"([^"]+)"', &u, pos) {
                    mirrors.Push(Trim(u[1]))
                    pos := u.Pos + u.Len
                }
            }
            if mirrors.Length
                s.mirrors := mirrors
        } catch {
            s := def
        }
    }
    if s.dir = "" || !DirExist(s.dir) {
        try DirCreate s.dir
        if !DirExist(s.dir)
            s.dir := DlDefaultDownloadsDir()
    }
    try DirCreate s.dir
    DL_DIR := s.dir
    DL_SETTINGS := s
    return s
}

DlSaveSettingsObj(s) {
    global DL_SETTINGS, DL_DIR
    if !IsObject(s)
        s := DlDefaultSettings()
    dir := Trim(String(s.HasProp("dir") ? s.dir : ""))
    if dir = ""
        dir := DlDefaultDownloadsDir()
    try DirCreate dir
    mirrors := []
    if s.HasProp("mirrors") && IsObject(s.mirrors) {
        for m in s.mirrors {
            m := Trim(String(m))
            if m != ""
                mirrors.Push(m)
        }
    }
    if mirrors.Length < 1
        mirrors := ["https://gh.tszai.cn"]
    conn := 16
    try conn := Integer(s.HasProp("conn") ? s.conn : 16)
    conn := Max(1, Min(32, conn))
    failover := true
    if s.HasProp("failover")
        failover := !!s.failover
    out := "{"
        . '"dir":' JStr(dir) ","
        . '"failover":' (failover ? "true" : "false") ","
        . '"conn":' conn ","
        . '"mirrors":['
    for i, m in mirrors
        out .= (i > 1 ? "," : "") JStr(m)
    out .= "]}"
    path := DlSettingsPath()
    try FileDelete path
    FileAppend out, path, "UTF-8"
    DL_DIR := dir
    DL_SETTINGS := { dir: dir, mirrors: mirrors, failover: failover, conn: conn }
    return DL_SETTINGS
}

DlGetSettings() {
    global DL_SETTINGS
    if !IsObject(DL_SETTINGS)
        return DlLoadSettings()
    return DL_SETTINGS
}

DlDataDir() {
    global DL_DIR
    s := DlGetSettings()
    d := s.HasProp("dir") ? s.dir : ""
    if d = "" || !DirExist(d) {
        s := DlLoadSettings()
        d := s.dir
    }
    try DirCreate d
    DL_DIR := d
    return d
}

DlStartPoll(*) {
    global DL_POLL_ON
    if DL_POLL_ON
        return
    DL_POLL_ON := true
    SetTimer(DlPollJobs, 500)
}

DlStopPoll(*) {
    global DL_POLL_ON
    DL_POLL_ON := false
    try SetTimer(DlPollJobs, 0)
}

DlHasActiveJobs() {
    global DL_JOBS
    if !IsObject(DL_JOBS)
        return false
    for id, j in DL_JOBS {
        st := j.HasProp("status") ? j.status : ""
        if st = "active" || st = "paused"
            return true
    }
    return false
}

DlParseAriaSizeToken(tok) {
    tok := Trim(String(tok))
    if !RegExMatch(tok, "i)^([\d.]+)\s*([KMGT]i?B|B)$", &m)
        return -1
    n := Number(m[1])
    u := StrUpper(m[2])
    if u = "B"
        return Integer(n)
    if InStr(u, "K")
        return Integer(n * 1024)
    if InStr(u, "M")
        return Integer(n * 1048576)
    if InStr(u, "G")
        return Integer(n * 1073741824)
    if InStr(u, "T")
        return Integer(n * 1099511627776)
    return -1
}

DlParseAriaLogProgress(logFile) {
    info := { got: -1, total: -1, speed: -1, done: false }
    if logFile = "" || !FileExist(logFile)
        return info
    raw := ""
    try {
        f := FileOpen(logFile, "r")
        if f {
            try {
                sz := f.Length
                if sz > 8192
                    f.Pos := sz - 8192
                raw := f.Read()
            } finally {
                f.Close()
            }
        }
    }
    if raw = ""
        return info
    ; aria2 控制台进度常用 \r 覆写同一行，先拆开再找最后一条有效进度
    raw := StrReplace(raw, "`r", "`n")
    if RegExMatch(raw, "i)download completed|\(OK\):download completed|Download Results:")
        info.done := true
    last := ""
    loop parse raw, "`n", "`r" {
        line := Trim(A_LoopField)
        if line = ""
            continue
        ; 去掉 ANSI 颜色码
        line := RegExReplace(line, "\x1b\[[0-9;]*m", "")
        if InStr(line, "[#") && (InStr(line, "/") || InStr(line, "DL:"))
            last := line
    }
    if last = ""
        return info
    if RegExMatch(last, "i)\[#[^\s\]]+\s+([0-9.]+[KMGT]i?B)\s*/\s*([0-9.]+[KMGT]i?B)", &m) {
        info.got := DlParseAriaSizeToken(m[1])
        info.total := DlParseAriaSizeToken(m[2])
    } else if RegExMatch(last, "i)([0-9.]+[KMGT]i?B)\s*/\s*([0-9.]+[KMGT]i?B)\s*\((\d+)\s*%\)", &m3) {
        info.got := DlParseAriaSizeToken(m3[1])
        info.total := DlParseAriaSizeToken(m3[2])
    }
    ; 0B/0B：鉴权失败/未开始，当作无进度（勿覆盖 UI 已有 total）
    if Integer(info.total) <= 0 {
        info.total := -1
        info.got := -1
        info.speed := -1
        return info
    }
    if Integer(info.got) < 0
        info.got := -1
    if RegExMatch(last, "i)DL:([0-9.]+[KMGT]i?B)", &m2)
        info.speed := DlParseAriaSizeToken(m2[1])
    return info
}

DlTrackSpeed(j, spd) {
    spd := Integer(spd)
    ; 过滤对齐进度时的假尖刺（如 900MB/0.5s → 上 GB/s），避免当前/平均显示成几百 MB/s
    maxSane := 200 * 1048576 ; 200 MB/s 上限
    if spd > maxSane
        spd := 0
    DlPushSpdHist(j, Max(0, spd))
    if spd <= 0
        return
    if !j.HasProp("maxSpeed") || Integer(j.maxSpeed) < spd
        j.maxSpeed := spd
    if !j.HasProp("minSpeed") || Integer(j.minSpeed) <= 0 || Integer(j.minSpeed) > spd
        j.minSpeed := spd
    sum := Integer(j.HasProp("spdSum") ? j.spdSum : 0) + spd
    n := Integer(j.HasProp("spdN") ? j.spdN : 0) + 1
    j.spdSum := sum
    j.spdN := n
    j.avgSpeed := Integer(sum / Max(1, n))
}

DlJobMissing(j) {
    if !(j.HasProp("status") && j.status = "done")
        return false
    p := j.HasProp("path") ? String(j.path) : ""
    if p = ""
        return true
    return !FileExist(p)
}

DlJobsPath() {
    global SEARCH_DIR
    base := ""
    try base := SEARCH_DIR
    if base = ""
        base := A_ScriptDir "\data\local_search"
    try DirCreate base
    return base "\download_jobs.json"
}

DlPushSpdHist(j, spd) {
    spd := Integer(spd)
    if spd < 0
        spd := 0
    hist := []
    if j.HasProp("spdHist") && IsObject(j.spdHist)
        hist := j.spdHist
    hist.Push(spd)
    while hist.Length > 90
        hist.RemoveAt(1)
    j.spdHist := hist
}

DlSpdHistJson(j) {
    if !(j.HasProp("spdHist") && IsObject(j.spdHist) && j.spdHist.Length)
        return "[]"
    parts := []
    for v in j.spdHist
        parts.Push(Integer(v))
    return "[" ArrJoin(parts, ",") "]"
}

DlJobIconUrl(j) {
    p := j.HasProp("path") ? String(j.path) : ""
    n := j.HasProp("name") ? String(j.name) : ""
    try {
        ; 文件已落盘：按真实路径提 Win11 壳图标（exe/msi 用内嵌图标）
        if p != "" && FileExist(p)
            return ShellIconUrl(p, false)
        ; 下载中：先按扩展名占位，完成后再换真图标
        probe := (p != "" ? p : n)
        if probe != ""
            return ShellIconUrlList(probe, false)
    }
    return ""
}

global DL_SAVE_AT := 0
DlSaveJobs(force := false) {
    global DL_JOBS, DL_SAVE_AT
    now := A_TickCount
    if !force && DL_SAVE_AT && (now - DL_SAVE_AT) < 1200
        return
    DL_SAVE_AT := now
    path := DlJobsPath()
    arr := []
    for id, j in DL_JOBS {
        urlsJson := "[]"
        if j.HasProp("urls") && IsObject(j.urls) {
            uParts := []
            for u in j.urls
                uParts.Push(JStr(u))
            urlsJson := "[" ArrJoin(uParts, ",") "]"
        }
        arr.Push("{"
            . '"id":' JStr(id) ","
            . '"name":' JStr(j.HasProp("name") ? j.name : "") ","
            . '"url":' JStr(j.HasProp("url") ? j.url : "") ","
            . '"path":' JStr(j.HasProp("path") ? j.path : "") ","
            . '"dir":' JStr(j.HasProp("dir") ? j.dir : "") ","
            . '"status":' JStr(j.HasProp("status") ? j.status : "") ","
            . '"got":' Integer(j.HasProp("got") ? j.got : 0) ","
            . '"total":' Integer(j.HasProp("total") ? j.total : 0) ","
            . '"maxSpeed":' Integer(j.HasProp("maxSpeed") ? j.maxSpeed : 0) ","
            . '"minSpeed":' Integer(j.HasProp("minSpeed") ? j.minSpeed : 0) ","
            . '"avgSpeed":' Integer(j.HasProp("avgSpeed") ? j.avgSpeed : 0) ","
            . '"spdSum":' Integer(j.HasProp("spdSum") ? j.spdSum : 0) ","
            . '"spdN":' Integer(j.HasProp("spdN") ? j.spdN : 0) ","
            . '"createdAt":' JStr(j.HasProp("createdAt") ? j.createdAt : "") ","
            . '"createdTick":' Integer(j.HasProp("createdTick") ? j.createdTick : 0) ","
            . '"finishedAt":' JStr(j.HasProp("finishedAt") ? j.finishedAt : "") ","
            . '"engine":' JStr(j.HasProp("engine") ? j.engine : "") ","
            . '"conn":' Integer(j.HasProp("conn") ? j.conn : 16) ","
            . '"urlIdx":' Integer(j.HasProp("urlIdx") ? j.urlIdx : 1) ","
            . '"failover":' ((j.HasProp("failover") && j.failover) ? "true" : "false") ","
            . '"aria":' JStr(j.HasProp("aria") ? j.aria : "") ","
            . '"spdHist":' DlSpdHistJson(j) ","
            . '"urls":' urlsJson ","
            . '"md5":' JStr(j.HasProp("md5") ? j.md5 : "") ","
            . '"sha1":' JStr(j.HasProp("sha1") ? j.sha1 : "") ","
            . '"sha256":' JStr(j.HasProp("sha256") ? j.sha256 : "") ","
            . '"hashStatus":' JStr(j.HasProp("hashStatus") ? j.hashStatus : "") ","
            . '"hashErr":' JStr(j.HasProp("hashErr") ? j.hashErr : "")
            . "}")
    }
    out := "{`"jobs`":[" ArrJoin(arr, ",") "]}"
    try FileDelete path
    try FileAppend out, path, "UTF-8"
}

DlParseJsonStrField(blk, key) {
    if RegExMatch(blk, 'i)"' key '"\s*:\s*"((?:\\.|[^"\\])*)"', &m)
        return StrReplace(m[1], "\\", "\")
    return ""
}

DlParseJsonIntField(blk, key, def := 0) {
    if RegExMatch(blk, 'i)"' key '"\s*:\s*(-?\d+)', &m)
        return Integer(m[1])
    return def
}

DlParseJsonBoolField(blk, key, def := false) {
    if RegExMatch(blk, 'i)"' key '"\s*:\s*(true|false)', &m)
        return (StrLower(m[1]) = "true")
    return def
}

; HuggingFace 等常返回几 KB HTML 错误页，不能当完成
DlIsBogusDownload(path, name := "") {
    p := Trim(String(path))
    if p = "" || !FileExist(p)
        return true
    sz := 0
    try sz := FileGetSize(p)
    if sz <= 0
        return true
    n := name != "" ? name : p
    ; 大文件扩展名却只有几 KB → 基本是错误页/登录页
    if RegExMatch(n, "i)\.(safetensors|gguf|pt|pth|bin|onnx|tpz|zip|7z|rar|exe|msi|iso|dmg|tar|gz|xz|apk|msix)$") {
        if sz < 256 * 1024
            return true
    }
    if sz < 64
        return true
    try {
        f := FileOpen(p, "r")
        if f {
            head := f.Read(512)
            f.Close()
            if RegExMatch(head, "i)^\s*<(!DOCTYPE\s+)?html|^\s*<\?xml|^\s*<svg")
                return true
            if InStr(head, "AccessDenied") || InStr(head, "Entry not found") || InStr(head, "Invalid username")
                return true
        }
    }
    return false
}

; 完成时清 .aria2/.part 与 _aria_job_*.cmd/log（进程被杀时 aria2 常留控制文件，导致重开又显示进度）
DlCleanupJobTemps(j) {
    if !IsObject(j)
        return
    p := j.HasProp("path") ? String(j.path) : ""
    if p != "" {
        try FileDelete p ".aria2"
        try FileDelete p ".part"
    }
    try {
        if j.HasProp("cmd") && j.cmd != ""
            FileDelete j.cmd
    }
    try {
        if j.HasProp("log") && j.log != ""
            FileDelete j.log
    }
}

; 目录里无任务引用的 _aria_job_*/_curl_job_* / 孤儿 .aria2|.part 残骸
DlSweepOrphanJobTemps(dir) {
    dir := RTrim(String(dir), "\/")
    if dir = "" || !DirExist(dir)
        return
    global DL_JOBS
    keepCmd := Map()
    keepPath := Map() ; 仅 active/paused 占用的目标路径（小写）
    if IsObject(DL_JOBS) {
        for , j in DL_JOBS {
            st := j.HasProp("status") ? String(j.status) : ""
            if st = "active" || st = "paused" {
                if j.HasProp("cmd") && j.cmd != ""
                    keepCmd[StrLower(j.cmd)] := true
                if j.HasProp("log") && j.log != ""
                    keepCmd[StrLower(j.log)] := true
                p := j.HasProp("path") ? StrLower(String(j.path)) : ""
                if p != ""
                    keepPath[p] := true
            }
        }
    }
    for pat in ["\_aria_job_*.*", "\_curl_job_*.*"] {
        loop files dir pat {
            fp := A_LoopFileFullPath
            if keepCmd.Has(StrLower(fp))
                continue
            try FileDelete fp
        }
    }
    ; 孤儿控制文件：没有 active/paused 任务占用，或主文件已不存在
    for pat in ["\*.aria2", "\*.part"] {
        loop files dir pat {
            fp := A_LoopFileFullPath
            base := RegExReplace(fp, "i)\.(aria2|part)$")
            if keepPath.Has(StrLower(base))
                continue
            try FileDelete fp
        }
    }
}

; 是否真正下完。注意：无 .aria2 ≠ 完成（多连接虚高文件 + 控制文件被清掉时极易误判）
DlJobLooksComplete(j) {
    p := j.HasProp("path") ? String(j.path) : ""
    if p = "" || !FileExist(p)
        return false
    nm := j.HasProp("name") ? String(j.name) : ""
    if DlIsBogusDownload(p, nm)
        return false
    sz := 0
    try sz := FileGetSize(p)
    if sz <= 0
        return false
    hasCtrl := FileExist(p ".aria2") || FileExist(p ".part")
    alive := j.HasProp("pid") && Integer(j.pid) > 0 && ProcessExist(j.pid)
    if alive
        return false
    tot := Integer(j.HasProp("total") ? j.total : 0)
    got := Integer(j.HasProp("got") ? j.got : 0)
    logDone := false
    try {
        if j.HasProp("log") && j.log != "" && FileExist(j.log) {
            prog := DlParseAriaLogProgress(j.log)
            logDone := !!prog.done
            if !logDone {
                tail := FileRead(j.log, "UTF-8")
                if InStr(tail, "Download complete") || InStr(tail, "(OK):download completed")
                    || InStr(tail, "|OK |") || InStr(tail, "|OK|")
                    logDone := true
            }
            if Integer(prog.total) > 0
                tot := Integer(prog.total)
            if Integer(prog.got) >= 0
                got := Integer(prog.got)
        }
    }
    if logDone {
        try FileDelete p ".aria2"
        try FileDelete p ".part"
        return true
    }
    ; 有控制文件：未完成，可续传
    if hasCtrl
        return false
    ; 无控制文件：必须「可信 got」达到 total；禁止只用磁盘尺寸（多连接虚高）
    if tot > 0 && got >= tot {
        return true
    }
    return false
}

; 关闭/落盘前：把已下完却仍 active/paused 的任务收成 done，并扫一遍临时文件
DlFinalizeCompleteJobs(*) {
    global DL_JOBS
    if !IsObject(DL_JOBS)
        return
    any := false
    dirs := Map()
    for id, j in DL_JOBS {
        st := j.HasProp("status") ? String(j.status) : ""
        if j.HasProp("dir") && j.dir != ""
            dirs[StrLower(j.dir)] := j.dir
        if st != "active" && st != "paused" && st != "error"
            continue
        if !DlJobLooksComplete(j)
            continue
        DL_JOBS[id] := DlMarkJobDone(j)
        any := true
    }
    try dirs[StrLower(DlDataDir())] := DlDataDir()
    for , d in dirs
        DlSweepOrphanJobTemps(d)
    if any
        try DlSaveJobs(true)
}

DlMarkJobDone(j) {
    p := j.HasProp("path") ? String(j.path) : ""
    got := Integer(j.HasProp("got") ? j.got : 0)
    tot := Integer(j.HasProp("total") ? j.total : 0)
    ; 完成时可用磁盘大小；但若仍有控制文件则不应走到这里
    if p != "" && FileExist(p) && !FileExist(p ".aria2") && !FileExist(p ".part") {
        sz := 0
        try sz := FileGetSize(p)
        ; 仅当进度已表明完成，或尺寸与已知 total 接近时才采信磁盘大小
        if sz > 0 && ((tot > 0 && got >= tot) || (tot > 0 && Abs(sz - tot) < Max(1048576, tot * 0.01)))
            got := sz
    }
    j.status := "done"
    j.got := got
    if tot > 0 && got < tot
        j.total := tot
    else
        j.total := got
    j.speed := 0
    j.pid := 0
    j.err := ""
    if !(j.HasProp("finishedAt") && j.finishedAt != "")
        j.finishedAt := FormatTime(, "yyyy-MM-dd HH:mm:ss")
    DlCleanupJobTemps(j)
    j.cmd := ""
    j.log := ""
    try {
        if j.HasProp("dir") && j.dir != ""
            DlSweepOrphanJobTemps(j.dir)
    }
    ; 异步算 MD5 / SHA-1 / SHA-256（详情页展示）；仍有控制文件则先别排队
    p0 := j.HasProp("path") ? String(j.path) : ""
    if p0 != "" && (FileExist(p0 ".aria2") || FileExist(p0 ".part")) {
        j.hashStatus := ""
    } else if !(j.HasProp("md5") && j.md5 != "" && j.HasProp("sha256") && j.sha256 != "") {
        if !(j.HasProp("hashStatus") && j.hashStatus = "pending")
            j.hashStatus := "queued"
    }
    return j
}

; —— 文件哈希（完成后异步，单通道，避免大文件抢盘）——
global DL_HASH_BUSY := ""

DlHashNeed(j) {
    if !IsObject(j) || (j.HasProp("status") ? j.status : "") != "done"
        return false
    if j.HasProp("missingFlag") && j.missingFlag
        return false
    p := j.HasProp("path") ? String(j.path) : ""
    if p = "" || !FileExist(p) || DirExist(p)
        return false
    ; 仍在下 / 控制文件在：勿校验（文件被 aria2 锁住会 OpenRead 失败）
    if FileExist(p ".aria2") || FileExist(p ".part")
        return false
    if j.HasProp("md5") && j.md5 != "" && j.HasProp("sha1") && j.sha1 != "" && j.HasProp("sha256") && j.sha256 != ""
        return false
    hs := j.HasProp("hashStatus") ? String(j.hashStatus) : ""
    if hs = "error" {
        ; 占用类错误可稍后自动重试；其它失败不循环
        err := j.HasProp("hashErr") ? String(j.hashErr) : ""
        if InStr(err, "正由另一进程使用") || InStr(err, "being used by another") || InStr(err, "Cannot access") || InStr(err, "锁")
            return true
        return false
    }
    return true
}

DlHashOutPath(id) {
    safe := RegExReplace(String(id), "[^\w\-]", "_")
    return A_Temp "\ahk_dl_hash_" safe ".json"
}

DlHashPsPath(id) {
    safe := RegExReplace(String(id), "[^\w\-]", "_")
    return A_Temp "\ahk_dl_hash_" safe ".ps1"
}

DlStartFileHash(id) {
    global DL_JOBS, DL_HASH_BUSY
    id := String(id)
    if id = "" || !DL_JOBS.Has(id)
        return false
    if DL_HASH_BUSY != "" && DL_HASH_BUSY != id {
        ; 其它任务在算：本任务保持 queued
        return false
    }
    j := DL_JOBS[id]
    if !DlHashNeed(j) && !(j.HasProp("hashStatus") && j.hashStatus = "queued")
        return false
    p := String(j.path)
    if p = "" || !FileExist(p)
        return false
    out := DlHashOutPath(id)
    ps1 := DlHashPsPath(id)
    try FileDelete out
    try FileDelete ps1
    pe := StrReplace(p, "'", "''")
    oe := StrReplace(out, "'", "''")
    body := "$ErrorActionPreference='Stop'`n"
        . "$p='" pe "'`n"
        . "$out='" oe "'`n"
        . "$r=[ordered]@{md5='';sha1='';sha256='';err=''}`n"
        . "try{`n"
        . "  $md5=[System.Security.Cryptography.MD5]::Create()`n"
        . "  $sha1=[System.Security.Cryptography.SHA1]::Create()`n"
        . "  $sha256=[System.Security.Cryptography.SHA256]::Create()`n"
        . "  $fs=$null`n"
        . "  for($i=0;$i -lt 8;$i++){`n"
        . "    try{`n"
        . "      $fs=[System.IO.File]::Open($p,[System.IO.FileMode]::Open,[System.IO.FileAccess]::Read,[System.IO.FileShare]::ReadWrite)`n"
        . "      break`n"
        . "    } catch {`n"
        . "      if($i -ge 7){ throw }`n"
        . "      Start-Sleep -Milliseconds (400*($i+1))`n"
        . "    }`n"
        . "  }`n"
        . "  try{`n"
        . "    $buf=New-Object byte[] 4194304`n"
        . "    while(($n=$fs.Read($buf,0,$buf.Length)) -gt 0){`n"
        . "      [void]$md5.TransformBlock($buf,0,$n,$null,0)`n"
        . "      [void]$sha1.TransformBlock($buf,0,$n,$null,0)`n"
        . "      [void]$sha256.TransformBlock($buf,0,$n,$null,0)`n"
        . "    }`n"
        . "    [void]$md5.TransformFinalBlock([byte[]]::new(0),0,0)`n"
        . "    [void]$sha1.TransformFinalBlock([byte[]]::new(0),0,0)`n"
        . "    [void]$sha256.TransformFinalBlock([byte[]]::new(0),0,0)`n"
        . "    $r.md5=[BitConverter]::ToString($md5.Hash).Replace('-','').ToLowerInvariant()`n"
        . "    $r.sha1=[BitConverter]::ToString($sha1.Hash).Replace('-','').ToLowerInvariant()`n"
        . "    $r.sha256=[BitConverter]::ToString($sha256.Hash).Replace('-','').ToLowerInvariant()`n"
        . "  } finally { if($fs){$fs.Dispose()}; $md5.Dispose(); $sha1.Dispose(); $sha256.Dispose() }`n"
        . "} catch { $r.err = [string]$_.Exception.Message }`n"
        . "($r|ConvertTo-Json -Compress)|Set-Content -LiteralPath $out -Encoding utf8`n"
    try FileAppend body, ps1, "UTF-8"
    catch
        return false
    pid := 0
    try Run('powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' ps1 '"', A_Temp, "Hide", &pid)
    catch
        return false
    if !pid
        return false
    j.hashStatus := "pending"
    j.hashPid := pid
    j.hashOut := out
    DL_JOBS[id] := j
    DL_HASH_BUSY := id
    return true
}

DlPollFileHashes(*) {
    global DL_JOBS, DL_HASH_BUSY
    if !IsObject(DL_JOBS)
        return false
    changed := false
    ; 收割当前 busy
    busy := String(DL_HASH_BUSY)
    if busy != "" && DL_JOBS.Has(busy) {
        j := DL_JOBS[busy]
        out := j.HasProp("hashOut") ? String(j.hashOut) : DlHashOutPath(busy)
        alive := j.HasProp("hashPid") && Integer(j.hashPid) > 0 && ProcessExist(j.hashPid)
        if FileExist(out) {
            raw := ""
            try raw := Trim(FileRead(out, "UTF-8"), " `t`r`n​")
            ; 进程还在写则等下一轮；文件非空且含 md5 键再解析
            if raw != "" && InStr(raw, "md5") {
                md5 := "", sha1 := "", sha256 := "", err := ""
                if RegExMatch(raw, 'i)"md5"\s*:\s*"([^"]*)"', &m)
                    md5 := m[1]
                if RegExMatch(raw, 'i)"sha1"\s*:\s*"([^"]*)"', &m)
                    sha1 := m[1]
                if RegExMatch(raw, 'i)"sha256"\s*:\s*"([^"]*)"', &m)
                    sha256 := m[1]
                if RegExMatch(raw, 'i)"err"\s*:\s*"((?:\\.|[^"\\])*)"', &m)
                    err := StrReplace(m[1], "\\", "\")
                if md5 != "" || sha1 != "" || sha256 != "" {
                    j.md5 := StrLower(md5)
                    j.sha1 := StrLower(sha1)
                    j.sha256 := StrLower(sha256)
                    j.hashStatus := "done"
                    j.hashErr := ""
                } else {
                    ; 文件被 aria2 占用：回 queued 稍后重试，勿永久失败
                    lockHit := InStr(err, "正由另一进程使用") || InStr(err, "being used by another") || InStr(err, "Cannot access the file")
                    if lockHit || FileExist(String(j.path) ".aria2") || FileExist(String(j.path) ".part") {
                        j.hashStatus := "queued"
                        j.hashErr := ""
                        j.hashRetryAt := A_TickCount + 5000
                    } else {
                        j.hashStatus := "error"
                        j.hashErr := err != "" ? err : "校验失败"
                    }
                }
                j.hashPid := 0
                DL_JOBS[busy] := j
                DL_HASH_BUSY := ""
                changed := true
                try DlSaveJobs(true)
                try FileDelete out
                try FileDelete DlHashPsPath(busy)
            } else if !alive {
                j.hashStatus := "error"
                j.hashErr := "校验进程异常退出"
                j.hashPid := 0
                DL_JOBS[busy] := j
                DL_HASH_BUSY := ""
                changed := true
            }
        } else if !alive {
            j.hashStatus := "error"
            j.hashErr := "校验无结果"
            j.hashPid := 0
            DL_JOBS[busy] := j
            DL_HASH_BUSY := ""
            changed := true
        }
    } else if busy != "" {
        DL_HASH_BUSY := ""
    }
    ; 空闲时启动下一个 queued / 缺哈希的完成任务
    if DL_HASH_BUSY = "" {
        for id, j in DL_JOBS {
            st := j.HasProp("hashStatus") ? String(j.hashStatus) : ""
            if st = "pending"
                continue
            if j.HasProp("hashRetryAt") && Integer(j.hashRetryAt) > A_TickCount
                continue
            if st = "queued" || (st != "done" && st != "error" && DlHashNeed(j)) || (st = "error" && DlHashNeed(j)) {
                if DlStartFileHash(id) {
                    changed := true
                    break
                }
            }
        }
    }
    return changed
}

DlLoadJobs(*) {
    global DL_JOBS
    if !IsObject(DL_JOBS)
        DL_JOBS := Map()
    if DL_JOBS.Count > 0
        return
    path := DlJobsPath()
    if !FileExist(path)
        return
    raw := ""
    try raw := Trim(FileRead(path, "UTF-8"))
    if raw = ""
        return
    pos := 1
    while RegExMatch(raw, '\{[^{}]*"id"\s*:\s*"[^"]+"[^{}]*\}', &blk, pos) {
        body := blk[0]
        id := DlParseJsonStrField(body, "id")
        if id = "" {
            pos := blk.Pos + blk.Len
            continue
        }
        st := DlParseJsonStrField(body, "status")
        if st = "active"
            st := "paused" ; 重开后进程已断，标暂停保留进度
        hist := []
        if RegExMatch(body, 'i)"spdHist"\s*:\s*\[([^\]]*)\]', &hm) {
            loop parse hm[1], "," {
                t := Trim(A_LoopField)
                if t != ""
                    hist.Push(Integer(t))
            }
        }
        urls := []
        if RegExMatch(body, 'i)"urls"\s*:\s*\[([^\]]*)\]', &um) {
            upos := 1
            while RegExMatch(um[1], '"((?:\\.|[^"\\])*)"', &uu, upos) {
                urls.Push(StrReplace(uu[1], "\\", "\"))
                upos := uu.Pos + uu.Len
            }
        }
        p := DlParseJsonStrField(body, "path")
        ; 进度只信 JSON；禁止 FileGetSize 抬高（多连接乱序写盘会虚高到接近整文件）
        got := DlParseJsonIntField(body, "got")
        tot := DlParseJsonIntField(body, "total")
        if tot > 0 && got > tot
            got := tot
        hasCtrl := (p != "" && (FileExist(p ".aria2") || FileExist(p ".part")))
        j := {
            id: id,
            name: DlParseJsonStrField(body, "name"),
            url: DlParseJsonStrField(body, "url"),
            path: p,
            dir: DlParseJsonStrField(body, "dir"),
            status: st,
            got: got,
            total: tot,
            speed: 0,
            maxSpeed: DlParseJsonIntField(body, "maxSpeed"),
            minSpeed: DlParseJsonIntField(body, "minSpeed"),
            avgSpeed: DlParseJsonIntField(body, "avgSpeed"),
            spdSum: DlParseJsonIntField(body, "spdSum"),
            spdN: DlParseJsonIntField(body, "spdN"),
            createdAt: DlParseJsonStrField(body, "createdAt"),
            createdTick: DlParseJsonIntField(body, "createdTick", A_TickCount),
            finishedAt: DlParseJsonStrField(body, "finishedAt"),
            engine: DlParseJsonStrField(body, "engine"),
            conn: DlParseJsonIntField(body, "conn", 16),
            urlIdx: DlParseJsonIntField(body, "urlIdx", 1),
            failover: DlParseJsonBoolField(body, "failover", true),
            aria: DlParseJsonStrField(body, "aria"),
            spdHist: hist,
            urls: urls.Length ? urls : [DlParseJsonStrField(body, "url")],
            pid: 0, cmd: "", log: "",
            t0: A_TickCount, lastGot: got, lastAt: A_TickCount, stallAt: A_TickCount,
            err: "", iconCache: "", iconReal: false,
            md5: DlParseJsonStrField(body, "md5"),
            sha1: DlParseJsonStrField(body, "sha1"),
            sha256: DlParseJsonStrField(body, "sha256"),
            hashStatus: DlParseJsonStrField(body, "hashStatus"),
            hashErr: DlParseJsonStrField(body, "hashErr"),
            hashPid: 0, hashOut: ""
        }
        ; 启动时未完成的校验改回排队（旧 pending 进程已不在）
        if j.hashStatus = "pending"
            j.hashStatus := "queued"
        ; 有控制文件：一定是未完成 → 暂停待续传（收回假「已完成」）
        if hasCtrl {
            j.status := "paused"
            j.finishedAt := ""
            j.hashStatus := ""
            j.hashErr := ""
            j.md5 := "", j.sha1 := "", j.sha256 := ""
        } else if j.status = "done" && tot > 0 && got < tot {
            ; JSON 进度未满却标了完成（重开误判）→ 收回暂停
            j.status := "paused"
            j.finishedAt := ""
            j.hashStatus := ""
            j.hashErr := ""
            j.md5 := "", j.sha1 := "", j.sha256 := ""
        } else if (j.status = "paused" || j.status = "error") && tot > 0 && got >= tot && p != "" && FileExist(p) {
            ; 进度已满且无控制文件 → 真正完成
            j := DlMarkJobDone(j)
        }
        ; 假完成（HTML 错误页等）：删掉列表项和几 KB 垃圾文件，避免堆积 model_2/_3/_4
        if j.status = "done" && DlIsBogusDownload(p, j.HasProp("name") ? j.name : "") {
            if p != "" {
                try FileDelete p
                try FileDelete p ".aria2"
                try FileDelete p ".part"
            }
            pos := blk.Pos + blk.Len
            continue
        }
        ; 已完成但还没哈希 → 排队异步计算
        if j.status = "done" && DlHashNeed(j) && j.hashStatus = ""
            j.hashStatus := "queued"
        ; 连接数始终跟设置
        try j.conn := Max(1, Min(32, Integer(DlGetSettings().conn)))
        DL_JOBS[id] := j
        pos := blk.Pos + blk.Len
    }
    ; 启动时清掉无任务占用的 _aria_job_* / 孤儿 .aria2
    dirs := Map()
    try dirs[StrLower(DlDataDir())] := DlDataDir()
    for , j in DL_JOBS {
        if j.HasProp("dir") && j.dir != ""
            dirs[StrLower(j.dir)] := j.dir
    }
    for , d in dirs
        DlSweepOrphanJobTemps(d)
    try DlSaveJobs(true)
}

DlEmitState() {
    global wvCore, DL_JOBS
    DlSaveJobs(false)
    if !IsObject(wvCore)
        return
    arr := []
    for id, j in DL_JOBS {
        miss := DlJobMissing(j)
        pth := j.HasProp("path") ? String(j.path) : ""
        ; 完成后或本地文件已存在时强制重提真实图标，避免沿用下载中的泛型扩展名图标
        forceIco := (j.HasProp("status") && j.status = "done" && pth != "" && FileExist(pth))
            || (pth != "" && FileExist(pth) && !(j.HasProp("iconReal") && j.iconReal))
        icon := ""
        if !forceIco && j.HasProp("iconCache") && j.iconCache != ""
            icon := j.iconCache
        else {
            icon := DlJobIconUrl(j)
            j.iconCache := icon
            if pth != "" && FileExist(pth)
                j.iconReal := true
            DL_JOBS[id] := j
        }
        arr.Push("{"
            . '"id":' JStr(id) ","
            . '"name":' JStr(j.HasProp("name") ? j.name : "") ","
            . '"url":' JStr(j.HasProp("url") ? j.url : "") ","
            . '"path":' JStr(j.HasProp("path") ? j.path : "") ","
            . '"dir":' JStr(j.HasProp("dir") ? j.dir : "") ","
            . '"status":' JStr(j.HasProp("status") ? j.status : "") ","
            . '"got":' Integer(j.HasProp("got") ? j.got : 0) ","
            . '"total":' Integer(j.HasProp("total") ? j.total : 0) ","
            . '"speed":' Integer(j.HasProp("speed") ? j.speed : 0) ","
            . '"maxSpeed":' Integer(j.HasProp("maxSpeed") ? j.maxSpeed : 0) ","
            . '"minSpeed":' Integer(j.HasProp("minSpeed") ? j.minSpeed : 0) ","
            . '"avgSpeed":' Integer(j.HasProp("avgSpeed") ? j.avgSpeed : 0) ","
            . '"createdAt":' JStr(j.HasProp("createdAt") ? j.createdAt : "") ","
            . '"createdTick":' Integer(j.HasProp("createdTick") ? j.createdTick : 0) ","
            . '"finishedAt":' JStr(j.HasProp("finishedAt") ? j.finishedAt : "") ","
            . '"missing":' (miss ? "true" : "false") ","
            . '"icon":' JStr(icon) ","
            . '"spdHist":' DlSpdHistJson(j) ","
            . '"err":' JStr(j.HasProp("err") ? j.err : "") ","
            . '"md5":' JStr(j.HasProp("md5") ? j.md5 : "") ","
            . '"sha1":' JStr(j.HasProp("sha1") ? j.sha1 : "") ","
            . '"sha256":' JStr(j.HasProp("sha256") ? j.sha256 : "") ","
            . '"hashStatus":' JStr(j.HasProp("hashStatus") ? j.hashStatus : "") ","
            . '"hashErr":' JStr(j.HasProp("hashErr") ? j.hashErr : "")
            . "}")
    }
    js := "try{window.__dlOnState&&window.__dlOnState({jobs:[" . ArrJoin(arr, ",") . "]})}catch(e){}"
    try wvCore.ExecuteScriptAsync(js)
}

DlEmitSettings() {
    global wvCore
    s := DlGetSettings()
    if !IsObject(wvCore)
        return
    mir := []
    for m in s.mirrors
        mir.Push(JStr(m))
    js := "try{window.__dlOnSettings&&window.__dlOnSettings({"
        . "dir:" JStr(s.dir) ","
        . "failover:" (s.failover ? "true" : "false") ","
        . "conn:" Integer(s.conn) ","
        . "mirrors:[" ArrJoin(mir, ",") "]"
        . "})}catch(e){}"
    try wvCore.ExecuteScriptAsync(js)
}

ArrJoin(arr, sep := ",") {
    out := ""
    for i, v in arr
        out .= (i > 1 ? sep : "") v
    return out
}

DlEnsure(*) {
    DlLoadSettings()
    DlLoadJobs()
    dir := DlDataDir()
    aria := ""
    try aria := FindLocalAria2c()
    ok := aria != "" && FileExist(aria)
    global wvCore
    if IsObject(wvCore) {
        js := "try{window.__dlReady&&window.__dlReady(" (ok ? "true" : "false") "," JStr(dir) "," JStr(ok ? aria : "") ")}catch(e){}"
        try wvCore.ExecuteScriptAsync(js)
    }
    DlEmitSettings()
    DlStartPoll()
    DlEmitState()
}

DlPickDir(*) {
    cur := DlDataDir()
    sel := FileSelect("D", cur, "选择下载保存目录")
    if sel = ""
        return
    s := DlGetSettings()
    s.dir := sel
    DlSaveSettingsObj(s)
    DlEmitSettings()
    global wvCore
    if IsObject(wvCore)
        try wvCore.ExecuteScriptAsync("try{window.__dlToast&&window.__dlToast(" JStr("已更换保存目录") ")}catch(e){}")
}

DlGuessName(url) {
    u := Trim(String(url))
    u := RegExReplace(u, "[?#].*$")
    ; 代理 URL：…/https://github.com/…/file.zip → 取最后一段
    name := ""
    if RegExMatch(u, "([^/\\]+)$", &m)
        name := m[1]
    name := RegExReplace(name, '[<>:"/\\|?*]', "_")
    if name = "" || name = "/" || StrLen(name) > 180
        name := "download_" FormatTime(, "yyyyMMdd_HHmmss")
    return name
}

DlReadLogHint(logFile) {
    if logFile = "" || !FileExist(logFile)
        return ""
    raw := ""
    try raw := FileRead(logFile, "UTF-8")
    if raw = ""
        try raw := FileRead(logFile, "CP0")
    if raw = ""
        return ""
    hint := ""
    if RegExMatch(raw, "i)(errorCode=\d+[^\r\n]*|Exception:[^\r\n]*|Failed to connect[^\r\n]*|Name resolution[^\r\n]*|Timeout[^\r\n]*|status=4\d\d[^\r\n]*|403 Forbidden|404 Not Found|401 Unauthorized)", &m)
        hint := Trim(m[1])
    if hint = "" {
        loop parse raw, "`n", "`r" {
            t := Trim(A_LoopField)
            if t = ""
                continue
            ; 跳过进度行 / 纯数字噪音（否则 UI 会显示「0 0 0 100 6500…」）
            if InStr(t, "[#") || InStr(t, "DL:") || InStr(t, "ETA:")
                continue
            if RegExMatch(t, "^[\d\s.%/KMGTB]+$")
                continue
            if RegExMatch(t, "i)redirecting|notice|info:|download complete")
                continue
            hint := t
        }
    }
    hint := RegExReplace(hint, "\[\d{2}/\d{2}[^\]]*\]\s*", "")
    hint := RegExReplace(hint, "\x1b\[[0-9;]*m", "")
    hint := Trim(hint)
    if RegExMatch(hint, "^[\d\s.%]+$")
        return ""
    if StrLen(hint) > 120
        hint := SubStr(hint, 1, 117) "…"
    return hint
}

DlIsHuggingFaceUrl(url) {
    return !!RegExMatch(String(url), "i)(?:huggingface\.co|hf-mirror\.com|hf\.co)/")
}

; HF resolve 链接补 download=true，减少拿到 HTML 中间页
DlNormalizeHfUrl(url) {
    u := Trim(String(url))
    if !DlIsHuggingFaceUrl(u)
        return u
    if RegExMatch(u, "i)/(resolve|blob)/") && !InStr(u, "download=true") {
        if InStr(u, "?")
            u .= "&download=true"
        else
            u .= "?download=true"
    }
    return u
}

; 解析 HF/镜像 302 后的 CDN 直链（如 cas-bridge.xethub.hf.co）
; 禁止 RunWait curl：会卡主线程导致鼠标一直转圈
DlResolveFinalDownloadUrl(url) {
    u := Trim(String(url))
    if u = "" || !RegExMatch(u, "i)^https?://")
        return u
    ; 已是 CDN/签名直链则不必再解
    if RegExMatch(u, "i)(xethub\.hf\.co|cas-bridge\.|cloudfront\.net|fastly\.net|\.r2\.cloudflarestorage\.|amazonaws\.com/)")
        return u
    cur := u
    loop 6 {
        loc := ""
        try {
            whr := ComObject("WinHttp.WinHttpRequest.5.1")
            whr.Open("HEAD", cur, false)
            ; 短超时，避免解链卡住界面
            whr.SetTimeouts(2000, 2000, 4000, 4000)
            try whr.Option[6] := false ; 不自动跟随，手动读 Location
            whr.SetRequestHeader("User-Agent", Aria2BrowserUa())
            whr.SetRequestHeader("Accept", "*/*")
            if DlIsHuggingFaceUrl(cur) || InStr(StrLower(cur), "hf-mirror")
                whr.SetRequestHeader("Referer", "https://hf-mirror.com/")
            whr.Send()
            st := 0
            try st := Integer(whr.Status)
            if st = 405 || st = 501 {
                ; 部分 CDN 拒 HEAD，改短 GET
                whr2 := ComObject("WinHttp.WinHttpRequest.5.1")
                whr2.Open("GET", cur, false)
                whr2.SetTimeouts(2000, 2000, 4000, 4000)
                try whr2.Option[6] := false
                whr2.SetRequestHeader("User-Agent", Aria2BrowserUa())
                whr2.SetRequestHeader("Accept", "*/*")
                whr2.SetRequestHeader("Range", "bytes=0-0")
                if DlIsHuggingFaceUrl(cur) || InStr(StrLower(cur), "hf-mirror")
                    whr2.SetRequestHeader("Referer", "https://hf-mirror.com/")
                whr2.Send()
                st := 0
                try st := Integer(whr2.Status)
                try loc := Trim(String(whr2.GetResponseHeader("Location")))
            } else {
                try loc := Trim(String(whr.GetResponseHeader("Location")))
            }
            if !(st = 301 || st = 302 || st = 303 || st = 307 || st = 308) || loc = ""
                break
            if RegExMatch(loc, "i)^https?://")
                cur := loc
            else if RegExMatch(cur, "i)^(https?://[^/]+)", &hm)
                cur := hm[1] (SubStr(loc, 1, 1) = "/" ? loc : "/" loc)
            else
                break
        } catch {
            break
        }
    }
    if RegExMatch(cur, "i)^https?://\S+$")
        return cur
    return u
}

DlExpandHfUrls(url) {
    out := [], seen := Map()
    u := DlNormalizeHfUrl(url)
    ; 国内直连 huggingface.co 常 TLS 被重置：优先 hf-mirror，再官方
    if InStr(StrLower(u), "huggingface.co") {
        alt := StrReplace(u, "huggingface.co", "hf-mirror.com")
        DlPushUrlUnique(out, seen, alt)
        DlPushUrlUnique(out, seen, u)
    } else if InStr(StrLower(u), "hf-mirror.com") {
        DlPushUrlUnique(out, seen, u)
        alt := StrReplace(u, "hf-mirror.com", "huggingface.co")
        DlPushUrlUnique(out, seen, alt)
    } else
        DlPushUrlUnique(out, seen, u)
    return out
}

; 解析 HF resolve/blob URL → {host, repoType, repo, rev, file, qs}
DlParseHfResolveUrl(url) {
    u := Trim(String(url))
    if !RegExMatch(u, "i)^https?://(huggingface\.co|hf-mirror\.com|hf\.co)/(models/|datasets/|spaces/)?([^/\s]+/[^/\s]+)/(resolve|blob)/([^/\s]+)/([^?\s]+)(\?.*)?$", &m)
        return false
    host := StrLower(m[1])
    if host = "hf.co"
        host := "huggingface.co"
    repoType := m[2] != "" ? m[2] : "models/"
    return {
        host: host, repoType: repoType, repo: m[3], kind: m[4],
        rev: m[5], file: m[6], qs: (m[7] != "" ? m[7] : "")
    }
}

; 单文件名已拆分为 xxx-00001-of-0000N.ext 时，通过 tree API 展开全部卷
DlResolveHfShardUrls(url) {
    out := []
    p := DlParseHfResolveUrl(url)
    if !IsObject(p)
        return out
    ; 已是分卷名则不必再查
    if RegExMatch(p.file, "i)-\d{5}-of-\d{5}\.")
        return out
    baseHost := "hf-mirror.com"
    api := "https://" baseHost "/api/" RegExReplace(p.repoType, "/$", "") "/" p.repo "/tree/" p.rev
    body := ""
    try {
        whr := ComObject("WinHttp.WinHttpRequest.5.1")
        whr.Open("GET", api, false)
        whr.SetTimeouts(3000, 3000, 8000, 15000)
        try whr.Option[6] := true
        whr.SetRequestHeader("User-Agent", Aria2BrowserUa())
        whr.SetRequestHeader("Accept", "application/json")
        whr.Send()
        if Integer(whr.Status) >= 200 && Integer(whr.Status) < 300
            body := String(whr.ResponseText)
    }
    if body = ""
        return out
    SplitPath p.file, , , &ext, &stem
    if stem = ""
        return out
    escStem := RegExReplace(stem, "([.\\+*?\[\](){}^$|])", "\$1")
    escExt := ext != "" ? RegExReplace(ext, "([.\\+*?\[\](){}^$|])", "\$1") : ""
    ; 匹配 "path":"stem-00001-of-00004.ext"
    pat := '"path"\s*:\s*"(' escStem '-\d{5}-of-\d{5}'
    if escExt != ""
        pat .= "\." escExt
    pat .= ')"'
    found := Map()
    pos := 1
    while RegExMatch(body, "i)" pat, &mm, pos) {
        found[StrLower(mm[1])] := mm[1]
        pos := mm.Pos + mm.Len
    }
    if found.Count < 1
        return out
    names := []
    for , nm in found
        names.Push(nm)
    ; 按分卷序号排序
    loop names.Length {
        i := A_Index
        loop names.Length - i {
            j := i + A_Index
            ai := 0, bi := 0
            if RegExMatch(names[i], "i)-(\d{5})-of-", &a)
                ai := Integer(a[1])
            if RegExMatch(names[j], "i)-(\d{5})-of-", &b)
                bi := Integer(b[1])
            if bi < ai {
                t := names[i], names[i] := names[j], names[j] := t
            }
        }
    }
    qs := p.qs
    if qs = ""
        qs := "?download=true"
    else if !InStr(qs, "download=true")
        qs .= "&download=true"
    for nm in names {
        u := "https://" baseHost "/" p.repo "/resolve/" p.rev "/" nm qs
        out.Push(u)
    }
    return out
}

; 规范化镜像前缀：https://gh.tszai.cn 或带尾斜杠
DlNormMirrorPrefix(m) {
    m := Trim(String(m))
    m := RegExReplace(m, "/+$", "")
    if m = ""
        return ""
    if !RegExMatch(m, "i)^https?://")
        m := "https://" m
    return m
}

; 从任意 URL 抽出 github.com 后的路径（owner/repo/...）
DlExtractGithubPath(url) {
    u := Trim(String(url))
    if RegExMatch(u, "i)(?:https?://(?:www\.)?github\.com/)(.+)$", &m)
        return m[1]
    if RegExMatch(u, "i)^https?://kkgithub\.com/(.+)$", &m)
        return m[1]
    return ""
}

; 是否已是「镜像包裹」的 GitHub 地址
DlUrlAlreadyMirrored(url) {
    u := Trim(String(url))
    ; https://mirror/.../https://github.com/...
    if RegExMatch(u, "i)^https?://[^/\s]+/https?://(?:www\.)?github\.com/")
        return true
    ; 常见镜像主机直转
    for tip in ["gh.tszai.cn", "ghproxy.", "gitmirror.com", "mirror.ghproxy", "ghfast.top"
        , "kkgithub.com", "gh-proxy.com", "gitdl.cn", "github.moeyy", "edgeone.gh-proxy"] {
        if InStr(StrLower(u), tip)
            return true
    }
    return false
}

DlJoinMirror(prefix, ghPath) {
    p := DlNormMirrorPrefix(prefix)
    if p = "" || ghPath = ""
        return ""
    ; 已是完整代理模板（极少）
    if InStr(p, "github.com/")
        return p
    return p "/https://github.com/" ghPath
}

DlPushUrlUnique(out, seen, u) {
    u := Trim(String(u))
    if u = ""
        return
    k := StrLower(u)
    if seen.Has(k)
        return
    seen[k] := true
    out.Push(u)
}

; 用户镜像规则：已有镜像→原样；裸 GitHub→套自己的镜像；失败可换下一个
DlPickUrls(url) {
    url := Trim(String(url))
    s := DlGetSettings()
    mirrors := []
    if IsObject(s) && s.HasProp("mirrors") {
        for m in s.mirrors {
            m := DlNormMirrorPrefix(m)
            if m != ""
                mirrors.Push(m)
        }
    }
    if mirrors.Length < 1
        mirrors := ["https://gh.tszai.cn"]
    failover := true
    if IsObject(s) && s.HasProp("failover")
        failover := !!s.failover

    out := [], seen := Map()
    gh := DlExtractGithubPath(url)
    if gh = "" {
        if DlIsHuggingFaceUrl(url) {
            for u in DlExpandHfUrls(url)
                DlPushUrlUnique(out, seen, u)
            return out
        }
        DlPushUrlUnique(out, seen, url)
        return out
    }

    if DlUrlAlreadyMirrored(url) {
        DlPushUrlUnique(out, seen, url)
        if failover {
            for m in mirrors
                DlPushUrlUnique(out, seen, DlJoinMirror(m, gh))
            DlPushUrlUnique(out, seen, "https://github.com/" gh)
        }
        return out
    }

    for m in mirrors
        DlPushUrlUnique(out, seen, DlJoinMirror(m, gh))
    if failover
        DlPushUrlUnique(out, seen, "https://github.com/" gh)
    if out.Length < 1
        DlPushUrlUnique(out, seen, url)
    return out
}

; 中科大等「Verifying your browser」页：JS 只是写入 Cookie addr=公网IP 后刷新；CLI 无 JS 故一直拿 877B/403
DlSolveMirrorVerifyCookie(url) {
    u := Trim(String(url))
    if u = "" || !RegExMatch(u, "i)^https?://")
        return ""
    try {
        whr := ComObject("WinHttp.WinHttpRequest.5.1")
        whr.Open("GET", u, false)
        whr.SetTimeouts(3000, 3000, 8000, 12000)
        try whr.Option[6] := true
        whr.SetRequestHeader("User-Agent", Aria2BrowserUa())
        whr.SetRequestHeader("Accept", "text/html,application/xhtml+xml,*/*;q=0.8")
        whr.SetRequestHeader("Accept-Language", "zh-CN,zh;q=0.9,en;q=0.8")
        if RegExMatch(u, "i)^(https?://.+/)[^/]+$", &rd)
            whr.SetRequestHeader("Referer", rd[1])
        whr.Send()
        body := ""
        try body := String(whr.ResponseText)
        if body = ""
            return ""
        if !InStr(body, "Verifying your browser") && !InStr(body, "Verifying - USTC") && !InStr(body, "Additional verification")
            return ""
        ; 避免引号嵌套触发 AHK 解析错误；页面里有 addr=x.x.x.x / Your IP address is ...
        if RegExMatch(body, "i)addr=([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)", &m)
            return "addr=" m[1]
        if RegExMatch(body, "i)Your IP address is\s+([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)", &m2)
            return "addr=" m2[1]
    }
    return ""
}

; mode: "file"=HF/模型等直链；"nav"=高校镜像过验证页（要像浏览器打开网页）
DlAriaBrowserHeaderArgs(ref := "", sameOrigin := false, cookie := "", mode := "file") {
    ua := Aria2BrowserUa()
    site := sameOrigin ? "same-origin" : "none"
    mode := StrLower(Trim(String(mode)))
    if mode = ""
        mode := "file"
    ; 注意：.cmd 里 header 值勿嵌套双引号，否则参数会被拆坏
    args := ' --user-agent="' ua '"'
        . ' --header="Accept-Language: zh-CN,zh;q=0.9,en;q=0.8"'
        . ' --header="Connection: keep-alive"'
    if mode = "nav" {
        ; 中科大 Verifying 页需要像浏览器导航
        args .= ' --header="Accept: text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8"'
            . ' --header="Cache-Control: no-cache"'
            . ' --header="Pragma: no-cache"'
            . ' --header="Upgrade-Insecure-Requests: 1"'
            . ' --header="Sec-Fetch-Dest: document"'
            . ' --header="Sec-Fetch-Mode: navigate"'
            . ' --header="Sec-Fetch-Site: ' site '"'
            . ' --header="Sec-Fetch-User: ?1"'
    } else {
        ; HF/CDN 文件直链：Accept 用 */*，勿伪装成打开 HTML（否则镜像易 404/HTML）
        args .= ' --header="Accept: */*"'
            . ' --header="Sec-Fetch-Dest: empty"'
            . ' --header="Sec-Fetch-Mode: cors"'
            . ' --header="Sec-Fetch-Site: ' site '"'
    }
    ref := Trim(String(ref))
    if ref != ""
        args .= ' --referer="' ref '"'
    cookie := Trim(String(cookie))
    if cookie != ""
        args .= ' --header="Cookie: ' cookie '"'
    return args
}

; noRef=true 时不带 Referer（部分镜像对 Referer 敏感，浏览器二次请求也可能不带）
DlSpawnAriaJob(aria, outDir, outName, useUrl, conn := 0, noRef := false) {
    s := DlGetSettings()
    ; 连接数只跟设置走，不做站点限流（下不动就失败，勿擅自砍线程）
    if conn < 1 {
        conn := 16
        try conn := Integer(s.conn)
    }
    conn := Max(1, Min(32, Integer(conn)))
    directGh := false
    try directGh := IsDirectGithubUrl(useUrl)
    isHf := DlIsHuggingFaceUrl(useUrl)
    if isHf
        useUrl := DlNormalizeHfUrl(useUrl)
    ; Referer：贴近浏览器从目录页点下载；勿乱带 github.com / 整段文件 URL
    ref := ""
    timeoutSec := 45
    host := ""
    if RegExMatch(useUrl, "i)^https?://([^/]+)", &hm)
        host := StrLower(hm[1])
    isEduMirror := !!RegExMatch(host, "i)(ustc\.edu|tuna\.tsinghua|aliyun|huaweicloud|njupt|bjtu|lzu|nju\.edu|sjtu\.edu|hit\.edu|cqu\.edu|bfsu\.edu)")
    sameOrigin := false
    piece := "1M"
    if isHf {
        ref := InStr(StrLower(useUrl), "hf-mirror") ? "https://hf-mirror.com/" : "https://huggingface.co/"
        timeoutSec := 180
        ; 勿预解析 CDN：WinHttp 会弄坏签名查询串
        piece := "4M"
        sameOrigin := true
    } else if directGh {
        ref := "https://github.com/"
        sameOrigin := true
    } else if RegExMatch(useUrl, "i)^(https?://.+/)[^/]+$", &rd) {
        ; 目录页作 Referer（如 .../22.04.5/），和浏览器点链接一致
        ref := rd[1]
        timeoutSec := 180
        sameOrigin := true
    }
    if noRef {
        ref := ""
        sameOrigin := false
    }
    ; 过中科大 JS 验证：预取页面解析 addr=IP，再带 Cookie 下载（与浏览器 reload 等价）
    verifyCookie := ""
    hdrMode := "file"
    if isEduMirror || RegExMatch(host, "i)mirrors\.(ustc|tuna|aliyun)") {
        hdrMode := "nav"
        verifyCookie := DlSolveMirrorVerifyCookie(useUrl)
        if verifyCookie != ""
            try AppLog("DlSolveMirrorVerifyCookie ok " verifyCookie " host=" host)
    }
    tick := A_TickCount
    cmdFile := outDir "\_aria_job_" tick ".cmd"
    logFile := outDir "\_aria_job_" tick ".log"
    cmdBody := "@echo off`r`n"
        . '"' aria '" -c -x ' conn " -s " conn " -k " piece " --min-split-size=" piece " --max-connection-per-server=" conn
        . " --connect-timeout=30 --timeout=" timeoutSec " --max-tries=5 --retry-wait=2"
        . " --max-file-not-found=3 --file-allocation=none --allow-overwrite=true --auto-file-renaming=false --check-certificate=false"
        . " --show-console-readout=false --summary-interval=1 --console-log-level=notice"
        . DlAriaBrowserHeaderArgs(ref, sameOrigin, verifyCookie, hdrMode)
        . ' -d "' outDir '" -o "' outName '" "' useUrl '"'
        . ' > "' logFile '" 2>&1`r`n'
        . "exit /b %ERRORLEVEL%`r`n"
    try FileDelete cmdFile
    try FileDelete logFile
    FileAppend cmdBody, cmdFile, "CP0"
    pid := 0
    Run(A_ComSpec ' /c ""' cmdFile '""', outDir, "Hide", &pid)
    return { pid: pid, cmd: cmdFile, log: logFile, url: useUrl, conn: conn }
}

; 高校镜像 / ISO：aria2、curl 常拿到几百字节拦截页；改用 Windows BITS（系统下载栈，接近浏览器）
DlPreferBitsDownload(url, name := "") {
    n := name != "" ? name : url
    if RegExMatch(n, "i)\.(iso|img|dmg)$")
        return true
    return !!RegExMatch(String(url), "i)(ustc\.edu\.cn|tuna\.tsinghua|aliyun\.com/.+ubuntu|releases\.ubuntu\.com|mirror\.ecs\.tn|mirrors\.(aliyun|tuna|ustc|huawei))")
}

DlSpawnBitsJob(outDir, outName, useUrl) {
    dest := outDir "\" outName
    tick := A_TickCount
    psFile := outDir "\_bits_job_" tick ".ps1"
    logFile := outDir "\_bits_job_" tick ".log"
    cmdFile := outDir "\_bits_job_" tick ".cmd"
    display := "ahk_dl_" tick
    srcPs := StrReplace(String(useUrl), "'", "''")
    dstPs := StrReplace(dest, "'", "''")
    ps := "$ErrorActionPreference = 'Stop'`r`n"
        . "Try { Get-BitsTransfer -Name '" display "' -ErrorAction SilentlyContinue | Remove-BitsTransfer -Confirm:$false } Catch {}`r`n"
        . "Start-BitsTransfer -Source '" srcPs "' -Destination '" dstPs "' -DisplayName '" display "' -Priority Foreground`r`n"
    try FileDelete psFile
    try FileDelete logFile
    try FileDelete cmdFile
    try FileDelete dest
    FileAppend ps, psFile, "UTF-8"
    cmdBody := "@echo off`r`n"
        . 'powershell -NoProfile -ExecutionPolicy Bypass -File "' psFile '" > "' logFile '" 2>&1`r`n'
        . "exit /b %ERRORLEVEL%`r`n"
    FileAppend cmdBody, cmdFile, "CP0"
    pid := 0
    Run(A_ComSpec ' /c ""' cmdFile '""', outDir, "Hide", &pid)
    return { pid: pid, cmd: cmdFile, log: logFile, url: useUrl, conn: 1, engine: "bits", ps: psFile, bitsName: display }
}

DlSpawnCurlJob(outDir, outName, useUrl, noRef := false) {
    curl := A_WinDir "\System32\curl.exe"
    if !FileExist(curl)
        return ""
    ua := Aria2BrowserUa()
    tick := A_TickCount
    cmdFile := outDir "\_curl_job_" tick ".cmd"
    logFile := outDir "\_curl_job_" tick ".log"
    dest := outDir "\" outName
    ; 绝不能写死 github.com Referer：高校镜像会直接回几百字节拦截页（看起来像「下完了」）
    ref := ""
    if !noRef {
        if RegExMatch(useUrl, "i)^(https?://.+/)[^/]+$", &rd)
            ref := rd[1]
        else if RegExMatch(useUrl, "i)^(https?://[^/]+/)", &rm)
            ref := rm[1]
    }
    big := !!RegExMatch(outName, "i)\.(iso|img|dmg|zip|7z|rar|exe|msi|gz|xz|safetensors|gguf)$")
    cmdBody := "@echo off`r`n"
        . '"' curl '" -L --retry 3 --connect-timeout 30 --retry-delay 2'
    ; ISO 等大文件勿加 --max-time，否则几分钟就被掐断
    if !big
        cmdBody .= " --max-time 180"
    cmdBody .= ' -A "' ua '"'
        . ' -H "Accept: text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8"'
        . ' -H "Accept-Language: zh-CN,zh;q=0.9,en;q=0.8"'
        . ' -H "Cache-Control: no-cache"'
        . ' -H "Upgrade-Insecure-Requests: 1"'
        . ' -H "Sec-Fetch-Dest: document"'
        . ' -H "Sec-Fetch-Mode: navigate"'
        . ' -H "Sec-Fetch-Site: ' (ref != "" ? "same-origin" : "none") '"'
        . ' -H "Sec-Fetch-User: ?1"'
        . ' --location-trusted'
        . ' --max-redirs 16'
    if ref != ""
        cmdBody .= ' -e "' ref '"'
    cmdBody .= ' -C - -o "' dest '" "' useUrl '"'
        . ' > "' logFile '" 2>&1`r`n'
        . "exit /b %ERRORLEVEL%`r`n"
    try FileDelete cmdFile
    try FileDelete logFile
    try FileDelete dest
    FileAppend cmdBody, cmdFile, "CP0"
    pid := 0
    Run(A_ComSpec ' /c ""' cmdFile '""', outDir, "Hide", &pid)
    return { pid: pid, cmd: cmdFile, log: logFile, url: useUrl, conn: 1, engine: "curl" }
}

; 迅雷链 thunder://Base64(AA+真实URL+ZZ)
DlDecodeThunder(url) {
    u := Trim(String(url))
    if !RegExMatch(u, "i)^thunder://(.+)$", &m)
        return ""
    b64 := RegExReplace(m[1], "\s+")
    size := 0
    if !DllCall("crypt32\CryptStringToBinaryW", "WStr", b64, "UInt", 0, "UInt", 1
        , "Ptr", 0, "UInt*", &size, "Ptr", 0, "Ptr", 0) || size < 1
        return ""
    buf := Buffer(size)
    if !DllCall("crypt32\CryptStringToBinaryW", "WStr", b64, "UInt", 0, "UInt", 1
        , "Ptr", buf, "UInt*", &size, "Ptr", 0, "Ptr", 0)
        return ""
    raw := StrGet(buf, size, "UTF-8")
    raw := Trim(raw)
    if RegExMatch(raw, "i)^AA(.+)ZZ$", &mm)
        return Trim(mm[1])
    return raw
}

; flashget:// / qqdl:// 类似包裹，尽量抽出 http(s)
DlDecodeWrapped(url) {
    u := Trim(String(url))
    if RegExMatch(u, "i)^(?:flashget|qqdl|fs2you)://(.+)$", &m) {
        b64 := RegExReplace(m[1], "\s+")
        size := 0
        if DllCall("crypt32\CryptStringToBinaryW", "WStr", b64, "UInt", 0, "UInt", 1
            , "Ptr", 0, "UInt*", &size, "Ptr", 0, "Ptr", 0) && size > 0 {
            buf := Buffer(size)
            if DllCall("crypt32\CryptStringToBinaryW", "WStr", b64, "UInt", 0, "UInt", 1
                , "Ptr", buf, "UInt*", &size, "Ptr", 0, "Ptr", 0) {
                raw := StrGet(buf, size, "UTF-8")
                if RegExMatch(raw, "i)(https?://\S+)", &mm)
                    return Trim(mm[1])
            }
        }
    }
    return ""
}

DlNormalizeInputUrl(url) {
    u := Trim(String(url))
    u := RegExReplace(u, "^[\s`"']+|[\s`"']+$", "")
    if u = ""
        return { ok: false, err: "链接为空" }
    ; 粘贴 Markdown 链接污染：https://a.iso](https://a.iso 或 [名](https://...)
    if RegExMatch(u, "i)\]\((https?://[^)\s]+)\)\s*$", &md)
        u := Trim(md[1])
    else if RegExMatch(u, "i)^(https?://\S+?)\]\(https?://", &md2)
        u := Trim(md2[1])
    else if RegExMatch(u, "i)^\[([^\]]*)\]\((https?://[^)\s]+)\)", &md3)
        u := Trim(md3[2])
    u := RegExReplace(u, "[\]\)\s]+$", "")
    ; 迅雷 / FlashGet 等先解码成真实地址
    if RegExMatch(u, "i)^thunder://") {
        d := DlDecodeThunder(u)
        if d != ""
            u := d
    } else if RegExMatch(u, "i)^(?:flashget|qqdl|fs2you)://") {
        d := DlDecodeWrapped(u)
        if d != ""
            u := d
    }
    ; aria2 可直接拉：http(s)/ftp(s)/magnet
    if RegExMatch(u, "i)^(https?|ftp|ftps|sftp)://")
        return { ok: true, kind: "aria2", url: u }
    if RegExMatch(u, "i)^magnet:\?")
        return { ok: true, kind: "aria2", url: u }
    ; ed2k：交给系统已注册客户端（电驴等）；aria2 通常不带 eDonkey
    if RegExMatch(u, "i)^ed2k://")
        return { ok: true, kind: "external", url: u, name: DlGuessEd2kName(u) }
    ; 其它私有协议：尝试系统打开
    if RegExMatch(u, "i)^[a-z][a-z0-9+.-]*:")
        return { ok: true, kind: "external", url: u }
    return { ok: false, err: "不支持的链接，请使用 http/https/ftp/磁力/ed2k 等" }
}

DlGuessEd2kName(url) {
    ; ed2k://|file|name|size|hash|/
    if RegExMatch(url, "i)^ed2k://\|file\|([^|]+)\|", &m) {
        n := RegExReplace(m[1], '[<>:"/\\|?*]', "_")
        if n != ""
            return n
    }
    return "ed2k_" FormatTime(, "yyyyMMdd_HHmmss")
}

DlAddExternalJob(url, name := "") {
    global DL_JOBS, wvCore
    dir := DlDataDir()
    if name = ""
        name := DlGuessName(url)
    id := "dl" A_TickCount
    ; 唤起系统关联程序
    opened := false
    try {
        Run(url)
        opened := true
    } catch {
        opened := false
    }
    DL_JOBS[id] := {
        id: id, url: url, name: name, path: "", dir: dir,
        status: opened ? "done" : "error",
        got: 0, total: 0, speed: 0, maxSpeed: 0, minSpeed: 0, avgSpeed: 0, spdSum: 0, spdN: 0,
        spdHist: [],
        err: opened ? "" : "无法唤起本机程序（请安装电驴/迅雷等）",
        pid: 0, cmd: "", log: "", t0: A_TickCount, lastGot: 0, lastAt: A_TickCount,
        createdAt: FormatTime(, "yyyy-MM-dd HH:mm:ss"), createdTick: A_TickCount,
        finishedAt: opened ? FormatTime(, "yyyy-MM-dd HH:mm:ss") : "",
        urls: [url], urlIdx: 1, engine: "external", failover: false
    }
    if IsObject(wvCore) {
        tip := opened ? ("已用本机程序打开：" name) : "打开失败，请检查是否安装 ed2k/迅雷客户端"
        try wvCore.ExecuteScriptAsync("try{window.__dlToast&&window.__dlToast(" JStr(tip) "," (opened ? "false" : "true") ")}catch(e){}")
    }
    DlStartPoll()
    DlEmitState()
}

; 同名可复用任务：未完成，或「已完成」其实是假文件（错误页）
DlFindUnfinishedByName(name) {
    global DL_JOBS
    name := StrLower(Trim(String(name)))
    if name = "" || !IsObject(DL_JOBS)
        return ""
    for id, j in DL_JOBS {
        n := StrLower(Trim(j.HasProp("name") ? String(j.name) : ""))
        ; 也匹配 model_2.safetensors → 以基础名查找时由调用方传入精确名
        if n != name
            continue
        st := j.HasProp("status") ? j.status : ""
        if st = "active" || st = "paused" || st = "error"
            return id
        if st = "done" {
            p := j.HasProp("path") ? String(j.path) : ""
            if DlIsBogusDownload(p, j.HasProp("name") ? j.name : "")
                return id
        }
    }
    return ""
}

DlRetargetJobUrl(id, url) {
    global DL_JOBS, wvCore
    id := String(id)
    if !DL_JOBS.Has(id)
        return false
    j := DL_JOBS[id]
    DlKillJobProc(j)
    p := j.HasProp("path") ? String(j.path) : ""
    if p != "" {
        try FileDelete p ".aria2"
        ; 假文件（错误页）清掉再下；真半成品保留给 -c
        if DlIsBogusDownload(p, j.HasProp("name") ? j.name : "") {
            try FileDelete p
            try FileDelete p ".part"
            j.got := 0
            j.total := 0
        }
    }
    urls := DlPickUrls(url)
    useUrl := urls[1]
    aria := j.HasProp("aria") && j.aria != "" ? j.aria : FindLocalAria2c()
    if aria = "" || !FileExist(aria) {
        if IsObject(wvCore)
            try wvCore.ExecuteScriptAsync("try{window.__dlToast&&window.__dlToast(" JStr("未找到 aria2c") ",true)}catch(e){}")
        return false
    }
    s := DlGetSettings()
    conn := j.HasProp("conn") ? j.conn : Integer(s.conn)
    spawned := DlSpawnAriaJob(aria, j.dir, j.name, useUrl, conn)
    j.pid := spawned.pid
    j.cmd := spawned.cmd
    j.log := spawned.log
    j.conn := spawned.conn
    j.aria := aria
    j.engine := "aria2"
    j.url := url
    j.urls := urls
    j.urlIdx := 1
    j.status := "active"
    j.err := ""
    j.speed := 0
    j.lastAt := A_TickCount
    j.stallAt := A_TickCount
    j.failover := !!(s.HasProp("failover") ? s.failover : true)
    DL_JOBS[id] := j
    DlStartPoll()
    DlEmitState()
    if IsObject(wvCore)
        try wvCore.ExecuteScriptAsync("try{window.__dlToast&&window.__dlToast(" JStr("已换源继续下载：" j.name) ")}catch(e){}")
    return true
}

DlAddUrl(url) {
    url := Trim(String(url))
    norm := DlNormalizeInputUrl(url)
    if !norm.ok {
        global wvCore
        if IsObject(wvCore)
            try wvCore.ExecuteScriptAsync("try{window.__dlToast&&window.__dlToast(" JStr(norm.err) ",true)}catch(e){}")
        return
    }
    if norm.kind = "external" {
        n := norm.HasProp("name") ? norm.name : ""
        DlAddExternalJob(norm.url, n)
        return
    }
    url := norm.url
    ; HF 旧单文件链常已拆卷（如 q6_k.gguf → q6_k-0000N-of-00004.gguf）
    if DlIsHuggingFaceUrl(url) && !RegExMatch(url, "i)-\d{5}-of-\d{5}\.") {
        shards := DlResolveHfShardUrls(url)
        if shards.Length > 1 {
            global wvCore
            if IsObject(wvCore)
                try wvCore.ExecuteScriptAsync("try{window.__dlToast&&window.__dlToast(" JStr("该模型已拆成 " shards.Length " 个分卷，已全部加入下载") ")}catch(e){}")
            for su in shards
                DlAddUrl(su)
            return
        }
    }
    dir := DlDataDir()
    name := DlGuessName(url)
    aria := FindLocalAria2c()
    if aria = "" || !FileExist(aria) {
        global wvCore
        if IsObject(wvCore)
            try wvCore.ExecuteScriptAsync("try{window.__dlToast&&window.__dlToast(" JStr("未找到 aria2c，请先到主页安装") ",true)}catch(e){}")
        return
    }
    if RegExMatch(url, "i)^magnet:")
        name := "magnet_" FormatTime(, "yyyyMMdd_HHmmss")

    ; 同名未完成：换链=换源；同链=不重复开任务
    existId := DlFindUnfinishedByName(name)
    if existId != "" {
        global DL_JOBS, wvCore
        ej := DL_JOBS[existId]
        oldUrl := StrLower(Trim(ej.HasProp("url") ? String(ej.url) : ""))
        newUrl := StrLower(Trim(url))
        if oldUrl = newUrl {
            if ej.status = "paused" || ej.status = "error"
                DlResumeJob(existId)
            else
                DlEmitState()
            if IsObject(wvCore)
                try wvCore.ExecuteScriptAsync("try{window.__dlToast&&window.__dlToast(" JStr("该文件已在下载列表中") ")}catch(e){}")
            return
        }
        DlRetargetJobUrl(existId, url)
        return
    }

    dest := dir "\" name
    ; 未完成残留 .aria2/.part 也算占用，避免新任务抢同一路径
    if FileExist(dest) || FileExist(dest ".aria2") || FileExist(dest ".part") {
        SplitPath dest, , , &ext, &noext
        n := 2
        loop {
            cand := dir "\" noext "_" n (ext != "" ? "." ext : "")
            if !FileExist(cand) && !FileExist(cand ".aria2") && !FileExist(cand ".part") {
                dest := cand
                name := noext "_" n (ext != "" ? "." ext : "")
                break
            }
            n += 1
            if n > 99
                break
        }
    }
    SplitPath dest, &outName, &outDir
    urls := DlPickUrls(url)
    useUrl := urls[1]
    s := DlGetSettings()
    conn := Integer(s.conn)
    ; 先 aria2（含自动过 USTC Verifying Cookie）；失败/拦截页再 BITS
    spawned := DlSpawnAriaJob(aria, outDir, outName, useUrl, conn)
    eng := "aria2"
    id := "dl" A_TickCount
    global DL_JOBS
    DL_JOBS[id] := {
        id: id, url: url, name: outName, path: dest, dir: outDir,
        status: "active", got: 0, total: 0, speed: 0, err: "",
        maxSpeed: 0, minSpeed: 0, avgSpeed: 0, spdSum: 0, spdN: 0, spdHist: [],
        pid: spawned.pid, cmd: spawned.cmd, log: spawned.log,
        t0: A_TickCount, lastGot: 0, lastAt: A_TickCount, stallAt: A_TickCount,
        createdAt: FormatTime(, "yyyy-MM-dd HH:mm:ss"), createdTick: A_TickCount, finishedAt: "",
        urls: urls, urlIdx: 1, aria: aria, conn: spawned.conn, engine: eng,
        failover: !!(s.HasProp("failover") ? s.failover : true),
        bitsTried: (eng = "bits")
    }
    if eng = "bits" && spawned.HasProp("bitsName")
        DL_JOBS[id].bitsName := spawned.bitsName
    if eng = "bits" && spawned.HasProp("ps")
        DL_JOBS[id].ps := spawned.ps
    DlStartPoll()
    DlEmitState()
}

DlKillPidTree(pid) {
    pid := Integer(pid)
    if pid <= 0
        return
    ; cmd 包一层启动 aria2 时，必须杀进程树，否则子进程 aria2c 会继续下
    try RunWait(A_ComSpec " /c taskkill /F /T /PID " pid " >nul 2>&1", , "Hide")
    try ProcessClose(pid)
    try ProcessWaitClose(pid, 2000)
}

DlKillJobProc(j) {
    if !IsObject(j)
        return
    if j.HasProp("bitsName") && j.bitsName != "" {
        bn := StrReplace(String(j.bitsName), "'", "''")
        try RunWait(A_ComSpec " /c powershell -NoProfile -Command `"Try{Get-BitsTransfer|?{$_.DisplayName -eq '" bn "'}|Remove-BitsTransfer -Confirm:$false}Catch{}`"", , "Hide")
    }
    pid := Integer(j.HasProp("pid") ? j.pid : 0)
    DlKillPidTree(pid)
    j.pid := 0
    j.speed := 0
    try {
        if j.HasProp("cmd") && j.cmd != ""
            FileDelete j.cmd
    }
}

DlPauseJob(id) {
    global DL_JOBS
    id := String(id)
    if !DL_JOBS.Has(id)
        return
    j := DL_JOBS[id]
    if j.status != "active"
        return
    DlKillJobProc(j)
    j.status := "paused"
    j.speed := 0
    DL_JOBS[id] := j
    DlEmitState()
}

DlResumeJob(id) {
    global DL_JOBS
    id := String(id)
    if !DL_JOBS.Has(id)
        return
    j := DL_JOBS[id]
    if j.status != "paused" && j.status != "error"
        return
    if j.HasProp("engine") && j.engine = "external" {
        try Run(j.url)
        j.status := "done"
        j.finishedAt := FormatTime(, "yyyy-MM-dd HH:mm:ss")
        DL_JOBS[id] := j
        DlEmitState()
        return
    }
    useUrl := j.url
    if j.HasProp("urls") && IsObject(j.urls) && j.urls.Length {
        idx := Integer(j.HasProp("urlIdx") ? j.urlIdx : 1)
        if idx >= 1 && idx <= j.urls.Length
            useUrl := j.urls[idx]
    }
    eng := j.HasProp("engine") ? j.engine : "aria2"
    if eng = "bits" {
        spawned := DlSpawnBitsJob(j.dir, j.name, useUrl)
        j.engine := "bits"
        j.bitsTried := true
        if spawned.HasProp("bitsName")
            j.bitsName := spawned.bitsName
        if spawned.HasProp("ps")
            j.ps := spawned.ps
    } else {
        aria := j.HasProp("aria") ? j.aria : FindLocalAria2c()
        if aria = "" || !FileExist(aria) {
            global wvCore
            if IsObject(wvCore)
                try wvCore.ExecuteScriptAsync("try{window.__dlToast&&window.__dlToast(" JStr("未找到 aria2c") ",true)}catch(e){}")
            return
        }
        conn := 0
        try conn := Integer(DlGetSettings().conn)
        try j.DeleteProp("singleConnTried")
        spawned := DlSpawnAriaJob(aria, j.dir, j.name, useUrl, conn)
        j.engine := "aria2"
    }
    j.pid := spawned.pid
    j.cmd := spawned.cmd
    j.log := spawned.log
    j.conn := spawned.conn
    j.status := "active"
    j.err := ""
    j.speed := 0
    j.lastAt := A_TickCount
    j.stallAt := A_TickCount
    DL_JOBS[id] := j
    DlStartPoll()
    DlEmitState()
}

DlPauseAll(*) {
    global DL_JOBS
    for id, j in DL_JOBS {
        if j.status = "active"
            DlPauseJob(id)
    }
}

DlResumeAll(*) {
    global DL_JOBS
    for id, j in DL_JOBS {
        if j.status = "paused" || j.status = "error"
            DlResumeJob(id)
    }
}

DlRemoveJob(id, purgeFile := false) {
    DlRemoveJobs(String(id), purgeFile)
}

; ids：单个 id，或逗号分隔的多个 id
DlRemoveJobs(idsRaw, purgeFile := false) {
    global DL_JOBS
    raw := Trim(String(idsRaw))
    if raw = ""
        return
    any := false
    for part in StrSplit(raw, ",") {
        id := Trim(String(part))
        if id = "" || !DL_JOBS.Has(id)
            continue
        j := DL_JOBS[id]
        DlKillJobProc(j)
        if purgeFile {
            p := j.HasProp("path") ? String(j.path) : ""
            if p != "" {
                try FileDelete p
                try FileDelete p ".aria2"
                try FileDelete p ".part"
            }
        }
        try {
            if j.HasProp("log") && j.log != ""
                FileDelete j.log
        }
        DL_JOBS.Delete(id)
        any := true
    }
    if !any
        return
    DlSaveJobs(true)
    DlEmitState()
}

DlToast(msg, isErr := false) {
    global wvCore
    if !IsObject(wvCore)
        return
    try wvCore.ExecuteScriptAsync("try{window.__dlToast&&window.__dlToast(" JStr(msg) "," (isErr ? "true" : "false") ")}catch(e){}")
}

; 打开文件/文件夹：必须在主线程 SetTimer 里跑；WebMessage/队列回调里 Run 常无窗口
DlShellOpen(path) {
    p := Trim(String(path))
    p := StrReplace(p, "/", "\")
    if p = "" || !FileExist(p)
        return false
    try {
        Run('"' p '"')
        return true
    }
    try {
        r := DllCall("shell32\ShellExecuteW", "Ptr", 0, "Str", "open", "Str", p
            , "Ptr", 0, "Ptr", 0, "Int", 1, "Ptr")
        if r > 32
            return true
    }
    return false
}

DlShellReveal(path) {
    p := Trim(String(path))
    p := StrReplace(p, "/", "\")
    if p = ""
        return false
    sel := ""
    d := ""
    if FileExist(p) && !DirExist(p) {
        sel := p
        SplitPath p, , &d
    } else if DirExist(p) {
        d := p
    } else {
        SplitPath p, , &d
    }
    if d = "" || !DirExist(d)
        try d := DlDataDir()
    if d = "" || !DirExist(d)
        return false
    ok := false
    ; 1) 与 dashboard openLocalPath / reveal| 完全同写法
    if sel != "" {
        try {
            Run('explorer.exe /select,"' sel '"')
            ok := true
        }
    }
    if !ok {
        try {
            Run('explorer.exe "' d '"')
            ok := true
        }
    }
    ; 2) Shell.Application（不依赖 explorer 命令行）
    if !ok {
        try {
            ComObject("Shell.Application").Explore(d)
            ok := true
        }
    }
    ; 3) ShellExecuteW
    if !ok {
        try {
            target := sel != "" ? sel : d
            verb := sel != "" ? "open" : "explore"
            if sel != "" {
                r := DllCall("shell32\ShellExecuteW", "Ptr", 0, "Str", "open", "Str", "explorer.exe"
                    , "Str", '/select,"' sel '"', "Ptr", 0, "Int", 1, "Ptr")
            } else {
                r := DllCall("shell32\ShellExecuteW", "Ptr", 0, "Str", "explore", "Str", d
                    , "Ptr", 0, "Ptr", 0, "Int", 1, "Ptr")
            }
            if r > 32
                ok := true
        }
    }
    try {
        if IsSet(AppLog)
            AppLog("DlShellReveal ok=" ok " sel=" sel " d=" d)
    }
    return ok
}

global DL_OPEN_FILE_ID := ""
global DL_OPEN_FOLDER_ID := ""
global DL_OPEN_DIR_FLAG := false

DlOpenJobFileTick(*) {
    global DL_OPEN_FILE_ID, DL_JOBS
    id := String(DL_OPEN_FILE_ID)
    DL_OPEN_FILE_ID := ""
    if id = "" || !DL_JOBS.Has(id)
        return
    j := DL_JOBS[id]
    p := j.HasProp("path") ? String(j.path) : ""
    if p = "" || !FileExist(p) {
        DlToast("文件不存在或已删除", true)
        DlEmitState()
        return
    }
    if !DlShellOpen(p)
        DlToast("无法打开文件", true)
}

DlQueueReveal(path) {
    ; 优先走 dashboard 的 open_path.request（主线程轮询），避免队列回调里 Run 无窗
    p := Trim(String(path))
    if p = ""
        p := DlDataDir()
    if IsSet(RequestOpenLocalPath) {
        try {
            RequestOpenLocalPath(p)
            return true
        }
    }
    return DlShellReveal(p)
}

DlOpenJobFolderTick(*) {
    global DL_OPEN_FOLDER_ID, DL_JOBS
    id := String(DL_OPEN_FOLDER_ID)
    DL_OPEN_FOLDER_ID := ""
    if id = "" {
        if !DlQueueReveal(DlDataDir())
            DlToast("无法打开下载目录", true)
        return
    }
    if !DL_JOBS.Has(id) {
        if !DlQueueReveal(DlDataDir())
            DlToast("无法打开下载目录", true)
        return
    }
    j := DL_JOBS[id]
    p := j.HasProp("path") ? String(j.path) : ""
    d := j.HasProp("dir") ? String(j.dir) : ""
    ok := false
    if p != "" && FileExist(p)
        ok := DlQueueReveal(p)
    else if p != "" && FileExist(p ".part")
        ok := DlQueueReveal(p ".part")
    else if d != "" && DirExist(d)
        ok := DlQueueReveal(d)
    else
        ok := DlQueueReveal(DlDataDir())
    if !ok
        DlToast("无法打开文件夹：请检查下载目录是否存在", true)
}

DlOpenDirTick(*) {
    global DL_OPEN_DIR_FLAG
    DL_OPEN_DIR_FLAG := false
    if !DlQueueReveal(DlDataDir())
        DlToast("无法打开下载目录", true)
}

DlOpenJobFile(id) {
    global DL_OPEN_FILE_ID
    DL_OPEN_FILE_ID := String(id)
    SetTimer(DlOpenJobFileTick, -30)
}

DlOpenJobFolder(id) {
    ; 立刻写请求文件，不再依赖可能不触发的 SetTimer
    global DL_JOBS
    id := String(id)
    p := ""
    d := ""
    if id != "" && DL_JOBS.Has(id) {
        j := DL_JOBS[id]
        p := j.HasProp("path") ? String(j.path) : ""
        d := j.HasProp("dir") ? String(j.dir) : ""
    }
    target := ""
    if p != "" && FileExist(p)
        target := p
    else if p != "" && FileExist(p ".part")
        target := p ".part"
    else if d != "" && DirExist(d)
        target := d
    else
        target := DlDataDir()
    if !DlQueueReveal(target)
        DlToast("无法打开文件夹：请检查下载目录是否存在", true)
}

DlApplyRename(id, newName) {
    global DL_JOBS, wvCore
    id := String(id)
    if !DL_JOBS.Has(id)
        return
    j := DL_JOBS[id]
    oldName := j.HasProp("name") ? String(j.name) : ""
    nn := Trim(String(newName))
    nn := RegExReplace(nn, '[<>:"/\\|?*]', "_")
    if nn = "" || nn = oldName
        return
    oldPath := j.HasProp("path") ? String(j.path) : ""
    dir := j.HasProp("dir") ? String(j.dir) : DlDataDir()
    newPath := dir "\" nn
    if oldPath != "" && FileExist(oldPath) {
        try FileMove oldPath, newPath, 0
        catch {
            if IsObject(wvCore)
                try wvCore.ExecuteScriptAsync("try{window.__dlToast&&window.__dlToast(" JStr("重命名失败") ",true)}catch(e){}")
            return
        }
    }
    j.name := nn
    j.path := newPath
    j.iconCache := ""
    DL_JOBS[id] := j
    DlSaveJobs(true)
    DlEmitState()
    if IsObject(wvCore)
        try wvCore.ExecuteScriptAsync("try{window.__dlToast&&window.__dlToast(" JStr("已重命名") ")}catch(e){}")
}

DlRedownloadJob(id) {
    global DL_JOBS
    id := String(id)
    if !DL_JOBS.Has(id)
        return
    j := DL_JOBS[id]
    url := j.HasProp("url") ? String(j.url) : ""
    if url = ""
        return
    DlKillJobProc(j)
    p := j.HasProp("path") ? String(j.path) : ""
    if p != "" {
        try FileDelete p
        try FileDelete p ".aria2"
        try FileDelete p ".part"
    }
    DL_JOBS.Delete(id)
    DlAddUrl(url)
}

DlRetryNextMirror(j) {
    ; 设置关闭「失败换源」则不再切换
    if j.HasProp("failover") && !j.failover
        return false
    if !j.HasProp("urls") || !IsObject(j.urls)
        return false
    next := Integer(j.HasProp("urlIdx") ? j.urlIdx : 1) + 1
    outDir := j.dir
    outName := j.name
    dest := j.path
    try FileDelete dest
    try FileDelete dest ".aria2"
    try FileDelete dest ".part"
    if next <= j.urls.Length {
        useUrl := j.urls[next]
        aria := j.HasProp("aria") ? j.aria : FindLocalAria2c()
        if aria = "" || !FileExist(aria)
            return false
        conn := j.HasProp("conn") ? j.conn : 0
        spawned := DlSpawnAriaJob(aria, outDir, outName, useUrl, conn)
        j.pid := spawned.pid
        j.cmd := spawned.cmd
        j.log := spawned.log
        j.urlIdx := next
        j.conn := spawned.conn
        j.engine := "aria2"
        j.status := "active"
        j.err := ""
        j.lastGot := 0
        j.lastAt := A_TickCount
        j.stallAt := A_TickCount
        j.got := 0
        j.speed := 0
        return true
    }
    if !(j.HasProp("curlTried") && j.curlTried) {
        j.curlTried := true
        useUrl := j.urls[1]
        ; 高校镜像：curl 默认不带 Referer（aria2 已带过）；其它站用目录页 Referer
        noRef := !!RegExMatch(useUrl, "i)(ustc\.edu|tuna\.tsinghua|aliyun|huaweicloud|njupt|bjtu|lzu|nju\.edu|sjtu\.edu)")
        spawned := DlSpawnCurlJob(outDir, outName, useUrl, noRef)
        if !IsObject(spawned)
            return false
        j.pid := spawned.pid
        j.cmd := spawned.cmd
        j.log := spawned.log
        j.urlIdx := 1
        j.engine := "curl"
        j.status := "active"
        j.err := ""
        j.lastGot := 0
        j.lastAt := A_TickCount
        j.stallAt := A_TickCount
        j.got := 0
        j.speed := 0
        return true
    }
    if (j.HasProp("engine") && j.engine = "curl") {
        ; curl 带 Referer 仍拿到错误页时，再无 Referer 试一次
        if !(j.HasProp("curlNoRefTried") && j.curlNoRefTried) {
            j.curlNoRefTried := true
            useUrl := j.urls[Integer(j.HasProp("urlIdx") ? j.urlIdx : 1)]
            spawned := DlSpawnCurlJob(outDir, outName, useUrl, true)
            if IsObject(spawned) {
                j.pid := spawned.pid
                j.cmd := spawned.cmd
                j.log := spawned.log
                j.status := "active"
                j.err := ""
                j.lastGot := 0
                j.lastAt := A_TickCount
                j.stallAt := A_TickCount
                j.got := 0
                j.speed := 0
                return true
            }
        }
        cnext := Integer(j.HasProp("urlIdx") ? j.urlIdx : 1) + 1
        if cnext <= j.urls.Length {
            useUrl := j.urls[cnext]
            spawned := DlSpawnCurlJob(outDir, outName, useUrl, true)
            if !IsObject(spawned)
                return false
            j.pid := spawned.pid
            j.cmd := spawned.cmd
            j.log := spawned.log
            j.urlIdx := cnext
            j.status := "active"
            j.err := ""
            j.lastGot := 0
            j.lastAt := A_TickCount
            j.stallAt := A_TickCount
            j.got := 0
            j.speed := 0
            return true
        }
    }
    return false
}

DlPollJobs(*) {
    global DL_JOBS
    changed := false
    if DlPollFileHashes()
        changed := true
    for id, j in DL_JOBS {
        if j.status = "done" {
            ; 误标完成但控制文件还在：收回下载中/暂停，禁止此时校验（否则 OpenRead 必撞锁）
            pDone := j.HasProp("path") ? String(j.path) : ""
            if pDone != "" && (FileExist(pDone ".aria2") || FileExist(pDone ".part")) {
                j.status := (j.HasProp("pid") && Integer(j.pid) > 0 && ProcessExist(j.pid)) ? "active" : "paused"
                j.hashStatus := ""
                j.hashErr := ""
                j.finishedAt := ""
                DL_JOBS[id] := j
                changed := true
                continue
            }
            miss := DlJobMissing(j)
            prev := j.HasProp("missingFlag") ? !!j.missingFlag : false
            if miss != prev {
                j.missingFlag := miss
                DL_JOBS[id] := j
                changed := true
            }
            ; 缺哈希则排队
            if DlHashNeed(j) {
                hs := j.HasProp("hashStatus") ? String(j.hashStatus) : ""
                if hs = "" {
                    j.hashStatus := "queued"
                    DL_JOBS[id] := j
                    changed := true
                }
            }
            continue
        }
        if j.status = "paused" {
            path := j.HasProp("path") ? j.path : ""
            got := Integer(j.HasProp("got") ? j.got : 0)
            ; 暂停时仍优先 aria2 日志；有 .aria2 时勿用 FileGetSize 抬高
            if path != "" {
                try {
                    if j.HasProp("log") && j.log != "" {
                        pprog := DlParseAriaLogProgress(j.log)
                        if Integer(pprog.got) >= 0
                            got := Integer(pprog.got)
                        if Integer(pprog.total) > 0
                            j.total := Integer(pprog.total)
                    }
                    if !FileExist(path ".aria2") && !FileExist(path ".part") {
                        if FileExist(path)
                            got := Max(got, FileGetSize(path))
                        else if FileExist(path ".part")
                            got := Max(got, FileGetSize(path ".part"))
                    }
                }
            }
            if got != Integer(j.HasProp("got") ? j.got : 0) {
                j.got := got
                changed := true
            }
            ; 暂停态 got>total：收口为实际大小（不再抬高）
            if Integer(j.HasProp("total") ? j.total : 0) > 0 && got > Integer(j.total) {
                j.total := got
                changed := true
            }
            ; 已落盘且无 .aria2/.part → 完成（aria2 成功后会删控制文件）
            if DlJobLooksComplete(j) {
                j := DlMarkJobDone(j)
                changed := true
            }
            DL_JOBS[id] := j
            continue
        }
        if j.status = "error"
            continue
        if j.status != "active"
            continue
        path := j.path
        prog := DlParseAriaLogProgress(j.HasProp("log") ? j.log : "")
        ; 多连接乱序写盘时 FileGetSize=最高偏移（可秒级虚高到数 GB），必须以 aria2 日志为准
        diskSz := 0
        try diskSz := FileExist(path) ? FileGetSize(path) : 0
        if !diskSz && FileExist(path ".part") {
            try diskSz := FileGetSize(path ".part")
        }
        got := 0
        if Integer(prog.got) >= 0
            got := Integer(prog.got)
        else if FileExist(path ".aria2") || FileExist(path ".part")
            ; 尚无日志时切勿用磁盘尺寸（多连接虚高），沿用上次 got
            got := Integer(j.HasProp("got") ? j.got : 0)
        else
            got := diskSz
        if Integer(prog.total) > 0 {
            ; Content-Length 偏小：进度用服务器值；有控制文件时不抬高 total
            if got > Integer(prog.total) && !FileExist(path ".aria2") && !FileExist(path ".part")
                j.total := got
            else
                j.total := Integer(prog.total)
        } else if Integer(j.HasProp("total") ? j.total : 0) > 0 && got > Integer(j.total) {
            if !FileExist(path ".aria2") && !FileExist(path ".part")
                j.total := got
        }
        now := A_TickCount
        dt := Max(1, now - Integer(j.lastAt))
        dg := got - Integer(j.lastGot)
        if dg < 0
            dg := 0
        ; 首次对齐/超大跳变不算速度（续传读到已有体积会爆成几百 MB/s）
        alignOnly := (Integer(j.lastGot) <= 0 && got > 1024 * 1024)
            || (dg > 64 * 1048576 && dt < 2000)
        spd := 0
        ; 速度优先 aria2 DL:；否则用真实 got 增量（勿用磁盘虚高算速）
        if Integer(prog.speed) > 0
            spd := Integer(prog.speed)
        else if !alignOnly
            spd := Integer(dg * 1000 / dt)
        if spd > 200 * 1048576
            spd := Integer(prog.speed) > 0 ? Integer(prog.speed) : 0
        if got > Integer(j.lastGot)
            j.stallAt := now
        if !j.HasProp("stallAt")
            j.stallAt := Integer(j.HasProp("t0") ? j.t0 : now)
        j.got := got
        j.speed := spd
        DlTrackSpeed(j, spd)
        j.lastGot := got
        j.lastAt := now
        alive := j.pid && ProcessExist(j.pid)
        eng0 := j.HasProp("engine") ? j.engine : "aria2"
        ; BITS 起步慢；curl/aria 卡住太久才杀
        stallMs := (eng0 = "bits") ? 60000 : ((eng0 = "curl") ? 18000 : 12000)
        if alive && got < 1024 && (now - Integer(j.stallAt)) > stallMs {
            DlKillPidTree(j.pid)
            j.pid := 0
            alive := false
        }
        if !alive {
            try FileDelete j.cmd
            finalOk := FileExist(path) && FileGetSize(path) > 0
            if !finalOk && FileExist(path ".part") && FileGetSize(path ".part") > 0 {
                try FileMove path ".part", path, 1
                finalOk := FileExist(path) && FileGetSize(path) > 0
            }
            if !finalOk && prog.done && got > 0
                finalOk := true
            hasCtrl := FileExist(path ".aria2") || FileExist(path ".part")
            ; 进程已退出：日志完成 / 体积够 → 清残留控制文件并标完成；否则半成品改暂停（勿报错，避免「下完又冒进度/失败」）
            if finalOk && hasCtrl {
                if prog.done || (Integer(j.HasProp("total") ? j.total : 0) > 0 && got >= Integer(j.total)) || DlJobLooksComplete(j) {
                    try FileDelete path ".aria2"
                    try FileDelete path ".part"
                    hasCtrl := false
                } else
                    finalOk := false
            }
            bogusMsg := ""
            if finalOk && DlIsBogusDownload(path, j.HasProp("name") ? j.name : "") {
                finalOk := false
                bogSz := 0
                try bogSz := FileGetSize(path)
                ; 保留样本便于排查（中科大拦截页等）
                try {
                    global SEARCH_DIR
                    sample := (SEARCH_DIR != "" ? SEARCH_DIR : A_ScriptDir) "\last_bogus.html"
                    FileCopy path, sample, 1
                }
                try FileDelete path ; 清掉垃圾页，避免占名
                u0 := j.HasProp("url") ? String(j.url) : ""
                ; 拦截页：优先改用 Windows BITS（ISO/高校镜像 aria2/curl 常失败）
                if !(j.HasProp("bitsTried") && j.bitsTried) {
                    useRetry := u0
                    if j.HasProp("urls") && IsObject(j.urls) {
                        idx := Integer(j.HasProp("urlIdx") ? j.urlIdx : 1)
                        if idx >= 1 && idx <= j.urls.Length
                            useRetry := j.urls[idx]
                    }
                    if useRetry != "" {
                        j.bitsTried := true
                        try FileDelete path ".aria2"
                        try FileDelete path ".part"
                        spawned := DlSpawnBitsJob(j.dir, j.name, useRetry)
                        j.pid := spawned.pid
                        j.cmd := spawned.cmd
                        j.log := spawned.log
                        j.engine := "bits"
                        j.conn := 1
                        if spawned.HasProp("bitsName")
                            j.bitsName := spawned.bitsName
                        if spawned.HasProp("ps")
                            j.ps := spawned.ps
                        j.status := "active"
                        j.err := ""
                        j.got := 0
                        j.speed := 0
                        j.lastGot := 0
                        j.lastAt := A_TickCount
                        j.stallAt := A_TickCount
                        DL_JOBS[id] := j
                        changed := true
                        continue
                    }
                }
                if DlIsHuggingFaceUrl(u0)
                    bogusMsg := "下载到的是错误页（约 " bogSz " 字节），不是真实模型文件。可换 hf-mirror / 官方源重试"
                else if j.HasProp("engine") && j.engine = "bits"
                    bogusMsg := "下载失败：BITS 仍只拿到约 " bogSz " 字节的网页/拦截页。请在浏览器打开链接确认可下，或换清华/阿里云等镜像"
                else
                    bogusMsg := "下载失败：服务器返回了约 " bogSz " 字节的错误页/网页，不是真实文件。请检查链接是否可直链下载"
            }
            if finalOk {
                j.path := path
                j := DlMarkJobDone(j)
            } else if got > 0 && bogusMsg = "" {
                ; 有进度的半成品：暂停保留 .aria2，方便续传；清掉 cmd，log 留给下次判定
                j.status := "paused"
                j.pid := 0
                j.speed := 0
                j.err := ""
                try FileDelete j.cmd
                j.cmd := ""
                try {
                    if j.HasProp("dir") && j.dir != ""
                        DlSweepOrphanJobTemps(j.dir)
                }
            } else {
                hint0 := DlReadLogHint(j.HasProp("log") ? j.log : "")
                ; HTTP 非 2xx：按设置连接数再试一次无 Referer；不再强行降到单连接
                httpFail := InStr(hint0, "errorCode=22") || InStr(hint0, "status=403") || InStr(hint0, "status=404")
                    || InStr(hint0, "403 Forbidden") || InStr(bogusMsg, "错误页")
                if httpFail && !(j.HasProp("noRefTried") && j.noRefTried) {
                    aria := j.HasProp("aria") ? j.aria : FindLocalAria2c()
                    useRetry := j.HasProp("url") ? String(j.url) : ""
                    if j.HasProp("urls") && IsObject(j.urls) {
                        idx := Integer(j.HasProp("urlIdx") ? j.urlIdx : 1)
                        if idx >= 1 && idx <= j.urls.Length
                            useRetry := j.urls[idx]
                    }
                    connRetry := 0
                    try connRetry := Integer(DlGetSettings().conn)
                    if aria != "" && FileExist(aria) && useRetry != "" {
                        j.noRefTried := true
                        try FileDelete path
                        try FileDelete path ".aria2"
                        try FileDelete path ".part"
                        spawned := DlSpawnAriaJob(aria, j.dir, j.name, useRetry, connRetry, true)
                        j.pid := spawned.pid
                        j.cmd := spawned.cmd
                        j.log := spawned.log
                        j.conn := spawned.conn
                        j.status := "active"
                        j.err := ""
                        j.got := 0
                        j.speed := 0
                        j.lastGot := 0
                        j.lastAt := A_TickCount
                        j.stallAt := A_TickCount
                        DL_JOBS[id] := j
                        changed := true
                        continue
                    }
                }
                if DlRetryNextMirror(j) {
                    DL_JOBS[id] := j
                    changed := true
                    continue
                }
                j.status := "error"
                if bogusMsg != ""
                    j.err := bogusMsg
                else if InStr(hint0, "errorCode=22")
                    j.err := "服务器拒绝了下载请求（HTTP 错误）。已按设置连接数重试仍失败，请换镜像或检查链接"
                else {
                    j.err := hint0 != "" ? hint0 : "下载失败（无进度）"
                }
                j.speed := 0
                DlCleanupJobTemps(j)
                j.cmd := ""
                j.log := ""
            }
        }
        DL_JOBS[id] := j
        changed := true
    }
    if changed
        DlEmitState()
}

DlParseSettingsPayload(raw) {
    raw := Trim(String(raw))
    s := DlGetSettings()
    dir := s.dir
    failover := s.failover
    conn := s.conn
    mirrors := s.mirrors.Clone()
    if RegExMatch(raw, 'i)"dir"\s*:\s*"([^"]*)"', &m)
        dir := StrReplace(StrReplace(m[1], "\\", "\"), "\/", "/")
    if RegExMatch(raw, 'i)"failover"\s*:\s*(true|false)', &m)
        failover := (StrLower(m[1]) = "true")
    if RegExMatch(raw, 'i)"conn"\s*:\s*(\d+)', &m)
        conn := Integer(m[1])
    if RegExMatch(raw, 'i)"mirrors"\s*:\s*\[([^\]]*)\]', &mm) {
        mirrors := []
        body := mm[1]
        pos := 1
        while RegExMatch(body, '"([^"]+)"', &u, pos) {
            mirrors.Push(Trim(u[1]))
            pos := u.Pos + u.Len
        }
    }
    return { dir: dir, failover: failover, conn: conn, mirrors: mirrors }
}

; 探测下载链接：异步 HEAD（勿在主线程同步 WinHttp，否则确认/取消会卡住数秒）
global DL_PROBE_GEN := 0
global DL_PROBE_Q := []
global DL_PROBE_BUSY := false
global DL_PROBE_PID := 0
global DL_PROBE_OUT := ""
global DL_PROBE_URL := ""
global DL_PROBE_JOB_GEN := 0

DlDecodeUri(s) {
    s := String(s)
    out := ""
    i := 1
    while i <= StrLen(s) {
        ch := SubStr(s, i, 1)
        if ch = "%" && i + 2 <= StrLen(s) {
            hx := SubStr(s, i + 1, 2)
            if RegExMatch(hx, "i)^[0-9a-f]{2}$") {
                out .= Chr(Integer("0x" hx))
                i += 3
                continue
            }
        }
        out .= ch
        i++
    }
    return out
}

DlCancelProbes(*) {
    global DL_PROBE_GEN, DL_PROBE_Q, DL_PROBE_BUSY, DL_PROBE_PID, DL_PROBE_OUT
    DL_PROBE_GEN += 1
    DL_PROBE_Q := []
    DL_PROBE_BUSY := false
    if DL_PROBE_PID && ProcessExist(DL_PROBE_PID) {
        try Run(A_ComSpec " /c taskkill /F /T /PID " DL_PROBE_PID " >nul 2>&1", , "Hide")
        try ProcessClose(DL_PROBE_PID)
    }
    DL_PROBE_PID := 0
    if DL_PROBE_OUT != "" {
        try FileDelete DL_PROBE_OUT
        try FileDelete RegExReplace(DL_PROBE_OUT, "i)\.json$", ".ps1")
    }
    DL_PROBE_OUT := ""
    try SetTimer(DlPollProbeJob, 0)
}

DlQueueProbe(url) {
    global DL_PROBE_Q, DL_PROBE_GEN
    u := Trim(String(url))
    if u = "" || !RegExMatch(u, "i)^https?://")
        return
    if !IsObject(DL_PROBE_Q)
        DL_PROBE_Q := []
    ; 去重
    for item in DL_PROBE_Q {
        if item.HasProp("url") && item.url = u
            return
    }
    DL_PROBE_Q.Push({ url: u, gen: DL_PROBE_GEN })
    SetTimer(DlPumpProbes, -30)
}

DlPumpProbes(*) {
    global DL_PROBE_Q, DL_PROBE_BUSY, DL_PROBE_GEN
    if DL_PROBE_BUSY
        return
    if !IsObject(DL_PROBE_Q) || DL_PROBE_Q.Length < 1
        return
    ; 丢掉过期项
    while DL_PROBE_Q.Length {
        item := DL_PROBE_Q.RemoveAt(1)
        if Integer(item.gen) = Integer(DL_PROBE_GEN) {
            DlStartProbeJob(item.url, item.gen)
            return
        }
    }
}

DlStartProbeJob(url, gen) {
    global DL_PROBE_BUSY, DL_PROBE_PID, DL_PROBE_OUT, DL_PROBE_URL, DL_PROBE_JOB_GEN, DL_PROBE_GEN
    if Integer(gen) != Integer(DL_PROBE_GEN)
        return
    u := Trim(String(url))
    tick := A_TickCount
    out := A_Temp "\ahk_dl_probe_" tick ".json"
    ps1 := A_Temp "\ahk_dl_probe_" tick ".ps1"
    try FileDelete out
    try FileDelete ps1
    ue := StrReplace(u, "'", "''")
    oe := StrReplace(out, "'", "''")
    ; 仅 HEAD，2s 超时；不阻塞 AHK 主线程
    body := "$ErrorActionPreference='SilentlyContinue'`n"
        . "try{[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13}catch{try{[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12}catch{}}`n"
        . "$u='" ue "'`n"
        . "$out='" oe "'`n"
        . "$r=[ordered]@{url=$u;size=0;type='';title='';name='';host='';err=''}`n"
        . "try{ $r.host=([Uri]$u).Host }catch{}`n"
        . "try{`n"
        . "  $req=[System.Net.HttpWebRequest]::Create($u)`n"
        . "  $req.Method='HEAD'; $req.AllowAutoRedirect=$true; $req.Timeout=2000; $req.ReadWriteTimeout=2000`n"
        . "  $req.UserAgent='Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/120.0.0.0 Safari/537.36'`n"
        . "  $req.Accept='*/*'`n"
        . "  $resp=$req.GetResponse()`n"
        . "  try{`n"
        . "    try{ $r.size=[int64]$resp.Headers['Content-Length'] }catch{}`n"
        . "    try{ $r.type=[string]$resp.ContentType }catch{}`n"
        . "    $cd=[string]$resp.Headers['Content-Disposition']`n"
        . "    if($cd -match 'filename\*=UTF-8''''([^;]+)'){ $r.name=[Uri]::UnescapeDataString($Matches[1]) }`n"
        . "    elseif($cd -match 'filename=`"([^`"]+)`"'){ $r.name=$Matches[1] }`n"
        . "    elseif($cd -match 'filename=([^;]+)'){ $r.name=$Matches[1].Trim().Trim('`"') }`n"
        . "  } finally { $resp.Close() }`n"
        . "} catch { $r.err=[string]$_.Exception.Message }`n"
        . "($r|ConvertTo-Json -Compress)|Set-Content -LiteralPath $out -Encoding utf8`n"
    try FileAppend body, ps1, "UTF-8"
    catch {
        SetTimer(DlPumpProbes, -30)
        return
    }
    pid := 0
    try Run('powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' ps1 '"', A_Temp, "Hide", &pid)
    catch {
        SetTimer(DlPumpProbes, -30)
        return
    }
    if !pid {
        SetTimer(DlPumpProbes, -30)
        return
    }
    DL_PROBE_BUSY := true
    DL_PROBE_PID := pid
    DL_PROBE_OUT := out
    DL_PROBE_URL := u
    DL_PROBE_JOB_GEN := gen
    SetTimer(DlPollProbeJob, 120)
}

DlPollProbeJob(*) {
    global DL_PROBE_BUSY, DL_PROBE_PID, DL_PROBE_OUT, DL_PROBE_URL, DL_PROBE_JOB_GEN, DL_PROBE_GEN, wvCore
    if !DL_PROBE_BUSY
        return
    out := DL_PROBE_OUT
    alive := DL_PROBE_PID && ProcessExist(DL_PROBE_PID)
    if !FileExist(out) {
        if !alive {
            DL_PROBE_BUSY := false
            DL_PROBE_PID := 0
            try SetTimer(DlPollProbeJob, 0)
            SetTimer(DlPumpProbes, -20)
        }
        return
    }
    raw := ""
    try raw := Trim(FileRead(out, "UTF-8"), " `t`r`n")
    if raw = "" {
        if !alive {
            DL_PROBE_BUSY := false
            DL_PROBE_PID := 0
            try SetTimer(DlPollProbeJob, 0)
            SetTimer(DlPumpProbes, -20)
        }
        return
    }
    ; 结果已写出
    try SetTimer(DlPollProbeJob, 0)
    genOk := Integer(DL_PROBE_JOB_GEN) = Integer(DL_PROBE_GEN)
    size := 0
    type := "", title := "", name := "", host := "", url := DL_PROBE_URL
    if RegExMatch(raw, 'i)"url"\s*:\s*"((?:\\.|[^"\\])*)"', &m)
        url := StrReplace(m[1], "\\", "\")
    if RegExMatch(raw, 'i)"size"\s*:\s*(-?\d+)', &m)
        size := Integer(m[1])
    if RegExMatch(raw, 'i)"type"\s*:\s*"((?:\\.|[^"\\])*)"', &m)
        type := StrReplace(m[1], "\\", "\")
    if RegExMatch(raw, 'i)"title"\s*:\s*"((?:\\.|[^"\\])*)"', &m)
        title := StrReplace(m[1], "\\", "\")
    if RegExMatch(raw, 'i)"name"\s*:\s*"((?:\\.|[^"\\])*)"', &m)
        name := StrReplace(m[1], "\\", "\")
    if RegExMatch(raw, 'i)"host"\s*:\s*"((?:\\.|[^"\\])*)"', &m)
        host := StrReplace(m[1], "\\", "\")
    try FileDelete out
    try FileDelete RegExReplace(out, "i)\.json$", ".ps1")
    if DL_PROBE_PID && ProcessExist(DL_PROBE_PID) {
        try ProcessClose(DL_PROBE_PID)
    }
    DL_PROBE_BUSY := false
    DL_PROBE_PID := 0
    DL_PROBE_OUT := ""
    if genOk && IsObject(wvCore) {
        js := "try{window.__dlOnProbe&&window.__dlOnProbe({"
            . "url:" JStr(url) ","
            . "size:" Integer(size) ","
            . "type:" JStr(type) ","
            . "title:" JStr(title) ","
            . "name:" JStr(name) ","
            . "host:" JStr(host)
            . "})}catch(e){}"
        try wvCore.ExecuteScriptAsync(js)
    }
    SetTimer(DlPumpProbes, -20)
}

DlProbeUrlTick(url) {
    ; 兼容旧调用：改走异步队列
    DlQueueProbe(url)
}

DlHandleUiMsg(msg) {
    m := String(msg)
    if m = "dlEnsure" {
        SetTimer(DlEnsure, -1)
        return true
    }
    if m = "dlPeekClip" {
        global wvCore
        clip := ""
        try clip := Trim(A_Clipboard)
        if IsObject(wvCore)
            try wvCore.ExecuteScriptAsync("try{window.__dlOnClipPeek&&window.__dlOnClipPeek(" JStr(clip) ")}catch(e){}")
        return true
    }
    if m = "dlProbeCancel" {
        DlCancelProbes()
        return true
    }
    if SubStr(m, 1, 8) = "dlProbe|" {
        DlQueueProbe(SubStr(m, 9))
        return true
    }
    if SubStr(m, 1, 6) = "dlAdd|" {
        ; 优先开下，探测让路
        SetTimer(DlAddUrl.Bind(SubStr(m, 7)), -1)
        return true
    }
    if m = "dlPickDir" {
        SetTimer(DlPickDir, -1)
        return true
    }
    if m = "dlPauseAll" {
        SetTimer(DlPauseAll, -1)
        return true
    }
    if m = "dlResumeAll" {
        SetTimer(DlResumeAll, -1)
        return true
    }
    if SubStr(m, 1, 10) = "dlOpenFile|" {
        DlOpenJobFile(SubStr(m, 11))
        return true
    }
    if SubStr(m, 1, 12) = "dlOpenFolder|" {
        DlOpenJobFolder(SubStr(m, 13))
        return true
    }
    if m = "dlOpenDir" || SubStr(m, 1, 10) = "dlOpenDir|" {
        if !DlQueueReveal(DlDataDir())
            DlToast("无法打开下载目录", true)
        return true
    }
    if SubStr(m, 1, 9) = "dlRename|" {
        rest := SubStr(m, 10)
        if RegExMatch(rest, "^([^|]+)\|(.+)$", &rm)
            SetTimer(DlApplyRename.Bind(rm[1], rm[2]), -1)
        return true
    }
    if SubStr(m, 1, 13) = "dlRedownload|" {
        SetTimer(DlRedownloadJob.Bind(SubStr(m, 14)), -1)
        return true
    }
    if SubStr(m, 1, 8) = "dlPause|" {
        SetTimer(DlPauseJob.Bind(SubStr(m, 9)), -1)
        return true
    }
    if SubStr(m, 1, 9) = "dlResume|" {
        SetTimer(DlResumeJob.Bind(SubStr(m, 10)), -1)
        return true
    }
    ; 注意：dlRemove| = 9 字符，dlPurge| = 8 字符；dlRemoveMany|/dlPurgeMany| 支持逗号分隔多 id
    if SubStr(m, 1, 13) = "dlRemoveMany|" {
        SetTimer(DlRemoveJobs.Bind(SubStr(m, 14), false), -1)
        return true
    }
    if SubStr(m, 1, 12) = "dlPurgeMany|" {
        SetTimer(DlRemoveJobs.Bind(SubStr(m, 13), true), -1)
        return true
    }
    if SubStr(m, 1, 9) = "dlRemove|" {
        SetTimer(DlRemoveJobs.Bind(SubStr(m, 10), false), -1)
        return true
    }
    if SubStr(m, 1, 8) = "dlPurge|" {
        SetTimer(DlRemoveJobs.Bind(SubStr(m, 9), true), -1)
        return true
    }
    if SubStr(m, 1, 10) = "dlOpenUrl|" {
        u := Trim(SubStr(m, 11))
        if RegExMatch(u, "i)^https?://")
            try Run(u)
        return true
    }
    if SubStr(m, 1, 15) = "dlSaveSettings|" {
        raw := SubStr(m, 16)
        s := DlParseSettingsPayload(raw)
        DlSaveSettingsObj(s)
        DlEmitSettings()
        global wvCore
        if IsObject(wvCore)
            try wvCore.ExecuteScriptAsync("try{window.__dlToast&&window.__dlToast(" JStr("下载设置已保存") ")}catch(e){}")
        return true
    }
    if SubStr(m, 1, 2) = "dl" || SubStr(m, 1, 3) = "dl|"
        return true
    if RegExMatch(m, "i)^dl[A-Z]")
        return true
    return false
}

; 启动即恢复任务列表（不等打开下载页）
try DlLoadJobs()
try DlStartPoll()
