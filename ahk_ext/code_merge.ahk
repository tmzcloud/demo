#Requires AutoHotkey v2.0
#NoTrayIcon
#SingleInstance Force

; 只有当 GoLand 窗口处于激活状态时才生效
#HotIf WinActive("ahk_exe goland64.exe")

; 输入 ?merge 并按下【空格】或【回车】触发
::?merge:: {
    ; 1. 获取当前激活窗口的标题并提取项目名称
    title := WinGetTitle("A")
    if (!RegExMatch(title, "^([a-zA-Z0-9_\-]+)", &match)) {
        MsgBox("无法从当前窗口标题中解析出项目名称！`n标题: " title, "错误", "Icon!")
        return
    }
    projectName := match[1]
    projectPath := "E:\dev\goland project\" . projectName

    if (!DirExist(projectPath)) {
        MsgBox("拼接出的项目路径在本地不存在！`n路径: " projectPath, "路径无效", "Icon!")
        return
    }

    targetDevelop := "develop"
    targetStaging := "staging"

    ; 彻底抹杀开头的黑框闪烁
    curBranchName := ""
    tempBranchFile := A_Temp "\ahk_git_branch_temp.txt"
    if FileExist(tempBranchFile)
        FileDelete(tempBranchFile)

    try {
        RunWait(A_ComSpec ' /c cd /d "' projectPath '" && git branch --show-current > "' tempBranchFile '"', , "Hide")
        if FileExist(tempBranchFile) {
            curBranchName := FileRead(tempBranchFile, "UTF-8")
            curBranchName := RegExReplace(curBranchName, "[\r\n\s\t]", "")
            FileDelete(tempBranchFile)
        }
    } catch {
        curBranchName := ""
    }

    if (curBranchName == "") {
        curBranchName := "HEAD"
    }

    ; 提前在 AHK 层面拦截核心主分支误触
    if (curBranchName == targetDevelop || curBranchName == targetStaging) {
        MsgBox("🛑 [⚠️ 严重警告]`n`n你当前正处于公共核心分支【" curBranchName "】上！`n`n不允许在公共分支上触发合并流水线，请在 GoLand 中先切回您的特性开发分支！", "拦截熔断", "Icon!")
        return
    }

    ; 2. 创建独立的 PowerShell 脚本文件
    psFile := A_Temp "\ahk_git_pipeline_worker.ps1"
    if FileExist(psFile)
        FileDelete(psFile)

    FileAppend("[System.Console]::OutputEncoding = [System.Text.Encoding]::UTF8`n", psFile, "UTF-8")

    ; 调整缓冲区大小
    FileAppend("$Host.UI.RawUI.BufferSize = New-Object System.Management.Automation.Host.Size(110, 1000)`n", psFile, "UTF-8")
    FileAppend("$Host.UI.RawUI.WindowSize = New-Object System.Management.Automation.Host.Size(110, 35)`n", psFile, "UTF-8")

    FileAppend("Clear-Host`n", psFile, "UTF-8")
    FileAppend("Write-Host '============================================================' -ForegroundColor Cyan`n", psFile, "UTF-8")
    FileAppend("Write-Host '                  🚀 流水线发布自动化控制台 🚀                 ' -ForegroundColor Cyan`n", psFile, "UTF-8")
    FileAppend("Write-Host '============================================================' -ForegroundColor Cyan`n", psFile, "UTF-8")
    FileAppend("Write-Host '[项目名称]: ' -NoNewline; Write-Host '" projectName "' -ForegroundColor Green`n", psFile, "UTF-8")
    FileAppend("Write-Host '[项目路径]: ' -NoNewline; Write-Host '" projectPath "' -ForegroundColor Green`n", psFile, "UTF-8")
    FileAppend("Write-Host '[当前分支]: ' -NoNewline; Write-Host '" curBranchName "' -ForegroundColor Green`n", psFile, "UTF-8")
    FileAppend("Write-Host ''`n", psFile, "UTF-8")

    ; 切目录并拉取 Tag
    FileAppend("Set-Location -LiteralPath '" projectPath "'`n", psFile, "UTF-8")
    FileAppend("Write-Host '正在同步拉取全网最新远程 Tag (请在下方查看进度)...' -ForegroundColor Yellow`n", psFile, "UTF-8")
    FileAppend("git fetch --tags 2>$null`n", psFile, "UTF-8")
    FileAppend("Write-Host '-> Tag 同步完成。'`n", psFile, "UTF-8")
    FileAppend("Write-Host ''`n", psFile, "UTF-8")

    ; 渲染最近 10 个历史标签
    FileAppend("Write-Host '📋 全网最新 10 个 Tag 历史（由旧 to 新排序）：' -ForegroundColor Yellow`n", psFile, "UTF-8")
    FileAppend("Write-Host '------------------------------------------------------------' -ForegroundColor DarkGray`n", psFile, "UTF-8")
    FileAppend("$global:i = 0`n", psFile, "UTF-8")
    FileAppend("$tags = git tag --sort=-v:refname | Where-Object { $_ -notlike '*-h.*' } | Select-Object -First 10 | ForEach-Object { $global:i++; [PSCustomObject]@{Index=$global:i; Tag=$_} }`n", psFile, "UTF-8")
    FileAppend("if ($tags) { $tags | Sort-Object Index -Descending | ForEach-Object { Write-Host (' {0}. {1}' -f (11-$_.Index), $_.Tag) -ForegroundColor Gray } } else { Write-Host '  (暂无历史 Tag)' -ForegroundColor DarkGray }`n", psFile, "UTF-8")
    FileAppend("Write-Host '------------------------------------------------------------' -ForegroundColor DarkGray`n", psFile, "UTF-8")
    FileAppend("Write-Host ''`n", psFile, "UTF-8")

    ; ======================================================================
    ; 🧠 【全新算法】精准自适应 RC 顺延与越级控制引擎
    ; ======================================================================
    FileAppend("$rawTags = git tag --sort=-v:refname`n", psFile, "UTF-8")
    FileAppend("$allTags = $rawTags | Where-Object { $_ -notlike '*-h.*' -and $_ -notlike '*-dev.*' }`n", psFile, "UTF-8")
    FileAppend("if ($allTags) {`n", psFile, "UTF-8")
    FileAppend("    $latest = $allTags[0]`n", psFile, "UTF-8")
    FileAppend("    `n", psFile, "UTF-8")
    FileAppend("    if ($latest -match '^v?(\d+\.\d+\.\d+)-rc\.(\d+)') {`n", psFile, "UTF-8")
    FileAppend("        # 情况 A：最新 Tag 已经是 RC 版 (如 v1.7.25-rc.1) -> 必须精准顺延 RC 序号！`n", psFile, "UTF-8")
    FileAppend("        $baseVer = $Matches[1]`n", psFile, "UTF-8")
    FileAppend("        $rcNum = [int]$Matches[2] + 1`n", psFile, "UTF-8")
    FileAppend("        $NEXT_TAG = 'v' + $baseVer + '-rc.' + $rcNum`n", psFile, "UTF-8")
    FileAppend("    } elseif ($latest -match '^v?(\d+\.\d+\.\d+)') {`n", psFile, "UTF-8")
    FileAppend("        # 情况 B：最新 Tag 是个正式版 (如 v1.7.25) -> 小版本自动 +1，启动新 RC 周期`n", psFile, "UTF-8")
    FileAppend("        $currentVersion = [version]$Matches[1]`n", psFile, "UTF-8")
    FileAppend("        $newVersion = New-Object Version($currentVersion.Major, $currentVersion.Minor, ($currentVersion.Build + 1))`n", psFile, "UTF-8")
    FileAppend("        $NEXT_TAG = 'v' + $newVersion.ToString() + '-rc.1'`n", psFile, "UTF-8")
    FileAppend("    } else {`n", psFile, "UTF-8")
    FileAppend("        $NEXT_TAG = 'v1.7.26-rc.1'`n", psFile, "UTF-8")
    FileAppend("    }`n", psFile, "UTF-8")
    FileAppend("} else {`n", psFile, "UTF-8")
    FileAppend("    $NEXT_TAG = 'v1.0.0-rc.1'`n", psFile, "UTF-8")
    FileAppend("}`n", psFile, "UTF-8")
    ; ======================================================================

    FileAppend("Write-Host '🚀 计算出下一个 rc Tag: ' -NoNewline; Write-Host ('【 ' + $NEXT_TAG + ' 】') -ForegroundColor Red`n", psFile, "UTF-8")
    FileAppend("Write-Host ''`n", psFile, "UTF-8")

    ; 展现菜单
    FileAppend("Write-Host '============================================================' -ForegroundColor Cyan`n", psFile, "UTF-8")
    FileAppend("Write-Host '请选择你要执行的流水线组合：' -ForegroundColor White`n", psFile, "UTF-8")
    FileAppend("Write-Host '  [1] Only Dev    -- 只推当前分支 + 合并推送 develop' -ForegroundColor DarkYellow`n", psFile, "UTF-8")
    FileAppend("Write-Host `"  [2] Dev & Stage -- 推当前分支 + 合并推送 develop 和 staging`" -ForegroundColor DarkYellow`n", psFile, "UTF-8")
    FileAppend("Write-Host '  [3] ALL (全套)   -- 双分支全合并推送 + 自动打 Tag 发射上天 [默认回车]' -ForegroundColor Red`n", psFile, "UTF-8")
    FileAppend("Write-Host '  [4] 取消退出     -- 中断操作' -ForegroundColor DarkGray`n", psFile, "UTF-8")
    FileAppend("Write-Host '============================================================' -ForegroundColor Cyan`n", psFile, "UTF-8")
    FileAppend("Write-Host ''`n", psFile, "UTF-8")

    FileAppend("do {`n", psFile, "UTF-8")
    FileAppend("    $choice = Read-Host '请输入选项 (1-4) [默认回车全套]'`n", psFile, "UTF-8")
    FileAppend("    if ($choice -eq '') { $choice = '3' }`n", psFile, "UTF-8")
    FileAppend("} while ($choice -notmatch '^[1-4]$')`n", psFile, "UTF-8")

    FileAppend("if ($choice -eq '4') { Write-Host '[X] 操作已取消，安全退出...' -ForegroundColor DarkGray; Start-Sleep -Seconds 1; Exit }`n", psFile, "UTF-8")

    ; 智慧大脑宏函数
    FileAppend("function Run-GitCmd ($title, $cmd) {`n", psFile, "UTF-8")
    FileAppend("    Write-Host ''; Write-Host (($global:step.ToString() + '.>>> ' + $title)) -ForegroundColor Yellow; $global:step++`n", psFile, "UTF-8")
    FileAppend("    $msg = Invoke-Expression $cmd 2>&1 | Out-String`n", psFile, "UTF-8")
    FileAppend("    if ($msg.Trim() -ne '') {`n", psFile, "UTF-8")
    FileAppend("        $msg.Split([char]10) | ForEach-Object { if ($_.Trim() -ne '') { Write-Host ('  ' + $_) -ForegroundColor Gray } }`n", psFile, "UTF-8")
    FileAppend("    }`n", psFile, "UTF-8")
    FileAppend("    $code = $LASTEXITCODE`n", psFile, "UTF-8")
    FileAppend("    if ($code -ne 0 -and $msg -notmatch 'Already up to date' -and $msg -notmatch 'Everything up-to-date' -and $msg -notmatch 'no changes added') {`n", psFile, "UTF-8")
    FileAppend("        Write-Host '`n💥 [ERROR] 流水线遭遇致命异常或代码冲突，已紧急实施熔断保护！' -ForegroundColor Red`n", psFile, "UTF-8")
    FileAppend("        Write-Host '请排查上方灰色 Git 日志。错误排除前，后续代码已被禁止运行。`n' -ForegroundColor Red`n", psFile, "UTF-8")
    FileAppend("        Read-Host '所有流程已终止。按下回车键（Enter）即可安全退出控制台...'`n", psFile, "UTF-8")
    FileAppend("        Exit`n", psFile, "UTF-8")
    FileAppend("    }`n", psFile, "UTF-8")
    FileAppend("}`n", psFile, "UTF-8")

    ; 核心第一个公共执行步骤
    FileAppend("$global:step = 1`n", psFile, "UTF-8")
    FileAppend("Run-GitCmd '先把当前开发分支 [" curBranchName "] 推送到远程...' 'git push origin " curBranchName " 2>$null'`n", psFile, "UTF-8")

    ; 执行分支 1：Only Dev
    FileAppend("if ($choice -eq '1') {`n", psFile, "UTF-8")
    FileAppend("    $global:step = 1`n", psFile, "UTF-8")
    FileAppend("    Run-GitCmd '切到 [" targetDevelop "] 分支...' 'git checkout " targetDevelop "'`n", psFile, "UTF-8")
    FileAppend("    Run-GitCmd '拉取远程 [" targetDevelop "] 最新代码...' 'git pull origin " targetDevelop "'`n", psFile, "UTF-8")
    FileAppend("    Run-GitCmd '将开发分支 [" curBranchName "] 强制非快进合并到 [" targetDevelop "]...' 'git merge " curBranchName " --no-ff --no-edit'`n", psFile, "UTF-8")
    FileAppend("    Run-GitCmd '推送合并后的 [" targetDevelop "] 到远程...' 'git push origin " targetDevelop " 2>$null'`n", psFile, "UTF-8")
    FileAppend("    Run-GitCmd '安全切回您的开发分支 [" curBranchName "]...' 'git checkout " curBranchName "'`n", psFile, "UTF-8")
    FileAppend("    Write-Host '`n🎉🎉🎉 [OK] Only Dev 模式全部步骤顺利执行完毕！' -ForegroundColor Green`n", psFile, "UTF-8")
    FileAppend("}`n", psFile, "UTF-8")

    ; 执行分支 2：Dev & Stage
    FileAppend("if ($choice -eq '2') {`n", psFile, "UTF-8")
    FileAppend("    $global:step = 1`n", psFile, "UTF-8")
    FileAppend("    Run-GitCmd '切到 [" targetDevelop "] 分符...' 'git checkout " targetDevelop "'`n", psFile, "UTF-8")
    FileAppend("    Run-GitCmd '拉取远程 [" targetDevelop "] 最新代码...' 'git pull origin " targetDevelop "'`n", psFile, "UTF-8")
    FileAppend("    Run-GitCmd '将开发分支 [" curBranchName "] 强制非快进合并到 [" targetDevelop "]...' 'git merge " curBranchName " --no-ff --no-edit'`n", psFile, "UTF-8")
    FileAppend("    Run-GitCmd '推送合并后的 [" targetDevelop "] 到远程...' 'git push origin " targetDevelop " 2>$null'`n", psFile, "UTF-8")
    FileAppend("    Run-GitCmd '切到 [" targetStaging "] 分支...' 'git checkout " targetStaging "'`n", psFile, "UTF-8")
    FileAppend("    Run-GitCmd '拉取远程 [" targetStaging "] 最新代码...' 'git pull origin " targetStaging "'`n", psFile, "UTF-8")
    FileAppend("    Run-GitCmd '将开发分支 [" curBranchName "] 强制非快进合并到 [" targetStaging "]...' 'git merge " curBranchName " --no-ff --no-edit'`n", psFile, "UTF-8")
    FileAppend("    Run-GitCmd '推送合并后的 [" targetStaging "] 到远程...' 'git push origin " targetStaging " 2>$null'`n", psFile, "UTF-8")
    FileAppend("    Run-GitCmd '安全切回您的开发分支 [" curBranchName "]...' 'git checkout " curBranchName "'`n", psFile, "UTF-8")
    FileAppend("    Write-Host `"  `n🎉🎉🎉 [OK] Dev & Stage 双环境合并发布成功！`" -ForegroundColor Green`n", psFile, "UTF-8")
    FileAppend("}`n", psFile, "UTF-8")

    ; 执行分支 3：ALL (全套)
    FileAppend("if ($choice -eq '3') {`n", psFile, "UTF-8")
    FileAppend("    $global:step = 1`n", psFile, "UTF-8")
    FileAppend("    Run-GitCmd '切到 [" targetDevelop "] 分支...' 'git checkout " targetDevelop "'`n", psFile, "UTF-8")
    FileAppend("    Run-GitCmd '拉取远程 [" targetDevelop "] 最新代码...' 'git pull origin " targetDevelop "'`n", psFile, "UTF-8")
    FileAppend("    Run-GitCmd '将开发分支 [" curBranchName "] 强制非快进合并到 [" targetDevelop "]...' 'git merge " curBranchName " --no-ff --no-edit'`n", psFile, "UTF-8")
    FileAppend("    Run-GitCmd '推送合并后的 [" targetDevelop "] 到远程...' 'git push origin " targetDevelop " 2>$null'`n", psFile, "UTF-8")
    FileAppend("    Run-GitCmd '切到 [" targetStaging "] 分支...' 'git checkout " targetStaging "'`n", psFile, "UTF-8")
    FileAppend("    Run-GitCmd '拉取远程 [" targetStaging "] 最新代码...' 'git pull origin " targetStaging "'`n", psFile, "UTF-8")
    FileAppend("    Run-GitCmd '将开发分支 [" curBranchName "] 强制非快进合并到 [" targetStaging "]...' 'git merge " curBranchName " --no-ff --no-edit'`n", psFile, "UTF-8")
    FileAppend("    Run-GitCmd '推送合并后的 [" targetStaging "] 到远程...' 'git push origin " targetStaging " 2>$null'`n", psFile, "UTF-8")

    ; 标签处理
    FileAppend("    Write-Host ''; Write-Host ($global:step.ToString() + '.>>> 在本地打上全新编译 Tag: [' + $NEXT_TAG + ']...') -ForegroundColor Yellow; $global:step++`n", psFile, "UTF-8")
    FileAppend("    $tagOut = git tag $NEXT_TAG 2>&1 | Out-String`n", psFile, "UTF-8")
    FileAppend("    if ($tagOut.Trim() -ne '') { $tagOut.Split([char]10) | ForEach-Object { if ($_.Trim() -ne '') { Write-Host ('  ' + $_) -ForegroundColor Gray } } }`n", psFile, "UTF-8")
    FileAppend("    if ($LASTEXITCODE -ne 0 -and $tagOut -notmatch 'already exists') { Write-Host '`n💥 [ERROR] 打 Tag 失败！本地可能已存在该标签。' -ForegroundColor Red; Read-Host '回车退出...'; Exit }`n", psFile, "UTF-8")

    FileAppend("    Write-Host ''; Write-Host ($global:step.ToString() + '.>>> 将新 Tag [' + $NEXT_TAG + '] 发射推送至远程流水线...') -ForegroundColor Yellow; $global:step++`n", psFile, "UTF-8")
    FileAppend("    $pushTagOut = git push origin $NEXT_TAG 2>$null | Out-String`n", psFile, "UTF-8")

    ; 自动提取版本号并复制到剪贴板
    FileAppend("    Set-Clipboard -Value $NEXT_TAG`n", psFile, "UTF-8")
    FileAppend("    Write-Host '  📋 [CLIPBOARD] 剪贴板已秒速锁死！'`n", psFile, "UTF-8")

    FileAppend("    Run-GitCmd '安全切回您的开发分支 [" curBranchName "]...' 'git checkout " curBranchName "'`n", psFile, "UTF-8")

    FileAppend("    Write-Host '------------------------------------------------------------' -ForegroundColor DarkGray`n", psFile, "UTF-8")
    FileAppend("    Write-Host '📢 [ ' $NEXT_TAG ' ] 版本号已自动复制到剪贴板！' -ForegroundColor Green`n", psFile, "UTF-8")
    FileAppend("    Write-Host '👉 请立刻前往 Bitbucket 页面，手动打包 classic staging 🚀' -ForegroundColor Yellow`n", psFile, "UTF-8")
    FileAppend("    Write-Host '------------------------------------------------------------' -ForegroundColor DarkGray`n", psFile, "UTF-8")
    FileAppend("    Write-Host '`n🎉🎉群雄退散！ALL 全套流水线合并发布、Tag自动编译启动成功！' -ForegroundColor Green`n", psFile, "UTF-8")
    FileAppend("}`n", psFile, "UTF-8")

    ; 兜底锁：手动回车才退出
    FileAppend("Write-Host '`n所有任务跑完啦！' -ForegroundColor Cyan`n", psFile, "UTF-8")
    FileAppend("Read-Host '按下回车键（Enter）即可安全关闭此控制台...'`n", psFile, "UTF-8")

    ; 4. 唤醒并执行 PowerShell 脚本
    Run("powershell.exe -NoExit -ExecutionPolicy Bypass -File `"" psFile "`"")

    ; AHK 外层物理强行居中
    if WinWait("ahk_exe powershell.exe", , 3) {
        WinCenter("ahk_exe powershell.exe")
    }
}

/**
 * 🛠️ 外置 AHK 高精度万能窗口居中函数
 */
WinCenter(WinTitle) {
    if !WinExist(WinTitle)
        return
    WinGetPos(,, &wWidth, &wHeight, WinTitle)
    MonitorGetWorkArea(, &mLeft, &mTop, &mRight, &mBottom)
    targetX := mLeft + ( (mRight - mLeft - wWidth) / 2 )
    targetY := mTop + ( (mBottom - mTop - wHeight) / 2 )
    WinMove(targetX, targetY, , , WinTitle)
    WinActivate(WinTitle)
}
#HotIf