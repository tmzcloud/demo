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
#SingleInstance force
;#Requires AutoHotkey 64-bit
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
imageutil.changetrayIcon("icon1") ;①初始化图标
init.createTaskBarMenu() ;②.创建任务栏菜单
init.initAll()           ;③.初始化环境变量和文件夹
ak.seticonTip("翻译&ocr：ctrl+1",2) ;④.设置提示
init.onStartup()         ;⑤.设置缓存连接cmd等
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
        recent.show()
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
;[@getIco-CB747C07A3FB4A31B5FCBE475DE40C85]
;获取图片或者ico等的base64编码  托盘图标：24x24
getIco(icoName)
{
    static obj:={
       ;加载动画 png
       loadGif:"
               ( LTrim Join
                 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AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
                )"
       ;初始图标 png
      ,icon1:"
              ( LTrim Join
                iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAACXBIWXMAAA7EAAAOxAGVKw4bAAACUklEQVQ4y22Ry2udVRTFf2ufcxMfoCDqQB35aFUwtCLOJOrEuVikKE5Do6DoyL9ArFMNhYsTxYEiDkQQFEQLFoSqVWIkCKIdFNHUZ9Le3PudvRx83y3RZsGGs89Ze5+19hYD3rn7CLfmzVWmqpF/lsn04c0TAHywdIxbLl6xYBOdW/f91X90T337JgACOH3wWF306Mma5WnMAcPvKb/XjfKlJHOxqy9Wx6O2r0/8YyvttVltb9y7sTbVqdtW4poYvbxAfb64hiwwNJIseabhbsFxXzgASExTy065dlGzZ+tVpT5YXZ4r1CguhIUNIZGpQxUoFGQhIEmEQtlWXfRhrY6VolpLBpHqiRZIhGKYUK9KFiFwCFCMnCt1RCyFhXIIhqLBiodBieHsoDhBopilSEjNGRJ7IUxgsPfc9VHoLUXDZ2wPPxn+1wKEhsZzFSnTlOyW7qtI57iRmTIZiZWXtZnDGEeSMl10+U/dHUeLPNnR3k11ZPQE1CvyXLqHYvXvLRo7dfb++dj+SABf37F605Uafbbgenu4EBmoBZeE2xDGSrpo7NTdn86PJsvL6+OzAXD4h7VzM7WjM+UvVvZWSi+1l21SSaoxKdOt7bL7xPL6+Cww3xncs/nq6d3SHp+q+zXVyGgQiaPh6PPtOt36rV44+tb0k1PzurJ3SDduffHzwRvuPyl4JNC1KV3yvVNn5/6uk8c+5vNPj29u/mdPl+GbO585sNjq25U4BHChzDb+KpMjD3w33mCfRe+LL+9ava64vjJTq9tl8sJD669v7cf7FyA9OlKNwUFpAAAAAElFTkSuQmCC
               )"
       ;有网络时的图标 png
      ,icon2:"
              ( LTrim Join
                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
               )"
       ;鼠标右键recent ico
       ,icon2RC:"
              ( LTrim Join
                AAABAAEAEBAAAAEAIABoBAAAFgAAACgAAAAQAAAAIAAAAAEAIAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAB4INcIeSPTzXki1HJ4INcEeSLUg3ki1K15IdUSeSLURnoj09t5IdUkAAAAAAAAAAAAAAAAAAAAAAAAAAB5IdUkeSLVSHoj1P95I9SxeSLVRHki1MN6I9TZeiPUWHki1Id6I9T/eiPUcHkh1SQAAAAAAAAAAAAAAAB6ItUceiPU/3oj1P96I9P/eiPT/3oj0/96I9P/eiPT/3oj0/96I9P/eiPT/3oj1P96I9T/eyPTOAAAAAB6ItUceiPUSHoi1P96ItT/eiPT/3oj0/96I9P/eiPT/3oj0/96I9P/eiPT/3oj0/96I9T/eiPU/3oi1HB8JNMOeSPTzXoj1P96I9T/eiPU/4Ev1v+TTdz/eiPU/4g72P+MQdr/eiPU/3oj1P96I9T/eiPU/3oj1P96I9T/eiPU6Xki1EZ5ItSVeiPU/3oj1P+XU93/3cf0/3oj1P+teOT/wJbq/3oj1P96I9T/eiPU/3oj1P96I9T/eiPTq3oj01x6ItUOeyPTOHoj1P96I9T/mVbe/+bW9/96I9T/rXjk/9a78v+FNdf/eiPU/3oj1P96I9T/eiPU/3oi1GJ8JNMIeSLUnXoj1Md6I9T/eiPU/4o+2f/fyvX/qnLj/4xB2f/dyPT/z6/v/4g72P96I9T/eiPU/3oj1P96I9PVeiPTsXki1IN5ItTJeiPU/3oj1P96I9T/iDvY/+bX9//QsvD/jEHa/8CX6v/j0fb/jkTa/3oj1P96I9T/eiPT1Xoj06N4INcEeiLUPHoj1P96I9T/eiPU/3oj1P+ORNr/2L7y/7iK6P99KdX/28Tz/6Rp4f96I9T/eiPU/3oi1GJ8JNMIeSLUYnoj1I96I9T/eiPU/3oj1P96I9T/eiPU/6py4//Alur/eiPU/8mm7f+gY+D/eiPU/3oj1P96I9OreiPTXHkj1Md6I9T/eiPU/3oj1P96I9T/eiPU/3oj1P+FNdf/jEHa/3oj1P+ORNr/gzLX/3oj1P96I9T/eiPU/3oj1Ol4INcIeiLUTnoi1P96ItT/eiPT/3oj0/96I9P/eiPT/3oj0/96I9P/eiPT/3oj0/96I9T/eiPU/3oi1HB8JNMOAAAAAHwk0w56I9TxeiPU/3oj0/96I9P/eiPT/3oj0/96I9P/eiPT/3oj0/96I9P/eiPU/3oj1P97I9M4AAAAAAAAAAAAAAAAeSHVJHoi1U56I9T/eSPUsXoi1EZ6ItTHeiPU2Xoj1Fh6ItSNeiPU/3oj1HB7I9MyAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAeSPT23oj04EAAAAAeSPUjXoj07V7I9MYeSPURnkj1ON7I9MyAAAAAAAAAAAAAAAA9m8AAPJPAADAAwAAwAMAAAAAAACAAQAAwAMAAAAAAAAAAAAAwAMAAIABAAAAAAAAwAMAAMADAADyTwAA8m8AAA==
              )"
       ;暂停时图标 png
      ,icon3:"
              ( LTrim Join
                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
               )"
       ;任务栏菜单-调试图标 png
      ,debug:"
              ( LTrim Join
                iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAAAXNSR0IArs4c6QAAAQtJREFUOE+1k1FOwkAQhv/Z4jvBA1ATS+IpLCeRPhYPoRxC+kg9ib2FCZi4F7DwDu5v1qRlW3aJCXEfZzLf/PPvjODCJxfWIwgYFu+xwuDBNqjzZBFqFASMlhsei6jr+eTGB/EChsUmVeTKLTAi2S5Pqj6kA7CygUGsgHtfN4PDq43v8jvd5DuA0XL9CUh81liRss5vMy/g+mU9o0hHeh9mBFN3lFbBcW5XAfWpImrXDwdgv+3qCeSslUdmVDIG8dwqESkN9ovGh44H/RHEA7Cxr8dJ6Tex+FiBJm1knwKoIaoKmmipvxvI6M1CXACBajtPpmf3oElaSGSi9FuJjgxj60Nonf/vmP56pT/gAXERCNO6rgAAAABJRU5ErkJggg==
               )"
       ;任务栏菜单-退出按钮 png
      ,exit:"
              ( LTrim Join
                iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAAAXNSR0IArs4c6QAAAUtJREFUOE+NU0FShDAQ7IF9CCsna/ENsi/Z5RfKRayy0F8svmTxD2x5Ec1DJGMNkBgCUuY2k0mnp6eH4J336C7SQXBg4hSgFIACUBNDBVq/XqsXie0hN7hc5Q9MKHxQJ1bEqHaf5aPJWYAmvj+PP668N1dcJ+3zXqIe4BLnRwZOCy8N3ci/I0YhTEh67sLgyyuQhxEBmeT/Ag87vad53wO9Js5PBLwNAHwIO866MDgLsO2fUZAUAjiaZNjprQ6DVH51GQhlmcKULdcCIPQtatKWNue1oJK23Hr1ygOw9HlkNBHRBbdteOMbf1kcaZW0ZdbEuQEXjGomotOrK5gSxQeH/hpNapfG2LtNBPvebHptbj6e6iWviOBrRrI7wNRPaWImEXjXlpVj5ek41/3sWdkU/2OZYCw8WyaT6Nd5MNItAFln8aIipnppnX8AVl3BDg87bxYAAAAASUVORK5CYII=
               )"
       ;任务栏菜单-重启按钮 png
      ,reload:"
              ( LTrim Join
                iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAAAXNSR0IArs4c6QAAAP1JREFUOE+lklFugzAQRJ/FRUCl5+jmJE1u4T/Cn28BN4nvUSLoQVpHazBNWyTc1H+WvM+zM2P45zFp3g4yAmW8G87uybc57C/AVRoC58cBg1wAiYDAwT17n63AvolguLjaG3uVZk++HaTDMOm7uELc39DvDd751alfrvaHBAh/kW0HOQIdBZWxo5R8MOrFVX7K2XtRHT99CLB+qoDVA2hd7fscBWq0Rq6mJ0A0hYJTzhpL6XC1r2bAHKNGs5tEjBCOybOtJvYUtFtKknTglNZdAYsXGk+z+OC1LATegZelpeXPuL8BIkRj/eSVEGs9Vxu01tOWsl+AnBTu39wA3RqBbuSKGVwAAAAASUVORK5CYII=
               )"
       ;任务栏菜单-暂停 png
      ,suspend:"
              ( LTrim Join
                iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAAAXNSR0IArs4c6QAAAFtJREFUOE9jZKAQMCLrf98u4MDEwBQPEmNkYDzIV/l2AYiNSxyiDgl8bBeaz8DAkAAVWsBf+S4RxMYlPmoAJKRGA3H4hQFypvnH8G+hYOWHA+iZCVkcIx2Qk7MB2cyQEWXj+ecAAAAASUVORK5CYII=
               )"
       ;任务栏菜单-自定义spy工具 png
      ,spy1:"
              ( LTrim Join
                iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAAAXNSR0IArs4c6QAAAO9JREFUOE+lk7FOwzAQhv9DcegbIOKILrSNEYgH4UGYMnSnW5GYGXkOuvcRUDuYDAgJFPMGIBmaQ5aaCEdBchtv9vn/7u73mdBzUU89OgHSqikzrkGYbBO8gvjBiOe7dkIPkPJYVt8HC4AuuypjxgvF1ZWhoqjjHiCx2dN/4lrgIB+xHoHA7qwBJDbLAboP8YQIN6XQtx7g2KoVARchADDezKEetipQXwAGQQAARugIhM2fFnYFHAnQ8qcBSKvWDJwHVvBuYn3SauEsBzjUxFkp9NwDuE2vZ3QA+XmachQ97j1Idf97j3Kggd613r/xF5sPWBF3I2Z4AAAAAElFTkSuQmCC
               )"
       ;任务栏菜单-自带spy工具 png
      ,spy2:"
              ( LTrim Join
                iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAAAXNSR0IArs4c6QAAAPdJREFUOE+tU9sRwjAMUyehnYRqEugkHJPQTRwmgVE45eyem+vjh/y0ZyuybDkdDo6ZvQB8ST73YN1Wwsx6ADcAd8/PAN4kS4tfEfhFVR1V2cHxVUwEE8mIoSX4+MUKMjMpuJKcErnUMUgWAjMzVVRmr99EsuAqgVeS9CHLO5iPlKpWCYIHgF5Sj1yJnKstcqczM11WrxpMDSag4pcmFnjBSiZQYN4gkFbZWI8XlCMa5pxbGI8GmFvzBRPxFARi1BAXe06cWA/RpdUFIjmcrPfK7rwH6qkmQ0l+C3mRcpGtVY43IFdEqqP/usrtnP77mNre81vYm8sPEdmQqTjrk9UAAAAASUVORK5CYII=
               )"
       ;任务栏菜单-阅读模式1 png
      ,read1:"
              ( LTrim Join
                iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAAAXNSR0IArs4c6QAAALFJREFUOE/tk8ENwjAMRf+XOkg2ASYpHSKReoKeKnkJyiR0E8IgkZGl9tKacgCJC746ebKT94kPiyJyARA8TimlqaoqqOrJ65PsDKAkz6r6WBzaAdhP8MYB1ADyDDjEGMflIRG5kxxijJ3Ts8nxDnADcE0pDX/Ar96g7/vQtm32JJoE3P7GLcu/DlipXEoZ5/FF5LilstnmVSDZqKoFzbRdqW6W8tWe044Wpmyp87Jid59PwKDM0m+MAQAAAABJRU5ErkJggg==
               )"
       ;任务栏菜单-阅读模式2 png
      ,read2:"
              ( LTrim Join
                iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAAAXNSR0IArs4c6QAAAMhJREFUOE/tk0sOgkAMhv8OHGQSVoZ4BvEkyi2EjZIY4i3Ak8AhMG58jPcQasZHYrDCQhM3znLa+dJ2vhI+PFR5cQawljhOzeHZdTVxPZfiTE5iAUyMBQin5yQGRgACAJqAsA1g8AQgcwUwqfFwtyzbSZUXH4mR+4c0EWKZvesBRAWB1v4+zf+AX81gq2d6YFZGkugmYM83dln+XYCksqqb8lH+xounHSpHhVwqaSYVKm40A3bhXlS3ltK7Pu89BgAbu3XSrti3F49wrlZvrESGAAAAAElFTkSuQmCC
               )"
       ;任务栏菜单-快捷ocr1 png
      ,ocr1:"
              ( LTrim Join
                iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAAAXNSR0IArs4c6QAAALtJREFUOE/dk9ERgkAMRPc6kU7cSoRKgErUSpZOsBOd1RzjzSDg4Jf545Lb7JGXhJ2R8n1JLYAuvjuS/bu2pDOAGsANwCXnnwKRPDoB4ErSRUVIOsSB69xsINlkgRFAT9ICqyHJTlqSVRa4A6jmOs+phZuRZJqeYDurraMgBOzg9YQ98S8C5uCbnxjs1B77z8ZokBqSw5aJBEh2PXFgNE2X+TeiSyiforZA2Zw7kZfJy1KAtbhMW2x/qnkAeNFgEfPNxnIAAAAASUVORK5CYII=
               )"
       ;任务栏菜单-快捷ocr2 png
      ,ocr2:"
              ( LTrim Join
                iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAAAXNSR0IArs4c6QAAAORJREFUOE/dU0sOgjAQfVMuArIy4B24iXALwwZITOMtxJtwCI0bES5Ca4aPGoKkBld2177pmzczbwgLDw3/L6s40YSU76SReneZvXOf3fgIIARQk0Y+4C1BDwYMCKVO6/pQj4Vd7Z3Nb8oSgQYSAIVfymggqAjIvFLmJhVd3DhkEr+UzkCgrUY5U5mnCFlNY4nKLyU9S2A5Jtk5pidgBV0JS86/ELAPvmki94xHyWP/2RgrTSLa3PaFyUR6I7Hqzgf9HoTsRtGoYtbKQmw1tTvxsjIbQ3VAu0wA8nFPZpfJRPanmAdCHXoRcPaWYwAAAABJRU5ErkJggg==
               )"
    }
    return obj.%icoName%
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
       setTimer ()=>recent.init(),-1 ;写入注册表右键打开最近文件
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
        current := FileGetTime(init.sysconfigPath, "M")
        if (current != init.syscConfigLastModifiedTime) {
            init.syscConfigLastModifiedTime := current
            reload
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
        tray.SetIcon("&Open","HICON: " . imageutil.Base64PNG_to_HICON(getIco("debug")))
        tray.rename("&Open","打开调试面板")
        tray.insert("&Help","ZH-文档帮助",onZhHelpmeMenu)
        tray.insert("ZH-文档帮助","阅读模式",onReadMenu)
        tray.SetIcon("阅读模式","HICON: " . imageutil.Base64PNG_to_HICON(getIco("read1")))
        tray.insert("阅读模式","快捷OCR",onOcrMenu)
        tray.SetIcon("快捷OCR","HICON: " . imageutil.Base64PNG_to_HICON(getIco("ocr1")))
        tray.rename("&Help","EN-文档帮助")
        tray.insert("&Window Spy","窗口检测my",onMyWindowSpyMenu,"Radio")
        tray.SetIcon("&Window Spy","HICON: " . imageutil.Base64PNG_to_HICON(getIco("spy2")))
        tray.rename("&Window Spy","窗口检测工具spy")
        tray.delete("&Reload Script")
        tray.delete("&Edit Script")
        tray.delete("&Pause Script")
        tray.SetIcon("&Suspend Hotkeys","HICON: " . imageutil.Base64PNG_to_HICON(getIco("suspend")))
        tray.rename("&Suspend Hotkeys","暂停")
        tray.insert("11&","重启",onrealoadMenu)
        tray.SetIcon("11&","HICON: " . imageutil.Base64PNG_to_HICON(getIco("reload")))
        tray.rename("12&","退出")
        tray.SetIcon("12&","HICON: " . imageutil.Base64PNG_to_HICON(getIco("exit")))
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
                tray.SetIcon("阅读模式","HICON: " . imageutil.Base64PNG_to_HICON(getIco("read2")))
                init.readmod:=1   ;开启阅读模式
                Tx1:=init.ocrmod?"":onOcrMenu()
            }else{
                tray.SetIcon("阅读模式","HICON: " . imageutil.Base64PNG_to_HICON(getIco("read1")))
                init.readmod:=0   ;关闭阅读模式、
                Tx1:=init.ocrmod?onOcrMenu():""
             }
            counter2+=1
        }
        onOcrMenu(*) ;开启xbutton2快捷识图
        {
            static counter3:=0
            if mod(counter3,2)==0 {
                tray.SetIcon("快捷OCR","HICON: " . imageutil.Base64PNG_to_HICON(getIco("ocr2")))
                init.ocrmod:=1  ;开启阅读模式
            }else{
                tray.SetIcon("快捷OCR","HICON: " . imageutil.Base64PNG_to_HICON(getIco("ocr1")))
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
            A_TrayMenu.SetIcon("窗口检测my","HICON: " . imageutil.Base64PNG_to_HICON(getIco("spy1")))
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
                code64path:=ak.getBase64(f:=Trim(Trim(Ltrim(rawstr,"base64")),'"'))
                loop
                    sleep 50
                until  fileExist(code64path) or A_index>200
                newCode64:=strReplace(strReplace(strReplace(fileRead(code64path),"`r`n",""),'-----END CERTIFICATE-----',""),'-----BEGIN CERTIFICATE-----',"")
                fileAppend newCode64 ,code64path2:=(subStr(code64path,1,strlen(code64path)-4) . "_2.txt")
                ak.shellExcuter(code64path2)
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
            waitLoadHtml:=Format(this.waithtml,this.background_color,getIco("loadGif"))
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
      ;传入的base64必须是png转换来的！转换base64字符串为ico图标，示例:TraySetIcon('HICON: ' . Base64PNG_to_HICON(Base64PNG))
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
            traySetIcon("HICON: " . this.Base64PNG_to_HICON(getico(icon)))
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
                   . ak.getPartScript("getIco")
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
            ak.createFileByBase64(getIco("icon2RC"),icoPath) ;先创建目标文件
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
   ;Func 获取文件base64编码
   static getBase64(filepath)
   {
      filepath:=!inStr(filepath ,"\")? A_Desktop . "\" . filepath :filepath
      tmpPath:=A_temp . "\" . this.getTimeStr() . "_base64.txt"
      T:=fileExist(filepath)?this.shellExcuter(Format('C:\Windows\System32\certutil.exe -encode "{1}" "{2}"',filepath,tmpPath)):""
      return tmpPath
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
     ;获取base64字符串原来文件 ,传入bas64字符串，生成目标路径
     static createFileByBase64(base64str,despath)
     {
        if fileExist(fb:=(A_temp . "\" . this.getTimeStr() . "_code.txt"))
            fileDelete fb
         fileAppend "-----BEGIN CERTIFICATE-----" . base64str . "-----END CERTIFICATE-----",fb
         this.shellExcuter(Format('C:\Windows\System32\certutil.exe -decode "{1}" "{2}"',fb,despath))
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
               getIco:"[@getIco-CB747C07A3FB4A31B5FCBE475DE40C85]"
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
