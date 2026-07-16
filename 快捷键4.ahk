;>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>
;AHK2.0.4_U64 快捷键4.0  create by tsz time:2023年8月28日08:31:28
;功能：
    ;①、初始话环境变量HELPME_HOME，设置java，oracle等环境变量，复制当前文件到环境变量，创建快捷放是在c:\windows下，创建job
    ;②、ctrl+1 搜狗翻译 ，搜狗ocr
    ;③、记录剪切板数据到%HELPME_HOME%\command_ext\ahk\log\clip.log目录下
    ;④、修改系统快捷键映射
    ;⑤、实现ctrl+v粘贴图片到任意位置
    ;⑥、实现运行框【回车】执行自定义命令
        ;- touch 命令在桌面创建文件并打开
        ;- spy/close 命令打开和关闭窗口检测程序
        ;- his 命令查看今天的剪切板历史记录
        ;- his2/runlog 查看运行框日志
        ;- log/syslog  查看脚本系统运行日志
        ;- base64命令把图片转为base64并打开
        ;- runconfig.txt 中命令配置包括 快捷键，网页，文件夹，cmd命令
    ;⑦、实现运行框==运算
    ;⑧、任务栏透明，不定时
    ;⑨、添加脚本运行日志sys.log ,和运行日志run.log
    ;⑩、系统图标
    ;⑪、新增阅读模式，快捷ocr模式，方便浏览x
    ;⑫、ctrl+shift+c复制文件路径
    ;⑬、修改必应bing壁纸
    ;⑭、修改了win11上的向下复制一行，修改截图工具为pixpin, shift+f2打开音量兼容，滚轮点击打开选中链接！
    ;⑮、添加对windows的copilot支持，打开/关闭 copilot自动切换代理
    ;⑯、添加功能 选中链接地址按鼠标中键即可跳转到浏览器，或者是关键字
    ;⑰、添加功能 获取手机验证码，各种提示短信等
    ;⑱、添加功能 鼠标右键新增最近打开文件选项

;提示：
    ;1、操作环境变量尽量用注册表来操作，实时性比较高envGet ,envSet都是环境中读取，实时性不高，也不是永久的
    ;2、要获取返回cookie的请求如果是用的同一个req，会缓存，下次就不会返回请求头所以请求一次就行了，多次会报错
    ;3、注意数组array的坑，所有操作都是对索引，比如has(index),delete(index)，需要自己写方法来用值操作
    ;4、如果要设置为透明请把底色设置为#ffffff白色，这样就不会有一个明度过程
    ;5、format在有换行“`n”时不会有空格对齐效果
    ;6、在比较字符串时，如果用"=" 表示不区分大小写，如果用"==" 表示严格区分大小写
    ;7、注意把死循环耗时的timer写在最前面，不耗时的timer写后面，因为后面的timer会自动中断前面的timer在优先级相同情况下
    ;8、超长字符串在打包后会报错，必须用 xx:=" [换行]( LTrim Join [换行] xxxxxxx  [换行] )"
    ;9、注意LTrim("get temp" ,"get ") 这种有风险，不会得到想要的temp而是mp具体机制不清楚，使用自定义ak.trim(str,"L")
;>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>
;#Requires AutoHotkey 64-bit
#SingleInstance force
;动态创建web2依赖
if (!FileExist(A_Temp "\WebView2.ahk") || !FileExist(A_Temp "\WebView2Loader.dll")) {
    outDependData.init()     ;0.初始化外部依赖数据
    Run(A_AhkPath ' "' A_ScriptFullPath '"')
    ExitApp()
}
#Include %A_Temp%\WebView2.ahk
Persistent true ;阻止脚本自动退出
FileEncoding "UTF-8" ;读写文件编码设置
;DetectHiddenWindows  1 ;开启隐藏窗口检测,不要开,copilot检测不需要开启
;ProcessSetPriority "High" ;设置脚本高优先级
if  A_PtrSize=4 and A_args.length >0 and A_args[1]!=32 { ;判断当前操作系统版32位或者64位
  exepath:=A_AhkPath || A_WorkingDir . "ahk\ahk_install2\AutoHotkey32.exe"
  SplitPath  exepath,&f , &dir
  Run  Format('{1}\AutoHotkey32.exe "{2}" 32',dir,A_ScriptFullPath)
  ExitApp
}

if A_args.length=0 and
ak.getAdminAccess() ;获取管理员权限
CoordMode "Mouse","Screen"
OnMessage 0x0201,WM_LBUTTONDOWN
OnMessage 0x100 ,KEYBOARD_MESSAGE_CALLBACK ;键盘事件
OnMessage(0x404, AHK_NOTIFYICON) ;托盘点击事件
;.........................................
outDependData.syncCreateConfig() ;0.创建配置文件config.
outDependData.asyncUpdateInitScriptAhkBase64() ;0.1更新init脚本为当前最新
imageutil.changetrayIcon("icon1") ;①初始化图标
init.createTaskBarMenu() ;②.创建任务栏菜单
init.initAll()           ;③.初始化环境变量和文件夹
ak.seticonTip("翻译&ocr：ctrl+1",2) ;④.设置提示
init.onStartup()         ;⑤.设置缓存连接cmd等
linkManager.init()       ;⑥.注册链接管理右键菜单
;.........................................

onExit onExitApp ;退出时执行
OnClipboardChange ClipChanged ;监听剪切板

;==========================================================================================================系统快捷键映射
;测试向上的快捷键ctrl+I
$^i::{
    Send "{Up}"
    return
}
;测试向下的快捷键ctrl+K
$^k::{
    Send "{Down}"
    return
}
;测试向左移动的快捷键 ctrl+J
$^j::{
    Send "{left}"
    return
}
;测试项右的快捷键 Ctrl+L
$^l::{
    Send "{right}"
    return
}
;测试跳转到行首的快捷键 Ctrl+Q
$^q::{
    Send "{home}"
    return
}
;测试跳转到行尾的快捷键 Ctrl+E
$^e::{
    Send "{end}"
    return
}
;测试选中向前的的所有文本 Ctrl+Shift+Q
$^+q::{
    Send "+{home}"
    return
}
;测试选中向后的所有文本 Ctrl+Shift+E
$^+e::{
    Send "+{end}"
    return
}
;测试向前选中一个单词Ctrl+Shift+J
$^+j::{
    Send "^+{left}"
    return
}
;测试向后选中一个单词Ctrl+Shift+L
$^+l::{
    Send "^+{right}"
    return
}
;向上选中Ctrl+Shift+i
$^+i::{
    Send  "+{up}"
    return
}
;向下选中Ctrl+Shift+K
$^+k::{
    Send "+{down}"
    return
}
;跳转到下一行 Shift+Enter
$+Enter::{
    send "{end}{Enter}"
    return
}
;改写那个idea的Alt insert 为 alt+i
$!i::{
    Send "!{insert}"
    return
}
;用于选中该单词，就是模拟双击事件
$^u::{
    send "^+!{F1}"
    return
}
;试选中单行的所有文本  Ctrl+Shift+W
$^+w::{
    Send "{end}+{home}"
    return
}
;删除一个字符串 Ctrl+Shift+BackSpace
$^+BS::{
    send "^+{left}{BS}"
    return
}
;如果是图片直接粘贴到当前文件夹 ctrl+v
~^v::{
    cliphis.pastpng2dir()
    return
}
;复制文件路径 ctrl+shift+c
~^+c::{
    cliphis.copyFilePath2Clip()
    return
}
;删除当前选中 ctrl+shift+d
$^+d::{
    send "{DEL}"
    return
}
;shift+F2 打开应用声音 win11新功能
$+F2::{
    send "^#v"
    return
}
;win+s键打开设置 win11新功能
$#S::{
    Run "ms-settings: --user admin"
    return
}
;打开sticky note
~$#space::{
    if WinExist("Sticky Notes (new)"){
      for hwnd in WinGetList("Sticky Notes (new)")
          WinClose(hwnd)
    }else
        send "#!s"
    return
}
;用ESC关闭sticky note
~ESC::{
    for hwnd in WinGetList("Sticky Notes (new)")
        WinClose(hwnd)
   return
}
;RButton+向上滚轮 滚轮上调音量
~WheelUp::{
    if GetKeyState("RButton", "P")
        Send "{Volume_Up 1}"
    return
}
;RButton+向下滚轮 滚轮下降音量
~WheelDown::{
    if GetKeyState("RButton", "P")
        Send "{Volume_down 1}"
    return
}

;用ctrl+shift+m 转换驼峰命名和下划线命名
$^+m::{
    try{
       ak.camelCaseString()
    }catch as e{
       log("驼峰下划线转换异常",e)
    }
   return
}

; 定义鼠标左键LButton三击检测,切换桌面
~LButton::
{
   ;任务1： 检测SoPY_Status窗口三击p
   static clickCount := 0
   static lastClickTime := 0
   currentTime := A_TickCount
   ; 如果是第一次点击，直接初始化
   if (lastClickTime = 0) {
       clickCount := 1
   } else if (currentTime - lastClickTime < 500) {
       clickCount += 1
   } else {
       clickCount := 1
   }
   lastClickTime := currentTime
   ; 三击时检测窗口类
   if (clickCount = 3) {
       MouseGetPos(, , &winId)
       winClass := WinGetClass(winId)
       if (winClass = "SoPY_Status") {
          currentNo := ak.GetCurrentDesktopNumber()
          if (currentNo = 1) {
                Send("^#{Right}")
          } else if (currentNo=2) {
              Send("^#{Left}")
          } else {
              Loop 5 {
                  Send("^#{Left}")
              }
          }
       }
       clickCount := 0
       lastClickTime := 0
   }
}

;;选中字符串大写或者是小写 ctrl+shift+up
#hotif not init.stringCaseConfigExe()
$^+U::{
   try{
       ak.upLowCaseString()
    }catch as e{
       log("字符串大小写转换异常",e)
    }
   return
}

#hotif
;;向下复制一行ctrl+alt+down
#hotif not init.copyLineConfigExe()
$^!down::{
   try{
      ak.copyNewLineDown()
   }catch as e{
      log("向下复制行异常",e)
   }
   return
}
#hotif

;重新使任务栏透明
~LWin::
~RWin::{
    sleep 300
    ak.transparentTaskBar()
    return
}
;显示spy信息到记事本,或者是打开鼠标选中链接
~Mbutton::{
    if init.spymod
        runbox.showSpyCmd()
    else
        cliphis.runCopyLink()
    return
}
;Ctrl+Tab 映射chrome插件Popup Tab Switcher 快捷键Ctrl+Y
;要设置控件不关闭，并且下面y使用小写！
#HotIf  winActive("ahk_exe chrome.exe") || winActive("ahk_exe msedge.exe")
$^Tab::{
  if GetKeyState("Ctrl")
      send "^y"
}
#HotIf
;ctrl+shift+v dbeaver中转换选中的列为in 里面的条件
#HotIf  winActive("ahk_exe dbeaver.exe") || winActive("ahk_exe datagrip64.exe")
$^+v::{
  strArr:=[]
  clip:=A_Clipboard
  if  inStr(trim(clip),"('")=1
    return
  Loop Parse, clip ,(ak.strEndWith(trim(clip),"|") ?"|" :"`n" ){
      currentLine :=Trim(Trim(A_LoopField),'`r`n')
      if not ak.arrHas(strArr,currentLine) and currentLine !=""{
          strArr.push(currentLine)
      }
  }
  caseA:=  ak.joinArr(strArr,",","","")
  caseB:= strArr.length<=2 ? ak.joinArr(strArr,  "," , '(' ,')' ,"'") : ak.joinArr(strArr,  ",`n" , '(' ,')' ,"'")
  A_Clipboard:=ak.strEndWith(trim(clip),"|") ? caseA : (caseB . ";")
  sleep 50
  send "^v"
}
#HotIf
;ctrl+shift+v 数据库中的字段转为goland的struct
#HotIf  winActive("ahk_exe goland64.exe")
$^+v::{
    strArr:=[""]
    clip:=A_Clipboard
    if  not inStr(trim(clip),"|")
      return
    Loop Parse, clip ,(inStr(clip,"|") ?"|" :"`n" ){
        currentLine :=Trim(Trim(A_LoopField),'`r`n')
        if not ak.arrHas(strArr,currentLine) and currentLine !=""{
            fieldType :=" string"
            if ak.arrHas(["created_at","updated_at"],currentLine){
                fieldType:=" time.Time"
            }
            strArr.push( RegExReplace(ak.underlineCamelConvert(currentLine), "(\b\w)", "$U1") . fieldType . ' ``json:"' . currentLine . '"``' )
        }
    }
    caseA:= ak.joinArr(strArr,"`n","","")
    A_Clipboard:=caseA ;ctrl+shift+v dbeaver中转换选中的列为in 里面的条件 String
    sleep 50
    send "^v"
}
#HotIf
;快速生成QQ邮箱
::?qqmail::tmzcloud@qq.com

;快速生成@@邮箱2
::?qqmail2::1321284045@qq.com

;快速生成手机号码
::?hm::15520497580

;快速生成163邮箱
::?163mail::15520497580@163.com

;生成JS的onload
::?onload::window.onload=function(){{}{enter}

;用于生成oracle的日期
::todate::TO_DATE('xxxxx','YYYY-MM-DD HH24:MI:SS')

;用于生成oracle的日期
::to_date::{
    sj:=A_YYYY "-" A_MM "-" A_DD " " A_Hour ":" A_Min ":" A_Sec
    SendInput Format("TO_DATE('{1}','YYYY-MM-DD HH24:MI:SS')",sj)
    return
}
::?sj::{
   SendInput A_YYYY "-" A_MM "-" A_DD " " A_Hour ":" A_Min ":" A_Sec
   return
}

;ctrl+1执行选中搜狗翻译，搜狗ocr操作
#MaxThreadsPerHotkey 10
^1::{
   try{
       if not ak.ConnectedToInternet(){ ;互联网没有连接
          throw Error("没有互联网连接")
       }
       if init.lbuttonupFlag and not init.readmod and not sogouocr.xbuttonpicPath ;快捷翻译判断
          return
       MouseGetPos &xpos, &ypos
       Tn4:=WinExist(loadgif.loadGuiTitle)?loadgif.loadGui.Destroy():"" ;开始删除动画
       Tn2:=WinExist(sogoutrans2.transResultTitle)?sogoutrans2.transGui.Destroy():"" ;开始删除翻译gui
       Tn3:=WinExist(sogouocr.html_title)?sogouocr.ocrgui.Destroy():"" ;开始删除ocr gui
       setTimer(()=>loadgif.show(xpos+5,ypos+5),-1)      ;开始异步加载动画
       setTimer(()=>loadgif.loadGui.Destroy(),-4000)     ;开始4s后关闭动画
       if  sogouocr.xbuttonpicPath {
           sleep 200
           sogouocr.showOcrResult()
       }else
          Tn1:=winActive(sogouocr.snipaste_title)? sogouocr.showOcrResult():sogoutrans2.showTransResult(xpos+20,ypos+25)
   }catch as e{
       log("翻译&ocr异常",e)
   }finally{
       init.lbuttonupFlag:=0
       sogouocr.xbuttonpicPath:=""
       T5:=loadgif.loadGui?loadgif.loadGui.Destroy():"" ;结束显示结果后关闭动画
   }
}
;鼠标弹起时执行操作
~LButton up::{
    try{
        if sogoutrans2.transGui{
           if (WinActive(sogoutrans2.transResultTitle)) ;为了能让鼠标在翻译界面操作
               return ;
           else
               sogoutrans2.transGui.Destroy()
        }
        if A_PriorHotkey="~LButton" and  A_TimeSincePriorHotkey>=500 and (init.readmod or init.ocrmod)  and init.lbuttonupFlag:=1 ;判断鼠标拖动事件执行阅读模式
            send "^1"
    }catch as e{
        log("鼠标弹起异常",e)
    }
}
;鼠标靠近手的辅助按键，不设置多线程
$XButton1::{
    if init.ocrmod{
       sogouocr.xbuttonpicPath:=Format("{1}\{2}_ocr_xbutton2.png",init.picPath ,ak.getTimeStr("-","_","-"))
       Run Format("{1}\{2} snip -o {3}",init.helpme2Path , init.snipastePath ,sogouocr.xbuttonpicPath)
    }else
        send "{XButton1}" ;恢复按键
}
#HotIf  winActive("运行") and winActive("ahk_class #32770")
#MaxThreadsPerHotkey 10
;在运行框中执行强大的计算功能，包括数学运算等
:*?:==::{
    try{
        rawText:=ControlGetText("Edit1","A") ;不会包含等号"100+100=="返回"100+100"
        fullResult:=runbox.calculateExpression(RTrim(rawText,"="))
        if fullResult{
            ControlsetText(fullResult,"Edit1","A")
        }
        ControlSend("{END}","Edit1","A")
    }catch as e{
        log("执行表达式异常",e)
    }
}
;在运行框中执行自定义命令,包括打开网页，打开文件夹，打开应用，自行自定义cmd命令
$ENTER::{
   try{
       ;解决当前搜狗输入法干扰，其他输入法需要加入这个判定
       if WinExist("ahk_class SoPY_Comp"){
           Send "{ENTER}"
           return
       }
       rawText:=ControlGetText("Edit1","A")
       T1:=runbox.runCmd(rawText)?"":Send("{ENTER}")
       T2:=WinExist("运行")?WinClose("运行"):""
   }catch as e{
        log("执行命令异常",e)
   }
}
#HotIf
;==========================================================================================================系统快捷键映射
;----------------------------------------------------------------------------------------------------------全局函数func
;[@func-A46687E52FCF472ABE87DD1DEB29177E]
ClipChanged(DataType)
{
    ;DataType 0：什么内容没有，1 txt内容，2：非文本的内容例如图片
    ;1 如果剪贴板中仅包含能以文本形式表示的内容 (这里也包含了从资源管理器窗口 复制的文件);
    ak.clipdataType:=DataType
    if DataType==1
        cliphis.recordetxt(A_clipboard,DataType)
    else if DataType==2
        cliphis.recordetxt(cliphis.recordepic(),DataType)
    return
}
;移动选框GUI
WM_LBUTTONDOWN(wParam, lParam, msg, hwnd){
    OnMessage 0x0201,WM_LBUTTONDOWN
    if(A_Cursor="Arrow")
        PostMessage  0xA1, 2
}
;托盘点击事件
AHK_NOTIFYICON(wParam, lParam, uMsg, hWnd)
{
    ;; 0x201单击 ,0x203双击 ,0x204 右键单击,0x206右键双击, 0x207滚轮单击，0x209滚轮双击
    ;; 脚本托盘图标单击与双击尽量不要同时启用
    if (lParam = 0x201){  ;鼠标左键单击脚本托盘图标
;        recent.show() ;暂不开启
    }
}

;搜狗ocr复制原文
srcCopyButton1_OnClick()
{
;    msgBox % SoGouOcr.result_source " :" SoGouOcr.result_trans
    A_Clipboard:=Trim(sogouocr.contentObj.contents,"`r`n")
    sogouocr.ocrgui.destroy()
}
;搜狗ocr复制翻译后
srcCopyButton2_OnClick()
{
    A_Clipboard:=Trim(sogouocr.contentObj.trans,"`r`n")
    sogouocr.ocrgui.destroy()
}
;搜狗ocr关闭窗口事件
exitBtn1_OnClick()
{
    sogouocr.ocrgui.destroy()
}
;响应键盘事件
KEYBOARD_MESSAGE_CALLBACK(wParam, lParam, msg, hwnd)
{
   if((wparam=13 || wparam=27) and sogoutrans2.transGui){ ;翻译窗口响应回车事件和esc事件
       sogoutrans2.transGui.destroy() ;翻译
    }
    if((wparam=13 || wparam=27) and sogouocr.ocrGui){ ;ocr窗口响应回车事件和esc事件
       sogouocr.ocrGui.destroy() ;ocr
    }
}

;程序退出时执行的代码,ExitReason:代码退出原因 ,ExitCode 退出码
onExitApp(ExitReason, ExitCode)
{
  if FileExist(loadgif.loadhtmlPath) ;清除tmp中文件，在脚本启动时重新生成
      fileDelete(loadgif.loadhtmlPath)
  imageutil.close() ;关闭gdi+
  init.KillExtraScripts() ;关闭打开过的ahk脚本
  return ;
}
;把html输出到桌面,一般用于调试
html(content,filename:="xxx.html",flag:=true)
{
   if not flag
        return
   T1:=FileExist(f:=A_desktop "\" filename)?fileDelete(f):""
   fileAppend content,f
}
;记录系统运行日志title：一个标题,e：Error对象
log(title,e)
{
    if init.sysPath and  FileExist(init.sysPath)=="D" ;日志文件夹
    {
        loop 100
            line.='-'
        line.=ak.getTimeStr("-"," ",":") . "[ " title " ]"
        line.= "`n"  . Format("Error: {1}`n{2}",e.Message,e.Stack)
        filePath:=init.sysPath . "\log_" . A_YYYY . "-" . A_MM . "-" . A_DD . ".txt"
        fileAppend(line,filePath)
    }
}
;记录run运行日志
runlog(title,content)
{
   if init.runPath and FileExist(init.runPath)=="D"{
       Loop 100
           line.="-"
       line.=ak.getTimeStr("-"," ",":") . "[" . title . "]"
       line.='`n' . content . "`n"
       filePath:=init.runPath . "\run_" . A_YYYY . "-" . A_MM . "-" . A_DD . ".txt"
       if fileExist(filePath){
            line.="`n" . fileRead(filePath)
            fileDelete(filePath)
       }
       fileAppend line ,filePath
   }
}
;----------------------------------------------------------------------------------------------------------外部依赖初始化 outDependData
class outDependData {
    ;检查 A_Temp 下是否已有 WebView2.ahk / WebView2Loader.dll，缺失则从 getResourceBase64 解码写出
    ;web_view2_ahk / web_view2_dll 已内嵌在 getResourceBase64 的 static obj 中，脚本自包含
    static init() {
        ahkB64 := getResourceBase64("web_view2_ahk")
        dllB64 := getResourceBase64("web_view2_dll")
        if ahkB64 != "" && ahkB64 != "xxxxx"
            if !FileExist(A_Temp "\WebView2.ahk")
                ak.createFileByBase64(ahkB64, A_Temp "\WebView2.ahk")
        if dllB64 != "" && dllB64 != "xxxxx"
            if !FileExist(A_Temp "\WebView2Loader.dll")
                ak.createFileByBase64(dllB64, A_Temp "\WebView2Loader.dll")

    }
    ;同步步执行
    static syncCreateConfig(){
        this._syncConfigs()
    }
    ;异步执行
    static asyncUpdateInitScriptAhkBase64(){
        setTimer ()=>this._updateInitScriptAhkBase64() ,-1
    }

    ;配置文件双向同步（以 HELPEME_HOME 环境变量为根目录，与脚本运行位置无关）
    ;- HELPEME_HOME\ahk\config\xxx.txt 不存在 → 解码脚本末尾变量 base64 → 写出文件
    ;- HELPEME_HOME\ahk\config\xxx.txt 已存在 → 编码文件 → 反向替换脚本末尾变量（重启后生效）
    static _syncConfigs() {
        helpmeHome := reg.getEnv(init.helpmeEnv)
        if helpmeHome = ""
            return
        configDir := helpmeHome . "\" . init.configDir
        for item in [["getconfig.txt","get_config_C11111"],["runconfig.txt","run_config_C22222"],["sysconfig.txt","sys_config_C33333"]] {
            filePath := configDir "\" item[1]
            varName  := item[2]
            curB64   := outDependData._readScriptVar(varName)
            if FileExist(filePath) {
                ;文件存在 → 编码后反向更新脚本变量
                newB64 := outDependData._encodeFileToBase64(filePath)
                if newB64 != "" && newB64 != curB64
                    outDependData._updateScriptVar(varName, newB64)
            } else if curB64 != "" && curB64 != "xxxxx" {
                ;文件不存在且变量有真实数据 → 解码写出
                DirCreate configDir
                ak.createFileByBase64(curB64, filePath)
            }
        }
    }

    ;从脚本源文件正则提取 varName:="value" 的值（直接读文件，不依赖变量执行顺序）
    static _readScriptVar(varName) {
        if RegExMatch(FileRead(A_ScriptFullPath), varName '\s*:=\s*"([^"]*)"', &m)
            return m[1]
        return ""
    }

    ;将文件原始字节编码为单行 base64，直接复用 ak.getBase64
    static _encodeFileToBase64(path) {
        return ak.getBase64(path)
    }

    ;用正则定位匹配范围，再做字符串整体替换，更新脚本末尾的 varName:="value"
    static _updateScriptVar(varName, newB64) {
        path       := A_ScriptFullPath
        content    := FileRead(path)
        newContent := RegExReplace(content
            , varName '\s*:=\s*"[^"]*"'
            , varName ':="' newB64 '"')
        if newContent = content
            return
        f := FileOpen(path, "w")
        f.Write(newContent)
        f.Close()
    }

    ;核心逻辑：检测并替换 init / init.ps1 中的变量
    static _updateInitScriptAhkBase64() {
        ; 获取当前脚本的 Base64 字符串
        base64Data := ak.getBase64(A_ScriptFullPath)
        if (base64Data = "") {
            return
        }
        ; 寻找目标 init 或 init.ps1 文件
        targetPath := ""
        possibleFiles := [A_ScriptDir "\init.ps1", A_ScriptDir "\init"]
        for filePath in possibleFiles {
            if FileExist(filePath) {
                targetPath := filePath
                break
            }
        }
        ; 如果没找到目标文件，提示并退出
        if (targetPath = "") {
            return
        }
        ; 读取目标文件内容
        try {
            content := FileRead(targetPath, "UTF-8")
        } catch {
            return
        }
        ; 替换变量内容
        ; 这里的正则支持替换类似: $ahk_kjj4_script_A22222 = 'xxx' 或 $ahk_kjj4_script_A22222 = "xxx"
        targetVar := "$ahk_kjj4_script_A22222"
        if !InStr(content, targetVar) {
            return
        }
       ; 修改点：外层改用双引号，内部的单引号不需要连续写两个，完美避免 AHK 转义歧义
       regexPattern := "(`\$ahk_kjj4_script_A22222\s*=\s*)([`"'])(.*?)([`"'])"
       replacement  := "${1}" . '"' . base64Data . '"'
       newContent   := RegExReplace(content, regexPattern, replacement)
        ; 以带有 BOM 的 UTF-8 编码写回文件（避免 PS 运行时遇到中文乱码）
        try {
            if FileExist(targetPath)
                FileDelete(targetPath)
            f := FileOpen(targetPath, "w", "UTF-8")
            f.Write(newContent)
            f.Close()
        } catch Error as err {
            MsgBox("写入文件时发生错误: " err.Message, "错误", 48)
        }
    }
}
;[@getIco-CB747C07A3FB4A31B5FCBE475DE40C85]
;获取资源的 base64 编码（ico/ahk/dll 等外部依赖均注册于此；用 ak.Base64EncodeFile 生成 web_view2_* 填入）
getResourceBase64(resName)
{
    static obj:={
       ;加载动画 gif
       loadGif:"
               ( LTrim Join
                 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AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
                )"
       ;初始图标[托盘] ico
      ,icon1:"
              ( LTrim Join
                iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAACXBIWXMAAA7EAAAOxAGVKw4bAAACUklEQVQ4y22Ry2udVRTFf2ufcxMfoCDqQB35aFUwtCLOJOrEuVikKE5Do6DoyL9ArFMNhYsTxYEiDkQQFEQLFoSqVWIkCKIdFNHUZ9Le3PudvRx83y3RZsGGs89Ze5+19hYD3rn7CLfmzVWmqpF/lsn04c0TAHywdIxbLl6xYBOdW/f91X90T337JgACOH3wWF306Mma5WnMAcPvKb/XjfKlJHOxqy9Wx6O2r0/8YyvttVltb9y7sTbVqdtW4poYvbxAfb64hiwwNJIseabhbsFxXzgASExTy065dlGzZ+tVpT5YXZ4r1CguhIUNIZGpQxUoFGQhIEmEQtlWXfRhrY6VolpLBpHqiRZIhGKYUK9KFiFwCFCMnCt1RCyFhXIIhqLBiodBieHsoDhBopilSEjNGRJ7IUxgsPfc9VHoLUXDZ2wPPxn+1wKEhsZzFSnTlOyW7qtI57iRmTIZiZWXtZnDGEeSMl10+U/dHUeLPNnR3k11ZPQE1CvyXLqHYvXvLRo7dfb++dj+SABf37F605Uafbbgenu4EBmoBZeE2xDGSrpo7NTdn86PJsvL6+OzAXD4h7VzM7WjM+UvVvZWSi+1l21SSaoxKdOt7bL7xPL6+Cww3xncs/nq6d3SHp+q+zXVyGgQiaPh6PPtOt36rV44+tb0k1PzurJ3SDduffHzwRvuPyl4JNC1KV3yvVNn5/6uk8c+5vNPj29u/mdPl+GbO585sNjq25U4BHChzDb+KpMjD3w33mCfRe+LL+9ava64vjJTq9tl8sJD669v7cf7FyA9OlKNwUFpAAAAAElFTkSuQmCC
               )"
       ;有网络时的图标 ico
      ,icon2:"
              ( LTrim Join
                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
               )"
       ;鼠标右键recent ico
       ,icon2RC:"
              ( LTrim Join
                AAABAAEAEBAAAAEAIABoBAAAFgAAACgAAAAQAAAAIAAAAAEAIAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAB4INcIeSPTzXki1HJ4INcEeSLUg3ki1K15IdUSeSLURnoj09t5IdUkAAAAAAAAAAAAAAAAAAAAAAAAAAB5IdUkeSLVSHoj1P95I9SxeSLVRHki1MN6I9TZeiPUWHki1Id6I9T/eiPUcHkh1SQAAAAAAAAAAAAAAAB6ItUceiPU/3oj1P96I9P/eiPT/3oj0/96I9P/eiPT/3oj0/96I9P/eiPT/3oj1P96I9T/eyPTOAAAAAB6ItUceiPUSHoi1P96ItT/eiPT/3oj0/96I9P/eiPT/3oj0/96I9P/eiPT/3oj0/96I9T/eiPU/3oi1HB8JNMOeSPTzXoj1P96I9T/eiPU/4Ev1v+TTdz/eiPU/4g72P+MQdr/eiPU/3oj1P96I9T/eiPU/3oj1P96I9T/eiPU6Xki1EZ5ItSVeiPU/3oj1P+XU93/3cf0/3oj1P+teOT/wJbq/3oj1P96I9T/eiPU/3oj1P96I9T/eiPTq3oj01x6ItUOeyPTOHoj1P96I9T/mVbe/+bW9/96I9T/rXjk/9a78v+FNdf/eiPU/3oj1P96I9T/eiPU/3oi1GJ8JNMIeSLUnXoj1Md6I9T/eiPU/4o+2f/fyvX/qnLj/4xB2f/dyPT/z6/v/4g72P96I9T/eiPU/3oj1P96I9PVeiPTsXki1IN5ItTJeiPU/3oj1P96I9T/iDvY/+bX9//QsvD/jEHa/8CX6v/j0fb/jkTa/3oj1P96I9T/eiPT1Xoj06N4INcEeiLUPHoj1P96I9T/eiPU/3oj1P+ORNr/2L7y/7iK6P99KdX/28Tz/6Rp4f96I9T/eiPU/3oi1GJ8JNMIeSLUYnoj1I96I9T/eiPU/3oj1P96I9T/eiPU/6py4//Alur/eiPU/8mm7f+gY+D/eiPU/3oj1P96I9OreiPTXHkj1Md6I9T/eiPU/3oj1P96I9T/eiPU/3oj1P+FNdf/jEHa/3oj1P+ORNr/gzLX/3oj1P96I9T/eiPU/3oj1Ol4INcIeiLUTnoi1P96ItT/eiPT/3oj0/96I9P/eiPT/3oj0/96I9P/eiPT/3oj0/96I9T/eiPU/3oi1HB8JNMOAAAAAHwk0w56I9TxeiPU/3oj0/96I9P/eiPT/3oj0/96I9P/eiPT/3oj0/96I9P/eiPU/3oj1P97I9M4AAAAAAAAAAAAAAAAeSHVJHoi1U56I9T/eSPUsXoi1EZ6ItTHeiPU2Xoj1Fh6ItSNeiPU/3oj1HB7I9MyAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAeSPT23oj04EAAAAAeSPUjXoj07V7I9MYeSPURnkj1ON7I9MyAAAAAAAAAAAAAAAA9m8AAPJPAADAAwAAwAMAAAAAAACAAQAAwAMAAAAAAAAAAAAAwAMAAIABAAAAAAAAwAMAAMADAADyTwAA8m8AAA==
              )"
       ;暂停时图标 ico
      ,icon3:"
              ( LTrim Join
                iVBORw0KGgoAAAANSUhEUgAAABgAAAAYCAYAAADgdz34AAAACXBIWXMAAAsTAAALEwEAmpwYAAAKTWlDQ1BQaG90b3Nob3AgSUNDIHByb2ZpbGUAAHjanVN3WJP3Fj7f92UPVkLY8LGXbIEAIiOsCMgQWaIQkgBhhBASQMWFiApWFBURnEhVxILVCkidiOKgKLhnQYqIWotVXDjuH9yntX167+3t+9f7vOec5/zOec8PgBESJpHmomoAOVKFPDrYH49PSMTJvYACFUjgBCAQ5svCZwXFAADwA3l4fnSwP/wBr28AAgBw1S4kEsfh/4O6UCZXACCRAOAiEucLAZBSAMguVMgUAMgYALBTs2QKAJQAAGx5fEIiAKoNAOz0ST4FANipk9wXANiiHKkIAI0BAJkoRyQCQLsAYFWBUiwCwMIAoKxAIi4EwK4BgFm2MkcCgL0FAHaOWJAPQGAAgJlCLMwAIDgCAEMeE80DIEwDoDDSv+CpX3CFuEgBAMDLlc2XS9IzFLiV0Bp38vDg4iHiwmyxQmEXKRBmCeQinJebIxNI5wNMzgwAABr50cH+OD+Q5+bk4eZm52zv9MWi/mvwbyI+IfHf/ryMAgQAEE7P79pf5eXWA3DHAbB1v2upWwDaVgBo3/ldM9sJoFoK0Hr5i3k4/EAenqFQyDwdHAoLC+0lYqG9MOOLPv8z4W/gi372/EAe/tt68ABxmkCZrcCjg/1xYW52rlKO58sEQjFu9+cj/seFf/2OKdHiNLFcLBWK8ViJuFAiTcd5uVKRRCHJleIS6X8y8R+W/QmTdw0ArIZPwE62B7XLbMB+7gECiw5Y0nYAQH7zLYwaC5EAEGc0Mnn3AACTv/mPQCsBAM2XpOMAALzoGFyolBdMxggAAESggSqwQQcMwRSswA6cwR28wBcCYQZEQAwkwDwQQgbkgBwKoRiWQRlUwDrYBLWwAxqgEZrhELTBMTgN5+ASXIHrcBcGYBiewhi8hgkEQcgIE2EhOogRYo7YIs4IF5mOBCJhSDSSgKQg6YgUUSLFyHKkAqlCapFdSCPyLXIUOY1cQPqQ28ggMor8irxHMZSBslED1AJ1QLmoHxqKxqBz0XQ0D12AlqJr0Rq0Hj2AtqKn0UvodXQAfYqOY4DRMQ5mjNlhXIyHRWCJWBomxxZj5Vg1Vo81Yx1YN3YVG8CeYe8IJAKLgBPsCF6EEMJsgpCQR1hMWEOoJewjtBK6CFcJg4Qxwicik6hPtCV6EvnEeGI6sZBYRqwm7iEeIZ4lXicOE1+TSCQOyZLkTgohJZAySQtJa0jbSC2kU6Q+0hBpnEwm65Btyd7kCLKArCCXkbeQD5BPkvvJw+S3FDrFiOJMCaIkUqSUEko1ZT/lBKWfMkKZoKpRzame1AiqiDqfWkltoHZQL1OHqRM0dZolzZsWQ8ukLaPV0JppZ2n3aC/pdLoJ3YMeRZfQl9Jr6Afp5+mD9HcMDYYNg8dIYigZaxl7GacYtxkvmUymBdOXmchUMNcyG5lnmA+Yb1VYKvYqfBWRyhKVOpVWlX6V56pUVXNVP9V5qgtUq1UPq15WfaZGVbNQ46kJ1Bar1akdVbupNq7OUndSj1DPUV+jvl/9gvpjDbKGhUaghkijVGO3xhmNIRbGMmXxWELWclYD6yxrmE1iW7L57Ex2Bfsbdi97TFNDc6pmrGaRZp3mcc0BDsax4PA52ZxKziHODc57LQMtPy2x1mqtZq1+rTfaetq+2mLtcu0W7eva73VwnUCdLJ31Om0693UJuja6UbqFutt1z+o+02PreekJ9cr1Dund0Uf1bfSj9Rfq79bv0R83MDQINpAZbDE4Y/DMkGPoa5hpuNHwhOGoEctoupHEaKPRSaMnuCbuh2fjNXgXPmasbxxirDTeZdxrPGFiaTLbpMSkxeS+Kc2Ua5pmutG003TMzMgs3KzYrMnsjjnVnGueYb7ZvNv8jYWlRZzFSos2i8eW2pZ8ywWWTZb3rJhWPlZ5VvVW16xJ1lzrLOtt1ldsUBtXmwybOpvLtqitm63Edptt3xTiFI8p0in1U27aMez87ArsmuwG7Tn2YfYl9m32zx3MHBId1jt0O3xydHXMdmxwvOuk4TTDqcSpw+lXZxtnoXOd8zUXpkuQyxKXdpcXU22niqdun3rLleUa7rrStdP1o5u7m9yt2W3U3cw9xX2r+00umxvJXcM970H08PdY4nHM452nm6fC85DnL152Xlle+70eT7OcJp7WMG3I28Rb4L3Le2A6Pj1l+s7pAz7GPgKfep+Hvqa+It89viN+1n6Zfgf8nvs7+sv9j/i/4XnyFvFOBWABwQHlAb2BGoGzA2sDHwSZBKUHNQWNBbsGLww+FUIMCQ1ZH3KTb8AX8hv5YzPcZyya0RXKCJ0VWhv6MMwmTB7WEY6GzwjfEH5vpvlM6cy2CIjgR2yIuB9pGZkX+X0UKSoyqi7qUbRTdHF09yzWrORZ+2e9jvGPqYy5O9tqtnJ2Z6xqbFJsY+ybuIC4qriBeIf4RfGXEnQTJAntieTE2MQ9ieNzAudsmjOc5JpUlnRjruXcorkX5unOy553PFk1WZB8OIWYEpeyP+WDIEJQLxhP5aduTR0T8oSbhU9FvqKNolGxt7hKPJLmnVaV9jjdO31D+miGT0Z1xjMJT1IreZEZkrkj801WRNberM/ZcdktOZSclJyjUg1plrQr1zC3KLdPZisrkw3keeZtyhuTh8r35CP5c/PbFWyFTNGjtFKuUA4WTC+oK3hbGFt4uEi9SFrUM99m/ur5IwuCFny9kLBQuLCz2Lh4WfHgIr9FuxYji1MXdy4xXVK6ZHhp8NJ9y2jLspb9UOJYUlXyannc8o5Sg9KlpUMrglc0lamUycturvRauWMVYZVkVe9ql9VbVn8qF5VfrHCsqK74sEa45uJXTl/VfPV5bdra3kq3yu3rSOuk626s91m/r0q9akHV0IbwDa0b8Y3lG19tSt50oXpq9Y7NtM3KzQM1YTXtW8y2rNvyoTaj9nqdf13LVv2tq7e+2Sba1r/dd3vzDoMdFTve75TsvLUreFdrvUV99W7S7oLdjxpiG7q/5n7duEd3T8Wej3ulewf2Re/ranRvbNyvv7+yCW1SNo0eSDpw5ZuAb9qb7Zp3tXBaKg7CQeXBJ9+mfHvjUOihzsPcw83fmX+39QjrSHkr0jq/dawto22gPaG97+iMo50dXh1Hvrf/fu8x42N1xzWPV56gnSg98fnkgpPjp2Snnp1OPz3Umdx590z8mWtdUV29Z0PPnj8XdO5Mt1/3yfPe549d8Lxw9CL3Ytslt0utPa49R35w/eFIr1tv62X3y+1XPK509E3rO9Hv03/6asDVc9f41y5dn3m978bsG7duJt0cuCW69fh29u0XdwruTNxdeo94r/y+2v3qB/oP6n+0/rFlwG3g+GDAYM/DWQ/vDgmHnv6U/9OH4dJHzEfVI0YjjY+dHx8bDRq98mTOk+GnsqcTz8p+Vv9563Or59/94vtLz1j82PAL+YvPv655qfNy76uprzrHI8cfvM55PfGm/K3O233vuO+638e9H5ko/ED+UPPR+mPHp9BP9z7nfP78L/eE8/sl0p8zAAAAIGNIUk0AAHolAACAgwAA+f8AAIDpAAB1MAAA6mAAADqYAAAXb5JfxUYAAAG9SURBVHjarJU/T8JQFMV/96Uh2hgw0dVaJl0kcVYjDk5+BBdY/SJ+DFmYdXAXoszOTFbmJobENA5NnwP9By3lgZ6lvSftPfe+89678vV4zzwiEAF4AVy0dIEBos24BViUQQS0bseC7oxTZhyqUsAF2sBhJqYu0RFrcF6+E/l6ugedRPojFvkbtFwlIvl+2kly2Shr7i/FZVxwKuCmJFlDa5adf02WGgt4QHRnw6xFDQHQHYQO4CnQxmtec1rYpzdL4zIotHTRcoXW3VUC1t4B1n62cdR2nZrTKvOjFxvdVNm2Ut5KgVzyFX572S6SosnFxA716zuU3eBn/Dar3m5Qc1pEwbTMC3OTrX2HnbNbAL5HfUJ/UuBKFFKTrSqTk0ShPyF4fyYKpmwdnbN1fEHoT/gZvxL6k6rFcitNrh2cEAVTvkf9QvKkmyUmJCZLpcnK3l2IG6ngv5q8wYEzMzn0P1F2I5sUwZTQ/zRRMDM52ZLLYhOsdZLNL9QVJ/nP1/WcyRm8f7uuI4bx4JkbmR5amhC147n8kLUbDc05NcgXuziTPaAHyk0rmiVag1s0uRweSG/2VIP4M1NuDr8DAIPC4J/n43+qAAAAAElFTkSuQmCC
               )"
       ;任务栏菜单-调试图标 ico
      ,debug:"
              ( LTrim Join
                iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAAAXNSR0IArs4c6QAAAQtJREFUOE+1k1FOwkAQhv/Z4jvBA1ATS+IpLCeRPhYPoRxC+kg9ib2FCZi4F7DwDu5v1qRlW3aJCXEfZzLf/PPvjODCJxfWIwgYFu+xwuDBNqjzZBFqFASMlhsei6jr+eTGB/EChsUmVeTKLTAi2S5Pqj6kA7CygUGsgHtfN4PDq43v8jvd5DuA0XL9CUh81liRss5vMy/g+mU9o0hHeh9mBFN3lFbBcW5XAfWpImrXDwdgv+3qCeSslUdmVDIG8dwqESkN9ovGh44H/RHEA7Cxr8dJ6Tex+FiBJm1knwKoIaoKmmipvxvI6M1CXACBajtPpmf3oElaSGSi9FuJjgxj60Nonf/vmP56pT/gAXERCNO6rgAAAABJRU5ErkJggg==
               )"
       ;任务栏菜单-退出按钮 ico
      ,exit:"
              ( LTrim Join
                iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAAAXNSR0IArs4c6QAAAUtJREFUOE+NU0FShDAQ7IF9CCsna/ENsi/Z5RfKRayy0F8svmTxD2x5Ec1DJGMNkBgCUuY2k0mnp6eH4J336C7SQXBg4hSgFIACUBNDBVq/XqsXie0hN7hc5Q9MKHxQJ1bEqHaf5aPJWYAmvj+PP668N1dcJ+3zXqIe4BLnRwZOCy8N3ci/I0YhTEh67sLgyyuQhxEBmeT/Ag87vad53wO9Js5PBLwNAHwIO866MDgLsO2fUZAUAjiaZNjprQ6DVH51GQhlmcKULdcCIPQtatKWNue1oJK23Hr1ygOw9HlkNBHRBbdteOMbf1kcaZW0ZdbEuQEXjGomotOrK5gSxQeH/hpNapfG2LtNBPvebHptbj6e6iWviOBrRrI7wNRPaWImEXjXlpVj5ek41/3sWdkU/2OZYCw8WyaT6Nd5MNItAFln8aIipnppnX8AVl3BDg87bxYAAAAASUVORK5CYII=
               )"
       ;任务栏菜单-重启按钮 ico
      ,reload:"
              ( LTrim Join
                iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAAAXNSR0IArs4c6QAAAP1JREFUOE+lklFugzAQRJ/FRUCl5+jmJE1u4T/Cn28BN4nvUSLoQVpHazBNWyTc1H+WvM+zM2P45zFp3g4yAmW8G87uybc57C/AVRoC58cBg1wAiYDAwT17n63AvolguLjaG3uVZk++HaTDMOm7uELc39DvDd751alfrvaHBAh/kW0HOQIdBZWxo5R8MOrFVX7K2XtRHT99CLB+qoDVA2hd7fscBWq0Rq6mJ0A0hYJTzhpL6XC1r2bAHKNGs5tEjBCOybOtJvYUtFtKknTglNZdAYsXGk+z+OC1LATegZelpeXPuL8BIkRj/eSVEGs9Vxu01tOWsl+AnBTu39wA3RqBbuSKGVwAAAAASUVORK5CYII=
               )"
       ;任务栏菜单-暂停 ico
      ,suspend:"
              ( LTrim Join
                iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAAAXNSR0IArs4c6QAAAFtJREFUOE9jZKAQMCLrf98u4MDEwBQPEmNkYDzIV/l2AYiNSxyiDgl8bBeaz8DAkAAVWsBf+S4RxMYlPmoAJKRGA3H4hQFypvnH8G+hYOWHA+iZCVkcIx2Qk7MB2cyQEWXj+ecAAAAASUVORK5CYII=
               )"
       ;任务栏菜单-自定义spy工具 ico
      ,spy1:"
              ( LTrim Join
                iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAAAXNSR0IArs4c6QAAAO9JREFUOE+lk7FOwzAQhv9DcegbIOKILrSNEYgH4UGYMnSnW5GYGXkOuvcRUDuYDAgJFPMGIBmaQ5aaCEdBchtv9vn/7u73mdBzUU89OgHSqikzrkGYbBO8gvjBiOe7dkIPkPJYVt8HC4AuuypjxgvF1ZWhoqjjHiCx2dN/4lrgIB+xHoHA7qwBJDbLAboP8YQIN6XQtx7g2KoVARchADDezKEetipQXwAGQQAARugIhM2fFnYFHAnQ8qcBSKvWDJwHVvBuYn3SauEsBzjUxFkp9NwDuE2vZ3QA+XmachQ97j1Idf97j3Kggd613r/xF5sPWBF3I2Z4AAAAAElFTkSuQmCC
               )"
       ;任务栏菜单-自带spy工具 ico
      ,spy2:"
              ( LTrim Join
                iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAAAXNSR0IArs4c6QAAAPdJREFUOE+tU9sRwjAMUyehnYRqEugkHJPQTRwmgVE45eyem+vjh/y0ZyuybDkdDo6ZvQB8ST73YN1Wwsx6ADcAd8/PAN4kS4tfEfhFVR1V2cHxVUwEE8mIoSX4+MUKMjMpuJKcErnUMUgWAjMzVVRmr99EsuAqgVeS9CHLO5iPlKpWCYIHgF5Sj1yJnKstcqczM11WrxpMDSag4pcmFnjBSiZQYN4gkFbZWI8XlCMa5pxbGI8GmFvzBRPxFARi1BAXe06cWA/RpdUFIjmcrPfK7rwH6qkmQ0l+C3mRcpGtVY43IFdEqqP/usrtnP77mNre81vYm8sPEdmQqTjrk9UAAAAASUVORK5CYII=
               )"
       ;任务栏菜单-阅读模式1 ico
      ,read1:"
              ( LTrim Join
                iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAAAXNSR0IArs4c6QAAALFJREFUOE/tk8ENwjAMRf+XOkg2ASYpHSKReoKeKnkJyiR0E8IgkZGl9tKacgCJC746ebKT94kPiyJyARA8TimlqaoqqOrJ65PsDKAkz6r6WBzaAdhP8MYB1ADyDDjEGMflIRG5kxxijJ3Ts8nxDnADcE0pDX/Ar96g7/vQtm32JJoE3P7GLcu/DlipXEoZ5/FF5LilstnmVSDZqKoFzbRdqW6W8tWe044Wpmyp87Jid59PwKDM0m+MAQAAAABJRU5ErkJggg==
               )"
       ;任务栏菜单-阅读模式2 ico
      ,read2:"
              ( LTrim Join
                iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAAAXNSR0IArs4c6QAAAMhJREFUOE/tk0sOgkAMhv8OHGQSVoZ4BvEkyi2EjZIY4i3Ak8AhMG58jPcQasZHYrDCQhM3znLa+dJ2vhI+PFR5cQawljhOzeHZdTVxPZfiTE5iAUyMBQin5yQGRgACAJqAsA1g8AQgcwUwqfFwtyzbSZUXH4mR+4c0EWKZvesBRAWB1v4+zf+AX81gq2d6YFZGkugmYM83dln+XYCksqqb8lH+xounHSpHhVwqaSYVKm40A3bhXlS3ltK7Pu89BgAbu3XSrti3F49wrlZvrESGAAAAAElFTkSuQmCC
               )"
       ;任务栏菜单-快捷ocr1 ico
      ,ocr1:"
              ( LTrim Join
                iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAAAXNSR0IArs4c6QAAALtJREFUOE/dk9ERgkAMRPc6kU7cSoRKgErUSpZOsBOd1RzjzSDg4Jf545Lb7JGXhJ2R8n1JLYAuvjuS/bu2pDOAGsANwCXnnwKRPDoB4ErSRUVIOsSB69xsINlkgRFAT9ICqyHJTlqSVRa4A6jmOs+phZuRZJqeYDurraMgBOzg9YQ98S8C5uCbnxjs1B77z8ZokBqSw5aJBEh2PXFgNE2X+TeiSyiforZA2Zw7kZfJy1KAtbhMW2x/qnkAeNFgEfPNxnIAAAAASUVORK5CYII=
               )"
       ;任务栏菜单-快捷ocr2 ico
      ,ocr2:"
              ( LTrim Join
                iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAAAXNSR0IArs4c6QAAAORJREFUOE/dU0sOgjAQfVMuArIy4B24iXALwwZITOMtxJtwCI0bES5Ca4aPGoKkBld2177pmzczbwgLDw3/L6s40YSU76SReneZvXOf3fgIIARQk0Y+4C1BDwYMCKVO6/pQj4Vd7Z3Nb8oSgQYSAIVfymggqAjIvFLmJhVd3DhkEr+UzkCgrUY5U5mnCFlNY4nKLyU9S2A5Jtk5pidgBV0JS86/ELAPvmki94xHyWP/2RgrTSLa3PaFyUR6I7Hqzgf9HoTsRtGoYtbKQmw1tTvxsjIbQ3VAu0wA8nFPZpfJRPanmAdCHXoRcPaWYwAAAABJRU5ErkJggg==
               )"
      ;web2 的 ahk 包（WebView2.ahk base64）
      ,web_view2_ahk:"
              ( LTrim Join
                LyoqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKg0KICogQGRlc2NyaXB0aW9uIFVzZSBNaWNyb3NvZnQgRWRnZSBXZWJWaWV3MiBjb250cm9sIGluIGFoay4NCiAqIEBhdXRob3IgdGhxYnkNCiAqIEBkYXRlIDIwMjUvMDQvMjkNCiAqIEB2ZXJzaW9uIDIuMC41DQogKiBAd2VidmlldzJ2ZXJzaW9uIDEuMC4yOTAzLjQwDQogKiBAc2VlIHtAbGluayBodHRwczovL3d3dy5udWdldC5vcmcvcGFja2FnZXMvTWljcm9zb2Z0LldlYi5XZWJWaWV3Mi8gbnVnZXQgcGFja2FnZX0NCiAqIEBzZWUge0BsaW5rIGh0dHBzOi8vbGVhcm4ubWljcm9zb2Z0LmNvbS9lbi11cy9taWNyb3NvZnQtZWRnZS93ZWJ2aWV3Mi9yZWZlcmVuY2Uvd2luMzIvIEFQSSBSZWZlcmVuY2V9DQogKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKiovDQpjbGFzcyBXZWJWaWV3MiB7DQoJc3RhdGljIGNyZWF0ZShod25kIDo9IC0zLCBjYWxsYmFjaz8sIGNyZWF0ZWRFbnZpcm9ubWVudCA6PSAwLCBkYXRhRGlyIDo9ICcnLCBlZGdlUnVudGltZSA6PSAnJywgb3B0aW9ucyA6PSAwLCBkbGxQYXRoT3JGdW5jUHRyIDo9ICdXZWJWaWV3MkxvYWRlci5kbGwnKSB7DQoJCXAgOj0gY3JlYXRlZEVudmlyb25tZW50ID8gY3JlYXRlZEVudmlyb25tZW50LkNyZWF0ZUNvcmVXZWJWaWV3MkNvbnRyb2xsZXJBc3luYyhod25kKSA6DQoJCQl0aGlzLkNyZWF0ZUNvbnRyb2xsZXJBc3luYyhod25kLCBvcHRpb25zLCBkYXRhRGlyLCBlZGdlUnVudGltZSwgZGxsUGF0aE9yRnVuY1B0cikNCgkJaWYgIUlzU2V0KGNhbGxiYWNrKQ0KCQkJcmV0dXJuIHAuYXdhaXQoKQ0KCQlwLnRoZW4oY2FsbGJhY2spDQoJfQ0KCS8qKg0KCSAqIGNyZWF0ZSBFZGdlIFdlYlZpZXcyIGNvbnRyb2wuDQoJICogQHBhcmFtIHtJbnRlZ2VyfSBod25kIHRoZSBod25kIG9mIEd1aSBvciBDb250cm9sLg0KCSAqIEBwYXJhbSB7JERpclBhdGh9IGRhdGFEaXIgVXNlciBkYXRhIGZvbGRlci4NCgkgKiBAcGFyYW0geyREaXJQYXRofSBlZGdlUnVudGltZSBUaGUgcGF0aCBvZiBFZGdlIFJ1bnRpbWUgb3IgRWRnZShkZXYuLikgQmluLg0KCSAqIEBwYXJhbSB7V2ViVmlldzIuRW52aXJvbm1lbnRPcHRpb25zfSBvcHRpb25zIFRoZSBlbnZpcm9ubWVudCBvcHRpb25zIG9mIEVkZ2UuDQoJICogQHBhcmFtIHskRmlsZVBhdGggfCBJbnRlZ2VyfSBkbGxQYXRoT3JGdW5jUHRyIFRoZSBwYXRoIG9mIGBXZWJWaWV3MkxvYWRlci5kbGxgIG9yIGZ1bmN0aW9uIGFkZHJlc3Mgb2YgYENyZWF0ZUNvcmVXZWJWaWV3MkVudmlyb25tZW50V2l0aE9wdGlvbnNgLg0KCSAqIEByZXR1cm5zIHtQcm9taXNlPFdlYlZpZXcyLkNvbnRyb2xsZXI+fQ0KCSAqLw0KCXN0YXRpYyBDcmVhdGVDb250cm9sbGVyQXN5bmMoaHduZCA6PSAtMywgb3B0aW9ucyA6PSAwLCBkYXRhRGlyIDo9ICcnLCBlZGdlUnVudGltZSA6PSAnJywgZGxsUGF0aE9yRnVuY1B0ciA6PSAnV2ViVmlldzJMb2FkZXIuZGxsJykgew0KCQlyZXR1cm4gdGhpcy5DcmVhdGVFbnZpcm9ubWVudEFzeW5jKG9wdGlvbnMsIGRhdGFEaXIsIGVkZ2VSdW50aW1lLCBkbGxQYXRoT3JGdW5jUHRyKQ0KCQkJLnRoZW4ociA9PiByLkNyZWF0ZUNvcmVXZWJWaWV3MkNvbnRyb2xsZXJBc3luYyhod25kKSkNCgl9DQoNCgkvKioNCgkgKiBjcmVhdGUgRWRnZSBXZWJWaWV3MiBFbnZpcm9ubWVudC4NCgkgKiBAcGFyYW0ge1dlYlZpZXcyLkVudmlyb25tZW50T3B0aW9uc30gb3B0aW9ucyBUaGUgZW52aXJvbm1lbnQgb3B0aW9ucyBvZiBFZGdlLg0KCSAqIEBwYXJhbSB7JERpclBhdGh9IGRhdGFEaXIgVXNlciBkYXRhIGZvbGRlci4NCgkgKiBAcGFyYW0geyREaXJQYXRofSBlZGdlUnVudGltZSBUaGUgcGF0aCBvZiBFZGdlIFJ1bnRpbWUgb3IgRWRnZShkZXYuLikgQmluLg0KCSAqIEBwYXJhbSB7JEZpbGVQYXRoIHwgSW50ZWdlcn0gZGxsUGF0aE9yRnVuY1B0ciBUaGUgcGF0aCBvZiBgV2ViVmlldzJMb2FkZXIuZGxsYCBvciBmdW5jdGlvbiBhZGRyZXNzIG9mIGBDcmVhdGVDb3JlV2ViVmlldzJFbnZpcm9ubWVudFdpdGhPcHRpb25zYC4NCgkgKiBAcmV0dXJucyB7UHJvbWlzZTxXZWJWaWV3Mi5FbnZpcm9ubWVudD59DQoJICovDQoJc3RhdGljIENyZWF0ZUVudmlyb25tZW50QXN5bmMob3B0aW9ucyA6PSAwLCBkYXRhRGlyIDo9ICcnLCBlZGdlUnVudGltZSA6PSAnJywgZGxsUGF0aE9yRnVuY1B0ciA6PSAnV2ViVmlldzJMb2FkZXIuZGxsJykgew0KCQlpZiAhKGRsbFBhdGhPckZ1bmNQdHIgaXMgSW50ZWdlcikgew0KCQkJaWYgIUZpbGVFeGlzdChkbGxQYXRoT3JGdW5jUHRyKSAmJiBGaWxlRXhpc3QodCA6PSBBX0xpbmVGaWxlICdcLi5cJyAoQV9QdHJTaXplICogOCkgJ2JpdFxXZWJWaWV3MkxvYWRlci5kbGwnKQ0KCQkJCWRsbFBhdGhPckZ1bmNQdHIgOj0gdA0KCQkJZGxsUGF0aE9yRnVuY1B0ciAuPSAnXENyZWF0ZUNvcmVXZWJWaWV3MkVudmlyb25tZW50V2l0aE9wdGlvbnMnDQoJCX0NCgkJaWYgIWVkZ2VSdW50aW1lIHsNCgkJCXZlciA6PSAnMC4wLjAuMCcNCgkJCWZvciByb290IGluIFtFbnZHZXQoJ1Byb2dyYW1GaWxlcyh4ODYpJyksIEFfQXBwRGF0YSAnXC4uXExvY2FsJ10NCgkJCQlsb29wIGZpbGVzIHJvb3QgJ1xNaWNyb3NvZnRcRWRnZVdlYlZpZXdcQXBwbGljYXRpb25cKicsICdEJw0KCQkJCQlpZiBSZWdFeE1hdGNoKEFfTG9vcEZpbGVQYXRoLCAnXFwoW1xkLl0rKSQnLCAmbSkgJiYgVmVyQ29tcGFyZShtWzFdLCB2ZXIpID4gMA0KCQkJCQkJZWRnZVJ1bnRpbWUgOj0gQV9Mb29wRmlsZUZ1bGxQYXRoLCB2ZXIgOj0gbVsxXQ0KCQl9DQoJCWlmIG9wdGlvbnMgJiYgIShvcHRpb25zIGlzIHRoaXMuRW52aXJvbm1lbnRPcHRpb25zKSB7DQoJCQlpZiAhb3B0aW9ucy5IYXNPd25Qcm9wKCdUYXJnZXRDb21wYXRpYmxlQnJvd3NlclZlcnNpb24nKQ0KCQkJCW9wdGlvbnMuVGFyZ2V0Q29tcGF0aWJsZUJyb3dzZXJWZXJzaW9uIDo9IHZlcg0KCQkJb3B0aW9ucyA6PSB0aGlzLkVudmlyb25tZW50T3B0aW9ucyhvcHRpb25zKQ0KCQl9DQoJCURsbENhbGwoZGxsUGF0aE9yRnVuY1B0ciwgJ3N0cicsIGVkZ2VSdW50aW1lLA0KCQkJJ3N0cicsIGRhdGFEaXIgfHwgUmVnRXhSZXBsYWNlKEFfQXBwRGF0YSwgJ1JvYW1pbmckJywgJ0xvY2FsXE1pY3Jvc29mdFxFZGdlXFVzZXIgRGF0YScpLCAncHRyJywgb3B0aW9ucywNCgkJCSdwdHInLCB0aGlzLkFzeW5jSGFuZGxlcigmcCwgdGhpcy5FbnZpcm9ubWVudCksICdocmVzdWx0JykNCgkJcmV0dXJuIHANCgl9DQoNCgkvKioNCgkgKiBAcGFyYW0geyRGaWxlUGF0aH0gZmlsZVBhdGgNCgkgKiBAcGFyYW0geydyJ3wndyd8J3J3J30gbW9kZQ0KCSAqIC0gYHJgLCByZWFkLW9ubHkgbW9kZSwgZmFpbHMgaWYgdGhlIGZpbGUgZG9lc24ndCBleGlzdC4NCgkgKiAtIGB3YCwgcmVhZC13cml0ZSBtb2RlLCBjcmVhdGVzIGEgbmV3IGZpbGUsIG92ZXJ3cml0aW5nIGFueSBleGlzdGluZyBmaWxlLg0KCSAqIC0gYHJ3YCwgcmVhZC13cml0ZSBtb2RlLCBjcmVhdGVzIGEgbmV3IGZpbGUgaWYgdGhlIGZpbGUgZG9lc24ndCBleGlzdC4NCgkgKiBAcmV0dXJucyB7V2ViVmlldzIuU3RyZWFtfQ0KCSAqLw0KCXN0YXRpYyBDcmVhdGVGaWxlU3RyZWFtKGZpbGVQYXRoLCBtb2RlIDo9ICdyJykgew0KCQlEbGxDYWxsKCdzaGx3YXBpXFNIQ3JlYXRlU3RyZWFtT25GaWxlRXgnLCAnd3N0cicsIGZpbGVQYXRoLCAndWludCcsDQoJCQlJblN0cihtb2RlLCAndycpICYmICghSW5TdHIobW9kZSwgJ3InKSB8fCAhRmlsZUV4aXN0KGZpbGVQYXRoKSA/IDB4MTAwMiA6IDIpLA0KCQkJJ3VpbnQnLCAxMjgsICdpbnQnLCAwLCAncHRyJywgMCwgJ3B0cionLCBzIDo9IHRoaXMuU3RyZWFtKCksICdocmVzdWx0JykNCgkJcmV0dXJuIHMNCgl9DQoNCgkvKioNCgkgKiBAcGFyYW0ge0ludGVnZXIgfCBCdWZmZXJ9IHB0cg0KCSAqIEBwYXJhbSB7SW50ZWdlcn0gc2l6ZQ0KCSAqIEByZXR1cm5zIHtXZWJWaWV3Mi5TdHJlYW19DQoJICovDQoJc3RhdGljIENyZWF0ZU1lbVN0cmVhbShwdHIgOj0gMCwgc2l6ZSA6PSAwKSB7DQoJCShzIDo9IHRoaXMuU3RyZWFtKCkpLlB0ciA6PSBEbGxDYWxsKCdzaGx3YXBpXFNIQ3JlYXRlTWVtU3RyZWFtJywgJ3B0cicsIHB0ciwNCgkJCSd1aW50Jywgc2l6ZSB8fCBwdHIgJiYgcHRyLlNpemUsICdwdHInKQ0KCQlyZXR1cm4gcw0KCX0NCg0KCS8qKg0KCSAqIEBwYXJhbSB7U3RyaW5nfSB0ZXh0DQoJICogQHBhcmFtIHtTdHJpbmd9IGVuY29kaW5nDQoJICogQHJldHVybnMge1dlYlZpZXcyLlN0cmVhbX0NCgkgKi8NCglzdGF0aWMgQ3JlYXRlVGV4dFN0cmVhbSh0ZXh0LCBlbmNvZGluZyA6PSAndXRmLTgnKSB7DQoJCWlmIGVuY29kaW5nID0gJ3V0Zi0xNicNCgkJCXJldHVybiB0aGlzLkNyZWF0ZU1lbVN0cmVhbShTdHJQdHIodGV4dCksIFN0ckxlbih0ZXh0KSA8PCAxKQ0KCQlTdHJQdXQodGV4dCwgYnVmIDo9IEJ1ZmZlcihTdHJQdXQodGV4dCwgZW5jb2RpbmcpIC0gMSksIGVuY29kaW5nKQ0KCQlyZXR1cm4gdGhpcy5DcmVhdGVNZW1TdHJlYW0oYnVmKQ0KCX0NCg0KCS8qKg0KCSAqIEBwYXJhbSB7VmFyUmVmPFByb21pc2U+fSBwDQoJICogQHJldHVybnMge1dlYlZpZXcyLkhhbmRsZXJ9DQoJICovDQoJc3RhdGljIEFzeW5jSGFuZGxlcigmcCwgd3JhcHBlciA6PSAwKSB7DQoJCXAgOj0gUHJvbWlzZShleGVjdXRvci5CaW5kKCZyZXQsIHdyYXBwZXIpKQ0KCQlyZXR1cm4gcmV0DQoJCXN0YXRpYyBleGVjdXRvcigmcmV0LCB0eXBlLCByZXNvbHZlLCByZWplY3QpIHsNCgkJCShyZXQgOj0gV2ViVmlldzIuSGFuZGxlcihoYW5kbGVyLCAzIC0gIXR5cGUpKS5yZWplY3QgOj0gcmVqZWN0DQoJCQlyZXQucmVzb2x2ZSA6PSB0eXBlICYmIHR5cGUgIT09IEludGVnZXIgPyByID0+IHJlc29sdmUodHlwZShyKSkgOiByZXNvbHZlDQoJCX0NCgkJc3RhdGljIGhhbmRsZXIodGhpcywgZXJyLCByZXN1bHQgOj0gJycpIHsNCgkJCXRoaXMgOj0gT2JqRnJvbVB0ckFkZFJlZihOdW1HZXQodGhpcywgQV9QdHJTaXplLCAncHRyJykpDQoJCQlpZiBlcnIgJiYgKCFyZXN1bHQgfHwgZXJyICE9PSAweDgwMDcwMDU3KQ0KCQkJCSh0aGlzLnJlamVjdCkoT1NFcnJvcihlcnIpKQ0KCQkJZWxzZQ0KCQkJCSh0aGlzLnJlc29sdmUpKHJlc3VsdCkNCgkJfQ0KCX0NCg0KCS8qKg0KCSAqIEBwYXJhbSB7KHNlbmRlciwgYXJncyk9PnZvaWR9IGludm9rZQ0KCSAqIEBwYXJhbSBjbHMgU3ViY2xhc3Mgb2YgV2ViVmlldzIuQmFzZQ0KCSAqIEBwYXJhbSBlYSBXZWJWaWV3Mi54eHh4RW52ZW50QXJncw0KCSAqIEByZXR1cm5zIHtXZWJWaWV3Mi5IYW5kbGVyfQ0KCSAqLw0KCXN0YXRpYyBUeXBlZEhhbmRsZXIoaW52b2tlLCBjbHMsIGVhIDo9IDApIHsNCgkJZSA6PSBXZWJWaWV3Mi5IYW5kbGVyKGhhbmRsZXIpDQoJCWUuaW52b2tlIDo9IGludm9rZSwgZS5jbHMgOj0gY2xzLCBlLmVhIDo9IGVhIHx8IHYgPT4gdg0KCQlyZXR1cm4gZQ0KCQlzdGF0aWMgaGFuZGxlcih0aGlzLCBzZW5kZXIsIGFyZ3MpIHsNCgkJCXRoaXMgOj0gT2JqRnJvbVB0ckFkZFJlZihOdW1HZXQodGhpcywgQV9QdHJTaXplLCAncHRyJykpDQoJCQkodGhpcy5pbnZva2UpKCh0aGlzLmNscykoc2VuZGVyKSwgKHRoaXMuZWEpKGFyZ3MpKQ0KCQl9DQoJfQ0KDQoJOyBJbnRlcmZhY2VzIEJhc2UgY2xhc3MNCgljbGFzcyBCYXNlIHsNCgkJc3RhdGljIFByb3RvdHlwZS5QdHIgOj0gMA0KCQkvKioNCgkJICogU29tZSBpbnRlcmZhY2VzIHdpdGggaW5oZXJpdGFuY2UgaGF2ZSBkaWZmZXJlbnQgYWRkcmVzc2VzIGZvciB0aGVpciBvYmplY3RzLg0KCQkgKiBJbmNvcnJlY3QgdXNlIG9mIG1ldGhvZHMgdGhhdCBkbyBub3QgZXhpc3QgaW4gdGhlIGludGVyZmFjZSB3aWxsIGNhdXNlIHRoZSBwcm9ncmFtIHRvIGNyYXNoLg0KCQkgKiBGb3IgZXhhbXBsZSwgdGhlIG9iamVjdCBhZGRyZXNzZXMgZm9yIGBGcmFtZUluZm9gIGFuZCBgRnJhbWVJbmZvMmAgYXJlIGRpZmZlcmVudC4NCgkJICogQnkgc3BlY2lmeWluZyB0aGUgZGVmYXVsdCBJSUQsIHRoZSBpbnRlcmZhY2UgaXMgYXV0b21hdGljYWxseSBxdWVyaWVkIHdoZW4gdGhlc2Ugb2JqZWN0cyBhcmUgcmV0dXJuZWQuDQoJCSAqLw0KCQlzdGF0aWMgRGVmYXVsdElJRCB7DQoJCQlzZXQgew0KCQkJCXRoaXMuUHJvdG90eXBlLkRlZmluZVByb3AoJ1B0cicsIHsgc2V0OiBRdWVyeUludGVyZmFjZSB9KQ0KCQkJCVF1ZXJ5SW50ZXJmYWNlKHRoaXMsIHB0cikgew0KCQkJCQlpZiAhcHRyDQoJCQkJCQlyZXR1cm4NCgkJCQkJb2JqIDo9IENvbU9ialF1ZXJ5KHB0ciwgVmFsdWUpDQoJCQkJCWlmIHB0ciAhPT0gbnB0ciA6PSBDb21PYmpWYWx1ZShvYmopDQoJCQkJCQlPYmpSZWxlYXNlKHB0ciksIE9iakFkZFJlZihwdHIgOj0gbnB0cikNCgkJCQkJdGhpcy5EZWZpbmVQcm9wKCdQdHInLCB7IHZhbHVlOiBwdHIgfSkNCgkJCQl9DQoJCQl9DQoJCX0NCgkJOyBSZS1pbXBsZW1lbnQgdGhlIGFkZF8gbWV0aG9kIGFuZCBhdXRvbWF0aWNhbGx5IGNvbnZlcnQgdGhlIGFoayBmdW5jdGlvbiBpbnRvIGEgZGVsZWdhdGUgaW4gd2VidmlldzIuDQoJCXN0YXRpYyBfX05ldygpIHsNCgkJCXB0aGlzIDo9IE9ialB0cih0aGlzKQ0KCQkJZm9yIGsgaW4gKHByb3RvIDo9IHRoaXMuUHJvdG90eXBlKS5Pd25Qcm9wcygpIHsNCgkJCQlpZiBTdWJTdHIoaywgMSwgNCkgIT09ICdhZGRfJw0KCQkJCQljb250aW51ZQ0KCQkJCWlmIE9iakhhc093blByb3AoV2ViVmlldzIsIGVhIDo9IFN1YlN0cihrLCA1KSAnRXZlbnRBcmdzJykgfHwNCgkJCQkJT2JqSGFzT3duUHJvcChXZWJWaWV3MiwgZWEgOj0gU3RyUmVwbGFjZShlYSwgJ0ZyYW1lJykpDQoJCQkJCWVhIDo9IFdlYlZpZXcyLiVlYSUNCgkJCQllbHNlIGVhIDo9IDANCgkJCQlwcm90by5EZWZpbmVQcm9wKGssIHsgY2FsbDogYWRkX2hhbmRsZXIuQmluZChwcm90by4layUsIHB0aGlzLCBlYSkgfSkNCgkJCX0NCgkJCXN0YXRpYyBhZGRfaGFuZGxlcihtZXRob2QsIHBjbHMsIGVhLCB0aGlzLCBoYW5kbGVyKSB7DQoJCQkJaWYgIUlzSW50ZWdlcihoYW5kbGVyKSAmJiAhKGhhbmRsZXIgaXMgV2ViVmlldzIuSGFuZGxlcikgew0KCQkJCQlpZiAhSGFzTWV0aG9kKGhhbmRsZXIsICwgMikNCgkJCQkJCXRocm93IFR5cGVFcnJvcignSGFuZGxlciBmdW5jdGlvbiByZXF1aXJlcyAyIHBhcmFtZXRlcnMuJykNCgkJCQkJaGFuZGxlciA6PSBXZWJWaWV3Mi5UeXBlZEhhbmRsZXIoaGFuZGxlciwgT2JqRnJvbVB0ckFkZFJlZihwY2xzKSwgZWEpDQoJCQkJfQ0KCQkJCXJldHVybiBtZXRob2QodGhpcywgaGFuZGxlcikNCgkJCX0NCgkJfQ0KCQlfX05ldyhwdHIgOj0gMCkgPT4gcHRyICYmIChPYmpBZGRSZWYocHRyKSwgdGhpcy5QdHIgOj0gcHRyKQ0KCQlfX0RlbGV0ZSgpID0+IChwdHIgOj0gdGhpcy5wdHIpICYmIE9ialJlbGVhc2UocHRyKQ0KCQlfX0NhbGwoTmFtZSwgUGFyYW1zKSB7DQoJCQlpZiBIYXNNZXRob2QodGhpcywgTmFtZSAnQXN5bmMnKQ0KCQkJCXJldHVybiB0aGlzLiVOYW1lJUFzeW5jKFBhcmFtcyopLmF3YWl0KCkNCgkJCWlmIEhhc01ldGhvZCh0aGlzLCAnYWRkXycgTmFtZSkNCgkJCQlyZXR1cm4geyBwdHI6IHRoaXMucHRyLCBfX0RlbGV0ZTogdGhpcy5yZW1vdmVfJU5hbWUlLkJpbmQoLCB0aGlzLmFkZF8lTmFtZSUoUGFyYW1zWzFdKSkgfQ0KCQkJdGhyb3cgTWV0aG9kRXJyb3IoJ1RoaXMgdmFsdWUgb2YgdHlwZSAiJyB0aGlzLl9fQ2xhc3MgJyIgaGFzIG5vIG1ldGhvZCBuYW1lZCAiJyBOYW1lICciLicsIC0xKQ0KCQl9DQoJCS8qKg0KCQkgKiBDb252ZXJ0IHRoZSBvYmplY3QgdG8gYW5vdGhlciBpbnRlcmZhY2UuDQoJCSAqIEBwYXJhbSB7Q2xhc3N9IGNscyBBIHN1YmNsYXNzIG9mIFdlYlZpZXcyLmJhc2UNCgkJICogQHBhcmFtIHtTdHJpbmd9IGlpZA0KCQkgKi8NCgkJYXMoY2xzLCBpaWQ/KSB7DQoJCQlwdHIgOj0gQ29tT2JqVmFsdWUob2JqIDo9IENvbU9ialF1ZXJ5KHRoaXMsIGlpZCA/PyBjbHMuSUlEKSkNCgkJCWlmIHB0ciA9PSB0aGlzLlB0cg0KCQkJCU9ialNldEJhc2UodGhpcywgY2xzLlByb3RvdHlwZSkNCgkJCWVsc2UgaWYgdGhpcyBpcyBjbHMNCgkJCQlPYmpSZWxlYXNlKHRoaXMuUHRyKSwgT2JqQWRkUmVmKHRoaXMuUHRyIDo9IHB0cikNCgkJCWVsc2UgcmV0dXJuIGNscyhwdHIpDQoJCQlyZXR1cm4gdGhpcw0KCQl9DQoJCS8qKg0KCQkgKiBCeSBkZWZhdWx0LCBhbiBvYmplY3QgaW4gd2VidmlldzIgY2FuIGJlIGVuY2Fwc3VsYXRlZCBhcyBtdWx0aXBsZSBkaWZmZXJlbnQgYWhrIG9iamVjdHMsDQoJCSAqIHdpdGggaW5kZXBlbmRlbnQgcHJvcGVydGllcy4gQnkgY2FsbGluZyB0aGlzIG1ldGhvZCwgeW91IGNhbiBnZXQgaXRzIHVuaXF1ZSBvYmplY3QgaW4gYWhrLg0KCQkgKiBAcmV0dXJucyB7dGhpc30NCgkJICovDQoJCXVuaXF1ZSgpIHsNCgkJCXN0YXRpYyBjYWNoZXMgOj0gTWFwKCkNCgkJCWlmIHB0ciA6PSBjYWNoZXMuR2V0KHRoaXMuUHRyLCAwKQ0KCQkJCXJldHVybiBPYmpGcm9tUHRyQWRkUmVmKHB0cikNCgkJCWlmIHB0ciA6PSB0aGlzLlB0ciB7DQoJCQkJY2FjaGVzW3B0cl0gOj0gT2JqUHRyKHRoaXMpDQoJCQkJY2FjaGUgOj0geyBQdHI6IHB0ciwgX19EZWxldGU6IHRoaXMgPT4gY2FjaGVzLkRlbGV0ZSh0aGlzLlB0cikgfQ0KCQkJCXRoaXMuRGVmaW5lUHJvcCgndW5pcXVlJywgeyBjYWxsOiAodGhpcykgPT4gKGNhY2hlLCB0aGlzKSB9KQ0KCQkJfQ0KCQkJcmV0dXJuIHRoaXMNCgkJfQ0KCX0NCgljbGFzcyBMaXN0IGV4dGVuZHMgV2ViVmlldzIuQmFzZSB7DQoJCTtAbGludC1kaXNhYmxlIGNsYXNzLW5vbi1keW5hbWljLW1lbWJlci1jaGVjaw0KCQlfX0l0ZW1baW5kZXhdID0+IHRoaXMuR2V0VmFsdWVBdEluZGV4KGluZGV4KQ0KCQlfX0VudW0obikgew0KCQkJaWYgbiA9IDENCgkJCQlyZXR1cm4gKG4gOj0gdGhpcy5Db3VudCwgaSA6PSAwLCAoJnYpID0+IGkgPCBuID8gKHYgOj0gdGhpcy5HZXRWYWx1ZUF0SW5kZXgoaSsrKSwgdHJ1ZSkgOiBmYWxzZSkNCgkJCXJldHVybiAobiA6PSB0aGlzLkNvdW50LCBpIDo9IDAsICgmaywgJnYsICopID0+IGkgPCBuID8gKHYgOj0gdGhpcy5HZXRWYWx1ZUF0SW5kZXgoayA6PSBpKyspLCB0cnVlKSA6IGZhbHNlKQ0KCQl9DQoJfQ0KDQoJOyNyZWdpb24gV2ViVmlldzIgSW50ZXJmYWNlcw0KCWNsYXNzIEFjY2VsZXJhdG9yS2V5UHJlc3NlZEV2ZW50QXJncyBleHRlbmRzIFdlYlZpZXcyLkJhc2Ugew0KCQlzdGF0aWMgSUlEIDo9ICd7OWY3NjBmOGEtZmI3OS00MmJlLTk5OTAtN2I1NjkwMGZhOWM3fScNCgkJS2V5RXZlbnRLaW5kID0+IChDb21DYWxsKDMsIHRoaXMsICdpbnQqJywgJmtleUV2ZW50S2luZCA6PSAwKSwga2V5RXZlbnRLaW5kKQk7IENPUkVXRUJWSUVXMl9LRVlfRVZFTlRfS0lORA0KCQlWaXJ0dWFsS2V5ID0+IChDb21DYWxsKDQsIHRoaXMsICd1aW50KicsICZ2aXJ0dWFsS2V5IDo9IDApLCB2aXJ0dWFsS2V5KQ0KCQlLZXlFdmVudExQYXJhbSA9PiAoQ29tQ2FsbCg1LCB0aGlzLCAnaW50KicsICZsUGFyYW0gOj0gMCksIGxQYXJhbSkNCgkJUGh5c2ljYWxLZXlTdGF0dXMgPT4gKENvbUNhbGwoNiwgdGhpcywgJ3B0cionLCBwaHlzaWNhbEtleVN0YXR1cyA6PSBXZWJWaWV3Mi5QSFlTSUNBTF9LRVlfU1RBVFVTKCkpLCBwaHlzaWNhbEtleVN0YXR1cykJOyBDT1JFV0VCVklFVzJfUEhZU0lDQUxfS0VZX1NUQVRVUw0KCQlIYW5kbGVkIHsNCgkJCWdldCA9PiAoQ29tQ2FsbCg3LCB0aGlzLCAnaW50KicsICZoYW5kbGVkIDo9IDApLCBoYW5kbGVkKQ0KCQkJc2V0ID0+IENvbUNhbGwoOCwgdGhpcywgJ2ludCcsIFZhbHVlKQ0KCQl9DQoNCgkJc3RhdGljIElJRF8yIDo9ICd7MDNiMmM4YzgtNzc5OS00ZTM0LWJkNjYtZWQyNmFhODVmMmJmfScNCgkJSXNCcm93c2VyQWNjZWxlcmF0b3JLZXlFbmFibGVkIHsNCgkJCWdldCA9PiAoQ29tQ2FsbCg5LCB0aGlzLCAnaW50KicsICZ2YWx1ZSA6PSAwKSwgdmFsdWUpDQoJCQlzZXQgPT4gQ29tQ2FsbCgxMCwgdGhpcywgJ2ludCcsIFZhbHVlKQ0KCQl9DQoJfQ0KCWNsYXNzIEJhc2ljQXV0aGVudGljYXRpb25SZXF1ZXN0ZWRFdmVudEFyZ3MgZXh0ZW5kcyBXZWJWaWV3Mi5CYXNlIHsNCgkJc3RhdGljIElJRCA6PSAne2VmMDU1MTZmLWQ4OTctNGY5ZS1iNjcyLWQ4ZTIzMDdhM2ZiMH0nDQoJCVVyaSA9PiAoQ29tQ2FsbCgzLCB0aGlzLCAncHRyKicsICZ2YWx1ZSA6PSAwKSwgQ29UYXNrTWVtX1N0cmluZyh2YWx1ZSkpDQoJCUNoYWxsZW5nZSA9PiAoQ29tQ2FsbCg0LCB0aGlzLCAncHRyKicsICZjaGFsbGVuZ2UgOj0gMCksIENvVGFza01lbV9TdHJpbmcoY2hhbGxlbmdlKSkNCgkJUmVzcG9uc2UgPT4gKENvbUNhbGwoNSwgdGhpcywgJ3B0cionLCByZXNwb25zZSA6PSBXZWJWaWV3Mi5CYXNpY0F1dGhlbnRpY2F0aW9uUmVzcG9uc2UoKSksIHJlc3BvbnNlKQ0KCQlDYW5jZWwgew0KCQkJZ2V0ID0+IChDb21DYWxsKDYsIHRoaXMsICdpbnQqJywgJmNhbmNlbCA6PSAwKSwgY2FuY2VsKQ0KCQkJc2V0ID0+IENvbUNhbGwoNywgdGhpcywgJ2ludCcsIFZhbHVlKQ0KCQl9DQoJCUdldERlZmVycmFsKCkgPT4gKENvbUNhbGwoOCwgdGhpcywgJ3B0cionLCBkZWZlcnJhbCA6PSBXZWJWaWV3Mi5EZWZlcnJhbCgpKSwgZGVmZXJyYWwpDQoJfQ0KCWNsYXNzIEJhc2ljQXV0aGVudGljYXRpb25SZXNwb25zZSBleHRlbmRzIFdlYlZpZXcyLkJhc2Ugew0KCQlVc2VyTmFtZSB7DQoJCQlnZXQgPT4gKENvbUNhbGwoMywgdGhpcywgJ3B0cionLCAmdXNlck5hbWUgOj0gMCksIENvVGFza01lbV9TdHJpbmcodXNlck5hbWUpKQ0KCQkJc2V0ID0+IENvbUNhbGwoNCwgdGhpcywgJ3dzdHInLCBWYWx1ZSkNCgkJfQ0KCQlQYXNzd29yZCB7DQoJCQlnZXQgPT4gKENvbUNhbGwoNSwgdGhpcywgJ3B0cionLCAmcGFzc3dvcmQgOj0gMCksIENvVGFza01lbV9TdHJpbmcocGFzc3dvcmQpKQ0KCQkJc2V0ID0+IENvbUNhbGwoNiwgdGhpcywgJ3dzdHInLCBWYWx1ZSkNCgkJfQ0KCX0NCgljbGFzcyBCcm93c2VyRXh0ZW5zaW9uIGV4dGVuZHMgV2ViVmlldzIuQmFzZSB7DQoJCXN0YXRpYyBJSUQgOj0gJ3s3RUY3RkZBMC1GQUM1LTQ2MkMtQjE4OS0zRDlFREJFNTc1REF9Jw0KCQlJZCA9PiAoQ29tQ2FsbCgzLCB0aGlzLCAncHRyKicsICZ2YWx1ZSA6PSAwKSwgQ29UYXNrTWVtX1N0cmluZyh2YWx1ZSkpDQoJCU5hbWUgPT4gKENvbUNhbGwoNCwgdGhpcywgJ3B0cionLCAmdmFsdWUgOj0gMCksIENvVGFza01lbV9TdHJpbmcodmFsdWUpKQ0KCQkvKiogQHJldHVybnMge1Byb21pc2U8dm9pZD59ICovDQoJCVJlbW92ZUFzeW5jKCkgPT4gKENvbUNhbGwoNSwgdGhpcywgJ3B0cicsIFdlYlZpZXcyLkFzeW5jSGFuZGxlcigmcCkpLCBwKQ0KCQlJc0VuYWJsZWQgPT4gKENvbUNhbGwoNiwgdGhpcywgJ2ludConLCAmdmFsdWUgOj0gMCksIHZhbHVlKQ0KCQkvKiogQHJldHVybnMge1Byb21pc2U8dm9pZD59ICovDQoJCUVuYWJsZUFzeW5jKGlzRW5hYmxlZCkgPT4gKENvbUNhbGwoNywgdGhpcywgJ2ludCcsIGlzRW5hYmxlZCwgJ3B0cicsIFdlYlZpZXcyLkFzeW5jSGFuZGxlcigmcCkpLCBwKQ0KCX0NCgljbGFzcyBCcm93c2VyRXh0ZW5zaW9uTGlzdCBleHRlbmRzIFdlYlZpZXcyLkxpc3Qgew0KCQlzdGF0aWMgSUlEIDo9ICd7MkVGM0QyREMtQkQ1Ri00RjRELTkwQUYtRkQ2Nzc5OEYwQzJGfScNCgkJQ291bnQgPT4gKENvbUNhbGwoMywgdGhpcywgJ3VpbnQqJywgJmNvdW50IDo9IDApLCBjb3VudCkNCgkJR2V0VmFsdWVBdEluZGV4KGluZGV4KSA9PiAoQ29tQ2FsbCg0LCB0aGlzLCAndWludCcsIGluZGV4LCAncHRyKicsIGV4dGVuc2lvbiA6PSBXZWJWaWV3Mi5Ccm93c2VyRXh0ZW5zaW9uKCkpLCBleHRlbnNpb24pDQoJfQ0KCWNsYXNzIEJyb3dzZXJQcm9jZXNzRXhpdGVkRXZlbnRBcmdzIGV4dGVuZHMgV2ViVmlldzIuQmFzZSB7DQoJCXN0YXRpYyBJSUQgOj0gJ3sxZjAwNjYzZi1hZjhjLTQ3ODItOWNkZC1kZDAxYzUyZTM0Y2J9Jw0KCQlCcm93c2VyUHJvY2Vzc0V4aXRLaW5kID0+IChDb21DYWxsKDMsIHRoaXMsICdpbnQqJywgJmJyb3dzZXJQcm9jZXNzRXhpdEtpbmQgOj0gMCksIGJyb3dzZXJQcm9jZXNzRXhpdEtpbmQpCTsgQ09SRVdFQlZJRVcyX0JST1dTRVJfUFJPQ0VTU19FWElUX0tJTkQNCgkJQnJvd3NlclByb2Nlc3NJZCA9PiAoQ29tQ2FsbCg0LCB0aGlzLCAndWludConLCAmdmFsdWUgOj0gMCksIHZhbHVlKQ0KCX0NCgljbGFzcyBDZXJ0aWZpY2F0ZSBleHRlbmRzIFdlYlZpZXcyLkJhc2Ugew0KCQlzdGF0aWMgSUlEIDo9ICd7QzVGQjJGQ0UtMUNBQy00QUVFLTlDNzktNUVEMDM2MkVBQUUwfScNCgkJU3ViamVjdCA9PiAoQ29tQ2FsbCgzLCB0aGlzLCAncHRyKicsICZ2YWx1ZSA6PSAwKSwgQ29UYXNrTWVtX1N0cmluZyh2YWx1ZSkpDQoJCUlzc3VlciA9PiAoQ29tQ2FsbCg0LCB0aGlzLCAncHRyKicsICZ2YWx1ZSA6PSAwKSwgQ29UYXNrTWVtX1N0cmluZyh2YWx1ZSkpDQoJCVZhbGlkRnJvbSA9PiAoQ29tQ2FsbCg1LCB0aGlzLCAnZG91YmxlKicsICZ2YWx1ZSA6PSAwKSwgdmFsdWUpDQoJCVZhbGlkVG8gPT4gKENvbUNhbGwoNiwgdGhpcywgJ2RvdWJsZSonLCAmdmFsdWUgOj0gMCksIHZhbHVlKQ0KCQlEZXJFbmNvZGVkU2VyaWFsTnVtYmVyID0+IChDb21DYWxsKDcsIHRoaXMsICdwdHIqJywgJnZhbHVlIDo9IDApLCBDb1Rhc2tNZW1fU3RyaW5nKHZhbHVlKSkNCgkJRGlzcGxheU5hbWUgPT4gKENvbUNhbGwoOCwgdGhpcywgJ3B0cionLCAmdmFsdWUgOj0gMCksIENvVGFza01lbV9TdHJpbmcodmFsdWUpKQ0KCQlUb1BlbUVuY29kaW5nKCkgPT4gKENvbUNhbGwoOSwgdGhpcywgJ3B0cionLCAmcGVtRW5jb2RlZERhdGEgOj0gMCksIENvVGFza01lbV9TdHJpbmcocGVtRW5jb2RlZERhdGEpKQ0KCQlQZW1FbmNvZGVkSXNzdWVyQ2VydGlmaWNhdGVDaGFpbiA9PiAoQ29tQ2FsbCgxMCwgdGhpcywgJ3B0cionLCB2YWx1ZSA6PSBXZWJWaWV3Mi5TdHJpbmdDb2xsZWN0aW9uKCkpLCB2YWx1ZSkNCgl9DQoJY2xhc3MgQ29tcG9zaXRpb25Db250cm9sbGVyIGV4dGVuZHMgV2ViVmlldzIuQmFzZSB7DQoJCXN0YXRpYyBJSUQgOj0gJ3szZGY5YjczMy1iOWFlLTRhMTUtODZiNC1lYjllZTk4MjY0Njl9Jw0KCQlSb290VmlzdWFsVGFyZ2V0IHsNCgkJCWdldCA9PiAoQ29tQ2FsbCgzLCB0aGlzLCAncHRyKicsICZ0YXJnZXQgOj0gMCksIENvbVZhbHVlKDB4ZCwgdGFyZ2V0KSkNCgkJCXNldCA9PiBDb21DYWxsKDQsIHRoaXMsICdwdHInLCBWYWx1ZSkNCgkJfQ0KCQlTZW5kTW91c2VJbnB1dChldmVudEtpbmQsIHZpcnR1YWxLZXlzLCBtb3VzZURhdGEsIHBvaW50KSA9PiBDb21DYWxsKDUsIHRoaXMsICdpbnQnLCBldmVudEtpbmQsICdpbnQnLCB2aXJ0dWFsS2V5cywgJ3VpbnQnLCBtb3VzZURhdGEsICdpbnQ2NCcsIHBvaW50KQ0KCQlTZW5kUG9pbnRlcklucHV0KGV2ZW50S2luZCwgcG9pbnRlckluZm8pID0+IENvbUNhbGwoNiwgdGhpcywgJ2ludCcsIGV2ZW50S2luZCwgJ3B0cicsIHBvaW50ZXJJbmZvKQk7IElDb3JlV2ViVmlldzJQb2ludGVySW5mbw0KCQlDdXJzb3IgPT4gKENvbUNhbGwoNywgdGhpcywgJ3B0cionLCAmY3Vyc29yIDo9IDApLCBjdXJzb3IpDQoJCVN5c3RlbUN1cnNvcklkID0+IChDb21DYWxsKDgsIHRoaXMsICd1aW50KicsICZzeXN0ZW1DdXJzb3JJZCA6PSAwKSwgc3lzdGVtQ3Vyc29ySWQpDQoJCS8qKiBAcGFyYW0geyhzZW5kZXI6IFdlYlZpZXcyLkNvbXBvc2l0aW9uQ29udHJvbGxlciwgYXJnczogSVVua25vd24pID0+IHZvaWR9IGV2ZW50SGFuZGxlciAqLw0KCQlhZGRfQ3Vyc29yQ2hhbmdlZChldmVudEhhbmRsZXIpID0+IChDb21DYWxsKDksIHRoaXMsICdwdHInLCBldmVudEhhbmRsZXIsICdpbnQ2NConLCAmdG9rZW4gOj0gMCksIHRva2VuKQk7IElDb3JlV2ViVmlldzJDdXJzb3JDaGFuZ2VkRXZlbnRIYW5kbGVyDQoJCXJlbW92ZV9DdXJzb3JDaGFuZ2VkKHRva2VuKSA9PiBDb21DYWxsKDEwLCB0aGlzLCAnaW50NjQnLCB0b2tlbikNCg0KCQlzdGF0aWMgSUlEXzIgOj0gJ3swYjZhM2QyNC00OWNiLTQ4MDYtYmEyMC1iNWUwNzM0YTdiMjZ9Jw0KCQlBdXRvbWF0aW9uUHJvdmlkZXIgPT4gKENvbUNhbGwoMTEsIHRoaXMsICdwdHIqJywgJnByb3ZpZGVyIDo9IDApLCBDb21WYWx1ZSgweGQsIHByb3ZpZGVyKSkNCg0KCQlzdGF0aWMgSUlEXzMgOj0gJ3s5NTcwNTcwZS00ZDc2LTQzNjEtOWVlMS1mMDRkMGRiZGZiMWV9Jw0KCQlEcmFnRW50ZXIoZGF0YU9iamVjdCwga2V5U3RhdGUsIHBvaW50LCBwZWZmZWN0KSA9PiBDb21DYWxsKDEyLCB0aGlzLCAncHRyJywgZGF0YU9iamVjdCwgJ3VpbnQnLCBrZXlTdGF0ZSwgJ2ludDY0JywgcG9pbnQsICdwdHInLCBwZWZmZWN0KQ0KCQlEcmFnTGVhdmUoKSA9PiBDb21DYWxsKDEzLCB0aGlzKQ0KCQlEcmFnT3ZlcihrZXlTdGF0ZSwgcG9pbnQsIHBlZmZlY3QpID0+IENvbUNhbGwoMTQsIHRoaXMsICd1aW50Jywga2V5U3RhdGUsICdpbnQ2NCcsIHBvaW50LCAncHRyJywgcGVmZmVjdCkNCgkJRHJvcChkYXRhT2JqZWN0LCBrZXlTdGF0ZSwgcG9pbnQsIHBlZmZlY3QpID0+IENvbUNhbGwoMTUsIHRoaXMsICdwdHInLCBkYXRhT2JqZWN0LCAndWludCcsIGtleVN0YXRlLCAnaW50NjQnLCBwb2ludCwgJ3B0cicsIHBlZmZlY3QpDQoNCgkJc3RhdGljIElJRF80IDo9ICd7N0MzNjdCOUItM0QyQi00NTBGLTlFNTgtRDYxQTIwRjQ4NkFBfScNCgkJR2V0Tm9uQ2xpZW50UmVnaW9uQXRQb2ludChwb2ludCkgPT4gKENvbUNhbGwoMTYsIHRoaXMsICdpbnQ2NCcsIHBvaW50LCAnaW50KicsICZ2YWx1ZSA6PSAwKSwgdmFsdWUpCTsgQ09SRVdFQlZJRVcyX05PTl9DTElFTlRfUkVHSU9OX0tJTkQNCgkJUXVlcnlOb25DbGllbnRSZWdpb24oa2luZCkgPT4gKENvbUNhbGwoMTcsIHRoaXMsICdpbnQnLCBraW5kLCAncHRyKicsIHJlY3RzIDo9IFdlYlZpZXcyLlJlZ2lvblJlY3RDb2xsZWN0aW9uVmlldygpKSwgcmVjdHMpDQoJCS8qKiBAcGFyYW0geyhzZW5kZXI6IFdlYlZpZXcyLkNvbXBvc2l0aW9uQ29udHJvbGxlciwgYXJnczogV2ViVmlldzIuTm9uQ2xpZW50UmVnaW9uQ2hhbmdlZEV2ZW50QXJncykgPT4gdm9pZH0gZXZlbnRIYW5kbGVyICovDQoJCWFkZF9Ob25DbGllbnRSZWdpb25DaGFuZ2VkKGV2ZW50SGFuZGxlcikgPT4gKENvbUNhbGwoMTgsIHRoaXMsICdwdHInLCBldmVudEhhbmRsZXIsICdpbnQ2NConLCAmdG9rZW4gOj0gMCksIHRva2VuKQ0KCQlyZW1vdmVfTm9uQ2xpZW50UmVnaW9uQ2hhbmdlZCh0b2tlbikgPT4gQ29tQ2FsbCgxOSwgdGhpcywgJ2ludDY0JywgdG9rZW4pDQoJfQ0KCWNsYXNzIENvbnRyb2xsZXIgZXh0ZW5kcyBXZWJWaWV3Mi5CYXNlIHsNCgkJc3RhdGljIElJRCA6PSAnezRkMDBjMGQxLTk0MzQtNGViNi04MDc4LTg2OTdhNTYwMzM0Zn0nDQoJCUZpbGwoKSB7DQoJCQlpZiAhdGhpcy5wdHINCgkJCQlyZXR1cm4NCgkJCURsbENhbGwoJ3VzZXIzMlxHZXRDbGllbnRSZWN0JywgJ3B0cicsIHRoaXMuUGFyZW50V2luZG93LCAncHRyJywgUkVDVCA6PSBCdWZmZXIoMTYpKQ0KCQkJdGhpcy5Cb3VuZHMgOj0gUkVDVA0KCQkJcmV0dXJuIHRoaXMNCgkJfQ0KCQlJc1Zpc2libGUgew0KCQkJZ2V0ID0+IChDb21DYWxsKDMsIHRoaXMsICdpbnQqJywgJmlzVmlzaWJsZSA6PSAwKSwgaXNWaXNpYmxlKQ0KCQkJc2V0ID0+IENvbUNhbGwoNCwgdGhpcywgJ2ludCcsIFZhbHVlKQ0KCQl9DQoJCUJvdW5kcyB7DQoJCQlnZXQgPT4gKENvbUNhbGwoNSwgdGhpcywgJ3B0cicsIGJvdW5kcyA6PSBXZWJWaWV3Mi5SRUNUKCkpLCBib3VuZHMpDQoJCQlzZXQgPT4gQV9QdHJTaXplID0gOCA/IENvbUNhbGwoNiwgdGhpcywgJ3B0cicsIFZhbHVlKSA6IENvbUNhbGwoNiwgdGhpcywgJ2ludDY0JywgTnVtR2V0KFZhbHVlLCAnaW50NjQnKSwgJ2ludDY0JywgTnVtR2V0KFZhbHVlLCA4LCAnaW50NjQnKSkNCgkJfQ0KCQlab29tRmFjdG9yIHsNCgkJCWdldCA9PiAoQ29tQ2FsbCg3LCB0aGlzLCAnZG91YmxlKicsICZ6b29tRmFjdG9yIDo9IDApLCB6b29tRmFjdG9yKQ0KCQkJc2V0ID0+IENvbUNhbGwoOCwgdGhpcywgJ2RvdWJsZScsIFZhbHVlKQ0KCQl9DQoJCS8qKiBAcGFyYW0geyhzZW5kZXI6IFdlYlZpZXcyLkNvbnRyb2xsZXIsIGFyZ3M6IElVbmtub3duKSA9PiB2b2lkfSBldmVudEhhbmRsZXIgKi8NCgkJYWRkX1pvb21GYWN0b3JDaGFuZ2VkKGV2ZW50SGFuZGxlcikgPT4gKENvbUNhbGwoOSwgdGhpcywgJ3B0cicsIGV2ZW50SGFuZGxlciwgJ2ludDY0KicsICZ0b2tlbiA6PSAwKSwgdG9rZW4pCTsgSUNvcmVXZWJWaWV3Mlpvb21GYWN0b3JDaGFuZ2VkRXZlbnRIYW5kbGVyDQoJCXJlbW92ZV9ab29tRmFjdG9yQ2hhbmdlZCh0b2tlbikgPT4gQ29tQ2FsbCgxMCwgdGhpcywgJ2ludDY0JywgdG9rZW4pDQoJCVNldEJvdW5kc0FuZFpvb21GYWN0b3IoYm91bmRzLCB6b29tRmFjdG9yKSA9PiAoQV9QdHJTaXplID0gOCA/IENvbUNhbGwoMTEsIHRoaXMsICdwdHInLCBib3VuZHMsICdkb3VibGUnLCB6b29tRmFjdG9yKSA6IENvbUNhbGwoMTEsIHRoaXMsICdpbnQ2NCcsIE51bUdldChib3VuZHMsICdpbnQ2NCcpLCAnaW50NjQnLCBOdW1HZXQoYm91bmRzLCA4LCAnaW50NjQnKSwgJ2RvdWJsZScsIHpvb21GYWN0b3IpKQ0KCQlNb3ZlRm9jdXMocmVhc29uKSA9PiBDb21DYWxsKDEyLCB0aGlzLCAnaW50JywgcmVhc29uKQ0KCQkvKiogQHBhcmFtIHsoc2VuZGVyOiBXZWJWaWV3Mi5Db250cm9sbGVyLCBhcmdzOiBXZWJWaWV3Mi5Nb3ZlRm9jdXNSZXF1ZXN0ZWRFdmVudEFyZ3MpID0+IHZvaWR9IGV2ZW50SGFuZGxlciAqLw0KCQlhZGRfTW92ZUZvY3VzUmVxdWVzdGVkKGV2ZW50SGFuZGxlcikgPT4gKENvbUNhbGwoMTMsIHRoaXMsICdwdHInLCBldmVudEhhbmRsZXIsICdpbnQ2NConLCAmdG9rZW4gOj0gMCksIHRva2VuKQk7IElDb3JlV2ViVmlldzJNb3ZlRm9jdXNSZXF1ZXN0ZWRFdmVudEhhbmRsZXINCgkJcmVtb3ZlX01vdmVGb2N1c1JlcXVlc3RlZCh0b2tlbikgPT4gQ29tQ2FsbCgxNCwgdGhpcywgJ2ludDY0JywgdG9rZW4pDQoJCS8qKiBAcGFyYW0geyhzZW5kZXI6IFdlYlZpZXcyLkNvbnRyb2xsZXIsIGFyZ3M6IElVbmtub3duKSA9PiB2b2lkfSBldmVudEhhbmRsZXIgKi8NCgkJYWRkX0dvdEZvY3VzKGV2ZW50SGFuZGxlcikgPT4gKENvbUNhbGwoMTUsIHRoaXMsICdwdHInLCBldmVudEhhbmRsZXIsICdpbnQ2NConLCAmdG9rZW4gOj0gMCksIHRva2VuKQk7IElDb3JlV2ViVmlldzJGb2N1c0NoYW5nZWRFdmVudEhhbmRsZXINCgkJcmVtb3ZlX0dvdEZvY3VzKHRva2VuKSA9PiBDb21DYWxsKDE2LCB0aGlzLCAnaW50NjQnLCB0b2tlbikNCgkJLyoqIEBwYXJhbSB7KHNlbmRlcjogV2ViVmlldzIuQ29udHJvbGxlciwgYXJnczogSVVua25vd24pID0+IHZvaWR9IGV2ZW50SGFuZGxlciAqLw0KCQlhZGRfTG9zdEZvY3VzKGV2ZW50SGFuZGxlcikgPT4gKENvbUNhbGwoMTcsIHRoaXMsICdwdHInLCBldmVudEhhbmRsZXIsICdpbnQ2NConLCAmdG9rZW4gOj0gMCksIHRva2VuKQk7IElDb3JlV2ViVmlldzJGb2N1c0NoYW5nZWRFdmVudEhhbmRsZXINCgkJcmVtb3ZlX0xvc3RGb2N1cyh0b2tlbikgPT4gQ29tQ2FsbCgxOCwgdGhpcywgJ2ludDY0JywgdG9rZW4pDQoJCS8qKiBAcGFyYW0geyhzZW5kZXI6IFdlYlZpZXcyLkNvbnRyb2xsZXIsIGFyZ3M6IFdlYlZpZXcyLkFjY2VsZXJhdG9yS2V5UHJlc3NlZEV2ZW50QXJncykgPT4gdm9pZH0gZXZlbnRIYW5kbGVyICovDQoJCWFkZF9BY2NlbGVyYXRvcktleVByZXNzZWQoZXZlbnRIYW5kbGVyKSA9PiAoQ29tQ2FsbCgxOSwgdGhpcywgJ3B0cicsIGV2ZW50SGFuZGxlciwgJ2ludDY0KicsICZ0b2tlbiA6PSAwKSwgdG9rZW4pCTsgSUNvcmVXZWJWaWV3MkFjY2VsZXJhdG9yS2V5UHJlc3NlZEV2ZW50SGFuZGxlcg0KCQlyZW1vdmVfQWNjZWxlcmF0b3JLZXlQcmVzc2VkKHRva2VuKSA9PiBDb21DYWxsKDIwLCB0aGlzLCAnaW50NjQnLCB0b2tlbikNCgkJUGFyZW50V2luZG93IHsNCgkJCWdldCA9PiAoQ29tQ2FsbCgyMSwgdGhpcywgJ3B0cionLCAmcGFyZW50V2luZG93IDo9IDApLCBwYXJlbnRXaW5kb3cpDQoJCQlzZXQgPT4gQ29tQ2FsbCgyMiwgdGhpcywgJ3B0cicsIFZhbHVlKQ0KCQl9DQoJCU5vdGlmeVBhcmVudFdpbmRvd1Bvc2l0aW9uQ2hhbmdlZCgpID0+IENvbUNhbGwoMjMsIHRoaXMpDQoJCUNsb3NlKCkgPT4gQ29tQ2FsbCgyNCwgdGhpcykNCgkJQ29yZVdlYlZpZXcyID0+IChDb21DYWxsKDI1LCB0aGlzLCAncHRyKicsIGNvcmVXZWJWaWV3MiA6PSBXZWJWaWV3Mi5Db3JlKCkpLCBjb3JlV2ViVmlldzIpDQoNCgkJc3RhdGljIElJRF8yIDo9ICd7Yzk3OTkwM2UtZDRjYS00MjI4LTkyZWItNDdlZTNmYTk2ZWFifScNCgkJRGVmYXVsdEJhY2tncm91bmRDb2xvciB7DQoJCQlnZXQgPT4gKENvbUNhbGwoMjYsIHRoaXMsICd1aW50KicsICZiYWNrZ3JvdW5kQ29sb3IgOj0gMCksIGJhY2tncm91bmRDb2xvcikNCgkJCXNldCA9PiBDb21DYWxsKDI3LCB0aGlzLCAndWludCcsIFZhbHVlKQ0KCQl9DQoNCgkJc3RhdGljIElJRF8zIDo9ICd7Zjk2MTQ3MjQtNWQyYi00MWRjLWFlZjctNzNkNjJiNTE1NDNifScNCgkJUmFzdGVyaXphdGlvblNjYWxlIHsNCgkJCWdldCA9PiAoQ29tQ2FsbCgyOCwgdGhpcywgJ2RvdWJsZSonLCAmc2NhbGUgOj0gMCksIHNjYWxlKQ0KCQkJc2V0ID0+IENvbUNhbGwoMjksIHRoaXMsICdkb3VibGUnLCBWYWx1ZSkNCgkJfQ0KCQlTaG91bGREZXRlY3RNb25pdG9yU2NhbGVDaGFuZ2VzIHsNCgkJCWdldCA9PiAoQ29tQ2FsbCgzMCwgdGhpcywgJ2ludConLCAmdmFsdWUgOj0gMCksIHZhbHVlKQ0KCQkJc2V0ID0+IENvbUNhbGwoMzEsIHRoaXMsICdpbnQnLCBWYWx1ZSkNCgkJfQ0KCQkvKiogQHBhcmFtIHsoc2VuZGVyOiBXZWJWaWV3Mi5Db250cm9sbGVyLCBhcmdzOiBJVW5rbm93bikgPT4gdm9pZH0gZXZlbnRIYW5kbGVyICovDQoJCWFkZF9SYXN0ZXJpemF0aW9uU2NhbGVDaGFuZ2VkKGV2ZW50SGFuZGxlcikgPT4gKENvbUNhbGwoMzIsIHRoaXMsICdwdHInLCBldmVudEhhbmRsZXIsICdpbnQ2NConLCAmdG9rZW4gOj0gMCksIHRva2VuKQk7IElDb3JlV2ViVmlldzJSYXN0ZXJpemF0aW9uU2NhbGVDaGFuZ2VkRXZlbnRIYW5kbGVyDQoJCXJlbW92ZV9SYXN0ZXJpemF0aW9uU2NhbGVDaGFuZ2VkKHRva2VuKSA9PiBDb21DYWxsKDMzLCB0aGlzLCAnaW50NjQnLCB0b2tlbikNCgkJQm91bmRzTW9kZSB7DQoJCQlnZXQgPT4gKENvbUNhbGwoMzQsIHRoaXMsICdpbnQqJywgJmJvdW5kc01vZGUgOj0gMCksIGJvdW5kc01vZGUpCTsgQ09SRVdFQlZJRVcyX0JPVU5EU19NT0RFDQoJCQlzZXQgPT4gQ29tQ2FsbCgzNSwgdGhpcywgJ2ludCcsIFZhbHVlKQ0KCQl9DQoNCgkJc3RhdGljIElJRF80IDo9ICd7OTdkNDE4ZDUtYTQyNi00ZTQ5LWExNTEtZTFhMTBmMzI3ZDllfScNCgkJQWxsb3dFeHRlcm5hbERyb3Agew0KCQkJZ2V0ID0+IChDb21DYWxsKDM2LCB0aGlzLCAnaW50KicsICZ2YWx1ZSA6PSAwKSwgdmFsdWUpDQoJCQlzZXQgPT4gQ29tQ2FsbCgzNywgdGhpcywgJ2ludCcsIFZhbHVlKQ0KCQl9DQoJfQ0KCWNsYXNzIENvbnRyb2xsZXJPcHRpb25zIGV4dGVuZHMgV2ViVmlldzIuQmFzZSB7DQoJCXN0YXRpYyBJSUQgOj0gJ3sxMmFhZTYxNi04Y2NiLTQ0ZWMtYmNiMy1lYjE4MzE4ODE2MzV9Jw0KCQlQcm9maWxlTmFtZSB7DQoJCQlnZXQgPT4gKENvbUNhbGwoMywgdGhpcywgJ3B0cionLCAmdmFsdWUgOj0gMCksIENvVGFza01lbV9TdHJpbmcodmFsdWUpKQ0KCQkJc2V0ID0+IENvbUNhbGwoNCwgdGhpcywgJ3dzdHInLCBWYWx1ZSkNCgkJfQ0KCQlJc0luUHJpdmF0ZU1vZGVFbmFibGVkIHsNCgkJCWdldCA9PiAoQ29tQ2FsbCg1LCB0aGlzLCAnaW50KicsICZ2YWx1ZSA6PSAwKSwgdmFsdWUpDQoJCQlzZXQgPT4gQ29tQ2FsbCg2LCB0aGlzLCAnaW50JywgVmFsdWUpDQoJCX0NCg0KCQlzdGF0aWMgSUlEXzIgOj0gJ3swNmM5OTFkOC05ZTdlLTExZWQtYThmYy0wMjQyYWMxMjAwMDJ9Jw0KCQlTY3JpcHRMb2NhbGUgew0KCQkJZ2V0ID0+IChDb21DYWxsKDcsIHRoaXMsICdwdHIqJywgJnZhbHVlIDo9IDApLCBDb1Rhc2tNZW1fU3RyaW5nKHZhbHVlKSkNCgkJCXNldCA9PiBDb21DYWxsKDgsIHRoaXMsICd3c3RyJywgVmFsdWUpDQoJCX0NCgl9DQoJY2xhc3MgQ29udGVudExvYWRpbmdFdmVudEFyZ3MgZXh0ZW5kcyBXZWJWaWV3Mi5CYXNlIHsNCgkJc3RhdGljIElJRCA6PSAnezBjOGExMjc1LTliNmItNDkwMS04N2FkLTcwZGYyNWJhZmE2ZX0nDQoJCUlzRXJyb3JQYWdlID0+IChDb21DYWxsKDMsIHRoaXMsICdpbnQqJywgJmlzRXJyb3JQYWdlIDo9IDApLCBpc0Vycm9yUGFnZSkNCgkJTmF2aWdhdGlvbklkID0+IChDb21DYWxsKDQsIHRoaXMsICdpbnQ2NConLCAmbmF2aWdhdGlvbklkIDo9IDApLCBuYXZpZ2F0aW9uSWQpDQoJfQ0KCWNsYXNzIENvbnRleHRNZW51SXRlbSBleHRlbmRzIFdlYlZpZXcyLkJhc2Ugew0KCQlzdGF0aWMgSUlEIDo9ICd7N2FlZDQ5ZTMtYTkzZi00OTdhLTgxMWMtNzQ5YzZiNmI2YzY1fScNCgkJTmFtZSA9PiAoQ29tQ2FsbCgzLCB0aGlzLCAncHRyKicsICZ2YWx1ZSA6PSAwKSwgQ29UYXNrTWVtX1N0cmluZyh2YWx1ZSkpDQoJCUxhYmVsID0+IChDb21DYWxsKDQsIHRoaXMsICdwdHIqJywgJnZhbHVlIDo9IDApLCBDb1Rhc2tNZW1fU3RyaW5nKHZhbHVlKSkNCgkJQ29tbWFuZElkID0+IChDb21DYWxsKDUsIHRoaXMsICdpbnQqJywgJnZhbHVlIDo9IDApLCB2YWx1ZSkNCgkJU2hvcnRjdXRLZXlEZXNjcmlwdGlvbiA9PiAoQ29tQ2FsbCg2LCB0aGlzLCAncHRyKicsICZ2YWx1ZSA6PSAwKSwgQ29UYXNrTWVtX1N0cmluZyh2YWx1ZSkpDQoJCUljb24gPT4gKENvbUNhbGwoNywgdGhpcywgJ3B0cionLCB2YWx1ZSA6PSBXZWJWaWV3Mi5TdHJlYW0oKSksIHZhbHVlKQ0KCQlLaW5kID0+IChDb21DYWxsKDgsIHRoaXMsICdpbnQqJywgJnZhbHVlIDo9IDApLCB2YWx1ZSkNCgkJSXNFbmFibGVkIHsNCgkJCXNldCA9PiBDb21DYWxsKDksIHRoaXMsICdpbnQnLCBWYWx1ZSkNCgkJCWdldCA9PiAoQ29tQ2FsbCgxMCwgdGhpcywgJ2ludConLCAmdmFsdWUgOj0gMCksIHZhbHVlKQ0KCQl9DQoJCUlzQ2hlY2tlZCB7DQoJCQlzZXQgPT4gQ29tQ2FsbCgxMSwgdGhpcywgJ2ludCcsIFZhbHVlKQ0KCQkJZ2V0ID0+IChDb21DYWxsKDEyLCB0aGlzLCAnaW50KicsICZ2YWx1ZSA6PSAwKSwgdmFsdWUpDQoJCX0NCgkJQ2hpbGRyZW4gPT4gKENvbUNhbGwoMTMsIHRoaXMsICdwdHIqJywgdmFsdWUgOj0gV2ViVmlldzIuQ29udGV4dE1lbnVJdGVtQ29sbGVjdGlvbigpKSwgdmFsdWUpDQoJCS8qKiBAcGFyYW0geyhzZW5kZXI6IFdlYlZpZXcyLkNvbnRleHRNZW51SXRlbSwgYXJnczogSVVua25vd24pID0+IHZvaWR9IGV2ZW50SGFuZGxlciAqLw0KCQlhZGRfQ3VzdG9tSXRlbVNlbGVjdGVkKGV2ZW50SGFuZGxlcikgPT4gKENvbUNhbGwoMTQsIHRoaXMsICdwdHInLCBldmVudEhhbmRsZXIsICdpbnQ2NConLCAmdG9rZW4gOj0gMCksIHRva2VuKQ0KCQlyZW1vdmVfQ3VzdG9tSXRlbVNlbGVjdGVkKHRva2VuKSA9PiBDb21DYWxsKDE1LCB0aGlzLCAnaW50NjQnLCB0b2tlbikNCgl9DQoJY2xhc3MgQ29udGV4dE1lbnVJdGVtQ29sbGVjdGlvbiBleHRlbmRzIFdlYlZpZXcyLkxpc3Qgew0KCQlzdGF0aWMgSUlEIDo9ICd7ZjU2MmEyZjUtYzQxNS00NWNmLWI5MDktZDRiN2MxZTI3NmQzfScNCgkJQ291bnQgPT4gKENvbUNhbGwoMywgdGhpcywgJ3VpbnQqJywgJnZhbHVlIDo9IDApLCB2YWx1ZSkNCgkJR2V0VmFsdWVBdEluZGV4KGluZGV4KSA9PiAoQ29tQ2FsbCg0LCB0aGlzLCAndWludCcsIGluZGV4LCAncHRyKicsIHZhbHVlIDo9IFdlYlZpZXcyLkNvbnRleHRNZW51SXRlbSgpKSwgdmFsdWUpDQoJCVJlbW92ZVZhbHVlQXRJbmRleChpbmRleCkgPT4gQ29tQ2FsbCg1LCB0aGlzLCAndWludCcsIGluZGV4KQ0KCQlJbnNlcnRWYWx1ZUF0SW5kZXgoaW5kZXgsIHZhbHVlKSA9PiBDb21DYWxsKDYsIHRoaXMsICd1aW50JywgaW5kZXgsICdwdHInLCB2YWx1ZSkNCgl9DQoJY2xhc3MgQ29udGV4dE1lbnVSZXF1ZXN0ZWRFdmVudEFyZ3MgZXh0ZW5kcyBXZWJWaWV3Mi5CYXNlIHsNCgkJc3RhdGljIElJRCA6PSAne2ExZDMwOWVlLWMwM2YtMTFlYi04NTI5LTAyNDJhYzEzMDAwM30nDQoJCU1lbnVJdGVtcyA9PiAoQ29tQ2FsbCgzLCB0aGlzLCAncHRyKicsIHZhbHVlIDo9IFdlYlZpZXcyLkNvbnRleHRNZW51SXRlbUNvbGxlY3Rpb24oKSksIHZhbHVlKQ0KCQlDb250ZXh0TWVudVRhcmdldCA9PiAoQ29tQ2FsbCg0LCB0aGlzLCAncHRyKicsIHZhbHVlIDo9IFdlYlZpZXcyLkNvbnRleHRNZW51VGFyZ2V0KCkpLCB2YWx1ZSkNCgkJTG9jYXRpb24gPT4gKENvbUNhbGwoNSwgdGhpcywgJ2ludDY0KicsICZ2YWx1ZSA6PSAwKSwgdmFsdWUpDQoJCVNlbGVjdGVkQ29tbWFuZElkIHsNCgkJCXNldCA9PiBDb21DYWxsKDYsIHRoaXMsICdpbnQnLCBWYWx1ZSkNCgkJCWdldCA9PiAoQ29tQ2FsbCg3LCB0aGlzLCAnaW50KicsICZ2YWx1ZSA6PSAwKSwgdmFsdWUpDQoJCX0NCgkJSGFuZGxlZCB7DQoJCQlzZXQgPT4gQ29tQ2FsbCg4LCB0aGlzLCAnaW50JywgVmFsdWUpDQoJCQlnZXQgPT4gKENvbUNhbGwoOSwgdGhpcywgJ2ludConLCAmdmFsdWUgOj0gMCksIHZhbHVlKQ0KCQl9DQoJCUdldERlZmVycmFsKCkgPT4gKENvbUNhbGwoMTAsIHRoaXMsICdwdHIqJywgZGVmZXJyYWwgOj0gV2ViVmlldzIuRGVmZXJyYWwoKSksIGRlZmVycmFsKQ0KCX0NCgljbGFzcyBDb250ZXh0TWVudVRhcmdldCBleHRlbmRzIFdlYlZpZXcyLkJhc2Ugew0KCQlzdGF0aWMgSUlEIDo9ICd7Yjg2MTFkOTktZWVkNi00ZjNmLTkwMmMtYTE5ODUwMmFkNDcyfScNCgkJS2luZCA9PiAoQ29tQ2FsbCgzLCB0aGlzLCAnaW50KicsICZ2YWx1ZSA6PSAwKSwgdmFsdWUpCTsgQ09SRVdFQlZJRVcyX0NPTlRFWFRfTUVOVV9UQVJHRVRfS0lORA0KCQlJc0VkaXRhYmxlID0+IChDb21DYWxsKDQsIHRoaXMsICdpbnQqJywgJnZhbHVlIDo9IDApLCB2YWx1ZSkNCgkJSXNSZXF1ZXN0ZWRGb3JNYWluRnJhbWUgPT4gKENvbUNhbGwoNSwgdGhpcywgJ2ludConLCAmdmFsdWUgOj0gMCksIHZhbHVlKQ0KCQlQYWdlVXJpID0+IChDb21DYWxsKDYsIHRoaXMsICdwdHIqJywgJnZhbHVlIDo9IDApLCBDb1Rhc2tNZW1fU3RyaW5nKHZhbHVlKSkNCgkJRnJhbWVVcmkgPT4gKENvbUNhbGwoNywgdGhpcywgJ3B0cionLCAmdmFsdWUgOj0gMCksIENvVGFza01lbV9TdHJpbmcodmFsdWUpKQ0KCQlIYXNMaW5rVXJpID0+IChDb21DYWxsKDgsIHRoaXMsICdpbnQqJywgJnZhbHVlIDo9IDApLCB2YWx1ZSkNCgkJTGlua1VyaSA9PiAoQ29tQ2FsbCg5LCB0aGlzLCAncHRyKicsICZ2YWx1ZSA6PSAwKSwgQ29UYXNrTWVtX1N0cmluZyh2YWx1ZSkpDQoJCUhhc0xpbmtUZXh0ID0+IChDb21DYWxsKDEwLCB0aGlzLCAnaW50KicsICZ2YWx1ZSA6PSAwKSwgdmFsdWUpDQoJCUxpbmtUZXh0ID0+IChDb21DYWxsKDExLCB0aGlzLCAncHRyKicsICZ2YWx1ZSA6PSAwKSwgQ29UYXNrTWVtX1N0cmluZyh2YWx1ZSkpDQoJCUhhc1NvdXJjZVVyaSA9PiAoQ29tQ2FsbCgxMiwgdGhpcywgJ2ludConLCAmdmFsdWUgOj0gMCksIHZhbHVlKQ0KCQlTb3VyY2VVcmkgPT4gKENvbUNhbGwoMTMsIHRoaXMsICdwdHIqJywgJnZhbHVlIDo9IDApLCBDb1Rhc2tNZW1fU3RyaW5nKHZhbHVlKSkNCgkJSGFzU2VsZWN0aW9uID0+IChDb21DYWxsKDE0LCB0aGlzLCAnaW50KicsICZ2YWx1ZSA6PSAwKSwgdmFsdWUpDQoJCVNlbGVjdGlvbiA9PiAoQ29tQ2FsbCgxNSwgdGhpcywgJ3B0cionLCAmdmFsdWUgOj0gMCksIENvVGFza01lbV9TdHJpbmcodmFsdWUpKQ0KCX0NCgljbGFzcyBDb29raWUgZXh0ZW5kcyBXZWJWaWV3Mi5CYXNlIHsNCgkJc3RhdGljIElJRCA6PSAne0FEMjZENkJFLTE0ODYtNDNFNi1CRjg3LUEyMDM0MDA2Q0EyMX0nDQoJCU5hbWUgPT4gKENvbUNhbGwoMywgdGhpcywgJ3B0cionLCAmbmFtZSA6PSAwKSwgQ29UYXNrTWVtX1N0cmluZyhuYW1lKSkNCgkJVmFsdWUgew0KCQkJZ2V0ID0+IChDb21DYWxsKDQsIHRoaXMsICdwdHIqJywgJnZhbHVlIDo9IDApLCBDb1Rhc2tNZW1fU3RyaW5nKHZhbHVlKSkNCgkJCXNldCA9PiBDb21DYWxsKDUsIHRoaXMsICd3c3RyJywgVmFsdWUpDQoJCX0NCgkJRG9tYWluID0+IChDb21DYWxsKDYsIHRoaXMsICdwdHIqJywgJmRvbWFpbiA6PSAwKSwgQ29UYXNrTWVtX1N0cmluZyhkb21haW4pKQ0KCQlQYXRoID0+IChDb21DYWxsKDcsIHRoaXMsICdwdHIqJywgJnBhdGggOj0gMCksIENvVGFza01lbV9TdHJpbmcocGF0aCkpDQoJCUV4cGlyZXMgew0KCQkJZ2V0ID0+IChDb21DYWxsKDgsIHRoaXMsICdkb3VibGUqJywgJmV4cGlyZXMgOj0gMCksIGV4cGlyZXMpDQoJCQlzZXQgPT4gQ29tQ2FsbCg5LCB0aGlzLCAnZG91YmxlJywgVmFsdWUpDQoJCX0NCgkJSXNIdHRwT25seSB7DQoJCQlnZXQgPT4gKENvbUNhbGwoMTAsIHRoaXMsICdpbnQqJywgJmlzSHR0cE9ubHkgOj0gMCksIGlzSHR0cE9ubHkpDQoJCQlzZXQgPT4gQ29tQ2FsbCgxMSwgdGhpcywgJ2ludCcsIFZhbHVlKQ0KCQl9DQoJCVNhbWVTaXRlIHsNCgkJCWdldCA9PiAoQ29tQ2FsbCgxMiwgdGhpcywgJ2ludConLCAmc2FtZVNpdGUgOj0gMCksIHNhbWVTaXRlKQk7IENPUkVXRUJWSUVXMl9DT09LSUVfU0FNRV9TSVRFX0tJTkQNCgkJCXNldCA9PiBDb21DYWxsKDEzLCB0aGlzLCAnaW50JywgVmFsdWUpDQoJCX0NCgkJSXNTZWN1cmUgew0KCQkJZ2V0ID0+IChDb21DYWxsKDE0LCB0aGlzLCAnaW50KicsICZpc1NlY3VyZSA6PSAwKSwgaXNTZWN1cmUpDQoJCQlzZXQgPT4gQ29tQ2FsbCgxNSwgdGhpcywgJ2ludCcsIFZhbHVlKQ0KCQl9DQoJCUlzU2Vzc2lvbiA9PiAoQ29tQ2FsbCgxNiwgdGhpcywgJ2ludConLCAmaXNTZXNzaW9uIDo9IDApLCBpc1Nlc3Npb24pDQoJfQ0KCWNsYXNzIENvb2tpZUxpc3QgZXh0ZW5kcyBXZWJWaWV3Mi5MaXN0IHsNCgkJc3RhdGljIElJRCA6PSAne0Y3RjZGNzE0LTVEMkEtNDNDNi05NTAzLTM0NkVDRTAyRDE4Nn0nDQoJCUNvdW50ID0+IChDb21DYWxsKDMsIHRoaXMsICd1aW50KicsICZjb3VudCA6PSAwKSwgY291bnQpDQoJCUdldFZhbHVlQXRJbmRleChpbmRleCkgPT4gKENvbUNhbGwoNCwgdGhpcywgJ3VpbnQnLCBpbmRleCwgJ3B0cionLCBjb29raWUgOj0gV2ViVmlldzIuQ29va2llKCkpLCBjb29raWUpDQoJfQ0KCWNsYXNzIENvb2tpZU1hbmFnZXIgZXh0ZW5kcyBXZWJWaWV3Mi5CYXNlIHsNCgkJc3RhdGljIElJRCA6PSAnezE3N0NEOUU3LUI2RjUtNDUxQS05NEEwLTVEN0EzQTRDNDE0MX0nDQoJCUNyZWF0ZUNvb2tpZShuYW1lLCB2YWx1ZSwgZG9tYWluLCBwYXRoKSA9PiAoQ29tQ2FsbCgzLCB0aGlzLCAnd3N0cicsIG5hbWUsICd3c3RyJywgdmFsdWUsICd3c3RyJywgZG9tYWluLCAnd3N0cicsIHBhdGgsICdwdHIqJywgY29va2llIDo9IFdlYlZpZXcyLkNvb2tpZSgpKSwgY29va2llKQ0KCQlDb3B5Q29va2llKGNvb2tpZVBhcmFtKSA9PiAoQ29tQ2FsbCg0LCB0aGlzLCAncHRyJywgY29va2llUGFyYW0sICdwdHIqJywgY29va2llIDo9IFdlYlZpZXcyLkNvb2tpZSgpKSwgY29va2llKQk7IElDb3JlV2ViVmlldzJDb29raWUNCgkJLyoqIEByZXR1cm5zIHtQcm9taXNlPFdlYlZpZXcyLkNvb2tpZUxpc3Q+fSAqLw0KCQlHZXRDb29raWVzQXN5bmModXJpKSA9PiAoQ29tQ2FsbCg1LCB0aGlzLCAnd3N0cicsIHVyaSwgJ3B0cicsIFdlYlZpZXcyLkFzeW5jSGFuZGxlcigmcCwgV2ViVmlldzIuQ29va2llTGlzdCkpLCBwKQ0KCQlBZGRPclVwZGF0ZUNvb2tpZShjb29raWUpID0+IENvbUNhbGwoNiwgdGhpcywgJ3B0cicsIGNvb2tpZSkJOyBJQ29yZVdlYlZpZXcyQ29va2llDQoJCURlbGV0ZUNvb2tpZShjb29raWUpID0+IENvbUNhbGwoNywgdGhpcywgJ3B0cicsIGNvb2tpZSkJOyBJQ29yZVdlYlZpZXcyQ29va2llDQoJCURlbGV0ZUNvb2tpZXMobmFtZSwgdXJpKSA9PiBDb21DYWxsKDgsIHRoaXMsICd3c3RyJywgbmFtZSwgJ3dzdHInLCB1cmkpDQoJCURlbGV0ZUNvb2tpZXNXaXRoRG9tYWluQW5kUGF0aChuYW1lLCBkb21haW4sIHBhdGgpID0+IENvbUNhbGwoOSwgdGhpcywgJ3dzdHInLCBuYW1lLCAnd3N0cicsIGRvbWFpbiwgJ3dzdHInLCBwYXRoKQ0KCQlEZWxldGVBbGxDb29raWVzKCkgPT4gQ29tQ2FsbCgxMCwgdGhpcykNCgl9DQoJY2xhc3MgQ29yZSBleHRlbmRzIFdlYlZpZXcyLkJhc2Ugew0KCQlzdGF0aWMgSUlEIDo9ICd7NzZlY2VhY2ItMDQ2Mi00ZDk0LWFjODMtNDIzYTY3OTM3NzVlfScNCgkJLyoqDQoJCSAqIC0gQWRkIGdsb2JhbCB2YXJpYWJsZSBgYWhrID0gY2hyb21lLndlYnZpZXcuaG9zdE9iamVjdHNgLg0KCQkgKiAtIEFkZCBgY2FsbChtZXRob2Q9J2NhbGwnLC4uLmFyZ3MpYCBtZXRob2QgZm9yIGBLbm93blJlbW90ZVByb3h5YCBvYmplY3RzLg0KCQkgKiAtIEFkZCBgZ2V0KHByb3A9J19fSXRlbScsLi4uYXJncylgIG1ldGhvZCBmb3IgYEtub3duUmVtb3RlUHJveHlgIG9iamVjdHMuDQoJCSAqIC0gQWRkIGBzZXQocHJvcD0nX19JdGVtJywuLi5hcmdzLHZhbClgIG1ldGhvZCBmb3IgYEtub3duUmVtb3RlUHJveHlgIG9iamVjdHMuDQoJCSAqIC0gQWRkIGB0aGVuYCBtZXRob2QgZm9yIGBLbm93blJlbW90ZVByb3h5YCBvYmplY3RzLg0KCQkgKiAjIyMjIENvbXBhcmVkIHdpdGggdGhlIG9yaWdpbmFsIGludm9raW5nIG1ldGhvZA0KCQkgKiBgYGBqYXZhc2NyaXB0DQoJCSAqIGxldCBhc3luY0FyciA9IGF3YWl0IGFoay5hcnJheU9iaiwgc3luY0FyciA9IGFoay5zeW5jLmFycmF5T2JqDQoJCSAqIC8vIGNhbGwgb2JqJ3MgbWV0aG9kDQoJCSAqIGF3YWl0IGFzeW5jQXJyLmNhbGwoJ1B1c2gnLDEsMiwzKQkvLyBuZXcNCgkJICogYXdhaXQgYXN5bmNBcnIuUHVzaChhc3luY0FyciwxLDIsMykJLy8gb3JpZ2luYWwNCgkJICogLy8gZ2V0IG9iaidzIG5vbi1leGlzdGVudCBwcm9wZXJ0eQ0KCQkgKiBzeW5jQXJyLmdldCgnbm9uX2V4aXN0ZW50JykJLy8gbmV3LCB1bmRlZmluZWQNCgkJICogc3luY0Fyci5ub25fZXhpc3RlbnQJCS8vIG9yaWdpbmFsLCBQcm94eShmdW5jdGlvbikNCgkJICogLy8gZ2V0IG9iaidzIHByb3BlcnR5IHdpdGhvdXQgcGFyYW1zDQoJCSAqIHN5bmNBcnIuZ2V0KCdMZW5ndGgnKQkvLyBuZXcNCgkJICogc3luY0Fyci5MZW5ndGgJCS8vIG9yaWdpbmFsDQoJCSAqIC8vIHNldCBvYmoncyBwcm9wZXJ0eSB3aXRob3V0IHBhcmFtcw0KCQkgKiBzeW5jQXJyLnNldCgnTGVuZ3RoJywyKQkvLyBuZXcNCgkJICogc3luY0Fyci5MZW5ndGggPSAyCS8vIG9yaWdpbmFsDQoJCSAqIC8vIGdldCBvYmoncyBkeW5hbWljIHByb3BlcnR5IHdpdGggcGFyYW1zDQoJCSAqIHN5bmNBcnIuZ2V0KG51bGwsMikJLy8gbmV3DQoJCSAqIHN5bmNBcnIuR2V0T3duUHJvcERlc2Moc3luY0Fyci5CYXNlLCdfX0l0ZW0nKS5HZXQoc3luY0FyciwyKQkvLyBvcmlnaW5hbA0KCQkgKiAvLyBzZXQgb2JqJ3MgZHluYW1pYyBwcm9wZXJ0eSB3aXRoIHBhcmFtcw0KCQkgKiBzeW5jQXJyLnNldChudWxsLDIsMCkJLy8gbmV3DQoJCSAqIHN5bmNBcnIuR2V0T3duUHJvcERlc2Moc3luY0Fyci5CYXNlLCdfX0l0ZW0nKS5TZXQoc3luY0FyciwwLDIpCS8vIG9yaWdpbmFsDQoJCSAqIC8vIGF3YWl0IGFoaydzIHByb21pc2UNCgkJICogbGV0IHAgPSBhaGsucHJvbWlzZU9iag0KCQkgKiBhd2FpdCBwCS8vIG5ldw0KCQkgKiBhd2FpdCBuZXcgUHJvbWlzZSgocmVzb2x2ZSxyZWplY3QpID0+IHAuVGhlbihwLHJlc29sdmUscmVqZWN0KSkJLy8gb3JpZ2luYWwNCgkJICogYGBgDQoJCSAqLw0KCQlJbmplY3RBaGtDb21wb25lbnQoKSB7DQoJCQlzdGF0aWMgXyA6PSAhUHJvbWlzZS5Qcm90b3R5cGUuRGVmaW5lUHJvcCgnBXRoZW4nLCB7DQoJCQkJY2FsbDogKHRoaXMsIHJlc29sdmUsIHJlamVjdCkgPT4gIXRoaXMub25TZXR0bGVkKHJlc29sdmUsIGVyciA9PiByZWplY3QoSXNPYmplY3QoZXJyKSA/IGVyci5NZXNzYWdlIDogZXJyKSkgfSkNCgkJCXNjcmlwdCA6PSAnDQoJCQkoDQoJCQkoZnVuY3Rpb24gKCkgew0KCQkJCWNvbnN0IHsgb2JqZWN0U2VyaWFsaXplcjogT1MsIHJlbW90ZU1lc3NlbmdlcjogUk0sIHJlbW90ZVJlZlRyYWNrZXI6IFJSVCB9ID0gKHdpbmRvdy5haGsgPSBjaHJvbWUud2Vidmlldy5ob3N0T2JqZWN0cykuX29wdGlvbnM7DQoJCQkJaWYgKE9iamVjdC5oYXNPd24oT1MsICdjcmVhdGVLbm93blJlbW90ZVByb3h5JykpDQoJCQkJCXJldHVybjsNCgkJCQljb25zdCBhaGtfZm5zID0gWydjYWxsJywgJ2dldCcsICdzZXQnXTsNCgkJCQljb25zdCB7IF9zZXJpYWxpemF0aW9uT3B0aW9uc1Byb3BlcnR5TmFtZTogU09QTiwgY3JlYXRlS25vd25SZW1vdGVQcm94eTogQ0tSUCB9ID0gT1M7DQoJCQkJYWhrLl9vcHRpb25zLmZvcmNlTG9jYWxQcm9wZXJ0aWVzLnB1c2goLi4uYWhrX2Zucyk7DQoJCQkJT1MuY3JlYXRlS25vd25SZW1vdGVQcm94eSA9IGZ1bmN0aW9uIChvYmpJZCwgdGhlbmFibGUsIHN5bmMsIGRlYnVnSWQsIGJhc2lzLCBob3N0S2V5TmFtZXMpIHsNCgkJCQkJY29uc3QgcHJveHkgPSBDS1JQLmNhbGwoT1MsIG9iaklkLCB0aGVuYWJsZSwgc3luYywgZGVidWdJZCwgYmFzaXMsIGhvc3RLZXlOYW1lcyk7DQoJCQkJCWlmICghYmFzaXMgJiYgb2JqSWQpIHsNCgkJCQkJCWZvciAoY29uc3QgayBvZiBhaGtfZm5zKSBwcm94eS5zZXRMb2NhbFByb3BlcnR5KGssIGludm9rZS5iaW5kKHByb3h5LCBrID09PSAnY2FsbCcgPyAnYXBwbHknIDogaykpDQoJCQkJCQl0aGVuYWJsZSB8fCBwcm94eS5zZXRMb2NhbFByb3BlcnR5KCd0aGVuJywgdGhlbi5iaW5kKHByb3h5KSk7DQoJCQkJCX0NCgkJCQkJcmV0dXJuIHByb3h5Ow0KCQkJCX07DQoJCQkJZnVuY3Rpb24gdGhlbihvbmZ1bGZpbGxlZCwgb25yZWplY3RlZCkgew0KCQkJCQlyZXR1cm4gbmV3IFByb21pc2UoYXN5bmMgKHJlc29sdmUsIHJlamVjdCkgPT4gew0KCQkJCQkJbGV0IHRoZW5hYmxlID0gdGhpcy5fZGVidWdJZC5hdCgtMSkgIT09ICdceDA1dGhlbigpJzsNCgkJCQkJCXRyeSB7IHRoZW5hYmxlICYmIGF3YWl0IGludm9rZS5jYWxsKHRoaXMsICdhcHBseScsICdceDA1dGhlbicsIHJlc29sdmUsIGVyciA9PiByZWplY3QobmV3IEVycm9yKGVycikpKTsgfQ0KCQkJCQkJY2F0Y2ggeyB0aGVuYWJsZSA9IGZhbHNlOyB9DQoJCQkJCQl0aGVuYWJsZSB8fCAoZGVsZXRlIHRoaXMudGhlbiwgcmVzb2x2ZSh0aGlzKSk7DQoJCQkJCX0pLnRoZW4ob25mdWxmaWxsZWQsIG9ucmVqZWN0ZWQpOw0KCQkJCX0NCgkJCQlmdW5jdGlvbiBpbnZva2Uob3BlcmF0aW9uLCBtZXRob2ROYW1lLCAuLi5wYXJhbWV0ZXJzKSB7DQoJCQkJCWNvbnN0IGRlYnVnSWQgPSB0aGlzLl9kZWJ1Z0lkLmNvbmNhdChvcGVyYXRpb24gPT09ICdhcHBseScgPyAobWV0aG9kTmFtZSA/Pz0gJycpICsgJygpJyA6IG1ldGhvZE5hbWUgfHw9ICdfX2l0ZW0nKTsNCgkJCQkJaWYgKCFPYmplY3QuaGFzT3duKHRoaXMsICdfcmVzdWx0T2JqZWN0SWQnKSkgew0KCQkJCQkJY29uc3QgcHJvbWlzZSA9IFJNLnBvc3RSZXF1ZXN0TWVzc2FnZSh0aGlzLl9yZW1vdGVPYmplY3RJZCwgbWV0aG9kTmFtZSwgb3BlcmF0aW9uLCBwYXJhbWV0ZXJzKTsNCgkJCQkJCWNvbnN0IHJlc29sdmUgPSBnZXRSZXN1bHQuYmluZChudWxsLCBmYWxzZSwgcHJvbWlzZS5fY2FsbElkLCBvcGVyYXRpb24sIGRlYnVnSWQpOw0KCQkJCQkJcmV0dXJuIHByb21pc2UudGhlbihyZXNvbHZlLCByZXNvbHZlKTsNCgkJCQkJfQ0KCQkJCQljb25zdCBjYWxsSWQgPSBSTS5faWRHZW5lcmF0b3IuZ2V0TmV4dElkKCk7DQoJCQkJCXJldHVybiBnZXRSZXN1bHQodHJ1ZSwgb3BlcmF0aW9uLCBjYWxsSWQsIGRlYnVnSWQsIFJNLl9wb3N0UmVtb3RlUHJveHlNZXNzYWdlKHRoaXMuX3Jlc3VsdE9iamVjdElkLCBtZXRob2ROYW1lLCB7DQoJCQkJCQlraW5kOiAicmVxdWVzdCIsIG9wdGlvbnM6IHsgb3BlcmF0aW9uLCB0eXBlZEFycmF5SW5kaWNlczogUk0uR2V0VHlwZWRBcnJheVBhcmFtZXRlcnNJbmRpY2VzKHBhcmFtZXRlcnMpIH0sIHBhcmFtZXRlcnMsDQoJCQkJCX0sIGNhbGxJZCwgdHJ1ZSkpOw0KCQkJCX0NCgkJCQlmdW5jdGlvbiBnZXRSZXN1bHQoc3luYywgb3BlcmF0aW9uLCBjYWxsSWQsIGRlYnVnSWQsIHJhd1Jlc3VsdCkgew0KCQkJCQljb25zdCB7IGVycm9yLCBoYXNfb2JqZWN0LCByZXN1bHQgfSA9IHJhd1Jlc3VsdC5wYXJhbWV0ZXJzOw0KCQkJCQlpZiAoZXJyb3IgIT09IHVuZGVmaW5lZCkNCgkJCQkJCXRocm93IG5ldyBFcnJvcihPUy5kZXNlcmlhbGl6ZShzeW5jLCBmYWxzZSwgZGVidWdJZCwgZXJyb3IpKTsNCgkJCQkJaWYgKGhhc19vYmplY3QgJiYgcmVzdWx0Lmhhc093blByb3BlcnR5KFNPUE4pKSB7DQoJCQkJCQlpZiAob3BlcmF0aW9uID09PSAnZ2V0Jykgew0KCQkJCQkJCWNvbnN0IG9wdGlvbnMgPSByZXN1bHRbU09QTl07DQoJCQkJCQkJaWYgKG9wdGlvbnMuc2VxX25vICYmIG9wdGlvbnMuY2FjaGVfYWJsZSAmJiBvcHRpb25zLmdyb3VwSWQgPT09ICduYXRpdmUnKSB7DQoJCQkJCQkJCVJSVC5hZGRTZXF1ZW5jZUlkKG9wdGlvbnMuc2VxX25vKSwgUlJULl9yZWxlYXNlT2JqZWN0c0NhbGxiYWNrKFJSVC5fbWF4UmVtb3RlU2VxdWVuY2VJZCwgb3B0aW9ucy5yZW1vdGVPYmplY3RJZCk7DQoJCQkJCQkJCWRlbGV0ZSBPUy5fcGFyYW1UcmFja2VyW2NhbGxJZF07DQoJCQkJCQkJCXJldHVybiB1bmRlZmluZWQ7DQoJCQkJCQkJfQ0KCQkJCQkJfQ0KCQkJCQkJcmVzdWx0LmNhbGxJZCA9IGNhbGxJZDsNCgkJCQkJfQ0KCQkJCQljb25zdCB2YWwgPSBPUy5kZXNlcmlhbGl6ZShmYWxzZSwgaGFzX29iamVjdCwgZGVidWdJZCwgcmVzdWx0KTsNCgkJCQkJZGVsZXRlIE9TLl9wYXJhbVRyYWNrZXJbY2FsbElkXTsNCgkJCQkJcmV0dXJuIHZhbDsNCgkJCQl9DQoJCQl9KSgpOw0KCQkJKScNCgkJCXRoaXMuRXhlY3V0ZVNjcmlwdEFzeW5jKHNjcmlwdCkNCgkJCXJldHVybiB0aGlzLkFkZFNjcmlwdFRvRXhlY3V0ZU9uRG9jdW1lbnRDcmVhdGVkQXN5bmMoc2NyaXB0KQ0KCQl9DQoJCVNldHRpbmdzID0+IChDb21DYWxsKDMsIHRoaXMsICdwdHIqJywgc2V0dGluZ3MgOj0gV2ViVmlldzIuU2V0dGluZ3MoKSksIHNldHRpbmdzKQ0KCQlTb3VyY2UgPT4gKENvbUNhbGwoNCwgdGhpcywgJ3B0cionLCAmdXJpIDo9IDApLCBDb1Rhc2tNZW1fU3RyaW5nKHVyaSkpDQoJCU5hdmlnYXRlKHVyaSkgPT4gQ29tQ2FsbCg1LCB0aGlzLCAnd3N0cicsIHVyaSkNCgkJTmF2aWdhdGVUb1N0cmluZyhodG1sQ29udGVudCkgPT4gQ29tQ2FsbCg2LCB0aGlzLCAnd3N0cicsIGh0bWxDb250ZW50KQ0KCQkvKiogQHBhcmFtIHsoc2VuZGVyOiBXZWJWaWV3Mi5Db3JlLCBhcmdzOiBXZWJWaWV3Mi5OYXZpZ2F0aW9uU3RhcnRpbmdFdmVudEFyZ3MpID0+IHZvaWR9IGV2ZW50SGFuZGxlciAqLw0KCQlhZGRfTmF2aWdhdGlvblN0YXJ0aW5nKGV2ZW50SGFuZGxlcikgPT4gKENvbUNhbGwoNywgdGhpcywgJ3B0cicsIGV2ZW50SGFuZGxlciwgJ2ludDY0KicsICZ0b2tlbiA6PSAwKSwgdG9rZW4pCTsgSUNvcmVXZWJWaWV3Mk5hdmlnYXRpb25TdGFydGluZ0V2ZW50SGFuZGxlcg0KCQlyZW1vdmVfTmF2aWdhdGlvblN0YXJ0aW5nKHRva2VuKSA9PiBDb21DYWxsKDgsIHRoaXMsICdpbnQ2NCcsIHRva2VuKQ0KCQkvKiogQHBhcmFtIHsoc2VuZGVyOiBXZWJWaWV3Mi5Db3JlLCBhcmdzOiBXZWJWaWV3Mi5Db250ZW50TG9hZGluZ0V2ZW50QXJncykgPT4gdm9pZH0gZXZlbnRIYW5kbGVyICovDQoJCWFkZF9Db250ZW50TG9hZGluZyhldmVudEhhbmRsZXIpID0+IChDb21DYWxsKDksIHRoaXMsICdwdHInLCBldmVudEhhbmRsZXIsICdpbnQ2NConLCAmdG9rZW4gOj0gMCksIHRva2VuKQk7IElDb3JlV2ViVmlldzJDb250ZW50TG9hZGluZ0V2ZW50SGFuZGxlcg0KCQlyZW1vdmVfQ29udGVudExvYWRpbmcodG9rZW4pID0+IENvbUNhbGwoMTAsIHRoaXMsICdpbnQ2NCcsIHRva2VuKQ0KCQkvKiogQHBhcmFtIHsoc2VuZGVyOiBXZWJWaWV3Mi5Db3JlLCBhcmdzOiBXZWJWaWV3Mi5Tb3VyY2VDaGFuZ2VkRXZlbnRBcmdzKSA9PiB2b2lkfSBldmVudEhhbmRsZXIgKi8NCgkJYWRkX1NvdXJjZUNoYW5nZWQoZXZlbnRIYW5kbGVyKSA9PiAoQ29tQ2FsbCgxMSwgdGhpcywgJ3B0cicsIGV2ZW50SGFuZGxlciwgJ2ludDY0KicsICZ0b2tlbiA6PSAwKSwgdG9rZW4pCTsgSUNvcmVXZWJWaWV3MlNvdXJjZUNoYW5nZWRFdmVudEhhbmRsZXINCgkJcmVtb3ZlX1NvdXJjZUNoYW5nZWQodG9rZW4pID0+IENvbUNhbGwoMTIsIHRoaXMsICdpbnQ2NCcsIHRva2VuKQ0KCQkvKiogQHBhcmFtIHsoc2VuZGVyOiBXZWJWaWV3Mi5Db3JlLCBhcmdzOiBJVW5rbm93bikgPT4gdm9pZH0gZXZlbnRIYW5kbGVyICovDQoJCWFkZF9IaXN0b3J5Q2hhbmdlZChldmVudEhhbmRsZXIpID0+IChDb21DYWxsKDEzLCB0aGlzLCAncHRyJywgZXZlbnRIYW5kbGVyLCAnaW50NjQqJywgJnRva2VuIDo9IDApLCB0b2tlbikJOyBJQ29yZVdlYlZpZXcySGlzdG9yeUNoYW5nZWRFdmVudEhhbmRsZXINCgkJcmVtb3ZlX0hpc3RvcnlDaGFuZ2VkKHRva2VuKSA9PiBDb21DYWxsKDE0LCB0aGlzLCAnaW50NjQnLCB0b2tlbikNCgkJLyoqIEBwYXJhbSB7KHNlbmRlcjogV2ViVmlldzIuQ29yZSwgYXJnczogV2ViVmlldzIuTmF2aWdhdGlvbkNvbXBsZXRlZEV2ZW50QXJncykgPT4gdm9pZH0gZXZlbnRIYW5kbGVyICovDQoJCWFkZF9OYXZpZ2F0aW9uQ29tcGxldGVkKGV2ZW50SGFuZGxlcikgPT4gKENvbUNhbGwoMTUsIHRoaXMsICdwdHInLCBldmVudEhhbmRsZXIsICdpbnQ2NConLCAmdG9rZW4gOj0gMCksIHRva2VuKQk7IElDb3JlV2ViVmlldzJOYXZpZ2F0aW9uQ29tcGxldGVkRXZlbnRIYW5kbGVyDQoJCXJlbW92ZV9OYXZpZ2F0aW9uQ29tcGxldGVkKHRva2VuKSA9PiBDb21DYWxsKDE2LCB0aGlzLCAnaW50NjQnLCB0b2tlbikNCgkJLyoqIEBwYXJhbSB7KHNlbmRlcjogV2ViVmlldzIuQ29yZSwgYXJnczogV2ViVmlldzIuTmF2aWdhdGlvblN0YXJ0aW5nRXZlbnRBcmdzKSA9PiB2b2lkfSBldmVudEhhbmRsZXIgKi8NCgkJYWRkX0ZyYW1lTmF2aWdhdGlvblN0YXJ0aW5nKGV2ZW50SGFuZGxlcikgPT4gKENvbUNhbGwoMTcsIHRoaXMsICdwdHInLCBldmVudEhhbmRsZXIsICdpbnQ2NConLCAmdG9rZW4gOj0gMCksIHRva2VuKQk7IElDb3JlV2ViVmlldzJOYXZpZ2F0aW9uU3RhcnRpbmdFdmVudEhhbmRsZXINCgkJcmVtb3ZlX0ZyYW1lTmF2aWdhdGlvblN0YXJ0aW5nKHRva2VuKSA9PiBDb21DYWxsKDE4LCB0aGlzLCAnaW50NjQnLCB0b2tlbikNCgkJLyoqIEBwYXJhbSB7KHNlbmRlcjogV2ViVmlldzIuQ29yZSwgYXJnczogV2ViVmlldzIuTmF2aWdhdGlvbkNvbXBsZXRlZEV2ZW50QXJncykgPT4gdm9pZH0gZXZlbnRIYW5kbGVyICovDQoJCWFkZF9GcmFtZU5hdmlnYXRpb25Db21wbGV0ZWQoZXZlbnRIYW5kbGVyKSA9PiAoQ29tQ2FsbCgxOSwgdGhpcywgJ3B0cicsIGV2ZW50SGFuZGxlciwgJ2ludDY0KicsICZ0b2tlbiA6PSAwKSwgdG9rZW4pCTsgSUNvcmVXZWJWaWV3Mk5hdmlnYXRpb25Db21wbGV0ZWRFdmVudEhhbmRsZXINCgkJcmVtb3ZlX0ZyYW1lTmF2aWdhdGlvbkNvbXBsZXRlZCh0b2tlbikgPT4gQ29tQ2FsbCgyMCwgdGhpcywgJ2ludDY0JywgdG9rZW4pDQoJCS8qKiBAcGFyYW0geyhzZW5kZXI6IFdlYlZpZXcyLkNvcmUsIGFyZ3M6IFdlYlZpZXcyLlNjcmlwdERpYWxvZ09wZW5pbmdFdmVudEFyZ3MpID0+IHZvaWR9IGV2ZW50SGFuZGxlciAqLw0KCQlhZGRfU2NyaXB0RGlhbG9nT3BlbmluZyhldmVudEhhbmRsZXIpID0+IChDb21DYWxsKDIxLCB0aGlzLCAncHRyJywgZXZlbnRIYW5kbGVyLCAnaW50NjQqJywgJnRva2VuIDo9IDApLCB0b2tlbikJOyBJQ29yZVdlYlZpZXcyU2NyaXB0RGlhbG9nT3BlbmluZ0V2ZW50SGFuZGxlcg0KCQlyZW1vdmVfU2NyaXB0RGlhbG9nT3BlbmluZyh0b2tlbikgPT4gQ29tQ2FsbCgyMiwgdGhpcywgJ2ludDY0JywgdG9rZW4pDQoJCS8qKiBAcGFyYW0geyhzZW5kZXI6IFdlYlZpZXcyLkNvcmUsIGFyZ3M6IFdlYlZpZXcyLlBlcm1pc3Npb25SZXF1ZXN0ZWRFdmVudEFyZ3MpID0+IHZvaWR9IGV2ZW50SGFuZGxlciAqLw0KCQlhZGRfUGVybWlzc2lvblJlcXVlc3RlZChldmVudEhhbmRsZXIpID0+IChDb21DYWxsKDIzLCB0aGlzLCAncHRyJywgZXZlbnRIYW5kbGVyLCAnaW50NjQqJywgJnRva2VuIDo9IDApLCB0b2tlbikJOyBJQ29yZVdlYlZpZXcyUGVybWlzc2lvblJlcXVlc3RlZEV2ZW50SGFuZGxlcg0KCQlyZW1vdmVfUGVybWlzc2lvblJlcXVlc3RlZCh0b2tlbikgPT4gQ29tQ2FsbCgyNCwgdGhpcywgJ2ludDY0JywgdG9rZW4pDQoJCS8qKiBAcGFyYW0geyhzZW5kZXI6IFdlYlZpZXcyLkNvcmUsIGFyZ3M6IFdlYlZpZXcyLlByb2Nlc3NGYWlsZWRFdmVudEFyZ3MpID0+IHZvaWR9IGV2ZW50SGFuZGxlciAqLw0KCQlhZGRfUHJvY2Vzc0ZhaWxlZChldmVudEhhbmRsZXIpID0+IChDb21DYWxsKDI1LCB0aGlzLCAncHRyJywgZXZlbnRIYW5kbGVyLCAnaW50NjQqJywgJnRva2VuIDo9IDApLCB0b2tlbikJOyBJQ29yZVdlYlZpZXcyUHJvY2Vzc0ZhaWxlZEV2ZW50SGFuZGxlcg0KCQlyZW1vdmVfUHJvY2Vzc0ZhaWxlZCh0b2tlbikgPT4gQ29tQ2FsbCgyNiwgdGhpcywgJ2ludDY0JywgdG9rZW4pDQoJCS8qKiBAcmV0dXJucyB7UHJvbWlzZTxTdHJpbmc+fSAqLw0KCQlBZGRTY3JpcHRUb0V4ZWN1dGVPbkRvY3VtZW50Q3JlYXRlZEFzeW5jKGphdmFTY3JpcHQpID0+IChDb21DYWxsKDI3LCB0aGlzLCAnd3N0cicsIGphdmFTY3JpcHQsICdwdHInLCBXZWJWaWV3Mi5Bc3luY0hhbmRsZXIoJnAsIFN0ckdldCkpLCBwKQ0KCQlSZW1vdmVTY3JpcHRUb0V4ZWN1dGVPbkRvY3VtZW50Q3JlYXRlZChpZCkgPT4gQ29tQ2FsbCgyOCwgdGhpcywgJ3dzdHInLCBpZCkNCgkJLyoqIEByZXR1cm5zIHtQcm9taXNlPFN0cmluZz59ICovDQoJCUV4ZWN1dGVTY3JpcHRBc3luYyhqYXZhU2NyaXB0KSA9PiAoQ29tQ2FsbCgyOSwgdGhpcywgJ3dzdHInLCBqYXZhU2NyaXB0LCAncHRyJywgV2ViVmlldzIuQXN5bmNIYW5kbGVyKCZwLCBTdHJHZXQpKSwgcCkNCgkJLyoqIEByZXR1cm5zIHtQcm9taXNlPHZvaWQ+fSAqLw0KCQlDYXB0dXJlUHJldmlld0FzeW5jKGltYWdlRm9ybWF0LCBpbWFnZVN0cmVhbSkgPT4gKENvbUNhbGwoMzAsIHRoaXMsICdpbnQnLCBpbWFnZUZvcm1hdCwgJ3B0cicsIGltYWdlU3RyZWFtLCAncHRyJywgV2ViVmlldzIuQXN5bmNIYW5kbGVyKCZwKSksIHApDQoJCVJlbG9hZCgpID0+IENvbUNhbGwoMzEsIHRoaXMpDQoJCVBvc3RXZWJNZXNzYWdlQXNKc29uKHdlYk1lc3NhZ2VBc0pzb24pID0+IENvbUNhbGwoMzIsIHRoaXMsICd3c3RyJywgd2ViTWVzc2FnZUFzSnNvbikNCgkJUG9zdFdlYk1lc3NhZ2VBc1N0cmluZyh3ZWJNZXNzYWdlQXNTdHJpbmcpID0+IENvbUNhbGwoMzMsIHRoaXMsICd3c3RyJywgd2ViTWVzc2FnZUFzU3RyaW5nKQ0KCQkvKiogQHBhcmFtIHsoc2VuZGVyOiBXZWJWaWV3Mi5Db3JlLCBhcmdzOiBXZWJWaWV3Mi5XZWJNZXNzYWdlUmVjZWl2ZWRFdmVudEFyZ3MpID0+IHZvaWR9IGV2ZW50SGFuZGxlciAqLw0KCQlhZGRfV2ViTWVzc2FnZVJlY2VpdmVkKGV2ZW50SGFuZGxlcikgPT4gKENvbUNhbGwoMzQsIHRoaXMsICdwdHInLCBldmVudEhhbmRsZXIsICdpbnQ2NConLCAmdG9rZW4gOj0gMCksIHRva2VuKQk7IElDb3JlV2ViVmlldzJXZWJNZXNzYWdlUmVjZWl2ZWRFdmVudEhhbmRsZXINCgkJcmVtb3ZlX1dlYk1lc3NhZ2VSZWNlaXZlZCh0b2tlbikgPT4gQ29tQ2FsbCgzNSwgdGhpcywgJ2ludDY0JywgdG9rZW4pDQoJCS8qKiBAcmV0dXJucyB7UHJvbWlzZTxTdHJpbmc+fSAqLw0KCQlDYWxsRGV2VG9vbHNQcm90b2NvbE1ldGhvZEFzeW5jKG1ldGhvZE5hbWUsIHBhcmFtZXRlcnNBc0pzb24pID0+IChDb21DYWxsKDM2LCB0aGlzLCAnd3N0cicsIG1ldGhvZE5hbWUsICd3c3RyJywgcGFyYW1ldGVyc0FzSnNvbiwgJ3B0cicsIFdlYlZpZXcyLkFzeW5jSGFuZGxlcigmcCwgU3RyR2V0KSksIHApDQoJCUJyb3dzZXJQcm9jZXNzSWQgPT4gKENvbUNhbGwoMzcsIHRoaXMsICd1aW50KicsICZ2YWx1ZSA6PSAwKSwgdmFsdWUpDQoJCUNhbkdvQmFjayA9PiAoQ29tQ2FsbCgzOCwgdGhpcywgJ2ludConLCAmY2FuR29CYWNrIDo9IDApLCBjYW5Hb0JhY2spDQoJCUNhbkdvRm9yd2FyZCA9PiAoQ29tQ2FsbCgzOSwgdGhpcywgJ2ludConLCAmY2FuR29Gb3J3YXJkIDo9IDApLCBjYW5Hb0ZvcndhcmQpDQoJCUdvQmFjaygpID0+IENvbUNhbGwoNDAsIHRoaXMpDQoJCUdvRm9yd2FyZCgpID0+IENvbUNhbGwoNDEsIHRoaXMpDQoJCUdldERldlRvb2xzUHJvdG9jb2xFdmVudFJlY2VpdmVyKGV2ZW50TmFtZSkgPT4gKENvbUNhbGwoNDIsIHRoaXMsICd3c3RyJywgZXZlbnROYW1lLCAncHRyKicsIHJlY2VpdmVyIDo9IFdlYlZpZXcyLkRldlRvb2xzUHJvdG9jb2xFdmVudFJlY2VpdmVyKCkpLCByZWNlaXZlcikNCgkJU3RvcCgpID0+IENvbUNhbGwoNDMsIHRoaXMpDQoJCS8qKiBAcGFyYW0geyhzZW5kZXI6IFdlYlZpZXcyLkNvcmUsIGFyZ3M6IFdlYlZpZXcyLk5ld1dpbmRvd1JlcXVlc3RlZEV2ZW50QXJncykgPT4gdm9pZH0gZXZlbnRIYW5kbGVyICovDQoJCWFkZF9OZXdXaW5kb3dSZXF1ZXN0ZWQoZXZlbnRIYW5kbGVyKSA9PiAoQ29tQ2FsbCg0NCwgdGhpcywgJ3B0cicsIGV2ZW50SGFuZGxlciwgJ2ludDY0KicsICZ0b2tlbiA6PSAwKSwgdG9rZW4pCTsgSUNvcmVXZWJWaWV3Mk5ld1dpbmRvd1JlcXVlc3RlZEV2ZW50SGFuZGxlcg0KCQlyZW1vdmVfTmV3V2luZG93UmVxdWVzdGVkKHRva2VuKSA9PiBDb21DYWxsKDQ1LCB0aGlzLCAnaW50NjQnLCB0b2tlbikNCgkJLyoqIEBwYXJhbSB7KHNlbmRlcjogV2ViVmlldzIuQ29yZSwgYXJnczogSVVua25vd24pID0+IHZvaWR9IGV2ZW50SGFuZGxlciAqLw0KCQlhZGRfRG9jdW1lbnRUaXRsZUNoYW5nZWQoZXZlbnRIYW5kbGVyKSA9PiAoQ29tQ2FsbCg0NiwgdGhpcywgJ3B0cicsIGV2ZW50SGFuZGxlciwgJ2ludDY0KicsICZ0b2tlbiA6PSAwKSwgdG9rZW4pCTsgSUNvcmVXZWJWaWV3MkRvY3VtZW50VGl0bGVDaGFuZ2VkRXZlbnRIYW5kbGVyDQoJCXJlbW92ZV9Eb2N1bWVudFRpdGxlQ2hhbmdlZCh0b2tlbikgPT4gQ29tQ2FsbCg0NywgdGhpcywgJ2ludDY0JywgdG9rZW4pDQoJCURvY3VtZW50VGl0bGUgPT4gKENvbUNhbGwoNDgsIHRoaXMsICdwdHIqJywgJnRpdGxlIDo9IDApLCBDb1Rhc2tNZW1fU3RyaW5nKHRpdGxlKSkNCgkJQWRkSG9zdE9iamVjdFRvU2NyaXB0KG5hbWUsIG9iamVjdCkgPT4gQ29tQ2FsbCg0OSwgdGhpcywgJ3dzdHInLCBuYW1lLCAncHRyJywgQ29tVmFyKG9iamVjdCkpDQoJCVJlbW92ZUhvc3RPYmplY3RGcm9tU2NyaXB0KG5hbWUpID0+IENvbUNhbGwoNTAsIHRoaXMsICd3c3RyJywgbmFtZSkNCgkJT3BlbkRldlRvb2xzV2luZG93KCkgPT4gQ29tQ2FsbCg1MSwgdGhpcykNCgkJLyoqIEBwYXJhbSB7KHNlbmRlcjogV2ViVmlldzIuQ29yZSwgYXJnczogSVVua25vd24pID0+IHZvaWR9IGV2ZW50SGFuZGxlciAqLw0KCQlhZGRfQ29udGFpbnNGdWxsU2NyZWVuRWxlbWVudENoYW5nZWQoZXZlbnRIYW5kbGVyKSA9PiAoQ29tQ2FsbCg1MiwgdGhpcywgJ3B0cicsIGV2ZW50SGFuZGxlciwgJ2ludDY0KicsICZ0b2tlbiA6PSAwKSwgdG9rZW4pCTsgSUNvcmVXZWJWaWV3MkNvbnRhaW5zRnVsbFNjcmVlbkVsZW1lbnRDaGFuZ2VkRXZlbnRIYW5kbGVyDQoJCXJlbW92ZV9Db250YWluc0Z1bGxTY3JlZW5FbGVtZW50Q2hhbmdlZCh0b2tlbikgPT4gQ29tQ2FsbCg1MywgdGhpcywgJ2ludDY0JywgdG9rZW4pDQoJCUNvbnRhaW5zRnVsbFNjcmVlbkVsZW1lbnQgPT4gKENvbUNhbGwoNTQsIHRoaXMsICdpbnQqJywgJmNvbnRhaW5zRnVsbFNjcmVlbkVsZW1lbnQgOj0gMCksIGNvbnRhaW5zRnVsbFNjcmVlbkVsZW1lbnQpDQoJCS8qKiBAcGFyYW0geyhzZW5kZXI6IFdlYlZpZXcyLkNvcmUsIGFyZ3M6IFdlYlZpZXcyLldlYlJlc291cmNlUmVxdWVzdGVkRXZlbnRBcmdzKSA9PiB2b2lkfSBldmVudEhhbmRsZXIgKi8NCgkJYWRkX1dlYlJlc291cmNlUmVxdWVzdGVkKGV2ZW50SGFuZGxlcikgPT4gKENvbUNhbGwoNTUsIHRoaXMsICdwdHInLCBldmVudEhhbmRsZXIsICdpbnQ2NConLCAmdG9rZW4gOj0gMCksIHRva2VuKQk7IElDb3JlV2ViVmlldzJXZWJSZXNvdXJjZVJlcXVlc3RlZEV2ZW50SGFuZGxlcg0KCQlyZW1vdmVfV2ViUmVzb3VyY2VSZXF1ZXN0ZWQodG9rZW4pID0+IENvbUNhbGwoNTYsIHRoaXMsICdpbnQ2NCcsIHRva2VuKQ0KCQlBZGRXZWJSZXNvdXJjZVJlcXVlc3RlZEZpbHRlcih1cmksIHJlc291cmNlQ29udGV4dCkgPT4gQ29tQ2FsbCg1NywgdGhpcywgJ3dzdHInLCB1cmksICdpbnQnLCByZXNvdXJjZUNvbnRleHQpDQoJCVJlbW92ZVdlYlJlc291cmNlUmVxdWVzdGVkRmlsdGVyKHVyaSwgcmVzb3VyY2VDb250ZXh0KSA9PiBDb21DYWxsKDU4LCB0aGlzLCAnd3N0cicsIHVyaSwgJ2ludCcsIHJlc291cmNlQ29udGV4dCkNCgkJLyoqIEBwYXJhbSB7KHNlbmRlcjogV2ViVmlldzIuQ29yZSwgYXJnczogSVVua25vd24pID0+IHZvaWR9IGV2ZW50SGFuZGxlciAqLw0KCQlhZGRfV2luZG93Q2xvc2VSZXF1ZXN0ZWQoZXZlbnRIYW5kbGVyKSA9PiAoQ29tQ2FsbCg1OSwgdGhpcywgJ3B0cicsIGV2ZW50SGFuZGxlciwgJ2ludDY0KicsICZ0b2tlbiA6PSAwKSwgdG9rZW4pCTsgSUNvcmVXZWJWaWV3MldpbmRvd0Nsb3NlUmVxdWVzdGVkRXZlbnRIYW5kbGVyDQoJCXJlbW92ZV9XaW5kb3dDbG9zZVJlcXVlc3RlZCh0b2tlbikgPT4gQ29tQ2FsbCg2MCwgdGhpcywgJ2ludDY0JywgdG9rZW4pDQoNCgkJc3RhdGljIElJRF8yIDo9ICd7OUU4RjBDRjgtRTY3MC00QjVFLUIyQkMtNzNFMDYxRTMxODRDfScNCgkJLyoqIEBwYXJhbSB7KHNlbmRlcjogV2ViVmlldzIuQ29yZSwgYXJnczogV2ViVmlldzIuV2ViUmVzb3VyY2VSZXNwb25zZVJlY2VpdmVkRXZlbnRBcmdzKSA9PiB2b2lkfSBldmVudEhhbmRsZXIgKi8NCgkJYWRkX1dlYlJlc291cmNlUmVzcG9uc2VSZWNlaXZlZChldmVudEhhbmRsZXIpID0+IChDb21DYWxsKDYxLCB0aGlzLCAncHRyJywgZXZlbnRIYW5kbGVyLCAnaW50NjQqJywgJnRva2VuIDo9IDApLCB0b2tlbikJOyBJQ29yZVdlYlZpZXcyV2ViUmVzb3VyY2VSZXNwb25zZVJlY2VpdmVkRXZlbnRIYW5kbGVyDQoJCXJlbW92ZV9XZWJSZXNvdXJjZVJlc3BvbnNlUmVjZWl2ZWQodG9rZW4pID0+IENvbUNhbGwoNjIsIHRoaXMsICdpbnQ2NCcsIHRva2VuKQ0KCQlOYXZpZ2F0ZVdpdGhXZWJSZXNvdXJjZVJlcXVlc3QocmVxdWVzdCkgPT4gQ29tQ2FsbCg2MywgdGhpcywgJ3B0cicsIHJlcXVlc3QpCTsgSUNvcmVXZWJWaWV3MldlYlJlc291cmNlUmVxdWVzdA0KCQkvKiogQHBhcmFtIHsoc2VuZGVyOiBXZWJWaWV3Mi5Db3JlLCBhcmdzOiBXZWJWaWV3Mi5ET01Db250ZW50TG9hZGVkRXZlbnRBcmdzKSA9PiB2b2lkfSBldmVudEhhbmRsZXIgKi8NCgkJYWRkX0RPTUNvbnRlbnRMb2FkZWQoZXZlbnRIYW5kbGVyKSA9PiAoQ29tQ2FsbCg2NCwgdGhpcywgJ3B0cicsIGV2ZW50SGFuZGxlciwgJ2ludDY0KicsICZ0b2tlbiA6PSAwKSwgdG9rZW4pCTsgSUNvcmVXZWJWaWV3MkRPTUNvbnRlbnRMb2FkZWRFdmVudEhhbmRsZXINCgkJcmVtb3ZlX0RPTUNvbnRlbnRMb2FkZWQodG9rZW4pID0+IENvbUNhbGwoNjUsIHRoaXMsICdpbnQ2NCcsIHRva2VuKQ0KCQlDb29raWVNYW5hZ2VyID0+IChDb21DYWxsKDY2LCB0aGlzLCAncHRyKicsIGNvb2tpZU1hbmFnZXIgOj0gV2ViVmlldzIuQ29va2llTWFuYWdlcigpKSwgY29va2llTWFuYWdlcikNCgkJRW52aXJvbm1lbnQgPT4gKENvbUNhbGwoNjcsIHRoaXMsICdwdHIqJywgZW52aXJvbm1lbnQgOj0gV2ViVmlldzIuRW52aXJvbm1lbnQoKSksIGVudmlyb25tZW50KQ0KDQoJCXN0YXRpYyBJSURfMyA6PSAne0EwRDZERjIwLTNCOTItNDE2RC1BQTBDLTQzN0E5QzcyNzg1N30nDQoJCS8qKiBAcmV0dXJucyB7UHJvbWlzZTxJbnRlZ2VyPn0gKi8NCgkJVHJ5U3VzcGVuZEFzeW5jKCkgPT4gKENvbUNhbGwoNjgsIHRoaXMsICdwdHInLCBXZWJWaWV3Mi5Bc3luY0hhbmRsZXIoJnAsIEludGVnZXIpKSwgcCkNCgkJUmVzdW1lKCkgPT4gQ29tQ2FsbCg2OSwgdGhpcykNCgkJSXNTdXNwZW5kZWQgPT4gKENvbUNhbGwoNzAsIHRoaXMsICdpbnQqJywgJmlzU3VzcGVuZGVkIDo9IDApLCBpc1N1c3BlbmRlZCkNCgkJU2V0VmlydHVhbEhvc3ROYW1lVG9Gb2xkZXJNYXBwaW5nKGhvc3ROYW1lLCBmb2xkZXJQYXRoLCBhY2Nlc3NLaW5kKSA9PiBDb21DYWxsKDcxLCB0aGlzLCAnd3N0cicsIGhvc3ROYW1lLCAnd3N0cicsIGZvbGRlclBhdGgsICdpbnQnLCBhY2Nlc3NLaW5kKQ0KCQlDbGVhclZpcnR1YWxIb3N0TmFtZVRvRm9sZGVyTWFwcGluZyhob3N0TmFtZSkgPT4gQ29tQ2FsbCg3MiwgdGhpcywgJ3dzdHInLCBob3N0TmFtZSkNCg0KCQlzdGF0aWMgSUlEXzQgOj0gJ3syMGQwMmQ1OS02ZGYyLTQyZGMtYmQwNi1mOThhNjk0YjEzMDJ9Jw0KCQkvKiogQHBhcmFtIHsoc2VuZGVyOiBXZWJWaWV3Mi5Db3JlLCBhcmdzOiBXZWJWaWV3Mi5GcmFtZUNyZWF0ZWRFdmVudEFyZ3MpID0+IHZvaWR9IGV2ZW50SGFuZGxlciAqLw0KCQlhZGRfRnJhbWVDcmVhdGVkKGV2ZW50SGFuZGxlcikgPT4gKENvbUNhbGwoNzMsIHRoaXMsICdwdHInLCBldmVudEhhbmRsZXIsICdpbnQ2NConLCAmdG9rZW4gOj0gMCksIHRva2VuKQk7IElDb3JlV2ViVmlldzJGcmFtZUNyZWF0ZWRFdmVudEhhbmRsZXINCgkJcmVtb3ZlX0ZyYW1lQ3JlYXRlZCh0b2tlbikgPT4gQ29tQ2FsbCg3NCwgdGhpcywgJ2ludDY0JywgdG9rZW4pDQoJCS8qKiBAcGFyYW0geyhzZW5kZXI6IFdlYlZpZXcyLkNvcmUsIGFyZ3M6IFdlYlZpZXcyLkRvd25sb2FkU3RhcnRpbmdFdmVudEFyZ3MpID0+IHZvaWR9IGV2ZW50SGFuZGxlciAqLw0KCQlhZGRfRG93bmxvYWRTdGFydGluZyhldmVudEhhbmRsZXIpID0+IChDb21DYWxsKDc1LCB0aGlzLCAncHRyJywgZXZlbnRIYW5kbGVyLCAnaW50NjQqJywgJnRva2VuIDo9IDApLCB0b2tlbikJOyBJQ29yZVdlYlZpZXcyRG93bmxvYWRTdGFydGluZ0V2ZW50SGFuZGxlcg0KCQlyZW1vdmVfRG93bmxvYWRTdGFydGluZyh0b2tlbikgPT4gQ29tQ2FsbCg3NiwgdGhpcywgJ2ludDY0JywgdG9rZW4pDQoNCgkJc3RhdGljIElJRF81IDo9ICd7YmVkYjExYjgtZDYzYy0xMWViLWI4YmMtMDI0MmFjMTMwMDAzfScNCgkJLyoqIEBwYXJhbSB7KHNlbmRlcjogV2ViVmlldzIuQ29yZSwgYXJnczogV2ViVmlldzIuQ2xpZW50Q2VydGlmaWNhdGVSZXF1ZXN0ZWRFdmVudEFyZ3MpID0+IHZvaWR9IGV2ZW50SGFuZGxlciAqLw0KCQlhZGRfQ2xpZW50Q2VydGlmaWNhdGVSZXF1ZXN0ZWQoZXZlbnRIYW5kbGVyKSA9PiAoQ29tQ2FsbCg3NywgdGhpcywgJ3B0cicsIGV2ZW50SGFuZGxlciwgJ2ludDY0KicsICZ0b2tlbiA6PSAwKSwgdG9rZW4pCTsgSUNvcmVXZWJWaWV3MkNsaWVudENlcnRpZmljYXRlUmVxdWVzdGVkRXZlbnRIYW5kbGVyDQoJCXJlbW92ZV9DbGllbnRDZXJ0aWZpY2F0ZVJlcXVlc3RlZCh0b2tlbikgPT4gQ29tQ2FsbCg3OCwgdGhpcywgJ2ludDY0JywgdG9rZW4pDQoNCgkJc3RhdGljIElJRF82IDo9ICd7NDk5YWFkYWMtZDkyYy00NTg5LThhNzUtMTExYmZjMTY3Nzk1fScNCgkJT3BlblRhc2tNYW5hZ2VyV2luZG93KCkgPT4gQ29tQ2FsbCg3OSwgdGhpcykNCg0KCQlzdGF0aWMgSUlEXzcgOj0gJ3s3OWMyNGQ4My0wOWEzLTQ1YWUtOTQxOC00ODdmMzJhNTg3NDB9Jw0KCQkvKiogQHJldHVybnMge1Byb21pc2U8SW50ZWdlcj59ICovDQoJCVByaW50VG9QZGZBc3luYyhyZXN1bHRGaWxlUGF0aCwgcHJpbnRTZXR0aW5ncykgPT4gKENvbUNhbGwoODAsIHRoaXMsICd3c3RyJywgcmVzdWx0RmlsZVBhdGgsICdwdHInLCBwcmludFNldHRpbmdzLCAncHRyJywgV2ViVmlldzIuQXN5bmNIYW5kbGVyKCZwLCBJbnRlZ2VyKSksIHApDQoNCgkJc3RhdGljIElJRF84IDo9ICd7RTk2MzI3MzAtNkUxRS00M0FCLUI3QjgtN0IyQzlFNjJFMDk0fScNCgkJLyoqIEBwYXJhbSB7KHNlbmRlcjogV2ViVmlldzIuQ29yZSwgYXJnczogSVVua25vd24pID0+IHZvaWR9IGV2ZW50SGFuZGxlciAqLw0KCQlhZGRfSXNNdXRlZENoYW5nZWQoZXZlbnRIYW5kbGVyKSA9PiAoQ29tQ2FsbCg4MSwgdGhpcywgJ3B0cicsIGV2ZW50SGFuZGxlciwgJ2ludDY0KicsICZ0b2tlbiA6PSAwKSwgdG9rZW4pCTsgSUNvcmVXZWJWaWV3MklzTXV0ZWRDaGFuZ2VkRXZlbnRIYW5kbGVyDQoJCXJlbW92ZV9Jc011dGVkQ2hhbmdlZCh0b2tlbikgPT4gQ29tQ2FsbCg4MiwgdGhpcywgJ2ludDY0JywgdG9rZW4pDQoJCUlzTXV0ZWQgew0KCQkJZ2V0ID0+IChDb21DYWxsKDgzLCB0aGlzLCAnaW50KicsICZ2YWx1ZSA6PSAwKSwgdmFsdWUpDQoJCQlzZXQgPT4gQ29tQ2FsbCg4NCwgdGhpcywgJ2ludCcsIFZhbHVlKQ0KCQl9DQoJCS8qKiBAcGFyYW0geyhzZW5kZXI6IFdlYlZpZXcyLkNvcmUsIGFyZ3M6IElVbmtub3duKSA9PiB2b2lkfSBldmVudEhhbmRsZXIgKi8NCgkJYWRkX0lzRG9jdW1lbnRQbGF5aW5nQXVkaW9DaGFuZ2VkKGV2ZW50SGFuZGxlcikgPT4gKENvbUNhbGwoODUsIHRoaXMsICdwdHInLCBldmVudEhhbmRsZXIsICdpbnQ2NConLCAmdG9rZW4gOj0gMCksIHRva2VuKQk7IElDb3JlV2ViVmlldzJJc0RvY3VtZW50UGxheWluZ0F1ZGlvQ2hhbmdlZEV2ZW50SGFuZGxlcg0KCQlyZW1vdmVfSXNEb2N1bWVudFBsYXlpbmdBdWRpb0NoYW5nZWQodG9rZW4pID0+IENvbUNhbGwoODYsIHRoaXMsICdpbnQ2NCcsIHRva2VuKQ0KCQlJc0RvY3VtZW50UGxheWluZ0F1ZGlvID0+IChDb21DYWxsKDg3LCB0aGlzLCAnaW50KicsICZ2YWx1ZSA6PSAwKSwgdmFsdWUpDQoNCgkJc3RhdGljIElJRF85IDo9ICd7NGQ3YjJlYWItOWZkYy00NjhkLWI5OTgtYTkyNjBiNWVkNjUxfScNCgkJLyoqIEBwYXJhbSB7KHNlbmRlcjogV2ViVmlldzIuQ29yZSwgYXJnczogSVVua25vd24pID0+IHZvaWR9IGV2ZW50SGFuZGxlciAqLw0KCQlhZGRfSXNEZWZhdWx0RG93bmxvYWREaWFsb2dPcGVuQ2hhbmdlZChldmVudEhhbmRsZXIpID0+IChDb21DYWxsKDg4LCB0aGlzLCAncHRyJywgZXZlbnRIYW5kbGVyLCAnaW50NjQqJywgJnRva2VuIDo9IDApLCB0b2tlbikJOyBJQ29yZVdlYlZpZXcySXNEZWZhdWx0RG93bmxvYWREaWFsb2dPcGVuQ2hhbmdlZEV2ZW50SGFuZGxlcg0KCQlyZW1vdmVfSXNEZWZhdWx0RG93bmxvYWREaWFsb2dPcGVuQ2hhbmdlZCh0b2tlbikgPT4gQ29tQ2FsbCg4OSwgdGhpcywgJ2ludDY0JywgdG9rZW4pDQoJCUlzRGVmYXVsdERvd25sb2FkRGlhbG9nT3BlbiA9PiAoQ29tQ2FsbCg5MCwgdGhpcywgJ2ludConLCAmdmFsdWUgOj0gMCksIHZhbHVlKQ0KCQlPcGVuRGVmYXVsdERvd25sb2FkRGlhbG9nKCkgPT4gQ29tQ2FsbCg5MSwgdGhpcykNCgkJQ2xvc2VEZWZhdWx0RG93bmxvYWREaWFsb2coKSA9PiBDb21DYWxsKDkyLCB0aGlzKQ0KCQlEZWZhdWx0RG93bmxvYWREaWFsb2dDb3JuZXJBbGlnbm1lbnQgew0KCQkJZ2V0ID0+IChDb21DYWxsKDkzLCB0aGlzLCAnaW50KicsICZ2YWx1ZSA6PSAwKSwgdmFsdWUpDQoJCQlzZXQgPT4gQ29tQ2FsbCg5NCwgdGhpcywgJ2ludCcsIFZhbHVlKQ0KCQl9DQoJCURlZmF1bHREb3dubG9hZERpYWxvZ01hcmdpbiB7DQoJCQlnZXQgPT4gKENvbUNhbGwoOTUsIHRoaXMsICdpbnQ2NConLCAmdmFsdWUgOj0gMCksIHZhbHVlKQk7IFBPSU5UDQoJCQlzZXQgPT4gQ29tQ2FsbCg5NiwgdGhpcywgJ2ludDY0JywgVmFsdWUpDQoJCX0NCg0KCQlzdGF0aWMgSUlEXzEwIDo9ICd7YjE2OTA1NjQtNmY1YS00OTgzLThlNDgtMzFkMTE0M2ZlY2RifScNCgkJLyoqIEBwYXJhbSB7KHNlbmRlcjogV2ViVmlldzIuQ29yZSwgYXJnczogV2ViVmlldzIuQmFzaWNBdXRoZW50aWNhdGlvblJlcXVlc3RlZEV2ZW50QXJncykgPT4gdm9pZH0gZXZlbnRIYW5kbGVyICovDQoJCWFkZF9CYXNpY0F1dGhlbnRpY2F0aW9uUmVxdWVzdGVkKGV2ZW50SGFuZGxlcikgPT4gKENvbUNhbGwoOTcsIHRoaXMsICdwdHInLCBldmVudEhhbmRsZXIsICdpbnQ2NConLCAmdG9rZW4gOj0gMCksIHRva2VuKQk7IElDb3JlV2ViVmlldzJCYXNpY0F1dGhlbnRpY2F0aW9uUmVxdWVzdGVkRXZlbnRIYW5kbGVyDQoJCXJlbW92ZV9CYXNpY0F1dGhlbnRpY2F0aW9uUmVxdWVzdGVkKHRva2VuKSA9PiBDb21DYWxsKDk4LCB0aGlzLCAnaW50NjQnLCB0b2tlbikNCg0KCQlzdGF0aWMgSUlEXzExIDo9ICd7MGJlNzhlNTYtYzE5My00MDUxLWI5NDMtMjNiNDYwYzA4YmRifScNCgkJLyoqIEByZXR1cm5zIHtQcm9taXNlPFN0cmluZz59ICovDQoJCUNhbGxEZXZUb29sc1Byb3RvY29sTWV0aG9kRm9yU2Vzc2lvbkFzeW5jKHNlc3Npb25JZCwgbWV0aG9kTmFtZSwgcGFyYW1ldGVyc0FzSnNvbikgPT4gKENvbUNhbGwoOTksIHRoaXMsICd3c3RyJywgc2Vzc2lvbklkLCAnd3N0cicsIG1ldGhvZE5hbWUsICd3c3RyJywgcGFyYW1ldGVyc0FzSnNvbiwgJ3B0cicsIFdlYlZpZXcyLkFzeW5jSGFuZGxlcigmcCwgU3RyR2V0KSksIHApDQoJCS8qKiBAcGFyYW0geyhzZW5kZXI6IFdlYlZpZXcyLkNvcmUsIGFyZ3M6IFdlYlZpZXcyLkNvbnRleHRNZW51UmVxdWVzdGVkRXZlbnRBcmdzKSA9PiB2b2lkfSBldmVudEhhbmRsZXIgKi8NCgkJYWRkX0NvbnRleHRNZW51UmVxdWVzdGVkKGV2ZW50SGFuZGxlcikgPT4gKENvbUNhbGwoMTAwLCB0aGlzLCAncHRyJywgZXZlbnRIYW5kbGVyLCAnaW50NjQqJywgJnRva2VuIDo9IDApLCB0b2tlbikJOyBJQ29yZVdlYlZpZXcyQ29udGV4dE1lbnVSZXF1ZXN0ZWRFdmVudEhhbmRsZXINCgkJcmVtb3ZlX0NvbnRleHRNZW51UmVxdWVzdGVkKHRva2VuKSA9PiBDb21DYWxsKDEwMSwgdGhpcywgJ2ludDY0JywgdG9rZW4pDQoNCgkJc3RhdGljIElJRF8xMiA6PSAnezM1RDY5OTI3LUJDRkEtNDU2Ni05MzQ5LTZCM0UwRDE1NENBQ30nDQoJCS8qKiBAcGFyYW0geyhzZW5kZXI6IFdlYlZpZXcyLkNvcmUsIGFyZ3M6IElVbmtub3duKSA9PiB2b2lkfSBldmVudEhhbmRsZXIgKi8NCgkJYWRkX1N0YXR1c0JhclRleHRDaGFuZ2VkKGV2ZW50SGFuZGxlcikgPT4gKENvbUNhbGwoMTAyLCB0aGlzLCAncHRyJywgZXZlbnRIYW5kbGVyLCAnaW50NjQqJywgJnRva2VuIDo9IDApLCB0b2tlbikJOyBJQ29yZVdlYlZpZXcyU3RhdHVzQmFyVGV4dENoYW5nZWRFdmVudEhhbmRsZXINCgkJcmVtb3ZlX1N0YXR1c0JhclRleHRDaGFuZ2VkKHRva2VuKSA9PiBDb21DYWxsKDEwMywgdGhpcywgJ2ludDY0JywgdG9rZW4pDQoJCVN0YXR1c0JhclRleHQgPT4gKENvbUNhbGwoMTA0LCB0aGlzLCAncHRyKicsICZ2YWx1ZSA6PSAwKSwgQ29UYXNrTWVtX1N0cmluZyh2YWx1ZSkpDQoNCgkJc3RhdGljIElJRF8xMyA6PSAne0Y3NUYwOUE4LTY2N0UtNDk4My04OEQ2LUM4NzczRjMxNUU4NH0nDQoJCVByb2ZpbGUgPT4gKENvbUNhbGwoMTA1LCB0aGlzLCAncHRyKicsIHZhbHVlIDo9IFdlYlZpZXcyLlByb2ZpbGUoKSksIHZhbHVlKQ0KDQoJCXN0YXRpYyBJSURfMTQgOj0gJ3s2REFBNEYxMC00QTkwLTQ3NTMtODg5OC03N0M1REY1MzQxNjV9Jw0KCQkvKiogQHBhcmFtIHsoc2VuZGVyOiBXZWJWaWV3Mi5Db3JlLCBhcmdzOiBXZWJWaWV3Mi5TZXJ2ZXJDZXJ0aWZpY2F0ZUVycm9yRGV0ZWN0ZWRFdmVudEFyZ3MpID0+IHZvaWR9IGV2ZW50SGFuZGxlciAqLw0KCQlhZGRfU2VydmVyQ2VydGlmaWNhdGVFcnJvckRldGVjdGVkKGV2ZW50SGFuZGxlcikgPT4gKENvbUNhbGwoMTA2LCB0aGlzLCAncHRyJywgZXZlbnRIYW5kbGVyLCAnaW50NjQqJywgJnRva2VuIDo9IDApLCB0b2tlbikJOyBJQ29yZVdlYlZpZXcyU2VydmVyQ2VydGlmaWNhdGVFcnJvckRldGVjdGVkRXZlbnRIYW5kbGVyDQoJCXJlbW92ZV9TZXJ2ZXJDZXJ0aWZpY2F0ZUVycm9yRGV0ZWN0ZWQodG9rZW4pID0+IENvbUNhbGwoMTA3LCB0aGlzLCAnaW50NjQnLCB0b2tlbikNCgkJLyoqIEByZXR1cm5zIHtQcm9taXNlPHZvaWQ+fSAqLw0KCQlDbGVhclNlcnZlckNlcnRpZmljYXRlRXJyb3JBY3Rpb25zQXN5bmMoKSA9PiAoQ29tQ2FsbCgxMDgsIHRoaXMsICdwdHInLCBXZWJWaWV3Mi5Bc3luY0hhbmRsZXIoJnApKSwgcCkNCg0KCQlzdGF0aWMgSUlEXzE1IDo9ICd7NTE3QjJEMUQtN0RBRS00QTY2LUE0RjQtMTAzNTJGRkI5NTE4fScNCgkJLyoqIEBwYXJhbSB7KHNlbmRlcjogV2ViVmlldzIuQ29yZSwgYXJnczogSVVua25vd24pID0+IHZvaWR9IGV2ZW50SGFuZGxlciAqLw0KCQlhZGRfRmF2aWNvbkNoYW5nZWQoZXZlbnRIYW5kbGVyKSA9PiAoQ29tQ2FsbCgxMDksIHRoaXMsICdwdHInLCBldmVudEhhbmRsZXIsICdpbnQ2NConLCAmdG9rZW4gOj0gMCksIHRva2VuKQk7IElDb3JlV2ViVmlldzJGYXZpY29uQ2hhbmdlZEV2ZW50SGFuZGxlcg0KCQlyZW1vdmVfRmF2aWNvbkNoYW5nZWQodG9rZW4pID0+IENvbUNhbGwoMTEwLCB0aGlzLCAnaW50NjQnLCB0b2tlbikNCgkJRmF2aWNvblVyaSA9PiAoQ29tQ2FsbCgxMTEsIHRoaXMsICdwdHIqJywgJnZhbHVlIDo9IDApLCBDb1Rhc2tNZW1fU3RyaW5nKHZhbHVlKSkNCgkJLyoqIEByZXR1cm5zIHtQcm9taXNlPFdlYlZpZXcyLlN0cmVhbT59ICovDQoJCUdldEZhdmljb25Bc3luYyhmb3JtYXQpID0+IChDb21DYWxsKDExMiwgdGhpcywgJ2ludCcsIGZvcm1hdCwgJ3B0cicsIFdlYlZpZXcyLkFzeW5jSGFuZGxlcigmcCwgV2ViVmlldzIuU3RyZWFtKSksIHApCTsgQ09SRVdFQlZJRVcyX0ZBVklDT05fSU1BR0VfRk9STUFUDQoNCgkJc3RhdGljIElJRF8xNiA6PSAnezBFQjM0REM5LTlGOTEtNDFFMS04NjM5LTk1Q0Q1OTQzOTA2Qn0nDQoJCS8qKiBAcmV0dXJucyB7UHJvbWlzZTxXZWJWaWV3Mi5QUklOVF9TVEFUVVM+fSAqLw0KCQlQcmludEFzeW5jKHByaW50U2V0dGluZ3MpID0+IChDb21DYWxsKDExMywgdGhpcywgJ3B0cicsIHByaW50U2V0dGluZ3MsICdwdHInLCBXZWJWaWV3Mi5Bc3luY0hhbmRsZXIoJnAsIEludGVnZXIpKSwgcCkNCgkJU2hvd1ByaW50VUkocHJpbnREaWFsb2dLaW5kKSA9PiBDb21DYWxsKDExNCwgdGhpcywgJ2ludCcsIHByaW50RGlhbG9nS2luZCkNCgkJLyoqIEByZXR1cm5zIHtQcm9taXNlPFdlYlZpZXcyLlN0cmVhbT59ICovDQoJCVByaW50VG9QZGZTdHJlYW1Bc3luYyhwcmludFNldHRpbmdzKSA9PiAoQ29tQ2FsbCgxMTUsIHRoaXMsICdwdHInLCBwcmludFNldHRpbmdzLCAncHRyJywgV2ViVmlldzIuQXN5bmNIYW5kbGVyKCZwLCBXZWJWaWV3Mi5TdHJlYW0pKSwgcCkNCg0KCQlzdGF0aWMgSUlEXzE3IDo9ICd7NzAyRTc1RDQtRkQ0NC00MzRELTlENzAtMUE2OEE2QjExOTJBfScNCgkJUG9zdFNoYXJlZEJ1ZmZlclRvU2NyaXB0KHNoYXJlZEJ1ZmZlciwgYWNjZXNzLCBhZGRpdGlvbmFsRGF0YUFzSnNvbikgPT4gQ29tQ2FsbCgxMTYsIHRoaXMsICdwdHInLCBzaGFyZWRCdWZmZXIsICdpbnQnLCBhY2Nlc3MsICd3c3RyJywgYWRkaXRpb25hbERhdGFBc0pzb24pDQoNCgkJc3RhdGljIElJRF8xOCA6PSAnezdBNjI2MDE3LTI4QkUtNDlCMi1CODY1LTNCQTJCMzUyMkQ5MH0nDQoJCS8qKiBAcGFyYW0geyhzZW5kZXI6IFdlYlZpZXcyLkNvcmUsIGFyZ3M6IFdlYlZpZXcyLkxhdW5jaGluZ0V4dGVybmFsVXJpU2NoZW1lRXZlbnRBcmdzKSA9PiB2b2lkfSBldmVudEhhbmRsZXIgKi8NCgkJYWRkX0xhdW5jaGluZ0V4dGVybmFsVXJpU2NoZW1lKGV2ZW50SGFuZGxlcikgPT4gKENvbUNhbGwoMTE3LCB0aGlzLCAncHRyJywgZXZlbnRIYW5kbGVyLCAnaW50NjQqJywgJnRva2VuIDo9IDApLCB0b2tlbikJOyBJQ29yZVdlYlZpZXcyTGF1bmNoaW5nRXh0ZXJuYWxVcmlTY2hlbWVFdmVudEhhbmRsZXINCgkJcmVtb3ZlX0xhdW5jaGluZ0V4dGVybmFsVXJpU2NoZW1lKHRva2VuKSA9PiBDb21DYWxsKDExOCwgdGhpcywgJ2ludDY0JywgdG9rZW4pDQoNCgkJc3RhdGljIElJRF8xOSA6PSAnezY5MjFGOTU0LTc5QjAtNDM3Ri1BOTk3LUM4NTgxMTg5N0M2OH0nDQoJCU1lbW9yeVVzYWdlVGFyZ2V0TGV2ZWwgew0KCQkJZ2V0ID0+IChDb21DYWxsKDExOSwgdGhpcywgJ2ludConLCAmbGV2ZWwgOj0gMCksIGxldmVsKQ0KCQkJc2V0ID0+IENvbUNhbGwoMTIwLCB0aGlzLCAnaW50JywgVmFsdWUpDQoJCX0NCg0KCQlzdGF0aWMgSUlEXzIwIDo9ICd7YjRiYzE5MjYtNzMwNS0xMWVlLWI5NjItMDI0MmFjMTIwMDAyfScNCgkJRnJhbWVJZCA9PiAoQ29tQ2FsbCgxMjEsIHRoaXMsICd1aW50KicsICZpZCA6PSAwKSwgaWQpDQoNCgkJc3RhdGljIElJRF8yMSA6PSAne2M0OTgwZGVhLTU4N2ItNDNiOS04MTQzLTNlZjNiZjU1MmQ5NX0nDQoJCS8qKiBAcmV0dXJucyB7UHJvbWlzZTxXZWJWaWV3Mi5FeGVjdXRlU2NyaXB0UmVzdWx0Pn0gKi8NCgkJRXhlY3V0ZVNjcmlwdFdpdGhSZXN1bHRBc3luYyhqYXZhU2NyaXB0KSA9PiAoQ29tQ2FsbCgxMjIsIHRoaXMsICd3c3RyJywgamF2YVNjcmlwdCwgJ3B0cicsIFdlYlZpZXcyLkFzeW5jSGFuZGxlcigmcCwgV2ViVmlldzIuRXhlY3V0ZVNjcmlwdFJlc3VsdCkpLCBwKQ0KDQoJCXN0YXRpYyBJSURfMjIgOj0gJ3tEQjc1REZDNy1BODU3LTQ2MzItQTM5OC02OTY5RERFMjZDMEF9Jw0KCQlBZGRXZWJSZXNvdXJjZVJlcXVlc3RlZEZpbHRlcldpdGhSZXF1ZXN0U291cmNlS2luZHModXJpLCByZXNvdXJjZUNvbnRleHQsIHJlcXVlc3RTb3VyY2VLaW5kcykgPT4gQ29tQ2FsbCgxMjMsIHRoaXMsICd3c3RyJywgdXJpLCAnaW50JywgcmVzb3VyY2VDb250ZXh0LCAnaW50JywgcmVxdWVzdFNvdXJjZUtpbmRzKQ0KCQlSZW1vdmVXZWJSZXNvdXJjZVJlcXVlc3RlZEZpbHRlcldpdGhSZXF1ZXN0U291cmNlS2luZHModXJpLCByZXNvdXJjZUNvbnRleHQsIHJlcXVlc3RTb3VyY2VLaW5kcykgPT4gQ29tQ2FsbCgxMjQsIHRoaXMsICd3c3RyJywgdXJpLCAnaW50JywgcmVzb3VyY2VDb250ZXh0LCAnaW50JywgcmVxdWVzdFNvdXJjZUtpbmRzKQ0KDQoJCXN0YXRpYyBJSURfMjMgOj0gJ3s1MDhmMGRiNS05MGM0LTU4NzItOTBhNy0yNjdhOTEzNzc1MDJ9Jw0KCQkvKioNCgkJICogU2FtZSBhcyBQb3N0V2ViTWVzc2FnZUFzSnNvbiwgYnV0IGFsc28gaGFzIHN1cHBvcnQgZm9yIHBvc3RpbmcgRE9NIG9iamVjdHMgdG8gcGFnZSBjb250ZW50Lg0KCQkgKiBAcGFyYW0ge1N0cmluZ30gd2ViTWVzc2FnZUFzSnNvbg0KCQkgKiBAcGFyYW0ge1dlYlZpZXcyLk9iamVjdENvbGxlY3Rpb25WaWV3fSBhZGRpdGlvbmFsT2JqZWN0cw0KCQkgKi8NCgkJUG9zdFdlYk1lc3NhZ2VBc0pzb25XaXRoQWRkaXRpb25hbE9iamVjdHMod2ViTWVzc2FnZUFzSnNvbiwgYWRkaXRpb25hbE9iamVjdHMpID0+IENvbUNhbGwoMTI1LCB0aGlzLCAnd3N0cicsIHdlYk1lc3NhZ2VBc0pzb24sICdwdHInLCBhZGRpdGlvbmFsT2JqZWN0cykNCg0KCQlzdGF0aWMgSUlEXzI0IDo9ICd7MzlhN2FkNTUtNDI4Ny01Y2MxLTg4YTEtYzZmNDU4NTkzODI0fScNCgkJLyoqIEBwYXJhbSB7KHNlbmRlcjogV2ViVmlldzIuQ29yZSwgYXJnczogV2ViVmlldzIuTm90aWZpY2F0aW9uUmVjZWl2ZWRFdmVudEFyZ3MpID0+IHZvaWR9IGV2ZW50SGFuZGxlciAqLw0KCQlhZGRfTm90aWZpY2F0aW9uUmVjZWl2ZWQoZXZlbnRIYW5kbGVyKSA9PiAoQ29tQ2FsbCgxMjYsIHRoaXMsICdwdHInLCBldmVudEhhbmRsZXIsICdpbnQ2NConLCAmdG9rZW4gOj0gMCksIHRva2VuKQk7IElDb3JlV2ViVmlldzJMYXVuY2hpbmdFeHRlcm5hbFVyaVNjaGVtZUV2ZW50SGFuZGxlcg0KCQlyZW1vdmVfTm90aWZpY2F0aW9uUmVjZWl2ZWQodG9rZW4pID0+IENvbUNhbGwoMTI3LCB0aGlzLCAnaW50NjQnLCB0b2tlbikNCg0KCQlzdGF0aWMgSUlEXzI1IDo9ICd7YjVhODYwOTItZGY1MC01YjRmLWExN2ItNmM4ZjhiNDBiNzcxfScNCgkJLyoqIEBwYXJhbSB7KHNlbmRlcjogV2ViVmlldzIuQ29yZSwgYXJnczogV2ViVmlldzIuU2F2ZUFzVUlTaG93aW5nRXZlbnRBcmdzKSA9PiB2b2lkfSBldmVudEhhbmRsZXIgKi8NCgkJYWRkX1NhdmVBc1VJU2hvd2luZyhldmVudEhhbmRsZXIpID0+IChDb21DYWxsKDEyOCwgdGhpcywgJ3B0cicsIGV2ZW50SGFuZGxlciwgJ2ludDY0KicsICZ0b2tlbiA6PSAwKSwgdG9rZW4pCTsgSUNvcmVXZWJWaWV3MkxhdW5jaGluZ0V4dGVybmFsVXJpU2NoZW1lRXZlbnRIYW5kbGVyDQoJCXJlbW92ZV9TYXZlQXNVSVNob3dpbmcodG9rZW4pID0+IENvbUNhbGwoMTI5LCB0aGlzLCAnaW50NjQnLCB0b2tlbikNCgkJLyoqIEByZXR1cm5zIHtQcm9taXNlPFdlYlZpZXcyLlNBVkVfQVNfVUlfUkVTVUxUPn0gKi8NCgkJU2hvd1NhdmVBc1VJQXN5bmMoKSA9PiAoQ29tQ2FsbCgxMzAsIHRoaXMsICdwdHInLCBXZWJWaWV3Mi5Bc3luY0hhbmRsZXIoJnAsIEludGVnZXIpKSwgcCkNCg0KCQlzdGF0aWMgSUlEXzI2IDo9ICd7ODA2MjY4YjgtZjg5Ny01Njg1LTg4ZTUtYzQ1ZmNhMGIxYTQ4fScNCgkJLyoqIEBwYXJhbSB7KHNlbmRlcjogV2ViVmlldzIuQ29yZSwgYXJnczogV2ViVmlldzIuU2F2ZUZpbGVTZWN1cml0eUNoZWNrU3RhcnRpbmdFdmVudEFyZ3MpID0+IHZvaWR9IGV2ZW50SGFuZGxlciAqLw0KCQlhZGRfU2F2ZUZpbGVTZWN1cml0eUNoZWNrU3RhcnRpbmcoZXZlbnRIYW5kbGVyKSA9PiAoQ29tQ2FsbCgxMzEsIHRoaXMsICdwdHInLCBldmVudEhhbmRsZXIsICdpbnQ2NConLCAmdG9rZW4gOj0gMCksIHRva2VuKQ0KCQlyZW1vdmVfU2F2ZUZpbGVTZWN1cml0eUNoZWNrU3RhcnRpbmcodG9rZW4pID0+IENvbUNhbGwoMTMyLCB0aGlzLCAnaW50NjQnLCB0b2tlbikNCg0KCQlzdGF0aWMgSUlEXzI3IDo9ICd7MDBmYmUzM2ItOGMwNy01MTdjLWFhMjMtMGRkZDRiNWY2ZmEwfScNCgkJLyoqIEBwYXJhbSB7KHNlbmRlcjogV2ViVmlldzIuQ29yZSwgYXJnczogV2ViVmlldzIuU2NyZWVuQ2FwdHVyZVN0YXJ0aW5nRXZlbnRBcmdzKSA9PiB2b2lkfSBldmVudEhhbmRsZXIgKi8NCgkJYWRkX1NjcmVlbkNhcHR1cmVTdGFydGluZyhldmVudEhhbmRsZXIpID0+IChDb21DYWxsKDEzMywgdGhpcywgJ3B0cicsIGV2ZW50SGFuZGxlciwgJ2ludDY0KicsICZ0b2tlbiA6PSAwKSwgdG9rZW4pDQoJCXJlbW92ZV9TY3JlZW5DYXB0dXJlU3RhcnRpbmcodG9rZW4pID0+IENvbUNhbGwoMTM0LCB0aGlzLCAnaW50NjQnLCB0b2tlbikNCgl9DQoJY2xhc3MgQ2xpZW50Q2VydGlmaWNhdGUgZXh0ZW5kcyBXZWJWaWV3Mi5CYXNlIHsNCgkJc3RhdGljIElJRCA6PSAne2U3MTg4MDc2LWJjYzMtMTFlYi04NTI5LTAyNDJhYzEzMDAwM30nDQoJCVN1YmplY3QgPT4gKENvbUNhbGwoMywgdGhpcywgJ3B0cionLCAmdmFsdWUgOj0gMCksIENvVGFza01lbV9TdHJpbmcodmFsdWUpKQ0KCQlJc3N1ZXIgPT4gKENvbUNhbGwoNCwgdGhpcywgJ3B0cionLCAmdmFsdWUgOj0gMCksIENvVGFza01lbV9TdHJpbmcodmFsdWUpKQ0KCQlWYWxpZEZyb20gPT4gKENvbUNhbGwoNSwgdGhpcywgJ2RvdWJsZSonLCAmdmFsdWUgOj0gMCksIHZhbHVlKQ0KCQlWYWxpZFRvID0+IChDb21DYWxsKDYsIHRoaXMsICdkb3VibGUqJywgJnZhbHVlIDo9IDApLCB2YWx1ZSkNCgkJRGVyRW5jb2RlZFNlcmlhbE51bWJlciA9PiAoQ29tQ2FsbCg3LCB0aGlzLCAncHRyKicsICZ2YWx1ZSA6PSAwKSwgQ29UYXNrTWVtX1N0cmluZyh2YWx1ZSkpDQoJCURpc3BsYXlOYW1lID0+IChDb21DYWxsKDgsIHRoaXMsICdwdHIqJywgJnZhbHVlIDo9IDApLCBDb1Rhc2tNZW1fU3RyaW5nKHZhbHVlKSkNCgkJVG9QZW1FbmNvZGluZygpID0+IChDb21DYWxsKDksIHRoaXMsICdwdHIqJywgJnBlbUVuY29kZWREYXRhIDo9IDApLCBDb1Rhc2tNZW1fU3RyaW5nKHBlbUVuY29kZWREYXRhKSkNCgkJUGVtRW5jb2RlZElzc3VlckNlcnRpZmljYXRlQ2hhaW4gPT4gKENvbUNhbGwoMTAsIHRoaXMsICdwdHIqJywgdmFsdWUgOj0gV2ViVmlldzIuU3RyaW5nQ29sbGVjdGlvbigpKSwgdmFsdWUpDQoJCUtpbmQgPT4gKENvbUNhbGwoMTEsIHRoaXMsICdpbnQqJywgJnZhbHVlIDo9IDApLCB2YWx1ZSkJOyBDT1JFV0VCVklFVzJfQ0xJRU5UX0NFUlRJRklDQVRFX0tJTkQNCgl9DQoJY2xhc3MgQ3VzdG9tU2NoZW1lUmVnaXN0cmF0aW9uIGV4dGVuZHMgQnVmZmVyIHsNCgkJc3RhdGljIElJRCA6PSAne2Q2MGFjOTJjLTM3YTYtNGIyNi1hMzllLTk1Y2ZlNTkwNDdiYn0nDQoJCS8qKg0KCQkgKiBSZXByZXNlbnRzIHRoZSByZWdpc3RyYXRpb24gb2YgYSBjdXN0b20gc2NoZW1lIHdpdGggdGhlIENvcmVXZWJWaWV3MkVudmlyb25tZW50Lg0KCQkgKiBodHRwczovL2xlYXJuLm1pY3Jvc29mdC5jb20vZW4tdXMvbWljcm9zb2Z0LWVkZ2Uvd2VidmlldzIvcmVmZXJlbmNlL3dpbjMyL2ljb3Jld2VidmlldzJjdXN0b21zY2hlbWVyZWdpc3RyYXRpb24NCgkJICogQHBhcmFtIHtTdHJpbmd9IFNjaGVtZU5hbWUgVGhlIG5hbWUgb2YgdGhlIGN1c3RvbSBzY2hlbWUgdG8gcmVnaXN0ZXIuDQoJCSAqIEBwYXJhbSB7QXJyYXl9IEFsbG93ZWRPcmlnaW5zIFRoZSBhcnJheSBvZiBvcmlnaW5zIHRoYXQgYXJlIGFsbG93ZWQgdG8gdXNlIHRoZSBzY2hlbWUuDQoJCSAqIEBwYXJhbSBUcmVhdEFzU2VjdXJlIFdoZXRoZXIgdGhlIHNpdGVzIHdpdGggdGhpcyBzY2hlbWUgd2lsbCBiZSB0cmVhdGVkIGFzIGEgU2VjdXJlIENvbnRleHQgbGlrZSBhbiBIVFRQUyBzaXRlLg0KCQkgKiBAcGFyYW0gSGFzQXV0aG9yaXR5Q29tcG9uZW50IFNldCB0aGlzIHByb3BlcnR5IHRvIHRydWUgaWYgdGhlIFVSSXMgd2l0aCB0aGlzIGN1c3RvbSBzY2hlbWUgd2lsbCBoYXZlIGFuIGF1dGhvcml0eSBjb21wb25lbnQgKGEgaG9zdCBmb3IgY3VzdG9tIHNjaGVtZXMpLg0KCQkgKi8NCgkJX19OZXcoU2NoZW1lTmFtZSwgQWxsb3dlZE9yaWdpbnMsIFRyZWF0QXNTZWN1cmUgOj0gZmFsc2UsIEhhc0F1dGhvcml0eUNvbXBvbmVudCA6PSBmYWxzZSkgew0KCQkJc3VwZXIuX19OZXcoMTEgKiBBX1B0clNpemUpDQoJCQlwX3RoaXMgOj0gT2JqUHRyKHRoaXMpLCBwX3VuayA6PSB0aGlzLlB0ciArIEFfUHRyU2l6ZQ0KCQkJcCA6PSBOdW1QdXQoJ3B0cicsIHBfdW5rLCB0aGlzKSwgZm5wdHJzIDo9IFtdDQoJCQl0aGlzLkRlZmluZVByb3AoJ19fRGVsZXRlJywgeyBjYWxsOiBfX0RlbGV0ZSB9KQ0KCQkJZm9yIGNiIGluIFsNCgkJCQlRdWVyeUludGVyZmFjZSwgQWRkUmVmLCBSZWxlYXNlLA0KCQkJCWdldF9TY2hlbWVOYW1lLCBnZXRfVHJlYXRBc1NlY3VyZSwgcHV0X3h4eCwNCgkJCQlHZXRBbGxvd2VkT3JpZ2lucywgU2V0QWxsb3dlZE9yaWdpbnMsDQoJCQkJZ2V0X0hhc0F1dGhvcml0eUNvbXBvbmVudCwgcHV0X3h4eA0KCQkJXQ0KCQkJCXAgOj0gTnVtUHV0KCdwdHInLCBfIDo9IENhbGxiYWNrQ3JlYXRlKGNiKSwgcCksIGZucHRycy5QdXNoKF8pDQoJCQlRdWVyeUludGVyZmFjZSh0aGlzLCByaWlkLCBwcHZPYmplY3QpIHsNCgkJCQlEbGxDYWxsKCJvbGUzMi5kbGxcU3RyaW5nRnJvbUdVSUQyIiwgInB0ciIsIHJpaWQsICJwdHIiLCBidWYgOj0gQnVmZmVyKDc4KSwgImludCIsIDM5KQ0KCQkJCWlpZCA6PSBTdHJHZXQoYnVmKQ0KCQkJCWlmIGlpZCA9ICd7ZDYwYWM5MmMtMzdhNi00YjI2LWEzOWUtOTVjZmU1OTA0N2JifScgew0KCQkJCQlPYmpBZGRSZWYocF90aGlzKSwgTnVtUHV0KCdwdHInLCBwX3VuaywgcHB2T2JqZWN0KQ0KCQkJCQlyZXR1cm4gMA0KCQkJCX0NCgkJCQlOdW1QdXQoJ3B0cicsIDAsIHBwdk9iamVjdCkNCgkJCQlyZXR1cm4gMHg4MDAwNDAwMg0KCQkJfQ0KCQkJQWRkUmVmKHRoaXMpID0+IE9iakFkZFJlZihwX3RoaXMpDQoJCQlSZWxlYXNlKHRoaXMpID0+IE9ialJlbGVhc2UocF90aGlzKQ0KCQkJcHV0X3h4eCh0aGlzLCB2YWx1ZSkgPT4gMA0KCQkJZ2V0X1NjaGVtZU5hbWUodGhpcywgcHZhbHVlKSB7DQoJCQkJcCA6PSBEbGxDYWxsKCdvbGUzMlxDb1Rhc2tNZW1BbGxvYycsICd1cHRyJywgcyA6PSBTdHJMZW4oU2NoZW1lTmFtZSkgKiAyICsgMiwgJ3B0cicpDQoJCQkJRGxsQ2FsbCgnUnRsTW92ZU1lbW9yeScsICdwdHInLCBwLCAncHRyJywgU3RyUHRyKFNjaGVtZU5hbWUpLCAndXB0cicsIHMpDQoJCQkJcmV0dXJuIChOdW1QdXQoJ3B0cicsIHAsIHB2YWx1ZSksIDApDQoJCQl9DQoJCQlnZXRfVHJlYXRBc1NlY3VyZSh0aGlzLCBwdmFsdWUpID0+IChOdW1QdXQoJ2ludCcsIFRyZWF0QXNTZWN1cmUsIHB2YWx1ZSksIDApDQoJCQlnZXRfSGFzQXV0aG9yaXR5Q29tcG9uZW50KHRoaXMsIHB2YWx1ZSkgPT4gKE51bVB1dCgnaW50JywgSGFzQXV0aG9yaXR5Q29tcG9uZW50LCBwdmFsdWUpLCAwKQ0KCQkJR2V0QWxsb3dlZE9yaWdpbnModGhpcywgcGFsbG93ZWRPcmlnaW5zQ291bnQsIHBhbGxvd2VkT3JpZ2lucykgew0KCQkJCWxvY2FsIGwsIHAsIHAsIHBzDQoJCQkJTnVtUHV0KCd1aW50JywgbCA6PSBBbGxvd2VkT3JpZ2lucy5MZW5ndGgsIHBhbGxvd2VkT3JpZ2luc0NvdW50KQ0KCQkJCWlmIGwgew0KCQkJCQlwIDo9IHAgOj0gRGxsQ2FsbCgnb2xlMzJcQ29UYXNrTWVtQWxsb2MnLCAndXB0cicsIGwgKiBBX1B0clNpemUsICdwdHInKQ0KCQkJCQlmb3Igb3JpZ2luIGluIEFsbG93ZWRPcmlnaW5zIHsNCgkJCQkJCXBzIDo9IERsbENhbGwoJ29sZTMyXENvVGFza01lbUFsbG9jJywgJ3VwdHInLCBzIDo9IFN0ckxlbihvcmlnaW4pICogMiArIDIsICdwdHInKQ0KCQkJCQkJRGxsQ2FsbCgnUnRsTW92ZU1lbW9yeScsICdwdHInLCBwcywgJ3B0cicsIFN0clB0cihvcmlnaW4pLCAndXB0cicsIHMpDQoJCQkJCQlwIDo9IE51bVB1dCgncHRyJywgcHMsIHApDQoJCQkJCX0NCgkJCQl9IGVsc2UgcCA6PSAwDQoJCQkJTnVtUHV0KCdwdHInLCBwLCBwYWxsb3dlZE9yaWdpbnMpDQoJCQkJcmV0dXJuIDANCgkJCX0NCgkJCVNldEFsbG93ZWRPcmlnaW5zKHRoaXMsIGFsbG93ZWRPcmlnaW5zQ291bnQsIHBhbGxvd2VkT3JpZ2lucykgew0KCQkJCUFsbG93ZWRPcmlnaW5zIDo9IFtdDQoJCQkJbG9vcCBhbGxvd2VkT3JpZ2luc0NvdW50DQoJCQkJCUFsbG93ZWRPcmlnaW5zLlB1c2goU3RyR2V0KE51bUdldChwYWxsb3dlZE9yaWdpbnMsIChBX0luZGV4IC0gMSkgKiBBX1B0clNpemUsICdwdHInKSkpDQoJCQkJcmV0dXJuIDANCgkJCX0NCgkJCV9fRGVsZXRlKCopIHsNCgkJCQlmb3IgcHRyIGluIGZucHRycw0KCQkJCQlDYWxsYmFja0ZyZWUocHRyKQ0KCQkJfQ0KCQl9DQoJfQ0KCWNsYXNzIENsaWVudENlcnRpZmljYXRlQ29sbGVjdGlvbiBleHRlbmRzIFdlYlZpZXcyLkxpc3Qgew0KCQlzdGF0aWMgSUlEIDo9ICd7ZWY1Njc0ZDItYmNjMy0xMWViLTg1MjktMDI0MmFjMTMwMDAzfScNCgkJQ291bnQgPT4gKENvbUNhbGwoMywgdGhpcywgJ3VpbnQqJywgJnZhbHVlIDo9IDApLCB2YWx1ZSkNCgkJR2V0VmFsdWVBdEluZGV4KGluZGV4KSA9PiAoQ29tQ2FsbCg0LCB0aGlzLCAndWludCcsIGluZGV4LCAncHRyKicsIGNlcnRpZmljYXRlIDo9IFdlYlZpZXcyLkNsaWVudENlcnRpZmljYXRlKCkpLCBjZXJ0aWZpY2F0ZSkNCgl9DQoJY2xhc3MgQ2xpZW50Q2VydGlmaWNhdGVSZXF1ZXN0ZWRFdmVudEFyZ3MgZXh0ZW5kcyBXZWJWaWV3Mi5CYXNlIHsNCgkJc3RhdGljIElJRCA6PSAne2JjNTlkYjI4LWJjYzMtMTFlYi04NTI5LTAyNDJhYzEzMDAwM30nDQoJCUhvc3QgPT4gKENvbUNhbGwoMywgdGhpcywgJ3B0cionLCAmdmFsdWUgOj0gMCksIENvVGFza01lbV9TdHJpbmcodmFsdWUpKQ0KCQlQb3J0ID0+IChDb21DYWxsKDQsIHRoaXMsICdpbnQqJywgJnZhbHVlIDo9IDApLCB2YWx1ZSkNCgkJSXNQcm94eSA9PiAoQ29tQ2FsbCg1LCB0aGlzLCAnaW50KicsICZ2YWx1ZSA6PSAwKSwgdmFsdWUpDQoJCUFsbG93ZWRDZXJ0aWZpY2F0ZUF1dGhvcml0aWVzID0+IChDb21DYWxsKDYsIHRoaXMsICdwdHIqJywgdmFsdWUgOj0gV2ViVmlldzIuU3RyaW5nQ29sbGVjdGlvbigpKSwgdmFsdWUpDQoJCU11dHVhbGx5VHJ1c3RlZENlcnRpZmljYXRlcyA9PiAoQ29tQ2FsbCg3LCB0aGlzLCAncHRyKicsIHZhbHVlIDo9IFdlYlZpZXcyLkNsaWVudENlcnRpZmljYXRlQ29sbGVjdGlvbigpKSwgdmFsdWUpDQoJCVNlbGVjdGVkQ2VydGlmaWNhdGUgew0KCQkJZ2V0ID0+IChDb21DYWxsKDgsIHRoaXMsICdwdHIqJywgdmFsdWUgOj0gV2ViVmlldzIuQ2xpZW50Q2VydGlmaWNhdGUoKSksIHZhbHVlKQ0KCQkJc2V0ID0+IENvbUNhbGwoOSwgdGhpcywgJ3B0cicsIFZhbHVlKQ0KCQl9DQoJCUNhbmNlbCB7DQoJCQlnZXQgPT4gKENvbUNhbGwoMTAsIHRoaXMsICdpbnQqJywgJnZhbHVlIDo9IDApLCB2YWx1ZSkNCgkJCXNldCA9PiBDb21DYWxsKDExLCB0aGlzLCAnaW50JywgVmFsdWUpDQoJCX0NCgkJSGFuZGxlZCB7DQoJCQlnZXQgPT4gKENvbUNhbGwoMTIsIHRoaXMsICdpbnQqJywgJnZhbHVlIDo9IDApLCB2YWx1ZSkNCgkJCXNldCA9PiBDb21DYWxsKDEzLCB0aGlzLCAnaW50JywgVmFsdWUpDQoJCX0NCgkJR2V0RGVmZXJyYWwoKSA9PiAoQ29tQ2FsbCgxNCwgdGhpcywgJ3B0cionLCBkZWZlcnJhbCA6PSBXZWJWaWV3Mi5EZWZlcnJhbCgpKSwgZGVmZXJyYWwpDQoJfQ0KCWNsYXNzIERPTUNvbnRlbnRMb2FkZWRFdmVudEFyZ3MgZXh0ZW5kcyBXZWJWaWV3Mi5CYXNlIHsNCgkJc3RhdGljIElJRCA6PSAnezE2QjFFMjFBLUM1MDMtNDRGMi04NEM5LTcwQUJBNTAzMTI4M30nDQoJCU5hdmlnYXRpb25JZCA9PiAoQ29tQ2FsbCgzLCB0aGlzLCAnaW50NjQqJywgJm5hdmlnYXRpb25JZCA6PSAwKSwgbmF2aWdhdGlvbklkKQ0KCX0NCgljbGFzcyBEZWZlcnJhbCBleHRlbmRzIFdlYlZpZXcyLkJhc2Ugew0KCQlzdGF0aWMgSUlEIDo9ICd7YzEwZTdmN2ItYjU4NS00NmYwLWE2MjMtOGJlZmJmM2U0ZWUwfScNCgkJQ29tcGxldGUoKSA9PiBDb21DYWxsKDMsIHRoaXMpDQoJfQ0KCWNsYXNzIERldlRvb2xzUHJvdG9jb2xFdmVudFJlY2VpdmVkRXZlbnRBcmdzIGV4dGVuZHMgV2ViVmlldzIuQmFzZSB7DQoJCXN0YXRpYyBJSUQgOj0gJ3s2NTNjMjk1OS1iYjNhLTQzNzctODYzMi1iNThhZGE0ZTY2YzR9Jw0KCQlQYXJhbWV0ZXJPYmplY3RBc0pzb24gPT4gKENvbUNhbGwoMywgdGhpcywgJ3B0cionLCAmcGFyYW1ldGVyT2JqZWN0QXNKc29uIDo9IDApLCBDb1Rhc2tNZW1fU3RyaW5nKHBhcmFtZXRlck9iamVjdEFzSnNvbikpDQoNCgkJc3RhdGljIElJRF8yIDo9ICd7MkRDNDk1OUQtMTQ5NC00MzkzLTk1QkEtQkVBNENCOUVCRDFCfScNCgkJU2Vzc2lvbklkID0+IChDb21DYWxsKDQsIHRoaXMsICdwdHIqJywgJnNlc3Npb25JZCA6PSAwKSwgQ29UYXNrTWVtX1N0cmluZyhzZXNzaW9uSWQpKQ0KCX0NCgljbGFzcyBEZXZUb29sc1Byb3RvY29sRXZlbnRSZWNlaXZlciBleHRlbmRzIFdlYlZpZXcyLkJhc2Ugew0KCQlzdGF0aWMgSUlEIDo9ICd7YjMyY2E1MWEtODM3MS00NWU5LTkzMTctYWYwMjFkMDgwMzY3fScNCgkJLyoqIEBwYXJhbSB7KHNlbmRlcjogV2ViVmlldzIuRGV2VG9vbHNQcm90b2NvbEV2ZW50UmVjZWl2ZXIsIGFyZ3M6IFdlYlZpZXcyLkRldlRvb2xzUHJvdG9jb2xFdmVudFJlY2VpdmVkRXZlbnRBcmdzKSA9PiB2b2lkfSBldmVudEhhbmRsZXIgKi8NCgkJYWRkX0RldlRvb2xzUHJvdG9jb2xFdmVudFJlY2VpdmVkKGV2ZW50SGFuZGxlcikgPT4gKENvbUNhbGwoMywgdGhpcywgJ3B0cicsIGV2ZW50SGFuZGxlciwgJ2ludDY0KicsICZ0b2tlbiA6PSAwKSwgdG9rZW4pCTsgSUNvcmVXZWJWaWV3MkRldlRvb2xzUHJvdG9jb2xFdmVudFJlY2VpdmVkRXZlbnRIYW5kbGVyDQoJCXJlbW92ZV9EZXZUb29sc1Byb3RvY29sRXZlbnRSZWNlaXZlZCh0b2tlbikgPT4gQ29tQ2FsbCg0LCB0aGlzLCAnaW50NjQnLCB0b2tlbikNCgl9DQoJY2xhc3MgRG93bmxvYWRPcGVyYXRpb24gZXh0ZW5kcyBXZWJWaWV3Mi5CYXNlIHsNCgkJc3RhdGljIElJRCA6PSAnezNkNmI2Y2YyLWFmZTEtNDRjNy1hOTk1LWM2NTExNzcxNDMzNn0nDQoJCS8qKiBAcGFyYW0geyhzZW5kZXI6IFdlYlZpZXcyLkRvd25sb2FkT3BlcmF0aW9uLCBhcmdzOiBJVW5rbm93bikgPT4gdm9pZH0gZXZlbnRIYW5kbGVyICovDQoJCWFkZF9CeXRlc1JlY2VpdmVkQ2hhbmdlZChldmVudEhhbmRsZXIpID0+IChDb21DYWxsKDMsIHRoaXMsICdwdHInLCBldmVudEhhbmRsZXIsICdpbnQ2NConLCAmdG9rZW4gOj0gMCksIHRva2VuKQk7IElDb3JlV2ViVmlldzJCeXRlc1JlY2VpdmVkQ2hhbmdlZEV2ZW50SGFuZGxlcg0KCQlyZW1vdmVfQnl0ZXNSZWNlaXZlZENoYW5nZWQodG9rZW4pID0+IENvbUNhbGwoNCwgdGhpcywgJ2ludDY0JywgdG9rZW4pDQoJCS8qKiBAcGFyYW0geyhzZW5kZXI6IFdlYlZpZXcyLkRvd25sb2FkT3BlcmF0aW9uLCBhcmdzOiBJVW5rbm93bikgPT4gdm9pZH0gZXZlbnRIYW5kbGVyICovDQoJCWFkZF9Fc3RpbWF0ZWRFbmRUaW1lQ2hhbmdlZChldmVudEhhbmRsZXIpID0+IChDb21DYWxsKDUsIHRoaXMsICdwdHInLCBldmVudEhhbmRsZXIsICdpbnQ2NConLCAmdG9rZW4gOj0gMCksIHRva2VuKQk7IElDb3JlV2ViVmlldzJFc3RpbWF0ZWRFbmRUaW1lQ2hhbmdlZEV2ZW50SGFuZGxlcg0KCQlyZW1vdmVfRXN0aW1hdGVkRW5kVGltZUNoYW5nZWQodG9rZW4pID0+IENvbUNhbGwoNiwgdGhpcywgJ2ludDY0JywgdG9rZW4pDQoJCS8qKiBAcGFyYW0geyhzZW5kZXI6IFdlYlZpZXcyLkRvd25sb2FkT3BlcmF0aW9uLCBhcmdzOiBJVW5rbm93bikgPT4gdm9pZH0gZXZlbnRIYW5kbGVyICovDQoJCWFkZF9TdGF0ZUNoYW5nZWQoZXZlbnRIYW5kbGVyKSA9PiAoQ29tQ2FsbCg3LCB0aGlzLCAncHRyJywgZXZlbnRIYW5kbGVyLCAnaW50NjQqJywgJnRva2VuIDo9IDApLCB0b2tlbikJOyBJQ29yZVdlYlZpZXcyU3RhdGVDaGFuZ2VkRXZlbnRIYW5kbGVyDQoJCXJlbW92ZV9TdGF0ZUNoYW5nZWQodG9rZW4pID0+IENvbUNhbGwoOCwgdGhpcywgJ2ludDY0JywgdG9rZW4pDQoJCVVyaSA9PiAoQ29tQ2FsbCg5LCB0aGlzLCAncHRyKicsICZ1cmkgOj0gMCksIENvVGFza01lbV9TdHJpbmcodXJpKSkNCgkJQ29udGVudERpc3Bvc2l0aW9uID0+IChDb21DYWxsKDEwLCB0aGlzLCAncHRyKicsICZjb250ZW50RGlzcG9zaXRpb24gOj0gMCksIENvVGFza01lbV9TdHJpbmcoY29udGVudERpc3Bvc2l0aW9uKSkNCgkJTWltZVR5cGUgPT4gKENvbUNhbGwoMTEsIHRoaXMsICdwdHIqJywgJm1pbWVUeXBlIDo9IDApLCBDb1Rhc2tNZW1fU3RyaW5nKG1pbWVUeXBlKSkNCgkJVG90YWxCeXRlc1RvUmVjZWl2ZSA9PiAoQ29tQ2FsbCgxMiwgdGhpcywgJ2ludDY0KicsICZ0b3RhbEJ5dGVzVG9SZWNlaXZlIDo9IDApLCB0b3RhbEJ5dGVzVG9SZWNlaXZlKQ0KCQlCeXRlc1JlY2VpdmVkID0+IChDb21DYWxsKDEzLCB0aGlzLCAnaW50NjQqJywgJmJ5dGVzUmVjZWl2ZWQgOj0gMCksIGJ5dGVzUmVjZWl2ZWQpDQoJCUVzdGltYXRlZEVuZFRpbWUgPT4gKENvbUNhbGwoMTQsIHRoaXMsICdwdHIqJywgJmVzdGltYXRlZEVuZFRpbWUgOj0gMCksIENvVGFza01lbV9TdHJpbmcoZXN0aW1hdGVkRW5kVGltZSkpDQoJCVJlc3VsdEZpbGVQYXRoID0+IChDb21DYWxsKDE1LCB0aGlzLCAncHRyKicsICZyZXN1bHRGaWxlUGF0aCA6PSAwKSwgQ29UYXNrTWVtX1N0cmluZyhyZXN1bHRGaWxlUGF0aCkpDQoJCVN0YXRlID0+IChDb21DYWxsKDE2LCB0aGlzLCAnaW50KicsICZkb3dubG9hZFN0YXRlIDo9IDApLCBkb3dubG9hZFN0YXRlKQk7IENPUkVXRUJWSUVXMl9ET1dOTE9BRF9TVEFURQ0KCQlJbnRlcnJ1cHRSZWFzb24gPT4gKENvbUNhbGwoMTcsIHRoaXMsICdpbnQqJywgJmludGVycnVwdFJlYXNvbiA6PSAwKSwgaW50ZXJydXB0UmVhc29uKQk7IENPUkVXRUJWSUVXMl9ET1dOTE9BRF9JTlRFUlJVUFRfUkVBU09ODQoJCUNhbmNlbCgpID0+IENvbUNhbGwoMTgsIHRoaXMpDQoJCVBhdXNlKCkgPT4gQ29tQ2FsbCgxOSwgdGhpcykNCgkJUmVzdW1lKCkgPT4gQ29tQ2FsbCgyMCwgdGhpcykNCgkJQ2FuUmVzdW1lID0+IChDb21DYWxsKDIxLCB0aGlzLCAnaW50KicsICZjYW5SZXN1bWUgOj0gMCksIGNhblJlc3VtZSkNCgl9DQoJY2xhc3MgRG93bmxvYWRTdGFydGluZ0V2ZW50QXJncyBleHRlbmRzIFdlYlZpZXcyLkJhc2Ugew0KCQlzdGF0aWMgSUlEIDo9ICd7ZTk5YmJlMjEtNDNlOS00NTQ0LWE3MzItMjgyNzY0ZWFmYTYwfScNCgkJRG93bmxvYWRPcGVyYXRpb24gPT4gKENvbUNhbGwoMywgdGhpcywgJ3B0cionLCBkb3dubG9hZE9wZXJhdGlvbiA6PSBXZWJWaWV3Mi5Eb3dubG9hZE9wZXJhdGlvbigpKSwgZG93bmxvYWRPcGVyYXRpb24pDQoJCUNhbmNlbCB7DQoJCQlnZXQgPT4gKENvbUNhbGwoNCwgdGhpcywgJ2ludConLCAmY2FuY2VsIDo9IDApLCBjYW5jZWwpDQoJCQlzZXQgPT4gQ29tQ2FsbCg1LCB0aGlzLCAnaW50JywgVmFsdWUpDQoJCX0NCgkJUmVzdWx0RmlsZVBhdGggew0KCQkJZ2V0ID0+IChDb21DYWxsKDYsIHRoaXMsICdwdHIqJywgJnJlc3VsdEZpbGVQYXRoIDo9IDApLCBDb1Rhc2tNZW1fU3RyaW5nKHJlc3VsdEZpbGVQYXRoKSkNCgkJCXNldCA9PiBDb21DYWxsKDcsIHRoaXMsICd3c3RyJywgVmFsdWUpDQoJCX0NCgkJSGFuZGxlZCB7DQoJCQlnZXQgPT4gKENvbUNhbGwoOCwgdGhpcywgJ2ludConLCAmaGFuZGxlZCA6PSAwKSwgaGFuZGxlZCkNCgkJCXNldCA9PiBDb21DYWxsKDksIHRoaXMsICdpbnQnLCBWYWx1ZSkNCgkJfQ0KCQlHZXREZWZlcnJhbCgpID0+IChDb21DYWxsKDEwLCB0aGlzLCAncHRyKicsIGRlZmVycmFsIDo9IFdlYlZpZXcyLkRlZmVycmFsKCkpLCBkZWZlcnJhbCkNCgl9DQoJY2xhc3MgRW52aXJvbm1lbnQgZXh0ZW5kcyBXZWJWaWV3Mi5CYXNlIHsNCgkJc3RhdGljIElJRCA6PSAne2I5NmQ3NTVlLTAzMTktNGU5Mi1hMjk2LTIzNDM2ZjQ2YTFmY30nDQoJCS8qKiBAcmV0dXJucyB7UHJvbWlzZTxXZWJWaWV3Mi5Db250cm9sbGVyPn0gKi8NCgkJQ3JlYXRlQ29yZVdlYlZpZXcyQ29udHJvbGxlckFzeW5jKHBhcmVudFdpbmRvdykgPT4gKENvbUNhbGwoMywgdGhpcywgJ3B0cicsIHBhcmVudFdpbmRvdywgJ3B0cicsIFdlYlZpZXcyLkFzeW5jSGFuZGxlcigmcCwgV2ViVmlldzIuQ29udHJvbGxlcikpLCBwLnRoZW4ociA9PiByLkZpbGwoKSkpDQoJCUNyZWF0ZVdlYlJlc291cmNlUmVzcG9uc2UoY29udGVudCwgc3RhdHVzQ29kZSwgcmVhc29uUGhyYXNlLCBoZWFkZXJzKSA9PiAoQ29tQ2FsbCg0LCB0aGlzLCAncHRyJywgY29udGVudCwgJ2ludCcsIHN0YXR1c0NvZGUsICd3c3RyJywgcmVhc29uUGhyYXNlLCAnd3N0cicsIGhlYWRlcnMsICdwdHIqJywgcmVzcG9uc2UgOj0gV2ViVmlldzIuV2ViUmVzb3VyY2VSZXNwb25zZSgpKSwgcmVzcG9uc2UpDQoJCUJyb3dzZXJWZXJzaW9uU3RyaW5nID0+IChDb21DYWxsKDUsIHRoaXMsICdwdHIqJywgJnZlcnNpb25JbmZvIDo9IDApLCBDb1Rhc2tNZW1fU3RyaW5nKHZlcnNpb25JbmZvKSkNCgkJLyoqIEBwYXJhbSB7KHNlbmRlcjogV2ViVmlldzIuRW52aXJvbm1lbnQsIGFyZ3M6IElVbmtub3duKSA9PiB2b2lkfSBldmVudEhhbmRsZXIgKi8NCgkJYWRkX05ld0Jyb3dzZXJWZXJzaW9uQXZhaWxhYmxlKGV2ZW50SGFuZGxlcikgPT4gKENvbUNhbGwoNiwgdGhpcywgJ3B0cicsIGV2ZW50SGFuZGxlciwgJ2ludDY0KicsICZ0b2tlbiA6PSAwKSwgdG9rZW4pCTsgSUNvcmVXZWJWaWV3Mk5ld0Jyb3dzZXJWZXJzaW9uQXZhaWxhYmxlRXZlbnRIYW5kbGVyDQoJCXJlbW92ZV9OZXdCcm93c2VyVmVyc2lvbkF2YWlsYWJsZSh0b2tlbikgPT4gQ29tQ2FsbCg3LCB0aGlzLCAnaW50NjQnLCB0b2tlbikNCg0KCQlzdGF0aWMgSUlEXzIgOj0gJ3s0MUYzNjMyQi01RUY0LTQwNEYtQUQ4Mi0yRDYwNkM1QTlBMjF9Jw0KCQlDcmVhdGVXZWJSZXNvdXJjZVJlcXVlc3QodXJpLCBtZXRob2QsIHBvc3REYXRhLCBoZWFkZXJzKSA9PiAoQ29tQ2FsbCg4LCB0aGlzLCAnd3N0cicsIHVyaSwgJ3dzdHInLCBtZXRob2QsICdwdHInLCBwb3N0RGF0YSwgJ3dzdHInLCBoZWFkZXJzLCAncHRyKicsIHJlcXVlc3QgOj0gV2ViVmlldzIuV2ViUmVzb3VyY2VSZXF1ZXN0KCkpLCByZXF1ZXN0KQ0KDQoJCXN0YXRpYyBJSURfMyA6PSAnezgwYTIyYWUzLWJlN2MtNGNlMi1hZmUxLTVhNTAwNTZjZGVlYn0nDQoJCS8qKiBAcmV0dXJucyB7UHJvbWlzZTxXZWJWaWV3Mi5Db21wb3NpdGlvbkNvbnRyb2xsZXI+fSAqLw0KCQlDcmVhdGVDb3JlV2ViVmlldzJDb21wb3NpdGlvbkNvbnRyb2xsZXJBc3luYyhwYXJlbnRXaW5kb3cpID0+IChDb21DYWxsKDksIHRoaXMsICdwdHInLCBwYXJlbnRXaW5kb3csICdwdHInLCBXZWJWaWV3Mi5Bc3luY0hhbmRsZXIoJnAsIFdlYlZpZXcyLkNvbXBvc2l0aW9uQ29udHJvbGxlcikpLCBwKQ0KCQlDcmVhdGVDb3JlV2ViVmlldzJQb2ludGVySW5mbygpID0+IChDb21DYWxsKDEwLCB0aGlzLCAncHRyKicsIHBvaW50ZXJJbmZvIDo9IFdlYlZpZXcyLlBvaW50ZXJJbmZvKCkpLCBwb2ludGVySW5mbykNCg0KCQlzdGF0aWMgSUlEXzQgOj0gJ3syMDk0NDM3OS02ZGNmLTQxZDYtYTBhMC1hYmMwZmM1MGRlMGR9Jw0KCQlHZXRBdXRvbWF0aW9uUHJvdmlkZXJGb3JXaW5kb3coaHduZCkgPT4gKENvbUNhbGwoMTEsIHRoaXMsICdwdHInLCBod25kLCAncHRyKicsICZwcm92aWRlciA6PSAwKSwgQ29tVmFsdWUoMHhkLCBwcm92aWRlcikpDQoNCgkJc3RhdGljIElJRF81IDo9ICd7MzE5ZTQyM2QtZTBkNy00YjhkLTkyNTQtYWU5NDc1ZGU5YjE3fScNCgkJLyoqIEBwYXJhbSB7KHNlbmRlcjogV2ViVmlldzIuRW52aXJvbm1lbnQsIGFyZ3M6IFdlYlZpZXcyLkJyb3dzZXJQcm9jZXNzRXhpdGVkRXZlbnRBcmdzKSA9PiB2b2lkfSBldmVudEhhbmRsZXIgKi8NCgkJYWRkX0Jyb3dzZXJQcm9jZXNzRXhpdGVkKGV2ZW50SGFuZGxlcikgPT4gKENvbUNhbGwoMTIsIHRoaXMsICdwdHInLCBldmVudEhhbmRsZXIsICdpbnQ2NConLCAmdG9rZW4gOj0gMCksIHRva2VuKQk7IElDb3JlV2ViVmlldzJCcm93c2VyUHJvY2Vzc0V4aXRlZEV2ZW50SGFuZGxlcg0KCQlyZW1vdmVfQnJvd3NlclByb2Nlc3NFeGl0ZWQodG9rZW4pID0+IENvbUNhbGwoMTMsIHRoaXMsICdpbnQ2NCcsIHRva2VuKQ0KDQoJCXN0YXRpYyBJSURfNiA6PSAne2U1OWVlMzYyLWFjYmQtNDg1Ny05YThlLWQzNjQ0ZDk0NTlhOX0nDQoJCUNyZWF0ZVByaW50U2V0dGluZ3MoKSA9PiAoQ29tQ2FsbCgxNCwgdGhpcywgJ3B0cionLCBwcmludFNldHRpbmdzIDo9IFdlYlZpZXcyLlByaW50U2V0dGluZ3MoKSksIHByaW50U2V0dGluZ3MpDQoNCgkJc3RhdGljIElJRF83IDo9ICd7NDNDMjIyOTYtM0JCRC00M0E0LTlDMDAtNUMwREY2REQyOUEyfScNCgkJVXNlckRhdGFGb2xkZXIgPT4gKENvbUNhbGwoMTUsIHRoaXMsICdwdHIqJywgJnZhbHVlIDo9IDApLCBDb1Rhc2tNZW1fU3RyaW5nKHZhbHVlKSkNCg0KCQlzdGF0aWMgSUlEXzggOj0gJ3tENkVCOTFERC1DM0QyLTQ1RTUtQkQyOS02REMyQkM0REU5Q0Z9Jw0KCQkvKiogQHBhcmFtIHsoc2VuZGVyOiBXZWJWaWV3Mi5FbnZpcm9ubWVudCwgYXJnczogSVVua25vd24pID0+IHZvaWR9IGV2ZW50SGFuZGxlciAqLw0KCQlhZGRfUHJvY2Vzc0luZm9zQ2hhbmdlZChldmVudEhhbmRsZXIpID0+IChDb21DYWxsKDE2LCB0aGlzLCAncHRyJywgZXZlbnRIYW5kbGVyLCAnaW50NjQqJywgJnRva2VuIDo9IDApLCB0b2tlbikJOyBJQ29yZVdlYlZpZXcyUHJvY2Vzc0luZm9zQ2hhbmdlZEV2ZW50SGFuZGxlcg0KCQlyZW1vdmVfUHJvY2Vzc0luZm9zQ2hhbmdlZCh0b2tlbikgPT4gQ29tQ2FsbCgxNywgdGhpcywgJ2ludDY0JywgdG9rZW4pDQoJCUdldFByb2Nlc3NJbmZvcygpID0+IChDb21DYWxsKDE4LCB0aGlzLCAncHRyKicsIHZhbHVlIDo9IFdlYlZpZXcyLlByb2Nlc3NJbmZvQ29sbGVjdGlvbigpKSwgdmFsdWUpDQoNCgkJc3RhdGljIElJRF85IDo9ICd7ZjA2ZjQxYmYtNGI1YS00OWQ4LWI5ZjYtZmExNmNkMjlmMjc0fScNCgkJQ3JlYXRlQ29udGV4dE1lbnVJdGVtKGxhYmVsLCBpY29uU3RyZWFtLCBraW5kKSA9PiAoQ29tQ2FsbCgxOSwgdGhpcywgJ3dzdHInLCBsYWJlbCwgJ3B0cicsIGljb25TdHJlYW0sICdpbnQnLCBraW5kLCAncHRyKicsIGl0ZW0gOj0gV2ViVmlldzIuQ29udGV4dE1lbnVJdGVtKCkpLCBpdGVtKQk7IElTdHJlYW0qLCBDT1JFV0VCVklFVzJfQ09OVEVYVF9NRU5VX0lURU1fS0lORA0KDQoJCXN0YXRpYyBJSURfMTAgOj0gJ3tlZTBlYjlkZi02ZjEyLTQ2Y2UtYjUzZi0zZjQ3YjljOTI4ZTB9Jw0KCQlDcmVhdGVDb3JlV2ViVmlldzJDb250cm9sbGVyT3B0aW9ucygpID0+IChDb21DYWxsKDIwLCB0aGlzLCAncHRyKicsIG9wdGlvbnMgOj0gV2ViVmlldzIuQ29udHJvbGxlck9wdGlvbnMoKSksIG9wdGlvbnMpDQoJCS8qKiBAcmV0dXJucyB7UHJvbWlzZTxXZWJWaWV3Mi5Db250cm9sbGVyPn0gKi8NCgkJQ3JlYXRlQ29yZVdlYlZpZXcyQ29udHJvbGxlcldpdGhPcHRpb25zQXN5bmMocGFyZW50V2luZG93LCBvcHRpb25zKSA9PiAoQ29tQ2FsbCgyMSwgdGhpcywgJ3B0cicsIHBhcmVudFdpbmRvdywgJ3B0cicsIG9wdGlvbnMsICdwdHInLCBXZWJWaWV3Mi5Bc3luY0hhbmRsZXIoJnAsIFdlYlZpZXcyLkNvbnRyb2xsZXIpKSwgcC50aGVuKHIgPT4gci5GaWxsKCkpKQk7IElDb3JlV2ViVmlldzJDb250cm9sbGVyT3B0aW9ucw0KCQkvKiogQHJldHVybnMge1Byb21pc2U8V2ViVmlldzIuQ29tcG9zaXRpb25Db250cm9sbGVyPn0gKi8NCgkJQ3JlYXRlQ29yZVdlYlZpZXcyQ29tcG9zaXRpb25Db250cm9sbGVyV2l0aE9wdGlvbnNBc3luYyhwYXJlbnRXaW5kb3csIG9wdGlvbnMpID0+IChDb21DYWxsKDIyLCB0aGlzLCAncHRyJywgcGFyZW50V2luZG93LCAncHRyJywgb3B0aW9ucywgJ3B0cicsIFdlYlZpZXcyLkFzeW5jSGFuZGxlcigmcCwgV2ViVmlldzIuQ29tcG9zaXRpb25Db250cm9sbGVyKSksIHApCTsgSUNvcmVXZWJWaWV3MkNvbnRyb2xsZXJPcHRpb25zDQoNCgkJc3RhdGljIElJRF8xMSA6PSAne0YwOTEzREM2LUEwRUMtNDJFRi05ODA1LTkxREZGM0EyOTY2QX0nDQoJCUZhaWx1cmVSZXBvcnRGb2xkZXJQYXRoID0+IChDb21DYWxsKDIzLCB0aGlzLCAncHRyKicsICZ2YWx1ZSA6PSAwKSwgQ29UYXNrTWVtX1N0cmluZyh2YWx1ZSkpDQoNCgkJc3RhdGljIElJRF8xMiA6PSAne0Y1MDNEQjlCLTczOUYtNDhERC1CMTUxLUZERkNGMjUzRjU0RX0nDQoJCUNyZWF0ZVNoYXJlZEJ1ZmZlcihzaXplKSA9PiAoQ29tQ2FsbCgyNCwgdGhpcywgJ3VpbnQ2NCcsIHNpemUsICdwdHIqJywgc2hhcmVkX2J1ZmZlciA6PSBXZWJWaWV3Mi5TaGFyZWRCdWZmZXIoKSksIHNoYXJlZF9idWZmZXIpDQoNCgkJc3RhdGljIElJRF8xMyA6PSAne2FmNjQxZjU4LTcyYjItMTFlZS1iOTYyLTAyNDJhYzEyMDAwMn0nDQoJCS8qKiBAcmV0dXJucyB7UHJvbWlzZTxXZWJWaWV3Mi5Qcm9jZXNzRXh0ZW5kZWRJbmZvQ29sbGVjdGlvbj59ICovDQoJCUdldFByb2Nlc3NFeHRlbmRlZEluZm9zQXN5bmMoKSA9PiAoQ29tQ2FsbCgyNSwgdGhpcywgJ3B0cicsIFdlYlZpZXcyLkFzeW5jSGFuZGxlcigmcCwgV2ViVmlldzIuUHJvY2Vzc0V4dGVuZGVkSW5mb0NvbGxlY3Rpb24pKSwgcCkNCg0KCQlzdGF0aWMgSUlEXzE0IDo9ICdhNWU5ZmFkOS1jODc1LTU5ZGEtOWJkNy00NzNhYTVjYTFjZWYnDQoJCS8qKg0KCQkgKiBAcGFyYW0geyRGaWxlUGF0aH0gcGF0aA0KCQkgKiBAcGFyYW0ge1dlYlZpZXcyLkZJTEVfU1lTVEVNX0hBTkRMRV9QRVJNSVNTSU9OfSBwZXJtaXNzaW9uDQoJCSAqLw0KCQlDcmVhdGVXZWJGaWxlU3lzdGVtRmlsZUhhbmRsZShwYXRoLCBwZXJtaXNzaW9uKSA9PiBDb21DYWxsKDI2LCB0aGlzLCAnd3N0cicsIHBhdGgsICdpbnQnLCBwZXJtaXNzaW9uLCAncHRyKicsIHZhbHVlIDo9IFdlYlZpZXcyLkZpbGVTeXN0ZW1IYW5kbGUoKSwgdmFsdWUpDQoJCS8qKg0KCQkgKiBAcGFyYW0geyREaXJQYXRofSBwYXRoDQoJCSAqIEBwYXJhbSB7V2ViVmlldzIuRklMRV9TWVNURU1fSEFORExFX1BFUk1JU1NJT059IHBlcm1pc3Npb24NCgkJICovDQoJCUNyZWF0ZVdlYkZpbGVTeXN0ZW1EaXJlY3RvcnlIYW5kbGUocGF0aCwgcGVybWlzc2lvbikgPT4gQ29tQ2FsbCgyNywgdGhpcywgJ3dzdHInLCBwYXRoLCAnaW50JywgcGVybWlzc2lvbiwgJ3B0cionLCB2YWx1ZSA6PSBXZWJWaWV3Mi5GaWxlU3lzdGVtSGFuZGxlKCksIHZhbHVlKQ0KCQkvKiogQHBhcmFtIHtBcnJheTxJVW5rbm93bj59IG9iamVjdHMgKi8NCgkJQ3JlYXRlT2JqZWN0Q29sbGVjdGlvbihvYmplY3RzKSB7DQoJCQlpdGVtcyA6PSBCdWZmZXIoQV9QdHJTaXplICogbGVuIDo9IG9iamVjdHMuTGVuZ3RoKSwgcCA6PSBpdGVtcy5QdHINCgkJCWZvciBpdCBpbiBvYmplY3RzDQoJCQkJcCA6PSBOdW1QdXQoJ3B0cicsIGl0LlB0ciwgcCkNCgkJCUNvbUNhbGwoMjgsIHRoaXMsICd1aW50JywgbGVuLCAncHRyJywgaXRlbXMsICdwdHIqJywgb2JqZWN0Q29sbGVjdGlvbiA6PSBXZWJWaWV3Mi5PYmplY3RDb2xsZWN0aW9uKCkpDQoJCQlyZXR1cm4gb2JqZWN0Q29sbGVjdGlvbg0KCQl9DQoJfQ0KCWNsYXNzIEVudmlyb25tZW50T3B0aW9ucyBleHRlbmRzIEJ1ZmZlciB7DQoJCS8qKg0KCQkgKiBAcGFyYW0ge09iamVjdH0gb3B0cyBPcHRpb25zIHVzZWQgdG8gY3JlYXRlIFdlYlZpZXcyIEVudmlyb25tZW50Lg0KCQkgKiBAcGFyYW0ge1N0cmluZ30gb3B0cy5BZGRpdGlvbmFsQnJvd3NlckFyZ3VtZW50cyBDaGFuZ2VzIHRoZSBiZWhhdmlvciBvZiB0aGUgV2ViVmlldy4NCgkJICogQHBhcmFtIHtCb29sfSBvcHRzLkFsbG93U2luZ2xlU2lnbk9uVXNpbmdPU1ByaW1hcnlBY2NvdW50IFRoZSBBbGxvd1NpbmdsZVNpZ25PblVzaW5nT1NQcmltYXJ5QWNjb3VudCBwcm9wZXJ0eSBpcyB1c2VkIHRvIGVuYWJsZSBzaW5nbGUgc2lnbiBvbiB3aXRoIEF6dXJlIEFjdGl2ZSBEaXJlY3RvcnkgKEFBRCkgYW5kIHBlcnNvbmFsIE1pY3Jvc29mdCBBY2NvdW50IChNU0EpIHJlc291cmNlcyBpbnNpZGUgV2ViVmlldy4NCgkJICogQHBhcmFtIHtTdHJpbmd9IG9wdHMuTGFuZ3VhZ2UgVGhlIGRlZmF1bHQgZGlzcGxheSBsYW5ndWFnZSBmb3IgV2ViVmlldy4NCgkJICogQHBhcmFtIHtTdHJpbmd9IG9wdHMuVGFyZ2V0Q29tcGF0aWJsZUJyb3dzZXJWZXJzaW9uIFNwZWNpZmllcyB0aGUgdmVyc2lvbiBvZiB0aGUgV2ViVmlldzIgUnVudGltZSBiaW5hcmllcyByZXF1aXJlZCB0byBiZSBjb21wYXRpYmxlIHdpdGggeW91ciBhcHAuDQoJCSAqIEBwYXJhbSB7Qm9vbH0gb3B0cy5FeGNsdXNpdmVVc2VyRGF0YUZvbGRlckFjY2VzcyBXaGV0aGVyIG90aGVyIHByb2Nlc3NlcyBjYW4gY3JlYXRlIFdlYlZpZXcyIGZyb20gV2ViVmlldzJFbnZpcm9ubWVudCBjcmVhdGVkIHdpdGggdGhlIHNhbWUgdXNlciBkYXRhIGZvbGRlciBhbmQgdGhlcmVmb3JlIHNoYXJpbmcgdGhlIHNhbWUgV2ViVmlldyBicm93c2VyIHByb2Nlc3MgaW5zdGFuY2UuDQoJCSAqIEBwYXJhbSB7Qm9vbH0gb3B0cy5Jc0N1c3RvbUNyYXNoUmVwb3J0aW5nRW5hYmxlZCBXaGVuIElzQ3VzdG9tQ3Jhc2hSZXBvcnRpbmdFbmFibGVkIGlzIHNldCB0byBUUlVFLCBXaW5kb3dzIHdvbid0IHNlbmQgY3Jhc2ggZGF0YSB0byBNaWNyb3NvZnQgZW5kcG9pbnQuDQoJCSAqIEBwYXJhbSB7QXJyYXl9IG9wdHMuQ3VzdG9tU2NoZW1lUmVnaXN0cmF0aW9ucyBBcnJheSBvZiBjdXN0b20gc2NoZW1lIHJlZ2lzdHJhdGlvbnMuDQoJCSAqIEBwYXJhbSB7Qm9vbH0gb3B0cy5FbmFibGVUcmFja2luZ1ByZXZlbnRpb24gVGhlIEVuYWJsZVRyYWNraW5nUHJldmVudGlvbiBwcm9wZXJ0eSBpcyB1c2VkIHRvIGVuYWJsZS9kaXNhYmxlIHRyYWNraW5nIHByZXZlbnRpb24gZmVhdHVyZSBpbiBXZWJWaWV3Mi4NCgkJICogQHBhcmFtIHtCb29sfSBvcHRzLkFyZUJyb3dzZXJFeHRlbnNpb25zRW5hYmxlZCBXaGVuIEFyZUJyb3dzZXJFeHRlbnNpb25zRW5hYmxlZCBpcyBzZXQgdG8gdHJ1ZSwgbmV3IGV4dGVuc2lvbnMgY2FuIGJlIGFkZGVkIHRvIHVzZXIgcHJvZmlsZSBhbmQgdXNlZC4NCgkJICogQHBhcmFtIHtXZWJWaWV3Mi5DSEFOTkVMX1NFQVJDSF9LSU5EfSBvcHRzLkNoYW5uZWxTZWFyY2hLaW5kIFRoZSBDaGFubmVsU2VhcmNoS2luZCBwcm9wZXJ0eSBpcyBDb3JlV2ViVmlldzJDaGFubmVsU2VhcmNoS2luZC5Nb3N0U3RhYmxlIGJ5IGRlZmF1bHQgYW5kIGVudmlyb25tZW50IGNyZWF0aW9uIHNlYXJjaGVzIGZvciBhIHJlbGVhc2UgY2hhbm5lbCBvbiB0aGUgbWFjaGluZSBmcm9tIG1vc3QgdG8gbGVhc3Qgc3RhYmxlIHVzaW5nIHRoZSBmaXJzdCBjaGFubmVsIGZvdW5kLiBUaGUgZGVmYXVsdCBzZWFyY2ggb3JkZXIgaXM6IFdlYlZpZXcyIFJlbGVhc2UgLT4gQmV0YSAtPiBEZXYgLT4gQ2FuYXJ5Lg0KCQkgKiBAcGFyYW0ge1dlYlZpZXcyLlJFTEVBU0VfQ0hBTk5FTFN9IG9wdHMuUmVsZWFzZUNoYW5uZWxzIE9SIG9wZXJhdGlvbihzKSBjYW4gYmUgYXBwbGllZCB0byBtdWx0aXBsZSB0byBjcmVhdGUgYSBtYXNrLiBUaGUgZGVmYXVsdCB2YWx1ZSBpcyBhIG1hc2sgb2YgYWxsIHRoZSBjaGFubmVscy4gQnkgZGVmYXVsdCwgZW52aXJvbm1lbnQgY3JlYXRpb24gc2VhcmNoZXMgZm9yIGNoYW5uZWxzIGZyb20gbW9zdCB0byBsZWFzdCBzdGFibGUsIHVzaW5nIHRoZSBmaXJzdCBjaGFubmVsIGZvdW5kIG9uIHRoZSBkZXZpY2UuDQoJCSAqIEBwYXJhbSB7V2ViVmlldzIuU0NST0xMQkFSX1NUWUxFfSBvcHRzLlNjcm9sbEJhclN0eWxlIFRoZSBTY3JvbGxCYXIgc3R5bGUgYmVpbmcgc2V0IG9uIHRoZSBXZWJWaWV3MiBFbnZpcm9ubWVudC4NCgkJICovDQoJCV9fTmV3KG9wdHMpIHsNCgkJCWNicyA6PSBbDQoJCQkJOyBvcHRpb25zDQoJCQkJUXVlcnlJbnRlcmZhY2UsIEFkZFJlZiwgUmVsZWFzZSwNCgkJCQlnZXRfeHh4X3N0ci5CaW5kKCdBZGRpdGlvbmFsQnJvd3NlckFyZ3VtZW50cycpLCBwdXRfeHh4LA0KCQkJCWdldF94eHhfc3RyLkJpbmQoJ0xhbmd1YWdlJyksIHB1dF94eHgsDQoJCQkJZ2V0X3h4eF9zdHIuQmluZCgnVGFyZ2V0Q29tcGF0aWJsZUJyb3dzZXJWZXJzaW9uJyksIHB1dF94eHgsDQoJCQkJZ2V0X3h4eF9pbnQuQmluZCgnQWxsb3dTaW5nbGVTaWduT25Vc2luZ09TUHJpbWFyeUFjY291bnQnKSwgcHV0X3h4eCwNCgkJCQk7IG9wdGlvbnMyDQoJCQkJUXVlcnlJbnRlcmZhY2UsIEFkZFJlZiwgUmVsZWFzZSwNCgkJCQlnZXRfeHh4X2ludC5CaW5kKCdFeGNsdXNpdmVVc2VyRGF0YUZvbGRlckFjY2VzcycpLCBwdXRfeHh4LA0KCQkJCTsgb3B0aW9uczMNCgkJCQlRdWVyeUludGVyZmFjZSwgQWRkUmVmLCBSZWxlYXNlLA0KCQkJCWdldF94eHhfaW50LkJpbmQoJ0lzQ3VzdG9tQ3Jhc2hSZXBvcnRpbmdFbmFibGVkJyksIHB1dF94eHgsDQoJCQkJOyBvcHRpb25zNA0KCQkJCVF1ZXJ5SW50ZXJmYWNlLCBBZGRSZWYsIFJlbGVhc2UsDQoJCQkJR2V0Q3VzdG9tU2NoZW1lUmVnaXN0cmF0aW9ucywgU2V0Q3VzdG9tU2NoZW1lUmVnaXN0cmF0aW9ucywNCgkJCQk7IG9wdGlvbnM1DQoJCQkJUXVlcnlJbnRlcmZhY2UsIEFkZFJlZiwgUmVsZWFzZSwNCgkJCQlnZXRfeHh4X2ludC5CaW5kKCdFbmFibGVUcmFja2luZ1ByZXZlbnRpb24nKSwgcHV0X3h4eCwNCgkJCQk7IG9wdGlvbnM2DQoJCQkJUXVlcnlJbnRlcmZhY2UsIEFkZFJlZiwgUmVsZWFzZSwNCgkJCQlnZXRfeHh4X2ludC5CaW5kKCdBcmVCcm93c2VyRXh0ZW5zaW9uc0VuYWJsZWQnKSwgcHV0X3h4eCwNCgkJCQk7IG9wdGlvbnM3DQoJCQkJUXVlcnlJbnRlcmZhY2UsIEFkZFJlZiwgUmVsZWFzZSwNCgkJCQlnZXRfeHh4X2ludC5CaW5kKCdDaGFubmVsU2VhcmNoS2luZCcpLCBwdXRfeHh4LA0KCQkJCWdldF94eHhfaW50LkJpbmQoJ1JlbGVhc2VDaGFubmVscycpLCBwdXRfeHh4LA0KCQkJCTsgb3B0aW9uczgNCgkJCQlRdWVyeUludGVyZmFjZSwgQWRkUmVmLCBSZWxlYXNlLA0KCQkJCWdldF94eHhfaW50LkJpbmQoJ1Njcm9sbEJhclN0eWxlJyksIHB1dF94eHgsDQoJCQldDQoJCQluIDo9IDgsIGkgOj0gMA0KCQkJc3VwZXIuX19OZXcoKG4gKyBjYnMuTGVuZ3RoKSAqIEFfUHRyU2l6ZSkNCgkJCXBfdGhpcyA6PSBPYmpQdHIodGhpcyksIHBfdW5rIDo9IHRoaXMuUHRyLCBwIDo9IHBfdW5rICsgbiAqIEFfUHRyU2l6ZQ0KCQkJbXAgOj0gTWFwKCksIGZucHRycyA6PSBbXSwgdGhpcy5EZWZpbmVQcm9wKCdfX0RlbGV0ZScsIHsgY2FsbDogX19EZWxldGUgfSkNCgkJCWZvciBjYiBpbiBjYnMgew0KCQkJCWlmIGNiID09IFF1ZXJ5SW50ZXJmYWNlDQoJCQkJCU51bVB1dCgncHRyJywgcCwgdGhpcywgKGkrKykgKiBBX1B0clNpemUpDQoJCQkJcCA6PSBOdW1QdXQoJ3B0cicsIG1wLkdldChjYiwgMCkgfHwgbXBbY2JdIDo9IENhbGxiYWNrQ3JlYXRlKGNiLCAsIGNiLk1pblBhcmFtcyB8fCAyKSwgcCkNCgkJCX0NCgkJCWZvciBfLCBwIGluIG1wDQoJCQkJZm5wdHJzLlB1c2gocCkNCgkJCVF1ZXJ5SW50ZXJmYWNlKHRoaXMsIHJpaWQsIHBwdk9iamVjdCkgew0KCQkJCXN0YXRpYyBpaWRzIDo9IE1hcCgNCgkJCQkJJ3syRkRFMDhBOC0xRTlBLTQ3NjYtOEMwNS05NUE5Q0VCOUQxQzV9JywgMCwJOyBJQ29yZVdlYlZpZXcyRW52aXJvbm1lbnRPcHRpb25zDQoJCQkJCSd7RkY4NUM5OEEtMUJBNy00QTZCLTkwQzgtMkI3NTJDODlFOUUyfScsIDEsCTsgSUNvcmVXZWJWaWV3MkVudmlyb25tZW50T3B0aW9uczINCgkJCQkJJ3s0QTVDNDM2RS1BOUUzLTRBMkUtODlDMy05MTBEMzUxM0Y1Q0N9JywgMiwJOyBJQ29yZVdlYlZpZXcyRW52aXJvbm1lbnRPcHRpb25zMw0KCQkJCQkne0FDNTJEMTNGLTBEMzgtNDc1QS05RENBLTg3NjU4MEQ2NzkzRX0nLCAzLAk7IElDb3JlV2ViVmlldzJFbnZpcm9ubWVudE9wdGlvbnM0DQoJCQkJCSd7MEFFMzVENjQtQzQ3Ri00NDY0LTgxNEUtMjU5QzM0NUQxNTAxfScsIDQsCTsgSUNvcmVXZWJWaWV3MkVudmlyb25tZW50T3B0aW9uczUNCgkJCQkJJ3s1N0QyOUNDMy1DODRGLTQyQTAtQjBFMi1FRkZCRDVFMTc5REV9JywgNSwJOyBJQ29yZVdlYlZpZXcyRW52aXJvbm1lbnRPcHRpb25zNg0KCQkJCQkne0M0OEQ1MzlGLUUzOUYtNDQxQy1BRTY4LTFGNjZFNTcwQkRDNX0nLCA2LAk7IElDb3JlV2ViVmlldzJFbnZpcm9ubWVudE9wdGlvbnM3DQoJCQkJCSd7N2M3ZWNmNTEtZTkxOC01Y2FmLTg1M2MtZTlhMmJjYzI3Nzc1fScsIDcsCTsgSUNvcmVXZWJWaWV3MkVudmlyb25tZW50T3B0aW9uczgNCgkJCQkpDQoJCQkJRGxsQ2FsbCgib2xlMzIuZGxsXFN0cmluZ0Zyb21HVUlEMiIsICJwdHIiLCByaWlkLCAicHRyIiwgYnVmIDo9IEJ1ZmZlcig3OCksICJpbnQiLCAzOSkNCgkJCQlpZiAoaW5kZXggOj0gaWlkcy5HZXQoaWlkIDo9IFN0clVwcGVyKFN0ckdldChidWYpKSwgLTEpKSA+PSAwIHsNCgkJCQkJT2JqQWRkUmVmKHBfdGhpcykNCgkJCQkJTnVtUHV0KCdwdHInLCBwX3VuayArIGluZGV4ICogQV9QdHJTaXplLCBwcHZPYmplY3QpDQoJCQkJCXJldHVybiAwDQoJCQkJfQ0KCQkJCU51bVB1dCgncHRyJywgMCwgcHB2T2JqZWN0KQ0KCQkJCXJldHVybiAweDgwMDA0MDAyDQoJCQl9DQoJCQlBZGRSZWYodGhpcykgPT4gT2JqQWRkUmVmKHBfdGhpcykNCgkJCVJlbGVhc2UodGhpcykgPT4gT2JqUmVsZWFzZShwX3RoaXMpDQoJCQlwdXRfeHh4KHRoaXMsIHZhbHVlKSA9PiAwDQoJCQlnZXRfeHh4X3N0cihwcm9wLCB0aGlzLCBwdmFsdWUpIHsNCgkJCQlpZiBvcHRzLkhhc093blByb3AocHJvcCkgew0KCQkJCQlwIDo9IERsbENhbGwoJ29sZTMyXENvVGFza01lbUFsbG9jJywgJ3VwdHInLCBzIDo9IFN0ckxlbih2IDo9IG9wdHMuJXByb3AlKSAqIDIgKyAyLCAncHRyJykNCgkJCQkJRGxsQ2FsbCgnUnRsTW92ZU1lbW9yeScsICdwdHInLCBwLCAncHRyJywgU3RyUHRyKHYpLCAndXB0cicsIHMpDQoJCQkJfSBlbHNlIHAgOj0gMA0KCQkJCXJldHVybiAoTnVtUHV0KCdwdHInLCBwLCBwdmFsdWUpLCAwKQ0KCQkJfQ0KCQkJZ2V0X3h4eF9pbnQocHJvcCwgdGhpcywgcHZhbHVlKSB7DQoJCQkJaWYgb3B0cy5IYXNPd25Qcm9wKHByb3ApDQoJCQkJCXYgOj0gb3B0cy4lcHJvcCUNCgkJCQllbHNlIHN3aXRjaCBwcm9wIHsNCgkJCQkJY2FzZSAnRW5hYmxlVHJhY2tpbmdQcmV2ZW50aW9uJzogdiA6PSB0cnVlDQoJCQkJCWNhc2UgJ1JlbGVhc2VDaGFubmVscyc6IHYgOj0gMTUNCgkJCQkJZGVmYXVsdDogdiA6PSAwDQoJCQkJfQ0KCQkJCXJldHVybiAoTnVtUHV0KCdpbnQnLCB2LCBwdmFsdWUpLCAwKQ0KCQkJfQ0KCQkJR2V0Q3VzdG9tU2NoZW1lUmVnaXN0cmF0aW9ucyh0aGlzLCBwY291bnQsIHBzY2hlbWVSZWdpc3RyYXRpb25zKSB7DQoJCQkJaWYgb3B0cy5IYXNPd25Qcm9wKCdDdXN0b21TY2hlbWVSZWdpc3RyYXRpb25zJykgJiYgKGNzcnMgOj0gb3B0cy5DdXN0b21TY2hlbWVSZWdpc3RyYXRpb25zKS5MZW5ndGggew0KCQkJCQlOdW1QdXQoJ3VpbnQnLCBjc3JzLkxlbmd0aCwgcGNvdW50KQ0KCQkJCQlOdW1QdXQoJ3B0cicsIHAgOj0gRGxsQ2FsbCgnb2xlMzJcQ29UYXNrTWVtQWxsb2MnLCAndXB0cicsIGNzcnMuTGVuZ3RoICogQV9QdHJTaXplLCAncHRyJyksIHBzY2hlbWVSZWdpc3RyYXRpb25zKQ0KCQkJCQlmb3IgY3NyIGluIGNzcnMNCgkJCQkJCU9ialB0ckFkZFJlZihjc3IpLCBwIDo9IE51bVB1dCgncHRyJywgY3NyLlB0ciwgcCkNCgkJCQl9IGVsc2UgTnVtUHV0KCd1aW50JywgMCwgcGNvdW50KSwgTnVtUHV0KCdwdHInLCAwLCBwc2NoZW1lUmVnaXN0cmF0aW9ucykNCgkJCQlyZXR1cm4gMA0KCQkJfQ0KCQkJU2V0Q3VzdG9tU2NoZW1lUmVnaXN0cmF0aW9ucyh0aGlzLCBjb3VudCwgc2NoZW1lUmVnaXN0cmF0aW9ucykgPT4gMA0KCQkJX19EZWxldGUoKikgew0KCQkJCWZvciBwdHIgaW4gZm5wdHJzDQoJCQkJCUNhbGxiYWNrRnJlZShwdHIpDQoJCQl9DQoJCX0NCgl9DQoJY2xhc3MgRXhlY3V0ZVNjcmlwdFJlc3VsdCBleHRlbmRzIFdlYlZpZXcyLkJhc2Ugew0KCQlzdGF0aWMgSUlEIDo9ICd7MENFMTU5NjMtMzY5OC00REY3LTkzOTktNzFFRDZDREQ4QzlGfScNCgkJU3VjY2VlZGVkID0+IChDb21DYWxsKDMsIHRoaXMsICdpbnQqJywgJnZhbHVlIDo9IDApLCB2YWx1ZSkNCgkJUmVzdWx0QXNKc29uID0+IChDb21DYWxsKDQsIHRoaXMsICdwdHIqJywgJmpzb25SZXN1bHQgOj0gMCksIENvVGFza01lbV9TdHJpbmcoanNvblJlc3VsdCkpDQoJCVRyeUdldFJlc3VsdEFzU3RyaW5nKCZyZXN1bHRJc1N0cmluZz8pID0+IChDb21DYWxsKDUsIHRoaXMsICdwdHIqJywgJnJlc3VsdCA6PSAwLCAnaW50KicsICZyZXN1bHRJc1N0cmluZyA6PSAwKSwgQ29UYXNrTWVtX1N0cmluZyhyZXN1bHQpKQ0KCQlFeGNlcHRpb24gPT4gKENvbUNhbGwoNiwgdGhpcywgJ3B0cionLCBleGNlcHRpb24gOj0gV2ViVmlldzIuU2NyaXB0RXhjZXB0aW9uKCkpLCBleGNlcHRpb24pDQoJfQ0KCWNsYXNzIEZpbGUgZXh0ZW5kcyBXZWJWaWV3Mi5CYXNlIHsNCgkJc3RhdGljIElJRCA6PSAne2YyYzE5NTU5LTZiYzEtNDU4My1hNzU3LTkwMDIxYmU5YWZlY30nDQoJCVBhdGggPT4gKENvbUNhbGwoMywgdGhpcywgJ3B0cionLCAmcGF0aCA6PSAwKSwgQ29UYXNrTWVtX1N0cmluZyhwYXRoKSkNCgl9DQoJY2xhc3MgRmlsZVN5c3RlbUhhbmRsZSBleHRlbmRzIFdlYlZpZXcyLkJhc2Ugew0KCQlzdGF0aWMgSUlEIDo9ICd7YzY1MTAwYWMtMGRlMi01NTUxLWEzNjItMjNkOWJkMWQwZTFmfScNCgkJLyoqIEB0eXBlIHtXZWJWaWV3Mi5GSUxFX1NZU1RFTV9IQU5ETEVfS0lORH0gKi8NCgkJS2luZCA9PiAoQ29tQ2FsbCgzLCB0aGlzLCAnaW50KicsICZ2YWx1ZSA6PSAwKSwgdmFsdWUpDQoJCVBhdGggPT4gKENvbUNhbGwoNCwgdGhpcywgJ3B0cionLCAmdmFsdWUgOj0gMCksIENvVGFza01lbV9TdHJpbmcodmFsdWUpKQ0KCQkvKiogQHR5cGUge1dlYlZpZXcyLkZJTEVfU1lTVEVNX0hBTkRMRV9QRVJNSVNTSU9OfSAqLw0KCQlQZXJtaXNzaW9uID0+IChDb21DYWxsKDUsIHRoaXMsICdpbnQqJywgJnZhbHVlIDo9IDApLCB2YWx1ZSkNCgl9DQoJY2xhc3MgRnJhbWUgZXh0ZW5kcyBXZWJWaWV3Mi5CYXNlIHsNCgkJc3RhdGljIElJRCA6PSAne2YxMTMxYTVlLTliYTktMTFlYi1hOGIzLTAyNDJhYzEzMDAwM30nDQoJCU5hbWUgPT4gKENvbUNhbGwoMywgdGhpcywgJ3B0cionLCAmbmFtZSA6PSAwKSwgQ29UYXNrTWVtX1N0cmluZyhuYW1lKSkNCgkJLyoqIEBwYXJhbSB7KHNlbmRlcjogV2ViVmlldzIuRnJhbWUsIGFyZ3M6IElVbmtub3duKSA9PiB2b2lkfSBldmVudEhhbmRsZXIgKi8NCgkJYWRkX05hbWVDaGFuZ2VkKGV2ZW50SGFuZGxlcikgPT4gKENvbUNhbGwoNCwgdGhpcywgJ3B0cicsIGV2ZW50SGFuZGxlciwgJ2ludDY0KicsICZ0b2tlbiA6PSAwKSwgdG9rZW4pCTsgSUNvcmVXZWJWaWV3MkZyYW1lTmFtZUNoYW5nZWRFdmVudEhhbmRsZXINCgkJcmVtb3ZlX05hbWVDaGFuZ2VkKHRva2VuKSA9PiBDb21DYWxsKDUsIHRoaXMsICdpbnQ2NCcsIHRva2VuKQ0KCQlBZGRIb3N0T2JqZWN0VG9TY3JpcHRXaXRoT3JpZ2lucyhuYW1lLCBvYmplY3QsIG9yaWdpbnNBcnIqKSB7DQoJCQlpZiBvcmlnaW5zQ291bnQgOj0gb3JpZ2luc0Fyci5MZW5ndGggew0KCQkJCXAgOj0gKG9yaWdpbnMgOj0gQnVmZmVyKG9yaWdpbnNDb3VudCAqIEFfUHRyU2l6ZSkpLlB0cg0KCQkJCWxvb3Agb3JpZ2luc0NvdW50DQoJCQkJCXAgOj0gTnVtUHV0KCdwdHInLCBTdHJQdHIob3JpZ2luc0FycltBX0luZGV4XSksIHApDQoJCQl9DQoJCQlDb21DYWxsKDYsIHRoaXMsICd3c3RyJywgbmFtZSwgJ3B0cicsIENvbVZhcihvYmplY3QpLCAndWludCcsIG9yaWdpbnNDb3VudCwgJ3B0cicsIG9yaWdpbnMpCTsgTFBDV1NUUioNCgkJfQ0KCQlSZW1vdmVIb3N0T2JqZWN0RnJvbVNjcmlwdChuYW1lKSA9PiBDb21DYWxsKDcsIHRoaXMsICd3c3RyJywgbmFtZSkNCgkJLyoqIEBwYXJhbSB7KHNlbmRlcjogV2ViVmlldzIuRnJhbWUsIGFyZ3M6IElVbmtub3duKSA9PiB2b2lkfSBldmVudEhhbmRsZXIgKi8NCgkJYWRkX0Rlc3Ryb3llZChldmVudEhhbmRsZXIpID0+IChDb21DYWxsKDgsIHRoaXMsICdwdHInLCBldmVudEhhbmRsZXIsICdpbnQ2NConLCAmdG9rZW4gOj0gMCksIHRva2VuKQk7IElDb3JlV2ViVmlldzJGcmFtZURlc3Ryb3llZEV2ZW50SGFuZGxlcg0KCQlyZW1vdmVfRGVzdHJveWVkKHRva2VuKSA9PiBDb21DYWxsKDksIHRoaXMsICdpbnQ2NCcsIHRva2VuKQ0KCQlJc0Rlc3Ryb3llZCgpID0+IChDb21DYWxsKDEwLCB0aGlzLCAnaW50KicsICZkZXN0cm95ZWQgOj0gMCksIGRlc3Ryb3llZCkNCg0KCQlzdGF0aWMgSUlEXzIgOj0gJ3s3YTZhNTgzNC1kMTg1LTRkYmYtYjYzZi00YTliYzQzMTA3ZDR9Jw0KCQkvKiogQHBhcmFtIHsoc2VuZGVyOiBXZWJWaWV3Mi5GcmFtZSwgYXJnczogV2ViVmlldzIuTmF2aWdhdGlvblN0YXJ0aW5nRXZlbnRBcmdzKSA9PiB2b2lkfSBldmVudEhhbmRsZXIgKi8NCgkJYWRkX05hdmlnYXRpb25TdGFydGluZyhldmVudEhhbmRsZXIpID0+IChDb21DYWxsKDExLCB0aGlzLCAncHRyJywgZXZlbnRIYW5kbGVyLCAnaW50NjQqJywgJnRva2VuIDo9IDApLCB0b2tlbikJOyBJQ29yZVdlYlZpZXcyRnJhbWVOYXZpZ2F0aW9uU3RhcnRpbmdFdmVudEhhbmRsZXINCgkJcmVtb3ZlX05hdmlnYXRpb25TdGFydGluZyh0b2tlbikgPT4gQ29tQ2FsbCgxMiwgdGhpcywgJ2ludDY0JywgdG9rZW4pDQoJCS8qKiBAcGFyYW0geyhzZW5kZXI6IFdlYlZpZXcyLkZyYW1lLCBhcmdzOiBXZWJWaWV3Mi5Db250ZW50TG9hZGluZ0V2ZW50QXJncykgPT4gdm9pZH0gZXZlbnRIYW5kbGVyICovDQoJCWFkZF9Db250ZW50TG9hZGluZyhldmVudEhhbmRsZXIpID0+IChDb21DYWxsKDEzLCB0aGlzLCAncHRyJywgZXZlbnRIYW5kbGVyLCAnaW50NjQqJywgJnRva2VuIDo9IDApLCB0b2tlbikJOyBJQ29yZVdlYlZpZXcyRnJhbWVDb250ZW50TG9hZGluZ0V2ZW50SGFuZGxlcg0KCQlyZW1vdmVfQ29udGVudExvYWRpbmcodG9rZW4pID0+IENvbUNhbGwoMTQsIHRoaXMsICdpbnQ2NCcsIHRva2VuKQ0KCQkvKiogQHBhcmFtIHsoc2VuZGVyOiBXZWJWaWV3Mi5GcmFtZSwgYXJnczogV2ViVmlldzIuTmF2aWdhdGlvbkNvbXBsZXRlZEV2ZW50QXJncykgPT4gdm9pZH0gZXZlbnRIYW5kbGVyICovDQoJCWFkZF9OYXZpZ2F0aW9uQ29tcGxldGVkKGV2ZW50SGFuZGxlcikgPT4gKENvbUNhbGwoMTUsIHRoaXMsICdwdHInLCBldmVudEhhbmRsZXIsICdpbnQ2NConLCAmdG9rZW4gOj0gMCksIHRva2VuKQk7IElDb3JlV2ViVmlldzJGcmFtZU5hdmlnYXRpb25Db21wbGV0ZWRFdmVudEhhbmRsZXINCgkJcmVtb3ZlX05hdmlnYXRpb25Db21wbGV0ZWQodG9rZW4pID0+IENvbUNhbGwoMTYsIHRoaXMsICdpbnQ2NCcsIHRva2VuKQ0KCQkvKiogQHBhcmFtIHsoc2VuZGVyOiBXZWJWaWV3Mi5GcmFtZSwgYXJnczogV2ViVmlldzIuRE9NQ29udGVudExvYWRlZEV2ZW50QXJncykgPT4gdm9pZH0gZXZlbnRIYW5kbGVyICovDQoJCWFkZF9ET01Db250ZW50TG9hZGVkKGV2ZW50SGFuZGxlcikgPT4gKENvbUNhbGwoMTcsIHRoaXMsICdwdHInLCBldmVudEhhbmRsZXIsICdpbnQ2NConLCAmdG9rZW4gOj0gMCksIHRva2VuKQk7IElDb3JlV2ViVmlldzJGcmFtZURPTUNvbnRlbnRMb2FkZWRFdmVudEhhbmRsZXINCgkJcmVtb3ZlX0RPTUNvbnRlbnRMb2FkZWQodG9rZW4pID0+IENvbUNhbGwoMTgsIHRoaXMsICdpbnQ2NCcsIHRva2VuKQ0KCQkvKiogQHJldHVybnMge1Byb21pc2U8U3RyaW5nPn0gKi8NCgkJRXhlY3V0ZVNjcmlwdEFzeW5jKGphdmFTY3JpcHQpID0+IChDb21DYWxsKDE5LCB0aGlzLCAnd3N0cicsIGphdmFTY3JpcHQsICdwdHInLCBXZWJWaWV3Mi5Bc3luY0hhbmRsZXIoJnAsIFN0ckdldCkpLCBwKQ0KCQlQb3N0V2ViTWVzc2FnZUFzSnNvbih3ZWJNZXNzYWdlQXNKc29uKSA9PiBDb21DYWxsKDIwLCB0aGlzLCAnd3N0cicsIHdlYk1lc3NhZ2VBc0pzb24pDQoJCVBvc3RXZWJNZXNzYWdlQXNTdHJpbmcod2ViTWVzc2FnZUFzU3RyaW5nKSA9PiBDb21DYWxsKDIxLCB0aGlzLCAnd3N0cicsIHdlYk1lc3NhZ2VBc1N0cmluZykNCgkJLyoqIEBwYXJhbSB7KHNlbmRlcjogV2ViVmlldzIuRnJhbWUsIGFyZ3M6IFdlYlZpZXcyLldlYk1lc3NhZ2VSZWNlaXZlZEV2ZW50QXJncykgPT4gdm9pZH0gZXZlbnRIYW5kbGVyICovDQoJCWFkZF9XZWJNZXNzYWdlUmVjZWl2ZWQoZXZlbnRIYW5kbGVyKSA9PiAoQ29tQ2FsbCgyMiwgdGhpcywgJ3B0cicsIGV2ZW50SGFuZGxlciwgJ2ludDY0KicsICZ0b2tlbiA6PSAwKSwgdG9rZW4pCTsgSUNvcmVXZWJWaWV3MkZyYW1lV2ViTWVzc2FnZVJlY2VpdmVkRXZlbnRIYW5kbGVyDQoJCXJlbW92ZV9XZWJNZXNzYWdlUmVjZWl2ZWQodG9rZW4pID0+IENvbUNhbGwoMjMsIHRoaXMsICdpbnQ2NCcsIHRva2VuKQ0KDQoJCXN0YXRpYyBJSURfMyA6PSAne2I1MGQ4MmNjLWNjMjgtNDgxZC05NjE0LWNiMDQ4ODk1ZTZhMH0nDQoJCS8qKiBAcGFyYW0geyhzZW5kZXI6IFdlYlZpZXcyLkZyYW1lLCBhcmdzOiBXZWJWaWV3Mi5QZXJtaXNzaW9uUmVxdWVzdGVkRXZlbnRBcmdzKSA9PiB2b2lkfSBldmVudEhhbmRsZXIgKi8NCgkJYWRkX1Blcm1pc3Npb25SZXF1ZXN0ZWQoZXZlbnRIYW5kbGVyKSA9PiAoQ29tQ2FsbCgyNCwgdGhpcywgJ3B0cicsIGV2ZW50SGFuZGxlciwgJ2ludDY0KicsICZ0b2tlbiA6PSAwKSwgdG9rZW4pCTsgSUNvcmVXZWJWaWV3MkZyYW1lUGVybWlzc2lvblJlcXVlc3RlZEV2ZW50SGFuZGxlcg0KCQlyZW1vdmVfUGVybWlzc2lvblJlcXVlc3RlZCh0b2tlbikgPT4gQ29tQ2FsbCgyNSwgdGhpcywgJ2ludDY0JywgdG9rZW4pDQoNCgkJc3RhdGljIElJRF80IDo9ICd7MTg4NzgyREMtOTJBQS00NzMyLUFCM0MtRkNDNTlGNkY2OEI5fScNCgkJUG9zdFNoYXJlZEJ1ZmZlclRvU2NyaXB0KHNoYXJlZEJ1ZmZlciwgYWNjZXNzLCBhZGRpdGlvbmFsRGF0YUFzSnNvbikgPT4gQ29tQ2FsbCgyNiwgdGhpcywgJ3B0cicsIHNoYXJlZEJ1ZmZlciwgJ2ludCcsIGFjY2VzcywgJ3dzdHInLCBhZGRpdGlvbmFsRGF0YUFzSnNvbikNCg0KCQlzdGF0aWMgSUlEXzUgOj0gJ3s5OWQxOTljNC03MzA1LTExZWUtYjk2Mi0wMjQyYWMxMjAwMDJ9Jw0KCQlGcmFtZUlkID0+IChDb21DYWxsKDI3LCB0aGlzLCAndWludConLCAmaWQgOj0gMCksIGlkKQ0KDQoJCXN0YXRpYyBJSURfNiA6PSAnezBkZTYxMWZkLTMxZTktNWRkYy05ZDcxLTk1ZWRhMjZlZmYzMn0nDQoJCS8qKiBAcGFyYW0geyhzZW5kZXI6IFdlYlZpZXcyLkZyYW1lLCBhcmdzOiBXZWJWaWV3Mi5TY3JlZW5DYXB0dXJlU3RhcnRpbmdFdmVudEFyZ3MpID0+IHZvaWR9IGV2ZW50SGFuZGxlciAqLw0KCQlhZGRfU2NyZWVuQ2FwdHVyZVN0YXJ0aW5nKGV2ZW50SGFuZGxlcikgPT4gKENvbUNhbGwoMjgsIHRoaXMsICdwdHInLCBldmVudEhhbmRsZXIsICdpbnQ2NConLCAmdG9rZW4gOj0gMCksIHRva2VuKQ0KCQlyZW1vdmVfU2NyZWVuQ2FwdHVyZVN0YXJ0aW5nKHRva2VuKSA9PiBDb21DYWxsKDI5LCB0aGlzLCAnaW50NjQnLCB0b2tlbikNCgl9DQoJY2xhc3MgRnJhbWVDcmVhdGVkRXZlbnRBcmdzIGV4dGVuZHMgV2ViVmlldzIuQmFzZSB7DQoJCXN0YXRpYyBJSUQgOj0gJ3s0ZDZlN2I1ZS05YmFhLTExZWItYThiMy0wMjQyYWMxMzAwMDN9Jw0KCQlGcmFtZSA9PiAoQ29tQ2FsbCgzLCB0aGlzLCAncHRyKicsIGZyYW1lIDo9IFdlYlZpZXcyLkZyYW1lKCkpLCBmcmFtZSkNCgl9DQoJY2xhc3MgRnJhbWVJbmZvIGV4dGVuZHMgV2ViVmlldzIuQmFzZSB7DQoJCXN0YXRpYyBJSUQgOj0gJ3tkYTg2YjhhMS1iZGYzLTRmMTEtOTk1NS01MjhjZWZhNTk3Mjd9Jw0KCQlOYW1lID0+IChDb21DYWxsKDMsIHRoaXMsICdwdHIqJywgJm5hbWUgOj0gMCksIENvVGFza01lbV9TdHJpbmcobmFtZSkpDQoJCVNvdXJjZSA9PiAoQ29tQ2FsbCg0LCB0aGlzLCAncHRyKicsICZzb3VyY2UgOj0gMCksIENvVGFza01lbV9TdHJpbmcoc291cmNlKSkNCg0KCQlzdGF0aWMgSUlEXzIgOj0gdGhpcy5EZWZhdWx0SUlEIDo9ICd7NTZmODVjZmEtNzJjNC0xMWVlLWI5NjItMDI0MmFjMTIwMDAyfScNCgkJUGFyZW50RnJhbWVJbmZvID0+IChDb21DYWxsKDUsIHRoaXMsICdwdHIqJywgZnJhbWVJbmZvIDo9IFdlYlZpZXcyLkZyYW1lSW5mbygpKSwgZnJhbWVJbmZvKQ0KCQlGcmFtZUlkID0+IChDb21DYWxsKDYsIHRoaXMsICd1aW50KicsICZpZCA6PSAwKSwgaWQpDQoJCUZyYW1lS2luZCA9PiAoQ29tQ2FsbCg3LCB0aGlzLCAndWludConLCAma2luZCA6PSAwKSwga2luZCkNCgl9DQoJY2xhc3MgRnJhbWVJbmZvQ29sbGVjdGlvbiBleHRlbmRzIFdlYlZpZXcyLkJhc2Ugew0KCQlzdGF0aWMgSUlEIDo9ICd7OGY4MzQxNTQtZDM4ZS00ZDkwLWFmZmItNjgwMGE3MjcyODM5fScNCgkJR2V0SXRlcmF0b3IoKSA9PiAoQ29tQ2FsbCgzLCB0aGlzLCAncHRyKicsIGl0ZXJhdG9yIDo9IFdlYlZpZXcyLkZyYW1lSW5mb0NvbGxlY3Rpb25JdGVyYXRvcigpKSwgaXRlcmF0b3IpDQoJfQ0KCWNsYXNzIEZyYW1lSW5mb0NvbGxlY3Rpb25JdGVyYXRvciBleHRlbmRzIFdlYlZpZXcyLkJhc2Ugew0KCQlzdGF0aWMgSUlEIDo9ICd7MWJmODllMmQtMWIyYi00NjI5LWIyOGYtMDUwOTliNDFiYjAzfScNCgkJSGFzQ3VycmVudCA9PiAoQ29tQ2FsbCgzLCB0aGlzLCAnaW50KicsICZoYXNDdXJyZW50IDo9IDApLCBoYXNDdXJyZW50KQ0KCQlHZXRDdXJyZW50KCkgPT4gKENvbUNhbGwoNCwgdGhpcywgJ3B0cionLCBmcmFtZUluZm8gOj0gV2ViVmlldzIuRnJhbWVJbmZvKCkpLCBmcmFtZUluZm8pDQoJCU1vdmVOZXh0KCkgPT4gKENvbUNhbGwoNSwgdGhpcywgJ2ludConLCAmaGFzTmV4dCA6PSAwKSwgaGFzTmV4dCkNCgkJX19FbnVtKG4pID0+ICgmZmksICopID0+IHRoaXMuSGFzQ3VycmVudCAmJiAoZmkgOj0gdGhpcy5HZXRDdXJyZW50KCksIHRoaXMuTW92ZU5leHQoKSwgdHJ1ZSkNCgl9DQoJY2xhc3MgSGFuZGxlciBleHRlbmRzIEJ1ZmZlciB7DQoJCS8qKg0KCQkgKiBDb25zdHJ1Y3QgSUNvcmVXZWJWaWV3MiBFdmVudCBvciBDb21wbGV0ZWQgSGFuZGxlci4NCgkJICogQHBhcmFtIGludm9rZSBJbnZva2UgZnVuY3Rpb24gb2YgaGFuZGxlci4NCgkJICogVGhlIGZpcnN0IHBhcmFtZXRlciBvZiB0aGUgY2FsbGJhY2sgZnVuY3Rpb24gaXMgdGhlIGV2ZW50IGludGVyZmFjZSBwb2ludGVyLg0KCQkgKiBAc2VlIGh0dHBzOi8vbGVhcm4ubWljcm9zb2Z0LmNvbS9lbi11cy9taWNyb3NvZnQtZWRnZS93ZWJ2aWV3Mi9yZWZlcmVuY2Uvd2luMzIvI2RlbGVnYXRlcw0KCQkgKi8NCgkJc3RhdGljIENhbGwoaW52b2tlLCBudW1QYXJhbXMgOj0gMykgew0KCQkJc3RhdGljIHBmbnMgOj0gW0NhbGxiYWNrQ3JlYXRlKFF1ZXJ5SW50ZXJmYWNlKSwgQ2FsbGJhY2tDcmVhdGUoQWRkUmVmKSwgQ2FsbGJhY2tDcmVhdGUoUmVsZWFzZSldDQoJCQkJLkRlZmluZVByb3AoJ19fRGVsZXRlJywgeyBjYWxsOiBfX0RlbGV0ZSB9KQ0KCQkJaWYgSGFzTWV0aG9kKGludm9rZSkgew0KCQkJCWhhbmRsZXIgOj0gc3VwZXIoNiAqIEFfUHRyU2l6ZSkNCgkJCQlOdW1QdXQoJ3B0cicsIGhhbmRsZXIuUHRyICsgMiAqIEFfUHRyU2l6ZSwgJ3B0cicsIE9ialB0cihoYW5kbGVyKSwNCgkJCQkJJ3B0cicsIHBmbnNbMV0sICdwdHInLCBwZm5zWzJdLCAncHRyJywgcGZuc1szXSwNCgkJCQkJJ3B0cicsIENhbGxiYWNrQ3JlYXRlKGludm9rZSwgLCBudW1QYXJhbXMpLCBoYW5kbGVyKQ0KCQkJCWhhbmRsZXIuX19EZWxldGUgOj0gKHRoaXMpID0+IENhbGxiYWNrRnJlZShOdW1HZXQodGhpcywgNSAqIEFfUHRyU2l6ZSwgJ3B0cicpKQ0KCQkJCXJldHVybiBoYW5kbGVyDQoJCQl9DQoJCQlyZXR1cm4gaW52b2tlDQoJCQlRdWVyeUludGVyZmFjZShpbnRlcmZhY2UsIHJpaWQsIHBwdk9iamVjdCkgPT4gMHg4MDAwNDAwMg0KCQkJQWRkUmVmKHRoaXMpID0+IE9iakFkZFJlZihOdW1HZXQodGhpcywgQV9QdHJTaXplLCAncHRyJykpDQoJCQlSZWxlYXNlKHRoaXMpID0+IE9ialJlbGVhc2UoTnVtR2V0KHRoaXMsIEFfUHRyU2l6ZSwgJ3B0cicpKQ0KCQkJX19EZWxldGUodGhpcykgew0KCQkJCWZvciBwIGluIHRoaXMNCgkJCQkJQ2FsbGJhY2tGcmVlKHApDQoJCQl9DQoJCX0NCgl9DQoJY2xhc3MgSHR0cEhlYWRlcnNDb2xsZWN0aW9uSXRlcmF0b3IgZXh0ZW5kcyBXZWJWaWV3Mi5CYXNlIHsNCgkJc3RhdGljIElJRCA6PSAnezA3MDJmYzMwLWY0M2ItNDdiYi1hYjUyLWE0MmNiNTUyYWQ5Zn0nDQoJCUdldEN1cnJlbnRIZWFkZXIoJm5hbWUsICZ2YWx1ZSkgew0KCQkJQ29tQ2FsbCgzLCB0aGlzLCAncHRyKicsICZuYW1lIDo9IDAsICdwdHIqJywgJnZhbHVlIDo9IDApDQoJCQluYW1lIDo9IENvVGFza01lbV9TdHJpbmcobmFtZSksIHZhbHVlIDo9IENvVGFza01lbV9TdHJpbmcodmFsdWUpDQoJCX0NCgkJSGFzQ3VycmVudEhlYWRlciA9PiAoQ29tQ2FsbCg0LCB0aGlzLCAnaW50KicsICZoYXNDdXJyZW50IDo9IDApLCBoYXNDdXJyZW50KQ0KCQlNb3ZlTmV4dCgpID0+IChDb21DYWxsKDUsIHRoaXMsICdpbnQqJywgJmhhc05leHQgOj0gMCksIGhhc05leHQpDQoJCV9fRW51bShuKSA9PiAoJm5hbWUsICZ2YWx1ZSwgKikgPT4gdGhpcy5IYXNDdXJyZW50SGVhZGVyICYmICh0aGlzLkdldEN1cnJlbnRIZWFkZXIoJm5hbWUsICZ2YWx1ZSksIHRoaXMuTW92ZU5leHQoKSwgdHJ1ZSkNCgl9DQoJY2xhc3MgSHR0cFJlcXVlc3RIZWFkZXJzIGV4dGVuZHMgV2ViVmlldzIuQmFzZSB7DQoJCXN0YXRpYyBJSUQgOj0gJ3tlODZjYWMwZS01NTIzLTQ2NWMtYjUzNi04ZmI5ZmM4YzhjNjB9Jw0KCQlHZXRIZWFkZXIobmFtZSkgPT4gKENvbUNhbGwoMywgdGhpcywgJ3dzdHInLCBuYW1lLCAncHRyKicsICZ2YWx1ZSA6PSAwKSwgQ29UYXNrTWVtX1N0cmluZyh2YWx1ZSkpDQoJCUdldEhlYWRlcnMobmFtZSkgPT4gKENvbUNhbGwoNCwgdGhpcywgJ3dzdHInLCBuYW1lLCAncHRyKicsIGl0ZXJhdG9yIDo9IFdlYlZpZXcyLkh0dHBIZWFkZXJzQ29sbGVjdGlvbkl0ZXJhdG9yKCkpLCBpdGVyYXRvcikNCgkJUmV0VmFsKG5hbWUpID0+IChDb21DYWxsKDUsIHRoaXMsICd3c3RyJywgbmFtZSwgJ2ludConLCAmUmV0VmFsIDo9IDApLCBSZXRWYWwpDQoJCVNldEhlYWRlcihuYW1lLCB2YWx1ZSkgPT4gQ29tQ2FsbCg2LCB0aGlzLCAnd3N0cicsIG5hbWUsICd3c3RyJywgdmFsdWUpDQoJCVJlbW92ZUhlYWRlcihuYW1lKSA9PiBDb21DYWxsKDcsIHRoaXMsICd3c3RyJywgbmFtZSkNCgkJR2V0SXRlcmF0b3IoKSA9PiAoQ29tQ2FsbCg4LCB0aGlzLCAncHRyKicsIGl0ZXJhdG9yIDo9IFdlYlZpZXcyLkh0dHBIZWFkZXJzQ29sbGVjdGlvbkl0ZXJhdG9yKCkpLCBpdGVyYXRvcikNCgl9DQoJY2xhc3MgSHR0cFJlc3BvbnNlSGVhZGVycyBleHRlbmRzIFdlYlZpZXcyLkJhc2Ugew0KCQlzdGF0aWMgSUlEIDo9ICd7MDNjNWZmNWEtOWI0NS00YTg4LTg4MWMtODlhOWYzMjg2MTljfScNCgkJQXBwZW5kSGVhZGVyKG5hbWUsIHZhbHVlKSA9PiBDb21DYWxsKDMsIHRoaXMsICd3c3RyJywgbmFtZSwgJ3dzdHInLCB2YWx1ZSkNCgkJUmV0VmFsKG5hbWUpID0+IChDb21DYWxsKDQsIHRoaXMsICd3c3RyJywgbmFtZSwgJ2ludConLCAmUmV0VmFsIDo9IDApLCBSZXRWYWwpDQoJCUdldEhlYWRlcihuYW1lKSA9PiAoQ29tQ2FsbCg1LCB0aGlzLCAnd3N0cicsIG5hbWUsICdwdHIqJywgJnZhbHVlIDo9IDApLCBDb1Rhc2tNZW1fU3RyaW5nKHZhbHVlKSkNCgkJR2V0SGVhZGVycyhuYW1lKSA9PiAoQ29tQ2FsbCg2LCB0aGlzLCAnd3N0cicsIG5hbWUsICdwdHIqJywgaXRlcmF0b3IgOj0gV2ViVmlldzIuSHR0cEhlYWRlcnNDb2xsZWN0aW9uSXRlcmF0b3IoKSksIGl0ZXJhdG9yKQ0KCQlHZXRJdGVyYXRvcigpID0+IChDb21DYWxsKDcsIHRoaXMsICdwdHIqJywgaXRlcmF0b3IgOj0gV2ViVmlldzIuSHR0cEhlYWRlcnNDb2xsZWN0aW9uSXRlcmF0b3IoKSksIGl0ZXJhdG9yKQ0KCX0NCgljbGFzcyBMYXVuY2hpbmdFeHRlcm5hbFVyaVNjaGVtZUV2ZW50QXJncyBleHRlbmRzIFdlYlZpZXcyLkJhc2Ugew0KCQlzdGF0aWMgSUlEIDo9ICd7MDdEMUE2QzMtNzE3NS00QkExLTkzMDYtRTU5M0NBMDdFNDZDfScNCgkJVXJpID0+IChDb21DYWxsKDMsIHRoaXMsICdwdHIqJywgdmFsdWUgOj0gMCksIENvVGFza01lbV9TdHJpbmcodmFsdWUpKQ0KCQlJbml0aWF0aW5nT3JpZ2luID0+IChDb21DYWxsKDQsIHRoaXMsICdwdHIqJywgdmFsdWUgOj0gMCksIENvVGFza01lbV9TdHJpbmcodmFsdWUpKQ0KCQlJc1VzZXJJbml0aWF0ZWQgPT4gKENvbUNhbGwoNSwgdGhpcywgJ2ludConLCAmdmFsdWUgOj0gMCksIHZhbHVlKQ0KCQlDYW5jZWwgew0KCQkJZ2V0ID0+IChDb21DYWxsKDYsIHRoaXMsICdpbnQqJywgJnZhbHVlIDo9IDApLCB2YWx1ZSkNCgkJCXNldCA9PiBDb21DYWxsKDcsIHRoaXMsICdpbnQnLCBWYWx1ZSkNCgkJfQ0KCQlHZXREZWZlcnJhbCgpID0+IChDb21DYWxsKDgsIHRoaXMsICdwdHIqJywgdmFsdWUgOj0gV2ViVmlldzIuRGVmZXJyYWwoKSksIHZhbHVlKQ0KCX0NCgljbGFzcyBNb3ZlRm9jdXNSZXF1ZXN0ZWRFdmVudEFyZ3MgZXh0ZW5kcyBXZWJWaWV3Mi5CYXNlIHsNCgkJc3RhdGljIElJRCA6PSAnezJkNmFhMTNiLTM4MzktNGExNS05MmZjLWQ4OGIzYzBkOWM5ZH0nDQoJCVJlYXNvbiA9PiAoQ29tQ2FsbCgzLCB0aGlzLCAnaW50KicsICZyZWFzb24gOj0gMCksIHJlYXNvbikJOyBDT1JFV0VCVklFVzJfTU9WRV9GT0NVU19SRUFTT04NCgkJSGFuZGxlZCB7DQoJCQlnZXQgPT4gKENvbUNhbGwoNCwgdGhpcywgJ2ludConLCAmdmFsdWUgOj0gMCksIHZhbHVlKQ0KCQkJc2V0ID0+IENvbUNhbGwoNSwgdGhpcywgJ2ludCcsIFZhbHVlKQ0KCQl9DQoJfQ0KCWNsYXNzIE5hdmlnYXRpb25Db21wbGV0ZWRFdmVudEFyZ3MgZXh0ZW5kcyBXZWJWaWV3Mi5CYXNlIHsNCgkJc3RhdGljIElJRCA6PSAnezMwZDY4YjdkLTIwZDktNDc1Mi1hOWNhLWVjODQ0OGZiYjVjMX0nDQoJCUlzU3VjY2VzcyA9PiAoQ29tQ2FsbCgzLCB0aGlzLCAnaW50KicsICZpc1N1Y2Nlc3MgOj0gMCksIGlzU3VjY2VzcykNCgkJV2ViRXJyb3JTdGF0dXMgPT4gKENvbUNhbGwoNCwgdGhpcywgJ2ludConLCAmd2ViRXJyb3JTdGF0dXMgOj0gMCksIHdlYkVycm9yU3RhdHVzKQk7IENPUkVXRUJWSUVXMl9XRUJfRVJST1JfU1RBVFVTDQoJCU5hdmlnYXRpb25JZCA9PiAoQ29tQ2FsbCg1LCB0aGlzLCAnaW50NjQqJywgJm5hdmlnYXRpb25JZCA6PSAwKSwgbmF2aWdhdGlvbklkKQ0KDQoJCXN0YXRpYyBJSURfMiA6PSAne0ZERjhCNzM4LUVFMUUtNERCMi1BMzI5LThEN0Q3Qjc0RDc5Mn0nDQoJCUh0dHBTdGF0dXNDb2RlID0+IChDb21DYWxsKDYsIHRoaXMsICdpbnQqJywgJmh0dHBfc3RhdHVzX2NvZGUgOj0gMCksIGh0dHBfc3RhdHVzX2NvZGUpDQoJfQ0KCWNsYXNzIE5hdmlnYXRpb25TdGFydGluZ0V2ZW50QXJncyBleHRlbmRzIFdlYlZpZXcyLkJhc2Ugew0KCQlzdGF0aWMgSUlEIDo9ICd7NWI0OTU0NjktZTExOS00MzhhLTliMTgtNzYwNGYyNWYyZTQ5fScNCgkJVXJpID0+IChDb21DYWxsKDMsIHRoaXMsICdwdHIqJywgJnVyaSA6PSAwKSwgQ29UYXNrTWVtX1N0cmluZyh1cmkpKQ0KCQlJc1VzZXJJbml0aWF0ZWQgPT4gKENvbUNhbGwoNCwgdGhpcywgJ2ludConLCAmaXNVc2VySW5pdGlhdGVkIDo9IDApLCBpc1VzZXJJbml0aWF0ZWQpDQoJCUlzUmVkaXJlY3RlZCA9PiAoQ29tQ2FsbCg1LCB0aGlzLCAnaW50KicsICZpc1JlZGlyZWN0ZWQgOj0gMCksIGlzUmVkaXJlY3RlZCkNCgkJUmVxdWVzdEhlYWRlcnMgPT4gKENvbUNhbGwoNiwgdGhpcywgJ3B0cionLCByZXF1ZXN0SGVhZGVycyA6PSBXZWJWaWV3Mi5IdHRwUmVxdWVzdEhlYWRlcnMoKSksIHJlcXVlc3RIZWFkZXJzKQ0KCQlDYW5jZWwgew0KCQkJZ2V0ID0+IChDb21DYWxsKDcsIHRoaXMsICdpbnQqJywgJmNhbmNlbCA6PSAwKSwgY2FuY2VsKQ0KCQkJc2V0ID0+IENvbUNhbGwoOCwgdGhpcywgJ2ludCcsIFZhbHVlKQ0KCQl9DQoJCU5hdmlnYXRpb25JZCA9PiAoQ29tQ2FsbCg5LCB0aGlzLCAnaW50NjQqJywgJm5hdmlnYXRpb25JZCA6PSAwKSwgbmF2aWdhdGlvbklkKQ0KDQoJCXN0YXRpYyBJSURfMiA6PSAnezkwODZCRTkzLTkxQUEtNDcyRC1BN0UwLTU3OUYyQkEwMDZBRH0nDQoJCUFkZGl0aW9uYWxBbGxvd2VkRnJhbWVBbmNlc3RvcnMgew0KCQkJZ2V0ID0+IChDb21DYWxsKDEwLCB0aGlzLCAncHRyKicsICZ2YWx1ZSA6PSAwKSwgQ29UYXNrTWVtX1N0cmluZyh2YWx1ZSkpDQoJCQlzZXQgPT4gQ29tQ2FsbCgxMSwgdGhpcywgJ3dzdHInLCBWYWx1ZSkNCgkJfQ0KDQoJCXN0YXRpYyBJSURfMyA6PSAne0RERkZFNDk0LTQ5NDItNEJEMi1BQjczLTM1QjhGRjQwRTE5Rn0nDQoJCU5hdmlnYXRpb25LaW5kID0+IChDb21DYWxsKDEyLCB0aGlzLCAnaW50KicsICZuYXZpZ2F0aW9uX2tpbmQgOj0gMCksIG5hdmlnYXRpb25fa2luZCkNCgl9DQoJY2xhc3MgTmV3V2luZG93UmVxdWVzdGVkRXZlbnRBcmdzIGV4dGVuZHMgV2ViVmlldzIuQmFzZSB7DQoJCXN0YXRpYyBJSUQgOj0gJ3szNGFjYjExYy1mYzM3LTQ0MTgtOTEzMi1mOWMyMWQxZWFmYjl9Jw0KCQlVcmkgPT4gKENvbUNhbGwoMywgdGhpcywgJ3B0cionLCAmdXJpIDo9IDApLCBDb1Rhc2tNZW1fU3RyaW5nKHVyaSkpDQoJCU5ld1dpbmRvdyB7DQoJCQlzZXQgPT4gQ29tQ2FsbCg0LCB0aGlzLCAncHRyJywgVmFsdWUpDQoJCQlnZXQgPT4gKENvbUNhbGwoNSwgdGhpcywgJ3B0cionLCBuZXdXaW5kb3cgOj0gV2ViVmlldzIuQ29yZSgpKSwgbmV3V2luZG93KQ0KCQl9DQoJCUhhbmRsZWQgew0KCQkJc2V0ID0+IENvbUNhbGwoNiwgdGhpcywgJ2ludCcsIFZhbHVlKQ0KCQkJZ2V0ID0+IChDb21DYWxsKDcsIHRoaXMsICdpbnQqJywgJmhhbmRsZWQgOj0gMCksIGhhbmRsZWQpDQoJCX0NCgkJSXNVc2VySW5pdGlhdGVkID0+IChDb21DYWxsKDgsIHRoaXMsICdpbnQqJywgJmlzVXNlckluaXRpYXRlZCA6PSAwKSwgaXNVc2VySW5pdGlhdGVkKQ0KCQlHZXREZWZlcnJhbCgpID0+IChDb21DYWxsKDksIHRoaXMsICdwdHIqJywgZGVmZXJyYWwgOj0gV2ViVmlldzIuRGVmZXJyYWwoKSksIGRlZmVycmFsKQ0KCQlXaW5kb3dGZWF0dXJlcyA9PiAoQ29tQ2FsbCgxMCwgdGhpcywgJ3B0cionLCB2YWx1ZSA6PSBXZWJWaWV3Mi5XaW5kb3dGZWF0dXJlcygpKSwgdmFsdWUpDQoNCgkJc3RhdGljIElJRF8yIDo9ICd7YmJjN2JhZWQtNzRjNi00YzkyLWI2M2EtN2Y1YWVhZTAzZGUzfScNCgkJTmFtZSA9PiAoQ29tQ2FsbCgxMSwgdGhpcywgJ3B0cionLCAmdmFsdWUgOj0gMCksIENvVGFza01lbV9TdHJpbmcodmFsdWUpKQ0KDQoJCXN0YXRpYyBJSURfMyA6PSAnezg0MmJlZDNjLTZhZDYtNGRkOS1iOTM4LTI4Yzk2NjY3YWQ2Nn0nDQoJCU9yaWdpbmFsU291cmNlRnJhbWVJbmZvID0+IChDb21DYWxsKDEyLCB0aGlzLCAncHRyKicsIGZyYW1lSW5mbyA6PSBXZWJWaWV3Mi5GcmFtZUluZm8oKSksIGZyYW1lSW5mbykNCgl9DQoJY2xhc3MgTm9uQ2xpZW50UmVnaW9uQ2hhbmdlZEV2ZW50QXJncyBleHRlbmRzIFdlYlZpZXcyLkJhc2Ugew0KCQlzdGF0aWMgSUlEIDo9ICd7QUI3MUQ1MDAtMDgyMC00QTUyLTgwOUMtNDhEQjA0RkY5M0JGfScNCgkJUmVnaW9uS2luZCA9PiAoQ29tQ2FsbCgzLCB0aGlzLCAnaW50KicsICZ2YWx1ZSA6PSAwKSwgdmFsdWUpDQoJfQ0KCWNsYXNzIE5vdGlmaWNhdGlvbiBleHRlbmRzIFdlYlZpZXcyLkJhc2Ugew0KCQlzdGF0aWMgSUlEIDo9ICd7Qjc0MzREOTgtNkJDOC00MTlELTlEQTUtRkI1QTk2RDREQUNEfScNCgkJLyoqIEBwYXJhbSB7KHNlbmRlcjogV2ViVmlldzIuTm90aWZpY2F0aW9uLCBhcmdzOiBJVW5rbm93bikgPT4gdm9pZH0gZXZlbnRIYW5kbGVyICovDQoJCWFkZF9DbG9zZVJlcXVlc3RlZChldmVudEhhbmRsZXIpID0+IChDb21DYWxsKDMsIHRoaXMsICdwdHInLCBldmVudEhhbmRsZXIsICdpbnQ2NConLCAmdG9rZW4gOj0gMCksIHRva2VuKQ0KCQlyZW1vdmVfQ2xvc2VSZXF1ZXN0ZWQodG9rZW4pID0+IENvbUNhbGwoNCwgdGhpcywgJ2ludDY0JywgdG9rZW4pDQoJCVJlcG9ydFNob3duKCkgPT4gQ29tQ2FsbCg1LCB0aGlzKQ0KCQlSZXBvcnRDbGlja2VkKCkgPT4gQ29tQ2FsbCg2LCB0aGlzKQ0KCQlSZXBvcnRDbG9zZWQoKSA9PiBDb21DYWxsKDcsIHRoaXMpDQoJCUJvZHkgPT4gKENvbUNhbGwoOCwgdGhpcywgJ3B0cionLCAmdmFsdWUgOj0gMCksIENvVGFza01lbV9TdHJpbmcodmFsdWUpKQ0KCQlEaXJlY3Rpb24gPT4gQ29tQ2FsbCg5LCB0aGlzLCAnaW50KicsICZ2YWx1ZSA6PSAwKQ0KCQlMYW5ndWFnZSA9PiAoQ29tQ2FsbCgxMCwgdGhpcywgJ3B0cionLCAmdmFsdWUgOj0gMCksIENvVGFza01lbV9TdHJpbmcodmFsdWUpKQ0KCQlUYWcgPT4gKENvbUNhbGwoMTEsIHRoaXMsICdwdHIqJywgJnZhbHVlIDo9IDApLCBDb1Rhc2tNZW1fU3RyaW5nKHZhbHVlKSkNCgkJSWNvblVyaSA9PiAoQ29tQ2FsbCgxMiwgdGhpcywgJ3B0cionLCAmdmFsdWUgOj0gMCksIENvVGFza01lbV9TdHJpbmcodmFsdWUpKQ0KCQlUaXRsZSA9PiAoQ29tQ2FsbCgxMywgdGhpcywgJ3B0cionLCAmdmFsdWUgOj0gMCksIENvVGFza01lbV9TdHJpbmcodmFsdWUpKQ0KCQlCYWRnZVVyaSA9PiAoQ29tQ2FsbCgxNCwgdGhpcywgJ3B0cionLCAmdmFsdWUgOj0gMCksIENvVGFza01lbV9TdHJpbmcodmFsdWUpKQ0KCQlCb2R5SW1hZ2VVcmkgPT4gKENvbUNhbGwoMTUsIHRoaXMsICdwdHIqJywgJnZhbHVlIDo9IDApLCBDb1Rhc2tNZW1fU3RyaW5nKHZhbHVlKSkNCgkJU2hvdWxkUmVub3RpZnkgPT4gKENvbUNhbGwoMTYsIHRoaXMsICdpbnQqJywgJnZhbHVlIDo9IDApLCB2YWx1ZSkNCgkJUmVxdWlyZXNJbnRlcmFjdGlvbiA9PiAoQ29tQ2FsbCgxNywgdGhpcywgJ2ludConLCAmdmFsdWUgOj0gMCksIHZhbHVlKQ0KCQlJc1NpbGVudCA9PiAoQ29tQ2FsbCgxOCwgdGhpcywgJ2ludConLCAmdmFsdWUgOj0gMCksIHZhbHVlKQ0KCQlUaW1lc3RhbXAgPT4gKENvbUNhbGwoMTksIHRoaXMsICdkb3VibGUqJywgJnZhbHVlIDo9IDApLCB2YWx1ZSkNCgkJR2V0VmlicmF0aW9uUGF0dGVybigpIHsNCgkJCUNvbUNhbGwoMjAsIHRoaXMsICd1aW50KicsICZjb3VudCA6PSAwLCAncHRyKicsICZwdmkgOj0gMCkNCgkJCSh2aWJyYXRpb25QYXR0ZXJuIDo9IFtdKS5DYXBhY2l0eSA6PSBjb3VudA0KCQkJbG9vcCBjb3VudA0KCQkJCXZpYnJhdGlvblBhdHRlcm4uUHVzaChOdW1HZXQocHZpLCAnaW50NjQnKSksIHB2aSArPSA4DQoJCQlyZXR1cm4gdmlicmF0aW9uUGF0dGVybg0KCQl9DQoJfQ0KCWNsYXNzIE5vdGlmaWNhdGlvblJlY2VpdmVkRXZlbnRBcmdzIGV4dGVuZHMgV2ViVmlldzIuQmFzZSB7DQoJCXN0YXRpYyBJSUQgOj0gJ3sxNTEyREQ1Qi01NTE0LTRGODUtODg2RS0yMUMzQTRDOUNGRTZ9Jw0KCQlTZW5kZXJPcmlnaW4gPT4gKENvbUNhbGwoMywgdGhpcywgJ3B0cionLCAmdmFsdWUgOj0gMCksIENvVGFza01lbV9TdHJpbmcodmFsdWUpKQ0KCQlOb3RpZmljYXRpb24gPT4gKENvbUNhbGwoNCwgdGhpcywgJ3B0cionLCB2YWx1ZSA6PSBXZWJWaWV3Mi5Ob3RpZmljYXRpb24oKSksIHZhbHVlKQ0KCQlIYW5kbGVkIHsNCgkJCXNldCA9PiBDb21DYWxsKDUsIHRoaXMsICdpbnQnLCBWYWx1ZSkNCgkJCWdldCA9PiAoQ29tQ2FsbCg2LCB0aGlzLCAnaW50KicsICZ2YWx1ZSA6PSAwKSwgdmFsdWUpDQoJCX0NCgkJR2V0RGVmZXJyYWwoKSA9PiAoQ29tQ2FsbCg3LCB0aGlzLCAncHRyKicsIGRlZmVycmFsIDo9IFdlYlZpZXcyLkRlZmVycmFsKCkpLCBkZWZlcnJhbCkNCgl9DQoJY2xhc3MgT2JqZWN0Q29sbGVjdGlvbiBleHRlbmRzIFdlYlZpZXcyLk9iamVjdENvbGxlY3Rpb25WaWV3IHsNCgkJc3RhdGljIElJRCA6PSAnezVjZmVjMTFjLTI1YmQtNGU4ZC05ZTFhLTdhY2RhZWVlYzA0N30nDQoJCVJlbW92ZVZhbHVlQXRJbmRleChpbmRleCkgPT4gQ29tQ2FsbCg1LCB0aGlzLCAndWludCcsIGluZGV4KQ0KCQlJbnNlcnRWYWx1ZUF0SW5kZXgoaW5kZXgsIHZhbHVlKSA9PiBDb21DYWxsKDYsIHRoaXMsICd1aW50JywgaW5kZXgsICdwdHInLCB2YWx1ZSkNCgl9DQoJY2xhc3MgT2JqZWN0Q29sbGVjdGlvblZpZXcgZXh0ZW5kcyBXZWJWaWV3Mi5MaXN0IHsNCgkJc3RhdGljIElJRCA6PSAnezBmMzZmZDg3LTRmNjktNDQxNS05OGRhLTg4OGY4OWZiOWEzM30nDQoJCUNvdW50ID0+IChDb21DYWxsKDMsIHRoaXMsICd1aW50KicsICZ2YWx1ZSA6PSAwKSwgdmFsdWUpDQoJCUdldFZhbHVlQXRJbmRleChpbmRleCkgPT4gKENvbUNhbGwoNCwgdGhpcywgJ3VpbnQnLCBpbmRleCwgJ3B0cionLCB2YWx1ZSA6PSBXZWJWaWV3Mi5CYXNlKCkpLCB2YWx1ZSkNCgl9DQoJY2xhc3MgUGVybWlzc2lvblJlcXVlc3RlZEV2ZW50QXJncyBleHRlbmRzIFdlYlZpZXcyLkJhc2Ugew0KCQlzdGF0aWMgSUlEIDo9ICd7OTczYWUyZWYtZmYxOC00ODk0LThmYjItM2M3NThmMDQ2ODEwfScNCgkJVXJpID0+IChDb21DYWxsKDMsIHRoaXMsICdwdHIqJywgJnVyaSA6PSAwKSwgQ29UYXNrTWVtX1N0cmluZyh1cmkpKQ0KCQlQZXJtaXNzaW9uS2luZCA9PiAoQ29tQ2FsbCg0LCB0aGlzLCAnaW50KicsICZwZXJtaXNzaW9uS2luZCA6PSAwKSwgcGVybWlzc2lvbktpbmQpCTsgQ09SRVdFQlZJRVcyX1BFUk1JU1NJT05fS0lORA0KCQlJc1VzZXJJbml0aWF0ZWQgPT4gKENvbUNhbGwoNSwgdGhpcywgJ2ludConLCAmaXNVc2VySW5pdGlhdGVkIDo9IDApLCBpc1VzZXJJbml0aWF0ZWQpDQoJCVN0YXRlIHsNCgkJCWdldCA9PiAoQ29tQ2FsbCg2LCB0aGlzLCAnaW50KicsICZzdGF0ZSA6PSAwKSwgc3RhdGUpCTsgQ09SRVdFQlZJRVcyX1BFUk1JU1NJT05fU1RBVEUNCgkJCXNldCA9PiBDb21DYWxsKDcsIHRoaXMsICdpbnQnLCBWYWx1ZSkNCgkJfQ0KCQlHZXREZWZlcnJhbCgpID0+IChDb21DYWxsKDgsIHRoaXMsICdwdHIqJywgZGVmZXJyYWwgOj0gV2ViVmlldzIuRGVmZXJyYWwoKSksIGRlZmVycmFsKQ0KDQoJCXN0YXRpYyBJSURfMiA6PSAnezc0ZDcxMjdmLTlkZTYtNDIwMC04NzM0LTQyZDZmYjRmZjc0MX0nDQoJCUhhbmRsZWQgew0KCQkJZ2V0ID0+IChDb21DYWxsKDksIHRoaXMsICdpbnQqJywgJmhhbmRsZWQgOj0gMCksIGhhbmRsZWQpDQoJCQlzZXQgPT4gQ29tQ2FsbCgxMCwgdGhpcywgJ2ludCcsIFZhbHVlKQ0KCQl9DQoNCgkJc3RhdGljIElJRF8zIDo9ICd7ZTYxNjcwYmMtM2RjZS00MTc3LTg2ZDItYzYyOWFlM2NiNmFjfScNCgkJU2F2ZXNJblByb2ZpbGUgew0KCQkJZ2V0ID0+IChDb21DYWxsKDExLCB0aGlzLCAnaW50KicsICZ2YWx1ZSA6PSAwKSwgdmFsdWUpDQoJCQlzZXQgPT4gQ29tQ2FsbCgxMiwgdGhpcywgJ2ludCcsIFZhbHVlKQ0KCQl9DQoJfQ0KCWNsYXNzIFBlcm1pc3Npb25TZXR0aW5nIGV4dGVuZHMgV2ViVmlldzIuQmFzZSB7DQoJCXN0YXRpYyBJSUQgOj0gJ3s3OTJiNmVjYS01NTc2LTQyMWMtOTExOS03NGViYjNhNGZmYjN9Jw0KCQlQZXJtaXNzaW9uS2luZCA9PiAoQ29tQ2FsbCgzLCB0aGlzLCAnaW50KicsICZ2YWx1ZSA6PSAwKSwgdmFsdWUpCTsgQ09SRVdFQlZJRVcyX1BFUk1JU1NJT05fS0lORA0KCQlQZXJtaXNzaW9uT3JpZ2luID0+IChDb21DYWxsKDQsIHRoaXMsICdpbnQqJywgJnZhbHVlIDo9IDApLCBDb1Rhc2tNZW1fU3RyaW5nKHZhbHVlKSkNCgkJUGVybWlzc2lvblN0YXRlID0+IChDb21DYWxsKDUsIHRoaXMsICdpbnQqJywgJnZhbHVlIDo9IDApLCB2YWx1ZSkJOyBDT1JFV0VCVklFVzJfUEVSTUlTU0lPTl9TVEFURQ0KCX0NCgljbGFzcyBQZXJtaXNzaW9uU2V0dGluZ0NvbGxlY3Rpb25WaWV3IGV4dGVuZHMgV2ViVmlldzIuTGlzdCB7DQoJCXN0YXRpYyBJSUQgOj0gJ3tmNTU5NmY2Mi0zZGU1LTQ3YjEtOTFlOC1hNDEwNGI1OTZiOTZ9Jw0KCQlHZXRWYWx1ZUF0SW5kZXgoaW5kZXgpID0+IChDb21DYWxsKDMsIHRoaXMsICdwdHIqJywgcGVybWlzc2lvblNldHRpbmcgOj0gV2ViVmlldzIuUGVybWlzc2lvblNldHRpbmcoKSksIHBlcm1pc3Npb25TZXR0aW5nKQ0KCQlDb3VudCA9PiAoQ29tQ2FsbCg0LCB0aGlzLCAndWludConLCAmdmFsdWUgOj0gMCksIHZhbHVlKQ0KCX0NCgljbGFzcyBQb2ludGVySW5mbyBleHRlbmRzIFdlYlZpZXcyLkJhc2Ugew0KCQlzdGF0aWMgSUlEIDo9ICd7ZTY5OTU4ODctZDEwZC00ZjVkLTkzNTktNGNlNDZlNGY5NmI5fScNCgkJUG9pbnRlcktpbmQgew0KCQkJZ2V0ID0+IChDb21DYWxsKDMsIHRoaXMsICd1aW50KicsICZwb2ludGVyS2luZCA6PSAwKSwgcG9pbnRlcktpbmQpDQoJCQlzZXQgPT4gQ29tQ2FsbCg0LCB0aGlzLCAndWludCcsIFZhbHVlKQ0KCQl9DQoJCVBvaW50ZXJJZCB7DQoJCQlnZXQgPT4gKENvbUNhbGwoNSwgdGhpcywgJ3VpbnQqJywgJnBvaW50ZXJJZCA6PSAwKSwgcG9pbnRlcklkKQ0KCQkJc2V0ID0+IENvbUNhbGwoNiwgdGhpcywgJ3VpbnQnLCBWYWx1ZSkNCgkJfQ0KCQlGcmFtZUlkIHsNCgkJCWdldCA9PiAoQ29tQ2FsbCg3LCB0aGlzLCAndWludConLCAmZnJhbWVJZCA6PSAwKSwgZnJhbWVJZCkNCgkJCXNldCA9PiBDb21DYWxsKDgsIHRoaXMsICd1aW50JywgVmFsdWUpDQoJCX0NCgkJUG9pbnRlckZsYWdzIHsNCgkJCWdldCA9PiAoQ29tQ2FsbCg5LCB0aGlzLCAndWludConLCAmcG9pbnRlckZsYWdzIDo9IDApLCBwb2ludGVyRmxhZ3MpDQoJCQlzZXQgPT4gQ29tQ2FsbCgxMCwgdGhpcywgJ3VpbnQnLCBWYWx1ZSkNCgkJfQ0KCQlQb2ludGVyRGV2aWNlUmVjdCB7DQoJCQlnZXQgPT4gKENvbUNhbGwoMTEsIHRoaXMsICdwdHInLCBwb2ludGVyRGV2aWNlUmVjdCA6PSBXZWJWaWV3Mi5SRUNUKCkpLCBwb2ludGVyRGV2aWNlUmVjdCkNCgkJCXNldCA9PiAoQV9QdHJTaXplID0gOCA/IENvbUNhbGwoMTIsIHRoaXMsICdwdHInLCBWYWx1ZSkgOiBDb21DYWxsKDEyLCB0aGlzLCAnaW50NjQnLCBOdW1HZXQoVmFsdWUsICdpbnQ2NCcpLCAnaW50NjQnLCBOdW1HZXQoVmFsdWUsIDgsICdpbnQ2NCcpKSkNCgkJfQ0KCQlEaXNwbGF5UmVjdCB7DQoJCQlnZXQgPT4gKENvbUNhbGwoMTMsIHRoaXMsICdwdHInLCBkaXNwbGF5UmVjdCA6PSBXZWJWaWV3Mi5SRUNUKCkpLCBkaXNwbGF5UmVjdCkNCgkJCXNldCA9PiAoQV9QdHJTaXplID0gOCA/IENvbUNhbGwoMTQsIHRoaXMsICdwdHInLCBWYWx1ZSkgOiBDb21DYWxsKDE0LCB0aGlzLCAnaW50NjQnLCBOdW1HZXQoVmFsdWUsICdpbnQ2NCcpLCAnaW50NjQnLCBOdW1HZXQoVmFsdWUsIDgsICdpbnQ2NCcpKSkNCgkJfQ0KCQlQaXhlbExvY2F0aW9uIHsNCgkJCWdldCA9PiAoQ29tQ2FsbCgxNSwgdGhpcywgJ2ludDY0KicsICZwaXhlbExvY2F0aW9uIDo9IDApLCBwaXhlbExvY2F0aW9uKQ0KCQkJc2V0ID0+IENvbUNhbGwoMTYsIHRoaXMsICdpbnQ2NCcsIFZhbHVlKQ0KCQl9DQoJCUhpbWV0cmljTG9jYXRpb24gew0KCQkJZ2V0ID0+IChDb21DYWxsKDE3LCB0aGlzLCAnaW50NjQqJywgJmhpbWV0cmljTG9jYXRpb24gOj0gMCksIGhpbWV0cmljTG9jYXRpb24pDQoJCQlzZXQgPT4gQ29tQ2FsbCgxOCwgdGhpcywgJ2ludDY0JywgVmFsdWUpDQoJCX0NCgkJUGl4ZWxMb2NhdGlvblJhdyB7DQoJCQlnZXQgPT4gKENvbUNhbGwoMTksIHRoaXMsICdpbnQ2NConLCAmcGl4ZWxMb2NhdGlvblJhdyA6PSAwKSwgcGl4ZWxMb2NhdGlvblJhdykNCgkJCXNldCA9PiBDb21DYWxsKDIwLCB0aGlzLCAnaW50NjQnLCBWYWx1ZSkNCgkJfQ0KCQlIaW1ldHJpY0xvY2F0aW9uUmF3IHsNCgkJCWdldCA9PiAoQ29tQ2FsbCgyMSwgdGhpcywgJ2ludDY0KicsICZoaW1ldHJpY0xvY2F0aW9uUmF3IDo9IDApLCBoaW1ldHJpY0xvY2F0aW9uUmF3KQ0KCQkJc2V0ID0+IENvbUNhbGwoMjIsIHRoaXMsICdpbnQ2NCcsIFZhbHVlKQ0KCQl9DQoJCVRpbWUgew0KCQkJZ2V0ID0+IChDb21DYWxsKDIzLCB0aGlzLCAndWludConLCAmdGltZSA6PSAwKSwgdGltZSkNCgkJCXNldCA9PiBDb21DYWxsKDI0LCB0aGlzLCAndWludCcsIFZhbHVlKQ0KCQl9DQoJCUhpc3RvcnlDb3VudCB7DQoJCQlnZXQgPT4gKENvbUNhbGwoMjUsIHRoaXMsICd1aW50KicsICZoaXN0b3J5Q291bnQgOj0gMCksIGhpc3RvcnlDb3VudCkNCgkJCXNldCA9PiBDb21DYWxsKDI2LCB0aGlzLCAndWludCcsIFZhbHVlKQ0KCQl9DQoJCUlucHV0RGF0YSB7DQoJCQlnZXQgPT4gKENvbUNhbGwoMjcsIHRoaXMsICdpbnQqJywgJmlucHV0RGF0YSA6PSAwKSwgaW5wdXREYXRhKQ0KCQkJc2V0ID0+IENvbUNhbGwoMjgsIHRoaXMsICdpbnQnLCBWYWx1ZSkNCgkJfQ0KCQlLZXlTdGF0ZXMgew0KCQkJZ2V0ID0+IChDb21DYWxsKDI5LCB0aGlzLCAndWludConLCAma2V5U3RhdGVzIDo9IDApLCBrZXlTdGF0ZXMpDQoJCQlzZXQgPT4gQ29tQ2FsbCgzMCwgdGhpcywgJ3VpbnQnLCBWYWx1ZSkNCgkJfQ0KCQlQZXJmb3JtYW5jZUNvdW50IHsNCgkJCWdldCA9PiAoQ29tQ2FsbCgzMSwgdGhpcywgJ3VpbnQ2NConLCAmcGVyZm9ybWFuY2VDb3VudCA6PSAwKSwgcGVyZm9ybWFuY2VDb3VudCkNCgkJCXNldCA9PiBDb21DYWxsKDMyLCB0aGlzLCAndWludDY0JywgVmFsdWUpDQoJCX0NCgkJQnV0dG9uQ2hhbmdlS2luZCB7DQoJCQlnZXQgPT4gKENvbUNhbGwoMzMsIHRoaXMsICdpbnQqJywgJmJ1dHRvbkNoYW5nZUtpbmQgOj0gMCksIGJ1dHRvbkNoYW5nZUtpbmQpDQoJCQlzZXQgPT4gQ29tQ2FsbCgzNCwgdGhpcywgJ2ludCcsIFZhbHVlKQ0KCQl9DQoJCVBlbkZsYWdzIHsNCgkJCWdldCA9PiAoQ29tQ2FsbCgzNSwgdGhpcywgJ3VpbnQqJywgJnBlbkZMYWdzIDo9IDApLCBwZW5GTGFncykNCgkJCXNldCA9PiBDb21DYWxsKDM2LCB0aGlzLCAndWludCcsIFZhbHVlKQ0KCQl9DQoJCVBlbk1hc2sgew0KCQkJZ2V0ID0+IChDb21DYWxsKDM3LCB0aGlzLCAndWludConLCAmcGVuTWFzayA6PSAwKSwgcGVuTWFzaykNCgkJCXNldCA9PiBDb21DYWxsKDM4LCB0aGlzLCAndWludCcsIFZhbHVlKQ0KCQl9DQoJCVBlblByZXNzdXJlIHsNCgkJCWdldCA9PiAoQ29tQ2FsbCgzOSwgdGhpcywgJ3VpbnQqJywgJnBlblByZXNzdXJlIDo9IDApLCBwZW5QcmVzc3VyZSkNCgkJCXNldCA9PiBDb21DYWxsKDQwLCB0aGlzLCAndWludCcsIFZhbHVlKQ0KCQl9DQoJCVBlblJvdGF0aW9uIHsNCgkJCWdldCA9PiAoQ29tQ2FsbCg0MSwgdGhpcywgJ3VpbnQqJywgJnBlblJvdGF0aW9uIDo9IDApLCBwZW5Sb3RhdGlvbikNCgkJCXNldCA9PiBDb21DYWxsKDQyLCB0aGlzLCAndWludCcsIFZhbHVlKQ0KCQl9DQoJCVBlblRpbHRYIHsNCgkJCWdldCA9PiAoQ29tQ2FsbCg0MywgdGhpcywgJ2ludConLCAmcGVuVGlsdFggOj0gMCksIHBlblRpbHRYKQ0KCQkJc2V0ID0+IENvbUNhbGwoNDQsIHRoaXMsICdpbnQnLCBWYWx1ZSkNCgkJfQ0KCQlQZW5UaWx0WSB7DQoJCQlnZXQgPT4gKENvbUNhbGwoNDUsIHRoaXMsICdpbnQqJywgJnBlblRpbHRZIDo9IDApLCBwZW5UaWx0WSkNCgkJCXNldCA9PiBDb21DYWxsKDQ2LCB0aGlzLCAnaW50JywgVmFsdWUpDQoJCX0NCgkJVG91Y2hGbGFncyB7DQoJCQlnZXQgPT4gKENvbUNhbGwoNDcsIHRoaXMsICd1aW50KicsICZ0b3VjaEZsYWdzIDo9IDApLCB0b3VjaEZsYWdzKQ0KCQkJc2V0ID0+IENvbUNhbGwoNDgsIHRoaXMsICd1aW50JywgVmFsdWUpDQoJCX0NCgkJVG91Y2hNYXNrIHsNCgkJCWdldCA9PiAoQ29tQ2FsbCg0OSwgdGhpcywgJ3VpbnQqJywgJnRvdWNoTWFzayA6PSAwKSwgdG91Y2hNYXNrKQ0KCQkJc2V0ID0+IENvbUNhbGwoNTAsIHRoaXMsICd1aW50JywgVmFsdWUpDQoJCX0NCgkJVG91Y2hDb250YWN0IHsNCgkJCWdldCA9PiAoQ29tQ2FsbCg1MSwgdGhpcywgJ3B0cicsIHRvdWNoQ29udGFjdCA6PSBXZWJWaWV3Mi5SRUNUKCkpLCB0b3VjaENvbnRhY3QpDQoJCQlzZXQgPT4gKEFfUHRyU2l6ZSA9IDggPyBDb21DYWxsKDUyLCB0aGlzLCAncHRyJywgVmFsdWUpIDogQ29tQ2FsbCg1MiwgdGhpcywgJ2ludDY0JywgTnVtR2V0KFZhbHVlLCAnaW50NjQnKSwgJ2ludDY0JywgTnVtR2V0KFZhbHVlLCA4LCAnaW50NjQnKSkpDQoJCX0NCgkJVG91Y2hDb250YWN0UmF3IHsNCgkJCWdldCA9PiAoQ29tQ2FsbCg1MywgdGhpcywgJ3B0cicsIHRvdWNoQ29udGFjdFJhdyA6PSBXZWJWaWV3Mi5SRUNUKCkpLCB0b3VjaENvbnRhY3RSYXcpDQoJCQlzZXQgPT4gKEFfUHRyU2l6ZSA9IDggPyBDb21DYWxsKDU0LCB0aGlzLCAncHRyJywgVmFsdWUpIDogQ29tQ2FsbCg1NCwgdGhpcywgJ2ludDY0JywgTnVtR2V0KFZhbHVlLCAnaW50NjQnKSwgJ2ludDY0JywgTnVtR2V0KFZhbHVlLCA4LCAnaW50NjQnKSkpDQoJCX0NCgkJVG91Y2hPcmllbnRhdGlvbiB7DQoJCQlnZXQgPT4gKENvbUNhbGwoNTUsIHRoaXMsICd1aW50KicsICZ0b3VjaE9yaWVudGF0aW9uIDo9IDApLCB0b3VjaE9yaWVudGF0aW9uKQ0KCQkJc2V0ID0+IENvbUNhbGwoNTYsIHRoaXMsICd1aW50JywgVmFsdWUpDQoJCX0NCgkJVG91Y2hQcmVzc3VyZSB7DQoJCQlnZXQgPT4gKENvbUNhbGwoNTcsIHRoaXMsICd1aW50KicsICZ0b3VjaFByZXNzdXJlIDo9IDApLCB0b3VjaFByZXNzdXJlKQ0KCQkJc2V0ID0+IENvbUNhbGwoNTgsIHRoaXMsICd1aW50JywgVmFsdWUpDQoJCX0NCgl9DQoJY2xhc3MgUHJpbnRTZXR0aW5ncyBleHRlbmRzIFdlYlZpZXcyLkJhc2Ugew0KCQlzdGF0aWMgSUlEIDo9ICd7Mzc3ZjM3MjEtYzc0ZS00OGNhLThkYjEtZGY2OGU1MWQ2MGUyfScNCgkJT3JpZW50YXRpb24gew0KCQkJZ2V0ID0+IChDb21DYWxsKDMsIHRoaXMsICdpbnQqJywgJm9yaWVudGF0aW9uIDo9IDApLCBvcmllbnRhdGlvbikNCgkJCXNldCA9PiBDb21DYWxsKDQsIHRoaXMsICdpbnQnLCBWYWx1ZSkNCgkJfQ0KCQlTY2FsZUZhY3RvciB7DQoJCQlnZXQgPT4gKENvbUNhbGwoNSwgdGhpcywgJ2RvdWJsZSonLCAmc2NhbGVGYWN0b3IgOj0gMCksIHNjYWxlRmFjdG9yKQ0KCQkJc2V0ID0+IENvbUNhbGwoNiwgdGhpcywgJ2RvdWJsZScsIFZhbHVlKQ0KCQl9DQoJCVBhZ2VXaWR0aCB7DQoJCQlnZXQgPT4gKENvbUNhbGwoNywgdGhpcywgJ2RvdWJsZSonLCAmcGFnZVdpZHRoIDo9IDApLCBwYWdlV2lkdGgpDQoJCQlzZXQgPT4gQ29tQ2FsbCg4LCB0aGlzLCAnZG91YmxlJywgVmFsdWUpDQoJCX0NCgkJUGFnZUhlaWdodCB7DQoJCQlnZXQgPT4gKENvbUNhbGwoOSwgdGhpcywgJ2RvdWJsZSonLCAmcGFnZUhlaWdodCA6PSAwKSwgcGFnZUhlaWdodCkNCgkJCXNldCA9PiBDb21DYWxsKDEwLCB0aGlzLCAnZG91YmxlJywgVmFsdWUpDQoJCX0NCgkJTWFyZ2luVG9wIHsNCgkJCWdldCA9PiAoQ29tQ2FsbCgxMSwgdGhpcywgJ2RvdWJsZSonLCAmbWFyZ2luVG9wIDo9IDApLCBtYXJnaW5Ub3ApDQoJCQlzZXQgPT4gQ29tQ2FsbCgxMiwgdGhpcywgJ2RvdWJsZScsIFZhbHVlKQ0KCQl9DQoJCU1hcmdpbkJvdHRvbSB7DQoJCQlnZXQgPT4gKENvbUNhbGwoMTMsIHRoaXMsICdkb3VibGUqJywgJm1hcmdpbkJvdHRvbSA6PSAwKSwgbWFyZ2luQm90dG9tKQ0KCQkJc2V0ID0+IENvbUNhbGwoMTQsIHRoaXMsICdkb3VibGUnLCBWYWx1ZSkNCgkJfQ0KCQlNYXJnaW5MZWZ0IHsNCgkJCWdldCA9PiAoQ29tQ2FsbCgxNSwgdGhpcywgJ2RvdWJsZSonLCAmbWFyZ2luTGVmdCA6PSAwKSwgbWFyZ2luTGVmdCkNCgkJCXNldCA9PiBDb21DYWxsKDE2LCB0aGlzLCAnZG91YmxlJywgVmFsdWUpDQoJCX0NCgkJTWFyZ2luUmlnaHQgew0KCQkJZ2V0ID0+IChDb21DYWxsKDE3LCB0aGlzLCAnZG91YmxlKicsICZtYXJnaW5SaWdodCA6PSAwKSwgbWFyZ2luUmlnaHQpDQoJCQlzZXQgPT4gQ29tQ2FsbCgxOCwgdGhpcywgJ2RvdWJsZScsIFZhbHVlKQ0KCQl9DQoJCVNob3VsZFByaW50QmFja2dyb3VuZHMgew0KCQkJZ2V0ID0+IChDb21DYWxsKDE5LCB0aGlzLCAnaW50KicsICZzaG91bGRQcmludEJhY2tncm91bmRzIDo9IDApLCBzaG91bGRQcmludEJhY2tncm91bmRzKQ0KCQkJc2V0ID0+IENvbUNhbGwoMjAsIHRoaXMsICdpbnQnLCBWYWx1ZSkNCgkJfQ0KCQlTaG91bGRQcmludFNlbGVjdGlvbk9ubHkgew0KCQkJZ2V0ID0+IChDb21DYWxsKDIxLCB0aGlzLCAnaW50KicsICZzaG91bGRQcmludFNlbGVjdGlvbk9ubHkgOj0gMCksIHNob3VsZFByaW50U2VsZWN0aW9uT25seSkNCgkJCXNldCA9PiBDb21DYWxsKDIyLCB0aGlzLCAnaW50JywgVmFsdWUpDQoJCX0NCgkJU2hvdWxkUHJpbnRIZWFkZXJBbmRGb290ZXIgew0KCQkJZ2V0ID0+IChDb21DYWxsKDIzLCB0aGlzLCAnaW50KicsICZzaG91bGRQcmludEhlYWRlckFuZEZvb3RlciA6PSAwKSwgc2hvdWxkUHJpbnRIZWFkZXJBbmRGb290ZXIpDQoJCQlzZXQgPT4gQ29tQ2FsbCgyNCwgdGhpcywgJ2ludCcsIFZhbHVlKQ0KCQl9DQoJCUhlYWRlclRpdGxlIHsNCgkJCWdldCA9PiAoQ29tQ2FsbCgyNSwgdGhpcywgJ3B0cionLCAmaGVhZGVyVGl0bGUgOj0gMCksIENvVGFza01lbV9TdHJpbmcoaGVhZGVyVGl0bGUpKQ0KCQkJc2V0ID0+IENvbUNhbGwoMjYsIHRoaXMsICd3c3RyJywgVmFsdWUpDQoJCX0NCgkJRm9vdGVyVXJpIHsNCgkJCWdldCA9PiAoQ29tQ2FsbCgyNywgdGhpcywgJ3B0cionLCAmZm9vdGVyVXJpIDo9IDApLCBDb1Rhc2tNZW1fU3RyaW5nKGZvb3RlclVyaSkpDQoJCQlzZXQgPT4gQ29tQ2FsbCgyOCwgdGhpcywgJ3dzdHInLCBWYWx1ZSkNCgkJfQ0KDQoJCXN0YXRpYyBJSURfMiA6PSAne0NBN0YwRTFGLTM0ODQtNDFEMS04QzFBLTY1Q0Q0NEE2M0Y4RH0nDQoJCVBhZ2VSYW5nZXMgew0KCQkJZ2V0ID0+IChDb21DYWxsKDI5LCB0aGlzLCAncHRyKicsICZ2YWx1ZSA6PSAwKSwgQ29UYXNrTWVtX1N0cmluZyh2YWx1ZSkpDQoJCQlzZXQgPT4gQ29tQ2FsbCgzMCwgdGhpcywgJ3dzdHInLCBWYWx1ZSkNCgkJfQ0KCQlQYWdlc1BlclNpZGUgew0KCQkJZ2V0ID0+IChDb21DYWxsKDMxLCB0aGlzLCAnaW50KicsICZ2YWx1ZSA6PSAwKSwgdmFsdWUpDQoJCQlzZXQgPT4gQ29tQ2FsbCgzMiwgdGhpcywgJ2ludCcsIFZhbHVlKQ0KCQl9DQoJCUNvcGllcyB7DQoJCQlnZXQgPT4gKENvbUNhbGwoMzMsIHRoaXMsICdpbnQqJywgJnZhbHVlIDo9IDApLCB2YWx1ZSkNCgkJCXNldCA9PiBDb21DYWxsKDM0LCB0aGlzLCAnaW50JywgVmFsdWUpDQoJCX0NCgkJQ29sbGF0aW9uIHsNCgkJCWdldCA9PiAoQ29tQ2FsbCgzNSwgdGhpcywgJ2ludConLCAmdmFsdWUgOj0gMCksIHZhbHVlKQk7IENPUkVXRUJWSUVXMl9QUklOVF9DT0xMQVRJT04NCgkJCXNldCA9PiBDb21DYWxsKDM2LCB0aGlzLCAnaW50JywgVmFsdWUpDQoJCX0NCgkJQ29sb3JNb2RlIHsNCgkJCWdldCA9PiAoQ29tQ2FsbCgzNywgdGhpcywgJ2ludConLCAmdmFsdWUgOj0gMCksIHZhbHVlKQk7IENPUkVXRUJWSUVXMl9QUklOVF9DT0xPUl9NT0RFDQoJCQlzZXQgPT4gQ29tQ2FsbCgzOCwgdGhpcywgJ2ludCcsIFZhbHVlKQ0KCQl9DQoJCUR1cGxleCB7DQoJCQlnZXQgPT4gKENvbUNhbGwoMzksIHRoaXMsICdpbnQqJywgJnZhbHVlIDo9IDApLCB2YWx1ZSkJOyBDT1JFV0VCVklFVzJfUFJJTlRfRFVQTEVYDQoJCQlzZXQgPT4gQ29tQ2FsbCg0MCwgdGhpcywgJ2ludCcsIFZhbHVlKQ0KCQl9DQoJCU1lZGlhU2l6ZSB7DQoJCQlnZXQgPT4gKENvbUNhbGwoNDEsIHRoaXMsICdpbnQqJywgJnZhbHVlIDo9IDApLCB2YWx1ZSkJOyBDT1JFV0VCVklFVzJfUFJJTlRfTUVESUFfU0laRQ0KCQkJc2V0ID0+IENvbUNhbGwoNDIsIHRoaXMsICdpbnQnLCBWYWx1ZSkNCgkJfQ0KCQlQcmludGVyTmFtZSB7DQoJCQlnZXQgPT4gKENvbUNhbGwoNDMsIHRoaXMsICdwdHIqJywgJnZhbHVlIDo9IDApLCBDb1Rhc2tNZW1fU3RyaW5nKHZhbHVlKSkNCgkJCXNldCA9PiBDb21DYWxsKDQ0LCB0aGlzLCAnd3N0cicsIFZhbHVlKQ0KCQl9DQoJfQ0KCWNsYXNzIFByb2Nlc3NFeHRlbmRlZEluZm8gZXh0ZW5kcyBXZWJWaWV3Mi5CYXNlIHsNCgkJc3RhdGljIElJRCA6PSAne2FmNGM0YzJlLTQ1ZGItMTFlZS1iZTU2LTAyNDJhYzEyMDAwMn0nDQoJCVByb2Nlc3NJbmZvID0+IChDb21DYWxsKDMsIHRoaXMsICdwdHIqJywgcHJvY2Vzc0luZm8gOj0gV2ViVmlldzIuUHJvY2Vzc0luZm8oKSksIHByb2Nlc3NJbmZvKQ0KCQlBc3NvY2lhdGVkRnJhbWVJbmZvcyA9PiAoQ29tQ2FsbCgzLCB0aGlzLCAncHRyKicsIGZyYW1lcyA6PSBXZWJWaWV3Mi5GcmFtZUluZm9Db2xsZWN0aW9uKCkpLCBmcmFtZXMpDQoJfQ0KCWNsYXNzIFByb2Nlc3NFeHRlbmRlZEluZm9Db2xsZWN0aW9uIGV4dGVuZHMgV2ViVmlldzIuTGlzdCB7DQoJCXN0YXRpYyBJSUQgOj0gJ3szMmVmYTY5Ni00MDdhLTExZWUtYmU1Ni0wMjQyYWMxMjAwMDJ9Jw0KCQlDb3VudCA9PiAoQ29tQ2FsbCgzLCB0aGlzLCAndWludConLCAmY291bnQgOj0gMCksIGNvdW50KQ0KCQlHZXRWYWx1ZUF0SW5kZXgoaW5kZXgpID0+IChDb21DYWxsKDQsIHRoaXMsICd1aW50JywgaW5kZXgsICdwdHIqJywgcHJvY2Vzc0luZm8gOj0gV2ViVmlldzIuUHJvY2Vzc0V4dGVuZGVkSW5mbygpKSwgcHJvY2Vzc0luZm8pDQoJfQ0KCWNsYXNzIFByb2Nlc3NJbmZvIGV4dGVuZHMgV2ViVmlldzIuQmFzZSB7DQoJCXN0YXRpYyBJSUQgOj0gJ3s4NEZBNzYxMi0zRjNELTRGQkYtODg5RC1GQUQwMDA0OTJENzJ9Jw0KCQlQcm9jZXNzSWQgPT4gKENvbUNhbGwoMywgdGhpcywgJ2ludConLCAmdmFsdWUgOj0gMCksIHZhbHVlKQ0KCQlLaW5kID0+IChDb21DYWxsKDQsIHRoaXMsICdpbnQqJywgJmtpbmQgOj0gMCksIGtpbmQpCTsgQ09SRVdFQlZJRVcyX1BST0NFU1NfS0lORA0KCX0NCgljbGFzcyBQcm9jZXNzSW5mb0NvbGxlY3Rpb24gZXh0ZW5kcyBXZWJWaWV3Mi5MaXN0IHsNCgkJc3RhdGljIElJRCA6PSAnezQwMkI5OUNELUEwQ0MtNEZBNS1CN0E1LTUxRDg2QTFEMjMzOX0nDQoJCUNvdW50ID0+IChDb21DYWxsKDMsIHRoaXMsICd1aW50KicsICZjb3VudCA6PSAwKSwgY291bnQpDQoJCUdldFZhbHVlQXRJbmRleChpbmRleCkgPT4gKENvbUNhbGwoNCwgdGhpcywgJ3VpbnQnLCBpbmRleCwgJ3B0cionLCBwcm9jZXNzSW5mbyA6PSBXZWJWaWV3Mi5Qcm9jZXNzSW5mbygpKSwgcHJvY2Vzc0luZm8pDQoJfQ0KCWNsYXNzIFByb2ZpbGUgZXh0ZW5kcyBXZWJWaWV3Mi5CYXNlIHsNCgkJc3RhdGljIElJRCA6PSAnezc5MTEwYWQzLWNkNWQtNDM3My04YmMzLWM2MDY1OGYxN2E1Zn0nDQoJCVByb2ZpbGVOYW1lID0+IChDb21DYWxsKDMsIHRoaXMsICdwdHIqJywgJnZhbHVlIDo9IDApLCBDb1Rhc2tNZW1fU3RyaW5nKHZhbHVlKSkNCgkJSXNJblByaXZhdGVNb2RlRW5hYmxlZCA9PiAoQ29tQ2FsbCg0LCB0aGlzLCAnaW50KicsICZ2YWx1ZSA6PSAwKSwgdmFsdWUpDQoJCVByb2ZpbGVQYXRoID0+IChDb21DYWxsKDUsIHRoaXMsICdwdHIqJywgJnZhbHVlIDo9IDApLCBDb1Rhc2tNZW1fU3RyaW5nKHZhbHVlKSkNCgkJRGVmYXVsdERvd25sb2FkRm9sZGVyUGF0aCB7DQoJCQlnZXQgPT4gKENvbUNhbGwoNiwgdGhpcywgJ3B0cionLCAmdmFsdWUgOj0gMCksIENvVGFza01lbV9TdHJpbmcodmFsdWUpKQ0KCQkJc2V0ID0+IENvbUNhbGwoNywgdGhpcywgJ3dzdHInLCBWYWx1ZSkNCgkJfQ0KCQlQcmVmZXJyZWRDb2xvclNjaGVtZSB7DQoJCQlnZXQgPT4gKENvbUNhbGwoOCwgdGhpcywgJ2ludConLCAmdmFsdWUgOj0gMCksIHZhbHVlKQk7IENPUkVXRUJWSUVXMl9QUkVGRVJSRURfQ09MT1JfU0NIRU1FDQoJCQlzZXQgPT4gQ29tQ2FsbCg5LCB0aGlzLCAnaW50JywgVmFsdWUpDQoJCX0NCg0KCQlzdGF0aWMgSUlEXzIgOj0gJ3tmYTc0MGQ0Yi01ZWFlLTQzNDQtYThhZC03NGJlMzE5MjUzOTd9Jw0KCQkvKiogQHJldHVybnMge1Byb21pc2U8dm9pZD59ICovDQoJCUNsZWFyQnJvd3NpbmdEYXRhQXN5bmMoZGF0YUtpbmRzKSA9PiAoQ29tQ2FsbCgxMCwgdGhpcywgJ2ludCcsIGRhdGFLaW5kcywgJ3B0cicsIFdlYlZpZXcyLkFzeW5jSGFuZGxlcigmcCkpLCBwKQk7IENPUkVXRUJWSUVXMl9CUk9XU0lOR19EQVRBX0tJTkRTDQoJCS8qKiBAcmV0dXJucyB7UHJvbWlzZTx2b2lkPn0gKi8NCgkJQ2xlYXJCcm93c2luZ0RhdGFJblRpbWVSYW5nZUFzeW5jKGRhdGFLaW5kcywgc3RhcnRUaW1lLCBlbmRUaW1lKSA9PiAoQ29tQ2FsbCgxMSwgdGhpcywgJ2ludCcsIGRhdGFLaW5kcywgJ2RvdWJsZScsIHN0YXJ0VGltZSwgJ2RvdWJsZScsIGVuZFRpbWUsICdwdHInLCBXZWJWaWV3Mi5Bc3luY0hhbmRsZXIoJnApKSwgcCkJOyBDT1JFV0VCVklFVzJfQlJPV1NJTkdfREFUQV9LSU5EUw0KCQkvKiogQHJldHVybnMge1Byb21pc2U8dm9pZD59ICovDQoJCUNsZWFyQnJvd3NpbmdEYXRhQWxsQXN5bmMoKSA9PiAoQ29tQ2FsbCgxMiwgdGhpcywgJ3B0cicsIFdlYlZpZXcyLkFzeW5jSGFuZGxlcigmcCkpLCBwKQ0KDQoJCXN0YXRpYyBJSURfMyA6PSAne0IxODhFNjU5LTU2ODUtNEUwNS1CREJBLUZDNjQwRTBGMTk5Mn0nDQoJCVByZWZlcnJlZFRyYWNraW5nUHJldmVudGlvbkxldmVsIHsNCgkJCWdldCA9PiAoQ29tQ2FsbCgxMywgdGhpcywgJ2ludConLCAmdmFsdWUgOj0gMCksIHZhbHVlKQk7IENPUkVXRUJWSUVXMl9UUkFDS0lOR19QUkVWRU5USU9OX0xFVkVMDQoJCQlzZXQgPT4gQ29tQ2FsbCgxNCwgdGhpcywgJ2ludCcsIFZhbHVlKQ0KCQl9DQoNCgkJc3RhdGljIElJRF80IDo9ICd7OEY0YWU2ODAtMTkyZS00ZUM4LTgzM2EtMjFjZmFkYWVmNjI4fScNCgkJLyoqIEByZXR1cm5zIHtQcm9taXNlPHZvaWQ+fSAqLw0KCQlTZXRQZXJtaXNzaW9uU3RhdGVBc3luYyhwZXJtaXNzaW9uS2luZCwgb3JpZ2luLCBzdGF0ZSkgPT4gKENvbUNhbGwoMTUsIHRoaXMsICdpbnQnLCBwZXJtaXNzaW9uS2luZCwgJ3dzdHInLCBvcmlnaW4sICdpbnQnLCBzdGF0ZSwgJ3B0cicsIFdlYlZpZXcyLkFzeW5jSGFuZGxlcigmcCkpLCBwKQk7IENPUkVXRUJWSUVXMl9QRVJNSVNTSU9OX0tJTkQsLCBDT1JFV0VCVklFVzJfUEVSTUlTU0lPTl9TVEFURQ0KCQkvKiogQHJldHVybnMge1Byb21pc2U8V2ViVmlldzIuUGVybWlzc2lvblNldHRpbmdDb2xsZWN0aW9uVmlldz59ICovDQoJCUdldE5vbkRlZmF1bHRQZXJtaXNzaW9uU2V0dGluZ3NBc3luYygpID0+IChDb21DYWxsKDE2LCB0aGlzLCAncHRyJywgV2ViVmlldzIuQXN5bmNIYW5kbGVyKCZwLCBXZWJWaWV3Mi5QZXJtaXNzaW9uU2V0dGluZ0NvbGxlY3Rpb25WaWV3KSksIHApDQoNCgkJc3RhdGljIElJRF81IDo9ICd7MkVFNUI3NkUtNkU4MC00REYyLUJDRDMtRDRFQzMzNDBBMDFCfScNCgkJQ29va2llTWFuYWdlciA9PiAoQ29tQ2FsbCgxNywgdGhpcywgJ3B0cionLCBjb29raWVNYW5hZ2VyIDo9IFdlYlZpZXcyLkNvb2tpZU1hbmFnZXIoKSksIGNvb2tpZU1hbmFnZXIpDQoNCgkJc3RhdGljIElJRF82IDo9ICd7QkQ4MkZBNkEtMUQ2NS00QzMzLUIyQjQtMDM5MzAyMENDNjFCfScNCgkJSXNQYXNzd29yZEF1dG9zYXZlRW5hYmxlZCB7DQoJCQlnZXQgPT4gKENvbUNhbGwoMTgsIHRoaXMsICdpbnQqJywgJnZhbHVlIDo9IDApLCB2YWx1ZSkNCgkJCXNldCA9PiBDb21DYWxsKDE5LCB0aGlzLCAnaW50JywgVmFsdWUpDQoJCX0NCgkJSXNHZW5lcmFsQXV0b2ZpbGxFbmFibGVkIHsNCgkJCWdldCA9PiAoQ29tQ2FsbCgyMCwgdGhpcywgJ2ludConLCAmdmFsdWUgOj0gMCksIHZhbHVlKQ0KCQkJc2V0ID0+IENvbUNhbGwoMjEsIHRoaXMsICdpbnQnLCBWYWx1ZSkNCgkJfQ0KDQoJCXN0YXRpYyBJSURfNyA6PSAnezdiNGM3OTA2LWExYWEtNGNiNC1iNzIzLWRiMDlmODEzZDU0MX0nDQoJCS8qKiBAcmV0dXJucyB7UHJvbWlzZTxXZWJWaWV3Mi5Ccm93c2VyRXh0ZW5zaW9uPn0gKi8NCgkJQWRkQnJvd3NlckV4dGVuc2lvbkFzeW5jKGV4dGVuc2lvbkZvbGRlclBhdGgpID0+IChDb21DYWxsKDIyLCB0aGlzLCAnd3N0cicsIGV4dGVuc2lvbkZvbGRlclBhdGgsICdwdHInLCBXZWJWaWV3Mi5Bc3luY0hhbmRsZXIoJnAsIFdlYlZpZXcyLkJyb3dzZXJFeHRlbnNpb24pKSwgcCkNCgkJLyoqIEByZXR1cm5zIHtQcm9taXNlPFdlYlZpZXcyLkJyb3dzZXJFeHRlbnNpb25MaXN0Pn0gKi8NCgkJR2V0QnJvd3NlckV4dGVuc2lvbnNBc3luYygpID0+IChDb21DYWxsKDIzLCB0aGlzLCAncHRyJywgV2ViVmlldzIuQXN5bmNIYW5kbGVyKCZwLCBXZWJWaWV3Mi5Ccm93c2VyRXh0ZW5zaW9uTGlzdCkpLCBwKQ0KDQoJCXN0YXRpYyBJSURfOCA6PSAne2ZiZjcwYzJmLWViMWYtNDM4My04NWEwLTE2M2U5MjA0NDAxMX0nDQoJCURlbGV0ZSgpID0+IENvbUNhbGwoMjQsIHRoaXMpDQoJCS8qKiBAcGFyYW0geyhzZW5kZXI6IFdlYlZpZXcyLlByb2ZpbGUsIGFyZ3M6IElVbmtub3duKSA9PiB2b2lkfSBldmVudEhhbmRsZXIgKi8NCgkJYWRkX0RlbGV0ZWQoZXZlbnRIYW5kbGVyKSA9PiAoQ29tQ2FsbCgyNSwgdGhpcywgJ3B0cicsIGV2ZW50SGFuZGxlciwgJ2ludDY0KicsICZ0b2tlbiA6PSAwKSwgdG9rZW4pDQoJCXJlbW92ZV9EZWxldGVkKHRva2VuKSA9PiBDb21DYWxsKDI2LCB0aGlzLCAnaW50NjQnLCB0b2tlbikNCgl9DQoJY2xhc3MgUHJvY2Vzc0ZhaWxlZEV2ZW50QXJncyBleHRlbmRzIFdlYlZpZXcyLkJhc2Ugew0KCQlzdGF0aWMgSUlEIDo9ICd7ODE1NWE5YTQtMTQ3NC00YTg2LThjYWUtMTUxYjBmYTZiOGNhfScNCgkJUHJvY2Vzc0ZhaWxlZEtpbmQgPT4gKENvbUNhbGwoMywgdGhpcywgJ2ludConLCAmcHJvY2Vzc0ZhaWxlZEtpbmQgOj0gMCksIHByb2Nlc3NGYWlsZWRLaW5kKQk7IENPUkVXRUJWSUVXMl9QUk9DRVNTX0ZBSUxFRF9LSU5EDQoNCgkJc3RhdGljIElJRF8yIDo9ICd7NGRhYjk0MjItNDZmYS00YzNlLWE1ZDItNDFkMjA3MWQzNjgwfScNCgkJUmVhc29uID0+IChDb21DYWxsKDQsIHRoaXMsICdpbnQqJywgJnJlYXNvbiA6PSAwKSwgcmVhc29uKQk7IENPUkVXRUJWSUVXMl9QUk9DRVNTX0ZBSUxFRF9SRUFTT04NCgkJRXhpdENvZGUgPT4gKENvbUNhbGwoNSwgdGhpcywgJ2ludConLCAmZXhpdENvZGUgOj0gMCksIGV4aXRDb2RlKQ0KCQlQcm9jZXNzRGVzY3JpcHRpb24gPT4gKENvbUNhbGwoNiwgdGhpcywgJ3B0cionLCAmcHJvY2Vzc0Rlc2NyaXB0aW9uIDo9IDApLCBDb1Rhc2tNZW1fU3RyaW5nKHByb2Nlc3NEZXNjcmlwdGlvbikpDQoJCUZyYW1lSW5mb3NGb3JGYWlsZWRQcm9jZXNzID0+IChDb21DYWxsKDcsIHRoaXMsICdwdHIqJywgZnJhbWVzIDo9IFdlYlZpZXcyLkZyYW1lSW5mb0NvbGxlY3Rpb24oKSksIGZyYW1lcykNCg0KCQlzdGF0aWMgSUlEXzMgOj0gJ3thYjY2NzQyOC0wOTRkLTVmZDEtYjQ4MC04YjRjMGZkYmRmMmZ9Jw0KCQlGYWlsdXJlU291cmNlTW9kdWxlUGF0aCA9PiAoQ29tQ2FsbCg4LCB0aGlzLCAncHRyKicsICZ2YWx1ZSA6PSAwKSwgQ29UYXNrTWVtX1N0cmluZyh2YWx1ZSkpDQoJfQ0KCWNsYXNzIFJlZ2lvblJlY3RDb2xsZWN0aW9uVmlldyBleHRlbmRzIFdlYlZpZXcyLkxpc3Qgew0KCQlzdGF0aWMgSUlEIDo9ICd7MzMzMzUzQjgtNDhCRi00NDQ5LThGQ0MtMjI2OTdGQUY1NzUzfScNCgkJQ291bnQgPT4gKENvbUNhbGwoMywgdGhpcywgJ3VpbnQqJywgJnZhbHVlIDo9IDApLCB2YWx1ZSkNCgkJR2V0VmFsdWVBdEluZGV4KGluZGV4KSA9PiAoQ29tQ2FsbCg0LCB0aGlzLCAndWludCcsIGluZGV4LCAncHRyJywgdmFsdWUgOj0gV2ViVmlldzIuUkVDVCgpKSwgdmFsdWUpDQoJfQ0KCWNsYXNzIFNhdmVBc1VJU2hvd2luZ0V2ZW50QXJncyBleHRlbmRzIFdlYlZpZXcyLkJhc2Ugew0KCQlzdGF0aWMgSUlEIDo9ICd7NTU5MDI5NTItMGUwZC01YWFhLWE3ZDAtZTgzM2NkYjM0ZjYyfScNCgkJQ29udGVudE1pbWVUeXBlID0+IChDb21DYWxsKDMsIHRoaXMsICdwdHIqJywgJnZhbHVlIDo9IDApLCBDb1Rhc2tNZW1fU3RyaW5nKHZhbHVlKSkNCgkJQ2FuY2VsIHsNCgkJCXNldCA9PiBDb21DYWxsKDQsIHRoaXMsICdpbnQnLCBWYWx1ZSkNCgkJCWdldCA9PiAoQ29tQ2FsbCg1LCB0aGlzLCAnaW50KicsICZ2YWx1ZSA6PSAwKSwgdmFsdWUpDQoJCX0NCgkJU3VwcHJlc3NEZWZhdWx0RGlhbG9nIHsNCgkJCXNldCA9PiBDb21DYWxsKDYsIHRoaXMsICdpbnQnLCBWYWx1ZSkNCgkJCWdldCA9PiAoQ29tQ2FsbCg3LCB0aGlzLCAnaW50KicsICZ2YWx1ZSA6PSAwKSwgdmFsdWUpDQoJCX0NCgkJR2V0RGVmZXJyYWwoKSA9PiAoQ29tQ2FsbCg4LCB0aGlzLCAncHRyKicsIGRlZmVycmFsIDo9IFdlYlZpZXcyLkRlZmVycmFsKCkpLCBkZWZlcnJhbCkNCgkJU2F2ZUFzRmlsZVBhdGggew0KCQkJc2V0ID0+IENvbUNhbGwoOSwgdGhpcywgJ3dzdHInLCBWYWx1ZSkNCgkJCWdldCA9PiAoQ29tQ2FsbCgxMCwgdGhpcywgJ3B0cionLCAmdmFsdWUgOj0gMCksIENvVGFza01lbV9TdHJpbmcodmFsdWUpKQ0KCQl9DQoJCUFsbG93UmVwbGFjZSB7DQoJCQlzZXQgPT4gQ29tQ2FsbCgxMSwgdGhpcywgJ2ludCcsIFZhbHVlKQ0KCQkJZ2V0ID0+IChDb21DYWxsKDEyLCB0aGlzLCAnaW50KicsICZ2YWx1ZSA6PSAwKSwgdmFsdWUpDQoJCX0NCgkJS2luZCB7DQoJCQlzZXQgPT4gQ29tQ2FsbCgxMywgdGhpcywgJ2ludCcsIFZhbHVlKQ0KCQkJZ2V0ID0+IChDb21DYWxsKDE0LCB0aGlzLCAnaW50KicsICZ2YWx1ZSA6PSAwKSwgdmFsdWUpDQoJCX0NCgl9DQoJY2xhc3MgU2F2ZUZpbGVTZWN1cml0eUNoZWNrU3RhcnRpbmdFdmVudEFyZ3MgZXh0ZW5kcyBXZWJWaWV3Mi5CYXNlIHsNCgkJc3RhdGljIElJRCA6PSAne2NmNGZmMWQxLTVhNjctNTY2MC04ZDYzLWVmNjk5ODgxZWE2NX0nDQoJCUNhbmNlbFNhdmUgew0KCQkJZ2V0ID0+IChDb21DYWxsKDMsIHRoaXMsICdpbnQqJywgJnZhbHVlIDo9IDApLCB2YWx1ZSkNCgkJCXNldCA9PiBDb21DYWxsKDQsIHRoaXMsICdpbnQnLCBWYWx1ZSkNCgkJfQ0KCQlEb2N1bWVudE9yaWdpblVyaSA9PiAoQ29tQ2FsbCg1LCB0aGlzLCAncHRyKicsICZ2YWx1ZSA6PSAwKSwgQ29UYXNrTWVtX1N0cmluZyh2YWx1ZSkpDQoJCUZpbGVFeHRlbnNpb24gPT4gKENvbUNhbGwoNiwgdGhpcywgJ3B0cionLCAmdmFsdWUgOj0gMCksIENvVGFza01lbV9TdHJpbmcodmFsdWUpKQ0KCQlGaWxlUGF0aCA9PiAoQ29tQ2FsbCg3LCB0aGlzLCAncHRyKicsICZ2YWx1ZSA6PSAwKSwgQ29UYXNrTWVtX1N0cmluZyh2YWx1ZSkpDQoJCVN1cHByZXNzRGVmYXVsdFBvbGljeSB7DQoJCQlnZXQgPT4gKENvbUNhbGwoOCwgdGhpcywgJ2ludConLCAmdmFsdWUgOj0gMCksIHZhbHVlKQ0KCQkJc2V0ID0+IENvbUNhbGwoOSwgdGhpcywgJ2ludCcsIFZhbHVlKQ0KCQl9DQoJCUdldERlZmVycmFsKCkgPT4gKENvbUNhbGwoMTAsIHRoaXMsICdwdHIqJywgZGVmZXJyYWwgOj0gV2ViVmlldzIuRGVmZXJyYWwoKSksIGRlZmVycmFsKQ0KCX0NCgljbGFzcyBTY3JlZW5DYXB0dXJlU3RhcnRpbmdFdmVudEFyZ3MgZXh0ZW5kcyBXZWJWaWV3Mi5CYXNlIHsNCgkJc3RhdGljIElJRCA6PSAnezg5MmMwM2ZkLWFlZTMtNWViYS1hMWZhLTZmZDJmNjQ4NGIyYn0nDQoJCUNhbmNlbCB7DQoJCQlnZXQgPT4gKENvbUNhbGwoMywgdGhpcywgJ2ludConLCAmdmFsdWUgOj0gMCksIHZhbHVlKQ0KCQkJc2V0ID0+IENvbUNhbGwoNCwgdGhpcywgJ2ludCcsIFZhbHVlKQ0KCQl9DQoJCUhhbmRsZWQgew0KCQkJZ2V0ID0+IChDb21DYWxsKDUsIHRoaXMsICdpbnQqJywgJnZhbHVlIDo9IDApLCB2YWx1ZSkNCgkJCXNldCA9PiBDb21DYWxsKDYsIHRoaXMsICdpbnQnLCBWYWx1ZSkNCgkJfQ0KCQlPcmlnaW5hbFNvdXJjZUZyYW1lSW5mbyA9PiAoQ29tQ2FsbCg3LCB0aGlzLCAncHRyKicsIHZhbHVlIDo9IFdlYlZpZXcyLkZyYW1lSW5mbygpKSwgdmFsdWUpDQoJCUdldERlZmVycmFsKCkgPT4gKENvbUNhbGwoOCwgdGhpcywgJ3B0cionLCB2YWx1ZSA6PSBXZWJWaWV3Mi5EZWZlcnJhbCgpKSwgdmFsdWUpDQoJfQ0KCWNsYXNzIFNjcmlwdERpYWxvZ09wZW5pbmdFdmVudEFyZ3MgZXh0ZW5kcyBXZWJWaWV3Mi5CYXNlIHsNCgkJc3RhdGljIElJRCA6PSAnezczOTBiYjcwLWFiZTAtNDg0My05NTI5LWYxNDNiMzFiMDNkNn0nDQoJCVVyaSA9PiAoQ29tQ2FsbCgzLCB0aGlzLCAncHRyKicsICZ1cmkgOj0gMCksIENvVGFza01lbV9TdHJpbmcodXJpKSkNCgkJS2luZCA9PiAoQ29tQ2FsbCg0LCB0aGlzLCAnaW50KicsICZraW5kIDo9IDApLCBraW5kKQk7IENPUkVXRUJWSUVXMl9TQ1JJUFRfRElBTE9HX0tJTkQNCgkJTWVzc2FnZSA9PiAoQ29tQ2FsbCg1LCB0aGlzLCAncHRyKicsICZtZXNzYWdlIDo9IDApLCBDb1Rhc2tNZW1fU3RyaW5nKG1lc3NhZ2UpKQ0KCQlBY2NlcHQoKSA9PiBDb21DYWxsKDYsIHRoaXMpDQoJCURlZmF1bHRUZXh0ID0+IChDb21DYWxsKDcsIHRoaXMsICdwdHIqJywgJmRlZmF1bHRUZXh0IDo9IDApLCBDb1Rhc2tNZW1fU3RyaW5nKGRlZmF1bHRUZXh0KSkNCgkJUmVzdWx0VGV4dCB7DQoJCQlnZXQgPT4gKENvbUNhbGwoOCwgdGhpcywgJ3B0cionLCAmcmVzdWx0VGV4dCA6PSAwKSwgQ29UYXNrTWVtX1N0cmluZyhyZXN1bHRUZXh0KSkNCgkJCXNldCA9PiBDb21DYWxsKDksIHRoaXMsICd3c3RyJywgVmFsdWUpDQoJCX0NCgkJR2V0RGVmZXJyYWwoKSA9PiAoQ29tQ2FsbCgxMCwgdGhpcywgJ3B0cionLCBkZWZlcnJhbCA6PSBXZWJWaWV3Mi5EZWZlcnJhbCgpKSwgZGVmZXJyYWwpDQoJfQ0KCWNsYXNzIFNjcmlwdEV4Y2VwdGlvbiBleHRlbmRzIFdlYlZpZXcyLkJhc2Ugew0KCQlzdGF0aWMgSUlEIDo9ICd7MDU0REFFMDAtODRBMy00OUZGLUJDMTctNDAxMkE5MEJDOUZEfScNCgkJTGluZU51bWJlciA9PiAoQ29tQ2FsbCgzLCB0aGlzLCAndWludConLCAmdmFsdWUgOj0gMCksIHZhbHVlKQ0KCQlDb2x1bW5OdW1iZXIgPT4gKENvbUNhbGwoNCwgdGhpcywgJ3VpbnQqJywgJnZhbHVlIDo9IDApLCB2YWx1ZSkNCgkJTmFtZSA9PiAoQ29tQ2FsbCg1LCB0aGlzLCAncHRyKicsICZ2YWx1ZSA6PSAwKSwgQ29UYXNrTWVtX1N0cmluZyh2YWx1ZSkpDQoJCU1lc3NhZ2UgPT4gKENvbUNhbGwoNiwgdGhpcywgJ3B0cionLCAmdmFsdWUgOj0gMCksIENvVGFza01lbV9TdHJpbmcodmFsdWUpKQ0KCQlUb0pzb24gPT4gKENvbUNhbGwoNywgdGhpcywgJ3B0cionLCAmdmFsdWUgOj0gMCksIENvVGFza01lbV9TdHJpbmcodmFsdWUpKQ0KCX0NCgljbGFzcyBTZXJ2ZXJDZXJ0aWZpY2F0ZUVycm9yRGV0ZWN0ZWRFdmVudEFyZ3MgZXh0ZW5kcyBXZWJWaWV3Mi5CYXNlIHsNCgkJc3RhdGljIElJRCA6PSAnezAxMjE5M0VELTdDMTMtNDhGRi05NjlELUE4NEMxRjQzMkExNH0nDQoJCUVycm9yU3RhdHVzID0+IChDb21DYWxsKDMsIHRoaXMsICdpbnQqJywgJnZhbHVlIDo9IDApLCB2YWx1ZSkNCgkJUmVxdWVzdFVyaSA9PiAoQ29tQ2FsbCg0LCB0aGlzLCAncHRyKicsICZ2YWx1ZSA6PSAwKSwgQ29UYXNrTWVtX1N0cmluZyh2YWx1ZSkpDQoJCVNlcnZlckNlcnRpZmljYXRlID0+IChDb21DYWxsKDUsIHRoaXMsICdwdHIqJywgdmFsdWUgOj0gV2ViVmlldzIuQ2VydGlmaWNhdGUoKSksIHZhbHVlKQ0KCQlBY3Rpb24gew0KCQkJZ2V0ID0+IChDb21DYWxsKDYsIHRoaXMsICdpbnQqJywgJnZhbHVlIDo9IDApLCB2YWx1ZSkJOyBDT1JFV0VCVklFVzJfU0VSVkVSX0NFUlRJRklDQVRFX0VSUk9SX0FDVElPTg0KCQkJc2V0ID0+IENvbUNhbGwoNywgdGhpcywgJ2ludCcsIFZhbHVlKQ0KCQl9DQoJCUdldERlZmVycmFsKCkgPT4gKENvbUNhbGwoOCwgdGhpcywgJ3B0cionLCBkZWZlcnJhbCA6PSBXZWJWaWV3Mi5EZWZlcnJhbCgpKSwgZGVmZXJyYWwpDQoJfQ0KCWNsYXNzIFNldHRpbmdzIGV4dGVuZHMgV2ViVmlldzIuQmFzZSB7DQoJCXN0YXRpYyBJSUQgOj0gJ3tlNTYyZTRmMC1kN2ZhLTQzYWMtOGQ3MS1jMDUxNTA0OTlmMDB9Jw0KCQlJc1NjcmlwdEVuYWJsZWQgew0KCQkJZ2V0ID0+IChDb21DYWxsKDMsIHRoaXMsICdpbnQqJywgJmlzU2NyaXB0RW5hYmxlZCA6PSAwKSwgaXNTY3JpcHRFbmFibGVkKQ0KCQkJc2V0ID0+IENvbUNhbGwoNCwgdGhpcywgJ2ludCcsIFZhbHVlKQ0KCQl9DQoJCUlzV2ViTWVzc2FnZUVuYWJsZWQgew0KCQkJZ2V0ID0+IChDb21DYWxsKDUsIHRoaXMsICdpbnQqJywgJmlzV2ViTWVzc2FnZUVuYWJsZWQgOj0gMCksIGlzV2ViTWVzc2FnZUVuYWJsZWQpDQoJCQlzZXQgPT4gQ29tQ2FsbCg2LCB0aGlzLCAnaW50JywgVmFsdWUpDQoJCX0NCgkJQXJlRGVmYXVsdFNjcmlwdERpYWxvZ3NFbmFibGVkIHsNCgkJCWdldCA9PiAoQ29tQ2FsbCg3LCB0aGlzLCAnaW50KicsICZhcmVEZWZhdWx0U2NyaXB0RGlhbG9nc0VuYWJsZWQgOj0gMCksIGFyZURlZmF1bHRTY3JpcHREaWFsb2dzRW5hYmxlZCkNCgkJCXNldCA9PiBDb21DYWxsKDgsIHRoaXMsICdpbnQnLCBWYWx1ZSkNCgkJfQ0KCQlJc1N0YXR1c0JhckVuYWJsZWQgew0KCQkJZ2V0ID0+IChDb21DYWxsKDksIHRoaXMsICdpbnQqJywgJmlzU3RhdHVzQmFyRW5hYmxlZCA6PSAwKSwgaXNTdGF0dXNCYXJFbmFibGVkKQ0KCQkJc2V0ID0+IENvbUNhbGwoMTAsIHRoaXMsICdpbnQnLCBWYWx1ZSkNCgkJfQ0KCQlBcmVEZXZUb29sc0VuYWJsZWQgew0KCQkJZ2V0ID0+IChDb21DYWxsKDExLCB0aGlzLCAnaW50KicsICZhcmVEZXZUb29sc0VuYWJsZWQgOj0gMCksIGFyZURldlRvb2xzRW5hYmxlZCkNCgkJCXNldCA9PiBDb21DYWxsKDEyLCB0aGlzLCAnaW50JywgVmFsdWUpDQoJCX0NCgkJQXJlRGVmYXVsdENvbnRleHRNZW51c0VuYWJsZWQgew0KCQkJZ2V0ID0+IChDb21DYWxsKDEzLCB0aGlzLCAnaW50KicsICZlbmFibGVkIDo9IDApLCBlbmFibGVkKQ0KCQkJc2V0ID0+IENvbUNhbGwoMTQsIHRoaXMsICdpbnQnLCBWYWx1ZSkNCgkJfQ0KCQlBcmVIb3N0T2JqZWN0c0FsbG93ZWQgew0KCQkJZ2V0ID0+IChDb21DYWxsKDE1LCB0aGlzLCAnaW50KicsICZhbGxvd2VkIDo9IDApLCBhbGxvd2VkKQ0KCQkJc2V0ID0+IENvbUNhbGwoMTYsIHRoaXMsICdpbnQnLCBWYWx1ZSkNCgkJfQ0KCQlJc1pvb21Db250cm9sRW5hYmxlZCB7DQoJCQlnZXQgPT4gKENvbUNhbGwoMTcsIHRoaXMsICdpbnQqJywgJmVuYWJsZWQgOj0gMCksIGVuYWJsZWQpDQoJCQlzZXQgPT4gQ29tQ2FsbCgxOCwgdGhpcywgJ2ludCcsIFZhbHVlKQ0KCQl9DQoJCUlzQnVpbHRJbkVycm9yUGFnZUVuYWJsZWQgew0KCQkJZ2V0ID0+IChDb21DYWxsKDE5LCB0aGlzLCAnaW50KicsICZlbmFibGVkIDo9IDApLCBlbmFibGVkKQ0KCQkJc2V0ID0+IENvbUNhbGwoMjAsIHRoaXMsICdpbnQnLCBWYWx1ZSkNCgkJfQ0KDQoJCXN0YXRpYyBJSURfMiA6PSAne2VlOWEwZjY4LWY0NmMtNGUzMi1hYzIzLWVmOGNhYzIyNGQyYX0nDQoJCVVzZXJBZ2VudCB7DQoJCQlnZXQgPT4gKENvbUNhbGwoMjEsIHRoaXMsICdwdHIqJywgJnVzZXJBZ2VudCA6PSAwKSwgQ29UYXNrTWVtX1N0cmluZyh1c2VyQWdlbnQpKQ0KCQkJc2V0ID0+IENvbUNhbGwoMjIsIHRoaXMsICd3c3RyJywgVmFsdWUpDQoJCX0NCg0KCQlzdGF0aWMgSUlEXzMgOj0gJ3tmZGI1YWI3NC1hZjMzLTQ4NTQtODRmMC0wYTYzMWRlYjVlYmF9Jw0KCQlBcmVCcm93c2VyQWNjZWxlcmF0b3JLZXlzRW5hYmxlZCB7DQoJCQlnZXQgPT4gKENvbUNhbGwoMjMsIHRoaXMsICdpbnQqJywgJmFyZUJyb3dzZXJBY2NlbGVyYXRvcktleXNFbmFibGVkIDo9IDApLCBhcmVCcm93c2VyQWNjZWxlcmF0b3JLZXlzRW5hYmxlZCkNCgkJCXNldCA9PiBDb21DYWxsKDI0LCB0aGlzLCAnaW50JywgVmFsdWUpDQoJCX0NCg0KCQlzdGF0aWMgSUlEXzQgOj0gJ3tjYjU2ODQ2Yy00MTY4LTRkNTMtYjA0Zi0wM2I2ZDY3OTZmZjJ9Jw0KCQlJc1Bhc3N3b3JkQXV0b3NhdmVFbmFibGVkIHsNCgkJCWdldCA9PiAoQ29tQ2FsbCgyNSwgdGhpcywgJ2ludConLCAmdmFsdWUgOj0gMCksIHZhbHVlKQ0KCQkJc2V0ID0+IENvbUNhbGwoMjYsIHRoaXMsICdpbnQnLCBWYWx1ZSkNCgkJfQ0KCQlJc0dlbmVyYWxBdXRvZmlsbEVuYWJsZWQgew0KCQkJZ2V0ID0+IChDb21DYWxsKDI3LCB0aGlzLCAnaW50KicsICZ2YWx1ZSA6PSAwKSwgdmFsdWUpDQoJCQlzZXQgPT4gQ29tQ2FsbCgyOCwgdGhpcywgJ2ludCcsIFZhbHVlKQ0KCQl9DQoNCgkJc3RhdGljIElJRF81IDo9ICd7MTgzZTcwNTItMWQwMy00M2EwLWFiOTktOThlMDQzYjY2YjM5fScNCgkJSXNQaW5jaFpvb21FbmFibGVkIHsNCgkJCWdldCA9PiAoQ29tQ2FsbCgyOSwgdGhpcywgJ2ludConLCAmZW5hYmxlZCA6PSAwKSwgZW5hYmxlZCkNCgkJCXNldCA9PiBDb21DYWxsKDMwLCB0aGlzLCAnaW50JywgVmFsdWUpDQoJCX0NCg0KCQlzdGF0aWMgSUlEXzYgOj0gJ3sxMWNiM2FjZC05YmM4LTQzYjgtODNiZi1mNDA3NTM3MTRmODd9Jw0KCQlJc1N3aXBlTmF2aWdhdGlvbkVuYWJsZWQgew0KCQkJZ2V0ID0+IChDb21DYWxsKDMxLCB0aGlzLCAnaW50KicsICZlbmFibGVkIDo9IDApLCBlbmFibGVkKQ0KCQkJc2V0ID0+IENvbUNhbGwoMzIsIHRoaXMsICdpbnQnLCBWYWx1ZSkNCgkJfQ0KDQoJCXN0YXRpYyBJSURfNyA6PSAnezQ4OGRjOTAyLTM1ZWYtNDJkMi1iYzdkLTk0YjY1YzRiYzQ5Y30nDQoJCUhpZGRlblBkZlRvb2xiYXJJdGVtcyB7DQoJCQlnZXQgPT4gKENvbUNhbGwoMzMsIHRoaXMsICdpbnQqJywgJmhpZGRlbl9wZGZfdG9vbGJhcl9pdGVtcyA6PSAwKSwgaGlkZGVuX3BkZl90b29sYmFyX2l0ZW1zKQk7IENPUkVXRUJWSUVXMl9QREZfVE9PTEJBUl9JVEVNUw0KCQkJc2V0ID0+IENvbUNhbGwoMzQsIHRoaXMsICdpbnQnLCBWYWx1ZSkNCgkJfQ0KDQoJCXN0YXRpYyBJSURfOCA6PSAnezllNmIwZThmLTg2YWQtNGU4MS04MTQ3LWE5YjVlZGI2ODY1MH0nDQoJCUlzUmVwdXRhdGlvbkNoZWNraW5nUmVxdWlyZWQgew0KCQkJZ2V0ID0+IChDb21DYWxsKDM1LCB0aGlzLCAnaW50KicsICZ2YWx1ZSA6PSAwKSwgdmFsdWUpDQoJCQlzZXQgPT4gQ29tQ2FsbCgzNiwgdGhpcywgJ2ludCcsIFZhbHVlKQ0KCQl9DQoNCgkJc3RhdGljIElJRF85IDo9ICd7MDUyOEE3M0ItRTkyRC00OUY0LTkyN0EtRTU0N0REREFBMzdEfScNCgkJSXNOb25DbGllbnRSZWdpb25TdXBwb3J0RW5hYmxlZCB7DQoJCQlnZXQgPT4gKENvbUNhbGwoMzcsIHRoaXMsICdpbnQqJywgJmVuYWJsZWQgOj0gMCksIGVuYWJsZWQpDQoJCQlzZXQgPT4gQ29tQ2FsbCgzOCwgdGhpcywgJ2ludCcsIFZhbHVlKQ0KCQl9DQoNCgl9DQoJY2xhc3MgU2hhcmVkQnVmZmVyIGV4dGVuZHMgV2ViVmlldzIuQmFzZSB7DQoJCXN0YXRpYyBJSUQgOj0gJ3tCNzQ3QTQ5NS0wQzZGLTQ0OUUtOTdCOC0yRjgxRTlENkFCNDN9Jw0KCQlTaXplID0+IChDb21DYWxsKDMsIHRoaXMsICd1aW50NjQnLCAmdmFsdWUgOj0gMCksIHZhbHVlKQ0KCQlCdWZmZXIgPT4gKENvbUNhbGwoNCwgdGhpcywgJ3B0cionLCAmdmFsdWUgOj0gMCksIHZhbHVlKQ0KCQlPcGVuU3RyZWFtKCkgPT4gKENvbUNhbGwoNSwgdGhpcywgJ3B0cionLCB2YWx1ZSA6PSBXZWJWaWV3Mi5TdHJlYW0oKSksIHZhbHVlKQ0KCQlGaWxlTWFwcGluZ0hhbmRsZSA9PiAoQ29tQ2FsbCg2LCB0aGlzLCAncHRyKicsICZ2YWx1ZSA6PSAwKSwgdmFsdWUpDQoJCUNsb3NlKCkgPT4gQ29tQ2FsbCg3LCB0aGlzKQ0KCX0NCgljbGFzcyBTb3VyY2VDaGFuZ2VkRXZlbnRBcmdzIGV4dGVuZHMgV2ViVmlldzIuQmFzZSB7DQoJCXN0YXRpYyBJSUQgOj0gJ3szMWUwZTU0NS0xZGJhLTQyNjYtODkxNC1mNjM4NDhhMWY3ZDd9Jw0KCQlJc05ld0RvY3VtZW50ID0+IChDb21DYWxsKDMsIHRoaXMsICdpbnQqJywgJmlzTmV3RG9jdW1lbnQgOj0gMCksIGlzTmV3RG9jdW1lbnQpDQoJfQ0KCWNsYXNzIFN0cmVhbSBleHRlbmRzIFdlYlZpZXcyLkJhc2Ugew0KCQlUb0J1ZmZlcigpIHsNCgkJCURsbENhbGwoJ3NobHdhcGlcSVN0cmVhbV9SZXNldCcsICdwdHInLCB0aGlzKQ0KCQkJRGxsQ2FsbCgnc2hsd2FwaVxJU3RyZWFtX1NpemUnLCAncHRyJywgdGhpcywgJ3VpbnQ2NConLCAmc3ogOj0gMCkNCgkJCURsbENhbGwoJ3NobHdhcGlcSVN0cmVhbV9SZWFkJywgJ3B0cicsIHRoaXMsICdwdHInLCBidWYgOj0gQnVmZmVyKHN6KSwgJ3VpbnQnLCBzeikNCgkJCXJldHVybiBidWYNCgkJfQ0KCQlUb1N0cmluZyhlbmNvZGluZyA6PSAndXRmLTgnKSA9PiBTdHJHZXQodGhpcy5Ub0J1ZmZlcigpLCBlbmNvZGluZykNCgl9DQoJY2xhc3MgU3RyaW5nQ29sbGVjdGlvbiBleHRlbmRzIFdlYlZpZXcyLkxpc3Qgew0KCQlzdGF0aWMgSUlEIDo9ICd7ZjQxZjNmOGEtYmNjMy0xMWViLTg1MjktMDI0MmFjMTMwMDAzfScNCgkJQ291bnQgPT4gKENvbUNhbGwoMywgdGhpcywgJ3VpbnQqJywgJnZhbHVlIDo9IDApLCB2YWx1ZSkNCgkJR2V0VmFsdWVBdEluZGV4KGluZGV4KSA9PiAoQ29tQ2FsbCg0LCB0aGlzLCAndWludCcsIGluZGV4LCAncHRyKicsICZ2YWx1ZSA6PSAwKSwgQ29UYXNrTWVtX1N0cmluZyh2YWx1ZSkpDQoJfQ0KCWNsYXNzIFdlYk1lc3NhZ2VSZWNlaXZlZEV2ZW50QXJncyBleHRlbmRzIFdlYlZpZXcyLkJhc2Ugew0KCQlzdGF0aWMgSUlEIDo9ICd7MGY5OWE0MGMtZTk2Mi00MjA3LTllOTItZTNkNTQyZWZmODQ5fScNCgkJU291cmNlID0+IChDb21DYWxsKDMsIHRoaXMsICdwdHIqJywgJnNvdXJjZSA6PSAwKSwgQ29UYXNrTWVtX1N0cmluZyhzb3VyY2UpKQ0KCQlXZWJNZXNzYWdlQXNKc29uID0+IChDb21DYWxsKDQsIHRoaXMsICdwdHIqJywgJndlYk1lc3NhZ2VBc0pzb24gOj0gMCksIENvVGFza01lbV9TdHJpbmcod2ViTWVzc2FnZUFzSnNvbikpDQoJCVRyeUdldFdlYk1lc3NhZ2VBc1N0cmluZygpID0+IChDb21DYWxsKDUsIHRoaXMsICdwdHIqJywgJndlYk1lc3NhZ2VBc1N0cmluZyA6PSAwKSwgQ29UYXNrTWVtX1N0cmluZyh3ZWJNZXNzYWdlQXNTdHJpbmcpKQ0KDQoJCXN0YXRpYyBJSURfMiA6PSAnezA2ZmM3YWI3LWM5MGMtNDI5Ny05Mzg5LTMzY2EwMWNmNmQ1ZX0nDQoJCUFkZGl0aW9uYWxPYmplY3RzID0+IChDb21DYWxsKDYsIHRoaXMsICdwdHIqJywgdmFsdWUgOj0gV2ViVmlldzIuT2JqZWN0Q29sbGVjdGlvblZpZXcoKSksIHZhbHVlKQ0KCX0NCgljbGFzcyBXZWJSZXNvdXJjZVJlcXVlc3QgZXh0ZW5kcyBXZWJWaWV3Mi5CYXNlIHsNCgkJc3RhdGljIElJRCA6PSAnezk3MDU1Y2Q0LTUxMmMtNDI2NC04YjVmLWUzZjQ0NmNlYTZhNX0nDQoJCVVyaSB7DQoJCQlnZXQgPT4gKENvbUNhbGwoMywgdGhpcywgJ3B0cionLCAmdXJpIDo9IDApLCBDb1Rhc2tNZW1fU3RyaW5nKHVyaSkpDQoJCQlzZXQgPT4gQ29tQ2FsbCg0LCB0aGlzLCAnd3N0cicsIFZhbHVlKQ0KCQl9DQoJCU1ldGhvZCB7DQoJCQlnZXQgPT4gKENvbUNhbGwoNSwgdGhpcywgJ3B0cionLCAmbWV0aG9kIDo9IDApLCBDb1Rhc2tNZW1fU3RyaW5nKG1ldGhvZCkpDQoJCQlzZXQgPT4gQ29tQ2FsbCg2LCB0aGlzLCAnd3N0cicsIFZhbHVlKQ0KCQl9DQoJCUNvbnRlbnQgew0KCQkJZ2V0ID0+IChDb21DYWxsKDcsIHRoaXMsICdwdHIqJywgY29udGVudCA6PSBXZWJWaWV3Mi5TdHJlYW0oKSksIGNvbnRlbnQpDQoJCQlzZXQgPT4gQ29tQ2FsbCg4LCB0aGlzLCAncHRyJywgVmFsdWUpDQoJCX0NCgkJSGVhZGVycyA9PiAoQ29tQ2FsbCg5LCB0aGlzLCAncHRyKicsIGhlYWRlcnMgOj0gV2ViVmlldzIuSHR0cFJlcXVlc3RIZWFkZXJzKCkpLCBoZWFkZXJzKQ0KCX0NCgljbGFzcyBXZWJSZXNvdXJjZVJlcXVlc3RlZEV2ZW50QXJncyBleHRlbmRzIFdlYlZpZXcyLkJhc2Ugew0KCQlzdGF0aWMgSUlEIDo9ICd7NDUzZTY2N2YtMTJjNy00OWQ0LWJlNmQtZGRiZTc5NTZmNTdhfScNCgkJUmVxdWVzdCA9PiAoQ29tQ2FsbCgzLCB0aGlzLCAncHRyKicsIHJlcXVlc3QgOj0gV2ViVmlldzIuV2ViUmVzb3VyY2VSZXF1ZXN0KCkpLCByZXF1ZXN0KQ0KCQlSZXNwb25zZSB7DQoJCQlnZXQgPT4gKENvbUNhbGwoNCwgdGhpcywgJ3B0cionLCByZXNwb25zZSA6PSBXZWJWaWV3Mi5XZWJSZXNvdXJjZVJlc3BvbnNlKCkpLCByZXNwb25zZSkNCgkJCXNldCA9PiBDb21DYWxsKDUsIHRoaXMsICdwdHInLCBWYWx1ZSkNCgkJfQ0KCQlHZXREZWZlcnJhbCgpID0+IChDb21DYWxsKDYsIHRoaXMsICdwdHIqJywgZGVmZXJyYWwgOj0gV2ViVmlldzIuRGVmZXJyYWwoKSksIGRlZmVycmFsKQ0KCQlSZXNvdXJjZUNvbnRleHQgPT4gKENvbUNhbGwoNywgdGhpcywgJ2ludConLCAmY29udGV4dCA6PSAwKSwgY29udGV4dCkJOyBDT1JFV0VCVklFVzJfV0VCX1JFU09VUkNFX0NPTlRFWFQNCg0KCQlzdGF0aWMgSUlEXzIgOj0gJ3s5QzU2MkMyNC1CMjE5LTREN0YtOTJGNi1CMTg3RkJCQURENTZ9Jw0KCQlSZXF1ZXN0ZWRTb3VyY2VLaW5kID0+IChDb21DYWxsKDgsIHRoaXMsICdpbnQqJywgJnJlcXVlc3RlZFNvdXJjZUtpbmQgOj0gMCksIHJlcXVlc3RlZFNvdXJjZUtpbmQpCTsgQ09SRVdFQlZJRVcyX1dFQl9SRVNPVVJDRV9SRVFVRVNUX1NPVVJDRV9LSU5EUw0KCX0NCgljbGFzcyBXZWJSZXNvdXJjZVJlc3BvbnNlIGV4dGVuZHMgV2ViVmlldzIuQmFzZSB7DQoJCXN0YXRpYyBJSUQgOj0gJ3thYWZjYzk0Zi1mYTI3LTQ4ZmQtOTdkZi04MzBlZjc1YWFlYzl9Jw0KCQlDb250ZW50IHsNCgkJCWdldCA9PiAoQ29tQ2FsbCgzLCB0aGlzLCAncHRyKicsIGNvbnRlbnQgOj0gV2ViVmlldzIuU3RyZWFtKCkpLCBjb250ZW50KQ0KCQkJc2V0ID0+IENvbUNhbGwoNCwgdGhpcywgJ3B0cicsIFZhbHVlKQ0KCQl9DQoJCUhlYWRlcnMgPT4gKENvbUNhbGwoNSwgdGhpcywgJ3B0cionLCBoZWFkZXJzIDo9IFdlYlZpZXcyLkh0dHBSZXNwb25zZUhlYWRlcnMoKSksIGhlYWRlcnMpDQoJCVN0YXR1c0NvZGUgew0KCQkJZ2V0ID0+IChDb21DYWxsKDYsIHRoaXMsICdpbnQqJywgJnN0YXR1c0NvZGUgOj0gMCksIHN0YXR1c0NvZGUpDQoJCQlzZXQgPT4gQ29tQ2FsbCg3LCB0aGlzLCAnaW50JywgVmFsdWUpDQoJCX0NCgkJUmVhc29uUGhyYXNlIHsNCgkJCWdldCA9PiAoQ29tQ2FsbCg4LCB0aGlzLCAncHRyKicsICZyZWFzb25QaHJhc2UgOj0gMCksIENvVGFza01lbV9TdHJpbmcocmVhc29uUGhyYXNlKSkNCgkJCXNldCA9PiBDb21DYWxsKDksIHRoaXMsICd3c3RyJywgVmFsdWUpDQoJCX0NCgl9DQoJY2xhc3MgV2ViUmVzb3VyY2VSZXNwb25zZVJlY2VpdmVkRXZlbnRBcmdzIGV4dGVuZHMgV2ViVmlldzIuQmFzZSB7DQoJCXN0YXRpYyBJSUQgOj0gJ3tEMURCNDgzRC02Nzk2LTRCOEItODBGQy0xMzcxMkJCNzE2RjR9Jw0KCQlSZXF1ZXN0ID0+IChDb21DYWxsKDMsIHRoaXMsICdwdHIqJywgcmVxdWVzdCA6PSBXZWJWaWV3Mi5XZWJSZXNvdXJjZVJlcXVlc3QoKSksIHJlcXVlc3QpDQoJCVJlc3BvbnNlID0+IChDb21DYWxsKDQsIHRoaXMsICdwdHIqJywgcmVzcG9uc2UgOj0gV2ViVmlldzIuV2ViUmVzb3VyY2VSZXNwb25zZVZpZXcoKSksIHJlc3BvbnNlKQ0KCX0NCgljbGFzcyBXZWJSZXNvdXJjZVJlc3BvbnNlVmlldyBleHRlbmRzIFdlYlZpZXcyLkJhc2Ugew0KCQlzdGF0aWMgSUlEIDo9ICd7Nzk3MDEwNTMtNzc1OS00MTYyLThGN0QtRjFCM0YwODQ5MjhEfScNCgkJSGVhZGVycyA9PiAoQ29tQ2FsbCgzLCB0aGlzLCAncHRyKicsIGhlYWRlcnMgOj0gV2ViVmlldzIuSHR0cFJlc3BvbnNlSGVhZGVycygpKSwgaGVhZGVycykNCgkJU3RhdHVzQ29kZSA9PiAoQ29tQ2FsbCg0LCB0aGlzLCAnaW50KicsICZzdGF0dXNDb2RlIDo9IDApLCBzdGF0dXNDb2RlKQ0KCQlSZWFzb25QaHJhc2UgPT4gKENvbUNhbGwoNSwgdGhpcywgJ3B0cionLCAmcmVhc29uUGhyYXNlIDo9IDApLCBDb1Rhc2tNZW1fU3RyaW5nKHJlYXNvblBocmFzZSkpDQoJCS8qKiBAcmV0dXJucyB7UHJvbWlzZTxXZWJWaWV3Mi5TdHJlYW0+fSAqLw0KCQlHZXRDb250ZW50QXN5bmMoKSA9PiAoQ29tQ2FsbCg2LCB0aGlzLCAncHRyJywgV2ViVmlldzIuQXN5bmNIYW5kbGVyKCZwLCBXZWJWaWV3Mi5TdHJlYW0pKSwgcCkNCgl9DQoJY2xhc3MgV2luZG93RmVhdHVyZXMgZXh0ZW5kcyBXZWJWaWV3Mi5CYXNlIHsNCgkJc3RhdGljIElJRCA6PSAnezVlYWY1NTlmLWI0NmUtNDM5Ny04ODYwLWU0MjJmMjg3ZmYxZX0nDQoJCUhhc1Bvc2l0aW9uID0+IChDb21DYWxsKDMsIHRoaXMsICdpbnQqJywgJnZhbHVlIDo9IDApLCB2YWx1ZSkNCgkJSGFzU2l6ZSA9PiAoQ29tQ2FsbCg0LCB0aGlzLCAnaW50KicsICZ2YWx1ZSA6PSAwKSwgdmFsdWUpDQoJCUxlZnQgPT4gKENvbUNhbGwoNSwgdGhpcywgJ3VpbnQqJywgJnZhbHVlIDo9IDApLCB2YWx1ZSkNCgkJVG9wID0+IChDb21DYWxsKDYsIHRoaXMsICd1aW50KicsICZ2YWx1ZSA6PSAwKSwgdmFsdWUpDQoJCUhlaWdodCA9PiAoQ29tQ2FsbCg3LCB0aGlzLCAndWludConLCAmdmFsdWUgOj0gMCksIHZhbHVlKQ0KCQlXaWR0aCA9PiAoQ29tQ2FsbCg4LCB0aGlzLCAndWludConLCAmdmFsdWUgOj0gMCksIHZhbHVlKQ0KCQlTaG91bGREaXNwbGF5TWVudUJhciA9PiAoQ29tQ2FsbCg5LCB0aGlzLCAnaW50KicsICZ2YWx1ZSA6PSAwKSwgdmFsdWUpDQoJCVNob3VsZERpc3BsYXlTdGF0dXMgPT4gKENvbUNhbGwoMTAsIHRoaXMsICdpbnQqJywgJnZhbHVlIDo9IDApLCB2YWx1ZSkNCgkJU2hvdWxkRGlzcGxheVRvb2xiYXIgPT4gKENvbUNhbGwoMTEsIHRoaXMsICdpbnQqJywgJnZhbHVlIDo9IDApLCB2YWx1ZSkNCgkJU2hvdWxkRGlzcGxheVNjcm9sbEJhcnMgPT4gKENvbUNhbGwoMTIsIHRoaXMsICdpbnQqJywgJnZhbHVlIDo9IDApLCB2YWx1ZSkNCgl9DQoJOyNlbmRyZWdpb24NCg0KCTsjcmVnaW9uIHN0cnVjdHMNCgljbGFzcyBQSFlTSUNBTF9LRVlfU1RBVFVTIGV4dGVuZHMgQnVmZmVyIHsNCgkJX19OZXcoKSA9PiBzdXBlci5fX05ldygyNCkNCgkJUmVwZWF0Q291bnQgew0KCQkJZ2V0ID0+IE51bUdldCh0aGlzLCAndWludCcpDQoJCQlzZXQgPT4gTnVtUHV0KCd1aW50JywgVmFsdWUsIHRoaXMpDQoJCX0NCgkJU2NhbkNvZGUgew0KCQkJZ2V0ID0+IE51bUdldCh0aGlzLCA0LCAndWludCcpDQoJCQlzZXQgPT4gTnVtUHV0KCd1aW50JywgVmFsdWUsIHRoaXMsIDQpDQoJCX0NCgkJSXNFeHRlbmRlZEtleSB7DQoJCQlnZXQgPT4gTnVtR2V0KHRoaXMsIDgsICdpbnQnKQ0KCQkJc2V0ID0+IE51bVB1dCgnaW50JywgVmFsdWUsIHRoaXMsIDgpDQoJCX0NCgkJSXNNZW51S2V5RG93biB7DQoJCQlnZXQgPT4gTnVtR2V0KHRoaXMsIDEyLCAnaW50JykNCgkJCXNldCA9PiBOdW1QdXQoJ2ludCcsIFZhbHVlLCB0aGlzLCAxMikNCgkJfQ0KCQlXYXNLZXlEb3duIHsNCgkJCWdldCA9PiBOdW1HZXQodGhpcywgMTYsICdpbnQnKQ0KCQkJc2V0ID0+IE51bVB1dCgnaW50JywgVmFsdWUsIHRoaXMsIDE2KQ0KCQl9DQoJCUlzS2V5UmVsZWFzZWQgew0KCQkJZ2V0ID0+IE51bUdldCh0aGlzLCAyMCwgJ2ludCcpDQoJCQlzZXQgPT4gTnVtUHV0KCdpbnQnLCBWYWx1ZSwgdGhpcywgMjApDQoJCX0NCgl9DQoJY2xhc3MgUkVDVCBleHRlbmRzIEJ1ZmZlciB7DQoJCV9fTmV3KCkgPT4gc3VwZXIuX19OZXcoMTYpDQoJCWxlZnQgew0KCQkJZ2V0ID0+IE51bUdldCh0aGlzLCAnaW50JykNCgkJCXNldCA9PiBOdW1QdXQoJ2ludCcsIFZhbHVlLCB0aGlzKQ0KCQl9DQoJCXRvcCB7DQoJCQlnZXQgPT4gTnVtR2V0KHRoaXMsIDQsICdpbnQnKQ0KCQkJc2V0ID0+IE51bVB1dCgnaW50JywgVmFsdWUsIHRoaXMsIDQpDQoJCX0NCgkJcmlnaHQgew0KCQkJZ2V0ID0+IE51bUdldCh0aGlzLCA4LCAnaW50JykNCgkJCXNldCA9PiBOdW1QdXQoJ2ludCcsIFZhbHVlLCB0aGlzLCA4KQ0KCQl9DQoJCWJvdHRvbSB7DQoJCQlnZXQgPT4gTnVtR2V0KHRoaXMsIDEyLCAnaW50JykNCgkJCXNldCA9PiBOdW1QdXQoJ2ludCcsIFZhbHVlLCB0aGlzLCAxMikNCgkJfQ0KCX0NCgk7I2VuZHJlZ2lvbg0KDQoJOyNyZWdpb24gY29uc3RhbnRzDQoJc3RhdGljIEJPVU5EU19NT0RFIDo9IHsgVVNFX1JBV19QSVhFTFM6IDAsIFVTRV9SQVNURVJJWkFUSU9OX1NDQUxFOiAxIH0NCglzdGF0aWMgQlJPV1NFUl9QUk9DRVNTX0VYSVRfS0lORCA6PSB7IE5PUk1BTDogMCwgRkFJTEVEOiAxIH0NCglzdGF0aWMgQlJPV1NJTkdfREFUQV9LSU5EUyA6PSB7IEZJTEVfU1lTVEVNUzogKDEgPDwgMCksIElOREVYRURfREI6ICgxIDw8IDEpLCBMT0NBTF9TVE9SQUdFOiAoMSA8PCAyKSwgV0VCX1NRTDogKDEgPDwgMyksIENBQ0hFX1NUT1JBR0U6ICgxIDw8IDQpLCBBTExfRE9NX1NUT1JBR0U6ICgxIDw8IDUpLCBDT09LSUVTOiAoMSA8PCA2KSwgQUxMX1NJVEU6ICgxIDw8IDcpLCBESVNLX0NBQ0hFOiAoMSA8PCA4KSwgRE9XTkxPQURfSElTVE9SWTogKDEgPDwgOSksIEdFTkVSQUxfQVVUT0ZJTEw6ICgxIDw8IDEwKSwgUEFTU1dPUkRfQVVUT1NBVkU6ICgxIDw8IDExKSwgQlJPV1NJTkdfSElTVE9SWTogKDEgPDwgMTIpLCBTRVRUSU5HUzogKDEgPDwgMTMpLCBBTExfUFJPRklMRTogKDEgPDwgMTQpLCBTRVJWSUNFX1dPUktFUlM6ICgxIDw8IDE1KSB9DQoJc3RhdGljIENBUFRVUkVfUFJFVklFV19JTUFHRV9GT1JNQVQgOj0geyBQTkc6IDAsIEpQRUc6IDEgfQ0KCXN0YXRpYyBDSEFOTkVMX1NFQVJDSF9LSU5EIDo9IHsgTU9TVF9TVEFCTEU6IDAsIExFQVNUX1NUQUJMRTogMSB9DQoJc3RhdGljIENMSUVOVF9DRVJUSUZJQ0FURV9LSU5EIDo9IHsgU01BUlRfQ0FSRDogMCwgUElOOiAxLCBPVEhFUjogMiB9DQoJc3RhdGljIENPTlRFWFRfTUVOVV9JVEVNX0tJTkQgOj0geyBDT01NQU5EOiAwLCBDSEVDS19CT1g6IDEsIFJBRElPOiAyLCBTRVBBUkFUT1I6IDMsIFNVQk1FTlU6IDQgfQ0KCXN0YXRpYyBDT05URVhUX01FTlVfVEFSR0VUX0tJTkQgOj0geyBQQUdFOiAwLCBJTUFHRTogMSwgU0VMRUNURURfVEVYVDogMiwgQVVESU86IDMsIFZJREVPOiA0IH0NCglzdGF0aWMgQ09PS0lFX1NBTUVfU0lURV9LSU5EIDo9IHsgTk9ORTogMCwgTEFYOiAxLCBTVFJJQ1Q6IDIgfQ0KCXN0YXRpYyBERUZBVUxUX0RPV05MT0FEX0RJQUxPR19DT1JORVJfQUxJR05NRU5UIDo9IHsgVE9QX0xFRlQ6IDAsIFRPUF9SSUdIVDogMSwgQk9UVE9NX0xFRlQ6IDIsIEJPVFRPTV9SSUdIVDogMyB9DQoJc3RhdGljIERPV05MT0FEX0lOVEVSUlVQVF9SRUFTT04gOj0geyBOT05FOiAwLCBGSUxFX0ZBSUxFRDogMSwgRklMRV9BQ0NFU1NfREVOSUVEOiAyLCBGSUxFX05PX1NQQUNFOiAzLCBGSUxFX05BTUVfVE9PX0xPTkc6IDQsIEZJTEVfVE9PX0xBUkdFOiA1LCBGSUxFX01BTElDSU9VUzogNiwgRklMRV9UUkFOU0lFTlRfRVJST1I6IDcsIEZJTEVfQkxPQ0tFRF9CWV9QT0xJQ1k6IDgsIEZJTEVfU0VDVVJJVFlfQ0hFQ0tfRkFJTEVEOiA5LCBGSUxFX1RPT19TSE9SVDogMTAsIEZJTEVfSEFTSF9NSVNNQVRDSDogMTEsIE5FVFdPUktfRkFJTEVEOiAxMiwgTkVUV09SS19USU1FT1VUOiAxMywgTkVUV09SS19ESVNDT05ORUNURUQ6IDE0LCBORVRXT1JLX1NFUlZFUl9ET1dOOiAxNSwgTkVUV09SS19JTlZBTElEX1JFUVVFU1Q6IDE2LCBTRVJWRVJfRkFJTEVEOiAxNywgU0VSVkVSX05PX1JBTkdFOiAxOCwgU0VSVkVSX0JBRF9DT05URU5UOiAxOSwgU0VSVkVSX1VOQVVUSE9SSVpFRDogMjAsIFNFUlZFUl9DRVJUSUZJQ0FURV9QUk9CTEVNOiAyMSwgU0VSVkVSX0ZPUkJJRERFTjogMjIsIFNFUlZFUl9VTkVYUEVDVEVEX1JFU1BPTlNFOiAyMywgU0VSVkVSX0NPTlRFTlRfTEVOR1RIX01JU01BVENIOiAyNCwgU0VSVkVSX0NST1NTX09SSUdJTl9SRURJUkVDVDogMjUsIFVTRVJfQ0FOQ0VMRUQ6IDI2LCBVU0VSX1NIVVRET1dOOiAyNywgVVNFUl9QQVVTRUQ6IDI4LCBET1dOTE9BRF9QUk9DRVNTX0NSQVNIRUQ6IDI5IH0NCglzdGF0aWMgRE9XTkxPQURfU1RBVEUgOj0geyBJTl9QUk9HUkVTUzogMCwgSU5URVJSVVBURUQ6IDEsIENPTVBMRVRFRDogMiB9DQoJc3RhdGljIEZBVklDT05fSU1BR0VfRk9STUFUIDo9IHsgUE5HOiAwLCBKUEVHOiAxIH0NCglzdGF0aWMgRklMRV9TWVNURU1fSEFORExFX0tJTkQgOj0geyBGSUxFOiAwLCBESVJFQ1RPUlk6IDEgfQ0KCXN0YXRpYyBGSUxFX1NZU1RFTV9IQU5ETEVfUEVSTUlTU0lPTiA6PSB7IFJFQURfT05MWTogMCwgUkVBRF9XUklURTogMSB9DQoJc3RhdGljIEZSQU1FX0tJTkQgOj0geyBVTktOT1dOOiAwLCBNQUlOX0ZSQU1FOiAxLCBJRlJBTUU6IDIsIEVNQkVEOiAzLCBPQkpFQ1Q6IDQgfQ0KCXN0YXRpYyBIT1NUX1JFU09VUkNFX0FDQ0VTU19LSU5EIDo9IHsgREVOWTogMCwgQUxMT1c6IDEsIERFTllfQ09SUzogMiB9DQoJc3RhdGljIEtFWV9FVkVOVF9LSU5EIDo9IHsgS0VZX0RPV046IDAsIEtFWV9VUDogMSwgU1lTVEVNX0tFWV9ET1dOOiAyLCBTWVNURU1fS0VZX1VQOiAzIH0NCglzdGF0aWMgTUVNT1JZX1VTQUdFX1RBUkdFVF9MRVZFTCA6PSB7IE5PUk1BTDogMCwgTE9XOiAxIH0NCglzdGF0aWMgTU9VU0VfRVZFTlRfS0lORCA6PSB7IEhPUklaT05UQUxfV0hFRUw6IDB4MjBlLCBMRUZUX0JVVFRPTl9ET1VCTEVfQ0xJQ0s6IDB4MjAzLCBMRUZUX0JVVFRPTl9ET1dOOiAweDIwMSwgTEVGVF9CVVRUT05fVVA6IDB4MjAyLCBMRUFWRTogMHgyYTMsIE1JRERMRV9CVVRUT05fRE9VQkxFX0NMSUNLOiAweDIwOSwgTUlERExFX0JVVFRPTl9ET1dOOiAweDIwNywgTUlERExFX0JVVFRPTl9VUDogMHgyMDgsIE1PVkU6IDB4MjAwLCBSSUdIVF9CVVRUT05fRE9VQkxFX0NMSUNLOiAweDIwNiwgUklHSFRfQlVUVE9OX0RPV046IDB4MjA0LCBSSUdIVF9CVVRUT05fVVA6IDB4MjA1LCBXSEVFTDogMHgyMGEsIFhfQlVUVE9OX0RPVUJMRV9DTElDSzogMHgyMGQsIFhfQlVUVE9OX0RPV046IDB4MjBiLCBYX0JVVFRPTl9VUDogMHgyMGMsIE5PTl9DTElFTlRfUklHSFRfQlVUVE9OX0RPV046IDB4YTQsIE5PTl9DTElFTlRfUklHSFRfQlVUVE9OX1VQOiAweGE1IH0NCglzdGF0aWMgTU9VU0VfRVZFTlRfVklSVFVBTF9LRVlTIDo9IHsgTk9ORTogMCwgTEVGVF9CVVRUT046IDB4MSwgUklHSFRfQlVUVE9OOiAweDIsIFNISUZUOiAweDQsIENPTlRST0w6IDB4OCwgTUlERExFX0JVVFRPTjogMHgxMCwgWF9CVVRUT04xOiAweDIwLCBYX0JVVFRPTjI6IDB4NDAgfQ0KCXN0YXRpYyBNT1ZFX0ZPQ1VTX1JFQVNPTiA6PSB7IFBST0dSQU1NQVRJQzogMCwgTkVYVDogMSwgUFJFVklPVVM6IDIgfQ0KCXN0YXRpYyBOQVZJR0FUSU9OX0tJTkQgOj0geyBSRUxPQUQ6IDAsIEJBQ0tfT1JfRk9SV0FSRDogMSwgTkVXX0RPQ1VNRU5UOiAyIH0NCglzdGF0aWMgTk9OX0NMSUVOVF9SRUdJT05fS0lORCA6PSB7IE5PV0hFUkU6IDAsIENMSUVOVDogMSwgQ0FQVElPTjogMiwgTUlOSU1JWkU6IDgsIE1BWElNSVpFOiA5LCBMT1NFOiAyMCB9DQoJc3RhdGljIFBERl9UT09MQkFSX0lURU1TIDo9IHsgSVRFTVNfTk9ORTogMCwgSVRFTVNfU0FWRTogMHgxLCBJVEVNU19QUklOVDogMHgyLCBJVEVNU19TQVZFX0FTOiAweDQsIElURU1TX1pPT01fSU46IDB4OCwgSVRFTVNfWk9PTV9PVVQ6IDB4MTAsIElURU1TX1JPVEFURTogMHgyMCwgSVRFTVNfRklUX1BBR0U6IDB4NDAsIElURU1TX1BBR0VfTEFZT1VUOiAweDgwLCBJVEVNU19CT09LTUFSS1M6IDB4MTAwLCBJVEVNU19QQUdFX1NFTEVDVE9SOiAweDIwMCwgSVRFTVNfU0VBUkNIOiAweDQwMCwgSVRFTVNfRlVMTF9TQ1JFRU46IDB4ODAwLCBJVEVNU19NT1JFX1NFVFRJTkdTOiAweDEwMDAgfQ0KCXN0YXRpYyBQRVJNSVNTSU9OX0tJTkQgOj0geyBVTktOT1dOX1BFUk1JU1NJT046IDAsIE1JQ1JPUEhPTkU6IDEsIENBTUVSQTogMiwgR0VPTE9DQVRJT046IDMsIE5PVElGSUNBVElPTlM6IDQsIE9USEVSX1NFTlNPUlM6IDUsIENMSVBCT0FSRF9SRUFEOiA2LCBNVUxUSVBMRV9BVVRPTUFUSUNfRE9XTkxPQURTOiA3LCBGSUxFX1JFQURfV1JJVEU6IDgsIEFVVE9QTEFZOiA5LCBMT0NBTF9GT05UUzogMTAsIE1JRElfU1lTVEVNX0VYQ0xVU0lWRV9NRVNTQUdFUzogMTEsIFdJTkRPV19NQU5BR0VNRU5UOiAxMiB9DQoJc3RhdGljIFBFUk1JU1NJT05fU1RBVEUgOj0geyBERUZBVUxUOiAwLCBBTExPVzogMSwgREVOWTogMiB9DQoJc3RhdGljIFBPSU5URVJfRVZFTlRfS0lORCA6PSB7IEFDVElWQVRFOiAweDI0YiwgRE9XTjogMHgyNDYsIEVOVEVSOiAweDI0OSwgTEVBVkU6IDB4MjRhLCBVUDogMHgyNDcsIFVQREFURTogMHgyNDUgfQ0KCXN0YXRpYyBQUkVGRVJSRURfQ09MT1JfU0NIRU1FIDo9IHsgQVVUTzogMCwgTElHSFQ6IDEsIERBUks6IDIgfQ0KCXN0YXRpYyBQUklOVF9DT0xMQVRJT04gOj0geyBERUZBVUxUOiAwLCBDT0xMQVRFRDogMSwgVU5DT0xMQVRFRDogMiB9DQoJc3RhdGljIFBSSU5UX0NPTE9SX01PREUgOj0geyBERUZBVUxUOiAwLCBDT0xPUjogMSwgR1JBWVNDQUxFOiAyIH0NCglzdGF0aWMgUFJJTlRfRElBTE9HX0tJTkQgOj0geyBCUk9XU0VSOiAwLCBTWVNURU06IDEgfQ0KCXN0YXRpYyBQUklOVF9EVVBMRVggOj0geyBERUZBVUxUOiAwLCBPTkVfU0lERUQ6IDEsIFRXT19TSURFRF9MT05HX0VER0U6IDIsIFRXT19TSURFRF9TSE9SVF9FREdFOiAzIH0NCglzdGF0aWMgUFJJTlRfTUVESUFfU0laRSA6PSB7IERFRkFVTFQ6IDAsIENVU1RPTTogMSB9DQoJc3RhdGljIFBSSU5UX09SSUVOVEFUSU9OIDo9IHsgUE9SVFJBSVQ6IDAsIExBTkRTQ0FQRTogMSB9DQoJc3RhdGljIFBSSU5UX1NUQVRVUyA6PSB7IFNVQ0NFRURFRDogMCwgUFJJTlRFUl9VTkFWQUlMQUJMRTogMSwgT1RIRVJfRVJST1I6IDIgfQ0KCXN0YXRpYyBQUk9DRVNTX0ZBSUxFRF9LSU5EIDo9IHsgQlJPV1NFUl9QUk9DRVNTX0VYSVRFRDogMCwgUkVOREVSX1BST0NFU1NfRVhJVEVEOiAxLCBSRU5ERVJfUFJPQ0VTU19VTlJFU1BPTlNJVkU6IDIsIEZSQU1FX1JFTkRFUl9QUk9DRVNTX0VYSVRFRDogMywgVVRJTElUWV9QUk9DRVNTX0VYSVRFRDogNCwgU0FOREJPWF9IRUxQRVJfUFJPQ0VTU19FWElURUQ6IDUsIEdQVV9QUk9DRVNTX0VYSVRFRDogNiwgUFBBUElfUExVR0lOX1BST0NFU1NfRVhJVEVEOiA3LCBQUEFQSV9CUk9LRVJfUFJPQ0VTU19FWElURUQ6IDgsIFVOS05PV05fUFJPQ0VTU19FWElURUQ6IDkgfQ0KCXN0YXRpYyBQUk9DRVNTX0ZBSUxFRF9SRUFTT04gOj0geyBVTkVYUEVDVEVEOiAwLCBVTlJFU1BPTlNJVkU6IDEsIFRFUk1JTkFURUQ6IDIsIENSQVNIRUQ6IDMsIExBVU5DSF9GQUlMRUQ6IDQsIE9VVF9PRl9NRU1PUlk6IDUsIFBST0ZJTEVfREVMRVRFRDogNiB9DQoJc3RhdGljIFBST0NFU1NfS0lORCA6PSB7IEJST1dTRVI6IDAsIFJFTkRFUkVSOiAxLCBVVElMSVRZOiAyLCBTQU5EQk9YX0hFTFBFUjogMywgR1BVOiA0LCBQUEFQSV9QTFVHSU46IDUsIFBQQVBJX0JST0tFUjogNiB9DQoJc3RhdGljIFJFTEVBU0VfQ0hBTk5FTFMgOj0geyBOT05FOiAwLCBTVEFCTEU6IDEsIEJFVEE6IDIsIERFVjogNCwgQ0FOQVJZOiA4IH0NCglzdGF0aWMgU0FWRV9BU19LSU5EIDo9IHsgREVGQVVMVDogMCwgSFRNTF9PTkxZOiAxLCBTSU5HTEVfRklMRTogMiwgQ09NUExFVEU6IDMgfQ0KCXN0YXRpYyBTQVZFX0FTX1VJX1JFU1VMVCA6PSB7IFNVQ0NFU1M6IDAsIElOVkFMSURfUEFUSDogMSwgRklMRV9BTFJFQURZX0VYSVNUUzogMiwgS0lORF9OT1RfU1VQUE9SVEVEOiAzLCBDQU5DRUxMRUQ6IDQgfQ0KCXN0YXRpYyBTQ1JJUFRfRElBTE9HX0tJTkQgOj0geyBBTEVSVDogMCwgQ09ORklSTTogMSwgUFJPTVBUOiAyLCBCRUZPUkVVTkxPQUQ6IDMgfQ0KCXN0YXRpYyBTQ1JPTExCQVJfU1RZTEUgOj0geyBERUZBVUxUOiAwLCBGTFVFTlRfT1ZFUkxBWTogMSB9DQoJc3RhdGljIFNFUlZFUl9DRVJUSUZJQ0FURV9FUlJPUl9BQ1RJT04gOj0geyBBTFdBWVNfQUxMT1c6IDAsIENBTkNFTDogMSwgREVGQVVMVDogMiB9DQoJc3RhdGljIFNIQVJFRF9CVUZGRVJfQUNDRVNTIDo9IHsgUkVBRF9PTkxZOiAwLCBSRUFEX1dSSVRFOiAxIH0NCglzdGF0aWMgVEVYVF9ESVJFQ1RJT05fS0lORCA6PSB7IERFRkFVTFQ6IDAsIExFRlRfVE9fUklHSFQ6IDEsIFJJR0hUX1RPX0xFRlQ6IDIgfQ0KCXN0YXRpYyBUUkFDS0lOR19QUkVWRU5USU9OX0xFVkVMIDo9IHsgTk9ORTogMCwgQkFTSUM6IDEsIEJBTEFOQ0VEOiAyLCBTVFJJQ1Q6IDMgfQ0KCXN0YXRpYyBXRUJfRVJST1JfU1RBVFVTIDo9IHsgVU5LTk9XTjogMCwgQ0VSVElGSUNBVEVfQ09NTU9OX05BTUVfSVNfSU5DT1JSRUNUOiAxLCBDRVJUSUZJQ0FURV9FWFBJUkVEOiAyLCBDTElFTlRfQ0VSVElGSUNBVEVfQ09OVEFJTlNfRVJST1JTOiAzLCBDRVJUSUZJQ0FURV9SRVZPS0VEOiA0LCBDRVJUSUZJQ0FURV9JU19JTlZBTElEOiA1LCBTRVJWRVJfVU5SRUFDSEFCTEU6IDYsIFRJTUVPVVQ6IDcsIEVSUk9SX0hUVFBfSU5WQUxJRF9TRVJWRVJfUkVTUE9OU0U6IDgsIENPTk5FQ1RJT05fQUJPUlRFRDogOSwgQ09OTkVDVElPTl9SRVNFVDogMTAsIERJU0NPTk5FQ1RFRDogMTEsIENBTk5PVF9DT05ORUNUOiAxMiwgSE9TVF9OQU1FX05PVF9SRVNPTFZFRDogMTMsIE9QRVJBVElPTl9DQU5DRUxFRDogMTQsIFJFRElSRUNUX0ZBSUxFRDogMTUsIFVORVhQRUNURURfRVJST1I6IDE2LCBWQUxJRF9BVVRIRU5USUNBVElPTl9DUkVERU5USUFMU19SRVFVSVJFRDogMTcsIFZBTElEX1BST1hZX0FVVEhFTlRJQ0FUSU9OX1JFUVVJUkVEOiAxOCB9DQoJc3RhdGljIFdFQl9SRVNPVVJDRV9DT05URVhUIDo9IHsgQUxMOiAwLCBET0NVTUVOVDogMSwgU1RZTEVTSEVFVDogMiwgSU1BR0U6IDMsIE1FRElBOiA0LCBGT05UOiA1LCBTQ1JJUFQ6IDYsIFhNTF9IVFRQX1JFUVVFU1Q6IDcsIEZFVENIOiA4LCBURVhUX1RSQUNLOiA5LCBFVkVOVF9TT1VSQ0U6IDEwLCBXRUJTT0NLRVQ6IDExLCBNQU5JRkVTVDogMTIsIFNJR05FRF9FWENIQU5HRTogMTMsIFBJTkc6IDE0LCBDU1BfVklPTEFUSU9OX1JFUE9SVDogMTUsIE9USEVSOiAxNiB9DQoJc3RhdGljIFdFQl9SRVNPVVJDRV9SRVFVRVNUX1NPVVJDRV9LSU5EUyA6PSB7IE5PTkU6IDAsIERPQ1VNRU5UOiAxLCBTSEFSRURfV09SS0VSOiAyLCBTRVJWSUNFX1dPUktFUjogNCwgQUxMOiAwWGZmZmZmZmZmIH0NCgk7I2VuZHJlZ2lvbg0KfQ0KQ29UYXNrTWVtX1N0cmluZyhwdHIpIHsNCglzIDo9IFN0ckdldChwdHIpLCBEbGxDYWxsKCdvbGUzMlxDb1Rhc2tNZW1GcmVlJywgJ3B0cicsIHB0cikNCglyZXR1cm4gcw0KfQ0KOyBDb25zdHJ1Y3Rpb24gYW5kIGRlY29uc3RydWN0aW9uIFZBUklBTlQgc3RydWN0DQpjbGFzcyBDb21WYXIgZXh0ZW5kcyBCdWZmZXIgew0KCS8qKg0KCSAqIENvbnN0cnVjdGlvbiBWQVJJQU5UIHN0cnVjdCwgYHB0cmAgcHJvcGVydHkgcG9pbnRzIHRvIHRoZSBhZGRyZXNzLCBgX19JdGVtYCBwcm9wZXJ0eSByZXR1cm5zIHZhcidzIFZhbHVlDQoJICogQHBhcmFtIHZWYWwgVmFsdWVzIHRoYXQgbmVlZCB0byBiZSB3cmFwcGVkLCBzdXBwb3J0cyBTdHJpbmcsIEludGVnZXIsIERvdWJsZSwgQXJyYXksIENvbVZhbHVlLCBDb21PYmpBcnJheQ0KCSAqICMjIyBleGFtcGxlDQoJICogYHZhcjEgOj0gQ29tVmFyKCdzdHJpbmcnKSwgTXNnQm94KHZhcjFbXSlgDQoJICoNCgkgKiBgdmFyMiA6PSBDb21WYXIoWzEsMiwzLDRdLCAsIHRydWUpYA0KCSAqDQoJICogYHZhcjMgOj0gQ29tVmFyKENvbVZhbHVlKDB4YiwgLTEpKWANCgkgKiBAcGFyYW0gdlR5cGUgVmFyaWFudCdzIHR5cGUsIFZUX1ZBUklBTlQoZGVmYXVsdCkNCgkgKiBAcGFyYW0gY29udmVydCBDb252ZXJ0IEFISydzIGFycmF5IHRvIENvbU9iakFycmF5DQoJICovDQoJc3RhdGljIENhbGwodlZhbCA6PSAwLCB2VHlwZSA6PSAweEMsIGNvbnZlcnQgOj0gZmFsc2UpIHsNCgkJc3RhdGljIHNpemUgOj0gOCArIDIgKiBBX1B0clNpemUNCgkJaWYgdlZhbCBpcyBDb21WYXINCgkJCXJldHVybiB2VmFsDQoJCXZhciA6PSBzdXBlcihzaXplLCAwKSwgSXNPYmplY3QodlZhbCkgJiYgdlR5cGUgOj0gMHhDDQoJCXZhci5yZWYgOj0gcmVmIDo9IENvbVZhbHVlKDB4NDAwMCB8IHZUeXBlLCB2YXIuUHRyICsgKHZUeXBlID0gMHhDID8gMCA6IDgpKQ0KCQlpZiBjb252ZXJ0ICYmICh2VmFsIGlzIEFycmF5KSB7DQoJCQlzd2l0Y2ggVHlwZSh2VmFsWzFdKSB7DQoJCQkJY2FzZSAiSW50ZWdlciI6IHZUeXBlIDo9IDMNCgkJCQljYXNlICJTdHJpbmciOiB2VHlwZSA6PSA4DQoJCQkJY2FzZSAiRmxvYXQiOiB2VHlwZSA6PSA1DQoJCQkJY2FzZSAiQ29tVmFsdWUiLCAiQ29tT2JqZWN0IjogdlR5cGUgOj0gQ29tT2JqVHlwZSh2VmFsWzFdKQ0KCQkJCWRlZmF1bHQ6IHZUeXBlIDo9IDB4Qw0KCQkJfQ0KCQkJQ29tT2JqRmxhZ3MocmVmW10gOj0gb2JqIDo9IENvbU9iakFycmF5KHZUeXBlLCB2VmFsLkxlbmd0aCksIGkgOj0gLTEpDQoJCQlmb3IgdiBpbiB2VmFsDQoJCQkJb2JqWysraV0gOj0gdg0KCQl9IGVsc2UgcmVmW10gOj0gdlZhbA0KCQlpZiB2VHlwZSAmIDB4Qw0KCQkJdmFyLklzVmFyaWFudCA6PSAxDQoJCXJldHVybiB2YXINCgl9DQoJX19EZWxldGUoKSA9PiBEbGxDYWxsKCJvbGVhdXQzMlxWYXJpYW50Q2xlYXIiLCAicHRyIiwgdGhpcykNCglfX0l0ZW0gew0KCQlnZXQgPT4gdGhpcy5yZWZbXQ0KCQlzZXQgPT4gdGhpcy5yZWZbXSA6PSBWYWx1ZQ0KCX0NCglUeXBlIHsNCgkJZ2V0ID0+IE51bUdldCh0aGlzLCAidXNob3J0IikNCgkJc2V0IHsNCgkJCWlmICghdGhpcy5Jc1ZhcmlhbnQpDQoJCQkJdGhyb3cgUHJvcGVydHlFcnJvcigiVmFyVHlwZSBpcyBub3QgVlRfVkFSSUFOVCwgVHlwZSBpcyByZWFkLW9ubHkuIiwgLTIpDQoJCQlOdW1QdXQoInVzaG9ydCIsIFZhbHVlLCB0aGlzKQ0KCQl9DQoJfQ0KCXN0YXRpYyBQcm90b3R5cGUuSXNWYXJpYW50IDo9IDANCglzdGF0aWMgUHJvdG90eXBlLnJlZiA6PSAwDQp9DQoNCi8qKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioNCiAqIEBkZXNjcmlwdGlvbiBJbXBsZW1lbnRzIGEgamF2YXNjcmlwdC1saWtlIFByb21pc2UNCiAqIEBhdXRob3IgdGhxYnkNCiAqIEBkYXRlIDIwMjUvMDEvMDkNCiAqIEB2ZXJzaW9uIDEuMC4xMA0KICoqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqLw0KDQovKioNCiAqIFJlcHJlc2VudHMgdGhlIGNvbXBsZXRpb24gb2YgYW4gYXN5bmNocm9ub3VzIG9wZXJhdGlvbg0KICogQHNlZSB7QGxpbmsgaHR0cHM6Ly9kZXZlbG9wZXIubW96aWxsYS5vcmcvZW4tVVMvZG9jcy9XZWIvSmF2YVNjcmlwdC9SZWZlcmVuY2UvR2xvYmFsX09iamVjdHMvUHJvbWlzZSBNRE4gZG9jfQ0KICogQGFsaWFzIFByb21pc2U8VD1Bbnk+DQogKi8NCmNsYXNzIFByb21pc2Ugew0KCXN0YXRpYyBQcm90b3R5cGUuc3RhdHVzIDo9ICdwZW5kaW5nJw0KCS8qKiBAdHlwZSB7VH0gKi8NCglzdGF0aWMgUHJvdG90eXBlLnJlc3VsdCA6PSAnJw0KCXN0YXRpYyBQcm90b3R5cGUudGhyb3duIDo9IGZhbHNlDQoNCgkvKioNCgkgKiBAcGFyYW0geyhyZXNvbHZlIFsscmVqZWN0XSkgPT4gdm9pZH0gZXhlY3V0b3IgQSBjYWxsYmFjayB1c2VkIHRvIGluaXRpYWxpemUgdGhlIHByb21pc2UuIFRoaXMgY2FsbGJhY2sgaXMgcGFzc2VkIHR3byBhcmd1bWVudHM6DQoJICogYSByZXNvbHZlIGNhbGxiYWNrIHVzZWQgdG8gcmVzb2x2ZSB0aGUgcHJvbWlzZSB3aXRoIGEgdmFsdWUgb3IgdGhlIHJlc3VsdCBvZiBhbm90aGVyIHByb21pc2UsDQoJICogYW5kIGEgcmVqZWN0IGNhbGxiYWNrIHVzZWQgdG8gcmVqZWN0IHRoZSBwcm9taXNlIHdpdGggYSBwcm92aWRlZCByZWFzb24gb3IgZXJyb3IuDQoJICogLSByZXNvbHZlKGRhdGEpID0+IHZvaWQNCgkgKiAtIHJlamVjdChlcnIpID0+IHZvaWQNCgkgKi8NCglfX05ldyhleGVjdXRvcikgew0KCQl0aGlzLmNhbGxiYWNrcyA6PSBbXQ0KCQl0cnkNCgkJCShleGVjdXRvci5NYXhQYXJhbXMgPSAxKSA/IGV4ZWN1dG9yKHJlc29sdmUpIDogZXhlY3V0b3IocmVzb2x2ZSwgcmVqZWN0KQ0KCQljYXRjaCBBbnkgYXMgZQ0KCQkJcmVqZWN0KGUpDQoJCXJlc29sdmUodmFsdWUgOj0gJycpIHsNCgkJCWlmIHZhbHVlIGlzIFByb21pc2Ugew0KCQkJCWlmICFPYmpIYXNPd25Qcm9wKHZhbHVlLCAnc3RhdHVzJykgew0KCQkJCQlpZiB0aGlzICE9PSB2YWx1ZQ0KCQkJCQkJcmV0dXJuIHZhbHVlLm9uQ29tcGxldGVkKHJlc29sdmUpDQoJCQkJCXRoaXMuc3RhdHVzIDo9ICdyZWplY3RlZCcsIHRoaXMucmVzdWx0IDo9IFZhbHVlRXJyb3IoJ0NoYWluaW5nIGN5Y2xlIGRldGVjdGVkIGZvciBwcm9taXNlJywgLTEpDQoJCQkJfSBlbHNlIGlmIHRoaXMNCgkJCQkJdGhpcy5zdGF0dXMgOj0gdmFsdWUuc3RhdHVzLCB0aGlzLnJlc3VsdCA6PSB2YWx1ZS5yZXN1bHQNCgkJCQllbHNlIHJldHVybg0KCQkJfSBlbHNlIGlmIHRoaXMNCgkJCQl0aGlzLnN0YXR1cyA6PSAnZnVsZmlsbGVkJywgdGhpcy5yZXN1bHQgOj0gdmFsdWUNCgkJCWVsc2UgcmV0dXJuDQoJCQlTZXRUaW1lcih0YXNrLkJpbmQodGhpcyksIC0xKSwgdGhpcyA6PSAwDQoJCX0NCgkJcmVqZWN0KHJlYXNvbj8pIHsNCgkJCWlmICF0aGlzDQoJCQkJcmV0dXJuDQoJCQl0aGlzLnN0YXR1cyA6PSAncmVqZWN0ZWQnLCB0aGlzLnJlc3VsdCA6PSByZWFzb24gPz8gRXJyb3IoLCAtMSkNCgkJCVNldFRpbWVyKHRhc2suQmluZCh0aGlzKSwgLTEpLCB0aGlzIDo9IDANCgkJfQ0KCQlzdGF0aWMgdGFzayh0aGlzKSB7DQoJCQlmb3IgY2IgaW4gdGhpcy5EZWxldGVQcm9wKCdjYWxsYmFja3MnKQ0KCQkJCWNiKHRoaXMpDQoJCQllbHNlIGlmICFPYmpIYXNPd25Qcm9wKHRoaXMsICd0aHJvd24nKSAmJiB0aGlzLnN0YXR1cyA9PSAncmVqZWN0ZWQnICYmIHRoaXMudGhyb3duIDo9IHRydWUNCgkJCQl0aHJvdyB0aGlzLnJlc3VsdA0KCQl9DQoJfQ0KCTsgX19EZWxldGUoKSA9PiBPdXRwdXREZWJ1ZygnZGVsOiAnIE9ialB0cih0aGlzKSAnYG4nKQ0KDQoJLyoqDQoJICogQXR0YWNoZXMgYSBjYWxsYmFjayB0aGF0IGlzIGludm9rZWQgd2hlbiB0aGUgUHJvbWlzZSBpcyBjb21wbGV0ZWQgKGZ1bGZpbGxlZCBvciByZWplY3RlZCkuDQoJICogQHBhcmFtIHsodmFsdWU6IFByb21pc2UpID0+IHZvaWR9IGNhbGxiYWNrIFRoZSBjYWxsYmFjayB0byBleGVjdXRlIHdoZW4gdGhlIFByb21pc2UgaXMgY29tcGxldGVkLg0KCSAqIEByZXR1cm5zIHt2b2lkfQ0KCSAqLw0KCW9uQ29tcGxldGVkKGNhbGxiYWNrKSB7DQoJCU9iakhhc093blByb3AodGhpcywgJ2NhbGxiYWNrcycpID8gdGhpcy5jYWxsYmFja3MuUHVzaChjYWxsYmFjaykgOiBuZXh0VGljayh0aGlzLCBjYWxsYmFjaykNCgkJc3RhdGljIG5leHRUaWNrKHRoaXMsIGNhbGxiYWNrKSA9PiBTZXRUaW1lcigoKSA9PiBjYWxsYmFjayh0aGlzKSwgLTEpDQoJfQ0KCS8qKg0KCSAqIEF0dGFjaGVzIGNhbGxiYWNrcyBmb3IgdGhlIHJlc29sdXRpb24gYW5kL29yIHJlamVjdGlvbiBvZiB0aGUgUHJvbWlzZS4NCgkgKiBAcGFyYW0geyh2YWx1ZSkgPT4gdm9pZH0gb25mdWxmaWxsZWQgVGhlIGNhbGxiYWNrIHRvIGV4ZWN1dGUgd2hlbiB0aGUgUHJvbWlzZSBpcyByZXNvbHZlZC4NCgkgKiBAcGFyYW0geyhyZWFzb24pID0+IHZvaWR9IG9ucmVqZWN0ZWQgVGhlIGNhbGxiYWNrIHRvIGV4ZWN1dGUgd2hlbiB0aGUgUHJvbWlzZSBpcyByZWplY3RlZC4NCgkgKiBAcmV0dXJucyB7dm9pZH0NCgkgKi8NCglvblNldHRsZWQob25mdWxmaWxsZWQsIG9ucmVqZWN0ZWQgOj0gUHJvbWlzZS50aHJvdykgew0KCQl0aGlzLm9uQ29tcGxldGVkKHZhbCA9PiAodmFsLnN0YXR1cyA9PSAnZnVsZmlsbGVkJyA/IG9uZnVsZmlsbGVkIDogb25yZWplY3RlZCkodmFsLnJlc3VsdCkpDQoJfQ0KCS8qKg0KCSAqIEF0dGFjaGVzIGNhbGxiYWNrcyBmb3IgdGhlIHJlc29sdXRpb24gYW5kL29yIHJlamVjdGlvbiBvZiB0aGUgUHJvbWlzZS4NCgkgKiBAcGFyYW0geyh2YWx1ZSkgPT4gQW55fSBvbmZ1bGZpbGxlZCBUaGUgY2FsbGJhY2sgdG8gZXhlY3V0ZSB3aGVuIHRoZSBQcm9taXNlIGlzIHJlc29sdmVkLg0KCSAqIEBwYXJhbSB7KHJlYXNvbikgPT4gQW55fSBvbnJlamVjdGVkIFRoZSBjYWxsYmFjayB0byBleGVjdXRlIHdoZW4gdGhlIFByb21pc2UgaXMgcmVqZWN0ZWQuDQoJICogQHJldHVybnMge1Byb21pc2V9IEEgUHJvbWlzZSBmb3IgdGhlIGNvbXBsZXRpb24gb2Ygd2hpY2ggZXZlciBjYWxsYmFjayBpcyBleGVjdXRlZC4NCgkgKi8NCgl0aGVuKG9uZnVsZmlsbGVkLCBvbnJlamVjdGVkIDo9IFByb21pc2UudGhyb3cpIHsNCgkJcmV0dXJuIFByb21pc2UoZXhlY3V0b3IpDQoJCWV4ZWN1dG9yKHJlc29sdmUsIHJlamVjdCkgew0KCQkJdGhpcy5vbkNvbXBsZXRlZCh0YXNrKQ0KCQkJdGFzayhwMSkgew0KCQkJCXRyeQ0KCQkJCQlyZXNvbHZlKChwMS5zdGF0dXMgPT0gJ2Z1bGZpbGxlZCcgPyBvbmZ1bGZpbGxlZCA6IG9ucmVqZWN0ZWQpKHAxLnJlc3VsdCkpDQoJCQkJY2F0Y2ggQW55IGFzIGUNCgkJCQkJcmVqZWN0KGUpDQoJCQl9DQoJCX0NCgl9DQoJLyoqDQoJICogQXR0YWNoZXMgYSBjYWxsYmFjayBmb3Igb25seSB0aGUgcmVqZWN0aW9uIG9mIHRoZSBQcm9taXNlLg0KCSAqIEBwYXJhbSB7KHJlYXNvbikgPT4gQW55fSBvbnJlamVjdGVkIFRoZSBjYWxsYmFjayB0byBleGVjdXRlIHdoZW4gdGhlIFByb21pc2UgaXMgcmVqZWN0ZWQuDQoJICogQHJldHVybnMge1Byb21pc2V9IEEgUHJvbWlzZSBmb3IgdGhlIGNvbXBsZXRpb24gb2YgdGhlIGNhbGxiYWNrLg0KCSAqLw0KCWNhdGNoKG9ucmVqZWN0ZWQpID0+IHRoaXMudGhlbih2YWwgPT4gdmFsLCBvbnJlamVjdGVkKQ0KCS8qKg0KCSAqIEF0dGFjaGVzIGEgY2FsbGJhY2sgdGhhdCBpcyBpbnZva2VkIHdoZW4gdGhlIFByb21pc2UgaXMgc2V0dGxlZCAoZnVsZmlsbGVkIG9yIHJlamVjdGVkKS4NCgkgKiBUaGUgcmVzb2x2ZWQgdmFsdWUgY2Fubm90IGJlIG1vZGlmaWVkIGZyb20gdGhlIGNhbGxiYWNrLg0KCSAqIEBwYXJhbSB7KCkgPT4gdm9pZH0gb25maW5hbGx5IFRoZSBjYWxsYmFjayB0byBleGVjdXRlIHdoZW4gdGhlIFByb21pc2UgaXMgc2V0dGxlZCAoZnVsZmlsbGVkIG9yIHJlamVjdGVkKS4NCgkgKiBAcmV0dXJucyB7UHJvbWlzZX0gQSBQcm9taXNlIGZvciB0aGUgY29tcGxldGlvbiBvZiB0aGUgY2FsbGJhY2suDQoJICovDQoJZmluYWxseShvbmZpbmFsbHkpID0+IHRoaXMudGhlbigNCgkJdmFsID0+IChvbmZpbmFsbHkoKSwgdmFsKSwNCgkJZXJyID0+IChvbmZpbmFsbHkoKSwgKFByb21pc2UudGhyb3cpKGVycikpDQoJKQ0KCS8qKg0KCSAqIFdhaXRzIGZvciBhIHByb21pc2UgdG8gYmUgY29tcGxldGVkLg0KCSAqIEByZXR1cm5zIHtUfQ0KCSAqLw0KCWF3YWl0Mih0aW1lb3V0IDo9IC0xKSB7DQoJCWVuZCA6PSBBX1RpY2tDb3VudCArIHRpbWVvdXQsIG9sZCA6PSBDcml0aWNhbCgwKQ0KCQl3aGlsZSAocGVuZGluZyA6PSAhT2JqSGFzT3duUHJvcCh0aGlzLCAnc3RhdHVzJykpICYmICh0aW1lb3V0IDwgMCB8fCBBX1RpY2tDb3VudCA8IGVuZCkNCgkJCVNsZWVwKDEpDQoJCUNyaXRpY2FsKG9sZCkNCgkJaWYgIXBlbmRpbmcgJiYgdGhpcy5zdGF0dXMgPT0gJ2Z1bGZpbGxlZCcNCgkJCXJldHVybiB0aGlzLnJlc3VsdA0KCQl0aHJvdyBwZW5kaW5nID8gVGltZW91dEVycm9yKCkgOiAodGhpcy50aHJvd24gOj0gdHJ1ZSkgJiYgdGhpcy5yZXN1bHQNCgl9DQoJLyoqDQoJICogV2FpdHMgZm9yIGEgcHJvbWlzZSB0byBiZSBjb21wbGV0ZWQuDQoJICogV2FrZSB1cCBvbmx5IHdoZW4gYSBzeXN0ZW0gZXZlbnQgb3IgdGltZW91dCBvY2N1cnMsIHdoaWNoIHRha2VzIHVwIGxlc3MgY3B1IHRpbWUuDQoJICogQHJldHVybnMge1R9DQoJICovDQoJYXdhaXQodGltZW91dCA6PSAtMSkgew0KCQlzdGF0aWMgaEV2ZW50IDo9IERsbENhbGwoJ0NyZWF0ZUV2ZW50JywgJ3B0cicsIDAsICdpbnQnLCAxLCAnaW50JywgMCwgJ3B0cicsIDAsICdwdHInKQ0KCQlzdGF0aWMgX19kZWwgOj0geyBQdHI6IGhFdmVudCwgX19EZWxldGU6IHRoaXMgPT4gRGxsQ2FsbCgnQ2xvc2VIYW5kbGUnLCAncHRyJywgdGhpcykgfQ0KCQlzdGF0aWMgbXNnIDo9IEJ1ZmZlcig0ICogQV9QdHJTaXplICsgMTYpDQoJCXQgOj0gQV9UaWNrQ291bnQsIHIgOj0gMjU4LCBvbGQgOj0gQ3JpdGljYWwoMCkNCgkJd2hpbGUgKHBlbmRpbmcgOj0gIU9iakhhc093blByb3AodGhpcywgJ3N0YXR1cycpKSAmJiB0aW1lb3V0ICYmDQoJCQkoRGxsQ2FsbCgnUGVla01lc3NhZ2UnLCAncHRyJywgbXNnLCAncHRyJywgMCwgJ3VpbnQnLCAwLCAndWludCcsIDAsICd1aW50JywgMCkgfHwNCgkJCQkxID09IHIgOj0gRGxsQ2FsbCgnTXNnV2FpdEZvck11bHRpcGxlT2JqZWN0cycsICd1aW50JywgMSwgJ3B0cionLCBoRXZlbnQsDQoJCQkJCSdpbnQnLCAwLCAndWludCcsIHRpbWVvdXQsICd1aW50JywgNzQyMywgJ3VpbnQnKSkNCgkJCVNsZWVwKC0xKSwgKHRpbWVvdXQgPCAwKSB8fCB0aW1lb3V0IDo9IE1heCh0aW1lb3V0IC0gQV9UaWNrQ291bnQgKyB0LCAwKQ0KCQlDcml0aWNhbChvbGQpDQoJCWlmICFwZW5kaW5nICYmIHRoaXMuc3RhdHVzID09ICdmdWxmaWxsZWQnDQoJCQlyZXR1cm4gdGhpcy5yZXN1bHQNCgkJdGhyb3cgcGVuZGluZyA/IHIgPT0gMHhmZmZmZmZmZiA/IE9TRXJyb3IoKSA6IFRpbWVvdXRFcnJvcigpIDogKHRoaXMudGhyb3duIDo9IHRydWUpICYmIHRoaXMucmVzdWx0DQoJfQ0KCXN0YXRpYyB0aHJvdygpIHsNCgkJdGhyb3cgdGhpcw0KCX0NCgkvKioNCgkgKiBDcmVhdGVzIGEgbmV3IHJlc29sdmVkIHByb21pc2UgZm9yIHRoZSBwcm92aWRlZCB2YWx1ZS4NCgkgKiBAcGFyYW0gdmFsdWUgVGhlIHZhbHVlIHRoZSBwcm9taXNlIHdhcyByZXNvbHZlZC4NCgkgKiBAcmV0dXJucyB7UHJvbWlzZX0gQSBuZXcgcmVzb2x2ZWQgUHJvbWlzZS4NCgkgKi8NCglzdGF0aWMgcmVzb2x2ZSh2YWx1ZSkgPT4geyBiYXNlOiB0aGlzLlByb3RvdHlwZSwgcmVzdWx0OiB2YWx1ZSwgc3RhdHVzOiAnZnVsZmlsbGVkJyB9DQoJLyoqDQoJICogQ3JlYXRlcyBhIG5ldyByZWplY3RlZCBwcm9taXNlIGZvciB0aGUgcHJvdmlkZWQgcmVhc29uLg0KCSAqIEBwYXJhbSByZWFzb24gVGhlIHJlYXNvbiB0aGUgcHJvbWlzZSB3YXMgcmVqZWN0ZWQuDQoJICogQHJldHVybnMge1Byb21pc2V9IEEgbmV3IHJlamVjdGVkIFByb21pc2UuDQoJICovDQoJc3RhdGljIHJlamVjdChyZWFzb24pID0+IFByb21pc2UoKF8sIHJlamVjdCkgPT4gcmVqZWN0KHJlYXNvbikpDQoJLyoqDQoJICogQ3JlYXRlcyBhIFByb21pc2UgdGhhdCBpcyByZXNvbHZlZCB3aXRoIGFuIGFycmF5IG9mIHJlc3VsdHMgd2hlbiBhbGwgb2YgdGhlIHByb3ZpZGVkIFByb21pc2VzDQoJICogcmVzb2x2ZSwgb3IgcmVqZWN0ZWQgd2hlbiBhbnkgUHJvbWlzZSBpcyByZWplY3RlZC4NCgkgKiBAcGFyYW0ge0FycmF5fSBwcm9taXNlcyBBbiBhcnJheSBvZiBQcm9taXNlcy4NCgkgKiBAcmV0dXJucyB7UHJvbWlzZTxBcnJheT59IEEgbmV3IFByb21pc2UuDQoJICovDQoJc3RhdGljIGFsbChwcm9taXNlcykgew0KCQlyZXR1cm4gUHJvbWlzZShleGVjdXRvcikNCgkJZXhlY3V0b3IocmVzb2x2ZSwgcmVqZWN0KSB7DQoJCQlyZXMgOj0gW10sIGNvdW50IDo9IHJlcy5MZW5ndGggOj0gcHJvbWlzZXMuTGVuZ3RoDQoJCQlyZXNvbHZlMiA6PSAoaW5kZXgsIHZhbCkgPT4gKHJlc1tpbmRleF0gOj0gdmFsLCAhLS1jb3VudCAmJiByZXNvbHZlKHJlcykpDQoJCQlmb3IgdmFsIGluIHByb21pc2VzIHsNCgkJCQlpZiB2YWwgaXMgUHJvbWlzZQ0KCQkJCQl2YWwub25TZXR0bGVkKHJlc29sdmUyLkJpbmQoQV9JbmRleCksIHJlamVjdCkNCgkJCQllbHNlIHJlc29sdmUyKEFfSW5kZXgsIHZhbCkNCgkJCX0gZWxzZSByZXNvbHZlKHJlcykNCgkJfQ0KCX0NCgkvKioNCgkgKiBDcmVhdGVzIGEgUHJvbWlzZSB0aGF0IGlzIHJlc29sdmVkIHdpdGggYW4gYXJyYXkgb2YgcmVzdWx0cyB3aGVuIGFsbA0KCSAqIG9mIHRoZSBwcm92aWRlZCBQcm9taXNlcyByZXNvbHZlIG9yIHJlamVjdC4NCgkgKiBAcGFyYW0ge0FycmF5fSBwcm9taXNlcyBBbiBhcnJheSBvZiBQcm9taXNlcy4NCgkgKiBAcmV0dXJucyB7UHJvbWlzZTxBcnJheTx7c3RhdHVzOiBTdHJpbmcsIHJlc3VsdDogQW55fT4+fSBBIG5ldyBQcm9taXNlLg0KCSAqLw0KCXN0YXRpYyBhbGxTZXR0bGVkKHByb21pc2VzKSB7DQoJCXJldHVybiBQcm9taXNlKGV4ZWN1dG9yKQ0KCQlleGVjdXRvcihyZXNvbHZlLCByZWplY3QpIHsNCgkJCXJlcyA6PSBbXSwgY291bnQgOj0gcmVzLkxlbmd0aCA6PSBwcm9taXNlcy5MZW5ndGgNCgkJCWNhbGxiYWNrIDo9IChpbmRleCwgdmFsKSA9PiAocmVzW2luZGV4XSA6PSB7IHJlc3VsdDogdmFsLnJlc3VsdCwgc3RhdHVzOiB2YWwuc3RhdHVzIH0sICEtLWNvdW50ICYmIHJlc29sdmUocmVzKSkNCgkJCWZvciB2YWwgaW4gcHJvbWlzZXMgew0KCQkJCWlmIHZhbCBpcyBQcm9taXNlDQoJCQkJCXZhbC5vbkNvbXBsZXRlZChjYWxsYmFjay5CaW5kKEFfSW5kZXgpKQ0KCQkJCWVsc2UgcmVzW0FfSW5kZXhdIDo9IHsgcmVzdWx0OiB2YWwsIHN0YXR1czogJ2Z1bGZpbGxlZCcgfSwgIS0tY291bnQgJiYgcmVzb2x2ZShyZXMpDQoJCQl9IGVsc2UgcmVzb2x2ZShyZXMpDQoJCX0NCgl9DQoJLyoqDQogICAgICogVGhlIGFueSBmdW5jdGlvbiByZXR1cm5zIGEgcHJvbWlzZSB0aGF0IGlzIGZ1bGZpbGxlZCBieSB0aGUgZmlyc3QgZ2l2ZW4gcHJvbWlzZSB0byBiZSBmdWxmaWxsZWQsIG9yIHJlamVjdGVkIHdpdGggYW4gQWdncmVnYXRlRXJyb3IgY29udGFpbmluZyBhbiBhcnJheSBvZiByZWplY3Rpb24gcmVhc29ucyBpZiBhbGwgb2YgdGhlIGdpdmVuIHByb21pc2VzIGFyZSByZWplY3RlZC4gSXQgcmVzb2x2ZXMgYWxsIGVsZW1lbnRzIG9mIHRoZSBwYXNzZWQgaXRlcmFibGUgdG8gcHJvbWlzZXMgYXMgaXQgcnVucyB0aGlzIGFsZ29yaXRobS4NCiAgICAgKiBAcGFyYW0ge0FycmF5PFByb21pc2U+fSBwcm9taXNlcyBBbiBhcnJheSBvZiBQcm9taXNlcy4NCiAgICAgKiBAcmV0dXJucyB7UHJvbWlzZX0gQSBuZXcgUHJvbWlzZS4NCiAgICAgKi8NCglzdGF0aWMgYW55KHByb21pc2VzKSB7DQoJCXJldHVybiBQcm9taXNlKGV4ZWN1dG9yKQ0KCQlleGVjdXRvcihyZXNvbHZlLCByZWplY3QpIHsNCgkJCWVycnMgOj0gW10sIGNvdW50IDo9IGVycnMuTGVuZ3RoIDo9IHByb21pc2VzLkxlbmd0aA0KCQkJcmVqZWN0MiA6PSAoaW5kZXgsIGVycikgPT4gKGVycnNbaW5kZXhdIDo9IGVyciwgIS0tY291bnQgJiYgKA0KCQkJCWVyciA6PSBFcnJvcignQWxsIHByb21pc2VzIHdlcmUgcmVqZWN0ZWQnKSwgZXJyLmVycm9ycyA6PSBlcnJzLCByZWplY3QoZXJyKSkpDQoJCQlmb3IgdmFsIGluIHByb21pc2VzDQoJCQkJdmFsLm9uU2V0dGxlZChyZXNvbHZlLCByZWplY3QyLkJpbmQoQV9JbmRleCkpDQoJCX0NCgl9DQoJLyoqDQoJICogQ3JlYXRlcyBhIFByb21pc2UgdGhhdCBpcyByZXNvbHZlZCBvciByZWplY3RlZCB3aGVuIGFueSBvZiB0aGUgcHJvdmlkZWQgUHJvbWlzZXMgYXJlIHJlc29sdmVkIG9yIHJlamVjdGVkLg0KCSAqIEBwYXJhbSB7QXJyYXl9IHByb21pc2VzIEFuIGFycmF5IG9mIFByb21pc2VzLg0KCSAqIEByZXR1cm5zIHtQcm9taXNlfSBBIG5ldyBQcm9taXNlLg0KCSAqLw0KCXN0YXRpYyByYWNlKHByb21pc2VzKSB7DQoJCXJldHVybiBQcm9taXNlKGV4ZWN1dG9yKQ0KCQlleGVjdXRvcihyZXNvbHZlLCByZWplY3QpIHsNCgkJCWZvciB2YWwgaW4gcHJvbWlzZXMNCgkJCQlpZiB2YWwgaXMgUHJvbWlzZQ0KCQkJCQl2YWwub25TZXR0bGVkKHJlc29sdmUsIHJlamVjdCkNCgkJCQllbHNlIHJldHVybiByZXNvbHZlKHZhbCkNCgkJfQ0KCX0NCglzdGF0aWMgdHJ5KGZuKSB7DQoJCXRyeSB7DQoJCQl2YWwgOj0gZm4oKQ0KCQkJcmV0dXJuIFByb21pc2UucmVzb2x2ZSh2YWwpDQoJCX0gY2F0Y2ggQW55IGFzIGUNCgkJCXJldHVybiBQcm9taXNlLnJlamVjdChlKQ0KCX0NCgkvKioNCgkgKiBDcmVhdGVzIGEgbmV3IFByb21pc2UgYW5kIHJldHVybnMgaXQgaW4gYW4gb2JqZWN0LCBhbG9uZyB3aXRoIGl0cyByZXNvbHZlIGFuZCByZWplY3QgZnVuY3Rpb25zLg0KCSAqIEByZXR1cm5zIHt7IHByb21pc2U6IFByb21pc2UsIHJlc29sdmU6IChkYXRhKSA9PiB2b2lkLCByZWplY3Q6IChlcnIpID0+IHZvaWQgfX0NCgkgKi8NCglzdGF0aWMgd2l0aFJlc29sdmVycygpIHsNCgkJbG9jYWwgcmVzb2x2ZXJzIDo9IDANCgkJcmVzb2x2ZXJzLnByb21pc2UgOj0gUHJvbWlzZSgocmVzb2x2ZSwgcmVqZWN0KSA9PiByZXNvbHZlcnMgOj0geyByZXNvbHZlOiByZXNvbHZlLCByZWplY3Q6IHJlamVjdCB9KQ0KCQlyZXR1cm4gcmVzb2x2ZXJzDQoJfQ0KfQ==
              )"
      ;web2 的 dll 依赖（WebView2Loader.dll base64）
      ,web_view2_dll:"
              ( LTrim Join
                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Lz0AACU9AAA+Pj0APDw9ACY9AAB8PQAAXj0AAGB2ZnRhYmxlJwAAAAAAAABgdmJ0YWJsZScAAAAAAAAAYHZjYWxsJwBgdHlwZW9mJwAAAAAAAAAAYGxvY2FsIHN0YXRpYyBndWFyZCcAAAAAYHN0cmluZycAAAAAAAAAAGB2YmFzZSBkZXN0cnVjdG9yJwAAAAAAAGB2ZWN0b3IgZGVsZXRpbmcgZGVzdHJ1Y3RvcicAAAAAYGRlZmF1bHQgY29uc3RydWN0b3IgY2xvc3VyZScAAABgc2NhbGFyIGRlbGV0aW5nIGRlc3RydWN0b3InAAAAAGB2ZWN0b3IgY29uc3RydWN0b3IgaXRlcmF0b3InAAAAYHZlY3RvciBkZXN0cnVjdG9yIGl0ZXJhdG9yJwAAAABgdmVjdG9yIHZiYXNlIGNvbnN0cnVjdG9yIGl0ZXJhdG9yJwAAAAAAYHZpcnR1YWwgZGlzcGxhY2VtZW50IG1hcCcAAAAAAABgZWggdmVjdG9yIGNvbnN0cnVjdG9yIGl0ZXJhdG9yJwAAAAAAAAAAYGVoIHZlY3RvciBkZXN0cnVjdG9yIGl0ZXJhdG9yJwBgZWggdmVjdG9yIHZiYXNlIGNvbnN0cnVjdG9yIGl0ZXJhdG9yJwAAYGNvcHkgY29uc3RydWN0b3IgY2xvc3VyZScAAAAAAABgdWR0IHJldHVybmluZycAYEVIAGBSVFRJAAAAAAAAAGBsb2NhbCB2ZnRhYmxlJwBgbG9jYWwgdmZ0YWJsZSBjb25zdHJ1Y3RvciBjbG9zdXJlJwAgbmV3W10AAAAAAAAgZGVsZXRlW10AAAAAAAAAYG9tbmkgY2FsbHNpZycAAGBwbGFjZW1lbnQgZGVsZXRlIGNsb3N1cmUnAAAAAAAAYHBsYWNlbWVudCBkZWxldGVbXSBjbG9zdXJlJwAAAABgbWFuYWdlZCB2ZWN0b3IgY29uc3RydWN0b3IgaXRlcmF0b3InAAAAYG1hbmFnZWQgdmVjdG9yIGRlc3RydWN0b3IgaXRlcmF0b3InAAAAAGBlaCB2ZWN0b3IgY29weSBjb25zdHJ1Y3RvciBpdGVyYXRvcicAAABgZWggdmVjdG9yIHZiYXNlIGNvcHkgY29uc3RydWN0b3IgaXRlcmF0b3InAAAAAABgZHluYW1pYyBpbml0aWFsaXplciBmb3IgJwAAAAAAAGBkeW5hbWljIGF0ZXhpdCBkZXN0cnVjdG9yIGZvciAnAAAAAAAAAABgdmVjdG9yIGNvcHkgY29uc3RydWN0b3IgaXRlcmF0b3InAAAAAAAAYHZlY3RvciB2YmFzZSBjb3B5IGNvbnN0cnVjdG9yIGl0ZXJhdG9yJwAAAAAAAAAAYG1hbmFnZWQgdmVjdG9yIGNvcHkgY29uc3RydWN0b3IgaXRlcmF0b3InAAAAAAAAYGxvY2FsIHN0YXRpYyB0aHJlYWQgZ3VhcmQnAAAAAABvcGVyYXRvciAiIiAAAAAAb3BlcmF0b3IgY29fYXdhaXQAAAAAAAAAb3BlcmF0b3I8PT4AAAAAACBUeXBlIERlc2NyaXB0b3InAAAAAAAAACBCYXNlIENsYXNzIERlc2NyaXB0b3IgYXQgKAAAAAAAIEJhc2UgQ2xhc3MgQXJyYXknAAAAAAAAIENsYXNzIEhpZXJhcmNoeSBEZXNjcmlwdG9yJwAAAAAgQ29tcGxldGUgT2JqZWN0IExvY2F0b3InAAAAAAAAAGBhbm9ueW1vdXMgbmFtZXNwYWNlJwAAAAAAAAAAAAAAIIUBgAEAAABghQGAAQAAAJiFAYABAAAA0IUBgAEAAAAghgGAAQAAAICGAYABAAAA0IYBgAEAAAAQhwGAAQAAAFCHAYABAAAAkIcBgAEAAADQhwGAAQAAABCIAYABAAAAYIgBgAEAAADAiAGAAQAAABCJAYABAAAAYIkBgAEAAAB4iQGAAQAAAJCJAYABAAAAqIkBgAEAAADAiQGAAQAAAAiKAYABAAAAAAAAAAAAAABhAHAAaQAtAG0AcwAtAHcAaQBuAC0AYwBvAHIAZQAtAGQAYQB0AGUAdABpAG0AZQAtAGwAMQAtADEALQAxAAAAYQBwAGkALQBtAHMALQB3AGkAbgAtAGMAbwByAGUALQBmAGkAbABlAC0AbAAxAC0AMgAtADQAAABhAHAAaQAtAG0AcwAtAHcAaQBuAC0AYwBvAHIAZQAtAGYAaQBsAGUALQBsADEALQAyAC0AMgAAAGEAcABpAC0AbQBzAC0AdwBpAG4ALQBjAG8AcgBlAC0AbABvAGMAYQBsAGkAegBhAHQAaQBvAG4ALQBsADEALQAyAC0AMQAAAAAAAAAAAAAAYQBwAGkALQBtAHMALQB3AGkAbgAtAGMAbwByAGUALQBsAG8AYwBhAGwAaQB6AGEAdABpAG8AbgAtAG8AYgBzAG8AbABlAHQAZQAtAGwAMQAtADIALQAwAAAAAAAAAAAAYQBwAGkALQBtAHMALQB3AGkAbgAtAGMAbwByAGUALQBwAHIAbwBjAGUAcwBzAHQAaAByAGUAYQBkAHMALQBsADEALQAxAC0AMgAAAAAAAABhAHAAaQAtAG0AcwAtAHcAaQBuAC0AYwBvAHIAZQAtAHMAdAByAGkAbgBnAC0AbAAxAC0AMQAtADAAAAAAAAAAYQBwAGkALQBtAHMALQB3AGkAbgAtAGMAbwByAGUALQBzAHkAbgBjAGgALQBsADEALQAyAC0AMAAAAAAAAAAAAGEAcABpAC0AbQBzAC0AdwBpAG4ALQBjAG8AcgBlAC0AcwB5AHMAaQBuAGYAbwAtAGwAMQAtADIALQAxAAAAAABhAHAAaQAtAG0AcwAtAHcAaQBuAC0AYwBvAHIAZQAtAHcAaQBuAHIAdAAtAGwAMQAtADEALQAwAAAAAAAAAAAAYQBwAGkALQBtAHMALQB3AGkAbgAtAGMAbwByAGUALQB4AHMAdABhAHQAZQAtAGwAMgAtADEALQAwAAAAAAAAAGEAcABpAC0AbQBzAC0AdwBpAG4ALQByAHQAYwBvAHIAZQAtAG4AdAB1AHMAZQByAC0AdwBpAG4AZABvAHcALQBsADEALQAxAC0AMAAAAAAAYQBwAGkALQBtAHMALQB3AGkAbgAtAHMAZQBjAHUAcgBpAHQAeQAtAHMAeQBzAHQAZQBtAGYAdQBuAGMAdABpAG8AbgBzAC0AbAAxAC0AMQAtADAAAAAAAAAAAAAAAAAAZQB4AHQALQBtAHMALQB3AGkAbgAtAG4AdAB1AHMAZQByAC0AZABpAGEAbABvAGcAYgBvAHgALQBsADEALQAxAC0AMAAAAAAAAAAAAAAAAABlAHgAdAAtAG0AcwAtAHcAaQBuAC0AbgB0AHUAcwBlAHIALQB3AGkAbgBkAG8AdwBzAHQAYQB0AGkAbwBuAC0AbAAxAC0AMQAtADAAAAAAAGEAZAB2AGEAcABpADMAMgAAAAAAAAAAAGsAZQByAG4AZQBsADMAMgAAAAAAAAAAAGsAZQByAG4AZQBsAGIAYQBzAGUAAAAAAG4AdABkAGwA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NAAxADcAOAAxADgAfQAAAFMAbwBmAHQAdwBhAHIAZQBcAE0AaQBjAHIAbwBzAG8AZgB0AFwARQBkAGcAZQBVAHAAZABhAHQAZQBcAEMAbABpAGUAbgB0AHMAXAB7ADUANgBFAEIAMQA4AEYAOAAtAEIAMAAwADgALQA0AEMAQgBEAC0AQgA2AEQAMgAtADgAQwA5ADcARgBFADcARQA5ADAANgAyAH0AAAAAAAAAAABTAG8AZgB0AHcAYQByAGUAXABNAGkAYwByAG8AcwBvAGYAdABcAEUAZABnAGUAVQBwAGQAYQB0AGUAXABDAGwAaQBlAG4AdABTAHQAYQB0AGUAXAAAAAAAYgBlAHQAYQAAAGQAZQB2AAAAYwBhAG4AYQByAHkAAABpAG4AdABlAHIAbgBhAGwAAABcAAAAV2ViVmlldzI6IEZhaWxlZCB0byBmaW5kIHRoZSBhcHAgZXhlIHBhdGguCgBXZWJWaWV3MjogRmFpbGVkIHRvIGZpbmQgdGhlIFdlYlZpZXcyIGNsaWVudCBkbGwgYXQ6IAAKAEdldEZpbGVWZXJzaW9uSW5mb1NpemVXAEdldEZpbGVWZXJzaW9uSW5mb1cAVmVyUXVlcnlWYWx1ZVcAAFwAUwB0AHIAaQBuAGcARgBpAGwAZQBJAG4AZgBvAFwAMAA0ADAAOQAwADQAQgAwAFwAUAByAG8AZAB1AGMAdABWAGUAcgBzAGkAbwBuAAAAAABMOaIO5pbjSo+ahHOr7zcyIAAAAFdlYlZpZXcyOiBGYWlsZWQgdG8gZmluZCBhbiBpbnN0YWxsZWQgV2ViVmlldzIgcnVudGltZSBvciBub24tc3RhYmxlIE1pY3Jvc29mdCBFZGdlIGluc3RhbGxhdGlvbi4KAACfU43En+McRK5oH2blcL3FV2ViVmlldzI6IHNraXBwZWQgaW5hY2Nlc3NpYmxlIABhAHAAaQAtAG0AcwAtAHcAaQBuAC0AYwBvAHIAZQAtAHYAZQByAHMAaQBvAG4ALQBsADEALQAxAC0AMAAuAGQAbABsAAAAdgBlAHIAcwBpAG8AbgAuAGQAbABsAAAATQBpAGMAcgBvAHMAbwBmAHQALgBXAGUAYgBWAGkAZQB3ADIAUgB1AG4AdABpAG0AZQAuAFMAdABhAGIAbABlAF8AOAB3AGUAawB5AGIAMwBkADgAYgBiAHcAZQAAAE0AaQBjAHIAbwBzAG8AZgB0AC4AVwBlAGIAVgBpAGUAdwAyAFIAdQBuAHQAaQBtAGUALgBCAGUAdABhAF8AOAB3AGUAawB5AGIAMwBkADgAYgBiAHcAZQAAAE0AaQBjAHIAbwBzAG8AZgB0AC4AVwBlAGIAVgBpAGUAdwAyAFIAdQBuAHQAaQBtAGUALgBEAGUAdgBfADgAdwBlAGsAeQBiADMAZAA4AGIAYgB3AGUAAABNAGkAYwByAG8AcwBvAGYAdAAuAFcAZQBiAFYAaQBlAHcAMgBSAHUAbgB0AGkAbQBlAC4AQwBhAG4AYQByAHkAXwA4AHcAZQBrAHkAYgAzAGQAOABiAGIAdwBlAAAATQBpAGMAcgBvAHMAbwBmAHQALgBXAGUAYgBWAGkAZQB3ADIAUgB1AG4AdABpAG0AZQAuAEkAbgB0AGUAcgBuAGEAbABfADgAdwBlAGsAeQBiADMAZAA4AGIAYgB3AGUAAAAAAGwAbwBjAGEAdABpAG8AbgAAAAAAcAB2AAAAAAAAAAAAVgAAAAAAAABoAgAAAAAAAFdlYlZpZXcyOiBza2lwcGVkIGFuIGluY29tcGF0aWJsZSB2ZXJzaW9uIAAALgAAAFRyeUNyZWF0ZVBhY2thZ2VEZXBlbmRlbmN5AABrAGUAcgBuAGUAbABiAGEAcwBlAC4AZABsAGwAAABBZGRQYWNrYWdlRGVwZW5kZW5jeQBHZXRDdXJyZW50UGFja2FnZUluZm8AAEEARABWAEEAUABJADMAMgAuAGQAbABsAAAARXZlbnRSZWdpc3RlcgAAAF51bbkZA5JOopYjQ29GofxHZXRDdXJyZW50QXBwbGljYXRpb25Vc2VyTW9kZWxJZAAASwBlAHIAbgBlAGwAMwAyAC4AZABsAGwAAABCAHIAbwB3AHMAZQByAEUAeABlAGMAdQB0AGEAYgBsAGUARgBvAGwAZABlAHIAAABXAEUAQgBWAEkARQBXADIAXwBCAFIATwBXAFMARQBSAF8ARQBYAEUAQwBVAFQAQQBCAEwARQBfAEYATwBMAEQARQBSAAAAVQBzAGUAcgBEAGEAdABhAEYAbwBsAGQAZQByAAAAVwBFAEIAVgBJAEUAVwAyAF8AVQBTAEUAUgBfAEQAQQBUAEEAXwBGAE8ATABEAEUAUgAAAFIAZQBsAGUAYQBzAGUAQwBoAGEAbgBuAGUAbABzAAAAVwBFAEIAVgBJAEUAVwAyAF8AUgBFAEwARQBBAFMARQBfAEMASABBAE4ATgBFAEwAUwAAAEMAaABhAG4AbgBlAGwAUwBlAGEAcgBjAGgASwBpAG4AZAAAAFcARQBCAFYASQBFAFcAMgBfAEMASABBAE4ATgBFAEwAXwBTAEUAQQBSAEMASABfAEsASQBOAEQAAABSAGUAbABlAGEAcwBlAEMAaABhAG4AbgBlAGwAUAByAGUAZgBlAHIAZQBuAGMAZQAAAFcARQBCAFYASQBFAFcAMgBfAFIARQBMAEUAQQBTAEUAXwBDAEgAQQBOAE4ARQBMAF8AUABSAEUARgBFAFIARQBOAEMARQAAAHMAaABlAGwAbAAzADIALgBkAGwAbAAAAEdldEN1cnJlbnRQcm9jZXNzRXhwbGljaXRBcHBVc2VyTW9kZWxJRABTAG8AZgB0AHcAYQByAGUAXABQAG8AbABpAGMAaQBlAHMAXABNAGkAYwByAG8AcwBvAGYAdABcAEUAZABnAGUAXABXAGUAYgBWAGkAZQB3ADIAXAAAAAAAKgAAAFcARQBCAFYASQBFAFcAMgBfAFUAUwBFAF8ARQBEAEcARQBfAFYASQBFAFcAAAAxAAAAAAAwMTIzNDU2Nzg5QUJDREVGAENyZWF0ZVdlYlZpZXdFbnZpcm9ubWVudFdpdGhPcHRpb25zSW50ZXJuYWwAAFcAZQBiAFYAaQBlAHcAMgA6ACAAQwBvAHIAZQBXAGUAYgBWAGkAZQB3ADIARQBuAHYAaQByAG8AbgBtAGUAbgB0ACAAZgBhAGkAbABlAGQAIAB3AGgAZQBuACAAdAByAHkAaQBuAGcAIAB0AG8AIABjAGEAbABsACAAaQBuAHQAbwAgAEUAbQBiAGUAZABkAGUAZABCAHIAbwB3AHMAZQByAFcAZQBiAFYAaQBlAHcALgBkAGwAbAAuACAAaAByAD0AMAB4AAAACgAAAERsbENhblVubG9hZE5vdwBXAGUAYgBWAGkAZQB3ADIAOgAgAEMAbwByAGUAVwBlAGIAVgBpAGUAdwAyAEUAbgB2AGkAcgBvAG4AbQBlAG4AdAAgAGYAYQBpAGwAZQBkACAAdwBoAGUAbgAgAHQAcgB5AGkAbgBnACAA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c0ZyZWUAtgFGbHNHZXRWYWx1ZQC3AUZsc1NldFZhbHVlALkBRmx1c2hGaWxlQnVmZmVycwAAxAFGcmVlRW52aXJvbm1lbnRTdHJpbmdzVwDFAUZyZWVMaWJyYXJ5AMwBR2V0QUNQAADbAUdldENQSW5mbwDwAUdldENvbW1hbmRMaW5lQQDxAUdldENvbW1hbmRMaW5lVwAWAkdldENvbnNvbGVNb2RlAAAaAkdldENvbnNvbGVPdXRwdXRDUAAAMgJHZXRDdXJyZW50UHJvY2VzcwAzAkdldEN1cnJlbnRQcm9jZXNzSWQANwJHZXRDdXJyZW50VGhyZWFkSWQAAFMCR2V0RW52aXJvbm1lbnRTdHJpbmdzVwAAVQJHZXRFbnZpcm9ubWVudFZhcmlhYmxlVwBhAkdldEZpbGVBdHRyaWJ1dGVzVwAAagJHZXRGaWxlVHlwZQB9AkdldExhc3RFcnJvcgAAkQJHZXRNb2R1bGVGaWxlTmFtZVcAAJQCR2V0TW9kdWxlSGFuZGxlRXhXAACVAkdldE1vZHVsZUhhbmRsZVcAALYCR2V0T0VNQ1AAAM0CR2V0UHJvY0FkZHJlc3MAANQCR2V0UHJvY2Vzc0hlYXAAAPECR2V0U3RhcnR1cEluZm9XAPMCR2V0U3RkSGFuZGxlAAD4AkdldFN0cmluZ1R5cGVXAAAEA0dldFN5c3RlbUluZm8ACgNHZXRTeXN0ZW1UaW1lQXNGaWxlVGltZQBsA0hlYXBBbGxvYwBwA0hlYXBGcmVlAABzA0hlYXBSZUFsbG9jAHUDSGVhcFNpemUAAIYDSW5pdGlhbGl6ZUNyaXRpY2FsU2VjdGlvbkFuZFNwaW5Db3VudACKA0luaXRpYWxpemVTTGlzdEhlYWQAjgNJbnRlcmxvY2tlZEZsdXNoU0xpc3QAoANJc0RlYnVnZ2VyUHJlc2VudACoA0lzUHJvY2Vzc29yRmVhdHVyZVByZXNlbnQArgNJc1ZhbGlkQ29kZVBhZ2UA1ANMQ01hcFN0cmluZ1cAAOADTGVhdmVDcml0aWNhbFNlY3Rpb24AAOUDTG9hZExpYnJhcnlFeEEAAOYDTG9hZExpYnJhcnlFeFcAAOcDTG9hZExpYnJhcnlXAAASBE11bHRpQnl0ZVRvV2lkZUNoYXIAOQRPdXRwdXREZWJ1Z1N0cmlu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OEMAAAAAAAAAAAAAAAAAAAAAAADAOgIAAAAAAP////8AAAAAGAAAAGxCAAAAAAAAAAAAAAAAAAAAAAAAJEMAAAAAAAC4JAIAAAAAAAAAAAAAAAAAAAAAAAMAAADYJAIASCQCAHAkAgAAAAAAAAAAAAAAAAAAAAAAAAAAAOg6AgAAAAAA/////wAAAAAYAAAAlEMAAAAAAAAAAAAAAAAAAAAAAAAkQwAAAAAAACAlAgAAAAAAAAAAAAAAAAAAAAAAAgAAADglAgBwJAIAAAAAAAAAAAAAAAAAAAAAABg7AgAAAAAA/////wAAAAAYAAAA/J0AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACA/////wAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAMqLfLZkrAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAM1dINJm1P//AQAAAAIAAAAAAAgAAAAAAAAAAAIAAAAAAgAAAP////8AAAAAAAAAAP////8AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEAAAAAAAACAgICAgICAgICAgICAgICAgICAgICAgICAgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA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AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAUmV0cG9saW5lVjEAEAAAABcAAAAFAAAAMwAAABAAAAAZAAAABQAAABcAAAAQAAAAIwAAAAUAAABMAAAAAAAAAFJldHBvbGluZVYxABAAAAADAAAABAAAABAAAABSZXRwb2xpbmVWMQAAAAAAAAAAAFJldHBvbGluZVYxABAAAAADAAAACAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA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oKywrMCs0KzgrPCsAK0QrSCtMK1ArVCtYK1wrYCtkK0AgAEA6AAAAHCkeKSApIikkKSYpKCkqKSwpLikwKTIpNCk2KTgpOik8KT4pAClCKUQpdiq4KroqvCqQKtIq1CrWKtgq2ircKt4q4CriKuQq5iroKuoq7CruKvAq8ir0KvYq+Cr6Kvwq/irAKwIrBCsGKwgrCisMKw4rECsSKxQrFisYKxorHCseKyArIiskKygrKissKy4rMCsyKzQrNis4KzorPCs+KwArQitEK0YrSCtKK0wrTitQK1IrVCtWK1grWitcK14rYCtiK2QrZitoK2orbCtuK3Arcit0K3YreCt6K3wrfitAJABAJQAAAA4q0CrSKvwq/irCKwYrCisOKxIrFisaKx4rIismKyorLisyKzYrOis+KwIrRitKK04rUitWK1orXitiK2YraituK3Irdit6K34rQiuGK4orjiuSK5YrmiueK6IrpiuqK64rsiu2K7orviuCK8YryivOK9Ir1ivaK94r4ivmK+or7ivyK/Yr+iv+K8AAACgAQBQAQAACKAYoCigOKBIoFigaKB4oIigmKCooLigyKDYoOig+KAIoRihKKE4oUihWKFooXihiKGYoaihuKHIodih6KH4oQiiGKIoojiiSKJYomiieKKIopiiqKK4osii2KLooviiCKMYoyijOKNIo1ijaKN4o4ijmKOoo7ijyKPYo+ij+KMIpBikKKQ4pEikWKRopHikiKSYpKikuKTIpNik6KT4pAilGKUopTilSKVYpWileKWIpZilqKW4pcil2KXopfilCKYYpiimOKZIplimaKZ4poimmKaoprimyKbYpuim+KYIpxinKKc4p0inWKdop3iniKeYp6inuKfIp9in6Kf4pwioGKgoqDioSKhYqGioeKiIqJioqKi4qMio2KjoqPioCKkYqSipOKlIqVipaKl4qYipmKmoqbipyKnYqeip+KkIqhiqKKo4qgCwAQA8AQAAYKZwpoCmkKagprCmwKbQpuCm8KYApxCnIKcwp0CnUKdgp3CngKeQp6CnsKfAp9Cn4KfwpwCoEKggqDCoQKhQqGCocKiAqJCooKiwqMCo0KjgqPCoAKkQqSCpMKlAqVCpYKlwqYCpkKmgqbCpwKnQqeCp8KkAqhCqIKowqkCqUKpgqnCqgKqQqqCqsKrAqtCq4KrwqgCrEKsgqzCrQKtQq2CrcKuAq5CroKuwq8Cr0Kvgq/CrAKwQrCCsMKxArFCsYKxwrICskKygrLCswKzQrOCs8KwArRCtIK0wrUCtUK1grXCtgK2QraCtsK3ArdCt4K3wrQCuEK4grjCuQK5QrmCucK6ArpCuoK6wrsCu0K7grvCuAK8QryCvMK9Ar1CvYK9wr4CvkK+gr7CvwK/Qr+Cv8K8AwAEAnAAAAACgEKAgoDCgQKBQoGCgcKCAoJCgoKCwoMCg0KDgoPCgAKEQoSChMKFAoVChYKFwoYChkKGgobChwKHQoeCh8KEAohCiIKIwokCiUKJgonCigKKQoqCisKLAotCi4KLwogCjEKMgozCjQKNQo2CjcKOAo5CjoKOwo8Cj0KPgo/CjAKQQpCCkMKRApFCkYKRwpICkkKQA4AEAHAAAANCp2Kngqeip8KkAqgiqEKoYqiCqAPABABAAAABQqFioYKhoqAAAAgAgAAAAAKIIohCiGKIgojCiUKJYomCiiKKQopiiADACAGgAAAAApkimaKaIpqimyKb4phCnGKcgp1inYKeAqKCoqKiwqLiowKjIqNCo2KjgqOio+KgAqQipEKkYqSCpKKkwqWCqmKrAquiqGKtAq3CreKuAq4irkKuYq6CrqKu4q8CrAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABIKAAAAAICADCCKDUGCSqGSIb3DQEHAqCCKCYwgigiAgEBMQ8wDQYJYIZIAWUDBAIBBQAwXAYKKwYBBAGCNwIBBKBOMEwwFwYKKwYBBAGCNwIBDzAJAwEAoASiAoAAMDEwDQYJYIZIAWUDBAIBBQAEIDQfz6KA2Xj4k7jkV6Tyha522SC31vjc87gyhmt1AfNBoIINdjCCBfQwggPcoAMCAQICEzMAAAP+a87a1sgDA6MAAAAAA/4wDQYJKoZIhvcNAQELBQAwfjELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEoMCYGA1UEAxMfTWljcm9zb2Z0IENvZGUgU2lnbmluZyBQQ0EgMjAxMTAeFw0yNDA4MjIxOTI2NDRaFw0yNTA4MjAxOTI2NDRaMHQxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xHjAcBgNVBAMTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBAL+L3CPiLKJByBRfAZLtKUChuO/NvLMqhgX40jAA1tjK9BzvXBiLsHh/kqpoe0XIarsjQ38OiSmyMPhHAAtckAUfPZhXZVS1r3rIjkPxD4OepdxPWhGvp/eGq0xIdP21YziWmPaiObybCvpBX0qq239/yVhcPg/j+Tqo54DZeTI3R2J1k8CQJG+sZ9ZeM43EUNw32KC1s1511QmSR/JWw2+L4CynpRpZaJD3H+5GrKGiN988PgPw1nCTsl9N72xiNlblgddEXW8zda4hoeZ2OdM3xA45BUUEpeLnABQRR+YT3swazlV/wMxVnXjP95FusxabeR1BXrfaAZYiPw6xmj8CAwEAAaOCAXMwggFvMB8GA1UdJQQYMBYGCisGAQQBgjcKAxUGCCsGAQUFBwMDMB0GA1UdDgQWBBToyo0ohzsfveYNzKOzegOBWC+SiDBFBgNVHREEPjA8pDowODEeMBwGA1UECxMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMRYwFAYDVQQFEw0yMzAyMTcrNTAyNzIzMB8GA1UdIwQYMBaAFEhuZOVQBdOCqhc3NyK1bajKdQKVMFQGA1UdHwRNMEswSaBHoEWGQ2h0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY3JsL01pY0NvZFNpZ1BDQTIwMTFfMjAxMS0wNy0wOC5jcmwwYQYIKwYBBQUHAQEEVTBTMFEGCCsGAQUFBzAChkVodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NlcnRzL01pY0NvZFNpZ1BDQTIwMTFfMjAxMS0wNy0wOC5jcnQwDAYDVR0TAQH/BAIwADANBgkqhkiG9w0BAQsFAAOCAgEAnIR/SQAbK9G11GTIzos/nW64VKzlrmS6di1V2BB64F9uuROYKC1xj9gBqhJOOLQrCAeTOMAT/yFyiEnIla46zge0ejLJEhHMCRG4RRoV84auIrxFQT1KuKWmUhvsfuJXgN/XFKupfYyJancgvSWmkNuOVwlY8bIojYedZszKAMcNgCpe2/n71thxVWEUkugVqUM529cUHLd+c9HDL2lBTXkhWH6T6J9Tlne62OQnuk4/ReEA2YeJugjzTI4dLiYyuBNQdMVIS0ex+q4oVoO080yrfR0+4DLD1ClWO5jLoaJjvpcDjYpCXZUldKP8cDkgQyhK4xc62KwmSN27fCJfdbhhwxJ/kUPBUzJaqxJm1Z209/FUrdFdkDkNxuF84prW4EP8rkFxRIk2XFydT/7gfloV65va/51fTx86MLKAO5y18HJjafaR46uDXDc5VFyuh8K8gqyYHdvj253Qfu3CoQasMzCxXs9mgvj2fhQqEWxAeE+AvbQHF3hv/xLbJErdEyg2Dak2U+gb3EF1b6eNi6UKw4RBr3YMwJKtN3n+w5sr9xu4plZWZOqDh25vaC/ubVRFYe390TIJ/j8jAk8HSKRs/92RxrlSoAZbT//CFQVIDOx2PdApEoNRVBjKp5ml4J7shSlUML1WowDSEpz5itbwfEqXbLtow7qDQ7lPjS0wggd6MIIFYqADAgECAgphDpDSAAAAAAADMA0GCSqGSIb3DQEBCwUAMIGIMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUm9vdCBDZXJ0aWZpY2F0ZSBBdXRob3JpdHkgMjAxMTAeFw0xMTA3MDgyMDU5MDlaFw0yNjA3MDgyMTA5MDlaMH4xCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKDAmBgNVBAMTH01pY3Jvc29mdCBDb2RlIFNpZ25pbmcgUENBIDIwMTEwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQCr8PpyEBwurdhuqoIQTTS68rZYIZ9CGypr6VpQqrgGOBoESbp/wwwe3TdrxhLYC/A4wpkGsMg51QEUMULTiQ15ZId+lGAkbK+eSZzpaF7S35tTsgosw6/ZqSuuegmv15ZZymAaBelmdugyUiYSL+erCFDPs0S3XdjELgN1q2jzy23zOlyhFvRGuuA4ZKxuZDV4pqBjDy3TQJP4494HDdVceaVJKecNvqATd76UPe/74ytaEB9NViiienLgEjq3SV7Y7e1DkYPZe7J7hhvZPrGMXeiJT4Qa8qEvWeSQOy2uM1jFtz7+MtOzAz2xsq+SOH7SnYAs9U5WkSE1JcM5bmR/U7qcD60ZI4TL9LoDho33X/DQUr+MlIe8wCF0JV8YKLbMJyg4JZg5SjbPfLGSrhwjp6lm7GEfauEoSZ1fiOIlXdMhSz5SxLVXPyQD8NF6Wy/VI+NwXQ9RRnez+ADhvKwCgl/bwBWzvRvUVUvnOaEP6SNJvBi4RHxF5MHDcnrgcuck379GmcXvwhxX24ON7E1JMKerjt/sW5+v/N2wZuLBl4F77dbtS+dJKacTKKanfWeA5opieF+yL4TXV5xcv3coKPHtbcMojyyPQDdPweGFRInECUzF1KVDL3SV9274eCBYLBNdYJWaPk8zhNqwiBfenk70lrC8RqBsmNLg1oiMCwIDAQABo4IB7TCCAekwEAYJKwYBBAGCNxUBBAMCAQAwHQYDVR0OBBYEFEhuZOVQBdOCqhc3NyK1bajKdQKVMBkGCSsGAQQBgjcUAgQMHgoAUwB1AGIAQwBBMAsGA1UdDwQEAwIBhjAPBgNVHRMBAf8EBTADAQH/MB8GA1UdIwQYMBaAFHItOgIxkEO5FAVO4eqnxzHRI4k0MFoGA1UdHwRTMFEwT6BNoEuGSWh0dHA6Ly9jcmwubWljcm9zb2Z0LmNvbS9wa2kvY3JsL3Byb2R1Y3RzL01pY1Jvb0NlckF1dDIwMTFfMjAxMV8wM18yMi5jcmwwXgYIKwYBBQUHAQEEUjBQME4GCCsGAQUFBzAChkJodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpL2NlcnRzL01pY1Jvb0NlckF1dDIwMTFfMjAxMV8wM18yMi5jcnQwgZ8GA1UdIASBlzCBlDCBkQYJKwYBBAGCNy4DMIGDMD8GCCsGAQUFBwIBFjNodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2RvY3MvcHJpbWFyeWNwcy5odG0wQAYIKwYBBQUHAgIwNB4yIB0ATABlAGcAYQBsAF8AcABvAGwAaQBjAHkAXwBzAHQAYQB0AGUAbQBlAG4AdAAuIB0wDQYJKoZIhvcNAQELBQADggIBAGfyhqWY4FR5Gi7T2HRnIpsLlhHhY5KZQpZ90nkMkMFlXy4sPvjDctFtg/6+P+gKyju/R6mj82nbY78iNaWXXWWEkH2LRlBV2AySfNIaSxzzPEKLUtCw/WvjPgcuKZvmPRul1LUdd5Q54ulkyUQ9eHoj8xN9ppB0g430yyYCRirCihC7pKkFDJvtaPpoLpWgKj8qa1hJYx8JaW5amJbkg/TAj/NGK978O9C9Ne9uJa7lryft0N3zDq+ZKJeYTQ49C/IIidYfwzIY4vDFLc5bnrRJOQrGCsLGra7lstnbFYhRRVg4MnEnGn+x9Cf43iw6IGmYslmJaG5vp7d0w0AFBqYBKig+gj8TTWYLwLNN9eGPfxxvFX1Fp3blQCplo8NdUmKGwx1jNpeG39rz+PIWoZon4c2ll9DuXWNB41sHnIc+BncG0QaxdR8UvmFhtfDcxhsEvt9Bxw4o7t5lL+yX9qFcltgA1qFGvVnzl6UJS0gQmYAf0AApxbGbpT9Fdx41xtKiop96eiL6SJUfq/tHI4D1nvi/a7dLl+LrdXga7Oo3mXkYS//WsyNodeav+vyL6wuA6mk7r/ww7QRMjt/fdW1jkT3RnVZOT7+AVyKheBEyIXrvQQqxP/uozKRdwaGIm1dxVk5IRcBCyZt2WwqASGv9eZ/BvW1taslScxMNelDNMYIaMjCCGi4CAQEwgZUwfjELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEoMCYGA1UEAxMfTWljcm9zb2Z0IENvZGUgU2lnbmluZyBQQ0EgMjAxMQITMwAAA/5rztrWyAMDowAAAAAD/jANBglghkgBZQMEAgEFAKCB1DAZBgkqhkiG9w0BCQMxDAYKKwYBBAGCNwIBBDAcBgorBgEEAYI3AgELMQ4wDAYKKwYBBAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQgtDpyuICV48+N78ucdKkZJtu+5lrQFWaeYp8Pr5PVHLIwaAYKKwYBBAGCNwIBDDFaMFigOIA2AE0AaQBjAHIAbwBzAG8AZgB0ACAARQBkAGcAZQAgAFcAZQBiAFYAaQBlAHcAMgAgAFMARABLoRyAGmh0dHBzOi8vd3d3Lm1pY3Jvc29mdC5jb20gMA0GCSqGSIb3DQEBAQUABIIBABmpXexsd2DvJmFJAM8HgHTimT873pdaybIffc8Jj79K2p4ZE5KdXy7jnj8A/his2FUA49W6fQ5QiiyzOecakqFotosW24ZQgVDmKkN7IFYQkFwbrvRaFx2N7OyyBYdO7xxR8ZUSPZoN9meZPHyOE5xnEig/QXVwdg6e/U4bGTxTTRuYv+htZzDHkQiZhqr8zF0gKtPNxsnOESzAVS1DfV6EKQw20RsAVCW+WXMh1eXBtFCEJ3oZJIDqaMM443djc8l07lRM2XLPnReY0oSjREhR8JXFBIA2wfLhtzXtNKsaTTOAtrpj0CXIdnpMEN4T96H3Brx/sEgQHCicgIyuy96hgheWMIIXkgYKKwYBBAGCNwMDATGCF4Iwghd+BgkqhkiG9w0BBwKgghdvMIIXawIBAzEPMA0GCWCGSAFlAwQCAQUAMIIBUQYLKoZIhvcNAQkQAQSgggFABIIBPDCCATgCAQEGCisGAQQBhFkKAwEwMTANBglghkgBZQMEAgEFAAQgkLE9acIapoaXQimcZwnnshi3o95WneQbt0xInno3NPkCBmda9Jj/ehgSMjAyNTAxMTIxMDE3MDcuMTdaMASAAgH0oIHRpIHOMIHLMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxkIFRTUyBFU046ODkwMC0wNUUwLUQ5NDcxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2WgghHtMIIHIDCCBQigAwIBAgITMwAAAe3hX8vV96VdcwABAAAB7TANBgkqhkiG9w0BAQsFADB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMDAeFw0yMzEyMDYxODQ1NDFaFw0yNTAzMDUxODQ1NDFaMIHLMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxkIFRTUyBFU046ODkwMC0wNUUwLUQ5NDcxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2UwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQCoMMJskrrqapycLxPC1H7zD7g88NpbEaQ6SjcTIRbzCVyYQNsz8TaL1pqFTEAPL1X7ojL4/EaEW+UjNqZs/ayMyW4YIpFPZP2x4FBMVCddseF2i+aMMjDHi0LcTQZxM2s3mFMrCZAWSfLYXYDIimFBz8j0oLWGy3VgLmBTKM4xLqv7DZUz8B2SoAmbEtp62ngSl0hOoN73SFwE+Y24SvGQMWhykpG+vXDwcpWvwDe+TgnrLR7ATRFXN5JS26dm2yy6SYFMRYnME3dMHCQ/UQIQQNC8nLmIvdKkAoWEMXtJsGEo3QrM2S2SBv4PpHRzRukzTtP+UAceGxM9JyrwUQP5OCEmW6YchEyRDSwP4hU9f7B0Ayh14Pw9vJo7jewNjeMPIkmneyLSi0ruv2ox/xRGtcJ9yBNC5BaRktjz7stPaojR+PDA2fuBtCo8xKlkt53mUb7AY+CZHHqhLm76pdMF6BHv2TvwlVBeQRN22XjaVVRwCgjgJnNewt7PejcrpUn0qHLgLq+1BN1DzYukWkTr7wT0zl0iXr+NtqUkWSOnWRfe8N21tB6uv3VkW8nFdChtbbZZz24peLtJEZuNrN8Xf9PTPMzZXDJBI1EciR/91QcGoZFmVbFVb2rUIAs01+ZkewvbhmGVDefX9oZG4/K4gGUsTvTW+r1JZMxUT2MwqQIDAQABo4IBSTCCAUUwHQYDVR0OBBYEFM4b8Oz33hAqBEfKlAZf0NKh4CIZMB8GA1UdIwQYMBaAFJ+nFV0AXmJdg/Tl0mWnG1M1GelyMF8GA1UdHwRYMFYwVKBSoFCGTmh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY3JsL01pY3Jvc29mdCUyMFRpbWUtU3RhbXAlMjBQQ0ElMjAyMDEwKDEpLmNybDBsBggrBgEFBQcBAQRgMF4wXAYIKwYBBQUHMAKGUGh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY2VydHMvTWljcm9zb2Z0JTIwVGltZS1TdGFtcCUyMFBDQSUyMDIwMTAoMSkuY3J0MAwGA1UdEwEB/wQCMAAwFgYDVR0lAQH/BAwwCgYIKwYBBQUHAwgwDgYDVR0PAQH/BAQDAgeAMA0GCSqGSIb3DQEBCwUAA4ICAQCd1gK2Rd+eGL0eHi+iE6/qDY8sbbsO4emancp6KPN+xq5ZAatiBR4jmRRhm+9Vik0Fo0DLWi/N28bFI7dXYw09p3vCipbjy4Eoifm0Nud7/4U30i9+7RvW7XOQ3rx37+U7vq9lk6yYpGCNp0jlJ188/CuRPgqJnfq5EdeafH2AoG46hKWTeB7DuXasGt6spJOenGedSre34MWZqeTIQ0raOItZnFuGDy4+xoD1qRz2QW+u2gCHaG8AQjhYUM4uTi9t6kttj6c7Xamr2zrWuceDhz7sKLttLTJ7ws5YrA2I8cTlbMAf2KW0GVjKbYGd+LZGduEK7/7fs4GUkMqc51FsNdG1n+zgc7zHu2oGGeCBg4s8ZR0ZFyx7jsgm9sSFCKQ5CsbAvlr/60Ndk5TeMR8Js2kNUicu2CqZ03833TsvTgk7iD1KLgfS16HEvjN6m4VKJKgjJ7OJJzabtS4JQgUnJrIZfyosk4D18rZni9pUwN03WgTmd10WTwiZOu4g8Un6iKcPMY/iFqTu4ntkzFUxBBpbFG6k1CINZmoirEWmCtG3lyZ2IddmjtIefTkIvGWb4Jxzz7l2m/E2kGOixDJHsahZVmwsoNvhy5ku/inU++dXHzw+hlvqTSFT89rIFVhcmsWPDJPNRSSpMhoJ33V2Za/lkKcbkUM0SbQgS9qsdzCCB3EwggVZoAMCAQICEzMAAAAVxedrngKbSZkAAAAAABUwDQYJKoZIhvcNAQELBQAwgYgxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xMjAwBgNVBAMTKU1pY3Jvc29mdCBSb290IENlcnRpZmljYXRlIEF1dGhvcml0eSAyMDEwMB4XDTIxMDkzMDE4MjIyNVoXDTMwMDkzMDE4MzIyNVowfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTAwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQDk4aZM57RyIQt5osvXJHm9DtWC0/3unAcH0qlsTnXIyjVX9gF/bErg4r25PhdgM/9cT8dm95VTcVrifkpa/rg2Z4VGIwy1jRPPdzLAEBjoYH1qUoNEt6aORmsHFPPFdvWGUNzBRMhxXFExN6AKOG6N7dcP2CZTfDlhAnrEqv1yaa8dq6z2Nr41JmTamDu6GnszrYBbfowQHJ1S/rboYiXcag/PXfT+jlPP1uyFVk3v3byNpOORj7I5LFGc6XBpDco2LXCOMcg1KL3jtIckw+DJj361VI/c+gVVmG1oO5pGve2krnopN6zL64NF50ZuyjLVwIYwXE8s4mKyzbnijYjklqwBSru+cakXW2dg3viSkR4dPf0gz3N9QZpGdc3EXzTdEonW/aUgfX782Z5F37ZyL9t9X4C626p+Nuw2TPYrbqgSUei/BQOj0XOmTTd0lBw0gg/wEPK3Rxjtp+iZfD9M269ewvPV2HM9Q07BMzlMjgK8QmguEOqEUUbi0b1qGFphAXPKZ6Je1yh2AuIzGHLXpyDwwvoSCtdjbwzJNmSLW6CmgyFdXzB0kZSU2LlQ+QuJYfM2BjUYhEfb3BvR/bLUHMVr9lxSUV0S2yW6r1AFemzFER1y7435UsSFF5PAPBXbGjfHCBUYP3irRbb1Hode2o+eFnJpxq57t7c+auIurQIDAQABo4IB3TCCAdkwEgYJKwYBBAGCNxUBBAUCAwEAATAjBgkrBgEEAYI3FQIEFgQUKqdS/mTEmr6CkTxGNSnPEP8vBO4wHQYDVR0OBBYEFJ+nFV0AXmJdg/Tl0mWnG1M1GelyMFwGA1UdIARVMFMwUQYMKwYBBAGCN0yDfQEBMEEwPwYIKwYBBQUHAgEWM2h0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvRG9jcy9SZXBvc2l0b3J5Lmh0bTATBgNVHSUEDDAKBggrBgEFBQcDCDAZBgkrBgEEAYI3FAIEDB4KAFMAdQBiAEMAQTALBgNVHQ8EBAMCAYYwDwYDVR0TAQH/BAUwAwEB/zAfBgNVHSMEGDAWgBTV9lbLj+iiXGJo0T2UkFvXzpoYxDBWBgNVHR8ETzBNMEugSaBHhkVodHRwOi8vY3JsLm1pY3Jvc29mdC5jb20vcGtpL2NybC9wcm9kdWN0cy9NaWNSb29DZXJBdXRfMjAxMC0wNi0yMy5jcmwwWgYIKwYBBQUHAQEETjBMMEoGCCsGAQUFBzAChj5odHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpL2NlcnRzL01pY1Jvb0NlckF1dF8yMDEwLTA2LTIzLmNydDANBgkqhkiG9w0BAQsFAAOCAgEAnVV9/Cqt4SwfZwExJFvhnnJL/Klv6lwUtj5OR2R4sQaTlz0xM7U518JxNj/aZGx80HU5bbsPMeTCj/ts0aGUGCLu6WZnOlNN3Zi6th542DYunKmCVgADsAW+iehp4LoJ7nvfam++Kctu2D9IdQHZGN5tggz1bSNU5HhTdSRXud2f8449xvNo32X2pFaq95W2KFUn0CS9QKC/GbYSEhFdPSfgQJY4rPf5KYnDvBewVIVCs/wMnosZiefwC2qBwoEZQhlSdYo2wh3DYXMuLGt7bj8sCXgU6ZGyqVvfSaN0DLzskYDSPeZKPmY7T7uG+jIa2Zb0j/aRAfbOxnT99kxybxCrdTDFNLB62FD+CljdQDzHVG2dY3RILLFORy3BFARxv2T5JL5zbcqOCb2zAVdJVGTZc9d/HltEAY5aGZFrDZ+kKNxnGSgkujhLmm77IVRrakURR6nxt67I6IleT53S0Ex2tVdUCbFpAUR+fKFhbHP+CrvsQWY9af3LwUFJfn6Tvsv4O+S3Fb+0zj6lMVGEvL8CwYKiexcdFYmNcP7ntdAoGokLjzbaukz5m/8K6TT4JDVnK+ANuOaMmdbhIurwJ0I9JZTmdHRbatGePu1+oDEzfbzL6Xu/OHBE0ZDxyKs6ijoIYn/ZcGNTTY3ugm2lBRDBcQZqELQdVTNYs6FwZvKhggNQMIICOAIBATCB+aGB0aSBzjCByzELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjElMCMGA1UECxMcTWljcm9zb2Z0IEFtZXJpY2EgT3BlcmF0aW9uczEnMCUGA1UECxMeblNoaWVsZCBUU1MgRVNOOjg5MDAtMDVFMC1EOTQ3MSUwIwYDVQQDExxNaWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNloiMKAQEwBwYFKw4DAhoDFQDuHayKTCaYsYxJh+oWTx6uVPFw+aCBgzCBgKR+MHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwMA0GCSqGSIb3DQEBCwUAAgUA6y2nADAiGA8yMDI1MDExMjAyMjcxMloYDzIwMjUwMTEzMDIyNzEyWjB3MD0GCisGAQQBhFkKBAExLzAtMAoCBQDrLacAAgEAMAoCAQACAhJhAgH/MAcCAQACAhLeMAoCBQDrLviAAgEAMDYGCisGAQQBhFkKBAIxKDAmMAwGCisGAQQBhFkKAwKgCjAIAgEAAgMHoSChCjAIAgEAAgMBhqAwDQYJKoZIhvcNAQELBQADggEBAJ7To3+dotbTJaC036hAhWEt2Vdha1p5r/MfXsbwb3y0acr6Il/3gz0jxXWoK0PkbRQ3UI8Q3e6o3SOLLP8Pbi4lep+OeoUb+opmhGZpzYnStiDmMH4j4YPwnml5YgzxGVL/DRm4nZdPuy8ODcCE/0I4fC9/lGhPS5XT9rdXkmfNvS7278ai9bQttcE6npTGzAXKk17w9T/oVqKddbWdBDZWNErfugjX2gwbMZqNfy+k82v0kCR7JeFyjh17CTNewzd8NUqDhZKHZZeZBxoRUXcsM+BKMCXwIQjjS80K9/x8oVDDpdH6HRsZtnZJMErSvQbycgoYETojwjJT7duePUgxggQNMIIECQIBATCBkzB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMAITMwAAAe3hX8vV96VdcwABAAAB7TANBglghkgBZQMEAgEFAKCCAUowGgYJKoZIhvcNAQkDMQ0GCyqGSIb3DQEJEAEEMC8GCSqGSIb3DQEJBDEiBCDLJMf+nYEx5QjuLwQIJjFzqKMxqGjcRx4PdbDPydhBkTCB+gYLKoZIhvcNAQkQAi8xgeowgecwgeQwgb0EII0uDWg0CFseKxK3A16l1wrIwrsSDrXZ6xSf0F4xbMo5MIGYMIGApH4wfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTACEzMAAAHt4V/L1felXXMAAQAAAe0wIgQgIAJD/EUNCWhz086sotjQQ3Y06YUukXxM3+p5sItWEwwwDQYJKoZIhvcNAQELBQAEggIAiQGyj2ES+gptxcu1MPmaBnbDl7i9UzCWapCwiBp+kPRysDhI2iJQMxCjm/gOgZ6LgL/bkHOdGaM8PRmkaYGJdy8NJzfFND0cFXx+fBC/yjHxp+5jwXvwBtU8xZQpekOr1l3EqO4MRfa6GlwM8RprlVlJIHdjSsqRXk37s1Ji9OBf0YIM0HTrwL7AbbZjEAl1/OeWPEE7IywCby7v94QkWt0LzLyYKAjA8cw2WVysEbKg1aC3SPTcH2uRox0GbsmBefmISDfrs0UZ+HKPigsSX8nlcR8C8mGYVlxUVYu3JahlJwXEiQqwY0gA7L9p9I2Q9t2Y2bM8AoZBDV2ayd3uqlb0xNGc/JR/l4tEz8Iio7hKHui08gSw7w5WyLROq0AJPrxPycy271fm6kbAnH/VswPkKVvkNUF4d8UKb1e0cVnxXc9xPK+H6XdvCTvn7EM7+GEYoe8vASbvYRbJugAlPiutnvFYVmM25AfIUR6iKJXl0A0rJOzhvy4bDA7p6HpkFN4GuosuUlQO4Be8iqu73M0gdqEASmg3q9srK7D10UKpf+/LGI62zsmgOIBDeIHeqoyjlv5YaeGj0EaD5xp/Jl5JoTZf+2XzMgjfvHSOlC88EUGLrS5eyt/GFc5bfKsZLc9x3HbTkFReRaVTKUTezMnnruft83GMb+SSgWBMp4cAAAAAAAAA"
              )"

   }
    return obj.%resName%
}
;[@getIco-CB747C07A3FB4A31B5FCBE475DE40C85]
;[@func-A46687E52FCF472ABE87DD1DEB29177E]
;----------------------------------------------------------------------------------------------------------全局函数func
;----------------------------------------------------------------------------------------------------------初始化类init class
;[@init-B42A9039F3BF47D8B038FEF62002708B]
;初始化启动
;①.设置环境变量HELPME_HOME,JAVA_HOME,NLS_LANG ，设置java到path
;②.设置开机启动到start文件夹下，包括frp,snipaste,rader
;③.创建初始化配置：
;    helpme\command_ext\ahk\config
;                        |      |---configsys.txt  ;主系统配置文件【config2】
;                        |      |---configget.txt  ;存取值配置文件【configget】
;                        |      |---configrun.txt  ;运行框配置文件【configrun】
;                         \log
;                           |---clip.log        ;粘贴板历史记录 【his】
;                           |---run.log         ;运行框历史命令记录 【his2/runlog】
;                           |---pic.log         ;截图保存位置 【hispic/pic】
;                           |---sys.log         ;系统运行日志 【syslog/log】
;
;④.复制当前非helpme目录command_ext下执行ahk文件到helpme的command_ext下面
;⑤.读取config目录下所有配置到对应变量CONFIGMAP,CONFIGGETMAP,CONFIGRUNMAP
;⑥.在系统path下创建一个快捷方式【kjj.lnk】用于运行框启动当前快捷键
class init
{
     ;环境变量
     static parentDir:="helpme"
     static helpmeEnv:="HELPME_HOME"
     static helpme2:="command_ext"
     static helpme3:="command_java"
     static logDir:="command_ext\ahk\log"
     static configDir:="command_ext\ahk\config"
     static helpmeHome:=""            ;HELPME_HOME 家目录
     static helpme2Path:=""           ;%HELPME_HOME%\command_ext路径
     static helpme3Path:=""           ;%HELPME_HOME%\command_java路径
     static configDirPath:=""         ;%HELPME_HOME%\command_ext\ahk\config配置config目录路径
     static configLogPath:=""         ;%HELPME_HOME%\command_ext\ahk\log日志log目录路径

     ;配置文件
     static sysconfigFile:="sysconfig.txt" ;脚本运行配置 congfig2
     static getconfigFile:="getconfig.txt" ;运行框获取答案get配置 getconfig
     static runconfigFile:="runconfig.txt" ;运行框运行配置 runconfig
     ;完整路径
     static sysconfigPath:=""    ;%helpme_home%\command_ext\ahk\config\sysconfig.txt
     static getconfigPath:=""    ;%helpme_home%\command_ext\ahk\config\getconfig.txt
     static runconfigPath:=""    ;%helpme_home%\command_ext\ahk\config\runconfig.txt

     ;日志文件
     static  runDir:="run.log"      ;运行框运行日志 his2
     static  sysDir:="sys.log"      ;脚本运行记录的错误日志  syslog
     static  picDir:="pic.log"      ;截图产生的日志 hispic
     static  clipDir:="clip.log"    ;复制产生的日志 his
     ;完整路径
     static  runPah:=""       ;%helpme_home%\command_ext\ahk\log\run.log
     static  sysPath:=""      ;%helpme_home%\command_ext\ahk\log\sys.log
     static  picPath:=""      ;%helpme_home%\command_ext\ahk\log\pic.log
     static  clipPath:=""     ;%helpme_home%\command_ext\ahk\log\clip.log

     ;配置java环境变量
     static javahomeK :="JAVA_HOME"
     static javahomeV :="command_java\jdk1.8_x64"
     ;配置orcale
     static oraclelangK:="NLS_LANG"
     static oraclelangV:="SIMPLIFIED CHINESE_CHINA.ZHS16GBK"
     ;设置job开机启动计划
     static jobName:="AhkStartUp"
     ;设置开机启动程序
     static radarPath:="radar\radar.exe"
;     static snipastePath:="Snipaste-2.5.6-Beta-x64\Snipaste.exe"
     static snipastePath:="PixPin\PixPin.exe"

     ;读取配置文件内容,runconfig.txt和getConfig.txt,sysconfig.txt是运行时读取
     static configMap:={}
     static getMap:={}
     static runMap:={}

     ;是否开启阅读模式0/1 关闭/开启
     static readmod:=0
     ;是否开启xbutton快捷识图0/1 关闭/开启
     static ocrmod:=0
     ;是否开启spy 0/1 关闭/开启
     static spymod:=0
     static lbuttonupFlag:=0

     ;网络代理配置注册表路径
     static inetSettingPath:="HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Internet Settings"
     ;检测copilot的定时器
     static copilotTimer:=ObjBindMethod(this, "copilotChangeProxy")
     ;检测sysconfig.txt配置文件是否被修改
     static sycConfigChangeTimer:=ObjBindMethod(this, "checkSycConfigChange")

     ;设置初始化系统配置文件最后修改时间
     static syscConfigLastModifiedTime := ""


     static initAll()
     {
        this.createEnv()        ;先创建并获取环境变量
        this.createDirFile()    ;初始化目录
        this.copyFile2Helpme()  ;复制当前脚本到%HELPME_HOME%\command_ext下
        setTimer(()=>this.asyncJob(),-1) ;定时器执行添加当前到job里面保持开机启动
        this.configMap:=ak.readFileToMap(init.sysconfigPath)  ;获取系统配置
        this.syscConfigLastModifiedTime:=FileGetTime(init.sysconfigPath, "M") ;初始化系统配置最后修改时间
        this.regesterHotKey()   ;注册热键
        this.RunExtraScripts()  ;ahk_ext目录下的所有ahk脚本
     }
     ;初始化后执行操作
     static onStartup()
     {
       imageutil.init() ;初始化gdi+
       ak.transparentTaskBar() ;立即透明桌面
       if FileExist(sogouocr.catcheguiHtmlPath) ;删除ocr的gui缓存html文件,重新获取html并缓存
           fileDelete(sogouocr.catcheguiHtmlPath)
       ;socketapp.connect()  ;连接socket,;耗时的timer放最上面
       setTimer ()=>sogouocr.sendGetRequest(1),-1 ;初始化ocr请求
       setTimer ()=>ak.getCpuid() ,-1 ;获取cpuid 并记录值到ak.cpuid
       setTimer ()=>loadgif.initData() ,-1 ;初始loadgif
       setTimer ()=>this.createConfigLnk() ,-1 ;在demo\z-ahk中创建一个config配置文件夹
       setTimer ()=>ak.transparentTaskBar(),-3000 ;3s后执行 透明桌面任务栏 防止开机还没加载
       setTimer ()=>this.changeBingWallpaper(),-1000 ;开机后更换桌面为bing壁纸，无水印
;       setTimer ()=>recent.init(),-1 ;写入注册表右键打开最近文件 [不启用recent功能]
       setTimer this.sycConfigChangeTimer,1000 ;检测sysconfig.txt是否变更,变更了重启脚本
;       setTimer this.copilotTimer,1000 ;检测copilot是否打开，打开就开启系统代理
;       setTimer ()=>this.setHostsByNetTimer(),-1 ;配置远程主机的ipv6本地hosts域名

       return ;
     }
     ;初始化文件夹文件
     static createDirFile()
     {
         if not this.helpmeHome
            throw Error("创建文件夹时发现init.helpmeHome未被初始化")
         if not fileExist(this.configDirPath)=="D" ;创建文件夹config
            DirCreate this.configDirPath
         if not fileExist(this.configLogPath)=="D"  ;创建文件夹log
            DirCreate this.configLogPath
         if not fileExist(this.clipPath:=(this.configLogPath . "\" this.clipDir))=="D" ;创建clip.log文件夹
            DirCreate this.clipPath
         if not fileExist(this.picPath:=(this.configLogPath . "\" this.picDir))=="D"   ;创建pic.log文件夹
            DirCreate this.picPath
         if not fileExist(this.sysPath:=(this.configLogPath . "\" this.sysDir))=="D"   ;创建sys.log文件夹
            DirCreate this.sysPath
         if not fileExist(this.runPath:=(this.configLogPath . "\" this.runDir))=="D"   ;创建run.log文件夹
            DirCreate this.runPath
         if not fileExist(this.sysconfigPath:=(this.configDirPath . "\" this.sysconfigFile)) ;创建sysconfig.txt文件
            FileAppend "",this.sysconfigPath
         if not fileExist(this.getconfigPath:=(this.configDirPath . "\" this.getconfigFile)) ;创建getconfig.txt文件
            FileAppend "",this.getconfigPath
         if not fileExist(this.runconfigPath:=(this.configDirPath . "\" this.runconfigFile)) ;创建runconfig.txt文件
            FileAppend "",this.runconfigPath
         if this.helpme2Path==A_ScriptDir{
             if not fileExist(kjj:=(A_WinDir . "\kjj.lnk"))                          ;创建快捷方式 kjj
                 FileCreateShortcut(A_LineFile ,kjj ,A_ScriptDir)
             if not fileExist(snipaste:=(A_startup . "\snipaste.exe.lnk"))           ;pixpin创建开机启动
                 FileCreateShortcut(this.helpme2Path . "\" . this.snipastePath ,snipaste)
             if not fileExist(radar:=(A_startup . "\radar.exe.lnk"))                 ;radar创建开机启动
                 FileCreateShortcut(this.helpme2Path . "\" . this.radarPath ,radar)
             if not fileExist(source:=(A_startup . "\" . A_ScriptName . ".lnk"))     ;创建当前脚本启动
                 FileCreateShortcut(A_LineFile ,source ,A_ScriptDir)
         }
     }
     ;创建环境变量
     static createEnv()
     {
        this.helpmeHome:=this.InPath()?subStr(A_ScriptDir,1,strLen(A_ScriptDir)-strLen(this.helpme2)-1):reg.getEnv(this.helpmeEnv)
        if not this.helpmeHome
            throw Error("创建环境变量时发现init.helpmeHome未被初始化")
        this.helpme2Path:=this.helpmeHome "\" this.helpme2
        this.helpme3Path:=this.helpmeHome "\" this.helpme3
        this.configDirPath:=this.helpmeHome "\" this.configDir
        this.configLogPath:=this.helpmeHome "\" this.logDir
        if not reg.getEnv(this.helpmeEnv) ;设置helpme环境变量
            reg.setEnv(this.helpmeEnv,this.helpmeHome)
        if not reg.getEnv(this.javahomeK) ;jdk1.8 环境变量
            reg.setEnv(this.javahomeK,this.helpmeHome . "\" . this.javahomeV )
        if not reg.getEnv(this.oraclelangK) ;oracle环境变量
            reg.setEnv(this.oraclelangK,this.oraclelangV )
         reg.pathPush(Format('%{1}%\bin',this.javahomeK)) ;设置java的path
     }
     ; 复制当前文件及扩展目录到 HELPME_HOME
     static copyFile2Helpme()
     {
         if ((not A_IsCompiled) and this.helpmeHome and A_ScriptDir != this.helpme2Path)
         {
             ; 1. 复制主脚本本身（1表示覆盖）
             FileCopy(A_ScriptFullPath, this.helpme2Path, 1)
             ; 2. 递归复制当前ahk_ext和下面的脚本所在目录下的所有文件及子目录（1表示覆盖）
             if DirExist(A_ScriptDir . "\ahk_ext")
             {
                 DirCopy(A_ScriptDir . "\ahk_ext", this.helpme2Path . "\ahk_ext", 1)
             }
         }
     }
     ;判断当前运行是否是在helpme下运行的
     static InPath()
     {
         ;判断当前执行路径是否在helpme\command_ext下
         return ak.strEndWith(A_ScriptDir,this.parentDir . "\" . this.helpme2)
     }
     ;添加当前脚本到job下面
     static add2Job()
     {
        if this.helpme2Path==A_ScriptDir{
            cmd:="schtasks.exe /create /tn " this.jobName " /tr " Format('"\"{1}\" \"{2}\""',A_AhkPath,A_LineFile) " /sc  onlogon"
            ak.shellExcuter(cmd)
        }
     }
     ;在当前demo\z-ahk下创建一个config文件夹来硬链接配置
     static createConfigLnk()
     {
        if "Z-ahk"=ak.getSuffix(A_ScriptDir){
            if not fileExist(configDir:=(A_ScriptDir . "\" . strLower(ak.getCpuid()) . ".config"))
                DirCreate(configDir)
            if  fileExist(getconfigPath:=(configDir . "\" this.getconfigFile)) ;创建z-ahk/getconfig.txt
                FileDelete getconfigPath
            if  fileExist(sysconfigPath:=(configDir . "\" this.sysconfigFile)) ;创建z-ahk/sysconfig.txt
                FileDelete sysconfigPath
            if  fileExist(runconfigPath:=(configDir . "\" this.runconfigFile)) ;创建z-ahk/runconfig.txt
                FileDelete runconfigPath
            ak.shellExcuter(Format('mklink /H "{1}" "{2}"' ,getconfigPath ,this.getconfigPath ))  ;{1}:target {2}:source
            ak.shellExcuter(Format('mklink /H "{1}" "{2}"' ,sysconfigPath ,this.sysconfigPath ))
            ak.shellExcuter(Format('mklink /H "{1}" "{2}"' ,runconfigPath ,this.runconfigPath))
        }
     }
     ;异步执行的操作
     static asyncJob()
     {
        this.add2Job()
     }
     ;读取系统的配置文件sysconfig.txt获取ctrl+shift+U 字符串大小写转换配置
     static StringCaseConfigExe()
     {
        sysconfig:=ak.readFileToMap(this.sysconfigPath)
        return ak.arrHas(sysconfig.get("no_uplow_string_exe"),WinGetProcessName("A"))
     }
     ;读取系统的配置文件sysconfig.txt获取ctrl+shift+down 向下复制一样
     static copyLineConfigExe()
     {
        sysconfig:=ak.readFileToMap(this.sysconfigPath)
        return ak.arrHas(sysconfig.get("no_copy_line_exe"),WinGetProcessName("A"))
     }
     ;更新壁纸 ，在黎明0点过3s钟更新壁纸
     static updateWallpaperAtZeroDawn()
     {
         delayMS:=-(86400-A_Hour*3600-A_Min*60-A_Sec +3)*1000 ;
         setTimer ()=>this.changeBingWallpaper() ,delayMS
         log("提示消息",Error("时间:" . ak.getTimeStr("-"," ",":") . " 已启动定时任务,下一次壁纸更新：" . delayMS . "ms")) ;记录日志
     }
     ;异步更换bing壁纸
     static changeBingWallpaper()
     {
        try{
            bingSite:="http://www.bing.com"
            if  not ak.ConnectedToInternet()
               throw Error("没有互联网连接")
            if  not this.helpmeHome
               throw Error("还没有创建环境变量HELPME_HOME")
            backpngPath:=(bingDir:=Format("{1}\wallpaper",this.configLogPath)) . "\" . (backpngName:="0A_" . ak.getTimeStr("-","","") . ".back.png")
            sysconfig:=ak.readFileToMap(this.sysconfigPath)
            wallpapaerPath:=ak.getDesktopWallpaperPath()
            lastpngBack:=ak.getlastFile(bingDir,"back.png")
            if not sysconfig.get("bing_wallpaper")="on"
                return lastpngBack and fileExist(lastpngBack) and inStr(wallpapaerPath,Format("{1}-{2}-{3}",A_YYYY,A_MM,A_DD))  and inStr(wallpapaerPath,"《")
                       ? ak.changeWallPaper(lastpngBack):""
            if not FileExist(bingPng:=ak.getPathByBegin(bingDir, tmpDay:=Format("{1}-{2}-{3}",A_YYYY,A_MM,A_DD),".png")){
                T1:= not FileExist(bingDir) ? DirCreate(bingDir):""
                content:=ak.getHtmlContent(bingSite)
                bingURL:=inStr(uri:=ak.getElementAttr(content,"preloadBg","href"),"http")==1?uri:bingSite . uri
                bingTitle:=ak.getstrBAB(ak.getstrBAB(content,'class="title" aria-label','</a>'),">") ; 获取bing壁纸今日标题
                Download bingURL, bingPng:=Format("{1}\{2}《{3}》.png",bingDir,tmpDay,bingTitle)       ;下载图片
            }
            tipTitle:="Bing壁纸:" . ak.getstrBAB(bingPng,"《","》",0,0)
            ak.seticonTip(ak.strInsertAt(ak.strInsertAt(tipTitle,12,"`n") ,22,"`n" ),5) ;设置Tip
            if not (inStr(wallpapaerPath,tmpDay)  and inStr(wallpapaerPath,"《") or   wallpapaerPath=lastpngBack)
                and fileExist(wallpapaerPath) and instr(wallpapaerPath,bingDir)!=1
                fileCopy(wallpapaerPath,backpngPath,1) ;备份壁纸
            ak.changeWallPaper(bingPng)                ;更换桌面壁纸
            this.updateWallpaperAtZeroDawn()           ;0点更新壁纸
         }catch as e{
            log("更换bing壁纸异常",e)
         }
     }
     ;检测copilot 来切换系统代理
     static copilotChangeProxy()
     {
        try{
            if not ak.mapget(this.configMap,"changeProxyTimer")="on"{
                 SetTimer this.copilotTimer, 0 ;关闭定时器
                 return
            }
            ;查询注册表数据获取系统代理状态
            if  ak.regHasKey(this.inetSettingPath,"ProxyEnable") and RegRead(this.inetSettingPath, "ProxyEnable")=1
                 proxyServer:=ak.regHasKey(this.inetSettingPath,"ProxyServer")? RegRead(this.inetSettingPath, "ProxyServer"):""
            ak.seticonTip("系统代理："  . (proxyServer??"off") ,3)
            ak.sysProxySwitch(init.configMap,WinExist("Copilot (预览版)")?1:0)
        }catch as e {
            log("copilot 切换系统代理异常",e)
        }
     }
     ;检测sysconfig.txt是否改变然后重启脚本
      static checkSycConfigChange()
      {
          if FileExist(init.sysconfigPath) {
              current := FileGetTime(init.sysconfigPath, "M")
              ; 首次运行若未记录时间，先进行初始化，避免一开始就误触发 Reload
              if !init.HasOwnProp("syscConfigLastModifiedTime") || !init.syscConfigLastModifiedTime {
                  init.syscConfigLastModifiedTime := current
                  return
              }
              if (current != init.syscConfigLastModifiedTime) {
                  init.syscConfigLastModifiedTime := current
                  Reload() ; AHK v2 推荐标准函数写法
              }
          }
      }
     ;从服务器同步ipv6到本地hosts文件
     static setHostsByNetTimer(){
        netflag:=ak.mapget(this.configMap,"netipv6")
        if netflag="on"{
            hostname:=ak.mapget(this.configMap,"hostname")
            url:=ak.mapget(this.configMap,"neturl")
            hosts:="C:\Windows\System32\drivers\etc\hosts"
            setTimer(()=>this.updateHostsByNet(hostname,url,hosts),3000)
        }
     }
     ;更新host 通过互联网 ,修改host映射自己的服务器
     static updateHostsByNet(hostname,url ,hosts)
     {
        try{
         static preIpv6:=""
         ipv6:=strReplace(Trim(ak.getHtmlContent(url)),"`n","")
         if ipv6!=preIpv6{
             if inStr(hostct:=fileRead(hosts),hostname)
                 hostct:=strReplace(hostct, "[" . preIpv6  . "] " . hostname ,"[" . ipv6  . "] " . hostname )
             else
                 hostct:=hostct "`n" . "[" . ipv6 . "]" . " " . hostname
             preIpv6:=ipv6
             fileDelete hosts
             fileAppend hostct ,hosts
         }
        }catch as e {
            log("添加hosts的ipv6异常",e)
        }
     }
     ;注册热键
     static  regesterHotKey()
     {
        sysconfig:=ak.readFileToMap(init.sysconfigPath)
        for key, val in sysconfig {
            if InStr(Trim(key), "::") = 1 {
                Hotstring(key, init.hotKeyHandler(val))
                Hotstring(StrReplace(key, "?", "？", , , 1),init.hotKeyHandler(val))
            }
        }
     }
     static hotKeyHandler(content){
        content:=strReplace(content,"\n","`n")
        localContent:=content
        return (*) => SendText(localContent)
     }

     ;创建任务栏菜单
     static createTaskBarMenu()
     {
        tray := A_TrayMenu ; 为了方便.
        tray.SetIcon("&Open","HICON: " . imageutil.Base64PNG_to_HICON(getResourceBase64("debug")))
        tray.rename("&Open","打开调试面板")
        tray.insert("&Help","ZH-文档帮助",onZhHelpmeMenu)
        tray.insert("ZH-文档帮助","阅读模式",onReadMenu)
        tray.SetIcon("阅读模式","HICON: " . imageutil.Base64PNG_to_HICON(getResourceBase64("read1")))
        tray.insert("阅读模式","快捷OCR",onOcrMenu)
        tray.SetIcon("快捷OCR","HICON: " . imageutil.Base64PNG_to_HICON(getResourceBase64("ocr1")))
        tray.rename("&Help","EN-文档帮助")
        tray.insert("&Window Spy","窗口检测my",onMyWindowSpyMenu,"Radio")
        tray.SetIcon("&Window Spy","HICON: " . imageutil.Base64PNG_to_HICON(getResourceBase64("spy2")))
        tray.rename("&Window Spy","窗口检测工具spy")
        tray.delete("&Reload Script")
        tray.delete("&Edit Script")
        tray.delete("&Pause Script")
        tray.SetIcon("&Suspend Hotkeys","HICON: " . imageutil.Base64PNG_to_HICON(getResourceBase64("suspend")))
        tray.rename("&Suspend Hotkeys","暂停")
        tray.insert("11&","重启",onrealoadMenu)
        tray.SetIcon("11&","HICON: " . imageutil.Base64PNG_to_HICON(getResourceBase64("reload")))
        tray.rename("12&","退出")
        tray.SetIcon("12&","HICON: " . imageutil.Base64PNG_to_HICON(getResourceBase64("exit")))
        tray.SetColor("white")

        onrealoadMenu(*) ;重启
        {
            Reload
        }
        onZhHelpmeMenu(*) ;中文版文档
        {
            ak.shellExcuter("start https://wyagd001.github.io/v2/docs/")
        }
        onMyWindowSpyMenu(*) ;自定义窗口检测工具
        {
            static counter:=0
            if mod(counter,2)==0
                runbox.runCmd("spy")
            else
                runbox.runCmd("closespy")
            counter+=1
        }
        onReadMenu(*) ;阅读国外网站时开启按钮
        {
            static counter2:=0
            if mod(counter2,2)==0{
                tray.SetIcon("阅读模式","HICON: " . imageutil.Base64PNG_to_HICON(getResourceBase64("read2")))
                init.readmod:=1   ;开启阅读模式
                Tx1:=init.ocrmod?"":onOcrMenu()
            }else{
                tray.SetIcon("阅读模式","HICON: " . imageutil.Base64PNG_to_HICON(getResourceBase64("read1")))
                init.readmod:=0   ;关闭阅读模式、
                Tx1:=init.ocrmod?onOcrMenu():""
             }
            counter2+=1
        }
        onOcrMenu(*) ;开启xbutton2快捷识图
        {
            static counter3:=0
            if mod(counter3,2)==0 {
                tray.SetIcon("快捷OCR","HICON: " . imageutil.Base64PNG_to_HICON(getResourceBase64("ocr2")))
                init.ocrmod:=1  ;开启阅读模式
            }else{
                tray.SetIcon("快捷OCR","HICON: " . imageutil.Base64PNG_to_HICON(getResourceBase64("ocr1")))
                init.ocrmod:=0  ;关闭阅读模式
             }
            counter3+=1
        }
     }
     ;运行 ahk_ext 子目录下所有的 ahk 脚本
     static RunExtraScripts() {
         ; 锁定当前脚本所在的 ahk_ext 文件夹目录
         scriptDir := A_ScriptDir . "\ahk_ext"
         ; 安全防御：如果这个子文件夹压根不存在，直接拦截，防止底层报错
         if (!DirExist(scriptDir)) {
             return
         }
         successCount := 0
         Loop Files scriptDir "\*.ahk", "F" {
             try {
                currentName := StrReplace(A_LoopFileName, ".ahk", "")
                 Run('"' A_LoopFileFullPath '"', , "Hide")
                 ak.seticonTip("💚" . currentName,3+successCount)
                 successCount++
             } catch Error as err {
                 OutputDebug("启动失败的脚本: " A_LoopFileName " | 原因: " err.Message "`n")
             }
         }
         ; 打印 Debug 日志（桌面上完全无感知）
         OutputDebug("🎉 纯静默运行完毕！共成功拉起 " successCount " 个扩展脚本。`n")
     }
     ;关闭 主脚本打开的ahk_ext下的子脚本
     static KillExtraScripts(ExitReason := 0, ExitCode := 0) {
         scriptDir := A_ScriptDir . "\ahk_ext" ; 锁定我们要清理的子脚本目录
         if DirExist(scriptDir) {
             oldDetect := DetectHiddenWindows(true)
             Loop Files scriptDir "\*.ahk", "F" {
                 targetTitle := A_LoopFileFullPath " ahk_class AutoHotkey"
                 if WinExist(targetTitle) {
                     WinClose(targetTitle)
                 }
             }
             DetectHiddenWindows(oldDetect)
         }
         return 0
     }
}
;[@init-B42A9039F3BF47D8B038FEF62002708B]
;----------------------------------------------------------------------------------------------------------初始化类init class
;----------------------------------------------------------------------------------------------------------日志记录操作cliphis类clas
;用于记录剪切板数据，剪切板图片
class cliphis
{
    ;记录文本数据
    static recordetxt(data,flag:=1)
    {
        try{
            if not init.clipPath{
                log("clipPath不存在" ,Error(init.helpmeHome))
                return
            }
            filePath:=Format("{1}\{2}-{3}-{4}.txt",init.clipPath,A_YYYY,A_MM,A_DD)
            if not (title:=ak.getactivePath()) ;获取当前标题
                title:=WinGetTitle("A")
            Loop 85
                line.="-"
            splitline:=Format("{1}{2} [({3})Title: {4}]`n",line,ak.getTimeStr("-"," " ,":"),flag==1?"复制":"截图",title)
            if not FileExist(filePath){
                FileAppend(splitline . data,filePath)
            }else{
                content:=FileRead(filePath)
                FileDelete(filePath)
                FileAppend(splitline . data . "`n`n" . content,filePath)
            }
        }catch as e{
          log("记录文字异常",e)
        }
    }
    ;记录图片数据
    static recordepic()
    {
        try{
            if init.picPath{
                while FileExist(path:=init.picPath . "\" . ak.getTimeStr() ".png")
                    sleep 1000
                ak.savepic(path)
                return path
            }
        }catch as e{
            log("记录图片异常",e)
        }
    }
    ;粘贴图片到当前文件夹ctrl+v或者点击win10多功能剪切板记录
    static pastpng2dir()
    {
       try{
           if ak.clipdataType==2{
               ak.setSystemCursor() ;忙等待
               if(f:=ak.getactivePath()){
                 imageutil.saveclip(Format("{1}\ahk_{2}.png",f, ak.getTimestr("-"," ","-")))
               }
               sleep 200
               ak.restoreCursors() ;恢复鼠标状态
           }
       }catch as e{
           log("ctrl+v粘贴图片异常",e)
       }
    }
    ;复制文件路径到剪切板
    static copyFilePath2Clip()
    {
        if A_Cursor!="Arrow"
            return
        if((tmp:=ak.clipdataType)!=2) ;非图片的时候才会恢复数据
            clipSave:=ClipboardAll()
        A_Clipboard := ""
        send "^c"
        if not ClipWait(1,1){
            log("复制文件路径", Error("等待剪切板数据超时:" . 1 . "s"))
            T3:=tmp==2?(A_Clipboard:="==========♜==========="):(A_Clipboard:=clipSave)  ;恢复数据
            return
        }
        ak.getClipFilePath()
    }
    ;用点击鼠标中键默认浏览器打开选中的http链接地址
    static runCopyLink()
    {
       try{
           sysconfig:=ak.readFileToMap(init.sysconfigPath)
           browserList:=sysconfig.get("browser_list")
           ignoreList:=sysconfig.get("ignore_process")
           searchEngine:=sysconfig.get("default_search_engine")
           if (A_Cursor="IBeam"  or A_Cursor="Unknown") and (str:=Trim(ak.getSelectStr())) and  ((inStr(str,"http://")==1 or inStr(str,"https://")==1)){
                Run ak.uriEncode(str)
           }else if(ak.arrHas(ignoreList,processName:=ak.getSuffix(processPath:= WinGetProcessPath("A")))){
                return  ;忽略项
           }else if(A_Cursor="IBeam" and  (str:=Trim(ak.getSelectStr())) and not inStr(str,"https://")==1 and not inStr(str,"http://")==1
                    and sysconfig.get("mbutton_search")="on"){
                   if not ak.arrHas(browserList, processName)
                        processPath:=""
                   Run  Trim(processPath . " " . ak.uriEncode(searchEngine . str))
           }
       }catch as e{
            log("跳转地址异常",e)
       }
    }
}
;----------------------------------------------------------------------------------------------------------日志记录操作cliphis类clas
;----------------------------------------------------------------------------------------------------------运行框rubox 类 class
;执行各种运算取值
class runbox
{
    ;定时器
    static spycmdTimer:=ObjBindMethod(this, "spyCmd")
    ;spy显示信息
    static spytext:=""

    ;执行比表达式计算，"==" 触发,callflag是其他函数调用该方法
    static calculateExpression(rawstr,callflag:=0)
    {
        ;从配置文件getconfig.txt中获取值
        if inStr(rawStr,"get ")==1 and (not (str:=Trim(Ltrim(rawStr,"get")))==Trim(rawStr)){
            result:=this.getExpression(str,&prefix)
            fulltxt:= rawStr . (prefix?"":"=") . result
            runlog("getconfig.txt配置中取值或者环境变量取值",fulltxt)
            return fulltxt
        }
        ;从配置文件getconfig.txt中获取值
        if inStr(rawStr,"getpath ")==1 and (not (str:=Trim(Ltrim(rawStr,"getpath")))==Trim(rawStr)){
            result:=this.getEnvExpression(str)
            fulltxt:= rawStr . "=" . result
            runlog("环境变量取值",fulltxt)
            return fulltxt
        }
        ;设置环境变量user/sys
        if (a:=(inStr(rawStr,"set ")==1) and (not (str:=Trim(Ltrim(rawStr,"set")))==Trim(rawStr)))
            or (inStr(rawStr,"sets ")==1 and (not (str:=Trim(Ltrim(rawStr,"sets")))==Trim(rawStr))){
            result:=this.setEnvExpression(str,a?1:0) ;返回成功/失败
            fulltxt:= rawStr . " " . result
            runlog("设置环境变量",fulltxt)
            return fulltxt
        }
        ;解析uri中的%字符
        if (str:=Trim(rawStr))~="^%[\da-zA-Z]+$"{
          result:=this.ascOrChrExpression(Format("{1:d}", "0x" . SubStr(str, 2) ),0)
          fulltxt:= rawStr . " =" . result
          runlog("解析uri中的%字符",fulltxt)
          return fulltxt
        }
        ;encodeuri  uri编码
        if inStr(rawStr,"encodeuri ")==1{
            result:=ak.uriEncode(Trim(LTrim(rawStr,"encodeuri")))
            fulltxt:= rawStr . "=" . result
            runlog("uri编码",fulltxt)
            return result
        }
        ;decodeuri  uri解码
        if inStr(rawStr,"decodeuri ")==1{
            result:=ak.uriDecode(Trim(LTrim(rawStr,"decodeuri")))
            fulltxt:= rawStr . "=" . result
            runlog("uri解码",fulltxt)
            return result
        }
        ;encodeurl  url编码
        if inStr(rawStr,"encodeurl ")==1{
            result:=ak.urlEncode(Trim(LTrim(rawStr,"encodeurl")))
            fulltxt:= rawStr . "=" . result
            runlog("url编码",fulltxt)
            return result
        }
        ;decodeurl  url解码
        if inStr(rawStr,"decodeurl ")==1{
            result:=ak.urlDecode(Trim(LTrim(rawStr,"decodeurl")))
            fulltxt:= rawStr . "=" . result
            runlog("url解码",fulltxt)
            return result
        }
        ;把字符转换为uncode编码
        if inStr(rawStr,"encode ")==1{
            result:=this.charcodeExpression(Trim(LTrim(rawStr,"encode")),1)
            runlog("把字符转换为uncode编码",rawStr . "=" . result)
            return result
        }
        ;把字unicode编码转换为字符串
        if inStr(rawStr,"decode ")==1 or inStr(rawStr,"\u")==1{
            result:=this.charcodeExpression(Trim(LTrim(rawStr,"decode")),0)
            runlog("把字unicode编码转换为字符串",rawStr . "=" . result)
            return result
        }
        ;获取cpuid
        if strLower(trim(rawStr))=="cpuid"{
            cpuid :=ak.cpuid or ak.getCpuid()
            fulltxt:= rawStr . "=" . cpuid
            runlog("获取cpuid",fulltxt)
            return cpuid
        }
        ;获取uuid随机值
        if strLower(trim(rawStr))=="uuid"{
            uuid:=ak.uuid()
            fulltxt:= rawStr . "=" . uuid
            runlog("获取uuid随机值",fulltxt)
            return uuid
        }
        ;计算字符的asc码值
        if inStr(rawStr,"asc ")==1{
            result:=this.ascOrChrExpression(trim(LTrim(rawStr,"asc")),1)
            fulltxt:= rawStr . "=" . result
            runlog("计算字符的asc码值",fulltxt)
            return fulltxt
        }
        ;计算字符串的MD5码值
        if inStr(rawStr,"md5 ")==1{
            result:=ak.MD5(trim(LTrim(rawStr,"md5")))
            fulltxt:= rawStr . "=" . result
            runlog("计算字符串的MD5码值",fulltxt)
            return fulltxt
        }
        ;计算数字所代表字符
        if inStr(rawStr,"ord ")==1 or inStr(rawStr,"chr ")==1{
            result:=this.ascOrChrExpression(Trim(LTrim(LTrim(rawStr,"ord"),"chr")),0)
            fulltxt:= rawStr . "=" . result
            runlog("计算数字所代表字符",fulltxt)
            return fulltxt
        }
        ;转换为大写
        if inStr(rawStr,"up ")==1{
            result:=strUpper(Trim(Ltrim(rawStr,"up")))
            fulltxt:= rawStr . "=" result
            runlog("转换为大写",fulltxt)
            return fulltxt
        }
        ;转换为小写
        if inStr(rawStr,"low ")==1{
            result:=strLower(Trim(Ltrim(rawStr,"low")))
            fulltxt:= rawStr . "=" result
            runlog("转换为小写",fulltxt)
            return fulltxt
        }
        ;计算数学表达式
        if (result:=this.mathExpression(rawStr)){
            fulltxt:=rawStr . result
            runlog("计算数学表达式",fulltxt)
            return result
        }
        ;计算平方根
        if inStr(rawStr,"sqrt ")==1{
            str:=Trim(Ltrim(rawStr,"sqrt"))
            result:=ak.get_bignumber(sqrt(str),3,0) ;该函数自带 = 或者  ≈
            fulltxt:=rawStr . result
            runlog("计算平方根",fulltxt)
            return fulltxt
        }
        ;翻译中<->英翻译,中<->韩互译,中<->日互译 ,注意：判断顺序不能换
        if ((i2:=(inStr(rawStr,"meank ")==1)) or (i3:=inStr(rawStr,"meanj ")==1 or i1:=(inStr(rawStr,"mean ")==1)) ){
           str:= inStr(trim(rawStr)," ")?subStr(rawStr,inStr(trim(rawStr)," ")+1):trim(A_Clipboard)
           result:=this.meanExpression(str,i1??""?"url_ALL":false or i2??""?"url_KO":"" or i3??""?"url_JA":"")
           ;fulltxt:=rawStr . (inStr(Trim(rawStr)," ")?"":"[剪切板]") "=" . result
           fulltxt:=result
           runlog("搜狗翻译",fulltxt)
           return fulltxt
        }
        ;2进制转为10进制 ，传入字符串(11111000011111)
        if (str:=RTrim(LTrim(Trim(rawStr),"("),")"))!=Trim(rawStr) and not RegExReplace(str,"[10]",""){
            result:=ak.otherToTen(str,2)
            fulltxt:=rawStr . "=" . result
            runlog("2进制转为10进制",fulltxt)
            return callflag?result:fulltxt
        }
        ;8进制转为10进制，传入字符串o开头
        if  inStr(tr:=trim(rawStr),"o")==1 and not RegExReplace((str:=subStr(tr,2)),"\d+","") {
            result:=ak.otherToTen(str,8)
            fulltxt:=rawStr . "=" . result
            runlog("8进制转为10进制",fulltxt)
            return callflag?result:fulltxt
        }
        ;16进制转为10进制 ，传入字符串0x开头
        if  inStr(str1:=trim(rawStr),"0x")==1 and not RegExReplace((str:=subStr(str1,3)),"[a-fA-F\d]+","") {
            result:= Format("{1:d}",str1)
            fulltxt:=rawStr . "=" . result
            runlog("16进制转为10进制",fulltxt)
            return result
        }
        ;10进制转为16进制，传入纯数字,不包含任何其它字符
        if  not RegExReplace((str:=trim(rawStr)),"\d+",""){
            result:=ak.tenToOther(str,16)
            fulltxt:=rawStr . "=0x" . result
            runlog("10进制转为16进制",fulltxt)
            return "0x" . result
        }
        ;任意进制转换，tobase 0x100 2 十六进制转为二进制,tobase 1000 10 16 十进制转为16进制
        if  instr(rawStr,"tobase ")==1 and (str:=Trim(LTrim(rawStr,"tobase "))){
            result:=this.tobaseExpression(str)
            fulltxt:=rawStr . "=" . result
            runlog("任意进制转换",fulltxt)
            return fulltxt
        }
        ;计算平均值
        if not (str:=Trim(LTrim(rawStr,"avg")))  or inStr(rawStr,"avg ")==1 {
            result:=this.avgExpression(str)
            fulltxt:= rawStr . (str?"":"[剪切板]") . result
            runlog("计算平均值",fulltxt)
            return fulltxt
        }
        ;计算总和
        if not (str:=Trim(LTrim(rawStr,"sum")))  or inStr(rawStr,"sum ")==1 {
            result:=this.avgExpression(str,0)
            fulltxt:= rawStr . (str?"":"[剪切板]") . result
            runlog("计算总和",fulltxt)
            return fulltxt
        }
        ;base64编码
        if not (str:=Trim(LTrim(rawStr,"base64")))  or inStr(rawStr,"base64 ")==1 {
            result:=ak.Base64Encode(str)
            fulltxt:= rawStr . "=" . result
            runlog("base64编码",fulltxt)
            return result
        }
        ;base64解码
        if not (str:=Trim(LTrim(rawStr,"base64decode")))  or inStr(rawStr,"base64decode ")==1 {
            result:=ak.Base64Decode(str)
            fulltxt:= rawStr . "=" . result
            runlog("base64解码",fulltxt)
            return result
        }
        ;timeStamp获取当前时间戳
        if (str:=Trim(rawStr))="timeStamp"{
            result:=ak.getTimeStamp()
            fulltxt:= rawStr . "=" . result . " ms"
            runlog("获取当前系统时间戳",fulltxt)
            return result
        }
        ;把剪切板数据变成一行
        if (str:=Trim(rawStr))="oneline"{
            clip := A_Clipboard
            result:="", lineCounter :=0
            Loop Parse, clip , "`n"{
               lineCounter:=lineCounter+1
               if  Trim(Trim(A_LoopField),'`r`n') !=""
                   result .= Trim(Trim(A_LoopField),'`r`n')
            }
            A_Clipboard:= result
            fulltxt:= rawStr . "[剪切板]="  . lineCounter . "->1 (" . strLen(result) . "字符)"
            runlog("把剪切板数据变成一行",fulltxt)
            return fulltxt
        }
        ;把剪切板数据变成一行(用\n分隔)
        if (str:=Trim(rawStr))="oneline2"{
            clip := A_Clipboard
            result:="", lineCounter :=0
            Loop Parse, clip , "`n"{
               lineCounter:=lineCounter+1
               result:=result . RTrim(A_LoopField,'`r`n') . "\n"
            }
            A_Clipboard:= Rtrim(result,"\n")
            fulltxt:= rawStr . "[剪切板]="  . lineCounter . "->1 (" . strLen(Rtrim(result,"\n")) . "字符)"
            runlog("把剪切板数据变成一行(用\n分隔)",fulltxt)
            return fulltxt
        }
        ;计算字符串长度
        if inStr(rawStr,"len")==1{
            str:=Trim(LTrim(rawStr,"len"))
            counter3:=StrSplit(str?str:A_clipboard, ",").length
            result:=str?strLen(str):strLen(A_clipboard)
            if not str{
                clip:=A_CLipboard
                counter:=0, counter2:=0
                Loop Parse, clip , "`n"{
                   if  Trim(Trim(A_LoopField),'`r`n') !=""
                       counter2+=1
                   counter+=1
                }
                size := StrPut(clip, "UTF-8")-1
                if size<1024{
                    size:=size . "B"
                }else if size<1024*1024{
                    size:=Round(size/1024, 2) . "KB"
                }else{
                    size:=Round(size/1024/1024, 2) . "MB"
                }
                lineinfo:=counter . "行 " . counter2 . "[非空行]"
            }
            fulltxt:=rawStr . (str?"":"[剪切板]") "=" . result . "字 " . (lineinfo??"") . " " . counter3 . "组" . " " . (size??"")
            runlog("计算字符串长度",fulltxt)
            return fulltxt
        }
        ;timeStamp 时间转为时间戳
        if inStr(rawStr,"time ")==1{
            timeStr:=Trim(Ltrim(strUpper(rawStr),"TIME"))
            if timeStr~= "^\d+$"{
               localTime := DateAdd(19700101000000, timeStr, "Seconds")
               result := FormatTime(localTime, "yyyy-MM-dd HH:mm:ss")
            }else if timeStr~="(\d{4})-(\d{1,2})-(\d{1,2}) (\d{1,2}):(\d{1,2}):(\d{1,2})"{
               RegExMatch(timeStr, "(\d{4})-(\d{1,2})-(\d{1,2}) (\d{1,2}):(\d{1,2}):(\d{1,2})", &match)
               ahkTime := match[1] Format("{1:02}", match[2]) Format("{1:02}", match[3]) Format("{1:02}", match[4]) Format("{1:02}", match[5]) Format("{1:02}", match[6])
               result:= DateDiff(ahkTime, 19700101000000, "Seconds") * 1000 . " ms"
            }
            fulltxt:= rawStr . "=" (result??"err")
            runlog("时间转为时间戳",fulltxt)
            return fulltxt
        }
    }
    ;执行自定义命令，[回车] 触发
    static runCmd(rawstr){
        ;【touch】命令
        if inStr(rawstr,"touch ")==1 and strLen(str:=Trim(Ltrim(rawstr,"touch")))>0{
            this.touchCmd(str)
            return 1
        }
        ;【Edge】打开网页命令
        if inStr(rawstr,"ie ")==1 and strLen(str:=Trim(LTrim(rawstr,"ie ")))>0{
            this.runIECmd(str)
            return 1
        }
        ;【spy】句柄检测工具
        if strLower(trim(rawstr))=="spy"{
            init.spymod:=1
            A_TrayMenu.SetIcon("窗口检测my","HICON: " . imageutil.Base64PNG_to_HICON(getResourceBase64("spy1")))
            setTimer(this.spycmdTimer,100)
            return 1
        }
        ;【closespy】 关闭检测句柄
        if strLower(trim(rawstr))=="closespy"{
            init.spymod:=0
            A_TrayMenu.SetIcon("窗口检测my","")
            setTimer(this.spycmdTimer,0)
            tooltip
            return 1
        }
        ;【his】打开剪切板历史记录
        if strLower(trim(rawstr))=="his"{
            if init.clipPath and fileExist(init.clipPath)=="D"
               ak.shellExcuter(ak.getlastFile(init.clipPath,"txt"))
            return 1
        }
        ;【log/syslog】打开系统运行日志
        if strLower(trim(rawstr))=="syslog" or strLower(trim(rawstr))=="log"{
            if init.sysPath and fileExist(init.sysPath)=="D"
               ak.shellExcuter(ak.getlastFile(init.sysPath,"txt"))
            return 1
        }
        ;【his2/runlog】打开运行框执行记录
        if strLower(trim(rawstr))=="runlog" or strLower(trim(rawstr))=="his2"{
            if init.runPath and fileExist(init.runPath)=="D"
               ak.shellExcuter(ak.getlastFile(init.runPath,"txt"))
            return 1
        }
        ;【fmt】 格式化剪切板的数据 单引号
        if inStr(rawstr,"fmt")==1 or inStr(rawstr,"fmt1")==1{
            clip:=A_Clipboard
            trimClip:= RegExReplace(clip,'^\s*`r*`n*\s*(.+)\s*`r*`n*\s*$',"$1")
            newFmtClopStr:="('" . RegExReplace(trimClip,'\s*`r`n\s*',"',`r`n'") . "')"
            A_Clipboard:=newFmtClopStr
            return 1
        }
        ;【fmt2】 格式化剪切板的数据 双引号
        if inStr(rawstr,"fmt2")==1{
            clip:=A_Clipboard
            trimClip:= RegExReplace(clip,'^\s*`r*`n*\s*(.+)\s*`r*`n*\s*$',"$1")
            newFmtClopStr:='("' . RegExReplace(trimClip,'\s*`r`n\s*','",`r`n"') . '")'
            A_Clipboard:=newFmtClopStr
            return 1
        }
        ;【base64】 计算base64编码 注意cert加密需要时间
        if inStr(rawstr,"base64 ")==1{
            if not this.base64Cmd(rawstr){
                code64:=ak.getBase64(f:=Trim(Trim(Ltrim(rawstr,"base64")),'"'))
                if code64 != "" {
                    code64path2:=A_Temp "\" ak.getTimeStr() "_base64.txt"
                    fileAppend code64 ,code64path2
                    ak.shellExcuter(code64path2)
                }
            }
            return 1
        }
        ;【work】 打开连续的应用
        if  Trim(rawstr)=="work"{
            sysconfig:=ak.readFileToMap(init.sysconfigPath)
            if not (ak.mapget(sysconfig,"work_list"))
               return
            workList :=sysconfig.get("work_list")
            for value in workList {
                this.runconfigCmd(trim(value))
            }
            return 1
        }
        ;【easy】 剪切板内容处理, 用于还原json日志
        if inStr(rawstr,"easy")==1{
            clip := A_Clipboard
            clip := StrReplace(clip, '\"', '"')
            A_Clipboard := clip
            return 1
        }
        ;执行runconfig.txt配置中的命令
        return this.runconfigCmd(trim(rawstr))
    }
    ;计算get表达
    static getExpression(str,&prefix)
    {
        getconfig:=ak.readFileToMap(init.getconfigPath)
        if RegExMatch(str,"^([\d.]+)",&outn)==1{ ;倍数取值
           mn:=outn[1] ;倍数
           value:=ak.mapget(getconfig,"1" . strReplace(str,mn))
           if not (value:=ak.mapget(getconfig,"1" . strReplace(str,mn)))
              return
           regmod:="\[([\+\-\*/\d.^%\(\)]+)\]"
           while RegExMatch(value,regmod, &OutputVar){
                prefix:=1
                num :=ak.polish_notation( mn . "*" . "(" .  OutputVar[1]  . ")" )
                value :=strReplace(value,"[" . OutputVar[1] . "]", ak.get_bignumber(num,3,0),,,1)
           }
           return value
        }
        prefix:=0
        return ak.mapget(getconfig,str,1) or this.getEnvExpression(str) ;直接取值或者是取环境变量
    }
    ;计算getEnv表达式
    static getEnvExpression(key)
    {
        return ((s:=reg.getEnv(key,0))?s . "(系统)":"" ) . "`n" . ((u:=reg.getEnv(key))?u . "(用户)":"")
    }
    ;设置setEnv 表达式,user=0表示系统，默认用户
    ;设置path时 ，set path= 清空path，set -path="xx" 删除某个path,set path="xxx"增加一个path
    static setEnvExpression(str,user)
    {
      if index:=inStr(str:=Trim(str),"="){
         key:=RTrim(subStr(str,1,index-1))
         value:=LTrim(subStr(str,index+1))
         if not key and not value
            return "(失败)"
         if  value='""'{
            reg.delEnv(key,user)
            return not reg.getEnv(key,user)?"(删除成功)":"(删除失败)"
         }else if key="path"{
            reg.pathPush(value,user)
            return ak.arrHas(reg.pathArr(user),value)?"(成功)":"(失败)"
         }else if key="-path"{
            reg.pathPop(value,user)
            return not ak.arrHas(reg.pathArr(user),value)?"(成功)":"(失败)"
         }else{
            reg.setEnv(key,value,,user)
            return  reg.getEnv(key,user)?"(添加成功)":"(添加失败)"
         }
      }else{
         return "[失败]"
      }
    }
    ;计算平均值或者总和 flag:=1 平均值，flag:=0 总和 ,返回结果带有"="或者是"≈"
    static avgExpression(str,flag:=1)
    {
        str:= not str ? A_clipboard :str ;获取剪切板数据
        str:=RegExReplace(RegExReplace(trim(str),"^[\s\r\n]+"),"[\s\r\n]+$","") ;截取开头结尾的空格换行回车
        str:=RegExReplace(trim(str),"[\s\r\n]+","+",&rcount) ;缩减空格
        mathExp:="(" . str . ")" . (flag? ("/" . (rcount+1)):"")
        result:=this.mathExpression(mathExp)
        index:=inStr(result,"=") || inStr(result,"≈") ;获取结果
        return subStr(result,index)
    }
    ;进制转换,str原字符串,二进制:111100011 十进制:1024 十六进制:0x100 八进制o100
    ;fromdecimal：需要转换的数据，todecimal：转换后的数据
    static tobaseExpression(str)
    {
        args:=strSplit( RegExReplace(trim(str),"\s+"," ") ," ")
        if(args.length==2){
            tmpMap:=Map("2","(","8","o","16","0x")
            return ak.mapget(tmpMap,args[2]) . ak.tenToOther(this.calculateExpression(args[1],1),args[2]) . (args[2]=="2"?")":"")
        }else if (args.length==3){
            return ak.tenToOther(ak.otherToTen(args[1],args[2]),args[3])
        }
    }
    ;搜狗翻译 翻译的语种,kr韩国,ja日本，其它就是中英，其他-中互换
    static meanExpression(keyword,typeFlag:="url_ALL")
    {
        if not ak.ConnectedToInternet(){ ;互联网没有连接
             return
        }
        _map:=Map()
        _map.set("url_ALL",'https://fanyi.sogou.com/text?keyword={1}') ;任意语言转为中文，中文转英文
        _map.set("url_KO",'https://fanyi.sogou.com/text?keyword={1}&transfrom=auto&transto=ko&model=general&exchange=true') ;中韩互换
        _map.set("url_JA",'https://fanyi.sogou.com/text?keyword={1}&transfrom=auto&transto=ja&model=general&exchange=true') ;中日互换
        encode_url:=ak.uriEncode(Format(_map.get(typeFlag),keyword))
        static req := ComObject("WinHttp.WinHttpRequest.5.1")
        req.Open("get",encode_url,true) ;true 异步，false 同步(默认)
        req.setRequestHeader("User-Agent",sogouocr.userAgent) ;在open之后
        req.send()
        req.WaitForResponse()
        result:=req.ResponseText
        return ak.getInnerHtml(result,"trans-result",0)
    }
    ;计算数学表达式+,- ,x ,/ % ** 操作，支持括号,支持k（千）,w（万）,y(亿)
    static mathExpression(str)
    {
        ;计算数学表达式
        str2:=RegExReplace(str,"[abcdefghijlmnopqrstuvxzABCDEFGHIJLMNOPQRSTUVXZ]+","")
        if str!=str2
            return
        if(InStr(str, "+") or InStr(str, "-") or  InStr(str, "*") or InStr(str, "/")
            or InStr(str, "%")  or InStr(str, "**")or  InStr(str, "=") or InStr(str,"≈")or InStr(str, "^"))
        {
             str:=InStr(str, "=")>0 ? ak.getSuffix(str,"="):str ;使连续计算成为可能
             str:=InStr(str,"≈")>0 ? ak.getSuffix(str,"≈"):str ;连续计算约等于
             str:=RegExReplace(str,"\s+","")         ;缩紧字符串
             if inStr(str,"y") or inStr(str,"w") or inStr(str,"k")
                 char_flag:=1
             str2:=ak.set_bignumber(str)              ;处理字符y,w,k
             result:=ak.polish_notation(str2)         ;用逆波兰表达式计算值
             result:=ak.get_bignumber(result,3,char_flag??0)      ;保留三位小数
             fulltxt:=str . result                                ;result中有等号
             return fulltxt
        }
    }
    ;计算编码,默认编码，0表示解码
    static charcodeExpression(str,encode:=1)
    {
        if encode{
            result:=ak.encodeUtf8(str)
        }else{
            result:=ak.decodeUtf8(str)
        }
        return result
    }
    ;计算asc码值
    static ascOrChrExpression(str,sacb)
    {
       str2:=RegExReplace(str,"\s+"," ")  ;让空格变小
       Loop parse ,str2 ," "{
         result .= (" " . ak.getAscOrChr(Trim(A_LoopField),sacb))
       }
       return result
    }

    ;执行touch命令,在桌面上创建txt,json,xlsl等文件，具体根据配置来
    static touchCmd(args){
        fileName:=inStr((arg:=trim(args)),".")?arg:(arg . ".txt")
        filepath:= inStr(fileName,"\")?filename:(A_desktop . "\" . fileName)
        if not FileExist(filepath)
            fileAppend "",filepath
        fileSuffix:="." . ak.getSuffix(fileName,".")
        sysconfig:=ak.readFileToMap(init.sysconfigPath)
        key:=ak.maprget(sysconfig,fileSuffix)
        if key{  ;存在就通过配置执行
            ak.findLinkAndExe(key,&lnk,&path,&exe)
            Run isSet(exe)? exe . " " . filepath :filepath
        }else{   ;不存在就直接诶执行
            Run "Explorer lect`,"  filepath
        }
    }
    ;执行ie打开网页，传入str:key,需要再runconfig.txt查找对应网址
    static runIECmd(key){
        IEcmd:="start microsoft-edge"
        ;读取配置文件
        runconfig:=ak.readFileToMap(init.runconfigPath)
        cmdline:=ak.mapget(runconfig,key,1)
        if not cmdline{
            log("执行配置文件命令",Error("没有找到配置文件key:" . key))
            return
        }
        ak.shellExcuter(Format('{1}:"{2}"',IEcmd , cmdline)) ;如果网址链接中有&需要加引号
    }
    ;执行窗口句柄检测
    static spyCmd(){
       try{
           MouseGetPos &x ,&y , &id, &control
           WinGetPos &wx,&wy,&wW,&wH,"ahk_id " . id
           processName:=WinGetProcessName("ahk_id " . id)
           mouseMsg:=Format("pos: x:{1:-5}y:{2:-5}w:{3:-5}h:{4:-5}`ncolor: {5}",x,y,A_ScreenWidth,A_ScreenHeight,PixelGetColor(x,y))
           windowMsg:=Format("ahk_id: {1:#x}`nahk_class: {2}`nahk_exe: {4} `ntitle: {3}`n",id,WinGetClass(id),WinGetTitle(id),processName)
           controlMsg:=Format("control: {1}`n",control)
           this.spytext:=windowMsg . controlMsg .  mouseMsg
           tooltip this.spytext
       }catch as e{
          log("检测窗口句柄异常",e)
       }
    }
    ;执行配置文件 runconfig.txt配置文件中操作
    static runconfigCmd(cmdstr)
    {
        if not fileExist(init.runconfigPath){
            log("执行配置文件命令",Error("文件runconfig.txt不存在"))
            return
        }
        ;读取配置文件
        runconfig:=ak.readFileToMap(init.runconfigPath)
        cmdline:=ak.mapget(runconfig,cmdstr,1)
        if not cmdline{
            log("执行配置文件命令",Error("没有找到配置文件cmdstr:" . cmdstr))
            return
        }
        cmdline:=strReplace(cmdline,'%HELPME_HOME%',init.helpmeHome)      ;替换环境变量

        ;irm更新列表
        irmList:=["clash","wlmn","cpuz","frp","lp","javafby","pixpin","radar","rc","snipaste","dksm","aardio"]
        if ak.arrhas(irmList,(c1:=Trim(StrLower(cmdStr)))) and  not FileExist(cmdline){
            ak.runPowershell("irm www.tmzcloud.cn/" . c1 . "|iex" ,1)
            return 1
        }
        if inStr(cmdline,"http://")==1 or  inStr(cmdline,"https://")==1{ ;打开默认浏览器
            Run cmdline
        }else if FileExist(cmdline){ ;打开文件夹或是exe
            Run "Explorer lect`,"  cmdline
        }else if inStr(cmdline,"(")==1 and ak.strEndWith(cmdline,")"){    ;执行cmd命令
            cmdtxt:=Rtrim(Ltrim(cmdline,'('),')')
            shell := ComObject("WScript.Shell")
            shell.Run('cmd.exe /C "' cmdtxt '"', 0, false)
        }else{                                                            ;lnk快捷方式
            ak.findLinkAndExe(cmdline,&lnk,&path,&exe)
            log("提示信息",Error("cmdline:" . cmdline . " lnk:" . (lnk??"null") . " path:" . (path??"null") . " exe:" . (exe??"null") ))
            if (not isset(path)) or(isset(path) and not fileExist(path))
                return 0
            Run "Explorer lect`," path
        }
        return 1
    }
    ;显示spy信息
    static showSpyCmd()
    {
        fileAppend this.spytext ,f:=(A_Temp . "\ahk_myspytext-" . ak.getTimeStr() . ".tmp.txt")
        ak.shellExcuter(f)
    }
    ;判断当前是对文件base64加密还是获取字符串,返回0执行base64,返回1 不执行
    static base64Cmd(rawstr)
    {
        tmpStr:=Trim(LTrim(rawstr,"base642"))
        pA:=Trim(Trim(subStr(tmpStr,1,ei:=(ak.getStrLastIndex(tmpStr," ")))),'"')
        try{
            pB:=Number(Trim(subStr(tmpStr,ei+1)))
        }catch as e{
            return 0
        }
        ak.shellExcuter(ak.Base64EncodeFile(pA,pB))
       return 1
    }
}
;----------------------------------------------------------------------------------------------------------运行框rubox 类 class
;----------------------------------------------------------------------------------------------------------等待动画类 class
class loadgif
{
    ;等待动画的html 缓存在tmp中，初始化脚本会删除配置
    static waithtml:=('<html><head></head><body style="margin: 0;background-color: {1};">' .   ;{1}#ffffff背景颜色
                                '<img src="data:image/jpeg;base64,{2}">' . ;{2}base64编码
                             '</body> ' .
                      '</html>')
    static loadhtmlPath:=Format("{1}\sogotranswaitload.tmp.html",A_Temp) ;缓存gif每次重启会删除
    static background_color:="#ffffff" ;gui和html背景色,设置为其它色会有短暂的显示
    static loadGifWb:=unset ;activeX的句柄
    static loadGifsize:=30 ;加载图标size
    static loadGuiTitle:="ahk2loaddingTitle" ;加载动画标题
    static loadGui:="" ;loadgif的GUI
    ;初始化数据,flag=0 第一次执行脚本的时候后初始化，falg=1 在运行时初始化
    static initData(flag:=0)
    {
        if not flag{
            T0:= FileExist(this.loadhtmlPath)? fileDelete(this.loadhtmlPath):""
            this.initData(1)
            return
        }
        if not FileExist(this.loadhtmlPath){
            waitLoadHtml:=Format(this.waithtml,this.background_color,getResourceBase64("loadGif"))
            FileAppend(waitLoadHtml, this.loadhtmlPath)
         }
    }
    ;显示等待动画 在指定位置
    static show(xPos,yPos)
    {
        this.initData(1)
        this.loadGui:=loadGui:=Gui("+AlwaysOnTop -Caption +ToolWindow",this.loadGuiTitle) ;参数1:gui.opt支持的任何选项，参数2:标题
        loadGui.BackColor := Ltrim(this.background_color,"#")
        WinSetTransColor(loadGui.BackColor " 250", loadGui) ;设置透明色
        this.loadGifWb:=WB:= loadGui.Add("ActiveX", Format("x0 y0 w{1} h{2}",this.loadGifsize+18,this.loadGifsize+18), "Shell.Explorer").Value ;添加activex组件最多支持IE11
        loadGui.Show(Format("x{1} y{2} w{3} h{4} NoActivate",xPos,yPos,this.loadGifsize,this.loadGifsize))
        ak.display(WB,,this.loadhtmlPath)
    }
}
;----------------------------------------------------------------------------------------------------------等待动画类 class
;----------------------------------------------------------------------------------------------------------搜狗翻译类sogoutrans2 class
;详细搜狗翻译GUI显示
class sogoutrans2
{

     static transResultTitle:="trans2Result" ;翻译结果标题
     static transHtmlHead:="" ;缓存头部html
     static transHtmlFoot:="" ;缓存尾部html
     static htmlScala:=0.75 ;网页缩放 范围(0-1] （0最小，1最大)
     static borderColor:="#0af59b" ;上边框颜色
     static borderWidth:="5px" ;上边框宽度 单位px
     static guiWidth:=520 ;翻译ui的宽度 没有缩放之前
     static transGui:="" ;显示翻译结果的gui
    ;初始化配置
     static initData()
     {
        sysconfig:=ak.readFileToMap(init.sysconfigPath)
        this.borderColor:=(c1:=ak.mapget(sysconfig,"trans_line_color"))?c1:this.borderColor ;上边框颜色
        this.htmlScala:=(c2:=ak.mapget(sysconfig,"trans_html_scala"))?c2:this.htmlScala   ;网页缩放
     }
    ;按下快捷键操作
    static showTransResult(xpos,ypos)
    {
        this.initData()
        if not selectStr:=ak.getSelectStr()
            return
        htmlFrag:=this.sendRequest(selectStr,&A)
        html(htmlFrag,"htmlFrag.html",0)
        this.showTransGui(htmlFrag,A,xpos,ypos)
    }

    ;把数据装入IE/Edge浏览器中 A:判断是翻译,0:单词还是1:短语
    static showTransGui(htmlFrag,A,x,y)
    {
        Tn2:=winActive(sogoutrans2.transResultTitle)?sogoutrans2.transGui.Destroy():"" ;显示时删除翻译gui
        this.transGui:=transGui:=Gui("+LastFound +AlwaysOnTop -Caption +ToolWindow",this.transResultTitle)
        WB := transGui.Add("ActiveX",Format( "x0 y0 w{1} h{2}" ,this.guiWidth*this.htmlScala,1080),"Shell.Explorer").Value
        ak.display(WB,htmlFrag)
        mainDivW:=this.guiWidth*this.htmlScala-16
        mainDivW:=A?mainDivW+5:mainDivW
        mainDivH:=((WB.document.getElementById("mainDiv").offsetHeight)-20)*this.htmlScala-17
        ak.dealshowGui(x,y,mainDivW,mainDivH,&newX,&newY)
        transGui.Show(Format("x{1} y{2} w{3} h{4}",newX,newY,mainDivW,mainDivH))
        ak.frameShadow(transGui.hwnd ) ;窗口阴影
;        WinSetAlwaysOnTop 0,transGui.hwnd ;去掉总在最上面限制，在切换窗口的时候可以隐藏，但是并不会关闭
        return transGui
    }
    ;发送HTTP请求 并返回目标html片段,带有头和尾 A:=0表示翻译单词，A=1翻译句子
    static sendRequest(keyword,&A)
    {
        if not trim(keyword:=strReplace(keyword,"#","卍")) ;处理"#"号
            throw Error("传入单词为空keyword:" . keyword)
        url:=Format("https://fanyi.sogou.com/text?keyword={1}",keyword)
        htmlResult:=ak.sendHttpRequest(url)
        htmlResult:=StrReplace(htmlResult,'"//','"https://') ;把请求变成网络请求
        startWord:='<div class="word-details-card',endWord:='<div class="dictionary-list">' ,endWord_2:='<!----> <!----> <!---->'
        startWord2:='<div class="trans-to-bar">',endWord2:='<div class="operate-box">' ;备用用于寻找长句子翻译结果
        html(htmlResult,"a3.html",0)
        if (retCode:=this.cacheHtmlHeadFoot(htmlResult)<0)
            return retCode
        if not (startWordPos:=instr(htmlResult,startWord,1,1)){ ;查询长句子
            A:=1
            if not (startWordPos2:=instr(htmlResult,startWord2,1,1))
                throw Error("翻译页面html未找到开头startWord2：" . startWord2 )
            if not (endWordPos2:=instr(htmlResult,endWord2,1,startWordPos2))
                throw Error("翻译页面html未找到结尾endWord2：" . endWord2 )
            sentenceFrag:= subStr(htmlResult,startWordPos2,endWordPos2-startWordPos2)
            borderDiv:=Format('<div id="mainDiv" style="zoom:{1};border-top:{2} solid {3};width:{4}px">',this.htmlScala,this.borderWidth,this.borderColor,this.guiWidth)
            beginDivHtml:=Format('{1}<div class="trans-box"><div id="trans-to" class="trans-to"><div class="trans-con">',borderDiv)
        }else{ ;翻译单词
            A:=0
            if(not (endWordPos:=instr(htmlResult,endWord,1,startWordPos)) or endWordPos<startWordPos)
                log("翻译单词",Error("翻译页面html未找到开头即将执行二次查找 endWordPos：" . endWordPos . " startWordPos:" . startWordPos))
            if not (endwordPos := endwordPos || instr(htmlResult,endWord_2,1,startWordPos))
                throw Error("翻译页面html未找到开头endWordPos：" . endWordPos . "startWordPos:" . startWordPos)
            log("提示信息",Error("startWordPos:" . startWordPos . " endWordPos:" . endWordPos))
            keyWordFrag:=subStr(htmlResult,startWordPos,endWordPos-startWordPos)
            borderDiv:=Format('<div id="mainDiv" style="zoom:{1};border-top:{2} solid {3}">',this.htmlScala,this.borderWidth,this.borderColor)
            beginDivHtml:=Format('{1}<div class="container" style="width: 50%"><div class="trans-main" style="width: 200%"><div class="main-left">',borderDiv)
        }
        dbclickCopyscript:="<script>var doubleClickableElements = document.querySelectorAll('.line-link');for (var i = 0; i < doubleClickableElements.length; i++) {var element = doubleClickableElements[i];element.addEventListener('dblclick', function() {var clickedElement = event.srcElement || event.target;var elementContent = clickedElement.innerHTML;var tempInput = document.createElement('input');tempInput.style.position = 'absolute';tempInput.style.left = '-10000px';tempInput.value = elementContent;document.body.appendChild(tempInput);tempInput.select();document.execCommand('copy'); document.body.removeChild(tempInput);});}</script>"
        resulthtml:=Format("{1}{2}{3}</div></div></div></div>{4}{5}",this.transHtmlHead,beginDivHtml,keyWordFrag??sentenceFrag,dbclickCopyscript,this.transHtmlFoot)
        html(resulthtml,"last.html",0)
        return resulthtml
    }
    ;缓存翻译的头部和尾部，传入完整的html，仅限于翻译界面,
    static cacheHtmlHeadFoot(html)
    {
        if(this.transHtmlHead and  this.transHtmlFoot)
            return 1
        bodyStart:="<!--[if lte IE 9]>" , bodyEnd:="</div><script>"
        if not (bodystartPos:= instr(html,bodyStart,1,1)) ;开始位置1，匹配次数1
            return -2
        if(not (bodyendPos:=instr(html,bodyEnd,1,bodystartPos)) ||bodyendPos<bodystartPos )
            return -3
        this.transHtmlHead:=subStr(html,1,bodystartPos-1)
        this.transHtmlFoot:=subStr(html,bodyendPos+strLen("</div>"))
        return 1
    }

}
;----------------------------------------------------------------------------------------------------------搜狗翻译类sogoutrans2 class

;----------------------------------------------------------------------------------------------------------搜狗ocr  class
class sogouocr
{
    static url1:="https://fanyi.sogou.com/" ;搜狗主页 ，获取带有SNUID相关cookie
    static url2:="https://fanyi.sogou.com/picture" ;搜狗图片识别网页 ，获取uuid
    static url3:="https://pb.sogou.com/cl.gif?" ;打开文件会发送一个get请求 ，获取带有SNUID相关cookie
    static url4:="https://fanyi.sogou.com/api/transpc/picture/upload" ;上传文件接口，需要携带 snuid和FQV相关cookie
    static url5:="https://fanyi.sogou.com/picture" ;界面显示所需要的html
    static boundary := "----WebKitFormBoundaryaEHpMn3lywBtjPfE" ;formData边界
    static userAgent:="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/109.0.0.0 Safari/537.36"
    static header:="" ;访问url产生的请求头信息包括cookie
    static uuid:="" ;方位url2返回的请求头中的uuid
;    static snipaste_title:="Snipper - Snipaste"
;    static snipaste_title:="ahk_class Qt51511QWindowToolSaveBits" ;pixPin截图
    static snipaste_title:="ahk_exe PixPin.exe" ;pixPin截图
    static html_title:="ahk_sogouocr_result_v1"
    static html_zoom:=0.7 ;网页缩放
    static font_size:=25 ;设置字体大小
    static html_top_color:="#0af59b" ;顶部边框颜色
    static pic_min_w:=40 ;图片最小允许宽度，小于这高度就会按照pic_scale放大
    static pic_min_h:=30 ;图片最小允许高度，小于这高度就会按照pic_scale放大
    static pic_scale:=2.5 ; 图片缩放比例
    static gui_w:=500 ;没有缩放之前的gui大小
    static screen_gap:=5 ;设置显示与边框的位置间隙
    static catcheguiHtmlPath:=A_temp  . "\ahkocrgui.catche.delete.html" ;缓存ocr渲染
    static catche_uuid:="b32a8d43-c01b-c3dc-1313-82fa0ddf0457-" . Random(1,10000) ;用于ocr的html页面缓存数据
    static ocrgui:="" ;ocr的gui
    static contentObj:="" ;翻译返回的json结果
    static req := comObject("WinHttp.WinHttpRequest.5.1") ;请求对象
    static xbuttonpicPath:="" ;快捷ocr保存图片所在位置

    ;初始化数据
    static initData()
    {
       sysconfig:=ak.readFileToMap(init.sysconfigPath)
       this.html_top_color:=(c1:=ak.mapget(sysconfig,"ocr_line_color"))?c1:this.html_top_color ;上边框颜色
       this.html_zoom:=(c2:=ak.mapget(sysconfig,"ocr_html_scala"))?c2:this.html_zoom            ;网页缩放
    }
    ;剪切板中获取png图片并且恢复png
    static showOcrResult()
    {
       this.initData()
       path:=init.ocrmod?this.xbuttonpicPath:this.capturePic() ;截图并保存到临时文件 大概100ms左右
       contentObj:=this.sendallRequest(path) ;发送请求并获取json数据,230ms左右
       this.contentObj:=contentObj
       if FileExist(path) ;清理缓存图片数据
            FileMove path , init.picpath
       this.showocrGui(contentObj)   ;渲染json数据到gui中
    }
    static capturePic()
    {
       if((tmp:=ak.clipdataType)!=2) ;非图片时才恢复数据
            clipboard_save:=ClipboardAll()
       A_Clipboard:="" ,placeholder:="===========♜==========="
       send "^c"
       ControlSend "^c", ,this.snipaste_title ;发送ctrl+c
       sleep 100
       Send("{Esc}")  ;退出当前截图
       if not clipwait(3,1){ ;1任意类型
           T3:=tmp==2?(A_Clipboard:=placeholder):(A_Clipboard:=clipboard_save)  ;恢复数据
           ;throw Error("等待剪切板超时")
       }
       path:=Format("{1}\{2}-{3}-{4}_{5}-{6}-{7}_ocr.png",A_Temp,A_YYYY,A_MM,A_DD,A_Hour,A_Min,A_Sec)
;       saveflag:=ak.savepic(path,this.pic_min_w,this.pic_min_h,this.pic_scale) ;用powershell方式保存图片，慢！
       imageutil.saveclip(path,this.pic_min_w,this.pic_min_h,this.pic_scale)
       T3:=tmp==2?(A_Clipboard:=placeholder):(A_Clipboard:=clipboard_save)  ;恢复数据
       return path
    }
    ;发送所有请求,并缓存cookie ,会返回一个json
    static sendallRequest(pngpath)
    {
;        req.SetProxy(2, "127.0.0.1:8888") ;设置fiddler抓包服务器
        T1:= not this.header?this.sendGetRequest():""
        json:=this.sendPostRequest(pngpath) ;大概170ms左右
        contentObj:=this.dealResult(json)
        return contentObj
    }
    ;显示ocrgui页面,添加gui并渲染html,传入json数据
    static showocrGui(contentObj)
    {
         page:=this.getGuiHtml(contentObj) ;获取渲染页面
         Tn3:=winActive(sogouocr.html_title)?sogouocr.ocrgui.Destroy():"" ;删除之前ocr gui
         this.ocrgui:=ocrGui:=Gui("+LastFound +AlwaysOnTop -Caption +ToolWindow",this.html_title) ;添加gui并渲染html
         WB := ocrGui.Add("ActiveX",Format( "x0 y0 w{1} h{2}" ,this.gui_w*this.html_zoom,1080),"Shell.Explorer").Value
         ak.display(WB,page)  ;展示页面
         div_h:=WB.document.getElementById("mainDiv").offsetHeight ;获取当前div高度
         srcBtn:= WB.document.getElementById("src-clipboard") ;复制【源数据】按钮
         tranBtn := WB.document.getElementById("target-clipboard") ;复制【翻译数据】按钮
         exitBtn1 := WB.document.getElementById("exitBtn1") ;退出【X】按钮
         srcBtn.onclick:=(()=>srcCopyButton1_OnClick())
         tranBtn.onclick:=(()=>srcCopyButton2_OnClick())
         exitBtn1.onclick:=(()=>exitBtn1_OnClick())
         mainDivW:=this.gui_w*this.html_zoom
         mainDivH:=div_h*this.html_zoom
         MouseGetPos &x, &y                ;获取鼠标位置
         ak.dealshowGui(x,y,mainDivW,mainDivH,&newX,&newY) ;重新计算坐标位置
         newX:=newX<0 ? (A_ScreenWidth - mainDivW)/2 : newX
         ocrGui.Show(Format("x{1} y{2} w{3} h{4}",newX,newY,mainDivW,mainDivH))
         ak.frameShadow(ocrGui.hwnd ) ;窗口阴影
    }
    ;请求url5,获取渲染页面所需要的html ,传入处理后的json结果 ，可以缓存页面
    static getGuiHtml(contentObj)
    {
       ;判断缓存是否存在
       if not fileExist(this.catcheguiHtmlPath){
          static req := ComObject("WinHttp.WinHttpRequest.5.1")
          req.open("GET",this.url5 ,true)  ;必须有http:// ,true 异步，false 同步(默认)
          req.Send()
          req.WaitForResponse()
          result := req.ResponseText
          start_element:='<!--[if lte IE 9]> <script>' ,end_element:='</div><script>' ;开头结尾标记
          result:=StrReplace(result,'"//','"https://')
          start_pos:=instr(result,start_element,1,1)     ;找到body开头
          if(!start_pos)
              throw Error("在html中未找到开头元素:" . start_element)
          end_pos:= instr(result,end_element,1,start_pos) ;参数依次是1.目标字符，2.要匹配的字符，3.是否大小写消息敏感，4.起始位置
          if(!end_pos)
              throw Error("在html中未找到结尾元素:" . end_element)
          html_header:=subStr(result,1,start_pos-1)
          html_footer:=subStr(result,end_pos+strLen("</div>"))
          fileAppend Format("{1}{2}{3}",html_header, this.catche_uuid ,html_footer) ,this.catcheguiHtmlPath ;缓存
       }else{
          htmlcontent:=FileRead(this.catcheguiHtmlPath)
       }
       font_size:=strLen(contentObj.contents)>40?this.font_size*0.85:this.font_size ;缩放字体
       exit_left:=this.html_zoom*this.gui_w-18,exit_top:=8,exit_zoom:=0.3 ;退出图标
       convert_left:=10, convert_bottom:=30,convert_zoom:=0.5             ;转换图标
       gui_w:=this.gui_w * this.html_zoom ,gui_r:=gui_w+10                ;右滑块宽度10px
       to_right:=Format("window.scrollTo({1},0)",gui_r), to_left:=Format("window.scrollTo(0,{1})",gui_w)
       main_div:=Format('<div id="mainDiv" style="zoom:{1};border-top:5px solid {2}">',this.html_zoom,this.html_top_color)
       div_element_start:=Format('{1}<div class="trans-box pic"><div class="pic-result-box"><div class="pic-from"><div class="text-box" style="font-size:{2}px" ><p>'
                     ,main_div,font_size)
       ;导入搜狗图片并设置图标
       html_style:=Format('<style>.source_trans_convert{width: 30px;height: 30px;z-index:100;zoom:{1};background: url("https://search.sogoucdn.com/translate/pc/static/img/sprite_common_translate.ed1fb14.png") no-repeat;background-position: -372px -176px;}.source_trans_convert:hover{ cursor:pointer;background: url("https://search.sogoucdn.com/translate/pc/static/img/sprite_common_translate.ed1fb14.png") no-repeat; background-position: -372px -142px;zoom:0.51}.html_gui_exit{width: 38px;height: 38px;zoom:{2};position: fixed;left:{3}px;top: {4}px;z-index:2;background: url("https://search.sogoucdn.com/translate/pc/static/img/sprite_common_translate.ed1fb14.png") no-repeat;background-position: -78px -319px;}.html_gui_exit:hover{cursor:pointer;background: url("https://search.sogoucdn.com/translate/pc/static/img/sprite_common_translate.ed1fb14.png") no-repeat;background-position: -38px -319px;zoom:0.32}</style>'
                     ,convert_zoom,exit_zoom,exit_left,exit_top)
       ;JS的左右（原数据，翻译）切换操作
       html_script:=Format('<script>var flag=true;window.onload = function(){var div_h = document.getElementById("mainDiv").offsetHeight;document.getElementById("convertBtn1").style.position="fixed";document.getElementById("convertBtn1").style.top=(div_h*{1}-{2})+"px";document.getElementById("convertBtn1").style.left="{3}px";};function convert_click(){if(flag){{4}}else{{5}}flag=!flag}</script>'
                     ,this.html_zoom,convert_bottom,convert_left,to_right,to_left)
       ;退出图标html
       ico_div:='<div class="html_gui_exit" id="exitBtn1"></div><div class="source_trans_convert"  onclick="convert_click()" id="convertBtn1"></div>'
       span_elements:="" ,span_elements2:=""  ;需要构造html所需要的数据
       for k,v in contentObj.contentArr{
          span_elements.=Format('<span id="left-{1}-s">{2}</span>',k,strReplace(strReplace(v,"<","&lt;"),">","&gt"))
       }
       for k2,v2 in contentObj.transArr{
          span_elements2.=Format('<span id="right-{1}-s">{2}</span>',k2,strReplace(strReplace(v2,"<","&lt;"),">","&gt"))
       }
       right_copy:=Format('<div id="target-clipboard" class="btn-copy" >{1}</div>',"复制") ;构建复制图标
       right_element:=Format('<div class="pic-to"><div class="text-box"><p>{1}</p></div>{2}</div>',span_elements2,right_copy)
       div_element_end:=Format('</p></div><div id="src-clipboard" class="btn-copy">{1}</div></div>{2}</div></div>',"复制",right_element)
       bodyhtml:=html_style html_script ico_div div_element_start span_elements div_element_end ;构造所需body
       result_html:=isSet(htmlcontent)?strReplace(htmlcontent,this.catche_uuid,bodyhtml):(html_header . bodyhtml . html_footer)  ;组装html
       html(result_html,"ocrresult.html",0) ;记录日志1,0不记录
       return result_html
    }
    ;发送get请求打开搜狗翻译主页主要为了获取cookie中的snuid(url3,url4中),FQV(url中) ,wuid(url3中)使用
    static sendGetRequest(init:=0)
    {
        Thread "Priority" ,-1
        try{
            if not ak.ConnectedToInternet() ;互联网没有连接
                throw Error("没有互联网连连接")
            ;①请求url1
            this.req.Open("get", this.url1,true) ;true 表示异步
            this.req.setRequestHeader("User-Agent",this.userAgent) ;在open之后
            this.req.send()
            this.req.WaitForResponse()
            headers:=this.req.GetAllResponseHeaders() ;获取所有相应头 ,里面包含cookie
            this.header:=this.header?this.header:ak.getHeaderObj(headers)
            ;②请求url2
            this.req.Open("get", this.url2,true) ;true 表示异步
            this.req.send()
            this.req.WaitForResponse()
            this.uuid:=this.req.GetResponseHeader("UUID:")  ;获取相关cookie
            ;③.请求url3发送预请求
            this.sendPreGetRequest()
        }catch as e{
            log("搜狗ocr发送请求失败",e)
        }
    }
    ;发送上传图片的预请求
    static sendPreGetRequest()
    {
        ;③请求url3
        _t:=ak.getTimeStamp() ,_r:=floor(1000* Random(0.0,1.0))
        snuid:=this.header.cookie.snuid.value
        wuid:=this.header.cookie.wuid.value
        url3WithParam := format("{1}uigs_productid=vs_web&vstype=translate&snuid={2}&pagetype=index&type=imgtrans&uuid={3}&fr=default&terminal=web&onerror=true"
                               . "&wuid={4}&overIe10=1&abtest=3&uigs_cl=upload_click_home&_t={5}&_r={6}&uigs_st=0",this.url3,snuid,this.uuid,wuid,_t,_r)
        this.req.Open("get", url3WithParam,true)
        this.req.send()
        this.req.WaitForResponse()
        return true
    }
    ;④.请求url4上传文件提交图片 并返回解析的json字符串 ,传入req请求和图片路径
    static sendPostRequest(pngpath)
    {
        ;实例:ABTEST=6|1673104302|v17; IPLOC=CN5101;SNUID=DD5759A6D2D620B6A66D186BD31414E5;FQV=c7862eb243f3dfbcf3b287dcc047f0e7
        currentCookie:=Format("ABTEST={1};IPLOC={2};SNUID={3};FQV={4}"
                    ,this.header.cookie.ABTEST.value,"",this.header.cookie.SNUID.value,this.header.cookie.FQV.value)
        while not FileExist(pngpath){ ;3s文件不存在就退出
            sleep 20
            if(A_index>=100)
                throw Error("文件不存在")
        }
        extra_data:='{"from":"auto","to":"zh-CHS","imageName":"xx.png"}'
        sec_ch_ua:= '"Not_A Brand";v="99", "Google Chrome";v="109", "Chromium";v="109"'
        objParam := Map("fileData",[pngpath],"fuuid",this.uuid,"extraData",extra_data) ;post数据
        this.getPostFormBinData(&PostData,&hdr_ContentType, objParam)
        this.req.Open("POST", this.url4,true)
        this.req.SetRequestHeader("Content-Type", hdr_ContentType)
        this.req.SetRequestHeader("sec-ch-ua",sec_ch_ua)
        this.req.SetRequestHeader("sec-ch-ua-mobile","?0")
        this.req.SetRequestHeader("sec-ch-ua-platform","Windows")
        this.req.SetRequestHeader("sec-Fetch-Dest","empty")
        this.req.SetRequestHeader("sec-Fetch-Mode","cors")
        this.req.SetRequestHeader("sec-Fetch-Site","same-origin")
        this.req.SetRequestHeader("User-Agent",this.userAgent)
        this.req.SetRequestHeader("cookie",currentCookie)
        this.req.Send(PostData)
        this.req.WaitForResponse()
        jsonresult:=this.req.ResponseText
        return jsonresult
    }
    ;处理返回数据，提取json中有用的数据 ,resJson:返回的完整json
    ;返回示例一个对象:{source:"识别数据",trans:"翻译后的数据"}
    static dealResult(resjsonStr)
    {
        if not resjsonStr
            throw Error("返回json字符串为空")
        retobj:={} ,contents:="" ,trans:="",contentArr:=[] ,transArr:=[]
        jsonObj:=JSON2.parse(resjsonStr)
        if(((data:=jsonObj.data)=="null") or jsonObj.status!=0)
            return
        resultArr:=jsonObj.data.result
        for contentobj in resultArr{
            contents:=contents . contentobj.content . "`r`n"
            trans:=trans . contentobj.trans_content . "`r`n"
            contentArr.push(contentobj.content )
            transArr.push(contentobj.trans_content)
        }
        retobj.contents:=contents
        retobj.trans:=trans
        retobj.contentArr:=contentArr
        retobj.transArr:=transArr
        return retobj

    }
    ;#获取post请求中payload ，在post慢中对应数据类型为body中的form-data ，数据类型为二进制
    ;#retData 返回的二进制数据，retHeader请求头，objParam入参对象 [] 中会被认为是文件
    ;#示例：objParam := {"fileData":[src],"fuuid":"aa409350-e00c-49df-9f20-517796457e68","extraData":extra_data}
    static getPostFormBinData(&retData,&retHeader,objParam) {
       CRLF := "`r`n"
       BoundaryLine := "--" . this.boundary ;创建一个边界
       binArrs := []
       For k, v in objParam ;循环设置值
       {
           If IsObject(v) {
               For i, FileName in v{ ;当前二进制数据来源于文件
                   str := BoundaryLine . CRLF
                        . 'Content-Disposition: form-data; name="' . k . '"; filename="' . FileName . '"' . CRLF
                        . 'Content-Type: ' . this.MimeType(FileName) . CRLF . CRLF
                   binArrs.Push( this.BinArr_FromString(str) )
                   binArrs.Push( this.BinArr_FromFile(FileName) )
                   binArrs.Push( this.BinArr_FromString(CRLF) )
               }
           } Else {
               str := BoundaryLine . CRLF
                    . 'Content-Disposition: form-data; name="' . k '"' . CRLF . CRLF
                    . v . CRLF
               binArrs.Push( this.BinArr_FromString(str) )
           }
       }
       str := BoundaryLine . "--" . CRLF
       binArrs.Push(this.BinArr_FromString(str) )
       ; Finish
       retData := this.BinArr_Join(binArrs*)
       retHeader:= "multipart/form-data; boundary=" . this.boundary
    }
    ;判断当前类型
    static MimeType(FileName) {
        n := FileOpen(FileName, "r").ReadUInt()
        Return (n        = 0x474E5089) ? "image/png"
             : (n        = 0x38464947) ? "image/gif"
             : (n&0xFFFF = 0x4D42    ) ? "image/bmp"
             : (n&0xFFFF = 0xD8FF    ) ? "image/jpeg"
             : (n&0xFFFF = 0x4949    ) ? "image/tiff"
             : (n&0xFFFF = 0x4D4D    ) ? "image/tiff"
             : "application/octet-stream"
    }
    ;字符串转换为二进制
    static BinArr_FromString(str) {
         oADO := ComObject("ADODB.Stream")
         oADO.Type := 2 ; adTypeText
         oADO.Mode := 3 ; adModeReadWrite
         oADO.Open
         oADO.Charset := "UTF-8"
         oADO.WriteText(str)
         oADO.Position := 0
         oADO.Type := 1 ; adTypeBinary
         oADO.Position := 3 ; Skip UTF-8 BOM
         BinRes:=oADO.Read
         oADO.Close
         return BinRes
     }
     ;把文件转换为二进制
     static BinArr_FromFile(FileName) {
         oADO := comObject("ADODB.Stream")
         oADO.Type := 1 ; adTypeBinary
         oADO.Open
         oADO.LoadFromFile(FileName)
         BinRes:=oADO.Read
         oADO.Close
         return BinRes
     }
     ;合并二进制数据
     static BinArr_Join(Arrays*) {
         oADO := comObject("ADODB.Stream")
         oADO.Type := 1 ; adTypeBinary
         oADO.Mode := 3 ; adModeReadWrite
         oADO.Open
         For i, arr in Arrays
             oADO.Write(arr)
         oADO.Position := 0
         BinRes:=oADO.Read
         oADO.Close
         return BinRes
     }
}
;----------------------------------------------------------------------------------------------------------搜狗ocr  class
;----------------------------------------------------------------------------------------------------------网络连接工具
;用于和c服务器通讯实现手机电脑互联
class socketapp
{
   ;开始连接c服务器
   static connect()
   {
      if not init.sysconfigPath or not fileExist(init.sysconfigPath)
         log("连接cmd服务器异常",Error("配置文件sysconfig.txt不存在,helpmeHome:" . this.helpmeHome))
      ;读取系统配置文件
      sysconfig:=ak.readFileToMap(init.sysconfigPath)
      cmdconnect:=ak.mapget(sysconfig,"cmdconnect")
      cmdname:=ak.mapget(sysconfig,"cmdname")
      server:=ak.mapget(sysconfig,"cmdserver")
      port:=ak.mapget(sysconfig,"cmdserverport")
      if cmdconnect=="on" or cmdconnect=="ON"
         setTimer(()=>this.connectTimer(server,port,cmdname),-1)
   }
   ;定时任务循环连接服务器
   static connectTimer(host,port,cmdname)
   {
        while(1){
            try{
                socketTipLevel:=4
                imageutil.changetrayIcon("icon1") ;浅色图标
                client1:=Socket() ,counter:=0
                ak.seticonTip("开始连接cmd服务器...",socketTipLevel)
                if not ak.ConnectedToInternet(){ ;互联网没有连接
                   ak.seticonTip("互联网已断开,重试中...",socketTipLevel)
                   sleep 3000
                   continue
                }
                client1.asyncConnect([host,port]) ;异步连接服务器
                if not client1.checkAsyncConnect(1000){
                    ak.seticonTip("cmd服务器链接失败,重试中...",socketTipLevel)
                    client1.disconnect()
                    sleep 3000
                    continue
                }
                ak.seticonTip("正在读取socket密码.",socketTipLevel)
                if not (spass:= Reg.getEnv("A_SOCKPASS")){ ;获取密码
                    ak.seticonTip("未读取到客户端密码,重试中...",socketTipLevel)
                    client1.disconnect()
                    sleep 2000
                    continue
                }
                ak.seticonTip("正在发送socket密码.",socketTipLevel)
                if not client1.sendText(ak.Base64Decode(Trim(spass))){ ;发送密码
                    ak.seticonTip("发送密码失败，重试中...",socketTipLevel)
                    client1.disconnect()
                    sleep 2000
                    continue
                }
                if  client1.recvText()!="ok"{
                    ak.seticonTip("客户端密码错误，重试中...",socketTipLevel)
                    client1.disconnect()
                    sleep 2000
                    continue
                }
                ak.seticonTip("客户端密码正确,发送连接名.",socketTipLevel)
                if not client1.sendText(cmdname){ ;发送连接名
                    ak.seticonTip("发送连接名失败，重试中...",socketTipLevel)
                    client1.disconnect()
                    sleep 2000
                    continue
                }
                while(1){ ;循环接收数据
                    sleep 1000
                    if not (size:=client1.msgSize()){
                        if counter>3{
                           ak.seticonTip("cmd失败,客户端未收到心跳...",socketTipLevel)
                           imageutil.changetrayIcon("icon1")
                           client1.disconnect()
                           break
                        }
                        counter+=1
                        continue
                    }
                    if((recvData:=client1.recvText())=="heartbeat"){ ;心跳
                        counter:=0
                        imageutil.changetrayIcon("icon2") ;深色图标
                        ak.seticonTip(cmdname . "连接服务器成功.",socketTipLevel)
                    }else{  ;数据
                        this.parseCommand(recvData)
                    }
                }
            }catch as e{
;                log("socket异常",e)
                try{
                    client1.disconnect()
                }catch as e2{
                    log("关闭socket异常",e2)
                }
            }
        }
   }
   ;解析cmd服务器发送的指令
   static parseCommand(str)
   {
        ;电量预警
        if(InStr(str,"%")==1){
            title:="ipone12mini电量提示"
            powerValue:=Trim(LTrim(str,"%"))
            if(powerValue<=30)
               content:=Format("电量过低 {1}%，请及时充电！",powerValue)
            else if(powerValue=="80")
               content:="已有足够电量80%"
            else if(powerValue=="100")
               content:="电量已充满100%"
            trayTip content,title
            return
        }
        ;下班提示
        if(InStr(str,"#workoff")){
            trayTip "下班了，打开手机钉钉打卡下班" ,"下班啦！"
            return
        }
        ;禁用鼠标键盘
        if(InStr(str,"#blockon")){
            trayTip "鼠标键盘已被禁用" ,"鼠标键盘关闭OFF"
            BlockInput "on"
            return
        }
        ;启用鼠标键盘
        if(InStr(str,"#blockoff")){
            trayTip "鼠标键盘已已启用" ,"鼠标键盘开启ON"
            BlockInput "off"
            return
        }
        ;快进>>
        if(InStr(str,"#VIDEOSPEEDUP")){
            send "{right}{right}"
            return
        }
        ;快退<<
        if(InStr(str,"#VIDEOSPEEDDOWN")){
            send "{left}{left}"
            return
        }
        ;增加音量（+10）
        if(InStr(str,"#VIDEOVOICEUP")){
            Send "{Volume_Up 2}"
            return
        }
        ;降低音量（-10）
        if(InStr(str,"#VIDEOVOICEDOWN")){
            Send "{Volume_Down 2}"
            return
        }
        ;暂停（空格）
        if(InStr(str,"#SPACE")){
            Send "{SPACE}"
            return
        }
        ;锁屏+黑屏
        if(InStr(str,"#LOCKSCREEN")){
            SendMessage 0x112, 0xF170, 2,, "Program Manager"
            return
        }
        ;强制关机
        if(InStr(str,"#SHUTDOWN")){
            ak.shellExcuter("shutdown /s /f /t  0")
            return
        }
        ;短信验证码
        if(InStr(str,"#VRIFCODE")){
            A_clipboard:=vrifcode:=this.decode(ak.getstrBAB(str,"#VRIFCODE","【"))
            ak.showToolTip("验证码:" . vrifcode,3500)
            trayTip "验证码：" . vrifcode,"已复制" . ak.getstrBAB(str,"【","】",0,0)
            SendText vrifcode
            Send "{Enter}"
            return
        }
        ;快递消息/车辆消息/欠费信息
        if(InStr(str,"#COMMSG")){
           trayTip  StrReplace(strReplace(str,sourceTitle:=(not (tmpA:=ak.getstrBAB(str,"【","】",0,0))?
                    ak.getstrBAB(str,"[","]",0,0):tmpA ),"" ),"#COMMSG","") ,sourceTitle
           return
        }
   }
   ;解码
   static decode(rawstr)
   {
        retstr:=""
        _obj:={O:0,P:1,N:2,Q:3,U:4,Y:5,A:6,W:7,F:8,B:9}
        Loop Parse rawstr
            retstr:=retstr . String(_obj.%A_LoopField%)
        return retstr
   }
}
;----------------------------------------------------------------------------------------------------------网络连接工具
;----------------------------------------------------------------------------------------------------------image GDI+工具类
class imageutil
{
    ;GDI句柄
     static GdipToken := 0

     ;当前托盘图标,防止重复创建同一图标
     static trayiconFlag:=0

     ;初始化GDI+模块
     static init()
     {
         DllCall("LoadLibrary", "str", "gdiplus")
         si := Buffer(A_PtrSize = 4 ? 16:24, 0) ; sizeof(GdiplusStartupInput) = 16, 24
         NumPut("uint", 0x1, si)
         DllCall("gdiplus\GdiplusStartup", "ptr*", &GdipToken:=0, "ptr", si, "ptr", 0)
         this.GdipToken:=GdipToken
     }
    ;保存图片,默认png格式 ,filepath:路径,minW/minH:缩放的最小宽度/高度小于就缩放scale倍数,sextension文件类型png
    static saveclip(filepath,minW:=0,minH:=0,scale:=1,extension:="png")
    {
        if not (pBitmap:=this.getBitFromClip())
            throw Error("获取pBitmap异常")
        this.saveBitmap(pBitmap,filepath,minW,minH,scale,extension)
    }
    ;保存bitmap图片
    static saveBitmap(pBitmap,filepath,minW:=0,minH:=0,scale:=1,extension:="png")
    {
        if not pBitmap
            throw Error("传入pBitmap异常")
        this.select_codec(pBitmap,  &pCodec, &ep, &ci, &v ,extension)
        DllCall("gdiplus\GdipGetImageWidth", "ptr", pBitmap, "uint*", &width:=0)  ;获取图片宽度
        DllCall("gdiplus\GdipGetImageHeight", "ptr", pBitmap, "uint*", &height:=0) ;获取图片高度
        scale:=(width<minW or  height<minH )?scale:1
        this.BitmapScale(&pBitmap,scale)  ;缩放
        Loop {
           if !DllCall("gdiplus\GdipSaveImageToFile", "ptr", pBitmap, "wstr", filepath, "ptr", pCodec, "ptr", IsSet(ep) ? ep : 0)
              break
           else
              if A_Index < 6
                 Sleep (2**(A_Index-1) * 30)
              else
                 throw Error("保存图片异常")
        }
    }
     ;获取粘贴板数据返回bitmap的指针 pBitmap ，非图片时报错
     static getBitFromClip() {
         Loop{
             if DllCall("OpenClipboard", "ptr", A_ScriptHwnd)
                break
             else
                if A_Index < 6
                   Sleep (2**(A_Index-1) * 30)
                else
                   throw Error("打开剪切板失败")
          }
          if !DllCall("IsClipboardFormatAvailable", "uint", 2){ ;CF_BITMAP
             DllCall("CloseClipboard")
             throw Error("获取CF_BIUTMAP失败")
          }
          if !(hbm := DllCall("GetClipboardData", "uint", 2, "ptr")){
             DllCall("CloseClipboard")
             throw Error("获取剪切板数据失败")
          }
          DllCall("gdiplus\GdipCreateBitmapFromHBITMAP", "ptr", hbm, "ptr", 0, "ptr*", &pBitmap:=0)
          DllCall("DeleteObject", "ptr", hbm)
          DllCall("CloseClipboard")
          return pBitmap
     }
     ;获取图片的编码信息
     static select_codec(pBitmap, &pCodec, &ep, &ci, &v ,extension:="png", quality:=100) {
          ; Fill a buffer with the available image codec info.
          DllCall("gdiplus\GdipGetImageEncodersSize", "uint*", &count:=0, "uint*", &size:=0)
          DllCall("gdiplus\GdipGetImageEncoders", "uint", count, "uint", size, "ptr", ci := Buffer(size))
          loop {
             if (A_Index > count) ;Could not find a matching encoder for the specified file format.
                throw Error("找不到匹配的图片编码")
             idx := (48+7*A_PtrSize)*(A_Index-1)
          } until InStr(StrGet(NumGet(ci, idx+32+3*A_PtrSize, "ptr"), "UTF-16"), extension) ; FilenameExtension
          pCodec := ci.ptr + idx ; ClassID
          return 1
     }
     ;缩放图片,scale 缩放倍数，可以是数组[m,n] 表示长度缩放m倍数，宽度缩放n倍数
     static BitmapScale(&pBitmap, scale) {
          if not (IsObject(scale) && ((scale[1] ~= "^\d+$") || (scale[2] ~= "^\d+$")) || (scale ~= "^\d+(\.\d+)?$"))
             throw Error("缩放倍数异常scale：" . scale)

          ; Get Bitmap width, height, and format.
          DllCall("gdiplus\GdipGetImageWidth", "ptr", pBitmap, "uint*", &width:=0)
          DllCall("gdiplus\GdipGetImageHeight", "ptr", pBitmap, "uint*", &height:=0)
          DllCall("gdiplus\GdipGetImagePixelFormat", "ptr", pBitmap, "int*", &format:=0)

          if IsObject(scale) {
             safe_w := (scale[1] ~= "^\d+$") ? scale[1] : Round(width / height * scale[2])
             safe_h := (scale[2] ~= "^\d+$") ? scale[2] : Round(height / width * scale[1])
          } else {
             safe_w := Ceil(width * scale)
             safe_h := Ceil(height * scale)
          }

          ; Avoid drawing if no changes detected.
          if (safe_w = width && safe_h = height)
             return pBitmap

          ; Create a new bitmap and get the graphics context.
          DllCall("gdiplus\GdipCreateBitmapFromScan0"
                   , "int", safe_w, "int", safe_h, "int", 0, "int", format, "ptr", 0, "ptr*", &pBitmapScale:=0)
          DllCall("gdiplus\GdipGetImageGraphicsContext", "ptr", pBitmapScale, "ptr*", &pGraphics:=0)

          ; Set settings in graphics context.
          DllCall("gdiplus\GdipSetPixelOffsetMode",    "ptr", pGraphics, "int", 2) ; Half pixel offset.
          DllCall("gdiplus\GdipSetCompositingMode",    "ptr", pGraphics, "int", 1) ; Overwrite/SourceCopy.
          DllCall("gdiplus\GdipSetInterpolationMode",  "ptr", pGraphics, "int", 7) ; HighQualityBicubic

          ; Draw Image.
          DllCall("gdiplus\GdipCreateImageAttributes", "ptr*", &ImageAttr:=0)
          DllCall("gdiplus\GdipSetImageAttributesWrapMode", "ptr", ImageAttr, "int", 3) ; WrapModeTileFlipXY
          DllCall("gdiplus\GdipDrawImageRectRectI"
                   ,    "ptr", pGraphics
                   ,    "ptr", pBitmap
                   ,    "int", 0, "int", 0, "int", safe_w, "int", safe_h ; destination rectangle
                   ,    "int", 0, "int", 0, "int",  width, "int", height ; source rectangle
                   ,    "int", 2
                   ,    "ptr", ImageAttr
                   ,    "ptr", 0
                   ,    "ptr", 0)
          DllCall("gdiplus\GdipDisposeImageAttributes", "ptr", ImageAttr)

          ; Clean up the graphics context.
          DllCall("gdiplus\GdipDeleteGraphics", "ptr", pGraphics)
          DllCall("gdiplus\GdipDisposeImage", "ptr", pBitmap)

          return pBitmap := pBitmapScale
     }
     ;关闭GDI+
     static close()
     {
        If (this.GdipToken) {
           DllCall("gdiplus\GdiplusShutdown", "UInt", this.GdipToken)
        }
        DllCall("FreeLibrary", "ptr", DllCall("GetModuleHandle", "str", "gdiplus", "ptr"))
     }

      ;在屏幕上绘制一个矩形，要生效删除清空资源，颜色粗细 ,颜色加上透明图0xFFFF0000前面两位是透明度,FF完全不透明，为红色
      drawRect(X,Y,Width,Height,color,bold)
      {
          ; 创建屏幕 DC
          hDC := DllCall("GetDC", "Ptr", 0)
          pGraphics:=Buffer(8, 0)
          ; 创建 GDI+ 绘图对象
          DllCall("gdiplus\GdipCreateFromHDC", "Ptr", hDC, "PtrP", &pGraphics:=0)
          ; 创建画笔对象
          DllCall("gdiplus\GdipCreatePen1", "UInt", color, "Float", bold, "Int", 2, "PtrP", &pPen:=0) ; 红色画笔

          ; 绘制矩形
          DllCall("gdiplus\GdipDrawRectangle", "Ptr", pGraphics, "Ptr", pPen, "Float", X, "Float", Y, "Float", Width, "Float", Height)
          ; 刷新屏幕
          DllCall("UpdateLayeredWindow", "Ptr", 0, "Ptr", hDC, "Ptr", 0, "UInt64P", 0, "Ptr", 0, "Ptr", 0, "UInt", 0, "Ptr", 0, "UInt", 2)

          DllCall("gdiplus\GdipDeletePen", "Ptr", pPen)
          DllCall("gdiplus\GdipDeleteGraphics", "Ptr", pGraphics)
          DllCall("ReleaseDC", "Ptr", 0, "Ptr", hDC)
      }
      ;传入 ico 的 base64，转成 HICON（托盘/菜单用）；示例: TraySetIcon('HICON: ' . Base64PNG_to_HICON(getResourceBase64("icon1")))
      ;参考https://www.autohotkey.com/boards/viewtopic.php?f=82&t=118167&p=524529&hilit=trayseticon#p524529
      static Base64PNG_to_HICON(Base64PNG, height := 16) {
          size := StrLen( RTrim(Base64PNG, '=') )*3//4
          if DllCall('Crypt32\CryptStringToBinary', 'Str', Base64PNG, 'UInt', StrLen(Base64PNG), 'UInt', 1,
                                                    'Ptr', buf := Buffer(size), 'UIntP', &size, 'Ptr', 0, 'Ptr', 0)
              return DllCall('CreateIconFromResourceEx', 'Ptr', buf, 'UInt', size, 'UInt', true,
                                                         'UInt', 0x30000, 'Int', height, 'Int', height, 'UInt', 0)
          return 0
      }
      ;改变图标,icon ： 字符串 "icon1" , "icon2"
      static changetrayIcon(icon)
      {
         if this.trayiconFlag==icon
            return
         else{
            traySetIcon("HICON: " . this.Base64PNG_to_HICON(getResourceBase64(icon)))
            this.trayiconFlag:=icon
         }
      }
}
;----------------------------------------------------------------------------------------------------------image GDI+工具类
;----------------------------------------------------------------------------------------------------------JSON工具类
;可以用于把comobject对象转换为ahk对象
class JSON2
{
    static uuidA:="0763C49802734108979739D89C0CC7A4" . A_NowUTC
    static uuidB:="C8C0655017FB428FB18EECF88E6E85CF" . A_NowUTC
    static uuidC:="08E3043B62324D0C8BDDB6A2A1DB4E6A" . A_NowUTC
    ;解析json
    static parse(str)
    {
        str:=inStr(str,'\\')?strReplace(str,'\\',this.uuidC):str ;替换 \\
        str:=inStr(str,'\"')?strReplace(str,'\"',this.uuidA):str ;替换 \"
        str:=inStr(str,"'")?strReplace(str,"'",this.uuidB):str   ;替换 '
        return this.recurve(str)
    }
    ;Func 把对象转换为字符串
    static stringify(obj)
    {
        return  this.GetJS().JSON.stringify(obj)
    }
    ;递归解析json
    static recurve(str,recFlag:=0)
    {
        static eval := ObjBindMethod(this.GetJS(), 'eval')
        if not recFlag{
            obj:= eval(Format('(function(){obj=JSON.parse({1}{2}{3});tmp=obj.length?"":obj["keys"]=Object.keys(obj);return obj})()'
            ,"'",str,"'"))
            return this.recurve(obj,1)
        }
        if(type(str)=="ComObject"){
           if(str.hasOwnProperty("length")){ ;数组
               tmpArr:=[]
               Loop str.length {
                 if type(value:=str.%A_index-1%)=="ComObject"
                    tmpArr.push(this.recurve(this.recurve(this.stringify(value),0),1))
                 else
                    tmpArr.push(this.recurve(value,1))
               }
               return tmpArr
           }else{  ;对象 注意js的下标是0开始
               tmpObject:={}
               Loop str.keys.length{
                  key:=str.keys.%A_index-1%
                  if type(value:=str.%key%)=="ComObject"{
                     tmpObject.%key%:=this.recurve(this.recurve(this.stringify(value),0),1)
                  }else
                    tmpObject.%key%:=this.recurve(value,1) ;
               }
               return tmpObject
           }
        }else{ ;普通类型,可能是已经组装好的map或者是组装好的array
;            msgBox type(str)
           if type(str)=="Object" or type(str)=="Array"
                return str
           str:=inStr(str,this.uuidA)?strReplace(str,this.uuidA,'"'):str
           str:=inStr(str,this.uuidB)?strReplace(str,this.uuidB,"'"):str
           str:=inStr(str,this.uuidC)?strReplace(str,this.uuidC,"\"):str
           return str
        }
    }
    ;获取JS对象
    static GetJS() {
        static document := '', JS
        if !document {
            document := ComObject('HTMLFILE')
            document.write('<meta http-equiv="X-UA-Compatible" content="IE=9">')
            JS := document.parentWindow
            (document.documentMode < 9 && JS.execScript())
        }
        return JS
    }
}
;----------------------------------------------------------------------------------------------------------JSON工具类
;----------------------------------------------------------------------------------------------------------Reg工具类
;注册表操作工具
class reg
{
    ;用户环境变量位置
    static HCU:="HKEY_CURRENT_USER\Environment"
    ;系统环境变量位置
    static HLM:="HKEY_LOCAL_MACHINE\System\CurrentControlSet\Control\Session Manager\Environment"

    ;获取当前某个环境变量的值 ，默认是当前用户
    static getEnv(key,user:=1)
    {
        return  ak.mapget(this.getEnvMap(user),key,1)
    }
    ;获取当前所有环境变量 ，默认是当前用户
    static getEnvMap(user:=1){
        regpath:=user?this.HCU:this.HLM
        retMap:=Map()
        Loop Reg, regpath ,"KV"{
            retMap.set(A_LoopRegName,RegRead())
        }
        return retMap
    }
    ;删除环境变量，默认当前用户
     static delEnv(key,user:=1){
        regpath:=user?this.HCU:this.HLM
        RegDelete regpath ,key
    }
    ;设置环境变量，立即生效，默认是当前用户
    static setEnv(key,value,type:="REG_SZ",user:=1)
    {
        regpath:=user?this.HCU:this.HLM
        RegWrite value, type, regpath, key
    }
    ;添加一个键值对到path ,默认是当前用户
    static pathPush(key,user:=1){
        arr:=this.pathArr(user)
        if(arr and ak.arrHas(arr,key))
            return
        else
           arr.push(key)
        pathStr:=ak.joinArr(arr,";","","")
        this.setEnv("Path",pathStr,"REG_EXPAND_SZ",user)
    }
    ;在path中删除一个键值，默认是当前用户
    static pathPop(key,user:=1){
        paths:=ak.arrDelete(this.pathArr(user),key)
        pathStr:=ak.joinArr(paths,";","","")
        this.setEnv("Path",pathStr,"REG_EXPAND_SZ",user)
    }
    ;返回path集合array ，默认是当前用户
    static pathArr(user:=1){
       retarr:=[]
       pathstr:=Rtrim(this.path(user),";")
       loop parse ,pathstr,";"
           retarr.push(A_loopField)
       return retarr
    }
    ;返回一个path字符串,默认是当前用户
    static path(user:=1){
        return this.getEnv("Path",user)
    }

}
;----------------------------------------------------------------------------------------------------------Reg工具类
;----------------------------------------------------------------------------------------------------------socket类
class Socket {
    static WM_SOCKET := 0x9987, MSG_PEEK := 2, FD_READ := 1, FD_ACCEPT := 8, FD_CLOSE := 32
    Bound := false, Blocking := true, BlockSleep := 50
    __New(Socket := -1, ProtocolId := 6, SocketType := 1) {
        static Init := 0
        if (!Init) {
            ; DllCall("LoadLibrary", "Str", "ws2_32", "Ptr")
            WSAData := Buffer(394 + A_PtrSize)
            if (err := DllCall("ws2_32\WSAStartup", "UShort", 0x0202, "Ptr", WSAData))
                return
                ;throw Error("Error starting Winsock", , err)
            if (NumGet(WSAData, 2, "UShort") != 0x0202)
                return
                ;throw Error("Winsock version 2.2 not available")
            Init := true
        }
        this.Ptr := Socket, this.ProtocolId := ProtocolId, this.SocketType := SocketType
    }
    __Delete() {
        if (this.Ptr != -1)
            this.Disconnect()
    }
    ;阻塞式连接，传入是一个数组[host,port]
    Connect(Address) {
        if (this.Ptr != -1)
            return
            ;throw Error("Socket already connected")
        Next := pAddrInfo := this.GetAddrInfo(Address)
        while Next {
            ai_addrlen := NumGet(Next + 0, 16, "UPtr")
            ai_addr := NumGet(Next + 0, 16 + (2 * A_PtrSize), "Ptr")
            if ((this.Ptr := DllCall("ws2_32\socket", "Int", NumGet(Next + 0, 4, "Int")
                , "Int", this.SocketType, "Int", this.ProtocolId, "Ptr")) != -1) {
                if (DllCall("ws2_32\WSAConnect", "Ptr", this.Ptr, "Ptr", ai_addr
                    , "UInt", ai_addrlen, "Ptr", 0, "Ptr", 0, "Ptr", 0, "Ptr", 0, "Int") = 0) {
                    DllCall("ws2_32\FreeAddrInfoW", "Ptr", pAddrInfo)   ; TODO: Error Handling
                    return this.EventProcRegister(Socket.FD_READ | Socket.FD_CLOSE)
                }
                this.Disconnect()
            }
            Next := NumGet(Next + 0, 16 + (3 * A_PtrSize), "Ptr")
        }
        return
        ;throw Error("Error connecting")
    }
    ;非阻塞式连接传入是一个数组[host,port],异步连接设置一个超时
    asyncConnect(Address) {
        if (this.Ptr != -1)
            return
            ;throw Error("Socket already connected")
        Next := pAddrInfo := this.GetAddrInfo(Address)
        this.hEvent := DllCall("kernel32\CreateEvent", "UInt", 0, "UInt", 0, "UInt", 0, "UInt", 0) ;①创建事件句柄
        while Next {
            ai_addrlen := NumGet(Next + 0, 16, "UPtr")
            ai_addr := NumGet(Next + 0, 16 + (2 * A_PtrSize), "Ptr")
            if ((this.Ptr := DllCall("ws2_32\socket", "Int", NumGet(Next + 0, 4, "Int")
                , "Int", this.SocketType, "Int", this.ProtocolId, "Ptr")) != -1) {
                DllCall("ws2_32\ioctlsocket", "UInt", this.Ptr, "UInt", 0x8004667E, "UIntP", 1)       ;②设置非阻塞
                DllCall("ws2_32\WSAEventSelect", "UInt", this.Ptr, "UInt", this.hEvent, "UInt", 0x10) ;③使用 WSAEventSelect 进行异步事件监听
                result:=DllCall("ws2_32\WSAConnect", "Ptr", this.Ptr, "Ptr", ai_addr
                                    , "UInt", ai_addrlen, "Ptr", 0, "Ptr", 0, "Ptr", 0, "Ptr", 0, "Int")
                if  result= 0 {
                    DllCall("ws2_32\FreeAddrInfoW", "Ptr", pAddrInfo)   ; TODO: Error Handling
                    return this.EventProcRegister(Socket.FD_READ | Socket.FD_CLOSE)
                }else if(result==-1 and this.GetLastError()==10035){ ;④等待连接中
                    return 2 ;等待连接中
                }
                this.Disconnect()
            }
            Next := NumGet(Next + 0, 16 + (3 * A_PtrSize), "Ptr")
        }
        return 0
    }
    ;检测异步连接是已经连接上服务器，这种方法不是一直成立，如果没有连接4s左右也会返回1所以超时最好设置2s
    checkAsyncConnect(timeout)
    {
      Sleep timeout
      ; 检查套接字状态成功返回1，失败返回0
      networkEvents:=Buffer(4, 0)
      eventResult := DllCall("ws2_32\WSAEnumNetworkEvents", "UInt", this.Ptr, "UInt", this.hEvent, "Ptr", networkEvents)
      return eventResult = 0 &&  NumGet(networkEvents, 0, "Int")&0x10 ? 1:0
    }
    ;作为服务器使用
    Bind(Address) {
        if (this.Ptr != -1)
        return
            ;throw Error("Socket already connected")
        Next := pAddrInfo := this.GetAddrInfo(Address)
        while Next {
            ai_addrlen := NumGet(Next + 0, 16, "UPtr")
            ai_addr := NumGet(Next + 0, 16 + (2 * A_PtrSize), "Ptr")
            if ((this.Ptr := DllCall("ws2_32\socket", "Int", NumGet(Next + 0, 4, "Int")
                , "Int", this.SocketType, "Int", this.ProtocolId, "Ptr")) != -1) {
                if (DllCall("ws2_32\bind", "Ptr", this.Ptr, "Ptr", ai_addr
                    , "UInt", ai_addrlen, "Int") == 0) {
                    DllCall("ws2_32\FreeAddrInfoW", "Ptr", pAddrInfo)   ; TODO: ERROR HANDLING
                    return this.EventProcRegister(Socket.FD_READ | Socket.FD_ACCEPT | Socket.FD_CLOSE)
                }
                this.Disconnect()
            }
            Next := NumGet(Next + 0, 16 + (3 * A_PtrSize), "Ptr")
        }
        return
        ;throw Error("Error binding")
    }
    ;作为服务器使用
    Listen(backlog := 32) {
        return DllCall("ws2_32\listen", "Ptr", this.Ptr, "Int", backlog) == 0
    }
    ;作为服务器使用
    Accept() {
        if ((s := DllCall("ws2_32\accept", "Ptr", this.Ptr, "Ptr", 0, "Ptr", 0, "Ptr")) == -1)
            return
            ;throw Error("Error calling accept", , this.GetLastError())
        Sock := Socket(s, this.ProtocolId, this.SocketType)
        Sock.EventProcRegister(Socket.FD_READ | Socket.FD_CLOSE)
        return Sock
    }

    Disconnect() {
        ; Return 0 if not connected
        if (this.Ptr == -1)
            return 0

        ; Unregister the socket event handler and close the socket
        this.EventProcUnregister()
        if (DllCall("ws2_32\closesocket", "Ptr", this.Ptr, "Int") == -1)
            return
            ;throw Error("Error closing socket", , this.GetLastError())
        this.Ptr := -1
        return 1
    }

    MsgSize() {
        static FIONREAD := 0x4004667F
        if (DllCall("ws2_32\ioctlsocket", "Ptr", this.Ptr, "UInt", FIONREAD, "UInt*", &argp := 0) == -1)
            return
            ;throw Error("Error calling ioctlsocket", , this.GetLastError())
        return argp
    }

    Send(pBuffer, BufSize, Flags := 0) {
        if ((r := DllCall("ws2_32\send", "Ptr", this.Ptr, "Ptr", pBuffer, "Int", BufSize, "Int", Flags)) == -1)
            return
            ;throw Error("Error calling send", , this.GetLastError())
        return r
    }

    SendText(Text, Flags := 0, Encoding := "UTF-8") {
        buf := Buffer(Length := StrPut(Text, Encoding) - ((Encoding = "UTF-16" || Encoding = "cp1200") ? 2 : 1))
        Length := StrPut(Text, buf, Encoding)
        return this.Send(buf, Length, Flags)
    }

    Recv(&Buf, BufSize := 0, Flags := 0, Timeout := 0) {
        t := 0
        while (!(Length := this.MsgSize()) && this.Blocking && (!Timeout || t < Timeout))
            Sleep(this.BlockSleep), t += this.BlockSleep
        if !Length
            return 0
        if !BufSize
            BufSize := Length
        else
            BufSize := Min(BufSize, Length)
        Buf := Buffer(BufSize)
        if ((r := DllCall("ws2_32\recv", "Ptr", this.Ptr, "Ptr", Buf, "Int", BufSize, "Int", Flags)) == -1)
            return
            ;throw Error("Error calling recv", , this.GetLastError())
        return r
    }

    RecvText(BufSize := 0, Flags := 0, Encoding := "UTF-8") {
        if (Length := this.Recv(&Buf := 0, BufSize, flags))
            return StrGet(Buf, Length, Encoding)
        return ""
    }

    RecvLine(BufSize := 0, Flags := 0, Encoding := "UTF-8", KeepEnd := false) {
        while !(i := InStr(this.RecvText(BufSize, Flags | Socket.MSG_PEEK, Encoding), "`n")) {
            if (!this.Blocking)
                return ""
            Sleep(this.BlockSleep)
        }
        if KeepEnd
            return this.RecvText(i, Flags, Encoding)
        else
            return RTrim(this.RecvText(i, Flags, Encoding), "`r`n")
    }

    GetAddrInfo(Address) {
        Host := Address[1], Port := Address[2]
        Hints := Buffer(16 + (4 * A_PtrSize), 0)
        NumPut("Int", this.SocketType, "Int", this.ProtocolId, Hints, 8)
        if (err := DllCall("ws2_32\GetAddrInfoW", "Str", Host, "Str", Port, "Ptr", Hints, "Ptr*", &Result := 0))
            return
            ;throw Error("Error calling GetAddrInfo", , err)
        return Result
    }

    OnMessage(wParam, lParam, Msg, hWnd) {
        if (Msg != Socket.WM_SOCKET || wParam != this.Ptr)
            return
        if (lParam & Socket.FD_READ)
            this.HasOwnProp('onRecv') ? this.onRecv() : 0
        else if (lParam & Socket.FD_ACCEPT)
            this.HasOwnProp('onAccept') ? this.onAccept() : 0
        else if (lParam & Socket.FD_CLOSE)
            this.EventProcUnregister(), this.HasOwnProp('OnDisconnect') ? this.OnDisconnect() : 0
    }

    EventProcRegister(lEvent) {
        this.AsyncSelect(lEvent)
        if !this.Bound {
            this.Bound := ObjBindMethod(this, "OnMessage")
            OnMessage(Socket.WM_SOCKET, this.Bound)
        }
    }

    EventProcUnregister() {
        this.AsyncSelect(0)
        if this.Bound {
            OnMessage(Socket.WM_SOCKET, this.Bound, 0)
            this.Bound := false
        }
    }

    AsyncSelect(lEvent) {
        if (DllCall("ws2_32\WSAAsyncSelect"
            , "Ptr", this.Ptr   ; s
            , "Ptr", A_ScriptHwnd   ; hWnd
            , "UInt", Socket.WM_SOCKET  ; wMsg
            , "UInt", lEvent) == -1)    ; lEvent
            return
            ;throw Error("Error calling WSAAsyncSelect", , this.GetLastError())
    }

    GetLastError() {
        return DllCall("ws2_32\WSAGetLastError")
    }
}
class SocketUDP extends Socket {
    __New(socket := -1) {
        ; ProtocolId := 17  ; IPPROTO_UDP
        ; SocketType := 2   ; SOCK_DGRAM
        super.__New(socket, 17, 2)
    }

    SetBroadcast(Enable) {
        static SOL_SOCKET := 0xFFFF, SO_BROADCAST := 0x20
        if (DllCall("ws2_32\setsockopt"
            , "Ptr", this.Ptr   ; SOCKET s
            , "Int", SOL_SOCKET ; int    level
            , "Int", SO_BROADCAST   ; int    optname
            , "UInt*", &Enable := !!Enable  ; *char  optval
            , "Int", 4) == -1)  ; int    optlen
            return
            ;throw Error("Error calling setsockopt", , this.GetLastError())
    }
}
;----------------------------------------------------------------------------------------------------------socket类
;----------------------------------------------------------------------------------------------------------最近打开的文件记录recent 类
;[@recent-5889F150A6B1430580B07D9028C9C0E4]
class recent{

    ;存放历史操作文件夹
    static recentdir:="C:\Users\" . A_username . "\AppData\Roaming\Microsoft\Windows\Recent"
    ;右键注册表位置
    static recentItem:="HKEY_CLASSES_ROOT\Directory\Background\shell\Recent"
    ;右键注册表图标ico位置
    static icopath:=A_temp . "\AhkRC.ico"
    ;排序方式
    static groupArr:=["dir","txt","mkv","mp4","|","png","jpg","ico","gif","webp","|" ,"doc","docx","pdf","xls","|","rar","zip"]
    ;每项最大item
    static listMaxSize:=20
    ;打开文件夹,而不是文件的后缀
    static opendirArr:=["ahk","rar","zip"]

    ;初始化
    static init(){
        this.writeRegRC()
        head:="#SingleInstance Force`n#NoTrayIcon`nrecent.show()`n"
        if fileExist(f:="~Recent.ahk")
            fileDelete f
        fileAppend   head
                   . ak.getPartScript("getResourceBase64")
                   . ak.getPartScript("recent")
                   . ak.getPartScript("ak")
                   ,f
    }
    ;显示
    static show(){
           try{
                _map:=this.classfiySuffix(recent.readRecentDir())
                _gmap:=this.createGroup(_map)
                this.showMenuGui(_gmap)
            }
    }
    ;写入注册表,来添加鼠标右键
    static writeRegRC(){
        icoPath:= A_temp . "\AhkRC.ico"
        if not A_IsCompiled{
            ak.createFileByBase64(getResourceBase64("icon2RC"),icoPath) ;先创建目标文件
            RegWrite icoPath, "REG_SZ", recent.recentItem, "Icon"
            RegWrite "Open Recent... ", "REG_SZ", recent.recentItem, "MUIVerb"
            RegWrite  Format('"{1}" "{2}"', A_AhkPath
                      ,A_scriptDir . "\~Recent.ahk"), "REG_SZ", recent.recentItem . "\command"
        }
    }
    ;获取recent下的文件并排序后的数组
    static readRecentDir()
    {
        Loop Files, this.recentdir . "\*.lnk" ,"F"{
             FileGetShortcut A_LoopFilePath , &OutTarget
             if OutTarget
                retstr.=A_LoopFileTimeModified . OutTarget  ","
        }
        return (retstr??"")?ak.orderListOrString(Rtrim(retstr,",")):""
    }
    ;对数组分类，返回一个map{ txt:{files:[xx1,xx2..],times:[1小时前...],icons:[xx.exe,shell.dll] ,status:[1,0...]}} 1存在,0删除
    static classfiySuffix(arr)
    {
        _map:=Map()
        for item in this.readRecentDir(){
             filePath:=subStr(item,15)
             suffix :=((ft:=FileExist(filePath)) and (inStr(ft,"D"))?"dir":ak.getSuffix(filePath,"."))
             icon:=(suffix="txt")?ak.getAssocExe(".txt"):""
             if not "txt" = suffix and not "dir" = suffix
                suffix :=ak.strEndWith((icon:=ak.getAssocExe("." . suffix)),"Notepad.exe") or not icon ?"other":suffix
             _innerMap:= (m1:=ak.mapget(_map,suffix))?m1:Map()
             fileArr:=(a1:=ak.mapget(_innerMap,"files"))?a1:[] , timeArr:=(a2:=ak.mapget(_innerMap,"times"))?a2:[]
             iconArr:=(a3:=ak.mapget(_innerMap,"icons"))?a3:[] , statArr:=(a4:=ak.mapget(_innerMap,"status"))?a4:[]
             if not ak.arrHas(fileArr,fullfilePath:=(filePath)) and fileArr.length<this.listMaxSize and
                 (dt:=subStr(item,1,14))~="\d{14}"{
                 fileArr.push(fullfilePath)
                 timeArr.push(ak.timeDiffRough(A_now,dt) . "前")
                 iconArr.push(not ft?"Shell32.dll_132":(suffix=="dir"?"Shell32.dll_4":(suffix=="other"?"Shell32.dll_0":icon)))
                 statArr.push(ft?1:0)
             }
             _innerMap["files"]:=fileArr ,_innerMap["times"]:=timeArr
             _innerMap["icons"]:=iconArr ,_innerMap["status"]:=statArr
             _map[suffix]:=_innerMap
        }
        return _map
    }
    ;对分类的数据进行分组排序，返回一个map:{a:[.txt,.java,...], b:[{..}] } ,分组之间用""空字符串来表示
    static createGroup(_map){
        _doc:=["doc","docx","xls"]
        _a:=[] ,_b:=[], _retmap:=Map("a",_a,"b",_b)
        for gitem in this.groupArr{
            if (v:=ak.mapget(_map,gitem)){
                _a.push(gitem)
                _b.push(v)
            }
        }
        for k1, v1 in _map{
            if not ak.arrHas(this.groupArr,k1) and not "other"==k1{
               _a.push(k1)
               _b.push(v1)
            }
        }
        _a.push("other"),_b.push(ak.mapget(_map,"other")|| "没有数据")
        return _retmap
    }
    ;创建menu的gui在桌面上
    static showMenuGui(gmap){
        level1 := Menu()
        for  k  in gmap.get("a"){
            level2 := Menu() ,v:=gmap.get("b")[A_index]
            switch{
                case k=="dir": assocExe2:="Shell32.dll" ,n2:="4"
                case k=="other" :assocExe2:="Shell32.dll" ,n2:="0"
                case "Default":assocExe2:=ak.getAssocExe("." . k) ,n2:=1
            }
            for filep in v["files"]{
                level2.add( (lvitem2:="【" . v["times"][A_index] . "】" . filep),MenuHandler)
                switch{
                    case inStr(iconitem:=v["icons"][A_index],"Shell32.dll")==1: assocExe:="Shell32.dll" ,n:=subStr(iconitem,13)
                    case "Default":assocExe:=iconitem ,n:=1
                }
                try level2.SetIcon(lvitem2,assocExe,n)
            }
            level1.Add(k, level2)
            try level1.SetIcon(k,assocExe2,n2)
        }
        level1.show()
        ;点击事件
        MenuHandler(Item, *) {
            try{
                fileName:=subStr(Item,inStr(Item,"】")+1)
                if ak.arrHas(this.opendirArr,suffix:=ak.getSuffix(fileName,".")){
                    if fileExist(subStr(fileName,1,strLen(fileName)-strLen(ak.getSuffix(fileName))))
                        Run "explorer.exe /select ,"  fileName
                }else
                    Run fileName
            }
        }
    }
}
;[@recent-5889F150A6B1430580B07D9028C9C0E4]
;----------------------------------------------------------------------------------------------------------最近打开的文件记录recent 类

;----------------------------------------------------------------------------------------------------------链接管理类 linkManager
;[@linkManager-7A3C9D21E84F16B05C2A78FD0E531B94]
class linkManager {
    ; 文件夹背景右键：HKCU\Software\Classes\Directory\Background\shell\LinkManager
    static BgRegPath    := "Software\Classes\Directory\Background\shell\LinkManager"
    ; helper 和 ico 统一放 A_Temp，避免脚本目录权限问题
    static HelperFile   := A_Temp "\~LinkManager.ahk"
    static IcoFile      := A_Temp "\AhkHeartLink.ico"
    ; A_Args[1]=soft/hard  A_Args[2]=%V（当前文件夹路径，由注册表命令传入）
    static LinkType     := ""
    static DestDir      := ""

    ;初始化：注册右键菜单 + 生成辅助脚本
    static init() {
        this.writeReg()
        ; helper 头：从注册表命令拿到 LinkType 和 DestDir（%V），不依赖活动窗口
        head := "#Requires AutoHotkey v2.0`n#SingleInstance Force`n#NoTrayIcon`n"
             . "linkManager.LinkType := A_Args.Length >= 1 ? A_Args[1] : `"soft`"`n"
             . "linkManager.DestDir  := A_Args.Length >= 2 ? A_Args[2] : `"`"`n"
             . "linkManager.batchCreate()`n"
        if FileExist(this.HelperFile)
            FileDelete(this.HelperFile)
        FileAppend(head . ak.getPartScript("getResourceBase64") . ak.getPartScript("linkManager") . ak.getPartScript("ak"), this.HelperFile)
    }

    ;写注册表：在文件夹空白处右键添加"创建链接"级联子菜单
    ;关键：父键须写 MUIVerb + SubCommands=""，Explorer 才会展开 shell\ 子键为飞出菜单
    ;命令中加 "%V" 让 Explorer 把当前文件夹路径传给 helper
    static writeReg() {
        icoPath := this.IcoFile
        helperFile := this.HelperFile
        if not A_IsCompiled {
            ak.createFileByBase64(getResourceBase64("icon1"), icoPath)
            base := "HKEY_CURRENT_USER\" this.BgRegPath
            ; 父菜单：MUIVerb 为显示名，SubCommands="" 告知 Explorer 展开 shell\ 子键
            RegWrite("",             "REG_SZ", base)
            RegWrite("🔗 创建链接", "REG_SZ", base, "MUIVerb")
            RegWrite(icoPath,        "REG_SZ", base, "Icon")
            RegWrite("",             "REG_SZ", base, "SubCommands")
            ; 子菜单：软链接（%V = 当前文件夹路径）
            soft := base . "\shell\01_soft"
            RegWrite("",                   "REG_SZ", soft)
            RegWrite("📎 批量创建软链接", "REG_SZ", soft, "MUIVerb")
            RegWrite(Format('"{1}" "{2}" soft "%V"', A_AhkPath, helperFile),
                     "REG_SZ", soft . "\command")
            ; 子菜单：硬链接
            hard := base . "\shell\02_hard"
            RegWrite("",                   "REG_SZ", hard)
            RegWrite("🔗 批量创建硬链接", "REG_SZ", hard, "MUIVerb")
            RegWrite(Format('"{1}" "{2}" hard "%V"', A_AhkPath, helperFile),
                     "REG_SZ", hard . "\command")
        }
    }

    ;批量创建链接（由辅助脚本调用）
    ;destDir 直接来自注册表命令传入的 %V，无需读活动窗口
    static batchCreate() {
        destDir := RTrim(linkManager.DestDir, "\")
        if !destDir {
            MsgBox("无法获取当前文件夹路径（A_Args[2] 为空）。", "链接管理", 0x10)
            ExitApp()
        }
        selected := FileSelect("M", destDir, "选择要链接的源文件（可多选）", "所有文件 (*.*)")
        if !IsObject(selected) || selected.Length = 0
            ExitApp()

        isHard := (linkManager.LinkType = "hard")
        ok := 0, fail := 0, failReasons := ""
        for srcPath in selected {
            SplitPath(srcPath, &fname)
            destPath := destDir "\" fname
            if FileExist(destPath) {
                fail++
                failReasons .= "已存在: " fname "`n"
                continue
            }
            if isHard {
                if SubStr(srcPath, 1, 1) != SubStr(destDir, 1, 1) {
                    fail++
                    failReasons .= "跨盘(硬链接限同盘): " fname "`n"
                    continue
                }
                cmd := 'mklink /H "' destPath '" "' srcPath '"'
            } else {
                cmd := 'mklink "' destPath '" "' srcPath '"'
            }
            RunWait('cmd.exe /c ' cmd,, "Hide")
            if FileExist(destPath)
                ok++
            else {
                fail++
                failReasons .= "mklink失败: " fname "`n"
            }
        }
        typeStr := isHard ? "硬链接" : "软链接"
        msg := "创建" typeStr "完成：成功 " ok " 个"
        if fail > 0
            msg .= "，失败/跳过 " fail " 个`n`n" failReasons
        MsgBox(msg, "链接管理", 0x40)
        ExitApp()
    }
}
;[@linkManager-7A3C9D21E84F16B05C2A78FD0E531B94]
;----------------------------------------------------------------------------------------------------------链接管理类 linkManager

;++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++ak工具类class
;[@ak-1FFF08E96143432088593A06D97CECF7]
class ak{
   ;cpu的id
   static cpuid:=""
   ;剪切板文件类型
   static clipdataType:=1
   ;Func打印数组Array或者map是,传入Array对象或者Map对象 ,inLine: true 单行，false 多行 默认单行
   static print(obj,inline:=true,quote:="",fileFlag:="")
   {
      if type(obj)=="Array"
          txt:= this.joinArr(obj,inline?",":",`n","[","]",quote)
      if type(obj)=="Map"
          txt:= this.joinMap(obj,inline?",":",`n","{","}",quote)
      if type(obj)=="Object"
          txt:= this.joinObj(obj,inline?",":",`n",quote)
      T1:= fileFlag?fileAppend(txt??obj,fileFlag):msgbox(txt??obj)
   }
   ;Func 遍历并连接对象 注意 map和Arry中只能是基本数据，否则报错
   static joinObj(obj,separator:=":",quote:="")
   {
       if type(obj)=="Array"{ ;数组类型
           return this.joinArr(obj,",","[","]",quote)
       }else if type(obj)=="Map"{ ;map类型
           return this.joinMap(obj,",","{","}",quote)
       }else if type(obj)=="Object"{ ;对象类型
          begin:="{"
          for k,v in  obj.OwnProps(){
               begin.=( quote . k  quote . ":" .  this.joinObj(v,":",quote) . ",") ;递归调用
          }
          return Rtrim(begin,",") . "}"
       }else
            return quote . obj . quote ;基本类型
   }
  ;Func连接数组Array ,arr:数组 ,separator:分隔符,L: 左边添加符号 R:右边添加符号
   static joinArr(arr  ,separator:=","  ,L:="["  ,R:="]" ,quote:="")
   {
      for i in arr{
         L.=(  this.joinObj(i,":",quote) . separator)
      }
      return Rtrim(L,separator)  . R
   }
   ;Func连接数组Array ,arr:数组 ,separator:分隔符,L: 左边添加符号 R:右边添加符号
   static joinMap(map,separator:=",",L:="{",R:="}" ,quote:="")
   {
       for k,v  in map{
         L:=L  . quote . k . quote . ":" . this.joinObj(v,":",quote) . separator
       }
       return RTrim(L,separator) . R
   }
   ;Func获取cpuid,需要在脚本开始阶段就执行
   static getCpuid()
   {
       query := "SELECT * FROM Win32_Processor"
       wmi := ComObjGet("winmgmts:\\.\root\cimv2")
       col := wmi.ExecQuery(query)
       for obj in col {
           return this.cpuid:=obj.ProcessorID
       }
       return ""
   }
   ;Func 静默执行cmd命令,返回0 就是成功！
   static shellExcuter(str)
   {
      return DllCall("shell32\ShellExecute", "uint", 0, "str","open","str", "cmd","str",Format("/c{1}",str), "uint", 0, "int", 0)
   }
   ;判断字符串是否以什么开头 str：原字符串  subStr:判断字符串
   static strBeginWith(str,subStr)
   {
      return inStr(str,subStr)==1?true:false
   }
   ;判断字符串是否以什么结尾 str：原字符串  subStr:判断字符串
   static strEndWith(str,sub)
   {
       return inStr(str,sub)?(subStr(str,strLen(str)-strLen(sub)+1)==sub?1:0):0
   }
   ;从路径中获取文件名或者是后缀 path:路径 ,separator 分隔器
   static getSuffix(path,separator:="\")
   {
     return inStr(path,separator)?SubStr(path,this.getStrLastIndex(path,separator)?this.getStrLastIndex(path,separator)+1:strLen(path)):""
   }
   ;判断是否连接互联网
   static ConnectedToInternet(flag:=0x40) {
      Return DllCall("Wininet.dll\InternetGetConnectedState", "Str", flag,"Int",0)
   }
   ;找到字符最后一次出现的位置 str:原字符串,needle:需要寻找的字符串
   static getStrLastIndex(str,needle)
   {
        loop  len:=strLen(str){
           if(SubStr(str, len-A_index+1,strLen(needle))==needle)
               return  len-A_index+1
        }
        return 0
   }
    ;Func 设置鼠标指针形态为忙等待
   static setSystemCursor()
   {
       IDC_ARROW := 32512
       hCursor  := DllCall( "LoadCursorFromFile", "Str", "C:\Windows\Cursors\aero_working.ani")
       DllCall("SetSystemCursor", "UInt", hCursor, "Int", IDC_ARROW)
   }
   ;Func 设置鼠标指针形态为正常形态
   static restoreCursors()
   {
       SPI_SETCURSORS := 0x57
       DllCall("SystemParametersInfo", "UInt", SPI_SETCURSORS, "UInt", 0, "UInt", 0, "UInt", 0)
   }
   ;Fucn读取配置文件到list返回一个Array，filePath：文件所在路径 ,注释符号"#"
   static readFileToList(filePath)
   {
        lines:=[]
        Loop read, filePath
           tmp:=(line:=trim(A_LoopReadLine)) and (not (inStr(line,"#")==1))?lines.push(line):unset
        return lines
   }
   ;Func读取配置文件到map返回一个Map，filePath：文件所在路径 ,注释符号"#" ,支持段落用{} 包裹、
   static readFileToMap(filePath, separator := "=")
   {
       configs := Map(), isCollecting := false, currentKey := currentValue := ""
       for line in ak.readFileToList(filePath) {
           trimmed := Trim(line)

           if (isCollecting) {
               if (trimmed == "}") {
                   configs[currentKey] := Trim(currentValue, "`n")
                   isCollecting := false, currentKey := currentValue := ""
               } else
                   currentValue .=StrReplace(StrReplace(line, "\#", "#"),"\}","}") "`n"
               continue
           }
           if (trimmed == "" || SubStr(trimmed, 1, 1) == "#")
               continue
           if (sepPos := InStr(trimmed, separator)) {
               key := Trim(SubStr(trimmed, 1, sepPos - 1)), val := Trim(SubStr(trimmed, sepPos + 1))
               if (val == "{")
                   isCollecting := true, currentKey := key, currentValue := ""
               else if (val == "")
                   currentKey := key
               ; 判定逻辑：以 [ 开头，以 ] 结尾，且中间不包含 ][ (防止误判公式)
               else if (SubStr(val, 1, 1) == "[" && SubStr(val, -1) == "]" && !InStr(val, "][")) {
                   arr := []
                   for item in StrSplit(SubStr(val, 2, -1), ",")
                       if (t := Trim(item)) != "" ; 避免空元素
                           arr.Push(t)
                   configs[key] := arr
               } else
                   configs[key] := val
           } else if (trimmed == "{" && currentKey != "")
               isCollecting := true, currentValue := ""
       }
       return configs
   }
   ;Func 通过value值来寻找key ,一般是一个key映射一个数组的时候，取数组中一个值来找key
   static maprget(mmap,value)
   {
      for k ,v in mmap{
         if (type(v)=="Array" and this.arrhas(v,value) )or(v==value){
            return k
          }
      }
      return
   }

   ;Func对中文编码进行unicode编码
   static encodeUtf8(str)
   {
        resultStr:=""
        Loop  Parse, str {
           resultStr:=resultStr . "\u" .  String(Ord(A_LoopField)>0x100 ? Format("{:04X}", Ord(A_LoopField) ):A_LoopField)
        }
        return resultStr
   }
   ;Func 对中英文unicode进行解码
   static decodeUtf8(str)
   {
       ret:="",aStr:=subStr(str,1,inStr(str,"\u")-1),bStr:=subStr(str,inStr(str,"\u")),arr:=strSplit(bStr,"\u")
       for k in arr{
            ret:=k?ret . chr(Abs("0x" . subStr(k,1,4))) . subStr(k,5):""
       }
       return aStr . ret
    }
   ;Func 利用js对url编码,由于采用js方式加密所以字符串中的“ " ”需要处理一下 ,只对参数编码
   static uriEncode(url)
   {
       static htmlfile := ComObject('htmlfile')
       htmlfile.write('<meta http-equiv="X-UA-Compatible" content="IE=edge">')
       return  htmlfile.parentWindow.encodeURI(url) ;还有一个方法encodeURIComponent会连http都编码
   }
   ;Func 利用js对url编码,由于采用js方式加密所以字符串中的“ " ”需要处理一下 ，只对参数解码
   static uriDecode(url) {
      static htmlfile := ComObject('htmlfile')
      htmlfile.write('<meta http-equiv="X-UA-Compatible" content="IE=edge">')
      return  htmlfile.parentWindow.decodeURI(url) ;还有一个方法decodeURIComponent会连http都解码
   }

   ;Func 利用js对url编码,由于采用js方式加密所以字符串中的“ " ”需要处理一下 ,只对参数编码
  static urlEncode(url)
  {
      static htmlfile := ComObject('htmlfile')
      htmlfile.write('<meta http-equiv="X-UA-Compatible" content="IE=edge">')
      return  htmlfile.parentWindow.encodeURIComponent(url) ;还有一个方法encodeURIComponent会连http都编码
  }
  ;Func 利用js对url编码,由于采用js方式加密所以字符串中的“ " ”需要处理一下 ，只对参数解码
  static urlDecode(url) {
     static htmlfile := ComObject('htmlfile')
     htmlfile.write('<meta http-equiv="X-UA-Compatible" content="IE=edge">')
     return  htmlfile.parentWindow.decodeURIComponent(url) ;还有一个方法decodeURIComponent会连http都解码
  }
   ;Func 生成32位UUID来源于guid
   static uuid()
   {
       shellobj := ComObject("Scriptlet.TypeLib")
       return RegExReplace(shellobj.GUID,"({|}|-)","") ;去掉花括号和-
    }
   ;Func 字符串串转换为list str：字符串list
   static strToList(str)
   {
       list:=[] ,str2:=Ltrim(Rtrim(trim(str),"]"),"[")
       Loop  parse, str2, "," ; 使用 , 解析字符串.
          list.push(Ltrim(Rtrim(A_LoopField)))
       return list
   }
   ;Fucn 逆波兰表达式计算 + - x ÷ 幂(**/^) 模(%)  expression:数学表达式可以带括号
   ;参考:https://blog.csdn.net/assiduous_me/article/details/101981332
   static polish_notation(expression)
   {
       operator_list:=Map("+",0,"-",0,"*",0,"`/",0,"%",0,"^",0) ;注意list的haskey操作只是检测索引
       operatorlevel_map:=Map("(",0,"+","1","-",1,"*",2,"/","2","%",2,"^",3,")",4)
       operator_map:=Map("+","add","-","sub" ,"*","multi","/","divi","%","mod2","^","pow")
       expression:=strReplace(strReplace(RegExReplace(trim(expression),"\s+",""),"**","^") ,"(-","(0-")
       expression:=inStr(expression,"-(")==1?strReplace(this.insertStrAt(expression,this.mirrorSymbolIndex(expression,"(",")"),")"),"-(","(0-("):expression
       ;①.获取一个中缀表达式集合类似 100+2 -> ["100","+","2"]
       middlefix_list:=[],fix:=""
       Loop parse,expression{
           current_value:=A_LoopField
           if(operatorlevel_map.has(current_value))
           {
             tmp:=""!=fix?middlefix_list.push(fix):""
             middlefix_list.push(current_value)
             fix:=""
           }else fix:=fix . current_value
       }
      tmp2:=fix!=""?middlefix_list.push(fix):""
      if(middlefix_list[1]="-"){ ;处理开头为负数
          middlefix_list.insertAt(1,"(")
          middlefix_list.insertAt(2,"0")
          middlefix_list.insertAt(5,")")
      }
      ;②.转换为后缀表达式(逆波兰表达式)
       operator_stack:=[] ,suffix_list:=[],number_stack:=[]
       for index ,currentElmt in middlefix_list
       {
         if(operator_list.has(currentElmt))
         {
             while(operator_stack.length>0 && operatorlevel_map.get(operator_stack.get(operator_stack.Length))>=operatorlevel_map.get(currentElmt))
                suffix_list.push(operator_stack.pop())
             operator_stack.push(currentElmt)
         }else if(currentElmt=="(")
            operator_stack.push("(")
         else if(currentElmt==")"){
            while(operator_stack.length>0 && operatorlevel_map.get(operator_stack.get(operator_stack.length))>operatorlevel_map.get("("))
               suffix_list.push(operator_stack.pop())
            if(operator_stack.length>0)
                operator_stack.pop()
         }else
             suffix_list.push(currentElmt)
       }
       while(operator_stack.length>0)
           suffix_list.push(operator_stack.pop())
       ;③.计算表达式最终的值，规则数字入栈，操作符就出栈两个元素计算值并把结果入栈
       for key,opertor_or_number in suffix_list{
          if(operator_list.has(opertor_or_number)){
               number2:=number_stack.pop(),number1:=number_stack.pop()
               tmpObj:={add:number1+number2,sub:number1-number2,multi:number1*number2,pow:number1**number2}
               T1:=opertor_or_number=="/"?(tmpObj.divi:=number1/number2):""       ;除法容易引发除0异常
               T2:=opertor_or_number=="%"?(tmpObj.mod2:=mod(number1,number2)):""  ;取模容易引发除0异常
               number_stack.push(tmpObj.%operator_map.get(opertor_or_number)%)
          }else
               number_stack.push(opertor_or_number)
       }
       return number_stack.pop()
   }
   ;Func 计算对称符号所在位置str:原字符串,firstIndex:左边符号所在位置,symbol:右边符号 返回右边符号在原字符串中索引 "-((10000+500)-500)/2" 返回18
   static mirrorSymbolIndex(str,Lsymbol,Rsymbol)
   {
       flag:=false ,list:=[]
       Loop Parse  ,str {
          if(Lsymbol==(sub:=subStr(Str,A_index,1))){
            list.push(sub)
            flag:=true
          }
          R:=Rsymbol==subStr(Str,A_index,1)?list.pop():""
          if(list.length==0 and flag)
            return A_index
       }
       return 0
   }
   ;Func 在字符串种插入片段 ，str：原字符串,index：插入位置（位置之后插入）,frag:插入片段
   static insertStrAt(str,index,frag)
   {
       return subStr(str,1,index) . frag . subStr(str,index+1)
   }
   ;Func 获取文件 base64 编码（单行，无换行），不依赖 certutil
   static getBase64(filepath) {
      filepath := !InStr(filepath, "\") ? A_Desktop "\" filepath : filepath
      if !FileExist(filepath)
          return ""
      f    := FileOpen(filepath, "r")
      size := f.Length
      buf  := Buffer(size)
      f.RawRead(buf, size)
      f.Close()
      NOCRLF := 0x40000001  ; CRYPT_STRING_BASE64 | CRYPT_STRING_NOCRLF
      DllCall("Crypt32.dll\CryptBinaryToStringW", "ptr", buf, "uint", size
            , "uint", NOCRLF, "ptr", 0, "uint*", &chars:=0)
      outBuf := Buffer(chars * 2)
      DllCall("Crypt32.dll\CryptBinaryToStringW", "ptr", buf, "uint", size
            , "uint", NOCRLF, "ptr", outBuf, "uint*", &chars)
      return StrGet(outBuf, "UTF-16")
   }
   ;Func获取当前系统时间
    static getTimeStr(A:="-",B:="_",C:="-")
    {
      return A_YYYY A A_MM A A_DD B A_Hour C A_Min C A_Sec
    }
   ;Func 显示网页 WB:activeX句柄 ,content:html内容,path:文件位置,timeout:=300
   static display(WB,content:="",path:="",timeout:=300)
   {
       if not content and not path
           throw Error("展示html时content和path同时为空")
       WB.silent := true
       if(content and not path and count:=1 ){
           while(FileExist(f:=Format("{1}\{2}{3}-tmp{4}DELETEME.html",A_Temp,A_TickCount,A_NowUTC,count)))
               count+=1
           FileAppend content,f
       }else if(path and not content)
           f:=path
       WB.Navigate("file://" . f)
       while((WB.readystate != 4) and --timeout>0)
            sleep 10
       return true
   }
   ;Func 发送http异步请求
   static sendHttpRequest(uri)
   {
       WebRequest := ComObject("WinHttp.WinHttpRequest.5.1")
       WebRequest.Open("GET", this.uriEncode(uri),true)  ;必须有http:// true 异步，false 同步(默认)
       WebRequest.Send()
       WebRequest.WaitForResponse()
       return  WebRequest.ResponseText
   }
   ;Func 在某个文件夹下面找文件 返回完整路径
    static findFileInDir(dir,filename)
    {
       Loop Files ,dir . "\*."  . this.getSuffix(filename,"."),"R"{
         if(this.strEndWith(A_LoopFilePath,filename))
             return A_LoopFilePath
       }
       return 0
    }
    ;Func 获取选中数据通过剪切板
    static getSelectStr(timeout:=3)
    {
       if((tmp:=this.clipdataType)!=2) ;非图片的时候才会恢复数据
            clipSave:=ClipboardAll()
       A_Clipboard := "" ; 必须清空, 才能检测是否有效.
       Send "^c"
       if not ClipWait(timeout)
            throw Error("等待剪切板数据超时:" . timeout . "s")
       selectStr:=A_Clipboard
       T3:=tmp==2?(A_Clipboard:="==========♜==========="):(A_Clipboard:=clipSave)  ;删除最近一条记录
       return selectStr
    }
    ;Func 选中字符串大写小写转换
    static upLowCaseString(timeout:=3)
    {
        if((tmp:=this.clipdataType)!=2) ;非图片的时候才会恢复数据
            clipSave:=ClipboardAll()
        A_Clipboard := "" ; 必须清空, 才能检测是否有效.
        Send "^c"
        if not ClipWait(timeout)
            throw Error("等待剪切板数据超时:" . timeout . "s")
        selectStr:=A_Clipboard
        if selectStr==StrUpper(selectStr)
            A_Clipboard:=StrLower(selectStr)
        else
            A_Clipboard:=StrUpper(selectStr)
        Send "^v"
        sleep 100
        T3:=tmp==2?(A_Clipboard:="==========♜==========="):(A_Clipboard:=clipSave)  ;恢复剪切板记录

    }
    ;Func 选中字符串大驼峰和下划线转换
    static camelCaseString(timeout:=3)
    {
        if((tmp:=this.clipdataType)!=2) ;非图片的时候才会恢复数据
            clipSave:=ClipboardAll()
        A_Clipboard := "" ; 必须清空, 才能检测是否有效.
        Send "^c"
        if not ClipWait(timeout)
            throw Error("等待剪切板数据超时:" . timeout . "s")
        selectStr:=A_Clipboard
        A_Clipboard:=ak.underlineCamelConvert(selectStr)
        Send "^v"
        sleep 100
        T3:=tmp==2?(A_Clipboard:="==========♜==========="):(A_Clipboard:=clipSave)  ;恢复剪切板记录

    }
    ;下划线和camel 相互转换
    static underlineCamelConvert(selectStr)
    {
       if not inStr(selectStr,"_")
           ret:=Trim(strLower(RegExReplace(selectStr, "([A-Z])", "_$1")),'_')
       else if inStr(selectStr,"_"){
           Loop Parse, selectStr, "_"{
               camelCaseString:=A_Index = 1?A_LoopField:camelCaseString . StrUpper(subStr(A_LoopField,1,1)) . Strlower(subStr(A_LoopField,2))
           }
           ret:=camelCaseString
       }else
           ret:=selectStr
       return ret
    }
    ;Func 快捷键ctrl+alt+down 向下复制一行,在win11记事本中不允许send 一行多个并且没有延时的操作！
    static copyNewLineDown(timeout:=3)
    {
        send  "{End}"
        sleep 60
        send "+{Home}"
        sleep 60
        if((tmp:=this.clipdataType)!=2) ;非图片的时候才会恢复数据
            clipSave:=ClipboardAll()
        A_Clipboard := "" ; 必须清空, 才能检测是否有效.
        Send "^c"
        if not ClipWait(timeout)
            throw Error("等待剪切板数据超时:" . timeout . "s")
        Send "{End}"
        sleep 60
        send "{Enter}"
        Send "^v"
        Sleep 100 ;
        T3:=tmp==2?(A_Clipboard:="==========♜==========="):(A_Clipboard:=clipSave)  ;恢复剪切板记录
    }
    ;Func frameShadow 窗口阴影
    static frameShadow(HGui)
    {
       _MARGINS:=Buffer(16)
       NumPut("UInt",0,_MARGINS,0),NumPut("UInt",0,_MARGINS,4),NumPut("UInt",1,_MARGINS,8),NumPut("UInt",0,_MARGINS,12)
       DllCall("dwmapi\DwmSetWindowAttribute", "Ptr", HGui, "UInt", 2, "Int*", 2, "UInt", 4)
       DllCall("dwmapi\DwmExtendFrameIntoClientArea", "Ptr", HGui, "Ptr", _MARGINS)
    }
    ;Func 获取时间戳
    static getTimeStamp(){
        ; datediff 计算现在的utc时间到unix时间戳的起始时间经过的秒数
        return DateDiff(A_NowUTC,'19700101000000','S')*1000+A_MSec
    }
    ;Func 获取请求头中的数据返回一个obj对象传入一个请求头 map={a:{value:"hello",path:"/" , expires:"Sun, 22 Jan 2023 03:46:59 GMT",size:n},xx:"xxx"}
    static getHeaderObj(header)
    {
        resobj:={},cookieobj:={},size:=0
        Loop parse ,header, "`n" {
           if  A_loopField and index:=inStr(A_loopField,":"){
              key:=trim(subStr(A_loopField,1,index-1))
              value:=trim(subStr(A_loopField,index+1))
              if(key=="Set-Cookie"){
                 lineobj:={} , cookieKey:=""
                 for v in strSplit(value,";"){
                    if indexb:=inStr(v,"=") {
                        a:=trim(subStr(v,1,indexb-1))
                        b:=trim(subStr(v,indexb+1))
                        A_index==1 ?((lineobj.value:=b)and (cookieKey:=a)):(lineobj.%a%:=b)
                    }
                 }
                 cookieobj.%cookieKey%:=lineobj
                 size+=1
              }
              cookieobj.size:=size
              resobj.%key%:=value
           }
        }
        resobj.cookie:=cookieobj
        return resobj
    }
    ;获取window当前活动窗口路径，包括samba和桌面和文件夹但是不包括ftp服务器
    static getactivePath()
    {
        if  path:=winActive("ahk_class WorkerW") or winActive("ahk_class Progman") ?A_desktop:""
            return path
        if ((not path) and (hwnd:=winActive("ahk_class CabinetWClass"))){
            for win in ComObject("Shell.Application").Windows
               If (win.HWND = hwnd) {
                  path:=subStr(win.LocationURL,9)
                  drivernum:=ord(StrUpper(subStr(path,1,1)))
                  return (drivernum > 65 and drivernum<90 and inStr(path,":")==2) or inStr(path,"\\")==1?strReplace(path,"%20"," "):""
             }
        }
    }
    ;保存【剪切板】图片到指定位置，当图片width<minW 或者 height<minH时就会缩放图片 ,默认不缩放
    static savepic(path,minW:=0,minH:=0,scale:=1,imageType:="Png")
    {
        try{
            ps1:=(
                  "Add-Type -AssemblyName System.Windows.Forms;"
                . "$image = [System.Windows.Forms.Clipboard]::GetImage();"
                . "$width = $image.Width;"
                . "$height = $image.Height;"
                . "if ($width -lt {2} -or $height -lt {3})"
                . "{$width=$width *{4};"
                . "$height=$height *{4};};"
                . "[System.Drawing.Image+GetThumbnailImageAbort] $callback = { return $false };"
                . "$resizedImage=$image.GetThumbnailImage($width, $height, $callback, [System.IntPtr]::Zero);"
                . "$resizedImage.Save('{1}', [System.Drawing.Imaging.ImageFormat]::{5});"
                . "$resizedImage.Dispose();"
                . "$image.Dispose();"
            )
            ps1:=Format(ps1,path,minW,minH,scale,imageType)
            this.shellExcuter(Format('powershell.exe  -Command "{1}"',ps1))
        }catch as e{
            msgBox "Excute powershell Exception:" e.Message()
            return
        }
        return 1
    }
    ;Func 处理在屏幕上显示的位置,返回图像所在x,y
    static dealshowGui(x,y,w,h,&newX, &newY,gap:=5)
    {
        newX:=x+w>A_ScreenWidth-gap ? A_ScreenWidth-gap -w:x ;处理右边界
        newY:=y+h>A_ScreenHeight-20?y-20-h:y ;处理下边界
    }
    ;删除数组中的值 ,当index=-1时表示删除对应值，如果不为-1则是对应的索引
    static arrDelete(arr2,index:=-1,value:="")
    {
        arr3:=[]
        for item in arr2{
            if index<0
                T1:=item!=value? arr3.push(item):""
            else
                T2:=A_index==index?"": arr3.push(item)
        }
        return arr3
    }
    ;Func 获取并保存数组中的值所在位置0
    static arrHas(arr2,value)
    {
        for item in arr2{
            if item==value
                return A_index
        }
        return 0
    }
    ;把 arr 数组变成set集合（不重复的arr）
    static arrSet(arr2)
    {
        arr3:=[]
        for item in arr2
            T1:=this.arrHas(arr3,item)?"":arr3.push(item)
        return arr3
    }
    ;Func 获取文件夹最新文件，path:路径， suffix:后缀 例如"txt,png,jpg..."
    static getlastFile(path,suffix)
    {
        Loop Files, path "\*." . suffix
            filelistStr.=A_LoopFileTimeCreated ":" A_LoopFileName "|"
        return (newStr:=isSet(filelistStr) ? Sort(filelistStr,"RD|"):"") ? (path . "\" . subStr(newStr,a:=(inStr(newstr,":")+1),inStr(newstr,"|")-a)):""
    }
    ;Func 获取当前系统上lnk和对应执行文件exe所在位置 ,lnk文件名和匹配模式0模糊，1精确匹配（默认）
    ;A_StartMenuCommon 公共软件 C:\ProgramData\Microsoft\Windows\Start Menu
    ;A_StartMenu       用户软件 C:\Users\<你的用户名>\AppData\Roaming\Microsoft\Windows\Start Menu
    ;matchmod=1都不区分大小写,等于0时不区分
    static findLinkAndExe(lnkname,&lnk,&path,&exe,matchmod:=1)
    {
        if ak.strEndWith(lnkname,"*"){
            matchmod:=0
            lnkname:=trim(subStr(lnkname,1,strLen(lnkname)-1))
        }
        for item in [A_Desktop,A_StartMenuCommon,A_StartMenu]{
            Loop Files, item   "\*.lnk", "R"{
                if ((not matchmod) and inStr(A_LoopFileName,lnkname)==1)
                    or (matchmod and ((lnkname . ".lnk")=A_LoopFileName)){
                    lnk:=A_LoopFileName
                    path:=A_LoopFileFullPath
                    FileGetShortcut(path,&exe)
                    return
                }
            }
        }
    }
    ; 帮助map获取值，优化原生map报错问题，ic控制是否忽略大小写
     static mapget(m, k, ic := 0) {
         try {
             if !ic {
                 for tk, tv in m {
                     if (tk == k)
                         return tv
                 }
             } else {
                 try return m[k]
                 for tk, tv in m {
                     if (tk = k)
                         return tv
                 }
             }
         }
         return ""
     }
    ;Func 使任务栏透明
    static transparentTaskBar()
    {
        ;0：表示禁用玻璃效果和透明度，窗口不会有透明效果。
        ;1：表示启用玻璃效果，通常以一种轻度透明的方式呈现窗口。
        ;2：表示启用玻璃效果，通常以更明显的透明方式呈现窗口。
        ;3：表示启用玻璃效果，通常以更明显的透明方式呈现窗口，并带有模糊效果。
        accent_state:=2
        WCA_ACCENT_POLICY := 19
        pad := A_PtrSize=8 ? 4 : 0
        gradient_color:="0x01000000"
        ACCENT_POLICY:=Buffer(16,0)
        WINCOMPATTRDATA:=Buffer( 4 + pad + A_PtrSize + 4 + pad,0)
        hTrayWnd := DllCall("User32\FindWindow", "str", "Shell_TrayWnd", "ptr", 0, "ptr")
        NumPut("int",(accent_state>0 && accent_state<4) ? accent_state : 0, ACCENT_POLICY, 0)
        NumPut("int",gradient_color, ACCENT_POLICY, 8)
        NumPut("int",WCA_ACCENT_POLICY, WINCOMPATTRDATA, 0)
        NumPut("int*",ACCENT_POLICY.ptr, WINCOMPATTRDATA, 4 + pad)
        NumPut("uint",ACCENT_POLICY.size, WINCOMPATTRDATA,  4 + pad + A_PtrSize)
        DllCall("user32\SetWindowCompositionAttribute", "ptr", hTrayWnd, "ptr", WINCOMPATTRDATA)
    }
    ;func 获取一个字符asc码值或是chr值
    static getAscOrChr(item,ascb:=1)
    {
         _map:=Map()
         _map.set("0","{NUL}")   ;空 ^@
         _map.set("1","{SOH}")   ;头标开始 ^A
         _map.set("2","{STX}")   ;正文开始 ^B
         _map.set("4","{EOT}")   ;正文结束 ^C
         _map.set("5","{ENQ}")   ;查询 ^E
         _map.set("6","{ACK}")   ;确认 ^F
         _map.set("7","{BEL}")   ;震铃 ^G
         _map.set("8","{BS}")    ;退格 ^H
         _map.set("9","{TAB}")   ;水平制表符
         _map.set("10","{换行}")   ;换行(\n) ^J
         _map.set("11","{VT}")   ;竖直制表符 ^K
         _map.set("12","{FF}")   ;换页^L
         _map.set("13","{回车}") ;回车(\r)
         _map.set("14","{SO}")   ;移出 ^N
         _map.set("15","{SI}")   ;移入 ^O
         _map.set("16","{DLE}")  ;数据链路转意 ^P
         _map.set("17","{DC1}")  ;设备控制符1 ^Q
         _map.set("18","{DC2}")  ;设备控制符2 ^R
         _map.set("19","{DC3}")  ;设备控制符3 ^S
         _map.set("20","{DC4}")  ;设备控制符4 ^T
         _map.set("21","{NAK}")  ;反确认 ^U
         _map.set("22","{SYN}")  ;同步空闲 ^V
         _map.set("23","{ETB}")  ;传输块结束 ^W
         _map.set("24","{CAN}")  ;取消^X
         _map.set("25","{EM}")   ;媒体结束 ^Y
         _map.set("26","{SUB}")  ;替换 ^Z
         _map.set("27","{ESC}")  ;转意 ^[
         _map.set("28","{FS}")   ;文件分隔符 ^\
         _map.set("29","{GS}")   ;组分隔符 ^]
         _map.set("30","{RS}")   ;记录分隔符 ^6
         _map.set("31","{US}")   ;单元分隔符 ^-
         _map.set("32","{空格}") ;空格
         _map.set("127","{^BASCK SPACE}") ;退格
         ;添加常规字符
         Loop  94
            _map.set(String(A_index+32),chr(A_index+32))
         return ascb?(ak.maprget(_map,item) || Ord(item)):(ak.mapget(_map,item) || chr(item))
    }

    ;Func 处理算式中含有k,w,y的,formula 表达式
    static set_bignumber(formula)
    {
      formula:=RegExReplace(formula,"(\d*\.*\d*)k|K","($1*1000)")      ;处理1k
      formula:=RegExReplace(formula,"(\d*\.*\d*)w|W","($1*10000)")     ;处理 1w
      formula:=RegExReplace(formula,"(\d*\.*\d*)y|Y","($1*100000000)") ;处理1亿
      return formula
    }
    ;func 作用：处理大的数字，
    ;参数：bigNumber数字类型的大数字，char_flag:0,1(是否带k,w,y)， scale 数字类型保留几位小数
    ;返回：返回字符串
    ;msgBox % Round(100,2)
    static get_bignumber(bigNumber,scale:=0,char_flag:=1)
    {
        ;判断有几位小数
        index:=InStr(bigNumber,".")
        left :=index=0?strLen(bigNumber):InStr(bigNumber,".")-1
        unit:="",prefix:="="
        if char_flag{
            if(left==4) ;单位K
            {
                result:=Round(bigNumber/1000,scale)
                prefix:=(result==bigNumber/1000)?"=":"≈"
                unit:="k"
            }else if(left>4 && left <9) ;单位w
            {
                result:=Round(bigNumber/10000,scale)
                prefix:=(result==bigNumber/10000)?"=":"≈"
                unit:="w"
            }else if(left>=9) ;单位亿
            {
                result:=Round(bigNumber/100000000,scale)
                prefix:=(result==bigNumber/100000000)?"=":"≈"
                unit:="亿"
            }else{ ;小于1k
                result:=Round(bigNumber,scale)
                prefix:=(result==bigNumber)?"=":"≈"
            }
        }else{ ;正常表示方式
            result:=Round(bigNumber,scale)
            prefix:=(result==bigNumber)?"=":"≈"
        }
        result:=RegExReplace(result,"\.0+$","") ;去掉 2.000这样式的
        if(InStr(result,".")>0)
            result:=RegExReplace(result,"0+$","")
        return prefix . result . unit
    }
    ;Func 获取某个指定id的元素内容，htmlcontent:整个html页面，id:标签里面的id,htmlflag:如果有html就返回html
    ;htmlflag:=0就是只取标签中的文字，不管有多少个标签。默认该值返回标签
    static getInnerHtml(htmlcontent,id,htmlflag:=1)
    {
         js:= ComObject("htmlfile")
         js.write(htmlcontent)
         document :=js.parentWindow.document
         element:=document.getElementByID(id)
         if element{
            return htmlflag?element.innerHtml:element.innerText
         }
    }
    ;Func 通过id获取htmlcontent中指定标签中的的指定属性attr
    static getElementAttr(htmlcontent,id ,attr)
    {
        js:= ComObject("htmlfile")
        js.write(htmlcontent)
        document :=js.parentWindow.document
        element:=document.getElementByID(id)
        return element.getAttribute(attr)
    }
    ;Func  十进制转换为任意进制，n:10000 ,也可传入16进制0x
     static tenToOther(n,b)
     {
           return (n < b ? "" : this.tenToOther(n//b,b)) . ((d:=Mod(n,b)) < 10 ? d : Chr(d+55))
     }
     ;Func 计算任意进制的十进制，str:101010(二进制) 或者其他进制，不能带o或者0x前缀
     static otherToTen(n,b)
     {
          MI:=strLen(n) ;幂
          Loop  parse, n
              result .= A_Loopfield  "*" b "^" MI-A_Index "+"
          return this.polish_notation(rtrim(result,"+"))
     }
     ;Func设置图标的上提示文字 ,txt:要设置的文字，n所在行数(从上到下1->n)
     ;默认第一行为文件名,n大于最大行数就放在最下边
     ;txt为空就是删除第n行数据
     static seticonTip(txt,n)
     {
         static tipArr:=[]
         T1:=tipArr.length==0?tipArr.push(A_ScriptName):""
         if n>tipArr.length{
            loop n-tipArr.length
               tipArr.push("")
         }
         tipArr[n]:=txt
         arr2:= ak.arrDelete(not txt? ak.arrDelete(tipArr,n):tipArr ,,"") ;删除空串
         A_IconTip:= ak.joinArr(arr2,"`n","","")
     }
     ;Func 修正自带的Trim存在的问题 ,如果带有字符串加空格会有问题
     static trim(str,Tstr,LorR:="")
     {
        if not LorR
            return str
        else if LorR = "L"
            return   inStr(str,Tstr)==1? subStr(str,strLen(Tstr)+1):str
        else if LorR = "R"
            return   inStr(str,Tstr)==(pre:=strLen(str)-strLen(Tstr)+1)? subStr(str,1,pre-1):str
     }
     ;Func 修改壁纸
     static changeWallpaper(path)
     {
        RegWrite(path,"REG_SZ", "HKEY_CURRENT_USER\Control Panel\Desktop", "Wallpaper")
        DllCall("SystemParametersInfo", "UInt", 0x14, "UInt", 0, "Str", path, "UInt", 2)
     }
     ;Func 异步获取网页内容,返回完整的html,传入完整的url 例：http://www.baidu.com
     static getHtmlContent(url)
     {
        static req := comObject("WinHttp.WinHttpRequest.5.1")
        req.Open("get",url,true)
        req.setRequestHeader("User-Agent","Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/109.0.0.0 Safari/537.36")
        req.send()
        req.WaitForResponse()
        return req.ResponseText
     }
     ;Func 判断是否是刚开机，传入时间 n 秒
     static onStartPc(n:=60)
     {
         return (A_TickCount/1000)<n
     }
     ;Func powershell获取剪切板文件的绝对路径,如果不为null，就写入剪切板中
     static getClipFilePath(){
         ps1:=(
               "Add-Type -AssemblyName System.Windows.Forms;"
             . "$filePath = [System.Windows.Forms.Clipboard]::GetFileDropList()[0];"
             . "if ($filePath -ne $null) {"
             . "[System.Windows.Forms.Clipboard]::SetText($filePath);"
             . "}"
         )
         this.shellExcuter(Format('powershell.exe  -Command "{1}"',ps1))
     }
     ;Func 获取字符串内容中两个字符串中间的字符串,返回中间字符串
     static getstrBAB(content ,strA:="",strB:="",trimL:=1,trimR:=1)
     {
         switch{
             case strA and not strB: ret:=(iA:=inStr(content,strA)) ? subStr(content,iA):""
             case not strA and strB: ret:=(iB:=inStr(content,strB))? subStr(content,1,iB+strLen(strB)-1) :""
             case strA and strB:  ret:=((iA:=inStr(content,strA)) and (iB:=inStr(content,strB,1,iA+strLen(strA))))?subStr(content,iA,iB-iA+strLen(strB)):""
             case "Default": ret:=""
         }
         ret:=trimR?subStr(ret,1,strLen(ret)-strLen(strB)):ret
         return trimL?subStr(ret,strLen(strA)+1 ):ret
     }
     ;Func 获取当前文件夹下，以beginStr开头的文件完整路径
     static getPathByBegin(dir,beginStr,suffix:=".png")
     {
        Loop Files, Format("{1}\{2}*{3}",dir,beginStr,suffix){
            if inStr(A_LoopFileName,beginStr)
                return A_LoopFileFullPath
        }
     }
     ;Func 打开或者关闭系统代理
     static sysProxySwitch(configMap,onProxy:=1)
     {
        whiteList:="localhost;127.*;10.*;172.16.*;172.17.*;172.18.*;172.19.*;172.20.*;172.21.*;172.22.*;172.23.*;172.24.*;172.25.*;172.26.*;172.27.*;172.28.*;172.29.*;172.30.*;172.31.*;192.168.*;apps.microsoft.com;browser.events.data.microsoft.com;<local>"
        extra:=whiteList . ";" . ak.mapget(configMap,"sysproxyWhiteList")
        ProxyServer:=ak.mapget(configMap,"ProxyServer")
        proxySetPath:="HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Internet Settings"
        if onProxy and this.regHasKey(proxySetPath,"ProxyEnable") and RegRead(proxySetPath, "ProxyEnable")=0{
            RegWrite  1 ,"REG_DWORD" , proxySetPath ,"ProxyEnable"
            RegWrite  ProxyServer,"REG_SZ" , proxySetPath ,"ProxyServer"
            RegWrite  extra,"REG_SZ" , proxySetPath ,"ProxyOverride"
        } else if not onProxy and this.regHasKey(proxySetPath,"ProxyServer") and  RegRead(proxySetPath, "ProxyServer")=ProxyServer
            RegWrite 0 ,"REG_DWORD" , proxySetPath ,"ProxyEnable"
        return
     }
     ;Func 在字符串指定位置index [后面] 插入字符串str
     static strInsertAt(sstr,index,str)
     {
        return index<1 ? sstr : ((index>strLen(sstr)?  sstr: "") || (subStr(sstr,1,index) . str . subStr(sstr,index+1)))
     }
     ;Func 获取桌面壁纸绝对地址
     static getDesktopWallpaperPath()
     {
         return RegRead("HKEY_CURRENT_USER\Control Panel\Desktop", "Wallpaper")
     }
     ;Func 计算两个时间差 A-B , Seconds(秒), Minutes(分), Hours(小时) 或 Days(天),roughTime:粗略值
     static timeDiffRough(A,B)
     {
         s:=DateDiff(A,B,"Seconds")
         switch {
            case s<60: roughTime:=strReplace(Format("{:3}" ,s)  ," " ," ") "秒钟"
            case 60<s and s<3600: roughTime:=strReplace(Format("{:3}" ,Ceil(s/60))," " ," ")  "分钟"
            case 3600<s and s<86400: roughTime:=strReplace(Format("{:3}" ,Ceil(s/3600))," " ," ")  "小时"
            case 86400<s and s<2592000: roughTime:="　" . strReplace(Format("{:3}",Ceil(s/86400))," " ," ")  "天"
            case 2592000<s and s<31536000: roughTime:= "　" . strReplace(Format("{:3}",Ceil(s/2592000))," " ," ") "月"
            case s>31536000:roughTime:="　" . strReplace(Format("{:3}",Ceil(s/31536000))," " ," ") "年"
         }
         return roughTime
     }
     ;判断当前key下是否有某个项
     static regHasKey(keyName,name)
     {
         Loop Reg keyName{
             if A_LoopRegName=name
                 return 1
         }
         return 0
     }
     ;Func 处理时间 20240124014352 变成 2024-01-24 01:43:52
     static dealtime(timestr,A:="-",B:=" ",C:=":")
     {
         return subStr(timestr,1,4) . A . subStr(timestr,5,2) . A . subStr(timestr,7,2)
             . B  . subStr(timestr,9,2) . C . subStr(timestr,11,2) . C . subStr(timestr,13)
     }
     ;Func 查询后缀 ext的关联执行exe 所在完整路径
     static getAssocExe(ext) {
         try{
             ;map 存放后缀对应exe文件
             static assocMap:=Map()
             if (ret:=this.mapget(assocMap,ext))
                return ret
             DllCall("Shell32\SHAssocEnumHandlers", "str", ext, "int", 0, "ptr*", enum := ComValue(13, 0), "hresult")
             ComCall(3, enum, "uint", 1, "ptr*", assoc := ComValue(13, 0), "uint*", &fetched := 0)
             ComCall(3, assoc, "str*", &name)
             assocMap[ext]:=name
             return name
         }
     }
     ;传入 base64 字符串，同步解码并写入目标文件（支持文本/二进制，不依赖 certutil）
     static createFileByBase64(base64str, despath) {
        CRYPT_STRING_BASE64 := 0x1
        DllCall("Crypt32.dll\CryptStringToBinary", "str", base64str, "uint", 0, "uint", CRYPT_STRING_BASE64
              , "ptr", 0, "uint*", &size:=0, "ptr", 0, "ptr", 0)
        if size = 0
            return
        buf := Buffer(size)
        DllCall("Crypt32.dll\CryptStringToBinary", "str", base64str, "uint", 0, "uint", CRYPT_STRING_BASE64
              , "ptr", buf, "uint*", &size, "ptr", 0, "ptr", 0)
        try FileDelete despath
        f := FileOpen(despath, "w")
        f.RawWrite(buf, size)
        f.Close()
     }
     ;Func 对数组或者字符串排序,默认降序desc=1 ,升序desc:=0 ,返回一个新的数组
     static orderListOrString(list,desc:=1)
     {
         return strSplit(Sort((type(list)=="Array"?this.joinArr(list,,"",""):list),(desc ?"R":"") . " D,") ,",")
     }
     ;Func 获取当前文件脚本对应部分,用于生成新的脚本
     static getPartScript(part,newLine:=1,runpath:="",syspath:="")
     {
        _obj:={    ak:"[@ak#1FFF08E96143432088593A06D97CECF7]" ,
               recent:"[@recent#5889F150A6B1430580B07D9028C9C0E4]",
                 func:"[@func-A46687E52FCF472ABE87DD1DEB29177E]" ,
    getResourceBase64:"[@getIco-CB747C07A3FB4A31B5FCBE475DE40C85]",
          linkManager:"[@linkManager#7A3C9D21E84F16B05C2A78FD0E531B94]"
            }
        return this.getstrBAB(fileRead(A_lineFile),(v:=strReplace(_obj.%part%,"#","-")),v)  . (newLine?"`n":"")
     }
     ;获取管理员权限
     static getAdminAccess()
     {
        for arg in A_args  ; For each parameter:
           params .= A_Space . A_index
        ShellExecute := A_PtrSize ==8 ? "shell32\ShellExecute":"shell32\ShellExecuteA"
        if not A_IsAdmin{
            If A_IsCompiled
               DllCall(ShellExecute, "uint", 0, "str", "RunAs", "str", A_ScriptFullPath, "str", params??"" , "str", A_WorkingDir, "int", 1)
            Else
               DllCall(ShellExecute, "uint", 0, "str", "RunAs", "str", A_AhkPath, "str", '"' . A_ScriptFullPath . '"' . A_Space . (params??""), "str", A_WorkingDir, "int", 1)
            ExitApp
        }
     }
    ;Func 对字符串进行base64编码
    static Base64Decode(s) {
       s := Trim(s)
       s := RegExReplace(s, "(?i)^.*?;base64,")
       size := StrLen(RTrim(s, "=")) * 3 // 4
       bin := Buffer(size)
       flags := 0x1 ; CRYPT_STRING_BASE64
       DllCall("crypt32\CryptStringToBinary", "str", s, "uint", 0, "uint", flags, "ptr", bin, "uint*", size, "ptr", 0, "ptr", 0)
       return StrGet(bin, size, "UTF-8")
    }
    ;Func 对字符串进行base64解码
    static Base64Encode(s) {
       size := StrPut(s, "UTF-8")
       bin := Buffer(size)
       StrPut(s, bin, "UTF-8")
       size := size - 1 ; A binary does not have a null terminator
       length := 4 * Ceil(size / 3) + 1   ; A string has a null terminator
       VarSetStrCapacity(&str, length)    ; Allocates a ANSI or Unicode string
       flags := 0x40000001 ; CRYPT_STRING_NOCRLF | CRYPT_STRING_BASE64
       DllCall("crypt32\CryptBinaryToString", "ptr", bin, "uint", size, "uint", flags, "str", str, "uint*", &length)
       return str
    }
    ;Func 执行powershell
    static runPowershell(cmdline,showflag:=0)
    {
        if showflag
            RunWait  Format('PowerShell.exe -ExecutionPolicy Bypass -Command "{1}" ',cmdline)
        else
            this.shellExcuter(Format('powershell.exe  -Command "{1}"',cmdline))
    }
    ;Func 显示tooltip ,默认是鼠标位置 ,index:=1-20 可以有20个
    static showToolTip(txt,dms:=3000,x:=-1,y:=-1,index:=2)
    {
        if x==-1 and y==-1{
            MouseGetPos &x,&y
            x+=10, y+=10
         }
        tooltip  txt ,x,y ,index
        SetTimer () => tooltip(,,,index), dms
    }

    ;Func 执行powershell 对目标文件进行base64加密，可以选择把文件分隔成多份
    static Base64EncodeFile(fullpath , rFileNum:=1){
        dirName:=StrReplace(fullpath,(fileName := this.getSuffix(fullpath)),"")
        ps1:=(
                "$fileBytes = [System.IO.File]::ReadAllBytes('{1}'); "
                . "$base64String = [System.Convert]::ToBase64String($fileBytes); "
                . "$base64String | Out-File -FilePath '{2}' -Encoding ASCII; "
               )
        DirCreate newDir:=(fullpath . "_dir")
        ps1:=Format(ps1,fullpath,(base64path:=newDir . "\" . fileName  . "_base64"))
        this.runPowershell(ps1,1)
        if rFileNum>1{
            this.splitFile(base64path,rFileNum,newDir)
        }
        return newDir
    }

    ;分割大文件，输出到指定目录outDir
    static splitFile(fullpath ,n,outDir){
        dirName:=StrReplace(fullpath,(fileName := this.getSuffix(fullpath)),"")
        len:=strLen(fileContent:=fileRead(fullpath))
        segmentlen:=Ceil(len/n)
        loop(n)
            fileAppend subStr(fileContent,(A_index-1)*segmentlen+1,segmentlen) ,outDir . "\"
                . fileName  . "_" . A_index
    }
    ;Func 计算字符串MD5码
    static MD5(string) {
       static PROV_RSA_FULL := 1, CRYPT_VERIFYCONTEXT := 0xF0000000
       static HP_HASHVAL := 0x0002, CALG_MD5 := 0x00008003
       if !DllCall("Advapi32\CryptAcquireContext", "Ptr*", &hProv:=0, "Ptr", 0, "Ptr", 0, "UInt", PROV_RSA_FULL, "UInt", CRYPT_VERIFYCONTEXT)
           throw Error("CryptAcquireContext failed", -1)
       if !DllCall("Advapi32\CryptCreateHash", "Ptr", hProv, "UInt", CALG_MD5, "UInt", 0, "UInt", 0, "Ptr*", &hHash:=0)
           throw Error("CryptCreateHash failed", -1)
       buf := Buffer(StrPut(string, "UTF-8"))
       StrPut(string, buf, "UTF-8")
       if !DllCall("Advapi32\CryptHashData", "Ptr", hHash, "Ptr", buf, "UInt", buf.Size, "UInt", 0)
           throw Error("CryptHashData failed", -1)
       if !DllCall("Advapi32\CryptGetHashParam", "Ptr", hHash, "UInt", HP_HASHVAL, "Ptr", 0, "UInt*", &hashLen:=0, "UInt", 0)
           throw Error("CryptGetHashParam failed", -1)
       hashBuf := Buffer(hashLen)
       if !DllCall("Advapi32\CryptGetHashParam", "Ptr", hHash, "UInt", HP_HASHVAL, "Ptr", hashBuf, "UInt*", &hashLen, "UInt", 0)
           throw Error("CryptGetHashParam failed", -1)
       DllCall("Advapi32\CryptDestroyHash", "Ptr", hHash)
       DllCall("Advapi32\CryptReleaseContext", "Ptr", hProv, "UInt", 0)
       loop hashLen {
           hex := Format("{:02x}", NumGet(hashBuf, A_Index-1, "UChar"))
           hash .= hex
       }
       return hash
   }
   ;Func 生成32位UUID
   static GenerateUUID() {
       shell := ComObject("Scriptlet.TypeLib")
       guid := shell.GUID
       return RegExReplace(guid, "[{}]")  ; 去掉花括号和连字符，得到32位纯UUID
   }
   ;Func 获取当前桌面的编号
   static GetCurrentDesktopNumber() {
       static SessionId := 1 ; 绝大多数单用户情况为 1
       ; 1. 尝试获取当前桌面的 UUID (兼容 Win10/Win11 不同路径)
       currentUUID := ""
       paths := [
           "HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\SessionInfo\" SessionId "\VirtualDesktops",
           "HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\VirtualDesktops"
       ]
       for path in paths {
           try {
               currentUUID := RegRead(path, "CurrentVirtualDesktop")
               if (currentUUID)
                   break
           }
       }
       if (!currentUUID)
           return 1 ; 如果找不到当前 UUID，通常说明只有一个桌面
       ; 2. 获取所有桌面的 UUID 列表 (兼容新旧版 Win11)
       allUUIDs := ""
       listValues := ["VirtualDesktopIds", "VirtualDesktopIdReversed"] ; 尝试新旧两个键名
       for valName in listValues {
           try {
               allUUIDs := RegRead("HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\VirtualDesktops", valName)
               if (allUUIDs)
                   break
           }
       }
       ; 3. 匹配编号
       if (allUUIDs) {
           ; UUID 在注册表中以二进制存储，每组 16 字节（32个十六进制字符）
           loop (StrLen(allUUIDs) / 32) {
               offset := (A_Index - 1) * 32 + 1
               if (SubStr(allUUIDs, offset, 32) = currentUUID)
                   return A_Index
           }
       }
       return 1
   }

}
;[@ak-1FFF08E96143432088593A06D97CECF7]
;++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++ak工具类class


;===========================================================================================================外部依赖 base64 数据（供 outDependData.init() 解码写入 A_Temp）

;-----------------------------------------------------------------------------------------------------------配置文件 base64 数据（HELPME_HOME 下自动同步 ahk/config/）
;若 ahk/config/ 下配置文件已存在，下次启动时会自动将文件内容编码后替换下方对应变量值
get_config_C11111:="IyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMNCiPlpoLmnpzmmK8x5byA5aS05YiZ5ZCO6Z2i6KGo6L6+5byP5Lit55qEIlsgXSLnmoTlgLzpnIDopoHorqHnrpcg77yMWyBd5Lit5pSv5oyBKy0qL17nrYnooajovr7lvI8sW13kuK3mlbDmja7kvJrmlbTkvZPkuZjlgI3mlbANCiPlpKflsI/lhpnmlY/mhJ8NCiMjI2Foa+aYoOWwhA0KY3RybD1eDQphbHQ9IQ0Kd2luPSMNCnNoaWZ0PSsNCg0KIyMjI+aXtumXtOaNoueulw0KMeWkqT1bMjRdW2hdIFsyNCo2MF1bbWluXSBbMjQqNjAqNjBdW3NdIFs4NjQwXXdbbXNdDQoxaD1bMS8yNF1b5aSpXSBbNjBdW21pbl0gWzYwKjYwXVtzXSBbMzYwXXdbbXNdDQoxbWluPVsxLzI0LzYwXVvlpKldIFsxLzYwXVtoXSBbNjBdW3NdIFs2XXdbbXNdDQoNCjFtcz1bMS8yNC82MC82MC8xMDAwXVvlpKldIFsxLzYwLzYwLzEwMDBdW2hdIFsxLzYwLzEwMDBdW21pbl0gWzEvMTAwMF1bc10NCg0KIyMj6K6h566X5a2Y5YKoDQoxR0I9WzEwMjRdW01CXSBbMTAyNCoxMDI0XVtLQl0gWzEwMjQqMTAyNCoxMDI0XVvlrZfoioJdIFsxMDI0KjEwMjQqMTAyNCo4XVtieXRlXQ0KMU1CPVsxLzEwMjRdW0dCXSBbMTAyNF1bS0JdIFsxMDI0KjEwMjRdW+Wtl+iKgl0gWzEwMjQqMTAyNCo4XVtieXRlXQ0KMUtCPVsxLzEwMjQvMTAyNF1bR0JdIFsxLzEwMjRdTUIgWzEwMjRdW+Wtl+iKgl0gWzEwMjQqOF1bYnl0ZV0NCjFCeXRlPVsxLzEwMjQvMTAyNC8xMDI0XVtHQl0gWzEvMTAyNC8xMDI0XVtNQl0gWzEvMTAyNF1bS0JdIFs4XVtieXRlXQ0KMWJ5dGU9WzEvMTAyNC8xMDI0LzEwMjQvOF1bR0JdIFsxLzEwMjQvMTAyNC84XVtNQl0gWzEvMTAyNC84XVtLQl0gWzEvOF1b5a2X6IqCXQ0KDQojIyPorqHnrpfljZXkvY0NCjHoi7Hph4w9WzEuNjA5MzQ0XSAoa20pIFswLjg2ODk3NjJdICjmtbfph4wpDQoxa209WzAuNjIxMzcxMl0gKOiLsemHjCkgWzAuNTM5OTU2OF0gKOa1t+mHjCkNCjHmtbfph4w9WzEuODUyXSAoa20pIFsxLjE1MDc3OTRdICjoi7Hph4wpIFsxXSjoioIpDQox6IqCPVsxLjg1Ml0gKGttKSBbMS4xNTA3Nzk0XSAo6Iux6YeMKSBbMV0o5rW36YeMKQ0KMeiLseWvuD1bMi41NF0gKGNtKSBbMC4wMjU0XSAobSkgWzAuNzYyXSAo5a+4KQ0KMeejhT1bMC40NTM2XSAoa2cpIFs0NTMuNl0gKGcpIFswLjk3Ml0gKOaWpCkNCjHlr7g9WzEwLzNdIChjbSkgWzEvMzBdIChtKQ0KMeWwuj1bMS8zXSAobSkgWzEwMC8zXSAoY20pDQox5LqpPVsyMDAwLzNdKG3CsikNCjHlhazpobc9WzE1XSjkuqkpIOmVv1sxMDBdKG0pIOWuvVsxMDBdKG0pDQoxbS9zPVszLjZdKGttL2gpIFsxLzM0MF3pqazotasNCjFrbS9oPVsxMDAwLzM2MDBdKG0vcykgWzEwMDAvMzYwMC8zNDBd6ams6LWrDQox6ams6LWrPVszNDBdKG0vcykgWzM0MCozLjZdKGttL2gpDQoNCiMjI+iuoeeul+eDremHjw0KMWtqPVswLjIzODldICjlpKfljaEpIFsyMzguOV0gKOWNoSkNCjHlpKfljaE9WzQuMTg1OF0gKOWNg+eEpikgIFs0MTg1XSAo54SmKQ0KDQojIyPpu4Tph5ENCjHnm47lj7g9WzI4LjM0OTUyMzEyNV0g5YWLDQoNCiMjIzEy5pe26L6wDQrlrZDml7Y9IDIzOjAwLTE6MDANCuS4keaXtj0gMTowMC0zOjAwDQrlr4Xml7Y9IDM6MDAtNTowMA0K5Y2v5pe2PSA1OjAwLTc6MDANCui+sOaXtj0gNzowMC05OjAwDQrlt7Pml7Y9IDk6MDAtMTE6MDANCuWNiOaXtj0gMTE6MDAtMTM6MDANCuacquaXtj0gMTM6MDAtMTU6MDANCueUs+aXtj0gMTU6MDAtMTc6MDANCumFieaXtj0gMTc6MDAtMTk6MDANCuaIjOaXtj0gMTk6MDAtMjE6MDANCuS6peaXtj0gMjE6MDAtMjM6MDANCg0KIyMj5bi46YePDQrlhYnpgJ89WzIuOTk3OTI0NThd5Lq/KG0vcykgWzI5Ljk3OTI0NThd5LiHKGttL3MpDQoNCiMjI+iuoumYheWcsOWdgA0K5rOh5rOh54uXPWh0dHBzOi8vMzA5ZGQyNGUtZTczNi00NmQyLTk4YTctYjY2NzM1NDY3OGI2LnBwZ25naW54LmNvbS9hcGkvdjEvY2xpZW50L3N1YnNjcmliZT90b2tlbj0yM2M5MjZmNGQ0NDNhYzA4NTM1YWFmNzJiODRiNjE5MA0K6a2U5oiSPWh0dHBzOi8vbW9qaWUwMjAxLnhuLS04c3R4OG9scndrdWNqcTNiLmNvbS9hcGkvdjEvY2xpZW50L3N1YnNjcmliZT90b2tlbj02OTRlNGY2NzEyOTRjNWU5ZDQ1MzhhM2E0ZTdlMTk1OA0KQV9TT0NLUEFTUz1OaWNhaXlhXzAuMA0KcHJwcj1odHRwczovL2dldC5jcjQ1MC5jYy9jbGFzaC8xMzgxNzIvUlZIRTVZSlJ1dC8NCg0KDQoAAAAAAAA="
run_config_C22222:="IyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMNCiMjI+mFjee9ruWPguaVsOS4umtleT12YWx1ZeW9ouW8jw0KIyMjIGtlee+8iOWRveS7pOahhuS4rei+k+WFpeeahOWRveS7pO+8ie+8jHZhbHVl77yI5b+r5o235pa55byP5ZCN5a2X5ZCO6Z2i5Y+v55SoKuihqOekuuaooeeziuWMuemFje+8jOazqOaEjyropoHmjKjnnYDlkI3lrZfvvIxleGXnu53lr7not6/lvoTvvIznvZHlnYDvvIzmlofku7blpLkv5paH5Lu257ud5a+56Lev5b6E77yJDQoNCmFoa2Rpcj0lSEVMUE1FX0hPTUUlXGNvbW1hbmRfZXh0XGFoaw0KaGlzMj0lSEVMUE1FX0hPTUUlXGNvbW1hbmRfZXh0XGFoa1xsb2dccnVuLmxvZ1xydW5sb2cudHh0DQpsb2dkaXI9JUhFTFBNRV9IT01FJVxjb21tYW5kX2V4dFxhaGtcbG9nDQpiaW5nZGlyPSVIRUxQTUVfSE9NRSVcY29tbWFuZF9leHRcYWhrXGxvZ1x3YWxscGFwZXINCmNvbmZpZ2Rpcj0lSEVMUE1FX0hPTUUlXGNvbW1hbmRfZXh0XGFoa1xjb25maWcNCmNvbmZpZz0lSEVMUE1FX0hPTUUlXGNvbW1hbmRfZXh0XGFoa1xjb25maWdcc3lzY29uZmlnLnR4dA0Kc3lzY29uZmlnPSVIRUxQTUVfSE9NRSVcY29tbWFuZF9leHRcYWhrXGNvbmZpZ1xzeXNjb25maWcudHh0DQpoZWxwbWU9JUhFTFBNRV9IT01FJVxjb21tYW5kX2V4dFxhaGtcY29uZmlnXHJ1bmNvbmZpZy50eHQNCmdldGNvbmZpZz0lSEVMUE1FX0hPTUUlXGNvbW1hbmRfZXh0XGFoa1xjb25maWdcZ2V0Y29uZmlnLnR4dA0KaGVscG1lMj0lSEVMUE1FX0hPTUUlXGNvbW1hbmRfZXh0DQpoZWxwbWUzPSVIRUxQTUVfSE9NRSVcY29tbWFuZF9qYXZhDQpyYWRhcj0lSEVMUE1FX0hPTUUlXGNvbW1hbmRfZXh0XHJhZGFyXHJhZGFyLmV4ZQ0Kc25pcGFzdGU9JUhFTFBNRV9IT01FJVxjb21tYW5kX2V4dFxTbmlwYXN0ZS0yLjUuNi1CZXRhLXg2NFxTbmlwYXN0ZS5leGUNCnBpeHBpbj0lSEVMUE1FX0hPTUUlXGNvbW1hbmRfZXh0XFBpeFBpblxQaXhQaW4uZXhlDQpoaXNkaXI9JUhFTFBNRV9IT01FJVxjb21tYW5kX2V4dFxhaGtcbG9nXGNsaXAubG9nDQpoaXNwaWM9JUhFTFBNRV9IT01FJVxjb21tYW5kX2V4dFxhaGtcbG9nXHBpYy5sb2cNCmNwdXo9JUhFTFBNRV9IT01FJVxjb21tYW5kX2V4dFxDUFUtWl8xLjg2XGNwdXpfeDY0LmV4ZQ0KbHA9JUhFTFBNRV9IT01FJVxjb21tYW5kX2V4dFxnaWblvZXliLZcZ2lm5b2V5bGPLmV4ZQ0KY29udmVydD0lSEVMUE1FX0hPTUUlXGNvbW1hbmRfZXh0XGFoa1xhaGtfaW5zdGFsbFxjb21waWxlclxBaGsyRXhlLmV4ZQ0Kd2xtbj0lSEVMUE1FX0hPTUUlXGNvbW1hbmRfZXh0XGNsdW1zeS0wLjItd2luNjRcY2x1bXN5LmV4ZQ0KYWFyZGlvPSVIRUxQTUVfSE9NRSVcY29tbWFuZF9leHRcYWFyZGlvXGFhcmRpby5leGUNCmNsYXNoPSVIRUxQTUVfSE9NRSVcY29tbWFuZF9leHRcQ2xhc2ggVmVyZ2VcY2xhc2gtdmVyZ2UuZXhlDQpka3NtPSVIRUxQTUVfSE9NRSVcY29tbWFuZF9leHRc56uv5Y+j5omr5o+P5bel5YW3LmV4ZQ0KZGV2ID1FOlxkZXYNCnNzPSVIRUxQTUVfSE9NRSVcY29tbWFuZF9leHRcRXZlcnl0aGluZy0xLjQuMS4xMDI2Lng2NFxldmVyeXRoaW5nLmV4ZQ0KY3Bhbj1EOlxoZWxwbWVcY29tbWFuZF9leHRcU3BhY2VTbmlmZmVyLmV4ZQ0KDQojIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIw0KDQoNCiMjIyMjIyMjIyMjI+OAkOaJk+W8gOe9keWdgOOAkQ0KICBiYWlkdT1odHRwczovL3d3dy5iYWlkdS5jb20NCiAgNDM5OT1odHRwczovL3d3dy40Mzk5LmNvbS8NCiAgZmFueWk9aHR0cHM6Ly9mYW55aS55b3VkYW8uY29tLw0KICB5b3VkYW89aHR0cHM6Ly9mYW55aS55b3VkYW8uY29tLw0KICBtYXA9aHR0cHM6Ly9tYXAuYmFpZHUuY29tL3NlYXJjaC8NCiAgdGFvYmFvPWh0dHBzOi8vd3d3LnRhb2Jhby5jb20vDQogIGpkPWh0dHBzOi8vd3d3LmpkLmNvbS8NCiAgY3Nkbj1odHRwczovL2Rvd25sb2FkLmNzZG4ubmV0L2xpc3QvZG93bmxvYWQ/dXRtX3NvdXJjZT1jc2RuX2RtX3RiJnNwbT0xMDAzLjIwMTguMzAwMS43OTUwDQogIGh1eWE9aHR0cHM6Ly93d3cuaHV5YS5jb20vDQogIHp4Z2o9aHR0cHM6Ly90b29sLmx1Lw0KICBzb2dvdT1odHRwczovL2ZhbnlpLnNvZ291LmNvbS90ZXh0DQogIGZhbnlpMj1odHRwczovL2ZhbnlpLnNvZ291LmNvbS90ZXh0DQogIHFxbWFpbD1odHRwczovL21haWwucXEuY29tLw0KICBwbmd0b2ljbz1odHRwczovL3d3dy5pbWcyZ28uY29tL3poL2NvbnZlcnQvcG5nLXRvLWljbw0KICBhbG1tPWh0dHBzOi8vd3d3Lmljb25mb250LmNuL2NvbGxlY3Rpb25zL2luZGV4P3NwbT1hMzEzeC43NzgxMDY5LjE5OTg5MTA0MTkuZDMzMTQ2ZDE0JnR5cGU9Mw0KICB4bGh5PWh0dHA6Ly9qaWUueHVubGVpeWl0aWFuLmNvbS9xXzM2NTZlYzM4MGUyNWMNCiAgcHJvY2Vzc09uPWh0dHBzOi8vcHJvY2Vzc29uLmNvbS8NCiAgaHV0b29sPWh0dHBzOi8vd3d3Lmh1dG9vbC5jbi9kb2NzLyMvDQogIHRpYW5xaT1odHRwczovL3dlYXRoZXJuZXcucGFlLmJhaWR1LmNvbS93ZWF0aGVybmV3L3BjP3F1ZXJ5PSVFNSU5QiU5QiVFNSVCNyU5RCVFNiU4OCU5MCVFOSU4MyVCRCVFNSVBNCVBOSVFNiVCMCU5NCZzcmNpZD00OTgyDQogIHRpYW5xaTI9aHR0cHM6Ly93d3cubXNuLmNuL3poLWNuL3dlYXRoZXIvZm9yZWNhc3QvaW4tQ2hlbmdkdT9sb2M9ZXlKc0lqb2lRMmhsYm1ka2RTSXNJbWtpT2lKRFRpSXNJbWNpT2lKNmFDMWpiaUlzSW5naU9qRXdNeTQ1T1Rnek9UYzRNamN4TkRnME5Dd2llU0k2TXpBdU5qVXdNelkzTnpNMk9ERTJOREEyZlElM0QlM0Qmd2VhZGVncmVldHlwZT1DJm9jaWQ9d2lucDF0YXNrYmFyJmN2aWQ9ODQzYWQxZDQ5ZWRhNGE2ODk5NzFmZDc0ZjEyOGU5NTgNCiAgcmlsaT1odHRwczovL3d3dy5iYWlkdS5jb20vcz9pZT11dGYtOCZmPTgmcnN2X2JwPTEmcnN2X2lkeD0xJnRuPWJhaWR1JndkPSVFNiU5NyVBNSVFNSU4RSU4NiZmZW5sZWk9MjU2JnJzdl9wcT04ODQzMDAwNTAwMDNiZjdhJnJzdl90PTg1NzNsNnYwRU03MkpkaExZVGdtQ0NFJTJCb1NLZDMzSXZxakxENG5UeTd2RjFCMEklMkZRWm5KaUZreXRIWSZycWxhbmc9Y24mcnN2X2VudGVyPTEmcnN2X2RsPWliJnJzdl9zdWczPTExJnJzdl9zdWcxPTkmcnN2X3N1Zzc9MTAwJnJzdl9zdWcyPTAmcnN2X2J0eXBlPWkmaW5wdXRUPTIyOTUmcnN2X3N1ZzQ9MjI5NQ0KICBiaW5nPWh0dHBzOi8vY24uYmluZy5jb20vDQogIGh1eWE9aHR0cHM6Ly93d3cuaHV5YS5jb20vNTE2MjgzDQogIHB5dGhvbmpjPWh0dHBzOi8vd3d3LmxpYW94dWVmZW5nLmNvbS93aWtpLzEwMTY5NTk2NjM2MDI0MDAvMTAxNjk1OTczNTYyMDQ0OA0KICBiaWxpYmlsaT1odHRwczovL3d3dy5iaWxpYmlsaS5jb20vDQogIHR4eT1odHRwczovL2Nsb3VkLnRlbmNlbnQuY29tLz9mcm9tU291cmNlPWd3emN3LjIyMTIxMjcuMjIxMjEyNy4yMjEyMTI3JnV0bV9tZWRpdW09Y3BkJnV0bV9pZD1nd3pjdy4yMjEyMTI3LjIyMTIxMjcuMjIxMjEyNw0KICBhY2c9aHR0cHM6Ly93d3cuODU3ZG0uY29tL3BsYXkvNDcyMS0xLTEuaHRtbA0KICB6aGlodT1odHRwczovL3d3dy56aGlodS5jb20vDQogIGxhb2xpPWh0dHBzOi8vd3d3Lmh1eWEuY29tL2phbWJlDQogIHdsY3M9aHR0cHM6Ly93d3cuc3BlZWR0ZXN0LmNuLw0KICB0b2Rlc2s9dG9kZXNrDQogIHhocz1odHRwczovL3d3dy54aWFvaG9uZ3NodS5jb20vZXhwbG9yZQ0KICB3bmw9aHR0cHM6Ly93d3cuYmFpZHUuY29tL3M/d2Q9JUU0JUI4JTg3JUU1JUI5JUI0JUU1JThFJTg2JnJzdl9zcHQ9MSZyc3ZfaXFpZD0weGU4Yjc5YWMzMDAwZTA4MWImaXNzcD0xJmY9OCZyc3ZfYnA9MSZyc3ZfaWR4PTImaWU9dXRmLTgmdG49YmFpZHVob21lX3BnJnJzdl9kbD10YiZyc3ZfZW50ZXI9MSZyc3Zfc3VnMz0xMiZyc3Zfc3VnMT01JnJzdl9zdWc3PTEwMCZyc3Zfc3VnMj0wJnJzdl9idHlwZT1pJnByZWZpeHN1Zz0lMjVFNCUyNUI4JTI1ODclMjVFNSUyNUI5JTI1QjQlMjVFNSUyNThFJTI1ODYmcnNwPTUmaW5wdXRUPTI4MDUmcnN2X3N1ZzQ9MjgwNg0KICBkeT1odHRwczovL3d3dy5kb3V5aW4uY29tLw0KICB3Yj1odHRwczovL3dlaWJvLmNvbS8/c3VkYXJlZj1zZWN1cml0eS53ZWliby5jb20NCiAgb3BlbmFpPWh0dHBzOi8vb3BlbmFpLmNvbS9ibG9nL2NoYXRncHQvDQogIGNoYXRncHQ9aHR0cHM6Ly9vcGVuYWkuY29tL2Jsb2cvY2hhdGdwdC8NCiAgYWk9aHR0cHM6Ly9jaGF0Lm9wZW5haS5jb20vDQogIGFpMj1odHRwczovL3d3dy5iaW5nLmNvbS9zZWFyY2g/cT1CaW5nK0FJJnNob3djb252PTEmRk9STT1ocGNvZHgNCiAgZ2l0aHViPWh0dHBzOi8vZ2l0aHViLmNvbS8NCiAgc2dmeT1odHRwczovL2ZhbnlpLnNvZ291LmNvbS90ZXh0DQogIGdnPWh0dHBzOi8vd3d3Lmdvb2dsZS5jb20vDQogIGdnY2o9Y2hyb21lOi8vZXh0ZW5zaW9ucy8NCiAgZ2dzZD1odHRwczovL2Nocm9tZS5nb29nbGUuY29tL3dlYnN0b3JlL2NhdGVnb3J5L2V4dGVuc2lvbnM/dXRtX3NvdXJjZT1leHRfc2lkZWJhciZobD16aC1DTg0KICB5b3VrdT1odHRwczovL3d3dy55b3VrdS5jb20vDQogIGFseT1odHRwczovL3d3dy5hbGl5dW4uY29tLw0KICB5dGI9aHR0cHM6Ly93d3cueW91dHViZS5jb20vDQogIHlvdXR1YmU9aHR0cHM6Ly93d3cueW91dHViZS5jb20vDQogIHR0PWh0dHBzOi8vdHdpdHRlci5jb20vaG9tZQ0KICB4PWh0dHBzOi8vdHdpdHRlci5jb20vaG9tZQ0KICBiZHk9aHR0cHM6Ly9jbG91ZC5iYWlkdS5jb20vDQogIGFoaz1odHRwczovL3d3dy5hdXRvYWhrLmNvbS8NCiAgaHd5PWh0dHBzOi8vYWN0aXZpdHkuaHVhd2VpY2xvdWQuY29tLw0KICBqc3k9aHR0cHM6Ly93d3cua3N5dW4uY29tLw0KICBnZG1hcD1odHRwczovL3d3dy5hbWFwLmNvbS8NCiAgdHlxdz1odHRwczovL3Rvbmd5aS5hbGl5dW4uY29tL3FpYW53ZW4/c3BtPTUxNzYuMjgzMjY1OTEuMC4wLjQwZjczZGEybUl6WENPDQogIHR5d3g9aHR0cHM6Ly90b25neWkuYWxpeXVuLmNvbS93YW54aWFuZy9jcmVhdGlvbg0KICBnZ21hcD1odHRwczovL3d3dy5nb29nbGUuY29tL21hcHMNCiAgZ2dkdD1odHRwczovL3d3dy5nb29nbGUuY29tL21hcHMNCiAgZ2dlYXJ0aD1odHRwczovL2VhcnRoLmdvb2dsZS5jb20vDQogIGdnYmFsbD1odHRwczovL2VhcnRoLmdvb2dsZS5jb20vDQogIGdnZHE9aHR0cHM6Ly9lYXJ0aC5nb29nbGUuY29tLw0KICB5YW5kZXg9aHR0cHM6Ly95YW5kZXguY29tL2ltYWdlcy8NCiAgI3d4eXk9aHR0cHM6Ly95aXlhbi5iYWlkdS5jb20vDQogIHRpZWJhPWh0dHBzOi8vdGllYmEuYmFpZHUuY29tLw0KICBib3NzPWh0dHBzOi8vd3d3LnpoaXBpbi5jb20vY2hlbmdkdS8NCiAgYmFyZD1odHRwczovL2JhcmQuZ29vZ2xlLmNvbS9jaGF0DQogIGNsYXVkZT1odHRwczovL2NsYXVkZS5haS9jaGF0LzcyYTU3NzU3LTVlNWEtNDZlNy1iZmY0LTY1Mzg0NjUyNTIzMg0KICBjbGF1ZGUyPWh0dHBzOi8vY2xhdWRlLmFpL2NoYXRzDQogIHJ1bm9ubGluZT1odHRwczovL3Rvb2wubHUvY29kZXJ1bm5lci8NCiAgenhkbT1odHRwczovL3Rvb2wubHUvY29kZXJ1bm5lci8NCiAgc21zPWh0dHBzOi8vc21zLWFjdGl2YXRlLm9yZy9jbg0KICBhaGt2Mj1odHRwczovL3d5YWdkMDAxLmdpdGh1Yi5pby92Mi9kb2NzLw0KICBhaGt2MT1odHRwOi8vYWhrY24uc291cmNlZm9yZ2UubmV0L2RvY3MvQXV0b0hvdGtleS5odG0NCiAgaHV5YT1odHRwczovL3d3dy5odXlhLmNvbS81MTYyODMNCiAgYWhrbHQ9aHR0cHM6Ly93d3cuYXV0b2hvdGtleS5jb20vYm9hcmRzLw0KICBnaXRlZT1odHRwczovL2dpdGVlLmNvbS8NCiAgd3Jndz1odHRwczovL3d3dy5taWNyb3NvZnQuY29tL3poLWNuDQogIGFxeTI9aHR0cHM6Ly93d3cuaXFpeWkuY29tLw0KICBpdGVsbHlvdT1odHRwczovL21zZG4uaXRlbGx5b3UuY24vDQogIG1zZG49aHR0cHM6Ly9tc2RuLml0ZWxseW91LmNuLw0KICBiaWFuPWh0dHA6Ly9tLm5ldGJpYW4uY29tL2JpemhpZGFxdWFuLw0KICBhZ2U9aHR0cHM6Ly93d3cuYWdlZG0ub3JnLw0KICBzdGFja292ZXJmbG93PWh0dHBzOi8vc3RhY2tvdmVyZmxvdy5jb20vDQogIGdwdDQ9aHR0cHM6Ly93d3cuNDM5OWFpLmNuLz9tb2RlbD1ncHQtNA0KICBpcHc9aHR0cHM6Ly9pcHcuY24vDQogIGlwdjZ0ZXN0PWh0dHBzOi8vd3d3LnRlc3QtaXB2Ni5jb20vDQogIG1hdmVucmVwb3NpdG9yeT1odHRwczovL212bnJlcG9zaXRvcnkuY29tLw0KICBtcmVwbz1odHRwczovL212bnJlcG9zaXRvcnkuY29tLw0KICBhbGlzdD1odHRwczovL2FsaXN0Lm5uLmNpL3poL2d1aWRlL2luc3RhbGwvc2NyaXB0Lmh0bWwjJUU1JUFFJTg5JUU4JUEzJTg1DQogIHl1cXVlPWh0dHBzOi8vd3d3Lnl1cXVlLmNvbS9kYXNoYm9hcmQNCiAgaWNvbjg9aHR0cHM6Ly9pY29uczguY29tL2ljb25zL3NldC9vd2wNCiAgbmt3PWh0dHBzOi8vd3d3Lm5vd2NvZGVyLmNvbS8NCiAgbWVkaWFGaXJlPWh0dHBzOi8vYXBwLm1lZGlhZmlyZS5jb20vNnp2NmJyZ2lhdDVxOA0KICB6bHpwPWh0dHBzOi8vaS56aGFvcGluLmNvbS8NCiAgemhpbGlhbj1odHRwczovL2kuemhhb3Bpbi5jb20vDQogIGxhZ291PWh0dHBzOi8vd3d3LmxhZ291LmNvbS93bi8NCiAgcWN3eT1odHRwczovL3d3dy41MWpvYi5jb20vDQogIDUxam9iPWh0dHBzOi8vd3d3LjUxam9iLmNvbS8NCiAgeHh3PWh0dHBzOi8vd3d3LmNoc2kuY29tLmNuLw0KICBncm9rPWh0dHBzOi8vZ3Jvay54LmFpLw0KICBnb2pjPWh0dHBzOi8vd3d3LnJ1bm9vYi5jb20vZ28vZ28taWRlLmh0bWwNCiAgZG16cz1odHRwczovL3Rvb2wub3NjaGluYS5uZXQvaGlnaGxpZ2h0DQogIGRtZ2w9aHR0cHM6Ly90b29sLm9zY2hpbmEubmV0L2hpZ2hsaWdodA0KICB0eHNwMj1odHRwczovL3YucXEuY29tLw0KICBzcGVlZHRlc3Q9aHR0cHM6Ly93d3cuc3BlZWR0ZXN0LmNuLw0KICBjc3c9aHR0cHM6Ly90ZXN0LnVzdGMuZWR1LmNuLw0KICBjc3cyPWh0dHBzOi8vd3d3LnNwZWVkdGVzdC5jbi8NCiAgd3Njcz1odHRwczovL3d3dy5zcGVlZHRlc3QuY24vDQogIHdsY3M9aHR0cHM6Ly93d3cuc3BlZWR0ZXN0LmNuLw0KICBrdD1odHRwczovL3JlbW92ZS5waG90b3MvDQogIGdqbGQ9aHR0cHM6Ly9jbG91ZC5zaWxpY29uZmxvdy5jbi9tZS9tb2RlbHMNCiAgcWRyYW50PWh0dHA6Ly9sb2NhbGhvc3Q6NjMzMy9kYXNoYm9hcmQjL2NvbGxlY3Rpb25zDQogIGNzdzI9aHR0cDovL3NwZWVkLnNjLmNoaW5hbW9iaWxlLmNvbS9zcGVlZHRlc3QvcGRhLmh0bWwjL3NwZWVkVGVzdA0KDQoNCiMjIyMjIyMjIyMjI+OAkOW3peS9nOe9keWdgOOAkQ0KICBjYXRhbG9nPWh0dHBzOi8vYml0YnVja2V0Lm9yZy9hZGhvY21vbnN0ZXIvY2F0YWxvZy1ncnBjL2NvbW1pdHMvYnJhbmNoL21haW4NCiAgdHJhbnM9aHR0cHM6Ly9iaXRidWNrZXQub3JnL2FkaG9jbW9uc3Rlci9jYXRhbG9nLXRyYW5zLWdycGMvY29tbWl0cy9icmFuY2gvbWFpbg0KICB0b2FzdD1odHRwczovL2JpdGJ1Y2tldC5vcmcvYWRob2Ntb25zdGVyL3RvYXN0LWdycGMvY29tbWl0cy9icmFuY2gvbWFpbg0KICBtY2FwaT1odHRwczovL2JpdGJ1Y2tldC5vcmcvYWRob2Ntb25zdGVyL21lcmNoYW50LXBvcnRhbC1hcGkvY29tbWl0cy9icmFuY2gvbWFpbg0KICBhbGxvZz1odHRwczovL3Nscy5jb25zb2xlLmFsaXl1bi5jb20vbG9nbmV4dC9wcm9qZWN0L2luZmktc3RhZ2luZy1iYWNrZW5kLWxvZ3MvbG9nc2VhcmNoL3N0YWdpbmctY29tbW9uLWxvZ3M/c2xzUmVnaW9uPXVzLXdlc3QtMQ0KICBhbHJ6PWh0dHBzOi8vc2xzLmNvbnNvbGUuYWxpeXVuLmNvbS9sb2duZXh0L3Byb2plY3QvaW5maS1zdGFnaW5nLWJhY2tlbmQtbG9ncy9sb2dzZWFyY2gvY2F0YWxvZy1ncnBjDQogIGZid2Q9aHR0cHM6Ly9kb2NzLmdvb2dsZS5jb20vc3ByZWFkc2hlZXRzL2QvMTlXekhWSW1GVl9qVktFbFpLczFvSlNPZ1EyZkhzbzdOX2xuMjFxMS02ZEEvZWRpdD9naWQ9MCNnaWQ9MA0KICBnbWFpbD1odHRwczovL21haWwuZ29vZ2xlLmNvbS9tYWlsL3UvMC8jaW5ib3gNCiAgbWM9aHR0cHM6Ly9zdGFnaW5nLm9yZGVyd2l0aGluZmkuY29tL21lcmNoYW50LXBvcnRhbC9tYWluL2xpYnJhcnkvaXRlbQ0KICBtY3N0YWdlPWh0dHBzOi8vc3RhZ2Uub3JkZXJ3aXRoaW5maS5jb20vbWVyY2hhbnQtcG9ydGFsL2F1dGgvc2lnbi1pbg0KICBtY3Byb2Q9aHR0cHM6Ly9wcm9kLm9yZGVyd2l0aGluZmkuY29tL21lcmNoYW50LXBvcnRhbC9tYWluL2xpYnJhcnkvaXRlbQ0KICBvYz1odHRwczovL3N0YWdpbmcub3JkZXJ3aXRoaW5maS5jb20vb3BlcmF0aW9uLXBvcnRhbC9tYWluL21lcmNoYW50DQogIG9jMj1odHRwczovL3Byb2Qub3JkZXJ3aXRoaW5maS5jb20vb3BlcmF0aW9uLXBvcnRhbC9hdXRoL3NpZ24taW4NCiAgb2Nwcm9kPWh0dHBzOi8vcHJvZC5vcmRlcndpdGhpbmZpLmNvbS9vcGVyYXRpb24tcG9ydGFsL2F1dGgvc2lnbi1pbg0KICB0b2FzdGxvZz1odHRwczovL3NhbmRib3guZW5nLnRvYXN0dGFiLmNvbS9yZXN0YXVyYW50cy9hZG1pbi9ob21lDQogIHRvYXN0bG9naW49aHR0cHM6Ly9zYW5kYm94LmVuZy50b2FzdHRhYi5jb20vcmVzdGF1cmFudHMvYWRtaW4vaG9tZQ0KICB0b2FzdGRldj1odHRwczovL2RvYy50b2FzdHRhYi5jb20vZG9jL2Rldmd1aWRlL2luZGV4Lmh0bWwNCiAgamlyYT1odHRwczovL2luZmluZXRsbGMuYXRsYXNzaWFuLm5ldC9qaXJhL3NvZnR3YXJlL2MvcHJvamVjdHMvU1MvYm9hcmRzLzUzL3RpbWVsaW5lDQogIHh6d2Q9aHR0cHM6Ly9kb2NzLmdvb2dsZS5jb20vc3ByZWFkc2hlZXRzL2QvMU1RX2dLUG9FSUhmMWI1UDIxeXFDRFJMMlR0bEhUd19BOHRTRGFSNjVHMmcvZWRpdD9naWQ9MCNnaWQ9MA0KICBzc2ZhbnlpPWh0dHBzOi8vd3d3LmV2ZW50Y2F0LmNvbS9tZWV0aW5ncy9mMmI4MjYyZC04MTcwLTRkMTYtYjU0ZS04MjY2MzY4NzkwOGY/dXRtX3NvdXJjZT16b29tJnV0bV9tZWRpdW09Y2hhdA0KICBkYXRhY2VudGVyPWh0dHBzOi8vYml0YnVja2V0Lm9yZy9hZGhvY21vbnN0ZXIvZGF0YS1jZW50ZXItZ3JwYy9jb21taXRzL2JyYW5jaC9tYWluDQogIGNzeWw9aHR0cHM6Ly9pbmZpbmV0bGxjLmF0bGFzc2lhbi5uZXQvYnJvd3NlL1NTLTM0MQ0KICBsaWdodHNwZWVkYXBpPWh0dHBzOi8vYXBpLWRvY3MubHNrLmxpZ2h0c3BlZWQuYXBwLw0KICBsaWdodHNwZWVkd2Q9aHR0cHM6Ly9pbmZpbmV0bGxjLmF0bGFzc2lhbi5uZXQvd2lraS9zcGFjZXMvU09TMi9wYWdlcy8yNTc2NTE1MTA1L0xpZ2h0c3BlZWQrSU5GSStNQytBY2NvdW50K01hdGNoaW5nK0luZm9ybWF0aW9uDQogIGxpZ2h0c3BlZWRkb2M9aHR0cHM6Ly9pbmZpbmV0bGxjLmF0bGFzc2lhbi5uZXQvd2lraS9zcGFjZXMvU09TMi9wYWdlcy8yNTc2NTE1MTA1L0xpZ2h0c3BlZWQrSU5GSStNQytBY2NvdW50K01hdGNoaW5nK0luZm9ybWF0aW9uDQogIGxpZ2h0c3BlZWRsb2dpbj1odHRwczovL21hbmFnZXIudHJpYWwubHNrLmxpZ2h0c3BlZWQuYXBwLw0KICBsc2xvZ2luPWh0dHBzOi8vbWFuYWdlci50cmlhbC5sc2subGlnaHRzcGVlZC5hcHAvDQogIGxpZ2h0c3BlZWRsb2dpbnByb2Q9aHR0cHM6Ly9tYW5hZ2VyLmxzay5saWdodHNwZWVkLmFwcC8NCiAgbGlnaHRzcGVlZD1odHRwczovL2JpdGJ1Y2tldC5vcmcvYWRob2Ntb25zdGVyL2xpZ2h0c3BlZWQtZ3JwYy9jb21taXRzL2JyYW5jaC9tYWluDQogIHFhdGFibGU9aHR0cHM6Ly9pbmZpbmV0bGxjLmF0bGFzc2lhbi5uZXQvYnJvd3NlL1NTLTExODcNCiAgc2p6aD1odHRwczovL2RvY3MuZ29vZ2xlLmNvbS9zcHJlYWRzaGVldHMvdS8xL2QvMURMR0pScl9kQnJNM3BLTEgweGppQkx0LTM0NVpQUjc4c1Z6ckU4UTR2bEUvaHRtbHZpZXcNCiAgeWh6aD1odHRwczovL2RvY3MuZ29vZ2xlLmNvbS9zcHJlYWRzaGVldHMvdS8xL2QvMURMR0pScl9kQnJNM3BLTEgweGppQkx0LTM0NVpQUjc4c1Z6ckU4UTR2bEUvaHRtbHZpZXcjZ2lkPTE1MjEzNzQ3Mw0KICBhbGxvZ3Byb2Q9aHR0cHM6Ly9zbHMuY29uc29sZS5hbGl5dW4uY29tL2xvZ25leHQvcHJvamVjdC9pbmZpLXByb2QtYmFja2VuZC1sb2dzL2xvZ3NlYXJjaC9wcm9kLWNvbW1vbi1sb2dzP3Nsc1JlZ2lvbj11cy13ZXN0LTENCiAgYWxsb2dkZXY9aHR0cHM6Ly9zbHMuY29uc29sZS5hbGl5dW4uY29tL2xvZ25leHQvcHJvamVjdC9pbmZpLWRldi1iYWNrZW5kLWxvZ3MvbG9nc2VhcmNoL2Rldi1jb21tb24tbG9ncz9zbHNSZWdpb249dXMtd2VzdC0xDQogIHpkaGNzPWh0dHBzOi8vc3FsLXNjcmlwdC1kZXBvbHkudmVyY2VsLmFwcC8NCiAgYXV0b3Rlc3Q9aHR0cHM6Ly9zcWwtc2NyaXB0LWRlcG9seS52ZXJjZWwuYXBwLw0KICBsaWdodHNwZWVkcHJvZExvZ2luPWh0dHBzOi8vbWFuYWdlci5sc2subGlnaHRzcGVlZC5hcHAvDQogIHBqcGQ9aHR0cHM6Ly9pbmZpbmV0bGxjLmF0bGFzc2lhbi5uZXQvd2lraS9zcGFjZXMvRFQvcGFnZXMvMjc1NTc4ODg1OA0KICB0b2FzdGxvZ2lucHJvZD1odHRwczovL3d3dy50b2FzdHRhYi5jb20vcmVzdGF1cmFudHMvYWRtaW4vaG9tZQ0KICBsaWdodHNwZWVkd2ViaG9vaz1odHRwczovL2JpdGJ1Y2tldC5vcmcvYWRob2Ntb25zdGVyL2xpZ2h0c3BlZWQtd2ViaG9vay1hcGkvY29tbWl0cy9icmFuY2gvbWFpbg0KICBvY2FwaT1odHRwczovL2JpdGJ1Y2tldC5vcmcvYWRob2Ntb25zdGVyL29wZXJhdGlvbi1wb3J0YWwtYXBpL2NvbW1pdHMvYnJhbmNoL21haW4NCiAgbWl4cGFuZWw9aHR0cHM6Ly9taXhwYW5lbC5jb20vcHJvamVjdC8zNjYyNzQwL3ZpZXcvNDE2MTQ3Ni9hcHAvZXZlbnRzDQogIG9yZGVyZ3ByYz1odHRwczovL2JpdGJ1Y2tldC5vcmcvYWRob2Ntb25zdGVyL29yZGVyLWdycGMvY29tbWl0cy9icmFuY2gvbWFpbg0KICB3emJ6PWh0dHBzOi8vcGNiei5pd3p3aC5jb20vIy9ob21lL2luZGV4DQogIGV2ZW50Y2F0PWh0dHBzOi8vYXBwLmV2ZW50Y2F0LmNvbS9kYXNoYm9hcmQvbWVldGluZ3Mvd2l6YXJkDQogIGNsb3ZlcnByZD1odHRwczovL2luZmluZXRsbGMuYXRsYXNzaWFuLm5ldC93aWtpL3NwYWNlcy9TT1MyL3BhZ2VzLzI4Mjc5NzY3MDgvQ2xvdmVyK0RldmVsb2VyK0RvY3VtZW50cw0KICBjbG92ZXJhcGk9aHR0cHM6Ly9kb2NzLmNsb3Zlci5jb20vZGV2L3JlZmVyZW5jZS9hcGktcmVmZXJlbmNlLW92ZXJ2aWV3DQogIGNsb3ZlcmxvZ2luPWh0dHBzOi8vd3d3LmNsb3Zlci5jb20vZ2xvYmFsLWRldmVsb3Blci1ob21lL05BL3NiL2Rhc2hib2FyZC90bWMNCiAgbWNncnBjPWh0dHBzOi8vYml0YnVja2V0Lm9yZy9hZGhvY21vbnN0ZXIvbWVyY2hhbnQtcG9ydGFsLWdycGMvY29tbWl0cy9icmFuY2gvbWFpbg0KICBsc3dlYmhvb2thcGk9aHR0cHM6Ly9iaXRidWNrZXQub3JnL2FkaG9jbW9uc3Rlci9saWdodHNwZWVkLXdlYmhvb2stYXBpL2NvbW1pdHMvYnJhbmNoL21haW4NCiAgY2xvdmVyPWh0dHBzOi8vYml0YnVja2V0Lm9yZy9hZGhvY21vbnN0ZXIvY2xvdmVyLWdycGMvY29tbWl0cy9icmFuY2gvbWFpbg0KICB0b2FzdGFwaSA9aHR0cHM6Ly9kb2MudG9hc3R0YWIuY29tL29wZW5hcGkvbWVudXN2My9vdmVydmlldy8NCiAgY3Vyc29yTG9naW49aHR0cHM6Ly9jdXJzb3IuY29tL2NuL2Rhc2hib2FyZC91c2FnZQ0KICBvbmxpbmU9aHR0cHM6Ly90ZXN0My5vcmRlci5pbmZpLnVzLz9tPXRlc3QwMDENCiAgb25saW5lUHJvZD1odHRwczovL3Rlc3Q0Lm9yZGVyLmluZmkudXMvP209cWFfMDAxDQogIGNsb3ZlcnBhc3M9aHR0cHM6Ly9zaGFyZS4xcGFzc3dvcmQuY29tL3MjZlRfLWtxeXppZ25ZRkRfUFlCOG1PSjctSnd6bTNOYktQdnVnNDFPSWZzTQ0KICBkcmF3PWh0dHBzOi8vZXhjYWxpZHJhdy5jb20vDQogIGNsb3ZlcnByZD1odHRwczovL2luZmluZXRsbGMuYXRsYXNzaWFuLm5ldC93aWtpL3NwYWNlcy9TT1MyL3BhZ2VzLzI4Mzg1MjgwMDcvQ2xvdmVyKy0rTGlicmFyeQ0KICBhbGppcXVuPWh0dHBzOi8vY3NuZXcuY29uc29sZS5hbGl5dW4uY29tLz9zcG09NTE3Ni4xMjgxODA5My5jb25zb2xlLWJhc2Vfc2VhcmNoLXBhbmVsLmR0YWItcHJvZHVjdF9hc2suM2EyNDE2ZDBrYnM4am0jL2s4cy9jbHVzdGVyL2xpc3Q/cmVnaW9uPXVzLXdlc3QtMQ0KICBtY2Rldj1odHRwczovL2Rldi5vcmRlcndpdGhpbmZpLmNvbS9tZXJjaGFudC1wb3J0YWwvbWFpbi9zZXR0aW5ncy9hY2NvdW50DQogIG9jZGV2PWh0dHBzOi8vZGV2Lm9yZGVyd2l0aGluZmkuY29tL29wZXJhdGlvbi1wb3J0YWwvYXV0aC9zaWduLWluDQogIGdlbWluaT1odHRwczovL2dlbWluaS5nb29nbGUuY29tL2FwcA0KICBtZXJtYWlkPWh0dHBzOi8vd3d3Lm1lcm1haWRjaGFydC5jb20vYXBwL3Byb2plY3RzL2ZmMGU4ODI2LTA2NTYtNDVhOS1hODQxLTIxNGFhZDc0YThhNy9kaWFncmFtcy9kNGUyNmY2My1kYzFiLTQ0MGQtOWY1OC00N2RlN2MzMTM4M2MvdmVyc2lvbi92MC4xL2VkaXQNCiAgZ29vZ2xlcmlsaT1odHRwczovL2NhbGVuZGFyLmdvb2dsZS5jb20vY2FsZW5kYXIvdS8wL3IvbW9udGgvMjAyNS8xMi8xP2NpZD1ZMTgwWVRGbU5EazJaVEptTkRnNU16YzVOakl6TUdNME5EWm1ZVGc0WVRrME5UQmlNamszT1RFek9XWXdNamczTUdFMk1XTTVZV015TnpNMk56SmtNbVkwUUdkeWIzVndMbU5oYkdWdVpHRnlMbWR2YjJkc1pTNWpiMjANCiAgZ2dyaWxpPWh0dHBzOi8vY2FsZW5kYXIuZ29vZ2xlLmNvbS9jYWxlbmRhci91LzAvci9tb250aC8yMDI1LzEyLzE/Y2lkPVkxODBZVEZtTkRrMlpUSm1ORGc1TXpjNU5qSXpNR00wTkRabVlUZzRZVGswTlRCaU1qazNPVEV6T1dZd01qZzNNR0UyTVdNNVlXTXlOek0yTnpKa01tWTBRR2R5YjNWd0xtTmhiR1Z1WkdGeUxtZHZiMmRzWlM1amIyMA0KICBzcXVhcmVidWc9aHR0cHM6Ly9pbmZpbmV0bGxjLmF0bGFzc2lhbi5uZXQvYnJvd3NlL1NTLTQ1MzENCiAgdG9hc3RwcmQ9aHR0cHM6Ly9pbmZpbmV0bGxjLmF0bGFzc2lhbi5uZXQvd2lraS9zcGFjZXMvU09TMi9wYWdlcy8yNTYyMDY0Mzk4L1RvYXN0Ky0rTWVudQ0KICBraW9za2Fwaz1odHRwczovL2RyaXZlLmdvb2dsZS5jb20vZHJpdmUvZm9sZGVycy8xMjJBM1dqVDg5ME1jQ2o2cGR4a1o0VHJtTmVaQ1ViOFgNCiAgb3JkZXI9aHR0cHM6Ly9iaXRidWNrZXQub3JnL2FkaG9jbW9uc3Rlci9vcmRlci1ncnBjL2NvbW1pdHMvYnJhbmNoL21haW4NCiAgYWljb2RlPWh0dHBzOi8vY2xhdWRlLmFpL2NoYXQvNGQ2Yzc2NTYtYzZkMy00MmU2LTkxZTMtNmY4OGVlYjQ1ZjE2P29uYm9hcmRpbmc9MQ0KICBzbWFydG1lbnU9aHR0cHM6Ly9kb2NzLmdvb2dsZS5jb20vZG9jdW1lbnQvZC8xRnJZNnoxajdMNXJGMzdDZzUxMmNucjJrdVc1S0Z2VlhXU3NZUUdqaG1Gay9lZGl0P3RhYj10LjAjaGVhZGluZz1oLnl4cm5lZjF1a2hpOQ0KDQogICMjc3F1YXJlIA0KICBzcXVhcmVsb2dpbj1odHRwczovL2FwcC5zcXVhcmV1cC5jb20vZGFzaGJvYXJkDQogIHNxdWFyZT1odHRwczovL2JpdGJ1Y2tldC5vcmcvYWRob2Ntb25zdGVyL3NxdWFyZS1ncnBjL2NvbW1pdHMvYnJhbmNoL21haW4NCiAgc3F1YXJlYXBpPWh0dHBzOi8vZGV2ZWxvcGVyLnNxdWFyZXVwLmNvbS9leHBsb3Jlci9zcXVhcmUvY2F0YWxvZy1hcGkvbGlzdC1jYXRhbG9nDQogIHNxdWFyZWx0PWh0dHBzOi8vYXBwLnNxdWFyZXVwLmNvbS9oZWxwL3VzL2VuL2NvbnRhY3Q/cGFuZWw9QkY1M0E5QzhFRjY4DQogIHNxdWFyZWhlbHA9aHR0cHM6Ly9zcXVhcmV1cC5jb20vaGVscC91cy9lbg0KICBzcXVhcmVwcmQ9aHR0cHM6Ly9pbmZpbmV0bGxjLmF0bGFzc2lhbi5uZXQvd2lraS9zcGFjZXMvU09TMi9wYWdlcy8yMjUyMjEwMTgwL1NxdWFyZSstK01lbnUNCg0KICAjI2h1bmdlcnJ1c2gNCiAgaHJwcmQ9aHR0cHM6Ly9pbmZpbmV0bGxjLmF0bGFzc2lhbi5uZXQvd2lraS9zcGFjZXMvU09TMi9wYWdlcy8yOTM2MTExMTEzL0hSKy0rTWVudStEcmFmdA0KICBocmxvZ2luPWh0dHBzOi8vaHViLmh1bmdlcnJ1c2guY29tLw0KICBodW5nZXJydXNoPWh0dHBzOi8vYml0YnVja2V0Lm9yZy9hZGhvY21vbnN0ZXIvaHVuZ2VycnVzaC1ncnBjL2NvbW1pdHMvYnJhbmNoL21haW4NCiAgaHJwYz1odHRwczovL215LnNwbGFzaHRvcC5jb20vY29tcHV0ZXJzDQogIGhyaGVscD1odHRwczovL3N1cHBvcnQuaHVuZ2VycnVzaC5jb20vaGMvZW4tdXMvc2VjdGlvbnMvMjUzNTEwMDc3NjY3OTctUHJvZHVjdC1Eb2N1bWVudGF0aW9uDQogIGhyb25saW5lPWh0dHBzOi8vaW5maWRlbW8uaHVuZ2VycnVzaC5jb20vT3JkZXIvTWVudS8xI2dyb3Vwcw0KICBkcmF3aW89aHR0cHM6Ly9hcHAuZGlhZ3JhbXMubmV0LyNMJUU2JTg5JTgwJUU2JTlDJTg5JUU3JUJCJTk4JUU1JTlCJUJFLmRyYXdpbyMlN0IlMjJwYWdlSWQlMjIlM0ElMjJGWjh0Tkp5YnRWb1VfVkVrYnY0MSUyMiU3RA0KDQogIGM0bW9kZWw9aHR0cHM6Ly9hcHAuaWNlcGFuZWwuaW8vdXNlci9sb2dpbg0KICBtZXJtYWlkPWh0dHBzOi8vbWVybWFpZC5qcy5vcmcvDQpwcnByZD1odHRwczovL2luZmluZXRsbGMuYXRsYXNzaWFuLm5ldC93aWtpL3NwYWNlcy90ZWFtODI5MjBlMjhkNTZkNGFmZmJmYWMyMWE0NjNhNDQzOGEvcGFnZXMvMzM0NTkwNzc0MS9Db2RlK1JldmlldytQUitTdGFuZGFyZHMNCmxzcHJkPWh0dHBzOi8vaW5maW5ldGxsYy5hdGxhc3NpYW4ubmV0L3dpa2kvc3BhY2VzL1NPUzIvcGFnZXMvMjA2Njc3NjA2NS9MaWdodFNwZWVkK1BPUytJbnRlZ3JhdGlvbiMyLjMtTWVudS1FZGl0aW5nLUNvbnN0cmFpbnRzDQppbmZpc3RhZ2U9aHR0cHM6Ly9jcy5jb25zb2xlLmFsaWJhYmFjbG91ZC5jb20vP3NwbT01MTc2LjEyODE4MDkzXzQ3LnJlc291cmNlQ2VudGVyLjEuMWZkNDJjYzlBU0o3cE0jL2s4cy9jbHVzdGVyL2NlZjhiMDNjNjkwYzA0MjY0ODcwZTkzMzE3MGM2MTA3YS92Mi93b3JrbG9hZC9wb2QvbGlzdD90eXBlPXBvZCZjbHVzdGVyVHlwZT1NYW5hZ2VkS3ViZXJuZXRlcyZwcm9maWxlPURlZmF1bHQmc3RhdGU9cnVubmluZyZyZWdpb249dXMtd2VzdC0xJm5zPXN0YWdpbmcNCmluZmlwcm9kPWh0dHBzOi8vY3MuY29uc29sZS5hbGliYWJhY2xvdWQuY29tLz9zcG09NTE3Ni4xMjgxODA5M180Ny5yZXNvdXJjZUNlbnRlci4xLjFmZDQyY2M5QVNKN3BNIy9rOHMvY2x1c3Rlci9jNWQ1MWUxNmI2M2M5NDVkNmEyMWNlZmYyNzJkN2M5ODIvdjIvd29ya2xvYWQvcG9kL2xpc3Q/dHlwZT1wb2QmY2x1c3RlclR5cGU9TWFuYWdlZEt1YmVybmV0ZXMmcHJvZmlsZT1EZWZhdWx0JnN0YXRlPXJ1bm5pbmcmcmVnaW9uPXVzLXdlc3QtMSZucz1wcm9kDQppbmZpZGV2PWh0dHBzOi8vY3MuY29uc29sZS5hbGliYWJhY2xvdWQuY29tLz9zcG09NTE3Ni4xMjgxODA5M180Ny5yZXNvdXJjZUNlbnRlci4xLjFmZDQyY2M5QVNKN3BNIy9rOHMvY2x1c3Rlci9jZTRmZGE3OWNiODQ5NGRkYmFiMWIyOWI2M2QwZjc1YjUvdjIvd29ya2xvYWQvcG9kL2xpc3Q/dHlwZT1wb2QmY2x1c3RlclR5cGU9TWFuYWdlZEt1YmVybmV0ZXMmcHJvZmlsZT1EZWZhdWx0JnN0YXRlPXJ1bm5pbmcmcmVnaW9uPXVzLXdlc3QtMSZucz1kZXYNCmluZmlzdGFnaW5nPWh0dHBzOi8vY3MuY29uc29sZS5hbGliYWJhY2xvdWQuY29tLz9zcG09NTE3Ni4xMjgxODA5M180Ny5jb25zb2xlLWJhc2VfcHJvZHVjdC1kcmF3ZXItcmlnaHQuZGNzay5iZjI2N2I2Yjg5NWYxbyMvazhzL2NsdXN0ZXIvY2IyYTQwMWEyMzhhMTQ2OWJiOWI5MzZlOTliNmZhZTZmL3YyL3dvcmtsb2FkL3BvZC9saXN0P3R5cGU9cG9kJmNsdXN0ZXJUeXBlPU1hbmFnZWRLdWJlcm5ldGVzJnByb2ZpbGU9RGVmYXVsdCZzdGF0ZT1ydW5uaW5nJnJlZ2lvbj11cy13ZXN0LTEmbnM9c3RhZ2luZw0Kb3BlbnRlbD1odHRwczovL3RyYWNlLmNvbnNvbGUuYWxpYmFiYWNsb3VkLmNvbS8/c3BtPTUxNzYuMTI4MTgwOTNfNDcub3ZlcnZpZXdfcmVjZW50LjQuMWZkNDJjYzlla2lwNkkjL3RyYWNpbmcvdXMtd2VzdC0xL2xpc3Q/ZnJvbT1ub3ctMTJoJnRvPW5vdyZyZWZyZXNoPW9mZg0KZGV2aWNlYXBwPWh0dHBzOi8vYml0YnVja2V0Lm9yZy9hZGhvY21vbnN0ZXIvZGV2aWNlLWFwcC1ncnBjL2NvbW1pdHMvYnJhbmNoL21haW4NCmJkZGRvYz1odHRwczovL2luZmluZXRsbGMuYXRsYXNzaWFuLm5ldC93aWtpL3NwYWNlcy9EVC9wYWdlcy8zNjYxMTY4NjQxL0JERCtTZXR1cCtJbnN0cnVjdGlvbitDb3B5K29mK0JhY2tlbmQrRGV2ZWxvcGVyKy0rUXVhbGl0eStDaGVja3MrSG93LVRvDQp0aGlyZHBhcnR5PWh0dHBzOi8vYml0YnVja2V0Lm9yZy9hZGhvY21vbnN0ZXIvdGhpcmQtcGFydHktZ3JwYy9jb21taXRzL2JyYW5jaC9tYWluDQoNCiMjIyMjIyMjIyMjI+OAkOaJk+W8gOW6lOeUqOOAkQ0KICBhcGlmb3g9QXBpZm94Kg0KICBkYmVhdmVyPWRiZWF2ZXIqDQogIHBnYWRtaW49cGdBZG1pbioNCiAgZ29sYW5kPWdvbGFuZCoNCiAgaWRlYT1JbnRlbGxpSiBJREVBKg0KICB2bT1WTXdhcmUgV29ya3N0YXRpb24gUHJvDQogIHV0b29scz11dG9vbHMNCiAgbW9iYT1Nb2JhWHRlcm0qDQogIHd4PeW+ruS/oQ0KICBxcT3ohb7orq9RUQ0KICB3cHM9V1BTKg0KICBrZz3phbfni5fpn7PkuZANCiAgcGxzcWw9cGxzcWwgRGV2ZWxvcGVyKg0KICBvbmVOb3RlMj1PbmVOb3RlKg0KICB4cms95ZCR5pel6JG1DQogIGhzaz3lkJHml6XokbUNCiAgYmR5cD3nmb7luqbnvZHnm5gNCiAgd2lmaT3lsI/nsbPpmo/ouqt3aWZpDQogIGNsaW9uPUNsaW9uKg0KICBub3RlUGFkKys9bm90ZVBhZCsrDQogIGlkbGU9aWRsZSAocHl0aG9ufDANCiAgc3VibGltZT1zdWJsaW1lIHRleHQqDQogIGh5PeiZjueJmeebtOaSrQ0KICBhcXk954ix5aWH6Im6DQogIG5hcmFrYT1MYXVuY2hlckdhbWUNCiAgdnNjb2RlPVZpc3VhbCBTdHVkaW8gQ29kZQ0KICB2c2M9VmlzdWFsIFN0dWRpbyBDb2RlDQogIGdhbWUrKz3muLjmiI/liqDliqANCiAgZmlkZGxlcj1GaWRkbGVyKg0KICBuYXZpY2F0PW5hdmljYXQgUHJlbWl1bSoNCiAgeGw96L+F6Zu3DQogIHR4c3A96IW+6K6v6KeG6aKRDQogIHN0ZWFtPXN0ZWFtDQogIHBzPWFkb2JlIHBob3Rvc2hvcHwwDQogIGp0PUM6XFdpbmRvd3Ncc3lzdGVtMzJcU25pcHBpbmdUb29sLmV4ZQ0KICBkbGxja3E9QzpcVXNlcnNcQWRtaW5pc3RyYXRvclxEZXNrdG9wXERMTOWHveaVsOafpeeci+WZqDMuN1xWaWV3QXBpXFZpZXdBcGkuZXhlDQogIHVtYT1DOlxVc2Vyc1xBZG1pbmlzdHJhdG9yXERlc2t0b3BcdW1hXFpURSBVTUFTQ0VcWlRFIFVNQVNDRVxVTUFTY2UuZXhlDQogIGZycD1EOlxoZWxwbWVcY29tbWFuZF9leHRcZnJwXzAuMzguMF93aW5kb3dzX2FtZDY0XGZycC52YnMNCiAgaGI9SEJ1aWxkZXJYDQogIGJsYmwgPeWTlOWTqeWTlOWTqQ0KICBvbmVub3RlPU9uZU5vdGUqDQogIHd5dXU9572R5piTVVXliqDpgJ/lmagNCiAgcio9Um9ja3N0YXIgR2FtZXMgTGF1bmNoZXINCiAgenc95pq06Zuq5oiY572RDQogIG93PeaatOmbquaImOe9kQ0KICBhbHlwPemYv+mHjOS6keebmA0KICBwb3RwbGF5ZXI9cG90cGxheWVyKg0KICBoc3l4Pea1t+myqOa4uOaIjw0KICBudmQ9R2VGb3JjZSBFeHBlcmllbmNlDQogIGdhbWU9R2VGb3JjZSBFeHBlcmllbmNlDQogIHl4PUdlRm9yY2UgRXhwZXJpZW5jZQ0KICBoYnVpbGRlcj1FOlwx44CB5bi455SoXGNocm9t5LiL6L29XEhCdWlsZGVyWFxIQnVpbGRlclguZXhlDQogIGhiPUQ6XDYu5LiL6L29XGNocm9tZVxIQnVpbGRlclhcSEJ1aWxkZXJYLmV4ZQ0KICBuYXJha2E95rC45Yqr5peg6Ze0DQogIGFseXA96Zi/6YeM5LqR55uYDQogIGxzanNxPembt+elnuWKoOmAn+WZqA0KICB1Ymk9VWJpc29mdCBDb25uZWN0DQogIGZzPUwtQ29ubmVjdCAzDQogIHBzPUFkb2JlIFBob3Rvc2hvcCoNCiAgdXU9VVXliqDpgJ/lmagNCiAgcG9zdG1hbj1Qb3N0bWFuDQogIHR4aHk96IW+6K6v5Lya6K6uDQogIHNsYWNrPXNsYWNrDQogIGN1cnNvcj1DdXJzb3INCiAgYXBpZG9nPUFwaWRvZw0KICBxc211c2ljPeaxveawtOmfs+S5kA0KICBiYW5kPUJhbmRpY2FtDQogIGdyaXA9ZGF0YWdyaXA2NCoNCg0KDQojIyMjIyMjIyMjIyPjgJB3aW5kb3dz5ZG95Luk44CRDQogIHBhaW50PShtc3BhaW50KQ0KICBqc3E9KGNhbGMpDQogIHpjYj0ocmVnZWRpdCkNCiAgZ2o9KHNodXRkb3duIC1zIC10IDApDQogIGNxPShzaHV0ZG93biAtciAtdCAwKQ0KICByd2dscT0odGFza21ncikNCiAgaG9zdHM9KG5vdGVwYWQuZXhlIEM6XFdpbmRvd3NcU3lzdGVtMzJcZHJpdmVyc1xldGNcaG9zdHMpDQogIG9jcj0oIkM6XFByb2dyYW0gRmlsZXMgKHg4NilcU29nb3VJbnB1dFxDb21wb25lbnRzXFNvZ291Q29tTWdyLmV4ZSIgLW9wZW5hcHAgc2NyZWVuY2FwdHVyZUJ1bmRsZSkNCiAgc209KHJ1bmRsbDMyLmV4ZSBwb3dycHJvZi5kbGwsU2V0U3VzcGVuZFN0YXRlIDAsMSwwKQ0KICB4bT0ocnVuZGxsMzIuZXhlIHBvd3Jwcm9mLmRsbCxTZXRTdXNwZW5kU3RhdGUgMCwxLDApDQogIGh5PSglSEVMUE1FX0hPTUUlXGNvbW1hbmRfamF2YVx6eC5iYXQpDQogIHNldHRpbmc9KHN0YXJ0IG1zLXNldHRpbmdzOiAtLXVzZXIgYWRtaW4pDQogIHVwZGF0ZT0oc3RhcnQgbXMtc2V0dGluZ3M6d2luZG93c3VwZGF0ZSkNCiAgcHJveHk9KHN0YXJ0IG1zLXNldHRpbmdzOm5ldHdvcmstcHJveHkpDQogIHh6PShzdGFydCBtcy1zZXR0aW5nczphcHBzZmVhdHVyZXMpDQogIC10eHNwPSh0YXNra2lsbCAvRiAvVCAvaW0gUVFMaXZlLmV4ZSkNCiAgLXZtPSh0YXNra2lsbCAvRiAvVCAvaW0gdm13YXJlLWhvc3RkLmV4ZSkNCiAgLWtqaj0odGFza2tpbGwgL0YgL1QgL2ltIEF1dG9Ib3RrZXlVMzIuZXhlKQ0KICAgYWkyPWh0dHBzOi8vY29waWxvdC5taWNyb3NvZnQuY29tL2NoYXRzLzlCcXFlYzlhdVRuMll1ZEZlUDhhVQ0KICAgYWkzPShzdGFydCBtaWNyb3NvZnQtZWRnZToiaHR0cHM6Ly93d3cuYmluZy5jb20vc2VhcmNoP3E9QmluZytBSSZzaG93Y29udj0xJkZPUk09aHBjb2R4IikNCiAgIGNoYXQ9KHN0YXJ0IG1pY3Jvc29mdC1lZGdlOiJodHRwczovL3d3dy5iaW5nLmNvbS9zZWFyY2g/cT1CaW5nK0FJJnNob3djb252PTEmRk9STT1ocGNvZHgiKQ0KICAgd3h5eT0oc3RhcnQgbWljcm9zb2Z0LWVkZ2U6Imh0dHBzOi8veWl5YW4uYmFpZHUuY29tLyIpDQogICBpZT0oc3RhcnQgIiIgICJtc2VkZ2UuZXhlIikNCiAgIGVkZ2U9KHN0YXJ0IG1pY3Jvc29mdC1lZGdlOiJodHRwczovL3d3dy5iYWlkdS5jb20vIikNCiAgIGxvY2s9KHJ1bmRsbDMyLmV4ZSB1c2VyMzIuZGxsLExvY2tXb3JrU3RhdGlvbikNCiAgIHBhdGg9KHN5c2RtLmNwbCkNCiAgIHN5c2luZm89KG1zaW5mbzMyKQ0KICAgZ2JmaHE9KG5ldHNoIGFkdmZpcmV3YWxsIHNldCBhbGxwcm9maWxlcyBzdGF0ZSBvZmYpDQogICBka2ZocT0obmV0c2ggYWR2ZmlyZXdhbGwgc2V0IGFsbHByb2ZpbGVzIHN0YXRlIG9uKQ0KICAgY2xlYXJraW9zaz0oYWRiIGNvbm5lY3QgMTI3LjAuMC4xOjU4NTI2ICYmIGFkYiBzaGVsbCBwbSBjbGVhciBjb20uaW5maS5zb3MyKQ0KICAgaW5zdGFsbGtpb3Nrc3RhZ2luZz0oRTpcZGV2XEFuZHJvaWRca2lvc2tca2lvc2tzdGFnaW5nLmJhdCkNCiAgIGluc3RhbGxraW9za3Byb2Q9KEU6XGRldlxBbmRyb2lkXGtpb3NrXGtpb3NrcHJvZC5iYXQpDQogICBkZW1vPSgiRTpcZGV2XGdvbGFuZC0yMDI1LjIuMC4xLndpblxiaW5cZ29sYW5kNjQuZXhlIiAiRTpcZGV2XGdvbGFuZCBwcm9qZWN0XGRlbW8iKQ0KDQoNCiMjIyMjIyMjIyMjI+OAkOaJk+W8gOaWh+S7tuWkueOAkQ0KICBjeT1EOlwxLuW4uOeUqA0KICBjaj1EOlwyLuaPkuS7tg0KICBzaGFyZT1GOlzlqLHkuZBceOOAgeWFseS6qw0KICBnb2Rpcj1EOlwzLmNvZGVcZ28NCiAgZ293b3JrPUQ6XDMuY29kZVxnb3dvcmtzDQogIG1pbmdtaW5nPUU6XOWpmue6seeFp1zpk63pk60NCiAgYV90ZW1wPUM6XFVzZXJzXEFkbWluaXN0cmF0b3JcQXBwRGF0YVxMb2NhbFxUZW1wDQoNCg0KAAAAYQBq"
sys_config_C33333:="IyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMNCiMgYWhr55qE44CQ57O757uf5Y+C5pWw6YWN572u44CRDQojIOmAmui/h2tleeWSjHZhbHVl55qE5b2i5byP77yM5L+u5pS55YC85ZCO5LiA6Iis5LiN6ZyA6KaB6YeN5ZCv6YO96IO955Sf5pWI77yM5L6L5aaCdG91Y2jlkb3ku6Tmr4/mrKHpg73kvJror7vlj5bov5nkuKrmlofku7YNCiMg5YC85Y+v5Lul5piv5pWw57uE55SoWyBdIOS7o+ihqOaVsOe7hA0KIyAnIyfku6Pooajms6jph4oNCiMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjDQoNCiNjbWTov57mjqXmnI3liqHlmajnmoTlj4LmlbDphY3nva4s5YiG5Yir5piv77yMW+aYr+WQpuaJk+W8gGNtZOi/nuaOpW9uL29mZum7mOiupOS4um9mZl0gW+W9k+WJjei/nuaOpeWQjeWtl11b5pyN5Yqh5Zmo5ZCNXVvnq6/lj6Plj7dd77yM6L+Y6ZyA6KaB6K6+572u546v5aKD5Y+Y6YeP5omN6IO96L+e5o6l5pyN5Yqh5ZmoDQpjbWRjb25uZWN0PW9mZg0KY21kbmFtZT1jbWQxDQpjbWRzZXJ2ZXI9dG16Y2xvdWQuY24NCmNtZHNlcnZlcnBvcnQ9ODg0OA0KDQojdG91Y2jphY3nva7nsbvlnovlr7nlupTnmoTmiZPlvIDmlrnlvI/vvIzlpJrkuKrnlKjnsbvlnovnlKgnW10n5Lit6Ze055So6YCX5Y+35YiG6ZqU77yM5aaC5p6c5rKh5pyJ6YWN572u5a+55bqU55qE5omT5byA57G75Z6L6YKj5LmI5bCx55So6buY6K6k5omT5byA5pa55byPDQpub3RlcGFkPVsudHh0LCAuYmF0LCAuY21kLCAudmJzLCAuYWhrXQ0Kc3VibGltZSBUZXh0Kj1bLmMsIC5jKyssIC5wYWNdDQppbnRlbGxpSiBJZGVhKj1bLmphdmEsIC54bWwgLC5odG1sLCAuanNvbiwuc3FsXQ0KDQojI+mFjee9ruaQnOeLl+e/u+ivkeeahOaYvuekuueVjOmdog0KdHJhbnNfbGluZV9jb2xvcj0jMGFmNTliDQp0cmFuc19odG1sX3NjYWxhPTAuNzUNCg0KIyPphY3nva7mkJzni5dvY3LnmoTnu5PmnpzmmL7npLrnvZHpobXlpKflsI8NCm9jcl9saW5lX2NvbG9yPSMwYWY1OWINCiNvY3JfaHRtbF9zY2FsYT0wLjY0DQpvY3JfaHRtbF9zY2FsYT0wLjY4DQoNCiMj6YWN572u5bGP6JS9Y3RybCtzaGlmdCtV77yI6L2s5o2i5a2X56ym5Liy5aSn5bCP5YaZ77yJY3RybCtzaGlmdCtkb3du77yI5ZCR5LiL5aSN5Yi25LiA6KGM5b+r5o236ZSu5bqU55So77yJDQpub191cGxvd19zdHJpbmdfZXhlPVtpZGVhNjQuZXhlLENvZGUuZXhlLGdvbGFuZDY0LmV4ZSxkYXRhZ3JpcDY0LmV4ZV0NCm5vX2NvcHlfbGluZV9leGU9W2lkZWE2NC5leGUsQ29kZS5leGUsZ29sYW5kNjQuZXhlLGRhdGFncmlwNjQuZXhlXQ0KDQojI+WmguaenOW8gOWQr2NvcGlsb3TlkI7lsLHkvJroh6rliqjlvIDlkK/ns7vnu5/ku6PnkIbvvIznu5Xov4fku6XkuIvphY3nva7vvIxhaGvku6PnoIHkuK3mnInlm7rlrprkuobkuIDpg6jliIbvvIzlpJrkuKrlgLznlKjliIblj7figJw74oCd5YiG6ZqU77yM5Y+v5Lul5L2/55So6YCa6YWN56ymICpiYWlkdS5jb20NCmNoYW5nZVByb3h5VGltZXI9b24NClByb3h5U2VydmVyPWh0dHA6Ly9sb2NhbGhvc3Q6Nzg5MA0Kc3lzcHJveHlXaGl0ZUxpc3Q9KnNvZ291LmNvbSoNCg0KIyPphY3nva7mmK/lkKblkK/nlKjpvKDmoIfkuK3plK7lnKjmtY/op4jlmajmkJzntKLpgInkuK3lhbPplK7lrZcNCm1idXR0b25fc2VhcmNoPW9uDQppZ25vcmVfcHJvY2Vzcz1baWRlYTY0LmV4ZSxDb2RlLmV4ZSxnb2xhbmQ2NC5leGUsc3VibGltZV90ZXh0LmV4ZSxkYXRhZ3JpcDY0LmV4ZV0NCmJyb3dzZXJfbGlzdD1bY2hyb21lLmV4ZSAsIG1zZWRnZS5leGUgLCBmaXJlZm94LmV4ZV0NCmRlZmF1bHRfc2VhcmNoX2VuZ2luZT1odHRwczovL3d3dy5iYWlkdS5jb20vcz93ZD0NCg0KIyPphY3nva5ob3N055qEaXB25pig5bCEDQpuZXRpcHY2PW9mZg0KbmV0dXJsPWh0dHA6Ly93d3cudG16Y2xvdWQuY24vaXB2Ng0KaG9zdG5hbWU9dG16Y2xvdWQuY24NCg0KIyPphY3nva5iaW5n5aOB57q4DQpiaW5nX3dhbGxwYXBlcj1vZmYNCg0KIyPphY3nva7lt6XkvZzpnIDopoHmiZPlvIDnmoTova/ku7YNCndvcmtfbGlzdD1bIHd4LCBnb2xhbmQsIGdyaXAsIG9uZW5vdGUsIGFwaWZveCAsc2xhY2sgLGN1cnNvciBdDQoNCg0KDQojIyMjIyMjIyMjIyPjgJDng63plK7mmKDlsIQgLOS4jeiDveacieepuuagvO+8jOS/ruaUuemcgOimgemHjeWQr2Foa+iEmuacrOOAkQ0KOjo/dXVpZD0wZDZjZGIwNy1mMDU4LTRjNDQtOWM3My1kNjlmODc3MDg5YzANCjo6PzI0PTI0MWU2MWJjLWEzMjEtNDRmYi1iMTBiLTU3NzRjMTBkNTdkMw0KOjo/YWRiPWFkYiBjb25uZWN0IDEyNy4wLjAuMTo1ODUyNg0KOjo/c29ydD1zb3J0LlNsaWNlU3RhYmxlKG9yaWdpbmFsTGlzdCwgZnVuYyhpLCBqIGludCkgYm9vbCB7IFxuIGluZGV4MSA6PXV0aWwuU2xpY2VJbmRleChsZW4ob3JkaW5hbExpc3QpLCBmdW5jKHggaW50KSBib29sIHsgcmV0dXJuIG9yZGluYWxMaXN0W3hdID09IG9yaWdpbmFsTGlzdFtpXS5JZCB9KSBcbiBpbmRleDIgOj0gdXRpbC5TbGljZUluZGV4KGxlbihvcmRpbmFsTGlzdCksIGZ1bmMoeCBpbnQpIGJvb2wgeyByZXR1cm4gb3JkaW5hbExpc3RbeF0gPT0gb3JpZ2luYWxMaXN0W2pdLklkIH0pIFxuIHJldHVybiBpbmRleDEgPCBpbmRleDIgXG59KQ0KOjo/Z28gZ2V0IGNhdGFsb2c9Z28gZ2V0IGJpdGJ1Y2tldC5vcmcvYWRob2Ntb25zdGVyL2NhdGFsb2ctZ3JwYy9wa2cvZ3JwYy92MUBkZXZlbG9wDQo6Oj9nbyBnZXQgdHJhbnM9Z28gZ2V0IGJpdGJ1Y2tldC5vcmcvYWRob2Ntb25zdGVyL2NhdGFsb2ctdHJhbnMtZ3JwYy9wa2cvZ3JwYy92MUBkZXZlbG9wDQo6Oj9nbyBnZXQgb3JkZXI9Z28gZ2V0IGJpdGJ1Y2tldC5vcmcvYWRob2Ntb25zdGVyL2NhdGFsb2ctZ3JwYy9wa2cvZ3JwYy92MUBkZXZlbG9wDQo6Oj9nbyBnZXQgbWVyY2hhbnQ9Z28gZ2V0IGJpdGJ1Y2tldC5vcmcvYWRob2Ntb25zdGVyL21lcmNoYW50LXBvcnRhbC1ncnBjL3BrZy9ncnBjL3YxQGRldmVsb3ANCjo6P2dvIGdldCBjbG92ZXI9Z28gZ2V0IGJpdGJ1Y2tldC5vcmcvYWRob2Ntb25zdGVyL2Nsb3Zlci1ncnBjL3BrZy9ncnBjL3YxQGRldmVsb3ANCjo6P2dvIGdldCB0b2FzdD1nbyBnZXQgYml0YnVja2V0Lm9yZy9hZGhvY21vbnN0ZXIvdG9hc3QtZ3JwYy9wa2cvZ3JwYy92MUBkZXZlbG9wDQo6Oj9nbyBnZXQgc3F1YXJlPWdvIGdldCBiaXRidWNrZXQub3JnL2FkaG9jbW9uc3Rlci9zcXVhcmUtZ3JwYy9wa2cvZ3JwYy92MUBkZXZlbG9wDQo6Oj9nbyBnZXQgbGlnaHRzcGVlZD1nbyBnZXQgYml0YnVja2V0Lm9yZy9hZGhvY21vbnN0ZXIvbGlnaHRzcGVlZC1ncnBjL3BrZy9ncnBjL3YxQGRldmVsb3ANCjo6P2dvIGdldCBocj1nbyBnZXQgYml0YnVja2V0Lm9yZy9hZGhvY21vbnN0ZXIvaHVuZ2VycnVzaC1ncnBjL3BrZy9ncnBjL3YxQGRldmVsb3ANCjo6P20xPTQ3NTE5MmFiLTQ4NTktNDA3ZS1hYTJjLTUyYTk4NWU2NzVkYQ0KOjo/bDE9MjczZjlkNTUtNWNkNS00NDgyLTg0NjEtZjhjYWY5MDc0YWVhDQo6Oj9sMj02ODBiNTg0MC1lZjY0LTRhNGUtOTk0YS1lMjFkYjhjNmUxYWUNCjo6P2wzPTBiMzBjNTI1LWNiOGItNDVlMS1iOGVkLTNjN2FlNTlhNmRjNw0KOjo/MjR0b2tlbj1FQUFBbDk2TGhRdFZ1aVFGRlY3UWNPbGNqVWNreWx2d2NqcVFkTE9MYTM4dGk1aGJoaXVfVjdYMFBkb3BpaldhDQoNCjo6P3NxdWFyZSBob29rIGJlZ2luPUluZm86c3R1Yi5XZWJob29rU3luY1NxdWFyZURhdGFWMiByZXF1ZXN0DQo6Oj9zcXVhcmUgaG9vayBlbmQ9SW5mbzpzdHViLldlYmhvb2tTeW5jU3F1YXJlRGF0YVYyIGVuZA0KOjo/c3F1YXJlIGNyb24gYmVnaW4gPUluZm86c3R1Yi5Dcm9uSm9iU3luY0xvY2F0aW9uU3F1YXJlSXRlbXMgcmVxdWVzdA0KOjo/c3F1YXJlIGNyb24gZW5kID1JbmZvOnN0dWIuQ3JvbkpvYlN5bmNMb2NhdGlvblNxdWFyZUl0ZW1zIGVuZA0KOjo/c3M9ZmluZHN0ciAvcyAvaSAvbSAieHh4IiAqLioNCjo6P3NzMj1oYXM6bGluayANCiMjI+aVsOaNruW6k+aTjeS9nA0KOjo/bWVyY2hhbnQ9c2VsZWN0ICogZnJvbSBtZXJjaGFudC5tZXJjaGFudCAgd2hlcmUgbWVyY2hhbnRfaWQgID0neHh4eHgnOw0KOjo/bG9jYXRpb249c2VsZWN0ICogZnJvbSBtZXJjaGFudC5sb2NhdGlvbiAgIHdoZXJlIG1lcmNoYW50X2lkICA9J3h4eHh4JzsNCjo6P2xvY2F0aW9uMj1zZWxlY3QgKiBmcm9tIG1lcmNoYW50LmxvY2F0aW9uICAgd2hlcmUgbG9jYXRpb25faWQgID0neHh4eHgnOw0KOjo/dG9rZW49c2VsZWN0ICogZnJvbSBtYXBwaW5nLnRva2VuX3RoaXJkcGFydHkgdHQgIHdoZXJlIHR0Lm1lcmNoYW50X2lkID0neHh4eHgnOw0KOjo/dG9rZW4yPXNlbGVjdCAqIGZyb20gbWFwcGluZy50b2tlbl90aGlyZHBhcnR5IHR0ICB3aGVyZSB0dC5sb2NhdGlvbl9pZCA9J3h4eHh4JzsNCjo6P3Rva2VuMjQ9RUFBQWwxdmZ2WTFsZndrQTFfa2Q5OTB5RTRTZTlKak5wdWRWS0hXVVNkbW5nVUc3UjdGVS1wYno0ZW9jNkQ1UA0KOjo/aXRlbT1zZWxlY3QgKmZyb20gY2F0YWxvZ3MuaXRlbSAgd2hlcmUgaWQgPSd4eHh4eCcgOw0KOjo/aXRlbTI9c2VsZWN0ICpmcm9tIGNhdGFsb2dzLml0ZW0gIHdoZXJlIHRpdGxlID0neHh4eHgnIDsNCjo6P3ZydD1zZWxlY3QgKiBmcm9tIGNhdGFsb2dzLnZhcmlhdGlvbiB3aGVyZSBpZD0neHh4eHgnOw0KOjo/dnJ0Mj1zZWxlY3QgKiBmcm9tIGNhdGFsb2dzLnZhcmlhdGlvbiB3aGVyZSBpdGVtX2lkPSd4eHh4eCc7DQo6Oj9tZHNldD1zZWxlY3QgKmZyb20gY2F0YWxvZ3MubW9kaWZpZXJfc2V0IHdoZXJlIGlkID0neHh4eHgnIDsNCjo6P21vZGlmaWVyPXNlbGVjdCAqZnJvbSBjYXRhbG9ncy5tb2RpZmllciB3aGVyZSBpZCA9J3h4eHh4JyA7DQo6Oj9tb2RpZmllcjI9c2VsZWN0ICpmcm9tIGNhdGFsb2dzLm1vZGlmaWVyIHdoZXJlIG1vZGlmaWVyX3NldF9pZCA9J3h4eHh4JyA7DQo6Oj9iZD1iZDJiMDA0MS0xYTZkLTRiOTEtYmUwMS1kNGM0YmYyNTdmMDANCjo6P21lbnU9c2VsZWN0ICpmcm9tIGNhdGFsb2dzLm1lbnUgd2hlcmUgaWQgPSd4eHh4eCc7DQoNCjo6P3BzcWw9ew0KCS8vIDIuIOazqOWFpee7j+i/h+W+ruiwg+eahOe9kee7nOW6leWxguihpeS4ge+8jOW9u+W6leW5s+eBremrmOW7tui/n+Wkp+Wtl+auteWBh+atuw0KCWlmIHBzcWwgIT0gbmlsICYmIHBzcWwuUG9vbCAhPSBuaWwgew0KCQljb25maWcgOj0gcHNxbC5Qb29sLkNvbmZpZygpDQoJCWlmIGNvbmZpZyAhPSBuaWwgJiYgY29uZmlnLkNvbm5Db25maWcgIT0gbmlsIHsNCgkJCS8vIOWjsOaYjuagh+WHhueahOmAmueUqCBEaWFsZXINCgkJCWQgOj0gJm5ldC5EaWFsZXJ7DQoJCQkJVGltZW91dDogMzAgKiB0aW1lLlNlY29uZCwNCgkJCVx9DQoJCQkvLyDpgJrov4cgQ29udHJvbCDpkqnlrZDvvIzlnKggVENQIOi/nuaOpeW7uueri+eahOeerOmXtOazqOWFpea4qeWSjOeahCAxTUIg57yT5Yay5Yy6DQoJCQlkLkNvbnRyb2wgPSBmdW5jKG5ldHdvcmssIGFkZHJlc3Mgc3RyaW5nLCBjIHN5c2NhbGwuUmF3Q29ubikgZXJyb3Igew0KCQkJCXJldHVybiBjLkNvbnRyb2woZnVuYyhmZCB1aW50cHRyKSB7DQoJCQkJCS8vIPCfkqEgMU1CIOaYryBWUE4g6ZO+6Lev5LiK5pyA5a6M576O55qE54mp55CG56qX5Y+j5aSn5bCP77yM5pei5aSn6L+H6buY6K6k5YyF77yM5Y+I5LiN5Lya5byV5Y+R5LqR56uv5ouS57ud5pyN5YqhDQoJCQkJCV8gPSBzeXNjYWxsLlNldHNvY2tvcHRJbnQoc3lzY2FsbC5IYW5kbGUoZmQpLCBzeXNjYWxsLlNPTF9TT0NLRVQsIHN5c2NhbGwuU09fUkNWQlVGLCAxMDI0KjEwMjQpIC8vIDFNQg0KCQkJCQlfID0gc3lzY2FsbC5TZXRzb2Nrb3B0SW50KHN5c2NhbGwuSGFuZGxlKGZkKSwgc3lzY2FsbC5TT0xfU09DS0VULCBzeXNjYWxsLlNPX1NOREJVRiwgMTAyNCoxMDI0KSAvLyAxTUINCgkJCQl9KQ0KCQkJXH0NCgkJCS8vIOWujOe+juWvuem9kCBwZ3gvdjUg55qEIERpYWxGdW5jIOetvuWQjQ0KCQkJY29uZmlnLkNvbm5Db25maWcuRGlhbEZ1bmMgPSBmdW5jKGN0eCBjb250ZXh0LkNvbnRleHQsIG5ldHdvcmssIGFkZHIgc3RyaW5nKSAobmV0LkNvbm4sIGVycm9yKSB7DQoJCQkJcmV0dXJuIGQuRGlhbENvbnRleHQoY3R4LCBuZXR3b3JrLCBhZGRyKQ0KCQkJXH0NCgkJCWxvZy5QcmludGxuKCLimpnvuI8g6Leo54mI5pys6YCa55So5YaF5qC457qnIFRDUCAxTUIg6buE6YeR57yT5Yay5Yy66KGl5LiB5rOo5YWl5oiQ5Yqf77yBIikNCgkJXH0NCglcfQ0KfQ0KDQoNCjo6P2Rldj17DQogICAgXCMg5byA5Y+R546v5aKD5Y+Y6YePIFtkZXZdDQogICAgXCNkYg0KICAgIFBTUUxfSE9TVD1wZ20tMmV2MTdxZTEzbXg5YWJ5cWVvLnBnLnJkcy5hbGl5dW5jcy5jb20NCiAgICBQU1FMX1BPUlQ9NTQzMg0KICAgIFBTUUxfVVNFUj1zaGVuZ3poaV90DQogICAgUFNRTF9QQVNTV09SRD0iNlwkVWprOTAiDQogICAgUFNRTF9EQVRBQkFTRT11bmljb3JuX2Rldg0KDQogICAgXCNncnBjDQogICAgTUVSQ0hBTlRfUlBDX1VSTD10bHM6Ly9tZXJjaGFudC1wb3J0YWwtZ3JwYy5kZXYub3JkZXJ3aXRoaW5maS5jb206NDQzDQogICAgTUVSQ0hBTlRfUE9SVEFMX1JQQ19VUkw9dGxzOi8vbWVyY2hhbnQtcG9ydGFsLWdycGMuZGV2Lm9yZGVyd2l0aGluZmkuY29tOjQ0Mw0KICAgIE9SREVSX1JQQ19VUkw9dGxzOi8vb3JkZXItZ3JwYy5kZXYub3JkZXJ3aXRoaW5maS5jb206NDQzDQogICAgQ0FUQUxPR19SUENfVVJMPXRsczovL2NhdGFsb2ctZ3JwYy5kZXYub3JkZXJ3aXRoaW5maS5jb206NDQzDQogICAgQ0FUQUxPR19UUkFOU19SUENfVVJMPXRsczovL2NhdGFsb2ctdHJhbnMtZ3JwYy5kZXYub3JkZXJ3aXRoaW5maS5jb206NDQzDQogICAgU1FVQVJFX1JQQ19VUkw9dGxzOi8vc3F1YXJlLWdycGMuZGV2Lm9yZGVyd2l0aGluZmkuY29tOjQ0Mw0KICAgIExJR0hUU1BFRURfUlBDX1VSTD10bHM6Ly9saWdodHNwZWVkLWdycGMuZGV2Lm9yZGVyd2l0aGluZmkuY29tOjQ0Mw0KICAgIFRPQVNUX1JQQ19VUkw9dGxzOi8vdG9hc3QtZ3JwYy5kZXYub3JkZXJ3aXRoaW5maS5jb206NDQzDQogICAgQ0xPVkVSX1JQQ19VUkw9dGxzOi8vY2xvdmVyLWdycGMuZGV2Lm9yZGVyd2l0aGluZmkuY29tOjQ0Mw0KICAgIERBVEFfQ0VOVEVSX1JQQ19VUkw9dGxzOi8vZGF0YS1jZW50ZXItZ3JwYy5kZXYub3JkZXJ3aXRoaW5maS5jb206NDQzDQogICAgVEhJUkRfUEFSVFlfUlBDX1VSTD10bHM6Ly90aGlyZC1wYXJ0eS1ncnBjLmRldi5vcmRlcndpdGhpbmZpLmNvbTo0NDMNCiAgICBBVVRIWl9SUENfVVJMPXRsczovL2F1dGhuei1ncnBjLmRldi5vcmRlcndpdGhpbmZpLmNvbTo0NDMNCiAgICBIVU5HRVJfUlVTSF9SUENfVVJMPXRsczovL2h1bmdlcnJ1c2gtZ3JwYy5kZXYub3JkZXJ3aXRoaW5maS5jb206NDQzDQogICAgUEFZTUVOVF9SUENfVVJMPXRsczovL3BheW1lbnQtZ3JwYy5kZXYub3JkZXJ3aXRoaW5maS5jb206NDQzDQogICAgTVNHSU5HX0JST0tFUl9HUlBDX1VSTD10bHM6Ly9tc2dpbmctYnJva2VyLWdycGMuZGV2Lm9yZGVyd2l0aGluZmkuY29tOjQ0Mw0KICAgIE1FTlVfU1lOQ19SUENfVVJMPXRsczovL21lbnUtc3luYy1ncnBjLmRldi5vcmRlcndpdGhpbmZpLmNvbTo0NDMNCg0KICAgIFwjUE9TIEVOVg0KICAgIFwjaHVuZ2VycnVzaA0KICAgIEhVTkdFUlJVU0hfQkFTRV9VUkw9aHR0cHM6Ly9jbG91ZGFwaS5odW5nZXJydXNoLmNvbQ0KICAgIEhVTkdFUlJVU0hfQVVUSF9VUkw9aHR0cHM6Ly9sb2dpbi5taWNyb3NvZnRvbmxpbmUuY29tL2JiNGJlMmMxLTcwNzEtNDNlMC05YTFhLWFkY2E2NTljODY2MS9vYXV0aDIvdjIuMC90b2tlbg0KICAgIEhVTkdFUlJVU0hfQ0xJRU5UX0lEPTlhNDlkNmFhLTA5M2MtNDk2NS04NjE4LWNkZDc3ODZhNmU3OQ0KICAgIEhVTkdFUlJVU0hfQ0xJRU5UX1NFQ1JFVD1JOGs4UX5BZHhGWkFKWmlueGJtLmouOXJZZkxhb1RoQXQ3dlRNYlFPDQogICAgSFVOR0VSUlVTSF9TQ09QRT1hcGk6Ly8yMWZiMjJlMS03MDQ0LTQyMmItYTJlMy00MmM5OTI1Nzc5MTAvLmRlZmF1bHQNCiAgICBcI3RvYXN0DQogICAgVE9BU1RfQkFTRV9VUkw9aHR0cHM6Ly93cy1zYW5kYm94LWFwaS5lbmcudG9hc3R0YWIuY29tDQogICAgQ0xJRU5UX0lEPUZNTEowSk51bTlVZXBZalRJSlVJZWxhenJ6UWd5YUxkDQogICAgQ0xJRU5UX1NFQ1JFVD02M0czUnlmRllrSXVyN1dIVmpIM2JjTWlQdWNZdTRRajc4Z2NCRXR5R0VSU0tYQWZ6MElYM3dRclc1dlM1SmsyDQogICAgVVNFUl9BQ0NFU1NfVFlQRT1UT0FTVF9NQUNISU5FX0NMSUVOVA0KfQ0KDQoNCjo6P3N0YWdpbmc9ew0KICAgIFwjIOa1i+ivleeOr+Wig+WPmOmHjyBbc3RhZ2luZ10NCiAgICBcI2RiDQogICAgUFNRTF9VU0VSPWluZmlfZGJhX2Rldg0KICAgIFBTUUxfUEFTU1dPUkQ9cGFzczRQYXNzDQogICAgUFNRTF9IT1NUPXBnbS0yZXZhYjQ5OTc0ZDMxN2kwdm8ucGcucmRzLmFsaXl1bmNzLmNvbQ0KICAgIFBTUUxfUE9SVD01NDMyDQogICAgUFNRTF9EQVRBQkFTRT1pbmZpLWRldg0KDQogICAgXCNncnBjDQogICAgTUVSQ0hBTlRfUlBDX1VSTD10bHM6Ly9tZXJjaGFudC1wb3J0YWwtZ3JwYy5zdGFnaW5nLm9yZGVyd2l0aGluZmkuY29tOjQ0Mw0KICAgIE1FUkNIQU5UX1BPUlRBTF9SUENfVVJMPXRsczovL21lcmNoYW50LXBvcnRhbC1ncnBjLnN0YWdpbmcub3JkZXJ3aXRoaW5maS5jb206NDQzDQogICAgT1JERVJfUlBDX1VSTD10bHM6Ly9vcmRlci1ncnBjLnN0YWdpbmcub3JkZXJ3aXRoaW5maS5jb206NDQzDQogICAgQ0FUQUxPR19SUENfVVJMPXRsczovL2NhdGFsb2ctZ3JwYy5zdGFnaW5nLm9yZGVyd2l0aGluZmkuY29tOjQ0Mw0KICAgIENBVEFMT0dfVFJBTlNfUlBDX1VSTD10bHM6Ly9jYXRhbG9nLXRyYW5zLWdycGMuc3RhZ2luZy5vcmRlcndpdGhpbmZpLmNvbTo0NDMNCiAgICBTUVVBUkVfUlBDX1VSTD10bHM6Ly9zcXVhcmUtZ3JwYy5zdGFnaW5nLm9yZGVyd2l0aGluZmkuY29tOjQ0Mw0KICAgIExJR0hUU1BFRURfUlBDX1VSTD10bHM6Ly9saWdodHNwZWVkLWdycGMuc3RhZ2luZy5vcmRlcndpdGhpbmZpLmNvbTo0NDMNCiAgICBUT0FTVF9SUENfVVJMPXRsczovL3RvYXN0LWdycGMuc3RhZ2luZy5vcmRlcndpdGhpbmZpLmNvbTo0NDMNCiAgICBDTE9WRVJfUlBDX1VSTD10bHM6Ly9jbG92ZXItZ3JwYy5zdGFnaW5nLm9yZGVyd2l0aGluZmkuY29tOjQ0Mw0KICAgIERBVEFfQ0VOVEVSX1JQQ19VUkw9dGxzOi8vZGF0YS1jZW50ZXItZ3JwYy5zdGFnaW5nLm9yZGVyd2l0aGluZmkuY29tOjQ0Mw0KICAgIFRISVJEX1BBUlRZX1JQQ19VUkw9dGxzOi8vdGhpcmQtcGFydHktZ3JwYy5zdGFnaW5nLm9yZGVyd2l0aGluZmkuY29tOjQ0Mw0KICAgIEFVVEhaX1JQQ19VUkw9dGxzOi8vYXV0aG56LWdycGMuc3RhZ2luZy5vcmRlcndpdGhpbmZpLmNvbTo0NDMNCiAgICBIVU5HRVJfUlVTSF9SUENfVVJMPXRsczovL2h1bmdlcnJ1c2gtZ3JwYy5zdGFnaW5nLm9yZGVyd2l0aGluZmkuY29tOjQ0Mw0KICAgIFBBWU1FTlRfUlBDX1VSTD10bHM6Ly9wYXltZW50LWdycGMuc3RhZ2luZy5vcmRlcndpdGhpbmZpLmNvbTo0NDMNCiAgICBNU0dJTkdfQlJPS0VSX0dSUENfVVJMPXRsczovL21zZ2luZy1icm9rZXItZ3JwYy5zdGFnaW5nLm9yZGVyd2l0aGluZmkuY29tOjQ0Mw0KICAgIE1FTlVfU1lOQ19SUENfVVJMPXRsczovL21lbnUtc3luYy1ncnBjLnN0YWdpbmcub3JkZXJ3aXRoaW5maS5jb206NDQzDQoNCiAgICBcI1BPUyBFTlYNCiAgICBcI2h1bmdlcnJ1c2gNCiAgICBIVU5HRVJSVVNIX0JBU0VfVVJMPWh0dHBzOi8vY2xvdWRhcGkuaHVuZ2VycnVzaC5jb20NCiAgICBIVU5HRVJSVVNIX0FVVEhfVVJMPWh0dHBzOi8vbG9naW4ubWljcm9zb2Z0b25saW5lLmNvbS9iYjRiZTJjMS03MDcxLTQzZTAtOWExYS1hZGNhNjU5Yzg2NjEvb2F1dGgyL3YyLjAvdG9rZW4NCiAgICBIVU5HRVJSVVNIX0NMSUVOVF9JRD05YTQ5ZDZhYS0wOTNjLTQ5NjUtODYxOC1jZGQ3Nzg2YTZlNzkNCiAgICBIVU5HRVJSVVNIX0NMSUVOVF9TRUNSRVQ9SThrOFF+QWR4RlpBSlppbnhibS5qLjlyWWZMYW9UaEF0N3ZUTWJRTw0KICAgIEhVTkdFUlJVU0hfU0NPUEU9YXBpOi8vMjFmYjIyZTEtNzA0NC00MjJiLWEyZTMtNDJjOTkyNTc3OTEwLy5kZWZhdWx0DQogICAgXCN0b2FzdA0KICAgIFRPQVNUX0JBU0VfVVJMPWh0dHBzOi8vd3Mtc2FuZGJveC1hcGkuZW5nLnRvYXN0dGFiLmNvbQ0KICAgIENMSUVOVF9JRD1GTUxKMEpOdW05VWVwWWpUSUpVSWVsYXpyelFneWFMZA0KICAgIENMSUVOVF9TRUNSRVQ9NjNHM1J5ZkZZa0l1cjdXSFZqSDNiY01pUHVjWXU0UWo3OGdjQkV0eUdFUlNLWEFmejBJWDN3UXJXNXZTNUprMg0KICAgIFVTRVJfQUNDRVNTX1RZUEU9VE9BU1RfTUFDSElORV9DTElFTlQNCn0NCg0KDQoNCjo6P3N0YWdlPXsNCiAgICBcIyDmlrDmtYvor5Xnjq/looPlj5jph48gW3N0YWdlXQ0KICAgIFwjZGINCiAgICBQU1FMX0hPU1Q9cGdtLTJldmprdDY2OGJtN3FlNzdmby5wZy5yZHMtYWxpeXVuLWFtZXJpY2EucmRzLmFsaXl1bmNzLmNvbQ0KICAgIFBTUUxfUE9SVD01NDMyDQogICAgUFNRTF9VU0VSPXNoZW5nemhpX3QNCiAgICBQU1FMX1BBU1NXT1JEPSI2XCRVams5MCINCiAgICBQU1FMX0RBVEFCQVNFPXVuaWNvcm5fc3RhZ2luZw0KICAgIFBTUUxfVExTX0NBX0NFUlRfUEFUSD1FOlxkZXZcY2VydFxzZXJ2ZXItY2EuY3J0DQogICAgUFNRTF9UTFNfQ0VSVF9QQVRIPUU6XGRldlxjZXJ0XHNoZW5nemhpX3QuY3J0DQogICAgUFNRTF9UTFNfS0VZX1BBVEg9RTpcZGV2XGNlcnRcc2hlbmd6aGlfdC5rZXkNCiAgICBQU1FMX1RMU19NT0RFPXJlcXVpcmUNCiAgICANCiAgICBcI2dycGMNCiAgICBNRVJDSEFOVF9SUENfVVJMPXRsczovL21lcmNoYW50LXBvcnRhbC1ncnBjLnN0YWdlLm9yZGVyd2l0aGluZmkuY29tOjQ0Mw0KICAgIE1FUkNIQU5UX1BPUlRBTF9SUENfVVJMPXRsczovL21lcmNoYW50LXBvcnRhbC1ncnBjLnN0YWdlLm9yZGVyd2l0aGluZmkuY29tOjQ0Mw0KICAgIE9SREVSX1JQQ19VUkw9dGxzOi8vb3JkZXItZ3JwYy5zdGFnZS5vcmRlcndpdGhpbmZpLmNvbTo0NDMNCiAgICBDQVRBTE9HX1JQQ19VUkw9dGxzOi8vY2F0YWxvZy1ncnBjLnN0YWdlLm9yZGVyd2l0aGluZmkuY29tOjQ0Mw0KICAgIENBVEFMT0dfVFJBTlNfUlBDX1VSTD10bHM6Ly9jYXRhbG9nLXRyYW5zLWdycGMuc3RhZ2Uub3JkZXJ3aXRoaW5maS5jb206NDQzDQogICAgU1FVQVJFX1JQQ19VUkw9dGxzOi8vc3F1YXJlLWdycGMuc3RhZ2Uub3JkZXJ3aXRoaW5maS5jb206NDQzDQogICAgTElHSFRTUEVFRF9SUENfVVJMPXRsczovL2xpZ2h0c3BlZWQtZ3JwYy5zdGFnZS5vcmRlcndpdGhpbmZpLmNvbTo0NDMNCiAgICBUT0FTVF9SUENfVVJMPXRsczovL3RvYXN0LWdycGMuc3RhZ2Uub3JkZXJ3aXRoaW5maS5jb206NDQzDQogICAgQ0xPVkVSX1JQQ19VUkw9dGxzOi8vY2xvdmVyLWdycGMuc3RhZ2Uub3JkZXJ3aXRoaW5maS5jb206NDQzDQogICAgREFUQV9DRU5URVJfUlBDX1VSTD10bHM6Ly9kYXRhLWNlbnRlci1ncnBjLnN0YWdlLm9yZGVyd2l0aGluZmkuY29tOjQ0Mw0KICAgIFRISVJEX1BBUlRZX1JQQ19VUkw9dGxzOi8vdGhpcmQtcGFydHktZ3JwYy5zdGFnZS5vcmRlcndpdGhpbmZpLmNvbTo0NDMNCiAgICBBVVRIWl9SUENfVVJMPXRsczovL2F1dGhuei1ncnBjLnN0YWdlLm9yZGVyd2l0aGluZmkuY29tOjQ0Mw0KICAgIEhVTkdFUl9SVVNIX1JQQ19VUkw9dGxzOi8vaHVuZ2VycnVzaC1ncnBjLnN0YWdlLm9yZGVyd2l0aGluZmkuY29tOjQ0Mw0KICAgIFBBWU1FTlRfUlBDX1VSTD10bHM6Ly9wYXltZW50LWdycGMuc3RhZ2Uub3JkZXJ3aXRoaW5maS5jb206NDQzDQogICAgTVNHSU5HX0JST0tFUl9HUlBDX1VSTD10bHM6Ly9tc2dpbmctYnJva2VyLWdycGMuc3RhZ2Uub3JkZXJ3aXRoaW5maS5jb206NDQzDQogICAgTUVOVV9TWU5DX1JQQ19VUkw9dGxzOi8vbWVudS1zeW5jLWdycGMuc3RhZ2Uub3JkZXJ3aXRoaW5maS5jb206NDQzDQogICAgDQogICAgXCNQT1MgRU5WDQogICAgXCNodW5nZXJydXNoDQogICAgSFVOR0VSUlVTSF9CQVNFX1VSTD1odHRwczovL2Nsb3VkYXBpLmh1bmdlcnJ1c2guY29tDQogICAgSFVOR0VSUlVTSF9BVVRIX1VSTD1odHRwczovL2xvZ2luLm1pY3Jvc29mdG9ubGluZS5jb20vYmI0YmUyYzEtNzA3MS00M2UwLTlhMWEtYWRjYTY1OWM4NjYxL29hdXRoMi92Mi4wL3Rva2VuDQogICAgSFVOR0VSUlVTSF9DTElFTlRfSUQ9OWE0OWQ2YWEtMDkzYy00OTY1LTg2MTgtY2RkNzc4NmE2ZTc5DQogICAgSFVOR0VSUlVTSF9DTElFTlRfU0VDUkVUPUk4azhRfkFkeEZaQUpaaW54Ym0uai45cllmTGFvVGhBdDd2VE1iUU8NCiAgICBIVU5HRVJSVVNIX1NDT1BFPWFwaTovLzIxZmIyMmUxLTcwNDQtNDIyYi1hMmUzLTQyYzk5MjU3NzkxMC8uZGVmYXVsdA0KICAgIFwjdG9hc3QNCiAgICBUT0FTVF9CQVNFX1VSTD1odHRwczovL3dzLXNhbmRib3gtYXBpLmVuZy50b2FzdHRhYi5jb20NCiAgICBDTElFTlRfSUQ9Rk1MSjBKTnVtOVVlcFlqVElKVUllbGF6cnpRZ3lhTGQNCiAgICBDTElFTlRfU0VDUkVUPTYzRzNSeWZGWWtJdXI3V0hWakgzYmNNaVB1Y1l1NFFqNzhnY0JFdHlHRVJTS1hBZnowSVgzd1FyVzV2UzVKazINCiAgICBVU0VSX0FDQ0VTU19UWVBFPVRPQVNUX01BQ0hJTkVfQ0xJRU5UDQp9DQoNCjo6P3Byb2Q9ew0KICAgIFwjIOeUn+S6p+eOr+Wig+WPmOmHjyBbcHJvZF0NCiAgICBcI2RiDQogICAgUFNRTF9VU0VSPWFwcF91c2VyMDAxDQogICAgUFNRTF9QQVNTV09SRD05dTgzcXJKZGtXcQ0KICAgIFBTUUxfSE9TVD1wZ20tMmV2MXNwcmZoMjRnMDV3MGpvLnBnLnJkcy5hbGl5dW5jcy5jb20NCiAgICBQU1FMX1BPUlQ9NTQzMg0KICAgIFBTUUxfREFUQUJBU0U9dW5pY29ybg0KDQogICAgXCNncnBjDQogICAgTUVSQ0hBTlRfUlBDX1VSTD10bHM6Ly9tZXJjaGFudC1wb3J0YWwtZ3JwYy5wcm9kLm9yZGVyd2l0aGluZmkuY29tOjQ0Mw0KICAgIE1FUkNIQU5UX1BPUlRBTF9SUENfVVJMPXRsczovL21lcmNoYW50LXBvcnRhbC1ncnBjLnByb2Qub3JkZXJ3aXRoaW5maS5jb206NDQzDQogICAgT1JERVJfUlBDX1VSTD10bHM6Ly9vcmRlci1ncnBjLnByb2Qub3JkZXJ3aXRoaW5maS5jb206NDQzDQogICAgQ0FUQUxPR19SUENfVVJMPXRsczovL2NhdGFsb2ctZ3JwYy5wcm9kLm9yZGVyd2l0aGluZmkuY29tOjQ0Mw0KICAgIENBVEFMT0dfVFJBTlNfUlBDX1VSTD10bHM6Ly9jYXRhbG9nLXRyYW5zLWdycGMucHJvZC5vcmRlcndpdGhpbmZpLmNvbTo0NDMNCiAgICBTUVVBUkVfUlBDX1VSTD10bHM6Ly9zcXVhcmUtZ3JwYy5wcm9kLm9yZGVyd2l0aGluZmkuY29tOjQ0Mw0KICAgIExJR0hUU1BFRURfUlBDX1VSTD10bHM6Ly9saWdodHNwZWVkLWdycGMucHJvZC5vcmRlcndpdGhpbmZpLmNvbTo0NDMNCiAgICBUT0FTVF9SUENfVVJMPXRsczovL3RvYXN0LWdycGMucHJvZC5vcmRlcndpdGhpbmZpLmNvbTo0NDMNCiAgICBDTE9WRVJfUlBDX1VSTD10bHM6Ly9jbG92ZXItZ3JwYy5wcm9kLm9yZGVyd2l0aGluZmkuY29tOjQ0Mw0KICAgIERBVEFfQ0VOVEVSX1JQQ19VUkw9dGxzOi8vZGF0YS1jZW50ZXItZ3JwYy5wcm9kLm9yZGVyd2l0aGluZmkuY29tOjQ0Mw0KICAgIFRISVJEX1BBUlRZX1JQQ19VUkw9dGxzOi8vdGhpcmQtcGFydHktZ3JwYy5wcm9kLm9yZGVyd2l0aGluZmkuY29tOjQ0Mw0KICAgIEFVVEhaX1JQQ19VUkw9dGxzOi8vYXV0aG56LWdycGMucHJvZC5vcmRlcndpdGhpbmZpLmNvbTo0NDMNCiAgICBIVU5HRVJfUlVTSF9SUENfVVJMPXRsczovL2h1bmdlcnJ1c2gtZ3JwYy5wcm9kLm9yZGVyd2l0aGluZmkuY29tOjQ0Mw0KICAgIFBBWU1FTlRfUlBDX1VSTD10bHM6Ly9wYXltZW50LWdycGMucHJvZC5vcmRlcndpdGhpbmZpLmNvbTo0NDMNCiAgICBNU0dJTkdfQlJPS0VSX0dSUENfVVJMPXRsczovL21zZ2luZy1icm9rZXItZ3JwYy5wcm9kLm9yZGVyd2l0aGluZmkuY29tOjQ0Mw0KICAgIE1FTlVfU1lOQ19SUENfVVJMPXRsczovL21lbnUtc3luYy1ncnBjLnByb2Qub3JkZXJ3aXRoaW5maS5jb206NDQzDQoNCiAgICBcI1BPUyBFTlYNCiAgICBcI2h1bmdlcnJ1c2gNCiAgICBIVU5HRVJSVVNIX0JBU0VfVVJMPWh0dHBzOi8vY2xvdWRhcGkuaHVuZ2VycnVzaC5jb20NCiAgICBIVU5HRVJSVVNIX0FVVEhfVVJMPWh0dHBzOi8vbG9naW4ubWljcm9zb2Z0b25saW5lLmNvbS9iYjRiZTJjMS03MDcxLTQzZTAtOWExYS1hZGNhNjU5Yzg2NjEvb2F1dGgyL3YyLjAvdG9rZW4NCiAgICBIVU5HRVJSVVNIX0NMSUVOVF9JRD05YTQ5ZDZhYS0wOTNjLTQ5NjUtODYxOC1jZGQ3Nzg2YTZlNzkNCiAgICBIVU5HRVJSVVNIX0NMSUVOVF9TRUNSRVQ9SThrOFF+QWR4RlpBSlppbnhibS5qLjlyWWZMYW9UaEF0N3ZUTWJRTw0KICAgIEhVTkdFUlJVU0hfU0NPUEU9YXBpOi8vMjFmYjIyZTEtNzA0NC00MjJiLWEyZTMtNDJjOTkyNTc3OTEwLy5kZWZhdWx0DQogICAgXCN0b2FzdA0KICAgIFRPQVNUX0JBU0VfVVJMPWh0dHBzOi8vd3MtYXBpLnRvYXN0dGFiLmNvbQ0KICAgIENMSUVOVF9JRD0yMGhCRXM1OWZCV3RsMXUwZUoyMDFHdkFzVTVDVTNhbw0KICAgIENMSUVOVF9TRUNSRVQ9SGZRR1ltUERGTV9aNGd6MTVFcVBoU3dWeDVkNFp3WVlsUWxRVkRvc2llX2N1N3NuTk92RU40aVhBNUw4dFlRag0KICAgIFVTRVJfQUNDRVNTX1RZUEU9VE9BU1RfTUFDSElORV9DTElFTlQNCn0NCg0KDQoNCjo6P29zLnNldCBkZXY9ew0KICAgIC8vdG9kbyBmb3IgdGVzdCBbZGV2XQ0KICAgIC8vZGF0YWJzZQ0KICAgIG9zLlNldGVudigiUFNRTF9IT1NUIiwgInBnbS0yZXYxN3FlMTNteDlhYnlxZW8ucGcucmRzLmFsaXl1bmNzLmNvbSIpIC8vZGV2DQogICAgb3MuU2V0ZW52KCJQU1FMX1BPUlQiLCAiNTQzMiIpIC8vZGV2DQogICAgb3MuU2V0ZW52KCJQU1FMX1VTRVIiLCAic2hlbmd6aGlfdCIpIC8vZGV2DQogICAgb3MuU2V0ZW52KCJQU1FMX1BBU1NXT1JEIiwgIjYkVWprOTAiKSAvL2Rldg0KICAgIG9zLlNldGVudigiUFNRTF9EQVRBQkFTRSIsICJ1bmljb3JuX2RldiIpIC8vZGV2DQogICAgLy9ncnBjDQogICAgb3MuU2V0ZW52KCJNRVJDSEFOVF9SUENfVVJMIiwgInRsczovL21lcmNoYW50LXBvcnRhbC1ncnBjLmRldi5vcmRlcndpdGhpbmZpLmNvbTo0NDMiKSAgICAgICAgLy9kZXYNCiAgICBvcy5TZXRlbnYoIk1FUkNIQU5UX1BPUlRBTF9SUENfVVJMIiwgInRsczovL21lcmNoYW50LXBvcnRhbC1ncnBjLmRldi5vcmRlcndpdGhpbmZpLmNvbTo0NDMiKSAvL2Rldg0KICAgIG9zLlNldGVudigiT1JERVJfUlBDX1VSTCIsICJ0bHM6Ly9vcmRlci1ncnBjLmRldi5vcmRlcndpdGhpbmZpLmNvbTo0NDMiKSAgICAgICAgICAgICAgICAgICAgIC8vZGV2DQogICAgb3MuU2V0ZW52KCJDQVRBTE9HX1JQQ19VUkwiLCAidGxzOi8vY2F0YWxvZy1ncnBjLmRldi5vcmRlcndpdGhpbmZpLmNvbTo0NDMiKSAgICAgICAgICAgICAgICAgLy9kZXYNCiAgICBvcy5TZXRlbnYoIkNBVEFMT0dfVFJBTlNfUlBDX1VSTCIsICJ0bHM6Ly9jYXRhbG9nLXRyYW5zLWdycGMuZGV2Lm9yZGVyd2l0aGluZmkuY29tOjQ0MyIpICAgICAvL2Rldg0KICAgIG9zLlNldGVudigiU1FVQVJFX1JQQ19VUkwiLCAidGxzOi8vc3F1YXJlLWdycGMuZGV2Lm9yZGVyd2l0aGluZmkuY29tOjQ0MyIpICAgICAgICAgICAgICAgICAgIC8vZGV2DQogICAgb3MuU2V0ZW52KCJMSUdIVFNQRUVEX1JQQ19VUkwiLCAidGxzOi8vbGlnaHRzcGVlZC1ncnBjLmRldi5vcmRlcndpdGhpbmZpLmNvbTo0NDMiKSAgICAgICAgICAgLy9kZXYNCiAgICBvcy5TZXRlbnYoIlRPQVNUX1JQQ19VUkwiLCAidGxzOi8vdG9hc3QtZ3JwYy5kZXYub3JkZXJ3aXRoaW5maS5jb206NDQzIikgICAgICAgICAgICAgICAgICAgICAvL2Rldg0KICAgIG9zLlNldGVudigiQ0xPVkVSX1JQQ19VUkwiLCAidGxzOi8vY2xvdmVyLWdycGMuZGV2Lm9yZGVyd2l0aGluZmkuY29tOjQ0MyIpICAgICAgICAgICAgICAgICAgIC8vZGV2DQogICAgb3MuU2V0ZW52KCJEQVRBX0NFTlRFUl9SUENfVVJMIiwgInRsczovL2RhdGEtY2VudGVyLWdycGMuZGV2Lm9yZGVyd2l0aGluZmkuY29tOjQ0MyIpICAgICAgICAgLy9kZXYNCiAgICBvcy5TZXRlbnYoIlRISVJEX1BBUlRZX1JQQ19VUkwiLCAidGxzOi8vdGhpcmQtcGFydHktZ3JwYy5kZXYub3JkZXJ3aXRoaW5maS5jb206NDQzIikgICAgICAgICAvL2Rldg0KICAgIG9zLlNldGVudigiQVVUSFpfUlBDX1VSTCIsICJ0bHM6Ly9hdXRobnotZ3JwYy5kZXYub3JkZXJ3aXRoaW5maS5jb206NDQzIikgICAgICAgICAgICAgICAgICAgIC8vZGV2DQogICAgb3MuU2V0ZW52KCJIVU5HRVJfUlVTSF9SUENfVVJMIiwgInRsczovL2h1bmdlcnJ1c2gtZ3JwYy5kZXYub3JkZXJ3aXRoaW5maS5jb206NDQzIikgICAgICAgICAgLy9kZXYNCiAgICBvcy5TZXRlbnYoIlBBWU1FTlRfUlBDX1VSTCIsICJ0bHM6Ly9wYXltZW50LWdycGMuZGV2Lm9yZGVyd2l0aGluZmkuY29tOjQ0MyIpICAgICAgICAgICAgICAgICAvL2Rldg0KICAgIG9zLlNldGVudigiTVNHSU5HX0JST0tFUl9HUlBDX1VSTCIsICJ0bHM6Ly9tc2dpbmctYnJva2VyLWdycGMuZGV2Lm9yZGVyd2l0aGluZmkuY29tOjQ0MyIpICAgIC8vZGV2DQogICAgb3MuU2V0ZW52KCJNRU5VX1NZTkNfUlBDX1VSTCIsICJ0bHM6Ly9tZW51LXN5bmMtZ3JwYy5kZXYub3JkZXJ3aXRoaW5maS5jb206NDQzIikgICAgICAgICAgICAgLy9kZXYNCiAgICAvL1BPUyBFTlYNCiAgICBvcy5TZXRlbnYoIkhVTkdFUlJVU0hfQkFTRV9VUkwiLCAiaHR0cHM6Ly9jbG91ZGFwaS5odW5nZXJydXNoLmNvbSIpIC8vZGV2DQogICAgb3MuU2V0ZW52KCJIVU5HRVJSVVNIX0FVVEhfVVJMIiwgImh0dHBzOi8vbG9naW4ubWljcm9zb2Z0b25saW5lLmNvbS9iYjRiZTJjMS03MDcxLTQzZTAtOWExYS1hZGNhNjU5Yzg2NjEvb2F1dGgyL3YyLjAvdG9rZW4iKSAvL2Rldg0KICAgIG9zLlNldGVudigiSFVOR0VSUlVTSF9DTElFTlRfSUQiLCAiOWE0OWQ2YWEtMDkzYy00OTY1LTg2MTgtY2RkNzc4NmE2ZTc5IikgLy9kZXYNCiAgICBvcy5TZXRlbnYoIkhVTkdFUlJVU0hfQ0xJRU5UX1NFQ1JFVCIsICJJOGs4UX5BZHhGWkFKWmlueGJtLmouOXJZZkxhb1RoQXQ3dlRNYlFPIikgLy9kZXYNCiAgICBvcy5TZXRlbnYoIkhVTkdFUlJVU0hfU0NPUEUiLCAiYXBpOi8vMjFmYjIyZTEtNzA0NC00MjJiLWEyZTMtNDJjOTkyNTc3OTEwLy5kZWZhdWx0IikgLy9kZXYNCn0NCg0KOjo/b3Muc2V0IHN0YWdpbmc9ew0KICAgIC8vdG9kbyBmb3IgdGVzdCBbc3RhZ2luZ10NCiAgICAvL2RhdGFic2UNCiAgICBvcy5TZXRlbnYoIlBTUUxfSE9TVCIsICJwZ20tMmV2YWI0OTk3NGQzMTdpMHZvLnBnLnJkcy5hbGl5dW5jcy5jb20iKSAvL3N0YWdpbmcNCiAgICBvcy5TZXRlbnYoIlBTUUxfUE9SVCIsICI1NDMyIikgLy9zdGFnaW5nDQogICAgb3MuU2V0ZW52KCJQU1FMX1VTRVIiLCAiaW5maV9kYmFfZGV2IikgLy9zdGFnaW5nDQogICAgb3MuU2V0ZW52KCJQU1FMX1BBU1NXT1JEIiwgInBhc3M0UGFzcyIpIC8vc3RhZ2luZw0KICAgIG9zLlNldGVudigiUFNRTF9EQVRBQkFTRSIsICJpbmZpLWRldiIpIC8vc3RhZ2luZw0KICAgIC8vZ3JwYw0KICAgIG9zLlNldGVudigiTUVSQ0hBTlRfUlBDX1VSTCIsICJ0bHM6Ly9tZXJjaGFudC1wb3J0YWwtZ3JwYy5zdGFnaW5nLm9yZGVyd2l0aGluZmkuY29tOjQ0MyIpICAgICAgICAvL3N0YWdpbmcNCiAgICBvcy5TZXRlbnYoIk1FUkNIQU5UX1BPUlRBTF9SUENfVVJMIiwgInRsczovL21lcmNoYW50LXBvcnRhbC1ncnBjLnN0YWdpbmcub3JkZXJ3aXRoaW5maS5jb206NDQzIikgLy9zdGFnaW5nDQogICAgb3MuU2V0ZW52KCJPUkRFUl9SUENfVVJMIiwgInRsczovL29yZGVyLWdycGMuc3RhZ2luZy5vcmRlcndpdGhpbmZpLmNvbTo0NDMiKSAgICAgICAgICAgICAgICAgICAgIC8vc3RhZ2luZw0KICAgIG9zLlNldGVudigiQ0FUQUxPR19SUENfVVJMIiwgInRsczovL2NhdGFsb2ctZ3JwYy5zdGFnaW5nLm9yZGVyd2l0aGluZmkuY29tOjQ0MyIpICAgICAgICAgICAgICAgICAvL3N0YWdpbmcNCiAgICBvcy5TZXRlbnYoIkNBVEFMT0dfVFJBTlNfUlBDX1VSTCIsICJ0bHM6Ly9jYXRhbG9nLXRyYW5zLWdycGMuc3RhZ2luZy5vcmRlcndpdGhpbmZpLmNvbTo0NDMiKSAgICAgLy9zdGFnaW5nDQogICAgb3MuU2V0ZW52KCJTUVVBUkVfUlBDX1VSTCIsICJ0bHM6Ly9zcXVhcmUtZ3JwYy5zdGFnaW5nLm9yZGVyd2l0aGluZmkuY29tOjQ0MyIpICAgICAgICAgICAgICAgICAgIC8vc3RhZ2luZw0KICAgIG9zLlNldGVudigiTElHSFRTUEVFRF9SUENfVVJMIiwgInRsczovL2xpZ2h0c3BlZWQtZ3JwYy5zdGFnaW5nLm9yZGVyd2l0aGluZmkuY29tOjQ0MyIpICAgICAgICAgICAvL3N0YWdpbmcNCiAgICBvcy5TZXRlbnYoIlRPQVNUX1JQQ19VUkwiLCAidGxzOi8vdG9hc3QtZ3JwYy5zdGFnaW5nLm9yZGVyd2l0aGluZmkuY29tOjQ0MyIpICAgICAgICAgICAgICAgICAgICAgLy9zdGFnaW5nDQogICAgb3MuU2V0ZW52KCJDTE9WRVJfUlBDX1VSTCIsICJ0bHM6Ly9jbG92ZXItZ3JwYy5zdGFnaW5nLm9yZGVyd2l0aGluZmkuY29tOjQ0MyIpICAgICAgICAgICAgICAgICAgIC8vc3RhZ2luZw0KICAgIG9zLlNldGVudigiREFUQV9DRU5URVJfUlBDX1VSTCIsICJ0bHM6Ly9kYXRhLWNlbnRlci1ncnBjLnN0YWdpbmcub3JkZXJ3aXRoaW5maS5jb206NDQzIikgICAgICAgICAvL3N0YWdpbmcNCiAgICBvcy5TZXRlbnYoIlRISVJEX1BBUlRZX1JQQ19VUkwiLCAidGxzOi8vdGhpcmQtcGFydHktZ3JwYy5zdGFnaW5nLm9yZGVyd2l0aGluZmkuY29tOjQ0MyIpICAgICAgICAgLy9zdGFnaW5nDQogICAgb3MuU2V0ZW52KCJBVVRIWl9SUENfVVJMIiwgInRsczovL2F1dGhuei1ncnBjLnN0YWdpbmcub3JkZXJ3aXRoaW5maS5jb206NDQzIikgICAgICAgICAgICAgICAgICAgIC8vc3RhZ2luZw0KICAgIG9zLlNldGVudigiSFVOR0VSX1JVU0hfUlBDX1VSTCIsICJ0bHM6Ly9odW5nZXJydXNoLWdycGMuc3RhZ2luZy5vcmRlcndpdGhpbmZpLmNvbTo0NDMiKSAgICAgICAgICAvL3N0YWdpbmcNCiAgICBvcy5TZXRlbnYoIlBBWU1FTlRfUlBDX1VSTCIsICJ0bHM6Ly9wYXltZW50LWdycGMuc3RhZ2luZy5vcmRlcndpdGhpbmZpLmNvbTo0NDMiKSAgICAgICAgICAgICAgICAgLy9zdGFnaW5nDQogICAgb3MuU2V0ZW52KCJNU0dJTkdfQlJPS0VSX0dSUENfVVJMIiwgInRsczovL21zZ2luZy1icm9rZXItZ3JwYy5zdGFnaW5nLm9yZGVyd2l0aGluZmkuY29tOjQ0MyIpICAgIC8vc3RhZ2luZw0KICAgIG9zLlNldGVudigiTUVOVV9TWU5DX1JQQ19VUkwiLCAidGxzOi8vbWVudS1zeW5jLWdycGMuc3RhZ2luZy5vcmRlcndpdGhpbmZpLmNvbTo0NDMiKSAgICAgICAgICAgICAvL3N0YWdpbmcNCiAgICAvL2hyIGNsaWVudA0KICAgIG9zLlNldGVudigiSFVOR0VSUlVTSF9CQVNFX1VSTCIsICJodHRwczovL2Nsb3VkYXBpLmh1bmdlcnJ1c2guY29tIikgLy9zdGFnaW5nDQogICAgb3MuU2V0ZW52KCJIVU5HRVJSVVNIX0FVVEhfVVJMIiwgImh0dHBzOi8vbG9naW4ubWljcm9zb2Z0b25saW5lLmNvbS9iYjRiZTJjMS03MDcxLTQzZTAtOWExYS1hZGNhNjU5Yzg2NjEvb2F1dGgyL3YyLjAvdG9rZW4iKSAvL3N0YWdpbmcNCiAgICBvcy5TZXRlbnYoIkhVTkdFUlJVU0hfQ0xJRU5UX0lEIiwgIjlhNDlkNmFhLTA5M2MtNDk2NS04NjE4LWNkZDc3ODZhNmU3OSIpIC8vc3RhZ2luZw0KICAgIG9zLlNldGVudigiSFVOR0VSUlVTSF9DTElFTlRfU0VDUkVUIiwgIkk4azhRfkFkeEZaQUpaaW54Ym0uai45cllmTGFvVGhBdDd2VE1iUU8iKSAvL3N0YWdpbmcNCiAgICBvcy5TZXRlbnYoIkhVTkdFUlJVU0hfU0NPUEUiLCAiYXBpOi8vMjFmYjIyZTEtNzA0NC00MjJiLWEyZTMtNDJjOTkyNTc3OTEwLy5kZWZhdWx0IikgLy9zdGFnaW5nDQp9DQoNCjo6P29zLnNldCBzdGFnZT17DQogICAgLy90b2RvIGZvciB0ZXN0IFtzdGFnZV0NCiAgICAvL2RhdGFic2UNCiAgICBvcy5TZXRlbnYoIlBTUUxfSE9TVCIsICJwZ20tMmV2amt0NjY4Ym03cWU3N2ZvLnBnLnJkcy1hbGl5dW4tYW1lcmljYS5yZHMuYWxpeXVuY3MuY29tIikgLy9zdGFnZQ0KICAgIG9zLlNldGVudigiUFNRTF9QT1JUIiwgIjU0MzIiKSAvL3N0YWdlDQogICAgb3MuU2V0ZW52KCJQU1FMX1VTRVIiLCAic2hlbmd6aGlfdCIpIC8vc3RhZ2UNCiAgICBvcy5TZXRlbnYoIlBTUUxfUEFTU1dPUkQiLCAiNiRVams5MCIpIC8vc3RhZ2UNCiAgICBvcy5TZXRlbnYoIlBTUUxfREFUQUJBU0UiLCAidW5pY29ybl9zdGFnaW5nIikgLy9zdGFnZQ0KICAgIGNvbnN0IHBzcWxUTFNCYXNlID0gYEU6XGRldlxjZXJ0YCAvL3N0YWdlDQogICAgb3MuU2V0ZW52KCJQU1FMX1RMU19DQV9DRVJUX1BBVEgiLCBmaWxlcGF0aC5Kb2luKHBzcWxUTFNCYXNlLCAic2VydmVyLWNhLmNydCIpKSAvL3N0YWdlDQogICAgb3MuU2V0ZW52KCJQU1FMX1RMU19DRVJUX1BBVEgiLCBmaWxlcGF0aC5Kb2luKHBzcWxUTFNCYXNlLCAic2hlbmd6aGlfdC5jcnQiKSkgLy9zdGFnZQ0KICAgIG9zLlNldGVudigiUFNRTF9UTFNfS0VZX1BBVEgiLCBmaWxlcGF0aC5Kb2luKHBzcWxUTFNCYXNlLCAic2hlbmd6aGlfdC5rZXkiKSkgLy9zdGFnZQ0KICAgIG9zLlNldGVudigiUFNRTF9UTFNfTU9ERSIsICJ2ZXJpZnktY2EiKSAgLy9zdGFnZQ0KICAgIC8vZ3JwYw0KICAgIG9zLlNldGVudigiTUVSQ0hBTlRfUlBDX1VSTCIsICJ0bHM6Ly9tZXJjaGFudC1wb3J0YWwtZ3JwYy5zdGFnZS5vcmRlcndpdGhpbmZpLmNvbTo0NDMiKSAgICAgICAgLy9zdGFnZQ0KICAgIG9zLlNldGVudigiTUVSQ0hBTlRfUE9SVEFMX1JQQ19VUkwiLCAidGxzOi8vbWVyY2hhbnQtcG9ydGFsLWdycGMuc3RhZ2Uub3JkZXJ3aXRoaW5maS5jb206NDQzIikgLy9zdGFnZQ0KICAgIG9zLlNldGVudigiT1JERVJfUlBDX1VSTCIsICJ0bHM6Ly9vcmRlci1ncnBjLnN0YWdlLm9yZGVyd2l0aGluZmkuY29tOjQ0MyIpICAgICAgICAgICAgICAgICAgICAgLy9zdGFnZQ0KICAgIG9zLlNldGVudigiQ0FUQUxPR19SUENfVVJMIiwgInRsczovL2NhdGFsb2ctZ3JwYy5zdGFnZS5vcmRlcndpdGhpbmZpLmNvbTo0NDMiKSAgICAgICAgICAgICAgICAgLy9zdGFnZQ0KICAgIG9zLlNldGVudigiQ0FUQUxPR19UUkFOU19SUENfVVJMIiwgInRsczovL2NhdGFsb2ctdHJhbnMtZ3JwYy5zdGFnZS5vcmRlcndpdGhpbmZpLmNvbTo0NDMiKSAgICAgLy9zdGFnZQ0KICAgIG9zLlNldGVudigiU1FVQVJFX1JQQ19VUkwiLCAidGxzOi8vc3F1YXJlLWdycGMuc3RhZ2Uub3JkZXJ3aXRoaW5maS5jb206NDQzIikgICAgICAgICAgICAgICAgICAgLy9zdGFnZQ0KICAgIG9zLlNldGVudigiTElHSFRTUEVFRF9SUENfVVJMIiwgInRsczovL2xpZ2h0c3BlZWQtZ3JwYy5zdGFnZS5vcmRlcndpdGhpbmZpLmNvbTo0NDMiKSAgICAgICAgICAgLy9zdGFnZQ0KICAgIG9zLlNldGVudigiVE9BU1RfUlBDX1VSTCIsICJ0bHM6Ly90b2FzdC1ncnBjLnN0YWdlLm9yZGVyd2l0aGluZmkuY29tOjQ0MyIpICAgICAgICAgICAgICAgICAgICAgLy9zdGFnZQ0KICAgIG9zLlNldGVudigiQ0xPVkVSX1JQQ19VUkwiLCAidGxzOi8vY2xvdmVyLWdycGMuc3RhZ2Uub3JkZXJ3aXRoaW5maS5jb206NDQzIikgICAgICAgICAgICAgICAgICAgLy9zdGFnZQ0KICAgIG9zLlNldGVudigiREFUQV9DRU5URVJfUlBDX1VSTCIsICJ0bHM6Ly9kYXRhLWNlbnRlci1ncnBjLnN0YWdlLm9yZGVyd2l0aGluZmkuY29tOjQ0MyIpICAgICAgICAgLy9zdGFnZQ0KICAgIG9zLlNldGVudigiVEhJUkRfUEFSVFlfUlBDX1VSTCIsICJ0bHM6Ly90aGlyZC1wYXJ0eS1ncnBjLnN0YWdlLm9yZGVyd2l0aGluZmkuY29tOjQ0MyIpICAgICAgICAgLy9zdGFnZQ0KICAgIG9zLlNldGVudigiQVVUSFpfUlBDX1VSTCIsICJ0bHM6Ly9hdXRobnotZ3JwYy5zdGFnZS5vcmRlcndpdGhpbmZpLmNvbTo0NDMiKSAgICAgICAgICAgICAgICAgICAgLy9zdGFnZQ0KICAgIG9zLlNldGVudigiSFVOR0VSX1JVU0hfUlBDX1VSTCIsICJ0bHM6Ly9odW5nZXJydXNoLWdycGMuc3RhZ2Uub3JkZXJ3aXRoaW5maS5jb206NDQzIikgICAgICAgICAgLy9zdGFnZQ0KICAgIG9zLlNldGVudigiUEFZTUVOVF9SUENfVVJMIiwgInRsczovL3BheW1lbnQtZ3JwYy5zdGFnZS5vcmRlcndpdGhpbmZpLmNvbTo0NDMiKSAgICAgICAgICAgICAgICAgLy9zdGFnZQ0KICAgIG9zLlNldGVudigiTVNHSU5HX0JST0tFUl9HUlBDX1VSTCIsICJ0bHM6Ly9tc2dpbmctYnJva2VyLWdycGMuc3RhZ2Uub3JkZXJ3aXRoaW5maS5jb206NDQzIikgICAgLy9zdGFnZQ0KICAgIG9zLlNldGVudigiTUVOVV9TWU5DX1JQQ19VUkwiLCAidGxzOi8vbWVudS1zeW5jLWdycGMuc3RhZ2Uub3JkZXJ3aXRoaW5maS5jb206NDQzIikgICAgICAgICAgICAgLy9zdGFnZQ0KICAgIC8vaHIgY2xpZW50DQogICAgb3MuU2V0ZW52KCJIVU5HRVJSVVNIX0JBU0VfVVJMIiwgImh0dHBzOi8vY2xvdWRhcGkuaHVuZ2VycnVzaC5jb20iKSAvL3N0YWdlDQogICAgb3MuU2V0ZW52KCJIVU5HRVJSVVNIX0FVVEhfVVJMIiwgImh0dHBzOi8vbG9naW4ubWljcm9zb2Z0b25saW5lLmNvbS9iYjRiZTJjMS03MDcxLTQzZTAtOWExYS1hZGNhNjU5Yzg2NjEvb2F1dGgyL3YyLjAvdG9rZW4iKSAvL3N0YWdlDQogICAgb3MuU2V0ZW52KCJIVU5HRVJSVVNIX0NMSUVOVF9JRCIsICI5YTQ5ZDZhYS0wOTNjLTQ5NjUtODYxOC1jZGQ3Nzg2YTZlNzkiKSAvL3N0YWdlDQogICAgb3MuU2V0ZW52KCJIVU5HRVJSVVNIX0NMSUVOVF9TRUNSRVQiLCAiSThrOFF+QWR4RlpBSlppbnhibS5qLjlyWWZMYW9UaEF0N3ZUTWJRTyIpIC8vc3RhZ2UNCiAgICBvcy5TZXRlbnYoIkhVTkdFUlJVU0hfU0NPUEUiLCAiYXBpOi8vMjFmYjIyZTEtNzA0NC00MjJiLWEyZTMtNDJjOTkyNTc3OTEwLy5kZWZhdWx0IikgLy9zdGFnZQ0KfQ0KDQo6Oj9vcy5zZXQgcHJvZD17DQogICAgLy90b2RvIGZvciB0ZXN0IFtwcm9kXQ0KICAgIC8vZGF0YWJzZQ0KICAgIG9zLlNldGVudigiUFNRTF9IT1NUIiwgInBnbS0yZXYxc3ByZmgyNGcwNXcwam8ucGcucmRzLmFsaXl1bmNzLmNvbSIpIC8vcHJvZA0KICAgIG9zLlNldGVudigiUFNRTF9QT1JUIiwgIjU0MzIiKSAvL3Byb2QNCiAgICBvcy5TZXRlbnYoIlBTUUxfVVNFUiIsICJhcHBfdXNlcjAwMSIpIC8vcHJvZA0KICAgIG9zLlNldGVudigiUFNRTF9QQVNTV09SRCIsICI5dTgzcXJKZGtXcSIpIC8vcHJvZA0KICAgIG9zLlNldGVudigiUFNRTF9EQVRBQkFTRSIsICJ1bmljb3JuIikgLy9wcm9kDQogICAgLy9ncnBjDQogICAgb3MuU2V0ZW52KCJNRVJDSEFOVF9SUENfVVJMIiwgInRsczovL21lcmNoYW50LXBvcnRhbC1ncnBjLnByb2Qub3JkZXJ3aXRoaW5maS5jb206NDQzIikgICAgICAgIC8vcHJvZA0KICAgIG9zLlNldGVudigiTUVSQ0hBTlRfUE9SVEFMX1JQQ19VUkwiLCAidGxzOi8vbWVyY2hhbnQtcG9ydGFsLWdycGMucHJvZC5vcmRlcndpdGhpbmZpLmNvbTo0NDMiKSAvL3Byb2QNCiAgICBvcy5TZXRlbnYoIk9SREVSX1JQQ19VUkwiLCAidGxzOi8vb3JkZXItZ3JwYy5wcm9kLm9yZGVyd2l0aGluZmkuY29tOjQ0MyIpICAgICAgICAgICAgICAgICAgICAgLy9wcm9kDQogICAgb3MuU2V0ZW52KCJDQVRBTE9HX1JQQ19VUkwiLCAidGxzOi8vY2F0YWxvZy1ncnBjLnByb2Qub3JkZXJ3aXRoaW5maS5jb206NDQzIikgICAgICAgICAgICAgICAgIC8vcHJvZA0KICAgIG9zLlNldGVudigiQ0FUQUxPR19UUkFOU19SUENfVVJMIiwgInRsczovL2NhdGFsb2ctdHJhbnMtZ3JwYy5wcm9kLm9yZGVyd2l0aGluZmkuY29tOjQ0MyIpICAgICAvL3Byb2QNCiAgICBvcy5TZXRlbnYoIlNRVUFSRV9SUENfVVJMIiwgInRsczovL3NxdWFyZS1ncnBjLnByb2Qub3JkZXJ3aXRoaW5maS5jb206NDQzIikgICAgICAgICAgICAgICAgICAgLy9wcm9kDQogICAgb3MuU2V0ZW52KCJMSUdIVFNQRUVEX1JQQ19VUkwiLCAidGxzOi8vbGlnaHRzcGVlZC1ncnBjLnByb2Qub3JkZXJ3aXRoaW5maS5jb206NDQzIikgICAgICAgICAgIC8vcHJvZA0KICAgIG9zLlNldGVudigiVE9BU1RfUlBDX1VSTCIsICJ0bHM6Ly90b2FzdC1ncnBjLnByb2Qub3JkZXJ3aXRoaW5maS5jb206NDQzIikgICAgICAgICAgICAgICAgICAgICAvL3Byb2QNCiAgICBvcy5TZXRlbnYoIkNMT1ZFUl9SUENfVVJMIiwgInRsczovL2Nsb3Zlci1ncnBjLnByb2Qub3JkZXJ3aXRoaW5maS5jb206NDQzIikgICAgICAgICAgICAgICAgICAgLy9wcm9kDQogICAgb3MuU2V0ZW52KCJEQVRBX0NFTlRFUl9SUENfVVJMIiwgInRsczovL2RhdGEtY2VudGVyLWdycGMucHJvZC5vcmRlcndpdGhpbmZpLmNvbTo0NDMiKSAgICAgICAgIC8vcHJvZA0KICAgIG9zLlNldGVudigiVEhJUkRfUEFSVFlfUlBDX1VSTCIsICJ0bHM6Ly90aGlyZC1wYXJ0eS1ncnBjLnByb2Qub3JkZXJ3aXRoaW5maS5jb206NDQzIikgICAgICAgICAvL3Byb2QNCiAgICBvcy5TZXRlbnYoIkFVVEhaX1JQQ19VUkwiLCAidGxzOi8vYXV0aG56LWdycGMucHJvZC5vcmRlcndpdGhpbmZpLmNvbTo0NDMiKSAgICAgICAgICAgICAgICAgICAgLy9wcm9kDQogICAgb3MuU2V0ZW52KCJIVU5HRVJfUlVTSF9SUENfVVJMIiwgInRsczovL2h1bmdlcnJ1c2gtZ3JwYy5wcm9kLm9yZGVyd2l0aGluZmkuY29tOjQ0MyIpICAgICAgICAgIC8vcHJvZA0KICAgIG9zLlNldGVudigiUEFZTUVOVF9SUENfVVJMIiwgInRsczovL3BheW1lbnQtZ3JwYy5wcm9kLm9yZGVyd2l0aGluZmkuY29tOjQ0MyIpICAgICAgICAgICAgICAgICAvL3Byb2QNCiAgICBvcy5TZXRlbnYoIk1TR0lOR19CUk9LRVJfR1JQQ19VUkwiLCAidGxzOi8vbXNnaW5nLWJyb2tlci1ncnBjLnByb2Qub3JkZXJ3aXRoaW5maS5jb206NDQzIikgICAgLy9wcm9kDQogICAgb3MuU2V0ZW52KCJNRU5VX1NZTkNfUlBDX1VSTCIsICJ0bHM6Ly9tZW51LXN5bmMtZ3JwYy5wcm9kLm9yZGVyd2l0aGluZmkuY29tOjQ0MyIpICAgICAgICAgICAgIC8vcHJvZA0KICAgIC8vUE9TIEVOVg0KICAgIG9zLlNldGVudigiSFVOR0VSUlVTSF9CQVNFX1VSTCIsICJodHRwczovL2Nsb3VkYXBpLmh1bmdlcnJ1c2guY29tIikgLy9wcm9kDQogICAgb3MuU2V0ZW52KCJIVU5HRVJSVVNIX0FVVEhfVVJMIiwgImh0dHBzOi8vbG9naW4ubWljcm9zb2Z0b25saW5lLmNvbS9iYjRiZTJjMS03MDcxLTQzZTAtOWExYS1hZGNhNjU5Yzg2NjEvb2F1dGgyL3YyLjAvdG9rZW4iKSAvL3Byb2QNCiAgICBvcy5TZXRlbnYoIkhVTkdFUlJVU0hfQ0xJRU5UX0lEIiwgIjlhNDlkNmFhLTA5M2MtNDk2NS04NjE4LWNkZDc3ODZhNmU3OSIpIC8vcHJvZA0KICAgIG9zLlNldGVudigiSFVOR0VSUlVTSF9DTElFTlRfU0VDUkVUIiwgIkk4azhRfkFkeEZaQUpaaW54Ym0uai45cllmTGFvVGhBdDd2VE1iUU8iKSAvL3Byb2QNCiAgICBvcy5TZXRlbnYoIkhVTkdFUlJVU0hfU0NPUEUiLCAiYXBpOi8vMjFmYjIyZTEtNzA0NC00MjJiLWEyZTMtNDJjOTkyNTc3OTEwLy5kZWZhdWx0IikgLy9wcm9kDQp9DQoNCg0KSQBDADEA"

