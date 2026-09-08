#Requires AutoHotkey v2.0
#NoTrayIcon
#Include %A_Temp%\WebView2.ahk
#SingleInstance Force
#UseHook
Persistent

; 勿在此强制 RunAs：UAC 取消会直接 ExitApp；与快捷键4共存请两边都以管理员启动（或都不提权）。
; 清掉残留的系统忙碌光标（其它脚本 / 长时间磁盘任务会留下转圈）
try DllCall("SystemParametersInfo", "UInt", 0x57, "UInt", 0, "Ptr", 0, "UInt", 0) ; SPI_SETCURSORS


; skipGui：浏览器/微信等自定义光标时，勿先信 GetGUIThreadInfo 假光标（否则 UIA/MSAA 到不了）
GetCaretPosEx(&left?, &top?, &right?, &bottom?, useHook := false, skipHeavy := false, skipGui := false) {
    hwnd := 0
    if !skipGui && getCaretPosFromGui(&hwnd)
        return true
    if !hwnd {
        ; 即使跳过 Gui，也要拿到 focus hwnd 供 MSAA/UIA
        x64 := A_PtrSize == 8
        gi := Buffer(x64 ? 72 : 48)
        NumPut("uint", gi.Size, gi)
        if DllCall("GetGUIThreadInfo", "uint", 0, "ptr", gi)
            hwnd := NumGet(gi, x64 ? 16 : 12, "ptr")
    }
    ; Acc/UIA from #UseHook hotkeys can deadlock OneNote / some Office hosts
    if skipHeavy
        return false
    try
        className := WinGetClass(hwnd)
    catch
        className := ""
    if className ~= "^(?:Windows|Microsoft)\.UI\..+"
        funcs := [getCaretPosFromUIA, getCaretPosFromHook, getCaretPosFromMSAA]
    else if className ~= "^HwndWrapper\[PowerShell_ISE\.exe;;[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\]"
        funcs := [getCaretPosFromHook, getCaretPosFromWpfCaret]
    else if className ~= "i)SunAwt" || IsJetBrainsApp()
        ; GoLand/IDEA：远程 Hook 最准；UIA 次之；勿先 MSAA（AWT 常失败或偏）
        funcs := useHook
            ? [getCaretPosFromHook, getCaretPosFromUIA, getCaretPosFromMSAA]
            : [getCaretPosFromUIA, getCaretPosFromHook, getCaretPosFromMSAA]
    else
        funcs := [getCaretPosFromMSAA, getCaretPosFromUIA, getCaretPosFromHook]
    for fn in funcs {
        if fn == getCaretPosFromHook && !useHook
            continue
        if fn()
            return true
    }
    return false

    getCaretPosFromGui(&hwnd) {
        x64 := A_PtrSize == 8
        guiThreadInfo := Buffer(x64 ? 72 : 48)
        NumPut("uint", guiThreadInfo.Size, guiThreadInfo)
        if DllCall("GetGUIThreadInfo", "uint", 0, "ptr", guiThreadInfo) {
            flags := NumGet(guiThreadInfo, 4, "uint")
            if hwnd := NumGet(guiThreadInfo, x64 ? 48 : 28, "ptr") {
                getRect(guiThreadInfo.Ptr + (x64 ? 56 : 32), &left, &top, &right, &bottom)
                ; 无 GUI_CARETBLINKING 的假矩形（Chrome/微信常见）直接丢弃
                if !(flags & 0x1) && ((right - left) < 1 || (bottom - top) < 1 || IsCustomCaretApp()) {
                    hwnd := NumGet(guiThreadInfo, x64 ? 16 : 12, "ptr")
                    return false
                }
                scaleRect(getWindowScale(hwnd), &left, &top, &right, &bottom)
                clientToScreenRect(hwnd, &left, &top, &right, &bottom)
                return true
            }
            hwnd := NumGet(guiThreadInfo, x64 ? 16 : 12, "ptr")
        }
        return false
    }

    getCaretPosFromMSAA() {
        if !hwnd
            return false
        if !hOleacc := DllCall("LoadLibraryW", "str", "oleacc.dll", "ptr")
            return false
        hOleacc := { Ptr: hOleacc, __Delete: (_) => DllCall("FreeLibrary", "ptr", _) }
        static IID_IAccessible := guidFromString("{618736e0-3c3d-11cf-810c-00aa00389b71}")
        if !DllCall("oleacc\AccessibleObjectFromWindow", "ptr", hwnd, "uint", 0xfffffff8, "ptr", IID_IAccessible, "ptr*", accCaret := ComValue(13, 0), "int") {
            if A_PtrSize == 8 {
                varChild := Buffer(24, 0)
                NumPut("ushort", 3, varChild)
                hr := ComCall(22, accCaret, "int*", &x := 0, "int*", &y := 0, "int*", &w := 0, "int*", &h := 0, "ptr", varChild, "int")
            }
            else {
                hr := ComCall(22, accCaret, "int*", &x := 0, "int*", &y := 0, "int*", &w := 0, "int*", &h := 0, "int64", 3, "int64", 0, "int")
            }
            if !hr {
                ; OBJID_CARET accLocation 已是屏幕坐标，勿再 ScreenToClient
                if w < 1 && h < 1 {
                    w := Max(w, 1)
                    h := Max(h, 16)
                }
                left := x
                top := y
                right := x + w
                bottom := y + h
                return true
            }
        }
        return false
    }

    getCaretPosFromUIA() {
        try {
            uia := ComObject("{E22AD333-B25F-460C-83D0-0581107395C9}", "{30CBE57D-D9D0-452A-AB13-7AC5AC4825EE}")
            ComCall(20, uia, "ptr*", cacheRequest := ComValue(13, 0))
            if !cacheRequest.Ptr
                return false
            ComCall(4, cacheRequest, "ptr", 10014)
            ComCall(4, cacheRequest, "ptr", 10024)

            ComCall(12, uia, "ptr", cacheRequest, "ptr*", focusedEle := ComValue(13, 0))
            if !focusedEle.Ptr
                return false

            static IID_IUIAutomationTextPattern2 := guidFromString("{506a921a-fcc9-409f-b23b-37eb74106872}")
            range := ComValue(13, 0)
            ComCall(15, focusedEle, "int", 10024, "ptr", IID_IUIAutomationTextPattern2, "ptr*", textPattern := ComValue(13, 0))
            if textPattern.Ptr {
                ComCall(10, textPattern, "int*", &isActive := 0, "ptr*", range)
                if range.Ptr
                    goto getRangeInfo
            }
            static IID_IUIAutomationTextPattern := guidFromString("{32eba289-3583-42c9-9c59-3b6d9a1e9b6a}")
            ComCall(15, focusedEle, "int", 10014, "ptr", IID_IUIAutomationTextPattern, "ptr*", textPattern)
            if textPattern.Ptr {
                ComCall(5, textPattern, "ptr*", ranges := ComValue(13, 0))
                if ranges.Ptr {
                    ComCall(3, ranges, "int*", &len := 0)
                    if len > 0
                        ComCall(4, ranges, "int", len - 1, "ptr*", range)
                }
            }
            if !range.Ptr
                return false
getRangeInfo:
            ; Try bounds without expand first (avoids scroll-into-view jitter).
            psa := 0
            ComCall(10, range, "ptr*", &psa)
            if psa {
                rects := ComValue(0x2005, psa, 1)
                if rects.MaxIndex() >= 3 {
                    left := Round(rects[0])
                    top := Round(rects[1])
                    w := Round(rects[2])
                    h := Round(rects[3])
                    if (w > 0 || h > 0 || left != 0 || top != 0) {
                        right := left + Max(w, 1)
                        bottom := top + Max(h, 1)
                        return true
                    }
                }
            }
            ; Fallback expand for IDEs (e.g. GoLand) when caret range has no rect yet.
            ; Only Character unit —Line expand was too aggressive on scroll.
            ComCall(6, range, "int", 0)
            psa := 0
            ComCall(10, range, "ptr*", &psa)
            if !psa
                return false
            rects := ComValue(0x2005, psa, 1)
            if rects.MaxIndex() < 3
                return false
            left := Round(rects[0])
            top := Round(rects[1])
            w := Round(rects[2])
            h := Round(rects[3])
            right := left + Max(w, 1)
            bottom := top + Max(h, 1)
            return true
        }
        return false
    }

    getCaretPosFromWpfCaret() {
        try {
            uia := ComObject("{E22AD333-B25F-460C-83D0-0581107395C9}", "{30CBE57D-D9D0-452A-AB13-7AC5AC4825EE}")
            ComCall(8, uia, "ptr*", focusedEle := ComValue(13, 0))
            if !focusedEle.Ptr
                return false

            ComCall(20, uia, "ptr*", cacheRequest := ComValue(13, 0))
            if !cacheRequest.Ptr
                return false

            ComCall(17, uia, "ptr*", rawViewCondition := ComValue(13, 0))
            if !rawViewCondition.Ptr
                return false

            ComCall(9, cacheRequest, "ptr", rawViewCondition)
            ComCall(3, cacheRequest, "int", 30001)

            var := Buffer(24, 0)
            ref := ComValue(0x400C, var.Ptr)
            ref[] := ComValue(8, "WpfCaret")
            ComCall(23, uia, "int", 30012, "ptr", var, "ptr*", condition := ComValue(13, 0))
            if !condition.Ptr
                return false

            ComCall(7, focusedEle, "int", 4, "ptr", condition, "ptr", cacheRequest, "ptr*", wpfCaret := ComValue(13, 0))
            if !wpfCaret.Ptr
                return false

            ComCall(75, wpfCaret, "ptr", rect := Buffer(16))
            getRect(rect, &left, &top, &right, &bottom)
            return true
        }
        return false
    }

    getCaretPosFromHook() {
        static WM_GET_CARET_POS := DllCall("RegisterWindowMessageW", "str", "WM_GET_CARET_POS", "uint")
        if !tid := DllCall("GetWindowThreadProcessId", "ptr", hwnd, "ptr*", &pid := 0, "uint")
            return false
        try {
            ; SMTO_ABORTIFHUNG —don't freeze if target ignores WM_IME_COMPOSITION
            DllCall("SendMessageTimeoutW", "Ptr", hwnd, "UInt", 0x010f, "Ptr", 0, "Ptr", 0
                , "UInt", 0x0002, "UInt", 50, "UPtr*", &ignored := 0)
        }
        if !hProcess := DllCall("OpenProcess", "uint", 1082, "int", false, "uint", pid, "ptr")
            return false
        hProcess := { Ptr: hProcess, __Delete: (_) => DllCall("CloseHandle", "ptr", _) }

        isX64 := isX64Process(hProcess)
        if isX64 && A_PtrSize == 4
            return false
        if !moduleBaseMap := getModulesBases(hProcess, ["kernel32.dll", "user32.dll", "combase.dll"])
            return false
        if isX64 {
            static shellcode64 := compile(true)
            shellcode := shellcode64
        }
        else {
            static shellcode32 := compile(false)
            shellcode := shellcode32
        }
        if !mem := DllCall("VirtualAllocEx", "ptr", hProcess, "ptr", 0, "ptr", shellcode.Size, "uint", 0x1000, "uint", 0x40, "ptr")
            return false
        mem := { Ptr: mem, __Delete: (_) => DllCall("VirtualFreeEx", "ptr", hProcess, "ptr", _, "uptr", 0, "uint", 0x8000) }
        link(isX64, shellcode, mem.Ptr, moduleBaseMap["user32.dll"], moduleBaseMap["combase.dll"], hwnd, tid, WM_GET_CARET_POS, &pThreadProc, &pRect)

        if !DllCall("WriteProcessMemory", "ptr", hProcess, "ptr", mem, "ptr", shellcode, "uptr", shellcode.Size, "ptr", 0)
            return false
        DllCall("FlushInstructionCache", "ptr", hProcess, "ptr", mem, "uptr", shellcode.Size)

        if !hThread := DllCall("CreateRemoteThread", "ptr", hProcess, "ptr", 0, "uptr", 0, "ptr", pThreadProc, "ptr", mem, "uint", 0, "uint*", &remoteTid := 0, "ptr")
            return false
        hThread := { Ptr: hThread, __Delete: (_) => DllCall("CloseHandle", "ptr", _) }

        if msgWaitForSingleObject(hThread)
            return false
        if !DllCall("GetExitCodeThread", "ptr", hThread, "uint*", exitCode := 0) || exitCode !== 0
            return false

        rect := Buffer(16)
        if !DllCall("ReadProcessMemory", "ptr", hProcess, "ptr", pRect, "ptr", rect, "uptr", rect.Size, "uptr*", &bytesRead := 0) || bytesRead !== rect.Size
            return false
        getRect(rect, &left, &top, &right, &bottom)
        ; JetBrains / AWT：hook 结果已是屏幕坐标；再乘 DPI 比例会整体偏移
        try {
            if (WinGetClass("ahk_id " hwnd) ~= "i)SunAwt") || IsJetBrainsApp()
                return true
        }
        scaleRect(getWindowScale(hwnd), &left, &top, &right, &bottom)
        return true

        static isX64Process(hProcess) {
            DllCall("IsWow64Process", "ptr", hProcess, "int*", &isWow64 := 0)
            if isWow64
                return false
            if A_PtrSize == 8
                return true
            DllCall("IsWow64Process", "ptr", DllCall("GetCurrentProcess", "ptr"), "int*", &isWow64)
            return isWow64
        }

        static getModulesBases(hProcess, modules) {
            hModules := Buffer(A_PtrSize * 350)
            if !DllCall("K32EnumProcessModulesEx", "ptr", hProcess, "ptr", hModules, "uint", hModules.Size, "uint*", &needed := 0, "uint", 3)
                return
            moduleBaseMap := Map()
            moduleBaseMap.CaseSense := false
            for v in modules
                moduleBaseMap[v] := 0
            cnt := modules.Length
            loop Min(350, needed) {
                hModule := NumGet(hModules, A_PtrSize * (A_Index - 1), "ptr")
                VarSetStrCapacity(&name, 12)
                if DllCall("K32GetModuleBaseNameW", "ptr", hProcess, "ptr", hModule, "str", &name, "uint", 13) {
                    if moduleBaseMap.Has(name) {
                        moduleInfo := Buffer(24)
                        if !DllCall("K32GetModuleInformation", "ptr", hProcess, "ptr", hModule, "ptr", moduleInfo, "uint", moduleInfo.Size)
                            return
                        if !base := NumGet(moduleInfo, "ptr")
                            return
                        moduleBaseMap[name] := base
                        cnt--
                    }
                }
            } until cnt == 0
            if cnt == 0
                return moduleBaseMap
        }

        static compile(x64) {
            if x64
                shellcodeBase64 := "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABrnppSh2UjT6uenH1oPjxQAeiAqiEg0hGT4ABgsGe4blNldFdpbmRvd3NIb29rRXhXAAAAVW5ob29rV2luZG93c0hvb2tFeABDYWxsTmV4dEhvb2tFeAAAAAAAAFNlbmRNZXNzYWdlVGltZW91dFcAQ29DcmVhdGVJbnN0YW5jZQAAAAAAAAAASIlcJAhIiXQkEFdIg+wgSYvYSIvyi/mFyXgjSIXbdB6LBQb///9BOUAQdRJIjQ3d/v//6JgBAACJBfL+//9Iiw3L/v//SI0VdP///+jnAgAASIXAdRBIi1wkMEiLdCQ4SIPEIF/DTIvLTIvGi9czyUiLXCQwSIt0JDhIg8QgX0j/4MzMzMzMzDPAw8zMzMzMQFNWSIPsSIvySIvZSIXJdQy4VwAHgEiDxEheW8NIi0kISI1UJGBIiVQkKEG4/////0iNVCQwSIl8JEAz/0iJVCQgiXwkYIvWSIsBRI1PAf9QKIXAeHJIOXwkMHRrOXwkYHRlSItLCEiNVCR4SIl8JHhIiwH/UEiL+IXAeDJIi0wkeEiFyXQoSIsBSI1UJHBMi0QkMEyNSxBIiVQkIIvW/1AgSItMJHiL+EiLAf9QEEiLTCQwSIsB/1AQi8dIi3wkQEiDxEheW8NIi3wkQLgBAAAASIPESF5bw8zMzMzMzMxIhcl0VEiF0nRPTYXAdEpIiwJIhcB1HUi4wAAAAAAAAEZIOUIIdCxJxwAAAAAAuAJAAIDDSbkD6ICqISDSEUk7wXXkSLiT4ABgsGe4bkg5Qgh11EmJCDPAw7hXAAeAw8xAU0iD7EBIi9lIjZHYAAAASItJCOhPAQAASIXAdQu4AQAAAEiDxEBbwzPJx0QkWAEAAABIjVQkaEiJTCRoSIlUJCBMjUt4M9JIiUwkYEiJTCQwiUwkUEiNS2hEjUIX/9CFwA+I7wAAAEiLTCRoSIXJD4ThAAAASIsBSI1UJFD/UBiFwA+IhQAAAEiLTCRoSI1UJGBIiwH/UDiFwHhxSItMJGBIhcl0bEiLAUiNVCQw/1AwhcB4WEiLTCQwSIXJdGZIjUNISIlLMEiJQyhMjUMoSI0Vyf7//0G5AwAAAEiJEEiNBdH9//9IiUNQSI1UJFhIiUNYSI0Fxf3//0iJQ2BIiwFIiVQkIItUJFD/UBhIi0wkYEiLVCQwSIXSdA5IiwJIi8r/UBBIi0wkYEiFyXQGSIsB/1AQSItMJGhIhcl0BkiLAf9QEItEJFj32BvAg+AESIPEQFvDuAQAAABIg8RAW8PMzMzMzMxIiVwkCEiJbCQQSIl0JBhIiXwkIEyL2kyL0UiFyXRwSIXSdGtIY0E8g7wIjAAAAAB0XYuMCIgAAACFyXRSRYtMCiBJjQQKi3AkTQPKi2gcSQPyi3gYSQPqD7YaRTPA/89BixFJA9I6GnUZD7bLSYvDSSvThMl0Lw+2SAFI/8A6DAJ08EH/wEmDwQREO8d20TPASItcJAhIi2wkEEiLdCQYSIt8JCDDSWPAD7cMRotEjQBJA8Lr28zMSIlcJAhIiWwkEEiJdCQYSIl8JCBBVkiD7EBIixlIjZGIAAAASIv5SIvL6Bn///9IjZfEAAAASIvLSIvw6Af///9IjZecAAAASIvLSIvo6PX+//9Mi/BIhfZ0ZUiF7XRgSIXAdFtEi08YSI0VoPv//0UzwEGNSAT/1kiL8EiFwHUFjUYC6z+LVxwzwEiLTxBFM8lIiUQkMEUzwMdEJCjIAAAAiUQkIP/VSIvOSIvYQf/WSIXbdQWNQwPrCotHIOsFuAEAAABIi1wkUEiLbCRYSIt0JGBIi3wkaEiDxEBBXsM="
            else
                shellcodeBase64 := "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAGuemlKHZSNPq56cfWg+PFAB6ICqISDSEZPgAGCwZ7huU2V0V2luZG93c0hvb2tFeFcAAABVbmhvb2tXaW5kb3dzSG9va0V4AENhbGxOZXh0SG9va0V4AAAAAAAAU2VuZE1lc3NhZ2VUaW1lb3V0VwBDb0NyZWF0ZUluc3RhbmNlAAAAAFZX6MkCAACDfCQMAIvwi3wkFHwYhf90FItPCDtOEHUMVuhqAQAAg8QEiUYUjYaIAAAAUP826J4CAACDxAiFwHUFX17CDABX/3QkFP90JBRqAP/QX17CDAAzwMIEAMzMzIPsFFaLdCQchfZ1DLhXAAeAXoPEFMIIAItOBI1UJARSjVQkEMdEJAgAAAAAUosBagFq//90JDBR/1AUhcB4bIN8JAwAdGWDfCQEAHRei04EjVQkHFfHRCQgAAAAAFKLAVH/UCSL+IX/eC2LVCQghdJ0JYsCi0gQjUQkDFCNRghQ/3QkGP90JDBS/9GL+ItEJCBQiwj/UQiLRCQQUIsI/1EIi8dfXoPEFMIIALgBAAAAXoPEFMIIAMyLTCQIVot0JAiF9nRfhcl0W4tUJBCF0nRTiwELQQR1IYF5CMAAAAB1CYF5DAAAAEZ0MscCAAAAALgCQACAXsIMAIE5A+iAqnXpgXkEISDSEXXggXkIk+AAYHXXgXkMsGe4bnXOiTIzwF7CDAC4VwAHgF7CDADMzMyD7BBWi3QkGI2GsAAAAFD/dgToMQEAAIvIg8QIhcl1CI1BAV6DxBDDjUQkBMdEJAQAAAAAUI1GUMdEJBwAAAAAUGoXagCNRkDHRCQYAAAAAFDHRCQgAAAAAMdEJCQBAAAA/9GFwA+IywAAAItMJASFyQ+EvwAAAIsBjVQkDFdSUf9QDIXAeHCLTCQIjVQkHFJRiwH/UByFwHhdi0wkHIXJdFmLAY1UJAxSUf9QGIXAeEaLfCQMhf90UI1OMIl+HLjcAQAAiU4YA8aNVhiJAYvGBRwBAACNTCQUUYlGNIlGOLgkAQAAagMDxlL/dCQciUY8iwdX/1AMi0wkHItUJAyF0nQKiwJS/1AIi0wkHF+FyXQGiwFR/1AIi0wkBIXJdAaLAVH/UAiLRCQQ99heG8CD4ASDxBDDuAQAAABeg8QQw7gAAAAAw8zMg+wIU1VWV4t8JByF/w+EgQAAAItcJCCF23R5i0c8g3w4fAB0b4tEOHiFwHRni0w4JDP2i1Q4IAPPi2w4GAPXiUwkEItMOBwDz4lUJByJTCQUTYorixSyA9c6KnUTis2LwyvThMl0FIpIAUA6DAJ080Y79Xcfi1QkHOvZi0QkEItMJBQPtwRwiwSBA8dfXl1bg8QIw19eXTPAW4PECMPMzFNVVleLfCQUizeNR2BQVuhM////iUQkHI2HnAAAAFBW6Dv///+L2I1HdFBW6C////+LTCQsg8QYi+iFyXRshdt0aIXtdGSLxwWUAwAAiXgBuMQAAAD/dwwDx2oAUGoE/9GJRCQUhcB1DF9eXbgCAAAAW8IEAGoAaMgAAABqAGoAagD/dxD/dwj/0/90JBSL8P/VhfZ1Cl+NRgNeXVvCBACLRxRfXl1bwgQAX15duAEAAABbwgQA"
            len := StrLen(shellcodeBase64)
            shellcode := Buffer(len * 0.75)
            if !DllCall("crypt32\CryptStringToBinary", "str", shellcodeBase64, "uint", len, "uint", 1, "ptr", shellcode, "uint*", shellcode.Size, "ptr", 0, "ptr", 0)
                return
            return shellcode
        }

        static link(x64, shellcode, shellcodeBase, user32Base, combaseBase, hwnd, tid, msg, &pThreadProc, &pRect) {
            if x64 {
                NumPut("uint64", user32Base, shellcode, 0)
                NumPut("uint64", combaseBase, shellcode, 8)
                NumPut("uint64", hwnd, shellcode, 16)
                NumPut("uint", tid, shellcode, 24)
                NumPut("uint", msg, shellcode, 28)
                pThreadProc := shellcodeBase + 0x4e0
                pRect := shellcodeBase + 56
            }
            else {
                NumPut("uint", user32Base, shellcode, 0)
                NumPut("uint", combaseBase, shellcode, 4)
                NumPut("uint", hwnd, shellcode, 8)
                NumPut("uint", tid, shellcode, 12)
                NumPut("uint", msg, shellcode, 16)
                pThreadProc := shellcodeBase + 0x43c
                pRect := shellcodeBase + 32
            }
        }

        static msgWaitForSingleObject(handle) {
            while 1 == res := DllCall("MsgWaitForMultipleObjects", "uint", 1, "ptr*", handle, "int", false, "uint", -1, "uint", 7423) {
                msg := Buffer(A_PtrSize == 8 ? 48 : 28)
                while DllCall("PeekMessageW", "ptr", msg, "ptr", 0, "uint", 0, "uint", 0, "uint", 1) {
                    DllCall("TranslateMessage", "ptr", msg)
                    DllCall("DispatchMessageW", "ptr", msg)
                }
            }
            return res
        }
    }

    static guidFromString(str) {
        DllCall("ole32\CLSIDFromString", "str", str, "ptr", buf := Buffer(16), "hresult")
        return buf
    }

    static getRect(buf, &left, &top, &right, &bottom) {
        left := NumGet(buf, 0, "int")
        top := NumGet(buf, 4, "int")
        right := NumGet(buf, 8, "int")
        bottom := NumGet(buf, 12, "int")
    }

    static getWindowScale(hwnd) {
        if winDpi := DllCall("GetDpiForWindow", "ptr", hwnd, "uint")
            return A_ScreenDPI / winDpi
        return 1
    }

    static scaleRect(scale, &left, &top, &right, &bottom) {
        left := Round(left * scale)
        top := Round(top * scale)
        right := Round(right * scale)
        bottom := Round(bottom * scale)
    }

    static clientToScreenRect(hwnd, &left, &top, &right, &bottom) {
        w := right - left
        h := bottom - top
        pt := left | top << 32
        DllCall("ClientToScreen", "ptr", hwnd, "int64*", &pt)
        left := pt & 0xffffffff
        top := pt >> 32
        right := left + w
        bottom := top + h
    }
}

; =================================================
;  Config
; =================================================
; 面板宽高（基准像素，可直接改；实际尺寸会按屏幕高度微调）
UI_W := 360
UI_H := 425   ; 原 485，减 60
; UI / disk page size: each NDJSON shard holds at most this many records
PAGE_SIZE    := 50
; First paint / load-more chunk shown in the panel (per tab)
VIEW_PAGE_SIZE := 40
; 进「全部」首屏只取这么多，其它 tab 不预热（按需 SetView）
FIRST_PAINT_SIZE := 20
; Clipboard screenshots (type=image) retention; file-copy thumbs (type=file / fimg_*) are permanent
MAX_SCREENSHOTS := 100
; Data root: prefer HELPME_HOME (synced runtime); else script-local ahk\clip_v1
CLIP_V1_DIR  := ResolveClipV1Dir()
HTML_FILE    := CLIP_V1_DIR "\index.html"
SAVE_FILE    := CLIP_V1_DIR "\clips.json"          ; legacy (migrated once)
PAGES_DIR    := CLIP_V1_DIR "\clips_pages"
MANIFEST_FILE := PAGES_DIR "\manifest.json"
STORE_DIR    := CLIP_V1_DIR "\clips_store"
PAYLOAD_DIR  := CLIP_V1_DIR "\clips_payloads"
PAYLOAD_INLINE_MAX := 4000   ; larger text/link bodies go to external files
STORE_HOST   := "clips.store"
; 禁止用 *.local —— Windows mDNS 会卡 ~2–3s（与 HTML 大小无关）
APP_HOST     := "clipui.app"
; Navigate cache key —固定版本；禁止每次启动用 mtime/A_Now 逼全量重载
UI_CACHE_VER := "20260908-pin-sync"
DEBUG_LOG    := CLIP_V1_DIR "\debug.log"
ERROR_LOG    := CLIP_V1_DIR "\error.log"
QUEUE_STATE_FILE := CLIP_V1_DIR "\paste_queue.json"
QUEUE_META_FILE  := CLIP_V1_DIR "\queue_meta.tsv"   ; uid -> group/index (sync, survives restart)
RECENT_FOLDERS_FILE := CLIP_V1_DIR "\recent_folders.json"
MAX_RECENT_FOLDERS := 20

; HELPME_HOME set →%HELPME_HOME%\command_ext\ahk_ext\ahk\clip_v1
; otherwise →%A_ScriptDir%\ahk\clip_v1
ResolveClipV1Dir() {
    home := ""
    try home := EnvGet("HELPME_HOME")
    home := Trim(String(home))
    if home != "" {
        home := RTrim(home, "\/")
        dir := home "\command_ext\ahk_ext\ahk\clip_v1"
        try DirCreate dir
        return dir
    }
    return A_ScriptDir "\ahk\clip_v1"
}

; ── Crash diagnostics: last line in debug.log  ≈ where it died ──
ClipLog(msg) {
    global DEBUG_LOG, CLIP_V1_DIR
    static seq := 0
    try {
        if !DirExist(CLIP_V1_DIR)
            DirCreate CLIP_V1_DIR
        seq += 1
        line := FormatTime(, "yyyy-MM-dd HH:mm:ss.") SubStr("000" Mod(A_TickCount, 1000), -2)
            . " [" A_TickCount "] #" seq " " String(msg) "`n"
        ; FileOpen+Write flushes better than FileAppend on hard kill
        f := FileOpen(DEBUG_LOG, "a", "UTF-8")
        if IsObject(f) {
            f.Write(line)
            f.Close()
        }
    } catch {
    }
}

ClipLogErr(where, e) {
    global ERROR_LOG
    msg := where ": " (IsObject(e) ? e.Message " @ " e.File ":" e.Line : String(e))
    ClipLog("ERR " msg)
    try FileAppend(FormatTime() " " msg "`n", ERROR_LOG, "UTF-8")
}

; First-open timeline: +Nms from first ShowPanel (or reset)
PerfMark(stage) {
    global firstOpenT0, DEBUG_LOG
    if !IsSet(firstOpenT0) || firstOpenT0 < 1
        firstOpenT0 := A_TickCount
    dt := A_TickCount - firstOpenT0
    ClipLog("PERF +" dt "ms " String(stage))
}

PerfReset(*) {
    global firstOpenT0
    firstOpenT0 := A_TickCount
    ClipLog("PERF RESET t0=" firstOpenT0)
}

; =================================================
;  内嵌 HTML（backtick 已转义为 ``）
; =================================================
HTML_B64 := "
(
PCFET0NUWVBFIGh0bWw+CjxodG1sIGxhbmc9InpoLUNOIj4KPGhlYWQ+CiAgICA8bWV0YSBjaGFyc2V0
PSJVVEYtOCI+CiAgICA8dGl0bGU+5Ymq6LS05p2/PC90aXRsZT4KICAgIDxzdHlsZT4KICAgICAgICA6
cm9vdCB7CiAgICAgICAgICAgIC0tYmc6ICAgICAjZWVmMWY2OwogICAgICAgICAgICAtLWFjYzogICAg
IzViNzNlODsKICAgICAgICAgICAgLS10eHQ6ICAgICMyYzJlMzY7CiAgICAgICAgICAgIC0tdHh0Mjog
ICAjNmI3MDgwOwogICAgICAgICAgICAtLXR4dDM6ICAgIzlhYTBiMDsKICAgICAgICAgICAgLS1jYXJk
OiAgICNmZmZmZmY7CiAgICAgICAgICAgIC0tY2FyZC1oOiAjZjhmOWZjOwogICAgICAgICAgICAtLXI6
ICAgICAgNHB4OwogICAgICAgICAgICAtLXRyOiAgICAgMC4xMnMgZWFzZTsKICAgICAgICB9CiAgICAg
ICAgKiwgKjo6YmVmb3JlLCAqOjphZnRlciB7IGJveC1zaXppbmc6IGJvcmRlci1ib3g7IG1hcmdpbjog
MDsgcGFkZGluZzogMDsgfQogICAgICAgIGh0bWwsIGJvZHkgewogICAgICAgICAgICB3aWR0aDogMTAw
JTsgaGVpZ2h0OiAxMDAlOyBvdmVyZmxvdzogaGlkZGVuOwogICAgICAgICAgICBiYWNrZ3JvdW5kOiB2
YXIoLS1iZyk7IGNvbG9yOiB2YXIoLS10eHQpOwogICAgICAgICAgICBmb250OiAxMnB4LzEuNDUgJ1Nl
Z29lIFVJJywnTWljcm9zb2Z0IFlhSGVpIFVJJyxzeXN0ZW0tdWksc2Fucy1zZXJpZjsKICAgICAgICAg
ICAgdXNlci1zZWxlY3Q6IG5vbmU7CiAgICAgICAgICAgIHpvb206IDE7CiAgICAgICAgICAgIHRvdWNo
LWFjdGlvbjogcGFuLXggcGFuLXk7CiAgICAgICAgfQogICAgICAgIDo6LXdlYmtpdC1zY3JvbGxiYXIg
eyB3aWR0aDogNXB4OyB9CiAgICAgICAgOjotd2Via2l0LXNjcm9sbGJhci10aHVtYiB7IGJhY2tncm91
bmQ6ICNjNWM5ZDQ7IGJvcmRlci1yYWRpdXM6IDNweDsgfQogICAgICAgIDo6LXdlYmtpdC1zY3JvbGxi
YXItdGh1bWI6aG92ZXIgeyBiYWNrZ3JvdW5kOiAjYWViM2MwOyB9CiAgICAgICAgOjotd2Via2l0LXNj
cm9sbGJhci10cmFjayB7IGJhY2tncm91bmQ6IHRyYW5zcGFyZW50OyB9CgogICAgICAgICNhcHAgewog
ICAgICAgICAgICBoZWlnaHQ6IDEwMCU7IGRpc3BsYXk6IGZsZXg7IGZsZXgtZGlyZWN0aW9uOiBjb2x1
bW47CiAgICAgICAgICAgIGJhY2tncm91bmQ6IGxpbmVhci1ncmFkaWVudCgxODBkZWcsICNmN2Y5ZmMg
MCUsICNlZWYxZjYgMTAwJSk7CiAgICAgICAgICAgIC13ZWJraXQtYXBwLXJlZ2lvbjogZHJhZzsgYXBw
LXJlZ2lvbjogZHJhZzsKICAgICAgICAgICAgcG9zaXRpb246IHJlbGF0aXZlOwogICAgICAgICAgICBv
dmVyZmxvdzogaGlkZGVuOwogICAgICAgIH0KCiAgICAgICAgLyog4pSA4pSAIFJvdyAxIOKUgOKUgOKU
gOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKU
gOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgCAqLwogICAgICAg
ICNoZHIgewogICAgICAgICAgICBkaXNwbGF5OiBmbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBmbGV4
LXNocmluazogMDsKICAgICAgICAgICAgcGFkZGluZzogNXB4IDRweCA1cHggNnB4OyBnYXA6IDRweDsK
ICAgICAgICAgICAgYmFja2dyb3VuZDogI2YyZjRmOTsKICAgICAgICB9CiAgICAgICAgI2hlYXJ0IHsg
ZmxleC1zaHJpbms6IDA7IGxpbmUtaGVpZ2h0OiAxOyBkaXNwbGF5OmZsZXg7IGFsaWduLWl0ZW1zOmNl
bnRlcjsgfQogICAgICAgICNoZWFydCBzdmcgeyB3aWR0aDoxN3B4OyBoZWlnaHQ6MTdweDsgY29sb3I6
IHZhcigtLXR4dDIpOyB9CiAgICAgICAgI2hkci1ncm93IHsgZmxleDogMTsgbWluLXdpZHRoOiA4cHg7
IH0KCiAgICAgICAgLyogU2VhcmNoOiBvdmVybGF5IGV4cGFuZCAodHJhbnNmb3JtL29wYWNpdHkgb25s
eSDigJQgbm8gd2lkdGggbGF5b3V0IHRocmFzaCkgKi8KICAgICAgICAjc2VhcmNoLXdyYXAgewogICAg
ICAgICAgICBmbGV4OiAwIDAgMjhweDsKICAgICAgICAgICAgd2lkdGg6IDI4cHg7CiAgICAgICAgICAg
IGhlaWdodDogMjhweDsKICAgICAgICAgICAgcG9zaXRpb246IHJlbGF0aXZlOwogICAgICAgICAgICB6
LWluZGV4OiA2OwogICAgICAgICAgICAtd2Via2l0LWFwcC1yZWdpb246IG5vLWRyYWc7IGFwcC1yZWdp
b246IG5vLWRyYWc7CiAgICAgICAgfQogICAgICAgICNidG4tc2VhcmNoIHsKICAgICAgICAgICAgcG9z
aXRpb246IGFic29sdXRlOyByaWdodDogMDsgdG9wOiAwOwogICAgICAgICAgICB3aWR0aDogMjhweDsg
aGVpZ2h0OiAyOHB4OwogICAgICAgICAgICBkaXNwbGF5OiBmbGV4OyBhbGlnbi1pdGVtczogY2VudGVy
OyBqdXN0aWZ5LWNvbnRlbnQ6IGNlbnRlcjsKICAgICAgICAgICAgYm9yZGVyOiBub25lOyBiYWNrZ3Jv
dW5kOiBub25lOyBjdXJzb3I6IHBvaW50ZXI7CiAgICAgICAgICAgIGNvbG9yOiB2YXIoLS10eHQzKTsg
Ym9yZGVyLXJhZGl1czogdmFyKC0tcik7CiAgICAgICAgICAgIHotaW5kZXg6IDI7CiAgICAgICAgICAg
IHRyYW5zaXRpb246IGNvbG9yIDAuMTVzIGVhc2UsIGJhY2tncm91bmQgMC4xNXMgZWFzZSwgb3BhY2l0
eSAwLjE1cyBlYXNlOwogICAgICAgIH0KICAgICAgICAjYnRuLXNlYXJjaDpob3ZlciB7IGNvbG9yOiB2
YXIoLS1hY2MpOyBiYWNrZ3JvdW5kOiByZ2JhKDkxLDExNSwyMzIsLjEpOyB9CiAgICAgICAgI2J0bi1z
ZWFyY2ggc3ZnIHsgd2lkdGg6IDE1cHg7IGhlaWdodDogMTVweDsgZGlzcGxheTogYmxvY2s7IH0KICAg
ICAgICAjc2VhcmNoLXdyYXAub3BlbiAjYnRuLXNlYXJjaCB7CiAgICAgICAgICAgIG9wYWNpdHk6IDA7
CiAgICAgICAgICAgIHBvaW50ZXItZXZlbnRzOiBub25lOwogICAgICAgIH0KCiAgICAgICAgI3NlYXJj
aC1ib3ggewogICAgICAgICAgICB0cmFuc2Zvcm0tb3JpZ2luOiByaWdodCBjZW50ZXI7CiAgICAgICAg
ICAgIHBvc2l0aW9uOiBhYnNvbHV0ZTsKICAgICAgICAgICAgcmlnaHQ6IDA7CiAgICAgICAgICAgIHRv
cDogMDsKICAgICAgICAgICAgd2lkdGg6IDE5NnB4OwogICAgICAgICAgICBoZWlnaHQ6IDI4cHg7CiAg
ICAgICAgICAgIGJveC1zaXppbmc6IGJvcmRlci1ib3g7CiAgICAgICAgICAgIHBhZGRpbmc6IDAgMnB4
IDAgMnB4OwogICAgICAgICAgICBiYWNrZ3JvdW5kOiB0cmFuc3BhcmVudDsKICAgICAgICAgICAgYm9y
ZGVyOiBub25lOwogICAgICAgICAgICBib3JkZXItcmFkaXVzOiAwOwogICAgICAgICAgICBvcGFjaXR5
OiAwOwogICAgICAgICAgICB0cmFuc2Zvcm06IHRyYW5zbGF0ZTNkKDhweCwgMCwgMCkgc2NhbGUoMC45
ODUpOwogICAgICAgICAgICBwb2ludGVyLWV2ZW50czogbm9uZTsKICAgICAgICAgICAgZGlzcGxheTog
ZmxleDsKICAgICAgICAgICAgYWxpZ24taXRlbXM6IGNlbnRlcjsKICAgICAgICAgICAgZ2FwOiA0cHg7
CiAgICAgICAgICAgIHdpbGwtY2hhbmdlOiB0cmFuc2Zvcm0sIG9wYWNpdHk7CiAgICAgICAgICAgIGJh
Y2tmYWNlLXZpc2liaWxpdHk6IGhpZGRlbjsKICAgICAgICAgICAgdHJhbnNpdGlvbjogb3BhY2l0eSAw
LjE4cyBlYXNlLCB0cmFuc2Zvcm0gMC4yNHMgY3ViaWMtYmV6aWVyKDAuMTYsIDEsIDAuMywgMSk7CiAg
ICAgICAgfQogICAgICAgICNzZWFyY2gtd3JhcC5vcGVuICNzZWFyY2gtYm94IHsKICAgICAgICAgICAg
dHJhbnNmb3JtLW9yaWdpbjogcmlnaHQgY2VudGVyOwogICAgICAgICAgICB0cmFuc2Zvcm0tb3JpZ2lu
OiByaWdodCBjZW50ZXI7CiAgICAgICAgICAgIG9wYWNpdHk6IDE7CiAgICAgICAgICAgIHRyYW5zZm9y
bTogdHJhbnNsYXRlM2QoMCwgMCwgMCk7CiAgICAgICAgICAgIHBvaW50ZXItZXZlbnRzOiBhdXRvOwog
ICAgICAgIH0KCiAgICAgICAgI3NlYXJjaCB7CiAgICAgICAgICAgIGZsZXg6IDE7IG1pbi13aWR0aDog
MDsgaGVpZ2h0OiAyOHB4OyBib3JkZXI6IG5vbmU7CiAgICAgICAgICAgIGJvcmRlci1ib3R0b206IDFw
eCBzb2xpZCB0cmFuc3BhcmVudDsKICAgICAgICAgICAgYm9yZGVyLXJhZGl1czogMDsgYmFja2dyb3Vu
ZDogdHJhbnNwYXJlbnQ7IGNvbG9yOiB2YXIoLS10eHQpOyBmb250LXNpemU6IDEycHg7CiAgICAgICAg
ICAgIHBhZGRpbmc6IDAgMjJweCAwIDJweDsgb3V0bGluZTogbm9uZTsKICAgICAgICAgICAgdHJhbnNp
dGlvbjogYm9yZGVyLWJvdHRvbS1jb2xvciAwLjE4cyBlYXNlOwogICAgICAgIH0KICAgICAgICAjc2Vh
cmNoLXdyYXAub3BlbiAjc2VhcmNoIHsKICAgICAgICAgICAgYm9yZGVyLWJvdHRvbS1jb2xvcjogI2M1
Y2FkNjsKICAgICAgICB9CiAgICAgICAgI3NlYXJjaC13cmFwLm9wZW4gI3NlYXJjaDpmb2N1cyB7CiAg
ICAgICAgICAgIGJvcmRlci1ib3R0b20tY29sb3I6IHZhcigtLWFjYyk7CiAgICAgICAgfQogICAgICAg
IG1hcmsucS1obCB7CiAgICAgICAgICAgIGJhY2tncm91bmQ6IHJnYmEoMjU1LCAxOTYsIDAsIC40Mik7
CiAgICAgICAgICAgIGNvbG9yOiBpbmhlcml0OwogICAgICAgICAgICBib3JkZXItcmFkaXVzOiAycHg7
CiAgICAgICAgICAgIHBhZGRpbmc6IDAgMXB4OwogICAgICAgICAgICBkaXNwbGF5OiBpbmxpbmU7CiAg
ICAgICAgICAgIGJveC1kZWNvcmF0aW9uLWJyZWFrOiBjbG9uZTsKICAgICAgICAgICAgLXdlYmtpdC1i
b3gtZGVjb3JhdGlvbi1icmVhazogY2xvbmU7CiAgICAgICAgfQogICAgICAgIC8qIG1hcmsgYnJlYWtz
IC13ZWJraXQtbGluZS1jbGFtcDsga2VlcCBmb2xkIHZpYSBtYXgtaGVpZ2h0IHdoaWxlIHNlYXJjaGlu
ZyAqLwogICAgICAgIC5pLXByZXYuaGFzLWhsLCAuaS1uYW1lLmhhcy1obCwgLm1nLWJvZHkuaGFzLWhs
LAogICAgICAgIC5pLWxpbmstdGl0bGUuaGFzLWhsLCAuaS1saW5rLXVybC5oYXMtaGwsIC5pLWZhdi10
aXRsZS5oYXMtaGwgewogICAgICAgICAgICBkaXNwbGF5OiBibG9jazsKICAgICAgICAgICAgLXdlYmtp
dC1saW5lLWNsYW1wOiB1bnNldDsKICAgICAgICAgICAgb3ZlcmZsb3c6IGhpZGRlbjsKICAgICAgICB9
CiAgICAgICAgLmktcHJldi5oYXMtaGwsIC5tZy1ib2R5Lmhhcy1obCB7IG1heC1oZWlnaHQ6IGNhbGMo
MS40NWVtICogNSk7IH0KICAgICAgICAuaS1uYW1lLmhhcy1obCB7IG1heC1oZWlnaHQ6IGNhbGMoMS40
NWVtICogMik7IH0KICAgICAgICAuaS1saW5rLXVybC5oYXMtaGwgeyBtYXgtaGVpZ2h0OiBjYWxjKDEu
NDVlbSAqIDMpOyB9CiAgICAgICAgLmktcHJldi5oYXMtaGwuZXhwYW5kZWQsIC5pLW5hbWUuaGFzLWhs
LmV4cGFuZGVkLAogICAgICAgIC5tZy1ib2R5Lmhhcy1obC5leHBhbmRlZCwgLmktbGluay11cmwuaGFz
LWhsLmV4cGFuZGVkIHsKICAgICAgICAgICAgLyog5bGV5byA6auY5bqm55SxIEpTIOaOp+WItu+8m+S7
jeijgeWIh+W5tuWcqOacq+WwvuWKoOOAjCAuLi7jgI0gKi8KICAgICAgICAgICAgb3ZlcmZsb3c6IGhp
ZGRlbjsKICAgICAgICB9CiAgICAgICAgLmktZXhwYW5kLWJ0biwgLmktbWV0YSB7IHVzZXItc2VsZWN0
OiBub25lOyB9CiAgICAgICAgI3NlYXJjaDo6cGxhY2Vob2xkZXIgeyBjb2xvcjogdmFyKC0tdHh0Myk7
IH0KICAgICAgICAjc2VhcmNoLWNsciB7CiAgICAgICAgICAgIHBvc2l0aW9uOiBhYnNvbHV0ZTsgcmln
aHQ6IDRweDsgdG9wOiA1MCU7IHRyYW5zZm9ybTogdHJhbnNsYXRlWSgtNTAlKTsKICAgICAgICAgICAg
Ym9yZGVyOiBub25lOyBiYWNrZ3JvdW5kOiBub25lOyBjb2xvcjogdmFyKC0tdHh0Myk7IGN1cnNvcjog
cG9pbnRlcjsKICAgICAgICAgICAgZm9udC1zaXplOiAxMXB4OyBkaXNwbGF5OiBub25lOyBwYWRkaW5n
OiAycHg7CiAgICAgICAgICAgIG9wYWNpdHk6IDAuODU7CiAgICAgICAgICAgIHRyYW5zaXRpb246IGNv
bG9yIDAuMTJzIGVhc2UsIG9wYWNpdHkgMC4xMnMgZWFzZTsKICAgICAgICAgICAgLXdlYmtpdC1hcHAt
cmVnaW9uOiBuby1kcmFnOyBhcHAtcmVnaW9uOiBuby1kcmFnOwogICAgICAgIH0KICAgICAgICAjc2Vh
cmNoLWNscjpob3ZlciB7IGNvbG9yOiB2YXIoLS1hY2MpOyBvcGFjaXR5OiAxOyB9CgogICAgICAgICNi
dG4tdG9kYXkgewogICAgICAgICAgICBkaXNwbGF5OiBub25lOwogICAgICAgICAgICBoZWlnaHQ6IDE4
cHg7IHBhZGRpbmc6IDAgN3B4OyBmbGV4LXNocmluazogMDsKICAgICAgICAgICAgYWxpZ24taXRlbXM6
IGNlbnRlcjsganVzdGlmeS1jb250ZW50OiBjZW50ZXI7CiAgICAgICAgICAgIGJvcmRlcjogMXB4IHNv
bGlkIHJnYmEoOTEsMTE1LDIzMiwuMjIpOyBiYWNrZ3JvdW5kOiByZ2JhKDkxLDExNSwyMzIsLjEwKTsK
ICAgICAgICAgICAgY29sb3I6ICM2YjgyZTg7IGJvcmRlci1yYWRpdXM6IDk5OXB4OyBmb250LXNpemU6
IDlweDsgZm9udC13ZWlnaHQ6IDYwMDsKICAgICAgICAgICAgbGluZS1oZWlnaHQ6IDE7IHdoaXRlLXNw
YWNlOiBub3dyYXA7IGN1cnNvcjogcG9pbnRlcjsKICAgICAgICAgICAgLXdlYmtpdC1hcHAtcmVnaW9u
OiBuby1kcmFnOyBhcHAtcmVnaW9uOiBuby1kcmFnOwogICAgICAgICAgICB0cmFuc2l0aW9uOiBjb2xv
ciB2YXIoLS10ciksIGJhY2tncm91bmQgdmFyKC0tdHIpLCBib3JkZXItY29sb3IgdmFyKC0tdHIpLCBv
cGFjaXR5IHZhcigtLXRyKTsKICAgICAgICB9CiAgICAgICAgI3NlYXJjaC13cmFwLm9wZW4gI2J0bi10
b2RheSB7IGRpc3BsYXk6IGlubGluZS1mbGV4OyB9CiAgICAgICAgI2J0bi10b2RheTpob3ZlciB7IGNv
bG9yOiAjNGE2MmQ0OyBiYWNrZ3JvdW5kOiByZ2JhKDkxLDExNSwyMzIsLjE2KTsgfQogICAgICAgICNi
dG4tdG9kYXkub24gewogICAgICAgICAgICBjb2xvcjogIzViNzNlODsKICAgICAgICAgICAgYmFja2dy
b3VuZDogcmdiYSg5MSwxMTUsMjMyLC4xNik7CiAgICAgICAgICAgIGJvcmRlci1jb2xvcjogcmdiYSg5
MSwxMTUsMjMyLC4zMik7CiAgICAgICAgfQogICAgICAgICNidG4tdG9kYXk6bm90KC5vbikgewogICAg
ICAgICAgICBjb2xvcjogdmFyKC0tdHh0Myk7CiAgICAgICAgICAgIGJhY2tncm91bmQ6IHJnYmEoMCww
LDAsLjA0KTsKICAgICAgICAgICAgYm9yZGVyLWNvbG9yOiByZ2JhKDAsMCwwLC4wNik7CiAgICAgICAg
fQoKICAgICAgICAjYnRuLXBpbiB7CiAgICAgICAgICAgIGRpc3BsYXk6IGZsZXg7CiAgICAgICAgICAg
IHdpZHRoOiAyOHB4OyBoZWlnaHQ6IDI4cHg7IGZsZXgtc2hyaW5rOiAwOwogICAgICAgICAgICBhbGln
bi1pdGVtczogY2VudGVyOyBqdXN0aWZ5LWNvbnRlbnQ6IGNlbnRlcjsKICAgICAgICAgICAgYm9yZGVy
OiAxLjVweCBzb2xpZCB0cmFuc3BhcmVudDsgYmFja2dyb3VuZDogbm9uZTsgY3Vyc29yOiBwb2ludGVy
OwogICAgICAgICAgICBjb2xvcjogdmFyKC0tdHh0Myk7IGJvcmRlci1yYWRpdXM6IHZhcigtLXIpOwog
ICAgICAgICAgICAtd2Via2l0LWFwcC1yZWdpb246IG5vLWRyYWc7IGFwcC1yZWdpb246IG5vLWRyYWc7
CiAgICAgICAgICAgIHRyYW5zaXRpb246IGNvbG9yIHZhcigtLXRyKSwgYmFja2dyb3VuZCB2YXIoLS10
ciksIGJvcmRlci1jb2xvciB2YXIoLS10cik7CiAgICAgICAgfQogICAgICAgICNidG4tcGluOmhvdmVy
IHsgY29sb3I6IHZhcigtLWFjYyk7IGJhY2tncm91bmQ6IHJnYmEoOTEsMTE1LDIzMiwuMSk7IH0KICAg
ICAgICAjYnRuLXBpbi5vbiAgewogICAgICAgICAgICBjb2xvcjogdmFyKC0tYWNjKTsKICAgICAgICAg
ICAgYmFja2dyb3VuZDogcmdiYSg5MSwxMTUsMjMyLC4xOCk7CiAgICAgICAgICAgIGJvcmRlci1jb2xv
cjogcmdiYSg5MSwxMTUsMjMyLC41NSk7CiAgICAgICAgfQogICAgICAgICNidG4tcGluIHN2ZyB7IHdp
ZHRoOiAxNHB4OyBoZWlnaHQ6IDE0cHg7IGRpc3BsYXk6IGJsb2NrOyB9CgogICAgICAgICNidG4tbG9j
YXRlIHsKICAgICAgICAgICAgd2lkdGg6IDI4cHg7IGhlaWdodDogMjhweDsgZmxleC1zaHJpbms6IDA7
CiAgICAgICAgICAgIGRpc3BsYXk6IGZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGp1c3RpZnktY29u
dGVudDogY2VudGVyOwogICAgICAgICAgICBib3JkZXI6IG5vbmU7IGJhY2tncm91bmQ6IG5vbmU7IGN1
cnNvcjogcG9pbnRlcjsKICAgICAgICAgICAgY29sb3I6IHZhcigtLXR4dDMpOyBib3JkZXItcmFkaXVz
OiB2YXIoLS1yKTsKICAgICAgICAgICAgLXdlYmtpdC1hcHAtcmVnaW9uOiBuby1kcmFnOyBhcHAtcmVn
aW9uOiBuby1kcmFnOwogICAgICAgICAgICB0cmFuc2l0aW9uOiBjb2xvciB2YXIoLS10ciksIGJhY2tn
cm91bmQgdmFyKC0tdHIpLCBvcGFjaXR5IHZhcigtLXRyKTsKICAgICAgICB9CiAgICAgICAgI2J0bi1s
b2NhdGU6aG92ZXI6bm90KDpkaXNhYmxlZCkgeyBjb2xvcjogdmFyKC0tYWNjKTsgYmFja2dyb3VuZDog
cmdiYSg5MSwxMTUsMjMyLC4xKTsgfQogICAgICAgICNidG4tbG9jYXRlOmRpc2FibGVkIHsgb3BhY2l0
eTogLjM1OyBjdXJzb3I6IGRlZmF1bHQ7IH0KICAgICAgICAjYnRuLWxvY2F0ZS5oYXMtdGFyZ2V0IHsg
Y29sb3I6IHZhcigtLWFjYyk7IH0KICAgICAgICAjYnRuLWxvY2F0ZS5vbiB7CiAgICAgICAgICAgIGNv
bG9yOiB2YXIoLS1hY2MpOwogICAgICAgICAgICBiYWNrZ3JvdW5kOiByZ2JhKDkxLDExNSwyMzIsLjE4
KTsKICAgICAgICB9CiAgICAgICAgI2J0bi1sb2NhdGUgc3ZnIHsgd2lkdGg6IDE1cHg7IGhlaWdodDog
MTVweDsgZGlzcGxheTogYmxvY2s7IH0KICAgICAgICAjaGRyOmhhcygjc2VhcmNoLXdyYXAub3Blbikg
I2J0bi1sb2NhdGUgewogICAgICAgICAgICBkaXNwbGF5OiBub25lOwogICAgICAgIH0KCiAgICAgICAg
Lyog4pSA4pSAIFJvdyAyIOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKU
gOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKU
gOKUgOKUgOKUgOKUgCAqLwogICAgICAgICN0YWJzIHsKICAgICAgICAgICAgcG9zaXRpb246IHJlbGF0
aXZlOwogICAgICAgICAgICBkaXNwbGF5OiBmbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBnYXA6IDJw
eDsgZmxleC13cmFwOiBub3dyYXA7CiAgICAgICAgICAgIHBhZGRpbmc6IDVweCA0cHggNXB4IDZweDsg
ZmxleC1zaHJpbms6IDA7CiAgICAgICAgICAgIGJhY2tncm91bmQ6ICNmMmY0Zjk7CiAgICAgICAgICAg
IG1pbi13aWR0aDogMDsKICAgICAgICB9CiAgICAgICAgI3RhYi1pbmsgewogICAgICAgICAgICBwb3Np
dGlvbjogYWJzb2x1dGU7CiAgICAgICAgICAgIGxlZnQ6IDA7IHRvcDogMDsKICAgICAgICAgICAgaGVp
Z2h0OiAyMnB4OwogICAgICAgICAgICBib3JkZXItcmFkaXVzOiA5OTlweDsKICAgICAgICAgICAgYmFj
a2dyb3VuZDogI2ZmZjsKICAgICAgICAgICAgYm94LXNoYWRvdzogMCAxcHggM3B4IHJnYmEoMCwwLDAs
LjA3KSwgMCAwIDAgMXB4IHJnYmEoOTEsMTE1LDIzMiwuMDYpOwogICAgICAgICAgICBwb2ludGVyLWV2
ZW50czogbm9uZTsKICAgICAgICAgICAgei1pbmRleDogMDsKICAgICAgICAgICAgdHJhbnNmb3JtOiB0
cmFuc2xhdGUzZCgwLDAsMCkgc2NhbGVYKDEpOwogICAgICAgICAgICB0cmFuc2Zvcm0tb3JpZ2luOiBj
ZW50ZXIgYm90dG9tOwogICAgICAgICAgICB0cmFuc2l0aW9uOgogICAgICAgICAgICAgICAgdHJhbnNm
b3JtIDAuMzRzIGN1YmljLWJlemllcigwLjIyLCAxLjE4LCAwLjMyLCAxKSwKICAgICAgICAgICAgICAg
IGhlaWdodCAwLjI0cyBlYXNlOwogICAgICAgICAgICB3aWxsLWNoYW5nZTogdHJhbnNmb3JtLCBoZWln
aHQ7CiAgICAgICAgfQogICAgICAgICN0YWItaW5rLnNxdWFzaCB7CiAgICAgICAgICAgIHRyYW5zaXRp
b246CiAgICAgICAgICAgICAgICB0cmFuc2Zvcm0gMC4zMHMgY3ViaWMtYmV6aWVyKDAuMzQsIDEuMjgs
IDAuNDQsIDEpLAogICAgICAgICAgICAgICAgaGVpZ2h0IDAuMjBzIGVhc2U7CiAgICAgICAgfQogICAg
ICAgIC50YWIgewogICAgICAgICAgICBwb3NpdGlvbjogcmVsYXRpdmU7CiAgICAgICAgICAgIHotaW5k
ZXg6IDE7CiAgICAgICAgICAgIHBhZGRpbmc6IDNweCA5cHg7IGZvbnQtc2l6ZTogMTFweDsgY29sb3I6
IHZhcigtLXR4dDIpOyBjdXJzb3I6IHBvaW50ZXI7CiAgICAgICAgICAgIGJvcmRlci1yYWRpdXM6IDk5
OXB4OyB3aGl0ZS1zcGFjZTogbm93cmFwOwogICAgICAgICAgICBiYWNrZ3JvdW5kOiB0cmFuc3BhcmVu
dDsKICAgICAgICAgICAgZmxleDogMCAwIGF1dG87CiAgICAgICAgICAgIHRyYW5zaXRpb246IGNvbG9y
IDAuMjhzIGN1YmljLWJlemllcigwLjIyLCAxLCAwLjM2LCAxKSwKICAgICAgICAgICAgICAgICAgICAg
ICAgdHJhbnNmb3JtIDAuMjhzIGN1YmljLWJlemllcigwLjIyLCAxLCAwLjM2LCAxKTsKICAgICAgICAg
ICAgLXdlYmtpdC1hcHAtcmVnaW9uOiBuby1kcmFnOyBhcHAtcmVnaW9uOiBuby1kcmFnOwogICAgICAg
IH0KICAgICAgICAudGFiOmhvdmVyIHsgY29sb3I6IHZhcigtLXR4dCk7IGJhY2tncm91bmQ6IHRyYW5z
cGFyZW50OyB9CiAgICAgICAgLnRhYjphY3RpdmUgeyB0cmFuc2Zvcm06IHNjYWxlKDAuOTYpOyB9CiAg
ICAgICAgLnRhYi5vbiB7IGNvbG9yOiB2YXIoLS1hY2MpOyBiYWNrZ3JvdW5kOiB0cmFuc3BhcmVudDsg
Ym94LXNoYWRvdzogbm9uZTsgZm9udC13ZWlnaHQ6IDYwMDsgfQogICAgICAgIC5iYWRnZSB7CiAgICAg
ICAgICAgIGRpc3BsYXk6IGlubGluZS1mbGV4OyBtaW4td2lkdGg6IDEzcHg7IGhlaWdodDogMTNweDsg
cGFkZGluZzogMCAycHg7CiAgICAgICAgICAgIGFsaWduLWl0ZW1zOiBjZW50ZXI7IGp1c3RpZnktY29u
dGVudDogY2VudGVyOwogICAgICAgICAgICBiYWNrZ3JvdW5kOiB2YXIoLS1hY2MpOyBjb2xvcjogI2Zm
ZjsgZm9udC1zaXplOiA5cHg7IGJvcmRlci1yYWRpdXM6IDdweDsgZm9udC13ZWlnaHQ6IDcwMDsKICAg
ICAgICAgICAgbWFyZ2luLWxlZnQ6IDFweDsKICAgICAgICB9CiAgICAgICAgI3Bpbi1kb3QgewogICAg
ICAgICAgICBkaXNwbGF5OiBub25lOwogICAgICAgICAgICB3aWR0aDogN3B4OyBoZWlnaHQ6IDdweDsK
ICAgICAgICAgICAgbWFyZ2luLWxlZnQ6IDRweDsKICAgICAgICAgICAgYm9yZGVyLXJhZGl1czogNTAl
OwogICAgICAgICAgICBiYWNrZ3JvdW5kOiAjMjJjNTVlOwogICAgICAgICAgICBib3gtc2hhZG93OiAw
IDAgMCAycHggcmdiYSgzNCwxOTcsOTQsLjE4KTsKICAgICAgICAgICAgZmxleC1zaHJpbms6IDA7CiAg
ICAgICAgICAgIHZlcnRpY2FsLWFsaWduOiBtaWRkbGU7CiAgICAgICAgfQogICAgICAgICNwaW4tZG90
Lm9uIHsgZGlzcGxheTogaW5saW5lLWJsb2NrOyB9CiAgICAgICAgI3RhYi1hY3Rpb25zIHsKICAgICAg
ICAgICAgbWFyZ2luLWxlZnQ6IGF1dG87IGRpc3BsYXk6IGZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7
IGdhcDogM3B4OwogICAgICAgICAgICBjb2xvcjogdmFyKC0tdHh0Myk7IGZvbnQtc2l6ZTogMTBweDsK
ICAgICAgICAgICAgZmxleDogMCAwIGF1dG87CiAgICAgICAgICAgIG1pbi13aWR0aDogMDsKICAgICAg
ICAgICAgLXdlYmtpdC1hcHAtcmVnaW9uOiBuby1kcmFnOyBhcHAtcmVnaW9uOiBuby1kcmFnOwogICAg
ICAgIH0KICAgICAgICAjYmFyLXR4dCB7IHdoaXRlLXNwYWNlOiBub3dyYXA7IGZvbnQtc2l6ZTogMTBw
eDsgbWF4LXdpZHRoOiA4LjVlbTsgb3ZlcmZsb3c6IGhpZGRlbjsgdGV4dC1vdmVyZmxvdzogZWxsaXBz
aXM7IH0KICAgICAgICAjYnRuLWNsciB7CiAgICAgICAgICAgIGRpc3BsYXk6IGZsZXg7IGFsaWduLWl0
ZW1zOiBjZW50ZXI7IGp1c3RpZnktY29udGVudDogY2VudGVyOwogICAgICAgICAgICB3aWR0aDogMjZw
eDsgaGVpZ2h0OiAyNnB4OyBib3JkZXI6IG5vbmU7IGJhY2tncm91bmQ6IG5vbmU7IGNvbG9yOiB2YXIo
LS10eHQzKTsKICAgICAgICAgICAgY3Vyc29yOiBwb2ludGVyOyBib3JkZXItcmFkaXVzOiB2YXIoLS1y
KTsKICAgICAgICAgICAgLXdlYmtpdC1hcHAtcmVnaW9uOiBuby1kcmFnOyBhcHAtcmVnaW9uOiBuby1k
cmFnOwogICAgICAgICAgICB0cmFuc2l0aW9uOiBjb2xvciB2YXIoLS10ciksIGJhY2tncm91bmQgdmFy
KC0tdHIpOwogICAgICAgIH0KICAgICAgICAjYnRuLWNscjpob3ZlciB7IGNvbG9yOiAjZmY3YjljOyBi
YWNrZ3JvdW5kOiByZ2JhKDI1NSwxMjMsMTU2LC4wOCk7IH0KICAgICAgICAjYnRuLWNsciBzdmcgeyB3
aWR0aDogMTRweDsgaGVpZ2h0OiAxNHB4OyBkaXNwbGF5OiBibG9jazsgfQoKICAgICAgICAvKiDilIDi
lIAgTGlzdCDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDi
lIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDi
lIDilIDilIAgKi8KICAgICAgICAjbGlzdCB7CiAgICAgICAgICAgIGZsZXg6IDE7IG92ZXJmbG93LXk6
IGF1dG87IG92ZXJmbG93LXg6IGhpZGRlbjsKICAgICAgICAgICAgLyog5bemIDEwIC8g5Y+zIDXvvJrl
j7Pkvqfmu5rliqjmnaHnuqbljaAgNXB477yM6KeG6KeJ5bem5Y+z5a+56b2QICovCiAgICAgICAgICAg
IHBhZGRpbmc6IDRweCA1cHggNHB4IDEwcHg7CiAgICAgICAgICAgIGN1cnNvcjogZGVmYXVsdDsKICAg
ICAgICAgICAgLyogTVVTVCBiZSBuby1kcmFnOiBkcmFnIHJlZ2lvbiBvbiB0aGUgc2Nyb2xsZXIgbWFr
ZXMgV2ViVmlldzIgc2Nyb2xsYmFyL3doZWVsIGhpdGNoICovCiAgICAgICAgICAgIC13ZWJraXQtYXBw
LXJlZ2lvbjogbm8tZHJhZzsgYXBwLXJlZ2lvbjogbm8tZHJhZzsKICAgICAgICAgICAgbWluLWhlaWdo
dDogMDsKICAgICAgICAgICAgb3ZlcmZsb3ctYW5jaG9yOiBub25lOwogICAgICAgIH0KICAgICAgICAv
KiBXaGlsZSBzY3JvbGxpbmc6IGtpbGwgaG92ZXIgYW5pbWF0aW9ucyB0aGF0IGNhdXNlIGxheW91dC9w
YWludCB0aHJhc2ggKi8KICAgICAgICAjbGlzdC5pcy1zY3JvbGxpbmcgLml0bSB7CiAgICAgICAgICAg
IHRyYW5zaXRpb246IG5vbmUgIWltcG9ydGFudDsKICAgICAgICB9CiAgICAgICAgI2xpc3QuaXMtc2Ny
b2xsaW5nIC5pdG06OmJlZm9yZSwKICAgICAgICAjbGlzdC5pcy1zY3JvbGxpbmcgLml0bTo6YWZ0ZXIg
ewogICAgICAgICAgICB0cmFuc2l0aW9uOiBub25lICFpbXBvcnRhbnQ7CiAgICAgICAgfQogICAgICAg
IEBrZXlmcmFtZXMgdGFiUGFuZUluTHIgewogICAgICAgICAgICBmcm9tIHsgb3BhY2l0eTogMDsgdHJh
bnNmb3JtOiB0cmFuc2xhdGVYKC00MHB4KTsgfQogICAgICAgICAgICB0byB7IG9wYWNpdHk6IDE7IHRy
YW5zZm9ybTogdHJhbnNsYXRlWCgwKTsgfQogICAgICAgIH0KICAgICAgICBAa2V5ZnJhbWVzIHRhYlBh
bmVJblJsIHsKICAgICAgICAgICAgZnJvbSB7IG9wYWNpdHk6IDA7IHRyYW5zZm9ybTogdHJhbnNsYXRl
WCg0MHB4KTsgfQogICAgICAgICAgICB0byB7IG9wYWNpdHk6IDE7IHRyYW5zZm9ybTogdHJhbnNsYXRl
WCgwKTsgfQogICAgICAgIH0KICAgICAgICAjbGlzdC50YWItaW4tbHIgeyBhbmltYXRpb246IHRhYlBh
bmVJbkxyIC4zNHMgY3ViaWMtYmV6aWVyKC4yMiwgMSwgLjM2LCAxKSBib3RoOyB9CiAgICAgICAgI2xp
c3QudGFiLWluLXJsIHsgYW5pbWF0aW9uOiB0YWJQYW5lSW5SbCAuMzRzIGN1YmljLWJlemllciguMjIs
IDEsIC4zNiwgMSkgYm90aDsgfQogICAgICAgICNidG4tdG9wIHsKICAgICAgICAgICAgcG9zaXRpb246
IGFic29sdXRlOyByaWdodDogMTBweDsgYm90dG9tOiAxMHB4OyB6LWluZGV4OiAyMDsKICAgICAgICAg
ICAgd2lkdGg6IDI4cHg7IGhlaWdodDogMjhweDsgYm9yZGVyOiBub25lOyBib3JkZXItcmFkaXVzOiA1
MCU7CiAgICAgICAgICAgIGRpc3BsYXk6IG5vbmU7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGp1c3RpZnkt
Y29udGVudDogY2VudGVyOwogICAgICAgICAgICBiYWNrZ3JvdW5kOiAjZmZmOyBjb2xvcjogdmFyKC0t
dHh0Mik7CiAgICAgICAgICAgIGJveC1zaGFkb3c6IDAgMnB4IDhweCByZ2JhKDI0LDMyLDU2LC4xNik7
CiAgICAgICAgICAgIGN1cnNvcjogcG9pbnRlcjsKICAgICAgICAgICAgLXdlYmtpdC1hcHAtcmVnaW9u
OiBuby1kcmFnOyBhcHAtcmVnaW9uOiBuby1kcmFnOwogICAgICAgICAgICB0cmFuc2l0aW9uOiBiYWNr
Z3JvdW5kIHZhcigtLXRyKSwgY29sb3IgdmFyKC0tdHIpLCBib3gtc2hhZG93IHZhcigtLXRyKTsKICAg
ICAgICB9CiAgICAgICAgI2J0bi10b3Aub24geyBkaXNwbGF5OiBmbGV4OyB9CiAgICAgICAgI2J0bi10
b3A6aG92ZXIgeyBjb2xvcjogdmFyKC0tYWNjKTsgYmFja2dyb3VuZDogI2VkZjFmZjsgYm94LXNoYWRv
dzogMCAzcHggMTBweCByZ2JhKDkxLDExNSwyMzIsLjI1KTsgfQogICAgICAgICNidG4tdG9wIHN2ZyB7
IHdpZHRoOiAxNHB4OyBoZWlnaHQ6IDE0cHg7IGRpc3BsYXk6IGJsb2NrOyB9CiAgICAgICAgI2VtcHR5
IHsKICAgICAgICAgICAgZGlzcGxheTogbm9uZTsgZmxleC1kaXJlY3Rpb246IGNvbHVtbjsgYWxpZ24t
aXRlbXM6IGNlbnRlcjsganVzdGlmeS1jb250ZW50OiBjZW50ZXI7CiAgICAgICAgICAgIHBhZGRpbmc6
IDQ4cHggMTZweDsgY29sb3I6IHZhcigtLXR4dDMpOyBnYXA6IDhweDsKICAgICAgICAgICAgLXdlYmtp
dC1hcHAtcmVnaW9uOiBkcmFnOyBhcHAtcmVnaW9uOiBkcmFnOwogICAgICAgIH0KICAgICAgICAjZW1w
dHkub24geyBkaXNwbGF5OiBmbGV4OyB9CiAgICAgICAgLmUtdHh0IHsgZm9udC1zaXplOiAxMnB4OyB0
ZXh0LWFsaWduOiBjZW50ZXI7IGxldHRlci1zcGFjaW5nOiAuMDJlbTsgfQogICAgICAgICNza2VsIHsK
ICAgICAgICAgICAgZGlzcGxheTogbm9uZSAhaW1wb3J0YW50OyAvKiDnp5LlvIDlkI7kuI3lho3lsZXn
pLrpqqjmnrbliqjnlLsgKi8KICAgICAgICB9CiAgICAgICAgI3NrZWwub24geyBkaXNwbGF5OiBub25l
ICFpbXBvcnRhbnQ7IH0KICAgICAgICAjYXBwLmJvb3QtbG9hZGluZyAjc2tlbCB7CiAgICAgICAgICAg
IGRpc3BsYXk6IG5vbmUgIWltcG9ydGFudDsKICAgICAgICB9CiAgICAgICAgI2FwcC5ib290LWxvYWRp
bmcgI2VtcHR5IHsKICAgICAgICAgICAgZGlzcGxheTogbm9uZSAhaW1wb3J0YW50OwogICAgICAgIH0K
ICAgICAgICAuc2stcm93IHsKICAgICAgICAgICAgZGlzcGxheTogZmxleDsgYWxpZ24taXRlbXM6IGZs
ZXgtc3RhcnQ7IGdhcDogMTBweDsKICAgICAgICAgICAgcGFkZGluZzogMTBweCA4cHg7IGJvcmRlci1y
YWRpdXM6IDhweDsKICAgICAgICAgICAgYmFja2dyb3VuZDogcmdiYSgyNTUsMjU1LDI1NSwuNzIpOwog
ICAgICAgICAgICBib3JkZXI6IDFweCBzb2xpZCByZ2JhKDE3MCwxODAsMjAwLC40NSk7CiAgICAgICAg
ICAgIHBvc2l0aW9uOiByZWxhdGl2ZTsKICAgICAgICAgICAgb3ZlcmZsb3c6IGhpZGRlbjsKICAgICAg
ICB9CiAgICAgICAgLnNrLXJvdzo6YWZ0ZXIgewogICAgICAgICAgICBjb250ZW50OiAnJzsKICAgICAg
ICAgICAgcG9zaXRpb246IGFic29sdXRlOwogICAgICAgICAgICBpbnNldDogMDsKICAgICAgICAgICAg
YmFja2dyb3VuZDogbGluZWFyLWdyYWRpZW50KDkwZGVnLCB0cmFuc3BhcmVudCAwJSwgcmdiYSgyNTUs
MjU1LDI1NSwuNzIpIDQ4JSwgdHJhbnNwYXJlbnQgMTAwJSk7CiAgICAgICAgICAgIHRyYW5zZm9ybTog
dHJhbnNsYXRlWCgtMTIwJSk7CiAgICAgICAgICAgIGFuaW1hdGlvbjogc2stc3dlZXAgMC45NXMgZWFz
ZS1pbi1vdXQgaW5maW5pdGU7CiAgICAgICAgICAgIHBvaW50ZXItZXZlbnRzOiBub25lOwogICAgICAg
IH0KICAgICAgICBAa2V5ZnJhbWVzIHNrLXN3ZWVwIHsKICAgICAgICAgICAgMTAwJSB7IHRyYW5zZm9y
bTogdHJhbnNsYXRlWCgxMjAlKTsgfQogICAgICAgIH0KICAgICAgICAuc2staWNvLCAuc2stbGluZSB7
CiAgICAgICAgICAgIGJhY2tncm91bmQ6IGxpbmVhci1ncmFkaWVudCg5MGRlZywgI2I4YzJkOCAwJSwg
I2YwZjRmYSAzOCUsICNkY2UzZjAgNTIlLCAjYjhjMmQ4IDEwMCUpOwogICAgICAgICAgICBiYWNrZ3Jv
dW5kLXNpemU6IDI0MCUgMTAwJTsKICAgICAgICAgICAgYW5pbWF0aW9uOiBzay1zaGltbWVyIDAuNzJz
IGVhc2UtaW4tb3V0IGluZmluaXRlOwogICAgICAgICAgICB3aWxsLWNoYW5nZTogYmFja2dyb3VuZC1w
b3NpdGlvbjsKICAgICAgICAgICAgYm9yZGVyLXJhZGl1czogNnB4OwogICAgICAgIH0KICAgICAgICAu
c2staWNvIHsgd2lkdGg6IDM0cHg7IGhlaWdodDogMzRweDsgZmxleC1zaHJpbms6IDA7IGJvcmRlci1y
YWRpdXM6IDhweDsgfQogICAgICAgIC5zay1ib2R5IHsgZmxleDogMTsgbWluLXdpZHRoOiAwOyBkaXNw
bGF5OiBmbGV4OyBmbGV4LWRpcmVjdGlvbjogY29sdW1uOyBnYXA6IDhweDsgcGFkZGluZy10b3A6IDJw
eDsgfQogICAgICAgIC5zay1saW5lIHsgaGVpZ2h0OiAxMHB4OyB3aWR0aDogMTAwJTsgfQogICAgICAg
IC5zay1saW5lLnNob3J0IHsgd2lkdGg6IDQyJTsgfQogICAgICAgIC5zay1saW5lLm1pZCB7IHdpZHRo
OiA2OCU7IH0KICAgICAgICAuc2stcm93Om50aC1jaGlsZCgyKTo6YWZ0ZXIgeyBhbmltYXRpb24tZGVs
YXk6IC4xMnM7IH0KICAgICAgICAuc2stcm93Om50aC1jaGlsZCgzKTo6YWZ0ZXIgeyBhbmltYXRpb24t
ZGVsYXk6IC4yNHM7IH0KICAgICAgICAuc2stcm93Om50aC1jaGlsZCg0KTo6YWZ0ZXIgeyBhbmltYXRp
b24tZGVsYXk6IC4zNnM7IH0KICAgICAgICAuc2stcm93Om50aC1jaGlsZCg1KTo6YWZ0ZXIgeyBhbmlt
YXRpb24tZGVsYXk6IC40OHM7IH0KICAgICAgICAuc2stcm93Om50aC1jaGlsZCg2KTo6YWZ0ZXIgeyBh
bmltYXRpb24tZGVsYXk6IC42czsgfQogICAgICAgIEBrZXlmcmFtZXMgc2stc2hpbW1lciB7CiAgICAg
ICAgICAgIDAlIHsgYmFja2dyb3VuZC1wb3NpdGlvbjogMTAwJSAwOyB9CiAgICAgICAgICAgIDEwMCUg
eyBiYWNrZ3JvdW5kLXBvc2l0aW9uOiAtMTAwJSAwOyB9CiAgICAgICAgfQogICAgICAgIC5saXN0LW1v
cmUgewogICAgICAgICAgICB0ZXh0LWFsaWduOiBjZW50ZXI7IHBhZGRpbmc6IDEwcHggOHB4IDE0cHg7
IGZvbnQtc2l6ZTogMTFweDsKICAgICAgICAgICAgY29sb3I6IHZhcigtLXR4dDMpOyAtd2Via2l0LWFw
cC1yZWdpb246IG5vLWRyYWc7IGFwcC1yZWdpb246IG5vLWRyYWc7CiAgICAgICAgfQogICAgICAgIC5s
aXN0LW1vcmUuZG9uZSB7IGRpc3BsYXk6IG5vbmU7IH0KCiAgICAgICAgLml0bSB7CiAgICAgICAgICAg
IGRpc3BsYXk6IGZsZXg7IGFsaWduLWl0ZW1zOiBmbGV4LXN0YXJ0OyBnYXA6IDhweDsKICAgICAgICAg
ICAgcGFkZGluZzogOHB4OyBtYXJnaW4tYm90dG9tOiA1cHg7CiAgICAgICAgICAgIGJhY2tncm91bmQ6
IHZhcigtLWNhcmQpOyBib3JkZXItcmFkaXVzOiA0cHg7IGN1cnNvcjogcG9pbnRlcjsKICAgICAgICAg
ICAgYm9yZGVyOiBub25lOwogICAgICAgICAgICBib3gtc2hhZG93OgogICAgICAgICAgICAgICAgMCAx
cHggMnB4IHJnYmEoMjQsMzIsNTYsLjA1KSwKICAgICAgICAgICAgICAgIDAgM3B4IDEwcHggcmdiYSgy
NCwzMiw1NiwuMDgpOwogICAgICAgICAgICAvKiBob3Zlci1saW5lICovCiAgICAgICAgICAgIHBvc2l0
aW9uOiByZWxhdGl2ZTsKICAgICAgICAgICAgdHJhbnNpdGlvbjogYmFja2dyb3VuZCAuMnMgZWFzZSwg
Ym94LXNoYWRvdyAuMnMgZWFzZSwgdHJhbnNmb3JtIC4ycyBlYXNlOwogICAgICAgICAgICAtd2Via2l0
LWFwcC1yZWdpb246IG5vLWRyYWc7IGFwcC1yZWdpb246IG5vLWRyYWc7CiAgICAgICAgICAgIG92ZXJm
bG93OiB2aXNpYmxlOwogICAgICAgIH0KICAgICAgICAuaXRtOjpiZWZvcmUgewogICAgICAgICAgICBj
b250ZW50OiAiIjsKICAgICAgICAgICAgcG9zaXRpb246IGFic29sdXRlOwogICAgICAgICAgICBsZWZ0
OiAwOyByaWdodDogMDsgYm90dG9tOiAwOwogICAgICAgICAgICBoZWlnaHQ6IDA7CiAgICAgICAgICAg
IHBvaW50ZXItZXZlbnRzOiBub25lOwogICAgICAgICAgICB6LWluZGV4OiAwOwogICAgICAgICAgICBi
b3JkZXItcmFkaXVzOiAwIDAgdmFyKC0tcikgdmFyKC0tcik7CiAgICAgICAgICAgIGJhY2tncm91bmQ6
IGxpbmVhci1ncmFkaWVudCh0byB0b3AsIHJnYmEoOTEsMTE1LDIzMiwuMzIpLCByZ2JhKDkxLDExNSwy
MzIsLjEyKSA1NSUsIHRyYW5zcGFyZW50KTsKICAgICAgICAgICAgdHJhbnNpdGlvbjogaGVpZ2h0IC4z
NHMgY3ViaWMtYmV6aWVyKC4yMiwxLC4zNiwxKTsKICAgICAgICB9CiAgICAgICAgLml0bTpob3Zlcjo6
YmVmb3JlIHsgaGVpZ2h0OiAzMy4zMzMlOyB9CiAgICAgICAgLml0bTo6YWZ0ZXIgewogICAgICAgICAg
ICBjb250ZW50OiAiIjsKICAgICAgICAgICAgcG9zaXRpb246IGFic29sdXRlOwogICAgICAgICAgICBs
ZWZ0OiAwOyByaWdodDogMDsgYm90dG9tOiAwOwogICAgICAgICAgICBoZWlnaHQ6IDJweDsKICAgICAg
ICAgICAgcG9pbnRlci1ldmVudHM6IG5vbmU7CiAgICAgICAgICAgIHotaW5kZXg6IDE7CiAgICAgICAg
ICAgIGJhY2tncm91bmQ6IHJnYmEoOTEsMTE1LDIzMiwuOTUpOwogICAgICAgICAgICBib3JkZXItcmFk
aXVzOiAxcHg7CiAgICAgICAgICAgIHRyYW5zZm9ybTogc2NhbGVYKDApOwogICAgICAgICAgICB0cmFu
c2Zvcm0tb3JpZ2luOiBjZW50ZXI7CiAgICAgICAgICAgIHRyYW5zaXRpb246IHRyYW5zZm9ybSAuM3Mg
Y3ViaWMtYmV6aWVyKC4yMiwxLC4zNiwxKTsKICAgICAgICB9CiAgICAgICAgLml0bTpob3ZlciB7CiAg
ICAgICAgICAgIGJhY2tncm91bmQ6IHZhcigtLWNhcmQtaCk7CiAgICAgICAgICAgIGJveC1zaGFkb3c6
CiAgICAgICAgICAgICAgICAwIDJweCA0cHggcmdiYSgyNCwzMiw1NiwuMDcpLAogICAgICAgICAgICAg
ICAgMCA2cHggMTZweCByZ2JhKDI0LDMyLDU2LC4xMik7CiAgICAgICAgfQogICAgICAgIC5pdG06aG92
ZXI6OmFmdGVyIHsKICAgICAgICAgICAgdHJhbnNmb3JtOiBzY2FsZVgoMSk7CiAgICAgICAgfQogICAg
ICAgIC5pdG0uc2VsIHsKICAgICAgICAgICAgYm94LXNoYWRvdzoKICAgICAgICAgICAgICAgIDAgMCAw
IDJweCByZ2JhKDkxLDExNSwyMzIsLjQyKSwKICAgICAgICAgICAgICAgIDAgMnB4IDRweCByZ2JhKDkx
LDExNSwyMzIsLjEwKSwKICAgICAgICAgICAgICAgIDAgNnB4IDE0cHggcmdiYSg5MSwxMTUsMjMyLC4x
Nik7CiAgICAgICAgICAgIGJhY2tncm91bmQ6ICNlZGYxZmY7CiAgICAgICAgfQogICAgICAgIC5pdG0u
bXVsdGkgewogICAgICAgICAgICBib3gtc2hhZG93OiAwIDAgMCAxLjVweCByZ2JhKDkxLDExNSwyMzIs
LjU1KSwgMCAycHggNnB4IHJnYmEoOTEsMTE1LDIzMiwuMTgpOwogICAgICAgICAgICBiYWNrZ3JvdW5k
OiAjZWVmMmZmOwogICAgICAgIH0KICAgICAgICAuaXRtLm11bHRpLnNlbCB7CiAgICAgICAgICAgIGJv
eC1zaGFkb3c6IDAgMCAwIDJweCByZ2JhKDkxLDExNSwyMzIsLjcpLCAwIDJweCA4cHggcmdiYSg5MSwx
MTUsMjMyLC4yMik7CiAgICAgICAgfQoKICAgICAgICAjbXVsdGktYmFyIHsKICAgICAgICAgICAgZGlz
cGxheTogbm9uZTsKICAgICAgICAgICAgYWxpZ24taXRlbXM6IGNlbnRlcjsKICAgICAgICAgICAgZ2Fw
OiA0cHg7CiAgICAgICAgICAgIG1hcmdpbjogMCAycHggMCAwOwogICAgICAgICAgICBmbGV4LXNocmlu
azogMDsKICAgICAgICAgICAgLXdlYmtpdC1hcHAtcmVnaW9uOiBuby1kcmFnOyBhcHAtcmVnaW9uOiBu
by1kcmFnOwogICAgICAgIH0KICAgICAgICAjbXVsdGktYmFyLm9uIHsgZGlzcGxheTogaW5saW5lLWZs
ZXg7IH0KICAgICAgICAjbXVsdGktc2VsIHsKICAgICAgICAgICAgZGlzcGxheTogaW5saW5lLWZsZXg7
CiAgICAgICAgICAgIGFsaWduLWl0ZW1zOiBjZW50ZXI7CiAgICAgICAgICAgIGdhcDogNHB4OwogICAg
ICAgICAgICBoZWlnaHQ6IDIycHg7CiAgICAgICAgICAgIHBhZGRpbmc6IDAgOXB4OwogICAgICAgICAg
ICBmbGV4LXNocmluazogMDsKICAgICAgICAgICAgYm9yZGVyOiBub25lOwogICAgICAgICAgICBib3Jk
ZXItcmFkaXVzOiAxMXB4OwogICAgICAgICAgICBiYWNrZ3JvdW5kOiB2YXIoLS1hY2MpOwogICAgICAg
ICAgICBjb2xvcjogI2ZmZjsKICAgICAgICAgICAgY3Vyc29yOiBwb2ludGVyOwogICAgICAgICAgICAt
d2Via2l0LWFwcC1yZWdpb246IG5vLWRyYWc7IGFwcC1yZWdpb246IG5vLWRyYWc7CiAgICAgICAgICAg
IHRyYW5zaXRpb246IGJhY2tncm91bmQgdmFyKC0tdHIpLCBvcGFjaXR5IHZhcigtLXRyKTsKICAgICAg
ICB9CiAgICAgICAgI211bHRpLXNlbDpob3ZlciB7IGJhY2tncm91bmQ6ICM0YTYyZDQ7IH0KICAgICAg
ICAjbXVsdGktc2VsLWxhYiB7CiAgICAgICAgICAgIGZvbnQtc2l6ZTogMTFweDsKICAgICAgICAgICAg
Zm9udC13ZWlnaHQ6IDYwMDsKICAgICAgICAgICAgY29sb3I6ICNmZmY7CiAgICAgICAgICAgIGxldHRl
ci1zcGFjaW5nOiAuMDJlbTsKICAgICAgICAgICAgbGluZS1oZWlnaHQ6IDE7CiAgICAgICAgICAgIHVz
ZXItc2VsZWN0OiBub25lOwogICAgICAgIH0KICAgICAgICAjbXVsdGktY250IHsKICAgICAgICAgICAg
ZGlzcGxheTogaW5saW5lLWZsZXg7CiAgICAgICAgICAgIGFsaWduLWl0ZW1zOiBjZW50ZXI7CiAgICAg
ICAgICAgIGp1c3RpZnktY29udGVudDogY2VudGVyOwogICAgICAgICAgICBtaW4td2lkdGg6IDFlbTsK
ICAgICAgICAgICAgZm9udC1zaXplOiAxMXB4OwogICAgICAgICAgICBmb250LXdlaWdodDogNzAwOwog
ICAgICAgICAgICBjb2xvcjogI2ZmZjsKICAgICAgICAgICAgbGluZS1oZWlnaHQ6IDE7CiAgICAgICAg
ICAgIHVzZXItc2VsZWN0OiBub25lOwogICAgICAgIH0KCiAgICAgICAgI3Bhc3RlLXNlcC13cmFwIHsK
ICAgICAgICAgICAgcG9zaXRpb246IHJlbGF0aXZlOyBmbGV4LXNocmluazogMDsKICAgICAgICB9CiAg
ICAgICAgI3Bhc3RlLXNlcC1idG4gewogICAgICAgICAgICBkaXNwbGF5OiBpbmxpbmUtZmxleDsgYWxp
Z24taXRlbXM6IGNlbnRlcjsKICAgICAgICAgICAgaGVpZ2h0OiAyMnB4OyBwYWRkaW5nOiAwIDhweDsK
ICAgICAgICAgICAgYm9yZGVyOiBub25lOyBib3JkZXItcmFkaXVzOiAxMXB4OyBjdXJzb3I6IHBvaW50
ZXI7CiAgICAgICAgICAgIGJhY2tncm91bmQ6IHJnYmEoOTEsMTE1LDIzMiwuMTApOyBjb2xvcjogdmFy
KC0tYWNjKTsKICAgICAgICAgICAgZm9udC1zaXplOiAxMnB4OyBsaW5lLWhlaWdodDogMTsgZm9udC13
ZWlnaHQ6IDcwMDsKICAgICAgICAgICAgZm9udC1mYW1pbHk6IHVpLW1vbm9zcGFjZSwgQ29uc29sYXMs
ICJDYXNjYWRpYSBNb25vIiwgbW9ub3NwYWNlOwogICAgICAgICAgICAtd2Via2l0LWFwcC1yZWdpb246
IG5vLWRyYWc7IGFwcC1yZWdpb246IG5vLWRyYWc7CiAgICAgICAgICAgIHRyYW5zaXRpb246IGJhY2tn
cm91bmQgdmFyKC0tdHIpLCBjb2xvciB2YXIoLS10cik7CiAgICAgICAgfQogICAgICAgICNwYXN0ZS1z
ZXAtYnRuOmhvdmVyLCAjcGFzdGUtc2VwLWJ0bi5vcGVuIHsKICAgICAgICAgICAgYmFja2dyb3VuZDog
cmdiYSg5MSwxMTUsMjMyLC4xOCk7IGNvbG9yOiAjNGE2MmQ0OwogICAgICAgIH0KICAgICAgICAjcGFz
dGUtc2VwLW1lbnUgewogICAgICAgICAgICBkaXNwbGF5OiBub25lOyBwb3NpdGlvbjogYWJzb2x1dGU7
IHRvcDogY2FsYygxMDAlICsgNXB4KTsgcmlnaHQ6IDA7CiAgICAgICAgICAgIHdpZHRoOiBtYXgtY29u
dGVudDsgbWF4LXdpZHRoOiAxNDBweDsgbWF4LWhlaWdodDogMjgwcHg7CiAgICAgICAgICAgIG92ZXJm
bG93LXk6IGF1dG87IHotaW5kZXg6IDEyMDsKICAgICAgICAgICAgYmFja2dyb3VuZDogcmdiYSgyNTAs
MjUxLDI1NCwuOTcpOwogICAgICAgICAgICBib3JkZXI6IDFweCBzb2xpZCByZ2JhKDAsMCwwLC4wNSk7
CiAgICAgICAgICAgIGJvcmRlci1yYWRpdXM6IDhweDsKICAgICAgICAgICAgYm94LXNoYWRvdzogMCA2
cHggMjBweCByZ2JhKDQ0LDQ2LDU0LC4xKTsKICAgICAgICAgICAgcGFkZGluZzogM3B4OwogICAgICAg
ICAgICBiYWNrZHJvcC1maWx0ZXI6IGJsdXIoOHB4KTsKICAgICAgICB9CiAgICAgICAgI3Bhc3RlLXNl
cC1tZW51Lm9uIHsKICAgICAgICAgICAgZGlzcGxheTogZmxleDsgZmxleC1kaXJlY3Rpb246IGNvbHVt
bjsgYWxpZ24taXRlbXM6IHN0cmV0Y2g7CiAgICAgICAgfQogICAgICAgIC5wYXN0ZS1zZXAtaXRlbSB7
CiAgICAgICAgICAgIGRpc3BsYXk6IGZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGp1c3RpZnktY29u
dGVudDogc3BhY2UtYmV0d2VlbjsgZ2FwOiA4cHg7CiAgICAgICAgICAgIHdpZHRoOiAxMDAlOyBib3gt
c2l6aW5nOiBib3JkZXItYm94OyB0ZXh0LWFsaWduOiBsZWZ0OwogICAgICAgICAgICBwYWRkaW5nOiA0
cHggNnB4OyBib3JkZXI6IG5vbmU7IGJvcmRlci1yYWRpdXM6IDZweDsKICAgICAgICAgICAgYmFja2dy
b3VuZDogbm9uZTsgY29sb3I6IHZhcigtLXR4dDIpOwogICAgICAgICAgICBmb250LXNpemU6IDEwcHg7
IGN1cnNvcjogcG9pbnRlcjsgd2hpdGUtc3BhY2U6IG5vd3JhcDsKICAgICAgICAgICAgb3ZlcmZsb3c6
IGhpZGRlbjsKICAgICAgICAgICAgdHJhbnNpdGlvbjogYmFja2dyb3VuZCB2YXIoLS10ciksIGNvbG9y
IHZhcigtLXRyKTsKICAgICAgICB9CiAgICAgICAgLnBhc3RlLXNlcC1zeW0gewogICAgICAgICAgICBm
bGV4LXNocmluazogMDsKICAgICAgICAgICAgZm9udC1mYW1pbHk6IHVpLW1vbm9zcGFjZSwgQ29uc29s
YXMsICJDYXNjYWRpYSBNb25vIiwgbW9ub3NwYWNlOwogICAgICAgICAgICBmb250LXNpemU6IDEwcHg7
IGZvbnQtd2VpZ2h0OiA3MDA7IGNvbG9yOiB2YXIoLS1hY2MpOwogICAgICAgICAgICBsZXR0ZXItc3Bh
Y2luZzogLTAuMDNlbTsKICAgICAgICB9CiAgICAgICAgLnBhc3RlLXNlcC1zeW0ub25seSB7IG1pbi13
aWR0aDogMDsgfQogICAgICAgIC5wYXN0ZS1zZXAtbmFtZSB7CiAgICAgICAgICAgIGZsZXg6IDAgMCBh
dXRvOyBtYXJnaW4tbGVmdDogYXV0bzsKICAgICAgICAgICAgZm9udC1zaXplOiAxMHB4OyBjb2xvcjog
dmFyKC0tdHh0Myk7CiAgICAgICAgICAgIG92ZXJmbG93OiBoaWRkZW47IHRleHQtb3ZlcmZsb3c6IGVs
bGlwc2lzOwogICAgICAgIH0KICAgICAgICAucGFzdGUtc2VwLWl0ZW06aG92ZXIgeyBiYWNrZ3JvdW5k
OiByZ2JhKDkxLDExNSwyMzIsLjA4KTsgfQogICAgICAgIC5wYXN0ZS1zZXAtaXRlbTpob3ZlciAucGFz
dGUtc2VwLW5hbWUgeyBjb2xvcjogdmFyKC0tdHh0Mik7IH0KICAgICAgICAucGFzdGUtc2VwLWl0ZW0u
c2VsIHsgYmFja2dyb3VuZDogcmdiYSg5MSwxMTUsMjMyLC4xMik7IH0KICAgICAgICAucGFzdGUtc2Vw
LWl0ZW0uc2VsIC5wYXN0ZS1zZXAtbmFtZSB7IGNvbG9yOiB2YXIoLS1hY2MpOyBmb250LXdlaWdodDog
NjAwOyB9CiAgICAgICAgLnBhc3RlLXNlcC1mb290IHsKICAgICAgICAgICAgbWFyZ2luLXRvcDogM3B4
OyBwYWRkaW5nLXRvcDogM3B4OwogICAgICAgICAgICBib3JkZXItdG9wOiAxcHggc29saWQgcmdiYSgw
LDAsMCwuMDUpOwogICAgICAgICAgICBtaW4td2lkdGg6IDA7IGFsaWduLXNlbGY6IHN0cmV0Y2g7CiAg
ICAgICAgfQogICAgICAgICNwYXN0ZS1zZXAtY3VzdG9tIHsKICAgICAgICAgICAgZGlzcGxheTogYmxv
Y2s7IHdpZHRoOiAxMDAlOyBtaW4td2lkdGg6IDA7IG1heC13aWR0aDogMTAwJTsKICAgICAgICAgICAg
Ym94LXNpemluZzogYm9yZGVyLWJveDsKICAgICAgICAgICAgaGVpZ2h0OiAyMnB4OyBwYWRkaW5nOiAw
IDZweDsKICAgICAgICAgICAgYm9yZGVyOiBub25lOyBib3JkZXItcmFkaXVzOiA1cHg7CiAgICAgICAg
ICAgIGJhY2tncm91bmQ6IHJnYmEoOTEsMTE1LDIzMiwuMDYpOwogICAgICAgICAgICBjb2xvcjogdmFy
KC0tdHh0Mik7IGZvbnQtc2l6ZTogMTBweDsKICAgICAgICAgICAgLXdlYmtpdC1hcHAtcmVnaW9uOiBu
by1kcmFnOyBhcHAtcmVnaW9uOiBuby1kcmFnOwogICAgICAgIH0KICAgICAgICAjcGFzdGUtc2VwLWN1
c3RvbTpmb2N1cyB7CiAgICAgICAgICAgIG91dGxpbmU6IG5vbmU7IGJhY2tncm91bmQ6IHJnYmEoOTEs
MTE1LDIzMiwuMSk7IGNvbG9yOiB2YXIoLS10eHQpOwogICAgICAgIH0KICAgICAgICAjcGFzdGUtc2Vw
LWN1c3RvbTo6cGxhY2Vob2xkZXIgeyBjb2xvcjogdmFyKC0tdHh0Myk7IH0KCiAgICAgICAgLmktaWNv
IHsKICAgICAgICAgICAgd2lkdGg6IDI4cHg7IGhlaWdodDogMjhweDsgYm9yZGVyLXJhZGl1czogdmFy
KC0tcik7IGRpc3BsYXk6IGZsZXg7CiAgICAgICAgICAgIGFsaWduLWl0ZW1zOiBjZW50ZXI7IGp1c3Rp
ZnktY29udGVudDogY2VudGVyOyBmbGV4LXNocmluazogMDsKICAgICAgICAgICAgYmFja2dyb3VuZDog
I2VkZjJmZjsgY29sb3I6IHZhcigtLWFjYyk7CiAgICAgICAgICAgIHBvc2l0aW9uOiByZWxhdGl2ZTsg
b3ZlcmZsb3c6IHZpc2libGU7CiAgICAgICAgfQogICAgICAgIC5pLWljbyBzdmcgeyB3aWR0aDogMTZw
eDsgaGVpZ2h0OiAxNnB4OyBkaXNwbGF5OiBibG9jazsgfQogICAgICAgIC5pLWljby5mdC1pbWcgeyBj
b2xvcjogIzdhZDdmZjsgfQogICAgICAgIC5pLWljby5mdC12aWQgeyBjb2xvcjogI2MwODRmYzsgfQog
ICAgICAgIC5pLWljby5mdC16aXAgeyBjb2xvcjogIzhhYjRmZjsgfQogICAgICAgIC5pLWljby5mdC1k
aXIgeyBjb2xvcjogI2ZmZDU2YTsgfQogICAgICAgIC5pLWljby5mdC1haGsgeyBjb2xvcjogIzZkZmY5
YTsgfQogICAgICAgIC5pLWljby5tZCB7IGNvbG9yOiAjNmI4Y2ZmOyB9CiAgICAgICAgLmktaWNvLm1k
IHN2ZyB7IHdpZHRoOiAyMHB4OyBoZWlnaHQ6IDIwcHg7IH0KICAgICAgICAuaS1pY28uZnQtbG5rLCAu
aS1pY28uZnQtZG9jIHsgY29sb3I6ICNhOWJkZDA7IH0KICAgICAgICAuaS11c2VkIHsKICAgICAgICAg
ICAgcG9zaXRpb246IGFic29sdXRlOyByaWdodDogMDsgYm90dG9tOiAwOwogICAgICAgICAgICB3aWR0
aDogMTNweDsgaGVpZ2h0OiAxM3B4OyBib3JkZXItcmFkaXVzOiA1MCU7CiAgICAgICAgICAgIGJhY2tn
cm91bmQ6ICMyMmM1NWU7IGJvcmRlcjogMS41cHggc29saWQgI2ZmZjsKICAgICAgICAgICAgZGlzcGxh
eTogZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsganVzdGlmeS1jb250ZW50OiBjZW50ZXI7CiAgICAg
ICAgICAgIHBvaW50ZXItZXZlbnRzOiBub25lOyB6LWluZGV4OiAzOwogICAgICAgICAgICBib3gtc2hh
ZG93OiAwIDFweCAycHggcmdiYSgwLDAsMCwuMTYpOwogICAgICAgICAgICB0cmFuc2Zvcm06IHRyYW5z
bGF0ZSgzMCUsIDMwJSk7CiAgICAgICAgfQogICAgICAgIC5pLXVzZWQgc3ZnIHsgd2lkdGg6IDlweDsg
aGVpZ2h0OiA5cHg7IGNvbG9yOiAjZmZmOyBkaXNwbGF5OiBibG9jazsgfQoKICAgICAgICAvKiBQYXN0
ZS1xdWV1ZSB2aXN1YWwgY2hhaW46IGdyYXkgPSBpbiBxdWV1ZTsgZ3JlZW4gPSBkZXF1ZXVlZCAocGFz
dGVkKSBjaGFpbiAqLwogICAgICAgIC5pdG0ucS1tZW1iZXIgewogICAgICAgICAgICBwYWRkaW5nLWxl
ZnQ6IDE0cHg7CiAgICAgICAgICAgIC8qIE1VU1Qgb3ZlcnJpZGUgZ2xvYmFsIC5pdG17b3ZlcmZsb3c6
aGlkZGVufSDigJQgb3RoZXJ3aXNlIGJvdHRvbTotTiByYWlsCiAgICAgICAgICAgICAgIGlzIGNsaXBw
ZWQgYW5kIHRoZSBjaGFpbiBsb29rcyDigJzmlq3nur/igJ0gYWNyb3NzIHRoZSA1cHggY2FyZCBnYXAg
Ki8KICAgICAgICAgICAgb3ZlcmZsb3c6IHZpc2libGUgIWltcG9ydGFudDsKICAgICAgICB9CiAgICAg
ICAgLml0bS5xLW1lbWJlciAucS1yYWlsIHsKICAgICAgICAgICAgcG9zaXRpb246IGFic29sdXRlOwog
ICAgICAgICAgICBsZWZ0OiA1cHg7CiAgICAgICAgICAgIHRvcDogMDsKICAgICAgICAgICAgLyogQnJp
ZGdlIC5pdG0gbWFyZ2luLWJvdHRvbTo1cHggc28gY29uc2VjdXRpdmUgcmFpbHMgcmVhZCBhcyBvbmUg
c3Ryb2tlICovCiAgICAgICAgICAgIGJvdHRvbTogLTVweDsKICAgICAgICAgICAgd2lkdGg6IDJweDsK
ICAgICAgICAgICAgYmFja2dyb3VuZDogIzljYTNhZjsKICAgICAgICAgICAgb3BhY2l0eTogLjcyOwog
ICAgICAgICAgICBwb2ludGVyLWV2ZW50czogbm9uZTsKICAgICAgICAgICAgei1pbmRleDogNDsKICAg
ICAgICB9CiAgICAgICAgLml0bS5xLW1lbWJlci5xLWZpcnN0IC5xLXJhaWwgeyB0b3A6IDE2cHg7IGJv
cmRlci1yYWRpdXM6IDJweCAycHggMCAwOyB9CiAgICAgICAgLyogRW5kIGNoYWluIGF0IHRoZSBsYXN0
IGRvdCDigJQgZG8gbm90IGhhbmcgaW50byB0aGUgZ2FwIGJlbG93ICovCiAgICAgICAgLml0bS5xLW1l
bWJlci5xLWxhc3QgLnEtcmFpbCB7CiAgICAgICAgICAgIGJvdHRvbTogYXV0bzsKICAgICAgICAgICAg
aGVpZ2h0OiAyMnB4OwogICAgICAgICAgICBib3JkZXItcmFkaXVzOiAwIDAgMnB4IDJweDsKICAgICAg
ICB9CiAgICAgICAgLml0bS5xLW1lbWJlci5xLWZpcnN0LnEtbGFzdCAucS1yYWlsLAogICAgICAgIC5p
dG0ucS1tZW1iZXIucS1vbmx5IC5xLXJhaWwgeyBkaXNwbGF5OiBub25lOyB9CiAgICAgICAgLml0bS5x
LW1lbWJlciAucS1kb3QgewogICAgICAgICAgICBwb3NpdGlvbjogYWJzb2x1dGU7CiAgICAgICAgICAg
IGxlZnQ6IDJweDsKICAgICAgICAgICAgdG9wOiAxNHB4OwogICAgICAgICAgICB3aWR0aDogOHB4Owog
ICAgICAgICAgICBoZWlnaHQ6IDhweDsKICAgICAgICAgICAgYm9yZGVyLXJhZGl1czogNTAlOwogICAg
ICAgICAgICBiYWNrZ3JvdW5kOiAjOWNhM2FmOwogICAgICAgICAgICBib3JkZXI6IDEuNXB4IHNvbGlk
ICNmZmY7CiAgICAgICAgICAgIGJveC1zaGFkb3c6IDAgMCAwIDFweCByZ2JhKDE1NiwxNjMsMTc1LC40
NSk7CiAgICAgICAgICAgIHBvaW50ZXItZXZlbnRzOiBub25lOwogICAgICAgICAgICB6LWluZGV4OiA1
OwogICAgICAgIH0KICAgICAgICAvKiBEZXF1ZXVlZDogZ3JlZW4gZG90czsgZ3JlZW4gcmFpbCBmb3Ig
Y29uc2VjdXRpdmUgZG9uZSBydW4gKi8KICAgICAgICAuaXRtLnEtbWVtYmVyLnEtZG9uZSAucS1kb3Qg
ewogICAgICAgICAgICBiYWNrZ3JvdW5kOiAjMjJjNTVlOwogICAgICAgICAgICBib3gtc2hhZG93OiAw
IDAgMCAxcHggcmdiYSgzNCwxOTcsOTQsLjQpOwogICAgICAgIH0KICAgICAgICAuaXRtLnEtbWVtYmVy
LnEtZG9uZS1saW5rIC5xLXJhaWwgewogICAgICAgICAgICBiYWNrZ3JvdW5kOiAjMjJjNTVlOwogICAg
ICAgICAgICBvcGFjaXR5OiAuOTI7CiAgICAgICAgfQoKICAgICAgICAuaXRtLmp1bXAtZmxhc2ggewog
ICAgICAgICAgICBib3gtc2hhZG93OiAwIDAgMCAycHggcmdiYSg5MSwxMTUsMjMyLC41NSksIDAgMnB4
IDEwcHggcmdiYSg5MSwxMTUsMjMyLC4yMik7CiAgICAgICAgICAgIGJhY2tncm91bmQ6ICNlOGVkZmY7
CiAgICAgICAgICAgIHRyYW5zaXRpb246IGJhY2tncm91bmQgLjM1cyBlYXNlLCBib3gtc2hhZG93IC4z
NXMgZWFzZTsKICAgICAgICB9CgogICAgICAgIC5pLWJvZHkgeyBmbGV4OiAxOyBtaW4td2lkdGg6IDA7
IGRpc3BsYXk6IGZsZXg7IGZsZXgtZGlyZWN0aW9uOiBjb2x1bW47IHBvc2l0aW9uOiByZWxhdGl2ZTsg
ei1pbmRleDogMjsgfQogICAgICAgIC5pLXByZXYsIC5pLW5hbWUgewogICAgICAgICAgICBmb250LXNp
emU6IDEzcHg7IGZvbnQtd2VpZ2h0OiA1MDA7IGNvbG9yOiB2YXIoLS10eHQpOyB3b3JkLWJyZWFrOiBi
cmVhay1hbGw7CiAgICAgICAgICAgIHdoaXRlLXNwYWNlOiBwcmUtd3JhcDsgLyog5pSv5oyB5aSa5paH
5Lu2L+WkmuihjOaWh+acrOaNouihjOaYvuekuiAqLwogICAgICAgIH0KICAgICAgICAuaS1wcmV2IHsK
ICAgICAgICAgICAgZGlzcGxheTogLXdlYmtpdC1ib3g7IC13ZWJraXQtYm94LW9yaWVudDogdmVydGlj
YWw7IC13ZWJraXQtbGluZS1jbGFtcDogNTsgb3ZlcmZsb3c6IGhpZGRlbjsKICAgICAgICAgICAgdGV4
dC1vdmVyZmxvdzogZWxsaXBzaXM7CiAgICAgICAgfQogICAgICAgIC5pLW5hbWUgewogICAgICAgICAg
ICBkaXNwbGF5OiAtd2Via2l0LWJveDsgLXdlYmtpdC1ib3gtb3JpZW50OiB2ZXJ0aWNhbDsgLXdlYmtp
dC1saW5lLWNsYW1wOiAyOyBvdmVyZmxvdzogaGlkZGVuOwogICAgICAgIH0KICAgICAgICAvKiBGaWxl
IGNsaXAgd2hvc2UgcGF0aChzKSBubyBsb25nZXIgZXhpc3Qg4oCUIGxpZ2h0IGJvbGQgZ3JheSBzdHJp
a2UgKi8KICAgICAgICAuaXRtLmdvbmUgLmktbmFtZSB7CiAgICAgICAgICAgIGNvbG9yOiAjOWFhMGIw
OwogICAgICAgICAgICB0ZXh0LWRlY29yYXRpb246IGxpbmUtdGhyb3VnaDsKICAgICAgICAgICAgdGV4
dC1kZWNvcmF0aW9uLXRoaWNrbmVzczogMnB4OwogICAgICAgICAgICB0ZXh0LWRlY29yYXRpb24tY29s
b3I6IHJnYmEoMTU0LCAxNjAsIDE3NiwgLjU1KTsKICAgICAgICAgICAgdGV4dC1kZWNvcmF0aW9uLXNr
aXAtaW5rOiBub25lOwogICAgICAgIH0KICAgICAgICAuaXRtLmdvbmUgLmktaWNvIHsgb3BhY2l0eTog
LjU1OyB9CiAgICAgICAgLml0bS5nb25lIC5pLXRodW1iLXdyYXAgeyBvcGFjaXR5OiAuNTU7IH0KICAg
ICAgICAuaS1wcmV2LnVybCB7IGNvbG9yOiB2YXIoLS1hY2MpOyB9CgogICAgICAgIC5yZi1wYXRoIHsK
ICAgICAgICAgICAgZGlzcGxheTogZmxleDsgZmxleC13cmFwOiB3cmFwOyBhbGlnbi1pdGVtczogY2Vu
dGVyOwogICAgICAgICAgICBnYXA6IDA7IHJvdy1nYXA6IDNweDsKICAgICAgICAgICAgZm9udC1zaXpl
OiAxM3B4OyBmb250LXdlaWdodDogNjAwOyBjb2xvcjogdmFyKC0tdHh0KTsKICAgICAgICAgICAgbGlu
ZS1oZWlnaHQ6IDEuNDU7IHdvcmQtYnJlYWs6IGJyZWFrLXdvcmQ7CiAgICAgICAgICAgIG1heC13aWR0
aDogMTAwJTsKICAgICAgICAgICAgd2lkdGg6IGZpdC1jb250ZW50OwogICAgICAgICAgICBwb3NpdGlv
bjogcmVsYXRpdmU7CiAgICAgICAgICAgIHotaW5kZXg6IDY7CiAgICAgICAgICAgIC13ZWJraXQtYXBw
LXJlZ2lvbjogbm8tZHJhZzsgYXBwLXJlZ2lvbjogbm8tZHJhZzsKICAgICAgICAgICAgcG9pbnRlci1l
dmVudHM6IGF1dG87CiAgICAgICAgfQogICAgICAgIC5yZi1zZWcgewogICAgICAgICAgICBjb2xvcjog
dmFyKC0tYWNjKTsKICAgICAgICAgICAgY3Vyc29yOiBwb2ludGVyOwogICAgICAgICAgICBwYWRkaW5n
OiAxcHggM3B4OwogICAgICAgICAgICBtYXJnaW46IDA7CiAgICAgICAgICAgIGJvcmRlcjogbm9uZTsK
ICAgICAgICAgICAgYmFja2dyb3VuZDogdHJhbnNwYXJlbnQ7CiAgICAgICAgICAgIGJvcmRlci1yYWRp
dXM6IDNweDsKICAgICAgICAgICAgZm9udDogaW5oZXJpdDsKICAgICAgICAgICAgZm9udC1zaXplOiAx
M3B4OwogICAgICAgICAgICBmb250LXdlaWdodDogNjAwOwogICAgICAgICAgICBsaW5lLWhlaWdodDog
MS40NTsKICAgICAgICAgICAgLXdlYmtpdC1hcHAtcmVnaW9uOiBuby1kcmFnOyBhcHAtcmVnaW9uOiBu
by1kcmFnOwogICAgICAgICAgICBwb2ludGVyLWV2ZW50czogYXV0byAhaW1wb3J0YW50OwogICAgICAg
ICAgICBwb3NpdGlvbjogcmVsYXRpdmU7CiAgICAgICAgICAgIHotaW5kZXg6IDg7CiAgICAgICAgICAg
IHRyYW5zaXRpb246IGJhY2tncm91bmQgLjEycyBlYXNlLCBjb2xvciAuMTJzIGVhc2U7CiAgICAgICAg
fQogICAgICAgIC5yZi1zZWc6aG92ZXIgewogICAgICAgICAgICBiYWNrZ3JvdW5kOiByZ2JhKDkxLDEx
NSwyMzIsLjE0KTsKICAgICAgICAgICAgdGV4dC1kZWNvcmF0aW9uOiB1bmRlcmxpbmU7CiAgICAgICAg
fQogICAgICAgIC5yZi1zZXAgewogICAgICAgICAgICBjb2xvcjogdmFyKC0tdHh0Myk7CiAgICAgICAg
ICAgIHBhZGRpbmc6IDAgMnB4OwogICAgICAgICAgICBtYXJnaW46IDA7CiAgICAgICAgICAgIHVzZXIt
c2VsZWN0OiBub25lOwogICAgICAgICAgICBmbGV4LXNocmluazogMDsKICAgICAgICAgICAgb3BhY2l0
eTogLjU1OwogICAgICAgICAgICBwb2ludGVyLWV2ZW50czogbm9uZTsKICAgICAgICAgICAgZm9udC1z
aXplOiAxMnB4OwogICAgICAgICAgICBsaW5lLWhlaWdodDogMS40NTsKICAgICAgICB9CiAgICAgICAg
Lml0bS5yZi1maXhlZCAuaS1pY28gewogICAgICAgICAgICBib3gtc2hhZG93OiAwIDAgMCAxLjVweCBy
Z2JhKDkxLDExNSwyMzIsLjQ1KTsKICAgICAgICB9CiAgICAgICAgLnJmLXBpbi10YWcgewogICAgICAg
ICAgICBkaXNwbGF5OiBpbmxpbmUtZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsganVzdGlmeS1jb250
ZW50OiBjZW50ZXI7CiAgICAgICAgICAgIGZsZXgtc2hyaW5rOiAwOwogICAgICAgICAgICBoZWlnaHQ6
IDE2cHg7IHBhZGRpbmc6IDAgNnB4OyBtYXJnaW4tcmlnaHQ6IDA7CiAgICAgICAgICAgIGJvcmRlci1y
YWRpdXM6IDRweDsKICAgICAgICAgICAgZm9udC1zaXplOiAxMHB4OyBmb250LXdlaWdodDogNTAwOwog
ICAgICAgICAgICBjb2xvcjogIzdhODQ5OTsKICAgICAgICAgICAgYmFja2dyb3VuZDogcmdiYSgxMjIs
MTMyLDE1MywuMTIpOwogICAgICAgICAgICBib3JkZXI6IDFweCBzb2xpZCByZ2JhKDEyMiwxMzIsMTUz
LC4yMik7CiAgICAgICAgICAgIGxldHRlci1zcGFjaW5nOiAuMDJlbTsKICAgICAgICAgICAgd2hpdGUt
c3BhY2U6IG5vd3JhcDsKICAgICAgICAgICAgcG9pbnRlci1ldmVudHM6IG5vbmU7CiAgICAgICAgfQog
ICAgICAgIC5pLXRodW1iLXdyYXAgewogICAgICAgICAgICB3aWR0aDogMTAwJTsgbWluLWhlaWdodDog
NDhweDsgbWF4LWhlaWdodDogMTgwcHg7IG1hcmdpbi1ib3R0b206IDRweDsKICAgICAgICAgICAgZGlz
cGxheTogZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsganVzdGlmeS1jb250ZW50OiBjZW50ZXI7CiAg
ICAgICAgICAgIGJhY2tncm91bmQ6ICNmM2Y1Zjk7IGJvcmRlci1yYWRpdXM6IHZhcigtLXIpOyBvdmVy
ZmxvdzogaGlkZGVuOwogICAgICAgIH0KICAgICAgICAuaS10aHVtYi13cmFwLndhaXRpbmcgewogICAg
ICAgICAgICBtaW4taGVpZ2h0OiA4OHB4OwogICAgICAgICAgICBiYWNrZ3JvdW5kOiBsaW5lYXItZ3Jh
ZGllbnQoOTBkZWcsICNlOGViZjIgMCUsICNmNGY2ZmEgNDUlLCAjZThlYmYyIDEwMCUpOwogICAgICAg
ICAgICBiYWNrZ3JvdW5kLXNpemU6IDIwMCUgMTAwJTsKICAgICAgICAgICAgYW5pbWF0aW9uOiB0aHVt
YlNoaW1tZXIgMS4wNXMgZWFzZS1pbi1vdXQgaW5maW5pdGU7CiAgICAgICAgfQogICAgICAgIEBrZXlm
cmFtZXMgdGh1bWJTaGltbWVyIHsKICAgICAgICAgICAgMCUgeyBiYWNrZ3JvdW5kLXBvc2l0aW9uOiAx
MDAlIDA7IH0KICAgICAgICAgICAgMTAwJSB7IGJhY2tncm91bmQtcG9zaXRpb246IC0xMDAlIDA7IH0K
ICAgICAgICB9CiAgICAgICAgLmktdGh1bWIgeyBtYXgtd2lkdGg6IDEwMCU7IG1heC1oZWlnaHQ6IDE4
MHB4OyB3aWR0aDogYXV0bzsgaGVpZ2h0OiBhdXRvOyBvYmplY3QtZml0OiBjb250YWluOyBkaXNwbGF5
OiBibG9jazsgfQogICAgICAgIC5pLXRodW1iLnRodW1iLWxvYWRpbmcgeyBvcGFjaXR5OiAwOyB3aWR0
aDogMXB4OyBoZWlnaHQ6IDFweDsgfQoKICAgICAgICAvKiBNZXRhIGJhcjogdGltZSBsZWZ0IHwgZXhw
YW5kIGNlbnRlciB8IHRhZ3MgcmlnaHQgKi8KICAgICAgICAuaS1tZXRhIHsKICAgICAgICAgICAgZGlz
cGxheTogZ3JpZDsKICAgICAgICAgICAgZ3JpZC10ZW1wbGF0ZS1jb2x1bW5zOiAxZnIgYXV0byAxZnI7
CiAgICAgICAgICAgIGFsaWduLWl0ZW1zOiBjZW50ZXI7CiAgICAgICAgICAgIGdhcDogNHB4OwogICAg
ICAgICAgICBtYXJnaW4tdG9wOiA0cHg7CiAgICAgICAgICAgIHdpZHRoOiAxMDAlOwogICAgICAgIH0K
ICAgICAgICAuaS1tZXRhIC5pLXRpbWUgeyBqdXN0aWZ5LXNlbGY6IHN0YXJ0OyB9CiAgICAgICAgLmkt
bWV0YS1jZW50ZXIgewogICAgICAgICAgICBqdXN0aWZ5LXNlbGY6IGNlbnRlcjsKICAgICAgICAgICAg
ZGlzcGxheTogZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsganVzdGlmeS1jb250ZW50OiBjZW50ZXI7
CiAgICAgICAgICAgIGdhcDogNHB4OwogICAgICAgICAgICBtaW4td2lkdGg6IDFweDsgLyoga2VlcCBj
ZW50ZXIgY29sdW1uIGV2ZW4gd2hlbiBleHBhbmQgaXMgaGlkZGVuICovCiAgICAgICAgfQogICAgICAg
IC5pLW1ldGEtcmlnaHQgewogICAgICAgICAgICBqdXN0aWZ5LXNlbGY6IGVuZDsKICAgICAgICAgICAg
ZGlzcGxheTogZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsgZ2FwOiA1cHg7IGZsZXgtd3JhcDogbm93
cmFwOwogICAgICAgICAgICBqdXN0aWZ5LWNvbnRlbnQ6IGZsZXgtZW5kOwogICAgICAgICAgICBtaW4t
d2lkdGg6IDA7CiAgICAgICAgfQogICAgICAgIC5pLW1ldGEtcmlnaHQudGV4dC1tZXRhIHsKICAgICAg
ICAgICAgZmxleC13cmFwOiBub3dyYXA7CiAgICAgICAgICAgIGdhcDogNHB4OwogICAgICAgIH0KICAg
ICAgICAuaS1zcmMtdGl0bGUgewogICAgICAgICAgICBmb250LXNpemU6IDEwcHg7CiAgICAgICAgICAg
IGNvbG9yOiB2YXIoLS10eHQzKTsKICAgICAgICAgICAgbWF4LXdpZHRoOiAxMWVtOwogICAgICAgICAg
ICBvdmVyZmxvdzogaGlkZGVuOwogICAgICAgICAgICB0ZXh0LW92ZXJmbG93OiBlbGxpcHNpczsKICAg
ICAgICAgICAgd2hpdGUtc3BhY2U6IG5vd3JhcDsKICAgICAgICAgICAgbWluLXdpZHRoOiAwOwogICAg
ICAgICAgICBsaW5lLWhlaWdodDogMS40OwogICAgICAgIH0KICAgICAgICAuaS10aW1lLCAuaS10YWcg
eyBmb250LXNpemU6IDEwcHg7IGNvbG9yOiB2YXIoLS10eHQzKTsgfQogICAgICAgIC5pLXRhZyB7CiAg
ICAgICAgICAgIGJhY2tncm91bmQ6ICNmMWYzZjg7IHBhZGRpbmc6IDAgNXB4OyBib3JkZXItcmFkaXVz
OiAzcHg7CiAgICAgICAgICAgIHdoaXRlLXNwYWNlOiBub3dyYXA7IGZsZXgtc2hyaW5rOiAwOyBsaW5l
LWhlaWdodDogMS40OwogICAgICAgIH0KICAgICAgICAuaS1jaGFycyB7CiAgICAgICAgICAgIGZvbnQt
c2l6ZTogMTBweDsgY29sb3I6IHZhcigtLXR4dDMpOwogICAgICAgICAgICBiYWNrZ3JvdW5kOiAjZjFm
M2Y4OyBwYWRkaW5nOiAwIDVweDsgYm9yZGVyLXJhZGl1czogM3B4OwogICAgICAgICAgICBmb250LXZh
cmlhbnQtbnVtZXJpYzogdGFidWxhci1udW1zOwogICAgICAgICAgICB3aGl0ZS1zcGFjZTogbm93cmFw
OwogICAgICAgICAgICBkaXNwbGF5OiBpbmxpbmUtZmxleDsgYWxpZ24taXRlbXM6IGJhc2VsaW5lOyBn
YXA6IDJweDsKICAgICAgICB9CiAgICAgICAgLmktY2hhcnMgLm4gewogICAgICAgICAgICBkaXNwbGF5
OiBpbmxpbmUtYmxvY2s7CiAgICAgICAgICAgIG1pbi13aWR0aDogNGNoOwogICAgICAgICAgICB0ZXh0
LWFsaWduOiByaWdodDsKICAgICAgICAgICAgZm9udC1mYW1pbHk6ICdDYXNjYWRpYSBNb25vJywgJ0Nv
bnNvbGFzJywgJ1NhcmFzYSBNb25vIFNDJywgdWktbW9ub3NwYWNlLCBtb25vc3BhY2U7CiAgICAgICAg
ICAgIGZvbnQtd2VpZ2h0OiA2MDA7CiAgICAgICAgICAgIGNvbG9yOiB2YXIoLS10eHQyKTsKICAgICAg
ICB9CiAgICAgICAgLyogc3JjLXRpdGxlLXRpcCAqLwogICAgICAgIC5pLXNyYy1pY28sIC5tZy1zcmMg
eyBjdXJzb3I6IHBvaW50ZXI7IH0KICAgICAgICAjc3JjLXRpcCB7CiAgICAgICAgICAgIHBvc2l0aW9u
OiBmaXhlZDsgei1pbmRleDogOTk5OTk7CiAgICAgICAgICAgIG1heC13aWR0aDogbWluKDI4MHB4LCBj
YWxjKDEwMHZ3IC0gMTZweCkpOwogICAgICAgICAgICBwYWRkaW5nOiA2cHggMTBweDsKICAgICAgICAg
ICAgYm9yZGVyLXJhZGl1czogOHB4OwogICAgICAgICAgICBiYWNrZ3JvdW5kOiByZ2JhKDMyLDM2LDQ4
LC45Mik7IGNvbG9yOiAjZmZmOwogICAgICAgICAgICBmb250LXNpemU6IDEycHg7IGxpbmUtaGVpZ2h0
OiAxLjM1OwogICAgICAgICAgICBib3gtc2hhZG93OiAwIDZweCAxOHB4IHJnYmEoMCwwLDAsLjIyKTsK
ICAgICAgICAgICAgcG9pbnRlci1ldmVudHM6IG5vbmU7CiAgICAgICAgICAgIG9wYWNpdHk6IDA7IHRy
YW5zZm9ybTogdHJhbnNsYXRlWSg0cHgpOwogICAgICAgICAgICB0cmFuc2l0aW9uOiBvcGFjaXR5IC4y
cyBlYXNlLCB0cmFuc2Zvcm0gLjIycyBjdWJpYy1iZXppZXIoLjIyLDEsLjM2LDEpOwogICAgICAgICAg
ICB3b3JkLWJyZWFrOiBicmVhay13b3JkOwogICAgICAgIH0KICAgICAgICAjc3JjLXRpcC5zaG93IHsg
b3BhY2l0eTogMTsgdHJhbnNmb3JtOiB0cmFuc2xhdGVZKDApOyB9CiAgICAgICAgLmktc3JjLWljbyB7
CiAgICAgICAgICAgIHdpZHRoOiAxNHB4OyBoZWlnaHQ6IDE0cHg7IGZsZXgtc2hyaW5rOiAwOwogICAg
ICAgICAgICBib3JkZXItcmFkaXVzOiAycHg7IG9iamVjdC1maXQ6IGNvbnRhaW47CiAgICAgICAgICAg
IGRpc3BsYXk6IGJsb2NrOwogICAgICAgIH0KICAgICAgICAuaS1udW0gewogICAgICAgICAgICBkaXNw
bGF5OiBmbGV4OyBmbGV4LWRpcmVjdGlvbjogY29sdW1uOyBhbGlnbi1pdGVtczogZmxleC1lbmQ7CiAg
ICAgICAgICAgIGp1c3RpZnktY29udGVudDogc3BhY2UtYmV0d2VlbjsKICAgICAgICAgICAgYWxpZ24t
c2VsZjogc3RyZXRjaDsKICAgICAgICAgICAgZm9udC1zaXplOiAxMHB4OyBjb2xvcjogdmFyKC0tdHh0
Myk7IG1pbi13aWR0aDogMTZweDsKICAgICAgICAgICAgdGV4dC1hbGlnbjogcmlnaHQ7IGZsZXgtc2hy
aW5rOiAwOwogICAgICAgICAgICBwYWRkaW5nLXRvcDogMnB4OwogICAgICAgIH0KICAgICAgICAuaS1u
dW0gLmktc3JjLWljbyB7IHdpZHRoOiAxNnB4OyBoZWlnaHQ6IDE2cHg7IG1hcmdpbi10b3A6IGF1dG87
IH0KCiAgICAgICAgLmktZXhwYW5kLWJ0biB7CiAgICAgICAgICAgIGJvcmRlcjogbm9uZTsgYmFja2dy
b3VuZDogbm9uZTsgY3Vyc29yOiBwb2ludGVyOwogICAgICAgICAgICBjb2xvcjogdmFyKC0tdHh0Myk7
IGZvbnQtc2l6ZTogMTJweDsgcGFkZGluZzogM3B4IDEwcHg7CiAgICAgICAgICAgIGJvcmRlci1yYWRp
dXM6IDhweDsgZGlzcGxheTogbm9uZTsgYWxpZ24taXRlbXM6IGNlbnRlcjsgZ2FwOiA0cHg7CiAgICAg
ICAgICAgIHRyYW5zaXRpb246IGNvbG9yIHZhcigtLXRyKSwgYmFja2dyb3VuZCB2YXIoLS10cik7CiAg
ICAgICAgICAgIC13ZWJraXQtYXBwLXJlZ2lvbjogbm8tZHJhZzsgYXBwLXJlZ2lvbjogbm8tZHJhZzsK
ICAgICAgICAgICAgbGluZS1oZWlnaHQ6IDEuMjsKICAgICAgICB9CiAgICAgICAgLmktZXhwYW5kLWJ0
biBzdmcgeyB3aWR0aDogMTRweDsgaGVpZ2h0OiAxNHB4OyBmbGV4LXNocmluazogMDsgfQogICAgICAg
IC5pLWV4cGFuZC1idG4ub24geyBkaXNwbGF5OiBpbmxpbmUtZmxleDsgfQogICAgICAgIC5pLWV4cGFu
ZC1idG46aG92ZXIgeyBjb2xvcjogdmFyKC0tYWNjKTsgYmFja2dyb3VuZDogcmdiYSg5MSwxMTUsMjMy
LC4wOCk7IH0KICAgICAgICAuaS1wcmV2LmV4cGFuZGVkLCAuaS1uYW1lLmV4cGFuZGVkIHsKICAgICAg
ICAgICAgLXdlYmtpdC1saW5lLWNsYW1wOiB1bnNldDsKICAgICAgICAgICAgZGlzcGxheTogYmxvY2s7
CiAgICAgICAgICAgIG92ZXJmbG93OiBoaWRkZW47CiAgICAgICAgICAgIC8qIOmrmOW6pueUsSBKUyDm
jInliJfooajlj6/op4bljLrorr7lrprvvJrnuqbljaDmlbTooajlsJHkuIDooYwgKi8KICAgICAgICB9
CiAgICAgICAgLmktc3JjLXRpdGxlIHsgZGlzcGxheTogbm9uZSAhaW1wb3J0YW50OyB9CiAgICAgICAg
LmktZmlsZS1kZXRhaWwgewogICAgICAgICAgICBkaXNwbGF5OiBub25lOwogICAgICAgICAgICBtYXJn
aW4tdG9wOiA0cHg7CiAgICAgICAgICAgIHBhZGRpbmc6IDA7CiAgICAgICAgICAgIGJhY2tncm91bmQ6
IG5vbmU7CiAgICAgICAgICAgIGJvcmRlcjogbm9uZTsKICAgICAgICB9CiAgICAgICAgLmktZmlsZS1k
ZXRhaWwub24geyBkaXNwbGF5OiBibG9jazsgfQogICAgICAgIC5mZC1ibG9jayB7CiAgICAgICAgICAg
IGRpc3BsYXk6IGZsZXg7IGZsZXgtZGlyZWN0aW9uOiBjb2x1bW47IGdhcDogNnB4OwogICAgICAgIH0K
ICAgICAgICAuZmQtYmxvY2sgKyAuZmQtYmxvY2sgeyBtYXJnaW4tdG9wOiA4cHg7IH0KICAgICAgICAu
ZmQtcGF0aCB7CiAgICAgICAgICAgIHdpZHRoOiAxMDAlOwogICAgICAgICAgICBmb250OiA2MDAgMTJw
eC8xLjU1ICdTZWdvZSBVSSBWYXJpYWJsZSBUZXh0JywnU2Vnb2UgVUknLCdNaWNyb3NvZnQgWWFIZWkg
VUknLHNhbnMtc2VyaWY7CiAgICAgICAgICAgIGNvbG9yOiB2YXIoLS10eHQyKTsKICAgICAgICAgICAg
bGV0dGVyLXNwYWNpbmc6IC4wMWVtOwogICAgICAgICAgICB3b3JkLWJyZWFrOiBicmVhay1hbGw7CiAg
ICAgICAgICAgIHVzZXItc2VsZWN0OiB0ZXh0OwogICAgICAgICAgICAtd2Via2l0LWFwcC1yZWdpb246
IG5vLWRyYWc7IGFwcC1yZWdpb246IG5vLWRyYWc7CiAgICAgICAgfQogICAgICAgIC5mZC1wYXRoLmxp
dmUgeyBjdXJzb3I6IHBvaW50ZXI7IH0KICAgICAgICAuZmQtcGF0aC5saXZlOmhvdmVyIHsgY29sb3I6
IHZhcigtLWFjYyk7IH0KICAgICAgICAuZmQtcGF0aC5kZWFkIHsKICAgICAgICAgICAgY29sb3I6ICM5
YWEwYjA7CiAgICAgICAgICAgIHRleHQtZGVjb3JhdGlvbjogbGluZS10aHJvdWdoOwogICAgICAgICAg
ICB0ZXh0LWRlY29yYXRpb24tdGhpY2tuZXNzOiAycHg7CiAgICAgICAgICAgIHRleHQtZGVjb3JhdGlv
bi1jb2xvcjogcmdiYSgxNTQsIDE2MCwgMTc2LCAuNTUpOwogICAgICAgICAgICB0ZXh0LWRlY29yYXRp
b24tc2tpcC1pbms6IG5vbmU7CiAgICAgICAgICAgIGN1cnNvcjogZGVmYXVsdDsKICAgICAgICB9CiAg
ICAgICAgLmZkLWFjdGlvbnMgewogICAgICAgICAgICBkaXNwbGF5OiBmbGV4OyBhbGlnbi1pdGVtczog
Y2VudGVyOyBqdXN0aWZ5LWNvbnRlbnQ6IGZsZXgtZW5kOwogICAgICAgICAgICBnYXA6IDhweDsgZmxl
eC13cmFwOiB3cmFwOwogICAgICAgIH0KICAgICAgICAuZmQtYnRuIHsKICAgICAgICAgICAgYm9yZGVy
OiBub25lOyBiYWNrZ3JvdW5kOiBub25lOyBjdXJzb3I6IHBvaW50ZXI7CiAgICAgICAgICAgIGNvbG9y
OiB2YXIoLS10eHQzKTsgZm9udC1zaXplOiAxMHB4OyBmb250LXdlaWdodDogNjAwOwogICAgICAgICAg
ICBwYWRkaW5nOiAxcHggMnB4OyBkaXNwbGF5OiBpbmxpbmUtZmxleDsgYWxpZ24taXRlbXM6IGNlbnRl
cjsgZ2FwOiAycHg7CiAgICAgICAgICAgIHdoaXRlLXNwYWNlOiBub3dyYXA7CiAgICAgICAgICAgIC13
ZWJraXQtYXBwLXJlZ2lvbjogbm8tZHJhZzsgYXBwLXJlZ2lvbjogbm8tZHJhZzsKICAgICAgICAgICAg
dHJhbnNpdGlvbjogY29sb3IgdmFyKC0tdHIpOwogICAgICAgIH0KICAgICAgICAuZmQtYnRuOmhvdmVy
IHsgY29sb3I6IHZhcigtLWFjYyk7IH0KICAgICAgICAuZmQtYnRuLm9rIHsgY29sb3I6ICMxZjdhNTU7
IH0KCiAgICAgICAgLyog4pSA4pSAIENvbnRleHQgbWVudSDilIDilIDilIDilIDilIDilIDilIDilIDi
lIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDi
lIDilIDilIDilIAgKi8KICAgICAgICAjY3R4IHsKICAgICAgICAgICAgcG9zaXRpb246IGZpeGVkOyB6
LWluZGV4OiA5OTk5OyBtaW4td2lkdGg6IDEzMnB4OyBkaXNwbGF5OiBub25lOyBwYWRkaW5nOiA0cHg7
CiAgICAgICAgICAgIGJhY2tncm91bmQ6ICNmZmY7IGJvcmRlci1yYWRpdXM6IHZhcigtLXIpOyBib3gt
c2hhZG93OiAwIDZweCAxNnB4IHJnYmEoMCwwLDAsLjE0KTsKICAgICAgICAgICAgLXdlYmtpdC1hcHAt
cmVnaW9uOiBuby1kcmFnOyBhcHAtcmVnaW9uOiBuby1kcmFnOwogICAgICAgIH0KICAgICAgICAjY3R4
Lm9uIHsgZGlzcGxheTogYmxvY2s7IH0KICAgICAgICAuYy1pdGVtIHsKICAgICAgICAgICAgZGlzcGxh
eTogZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsgZ2FwOiA3cHg7IHBhZGRpbmc6IDZweCA5cHg7CiAg
ICAgICAgICAgIGJvcmRlci1yYWRpdXM6IHZhcigtLXIpOyBjdXJzb3I6IHBvaW50ZXI7IGZvbnQtc2l6
ZTogMTFweDsgY29sb3I6IHZhcigtLXR4dCk7CiAgICAgICAgfQogICAgICAgIC5jLWl0ZW06aG92ZXIg
eyBiYWNrZ3JvdW5kOiAjZjJmNGY5OyB9CiAgICAgICAgLmMtaXRlbS5kYW5nZXIgeyBjb2xvcjogI2Zm
N2I5YzsgfQogICAgICAgIC5jLXNlcCB7IGhlaWdodDogMXB4OyBiYWNrZ3JvdW5kOiAjZWNlZmY1OyBt
YXJnaW46IDNweCAwOyB9CiAgICAgICAgLmMtaWNvIHsgd2lkdGg6IDE0cHg7IHRleHQtYWxpZ246IGNl
bnRlcjsgfQoKICAgICAgICAvKiDilIDilIAgQ2xlYXIgY29uZmlybSDilIDilIDilIDilIDilIDilIDi
lIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDi
lIDilIDilIDilIDilIAgKi8KICAgICAgICAjY2xyLWRsZyB7CiAgICAgICAgICAgIGRpc3BsYXk6IG5v
bmU7IHBvc2l0aW9uOiBmaXhlZDsgaW5zZXQ6IDA7IHotaW5kZXg6IDEwMDAwOwogICAgICAgICAgICBi
YWNrZ3JvdW5kOiByZ2JhKDIwLCAyMiwgMzUsIC40Mik7CiAgICAgICAgICAgIGFsaWduLWl0ZW1zOiBj
ZW50ZXI7IGp1c3RpZnktY29udGVudDogY2VudGVyOwogICAgICAgICAgICAtd2Via2l0LWFwcC1yZWdp
b246IG5vLWRyYWc7IGFwcC1yZWdpb246IG5vLWRyYWc7CiAgICAgICAgfQogICAgICAgICNjbHItZGxn
Lm9uIHsgZGlzcGxheTogZmxleDsgfQogICAgICAgIC5jbHItYm94IHsKICAgICAgICAgICAgd2lkdGg6
IG1pbigyODBweCwgY2FsYygxMDAlIC0gMzJweCkpOwogICAgICAgICAgICBiYWNrZ3JvdW5kOiAjZmZm
OyBib3JkZXItcmFkaXVzOiAxMnB4OwogICAgICAgICAgICBib3gtc2hhZG93OiAwIDEycHggMzJweCBy
Z2JhKDAsMCwwLC4xOCk7CiAgICAgICAgICAgIHBhZGRpbmc6IDE2cHggMTZweCAxNHB4OyBjb2xvcjog
dmFyKC0tdHh0KTsKICAgICAgICB9CiAgICAgICAgLmNsci10aXRsZSB7IGZvbnQtc2l6ZTogMTRweDsg
Zm9udC13ZWlnaHQ6IDcwMDsgbWFyZ2luLWJvdHRvbTogNnB4OyB9CiAgICAgICAgLmNsci1kZXNjIHsg
Zm9udC1zaXplOiAxMXB4OyBjb2xvcjogdmFyKC0tdHh0Myk7IGxpbmUtaGVpZ2h0OiAxLjU7IG1hcmdp
bi1ib3R0b206IDEycHg7IH0KICAgICAgICAuY2xyLWNoZWNrIHsKICAgICAgICAgICAgZGlzcGxheTog
ZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsgZ2FwOiA3cHg7CiAgICAgICAgICAgIGZvbnQtc2l6ZTog
MTJweDsgY29sb3I6IHZhcigtLXR4dCk7IGN1cnNvcjogcG9pbnRlcjsKICAgICAgICAgICAgdXNlci1z
ZWxlY3Q6IG5vbmU7IG1hcmdpbi1ib3R0b206IDE0cHg7CiAgICAgICAgfQogICAgICAgIC5jbHItY2hl
Y2sgaW5wdXQgewogICAgICAgICAgICB3aWR0aDogMTRweDsgaGVpZ2h0OiAxNHB4OyBhY2NlbnQtY29s
b3I6IHZhcigtLWFjYyk7IGN1cnNvcjogcG9pbnRlcjsKICAgICAgICB9CiAgICAgICAgLmNsci1idG5z
IHsgZGlzcGxheTogZmxleDsgZ2FwOiA4cHg7IGp1c3RpZnktY29udGVudDogZmxleC1lbmQ7IH0KICAg
ICAgICAuY2xyLWJ0bnMgYnV0dG9uIHsKICAgICAgICAgICAgYm9yZGVyOiBub25lOyBib3JkZXItcmFk
aXVzOiA4cHg7IHBhZGRpbmc6IDdweCAxNHB4OwogICAgICAgICAgICBmb250LXNpemU6IDEycHg7IGN1
cnNvcjogcG9pbnRlcjsgZm9udC13ZWlnaHQ6IDYwMDsKICAgICAgICAgICAgdHJhbnNpdGlvbjogYmFj
a2dyb3VuZCB2YXIoLS10ciksIGNvbG9yIHZhcigtLXRyKTsKICAgICAgICB9CiAgICAgICAgI2Nsci1j
YW5jZWwgeyBiYWNrZ3JvdW5kOiAjZjFmM2Y4OyBjb2xvcjogdmFyKC0tdHh0Mik7IH0KICAgICAgICAj
Y2xyLWNhbmNlbDpob3ZlciB7IGJhY2tncm91bmQ6ICNlNmU5ZjI7IH0KICAgICAgICAjY2xyLW9rIHsg
YmFja2dyb3VuZDogcmdiYSgyNTUsMTIzLDE1NiwuMTQpOyBjb2xvcjogI2U4NWE3YTsgfQogICAgICAg
ICNjbHItb2s6aG92ZXIgeyBiYWNrZ3JvdW5kOiByZ2JhKDI1NSwxMjMsMTU2LC4yNCk7IH0KCiAgICAg
ICAgLyog4pSA4pSAIEZpbGUgcGF0aCB0aXAg4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA
4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA
ICovCiAgICAgICAgI3BhdGgtdGlwIHsKICAgICAgICAgICAgZGlzcGxheTogbm9uZTsgcG9zaXRpb246
IGZpeGVkOyB6LWluZGV4OiAxMDAwMTsKICAgICAgICAgICAgd2lkdGg6IG1pbigzMjBweCwgY2FsYygx
MDB2dyAtIDE2cHgpKTsKICAgICAgICAgICAgbWF4LWhlaWdodDogbWluKDI4MHB4LCBjYWxjKDEwMHZo
IC0gMjRweCkpOwogICAgICAgICAgICBvdmVyZmxvdzogYXV0bzsKICAgICAgICAgICAgcGFkZGluZzog
MDsKICAgICAgICAgICAgYmFja2dyb3VuZDogbGluZWFyLWdyYWRpZW50KDE2NWRlZywgI2ZmZmZmZiAw
JSwgI2Y2ZjhmYyAxMDAlKTsKICAgICAgICAgICAgYm9yZGVyOiAxcHggc29saWQgcmdiYSg3MCwgODQs
IDEyMCwgLjEpOwogICAgICAgICAgICBib3JkZXItcmFkaXVzOiAxMnB4OwogICAgICAgICAgICBib3gt
c2hhZG93OgogICAgICAgICAgICAgICAgMCA0cHggNnB4IHJnYmEoMzAsIDQwLCA3MCwgLjA0KSwKICAg
ICAgICAgICAgICAgIDAgMTRweCAzNnB4IHJnYmEoMzAsIDQwLCA3MCwgLjE2KTsKICAgICAgICAgICAg
Y29sb3I6IHZhcigtLXR4dCk7CiAgICAgICAgICAgIHBvaW50ZXItZXZlbnRzOiBhdXRvOwogICAgICAg
ICAgICBvcGFjaXR5OiAwOwogICAgICAgICAgICB0cmFuc2Zvcm06IHRyYW5zbGF0ZVkoNHB4KSBzY2Fs
ZSguOTgpOwogICAgICAgICAgICB0cmFuc2l0aW9uOiBvcGFjaXR5IC4xNHMgZWFzZSwgdHJhbnNmb3Jt
IC4xNHMgZWFzZTsKICAgICAgICAgICAgLXdlYmtpdC1hcHAtcmVnaW9uOiBuby1kcmFnOyBhcHAtcmVn
aW9uOiBuby1kcmFnOwogICAgICAgIH0KICAgICAgICAjcGF0aC10aXAub24gewogICAgICAgICAgICBk
aXNwbGF5OiBibG9jazsKICAgICAgICAgICAgb3BhY2l0eTogMTsKICAgICAgICAgICAgdHJhbnNmb3Jt
OiB0cmFuc2xhdGVZKDApIHNjYWxlKDEpOwogICAgICAgIH0KICAgICAgICAucHQtaGVhZCB7CiAgICAg
ICAgICAgIGRpc3BsYXk6IGZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGp1c3RpZnktY29udGVudDog
c3BhY2UtYmV0d2VlbjsKICAgICAgICAgICAgZ2FwOiAxMHB4OyBwYWRkaW5nOiAxMHB4IDEycHggOHB4
OwogICAgICAgICAgICBib3JkZXItYm90dG9tOiAxcHggc29saWQgcmdiYSg3MCwgODQsIDEyMCwgLjA3
KTsKICAgICAgICB9CiAgICAgICAgLnB0LXRpdGxlIHsKICAgICAgICAgICAgZm9udC1zaXplOiAxMXB4
OyBmb250LXdlaWdodDogNzAwOyBsZXR0ZXItc3BhY2luZzogLjA0ZW07CiAgICAgICAgICAgIGNvbG9y
OiB2YXIoLS10eHQyKTsgdGV4dC10cmFuc2Zvcm06IHVwcGVyY2FzZTsKICAgICAgICAgICAgZmxleC1z
aHJpbms6IDA7CiAgICAgICAgfQogICAgICAgIC5wdC1oZWFkLWJ0biB7CiAgICAgICAgICAgIGZsZXgt
c2hyaW5rOiAwOyBtYXJnaW4tbGVmdDogYXV0bzsKICAgICAgICAgICAgaGVpZ2h0OiAyMnB4OyBwYWRk
aW5nOiAwIDhweDsgZGlzcGxheTogaW5saW5lLWZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGdhcDog
NHB4OwogICAgICAgICAgICBib3JkZXI6IDFweCBzb2xpZCByZ2JhKDEwNywxMTIsMTI4LC4yMik7IGJv
cmRlci1yYWRpdXM6IDZweDsgY3Vyc29yOiBwb2ludGVyOwogICAgICAgICAgICBiYWNrZ3JvdW5kOiBy
Z2JhKDEwNywxMTIsMTI4LC4wNik7IGNvbG9yOiAjOGE5MGEwOyBmb250LXNpemU6IDExcHg7IGZvbnQt
d2VpZ2h0OiA2MDA7CiAgICAgICAgICAgIHdoaXRlLXNwYWNlOiBub3dyYXA7CiAgICAgICAgICAgIC13
ZWJraXQtYXBwLXJlZ2lvbjogbm8tZHJhZzsgYXBwLXJlZ2lvbjogbm8tZHJhZzsKICAgICAgICAgICAg
dHJhbnNpdGlvbjogYmFja2dyb3VuZCB2YXIoLS10ciksIGNvbG9yIHZhcigtLXRyKSwgYm9yZGVyLWNv
bG9yIHZhcigtLXRyKTsKICAgICAgICB9CiAgICAgICAgLnB0LWhlYWQtYnRuOmhvdmVyIHsKICAgICAg
ICAgICAgYmFja2dyb3VuZDogcmdiYSgxMDcsMTEyLDEyOCwuMTIpOyBjb2xvcjogdmFyKC0tdHh0Mik7
CiAgICAgICAgICAgIGJvcmRlci1jb2xvcjogcmdiYSgxMDcsMTEyLDEyOCwuNCk7CiAgICAgICAgfQog
ICAgICAgIC5wdC1saXN0IHsgcGFkZGluZzogNnB4IDhweCA4cHg7IGRpc3BsYXk6IGZsZXg7IGZsZXgt
ZGlyZWN0aW9uOiBjb2x1bW47IGdhcDogNHB4OyB9CiAgICAgICAgLnB0LXJvdyB7CiAgICAgICAgICAg
IGRpc3BsYXk6IGdyaWQ7IGdyaWQtdGVtcGxhdGUtY29sdW1uczogOHB4IDFmcjsgZ2FwOiA4cHg7CiAg
ICAgICAgICAgIHBhZGRpbmc6IDhweCA4cHg7IGJvcmRlci1yYWRpdXM6IDhweDsKICAgICAgICAgICAg
YmFja2dyb3VuZDogcmdiYSgyNTUsMjU1LDI1NSwuNyk7CiAgICAgICAgfQogICAgICAgIC5wdC1yb3cu
ZGVhZCB7IGJhY2tncm91bmQ6IHJnYmEoMjU1LCAxMjMsIDE1NiwgLjA2KTsgfQogICAgICAgIC5wdC1k
b3QgewogICAgICAgICAgICB3aWR0aDogOHB4OyBoZWlnaHQ6IDhweDsgYm9yZGVyLXJhZGl1czogNTAl
OyBtYXJnaW4tdG9wOiA1cHg7CiAgICAgICAgICAgIGJhY2tncm91bmQ6ICMyZWI0Nzg7IGJveC1zaGFk
b3c6IDAgMCAwIDNweCByZ2JhKDQ2LCAxODAsIDEyMCwgLjE4KTsKICAgICAgICB9CiAgICAgICAgLnB0
LXJvdy5kZWFkIC5wdC1kb3QgewogICAgICAgICAgICBiYWNrZ3JvdW5kOiAjZTg1YTdhOyBib3gtc2hh
ZG93OiAwIDAgMCAzcHggcmdiYSgyMzIsIDkwLCAxMjIsIC4xNik7CiAgICAgICAgfQogICAgICAgIC5w
dC1uYW1lIHsKICAgICAgICAgICAgZm9udC1zaXplOiAxMnB4OyBmb250LXdlaWdodDogNjUwOyBjb2xv
cjogdmFyKC0tdHh0KTsKICAgICAgICAgICAgbGluZS1oZWlnaHQ6IDEuMzsgd29yZC1icmVhazogYnJl
YWstYWxsOwogICAgICAgIH0KICAgICAgICAucHQtcGF0aCB7CiAgICAgICAgICAgIG1hcmdpbi10b3A6
IDNweDsKICAgICAgICAgICAgZm9udDogMTAuNXB4LzEuNDUgJ0Nhc2NhZGlhIE1vbm8nLCdDb25zb2xh
cycsJ01pY3Jvc29mdCBZYUhlaSBVSScsbW9ub3NwYWNlOwogICAgICAgICAgICBjb2xvcjogdmFyKC0t
dHh0Mik7IHdvcmQtYnJlYWs6IGJyZWFrLWFsbDsKICAgICAgICAgICAgdXNlci1zZWxlY3Q6IHRleHQ7
CiAgICAgICAgfQogICAgICAgIC5wdC1wYXRoLmxpdmUgewogICAgICAgICAgICBjb2xvcjogdmFyKC0t
YWNjKTsgY3Vyc29yOiBwb2ludGVyOwogICAgICAgIH0KICAgICAgICAucHQtcGF0aC5saXZlOmhvdmVy
IHsgdGV4dC1kZWNvcmF0aW9uOiB1bmRlcmxpbmU7IH0KICAgICAgICAucHQtcGF0aC5kZWFkIHsKICAg
ICAgICAgICAgY29sb3I6ICNjNDNkNWM7CiAgICAgICAgICAgIHRleHQtZGVjb3JhdGlvbjogbGluZS10
aHJvdWdoOwogICAgICAgICAgICB0ZXh0LWRlY29yYXRpb24tdGhpY2tuZXNzOiAycHg7CiAgICAgICAg
ICAgIHRleHQtZGVjb3JhdGlvbi1jb2xvcjogI2UxMWQ0ODsKICAgICAgICAgICAgY3Vyc29yOiBkZWZh
dWx0OwogICAgICAgIH0KICAgICAgICAucHQtYWN0aW9ucyB7CiAgICAgICAgICAgIG1hcmdpbi10b3A6
IDZweDsKICAgICAgICAgICAgZGlzcGxheTogZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsgZ2FwOiA2
cHg7IGZsZXgtd3JhcDogd3JhcDsKICAgICAgICB9CiAgICAgICAgLnB0LWNvcHktYnRuIHsKICAgICAg
ICAgICAgaGVpZ2h0OiAyMnB4OyBwYWRkaW5nOiAwIDhweDsgZGlzcGxheTogaW5saW5lLWZsZXg7IGFs
aWduLWl0ZW1zOiBjZW50ZXI7CiAgICAgICAgICAgIGJvcmRlcjogMXB4IHNvbGlkIHJnYmEoMTA3LDEx
MiwxMjgsLjIyKTsgYm9yZGVyLXJhZGl1czogNnB4OyBjdXJzb3I6IHBvaW50ZXI7CiAgICAgICAgICAg
IGJhY2tncm91bmQ6IHJnYmEoMTA3LDExMiwxMjgsLjA2KTsgY29sb3I6ICM4YTkwYTA7IGZvbnQtc2l6
ZTogMTFweDsgZm9udC13ZWlnaHQ6IDYwMDsKICAgICAgICAgICAgLXdlYmtpdC1hcHAtcmVnaW9uOiBu
by1kcmFnOyBhcHAtcmVnaW9uOiBuby1kcmFnOwogICAgICAgICAgICB0cmFuc2l0aW9uOiBiYWNrZ3Jv
dW5kIHZhcigtLXRyKSwgY29sb3IgdmFyKC0tdHIpLCBib3JkZXItY29sb3IgdmFyKC0tdHIpOwogICAg
ICAgIH0KICAgICAgICAucHQtY29weS1idG46aG92ZXIgewogICAgICAgICAgICBiYWNrZ3JvdW5kOiBy
Z2JhKDEwNywxMTIsMTI4LC4xMik7IGNvbG9yOiB2YXIoLS10eHQyKTsKICAgICAgICAgICAgYm9yZGVy
LWNvbG9yOiByZ2JhKDEwNywxMTIsMTI4LC40KTsKICAgICAgICB9CiAgICAgICAgLnB0LWNvcHktYnRu
Lm9rIHsKICAgICAgICAgICAgY29sb3I6ICMxZjdhNTU7IGJvcmRlci1jb2xvcjogcmdiYSg0NiwgMTgw
LCAxMjAsIC4zNSk7CiAgICAgICAgICAgIGJhY2tncm91bmQ6IHJnYmEoNDYsIDE4MCwgMTIwLCAuMSk7
CiAgICAgICAgfQogICAgICAgIC5pdG0uaXQtZ3JvdXAgewogICAgICAgICAgICBmbGV4LWRpcmVjdGlv
bjogY29sdW1uOwogICAgICAgICAgICBhbGlnbi1pdGVtczogc3RyZXRjaDsKICAgICAgICAgICAgZ2Fw
OiAwOwogICAgICAgICAgICBwYWRkaW5nOiA2cHggOHB4IDRweDsKICAgICAgICAgICAgY3Vyc29yOiBk
ZWZhdWx0OwogICAgICAgIH0KICAgICAgICAuaXRtLml0LWdyb3VwOmhvdmVyIHsgYmFja2dyb3VuZDog
dmFyKC0tY2FyZCk7IH0KICAgICAgICAubWctaGVhZCB7CiAgICAgICAgICAgIGRpc3BsYXk6IGZsZXg7
IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGdhcDogNnB4OwogICAgICAgICAgICBmb250LXNpemU6IDExcHg7
IGNvbG9yOiB2YXIoLS10eHQzKTsgZm9udC13ZWlnaHQ6IDYwMDsKICAgICAgICAgICAgcGFkZGluZzog
MnB4IDJweCA2cHg7IHVzZXItc2VsZWN0OiBub25lOwogICAgICAgIH0KICAgICAgICAubWctaGVhZCAu
bWctdGFnIHsKICAgICAgICAgICAgZGlzcGxheTogaW5saW5lLWZsZXg7IGFsaWduLWl0ZW1zOiBjZW50
ZXI7CiAgICAgICAgICAgIGhlaWdodDogMTZweDsgcGFkZGluZzogMCA2cHg7IGJvcmRlci1yYWRpdXM6
IDhweDsKICAgICAgICAgICAgYmFja2dyb3VuZDogcmdiYSg5MSwxMTUsMjMyLC4xMik7IGNvbG9yOiB2
YXIoLS1hY2MpOyBmb250LXNpemU6IDEwcHg7CiAgICAgICAgfQogICAgICAgIC5tZy1yb3cgewogICAg
ICAgICAgICBwYWRkaW5nOiA3cHggNnB4OyBtYXJnaW4tYm90dG9tOiAzcHg7CiAgICAgICAgICAgIGJv
cmRlci1yYWRpdXM6IDVweDsgY3Vyc29yOiBwb2ludGVyOwogICAgICAgICAgICBib3JkZXI6IDFweCBz
b2xpZCB0cmFuc3BhcmVudDsKICAgICAgICAgICAgdHJhbnNpdGlvbjogYmFja2dyb3VuZCAuMTJzIGVh
c2UsIGJvcmRlci1jb2xvciAuMTJzIGVhc2U7CiAgICAgICAgfQogICAgICAgIC5tZy1yb3c6aG92ZXIg
eyBiYWNrZ3JvdW5kOiB2YXIoLS1jYXJkLWgpOyB9CiAgICAgICAgLm1nLXJvdy5zZWwgewogICAgICAg
ICAgICBiYWNrZ3JvdW5kOiAjZWRmMWZmOwogICAgICAgICAgICBib3JkZXItY29sb3I6IHJnYmEoOTEs
MTE1LDIzMiwuMzUpOwogICAgICAgICAgICBib3gtc2hhZG93OiAwIDAgMCAxcHggcmdiYSg5MSwxMTUs
MjMyLC4yNSk7CiAgICAgICAgfQogICAgICAgIC5tZy1yb3cubXVsdGkgewogICAgICAgICAgICBiYWNr
Z3JvdW5kOiAjZWVmMmZmOwogICAgICAgICAgICBib3JkZXItY29sb3I6IHJnYmEoOTEsMTE1LDIzMiwu
NDUpOwogICAgICAgIH0KICAgICAgICAubWctdGl0bGUgewogICAgICAgICAgICBmb250LXNpemU6IDEz
cHg7IGZvbnQtd2VpZ2h0OiA2MDA7IGNvbG9yOiB2YXIoLS1hY2MpOwogICAgICAgICAgICBtYXJnaW4t
Ym90dG9tOiAycHg7IGxpbmUtaGVpZ2h0OiAxLjM1OwogICAgICAgICAgICBkaXNwbGF5OiAtd2Via2l0
LWJveDsgLXdlYmtpdC1ib3gtb3JpZW50OiB2ZXJ0aWNhbDsgLXdlYmtpdC1saW5lLWNsYW1wOiAyOwog
ICAgICAgICAgICBvdmVyZmxvdzogaGlkZGVuOyB3b3JkLWJyZWFrOiBicmVhay13b3JkOwogICAgICAg
IH0KICAgICAgICAubWctYm9keSB7CiAgICAgICAgICAgIGZvbnQtc2l6ZTogMTIuNXB4OyBmb250LXdl
aWdodDogNTAwOyBjb2xvcjogdmFyKC0tdHh0KTsKICAgICAgICAgICAgd2hpdGUtc3BhY2U6IHByZS13
cmFwOyB3b3JkLWJyZWFrOiBicmVhay1hbGw7CiAgICAgICAgICAgIGRpc3BsYXk6IC13ZWJraXQtYm94
OyAtd2Via2l0LWJveC1vcmllbnQ6IHZlcnRpY2FsOyAtd2Via2l0LWxpbmUtY2xhbXA6IDQ7CiAgICAg
ICAgICAgIG92ZXJmbG93OiBoaWRkZW47IGxpbmUtaGVpZ2h0OiAxLjQ7CiAgICAgICAgfQogICAgICAg
IC5tZy1ib2R5LmltZyB7IGNvbG9yOiB2YXIoLS10eHQyKTsgfQogICAgICAgIC5tZy1yb3ctdG9wIHsK
ICAgICAgICAgICAgZGlzcGxheTogZmxleDsgYWxpZ24taXRlbXM6IGZsZXgtc3RhcnQ7IGdhcDogOHB4
OwogICAgICAgIH0KICAgICAgICAubWctcm93LW1haW4geyBmbGV4OiAxOyBtaW4td2lkdGg6IDA7IH0K
ICAgICAgICAubWctc3JjIHsKICAgICAgICAgICAgd2lkdGg6IDE4cHg7IGhlaWdodDogMThweDsgZmxl
eC1zaHJpbms6IDA7IG1hcmdpbi10b3A6IDJweDsKICAgICAgICAgICAgYm9yZGVyLXJhZGl1czogM3B4
OyBvYmplY3QtZml0OiBjb250YWluOwogICAgICAgICAgICBiYWNrZ3JvdW5kOiByZ2JhKDAsMCwwLC4w
NCk7CiAgICAgICAgfQogICAgICAgIC5pLWZhdi10aXRsZSB7CiAgICAgICAgICAgIGZvbnQtc2l6ZTog
MTNweDsgZm9udC13ZWlnaHQ6IDYwMDsgY29sb3I6IHZhcigtLWFjYyk7CiAgICAgICAgICAgIG1hcmdp
bjogMCAwIDNweDsgbGluZS1oZWlnaHQ6IDEuMzU7CiAgICAgICAgICAgIGRpc3BsYXk6IC13ZWJraXQt
Ym94OyAtd2Via2l0LWJveC1vcmllbnQ6IHZlcnRpY2FsOyAtd2Via2l0LWxpbmUtY2xhbXA6IDI7CiAg
ICAgICAgICAgIG92ZXJmbG93OiBoaWRkZW47IHdvcmQtYnJlYWs6IGJyZWFrLXdvcmQ7CiAgICAgICAg
fQogICAgICAgICN0aXRsZS1kbGcgewogICAgICAgICAgICBkaXNwbGF5OiBub25lOyBwb3NpdGlvbjog
Zml4ZWQ7IGluc2V0OiAwOyB6LWluZGV4OiAxMDA7CiAgICAgICAgICAgIGJhY2tncm91bmQ6IHJnYmEo
MTUsMTgsMjgsLjM1KTsKICAgICAgICAgICAgYWxpZ24taXRlbXM6IGNlbnRlcjsganVzdGlmeS1jb250
ZW50OiBjZW50ZXI7CiAgICAgICAgfQogICAgICAgICN0aXRsZS1kbGcub24geyBkaXNwbGF5OiBmbGV4
OyB9CiAgICAgICAgI3RpdGxlLWRsZyAudGl0bGUtYm94IHsKICAgICAgICAgICAgd2lkdGg6IDI2MHB4
OyBwYWRkaW5nOiAxNnB4IDE2cHggMTJweDsKICAgICAgICAgICAgYmFja2dyb3VuZDogdmFyKC0tY2Fy
ZCk7IGJvcmRlci1yYWRpdXM6IDEwcHg7CiAgICAgICAgICAgIGJveC1zaGFkb3c6IDAgOHB4IDI4cHgg
cmdiYSgwLDAsMCwuMTgpOwogICAgICAgIH0KICAgICAgICAjdGl0bGUtaW5wdXQgewogICAgICAgICAg
ICB3aWR0aDogMTAwJTsgYm94LXNpemluZzogYm9yZGVyLWJveDsgbWFyZ2luOiA4cHggMCAxMnB4Owog
ICAgICAgICAgICBoZWlnaHQ6IDMycHg7IHBhZGRpbmc6IDAgMTBweDsgYm9yZGVyLXJhZGl1czogNnB4
OwogICAgICAgICAgICBib3JkZXI6IDFweCBzb2xpZCAjZDVkYWU2OyBiYWNrZ3JvdW5kOiAjZmZmOyBj
b2xvcjogdmFyKC0tdHh0KTsKICAgICAgICAgICAgZm9udC1zaXplOiAxM3B4OyBvdXRsaW5lOiBub25l
OwogICAgICAgIH0KICAgICAgICAjdGl0bGUtaW5wdXQ6Zm9jdXMgeyBib3JkZXItY29sb3I6IHZhcigt
LWFjYyk7IH0KCiAgICAKICAgICAgICAvKiB1aS1ncmF5LWJnLXYxICovCiAgICAgICAgOnJvb3Qgewog
ICAgICAgICAgICAtLWJnOiAjZTRlN2VlICFpbXBvcnRhbnQ7CiAgICAgICAgfQogICAgICAgIGh0bWws
IGJvZHkgewogICAgICAgICAgICBiYWNrZ3JvdW5kOiAjZTRlN2VlICFpbXBvcnRhbnQ7CiAgICAgICAg
fQogICAgICAgICNhcHAgewogICAgICAgICAgICBiYWNrZ3JvdW5kOiBsaW5lYXItZ3JhZGllbnQoMTgw
ZGVnLCAjZTllY2YzIDAlLCAjZTBlNGVjIDEwMCUpICFpbXBvcnRhbnQ7CiAgICAgICAgfQogICAgICAg
ICNoZHIgewogICAgICAgICAgICBiYWNrZ3JvdW5kOiAjZTJlNmVlICFpbXBvcnRhbnQ7CiAgICAgICAg
fQogICAgICAgICN0YWJzIHsKICAgICAgICAgICAgYmFja2dyb3VuZDogI2UyZTZlZSAhaW1wb3J0YW50
OwogICAgICAgIH0KICAgICAgICAjbGlzdCwgI2VtcHR5LCAjc2tlbCwgI2hkci1ncm93LCAjc2VhcmNo
LXdyYXAgewogICAgICAgICAgICBiYWNrZ3JvdW5kOiB0cmFuc3BhcmVudCAhaW1wb3J0YW50OwogICAg
ICAgIH0KICAgICAgICAjc2VhcmNoLWJveCB7CiAgICAgICAgICAgIHRyYW5zZm9ybS1vcmlnaW46IHJp
Z2h0IGNlbnRlcjsKICAgICAgICAgICAgYmFja2dyb3VuZDogdHJhbnNwYXJlbnQgIWltcG9ydGFudDsK
ICAgICAgICB9CiAgICAgICAgLml0bSwgLm1nLCAubWctcm93LCAubWVyZ2UtZ3JvdXAgewogICAgICAg
ICAgICBiYWNrZ3JvdW5kOiAjZmZmZmZmICFpbXBvcnRhbnQ7CiAgICAgICAgfQogICAgICAgIC5pdG06
aG92ZXIgewogICAgICAgICAgICBiYWNrZ3JvdW5kOiAjZjhmOWZjICFpbXBvcnRhbnQ7CiAgICAgICAg
fQogICAgCiAgICAgICAgLyogc2VsLXRpbnQtYmx1ZS12MSAqLwogICAgICAgIC5pdG0uc2VsLAogICAg
ICAgIC5tZy1yb3cuc2VsLAogICAgICAgIC5pdG0ubXVsdGksCiAgICAgICAgLm1nLXJvdy5tdWx0aSwK
ICAgICAgICAuaXRtLm11bHRpLnNlbCwKICAgICAgICAuaXQtZ3JvdXAuc2VsLAogICAgICAgIC5pdC1n
cm91cC5tdWx0aSB7CiAgICAgICAgICAgIGJhY2tncm91bmQ6ICNlOGVmZmYgIWltcG9ydGFudDsKICAg
ICAgICB9CiAgICAgICAgLml0bS5zZWw6aG92ZXIsCiAgICAgICAgLml0bS5tdWx0aTpob3ZlciwKICAg
ICAgICAubWctcm93LnNlbDpob3ZlciwKICAgICAgICAubWctcm93Lm11bHRpOmhvdmVyIHsKICAgICAg
ICAgICAgYmFja2dyb3VuZDogI2RkZTZmZiAhaW1wb3J0YW50OwogICAgICAgIH0KICAgIAogICAgICAg
IC8qIGhvdmVyLWdyZWVuLXJpc2UtdjIgKi8KICAgICAgICAvKiBob3Zlci1hY2NlbnQtcmlzZS12MyAq
LwogICAgICAgIC5pdG0geyBwb3NpdGlvbjogcmVsYXRpdmUgIWltcG9ydGFudDsgb3ZlcmZsb3c6IGhp
ZGRlbiAhaW1wb3J0YW50OyB9CiAgICAgICAgLml0bTo6YmVmb3JlIHsKICAgICAgICAgICAgY29udGVu
dDogIiIgIWltcG9ydGFudDsKICAgICAgICAgICAgcG9zaXRpb246IGFic29sdXRlICFpbXBvcnRhbnQ7
CiAgICAgICAgICAgIGxlZnQ6IDAgIWltcG9ydGFudDsgcmlnaHQ6IDAgIWltcG9ydGFudDsgYm90dG9t
OiAwICFpbXBvcnRhbnQ7CiAgICAgICAgICAgIGhlaWdodDogMCAhaW1wb3J0YW50OwogICAgICAgICAg
ICBwb2ludGVyLWV2ZW50czogbm9uZSAhaW1wb3J0YW50OwogICAgICAgICAgICB6LWluZGV4OiAwICFp
bXBvcnRhbnQ7CiAgICAgICAgICAgIGJvcmRlci1yYWRpdXM6IDAgMCB2YXIoLS1yLCA0cHgpIHZhcigt
LXIsIDRweCkgIWltcG9ydGFudDsKICAgICAgICAgICAgYmFja2dyb3VuZDogbGluZWFyLWdyYWRpZW50
KHRvIHRvcCwKICAgICAgICAgICAgICAgIHJnYmEoOTEsIDExNSwgMjMyLCAuMzIpIDAlLAogICAgICAg
ICAgICAgICAgcmdiYSg5MSwgMTE1LCAyMzIsIC4xMikgNTUlLAogICAgICAgICAgICAgICAgcmdiYSg5
MSwgMTE1LCAyMzIsIDApIDEwMCUpICFpbXBvcnRhbnQ7CiAgICAgICAgICAgIHRyYW5zaXRpb246IGhl
aWdodCAuMzRzIGN1YmljLWJlemllciguMjIsIDEsIC4zNiwgMSkgIWltcG9ydGFudDsKICAgICAgICB9
CiAgICAgICAgLml0bTpob3Zlcjo6YmVmb3JlIHsgaGVpZ2h0OiAzMy4zMzMlICFpbXBvcnRhbnQ7IH0K
ICAgICAgICAuaXRtOjphZnRlciB7CiAgICAgICAgICAgIGNvbnRlbnQ6ICIiICFpbXBvcnRhbnQ7CiAg
ICAgICAgICAgIHBvc2l0aW9uOiBhYnNvbHV0ZSAhaW1wb3J0YW50OwogICAgICAgICAgICBsZWZ0OiAw
ICFpbXBvcnRhbnQ7IHJpZ2h0OiAwICFpbXBvcnRhbnQ7IGJvdHRvbTogMCAhaW1wb3J0YW50OwogICAg
ICAgICAgICBoZWlnaHQ6IDJweCAhaW1wb3J0YW50OwogICAgICAgICAgICBwb2ludGVyLWV2ZW50czog
bm9uZSAhaW1wb3J0YW50OwogICAgICAgICAgICB6LWluZGV4OiAxICFpbXBvcnRhbnQ7CiAgICAgICAg
ICAgIGJhY2tncm91bmQ6IHJnYmEoOTEsIDExNSwgMjMyLCAuOTIpICFpbXBvcnRhbnQ7CiAgICAgICAg
ICAgIGJvcmRlci1yYWRpdXM6IDFweCAhaW1wb3J0YW50OwogICAgICAgICAgICB0cmFuc2Zvcm06IHNj
YWxlWCgwKSAhaW1wb3J0YW50OwogICAgICAgICAgICB0cmFuc2Zvcm0tb3JpZ2luOiBjZW50ZXIgIWlt
cG9ydGFudDsKICAgICAgICAgICAgdHJhbnNpdGlvbjogdHJhbnNmb3JtIC4zcyBjdWJpYy1iZXppZXIo
LjIyLCAxLCAuMzYsIDEpICFpbXBvcnRhbnQ7CiAgICAgICAgfQogICAgICAgIC5pdG06aG92ZXI6OmFm
dGVyIHsKICAgICAgICAgICAgdHJhbnNmb3JtOiBzY2FsZVgoMSkgIWltcG9ydGFudDsKICAgICAgICAg
ICAgYmFja2dyb3VuZDogcmdiYSg5MSwgMTE1LCAyMzIsIC45NSkgIWltcG9ydGFudDsKICAgICAgICB9
CiAgICAgICAgLml0bSA+ICogeyBwb3NpdGlvbjogcmVsYXRpdmU7IHotaW5kZXg6IDI7IH0KICAgICAg
ICAvKiDljrvmjonpnaLmnb/mnIDlpJbmj4/ovrnvvJvmnaHnm67ljaHniYfovbvmgqzmta7ljprluqYg
Ki8KICAgICAgICBodG1sLCBib2R5LCAjYXBwIHsKICAgICAgICAgICAgYm9yZGVyOiBub25lICFpbXBv
cnRhbnQ7CiAgICAgICAgICAgIG91dGxpbmU6IG5vbmUgIWltcG9ydGFudDsKICAgICAgICAgICAgYm94
LXNoYWRvdzogbm9uZSAhaW1wb3J0YW50OwogICAgICAgIH0KICAgICAgICAjYXBwIHsKICAgICAgICAg
ICAgYm9yZGVyLXJhZGl1czogMCAhaW1wb3J0YW50OwogICAgICAgICAgICBib3gtc2l6aW5nOiBib3Jk
ZXItYm94ICFpbXBvcnRhbnQ7CiAgICAgICAgICAgIG92ZXJmbG93OiBoaWRkZW4gIWltcG9ydGFudDsK
ICAgICAgICB9CiAgICAgICAgLml0bSwgLm1nLCAubWVyZ2UtZ3JvdXAgewogICAgICAgICAgICBib3Jk
ZXI6IG5vbmUgIWltcG9ydGFudDsKICAgICAgICAgICAgYm9yZGVyLXJhZGl1czogNHB4ICFpbXBvcnRh
bnQ7CiAgICAgICAgICAgIGJveC1zaGFkb3c6CiAgICAgICAgICAgICAgICAwIDFweCAycHggcmdiYSgy
NCwgMzIsIDU2LCAuMDUpLAogICAgICAgICAgICAgICAgMCAzcHggMTBweCByZ2JhKDI0LCAzMiwgNTYs
IC4wOSkgIWltcG9ydGFudDsKICAgICAgICB9CiAgICAgICAgLml0bTpob3ZlciwgLm1nOmhvdmVyLCAu
bWVyZ2UtZ3JvdXA6aG92ZXIgewogICAgICAgICAgICBib3gtc2hhZG93OgogICAgICAgICAgICAgICAg
MCAycHggNHB4IHJnYmEoMjQsIDMyLCA1NiwgLjA3KSwKICAgICAgICAgICAgICAgIDAgNnB4IDE2cHgg
cmdiYSgyNCwgMzIsIDU2LCAuMTMpICFpbXBvcnRhbnQ7CiAgICAgICAgfQogICAgICAgIC5pdG0uc2Vs
LAogICAgICAgIC5tZy1yb3cuc2VsLAogICAgICAgIC5pdG0ubXVsdGksCiAgICAgICAgLm1nLXJvdy5t
dWx0aSwKICAgICAgICAuaXRtLm11bHRpLnNlbCwKICAgICAgICAuaXQtZ3JvdXAuc2VsLAogICAgICAg
IC5pdC1ncm91cC5tdWx0aSB7CiAgICAgICAgICAgIGJveC1zaGFkb3c6CiAgICAgICAgICAgICAgICAw
IDAgMCAycHggcmdiYSg5MSwgMTE1LCAyMzIsIC40MiksCiAgICAgICAgICAgICAgICAwIDJweCA0cHgg
cmdiYSg5MSwgMTE1LCAyMzIsIC4xMCksCiAgICAgICAgICAgICAgICAwIDZweCAxNHB4IHJnYmEoOTEs
IDExNSwgMjMyLCAuMTYpICFpbXBvcnRhbnQ7CiAgICAgICAgfQogICAgPC9zdHlsZT4KPC9oZWFkPgo8
Ym9keSBkYXRhLXVpLWJ1aWxkPSIyMDI2MDkwNy0yMzA3Ij4KPGRpdiBpZD0iYXBwIiBkYXRhLXVpLXZl
cj0iMjAyNjA5MDgtcGluLXN5bmMiPgogICAgPGRpdiBpZD0iaGRyIj4KICAgICAgICA8ZGl2IGlkPSJo
ZWFydCI+CiAgICAgICAgICAgIDxzdmcgdmlld0JveD0iMCAwIDI0IDI0IiBmaWxsPSJub25lIiBzdHJv
a2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIxLjgiCiAgICAgICAgICAgICAgICAgc3Ryb2tl
LWxpbmVjYXA9InJvdW5kIiBzdHJva2UtbGluZWpvaW49InJvdW5kIj4KICAgICAgICAgICAgICAgIDxy
ZWN0IHg9IjkiIHk9IjIiIHdpZHRoPSI2IiBoZWlnaHQ9IjQiIHJ4PSIxIi8+CiAgICAgICAgICAgICAg
ICA8cGF0aCBkPSJNMTYgNGgyYTIgMiAwIDAgMSAyIDJ2MTRhMiAyIDAgMCAxLTIgMkg2YTIgMiAwIDAg
MS0yLTJWNmEyIDIgMCAwIDEgMi0yaDIiLz4KICAgICAgICAgICAgICAgIDxwYXRoIGQ9Ik05IDEyaDZN
OSAxNmg0Ii8+CiAgICAgICAgICAgIDwvc3ZnPgogICAgICAgIDwvZGl2PgogICAgICAgIDxkaXYgaWQ9
Imhkci1ncm93Ij48L2Rpdj4KICAgICAgICA8ZGl2IGlkPSJtdWx0aS1iYXIiPgogICAgICAgICAgICA8
YnV0dG9uIGlkPSJtdWx0aS1zZWwiIHR5cGU9ImJ1dHRvbiIgdGl0bGU9IuWPlua2iOWkmumAiSI+CiAg
ICAgICAgICAgICAgICA8c3BhbiBpZD0ibXVsdGktc2VsLWxhYiI+5bey6YCJPC9zcGFuPgogICAgICAg
ICAgICAgICAgPHNwYW4gaWQ9Im11bHRpLWNudCI+MDwvc3Bhbj4KICAgICAgICAgICAgPC9idXR0b24+
CiAgICAgICAgICAgIDxkaXYgaWQ9InBhc3RlLXNlcC13cmFwIj4KICAgICAgICAgICAgICAgIDxidXR0
b24gaWQ9InBhc3RlLXNlcC1idG4iIHR5cGU9ImJ1dHRvbiIgdGl0bGU9IueymOi0tOWIhumalOespu+8
iOeCuemAieeUqOW5tueymOi0tO+8iSI+CiAgICAgICAgICAgICAgICAgICAgPHNwYW4gaWQ9InBhc3Rl
LXNlcC1sYWJlbCI+4pCjPC9zcGFuPgogICAgICAgICAgICAgICAgPC9idXR0b24+CiAgICAgICAgICAg
ICAgICA8ZGl2IGlkPSJwYXN0ZS1zZXAtbWVudSI+PC9kaXY+CiAgICAgICAgICAgIDwvZGl2PgogICAg
ICAgIDwvZGl2PgogICAgICAgIDxidXR0b24gaWQ9ImJ0bi1sb2NhdGUiIHR5cGU9ImJ1dHRvbiIgdGl0
bGU9IuWumuS9jeWIsOS4iuasoeS9v+eUqOeahOadoeebriIgZGlzYWJsZWQ+CiAgICAgICAgICAgIDxz
dmcgdmlld0JveD0iMCAwIDI0IDI0IiBmaWxsPSJub25lIiBzdHJva2U9ImN1cnJlbnRDb2xvciIgc3Ry
b2tlLXdpZHRoPSIyIgogICAgICAgICAgICAgICAgIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIgc3Ryb2tl
LWxpbmVqb2luPSJyb3VuZCI+CiAgICAgICAgICAgICAgICA8Y2lyY2xlIGN4PSIxMiIgY3k9IjEyIiBy
PSI4Ii8+CiAgICAgICAgICAgICAgICA8Y2lyY2xlIGN4PSIxMiIgY3k9IjEyIiByPSIzLjUiLz4KICAg
ICAgICAgICAgPC9zdmc+CiAgICAgICAgPC9idXR0b24+CiAgICAgICAgPGRpdiBpZD0ic2VhcmNoLXdy
YXAiPgogICAgICAgICAgICA8YnV0dG9uIGlkPSJidG4tc2VhcmNoIiB0eXBlPSJidXR0b24iIHRpdGxl
PSLmkJzntKIiPgogICAgICAgICAgICAgICAgPHN2ZyB2aWV3Qm94PSIwIDAgMjQgMjQiIGZpbGw9Im5v
bmUiIHN0cm9rZT0iY3VycmVudENvbG9yIiBzdHJva2Utd2lkdGg9IjIiCiAgICAgICAgICAgICAgICAg
ICAgIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIgc3Ryb2tlLWxpbmVqb2luPSJyb3VuZCI+CiAgICAgICAg
ICAgICAgICAgICAgPGNpcmNsZSBjeD0iMTEiIGN5PSIxMSIgcj0iNyIvPgogICAgICAgICAgICAgICAg
ICAgIDxwYXRoIGQ9Ik0yMCAyMGwtMy41LTMuNSIvPgogICAgICAgICAgICAgICAgPC9zdmc+CiAgICAg
ICAgICAgIDwvYnV0dG9uPgogICAgICAgICAgICA8ZGl2IGlkPSJzZWFyY2gtYm94Ij4KICAgICAgICAg
ICAgICAgIDxidXR0b24gaWQ9ImJ0bi10b2RheSIgdHlwZT0iYnV0dG9uIj7lvZPlpKk8L2J1dHRvbj4K
ICAgICAgICAgICAgICAgIDxpbnB1dCBpZD0ic2VhcmNoIiB0eXBlPSJ0ZXh0IiBwbGFjZWhvbGRlcj0i
5pCc57Si4oCmIOepuuagvOWIhuivjemhu+WQjOaXtuWMheWQqyDCtyBhfGIg5YiG5q61IiBhdXRvY29t
cGxldGU9Im9mZiIgc3BlbGxjaGVjaz0iZmFsc2UiPgogICAgICAgICAgICAgICAgPGJ1dHRvbiBpZD0i
c2VhcmNoLWNsciIgdHlwZT0iYnV0dG9uIj7inJU8L2J1dHRvbj4KICAgICAgICAgICAgPC9kaXY+CiAg
ICAgICAgPC9kaXY+CiAgICAgICAgPGJ1dHRvbiBpZD0iYnRuLXBpbiIgdHlwZT0iYnV0dG9uIiB0aXRs
ZT0i6ZKJ5Zyo5bGP5bmV5LiKIj4KICAgICAgICAgICAgPHN2ZyB2aWV3Qm94PSIwIDAgMjQgMjQiIGZp
bGw9Im5vbmUiIHN0cm9rZT0iY3VycmVudENvbG9yIiBzdHJva2Utd2lkdGg9IjIiCiAgICAgICAgICAg
ICAgICAgc3Ryb2tlLWxpbmVqb2luPSJyb3VuZCIgc3Ryb2tlLWxpbmVjYXA9InJvdW5kIj4KICAgICAg
ICAgICAgICAgIDxsaW5lIHgxPSIxMiIgeTE9IjE3IiB4Mj0iMTIiIHkyPSIyMiIvPgogICAgICAgICAg
ICAgICAgPHBhdGggZD0iTTUgMTdoMTR2LTEuNzZhMiAyIDAgMCAwLTEuMTEtMS43OWwtMS43OC0uOUEy
IDIgMCAwIDEgMTUgMTAuNzZWNmgxYTIgMiAwIDAgMCAwLTRIOGEyIDIgMCAwIDAgMCA0aDF2NC43NmEy
IDIgMCAwIDEtMS4xMSAxLjc5bC0xLjc4LjlBMiAyIDAgMCAwIDUgMTUuMjRaIi8+CiAgICAgICAgICAg
IDwvc3ZnPgogICAgICAgIDwvYnV0dG9uPgogICAgPC9kaXY+CgogICAgPGRpdiBpZD0idGFicyI+CiAg
ICAgICAgPGRpdiBpZD0idGFiLWluayIgYXJpYS1oaWRkZW49InRydWUiPjwvZGl2PgogICAgICAgIDxk
aXYgY2xhc3M9InRhYiBvbiIgZGF0YS10YWI9ImFsbCI+5YWo6YOoPC9kaXY+CiAgICAgICAgPGRpdiBj
bGFzcz0idGFiIiBkYXRhLXRhYj0idGV4dCI+5paH5pysPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0i
dGFiIiBkYXRhLXRhYj0iaW1hZ2UiPuWbvuWDjzwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9InRhYiIg
ZGF0YS10YWI9ImZpbGUiPuaWh+S7tjwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9InRhYiIgZGF0YS10
YWI9InJlY2VudCI+5pyA6L+RPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0idGFiIiBkYXRhLXRhYj0i
cGlubmVkIj7mlLbol48gPHNwYW4gaWQ9InBpbi1kb3QiIHRpdGxlPSLmnInmlrDmlLbol48iPjwvc3Bh
bj48L2Rpdj4KICAgICAgICA8ZGl2IGlkPSJ0YWItYWN0aW9ucyI+CiAgICAgICAgICAgIDxzcGFuIGlk
PSJiYXItdHh0Ij4wPC9zcGFuPgogICAgICAgICAgICA8YnV0dG9uIGlkPSJidG4tY2xyIiB0eXBlPSJi
dXR0b24iIHRpdGxlPSLmuIXnqbrljoblj7IiPgogICAgICAgICAgICAgICAgPHN2ZyB2aWV3Qm94PSIw
IDAgMjQgMjQiIGZpbGw9Im5vbmUiIHN0cm9rZT0iY3VycmVudENvbG9yIiBzdHJva2Utd2lkdGg9IjIi
CiAgICAgICAgICAgICAgICAgICAgIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIgc3Ryb2tlLWxpbmVqb2lu
PSJyb3VuZCI+CiAgICAgICAgICAgICAgICAgICAgPHBvbHlsaW5lIHBvaW50cz0iMyA2IDUgNiAyMSA2
Ii8+CiAgICAgICAgICAgICAgICAgICAgPHBhdGggZD0iTTE5IDZsLTEgMTRhMiAyIDAgMCAxLTIgMkg4
YTIgMiAwIDAgMS0yLTJMNSA2Ii8+CiAgICAgICAgICAgICAgICAgICAgPHBhdGggZD0iTTEwIDExdjZN
MTQgMTF2Nk05IDZWNGg2djIiLz4KICAgICAgICAgICAgICAgIDwvc3ZnPgogICAgICAgICAgICA8L2J1
dHRvbj4KICAgICAgICA8L2Rpdj4KICAgIDwvZGl2PgoKICAgIDxkaXYgaWQ9Imxpc3QiPgogICAgICAg
IDxkaXYgaWQ9InNrZWwiIGFyaWEtaGlkZGVuPSJ0cnVlIj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0i
c2stcm93Ij48ZGl2IGNsYXNzPSJzay1pY28iPjwvZGl2PjxkaXYgY2xhc3M9InNrLWJvZHkiPjxkaXYg
Y2xhc3M9InNrLWxpbmUgbWlkIj48L2Rpdj48ZGl2IGNsYXNzPSJzay1saW5lIHNob3J0Ij48L2Rpdj48
L2Rpdj48L2Rpdj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0ic2stcm93Ij48ZGl2IGNsYXNzPSJzay1p
Y28iPjwvZGl2PjxkaXYgY2xhc3M9InNrLWJvZHkiPjxkaXYgY2xhc3M9InNrLWxpbmUiPjwvZGl2Pjxk
aXYgY2xhc3M9InNrLWxpbmUgbWlkIj48L2Rpdj48L2Rpdj48L2Rpdj4KICAgICAgICAgICAgPGRpdiBj
bGFzcz0ic2stcm93Ij48ZGl2IGNsYXNzPSJzay1pY28iPjwvZGl2PjxkaXYgY2xhc3M9InNrLWJvZHki
PjxkaXYgY2xhc3M9InNrLWxpbmUgbWlkIj48L2Rpdj48ZGl2IGNsYXNzPSJzay1saW5lIHNob3J0Ij48
L2Rpdj48L2Rpdj48L2Rpdj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0ic2stcm93Ij48ZGl2IGNsYXNz
PSJzay1pY28iPjwvZGl2PjxkaXYgY2xhc3M9InNrLWJvZHkiPjxkaXYgY2xhc3M9InNrLWxpbmUiPjwv
ZGl2PjxkaXYgY2xhc3M9InNrLWxpbmUgbWlkIj48L2Rpdj48L2Rpdj48L2Rpdj4KICAgICAgICAgICAg
PGRpdiBjbGFzcz0ic2stcm93Ij48ZGl2IGNsYXNzPSJzay1pY28iPjwvZGl2PjxkaXYgY2xhc3M9InNr
LWJvZHkiPjxkaXYgY2xhc3M9InNrLWxpbmUgbWlkIj48L2Rpdj48ZGl2IGNsYXNzPSJzay1saW5lIHNo
b3J0Ij48L2Rpdj48L2Rpdj48L2Rpdj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0ic2stcm93Ij48ZGl2
IGNsYXNzPSJzay1pY28iPjwvZGl2PjxkaXYgY2xhc3M9InNrLWJvZHkiPjxkaXYgY2xhc3M9InNrLWxp
bmUiPjwvZGl2PjxkaXYgY2xhc3M9InNrLWxpbmUgc2hvcnQiPjwvZGl2PjwvZGl2PjwvZGl2PgogICAg
ICAgIDwvZGl2PgogICAgICAgIDxkaXYgaWQ9ImVtcHR5Ij4KICAgICAgICAgICAgPGRpdiBjbGFzcz0i
ZS10eHQiIGlkPSJlbXB0eS10eHQiPuaaguaXoOiusOW9le+8jOWkjeWItuWQjuiHquWKqOWHuueOsDwv
ZGl2PgogICAgICAgIDwvZGl2PgogICAgPC9kaXY+CiAgICA8YnV0dG9uIGlkPSJidG4tdG9wIiB0eXBl
PSJidXR0b24iIHRpdGxlPSLlm57liLDpobbpg6giIGFyaWEtbGFiZWw9IuWbnuWIsOmhtumDqCI+CiAg
ICAgICAgPHN2ZyB2aWV3Qm94PSIwIDAgMjQgMjQiIGZpbGw9Im5vbmUiIHN0cm9rZT0iY3VycmVudENv
bG9yIiBzdHJva2Utd2lkdGg9IjIuMiIKICAgICAgICAgICAgIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIg
c3Ryb2tlLWxpbmVqb2luPSJyb3VuZCI+CiAgICAgICAgICAgIDxwYXRoIGQ9Ik0xMiAxOVY1Ii8+CiAg
ICAgICAgICAgIDxwYXRoIGQ9Ik01IDEybDctNyA3IDciLz4KICAgICAgICA8L3N2Zz4KICAgIDwvYnV0
dG9uPgo8L2Rpdj4KCjxkaXYgaWQ9ImN0eCI+CiAgICA8ZGl2IGNsYXNzPSJjLWl0ZW0iIGlkPSJjLWNv
cHkiPjxzcGFuIGNsYXNzPSJjLWljbyI+4o6YPC9zcGFuPuWkjeWItjwvZGl2PgogICAgPGRpdiBjbGFz
cz0iYy1pdGVtIiBpZD0iYy1wYXN0ZSI+PHNwYW4gY2xhc3M9ImMtaWNvIj7ij448L3NwYW4+57KY6LS0
PC9kaXY+CiAgICA8ZGl2IGNsYXNzPSJjLXNlcCI+PC9kaXY+CiAgICA8ZGl2IGNsYXNzPSJjLWl0ZW0i
IGlkPSJjLXBpbiI+PHNwYW4gY2xhc3M9ImMtaWNvIj7imIU8L3NwYW4+5pS26JePPC9kaXY+CiAgICA8
ZGl2IGNsYXNzPSJjLWl0ZW0iIGlkPSJjLXRpdGxlIiBzdHlsZT0iZGlzcGxheTpub25lIj48c3BhbiBj
bGFzcz0iYy1pY28iPuKcjjwvc3Bhbj7orr7nva7moIfpopg8L2Rpdj4KICAgIDxkaXYgY2xhc3M9ImMt
aXRlbSIgaWQ9ImMtbWVyZ2UiIHN0eWxlPSJkaXNwbGF5Om5vbmUiPjxzcGFuIGNsYXNzPSJjLWljbyI+
4qeJPC9zcGFuPuWQiOW5tjwvZGl2PgogICAgPGRpdiBjbGFzcz0iYy1pdGVtIiBpZD0iYy11bm1lcmdl
IiBzdHlsZT0iZGlzcGxheTpub25lIj48c3BhbiBjbGFzcz0iYy1pY28iPuKHhDwvc3Bhbj7lj5bmtojl
kIjlubY8L2Rpdj4KICAgIDxkaXYgY2xhc3M9ImMtaXRlbSIgaWQ9ImMtdG9wIj48c3BhbiBjbGFzcz0i
Yy1pY28iPuKGkTwvc3Bhbj7np7vliLDpobbpg6g8L2Rpdj4KICAgIDxkaXYgY2xhc3M9ImMtaXRlbSIg
aWQ9ImMtY2xlYXItcGFzdGVkIiBzdHlsZT0iZGlzcGxheTpub25lIj48c3BhbiBjbGFzcz0iYy1pY28i
PuKckzwvc3Bhbj7muIXpmaTnirbmgIE8L2Rpdj4KICAgIDxkaXYgY2xhc3M9ImMtaXRlbSIgaWQ9ImMt
cXVldWUtZnJvbSIgc3R5bGU9ImRpc3BsYXk6bm9uZSI+PHNwYW4gY2xhc3M9ImMtaWNvIj7ihrs8L3Nw
YW4+5LuO5q2k5aSE5byA5aeL6Zif5YiXPC9kaXY+CiAgICA8ZGl2IGNsYXNzPSJjLXNlcCI+PC9kaXY+
CiAgICA8ZGl2IGNsYXNzPSJjLWl0ZW0gZGFuZ2VyIiBpZD0iYy1kZWwiPjxzcGFuIGNsYXNzPSJjLWlj
byI+4pyVPC9zcGFuPuWIoOmZpDwvZGl2Pgo8L2Rpdj4KCjxkaXYgaWQ9ImNsci1kbGciPgogICAgPGRp
diBjbGFzcz0iY2xyLWJveCIgcm9sZT0iZGlhbG9nIiBhcmlhLW1vZGFsPSJ0cnVlIj4KICAgICAgICA8
ZGl2IGNsYXNzPSJjbHItdGl0bGUiIGlkPSJjbHItdGl0bGUiPuehruiupOa4heepuu+8nzwvZGl2Pgog
ICAgICAgIDxkaXYgY2xhc3M9ImNsci1kZXNjIiBpZD0iY2xyLWRlc2MiPum7mOiupOS7hea4heepuuW9
k+WkqeWGheWuueOAgjwvZGl2PgogICAgICAgIDxsYWJlbCBjbGFzcz0iY2xyLWNoZWNrIiBmb3I9ImNs
ci1hbGwiPgogICAgICAgICAgICA8aW5wdXQgdHlwZT0iY2hlY2tib3giIGlkPSJjbHItYWxsIj4KICAg
ICAgICAgICAgPHNwYW4+5riF56m65omA5pyJPC9zcGFuPgogICAgICAgIDwvbGFiZWw+CiAgICAgICAg
PGRpdiBjbGFzcz0iY2xyLWJ0bnMiPgogICAgICAgICAgICA8YnV0dG9uIHR5cGU9ImJ1dHRvbiIgaWQ9
ImNsci1jYW5jZWwiPuWPlua2iDwvYnV0dG9uPgogICAgICAgICAgICA8YnV0dG9uIHR5cGU9ImJ1dHRv
biIgaWQ9ImNsci1vayI+5riF56m6PC9idXR0b24+CiAgICAgICAgPC9kaXY+CiAgICA8L2Rpdj4KPC9k
aXY+Cgo8ZGl2IGlkPSJ0aXRsZS1kbGciPgogICAgPGRpdiBjbGFzcz0idGl0bGUtYm94IiByb2xlPSJk
aWFsb2ciIGFyaWEtbW9kYWw9InRydWUiPgogICAgICAgIDxkaXYgY2xhc3M9ImNsci10aXRsZSI+6K6+
572u5qCH6aKYPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0iY2xyLWRlc2MiPuagh+mimOWPr+iiq+aQ
nOe0ouaJvuWIsO+8jOS7heeUqOS6juaUtuiXj+aVtOeQhuOAgjwvZGl2PgogICAgICAgIDxpbnB1dCBp
ZD0idGl0bGUtaW5wdXQiIHR5cGU9InRleHQiIG1heGxlbmd0aD0iODAiIHBsYWNlaG9sZGVyPSLnu5no
v5nmnaHmlLbol4/otbfkuKrlkI3lrZfigKYiIGF1dG9jb21wbGV0ZT0ib2ZmIiBzcGVsbGNoZWNrPSJm
YWxzZSI+CiAgICAgICAgPGRpdiBjbGFzcz0iY2xyLWJ0bnMiPgogICAgICAgICAgICA8YnV0dG9uIHR5
cGU9ImJ1dHRvbiIgaWQ9InRpdGxlLWNhbmNlbCI+5Y+W5raIPC9idXR0b24+CiAgICAgICAgICAgIDxi
dXR0b24gdHlwZT0iYnV0dG9uIiBpZD0idGl0bGUtb2siPuS/neWtmDwvYnV0dG9uPgogICAgICAgIDwv
ZGl2PgogICAgPC9kaXY+CjwvZGl2Pgo8ZGl2IGlkPSJwYXRoLXRpcCIgYXJpYS1oaWRkZW49InRydWUi
PjwvZGl2PgoKPHNjcmlwdD4KLyog56aB5q2iIEN0cmwr5rua6L2u57yp5pS+77yIV2ViVmlldyDorr7n
va4gKyDpobXpnaLlhZzlupXvvIkgKi8KKGZ1bmN0aW9uKCl7CiAgY29uc3QgYmxvY2tab29tID0gZSA9
PiB7CiAgICBpZiAoZS5jdHJsS2V5IHx8IGUubWV0YUtleSkgewogICAgICBlLnByZXZlbnREZWZhdWx0
KCk7CiAgICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICB9CiAgfTsKICB3aW5kb3cuYWRkRXZlbnRM
aXN0ZW5lcignd2hlZWwnLCBibG9ja1pvb20sIHsgcGFzc2l2ZTogZmFsc2UsIGNhcHR1cmU6IHRydWUg
fSk7CiAgd2luZG93LmFkZEV2ZW50TGlzdGVuZXIoJ2dlc3R1cmVzdGFydCcsIGUgPT4gZS5wcmV2ZW50
RGVmYXVsdCgpLCB7IHBhc3NpdmU6IGZhbHNlLCBjYXB0dXJlOiB0cnVlIH0pOwogIGRvY3VtZW50LmFk
ZEV2ZW50TGlzdGVuZXIoJ2tleWRvd24nLCBlID0+IHsKICAgIGlmICghKGUuY3RybEtleSB8fCBlLm1l
dGFLZXkpKSByZXR1cm47CiAgICBpZiAoZS5rZXkgPT09ICcrJyB8fCBlLmtleSA9PT0gJy0nIHx8IGUu
a2V5ID09PSAnPScgfHwgZS5rZXkgPT09ICdfJwogICAgICAgIHx8IGUuY29kZSA9PT0gJ051bXBhZEFk
ZCcgfHwgZS5jb2RlID09PSAnTnVtcGFkU3VidHJhY3QnCiAgICAgICAgfHwgZS5rZXkgPT09ICcwJykg
ewogICAgICAvLyBhbGxvdyBub3RoaW5nIGZvciB6b29tOyBDdHJsKzAgLyDCsQogICAgICBpZiAoZS5r
ZXkgPT09ICcwJyB8fCBlLmtleSA9PT0gJysnIHx8IGUua2V5ID09PSAnLScgfHwgZS5rZXkgPT09ICc9
JyB8fCBlLmtleSA9PT0gJ18nCiAgICAgICAgICB8fCBlLmNvZGUgPT09ICdOdW1wYWRBZGQnIHx8IGUu
Y29kZSA9PT0gJ051bXBhZFN1YnRyYWN0JykgewogICAgICAgIGUucHJldmVudERlZmF1bHQoKTsKICAg
ICAgfQogICAgfQogIH0sIHRydWUpOwp9KSgpOwo8L3NjcmlwdD4KPHNjcmlwdD4KLyogc2tlbC1mYWls
c2FmZTogb25seSBpZiBtYWluIFVJIHNjcmlwdCBuZXZlciBib290ZWQg4oCUbmV2ZXIgaW52ZW50IGVt
cHR5LXN0YXRlICovCihmdW5jdGlvbigpewogIHNldFRpbWVvdXQoKCkgPT4gewogICAgdHJ5IHsKICAg
ICAgaWYgKHdpbmRvdy5fX3VpQm9vdGVkKSByZXR1cm47CiAgICAgIHZhciBhcHAgPSBkb2N1bWVudC5n
ZXRFbGVtZW50QnlJZCgnYXBwJyk7CiAgICAgIGlmIChhcHApIGFwcC5jbGFzc0xpc3QucmVtb3ZlKCdi
b290LWxvYWRpbmcnKTsKICAgICAgdmFyIHMgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc2tlbCcp
OwogICAgICBpZiAocykgcy5jbGFzc0xpc3QucmVtb3ZlKCdvbicpOwogICAgfSBjYXRjaCAoZXJyKSB7
fQogIH0sIDMwMDApOwp9KSgpOwo8L3NjcmlwdD4KPHNjcmlwdD4KICAgIGxldCBhbGxDbGlwcyA9IFtd
LCBjdXJUYWIgPSAnYWxsJywgcXVlcnkgPSAnJywgY3R4Q2xpcCA9IG51bGwsIHNlbGVjdGVkSWQgPSAw
LCBwaW5uZWRVSSA9IGZhbHNlOwogICAgY29uc3QgVEFCX09SREVSID0gWydhbGwnLCAndGV4dCcsICdp
bWFnZScsICdmaWxlJywgJ3JlY2VudCcsICdwaW5uZWQnXTsKICAgIGNvbnN0IHZpZXdNZW0gPSBuZXcg
TWFwKCk7CiAgICBmdW5jdGlvbiB2aWV3TWVtS2V5KHRhYiwgcSwgdG9kYXkpIHsKICAgICAgICByZXR1
cm4gU3RyaW5nKHRhYiB8fCAnYWxsJykgKyAnXHQnICsgU3RyaW5nKHEgfHwgJycpICsgJ1x0JyArICh0
b2RheSA/ICcxJyA6ICcwJyk7CiAgICB9CiAgICBsZXQgdGFiU3dpdGNoQW5pbURpciA9IDA7CiAgICBs
ZXQgbXVsdGlJZHMgPSBbXTsKICAgIGxldCB0b2RheU9ubHkgPSBmYWxzZTsKICAgIGxldCBkaXNrVG90
YWwgPSAwOwogICAgbGV0IGxvYWRpbmdNb3JlID0gZmFsc2U7CiAgICAvLyBEb24ndCBzaG93IHNrZWxl
dG9uIGltbWVkaWF0ZWx5IOKAlG9ubHkgYWZ0ZXIgU0tFTF9ERUxBWV9NUyBpZiBkYXRhIHN0aWxsIG1p
c3NpbmcKICAgIGxldCBib290TG9hZGluZyA9IGZhbHNlOwogICAgbGV0IHdhaXRpbmdEYXRhID0gZmFs
c2U7CiAgICBsZXQgaG9zdFB1c2hlZE9uY2UgPSBmYWxzZTsgLy8gb25seSB0aGVuIG1heSBzaG9344CM
5pqC5peg6K6w5b2V44CNCiAgICBsZXQgc2F3Tm9uRW1wdHkgPSBmYWxzZTsgICAgLy8gaWdub3JlIGJv
b3RzdHJhcCBlbXB0eSBwdXNoZXMgYmVmb3JlIGZpcnN0IHJlYWwgbGlzdAogICAgbGV0IHBpbm5lZFRv
dGFsID0gMDsgICAgICAgIC8vIGF1dGhvcml0YXRpdmUg5pS26JePIGNvdW50IGZyb20gQUhLCiAgICBs
ZXQgdW5zZWVuRmF2SWRzID0gbmV3IFNldCgpOwogICAgdHJ5IHsKICAgICAgICBjb25zdCByYXcgPSBs
b2NhbFN0b3JhZ2UuZ2V0SXRlbSgnY2xpcF91bnNlZW5fZmF2Jyk7CiAgICAgICAgaWYgKHJhdykgSlNP
Ti5wYXJzZShyYXcpLmZvckVhY2goaWQgPT4geyBpZCA9ICtpZDsgaWYgKGlkKSB1bnNlZW5GYXZJZHMu
YWRkKGlkKTsgfSk7CiAgICB9IGNhdGNoIHt9CiAgICBmdW5jdGlvbiBzYXZlVW5zZWVuRmF2KCkgewog
ICAgICAgIHRyeSB7IGxvY2FsU3RvcmFnZS5zZXRJdGVtKCdjbGlwX3Vuc2Vlbl9mYXYnLCBKU09OLnN0
cmluZ2lmeShbLi4udW5zZWVuRmF2SWRzXSkpOyB9IGNhdGNoIHt9CiAgICB9CiAgICBmdW5jdGlvbiB1
cGRhdGVQaW5Eb3QoKSB7CiAgICAgICAgY29uc3QgZWwgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgn
cGluLWRvdCcpOwogICAgICAgIGlmICghZWwpIHJldHVybjsKICAgICAgICBlbC5jbGFzc0xpc3QudG9n
Z2xlKCdvbicsIHVuc2VlbkZhdklkcy5zaXplID4gMCk7CiAgICB9CiAgICBmdW5jdGlvbiBtYXJrRmF2
VW5zZWVuKGlkKSB7CiAgICAgICAgaWQgPSAraWQ7CiAgICAgICAgaWYgKCFpZCkgcmV0dXJuOwogICAg
ICAgIHVuc2VlbkZhdklkcy5hZGQoaWQpOwogICAgICAgIHNhdmVVbnNlZW5GYXYoKTsKICAgICAgICB1
cGRhdGVQaW5Eb3QoKTsKICAgIH0KICAgIGZ1bmN0aW9uIGNsZWFyRmF2VW5zZWVuKCkgewogICAgICAg
IGlmICghdW5zZWVuRmF2SWRzLnNpemUpIHsKICAgICAgICAgICAgdXBkYXRlUGluRG90KCk7CiAgICAg
ICAgICAgIHJldHVybjsKICAgICAgICB9CiAgICAgICAgdW5zZWVuRmF2SWRzLmNsZWFyKCk7CiAgICAg
ICAgc2F2ZVVuc2VlbkZhdigpOwogICAgICAgIHVwZGF0ZVBpbkRvdCgpOwogICAgfQogICAgY29uc3Qg
U0tFTF9ERUxBWV9NUyA9IDYwOwogICAgd2luZG93Ll9fZGF0YVJlYWR5ID0gZmFsc2U7CiAgICB3aW5k
b3cuX191aUJvb3RlZCA9IHRydWU7CiAgICAvLyBPcGVuIHBhbmVsIHdpdGhvdXQgcGFzdGluZyDihpIg
YWx3YXlzIGxhbmQgb24gZmlyc3QgaXRlbSAoYWZ0ZXIgZGF0YSBhcnJpdmVzKQogICAgbGV0IHNlbGVj
dEZpcnN0T25TaG93ID0gZmFsc2U7CiAgICBsZXQgbGFzdFBhc3RlSWQgPSAwOwogICAgbGV0IGxhc3RQ
YXN0ZVRhYiA9ICdhbGwnOwogICAgbGV0IGxvY2F0ZUFjdGl2ZSA9IGZhbHNlOwogICAgdHJ5IHsgbGFz
dFBhc3RlSWQgPSArbG9jYWxTdG9yYWdlLmdldEl0ZW0oJ2NsaXBMYXN0UGFzdGVJZCcpIHx8IDA7IH0g
Y2F0Y2gge30KICAgIHRyeSB7CiAgICAgICAgY29uc3QgdCA9IGxvY2FsU3RvcmFnZS5nZXRJdGVtKCdj
bGlwTGFzdFBhc3RlVGFiJykgfHwgJ2FsbCc7CiAgICAgICAgbGFzdFBhc3RlVGFiID0gWydhbGwnLCd0
ZXh0JywnaW1hZ2UnLCdmaWxlJywncGlubmVkJ10uaW5jbHVkZXModCkgPyB0IDogJ2FsbCc7CiAgICB9
IGNhdGNoIHt9CiAgICAvLyBQcmVmZXIgc2FtZS1vcmlnaW4gdW5kZXIgY2xpcHVpLmFwcCAoQVBQX0hP
U1Qg4oaSIENMSVBfVjFfRElSL2NsaXBzX3N0b3JlKS4KICAgIC8vIOWLv+eUqCAqLmxvY2Fs77ya57O7
57ufIG1ETlMg5Lya5Y2hIDLigJMzc+OAgmNsaXBzLnN0b3JlIOS7heS9nCBmYWxsYmFja+OAggogICAg
Y29uc3QgU1RPUkVfQkFTRSA9IChsb2NhdGlvbi5vcmlnaW4gJiYgbG9jYXRpb24ub3JpZ2luLmluZGV4
T2YoJ2h0dHBzOi8vJykgPT09IDApCiAgICAgICAgPyAobG9jYXRpb24ub3JpZ2luLnJlcGxhY2UoL1wv
JC8sICcnKSArICcvY2xpcHNfc3RvcmUvJykKICAgICAgICA6ICdodHRwczovL2NsaXB1aS5hcHAvY2xp
cHNfc3RvcmUvJzsKICAgIGNvbnN0IFNUT1JFX0JBU0VfRkFMTEJBQ0sgPSAnaHR0cHM6Ly9jbGlwcy5z
dG9yZS8nOwogICAgZnVuY3Rpb24gbWV0YUNlbnRlckh0bWwoZXhwYW5kSW5uZXIpIHsKICAgICAgICBp
ZiAoZXhwYW5kSW5uZXIgPT0gbnVsbCB8fCBleHBhbmRJbm5lciA9PT0gZmFsc2UpCiAgICAgICAgICAg
IHJldHVybiBgPHNwYW4gY2xhc3M9ImktbWV0YS1jZW50ZXIiPjwvc3Bhbj5gOwogICAgICAgIHJldHVy
biBgPHNwYW4gY2xhc3M9ImktbWV0YS1jZW50ZXIiPjxidXR0b24gY2xhc3M9ImktZXhwYW5kLWJ0biR7
ZXhwYW5kSW5uZXIub24gPyAnIG9uJyA6ICcnfSIgdHlwZT0iYnV0dG9uIiB0aXRsZT0i5bGV5byAL+aU
tui1tyI+JHtleHBhbmRJbm5lci5odG1sfTwvYnV0dG9uPjwvc3Bhbj5gOwogICAgfQoKICAgIGZ1bmN0
aW9uIHJlbWVtYmVyTGFzdFBhc3RlKGlkKSB7CiAgICAgICAgbGFzdFBhc3RlSWQgPSAraWQgfHwgMDsK
ICAgICAgICBsYXN0UGFzdGVUYWIgPSBjdXJUYWIgfHwgJ2FsbCc7CiAgICAgICAgdHJ5IHsKICAgICAg
ICAgICAgbG9jYWxTdG9yYWdlLnNldEl0ZW0oJ2NsaXBMYXN0UGFzdGVJZCcsIFN0cmluZyhsYXN0UGFz
dGVJZCkpOwogICAgICAgICAgICBsb2NhbFN0b3JhZ2Uuc2V0SXRlbSgnY2xpcExhc3RQYXN0ZVRhYics
IGxhc3RQYXN0ZVRhYik7CiAgICAgICAgfSBjYXRjaCB7fQogICAgICAgIHVwZGF0ZUxvY2F0ZUJ0bigp
OwogICAgfQogICAgZnVuY3Rpb24gdXBkYXRlTG9jYXRlQnRuKCkgewogICAgICAgIGNvbnN0IGJ0biA9
IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdidG4tbG9jYXRlJyk7CiAgICAgICAgaWYgKCFidG4pIHJl
dHVybjsKICAgICAgICBidG4uZGlzYWJsZWQgPSAhbGFzdFBhc3RlSWQ7CiAgICAgICAgYnRuLmNsYXNz
TGlzdC50b2dnbGUoJ2hhcy10YXJnZXQnLCAhIWxhc3RQYXN0ZUlkKTsKICAgICAgICBidG4uY2xhc3NM
aXN0LnRvZ2dsZSgnb24nLCBsb2NhdGVBY3RpdmUgJiYgISFsYXN0UGFzdGVJZCk7CiAgICAgICAgYnRu
LnRpdGxlID0gIWxhc3RQYXN0ZUlkCiAgICAgICAgICAgID8gJ+aaguaXoOS4iuasoeS9v+eUqOS9jee9
ricKICAgICAgICAgICAgOiAobG9jYXRlQWN0aXZlID8gJ+WPlua2iOWumuS9je+8jOWbnuWIsOesrOS4
gOadoScgOiAn5a6a5L2N5Yiw5LiK5qyh5L2/55So55qE5p2h55uuJyk7CiAgICB9CiAgICBmdW5jdGlv
biBzZWxlY3RGaXJzdEl0ZW0oKSB7CiAgICAgICAgbG9jYXRlQWN0aXZlID0gZmFsc2U7CiAgICAgICAg
d2luZG93Ll9fcGVuZGluZ0p1bXBJZCA9IDA7CiAgICAgICAgd2luZG93Ll9fanVtcExvYWRUcmllcyA9
IDA7CiAgICAgICAgc2VsZWN0Rmlyc3RPblNob3cgPSBmYWxzZTsKICAgICAgICBjb25zdCB2aXMgPSB2
aXNpYmxlTGlzdCgpOwogICAgICAgIGlmICghdmlzLmxlbmd0aCkgewogICAgICAgICAgICBzZWxlY3Rl
ZElkID0gMDsKICAgICAgICAgICAgc3luY0l0ZW1IaWdobGlnaHQoKTsKICAgICAgICAgICAgdXBkYXRl
TG9jYXRlQnRuKCk7CiAgICAgICAgICAgIHJldHVybjsKICAgICAgICB9CiAgICAgICAgc2VsZWN0ZWRJ
ZCA9IHZpc1swXS5pZDsKICAgICAgICByYW5nZUFuY2hvcklkID0gc2VsZWN0ZWRJZDsKICAgICAgICBy
YW5nZUFuY2hvckNsaWNrZWQgPSBmYWxzZTsKICAgICAgICBsaXN0RWwuc2Nyb2xsVG9wID0gMDsKICAg
ICAgICBzeW5jSXRlbUhpZ2hsaWdodCgpOwogICAgICAgIGNvbnN0IGVsID0gbGlzdEVsLnF1ZXJ5U2Vs
ZWN0b3IoJy5pdG1bZGF0YS1pZD0iJyArIHNlbGVjdGVkSWQgKyAnIl0nKTsKICAgICAgICBpZiAoZWwp
IGVsLnNjcm9sbEludG9WaWV3KHsgYmxvY2s6ICduZWFyZXN0JyB9KTsKICAgICAgICB1cGRhdGVMb2Nh
dGVCdG4oKTsKICAgIH0KICAgIGZ1bmN0aW9uIGp1bXBUb0xhc3RQYXN0ZSgpIHsKICAgICAgICBpZiAo
IWxhc3RQYXN0ZUlkKSByZXR1cm47CiAgICAgICAgLy8gQWxyZWFkeSBsb2NhdGVkIG9uIGxhc3QgcGFz
dGUg4oaSIGNhbmNlbCBhbmQgc2VsZWN0IGZpcnN0CiAgICAgICAgaWYgKGxvY2F0ZUFjdGl2ZSAmJiAr
c2VsZWN0ZWRJZCA9PT0gK2xhc3RQYXN0ZUlkKSB7CiAgICAgICAgICAgIHNlbGVjdEZpcnN0SXRlbSgp
OwogICAgICAgICAgICByZXR1cm47CiAgICAgICAgfQogICAgICAgIGxvY2F0ZUFjdGl2ZSA9IHRydWU7
CiAgICAgICAgc2VsZWN0Rmlyc3RPblNob3cgPSBmYWxzZTsKICAgICAgICAvLyBDbGVhciBmaWx0ZXJz
IHNvIHRoZSBpdGVtIGlzIGZpbmRhYmxlIG9uIHRoZSB0YWIgd2hlcmUgaXQgd2FzIHVzZWQKICAgICAg
ICBxdWVyeSA9ICcnOwogICAgICAgIHRvZGF5T25seSA9IGZhbHNlOwogICAgICAgIHRyeSB7CiAgICAg
ICAgICAgIGNvbnN0IHNyY2ggPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc2VhcmNoJyk7CiAgICAg
ICAgICAgIGNvbnN0IHNjbHIgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc2VhcmNoLWNscicpOwog
ICAgICAgICAgICBjb25zdCB3cmFwID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NlYXJjaC13cmFw
Jyk7CiAgICAgICAgICAgIGNvbnN0IGJ0blRvZGF5ID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2J0
bi10b2RheScpOwogICAgICAgICAgICBpZiAoc3JjaCkgeyBzcmNoLnZhbHVlID0gJyc7IHNyY2guY2xh
c3NMaXN0LnJlbW92ZSgnaGFzLXZhbCcpOyB9CiAgICAgICAgICAgIGlmIChzY2xyKSBzY2xyLnN0eWxl
LmRpc3BsYXkgPSAnbm9uZSc7CiAgICAgICAgICAgIGlmICh3cmFwKSB3cmFwLmNsYXNzTGlzdC5yZW1v
dmUoJ29wZW4nKTsKICAgICAgICAgICAgaWYgKGJ0blRvZGF5KSBidG5Ub2RheS5jbGFzc0xpc3QucmVt
b3ZlKCdvbicpOwogICAgICAgIH0gY2F0Y2gge30KICAgICAgICBjb25zdCB0YWIgPSBbJ2FsbCcsJ3Rl
eHQnLCdpbWFnZScsJ2ZpbGUnLCdwaW5uZWQnXS5pbmNsdWRlcyhsYXN0UGFzdGVUYWIpCiAgICAgICAg
ICAgID8gbGFzdFBhc3RlVGFiIDogJ2FsbCc7CiAgICAgICAgY29uc3QgcHJldlRhYiA9IGN1clRhYjsK
ICAgICAgICBjdXJUYWIgPSB0YWI7CiAgICAgICAgbG9hZGluZ01vcmUgPSBmYWxzZTsKICAgICAgICBt
YXJrVGFiKHRhYik7CiAgICAgICAgY2xlYXJNdWx0aSgpOwogICAgICAgIHNlbGVjdGVkSWQgPSBsYXN0
UGFzdGVJZDsKICAgICAgICB3aW5kb3cuX19wZW5kaW5nSnVtcElkID0gbGFzdFBhc3RlSWQ7CiAgICAg
ICAgd2luZG93Ll9fanVtcExvYWRUcmllcyA9IDA7CiAgICAgICAgd2luZG93Ll9fanVtcEZlbGxCYWNr
ID0gZmFsc2U7CiAgICAgICAgdXBkYXRlTG9jYXRlQnRuKCk7CiAgICAgICAgcmVxdWVzdFZpZXcoKTsK
ICAgIH0KCiAgICBmdW5jdGlvbiByZXF1ZXN0VmlldygpIHsKICAgICAgICBjb25zdCB0YWIgPSBjdXJU
YWIsIHEgPSBxdWVyeSwgdG9kYXkgPSB0b2RheU9ubHkgPyAnMScgOiAnMCc7CiAgICAgICAgaWYgKHdp
bmRvdy5fX3ZpZXdSYWYpIGNhbmNlbEFuaW1hdGlvbkZyYW1lKHdpbmRvdy5fX3ZpZXdSYWYpOwogICAg
ICAgIHdpbmRvdy5fX3ZpZXdSYWYgPSByZXF1ZXN0QW5pbWF0aW9uRnJhbWUoKCkgPT4gewogICAgICAg
ICAgICB3aW5kb3cuX192aWV3UmFmID0gMDsKICAgICAgICAgICAgc2V0VGltZW91dCgoKSA9PiBhaGso
J3NldFZpZXcnLCB0YWIsIHEsIHRvZGF5KSwgMCk7CiAgICAgICAgfSk7CiAgICB9CiAgICAvKiogRGVi
b3VuY2VkIEFISyBzeW5jIGFmdGVyIHZpZXdNZW0gaW5zdGFudCBwYWludCDigJRhdm9pZHMgdGFiLXN3
aXRjaCBkb3VibGUgUHVzaENsaXBzICovCiAgICBmdW5jdGlvbiBzb2Z0UmVxdWVzdFZpZXcoKSB7CiAg
ICAgICAgaWYgKHdpbmRvdy5fX3NvZnRWaWV3VCkgY2xlYXJUaW1lb3V0KHdpbmRvdy5fX3NvZnRWaWV3
VCk7CiAgICAgICAgd2luZG93Ll9fc29mdFZpZXdUID0gc2V0VGltZW91dCgoKSA9PiB7CiAgICAgICAg
ICAgIHdpbmRvdy5fX3NvZnRWaWV3VCA9IDA7CiAgICAgICAgICAgIHJlcXVlc3RWaWV3KCk7CiAgICAg
ICAgfSwgMzIwKTsKICAgIH0KICAgIGZ1bmN0aW9uIHJlcXVlc3RNb3JlKGZvcmNlID0gZmFsc2UpIHsK
ICAgICAgICBpZiAoZGlza1RvdGFsID4gMCAmJiBhbGxDbGlwcy5sZW5ndGggPj0gZGlza1RvdGFsKSBy
ZXR1cm47CiAgICAgICAgLy8gTG9jYXRlIC8ganVtcCBtdXN0IG5vdCB3YWl0IG9uIHNjcm9sbC1pZGxl
IG9yIGEgc3R1Y2sgbG9hZGluZ01vcmUgZmxhZwogICAgICAgIGlmICghZm9yY2UpIHsKICAgICAgICAg
ICAgaWYgKGxvYWRpbmdNb3JlKSByZXR1cm47CiAgICAgICAgICAgIGlmICh3aW5kb3cuX19zY3JvbGxC
dXN5IHx8IF9saXN0UHRyRG93bikgewogICAgICAgICAgICAgICAgd2luZG93Ll9fd2FudE1vcmUgPSB0
cnVlOwogICAgICAgICAgICAgICAgcmV0dXJuOwogICAgICAgICAgICB9CiAgICAgICAgfSBlbHNlIHsK
ICAgICAgICAgICAgbG9hZGluZ01vcmUgPSBmYWxzZTsKICAgICAgICAgICAgd2luZG93Ll9fc2Nyb2xs
QnVzeSA9IGZhbHNlOwogICAgICAgICAgICB3aW5kb3cuX193YW50TW9yZSA9IGZhbHNlOwogICAgICAg
ICAgICBfbGlzdFB0ckRvd24gPSBmYWxzZTsKICAgICAgICAgICAgdHJ5IHsgbGlzdEVsLmNsYXNzTGlz
dC5yZW1vdmUoJ2lzLXNjcm9sbGluZycpOyB9IGNhdGNoIHt9CiAgICAgICAgfQogICAgICAgIGlmIChs
b2FkaW5nTW9yZSkgcmV0dXJuOwogICAgICAgIGxvYWRpbmdNb3JlID0gdHJ1ZTsKICAgICAgICB3aW5k
b3cuX193YW50TW9yZSA9IGZhbHNlOwogICAgICAgIGlmICh3aW5kb3cuX19sb2FkTW9yZVdhdGNoKSBj
bGVhclRpbWVvdXQod2luZG93Ll9fbG9hZE1vcmVXYXRjaCk7CiAgICAgICAgd2luZG93Ll9fbG9hZE1v
cmVXYXRjaCA9IHNldFRpbWVvdXQoKCkgPT4gewogICAgICAgICAgICB3aW5kb3cuX19sb2FkTW9yZVdh
dGNoID0gMDsKICAgICAgICAgICAgaWYgKGxvYWRpbmdNb3JlKSB7CiAgICAgICAgICAgICAgICBsb2Fk
aW5nTW9yZSA9IGZhbHNlOwogICAgICAgICAgICAgICAgaWYgKHdpbmRvdy5fX3BlbmRpbmdKdW1wSWQp
IHRyeUNvbnRpbnVlSnVtcCgpOwogICAgICAgICAgICB9CiAgICAgICAgfSwgMTgwMCk7CiAgICAgICAg
YWhrKCdsb2FkTW9yZScpOwogICAgfQoKICAgIGZ1bmN0aW9uIHRyeUNvbnRpbnVlSnVtcCgpIHsKICAg
ICAgICBjb25zdCBqaWQgPSArd2luZG93Ll9fcGVuZGluZ0p1bXBJZDsKICAgICAgICBpZiAoIWppZCkg
cmV0dXJuOwogICAgICAgIGlmIChfcGVuZGluZ0FwcGVuZCkgewogICAgICAgICAgICBjb25zdCBwZW5k
aW5nID0gX3BlbmRpbmdBcHBlbmQ7CiAgICAgICAgICAgIF9wZW5kaW5nQXBwZW5kID0gbnVsbDsKICAg
ICAgICAgICAgYXBwbHlBcHBlbmRQYXlsb2FkKHBlbmRpbmcpOwogICAgICAgIH0KICAgICAgICBjb25z
dCBlbCA9IGxpc3RFbC5xdWVyeVNlbGVjdG9yKCcubWctcm93W2RhdGEtaWQ9IicgKyBqaWQgKyAnIl0n
KSB8fCBsaXN0RWwucXVlcnlTZWxlY3RvcignLml0bVtkYXRhLWlkPSInICsgamlkICsgJyJdJyk7CiAg
ICAgICAgaWYgKGVsKSB7CiAgICAgICAgICAgIHdpbmRvdy5fX3BlbmRpbmdKdW1wSWQgPSAwOwogICAg
ICAgICAgICB3aW5kb3cuX19qdW1wTG9hZFRyaWVzID0gMDsKICAgICAgICAgICAgc2VsZWN0ZWRJZCA9
IGppZDsKICAgICAgICAgICAgbG9jYXRlQWN0aXZlID0gdHJ1ZTsKICAgICAgICAgICAgdXBkYXRlTG9j
YXRlQnRuKCk7CiAgICAgICAgICAgIHJlcXVlc3RBbmltYXRpb25GcmFtZSgoKSA9PiB7CiAgICAgICAg
ICAgICAgICBjb25zdCBub2RlID0gbGlzdEVsLnF1ZXJ5U2VsZWN0b3IoJy5tZy1yb3dbZGF0YS1pZD0i
JyArIGppZCArICciXScpIHx8IGxpc3RFbC5xdWVyeVNlbGVjdG9yKCcuaXRtW2RhdGEtaWQ9IicgKyBq
aWQgKyAnIl0nKTsKICAgICAgICAgICAgICAgIGlmICghbm9kZSkgcmV0dXJuOwogICAgICAgICAgICAg
ICAgbm9kZS5zY3JvbGxJbnRvVmlldyh7IGJsb2NrOiAnY2VudGVyJyB9KTsKICAgICAgICAgICAgICAg
IG5vZGUuY2xhc3NMaXN0LmFkZCgnanVtcC1mbGFzaCcpOwogICAgICAgICAgICAgICAgc2V0VGltZW91
dCgoKSA9PiBub2RlLmNsYXNzTGlzdC5yZW1vdmUoJ2p1bXAtZmxhc2gnKSwgOTAwKTsKICAgICAgICAg
ICAgICAgIHN5bmNJdGVtSGlnaGxpZ2h0KCk7CiAgICAgICAgICAgIH0pOwogICAgICAgICAgICByZXR1
cm47CiAgICAgICAgfQogICAgICAgIGlmIChhbGxDbGlwcy5zb21lKGMgPT4gK2MuaWQgPT09IGppZCkp
IHsKICAgICAgICAgICAgcmVuZGVyKCk7CiAgICAgICAgICAgIHJlcXVlc3RBbmltYXRpb25GcmFtZSgo
KSA9PiB0cnlDb250aW51ZUp1bXAoKSk7CiAgICAgICAgICAgIHJldHVybjsKICAgICAgICB9CiAgICAg
ICAgaWYgKGFsbENsaXBzLmxlbmd0aCA8IGRpc2tUb3RhbCAmJiAod2luZG93Ll9fanVtcExvYWRUcmll
cyB8fCAwKSA8IDgwKSB7CiAgICAgICAgICAgIHdpbmRvdy5fX2p1bXBMb2FkVHJpZXMgPSAod2luZG93
Ll9fanVtcExvYWRUcmllcyB8fCAwKSArIDE7CiAgICAgICAgICAgIHJlcXVlc3RNb3JlKHRydWUpOwog
ICAgICAgICAgICByZXR1cm47CiAgICAgICAgfQogICAgICAgIHdpbmRvdy5fX3BlbmRpbmdKdW1wSWQg
PSAwOwogICAgICAgIHdpbmRvdy5fX2p1bXBMb2FkVHJpZXMgPSAwOwogICAgfQogICAgY29uc3QgRU1Q
VFlfTVNHID0gewogICAgICAgIGFsbDogICAgJ+aaguaXoOiusOW9le+8jOWkjeWItuWQjuiHquWKqOWH
uueOsCcsCiAgICAgICAgdGV4dDogICAn5pqC5peg5paH5pysJywKICAgICAgICBpbWFnZTogICfmmoLm
l6Dlm77lg48nLAogICAgICAgIGZpbGU6ICAgJ+aaguaXoOaWh+S7ticsCiAgICAgICAgcGlubmVkOiAn
5pqC5peg5pS26JePJywKICAgICAgICByZWNlbnQ6ICfmmoLml6DmnIDov5HmiZPlvIDnmoTnm67lvZUn
CiAgICB9OwoKICAgIGZ1bmN0aW9uIGFoa0ludm9rZShtZXRob2QsIGFyZ3MpIHsKICAgICAgICB0cnkg
ewogICAgICAgICAgICBjb25zdCBob3N0ID0gY2hyb21lLndlYnZpZXcuaG9zdE9iamVjdHMuc3luYy5h
aGs7CiAgICAgICAgICAgIGlmICghaG9zdCkgcmV0dXJuOwogICAgICAgICAgICBsZXQgY2FsbGVkID0g
ZmFsc2U7CiAgICAgICAgICAgIC8vIFdlYlZpZXcyOiBob3N0LmNhbGwobmFtZSwg4oCmKSBpcyB0aGUg
cmVsaWFibGUgcGF0aC4gRGlyZWN0IGhvc3RbbWV0aG9kXSjigKYpCiAgICAgICAgICAgIC8vIGNhbiBt
aXMtYmluZCBhcmdzIChzYXcgc2V0VmlldyB0YWIgYmVjb21lIDAg4oaSIGZvcmV2ZXIgc2tlbGV0b24g
LyB3cm9uZyB0YWIpLgogICAgICAgICAgICBpZiAodHlwZW9mIGhvc3QuY2FsbCA9PT0gJ2Z1bmN0aW9u
JykgewogICAgICAgICAgICAgICAgdHJ5IHsgaG9zdC5jYWxsKG1ldGhvZCwgLi4uYXJncyk7IGNhbGxl
ZCA9IHRydWU7IH0gY2F0Y2gge30KICAgICAgICAgICAgfQogICAgICAgICAgICBpZiAoIWNhbGxlZCAm
JiB0eXBlb2YgaG9zdFttZXRob2RdID09PSAnZnVuY3Rpb24nKSB7CiAgICAgICAgICAgICAgICB0cnkg
eyBob3N0W21ldGhvZF0oLi4uYXJncyk7IGNhbGxlZCA9IHRydWU7IH0gY2F0Y2ggKGUpIHsgY29uc29s
ZS53YXJuKCdhaGsuJyArIG1ldGhvZCwgZSk7IH0KICAgICAgICAgICAgfQogICAgICAgICAgICBpZiAo
IWNhbGxlZCAmJiBob3N0W21ldGhvZF0gIT0gbnVsbCAmJiB0eXBlb2YgaG9zdFttZXRob2RdICE9PSAn
ZnVuY3Rpb24nKSB7CiAgICAgICAgICAgICAgICB0cnkgeyB2b2lkIGhvc3RbbWV0aG9kXTsgfSBjYXRj
aCB7fQogICAgICAgICAgICB9CiAgICAgICAgfSBjYXRjaCAoZSkgeyBjb25zb2xlLndhcm4oJ2Foay4n
ICsgbWV0aG9kLCBlKTsgfQogICAgfQogICAgZnVuY3Rpb24gYWhrKG1ldGhvZCwgLi4uYXJncykgewog
ICAgICAgIGFoa0ludm9rZShtZXRob2QsIGFyZ3MpOwogICAgfQogICAgZnVuY3Rpb24gYWhrUmV0KG1l
dGhvZCwgLi4uYXJncykgewogICAgICAgIHRyeSB7CiAgICAgICAgICAgIGNvbnN0IGhvc3QgPSBjaHJv
bWUud2Vidmlldy5ob3N0T2JqZWN0cy5zeW5jLmFoazsKICAgICAgICAgICAgaWYgKCFob3N0KSByZXR1
cm4gbnVsbDsKICAgICAgICAgICAgbGV0IHJldCA9IG51bGw7CiAgICAgICAgICAgIGlmICh0eXBlb2Yg
aG9zdC5jYWxsID09PSAnZnVuY3Rpb24nKSB7CiAgICAgICAgICAgICAgICB0cnkgeyByZXQgPSBob3N0
LmNhbGwobWV0aG9kLCAuLi5hcmdzKTsgfSBjYXRjaCB7fQogICAgICAgICAgICB9CiAgICAgICAgICAg
IGlmIChyZXQgPT0gbnVsbCAmJiB0eXBlb2YgaG9zdFttZXRob2RdID09PSAnZnVuY3Rpb24nKSB7CiAg
ICAgICAgICAgICAgICB0cnkgeyByZXQgPSBob3N0W21ldGhvZF0oLi4uYXJncyk7IH0gY2F0Y2gge30K
ICAgICAgICAgICAgICAgIGlmIChyZXQgPT0gbnVsbCkgewogICAgICAgICAgICAgICAgICAgIHRyeSB7
IHJldCA9IGhvc3RbbWV0aG9kXSguLi5hcmdzKTsgfSBjYXRjaCB7fQogICAgICAgICAgICAgICAgfQog
ICAgICAgICAgICB9CiAgICAgICAgICAgIGlmIChyZXQgPT0gbnVsbCAmJiBob3N0W21ldGhvZF0gIT0g
bnVsbCAmJiB0eXBlb2YgaG9zdFttZXRob2RdICE9PSAnZnVuY3Rpb24nKQogICAgICAgICAgICAgICAg
cmV0ID0gaG9zdFttZXRob2RdOwogICAgICAgICAgICBpZiAocmV0ID09IG51bGwpIHJldHVybiBudWxs
OwogICAgICAgICAgICBpZiAodHlwZW9mIHJldCA9PT0gJ3N0cmluZycgfHwgdHlwZW9mIHJldCA9PT0g
J251bWJlcicgfHwgdHlwZW9mIHJldCA9PT0gJ2Jvb2xlYW4nKQogICAgICAgICAgICAgICAgcmV0dXJu
IHJldDsKICAgICAgICAgICAgdHJ5IHsgcmV0dXJuIFN0cmluZyhyZXQpOyB9IGNhdGNoIHsgcmV0dXJu
IHJldDsgfQogICAgICAgIH0gY2F0Y2ggKGUpIHsgY29uc29sZS53YXJuKCdhaGtSZXQuJyArIG1ldGhv
ZCwgZSk7IH0KICAgICAgICByZXR1cm4gbnVsbDsKICAgIH0KCiAgICAvLyBFYXJseSBBSEsgX19zZXRU
aHVtYiBjYW4gYXJyaXZlIGJlZm9yZSBET00gbm9kZXMgZXhpc3Qg4oCUIGtlZXAgdW50aWwgYmluZAog
ICAgY29uc3QgdGh1bWJDYWNoZSA9IG5ldyBNYXAoKTsKCiAgICAvKiogUHJlZmVyIGNhY2hlIC8gZGF0
YS1VUkwsIHRoZW4gdGhfKi5qcGcgdmlhIHZpcnR1YWwgaG9zdCwgdGhlbiBvcmlnaW5hbCAqLwogICAg
ZnVuY3Rpb24gYmluZFN0b3JlVGh1bWIoaW1nLCBmaWxlLCBpZCwgZmFsbGJhY2spIHsKICAgICAgICBp
bWcuZGF0YXNldC50aHVtYklkID0gU3RyaW5nKGlkKTsKICAgICAgICBpbWcuYWx0ID0gJyc7CiAgICAg
ICAgaW1nLmNsYXNzTGlzdC5hZGQoJ3RodW1iLWxvYWRpbmcnKTsKICAgICAgICBjb25zdCB3cmFwID0g
aW1nLnBhcmVudEVsZW1lbnQ7CiAgICAgICAgaWYgKHdyYXAgJiYgd3JhcC5jbGFzc0xpc3QuY29udGFp
bnMoJ2ktdGh1bWItd3JhcCcpKQogICAgICAgICAgICB3cmFwLmNsYXNzTGlzdC5hZGQoJ3dhaXRpbmcn
KTsKICAgICAgICBjb25zdCBjbGVhcldhaXQgPSAoKSA9PiB7CiAgICAgICAgICAgIGltZy5jbGFzc0xp
c3QucmVtb3ZlKCd0aHVtYi1sb2FkaW5nJyk7CiAgICAgICAgICAgIGlmICh3cmFwKSB3cmFwLmNsYXNz
TGlzdC5yZW1vdmUoJ3dhaXRpbmcnKTsKICAgICAgICAgICAgaWYgKGltZy5fZmFpbFRpbWVyKSB0cnkg
eyBjbGVhclRpbWVvdXQoaW1nLl9mYWlsVGltZXIpOyB9IGNhdGNoIHt9CiAgICAgICAgfTsKICAgICAg
ICBjb25zdCBmYWlsVGltZXIgPSBzZXRUaW1lb3V0KCgpID0+IHsKICAgICAgICAgICAgaWYgKCFpbWcu
c3JjIHx8IGltZy5uYXR1cmFsV2lkdGggPCAxKQogICAgICAgICAgICAgICAgaW1nLmFsdCA9ICfml6Dm
s5XliqDovb0nOwogICAgICAgICAgICBjbGVhcldhaXQoKTsKICAgICAgICB9LCAxMjAwMCk7CiAgICAg
ICAgaW1nLl9mYWlsVGltZXIgPSBmYWlsVGltZXI7CiAgICAgICAgY29uc3QgcHJldkxvYWQgPSBpbWcu
b25sb2FkOwogICAgICAgIGltZy5vbmxvYWQgPSBlID0+IHsKICAgICAgICAgICAgY2xlYXJXYWl0KCk7
CiAgICAgICAgICAgIGltZy5hbHQgPSAnJzsKICAgICAgICAgICAgaWYgKHR5cGVvZiBwcmV2TG9hZCA9
PT0gJ2Z1bmN0aW9uJykgcHJldkxvYWQuY2FsbChpbWcsIGUpOwogICAgICAgIH07CiAgICAgICAgY29u
c3QgYmFyZSA9IGZpbGUgPyBTdHJpbmcoZmlsZSkuc3BsaXQoL1tcXC9dLykucG9wKCkgOiAnJzsKICAg
ICAgICBjb25zdCB0aE5hbWUgPSBiYXJlID8gKCd0aF8nICsgYmFyZS5yZXBsYWNlKC9cLlteLl0rJC8s
ICcnKSArICcuanBnJykgOiAnJzsKICAgICAgICBpbWcub25lcnJvciA9ICgpID0+IHsKICAgICAgICAg
ICAgY29uc3Qgc3RlcCA9IE51bWJlcihpbWcuZGF0YXNldC5zdGVwIHx8IDApOwogICAgICAgICAgICBp
ZiAoc3RlcCA8IDIgJiYgYmFyZSkgewogICAgICAgICAgICAgICAgaW1nLmRhdGFzZXQuc3RlcCA9ICcy
JzsKICAgICAgICAgICAgICAgIGltZy5zcmMgPSBTVE9SRV9CQVNFICsgZW5jb2RlVVJJQ29tcG9uZW50
KGJhcmUpOwogICAgICAgICAgICAgICAgcmV0dXJuOwogICAgICAgICAgICB9CiAgICAgICAgICAgIGlm
IChzdGVwIDwgMyAmJiAodGhOYW1lIHx8IGJhcmUpKSB7CiAgICAgICAgICAgICAgICBpbWcuZGF0YXNl
dC5zdGVwID0gJzMnOwogICAgICAgICAgICAgICAgaW1nLnNyYyA9IFNUT1JFX0JBU0VfRkFMTEJBQ0sg
KyBlbmNvZGVVUklDb21wb25lbnQodGhOYW1lIHx8IGJhcmUpOwogICAgICAgICAgICAgICAgcmV0dXJu
OwogICAgICAgICAgICB9CiAgICAgICAgICAgIGlmIChzdGVwIDwgNCAmJiBiYXJlICYmIHRoTmFtZSkg
ewogICAgICAgICAgICAgICAgaW1nLmRhdGFzZXQuc3RlcCA9ICc0JzsKICAgICAgICAgICAgICAgIGlt
Zy5zcmMgPSBTVE9SRV9CQVNFX0ZBTExCQUNLICsgZW5jb2RlVVJJQ29tcG9uZW50KGJhcmUpOwogICAg
ICAgICAgICAgICAgcmV0dXJuOwogICAgICAgICAgICB9CiAgICAgICAgICAgIC8vIEtlZXAgc2hpbW1l
cjsgQUhLIF9fc2V0VGh1bWIgd2lsbCBmaWxsIGluCiAgICAgICAgICAgIGltZy5yZW1vdmVBdHRyaWJ1
dGUoJ3NyYycpOwogICAgICAgICAgICBpbWcuY2xhc3NMaXN0LmFkZCgndGh1bWItbG9hZGluZycpOwog
ICAgICAgICAgICBpZiAod3JhcCkgd3JhcC5jbGFzc0xpc3QuYWRkKCd3YWl0aW5nJyk7CiAgICAgICAg
fTsKICAgICAgICBjb25zdCBjYWNoZWQgPSB0aHVtYkNhY2hlLmdldChTdHJpbmcoaWQpKTsKICAgICAg
ICAvLyBBY2NlcHQgZGF0YS1VUkwgb3IgaG9zdCBVUkwgZnJvbSBwcmlvciBfX3NldFRodW1iIChyZS1y
ZW5kZXIgbXVzdCBub3QgZHJvcCBpdCkKICAgICAgICBpZiAoY2FjaGVkICYmIFN0cmluZyhjYWNoZWQp
Lmxlbmd0aCkgewogICAgICAgICAgICBpbWcuZGF0YXNldC5zdGVwID0gJzknOwogICAgICAgICAgICBp
bWcuc3JjID0gU3RyaW5nKGNhY2hlZCk7CiAgICAgICAgICAgIHJldHVybjsKICAgICAgICB9CiAgICAg
ICAgY29uc3QgZGF0YVVybCA9IChmYWxsYmFjayAmJiBTdHJpbmcoZmFsbGJhY2spLnN0YXJ0c1dpdGgo
J2RhdGE6JykpCiAgICAgICAgICAgID8gU3RyaW5nKGZhbGxiYWNrKSA6ICcnOwogICAgICAgIGlmIChk
YXRhVXJsKSB7CiAgICAgICAgICAgIGltZy5kYXRhc2V0LnN0ZXAgPSAnOSc7CiAgICAgICAgICAgIGlt
Zy5zcmMgPSBkYXRhVXJsOwogICAgICAgICAgICByZXR1cm47CiAgICAgICAgfQogICAgICAgIGlmIChi
YXJlKSB7CiAgICAgICAgICAgIC8vIFByZWZlciBsaXN0IHRodW1iIEpQRUcgKHNtYWxsKSBvbiBkZWRp
Y2F0ZWQgc3RvcmUgaG9zdAogICAgICAgICAgICBpbWcuZGF0YXNldC5zdGVwID0gJzEnOwogICAgICAg
ICAgICBpbWcuc3JjID0gU1RPUkVfQkFTRSArIGVuY29kZVVSSUNvbXBvbmVudCh0aE5hbWUgfHwgYmFy
ZSk7CiAgICAgICAgfSBlbHNlIHsKICAgICAgICAgICAgLy8gTm8gZmlsZSB5ZXQgKGp1c3QgY29waWVk
KSDigJRrZWVwIHNoaW1tZXI7IEluamVjdExpdmVJbWFnZVRodW1iIC8gX19zZXRUaHVtYiBmaWxscyBp
bgogICAgICAgICAgICBpbWcuY2xhc3NMaXN0LmFkZCgndGh1bWItbG9hZGluZycpOwogICAgICAgICAg
ICBpZiAod3JhcCkgd3JhcC5jbGFzc0xpc3QuYWRkKCd3YWl0aW5nJyk7CiAgICAgICAgfQogICAgfQoK
ICAgIHdpbmRvdy5fX3NldFRodW1iID0gKGlkLCB1cmwpID0+IHsKICAgICAgICBpZiAoIXVybCkgcmV0
dXJuOwogICAgICAgIGNvbnN0IGtleSA9IFN0cmluZyhpZCk7CiAgICAgICAgdGh1bWJDYWNoZS5zZXQo
a2V5LCB1cmwpOwogICAgICAgIGNvbnN0IGFwcGx5ID0gaW1nID0+IHsKICAgICAgICAgICAgaWYgKGlt
Zy5fZmFpbFRpbWVyKSB0cnkgeyBjbGVhclRpbWVvdXQoaW1nLl9mYWlsVGltZXIpOyB9IGNhdGNoIHt9
CiAgICAgICAgICAgIGltZy5vbmVycm9yID0gbnVsbDsKICAgICAgICAgICAgaW1nLmFsdCA9ICcnOwog
ICAgICAgICAgICBpbWcuY2xhc3NMaXN0LnJlbW92ZSgndGh1bWItbG9hZGluZycpOwogICAgICAgICAg
ICBjb25zdCB3cmFwID0gaW1nLnBhcmVudEVsZW1lbnQ7CiAgICAgICAgICAgIGlmICh3cmFwKSB3cmFw
LmNsYXNzTGlzdC5yZW1vdmUoJ3dhaXRpbmcnKTsKICAgICAgICAgICAgaW1nLnNyYyA9IHVybDsKICAg
ICAgICB9OwogICAgICAgIGxldCBoaXQgPSAwOwogICAgICAgIGRvY3VtZW50LnF1ZXJ5U2VsZWN0b3JB
bGwoJy5pdG1bZGF0YS1pZD0iJyArIGtleSArICciXSBpbWcuaS10aHVtYicpLmZvckVhY2goaW1nID0+
IHsKICAgICAgICAgICAgYXBwbHkoaW1nKTsgaGl0Kys7CiAgICAgICAgfSk7CiAgICAgICAgaWYgKCFo
aXQpIHsKICAgICAgICAgICAgZG9jdW1lbnQucXVlcnlTZWxlY3RvckFsbCgnaW1nLmktdGh1bWJbZGF0
YS10aHVtYi1pZD0iJyArIGtleSArICciXScpLmZvckVhY2goYXBwbHkpOwogICAgICAgIH0KICAgIH07
CgogICAgZnVuY3Rpb24gaXNEcmFnRXhjbHVkZSh0KSB7CiAgICAgICAgcmV0dXJuICEhdC5jbG9zZXN0
KCcjc2VhcmNoLXdyYXAsICNidG4tc2VhcmNoLCAjYnRuLWxvY2F0ZSwgI2J0bi10b2RheSwgI2J0bi1w
aW4sICNidG4tY2xyLCAjbXVsdGktYmFyLCAjbXVsdGktc2VsLCAjbXVsdGktY250LCAjcGFzdGUtc2Vw
LXdyYXAsIC50YWIsIC5pdG0sICN0YWItYWN0aW9ucywgI2N0eCwgI2Nsci1kbGcsICNwYXRoLXRpcCwg
YnV0dG9uLCBpbnB1dCwgYScpOwogICAgfQogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2FwcCcp
LmFkZEV2ZW50TGlzdGVuZXIoJ21vdXNlZG93bicsIGUgPT4gewogICAgICAgIGlmIChlLmJ1dHRvbiAh
PT0gMCkgcmV0dXJuOwogICAgICAgIGlmIChpc0RyYWdFeGNsdWRlKGUudGFyZ2V0KSkgcmV0dXJuOwog
ICAgICAgIGUucHJldmVudERlZmF1bHQoKTsKICAgICAgICBhaGsoJ3N0YXJ0RHJhZycpOwogICAgfSwg
dHJ1ZSk7CgogICAgY29uc3QgaXNVcmwgID0gcyA9PiAvXmh0dHBzPzpcL1wvL2kudGVzdCgocyB8fCAn
JykudHJpbSgpKTsKCiAgICBmdW5jdGlvbiBhZ28oZGF0ZVN0cikgewogICAgICAgIHRyeSB7CiAgICAg
ICAgICAgIGNvbnN0IGQgPSBuZXcgRGF0ZShTdHJpbmcoZGF0ZVN0cikucmVwbGFjZSgnICcsICdUJykp
OwogICAgICAgICAgICBjb25zdCBzID0gKERhdGUubm93KCkgLSBkKSAvIDEwMDAgfCAwOwogICAgICAg
ICAgICBpZiAocyA8IDYwKSByZXR1cm4gJ+WImuWImic7CiAgICAgICAgICAgIGlmIChzIDwgMzYwMCkg
cmV0dXJuIChzIC8gNjAgfCAwKSArICcg5YiG6ZKf5YmNJzsKICAgICAgICAgICAgaWYgKHMgPCA4NjQw
MCkgcmV0dXJuIChzIC8gMzYwMCB8IDApICsgJyDlsI/ml7bliY0nOwogICAgICAgICAgICByZXR1cm4g
KHMgLyA4NjQwMCB8IDApICsgJyDlpKnliY0nOwogICAgICAgIH0gY2F0Y2ggeyByZXR1cm4gZGF0ZVN0
cjsgfQogICAgfQoKICAgIGZ1bmN0aW9uIG5vcm1UeXBlKHQpIHsKICAgICAgICB0ID0gU3RyaW5nKHQg
fHwgJycpLnRvTG93ZXJDYXNlKCk7CiAgICAgICAgaWYgKHQgPT09ICdpbWFnZScgfHwgdCA9PT0gJ2lt
ZycgfHwgdCA9PT0gJ2JpdG1hcCcpIHJldHVybiAnaW1hZ2UnOwogICAgICAgIGlmICh0ID09PSAnZmls
ZScgIHx8IHQgPT09ICdmaWxlcycpIHJldHVybiAnZmlsZSc7CiAgICAgICAgaWYgKHQgPT09ICdyZWNl
bnQnIHx8IHQgPT09ICdmb2xkZXInIHx8IHQgPT09ICdkaXInKSByZXR1cm4gJ3JlY2VudCc7CiAgICAg
ICAgaWYgKHQgPT09ICdsaW5rJyB8fCB0ID09PSAndXJsJykgcmV0dXJuICdsaW5rJzsKICAgICAgICBy
ZXR1cm4gJ3RleHQnOwogICAgfQogICAgZnVuY3Rpb24gaXNQaW5uZWQoYykgewogICAgICAgIHJldHVy
biBjLnBpbm5lZCA9PT0gdHJ1ZSB8fCBjLnBpbm5lZCA9PT0gMSB8fCBjLnBpbm5lZCA9PT0gJ3RydWUn
IHx8IGMucGlubmVkID09PSAnMSc7CiAgICB9CiAgICAvKiog5ZCM5q2l5omA5pyJIHRhYiDnvJPlrZjp
h4znmoTmlLbol4/moIforrDvvIzpgb/lhY3mlLbol4/pobXlj5bmtojlkI7lhbblroPliJfooajku43m
mL7npLrjgIzlj5bmtojmlLbol4/jgI0gKi8KICAgIGZ1bmN0aW9uIHBhdGNoUGlubmVkSW5DYWNoZXMo
aWQsIHBpbm5lZCkgewogICAgICAgIGlkID0gK2lkOwogICAgICAgIGlmICghaWQpIHJldHVybjsKICAg
ICAgICBjb25zdCBhcHBseSA9IChjKSA9PiB7CiAgICAgICAgICAgIGlmICghYyB8fCArYy5pZCAhPT0g
aWQpIHJldHVybjsKICAgICAgICAgICAgYy5waW5uZWQgPSAhIXBpbm5lZDsKICAgICAgICAgICAgaWYg
KCFwaW5uZWQpIGMucGluVGltZSA9ICcnOwogICAgICAgIH07CiAgICAgICAgZm9yIChjb25zdCB4IG9m
IGFsbENsaXBzKSBhcHBseSh4KTsKICAgICAgICB0cnkgewogICAgICAgICAgICBmb3IgKGNvbnN0IFtr
ZXksIGhpdF0gb2Ygdmlld01lbS5lbnRyaWVzKCkpIHsKICAgICAgICAgICAgICAgIGlmICghaGl0IHx8
ICFBcnJheS5pc0FycmF5KGhpdC5pdGVtcykpIGNvbnRpbnVlOwogICAgICAgICAgICAgICAgZm9yIChj
b25zdCB4IG9mIGhpdC5pdGVtcykgYXBwbHkoeCk7CiAgICAgICAgICAgICAgICAvLyDmlLbol48gdGFi
IOe8k+WtmO+8muWPlua2iOWQjuebtOaOpeenu+WHugogICAgICAgICAgICAgICAgaWYgKCFwaW5uZWQg
JiYgU3RyaW5nKGtleSkuc3RhcnRzV2l0aCgncGlubmVkXHQnKSkgewogICAgICAgICAgICAgICAgICAg
IGNvbnN0IGJlZm9yZSA9IGhpdC5pdGVtcy5sZW5ndGg7CiAgICAgICAgICAgICAgICAgICAgaGl0Lml0
ZW1zID0gaGl0Lml0ZW1zLmZpbHRlcih4ID0+ICt4LmlkICE9PSBpZCk7CiAgICAgICAgICAgICAgICAg
ICAgaWYgKGhpdC5pdGVtcy5sZW5ndGggIT09IGJlZm9yZSkKICAgICAgICAgICAgICAgICAgICAgICAg
aGl0LnRvdGFsID0gTWF0aC5tYXgoMCwgKE51bWJlcihoaXQudG90YWwpIHx8IGJlZm9yZSkgLSAoYmVm
b3JlIC0gaGl0Lml0ZW1zLmxlbmd0aCkpOwogICAgICAgICAgICAgICAgICAgIHZpZXdNZW0uc2V0KGtl
eSwgaGl0KTsKICAgICAgICAgICAgICAgIH0KICAgICAgICAgICAgfQogICAgICAgIH0gY2F0Y2gge30K
ICAgIH0KICAgIGZ1bmN0aW9uIGlzUGFzdGVkKGMpIHsKICAgICAgICByZXR1cm4gYy5wYXN0ZWQgPT09
IHRydWUgfHwgYy5wYXN0ZWQgPT09IDEgfHwgYy5wYXN0ZWQgPT09ICd0cnVlJyB8fCBjLnBhc3RlZCA9
PT0gJzEnOwogICAgfQoKICAgIGZ1bmN0aW9uIGlzTWFya2Rvd24odGV4dCkgewogICAgICAgIGlmICgh
dGV4dCB8fCB0ZXh0Lmxlbmd0aCA8IDQpIHJldHVybiBmYWxzZTsKICAgICAgICByZXR1cm4gLyg/Ol58
XG4pI3sxLDZ9IHxeWy0qK10gfFwqXCpbXipcbl0rXCpcKnxfX1teX1xuXStfX3woPzpefFxuKT4gfGBg
YHxgW15gXG5dK2B8XFtbXlxdXStcXVwoW14pXStcKXxcfC4rXHwuK1x8L20udGVzdCh0ZXh0KTsKICAg
IH0KICAgIGZ1bmN0aW9uIGNsaXBVc2VzTUljb24oYykgewogICAgICAgIGlmICghYykgcmV0dXJuIGZh
bHNlOwogICAgICAgIGlmIChjLmlzTWQgPT09IHRydWUgfHwgYy5pc01kID09PSAxIHx8IGMuaXNNZCA9
PT0gJ3RydWUnIHx8IGMuaXNNZCA9PT0gJzEnKSByZXR1cm4gdHJ1ZTsKICAgICAgICBpZiAoYy5pc1Jp
Y2ggPT09IHRydWUgfHwgYy5pc1JpY2ggPT09IDEgfHwgYy5pc1JpY2ggPT09ICd0cnVlJyB8fCBjLmlz
UmljaCA9PT0gJzEnKSByZXR1cm4gdHJ1ZTsKICAgICAgICBjb25zdCB0ID0gU3RyaW5nKGMudHlwZSB8
fCAnJykudG9Mb3dlckNhc2UoKTsKICAgICAgICBpZiAodCAmJiB0ICE9PSAndGV4dCcgJiYgdCAhPT0g
J2xpbmsnKSByZXR1cm4gZmFsc2U7CiAgICAgICAgcmV0dXJuIGlzTWFya2Rvd24oYy5kYXRhIHx8IGMu
cHJldmlldyB8fCAnJyk7CiAgICB9CiAgICBmdW5jdGlvbiBlc2NBdHRyKHMpIHsKICAgICAgICByZXR1
cm4gU3RyaW5nKHMgfHwgJycpCiAgICAgICAgICAgIC5yZXBsYWNlKC8mL2csICcmYW1wOycpCiAgICAg
ICAgICAgIC5yZXBsYWNlKC8iL2csICcmcXVvdDsnKQogICAgICAgICAgICAucmVwbGFjZSgvPC9nLCAn
Jmx0OycpCiAgICAgICAgICAgIC5yZXBsYWNlKC8+L2csICcmZ3Q7Jyk7CiAgICB9CgogICAgZnVuY3Rp
b24gdG9kYXlQcmVmaXgoKSB7CiAgICAgICAgY29uc3QgZCA9IG5ldyBEYXRlKCk7CiAgICAgICAgY29u
c3QgcCA9IG4gPT4gU3RyaW5nKG4pLnBhZFN0YXJ0KDIsICcwJyk7CiAgICAgICAgcmV0dXJuIGQuZ2V0
RnVsbFllYXIoKSArICctJyArIHAoZC5nZXRNb250aCgpICsgMSkgKyAnLScgKyBwKGQuZ2V0RGF0ZSgp
KTsKICAgIH0KICAgIGZ1bmN0aW9uIGlzVG9kYXlDbGlwKGMpIHsKICAgICAgICByZXR1cm4gU3RyaW5n
KGMudGltZSB8fCAnJykuc3RhcnRzV2l0aCh0b2RheVByZWZpeCgpKTsKICAgIH0KCiAgICBmdW5jdGlv
biBjbGlwSGF5KGMpIHsKICAgICAgICByZXR1cm4gU3RyaW5nKGMucHJldmlldyB8fCAnJykgKyAnICcg
KyBTdHJpbmcoYy5kYXRhIHx8ICcnKSArICcgJwogICAgICAgICAgICArIFN0cmluZyhjLmxpbmtUaXRs
ZSB8fCAnJykgKyAnICcgKyBTdHJpbmcoYy5mYXZUaXRsZSB8fCAnJyk7CiAgICB9CiAgICAvKiogTWF0
Y2ggQUhLIEl0ZW1NYXRjaGVzVmlldyBsaXN0IHNlYXJjaCDigJQgcHJldmlldyAoKyBzaG9ydCBib2R5
IGZhbGxiYWNrKSwgbm90IGZ1bGwgZGF0YSAqLwogICAgZnVuY3Rpb24gY2xpcFNlYXJjaEhheShjKSB7
CiAgICAgICAgY29uc3QgdHlwZSA9IFN0cmluZyhjLnR5cGUgfHwgJycpLnRvTG93ZXJDYXNlKCk7CiAg
ICAgICAgaWYgKHR5cGUgPT09ICdpbWFnZScpCiAgICAgICAgICAgIHJldHVybiBTdHJpbmcoYy5mYXZU
aXRsZSB8fCAnJyk7CiAgICAgICAgaWYgKHR5cGUgPT09ICdmaWxlJykgewogICAgICAgICAgICByZXR1
cm4gU3RyaW5nKGMucHJldmlldyB8fCAnJykgKyAnICcgKyBTdHJpbmcoYy5kYXRhIHx8ICcnKSArICcg
JwogICAgICAgICAgICAgICAgKyBTdHJpbmcoYy5mYXZUaXRsZSB8fCAnJyk7CiAgICAgICAgfQogICAg
ICAgIGxldCBwcmV2ID0gU3RyaW5nKGMucHJldmlldyB8fCAnJyk7CiAgICAgICAgaWYgKCFwcmV2ICYm
IGMuZGF0YSkKICAgICAgICAgICAgcHJldiA9IFN0cmluZyhjLmRhdGEpLnNsaWNlKDAsIDUwMCk7CiAg
ICAgICAgcmV0dXJuIHByZXYgKyAnICcgKyBTdHJpbmcoYy5saW5rVGl0bGUgfHwgJycpICsgJyAnICsg
U3RyaW5nKGMuZmF2VGl0bGUgfHwgJycpOwogICAgfQogICAgZnVuY3Rpb24gY2xpcE1hdGNoZXNTZWFy
Y2goYywgdGVybUwpIHsKICAgICAgICBjb25zdCB0eXBlID0gU3RyaW5nKGMudHlwZSB8fCAnJykudG9M
b3dlckNhc2UoKTsKICAgICAgICBjb25zdCBoYXkgPSAodHlwZSA9PT0gJ2ltYWdlJyA/IFN0cmluZyhj
LmZhdlRpdGxlIHx8ICcnKSA6IGNsaXBTZWFyY2hIYXkoYykpLnRvTG93ZXJDYXNlKCk7CiAgICAgICAg
cmV0dXJuIHRlcm1MLmV2ZXJ5KHQgPT4gaGF5LmluY2x1ZGVzKHQpKTsKICAgIH0KICAgIGZ1bmN0aW9u
IGZpbHRlcihjbGlwcywgdGFiLCBxKSB7CiAgICAgICAgLy8g5Li75py65bey6L+H5ruk5pe25LuN5YGa
5YmN56uv5YWc5bqV77ya6YG/5YWN56ue5oCB5o6o5p2l5pyq5ZG95Lit6KGMCiAgICAgICAgY29uc3Qg
dGVybXMgPSBxdWVyeVRlcm1zKHEpOwogICAgICAgIGlmICghdGVybXMubGVuZ3RoKSByZXR1cm4gY2xp
cHM7CiAgICAgICAgY29uc3QgdGVybUwgPSB0ZXJtcy5tYXAodCA9PiB0LnRvTG93ZXJDYXNlKCkpOwog
ICAgICAgIGNvbnN0IG1hdGNoZWRHcm91cHMgPSBuZXcgU2V0KCk7CiAgICAgICAgZm9yIChjb25zdCBj
IG9mIGNsaXBzKSB7CiAgICAgICAgICAgIGlmICghY2xpcE1hdGNoZXNTZWFyY2goYywgdGVybUwpKSBj
b250aW51ZTsKICAgICAgICAgICAgY29uc3QgZ2lkID0gU3RyaW5nKGMgJiYgYy5mYXZHcm91cCB8fCAn
JykudHJpbSgpOwogICAgICAgICAgICBpZiAoZ2lkKSBtYXRjaGVkR3JvdXBzLmFkZChnaWQpOwogICAg
ICAgIH0KICAgICAgICAvLyDlkIjlubbnu4TvvJrlhbPplK7lrZflj6/og73liIbmlaPlnKjkuI3lkIzo
oYzvvIjmoIfpopgv5q2j5paH77yJCiAgICAgICAgY29uc3QgYnlHcm91cCA9IG5ldyBNYXAoKTsKICAg
ICAgICBmb3IgKGNvbnN0IGMgb2YgY2xpcHMpIHsKICAgICAgICAgICAgY29uc3QgZ2lkID0gU3RyaW5n
KGMgJiYgYy5mYXZHcm91cCB8fCAnJykudHJpbSgpOwogICAgICAgICAgICBpZiAoIWdpZCkgY29udGlu
dWU7CiAgICAgICAgICAgIGlmICghYnlHcm91cC5oYXMoZ2lkKSkgYnlHcm91cC5zZXQoZ2lkLCBbXSk7
CiAgICAgICAgICAgIGJ5R3JvdXAuZ2V0KGdpZCkucHVzaChjKTsKICAgICAgICB9CiAgICAgICAgZm9y
IChjb25zdCBbZ2lkLCBtZW1iZXJzXSBvZiBieUdyb3VwKSB7CiAgICAgICAgICAgIGlmIChtYXRjaGVk
R3JvdXBzLmhhcyhnaWQpKSBjb250aW51ZTsKICAgICAgICAgICAgY29uc3QgdW5pb24gPSBtZW1iZXJz
Lm1hcChjID0+IHsKICAgICAgICAgICAgICAgIGNvbnN0IHR5cGUgPSBTdHJpbmcoYy50eXBlIHx8ICcn
KS50b0xvd2VyQ2FzZSgpOwogICAgICAgICAgICAgICAgcmV0dXJuICh0eXBlID09PSAnaW1hZ2UnID8g
U3RyaW5nKGMuZmF2VGl0bGUgfHwgJycpIDogY2xpcFNlYXJjaEhheShjKSkudG9Mb3dlckNhc2UoKTsK
ICAgICAgICAgICAgfSkuam9pbignICcpOwogICAgICAgICAgICBpZiAodGVybUwuZXZlcnkodCA9PiB1
bmlvbi5pbmNsdWRlcyh0KSkpCiAgICAgICAgICAgICAgICBtYXRjaGVkR3JvdXBzLmFkZChnaWQpOwog
ICAgICAgIH0KICAgICAgICByZXR1cm4gY2xpcHMuZmlsdGVyKGMgPT4gewogICAgICAgICAgICBpZiAo
Y2xpcE1hdGNoZXNTZWFyY2goYywgdGVybUwpKSByZXR1cm4gdHJ1ZTsKICAgICAgICAgICAgY29uc3Qg
Z2lkID0gU3RyaW5nKGMgJiYgYy5mYXZHcm91cCB8fCAnJykudHJpbSgpOwogICAgICAgICAgICByZXR1
cm4gZ2lkICYmIG1hdGNoZWRHcm91cHMuaGFzKGdpZCk7CiAgICAgICAgfSk7CiAgICB9CgogICAgZnVu
Y3Rpb24gbWFya1Bhc3RlZExvY2FsKGlkcykgewogICAgICAgIGNvbnN0IGxpc3QgPSBBcnJheS5pc0Fy
cmF5KGlkcykgPyBpZHMgOiBbaWRzXTsKICAgICAgICBpZiAobGlzdC5sZW5ndGgpCiAgICAgICAgICAg
IHJlbWVtYmVyTGFzdFBhc3RlKGxpc3RbbGlzdC5sZW5ndGggLSAxXSk7CiAgICAgICAgY29uc3QgYmFk
Z2VIdG1sID0gYDxzdmcgdmlld0JveD0iMCAwIDE2IDE2IiBmaWxsPSJub25lIiBzdHJva2U9ImN1cnJl
bnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIyLjQiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIgc3Ryb2tlLWxp
bmVqb2luPSJyb3VuZCI+PHBvbHlsaW5lIHBvaW50cz0iMy41IDguNSA2LjUgMTEuNSAxMi41IDQuNSIv
Pjwvc3ZnPmA7CiAgICAgICAgbGlzdC5mb3JFYWNoKHJhd0lkID0+IHsKICAgICAgICAgICAgY29uc3Qg
aWQgPSArcmF3SWQ7CiAgICAgICAgICAgIGNvbnN0IGMgPSBhbGxDbGlwcy5maW5kKHggPT4gK3guaWQg
PT09IGlkKTsKICAgICAgICAgICAgaWYgKGMpIGMucGFzdGVkID0gdHJ1ZTsKICAgICAgICAgICAgY29u
c3Qgcm93ID0gbGlzdEVsICYmICgKICAgICAgICAgICAgICAgIGxpc3RFbC5xdWVyeVNlbGVjdG9yKCcu
aXRtW2RhdGEtaWQ9IicgKyBpZCArICciXScpCiAgICAgICAgICAgICAgICB8fCBsaXN0RWwucXVlcnlT
ZWxlY3RvcignLml0bVtkYXRhLWlkPSInICsgU3RyaW5nKHJhd0lkKSArICciXScpCiAgICAgICAgICAg
ICk7CiAgICAgICAgICAgIGlmICghcm93KSByZXR1cm47CiAgICAgICAgICAgIHJvdy5jbGFzc0xpc3Qu
YWRkKCdwYXN0ZWQnLCAncS1kb25lJyk7CiAgICAgICAgICAgIGNvbnN0IGljbyA9IHJvdy5xdWVyeVNl
bGVjdG9yKCcuaS1pY28nKTsKICAgICAgICAgICAgaWYgKGljbyAmJiAhaWNvLnF1ZXJ5U2VsZWN0b3Io
Jy5pLXVzZWQnKSkgewogICAgICAgICAgICAgICAgY29uc3QgYmFkZ2UgPSBkb2N1bWVudC5jcmVhdGVF
bGVtZW50KCdzcGFuJyk7CiAgICAgICAgICAgICAgICBiYWRnZS5jbGFzc05hbWUgPSAnaS11c2VkJzsK
ICAgICAgICAgICAgICAgIGJhZGdlLnRpdGxlID0gJ+W3sueymOi0tCc7CiAgICAgICAgICAgICAgICBi
YWRnZS5pbm5lckhUTUwgPSBiYWRnZUh0bWw7CiAgICAgICAgICAgICAgICBpY28uYXBwZW5kQ2hpbGQo
YmFkZ2UpOwogICAgICAgICAgICB9CiAgICAgICAgfSk7CiAgICAgICAgdHJ5IHsgbWFya1F1ZXVlUmFp
bHMoKTsgfSBjYXRjaCAoZSkge30KICAgIH0KICAgIHdpbmRvdy5fX21hcmtQYXN0ZWQgPSBtYXJrUGFz
dGVkTG9jYWw7CgogICAgZnVuY3Rpb24gbWFya1VucGFzdGVkTG9jYWwoaWRzKSB7CiAgICAgICAgY29u
c3QgbGlzdCA9IEFycmF5LmlzQXJyYXkoaWRzKSA/IGlkcyA6IFtpZHNdOwogICAgICAgIGxpc3QuZm9y
RWFjaChyYXdJZCA9PiB7CiAgICAgICAgICAgIGNvbnN0IGlkID0gK3Jhd0lkOwogICAgICAgICAgICBj
b25zdCBjID0gYWxsQ2xpcHMuZmluZCh4ID0+ICt4LmlkID09PSBpZCk7CiAgICAgICAgICAgIGlmIChj
KSBjLnBhc3RlZCA9IGZhbHNlOwogICAgICAgICAgICBjb25zdCByb3cgPSBsaXN0RWwgJiYgKAogICAg
ICAgICAgICAgICAgbGlzdEVsLnF1ZXJ5U2VsZWN0b3IoJy5pdG1bZGF0YS1pZD0iJyArIGlkICsgJyJd
JykKICAgICAgICAgICAgICAgIHx8IGxpc3RFbC5xdWVyeVNlbGVjdG9yKCcuaXRtW2RhdGEtaWQ9Iicg
KyBTdHJpbmcocmF3SWQpICsgJyJdJykKICAgICAgICAgICAgKTsKICAgICAgICAgICAgaWYgKCFyb3cp
IHJldHVybjsKICAgICAgICAgICAgcm93LmNsYXNzTGlzdC5yZW1vdmUoJ3Bhc3RlZCcsICdxLWRvbmUn
LCAncS1kb25lLWxpbmsnKTsKICAgICAgICAgICAgY29uc3QgYmFkZ2UgPSByb3cucXVlcnlTZWxlY3Rv
cignLmktdXNlZCcpOwogICAgICAgICAgICBpZiAoYmFkZ2UpIGJhZGdlLnJlbW92ZSgpOwogICAgICAg
ICAgICBjb25zdCBkb3QgPSByb3cucXVlcnlTZWxlY3RvcignLnEtZG90Jyk7CiAgICAgICAgICAgIGlm
IChkb3QpIGRvdC50aXRsZSA9ICfnspjotLTpmJ/liJcnOwogICAgICAgIH0pOwogICAgICAgIHRyeSB7
IG1hcmtRdWV1ZVJhaWxzKCk7IH0gY2F0Y2ggKGUpIHt9CiAgICB9CiAgICB3aW5kb3cuX19tYXJrVW5w
YXN0ZWQgPSBtYXJrVW5wYXN0ZWRMb2NhbDsKCiAgICBjb25zdCBsaXN0RWwgID0gZG9jdW1lbnQuZ2V0
RWxlbWVudEJ5SWQoJ2xpc3QnKTsKICAgIGNvbnN0IGVtcHR5RWwgPSBkb2N1bWVudC5nZXRFbGVtZW50
QnlJZCgnZW1wdHknKTsKICAgIGNvbnN0IHNrZWxFbCAgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgn
c2tlbCcpOwogICAgY29uc3QgYnRuVG9wICA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdidG4tdG9w
Jyk7CiAgICBmdW5jdGlvbiBzZXRCb290TG9hZGluZyhvbikgewogICAgICAgIGJvb3RMb2FkaW5nID0g
ISFvbjsKICAgICAgICAvLyDnp5LlvIDvvJrkuI3lho3miZPlvIDpqqjmnrbpl6rliqjvvJvlj6rkv53n
lZkgd2FpdGluZ0RhdGEg6YC76L6R6Ziy56m65oCB6K+v6ZeqCiAgICAgICAgaWYgKHNrZWxFbCkgc2tl
bEVsLmNsYXNzTGlzdC5yZW1vdmUoJ29uJyk7CiAgICAgICAgaWYgKG9uICYmIGVtcHR5RWwpIGVtcHR5
RWwuY2xhc3NMaXN0LnJlbW92ZSgnb24nKTsKICAgICAgICBjb25zdCBhcHAgPSBkb2N1bWVudC5nZXRF
bGVtZW50QnlJZCgnYXBwJyk7CiAgICAgICAgaWYgKGFwcCkgYXBwLmNsYXNzTGlzdC5yZW1vdmUoJ2Jv
b3QtbG9hZGluZycpOwogICAgfQogICAgLyoqIFdhaXQgZm9yIGhvc3QgZGF0YSDigJTkuI3lho3nq4vl
iLvlvLnpqqjmnrbvvIzmnInlhoXlrrnml7bkv53mjIHml6fliJfooaggKi8KICAgIGZ1bmN0aW9uIHNj
aGVkdWxlRGVsYXllZFNrZWwoKSB7CiAgICAgICAgd2FpdGluZ0RhdGEgPSB0cnVlOwogICAgICAgIHdp
bmRvdy5fX2RhdGFSZWFkeSA9IGZhbHNlOwogICAgICAgIGlmIChlbXB0eUVsKSBlbXB0eUVsLmNsYXNz
TGlzdC5yZW1vdmUoJ29uJyk7CiAgICAgICAgaWYgKHdpbmRvdy5fX3BlbmRpbmdTa2VsVGltZXIpIHsK
ICAgICAgICAgICAgY2xlYXJUaW1lb3V0KHdpbmRvdy5fX3BlbmRpbmdTa2VsVGltZXIpOwogICAgICAg
ICAgICB3aW5kb3cuX19wZW5kaW5nU2tlbFRpbWVyID0gMDsKICAgICAgICB9CiAgICAgICAgd2luZG93
Ll9fcGVuZGluZ1NrZWxTaW5jZSA9IERhdGUubm93KCk7CiAgICAgICAgLy8g5pyJ5pen5YiX6KGo5bCx
5L+d55WZ77yb56m65YiX6KGo5Lmf5LiN5YaN5pKt6aqo5p625Yqo55S7CiAgICB9CiAgICBmdW5jdGlv
biBjbGVhcldhaXRpbmdEYXRhKCkgewogICAgICAgIHdhaXRpbmdEYXRhID0gZmFsc2U7CiAgICAgICAg
aWYgKHdpbmRvdy5fX3BlbmRpbmdTa2VsVGltZXIpIHsKICAgICAgICAgICAgY2xlYXJUaW1lb3V0KHdp
bmRvdy5fX3BlbmRpbmdTa2VsVGltZXIpOwogICAgICAgICAgICB3aW5kb3cuX19wZW5kaW5nU2tlbFRp
bWVyID0gMDsKICAgICAgICB9CiAgICAgICAgd2luZG93Ll9fcGVuZGluZ1NrZWxTaW5jZSA9IDA7CiAg
ICAgICAgc2V0Qm9vdExvYWRpbmcoZmFsc2UpOwogICAgfQogICAgd2luZG93LnNldEJvb3RMb2FkaW5n
ID0gc2V0Qm9vdExvYWRpbmc7CiAgICB3aW5kb3cuZm9yY2VFbmRCb290TG9hZGluZyA9IGZ1bmN0aW9u
KCkgewogICAgICAgIGNsZWFyV2FpdGluZ0RhdGEoKTsKICAgICAgICAvLyBEbyBub3QgZmFrZeOAjOaa
guaXoOiusOW9leOAjWlmIGhvc3QgbmV2ZXIgcHVzaGVkCiAgICAgICAgaWYgKGhvc3RQdXNoZWRPbmNl
KQogICAgICAgICAgICB3aW5kb3cuX19kYXRhUmVhZHkgPSB0cnVlOwogICAgICAgIHRyeSB7IHJlbmRl
cigpOyB9IGNhdGNoIChlKSB7fQogICAgfTsKICAgIC8vIFNhZmV0eTogZHJvcCBzdHVjayBza2VsZXRv
bjsgc3RpbGwgbmV2ZXIgaW52ZW50IGVtcHR5LXN0YXRlIHdpdGhvdXQgaG9zdCBwdXNoCiAgICBzZXRU
aW1lb3V0KCgpID0+IHsKICAgICAgICBpZiAoaG9zdFB1c2hlZE9uY2UgfHwgd2luZG93Ll9fZGF0YVJl
YWR5KSByZXR1cm47CiAgICAgICAgaWYgKCFib290TG9hZGluZyAmJiAhd2FpdGluZ0RhdGEpIHJldHVy
bjsKICAgICAgICBjbGVhcldhaXRpbmdEYXRhKCk7CiAgICAgICAgdHJ5IHsgcmVuZGVyKCk7IH0gY2F0
Y2gge30KICAgIH0sIDgwMDApOwoKICAgIGZ1bmN0aW9uIHVwZGF0ZVRvcEJ0bigpIHsKICAgICAgICBp
ZiAoIWJ0blRvcCB8fCAhbGlzdEVsKSByZXR1cm47CiAgICAgICAgYnRuVG9wLmNsYXNzTGlzdC50b2dn
bGUoJ29uJywgbGlzdEVsLnNjcm9sbFRvcCA+IDQ4KTsKICAgIH0KICAgIGxldCBfc2Nyb2xsUmFmID0g
MDsKICAgIGxldCBfc2Nyb2xsSWRsZVQgPSAwOwogICAgbGV0IF9saXN0UHRyRG93biA9IGZhbHNlOwog
ICAgbGV0IF9wZW5kaW5nQXBwZW5kID0gbnVsbDsgLy8geyBmcm9tTGVuIH0gcXVldWVkIHdoaWxlIHNj
cm9sbGluZwogICAgd2luZG93Ll9fc2Nyb2xsQnVzeSA9IGZhbHNlOwogICAgd2luZG93Ll9fd2FudE1v
cmUgPSBmYWxzZTsKCiAgICBmdW5jdGlvbiBtYXJrTGlzdFNjcm9sbGluZygpIHsKICAgICAgICB3aW5k
b3cuX19zY3JvbGxCdXN5ID0gdHJ1ZTsKICAgICAgICB0cnkgeyBsaXN0RWwuY2xhc3NMaXN0LmFkZCgn
aXMtc2Nyb2xsaW5nJyk7IH0gY2F0Y2gge30KICAgICAgICBpZiAoX3Njcm9sbElkbGVUKSBjbGVhclRp
bWVvdXQoX3Njcm9sbElkbGVUKTsKICAgICAgICBfc2Nyb2xsSWRsZVQgPSBzZXRUaW1lb3V0KCgpID0+
IHsKICAgICAgICAgICAgX3Njcm9sbElkbGVUID0gMDsKICAgICAgICAgICAgZmx1c2hTY3JvbGxJZGxl
KCk7CiAgICAgICAgfSwgMjIwKTsKICAgIH0KCiAgICBmdW5jdGlvbiBmbHVzaFNjcm9sbElkbGUoKSB7
CiAgICAgICAgaWYgKF9saXN0UHRyRG93bikgewogICAgICAgICAgICBtYXJrTGlzdFNjcm9sbGluZygp
OwogICAgICAgICAgICByZXR1cm47CiAgICAgICAgfQogICAgICAgIHdpbmRvdy5fX3Njcm9sbEJ1c3kg
PSBmYWxzZTsKICAgICAgICB0cnkgeyBsaXN0RWwuY2xhc3NMaXN0LnJlbW92ZSgnaXMtc2Nyb2xsaW5n
Jyk7IH0gY2F0Y2gge30KICAgICAgICBpZiAoX3BlbmRpbmdBcHBlbmQpIHsKICAgICAgICAgICAgY29u
c3QgcGVuZGluZyA9IF9wZW5kaW5nQXBwZW5kOwogICAgICAgICAgICBfcGVuZGluZ0FwcGVuZCA9IG51
bGw7CiAgICAgICAgICAgIGFwcGx5QXBwZW5kUGF5bG9hZChwZW5kaW5nKTsKICAgICAgICB9CiAgICAg
ICAgaWYgKHdpbmRvdy5fX3dhbnRNb3JlKQogICAgICAgICAgICByZXF1ZXN0TW9yZSgpOwogICAgICAg
IGVsc2UgaWYgKCFsb2FkaW5nTW9yZQogICAgICAgICAgICAmJiBkaXNrVG90YWwgPiAwCiAgICAgICAg
ICAgICYmIGFsbENsaXBzLmxlbmd0aCA8IGRpc2tUb3RhbAogICAgICAgICAgICAmJiBsaXN0RWwuc2Ny
b2xsVG9wICsgbGlzdEVsLmNsaWVudEhlaWdodCA+PSBsaXN0RWwuc2Nyb2xsSGVpZ2h0IC0gNDIwKQog
ICAgICAgICAgICByZXF1ZXN0TW9yZSgpOwogICAgfQoKICAgIGZ1bmN0aW9uIG9uTGlzdFNjcm9sbCgp
IHsKICAgICAgICBtYXJrTGlzdFNjcm9sbGluZygpOwogICAgICAgIGlmIChfc2Nyb2xsUmFmKSByZXR1
cm47CiAgICAgICAgX3Njcm9sbFJhZiA9IHJlcXVlc3RBbmltYXRpb25GcmFtZSgoKSA9PiB7CiAgICAg
ICAgICAgIF9zY3JvbGxSYWYgPSAwOwogICAgICAgICAgICB0cnkgeyBoaWRlUGF0aFRpcCgpOyB9IGNh
dGNoIHt9CiAgICAgICAgICAgIHVwZGF0ZVRvcEJ0bigpOwogICAgICAgICAgICBpZiAoIWxvYWRpbmdN
b3JlCiAgICAgICAgICAgICAgICAmJiBkaXNrVG90YWwgPiAwCiAgICAgICAgICAgICAgICAmJiBhbGxD
bGlwcy5sZW5ndGggPCBkaXNrVG90YWwKICAgICAgICAgICAgICAgICYmIGxpc3RFbC5zY3JvbGxUb3Ag
KyBsaXN0RWwuY2xpZW50SGVpZ2h0ID49IGxpc3RFbC5zY3JvbGxIZWlnaHQgLSAyNDApCiAgICAgICAg
ICAgICAgICB3aW5kb3cuX193YW50TW9yZSA9IHRydWU7CiAgICAgICAgfSk7CiAgICB9CiAgICBsaXN0
RWwuYWRkRXZlbnRMaXN0ZW5lcignc2Nyb2xsJywgb25MaXN0U2Nyb2xsLCB7IHBhc3NpdmU6IHRydWUg
fSk7CiAgICBsaXN0RWwuYWRkRXZlbnRMaXN0ZW5lcignd2hlZWwnLCBtYXJrTGlzdFNjcm9sbGluZywg
eyBwYXNzaXZlOiB0cnVlIH0pOwogICAgbGlzdEVsLmFkZEV2ZW50TGlzdGVuZXIoJ3BvaW50ZXJkb3du
JywgZSA9PiB7CiAgICAgICAgaWYgKGUuYnV0dG9uICE9PSAwKSByZXR1cm47CiAgICAgICAgX2xpc3RQ
dHJEb3duID0gdHJ1ZTsKICAgICAgICBtYXJrTGlzdFNjcm9sbGluZygpOwogICAgfSwgeyBwYXNzaXZl
OiB0cnVlIH0pOwogICAgd2luZG93LmFkZEV2ZW50TGlzdGVuZXIoJ3BvaW50ZXJ1cCcsICgpID0+IHsK
ICAgICAgICBpZiAoIV9saXN0UHRyRG93bikgcmV0dXJuOwogICAgICAgIF9saXN0UHRyRG93biA9IGZh
bHNlOwogICAgICAgIG1hcmtMaXN0U2Nyb2xsaW5nKCk7CiAgICB9LCB7IHBhc3NpdmU6IHRydWUgfSk7
CiAgICB3aW5kb3cuYWRkRXZlbnRMaXN0ZW5lcigncG9pbnRlcmNhbmNlbCcsICgpID0+IHsKICAgICAg
ICBpZiAoIV9saXN0UHRyRG93bikgcmV0dXJuOwogICAgICAgIF9saXN0UHRyRG93biA9IGZhbHNlOwog
ICAgICAgIG1hcmtMaXN0U2Nyb2xsaW5nKCk7CiAgICB9LCB7IHBhc3NpdmU6IHRydWUgfSk7CiAgICBi
dG5Ub3AuYWRkRXZlbnRMaXN0ZW5lcignY2xpY2snLCBlID0+IHsKICAgICAgICBlLnN0b3BQcm9wYWdh
dGlvbigpOwogICAgICAgIGxpc3RFbC5zY3JvbGxUbyh7IHRvcDogMCwgYmVoYXZpb3I6ICdzbW9vdGgn
IH0pOwogICAgfSk7CgogICAgZnVuY3Rpb24gdmlzaWJsZUxpc3QoKSB7CiAgICAgICAgY29uc3QgcSA9
IFN0cmluZyhxdWVyeSB8fCAnJykudHJpbSgpOwogICAgICAgIC8vIEhvc3QgYWxyZWFkeSBmaWx0ZXJl
ZCtleHBhbmRlZCBmb3IgdGhpcyBleGFjdCBxdWVyeSDigJQgZG9uJ3QgcmUtZmlsdGVyIChhdm9pZHMg
Zmxhc2ggLyBkcm9wcGVkIGZhdiBncm91cHMpCiAgICAgICAgbGV0IGxpc3QgPSAocSAmJiB3aW5kb3cu
X19ob3N0RmlsdGVyZWQgJiYgd2luZG93Ll9faG9zdEZpbHRlclEgPT09IHEpCiAgICAgICAgICAgID8g
YWxsQ2xpcHMKICAgICAgICAgICAgOiBmaWx0ZXIoYWxsQ2xpcHMsIGN1clRhYiwgcXVlcnkpOwogICAg
ICAgIC8vIOaUtuiXj+mhte+8muacrOWcsOWGjea7pOS4gOasoe+8jOWPlua2iOaUtuiXj+WPr+eri+WI
u+a2iOWkse+8jOS4jeW/heetiSBBSEsg6YeN5bu6CiAgICAgICAgaWYgKGN1clRhYiA9PT0gJ3Bpbm5l
ZCcpCiAgICAgICAgICAgIGxpc3QgPSBsaXN0LmZpbHRlcihjID0+IGlzUGlubmVkKGMpKTsKICAgICAg
ICByZXR1cm4gbGlzdDsKICAgIH0KICAgIGZ1bmN0aW9uIGVzY0h0bWwocykgewogICAgICAgIHJldHVy
biBTdHJpbmcocyA/PyAnJykucmVwbGFjZSgvJi9nLCcmYW1wOycpLnJlcGxhY2UoLzwvZywnJmx0Oycp
LnJlcGxhY2UoLz4vZywnJmd0OycpLnJlcGxhY2UoLyIvZywnJnF1b3Q7Jyk7CiAgICB9CiAgICBmdW5j
dGlvbiBxdWVyeVRlcm1zKHEpIHsKICAgICAgICBjb25zdCBvdXQgPSBbXTsKICAgICAgICBmb3IgKGNv
bnN0IHNlZyBvZiBTdHJpbmcocSB8fCAnJykuc3BsaXQoJ3wnKSkgewogICAgICAgICAgICBjb25zdCBz
ID0gc2VnLnRyaW0oKTsKICAgICAgICAgICAgaWYgKCFzKSBjb250aW51ZTsKICAgICAgICAgICAgY29u
c3Qgd29yZHMgPSBzLnNwbGl0KC9ccysvKS5maWx0ZXIoQm9vbGVhbik7CiAgICAgICAgICAgIGlmICh3
b3Jkcy5sZW5ndGgpIG91dC5wdXNoKC4uLndvcmRzKTsKICAgICAgICB9CiAgICAgICAgcmV0dXJuIG91
dDsKICAgIH0KICAgIGZ1bmN0aW9uIGhsSHRtbCh0ZXh0KSB7CiAgICAgICAgY29uc3QgdGVybXMgPSBx
dWVyeVRlcm1zKHF1ZXJ5KTsKICAgICAgICBjb25zdCBzID0gU3RyaW5nKHRleHQgPz8gJycpOwogICAg
ICAgIGlmICghdGVybXMubGVuZ3RoKSByZXR1cm4gZXNjSHRtbChzKTsKICAgICAgICBjb25zdCBsb3dl
ciA9IHMudG9Mb3dlckNhc2UoKTsKICAgICAgICBjb25zdCB0ZXJtTCA9IHRlcm1zLm1hcCh0ID0+IHQu
dG9Mb3dlckNhc2UoKSk7CiAgICAgICAgbGV0IG91dCA9ICcnLCBpID0gMDsKICAgICAgICB3aGlsZSAo
aSA8IHMubGVuZ3RoKSB7CiAgICAgICAgICAgIGxldCBiZXN0SiA9IC0xLCBiZXN0TGVuID0gMDsKICAg
ICAgICAgICAgZm9yIChsZXQgdGkgPSAwOyB0aSA8IHRlcm1MLmxlbmd0aDsgdGkrKykgewogICAgICAg
ICAgICAgICAgY29uc3QgdCA9IHRlcm1MW3RpXTsKICAgICAgICAgICAgICAgIGlmICghdCkgY29udGlu
dWU7CiAgICAgICAgICAgICAgICBjb25zdCBqID0gbG93ZXIuaW5kZXhPZih0LCBpKTsKICAgICAgICAg
ICAgICAgIGlmIChqIDwgMCkgY29udGludWU7CiAgICAgICAgICAgICAgICBpZiAoYmVzdEogPCAwIHx8
IGogPCBiZXN0SiB8fCAoaiA9PT0gYmVzdEogJiYgdC5sZW5ndGggPiBiZXN0TGVuKSkgewogICAgICAg
ICAgICAgICAgICAgIGJlc3RKID0gajsgYmVzdExlbiA9IHQubGVuZ3RoOwogICAgICAgICAgICAgICAg
fQogICAgICAgICAgICB9CiAgICAgICAgICAgIGlmIChiZXN0SiA8IDApIHsgb3V0ICs9IGVzY0h0bWwo
cy5zbGljZShpKSk7IGJyZWFrOyB9CiAgICAgICAgICAgIG91dCArPSBlc2NIdG1sKHMuc2xpY2UoaSwg
YmVzdEopKTsKICAgICAgICAgICAgb3V0ICs9ICc8bWFyayBjbGFzcz0icS1obCI+JyArIGVzY0h0bWwo
cy5zbGljZShiZXN0SiwgYmVzdEogKyBiZXN0TGVuKSkgKyAnPC9tYXJrPic7CiAgICAgICAgICAgIGkg
PSBiZXN0SiArIE1hdGgubWF4KDEsIGJlc3RMZW4pOwogICAgICAgIH0KICAgICAgICByZXR1cm4gb3V0
OwogICAgfQogICAgZnVuY3Rpb24gc2V0SGxUZXh0KGVsLCB0ZXh0KSB7CiAgICAgICAgaWYgKCFlbCkg
cmV0dXJuOwogICAgICAgIGNvbnN0IHEgPSBTdHJpbmcocXVlcnkgfHwgJycpLnRyaW0oKTsKICAgICAg
ICBpZiAoIXEpIHsKICAgICAgICAgICAgZWwuY2xhc3NMaXN0LnJlbW92ZSgnaGFzLWhsJyk7CiAgICAg
ICAgICAgIGVsLnRleHRDb250ZW50ID0gdGV4dCA9PSBudWxsID8gJycgOiBTdHJpbmcodGV4dCk7CiAg
ICAgICAgICAgIHJldHVybjsKICAgICAgICB9CiAgICAgICAgZWwuY2xhc3NMaXN0LmFkZCgnaGFzLWhs
Jyk7CiAgICAgICAgZWwuaW5uZXJIVE1MID0gaGxIdG1sKHRleHQpOwogICAgfQoKCiAgICBmdW5jdGlv
biBhcHBseVRhYlN3aXRjaEFuaW0oKSB7CiAgICAgICAgaWYgKCF0YWJTd2l0Y2hBbmltRGlyIHx8ICFs
aXN0RWwpIHJldHVybjsKICAgICAgICBpZiAoIWxpc3RFbC5xdWVyeVNlbGVjdG9yKCcuaXRtLCAjZW1w
dHkub24sICNsaXN0LW1vcmUnKSkKICAgICAgICAgICAgcmV0dXJuOwogICAgICAgIGNvbnN0IGRpciA9
IHRhYlN3aXRjaEFuaW1EaXI7CiAgICAgICAgdGFiU3dpdGNoQW5pbURpciA9IDA7CiAgICAgICAgbGlz
dEVsLmNsYXNzTGlzdC5yZW1vdmUoJ3RhYi1pbi1scicsICd0YWItaW4tcmwnKTsKICAgICAgICB2b2lk
IGxpc3RFbC5vZmZzZXRXaWR0aDsKICAgICAgICBsaXN0RWwuY2xhc3NMaXN0LmFkZChkaXIgPiAwID8g
J3RhYi1pbi1scicgOiAndGFiLWluLXJsJyk7CiAgICAgICAgY2xlYXJUaW1lb3V0KGxpc3RFbC5fdGFi
QW5pbVRpbWVyKTsKICAgICAgICBsaXN0RWwuX3RhYkFuaW1UaW1lciA9IHNldFRpbWVvdXQoKCkgPT4g
ewogICAgICAgICAgICBsaXN0RWwuY2xhc3NMaXN0LnJlbW92ZSgndGFiLWluLWxyJywgJ3RhYi1pbi1y
bCcpOwogICAgICAgIH0sIDQwMCk7CiAgICB9CgogICAgZnVuY3Rpb24gdGFiSW5kZXgodGFiKSB7CiAg
ICAgICAgY29uc3QgaSA9IFRBQl9PUkRFUi5pbmRleE9mKHRhYik7CiAgICAgICAgcmV0dXJuIGkgPj0g
MCA/IGkgOiAwOwogICAgfQoKICAgIGZ1bmN0aW9uIG1vdmVUYWJJbmsoaW5zdGFudCwgdGFyZ2V0RWwp
IHsKICAgICAgICBjb25zdCBpbmsgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgndGFiLWluaycpOwog
ICAgICAgIGNvbnN0IHRhYnMgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgndGFicycpOwogICAgICAg
IGNvbnN0IGVsID0gdGFyZ2V0RWwgfHwgZG9jdW1lbnQucXVlcnlTZWxlY3RvcignI3RhYnMgLnRhYi5v
bicpOwogICAgICAgIGlmICghaW5rIHx8ICF0YWJzIHx8ICFlbCkgcmV0dXJuOwogICAgICAgIGNvbnN0
IHRyID0gdGFicy5nZXRCb3VuZGluZ0NsaWVudFJlY3QoKTsKICAgICAgICBjb25zdCByID0gZWwuZ2V0
Qm91bmRpbmdDbGllbnRSZWN0KCk7CiAgICAgICAgY29uc3QgeCA9IHIubGVmdCAtIHRyLmxlZnQ7CiAg
ICAgICAgY29uc3QgaCA9IE1hdGgubWF4KDIwLCBNYXRoLnJvdW5kKHIuaGVpZ2h0KSk7CiAgICAgICAg
Y29uc3QgeSA9IHIudG9wIC0gdHIudG9wOwogICAgICAgIGNvbnN0IHcgPSBNYXRoLm1heCgyNCwgci53
aWR0aCk7CiAgICAgICAgY29uc3QgcG9zID0gJ3RyYW5zbGF0ZTNkKCcgKyB4ICsgJ3B4LCcgKyB5ICsg
J3B4LDApJzsKICAgICAgICBpbmsuc3R5bGUudHJhbnNmb3JtT3JpZ2luID0gJ2NlbnRlciBib3R0b20n
OwogICAgICAgIGluay5zdHlsZS53aWR0aCA9IHcgKyAncHgnOwogICAgICAgIGluay5zdHlsZS5oZWln
aHQgPSBoICsgJ3B4JzsKICAgICAgICBpZiAoaW5zdGFudCkgewogICAgICAgICAgICBpbmsuc3R5bGUu
dHJhbnNpdGlvbiA9ICdub25lJzsKICAgICAgICAgICAgaW5rLmNsYXNzTGlzdC5yZW1vdmUoJ3NxdWFz
aCcpOwogICAgICAgICAgICBpbmsuc3R5bGUudHJhbnNmb3JtID0gcG9zICsgJyBzY2FsZVgoMSknOwog
ICAgICAgICAgICBpbmsub2Zmc2V0SGVpZ2h0OwogICAgICAgICAgICBpbmsuc3R5bGUudHJhbnNpdGlv
biA9ICcnOwogICAgICAgICAgICByZXR1cm47CiAgICAgICAgfQogICAgICAgIC8vIFNuYXAgdG8gaG92
ZXJlZCB0YWIsIGV4cGFuZCBmcm9tIGJvdHRvbS1jZW50ZXIg4oCUIG5vIHNsaWRpbmcgYmV0d2VlbiB0
YWJzCiAgICAgICAgaW5rLnN0eWxlLnRyYW5zaXRpb24gPSAnbm9uZSc7CiAgICAgICAgaW5rLnN0eWxl
LnRyYW5zZm9ybSA9IHBvcyArICcgc2NhbGVYKDAuMDAxKSc7CiAgICAgICAgaW5rLm9mZnNldEhlaWdo
dDsKICAgICAgICBpbmsuc3R5bGUudHJhbnNpdGlvbiA9ICcnOwogICAgICAgIGluay5jbGFzc0xpc3Qu
YWRkKCdzcXVhc2gnKTsKICAgICAgICBpbmsuc3R5bGUudHJhbnNmb3JtID0gcG9zICsgJyBzY2FsZVgo
MSknOwogICAgICAgIGNsZWFyVGltZW91dChpbmsuX3NxdWFzaFRpbWVyKTsKICAgICAgICBpbmsuX3Nx
dWFzaFRpbWVyID0gc2V0VGltZW91dCgoKSA9PiBpbmsuY2xhc3NMaXN0LnJlbW92ZSgnc3F1YXNoJyks
IDM0MCk7CiAgICB9CiAgICBmdW5jdGlvbiBtYXJrVGFiKHRhYiwgaW5zdGFudCkgewogICAgICAgIGRv
Y3VtZW50LnF1ZXJ5U2VsZWN0b3JBbGwoJyN0YWJzIC50YWInKS5mb3JFYWNoKGVsID0+CiAgICAgICAg
ICAgIGVsLmNsYXNzTGlzdC50b2dnbGUoJ29uJywgZWwuZGF0YXNldC50YWIgPT09IHRhYikpOwogICAg
ICAgIG1vdmVUYWJJbmsoISFpbnN0YW50KTsKICAgIH0KICAgIGZ1bmN0aW9uIGJpbmRUYWJJbmtIb3Zl
cigpIHsKICAgICAgICBjb25zdCB0YWJzID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3RhYnMnKTsK
ICAgICAgICBpZiAoIXRhYnMgfHwgdGFicy5faW5rSG92ZXJCb3VuZCkgcmV0dXJuOwogICAgICAgIHRh
YnMuX2lua0hvdmVyQm91bmQgPSB0cnVlOwogICAgICAgIHRhYnMuYWRkRXZlbnRMaXN0ZW5lcigncG9p
bnRlcm92ZXInLCBlID0+IHsKICAgICAgICAgICAgY29uc3QgdGFiID0gZS50YXJnZXQuY2xvc2VzdCgn
LnRhYicpOwogICAgICAgICAgICBpZiAoIXRhYiB8fCAhdGFicy5jb250YWlucyh0YWIpKSByZXR1cm47
CiAgICAgICAgICAgIG1vdmVUYWJJbmsoZmFsc2UsIHRhYik7CiAgICAgICAgfSk7CiAgICAgICAgdGFi
cy5hZGRFdmVudExpc3RlbmVyKCdwb2ludGVybGVhdmUnLCBlID0+IHsKICAgICAgICAgICAgaWYgKGUu
cmVsYXRlZFRhcmdldCAmJiB0YWJzLmNvbnRhaW5zKGUucmVsYXRlZFRhcmdldCkpIHJldHVybjsKICAg
ICAgICAgICAgbW92ZVRhYkluayhmYWxzZSk7CiAgICAgICAgfSk7CiAgICB9CmZ1bmN0aW9uIHNldFRh
Yih0YWIpIHsKICAgICAgICBpZiAodGFiID09PSBjdXJUYWIpIHJldHVybjsKICAgICAgICBjb25zdCBm
cm9tID0gdGFiSW5kZXgoY3VyVGFiKTsKICAgICAgICBjb25zdCB0byA9IHRhYkluZGV4KHRhYik7CiAg
ICAgICAgdGFiU3dpdGNoQW5pbURpciA9IHRvID4gZnJvbSA/IDEgOiAodG8gPCBmcm9tID8gLTEgOiAw
KTsKICAgICAgICBjdXJUYWIgPSB0YWI7CiAgICAgICAgbG9hZGluZ01vcmUgPSBmYWxzZTsKICAgICAg
ICBtYXJrVGFiKHRhYik7CiAgICAgICAgLy8g5omT5byA5pS26JeP5bm25p+l55yL5ZCO77yM5riF6Zmk
44CM5paw5pS26JeP44CN57u/54K5CiAgICAgICAgaWYgKHRhYiA9PT0gJ3Bpbm5lZCcpCiAgICAgICAg
ICAgIGNsZWFyRmF2VW5zZWVuKCk7CgogICAgICAgIC8vIEtlZXAgc2VhcmNoICJ0b2RheSIgZmlsdGVy
IGluIHN5bmMgd2hlbiBzZWFyY2ggaXMgb3BlbgogICAgICAgIHRyeSB7CiAgICAgICAgICAgIGNvbnN0
IHdyYXAgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc2VhcmNoLXdyYXAnKTsKICAgICAgICAgICAg
Y29uc3QgYnRuVG9kYXkgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYnRuLXRvZGF5Jyk7CiAgICAg
ICAgICAgIGlmICh3cmFwICYmIHdyYXAuY2xhc3NMaXN0LmNvbnRhaW5zKCdvcGVuJykpIHsKICAgICAg
ICAgICAgICAgIGNvbnN0IHdhbnRUb2RheSA9IGZhbHNlOwogICAgICAgICAgICAgICAgaWYgKHRvZGF5
T25seSAhPT0gd2FudFRvZGF5KSB7CiAgICAgICAgICAgICAgICAgICAgdG9kYXlPbmx5ID0gd2FudFRv
ZGF5OwogICAgICAgICAgICAgICAgICAgIGlmIChidG5Ub2RheSkgYnRuVG9kYXkuY2xhc3NMaXN0LnRv
Z2dsZSgnb24nLCB0b2RheU9ubHkpOwogICAgICAgICAgICAgICAgfQogICAgICAgICAgICB9CiAgICAg
ICAgfSBjYXRjaCB7fQoKICAgICAgICBzZWxlY3RlZElkID0gbnVsbDsKICAgICAgICBtdWx0aUlkcyA9
IFtdOwogICAgICAgIGxpc3RFbC5zY3JvbGxUb3AgPSAwOwogICAgICAgIGNvbnN0IGhpdCA9IHZpZXdN
ZW0uZ2V0KHZpZXdNZW1LZXkodGFiLCBxdWVyeSwgdG9kYXlPbmx5KSk7CiAgICAgICAgaWYgKGhpdCAm
JiBBcnJheS5pc0FycmF5KGhpdC5pdGVtcykgJiYgaGl0Lml0ZW1zLmxlbmd0aCkgewogICAgICAgICAg
ICBhbGxDbGlwcyA9IGhpdC5pdGVtcy5zbGljZSgpOwogICAgICAgICAgICBkaXNrVG90YWwgPSBOdW1i
ZXIoaGl0LnRvdGFsKSB8fCBoaXQuaXRlbXMubGVuZ3RoOwogICAgICAgICAgICB3aW5kb3cuX193YWl0
aW5nVmlldyA9IGZhbHNlOwogICAgICAgICAgICBjbGVhcldhaXRpbmdEYXRhKCk7CiAgICAgICAgICAg
IHdpbmRvdy5fX2RhdGFSZWFkeSA9IHRydWU7CiAgICAgICAgICAgIGhvc3RQdXNoZWRPbmNlID0gdHJ1
ZTsKICAgICAgICAgICAgc2F3Tm9uRW1wdHkgPSB0cnVlOwogICAgICAgICAgICByZW5kZXIoKTsKICAg
ICAgICAgICAgYXBwbHlUYWJTd2l0Y2hBbmltKCk7CiAgICAgICAgICAgIC8vIE1lbW9yeSBwYWludCBm
aXJzdCDigJRiYWNrZ3JvdW5kIHNvZnQtc3luYyBrZWVwcyBBSEsgaW4gc3RlcCB3aXRob3V0IGRvdWJs
ZSByZWRyYXcKICAgICAgICAgICAgc29mdFJlcXVlc3RWaWV3KCk7CiAgICAgICAgICAgIHJldHVybjsK
ICAgICAgICB9CiAgICAgICAgLy8gTm8gY2FjaGUgeWV0OiBrZWVwIGN1cnJlbnQgcm93cyDigJQgTkVW
RVIgd2lwZSB0byBibGFuayB3aGl0ZQogICAgICAgIHdpbmRvdy5fX3dhaXRpbmdWaWV3ID0gdHJ1ZTsK
ICAgICAgICBzY2hlZHVsZURlbGF5ZWRTa2VsKCk7CiAgICAgICAgaWYgKCFhbGxDbGlwcy5sZW5ndGgp
CiAgICAgICAgICAgIHJlbmRlcigpOwogICAgICAgIHJlcXVlc3RWaWV3KCk7CiAgICAgICAgYXBwbHlU
YWJTd2l0Y2hBbmltKCk7CiAgICB9CgogICAgbW92ZVRhYkluayh0cnVlKTsKICAgIGJpbmRUYWJJbmtI
b3ZlcigpOwogICAgdHJ5IHsgbmV3IFJlc2l6ZU9ic2VydmVyKCgpID0+IG1vdmVUYWJJbmsodHJ1ZSkp
Lm9ic2VydmUoZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3RhYnMnKSk7IH0gY2F0Y2gge30KICAgIHdp
bmRvdy5hZGRFdmVudExpc3RlbmVyKCdyZXNpemUnLCAoKSA9PiBtb3ZlVGFiSW5rKHRydWUpKTsKCiAg
ICBmdW5jdGlvbiB1cGRhdGVNb3JlRm9vdGVyKHRvdGFsKSB7CiAgICAgICAgbGV0IG1vcmVFbCA9IGRv
Y3VtZW50LmdldEVsZW1lbnRCeUlkKCdsaXN0LW1vcmUnKTsKICAgICAgICBjb25zdCBsb2FkZWQgPSBh
bGxDbGlwcy5sZW5ndGg7CiAgICAgICAgaWYgKGxvYWRlZCA+PSB0b3RhbCkgewogICAgICAgICAgICBp
ZiAobW9yZUVsKSBtb3JlRWwucmVtb3ZlKCk7CiAgICAgICAgICAgIHJldHVybjsKICAgICAgICB9CiAg
ICAgICAgaWYgKCFtb3JlRWwpIHsKICAgICAgICAgICAgbW9yZUVsID0gZG9jdW1lbnQuY3JlYXRlRWxl
bWVudCgnZGl2Jyk7CiAgICAgICAgICAgIG1vcmVFbC5pZCA9ICdsaXN0LW1vcmUnOwogICAgICAgICAg
ICBtb3JlRWwuY2xhc3NOYW1lID0gJ2xpc3QtbW9yZSc7CiAgICAgICAgICAgIGxpc3RFbC5hcHBlbmRD
aGlsZChtb3JlRWwpOwogICAgICAgIH0KICAgICAgICBtb3JlRWwudGV4dENvbnRlbnQgPSAn57un57ut
5LiL5ruR5LuO56OB55uY5Yqg6L2977yIJyArIGxvYWRlZCArICcvJyArIHRvdGFsICsgJ++8iSc7CiAg
ICB9CgogICAgLyoqIFVwZGF0ZSBiYXIgLyBwaW4gYmFkZ2Ugd2l0aG91dCB0b3VjaGluZyB0aGUgbGlz
dCBET00gKi8KICAgIGZ1bmN0aW9uIHJlZnJlc2hMaXN0Q2hyb21lKCkgewogICAgICAgIGNvbnN0IHZp
c2libGUgPSB2aXNpYmxlTGlzdCgpOwogICAgICAgIGNvbnN0IGxvYWRlZCA9IGFsbENsaXBzLmxlbmd0
aDsKICAgICAgICBjb25zdCBzaG93bkNvdW50ID0gdmlzaWJsZS5sZW5ndGg7CiAgICAgICAgbGV0IHBp
bm5lZE4gPSBOdW1iZXIocGlubmVkVG90YWwpIHx8IDA7CiAgICAgICAgaWYgKHBpbm5lZE4gPCAxKSB7
CiAgICAgICAgICAgIGlmIChjdXJUYWIgPT09ICdwaW5uZWQnKQogICAgICAgICAgICAgICAgcGlubmVk
TiA9IE1hdGgubWF4KE51bWJlcihkaXNrVG90YWwpIHx8IDAsIGxvYWRlZCk7CiAgICAgICAgICAgIGVs
c2UKICAgICAgICAgICAgICAgIHBpbm5lZE4gPSBhbGxDbGlwcy5maWx0ZXIoYyA9PiBpc1Bpbm5lZChj
KSkubGVuZ3RoOwogICAgICAgIH0KICAgICAgICB1cGRhdGVQaW5Eb3QoKTsKICAgICAgICBsZXQgc2hv
d1RvdGFsID0gZGlza1RvdGFsID4gMCA/IGRpc2tUb3RhbCA6IChsb2FkZWQgfHwgMCk7CiAgICAgICAg
aWYgKGN1clRhYiA9PT0gJ3Bpbm5lZCcgJiYgcGlubmVkTiA+IHNob3dUb3RhbCkKICAgICAgICAgICAg
c2hvd1RvdGFsID0gcGlubmVkTjsKICAgICAgICBjb25zdCBxT24gPSBTdHJpbmcocXVlcnkgfHwgJycp
LnRyaW0oKS5sZW5ndGggPiAwOwogICAgICAgIGNvbnN0IGJhciA9IGRvY3VtZW50LmdldEVsZW1lbnRC
eUlkKCdiYXItdHh0Jyk7CiAgICAgICAgaWYgKGJhcikgewogICAgICAgICAgICBiYXIudGV4dENvbnRl
bnQgPSBxT24KICAgICAgICAgICAgICAgID8gKHNob3duQ291bnQgKyAnIOadoScpCiAgICAgICAgICAg
ICAgICA6IChzaG93VG90YWwgPiBsb2FkZWQgPyAoc2hvd25Db3VudCArICcgLyAnICsgc2hvd1RvdGFs
ICsgJyDmnaEnKSA6IChzaG93VG90YWwgKyAnIOadoScpKTsKICAgICAgICB9CiAgICAgICAgdXBkYXRl
TW9yZUZvb3RlcihkaXNrVG90YWwpOwogICAgICAgIHVwZGF0ZVRvcEJ0bigpOwogICAgfQoKICAgIC8q
KgogICAgICogTG9hZC1tb3JlOiBhcHBlbmQgb25seSBuZXcgRE9NIG5vZGVzLiBGdWxsIHJlbmRlcigp
IG51a2VzIGV2ZXJ5IC5pdG0gYW5kCiAgICAgKiByZXN0b3JlcyBzY3JvbGxUb3Ag4oCUIHRoYXQgaGl0
Y2ggaXMgd2hhdCBtYWtlcyBkcmFnZ2luZyB0aGUgc2Nyb2xsYmFyIGZlZWwgc3RpY2t5LgogICAgICov
CiAgICBmdW5jdGlvbiBhcHBlbmRSZW5kZXIocHJldkxlbikgewogICAgICAgIGNvbnN0IHZpc2libGUg
PSB2aXNpYmxlTGlzdCgpOwogICAgICAgIGlmICghdmlzaWJsZS5sZW5ndGgpIHsKICAgICAgICAgICAg
cmVuZGVyKCk7CiAgICAgICAgICAgIHJldHVybiBmYWxzZTsKICAgICAgICB9CiAgICAgICAgaWYgKHBy
ZXZMZW4gPiAwICYmIHByZXZMZW4gPCBhbGxDbGlwcy5sZW5ndGgpIHsKICAgICAgICAgICAgY29uc3Qg
c2VhbUdpZHMgPSBuZXcgU2V0KCk7CiAgICAgICAgICAgIGZvciAobGV0IGkgPSBNYXRoLm1heCgwLCBw
cmV2TGVuIC0gOCk7IGkgPCBNYXRoLm1pbihhbGxDbGlwcy5sZW5ndGgsIHByZXZMZW4gKyA4KTsgaSsr
KSB7CiAgICAgICAgICAgICAgICBjb25zdCBnID0gZmF2R3JvdXBPZihhbGxDbGlwc1tpXSk7CiAgICAg
ICAgICAgICAgICBpZiAoZykgc2VhbUdpZHMuYWRkKGcpOwogICAgICAgICAgICB9CiAgICAgICAgICAg
IGlmIChzZWFtR2lkcy5zaXplKSB7CiAgICAgICAgICAgICAgICBmb3IgKGNvbnN0IGcgb2Ygc2VhbUdp
ZHMpIHsKICAgICAgICAgICAgICAgICAgICBsZXQgYmVmb3JlID0gMCwgYWZ0ZXIgPSAwOwogICAgICAg
ICAgICAgICAgICAgIGZvciAobGV0IGkgPSAwOyBpIDwgYWxsQ2xpcHMubGVuZ3RoOyBpKyspIHsKICAg
ICAgICAgICAgICAgICAgICAgICAgaWYgKGZhdkdyb3VwT2YoYWxsQ2xpcHNbaV0pICE9PSBnKSBjb250
aW51ZTsKICAgICAgICAgICAgICAgICAgICAgICAgaWYgKGkgPCBwcmV2TGVuKSBiZWZvcmUrKzsKICAg
ICAgICAgICAgICAgICAgICAgICAgZWxzZSBhZnRlcisrOwogICAgICAgICAgICAgICAgICAgIH0KICAg
ICAgICAgICAgICAgICAgICBpZiAoYmVmb3JlID4gMCAmJiBhZnRlciA+IDApIHsKICAgICAgICAgICAg
ICAgICAgICAgICAgcmVuZGVyKCk7CiAgICAgICAgICAgICAgICAgICAgICAgIHJldHVybiBmYWxzZTsK
ICAgICAgICAgICAgICAgICAgICB9CiAgICAgICAgICAgICAgICB9CiAgICAgICAgICAgIH0KICAgICAg
ICB9CiAgICAgICAgY29uc3QgYmxvY2tzID0gYnVpbGRQaW5uZWRCbG9ja3ModmlzaWJsZSk7CiAgICAg
ICAgY29uc3QgZXhpc3RpbmcgPSBsaXN0RWwucXVlcnlTZWxlY3RvckFsbCgnLml0bScpLmxlbmd0aDsK
ICAgICAgICBpZiAoZXhpc3RpbmcgPCAxKSB7CiAgICAgICAgICAgIHJlbmRlcigpOwogICAgICAgICAg
ICByZXR1cm4gZmFsc2U7CiAgICAgICAgfQogICAgICAgIGlmIChibG9ja3MubGVuZ3RoIDw9IGV4aXN0
aW5nKSB7CiAgICAgICAgICAgIHJlZnJlc2hMaXN0Q2hyb21lKCk7CiAgICAgICAgICAgIHRyeSB7IG1h
cmtRdWV1ZVJhaWxzKCk7IH0gY2F0Y2ggKGUpIHt9CiAgICAgICAgICAgIHJldHVybiB0cnVlOwogICAg
ICAgIH0KICAgICAgICBjb25zdCBmcmFnID0gZG9jdW1lbnQuY3JlYXRlRG9jdW1lbnRGcmFnbWVudCgp
OwogICAgICAgIGxldCBudW0gPSAwOwogICAgICAgIGJsb2Nrcy5mb3JFYWNoKGIgPT4gewogICAgICAg
ICAgICBudW0gKz0gMTsKICAgICAgICAgICAgaWYgKG51bSA8PSBleGlzdGluZykgcmV0dXJuOwogICAg
ICAgICAgICBpZiAoYi5raW5kID09PSAnZ3JvdXAnICYmIGIuaXRlbXMubGVuZ3RoID4gMSkKICAgICAg
ICAgICAgICAgIGZyYWcuYXBwZW5kQ2hpbGQobWFrZUdyb3VwSXRlbShiLml0ZW1zLCBudW0pKTsKICAg
ICAgICAgICAgZWxzZQogICAgICAgICAgICAgICAgZnJhZy5hcHBlbmRDaGlsZChtYWtlSXRlbShiLml0
ZW1zWzBdLCBudW0pKTsKICAgICAgICB9KTsKICAgICAgICBjb25zdCBtb3JlRWwgPSBkb2N1bWVudC5n
ZXRFbGVtZW50QnlJZCgnbGlzdC1tb3JlJyk7CiAgICAgICAgaWYgKG1vcmVFbCkKICAgICAgICAgICAg
bGlzdEVsLmluc2VydEJlZm9yZShmcmFnLCBtb3JlRWwpOwogICAgICAgIGVsc2UKICAgICAgICAgICAg
bGlzdEVsLmFwcGVuZENoaWxkKGZyYWcpOwogICAgICAgIHRyeSB7IG1hcmtRdWV1ZVJhaWxzKCk7IH0g
Y2F0Y2ggKGUpIHt9CiAgICAgICAgcmVmcmVzaExpc3RDaHJvbWUoKTsKICAgICAgICByZXF1ZXN0QW5p
bWF0aW9uRnJhbWUoKCkgPT4gewogICAgICAgICAgICBpZiAoYWxsQ2xpcHMubGVuZ3RoIDwgZGlza1Rv
dGFsCiAgICAgICAgICAgICAgICAmJiBsaXN0RWwuc2Nyb2xsSGVpZ2h0IDw9IGxpc3RFbC5jbGllbnRI
ZWlnaHQgKyAyMCkKICAgICAgICAgICAgICAgIHJlcXVlc3RNb3JlKCk7CiAgICAgICAgICAgIHRyeSB7
IHNjaGVkdWxlRmlsZUdvbmVDaGVjaygpOyB9IGNhdGNoIHt9CiAgICAgICAgfSk7CiAgICAgICAgcmV0
dXJuIHRydWU7CiAgICB9CgogICAgZnVuY3Rpb24gYXBwbHlBcHBlbmRQYXlsb2FkKHBlbmRpbmcpIHsK
ICAgICAgICBpZiAoIXBlbmRpbmcgfHwgcGVuZGluZy5mcm9tTGVuID09IG51bGwpIHJldHVybjsKICAg
ICAgICBjb25zdCBmcm9tTGVuID0gTnVtYmVyKHBlbmRpbmcuZnJvbUxlbikgfHwgMDsKICAgICAgICBp
ZiAoZnJvbUxlbiA8IDAgfHwgYWxsQ2xpcHMubGVuZ3RoIDw9IGZyb21MZW4pIHsKICAgICAgICAgICAg
cmVmcmVzaExpc3RDaHJvbWUoKTsKICAgICAgICAgICAgcmV0dXJuOwogICAgICAgIH0KICAgICAgICBh
cHBlbmRSZW5kZXIoZnJvbUxlbik7CiAgICB9CgogICAgZnVuY3Rpb24gbmF2TGlzdCgpIHsKICAgICAg
ICBjb25zdCBibG9ja3MgPSBidWlsZFBpbm5lZEJsb2Nrcyh2aXNpYmxlTGlzdCgpKTsKICAgICAgICBj
b25zdCBvdXQgPSBbXTsKICAgICAgICBmb3IgKGNvbnN0IGIgb2YgYmxvY2tzKSB7CiAgICAgICAgICAg
IGlmICghYiB8fCAhYi5pdGVtcykgY29udGludWU7CiAgICAgICAgICAgIGZvciAoY29uc3QgYyBvZiBi
Lml0ZW1zKSBvdXQucHVzaChjKTsKICAgICAgICB9CiAgICAgICAgcmV0dXJuIG91dDsKICAgIH0KCiAg
ICBmdW5jdGlvbiBzZWxlY3RCeUluZGV4KGlkeCkgewogICAgICAgIGNvbnN0IHZpcyA9IG5hdkxpc3Qo
KTsKICAgICAgICBpZiAoIXZpcy5sZW5ndGgpIHJldHVybjsKICAgICAgICBpZHggPSBNYXRoLm1heCgw
LCBNYXRoLm1pbih2aXMubGVuZ3RoIC0gMSwgaWR4KSk7CiAgICAgICAgaWYgKGlkeCA+PSB2aXMubGVu
Z3RoIC0gMSAmJiBhbGxDbGlwcy5sZW5ndGggPCBkaXNrVG90YWwpCiAgICAgICAgICAgIHJlcXVlc3RN
b3JlKCk7CiAgICAgICAgc2VsZWN0ZWRJZCA9IHZpc1tNYXRoLm1pbihpZHgsIHZpcy5sZW5ndGggLSAx
KV0uaWQ7CiAgICAgICAgcmFuZ2VBbmNob3JJZCA9IHNlbGVjdGVkSWQ7CiAgICAgICAgcmFuZ2VBbmNo
b3JDbGlja2VkID0gZmFsc2U7CiAgICAgICAgaWYgKCtzZWxlY3RlZElkICE9PSArbGFzdFBhc3RlSWQp
CiAgICAgICAgICAgIGxvY2F0ZUFjdGl2ZSA9IGZhbHNlOwogICAgICAgIHVwZGF0ZUxvY2F0ZUJ0bigp
OwogICAgICAgIHN5bmNJdGVtSGlnaGxpZ2h0KCk7CiAgICAgICAgY29uc3QgZWwgPSBsaXN0RWwucXVl
cnlTZWxlY3RvcignLm1nLXJvd1tkYXRhLWlkPSInICsgc2VsZWN0ZWRJZCArICciXScpCiAgICAgICAg
ICAgIHx8IGxpc3RFbC5xdWVyeVNlbGVjdG9yKCcuaXRtW2RhdGEtaWQ9IicgKyBzZWxlY3RlZElkICsg
JyJdJyk7CiAgICAgICAgaWYgKGVsKSBlbC5zY3JvbGxJbnRvVmlldyh7IGJsb2NrOiAnbmVhcmVzdCcg
fSk7CiAgICB9CgogICAgZnVuY3Rpb24gc2VsZWN0ZWRJbmRleCgpIHsKICAgICAgICByZXR1cm4gbmF2
TGlzdCgpLmZpbmRJbmRleChjID0+IGMuaWQgPT0gc2VsZWN0ZWRJZCk7CiAgICB9CgogICAgZnVuY3Rp
b24gc3luY0l0ZW1IaWdobGlnaHQoKSB7CiAgICAgICAgZG9jdW1lbnQucXVlcnlTZWxlY3RvckFsbCgn
Lml0bScpLmZvckVhY2gobiA9PiB7CiAgICAgICAgICAgIGlmIChuLmNsYXNzTGlzdC5jb250YWlucygn
aXQtZ3JvdXAnKSkgewogICAgICAgICAgICAgICAgY29uc3Qgcm93cyA9IFsuLi5uLnF1ZXJ5U2VsZWN0
b3JBbGwoJy5tZy1yb3cnKV07CiAgICAgICAgICAgICAgICBjb25zdCBpZHMgPSByb3dzLm1hcChyID0+
ICtyLmRhdGFzZXQuaWQpOwogICAgICAgICAgICAgICAgY29uc3QgYW55U2VsID0gaWRzLmluY2x1ZGVz
KCtzZWxlY3RlZElkKSB8fCBpZHMuc29tZShpZCA9PiBtdWx0aUlkcy5pbmNsdWRlcyhpZCkpOwogICAg
ICAgICAgICAgICAgbi5jbGFzc0xpc3QudG9nZ2xlKCdzZWwnLCBhbnlTZWwpOwogICAgICAgICAgICAg
ICAgbi5jbGFzc0xpc3QudG9nZ2xlKCdtdWx0aScsIGlkcy5zb21lKGlkID0+IG11bHRpSWRzLmluY2x1
ZGVzKGlkKSkpOwogICAgICAgICAgICAgICAgcm93cy5mb3JFYWNoKHIgPT4gewogICAgICAgICAgICAg
ICAgICAgIGNvbnN0IGlkID0gK3IuZGF0YXNldC5pZDsKICAgICAgICAgICAgICAgICAgICBjb25zdCBp
bk11bHRpID0gbXVsdGlJZHMuaW5jbHVkZXMoaWQpOwogICAgICAgICAgICAgICAgICAgIHIuY2xhc3NM
aXN0LnRvZ2dsZSgnc2VsJywgaWQgPT0gc2VsZWN0ZWRJZCB8fCBpbk11bHRpKTsKICAgICAgICAgICAg
ICAgICAgICByLmNsYXNzTGlzdC50b2dnbGUoJ211bHRpJywgaW5NdWx0aSk7CiAgICAgICAgICAgICAg
ICB9KTsKICAgICAgICAgICAgICAgIHJldHVybjsKICAgICAgICAgICAgfQogICAgICAgICAgICBjb25z
dCBpZCA9ICtuLmRhdGFzZXQuaWQ7CiAgICAgICAgICAgIGNvbnN0IGluTXVsdGkgPSBtdWx0aUlkcy5p
bmNsdWRlcyhpZCk7CiAgICAgICAgICAgIG4uY2xhc3NMaXN0LnRvZ2dsZSgnc2VsJywgaWQgPT0gc2Vs
ZWN0ZWRJZCB8fCBpbk11bHRpKTsKICAgICAgICAgICAgbi5jbGFzc0xpc3QudG9nZ2xlKCdtdWx0aScs
IGluTXVsdGkpOwogICAgICAgIH0pOwogICAgfQogICAgZnVuY3Rpb24gdXBkYXRlTXVsdGlCYWRnZSgp
IHsKICAgICAgICBjb25zdCBiYXIgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbXVsdGktYmFyJyk7
CiAgICAgICAgY29uc3QgZWwgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbXVsdGktY250Jyk7CiAg
ICAgICAgaWYgKG11bHRpSWRzLmxlbmd0aCA+IDApIHsKICAgICAgICAgICAgaWYgKGVsKSBlbC50ZXh0
Q29udGVudCA9IFN0cmluZyhtdWx0aUlkcy5sZW5ndGgpOwogICAgICAgICAgICBpZiAoYmFyKSB7CiAg
ICAgICAgICAgICAgICBjb25zdCB3YXNPZmYgPSAhYmFyLmNsYXNzTGlzdC5jb250YWlucygnb24nKTsK
ICAgICAgICAgICAgICAgIGJhci5jbGFzc0xpc3QuYWRkKCdvbicpOwogICAgICAgICAgICAgICAgaWYg
KHdhc09mZikgcmVzZXRQYXN0ZVNlcERlZmF1bHQoKTsKICAgICAgICAgICAgfQogICAgICAgIH0gZWxz
ZSB7CiAgICAgICAgICAgIGlmIChiYXIpIGJhci5jbGFzc0xpc3QucmVtb3ZlKCdvbicpOwogICAgICAg
ICAgICBjbG9zZVNlcE1lbnUoKTsKICAgICAgICB9CiAgICAgICAgc3luY0l0ZW1IaWdobGlnaHQoKTsK
ICAgIH0KCiAgICBjb25zdCBTRVBfTkVXTElORV9UT0tFTiA9ICdb5o2i6KGMXSc7CiAgICAvLyDlm7rl
rprluLjnlKjliIbpmpTnrKbvvJvoh6rlrprkuYnkuI3ov5vliJfooagKICAgIGNvbnN0IFNFUF9MSVNU
ID0gWycgJywgU0VQX05FV0xJTkVfVE9LRU4sICcsJywgJywgJywgJ+OAgScsICd8JywgJ1siIiwiIl0n
LCAiKCcnLCcnKSJdOwogICAgbGV0IHBhc3RlU2VwVmFsdWUgPSAnICc7CgogICAgZnVuY3Rpb24gbm9y
bWFsaXplU2VwSW5wdXQocmF3KSB7CiAgICAgICAgbGV0IHMgPSBTdHJpbmcocmF3ID8/ICcnKTsKICAg
ICAgICBpZiAocyA9PT0gJycpIHJldHVybiAnICc7CiAgICAgICAgY29uc3QgdCA9IHMudHJpbSgpOwog
ICAgICAgIGlmICh0ID09PSBTRVBfTkVXTElORV9UT0tFTiB8fCB0ID09PSAn5o2i6KGMJyB8fCB0ID09
PSAnXFxuJyB8fCB0ID09PSAnXG4nIHx8IHQgPT09ICdcclxuJykKICAgICAgICAgICAgcmV0dXJuIFNF
UF9ORVdMSU5FX1RPS0VOOwogICAgICAgIGlmICh0ID09PSAnXFx0JyB8fCB0ID09PSAnXHQnKSByZXR1
cm4gJ1x0JzsKICAgICAgICByZXR1cm4gczsKICAgIH0KICAgIGZ1bmN0aW9uIHNlcFRvQWN0dWFsKHJh
dykgewogICAgICAgIGNvbnN0IHMgPSBub3JtYWxpemVTZXBJbnB1dChyYXcpOwogICAgICAgIHJldHVy
biBzID09PSBTRVBfTkVXTElORV9UT0tFTiA/ICdcbicgOiBzOwogICAgfQogICAgZnVuY3Rpb24gc2Vw
VG9CcmlkZ2UocmF3KSB7CiAgICAgICAgY29uc3QgcyA9IG5vcm1hbGl6ZVNlcElucHV0KHJhdyk7CiAg
ICAgICAgaWYgKHMgPT09IFNFUF9ORVdMSU5FX1RPS0VOIHx8IHMgPT09ICdcbicgfHwgcyA9PT0gJ1xy
XG4nKSByZXR1cm4gU0VQX05FV0xJTkVfVE9LRU47CiAgICAgICAgaWYgKHMgPT09ICdcdCcpIHJldHVy
biAnW+WItuihqOespl0nOwogICAgICAgIHJldHVybiBzOwogICAgfQogICAgZnVuY3Rpb24gc2VwRGlz
cGxheVN5bWJvbChyYXcpIHsKICAgICAgICBjb25zdCBzID0gbm9ybWFsaXplU2VwSW5wdXQocmF3KTsK
ICAgICAgICBpZiAocyA9PT0gJyAnKSByZXR1cm4gJ+KQoyc7CiAgICAgICAgaWYgKHMgPT09IFNFUF9O
RVdMSU5FX1RPS0VOIHx8IHMgPT09ICdcbicgfHwgcyA9PT0gJ1xyXG4nKSByZXR1cm4gJ+KGtSc7CiAg
ICAgICAgaWYgKHMgPT09ICdcdCcpIHJldHVybiAn4oelJzsKICAgICAgICBpZiAocyA9PT0gJywnKSBy
ZXR1cm4gJywnOwogICAgICAgIGlmIChzID09PSAnLCAnKSByZXR1cm4gJyzikKMnOwogICAgICAgIGlm
IChzID09PSAn44CBJykgcmV0dXJuICfjgIEnOwogICAgICAgIGlmIChzID09PSAnfCcpIHJldHVybiAn
fCc7CiAgICAgICAgaWYgKHMgPT09ICdbIiIsIiJdJykgcmV0dXJuICdbIiIsIiJdJzsKICAgICAgICBp
ZiAocyA9PT0gIignJywnJykiKSByZXR1cm4gIignJywnJykiOwogICAgICAgIHJldHVybiBzLnJlcGxh
Y2UoL1xyXG4vZywgJ+KGtScpLnJlcGxhY2UoL1xuL2csICfihrUnKS5yZXBsYWNlKC9cdC9nLCAn4oel
JykucmVwbGFjZSgvXHIvZywgJycpOwogICAgfQogICAgZnVuY3Rpb24gc2VwRGlzcGxheU5hbWUocmF3
KSB7CiAgICAgICAgY29uc3QgcyA9IG5vcm1hbGl6ZVNlcElucHV0KHJhdyk7CiAgICAgICAgaWYgKHMg
PT09ICcgJykgcmV0dXJuICfnqbrmoLwnOwogICAgICAgIGlmIChzID09PSBTRVBfTkVXTElORV9UT0tF
TiB8fCBzID09PSAnXG4nIHx8IHMgPT09ICdcclxuJykgcmV0dXJuICfmjaLooYwnOwogICAgICAgIGlm
IChzID09PSAnXHQnKSByZXR1cm4gJ+WItuihqOespic7CiAgICAgICAgaWYgKHMgPT09ICcsJykgcmV0
dXJuICfpgJflj7cnOwogICAgICAgIGlmIChzID09PSAnLCAnKSByZXR1cm4gJ+mAl+WPt+epuuagvCc7
CiAgICAgICAgaWYgKHMgPT09ICfjgIEnKSByZXR1cm4gJ+mhv+WPtyc7CiAgICAgICAgaWYgKHMgPT09
ICd8JykgcmV0dXJuICfnq5bnur8nOwogICAgICAgIGlmIChzID09PSAnWyIiLCIiXScpIHJldHVybiAn
5YiX6KGoMSc7CiAgICAgICAgaWYgKHMgPT09ICIoJycsJycpIikgcmV0dXJuICfliJfooagyJzsKICAg
ICAgICByZXR1cm4gJyc7CiAgICB9CiAgICBmdW5jdGlvbiBmaWxsU2VwTWVudUl0ZW0oYnRuLCB2KSB7
CiAgICAgICAgYnRuLmlubmVySFRNTCA9ICcnOwogICAgICAgIGNvbnN0IHN5bSA9IGRvY3VtZW50LmNy
ZWF0ZUVsZW1lbnQoJ3NwYW4nKTsKICAgICAgICBzeW0uY2xhc3NOYW1lID0gJ3Bhc3RlLXNlcC1zeW0n
ICsgKHNlcERpc3BsYXlOYW1lKHYpID8gJycgOiAnIG9ubHknKTsKICAgICAgICBzeW0udGV4dENvbnRl
bnQgPSBzZXBEaXNwbGF5U3ltYm9sKHYpOwogICAgICAgIGJ0bi5hcHBlbmRDaGlsZChzeW0pOwogICAg
ICAgIGNvbnN0IG5hbWUgPSBzZXBEaXNwbGF5TmFtZSh2KTsKICAgICAgICBpZiAobmFtZSkgewogICAg
ICAgICAgICBjb25zdCBsYWIgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdzcGFuJyk7CiAgICAgICAg
ICAgIGxhYi5jbGFzc05hbWUgPSAncGFzdGUtc2VwLW5hbWUnOwogICAgICAgICAgICBsYWIudGV4dENv
bnRlbnQgPSBuYW1lOwogICAgICAgICAgICBidG4uYXBwZW5kQ2hpbGQobGFiKTsKICAgICAgICB9CiAg
ICB9CiAgICBmdW5jdGlvbiB1cGRhdGVTZXBMYWJlbCgpIHsKICAgICAgICBjb25zdCBsYWIgPSBkb2N1
bWVudC5nZXRFbGVtZW50QnlJZCgncGFzdGUtc2VwLWxhYmVsJyk7CiAgICAgICAgaWYgKGxhYikgbGFi
LnRleHRDb250ZW50ID0gc2VwRGlzcGxheVN5bWJvbChwYXN0ZVNlcFZhbHVlKTsKICAgIH0KICAgIGZ1
bmN0aW9uIGFwcGx5U2VwYXJhdG9yKHJhdywgb3B0cyA9IHt9KSB7CiAgICAgICAgY29uc3QgZG9QYXN0
ZSA9IG9wdHMucGFzdGUgIT0gbnVsbCA/IG9wdHMucGFzdGUgOiBtdWx0aUlkcy5sZW5ndGggPiAwOwog
ICAgICAgIHBhc3RlU2VwVmFsdWUgPSBub3JtYWxpemVTZXBJbnB1dChyYXcpOwogICAgICAgIHVwZGF0
ZVNlcExhYmVsKCk7CiAgICAgICAgY2xvc2VTZXBNZW51KCk7CiAgICAgICAgaWYgKGRvUGFzdGUpIHBh
c3RlTXVsdGlTZWxlY3Rpb24oKTsKICAgIH0KICAgIGZ1bmN0aW9uIGNsb3NlU2VwTWVudSgpIHsKICAg
ICAgICBjb25zdCBtZW51ID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3Bhc3RlLXNlcC1tZW51Jyk7
CiAgICAgICAgY29uc3QgYnRuID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3Bhc3RlLXNlcC1idG4n
KTsKICAgICAgICBpZiAobWVudSkgbWVudS5jbGFzc0xpc3QucmVtb3ZlKCdvbicpOwogICAgICAgIGlm
IChidG4pIGJ0bi5jbGFzc0xpc3QucmVtb3ZlKCdvcGVuJyk7CiAgICB9CiAgICBmdW5jdGlvbiByZW5k
ZXJTZXBNZW51KCkgewogICAgICAgIGNvbnN0IG1lbnUgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgn
cGFzdGUtc2VwLW1lbnUnKTsKICAgICAgICBpZiAoIW1lbnUpIHJldHVybjsKICAgICAgICBtZW51Lmlu
bmVySFRNTCA9ICcnOwogICAgICAgIGZvciAoY29uc3QgdiBvZiBTRVBfTElTVCkgewogICAgICAgICAg
ICBjb25zdCBiID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnYnV0dG9uJyk7CiAgICAgICAgICAgIGIu
dHlwZSA9ICdidXR0b24nOwogICAgICAgICAgICBiLmNsYXNzTmFtZSA9ICdwYXN0ZS1zZXAtaXRlbScg
KyAodiA9PT0gcGFzdGVTZXBWYWx1ZSA/ICcgc2VsJyA6ICcnKTsKICAgICAgICAgICAgZmlsbFNlcE1l
bnVJdGVtKGIsIHYpOwogICAgICAgICAgICBiLm9uY2xpY2sgPSBlID0+IHsKICAgICAgICAgICAgICAg
IGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAgICAgICAgICAgICBhcHBseVNlcGFyYXRvcih2KTsKICAg
ICAgICAgICAgfTsKICAgICAgICAgICAgbWVudS5hcHBlbmRDaGlsZChiKTsKICAgICAgICB9CiAgICAg
ICAgY29uc3QgZm9vdCA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOwogICAgICAgIGZvb3Qu
Y2xhc3NOYW1lID0gJ3Bhc3RlLXNlcC1mb290JzsKICAgICAgICBjb25zdCBpbnAgPSBkb2N1bWVudC5j
cmVhdGVFbGVtZW50KCdpbnB1dCcpOwogICAgICAgIGlucC5pZCA9ICdwYXN0ZS1zZXAtY3VzdG9tJzsK
ICAgICAgICBpbnAudHlwZSA9ICd0ZXh0JzsKICAgICAgICBpbnAuc2l6ZSA9IDE7CiAgICAgICAgaW5w
LnBsYWNlaG9sZGVyID0gJ+iHquWumuS5iSc7CiAgICAgICAgaW5wLmF1dG9jb21wbGV0ZSA9ICdvZmYn
OwogICAgICAgIGlucC5zcGVsbGNoZWNrID0gZmFsc2U7CiAgICAgICAgaW5wLnZhbHVlID0gU0VQX0xJ
U1QuaW5jbHVkZXMocGFzdGVTZXBWYWx1ZSkgPyAnJyA6IHBhc3RlU2VwVmFsdWU7CiAgICAgICAgaW5w
Lm9ubW91c2Vkb3duID0gZSA9PiB7CiAgICAgICAgICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAg
ICAgICAgIGUucHJldmVudERlZmF1bHQoKTsKICAgICAgICAgICAgdHJ5IHsgYWhrKCdmb2N1c1BhbmVs
Jyk7IH0gY2F0Y2gge30KICAgICAgICAgICAgaW5wLmZvY3VzKCk7CiAgICAgICAgfTsKICAgICAgICBp
bnAub25jbGljayA9IGUgPT4gZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICBpbnAub25mb2N1cyA9
ICgpID0+IHsgdHJ5IHsgYWhrKCdmb2N1c1BhbmVsJyk7IH0gY2F0Y2gge30gfTsKICAgICAgICBpbnAu
b25pbnB1dCA9IGUgPT4gZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICBpbnAub25rZXlkb3duID0g
ZSA9PiB7CiAgICAgICAgICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAgICAgICAgIGlmIChlLmtl
eSA9PT0gJ0VudGVyJykgewogICAgICAgICAgICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOwogICAgICAg
ICAgICAgICAgaWYgKGlucC52YWx1ZSAhPT0gJycpIGFwcGx5U2VwYXJhdG9yKGlucC52YWx1ZSk7CiAg
ICAgICAgICAgICAgICBlbHNlIGNsb3NlU2VwTWVudSgpOwogICAgICAgICAgICB9IGVsc2UgaWYgKGUu
a2V5ID09PSAnRXNjYXBlJykgewogICAgICAgICAgICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOwogICAg
ICAgICAgICAgICAgY2xvc2VTZXBNZW51KCk7CiAgICAgICAgICAgIH0KICAgICAgICB9OwogICAgICAg
IGZvb3QuYXBwZW5kQ2hpbGQoaW5wKTsKICAgICAgICBtZW51LmFwcGVuZENoaWxkKGZvb3QpOwogICAg
fQogICAgZnVuY3Rpb24gcmVzZXRQYXN0ZVNlcERlZmF1bHQoKSB7CiAgICAgICAgcGFzdGVTZXBWYWx1
ZSA9ICcgJzsKICAgICAgICB1cGRhdGVTZXBMYWJlbCgpOwogICAgICAgIGNsb3NlU2VwTWVudSgpOwog
ICAgfQogICAgZnVuY3Rpb24gcGFzdGVNYW55V2l0aFNlcChpZHMpIHsKICAgICAgICBhaGsoJ3Bhc3Rl
TWFueScsIGlkcy5qb2luKCcsJyksIHNlcFRvQnJpZGdlKHBhc3RlU2VwVmFsdWUpKTsKICAgIH0KICAg
IGZ1bmN0aW9uIHBhc3RlTXVsdGlTZWxlY3Rpb24oKSB7CiAgICAgICAgaWYgKCFtdWx0aUlkcy5sZW5n
dGgpIHJldHVybjsKICAgICAgICBjb25zdCBpZHMgPSBtdWx0aUlkcy5zbGljZSgpOwogICAgICAgIGNs
ZWFyTXVsdGkoKTsKICAgICAgICBpZiAoaWRzLnNvbWUoaWQgPT4gewogICAgICAgICAgICBjb25zdCBp
dCA9IGFsbENsaXBzLmZpbmQoeCA9PiAreC5pZCA9PT0gK2lkKTsKICAgICAgICAgICAgcmV0dXJuIGl0
ICYmIG5vcm1UeXBlKGl0LnR5cGUpID09PSAncmVjZW50JzsKICAgICAgICB9KSkgewogICAgICAgICAg
ICBjb25zdCBmaXJzdCA9IGFsbENsaXBzLmZpbmQoeCA9PiAreC5pZCA9PT0gK2lkc1swXSk7CiAgICAg
ICAgICAgIGlmIChmaXJzdCkgYWN0aXZhdGVDbGlwSXRlbShmaXJzdCk7CiAgICAgICAgICAgIHJldHVy
bjsKICAgICAgICB9CiAgICAgICAgbWFya1Bhc3RlZExvY2FsKGlkcyk7CiAgICAgICAgcGFzdGVNYW55
V2l0aFNlcChpZHMpOwogICAgfQogICAgZnVuY3Rpb24gaW5pdFNlcFVpKCkgewogICAgICAgIHVwZGF0
ZVNlcExhYmVsKCk7CiAgICAgICAgY29uc3QgYnRuID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3Bh
c3RlLXNlcC1idG4nKTsKICAgICAgICBpZiAoYnRuKSB7CiAgICAgICAgICAgIGJ0bi5hZGRFdmVudExp
c3RlbmVyKCdjbGljaycsIGUgPT4gewogICAgICAgICAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsK
ICAgICAgICAgICAgICAgIGNvbnN0IG1lbnUgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgncGFzdGUt
c2VwLW1lbnUnKTsKICAgICAgICAgICAgICAgIGNvbnN0IG9wZW4gPSBtZW51ICYmIG1lbnUuY2xhc3NM
aXN0LmNvbnRhaW5zKCdvbicpOwogICAgICAgICAgICAgICAgaWYgKG9wZW4pIHsKICAgICAgICAgICAg
ICAgICAgICBjb25zdCBpbnAgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgncGFzdGUtc2VwLWN1c3Rv
bScpOwogICAgICAgICAgICAgICAgICAgIGlmIChpbnAgJiYgaW5wLnZhbHVlICE9PSAnJykgYXBwbHlT
ZXBhcmF0b3IoaW5wLnZhbHVlLCB7IHBhc3RlOiBtdWx0aUlkcy5sZW5ndGggPiAwIH0pOwogICAgICAg
ICAgICAgICAgICAgIGVsc2UgY2xvc2VTZXBNZW51KCk7CiAgICAgICAgICAgICAgICAgICAgcmV0dXJu
OwogICAgICAgICAgICAgICAgfQogICAgICAgICAgICAgICAgcmVuZGVyU2VwTWVudSgpOwogICAgICAg
ICAgICAgICAgbWVudS5jbGFzc0xpc3QuYWRkKCdvbicpOwogICAgICAgICAgICAgICAgYnRuLmNsYXNz
TGlzdC5hZGQoJ29wZW4nKTsKICAgICAgICAgICAgfSk7CiAgICAgICAgfQogICAgICAgIGRvY3VtZW50
LmFkZEV2ZW50TGlzdGVuZXIoJ21vdXNlZG93bicsIGUgPT4gewogICAgICAgICAgICBpZiAoZS50YXJn
ZXQuY2xvc2VzdCgnI3Bhc3RlLXNlcC13cmFwJykpIHJldHVybjsKICAgICAgICAgICAgY29uc3QgbWVu
dSA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdwYXN0ZS1zZXAtbWVudScpOwogICAgICAgICAgICBp
ZiAoIW1lbnUgfHwgIW1lbnUuY2xhc3NMaXN0LmNvbnRhaW5zKCdvbicpKSByZXR1cm47CiAgICAgICAg
ICAgIGNvbnN0IGlucCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdwYXN0ZS1zZXAtY3VzdG9tJyk7
CiAgICAgICAgICAgIGlmIChpbnAgJiYgaW5wLnZhbHVlICE9PSAnJykgewogICAgICAgICAgICAgICAg
YXBwbHlTZXBhcmF0b3IoaW5wLnZhbHVlKTsKICAgICAgICAgICAgICAgIHJldHVybjsKICAgICAgICAg
ICAgfQogICAgICAgICAgICBjbG9zZVNlcE1lbnUoKTsKICAgICAgICB9LCB0cnVlKTsKICAgIH0KCiAg
ICBmdW5jdGlvbiBjbGVhck11bHRpKHJlc3RvcmVUb0FuY2hvcikgewogICAgICAgIGNvbnN0IGJhY2tJ
ZCA9ICtyYW5nZUFuY2hvcklkIHx8IDA7CiAgICAgICAgbXVsdGlJZHMgPSBbXTsKICAgICAgICBpZiAo
cmVzdG9yZVRvQW5jaG9yICYmIGJhY2tJZCkKICAgICAgICAgICAgc2VsZWN0ZWRJZCA9IGJhY2tJZDsK
ICAgICAgICByYW5nZUFuY2hvcklkID0gc2VsZWN0ZWRJZCB8fCAwOwogICAgICAgIHJhbmdlQW5jaG9y
Q2xpY2tlZCA9IGZhbHNlOwogICAgICAgIHVwZGF0ZU11bHRpQmFkZ2UoKTsKICAgICAgICBpZiAocmVz
dG9yZVRvQW5jaG9yICYmIHNlbGVjdGVkSWQpIHsKICAgICAgICAgICAgY29uc3QgZWwgPSBsaXN0RWwu
cXVlcnlTZWxlY3RvcignLm1nLXJvd1tkYXRhLWlkPSInICsgc2VsZWN0ZWRJZCArICciXScpCiAgICAg
ICAgICAgICAgICB8fCBsaXN0RWwucXVlcnlTZWxlY3RvcignLml0bVtkYXRhLWlkPSInICsgc2VsZWN0
ZWRJZCArICciXScpOwogICAgICAgICAgICBpZiAoZWwpIGVsLnNjcm9sbEludG9WaWV3KHsgYmxvY2s6
ICduZWFyZXN0JyB9KTsKICAgICAgICB9CiAgICB9CgoKICAgIC8qIHNoaWZ0L2N0cmwgbXVsdGktc2Vs
ZWN0OgogICAgICogU2hpZnTvvJrmnInpgInljLrml7bku6XjgIzmnIDkuIov5pyA5LiL44CN5Li66ZSa
77yM5LiN6Lef6byg5qCH5LiK5qyh54K55Ye76LWwCiAgICAgKiAgIC0g54K55Zyo6YCJ5Yy65LiL5pa5
IOKGkiDku47kuIrpgInliLDlvZPliY0KICAgICAqICAgLSDngrnlnKjpgInljLrkuIrmlrkg4oaSIOS7
juW9k+WJjeWIsOS4i+mAiQogICAgICogICAtIOeCueWcqOmAieWMuui3qOW6puWGhSDihpIg5aGr5ruh
5pyA5LiK5Yiw5pyA5LiL77yI5ZCr6Z2e6L+e57ut56m65rSe77yJCiAgICAgKiBDdHJs77ya6aaW5qyh
54K55Lu75oSP6aG577yI5ZCr6buY6K6k6auY5Lqu77yJ6L+b5YWl5aSa6YCJ5bm26YCJ5Lit77yb5YaN
54K55bey6YCJ6aG55Y+W5raI44CB5pyq6YCJ6aG55Yqg5YWlCiAgICAgKi8KICAgIGxldCByYW5nZUFu
Y2hvcklkID0gMDsKICAgIGxldCByYW5nZUFuY2hvckNsaWNrZWQgPSBmYWxzZTsKICAgIGZ1bmN0aW9u
IHNlbGVjdGVkSW5kaWNlc0luTGlzdChsaXN0KSB7CiAgICAgICAgY29uc3Qgc2V0ID0gbmV3IFNldCgo
bXVsdGlJZHMgfHwgW10pLm1hcChOdW1iZXIpLmZpbHRlcihCb29sZWFuKSk7CiAgICAgICAgaWYgKCtz
ZWxlY3RlZElkKSBzZXQuYWRkKCtzZWxlY3RlZElkKTsKICAgICAgICBjb25zdCBpZHhzID0gW107CiAg
ICAgICAgbGlzdC5mb3JFYWNoKChjLCBpKSA9PiB7CiAgICAgICAgICAgIGlmIChzZXQuaGFzKCtjLmlk
KSkgaWR4cy5wdXNoKGkpOwogICAgICAgIH0pOwogICAgICAgIHJldHVybiBpZHhzOwogICAgfQogICAg
ZnVuY3Rpb24gc2VsZWN0UmFuZ2VUbyhpZCkgewogICAgICAgIGlkID0gK2lkOwogICAgICAgIGNvbnN0
IGxpc3QgPSAodHlwZW9mIG5hdkxpc3QgPT09ICdmdW5jdGlvbicgPyBuYXZMaXN0KCkgOiB2aXNpYmxl
TGlzdCgpKTsKICAgICAgICBjb25zdCBiID0gbGlzdC5maW5kSW5kZXgoYyA9PiArYy5pZCA9PT0gaWQp
OwogICAgICAgIGlmIChiIDwgMCkgcmV0dXJuOwogICAgICAgIGNvbnN0IGlkeHMgPSBzZWxlY3RlZElu
ZGljZXNJbkxpc3QobGlzdCk7CiAgICAgICAgbGV0IGxvLCBoaTsKICAgICAgICBpZiAoIWlkeHMubGVu
Z3RoKSB7CiAgICAgICAgICAgIGxvID0gaGkgPSBiOwogICAgICAgIH0gZWxzZSB7CiAgICAgICAgICAg
IGNvbnN0IHRvcCA9IE1hdGgubWluKC4uLmlkeHMpOwogICAgICAgICAgICBjb25zdCBib3QgPSBNYXRo
Lm1heCguLi5pZHhzKTsKICAgICAgICAgICAgaWYgKGIgPiBib3QpIHsKICAgICAgICAgICAgICAgIC8v
IOmAieWMuuS4i+aWue+8muacgOS4iiDihpIg5b2T5YmNCiAgICAgICAgICAgICAgICBsbyA9IHRvcDsK
ICAgICAgICAgICAgICAgIGhpID0gYjsKICAgICAgICAgICAgfSBlbHNlIGlmIChiIDwgdG9wKSB7CiAg
ICAgICAgICAgICAgICAvLyDpgInljLrkuIrmlrnvvJrlvZPliY0g4oaSIOacgOS4iwogICAgICAgICAg
ICAgICAgbG8gPSBiOwogICAgICAgICAgICAgICAgaGkgPSBib3Q7CiAgICAgICAgICAgIH0gZWxzZSB7
CiAgICAgICAgICAgICAgICAvLyDlnKjot6jluqblhoXvvIjlkKvpnZ7ov57nu63nqbrmtJ7vvInvvJrm
lbTmrrXmnIDkuIrihpLmnIDkuIsKICAgICAgICAgICAgICAgIGxvID0gdG9wOwogICAgICAgICAgICAg
ICAgaGkgPSBib3Q7CiAgICAgICAgICAgIH0KICAgICAgICB9CiAgICAgICAgbXVsdGlJZHMgPSBbXTsK
ICAgICAgICBmb3IgKGxldCBpID0gbG87IGkgPD0gaGk7IGkrKykKICAgICAgICAgICAgbXVsdGlJZHMu
cHVzaCgrbGlzdFtpXS5pZCk7CiAgICAgICAgc2VsZWN0ZWRJZCA9IGlkOwogICAgICAgIC8vIOS4jeWG
jeaKium8oOagh+eCueWHu+W9k+aIkOS4i+S4gOasoSBTaGlmdCDplJrngrkKICAgICAgICByYW5nZUFu
Y2hvcklkID0gK2xpc3RbbG9dLmlkOwogICAgICAgIHJhbmdlQW5jaG9yQ2xpY2tlZCA9IHRydWU7CiAg
ICAgICAgdXBkYXRlTXVsdGlCYWRnZSgpOwogICAgICAgIGNvbnN0IGVsID0gbGlzdEVsLnF1ZXJ5U2Vs
ZWN0b3IoJy5tZy1yb3dbZGF0YS1pZD0iJyArIHNlbGVjdGVkSWQgKyAnIl0nKQogICAgICAgICAgICB8
fCBsaXN0RWwucXVlcnlTZWxlY3RvcignLml0bVtkYXRhLWlkPSInICsgc2VsZWN0ZWRJZCArICciXScp
OwogICAgICAgIGlmIChlbCkgZWwuc2Nyb2xsSW50b1ZpZXcoeyBibG9jazogJ25lYXJlc3QnIH0pOwog
ICAgfQogICAgZnVuY3Rpb24gaGFuZGxlSXRlbUNsaWNrKGUsIGMpIHsKICAgICAgICBpZiAoZS5zaGlm
dEtleSkgewogICAgICAgICAgICBlLnByZXZlbnREZWZhdWx0KCk7IGUuc3RvcFByb3BhZ2F0aW9uKCk7
CiAgICAgICAgICAgIHNlbGVjdFJhbmdlVG8oYy5pZCk7CiAgICAgICAgICAgIHJldHVybiB0cnVlOwog
ICAgICAgIH0KICAgICAgICBpZiAoZS5jdHJsS2V5IHx8IGUubWV0YUtleSkgewogICAgICAgICAgICBl
LnByZXZlbnREZWZhdWx0KCk7IGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAgICAgICAgIHRvZ2dsZU11
bHRpKGMuaWQpOwogICAgICAgICAgICByZXR1cm4gdHJ1ZTsKICAgICAgICB9CiAgICAgICAgcmFuZ2VB
bmNob3JJZCA9IGMuaWQ7CiAgICAgICAgcmFuZ2VBbmNob3JDbGlja2VkID0gdHJ1ZTsKICAgICAgICBy
ZXR1cm4gZmFsc2U7CiAgICB9CiAgICBmdW5jdGlvbiB0b2dnbGVNdWx0aShpZCkgewogICAgICAgIGlk
ID0gK2lkOwogICAgICAgIC8vIOmmluasoSBDdHJs77ya5Y+q6YCJ5Lit5b2T5YmN54K55Ye76aG577yI
5ZCr6buY6K6k6auY5Lqu6aG5IOKGkiDov5vlhaXlpJrpgInvvIzkuI3opoHlj5bmtojvvIkKICAgICAg
ICBpZiAoIW11bHRpSWRzLmxlbmd0aCkgewogICAgICAgICAgICBtdWx0aUlkcyA9IFtpZF07CiAgICAg
ICAgICAgIHNlbGVjdGVkSWQgPSBpZDsKICAgICAgICAgICAgdXBkYXRlTXVsdGlCYWRnZSgpOwogICAg
ICAgICAgICByZXR1cm47CiAgICAgICAgfQogICAgICAgIGNvbnN0IGkgPSBtdWx0aUlkcy5pbmRleE9m
KGlkKTsKICAgICAgICBpZiAoaSA+PSAwKSB7CiAgICAgICAgICAgIG11bHRpSWRzLnNwbGljZShpLCAx
KTsKICAgICAgICAgICAgaWYgKCtzZWxlY3RlZElkID09PSBpZCkKICAgICAgICAgICAgICAgIHNlbGVj
dGVkSWQgPSBtdWx0aUlkcy5sZW5ndGggPyBtdWx0aUlkc1ttdWx0aUlkcy5sZW5ndGggLSAxXSA6IDA7
CiAgICAgICAgfSBlbHNlIHsKICAgICAgICAgICAgbXVsdGlJZHMucHVzaChpZCk7CiAgICAgICAgICAg
IHNlbGVjdGVkSWQgPSBpZDsKICAgICAgICB9CiAgICAgICAgdXBkYXRlTXVsdGlCYWRnZSgpOwogICAg
fQogICAgZnVuY3Rpb24gc2hvd1NyY1RpcChhbmNob3IsIHRleHQpIHsKICAgICAgICB0ZXh0ID0gU3Ry
aW5nKHRleHQgfHwgJycpLnRyaW0oKTsKICAgICAgICBpZiAoIXRleHQpIHJldHVybjsKICAgICAgICBs
ZXQgdGlwID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NyYy10aXAnKTsKICAgICAgICBpZiAoIXRp
cCkgewogICAgICAgICAgICB0aXAgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsKICAgICAg
ICAgICAgdGlwLmlkID0gJ3NyYy10aXAnOwogICAgICAgICAgICBkb2N1bWVudC5ib2R5LmFwcGVuZENo
aWxkKHRpcCk7CiAgICAgICAgfQogICAgICAgIHRpcC50ZXh0Q29udGVudCA9IHRleHQ7CiAgICAgICAg
dGlwLmNsYXNzTGlzdC5hZGQoJ3Nob3cnKTsKICAgICAgICBjb25zdCByID0gYW5jaG9yLmdldEJvdW5k
aW5nQ2xpZW50UmVjdCgpOwogICAgICAgIGNvbnN0IHR3ID0gdGlwLm9mZnNldFdpZHRoIHx8IDE2MDsK
ICAgICAgICBjb25zdCB0aCA9IHRpcC5vZmZzZXRIZWlnaHQgfHwgMjg7CiAgICAgICAgbGV0IGxlZnQg
PSByLnJpZ2h0IC0gdHc7CiAgICAgICAgbGV0IHRvcCA9IHIudG9wIC0gdGggLSA4OwogICAgICAgIGlm
IChsZWZ0IDwgOCkgbGVmdCA9IDg7CiAgICAgICAgaWYgKGxlZnQgKyB0dyA+IHdpbmRvdy5pbm5lcldp
ZHRoIC0gOCkgbGVmdCA9IHdpbmRvdy5pbm5lcldpZHRoIC0gdHcgLSA4OwogICAgICAgIGlmICh0b3Ag
PCA4KSB0b3AgPSByLmJvdHRvbSArIDg7CiAgICAgICAgdGlwLnN0eWxlLmxlZnQgPSBsZWZ0ICsgJ3B4
JzsKICAgICAgICB0aXAuc3R5bGUudG9wID0gdG9wICsgJ3B4JzsKICAgICAgICBjbGVhclRpbWVvdXQo
dGlwLl9oaWRlVCk7CiAgICAgICAgdGlwLl9oaWRlVCA9IHNldFRpbWVvdXQoKCkgPT4gdGlwLmNsYXNz
TGlzdC5yZW1vdmUoJ3Nob3cnKSwgMjIwMCk7CiAgICB9CiAgICAvKiBpbWctaG92ZXItcHJldmlldy12
OCAqLwogICAgbGV0IF9faW1nSG92ZXJUaW1lciA9IDAsIF9faW1nSG92ZXJIaWRlVGltZXIgPSAwLCBf
X2ltZ0hvdmVyS2V5ID0gJyc7CiAgICBmdW5jdGlvbiBfX2ltZ0hvdmVyRW5zdXJlKCkgewogICAgICAg
IGxldCBib3ggPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnaW1nLWhvdmVyLXNpZGUnKTsKICAgICAg
ICBpZiAoIWJveCkgewogICAgICAgICAgICBib3ggPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYn
KTsgYm94LmlkID0gJ2ltZy1ob3Zlci1zaWRlJzsKICAgICAgICAgICAgY29uc3QgZnJhbWUgPSBkb2N1
bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsgZnJhbWUuY2xhc3NOYW1lID0gJ2locC1mcmFtZSc7CiAg
ICAgICAgICAgIGNvbnN0IGltID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnaW1nJyk7IGltLmFsdCA9
ICcnOwogICAgICAgICAgICBmcmFtZS5hcHBlbmRDaGlsZChpbSk7IGJveC5hcHBlbmRDaGlsZChmcmFt
ZSk7IGRvY3VtZW50LmJvZHkuYXBwZW5kQ2hpbGQoYm94KTsKICAgICAgICB9CiAgICAgICAgbGV0IHN0
ID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2ltZy1ob3Zlci1zaWRlLWNzcycpOwogICAgICAgIGlm
ICghc3QpIHsgc3QgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdzdHlsZScpOyBzdC5pZCA9ICdpbWct
aG92ZXItc2lkZS1jc3MnOyBkb2N1bWVudC5oZWFkLmFwcGVuZENoaWxkKHN0KTsgfQogICAgICAgIHN0
LnRleHRDb250ZW50ID0gIiNpbWctaG92ZXItc2lkZXtwb3NpdGlvbjpmaXhlZDt6LWluZGV4OjEwMDAw
MDtyaWdodDo2cHg7dG9wOjUwJTt0cmFuc2Zvcm06dHJhbnNsYXRlWSgtNTAlKTtwb2ludGVyLWV2ZW50
czpub25lO29wYWNpdHk6MDt2aXNpYmlsaXR5OmhpZGRlbjttYXgtd2lkdGg6bWluKDYyMHB4LDkydncp
O21heC1oZWlnaHQ6bWluKDkydmgsOTIwcHgpfSNpbWctaG92ZXItc2lkZS5zaG93e29wYWNpdHk6MTt2
aXNpYmlsaXR5OnZpc2libGV9I2ltZy1ob3Zlci1zaWRlIC5paHAtZnJhbWV7cGFkZGluZzozcHg7YmFj
a2dyb3VuZDojZmZmO2JvcmRlcjoxcHggc29saWQgI0M1Q0REQztib3JkZXItcmFkaXVzOjJweDtib3gt
c2hhZG93OjAgNnB4IDE4cHggcmdiYSg0NCw0Niw1NCwuMTIpfSNpbWctaG92ZXItc2lkZSBpbWd7ZGlz
cGxheTpibG9jazttYXgtd2lkdGg6bWluKDYxMnB4LDkwdncpO21heC1oZWlnaHQ6bWluKDkwdmgsOTAw
cHgpO3dpZHRoOmF1dG87aGVpZ2h0OmF1dG87b2JqZWN0LWZpdDpjb250YWluO2JhY2tncm91bmQ6I2Zm
Zn0iOwogICAgICAgIHJldHVybiBib3g7CiAgICB9CiAgICB3aW5kb3cuX19pbWdIb3ZlclNob3cgPSBm
dW5jdGlvbihmaWxlLCBpZCkgewogICAgICAgIGNvbnN0IGJhcmUgPSBTdHJpbmcoZmlsZSB8fCAnJyku
c3BsaXQoL1tcXFxcL10vKS5wb3AoKTsgaWYgKCFiYXJlKSByZXR1cm47CiAgICAgICAgY29uc3QgYm94
ID0gX19pbWdIb3ZlckVuc3VyZSgpOyBjb25zdCBpbWcgPSBib3gucXVlcnlTZWxlY3RvcignaW1nJyk7
IGlmICghaW1nKSByZXR1cm47CiAgICAgICAgYm94LmNsYXNzTGlzdC5hZGQoJ3Nob3cnKTsKICAgICAg
ICBpbWcub25lcnJvciA9ICgpID0+IHsKICAgICAgICAgICAgaW1nLm9uZXJyb3IgPSAoKSA9PiB7IGlt
Zy5vbmVycm9yID0gbnVsbDsgdHJ5IHsgY29uc3QgYyA9IHRodW1iQ2FjaGUgJiYgdGh1bWJDYWNoZS5n
ZXQoU3RyaW5nKGlkKSk7IGlmIChjKSBpbWcuc3JjID0gYzsgfSBjYXRjaCAoZSkge30gfTsKICAgICAg
ICAgICAgaW1nLnNyYyA9IFNUT1JFX0JBU0UgKyAndGhfJyArIGJhcmUucmVwbGFjZSgvXC5bXi5dKyQv
LCAnJykgKyAnLmpwZyc7CiAgICAgICAgfTsKICAgICAgICBpbWcub25sb2FkID0gKCkgPT4geyBpbWcu
b25lcnJvciA9IG51bGw7IH07CiAgICAgICAgaW1nLmRhdGFzZXQuYmFyZSA9IGJhcmU7IGltZy5zcmMg
PSBTVE9SRV9CQVNFICsgYmFyZTsKICAgIH07CiAgICB3aW5kb3cuX19pbWdIb3ZlckNsZWFyVWkgPSBm
dW5jdGlvbigpIHsKICAgICAgICBfX2ltZ0hvdmVyS2V5ID0gJyc7CiAgICAgICAgaWYgKF9faW1nSG92
ZXJUaW1lcikgeyBjbGVhclRpbWVvdXQoX19pbWdIb3ZlclRpbWVyKTsgX19pbWdIb3ZlclRpbWVyID0g
MDsgfQogICAgICAgIGlmIChfX2ltZ0hvdmVySGlkZVRpbWVyKSB7IGNsZWFyVGltZW91dChfX2ltZ0hv
dmVySGlkZVRpbWVyKTsgX19pbWdIb3ZlckhpZGVUaW1lciA9IDA7IH0KICAgICAgICBjb25zdCBib3gg
PSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnaW1nLWhvdmVyLXNpZGUnKTsgaWYgKGJveCkgYm94LmNs
YXNzTGlzdC5yZW1vdmUoJ3Nob3cnKTsKICAgICAgICBjb25zdCBpbWcgPSBib3ggJiYgYm94LnF1ZXJ5
U2VsZWN0b3IoJ2ltZycpOwogICAgICAgIGlmIChpbWcpIHsgaW1nLm9ubG9hZCA9IG51bGw7IGltZy5v
bmVycm9yID0gbnVsbDsgaW1nLnJlbW92ZUF0dHJpYnV0ZSgnc3JjJyk7IGRlbGV0ZSBpbWcuZGF0YXNl
dC5iYXJlOyB9CiAgICB9OwogICAgd2luZG93Ll9faW1nSG92ZXJIaWRlID0gZnVuY3Rpb24oKSB7IHdp
bmRvdy5fX2ltZ0hvdmVyQ2xlYXJVaSgpOyB9OwogICAgZnVuY3Rpb24gYmluZEltZ0hvdmVyUHJldmll
dyhlbCwgaWQsIGZpbGUpIHsKICAgICAgICBpZiAoIWVsKSByZXR1cm47CiAgICAgICAgY29uc3QgYmFy
ZSA9IFN0cmluZyhmaWxlIHx8ICcnKS5zcGxpdCgvW1xcXFwvXS8pLnBvcCgpOyBpZiAoIWJhcmUpIHJl
dHVybjsKICAgICAgICBjb25zdCBrZXkgPSBTdHJpbmcoaWQpICsgJ3wnICsgYmFyZTsKICAgICAgICBl
bC5zdHlsZS5jdXJzb3IgPSAnem9vbS1pbic7CiAgICAgICAgZWwuYWRkRXZlbnRMaXN0ZW5lcignbW91
c2VlbnRlcicsICgpID0+IHsKICAgICAgICAgICAgaWYgKF9faW1nSG92ZXJIaWRlVGltZXIpIHsgY2xl
YXJUaW1lb3V0KF9faW1nSG92ZXJIaWRlVGltZXIpOyBfX2ltZ0hvdmVySGlkZVRpbWVyID0gMDsgfQog
ICAgICAgICAgICBfX2ltZ0hvdmVyS2V5ID0ga2V5OwogICAgICAgICAgICBpZiAoX19pbWdIb3ZlclRp
bWVyKSBjbGVhclRpbWVvdXQoX19pbWdIb3ZlclRpbWVyKTsKICAgICAgICAgICAgX19pbWdIb3ZlclRp
bWVyID0gc2V0VGltZW91dCgoKSA9PiB7IGlmIChfX2ltZ0hvdmVyS2V5ID09PSBrZXkpIHRyeSB7IHdp
bmRvdy5fX2ltZ0hvdmVyU2hvdyhiYXJlLCBpZCk7IH0gY2F0Y2ggKGUpIHt9IH0sIDYwKTsKICAgICAg
ICB9KTsKICAgICAgICBlbC5hZGRFdmVudExpc3RlbmVyKCdtb3VzZWxlYXZlJywgKCkgPT4gewogICAg
ICAgICAgICBpZiAoX19pbWdIb3ZlclRpbWVyKSB7IGNsZWFyVGltZW91dChfX2ltZ0hvdmVyVGltZXIp
OyBfX2ltZ0hvdmVyVGltZXIgPSAwOyB9CiAgICAgICAgICAgIF9faW1nSG92ZXJIaWRlVGltZXIgPSBz
ZXRUaW1lb3V0KCgpID0+IHsgaWYgKCFfX2ltZ0hvdmVyS2V5IHx8IF9faW1nSG92ZXJLZXkgPT09IGtl
eSkgd2luZG93Ll9faW1nSG92ZXJIaWRlKCk7IH0sIDcwKTsKICAgICAgICB9KTsKICAgIH0KCiAgICBm
dW5jdGlvbiByZW5kZXIoKSB7CiAgICAgICAgaGlkZVBhdGhUaXAoKTsKCiAgICAgICAgY29uc3Qgdmlz
aWJsZSA9IHZpc2libGVMaXN0KCk7CiAgICAgICAgY29uc3QgbG9hZGVkID0gYWxsQ2xpcHMubGVuZ3Ro
OwogICAgICAgIGNvbnN0IHNob3duQ291bnQgPSB2aXNpYmxlLmxlbmd0aDsKICAgICAgICAvLyDmlLbo
l4/op5LmoIfvvJrmlLnkuLrnu7/ngrnvvIjmnInmnKrmn6XnnIvnmoTmlrDmlLbol4/ml7bmmL7npLrv
vIkKICAgICAgICBsZXQgcGlubmVkTiA9IE51bWJlcihwaW5uZWRUb3RhbCkgfHwgMDsKICAgICAgICBp
ZiAocGlubmVkTiA8IDEpIHsKICAgICAgICAgICAgaWYgKGN1clRhYiA9PT0gJ3Bpbm5lZCcpCiAgICAg
ICAgICAgICAgICBwaW5uZWROID0gTWF0aC5tYXgoTnVtYmVyKGRpc2tUb3RhbCkgfHwgMCwgbG9hZGVk
KTsKICAgICAgICAgICAgZWxzZQogICAgICAgICAgICAgICAgcGlubmVkTiA9IGFsbENsaXBzLmZpbHRl
cihjID0+IGlzUGlubmVkKGMpKS5sZW5ndGg7CiAgICAgICAgfQogICAgICAgIHVwZGF0ZVBpbkRvdCgp
OwogICAgICAgIC8vIOaUtuiXjyB0YWLvvJpiYXIg55So5oC75pWw77yb5pyq5ruh6aG15pe25pi+56S6
IOW3suWKoOi9vS/mgLvmlbAKICAgICAgICBsZXQgc2hvd1RvdGFsID0gZGlza1RvdGFsID4gMCA/IGRp
c2tUb3RhbCA6IChsb2FkZWQgfHwgMCk7CiAgICAgICAgaWYgKGN1clRhYiA9PT0gJ3Bpbm5lZCcgJiYg
cGlubmVkTiA+IHNob3dUb3RhbCkKICAgICAgICAgICAgc2hvd1RvdGFsID0gcGlubmVkTjsKICAgICAg
ICBjb25zdCBxT24gPSBTdHJpbmcocXVlcnkgfHwgJycpLnRyaW0oKS5sZW5ndGggPiAwOwogICAgICAg
IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdiYXItdHh0JykudGV4dENvbnRlbnQgPSBxT24KICAgICAg
ICAgICAgPyAoc2hvd25Db3VudCArICcg5p2hJykKICAgICAgICAgICAgOiAoc2hvd1RvdGFsID4gbG9h
ZGVkID8gKHNob3duQ291bnQgKyAnIC8gJyArIHNob3dUb3RhbCArICcg5p2hJykgOiAoc2hvd1RvdGFs
ICsgJyDmnaEnKSk7CiAgICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2VtcHR5LXR4dCcpLnRl
eHRDb250ZW50ID0gRU1QVFlfTVNHW2N1clRhYl0gfHwgRU1QVFlfTVNHLmFsbDsKCiAgICAgICAgY29u
c3QgaWRTZXQgPSBuZXcgU2V0KGFsbENsaXBzLm1hcChjID0+ICtjLmlkKSk7CiAgICAgICAgbXVsdGlJ
ZHMgPSBtdWx0aUlkcy5maWx0ZXIoaWQgPT4gaWRTZXQuaGFzKGlkKSk7CiAgICAgICAgdXBkYXRlTXVs
dGlCYWRnZSgpOwoKICAgICAgICBjb25zdCBzaG93biA9IHZpc2libGU7CgogICAgICAgIGxpc3RFbC5x
dWVyeVNlbGVjdG9yQWxsKCcuaXRtLCAjbGlzdC1tb3JlJykuZm9yRWFjaChlID0+IGUucmVtb3ZlKCkp
OwogICAgICAgIC8vIOmqqOaetuW3suWFs+mXre+8muWNs+S9vyB3YWl0aW5nIOS5n+S4jSByZXR1cm7v
vIzmnInmlbDmja7lsLHnm7TmjqXnlLsKICAgICAgICBpZiAoc2tlbEVsKSBza2VsRWwuY2xhc3NMaXN0
LnJlbW92ZSgnb24nKTsKICAgICAgICBjb25zdCBhcHBCb290ID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5
SWQoJ2FwcCcpOwogICAgICAgIGlmIChhcHBCb290KSBhcHBCb290LmNsYXNzTGlzdC5yZW1vdmUoJ2Jv
b3QtbG9hZGluZycpOwogICAgICAgIGlmICgod2FpdGluZ0RhdGEgfHwgIWhvc3RQdXNoZWRPbmNlKSAm
JiAhdmlzaWJsZS5sZW5ndGgpIHsKICAgICAgICAgICAgZW1wdHlFbC5jbGFzc0xpc3QucmVtb3ZlKCdv
bicpOwogICAgICAgICAgICB1cGRhdGVUb3BCdG4oKTsKICAgICAgICAgICAgcmV0dXJuOwogICAgICAg
IH0KICAgICAgICBpZiAoIXZpc2libGUubGVuZ3RoKSB7CiAgICAgICAgICAgIC8vIE5ldmVyIHNob3fj
gIzmmoLml6DorrDlvZXjgI11bnRpbCB3ZSBoYXZlIHNlZW4gYSByZWFsIG5vbi1lbXB0eSBwdXNoLAog
ICAgICAgICAgICAvLyBvciBhIGNvbmZpcm1lZCBlbXB0eSBhZnRlciB3YXJtIChzYXdOb25FbXB0eSBj
YW4gYmUgc2V0IGJ5IGVtcHR5LWZhbGxiYWNrKS4KICAgICAgICAgICAgLy8gRmlsdGVyZWQgc2VhcmNo
IHdpdGggMCBoaXRzIGlzIGFsbG93ZWQgb25jZSBob3N0IHB1c2hlZC4KICAgICAgICAgICAgY29uc3Qg
cU9uID0gU3RyaW5nKHF1ZXJ5IHx8ICcnKS50cmltKCkubGVuZ3RoID4gMDsKICAgICAgICAgICAgY29u
c3QgYWxsb3dFbXB0eSA9IGhvc3RQdXNoZWRPbmNlICYmIHNhd05vbkVtcHR5ICYmICF3YWl0aW5nRGF0
YSAmJiAhYm9vdExvYWRpbmcKICAgICAgICAgICAgICAgICYmIChxT24gfHwgZGlza1RvdGFsIDw9IDAp
OwogICAgICAgICAgICBpZiAoIWFsbG93RW1wdHkpIHsKICAgICAgICAgICAgICAgIGVtcHR5RWwuY2xh
c3NMaXN0LnJlbW92ZSgnb24nKTsKICAgICAgICAgICAgICAgIHVwZGF0ZVRvcEJ0bigpOwogICAgICAg
ICAgICAgICAgcmV0dXJuOwogICAgICAgICAgICB9CiAgICAgICAgICAgIGlmIChzZWxlY3RGaXJzdE9u
U2hvdykgewogICAgICAgICAgICAgICAgc2VsZWN0Rmlyc3RPblNob3cgPSBmYWxzZTsKICAgICAgICAg
ICAgICAgIHNlbGVjdGVkSWQgPSAwOwogICAgICAgICAgICAgICAgY2xlYXJNdWx0aSgpOwogICAgICAg
ICAgICAgICAgbGlzdEVsLnNjcm9sbFRvcCA9IDA7CiAgICAgICAgICAgIH0KICAgICAgICAgICAgZW1w
dHlFbC5jbGFzc0xpc3QuYWRkKCdvbicpOwogICAgICAgICAgICB1cGRhdGVUb3BCdG4oKTsKICAgICAg
ICAgICAgcmV0dXJuOwogICAgICAgIH0KICAgICAgICBlbXB0eUVsLmNsYXNzTGlzdC5yZW1vdmUoJ29u
Jyk7CiAgICAgICAgY29uc3QgZnJhZyA9IGRvY3VtZW50LmNyZWF0ZURvY3VtZW50RnJhZ21lbnQoKTsK
ICAgICAgICBjb25zdCBibG9ja3MgPSBidWlsZFBpbm5lZEJsb2NrcyhzaG93bik7CiAgICAgICAgbGV0
IG51bSA9IDA7CiAgICAgICAgYmxvY2tzLmZvckVhY2goYiA9PiB7CiAgICAgICAgICAgIG51bSArPSAx
OwogICAgICAgICAgICBpZiAoYi5raW5kID09PSAnZ3JvdXAnICYmIGIuaXRlbXMubGVuZ3RoID4gMSkK
ICAgICAgICAgICAgICAgIGZyYWcuYXBwZW5kQ2hpbGQobWFrZUdyb3VwSXRlbShiLml0ZW1zLCBudW0p
KTsKICAgICAgICAgICAgZWxzZQogICAgICAgICAgICAgICAgZnJhZy5hcHBlbmRDaGlsZChtYWtlSXRl
bShiLml0ZW1zWzBdLCBudW0pKTsKICAgICAgICB9KTsKICAgICAgICBsaXN0RWwuYXBwZW5kQ2hpbGQo
ZnJhZyk7CiAgICAgICAgbWFya1F1ZXVlUmFpbHMoKTsKICAgICAgICB1cGRhdGVNb3JlRm9vdGVyKGRp
c2tUb3RhbCk7CiAgICAgICAgaWYgKHNlbGVjdEZpcnN0T25TaG93KSB7CiAgICAgICAgICAgIHNlbGVj
dEZpcnN0T25TaG93ID0gZmFsc2U7CiAgICAgICAgICAgIHNlbGVjdGVkSWQgPSB2aXNpYmxlWzBdLmlk
OwogICAgICAgICAgICBjbGVhck11bHRpKCk7CiAgICAgICAgICAgIGxpc3RFbC5zY3JvbGxUb3AgPSAw
OwogICAgICAgIH0gZWxzZSBpZiAoIXZpc2libGUuc29tZShjID0+IGMuaWQgPT0gc2VsZWN0ZWRJZCkp
IHsKICAgICAgICAgICAgc2VsZWN0ZWRJZCA9IHZpc2libGVbMF0uaWQ7CiAgICAgICAgICAgIHJhbmdl
QW5jaG9ySWQgPSBzZWxlY3RlZElkOwogICAgICAgICAgICByYW5nZUFuY2hvckNsaWNrZWQgPSBmYWxz
ZTsKICAgICAgICB9IGVsc2UgaWYgKCFyYW5nZUFuY2hvcklkKSB7CiAgICAgICAgICAgIHJhbmdlQW5j
aG9ySWQgPSBzZWxlY3RlZElkOwogICAgICAgIH0KICAgICAgICBzeW5jSXRlbUhpZ2hsaWdodCgpOwog
ICAgICAgIHVwZGF0ZVRvcEJ0bigpOwogICAgICAgIGlmICh3aW5kb3cuX19wZW5kaW5nSnVtcElkKSB7
CiAgICAgICAgICAgIGNvbnN0IGppZCA9ICt3aW5kb3cuX19wZW5kaW5nSnVtcElkOwogICAgICAgICAg
ICBjb25zdCBlbCA9IGxpc3RFbC5xdWVyeVNlbGVjdG9yKCcubWctcm93W2RhdGEtaWQ9IicgKyBqaWQg
KyAnIl0nKSB8fCBsaXN0RWwucXVlcnlTZWxlY3RvcignLml0bVtkYXRhLWlkPSInICsgamlkICsgJyJd
Jyk7CiAgICAgICAgICAgIGlmIChlbCkgewogICAgICAgICAgICAgICAgd2luZG93Ll9fcGVuZGluZ0p1
bXBJZCA9IDA7CiAgICAgICAgICAgICAgICB3aW5kb3cuX19qdW1wTG9hZFRyaWVzID0gMDsKICAgICAg
ICAgICAgICAgIHNlbGVjdGVkSWQgPSBqaWQ7CiAgICAgICAgICAgICAgICByZXF1ZXN0QW5pbWF0aW9u
RnJhbWUoKCkgPT4gewogICAgICAgICAgICAgICAgICAgIGNvbnN0IG5vZGUgPSBsaXN0RWwucXVlcnlT
ZWxlY3RvcignLm1nLXJvd1tkYXRhLWlkPSInICsgamlkICsgJyJdJykgfHwgbGlzdEVsLnF1ZXJ5U2Vs
ZWN0b3IoJy5pdG1bZGF0YS1pZD0iJyArIGppZCArICciXScpOwogICAgICAgICAgICAgICAgICAgIGlm
ICghbm9kZSkgcmV0dXJuOwogICAgICAgICAgICAgICAgICAgIG5vZGUuc2Nyb2xsSW50b1ZpZXcoeyBi
bG9jazogJ2NlbnRlcicgfSk7CiAgICAgICAgICAgICAgICAgICAgbm9kZS5jbGFzc0xpc3QuYWRkKCdq
dW1wLWZsYXNoJyk7CiAgICAgICAgICAgICAgICAgICAgc2V0VGltZW91dCgoKSA9PiBub2RlLmNsYXNz
TGlzdC5yZW1vdmUoJ2p1bXAtZmxhc2gnKSwgOTAwKTsKICAgICAgICAgICAgICAgICAgICBzeW5jSXRl
bUhpZ2hsaWdodCgpOwogICAgICAgICAgICAgICAgfSk7CiAgICAgICAgICAgIH0gZWxzZSBpZiAoYWxs
Q2xpcHMubGVuZ3RoIDwgZGlza1RvdGFsICYmICh3aW5kb3cuX19qdW1wTG9hZFRyaWVzIHx8IDApIDwg
NDApIHsKICAgICAgICAgICAgICAgIHdpbmRvdy5fX2p1bXBMb2FkVHJpZXMgPSAod2luZG93Ll9fanVt
cExvYWRUcmllcyB8fCAwKSArIDE7CiAgICAgICAgICAgICAgICByZXF1ZXN0TW9yZSgpOwogICAgICAg
ICAgICB9IGVsc2UgaWYgKGN1clRhYiAhPT0gJ2FsbCcgJiYgIXdpbmRvdy5fX2p1bXBGZWxsQmFjaykg
ewogICAgICAgICAgICAgICAgLy8gSXRlbSBnb25lIGZyb20gdGhpcyB0YWIgKGUuZy4gdW5waW5uZWQp
IOKAlCBmYWxsIGJhY2sgdG8g5YWo6YOoIG9uY2UKICAgICAgICAgICAgICAgIHdpbmRvdy5fX2p1bXBG
ZWxsQmFjayA9IHRydWU7CiAgICAgICAgICAgICAgICB3aW5kb3cuX19qdW1wTG9hZFRyaWVzID0gMDsK
ICAgICAgICAgICAgICAgIGN1clRhYiA9ICdhbGwnOwogICAgICAgICAgICAgICAgbWFya1RhYignYWxs
Jyk7CiAgICAgICAgICAgICAgICByZXF1ZXN0VmlldygpOwogICAgICAgICAgICB9IGVsc2UgewogICAg
ICAgICAgICAgICAgd2luZG93Ll9fcGVuZGluZ0p1bXBJZCA9IDA7CiAgICAgICAgICAgICAgICB3aW5k
b3cuX19qdW1wTG9hZFRyaWVzID0gMDsKICAgICAgICAgICAgICAgIGlmIChhbGxDbGlwcy5zb21lKGMg
PT4gK2MuaWQgPT09IGppZCkpCiAgICAgICAgICAgICAgICAgICAgc2VsZWN0ZWRJZCA9IGppZDsKICAg
ICAgICAgICAgICAgIHN5bmNJdGVtSGlnaGxpZ2h0KCk7CiAgICAgICAgICAgIH0KICAgICAgICB9CiAg
ICAgICAgcmVxdWVzdEFuaW1hdGlvbkZyYW1lKCgpID0+IHsKICAgICAgICAgICAgaWYgKGFsbENsaXBz
Lmxlbmd0aCA8IGRpc2tUb3RhbAogICAgICAgICAgICAgICAgJiYgbGlzdEVsLnNjcm9sbEhlaWdodCA8
PSBsaXN0RWwuY2xpZW50SGVpZ2h0ICsgMjApCiAgICAgICAgICAgICAgICByZXF1ZXN0TW9yZSgpOwog
ICAgICAgICAgICBzY2hlZHVsZUZpbGVHb25lQ2hlY2soKTsKICAgICAgICB9KTsKICAgIH0KCiAgICBj
b25zdCBTVkcgPSB7CiAgICAgICAgdGV4dDogICBgPHN2ZyB2aWV3Qm94PSIwIDAgMjQgMjQiIGZpbGw9
Im5vbmUiIHN0cm9rZT0iY3VycmVudENvbG9yIiBzdHJva2Utd2lkdGg9IjIiPjxwYXRoIGQ9Ik00IDdW
NGgxNnYzTTkgMjBoNk0xMiA0djE2Ii8+PC9zdmc+YCwKICAgICAgICBtZDogICAgIGA8c3ZnIHZpZXdC
b3g9IjAgMCAyNCAyNCIgZmlsbD0iY3VycmVudENvbG9yIj48dGV4dCB4PSIxMiIgeT0iMTciIHRleHQt
YW5jaG9yPSJtaWRkbGUiIGZvbnQtc2l6ZT0iMTUiIGZvbnQtd2VpZ2h0PSI4MDAiIGZvbnQtZmFtaWx5
PSJTZWdvZSBVSSxNaWNyb3NvZnQgWWFIZWksc2Fucy1zZXJpZiI+TTwvdGV4dD48L3N2Zz5gLAogICAg
ICAgIGltYWdlOiAgYDxzdmcgdmlld0JveD0iMCAwIDI0IDI0IiBmaWxsPSJub25lIiBzdHJva2U9ImN1
cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIxLjgiPjxyZWN0IHg9IjMiIHk9IjUiIHdpZHRoPSIxOCIg
aGVpZ2h0PSIxNCIgcng9IjIiLz48Y2lyY2xlIGN4PSI4LjUiIGN5PSIxMCIgcj0iMS41IiBmaWxsPSJj
dXJyZW50Q29sb3IiIHN0cm9rZT0ibm9uZSIvPjxwYXRoIGQ9Ik0zIDE2bDUtNSA0IDQgMy0zIDYgNiIv
Pjwvc3ZnPmAsCiAgICAgICAgdmlkZW86ICBgPHN2ZyB2aWV3Qm94PSIwIDAgMjQgMjQiIGZpbGw9Im5v
bmUiIHN0cm9rZT0iY3VycmVudENvbG9yIiBzdHJva2Utd2lkdGg9IjEuOCI+PHJlY3QgeD0iMyIgeT0i
NiIgd2lkdGg9IjE0IiBoZWlnaHQ9IjEyIiByeD0iMiIvPjxwYXRoIGQ9Ik0xNyA5LjVsNC0yLjV2MTBs
LTQtMi41VjkuNXoiIGZpbGw9ImN1cnJlbnRDb2xvciIgc3Ryb2tlPSJub25lIi8+PHBhdGggZD0iTTgu
NSAxMC4ydjMuNmwzLjItMS44LTMuMi0xLjh6IiBmaWxsPSJjdXJyZW50Q29sb3IiIHN0cm9rZT0ibm9u
ZSIvPjwvc3ZnPmAsCiAgICAgICAgZm9sZGVyOiBgPHN2ZyB2aWV3Qm94PSIwIDAgMjQgMjQiIGZpbGw9
ImN1cnJlbnRDb2xvciI+PHBhdGggZD0iTTEwIDRINGMtMS4xIDAtMiAuOS0yIDJ2MTJjMCAxLjEuOSAy
IDIgMmgxNmMxLjEgMCAyLS45IDItMlY4YzAtMS4xLS45LTItMi0yaC04bC0yLTJ6Ii8+PC9zdmc+YCwK
ICAgICAgICB6aXA6ICAgIGA8c3ZnIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0ibm9uZSIgc3Ryb2tl
PSJjdXJyZW50Q29sb3IiIHN0cm9rZS13aWR0aD0iMS44Ij48cGF0aCBkPSJNNiAzaDlsNSA1djEzYTEg
MSAwIDAgMS0xIDFINmExIDEgMCAwIDEtMS0xVjRhMSAxIDAgMCAxIDEtMXoiLz48cGF0aCBkPSJNMTQg
M3Y2aDYiLz48L3N2Zz5gLAogICAgICAgIGFoazogICAgYDxzdmcgdmlld0JveD0iMCAwIDI0IDI0IiBm
aWxsPSJjdXJyZW50Q29sb3IiPjx0ZXh0IHg9IjEyIiB5PSIxNyIgdGV4dC1hbmNob3I9Im1pZGRsZSIg
Zm9udC1zaXplPSIxNCIgZm9udC13ZWlnaHQ9IjcwMCI+SDwvdGV4dD48L3N2Zz5gLAogICAgICAgIGxu
azogICAgYDxzdmcgdmlld0JveD0iMCAwIDI0IDI0IiBmaWxsPSJub25lIiBzdHJva2U9ImN1cnJlbnRD
b2xvciIgc3Ryb2tlLXdpZHRoPSIxLjgiPjxwYXRoIGQ9Ik0xMCAxM2E1IDUgMCAwIDAgNy4wNyAwbDIu
MTItMi4xMmE1IDUgMCAwIDAtNy4wNy03LjA3TDExIDUiLz48cGF0aCBkPSJNMTQgMTFhNSA1IDAgMCAw
LTcuMDcgMEw0LjggMTMuMTJhNSA1IDAgMSAwIDcuMDcgNy4wN0wxMyAxOSIvPjwvc3ZnPmAsCiAgICAg
ICAgZG9jOiAgICBgPHN2ZyB2aWV3Qm94PSIwIDAgMjQgMjQiIGZpbGw9Im5vbmUiIHN0cm9rZT0iY3Vy
cmVudENvbG9yIiBzdHJva2Utd2lkdGg9IjEuOCI+PHBhdGggZD0iTTcgM2g3bDUgNXYxM2ExIDEgMCAw
IDEtMSAxSDdhMSAxIDAgMCAxLTEtMVY0YTEgMSAwIDAgMSAxLTF6Ii8+PHBhdGggZD0iTTE0IDN2Nmg2
Ii8+PC9zdmc+YCwKICAgICAgICBtdWx0aTogIGA8c3ZnIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0i
bm9uZSIgc3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0cm9rZS13aWR0aD0iMS44Ij48cmVjdCB4PSI3IiB5
PSI3IiB3aWR0aD0iMTIiIGhlaWdodD0iMTQiIHJ4PSIxLjUiLz48cGF0aCBkPSJNNSAxN1Y1YTEgMSAw
IDAgMSAxLTFoMTAiLz48L3N2Zz5gCiAgICB9OwoKICAgIGZ1bmN0aW9uIGZpbGVFeHQocGF0aCkgewog
ICAgICAgIGNvbnN0IGJhc2UgPSBTdHJpbmcocGF0aCB8fCAnJykuc3BsaXQoL1tcXC9dLykucG9wKCkg
fHwgJyc7CiAgICAgICAgY29uc3QgaSA9IGJhc2UubGFzdEluZGV4T2YoJy4nKTsKICAgICAgICByZXR1
cm4gaSA+IDAgPyBiYXNlLnNsaWNlKGkgKyAxKS50b0xvd2VyQ2FzZSgpIDogJyc7CiAgICB9CiAgICBj
b25zdCBpc0ltYWdlRXh0ID0gZSA9PiBbJ3BuZycsJ2pwZycsJ2pwZWcnLCdnaWYnLCd3ZWJwJywnYm1w
JywnaWNvJywndGlmJywndGlmZicsJ3N2ZyddLmluY2x1ZGVzKGUpOwogICAgY29uc3QgaXNWaWRlb0V4
dCA9IGUgPT4gWydtcDQnLCdta3YnLCdhdmknLCdtb3YnLCd3bXYnLCdmbHYnLCd3ZWJtJywnbTR2Jywn
bXBlZycsJ21wZycsJ3RzJywnbTJ0cycsJzNncCcsJ3JtJywncm12YiddLmluY2x1ZGVzKGUpOwogICAg
Y29uc3QgaXNaaXBFeHQgICA9IGUgPT4gWyd6aXAnLCdyYXInLCc3eicsJ3RhcicsJ2d6JywnYnoyJ10u
aW5jbHVkZXMoZSk7CgogICAgZnVuY3Rpb24gaWNvbkZvckZpbGVzKGZpbGVzKSB7CiAgICAgICAgaWYg
KCFmaWxlcy5sZW5ndGgpICAgIHJldHVybiB7IGNsczogJ2ZpbGUgZnQtZG9jJywgc3ZnOiBTVkcuZG9j
IH07CiAgICAgICAgaWYgKGZpbGVzLmxlbmd0aCA+IDEpIHJldHVybiB7IGNsczogJ2ZpbGUgZnQtbG5r
Jywgc3ZnOiBTVkcubXVsdGkgfTsKICAgICAgICBjb25zdCBleHQgPSBmaWxlRXh0KGZpbGVzWzBdKTsK
ICAgICAgICBpZiAoIWV4dCkgICAgICAgICAgICAgIHJldHVybiB7IGNsczogJ2ZpbGUgZnQtZGlyJywg
c3ZnOiBTVkcuZm9sZGVyIH07CiAgICAgICAgaWYgKGlzSW1hZ2VFeHQoZXh0KSkgICByZXR1cm4geyBj
bHM6ICdmaWxlIGZ0LWltZycsIHN2ZzogU1ZHLmltYWdlIH07CiAgICAgICAgaWYgKGlzVmlkZW9FeHQo
ZXh0KSkgICByZXR1cm4geyBjbHM6ICdmaWxlIGZ0LXZpZCcsIHN2ZzogKFNWRy52aWRlbyB8fCBTVkcu
ZG9jKSB9OwogICAgICAgIGlmIChpc1ppcEV4dChleHQpKSAgICAgcmV0dXJuIHsgY2xzOiAnZmlsZSBm
dC16aXAnLCBzdmc6IFNWRy56aXAgfTsKICAgICAgICBpZiAoZXh0ID09PSAnYWhrJykgICAgIHJldHVy
biB7IGNsczogJ2ZpbGUgZnQtYWhrJywgc3ZnOiBTVkcuYWhrIH07CiAgICAgICAgaWYgKGV4dCA9PT0g
J2xuaycpICAgICByZXR1cm4geyBjbHM6ICdmaWxlIGZ0LWxuaycsIHN2ZzogU1ZHLmxuayB9OwogICAg
ICAgIHJldHVybiB7IGNsczogJ2ZpbGUgZnQtZG9jJywgc3ZnOiBTVkcuZG9jIH07CiAgICB9CgogICAg
ZnVuY3Rpb24gc3JjV2luTGFiZWwoYykgewogICAgICAgIGNvbnN0IHQgPSBTdHJpbmcoYyAmJiBjLnNy
Y1RpdGxlIHx8ICcnKS50cmltKCk7CiAgICAgICAgaWYgKHQpIHJldHVybiB0OwogICAgICAgIHJldHVy
biBTdHJpbmcoYyAmJiBjLnNyY0V4ZSB8fCAnJykucmVwbGFjZSgvXC5leGUkL2ksICcnKTsKICAgIH0K
ICAgIGZ1bmN0aW9uIHNyY1RpdGxlSHRtbChjKSB7CiAgICAgICAgLy8g5YiX6KGo5Lit6Ze0L+WPs+S+
p+S4jeWGjeaYvuekuueql+WPo+agh+mimO+8jOadpea6kOWPquS/neeVmeWPs+S+p+Wbvuagh+aCrOWB
nOaPkOekugogICAgICAgIHJldHVybiAnJzsKICAgIH0KICAgIGZ1bmN0aW9uIGV4cGFuZENoZXZyb24o
b3BlbikgewogICAgICAgIHJldHVybiBvcGVuCiAgICAgICAgICAgID8gYDxzdmcgdmlld0JveD0iMCAw
IDE2IDE2IiB3aWR0aD0iMTQiIGhlaWdodD0iMTQiIGZpbGw9Im5vbmUiIHN0cm9rZT0iY3VycmVudENv
bG9yIiBzdHJva2Utd2lkdGg9IjEuOCIgc3Ryb2tlLWxpbmVjYXA9InJvdW5kIj48cG9seWxpbmUgcG9p
bnRzPSI0IDEwIDggNiAxMiAxMCIvPjwvc3ZnPjxzcGFuPuaUtui1tzwvc3Bhbj5gCiAgICAgICAgICAg
IDogYDxzdmcgdmlld0JveD0iMCAwIDE2IDE2IiB3aWR0aD0iMTQiIGhlaWdodD0iMTQiIGZpbGw9Im5v
bmUiIHN0cm9rZT0iY3VycmVudENvbG9yIiBzdHJva2Utd2lkdGg9IjEuOCIgc3Ryb2tlLWxpbmVjYXA9
InJvdW5kIj48cG9seWxpbmUgcG9pbnRzPSI0IDYgOCAxMCAxMiA2Ii8+PC9zdmc+PHNwYW4+5bGV5byA
PC9zcGFuPmA7CiAgICB9CiAgICBmdW5jdGlvbiBsaXN0RXhwYW5kTWF4UHgoKSB7CiAgICAgICAgY29u
c3QgaCA9IChsaXN0RWwgJiYgbGlzdEVsLmNsaWVudEhlaWdodCkgfHwgMzYwOwogICAgICAgIC8vIOWH
oOS5juWNoOa7oeWIl+ihqO+8jOW6lemDqOeVmee6puS4gOihjAogICAgICAgIHJldHVybiBNYXRoLm1h
eCg5NiwgaCAtIDI4KTsKICAgIH0KICAgIGZ1bmN0aW9uIGFwcGx5RXhwYW5kZWRQcmV2aWV3KHByZXYs
IGZ1bGxUZXh0KSB7CiAgICAgICAgY29uc3QgbWF4SCA9IGxpc3RFeHBhbmRNYXhQeCgpOwogICAgICAg
IHByZXYuc3R5bGUubWF4SGVpZ2h0ID0gbWF4SCArICdweCc7CiAgICAgICAgcHJldi5jbGFzc0xpc3Qu
YWRkKCdleHBhbmRlZCcpOwogICAgICAgIHNldEhsVGV4dChwcmV2LCBmdWxsVGV4dCk7CiAgICAgICAg
Ly8g5LuN5rqi5Ye677ya5oiq5pat5bm25Zyo5pyr5bC+5Yqg44CMIC4uLuOAjQogICAgICAgIGlmIChw
cmV2LnNjcm9sbEhlaWdodCA8PSBwcmV2LmNsaWVudEhlaWdodCArIDIpCiAgICAgICAgICAgIHJldHVy
bjsKICAgICAgICBsZXQgbG8gPSAwLCBoaSA9IGZ1bGxUZXh0Lmxlbmd0aCwgYmVzdCA9IDA7CiAgICAg
ICAgd2hpbGUgKGxvIDw9IGhpKSB7CiAgICAgICAgICAgIGNvbnN0IG1pZCA9IChsbyArIGhpKSA+PiAx
OwogICAgICAgICAgICBzZXRIbFRleHQocHJldiwgZnVsbFRleHQuc2xpY2UoMCwgbWlkKSArICcgLi4u
Jyk7CiAgICAgICAgICAgIGlmIChwcmV2LnNjcm9sbEhlaWdodCA8PSBwcmV2LmNsaWVudEhlaWdodCAr
IDIpIHsKICAgICAgICAgICAgICAgIGJlc3QgPSBtaWQ7CiAgICAgICAgICAgICAgICBsbyA9IG1pZCAr
IDE7CiAgICAgICAgICAgIH0gZWxzZSB7CiAgICAgICAgICAgICAgICBoaSA9IG1pZCAtIDE7CiAgICAg
ICAgICAgIH0KICAgICAgICB9CiAgICAgICAgc2V0SGxUZXh0KHByZXYsIGZ1bGxUZXh0LnNsaWNlKDAs
IGJlc3QpICsgJyAuLi4nKTsKICAgIH0KICAgIGZ1bmN0aW9uIGNvbGxhcHNlUHJldmlldyhwcmV2LCBm
dWxsVGV4dCkgewogICAgICAgIHByZXYuY2xhc3NMaXN0LnJlbW92ZSgnZXhwYW5kZWQnKTsKICAgICAg
ICBwcmV2LnN0eWxlLm1heEhlaWdodCA9ICcnOwogICAgICAgIHNldEhsVGV4dChwcmV2LCBmdWxsVGV4
dCk7CiAgICB9CgogICAgZnVuY3Rpb24gZmF2R3JvdXBPZihjKSB7CiAgICAgICAgcmV0dXJuIFN0cmlu
ZyhjICYmIGMuZmF2R3JvdXAgfHwgJycpLnRyaW0oKTsKICAgIH0KICAgIGZ1bmN0aW9uIGNsaXBDb250
ZW50UHJldmlldyhjKSB7CiAgICAgICAgY29uc3QgdHlwZSA9IG5vcm1UeXBlKGMudHlwZSk7CiAgICAg
ICAgaWYgKHR5cGUgPT09ICdpbWFnZScpIHJldHVybiAnW+WbvuWDj10nICsgKGMud2lkdGggJiYgYy5o
ZWlnaHQgPyAoJyAnICsgYy53aWR0aCArICfDlycgKyBjLmhlaWdodCkgOiAnJyk7CiAgICAgICAgaWYg
KHR5cGUgPT09ICdmaWxlJykgewogICAgICAgICAgICBjb25zdCBmaWxlcyA9IFN0cmluZyhjLnByZXZp
ZXcgfHwgYy5kYXRhIHx8ICcnKS5zcGxpdCgvXHI/XG4vKS5maWx0ZXIoQm9vbGVhbik7CiAgICAgICAg
ICAgIHJldHVybiBmaWxlcy5tYXAoZiA9PiBmLnNwbGl0KC9bXFwvXS8pLnBvcCgpKS5qb2luKCcgwrcg
JykgfHwgJ1vmlofku7ZdJzsKICAgICAgICB9CiAgICAgICAgbGV0IF9wID0gU3RyaW5nKGMucHJldmll
dyB8fCBjLmRhdGEgfHwgJycpOwogICAgICAgIHsgY29uc3QgX24gPSBOdW1iZXIoYy5jaGFyQ291bnQp
IHx8IDA7IGlmIChfbiA+IF9wLmxlbmd0aCAmJiBfcC5sZW5ndGgpIF9wICs9ICcuLi4nOyB9CiAgICAg
ICAgcmV0dXJuIF9wOwogICAgfQogICAgZnVuY3Rpb24gYnVpbGRQaW5uZWRCbG9ja3MobGlzdCkgewog
ICAgICAgIGNvbnN0IHVzZWQgPSBuZXcgU2V0KCk7CiAgICAgICAgY29uc3Qgb3V0ID0gW107CiAgICAg
ICAgZm9yIChjb25zdCBjIG9mIGxpc3QpIHsKICAgICAgICAgICAgaWYgKHVzZWQuaGFzKCtjLmlkKSkg
Y29udGludWU7CiAgICAgICAgICAgIGNvbnN0IGdpZCA9IGZhdkdyb3VwT2YoYyk7CiAgICAgICAgICAg
IGlmICghZ2lkKSB7CiAgICAgICAgICAgICAgICB1c2VkLmFkZCgrYy5pZCk7CiAgICAgICAgICAgICAg
ICBvdXQucHVzaCh7IGtpbmQ6ICdzaW5nbGUnLCBpdGVtczogW2NdIH0pOwogICAgICAgICAgICAgICAg
Y29udGludWU7CiAgICAgICAgICAgIH0KICAgICAgICAgICAgY29uc3QgbWVtYmVycyA9IGxpc3QuZmls
dGVyKHggPT4gZmF2R3JvdXBPZih4KSA9PT0gZ2lkKTsKICAgICAgICAgICAgbWVtYmVycy5mb3JFYWNo
KG0gPT4gdXNlZC5hZGQoK20uaWQpKTsKICAgICAgICAgICAgaWYgKG1lbWJlcnMubGVuZ3RoIDwgMikK
ICAgICAgICAgICAgICAgIG91dC5wdXNoKHsga2luZDogJ3NpbmdsZScsIGl0ZW1zOiBbbWVtYmVyc1sw
XSB8fCBjXSB9KTsKICAgICAgICAgICAgZWxzZQogICAgICAgICAgICAgICAgb3V0LnB1c2goeyBraW5k
OiAnZ3JvdXAnLCBnaWQsIGl0ZW1zOiBtZW1iZXJzIH0pOwogICAgICAgIH0KICAgICAgICByZXR1cm4g
b3V0OwogICAgfQogICAgZnVuY3Rpb24gX19wcmVwUGFzdGUoKSB7CiAgICAgICAgdHJ5IHsKICAgICAg
ICAgICAgY29uc3QgcyA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzZWFyY2gnKTsKICAgICAgICAg
ICAgaWYgKHMgJiYgZG9jdW1lbnQuYWN0aXZlRWxlbWVudCA9PT0gcykgdHJ5IHsgcy5ibHVyKCk7IH0g
Y2F0Y2gge30KICAgICAgICAgICAgaWYgKHdpbmRvdy5nZXRTZWxlY3Rpb24pIHdpbmRvdy5nZXRTZWxl
Y3Rpb24oKS5yZW1vdmVBbGxSYW5nZXMoKTsKICAgICAgICB9IGNhdGNoIHt9CiAgICB9CiAgICBmdW5j
dGlvbiBwYXN0ZU9uZShjKSB7CiAgICAgICAgX19wcmVwUGFzdGUoKTsKICAgICAgICBzZWxlY3RlZElk
ID0gYy5pZDsKICAgICAgICBpZiAobXVsdGlJZHMubGVuZ3RoKSBjbGVhck11bHRpKCk7CiAgICAgICAg
c3luY0l0ZW1IaWdobGlnaHQoKTsKICAgICAgICBtYXJrUGFzdGVkTG9jYWwoYy5pZCk7CiAgICAgICAg
YWhrKCdwYXN0ZScsIFN0cmluZyhjLmlkKSk7CiAgICB9CiAgICBmdW5jdGlvbiBvcGVuUmVjZW50RGly
KHBhdGgpIHsKICAgICAgICBsZXQgcCA9IFN0cmluZyhwYXRoIHx8ICcnKS50cmltKCk7CiAgICAgICAg
aWYgKCFwKSByZXR1cm47CiAgICAgICAgaWYgKC9eW2EtekEtWl06JC8udGVzdChwKSkgcCArPSAnXFwn
OwogICAgICAgIC8vIOe7n+S4gCAvIO+8mumBv+WFjSBXZWJWaWV3IGhvc3QvSlNPTiDlkIPmjonlj43m
lpzmnaAKICAgICAgICBjb25zdCB3aXJlID0gcC5yZXBsYWNlKC9cXC9nLCAnLycpOwogICAgICAgIGNv
bnN0IHNlbmQgPSAoKSA9PiB7CiAgICAgICAgICAgIC8vIDEpIHBvc3RNZXNzYWdlIOacgOeos++8iOS4
jei/myBzeW5jIENPTe+8iQogICAgICAgICAgICB0cnkgewogICAgICAgICAgICAgICAgaWYgKHdpbmRv
dy5jaHJvbWUgJiYgY2hyb21lLndlYnZpZXcgJiYgdHlwZW9mIGNocm9tZS53ZWJ2aWV3LnBvc3RNZXNz
YWdlID09PSAnZnVuY3Rpb24nKSB7CiAgICAgICAgICAgICAgICAgICAgY2hyb21lLndlYnZpZXcucG9z
dE1lc3NhZ2UoJ29wZW5EaXJ8JyArIHdpcmUpOwogICAgICAgICAgICAgICAgICAgIHJldHVybiB0cnVl
OwogICAgICAgICAgICAgICAgfQogICAgICAgICAgICB9IGNhdGNoIHt9CiAgICAgICAgICAgIC8vIDIp
IGFzeW5jIGhvc3TvvIjpnZ4gc3luY++8iQogICAgICAgICAgICB0cnkgewogICAgICAgICAgICAgICAg
Y29uc3QgaG9zdCA9IGNocm9tZS53ZWJ2aWV3Lmhvc3RPYmplY3RzLmFoazsKICAgICAgICAgICAgICAg
IGlmIChob3N0ICYmIGhvc3Qub3BlbkRpcikgewogICAgICAgICAgICAgICAgICAgIFByb21pc2UucmVz
b2x2ZShob3N0Lm9wZW5EaXIod2lyZSkpLmNhdGNoKCgpID0+IHt9KTsKICAgICAgICAgICAgICAgICAg
ICByZXR1cm4gdHJ1ZTsKICAgICAgICAgICAgICAgIH0KICAgICAgICAgICAgfSBjYXRjaCB7fQogICAg
ICAgICAgICAvLyAzKSDmnIDlkI7miY0gc3luYwogICAgICAgICAgICB0cnkgeyBhaGsoJ29wZW5EaXIn
LCB3aXJlKTsgcmV0dXJuIHRydWU7IH0gY2F0Y2gge30KICAgICAgICAgICAgcmV0dXJuIGZhbHNlOwog
ICAgICAgIH07CiAgICAgICAgLy8g56a75byAIHBvaW50ZXIg5LqL5Lu25qCI5YaN6LCD77yM6YG/5YWN
IFdlYlZpZXcyIOWQjOatpeatu+mUgeWvvOiHtOKAnOeCueS6huayoeWPjeW6lOKAnQogICAgICAgIHNl
dFRpbWVvdXQoc2VuZCwgMCk7CiAgICB9CiAgICBmdW5jdGlvbiBpc0l0ZW1DaHJvbWVUYXJnZXQodCkg
ewogICAgICAgIHJldHVybiAhISh0ICYmIHQuY2xvc2VzdCAmJiB0LmNsb3Nlc3QoJy5pLWV4cGFuZC1i
dG4sIC5pLXNyYy1pY28sIC5tZy1zcmMsIC5mZC1idG4sIC5mZC1wYXRoLCAucmYtc2VnLCBidXR0b24s
IGEsIGlucHV0JykpOwogICAgfQogICAgZnVuY3Rpb24gYmVnaW5QYXN0ZUZyb21JdGVtKGUsIGMpIHsK
ICAgICAgICBpZiAoZS5idXR0b24gIT0gbnVsbCAmJiBlLmJ1dHRvbiAhPT0gMCkgcmV0dXJuOwogICAg
ICAgIGNvbnN0IHNlZyA9IGUudGFyZ2V0ICYmIGUudGFyZ2V0LmNsb3Nlc3QgJiYgZS50YXJnZXQuY2xv
c2VzdCgnLnJmLXNlZycpOwogICAgICAgIGlmIChzZWcpIHsKICAgICAgICAgICAgY29uc3Qgb3BlblBh
dGggPSBzZWcuX29wZW5QYXRoIHx8IHNlZy5nZXRBdHRyaWJ1dGUoJ2RhdGEtcGF0aCcpIHx8IHNlZy5k
YXRhc2V0Lm9wZW5QYXRoIHx8ICcnOwogICAgICAgICAgICBpZiAob3BlblBhdGgpIHsKICAgICAgICAg
ICAgICAgIGUucHJldmVudERlZmF1bHQoKTsKICAgICAgICAgICAgICAgIGUuc3RvcFByb3BhZ2F0aW9u
KCk7CiAgICAgICAgICAgICAgICBvcGVuUmVjZW50RGlyKG9wZW5QYXRoKTsKICAgICAgICAgICAgICAg
IHJldHVybjsKICAgICAgICAgICAgfQogICAgICAgIH0KICAgICAgICBpZiAoZS50YXJnZXQgJiYgZS50
YXJnZXQuY2xvc2VzdCAmJiBlLnRhcmdldC5jbG9zZXN0KCcucmYtcGF0aCcpKQogICAgICAgICAgICBy
ZXR1cm47CiAgICAgICAgaWYgKGlzSXRlbUNocm9tZVRhcmdldChlLnRhcmdldCkpIHJldHVybjsKICAg
ICAgICBpZiAobm9ybVR5cGUoYy50eXBlKSA9PT0gJ3JlY2VudCcpIHsKICAgICAgICAgICAgYWN0aXZh
dGVDbGlwSXRlbShjKTsKICAgICAgICAgICAgcmV0dXJuOwogICAgICAgIH0KICAgICAgICBpZiAoaGFu
ZGxlSXRlbUNsaWNrKGUsIGMpKQogICAgICAgICAgICByZXR1cm47CiAgICAgICAgX19wcmVwUGFzdGUo
KTsKICAgICAgICBzZWxlY3RlZElkID0gYy5pZDsKICAgICAgICByYW5nZUFuY2hvcklkID0gYy5pZDsK
ICAgICAgICAgICAgaWYgKG11bHRpSWRzLmxlbmd0aCA+IDAgJiYgbXVsdGlJZHMuaW5jbHVkZXMoK2Mu
aWQpKSB7CiAgICAgICAgICAgIGNvbnN0IGlkcyA9IG11bHRpSWRzLnNsaWNlKCk7CiAgICAgICAgICAg
IGNsZWFyTXVsdGkoKTsKICAgICAgICAgICAgbWFya1Bhc3RlZExvY2FsKGlkcyk7CiAgICAgICAgICAg
IHBhc3RlTWFueVdpdGhTZXAoaWRzKTsKICAgICAgICAgICAgcmV0dXJuOwogICAgICAgIH0KICAgICAg
ICBpZiAobXVsdGlJZHMubGVuZ3RoKSBjbGVhck11bHRpKCk7CiAgICAgICAgc3luY0l0ZW1IaWdobGln
aHQoKTsKICAgICAgICBtYXJrUGFzdGVkTG9jYWwoYy5pZCk7CiAgICAgICAgYWhrKCdwYXN0ZScsIFN0
cmluZyhjLmlkKSk7CiAgICB9CiAgICBmdW5jdGlvbiBtYWtlR3JvdXBJdGVtKGl0ZW1zLCBpZHgpIHsK
ICAgICAgICBjb25zdCBlbCA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOwogICAgICAgIGVs
LmNsYXNzTmFtZSA9ICdpdG0gaXQtZ3JvdXAnCiAgICAgICAgICAgICsgKGl0ZW1zLnNvbWUoYyA9PiAr
Yy5pZCA9PT0gK3NlbGVjdGVkSWQpID8gJyBzZWwnIDogJycpCiAgICAgICAgICAgICsgKGl0ZW1zLnNv
bWUoYyA9PiBtdWx0aUlkcy5pbmNsdWRlcygrYy5pZCkpID8gJyBtdWx0aScgOiAnJyk7CiAgICAgICAg
ZWwuZGF0YXNldC5ncm91cCA9IGZhdkdyb3VwT2YoaXRlbXNbMF0pIHx8ICcnOwogICAgICAgIGVsLmRh
dGFzZXQuaWQgPSBpdGVtc1swXS5pZDsKCiAgICAgICAgY29uc3QgaGVhZCA9IGRvY3VtZW50LmNyZWF0
ZUVsZW1lbnQoJ2RpdicpOwogICAgICAgIGhlYWQuY2xhc3NOYW1lID0gJ21nLWhlYWQnOwogICAgICAg
IGhlYWQuaW5uZXJIVE1MID0gJzxzcGFuIGNsYXNzPSJtZy10YWciPuWQiOW5tjwvc3Bhbj48c3Bhbj4n
ICsgaXRlbXMubGVuZ3RoICsgJyDmnaEgwrcg54K55Ye75Y2V5p2h57KY6LS0PC9zcGFuPic7CiAgICAg
ICAgZWwuYXBwZW5kQ2hpbGQoaGVhZCk7CgogICAgICAgIGl0ZW1zLmZvckVhY2goYyA9PiB7CiAgICAg
ICAgICAgIGNvbnN0IHJvdyA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOwogICAgICAgICAg
ICByb3cuY2xhc3NOYW1lID0gJ21nLXJvdycKICAgICAgICAgICAgICAgICsgKCtzZWxlY3RlZElkID09
PSArYy5pZCA/ICcgc2VsJyA6ICcnKQogICAgICAgICAgICAgICAgKyAobXVsdGlJZHMuaW5jbHVkZXMo
K2MuaWQpID8gJyBtdWx0aScgOiAnJyk7CiAgICAgICAgICAgIHJvdy5kYXRhc2V0LmlkID0gYy5pZDsK
CiAgICAgICAgICAgIGNvbnN0IHRvcCA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOwogICAg
ICAgICAgICB0b3AuY2xhc3NOYW1lID0gJ21nLXJvdy10b3AnOwogICAgICAgICAgICBjb25zdCBtYWlu
ID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnZGl2Jyk7CiAgICAgICAgICAgIG1haW4uY2xhc3NOYW1l
ID0gJ21nLXJvdy1tYWluJzsKCiAgICAgICAgICAgIGNvbnN0IHRpdGxlID0gU3RyaW5nKGMuZmF2VGl0
bGUgfHwgJycpLnRyaW0oKTsKICAgICAgICAgICAgaWYgKHRpdGxlKSB7CiAgICAgICAgICAgICAgICBj
b25zdCB0ID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnZGl2Jyk7CiAgICAgICAgICAgICAgICB0LmNs
YXNzTmFtZSA9ICdtZy10aXRsZSc7CiAgICAgICAgICAgICAgICBzZXRIbFRleHQodCwgdGl0bGUpOwog
ICAgICAgICAgICAgICAgbWFpbi5hcHBlbmRDaGlsZCh0KTsKICAgICAgICAgICAgfQogICAgICAgICAg
ICBjb25zdCBib2R5ID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnZGl2Jyk7CiAgICAgICAgICAgIGJv
ZHkuY2xhc3NOYW1lID0gJ21nLWJvZHknICsgKG5vcm1UeXBlKGMudHlwZSkgPT09ICdpbWFnZScgPyAn
IGltZycgOiAnJyk7CiAgICAgICAgICAgIHNldEhsVGV4dChib2R5LCBjbGlwQ29udGVudFByZXZpZXco
YykpOwogICAgICAgICAgICBtYWluLmFwcGVuZENoaWxkKGJvZHkpOwogICAgICAgICAgICB0b3AuYXBw
ZW5kQ2hpbGQobWFpbik7CgogICAgICAgICAgICBjb25zdCBzcmNJY28gPSBTdHJpbmcoYy5zcmNJY29u
IHx8ICcnKTsKICAgICAgICAgICAgY29uc3Qgc3JjRXhlID0gU3RyaW5nKGMuc3JjRXhlIHx8ICcnKTsK
ICAgICAgICAgICAgY29uc3Qgc3JjVGl0bGUgPSBTdHJpbmcoYy5zcmNUaXRsZSB8fCAnJyk7CiAgICAg
ICAgICAgIGlmIChzcmNJY28pIHsKICAgICAgICAgICAgICAgIGNvbnN0IGltZyA9IGRvY3VtZW50LmNy
ZWF0ZUVsZW1lbnQoJ2ltZycpOwogICAgICAgICAgICAgICAgaW1nLmNsYXNzTmFtZSA9ICdtZy1zcmMn
OwogICAgICAgICAgICAgICAgaW1nLnNyYyA9IFNUT1JFX0JBU0UgKyBlbmNvZGVVUklDb21wb25lbnQo
c3JjSWNvKTsKICAgICAgICAgICAgICAgIGltZy5hbHQgPSAnJzsKICAgICAgICAgICAgICAgIGNvbnN0
IHRpcFR4dCA9IHNyY1RpdGxlIHx8IHNyY0V4ZSB8fCAn5p2l5rqQJzsKICAgICAgICAgICAgICAgIGlt
Zy50aXRsZSA9IHRpcFR4dDsKICAgICAgICAgICAgICAgIGltZy5vbmNsaWNrID0gZSA9PiB7IGUucHJl
dmVudERlZmF1bHQoKTsgZS5zdG9wUHJvcGFnYXRpb24oKTsgc2hvd1NyY1RpcChpbWcsIHRpcFR4dCk7
IH07CiAgICAgICAgICAgICAgICB0b3AuYXBwZW5kQ2hpbGQoaW1nKTsKICAgICAgICAgICAgfQogICAg
ICAgICAgICByb3cuYXBwZW5kQ2hpbGQodG9wKTsKCiAgICAgICAgICAgIHJvdy5vbnBvaW50ZXJkb3du
ID0gZSA9PiB7CiAgICAgICAgICAgICAgICBpZiAoZS5idXR0b24gIT09IDApIHJldHVybjsKICAgICAg
ICAgICAgICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAgICAgICAgICAgICBiZWdpblBhc3RlRnJv
bUl0ZW0oZSwgYyk7CiAgICAgICAgICAgIH07CiAgICAgICAgICAgIHJvdy5vbmNvbnRleHRtZW51ID0g
ZSA9PiB7CiAgICAgICAgICAgICAgICBlLnByZXZlbnREZWZhdWx0KCk7CiAgICAgICAgICAgICAgICBl
LnN0b3BQcm9wYWdhdGlvbigpOwogICAgICAgICAgICAgICAgc2VsZWN0ZWRJZCA9IGMuaWQ7CiAgICAg
ICAgICAgICAgICBzaG93Q3R4KGUuY2xpZW50WCwgZS5jbGllbnRZLCBjKTsKICAgICAgICAgICAgfTsK
ICAgICAgICAgICAgZWwuYXBwZW5kQ2hpbGQocm93KTsKICAgICAgICB9KTsKCiAgICAgICAgZWwub25j
b250ZXh0bWVudSA9IGUgPT4gewogICAgICAgICAgICBpZiAoZS50YXJnZXQuY2xvc2VzdCgnLm1nLXJv
dycpKSByZXR1cm47CiAgICAgICAgICAgIGUucHJldmVudERlZmF1bHQoKTsKICAgICAgICAgICAgc2Vs
ZWN0ZWRJZCA9IGl0ZW1zWzBdLmlkOwogICAgICAgICAgICBzaG93Q3R4KGUuY2xpZW50WCwgZS5jbGll
bnRZLCBpdGVtc1swXSk7CiAgICAgICAgfTsKICAgICAgICByZXR1cm4gZWw7CiAgICB9CgoKICAgIGZ1
bmN0aW9uIGJ1aWxkUmVjZW50UGF0aENydW1icyhjb250YWluZXIsIGZ1bGxQYXRoKSB7CiAgICAgICAg
aWYgKCFjb250YWluZXIpIHJldHVybjsKICAgICAgICBjb250YWluZXIucXVlcnlTZWxlY3RvckFsbCgn
LnJmLXNlZywgLnJmLXNlcCcpLmZvckVhY2gobiA9PiBuLnJlbW92ZSgpKTsKICAgICAgICBjb25zdCBy
YXcgPSBTdHJpbmcoZnVsbFBhdGggfHwgJycpLnJlcGxhY2UoL1wvL2csICdcXCcpLnJlcGxhY2UoL1xc
KyQvLCAnJyk7CiAgICAgICAgaWYgKCFyYXcpIHJldHVybjsKICAgICAgICBjb25zdCB1bmMgPSByYXcu
c3RhcnRzV2l0aCgnXFxcXCcpOwogICAgICAgIGxldCByZXN0ID0gdW5jID8gcmF3LnNsaWNlKDIpIDog
cmF3OwogICAgICAgIGNvbnN0IHBhcnRzID0gcmVzdC5zcGxpdCgnXFwnKS5maWx0ZXIoQm9vbGVhbik7
CiAgICAgICAgY29uc3QgYWRkU2VnID0gKGxhYmVsLCBvcGVuUGF0aCkgPT4gewogICAgICAgICAgICBp
ZiAoY29udGFpbmVyLnF1ZXJ5U2VsZWN0b3IoJy5yZi1zZWcsIC5yZi1zZXAnKSkgewogICAgICAgICAg
ICAgICAgY29uc3Qgc2VwID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnc3BhbicpOwogICAgICAgICAg
ICAgICAgc2VwLmNsYXNzTmFtZSA9ICdyZi1zZXAnOwogICAgICAgICAgICAgICAgc2VwLnRleHRDb250
ZW50ID0gJ1xcJzsKICAgICAgICAgICAgICAgIGNvbnRhaW5lci5hcHBlbmRDaGlsZChzZXApOwogICAg
ICAgICAgICB9CiAgICAgICAgICAgIC8vIGJ1dHRvbu+8muWRveS4reabtOeos++8jOS4jeiiqyBhcHAt
cmVnaW9uIC8g54i257qnIHBvaW50ZXIg5ZCD5o6JCiAgICAgICAgICAgIGNvbnN0IHNlZyA9IGRvY3Vt
ZW50LmNyZWF0ZUVsZW1lbnQoJ2J1dHRvbicpOwogICAgICAgICAgICBzZWcudHlwZSA9ICdidXR0b24n
OwogICAgICAgICAgICBzZWcuY2xhc3NOYW1lID0gJ3JmLXNlZyc7CiAgICAgICAgICAgIHNldEhsVGV4
dChzZWcsIGxhYmVsKTsKICAgICAgICAgICAgc2VnLnRpdGxlID0gJ+aJk+W8gDogJyArIG9wZW5QYXRo
OwogICAgICAgICAgICBzZWcuc2V0QXR0cmlidXRlKCdkYXRhLXBhdGgnLCBvcGVuUGF0aC5yZXBsYWNl
KC9cXC9nLCAnLycpKTsKICAgICAgICAgICAgc2VnLl9vcGVuUGF0aCA9IG9wZW5QYXRoOwogICAgICAg
ICAgICBzZWcuYWRkRXZlbnRMaXN0ZW5lcignY2xpY2snLCBlID0+IHsKICAgICAgICAgICAgICAgIGUu
cHJldmVudERlZmF1bHQoKTsKICAgICAgICAgICAgICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAg
ICAgICAgICAgICBvcGVuUmVjZW50RGlyKG9wZW5QYXRoKTsKICAgICAgICAgICAgfSwgdHJ1ZSk7CiAg
ICAgICAgICAgIHNlZy5hZGRFdmVudExpc3RlbmVyKCdwb2ludGVyZG93bicsIGUgPT4gewogICAgICAg
ICAgICAgICAgaWYgKGUuYnV0dG9uICE9PSAwKSByZXR1cm47CiAgICAgICAgICAgICAgICBlLnByZXZl
bnREZWZhdWx0KCk7CiAgICAgICAgICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgICAgICAg
ICAgICAgb3BlblJlY2VudERpcihvcGVuUGF0aCk7CiAgICAgICAgICAgIH0sIHRydWUpOwogICAgICAg
ICAgICBjb250YWluZXIuYXBwZW5kQ2hpbGQoc2VnKTsKICAgICAgICB9OwogICAgICAgIGlmICghcGFy
dHMubGVuZ3RoKSB7CiAgICAgICAgICAgIGFkZFNlZyhyYXcsIHJhdyk7CiAgICAgICAgICAgIHJldHVy
bjsKICAgICAgICB9CiAgICAgICAgbGV0IGFjYyA9IHVuYyA/ICdcXFxcJyArIHBhcnRzWzBdIDogcGFy
dHNbMF07CiAgICAgICAgaWYgKCF1bmMgJiYgL15bYS16QS1aXTokLy50ZXN0KHBhcnRzWzBdKSkKICAg
ICAgICAgICAgYWNjID0gcGFydHNbMF0gKyAnXFwnOwogICAgICAgIGFkZFNlZyhwYXJ0c1swXSwgYWNj
KTsKICAgICAgICBmb3IgKGxldCBpID0gMTsgaSA8IHBhcnRzLmxlbmd0aDsgaSsrKSB7CiAgICAgICAg
ICAgIGFjYyA9IGFjYy5yZXBsYWNlKC9cXCskLywgJycpICsgJ1xcJyArIHBhcnRzW2ldOwogICAgICAg
ICAgICBhZGRTZWcocGFydHNbaV0sIGFjYyk7CiAgICAgICAgfQogICAgfQoKICAgIGZ1bmN0aW9uIGFj
dGl2YXRlQ2xpcEl0ZW0oYykgewogICAgICAgIGlmICghYykgcmV0dXJuOwogICAgICAgIGlmIChub3Jt
VHlwZShjLnR5cGUpID09PSAncmVjZW50JykgewogICAgICAgICAgICBfX3ByZXBQYXN0ZSgpOwogICAg
ICAgICAgICBzZWxlY3RlZElkID0gYy5pZDsKICAgICAgICAgICAgaWYgKG11bHRpSWRzLmxlbmd0aCkg
Y2xlYXJNdWx0aSgpOwogICAgICAgICAgICBzeW5jSXRlbUhpZ2hsaWdodCgpOwogICAgICAgICAgICBh
aGsoJ3Bhc3RlJywgU3RyaW5nKGMuaWQpKTsKICAgICAgICAgICAgcmV0dXJuOwogICAgICAgIH0KICAg
ICAgICBwYXN0ZU9uZShjKTsKICAgIH0KICAgIGZ1bmN0aW9uIG1ha2VJdGVtKGMsIGlkeCkgewogICAg
ICAgIGNvbnN0IHR5cGUgICA9IG5vcm1UeXBlKGMudHlwZSk7CiAgICAgICAgY29uc3QgcGlubmVkID0g
aXNQaW5uZWQoYyk7CiAgICAgICAgY29uc3QgcGFzdGVkID0gaXNQYXN0ZWQoYyk7CiAgICAgICAgY29u
c3QgZWwgICAgID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnZGl2Jyk7CiAgICAgICAgZWwuY2xhc3NO
YW1lICA9ICdpdG0nCiAgICAgICAgICAgICsgKHNlbGVjdGVkSWQgPT0gYy5pZCA/ICcgc2VsJyA6ICcn
KQogICAgICAgICAgICArIChtdWx0aUlkcy5pbmNsdWRlcygrYy5pZCkgPyAnIG11bHRpJyA6ICcnKTsK
ICAgICAgICBlbC5kYXRhc2V0LmlkID0gYy5pZDsKICAgICAgICBjb25zdCBxZyA9IE51bWJlcihjLnF1
ZXVlR3JvdXApIHx8IDA7CiAgICAgICAgaWYgKHFnID4gMCkgewogICAgICAgICAgICBlbC5jbGFzc0xp
c3QuYWRkKCdxLW1lbWJlcicpOwogICAgICAgICAgICBlbC5kYXRhc2V0LnFnID0gU3RyaW5nKHFnKTsK
ICAgICAgICAgICAgZWwuZGF0YXNldC5xaSA9IFN0cmluZyhOdW1iZXIoYy5xdWV1ZUluZGV4KSB8fCAw
KTsKICAgICAgICAgICAgaWYgKHBhc3RlZCkgZWwuY2xhc3NMaXN0LmFkZCgncS1kb25lJyk7CiAgICAg
ICAgICAgIGNvbnN0IHJhaWwgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdzcGFuJyk7CiAgICAgICAg
ICAgIHJhaWwuY2xhc3NOYW1lID0gJ3EtcmFpbCc7CiAgICAgICAgICAgIGNvbnN0IGRvdCA9IGRvY3Vt
ZW50LmNyZWF0ZUVsZW1lbnQoJ3NwYW4nKTsKICAgICAgICAgICAgZG90LmNsYXNzTmFtZSA9ICdxLWRv
dCc7CiAgICAgICAgICAgIGRvdC50aXRsZSA9IHBhc3RlZCA/ICfpmJ/liJflt7LnspjotLQnIDogJ+ey
mOi0tOmYn+WIlyc7CiAgICAgICAgICAgIGVsLmFwcGVuZENoaWxkKHJhaWwpOwogICAgICAgICAgICBl
bC5hcHBlbmRDaGlsZChkb3QpOwogICAgICAgIH0KCiAgICAgICAgY29uc3QgaWNvICA9IGRvY3VtZW50
LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOwogICAgICAgIGNvbnN0IGJvZHkgPSBkb2N1bWVudC5jcmVhdGVF
bGVtZW50KCdkaXYnKTsKICAgICAgICBib2R5LmNsYXNzTmFtZSA9ICdpLWJvZHknOwoKICAgICAgICBp
ZiAodHlwZSA9PT0gJ2ltYWdlJykgewogICAgICAgICAgICBpY28uY2xhc3NOYW1lID0gJ2ktaWNvIGlt
YWdlJzsKICAgICAgICAgICAgaWNvLmlubmVySFRNTCA9IFNWRy5pbWFnZTsKICAgICAgICAgICAgYmlu
ZEltZ0hvdmVyUHJldmlldyhpY28sIGMuaWQsIGMuaW1nRmlsZSk7CiAgICAgICAgICAgIGNvbnN0IHdy
YXAgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsKICAgICAgICAgICAgd3JhcC5jbGFzc05h
bWUgPSAnaS10aHVtYi13cmFwJzsKICAgICAgICAgICAgY29uc3QgaW1nICA9IGRvY3VtZW50LmNyZWF0
ZUVsZW1lbnQoJ2ltZycpOwogICAgICAgICAgICBpbWcuY2xhc3NOYW1lID0gJ2ktdGh1bWInOwogICAg
ICAgICAgICBpbWcuYWx0ID0gJyc7CiAgICAgICAgICAgIGNvbnN0IGZpbGUgPSBTdHJpbmcoYy5pbWdG
aWxlIHx8ICcnKTsKICAgICAgICAgICAgbGV0IGZhbGxiYWNrID0gU3RyaW5nKGMuZGF0YSB8fCAnJyk7
CiAgICAgICAgICAgIC8vIE5ldmVyIHN5bmMtY2FsbCBBSEsgdGh1bWIgaGVyZSDigJQgZnJlZXplcyB0
YWIgc3dpdGNoZXM7IFB1c2hTdG9yZVRodW1icyBmaWxscyBhc3luYwogICAgICAgICAgICBpZiAoIWZh
bGxiYWNrLnN0YXJ0c1dpdGgoJ2RhdGE6JykgJiYgdGh1bWJDYWNoZS5oYXMoU3RyaW5nKGMuaWQpKSkK
ICAgICAgICAgICAgICAgIGZhbGxiYWNrID0gU3RyaW5nKHRodW1iQ2FjaGUuZ2V0KFN0cmluZyhjLmlk
KSkpOwogICAgICAgICAgICBpbWcub25sb2FkID0gKCkgPT4gewogICAgICAgICAgICAgICAgY29uc3Qg
bXcgPSB3cmFwLmNsaWVudFdpZHRoIHx8IDMwMDsKICAgICAgICAgICAgICAgIGNvbnN0IG53ID0gaW1n
Lm5hdHVyYWxXaWR0aCAgfHwgMDsKICAgICAgICAgICAgICAgIGNvbnN0IG5oID0gaW1nLm5hdHVyYWxI
ZWlnaHQgfHwgMDsKICAgICAgICAgICAgICAgIGlmICghbncgfHwgIW5oKSByZXR1cm47CiAgICAgICAg
ICAgICAgICBjb25zdCBzY2FsZSA9IE1hdGgubWluKDEsIDE4MCAvIG5oLCBtdyAvIG53KTsKICAgICAg
ICAgICAgICAgIGltZy5zdHlsZS53aWR0aCAgPSBNYXRoLnJvdW5kKG53ICogc2NhbGUpICsgJ3B4JzsK
ICAgICAgICAgICAgICAgIGltZy5zdHlsZS5oZWlnaHQgPSBNYXRoLnJvdW5kKG5oICogc2NhbGUpICsg
J3B4JzsKICAgICAgICAgICAgfTsKICAgICAgICAgICAgYmluZFN0b3JlVGh1bWIoaW1nLCBmaWxlLCBj
LmlkLCBmYWxsYmFjayk7CiAgICAgICAgICAgIHdyYXAuYXBwZW5kQ2hpbGQoaW1nKTsKICAgICAgICAg
ICAgY29uc3QgbWV0YSA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOwogICAgICAgICAgICBt
ZXRhLmNsYXNzTmFtZSA9ICdpLW1ldGEnOwogICAgICAgICAgICBtZXRhLmlubmVySFRNTCAgPSBgPHNw
YW4gY2xhc3M9ImktdGltZSI+JHthZ28oYy50aW1lKX08L3NwYW4+JHttZXRhQ2VudGVySHRtbChmYWxz
ZSl9PGRpdiBjbGFzcz0iaS1tZXRhLXJpZ2h0Ij4ke2Mud2lkdGggPyBgPHNwYW4gY2xhc3M9ImktdGFn
Ij4ke2Mud2lkdGh9w5cke2MuaGVpZ2h0fSBweDwvc3Bhbj5gIDogJyd9PC9kaXY+YDsKICAgICAgICAg
ICAgYm9keS5hcHBlbmRDaGlsZCh3cmFwKTsKICAgICAgICAgICAgYm9keS5hcHBlbmRDaGlsZChtZXRh
KTsKICAgICAgICB9IGVsc2UgaWYgKHR5cGUgPT09ICdyZWNlbnQnKSB7CiAgICAgICAgICAgIGljby5j
bGFzc05hbWUgPSAnaS1pY28gZmlsZSBmdC1kaXInOwogICAgICAgICAgICBpY28uaW5uZXJIVE1MID0g
U1ZHLmZvbGRlcjsKICAgICAgICAgICAgaWYgKHBpbm5lZCkgZWwuY2xhc3NMaXN0LmFkZCgncmYtZml4
ZWQnKTsKICAgICAgICAgICAgY29uc3QgcGF0aCA9IFN0cmluZyhjLmRhdGEgfHwgYy5wcmV2aWV3IHx8
ICcnKTsKICAgICAgICAgICAgY29uc3QgY3J1bWJzID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnZGl2
Jyk7CiAgICAgICAgICAgIGNydW1icy5jbGFzc05hbWUgPSAncmYtcGF0aCc7CiAgICAgICAgICAgIGJ1
aWxkUmVjZW50UGF0aENydW1icyhjcnVtYnMsIHBhdGgpOwogICAgICAgICAgICAvLyDlm7rlrprmoIfo
rrDlj6rmlL4gbWV0YSDlj7PkvqfvvIzkuI3mjKHot6/lvoQKICAgICAgICAgICAgY29uc3QgbWV0YSA9
IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOwogICAgICAgICAgICBtZXRhLmNsYXNzTmFtZSA9
ICdpLW1ldGEnOwogICAgICAgICAgICBtZXRhLmlubmVySFRNTCA9CiAgICAgICAgICAgICAgICBgPHNw
YW4gY2xhc3M9ImktdGltZSI+JHthZ28oYy50aW1lKX08L3NwYW4+YCArCiAgICAgICAgICAgICAgICBt
ZXRhQ2VudGVySHRtbChmYWxzZSkgKwogICAgICAgICAgICAgICAgYDxkaXYgY2xhc3M9ImktbWV0YS1y
aWdodCI+JHtwaW5uZWQgPyAnPHNwYW4gY2xhc3M9InJmLXBpbi10YWciIHRpdGxlPSLlt7Llm7rlrprv
vIzkuI3kvJrooqvmt5jmsbAiPuWbuuWumjwvc3Bhbj4nIDogJyd9PC9kaXY+YDsKICAgICAgICAgICAg
Ym9keS5hcHBlbmRDaGlsZChjcnVtYnMpOwogICAgICAgICAgICBib2R5LmFwcGVuZENoaWxkKG1ldGEp
OwogICAgICAgIH0gZWxzZSBpZiAodHlwZSA9PT0gJ2ZpbGUnKSB7CiAgICAgICAgICAgIGNvbnN0IGZp
bGVzID0gU3RyaW5nKGMucHJldmlldyB8fCBjLmRhdGEgfHwgJycpLnNwbGl0KC9ccj9cbi8pLmZpbHRl
cihCb29sZWFuKTsKICAgICAgICAgICAgY29uc3QgaW1hZ2VQYXRocyA9IGZpbGVzLmZpbHRlcihmID0+
IGlzSW1hZ2VFeHQoZmlsZUV4dChmKSkpOwogICAgICAgICAgICBjb25zdCBpYyAgICA9IGljb25Gb3JG
aWxlcyhmaWxlcyk7CiAgICAgICAgICAgIGljby5jbGFzc05hbWUgPSAnaS1pY28gJyArIGljLmNsczsK
ICAgICAgICAgICAgaWNvLmlubmVySFRNTCA9IGljLnN2ZzsKCiAgICAgICAgICAgIGxldCB0aHVtYkZp
bGUgPSBTdHJpbmcoYy5pbWdGaWxlIHx8ICcnKTsKICAgICAgICAgICAgLyogZW5zdXJlRmlsZUltZyBk
ZWZlcnJlZDogYXZvaWQgc3luYyBmcmVlemUgb24gZmlsZSB0YWIgKi8KCiAgICAgICAgICAgIC8vIElt
YWdlLWZvcm1hdCBmaWxlczogc2FtZSB0aHVtYm5haWwgcnVsZXMgYXMgc2NyZWVuc2hvdCBjbGlwcwog
ICAgICAgICAgICBpZiAodGh1bWJGaWxlIHx8IGltYWdlUGF0aHMubGVuZ3RoKSB7CiAgICAgICAgICAg
ICAgICBjb25zdCB3cmFwID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnZGl2Jyk7CiAgICAgICAgICAg
ICAgICB3cmFwLmNsYXNzTmFtZSA9ICdpLXRodW1iLXdyYXAnOwogICAgICAgICAgICAgICAgY29uc3Qg
aW1nICA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2ltZycpOwogICAgICAgICAgICAgICAgaW1nLmNs
YXNzTmFtZSA9ICdpLXRodW1iJzsKICAgICAgICAgICAgICAgIGltZy5hbHQgPSAnJzsKICAgICAgICAg
ICAgICAgIGltZy5vbmxvYWQgPSAoKSA9PiB7CiAgICAgICAgICAgICAgICAgICAgY29uc3QgbXcgPSB3
cmFwLmNsaWVudFdpZHRoIHx8IDMwMDsKICAgICAgICAgICAgICAgICAgICBjb25zdCBudyA9IGltZy5u
YXR1cmFsV2lkdGggIHx8IDA7CiAgICAgICAgICAgICAgICAgICAgY29uc3QgbmggPSBpbWcubmF0dXJh
bEhlaWdodCB8fCAwOwogICAgICAgICAgICAgICAgICAgIGlmICghbncgfHwgIW5oKSByZXR1cm47CiAg
ICAgICAgICAgICAgICAgICAgY29uc3Qgc2NhbGUgPSBNYXRoLm1pbigxLCAxODAgLyBuaCwgbXcgLyBu
dyk7CiAgICAgICAgICAgICAgICAgICAgaW1nLnN0eWxlLndpZHRoICA9IE1hdGgucm91bmQobncgKiBz
Y2FsZSkgKyAncHgnOwogICAgICAgICAgICAgICAgICAgIGltZy5zdHlsZS5oZWlnaHQgPSBNYXRoLnJv
dW5kKG5oICogc2NhbGUpICsgJ3B4JzsKICAgICAgICAgICAgICAgIH07CiAgICAgICAgICAgIC8qIGVu
c3VyZUZpbGVJbWcgZGVmZXJyZWQ6IGF2b2lkIHN5bmMgZnJlZXplIG9uIGZpbGUgdGFiICovCiAgICAg
ICAgICAgICAgICBiaW5kU3RvcmVUaHVtYihpbWcsIHRodW1iRmlsZSwgYy5pZCwgJycpOwogICAgICAg
ICAgICAgICAgd3JhcC5hcHBlbmRDaGlsZChpbWcpOwogICAgICAgICAgICAgICAgYm9keS5hcHBlbmRD
aGlsZCh3cmFwKTsKICAgICAgICAgICAgfQoKICAgICAgICAgICAgY29uc3QgbmFtZSA9IGRvY3VtZW50
LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOwogICAgICAgICAgICBuYW1lLmNsYXNzTmFtZSAgPSAnaS1uYW1l
JzsKICAgICAgICAgICAgc2V0SGxUZXh0KG5hbWUsIGZpbGVzLm1hcChmID0+IGYuc3BsaXQoL1tcXC9d
LykucG9wKCkpLmpvaW4oJ1xuJykgfHwgJyjmlofku7YpJyk7CgogICAgICAgICAgICBlbC5fZmlsZVBh
dGhzID0gZmlsZXM7CgogICAgICAgICAgICBjb25zdCBkZXRhaWwgPSBkb2N1bWVudC5jcmVhdGVFbGVt
ZW50KCdkaXYnKTsKICAgICAgICAgICAgZGV0YWlsLmNsYXNzTmFtZSA9ICdpLWZpbGUtZGV0YWlsJzsK
CiAgICAgICAgICAgIGNvbnN0IG1ldGEgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsKICAg
ICAgICAgICAgbWV0YS5jbGFzc05hbWUgPSAnaS1tZXRhJzsKICAgICAgICAgICAgbGV0IHJpZ2h0ID0g
Jyc7CiAgICAgICAgICAgIHJpZ2h0ICs9IGA8c3BhbiBjbGFzcz0iaS10YWciPiR7Yy5maWxlQ291bnQg
fHwgZmlsZXMubGVuZ3RoIHx8IDF9IOS4quaWh+S7tjwvc3Bhbj5gOwogICAgICAgICAgICBpZiAoKHRo
dW1iRmlsZSB8fCBpbWFnZVBhdGhzLmxlbmd0aCkgJiYgYy53aWR0aCkKICAgICAgICAgICAgICAgIHJp
Z2h0ICs9IGA8c3BhbiBjbGFzcz0iaS10YWciPiR7Yy53aWR0aH3DlyR7Yy5oZWlnaHR9IHB4PC9zcGFu
PmA7CiAgICAgICAgICAgIGNvbnN0IGV4cGFuZEh0bWwgPSBleHBhbmRDaGV2cm9uKGZhbHNlKTsKICAg
ICAgICAgICAgY29uc3QgY29sbGFwc2VIdG1sID0gZXhwYW5kQ2hldnJvbih0cnVlKTsKICAgICAgICAg
ICAgbWV0YS5pbm5lckhUTUwgPQogICAgICAgICAgICAgICAgYDxzcGFuIGNsYXNzPSJpLXRpbWUiPiR7
YWdvKGMudGltZSl9PC9zcGFuPmAgKwogICAgICAgICAgICAgICAgbWV0YUNlbnRlckh0bWwoeyBvbjog
dHJ1ZSwgaHRtbDogZXhwYW5kSHRtbCB9KSArCiAgICAgICAgICAgICAgICBgPGRpdiBjbGFzcz0iaS1t
ZXRhLXJpZ2h0Ij4ke3JpZ2h0fTwvZGl2PmA7CgogICAgICAgICAgICBjb25zdCBleHBCdG4gPSBtZXRh
LnF1ZXJ5U2VsZWN0b3IoJy5pLWV4cGFuZC1idG4nKTsKICAgICAgICAgICAgbGV0IGRldGFpbEJ1aWx0
ID0gZmFsc2U7CiAgICAgICAgICAgIGV4cEJ0bi5vbmNsaWNrID0gZSA9PiB7CiAgICAgICAgICAgICAg
ICBlLnByZXZlbnREZWZhdWx0KCk7CiAgICAgICAgICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwog
ICAgICAgICAgICAgICAgY29uc3Qgb3BlbiA9ICFkZXRhaWwuY2xhc3NMaXN0LmNvbnRhaW5zKCdvbicp
OwogICAgICAgICAgICAgICAgaWYgKG9wZW4gJiYgIWRldGFpbEJ1aWx0KSB7CiAgICAgICAgICAgICAg
ICAgICAgY29uc3QgcGF0aFJvd3MgPSBlbC5fcGF0aFJvd3MgfHwgY2hlY2tGaWxlUGF0aHMoZWwuX2Zp
bGVQYXRocyB8fCBmaWxlcyk7CiAgICAgICAgICAgICAgICAgICAgZmlsbEZpbGVEZXRhaWxQYW5lbChk
ZXRhaWwsIHBhdGhSb3dzKTsKICAgICAgICAgICAgICAgICAgICBkZXRhaWxCdWlsdCA9IHRydWU7CiAg
ICAgICAgICAgICAgICB9CiAgICAgICAgICAgICAgICBkZXRhaWwuY2xhc3NMaXN0LnRvZ2dsZSgnb24n
LCBvcGVuKTsKICAgICAgICAgICAgICAgIGlmIChvcGVuKSB7CiAgICAgICAgICAgICAgICAgICAgZGV0
YWlsLnN0eWxlLm1heEhlaWdodCA9IGxpc3RFeHBhbmRNYXhQeCgpICsgJ3B4JzsKICAgICAgICAgICAg
ICAgICAgICBkZXRhaWwuc3R5bGUub3ZlcmZsb3cgPSAnYXV0byc7CiAgICAgICAgICAgICAgICB9IGVs
c2UgewogICAgICAgICAgICAgICAgICAgIGRldGFpbC5zdHlsZS5tYXhIZWlnaHQgPSAnJzsKICAgICAg
ICAgICAgICAgICAgICBkZXRhaWwuc3R5bGUub3ZlcmZsb3cgPSAnJzsKICAgICAgICAgICAgICAgIH0K
ICAgICAgICAgICAgICAgIGV4cEJ0bi5pbm5lckhUTUwgPSBvcGVuID8gY29sbGFwc2VIdG1sIDogZXhw
YW5kSHRtbDsKICAgICAgICAgICAgfTsKCiAgICAgICAgICAgIGJvZHkuYXBwZW5kQ2hpbGQobmFtZSk7
CiAgICAgICAgICAgIGJvZHkuYXBwZW5kQ2hpbGQoZGV0YWlsKTsKICAgICAgICAgICAgYm9keS5hcHBl
bmRDaGlsZChtZXRhKTsKICAgICAgICB9IGVsc2UgewogICAgICAgICAgICBjb25zdCB1c2VNID0gY2xp
cFVzZXNNSWNvbihjKTsKICAgICAgICAgICAgaWNvLmNsYXNzTmFtZSA9IHVzZU0gPyAnaS1pY28gbWQn
IDogJ2ktaWNvIHRleHQnOwogICAgICAgICAgICBpY28uaW5uZXJIVE1MID0gdXNlTSA/IChTVkcubWQg
fHwgU1ZHLnRleHQpIDogU1ZHLnRleHQ7CiAgICAgICAgICAgIC8qIHBsYWluLWxpc3QtcHJldiAqLwog
ICAgICAgICAgICAvKiBwcmV2aWV3LWVsbGlwc2lzICovCiAgICAgICAgICAgIGxldCB0eHQgID0gYy5w
cmV2aWV3IHx8IGMuZGF0YSB8fCAnJzsKICAgICAgICAgICAgeyBjb25zdCBfbiA9IE51bWJlcihjLmNo
YXJDb3VudCkgfHwgMDsgaWYgKF9uID4gdHh0Lmxlbmd0aCAmJiB0eHQubGVuZ3RoKSB0eHQgKz0gJy4u
Lic7IH0KICAgICAgICAgICAgY29uc3QgcHJldiA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2Rpdicp
OwogICAgICAgICAgICBwcmV2LmNsYXNzTmFtZSAgPSAnaS1wcmV2JyArIChpc1VybCh0eHQpID8gJyB1
cmwnIDogJycpOwogICAgICAgICAgICBzZXRIbFRleHQocHJldiwgdHh0KTsKCiAgICAgICAgICAgIGNv
bnN0IG1ldGEgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsKICAgICAgICAgICAgbWV0YS5j
bGFzc05hbWUgPSAnaS1tZXRhJzsKCiAgICAgICAgICAgIGNvbnN0IGNoYXJzID0gTnVtYmVyKGMuY2hh
ckNvdW50KSB8fCAwOwogICAgICAgICAgICBjb25zdCByaWdodEhUTUwgPSBgPHNwYW4gY2xhc3M9Imkt
Y2hhcnMiPjxzcGFuIGNsYXNzPSJuIj4ke2NoYXJzfTwvc3Bhbj4g5a2X56ymPC9zcGFuPmA7CgogICAg
ICAgICAgICBtZXRhLmlubmVySFRNTCA9CiAgICAgICAgICAgICAgICBgPHNwYW4gY2xhc3M9ImktdGlt
ZSI+JHthZ28oYy50aW1lKX08L3NwYW4+YCArCiAgICAgICAgICAgICAgICBtZXRhQ2VudGVySHRtbCh7
CiAgICAgICAgICAgICAgICAgICAgb246IGZhbHNlLAogICAgICAgICAgICAgICAgICAgIGh0bWw6IGV4
cGFuZENoZXZyb24oZmFsc2UpCiAgICAgICAgICAgICAgICB9KSArCiAgICAgICAgICAgICAgICBgPGRp
diBjbGFzcz0iaS1tZXRhLXJpZ2h0IHRleHQtbWV0YSI+JHtyaWdodEhUTUx9PC9kaXY+YDsKCiAgICAg
ICAgICAgIGJvZHkuYXBwZW5kQ2hpbGQocHJldik7CiAgICAgICAgICAgIGJvZHkuYXBwZW5kQ2hpbGQo
bWV0YSk7CgogICAgICAgICAgICBjb25zdCBleHBCdG4gPSBtZXRhLnF1ZXJ5U2VsZWN0b3IoJy5pLWV4
cGFuZC1idG4nKTsKICAgICAgICAgICAgaWYgKGV4cEJ0bikgewogICAgICAgICAgICAgICAgZXhwQnRu
Lm9uY2xpY2sgPSBlID0+IHsKICAgICAgICAgICAgICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwog
ICAgICAgICAgICAgICAgICAgIGNvbnN0IHdpbGxFeHBhbmQgPSAhcHJldi5jbGFzc0xpc3QuY29udGFp
bnMoJ2V4cGFuZGVkJyk7CiAgICAgICAgICAgICAgICAgICAgaWYgKHdpbGxFeHBhbmQpIHsKICAgICAg
ICAgICAgICAgICAgICAgICAgYXBwbHlFeHBhbmRlZFByZXZpZXcocHJldiwgdHh0KTsKICAgICAgICAg
ICAgICAgICAgICAgICAgZXhwQnRuLmlubmVySFRNTCA9IGV4cGFuZENoZXZyb24odHJ1ZSk7CiAgICAg
ICAgICAgICAgICAgICAgICAgIHRyeSB7IGVsLnNjcm9sbEludG9WaWV3KHsgYmxvY2s6ICduZWFyZXN0
JyB9KTsgfSBjYXRjaCB7fQogICAgICAgICAgICAgICAgICAgIH0gZWxzZSB7CiAgICAgICAgICAgICAg
ICAgICAgICAgIGNvbGxhcHNlUHJldmlldyhwcmV2LCB0eHQpOwogICAgICAgICAgICAgICAgICAgICAg
ICBleHBCdG4uaW5uZXJIVE1MID0gZXhwYW5kQ2hldnJvbihmYWxzZSk7CiAgICAgICAgICAgICAgICAg
ICAgfQogICAgICAgICAgICAgICAgfTsKICAgICAgICAgICAgICAgIGNvbnN0IGNoZWNrT3ZlcmZsb3cg
PSAoKSA9PiB7CiAgICAgICAgICAgICAgICAgICAgY29uc3QgcGxhaW5MZW4gPSBTdHJpbmcoYy5wcmV2
aWV3IHx8IGMuZGF0YSB8fCAnJykubGVuZ3RoOwogICAgICAgICAgICAgICAgICAgIGNvbnN0IGZ1bGxO
ID0gTnVtYmVyKGMuY2hhckNvdW50KSB8fCAwOwogICAgICAgICAgICAgICAgICAgIGNvbnN0IHRydW5j
ID0gZnVsbE4gPiBwbGFpbkxlbjsKICAgICAgICAgICAgICAgICAgICBpZiAocHJldi5zY3JvbGxIZWln
aHQgPiBwcmV2LmNsaWVudEhlaWdodCArIDIgfHwgdHJ1bmMpCiAgICAgICAgICAgICAgICAgICAgICAg
IGV4cEJ0bi5jbGFzc0xpc3QuYWRkKCdvbicpOwogICAgICAgICAgICAgICAgICAgIGVsc2UKICAgICAg
ICAgICAgICAgICAgICAgICAgZXhwQnRuLmNsYXNzTGlzdC5yZW1vdmUoJ29uJyk7CiAgICAgICAgICAg
ICAgICB9OwogICAgICAgICAgICAgICAgcmVxdWVzdEFuaW1hdGlvbkZyYW1lKGNoZWNrT3ZlcmZsb3cp
OwogICAgICAgICAgICAgICAgc2V0VGltZW91dChjaGVja092ZXJmbG93LCA4MCk7CiAgICAgICAgICAg
IH0KICAgICAgICB9CgogICAgICAgIGNvbnN0IGZhdlQgPSBTdHJpbmcoYy5mYXZUaXRsZSB8fCAnJyku
dHJpbSgpOwogICAgICAgIGlmIChmYXZUKSB7CiAgICAgICAgICAgIGNvbnN0IGZ0ID0gZG9jdW1lbnQu
Y3JlYXRlRWxlbWVudCgnZGl2Jyk7CiAgICAgICAgICAgIGZ0LmNsYXNzTmFtZSA9ICdpLWZhdi10aXRs
ZSc7CiAgICAgICAgICAgIHNldEhsVGV4dChmdCwgZmF2VCk7CiAgICAgICAgICAgIGJvZHkuaW5zZXJ0
QmVmb3JlKGZ0LCBib2R5LmZpcnN0Q2hpbGQpOwogICAgICAgIH0KCiAgICAgICAgaWYgKHBhc3RlZCkg
ewogICAgICAgICAgICBlbC5jbGFzc0xpc3QuYWRkKCdwYXN0ZWQnKTsKICAgICAgICAgICAgY29uc3Qg
YmFkZ2UgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdzcGFuJyk7CiAgICAgICAgICAgIGJhZGdlLmNs
YXNzTmFtZSA9ICdpLXVzZWQnOwogICAgICAgICAgICBiYWRnZS50aXRsZSA9ICflt7LnspjotLQnOwog
ICAgICAgICAgICBiYWRnZS5pbm5lckhUTUwgPSBgPHN2ZyB2aWV3Qm94PSIwIDAgMTYgMTYiIGZpbGw9
Im5vbmUiIHN0cm9rZT0iY3VycmVudENvbG9yIiBzdHJva2Utd2lkdGg9IjIuNCIgc3Ryb2tlLWxpbmVj
YXA9InJvdW5kIiBzdHJva2UtbGluZWpvaW49InJvdW5kIj48cG9seWxpbmUgcG9pbnRzPSIzLjUgOC41
IDYuNSAxMS41IDEyLjUgNC41Ii8+PC9zdmc+YDsKICAgICAgICAgICAgaWNvLmFwcGVuZENoaWxkKGJh
ZGdlKTsKICAgICAgICB9CgogICAgICAgIGNvbnN0IG51bSA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQo
J2RpdicpOwogICAgICAgIG51bS5jbGFzc05hbWUgPSAnaS1udW0nOwogICAgICAgIGNvbnN0IG51bVR4
dCA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ3NwYW4nKTsKICAgICAgICBudW1UeHQudGV4dENvbnRl
bnQgPSBpZHg7CiAgICAgICAgbnVtLmFwcGVuZENoaWxkKG51bVR4dCk7CiAgICAgICAgY29uc3Qgc3Jj
SWNvID0gU3RyaW5nKGMuc3JjSWNvbiB8fCAnJyk7CiAgICAgICAgY29uc3Qgc3JjRXhlID0gU3RyaW5n
KGMuc3JjRXhlIHx8ICcnKTsKICAgICAgICBjb25zdCBzcmNUaXRsZSA9IFN0cmluZyhjLnNyY1RpdGxl
IHx8ICcnKTsKICAgICAgICBpZiAoc3JjSWNvKSB7CiAgICAgICAgICAgIGNvbnN0IGltZyA9IGRvY3Vt
ZW50LmNyZWF0ZUVsZW1lbnQoJ2ltZycpOwogICAgICAgICAgICBpbWcuY2xhc3NOYW1lID0gJ2ktc3Jj
LWljbyc7CiAgICAgICAgICAgIGltZy5zcmMgPSBTVE9SRV9CQVNFICsgZW5jb2RlVVJJQ29tcG9uZW50
KHNyY0ljbyk7CiAgICAgICAgICAgIGltZy5hbHQgPSAnJzsKICAgICAgICAgICAgY29uc3QgdGlwVHh0
ID0gc3JjVGl0bGUgfHwgc3JjRXhlIHx8ICfmnaXmupAnOwogICAgICAgICAgICBpbWcudGl0bGUgPSB0
aXBUeHQ7CiAgICAgICAgICAgIGltZy5vbmNsaWNrID0gZSA9PiB7IGUucHJldmVudERlZmF1bHQoKTsg
ZS5zdG9wUHJvcGFnYXRpb24oKTsgc2hvd1NyY1RpcChpbWcsIHRpcFR4dCk7IH07CiAgICAgICAgICAg
IG51bS5hcHBlbmRDaGlsZChpbWcpOwogICAgICAgIH0KCiAgICAgICAgZWwuYXBwZW5kQ2hpbGQoaWNv
KTsKICAgICAgICBlbC5hcHBlbmRDaGlsZChib2R5KTsKICAgICAgICBlbC5hcHBlbmRDaGlsZChudW0p
OwoKICAgICAgICBlbC5vbnBvaW50ZXJkb3duID0gZSA9PiB7CiAgICAgICAgICAgIGJlZ2luUGFzdGVG
cm9tSXRlbShlLCBjKTsKICAgICAgICB9OwogICAgICAgIGVsLm9uY29udGV4dG1lbnUgPSBlID0+IHsK
ICAgICAgICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOwogICAgICAgICAgICBzZWxlY3RlZElkID0gYy5p
ZDsKICAgICAgICAgICAgc2hvd0N0eChlLmNsaWVudFgsIGUuY2xpZW50WSwgYyk7CiAgICAgICAgfTsK
CiAgICAgICAgcmV0dXJuIGVsOwogICAgfQoKICAgIGZ1bmN0aW9uIGl0ZW1Jc1F1ZXVlRG9uZShyb3cp
IHsKICAgICAgICBpZiAoIXJvdykgcmV0dXJuIGZhbHNlOwogICAgICAgIGlmIChyb3cuY2xhc3NMaXN0
LmNvbnRhaW5zKCdwYXN0ZWQnKSB8fCByb3cuY2xhc3NMaXN0LmNvbnRhaW5zKCdxLWRvbmUnKSkKICAg
ICAgICAgICAgcmV0dXJuIHRydWU7CiAgICAgICAgY29uc3QgaWQgPSArcm93LmRhdGFzZXQuaWQ7CiAg
ICAgICAgY29uc3QgYyA9IGFsbENsaXBzLmZpbmQoeCA9PiAreC5pZCA9PT0gaWQpOwogICAgICAgIHJl
dHVybiAhIShjICYmIGlzUGFzdGVkKGMpKTsKICAgIH0KCiAgICBmdW5jdGlvbiBtYXJrUXVldWVSYWls
cygpIHsKICAgICAgICBpZiAoIWxpc3RFbCkgcmV0dXJuOwogICAgICAgIGNvbnN0IG5vZGVzID0gWy4u
Lmxpc3RFbC5xdWVyeVNlbGVjdG9yQWxsKCcuaXRtLnEtbWVtYmVyJyldOwogICAgICAgIGlmICghbm9k
ZXMubGVuZ3RoKSByZXR1cm47CiAgICAgICAgLy8gUmVzZXQgbGluayBjbGFzc2VzOyBrZWVwIHN0cnVj
dHVyYWwgZW5kcwogICAgICAgIG5vZGVzLmZvckVhY2gobiA9PiBuLmNsYXNzTGlzdC5yZW1vdmUoJ3Et
Zmlyc3QnLCAncS1sYXN0JywgJ3Etb25seScsICdxLWRvbmUtbGluaycsICdxLXBhc3RlZC1uZXh0Jykp
OwogICAgICAgIC8vIEdyb3VwIGNvbnNlY3V0aXZlIHNhbWUgcXVldWVHcm91cCBpbiBET00gb3JkZXIK
ICAgICAgICBsZXQgaSA9IDA7CiAgICAgICAgd2hpbGUgKGkgPCBub2Rlcy5sZW5ndGgpIHsKICAgICAg
ICAgICAgY29uc3QgZyA9IG5vZGVzW2ldLmRhdGFzZXQucWc7CiAgICAgICAgICAgIGxldCBqID0gaSAr
IDE7CiAgICAgICAgICAgIHdoaWxlIChqIDwgbm9kZXMubGVuZ3RoICYmIG5vZGVzW2pdLmRhdGFzZXQu
cWcgPT09IGcpIGorKzsKICAgICAgICAgICAgY29uc3Qgc2xpY2UgPSBub2Rlcy5zbGljZShpLCBqKTsK
ICAgICAgICAgICAgaWYgKHNsaWNlLmxlbmd0aCA9PT0gMSkgewogICAgICAgICAgICAgICAgc2xpY2Vb
MF0uY2xhc3NMaXN0LmFkZCgncS1vbmx5Jyk7CiAgICAgICAgICAgIH0gZWxzZSB7CiAgICAgICAgICAg
ICAgICBzbGljZVswXS5jbGFzc0xpc3QuYWRkKCdxLWZpcnN0Jyk7CiAgICAgICAgICAgICAgICBzbGlj
ZVtzbGljZS5sZW5ndGggLSAxXS5jbGFzc0xpc3QuYWRkKCdxLWxhc3QnKTsKICAgICAgICAgICAgfQog
ICAgICAgICAgICBmb3IgKGxldCBrID0gMDsgayA8IHNsaWNlLmxlbmd0aDsgaysrKSB7CiAgICAgICAg
ICAgICAgICBjb25zdCBkb25lID0gaXRlbUlzUXVldWVEb25lKHNsaWNlW2tdKTsKICAgICAgICAgICAg
ICAgIHNsaWNlW2tdLmNsYXNzTGlzdC50b2dnbGUoJ3EtZG9uZScsIGRvbmUpOwogICAgICAgICAgICAg
ICAgY29uc3QgZG90ID0gc2xpY2Vba10ucXVlcnlTZWxlY3RvcignLnEtZG90Jyk7CiAgICAgICAgICAg
ICAgICBpZiAoZG90KSBkb3QudGl0bGUgPSBkb25lID8gJ+mYn+WIl+W3sueymOi0tCcgOiAn57KY6LS0
6Zif5YiXJzsKICAgICAgICAgICAgICAgIC8vIEdyZWVuIHJhaWwgZm9yIGV2ZXJ5IGl0ZW0gaW4gYSAy
KyBkZXF1ZXVlZCBydW4gKGluY2wuIGZpcnN0L2xhc3Qgc3R1YnMpCiAgICAgICAgICAgICAgICBjb25z
dCBwcmV2RG9uZSA9IGsgPiAwICYmIGl0ZW1Jc1F1ZXVlRG9uZShzbGljZVtrIC0gMV0pOwogICAgICAg
ICAgICAgICAgY29uc3QgbmV4dERvbmUgPSBrIDwgc2xpY2UubGVuZ3RoIC0gMSAmJiBpdGVtSXNRdWV1
ZURvbmUoc2xpY2VbayArIDFdKTsKICAgICAgICAgICAgICAgIGlmIChkb25lICYmIChwcmV2RG9uZSB8
fCBuZXh0RG9uZSkpCiAgICAgICAgICAgICAgICAgICAgc2xpY2Vba10uY2xhc3NMaXN0LmFkZCgncS1k
b25lLWxpbmsnKTsKICAgICAgICAgICAgfQogICAgICAgICAgICBpID0gajsKICAgICAgICB9CiAgICB9
CgogICAgY29uc3QgcGF0aFRpcEVsID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3BhdGgtdGlwJyk7
CiAgICBsZXQgcGF0aFRpcFRpbWVyID0gMDsKICAgIGxldCBwYXRoVGlwSGlkZVRpbWVyID0gMDsKICAg
IGxldCBwYXRoVGlwVG9rZW4gPSAwOwogICAgbGV0IHBhdGhUaXBBbmNob3JCdG4gPSBudWxsOwoKICAg
IGZ1bmN0aW9uIGhpZGVQYXRoVGlwKCkgewogICAgICAgIGNsZWFyVGltZW91dChwYXRoVGlwVGltZXIp
OwogICAgICAgIGNsZWFyVGltZW91dChwYXRoVGlwSGlkZVRpbWVyKTsKICAgICAgICBwYXRoVGlwVG9r
ZW4rKzsKICAgICAgICBpZiAocGF0aFRpcEFuY2hvckJ0bikgewogICAgICAgICAgICBwYXRoVGlwQW5j
aG9yQnRuLmNsYXNzTGlzdC5yZW1vdmUoJ29uJyk7CiAgICAgICAgICAgIHBhdGhUaXBBbmNob3JCdG4g
PSBudWxsOwogICAgICAgIH0KICAgICAgICBpZiAocGF0aFRpcEVsKSB7CiAgICAgICAgICAgIHBhdGhU
aXBFbC5jbGFzc0xpc3QucmVtb3ZlKCdvbicpOwogICAgICAgICAgICBwYXRoVGlwRWwuc2V0QXR0cmli
dXRlKCdhcmlhLWhpZGRlbicsICd0cnVlJyk7CiAgICAgICAgfQogICAgfQogICAgZnVuY3Rpb24gcGxh
Y2VQYXRoVGlwKGFuY2hvckVsKSB7CiAgICAgICAgaWYgKCFwYXRoVGlwRWwgfHwgIWFuY2hvckVsKSBy
ZXR1cm47CiAgICAgICAgY29uc3QgdGlwID0gcGF0aFRpcEVsOwogICAgICAgIGNvbnN0IGFyID0gYW5j
aG9yRWwuZ2V0Qm91bmRpbmdDbGllbnRSZWN0KCk7CiAgICAgICAgY29uc3QgcGFkID0gODsKICAgICAg
ICB0aXAuc3R5bGUubGVmdCA9ICcwcHgnOwogICAgICAgIHRpcC5zdHlsZS50b3AgPSAnMHB4JzsKICAg
ICAgICB0aXAuY2xhc3NMaXN0LmFkZCgnb24nKTsKICAgICAgICBjb25zdCB0dyA9IHRpcC5vZmZzZXRX
aWR0aDsKICAgICAgICBjb25zdCB0aCA9IHRpcC5vZmZzZXRIZWlnaHQ7CiAgICAgICAgbGV0IGxlZnQg
PSBhci5sZWZ0OwogICAgICAgIGxldCB0b3AgPSBhci5ib3R0b20gKyA2OwogICAgICAgIGlmIChsZWZ0
ICsgdHcgPiB3aW5kb3cuaW5uZXJXaWR0aCAtIHBhZCkKICAgICAgICAgICAgbGVmdCA9IE1hdGgubWF4
KHBhZCwgd2luZG93LmlubmVyV2lkdGggLSB0dyAtIHBhZCk7CiAgICAgICAgaWYgKGxlZnQgPCBwYWQp
IGxlZnQgPSBwYWQ7CiAgICAgICAgaWYgKHRvcCArIHRoID4gd2luZG93LmlubmVySGVpZ2h0IC0gcGFk
KQogICAgICAgICAgICB0b3AgPSBNYXRoLm1heChwYWQsIGFyLnRvcCAtIHRoIC0gNik7CiAgICAgICAg
dGlwLnN0eWxlLmxlZnQgPSBsZWZ0ICsgJ3B4JzsKICAgICAgICB0aXAuc3R5bGUudG9wID0gdG9wICsg
J3B4JzsKICAgIH0KICAgICAgICBmdW5jdGlvbiBjaGVja0ZpbGVQYXRocyhwYXRocykgewogICAgICAg
IGNvbnN0IGxpc3QgPSAocGF0aHMgfHwgW10pLm1hcChwID0+IHsKICAgICAgICAgICAgbGV0IHBhdGgg
PSBTdHJpbmcocCB8fCAnJykudHJpbSgpOwogICAgICAgICAgICBpZiAoKHBhdGguc3RhcnRzV2l0aCgn
IicpICYmIHBhdGguZW5kc1dpdGgoJyInKSkgfHwgKHBhdGguc3RhcnRzV2l0aCgiJyIpICYmIHBhdGgu
ZW5kc1dpdGgoIiciKSkpCiAgICAgICAgICAgICAgICBwYXRoID0gcGF0aC5zbGljZSgxLCAtMSkudHJp
bSgpOwogICAgICAgICAgICByZXR1cm4gcGF0aDsKICAgICAgICB9KTsKICAgICAgICAvLyBPbmUgaG9z
dCByb3VuZC10cmlwIGZvciB0aGUgd2hvbGUgbGlzdCDigJQgTsOXIHBhdGhFeGlzdHMgZnJlZXplcyBm
aWxlIHRhYgogICAgICAgIHRyeSB7CiAgICAgICAgICAgIGNvbnN0IHJhdyA9IGFoa1JldCgnY2hlY2tQ
YXRocycsIGxpc3Quam9pbignXG4nKSk7CiAgICAgICAgICAgIGlmIChyYXcpIHsKICAgICAgICAgICAg
ICAgIGNvbnN0IHBhcnNlZCA9IHR5cGVvZiByYXcgPT09ICdzdHJpbmcnID8gSlNPTi5wYXJzZShyYXcp
IDogcmF3OwogICAgICAgICAgICAgICAgaWYgKEFycmF5LmlzQXJyYXkocGFyc2VkKSAmJiBwYXJzZWQu
bGVuZ3RoKSB7CiAgICAgICAgICAgICAgICAgICAgcmV0dXJuIGxpc3QubWFwKChwYXRoLCBpKSA9PiB7
CiAgICAgICAgICAgICAgICAgICAgICAgIGNvbnN0IHJvdyA9IHBhcnNlZFtpXSB8fCB7fTsKICAgICAg
ICAgICAgICAgICAgICAgICAgcmV0dXJuIHsKICAgICAgICAgICAgICAgICAgICAgICAgICAgIHBhdGg6
IHBhdGggfHwgU3RyaW5nKHJvdy5wYXRoIHx8ICcnKSwKICAgICAgICAgICAgICAgICAgICAgICAgICAg
IGV4aXN0czogcm93LmV4aXN0cyA9PT0gdHJ1ZSB8fCByb3cuZXhpc3RzID09PSAxIHx8IHJvdy5leGlz
dHMgPT09ICcxJywKICAgICAgICAgICAgICAgICAgICAgICAgICAgIGlzRGlyOiAhIShyb3cuaXNEaXIg
PT09IHRydWUgfHwgcm93LmlzRGlyID09PSAxIHx8IHJvdy5pc0RpciA9PT0gJzEnKQogICAgICAgICAg
ICAgICAgICAgICAgICB9OwogICAgICAgICAgICAgICAgICAgIH0pOwogICAgICAgICAgICAgICAgfQog
ICAgICAgICAgICB9CiAgICAgICAgfSBjYXRjaCB7fQogICAgICAgIHJldHVybiBsaXN0Lm1hcChwYXRo
ID0+IHsKICAgICAgICAgICAgaWYgKCFwYXRoKSByZXR1cm4geyBwYXRoLCBleGlzdHM6IGZhbHNlLCBp
c0RpcjogZmFsc2UgfTsKICAgICAgICAgICAgbGV0IGV4aXN0cyA9IGZhbHNlOwogICAgICAgICAgICB0
cnkgewogICAgICAgICAgICAgICAgY29uc3QgZmxhZyA9IFN0cmluZyhhaGtSZXQoJ3BhdGhFeGlzdHMn
LCBwYXRoKSA/PyAnJykudHJpbSgpLnRvTG93ZXJDYXNlKCk7CiAgICAgICAgICAgICAgICBleGlzdHMg
PSAoZmxhZyA9PT0gJzEnIHx8IGZsYWcgPT09ICd0cnVlJyk7CiAgICAgICAgICAgIH0gY2F0Y2gge30K
ICAgICAgICAgICAgcmV0dXJuIHsgcGF0aCwgZXhpc3RzLCBpc0RpcjogZmFsc2UgfTsKICAgICAgICB9
KTsKICAgIH0KICAgIGxldCBnb25lQ2hlY2tUaW1lciA9IDA7CiAgICBmdW5jdGlvbiBzY2hlZHVsZUZp
bGVHb25lQ2hlY2soKSB7CiAgICAgICAgaWYgKGdvbmVDaGVja1RpbWVyKSByZXR1cm47CiAgICAgICAg
Z29uZUNoZWNrVGltZXIgPSBzZXRUaW1lb3V0KCgpID0+IHsKICAgICAgICAgICAgZ29uZUNoZWNrVGlt
ZXIgPSAwOwogICAgICAgICAgICBjb25zdCBub2RlcyA9IFsuLi5saXN0RWwucXVlcnlTZWxlY3RvckFs
bCgnLml0bScpXS5maWx0ZXIobiA9PiBuLl9maWxlUGF0aHMgJiYgbi5fZmlsZVBhdGhzLmxlbmd0aCk7
CiAgICAgICAgICAgIGlmICghbm9kZXMubGVuZ3RoKSByZXR1cm47CiAgICAgICAgICAgIGNvbnN0IHVu
aXF1ZSA9IFtdOwogICAgICAgICAgICBjb25zdCBzZWVuID0gbmV3IFNldCgpOwogICAgICAgICAgICBu
b2Rlcy5mb3JFYWNoKG4gPT4gewogICAgICAgICAgICAgICAgbi5fZmlsZVBhdGhzLmZvckVhY2gocCA9
PiB7CiAgICAgICAgICAgICAgICAgICAgY29uc3QgcGF0aCA9IFN0cmluZyhwIHx8ICcnKTsKICAgICAg
ICAgICAgICAgICAgICBpZiAoIXBhdGggfHwgc2Vlbi5oYXMocGF0aCkpIHJldHVybjsKICAgICAgICAg
ICAgICAgICAgICBzZWVuLmFkZChwYXRoKTsKICAgICAgICAgICAgICAgICAgICB1bmlxdWUucHVzaChw
YXRoKTsKICAgICAgICAgICAgICAgIH0pOwogICAgICAgICAgICB9KTsKICAgICAgICAgICAgY29uc3Qg
cm93cyA9IGNoZWNrRmlsZVBhdGhzKHVuaXF1ZSk7CiAgICAgICAgICAgIGNvbnN0IGJ5UGF0aCA9IG5l
dyBNYXAoKTsKICAgICAgICAgICAgcm93cy5mb3JFYWNoKHIgPT4gYnlQYXRoLnNldChTdHJpbmcoci5w
YXRoIHx8ICcnKSwgcikpOwogICAgICAgICAgICBub2Rlcy5mb3JFYWNoKG4gPT4gewogICAgICAgICAg
ICAgICAgY29uc3QgcGF0aFJvd3MgPSBuLl9maWxlUGF0aHMubWFwKHAgPT4gewogICAgICAgICAgICAg
ICAgICAgIGNvbnN0IGhpdCA9IGJ5UGF0aC5nZXQoU3RyaW5nKHAgfHwgJycpKTsKICAgICAgICAgICAg
ICAgICAgICByZXR1cm4gaGl0IHx8IHsgcGF0aDogcCwgZXhpc3RzOiB0cnVlLCBpc0RpcjogZmFsc2Ug
fTsKICAgICAgICAgICAgICAgIH0pOwogICAgICAgICAgICAgICAgbi5fcGF0aFJvd3MgPSBwYXRoUm93
czsKICAgICAgICAgICAgICAgIGNvbnN0IGFsbEdvbmUgPSBwYXRoUm93cy5sZW5ndGggPiAwICYmIHBh
dGhSb3dzLmV2ZXJ5KHIgPT4gci5leGlzdHMgPT09IGZhbHNlKTsKICAgICAgICAgICAgICAgIG4uY2xh
c3NMaXN0LnRvZ2dsZSgnZ29uZScsIGFsbEdvbmUpOwogICAgICAgICAgICB9KTsKICAgICAgICB9LCA0
MDApOwogICAgfQogICAgZnVuY3Rpb24gZmlsbEZpbGVEZXRhaWxQYW5lbChjb250YWluZXIsIHJvd3Mp
IHsKICAgICAgICBjb250YWluZXIuaW5uZXJIVE1MID0gJyc7CiAgICAgICAgaWYgKCFyb3dzLmxlbmd0
aCkgewogICAgICAgICAgICBjb25zdCBlbXB0eSA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2Rpdicp
OwogICAgICAgICAgICBlbXB0eS5jbGFzc05hbWUgPSAnZmQtcGF0aCc7CiAgICAgICAgICAgIGVtcHR5
LnRleHRDb250ZW50ID0gJ+aXoOi3r+W+hCc7CiAgICAgICAgICAgIGNvbnRhaW5lci5hcHBlbmRDaGls
ZChlbXB0eSk7CiAgICAgICAgICAgIHJldHVybjsKICAgICAgICB9CiAgICAgICAgcm93cy5mb3JFYWNo
KHIgPT4gewogICAgICAgICAgICBjb25zdCBwYXRoID0gU3RyaW5nKHIucGF0aCB8fCAnJyk7CiAgICAg
ICAgICAgIGNvbnN0IG1pc3NpbmcgPSByLmV4aXN0cyA9PT0gZmFsc2U7CiAgICAgICAgICAgIGNvbnN0
IGJsb2NrID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnZGl2Jyk7CiAgICAgICAgICAgIGJsb2NrLmNs
YXNzTmFtZSA9ICdmZC1ibG9jayc7CgogICAgICAgICAgICBjb25zdCBwYXRoRWwgPSBkb2N1bWVudC5j
cmVhdGVFbGVtZW50KCdkaXYnKTsKICAgICAgICAgICAgcGF0aEVsLmNsYXNzTmFtZSA9ICdmZC1wYXRo
JyArIChtaXNzaW5nID8gJyBkZWFkJyA6ICcgbGl2ZScpOwogICAgICAgICAgICBwYXRoRWwudGV4dENv
bnRlbnQgPSBwYXRoIHx8ICco56m66Lev5b6EKSc7CiAgICAgICAgICAgIGlmICghbWlzc2luZykgewog
ICAgICAgICAgICAgICAgcGF0aEVsLm9uY2xpY2sgPSBlID0+IHsKICAgICAgICAgICAgICAgICAgICBl
LnByZXZlbnREZWZhdWx0KCk7CiAgICAgICAgICAgICAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsK
ICAgICAgICAgICAgICAgICAgICBhaGsoJ29wZW5QYXRoJywgcGF0aCk7CiAgICAgICAgICAgICAgICB9
OwogICAgICAgICAgICB9CiAgICAgICAgICAgIGJsb2NrLmFwcGVuZENoaWxkKHBhdGhFbCk7CgogICAg
ICAgICAgICBjb25zdCBhY3Rpb25zID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnZGl2Jyk7CiAgICAg
ICAgICAgIGFjdGlvbnMuY2xhc3NOYW1lID0gJ2ZkLWFjdGlvbnMnOwoKICAgICAgICAgICAgY29uc3Qg
Y29weUJ0biA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2J1dHRvbicpOwogICAgICAgICAgICBjb3B5
QnRuLnR5cGUgPSAnYnV0dG9uJzsKICAgICAgICAgICAgY29weUJ0bi5jbGFzc05hbWUgPSAnZmQtYnRu
JzsKICAgICAgICAgICAgY29weUJ0bi5pbm5lckhUTUwgPSAnPHNwYW4gY2xhc3M9ImZkLWljbyI+8J+U
lzwvc3Bhbj48c3BhbiBjbGFzcz0iZmQtdHh0Ij7lpI3liLbot6/lvoQ8L3NwYW4+JzsKICAgICAgICAg
ICAgY29weUJ0bi5vbmNsaWNrID0gZSA9PiB7CiAgICAgICAgICAgICAgICBlLnByZXZlbnREZWZhdWx0
KCk7CiAgICAgICAgICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgICAgICAgICAgICAgYWhr
KCdjb3B5UGF0aCcsIHBhdGgpOwogICAgICAgICAgICAgICAgY29weUJ0bi5xdWVyeVNlbGVjdG9yKCcu
ZmQtdHh0JykudGV4dENvbnRlbnQgPSAn5bey5aSN5Yi2JzsKICAgICAgICAgICAgICAgIGNvcHlCdG4u
Y2xhc3NMaXN0LmFkZCgnb2snKTsKICAgICAgICAgICAgICAgIHNldFRpbWVvdXQoKCkgPT4gewogICAg
ICAgICAgICAgICAgICAgIGNvcHlCdG4ucXVlcnlTZWxlY3RvcignLmZkLXR4dCcpLnRleHRDb250ZW50
ID0gJ+WkjeWItui3r+W+hCc7CiAgICAgICAgICAgICAgICAgICAgY29weUJ0bi5jbGFzc0xpc3QucmVt
b3ZlKCdvaycpOwogICAgICAgICAgICAgICAgfSwgMTIwMCk7CiAgICAgICAgICAgIH07CiAgICAgICAg
ICAgIGFjdGlvbnMuYXBwZW5kQ2hpbGQoY29weUJ0bik7CgogICAgICAgICAgICBjb25zdCBmb2xkZXJC
dG4gPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdidXR0b24nKTsKICAgICAgICAgICAgZm9sZGVyQnRu
LnR5cGUgPSAnYnV0dG9uJzsKICAgICAgICAgICAgZm9sZGVyQnRuLmNsYXNzTmFtZSA9ICdmZC1idG4n
OwogICAgICAgICAgICBmb2xkZXJCdG4uaW5uZXJIVE1MID0gJzxzcGFuIGNsYXNzPSJmZC1pY28iPvCf
k4I8L3NwYW4+PHNwYW4gY2xhc3M9ImZkLXR4dCI+5omT5byA5omA5Zyo5paH5Lu25aS5PC9zcGFuPic7
CiAgICAgICAgICAgIGZvbGRlckJ0bi5vbmNsaWNrID0gZSA9PiB7CiAgICAgICAgICAgICAgICBlLnBy
ZXZlbnREZWZhdWx0KCk7CiAgICAgICAgICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgICAg
ICAgICAgICAgYWhrKCdvcGVuRm9sZGVyJywgcGF0aCk7CiAgICAgICAgICAgIH07CiAgICAgICAgICAg
IGFjdGlvbnMuYXBwZW5kQ2hpbGQoZm9sZGVyQnRuKTsKCiAgICAgICAgICAgIGJsb2NrLmFwcGVuZENo
aWxkKGFjdGlvbnMpOwogICAgICAgICAgICBjb250YWluZXIuYXBwZW5kQ2hpbGQoYmxvY2spOwogICAg
ICAgIH0pOwogICAgfQoKICAgIGNvbnN0IGN0eEVsID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2N0
eCcpOwogICAgZnVuY3Rpb24gc2hvd0N0eCh4LCB5LCBjKSB7CiAgICAgICAgY3R4Q2xpcCA9IGM7CiAg
ICAgICAgc2VsZWN0ZWRJZCA9IGMuaWQ7CiAgICAgICAgcmFuZ2VBbmNob3JJZCA9IGMuaWQ7CiAgICAg
ICAgcmFuZ2VBbmNob3JDbGlja2VkID0gdHJ1ZTsKICAgICAgICBjb25zdCBjbGVhckJ0biA9IGRvY3Vt
ZW50LmdldEVsZW1lbnRCeUlkKCdjLWNsZWFyLXBhc3RlZCcpOwogICAgICAgIGlmIChjbGVhckJ0bikg
Y2xlYXJCdG4uc3R5bGUuZGlzcGxheSA9IGlzUGFzdGVkKGMpID8gJycgOiAnbm9uZSc7CiAgICAgICAg
Y29uc3QgcUZyb20gPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYy1xdWV1ZS1mcm9tJyk7CiAgICAg
ICAgaWYgKHFGcm9tKSBxRnJvbS5zdHlsZS5kaXNwbGF5ID0gKE51bWJlcihjLnF1ZXVlR3JvdXApID4g
MCkgPyAnJyA6ICdub25lJzsKCiAgICAgICAgY29uc3QgcGluQnRuID0gZG9jdW1lbnQuZ2V0RWxlbWVu
dEJ5SWQoJ2MtcGluJyk7CiAgICAgICAgY29uc3QgY29weUJ0biA9IGRvY3VtZW50LmdldEVsZW1lbnRC
eUlkKCdjLWNvcHknKTsKICAgICAgICBjb25zdCBpc1JlY2VudCA9IG5vcm1UeXBlKGMudHlwZSkgPT09
ICdyZWNlbnQnIHx8IGN1clRhYiA9PT0gJ3JlY2VudCc7CiAgICAgICAgaWYgKGNvcHlCdG4pIHsKICAg
ICAgICAgICAgY29weUJ0bi5pbm5lckhUTUwgPSBpc1JlY2VudAogICAgICAgICAgICAgICAgPyAnPHNw
YW4gY2xhc3M9ImMtaWNvIj7wn5SXPC9zcGFuPuWkjeWItui3r+W+hCcKICAgICAgICAgICAgICAgIDog
JzxzcGFuIGNsYXNzPSJjLWljbyI+4o6YPC9zcGFuPuWkjeWItic7CiAgICAgICAgICAgIGNvcHlCdG4u
c3R5bGUuZGlzcGxheSA9ICcnOwogICAgICAgIH0KICAgICAgICBpZiAocGluQnRuKSB7CiAgICAgICAg
ICAgIGlmIChpc1JlY2VudCkgewogICAgICAgICAgICAgICAgLy8gUmVjZW50IGZvbGRlcnM6IHBpbiA9
IGtlZXAgcGF0aCAobm90IGNsaXBib2FyZCDmlLbol48pCiAgICAgICAgICAgICAgICBwaW5CdG4uc3R5
bGUuZGlzcGxheSA9ICcnOwogICAgICAgICAgICAgICAgY29uc3Qgb24gPSBpc1Bpbm5lZChjKTsKICAg
ICAgICAgICAgICAgIHBpbkJ0bi5pbm5lckhUTUwgPSBvbgogICAgICAgICAgICAgICAgICAgID8gJzxz
cGFuIGNsYXNzPSJjLWljbyI+4piFPC9zcGFuPuWPlua2iOWbuuWumicKICAgICAgICAgICAgICAgICAg
ICA6ICc8c3BhbiBjbGFzcz0iYy1pY28iPuKYhTwvc3Bhbj7lm7rlrprot6/lvoQnOwogICAgICAgICAg
ICB9IGVsc2UgewogICAgICAgICAgICAgICAgcGluQnRuLnN0eWxlLmRpc3BsYXkgPSAnJzsKICAgICAg
ICAgICAgICAgIGNvbnN0IG9uID0gaXNQaW5uZWQoYyk7CiAgICAgICAgICAgICAgICBwaW5CdG4uaW5u
ZXJIVE1MID0gb24KICAgICAgICAgICAgICAgICAgICA/ICc8c3BhbiBjbGFzcz0iYy1pY28iPuKYhTwv
c3Bhbj7lj5bmtojmlLbol48nCiAgICAgICAgICAgICAgICAgICAgOiAnPHNwYW4gY2xhc3M9ImMtaWNv
Ij7imIU8L3NwYW4+5pS26JePJzsKICAgICAgICAgICAgfQogICAgICAgIH0KICAgICAgICBjb25zdCB0
aXRsZUJ0biA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjLXRpdGxlJyk7CiAgICAgICAgaWYgKHRp
dGxlQnRuKSB7CiAgICAgICAgICAgIC8vIE5vIGZhdi10aXRsZSBmb3IgcmVjZW50IHBhdGhzCiAgICAg
ICAgICAgIGNvbnN0IHNob3dUaXRsZSA9ICFpc1JlY2VudCAmJiAoaXNQaW5uZWQoYykgfHwgY3VyVGFi
ID09PSAncGlubmVkJyk7CiAgICAgICAgICAgIHRpdGxlQnRuLnN0eWxlLmRpc3BsYXkgPSBzaG93VGl0
bGUgPyAnJyA6ICdub25lJzsKICAgICAgICAgICAgaWYgKHNob3dUaXRsZSkKICAgICAgICAgICAgICAg
IHRpdGxlQnRuLmlubmVySFRNTCA9IChTdHJpbmcoYy5mYXZUaXRsZSB8fCAnJykudHJpbSgpID8gJzxz
cGFuIGNsYXNzPSJjLWljbyI+4pyOPC9zcGFuPue8lui+keagh+mimCcgOiAnPHNwYW4gY2xhc3M9ImMt
aWNvIj7inI48L3NwYW4+6K6+572u5qCH6aKYJyk7CiAgICAgICAgfQogICAgICAgIGNvbnN0IG1lcmdl
QnRuID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2MtbWVyZ2UnKTsKICAgICAgICBjb25zdCB1bm1l
cmdlQnRuID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2MtdW5tZXJnZScpOwogICAgICAgIGNvbnN0
IG9uUGlubmVkID0gY3VyVGFiID09PSAncGlubmVkJzsKICAgICAgICBpZiAobWVyZ2VCdG4pCiAgICAg
ICAgICAgIG1lcmdlQnRuLnN0eWxlLmRpc3BsYXkgPSAoIWlzUmVjZW50ICYmIG9uUGlubmVkICYmIG11
bHRpSWRzLmxlbmd0aCA+PSAyKSA/ICcnIDogJ25vbmUnOwogICAgICAgIGlmICh1bm1lcmdlQnRuKQog
ICAgICAgICAgICB1bm1lcmdlQnRuLnN0eWxlLmRpc3BsYXkgPSAoIWlzUmVjZW50ICYmIG9uUGlubmVk
ICYmIGZhdkdyb3VwT2YoYykpID8gJycgOiAnbm9uZSc7CiAgICAgICAgY29uc3QgdG9wQnRuID0gZG9j
dW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2MtdG9wJyk7CiAgICAgICAgaWYgKHRvcEJ0bikKICAgICAgICAg
ICAgdG9wQnRuLnN0eWxlLmRpc3BsYXkgPSBpc1JlY2VudCA/ICdub25lJyA6ICcnOwogICAgICAgIGNv
bnN0IGNsZWFyQnRuMiA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjLWNsZWFyLXBhc3RlZCcpOwog
ICAgICAgIGlmIChjbGVhckJ0bjIgJiYgaXNSZWNlbnQpCiAgICAgICAgICAgIGNsZWFyQnRuMi5zdHls
ZS5kaXNwbGF5ID0gJ25vbmUnOwogICAgICAgIGNvbnN0IHFGcm9tMiA9IGRvY3VtZW50LmdldEVsZW1l
bnRCeUlkKCdjLXF1ZXVlLWZyb20nKTsKICAgICAgICBpZiAocUZyb20yICYmIGlzUmVjZW50KQogICAg
ICAgICAgICBxRnJvbTIuc3R5bGUuZGlzcGxheSA9ICdub25lJzsKICAgICAgICBjb25zdCBkZWxCdG4g
PSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYy1kZWwnKTsKICAgICAgICBpZiAoZGVsQnRuKSB7CiAg
ICAgICAgICAgIGNvbnN0IG11bHRpRGVsID0gbXVsdGlJZHMubGVuZ3RoID4gMSAmJiBtdWx0aUlkcy5p
bmNsdWRlcygrYy5pZCk7CiAgICAgICAgICAgIGNvbnN0IG4gPSBtdWx0aURlbCA/IG11bHRpSWRzLmxl
bmd0aCA6IDE7CiAgICAgICAgICAgIGRlbEJ0bi5pbm5lckhUTUwgPSBuID4gMQogICAgICAgICAgICAg
ICAgPyAoJzxzcGFuIGNsYXNzPSJjLWljbyI+4pyVPC9zcGFuPuWIoOmZpCAoJyArIG4gKyAnKScpCiAg
ICAgICAgICAgICAgICA6ICc8c3BhbiBjbGFzcz0iYy1pY28iPuKclTwvc3Bhbj7liKDpmaQnOwogICAg
ICAgIH0KICAgICAgICBjdHhFbC5jbGFzc0xpc3QuYWRkKCdvbicpOwogICAgICAgIGN0eEVsLnN0eWxl
LmxlZnQgPSB4ICsgJ3B4JzsKICAgICAgICBjdHhFbC5zdHlsZS50b3AgID0geSArICdweCc7CiAgICAg
ICAgcmVxdWVzdEFuaW1hdGlvbkZyYW1lKCgpID0+IHsKICAgICAgICAgICAgY29uc3QgciA9IGN0eEVs
LmdldEJvdW5kaW5nQ2xpZW50UmVjdCgpOwogICAgICAgICAgICBpZiAoci5yaWdodCAgPiBpbm5lcldp
ZHRoKSAgY3R4RWwuc3R5bGUubGVmdCA9ICh4IC0gci53aWR0aCkgICsgJ3B4JzsKICAgICAgICAgICAg
aWYgKHIuYm90dG9tID4gaW5uZXJIZWlnaHQpIGN0eEVsLnN0eWxlLnRvcCAgPSAoeSAtIHIuaGVpZ2h0
KSArICdweCc7CiAgICAgICAgfSk7CiAgICB9CiAgICBmdW5jdGlvbiBoaWRlQ3R4KCkgeyBjdHhFbC5j
bGFzc0xpc3QucmVtb3ZlKCdvbicpOyBjdHhDbGlwID0gbnVsbDsgfQogICAgd2luZG93Ll9faGlkZUN0
eCA9IGhpZGVDdHg7CgogICAgZnVuY3Rpb24gZGlzbWlzc0N0eFVubGVzc0luc2lkZShlKSB7CiAgICAg
ICAgaWYgKCFjdHhFbC5jbGFzc0xpc3QuY29udGFpbnMoJ29uJykpIHJldHVybjsKICAgICAgICBpZiAo
ZS50YXJnZXQuY2xvc2VzdCgnI2N0eCcpKSByZXR1cm47CiAgICAgICAgaGlkZUN0eCgpOwogICAgfQog
ICAgZG9jdW1lbnQuYWRkRXZlbnRMaXN0ZW5lcignbW91c2Vkb3duJywgZGlzbWlzc0N0eFVubGVzc0lu
c2lkZSwgdHJ1ZSk7CiAgICBkb2N1bWVudC5hZGRFdmVudExpc3RlbmVyKCdjbGljaycsIGRpc21pc3ND
dHhVbmxlc3NJbnNpZGUsIHRydWUpOwogICAgbGlzdEVsLmFkZEV2ZW50TGlzdGVuZXIoJ3Njcm9sbCcs
IGhpZGVDdHgsIHsgcGFzc2l2ZTogdHJ1ZSB9KTsKICAgIGRvY3VtZW50LmFkZEV2ZW50TGlzdGVuZXIo
J2tleWRvd24nLCBlID0+IHsKICAgICAgICAvLyBFc2M6IGFsd2F5cyBjbG9zZSBwYW5lbCAoc2VhcmNo
IG9yIG5vdCk7IHBpbiBrZWVwcyBwYW5lbAogICAgICAgIGlmIChlLmtleSA9PT0gJ0VzY2FwZScpIHsK
ICAgICAgICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOwogICAgICAgICAgICBoaWRlQ3R4KCk7CiAgICAg
ICAgICAgIGNvbnN0IHRkID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3RpdGxlLWRsZycpOwogICAg
ICAgICAgICBpZiAodGQgJiYgdGQuY2xhc3NMaXN0LmNvbnRhaW5zKCdvbicpKSB7CiAgICAgICAgICAg
ICAgICB0cnkgeyBjbG9zZVRpdGxlRGxnKCk7IH0gY2F0Y2ggeyB0ZC5jbGFzc0xpc3QucmVtb3ZlKCdv
bicpOyB9CiAgICAgICAgICAgICAgICByZXR1cm47CiAgICAgICAgICAgIH0KICAgICAgICAgICAgaWYg
KGNsckRsZy5jbGFzc0xpc3QuY29udGFpbnMoJ29uJykpIHsKICAgICAgICAgICAgICAgIGNsb3NlQ2xl
YXJEbGcoKTsKICAgICAgICAgICAgICAgIHJldHVybjsKICAgICAgICAgICAgfQogICAgICAgICAgICBp
ZiAoIXBpbm5lZFVJKSBhaGsoJ2hpZGUnKTsKICAgICAgICAgICAgcmV0dXJuOwogICAgICAgIH0KICAg
ICAgICAvLyBXaGlsZSB0eXBpbmcgaW4gc2VhcmNoOiBDdHJsK0kvSyBhbmQgYXJyb3dzIG1vdmUgbGlz
dCwgZG9uJ3QgbGVhdmUgdGhlIGJveAogICAgICAgIGlmIChkb2N1bWVudC5hY3RpdmVFbGVtZW50Py5p
ZCA9PT0gJ3NlYXJjaCcpIHsKICAgICAgICAgICAgaWYgKChlLmN0cmxLZXkgfHwgZS5tZXRhS2V5KSAm
JiAoZS5rZXkgPT09ICdpJyB8fCBlLmtleSA9PT0gJ0knKSkgewogICAgICAgICAgICAgICAgZS5wcmV2
ZW50RGVmYXVsdCgpOyBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgICAgICAgICAgICAgd2luZG93Ll9f
bmF2ICYmIHdpbmRvdy5fX25hdigndXAnKTsKICAgICAgICAgICAgICAgIHJldHVybjsKICAgICAgICAg
ICAgfQogICAgICAgICAgICBpZiAoKGUuY3RybEtleSB8fCBlLm1ldGFLZXkpICYmIChlLmtleSA9PT0g
J2snIHx8IGUua2V5ID09PSAnSycpKSB7CiAgICAgICAgICAgICAgICBlLnByZXZlbnREZWZhdWx0KCk7
IGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAgICAgICAgICAgICB3aW5kb3cuX19uYXYgJiYgd2luZG93
Ll9fbmF2KCdkb3duJyk7CiAgICAgICAgICAgICAgICByZXR1cm47CiAgICAgICAgICAgIH0KICAgICAg
ICAgICAgaWYgKGUua2V5ID09PSAnQXJyb3dEb3duJykgewogICAgICAgICAgICAgICAgZS5wcmV2ZW50
RGVmYXVsdCgpOyBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgICAgICAgICAgICAgd2luZG93Ll9fbmF2
ICYmIHdpbmRvdy5fX25hdignZG93bicpOwogICAgICAgICAgICAgICAgcmV0dXJuOwogICAgICAgICAg
ICB9CiAgICAgICAgICAgIGlmIChlLmtleSA9PT0gJ0Fycm93VXAnKSB7CiAgICAgICAgICAgICAgICBl
LnByZXZlbnREZWZhdWx0KCk7IGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAgICAgICAgICAgICB3aW5k
b3cuX19uYXYgJiYgd2luZG93Ll9fbmF2KCd1cCcpOwogICAgICAgICAgICAgICAgcmV0dXJuOwogICAg
ICAgICAgICB9CiAgICAgICAgICAgIHJldHVybjsKICAgICAgICB9CiAgICAgICAgY29uc3QgdmlzID0g
KHR5cGVvZiBuYXZMaXN0ID09PSAnZnVuY3Rpb24nID8gbmF2TGlzdCgpIDogdmlzaWJsZUxpc3QoKSk7
CiAgICAgICAgaWYgKCF2aXMubGVuZ3RoKSByZXR1cm47CiAgICAgICAgbGV0IGlkeCA9IHNlbGVjdGVk
SW5kZXgoKTsKICAgICAgICBpZiAoaWR4IDwgMCkgaWR4ID0gMDsKICAgICAgICBpZiAgICAgIChlLmtl
eSA9PT0gJ0Fycm93RG93bicpIHsgZS5wcmV2ZW50RGVmYXVsdCgpOyBlLnN0b3BQcm9wYWdhdGlvbigp
OyBzZWxlY3RCeUluZGV4KGlkeCArIDEpOyB9CiAgICAgICAgZWxzZSBpZiAoZS5rZXkgPT09ICdBcnJv
d1VwJykgICB7IGUucHJldmVudERlZmF1bHQoKTsgZS5zdG9wUHJvcGFnYXRpb24oKTsgc2VsZWN0QnlJ
bmRleChpZHggLSAxKTsgfQogICAgICAgIGVsc2UgaWYgKGUua2V5ID09PSAnRW50ZXInKSB7CiAgICAg
ICAgICAgIGUucHJldmVudERlZmF1bHQoKTsKICAgICAgICAgICAgLy8g5Zu65a6a5pe25Zue6L2m5LiN
57KY6LS077yM5Y+q54K55p2h55uu57KY6LS0CiAgICAgICAgICAgIGlmIChwaW5uZWRVSSkgcmV0dXJu
OwogICAgICAgICAgICBpZiAobXVsdGlJZHMubGVuZ3RoID49IDEpIHsKICAgICAgICAgICAgICAgIGNv
bnN0IGlkcyA9IG11bHRpSWRzLnNsaWNlKCk7CiAgICAgICAgICAgICAgICBjbGVhck11bHRpKCk7CiAg
ICAgICAgICAgICAgICBtYXJrUGFzdGVkTG9jYWwoaWRzKTsKICAgICAgICAgICAgICAgIHBhc3RlTWFu
eVdpdGhTZXAoaWRzKTsKICAgICAgICAgICAgICAgIHJldHVybjsKICAgICAgICAgICAgfQogICAgICAg
ICAgICBjb25zdCBjID0gdmlzW3NlbGVjdGVkSW5kZXgoKV07CiAgICAgICAgICAgIGlmIChjKSB7CiAg
ICAgICAgICAgICAgICBtYXJrUGFzdGVkTG9jYWwoYy5pZCk7CiAgICAgICAgICAgICAgICBhaGsoJ3Bh
c3RlJywgU3RyaW5nKGMuaWQpKTsKICAgICAgICAgICAgfQogICAgICAgIH0gZWxzZSBpZiAoL15bMS05
XSQvLnRlc3QoZS5rZXkpKSB7CiAgICAgICAgICAgIGNvbnN0IGMgPSB2aXNbK2Uua2V5IC0gMV07CiAg
ICAgICAgICAgIGlmIChjKSB7CiAgICAgICAgICAgICAgICBtYXJrUGFzdGVkTG9jYWwoYy5pZCk7CiAg
ICAgICAgICAgICAgICBhaGsoJ3Bhc3RlJywgU3RyaW5nKGMuaWQpKTsKICAgICAgICAgICAgfQogICAg
ICAgIH0KICAgIH0pOwoKICAgIHdpbmRvdy5fX25hdiA9IGRpciA9PiB7CiAgICAgICAgY29uc3Qgdmlz
ID0gKHR5cGVvZiBuYXZMaXN0ID09PSAnZnVuY3Rpb24nID8gbmF2TGlzdCgpIDogdmlzaWJsZUxpc3Qo
KSk7CiAgICAgICAgaWYgKCF2aXMubGVuZ3RoICYmIGRpciAhPT0gJ3RhYicgJiYgZGlyICE9PSAndGFi
UHJldicpIHJldHVybjsKICAgICAgICBsZXQgaWR4ID0gc2VsZWN0ZWRJbmRleCgpOwogICAgICAgIGlm
IChpZHggPCAwKSBpZHggPSAwOwogICAgICAgIGlmIChkaXIgPT09ICd1cCcpIHNlbGVjdEJ5SW5kZXgo
aWR4IC0gMSk7CiAgICAgICAgZWxzZSBpZiAoZGlyID09PSAnZG93bicpIHNlbGVjdEJ5SW5kZXgoaWR4
ICsgMSk7CiAgICAgICAgZWxzZSBpZiAoZGlyID09PSAnZW50ZXInKSB7CiAgICAgICAgICAgIGlmIChw
aW5uZWRVSSkgcmV0dXJuOwogICAgICAgICAgICBfX3ByZXBQYXN0ZSgpOwogICAgICAgICAgICBpZiAo
bXVsdGlJZHMubGVuZ3RoID49IDEpIHsKICAgICAgICAgICAgICAgIGNvbnN0IGlkcyA9IG11bHRpSWRz
LnNsaWNlKCk7CiAgICAgICAgICAgICAgICBjbGVhck11bHRpKCk7CiAgICAgICAgICAgICAgICBtYXJr
UGFzdGVkTG9jYWwoaWRzKTsKICAgICAgICAgICAgICAgIHBhc3RlTWFueVdpdGhTZXAoaWRzKTsKICAg
ICAgICAgICAgICAgIHJldHVybjsKICAgICAgICAgICAgfQogICAgICAgICAgICBjb25zdCBjID0gdmlz
W3NlbGVjdGVkSW5kZXgoKV07CiAgICAgICAgICAgIGlmIChjKSB7CiAgICAgICAgICAgICAgICBtYXJr
UGFzdGVkTG9jYWwoYy5pZCk7CiAgICAgICAgICAgICAgICBhaGsoJ3Bhc3RlJywgU3RyaW5nKGMuaWQp
KTsKICAgICAgICAgICAgfQogICAgICAgIH0KICAgIH07CgogICAgLy8gQUhLIEVudGVyIGhvdGtleSBs
YW5kcyBoZXJlIChXZWJWaWV3IG1heSBub3QgcmVjZWl2ZSB0aGUga2V5IHdoaWxlIHVucGlubmVkKQog
ICAgd2luZG93Ll9fZWRpdFRpdGxlID0gKCkgPT4gewogICAgICAgIGxldCBjID0gbnVsbDsKICAgICAg
ICBpZiAoc2VsZWN0ZWRJZCkKICAgICAgICAgICAgYyA9IGFsbENsaXBzLmZpbmQoeCA9PiAreC5pZCA9
PT0gK3NlbGVjdGVkSWQpIHx8IG51bGw7CiAgICAgICAgaWYgKCFjICYmIGN0eENsaXApCiAgICAgICAg
ICAgIGMgPSBjdHhDbGlwOwogICAgICAgIGlmICghYykgewogICAgICAgICAgICBjb25zdCB2aXMgPSB2
aXNpYmxlTGlzdCgpOwogICAgICAgICAgICBpZiAodmlzLmxlbmd0aCkgYyA9IHZpc1swXTsKICAgICAg
ICB9CiAgICAgICAgaWYgKCFjKSByZXR1cm47CiAgICAgICAgb3BlblRpdGxlRGxnKGMpOwogICAgfTsK
CiAgICB3aW5kb3cuX19vbkVudGVyID0gKCkgPT4gewogICAgICAgIGNvbnN0IHRkID0gZG9jdW1lbnQu
Z2V0RWxlbWVudEJ5SWQoJ3RpdGxlLWRsZycpOwogICAgICAgIGlmICh0ZCAmJiB0ZC5jbGFzc0xpc3Qu
Y29udGFpbnMoJ29uJykpIHsKICAgICAgICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3RpdGxl
LW9rJyk/LmNsaWNrKCk7CiAgICAgICAgICAgIHJldHVybjsKICAgICAgICB9CiAgICAgICAgaWYgKGRv
Y3VtZW50LmFjdGl2ZUVsZW1lbnQ/LmlkID09PSAndGl0bGUtaW5wdXQnKSB7CiAgICAgICAgICAgIGRv
Y3VtZW50LmdldEVsZW1lbnRCeUlkKCd0aXRsZS1vaycpPy5jbGljaygpOwogICAgICAgICAgICByZXR1
cm47CiAgICAgICAgfQogICAgICAgIC8vIOiHquWumuS5ieWIhumalOespu+8muacquWbuuWumuaXtiBB
SEsg5Lya5oqiIEVudGVyCiAgICAgICAgY29uc3Qgc2VwTWVudSA9IGRvY3VtZW50LmdldEVsZW1lbnRC
eUlkKCdwYXN0ZS1zZXAtbWVudScpOwogICAgICAgIGNvbnN0IHNlcElucCA9IGRvY3VtZW50LmdldEVs
ZW1lbnRCeUlkKCdwYXN0ZS1zZXAtY3VzdG9tJyk7CiAgICAgICAgaWYgKHNlcE1lbnUgJiYgc2VwTWVu
dS5jbGFzc0xpc3QuY29udGFpbnMoJ29uJykgJiYgc2VwSW5wKSB7CiAgICAgICAgICAgIGlmIChTdHJp
bmcoc2VwSW5wLnZhbHVlIHx8ICcnKSAhPT0gJycpIGFwcGx5U2VwYXJhdG9yKHNlcElucC52YWx1ZSk7
CiAgICAgICAgICAgIGVsc2UgY2xvc2VTZXBNZW51KCk7CiAgICAgICAgICAgIHJldHVybjsKICAgICAg
ICB9CiAgICAgICAgLy8g5Zu65a6a5pe25Zue6L2m5LiN57KY6LS0CiAgICAgICAgaWYgKHBpbm5lZFVJ
KSByZXR1cm47CiAgICAgICAgLy8gVHlwaW5nIGluIHNlYXJjaDogRW50ZXIgc2hvdWxkIHBhc3RlIHNl
bGVjdGVkIGl0ZW0KICAgICAgICBpZiAoZG9jdW1lbnQuYWN0aXZlRWxlbWVudD8uaWQgPT09ICdzZWFy
Y2gnKSB7CiAgICAgICAgICAgIHdpbmRvdy5fX25hdiAmJiB3aW5kb3cuX19uYXYoJ2VudGVyJyk7CiAg
ICAgICAgICAgIHJldHVybjsKICAgICAgICB9CiAgICAgICAgd2luZG93Ll9fbmF2ICYmIHdpbmRvdy5f
X25hdignZW50ZXInKTsKICAgIH07CgogICAgd2luZG93Ll9fY3ljbGVUYWIgPSBkaXIgPT4gewogICAg
ICAgIGNvbnN0IGkgPSBNYXRoLm1heCgwLCBUQUJfT1JERVIuaW5kZXhPZihjdXJUYWIpKTsKICAgICAg
ICBjb25zdCBuZXh0ID0gVEFCX09SREVSWyhpICsgKGRpciB8IDApICsgVEFCX09SREVSLmxlbmd0aCAq
IDEwKSAlIFRBQl9PUkRFUi5sZW5ndGhdOwogICAgICAgIHNldFRhYihuZXh0KTsKICAgIH07CiAgICB3
aW5kb3cuX19vblBhbmVsU2hvdyA9IChrZWVwU2VhcmNoKSA9PiB7CiAgICAgICAgd2luZG93Ll9fcGVy
Zk1hcmsgJiYgd2luZG93Ll9fcGVyZk1hcmsoJ2pzX29uUGFuZWxTaG93IGtlZXBTZWFyY2g9JyArICgh
IWtlZXBTZWFyY2gpKTsKICAgICAgICB0cnkgeyByZXNldFBhc3RlU2VwRGVmYXVsdCgpOyB9IGNhdGNo
IHt9CiAgICAgICAgLy8gRG8gTk9UIGZvY3VzIFdlYlZpZXcg4oCUIGtlZXAgZWRpdG9yIGNhcmV0L2Zv
Y3VzIChBSEsgaGFuZGxlcyBrZXlzIHZpYSAjSG90SWYpCiAgICAgICAgLy8gV2luK1Y6IGNvbGxhcHNl
IHNlYXJjaC4gPz8gc2VhcmNoOiBrZWVwL29wZW4gc2VhcmNoIGJveC4KICAgICAgICBrZWVwU2VhcmNo
ID0gISFrZWVwU2VhcmNoOwogICAgICAgIHRyeSB7IGhpZGVDdHgoKTsgfSBjYXRjaCB7fQogICAgICAg
IHRyeSB7IGNsb3NlVGl0bGVEbGcoKTsgfSBjYXRjaCB7fQogICAgICAgIHRyeSB7CiAgICAgICAgICAg
IGNvbnN0IHdyYXAgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc2VhcmNoLXdyYXAnKTsKICAgICAg
ICAgICAgY29uc3Qgc3JjaCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzZWFyY2gnKTsKICAgICAg
ICAgICAgY29uc3Qgc2NsciA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzZWFyY2gtY2xyJyk7CiAg
ICAgICAgICAgIGlmICgha2VlcFNlYXJjaCkgewogICAgICAgICAgICAgICAgaWYgKHdyYXApIHdyYXAu
Y2xhc3NMaXN0LnJlbW92ZSgnb3BlbicpOwogICAgICAgICAgICAgICAgaWYgKHNyY2gpIHsKICAgICAg
ICAgICAgICAgICAgICBzcmNoLnZhbHVlID0gJyc7CiAgICAgICAgICAgICAgICAgICAgc3JjaC5jbGFz
c0xpc3QucmVtb3ZlKCdoYXMtdmFsJyk7CiAgICAgICAgICAgICAgICAgICAgdHJ5IHsgc3JjaC5ibHVy
KCk7IH0gY2F0Y2gge30KICAgICAgICAgICAgICAgIH0KICAgICAgICAgICAgICAgIGlmIChzY2xyKSBz
Y2xyLnN0eWxlLmRpc3BsYXkgPSAnbm9uZSc7CiAgICAgICAgICAgICAgICBxdWVyeSA9ICcnOwogICAg
ICAgICAgICAgICAgd2luZG93Ll9faG9zdEZpbHRlcmVkID0gZmFsc2U7CiAgICAgICAgICAgICAgICB3
aW5kb3cuX19ob3N0RmlsdGVyUSA9ICcnOwogICAgICAgICAgICAgICAgLy8gV2luK1bvvJrnq4vliLvn
lKjmnKrov4fmu6TnvJPlrZjpk7rliJfooajvvIzpgb/lhY3lhYjpl6rov4fmu6Tnu5Pmnpwv56m65aOz
5YaN562JIFNldFZpZXcKICAgICAgICAgICAgICAgIHRyeSB7CiAgICAgICAgICAgICAgICAgICAgY29u
c3QgaGl0ID0gdmlld01lbS5nZXQodmlld01lbUtleSgnYWxsJywgJycsIGZhbHNlKSk7CiAgICAgICAg
ICAgICAgICAgICAgaWYgKGhpdCAmJiBBcnJheS5pc0FycmF5KGhpdC5pdGVtcykgJiYgaGl0Lml0ZW1z
Lmxlbmd0aCkgewogICAgICAgICAgICAgICAgICAgICAgICBhbGxDbGlwcyA9IGhpdC5pdGVtcy5zbGlj
ZSgpOwogICAgICAgICAgICAgICAgICAgICAgICBkaXNrVG90YWwgPSBOdW1iZXIoaGl0LnRvdGFsKSB8
fCBoaXQuaXRlbXMubGVuZ3RoOwogICAgICAgICAgICAgICAgICAgICAgICB3aW5kb3cuX19kYXRhUmVh
ZHkgPSB0cnVlOwogICAgICAgICAgICAgICAgICAgICAgICBob3N0UHVzaGVkT25jZSA9IHRydWU7CiAg
ICAgICAgICAgICAgICAgICAgICAgIHNhd05vbkVtcHR5ID0gdHJ1ZTsKICAgICAgICAgICAgICAgICAg
ICAgICAgY2xlYXJXYWl0aW5nRGF0YSgpOwogICAgICAgICAgICAgICAgICAgIH0gZWxzZSB7CiAgICAg
ICAgICAgICAgICAgICAgICAgIHNjaGVkdWxlRGVsYXllZFNrZWwoKTsKICAgICAgICAgICAgICAgICAg
ICB9CiAgICAgICAgICAgICAgICB9IGNhdGNoIHsKICAgICAgICAgICAgICAgICAgICBzY2hlZHVsZURl
bGF5ZWRTa2VsKCk7CiAgICAgICAgICAgICAgICB9CiAgICAgICAgICAgIH0gZWxzZSBpZiAod3JhcCkg
ewogICAgICAgICAgICAgICAgd3JhcC5jbGFzc0xpc3QuYWRkKCdvcGVuJyk7CiAgICAgICAgICAgICAg
ICBpZiAoc3JjaCAmJiBzcmNoLnZhbHVlKQogICAgICAgICAgICAgICAgICAgIHF1ZXJ5ID0gc3JjaC52
YWx1ZTsKICAgICAgICAgICAgICAgIC8vID8/IOaQnOe0ou+8muWcqOS4u+acuui/h+a7pOe7k+aenOWI
sOi+vuWJje+8jOWFiOaMieWFs+mUruWtl+acrOWcsOa7pO+8jOemgeatoumXquWHuuOAjOWFqOmDqOOA
jQogICAgICAgICAgICAgICAgaWYgKFN0cmluZyhxdWVyeSB8fCAnJykudHJpbSgpKSB7CiAgICAgICAg
ICAgICAgICAgICAgd2luZG93Ll9faG9zdEZpbHRlcmVkID0gZmFsc2U7CiAgICAgICAgICAgICAgICAg
ICAgd2luZG93Ll9faG9zdEZpbHRlclEgPSAnJzsKICAgICAgICAgICAgICAgIH0KICAgICAgICAgICAg
fQogICAgICAgICAgICB0b2RheU9ubHkgPSBmYWxzZTsKICAgICAgICAgICAgdHJ5IHsKICAgICAgICAg
ICAgICAgIGNvbnN0IGJ0blRvZGF5ID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2J0bi10b2RheScp
OwogICAgICAgICAgICAgICAgaWYgKGJ0blRvZGF5KSBidG5Ub2RheS5jbGFzc0xpc3QucmVtb3ZlKCdv
bicpOwogICAgICAgICAgICB9IGNhdGNoIHt9CiAgICAgICAgICAgIGN1clRhYiA9ICdhbGwnOwogICAg
ICAgICAgICBsb2FkaW5nTW9yZSA9IGZhbHNlOwogICAgICAgICAgICBtYXJrVGFiKCdhbGwnKTsKICAg
ICAgICAgICAgLy8g5LiN6KaBIGFoaygnYmx1clBhbmVsJynvvJrkvJrot58gU2hvd1BhbmVsIOaKoueE
pueCue+8jFdpbitWLz8/IOmDveWuueaYk+mXquOAgeS5sei3swogICAgICAgICAgICByZW5kZXIoKTsK
ICAgICAgICAgICAgLy8g5ZCM5q2l5b2T5YmNIHRhYi9xdWVyeSDliLAgQUhL77yIPz8g5pu+5Y+q55So
IHZpZXdUYWIg5pCc6ZSZ6aG177yJCiAgICAgICAgICAgIHJlcXVlc3RWaWV3KCk7CiAgICAgICAgfSBj
YXRjaCB7fQogICAgICAgIHNlbGVjdEZpcnN0T25TaG93ID0gdHJ1ZTsKICAgICAgICBsb2NhdGVBY3Rp
dmUgPSBmYWxzZTsKICAgICAgICB1cGRhdGVMb2NhdGVCdG4oKTsKICAgICAgICBjbGVhck11bHRpKCk7
CiAgICAgICAgY29uc3QgdmlzID0gdmlzaWJsZUxpc3QoKTsKICAgICAgICBpZiAodmlzLmxlbmd0aCkg
ewogICAgICAgICAgICBzZWxlY3RlZElkID0gdmlzWzBdLmlkOwogICAgICAgICAgICByYW5nZUFuY2hv
cklkID0gc2VsZWN0ZWRJZDsKICAgICAgICAgICAgcmFuZ2VBbmNob3JDbGlja2VkID0gZmFsc2U7CiAg
ICAgICAgICAgIGxpc3RFbC5zY3JvbGxUb3AgPSAwOwogICAgICAgIH0KICAgICAgICBzeW5jSXRlbUhp
Z2hsaWdodCgpOwogICAgfTsKCiAgICBmdW5jdGlvbiBjdHhCaW5kKGlkLCBmbikgewogICAgICAgIGRv
Y3VtZW50LmdldEVsZW1lbnRCeUlkKGlkKS5hZGRFdmVudExpc3RlbmVyKCdjbGljaycsIGUgPT4gewog
ICAgICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgICAgICAgICBpZiAoY3R4Q2xpcCkgZm4o
Y3R4Q2xpcCk7CiAgICAgICAgICAgIGhpZGVDdHgoKTsKICAgICAgICB9KTsKICAgIH0KICAgIGN0eEJp
bmQoJ2MtY29weScsICBjID0+IHsKICAgICAgICBpZiAobm9ybVR5cGUoYy50eXBlKSA9PT0gJ3JlY2Vu
dCcpCiAgICAgICAgICAgIGFoaygnY29weVBhdGgnLCBTdHJpbmcoYy5kYXRhIHx8IGMucHJldmlldyB8
fCAnJykpOwogICAgICAgIGVsc2UKICAgICAgICAgICAgYWhrKCdjb3B5QnlJZCcsIFN0cmluZyhjLmlk
KSk7CiAgICB9KTsKICAgIGN0eEJpbmQoJ2MtcGFzdGUnLCBjID0+IHsKICAgICAgICBhY3RpdmF0ZUNs
aXBJdGVtKGMpOwogICAgfSk7CiAgICBjdHhCaW5kKCdjLXBpbicsICAgYyA9PiB7CiAgICAgICAgLy8g
T3B0aW1pc3RpYyBmbGlwIOKAlCDlm7rlrprlj6rpmLLmt5jmsbDvvIzkuI3nva7pobbvvJvlho3mrKHo
rr/pl67miY3pnaAgUmVjb3JkIOmhtuWIsOS4iumdogogICAgICAgIGNvbnN0IG5leHQgPSAhaXNQaW5u
ZWQoYyk7CiAgICAgICAgY29uc3QgaWQgPSArYy5pZDsKICAgICAgICBwYXRjaFBpbm5lZEluQ2FjaGVz
KGlkLCBuZXh0KTsKICAgICAgICBjLnBpbm5lZCA9IG5leHQ7CiAgICAgICAgaWYgKG5leHQpIG1hcmtG
YXZVbnNlZW4oaWQpOwogICAgICAgIGVsc2UgewogICAgICAgICAgICB1bnNlZW5GYXZJZHMuZGVsZXRl
KGlkKTsKICAgICAgICAgICAgc2F2ZVVuc2VlbkZhdigpOwogICAgICAgICAgICB1cGRhdGVQaW5Eb3Qo
KTsKICAgICAgICB9CiAgICAgICAgLy8g5pS26JeP6aG15Y+W5raI77ya56uL5Yi75LuO5YiX6KGo5pGY
5o6J77yM5Yir562JIFNldFZpZXcg5omr55uYCiAgICAgICAgaWYgKCFuZXh0ICYmIGN1clRhYiA9PT0g
J3Bpbm5lZCcpIHsKICAgICAgICAgICAgYWxsQ2xpcHMgPSBhbGxDbGlwcy5maWx0ZXIoeCA9PiAreC5p
ZCAhPT0gaWQpOwogICAgICAgICAgICBkaXNrVG90YWwgPSBNYXRoLm1heCgwLCAoTnVtYmVyKGRpc2tU
b3RhbCkgfHwgMCkgLSAxKTsKICAgICAgICAgICAgcGlubmVkVG90YWwgPSBNYXRoLm1heCgwLCAoTnVt
YmVyKHBpbm5lZFRvdGFsKSB8fCAwKSAtIDEpOwogICAgICAgICAgICBpZiAoK3NlbGVjdGVkSWQgPT09
IGlkKQogICAgICAgICAgICAgICAgc2VsZWN0ZWRJZCA9IGFsbENsaXBzLmxlbmd0aCA/IGFsbENsaXBz
WzBdLmlkIDogMDsKICAgICAgICAgICAgdHJ5IHsKICAgICAgICAgICAgICAgIHZpZXdNZW0uc2V0KHZp
ZXdNZW1LZXkoY3VyVGFiLCBxdWVyeSwgdG9kYXlPbmx5KSwgewogICAgICAgICAgICAgICAgICAgIGl0
ZW1zOiBhbGxDbGlwcy5zbGljZSgpLAogICAgICAgICAgICAgICAgICAgIHRvdGFsOiBkaXNrVG90YWwK
ICAgICAgICAgICAgICAgIH0pOwogICAgICAgICAgICB9IGNhdGNoIHt9CiAgICAgICAgICAgIGNsZWFy
RmF2VW5zZWVuKCk7CiAgICAgICAgfSBlbHNlIGlmIChjdXJUYWIgPT09ICdwaW5uZWQnKSB7CiAgICAg
ICAgICAgIGNsZWFyRmF2VW5zZWVuKCk7CiAgICAgICAgfQogICAgICAgIHJlbmRlcigpOwogICAgICAg
IGFoaygncGluJywgU3RyaW5nKGMuaWQpKTsKICAgIH0pOwogICAgY3R4QmluZCgnYy10b3AnLCAgIGMg
PT4gYWhrKCdtb3ZlVG9Ub3AnLCAgICAgU3RyaW5nKGMuaWQpKSk7CiAgICBjdHhCaW5kKCdjLWNsZWFy
LXBhc3RlZCcsIGMgPT4gYWhrKCdjbGVhclBhc3RlZCcsIFN0cmluZyhjLmlkKSkpOwogICAgY3R4Qmlu
ZCgnYy1xdWV1ZS1mcm9tJywgYyA9PiB7CiAgICAgICAgYWhrKCdyZXNldFF1ZXVlRnJvbScsIFN0cmlu
ZyhjLmlkKSk7CiAgICAgICAgaWYgKCFwaW5uZWRVSSkgYWhrKCdoaWRlJyk7CiAgICB9KTsKICAgIGN0
eEJpbmQoJ2MtZGVsJywgICBjID0+IHsKICAgICAgICAvLyDlpJrpgInkuJTlj7PplK7ngrnlnKjpgInk
uK3pobnkuIog4oaSIOaJuemHj+WIoOmZpO+8m+WQpuWImeWPquWIoOW9k+WJjQogICAgICAgIGxldCBp
ZHMgPSBbXTsKICAgICAgICBpZiAobXVsdGlJZHMubGVuZ3RoID4gMSAmJiBtdWx0aUlkcy5pbmNsdWRl
cygrYy5pZCkpCiAgICAgICAgICAgIGlkcyA9IG11bHRpSWRzLnNsaWNlKCk7CiAgICAgICAgZWxzZQog
ICAgICAgICAgICBpZHMgPSBbK2MuaWRdOwogICAgICAgIGlkcyA9IGlkcy5tYXAoeCA9PiAreCkuZmls
dGVyKHggPT4geCA+IDApOwogICAgICAgIGlmICghaWRzLmxlbmd0aCkgcmV0dXJuOwogICAgICAgIHRy
eSB7CiAgICAgICAgICAgIGNvbnN0IGlkU2V0ID0gbmV3IFNldChpZHMpOwogICAgICAgICAgICBhbGxD
bGlwcyA9IGFsbENsaXBzLmZpbHRlcih4ID0+ICFpZFNldC5oYXMoK3guaWQpKTsKICAgICAgICAgICAg
ZGlza1RvdGFsID0gTWF0aC5tYXgoMCwgKE51bWJlcihkaXNrVG90YWwpIHx8IDApIC0gaWRzLmxlbmd0
aCk7CiAgICAgICAgICAgIGlmIChpZFNldC5oYXMoK3NlbGVjdGVkSWQpKQogICAgICAgICAgICAgICAg
c2VsZWN0ZWRJZCA9IGFsbENsaXBzLmxlbmd0aCA/IGFsbENsaXBzWzBdLmlkIDogMDsKICAgICAgICAg
ICAgY2xlYXJNdWx0aSgpOwogICAgICAgICAgICByZW5kZXIoKTsKICAgICAgICB9IGNhdGNoIHt9CiAg
ICAgICAgaWYgKGlkcy5sZW5ndGggPT09IDEpCiAgICAgICAgICAgIGFoaygnZGVsZXRlJywgU3RyaW5n
KGlkc1swXSkpOwogICAgICAgIGVsc2UKICAgICAgICAgICAgYWhrKCdkZWxldGVNYW55JywgaWRzLmpv
aW4oJywnKSk7CiAgICB9KTsKICAgIGN0eEJpbmQoJ2MtdGl0bGUnLCBjID0+IG9wZW5UaXRsZURsZyhj
KSk7CiAgICBjdHhCaW5kKCdjLW1lcmdlJywgYyA9PiB7CiAgICAgICAgY29uc3QgaWRzID0gKG11bHRp
SWRzLmxlbmd0aCA+PSAyKSA/IG11bHRpSWRzLnNsaWNlKCkgOiBbXTsKICAgICAgICBpZiAoaWRzLmxl
bmd0aCA8IDIpIHJldHVybjsKICAgICAgICBpZiAoIWlkcy5pbmNsdWRlcygrYy5pZCkpIGlkcy5wdXNo
KCtjLmlkKTsKICAgICAgICBhaGsoJ21lcmdlRmF2JywgaWRzLmpvaW4oJywnKSk7CiAgICAgICAgY2xl
YXJNdWx0aSgpOwogICAgfSk7CiAgICBjdHhCaW5kKCdjLXVubWVyZ2UnLCBjID0+IHsKICAgICAgICBh
aGsoJ3VubWVyZ2VGYXYnLCBTdHJpbmcoYy5pZCkpOwogICAgICAgIGNsZWFyTXVsdGkoKTsKICAgIH0p
OwoKICAgIGNvbnN0IHRpdGxlRGxnID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3RpdGxlLWRsZycp
OwogICAgY29uc3QgdGl0bGVJbnB1dCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd0aXRsZS1pbnB1
dCcpOwogICAgbGV0IHRpdGxlRGxnQ2xpcCA9IG51bGw7CiAgICBmdW5jdGlvbiBjbG9zZVRpdGxlRGxn
KCkgewogICAgICAgIGlmICh0aXRsZURsZykgdGl0bGVEbGcuY2xhc3NMaXN0LnJlbW92ZSgnb24nKTsK
ICAgICAgICB0aXRsZURsZ0NsaXAgPSBudWxsOwogICAgfQogICAgZnVuY3Rpb24gb3BlblRpdGxlRGxn
KGMpIHsKICAgICAgICBoaWRlQ3R4KCk7CiAgICAgICAgdGl0bGVEbGdDbGlwID0gYzsKICAgICAgICBp
ZiAodGl0bGVJbnB1dCkgdGl0bGVJbnB1dC52YWx1ZSA9IFN0cmluZyhjLmZhdlRpdGxlIHx8ICcnKS50
cmltKCk7CiAgICAgICAgaWYgKHRpdGxlRGxnKSB0aXRsZURsZy5jbGFzc0xpc3QuYWRkKCdvbicpOwog
ICAgICAgIGFoaygnZm9jdXNQYW5lbCcpOwogICAgICAgIHJlcXVlc3RBbmltYXRpb25GcmFtZSgoKSA9
PiB7CiAgICAgICAgICAgIHRyeSB7IHRpdGxlSW5wdXQuZm9jdXMoKTsgdGl0bGVJbnB1dC5zZWxlY3Qo
KTsgfSBjYXRjaCB7fQogICAgICAgIH0pOwogICAgfQogICAgaWYgKHRpdGxlRGxnKSB7CiAgICAgICAg
dGl0bGVEbGcuYWRkRXZlbnRMaXN0ZW5lcignY2xpY2snLCBlID0+IHsKICAgICAgICAgICAgaWYgKGUu
dGFyZ2V0ID09PSB0aXRsZURsZykgY2xvc2VUaXRsZURsZygpOwogICAgICAgIH0pOwogICAgfQogICAg
ZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3RpdGxlLWNhbmNlbCcpPy5hZGRFdmVudExpc3RlbmVyKCdj
bGljaycsIGUgPT4gewogICAgICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAgICAgY2xvc2VUaXRs
ZURsZygpOwogICAgICAgIGFoaygnYmx1clBhbmVsJyk7CiAgICB9KTsKICAgIGRvY3VtZW50LmdldEVs
ZW1lbnRCeUlkKCd0aXRsZS1vaycpPy5hZGRFdmVudExpc3RlbmVyKCdjbGljaycsIGUgPT4gewogICAg
ICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAgICAgaWYgKCF0aXRsZURsZ0NsaXApIHJldHVybjsK
ICAgICAgICBjb25zdCB0ID0gU3RyaW5nKHRpdGxlSW5wdXQ/LnZhbHVlIHx8ICcnKS50cmltKCkuc2xp
Y2UoMCwgODApOwogICAgICAgIGNvbnN0IGlkID0gU3RyaW5nKHRpdGxlRGxnQ2xpcC5pZCk7CiAgICAg
ICAgLy8gT3B0aW1pc3RpYyBsb2NhbCB1cGRhdGUKICAgICAgICBjb25zdCBoaXQgPSBhbGxDbGlwcy5m
aW5kKHggPT4gK3guaWQgPT09ICtpZCk7CiAgICAgICAgaWYgKGhpdCkgaGl0LmZhdlRpdGxlID0gdDsK
ICAgICAgICB0aXRsZURsZ0NsaXAuZmF2VGl0bGUgPSB0OwogICAgICAgIGNsb3NlVGl0bGVEbGcoKTsK
ICAgICAgICBhaGsoJ3NldEZhdlRpdGxlJywgaWQsIHQpOwogICAgICAgIGFoaygnYmx1clBhbmVsJyk7
CiAgICAgICAgcmVuZGVyKCk7CiAgICB9KTsKICAgIHRpdGxlSW5wdXQ/LmFkZEV2ZW50TGlzdGVuZXIo
J2tleWRvd24nLCBlID0+IHsKICAgICAgICBpZiAoZS5rZXkgPT09ICdFbnRlcicpIHsKICAgICAgICAg
ICAgZS5wcmV2ZW50RGVmYXVsdCgpOwogICAgICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAg
ICAgICAgICBlLnN0b3BJbW1lZGlhdGVQcm9wYWdhdGlvbigpOwogICAgICAgICAgICBkb2N1bWVudC5n
ZXRFbGVtZW50QnlJZCgndGl0bGUtb2snKT8uY2xpY2soKTsKICAgICAgICAgICAgcmV0dXJuOwogICAg
ICAgIH0KICAgICAgICBpZiAoZS5rZXkgPT09ICdFc2NhcGUnKSB7CiAgICAgICAgICAgIGUucHJldmVu
dERlZmF1bHQoKTsKICAgICAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICAgICAgY2xv
c2VUaXRsZURsZygpOwogICAgICAgICAgICBhaGsoJ2JsdXJQYW5lbCcpOwogICAgICAgICAgICByZXR1
cm47CiAgICAgICAgfQogICAgICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICB9LCB0cnVlKTsKCiAg
ICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgndGFicycpLmFkZEV2ZW50TGlzdGVuZXIoJ2NsaWNrJywg
ZSA9PiB7CiAgICAgICAgY29uc3QgdGFiID0gZS50YXJnZXQuY2xvc2VzdCgnLnRhYicpOwogICAgICAg
IGlmICghdGFiIHx8IGUudGFyZ2V0LmNsb3Nlc3QoJyN0YWItYWN0aW9ucycpKSByZXR1cm47CiAgICAg
ICAgc2V0VGFiKHRhYi5kYXRhc2V0LnRhYik7CiAgICB9KTsKCiAgICBjb25zdCBzcmNoV3JhcCA9IGRv
Y3VtZW50LmdldEVsZW1lbnRCeUlkKCdzZWFyY2gtd3JhcCcpOwogICAgY29uc3QgYnRuU2VhcmNoID0g
ZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2J0bi1zZWFyY2gnKTsKICAgIGNvbnN0IGJ0bkxvY2F0ZSA9
IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdidG4tbG9jYXRlJyk7CiAgICBjb25zdCBidG5Ub2RheSA9
IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdidG4tdG9kYXknKTsKICAgIGNvbnN0IHNyY2ggPSBkb2N1
bWVudC5nZXRFbGVtZW50QnlJZCgnc2VhcmNoJyk7CiAgICBjb25zdCBzY2xyID0gZG9jdW1lbnQuZ2V0
RWxlbWVudEJ5SWQoJ3NlYXJjaC1jbHInKTsKICAgIGxldCBkZWI7CgogICAgdXBkYXRlTG9jYXRlQnRu
KCk7CiAgICBpZiAoYnRuTG9jYXRlKSB7CiAgICAgICAgYnRuTG9jYXRlLmFkZEV2ZW50TGlzdGVuZXIo
J2NsaWNrJywgZSA9PiB7CiAgICAgICAgICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAgICAgICAg
IGp1bXBUb0xhc3RQYXN0ZSgpOwogICAgICAgIH0pOwogICAgfQoKICAgIGJ0blRvZGF5LmFkZEV2ZW50
TGlzdGVuZXIoJ21vdXNlZG93bicsIGUgPT4gewogICAgICAgIGUucHJldmVudERlZmF1bHQoKTsKICAg
ICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgfSk7CiAgICBidG5Ub2RheS5hZGRFdmVudExpc3Rl
bmVyKCdjbGljaycsIGUgPT4gewogICAgICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAgICAgZS5w
cmV2ZW50RGVmYXVsdCgpOwogICAgICAgIHRvZGF5T25seSA9ICF0b2RheU9ubHk7CiAgICAgICAgYnRu
VG9kYXkuY2xhc3NMaXN0LnRvZ2dsZSgnb24nLCB0b2RheU9ubHkpOwogICAgICAgIGxpc3RFbC5zY3Jv
bGxUb3AgPSAwOwogICAgICAgIHJlcXVlc3RWaWV3KCk7CiAgICAgICAgdHJ5IHsgc3JjaC5mb2N1cygp
OyB9IGNhdGNoIHt9CiAgICB9KTsKCiAgICBmdW5jdGlvbiBvcGVuU2VhcmNoKCkgewogICAgICAgIGlm
IChzcmNoV3JhcC5jbGFzc0xpc3QuY29udGFpbnMoJ29wZW4nKSkgewogICAgICAgICAgICBhaGsoJ2Zv
Y3VzUGFuZWwnKTsKICAgICAgICAgICAgdHJ5IHsgc3JjaC5mb2N1cygpOyB9IGNhdGNoIHt9CiAgICAg
ICAgICAgIHJldHVybjsKICAgICAgICB9CiAgICAgICAgc3JjaFdyYXAuY2xhc3NMaXN0LmFkZCgnb3Bl
bicpOwogICAgICAgIC8vIERlZmF1bHQ6IOaJgOaciemhteaJk+W8gOaQnOe0ouaXtum7mOiupOaQnOWF
qOmDqAogICAgICAgIGNvbnN0IHdhbnRUb2RheSA9IGZhbHNlOwogICAgICAgIGlmICh0b2RheU9ubHkg
IT09IHdhbnRUb2RheSkgewogICAgICAgICAgICB0b2RheU9ubHkgPSB3YW50VG9kYXk7CiAgICAgICAg
ICAgIGJ0blRvZGF5LmNsYXNzTGlzdC50b2dnbGUoJ29uJywgdG9kYXlPbmx5KTsKICAgICAgICAgICAg
bGlzdEVsLnNjcm9sbFRvcCA9IDA7CiAgICAgICAgICAgIHJlcXVlc3RWaWV3KCk7CiAgICAgICAgfSBl
bHNlIHsKICAgICAgICAgICAgYnRuVG9kYXkuY2xhc3NMaXN0LnRvZ2dsZSgnb24nLCB0b2RheU9ubHkp
OwogICAgICAgIH0KICAgICAgICBhaGsoJ2ZvY3VzUGFuZWwnKTsKICAgICAgICByZXF1ZXN0QW5pbWF0
aW9uRnJhbWUoKCkgPT4gewogICAgICAgICAgICB0cnkgeyBzcmNoLmZvY3VzKCk7IH0gY2F0Y2gge30K
ICAgICAgICB9KTsKICAgIH0KICAgIGZ1bmN0aW9uIGNsb3NlU2VhcmNoVWkoKSB7CiAgICAgICAgc3Jj
aFdyYXAuY2xhc3NMaXN0LnJlbW92ZSgnb3BlbicpOwogICAgICAgIGlmICghc3JjaC52YWx1ZSkgewog
ICAgICAgICAgICBzcmNoLmNsYXNzTGlzdC5yZW1vdmUoJ2hhcy12YWwnKTsKICAgICAgICAgICAgc2Ns
ci5zdHlsZS5kaXNwbGF5ID0gJ25vbmUnOwogICAgICAgICAgICAvLyBMZWF2aW5nIHNlYXJjaCB3aXRo
IGVtcHR5IHF1ZXJ5IOKGkiBkcm9wIHRvZGF5IGZpbHRlcgogICAgICAgICAgICBpZiAodG9kYXlPbmx5
KSB7CiAgICAgICAgICAgICAgICB0b2RheU9ubHkgPSBmYWxzZTsKICAgICAgICAgICAgICAgIGJ0blRv
ZGF5LmNsYXNzTGlzdC5yZW1vdmUoJ29uJyk7CiAgICAgICAgICAgICAgICByZXF1ZXN0VmlldygpOwog
ICAgICAgICAgICB9CiAgICAgICAgfQogICAgfQogICAgd2luZG93Ll9fb3BlblNlYXJjaCA9IG9wZW5T
ZWFyY2g7CiAgICB3aW5kb3cuX19wcmVwVHlwZVNlYXJjaCA9ICgpID0+IHsKICAgICAgICB0cnkgewog
ICAgICAgICAgICBjb25zdCB3cmFwID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NlYXJjaC13cmFw
Jyk7CiAgICAgICAgICAgIGNvbnN0IHMgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc2VhcmNoJyk7
CiAgICAgICAgICAgIGlmICh3cmFwICYmICF3cmFwLmNsYXNzTGlzdC5jb250YWlucygnb3BlbicpKSB7
CiAgICAgICAgICAgICAgICB3cmFwLmNsYXNzTGlzdC5hZGQoJ29wZW4nKTsKICAgICAgICAgICAgICAg
IHRyeSB7CiAgICAgICAgICAgICAgICAgICAgY29uc3Qgd2FudFRvZGF5ID0gZmFsc2U7CiAgICAgICAg
ICAgICAgICAgICAgaWYgKHR5cGVvZiB0b2RheU9ubHkgIT09ICd1bmRlZmluZWQnICYmIHRvZGF5T25s
eSAhPT0gd2FudFRvZGF5KSB7CiAgICAgICAgICAgICAgICAgICAgICAgIHRvZGF5T25seSA9IHdhbnRU
b2RheTsKICAgICAgICAgICAgICAgICAgICAgICAgaWYgKHR5cGVvZiBidG5Ub2RheSAhPT0gJ3VuZGVm
aW5lZCcgJiYgYnRuVG9kYXkpIGJ0blRvZGF5LmNsYXNzTGlzdC50b2dnbGUoJ29uJywgdG9kYXlPbmx5
KTsKICAgICAgICAgICAgICAgICAgICAgICAgaWYgKHR5cGVvZiBsaXN0RWwgIT09ICd1bmRlZmluZWQn
ICYmIGxpc3RFbCkgbGlzdEVsLnNjcm9sbFRvcCA9IDA7CiAgICAgICAgICAgICAgICAgICAgICAgIGlm
ICh0eXBlb2YgcmVxdWVzdFZpZXcgPT09ICdmdW5jdGlvbicpIHNldFRpbWVvdXQocmVxdWVzdFZpZXcs
IDApOwogICAgICAgICAgICAgICAgICAgIH0gZWxzZSBpZiAodHlwZW9mIGJ0blRvZGF5ICE9PSAndW5k
ZWZpbmVkJyAmJiBidG5Ub2RheSkgewogICAgICAgICAgICAgICAgICAgICAgICBidG5Ub2RheS5jbGFz
c0xpc3QudG9nZ2xlKCdvbicsICEhdG9kYXlPbmx5KTsKICAgICAgICAgICAgICAgICAgICB9CiAgICAg
ICAgICAgICAgICB9IGNhdGNoIHt9CiAgICAgICAgICAgIH0KICAgICAgICAgICAgLy8gPz8g6ZWc5YOP
5pCc57Si77ya5LiN6KaBIGZvY3Vz77yM6YG/5YWN5oqi6LWw5Y6f57yW6L6R5qGG5YWJ5qCHCiAgICAg
ICAgfSBjYXRjaCB7fQogICAgfTsKICAgIHdpbmRvdy5fX3R5cGVTZWFyY2ggPSAoY2gpID0+IHsKICAg
ICAgICB0cnkgewogICAgICAgICAgICB3aW5kb3cuX19wcmVwVHlwZVNlYXJjaCAmJiB3aW5kb3cuX19w
cmVwVHlwZVNlYXJjaCgpOwogICAgICAgICAgICBjb25zdCBzID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5
SWQoJ3NlYXJjaCcpOwogICAgICAgICAgICBpZiAoIXMpIHJldHVybjsKICAgICAgICAgICAgcy52YWx1
ZSA9IFN0cmluZyhzLnZhbHVlIHx8ICcnKSArIFN0cmluZyhjaCA9PSBudWxsID8gJycgOiBjaCk7CiAg
ICAgICAgICAgIHMuY2xhc3NMaXN0LnRvZ2dsZSgnaGFzLXZhbCcsICEhcy52YWx1ZSk7CiAgICAgICAg
ICAgIHMuZGlzcGF0Y2hFdmVudChuZXcgRXZlbnQoJ2lucHV0JywgeyBidWJibGVzOiB0cnVlIH0pKTsK
ICAgICAgICB9IGNhdGNoIHt9CiAgICB9OwogICAgd2luZG93Ll9fYmtzcFNlYXJjaCA9ICgpID0+IHsK
ICAgICAgICB0cnkgewogICAgICAgICAgICB3aW5kb3cuX19wcmVwVHlwZVNlYXJjaCAmJiB3aW5kb3cu
X19wcmVwVHlwZVNlYXJjaCgpOwogICAgICAgICAgICBjb25zdCBzID0gZG9jdW1lbnQuZ2V0RWxlbWVu
dEJ5SWQoJ3NlYXJjaCcpOwogICAgICAgICAgICBpZiAoIXMpIHJldHVybjsKICAgICAgICAgICAgY29u
c3QgdiA9IFN0cmluZyhzLnZhbHVlIHx8ICcnKTsKICAgICAgICAgICAgcy52YWx1ZSA9IHYubGVuZ3Ro
ID8gdi5zbGljZSgwLCAtMSkgOiAnJzsKICAgICAgICAgICAgcy5jbGFzc0xpc3QudG9nZ2xlKCdoYXMt
dmFsJywgISFzLnZhbHVlKTsKICAgICAgICAgICAgcy5kaXNwYXRjaEV2ZW50KG5ldyBFdmVudCgnaW5w
dXQnLCB7IGJ1YmJsZXM6IHRydWUgfSkpOwogICAgICAgIH0gY2F0Y2gge30KICAgIH07CiAgICB3aW5k
b3cuX19zZXRTZWFyY2hRdWVyeSA9IChxKSA9PiB7CiAgICAgICAgdHJ5IHsKICAgICAgICAgICAgY29u
c3QgcyA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzZWFyY2gnKTsKICAgICAgICAgICAgaWYgKCFz
KSByZXR1cm47CiAgICAgICAgICAgIGNvbnN0IG5leHQgPSBTdHJpbmcocSA9PSBudWxsID8gJycgOiBx
KTsKICAgICAgICAgICAgY29uc3QgcHJldiA9IFN0cmluZyhzLnZhbHVlIHx8ICcnKTsKICAgICAgICAg
ICAgLy8g5ZCM5YWz6ZSu5a2X6YeN5aSN5o6o6YCB77ya5Y+q5L+d6K+B5pCc57Si5qGG5byA552A77yM
56aB5q2i5YaNIHJlcXVlc3RWaWV377yI5Lya5q275b6q546v6Zeq77yJCiAgICAgICAgICAgIGlmIChw
cmV2ID09PSBuZXh0ICYmIFN0cmluZyhxdWVyeSB8fCAnJykgPT09IG5leHQpIHsKICAgICAgICAgICAg
ICAgIHRyeSB7CiAgICAgICAgICAgICAgICAgICAgY29uc3Qgd3JhcCA9IGRvY3VtZW50LmdldEVsZW1l
bnRCeUlkKCdzZWFyY2gtd3JhcCcpOwogICAgICAgICAgICAgICAgICAgIGlmICh3cmFwICYmICF3cmFw
LmNsYXNzTGlzdC5jb250YWlucygnb3BlbicpKQogICAgICAgICAgICAgICAgICAgICAgICB3cmFwLmNs
YXNzTGlzdC5hZGQoJ29wZW4nKTsKICAgICAgICAgICAgICAgIH0gY2F0Y2gge30KICAgICAgICAgICAg
ICAgIHJldHVybjsKICAgICAgICAgICAgfQogICAgICAgICAgICAvLyDmiZPlrZfljbPml7bkuIrlsY/v
vIzkuI7no4Hnm5jmkJzntKLop6PogKYKICAgICAgICAgICAgcy52YWx1ZSA9IG5leHQ7CiAgICAgICAg
ICAgIHMuY2xhc3NMaXN0LnRvZ2dsZSgnaGFzLXZhbCcsICEhcy52YWx1ZSk7CiAgICAgICAgICAgIGNv
bnN0IHNjbHIgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc2VhcmNoLWNscicpOwogICAgICAgICAg
ICBpZiAoc2Nscikgc2Nsci5zdHlsZS5kaXNwbGF5ID0gcy52YWx1ZSA/ICdibG9jaycgOiAnbm9uZSc7
CiAgICAgICAgICAgIHF1ZXJ5ID0gcy52YWx1ZTsKICAgICAgICAgICAgdHJ5IHsKICAgICAgICAgICAg
ICAgIGNvbnN0IHdyYXAgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc2VhcmNoLXdyYXAnKTsKICAg
ICAgICAgICAgICAgIGlmICh3cmFwICYmICF3cmFwLmNsYXNzTGlzdC5jb250YWlucygnb3BlbicpKQog
ICAgICAgICAgICAgICAgICAgIHdpbmRvdy5fX3ByZXBUeXBlU2VhcmNoICYmIHdpbmRvdy5fX3ByZXBU
eXBlU2VhcmNoKCk7CiAgICAgICAgICAgICAgICBlbHNlIGlmICh3cmFwKQogICAgICAgICAgICAgICAg
ICAgIHdyYXAuY2xhc3NMaXN0LmFkZCgnb3BlbicpOwogICAgICAgICAgICB9IGNhdGNoIHt9CiAgICAg
ICAgICAgIHdpbmRvdy5fX2hvc3RGaWx0ZXJlZCA9IGZhbHNlOwogICAgICAgICAgICB3aW5kb3cuX19o
b3N0RmlsdGVyUSA9ICcnOwogICAgICAgICAgICBpZiAoU3RyaW5nKHF1ZXJ5IHx8ICcnKS50cmltKCkp
IHsKICAgICAgICAgICAgICAgIHdhaXRpbmdEYXRhID0gdHJ1ZTsKICAgICAgICAgICAgICAgIHdpbmRv
dy5fX2RhdGFSZWFkeSA9IGZhbHNlOwogICAgICAgICAgICB9CiAgICAgICAgICAgIHRyeSB7CiAgICAg
ICAgICAgICAgICBjb25zdCBjbnQgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYmFyLXR4dCcpOwog
ICAgICAgICAgICAgICAgaWYgKGNudCAmJiBTdHJpbmcocXVlcnkgfHwgJycpLnRyaW0oKSkKICAgICAg
ICAgICAgICAgICAgICBjbnQudGV4dENvbnRlbnQgPSB2aXNpYmxlTGlzdCgpLmxlbmd0aCArICcg5p2h
JzsKICAgICAgICAgICAgfSBjYXRjaCB7fQogICAgICAgICAgICB0cnkgeyByZW5kZXIoKTsgfSBjYXRj
aCB7fQogICAgICAgICAgICBjbGVhclRpbWVvdXQod2luZG93Ll9fcXFWaWV3RGViKTsKICAgICAgICAg
ICAgd2luZG93Ll9fcXFWaWV3RGViID0gc2V0VGltZW91dCgoKSA9PiB7CiAgICAgICAgICAgICAgICB3
aW5kb3cuX19xcVZpZXdEZWIgPSAwOwogICAgICAgICAgICAgICAgcmVxdWVzdFZpZXcoKTsKICAgICAg
ICAgICAgfSwgNzApOwogICAgICAgIH0gY2F0Y2gge30KICAgIH07CiAgICB3aW5kb3cuX19jbGVhclFR
U2VhcmNoID0gKCkgPT4gewogICAgICAgIHRyeSB7CiAgICAgICAgICAgIHF1ZXJ5ID0gJyc7CiAgICAg
ICAgICAgIHdpbmRvdy5fX2hvc3RGaWx0ZXJlZCA9IGZhbHNlOwogICAgICAgICAgICB3aW5kb3cuX19o
b3N0RmlsdGVyUSA9ICcnOwogICAgICAgICAgICBjb25zdCBzID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5
SWQoJ3NlYXJjaCcpOwogICAgICAgICAgICBpZiAocykgewogICAgICAgICAgICAgICAgcy52YWx1ZSA9
ICcnOwogICAgICAgICAgICAgICAgcy5jbGFzc0xpc3QucmVtb3ZlKCdoYXMtdmFsJyk7CiAgICAgICAg
ICAgICAgICB0cnkgeyBzLmJsdXIoKTsgfSBjYXRjaCB7fQogICAgICAgICAgICB9CiAgICAgICAgICAg
IGNvbnN0IHNjbHIgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc2VhcmNoLWNscicpOwogICAgICAg
ICAgICBpZiAoc2Nscikgc2Nsci5zdHlsZS5kaXNwbGF5ID0gJ25vbmUnOwogICAgICAgICAgICBjb25z
dCB3cmFwID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NlYXJjaC13cmFwJyk7CiAgICAgICAgICAg
IGlmICh3cmFwKSB3cmFwLmNsYXNzTGlzdC5yZW1vdmUoJ29wZW4nKTsKICAgICAgICAgICAgdHJ5IHsg
cmVuZGVyKCk7IH0gY2F0Y2gge30KICAgICAgICB9IGNhdGNoIHt9CiAgICB9OwogICAgLy8gQ2FwdHVy
ZSBDdHJsK0YgaW5zaWRlIFdlYlZpZXcgKENocm9taXVtIGZpbmQgaXMgZGlzYWJsZWQsIGJ1dCBzdGls
bCBoYW5kbGUgaGVyZSkKICAgIGRvY3VtZW50LmFkZEV2ZW50TGlzdGVuZXIoJ2tleWRvd24nLCBlID0+
IHsKICAgICAgICBpZiAoKGUuY3RybEtleSB8fCBlLm1ldGFLZXkpICYmICFlLmFsdEtleSAmJiAoZS5r
ZXkgPT09ICdmJyB8fCBlLmtleSA9PT0gJ0YnKSkgewogICAgICAgICAgICBlLnByZXZlbnREZWZhdWx0
KCk7CiAgICAgICAgICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAgICAgICAgIG9wZW5TZWFyY2go
KTsKICAgICAgICB9CiAgICB9LCB0cnVlKTsKICAgIGJ0blNlYXJjaC5hZGRFdmVudExpc3RlbmVyKCdj
bGljaycsIGUgPT4gewogICAgICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAgICAgb3BlblNlYXJj
aCgpOwogICAgfSk7CiAgICBsZXQgX19zcmNoQ29tcG9zaW5nID0gZmFsc2U7CiAgICBjb25zdCBfX2Zs
dXNoU2VhcmNoSW5wdXQgPSAoKSA9PiB7CiAgICAgICAgcXVlcnkgPSBzcmNoLnZhbHVlOwogICAgICAg
IHNyY2guY2xhc3NMaXN0LnRvZ2dsZSgnaGFzLXZhbCcsICEhcXVlcnkpOwogICAgICAgIHNjbHIuc3R5
bGUuZGlzcGxheSA9IHF1ZXJ5ID8gJ2Jsb2NrJyA6ICdub25lJzsKICAgICAgICBsaXN0RWwuc2Nyb2xs
VG9wID0gMDsKICAgICAgICB3aW5kb3cuX19ob3N0RmlsdGVyZWQgPSBmYWxzZTsKICAgICAgICB3aW5k
b3cuX19ob3N0RmlsdGVyUSA9ICcnOwogICAgICAgIHRyeSB7IHJlbmRlcigpOyB9IGNhdGNoIHt9CiAg
ICAgICAgY2xlYXJUaW1lb3V0KGRlYik7CiAgICAgICAgZGViID0gc2V0VGltZW91dChyZXF1ZXN0Vmll
dywgODApOwogICAgfTsKICAgIHNyY2guYWRkRXZlbnRMaXN0ZW5lcignY29tcG9zaXRpb25zdGFydCcs
ICgpID0+IHsgX19zcmNoQ29tcG9zaW5nID0gdHJ1ZTsgfSk7CiAgICBzcmNoLmFkZEV2ZW50TGlzdGVu
ZXIoJ2NvbXBvc2l0aW9uZW5kJywgKCkgPT4gewogICAgICAgIF9fc3JjaENvbXBvc2luZyA9IGZhbHNl
OwogICAgICAgIF9fZmx1c2hTZWFyY2hJbnB1dCgpOwogICAgfSk7CiAgICBzcmNoLmFkZEV2ZW50TGlz
dGVuZXIoJ2lucHV0JywgKCkgPT4gewogICAgICAgIGlmIChfX3NyY2hDb21wb3NpbmcpIHsKICAgICAg
ICAgICAgcXVlcnkgPSBzcmNoLnZhbHVlOwogICAgICAgICAgICBzcmNoLmNsYXNzTGlzdC50b2dnbGUo
J2hhcy12YWwnLCAhIXF1ZXJ5KTsKICAgICAgICAgICAgc2Nsci5zdHlsZS5kaXNwbGF5ID0gcXVlcnkg
PyAnYmxvY2snIDogJ25vbmUnOwogICAgICAgICAgICByZXR1cm47CiAgICAgICAgfQogICAgICAgIF9f
Zmx1c2hTZWFyY2hJbnB1dCgpOwogICAgfSk7CiAgICBzcmNoLmFkZEV2ZW50TGlzdGVuZXIoJ2ZvY3Vz
JywgKCkgPT4gewogICAgICAgIC8vIElkZW1wb3RlbnQgb24gQUhLIHNpZGUg4oCUIHNhZmUsIGJ1dCBh
dm9pZCBzcGFtbWluZyBkdXJpbmcgSU1FCiAgICAgICAgdHJ5IHsgYWhrKCdmb2N1c1BhbmVsJyk7IH0g
Y2F0Y2gge30KICAgIH0pOwogICAgc3JjaC5hZGRFdmVudExpc3RlbmVyKCdibHVyJywgKCkgPT4gewog
ICAgICAgIHNldFRpbWVvdXQoKCkgPT4gewogICAgICAgICAgICBpZiAoZG9jdW1lbnQuYWN0aXZlRWxl
bWVudCA9PT0gc3JjaCkgcmV0dXJuOwogICAgICAgICAgICBpZiAoZG9jdW1lbnQuYWN0aXZlRWxlbWVu
dCA9PT0gc2NsciB8fCAoc2NsciAmJiBzY2xyLmNvbnRhaW5zKGRvY3VtZW50LmFjdGl2ZUVsZW1lbnQp
KSkgcmV0dXJuOwogICAgICAgICAgICBpZiAoZG9jdW1lbnQuYWN0aXZlRWxlbWVudCA9PT0gYnRuVG9k
YXkgfHwgKGJ0blRvZGF5ICYmIGJ0blRvZGF5LmNvbnRhaW5zKGRvY3VtZW50LmFjdGl2ZUVsZW1lbnQp
KSkgcmV0dXJuOwogICAgICAgICAgICAvLyBJTUUgY2FuZGlkYXRlIFVJIHN0ZWFscyBmb2N1cyBicmll
Zmx5IOKAlCBrZWVwIHNlYXJjaCBpZiBzdGlsbCBjb21wb3NpbmcKICAgICAgICAgICAgaWYgKF9fc3Jj
aENvbXBvc2luZykgcmV0dXJuOwogICAgICAgICAgICBjbG9zZVNlYXJjaFVpKCk7CiAgICAgICAgICAg
IGFoaygnYmx1clBhbmVsJyk7CiAgICAgICAgfSwgMjgwKTsKICAgIH0pOwogICAgc3JjaC5hZGRFdmVu
dExpc3RlbmVyKCdrZXlkb3duJywgZSA9PiB7CiAgICAgICAgLy8gQ3RybCtJIC8gQ3RybCtLOiBtb3Zl
IGNsaXAgc2VsZWN0aW9uIChub3QgaW5zZXJ0IGNoYXIgLyBicm93c2VyIHNob3J0Y3V0KQogICAgICAg
IGlmICgoZS5jdHJsS2V5IHx8IGUubWV0YUtleSkgJiYgKGUua2V5ID09PSAnaScgfHwgZS5rZXkgPT09
ICdJJykpIHsKICAgICAgICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOwogICAgICAgICAgICBlLnN0b3BQ
cm9wYWdhdGlvbigpOwogICAgICAgICAgICB3aW5kb3cuX19uYXYgJiYgd2luZG93Ll9fbmF2KCd1cCcp
OwogICAgICAgICAgICByZXR1cm47CiAgICAgICAgfQogICAgICAgIGlmICgoZS5jdHJsS2V5IHx8IGUu
bWV0YUtleSkgJiYgKGUua2V5ID09PSAnaycgfHwgZS5rZXkgPT09ICdLJykpIHsKICAgICAgICAgICAg
ZS5wcmV2ZW50RGVmYXVsdCgpOwogICAgICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgICAg
ICAgICB3aW5kb3cuX19uYXYgJiYgd2luZG93Ll9fbmF2KCdkb3duJyk7CiAgICAgICAgICAgIHJldHVy
bjsKICAgICAgICB9CiAgICAgICAgaWYgKGUua2V5ID09PSAnQXJyb3dEb3duJykgewogICAgICAgICAg
ICBlLnByZXZlbnREZWZhdWx0KCk7CiAgICAgICAgICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAg
ICAgICAgIHdpbmRvdy5fX25hdiAmJiB3aW5kb3cuX19uYXYoJ2Rvd24nKTsKICAgICAgICAgICAgcmV0
dXJuOwogICAgICAgIH0KICAgICAgICBpZiAoZS5rZXkgPT09ICdBcnJvd1VwJykgewogICAgICAgICAg
ICBlLnByZXZlbnREZWZhdWx0KCk7CiAgICAgICAgICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAg
ICAgICAgIHdpbmRvdy5fX25hdiAmJiB3aW5kb3cuX19uYXYoJ3VwJyk7CiAgICAgICAgICAgIHJldHVy
bjsKICAgICAgICB9CiAgICAgICAgaWYgKGUua2V5ID09PSAnRXNjYXBlJykgewogICAgICAgICAgICBl
LnByZXZlbnREZWZhdWx0KCk7CiAgICAgICAgICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAgICAg
ICAgIC8vIEFsd2F5cyBkaXNtaXNzIHRoZSB3aG9sZSBwYW5lbCAobm90IGp1c3QgdGhlIHNlYXJjaCBm
aWVsZCkKICAgICAgICAgICAgaWYgKCFwaW5uZWRVSSkgYWhrKCdoaWRlJyk7CiAgICAgICAgICAgIHJl
dHVybjsKICAgICAgICB9CiAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgIH0pOwogICAgc2Ns
ci5hZGRFdmVudExpc3RlbmVyKCdjbGljaycsIGUgPT4gewogICAgICAgIGUuc3RvcFByb3BhZ2F0aW9u
KCk7CiAgICAgICAgc3JjaC52YWx1ZSA9IHF1ZXJ5ID0gJyc7CiAgICAgICAgc2Nsci5zdHlsZS5kaXNw
bGF5ID0gJ25vbmUnOwogICAgICAgIHNyY2guY2xhc3NMaXN0LnJlbW92ZSgnaGFzLXZhbCcpOwogICAg
ICAgIHJlcXVlc3RWaWV3KCk7CiAgICAgICAgYWhrKCdmb2N1c1BhbmVsJyk7CiAgICAgICAgc3JjaC5m
b2N1cygpOwogICAgfSk7CgogICAgY29uc3QgVEFCX05BTUVTID0geyBhbGw6ICflhajpg6gnLCB0ZXh0
OiAn5paH5pysJywgaW1hZ2U6ICflm77lg48nLCBmaWxlOiAn5paH5Lu2JywgcmVjZW50OiAn5pyA6L+R
JywgcGlubmVkOiAn5pS26JePJyB9OwogICAgY29uc3QgY2xyRGxnID0gZG9jdW1lbnQuZ2V0RWxlbWVu
dEJ5SWQoJ2Nsci1kbGcnKTsKICAgIGNvbnN0IGNsckFsbENiID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5
SWQoJ2Nsci1hbGwnKTsKICAgIGZ1bmN0aW9uIG9wZW5DbGVhckRsZygpIHsKICAgICAgICBjb25zdCBu
YW1lID0gVEFCX05BTUVTW2N1clRhYl0gfHwgJ+W9k+WJjSc7CiAgICAgICAgZG9jdW1lbnQuZ2V0RWxl
bWVudEJ5SWQoJ2Nsci10aXRsZScpLnRleHRDb250ZW50ID0gJ+a4heepuuOAjCcgKyBuYW1lICsgJ+OA
je+8nyc7CiAgICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2Nsci1kZXNjJykudGV4dENvbnRl
bnQgPSBjdXJUYWIgPT09ICdwaW5uZWQnCiAgICAgICAgICAgID8gJ+m7mOiupOS7hea4heepuuW9k+Wk
qeeahOaUtuiXj+mhueOAguWLvumAieOAjOa4heepuuaJgOacieOAjeWPr+a4hemZpOivpemAiemhueWN
oeWFqOmDqOWGheWuueOAgicKICAgICAgICAgICAgOiAoY3VyVGFiID09PSAncmVjZW50JwogICAgICAg
ICAgICAgICAgPyAn5riF56m644CM5pyA6L+R44CN5Lya5Yig6Zmk5pyq5Zu65a6a55qE5pyA6L+R55uu
5b2V6K6w5b2V77yb5bey5Zu65a6a55qE55uu5b2V5Lya5L+d55WZ44CCJwogICAgICAgICAgICAgICAg
OiAn5LuF5riF56m65b2T5YmN6YCJ6aG55Y2h44CC6buY6K6k5Y+q5riF5b2T5aSp77yb5pS26JeP6aG5
5LiN5Lya6KKr5riF6Zmk44CC5Yu+6YCJ44CM5riF56m65omA5pyJ44CN5Y+v5riF6Zmk6K+l6YCJ6aG5
5Y2h5YWo6YOo5pel5pyf44CCJyk7CiAgICAgICAgY2xyQWxsQ2IuY2hlY2tlZCA9IGZhbHNlOwogICAg
ICAgIGNsckRsZy5jbGFzc0xpc3QuYWRkKCdvbicpOwogICAgfQogICAgZnVuY3Rpb24gY2xvc2VDbGVh
ckRsZygpIHsKICAgICAgICBjbHJEbGcuY2xhc3NMaXN0LnJlbW92ZSgnb24nKTsKICAgIH0KICAgIGRv
Y3VtZW50LmdldEVsZW1lbnRCeUlkKCdidG4tY2xyJykuYWRkRXZlbnRMaXN0ZW5lcignY2xpY2snLCBl
ID0+IHsKICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgICAgIG9wZW5DbGVhckRsZygpOwog
ICAgfSk7CiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnY2xyLWNhbmNlbCcpLmFkZEV2ZW50TGlz
dGVuZXIoJ2NsaWNrJywgZSA9PiB7CiAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICBj
bG9zZUNsZWFyRGxnKCk7CiAgICB9KTsKICAgIGNsckRsZy5hZGRFdmVudExpc3RlbmVyKCdjbGljaycs
IGUgPT4gewogICAgICAgIGlmIChlLnRhcmdldCA9PT0gY2xyRGxnKSBjbG9zZUNsZWFyRGxnKCk7CiAg
ICB9KTsKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjbHItb2snKS5hZGRFdmVudExpc3RlbmVy
KCdjbGljaycsIGUgPT4gewogICAgICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAgICAgY29uc3Qg
c2NvcGUgPSAoY3VyVGFiID09PSAncmVjZW50JykgPyAnYWxsJyA6IChjbHJBbGxDYi5jaGVja2VkID8g
J2FsbCcgOiAndG9kYXknKTsKICAgICAgICBjbG9zZUNsZWFyRGxnKCk7CiAgICAgICAgYWhrKCdjbGVh
cicsIGN1clRhYiwgc2NvcGUpOwogICAgfSk7CiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbXVs
dGktc2VsJykuYWRkRXZlbnRMaXN0ZW5lcignY2xpY2snLCBlID0+IHsKICAgICAgICBlLnN0b3BQcm9w
YWdhdGlvbigpOwogICAgICAgIGNsZWFyTXVsdGkodHJ1ZSk7CiAgICB9KTsKICAgIGRvY3VtZW50Lmdl
dEVsZW1lbnRCeUlkKCdidG4tcGluJykuYWRkRXZlbnRMaXN0ZW5lcignY2xpY2snLCBlID0+IHsKICAg
ICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgICAgIHBpbm5lZFVJID0gIXBpbm5lZFVJOwogICAg
ICAgIGUuY3VycmVudFRhcmdldC5jbGFzc0xpc3QudG9nZ2xlKCdvbicsIHBpbm5lZFVJKTsKICAgICAg
ICBhaGsoJ3RvZ2dsZVBpbicsIHBpbm5lZFVJID8gJzEnIDogJzAnKTsKICAgIH0pOwoKICAgIHdpbmRv
dy5fX3BlcmZNYXJrID0gKHN0YWdlKSA9PiB7CiAgICAgICAgdHJ5IHsKICAgICAgICAgICAgaWYgKHdp
bmRvdy5jaHJvbWUgJiYgY2hyb21lLndlYnZpZXcgJiYgY2hyb21lLndlYnZpZXcucG9zdE1lc3NhZ2Up
CiAgICAgICAgICAgICAgICBjaHJvbWUud2Vidmlldy5wb3N0TWVzc2FnZSgncGVyZnwnICsgU3RyaW5n
KHN0YWdlIHx8ICcnKSk7CiAgICAgICAgfSBjYXRjaCB7fQogICAgfTsKCiAgICB3aW5kb3cuX191cGRh
dGVDbGlwcyA9IHBheWxvYWQgPT4gewogICAgICAgIGNvbnN0IHQwID0gKHR5cGVvZiBwZXJmb3JtYW5j
ZSAhPT0gJ3VuZGVmaW5lZCcgJiYgcGVyZm9ybWFuY2Uubm93KSA/IHBlcmZvcm1hbmNlLm5vdygpIDog
RGF0ZS5ub3coKTsKICAgICAgICB3aW5kb3cuX19wZXJmTWFyaygnanNfdXBkYXRlQ2xpcHNfZW50ZXIg
bj0nICsgKHBheWxvYWQgJiYgcGF5bG9hZC5pdGVtcyA/IHBheWxvYWQuaXRlbXMubGVuZ3RoIDogKEFy
cmF5LmlzQXJyYXkocGF5bG9hZCkgPyBwYXlsb2FkLmxlbmd0aCA6IDApKSk7CiAgICAgICAgLy8gS2Vl
cCBwcmV2aW91cyBzY3JvbGwgZm9yIGxvYWQtbW9yZTsgcmVzZXQgd2hlbiBvcGVuaW5nIHBhbmVsIHRv
IGZpcnN0IGl0ZW0KICAgICAgICBjb25zdCBrZWVwU2Nyb2xsID0gIXNlbGVjdEZpcnN0T25TaG93Owog
ICAgICAgIGNvbnN0IHN0ID0gbGlzdEVsLnNjcm9sbFRvcDsKICAgICAgICB3aW5kb3cuX193YWl0aW5n
VmlldyA9IGZhbHNlOwogICAgICAgIGNvbnN0IHdhc0FwcGVuZCA9IHBheWxvYWQgJiYgcGF5bG9hZC5h
cHBlbmQ7CiAgICAgICAgbG9hZGluZ01vcmUgPSBmYWxzZTsKICAgICAgICBjb25zdCBwcmV2SXRlbXMg
PSBhbGxDbGlwczsKICAgICAgICBsZXQgbmV4dEl0ZW1zID0gW107CiAgICAgICAgbGV0IG5leHRUb3Rh
bCA9IDA7CiAgICAgICAgbGV0IG5leHRGaWx0ZXJlZCA9IGZhbHNlOwogICAgICAgIGxldCBwVGFiID0g
Jyc7CiAgICAgICAgbGV0IHBQaW5uZWRUb3RhbCA9IC0xOwogICAgICAgIGlmIChBcnJheS5pc0FycmF5
KHBheWxvYWQpKSB7CiAgICAgICAgICAgIG5leHRJdGVtcyA9IHBheWxvYWQ7CiAgICAgICAgICAgIG5l
eHRUb3RhbCA9IHBheWxvYWQubGVuZ3RoOwogICAgICAgICAgICBuZXh0RmlsdGVyZWQgPSBmYWxzZTsK
ICAgICAgICB9IGVsc2UgaWYgKHBheWxvYWQgJiYgdHlwZW9mIHBheWxvYWQgPT09ICdvYmplY3QnKSB7
CiAgICAgICAgICAgIG5leHRUb3RhbCA9IE51bWJlcihwYXlsb2FkLnRvdGFsKSB8fCAwOwogICAgICAg
ICAgICBuZXh0SXRlbXMgPSBBcnJheS5pc0FycmF5KHBheWxvYWQuaXRlbXMpID8gcGF5bG9hZC5pdGVt
cyA6IFtdOwogICAgICAgICAgICBwVGFiID0gcGF5bG9hZC50YWIgIT0gbnVsbCA/IFN0cmluZyhwYXls
b2FkLnRhYikgOiAnJzsKICAgICAgICAgICAgaWYgKHBheWxvYWQucGlubmVkVG90YWwgIT0gbnVsbCAm
JiBwYXlsb2FkLnBpbm5lZFRvdGFsICE9PSAnJykKICAgICAgICAgICAgICAgIHBQaW5uZWRUb3RhbCA9
IE51bWJlcihwYXlsb2FkLnBpbm5lZFRvdGFsKSB8fCAwOwogICAgICAgICAgICBjb25zdCBwcTAgPSBw
YXlsb2FkLnF1ZXJ5ICE9IG51bGwgPyBTdHJpbmcocGF5bG9hZC5xdWVyeSkgOiAnJzsKICAgICAgICAg
ICAgbmV4dEZpbHRlcmVkID0gISEocGF5bG9hZC5maWx0ZXJlZCB8fCAocHEwICYmIHBxMC50cmltKCkp
KTsKICAgICAgICAgICAgaWYgKHBheWxvYWQuYXBwZW5kKSB7CiAgICAgICAgICAgICAgICAvLyBBcHBl
bmQgb25seSBhcHBsaWVzIHRvIHRoZSB0YWIgd2UncmUgY3VycmVudGx5IHZpZXdpbmcKICAgICAgICAg
ICAgICAgIGlmIChwVGFiICYmIHBUYWIgIT09IGN1clRhYikKICAgICAgICAgICAgICAgICAgICByZXR1
cm47CiAgICAgICAgICAgICAgICBjb25zdCBzZWVuID0gbmV3IFNldChhbGxDbGlwcy5tYXAoYyA9PiAr
Yy5pZCkpOwogICAgICAgICAgICAgICAgY29uc3QgbWVyZ2VkID0gYWxsQ2xpcHMuc2xpY2UoKTsKICAg
ICAgICAgICAgICAgIG5leHRJdGVtcy5mb3JFYWNoKGl0ID0+IHsKICAgICAgICAgICAgICAgICAgICBp
ZiAoIXNlZW4uaGFzKCtpdC5pZCkpIG1lcmdlZC5wdXNoKGl0KTsKICAgICAgICAgICAgICAgIH0pOwog
ICAgICAgICAgICAgICAgbmV4dEl0ZW1zID0gbWVyZ2VkOwogICAgICAgICAgICAgICAgbmV4dFRvdGFs
ID0gTWF0aC5tYXgobmV4dFRvdGFsLCBuZXh0SXRlbXMubGVuZ3RoKTsKICAgICAgICAgICAgfQogICAg
ICAgICAgICAvLyDmkJzntKLmoYbku6XmiZPlrZfplZzlg4/kuLrlh4bvvIznu53kuI3ooqvmu57lkI7n
moTno4Hnm5jnu5Pmnpzlhpnlm57ml6flhbPplK7lrZcKICAgICAgICAgICAgdHJ5IHsKICAgICAgICAg
ICAgICAgIGNvbnN0IHMgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc2VhcmNoJyk7CiAgICAgICAg
ICAgICAgICBpZiAocyAmJiBTdHJpbmcocy52YWx1ZSB8fCAnJykubGVuZ3RoKQogICAgICAgICAgICAg
ICAgICAgIHF1ZXJ5ID0gcy52YWx1ZTsKICAgICAgICAgICAgICAgIGVsc2UgaWYgKHBxMCAhPT0gJycg
JiYgIVN0cmluZyhxdWVyeSB8fCAnJykudHJpbSgpKQogICAgICAgICAgICAgICAgICAgIHF1ZXJ5ID0g
cHEwOwogICAgICAgICAgICB9IGNhdGNoIHt9CiAgICAgICAgfSBlbHNlIHsKICAgICAgICAgICAgbmV4
dEl0ZW1zID0gW107CiAgICAgICAgICAgIG5leHRUb3RhbCA9IDA7CiAgICAgICAgICAgIG5leHRGaWx0
ZXJlZCA9IGZhbHNlOwogICAgICAgIH0KCiAgICAgICAgY29uc3QgYm94USA9IFN0cmluZyhxdWVyeSB8
fCAnJykudHJpbSgpOwogICAgICAgIGNvbnN0IHB1c2hRID0gKHBheWxvYWQgJiYgdHlwZW9mIHBheWxv
YWQgPT09ICdvYmplY3QnICYmIHBheWxvYWQucXVlcnkgIT0gbnVsbCkKICAgICAgICAgICAgPyBTdHJp
bmcocGF5bG9hZC5xdWVyeSkudHJpbSgpIDogJyc7CgogICAgICAgIC8vIEFsd2F5cyByZWZyZXNoIOaU
tuiXjyBiYWRnZSBmcm9tIGhvc3Qgd2hlbiBwcm92aWRlZAogICAgICAgIGlmIChwUGlubmVkVG90YWwg
Pj0gMCkKICAgICAgICAgICAgcGlubmVkVG90YWwgPSBwUGlubmVkVG90YWw7CgogICAgICAgIC8vIFN0
YWxlIHNlYXJjaCBwdXNoIChlLmcuICJzcXVhcmUgbG9naSIgbGFuZHMgYWZ0ZXIgdXNlciB0eXBlZCAi
c3F1YXJlIGxvZ2luIikg4oCUY2FjaGUgb25seQogICAgICAgIGlmICghd2FzQXBwZW5kICYmIG5leHRG
aWx0ZXJlZCAmJiBwdXNoUSAmJiBib3hRICYmIHB1c2hRICE9PSBib3hRKSB7CiAgICAgICAgICAgIHZp
ZXdNZW0uc2V0KHZpZXdNZW1LZXkocFRhYiB8fCBjdXJUYWIsIHB1c2hRLCB0b2RheU9ubHkpLCB7CiAg
ICAgICAgICAgICAgICBpdGVtczogbmV4dEl0ZW1zLnNsaWNlKCksCiAgICAgICAgICAgICAgICB0b3Rh
bDogbmV4dFRvdGFsCiAgICAgICAgICAgIH0pOwogICAgICAgICAgICByZXR1cm47CiAgICAgICAgfQoK
ICAgICAgICAvLyBTdGFsZSBwdXNoIGZvciBhbm90aGVyIHRhYjogb25seSByZWZyZXNoIHRoYXQgdGFi
J3Mgdmlld01lbSwgZG9uJ3QgaGlqYWNrIFVJCiAgICAgICAgaWYgKCF3YXNBcHBlbmQgJiYgcFRhYiAm
JiBwVGFiICE9PSBjdXJUYWIpIHsKICAgICAgICAgICAgY29uc3QgbWVtUSA9IChwYXlsb2FkICYmIHR5
cGVvZiBwYXlsb2FkID09PSAnb2JqZWN0JyAmJiBwYXlsb2FkLnF1ZXJ5ICE9IG51bGwpCiAgICAgICAg
ICAgICAgICA/IFN0cmluZyhwYXlsb2FkLnF1ZXJ5KSA6ICcnOwogICAgICAgICAgICB2aWV3TWVtLnNl
dCh2aWV3TWVtS2V5KHBUYWIsIG1lbVEsIHRvZGF5T25seSksIHsKICAgICAgICAgICAgICAgIGl0ZW1z
OiBuZXh0SXRlbXMuc2xpY2UoKSwKICAgICAgICAgICAgICAgIHRvdGFsOiBuZXh0VG90YWwKICAgICAg
ICAgICAgfSk7CiAgICAgICAgICAgIC8vIFN0aWxsIHVwZGF0ZSBwaW4gYmFkZ2UgaWYgaG9zdCBzZW50
IGl0CiAgICAgICAgICAgIHRyeSB7IHVwZGF0ZVBpbkRvdCgpOyB9IGNhdGNoIHt9CiAgICAgICAgICAg
IC8vIFFRIOaQnOe0ouabvuWbuuWumuaOqCBhbGwgdGFiIOKGkiDlvZPliY0gdGFiIOS8muS4gOebtOmq
qOaetu+8m+ihpeS4gOasoSByZXF1ZXN0VmlldwogICAgICAgICAgICBpZiAod2FpdGluZ0RhdGEgJiYg
cHVzaFEgPT09IGJveFEpIHsKICAgICAgICAgICAgICAgIHNldFRpbWVvdXQoKCkgPT4gewogICAgICAg
ICAgICAgICAgICAgIGlmICh3YWl0aW5nRGF0YSAmJiBjdXJUYWIgIT09IHBUYWIpCiAgICAgICAgICAg
ICAgICAgICAgICAgIHJlcXVlc3RWaWV3KCk7CiAgICAgICAgICAgICAgICB9LCA0MCk7CiAgICAgICAg
ICAgIH0KICAgICAgICAgICAgcmV0dXJuOwogICAgICAgIH0KCiAgICAgICAgLy8gQm9vdHN0cmFwIHJh
Y2U6IEFISyBwdXNoZWQgZW1wdHkgYmVmb3JlIFdhcm1BbGxWaWV3cyDigJRrZWVwIHNrZWxldG9uLCBp
Z25vcmUKICAgICAgICBjb25zdCBxT24gPSBTdHJpbmcocXVlcnkgfHwgJycpLnRyaW0oKS5sZW5ndGgg
PiAwOwogICAgICAgIGlmICghd2FzQXBwZW5kICYmICFuZXh0SXRlbXMubGVuZ3RoICYmIG5leHRUb3Rh
bCA8PSAwICYmICFxT24gJiYgIW5leHRGaWx0ZXJlZCAmJiAhc2F3Tm9uRW1wdHkpIHsKICAgICAgICAg
ICAgaWYgKCF3aW5kb3cuX19lbXB0eUZhbGxiYWNrVCkgewogICAgICAgICAgICAgICAgd2luZG93Ll9f
ZW1wdHlGYWxsYmFja1QgPSBzZXRUaW1lb3V0KCgpID0+IHsKICAgICAgICAgICAgICAgICAgICB3aW5k
b3cuX19lbXB0eUZhbGxiYWNrVCA9IDA7CiAgICAgICAgICAgICAgICAgICAgaWYgKHNhd05vbkVtcHR5
KSByZXR1cm47CiAgICAgICAgICAgICAgICAgICAgLy8gVHJ1bHkgZW1wdHkgaW5zdGFsbCBhZnRlciB3
YWl0CiAgICAgICAgICAgICAgICAgICAgc2F3Tm9uRW1wdHkgPSB0cnVlOwogICAgICAgICAgICAgICAg
ICAgIGhvc3RQdXNoZWRPbmNlID0gdHJ1ZTsKICAgICAgICAgICAgICAgICAgICB3aW5kb3cuX19kYXRh
UmVhZHkgPSB0cnVlOwogICAgICAgICAgICAgICAgICAgIGFsbENsaXBzID0gW107CiAgICAgICAgICAg
ICAgICAgICAgZGlza1RvdGFsID0gMDsKICAgICAgICAgICAgICAgICAgICBjbGVhcldhaXRpbmdEYXRh
KCk7CiAgICAgICAgICAgICAgICAgICAgdHJ5IHsgcmVuZGVyKCk7IH0gY2F0Y2gge30KICAgICAgICAg
ICAgICAgIH0sIDQ1MDApOwogICAgICAgICAgICB9CiAgICAgICAgICAgIHdhaXRpbmdEYXRhID0gdHJ1
ZTsKICAgICAgICAgICAgd2luZG93Ll9fZGF0YVJlYWR5ID0gZmFsc2U7CiAgICAgICAgICAgIGhvc3RQ
dXNoZWRPbmNlID0gZmFsc2U7CiAgICAgICAgICAgIHNldEJvb3RMb2FkaW5nKHRydWUpOwogICAgICAg
ICAgICB0cnkgeyByZW5kZXIoKTsgfSBjYXRjaCB7fQogICAgICAgICAgICByZXR1cm47CiAgICAgICAg
fQoKICAgICAgICBjbGVhcldhaXRpbmdEYXRhKCk7CiAgICAgICAgYWxsQ2xpcHMgPSBuZXh0SXRlbXM7
CiAgICAgICAgZGlza1RvdGFsID0gbmV4dFRvdGFsOwogICAgICAgIC8vIEtlZXAgYmFyIGNvbnNpc3Rl
bnQgaWYgbGlzdCBncmV3IHBhc3QgYSBzdGFsZSB0b3RhbAogICAgICAgIGlmIChhbGxDbGlwcy5sZW5n
dGggPiBkaXNrVG90YWwpCiAgICAgICAgICAgIGRpc2tUb3RhbCA9IGFsbENsaXBzLmxlbmd0aDsKICAg
ICAgICB3aW5kb3cuX19ob3N0RmlsdGVyZWQgPSBuZXh0RmlsdGVyZWQ7CiAgICAgICAgd2luZG93Ll9f
aG9zdEZpbHRlclEgPSAobmV4dEZpbHRlcmVkICYmIHB1c2hRKSA/IHB1c2hRIDogJyc7CiAgICAgICAg
Ly8gRmlsdGVyZWQgc2VhcmNoIHdpdGggMCBoaXRzIOKAlG11c3QgbGVhdmUgc2tlbGV0b24gKGhvc3Qg
ZGlkIHJlc3BvbmQpCiAgICAgICAgaWYgKCF3YXNBcHBlbmQgJiYgbmV4dEZpbHRlcmVkICYmICFhbGxD
bGlwcy5sZW5ndGggJiYgZGlza1RvdGFsIDw9IDApIHsKICAgICAgICAgICAgaG9zdFB1c2hlZE9uY2Ug
PSB0cnVlOwogICAgICAgICAgICBzYXdOb25FbXB0eSA9IHRydWU7CiAgICAgICAgfQogICAgICAgIGlm
IChhbGxDbGlwcy5sZW5ndGggfHwgZGlza1RvdGFsID4gMCkKICAgICAgICAgICAgc2F3Tm9uRW1wdHkg
PSB0cnVlOwogICAgICAgIGlmICh3aW5kb3cuX19lbXB0eUZhbGxiYWNrVCkgewogICAgICAgICAgICBj
bGVhclRpbWVvdXQod2luZG93Ll9fZW1wdHlGYWxsYmFja1QpOwogICAgICAgICAgICB3aW5kb3cuX19l
bXB0eUZhbGxiYWNrVCA9IDA7CiAgICAgICAgfQogICAgICAgIGlmICghd2FzQXBwZW5kKSB7CiAgICAg
ICAgICAgIGNvbnN0IG1lbVEgPSAocGF5bG9hZCAmJiB0eXBlb2YgcGF5bG9hZCA9PT0gJ29iamVjdCcg
JiYgcGF5bG9hZC5xdWVyeSAhPSBudWxsKQogICAgICAgICAgICAgICAgPyBTdHJpbmcocGF5bG9hZC5x
dWVyeSkgOiBxdWVyeTsKICAgICAgICAgICAgdmlld01lbS5zZXQodmlld01lbUtleShjdXJUYWIsIG1l
bVEsIHRvZGF5T25seSksIHsKICAgICAgICAgICAgICAgIGl0ZW1zOiBhbGxDbGlwcy5zbGljZSgpLAog
ICAgICAgICAgICAgICAgdG90YWw6IGRpc2tUb3RhbAogICAgICAgICAgICB9KTsKICAgICAgICB9CiAg
ICAgICAgd2luZG93Ll9fZGF0YVJlYWR5ID0gdHJ1ZTsKICAgICAgICBob3N0UHVzaGVkT25jZSA9IHRy
dWU7CgogICAgICAgIC8vIE1pZC13aGVlbDoga2VlcCBkYXRhLCBkZWxheSBET00gc28gc2Nyb2xsL2Ry
YWcgbmV2ZXIgaGl0Y2ggb24gYXBwZW5kIHBhaW50CiAgICAgICAgaWYgKHdhc0FwcGVuZCAmJiB3aW5k
b3cuX19zY3JvbGxCdXN5ICYmICF3aW5kb3cuX19wZW5kaW5nSnVtcElkKSB7CiAgICAgICAgICAgIGNv
bnN0IGZyb21MZW4gPSAocHJldkl0ZW1zICYmIHByZXZJdGVtcy5sZW5ndGgpID8gcHJldkl0ZW1zLmxl
bmd0aCA6IDA7CiAgICAgICAgICAgIGlmICghX3BlbmRpbmdBcHBlbmQpCiAgICAgICAgICAgICAgICBf
cGVuZGluZ0FwcGVuZCA9IHsgZnJvbUxlbjogZnJvbUxlbiB9OwogICAgICAgICAgICB0cnkgeyByZWZy
ZXNoTGlzdENocm9tZSgpOyB9IGNhdGNoIHt9CiAgICAgICAgICAgIHJldHVybjsKICAgICAgICB9Cgog
ICAgICAgIGNvbnN0IHdhc0Jvb3RMb2FkaW5nID0gYm9vdExvYWRpbmc7CiAgICAgICAgbGV0IHNhbWVQ
YWludCA9IGZhbHNlOwogICAgICAgIGNvbnN0IHByZXZMZW4gPSAocHJldkl0ZW1zICYmIHByZXZJdGVt
cy5sZW5ndGgpID8gcHJldkl0ZW1zLmxlbmd0aCA6IDA7CiAgICAgICAgaWYgKCF3YXNBcHBlbmQgJiYg
IXdhc0Jvb3RMb2FkaW5nICYmIHByZXZJdGVtcyAmJiBwcmV2SXRlbXMubGVuZ3RoID09PSBhbGxDbGlw
cy5sZW5ndGggJiYgcHJldkl0ZW1zLmxlbmd0aCkgewogICAgICAgICAgICBzYW1lUGFpbnQgPSB0cnVl
OwogICAgICAgICAgICBmb3IgKGxldCBpID0gMDsgaSA8IGFsbENsaXBzLmxlbmd0aDsgaSsrKSB7CiAg
ICAgICAgICAgICAgICBpZiAoK3ByZXZJdGVtc1tpXS5pZCAhPT0gK2FsbENsaXBzW2ldLmlkKSB7IHNh
bWVQYWludCA9IGZhbHNlOyBicmVhazsgfQogICAgICAgICAgICB9CiAgICAgICAgICAgIGlmIChzYW1l
UGFpbnQgJiYgIWxpc3RFbC5xdWVyeVNlbGVjdG9yKCcuaXRtJykpIHNhbWVQYWludCA9IGZhbHNlOwog
ICAgICAgIH0KICAgICAgICBjb25zdCBmaW5pc2hVcGRhdGUgPSAoKSA9PiB7CiAgICAgICAgICAgIGNv
bnN0IHRSZW5kZXIwID0gKHR5cGVvZiBwZXJmb3JtYW5jZSAhPT0gJ3VuZGVmaW5lZCcgJiYgcGVyZm9y
bWFuY2Uubm93KSA/IHBlcmZvcm1hbmNlLm5vdygpIDogRGF0ZS5ub3coKTsKICAgICAgICAgICAgY2xl
YXJXYWl0aW5nRGF0YSgpOwogICAgICAgICAgICBpZiAod2FzQXBwZW5kICYmICF3YXNCb290TG9hZGlu
ZyAmJiBwcmV2TGVuID4gMCAmJiBhbGxDbGlwcy5sZW5ndGggPiBwcmV2TGVuKSB7CiAgICAgICAgICAg
ICAgICBhcHBlbmRSZW5kZXIocHJldkxlbik7CiAgICAgICAgICAgIH0gZWxzZSBpZiAoIXNhbWVQYWlu
dCkgewogICAgICAgICAgICAgICAgcmVuZGVyKCk7CiAgICAgICAgICAgICAgICBhcHBseVRhYlN3aXRj
aEFuaW0oKTsKICAgICAgICAgICAgICAgIGlmIChrZWVwU2Nyb2xsKQogICAgICAgICAgICAgICAgICAg
IGxpc3RFbC5zY3JvbGxUb3AgPSBzdDsKICAgICAgICAgICAgICAgIGVsc2UKICAgICAgICAgICAgICAg
ICAgICBsaXN0RWwuc2Nyb2xsVG9wID0gMDsKICAgICAgICAgICAgfSBlbHNlIHsKICAgICAgICAgICAg
ICAgIHRyeSB7IHJlZnJlc2hMaXN0Q2hyb21lKCk7IH0gY2F0Y2gge30KICAgICAgICAgICAgICAgIGlm
IChrZWVwU2Nyb2xsKQogICAgICAgICAgICAgICAgICAgIGxpc3RFbC5zY3JvbGxUb3AgPSBzdDsKICAg
ICAgICAgICAgfQogICAgICAgICAgICBjb25zdCB0MSA9ICh0eXBlb2YgcGVyZm9ybWFuY2UgIT09ICd1
bmRlZmluZWQnICYmIHBlcmZvcm1hbmNlLm5vdykgPyBwZXJmb3JtYW5jZS5ub3coKSA6IERhdGUubm93
KCk7CiAgICAgICAgICAgIHdpbmRvdy5fX3BlcmZNYXJrKCdqc191cGRhdGVDbGlwc19kb25lIHJlbmRl
ck1zPScgKyBNYXRoLnJvdW5kKHQxIC0gdFJlbmRlcjApICsgJyB0b3RhbE1zPScgKyBNYXRoLnJvdW5k
KHQxIC0gdDApICsgJyBuPScgKyBhbGxDbGlwcy5sZW5ndGgpOwogICAgICAgIH07CiAgICAgICAgaWYg
KHdhc0Jvb3RMb2FkaW5nKSB7CiAgICAgICAgICAgIGNvbnN0IHNpbmNlID0gd2luZG93Ll9fc2tlbFNp
bmNlIHx8IDA7CiAgICAgICAgICAgIGNvbnN0IHdhaXQgPSBzaW5jZSA/IE1hdGgubWF4KDAsIDgwIC0g
KERhdGUubm93KCkgLSBzaW5jZSkpIDogMDsKICAgICAgICAgICAgaWYgKHdhaXQgPiAwKQogICAgICAg
ICAgICAgICAgc2V0VGltZW91dChmaW5pc2hVcGRhdGUsIHdhaXQpOwogICAgICAgICAgICBlbHNlCiAg
ICAgICAgICAgICAgICBmaW5pc2hVcGRhdGUoKTsKICAgICAgICB9IGVsc2UgewogICAgICAgICAgICBm
aW5pc2hVcGRhdGUoKTsKICAgICAgICB9CiAgICB9OwogICAgd2luZG93Ll9fc2V0UGlubmVkID0gdiA9
PiB7CiAgICAgICAgcGlubmVkVUkgPSAhIXY7CiAgICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQo
J2J0bi1waW4nKS5jbGFzc0xpc3QudG9nZ2xlKCdvbicsIHBpbm5lZFVJKTsKICAgIH07CiAgICB3aW5k
b3cuX19sb2FkTW9yZURvbmUgPSAoKSA9PiB7CiAgICAgICAgbG9hZGluZ01vcmUgPSBmYWxzZTsKICAg
ICAgICBpZiAod2luZG93Ll9fbG9hZE1vcmVXYXRjaCkgewogICAgICAgICAgICBjbGVhclRpbWVvdXQo
d2luZG93Ll9fbG9hZE1vcmVXYXRjaCk7CiAgICAgICAgICAgIHdpbmRvdy5fX2xvYWRNb3JlV2F0Y2gg
PSAwOwogICAgICAgIH0KICAgICAgICBpZiAod2luZG93Ll9fcGVuZGluZ0p1bXBJZCkKICAgICAgICAg
ICAgdHJ5Q29udGludWVKdW1wKCk7CiAgICB9OwoKICAgIGluaXRTZXBVaSgpOwogICAgdXBkYXRlUGlu
RG90KCk7CiAgICBzY2hlZHVsZURlbGF5ZWRTa2VsKCk7CiAgICB3aW5kb3cuX19wZXJmTWFyayAmJiB3
aW5kb3cuX19wZXJmTWFyaygnanNfYm9vdCByZXF1ZXN0VmlldycpOwogICAgcmVxdWVzdFZpZXcoKTsK
ICAgIC8vIHNjaGVkdWxlRGVsYXllZFNrZWwgYWxyZWFkeSByZW5kZXIoKSdkIHdoZW4gZW1wdHk7IHN0
aWxsIHBhaW50IG9uY2UgZm9yIGNocm9tZQoKICAgIDwvc2NyaXB0Pgo8L2JvZHk+CjwvaHRtbD4=
)"

global clips   := []
global clipUidSeq := 0
global lastAppendCount := 0
global viewTab := "all"
global viewQuery := ""
global viewToday := false
global viewTotal := 0
global viewCache := Map()
global searchPools := Map()   ; only all + pinned pools (tab+today -> { items, groups })
global diskJobQueue := []
global diskJobBusy := false
global guiWin  := ""
global wv      := ""
global wvCore  := ""
global lastTxt := ""
global lastImg := ""
global uiPinned := false
global prevActiveWin := 0
global clipIgnore := false
global clipReady := false          ; false until InitClipsFromDisk + settle (boot copy = crash)
global diskScanBusy := false
global firstAllPaintDone := false  ; true after first 20 of all tab ready
global firstOpenT0 := 0            ; PERF timeline anchor (ShowPanel first open)
global uiNavReady := false         ; true after full index.html NavigationCompleted
global viewSwitchGuardUntil := 0  ; 切 tab 扫盘期间忽略外侧点击，避免卡完面板被藏掉
global viewApplyGen := 0          ; SetView 代数：Sleep 让出后丢弃过期结果
global viewApplying := false      ; 扫盘中禁止把「旧 clips + 新 query」推给 UI
global pasteLockUntil := 0
global pasteSending := false
global pasteQueueMode := false          ; Ctrl+Shift+C queue paste mode
global pasteQueueIds := []              ; FIFO uid list
global pasteQueueGroupId := 0           ; visual group id for UI connector lines
global pasteQueueDone := 0              ; how many FIFO pastes in this session
global queueCaptureArmed := false       ; next AddClipItem joins the queue
global queueSuppressExit := false       ; ignore ~^c exit while we Send ^c for queue copy
global queueFifoPasteding := false      ; ignore re-entry during FIFO paste
global queueFifoPasteAt := 0            ; tick of last FIFO paste start
global queueCopyGen := 0                ; generation for arm timeout
global lastKeyboardCopyAt := 0          ; tick of last real Ctrl+C / Ctrl+X (not Ctrl+click)
global ctrlMouseCopyUntil := 0          ; Ctrl+LButton 开窗：剪贴板异步到达时 Ctrl 可能已松开
global queueTipGui := 0
global queueTipSeq := 0
global queueMetaMap := Map()            ; uid -> {g, i} persisted for UI after restart
global lastCaretX := 0
global lastCaretY := 0
global hasCaretPos := false
global panelVisible := false
global searchFocused := false
global qqSearchOn := false
global qqQuery := ""
global qqIh := 0
global qqPending := false
global qqNeedRelease := false
global qqPanelPlaced := false
global qqMarkCount := 0
global qqAwaitKeyword := false
global linkMetaQueue := []
global linkMetaPausedUntil := 0
global wvBuilding := false
global uiPushPending := false
global uiPushTimerArmed := false
global liveFront := []   ; recently copied items not yet confirmed on disk (survive SetView)
global recentFolders := []  ; Explorer folders (type=recent), newest first
global recentFolderUidSeq := 800000000
global lastExplorerFolder := ""
global pendingViewTab := "all"
global pendingViewQuery := ""
global pendingViewToday := "0"
global pendingViewArmed := false
; List-thumb inject: chunked + cancellable so tab switches stay responsive
global listThumbUrlCache := Map()   ; imgFile -> { mt, url }
global thumbPushGen := 0
global thumbPushQueue := []
global thumbPushArmed := false
global thumbPushedUids := Map()     ; uid already injected this session
global tabTotals := Map()           ; ViewCacheKey -> known total (skip full rescan)
global pruneScreenshotsArmed := false
global pruneScreenshotsPending := false

TraySetIcon("shell32.dll", 261)
A_TrayMenu.Delete()
A_TrayMenu.Add("显示剪贴板", (*) => ShowPanel())
A_TrayMenu.Add("清空历史",   (*) => ClearAll())
A_TrayMenu.Add()
A_TrayMenu.Add("退出",       (*) => ExitApp())
A_TrayMenu.Default := "显示剪贴板"
A_IconTip := "ClipboardManager  (Win+V)"

; Hotkeys are registered at the end of auto-execute (after EnsureDataDir / BuildGui)
; so a failed early init cannot leave the script without any show shortcut.

; Do NOT hook ~^v to PastePngToDir here:
; Explorer/Desktop already creates a file on Ctrl+V, and 快捷键4 pastpng2dir also saves —
; a third/second save here made desktop Ctrl+V produce duplicate images.
;
; OnClipboardChange is registered AFTER InitClipsFromDisk (EnableClipboardWatch).
; Early register raced boot init →freeze/exit + history wipe on copy-right-after-start.

; =================================================
;  Panel hotkeys: while panel is open, keys go to clipboard
;  even if the editor still has focus (NoActivate popup)
; =================================================
; Always-on while panel visible (search / pin / unfocused all OK):
;   Ctrl+I/K = move selection, Ctrl+J/L = switch tabs, Ctrl+F = open search
#HotIf ClipPanelIsUp()
$^i::PanelKeyUp("")
$^k::PanelKeyDown("")
$^j::PanelKeyPrevTab("")
$^l::PanelKeyNextTab("")
$^f::PanelOpenSearch("")
F2::PanelKeyEditTitle("")
#HotIf

; ?? 搜索中（面板可能已 SoftHide）：Esc 结束本次搜索
#HotIf qqSearchOn
Esc::EscHidePanel("")
#HotIf

; Unpinned: arrows / Enter / Esc hide
#HotIf ClipPanelIsUp() && !uiPinned
Up::PanelKeyUp("")
Down::PanelKeyDown("")
Enter::PanelKeyEnter("")
Esc::EscHidePanel("")
~LButton::OnOutsideClick("")
~LAlt::EscHidePanel("")
~RAlt::EscHidePanel("")
#HotIf

; Pinned: arrows still navigate；回车不粘贴（点条目才粘贴）
#HotIf ClipPanelIsUp() && uiPinned
Up::PanelKeyUp("")
Down::PanelKeyDown("")
#HotIf

ClipPanelIsUp(*) {
    global panelVisible, guiWin
    if panelVisible
        return true
    try {
        if IsObject(guiWin) && guiWin.Hwnd && DllCall("IsWindowVisible", "Ptr", guiWin.Hwnd, "Int")
            return true
    }
    return false
}

; =================================================
;  Clipboard
; =================================================
ClipChanged(dataType) {
    global lastTxt, lastImg, clipIgnore, clipReady, diskScanBusy
    if clipIgnore || dataType = 0
        return
    ; Not ready yet (boot) —ignore; EnableClipboardWatch arms after InitClipsFromDisk
    if !clipReady {
        ClipLog("ClipChanged SKIP not-ready type=" dataType)
        return
    }
    ; Preload / heavy scan in progress —retry shortly (do not race disk)
    if diskScanBusy {
        ClipLog("ClipChanged DEFER diskScanBusy type=" dataType)
        dt := Integer(dataType)
        SetTimer(() => ClipChanged(dt), -500)
        return
    }
    ClipLog("ClipChanged ENTER type=" dataType)
    try ClipChangedSafe(dataType)
    catch as e {
        ClipLogErr("ClipChanged", e)
    }
    ClipLog("ClipChanged EXIT type=" dataType)
}

ClipChangedSafe(dataType) {
    global lastTxt, lastImg, clipIgnore
    if clipIgnore
        return
    ; Brief settle so clipboard formats are ready (too long blocked UI updates)
    Sleep 30

    hasFiles := DllCall("IsClipboardFormatAvailable", "UInt", 15, "Int")
    hasBmp   := DllCall("IsClipboardFormatAvailable", "UInt", 2, "Int")
    hasDib   := DllCall("IsClipboardFormatAvailable", "UInt", 8, "Int")
    hasDib5  := DllCall("IsClipboardFormatAvailable", "UInt", 17, "Int")
    hasImg   := hasBmp || hasDib || hasDib5 || (dataType = 2)
    ClipLog("ClipChanged formats files=" hasFiles " img=" hasImg " bmp=" hasBmp " dib=" hasDib " type=" dataType)

    item := { time: FormatTime(, "yyyy-MM-dd HH:mm:ss"), pinned: false, pasted: false }

    ; File drops first —skip ClipboardAll (can be huge / exotic shell formats →freeze)
    if hasFiles {
        ClipLog("ClipChanged branch=file getList")
        names := GetClipboardFileList()
        ClipLog("ClipChanged fileList n=" names.Length)
        if names.Length = 0 {
            raw := A_Clipboard
            if raw = "" {
                Sleep 60
                raw := A_Clipboard
            }
            if raw = ""
                return
            names := []
            for ln in StrSplit(raw, "`n", "`r") {
                ln := Trim(ln)
                if ln != ""
                    names.Push(ln)
            }
            ClipLog("ClipChanged fileList from text n=" names.Length)
        }
        if names.Length = 0
            return
        raw := ""
        for i, ln in names
            raw .= (i > 1 ? "`n" : "") ln
        item.type := "file"
        item.data := raw
        item.preview := raw
        item.fileCount := names.Length
        item.charCount := 0
        ClipLog("ClipChanged file path0=" SubStr(names[1], 1, 120))
        ApplyClipSrc(item)
        AddClipItem(item)
        return
    }

    ; Only keep ClipboardAll for non-file clips (paste fidelity); size-capped
    ClipLog("ClipChanged ClipboardAll begin")
    try {
        ca := ClipboardAll()
        if IsObject(ca) && ca.Size > 0 && ca.Size < 12 * 1024 * 1024 {
            item.clipAll := ca
            ClipLog("ClipChanged ClipboardAll size=" ca.Size)
        } else
            ClipLog("ClipChanged ClipboardAll skip size=" (IsObject(ca) ? ca.Size : 0))
    } catch as e {
        ClipLogErr("ClipboardAll", e)
    }

    if hasImg {
        ClipLog("ClipChanged branch=image ClipImageToBase64")
        img := ClipImageToBase64(&w, &h)
        ClipLog("ClipChanged image b64Len=" StrLen(img) " w=" w " h=" h)
        if img != "" && img != lastImg {
            lastImg := img
            item.type := "image"
            item.data := img
            item.preview := ""
            item.charCount := 0
            item.width := w
            item.height := h
            ApplyClipSrc(item)
            AddClipItem(item)
            return
        }
        if dataType = 2
            return
    }

    if dataType = 1 {
        global queueCaptureArmed, pasteQueueMode, pasteQueueIds, pasteQueueGroupId, pasteQueueDone
        global lastKeyboardCopyAt, ctrlMouseCopyUntil
        ClipLog("ClipChanged branch=text")
        txt := A_Clipboard
        if txt = "" {
            Sleep 60
            txt := A_Clipboard
        }
        ; Ctrl+鼠标点击复制：以「按下时」开窗，不要求剪贴板到达时仍按着 Ctrl
        ; （网页 clipboard.writeText 异步，松 Ctrl 后才写入 → 旧逻辑会漏入队）
        ; 普通 Ctrl+C：~^c 打 lastKeyboardCopyAt，这里跳过
        if !queueCaptureArmed
            && (A_TickCount <= ctrlMouseCopyUntil)
            && (A_TickCount - lastKeyboardCopyAt) > 480
            && !GetKeyState("C", "P") && !GetKeyState("X", "P") {
            PrunePasteQueueIds()
            if !pasteQueueMode || !pasteQueueIds.Length {
                pasteQueueMode := true
                pasteQueueIds := []
                pasteQueueDone := 0
                pasteQueueGroupId += 1
                ClipLog("PasteQueue Ctrl-click new session group=" pasteQueueGroupId)
            }
            queueCaptureArmed := true
            ctrlMouseCopyUntil := 0  ; one shot per click
            ClipLog("PasteQueue Ctrl-click armed n=" pasteQueueIds.Length)
        }
        ; Queue capture must accept even duplicate text (lastTxt), else ^+c feels "dead"
        if txt = "" || (txt = lastTxt && !queueCaptureArmed)
            return
        lastTxt := txt
        item.type := "text"
        item.data := txt
        item.preview := SubStr(txt, 1, 500)
        item.charCount := StrLen(txt)
        item.isMd := TextLooksLikeMarkdown(txt)
        item.isRich := ClipboardHasRichText()
        ApplyClipSrc(item)
        AddClipItem(item)
        AddLinksFromText(txt)
    }
}

; 剪贴板是否带 RTF / 带格式的 HTML（富文本）
ClipboardHasRichText(*) {
    static fmtRtf := 0, fmtHtml := 0
    if !fmtRtf
        try fmtRtf := DllCall("RegisterClipboardFormat", "Str", "Rich Text Format", "UInt")
    if !fmtHtml
        try fmtHtml := DllCall("RegisterClipboardFormat", "Str", "HTML Format", "UInt")
    if fmtRtf && DllCall("IsClipboardFormatAvailable", "UInt", fmtRtf, "Int")
        return true
    if !fmtHtml || !DllCall("IsClipboardFormatAvailable", "UInt", fmtHtml, "Int")
        return false
    ; 浏览器常给纯文本也挂 HTML：只有带明显格式才算富文本
    html := ClipboardGetHtmlSnippet(2400)
    if html = ""
        return true  ; 有 HTML 格式但读不到时仍视为富文本
    if RegExMatch(html, "i)</?(b|i|u|em|strong|h[1-6]|ul|ol|li|table|tr|td|th|img)\b")
        return true
    if RegExMatch(html, "i)\b(font-weight|font-style|text-decoration|background-color)\s*:")
        return true
    return false
}

ClipboardGetHtmlSnippet(maxLen := 2400) {
    static fmtHtml := 0
    if !fmtHtml
        try fmtHtml := DllCall("RegisterClipboardFormat", "Str", "HTML Format", "UInt")
    if !fmtHtml
        return ""
    if !DllCall("OpenClipboard", "Ptr", 0)
        return ""
    html := ""
    try {
        h := DllCall("GetClipboardData", "UInt", fmtHtml, "Ptr")
        if h {
            p := DllCall("GlobalLock", "Ptr", h, "Ptr")
            if p {
                ; HTML Format 多为 UTF-8 / ANSI 混合；按字节读一段即可做格式嗅探
                buf := Buffer(maxLen + 1, 0)
                DllCall("RtlMoveMemory", "Ptr", buf, "Ptr", p, "UPtr", maxLen)
                DllCall("GlobalUnlock", "Ptr", h)
                html := StrGet(buf, "UTF-8")
                if html = ""
                    html := StrGet(buf, "CP0")
            }
        }
    } finally {
        DllCall("CloseClipboard")
    }
    return html
}

; Markdown 启发式（与前端 isMarkdown 对齐）
TextLooksLikeMarkdown(txt) {
    s := String(txt)
    if StrLen(s) < 4
        return false
    ; AHK 里 ` 是转义符，代码围栏用 Chr(96) 拼出 ```
    fence := Chr(96) Chr(96) Chr(96)
    if InStr(s, fence)
        return true
    if RegExMatch(s, "m)^#{1,6} ")
        return true
    if RegExMatch(s, "m)^[-*+] ")
        return true
    if RegExMatch(s, "m)^> ")
        return true
    if RegExMatch(s, "\*\*[^*\r\n]+\*\*")
        return true
    if RegExMatch(s, "__[^_\r\n]+__")
        return true
    if RegExMatch(s, "\[[^\]]+\]\([^)]+\)")
        return true
    if RegExMatch(s, "\|.+\|.+\|")
        return true
    return false
}

AddClipItem(item) {
    global clips, wvCore, STORE_DIR, lastTxt
    ClipLog("AddClipItem begin type=" item.type)
    if !item.HasProp("uid") || !item.uid
        item.uid := NextClipUid()
    ClipLog("AddClipItem uid=" item.uid)
    ; Keep clipboard path light: do NOT write image/payload files here.
    ; Disk persist is async; UI must refresh from memory immediately.
    if item.type = "file" {
        ; NEVER FileCopy/GDI+ here —thumbs are lazy via EnsureFileClipThumb (async)
        ClipLog("AddClipItem file skip eager thumb (async EnsureFileClipThumb)")
    }
    ; Memory-first: update UI caches immediately, persist disk async
    ; Re-copy must inherit 收藏/标题 — otherwise DiskRemove*Equal deletes the pinned row
    ; and inserts a fresh unpinned clone (favorites appear "lost").
    ; EXCEPTION: queue capture needs a DISTINCT uid per FIFO slot. Collapsing onto an older
    ; equal-text row (MemoryTake + Inherit uid) is what turned 3 queue items into 2.
    global queueCaptureArmed
    if item.type = "text" {
        if !queueCaptureArmed {
            old := MemoryTakeTextEqual(item.data)
            InheritClipMeta(item, old)
        }
        lastTxt := item.data
    } else if item.type = "link" {
        if !queueCaptureArmed {
            old := MemoryTakeLinkEqual(item.data)
            InheritClipMeta(item, old)
            if IsObject(old) && old.HasProp("linkTitle") && old.linkTitle != ""
                item.linkTitle := old.linkTitle
        }
    } else if item.type = "file" {
        if !queueCaptureArmed {
            old := MemoryTakeFileEqual(item.data)
            InheritClipMeta(item, old)
            if IsObject(old) && old.HasProp("imgFile") && old.imgFile != "" && !(item.HasProp("imgFile") && item.imgFile != "")
                item.imgFile := old.imgFile
        }
        if FileClipLooksLikeImage(item) && !(item.HasProp("imgFile") && item.imgFile != "")
            SetTimer(EnsureFileClipThumbAndInject.Bind(item), -30)
    }
    ClipLog("AddClipItem MemoryInsertFront")
    MemoryInsertFront(item)
    ; Queue: Ctrl+Shift+C 入队；其它来源的剪贴板新增 → 结束队列
    global pasteQueueMode, queueCaptureArmed
    wasQueueArmed := queueCaptureArmed
    try EnqueuePasteQueueItem(item)
    if pasteQueueMode && !wasQueueArmed
        ExitPasteQueue("foreign-clip")
    ; Never call WebView sync from OnClipboardChange —it often drops the update.
    ; Defer a coalesced UI push so the open panel shows the new item immediately.
    RequestUiPush()
    ; Image payload is stripped from list JSON —inject a list thumb ASAP so UI is not blank
    if item.type = "image" && item.HasProp("data") && item.data != ""
        SetTimer(InjectLiveImageThumb.Bind(Integer(item.uid)), -15)
    ; Queue items already PrependDiskJob'd Persist — skip duplicate enqueue
    if (item.HasProp("_queuePersistQueued") && item._queuePersistQueued)
        || (item.HasProp("_queueSyncPersisted") && item._queueSyncPersisted) {
        ClipLog("AddClipItem skip async Persist (queue queued) uid=" item.uid)
    } else {
        ClipLog("AddClipItem Enqueue PersistNewItem")
        EnqueueDiskJob(PersistNewItem.Bind(item))
    }
    ClipLog("AddClipItem done uid=" item.uid)
}

AddLinksFromText(text) {
    urls := ExtractUrls(text)
    if urls.Length = 0
        return
    for url in urls
        AddLinkItem(url, false)
    RequestUiPush()
}

AddLinkItem(url, doPush := true) {
    global clips, viewTab, viewQuery, viewToday, viewTotal, wvCore
    url := Trim(url)
    if url = ""
        return false
    item := {
        uid: NextClipUid(),
        type: "link",
        data: url,
        time: FormatTime(, "yyyy-MM-dd HH:mm:ss"),
        pinned: false,
        pasted: false,
        preview: url,
        linkTitle: "",
        linkHost: HostOfUrl(url),
        charCount: 0,
        fileCount: 0,
        width: 0,
        height: 0,
        imgFile: ""
    }
    ApplyClipSrc(item)
    old := MemoryTakeLinkEqual(url)
    InheritClipMeta(item, old)
    if IsObject(old) && old.HasProp("linkTitle") && old.linkTitle != ""
        item.linkTitle := old.linkTitle
    MemoryInsertFront(item)
    if doPush
        RequestUiPush()
    EnqueueDiskJob(PersistNewItem.Bind(item))
    return true
}

ExtractUrls(text) {
    urls := []
    seen := Map()
    pos := 1
    while foundPos := RegExMatch(text, "i)https?://\S+", &m, pos) {
        url := RegExReplace(m[0], "[.,;:!?\)\]}>]+$", "")
        url := Trim(url)
        if url != "" {
            key := StrLower(url)
            if !seen.Has(key) {
                seen[key] := true
                urls.Push(url)
            }
        }
        pos := foundPos + StrLen(m[0])
    }
    return urls
}

HostOfUrl(url) {
    if RegExMatch(url, "i)^https?://([^/:#?]+)", &m)
        return m[1]
    return ""
}

EnqueueLinkMeta(url) {
    global linkMetaQueue, clips
    for c in clips {
        if c.type = "link" && c.data = url {
            if c.HasProp("linkTitle") && c.linkTitle != ""
                return
            break
        }
    }
    for u in linkMetaQueue {
        if u = url
            return
    }
    linkMetaQueue.Push(url)
    SetTimer(ProcessLinkMetaQueue, -500)
}

; Only when user opens 链接 tab  — never during Win+V open
PrimeLinkMeta(idsStr := "") {
    global clips
    want := Map()
    if idsStr != "" {
        for part in StrSplit(String(idsStr), ",") {
            part := Trim(part)
            if part = ""
                continue
            want[Integer(part)] := true
        }
    }
    n := 0
    for c in clips {
        if c.type != "link"
            continue
        if want.Count && !want.Has(c.uid)
            continue
        if c.HasProp("linkTitle") && c.linkTitle != ""
            continue
        EnqueueLinkMeta(c.data)
        if ++n >= 8
            break
    }
}

StopLinkMeta(*) {
    global linkMetaQueue, linkMetaPausedUntil
    linkMetaQueue := []
    linkMetaPausedUntil := A_TickCount + 3000
    SetTimer(ProcessLinkMetaQueue, 0)
    SetTimer(PushClips, 0)
}

ProcessLinkMetaQueue(*) {
    global linkMetaQueue
    if linkMetaQueue.Length = 0
        return
    url := linkMetaQueue.RemoveAt(1)
    fetchUrl := url
    SetTimer(() => _FetchLinkTitleWorker(fetchUrl), -20)
}

_FetchLinkTitleWorker(url) {
    global clips, linkMetaQueue, linkMetaPausedUntil
    ; Don't block Win+V / panel open with network I/O
    if A_TickCount < linkMetaPausedUntil {
        linkMetaQueue.InsertAt(1, url)
        SetTimer(ProcessLinkMetaQueue, Max(50, linkMetaPausedUntil - A_TickCount))
        return
    }
    title := ""
    try {
        http := ComObject("WinHttp.WinHttpRequest.5.1")
        http.Open("GET", url, false)
        http.SetTimeouts(300, 300, 600, 600)
        http.SetRequestHeader("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/120.0.0.0")
        http.Send()
        if Integer(http.Status) >= 200 && Integer(http.Status) < 400 {
            html := http.ResponseText
            if StrLen(html) > 65536
                html := SubStr(html, 1, 65536)
            if RegExMatch(html, "i)<title[^>]*>([\s\S]*?)</title>", &m) {
                title := Trim(m[1])
                title := RegExReplace(title, "\s+", " ")
                title := StrReplace(title, "&amp;", "&")
                title := StrReplace(title, "&lt;", "<")
                title := StrReplace(title, "&gt;", ">")
                title := StrReplace(title, "&quot;", '"')
                title := StrReplace(title, "&#39;", "'")
                if StrLen(title) > 120
                    title := SubStr(title, 1, 120)
            }
        }
    } catch {
    }
    if title != "" {
        updated := false
        for c in clips {
            if c.type = "link" && c.data = url {
                if !c.HasProp("linkTitle") || c.linkTitle != title {
                    c.linkTitle := title
                    updated := true
                }
                break
            }
        }
        if updated {
            DiskSetLinkTitle(url, title)
            SchedulePushClips()
        }
    }
    if linkMetaQueue.Length
        SetTimer(ProcessLinkMetaQueue, -800)
}

SchedulePushClips() {
    RequestUiPush()
}

ClipImageToBase64(&outW, &outH) {
    outW := 0, outH := 0
    pToken := 0, pBitmap := 0, hCopy := 0
    try {
        DllCall("LoadLibrary", "Str", "gdiplus.dll", "Ptr")
        si := Buffer(24, 0)
        NumPut("UInt", 1, si)
        if DllCall("gdiplus\GdiplusStartup", "Ptr*", &pToken, "Ptr", si, "Ptr", 0)
            return ""

        if !DllCall("OpenClipboard", "Ptr", 0)
            return ""

        hSrc := DllCall("GetClipboardData", "UInt", 2, "Ptr")
        if hSrc
            hCopy := DllCall("CopyImage", "Ptr", hSrc, "UInt", 0, "Int", 0, "Int", 0, "UInt", 0x2008, "Ptr")
        DllCall("CloseClipboard")

        if !hCopy
            return ""

        if DllCall("gdiplus\GdipCreateBitmapFromHBITMAP", "Ptr", hCopy, "Ptr", 0, "Ptr*", &pBitmap)
            return ""
        DllCall("DeleteObject", "Ptr", hCopy)
        hCopy := 0
        if !pBitmap
            return ""

        DllCall("gdiplus\GdipGetImageWidth",  "Ptr", pBitmap, "UInt*", &w := 0)
        DllCall("gdiplus\GdipGetImageHeight", "Ptr", pBitmap, "UInt*", &h := 0)
        outW := w, outH := h
        if w < 1 || h < 1
            return ""

        if (w > 1200 || h > 1200) {
            sc := Min(1200 / w, 1200 / h)
            nw := Round(w * sc), nh := Round(h * sc)
            pThumb := 0, pGfx := 0
            DllCall("gdiplus\GdipCreateBitmapFromScan0", "Int", nw, "Int", nh,
                "Int", 0, "Int", 0x26200A, "Ptr", 0, "Ptr*", &pThumb)
            if pThumb {
                DllCall("gdiplus\GdipGetImageGraphicsContext", "Ptr", pThumb, "Ptr*", &pGfx)
                if pGfx {
                    DllCall("gdiplus\GdipSetInterpolationMode", "Ptr", pGfx, "Int", 7)
                    DllCall("gdiplus\GdipDrawImageRectI", "Ptr", pGfx, "Ptr", pBitmap, "Int", 0, "Int", 0, "Int", nw, "Int", nh)
                    DllCall("gdiplus\GdipDeleteGraphics", "Ptr", pGfx)
                }
                DllCall("gdiplus\GdipDisposeImage", "Ptr", pBitmap)
                pBitmap := pThumb
            }
        }

        clsid := Buffer(16)
        DllCall("ole32\CLSIDFromString", "Str", "{557CF406-1A04-11D3-9A73-0000F81EF32E}", "Ptr", clsid)
        tmp := A_Temp "\cb_" A_TickCount ".png"
        if DllCall("gdiplus\GdipSaveImageToFile", "Ptr", pBitmap, "WStr", tmp, "Ptr", clsid, "Ptr", 0)
            return ""
        DllCall("gdiplus\GdipDisposeImage", "Ptr", pBitmap)
        pBitmap := 0

        f := FileOpen(tmp, "r")
        if !IsObject(f)
            return ""
        buf := Buffer(f.Length)
        f.RawRead(buf)
        f.Close()
        try FileDelete tmp
        if buf.Size < 32
            return ""
        return "data:image/png;base64," B64Encode(buf)
    } catch {
        return ""
    } finally {
        if hCopy
            try DllCall("DeleteObject", "Ptr", hCopy)
        if pBitmap
            try DllCall("gdiplus\GdipDisposeImage", "Ptr", pBitmap)
        if pToken
            try DllCall("gdiplus\GdiplusShutdown", "Ptr", pToken)
    }
}

B64Encode(buf) {
    needed := 0
    DllCall("crypt32\CryptBinaryToStringW",
        "Ptr", buf, "UInt", buf.Size, "UInt", 0x40000001, "Ptr", 0, "UInt*", &needed, "Int")
    out := Buffer(needed * 2)
    DllCall("crypt32\CryptBinaryToStringW",
        "Ptr", buf, "UInt", buf.Size, "UInt", 0x40000001, "Ptr", out, "UInt*", &needed, "Int")
    return StrGet(out, "UTF-16")
}

; =================================================
;  Bridge
; =================================================
class ClipBridge {
    ; Defer out of sync WebView host call —sync paste from click re-enters and can paste twice
    paste(id) {
        RequestPaste(id)
    }
    pasteMany(ids, sep := "") {
        RequestPasteMany(ids, sep)
    }
    delete(id) {
        ; 立刻返回，避免 WebView 同步调用卡死界面
        SetTimer(DeleteItem.Bind(id), -1)
    }
    deleteMany(ids := "") {
        SetTimer(DeleteItemsMany.Bind(String(ids)), -1)
    }
    pin(id) {
        ; Defer —sync DiskSetPinned + SetView freezes WebView click
        SetTimer(PinItem.Bind(id), -1)
    }
    clear(tab := "all", scope := "today") {
        SetTimer(ClearTab.Bind(tab, scope), -1)
    }
    hide(*) {
        HidePanel()
    }
    moveToTop(id) {
        SetTimer(MoveToTop.Bind(id), -1)
    }
    copyById(id) {
        CopyById(id)
    }
    clearPasted(id) {
        ClearPasted(id)
    }
    resetQueueFrom(id) {
        SetTimer(ResetPasteQueueFrom.Bind(id), -1)
    }
    setFavTitle(id, title := "") {
        SetFavTitle(id, title)
    }
    mergeFav(ids := "") {
        MergeFavItems(ids)
    }
    unmergeFav(id := 0) {
        UnmergeFavItem(id)
    }
    openLink(id) {
        OpenLink(id)
    }
    openPath(path := "") {
        OpenFilePath(path)
    }
    openFolder(path := "") {
        ; Defer — same as openDir (sync WebView host + explorer races look dead)
        SetTimer(OpenContainingFolder.Bind(String(path)), -1)
    }
    openDir(path := "") {
        ; 必须异步 — sync 调 explorer 会让 WebView 点击假死/无响应
        p := String(path)
        SetTimer(OpenFolderDir.Bind(p), -1)
    }
    copyPath(path := "") {
        CopyFilePath(path)
    }
    pathExists(path := "") {
        return PathExistsFlag(path)
    }
    primeLinkMeta(ids := "") {
        PrimeLinkMeta(ids)
    }
    stopLinkMeta(*) {
        StopLinkMeta()
    }
    checkPaths(raw := "") {
        return CheckFilePathsJson(raw)
    }
    togglePin(flag := "") {
        TogglePin(flag)
    }
    startDrag(*) {
        StartDrag()
    }
    focusPanel(*) {
        FocusPanelForInput()
    }
    blurPanel(*) {
        UnfocusPanelRestore()
    }
    setView(tab := "all", query := "", today := "0") {
        ; Return immediately — sync host+disk scan freezes tab clicks in WebView
        t := String(tab)
        ; Guard against WebView arg mis-bind (tab arriving as 0/empty)
        if t = "" || t = "0"
            t := "all"
        QueueSetView(t, String(query), String(today))
    }
    loadMore(*) {
        SetTimer(LoadMoreView, -1)
    }
    thumb(id := 0) {
        return ImageDataUrlForId(id)
    }
    ensureFileImg(path := "", uid := 0) {
        return EnsureFileImageInStore(path, uid)
    }
}

TogglePanel() {
    global guiWin, prevActiveWin, lastCaretX, lastCaretY, hasCaretPos, panelVisible
    ; If flag says visible but window is gone/hidden, treat as closed
    if panelVisible && IsObject(guiWin) {
        try {
            if !WinExist("ahk_id " guiWin.Hwnd) || !DllCall("IsWindowVisible", "Ptr", guiWin.Hwnd, "Int")
                panelVisible := false
        } catch {
            panelVisible := false
        }
    }
    try {
        cur := WinGetID("A")
        if !IsObject(guiWin) || (guiWin.Hwnd && cur != guiWin.Hwnd) {
            ; Never remember Start/Search as "previous app" —restoring it covers our panel
            prevActiveWin := ResolvePrevActiveWin(cur)
            ; OneNote: never probe caret (Gui/IME/Acc/UIA all risk Critical Error)
            if IsOneNoteApp() {
                lastCaretX := 0
                lastCaretY := 0
                hasCaretPos := false
            } else {
                GetCaretScreenPos(&cx, &cy, &found, true)
                if found {
                    lastCaretX := cx
                    lastCaretY := cy
                    hasCaretPos := true
                } else {
                    lastCaretX := 0
                    lastCaretY := 0
                    hasCaretPos := false
                }
            }
        }
    }
    if panelVisible {
        HidePanel()
        return
    }
    ShowPanel()
}

; Leave keyboard-hook context before Acc/UIA (avoids OneNote deadlock on Win+V)
TogglePanelDeferred(*) {
    TogglePanel()
}

; Start/Search use a higher z-band —cannot cover them; dismiss the visible overlay only.
; Do NOT ProcessClose StartMenuExperienceHost (process always runs; killing UI just flickers).
global dismissSearchUntil := 0
global lastGoodActiveWin := 0

IsShellOverlayHwnd(hwnd) {
    if !hwnd
        return false
    try exe := StrLower(WinGetProcessName("ahk_id " hwnd))
    catch
        return false
    return exe = "searchhost.exe" || exe = "searchapp.exe"
        || exe = "startmenuexperiencehost.exe" || exe = "shellexperiencehost.exe"
}

ShellOverlayIsShowing(*) {
    prevDetect := A_DetectHiddenWindows
    DetectHiddenWindows false
    try {
        for exe in ["SearchHost.exe", "SearchApp.exe", "StartMenuExperienceHost.exe"] {
            try {
                for hwnd in WinGetList("ahk_exe " exe) {
                    if !DllCall("IsWindowVisible", "Ptr", hwnd, "Int")
                        continue
                    try {
                        WinGetPos(, , &w, &h, "ahk_id " hwnd)
                        ; Real Start/Search overlay is large (taskbar helpers are tiny)
                        if w >= 400 && h >= 400
                            return true
                    }
                }
            }
        }
    } finally {
        DetectHiddenWindows prevDetect
    }
    return false
}

ResolvePrevActiveWin(cur := 0) {
    global lastGoodActiveWin, guiWin
    excludeGui := IsObject(guiWin) ? guiWin.Hwnd : 0
    if cur && cur != excludeGui && !IsShellOverlayHwnd(cur) && DllCall("IsWindow", "Ptr", cur, "Int") {
        lastGoodActiveWin := cur
        return cur
    }
    if lastGoodActiveWin && lastGoodActiveWin != excludeGui
        && !IsShellOverlayHwnd(lastGoodActiveWin)
        && DllCall("IsWindow", "Ptr", lastGoodActiveWin, "Int")
        return lastGoodActiveWin
    for hwnd in WinGetList() {
        if hwnd = excludeGui || IsShellOverlayHwnd(hwnd)
            continue
        if !DllCall("IsWindowVisible", "Ptr", hwnd, "Int")
            continue
        try {
            title := WinGetTitle("ahk_id " hwnd)
            cls := WinGetClass("ahk_id " hwnd)
            if title = "" && cls = ""
                continue
            if cls = "Shell_TrayWnd" || cls = "Shell_SecondaryTrayWnd" || cls = "Progman" || cls = "WorkerW"
                continue
        } catch {
            continue
        }
        lastGoodActiveWin := hwnd
        return hwnd
    }
    return 0
}

RememberGoodActiveWin(*) {
    global lastGoodActiveWin, guiWin, panelVisible, prevActiveWin
    try {
        cur := WinGetID("A")
        if !cur
            return
        if IsObject(guiWin) && cur = guiWin.Hwnd
            return
        ; WebView 子窗口获焦时不要当成「粘贴目标」
        if IsWindowOwnedByPanel(cur)
            return
        if IsShellOverlayHwnd(cur) || IsScreenshotHelperHwnd(cur)
            return
        lastGoodActiveWin := cur
        ; 固定显示期间也记住最近编辑窗，方便多次粘贴
        if panelVisible
            prevActiveWin := cur
    }
}

; 粘贴目标：弹出前 / 最近聚焦的编辑窗口（固定时点面板不会改成自己）
ResolvePasteTargetWin(*) {
    global prevActiveWin, lastGoodActiveWin, guiWin
    for hwnd in [lastGoodActiveWin, prevActiveWin] {
        if !hwnd
            continue
        if IsObject(guiWin) && guiWin.Hwnd && hwnd = guiWin.Hwnd
            continue
        if IsWindowOwnedByPanel(hwnd)
            continue
        if IsShellOverlayHwnd(hwnd)
            continue
        if DllCall("IsWindow", "Ptr", hwnd, "Int")
            return hwnd
    }
    return ResolvePrevActiveWin(0)
}

DismissWindowsSearch(*) {
    prevDetect := A_DetectHiddenWindows
    DetectHiddenWindows false
    try {
        ; Mask Win so releasing it does not re-open Start
        try Send("{Blind}{vkE8}")
        try Send("{Blind}{LWin up}{RWin up}")
        for exe in ["SearchHost.exe", "SearchApp.exe", "StartMenuExperienceHost.exe"] {
            try {
                for hwnd in WinGetList("ahk_exe " exe) {
                    if !DllCall("IsWindowVisible", "Ptr", hwnd, "Int")
                        continue
                    try {
                        WinGetPos(, , &w, &h, "ahk_id " hwnd)
                        if w < 400 || h < 400
                            continue
                    }
                    ; Close only the visible Start/Search surface (title 寮€濮?/ Search)
                    try WinClose("ahk_id " hwnd)
                }
            }
        }
    } finally {
        DetectHiddenWindows prevDetect
    }
}

RaiseClipboardPanel(*) {
    global guiWin, panelVisible, uiPinned
    if !panelVisible || !IsObject(guiWin) || !guiWin.Hwnd
        return
    hwnd := guiWin.Hwnd
    try guiWin.Opt("+AlwaysOnTop")
    try DllCall("SetWindowPos", "Ptr", hwnd, "Ptr", -1
        , "Int", 0, "Int", 0, "Int", 0, "Int", 0
        , "UInt", 0x0013) ; SWP_NOSIZE|SWP_NOMOVE|SWP_NOACTIVATE
    try WinSetAlwaysOnTop(1, "ahk_id " hwnd)
}

; 仅在焦点被面板/系统搜索抢走时还回编辑器，避免反复 SetForegroundWindow 导致窗口乱跳
RestorePrevFocusQuietly(*) {
    global prevActiveWin, guiWin, qqSearchOn
    if !prevActiveWin || IsShellOverlayHwnd(prevActiveWin)
        return
    cur := 0
    try cur := WinGetID("A")
    if !cur || cur = prevActiveWin
        return
    steal := false
    if IsObject(guiWin) && guiWin.Hwnd && cur = guiWin.Hwnd
        steal := true
    else if IsShellOverlayHwnd(cur)
        steal := true
    else if IsScreenshotHelperHwnd(cur)
        steal := true
    if steal
        try DllCall("SetForegroundWindow", "Ptr", prevActiveWin)
}

KeepSearchDismissed(*) {
    global dismissSearchUntil, panelVisible
    if A_TickCount > dismissSearchUntil {
        SetTimer(KeepSearchDismissed, 0)
        return
    }
    ; Only when the large overlay is actually visible —process itself always exists
    if ShellOverlayIsShowing()
        DismissWindowsSearch()
    if panelVisible
        RaiseClipboardPanel()
}

StartSearchGuard(*) {
    global dismissSearchUntil
    dismissSearchUntil := A_TickCount + 1200
    if ShellOverlayIsShowing()
        DismissWindowsSearch()
    RaiseClipboardPanel()
    SetTimer(KeepSearchDismissed, 80)
}

; Defer out of #UseHook; OneNote: longer delay + no caret probe (see TogglePanel)
; Win+V: Start/Search is a higher z-band than AlwaysOnTop (Windows clipboard is shell-band).
; We cannot draw above Start —prevent Start by delaying LWin until we know it's not Win+V.
HotkeyWinV(*) {
    RememberGoodActiveWin()
    ; 按键当下就采光标（延迟后再采时，焦点/IME 可能已变）
    global lastCaretX, lastCaretY, hasCaretPos
    if !IsOneNoteApp() {
        GetCaretScreenPos(&cx, &cy, &found, true)
        if found {
            lastCaretX := cx
            lastCaretY := cy
            hasCaretPos := true
        } else {
            lastCaretX := 0
            lastCaretY := 0
            hasCaretPos := false
        }
    } else {
        lastCaretX := 0
        lastCaretY := 0
        hasCaretPos := false
    }
    ; Fallback only if Start somehow already visible
    if ShellOverlayIsShowing()
        DismissWindowsSearch()
    delay := IsOneNoteApp() ? -200 : -30
    SetTimer(TogglePanelDeferred, delay)
}

ShowPanel() {
    global guiWin, wv, wvCore, lastCaretX, lastCaretY, hasCaretPos, panelVisible, uiPinned, prevActiveWin, linkMetaPausedUntil, viewToday, viewTab, qqSearchOn, qqQuery, clips, diskScanBusy, firstOpenT0, uiNavReady
    ; 仅冷启动（尚无 WebView）时重置 PERF；预热中的打开沿用同一条时间线
    if !IsObject(wvCore) && !IsObject(guiWin)
        PerfReset()
    PerfMark("ShowPanel ENTER clips=" (IsObject(clips) ? clips.Length : 0) " wv=" (IsObject(wv) ? 1 : 0) " wvCore=" (IsObject(wvCore) ? 1 : 0) " navReady=" (uiNavReady ? 1 : 0))
    ClipLog("ShowPanel ENTER")

    ; Pause any background title fetching so Win+V stays responsive
    linkMetaPausedUntil := A_TickCount + 2000
    prevActiveWin := ResolvePrevActiveWin(prevActiveWin)

    ; OneNote: bottom-right only  — never Acc/UIA/IME/Gui caret
    ; 弹出时强制新鲜探测；失败才回退到 HotkeyWinV 刚采到的样本
    ; 桌面 / 无编辑态：绝不沿用旧光标，固定右下角
    if !IsOneNoteApp() {
        if IsDesktopOrShellSurface() || !HasEditableCaretContext() {
            lastCaretX := 0
            lastCaretY := 0
            hasCaretPos := false
        } else {
            savedX := lastCaretX, savedY := lastCaretY, savedOk := hasCaretPos
            GetCaretScreenPos(&cx, &cy, &found, true)
            if found {
                lastCaretX := cx
                lastCaretY := cy
                hasCaretPos := true
            } else if savedOk {
                lastCaretX := savedX
                lastCaretY := savedY
                hasCaretPos := true
            } else {
                hasCaretPos := false
            }
        }
    } else {
        lastCaretX := 0
        lastCaretY := 0
        hasCaretPos := false
    }

    if !IsObject(guiWin) {
        PerfMark("ShowPanel before BuildGui")
        BuildGui()
        PerfMark("ShowPanel after BuildGui (async WV may still init)")
    }
    if !IsObject(guiWin)
        return
    CalcUiSize(&uiW, &uiH)
    GetWorkArea(&waL, &waT, &waR, &waB)

    if hasCaretPos {
        x := lastCaretX
        if (x + uiW > waR - 2)
            x := waR - uiW - 2
        if x < waL + 2
            x := waL + 2

        lineGapBelow := 10   ; half of previous 20 —panel under caret
        lineGapAbove := 30   ; was 36; only -6 when panel sits above caret
        cy := lastCaretY
        if (cy + lineGapBelow + uiH <= waB - 2)
            y := cy + lineGapBelow
        else
            y := cy - uiH - lineGapAbove
        y := Max(waT + 2, Min(y, waB - uiH - 2))
    } else {
        ; Bottom-right of work area: 2px from right edge, 2px above taskbar
        x := waR - uiW - 2
        y := waB - uiH - 2
    }

    guiWin.Move(x, y, uiW, uiH)
    ; NoActivate when unpinned (keep editor focus); pinned must stay activatable for Ctrl+F
    try guiWin.Opt("+AlwaysOnTop")
    if uiPinned {
        try guiWin.Opt("-E0x08000000")
    } else {
        try guiWin.Opt("+E0x08000000")
    }
    guiWin.Show("NA x" x " y" y " w" uiW " h" uiH)
    ApplyRoundedCorners(guiWin.Hwnd, uiW, uiH, 10)
    panelVisible := true
    PerfMark("ShowPanel window shown")
    RaiseClipboardPanel()
    ; Restore previous app focus  — never Start/Search (that re-covers our panel)
    prevActiveWin := ResolvePrevActiveWin(prevActiveWin)
    ; ?? / Win+V：不要无脑 SetForegroundWindow（会闪、会乱跳）
    RestorePrevFocusQuietly()
    if IsObject(wv) {
        try {
            wv.Fill()
            wv.IsVisible := true
            wv.NotifyParentWindowPositionChanged()
        }
    }
    if IsObject(wvCore) {
        ; Show first, push data after paint  — avoids Win+V freeze on large clip JSON
        ; 不要每次 Invalidate：清空缓存会逼磁盘重扫，列表先空再满 → 闪一下
        keepSearch := qqSearchOn ? "true" : "false"
        try wvCore.ExecuteScriptAsync("window.__onPanelShow && window.__onPanelShow(" keepSearch ")")
        if qqSearchOn {
            QQPushQuery()
        } else if (IsObject(clips) && clips.Length > 0) {
            ; 预热已有列表 → 绝不二次 SetView/扫盘（diskScanBusy 时更不能扫）
            SetTimer(() => RequestUiPush(), -30)
        } else if diskScanBusy {
            SetTimer(() => RequestUiPush(), -30)
        } else
            SetTimer(() => (SetView(viewTab, "", viewToday ? "1" : "0"), RequestUiPush()), -30)
        SetTimer(() => PushPinStateToUi(), -50)
    }
}

EscHidePanel(*) {
    global uiPinned, qqSearchOn
    ; ?? 会话中：Esc = 结束本次搜索（面板藏着也算），等下一次 ??
    if qqSearchOn {
        QQAbortSearch()
        return
    }
    if uiPinned
        return
    HidePanel()
}

PanelKeyUp(*) {
    global wvCore
    if IsObject(wvCore)
        try wvCore.ExecuteScriptAsync("window.__nav && window.__nav('up')")
}
PanelKeyDown(*) {
    global wvCore
    if IsObject(wvCore)
        try wvCore.ExecuteScriptAsync("window.__nav && window.__nav('down')")
}
PanelKeyEnter(*) {
    global wvCore
    if IsObject(wvCore)
        try wvCore.ExecuteScriptAsync("window.__onEnter && window.__onEnter()")
}
PanelKeyEditTitle(*) {
    global wvCore
    if !ClipPanelIsUp()
        return
    FocusPanelForInput()
    if IsObject(wvCore)
        try wvCore.ExecuteScriptAsync("window.__editTitle && window.__editTitle()")
}
PanelKeyNextTab(*) {
    global wvCore
    if IsObject(wvCore)
        try wvCore.ExecuteScriptAsync("window.__cycleTab && window.__cycleTab(1)")
}
PanelKeyPrevTab(*) {
    global wvCore
    if IsObject(wvCore)
        try wvCore.ExecuteScriptAsync("window.__cycleTab && window.__cycleTab(-1)")
}

PanelOpenSearch(*) {
    global wvCore
    if !ClipPanelIsUp()
        return
    FocusPanelForInput()
    if IsObject(wvCore)
        try wvCore.ExecuteScriptAsync("window.__openSearch && window.__openSearch()")
}

; ?? / ？？ + 关键字：原编辑框照常输入（不删字、不抢光标），关键字镜像到面板搜索框
QQQuestionHotIf(*) {
    global searchFocused
    return !(ClipPanelIsUp() && searchFocused)
}

QQQuestionKeyHeld(*) {
    if GetKeyState("Shift", "P") && (GetKeyState("/", "P") || GetKeyState("vkBF", "P"))
        return true
    return false
}

QQOnSlashQuestion(*) {
    if GetKeyState("Shift", "P")
        QQOnQuestion()
}

QQInstallSearchHotkeys(*) {
    ; ~ 透传：问号仍打进当前编辑框；不要用裸 ~?（中文布局会报错）
    try HotIf QQQuestionHotIf
    installed := false
    try {
        Hotkey("~+/", QQOnQuestion, "On")
        installed := true
    }
    if !installed {
        try Hotkey("~*vkBF", QQOnSlashQuestion, "On")
    }
    try Hotkey("~？", QQOnQuestion, "On")
    try HotIf
}

QQArmReleaseWatch(*) {
    global qqNeedRelease
    qqNeedRelease := true
    SetTimer(QQWatchQuestionRelease, 15)
}

QQWatchQuestionRelease(*) {
    global qqNeedRelease
    if QQQuestionKeyHeld()
        return
    qqNeedRelease := false
    SetTimer(QQWatchQuestionRelease, 0)
}

QQClearPending(*) {
    global qqPending, qqMarkCount
    qqPending := false
    qqMarkCount := 0
}

QQResetMarkCount(*) {
    global qqMarkCount
    qqMarkCount := 0
}

QQIsQuestionChar(ch) {
    return ch = "?" || ch = "？"
}

QQClearSearchState(*) {
    global qqQuery, qqAwaitKeyword, viewQuery
    qqQuery := ""
    qqAwaitKeyword := false
    viewQuery := ""
    SetTimer(QQApplyQueryView, 0)
    SetTimer(QQAwaitIdleAbort, 0)
    SoftHidePanel()
    ; 强制清空搜索框（哪怕随后 Stop）
    try {
        global wvCore, qqSearchOn
        if IsObject(wvCore)
            wvCore.ExecuteScriptAsync("window.__setSearchQuery&&window.__setSearchQuery('')")
    }
}

QQAbortSearch(*) {
    ; Esc / ??? / 超时取消：结束镜像，不保留脏查询；下次需重新 ??
    QQClearSearchState()
    QQStopSearch(true)
}

QQScheduleAwaitTimeout(*) {
    ; ?? 后一直不输入关键字（或只打了前导空格）：自动结束，避免“一直在搜”
    SetTimer(QQAwaitIdleAbort, -6000)
}

QQAwaitIdleAbort(*) {
    global qqSearchOn, qqAwaitKeyword
    if qqSearchOn && qqAwaitKeyword
        QQAbortSearch()
}

QQOnQuestion(*) {
    global searchFocused, qqNeedRelease, qqMarkCount, qqSearchOn, qqAwaitKeyword
    if GetKeyState("Ctrl", "P") || GetKeyState("Alt", "P") || GetKeyState("LWin", "P") || GetKeyState("RWin", "P")
        return
    if ClipPanelIsUp() && searchFocused
        return
    ; 按住重复触发忽略
    if qqNeedRelease
        return
    QQArmReleaseWatch()
    qqMarkCount += 1
    SetTimer(QQResetMarkCount, -700)

    if qqMarkCount >= 3 {
        ; ??? → 不触发搜索，清掉刚武装的状态
        SetTimer(QQResetMarkCount, 0)
        qqMarkCount := 0
        QQAbortSearch()
        return
    }
    if qqMarkCount = 2 {
        ; ?? → 清空旧条件，等待关键字；尚未出 UI
        QQArmFreshSearch()
    }
}

; 重新打 ??：清空之前的查询条件，只武装、不弹窗
QQArmFreshSearch(*) {
    global qqSearchOn, qqQuery, qqIh, qqAwaitKeyword, qqPanelPlaced
        , prevActiveWin, lastCaretX, lastCaretY, hasCaretPos, guiWin
    SetTimer(QQClearPending, 0)
    SetTimer(QQApplyQueryView, 0)
    RememberGoodActiveWin()
    if !IsOneNoteApp() {
        GetCaretScreenPos(&cx, &cy, &found, true)
        if found {
            lastCaretX := cx
            lastCaretY := cy
            hasCaretPos := true
        } else {
            lastCaretX := 0
            lastCaretY := 0
            hasCaretPos := false
        }
    } else {
        lastCaretX := 0
        lastCaretY := 0
        hasCaretPos := false
    }
    ; 停掉旧 hook，清空脏查询
    if IsObject(qqIh) {
        try qqIh.Stop()
        qqIh := 0
    }
    qqQuery := ""
    qqAwaitKeyword := true
    qqSearchOn := true
    SoftHidePanel()
    try {
        global wvCore
        if IsObject(wvCore)
            wvCore.ExecuteScriptAsync("window.__setSearchQuery&&window.__setSearchQuery('')")
    }
    ; 不要立刻 SetView 出结果；等第一个非 ? / 非前导空格 的关键字
    qqIh := InputHook("V")
    qqIh.OnChar := QQOnChar
    qqIh.KeyOpt("{Backspace}", "N")
    qqIh.KeyOpt("{Escape}", "N")  ; Esc → OnKeyDown 结束本次搜索
    qqIh.OnKeyDown := QQOnKeyDown
    qqIh.Start()
    QQScheduleAwaitTimeout()
    if !IsObject(guiWin)
        BuildGui()
}

QQOnChar(ih, ch) {
    global qqQuery, qqAwaitKeyword, qqMarkCount
    if ch = "" || ch = "`b" || ch = "`r" || ch = "`n"
        return
    ; 问号只用于武装/取消，不进查询串（避免 ?? 重输时污染关键字）
    if QQIsQuestionChar(ch) {
        if qqAwaitKeyword || qqQuery = ""
            QQAbortSearch()
        return
    }
    ; ?? 后的前导空格/制表不触发搜索（?? wiki 里的空格应忽略；纯 ??+空格也不开搜）
    if qqAwaitKeyword && (ch = " " || ch = "`t") {
        QQScheduleAwaitTimeout()
        return
    }
    qqAwaitKeyword := false
    qqMarkCount := 0
    SetTimer(QQResetMarkCount, 0)
    SetTimer(QQAwaitIdleAbort, 0)
    qqQuery .= ch
    QQOnQueryChanged()
}

QQOnKeyDown(ih, vk, sc) {
    global qqQuery, qqAwaitKeyword
    if vk = 8 {
        if StrLen(qqQuery)
            qqQuery := SubStr(qqQuery, 1, -1)
        if qqQuery = "" {
            qqAwaitKeyword := true
            SoftHidePanel()
            QQScheduleAwaitTimeout()
        }
        QQOnQueryChanged()
        return
    }
    if vk = 27 {
        QQAbortSearch()
    }
}

QQOnQueryChanged(*) {
    global qqQuery
    ; 搜索框镜像到 WebView；磁盘过滤由前端 requestView(setView) 驱动（带当前 tab）
    QQPushQuery()
}

QQApplyQueryView(*) {
    global qqSearchOn, qqQuery, viewTab, viewToday
    if !qqSearchOn
        return
    SetView(viewTab, qqQuery, viewToday ? "1" : "0")
}

QQPushQuery(*) {
    global wvCore, qqQuery, qqSearchOn
    if !qqSearchOn || !IsObject(wvCore)
        return
    try wvCore.ExecuteScriptAsync("window.__setSearchQuery&&window.__setSearchQuery(" JsonStr(qqQuery) ")")
}

QQAttachUi(*) {
    global qqSearchOn, wvCore, prevActiveWin
    if !qqSearchOn
        return
    if !IsObject(wvCore) {
        SetTimer(QQAttachUi, -80)
        return
    }
    QQPushQuery()
    RestorePrevFocusQuietly()
}

QQStopSearch(resetFlag := true) {
    global qqIh, qqSearchOn, qqPending, qqNeedRelease, qqPanelPlaced, qqQuery
        , qqAwaitKeyword, qqMarkCount
    SetTimer(QQAttachUi, 0)
    SetTimer(QQWatchQuestionRelease, 0)
    SetTimer(QQClearPending, 0)
    SetTimer(QQApplyQueryView, 0)
    SetTimer(QQResetMarkCount, 0)
    SetTimer(QQAwaitIdleAbort, 0)
    qqPending := false
    qqNeedRelease := false
    qqAwaitKeyword := false
    qqMarkCount := 0
    if IsObject(qqIh) {
        try qqIh.Stop()
        qqIh := 0
    }
    if resetFlag {
        qqSearchOn := false
        qqPanelPlaced := false
        qqQuery := ""
    }
}

QQTypedEraseCount(*) {
    global qqSearchOn, qqQuery
    if !qqSearchOn
        return 0
    ; ?? / ？？ 各 2 字 + 关键字
    return 2 + StrLen(String(qqQuery))
}

QQEraseTypedInEditor(n) {
    n := Integer(n)
    if n < 1
        return
    Sleep 20
    Send("{BS " n "}")
    Sleep 20
}

OnOutsideClick(*) {
    global guiWin, uiPinned, panelVisible, viewSwitchGuardUntil
    if !panelVisible || uiPinned || !IsObject(guiWin)
        return
    ; 切页/扫盘卡顿期间点到的后续点击不要关面板
    if A_TickCount < viewSwitchGuardUntil
        return
    try {
        CoordMode "Mouse", "Screen"
        MouseGetPos(&mx, &my, &hwndUnder)
        ; WebView 是子窗口：点在面板内时 hwnd 往往不是 guiWin 本身
        if hwndUnder && IsWindowOwnedByPanel(hwndUnder)
            return
        WinGetPos(&wx, &wy, &ww, &wh, "ahk_id " guiWin.Hwnd)
        if (mx >= wx && mx <= wx + ww && my >= wy && my <= wy + wh)
            return
        HidePanel()
    }
}

IsWindowOwnedByPanel(hwnd) {
    global guiWin
    if !hwnd || !IsObject(guiWin) || !guiWin.Hwnd
        return false
    root := guiWin.Hwnd
    if hwnd = root
        return true
    ; 沿父链走到面板根
    cur := hwnd
    loop 12 {
        parent := DllCall("GetParent", "Ptr", cur, "Ptr")
        if !parent
            break
        if parent = root
            return true
        cur := parent
    }
    return false
}

BuildGui() {
    global guiWin, wv, wvCore, HTML_FILE, CLIP_V1_DIR, STORE_DIR, STORE_HOST, panelVisible, wvBuilding
    PerfMark("BuildGui ENTER")
    ClipLog("BuildGui ENTER")
    if IsObject(guiWin) || wvBuilding {
        ClipLog("BuildGui skip already building/built")
        return
    }
    wvBuilding := true

    guiWin := Gui("-Caption -Border +ToolWindow +AlwaysOnTop")
    guiWin.BackColor := "e4e7ee"   ; 与 UI 底色一致，避免外缘露灰边 #a6a49b
    guiWin.MarginX := 0
    guiWin.MarginY := 0
    guiWin.OnEvent("Close", (*) => HidePanel())
    guiWin.OnEvent("Size", OnGuiSize)
    ; WS_EX_NOACTIVATE: showing the panel must not steal keyboard focus
    try guiWin.Opt("+E0x08000000")

    CalcUiSize(&uiW, &uiH)
    guiWin.Show("NA x-32000 y-32000 w" uiW " h" uiH)
    EnableDwmShadow(guiWin.Hwnd)
    PerfMark("BuildGui before WebView2.create")

    try {
        dll := A_Temp "\WebView2Loader.dll"
        if !FileExist(dll)
            throw Error("找不到 WebView2Loader.dll:`n" dll)

        dataDir := CLIP_V1_DIR "\wv2data"
        opts := {
            AdditionalBrowserArguments: "--enable-features=msWebView2EnableDraggableRegions"
        }
        ; Async: do not block AHK thread while Edge process starts
        WebView2.create(guiWin.Hwnd, FinishWebViewInit, 0, dataDir, "", opts, dll)
        PerfMark("BuildGui WebView2.create requested")
    } catch as e {
        wvBuilding := false
        TrayTip("WebView2 init failed", e.Message, "Iconx")
        try FileAppend(FormatTime() " WebView2: " e.Message "`n", CLIP_V1_DIR "\error.log", "UTF-8")
    }

    guiWin.Hide()
    panelVisible := false
}

FinishWebViewInit(controller) {
    global wv, wvCore, HTML_FILE, STORE_DIR, STORE_HOST, APP_HOST, CLIP_V1_DIR, wvBuilding, panelVisible
        , diskScanBusy, clips
    PerfMark("FinishWebViewInit ENTER")
    try {
        wv := controller
        wv.Fill()
        wv.IsVisible := true
        try wv.DefaultBackgroundColor := 0xFFE4E7EE

        wvCore := wv.CoreWebView2
        wvCore.Settings.AreDefaultContextMenusEnabled := false
        wvCore.Settings.IsStatusBarEnabled := false
        ; Stop Chromium Ctrl+F find from eating our search shortcut
        try wvCore.Settings.AreBrowserAcceleratorKeysEnabled := false
        ; 禁止 Ctrl+滚轮 / Ctrl± 缩放界面
        try wvCore.Settings.IsZoomControlEnabled := false
        try wvCore.Settings.IsNonClientRegionSupportEnabled := true
        try wvCore.ZoomFactor := 1

        ; Virtual hosts: UI at https://clipui.app/ ; thumbs at /clips_store/...
        ; Prefer 8.3 short paths —spaces in "goland project" break WebView2 folder mapping.
        try {
            DirCreate STORE_DIR
            DirCreate CLIP_V1_DIR
            mapRoot := GetShortPath(CLIP_V1_DIR)
            mapStore := GetShortPath(STORE_DIR)
            wvCore.SetVirtualHostNameToFolderMapping(APP_HOST, mapRoot, 1)
            wvCore.SetVirtualHostNameToFolderMapping(STORE_HOST, mapStore, 1)
            ClipLog("WV2 map APP=" mapRoot " STORE=" mapStore)
        }
        PerfMark("FinishWebViewInit mapped hosts")

        try wvCore.InjectAhkComponent()
        wvCore.AddHostObjectToScript("ahk", ClipBridge())
        PerfMark("FinishWebViewInit hostObject ready")

        if !FileExist(HTML_FILE)
            throw Error("找不到界面文件`n" HTML_FILE)

        ; UI → AHK：路径用 postMessage，避免 sync host 吞反斜杠 / 点击无响应
        try wvCore.add_WebMessageReceived(HandleUiWebMessage)

        ; Navigate 完整 UI（clipui.app 无 mDNS 坑；首屏由 PaintAllFirstPage 推）
        wvCore.add_NavigationCompleted(OnUiNavigationCompleted)
        PerfMark("FinishWebViewInit before Navigate")
        navVer := UiCacheVer()
        wvCore.Navigate("https://" APP_HOST "/index.html?v=" navVer)
        wvBuilding := false
        PerfMark("FinishWebViewInit Navigate issued ver=" navVer)
        if panelVisible
            SetTimer(() => (
                IsObject(wv) && (wv.Fill(), wv.IsVisible := true, wv.NotifyParentWindowPositionChanged())
            ), -80)
    } catch as e {
        wvBuilding := false
        TrayTip("WebView2 init failed", e.Message, "Iconx")
        try FileAppend(FormatTime() " WebView2: " e.Message "`n", CLIP_V1_DIR "\error.log", "UTF-8")
    }
}

OnUiNavigationCompleted(core, args) {
    global uiNavReady, wvCore
    uiNavReady := true
    try wvCore.ZoomFactor := 1
    PerfMark("NavigationCompleted (app)")
    SetTimer(PaintAllFirstPage, -1)
    SetTimer(() => PushPinStateToUi(), -80)
}

UiCacheVer(*) {
    global UI_CACHE_VER
    if UI_CACHE_VER = ""
        UI_CACHE_VER := "1"
    return UI_CACHE_VER
}

; 脚本启动后后台预热 Edge/WebView，把 ~2s 冷启动挪出首次 Win+V
WarmWebViewEarly(*) {
    global guiWin, wvCore, wvBuilding, uiNavReady
    if IsObject(wvCore) || IsObject(guiWin) || wvBuilding {
        ClipLog("WarmWebViewEarly skip ready=" (IsObject(wvCore) ? 1 : 0))
        return
    }
    ClipLog("WarmWebViewEarly START")
    PerfMark("WarmWebViewEarly BuildGui")
    try BuildGui()
    catch as e {
        ClipLogErr("WarmWebViewEarly", e)
    }
}

; First paint: only push first 20 of「全部」; totals/prune run in background (no search index)
PaintAllFirstPage(*) {
    global qqSearchOn, clips, wvCore, pendingViewArmed, firstAllPaintDone
    PerfMark("PaintAllFirstPage START clips=" (IsObject(clips) ? clips.Length : 0))
    ClipLog("PaintAllFirstPage START")
    t0 := A_TickCount
    try {
        if IsObject(clips) && clips.Length > 0 {
            PerfMark("PaintAllFirstPage cache-hit PushClips")
            if !qqSearchOn && IsObject(wvCore)
                PushClips(false)
        } else {
            PerfMark("PaintAllFirstPage cold PreloadAllViews")
            PreloadAllViews("0", true)
        }
        firstAllPaintDone := true
        PerfMark("PaintAllFirstPage END n=" (IsObject(clips) ? clips.Length : 0) " localMs=" (A_TickCount - t0))
        ClipLog("PaintAllFirstPage END n=" (IsObject(clips) ? clips.Length : 0) " ms=" (A_TickCount - t0))
    } catch as e {
        firstAllPaintDone := true
        ClipLogErr("PaintAllFirstPage", e)
        PerfMark("PaintAllFirstPage ERR")
    }
    if pendingViewArmed
        SetTimer(ApplyPendingView, -1)
    SetTimer(DrainDiskJobs, -50)
    EnqueueDiskJob(PruneOldScreenshots)
}

WarmAllViewsAfterNav(*) {
    PaintAllFirstPage()
}
StartDrag() {
    global guiWin
    if !IsObject(guiWin)
        return
    DllCall("ReleaseCapture")
    PostMessage 0xA1, 2, 0,, "ahk_id " guiWin.Hwnd
}

; Temporarily activate panel so search input can receive typing
FocusPanelForInput() {
    global guiWin, searchFocused, uiPinned
    searchFocused := true
    if !IsObject(guiWin)
        return
    ; Pinned panels must accept activation; NOACTIVATE blocks Ctrl+F / focus
    try guiWin.Opt("-E0x08000000")
    try {
        WinActivate("ahk_id " guiWin.Hwnd)
        DllCall("SetForegroundWindow", "Ptr", guiWin.Hwnd)
    }
}

; After search closes, restore NoActivate and return focus to previous window
UnfocusPanelRestore() {
    global guiWin, prevActiveWin, searchFocused, uiPinned, qqSearchOn
    searchFocused := false
    ; Keep activatable while pinned so Ctrl+F still works without clicking UI
    if IsObject(guiWin) && !uiPinned {
        try guiWin.Opt("+E0x08000000")
    }
    if !uiPinned && !qqSearchOn
        RestorePrevFocusQuietly()
}

GetWorkArea(&l, &t, &r, &b) {
    try MonitorGetWorkArea(, &l, &t, &r, &b)
    catch {
        l := 0, t := 0, r := A_ScreenWidth, b := A_ScreenHeight
    }
}

SetClipboardImage(imgPath) {
    if !FileExist(imgPath)
        return false

    pngBuf := ""
    try {
        f := FileOpen(imgPath, "r")
        if IsObject(f) {
            pngBuf := Buffer(f.Length)
            f.RawRead(pngBuf)
            f.Close()
        }
    }

    DllCall("LoadLibrary", "Str", "gdiplus.dll", "Ptr")
    si := Buffer(24, 0)
    NumPut("UInt", 1, si)
    pToken := 0
    DllCall("gdiplus\GdiplusStartup", "UPtr*", &pToken, "Ptr", si, "Ptr", 0)
    if !pToken
        return false

    ok := false
    pBitmap := 0, hBitmap := 0
    try {
        if DllCall("gdiplus\GdipCreateBitmapFromFile", "WStr", imgPath, "UPtr*", &pBitmap) || !pBitmap
            return false
        DllCall("gdiplus\GdipCreateHBITMAPFromBitmap",
            "UPtr", pBitmap, "UPtr*", &hBitmap, "UInt", 0xFFFFFFFF)
        if !hBitmap
            return false

        bm := Buffer(32, 0)
        DllCall("GetObject", "Ptr", hBitmap, "Int", bm.Size, "Ptr", bm)
        w := NumGet(bm, 4, "Int"), h := NumGet(bm, 8, "Int")
        if w < 1 || h < 1
            return false
        stride := ((w * 32 + 31) // 32) * 4
        dibSize := 40 + stride * h
        hDib := DllCall("GlobalAlloc", "UInt", 0x0002, "UPtr", dibSize, "Ptr")
        if !hDib
            return false
        pDib := DllCall("GlobalLock", "Ptr", hDib, "Ptr")
        DllCall("RtlZeroMemory", "Ptr", pDib, "UPtr", dibSize)
        NumPut("UInt", 40, pDib, 0)
        NumPut("Int", w, pDib, 4)
        NumPut("Int", h, pDib, 8)
        NumPut("UShort", 1, pDib, 12)
        NumPut("UShort", 32, pDib, 14)
        NumPut("UInt", 0, pDib, 16)
        hdc := DllCall("GetDC", "Ptr", 0, "Ptr")
        DllCall("GetDIBits", "Ptr", hdc, "Ptr", hBitmap, "UInt", 0, "UInt", h,
            "Ptr", pDib + 40, "Ptr", pDib, "UInt", 0)
        DllCall("ReleaseDC", "Ptr", 0, "Ptr", hdc)
        DllCall("GlobalUnlock", "Ptr", hDib)

        opened := false
        loop 10 {
            if DllCall("OpenClipboard", "Ptr", 0) {
                opened := true
                break
            }
            Sleep 10
        }
        if !opened
            return false
        DllCall("EmptyClipboard")

        if IsObject(pngBuf) && pngBuf.Size {
            cfPng := DllCall("RegisterClipboardFormat", "Str", "PNG", "UInt")
            hPng := DllCall("GlobalAlloc", "UInt", 0x0002, "UPtr", pngBuf.Size, "Ptr")
            if hPng {
                pPng := DllCall("GlobalLock", "Ptr", hPng, "Ptr")
                DllCall("RtlMoveMemory", "Ptr", pPng, "Ptr", pngBuf, "UPtr", pngBuf.Size)
                DllCall("GlobalUnlock", "Ptr", hPng)
                DllCall("SetClipboardData", "UInt", cfPng, "Ptr", hPng)
            }
        }

        DllCall("SetClipboardData", "UInt", 8, "Ptr", hDib)
        DllCall("CloseClipboard")
        ok := true
    } finally {
        if hBitmap
            try DllCall("DeleteObject", "Ptr", hBitmap)
        if pBitmap
            try DllCall("gdiplus\GdipDisposeImage", "UPtr", pBitmap)
        if pToken
            try DllCall("gdiplus\GdiplusShutdown", "UPtr", pToken)
    }
    return ok
}

; Positioning strategy (align with Win10 clipboard / Raymond Chen):
; 1) GetGUIThreadInfo + GUI_CARETBLINKING
; 2) IAccessible OBJID_CARET on hwndFocus (Chrome / WeChat custom caret)
; 3) UIA TextPattern caret
; 4) IME char position
; 5) Focus-window anchor (near typing UI) — not always screen bottom-right
; OneNote: NEVER probe — bottom-right only
global cachedCaretX := 0
global cachedCaretY := 0
global cachedCaretTick := 0
global pendingCaretHwnd := 0

IsCustomCaretApp(*) {
    try {
        if IsJetBrainsApp()
            return true
        pn := StrLower(WinGetProcessName("A"))
        if pn ~= "i)^(chrome|msedge|msedgewebview2|brave|firefox|opera|vivaldi)\.exe$"
            return true
        if pn ~= "i)^(wechat|weixin|wechatappex|wechatbrowser)\.exe$"
            return true
        if pn ~= "i)^(electron|code|discord|slack|teams|notion|figma)\.exe$"
            return true
        if pn ~= "i)webview2|cursor\.exe"
            return true
    }
    return false
}

; GoLand / IntelliJ 等：自绘光标，无 GUI_CARETBLINKING
IsJetBrainsApp(*) {
    try {
        pn := StrLower(WinGetProcessName("A"))
        if pn ~= "i)goland|idea|webstorm|pycharm|phpstorm|clion|rider|datagrip|rubymine|studio64|jetbrains"
            return true
        cls := WinGetClass("A")
        if cls ~= "i)SunAwt"
            return true
    }
    return false
}

CaretRectLooksValid(left, top, right, bottom) {
    w := right - left
    h := bottom - top
    if w < 0 || h < 0
        return false
    ; 假光标：原点零尺寸 / 明显越界
    if left = 0 && top = 0 && right <= 2 && bottom <= 2
        return false
    if left < -200 || top < -200
        return false
    if left > A_ScreenWidth + 200 || top > A_ScreenHeight + 200
        return false
    return true
}

; MSAA caret on focus hwnd — Acc 返回的已是屏幕坐标（勿再 ScreenToClient）
GetCaretPosFromMSAAFocus(&left, &top, &right, &bottom) {
    left := 0, top := 0, right := 0, bottom := 0
    gi := Buffer(A_PtrSize = 8 ? 72 : 48, 0)
    NumPut("UInt", gi.Size, gi, 0)
    if !DllCall("GetGUIThreadInfo", "UInt", 0, "Ptr", gi)
        return false
    hwndFocus := NumGet(gi, A_PtrSize = 8 ? 16 : 12, "Ptr")
    hwndActive := NumGet(gi, A_PtrSize = 8 ? 8 : 8, "Ptr")
    candidates := []
    if hwndFocus
        candidates.Push(hwndFocus)
    if hwndActive && hwndActive != hwndFocus
        candidates.Push(hwndActive)
    ; Chrome/Edge：光标常在深层 RenderWidget
    for base in [hwndFocus, hwndActive] {
        if !base
            continue
        CollectChromeRenderHwnds(base, candidates)
    }
    if !DllCall("LoadLibraryW", "Str", "oleacc.dll", "Ptr")
        return false
    static IID_IAccessible := Buffer(16, 0)
    static iidReady := false
    if !iidReady {
        DllCall("ole32\CLSIDFromString", "WStr", "{618736E0-3C3D-11CF-810C-00AA00389B71}", "Ptr", IID_IAccessible)
        iidReady := true
    }
    for hwndTry in candidates {
        if !hwndTry
            continue
        if TryMSAACaretOnHwnd(hwndTry, IID_IAccessible, &left, &top, &right, &bottom)
            return true
    }
    return false
}

CollectChromeRenderHwnds(root, arr) {
    if !root
        return
    queue := [root]
    seen := Map()
    while queue.Length {
        cur := queue.RemoveAt(1)
        if seen.Has(cur)
            continue
        seen[cur] := true
        child := 0
        loop 64 {
            child := DllCall("FindWindowExW", "Ptr", cur, "Ptr", child, "Ptr", 0, "Ptr", 0, "Ptr")
            if !child
                break
            try {
                cls := WinGetClass("ahk_id " child)
                if cls = "Chrome_RenderWidgetHostHWND"
                    arr.Push(child)
            }
            queue.Push(child)
            if queue.Length > 80
                break
        }
        if queue.Length > 80
            break
    }
}

TryMSAACaretOnHwnd(hwnd, IID_IAccessible, &left, &top, &right, &bottom) {
    acc := 0
    if DllCall("oleacc\AccessibleObjectFromWindow", "Ptr", hwnd, "UInt", 0xFFFFFFF8
        , "Ptr", IID_IAccessible, "Ptr*", &acc, "Int")
        return false
    if !acc
        return false
    try {
        x := 0, y := 0, w := 0, h := 0
        if A_PtrSize = 8 {
            varChild := Buffer(24, 0)
            NumPut("UShort", 3, varChild) ; VT_I4 CHILDID_SELF
            hr := ComCall(22, acc, "Int*", &x, "Int*", &y, "Int*", &w, "Int*", &h, "Ptr", varChild, "Int")
        } else {
            hr := ComCall(22, acc, "Int*", &x, "Int*", &y, "Int*", &w, "Int*", &h, "Int64", 3, "Int64", 0, "Int")
        }
        if hr
            return false
        if w < 1 && h < 1 {
            w := Max(w, 1)
            h := Max(h, 16)
        }
        left := x
        top := y
        right := x + w
        bottom := y + h
        return CaretRectLooksValid(left, top, right, bottom)
    } catch {
        return false
    }
}

; 桌面 / 任务栏：没有可编辑光标，面板应落在工作区右下角（对齐 Win10 Win+V）
IsDesktopOrShellSurface(*) {
    try {
        cls := WinGetClass("A")
        if cls ~= "i)^(Progman|WorkerW|Shell_TrayWnd|Shell_SecondaryTrayWnd|NotifyIconOverflowWindow)$"
            return true
        gi := Buffer(A_PtrSize = 8 ? 72 : 48, 0)
        NumPut("UInt", gi.Size, gi, 0)
        if DllCall("GetGUIThreadInfo", "UInt", 0, "Ptr", gi) {
            hwndFocus := NumGet(gi, A_PtrSize = 8 ? 16 : 12, "Ptr")
            if hwndFocus {
                fcls := WinGetClass("ahk_id " hwndFocus)
                if fcls ~= "i)^(SysListView32|SHELLDLL_DefView)$" {
                    root := DllCall("GetAncestor", "Ptr", hwndFocus, "UInt", 2, "Ptr") ; GA_ROOT
                    if root {
                        rcls := WinGetClass("ahk_id " root)
                        if rcls ~= "i)^(Progman|WorkerW)$"
                            return true
                    }
                }
            }
        }
    }
    return false
}

; 当前是否处于「可打字」编辑态（有系统光标 / 标准编辑框焦点）
HasEditableCaretContext(*) {
    if IsDesktopOrShellSurface()
        return false
    ; JetBrains / 浏览器等自绘光标：编辑器里也没有 GUI_CARETBLINKING
    if IsJetBrainsApp() || IsCustomCaretApp()
        return true
    x64 := A_PtrSize == 8
    gi := Buffer(x64 ? 72 : 48, 0)
    NumPut("UInt", gi.Size, gi)
    if !DllCall("GetGUIThreadInfo", "UInt", 0, "Ptr", gi)
        return false
    flags := NumGet(gi, 4, "UInt")
    ; GUI_CARETBLINKING：真·系统插入符
    if (flags & 0x1)
        return true
    hwndFocus := NumGet(gi, x64 ? 16 : 12, "Ptr")
    if !hwndFocus
        return false
    try {
        fcls := WinGetClass("ahk_id " hwndFocus)
        ; 经典编辑框 / 重命名框等
        if fcls ~= "i)^(Edit|RichEdit20[AW]|RichEdit50W|RICHEDIT60W|Scintilla|TxutEdit)$"
            return true
        if fcls ~= "i)Chrome_RenderWidgetHostHWND|Chrome_WidgetWin|SunAwt"
            return true
    }
    return false
}

; 找不到光标时：不再贴焦点窗口（桌面/浏览网页时会飘到奇怪位置）→ 交给 ShowPanel 右下角
GetFocusWindowAnchor(&cx, &cy) {
    cx := 0, cy := 0
    return false
}

GetCaretScreenPos(&cx, &cy, &found := false, forceFresh := false) {
    cx := 0, cy := 0, found := false
    left := 0, top := 0, right := 0, bottom := 0

    if IsOneNoteApp()
        return

    ; 桌面 / 无编辑态：直接右下角，不采假光标、不贴窗口
    if IsDesktopOrShellSurface() || !HasEditableCaretContext() {
        return
    }

    if !forceFresh && GetCachedCaretPos(&x, &y) {
        cx := x, cy := y, found := true
        return
    }

    custom := IsCustomCaretApp()
    jb := IsJetBrainsApp()
    useHook := false
    try {
        pn := WinGetProcessName("A")
        if pn ~= "i)goland|idea|webstorm|pycharm|phpstorm|clion|rider|datagrip|rubymine"
            useHook := true
    }
    if jb
        useHook := true

    ; JetBrains：Hook/UIA 优先（AWT 的 Gui 光标经常偏/假）
    ; 浏览器/微信：MSAA → UIA
    ; 其它：Gui → MSAA → UIA → IME
    if jb
        tryOrder := ["uia", "msaa", "ime"]
    else if custom
        tryOrder := ["msaa", "uia", "gui", "ime"]
    else
        tryOrder := ["gui", "msaa", "uia", "ime"]

    for step in tryOrder {
        ok := false
        if step = "gui" {
            ok := GetCaretPosFromGuiThread(&left, &top, &right, &bottom)
        } else if step = "msaa" {
            ok := GetCaretPosFromMSAAFocus(&left, &top, &right, &bottom)
        } else if step = "uia" {
            ; skipGui=true：只跑 UIA/MSAA/Hook；JetBrains 在 GetCaretPosEx 内优先 Hook
            ok := GetCaretPosEx(&left, &top, &right, &bottom, useHook, false, true)
        } else if step = "ime" {
            if GetCaretPosIME(&x, &y) {
                left := x, top := y - 18, right := x + 1, bottom := y
                ok := true
            }
        }
        if ok && CaretRectLooksValid(left, top, right, bottom) {
            cx := left
            cy := bottom > top ? bottom : top + 18
            found := true
            CacheCaretPos(cx, cy)
            return
        }
    }
    ; 探测失败 → found=false → ShowPanel 工作区右下角
}

IsOneNoteApp() {
    try {
        pn := WinGetProcessName("A")
        if pn ~= "i)^(ONENOTE|ONENOTEM|ONENOTEIM)\.EXE$"
            return true
        title := WinGetTitle("A")
        if pn ~= "i)^ApplicationFrameHost\.EXE$" && InStr(title, "OneNote")
            return true
        ; Title fallback (new OneNote / Store builds with odd process names)
        if InStr(title, "OneNote")
            return true
        cls := WinGetClass("A")
        if InStr(cls, "OneNote")
            return true
    }
    return false
}

CacheCaretPos(x, y) {
    global cachedCaretX, cachedCaretY, cachedCaretTick
    cachedCaretX := x
    cachedCaretY := y
    cachedCaretTick := A_TickCount
}

GetCachedCaretPos(&cx, &cy) {
    global cachedCaretX, cachedCaretY, cachedCaretTick
    cx := 0, cy := 0
    if !cachedCaretTick
        return false
    ; 浏览器/微信光标常变：缓存更短，避免「开在上一次位置」
    maxAge := IsOneNoteApp() ? 4000 : (IsCustomCaretApp() ? 600 : 1500)
    if (A_TickCount - cachedCaretTick) > maxAge
        return false
    if cachedCaretX = 0 && cachedCaretY = 0
        return false
    cx := cachedCaretX
    cy := cachedCaretY
    return true
}

; Background caret tracker disabled —LOCATIONCHANGE while scrolling made hosts
; auto-scroll an extra notch after the wheel stopped.
StartCaretWatcher() {
}
StopCaretWatcher() {
}

; Same as GetCaretPosEx getCaretPosFromGui —no COM
GetCaretPosFromGuiThread(&left, &top, &right, &bottom) {
    left := 0, top := 0, right := 0, bottom := 0
    x64 := A_PtrSize == 8
    guiThreadInfo := Buffer(x64 ? 72 : 48)
    NumPut("UInt", guiThreadInfo.Size, guiThreadInfo)
    if !DllCall("GetGUIThreadInfo", "UInt", 0, "Ptr", guiThreadInfo)
        return false
    flags := NumGet(guiThreadInfo, 4, "UInt")
    ; GUI_CARETBLINKING=0x1：没有真系统光标时别信 rcCaret（浏览器常给空/假矩形）
    if !(flags & 0x1) && !IsCustomCaretApp() {
        ; 非自定义光标应用也可试一下 hwndCaret；无 blinking 仍可能有效
    }
    hwndCaret := NumGet(guiThreadInfo, x64 ? 48 : 28, "Ptr")
    if !hwndCaret
        return false
    left := NumGet(guiThreadInfo, x64 ? 56 : 32, "Int")
    top := NumGet(guiThreadInfo, x64 ? 60 : 36, "Int")
    right := NumGet(guiThreadInfo, x64 ? 64 : 40, "Int")
    bottom := NumGet(guiThreadInfo, x64 ? 68 : 44, "Int")
    if (right - left) < 1 && (bottom - top) < 1
        return false
    ; 自定义光标应用：无 blinking 时 Gui 矩形经常是错的
    if IsCustomCaretApp() && !(flags & 0x1)
        return false
    pt := Buffer(8, 0)
    NumPut("Int", left, pt, 0)
    NumPut("Int", bottom, pt, 4)
    DllCall("ClientToScreen", "Ptr", hwndCaret, "Ptr", pt)
    left := NumGet(pt, 0, "Int")
    bottom := NumGet(pt, 4, "Int")
    top := bottom - Max(bottom - top, 1)
    right := left + 1
    return CaretRectLooksValid(left, top, right, bottom)
}

GetCaretPosIME(&cx, &cy) {
    cx := 0, cy := 0
    gi := Buffer(A_PtrSize = 8 ? 72 : 48, 0)
    NumPut("UInt", gi.Size, gi, 0)
    if !DllCall("GetGUIThreadInfo", "UInt", 0, "Ptr", gi)
        return false
    hwndFocus := NumGet(gi, A_PtrSize = 8 ? 16 : 12, "Ptr")
    if !hwndFocus
        return false
    ; IMECHARPOSITION: dwSize, dwCharPos, POINT pt, UINT cLineHeight, RECT rcDocument
    buf := Buffer(4 + 4 + 8 + 4 + 16, 0)
    NumPut("UInt", buf.Size, buf, 0)
    NumPut("UInt", 0, buf, 4)  ; first char / caret
    ; WM_IME_REQUEST=0x0288, IMR_QUERYCHARPOSITION=6  — never block forever
    ; SMTO_ABORTIFHUNG=0x0002
    result := 0
    ok := DllCall("SendMessageTimeoutW", "Ptr", hwndFocus, "UInt", 0x0288, "Ptr", 6, "Ptr", buf.Ptr
        , "UInt", 0x0002, "UInt", 80, "UPtr*", &result)
    if !ok || !result
        return false
    x := NumGet(buf, 8, "Int")
    y := NumGet(buf, 12, "Int")
    lineH := NumGet(buf, 16, "UInt")
    if x = 0 && y = 0
        return false
    cx := x
    cy := y + (lineH > 0 ? lineH : 18)
    return true
}

ApplyRoundedCorners(hwnd, w, h, r := 10) {
    ; 不用 CreateRoundRectRgn/SetWindowRgn：GDI 区域圆角无抗锯齿，锯齿很重
    ; 清掉旧 region，交给 Win11 DWM 圆角（系统抗锯齿）
    try DllCall("SetWindowRgn", "Ptr", hwnd, "Ptr", 0, "Int", true)
    ; DWMWA_WINDOW_CORNER_PREFERENCE=33, DWMWCP_ROUND=2
    try DllCall("dwmapi\DwmSetWindowAttribute",
        "Ptr", hwnd, "UInt", 33, "Int*", 2, "UInt", 4)
    ClearWindowBorder(hwnd)
}

; Win11 无边框窗口仍会画系统描边（常见 #a6a49b）；关掉
ClearWindowBorder(hwnd) {
    if !hwnd
        return
    ; DWMWA_BORDER_COLOR = 34, DWMWA_COLOR_NONE = 0xFFFFFFFE
    try DllCall("dwmapi\DwmSetWindowAttribute",
        "Ptr", hwnd, "UInt", 34, "UInt*", 0xFFFFFFFE, "UInt", 4)
    ; DWMWA_VISIBLE_FRAME_BORDER_THICKNESS = 37 → 0
    try DllCall("dwmapi\DwmSetWindowAttribute",
        "Ptr", hwnd, "UInt", 37, "UInt*", 0, "UInt", 4)
}

EnableDwmShadow(hwnd) {
    try DllCall("dwmapi\DwmSetWindowAttribute",
        "Ptr", hwnd, "UInt", 2, "Int*", 2, "UInt", 4)
    try {
        m := Buffer(16, 0)
        NumPut("Int", 1, m, 0)
        DllCall("dwmapi\DwmExtendFrameIntoClientArea", "Ptr", hwnd, "Ptr", m)
    }
    try DllCall("dwmapi\DwmSetWindowAttribute",
        "Ptr", hwnd, "UInt", 33, "Int*", 2, "UInt", 4)
    ClearWindowBorder(hwnd)
}

HidePanel(*) {
    global guiWin, wvCore, panelVisible, hasCaretPos, searchFocused, dismissSearchUntil
    QQStopSearch()
    panelVisible := false
    hasCaretPos := false
    searchFocused := false
    dismissSearchUntil := 0
    SetTimer(KeepSearchDismissed, 0)
    ; Drop leftover right-click menu so next open is clean
    if IsObject(wvCore)
        try wvCore.ExecuteScriptAsync("window.__hideCtx&&window.__hideCtx()")
    if IsObject(guiWin) {
        try guiWin.Opt("+E0x08000000")
        guiWin.Hide()
    }
}

; ?? 搜索无命中：只藏窗口，不结束镜像输入
SoftHidePanel(*) {
    global guiWin, panelVisible, wvCore
    panelVisible := false
    if IsObject(wvCore)
        try wvCore.ExecuteScriptAsync("window.__hideCtx&&window.__hideCtx()")
    if IsObject(guiWin)
        try guiWin.Hide()
}

; ?? 搜索又有命中：显示已建好的面板，不重置查询
SoftShowPanel(*) {
    global guiWin, wv, panelVisible, prevActiveWin, uiPinned, qqPanelPlaced
    ; 首次弹出必须走 ShowPanel 定位到光标；之后 SoftHide/Show 只切换可见性
    if !IsObject(guiWin) || !qqPanelPlaced {
        ShowPanel()
        qqPanelPlaced := true
        QQPushQuery()
        return
    }
    wasVis := panelVisible
    try guiWin.Opt("+AlwaysOnTop")
    if uiPinned {
        try guiWin.Opt("-E0x08000000")
    } else {
        try guiWin.Opt("+E0x08000000")
    }
    guiWin.Show("NA")
    panelVisible := true
    RaiseClipboardPanel()
    if IsObject(wv) {
        try {
            wv.IsVisible := true
            ; 已显示时不要 Fill/重排：会白闪；仅首次从隐藏恢复时刷新
            if !wasVis {
                wv.Fill()
                wv.NotifyParentWindowPositionChanged()
            }
        }
    }
    RestorePrevFocusQuietly()
    QQPushQuery()
    ; 不要再 PushClips：SetView 刚推过，重复推会整表重绘闪一下
}

; ?? 模式：无关键字 / 无命中都不显示；有命中才弹出
; ?? 模式：无关键字时隐藏；有命中才弹出；已显示时切 tab 即使 0 条也保留（避免「卡一下就消失」）
QQSyncPanelVisibility(*) {
    global qqSearchOn, viewQuery, clips, viewTotal, panelVisible
    if !qqSearchOn
        return
    q := Trim(String(viewQuery))
    if q = "" {
        if panelVisible
            SoftHidePanel()
        return
    }
    n := 0
    try n := clips.Length
    tot := Integer(viewTotal)
    if (n < 1 && tot < 1) {
        ; 未弹出：继续藏着等有命中；已弹出：显示空状态，不关窗
        return
    }
    if !panelVisible
        SoftShowPanel()
}

TogglePin(flag := "") {
    global guiWin, uiPinned, panelVisible
    if (flag = "" || !IsSet(flag)) {
        uiPinned := !uiPinned
    } else {
        s := String(flag)
        uiPinned := (s = "1" || s = "true" || s = "True")
    }
    if IsObject(guiWin) {
        if panelVisible
            guiWin.Opt("+AlwaysOnTop")
        else
            guiWin.Opt(uiPinned ? "+AlwaysOnTop" : "-AlwaysOnTop")
        ; Pinned: drop NOACTIVATE so Ctrl+F / keys work without clicking first
        if uiPinned {
            try guiWin.Opt("-E0x08000000")
        } else if panelVisible {
            try guiWin.Opt("+E0x08000000")
        }
    }
    PushPinStateToUi()
}

PushPinStateToUi() {
    global wvCore, uiPinned
    if !IsObject(wvCore)
        return
    try wvCore.ExecuteScriptAsync("window.__setPinned && window.__setPinned(" (uiPinned ? "true" : "false") ")")
}

CalcUiSize(&outW, &outH) {
    global UI_W, UI_H
    scale := A_ScreenHeight / 1080.0
    if scale < 0.75
        scale := 0.75
    if scale > 1.35
        scale := 1.35
    outW := Round(UI_W * scale)
    outH := Round(UI_H * scale)
}

OnGuiSize(*) {
    global wv
    if IsObject(wv)
        try wv.Fill()
}

PushClips(append := false) {
    global wvCore, clips, viewTotal, viewQuery, viewTab, viewToday, viewApplying
        , diskScanBusy, clipReady
    if !IsObject(wvCore)
        return
    t0 := A_TickCount
    q := String(viewQuery)
    ; 扫盘中途可能 Sleep 让出：此时 viewQuery 已新、clips 仍旧 → 绝不推「伪过滤」列表
    if viewApplying && Trim(q) != ""
        return
    sendList := clips
    sendTotal := Integer(viewTotal)
    ; Boot/warm race: empty push used to flash「暂无记录」— keep UI on skeleton instead of silent SKIP (blank white)
    if !append && (!IsObject(sendList) || sendList.Length = 0) && sendTotal <= 0 && Trim(q) = "" {
        if viewTab != "recent" && (diskScanBusy || !clipReady) {
            ClipLog("PushClips KEEP skel while warm/boot")
            try wvCore.ExecuteScriptAsync("window.setBootLoading&&window.setBootLoading(true);window.__waitingView=true;")
            return
        }
    }
    filtered := Trim(q) != ""
    if filtered {
        ; SetView / QueryDiskPage 已过滤+展开合并组，勿再扫盘
        sendList := clips
        if !append
            sendTotal := clips.Length
        else
            sendTotal := Max(Integer(viewTotal), clips.Length)
    }
    tJson0 := A_TickCount
    payload := "{"
    payload .= '"append":' (append ? "true" : "false") ","
    payload .= '"tab":' JsonStr(String(viewTab)) ","
    payload .= '"total":' sendTotal ","
    payload .= '"pinnedTotal":' Integer(PinnedTotalForUi()) ","
    payload .= '"query":' JsonStr(q) ","
    payload .= '"filtered":' (filtered ? "true" : "false") ","
    payload .= '"items":' ClipsListToJson(sendList, append)
    payload .= "}"
    jsonMs := A_TickCount - tJson0
    try wvCore.ExecuteScriptAsync("window.__updateClips && window.__updateClips(" payload ");window.__loadMoreDone&&window.__loadMoreDone();window.__perfMark&&window.__perfMark('js_updateClips_called')")
    PerfMark("PushClips done n=" (IsObject(sendList) ? sendList.Length : 0) " jsonMs=" jsonMs " totalMs=" (A_TickCount - t0) " payloadKB=" Round(StrLen(payload) / 1024, 1))
    ; Defer thumbs so first paint is not blocked
    SetTimer(ScheduleStoreThumbs.Bind(append), -400)
}

; Badge on 收藏 tab —prefer pinned viewCache total, else count current window
PinnedTotalForUi(*) {
    global viewCache, viewToday, viewTab, viewTotal, clips
    try {
        key := ViewCacheKey("pinned", "", viewToday)
        if viewCache.Has(key) {
            t := Integer(viewCache[key].total)
            if t > 0
                return t
        }
    }
    if viewTab = "pinned" {
        n := 0
        try n := clips.Length
        return Max(Integer(viewTotal), n)
    }
    n := 0
    if IsObject(clips) {
        for c in clips {
            if IsObject(c) && c.HasProp("pinned") && c.pinned
                n += 1
        }
    }
    return n
}

; Coalesce UI refreshes —safe to call from OnClipboardChange / disk jobs
RequestUiPush(*) {
    global uiPushPending, uiPushTimerArmed
    uiPushPending := true
    if uiPushTimerArmed
        return
    uiPushTimerArmed := true
    ; Leave clipboard / Critical context before talking to WebView
    SetTimer(FlushUiPush, -30)
}

FlushUiPush(*) {
    global uiPushPending, uiPushTimerArmed, wvCore, panelVisible, clips, viewApplying, viewQuery
    uiPushTimerArmed := false
    if !uiPushPending
        return
    uiPushPending := false
    if !IsObject(wvCore)
        return
    ; 搜索扫盘中途勿推旧列表
    if viewApplying && Trim(String(viewQuery)) != "" {
        uiPushPending := true
        uiPushTimerArmed := true
        SetTimer(FlushUiPush, -80)
        return
    }
    n := 0
    try n := clips.Length
    ClipLog("FlushUiPush panel=" panelVisible " clips=" n)
    PushClips(false)
}

; Queue list thumbs without blocking SetView / tab switch
ScheduleStoreThumbs(append := false) {
    global clips, wvCore, lastAppendCount, thumbPushGen, thumbPushQueue, thumbPushArmed
        , thumbPushedUids, clipReady, STORE_DIR, panelVisible
    if !IsObject(wvCore) || !panelVisible
        return
    if !clipReady {
        SetTimer(ScheduleStoreThumbs.Bind(append), -200)
        return
    }
    start := 1
    if append && lastAppendCount > 0
        start := Max(1, clips.Length - lastAppendCount + 1)
    else if !append {
        ; Full refresh: allow re-inject (DOM was rebuilt); keep memory URL cache
        thumbPushedUids := Map()
    }
    q := []
    i := start
    while i <= clips.Length {
        c := clips[i]
        i += 1
        if !IsObject(c)
            continue
        ; 历史条目：图片文件没写入 imgFile 时补拷一份，否则永远占位
        if c.type = "file" && (!c.HasProp("imgFile") || c.imgFile = "") && FileClipLooksLikeImage(c) {
            try EnsureFileClipThumb(c)
            catch {
            }
            if c.HasProp("imgFile") && c.imgFile != ""
                ApplyImgFileLocal(c.uid, c.imgFile)
        }
        if !c.HasProp("imgFile") || c.imgFile = ""
            continue
        if c.type != "image" && c.type != "file"
            continue
        uid := Integer(c.uid)
        if thumbPushedUids.Has(uid)
            continue
        th := ListThumbCacheName(String(c.imgFile))
        ; th_ on disk: still tell UI the URL —skipping left placeholders when virtual-host failed
        if th != "" {
            try {
                if FileExist(STORE_DIR "\" th) {
                    hostUrl := ListThumbHostUrl(th)
                    if hostUrl != "" {
                        try wvCore.ExecuteScriptAsync("window.__setThumb&&window.__setThumb(" uid "," JsonStr(hostUrl) ")")
                        thumbPushedUids[uid] := true
                        continue
                    }
                }
            }
        }
        q.Push({ uid: uid, imgFile: String(c.imgFile) })
    }
    thumbPushGen += 1
    thumbPushQueue := q
    if !thumbPushArmed && q.Length {
        thumbPushArmed := true
        SetTimer(ProcessThumbPushQueue, -20)
    } else if !q.Length {
        thumbPushArmed := false
        SetTimer(ProcessThumbPushQueue, 0)
    }
}

ProcessThumbPushQueue(*) {
    global wvCore, STORE_DIR, APP_HOST, thumbPushGen, thumbPushQueue, thumbPushArmed, thumbPushedUids
    thumbPushArmed := false
    if !IsObject(wvCore) || !thumbPushQueue.Length
        return
    myGen := thumbPushGen
    ; At most 3 host-URL injects / 1 GDI+ encode per tick
    ; At most 2 host-URL injects / 1 GDI+ encode per tick (keep scroll fluid)
    budget := 2
    madeJpeg := false
    while budget > 0 && thumbPushQueue.Length {
        if myGen != thumbPushGen
            return
        job := thumbPushQueue.RemoveAt(1)
        uid := Integer(job.uid)
        if thumbPushedUids.Has(uid)
            continue
        name := String(job.imgFile)
        allowMake := !madeJpeg
        cacheName := ListThumbCacheName(name)
        url := ""
        if cacheName != "" && FileExist(STORE_DIR "\" cacheName)
            url := ListThumbHostUrl(cacheName)
        else if allowMake {
            try {
                made := EnsureListThumbFile(name)
                if made != "" {
                    madeJpeg := true
                    ; Prefer data-URL after encode —virtual-host alone left blank placeholders
                    didMake := false
                    try url := ListThumbDataUrl(name, false, &didMake)
                    catch {
                    }
                    if url = ""
                        url := ListThumbHostUrl(made)
                }
            } catch as e {
                ClipLog("ProcessThumbPushQueue Ensure fail " name " " e.Message)
            }
        } else {
            ; Encode budget used —retry next tick
            try {
                if FileExist(STORE_DIR "\" name)
                    thumbPushQueue.Push(job)
            }
            continue
        }
        if url = "" {
            ; Last resort: tiny data-URL (virtual host may be broken)
            didMake := false
            try url := ListThumbDataUrl(name, false, &didMake)
            catch {
            }
        }
        if url = ""
            continue
        try wvCore.ExecuteScriptAsync("window.__setThumb&&window.__setThumb(" uid "," JsonStr(url) ")")
        thumbPushedUids[uid] := true
        budget -= 1
    }
    if myGen != thumbPushGen
        return
    if thumbPushQueue.Length {
        thumbPushArmed := true
        SetTimer(ProcessThumbPushQueue, madeJpeg ? -70 : -28)
    }
}

; Prefer short virtual-host URL —no FileRead / base64 on hot path
ListThumbHostUrl(cacheName) {
    global APP_HOST
    cacheName := String(cacheName)
    if cacheName = ""
        return ""
    ; encodeURIComponent-ish for uncommon chars (img_/th_ names are usually safe)
    safe := StrReplace(cacheName, " ", "%20")
    return "https://" APP_HOST "/clips_store/" safe
}

; Just-copied image: list JSON strips data → inject a small JPEG data-URL into WV2 ASAP
InjectLiveImageThumb(uid) {
    global clips, liveFront, wvCore, thumbPushedUids, panelVisible
    uid := Integer(uid)
    if uid < 1 || !IsObject(wvCore)
        return
    item := ""
    for c in clips {
        if IsObject(c) && c.uid = uid {
            item := c
            break
        }
    }
    if !IsObject(item) && IsObject(liveFront) {
        for c in liveFront {
            if IsObject(c) && c.uid = uid {
                item := c
                break
            }
        }
    }
    if !IsObject(item) || item.type != "image"
        return
    if item.HasProp("imgFile") && item.imgFile != "" {
        InjectStoreThumbNow(uid, item.imgFile)
        return
    }
    if !(item.HasProp("data") && InStr(item.data, "base64,"))
        return
    url := ""
    try url := MemoryDataUrlToListThumbUrl(item.data)
    catch as e {
        ClipLog("InjectLiveImageThumb fail uid=" uid " " e.Message)
        return
    }
    if url = ""
        return
    try wvCore.ExecuteScriptAsync("window.__setThumb&&window.__setThumb(" uid "," JsonStr(url) ")")
    thumbPushedUids[uid] := true
    ClipLog("InjectLiveImageThumb ok uid=" uid " len=" StrLen(url))
}

; After imgFile lands on disk: ensure th_ + inject (prefer data-URL —virtual host is flaky)
InjectStoreThumbNow(uid, imgFile) {
    global wvCore, STORE_DIR, thumbPushedUids
    uid := Integer(uid)
    imgFile := String(imgFile)
    if uid < 1 || imgFile = "" || !IsObject(wvCore)
        return
    cacheName := ""
    try cacheName := EnsureListThumbFile(imgFile)
    catch as e {
        ClipLog("InjectStoreThumbNow Ensure fail " imgFile " " e.Message)
    }
    url := ""
    if cacheName != "" {
        didMake := false
        try url := ListThumbDataUrl(imgFile, false, &didMake)
        catch {
        }
        if url = ""
            url := ListThumbHostUrl(cacheName)
    }
    if url = ""
        return
    try wvCore.ExecuteScriptAsync("window.__setThumb&&window.__setThumb(" uid "," JsonStr(url) ")")
    thumbPushedUids[uid] := true
}

; Shrink in-memory clipboard PNG/data-URL to a small JPEG data-URL for list inject
MemoryDataUrlToListThumbUrl(dataUrl) {
    if !RegExMatch(String(dataUrl), "i)base64,([\s\S]+)$", &m)
        return ""
    stamp := A_TickCount "_" Random(1000, 9999)
    tmp := A_Temp "\clip_live_" stamp ".png"
    th := A_Temp "\clip_live_th_" stamp ".jpg"
    try {
        if !B64DecodeToFile(m[1], tmp)
            return ""
        if !MakeListThumbJpeg(tmp, th)
            return ""
        f := FileOpen(th, "r")
        if !IsObject(f)
            return ""
        buf := Buffer(f.Length)
        f.RawRead(buf)
        f.Close()
        if buf.Size < 32
            return ""
        return "data:image/jpeg;base64," B64Encode(buf)
    } catch {
        return ""
    } finally {
        try FileDelete tmp
        try FileDelete th
    }
}

; Small JPEG list preview (cached next to original) —keeps inject payload small
; allowMake=false →never GDI+ (used when budget already spent this tick)
ListThumbDataUrl(name, allowMake := true, &didMake := false) {
    global STORE_DIR, listThumbUrlCache
    didMake := false
    name := String(name)
    if name = ""
        return ""
    src := STORE_DIR "\" name
    if !FileExist(src)
        return ""
    mt := ""
    try mt := FileGetTime(src, "M")
    if listThumbUrlCache.Has(name) {
        ent := listThumbUrlCache[name]
        if IsObject(ent) && ent.HasProp("mt") && ent.mt = mt && ent.HasProp("url") && ent.url != ""
            return ent.url
    }
    ; Prefer existing th_*.jpg —no encode on hot path
    cacheName := ListThumbCacheName(name)
    cachePath := STORE_DIR "\" cacheName
    if FileExist(cachePath) {
        try {
            if FileGetTime(cachePath, "M") >= mt {
                u := LoadImageFromStore(cacheName)
                if u != "" {
                    CapListThumbUrlCache()
                    listThumbUrlCache[name] := { mt: mt, url: u }
                    return u
                }
            }
        } catch {
            u := LoadImageFromStore(cacheName)
            if u != "" {
                CapListThumbUrlCache()
                listThumbUrlCache[name] := { mt: mt, url: u }
                return u
            }
        }
    }
    if allowMake {
        try {
            hadCache := FileExist(cachePath)
            if EnsureListThumbFile(name) != "" {
                if !hadCache
                    didMake := true
                u := LoadImageFromStore(cacheName)
                if u != "" {
                    CapListThumbUrlCache()
                    listThumbUrlCache[name] := { mt: mt, url: u }
                    return u
                }
            }
        } catch as e {
            ClipLog("ListThumbDataUrl EnsureListThumbFile fail name=" name " err=" e.Message)
        }
    }
    ; Last resort: tiny originals only (large ExecuteScript payloads fail silently)
    try {
        if FileGetSize(src) <= 80000 {
            u := LoadImageFromStore(name)
            if u != "" {
                CapListThumbUrlCache()
                listThumbUrlCache[name] := { mt: mt, url: u }
                return u
            }
        }
    } catch {
    }
    return ""
}

CapListThumbUrlCache(*) {
    global listThumbUrlCache
    if !IsObject(listThumbUrlCache) || listThumbUrlCache.Count <= 96
        return
    ; Drop all —cheaper than LRU bookkeeping; th_ files remain on disk
    listThumbUrlCache := Map()
}

ListThumbCacheName(name) {
    base := RegExReplace(String(name), "\.[^.]+$", "")
    return "th_" base ".jpg"
}

EnsureListThumbFile(name) {
    global STORE_DIR
    src := STORE_DIR "\" name
    if !FileExist(src)
        return ""
    cacheName := ListThumbCacheName(name)
    cachePath := STORE_DIR "\" cacheName
    if FileExist(cachePath) {
        try {
            if FileGetTime(cachePath, "M") >= FileGetTime(src, "M")
                return cacheName
        } catch {
            return cacheName
        }
    }
    if MakeListThumbJpeg(src, cachePath)
        return cacheName
    return ""
}

MakeListThumbJpeg(srcPath, destPath) {
    pToken := 0, pBitmap := 0, pThumb := 0, pGfx := 0
    try {
        DllCall("LoadLibrary", "Str", "gdiplus.dll", "Ptr")
        si := Buffer(24, 0)
        NumPut("UInt", 1, si)
        if DllCall("gdiplus\GdiplusStartup", "Ptr*", &pToken, "Ptr", si, "Ptr", 0)
            return false
        if DllCall("gdiplus\GdipCreateBitmapFromFile", "WStr", srcPath, "Ptr*", &pBitmap) || !pBitmap
            return false
        DllCall("gdiplus\GdipGetImageWidth", "Ptr", pBitmap, "UInt*", &w := 0)
        DllCall("gdiplus\GdipGetImageHeight", "Ptr", pBitmap, "UInt*", &h := 0)
        if w < 1 || h < 1
            return false
        maxEdge := 420
        if (w > maxEdge || h > maxEdge) {
            sc := Min(maxEdge / w, maxEdge / h)
            nw := Max(1, Round(w * sc)), nh := Max(1, Round(h * sc))
            DllCall("gdiplus\GdipCreateBitmapFromScan0", "Int", nw, "Int", nh,
                "Int", 0, "Int", 0x26200A, "Ptr", 0, "Ptr*", &pThumb)
            if !pThumb
                return false
            DllCall("gdiplus\GdipGetImageGraphicsContext", "Ptr", pThumb, "Ptr*", &pGfx)
            if pGfx {
                DllCall("gdiplus\GdipSetInterpolationMode", "Ptr", pGfx, "Int", 7)
                DllCall("gdiplus\GdipDrawImageRectI", "Ptr", pGfx, "Ptr", pBitmap, "Int", 0, "Int", 0, "Int", nw, "Int", nh)
                DllCall("gdiplus\GdipDeleteGraphics", "Ptr", pGfx)
                pGfx := 0
            }
            DllCall("gdiplus\GdipDisposeImage", "Ptr", pBitmap)
            pBitmap := pThumb
            pThumb := 0
        }
        ; JPEG encoder
        clsid := Buffer(16)
        DllCall("ole32\CLSIDFromString", "Str", "{557CF401-1A04-11D3-9A73-0000F81EF32E}", "Ptr", clsid)
        if FileExist(destPath)
            try FileDelete destPath
        if DllCall("gdiplus\GdipSaveImageToFile", "Ptr", pBitmap, "WStr", destPath, "Ptr", clsid, "Ptr", 0)
            return false
        return FileExist(destPath) ? true : false
    } catch {
        return false
    } finally {
        if pGfx
            try DllCall("gdiplus\GdipDeleteGraphics", "Ptr", pGfx)
        if pThumb
            try DllCall("gdiplus\GdipDisposeImage", "Ptr", pThumb)
        if pBitmap
            try DllCall("gdiplus\GdipDisposeImage", "Ptr", pBitmap)
        if pToken
            try DllCall("gdiplus\GdiplusShutdown", "Ptr", pToken)
    }
}

ClipsToJson(append := false) {
    global clips
    return ClipsListToJson(clips, append)
}

ClipsListToJson(list, append := false) {
    global PAGE_SIZE, lastAppendCount
    if !IsObject(list)
        list := []
    start := 1
    if append && lastAppendCount > 0
        start := Max(1, list.Length - lastAppendCount + 1)
    out := "["
    first := true
    loop list.Length {
        i := A_Index
        if i < start
            continue
        c := list[i]
        if !first
            out .= ","
        first := false
        imgFile := c.HasProp("imgFile") ? c.imgFile : ""
        preview := c.HasProp("preview") ? String(c.preview) : ""
        ; List payload must stay small —full text body is loaded only on paste
        if c.type = "image" {
            data := ""
            preview := ""
        } else if c.type = "link" {
            data := (c.HasProp("data") && c.data != "") ? String(c.data) : preview
            if preview = ""
                preview := data
        } else if c.type = "file" {
            data := preview != "" ? preview : String(c.HasProp("data") ? c.data : "")
            if preview = ""
                preview := data
        } else if c.type = "recent" {
            data := String(c.HasProp("data") ? c.data : "")
            if data = ""
                data := preview
            if preview = ""
                preview := data
        } else {
            data := ""
            if preview = "" && c.HasProp("data") && c.data != ""
                preview := SubStr(String(c.data), 1, 500)
        }
        uid := c.HasProp("uid") ? Integer(c.uid) : i
        ApplyQueueMetaToItem(c)
        out .= "{"
        out .= '"id":' uid ","
        out .= '"type":"' c.type '",'
        out .= '"time":"' c.time '",'
        out .= '"pinned":' (c.pinned ? "true" : "false") ","
        out .= '"pasted":' ((c.HasProp("pasted") && c.pasted) ? "true" : "false") ","
        out .= '"queueGroup":' (c.HasProp("queueGroup") ? Integer(c.queueGroup) : 0) ","
        out .= '"queueIndex":' (c.HasProp("queueIndex") ? Integer(c.queueIndex) : 0) ","
        out .= '"charCount":' (c.HasProp("charCount") ? c.charCount : 0) ","
        out .= '"fileCount":' (c.HasProp("fileCount") ? c.fileCount : 0) ","
        out .= '"width":' (c.HasProp("width") ? c.width : 0) ","
        out .= '"height":' (c.HasProp("height") ? c.height : 0) ","
        out .= '"imgFile":' JsonStr(imgFile) ","
        out .= '"linkTitle":' JsonStr(c.HasProp("linkTitle") ? c.linkTitle : "") ","
        out .= '"linkHost":' JsonStr(c.HasProp("linkHost") ? c.linkHost : "") ","
        out .= '"favTitle":' JsonStr(c.HasProp("favTitle") ? c.favTitle : "") ","
        out .= '"favGroup":' JsonStr(c.HasProp("favGroup") ? c.favGroup : "") ","
        out .= '"srcIcon":' JsonStr(c.HasProp("srcIcon") ? c.srcIcon : "") ","
        out .= '"srcExe":' JsonStr(c.HasProp("srcExe") ? c.srcExe : "") ","
        out .= '"srcTitle":' JsonStr(c.HasProp("srcTitle") ? c.srcTitle : "") ","
        out .= '"isMd":' ((c.HasProp("isMd") && c.isMd) ? "true" : "false") ","
        out .= '"isRich":' ((c.HasProp("isRich") && c.isRich) ? "true" : "false") ","
        out .= '"preview":' JsonStr(preview) ","
        out .= '"data":' JsonStr(data)
        out .= "}"
    }
    return out "]"
}

ImageDataUrlForId(uid) {
    c := ResolveClip(uid)
    if !IsObject(c)
        return ""
    if c.HasProp("imgFile") && c.imgFile != "" {
        u := ListThumbDataUrl(c.imgFile)
        if u != ""
            return u
    }
    if c.type = "image"
        return c.HasProp("data") ? String(c.data) : ""
    return ""
}

JsonStr(s) {
    s := StrReplace(s, "\", "\\")
    s := StrReplace(s, '"', '\"')
    s := StrReplace(s, "`n", "\n")
    s := StrReplace(s, "`r", "\r")
    s := StrReplace(s, "`t", "\t")
    return '"' s '"'
}

PasteItem(uid) {
    global prevActiveWin, clipIgnore, uiPinned, pasteQueueMode
    ; Manual panel paste aborts active FIFO queue (keep original paste flow)
    if pasteQueueMode
        ExitPasteQueue("panel-paste")
    item := ResolveClip(uid)
    if !IsObject(item)
        return
    if StrLower(String(item.type)) = "recent" {
        path := item.HasProp("data") ? String(item.data) : String(item.preview)
        OpenFolderDir(path)
        return
    }

    eraseN := QQTypedEraseCount()
    ; 未固定：先藏面板再粘贴；固定：保持 UI，粘贴到原编辑光标处
    if !uiPinned
        HidePanel()

    clipIgnore := true
    try {
        ok := false
        if item.type = "file" {
            paths := GetItemFilePaths(item)
            if paths.Length
                ok := SetClipboardFiles(paths)
        } else if item.type = "image" {
            paths := BuildAhkNamedPastePaths([item])
            if paths.Length
                ok := SetClipboardFiles(paths)
        }
        if !ok && !PutItemOnClipboard(item)
            return
        MarkItemsPasted([item.uid])
        target := ResolvePasteTargetWin()
        if target {
            DllCall("SetForegroundWindow", "Ptr", target)
            Sleep 15
        }
        QQEraseTypedInEditor(eraseN)
        TriggerPasteKey()
    } finally {
        SetTimer(() => (clipIgnore := false), -400)
        if uiPinned
            SetTimer(RaiseClipboardPanel, -50)
    }
}

PasteMany(idsStr, sepToken := "") {
    global prevActiveWin, clipIgnore, uiPinned, pasteQueueMode
    if pasteQueueMode
        ExitPasteQueue("panel-paste-many")
    items := []
    uids := []
    for part in StrSplit(String(idsStr), ",") {
        part := Trim(part)
        if part = ""
            continue
        it := ResolveClip(part)
        if !IsObject(it)
            continue
        items.Push(it)
        uids.Push(it.uid)
    }
    if items.Length = 0
        return
    ; 单条且无分隔符 → 普通粘贴；有分隔符（含列表包裹）则走合并，以便拆多行
    if items.Length = 1 && String(sepToken) = "" {
        PasteItem(uids[1])
        return
    }

    ; 有分隔符且全部为文本/链接 → 一次合并粘贴
    sepTok := String(sepToken)
    if sepTok != "" {
        allText := true
        for it in items {
            if !(it.type = "text" || it.type = "link") {
                allText := false
                break
            }
        }
        if allText {
            parts := []
            for it in items {
                EnsureClipBodyLoaded(it)
                parts.Push(it.HasProp("data") ? String(it.data) : "")
            }
            joined := JoinClipPartsWithSep(parts, sepTok)
            eraseN := QQTypedEraseCount()
            if !uiPinned
                HidePanel()
            clipIgnore := true
            try {
                A_Clipboard := joined
                MarkItemsPasted(uids)
                target := ResolvePasteTargetWin()
                if target {
                    DllCall("SetForegroundWindow", "Ptr", target)
                    Sleep 30
                }
                QQEraseTypedInEditor(eraseN)
                TriggerPasteKey()
            } finally {
                SetTimer(() => (clipIgnore := false), -500)
                if uiPinned
                    SetTimer(RaiseClipboardPanel, -50)
            }
            return
        }
    }

    paths := CollectPasteFilePaths(items)
    if paths.Length {
        eraseN := QQTypedEraseCount()
        if !uiPinned
            HidePanel()
        clipIgnore := true
        try {
            if !SetClipboardFiles(paths)
                return
            MarkItemsPasted(uids)
            target := ResolvePasteTargetWin()
            if target {
                DllCall("SetForegroundWindow", "Ptr", target)
                Sleep 30
            }
            QQEraseTypedInEditor(eraseN)
            TriggerPasteKey()
        } finally {
            SetTimer(() => (clipIgnore := false), -500)
            if uiPinned
                SetTimer(RaiseClipboardPanel, -50)
        }
        return
    }

    eraseN := QQTypedEraseCount()
    if !uiPinned
        HidePanel()
    clipIgnore := true
    pastedIds := []
    try {
        target := ResolvePasteTargetWin()
        if target {
            DllCall("SetForegroundWindow", "Ptr", target)
            Sleep 20
        }
        QQEraseTypedInEditor(eraseN)
        for i, it in items {
            if !PutItemOnClipboard(it)
                continue
            pastedIds.Push(it.uid)
            Sleep 80
            TriggerPasteKey()
            if i < items.Length
                Sleep 220
        }
        if pastedIds.Length
            MarkItemsPasted(pastedIds)
    } finally {
        SetTimer(() => (clipIgnore := false), -500)
        if uiPinned
            SetTimer(RaiseClipboardPanel, -50)
    }
}

; Gather on-disk paths for a batch of image/file clips (for one HDROP paste)
CollectPasteFilePaths(items) {
    paths := []
    if !IsObject(items) || items.Length < 1
        return paths
    imageBatch := []
    for item in items {
        if item.type = "file" {
            if imageBatch.Length {
                built := BuildAhkNamedPastePaths(imageBatch)
                if !built.Length
                    return []
                for p in built
                    paths.Push(p)
                imageBatch := []
            }
            fps := GetItemFilePaths(item)
            if !fps.Length
                return []
            for p in fps
                paths.Push(p)
        } else if item.type = "image" {
            imageBatch.Push(item)
        } else {
            return []
        }
    }
    if imageBatch.Length {
        built := BuildAhkNamedPastePaths(imageBatch)
        if !built.Length
            return []
        for p in built
            paths.Push(p)
    }
    return paths
}

; Copy clip images/files to temp as ahk_2026-07-19 00-20-31_1.png for Explorer paste names
BuildAhkNamedPastePaths(items) {
    paths := []
    if !IsObject(items) || items.Length < 1
        return paths
    stamp := FormatTime(, "yyyy-MM-dd HH-mm-ss")
    tick := A_TickCount
    idx := 0
    for item in items {
        src := GetItemFilePath(item)
        if src = ""
            return []
        dotPos := InStr(src, ".", false, -1)
        ext := dotPos > 0 ? StrLower(SubStr(src, dotPos + 1)) : "png"
        if ext = ""
            ext := "png"
        ; uid + tick + idx: never collide when called once-per-item in the same second
        uidPart := (item.HasProp("uid") && item.uid) ? Integer(item.uid) : Random(1000, 9999)
        dest := A_Temp "\ahk_" stamp "_" uidPart "_" tick "_" (++idx) "." ext
        try FileCopy src, dest, 1
        catch
            return []
        if !FileExist(dest)
            return []
        paths.Push(dest)
    }
    return paths
}

; Resolve on-disk path for image/file clip items (for HDROP multi-paste)
GetItemFilePath(item) {
    if item.type = "file" {
        paths := GetItemFilePaths(item)
        return paths.Length ? paths[1] : ""
    }
    global STORE_DIR
    if !IsObject(item)
        return ""
    if item.type = "image" {
        if item.HasProp("imgFile") && item.imgFile != "" {
            p := STORE_DIR "\" item.imgFile
            if FileExist(p)
                return p
        }
        if InStr(item.data, "base64,") {
            p := A_Temp "\clipmgr_m" A_TickCount "_" Random(1000, 9999) ".png"
            if RegExMatch(item.data, "i)base64,([\s\S]+)$", &m) && B64DecodeToFile(m[1], p)
                return p
        }
        return ""
    }
    return ""
}

; All existing paths from a file clip (files and folders)
GetItemFilePaths(item) {
    paths := []
    if !IsObject(item) || item.type != "file"
        return paths
    raw := ""
    if item.HasProp("data") && item.data != ""
        raw := String(item.data)
    else if item.HasProp("preview")
        raw := String(item.preview)
    for ln in StrSplit(raw, "`n", "`r") {
        ln := Trim(ln)
        if ln != "" && FileExist(ln)
            paths.Push(ln)
    }
    return paths
}

; "1" / "0" —simple return for WebView hostObjects (avoids JSON parse issues)
PathExistsFlag(path := "") {
    path := Trim(String(path))
    if (SubStr(path, 1, 1) = '"' && SubStr(path, -1) = '"')
        || (SubStr(path, 1, 1) = "'" && SubStr(path, -1) = "'")
        path := Trim(SubStr(path, 2, -1))
    if path = ""
        return "0"
    return FileExist(path) ? "1" : "0"
}

; JSON for UI hover tip: [{"path":"...","exists":true,"isDir":false}, ...]
CheckFilePathsJson(raw := "") {
    out := "["
    first := true
    for ln in StrSplit(String(raw), "`n", "`r") {
        ln := Trim(ln)
        if ln = ""
            continue
        ex := FileExist(ln)
        if !first
            out .= ","
        first := false
        out .= "{"
        out .= '"path":' JsonStr(ln) ","
        out .= '"exists":' (ex ? "true" : "false") ","
        out .= '"isDir":' ((ex && InStr(ex, "D")) ? "true" : "false")
        out .= "}"
    }
    return out "]"
}

; Put multiple files on clipboard as CF_HDROP (Explorer pastes them all at once)
SetClipboardFiles(paths) {
    if !IsObject(paths) || paths.Length < 1
        return false
    ; Dedupe identical paths (guards against same temp name twice → one image pasted twice)
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
    paths := uniq
    totalChars := 1
    for p in paths
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
    for p in paths {
        StrPut(p, ptr + pos, "UTF-16")
        pos += (StrLen(p) + 1) * 2
    }
    DllCall("GlobalUnlock", "Ptr", hMem)

    ; Preferred DropEffect = COPY so Explorer pastes (not move/fail)
    hEffect := DllCall("GlobalAlloc", "UInt", 0x0002, "UPtr", 4, "Ptr")
    if hEffect {
        pEff := DllCall("GlobalLock", "Ptr", hEffect, "Ptr")
        if pEff {
            NumPut("UInt", 1, pEff, 0) ; DROPEFFECT_COPY
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

; Bridge entry: leave WebView sync stack + debounce (click→抙ost.call re-entrancy = double paste)
RequestPaste(id) {
    global pasteLockUntil
    if A_TickCount < pasteLockUntil
        return
    pasteLockUntil := A_TickCount + 500
    pasteId := id
    SetTimer(() => PasteItem(pasteId), -10)
}

RequestPasteMany(ids, sep := "") {
    global pasteLockUntil
    if A_TickCount < pasteLockUntil
        return
    pasteLockUntil := A_TickCount + 500
    pasteIds := ids
    pasteSep := String(sep)
    SetTimer(() => PasteMany(pasteIds, pasteSep), -10)
}

NormalizePasteSep(tok) {
    tok := String(tok)
    if tok = "" || tok = " "
        return " "
    if tok = "[换行]" || tok = "换行"
        return "`n"
    if tok = "[制表符]"
        return "`t"
    return tok
}

; 条目内按行拆开：每行单独走分隔符；仅跳过末尾空行（复制时常带尾换行）
ExpandPartsByNewline(parts) {
    out := []
    for p in parts {
        lines := StrSplit(String(p), "`n", "`r")
        while lines.Length > 0 && lines[lines.Length] = ""
            lines.Pop()
        for line in lines
            out.Push(line)
    }
    return out
}

; 按分隔符/包裹格式拼接文本条目
JoinClipPartsWithSep(parts, sepTok) {
    sepTok := String(sepTok)
    parts := ExpandPartsByNewline(parts)
    ; ["",""] → ["a","b"]
    if sepTok = "[`"`",`"`"]" {
        out := "["
        for i, p in parts {
            if i > 1
                out .= ","
            out .= '"' p '"'
        }
        return out "]"
    }
    ; ('','') → ('a','b')
    if sepTok = "('','')" {
        out := "("
        for i, p in parts {
            if i > 1
                out .= ","
            out .= "'" p "'"
        }
        return out ")"
    }
    sep := NormalizePasteSep(sepTok)
    out := ""
    for i, p in parts {
        if i > 1
            out .= sep
        out .= p
    }
    return out
}

; SendLevel 0: injected Ctrl+V must not re-enter ~^v / PastePngToDir.
; Explorer/Desktop already pastes HDROP/bitmap once —calling PastePngToDir here duplicated files (2→).
TriggerPasteKey() {
    global pasteSending
    pasteSending := true
    prevLvl := A_SendLevel
    try {
        SendLevel 0
        SendInput "^v"
    } finally {
        SendLevel prevLvl
        SetTimer(() => (pasteSending := false), -120)
    }
}

PutItemOnClipboard(item) {
    global STORE_DIR
    if !IsObject(item)
        return false

    if item.type = "image" {
        imgPath := ""
        if item.HasProp("imgFile") && item.imgFile != ""
            imgPath := STORE_DIR "\" item.imgFile
        if (imgPath = "" || !FileExist(imgPath)) && InStr(item.data, "base64,") {
            imgPath := A_Temp "\clipmgr_p" A_TickCount ".png"
            if RegExMatch(item.data, "i)base64,([\s\S]+)$", &m)
                B64DecodeToFile(m[1], imgPath)
        }
        if imgPath != "" && FileExist(imgPath)
            return SetClipboardImage(imgPath)
        if item.HasProp("clipAll") && IsObject(item.clipAll) && item.clipAll.Size > 0 {
            A_Clipboard := item.clipAll
            return true
        }
        return false
    }

    if item.HasProp("clipAll") && IsObject(item.clipAll) && item.clipAll.Size > 0 {
        A_Clipboard := item.clipAll
        return true
    }
    if item.type = "file" {
        paths := GetItemFilePaths(item)
        if paths.Length
            return SetClipboardFiles(paths)
        ; Fallback: path text if files were moved/deleted
        A_Clipboard := item.data
        return true
    }
    if item.type = "text" || item.type = "link" {
        EnsureClipBodyLoaded(item)
        data := item.HasProp("data") ? String(item.data) : ""
        if data = ""
            return false
        A_Clipboard := data
        return true
    }
    return false
}

CopyById(uid) {
    item := ResolveClip(uid)
    if !IsObject(item)
        return
    if item.type = "file" {
        paths := GetItemFilePaths(item)
        if paths.Length
            SetClipboardFiles(paths)
        else
            A_Clipboard := item.data
        return
    }
    if item.type = "text" || item.type = "link"
        A_Clipboard := item.data
}

DeleteItem(uid) {
    global clips, viewTotal, wvCore, lastTxt, lastImg, pasteQueueMode, pasteQueueIds, queueMetaMap
    uid := Integer(uid)
    ; Optimistic UI: remove from memory first, disk later — 禁止 ResolveClip 全盘扫描
    imgFile := ""
    itemType := ""
    for c in clips {
        if c.uid = uid {
            if c.HasProp("imgFile")
                imgFile := c.imgFile
            itemType := c.type
            if itemType = "text" || itemType = "link"
                lastTxt := ""
            else if itemType = "image"
                lastImg := ""
            break
        }
    }
    MemoryRemoveUid(uid)
    LiveFrontRemoveUid(uid)
    ; Keep FIFO / meta in sync — stale ids made ^+c / Ctrl+V look "dead" after deletes
    if IsObject(pasteQueueIds) && pasteQueueIds.Length {
        i := 1
        while i <= pasteQueueIds.Length {
            if Integer(pasteQueueIds[i]) = uid
                pasteQueueIds.RemoveAt(i)
            else
                i += 1
        }
        if pasteQueueMode {
            if !pasteQueueIds.Length
                ExitPasteQueue("deleted-all")
            else
                SavePasteQueueState()
        }
    }
    if IsObject(queueMetaMap) && queueMetaMap.Has(String(uid)) {
        queueMetaMap.Delete(String(uid))
        try SaveQueueMeta()
    }
    RequestUiPush()
    EnqueueDiskJob(PersistDeleteUid.Bind(uid, imgFile, itemType))
}

DeleteItemsMany(idsStr) {
    idsStr := String(idsStr)
    seen := Map()
    for part in StrSplit(idsStr, ",") {
        uid := Integer(Trim(part))
        if uid < 1 || seen.Has(uid)
            continue
        seen[uid] := true
        DeleteItem(uid)
    }
}

PinItem(uid) {
    global clips, viewTab, viewQuery, viewToday, wvCore, viewCache, recentFolders
    uid := Integer(uid)
    if IsObject(recentFolders) {
        for c in recentFolders {
            if !IsObject(c) || Integer(c.uid) != uid
                continue
            c.pinned := !(c.HasProp("pinned") && c.pinned)
            ; Memory + one cache rebuild; disk write async (was freezing right-click pin)
            try CacheRecentFoldersView(viewToday)
            if viewTab = "recent" {
                page := QueryRecentFoldersPage(viewQuery, viewToday, 0, VIEW_PAGE_SIZE)
                clips := page.items
                viewTotal := page.total
                PushClips(false)
            } else
                RequestUiPush()
            EnqueueDiskJob(SaveRecentFolders)
            return
        }
    }
    newPin := unset
    pinAt := ""
    for c in clips {
        if c.uid = uid {
            c.pinned := !(c.HasProp("pinned") && c.pinned)
            newPin := c.pinned
            if newPin {
                pinAt := FormatTime(, "yyyy-MM-dd HH:mm:ss")
                c.pinTime := pinAt
            } else
                c.pinTime := ""
            break
        }
    }
    if !IsSet(newPin) {
        ; Not in current list —still flip on disk/cache via resolve
        it := ResolveClip(uid)
        if !IsObject(it)
            return
        it.pinned := !(it.HasProp("pinned") && it.pinned)
        newPin := it.pinned
        if newPin {
            pinAt := FormatTime(, "yyyy-MM-dd HH:mm:ss")
            it.pinTime := pinAt
        } else
            it.pinTime := ""
    }
    for , entry in viewCache {
        if !IsObject(entry) || !entry.HasProp("items")
            continue
        for c in entry.items {
            if c.uid = uid {
                c.pinned := newPin
                c.pinTime := newPin ? pinAt : ""
                break
            }
        }
    }
    ; Keep liveFront in sync (not-yet-persisted copies)
    global liveFront
    if IsObject(liveFront) {
        for c in liveFront {
            if IsObject(c) && c.uid = uid {
                c.pinned := newPin
                c.pinTime := newPin ? pinAt : ""
                break
            }
        }
    }
    ; Drop stale 收藏-tab caches (membership / order changed)
    dropKeys := []
    for key, entry in viewCache {
        tab := "", todayOnly := false, query := ""
        ParseViewCacheKey(key, &tab, &todayOnly, &query)
        if tab = "pinned"
            dropKeys.Push(key)
    }
    for key in dropKeys
        viewCache.Delete(key)
    ; 必须清掉 pinned searchPools，否则新收藏进不了「收藏」页（旧池一直缓存）
    InvalidatePinnedSearchPools()
    ; Persist async —sync disk + SetView made pin clicks hitch
    EnqueueDiskJob(DiskSetPinned.Bind(uid, newPin, pinAt))
    if viewTab = "pinned" {
        if !newPin {
            ; 取消收藏：当前页立刻摘掉，勿走慢速全量 SetView
            kept := []
            for c in clips {
                if !IsObject(c) || Integer(c.uid) != uid
                    kept.Push(c)
            }
            clips := kept
            viewTotal := Max(0, Integer(viewTotal) - 1)
            PushClips(false)
        } else {
            ; 新收藏落在收藏页：补一次视图（相对少见）
            QueueSetView(viewTab, viewQuery, viewToday ? "1" : "0")
        }
    } else if viewQuery != "" {
        QueueSetView(viewTab, viewQuery, viewToday ? "1" : "0")
    } else
        RequestUiPush()
}

InvalidatePinnedSearchPools() {
    global searchPools
    if !IsObject(searchPools)
        return
    dropKeys := []
    for key, _ in searchPools {
        tab := "", todayOnly := false, query := ""
        ParseViewCacheKey(key, &tab, &todayOnly, &query)
        if tab = "pinned"
            dropKeys.Push(key)
    }
    for key in dropKeys
        searchPools.Delete(key)
}

MarkItemsPasted(uids) {
    global clips, viewCache, liveFront, panelVisible, wvCore
    want := Map()
    idList := []
    for uid in uids {
        id := Integer(uid)
        if id < 1
            continue
        want[id] := true
        idList.Push(id)
    }
    if !want.Count
        return
    ; Optimistic memory update —disk write is async (was blocking paste for seconds)
    for c in clips {
        if want.Has(c.uid)
            c.pasted := true
    }
    if IsObject(liveFront) {
        for c in liveFront {
            if IsObject(c) && want.Has(c.uid)
                c.pasted := true
        }
    }
    for , entry in viewCache {
        if !IsObject(entry) || !entry.HasProp("items")
            continue
        for c in entry.items {
            if want.Has(c.uid)
                c.pasted := true
        }
    }
    EnqueueDiskJob(DiskSetPasted.Bind(want, true))
    ; Instant ✓ — inject even if panel just hid (FIFO paste); WebView keeps DOM
    if IsObject(wvCore) && idList.Length {
        jsIds := ""
        for i, id in idList
            jsIds .= (i > 1 ? "," : "") id
        try wvCore.ExecuteScriptAsync("window.__markPasted&&window.__markPasted([" jsIds "])")
    }
}

ClearPasted(uid) {
    global clips
    uid := Integer(uid)
    want := Map()
    want[uid] := true
    DiskSetPasted(want, false)
    for c in clips {
        if c.uid = uid {
            c.pasted := false
            break
        }
    }
    PushClips(false)
}

SetFavTitle(uid, title := "") {
    global clips, viewTab, viewQuery, viewToday, wvCore, viewCache
    uid := Integer(uid)
    title := Trim(String(title))
    if StrLen(title) > 80
        title := SubStr(title, 1, 80)
    found := false
    for c in clips {
        if c.uid = uid {
            c.favTitle := title
            found := true
            break
        }
    }
    if !found {
        it := ResolveClip(uid)
        if !IsObject(it)
            return
        it.favTitle := title
    }
    for , entry in viewCache {
        if !IsObject(entry) || !entry.HasProp("items")
            continue
        for c in entry.items {
            if c.uid = uid {
                c.favTitle := title
                break
            }
        }
    }
    DiskSetFavTitle(uid, title)
    if viewQuery != "" || viewTab = "pinned"
        SetView(viewTab, viewQuery, viewToday ? "1" : "0")
    else if IsObject(wvCore)
        PushClips(false)
}

ApplyFavGroupLocal(uid, gid) {
    global clips, viewCache
    uid := Integer(uid)
    gid := String(gid)
    for c in clips {
        if c.uid = uid {
            c.favGroup := gid
            break
        }
    }
    for , entry in viewCache {
        if !IsObject(entry) || !entry.HasProp("items")
            continue
        for c in entry.items {
            if c.uid = uid {
                c.favGroup := gid
                break
            }
        }
    }
}

MergeFavItems(idsCsv := "") {
    global viewTab, viewQuery, viewToday, wvCore, viewCache
    ids := []
    seen := Map()
    for part in StrSplit(String(idsCsv), ",") {
        uid := Integer(Trim(part))
        if uid < 1 || seen.Has(uid)
            continue
        seen[uid] := true
        ids.Push(uid)
    }
    if ids.Length < 2
        return
    gid := "g" A_Now "_" Random(1000, 9999)
    for uid in ids {
        it := ResolveClip(uid)
        if !IsObject(it)
            continue
        ; Merge is a favorites feature —keep pinned
        if !(it.HasProp("pinned") && it.pinned) {
            it.pinned := true
            it.pinTime := FormatTime(, "yyyy-MM-dd HH:mm:ss")
            DiskSetPinned(uid, true, it.pinTime)
        }
        ApplyFavGroupLocal(uid, gid)
        DiskSetFavGroup(uid, gid)
    }
    ; Drop pinned-tab caches (order/grouping changed)
    dropKeys := []
    for key, entry in viewCache {
        tab := "", todayOnly := false, query := ""
        ParseViewCacheKey(key, &tab, &todayOnly, &query)
        if tab = "pinned"
            dropKeys.Push(key)
    }
    for key in dropKeys
        viewCache.Delete(key)
    InvalidatePinnedSearchPools()
    if viewTab = "pinned" || viewQuery != ""
        SetView(viewTab, viewQuery, viewToday ? "1" : "0")
    else if IsObject(wvCore)
        PushClips(false)
}

UnmergeFavItem(uid := 0) {
    global viewTab, viewQuery, viewToday, wvCore, viewCache, clips
    uid := Integer(uid)
    if uid < 1
        return
    it := ResolveClip(uid)
    if !IsObject(it)
        return
    gid := it.HasProp("favGroup") ? String(it.favGroup) : ""
    if gid = ""
        return
    targets := []
    for c in clips {
        if c.HasProp("favGroup") && String(c.favGroup) = gid
            targets.Push(c.uid)
    }
    ; Also clear mates only present in viewCache / disk resolve
    if !targets.Length
        targets.Push(uid)
    for , entry in viewCache {
        if !IsObject(entry) || !entry.HasProp("items")
            continue
        for c in entry.items {
            if c.HasProp("favGroup") && String(c.favGroup) = gid {
                found := false
                for t in targets {
                    if t = c.uid {
                        found := true
                        break
                    }
                }
                if !found
                    targets.Push(c.uid)
            }
        }
    }
    for t in targets {
        ApplyFavGroupLocal(t, "")
        DiskSetFavGroup(t, "")
    }
    dropKeys := []
    for key, entry in viewCache {
        tab := "", todayOnly := false, query := ""
        ParseViewCacheKey(key, &tab, &todayOnly, &query)
        if tab = "pinned"
            dropKeys.Push(key)
    }
    for key in dropKeys
        viewCache.Delete(key)
    InvalidatePinnedSearchPools()
    if viewTab = "pinned" || viewQuery != ""
        SetView(viewTab, viewQuery, viewToday ? "1" : "0")
    else if IsObject(wvCore)
        PushClips(false)
}

OpenLink(uid) {
    item := ResolveClip(uid)
    if !IsObject(item)
        return
    url := ""
    if item.type = "link"
        url := item.data
    else if item.type = "text" && RegExMatch(Trim(item.data), "i)^https?://")
        url := Trim(item.data)
    if url = ""
        return
    try Run(url)
    HidePanel()
}

OpenFilePath(path := "") {
    path := Trim(String(path))
    if (SubStr(path, 1, 1) = '"' && SubStr(path, -1) = '"')
        || (SubStr(path, 1, 1) = "'" && SubStr(path, -1) = "'")
        path := Trim(SubStr(path, 2, -1))
    if path = ""
        return
    if !FileExist(path)
        return
    ; Quote path so spaces / special chars still open
    try Run('"' path '"')
    catch {
        try DllCall("shell32\ShellExecuteW", "ptr", 0, "wstr", "open", "wstr", path, "ptr", 0, "ptr", 0, "int", 1)
    }
    HidePanel()
}

; Open a directory itself (recent-folder tab / Enter / path crumbs)
OpenFolderDir(path := "") {
    global uiPinned, qqSearchOn, qqQuery, viewQuery, viewTab, viewToday, wvCore
    path := Trim(String(path))
    path := StrReplace(path, "/", "\")
    if (SubStr(path, 1, 1) = '"' && SubStr(path, -1) = '"')
        || (SubStr(path, 1, 1) = "'" && SubStr(path, -1) = "'")
        path := Trim(SubStr(path, 2, -1))
    if path = ""
        return
    ; "E:" → "E:\" so DirExist / explorer work
    if RegExMatch(path, "^[a-zA-Z]:$")
        path .= "\"
    ClipLog("OpenFolderDir try " path)
    if !DirExist(path) {
        SplitPath path, , &dir
        if dir != "" && DirExist(dir)
            path := dir
        else {
            ClipLog("OpenFolderDir miss " path)
            return
        }
    }
    wasQQ := qqSearchOn
    eraseN := QQTypedEraseCount()
    ; Open explorer first —never call ExecuteScriptAsync inside sync WebView host
    try Run('explorer.exe "' path '"')
    if wasQQ {
        target := ResolvePasteTargetWin()
        if target {
            try DllCall("SetForegroundWindow", "Ptr", target)
            Sleep 15
        }
        QQEraseTypedInEditor(eraseN)
        QQStopSearch(true)
        qqQuery := ""
        viewQuery := ""
        ; Defer UI clear so we are outside the host call stack
        if IsObject(wvCore)
            SetTimer(() => (IsObject(wvCore) && wvCore.ExecuteScriptAsync("window.__clearQQSearch&&window.__clearQQSearch()")), -30)
    }
    if !uiPinned {
        HidePanel()
        return
    }
    if wasQQ
        SetTimer(() => SetView(viewTab, "", viewToday ? "1" : "0"), -40)
    SetTimer(RaiseClipboardPanel, -80)
}

; WebView2 postMessage: "openDir|E:/foo/bar" — 路径点击专用，避开 sync host
HandleUiWebMessage(core, args) {
    try {
        s := ""
        try s := String(args.TryGetWebMessageAsString())
        catch {
            try s := String(args.WebMessageAsJson)
        }
        s := Trim(s)
        if s = ""
            return
        ClipLog("WebMsg " SubStr(s, 1, 180))
        if SubStr(s, 1, 5) = "perf|" {
            PerfMark("UI " SubStr(s, 6))
            return
        }
        if SubStr(s, 1, 8) = "openDir|" {
            p := SubStr(s, 9)
            p := Trim(p, ' `"')
            SetTimer(OpenFolderDir.Bind(p), -1)
            return
        }
    } catch as e {
        ClipLogErr("HandleUiWebMessage", e)
    }
}

OpenContainingFolder(path := "") {
    path := Trim(String(path))
    if (SubStr(path, 1, 1) = '"' && SubStr(path, -1) = '"')
        || (SubStr(path, 1, 1) = "'" && SubStr(path, -1) = "'")
        path := Trim(SubStr(path, 2, -1))
    if path = ""
        return
    if FileExist(path) {
        try Run('explorer.exe /select,"' path '"')
        HidePanel()
        return
    }
    SplitPath path, , &dir
    if dir != "" && DirExist(dir) {
        try Run('explorer.exe "' dir '"')
        HidePanel()
    }
}

CopyFilePath(path := "") {
    global clipIgnore
    path := Trim(String(path))
    if (SubStr(path, 1, 1) = '"' && SubStr(path, -1) = '"')
        || (SubStr(path, 1, 1) = "'" && SubStr(path, -1) = "'")
        path := Trim(SubStr(path, 2, -1))
    if path = ""
        return
    clipIgnore := true
    try A_Clipboard := path
    SetTimer(() => (clipIgnore := false), -400)
}

MoveToTop(uid) {
    global viewTab, viewQuery, viewToday, wvCore
    uid := Integer(uid)
    item := MemoryTakeUid(uid)
    if !IsObject(item)
        item := ResolveClip(uid)
    if !IsObject(item)
        return
    MemoryInsertFront(item)
    RequestUiPush()
    EnqueueDiskJob(PersistMoveToTop.Bind(item))
}

ClearAll(*) {
    ClearTab("all", "all")
}

; tab: all|text|image|file|link|pinned
; scope: today (default) | all
ClearTab(tab := "all", scope := "today") {
    global viewTab, viewQuery, viewToday, lastTxt, lastImg, clips, viewTotal, liveFront, pasteQueueMode, pasteQueueIds, queueMetaMap
    tab := StrLower(Trim(String(tab)))
    scope := StrLower(Trim(String(scope)))
    if tab = "recent" {
        ClearRecentFolders()
        InvalidateRecentViewCaches()
        try CacheRecentFoldersView(false)
        try CacheRecentFoldersView(true)
        RequestUiPush()
        SetView("recent", viewQuery, viewToday ? "1" : "0")
        return
    }
    clearAllDates := (scope = "all")
    today := FormatTime(, "yyyy-MM-dd")
    ; 清空历史后队列应重新从 +1 开始
    if pasteQueueMode || (IsObject(pasteQueueIds) && pasteQueueIds.Length)
        ExitPasteQueue("clear-tab")
    ; 先清内存并立刻刷新 UI，磁盘清空丢后台（否则 3000+ 条会卡死面板）
    MemoryClearTab(tab, clearAllDates, today)
    InvalidateViewCache()
    if tab = "all" || tab = "text" || tab = "link"
        lastTxt := ""
    if tab = "all" || tab = "image"
        lastImg := ""
    try {
        if tab = "all" && clearAllDates {
            queueMetaMap := Map()
            SaveQueueMeta()
        }
    }
    RequestUiPush()
    vt := viewTab, vq := viewQuery, vd := viewToday
    EnqueueDiskJob(() => (
        DiskClearTab(tab, clearAllDates, today),
        SetView(vt, vq, vd ? "1" : "0")
    ))
}

MemoryClearTab(tab, clearAllDates, today) {
    global clips, viewTotal, liveFront
    pred := (c) => ItemShouldClear(c, tab, clearAllDates, today)
    MemoryRemoveFromList(clips, pred)
    viewTotal := clips.Length
    if IsObject(liveFront)
        MemoryRemoveFromList(liveFront, pred)
}

ItemShouldClear(c, tab, clearAllDates, today) {
    if !IsObject(c)
        return false
    if !ItemMatchesClearTab(c, tab)
        return false
    if tab != "pinned" && c.HasOwnProp("pinned") && c.pinned
        return false
    if !clearAllDates {
        t := c.HasOwnProp("time") ? String(c.time) : ""
        if SubStr(t, 1, 10) != today
            return false
    }
    return true
}

ItemMatchesClearTab(c, tab) {
    type := c.HasOwnProp("type") ? StrLower(String(c.type)) : "text"
    switch tab {
        case "text", "image", "file", "link":
            return type = tab
        case "pinned":
            return c.HasOwnProp("pinned") && c.pinned
        default: ; all
            return type != "link"
    }
}

ScheduleSave() {
    ; Disk is written immediately by mutators; keep stub for any leftover callers
}

SaveImageToStore(dataUrl) {
    global STORE_DIR
    try {
        DirCreate STORE_DIR
        if !RegExMatch(dataUrl, "i)base64,([\s\S]+)$", &m)
            return ""
        name := "img_" A_Now "_" Random(10000, 99999) ".png"
        path := STORE_DIR "\" name
        if !B64DecodeToFile(m[1], path)
            return ""
        ; Build list thumb off the clipboard hot path
        nm := name
        SetTimer(() => EnsureListThumbSafe(nm), -80)
        return name
    } catch {
        return ""
    }
}

EnsureListThumbSafe(name) {
    try EnsureListThumbFile(name)
    catch as e {
        ClipLog("EnsureListThumbSafe fail name=" name " err=" e.Message)
    }
}

; 8.3 short path —WebView2 virtual host mapping fails on folders with spaces
GetShortPath(longPath) {
    longPath := String(longPath)
    if longPath = ""
        return ""
    bufSize := 520
    buf := Buffer(bufSize * 2, 0)
    n := DllCall("GetShortPathNameW", "WStr", longPath, "Ptr", buf, "UInt", bufSize, "UInt")
    if n && n < bufSize
        return StrGet(buf, "UTF-16")
    return longPath
}

ApplyClipSrc(item) {
    src := CaptureClipSrcIcon()
    item.srcIcon := src.icon
    item.srcExe := src.exe
    item.srcTitle := src.title
}

; Capture foreground (or last non-panel / non-snip) process icon + window title
CaptureClipSrcIcon() {
    global guiWin, prevActiveWin, lastGoodActiveWin
    hwnd := 0
    try hwnd := WinExist("A")
    if IsObject(guiWin) && guiWin.Hwnd && hwnd = guiWin.Hwnd
        hwnd := prevActiveWin ? prevActiveWin : lastGoodActiveWin
    ; Win+Shift+S / 截图工具常会抢前台 — 用截图前的真实窗口
    if IsScreenshotHelperHwnd(hwnd) || IsShellOverlayHwnd(hwnd)
        hwnd := lastGoodActiveWin ? lastGoodActiveWin : prevActiveWin
    empty := { icon: "", exe: "", title: "" }
    if !hwnd
        return empty
    exePath := ""
    exeName := ""
    try {
        exePath := WinGetProcessPath("ahk_id " hwnd)
        exeName := WinGetProcessName("ahk_id " hwnd)
    }
    if IsScreenshotHelperExe(exeName) {
        hwnd := lastGoodActiveWin ? lastGoodActiveWin : prevActiveWin
        if !hwnd
            return empty
        try {
            exePath := WinGetProcessPath("ahk_id " hwnd)
            exeName := WinGetProcessName("ahk_id " hwnd)
        }
    }
    title := ClipSrcWindowTitle(hwnd, exeName)
    if exePath = "" || !FileExist(exePath)
        return { icon: "", exe: exeName, title: title }
    return { icon: SaveExeIconToStore(exePath), exe: exeName, title: title }
}

ClipSrcWindowTitle(hwnd, exeName := "") {
    global guiWin
    title := ""
    try title := Trim(WinGetTitle("ahk_id " hwnd))
    catch
        title := ""
    if IsObject(guiWin) && guiWin.Hwnd && hwnd = guiWin.Hwnd
        title := ""
    ; Strip common " — App" / " - App" suffixes only if leftover is empty
    if title = "" {
        exe := RegExReplace(String(exeName), "i)\.exe$", "")
        return exe
    }
    if StrLen(title) > 200
        title := SubStr(title, 1, 200)
    return title
}

IsScreenshotHelperExe(exe) {
    exe := StrLower(Trim(String(exe)))
    return exe = "screenclippinghost.exe"
        || exe = "snippingtool.exe"
        || exe = "pickerhost.exe"
        || exe = "screenshot.exe"
}

IsScreenshotHelperHwnd(hwnd) {
    if !hwnd
        return false
    try return IsScreenshotHelperExe(WinGetProcessName("ahk_id " hwnd))
    catch
        return false
}

SaveExeIconToStore(exePath) {
    global STORE_DIR
    exePath := Trim(String(exePath))
    if exePath = "" || !FileExist(exePath)
        return ""
    try DirCreate STORE_DIR
    SplitPath exePath, &exeName
    safe := RegExReplace(StrLower(exeName), "[^a-z0-9._-]+", "_")
    if safe = ""
        safe := "app"
    name := "appico_" safe ".png"
    dest := STORE_DIR "\" name
    if FileExist(dest)
        return name

    hLarge := 0, hSmall := 0, pToken := 0, pBitmap := 0
    try {
        DllCall("shell32\ExtractIconExW", "WStr", exePath, "Int", 0
            , "Ptr*", &hLarge, "Ptr*", &hSmall, "UInt", 1, "UInt")
        hIcon := hLarge ? hLarge : hSmall
        if !hIcon
            return ""

        DllCall("LoadLibrary", "Str", "gdiplus.dll", "Ptr")
        si := Buffer(24, 0)
        NumPut("UInt", 1, si)
        if DllCall("gdiplus\GdiplusStartup", "Ptr*", &pToken, "Ptr", si, "Ptr", 0)
            return ""
        if DllCall("gdiplus\GdipCreateBitmapFromHICON", "Ptr", hIcon, "Ptr*", &pBitmap) || !pBitmap
            return ""
        clsid := Buffer(16)
        DllCall("ole32\CLSIDFromString", "Str", "{557CF406-1A04-11D3-9A73-0000F81EF32E}", "Ptr", clsid)
        if DllCall("gdiplus\GdipSaveImageToFile", "Ptr", pBitmap, "WStr", dest, "Ptr", clsid, "Ptr", 0)
            return ""
        return FileExist(dest) ? name : ""
    } catch {
        return ""
    } finally {
        if hLarge
            try DllCall("DestroyIcon", "Ptr", hLarge)
        if hSmall && hSmall != hLarge
            try DllCall("DestroyIcon", "Ptr", hSmall)
        if pBitmap
            try DllCall("gdiplus\GdipDisposeImage", "Ptr", pBitmap)
        if pToken
            try DllCall("gdiplus\GdiplusShutdown", "Ptr", pToken)
    }
}

IsImageFilePath(path) {
    path := Trim(String(path))
    if path = ""
        return false
    SplitPath path, , , &ext
    ext := StrLower(ext)
    static imgExt := " png jpg jpeg gif webp bmp ico tif tiff svg "
    return InStr(imgExt, " " ext " ")
}

; Copy first image file path into clips_store so UI can use https://clips.store/ like screenshots
EnsureFileImageInStore(path := "", uid := 0) {
    global STORE_DIR
    path := Trim(String(path))
    if (SubStr(path, 1, 1) = '"' && SubStr(path, -1) = '"')
        || (SubStr(path, 1, 1) = "'" && SubStr(path, -1) = "'")
        path := Trim(SubStr(path, 2, StrLen(path) - 2))
    if !IsImageFilePath(path) || !FileExist(path)
        return ""
    try DirCreate STORE_DIR
    SplitPath path, , , &ext
    ext := StrLower(ext)
    if ext = ""
        ext := "png"
    uid := Integer(uid)
    name := (uid > 0 ? ("fimg_" uid) : ("fimg_" A_Now "_" Random(10000, 99999))) "." ext
    dest := STORE_DIR "\" name
    try {
        if FileExist(dest) {
            ClipLog("EnsureFileImageInStore exists " name)
            return name
        }
        ClipLog("EnsureFileImageInStore FileCopy →" name)
        ; Prefer CopyFileW; avoid AHK FileCopy hang on cloud/OneDrive Desktop
        ok := DllCall("CopyFileW", "WStr", path, "WStr", dest, "Int", 0)
        if !ok {
            ClipLog("EnsureFileImageInStore CopyFileW fail err=" A_LastError " fallback FileCopy")
            try FileCopy path, dest, 1
            catch as e {
                ClipLogErr("EnsureFileImageInStore FileCopy", e)
                return ""
            }
        }
        if FileExist(dest) {
            ClipLog("EnsureFileImageInStore OK " name " size=" FileGetSize(dest))
            return name
        }
        ClipLog("EnsureFileImageInStore missing after copy")
    } catch as e {
        ClipLogErr("EnsureFileImageInStore", e)
    }
    return ""
}

EnsureFileClipThumb(item) {
    global STORE_DIR, wvCore, panelVisible
    ; Soft path only  — never call GDI+ here (native hang/kill under disk jobs)
    if !IsObject(item) || item.type != "file"
        return
    ClipLog("EnsureFileClipThumb begin uid=" item.uid)
    if item.HasProp("imgFile") && item.imgFile != "" && FileExist(STORE_DIR "\" item.imgFile) {
        ClipLog("EnsureFileClipThumb already has " item.imgFile)
        return
    }
    raw := String(item.HasProp("data") ? item.data : "")
    if raw = "" && item.HasProp("preview")
        raw := String(item.preview)
    for ln in StrSplit(raw, "`n", "`r") {
        p := Trim(ln)
        if (SubStr(p, 1, 1) = '"' && SubStr(p, -1) = '"')
            || (SubStr(p, 1, 1) = "'" && SubStr(p, -1) = "'")
            p := Trim(SubStr(p, 2, StrLen(p) - 2))
        if !IsImageFilePath(p) || !FileExist(p)
            continue
        ClipLog("EnsureFileClipThumb copy " SubStr(p, 1, 120))
        name := ""
        try name := EnsureFileImageInStore(p, item.uid)
        catch as e {
            ClipLogErr("EnsureFileClipThumb store", e)
            return
        }
        if name = "" {
            ClipLog("EnsureFileClipThumb store empty —skip")
            return
        }
        item.imgFile := name
        ; Dimensions optional —GdipCreateBitmapFromFile hung/killed process; skip
        ClipLog("EnsureFileClipThumb done imgFile=" name " (no GDI+ dims)")
        break
    }
}

; AddClipItem 立刻异步补缩略图（不等 Persist 队列）
EnsureFileClipThumbAndInject(item) {
    global panelVisible, wvCore
    if !IsObject(item) || item.type != "file"
        return
    try EnsureFileClipThumb(item)
    catch as e {
        ClipLogErr("EnsureFileClipThumbAndInject", e)
        return
    }
    if !(item.HasProp("imgFile") && item.imgFile != "")
        return
    ApplyImgFileLocal(item.uid, item.imgFile)
    SetTimer(InjectStoreThumbNow.Bind(Integer(item.uid), String(item.imgFile)), -10)
    if panelVisible && IsObject(wvCore)
        SetTimer(() => RequestUiPush(), -40)
}

GetImageFileDimensions(path, &w := 0, &h := 0) {
    w := 0, h := 0
    if !FileExist(path)
        return false
    pToken := 0, pBitmap := 0
    try {
        si := Buffer(16, 0)
        NumPut("UInt", 1, si, 0)
        if DllCall("gdiplus\GdiplusStartup", "UPtr*", &pToken, "Ptr", si, "Ptr", 0)
            return false
        if DllCall("gdiplus\GdipCreateBitmapFromFile", "WStr", path, "Ptr*", &pBitmap) || !pBitmap
            return false
        DllCall("gdiplus\GdipGetImageWidth", "Ptr", pBitmap, "UInt*", &w)
        DllCall("gdiplus\GdipGetImageHeight", "Ptr", pBitmap, "UInt*", &h)
        return w > 0 && h > 0
    } catch {
        return false
    } finally {
        if pBitmap
            try DllCall("gdiplus\GdipDisposeImage", "Ptr", pBitmap)
        if pToken
            try DllCall("gdiplus\GdiplusShutdown", "Ptr", pToken)
    }
}

DeleteStoredImage(item) {
    global STORE_DIR, listThumbUrlCache
    if !IsObject(item) || !item.HasProp("imgFile") || item.imgFile = ""
        return
    path := STORE_DIR "\" item.imgFile
    try {
        if FileExist(path)
            FileDelete path
    }
    ; Remove list-thumb cache too
    try {
        if listThumbUrlCache.Has(String(item.imgFile))
            listThumbUrlCache.Delete(String(item.imgFile))
        base := RegExReplace(String(item.imgFile), "\.[^.]+$", "")
        th := STORE_DIR "\th_" base ".jpg"
        if FileExist(th)
            FileDelete th
    }
}

LoadImageFromStore(name) {
    global STORE_DIR
    if name = ""
        return ""
    path := STORE_DIR "\" name
    if !FileExist(path)
        return ""
    try {
        f := FileOpen(path, "r")
        if !IsObject(f)
            return ""
        buf := Buffer(f.Length)
        f.RawRead(buf)
        f.Close()
        SplitPath path, , , &ext
        ext := StrLower(ext)
        mime := "image/png"
        switch ext {
            case "jpg", "jpeg": mime := "image/jpeg"
            case "gif": mime := "image/gif"
            case "webp": mime := "image/webp"
            case "bmp": mime := "image/bmp"
            case "svg": mime := "image/svg+xml"
            case "ico": mime := "image/x-icon"
        }
        return "data:" mime ";base64," B64Encode(buf)
    } catch {
        return ""
    }
}

B64DecodeToFile(b64, path) {
    b64 := RegExReplace(b64, "\s+")
    needed := 0
    if !DllCall("crypt32\CryptStringToBinaryW",
        "WStr", b64, "UInt", 0, "UInt", 0x1, "Ptr", 0, "UInt*", &needed, "Ptr", 0, "Ptr", 0, "Int")
        return false
    buf := Buffer(needed)
    if !DllCall("crypt32\CryptStringToBinaryW",
        "WStr", b64, "UInt", 0, "UInt", 0x1, "Ptr", buf, "UInt*", &needed, "Ptr", 0, "Ptr", 0, "Int")
        return false
    f := FileOpen(path, "w")
    if !IsObject(f)
        return false
    f.RawWrite(buf)
    f.Close()
    return true
}

; 鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺?
; NDJSON page store (inlined —was ahk\clip_v1\ndjson_pages.ahk)
; each shard holds at most PAGE_SIZE records (newest pages first)
; 鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺?
; NDJSON page store: each shard file holds at most PAGE_SIZE records (newest pages first).
; Query/mutate only load one shard at a time —peak memory stays bounded.

ItemToJsonLine(c) {
    imgFile := c.HasProp("imgFile") ? c.imgFile : ""
    dataFile := c.HasProp("dataFile") ? c.dataFile : ""
    preview := c.HasProp("preview") ? c.preview : ""
    if c.type = "image" {
        preview := ""
        data := ""
        dataFile := ""
    } else if dataFile != "" {
        ; Large body lives in clips_payloads —keep NDJSON line small/reliable
        data := ""
    } else {
        data := c.data
    }
    uid := c.HasProp("uid") ? Integer(c.uid) : 0
    out := "{"
    out .= '"uid":' uid ","
    out .= '"type":"' c.type '",'
    out .= '"time":"' c.time '",'
    out .= '"pinned":' (c.pinned ? "true" : "false") ","
    out .= '"pinTime":' JsonStr(c.HasProp("pinTime") ? c.pinTime : "") ","
    out .= '"pasted":' ((c.HasProp("pasted") && c.pasted) ? "true" : "false") ","
    out .= '"queueGroup":' (c.HasProp("queueGroup") ? Integer(c.queueGroup) : 0) ","
    out .= '"queueIndex":' (c.HasProp("queueIndex") ? Integer(c.queueIndex) : 0) ","
    out .= '"charCount":' (c.HasProp("charCount") ? c.charCount : 0) ","
    out .= '"fileCount":' (c.HasProp("fileCount") ? c.fileCount : 0) ","
    out .= '"width":' (c.HasProp("width") ? c.width : 0) ","
    out .= '"height":' (c.HasProp("height") ? c.height : 0) ","
    out .= '"imgFile":' JsonStr(imgFile) ","
    out .= '"dataFile":' JsonStr(dataFile) ","
    out .= '"linkTitle":' JsonStr(c.HasProp("linkTitle") ? c.linkTitle : "") ","
    out .= '"linkHost":' JsonStr(c.HasProp("linkHost") ? c.linkHost : "") ","
    out .= '"favTitle":' JsonStr(c.HasProp("favTitle") ? c.favTitle : "") ","
    out .= '"favGroup":' JsonStr(c.HasProp("favGroup") ? c.favGroup : "") ","
    out .= '"srcIcon":' JsonStr(c.HasProp("srcIcon") ? c.srcIcon : "") ","
    out .= '"srcExe":' JsonStr(c.HasProp("srcExe") ? c.srcExe : "") ","
    out .= '"srcTitle":' JsonStr(c.HasProp("srcTitle") ? c.srcTitle : "") ","
    out .= '"isMd":' ((c.HasProp("isMd") && c.isMd) ? "true" : "false") ","
    out .= '"isRich":' ((c.HasProp("isRich") && c.isRich) ? "true" : "false") ","
    out .= '"preview":' JsonStr(preview) ","
    out .= '"data":' JsonStr(data)
    out .= "}"
    return out
}

JsonParse(text) {
    doc := ComObject("HTMLFile")
    doc.write("<meta http-equiv='X-UA-Compatible' content='IE=Edge'>")
    return doc.parentWindow.JSON.parse(text)
}

JsonArrayToAhk(arr) {
    result := []
    try n := Integer(arr.length)
    catch
        return result
    loop n {
        idx := A_Index - 1
        jo := ""
        try jo := arr[idx]
        catch {
            try jo := arr.%idx%
        }
        if !IsObject(jo)
            continue
        result.Push(jo)
    }
    return result
}

NextClipUid() {
    global clipUidSeq
    clipUidSeq += 1
    return clipUidSeq
}

ParseJoToItem(jo, &dirty := false, light := false) {
    global STORE_DIR, PAYLOAD_DIR, clipUidSeq
    item := {}
    try item.uid := Integer(jo.uid || 0)
    catch
        item.uid := 0
    if item.uid < 1 {
        item.uid := ++clipUidSeq
        dirty := true
    } else if item.uid > clipUidSeq {
        clipUidSeq := item.uid
    }
    item.type := String(jo.type)
    item.time := String(jo.time)
    item.pinned := (jo.pinned = true || jo.pinned = 1)
    try item.pinTime := String(jo.pinTime || "")
    catch
        item.pinTime := ""
    try
        item.pasted := (jo.pasted = true || jo.pasted = 1)
    catch
        item.pasted := false
    try item.queueGroup := Integer(jo.queueGroup || 0)
    catch
        item.queueGroup := 0
    try item.queueIndex := Integer(jo.queueIndex || 0)
    catch
        item.queueIndex := 0
    NoteQueueGroupFromItem(item)
    ApplyQueueMetaToItem(item)
    item.charCount := Integer(jo.charCount || 0)
    item.fileCount := Integer(jo.fileCount || 0)
    item.width := Integer(jo.width || 0)
    item.height := Integer(jo.height || 0)
    item.preview := String(jo.preview || "")
    item.imgFile := String(jo.imgFile || "")
    try item.dataFile := String(jo.dataFile || "")
    catch
        item.dataFile := ""
    try item.linkTitle := String(jo.linkTitle || "")
    catch
        item.linkTitle := ""
    try item.linkHost := String(jo.linkHost || "")
    catch
        item.linkHost := ""
    try item.favTitle := String(jo.favTitle || "")
    catch
        item.favTitle := ""
    try item.favGroup := String(jo.favGroup || "")
    catch
        item.favGroup := ""
    try item.srcIcon := String(jo.srcIcon || "")
    catch
        item.srcIcon := ""
    try item.srcExe := String(jo.srcExe || "")
    catch
        item.srcExe := ""
    try item.srcTitle := String(jo.srcTitle || "")
    catch
        item.srcTitle := ""
    try item.isMd := (jo.isMd = true || jo.isMd = 1)
    catch
        item.isMd := false
    try item.isRich := (jo.isRich = true || jo.isRich = 1)
    catch
        item.isRich := false
    if !item.isMd && (item.type = "text" || item.type = "link")
        item.isMd := TextLooksLikeMarkdown(item.preview != "" ? item.preview : String(jo.data || ""))
    if item.type = "image" {
        if item.imgFile = "" {
            raw := String(jo.data || "")
            if InStr(raw, "base64,") {
                item.imgFile := SaveImageToStore(raw)
                dirty := true
            }
        }
        if item.imgFile = "" || !FileExist(STORE_DIR "\" item.imgFile)
            return ""
        item.data := ""
    } else {
        if item.dataFile != "" {
            ; List/query path: keep preview only —full body loaded on paste/resolve
            if light {
                item.data := ""
            } else {
                p := PAYLOAD_DIR "\" item.dataFile
                if FileExist(p)
                    item.data := FileRead(p, "UTF-8")
                else
                    item.data := String(jo.data || "")
            }
        } else
            item.data := String(jo.data || "")
        if item.preview = "" && (item.type = "text" || item.type = "link")
            item.preview := SubStr(item.data, 1, 300)
    }
    if item.type = "link" && item.linkHost = ""
        item.linkHost := HostOfUrl(item.data)
    return item
}

ParseNdjsonLine(line, &dirty := false, light := false) {
    line := Trim(line, " `t`r`n")
    if line = "" || SubStr(line, 1, 1) != "{"
        return ""
    ; List/query path: regex extract  — avoid HTMLFile COM JSON (very slow per line)
    if light
        return ParseNdjsonLineFast(line)
    try
        return ParseJoToItem(JsonParse(line), &dirty, false)
    catch
        return ""
}

; Fast list-item parse from our own ItemToJsonLine format (no COM)
ParseNdjsonLineFast(line) {
    global clipUidSeq
    item := {}
    item.uid := JsonFieldInt(line, "uid")
    if item.uid < 1
        return ""
    if item.uid > clipUidSeq
        clipUidSeq := item.uid
    item.type := JsonFieldStr(line, "type")
    if item.type = ""
        return ""
    item.time := JsonFieldStr(line, "time")
    item.pinned := JsonFieldBool(line, "pinned")
    item.pinTime := JsonFieldStr(line, "pinTime")
    item.pasted := JsonFieldBool(line, "pasted")
    item.queueGroup := JsonFieldInt(line, "queueGroup")
    item.queueIndex := JsonFieldInt(line, "queueIndex")
    ApplyQueueMetaToItem(item)
    NoteQueueGroupFromItem(item)
    item.charCount := JsonFieldInt(line, "charCount")
    item.fileCount := JsonFieldInt(line, "fileCount")
    item.width := JsonFieldInt(line, "width")
    item.height := JsonFieldInt(line, "height")
    item.preview := JsonFieldStr(line, "preview")
    item.imgFile := JsonFieldStr(line, "imgFile")
    item.dataFile := JsonFieldStr(line, "dataFile")
    item.linkTitle := JsonFieldStr(line, "linkTitle")
    item.linkHost := JsonFieldStr(line, "linkHost")
    item.favTitle := JsonFieldStr(line, "favTitle")
    item.favGroup := JsonFieldStr(line, "favGroup")
    item.srcIcon := JsonFieldStr(line, "srcIcon")
    item.srcExe := JsonFieldStr(line, "srcExe")
    item.srcTitle := JsonFieldStr(line, "srcTitle")
    item.isMd := JsonFieldBool(line, "isMd")
    item.isRich := JsonFieldBool(line, "isRich")
    if item.type = "image" {
        item.data := ""
        ; 无缩略图时仍保留条目（尤其是已收藏），避免收藏页读盘被丢弃
        if item.imgFile = "" && !(item.HasProp("pinned") && item.pinned)
            return ""
    } else if item.dataFile != "" {
        ; Large body on disk —load only when pasting
        item.data := ""
        if item.type = "file"
            item._looksImage := PreviewLooksLikeImagePath(item.preview)
        if !item.isMd && (item.type = "text" || item.type = "link")
            item.isMd := TextLooksLikeMarkdown(item.preview)
    } else {
        ; Inline body (small) kept in memory for instant paste
        item.data := JsonFieldStr(line, "data")
        if item.preview = "" && (item.type = "text" || item.type = "link" || item.type = "file")
            item.preview := SubStr(item.data, 1, 500)
        if !item.isMd && (item.type = "text" || item.type = "link")
            item.isMd := TextLooksLikeMarkdown(item.preview != "" ? item.preview : item.data)
        if item.type = "file"
            item._looksImage := PreviewLooksLikeImagePath(item.preview != "" ? item.preview : item.data)
    }
    return item
}

PreviewLooksLikeImagePath(raw) {
    static imgExt := " png jpg jpeg gif webp bmp ico tif tiff svg "
    raw := Trim(String(raw))
    if raw = ""
        return false
    ; Only check first path line —enough for list bucketing
    ln := Trim(StrSplit(raw, "`n", "`r")[1])
    if (SubStr(ln, 1, 1) = '"' && SubStr(ln, -1) = '"')
        || (SubStr(ln, 1, 1) = "'" && SubStr(ln, -1) = "'")
        ln := Trim(SubStr(ln, 2, StrLen(ln) - 2))
    SplitPath ln, , , &ext
    ext := StrLower(ext)
    return ext != "" && InStr(imgExt, " " ext " ")
}

JsonFieldInt(line, key) {
    if RegExMatch(line, '"' key '"\s*:\s*(-?\d+)', &m)
        return Integer(m[1])
    return 0
}
JsonFieldBool(line, key) {
    if RegExMatch(line, '"' key '"\s*:\s*(true|false|1|0)', &m)
        return (m[1] = "true" || m[1] = "1")
    return false
}
JsonFieldStr(line, key) {
    if !RegExMatch(line, '"' key '"\s*:\s*"((?:\\.|[^"\\])*)"', &m)
        return ""
    s := m[1]
    out := ""
    i := 1
    len := StrLen(s)
    while i <= len {
        ch := SubStr(s, i, 1)
        if ch = "\" && i < len {
            n := SubStr(s, i + 1, 1)
            switch n {
                case "n": out .= "`n"
                case "r": out .= "`r"
                case "t": out .= "`t"
                case '"': out .= '"'
                case "\": out .= "\"
                case "/": out .= "/"
                default: out .= n
            }
            i += 2
        } else {
            out .= ch
            i += 1
        }
    }
    return out
}

EnsurePagesDir() {
    global PAGES_DIR
    try DirCreate PAGES_DIR
}

LoadManifest() {
    global MANIFEST_FILE, clipUidSeq
    EnsurePagesDir()
    m := Map("uidSeq", clipUidSeq, "nextPage", 1, "pages", [])
    if !FileExist(MANIFEST_FILE)
        return RepairManifestPages(m)
    try {
        raw := FileRead(MANIFEST_FILE, "UTF-8")
        if RegExMatch(raw, '"uidSeq"\s*:\s*(\d+)', &mm)
            m["uidSeq"] := Integer(mm[1])
        if RegExMatch(raw, '"nextPage"\s*:\s*(\d+)', &mm)
            m["nextPage"] := Integer(mm[1])
        ; Do NOT use HTMLFile JSON array parse —it often returns incomplete pages and
        ; the next SaveManifest then orphans older shards.
        pages := []
        if RegExMatch(raw, '"pages"\s*:\s*\[([\s\S]*?)\]', &pm) {
            pos := 1
            while RegExMatch(pm[1], '"([^"]+)"', &qm, pos) {
                pages.Push(qm[1])
                pos := qm.Pos + qm.Len
            }
        }
        m["pages"] := pages
        if Integer(m["uidSeq"]) > clipUidSeq
            clipUidSeq := Integer(m["uidSeq"])
    } catch {
    }
    ; 读盘时也修补：双实例/异常写入可能导致 pages 被截断，读时必须找回 orphan shard
    return RepairManifestPages(m)
}

; Re-attach orphaned p_*.ndjson files dropped by a bad manifest rewrite
RepairManifestPages(m) {
    global PAGES_DIR
    EnsurePagesDir()
    onDisk := []
    loop files PAGES_DIR "\p_*.ndjson" {
        num := 0
        if RegExMatch(A_LoopFileName, "i)p_(\d+)\.ndjson", &nm)
            num := Integer(nm[1])
        onDisk.Push({ name: A_LoopFileName, num: num, t: String(A_LoopFileTimeModified) })
    }
    if onDisk.Length = 0 {
        m["pages"] := []
        return m
    }
    ; newest modified first; tie-break by higher page number (numeric)
    loop onDisk.Length - 1 {
        loop onDisk.Length - A_Index {
            j := A_Index
            a := onDisk[j]
            b := onDisk[j + 1]
            swap := false
            if a.t < b.t
                swap := true
            else if a.t = b.t && a.num < b.num
                swap := true
            if swap {
                onDisk[j] := b
                onDisk[j + 1] := a
            }
        }
    }
    known := Map()
    valid := 0
    for name in (m.Has("pages") ? m["pages"] : []) {
        if FileExist(PagePath(name))
            valid += 1, known[name] := true
    }
    ; Rebuild from disk when manifest missing files
    if valid != onDisk.Length {
        pages := []
        for f in onDisk
            pages.Push(f.name)
        m["pages"] := pages
    } else {
        pages := []
        seen := Map()
        for name in m["pages"] {
            if !FileExist(PagePath(name)) || seen.Has(name)
                continue
            seen[name] := true
            pages.Push(name)
        }
        m["pages"] := pages
    }
    maxN := Integer(m["nextPage"])
    for name in m["pages"] {
        if RegExMatch(name, "i)p_(\d+)\.ndjson", &nm) {
            n := Integer(nm[1]) + 1
            if n > maxN
                maxN := n
        }
    }
    m["nextPage"] := maxN
    return m
}

SaveManifest(m) {
    global MANIFEST_FILE
    EnsurePagesDir()
    ; Always re-attach orphan shards before writing  — never shrink pages to one new file
    m := RepairManifestPages(m)
    pages := m.Has("pages") ? m["pages"] : []
    ; de-dupe while preserving order
    seen := Map()
    clean := []
    for p in pages {
        p := String(p)
        if p = "" || seen.Has(p)
            continue
        if !FileExist(PagePath(p))
            continue
        seen[p] := true
        clean.Push(p)
    }
    pages := clean
    m["pages"] := pages
    out := "{"
    out .= '"uidSeq":' Integer(m.Has("uidSeq") ? m["uidSeq"] : 0) ","
    out .= '"nextPage":' Integer(m.Has("nextPage") ? m["nextPage"] : 1) ","
    out .= '"pages":['
    for i, p in pages {
        if i > 1
            out .= ","
        out .= JsonStr(p)
    }
    out .= "]}"
    AtomicWriteText(MANIFEST_FILE, out)
}

; Write via tmp + MoveFileEx(REPLACE)  — never delete the live file first (crash = data loss)
AtomicWriteText(path, text) {
    tmp := path ".tmp"
    try {
        if FileExist(tmp)
            FileDelete tmp
        FileAppend text, tmp, "UTF-8"
        if !FileExist(tmp)
            return false
        ; MOVEFILE_REPLACE_EXISTING = 1
        if DllCall("MoveFileExW", "WStr", tmp, "WStr", path, "UInt", 1) {
            return true
        }
        ; Fallback: keep original if replace fails
        try FileDelete tmp
    } catch {
    }
    return false
}

PagePath(name) {
    global PAGES_DIR
    return PAGES_DIR "\" name
}

ReadPageFile(name, light := false) {
    result := []
    if name = ""
        return result
    path := PagePath(name)
    if !FileExist(path)
        return result
    try {
        dirty := false
        loop read path, "UTF-8" {
            item := ParseNdjsonLine(A_LoopReadLine, &dirty, light)
            if IsObject(item)
                result.Push(item)
        }
        ; Do NOT auto-rewrite on dirty/partial parse —that wiped shards when any line failed
    } catch {
    }
    return result
}

WritePageFile(name, items) {
    path := PagePath(name)
    EnsurePagesDir()
    text := ""
    for c in items
        text .= ItemToJsonLine(c) "`n"
    AtomicWriteText(path, text)
}

; Count non-empty lines without JSON-parsing (rewrite must not drop unparsable history)
CountPageLines(name) {
    n := 0
    path := PagePath(name)
    if name = "" || !FileExist(path)
        return 0
    try {
        loop read path, "UTF-8" {
            if Trim(A_LoopReadLine, " `t`r`n") != ""
                n += 1
        }
    } catch {
    }
    return n
}

; Prepend one NDJSON line without re-parsing the shard (avoids silent data loss)
PrependPageLine(name, line) {
    path := PagePath(name)
    EnsurePagesDir()
    tmp := path ".tmp"
    try {
        if FileExist(tmp)
            FileDelete tmp
        line := String(line)
        if SubStr(line, -1) != "`n"
            line .= "`n"
        existing := ""
        if FileExist(path)
            existing := FileRead(path, "UTF-8")
        FileAppend line existing, tmp, "UTF-8"
        if !FileExist(tmp)
            return false
        if DllCall("MoveFileExW", "WStr", tmp, "WStr", path, "UInt", 1)
            return true
        try FileDelete tmp
    } catch {
        try {
            if FileExist(tmp)
                FileDelete tmp
        }
    }
    return false
}

NewPageName(m) {
    n := Integer(m["nextPage"])
    m["nextPage"] := n + 1
    return Format("p_{:06}.ndjson", n)
}

DiskInsertFront(item) {
    global PAGE_SIZE, clipUidSeq
    ; No Critical here —disk jobs are already serialized by DrainDiskJobs.
    ; Critical blocked OnClipboardChange and made copies "appear one behind".
    try {
        ClipLog("DiskInsertFront begin uid=" (item.HasProp("uid") ? item.uid : 0))
        ; Strip non-serializable / huge clipboard blobs before touching disk
        try item.DeleteProp("clipAll")
        m := LoadManifest()
        m := RepairManifestPages(m)
        pages := m["pages"]
        ClipLog("DiskInsertFront pages=" pages.Length " next=" m["nextPage"])
        if !item.HasProp("uid") || !item.uid
            item.uid := NextClipUid()
        if item.uid > clipUidSeq
            clipUidSeq := item.uid
        m["uidSeq"] := Max(Integer(m["uidSeq"]), clipUidSeq)

        firstCount := pages.Length ? CountPageLines(pages[1]) : 0
        ClipLog("DiskInsertFront firstCount=" firstCount " page0=" (pages.Length ? pages[1] : ""))
        if pages.Length = 0 || firstCount >= PAGE_SIZE {
            name := NewPageName(m)
            ClipLog("DiskInsertFront newPage=" name)
            WritePageFile(name, [item])
            pages.InsertAt(1, name)
            m["pages"] := pages
            SaveManifest(m)
            ClipLog("DiskInsertFront saved newPage")
            return true
        }
        ; Prepend raw line  — never parse+rewrite (one bad line used to wipe the whole shard)
        ClipLog("DiskInsertFront PrependPageLine " pages[1])
        if PrependPageLine(pages[1], ItemToJsonLine(item)) {
            m["pages"] := pages
            SaveManifest(m)
            ClipLog("DiskInsertFront prepend OK")
            return true
        }
        ; Prepend failed: new shard only —keep existing pages intact
        name := NewPageName(m)
        ClipLog("DiskInsertFront prepend FAIL →newPage=" name)
        WritePageFile(name, [item])
        pages.InsertAt(1, name)
        m["pages"] := pages
        SaveManifest(m)
        ClipLog("DiskInsertFront saved fallback page")
        return true
    } catch as e {
        ClipLogErr("DiskInsertFront", e)
        return false
    }
}

DiskRemoveUid(uid) {
    uid := Integer(uid)
    m := LoadManifest()
    pages := m["pages"]
    removed := ""
    newPages := []
    n := 0
    for name in pages {
        if IsObject(removed) {
            newPages.Push(name)
            continue
        }
        ; light 足够定位 uid / imgFile / dataFile，避免删一条扫全文
        items := ReadPageFile(name, true)
        kept := []
        changed := false
        for c in items {
            if c.uid = uid {
                removed := c
                changed := true
            } else
                kept.Push(c)
            if Mod(++n, 64) = 0
                Sleep(-1)
        }
        if !changed {
            newPages.Push(name)
            continue
        }
        if kept.Length {
            WritePageFile(name, kept)
            newPages.Push(name)
        } else {
            try FileDelete PagePath(name)
        }
    }
    if IsObject(removed) {
        m["pages"] := newPages
        SaveManifest(m)
    }
    return removed
}

; Remove text-equal rows (prefer keep pinned meta). Must stay fast — full-page
; heavy reads used to block the AHK thread ~30s → busy cursor + dead ^+c.
DiskRemoveTextEqual(text) {
    global PAYLOAD_DIR
    text := String(text)
    textLen := StrLen(text)
    if textLen < 1
        return ""
    m := LoadManifest()
    pages := m["pages"]
    newPages := []
    changedAny := false
    best := ""
    ; Newest shards first; scanning all 100+ pages with full payload freezes UI
    maxScan := Min(pages.Length, 24)
    i := 1
    while i <= pages.Length {
        name := pages[i]
        if i > maxScan {
            newPages.Push(name)
            i += 1
            continue
        }
        light := ReadPageFile(name, true)
        kill := Map()
        for c in light {
            if !(IsObject(c) && c.type = "text")
                continue
            cc := (c.HasProp("charCount") ? Integer(c.charCount) : -1)
            if cc >= 0 && cc != textLen
                continue
            body := ""
            full := ""
            if c.HasProp("data") && c.data != ""
                body := String(c.data)
            else if c.HasProp("dataFile") && c.dataFile != "" {
                try body := FileRead(PAYLOAD_DIR "\" c.dataFile, "UTF-8")
            } else {
                full := DiskLoadUid(c.uid)
                if IsObject(full) && full.HasProp("data")
                    body := String(full.data)
            }
            if body = "" || body != text
                continue
            kill[Integer(c.uid)] := true
            cand := IsObject(full) ? full : c
            if !IsObject(best) || (cand.HasProp("pinned") && cand.pinned && !(best.HasProp("pinned") && best.pinned))
                best := cand
        }
        if kill.Count < 1 {
            newPages.Push(name)
            i += 1
            Sleep 0
            continue
        }
        ; Rewrite from light rows (dataFile / inline data preserved by fast parse)
        kept := []
        for c in light {
            uid := Integer(c.uid)
            if kill.Has(uid) {
                DeletePayloadFile(c)
                changedAny := true
            } else
                kept.Push(c)
        }
        if kept.Length {
            WritePageFile(name, kept)
            newPages.Push(name)
        } else {
            try FileDelete PagePath(name)
        }
        i += 1
        Sleep 0  ; yield so hotkeys / ^+c are not starved
    }
    if changedAny {
        m["pages"] := newPages
        SaveManifest(m)
    }
    return best
}

; 文件条目比较键：路径规范化（大小写/斜杠），多文件按行拼接
FileClipKey(data) {
    raw := String(data)
    if raw = ""
        return ""
    lines := []
    for ln in StrSplit(raw, "`n", "`r") {
        p := Trim(ln)
        if p = ""
            continue
        p := StrReplace(p, "/", "\")
        while InStr(p, "\\")
            p := StrReplace(p, "\\", "\")
        lines.Push(StrLower(p))
    }
    if lines.Length = 0
        return ""
    out := ""
    for i, p in lines
        out .= (i > 1 ? "`n" : "") p
    return out
}

FileClipDataEqual(a, b) {
    ka := FileClipKey(a)
    if ka = ""
        return false
    return ka = FileClipKey(b)
}

; 同路径文件去重（内存）；优先保留已收藏条目的元数据
MemoryTakeFileEqual(data) {
    global clips, viewTotal, viewCache, liveFront
    key := FileClipKey(data)
    if key = ""
        return ""
    best := ""
    matches := []
    for c in clips {
        if IsObject(c) && c.type = "file" && FileClipKey(c.HasProp("data") ? c.data : "") = key
            matches.Push(c)
    }
    for c in matches {
        if !IsObject(best) || (c.HasProp("pinned") && c.pinned && !(best.HasProp("pinned") && best.pinned))
            best := c
        MemoryRemoveUid(c.uid)
    }
    if IsObject(viewCache) {
        for cacheKey, entry in viewCache {
            if !IsObject(entry) || !entry.HasProp("items")
                continue
            i := 1
            while i <= entry.items.Length {
                c := entry.items[i]
                if IsObject(c) && c.type = "file" && FileClipKey(c.HasProp("data") ? c.data : "") = key {
                    if !IsObject(best) || (c.HasProp("pinned") && c.pinned && !(best.HasProp("pinned") && best.pinned))
                        best := c
                    entry.items.RemoveAt(i)
                    entry.total := Max(0, entry.total - 1)
                } else
                    i += 1
            }
        }
    }
    if IsObject(liveFront) {
        i := 1
        while i <= liveFront.Length {
            c := liveFront[i]
            if IsObject(c) && c.type = "file" && FileClipKey(c.HasProp("data") ? c.data : "") = key {
                if !IsObject(best) || (c.HasProp("pinned") && c.pinned && !(best.HasProp("pinned") && best.pinned))
                    best := c
                liveFront.RemoveAt(i)
            } else
                i += 1
        }
    }
    return best
}

DiskRemoveFileEqual(data) {
    global PAYLOAD_DIR
    key := FileClipKey(data)
    if key = ""
        return ""
    m := LoadManifest()
    pages := m["pages"]
    newPages := []
    changedAny := false
    best := ""
    maxScan := Min(pages.Length, 24)
    i := 1
    while i <= pages.Length {
        name := pages[i]
        if i > maxScan {
            newPages.Push(name)
            i += 1
            continue
        }
        light := ReadPageFile(name, true)
        kill := Map()
        for c in light {
            if !(IsObject(c) && c.type = "file")
                continue
            body := ""
            if c.HasProp("data") && c.data != ""
                body := String(c.data)
            else if c.HasProp("preview") && c.preview != ""
                body := String(c.preview)
            else if c.HasProp("dataFile") && c.dataFile != "" {
                try body := FileRead(PAYLOAD_DIR "\" c.dataFile, "UTF-8")
            }
            if body = "" || FileClipKey(body) != key
                continue
            kill[Integer(c.uid)] := true
            if !IsObject(best) || (c.HasProp("pinned") && c.pinned && !(best.HasProp("pinned") && best.pinned))
                best := c
        }
        if kill.Count < 1 {
            newPages.Push(name)
            i += 1
            Sleep 0
            continue
        }
        kept := []
        for c in light {
            uid := Integer(c.uid)
            if kill.Has(uid) {
                DeletePayloadFile(c)
                changedAny := true
            } else
                kept.Push(c)
        }
        if kept.Length {
            WritePageFile(name, kept)
            newPages.Push(name)
        } else {
            try FileDelete PagePath(name)
        }
        i += 1
        Sleep 0
    }
    if changedAny {
        m["pages"] := newPages
        SaveManifest(m)
    }
    return best
}

DiskTakeLinkEqual(url) {
    m := LoadManifest()
    pages := m["pages"]
    taken := ""
    newPages := []
    for name in pages {
        if IsObject(taken) {
            newPages.Push(name)
            continue
        }
        items := ReadPageFile(name)
        kept := []
        changed := false
        for c in items {
            if c.type = "link" && c.data = url {
                taken := c
                changed := true
            } else
                kept.Push(c)
        }
        if !changed {
            newPages.Push(name)
            continue
        }
        if kept.Length {
            WritePageFile(name, kept)
            newPages.Push(name)
        } else {
            try FileDelete PagePath(name)
        }
    }
    if IsObject(taken) {
        m["pages"] := newPages
        SaveManifest(m)
    }
    return taken
}

DiskSetLinkTitle(url, title) {
    m := LoadManifest()
    for name in m["pages"] {
        items := ReadPageFile(name)
        changed := false
        for c in items {
            if c.type = "link" && c.data = url {
                c.linkTitle := title
                changed := true
                break
            }
        }
        if changed {
            WritePageFile(name, items)
            return true
        }
    }
    return false
}

DiskSetPinned(uid, pinned, pinTime := "") {
    ; Patch NDJSON line in place  — avoid full parse/rewrite (async race broke 收藏)
    uid := Integer(uid)
    pinned := !!pinned
    flag := pinned ? "true" : "false"
    if pinned {
        if pinTime = ""
            pinTime := FormatTime(, "yyyy-MM-dd HH:mm:ss")
    } else
        pinTime := ""
    pinJson := JsonStr(pinTime)
    m := LoadManifest()
    for name in m["pages"] {
        path := PagePath(name)
        if !FileExist(path)
            continue
        newText := ""
        changed := false
        found := false
        try {
            loop read path, "UTF-8" {
                line := A_LoopReadLine
                if !found && JsonFieldInt(line, "uid") = uid {
                    found := true
                    nl := line
                    if RegExMatch(nl, '"pinned"\s*:')
                        nl := RegExReplace(nl, '"pinned"\s*:\s*(true|false|1|0)', '"pinned":' flag, &_cnt, 1)
                    else
                        nl := RegExReplace(nl, "\}$", ',"pinned":' flag "}")
                    if RegExMatch(nl, '"pinTime"\s*:')
                        nl := RegExReplace(nl, '"pinTime"\s*:\s*"(?:\\.|[^"\\])*"', '"pinTime":' pinJson, &_cnt, 1)
                    else
                        nl := RegExReplace(nl, '"pinned"\s*:\s*(true|false|1|0)', '"pinned":' flag ',"pinTime":' pinJson, &_cnt, 1)
                    if nl != line {
                        line := nl
                        changed := true
                    }
                }
                newText .= line "`n"
            }
        } catch {
            continue
        }
        if changed {
            tmp := path ".tmp"
            try {
                if FileExist(tmp)
                    FileDelete tmp
                FileAppend newText, tmp, "UTF-8"
                if FileExist(path)
                    FileDelete path
                FileMove tmp, path
            } catch {
            }
            return true
        }
        if found
            return true
    }
    return false
}

DiskSetFavTitle(uid, title := "") {
    uid := Integer(uid)
    titleJson := JsonStr(Trim(String(title)))
    m := LoadManifest()
    for name in m["pages"] {
        path := PagePath(name)
        if !FileExist(path)
            continue
        newText := ""
        changed := false
        found := false
        try {
            loop read path, "UTF-8" {
                line := A_LoopReadLine
                if !found && JsonFieldInt(line, "uid") = uid {
                    found := true
                    nl := line
                    if RegExMatch(nl, '"favTitle"\s*:')
                        nl := RegExReplace(nl, '"favTitle"\s*:\s*"(?:\\.|[^"\\])*"', '"favTitle":' titleJson, &_cnt, 1)
                    else
                        nl := RegExReplace(nl, "\}$", ',"favTitle":' titleJson "}")
                    if nl != line {
                        line := nl
                        changed := true
                    }
                }
                newText .= line "`n"
            }
        } catch {
            continue
        }
        if changed {
            tmp := path ".tmp"
            try {
                if FileExist(tmp)
                    FileDelete tmp
                FileAppend newText, tmp, "UTF-8"
                if FileExist(path)
                    FileDelete path
                FileMove tmp, path
            } catch {
            }
            return true
        }
        if found
            return true
    }
    return false
}

DiskSetFavGroup(uid, gid := "") {
    uid := Integer(uid)
    gidJson := JsonStr(Trim(String(gid)))
    m := LoadManifest()
    for name in m["pages"] {
        path := PagePath(name)
        if !FileExist(path)
            continue
        newText := ""
        changed := false
        found := false
        try {
            loop read path, "UTF-8" {
                line := A_LoopReadLine
                if !found && JsonFieldInt(line, "uid") = uid {
                    found := true
                    nl := line
                    if RegExMatch(nl, '"favGroup"\s*:')
                        nl := RegExReplace(nl, '"favGroup"\s*:\s*"(?:\\.|[^"\\])*"', '"favGroup":' gidJson, &_cnt, 1)
                    else
                        nl := RegExReplace(nl, "\}$", ',"favGroup":' gidJson "}")
                    if nl != line {
                        line := nl
                        changed := true
                    }
                }
                newText .= line "`n"
            }
        } catch {
            continue
        }
        if changed {
            tmp := path ".tmp"
            try {
                if FileExist(tmp)
                    FileDelete tmp
                FileAppend newText, tmp, "UTF-8"
                if FileExist(path)
                    FileDelete path
                FileMove tmp, path
            } catch {
            }
            return true
        }
        if found
            return true
    }
    return false
}

; Favorites sort key: pinTime (when favorited), else create time
ClipPinSortKey(c) {
    if !IsObject(c)
        return ""
    if c.HasProp("pinTime") && c.pinTime != ""
        return String(c.pinTime)
    return c.HasProp("time") ? String(c.time) : ""
}

SortPinnedClipsDesc(arr) {
    ; Newest favorite first (pinTime / time descending)
    n := arr.Length
    i := 2
    while i <= n {
        key := arr[i]
        keySort := ClipPinSortKey(key)
        j := i - 1
        while j >= 1 && StrCompare(ClipPinSortKey(arr[j]), keySort) < 0 {
            arr[j + 1] := arr[j]
            j -= 1
        }
        arr[j + 1] := key
        i += 1
    }
}

DiskSetPasted(wantMap, pasted) {
    ; Patch NDJSON lines in place —do NOT full-parse / load payloads (that froze paste)
    m := LoadManifest()
    changedAny := false
    left := wantMap.Count
    flag := pasted ? "true" : "false"
    for name in m["pages"] {
        if left < 1
            break
        path := PagePath(name)
        if !FileExist(path)
            continue
        newText := ""
        changed := false
        try {
            loop read path, "UTF-8" {
                line := A_LoopReadLine
                if left > 0 {
                    uid := JsonFieldInt(line, "uid")
                    if uid > 0 && wantMap.Has(uid) {
                        if RegExMatch(line, '"pasted"\s*:')
                            nl := RegExReplace(line, '"pasted"\s*:\s*(true|false|1|0)', '"pasted":' flag, &_cnt, 1)
                        else
                            nl := RegExReplace(line, "\}$", ',"pasted":' flag "}")
                        if nl != line {
                            line := nl
                            changed := true
                            changedAny := true
                        }
                        left -= 1
                    }
                }
                newText .= line "`n"
            }
        } catch {
            continue
        }
        if changed {
            tmp := path ".tmp"
            try {
                if FileExist(tmp)
                    FileDelete tmp
                FileAppend newText, tmp, "UTF-8"
                if FileExist(path)
                    FileDelete path
                FileMove tmp, path
            } catch {
            }
        }
    }
    return changedAny
}

; Persist queueGroup/queueIndex onto NDJSON so UI lines survive script restart
DiskSetQueueMeta(uid, queueGroup, queueIndex) {
    uid := Integer(uid)
    queueGroup := Integer(queueGroup)
    queueIndex := Integer(queueIndex)
    if uid < 1
        return false
    m := LoadManifest()
    for name in m["pages"] {
        path := PagePath(name)
        if !FileExist(path)
            continue
        newText := ""
        changed := false
        try {
            loop read path, "UTF-8" {
                line := A_LoopReadLine
                lineUid := JsonFieldInt(line, "uid")
                if lineUid = uid {
                    nl := line
                    if RegExMatch(nl, '"queueGroup"\s*:')
                        nl := RegExReplace(nl, '"queueGroup"\s*:\s*-?\d+', '"queueGroup":' queueGroup, &_c1, 1)
                    else
                        nl := RegExReplace(nl, "\}$", ',"queueGroup":' queueGroup "}")
                    if RegExMatch(nl, '"queueIndex"\s*:')
                        nl := RegExReplace(nl, '"queueIndex"\s*:\s*-?\d+', '"queueIndex":' queueIndex, &_c2, 1)
                    else
                        nl := RegExReplace(nl, "\}$", ',"queueIndex":' queueIndex "}")
                    if nl != line {
                        line := nl
                        changed := true
                    }
                }
                newText .= line "`n"
            }
        } catch {
            continue
        }
        if changed {
            tmp := path ".tmp"
            try {
                if FileExist(tmp)
                    FileDelete tmp
                FileAppend newText, tmp, "UTF-8"
                if FileExist(path)
                    FileDelete path
                FileMove tmp, path
                return true
            } catch {
            }
        }
    }
    return false
}

DiskClearTab(tab, clearAllDates, today) {
    InvalidateViewCache()
    m := LoadManifest()
    newPages := []
    n := 0
    for name in m["pages"] {
        ; light=true：不要加载全文 payload，否则清空会卡死
        items := ReadPageFile(name, true)
        kept := []
        for c in items {
            drop := ItemShouldClear(c, tab, clearAllDates, today)
            if drop {
                try DeleteStoredImage(c)
                try DeletePayloadFile(c)
            } else
                kept.Push(c)
            if Mod(++n, 40) = 0
                Sleep(-1)
        }
        if kept.Length {
            WritePageFile(name, kept)
            newPages.Push(name)
        } else {
            try FileDelete PagePath(name)
        }
    }
    m["pages"] := newPages
    SaveManifest(m)
}

FileClipLooksLikeImage(c) {
    if !IsObject(c)
        return false
    if c.HasProp("_looksImage")
        return !!c._looksImage
    ; Thumb created from an image path
    if c.HasProp("imgFile") && c.imgFile != "" {
        n := StrLower(String(c.imgFile))
        if InStr(n, "fimg_") = 1 || RegExMatch(n, "i)\.(png|jpe?g|gif|webp|bmp|ico|tiff?|svg)$")
            return true
    }
    raw := ""
    if c.HasProp("data")
        raw := String(c.data)
    if raw = "" && c.HasProp("preview")
        raw := String(c.preview)
    return PreviewLooksLikeImagePath(raw)
}

; Tab / today filter only (no search query)
ItemMatchesTabToday(c, tab, todayOnly) {
    if !IsObject(c)
        return false
    type := StrLower(String(c.type))
    tab := StrLower(Trim(String(tab)))
    if todayOnly {
        t := c.HasProp("time") ? String(c.time) : ""
        if SubStr(t, 1, 10) != FormatTime(, "yyyy-MM-dd")
            return false
    }
    switch tab {
        case "text", "link":
            if type != tab
                return false
        case "image":
            if type = "image" {
            } else if type = "file" && FileClipLooksLikeImage(c) {
            } else
                return false
        case "file":
            if type != "file"
                return false
        case "recent":
            if type != "recent"
                return false
        case "pinned":
            if !(c.HasProp("pinned") && c.pinned)
                return false
        default:
            if type = "link" || type = "recent"
                return false
    }
    return true
}

; Lowercased hay for list search (preview / title fields only)
ClipSearchHay(c) {
    if !IsObject(c)
        return ""
    type := StrLower(String(c.type))
    favTitle := c.HasProp("favTitle") ? String(c.favTitle) : ""
    if type = "image"
        return StrLower(favTitle)
    if type = "file" {
        return StrLower(String(c.HasProp("preview") ? c.preview : "") " "
            . String(c.HasProp("data") ? c.data : "") " " favTitle)
    }
    prev := c.HasProp("preview") ? String(c.preview) : ""
    dataSample := ""
    if c.HasProp("data") && c.data != ""
        dataSample := SubStr(String(c.data), 1, 500)
    if prev = "" && dataSample != ""
        prev := dataSample
    hay := StrLower(prev " "
        . String(c.HasProp("linkTitle") ? c.linkTitle : "") " " favTitle)
    if dataSample != "" && dataSample != prev
        hay .= " " StrLower(dataSample)
    return hay
}

; a|b = AND segments; within each segment, space-separated words are AND (not one contiguous phrase)
QueryMatchText(hay, favTitle, type, q) {
    q := Trim(String(q))
    if q = ""
        return true
    favTitle := String(favTitle)
    favLower := StrLower(favTitle)
    hay := StrLower(String(hay))
    if type = "image"
        hay := favLower
    matchedAny := false
    for part in StrSplit(q, "|") {
        seg := Trim(part)
        if seg = ""
            continue
        segAny := false
        for term in StrSplit(seg, A_Space A_Tab) {
            term := Trim(term)
            if term = ""
                continue
            segAny := true
            matchedAny := true
            tLower := StrLower(term)
            if type = "image" {
                if favTitle = "" || !InStr(favLower, tLower)
                    return false
            } else if !InStr(hay, tLower)
                return false
        }
        if !segAny {
            matchedAny := true
            tLower := StrLower(seg)
            if type = "image" {
                if favTitle = "" || !InStr(favLower, tLower)
                    return false
            } else if !InStr(hay, tLower)
                return false
        }
    }
    return matchedAny
}

; Union expand only helps multi-word queries (words split across merged rows)
QueryNeedsFavGroupUnion(q) {
    q := Trim(String(q))
    if q = ""
        return false
    for part in StrSplit(q, "|") {
        seg := Trim(part)
        if InStr(seg, " ") || InStr(seg, A_Tab)
            return true
    }
    return false
}

ItemMatchesView(c, tab, query, todayOnly) {
    if !ItemMatchesTabToday(c, tab, todayOnly)
        return false
    q := Trim(String(query))
    if q = ""
        return true
    type := StrLower(String(c.type))
    favTitle := c.HasProp("favTitle") ? String(c.favTitle) : ""
    return QueryMatchText(ClipSearchHay(c), favTitle, type, q)
}

; Stream shards: never hold more than one page file + result window in memory
CountDiskMatches(tab, query, todayOnly) {
    total := 0
    n := 0
    m := LoadManifest()
    for name in m["pages"] {
        path := PagePath(name)
        if !FileExist(path)
            continue
        try {
            loop read path, "UTF-8" {
                c := ParseNdjsonLineFast(A_LoopReadLine)
                if !IsObject(c)
                    continue
                if ItemMatchesView(c, tab, query, todayOnly)
                    total += 1
                if Mod(++n, 120) = 0
                    Sleep(-1)
            }
        } catch {
        }
    }
    return total
}

QueryDiskPage(tab, query, todayOnly, offset, limit) {
    global tabTotals, VIEW_PAGE_SIZE, FIRST_PAINT_SIZE
    tab := StrLower(Trim(String(tab)))
    if tab = "recent"
        return QueryRecentFoldersPage(query, todayOnly, offset, limit)
    if tab = "pinned"
        return QueryPinnedDiskPage(query, todayOnly, offset, limit)
    q := Trim(String(query))
    n := 0
    if q != "" {
        pool := EnsureSearchPool(tab, todayOnly)
        all := SearchPoolQuery(pool, tab, q, todayOnly)
        items := []
        i := Integer(offset) + 1
        while i <= all.Length && items.Length < limit {
            items.Push(all[i])
            i += 1
        }
        return { items: items, total: all.Length }
    }
    items := []
    total := 0
    key := ViewCacheKey(tab, "", todayOnly)
    knownTotal := -1
    if IsObject(tabTotals) && tabTotals.Has(key)
        knownTotal := Integer(tabTotals[key])
    limit := Integer(limit)
    if limit < 1
        limit := Integer(VIEW_PAGE_SIZE)
    offset := Integer(offset)
    m := LoadManifest()
    t0 := A_TickCount
    for name in m["pages"] {
        path := PagePath(name)
        if !FileExist(path)
            continue
        try {
            loop read path, "UTF-8" {
                c := ParseNdjsonLineFast(A_LoopReadLine)
                if !IsObject(c)
                    continue
                if !ItemMatchesView(c, tab, query, todayOnly)
                    continue
                if total >= offset && items.Length < limit
                    items.Push(c)
                total += 1
                if items.Length >= limit && knownTotal >= 0 && knownTotal >= (offset + limit) {
                    tabTotals[key] := knownTotal
                    ClipLog("QueryDiskPage stream hit ms=" (A_TickCount - t0) " n=" items.Length)
                    return { items: items, total: knownTotal }
                }
                if items.Length >= limit {
                    approx := offset + items.Length
                    EnqueueDiskJob(RefreshTabTotalAsync.Bind(tab, todayOnly, key))
                    ClipLog("QueryDiskPage stream early ms=" (A_TickCount - t0) " n=" items.Length)
                    return { items: items, total: Max(approx + Integer(VIEW_PAGE_SIZE), approx + 1) }
                }
                if Mod(++n, 80) = 0
                    Sleep(-1)
            }
        } catch {
        }
    }
    tabTotals[key] := total
    ClipLog("QueryDiskPage stream end ms=" (A_TickCount - t0) " n=" items.Length " total=" total)
    return { items: items, total: total }
}

; Background recount so first paint of「全部」does not scan the whole library
RefreshTabTotalAsync(tab, todayOnly, key := "") {
    global tabTotals, viewCache, viewTab, viewQuery, viewToday, viewTotal, panelVisible
    tab := StrLower(Trim(String(tab)))
    todayOnly := !!todayOnly
    if key = ""
        key := ViewCacheKey(tab, "", todayOnly)
    total := 0
    try total := CountDiskMatches(tab, "", todayOnly)
    catch {
        return
    }
    if !IsObject(tabTotals)
        tabTotals := Map()
    tabTotals[key] := Integer(total)
    if viewCache.Has(key) {
        try viewCache[key].total := Integer(total)
    }
    if panelVisible && viewTab = tab && Trim(String(viewQuery)) = "" && (!!viewToday) = todayOnly {
        viewTotal := Integer(total)
        RequestUiPush()
    }
}

; 收藏: newest pinTime first (not create time / disk order)
QueryPinnedDiskPage(query, todayOnly, offset, limit) {
    q := Trim(String(query))
    pool := EnsureSearchPool("pinned", todayOnly)
    if q != ""
        all := SearchPoolQuery(pool, "pinned", q, todayOnly)
    else
        all := pool.items.Clone()
    SortPinnedClipsDesc(all)
    items := []
    i := Integer(offset) + 1
    while i <= all.Length && items.Length < limit {
        items.Push(all[i])
        i += 1
    }
    return { items: items, total: all.Length }
}

; Search hits + favGroup siblings (siblings skip query match) — memory pool, no disk
FilterViewClipsWithFavExpand(src, tab, query, todayOnly) {
    q := Trim(String(query))
    if q = ""
        return src
    pool := EnsureSearchPool(tab, todayOnly)
    return SearchPoolQuery(pool, tab, q, todayOnly)
}

; Merged group: words may sit on different rows — match union of members' preview/title fields
ExpandFavGroupUnionHits(items, tab, todayOnly, query) {
    q := Trim(String(query))
    if q = "" || !IsObject(items)
        return
    have := Map()
    for c in items
        have[Integer(c.uid)] := true
    hitGids := Map()
    for c in items {
        g := (c.HasProp("favGroup") ? Trim(String(c.favGroup)) : "")
        if g != ""
            hitGids[g] := true
    }
    gids := Map()
    m := LoadManifest()
    for name in m["pages"] {
        for c in ReadPageFile(name, true) {
            if !ItemMatchesTabToday(c, tab, todayOnly)
                continue
            g := (c.HasProp("favGroup") ? Trim(String(c.favGroup)) : "")
            if g = ""
                continue
            if !gids.Has(g)
                gids[g] := []
            gids[g].Push(c)
        }
    }
    for g, members in gids {
        if hitGids.Has(g)
            continue
        unionHay := ""
        for c in members
            unionHay .= " " ClipSearchHay(c)
        if !QueryMatchText(unionHay, "", "text", q)
            continue
        for c in members {
            uid := Integer(c.uid)
            if !have.Has(uid) {
                items.Push(c)
                have[uid] := true
            }
        }
    }
}

; If search hits one member of a favGroup, include the whole group (ignore query for siblings)
ExpandFavGroupHits(items, tab, todayOnly) {
    if !IsObject(items) || items.Length < 1
        return
    gids := Map()
    for c in items {
        g := (c.HasProp("favGroup") ? Trim(String(c.favGroup)) : "")
        if g != ""
            gids[g] := true
    }
    if !gids.Count
        return
    have := Map()
    for c in items
        have[Integer(c.uid)] := true
    m := LoadManifest()
    for name in m["pages"] {
        for c in ReadPageFile(name, true) {
            g := (c.HasProp("favGroup") ? Trim(String(c.favGroup)) : "")
            if g = "" || !gids.Has(g)
                continue
            uid := Integer(c.uid)
            if have.Has(uid)
                continue
            ; Sibling: same tab/today filters, but no search query
            if !ItemMatchesView(c, tab, "", todayOnly)
                continue
            items.Push(c)
            have[uid] := true
        }
    }
}

ResolveClip(uid) {
    global clips, liveFront, PAYLOAD_DIR, recentFolders
    uid := Integer(uid)
    if uid < 1
        return ""
    if IsObject(recentFolders) {
        for c in recentFolders {
            if IsObject(c) && Integer(c.uid) = uid
                return c
        }
    }
    if IsObject(liveFront) {
        for c in liveFront {
            if IsObject(c) && c.uid = uid {
                ApplyQueueMetaToItem(c)
                EnsureClipBodyLoaded(c)
                return c
            }
        }
    }
    for c in clips {
        if c.uid = uid {
            ApplyQueueMetaToItem(c)
            EnsureClipBodyLoaded(c)
            return c
        }
    }
    m := LoadManifest()
    for name in m["pages"] {
        for c in ReadPageFile(name, false) {
            if c.uid = uid {
                ApplyQueueMetaToItem(c)
                EnsureClipBodyLoaded(c)
                return c
            }
        }
    }
    return ""
}

; List queries skip payload files; load body when pasting / opening
EnsureClipBodyLoaded(item) {
    global PAYLOAD_DIR
    if !IsObject(item)
        return
    if item.type = "image"
        return
    if item.HasProp("data") && item.data != ""
        return
    if item.HasProp("dataFile") && item.dataFile != "" {
        p := PAYLOAD_DIR "\" item.dataFile
        if FileExist(p)
            item.data := FileRead(p, "UTF-8")
        return
    }
    ; Inline record with empty data (shouldn't happen after fast parse) —reload from disk
    if item.HasProp("uid") && item.uid > 0 {
        full := DiskLoadUid(item.uid)
        if IsObject(full) && full.HasProp("data")
            item.data := full.data
    }
}

DiskLoadUid(uid) {
    uid := Integer(uid)
    if uid < 1
        return ""
    m := LoadManifest()
    for name in m["pages"] {
        path := PagePath(name)
        if !FileExist(path)
            continue
        try {
            loop read path, "UTF-8" {
                if JsonFieldInt(A_LoopReadLine, "uid") != uid
                    continue
                dirty := false
                return ParseNdjsonLine(A_LoopReadLine, &dirty, false)
            }
        } catch {
        }
    }
    return ""
}

ViewCacheKey(tab, query, todayOnly) {
    return StrLower(Trim(String(tab))) "`n" (todayOnly ? "1" : "0") "`n" String(query)
}

InvalidateViewCache(*) {
    global viewCache, tabTotals, searchPools
    viewCache := Map()
    tabTotals := Map()
    searchPools := Map()
    ClipLog("InvalidateViewCache")
}

SearchPoolKey(tab, todayOnly) {
    return ViewCacheKey(tab, "", todayOnly)
}

; Only keep memory pools for 全部 + 收藏；其它 tab 搜时复用 all 池再按类型滤
SearchPoolTab(tab) {
    tab := StrLower(Trim(String(tab)))
    if tab = "pinned"
        return "pinned"
    return "all"
}

EnsureSearchPool(tab, todayOnly) {
    global searchPools
    tab := SearchPoolTab(tab)
    key := SearchPoolKey(tab, todayOnly)
    if searchPools.Has(key)
        return searchPools[key]
    pool := { items: [], groups: Map() }
    m := LoadManifest()
    n := 0
    for name in m["pages"] {
        for c in ReadPageFile(name, true) {
            if !ItemMatchesTabToday(c, tab, todayOnly)
                continue
            h := ClipSearchHay(c)
            c._searchHay := h
            pool.items.Push(c)
            g := (c.HasProp("favGroup") ? Trim(String(c.favGroup)) : "")
            if g != "" {
                if !pool.groups.Has(g)
                    pool.groups[g] := []
                pool.groups[g].Push(c)
            }
            if Mod(++n, 64) = 0
                Sleep(-1)
        }
    }
    searchPools[key] := pool
    ClipLog("EnsureSearchPool tab=" tab " n=" pool.items.Length)
    return pool
}

; In-memory search (pool built once; fav-group expand without re-scanning disk)
SearchPoolQuery(pool, tab, q, todayOnly) {
    all := []
    if !IsObject(pool) || !pool.HasProp("items")
        return all
    tab := StrLower(Trim(String(tab)))
    have := Map()
    hitGids := Map()
    q := Trim(String(q))
    for c in pool.items {
        if !ItemMatchesTabToday(c, tab, todayOnly)
            continue
        type := StrLower(String(c.type))
        favTitle := c.HasProp("favTitle") ? String(c.favTitle) : ""
        hay := c.HasProp("_searchHay") ? c._searchHay : ClipSearchHay(c)
        if !QueryMatchText(hay, favTitle, type, q)
            continue
        uid := Integer(c.uid)
        if !have.Has(uid) {
            all.Push(c)
            have[uid] := true
        }
        g := (c.HasProp("favGroup") ? Trim(String(c.favGroup)) : "")
        if g != ""
            hitGids[g] := true
    }
    if IsObject(pool.groups) {
        for g, _ in hitGids {
            if !pool.groups.Has(g)
                continue
            for c in pool.groups[g] {
                uid := Integer(c.uid)
                if have.Has(uid)
                    continue
                if !ItemMatchesTabToday(c, tab, todayOnly)
                    continue
                all.Push(c)
                have[uid] := true
            }
        }
        if QueryNeedsFavGroupUnion(q) {
            for g, members in pool.groups {
                if hitGids.Has(g)
                    continue
                unionHay := ""
                anyTab := false
                for c in members {
                    if !ItemMatchesTabToday(c, tab, todayOnly)
                        continue
                    anyTab := true
                    unionHay .= " " (c.HasProp("_searchHay") ? c._searchHay : ClipSearchHay(c))
                }
                if !anyTab || !QueryMatchText(unionHay, "", "text", q)
                    continue
                for c in members {
                    if !ItemMatchesTabToday(c, tab, todayOnly)
                        continue
                    uid := Integer(c.uid)
                    if !have.Has(uid) {
                        all.Push(c)
                        have[uid] := true
                    }
                }
            }
        }
    }
    return all
}

ParseViewCacheKey(key, &tab, &todayOnly, &query) {
    parts := StrSplit(String(key), "`n")
    tab := parts.Length >= 1 ? parts[1] : "all"
    todayOnly := parts.Length >= 2 && parts[2] = "1"
    query := parts.Length >= 3 ? parts[3] : ""
}

MemoryRemoveFromList(arr, pred) {
    removed := 0
    if !IsObject(arr)
        return 0
    i := 1
    while i <= arr.Length {
        if pred(arr[i]) {
            arr.RemoveAt(i)
            removed += 1
        } else
            i += 1
    }
    return removed
}

; Remove all in-memory text equals; return best match (prefer pinned) for meta inherit
MemoryTakeTextEqual(text) {
    global clips, viewTotal, viewCache, liveFront
    best := ""
    ; Collect then remove — avoid nested arrow closures mutating outer vars
    matches := []
    for c in clips {
        if IsObject(c) && c.type = "text" && c.data = text
            matches.Push(c)
    }
    for c in matches {
        if !IsObject(best) || (c.HasProp("pinned") && c.pinned && !(best.HasProp("pinned") && best.pinned))
            best := c
        MemoryRemoveUid(c.uid)
    }
    ; viewCache / liveFront may still hold copies not in clips
    if IsObject(viewCache) {
        for key, entry in viewCache {
            if !IsObject(entry) || !entry.HasProp("items")
                continue
            i := 1
            while i <= entry.items.Length {
                c := entry.items[i]
                if IsObject(c) && c.type = "text" && c.data = text {
                    if !IsObject(best) || (c.HasProp("pinned") && c.pinned && !(best.HasProp("pinned") && best.pinned))
                        best := c
                    entry.items.RemoveAt(i)
                    entry.total := Max(0, entry.total - 1)
                } else
                    i += 1
            }
        }
    }
    if IsObject(liveFront) {
        i := 1
        while i <= liveFront.Length {
            c := liveFront[i]
            if IsObject(c) && c.type = "text" && c.data = text {
                if !IsObject(best) || (c.HasProp("pinned") && c.pinned && !(best.HasProp("pinned") && best.pinned))
                    best := c
                liveFront.RemoveAt(i)
            } else
                i += 1
        }
    }
    return best
}

; Prefer keeping 收藏 / 标题 / uid when re-copy replaces an older row
InheritClipMeta(item, old) {
    if !IsObject(item) || !IsObject(old)
        return
    if old.HasProp("pasted") && old.pasted
        item.pasted := true
    if old.HasProp("pinned") && old.pinned {
        if !(item.HasProp("pinned") && item.pinned) {
            item.pinned := true
            if old.HasProp("pinTime") && old.pinTime != ""
                item.pinTime := old.pinTime
        } else if (!(item.HasProp("pinTime") && item.pinTime != "")) && old.HasProp("pinTime") && old.pinTime != ""
            item.pinTime := old.pinTime
    }
    if (!(item.HasProp("favTitle") && item.favTitle != "")) && old.HasProp("favTitle") && old.favTitle != ""
        item.favTitle := old.favTitle
    if (!(item.HasProp("favGroup") && item.favGroup != "")) && old.HasProp("favGroup") && old.favGroup != ""
        item.favGroup := old.favGroup
    ; Keep queue membership when re-copy replaces equal content (unless already tagged)
    if (!(item.HasProp("queueGroup") && Integer(item.queueGroup) > 0)) && old.HasProp("queueGroup") && Integer(old.queueGroup) > 0 {
        item.queueGroup := Integer(old.queueGroup)
        if old.HasProp("queueIndex")
            item.queueIndex := Integer(old.queueIndex)
    }
    if old.HasProp("uid") && old.uid
        item.uid := old.uid
}

MemoryTakeLinkEqual(url) {
    global clips, viewTotal, viewCache, liveFront
    taken := ""
    for i, c in clips {
        if c.type = "link" && c.data = url {
            taken := clips.RemoveAt(i)
            viewTotal := Max(0, viewTotal - 1)
            break
        }
    }
    for key, entry in viewCache {
        for i, c in entry.items {
            if c.type = "link" && c.data = url {
                if !IsObject(taken)
                    taken := c
                entry.items.RemoveAt(i)
                entry.total := Max(0, entry.total - 1)
                break
            }
        }
    }
    if IsObject(liveFront) {
        for i, c in liveFront {
            if IsObject(c) && c.type = "link" && c.data = url {
                if !IsObject(taken)
                    taken := c
                liveFront.RemoveAt(i)
                break
            }
        }
    }
    return taken
}

MemoryTakeUid(uid) {
    global clips, viewTotal, viewCache
    uid := Integer(uid)
    taken := ""
    for i, c in clips {
        if c.uid = uid {
            taken := clips.RemoveAt(i)
            viewTotal := Max(0, viewTotal - 1)
            break
        }
    }
    for key, entry in viewCache {
        for i, c in entry.items {
            if c.uid = uid {
                if !IsObject(taken)
                    taken := c
                entry.items.RemoveAt(i)
                entry.total := Max(0, entry.total - 1)
                break
            }
        }
    }
    return taken
}

MemoryRemoveUid(uid) {
    MemoryTakeUid(uid)
}

MemoryInsertFront(item) {
    global clips, viewTab, viewQuery, viewToday, viewTotal, viewCache, PAGE_SIZE, VIEW_PAGE_SIZE, tabTotals, searchPools
    ; Drop same uid anywhere first
    MemoryRemoveUid(item.uid)
    LiveFrontAdd(item)
    maxRows := Max(VIEW_PAGE_SIZE * 2, 40)
    for key, entry in viewCache {
        tab := "", todayOnly := false, query := ""
        ParseViewCacheKey(key, &tab, &todayOnly, &query)
        if !ItemMatchesView(item, tab, query, todayOnly)
            continue
        entry.items.InsertAt(1, item)
        entry.total += 1
        while entry.items.Length > maxRows
            entry.items.Pop()
        if query = "" && IsObject(tabTotals)
            tabTotals[key] := Integer(entry.total)
    }
    if IsObject(searchPools) {
        h := ClipSearchHay(item)
        item._searchHay := h
        for key, pool in searchPools {
            tab := "", todayOnly := false, query := ""
            ParseViewCacheKey(key, &tab, &todayOnly, &query)
            if !ItemMatchesTabToday(item, tab, todayOnly)
                continue
            pool.items.InsertAt(1, item)
            g := (item.HasProp("favGroup") ? Trim(String(item.favGroup)) : "")
            if g != "" {
                if !pool.groups.Has(g)
                    pool.groups[g] := []
                pool.groups[g].InsertAt(1, item)
            }
        }
    }
    if ItemMatchesView(item, viewTab, viewQuery, viewToday) {
        clips.InsertAt(1, item)
        viewTotal += 1
    }
    ; Do NOT CacheCurrentView() here —that overwrote a full disk page with the
    ; in-memory clips window (often 1 item after copy-before-open) and hid history.
}

; Keep freshly copied items across InvalidateViewCache / SetView(disk) races
LiveFrontAdd(item) {
    global liveFront
    if !IsObject(item) || !item.HasProp("uid")
        return
    LiveFrontRemoveUid(item.uid)
    liveFront.InsertAt(1, item)
    ; Bound memory —only need the newest few until disk catches up
    while liveFront.Length > 40
        liveFront.Pop()
}

LiveFrontRemoveUid(uid) {
    global liveFront
    uid := Integer(uid)
    for i, c in liveFront {
        if IsObject(c) && c.uid = uid {
            liveFront.RemoveAt(i)
            return
        }
    }
}

LiveFrontConfirmPersisted(uid) {
    LiveFrontRemoveUid(uid)
}

MergeLiveFrontIntoClips() {
    global liveFront, clips, viewTab, viewQuery, viewToday, viewTotal
    if !IsObject(liveFront) || liveFront.Length < 1
        return
    have := Map()
    for c in clips {
        if IsObject(c) && c.HasProp("uid")
            have[Integer(c.uid)] := true
    }
    ; liveFront is newest-first; collect matching missing items then prepend in order
    add := []
    for c in liveFront {
        if !IsObject(c) || !c.HasProp("uid")
            continue
        uid := Integer(c.uid)
        if have.Has(uid)
            continue
        if !ItemMatchesView(c, viewTab, viewQuery, viewToday)
            continue
        add.Push(c)
        have[uid] := true
    }
    ; 搜索模式不把同 favGroup 的未命中兄弟塞进结果
    if !add.Length
        return
    ; Insert so add[1] (newest) ends at front
    i := add.Length
    while i >= 1 {
        clips.InsertAt(1, add[i])
        viewTotal += 1
        i -= 1
    }
    ClipLog("MergeLiveFrontIntoClips added=" add.Length " clips=" clips.Length)
}

EnqueueDiskJob(fn) {
    global diskJobQueue
    diskJobQueue.Push(fn)
    SetTimer(DrainDiskJobs, -20)
}

; Run ASAP (front of queue) — queue persist must not wait behind thumbs/prune
PrependDiskJob(fn) {
    global diskJobQueue
    diskJobQueue.InsertAt(1, fn)
    SetTimer(DrainDiskJobs, -1)
}

DrainDiskJobs(*) {
    global diskJobBusy, diskJobQueue, diskScanBusy
    if diskJobBusy {
        ; Still running —retry soon so queued jobs are not stuck until next copy
        SetTimer(DrainDiskJobs, -80)
        return
    }
    if diskScanBusy {
        SetTimer(DrainDiskJobs, -200)
        return
    }
    if diskJobQueue.Length < 1
        return
    diskJobBusy := true
    ; No Critical here —GDI+/FileCopy under Critical hung then killed the process
    fn := diskJobQueue.RemoveAt(1)
    ClipLog("DrainDiskJobs RUN qLeft=" diskJobQueue.Length)
    try fn.Call()
    catch as e {
        ClipLogErr("DrainDiskJobs", e)
    }
    diskJobBusy := false
    ClipLog("DrainDiskJobs DONE")
    ; Long FileRead loops can leave the wait cursor; restore after each job
    try DllCall("SystemParametersInfo", "UInt", 0x57, "UInt", 0, "Ptr", 0, "UInt", 0)
    if diskJobQueue.Length
        SetTimer(DrainDiskJobs, -20)
}

; Block until pending disk jobs finish (used on script exit)
FlushDiskJobsSync(*) {
    global diskJobBusy, diskJobQueue
    SetTimer(DrainDiskJobs, 0)
    loop 1000 {
        if diskJobQueue.Length < 1 && !diskJobBusy
            break
        if diskJobBusy {
            Sleep 15
            continue
        }
        if diskJobQueue.Length {
            diskJobBusy := true
            fn := diskJobQueue.RemoveAt(1)
            try fn.Call()
            catch {
            }
            diskJobBusy := false
        }
    }
}

; Large text/link →external payload file (NDJSON line stays small so reload won't drop it)
EnsureSpillPayload(item) {
    global PAYLOAD_DIR, PAYLOAD_INLINE_MAX
    if !IsObject(item)
        return
    if item.type = "image" || item.type = "file"
        return
    if item.HasProp("dataFile") && item.dataFile != ""
        return
    data := String(item.HasProp("data") ? item.data : "")
    if StrLen(data) <= PAYLOAD_INLINE_MAX
        return
    try DirCreate PAYLOAD_DIR
    name := "d_" item.uid ".txt"
    path := PAYLOAD_DIR "\" name
    try {
        if FileExist(path)
            FileDelete path
        FileAppend data, path, "UTF-8"
        if FileExist(path)
            item.dataFile := name
    } catch {
    }
}

; 落盘前从内存抄回收藏/标题，避免异步 Persist 覆盖用户刚点的收藏
SyncPersistItemMetaFromMemory(item) {
    global clips, liveFront
    if !IsObject(item) || !item.HasProp("uid")
        return
    uid := Integer(item.uid)
    if uid < 1
        return
    src := ""
    if IsObject(clips) {
        for c in clips {
            if IsObject(c) && Integer(c.uid) = uid {
                src := c
                break
            }
        }
    }
    if !IsObject(src) && IsObject(liveFront) {
        for c in liveFront {
            if IsObject(c) && Integer(c.uid) = uid {
                src := c
                break
            }
        }
    }
    if !IsObject(src)
        return
    if src.HasProp("pinned")
        item.pinned := !!src.pinned
    if src.HasProp("pinTime")
        item.pinTime := src.pinTime
    if src.HasProp("favTitle")
        item.favTitle := src.favTitle
    if src.HasProp("favGroup")
        item.favGroup := src.favGroup
    if src.HasProp("pasted")
        item.pasted := !!src.pasted
}

DeletePayloadFile(item) {
    global PAYLOAD_DIR
    if !IsObject(item) || !item.HasProp("dataFile") || item.dataFile = ""
        return
    path := PAYLOAD_DIR "\" item.dataFile
    try {
        if FileExist(path)
            FileDelete path
    }
}

PersistNewItem(item) {
    global panelVisible, pasteQueueIds
    if !IsObject(item)
        return
    uidBefore := item.HasProp("uid") ? Integer(item.uid) : 0
    ClipLog("PersistNewItem begin uid=" uidBefore " type=" item.type)
    ; Keep queue tags across InheritClipMeta (disk equal may not have them yet)
    keepQg := (item.HasProp("queueGroup") ? Integer(item.queueGroup) : 0)
    keepQi := (item.HasProp("queueIndex") ? Integer(item.queueIndex) : 0)
    ; Heavy file I/O lives here (async queue) — never on OnClipboardChange
    if item.type = "image" {
        if (!item.HasProp("imgFile") || item.imgFile = "") && item.HasProp("data") && item.data != "" {
            try item.imgFile := SaveImageToStore(item.data)
            catch as e {
                ClipLogErr("PersistNewItem SaveImageToStore", e)
            }
            item.data := ""
            ; Patch in-memory / cache so UI can load thumb after write
            ApplyImgFileLocal(item.uid, item.HasProp("imgFile") ? item.imgFile : "")
            ; Don't wait for coalesced PushClips —fill the blank placeholder now
            if item.HasProp("imgFile") && item.imgFile != ""
                SetTimer(InjectStoreThumbNow.Bind(Integer(item.uid), String(item.imgFile)), -10)
        }
    }
    ; Remove old equals BEFORE spill — reused uid shares d_<uid>.txt with the old row.
    ; Queue FIFO slots must stay distinct: DiskRemoveTextEqual was deleting earlier queue
    ; rows with the same text and InheritClipMeta stole their uid (3→2 after restart).
    if keepQg > 0 {
        ; keep fresh uid + queue tags; do not collapse onto historical equals
    } else if item.type = "text" {
        old := DiskRemoveTextEqual(item.data)
        InheritClipMeta(item, old)
    } else if item.type = "link" {
        old := DiskTakeLinkEqual(item.data)
        if IsObject(old) {
            InheritClipMeta(item, old)
            if old.HasProp("linkTitle") && old.linkTitle != "" && !(item.HasProp("linkTitle") && item.linkTitle != "")
                item.linkTitle := old.linkTitle
            if old.uid != item.uid
                DeletePayloadFile(old)
        }
    } else if item.type = "file" {
        old := DiskRemoveFileEqual(item.data)
        InheritClipMeta(item, old)
        if IsObject(old) && old.HasProp("imgFile") && old.imgFile != "" && !(item.HasProp("imgFile") && item.imgFile != "")
            item.imgFile := old.imgFile
    }
    if keepQg > 0 {
        item.queueGroup := keepQg
        item.queueIndex := keepQi
        ; Force uid stable — never accept Inherit from a partial path above
        if uidBefore > 0
            item.uid := uidBefore
    }
    ; 文件缩略图：去重继承之后再补（队列模式也会走到这里）
    if item.type = "file" {
        if (!item.HasProp("imgFile") || item.imgFile = "") && FileClipLooksLikeImage(item) {
            try EnsureFileClipThumb(item)
            catch as e {
                ClipLogErr("PersistNewItem EnsureFileClipThumb", e)
            }
        }
        if item.HasProp("imgFile") && item.imgFile != "" {
            ApplyImgFileLocal(item.uid, item.imgFile)
            SetTimer(InjectStoreThumbNow.Bind(Integer(item.uid), String(item.imgFile)), -10)
        }
    }
    EnsureSpillPayload(item)
    ; 持久化前与内存对齐：用户可能在异步落盘前已收藏/改标题
    SyncPersistItemMetaFromMemory(item)
    ok := DiskInsertFront(item)
    uidAfter := item.HasProp("uid") ? Integer(item.uid) : 0
    ClipLog("PersistNewItem done uid=" uidAfter " ok=" ok " qg=" keepQg " qi=" keepQi)
    if ok {
        LiveFrontConfirmPersisted(item.uid)
        if keepQg > 0 {
            ; Final uid after Inherit — meta must match disk row
            if uidBefore > 0 && uidAfter > 0 && uidBefore != uidAfter
                RemapPasteQueueUid(uidBefore, uidAfter)
            UpsertQueueMeta(uidAfter, keepQg, keepQi)
            DiskSetQueueMeta(uidAfter, keepQg, keepQi)
        }
    }
    ; Cap clipboard screenshots only —file images stay forever (debounced)
    if item.type = "image"
        SchedulePruneScreenshots()
    ; Ensure open panel catches up even if the first UI push was dropped
    if panelVisible
        RequestUiPush()
}

ApplyImgFileLocal(uid, imgFile) {
    global clips, viewCache
    uid := Integer(uid)
    imgFile := String(imgFile)
    for c in clips {
        if c.uid = uid {
            c.imgFile := imgFile
            c.data := ""
            break
        }
    }
    for , entry in viewCache {
        if !IsObject(entry) || !entry.HasProp("items")
            continue
        for c in entry.items {
            if c.uid = uid {
                c.imgFile := imgFile
                c.data := ""
                break
            }
        }
    }
}

PersistDeleteUid(uid, imgFile := "", itemType := "") {
    removed := DiskRemoveUid(uid)
    if IsObject(removed)
        DeletePayloadFile(removed)
    ; Screenshots and image-format file thumbs both live in clips_store
    if imgFile != ""
        DeleteStoredImage({ type: "image", imgFile: imgFile })
    else if IsObject(removed) && removed.HasProp("imgFile") && removed.imgFile != ""
        DeleteStoredImage(removed)
}

; Keep only the newest MAX_SCREENSHOTS clipboard screenshots (type=image).
; type=file / fimg_* thumbs are never touched. Pinned screenshots are always kept.
SchedulePruneScreenshots(*) {
    global pruneScreenshotsArmed, pruneScreenshotsPending
    pruneScreenshotsPending := true
    if pruneScreenshotsArmed
        return
    pruneScreenshotsArmed := true
    ; Idle debounce —never full-scan the library on every screenshot persist
    SetTimer(FlushPruneScreenshots, -2800)
}

FlushPruneScreenshots(*) {
    global pruneScreenshotsArmed, pruneScreenshotsPending
    pruneScreenshotsArmed := false
    if !pruneScreenshotsPending
        return
    pruneScreenshotsPending := false
    EnqueueDiskJob(PruneOldScreenshots)
}

PruneOldScreenshots(*) {
    global MAX_SCREENSHOTS, viewCache
    maxKeep := Integer(MAX_SCREENSHOTS)
    if maxKeep < 1
        maxKeep := 100
    m := LoadManifest()
    pages := m["pages"]
    if !IsObject(pages) || !pages.Length
        return
    ; Newest-first (page order): collect screenshot rows only
    images := []
    n := 0
    for name in pages {
        for c in ReadPageFile(name, true) {
            if !IsObject(c) || c.type != "image"
                continue
            images.Push(c)
            if Mod(++n, 64) = 0
                Sleep(-1)
        }
    }
    drop := Map()
    keptUnpinned := 0
    for c in images {
        uid := Integer(c.uid)
        if uid < 1
            continue
        if c.HasProp("pinned") && c.pinned
            continue
        if keptUnpinned < maxKeep {
            keptUnpinned += 1
            continue
        }
        drop[uid] := c
    }
    if !drop.Count
        return
    ClipLog("PruneOldScreenshots drop=" drop.Count " keepUnpinned=" keptUnpinned " max=" maxKeep)

    ; One rewrite pass over pages
    newPages := []
    for name in pages {
        items := ReadPageFile(name, true)
        kept := []
        changed := false
        for c in items {
            if IsObject(c) && drop.Has(Integer(c.uid)) {
                changed := true
                continue
            }
            kept.Push(c)
        }
        if !changed {
            newPages.Push(name)
            continue
        }
        if kept.Length {
            WritePageFile(name, kept)
            newPages.Push(name)
        } else {
            try FileDelete PagePath(name)
        }
        if Mod(++n, 8) = 0
            Sleep(-1)
    }
    m["pages"] := newPages
    SaveManifest(m)

    for uid, c in drop {
        try DeleteStoredImage(c)
        MemoryRemoveUid(uid)
        LiveFrontRemoveUid(uid)
    }
    ; Drop stale image-tab / all totals in viewCache
    for key, entry in viewCache {
        if !IsObject(entry) || !entry.HasProp("items")
            continue
        keptItems := []
        removedN := 0
        for c in entry.items {
            if IsObject(c) && drop.Has(Integer(c.uid)) {
                removedN += 1
                continue
            }
            keptItems.Push(c)
        }
        if removedN {
            entry.items := keptItems
            entry.total := Max(0, Integer(entry.total) - removedN)
        }
    }
    ; Totals changed —force next QueryDiskPage to recount if needed
    global tabTotals
    tabTotals := Map()
    ClipLog("PruneOldScreenshots done")
}

PersistMoveToTop(item) {
    if !IsObject(item)
        return
    EnsureSpillPayload(item)
    DiskRemoveUid(item.uid)
    DiskInsertFront(item)
}

CacheCurrentView() {
    global viewCache, clips, viewTab, viewQuery, viewToday, viewTotal, VIEW_PAGE_SIZE, tabTotals
    key := ViewCacheKey(viewTab, viewQuery, viewToday)
    ; 禁止用「仅一页、total 未扫完」的全部快照盖掉已有完整 total
    if viewTab = "all" && viewQuery = "" && !viewToday {
        if viewTotal <= VIEW_PAGE_SIZE && clips.Length <= VIEW_PAGE_SIZE {
            if viewCache.Has(key) {
                old := viewCache[key]
                if IsObject(old) && old.HasProp("total") && old.total > VIEW_PAGE_SIZE
                    return
            }
            ; 完整小库（条数=total）可以缓存；未扫完的首屏快照不要写
            if !(viewTotal > 0 && viewTotal = clips.Length)
                return
        }
    }
    cloned := []
    for c in clips
        cloned.Push(c)
    viewCache[key] := { items: cloned, total: viewTotal }
    if viewQuery = "" && IsObject(tabTotals)
        tabTotals[key] := Integer(viewTotal)
}

; 首屏：只暖「全部」前 FIRST_PAINT_SIZE 条；pushUi=false 时只填内存（Navigate 前用）
PreloadAllViews(today := "", pushUi := true) {
    global viewCache, viewToday, VIEW_PAGE_SIZE, FIRST_PAINT_SIZE, qqSearchOn, tabTotals
        , clips, viewTab, viewQuery, viewTotal, viewApplying, wvCore
    PerfMark("PreloadAllViews ENTER pushUi=" pushUi)
    try {
        if today = ""
            todayFlag := viewToday
        else
            todayFlag := (String(today) = "1" || String(today) = "true")
        key := ViewCacheKey("all", "", todayFlag)
        if viewCache.Has(key) {
            entry := viewCache[key]
            if IsObject(entry) && entry.HasProp("items") && entry.items.Length >= 1 {
                PerfMark("PreloadAllViews viewCache HIT n=" entry.items.Length)
                if !qqSearchOn {
                    clips := []
                    for c in entry.items
                        clips.Push(c)
                    viewTab := "all"
                    viewQuery := ""
                    viewToday := todayFlag
                    viewTotal := Integer(entry.HasProp("total") ? entry.total : clips.Length)
                    viewApplying := false
                    if pushUi && IsObject(wvCore)
                        PushClips(false)
                }
                CacheRecentFoldersView(todayFlag)
                return
            }
        }

        paintN := Integer(FIRST_PAINT_SIZE)
        if paintN < 1
            paintN := 20
        if paintN > VIEW_PAGE_SIZE
            paintN := VIEW_PAGE_SIZE

        items := []
        m := LoadManifest()
        pageN := 0
        try pageN := m["pages"].Length
        PerfMark("PreloadAllViews scan start paintN=" paintN " pages=" pageN)
        n := 0
        t0 := A_TickCount
        for name in m["pages"] {
            path := PagePath(name)
            if !FileExist(path)
                continue
            try {
                loop read path, "UTF-8" {
                    c := ParseNdjsonLineFast(A_LoopReadLine)
                    if !IsObject(c)
                        continue
                    if !ItemMatchesView(c, "all", "", todayFlag)
                        continue
                    items.Push(c)
                    if items.Length >= paintN {
                        approxTotal := items.Length + VIEW_PAGE_SIZE
                        viewCache[key] := { items: items.Clone(), total: approxTotal }
                        if IsObject(tabTotals)
                            tabTotals[key] := Integer(approxTotal)
                        if !qqSearchOn {
                            clips := items.Clone()
                            viewTab := "all"
                            viewQuery := ""
                            viewToday := todayFlag
                            viewTotal := approxTotal
                            viewApplying := false
                            if pushUi && IsObject(wvCore)
                                PushClips(false)
                        }
                        CacheRecentFoldersView(todayFlag)
                        EnqueueDiskJob(RefreshTabTotalAsync.Bind("all", todayFlag, key))
                        ClipLog("PreloadAllViews paint n=" items.Length " ms=" (A_TickCount - t0))
                        PerfMark("PreloadAllViews paint done n=" items.Length " scanMs=" (A_TickCount - t0))
                        return
                    }
                }
            } catch {
            }
        }
        viewCache[key] := { items: items, total: items.Length }
        if IsObject(tabTotals)
            tabTotals[key] := Integer(items.Length)
        CacheRecentFoldersView(todayFlag)
        ClipLog("PreloadAllViews full-lib n=" items.Length " ms=" (A_TickCount - t0))
        PerfMark("PreloadAllViews full-lib n=" items.Length " scanMs=" (A_TickCount - t0))
        if pushUi && !qqSearchOn
            SetView("all", "", todayFlag ? "1" : "0")
    }
}

; 兼容旧名
PreloadAllViewsContinue(todayFlag := false, startPageIdx := 1) {
    key := ViewCacheKey("all", "", !!todayFlag)
    EnqueueDiskJob(RefreshTabTotalAsync.Bind("all", !!todayFlag, key))
}

PreloadNonLinkViews(today := "") {
    PreloadAllViews(today, true)
}

QueueSetView(tab, query, today) {
    global pendingViewTab, pendingViewQuery, pendingViewToday, pendingViewArmed
        , qqSearchOn, qqQuery, firstAllPaintDone
    ; ?? 搜索中前端偶发带空 query 的 setView：改写为当前关键字，避免冲掉命中
    if qqSearchOn {
        want := Trim(String(qqQuery))
        if want != "" && Trim(String(query)) = ""
            query := qqQuery
    }
    pendingViewTab := tab
    pendingViewQuery := query
    pendingViewToday := today
    ; 首屏未出前：只记 pending，避免 JS requestView 冷扫盘抢跑
    if !firstAllPaintDone {
        pendingViewArmed := true
        return
    }
    if pendingViewArmed
        return
    pendingViewArmed := true
    SetTimer(ApplyPendingView, -1)
}

ApplyPendingView(*) {
    global pendingViewArmed, pendingViewTab, pendingViewQuery, pendingViewToday
    pendingViewArmed := false
    SetView(pendingViewTab, pendingViewQuery, pendingViewToday)
}

SetView(tab := "all", query := "", today := "0") {
    global clips, viewTab, viewQuery, viewToday, viewTotal, VIEW_PAGE_SIZE, FIRST_PAINT_SIZE, lastAppendCount, wvCore, viewCache
        , qqSearchOn, qqQuery, qqAwaitKeyword, viewSwitchGuardUntil, viewApplyGen, viewApplying
    ; ?? 搜索进行中：禁止空查询把结果冲成「全部未过滤」，否则前端按关键字一滤就变成 0 条
    if qqSearchOn {
        want := Trim(String(qqQuery))
        incoming := Trim(String(query))
        if want != "" && incoming = "" {
            ClipLog("SetView SKIP empty while qqSearch q=" want)
            return
        }
        if qqAwaitKeyword && incoming = "" {
            ClipLog("SetView SKIP empty while qqAwaitKeyword")
            return
        }
    }
    newTab := StrLower(Trim(String(tab)))
    if newTab = "" || newTab = "0"
        newTab := "all"
    newQuery := String(query)
    newToday := (String(today) = "1" || String(today) = "true")
    ; 「最近」纯内存：短守卫，不走整盘扫
    if newTab = "recent" {
        viewSwitchGuardUntil := A_TickCount + 200
        myGen := ++viewApplyGen
        viewApplying := true
        viewTab := newTab
        viewQuery := newQuery
        viewToday := newToday
        lastAppendCount := 0
        try {
            page := QueryRecentFoldersPage(viewQuery, viewToday, 0, VIEW_PAGE_SIZE)
            if myGen != viewApplyGen
                return
            clips := page.items
            viewTotal := page.total
            key := ViewCacheKey(viewTab, viewQuery, viewToday)
            cached := []
            for c in clips
                cached.Push(c)
            viewCache[key] := { items: cached, total: viewTotal }
            ClipLog("SetView recent n=" clips.Length " total=" viewTotal)
            viewApplying := false
            if IsObject(wvCore)
                PushClips(false)
            QQSyncPanelVisibility()
            viewSwitchGuardUntil := A_TickCount + 120
        } finally {
            if myGen = viewApplyGen
                viewApplying := false
        }
        return
    }
    ; 切页扫盘可能较慢：期间忽略外侧点击，避免卡完面板被误关
    viewSwitchGuardUntil := A_TickCount + 1200
    myGen := ++viewApplyGen
    viewApplying := true
    viewTab := newTab
    viewQuery := newQuery
    viewToday := newToday
    lastAppendCount := 0
    try {
        key := ViewCacheKey(viewTab, viewQuery, viewToday)
        if viewCache.Has(key) {
            entry := viewCache[key]
            ; Only drop empty / near-empty "全部" snapshots (copy-before-open).
            ; Do NOT treat total<=VIEW_PAGE_SIZE as poison —that forced a full disk
            ; rescan on every tab switch for libraries with ≤20 items.
            poisoned := viewTab = "all" && viewQuery = "" && !viewToday
                && IsObject(entry) && entry.HasProp("items")
                && entry.items.Length < 5 && entry.total <= entry.items.Length
            thin := !IsObject(entry) || !entry.HasProp("items") || poisoned
            if !thin {
                if myGen != viewApplyGen
                    return
                clips := []
                for c in entry.items
                    clips.Push(c)
                viewTotal := entry.total
                MergeLiveFrontIntoClips()
                ClipLog("SetView cache hit tab=" viewTab " n=" clips.Length " total=" viewTotal)
                viewApplying := false
                if IsObject(wvCore)
                    PushClips(false)
                ; 不要 QQPushQuery：会触发前端 requestView → SetView 死循环闪烁
                QQSyncPanelVisibility()
                viewSwitchGuardUntil := A_TickCount + 400
                return
            }
            ClipLog("SetView drop thin cache tab=" viewTab " n=" entry.items.Length " total=" entry.total)
            viewCache.Delete(key)
        }
        page := QueryDiskPage(viewTab, viewQuery, viewToday, 0
            , (viewTab = "all" && viewQuery = "" ? FIRST_PAINT_SIZE : VIEW_PAGE_SIZE))
        if myGen != viewApplyGen
            return
        clips := page.items
        viewTotal := page.total
        MergeLiveFrontIntoClips()
        ClipLog("SetView disk tab=" viewTab " n=" clips.Length " total=" viewTotal)
        CacheCurrentView()
        viewApplying := false
        if IsObject(wvCore)
            PushClips(false)
        ; 不要 QQPushQuery：会触发前端 requestView → SetView 死循环闪烁
        QQSyncPanelVisibility()
        viewSwitchGuardUntil := A_TickCount + 400
    } finally {
        if myGen = viewApplyGen
            viewApplying := false
    }
}

; 有搜索关键字时，严格命中 + 合并组整组展示（防缓存/竞态脏数据）
FilterClipsInPlaceToQuery(*) {
    global clips, viewTab, viewQuery, viewToday, viewTotal
    q := Trim(String(viewQuery))
    if q = ""
        return
    clips := FilterViewClipsWithFavExpand(clips, viewTab, viewQuery, viewToday)
    viewTotal := clips.Length
}

LoadMoreView(*) {
    global clips, viewTab, viewQuery, viewToday, viewTotal, VIEW_PAGE_SIZE, lastAppendCount, wvCore
    if clips.Length >= viewTotal {
        lastAppendCount := 0
        if IsObject(wvCore)
            try wvCore.ExecuteScriptAsync("window.__loadMoreDone&&window.__loadMoreDone()")
        return
    }
    page := QueryDiskPage(viewTab, viewQuery, viewToday, clips.Length, VIEW_PAGE_SIZE)
    viewTotal := page.total
    lastAppendCount := page.items.Length
    for c in page.items
        clips.Push(c)
    CacheCurrentView()
    if IsObject(wvCore)
        PushClips(true)
}

; One-time migrate clips.json →NDJSON shards of PAGE_SIZE
MigrateLegacyJsonIfNeeded() {
    global SAVE_FILE, MANIFEST_FILE, PAGE_SIZE, clipUidSeq, STORE_DIR
    EnsurePagesDir()
    if FileExist(MANIFEST_FILE)
        return
    bak := SAVE_FILE ".bak"
    src := ""
    if FileExist(SAVE_FILE)
        src := SAVE_FILE
    else if FileExist(bak)
        src := bak
    if src = "" {
        SaveManifest(Map("uidSeq", clipUidSeq, "nextPage", 1, "pages", []))
        return
    }
    try {
        txt := FileRead(src, "UTF-8")
        if txt = "" || !RegExMatch(txt, "^\s*\[")
            return
        all := []
        dirty := false
        for jo in JsonArrayToAhk(JsonParse(txt)) {
            item := ParseJoToItem(jo, &dirty)
            if IsObject(item)
                all.Push(item)
        }
        pages := []
        nextPage := 1
        i := 1
        while i <= all.Length {
            chunk := []
            loop PAGE_SIZE {
                if i > all.Length
                    break
                chunk.Push(all[i])
                i += 1
            }
            name := Format("p_{:06}.ndjson", nextPage)
            nextPage += 1
            WritePageFile(name, chunk)
            pages.Push(name)
        }
        SaveManifest(Map("uidSeq", clipUidSeq, "nextPage", nextPage, "pages", pages))
        try FileMove src, src ".migrated", 1
    } catch {
        SaveManifest(Map("uidSeq", clipUidSeq, "nextPage", 1, "pages", []))
    }
}

InitClipsFromDisk() {
    global clips, lastTxt, clipUidSeq
    clips := []
    MigrateLegacyJsonIfNeeded()
    m := LoadManifest()
    m := RepairManifestPages(m)
    SaveManifest(m)
    clipUidSeq := Integer(m["uidSeq"])
    if m["pages"].Length {
        for c in ReadPageFile(m["pages"][1]) {
            NoteQueueGroupFromItem(c)
            if c.type = "text" {
                lastTxt := c.data
                break
            }
        }
    }
    LoadQueueMeta()
    LoadPasteQueueState()
}


; Keep running after non-critical errors (clipboard exotic formats etc.)
OnError(ClipMgrOnError, 1)
ClipMgrOnError(err, mode) {
    ClipLogErr("OnError mode=" mode, err)
    return true
}

OnExit SaveAndExit
SaveAndExit(exitReason, exitCode) {
    ClipLog("OnExit reason=" exitReason " code=" exitCode " —flushing disk")
    try SavePasteQueueState()
    catch as e {
        ClipLogErr("SavePasteQueueState", e)
    }
    try SaveQueueMeta()
    catch as e {
        ClipLogErr("SaveQueueMeta", e)
    }
    try FlushDiskJobsSync()
    catch as e {
        ClipLogErr("FlushDiskJobsSync", e)
    }
    try StopCaretWatcher()
    ClipLog("OnExit done")
}

ClipLog("=== SCRIPT BOOT begin pid=" ProcessExist() " ===")
; Keep last run tail so we can compare; mark new session clearly
try {
    if FileExist(DEBUG_LOG) && FileGetSize(DEBUG_LOG) > 2 * 1024 * 1024 {
        FileMove DEBUG_LOG, DEBUG_LOG ".old", 1
    }
}
EnsureDataDir()
ClipLog("EnsureDataDir done CLIP_V1_DIR=" CLIP_V1_DIR " script=" A_ScriptDir)
InitClipsFromDisk()
ClipLog("InitClipsFromDisk done")
LoadRecentFolders()
ClipLog("LoadRecentFolders n=" (IsObject(recentFolders) ? recentFolders.Length : 0))
; Warm「最近」cache immediately —do not wait for full-disk PreloadAllViews
try CacheRecentFoldersView(false)
try CacheRecentFoldersView(true)
SetTimer(WatchExplorerFolder, 700)
; One-shot: trim historical screenshots over the cap (file images untouched)
SetTimer(() => PreloadAllViews("0", false), -1)

; Clipboard watch ONLY after disk init —early OnClipboardChange caused boot-copy crash
EnableClipboardWatch()
ClipLog("EnableClipboardWatch scheduled")

; Register Win+V before BuildGui (WebView2 init must not block hotkey setup)
try RegWrite(0, "REG_DWORD", "HKCU\Software\Microsoft\Clipboard", "EnableClipboardHistory")
A_MenuMaskKey := "vkE8"

; ── Win key gate ───────────────────────────────────────────
; Windows clipboard sits in a higher shell z-band; our GUI cannot cover Start/Search.
; Swallow Win on keydown and NEVER auto-forward on a timer (that was reopening Search).
; - Win+V  → our panel (Win never reaches OS)
; - Win+其它 → forward Win then the key
; - 单击 Win → on release, open Start
global winPendingL := false, winPendingR := false
global winSentL := false, winSentR := false
global winChord := false

FlushWinForSystemChord(key) {
    global winChord, winPendingL, winPendingR, winSentL, winSentR
    winChord := false
    if GetKeyState("LWin", "P") && !winSentL {
        Send("{Blind}{LWin down}")
        winSentL := true
        winPendingL := false
    }
    if GetKeyState("RWin", "P") && !winSentR {
        Send("{Blind}{RWin down}")
        winSentR := true
        winPendingR := false
    }
    Send("{Blind}{" key "}")
}
TriggerWinV(*) {
    global winChord, winPendingL, winPendingR, winSentL, winSentR
    winChord := true
    winPendingL := false
    winPendingR := false
    ; If Win was already forwarded somehow, release + dismiss Search
    if winSentL {
        Send("{Blind}{LWin up}")
        winSentL := false
    }
    if winSentR {
        Send("{Blind}{RWin up}")
        winSentR := false
    }
    if ShellOverlayIsShowing()
        DismissWindowsSearch()
    HotkeyWinV()
}

*$LWin:: {
    global winPendingL, winSentL, winChord
    winChord := false
    winPendingL := true
    winSentL := false
}
*$RWin:: {
    global winPendingR, winSentR, winChord
    winChord := false
    winPendingR := true
    winSentR := false
}
*$LWin up:: {
    global winPendingL, winSentL, winChord
    if winChord {
        winPendingL := false
        winSentL := false
        winChord := false
        return
    }
    if winSentL {
        Send("{Blind}{LWin up}")
    } else if winPendingL {
        Send("{Blind}{LWin down}{LWin up}")
    }
    winPendingL := false
    winSentL := false
}
*$RWin up:: {
    global winPendingR, winSentR, winChord
    if winChord {
        winPendingR := false
        winSentR := false
        winChord := false
        return
    }
    if winSentR {
        Send("{Blind}{RWin up}")
    } else if winPendingR {
        Send("{Blind}{RWin down}{RWin up}")
    }
    winPendingR := false
    winSentR := false
}

#HotIf GetKeyState("LWin", "P") || GetKeyState("RWin", "P")
*$v:: TriggerWinV()
; Quick Win+other —still reach the OS
*$e:: FlushWinForSystemChord("e")
*$d:: FlushWinForSystemChord("d")
*$r:: FlushWinForSystemChord("r")
*$i:: FlushWinForSystemChord("i")
*$x:: FlushWinForSystemChord("x")
*$l:: FlushWinForSystemChord("l")
*$s:: FlushWinForSystemChord("s")
*$a:: FlushWinForSystemChord("a")
*$Tab:: FlushWinForSystemChord("Tab")
*$Left:: FlushWinForSystemChord("Left")
*$Right:: FlushWinForSystemChord("Right")
*$Up:: FlushWinForSystemChord("Up")
*$Down:: FlushWinForSystemChord("Down")
*$1:: FlushWinForSystemChord("1")
*$2:: FlushWinForSystemChord("2")
*$3:: FlushWinForSystemChord("3")
*$4:: FlushWinForSystemChord("4")
*$5:: FlushWinForSystemChord("5")
*$6:: FlushWinForSystemChord("6")
*$7:: FlushWinForSystemChord("7")
*$8:: FlushWinForSystemChord("8")
*$9:: FlushWinForSystemChord("9")
*$0:: FlushWinForSystemChord("0")
*$Escape:: FlushWinForSystemChord("Escape")
*$Space:: FlushWinForSystemChord("Space")
*$m:: FlushWinForSystemChord("m")
*$n:: FlushWinForSystemChord("n")
*$p:: FlushWinForSystemChord("p")
*$u:: FlushWinForSystemChord("u")
*$h:: FlushWinForSystemChord("h")
*$k:: FlushWinForSystemChord("k")
*$g:: FlushWinForSystemChord("g")
*$c:: FlushWinForSystemChord("c")
*$b:: FlushWinForSystemChord("b")
*$t:: FlushWinForSystemChord("t")
*$w:: FlushWinForSystemChord("w")
*$z:: FlushWinForSystemChord("z")
*$f:: FlushWinForSystemChord("f")
*$q:: FlushWinForSystemChord("q")
*$y:: FlushWinForSystemChord("y")
*$o:: FlushWinForSystemChord("o")
*$j:: FlushWinForSystemChord("j")
*$,:: FlushWinForSystemChord(",")
*$.:: FlushWinForSystemChord(".")
#HotIf

; =================================================
;  Paste queue: Ctrl+Shift+C / Ctrl+Shift+V
;  (^+c / dbeaver+goland ^+v moved here from 快捷键4)
; =================================================     
PasteQueueModeActive(*) {
    global pasteQueueMode
    return !!pasteQueueMode
}
ShiftVLegacyTarget(*) {
    return WinActive("ahk_exe dbeaver.exe") || WinActive("ahk_exe datagrip64.exe")
        || WinActive("ahk_exe goland64.exe")
}

NoteQueueGroupFromItem(item) {
    global pasteQueueGroupId
    if !IsObject(item)
        return
    g := (item.HasProp("queueGroup") ? Integer(item.queueGroup) : 0)
    if g > pasteQueueGroupId
        pasteQueueGroupId := g
}

; Sync sidecar: UI queue lines survive restart even if NDJSON patch lags
LoadQueueMeta(*) {
    global QUEUE_META_FILE, queueMetaMap, pasteQueueGroupId
    queueMetaMap := Map()
    if !FileExist(QUEUE_META_FILE)
        return
    try {
        loop read QUEUE_META_FILE, "UTF-8" {
            line := Trim(A_LoopReadLine)
            if line = "" || SubStr(line, 1, 1) = "#"
                continue
            parts := StrSplit(line, "`t")
            if parts.Length < 3
                continue
            uid := Integer(parts[1])
            g := Integer(parts[2])
            i := Integer(parts[3])
            if uid < 1 || g < 1
                continue
            queueMetaMap[String(uid)] := { g: g, i: i }
            if g > pasteQueueGroupId
                pasteQueueGroupId := g
        }
        ClipLog("LoadQueueMeta n=" queueMetaMap.Count " maxGroup=" pasteQueueGroupId)
    } catch as e {
        ClipLogErr("LoadQueueMeta", e)
    }
}

SaveQueueMeta(*) {
    global QUEUE_META_FILE, CLIP_V1_DIR, queueMetaMap
    try DirCreate(CLIP_V1_DIR)
    out := ""
    if IsObject(queueMetaMap) {
        for key, meta in queueMetaMap {
            if !IsObject(meta)
                continue
            out .= Integer(key) "`t" Integer(meta.g) "`t" Integer(meta.i) "`n"
        }
    }
    AtomicWriteText(QUEUE_META_FILE, out)
}

UpsertQueueMeta(uid, g, i) {
    global queueMetaMap
    uid := Integer(uid)
    g := Integer(g)
    i := Integer(i)
    if uid < 1 || g < 1
        return
    if !IsObject(queueMetaMap)
        queueMetaMap := Map()
    ; String key — avoids AHK Map int/string Has() mismatches
    queueMetaMap[String(uid)] := { g: g, i: i }
    SaveQueueMeta()
}

RemapPasteQueueUid(oldUid, newUid) {
    global pasteQueueIds, queueMetaMap
    oldUid := Integer(oldUid)
    newUid := Integer(newUid)
    if oldUid < 1 || newUid < 1 || oldUid = newUid
        return
    if IsObject(pasteQueueIds) {
        for i, id in pasteQueueIds {
            if Integer(id) = oldUid
                pasteQueueIds[i] := newUid
        }
    }
    if IsObject(queueMetaMap) && queueMetaMap.Has(String(oldUid)) {
        meta := queueMetaMap[String(oldUid)]
        queueMetaMap.Delete(String(oldUid))
        if IsObject(meta)
            queueMetaMap[String(newUid)] := meta
        SaveQueueMeta()
    }
    ClipLog("PasteQueue remap uid " oldUid " -> " newUid)
}

ApplyQueueMetaToItem(item) {
    global queueMetaMap
    if !IsObject(item) || !IsObject(queueMetaMap)
        return
    uid := item.HasProp("uid") ? Integer(item.uid) : 0
    if uid < 1
        return
    key := String(uid)
    if !queueMetaMap.Has(key)
        return
    meta := queueMetaMap[key]
    if !IsObject(meta)
        return
    if Integer(meta.g) > 0 {
        item.queueGroup := Integer(meta.g)
        item.queueIndex := Integer(meta.i)
    }
}

SavePasteQueueState(*) {
    global QUEUE_STATE_FILE, CLIP_V1_DIR, pasteQueueMode, pasteQueueIds, pasteQueueDone, pasteQueueGroupId
    try DirCreate(CLIP_V1_DIR)
    ids := ""
    if IsObject(pasteQueueIds) {
        for i, id in pasteQueueIds
            ids .= (i > 1 ? "," : "") Integer(id)
    }
    out := "{"
    out .= '"mode":' (pasteQueueMode ? "true" : "false") ","
    out .= '"groupId":' Integer(pasteQueueGroupId) ","
    out .= '"done":' Integer(pasteQueueDone) ","
    out .= '"ids":"' ids '"'
    out .= "}"
    AtomicWriteText(QUEUE_STATE_FILE, out)
}

LoadPasteQueueState(*) {
    global QUEUE_STATE_FILE, pasteQueueMode, pasteQueueIds, pasteQueueDone, pasteQueueGroupId
    if !FileExist(QUEUE_STATE_FILE)
        return
    try {
        raw := FileRead(QUEUE_STATE_FILE, "UTF-8")
        mode := RegExMatch(raw, '"mode"\s*:\s*(true|false)', &m) ? (m[1] = "true") : false
        g := JsonFieldInt(raw, "groupId")
        done := JsonFieldInt(raw, "done")
        idsRaw := JsonFieldStr(raw, "ids")
        if g > pasteQueueGroupId
            pasteQueueGroupId := g
        pasteQueueDone := Max(0, done)
        pasteQueueIds := []
        if idsRaw != "" {
            for part in StrSplit(idsRaw, ",") {
                part := Trim(part)
                if part != ""
                    pasteQueueIds.Push(Integer(part))
            }
        }
        pasteQueueMode := mode && pasteQueueIds.Length > 0
        if pasteQueueMode
            ClipLog("PasteQueue restored n=" pasteQueueIds.Length " group=" pasteQueueGroupId " done=" pasteQueueDone)
        else {
            pasteQueueMode := false
            pasteQueueIds := []
            pasteQueueDone := 0
        }
    } catch as e {
        ClipLogErr("LoadPasteQueueState", e)
    }
}

; Start/continue queue + copy selection (counts as queue item)
$^+c:: {
    QueueCopyHotkey()
}

; 标记键盘复制，供 ClipChanged 区分「Ctrl+C」与「Ctrl+鼠标点击复制」
~^c:: {
    global lastKeyboardCopyAt
    lastKeyboardCopyAt := A_TickCount
}
~^x:: {
    global lastKeyboardCopyAt
    lastKeyboardCopyAt := A_TickCount
}

; Ctrl+左键：开 1.5s 窗口，等网页异步写入剪贴板（此时 Ctrl 往往已松开）
~*LButton:: {
    global ctrlMouseCopyUntil
    if GetKeyState("Ctrl", "P") && !GetKeyState("Shift", "P") && !GetKeyState("Alt", "P")
        ctrlMouseCopyUntil := A_TickCount + 1500
}

; Queue on: Ctrl+V = FIFO paste. Queue off: let OS / 快捷键4 handle Ctrl+V.
#HotIf PasteQueueModeActive()
$^v:: {
    global queueFifoPasteding, pasteSending, queueFifoPasteAt
    ; Only block while a paste is actually running (was 280ms after-start → ate next Ctrl+V)
    if queueFifoPasteding
        return
    ; Ignore keyboard auto-repeat only
    if (A_TickCount - queueFifoPasteAt) < 70
        return
    if pasteSending && (A_TickCount - queueFifoPasteAt) < 50
        return
    PasteQueueFifo()
}
#HotIf

; Ctrl+Shift+V:
; - 队列开启：出队到剪贴板，若在 DBeaver/DataGrip/GoLand 再跑原有转换后粘贴；否则普通出队粘贴
; - 队列关闭：仅在上述 IDE 里做原有转换粘贴
$^+v:: {
    global queueFifoPasteding, pasteSending, queueFifoPasteAt
    if PasteQueueModeActive() {
        if queueFifoPasteding
            return
        if (A_TickCount - queueFifoPasteAt) < 70
            return
        if pasteSending && (A_TickCount - queueFifoPasteAt) < 50
            return
        PasteQueueFifo(true)
        return
    }
    if !ShiftVLegacyTarget()
        return
    if WinActive("ahk_exe dbeaver.exe") || WinActive("ahk_exe datagrip64.exe")
        LegacyDbeaverShiftV()
    else if WinActive("ahk_exe goland64.exe")
        LegacyGolandShiftV()
}

; Tiny OS ToolTip at cursor — Gui tip was blocking ^+c / Ctrl+V (AHK single thread)
ShowQueueTip(title, sub := "", ms := 900) {
    ; Defer so paste/copy hotkey finishes Send first
    SetTimer(ShowQueueTipNow.Bind(String(title), String(sub), Integer(ms)), -80)
}

ShowQueueTipNow(title, sub := "", ms := 900) {
    global queueTipSeq
    queueTipSeq += 1
    seq := queueTipSeq
    text := Trim(String(title))
    ; Keep one short line by default; sub only if title is very short
    if text = "" && sub != ""
        text := Trim(String(sub))
    CoordMode "Mouse", "Screen"
    CoordMode "ToolTip", "Screen"
    MouseGetPos(&mx, &my)
    try ToolTip text, mx + 12, my + 14
    SetTimer(HideQueueTip.Bind(seq), -Max(500, Integer(ms)))
}

HideQueueTip(seq := 0) {
    global queueTipSeq
    if seq && seq != queueTipSeq
        return
    try ToolTip()
}

QueueCopyHotkey(*) {
    global pasteQueueMode, pasteQueueIds, pasteQueueGroupId, pasteQueueDone, queueCaptureArmed, queueSuppressExit, queueCopyGen
    ; Drop uids deleted from history; if none left, start a fresh session at 队列 +1
    PrunePasteQueueIds()
    if !pasteQueueMode || !pasteQueueIds.Length {
        pasteQueueMode := true
        pasteQueueIds := []
        pasteQueueDone := 0
        pasteQueueGroupId += 1
        ClipLog("PasteQueue new session group=" pasteQueueGroupId)
    }
    queueCaptureArmed := true
    queueSuppressExit := true
    queueCopyGen += 1
    gen := queueCopyGen
    ClipLog("PasteQueue hotkey ^+c armed group=" pasteQueueGroupId " n=" pasteQueueIds.Length)
    ; Holding Ctrl+Shift+C: {Blind}{Shift up} does NOT clear physical Shift, so the
    ; following ^c arrives as Ctrl+Shift+C and many apps never copy. Force real key-ups.
    SendInput "{LShift up}{RShift up}"
    Sleep 25
    ; Ctrl may stay physically down — that is correct for Ctrl+C
    SendInput "^c"
    SetTimer(() => (queueSuppressExit := false), -600)
    ; Allow app time to update clipboard; also covers "clipboard unchanged" after delete
    SetTimer(QueueCopyCatchup.Bind(gen), -250)
    SetTimer(ClearStaleQueueArm.Bind(gen), -3000)
}

; Remove FIFO slots whose clips were deleted (meta cleared in DeleteItem)
PrunePasteQueueIds(*) {
    global pasteQueueMode, pasteQueueIds, pasteQueueDone, queueCaptureArmed
    if !IsObject(pasteQueueIds) || !pasteQueueIds.Length
        return
    kept := []
    for id in pasteQueueIds {
        if PasteQueueUidAlive(Integer(id))
            kept.Push(Integer(id))
    }
    removed := pasteQueueIds.Length - kept.Length
    pasteQueueIds := kept
    if removed > 0
        ClipLog("PasteQueue prune removed=" removed " left=" pasteQueueIds.Length)
    if pasteQueueMode && !pasteQueueIds.Length {
        ; End session so next ^+c opens 队列 +1 (not +4 after deleting old rows)
        pasteQueueMode := false
        pasteQueueDone := 0
        queueCaptureArmed := false
        SavePasteQueueState()
        ClipLog("PasteQueue prune → session ended")
    } else if removed > 0 && pasteQueueMode {
        SavePasteQueueState()
    }
}

PasteQueueUidAlive(uid) {
    global clips, liveFront, queueMetaMap
    uid := Integer(uid)
    if uid < 1
        return false
    if IsObject(liveFront) {
        for c in liveFront {
            if IsObject(c) && Integer(c.uid) = uid
                return true
        }
    }
    if IsObject(clips) {
        for c in clips {
            if IsObject(c) && Integer(c.uid) = uid
                return true
        }
    }
    ; DeleteItem removes meta; if meta gone and not in memory → treat as deleted
    if IsObject(queueMetaMap) && queueMetaMap.Has(String(uid))
        return true
    return false
}

ClearStaleQueueArm(gen) {
    global queueCaptureArmed, queueCopyGen
    if queueCopyGen = gen && queueCaptureArmed
        queueCaptureArmed := false
}

; If ClipChanged skipped (same clipboard bytes), still join the queue
QueueCopyCatchup(gen) {
    global queueCaptureArmed, queueCopyGen, lastTxt, pasteQueueMode
    if queueCopyGen != gen || !queueCaptureArmed || !pasteQueueMode
        return
    txt := ""
    try txt := A_Clipboard
    if txt = "" {
        Sleep 40
        try txt := A_Clipboard
    }
    if txt = ""
        return
    ClipLog("PasteQueue catchup force-add len=" StrLen(txt))
    ; Allow duplicate of lastTxt — this path exists specifically for unchanged clipboard
    item := {
        uid: NextClipUid(),
        type: "text",
        data: txt,
        time: FormatTime(, "yyyy-MM-dd HH:mm:ss"),
        pinned: false,
        pasted: false,
        preview: SubStr(txt, 1, 500),
        charCount: StrLen(txt),
        fileCount: 0,
        width: 0,
        height: 0,
        imgFile: ""
    }
    try item.isMd := TextLooksLikeMarkdown(txt)
    try item.isRich := ClipboardHasRichText()
    ApplyClipSrc(item)
    ; Skip MemoryTake so a deleted-but-still-on-OS-clip row gets a fresh queue slot
    lastTxt := txt
    MemoryInsertFront(item)
    EnqueuePasteQueueItem(item)
    RequestUiPush()
}

EnqueuePasteQueueItem(item) {
    global pasteQueueMode, pasteQueueIds, pasteQueueGroupId, queueCaptureArmed
    if !pasteQueueMode || !queueCaptureArmed || !IsObject(item)
        return
    queueCaptureArmed := false
    item.queueGroup := pasteQueueGroupId
    pasteQueueIds.Push(Integer(item.uid))
    item.queueIndex := pasteQueueIds.Length
    n := pasteQueueIds.Length
    ClipLog("PasteQueue enqueue uid=" item.uid " n=" n " group=" pasteQueueGroupId)
    ; Fast path only: TSV meta + paste_queue.json (restart-safe for blue lines).
    ; NEVER PersistNewItem here — disk I/O blocks the AHK thread and makes ^+c #3+ feel dead.
    try UpsertQueueMeta(Integer(item.uid), Integer(item.queueGroup), Integer(item.queueIndex))
    catch as e
        ClipLogErr("PasteQueue UpsertQueueMeta", e)
    try SavePasteQueueState()
    catch as e
        ClipLogErr("PasteQueue SavePasteQueueState", e)
    item._queuePersistQueued := true
    ; Persist ASAP without DiskRemove scan (see PersistNewItem keepQg path) — front of disk queue
    PrependDiskJob(PersistNewItem.Bind(item))
    if n = 1
        ShowQueueTip("队列 +1", "", 800)
    else
        ShowQueueTip("队列 +" n, "", 700)
}

; Right-click: restart FIFO from this queue item (same queueGroup)
ResetPasteQueueFrom(uid) {
    global pasteQueueMode, pasteQueueIds, pasteQueueDone, pasteQueueGroupId, queueCaptureArmed
    global clips, liveFront, panelVisible, queueMetaMap, uiPinned
    uid := Integer(uid)
    it := ResolveClip(uid)
    g := 0
    startIdx := 0
    if IsObject(it) {
        g := (it.HasProp("queueGroup") && Integer(it.queueGroup) > 0) ? Integer(it.queueGroup) : 0
        startIdx := (it.HasProp("queueIndex") && Integer(it.queueIndex) > 0) ? Integer(it.queueIndex) : 0
    }
    ; Fall back to sidecar meta when ResolveClip misses (item not in current page)
    if g < 1 && IsObject(queueMetaMap) && queueMetaMap.Has(String(uid)) {
        meta := queueMetaMap[String(uid)]
        if IsObject(meta) {
            g := Integer(meta.g)
            startIdx := Integer(meta.i)
        }
    }
    if g < 1 {
        ShowQueueTip("非队列项", "", 700)
        return
    }
    if startIdx < 1
        startIdx := 1

    members := [] ; {uid, qi}
    seen := Map()
    AddMember(id, qi) {
        id := Integer(id)
        qi := Integer(qi)
        if id < 1 || qi < 1
            return
        if qi < startIdx
            return
        if seen.Has(id)
            return
        seen[id] := true
        members.Push({ uid: id, qi: qi })
    }

    ; 1) Authoritative: queue_meta.tsv (survives page unload / restart)
    if IsObject(queueMetaMap) {
        for key, meta in queueMetaMap {
            if !IsObject(meta) || Integer(meta.g) != g
                continue
            AddMember(Integer(key), Integer(meta.i))
        }
    }
    ; 2) Active FIFO ids (same group session)
    if IsObject(pasteQueueIds) {
        for id in pasteQueueIds {
            id := Integer(id)
            qi := 0
            if IsObject(queueMetaMap) && queueMetaMap.Has(String(id))
                qi := Integer(queueMetaMap[String(id)].i)
            if qi < 1 {
                c := ResolveClip(id)
                if IsObject(c) && c.HasProp("queueIndex")
                    qi := Integer(c.queueIndex)
            }
            if qi < 1
                qi := id
            AddMember(id, qi)
        }
    }
    ; 3) In-memory clips / liveFront
    CollectMem(c) {
        if !IsObject(c) || !c.HasProp("uid")
            return
        if !(c.HasProp("queueGroup") && Integer(c.queueGroup) = g)
            return
        qi := (c.HasProp("queueIndex") && Integer(c.queueIndex) > 0) ? Integer(c.queueIndex) : Integer(c.uid)
        AddMember(Integer(c.uid), qi)
    }
    if IsObject(clips) {
        for c in clips
            CollectMem(c)
    }
    if IsObject(liveFront) {
        for c in liveFront
            CollectMem(c)
    }
    ; Always include the clicked item
    AddMember(uid, startIdx)

    if members.Length < 1
        return
    ; Sort by queueIndex ascending (FIFO)
    loop members.Length - 1 {
        i := 1
        while i <= members.Length - A_Index {
            if members[i].qi > members[i + 1].qi {
                tmp := members[i]
                members[i] := members[i + 1]
                members[i + 1] := tmp
            }
            i += 1
        }
    }
    startAt := 1
    for i, m in members {
        if m.uid = uid {
            startAt := i
            break
        }
    }
    newIds := []
    i := startAt
    while i <= members.Length {
        newIds.Push(members[i].uid)
        i += 1
    }
    pasteQueueMode := true
    pasteQueueIds := newIds
    pasteQueueDone := 0
    pasteQueueGroupId := g
    queueCaptureArmed := false
    MarkItemsUnpasted(newIds)
    n := newIds.Length
    ShowQueueTip("队列 重置 +" n, "", 800)
    ; Keep panel open so gray rails are visible; only soft-hide when unpinned after a beat
    if panelVisible
        SetTimer(() => PushClips(false), -50)
    ClipLog("PasteQueue resetFrom uid=" uid " n=" n " group=" g " startIdx=" startIdx)
    SavePasteQueueState()
}

MarkItemsUnpasted(uids) {
    global clips, viewCache, liveFront, wvCore
    want := Map()
    idList := []
    for uid in uids {
        id := Integer(uid)
        if id < 1
            continue
        want[id] := true
        idList.Push(id)
    }
    if !want.Count
        return
    for c in clips {
        if want.Has(c.uid)
            c.pasted := false
    }
    if IsObject(liveFront) {
        for c in liveFront {
            if IsObject(c) && want.Has(c.uid)
                c.pasted := false
        }
    }
    for , entry in viewCache {
        if !IsObject(entry) || !entry.HasProp("items")
            continue
        for c in entry.items {
            if want.Has(c.uid)
                c.pasted := false
        }
    }
    EnqueueDiskJob(DiskSetPasted.Bind(want, false))
    ; Instant gray rails / clear ✓ — same path as mark pasted
    if IsObject(wvCore) && idList.Length {
        jsIds := ""
        for i, id in idList
            jsIds .= (i > 1 ? "," : "") id
        try wvCore.ExecuteScriptAsync("window.__markUnpasted&&window.__markUnpasted([" jsIds "])")
    }
}

ExitPasteQueue(reason := "") {
    global pasteQueueMode, pasteQueueIds, pasteQueueDone, queueCaptureArmed
    if !pasteQueueMode && !pasteQueueIds.Length
        return
    ClipLog("PasteQueue exit reason=" reason " left=" pasteQueueIds.Length)
    pasteQueueMode := false
    pasteQueueIds := []
    pasteQueueDone := 0
    queueCaptureArmed := false
    SavePasteQueueState()
    if reason = "foreign-clip" || reason = "deleted-all" || reason = "clear-tab"
        ShowQueueTip("队列结束", "", 700)
}

PasteQueueFifo(useLegacy := false) {
    global pasteQueueMode, pasteQueueIds, pasteQueueDone, clipIgnore, queueFifoPasteding, queueFifoPasteAt, uiPinned, panelVisible
    if queueFifoPasteding
        return
    if !pasteQueueMode && !(IsObject(pasteQueueIds) && pasteQueueIds.Length) {
        return
    }
    pasteQueueMode := true
    if !pasteQueueIds.Length {
        ExitPasteQueue("empty")
        return
    }
    queueFifoPasteding := true
    queueFifoPasteAt := A_TickCount
    clipIgnore := true
    pastedOk := false
    uid := 0
    didLegacy := false
    try {
        ; Peek first — only dequeue after a successful paste
        uid := Integer(pasteQueueIds[1])
        item := ResolveClip(uid)
        if !IsObject(item) {
            ClipLog("PasteQueueFifo miss uid=" uid " —drop dead slot")
            pasteQueueIds.RemoveAt(1)
            SetTimer(SavePasteQueueState, -1)
            ShowQueueTip("队列 缺项 跳过", "", 700)
            if !pasteQueueIds.Length
                ExitPasteQueue("missing-empty")
            return
        }
        EnsureClipBodyLoaded(item)
        ; Panel open: hide first so Send ^v goes to the editor
        if panelVisible && !uiPinned
            HidePanel()
        ok := false
        if item.type = "file" {
            paths := GetItemFilePaths(item)
            if paths.Length
                ok := SetClipboardFiles(paths)
        } else if item.type = "image" {
            paths := BuildAhkNamedPastePaths([item])
            if paths.Length
                ok := SetClipboardFiles(paths)
        }
        if !ok
            ok := PutItemOnClipboard(item)
        if !ok {
            ClipLog("PasteQueueFifo put fail uid=" uid " type=" item.type)
            ShowQueueTip("队列 粘贴失败", "", 800)
            return
        }
        target := ResolvePasteTargetWin()
        if !target {
            try target := WinExist("A")
        }
        if target
            DllCall("SetForegroundWindow", "Ptr", target)
        ; Paste ASAP — mark/tip/save after (old order felt like dead Ctrl+V)
        if useLegacy && ShiftVLegacyTarget() {
            if WinActive("ahk_exe dbeaver.exe") || WinActive("ahk_exe datagrip64.exe")
                didLegacy := LegacyDbeaverShiftV()
            else if WinActive("ahk_exe goland64.exe")
                didLegacy := LegacyGolandShiftV()
        }
        if !didLegacy
            TriggerPasteKey()
        pasteQueueIds.RemoveAt(1)
        pasteQueueDone += 1
        pastedOk := true
        queueFifoPasteAt := A_TickCount
        MarkItemsPasted([uid])
        done := pasteQueueDone
        left := pasteQueueIds.Length
        if left = 0 {
            ShowQueueTip("队列 完成 -" done, "", 800)
            ExitPasteQueue("drained")
        } else {
            ShowQueueTip("队列 -" done " 剩" left, "", 700)
            SetTimer(SavePasteQueueState, -1)
        }
        ClipLog("PasteQueueFifo ok uid=" uid " left=" left " legacy=" (didLegacy ? 1 : 0))
    } finally {
        queueFifoPasteding := false
        SetTimer(() => (clipIgnore := false), -200)
        if uiPinned && panelVisible
            SetTimer(RaiseClipboardPanel, -50)
    }
    if !pastedOk && uid > 0
        ClipLog("PasteQueueFifo aborted uid=" uid " kept in queue")
}

ClipArrHas(arr, value) {
    for item in arr {
        if item == value
            return A_Index
    }
    return 0
}
ClipStrEndWith(str, sub) {
    if !InStr(str, sub)
        return 0
    return SubStr(str, StrLen(str) - StrLen(sub) + 1) == sub ? 1 : 0
}
ClipJoinArr(arr, separator := ",", L := "[", R := "]", quote := "") {
    out := L
    for i, v in arr {
        if i > 1
            out .= separator
        out .= quote v quote
    }
    return out R
}
ClipUnderlineToPascal(selectStr) {
    selectStr := String(selectStr)
    if InStr(selectStr, "_") {
        camel := ""
        Loop Parse selectStr, "_" {
            if A_Index = 1
                camel := A_LoopField
            else
                camel .= StrUpper(SubStr(A_LoopField, 1, 1)) StrLower(SubStr(A_LoopField, 2))
        }
        selectStr := camel
    }
    return RegExReplace(selectStr, "(\b\w)", "$U1")
}

LegacyDbeaverShiftV(*) {
    global clipIgnore, pasteSending, queueFifoPasteAt
    clip := A_Clipboard
    if InStr(Trim(clip), "('") = 1
        return false
    strArr := []
    delim := ClipStrEndWith(Trim(clip), "|") ? "|" : "`n"
    Loop Parse clip, delim {
        currentLine := Trim(Trim(A_LoopField), "`r`n")
        if currentLine != "" && !ClipArrHas(strArr, currentLine)
            strArr.Push(currentLine)
    }
    if !strArr.Length
        return false
    caseA := ClipJoinArr(strArr, ",", "", "", "")
    caseB := strArr.Length <= 2
        ? ClipJoinArr(strArr, ",", "(", ")", "'")
        : ClipJoinArr(strArr, ",`n", "(", ")", "'")
    clipIgnore := true
    pasteSending := true
    queueFifoPasteAt := A_TickCount
    ok := false
    try {
        A_Clipboard := ClipStrEndWith(Trim(clip), "|") ? caseA : (caseB . ";")
        Sleep 50
        TriggerPasteKey()
        ok := true
    } finally {
        SetTimer(() => (clipIgnore := false), -400)
    }
    return ok
}

LegacyGolandShiftV(*) {
    global clipIgnore, pasteSending, queueFifoPasteAt
    clip := A_Clipboard
    if !InStr(Trim(clip), "|")
        return false
    strArr := [""]
    Loop Parse clip, "|" {
        currentLine := Trim(Trim(A_LoopField), "`r`n")
        if currentLine = "" || ClipArrHas(strArr, currentLine)
            continue
        fieldType := " string"
        if ClipArrHas(["created_at", "updated_at"], currentLine)
            fieldType := " time.Time"
        strArr.Push(ClipUnderlineToPascal(currentLine) . fieldType . ' ``json:"' . currentLine . '"``')
    }
    if strArr.Length < 2
        return false
    caseA := ClipJoinArr(strArr, "`n", "", "", "")
    clipIgnore := true
    pasteSending := true
    queueFifoPasteAt := A_TickCount
    ok := false
    try {
        A_Clipboard := caseA
        Sleep 50
        TriggerPasteKey()
        ok := true
    } finally {
        SetTimer(() => (clipIgnore := false), -400)
    }
    return ok
}

; ?? / ？？：不要注册 ~?（中文键盘布局没有独立问号键，会弹 AHK 提示且热键无效）
QQInstallSearchHotkeys()
StartCaretWatcher()
SetTimer(RememberGoodActiveWin, 1000)
ClipLog("=== SCRIPT BOOT auto-execute END —waiting for clipReady ===")

; 启动立刻后台预热：先出骨架，再加载完整 UI（把 ~2s 挪到脚本启动后）
SetTimer(WarmWebViewEarly, -1)

; =================================================
;  Init: create ahk\clip_v1 dirs and write HTML
; =================================================
EnsureDataDir() {
    global CLIP_V1_DIR, HTML_FILE, STORE_DIR, PAGES_DIR, PAYLOAD_DIR
    try DirCreate CLIP_V1_DIR
    try DirCreate STORE_DIR
    try DirCreate PAGES_DIR
    try DirCreate PAYLOAD_DIR
    WriteHtmlFile()
}

; Arm clipboard AFTER disk init. Early OnClipboardChange raced boot and crashed on first copy.
EnableClipboardWatch(*) {
    static registered := false
    if !registered {
        OnClipboardChange ClipChanged
        registered := true
        ClipLog("OnClipboardChange registered")
    }
    ; Brief settle so auto-execute / tray finish before accepting copies
    SetTimer(ArmClipboardReady, -1000)
    ; Was 2s file IO → busy cursor; only heartbeat when panel open / slow interval
    SetTimer(ClipLogHeartbeat, 15000)
    ClipLog("ArmClipboardReady in 1000ms + heartbeat 2s")
}

ArmClipboardReady(*) {
    global clipReady, pasteQueueMode, pasteQueueIds
    clipReady := true
    ClipLog("clipReady=TRUE —accepting clipboard now")
    if pasteQueueMode && IsObject(pasteQueueIds) && pasteQueueIds.Length > 0
        SetTimer(() => ShowQueueTip("队列 恢复 +" pasteQueueIds.Length, "", 900), -800)
}

ClipLogHeartbeat(*) {
    global clipReady, diskScanBusy, diskJobBusy, diskJobQueue, panelVisible, wvBuilding, clips
    if !panelVisible
        return
    q := 0
    try q := diskJobQueue.Length
    n := 0
    try n := clips.Length
    ClipLog("HB ready=" clipReady " scan=" diskScanBusy " jobBusy=" diskJobBusy
        . " q=" q " panel=" panelVisible " wvBuild=" wvBuilding " clips=" n)
}

WriteHtmlFile() {
    global HTML_FILE, HTML_B64, CLIP_V1_DIR, UI_CACHE_VER
    ; 未变更则跳过写入，避免 mtime 变了导致 WebView 每次冷加载 ~2s
    if FileExist(HTML_FILE) {
        try {
            existing := FileRead(HTML_FILE, "UTF-8")
            ver := UiCacheVer()
            if ver != "" && InStr(existing, 'data-ui-ver="' ver '"') {
                ClipLog("WriteHtmlFile SKIP unchanged ver=" ver)
                return
            }
        } catch {
        }
    }
    B64DecodeToFile(HTML_B64, HTML_FILE)
    ClipLog("WriteHtmlFile -> " HTML_FILE " ver=" UiCacheVer())
}

; =================================================
;  Ctrl+V: save clipboard image(s) into the active folder (not ahk\clip_v1)
; =================================================
; =================================================
;  Recent Explorer folders (double-click into dir -> "最近" tab)
; =================================================
NormalizeFolderPath(path) {
    path := Trim(String(path))
    if path = ""
        return ""
    try path := RTrim(path, "\/")
    try {
        n := DllCall("kernel32\GetLongPathNameW", "WStr", path, "Ptr", 0, "UInt", 0, "UInt")
        if n > 0 {
            buf := Buffer(n * 2)
            if DllCall("kernel32\GetLongPathNameW", "WStr", path, "Ptr", buf, "UInt", n, "UInt")
                path := RTrim(StrGet(buf, "UTF-16"), "\/")
        }
    }
    return path
}

IsDesktopFolderPath(path) {
    path := NormalizeFolderPath(path)
    if path = ""
        return true
    p := StrLower(path)
    d1 := StrLower(NormalizeFolderPath(A_Desktop))
    d2 := StrLower(NormalizeFolderPath(A_DesktopCommon))
    if d1 != "" && p = d1
        return true
    if d2 != "" && p = d2
        return true
    if InStr(p, "::{") = 1
        return true
    return false
}

; Skip drive roots like C:\ / D:\ and bare UNC shares
IsDriveRootFolderPath(path) {
    path := NormalizeFolderPath(path)
    if path = ""
        return true
    if RegExMatch(path, "i)^[a-z]:\\?$")
        return true
    if RegExMatch(path, "^\\\\[^\\]+\\[^\\]+$")
        return true
    return false
}

RecentPathIsParentOf(parent, child) {
    parent := StrLower(NormalizeFolderPath(parent))
    child := StrLower(NormalizeFolderPath(child))
    if parent = "" || child = "" || parent = child
        return false
    return InStr(child "\", parent "\") = 1
}

UnescapeJsonStr(s) {
    s := String(s)
    s := StrReplace(s, "\\", "\x00")
    s := StrReplace(s, "\/", "/")
    s := StrReplace(s, '\"', '"')
    s := StrReplace(s, "\n", "`n")
    s := StrReplace(s, "\r", "`r")
    s := StrReplace(s, "\t", "`t")
    s := StrReplace(s, "\x00", "\")
    return s
}

MakeRecentFolderItem(uid, path, time := "", pinned := false) {
    if time = ""
        time := FormatTime(, "yyyy-MM-dd HH:mm:ss")
    return {
        uid: Integer(uid),
        type: "recent",
        time: time,
        pinned: !!pinned,
        pasted: false,
        charCount: StrLen(path),
        fileCount: 0,
        width: 0,
        height: 0,
        preview: path,
        data: path,
        imgFile: "",
        favTitle: "",
        favGroup: "",
        linkTitle: "",
        linkHost: "",
        srcIcon: "",
        srcExe: "",
        srcTitle: "",
        isMd: false,
        isRich: false
    }
}

IsRecentFolderPinned(c) {
    return IsObject(c) && c.HasProp("pinned") && c.pinned
}

TrimRecentFoldersToMax(*) {
    global recentFolders, MAX_RECENT_FOLDERS
    if !IsObject(recentFolders)
        return
    while recentFolders.Length > MAX_RECENT_FOLDERS {
        removed := false
        i := recentFolders.Length
        while i >= 1 {
            if !IsRecentFolderPinned(recentFolders[i]) {
                recentFolders.RemoveAt(i)
                removed := true
                break
            }
            i -= 1
        }
        if !removed
            break
    }
}

RecentFoldersHasEvictable(*) {
    global recentFolders
    if !IsObject(recentFolders)
        return false
    for c in recentFolders {
        if !IsRecentFolderPinned(c)
            return true
    }
    return false
}

LoadRecentFolders(*) {
    global recentFolders, recentFolderUidSeq, RECENT_FOLDERS_FILE, MAX_RECENT_FOLDERS
    recentFolders := []
    if !FileExist(RECENT_FOLDERS_FILE)
        return
    try {
        raw := FileRead(RECENT_FOLDERS_FILE, "UTF-8")
        raw := Trim(raw)
        if raw = "" || SubStr(raw, 1, 1) != "["
            return
        pos := 1
        while RegExMatch(raw, '\{[^{}]*\}', &m, pos) {
            block := m[0]
            path := ""
            if RegExMatch(block, '"path"\s*:\s*"((?:\\.|[^"\\])*)"', &pm)
                path := UnescapeJsonStr(pm[1])
            path := NormalizeFolderPath(path)
            if path = "" || IsDesktopFolderPath(path) || IsDriveRootFolderPath(path) {
                pos := m.Pos + m.Len
                continue
            }
            uid := 0
            if RegExMatch(block, '"uid"\s*:\s*(-?\d+)', &um)
                uid := Integer(um[1])
            if uid < 1
                uid := ++recentFolderUidSeq
            else if uid >= recentFolderUidSeq
                recentFolderUidSeq := uid
            time := ""
            if RegExMatch(block, '"time"\s*:\s*"((?:\\.|[^"\\])*)"', &tm)
                time := UnescapeJsonStr(tm[1])
            if time = ""
                time := FormatTime(, "yyyy-MM-dd HH:mm:ss")
            pinned := false
            if RegExMatch(block, '"pinned"\s*:\s*(true|false|1|0)', &pim)
                pinned := (pim[1] = "true" || pim[1] = "1")
            recentFolders.Push(MakeRecentFolderItem(uid, path, time, pinned))
            pos := m.Pos + m.Len
            if recentFolders.Length >= MAX_RECENT_FOLDERS
                break
        }
    } catch as e {
        ClipLogErr("LoadRecentFolders", e)
        recentFolders := []
    }
}

SaveRecentFolders(*) {
    global recentFolders, RECENT_FOLDERS_FILE, CLIP_V1_DIR
    try {
        if !DirExist(CLIP_V1_DIR)
            DirCreate CLIP_V1_DIR
        out := "["
        first := true
        if IsObject(recentFolders) {
            for c in recentFolders {
                if !first
                    out .= ","
                first := false
                path := c.HasProp("data") ? String(c.data) : String(c.preview)
                out .= "{"
                out .= '"uid":' Integer(c.uid) ","
                out .= '"path":' JsonStr(path) ","
                out .= '"time":' JsonStr(c.HasProp("time") ? c.time : "") ","
                out .= '"pinned":' (IsRecentFolderPinned(c) ? "true" : "false")
                out .= "}"
            }
        }
        out .= "]"
        tmp := RECENT_FOLDERS_FILE ".tmp"
        if FileExist(tmp)
            try FileDelete tmp
        FileAppend out, tmp, "UTF-8"
        if FileExist(RECENT_FOLDERS_FILE)
            try FileDelete RECENT_FOLDERS_FILE
        FileMove tmp, RECENT_FOLDERS_FILE
    } catch as e {
        ClipLogErr("SaveRecentFolders", e)
    }
}

RecordRecentFolder(path) {
    global recentFolders, recentFolderUidSeq, MAX_RECENT_FOLDERS, viewTab, viewQuery, viewToday, panelVisible
    path := NormalizeFolderPath(path)
    if path = "" || IsDesktopFolderPath(path) || IsDriveRootFolderPath(path)
        return false
    if !DirExist(path)
        return false
    key := StrLower(path)
    keptUid := 0
    keptPinned := false
    foundSame := false
    i := 1
    while IsObject(recentFolders) && i <= recentFolders.Length {
        c := recentFolders[i]
        p := StrLower(NormalizeFolderPath(c.HasProp("data") ? c.data : c.preview))
        if p = "" {
            recentFolders.RemoveAt(i)
            continue
        }
        if p = key {
            foundSame := true
            keptUid := Integer(c.uid)
            keptPinned := IsRecentFolderPinned(c)
            recentFolders.RemoveAt(i)
            continue
        }
        if RecentPathIsParentOf(p, key) {
            if IsRecentFolderPinned(c) {
                i += 1
                continue
            }
            recentFolders.RemoveAt(i)
            continue
        }
        i += 1
    }
    if !IsObject(recentFolders)
        recentFolders := []
    if !foundSame && recentFolders.Length >= MAX_RECENT_FOLDERS && !RecentFoldersHasEvictable()
        return false
    if keptUid < 1
        keptUid := ++recentFolderUidSeq
    item := MakeRecentFolderItem(keptUid, path, "", keptPinned)
    recentFolders.InsertAt(1, item)
    TrimRecentFoldersToMax()
    SaveRecentFolders()
    InvalidateRecentViewCaches()
    try CacheRecentFoldersView(false)
    try CacheRecentFoldersView(true)
    if panelVisible && viewTab = "recent" {
        try SetView("recent", viewQuery, viewToday ? "1" : "0")
    }
    return true
}

WatchExplorerFolder(*) {
    global lastExplorerFolder
    try {
        if !(WinActive("ahk_class CabinetWClass") || WinActive("ahk_class ExploreWClass"))
            return
        p := GetActiveFolderPath()
        if p = ""
            return
        p := NormalizeFolderPath(p)
        if p = "" || p = lastExplorerFolder
            return
        lastExplorerFolder := p
        RecordRecentFolder(p)
    }
}

QueryRecentFoldersPage(query, todayOnly, offset, limit) {
    global recentFolders
    ; 按访问时间顺序（newest first），固定项不置顶 — 只防淘汰
    all := []
    if IsObject(recentFolders) {
        for c in recentFolders {
            if !ItemMatchesView(c, "recent", query, todayOnly)
                continue
            all.Push(c)
        }
    }
    items := []
    i := Integer(offset) + 1
    while i <= all.Length && items.Length < limit {
        items.Push(all[i])
        i += 1
    }
    return { items: items, total: all.Length }
}

ClearRecentFolders(*) {
    global recentFolders
    kept := []
    if IsObject(recentFolders) {
        for c in recentFolders {
            if IsRecentFolderPinned(c)
                kept.Push(c)
        }
    }
    recentFolders := kept
    SaveRecentFolders()
}

CacheRecentFoldersView(todayFlag := false) {
    global viewCache, tabTotals, recentFolders, VIEW_PAGE_SIZE
    key := ViewCacheKey("recent", "", todayFlag)
    items := []
    total := 0
    if IsObject(recentFolders) {
        for c in recentFolders {
            if !ItemMatchesTabToday(c, "recent", todayFlag)
                continue
            total += 1
            if items.Length < VIEW_PAGE_SIZE
                items.Push(c)
        }
    }
    viewCache[key] := { items: items, total: total }
    if IsObject(tabTotals)
        tabTotals[key] := total
}

InvalidateRecentViewCaches(*) {
    global viewCache, tabTotals
    if !IsObject(viewCache)
        return
    dropKeys := []
    for key, _ in viewCache {
        tab := "", todayOnly := false, query := ""
        ParseViewCacheKey(key, &tab, &todayOnly, &query)
        if tab = "recent"
            dropKeys.Push(key)
    }
    for key in dropKeys {
        viewCache.Delete(key)
        if IsObject(tabTotals) && tabTotals.Has(key)
            tabTotals.Delete(key)
    }
}


PastePngToDir() {
    hasBmp   := DllCall("IsClipboardFormatAvailable", "UInt", 2, "Int")
    hasDib   := DllCall("IsClipboardFormatAvailable", "UInt", 8, "Int")
    hasFiles := DllCall("IsClipboardFormatAvailable", "UInt", 15, "Int")
    if !hasBmp && !hasDib && !hasFiles
        return

    saveDir := GetActiveFolderPath()
    if saveDir = ""
        return  ; only act when Explorer/Desktop is active

    ; CF_HDROP: copy each image file into the current folder
    if hasFiles {
        files := []
        raw := A_Clipboard
        if raw != "" {
            for ln in StrSplit(raw, "`n", "`r") {
                ln := Trim(ln)
                if ln != ""
                    files.Push(ln)
            }
        }
        if files.Length = 0
            files := GetClipboardFileList()

        stamp := FormatTime(, "yyyyMMdd_HHmmss")
        copied := 0
        for ln in files {
            if ln = "" || !FileExist(ln)
                continue
            ; Skip directories  — never copy/create folder trees
            if InStr(FileExist(ln), "D")
                continue
            dotPos := InStr(ln, ".", false, -1)
            ext := dotPos > 0 ? StrLower(SubStr(ln, dotPos + 1)) : ""
            if !IsImgExt(ext)
                continue
            dest := saveDir "\ahk_" stamp "_" (++copied) "." ext
            try FileCopy ln, dest, 1
        }
        return
    }

    ; Single bitmap/DIB (screenshot, etc.)
    if hasBmp || hasDib {
        stamp   := FormatTime(, "yyyyMMdd_HHmmss")
        imgPath := saveDir "\ahk_" stamp "_1.png"
        SaveClipboardImageToFile(imgPath)
    }
}

; Active Explorer folder, desktop, or empty
GetActiveFolderPath() {
    try {
        if WinActive("ahk_class WorkerW") || WinActive("ahk_class Progman")
            return A_Desktop
        hwnd := WinActive("ahk_class CabinetWClass")
        if !hwnd
            hwnd := WinActive("ahk_class ExploreWClass")
        if !hwnd
            return ""
        for win in ComObject("Shell.Application").Windows {
            try {
                if (win.HWND = hwnd) {
                    path := win.Document.Folder.Self.Path
                    if path != ""
                        return path
                }
            }
        }
    }
    return ""
}

; Enumerate all CF_HDROP paths (supports multi-select; OpenClipboard retry)
GetClipboardFileList() {
    files := []
    opened := false
    loop 10 {
        if DllCall("OpenClipboard", "Ptr", 0) {
            opened := true
            break
        }
        Sleep 20
    }
    if !opened
        return files
    try {
        hDrop := DllCall("GetClipboardData", "UInt", 15, "Ptr")
        if !hDrop
            return files
        cnt := DllCall("shell32\DragQueryFileW", "Ptr", hDrop, "UInt", 0xFFFFFFFF, "Ptr", 0, "UInt", 0, "UInt")
        loop cnt {
            n := DllCall("shell32\DragQueryFileW", "Ptr", hDrop, "UInt", A_Index - 1, "Ptr", 0, "UInt", 0, "UInt")
            if n < 1
                continue
            buf := Buffer((n + 1) * 2, 0)
            DllCall("shell32\DragQueryFileW", "Ptr", hDrop, "UInt", A_Index - 1, "Ptr", buf, "UInt", n + 1)
            files.Push(StrGet(buf, "UTF-16"))
        }
    } finally {
        DllCall("CloseClipboard")
    }
    return files
}

IsImgExt(ext) {
    return RegExMatch(ext, "^(?i)(?:png|jpe?g|gif|webp|bmp|ico|tiff?)$") > 0
}

SaveClipboardImageToFile(path) {
    pToken := 0, pBitmap := 0, hCopy := 0
    try {
        DllCall("LoadLibrary", "Str", "gdiplus.dll", "Ptr")
        si := Buffer(24, 0)
        NumPut("UInt", 1, si)
        if DllCall("gdiplus\GdiplusStartup", "Ptr*", &pToken, "Ptr", si, "Ptr", 0)
            return false
        if !DllCall("OpenClipboard", "Ptr", 0)
            return false
        hSrc := DllCall("GetClipboardData", "UInt", 2, "Ptr")
        if hSrc
            hCopy := DllCall("CopyImage", "Ptr", hSrc, "UInt", 0, "Int", 0, "Int", 0, "UInt", 0x2008, "Ptr")
        DllCall("CloseClipboard")
        if !hCopy
            return false
        if DllCall("gdiplus\GdipCreateBitmapFromHBITMAP", "Ptr", hCopy, "Ptr", 0, "Ptr*", &pBitmap)
            return false
        DllCall("DeleteObject", "Ptr", hCopy), hCopy := 0
        if !pBitmap
            return false
        clsid := Buffer(16)
        DllCall("ole32\CLSIDFromString", "Str", "{557CF406-1A04-11D3-9A73-0000F81EF32E}", "Ptr", clsid)
        DllCall("gdiplus\GdipSaveImageToFile", "Ptr", pBitmap, "WStr", path, "Ptr", clsid, "Ptr", 0)
        return true
    } catch {
        return false
    } finally {
        if hCopy {
            try DllCall("DeleteObject", "Ptr", hCopy)
        }
        if pBitmap {
            try DllCall("gdiplus\GdipDisposeImage", "Ptr", pBitmap)
        }
        if pToken {
            try DllCall("gdiplus\GdiplusShutdown", "Ptr", pToken)
        }
    }
}
