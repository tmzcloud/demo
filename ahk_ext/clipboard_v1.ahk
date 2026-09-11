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
UI_CACHE_VER := "20260911-locate-group"
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
aGVpZ2h0OiA5cHg7IGNvbG9yOiAjZmZmOyBkaXNwbGF5OiBibG9jazsgfQogICAgICAgIC5pLWZhdiB7
CiAgICAgICAgICAgIHBvc2l0aW9uOiBhYnNvbHV0ZTsgcmlnaHQ6IDA7IHRvcDogMDsKICAgICAgICAg
ICAgd2lkdGg6IDE0cHg7IGhlaWdodDogMTRweDsgYm9yZGVyLXJhZGl1czogNTAlOwogICAgICAgICAg
ICBiYWNrZ3JvdW5kOiAjZmZmOyBib3JkZXI6IG5vbmU7CiAgICAgICAgICAgIGRpc3BsYXk6IGZsZXg7
IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGp1c3RpZnktY29udGVudDogY2VudGVyOwogICAgICAgICAgICBw
b2ludGVyLWV2ZW50czogbm9uZTsgei1pbmRleDogMzsKICAgICAgICAgICAgYm94LXNoYWRvdzogMCAx
cHggMnB4IHJnYmEoMCwwLDAsLjEyKTsKICAgICAgICAgICAgdHJhbnNmb3JtOiB0cmFuc2xhdGUoMjgl
LCAtMjglKTsKICAgICAgICAgICAgZm9udC1zaXplOiAxMXB4OyBsaW5lLWhlaWdodDogMTsKICAgICAg
ICAgICAgY29sb3I6ICNlMTFkNDg7CiAgICAgICAgfQogICAgICAgIC5pLWZhdiBzdmcgeyB3aWR0aDog
MTBweDsgaGVpZ2h0OiAxMHB4OyBjb2xvcjogI2UxMWQ0ODsgZGlzcGxheTogYmxvY2s7IH0KICAgICAg
ICAvKiBGYXZvcml0ZXMgdGFiOiBldmVyeSByb3cgaXMgcGlubmVkIOKAlCBoaWRlIGJhZGdlIGNsdXR0
ZXIgKi8KICAgICAgICAjYXBwW2RhdGEtdGFiPSJwaW5uZWQiXSAuaS1mYXYgeyBkaXNwbGF5OiBub25l
OyB9CgogICAgICAgIC8qIFBhc3RlLXF1ZXVlIHZpc3VhbCBjaGFpbjogZ3JheSA9IGluIHF1ZXVlOyBn
cmVlbiA9IGRlcXVldWVkIChwYXN0ZWQpIGNoYWluICovCiAgICAgICAgLml0bS5xLW1lbWJlciB7CiAg
ICAgICAgICAgIHBhZGRpbmctbGVmdDogMTRweDsKICAgICAgICAgICAgLyogTVVTVCBvdmVycmlkZSBn
bG9iYWwgLml0bXtvdmVyZmxvdzpoaWRkZW59IOKAlCBvdGhlcndpc2UgYm90dG9tOi1OIHJhaWwKICAg
ICAgICAgICAgICAgaXMgY2xpcHBlZCBhbmQgdGhlIGNoYWluIGxvb2tzIOKAnOaWree6v+KAnSBhY3Jv
c3MgdGhlIDVweCBjYXJkIGdhcCAqLwogICAgICAgICAgICBvdmVyZmxvdzogdmlzaWJsZSAhaW1wb3J0
YW50OwogICAgICAgIH0KICAgICAgICAuaXRtLnEtbWVtYmVyIC5xLXJhaWwgewogICAgICAgICAgICBw
b3NpdGlvbjogYWJzb2x1dGU7CiAgICAgICAgICAgIGxlZnQ6IDVweDsKICAgICAgICAgICAgdG9wOiAw
OwogICAgICAgICAgICAvKiBCcmlkZ2UgLml0bSBtYXJnaW4tYm90dG9tOjVweCBzbyBjb25zZWN1dGl2
ZSByYWlscyByZWFkIGFzIG9uZSBzdHJva2UgKi8KICAgICAgICAgICAgYm90dG9tOiAtNXB4OwogICAg
ICAgICAgICB3aWR0aDogMnB4OwogICAgICAgICAgICBiYWNrZ3JvdW5kOiAjOWNhM2FmOwogICAgICAg
ICAgICBvcGFjaXR5OiAuNzI7CiAgICAgICAgICAgIHBvaW50ZXItZXZlbnRzOiBub25lOwogICAgICAg
ICAgICB6LWluZGV4OiA0OwogICAgICAgIH0KICAgICAgICAuaXRtLnEtbWVtYmVyLnEtZmlyc3QgLnEt
cmFpbCB7IHRvcDogMTZweDsgYm9yZGVyLXJhZGl1czogMnB4IDJweCAwIDA7IH0KICAgICAgICAvKiBF
bmQgY2hhaW4gYXQgdGhlIGxhc3QgZG90IOKAlCBkbyBub3QgaGFuZyBpbnRvIHRoZSBnYXAgYmVsb3cg
Ki8KICAgICAgICAuaXRtLnEtbWVtYmVyLnEtbGFzdCAucS1yYWlsIHsKICAgICAgICAgICAgYm90dG9t
OiBhdXRvOwogICAgICAgICAgICBoZWlnaHQ6IDIycHg7CiAgICAgICAgICAgIGJvcmRlci1yYWRpdXM6
IDAgMCAycHggMnB4OwogICAgICAgIH0KICAgICAgICAuaXRtLnEtbWVtYmVyLnEtZmlyc3QucS1sYXN0
IC5xLXJhaWwsCiAgICAgICAgLml0bS5xLW1lbWJlci5xLW9ubHkgLnEtcmFpbCB7IGRpc3BsYXk6IG5v
bmU7IH0KICAgICAgICAuaXRtLnEtbWVtYmVyIC5xLWRvdCB7CiAgICAgICAgICAgIHBvc2l0aW9uOiBh
YnNvbHV0ZTsKICAgICAgICAgICAgbGVmdDogMnB4OwogICAgICAgICAgICB0b3A6IDE0cHg7CiAgICAg
ICAgICAgIHdpZHRoOiA4cHg7CiAgICAgICAgICAgIGhlaWdodDogOHB4OwogICAgICAgICAgICBib3Jk
ZXItcmFkaXVzOiA1MCU7CiAgICAgICAgICAgIGJhY2tncm91bmQ6ICM5Y2EzYWY7CiAgICAgICAgICAg
IGJvcmRlcjogMS41cHggc29saWQgI2ZmZjsKICAgICAgICAgICAgYm94LXNoYWRvdzogMCAwIDAgMXB4
IHJnYmEoMTU2LDE2MywxNzUsLjQ1KTsKICAgICAgICAgICAgcG9pbnRlci1ldmVudHM6IG5vbmU7CiAg
ICAgICAgICAgIHotaW5kZXg6IDU7CiAgICAgICAgfQogICAgICAgIC8qIERlcXVldWVkOiBncmVlbiBk
b3RzOyBncmVlbiByYWlsIGZvciBjb25zZWN1dGl2ZSBkb25lIHJ1biAqLwogICAgICAgIC5pdG0ucS1t
ZW1iZXIucS1kb25lIC5xLWRvdCB7CiAgICAgICAgICAgIGJhY2tncm91bmQ6ICMyMmM1NWU7CiAgICAg
ICAgICAgIGJveC1zaGFkb3c6IDAgMCAwIDFweCByZ2JhKDM0LDE5Nyw5NCwuNCk7CiAgICAgICAgfQog
ICAgICAgIC5pdG0ucS1tZW1iZXIucS1kb25lLWxpbmsgLnEtcmFpbCB7CiAgICAgICAgICAgIGJhY2tn
cm91bmQ6ICMyMmM1NWU7CiAgICAgICAgICAgIG9wYWNpdHk6IC45MjsKICAgICAgICB9CgogICAgICAg
IC5pdG0uanVtcC1mbGFzaCB7CiAgICAgICAgICAgIGJveC1zaGFkb3c6IDAgMCAwIDJweCByZ2JhKDkx
LDExNSwyMzIsLjU1KSwgMCAycHggMTBweCByZ2JhKDkxLDExNSwyMzIsLjIyKTsKICAgICAgICAgICAg
YmFja2dyb3VuZDogI2U4ZWRmZjsKICAgICAgICAgICAgdHJhbnNpdGlvbjogYmFja2dyb3VuZCAuMzVz
IGVhc2UsIGJveC1zaGFkb3cgLjM1cyBlYXNlOwogICAgICAgIH0KCiAgICAgICAgLmktYm9keSB7IGZs
ZXg6IDE7IG1pbi13aWR0aDogMDsgZGlzcGxheTogZmxleDsgZmxleC1kaXJlY3Rpb246IGNvbHVtbjsg
cG9zaXRpb246IHJlbGF0aXZlOyB6LWluZGV4OiAyOyB9CiAgICAgICAgLmktcHJldiwgLmktbmFtZSB7
CiAgICAgICAgICAgIGZvbnQtc2l6ZTogMTNweDsgZm9udC13ZWlnaHQ6IDUwMDsgY29sb3I6IHZhcigt
LXR4dCk7IHdvcmQtYnJlYWs6IGJyZWFrLWFsbDsKICAgICAgICAgICAgd2hpdGUtc3BhY2U6IHByZS13
cmFwOyAvKiDmlK/mjIHlpJrmlofku7Yv5aSa6KGM5paH5pys5o2i6KGM5pi+56S6ICovCiAgICAgICAg
fQogICAgICAgIC5pLXByZXYgewogICAgICAgICAgICBkaXNwbGF5OiAtd2Via2l0LWJveDsgLXdlYmtp
dC1ib3gtb3JpZW50OiB2ZXJ0aWNhbDsgLXdlYmtpdC1saW5lLWNsYW1wOiA1OyBvdmVyZmxvdzogaGlk
ZGVuOwogICAgICAgICAgICB0ZXh0LW92ZXJmbG93OiBlbGxpcHNpczsKICAgICAgICB9CiAgICAgICAg
LmktbmFtZSB7CiAgICAgICAgICAgIGRpc3BsYXk6IC13ZWJraXQtYm94OyAtd2Via2l0LWJveC1vcmll
bnQ6IHZlcnRpY2FsOyAtd2Via2l0LWxpbmUtY2xhbXA6IDI7IG92ZXJmbG93OiBoaWRkZW47CiAgICAg
ICAgfQogICAgICAgIC8qIEZpbGUgY2xpcCB3aG9zZSBwYXRoKHMpIG5vIGxvbmdlciBleGlzdCDigJQg
bGlnaHQgYm9sZCBncmF5IHN0cmlrZSAqLwogICAgICAgIC5pdG0uZ29uZSAuaS1uYW1lIHsKICAgICAg
ICAgICAgY29sb3I6ICM5YWEwYjA7CiAgICAgICAgICAgIHRleHQtZGVjb3JhdGlvbjogbGluZS10aHJv
dWdoOwogICAgICAgICAgICB0ZXh0LWRlY29yYXRpb24tdGhpY2tuZXNzOiAycHg7CiAgICAgICAgICAg
IHRleHQtZGVjb3JhdGlvbi1jb2xvcjogcmdiYSgxNTQsIDE2MCwgMTc2LCAuNTUpOwogICAgICAgICAg
ICB0ZXh0LWRlY29yYXRpb24tc2tpcC1pbms6IG5vbmU7CiAgICAgICAgfQogICAgICAgIC5pdG0uZ29u
ZSAuaS1pY28geyBvcGFjaXR5OiAuNTU7IH0KICAgICAgICAuaXRtLmdvbmUgLmktdGh1bWItd3JhcCB7
IG9wYWNpdHk6IC41NTsgfQogICAgICAgIC5pLXByZXYudXJsIHsgY29sb3I6IHZhcigtLWFjYyk7IH0K
CiAgICAgICAgLnJmLXBhdGggewogICAgICAgICAgICBkaXNwbGF5OiBmbGV4OyBmbGV4LXdyYXA6IHdy
YXA7IGFsaWduLWl0ZW1zOiBjZW50ZXI7CiAgICAgICAgICAgIGdhcDogMDsgcm93LWdhcDogM3B4Owog
ICAgICAgICAgICBmb250LXNpemU6IDEzcHg7IGZvbnQtd2VpZ2h0OiA2MDA7IGNvbG9yOiB2YXIoLS10
eHQpOwogICAgICAgICAgICBsaW5lLWhlaWdodDogMS40NTsgd29yZC1icmVhazogYnJlYWstd29yZDsK
ICAgICAgICAgICAgbWF4LXdpZHRoOiAxMDAlOwogICAgICAgICAgICB3aWR0aDogZml0LWNvbnRlbnQ7
CiAgICAgICAgICAgIHBvc2l0aW9uOiByZWxhdGl2ZTsKICAgICAgICAgICAgei1pbmRleDogNjsKICAg
ICAgICAgICAgLXdlYmtpdC1hcHAtcmVnaW9uOiBuby1kcmFnOyBhcHAtcmVnaW9uOiBuby1kcmFnOwog
ICAgICAgICAgICBwb2ludGVyLWV2ZW50czogYXV0bzsKICAgICAgICB9CiAgICAgICAgLnJmLXNlZyB7
CiAgICAgICAgICAgIGNvbG9yOiB2YXIoLS1hY2MpOwogICAgICAgICAgICBjdXJzb3I6IHBvaW50ZXI7
CiAgICAgICAgICAgIHBhZGRpbmc6IDFweCAzcHg7CiAgICAgICAgICAgIG1hcmdpbjogMDsKICAgICAg
ICAgICAgYm9yZGVyOiBub25lOwogICAgICAgICAgICBiYWNrZ3JvdW5kOiB0cmFuc3BhcmVudDsKICAg
ICAgICAgICAgYm9yZGVyLXJhZGl1czogM3B4OwogICAgICAgICAgICBmb250OiBpbmhlcml0OwogICAg
ICAgICAgICBmb250LXNpemU6IDEzcHg7CiAgICAgICAgICAgIGZvbnQtd2VpZ2h0OiA2MDA7CiAgICAg
ICAgICAgIGxpbmUtaGVpZ2h0OiAxLjQ1OwogICAgICAgICAgICAtd2Via2l0LWFwcC1yZWdpb246IG5v
LWRyYWc7IGFwcC1yZWdpb246IG5vLWRyYWc7CiAgICAgICAgICAgIHBvaW50ZXItZXZlbnRzOiBhdXRv
ICFpbXBvcnRhbnQ7CiAgICAgICAgICAgIHBvc2l0aW9uOiByZWxhdGl2ZTsKICAgICAgICAgICAgei1p
bmRleDogODsKICAgICAgICAgICAgdHJhbnNpdGlvbjogYmFja2dyb3VuZCAuMTJzIGVhc2UsIGNvbG9y
IC4xMnMgZWFzZTsKICAgICAgICB9CiAgICAgICAgLnJmLXNlZzpob3ZlciB7CiAgICAgICAgICAgIGJh
Y2tncm91bmQ6IHJnYmEoOTEsMTE1LDIzMiwuMTQpOwogICAgICAgICAgICB0ZXh0LWRlY29yYXRpb246
IHVuZGVybGluZTsKICAgICAgICB9CiAgICAgICAgLnJmLXNlcCB7CiAgICAgICAgICAgIGNvbG9yOiB2
YXIoLS10eHQzKTsKICAgICAgICAgICAgcGFkZGluZzogMCAycHg7CiAgICAgICAgICAgIG1hcmdpbjog
MDsKICAgICAgICAgICAgdXNlci1zZWxlY3Q6IG5vbmU7CiAgICAgICAgICAgIGZsZXgtc2hyaW5rOiAw
OwogICAgICAgICAgICBvcGFjaXR5OiAuNTU7CiAgICAgICAgICAgIHBvaW50ZXItZXZlbnRzOiBub25l
OwogICAgICAgICAgICBmb250LXNpemU6IDEycHg7CiAgICAgICAgICAgIGxpbmUtaGVpZ2h0OiAxLjQ1
OwogICAgICAgIH0KICAgICAgICAucmYtcGluLXRhZyB7CiAgICAgICAgICAgIGRpc3BsYXk6IGlubGlu
ZS1mbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBqdXN0aWZ5LWNvbnRlbnQ6IGNlbnRlcjsKICAgICAg
ICAgICAgZmxleC1zaHJpbms6IDA7CiAgICAgICAgICAgIGhlaWdodDogMTZweDsgcGFkZGluZzogMCA2
cHg7IG1hcmdpbi1yaWdodDogMDsKICAgICAgICAgICAgYm9yZGVyLXJhZGl1czogNHB4OwogICAgICAg
ICAgICBmb250LXNpemU6IDEwcHg7IGZvbnQtd2VpZ2h0OiA1MDA7CiAgICAgICAgICAgIGNvbG9yOiAj
N2E4NDk5OwogICAgICAgICAgICBiYWNrZ3JvdW5kOiByZ2JhKDEyMiwxMzIsMTUzLC4xMik7CiAgICAg
ICAgICAgIGJvcmRlcjogMXB4IHNvbGlkIHJnYmEoMTIyLDEzMiwxNTMsLjIyKTsKICAgICAgICAgICAg
bGV0dGVyLXNwYWNpbmc6IC4wMmVtOwogICAgICAgICAgICB3aGl0ZS1zcGFjZTogbm93cmFwOwogICAg
ICAgICAgICBwb2ludGVyLWV2ZW50czogbm9uZTsKICAgICAgICB9CiAgICAgICAgLmktdGh1bWItd3Jh
cCB7CiAgICAgICAgICAgIHdpZHRoOiAxMDAlOyBtaW4taGVpZ2h0OiA0OHB4OyBtYXgtaGVpZ2h0OiAx
ODBweDsgbWFyZ2luLWJvdHRvbTogNHB4OwogICAgICAgICAgICBkaXNwbGF5OiBmbGV4OyBhbGlnbi1p
dGVtczogY2VudGVyOyBqdXN0aWZ5LWNvbnRlbnQ6IGNlbnRlcjsKICAgICAgICAgICAgYmFja2dyb3Vu
ZDogI2YzZjVmOTsgYm9yZGVyLXJhZGl1czogdmFyKC0tcik7IG92ZXJmbG93OiBoaWRkZW47CiAgICAg
ICAgfQogICAgICAgIC5pLXRodW1iLXdyYXAud2FpdGluZyB7CiAgICAgICAgICAgIG1pbi1oZWlnaHQ6
IDg4cHg7CiAgICAgICAgICAgIGJhY2tncm91bmQ6IGxpbmVhci1ncmFkaWVudCg5MGRlZywgI2U4ZWJm
MiAwJSwgI2Y0ZjZmYSA0NSUsICNlOGViZjIgMTAwJSk7CiAgICAgICAgICAgIGJhY2tncm91bmQtc2l6
ZTogMjAwJSAxMDAlOwogICAgICAgICAgICBhbmltYXRpb246IHRodW1iU2hpbW1lciAxLjA1cyBlYXNl
LWluLW91dCBpbmZpbml0ZTsKICAgICAgICB9CiAgICAgICAgQGtleWZyYW1lcyB0aHVtYlNoaW1tZXIg
ewogICAgICAgICAgICAwJSB7IGJhY2tncm91bmQtcG9zaXRpb246IDEwMCUgMDsgfQogICAgICAgICAg
ICAxMDAlIHsgYmFja2dyb3VuZC1wb3NpdGlvbjogLTEwMCUgMDsgfQogICAgICAgIH0KICAgICAgICAu
aS10aHVtYiB7IG1heC13aWR0aDogMTAwJTsgbWF4LWhlaWdodDogMTgwcHg7IHdpZHRoOiBhdXRvOyBo
ZWlnaHQ6IGF1dG87IG9iamVjdC1maXQ6IGNvbnRhaW47IGRpc3BsYXk6IGJsb2NrOyB9CiAgICAgICAg
LmktdGh1bWIudGh1bWItbG9hZGluZyB7IG9wYWNpdHk6IDA7IHdpZHRoOiAxcHg7IGhlaWdodDogMXB4
OyB9CgogICAgICAgIC8qIE1ldGEgYmFyOiB0aW1lIGxlZnQgfCBleHBhbmQgY2VudGVyIHwgdGFncyBy
aWdodCAqLwogICAgICAgIC5pLW1ldGEgewogICAgICAgICAgICBkaXNwbGF5OiBncmlkOwogICAgICAg
ICAgICBncmlkLXRlbXBsYXRlLWNvbHVtbnM6IDFmciBhdXRvIDFmcjsKICAgICAgICAgICAgYWxpZ24t
aXRlbXM6IGNlbnRlcjsKICAgICAgICAgICAgZ2FwOiA0cHg7CiAgICAgICAgICAgIG1hcmdpbi10b3A6
IDRweDsKICAgICAgICAgICAgd2lkdGg6IDEwMCU7CiAgICAgICAgfQogICAgICAgIC5pLW1ldGEgLmkt
dGltZSB7IGp1c3RpZnktc2VsZjogc3RhcnQ7IH0KICAgICAgICAuaS1tZXRhLWNlbnRlciB7CiAgICAg
ICAgICAgIGp1c3RpZnktc2VsZjogY2VudGVyOwogICAgICAgICAgICBkaXNwbGF5OiBmbGV4OyBhbGln
bi1pdGVtczogY2VudGVyOyBqdXN0aWZ5LWNvbnRlbnQ6IGNlbnRlcjsKICAgICAgICAgICAgZ2FwOiA0
cHg7CiAgICAgICAgICAgIG1pbi13aWR0aDogMXB4OyAvKiBrZWVwIGNlbnRlciBjb2x1bW4gZXZlbiB3
aGVuIGV4cGFuZCBpcyBoaWRkZW4gKi8KICAgICAgICB9CiAgICAgICAgLmktbWV0YS1yaWdodCB7CiAg
ICAgICAgICAgIGp1c3RpZnktc2VsZjogZW5kOwogICAgICAgICAgICBkaXNwbGF5OiBmbGV4OyBhbGln
bi1pdGVtczogY2VudGVyOyBnYXA6IDVweDsgZmxleC13cmFwOiBub3dyYXA7CiAgICAgICAgICAgIGp1
c3RpZnktY29udGVudDogZmxleC1lbmQ7CiAgICAgICAgICAgIG1pbi13aWR0aDogMDsKICAgICAgICB9
CiAgICAgICAgLmktbWV0YS1yaWdodC50ZXh0LW1ldGEgewogICAgICAgICAgICBmbGV4LXdyYXA6IG5v
d3JhcDsKICAgICAgICAgICAgZ2FwOiA0cHg7CiAgICAgICAgfQogICAgICAgIC5pLXNyYy10aXRsZSB7
CiAgICAgICAgICAgIGZvbnQtc2l6ZTogMTBweDsKICAgICAgICAgICAgY29sb3I6IHZhcigtLXR4dDMp
OwogICAgICAgICAgICBtYXgtd2lkdGg6IDExZW07CiAgICAgICAgICAgIG92ZXJmbG93OiBoaWRkZW47
CiAgICAgICAgICAgIHRleHQtb3ZlcmZsb3c6IGVsbGlwc2lzOwogICAgICAgICAgICB3aGl0ZS1zcGFj
ZTogbm93cmFwOwogICAgICAgICAgICBtaW4td2lkdGg6IDA7CiAgICAgICAgICAgIGxpbmUtaGVpZ2h0
OiAxLjQ7CiAgICAgICAgfQogICAgICAgIC5pLXRpbWUsIC5pLXRhZyB7IGZvbnQtc2l6ZTogMTBweDsg
Y29sb3I6IHZhcigtLXR4dDMpOyB9CiAgICAgICAgLmktdGFnIHsKICAgICAgICAgICAgYmFja2dyb3Vu
ZDogI2YxZjNmODsgcGFkZGluZzogMCA1cHg7IGJvcmRlci1yYWRpdXM6IDNweDsKICAgICAgICAgICAg
d2hpdGUtc3BhY2U6IG5vd3JhcDsgZmxleC1zaHJpbms6IDA7IGxpbmUtaGVpZ2h0OiAxLjQ7CiAgICAg
ICAgfQogICAgICAgIC5pLWNoYXJzIHsKICAgICAgICAgICAgZm9udC1zaXplOiAxMHB4OyBjb2xvcjog
dmFyKC0tdHh0Myk7CiAgICAgICAgICAgIGJhY2tncm91bmQ6ICNmMWYzZjg7IHBhZGRpbmc6IDAgNXB4
OyBib3JkZXItcmFkaXVzOiAzcHg7CiAgICAgICAgICAgIGZvbnQtdmFyaWFudC1udW1lcmljOiB0YWJ1
bGFyLW51bXM7CiAgICAgICAgICAgIHdoaXRlLXNwYWNlOiBub3dyYXA7CiAgICAgICAgICAgIGRpc3Bs
YXk6IGlubGluZS1mbGV4OyBhbGlnbi1pdGVtczogYmFzZWxpbmU7IGdhcDogMnB4OwogICAgICAgIH0K
ICAgICAgICAuaS1jaGFycyAubiB7CiAgICAgICAgICAgIGRpc3BsYXk6IGlubGluZS1ibG9jazsKICAg
ICAgICAgICAgbWluLXdpZHRoOiA0Y2g7CiAgICAgICAgICAgIHRleHQtYWxpZ246IHJpZ2h0OwogICAg
ICAgICAgICBmb250LWZhbWlseTogJ0Nhc2NhZGlhIE1vbm8nLCAnQ29uc29sYXMnLCAnU2FyYXNhIE1v
bm8gU0MnLCB1aS1tb25vc3BhY2UsIG1vbm9zcGFjZTsKICAgICAgICAgICAgZm9udC13ZWlnaHQ6IDYw
MDsKICAgICAgICAgICAgY29sb3I6IHZhcigtLXR4dDIpOwogICAgICAgIH0KICAgICAgICAvKiBzcmMt
dGl0bGUtdGlwICovCiAgICAgICAgLmktc3JjLWljbywgLm1nLXNyYyB7IGN1cnNvcjogcG9pbnRlcjsg
fQogICAgICAgICNzcmMtdGlwIHsKICAgICAgICAgICAgcG9zaXRpb246IGZpeGVkOyB6LWluZGV4OiA5
OTk5OTsKICAgICAgICAgICAgbWF4LXdpZHRoOiBtaW4oMjgwcHgsIGNhbGMoMTAwdncgLSAxNnB4KSk7
CiAgICAgICAgICAgIHBhZGRpbmc6IDZweCAxMHB4OwogICAgICAgICAgICBib3JkZXItcmFkaXVzOiA4
cHg7CiAgICAgICAgICAgIGJhY2tncm91bmQ6IHJnYmEoMzIsMzYsNDgsLjkyKTsgY29sb3I6ICNmZmY7
CiAgICAgICAgICAgIGZvbnQtc2l6ZTogMTJweDsgbGluZS1oZWlnaHQ6IDEuMzU7CiAgICAgICAgICAg
IGJveC1zaGFkb3c6IDAgNnB4IDE4cHggcmdiYSgwLDAsMCwuMjIpOwogICAgICAgICAgICBwb2ludGVy
LWV2ZW50czogbm9uZTsKICAgICAgICAgICAgb3BhY2l0eTogMDsgdHJhbnNmb3JtOiB0cmFuc2xhdGVZ
KDRweCk7CiAgICAgICAgICAgIHRyYW5zaXRpb246IG9wYWNpdHkgLjJzIGVhc2UsIHRyYW5zZm9ybSAu
MjJzIGN1YmljLWJlemllciguMjIsMSwuMzYsMSk7CiAgICAgICAgICAgIHdvcmQtYnJlYWs6IGJyZWFr
LXdvcmQ7CiAgICAgICAgfQogICAgICAgICNzcmMtdGlwLnNob3cgeyBvcGFjaXR5OiAxOyB0cmFuc2Zv
cm06IHRyYW5zbGF0ZVkoMCk7IH0KICAgICAgICAuaS1zcmMtaWNvIHsKICAgICAgICAgICAgd2lkdGg6
IDE0cHg7IGhlaWdodDogMTRweDsgZmxleC1zaHJpbms6IDA7CiAgICAgICAgICAgIGJvcmRlci1yYWRp
dXM6IDJweDsgb2JqZWN0LWZpdDogY29udGFpbjsKICAgICAgICAgICAgZGlzcGxheTogYmxvY2s7CiAg
ICAgICAgfQogICAgICAgIC5pLW51bSB7CiAgICAgICAgICAgIGRpc3BsYXk6IGZsZXg7IGZsZXgtZGly
ZWN0aW9uOiBjb2x1bW47IGFsaWduLWl0ZW1zOiBmbGV4LWVuZDsKICAgICAgICAgICAganVzdGlmeS1j
b250ZW50OiBzcGFjZS1iZXR3ZWVuOwogICAgICAgICAgICBhbGlnbi1zZWxmOiBzdHJldGNoOwogICAg
ICAgICAgICBmb250LXNpemU6IDEwcHg7IGNvbG9yOiB2YXIoLS10eHQzKTsgbWluLXdpZHRoOiAxNnB4
OwogICAgICAgICAgICB0ZXh0LWFsaWduOiByaWdodDsgZmxleC1zaHJpbms6IDA7CiAgICAgICAgICAg
IHBhZGRpbmctdG9wOiAycHg7CiAgICAgICAgfQogICAgICAgIC5pLW51bSAuaS1zcmMtaWNvIHsgd2lk
dGg6IDE2cHg7IGhlaWdodDogMTZweDsgbWFyZ2luLXRvcDogYXV0bzsgfQoKICAgICAgICAuaS1leHBh
bmQtYnRuIHsKICAgICAgICAgICAgYm9yZGVyOiBub25lOyBiYWNrZ3JvdW5kOiBub25lOyBjdXJzb3I6
IHBvaW50ZXI7CiAgICAgICAgICAgIGNvbG9yOiB2YXIoLS10eHQzKTsgZm9udC1zaXplOiAxMnB4OyBw
YWRkaW5nOiAzcHggMTBweDsKICAgICAgICAgICAgYm9yZGVyLXJhZGl1czogOHB4OyBkaXNwbGF5OiBu
b25lOyBhbGlnbi1pdGVtczogY2VudGVyOyBnYXA6IDRweDsKICAgICAgICAgICAgdHJhbnNpdGlvbjog
Y29sb3IgdmFyKC0tdHIpLCBiYWNrZ3JvdW5kIHZhcigtLXRyKTsKICAgICAgICAgICAgLXdlYmtpdC1h
cHAtcmVnaW9uOiBuby1kcmFnOyBhcHAtcmVnaW9uOiBuby1kcmFnOwogICAgICAgICAgICBsaW5lLWhl
aWdodDogMS4yOwogICAgICAgIH0KICAgICAgICAuaS1leHBhbmQtYnRuIHN2ZyB7IHdpZHRoOiAxNHB4
OyBoZWlnaHQ6IDE0cHg7IGZsZXgtc2hyaW5rOiAwOyB9CiAgICAgICAgLmktZXhwYW5kLWJ0bi5vbiB7
IGRpc3BsYXk6IGlubGluZS1mbGV4OyB9CiAgICAgICAgLmktZXhwYW5kLWJ0bjpob3ZlciB7IGNvbG9y
OiB2YXIoLS1hY2MpOyBiYWNrZ3JvdW5kOiByZ2JhKDkxLDExNSwyMzIsLjA4KTsgfQogICAgICAgIC5p
LXByZXYuZXhwYW5kZWQsIC5pLW5hbWUuZXhwYW5kZWQgewogICAgICAgICAgICAtd2Via2l0LWxpbmUt
Y2xhbXA6IHVuc2V0OwogICAgICAgICAgICBkaXNwbGF5OiBibG9jazsKICAgICAgICAgICAgb3ZlcmZs
b3c6IGhpZGRlbjsKICAgICAgICAgICAgLyog6auY5bqm55SxIEpTIOaMieWIl+ihqOWPr+inhuWMuuiu
vuWumu+8mue6puWNoOaVtOihqOWwkeS4gOihjCAqLwogICAgICAgIH0KICAgICAgICAuaS1zcmMtdGl0
bGUgeyBkaXNwbGF5OiBub25lICFpbXBvcnRhbnQ7IH0KICAgICAgICAuaS1maWxlLWRldGFpbCB7CiAg
ICAgICAgICAgIGRpc3BsYXk6IG5vbmU7CiAgICAgICAgICAgIG1hcmdpbi10b3A6IDRweDsKICAgICAg
ICAgICAgcGFkZGluZzogMDsKICAgICAgICAgICAgYmFja2dyb3VuZDogbm9uZTsKICAgICAgICAgICAg
Ym9yZGVyOiBub25lOwogICAgICAgIH0KICAgICAgICAuaS1maWxlLWRldGFpbC5vbiB7IGRpc3BsYXk6
IGJsb2NrOyB9CiAgICAgICAgLmZkLWJsb2NrIHsKICAgICAgICAgICAgZGlzcGxheTogZmxleDsgZmxl
eC1kaXJlY3Rpb246IGNvbHVtbjsgZ2FwOiA2cHg7CiAgICAgICAgfQogICAgICAgIC5mZC1ibG9jayAr
IC5mZC1ibG9jayB7IG1hcmdpbi10b3A6IDhweDsgfQogICAgICAgIC5mZC1wYXRoIHsKICAgICAgICAg
ICAgd2lkdGg6IDEwMCU7CiAgICAgICAgICAgIGZvbnQ6IDYwMCAxMnB4LzEuNTUgJ1NlZ29lIFVJIFZh
cmlhYmxlIFRleHQnLCdTZWdvZSBVSScsJ01pY3Jvc29mdCBZYUhlaSBVSScsc2Fucy1zZXJpZjsKICAg
ICAgICAgICAgY29sb3I6IHZhcigtLXR4dDIpOwogICAgICAgICAgICBsZXR0ZXItc3BhY2luZzogLjAx
ZW07CiAgICAgICAgICAgIHdvcmQtYnJlYWs6IGJyZWFrLWFsbDsKICAgICAgICAgICAgdXNlci1zZWxl
Y3Q6IHRleHQ7CiAgICAgICAgICAgIC13ZWJraXQtYXBwLXJlZ2lvbjogbm8tZHJhZzsgYXBwLXJlZ2lv
bjogbm8tZHJhZzsKICAgICAgICB9CiAgICAgICAgLmZkLXBhdGgubGl2ZSB7IGN1cnNvcjogcG9pbnRl
cjsgfQogICAgICAgIC5mZC1wYXRoLmxpdmU6aG92ZXIgeyBjb2xvcjogdmFyKC0tYWNjKTsgfQogICAg
ICAgIC5mZC1wYXRoLmRlYWQgewogICAgICAgICAgICBjb2xvcjogIzlhYTBiMDsKICAgICAgICAgICAg
dGV4dC1kZWNvcmF0aW9uOiBsaW5lLXRocm91Z2g7CiAgICAgICAgICAgIHRleHQtZGVjb3JhdGlvbi10
aGlja25lc3M6IDJweDsKICAgICAgICAgICAgdGV4dC1kZWNvcmF0aW9uLWNvbG9yOiByZ2JhKDE1NCwg
MTYwLCAxNzYsIC41NSk7CiAgICAgICAgICAgIHRleHQtZGVjb3JhdGlvbi1za2lwLWluazogbm9uZTsK
ICAgICAgICAgICAgY3Vyc29yOiBkZWZhdWx0OwogICAgICAgIH0KICAgICAgICAuZmQtYWN0aW9ucyB7
CiAgICAgICAgICAgIGRpc3BsYXk6IGZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGp1c3RpZnktY29u
dGVudDogZmxleC1lbmQ7CiAgICAgICAgICAgIGdhcDogOHB4OyBmbGV4LXdyYXA6IHdyYXA7CiAgICAg
ICAgfQogICAgICAgIC5mZC1idG4gewogICAgICAgICAgICBib3JkZXI6IG5vbmU7IGJhY2tncm91bmQ6
IG5vbmU7IGN1cnNvcjogcG9pbnRlcjsKICAgICAgICAgICAgY29sb3I6IHZhcigtLXR4dDMpOyBmb250
LXNpemU6IDEwcHg7IGZvbnQtd2VpZ2h0OiA2MDA7CiAgICAgICAgICAgIHBhZGRpbmc6IDFweCAycHg7
IGRpc3BsYXk6IGlubGluZS1mbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBnYXA6IDJweDsKICAgICAg
ICAgICAgd2hpdGUtc3BhY2U6IG5vd3JhcDsKICAgICAgICAgICAgLXdlYmtpdC1hcHAtcmVnaW9uOiBu
by1kcmFnOyBhcHAtcmVnaW9uOiBuby1kcmFnOwogICAgICAgICAgICB0cmFuc2l0aW9uOiBjb2xvciB2
YXIoLS10cik7CiAgICAgICAgfQogICAgICAgIC5mZC1idG46aG92ZXIgeyBjb2xvcjogdmFyKC0tYWNj
KTsgfQogICAgICAgIC5mZC1idG4ub2sgeyBjb2xvcjogIzFmN2E1NTsgfQoKICAgICAgICAvKiDilIDi
lIAgQ29udGV4dCBtZW51IOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKU
gOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgCAqLwogICAg
ICAgICNjdHggewogICAgICAgICAgICBwb3NpdGlvbjogZml4ZWQ7IHotaW5kZXg6IDk5OTk7IG1pbi13
aWR0aDogMTMycHg7IGRpc3BsYXk6IG5vbmU7IHBhZGRpbmc6IDRweDsKICAgICAgICAgICAgYmFja2dy
b3VuZDogI2ZmZjsgYm9yZGVyLXJhZGl1czogdmFyKC0tcik7IGJveC1zaGFkb3c6IDAgNnB4IDE2cHgg
cmdiYSgwLDAsMCwuMTQpOwogICAgICAgICAgICAtd2Via2l0LWFwcC1yZWdpb246IG5vLWRyYWc7IGFw
cC1yZWdpb246IG5vLWRyYWc7CiAgICAgICAgfQogICAgICAgICNjdHgub24geyBkaXNwbGF5OiBibG9j
azsgfQogICAgICAgIC5jLWl0ZW0gewogICAgICAgICAgICBkaXNwbGF5OiBmbGV4OyBhbGlnbi1pdGVt
czogY2VudGVyOyBnYXA6IDdweDsgcGFkZGluZzogNnB4IDlweDsKICAgICAgICAgICAgYm9yZGVyLXJh
ZGl1czogdmFyKC0tcik7IGN1cnNvcjogcG9pbnRlcjsgZm9udC1zaXplOiAxMXB4OyBjb2xvcjogdmFy
KC0tdHh0KTsKICAgICAgICB9CiAgICAgICAgLmMtaXRlbTpob3ZlciB7IGJhY2tncm91bmQ6ICNmMmY0
Zjk7IH0KICAgICAgICAuYy1pdGVtLmRhbmdlciB7IGNvbG9yOiAjZmY3YjljOyB9CiAgICAgICAgLmMt
c2VwIHsgaGVpZ2h0OiAxcHg7IGJhY2tncm91bmQ6ICNlY2VmZjU7IG1hcmdpbjogM3B4IDA7IH0KICAg
ICAgICAuYy1pY28geyB3aWR0aDogMTRweDsgdGV4dC1hbGlnbjogY2VudGVyOyB9CiAgICAgICAgLmMt
c3Vid3JhcCB7IHBvc2l0aW9uOiByZWxhdGl2ZTsgfQogICAgICAgIC5jLXN1YndyYXAgPiAuYy1pdGVt
IHsgd2lkdGg6IDEwMCU7IGJveC1zaXppbmc6IGJvcmRlci1ib3g7IH0KICAgICAgICAuYy1jYXJldCB7
IG1hcmdpbi1sZWZ0OiBhdXRvOyBjb2xvcjogdmFyKC0tdHh0Myk7IGZvbnQtc2l6ZTogMTBweDsgfQog
ICAgICAgIC5jLXN1YiB7CiAgICAgICAgICAgIGRpc3BsYXk6IG5vbmU7IHBvc2l0aW9uOiBhYnNvbHV0
ZTsgbGVmdDogY2FsYygxMDAlIC0gMnB4KTsgdG9wOiAtMnB4OyB6LWluZGV4OiAxOwogICAgICAgICAg
ICBtaW4td2lkdGg6IDA7IHdpZHRoOiBtYXgtY29udGVudDsgcGFkZGluZzogMnB4OwogICAgICAgICAg
ICBiYWNrZ3JvdW5kOiAjZmZmOyBib3JkZXItcmFkaXVzOiB2YXIoLS1yKTsKICAgICAgICAgICAgYm94
LXNoYWRvdzogMCA2cHggMTZweCByZ2JhKDAsMCwwLC4xNCk7CiAgICAgICAgfQogICAgICAgIC5jLXN1
Yi5sZWZ0IHsKICAgICAgICAgICAgbGVmdDogYXV0bzsgcmlnaHQ6IGNhbGMoMTAwJSAtIDJweCk7CiAg
ICAgICAgfQogICAgICAgIC5jLXN1YndyYXA6aG92ZXIgPiAuYy1zdWIsCiAgICAgICAgLmMtc3Vid3Jh
cC5vcGVuID4gLmMtc3ViIHsgZGlzcGxheTogYmxvY2s7IH0KICAgICAgICAuYy1zdWIgLmMtaXRlbSB7
CiAgICAgICAgICAgIGZvbnQtZmFtaWx5OiB1aS1tb25vc3BhY2UsIENvbnNvbGFzLCAiQ2FzY2FkaWEg
TW9ubyIsIG1vbm9zcGFjZTsKICAgICAgICAgICAgZm9udC1zaXplOiAxMHB4OyB3aGl0ZS1zcGFjZTog
bm93cmFwOwogICAgICAgICAgICBwYWRkaW5nOiA0cHggN3B4OyBnYXA6IDA7CiAgICAgICAgfQogICAg
ICAgIC5jLXN1YiAuYy1pdGVtLnBpY2sgewogICAgICAgICAgICBiYWNrZ3JvdW5kOiByZ2JhKDkxLCAx
MjQsIDI1MCwgLjE0KTsKICAgICAgICAgICAgY29sb3I6ICMzYjViZGI7CiAgICAgICAgICAgIGZvbnQt
d2VpZ2h0OiA2MDA7CiAgICAgICAgfQogICAgICAgIC5jLXN1YiAuYy1pdGVtLnBpY2sgLmMtbnVtLAog
ICAgICAgIC5jLXN1YiAuYy1pdGVtLnBpY2sgLmMtYXJyb3cgeyBjb2xvcjogIzViN2NmYTsgfQogICAg
ICAgIC5jLXN1YiAuYy1udW0gewogICAgICAgICAgICB3aWR0aDogMTJweDsgZmxleC1zaHJpbms6IDA7
IGNvbG9yOiB2YXIoLS10eHQzKTsgdGV4dC1hbGlnbjogbGVmdDsKICAgICAgICAgICAgbWFyZ2luLXJp
Z2h0OiA0cHg7CiAgICAgICAgfQogICAgICAgIC5jLXN1YiAuYy1mcm9tIHsKICAgICAgICAgICAgZGlz
cGxheTogaW5saW5lLWJsb2NrOyBtaW4td2lkdGg6IDA7IHRleHQtYWxpZ246IGxlZnQ7IGZsZXgtc2hy
aW5rOiAwOwogICAgICAgIH0KICAgICAgICAuYy1zdWIgLmMtYXJyb3cgewogICAgICAgICAgICBkaXNw
bGF5OiBpbmxpbmUtYmxvY2s7IHBhZGRpbmc6IDAgNHB4OyBjb2xvcjogdmFyKC0tdHh0Myk7IGZsZXgt
c2hyaW5rOiAwOwogICAgICAgIH0KICAgICAgICAuYy1zdWIgLmMtdG8geyBmbGV4LXNocmluazogMDsg
fQoKICAgICAgICAvKiDilIDilIAgQ2xlYXIgY29uZmlybSDilIDilIDilIDilIDilIDilIDilIDilIDi
lIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDi
lIDilIDilIAgKi8KICAgICAgICAjY2xyLWRsZyB7CiAgICAgICAgICAgIGRpc3BsYXk6IG5vbmU7IHBv
c2l0aW9uOiBmaXhlZDsgaW5zZXQ6IDA7IHotaW5kZXg6IDEwMDAwOwogICAgICAgICAgICBiYWNrZ3Jv
dW5kOiByZ2JhKDIwLCAyMiwgMzUsIC40Mik7CiAgICAgICAgICAgIGFsaWduLWl0ZW1zOiBjZW50ZXI7
IGp1c3RpZnktY29udGVudDogY2VudGVyOwogICAgICAgICAgICAtd2Via2l0LWFwcC1yZWdpb246IG5v
LWRyYWc7IGFwcC1yZWdpb246IG5vLWRyYWc7CiAgICAgICAgfQogICAgICAgICNjbHItZGxnLm9uIHsg
ZGlzcGxheTogZmxleDsgfQogICAgICAgIC5jbHItYm94IHsKICAgICAgICAgICAgd2lkdGg6IG1pbigy
ODBweCwgY2FsYygxMDAlIC0gMzJweCkpOwogICAgICAgICAgICBiYWNrZ3JvdW5kOiAjZmZmOyBib3Jk
ZXItcmFkaXVzOiAxMnB4OwogICAgICAgICAgICBib3gtc2hhZG93OiAwIDEycHggMzJweCByZ2JhKDAs
MCwwLC4xOCk7CiAgICAgICAgICAgIHBhZGRpbmc6IDE2cHggMTZweCAxNHB4OyBjb2xvcjogdmFyKC0t
dHh0KTsKICAgICAgICB9CiAgICAgICAgLmNsci10aXRsZSB7IGZvbnQtc2l6ZTogMTRweDsgZm9udC13
ZWlnaHQ6IDcwMDsgbWFyZ2luLWJvdHRvbTogNnB4OyB9CiAgICAgICAgLmNsci1kZXNjIHsgZm9udC1z
aXplOiAxMXB4OyBjb2xvcjogdmFyKC0tdHh0Myk7IGxpbmUtaGVpZ2h0OiAxLjU7IG1hcmdpbi1ib3R0
b206IDEycHg7IH0KICAgICAgICAuY2xyLWNoZWNrIHsKICAgICAgICAgICAgZGlzcGxheTogZmxleDsg
YWxpZ24taXRlbXM6IGNlbnRlcjsgZ2FwOiA3cHg7CiAgICAgICAgICAgIGZvbnQtc2l6ZTogMTJweDsg
Y29sb3I6IHZhcigtLXR4dCk7IGN1cnNvcjogcG9pbnRlcjsKICAgICAgICAgICAgdXNlci1zZWxlY3Q6
IG5vbmU7IG1hcmdpbi1ib3R0b206IDE0cHg7CiAgICAgICAgfQogICAgICAgIC5jbHItY2hlY2sgaW5w
dXQgewogICAgICAgICAgICB3aWR0aDogMTRweDsgaGVpZ2h0OiAxNHB4OyBhY2NlbnQtY29sb3I6IHZh
cigtLWFjYyk7IGN1cnNvcjogcG9pbnRlcjsKICAgICAgICB9CiAgICAgICAgLmNsci1idG5zIHsgZGlz
cGxheTogZmxleDsgZ2FwOiA4cHg7IGp1c3RpZnktY29udGVudDogZmxleC1lbmQ7IH0KICAgICAgICAu
Y2xyLWJ0bnMgYnV0dG9uIHsKICAgICAgICAgICAgYm9yZGVyOiBub25lOyBib3JkZXItcmFkaXVzOiA4
cHg7IHBhZGRpbmc6IDdweCAxNHB4OwogICAgICAgICAgICBmb250LXNpemU6IDEycHg7IGN1cnNvcjog
cG9pbnRlcjsgZm9udC13ZWlnaHQ6IDYwMDsKICAgICAgICAgICAgdHJhbnNpdGlvbjogYmFja2dyb3Vu
ZCB2YXIoLS10ciksIGNvbG9yIHZhcigtLXRyKTsKICAgICAgICB9CiAgICAgICAgI2Nsci1jYW5jZWwg
eyBiYWNrZ3JvdW5kOiAjZjFmM2Y4OyBjb2xvcjogdmFyKC0tdHh0Mik7IH0KICAgICAgICAjY2xyLWNh
bmNlbDpob3ZlciB7IGJhY2tncm91bmQ6ICNlNmU5ZjI7IH0KICAgICAgICAjY2xyLW9rIHsgYmFja2dy
b3VuZDogcmdiYSgyNTUsMTIzLDE1NiwuMTQpOyBjb2xvcjogI2U4NWE3YTsgfQogICAgICAgICNjbHIt
b2s6aG92ZXIgeyBiYWNrZ3JvdW5kOiByZ2JhKDI1NSwxMjMsMTU2LC4yNCk7IH0KCiAgICAgICAgLyog
4pSA4pSAIEZpbGUgcGF0aCB0aXAg4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA
4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSAICovCiAg
ICAgICAgI3BhdGgtdGlwIHsKICAgICAgICAgICAgZGlzcGxheTogbm9uZTsgcG9zaXRpb246IGZpeGVk
OyB6LWluZGV4OiAxMDAwMTsKICAgICAgICAgICAgd2lkdGg6IG1pbigzMjBweCwgY2FsYygxMDB2dyAt
IDE2cHgpKTsKICAgICAgICAgICAgbWF4LWhlaWdodDogbWluKDI4MHB4LCBjYWxjKDEwMHZoIC0gMjRw
eCkpOwogICAgICAgICAgICBvdmVyZmxvdzogYXV0bzsKICAgICAgICAgICAgcGFkZGluZzogMDsKICAg
ICAgICAgICAgYmFja2dyb3VuZDogbGluZWFyLWdyYWRpZW50KDE2NWRlZywgI2ZmZmZmZiAwJSwgI2Y2
ZjhmYyAxMDAlKTsKICAgICAgICAgICAgYm9yZGVyOiAxcHggc29saWQgcmdiYSg3MCwgODQsIDEyMCwg
LjEpOwogICAgICAgICAgICBib3JkZXItcmFkaXVzOiAxMnB4OwogICAgICAgICAgICBib3gtc2hhZG93
OgogICAgICAgICAgICAgICAgMCA0cHggNnB4IHJnYmEoMzAsIDQwLCA3MCwgLjA0KSwKICAgICAgICAg
ICAgICAgIDAgMTRweCAzNnB4IHJnYmEoMzAsIDQwLCA3MCwgLjE2KTsKICAgICAgICAgICAgY29sb3I6
IHZhcigtLXR4dCk7CiAgICAgICAgICAgIHBvaW50ZXItZXZlbnRzOiBhdXRvOwogICAgICAgICAgICBv
cGFjaXR5OiAwOwogICAgICAgICAgICB0cmFuc2Zvcm06IHRyYW5zbGF0ZVkoNHB4KSBzY2FsZSguOTgp
OwogICAgICAgICAgICB0cmFuc2l0aW9uOiBvcGFjaXR5IC4xNHMgZWFzZSwgdHJhbnNmb3JtIC4xNHMg
ZWFzZTsKICAgICAgICAgICAgLXdlYmtpdC1hcHAtcmVnaW9uOiBuby1kcmFnOyBhcHAtcmVnaW9uOiBu
by1kcmFnOwogICAgICAgIH0KICAgICAgICAjcGF0aC10aXAub24gewogICAgICAgICAgICBkaXNwbGF5
OiBibG9jazsKICAgICAgICAgICAgb3BhY2l0eTogMTsKICAgICAgICAgICAgdHJhbnNmb3JtOiB0cmFu
c2xhdGVZKDApIHNjYWxlKDEpOwogICAgICAgIH0KICAgICAgICAucHQtaGVhZCB7CiAgICAgICAgICAg
IGRpc3BsYXk6IGZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGp1c3RpZnktY29udGVudDogc3BhY2Ut
YmV0d2VlbjsKICAgICAgICAgICAgZ2FwOiAxMHB4OyBwYWRkaW5nOiAxMHB4IDEycHggOHB4OwogICAg
ICAgICAgICBib3JkZXItYm90dG9tOiAxcHggc29saWQgcmdiYSg3MCwgODQsIDEyMCwgLjA3KTsKICAg
ICAgICB9CiAgICAgICAgLnB0LXRpdGxlIHsKICAgICAgICAgICAgZm9udC1zaXplOiAxMXB4OyBmb250
LXdlaWdodDogNzAwOyBsZXR0ZXItc3BhY2luZzogLjA0ZW07CiAgICAgICAgICAgIGNvbG9yOiB2YXIo
LS10eHQyKTsgdGV4dC10cmFuc2Zvcm06IHVwcGVyY2FzZTsKICAgICAgICAgICAgZmxleC1zaHJpbms6
IDA7CiAgICAgICAgfQogICAgICAgIC5wdC1oZWFkLWJ0biB7CiAgICAgICAgICAgIGZsZXgtc2hyaW5r
OiAwOyBtYXJnaW4tbGVmdDogYXV0bzsKICAgICAgICAgICAgaGVpZ2h0OiAyMnB4OyBwYWRkaW5nOiAw
IDhweDsgZGlzcGxheTogaW5saW5lLWZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGdhcDogNHB4Owog
ICAgICAgICAgICBib3JkZXI6IDFweCBzb2xpZCByZ2JhKDEwNywxMTIsMTI4LC4yMik7IGJvcmRlci1y
YWRpdXM6IDZweDsgY3Vyc29yOiBwb2ludGVyOwogICAgICAgICAgICBiYWNrZ3JvdW5kOiByZ2JhKDEw
NywxMTIsMTI4LC4wNik7IGNvbG9yOiAjOGE5MGEwOyBmb250LXNpemU6IDExcHg7IGZvbnQtd2VpZ2h0
OiA2MDA7CiAgICAgICAgICAgIHdoaXRlLXNwYWNlOiBub3dyYXA7CiAgICAgICAgICAgIC13ZWJraXQt
YXBwLXJlZ2lvbjogbm8tZHJhZzsgYXBwLXJlZ2lvbjogbm8tZHJhZzsKICAgICAgICAgICAgdHJhbnNp
dGlvbjogYmFja2dyb3VuZCB2YXIoLS10ciksIGNvbG9yIHZhcigtLXRyKSwgYm9yZGVyLWNvbG9yIHZh
cigtLXRyKTsKICAgICAgICB9CiAgICAgICAgLnB0LWhlYWQtYnRuOmhvdmVyIHsKICAgICAgICAgICAg
YmFja2dyb3VuZDogcmdiYSgxMDcsMTEyLDEyOCwuMTIpOyBjb2xvcjogdmFyKC0tdHh0Mik7CiAgICAg
ICAgICAgIGJvcmRlci1jb2xvcjogcmdiYSgxMDcsMTEyLDEyOCwuNCk7CiAgICAgICAgfQogICAgICAg
IC5wdC1saXN0IHsgcGFkZGluZzogNnB4IDhweCA4cHg7IGRpc3BsYXk6IGZsZXg7IGZsZXgtZGlyZWN0
aW9uOiBjb2x1bW47IGdhcDogNHB4OyB9CiAgICAgICAgLnB0LXJvdyB7CiAgICAgICAgICAgIGRpc3Bs
YXk6IGdyaWQ7IGdyaWQtdGVtcGxhdGUtY29sdW1uczogOHB4IDFmcjsgZ2FwOiA4cHg7CiAgICAgICAg
ICAgIHBhZGRpbmc6IDhweCA4cHg7IGJvcmRlci1yYWRpdXM6IDhweDsKICAgICAgICAgICAgYmFja2dy
b3VuZDogcmdiYSgyNTUsMjU1LDI1NSwuNyk7CiAgICAgICAgfQogICAgICAgIC5wdC1yb3cuZGVhZCB7
IGJhY2tncm91bmQ6IHJnYmEoMjU1LCAxMjMsIDE1NiwgLjA2KTsgfQogICAgICAgIC5wdC1kb3Qgewog
ICAgICAgICAgICB3aWR0aDogOHB4OyBoZWlnaHQ6IDhweDsgYm9yZGVyLXJhZGl1czogNTAlOyBtYXJn
aW4tdG9wOiA1cHg7CiAgICAgICAgICAgIGJhY2tncm91bmQ6ICMyZWI0Nzg7IGJveC1zaGFkb3c6IDAg
MCAwIDNweCByZ2JhKDQ2LCAxODAsIDEyMCwgLjE4KTsKICAgICAgICB9CiAgICAgICAgLnB0LXJvdy5k
ZWFkIC5wdC1kb3QgewogICAgICAgICAgICBiYWNrZ3JvdW5kOiAjZTg1YTdhOyBib3gtc2hhZG93OiAw
IDAgMCAzcHggcmdiYSgyMzIsIDkwLCAxMjIsIC4xNik7CiAgICAgICAgfQogICAgICAgIC5wdC1uYW1l
IHsKICAgICAgICAgICAgZm9udC1zaXplOiAxMnB4OyBmb250LXdlaWdodDogNjUwOyBjb2xvcjogdmFy
KC0tdHh0KTsKICAgICAgICAgICAgbGluZS1oZWlnaHQ6IDEuMzsgd29yZC1icmVhazogYnJlYWstYWxs
OwogICAgICAgIH0KICAgICAgICAucHQtcGF0aCB7CiAgICAgICAgICAgIG1hcmdpbi10b3A6IDNweDsK
ICAgICAgICAgICAgZm9udDogMTAuNXB4LzEuNDUgJ0Nhc2NhZGlhIE1vbm8nLCdDb25zb2xhcycsJ01p
Y3Jvc29mdCBZYUhlaSBVSScsbW9ub3NwYWNlOwogICAgICAgICAgICBjb2xvcjogdmFyKC0tdHh0Mik7
IHdvcmQtYnJlYWs6IGJyZWFrLWFsbDsKICAgICAgICAgICAgdXNlci1zZWxlY3Q6IHRleHQ7CiAgICAg
ICAgfQogICAgICAgIC5wdC1wYXRoLmxpdmUgewogICAgICAgICAgICBjb2xvcjogdmFyKC0tYWNjKTsg
Y3Vyc29yOiBwb2ludGVyOwogICAgICAgIH0KICAgICAgICAucHQtcGF0aC5saXZlOmhvdmVyIHsgdGV4
dC1kZWNvcmF0aW9uOiB1bmRlcmxpbmU7IH0KICAgICAgICAucHQtcGF0aC5kZWFkIHsKICAgICAgICAg
ICAgY29sb3I6ICNjNDNkNWM7CiAgICAgICAgICAgIHRleHQtZGVjb3JhdGlvbjogbGluZS10aHJvdWdo
OwogICAgICAgICAgICB0ZXh0LWRlY29yYXRpb24tdGhpY2tuZXNzOiAycHg7CiAgICAgICAgICAgIHRl
eHQtZGVjb3JhdGlvbi1jb2xvcjogI2UxMWQ0ODsKICAgICAgICAgICAgY3Vyc29yOiBkZWZhdWx0Owog
ICAgICAgIH0KICAgICAgICAucHQtYWN0aW9ucyB7CiAgICAgICAgICAgIG1hcmdpbi10b3A6IDZweDsK
ICAgICAgICAgICAgZGlzcGxheTogZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsgZ2FwOiA2cHg7IGZs
ZXgtd3JhcDogd3JhcDsKICAgICAgICB9CiAgICAgICAgLnB0LWNvcHktYnRuIHsKICAgICAgICAgICAg
aGVpZ2h0OiAyMnB4OyBwYWRkaW5nOiAwIDhweDsgZGlzcGxheTogaW5saW5lLWZsZXg7IGFsaWduLWl0
ZW1zOiBjZW50ZXI7CiAgICAgICAgICAgIGJvcmRlcjogMXB4IHNvbGlkIHJnYmEoMTA3LDExMiwxMjgs
LjIyKTsgYm9yZGVyLXJhZGl1czogNnB4OyBjdXJzb3I6IHBvaW50ZXI7CiAgICAgICAgICAgIGJhY2tn
cm91bmQ6IHJnYmEoMTA3LDExMiwxMjgsLjA2KTsgY29sb3I6ICM4YTkwYTA7IGZvbnQtc2l6ZTogMTFw
eDsgZm9udC13ZWlnaHQ6IDYwMDsKICAgICAgICAgICAgLXdlYmtpdC1hcHAtcmVnaW9uOiBuby1kcmFn
OyBhcHAtcmVnaW9uOiBuby1kcmFnOwogICAgICAgICAgICB0cmFuc2l0aW9uOiBiYWNrZ3JvdW5kIHZh
cigtLXRyKSwgY29sb3IgdmFyKC0tdHIpLCBib3JkZXItY29sb3IgdmFyKC0tdHIpOwogICAgICAgIH0K
ICAgICAgICAucHQtY29weS1idG46aG92ZXIgewogICAgICAgICAgICBiYWNrZ3JvdW5kOiByZ2JhKDEw
NywxMTIsMTI4LC4xMik7IGNvbG9yOiB2YXIoLS10eHQyKTsKICAgICAgICAgICAgYm9yZGVyLWNvbG9y
OiByZ2JhKDEwNywxMTIsMTI4LC40KTsKICAgICAgICB9CiAgICAgICAgLnB0LWNvcHktYnRuLm9rIHsK
ICAgICAgICAgICAgY29sb3I6ICMxZjdhNTU7IGJvcmRlci1jb2xvcjogcmdiYSg0NiwgMTgwLCAxMjAs
IC4zNSk7CiAgICAgICAgICAgIGJhY2tncm91bmQ6IHJnYmEoNDYsIDE4MCwgMTIwLCAuMSk7CiAgICAg
ICAgfQogICAgICAgIC5pdG0uaXQtZ3JvdXAgewogICAgICAgICAgICBmbGV4LWRpcmVjdGlvbjogY29s
dW1uOwogICAgICAgICAgICBhbGlnbi1pdGVtczogc3RyZXRjaDsKICAgICAgICAgICAgZ2FwOiAwOwog
ICAgICAgICAgICBwYWRkaW5nOiA2cHggOHB4IDRweDsKICAgICAgICAgICAgY3Vyc29yOiBkZWZhdWx0
OwogICAgICAgIH0KICAgICAgICAuaXRtLml0LWdyb3VwOmhvdmVyIHsgYmFja2dyb3VuZDogdmFyKC0t
Y2FyZCk7IH0KICAgICAgICAubWctaGVhZCB7CiAgICAgICAgICAgIGRpc3BsYXk6IGZsZXg7IGFsaWdu
LWl0ZW1zOiBjZW50ZXI7IGdhcDogNnB4OwogICAgICAgICAgICBmb250LXNpemU6IDExcHg7IGNvbG9y
OiB2YXIoLS10eHQzKTsgZm9udC13ZWlnaHQ6IDYwMDsKICAgICAgICAgICAgcGFkZGluZzogMnB4IDJw
eCA2cHg7IHVzZXItc2VsZWN0OiBub25lOwogICAgICAgIH0KICAgICAgICAubWctaGVhZCAubWctdGFn
IHsKICAgICAgICAgICAgZGlzcGxheTogaW5saW5lLWZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7CiAg
ICAgICAgICAgIGhlaWdodDogMTZweDsgcGFkZGluZzogMCA2cHg7IGJvcmRlci1yYWRpdXM6IDhweDsK
ICAgICAgICAgICAgYmFja2dyb3VuZDogcmdiYSg5MSwxMTUsMjMyLC4xMik7IGNvbG9yOiB2YXIoLS1h
Y2MpOyBmb250LXNpemU6IDEwcHg7CiAgICAgICAgfQogICAgICAgIC5tZy1yb3cgewogICAgICAgICAg
ICBwYWRkaW5nOiA3cHggNnB4OyBtYXJnaW4tYm90dG9tOiAzcHg7CiAgICAgICAgICAgIGJvcmRlci1y
YWRpdXM6IDVweDsgY3Vyc29yOiBwb2ludGVyOwogICAgICAgICAgICBib3JkZXI6IDFweCBzb2xpZCB0
cmFuc3BhcmVudDsKICAgICAgICAgICAgdHJhbnNpdGlvbjogYmFja2dyb3VuZCAuMTJzIGVhc2UsIGJv
cmRlci1jb2xvciAuMTJzIGVhc2U7CiAgICAgICAgfQogICAgICAgIC5tZy1yb3c6aG92ZXIgeyBiYWNr
Z3JvdW5kOiB2YXIoLS1jYXJkLWgpOyB9CiAgICAgICAgLm1nLXJvdy5zZWwgewogICAgICAgICAgICBi
YWNrZ3JvdW5kOiAjZWRmMWZmOwogICAgICAgICAgICBib3JkZXItY29sb3I6IHJnYmEoOTEsMTE1LDIz
MiwuMzUpOwogICAgICAgICAgICBib3gtc2hhZG93OiAwIDAgMCAxcHggcmdiYSg5MSwxMTUsMjMyLC4y
NSk7CiAgICAgICAgfQogICAgICAgIC5tZy1yb3cubXVsdGkgewogICAgICAgICAgICBiYWNrZ3JvdW5k
OiAjZWVmMmZmOwogICAgICAgICAgICBib3JkZXItY29sb3I6IHJnYmEoOTEsMTE1LDIzMiwuNDUpOwog
ICAgICAgIH0KICAgICAgICAubWctdGl0bGUgewogICAgICAgICAgICBmb250LXNpemU6IDEzcHg7IGZv
bnQtd2VpZ2h0OiA2MDA7IGNvbG9yOiB2YXIoLS1hY2MpOwogICAgICAgICAgICBtYXJnaW4tYm90dG9t
OiAycHg7IGxpbmUtaGVpZ2h0OiAxLjM1OwogICAgICAgICAgICBkaXNwbGF5OiAtd2Via2l0LWJveDsg
LXdlYmtpdC1ib3gtb3JpZW50OiB2ZXJ0aWNhbDsgLXdlYmtpdC1saW5lLWNsYW1wOiAyOwogICAgICAg
ICAgICBvdmVyZmxvdzogaGlkZGVuOyB3b3JkLWJyZWFrOiBicmVhay13b3JkOwogICAgICAgIH0KICAg
ICAgICAubWctYm9keSB7CiAgICAgICAgICAgIGZvbnQtc2l6ZTogMTIuNXB4OyBmb250LXdlaWdodDog
NTAwOyBjb2xvcjogdmFyKC0tdHh0KTsKICAgICAgICAgICAgd2hpdGUtc3BhY2U6IHByZS13cmFwOyB3
b3JkLWJyZWFrOiBicmVhay1hbGw7CiAgICAgICAgICAgIGRpc3BsYXk6IC13ZWJraXQtYm94OyAtd2Vi
a2l0LWJveC1vcmllbnQ6IHZlcnRpY2FsOyAtd2Via2l0LWxpbmUtY2xhbXA6IDQ7CiAgICAgICAgICAg
IG92ZXJmbG93OiBoaWRkZW47IGxpbmUtaGVpZ2h0OiAxLjQ7CiAgICAgICAgfQogICAgICAgIC5tZy1i
b2R5LmltZyB7IGNvbG9yOiB2YXIoLS10eHQyKTsgfQogICAgICAgIC5tZy1yb3ctdG9wIHsKICAgICAg
ICAgICAgZGlzcGxheTogZmxleDsgYWxpZ24taXRlbXM6IGZsZXgtc3RhcnQ7IGdhcDogOHB4OwogICAg
ICAgIH0KICAgICAgICAubWctcm93LW1haW4geyBmbGV4OiAxOyBtaW4td2lkdGg6IDA7IH0KICAgICAg
ICAubWctc3JjIHsKICAgICAgICAgICAgd2lkdGg6IDE4cHg7IGhlaWdodDogMThweDsgZmxleC1zaHJp
bms6IDA7IG1hcmdpbi10b3A6IDJweDsKICAgICAgICAgICAgYm9yZGVyLXJhZGl1czogM3B4OyBvYmpl
Y3QtZml0OiBjb250YWluOwogICAgICAgICAgICBiYWNrZ3JvdW5kOiByZ2JhKDAsMCwwLC4wNCk7CiAg
ICAgICAgfQogICAgICAgIC5pLWZhdi10aXRsZSB7CiAgICAgICAgICAgIGZvbnQtc2l6ZTogMTNweDsg
Zm9udC13ZWlnaHQ6IDYwMDsgY29sb3I6IHZhcigtLWFjYyk7CiAgICAgICAgICAgIG1hcmdpbjogMCAw
IDNweDsgbGluZS1oZWlnaHQ6IDEuMzU7CiAgICAgICAgICAgIGRpc3BsYXk6IC13ZWJraXQtYm94OyAt
d2Via2l0LWJveC1vcmllbnQ6IHZlcnRpY2FsOyAtd2Via2l0LWxpbmUtY2xhbXA6IDI7CiAgICAgICAg
ICAgIG92ZXJmbG93OiBoaWRkZW47IHdvcmQtYnJlYWs6IGJyZWFrLXdvcmQ7CiAgICAgICAgfQogICAg
ICAgICN0aXRsZS1kbGcgewogICAgICAgICAgICBkaXNwbGF5OiBub25lOyBwb3NpdGlvbjogZml4ZWQ7
IGluc2V0OiAwOyB6LWluZGV4OiAxMDA7CiAgICAgICAgICAgIGJhY2tncm91bmQ6IHJnYmEoMTUsMTgs
MjgsLjM1KTsKICAgICAgICAgICAgYWxpZ24taXRlbXM6IGNlbnRlcjsganVzdGlmeS1jb250ZW50OiBj
ZW50ZXI7CiAgICAgICAgfQogICAgICAgICN0aXRsZS1kbGcub24geyBkaXNwbGF5OiBmbGV4OyB9CiAg
ICAgICAgI3RpdGxlLWRsZyAudGl0bGUtYm94IHsKICAgICAgICAgICAgd2lkdGg6IDI2MHB4OyBwYWRk
aW5nOiAxNnB4IDE2cHggMTJweDsKICAgICAgICAgICAgYmFja2dyb3VuZDogdmFyKC0tY2FyZCk7IGJv
cmRlci1yYWRpdXM6IDEwcHg7CiAgICAgICAgICAgIGJveC1zaGFkb3c6IDAgOHB4IDI4cHggcmdiYSgw
LDAsMCwuMTgpOwogICAgICAgIH0KICAgICAgICAjdGl0bGUtaW5wdXQgewogICAgICAgICAgICB3aWR0
aDogMTAwJTsgYm94LXNpemluZzogYm9yZGVyLWJveDsgbWFyZ2luOiA4cHggMCAxMnB4OwogICAgICAg
ICAgICBoZWlnaHQ6IDMycHg7IHBhZGRpbmc6IDAgMTBweDsgYm9yZGVyLXJhZGl1czogNnB4OwogICAg
ICAgICAgICBib3JkZXI6IDFweCBzb2xpZCAjZDVkYWU2OyBiYWNrZ3JvdW5kOiAjZmZmOyBjb2xvcjog
dmFyKC0tdHh0KTsKICAgICAgICAgICAgZm9udC1zaXplOiAxM3B4OyBvdXRsaW5lOiBub25lOwogICAg
ICAgIH0KICAgICAgICAjdGl0bGUtaW5wdXQ6Zm9jdXMgeyBib3JkZXItY29sb3I6IHZhcigtLWFjYyk7
IH0KCiAgICAKICAgICAgICAvKiB1aS1ncmF5LWJnLXYxICovCiAgICAgICAgOnJvb3QgewogICAgICAg
ICAgICAtLWJnOiAjZTRlN2VlICFpbXBvcnRhbnQ7CiAgICAgICAgfQogICAgICAgIGh0bWwsIGJvZHkg
ewogICAgICAgICAgICBiYWNrZ3JvdW5kOiAjZTRlN2VlICFpbXBvcnRhbnQ7CiAgICAgICAgfQogICAg
ICAgICNhcHAgewogICAgICAgICAgICBiYWNrZ3JvdW5kOiBsaW5lYXItZ3JhZGllbnQoMTgwZGVnLCAj
ZTllY2YzIDAlLCAjZTBlNGVjIDEwMCUpICFpbXBvcnRhbnQ7CiAgICAgICAgfQogICAgICAgICNoZHIg
ewogICAgICAgICAgICBiYWNrZ3JvdW5kOiAjZTJlNmVlICFpbXBvcnRhbnQ7CiAgICAgICAgfQogICAg
ICAgICN0YWJzIHsKICAgICAgICAgICAgYmFja2dyb3VuZDogI2UyZTZlZSAhaW1wb3J0YW50OwogICAg
ICAgIH0KICAgICAgICAjbGlzdCwgI2VtcHR5LCAjc2tlbCwgI2hkci1ncm93LCAjc2VhcmNoLXdyYXAg
ewogICAgICAgICAgICBiYWNrZ3JvdW5kOiB0cmFuc3BhcmVudCAhaW1wb3J0YW50OwogICAgICAgIH0K
ICAgICAgICAjc2VhcmNoLWJveCB7CiAgICAgICAgICAgIHRyYW5zZm9ybS1vcmlnaW46IHJpZ2h0IGNl
bnRlcjsKICAgICAgICAgICAgYmFja2dyb3VuZDogdHJhbnNwYXJlbnQgIWltcG9ydGFudDsKICAgICAg
ICB9CiAgICAgICAgLml0bSwgLm1nLCAubWctcm93LCAubWVyZ2UtZ3JvdXAgewogICAgICAgICAgICBi
YWNrZ3JvdW5kOiAjZmZmZmZmICFpbXBvcnRhbnQ7CiAgICAgICAgfQogICAgICAgIC5pdG06aG92ZXIg
ewogICAgICAgICAgICBiYWNrZ3JvdW5kOiAjZjhmOWZjICFpbXBvcnRhbnQ7CiAgICAgICAgfQogICAg
CiAgICAgICAgLyogc2VsLXRpbnQtYmx1ZS12MSAqLwogICAgICAgIC5pdG0uc2VsLAogICAgICAgIC5t
Zy1yb3cuc2VsLAogICAgICAgIC5pdG0ubXVsdGksCiAgICAgICAgLm1nLXJvdy5tdWx0aSwKICAgICAg
ICAuaXRtLm11bHRpLnNlbCwKICAgICAgICAuaXQtZ3JvdXAuc2VsLAogICAgICAgIC5pdC1ncm91cC5t
dWx0aSB7CiAgICAgICAgICAgIGJhY2tncm91bmQ6ICNlOGVmZmYgIWltcG9ydGFudDsKICAgICAgICB9
CiAgICAgICAgLml0bS5zZWw6aG92ZXIsCiAgICAgICAgLml0bS5tdWx0aTpob3ZlciwKICAgICAgICAu
bWctcm93LnNlbDpob3ZlciwKICAgICAgICAubWctcm93Lm11bHRpOmhvdmVyIHsKICAgICAgICAgICAg
YmFja2dyb3VuZDogI2RkZTZmZiAhaW1wb3J0YW50OwogICAgICAgIH0KICAgIAogICAgICAgIC8qIGhv
dmVyLWdyZWVuLXJpc2UtdjIgKi8KICAgICAgICAvKiBob3Zlci1hY2NlbnQtcmlzZS12MyAqLwogICAg
ICAgIC5pdG0geyBwb3NpdGlvbjogcmVsYXRpdmUgIWltcG9ydGFudDsgb3ZlcmZsb3c6IGhpZGRlbiAh
aW1wb3J0YW50OyB9CiAgICAgICAgLml0bTo6YmVmb3JlIHsKICAgICAgICAgICAgY29udGVudDogIiIg
IWltcG9ydGFudDsKICAgICAgICAgICAgcG9zaXRpb246IGFic29sdXRlICFpbXBvcnRhbnQ7CiAgICAg
ICAgICAgIGxlZnQ6IDAgIWltcG9ydGFudDsgcmlnaHQ6IDAgIWltcG9ydGFudDsgYm90dG9tOiAwICFp
bXBvcnRhbnQ7CiAgICAgICAgICAgIGhlaWdodDogMCAhaW1wb3J0YW50OwogICAgICAgICAgICBwb2lu
dGVyLWV2ZW50czogbm9uZSAhaW1wb3J0YW50OwogICAgICAgICAgICB6LWluZGV4OiAwICFpbXBvcnRh
bnQ7CiAgICAgICAgICAgIGJvcmRlci1yYWRpdXM6IDAgMCB2YXIoLS1yLCA0cHgpIHZhcigtLXIsIDRw
eCkgIWltcG9ydGFudDsKICAgICAgICAgICAgYmFja2dyb3VuZDogbGluZWFyLWdyYWRpZW50KHRvIHRv
cCwKICAgICAgICAgICAgICAgIHJnYmEoOTEsIDExNSwgMjMyLCAuMzIpIDAlLAogICAgICAgICAgICAg
ICAgcmdiYSg5MSwgMTE1LCAyMzIsIC4xMikgNTUlLAogICAgICAgICAgICAgICAgcmdiYSg5MSwgMTE1
LCAyMzIsIDApIDEwMCUpICFpbXBvcnRhbnQ7CiAgICAgICAgICAgIHRyYW5zaXRpb246IGhlaWdodCAu
MzRzIGN1YmljLWJlemllciguMjIsIDEsIC4zNiwgMSkgIWltcG9ydGFudDsKICAgICAgICB9CiAgICAg
ICAgLml0bTpob3Zlcjo6YmVmb3JlIHsgaGVpZ2h0OiAzMy4zMzMlICFpbXBvcnRhbnQ7IH0KICAgICAg
ICAuaXRtOjphZnRlciB7CiAgICAgICAgICAgIGNvbnRlbnQ6ICIiICFpbXBvcnRhbnQ7CiAgICAgICAg
ICAgIHBvc2l0aW9uOiBhYnNvbHV0ZSAhaW1wb3J0YW50OwogICAgICAgICAgICBsZWZ0OiAwICFpbXBv
cnRhbnQ7IHJpZ2h0OiAwICFpbXBvcnRhbnQ7IGJvdHRvbTogMCAhaW1wb3J0YW50OwogICAgICAgICAg
ICBoZWlnaHQ6IDJweCAhaW1wb3J0YW50OwogICAgICAgICAgICBwb2ludGVyLWV2ZW50czogbm9uZSAh
aW1wb3J0YW50OwogICAgICAgICAgICB6LWluZGV4OiAxICFpbXBvcnRhbnQ7CiAgICAgICAgICAgIGJh
Y2tncm91bmQ6IHJnYmEoOTEsIDExNSwgMjMyLCAuOTIpICFpbXBvcnRhbnQ7CiAgICAgICAgICAgIGJv
cmRlci1yYWRpdXM6IDFweCAhaW1wb3J0YW50OwogICAgICAgICAgICB0cmFuc2Zvcm06IHNjYWxlWCgw
KSAhaW1wb3J0YW50OwogICAgICAgICAgICB0cmFuc2Zvcm0tb3JpZ2luOiBjZW50ZXIgIWltcG9ydGFu
dDsKICAgICAgICAgICAgdHJhbnNpdGlvbjogdHJhbnNmb3JtIC4zcyBjdWJpYy1iZXppZXIoLjIyLCAx
LCAuMzYsIDEpICFpbXBvcnRhbnQ7CiAgICAgICAgfQogICAgICAgIC5pdG06aG92ZXI6OmFmdGVyIHsK
ICAgICAgICAgICAgdHJhbnNmb3JtOiBzY2FsZVgoMSkgIWltcG9ydGFudDsKICAgICAgICAgICAgYmFj
a2dyb3VuZDogcmdiYSg5MSwgMTE1LCAyMzIsIC45NSkgIWltcG9ydGFudDsKICAgICAgICB9CiAgICAg
ICAgLml0bSA+ICogeyBwb3NpdGlvbjogcmVsYXRpdmU7IHotaW5kZXg6IDI7IH0KICAgICAgICAvKiDl
jrvmjonpnaLmnb/mnIDlpJbmj4/ovrnvvJvmnaHnm67ljaHniYfovbvmgqzmta7ljprluqYgKi8KICAg
ICAgICBodG1sLCBib2R5LCAjYXBwIHsKICAgICAgICAgICAgYm9yZGVyOiBub25lICFpbXBvcnRhbnQ7
CiAgICAgICAgICAgIG91dGxpbmU6IG5vbmUgIWltcG9ydGFudDsKICAgICAgICAgICAgYm94LXNoYWRv
dzogbm9uZSAhaW1wb3J0YW50OwogICAgICAgIH0KICAgICAgICAjYXBwIHsKICAgICAgICAgICAgYm9y
ZGVyLXJhZGl1czogMCAhaW1wb3J0YW50OwogICAgICAgICAgICBib3gtc2l6aW5nOiBib3JkZXItYm94
ICFpbXBvcnRhbnQ7CiAgICAgICAgICAgIG92ZXJmbG93OiBoaWRkZW4gIWltcG9ydGFudDsKICAgICAg
ICB9CiAgICAgICAgLml0bSwgLm1nLCAubWVyZ2UtZ3JvdXAgewogICAgICAgICAgICBib3JkZXI6IG5v
bmUgIWltcG9ydGFudDsKICAgICAgICAgICAgYm9yZGVyLXJhZGl1czogNHB4ICFpbXBvcnRhbnQ7CiAg
ICAgICAgICAgIGJveC1zaGFkb3c6CiAgICAgICAgICAgICAgICAwIDFweCAycHggcmdiYSgyNCwgMzIs
IDU2LCAuMDUpLAogICAgICAgICAgICAgICAgMCAzcHggMTBweCByZ2JhKDI0LCAzMiwgNTYsIC4wOSkg
IWltcG9ydGFudDsKICAgICAgICB9CiAgICAgICAgLml0bTpob3ZlciwgLm1nOmhvdmVyLCAubWVyZ2Ut
Z3JvdXA6aG92ZXIgewogICAgICAgICAgICBib3gtc2hhZG93OgogICAgICAgICAgICAgICAgMCAycHgg
NHB4IHJnYmEoMjQsIDMyLCA1NiwgLjA3KSwKICAgICAgICAgICAgICAgIDAgNnB4IDE2cHggcmdiYSgy
NCwgMzIsIDU2LCAuMTMpICFpbXBvcnRhbnQ7CiAgICAgICAgfQogICAgICAgIC5pdG0uc2VsLAogICAg
ICAgIC5tZy1yb3cuc2VsLAogICAgICAgIC5pdG0ubXVsdGksCiAgICAgICAgLm1nLXJvdy5tdWx0aSwK
ICAgICAgICAuaXRtLm11bHRpLnNlbCwKICAgICAgICAuaXQtZ3JvdXAuc2VsLAogICAgICAgIC5pdC1n
cm91cC5tdWx0aSB7CiAgICAgICAgICAgIGJveC1zaGFkb3c6CiAgICAgICAgICAgICAgICAwIDAgMCAy
cHggcmdiYSg5MSwgMTE1LCAyMzIsIC40MiksCiAgICAgICAgICAgICAgICAwIDJweCA0cHggcmdiYSg5
MSwgMTE1LCAyMzIsIC4xMCksCiAgICAgICAgICAgICAgICAwIDZweCAxNHB4IHJnYmEoOTEsIDExNSwg
MjMyLCAuMTYpICFpbXBvcnRhbnQ7CiAgICAgICAgfQogICAgPC9zdHlsZT4KPC9oZWFkPgo8Ym9keSBk
YXRhLXVpLWJ1aWxkPSIyMDI2MDkwNy0yMzA3Ij4KPGRpdiBpZD0iYXBwIiBkYXRhLXVpLXZlcj0iMjAy
NjA5MTEtbG9jYXRlLWdyb3VwIiBkYXRhLXRhYj0iYWxsIj4KICAgIDxkaXYgaWQ9ImhkciI+CiAgICAg
ICAgPGRpdiBpZD0iaGVhcnQiPgogICAgICAgICAgICA8c3ZnIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmls
bD0ibm9uZSIgc3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0cm9rZS13aWR0aD0iMS44IgogICAgICAgICAg
ICAgICAgIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIgc3Ryb2tlLWxpbmVqb2luPSJyb3VuZCI+CiAgICAg
ICAgICAgICAgICA8cmVjdCB4PSI5IiB5PSIyIiB3aWR0aD0iNiIgaGVpZ2h0PSI0IiByeD0iMSIvPgog
ICAgICAgICAgICAgICAgPHBhdGggZD0iTTE2IDRoMmEyIDIgMCAwIDEgMiAydjE0YTIgMiAwIDAgMS0y
IDJINmEyIDIgMCAwIDEtMi0yVjZhMiAyIDAgMCAxIDItMmgyIi8+CiAgICAgICAgICAgICAgICA8cGF0
aCBkPSJNOSAxMmg2TTkgMTZoNCIvPgogICAgICAgICAgICA8L3N2Zz4KICAgICAgICA8L2Rpdj4KICAg
ICAgICA8ZGl2IGlkPSJoZHItZ3JvdyI+PC9kaXY+CiAgICAgICAgPGRpdiBpZD0ibXVsdGktYmFyIj4K
ICAgICAgICAgICAgPGJ1dHRvbiBpZD0ibXVsdGktc2VsIiB0eXBlPSJidXR0b24iIHRpdGxlPSLlj5bm
tojlpJrpgIkiPgogICAgICAgICAgICAgICAgPHNwYW4gaWQ9Im11bHRpLXNlbC1sYWIiPuW3sumAiTwv
c3Bhbj4KICAgICAgICAgICAgICAgIDxzcGFuIGlkPSJtdWx0aS1jbnQiPjA8L3NwYW4+CiAgICAgICAg
ICAgIDwvYnV0dG9uPgogICAgICAgICAgICA8ZGl2IGlkPSJwYXN0ZS1zZXAtd3JhcCI+CiAgICAgICAg
ICAgICAgICA8YnV0dG9uIGlkPSJwYXN0ZS1zZXAtYnRuIiB0eXBlPSJidXR0b24iIHRpdGxlPSLnspjo
tLTliIbpmpTnrKbvvIjngrnpgInnlKjlubbnspjotLTvvIkiPgogICAgICAgICAgICAgICAgICAgIDxz
cGFuIGlkPSJwYXN0ZS1zZXAtbGFiZWwiPuKQozwvc3Bhbj4KICAgICAgICAgICAgICAgIDwvYnV0dG9u
PgogICAgICAgICAgICAgICAgPGRpdiBpZD0icGFzdGUtc2VwLW1lbnUiPjwvZGl2PgogICAgICAgICAg
ICA8L2Rpdj4KICAgICAgICA8L2Rpdj4KICAgICAgICA8YnV0dG9uIGlkPSJidG4tbG9jYXRlIiB0eXBl
PSJidXR0b24iIHRpdGxlPSLlrprkvY3liLDkuIrmrKHkvb/nlKjnmoTmnaHnm64iIGRpc2FibGVkPgog
ICAgICAgICAgICA8c3ZnIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSJjdXJy
ZW50Q29sb3IiIHN0cm9rZS13aWR0aD0iMiIKICAgICAgICAgICAgICAgICBzdHJva2UtbGluZWNhcD0i
cm91bmQiIHN0cm9rZS1saW5lam9pbj0icm91bmQiPgogICAgICAgICAgICAgICAgPGNpcmNsZSBjeD0i
MTIiIGN5PSIxMiIgcj0iOCIvPgogICAgICAgICAgICAgICAgPGNpcmNsZSBjeD0iMTIiIGN5PSIxMiIg
cj0iMy41Ii8+CiAgICAgICAgICAgIDwvc3ZnPgogICAgICAgIDwvYnV0dG9uPgogICAgICAgIDxkaXYg
aWQ9InNlYXJjaC13cmFwIj4KICAgICAgICAgICAgPGJ1dHRvbiBpZD0iYnRuLXNlYXJjaCIgdHlwZT0i
YnV0dG9uIiB0aXRsZT0i5pCc57SiIj4KICAgICAgICAgICAgICAgIDxzdmcgdmlld0JveD0iMCAwIDI0
IDI0IiBmaWxsPSJub25lIiBzdHJva2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIyIgogICAg
ICAgICAgICAgICAgICAgICBzdHJva2UtbGluZWNhcD0icm91bmQiIHN0cm9rZS1saW5lam9pbj0icm91
bmQiPgogICAgICAgICAgICAgICAgICAgIDxjaXJjbGUgY3g9IjExIiBjeT0iMTEiIHI9IjciLz4KICAg
ICAgICAgICAgICAgICAgICA8cGF0aCBkPSJNMjAgMjBsLTMuNS0zLjUiLz4KICAgICAgICAgICAgICAg
IDwvc3ZnPgogICAgICAgICAgICA8L2J1dHRvbj4KICAgICAgICAgICAgPGRpdiBpZD0ic2VhcmNoLWJv
eCI+CiAgICAgICAgICAgICAgICA8YnV0dG9uIGlkPSJidG4tdG9kYXkiIHR5cGU9ImJ1dHRvbiI+5b2T
5aSpPC9idXR0b24+CiAgICAgICAgICAgICAgICA8aW5wdXQgaWQ9InNlYXJjaCIgdHlwZT0idGV4dCIg
cGxhY2Vob2xkZXI9IuaQnOe0ouKApiDnqbrmoLzliIbor43pobvlkIzml7bljIXlkKsgwrcgYXxiIOWI
huautSIgYXV0b2NvbXBsZXRlPSJvZmYiIHNwZWxsY2hlY2s9ImZhbHNlIj4KICAgICAgICAgICAgICAg
IDxidXR0b24gaWQ9InNlYXJjaC1jbHIiIHR5cGU9ImJ1dHRvbiI+4pyVPC9idXR0b24+CiAgICAgICAg
ICAgIDwvZGl2PgogICAgICAgIDwvZGl2PgogICAgICAgIDxidXR0b24gaWQ9ImJ0bi1waW4iIHR5cGU9
ImJ1dHRvbiIgdGl0bGU9IumSieWcqOWxj+W5leS4iiI+CiAgICAgICAgICAgIDxzdmcgdmlld0JveD0i
MCAwIDI0IDI0IiBmaWxsPSJub25lIiBzdHJva2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIy
IgogICAgICAgICAgICAgICAgIHN0cm9rZS1saW5lam9pbj0icm91bmQiIHN0cm9rZS1saW5lY2FwPSJy
b3VuZCI+CiAgICAgICAgICAgICAgICA8bGluZSB4MT0iMTIiIHkxPSIxNyIgeDI9IjEyIiB5Mj0iMjIi
Lz4KICAgICAgICAgICAgICAgIDxwYXRoIGQ9Ik01IDE3aDE0di0xLjc2YTIgMiAwIDAgMC0xLjExLTEu
NzlsLTEuNzgtLjlBMiAyIDAgMCAxIDE1IDEwLjc2VjZoMWEyIDIgMCAwIDAgMC00SDhhMiAyIDAgMCAw
IDAgNGgxdjQuNzZhMiAyIDAgMCAxLTEuMTEgMS43OWwtMS43OC45QTIgMiAwIDAgMCA1IDE1LjI0WiIv
PgogICAgICAgICAgICA8L3N2Zz4KICAgICAgICA8L2J1dHRvbj4KICAgIDwvZGl2PgoKICAgIDxkaXYg
aWQ9InRhYnMiPgogICAgICAgIDxkaXYgaWQ9InRhYi1pbmsiIGFyaWEtaGlkZGVuPSJ0cnVlIj48L2Rp
dj4KICAgICAgICA8ZGl2IGNsYXNzPSJ0YWIgb24iIGRhdGEtdGFiPSJhbGwiPuWFqOmDqDwvZGl2Pgog
ICAgICAgIDxkaXYgY2xhc3M9InRhYiIgZGF0YS10YWI9InRleHQiPuaWh+acrDwvZGl2PgogICAgICAg
IDxkaXYgY2xhc3M9InRhYiIgZGF0YS10YWI9ImltYWdlIj7lm77lg488L2Rpdj4KICAgICAgICA8ZGl2
IGNsYXNzPSJ0YWIiIGRhdGEtdGFiPSJmaWxlIj7mlofku7Y8L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNz
PSJ0YWIiIGRhdGEtdGFiPSJyZWNlbnQiPuacgOi/kTwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9InRh
YiIgZGF0YS10YWI9InBpbm5lZCI+5pS26JePIDxzcGFuIGlkPSJwaW4tZG90IiB0aXRsZT0i5pyJ5paw
5pS26JePIj48L3NwYW4+PC9kaXY+CiAgICAgICAgPGRpdiBpZD0idGFiLWFjdGlvbnMiPgogICAgICAg
ICAgICA8c3BhbiBpZD0iYmFyLXR4dCI+MDwvc3Bhbj4KICAgICAgICAgICAgPGJ1dHRvbiBpZD0iYnRu
LWNsciIgdHlwZT0iYnV0dG9uIiB0aXRsZT0i5riF56m65Y6G5Y+yIj4KICAgICAgICAgICAgICAgIDxz
dmcgdmlld0JveD0iMCAwIDI0IDI0IiBmaWxsPSJub25lIiBzdHJva2U9ImN1cnJlbnRDb2xvciIgc3Ry
b2tlLXdpZHRoPSIyIgogICAgICAgICAgICAgICAgICAgICBzdHJva2UtbGluZWNhcD0icm91bmQiIHN0
cm9rZS1saW5lam9pbj0icm91bmQiPgogICAgICAgICAgICAgICAgICAgIDxwb2x5bGluZSBwb2ludHM9
IjMgNiA1IDYgMjEgNiIvPgogICAgICAgICAgICAgICAgICAgIDxwYXRoIGQ9Ik0xOSA2bC0xIDE0YTIg
MiAwIDAgMS0yIDJIOGEyIDIgMCAwIDEtMi0yTDUgNiIvPgogICAgICAgICAgICAgICAgICAgIDxwYXRo
IGQ9Ik0xMCAxMXY2TTE0IDExdjZNOSA2VjRoNnYyIi8+CiAgICAgICAgICAgICAgICA8L3N2Zz4KICAg
ICAgICAgICAgPC9idXR0b24+CiAgICAgICAgPC9kaXY+CiAgICA8L2Rpdj4KCiAgICA8ZGl2IGlkPSJs
aXN0Ij4KICAgICAgICA8ZGl2IGlkPSJza2VsIiBhcmlhLWhpZGRlbj0idHJ1ZSI+CiAgICAgICAgICAg
IDxkaXYgY2xhc3M9InNrLXJvdyI+PGRpdiBjbGFzcz0ic2staWNvIj48L2Rpdj48ZGl2IGNsYXNzPSJz
ay1ib2R5Ij48ZGl2IGNsYXNzPSJzay1saW5lIG1pZCI+PC9kaXY+PGRpdiBjbGFzcz0ic2stbGluZSBz
aG9ydCI+PC9kaXY+PC9kaXY+PC9kaXY+CiAgICAgICAgICAgIDxkaXYgY2xhc3M9InNrLXJvdyI+PGRp
diBjbGFzcz0ic2staWNvIj48L2Rpdj48ZGl2IGNsYXNzPSJzay1ib2R5Ij48ZGl2IGNsYXNzPSJzay1s
aW5lIj48L2Rpdj48ZGl2IGNsYXNzPSJzay1saW5lIG1pZCI+PC9kaXY+PC9kaXY+PC9kaXY+CiAgICAg
ICAgICAgIDxkaXYgY2xhc3M9InNrLXJvdyI+PGRpdiBjbGFzcz0ic2staWNvIj48L2Rpdj48ZGl2IGNs
YXNzPSJzay1ib2R5Ij48ZGl2IGNsYXNzPSJzay1saW5lIG1pZCI+PC9kaXY+PGRpdiBjbGFzcz0ic2st
bGluZSBzaG9ydCI+PC9kaXY+PC9kaXY+PC9kaXY+CiAgICAgICAgICAgIDxkaXYgY2xhc3M9InNrLXJv
dyI+PGRpdiBjbGFzcz0ic2staWNvIj48L2Rpdj48ZGl2IGNsYXNzPSJzay1ib2R5Ij48ZGl2IGNsYXNz
PSJzay1saW5lIj48L2Rpdj48ZGl2IGNsYXNzPSJzay1saW5lIG1pZCI+PC9kaXY+PC9kaXY+PC9kaXY+
CiAgICAgICAgICAgIDxkaXYgY2xhc3M9InNrLXJvdyI+PGRpdiBjbGFzcz0ic2staWNvIj48L2Rpdj48
ZGl2IGNsYXNzPSJzay1ib2R5Ij48ZGl2IGNsYXNzPSJzay1saW5lIG1pZCI+PC9kaXY+PGRpdiBjbGFz
cz0ic2stbGluZSBzaG9ydCI+PC9kaXY+PC9kaXY+PC9kaXY+CiAgICAgICAgICAgIDxkaXYgY2xhc3M9
InNrLXJvdyI+PGRpdiBjbGFzcz0ic2staWNvIj48L2Rpdj48ZGl2IGNsYXNzPSJzay1ib2R5Ij48ZGl2
IGNsYXNzPSJzay1saW5lIj48L2Rpdj48ZGl2IGNsYXNzPSJzay1saW5lIHNob3J0Ij48L2Rpdj48L2Rp
dj48L2Rpdj4KICAgICAgICA8L2Rpdj4KICAgICAgICA8ZGl2IGlkPSJlbXB0eSI+CiAgICAgICAgICAg
IDxkaXYgY2xhc3M9ImUtdHh0IiBpZD0iZW1wdHktdHh0Ij7mmoLml6DorrDlvZXvvIzlpI3liLblkI7o
h6rliqjlh7rnjrA8L2Rpdj4KICAgICAgICA8L2Rpdj4KICAgIDwvZGl2PgogICAgPGJ1dHRvbiBpZD0i
YnRuLXRvcCIgdHlwZT0iYnV0dG9uIiB0aXRsZT0i5Zue5Yiw6aG26YOoIiBhcmlhLWxhYmVsPSLlm57l
iLDpobbpg6giPgogICAgICAgIDxzdmcgdmlld0JveD0iMCAwIDI0IDI0IiBmaWxsPSJub25lIiBzdHJv
a2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIyLjIiCiAgICAgICAgICAgICBzdHJva2UtbGlu
ZWNhcD0icm91bmQiIHN0cm9rZS1saW5lam9pbj0icm91bmQiPgogICAgICAgICAgICA8cGF0aCBkPSJN
MTIgMTlWNSIvPgogICAgICAgICAgICA8cGF0aCBkPSJNNSAxMmw3LTcgNyA3Ii8+CiAgICAgICAgPC9z
dmc+CiAgICA8L2J1dHRvbj4KPC9kaXY+Cgo8ZGl2IGlkPSJjdHgiPgogICAgPGRpdiBjbGFzcz0iYy1p
dGVtIiBpZD0iYy1jb3B5Ij48c3BhbiBjbGFzcz0iYy1pY28iPuKOmDwvc3Bhbj7lpI3liLY8L2Rpdj4K
ICAgIDxkaXYgY2xhc3M9ImMtaXRlbSIgaWQ9ImMtcGFzdGUiPjxzcGFuIGNsYXNzPSJjLWljbyI+4o+O
PC9zcGFuPueymOi0tDwvZGl2PgogICAgPGRpdiBjbGFzcz0iYy1zZXAiIGlkPSJjLWRhdGEtc2VwIiBz
dHlsZT0iZGlzcGxheTpub25lIj48L2Rpdj4KICAgIDxkaXYgY2xhc3M9ImMtc3Vid3JhcCIgaWQ9ImMt
ZGF0YS13cmFwIiBzdHlsZT0iZGlzcGxheTpub25lIj4KICAgICAgICA8ZGl2IGNsYXNzPSJjLWl0ZW0i
IGlkPSJjLWRhdGEiPjxzcGFuIGNsYXNzPSJjLWljbyI+zqM8L3NwYW4+5pWw5o2u5aSE55CGPHNwYW4g
Y2xhc3M9ImMtY2FyZXQiPuKAujwvc3Bhbj48L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJjLXN1YiIg
aWQ9ImMtZGF0YS1zdWIiPgogICAgICAgICAgICA8ZGl2IGNsYXNzPSJjLWl0ZW0iIGlkPSJjLWRhdGEt
YnJhY2UiIHRpdGxlPSJ7YSxifSAvIGEsYiDihpIgU1FMIj4KICAgICAgICAgICAgICAgIDxzcGFuIGNs
YXNzPSJjLW51bSI+MTwvc3Bhbj48c3BhbiBjbGFzcz0iYy1mcm9tIj57YSxifTwvc3Bhbj48c3BhbiBj
bGFzcz0iYy1hcnJvdyI+4oaSPC9zcGFuPjxzcGFuIGNsYXNzPSJjLXRvIj4oJ2EnLCdiJyk8L3NwYW4+
CiAgICAgICAgICAgIDwvZGl2PgogICAgICAgICAgICA8ZGl2IGNsYXNzPSJjLWl0ZW0iIGlkPSJjLWRh
dGEtbGluZXMiIHRpdGxlPSLmjaLooYzliIbpmpQg4oaSIFNRTCI+CiAgICAgICAgICAgICAgICA8c3Bh
biBjbGFzcz0iYy1udW0iPjI8L3NwYW4+PHNwYW4gY2xhc3M9ImMtZnJvbSI+YSBcbiBiPC9zcGFuPjxz
cGFuIGNsYXNzPSJjLWFycm93Ij7ihpI8L3NwYW4+PHNwYW4gY2xhc3M9ImMtdG8iPignYScsJ2InKTwv
c3Bhbj4KICAgICAgICAgICAgPC9kaXY+CiAgICAgICAgICAgIDxkaXYgY2xhc3M9ImMtaXRlbSIgaWQ9
ImMtZGF0YS1qc29uIiB0aXRsZT0iSlNPTiDljrvovazkuYnvvJpcJnF1b3Q7IOKGkiAmcXVvdDsiPgog
ICAgICAgICAgICAgICAgPHNwYW4gY2xhc3M9ImMtbnVtIj4zPC9zcGFuPjxzcGFuIGNsYXNzPSJjLWZy
b20iPmpzb24gICZxdW90O1wmcXVvdDs8L3NwYW4+PHNwYW4gY2xhc3M9ImMtYXJyb3ciPuKGkjwvc3Bh
bj48c3BhbiBjbGFzcz0iYy10byI+JnF1b3Q7ICZxdW90Ozwvc3Bhbj4KICAgICAgICAgICAgPC9kaXY+
CiAgICAgICAgPC9kaXY+CiAgICA8L2Rpdj4KICAgIDxkaXYgY2xhc3M9ImMtc2VwIj48L2Rpdj4KICAg
IDxkaXYgY2xhc3M9ImMtaXRlbSIgaWQ9ImMtcGluIj48c3BhbiBjbGFzcz0iYy1pY28iPuKYhTwvc3Bh
bj7mlLbol488L2Rpdj4KICAgIDxkaXYgY2xhc3M9ImMtaXRlbSIgaWQ9ImMtdGl0bGUiIHN0eWxlPSJk
aXNwbGF5Om5vbmUiPjxzcGFuIGNsYXNzPSJjLWljbyI+4pyOPC9zcGFuPuiuvue9ruagh+mimDwvZGl2
PgogICAgPGRpdiBjbGFzcz0iYy1pdGVtIiBpZD0iYy1tZXJnZSIgc3R5bGU9ImRpc3BsYXk6bm9uZSI+
PHNwYW4gY2xhc3M9ImMtaWNvIj7ip4k8L3NwYW4+5ZCI5bm2PC9kaXY+CiAgICA8ZGl2IGNsYXNzPSJj
LWl0ZW0iIGlkPSJjLXVubWVyZ2UiIHN0eWxlPSJkaXNwbGF5Om5vbmUiPjxzcGFuIGNsYXNzPSJjLWlj
byI+4oeEPC9zcGFuPuWPlua2iOWQiOW5tjwvZGl2PgogICAgPGRpdiBjbGFzcz0iYy1pdGVtIiBpZD0i
Yy10b3AiPjxzcGFuIGNsYXNzPSJjLWljbyI+4oaRPC9zcGFuPuenu+WIsOmhtumDqDwvZGl2PgogICAg
PGRpdiBjbGFzcz0iYy1pdGVtIiBpZD0iYy1jbGVhci1wYXN0ZWQiIHN0eWxlPSJkaXNwbGF5Om5vbmUi
PjxzcGFuIGNsYXNzPSJjLWljbyI+4pyTPC9zcGFuPua4hemZpOeKtuaAgTwvZGl2PgogICAgPGRpdiBj
bGFzcz0iYy1pdGVtIiBpZD0iYy1xdWV1ZS1mcm9tIiBzdHlsZT0iZGlzcGxheTpub25lIj48c3BhbiBj
bGFzcz0iYy1pY28iPuKGuzwvc3Bhbj7ku47mraTlpITlvIDlp4vpmJ/liJc8L2Rpdj4KICAgIDxkaXYg
Y2xhc3M9ImMtc2VwIj48L2Rpdj4KICAgIDxkaXYgY2xhc3M9ImMtaXRlbSBkYW5nZXIiIGlkPSJjLWRl
bCI+PHNwYW4gY2xhc3M9ImMtaWNvIj7inJU8L3NwYW4+5Yig6ZmkPC9kaXY+CjwvZGl2PgoKPGRpdiBp
ZD0iY2xyLWRsZyI+CiAgICA8ZGl2IGNsYXNzPSJjbHItYm94IiByb2xlPSJkaWFsb2ciIGFyaWEtbW9k
YWw9InRydWUiPgogICAgICAgIDxkaXYgY2xhc3M9ImNsci10aXRsZSIgaWQ9ImNsci10aXRsZSI+56Gu
6K6k5riF56m677yfPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0iY2xyLWRlc2MiIGlkPSJjbHItZGVz
YyI+6buY6K6k5LuF5riF56m65b2T5aSp5YaF5a6544CCPC9kaXY+CiAgICAgICAgPGxhYmVsIGNsYXNz
PSJjbHItY2hlY2siIGZvcj0iY2xyLWFsbCI+CiAgICAgICAgICAgIDxpbnB1dCB0eXBlPSJjaGVja2Jv
eCIgaWQ9ImNsci1hbGwiPgogICAgICAgICAgICA8c3Bhbj7muIXnqbrmiYDmnIk8L3NwYW4+CiAgICAg
ICAgPC9sYWJlbD4KICAgICAgICA8ZGl2IGNsYXNzPSJjbHItYnRucyI+CiAgICAgICAgICAgIDxidXR0
b24gdHlwZT0iYnV0dG9uIiBpZD0iY2xyLWNhbmNlbCI+5Y+W5raIPC9idXR0b24+CiAgICAgICAgICAg
IDxidXR0b24gdHlwZT0iYnV0dG9uIiBpZD0iY2xyLW9rIj7muIXnqbo8L2J1dHRvbj4KICAgICAgICA8
L2Rpdj4KICAgIDwvZGl2Pgo8L2Rpdj4KCjxkaXYgaWQ9InRpdGxlLWRsZyI+CiAgICA8ZGl2IGNsYXNz
PSJ0aXRsZS1ib3giIHJvbGU9ImRpYWxvZyIgYXJpYS1tb2RhbD0idHJ1ZSI+CiAgICAgICAgPGRpdiBj
bGFzcz0iY2xyLXRpdGxlIj7orr7nva7moIfpopg8L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJjbHIt
ZGVzYyI+5qCH6aKY5Y+v6KKr5pCc57Si5om+5Yiw77yM5LuF55So5LqO5pS26JeP5pW055CG44CCPC9k
aXY+CiAgICAgICAgPGlucHV0IGlkPSJ0aXRsZS1pbnB1dCIgdHlwZT0idGV4dCIgbWF4bGVuZ3RoPSI4
MCIgcGxhY2Vob2xkZXI9Iue7mei/meadoeaUtuiXj+i1t+S4quWQjeWtl+KApiIgYXV0b2NvbXBsZXRl
PSJvZmYiIHNwZWxsY2hlY2s9ImZhbHNlIj4KICAgICAgICA8ZGl2IGNsYXNzPSJjbHItYnRucyI+CiAg
ICAgICAgICAgIDxidXR0b24gdHlwZT0iYnV0dG9uIiBpZD0idGl0bGUtY2FuY2VsIj7lj5bmtog8L2J1
dHRvbj4KICAgICAgICAgICAgPGJ1dHRvbiB0eXBlPSJidXR0b24iIGlkPSJ0aXRsZS1vayI+5L+d5a2Y
PC9idXR0b24+CiAgICAgICAgPC9kaXY+CiAgICA8L2Rpdj4KPC9kaXY+CjxkaXYgaWQ9InBhdGgtdGlw
IiBhcmlhLWhpZGRlbj0idHJ1ZSI+PC9kaXY+Cgo8c2NyaXB0PgovKiDnpoHmraIgQ3RybCvmu5rova7n
vKnmlL7vvIhXZWJWaWV3IOiuvue9riArIOmhtemdouWFnOW6le+8iSAqLwooZnVuY3Rpb24oKXsKICBj
b25zdCBibG9ja1pvb20gPSBlID0+IHsKICAgIGlmIChlLmN0cmxLZXkgfHwgZS5tZXRhS2V5KSB7CiAg
ICAgIGUucHJldmVudERlZmF1bHQoKTsKICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgIH0KICB9
OwogIHdpbmRvdy5hZGRFdmVudExpc3RlbmVyKCd3aGVlbCcsIGJsb2NrWm9vbSwgeyBwYXNzaXZlOiBm
YWxzZSwgY2FwdHVyZTogdHJ1ZSB9KTsKICB3aW5kb3cuYWRkRXZlbnRMaXN0ZW5lcignZ2VzdHVyZXN0
YXJ0JywgZSA9PiBlLnByZXZlbnREZWZhdWx0KCksIHsgcGFzc2l2ZTogZmFsc2UsIGNhcHR1cmU6IHRy
dWUgfSk7CiAgZG9jdW1lbnQuYWRkRXZlbnRMaXN0ZW5lcigna2V5ZG93bicsIGUgPT4gewogICAgaWYg
KCEoZS5jdHJsS2V5IHx8IGUubWV0YUtleSkpIHJldHVybjsKICAgIGlmIChlLmtleSA9PT0gJysnIHx8
IGUua2V5ID09PSAnLScgfHwgZS5rZXkgPT09ICc9JyB8fCBlLmtleSA9PT0gJ18nCiAgICAgICAgfHwg
ZS5jb2RlID09PSAnTnVtcGFkQWRkJyB8fCBlLmNvZGUgPT09ICdOdW1wYWRTdWJ0cmFjdCcKICAgICAg
ICB8fCBlLmtleSA9PT0gJzAnKSB7CiAgICAgIC8vIGFsbG93IG5vdGhpbmcgZm9yIHpvb207IEN0cmwr
MCAvIMKxCiAgICAgIGlmIChlLmtleSA9PT0gJzAnIHx8IGUua2V5ID09PSAnKycgfHwgZS5rZXkgPT09
ICctJyB8fCBlLmtleSA9PT0gJz0nIHx8IGUua2V5ID09PSAnXycKICAgICAgICAgIHx8IGUuY29kZSA9
PT0gJ051bXBhZEFkZCcgfHwgZS5jb2RlID09PSAnTnVtcGFkU3VidHJhY3QnKSB7CiAgICAgICAgZS5w
cmV2ZW50RGVmYXVsdCgpOwogICAgICB9CiAgICB9CiAgfSwgdHJ1ZSk7Cn0pKCk7Cjwvc2NyaXB0Pgo8
c2NyaXB0PgovKiBza2VsLWZhaWxzYWZlOiBvbmx5IGlmIG1haW4gVUkgc2NyaXB0IG5ldmVyIGJvb3Rl
ZCDigJRuZXZlciBpbnZlbnQgZW1wdHktc3RhdGUgKi8KKGZ1bmN0aW9uKCl7CiAgc2V0VGltZW91dCgo
KSA9PiB7CiAgICB0cnkgewogICAgICBpZiAod2luZG93Ll9fdWlCb290ZWQpIHJldHVybjsKICAgICAg
dmFyIGFwcCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdhcHAnKTsKICAgICAgaWYgKGFwcCkgYXBw
LmNsYXNzTGlzdC5yZW1vdmUoJ2Jvb3QtbG9hZGluZycpOwogICAgICB2YXIgcyA9IGRvY3VtZW50Lmdl
dEVsZW1lbnRCeUlkKCdza2VsJyk7CiAgICAgIGlmIChzKSBzLmNsYXNzTGlzdC5yZW1vdmUoJ29uJyk7
CiAgICB9IGNhdGNoIChlcnIpIHt9CiAgfSwgMzAwMCk7Cn0pKCk7Cjwvc2NyaXB0Pgo8c2NyaXB0Pgog
ICAgbGV0IGFsbENsaXBzID0gW10sIGN1clRhYiA9ICdhbGwnLCBxdWVyeSA9ICcnLCBjdHhDbGlwID0g
bnVsbCwgc2VsZWN0ZWRJZCA9IDAsIHBpbm5lZFVJID0gZmFsc2U7CiAgICBjb25zdCBUQUJfT1JERVIg
PSBbJ2FsbCcsICd0ZXh0JywgJ2ltYWdlJywgJ2ZpbGUnLCAncmVjZW50JywgJ3Bpbm5lZCddOwogICAg
Y29uc3Qgdmlld01lbSA9IG5ldyBNYXAoKTsKICAgIGZ1bmN0aW9uIHZpZXdNZW1LZXkodGFiLCBxLCB0
b2RheSkgewogICAgICAgIHJldHVybiBTdHJpbmcodGFiIHx8ICdhbGwnKSArICdcdCcgKyBTdHJpbmco
cSB8fCAnJykgKyAnXHQnICsgKHRvZGF5ID8gJzEnIDogJzAnKTsKICAgIH0KICAgIGxldCB0YWJTd2l0
Y2hBbmltRGlyID0gMDsKICAgIGxldCBtdWx0aUlkcyA9IFtdOwogICAgbGV0IHRvZGF5T25seSA9IGZh
bHNlOwogICAgbGV0IGRpc2tUb3RhbCA9IDA7CiAgICBsZXQgbG9hZGluZ01vcmUgPSBmYWxzZTsKICAg
IC8vIERvbid0IHNob3cgc2tlbGV0b24gaW1tZWRpYXRlbHkg4oCUb25seSBhZnRlciBTS0VMX0RFTEFZ
X01TIGlmIGRhdGEgc3RpbGwgbWlzc2luZwogICAgbGV0IGJvb3RMb2FkaW5nID0gZmFsc2U7CiAgICBs
ZXQgd2FpdGluZ0RhdGEgPSBmYWxzZTsKICAgIGxldCBob3N0UHVzaGVkT25jZSA9IGZhbHNlOyAvLyBv
bmx5IHRoZW4gbWF5IHNob3fjgIzmmoLml6DorrDlvZXjgI0KICAgIGxldCBzYXdOb25FbXB0eSA9IGZh
bHNlOyAgICAvLyBpZ25vcmUgYm9vdHN0cmFwIGVtcHR5IHB1c2hlcyBiZWZvcmUgZmlyc3QgcmVhbCBs
aXN0CiAgICBsZXQgcGlubmVkVG90YWwgPSAwOyAgICAgICAgLy8gYXV0aG9yaXRhdGl2ZSDmlLbol48g
Y291bnQgZnJvbSBBSEsKICAgIGxldCB1bnNlZW5GYXZJZHMgPSBuZXcgU2V0KCk7CiAgICB0cnkgewog
ICAgICAgIGNvbnN0IHJhdyA9IGxvY2FsU3RvcmFnZS5nZXRJdGVtKCdjbGlwX3Vuc2Vlbl9mYXYnKTsK
ICAgICAgICBpZiAocmF3KSBKU09OLnBhcnNlKHJhdykuZm9yRWFjaChpZCA9PiB7IGlkID0gK2lkOyBp
ZiAoaWQpIHVuc2VlbkZhdklkcy5hZGQoaWQpOyB9KTsKICAgIH0gY2F0Y2gge30KICAgIGZ1bmN0aW9u
IHNhdmVVbnNlZW5GYXYoKSB7CiAgICAgICAgdHJ5IHsgbG9jYWxTdG9yYWdlLnNldEl0ZW0oJ2NsaXBf
dW5zZWVuX2ZhdicsIEpTT04uc3RyaW5naWZ5KFsuLi51bnNlZW5GYXZJZHNdKSk7IH0gY2F0Y2gge30K
ICAgIH0KICAgIGZ1bmN0aW9uIHVwZGF0ZVBpbkRvdCgpIHsKICAgICAgICBjb25zdCBlbCA9IGRvY3Vt
ZW50LmdldEVsZW1lbnRCeUlkKCdwaW4tZG90Jyk7CiAgICAgICAgaWYgKCFlbCkgcmV0dXJuOwogICAg
ICAgIGVsLmNsYXNzTGlzdC50b2dnbGUoJ29uJywgdW5zZWVuRmF2SWRzLnNpemUgPiAwKTsKICAgIH0K
ICAgIGZ1bmN0aW9uIG1hcmtGYXZVbnNlZW4oaWQpIHsKICAgICAgICBpZCA9ICtpZDsKICAgICAgICBp
ZiAoIWlkKSByZXR1cm47CiAgICAgICAgdW5zZWVuRmF2SWRzLmFkZChpZCk7CiAgICAgICAgc2F2ZVVu
c2VlbkZhdigpOwogICAgICAgIHVwZGF0ZVBpbkRvdCgpOwogICAgfQogICAgZnVuY3Rpb24gY2xlYXJG
YXZVbnNlZW4oKSB7CiAgICAgICAgaWYgKCF1bnNlZW5GYXZJZHMuc2l6ZSkgewogICAgICAgICAgICB1
cGRhdGVQaW5Eb3QoKTsKICAgICAgICAgICAgcmV0dXJuOwogICAgICAgIH0KICAgICAgICB1bnNlZW5G
YXZJZHMuY2xlYXIoKTsKICAgICAgICBzYXZlVW5zZWVuRmF2KCk7CiAgICAgICAgdXBkYXRlUGluRG90
KCk7CiAgICB9CiAgICBjb25zdCBTS0VMX0RFTEFZX01TID0gNjA7CiAgICB3aW5kb3cuX19kYXRhUmVh
ZHkgPSBmYWxzZTsKICAgIHdpbmRvdy5fX3VpQm9vdGVkID0gdHJ1ZTsKICAgIC8vIE9wZW4gcGFuZWwg
d2l0aG91dCBwYXN0aW5nIOKGkiBhbHdheXMgbGFuZCBvbiBmaXJzdCBpdGVtIChhZnRlciBkYXRhIGFy
cml2ZXMpCiAgICBsZXQgc2VsZWN0Rmlyc3RPblNob3cgPSBmYWxzZTsKICAgIGxldCBsYXN0UGFzdGVJ
ZCA9IDA7CiAgICBsZXQgbGFzdFBhc3RlVGFiID0gJ2FsbCc7CiAgICBsZXQgbGFzdFBhc3RlR3JvdXAg
PSAnJzsKICAgIGxldCBsb2NhdGVBY3RpdmUgPSBmYWxzZTsKICAgIHRyeSB7IGxhc3RQYXN0ZUlkID0g
K2xvY2FsU3RvcmFnZS5nZXRJdGVtKCdjbGlwTGFzdFBhc3RlSWQnKSB8fCAwOyB9IGNhdGNoIHt9CiAg
ICB0cnkgewogICAgICAgIGNvbnN0IHQgPSBsb2NhbFN0b3JhZ2UuZ2V0SXRlbSgnY2xpcExhc3RQYXN0
ZVRhYicpIHx8ICdhbGwnOwogICAgICAgIGxhc3RQYXN0ZVRhYiA9IFsnYWxsJywndGV4dCcsJ2ltYWdl
JywnZmlsZScsJ3Bpbm5lZCddLmluY2x1ZGVzKHQpID8gdCA6ICdhbGwnOwogICAgfSBjYXRjaCB7fQog
ICAgdHJ5IHsgbGFzdFBhc3RlR3JvdXAgPSBTdHJpbmcobG9jYWxTdG9yYWdlLmdldEl0ZW0oJ2NsaXBM
YXN0UGFzdGVHcm91cCcpIHx8ICcnKS50cmltKCk7IH0gY2F0Y2gge30KICAgIC8vIExvY2FsIFdlYlZp
ZXcgdmlydHVhbC1ob3N0IG9ubHkg4oCUIG5ldmVyIHJlcXVlc3QgdGhlIHB1YmxpYyBpbnRlcm5ldAog
ICAgZnVuY3Rpb24gc3RvcmVCYXNlVXJsKCkgewogICAgICAgIHRyeSB7CiAgICAgICAgICAgIGlmIChs
b2NhdGlvbi5vcmlnaW4gJiYgL15odHRwcz86XC9cLy9pLnRlc3QobG9jYXRpb24ub3JpZ2luKSkKICAg
ICAgICAgICAgICAgIHJldHVybiBsb2NhdGlvbi5vcmlnaW4ucmVwbGFjZSgvXC8kLywgJycpICsgJy9j
bGlwc19zdG9yZS8nOwogICAgICAgIH0gY2F0Y2gge30KICAgICAgICByZXR1cm4gJy9jbGlwc19zdG9y
ZS8nOwogICAgfQogICAgY29uc3QgU1RPUkVfQkFTRSA9IHN0b3JlQmFzZVVybCgpOwogICAgY29uc3Qg
U1RPUkVfQkFTRV9GQUxMQkFDSyA9IFNUT1JFX0JBU0U7CiAgICBmdW5jdGlvbiBtZXRhQ2VudGVySHRt
bChleHBhbmRJbm5lcikgewogICAgICAgIGlmIChleHBhbmRJbm5lciA9PSBudWxsIHx8IGV4cGFuZElu
bmVyID09PSBmYWxzZSkKICAgICAgICAgICAgcmV0dXJuIGA8c3BhbiBjbGFzcz0iaS1tZXRhLWNlbnRl
ciI+PC9zcGFuPmA7CiAgICAgICAgcmV0dXJuIGA8c3BhbiBjbGFzcz0iaS1tZXRhLWNlbnRlciI+PGJ1
dHRvbiBjbGFzcz0iaS1leHBhbmQtYnRuJHtleHBhbmRJbm5lci5vbiA/ICcgb24nIDogJyd9IiB0eXBl
PSJidXR0b24iIHRpdGxlPSLlsZXlvIAv5pS26LW3Ij4ke2V4cGFuZElubmVyLmh0bWx9PC9idXR0b24+
PC9zcGFuPmA7CiAgICB9CgogICAgZnVuY3Rpb24gcmVtZW1iZXJMYXN0UGFzdGUoaWQpIHsKICAgICAg
ICBsYXN0UGFzdGVJZCA9ICtpZCB8fCAwOwogICAgICAgIGxhc3RQYXN0ZVRhYiA9IGN1clRhYiB8fCAn
YWxsJzsKICAgICAgICBsYXN0UGFzdGVHcm91cCA9ICcnOwogICAgICAgIHRyeSB7CiAgICAgICAgICAg
IGNvbnN0IGhpdCA9IChhbGxDbGlwcyB8fCBbXSkuZmluZChjID0+ICtjLmlkID09PSArbGFzdFBhc3Rl
SWQpOwogICAgICAgICAgICBpZiAoaGl0KSBsYXN0UGFzdGVHcm91cCA9IFN0cmluZyhoaXQuZmF2R3Jv
dXAgfHwgJycpLnRyaW0oKTsKICAgICAgICB9IGNhdGNoIHt9CiAgICAgICAgdHJ5IHsKICAgICAgICAg
ICAgbG9jYWxTdG9yYWdlLnNldEl0ZW0oJ2NsaXBMYXN0UGFzdGVJZCcsIFN0cmluZyhsYXN0UGFzdGVJ
ZCkpOwogICAgICAgICAgICBsb2NhbFN0b3JhZ2Uuc2V0SXRlbSgnY2xpcExhc3RQYXN0ZVRhYicsIGxh
c3RQYXN0ZVRhYik7CiAgICAgICAgICAgIGxvY2FsU3RvcmFnZS5zZXRJdGVtKCdjbGlwTGFzdFBhc3Rl
R3JvdXAnLCBsYXN0UGFzdGVHcm91cCk7CiAgICAgICAgfSBjYXRjaCB7fQogICAgICAgIHVwZGF0ZUxv
Y2F0ZUJ0bigpOwogICAgfQogICAgZnVuY3Rpb24gdXBkYXRlTG9jYXRlQnRuKCkgewogICAgICAgIGNv
bnN0IGJ0biA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdidG4tbG9jYXRlJyk7CiAgICAgICAgaWYg
KCFidG4pIHJldHVybjsKICAgICAgICBidG4uZGlzYWJsZWQgPSAhbGFzdFBhc3RlSWQ7CiAgICAgICAg
YnRuLmNsYXNzTGlzdC50b2dnbGUoJ2hhcy10YXJnZXQnLCAhIWxhc3RQYXN0ZUlkKTsKICAgICAgICBi
dG4uY2xhc3NMaXN0LnRvZ2dsZSgnb24nLCBsb2NhdGVBY3RpdmUgJiYgISFsYXN0UGFzdGVJZCk7CiAg
ICAgICAgYnRuLnRpdGxlID0gIWxhc3RQYXN0ZUlkCiAgICAgICAgICAgID8gJ+aaguaXoOS4iuasoeS9
v+eUqOS9jee9ricKICAgICAgICAgICAgOiAobG9jYXRlQWN0aXZlID8gJ+WPlua2iOWumuS9je+8jOWb
nuWIsOesrOS4gOadoScgOiAn5a6a5L2N5Yiw5LiK5qyh5L2/55So55qE5p2h55uuJyk7CiAgICB9CiAg
ICBmdW5jdGlvbiBzZWxlY3RGaXJzdEl0ZW0oKSB7CiAgICAgICAgbG9jYXRlQWN0aXZlID0gZmFsc2U7
CiAgICAgICAgd2luZG93Ll9fcGVuZGluZ0p1bXBJZCA9IDA7CiAgICAgICAgd2luZG93Ll9fanVtcExv
YWRUcmllcyA9IDA7CiAgICAgICAgc2VsZWN0Rmlyc3RPblNob3cgPSBmYWxzZTsKICAgICAgICBjb25z
dCB2aXMgPSB2aXNpYmxlTGlzdCgpOwogICAgICAgIGlmICghdmlzLmxlbmd0aCkgewogICAgICAgICAg
ICBzZWxlY3RlZElkID0gMDsKICAgICAgICAgICAgc3luY0l0ZW1IaWdobGlnaHQoKTsKICAgICAgICAg
ICAgdXBkYXRlTG9jYXRlQnRuKCk7CiAgICAgICAgICAgIHJldHVybjsKICAgICAgICB9CiAgICAgICAg
c2VsZWN0ZWRJZCA9IHZpc1swXS5pZDsKICAgICAgICByYW5nZUFuY2hvcklkID0gc2VsZWN0ZWRJZDsK
ICAgICAgICByYW5nZUFuY2hvckNsaWNrZWQgPSBmYWxzZTsKICAgICAgICBsaXN0RWwuc2Nyb2xsVG9w
ID0gMDsKICAgICAgICBzeW5jSXRlbUhpZ2hsaWdodCgpOwogICAgICAgIGNvbnN0IGVsID0gbGlzdEVs
LnF1ZXJ5U2VsZWN0b3IoJy5pdG1bZGF0YS1pZD0iJyArIHNlbGVjdGVkSWQgKyAnIl0nKTsKICAgICAg
ICBpZiAoZWwpIGVsLnNjcm9sbEludG9WaWV3KHsgYmxvY2s6ICduZWFyZXN0JyB9KTsKICAgICAgICB1
cGRhdGVMb2NhdGVCdG4oKTsKICAgIH0KICAgIGZ1bmN0aW9uIGp1bXBUb0xhc3RQYXN0ZSgpIHsKICAg
ICAgICBpZiAoIWxhc3RQYXN0ZUlkKSByZXR1cm47CiAgICAgICAgLy8gQWxyZWFkeSBsb2NhdGVkIG9u
IGxhc3QgcGFzdGUg4oaSIGNhbmNlbCBhbmQgc2VsZWN0IGZpcnN0CiAgICAgICAgaWYgKGxvY2F0ZUFj
dGl2ZSAmJiArc2VsZWN0ZWRJZCA9PT0gK2xhc3RQYXN0ZUlkKSB7CiAgICAgICAgICAgIHNlbGVjdEZp
cnN0SXRlbSgpOwogICAgICAgICAgICByZXR1cm47CiAgICAgICAgfQogICAgICAgIGxvY2F0ZUFjdGl2
ZSA9IHRydWU7CiAgICAgICAgc2VsZWN0Rmlyc3RPblNob3cgPSBmYWxzZTsKICAgICAgICAvLyBDbGVh
ciBmaWx0ZXJzIHNvIHRoZSBpdGVtIGlzIGZpbmRhYmxlIG9uIHRoZSB0YWIgd2hlcmUgaXQgd2FzIHVz
ZWQKICAgICAgICBxdWVyeSA9ICcnOwogICAgICAgIHRvZGF5T25seSA9IGZhbHNlOwogICAgICAgIHRy
eSB7CiAgICAgICAgICAgIGNvbnN0IHNyY2ggPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc2VhcmNo
Jyk7CiAgICAgICAgICAgIGNvbnN0IHNjbHIgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc2VhcmNo
LWNscicpOwogICAgICAgICAgICBjb25zdCB3cmFwID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3Nl
YXJjaC13cmFwJyk7CiAgICAgICAgICAgIGNvbnN0IGJ0blRvZGF5ID0gZG9jdW1lbnQuZ2V0RWxlbWVu
dEJ5SWQoJ2J0bi10b2RheScpOwogICAgICAgICAgICBpZiAoc3JjaCkgeyBzcmNoLnZhbHVlID0gJyc7
IHNyY2guY2xhc3NMaXN0LnJlbW92ZSgnaGFzLXZhbCcpOyB9CiAgICAgICAgICAgIGlmIChzY2xyKSBz
Y2xyLnN0eWxlLmRpc3BsYXkgPSAnbm9uZSc7CiAgICAgICAgICAgIGlmICh3cmFwKSB3cmFwLmNsYXNz
TGlzdC5yZW1vdmUoJ29wZW4nKTsKICAgICAgICAgICAgaWYgKGJ0blRvZGF5KSBidG5Ub2RheS5jbGFz
c0xpc3QucmVtb3ZlKCdvbicpOwogICAgICAgIH0gY2F0Y2gge30KICAgICAgICBjb25zdCB0YWIgPSBb
J2FsbCcsJ3RleHQnLCdpbWFnZScsJ2ZpbGUnLCdwaW5uZWQnXS5pbmNsdWRlcyhsYXN0UGFzdGVUYWIp
CiAgICAgICAgICAgID8gbGFzdFBhc3RlVGFiIDogJ2FsbCc7CiAgICAgICAgY29uc3QgcHJldlRhYiA9
IGN1clRhYjsKICAgICAgICBjdXJUYWIgPSB0YWI7CiAgICAgICAgbG9hZGluZ01vcmUgPSBmYWxzZTsK
ICAgICAgICBtYXJrVGFiKHRhYik7CiAgICAgICAgY2xlYXJNdWx0aSgpOwogICAgICAgIHNlbGVjdGVk
SWQgPSBsYXN0UGFzdGVJZDsKICAgICAgICB3aW5kb3cuX19wZW5kaW5nSnVtcElkID0gbGFzdFBhc3Rl
SWQ7CiAgICAgICAgd2luZG93Ll9fanVtcExvYWRUcmllcyA9IDA7CiAgICAgICAgd2luZG93Ll9fanVt
cEZlbGxCYWNrID0gZmFsc2U7CiAgICAgICAgd2luZG93Ll9fanVtcEdyb3VwRW5zdXJlZCA9IDA7CiAg
ICAgICAgdXBkYXRlTG9jYXRlQnRuKCk7CiAgICAgICAgLy8gS2ljayBBSEsgdG8gZXhwYW5kIG1lcmdl
IGdyb3VwIEFTQVAgKGV2ZW4gYmVmb3JlIGZpcnN0IHBhaW50KQogICAgICAgIGlmIChsYXN0UGFzdGVH
cm91cCB8fCBsYXN0UGFzdGVJZCkgewogICAgICAgICAgICB0cnkgeyBhaGsoJ2Vuc3VyZUZhdkdyb3Vw
QXJvdW5kJywgU3RyaW5nKGxhc3RQYXN0ZUlkKSk7IH0gY2F0Y2gge30KICAgICAgICB9CiAgICAgICAg
cmVxdWVzdFZpZXcoKTsKICAgIH0KCiAgICBmdW5jdGlvbiByZXF1ZXN0VmlldygpIHsKICAgICAgICBj
b25zdCB0YWIgPSBjdXJUYWIsIHEgPSBxdWVyeSwgdG9kYXkgPSB0b2RheU9ubHkgPyAnMScgOiAnMCc7
CiAgICAgICAgaWYgKHdpbmRvdy5fX3ZpZXdSYWYpIGNhbmNlbEFuaW1hdGlvbkZyYW1lKHdpbmRvdy5f
X3ZpZXdSYWYpOwogICAgICAgIHdpbmRvdy5fX3ZpZXdSYWYgPSByZXF1ZXN0QW5pbWF0aW9uRnJhbWUo
KCkgPT4gewogICAgICAgICAgICB3aW5kb3cuX192aWV3UmFmID0gMDsKICAgICAgICAgICAgc2V0VGlt
ZW91dCgoKSA9PiBhaGsoJ3NldFZpZXcnLCB0YWIsIHEsIHRvZGF5KSwgMCk7CiAgICAgICAgfSk7CiAg
ICB9CiAgICAvKiogRGVib3VuY2VkIEFISyBzeW5jIGFmdGVyIHZpZXdNZW0gaW5zdGFudCBwYWludCDi
gJRhdm9pZHMgdGFiLXN3aXRjaCBkb3VibGUgUHVzaENsaXBzICovCiAgICBmdW5jdGlvbiBzb2Z0UmVx
dWVzdFZpZXcoKSB7CiAgICAgICAgaWYgKHdpbmRvdy5fX3NvZnRWaWV3VCkgY2xlYXJUaW1lb3V0KHdp
bmRvdy5fX3NvZnRWaWV3VCk7CiAgICAgICAgd2luZG93Ll9fc29mdFZpZXdUID0gc2V0VGltZW91dCgo
KSA9PiB7CiAgICAgICAgICAgIHdpbmRvdy5fX3NvZnRWaWV3VCA9IDA7CiAgICAgICAgICAgIHJlcXVl
c3RWaWV3KCk7CiAgICAgICAgfSwgMzIwKTsKICAgIH0KICAgIGZ1bmN0aW9uIHJlcXVlc3RNb3JlKGZv
cmNlID0gZmFsc2UpIHsKICAgICAgICBpZiAoZGlza1RvdGFsID4gMCAmJiBhbGxDbGlwcy5sZW5ndGgg
Pj0gZGlza1RvdGFsKSByZXR1cm47CiAgICAgICAgLy8gTG9jYXRlIC8ganVtcCBtdXN0IG5vdCB3YWl0
IG9uIHNjcm9sbC1pZGxlIG9yIGEgc3R1Y2sgbG9hZGluZ01vcmUgZmxhZwogICAgICAgIGlmICghZm9y
Y2UpIHsKICAgICAgICAgICAgaWYgKGxvYWRpbmdNb3JlKSByZXR1cm47CiAgICAgICAgICAgIGlmICh3
aW5kb3cuX19zY3JvbGxCdXN5IHx8IF9saXN0UHRyRG93bikgewogICAgICAgICAgICAgICAgd2luZG93
Ll9fd2FudE1vcmUgPSB0cnVlOwogICAgICAgICAgICAgICAgcmV0dXJuOwogICAgICAgICAgICB9CiAg
ICAgICAgfSBlbHNlIHsKICAgICAgICAgICAgbG9hZGluZ01vcmUgPSBmYWxzZTsKICAgICAgICAgICAg
d2luZG93Ll9fc2Nyb2xsQnVzeSA9IGZhbHNlOwogICAgICAgICAgICB3aW5kb3cuX193YW50TW9yZSA9
IGZhbHNlOwogICAgICAgICAgICBfbGlzdFB0ckRvd24gPSBmYWxzZTsKICAgICAgICAgICAgdHJ5IHsg
bGlzdEVsLmNsYXNzTGlzdC5yZW1vdmUoJ2lzLXNjcm9sbGluZycpOyB9IGNhdGNoIHt9CiAgICAgICAg
fQogICAgICAgIGlmIChsb2FkaW5nTW9yZSkgcmV0dXJuOwogICAgICAgIGxvYWRpbmdNb3JlID0gdHJ1
ZTsKICAgICAgICB3aW5kb3cuX193YW50TW9yZSA9IGZhbHNlOwogICAgICAgIGlmICh3aW5kb3cuX19s
b2FkTW9yZVdhdGNoKSBjbGVhclRpbWVvdXQod2luZG93Ll9fbG9hZE1vcmVXYXRjaCk7CiAgICAgICAg
d2luZG93Ll9fbG9hZE1vcmVXYXRjaCA9IHNldFRpbWVvdXQoKCkgPT4gewogICAgICAgICAgICB3aW5k
b3cuX19sb2FkTW9yZVdhdGNoID0gMDsKICAgICAgICAgICAgaWYgKGxvYWRpbmdNb3JlKSB7CiAgICAg
ICAgICAgICAgICBsb2FkaW5nTW9yZSA9IGZhbHNlOwogICAgICAgICAgICAgICAgaWYgKHdpbmRvdy5f
X3BlbmRpbmdKdW1wSWQpIHRyeUNvbnRpbnVlSnVtcCgpOwogICAgICAgICAgICB9CiAgICAgICAgfSwg
MTgwMCk7CiAgICAgICAgYWhrKCdsb2FkTW9yZScpOwogICAgfQoKICAgIGZ1bmN0aW9uIGZsYXNoTG9j
YXRlTm9kZShqaWQpIHsKICAgICAgICBzZWxlY3RlZElkID0gamlkOwogICAgICAgIGxvY2F0ZUFjdGl2
ZSA9IHRydWU7CiAgICAgICAgdXBkYXRlTG9jYXRlQnRuKCk7CiAgICAgICAgcmVxdWVzdEFuaW1hdGlv
bkZyYW1lKCgpID0+IHsKICAgICAgICAgICAgY29uc3Qgcm93ID0gbGlzdEVsLnF1ZXJ5U2VsZWN0b3Io
Jy5tZy1yb3dbZGF0YS1pZD0iJyArIGppZCArICciXScpOwogICAgICAgICAgICBjb25zdCBzaW5nbGUg
PSBsaXN0RWwucXVlcnlTZWxlY3RvcignLml0bVtkYXRhLWlkPSInICsgamlkICsgJyJdJyk7CiAgICAg
ICAgICAgIC8vIFByZWZlciBmbGFzaGluZyB0aGUgd2hvbGUg5ZCI5bm257uEIGNhcmQgd2hlbiBwcmVz
ZW50CiAgICAgICAgICAgIGNvbnN0IG5vZGUgPSAocm93ICYmIHJvdy5jbG9zZXN0KCcuaXRtLml0LWdy
b3VwJykpIHx8IHJvdyB8fCBzaW5nbGU7CiAgICAgICAgICAgIGlmICghbm9kZSkgcmV0dXJuOwogICAg
ICAgICAgICBub2RlLnNjcm9sbEludG9WaWV3KHsgYmxvY2s6ICdjZW50ZXInIH0pOwogICAgICAgICAg
ICBub2RlLmNsYXNzTGlzdC5hZGQoJ2p1bXAtZmxhc2gnKTsKICAgICAgICAgICAgc2V0VGltZW91dCgo
KSA9PiBub2RlLmNsYXNzTGlzdC5yZW1vdmUoJ2p1bXAtZmxhc2gnKSwgOTAwKTsKICAgICAgICAgICAg
c3luY0l0ZW1IaWdobGlnaHQoKTsKICAgICAgICB9KTsKICAgIH0KCiAgICBmdW5jdGlvbiBsb2NhdGVH
cm91cE1lbWJlckNvdW50KGppZCkgewogICAgICAgIGNvbnN0IGhpdCA9IChhbGxDbGlwcyB8fCBbXSku
ZmluZChjID0+ICtjLmlkID09PSAramlkKTsKICAgICAgICBpZiAoIWhpdCkgcmV0dXJuIDA7CiAgICAg
ICAgY29uc3QgZyA9IFN0cmluZyhoaXQuZmF2R3JvdXAgfHwgJycpLnRyaW0oKSB8fCBsYXN0UGFzdGVH
cm91cDsKICAgICAgICBpZiAoIWcpIHJldHVybiAxOwogICAgICAgIHJldHVybiAoYWxsQ2xpcHMgfHwg
W10pLmZpbHRlcihjID0+IFN0cmluZyhjLmZhdkdyb3VwIHx8ICcnKS50cmltKCkgPT09IGcpLmxlbmd0
aDsKICAgIH0KCiAgICBmdW5jdGlvbiB0cnlDb250aW51ZUp1bXAoKSB7CiAgICAgICAgY29uc3Qgamlk
ID0gK3dpbmRvdy5fX3BlbmRpbmdKdW1wSWQ7CiAgICAgICAgaWYgKCFqaWQpIHJldHVybjsKICAgICAg
ICBpZiAoX3BlbmRpbmdBcHBlbmQpIHsKICAgICAgICAgICAgY29uc3QgcGVuZGluZyA9IF9wZW5kaW5n
QXBwZW5kOwogICAgICAgICAgICBfcGVuZGluZ0FwcGVuZCA9IG51bGw7CiAgICAgICAgICAgIGFwcGx5
QXBwZW5kUGF5bG9hZChwZW5kaW5nKTsKICAgICAgICB9CiAgICAgICAgY29uc3QgZWwgPSBsaXN0RWwu
cXVlcnlTZWxlY3RvcignLm1nLXJvd1tkYXRhLWlkPSInICsgamlkICsgJyJdJykgfHwgbGlzdEVsLnF1
ZXJ5U2VsZWN0b3IoJy5pdG1bZGF0YS1pZD0iJyArIGppZCArICciXScpOwogICAgICAgIGlmIChlbCkg
ewogICAgICAgICAgICBjb25zdCBoaXQgPSAoYWxsQ2xpcHMgfHwgW10pLmZpbmQoYyA9PiArYy5pZCA9
PT0gK2ppZCk7CiAgICAgICAgICAgIGNvbnN0IGdpZCA9IChoaXQgJiYgU3RyaW5nKGhpdC5mYXZHcm91
cCB8fCAnJykudHJpbSgpKSB8fCBsYXN0UGFzdGVHcm91cDsKICAgICAgICAgICAgY29uc3QgZ3JvdXBO
ID0gbG9jYXRlR3JvdXBNZW1iZXJDb3VudChqaWQpOwogICAgICAgICAgICAvLyBQYXN0ZWQgZnJvbSBh
IG1lcmdlIGdyb3VwIGJ1dCBzaWJsaW5ncyBub3QgbG9hZGVkIHlldCDihpIgYXNrIEFISyB0byBleHBh
bmQKICAgICAgICAgICAgaWYgKGdpZCAmJiBncm91cE4gPCAyICYmICEod2luZG93Ll9fanVtcEdyb3Vw
RW5zdXJlZCA+IDApKSB7CiAgICAgICAgICAgICAgICB3aW5kb3cuX19qdW1wR3JvdXBFbnN1cmVkID0g
KHdpbmRvdy5fX2p1bXBHcm91cEVuc3VyZWQgfHwgMCkgKyAxOwogICAgICAgICAgICAgICAgdHJ5IHsg
YWhrKCdlbnN1cmVGYXZHcm91cEFyb3VuZCcsIFN0cmluZyhqaWQpKTsgfSBjYXRjaCB7fQogICAgICAg
ICAgICAgICAgLy8gS2VlcCBwZW5kaW5nSnVtcDsgbmV4dCBQdXNoQ2xpcHMvcmVuZGVyIHdpbGwgcmV0
cnkKICAgICAgICAgICAgICAgIHNldFRpbWVvdXQoKCkgPT4geyBpZiAod2luZG93Ll9fcGVuZGluZ0p1
bXBJZCkgdHJ5Q29udGludWVKdW1wKCk7IH0sIDEyMCk7CiAgICAgICAgICAgICAgICByZXR1cm47CiAg
ICAgICAgICAgIH0KICAgICAgICAgICAgd2luZG93Ll9fcGVuZGluZ0p1bXBJZCA9IDA7CiAgICAgICAg
ICAgIHdpbmRvdy5fX2p1bXBMb2FkVHJpZXMgPSAwOwogICAgICAgICAgICB3aW5kb3cuX19qdW1wR3Jv
dXBFbnN1cmVkID0gMDsKICAgICAgICAgICAgZmxhc2hMb2NhdGVOb2RlKGppZCk7CiAgICAgICAgICAg
IHJldHVybjsKICAgICAgICB9CiAgICAgICAgaWYgKGFsbENsaXBzLnNvbWUoYyA9PiArYy5pZCA9PT0g
amlkKSkgewogICAgICAgICAgICByZW5kZXIoKTsKICAgICAgICAgICAgcmVxdWVzdEFuaW1hdGlvbkZy
YW1lKCgpID0+IHRyeUNvbnRpbnVlSnVtcCgpKTsKICAgICAgICAgICAgcmV0dXJuOwogICAgICAgIH0K
ICAgICAgICBpZiAoYWxsQ2xpcHMubGVuZ3RoIDwgZGlza1RvdGFsICYmICh3aW5kb3cuX19qdW1wTG9h
ZFRyaWVzIHx8IDApIDwgODApIHsKICAgICAgICAgICAgd2luZG93Ll9fanVtcExvYWRUcmllcyA9ICh3
aW5kb3cuX19qdW1wTG9hZFRyaWVzIHx8IDApICsgMTsKICAgICAgICAgICAgcmVxdWVzdE1vcmUodHJ1
ZSk7CiAgICAgICAgICAgIHJldHVybjsKICAgICAgICB9CiAgICAgICAgd2luZG93Ll9fcGVuZGluZ0p1
bXBJZCA9IDA7CiAgICAgICAgd2luZG93Ll9fanVtcExvYWRUcmllcyA9IDA7CiAgICAgICAgd2luZG93
Ll9fanVtcEdyb3VwRW5zdXJlZCA9IDA7CiAgICB9CiAgICBjb25zdCBFTVBUWV9NU0cgPSB7CiAgICAg
ICAgYWxsOiAgICAn5pqC5peg6K6w5b2V77yM5aSN5Yi25ZCO6Ieq5Yqo5Ye6546wJywKICAgICAgICB0
ZXh0OiAgICfmmoLml6DmlofmnKwnLAogICAgICAgIGltYWdlOiAgJ+aaguaXoOWbvuWDjycsCiAgICAg
ICAgZmlsZTogICAn5pqC5peg5paH5Lu2JywKICAgICAgICBwaW5uZWQ6ICfmmoLml6DmlLbol48nLAog
ICAgICAgIHJlY2VudDogJ+aaguaXoOacgOi/keaJk+W8gOeahOebruW9lScKICAgIH07CgogICAgZnVu
Y3Rpb24gYWhrSW52b2tlKG1ldGhvZCwgYXJncykgewogICAgICAgIHRyeSB7CiAgICAgICAgICAgIGNv
bnN0IGhvc3QgPSBjaHJvbWUud2Vidmlldy5ob3N0T2JqZWN0cy5zeW5jLmFoazsKICAgICAgICAgICAg
aWYgKCFob3N0KSByZXR1cm47CiAgICAgICAgICAgIGxldCBjYWxsZWQgPSBmYWxzZTsKICAgICAgICAg
ICAgLy8gV2ViVmlldzI6IGhvc3QuY2FsbChuYW1lLCDigKYpIGlzIHRoZSByZWxpYWJsZSBwYXRoLiBE
aXJlY3QgaG9zdFttZXRob2RdKOKApikKICAgICAgICAgICAgLy8gY2FuIG1pcy1iaW5kIGFyZ3MgKHNh
dyBzZXRWaWV3IHRhYiBiZWNvbWUgMCDihpIgZm9yZXZlciBza2VsZXRvbiAvIHdyb25nIHRhYikuCiAg
ICAgICAgICAgIGlmICh0eXBlb2YgaG9zdC5jYWxsID09PSAnZnVuY3Rpb24nKSB7CiAgICAgICAgICAg
ICAgICB0cnkgeyBob3N0LmNhbGwobWV0aG9kLCAuLi5hcmdzKTsgY2FsbGVkID0gdHJ1ZTsgfSBjYXRj
aCB7fQogICAgICAgICAgICB9CiAgICAgICAgICAgIGlmICghY2FsbGVkICYmIHR5cGVvZiBob3N0W21l
dGhvZF0gPT09ICdmdW5jdGlvbicpIHsKICAgICAgICAgICAgICAgIHRyeSB7IGhvc3RbbWV0aG9kXSgu
Li5hcmdzKTsgY2FsbGVkID0gdHJ1ZTsgfSBjYXRjaCAoZSkgeyBjb25zb2xlLndhcm4oJ2Foay4nICsg
bWV0aG9kLCBlKTsgfQogICAgICAgICAgICB9CiAgICAgICAgICAgIGlmICghY2FsbGVkICYmIGhvc3Rb
bWV0aG9kXSAhPSBudWxsICYmIHR5cGVvZiBob3N0W21ldGhvZF0gIT09ICdmdW5jdGlvbicpIHsKICAg
ICAgICAgICAgICAgIHRyeSB7IHZvaWQgaG9zdFttZXRob2RdOyB9IGNhdGNoIHt9CiAgICAgICAgICAg
IH0KICAgICAgICB9IGNhdGNoIChlKSB7IGNvbnNvbGUud2FybignYWhrLicgKyBtZXRob2QsIGUpOyB9
CiAgICB9CiAgICBmdW5jdGlvbiBhaGsobWV0aG9kLCAuLi5hcmdzKSB7CiAgICAgICAgYWhrSW52b2tl
KG1ldGhvZCwgYXJncyk7CiAgICB9CiAgICBmdW5jdGlvbiBhaGtSZXQobWV0aG9kLCAuLi5hcmdzKSB7
CiAgICAgICAgdHJ5IHsKICAgICAgICAgICAgY29uc3QgaG9zdCA9IGNocm9tZS53ZWJ2aWV3Lmhvc3RP
YmplY3RzLnN5bmMuYWhrOwogICAgICAgICAgICBpZiAoIWhvc3QpIHJldHVybiBudWxsOwogICAgICAg
ICAgICBsZXQgcmV0ID0gbnVsbDsKICAgICAgICAgICAgaWYgKHR5cGVvZiBob3N0LmNhbGwgPT09ICdm
dW5jdGlvbicpIHsKICAgICAgICAgICAgICAgIHRyeSB7IHJldCA9IGhvc3QuY2FsbChtZXRob2QsIC4u
LmFyZ3MpOyB9IGNhdGNoIHt9CiAgICAgICAgICAgIH0KICAgICAgICAgICAgaWYgKHJldCA9PSBudWxs
ICYmIHR5cGVvZiBob3N0W21ldGhvZF0gPT09ICdmdW5jdGlvbicpIHsKICAgICAgICAgICAgICAgIHRy
eSB7IHJldCA9IGhvc3RbbWV0aG9kXSguLi5hcmdzKTsgfSBjYXRjaCB7fQogICAgICAgICAgICAgICAg
aWYgKHJldCA9PSBudWxsKSB7CiAgICAgICAgICAgICAgICAgICAgdHJ5IHsgcmV0ID0gaG9zdFttZXRo
b2RdKC4uLmFyZ3MpOyB9IGNhdGNoIHt9CiAgICAgICAgICAgICAgICB9CiAgICAgICAgICAgIH0KICAg
ICAgICAgICAgaWYgKHJldCA9PSBudWxsICYmIGhvc3RbbWV0aG9kXSAhPSBudWxsICYmIHR5cGVvZiBo
b3N0W21ldGhvZF0gIT09ICdmdW5jdGlvbicpCiAgICAgICAgICAgICAgICByZXQgPSBob3N0W21ldGhv
ZF07CiAgICAgICAgICAgIGlmIChyZXQgPT0gbnVsbCkgcmV0dXJuIG51bGw7CiAgICAgICAgICAgIGlm
ICh0eXBlb2YgcmV0ID09PSAnc3RyaW5nJyB8fCB0eXBlb2YgcmV0ID09PSAnbnVtYmVyJyB8fCB0eXBl
b2YgcmV0ID09PSAnYm9vbGVhbicpCiAgICAgICAgICAgICAgICByZXR1cm4gcmV0OwogICAgICAgICAg
ICB0cnkgeyByZXR1cm4gU3RyaW5nKHJldCk7IH0gY2F0Y2ggeyByZXR1cm4gcmV0OyB9CiAgICAgICAg
fSBjYXRjaCAoZSkgeyBjb25zb2xlLndhcm4oJ2Foa1JldC4nICsgbWV0aG9kLCBlKTsgfQogICAgICAg
IHJldHVybiBudWxsOwogICAgfQoKICAgIC8vIEVhcmx5IEFISyBfX3NldFRodW1iIGNhbiBhcnJpdmUg
YmVmb3JlIERPTSBub2RlcyBleGlzdCDigJQga2VlcCB1bnRpbCBiaW5kCiAgICBjb25zdCB0aHVtYkNh
Y2hlID0gbmV3IE1hcCgpOwoKICAgIC8qKiBQcmVmZXIgY2FjaGUgLyBkYXRhLVVSTCwgdGhlbiB0aF8q
LmpwZyB2aWEgdmlydHVhbCBob3N0LCB0aGVuIG9yaWdpbmFsICovCiAgICBmdW5jdGlvbiBiaW5kU3Rv
cmVUaHVtYihpbWcsIGZpbGUsIGlkLCBmYWxsYmFjaykgewogICAgICAgIGltZy5kYXRhc2V0LnRodW1i
SWQgPSBTdHJpbmcoaWQpOwogICAgICAgIGltZy5hbHQgPSAnJzsKICAgICAgICBpbWcuY2xhc3NMaXN0
LmFkZCgndGh1bWItbG9hZGluZycpOwogICAgICAgIGNvbnN0IHdyYXAgPSBpbWcucGFyZW50RWxlbWVu
dDsKICAgICAgICBpZiAod3JhcCAmJiB3cmFwLmNsYXNzTGlzdC5jb250YWlucygnaS10aHVtYi13cmFw
JykpCiAgICAgICAgICAgIHdyYXAuY2xhc3NMaXN0LmFkZCgnd2FpdGluZycpOwogICAgICAgIGNvbnN0
IGNsZWFyV2FpdCA9ICgpID0+IHsKICAgICAgICAgICAgaW1nLmNsYXNzTGlzdC5yZW1vdmUoJ3RodW1i
LWxvYWRpbmcnKTsKICAgICAgICAgICAgaWYgKHdyYXApIHdyYXAuY2xhc3NMaXN0LnJlbW92ZSgnd2Fp
dGluZycpOwogICAgICAgICAgICBpZiAoaW1nLl9mYWlsVGltZXIpIHRyeSB7IGNsZWFyVGltZW91dChp
bWcuX2ZhaWxUaW1lcik7IH0gY2F0Y2gge30KICAgICAgICB9OwogICAgICAgIGNvbnN0IGZhaWxUaW1l
ciA9IHNldFRpbWVvdXQoKCkgPT4gewogICAgICAgICAgICBpZiAoIWltZy5zcmMgfHwgaW1nLm5hdHVy
YWxXaWR0aCA8IDEpCiAgICAgICAgICAgICAgICBpbWcuYWx0ID0gJ+aXoOazleWKoOi9vSc7CiAgICAg
ICAgICAgIGNsZWFyV2FpdCgpOwogICAgICAgIH0sIDEyMDAwKTsKICAgICAgICBpbWcuX2ZhaWxUaW1l
ciA9IGZhaWxUaW1lcjsKICAgICAgICBjb25zdCBwcmV2TG9hZCA9IGltZy5vbmxvYWQ7CiAgICAgICAg
aW1nLm9ubG9hZCA9IGUgPT4gewogICAgICAgICAgICBjbGVhcldhaXQoKTsKICAgICAgICAgICAgaW1n
LmFsdCA9ICcnOwogICAgICAgICAgICBpZiAodHlwZW9mIHByZXZMb2FkID09PSAnZnVuY3Rpb24nKSBw
cmV2TG9hZC5jYWxsKGltZywgZSk7CiAgICAgICAgfTsKICAgICAgICBjb25zdCBiYXJlID0gZmlsZSA/
IFN0cmluZyhmaWxlKS5zcGxpdCgvW1xcL10vKS5wb3AoKSA6ICcnOwogICAgICAgIGNvbnN0IHRoTmFt
ZSA9IGJhcmUgPyAoJ3RoXycgKyBiYXJlLnJlcGxhY2UoL1wuW14uXSskLywgJycpICsgJy5qcGcnKSA6
ICcnOwogICAgICAgIGlmIChiYXJlKSBpbWcuZGF0YXNldC5iYXJlID0gYmFyZTsKICAgICAgICBpbWcu
b25lcnJvciA9ICgpID0+IHsKICAgICAgICAgICAgY29uc3Qgc3RlcCA9IE51bWJlcihpbWcuZGF0YXNl
dC5zdGVwIHx8IDApOwogICAgICAgICAgICBpZiAoc3RlcCA8IDIgJiYgYmFyZSkgewogICAgICAgICAg
ICAgICAgaW1nLmRhdGFzZXQuc3RlcCA9ICcyJzsKICAgICAgICAgICAgICAgIGltZy5zcmMgPSBTVE9S
RV9CQVNFICsgZW5jb2RlVVJJQ29tcG9uZW50KGJhcmUpOwogICAgICAgICAgICAgICAgcmV0dXJuOwog
ICAgICAgICAgICB9CiAgICAgICAgICAgIGlmIChzdGVwIDwgMyAmJiAodGhOYW1lIHx8IGJhcmUpKSB7
CiAgICAgICAgICAgICAgICBpbWcuZGF0YXNldC5zdGVwID0gJzMnOwogICAgICAgICAgICAgICAgaW1n
LnNyYyA9IFNUT1JFX0JBU0VfRkFMTEJBQ0sgKyBlbmNvZGVVUklDb21wb25lbnQodGhOYW1lIHx8IGJh
cmUpOwogICAgICAgICAgICAgICAgcmV0dXJuOwogICAgICAgICAgICB9CiAgICAgICAgICAgIGlmIChz
dGVwIDwgNCAmJiBiYXJlICYmIHRoTmFtZSkgewogICAgICAgICAgICAgICAgaW1nLmRhdGFzZXQuc3Rl
cCA9ICc0JzsKICAgICAgICAgICAgICAgIGltZy5zcmMgPSBTVE9SRV9CQVNFX0ZBTExCQUNLICsgZW5j
b2RlVVJJQ29tcG9uZW50KGJhcmUpOwogICAgICAgICAgICAgICAgcmV0dXJuOwogICAgICAgICAgICB9
CiAgICAgICAgICAgIC8vIEtlZXAgc2hpbW1lcjsgQUhLIF9fc2V0VGh1bWIgd2lsbCBmaWxsIGluCiAg
ICAgICAgICAgIGltZy5yZW1vdmVBdHRyaWJ1dGUoJ3NyYycpOwogICAgICAgICAgICBpbWcuY2xhc3NM
aXN0LmFkZCgndGh1bWItbG9hZGluZycpOwogICAgICAgICAgICBpZiAod3JhcCkgd3JhcC5jbGFzc0xp
c3QuYWRkKCd3YWl0aW5nJyk7CiAgICAgICAgfTsKICAgICAgICBjb25zdCBjYWNoZWQgPSB0aHVtYkNh
Y2hlLmdldChTdHJpbmcoaWQpKTsKICAgICAgICAvLyBBY2NlcHQgZGF0YS1VUkwgb3IgaG9zdCBVUkwg
ZnJvbSBwcmlvciBfX3NldFRodW1iIChyZS1yZW5kZXIgbXVzdCBub3QgZHJvcCBpdCkKICAgICAgICBp
ZiAoY2FjaGVkICYmIFN0cmluZyhjYWNoZWQpLmxlbmd0aCkgewogICAgICAgICAgICBpbWcuZGF0YXNl
dC5zdGVwID0gJzknOwogICAgICAgICAgICBpbWcuc3JjID0gU3RyaW5nKGNhY2hlZCk7CiAgICAgICAg
ICAgIHJldHVybjsKICAgICAgICB9CiAgICAgICAgY29uc3QgZGF0YVVybCA9IChmYWxsYmFjayAmJiBT
dHJpbmcoZmFsbGJhY2spLnN0YXJ0c1dpdGgoJ2RhdGE6JykpCiAgICAgICAgICAgID8gU3RyaW5nKGZh
bGxiYWNrKSA6ICcnOwogICAgICAgIGlmIChkYXRhVXJsKSB7CiAgICAgICAgICAgIGltZy5kYXRhc2V0
LnN0ZXAgPSAnOSc7CiAgICAgICAgICAgIGltZy5zcmMgPSBkYXRhVXJsOwogICAgICAgICAgICByZXR1
cm47CiAgICAgICAgfQogICAgICAgIGlmIChiYXJlKSB7CiAgICAgICAgICAgIC8vIFByZWZlciBsaXN0
IHRodW1iIEpQRUcgKHNtYWxsKSBvbiBkZWRpY2F0ZWQgc3RvcmUgaG9zdAogICAgICAgICAgICBpbWcu
ZGF0YXNldC5zdGVwID0gJzEnOwogICAgICAgICAgICBpbWcuc3JjID0gU1RPUkVfQkFTRSArIGVuY29k
ZVVSSUNvbXBvbmVudCh0aE5hbWUgfHwgYmFyZSk7CiAgICAgICAgfSBlbHNlIHsKICAgICAgICAgICAg
Ly8gTm8gZmlsZSB5ZXQgKGp1c3QgY29waWVkKSDigJRrZWVwIHNoaW1tZXI7IEluamVjdExpdmVJbWFn
ZVRodW1iIC8gX19zZXRUaHVtYiBmaWxscyBpbgogICAgICAgICAgICBpbWcuY2xhc3NMaXN0LmFkZCgn
dGh1bWItbG9hZGluZycpOwogICAgICAgICAgICBpZiAod3JhcCkgd3JhcC5jbGFzc0xpc3QuYWRkKCd3
YWl0aW5nJyk7CiAgICAgICAgfQogICAgfQoKICAgIHdpbmRvdy5fX3NldFRodW1iID0gKGlkLCB1cmwp
ID0+IHsKICAgICAgICBpZiAoIXVybCkgcmV0dXJuOwogICAgICAgIGNvbnN0IGtleSA9IFN0cmluZyhp
ZCk7CiAgICAgICAgY29uc3QgaXNEYXRhID0gU3RyaW5nKHVybCkuc3RhcnRzV2l0aCgnZGF0YTonKTsK
ICAgICAgICAvLyBQcmVmZXIga2VlcGluZyBhIHdvcmtpbmcgZGF0YS1VUkw7IGRvbid0IGxldCBhIGZs
YWt5IGhvc3QgVVJMIG92ZXJ3cml0ZSBpdAogICAgICAgIGNvbnN0IHByZXYgPSB0aHVtYkNhY2hlLmdl
dChrZXkpOwogICAgICAgIGlmICghaXNEYXRhICYmIHByZXYgJiYgU3RyaW5nKHByZXYpLnN0YXJ0c1dp
dGgoJ2RhdGE6JykpCiAgICAgICAgICAgIHJldHVybjsKICAgICAgICB0aHVtYkNhY2hlLnNldChrZXks
IHVybCk7CiAgICAgICAgY29uc3QgYXBwbHkgPSBpbWcgPT4gewogICAgICAgICAgICBpZiAoaW1nLl9m
YWlsVGltZXIpIHRyeSB7IGNsZWFyVGltZW91dChpbWcuX2ZhaWxUaW1lcik7IH0gY2F0Y2gge30KICAg
ICAgICAgICAgaW1nLmFsdCA9ICcnOwogICAgICAgICAgICBpbWcuY2xhc3NMaXN0LnJlbW92ZSgndGh1
bWItbG9hZGluZycpOwogICAgICAgICAgICBjb25zdCB3cmFwID0gaW1nLnBhcmVudEVsZW1lbnQ7CiAg
ICAgICAgICAgIGlmICh3cmFwKSB3cmFwLmNsYXNzTGlzdC5yZW1vdmUoJ3dhaXRpbmcnKTsKICAgICAg
ICAgICAgaW1nLm9uZXJyb3IgPSAoKSA9PiB7CiAgICAgICAgICAgICAgICBpbWcub25lcnJvciA9IG51
bGw7CiAgICAgICAgICAgICAgICAvLyBIb3N0L3ZpcnR1YWwtaG9zdCBmYWlsZWQg4oCUIGRyb3AgcG9p
c29uIHNvIGJpbmQgY2FuIHJldHJ5IGZpbGUgcGF0aHMKICAgICAgICAgICAgICAgIGlmICh0aHVtYkNh
Y2hlLmdldChrZXkpID09PSB1cmwpCiAgICAgICAgICAgICAgICAgICAgdGh1bWJDYWNoZS5kZWxldGUo
a2V5KTsKICAgICAgICAgICAgICAgIGltZy5jbGFzc0xpc3QuYWRkKCd0aHVtYi1sb2FkaW5nJyk7CiAg
ICAgICAgICAgICAgICBpZiAod3JhcCkgd3JhcC5jbGFzc0xpc3QuYWRkKCd3YWl0aW5nJyk7CiAgICAg
ICAgICAgICAgICBjb25zdCBiYXJlID0gaW1nLmRhdGFzZXQuYmFyZSB8fCAnJzsKICAgICAgICAgICAg
ICAgIGNvbnN0IHRoTmFtZSA9IGJhcmUgPyAoJ3RoXycgKyBiYXJlLnJlcGxhY2UoL1wuW14uXSskLywg
JycpICsgJy5qcGcnKSA6ICcnOwogICAgICAgICAgICAgICAgaWYgKGJhcmUpIHsKICAgICAgICAgICAg
ICAgICAgICBpbWcuZGF0YXNldC5zdGVwID0gJzEnOwogICAgICAgICAgICAgICAgICAgIGltZy5zcmMg
PSBTVE9SRV9CQVNFICsgZW5jb2RlVVJJQ29tcG9uZW50KHRoTmFtZSB8fCBiYXJlKTsKICAgICAgICAg
ICAgICAgIH0KICAgICAgICAgICAgfTsKICAgICAgICAgICAgaW1nLnNyYyA9IHVybDsKICAgICAgICB9
OwogICAgICAgIGxldCBoaXQgPSAwOwogICAgICAgIGRvY3VtZW50LnF1ZXJ5U2VsZWN0b3JBbGwoJy5p
dG1bZGF0YS1pZD0iJyArIGtleSArICciXSBpbWcuaS10aHVtYicpLmZvckVhY2goaW1nID0+IHsKICAg
ICAgICAgICAgYXBwbHkoaW1nKTsgaGl0Kys7CiAgICAgICAgfSk7CiAgICAgICAgaWYgKCFoaXQpIHsK
ICAgICAgICAgICAgZG9jdW1lbnQucXVlcnlTZWxlY3RvckFsbCgnaW1nLmktdGh1bWJbZGF0YS10aHVt
Yi1pZD0iJyArIGtleSArICciXScpLmZvckVhY2goYXBwbHkpOwogICAgICAgIH0KICAgIH07CgogICAg
ZnVuY3Rpb24gaXNEcmFnRXhjbHVkZSh0KSB7CiAgICAgICAgcmV0dXJuICEhdC5jbG9zZXN0KCcjc2Vh
cmNoLXdyYXAsICNidG4tc2VhcmNoLCAjYnRuLWxvY2F0ZSwgI2J0bi10b2RheSwgI2J0bi1waW4sICNi
dG4tY2xyLCAjbXVsdGktYmFyLCAjbXVsdGktc2VsLCAjbXVsdGktY250LCAjcGFzdGUtc2VwLXdyYXAs
IC50YWIsIC5pdG0sICN0YWItYWN0aW9ucywgI2N0eCwgI2Nsci1kbGcsICNwYXRoLXRpcCwgYnV0dG9u
LCBpbnB1dCwgYScpOwogICAgfQogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2FwcCcpLmFkZEV2
ZW50TGlzdGVuZXIoJ21vdXNlZG93bicsIGUgPT4gewogICAgICAgIGlmIChlLmJ1dHRvbiAhPT0gMCkg
cmV0dXJuOwogICAgICAgIGlmIChpc0RyYWdFeGNsdWRlKGUudGFyZ2V0KSkgcmV0dXJuOwogICAgICAg
IGUucHJldmVudERlZmF1bHQoKTsKICAgICAgICBhaGsoJ3N0YXJ0RHJhZycpOwogICAgfSwgdHJ1ZSk7
CgogICAgY29uc3QgaXNVcmwgID0gcyA9PiAvXmh0dHBzPzpcL1wvL2kudGVzdCgocyB8fCAnJykudHJp
bSgpKTsKCiAgICBmdW5jdGlvbiBhZ28oZGF0ZVN0cikgewogICAgICAgIHRyeSB7CiAgICAgICAgICAg
IGNvbnN0IGQgPSBuZXcgRGF0ZShTdHJpbmcoZGF0ZVN0cikucmVwbGFjZSgnICcsICdUJykpOwogICAg
ICAgICAgICBjb25zdCBzID0gKERhdGUubm93KCkgLSBkKSAvIDEwMDAgfCAwOwogICAgICAgICAgICBp
ZiAocyA8IDYwKSByZXR1cm4gJ+WImuWImic7CiAgICAgICAgICAgIGlmIChzIDwgMzYwMCkgcmV0dXJu
IChzIC8gNjAgfCAwKSArICcg5YiG6ZKf5YmNJzsKICAgICAgICAgICAgaWYgKHMgPCA4NjQwMCkgcmV0
dXJuIChzIC8gMzYwMCB8IDApICsgJyDlsI/ml7bliY0nOwogICAgICAgICAgICByZXR1cm4gKHMgLyA4
NjQwMCB8IDApICsgJyDlpKnliY0nOwogICAgICAgIH0gY2F0Y2ggeyByZXR1cm4gZGF0ZVN0cjsgfQog
ICAgfQoKICAgIGZ1bmN0aW9uIG5vcm1UeXBlKHQpIHsKICAgICAgICB0ID0gU3RyaW5nKHQgfHwgJycp
LnRvTG93ZXJDYXNlKCk7CiAgICAgICAgaWYgKHQgPT09ICdpbWFnZScgfHwgdCA9PT0gJ2ltZycgfHwg
dCA9PT0gJ2JpdG1hcCcpIHJldHVybiAnaW1hZ2UnOwogICAgICAgIGlmICh0ID09PSAnZmlsZScgIHx8
IHQgPT09ICdmaWxlcycpIHJldHVybiAnZmlsZSc7CiAgICAgICAgaWYgKHQgPT09ICdyZWNlbnQnIHx8
IHQgPT09ICdmb2xkZXInIHx8IHQgPT09ICdkaXInKSByZXR1cm4gJ3JlY2VudCc7CiAgICAgICAgaWYg
KHQgPT09ICdsaW5rJyB8fCB0ID09PSAndXJsJykgcmV0dXJuICdsaW5rJzsKICAgICAgICByZXR1cm4g
J3RleHQnOwogICAgfQogICAgZnVuY3Rpb24gaXNQaW5uZWQoYykgewogICAgICAgIHJldHVybiBjLnBp
bm5lZCA9PT0gdHJ1ZSB8fCBjLnBpbm5lZCA9PT0gMSB8fCBjLnBpbm5lZCA9PT0gJ3RydWUnIHx8IGMu
cGlubmVkID09PSAnMSc7CiAgICB9CiAgICAvKiog5ZCM5q2l5omA5pyJIHRhYiDnvJPlrZjph4znmoTm
lLbol4/moIforrDvvIzpgb/lhY3mlLbol4/pobXlj5bmtojlkI7lhbblroPliJfooajku43mmL7npLrj
gIzlj5bmtojmlLbol4/jgI0gKi8KICAgIGZ1bmN0aW9uIHBhdGNoUGlubmVkSW5DYWNoZXMoaWQsIHBp
bm5lZCkgewogICAgICAgIGlkID0gK2lkOwogICAgICAgIGlmICghaWQpIHJldHVybjsKICAgICAgICBj
b25zdCBhcHBseSA9IChjKSA9PiB7CiAgICAgICAgICAgIGlmICghYyB8fCArYy5pZCAhPT0gaWQpIHJl
dHVybjsKICAgICAgICAgICAgYy5waW5uZWQgPSAhIXBpbm5lZDsKICAgICAgICAgICAgaWYgKCFwaW5u
ZWQpIGMucGluVGltZSA9ICcnOwogICAgICAgIH07CiAgICAgICAgZm9yIChjb25zdCB4IG9mIGFsbENs
aXBzKSBhcHBseSh4KTsKICAgICAgICB0cnkgewogICAgICAgICAgICBmb3IgKGNvbnN0IFtrZXksIGhp
dF0gb2Ygdmlld01lbS5lbnRyaWVzKCkpIHsKICAgICAgICAgICAgICAgIGlmICghaGl0IHx8ICFBcnJh
eS5pc0FycmF5KGhpdC5pdGVtcykpIGNvbnRpbnVlOwogICAgICAgICAgICAgICAgZm9yIChjb25zdCB4
IG9mIGhpdC5pdGVtcykgYXBwbHkoeCk7CiAgICAgICAgICAgICAgICAvLyDmlLbol48gdGFiIOe8k+Wt
mO+8muWPlua2iOWQjuebtOaOpeenu+WHugogICAgICAgICAgICAgICAgaWYgKCFwaW5uZWQgJiYgU3Ry
aW5nKGtleSkuc3RhcnRzV2l0aCgncGlubmVkXHQnKSkgewogICAgICAgICAgICAgICAgICAgIGNvbnN0
IGJlZm9yZSA9IGhpdC5pdGVtcy5sZW5ndGg7CiAgICAgICAgICAgICAgICAgICAgaGl0Lml0ZW1zID0g
aGl0Lml0ZW1zLmZpbHRlcih4ID0+ICt4LmlkICE9PSBpZCk7CiAgICAgICAgICAgICAgICAgICAgaWYg
KGhpdC5pdGVtcy5sZW5ndGggIT09IGJlZm9yZSkKICAgICAgICAgICAgICAgICAgICAgICAgaGl0LnRv
dGFsID0gTWF0aC5tYXgoMCwgKE51bWJlcihoaXQudG90YWwpIHx8IGJlZm9yZSkgLSAoYmVmb3JlIC0g
aGl0Lml0ZW1zLmxlbmd0aCkpOwogICAgICAgICAgICAgICAgICAgIHZpZXdNZW0uc2V0KGtleSwgaGl0
KTsKICAgICAgICAgICAgICAgIH0KICAgICAgICAgICAgfQogICAgICAgIH0gY2F0Y2gge30KICAgIH0K
ICAgIGZ1bmN0aW9uIGlzUGFzdGVkKGMpIHsKICAgICAgICByZXR1cm4gYy5wYXN0ZWQgPT09IHRydWUg
fHwgYy5wYXN0ZWQgPT09IDEgfHwgYy5wYXN0ZWQgPT09ICd0cnVlJyB8fCBjLnBhc3RlZCA9PT0gJzEn
OwogICAgfQoKICAgIGZ1bmN0aW9uIGlzTWFya2Rvd24odGV4dCkgewogICAgICAgIGlmICghdGV4dCB8
fCB0ZXh0Lmxlbmd0aCA8IDQpIHJldHVybiBmYWxzZTsKICAgICAgICByZXR1cm4gLyg/Ol58XG4pI3sx
LDZ9IHxeWy0qK10gfFwqXCpbXipcbl0rXCpcKnxfX1teX1xuXStfX3woPzpefFxuKT4gfGBgYHxgW15g
XG5dK2B8XFtbXlxdXStcXVwoW14pXStcKXxcfC4rXHwuK1x8L20udGVzdCh0ZXh0KTsKICAgIH0KICAg
IGZ1bmN0aW9uIGNsaXBVc2VzTUljb24oYykgewogICAgICAgIGlmICghYykgcmV0dXJuIGZhbHNlOwog
ICAgICAgIGlmIChjLmlzTWQgPT09IHRydWUgfHwgYy5pc01kID09PSAxIHx8IGMuaXNNZCA9PT0gJ3Ry
dWUnIHx8IGMuaXNNZCA9PT0gJzEnKSByZXR1cm4gdHJ1ZTsKICAgICAgICBpZiAoYy5pc1JpY2ggPT09
IHRydWUgfHwgYy5pc1JpY2ggPT09IDEgfHwgYy5pc1JpY2ggPT09ICd0cnVlJyB8fCBjLmlzUmljaCA9
PT0gJzEnKSByZXR1cm4gdHJ1ZTsKICAgICAgICBjb25zdCB0ID0gU3RyaW5nKGMudHlwZSB8fCAnJyku
dG9Mb3dlckNhc2UoKTsKICAgICAgICBpZiAodCAmJiB0ICE9PSAndGV4dCcgJiYgdCAhPT0gJ2xpbmsn
KSByZXR1cm4gZmFsc2U7CiAgICAgICAgcmV0dXJuIGlzTWFya2Rvd24oYy5kYXRhIHx8IGMucHJldmll
dyB8fCAnJyk7CiAgICB9CiAgICBmdW5jdGlvbiBlc2NBdHRyKHMpIHsKICAgICAgICByZXR1cm4gU3Ry
aW5nKHMgfHwgJycpCiAgICAgICAgICAgIC5yZXBsYWNlKC8mL2csICcmYW1wOycpCiAgICAgICAgICAg
IC5yZXBsYWNlKC8iL2csICcmcXVvdDsnKQogICAgICAgICAgICAucmVwbGFjZSgvPC9nLCAnJmx0Oycp
CiAgICAgICAgICAgIC5yZXBsYWNlKC8+L2csICcmZ3Q7Jyk7CiAgICB9CgogICAgZnVuY3Rpb24gdG9k
YXlQcmVmaXgoKSB7CiAgICAgICAgY29uc3QgZCA9IG5ldyBEYXRlKCk7CiAgICAgICAgY29uc3QgcCA9
IG4gPT4gU3RyaW5nKG4pLnBhZFN0YXJ0KDIsICcwJyk7CiAgICAgICAgcmV0dXJuIGQuZ2V0RnVsbFll
YXIoKSArICctJyArIHAoZC5nZXRNb250aCgpICsgMSkgKyAnLScgKyBwKGQuZ2V0RGF0ZSgpKTsKICAg
IH0KICAgIGZ1bmN0aW9uIGlzVG9kYXlDbGlwKGMpIHsKICAgICAgICByZXR1cm4gU3RyaW5nKGMudGlt
ZSB8fCAnJykuc3RhcnRzV2l0aCh0b2RheVByZWZpeCgpKTsKICAgIH0KCiAgICBmdW5jdGlvbiBjbGlw
SGF5KGMpIHsKICAgICAgICBjb25zdCBmYXYgPSBTdHJpbmcoYy5mYXZUaXRsZSB8fCAnJyk7CiAgICAg
ICAgY29uc3QgZmF2Q29tcGFjdCA9IGZhdi5yZXBsYWNlKC9ccysvZywgJycpOwogICAgICAgIHJldHVy
biBTdHJpbmcoYy5wcmV2aWV3IHx8ICcnKSArICcgJyArIFN0cmluZyhjLmRhdGEgfHwgJycpICsgJyAn
CiAgICAgICAgICAgICsgU3RyaW5nKGMubGlua1RpdGxlIHx8ICcnKSArICcgJyArIGZhdgogICAgICAg
ICAgICArIChmYXZDb21wYWN0ICYmIGZhdkNvbXBhY3QgIT09IGZhdiA/ICgnICcgKyBmYXZDb21wYWN0
KSA6ICcnKTsKICAgIH0KICAgIC8qKiBNYXRjaCBBSEsgSXRlbU1hdGNoZXNWaWV3IGxpc3Qgc2VhcmNo
IOKAlCBwcmV2aWV3ICgrIHNob3J0IGJvZHkgZmFsbGJhY2spLCBub3QgZnVsbCBkYXRhICovCiAgICBm
dW5jdGlvbiBmYXZUaXRsZUhheShmYXYpIHsKICAgICAgICBmYXYgPSBTdHJpbmcoZmF2IHx8ICcnKTsK
ICAgICAgICBjb25zdCBjb21wYWN0ID0gZmF2LnJlcGxhY2UoL1xzKy9nLCAnJyk7CiAgICAgICAgaWYg
KGNvbXBhY3QgJiYgY29tcGFjdCAhPT0gZmF2KQogICAgICAgICAgICByZXR1cm4gZmF2ICsgJyAnICsg
Y29tcGFjdDsKICAgICAgICByZXR1cm4gZmF2OwogICAgfQogICAgZnVuY3Rpb24gY2xpcFNlYXJjaEhh
eShjKSB7CiAgICAgICAgY29uc3QgdHlwZSA9IFN0cmluZyhjLnR5cGUgfHwgJycpLnRvTG93ZXJDYXNl
KCk7CiAgICAgICAgY29uc3QgZmF2ID0gZmF2VGl0bGVIYXkoYy5mYXZUaXRsZSk7CiAgICAgICAgaWYg
KHR5cGUgPT09ICdpbWFnZScpCiAgICAgICAgICAgIHJldHVybiBmYXY7CiAgICAgICAgaWYgKHR5cGUg
PT09ICdmaWxlJykgewogICAgICAgICAgICByZXR1cm4gU3RyaW5nKGMucHJldmlldyB8fCAnJykgKyAn
ICcgKyBTdHJpbmcoYy5kYXRhIHx8ICcnKSArICcgJyArIGZhdjsKICAgICAgICB9CiAgICAgICAgbGV0
IHByZXYgPSBTdHJpbmcoYy5wcmV2aWV3IHx8ICcnKTsKICAgICAgICBpZiAoIXByZXYgJiYgYy5kYXRh
KQogICAgICAgICAgICBwcmV2ID0gU3RyaW5nKGMuZGF0YSkuc2xpY2UoMCwgNTAwKTsKICAgICAgICBy
ZXR1cm4gcHJldiArICcgJyArIFN0cmluZyhjLmxpbmtUaXRsZSB8fCAnJykgKyAnICcgKyBmYXY7CiAg
ICB9CiAgICBmdW5jdGlvbiBjbGlwTWF0Y2hlc1NlYXJjaChjLCB0ZXJtTCkgewogICAgICAgIGNvbnN0
IHR5cGUgPSBTdHJpbmcoYy50eXBlIHx8ICcnKS50b0xvd2VyQ2FzZSgpOwogICAgICAgIGNvbnN0IGhh
eSA9ICh0eXBlID09PSAnaW1hZ2UnID8gZmF2VGl0bGVIYXkoYy5mYXZUaXRsZSkgOiBjbGlwU2VhcmNo
SGF5KGMpKS50b0xvd2VyQ2FzZSgpOwogICAgICAgIHJldHVybiB0ZXJtTC5ldmVyeSh0ID0+IGhheS5p
bmNsdWRlcyh0KSk7CiAgICB9CiAgICBmdW5jdGlvbiBmaWx0ZXIoY2xpcHMsIHRhYiwgcSkgewogICAg
ICAgIC8vIOS4u+acuuW3sui/h+a7pOaXtuS7jeWBmuWJjeerr+WFnOW6le+8mumBv+WFjeernuaAgeaO
qOadpeacquWRveS4reihjAogICAgICAgIGNvbnN0IHRlcm1zID0gcXVlcnlUZXJtcyhxKTsKICAgICAg
ICBpZiAoIXRlcm1zLmxlbmd0aCkgcmV0dXJuIGNsaXBzOwogICAgICAgIGNvbnN0IHRlcm1MID0gdGVy
bXMubWFwKHQgPT4gdC50b0xvd2VyQ2FzZSgpKTsKICAgICAgICBjb25zdCBtYXRjaGVkR3JvdXBzID0g
bmV3IFNldCgpOwogICAgICAgIGZvciAoY29uc3QgYyBvZiBjbGlwcykgewogICAgICAgICAgICBpZiAo
IWNsaXBNYXRjaGVzU2VhcmNoKGMsIHRlcm1MKSkgY29udGludWU7CiAgICAgICAgICAgIGNvbnN0IGdp
ZCA9IFN0cmluZyhjICYmIGMuZmF2R3JvdXAgfHwgJycpLnRyaW0oKTsKICAgICAgICAgICAgaWYgKGdp
ZCkgbWF0Y2hlZEdyb3Vwcy5hZGQoZ2lkKTsKICAgICAgICB9CiAgICAgICAgLy8g5ZCI5bm257uE77ya
5YWz6ZSu5a2X5Y+v6IO95YiG5pWj5Zyo5LiN5ZCM6KGM77yI5qCH6aKYL+ato+aWh++8iQogICAgICAg
IGNvbnN0IGJ5R3JvdXAgPSBuZXcgTWFwKCk7CiAgICAgICAgZm9yIChjb25zdCBjIG9mIGNsaXBzKSB7
CiAgICAgICAgICAgIGNvbnN0IGdpZCA9IFN0cmluZyhjICYmIGMuZmF2R3JvdXAgfHwgJycpLnRyaW0o
KTsKICAgICAgICAgICAgaWYgKCFnaWQpIGNvbnRpbnVlOwogICAgICAgICAgICBpZiAoIWJ5R3JvdXAu
aGFzKGdpZCkpIGJ5R3JvdXAuc2V0KGdpZCwgW10pOwogICAgICAgICAgICBieUdyb3VwLmdldChnaWQp
LnB1c2goYyk7CiAgICAgICAgfQogICAgICAgIGZvciAoY29uc3QgW2dpZCwgbWVtYmVyc10gb2YgYnlH
cm91cCkgewogICAgICAgICAgICBpZiAobWF0Y2hlZEdyb3Vwcy5oYXMoZ2lkKSkgY29udGludWU7CiAg
ICAgICAgICAgIGNvbnN0IHVuaW9uID0gbWVtYmVycy5tYXAoYyA9PiB7CiAgICAgICAgICAgICAgICBj
b25zdCB0eXBlID0gU3RyaW5nKGMudHlwZSB8fCAnJykudG9Mb3dlckNhc2UoKTsKICAgICAgICAgICAg
ICAgIHJldHVybiAodHlwZSA9PT0gJ2ltYWdlJyA/IGZhdlRpdGxlSGF5KGMuZmF2VGl0bGUpIDogY2xp
cFNlYXJjaEhheShjKSkudG9Mb3dlckNhc2UoKTsKICAgICAgICAgICAgfSkuam9pbignICcpOwogICAg
ICAgICAgICBpZiAodGVybUwuZXZlcnkodCA9PiB1bmlvbi5pbmNsdWRlcyh0KSkpCiAgICAgICAgICAg
ICAgICBtYXRjaGVkR3JvdXBzLmFkZChnaWQpOwogICAgICAgIH0KICAgICAgICByZXR1cm4gY2xpcHMu
ZmlsdGVyKGMgPT4gewogICAgICAgICAgICBpZiAoY2xpcE1hdGNoZXNTZWFyY2goYywgdGVybUwpKSBy
ZXR1cm4gdHJ1ZTsKICAgICAgICAgICAgY29uc3QgZ2lkID0gU3RyaW5nKGMgJiYgYy5mYXZHcm91cCB8
fCAnJykudHJpbSgpOwogICAgICAgICAgICByZXR1cm4gZ2lkICYmIG1hdGNoZWRHcm91cHMuaGFzKGdp
ZCk7CiAgICAgICAgfSk7CiAgICB9CgogICAgZnVuY3Rpb24gbWFya1Bhc3RlZExvY2FsKGlkcykgewog
ICAgICAgIGNvbnN0IGxpc3QgPSBBcnJheS5pc0FycmF5KGlkcykgPyBpZHMgOiBbaWRzXTsKICAgICAg
ICBpZiAobGlzdC5sZW5ndGgpCiAgICAgICAgICAgIHJlbWVtYmVyTGFzdFBhc3RlKGxpc3RbbGlzdC5s
ZW5ndGggLSAxXSk7CiAgICAgICAgY29uc3QgYmFkZ2VIdG1sID0gYDxzdmcgdmlld0JveD0iMCAwIDE2
IDE2IiBmaWxsPSJub25lIiBzdHJva2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIyLjQiIHN0
cm9rZS1saW5lY2FwPSJyb3VuZCIgc3Ryb2tlLWxpbmVqb2luPSJyb3VuZCI+PHBvbHlsaW5lIHBvaW50
cz0iMy41IDguNSA2LjUgMTEuNSAxMi41IDQuNSIvPjwvc3ZnPmA7CiAgICAgICAgbGlzdC5mb3JFYWNo
KHJhd0lkID0+IHsKICAgICAgICAgICAgY29uc3QgaWQgPSArcmF3SWQ7CiAgICAgICAgICAgIGNvbnN0
IGMgPSBhbGxDbGlwcy5maW5kKHggPT4gK3guaWQgPT09IGlkKTsKICAgICAgICAgICAgaWYgKGMpIGMu
cGFzdGVkID0gdHJ1ZTsKICAgICAgICAgICAgY29uc3Qgcm93ID0gbGlzdEVsICYmICgKICAgICAgICAg
ICAgICAgIGxpc3RFbC5xdWVyeVNlbGVjdG9yKCcuaXRtW2RhdGEtaWQ9IicgKyBpZCArICciXScpCiAg
ICAgICAgICAgICAgICB8fCBsaXN0RWwucXVlcnlTZWxlY3RvcignLml0bVtkYXRhLWlkPSInICsgU3Ry
aW5nKHJhd0lkKSArICciXScpCiAgICAgICAgICAgICk7CiAgICAgICAgICAgIGlmICghcm93KSByZXR1
cm47CiAgICAgICAgICAgIHJvdy5jbGFzc0xpc3QuYWRkKCdwYXN0ZWQnLCAncS1kb25lJyk7CiAgICAg
ICAgICAgIGNvbnN0IGljbyA9IHJvdy5xdWVyeVNlbGVjdG9yKCcuaS1pY28nKTsKICAgICAgICAgICAg
aWYgKGljbyAmJiAhaWNvLnF1ZXJ5U2VsZWN0b3IoJy5pLXVzZWQnKSkgewogICAgICAgICAgICAgICAg
Y29uc3QgYmFkZ2UgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdzcGFuJyk7CiAgICAgICAgICAgICAg
ICBiYWRnZS5jbGFzc05hbWUgPSAnaS11c2VkJzsKICAgICAgICAgICAgICAgIGJhZGdlLnRpdGxlID0g
J+W3sueymOi0tCc7CiAgICAgICAgICAgICAgICBiYWRnZS5pbm5lckhUTUwgPSBiYWRnZUh0bWw7CiAg
ICAgICAgICAgICAgICBpY28uYXBwZW5kQ2hpbGQoYmFkZ2UpOwogICAgICAgICAgICB9CiAgICAgICAg
fSk7CiAgICAgICAgdHJ5IHsgbWFya1F1ZXVlUmFpbHMoKTsgfSBjYXRjaCAoZSkge30KICAgIH0KICAg
IHdpbmRvdy5fX21hcmtQYXN0ZWQgPSBtYXJrUGFzdGVkTG9jYWw7CgogICAgZnVuY3Rpb24gbWFya1Vu
cGFzdGVkTG9jYWwoaWRzKSB7CiAgICAgICAgY29uc3QgbGlzdCA9IEFycmF5LmlzQXJyYXkoaWRzKSA/
IGlkcyA6IFtpZHNdOwogICAgICAgIGxpc3QuZm9yRWFjaChyYXdJZCA9PiB7CiAgICAgICAgICAgIGNv
bnN0IGlkID0gK3Jhd0lkOwogICAgICAgICAgICBjb25zdCBjID0gYWxsQ2xpcHMuZmluZCh4ID0+ICt4
LmlkID09PSBpZCk7CiAgICAgICAgICAgIGlmIChjKSBjLnBhc3RlZCA9IGZhbHNlOwogICAgICAgICAg
ICBjb25zdCByb3cgPSBsaXN0RWwgJiYgKAogICAgICAgICAgICAgICAgbGlzdEVsLnF1ZXJ5U2VsZWN0
b3IoJy5pdG1bZGF0YS1pZD0iJyArIGlkICsgJyJdJykKICAgICAgICAgICAgICAgIHx8IGxpc3RFbC5x
dWVyeVNlbGVjdG9yKCcuaXRtW2RhdGEtaWQ9IicgKyBTdHJpbmcocmF3SWQpICsgJyJdJykKICAgICAg
ICAgICAgKTsKICAgICAgICAgICAgaWYgKCFyb3cpIHJldHVybjsKICAgICAgICAgICAgcm93LmNsYXNz
TGlzdC5yZW1vdmUoJ3Bhc3RlZCcsICdxLWRvbmUnLCAncS1kb25lLWxpbmsnKTsKICAgICAgICAgICAg
Y29uc3QgYmFkZ2UgPSByb3cucXVlcnlTZWxlY3RvcignLmktdXNlZCcpOwogICAgICAgICAgICBpZiAo
YmFkZ2UpIGJhZGdlLnJlbW92ZSgpOwogICAgICAgICAgICBjb25zdCBkb3QgPSByb3cucXVlcnlTZWxl
Y3RvcignLnEtZG90Jyk7CiAgICAgICAgICAgIGlmIChkb3QpIGRvdC50aXRsZSA9ICfnspjotLTpmJ/l
iJcnOwogICAgICAgIH0pOwogICAgICAgIHRyeSB7IG1hcmtRdWV1ZVJhaWxzKCk7IH0gY2F0Y2ggKGUp
IHt9CiAgICB9CiAgICB3aW5kb3cuX19tYXJrVW5wYXN0ZWQgPSBtYXJrVW5wYXN0ZWRMb2NhbDsKCiAg
ICBjb25zdCBsaXN0RWwgID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2xpc3QnKTsKICAgIGNvbnN0
IGVtcHR5RWwgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnZW1wdHknKTsKICAgIGNvbnN0IHNrZWxF
bCAgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc2tlbCcpOwogICAgY29uc3QgYnRuVG9wICA9IGRv
Y3VtZW50LmdldEVsZW1lbnRCeUlkKCdidG4tdG9wJyk7CiAgICBmdW5jdGlvbiBzZXRCb290TG9hZGlu
ZyhvbikgewogICAgICAgIGJvb3RMb2FkaW5nID0gISFvbjsKICAgICAgICAvLyDnp5LlvIDvvJrkuI3l
ho3miZPlvIDpqqjmnrbpl6rliqjvvJvlj6rkv53nlZkgd2FpdGluZ0RhdGEg6YC76L6R6Ziy56m65oCB
6K+v6ZeqCiAgICAgICAgaWYgKHNrZWxFbCkgc2tlbEVsLmNsYXNzTGlzdC5yZW1vdmUoJ29uJyk7CiAg
ICAgICAgaWYgKG9uICYmIGVtcHR5RWwpIGVtcHR5RWwuY2xhc3NMaXN0LnJlbW92ZSgnb24nKTsKICAg
ICAgICBjb25zdCBhcHAgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYXBwJyk7CiAgICAgICAgaWYg
KGFwcCkgYXBwLmNsYXNzTGlzdC5yZW1vdmUoJ2Jvb3QtbG9hZGluZycpOwogICAgfQogICAgLyoqIFdh
aXQgZm9yIGhvc3QgZGF0YSDigJTkuI3lho3nq4vliLvlvLnpqqjmnrbvvIzmnInlhoXlrrnml7bkv53m
jIHml6fliJfooaggKi8KICAgIGZ1bmN0aW9uIHNjaGVkdWxlRGVsYXllZFNrZWwoKSB7CiAgICAgICAg
d2FpdGluZ0RhdGEgPSB0cnVlOwogICAgICAgIHdpbmRvdy5fX2RhdGFSZWFkeSA9IGZhbHNlOwogICAg
ICAgIGlmIChlbXB0eUVsKSBlbXB0eUVsLmNsYXNzTGlzdC5yZW1vdmUoJ29uJyk7CiAgICAgICAgaWYg
KHdpbmRvdy5fX3BlbmRpbmdTa2VsVGltZXIpIHsKICAgICAgICAgICAgY2xlYXJUaW1lb3V0KHdpbmRv
dy5fX3BlbmRpbmdTa2VsVGltZXIpOwogICAgICAgICAgICB3aW5kb3cuX19wZW5kaW5nU2tlbFRpbWVy
ID0gMDsKICAgICAgICB9CiAgICAgICAgd2luZG93Ll9fcGVuZGluZ1NrZWxTaW5jZSA9IERhdGUubm93
KCk7CiAgICAgICAgLy8g5pyJ5pen5YiX6KGo5bCx5L+d55WZ77yb56m65YiX6KGo5Lmf5LiN5YaN5pKt
6aqo5p625Yqo55S7CiAgICB9CiAgICBmdW5jdGlvbiBjbGVhcldhaXRpbmdEYXRhKCkgewogICAgICAg
IHdhaXRpbmdEYXRhID0gZmFsc2U7CiAgICAgICAgaWYgKHdpbmRvdy5fX3BlbmRpbmdTa2VsVGltZXIp
IHsKICAgICAgICAgICAgY2xlYXJUaW1lb3V0KHdpbmRvdy5fX3BlbmRpbmdTa2VsVGltZXIpOwogICAg
ICAgICAgICB3aW5kb3cuX19wZW5kaW5nU2tlbFRpbWVyID0gMDsKICAgICAgICB9CiAgICAgICAgd2lu
ZG93Ll9fcGVuZGluZ1NrZWxTaW5jZSA9IDA7CiAgICAgICAgc2V0Qm9vdExvYWRpbmcoZmFsc2UpOwog
ICAgfQogICAgd2luZG93LnNldEJvb3RMb2FkaW5nID0gc2V0Qm9vdExvYWRpbmc7CiAgICB3aW5kb3cu
Zm9yY2VFbmRCb290TG9hZGluZyA9IGZ1bmN0aW9uKCkgewogICAgICAgIGNsZWFyV2FpdGluZ0RhdGEo
KTsKICAgICAgICAvLyBEbyBub3QgZmFrZeOAjOaaguaXoOiusOW9leOAjWlmIGhvc3QgbmV2ZXIgcHVz
aGVkCiAgICAgICAgaWYgKGhvc3RQdXNoZWRPbmNlKQogICAgICAgICAgICB3aW5kb3cuX19kYXRhUmVh
ZHkgPSB0cnVlOwogICAgICAgIHRyeSB7IHJlbmRlcigpOyB9IGNhdGNoIChlKSB7fQogICAgfTsKICAg
IC8vIFNhZmV0eTogZHJvcCBzdHVjayBza2VsZXRvbjsgc3RpbGwgbmV2ZXIgaW52ZW50IGVtcHR5LXN0
YXRlIHdpdGhvdXQgaG9zdCBwdXNoCiAgICBzZXRUaW1lb3V0KCgpID0+IHsKICAgICAgICBpZiAoaG9z
dFB1c2hlZE9uY2UgfHwgd2luZG93Ll9fZGF0YVJlYWR5KSByZXR1cm47CiAgICAgICAgaWYgKCFib290
TG9hZGluZyAmJiAhd2FpdGluZ0RhdGEpIHJldHVybjsKICAgICAgICBjbGVhcldhaXRpbmdEYXRhKCk7
CiAgICAgICAgdHJ5IHsgcmVuZGVyKCk7IH0gY2F0Y2gge30KICAgIH0sIDgwMDApOwoKICAgIGZ1bmN0
aW9uIHVwZGF0ZVRvcEJ0bigpIHsKICAgICAgICBpZiAoIWJ0blRvcCB8fCAhbGlzdEVsKSByZXR1cm47
CiAgICAgICAgYnRuVG9wLmNsYXNzTGlzdC50b2dnbGUoJ29uJywgbGlzdEVsLnNjcm9sbFRvcCA+IDQ4
KTsKICAgIH0KICAgIGxldCBfc2Nyb2xsUmFmID0gMDsKICAgIGxldCBfc2Nyb2xsSWRsZVQgPSAwOwog
ICAgbGV0IF9saXN0UHRyRG93biA9IGZhbHNlOwogICAgbGV0IF9wZW5kaW5nQXBwZW5kID0gbnVsbDsg
Ly8geyBmcm9tTGVuIH0gcXVldWVkIHdoaWxlIHNjcm9sbGluZwogICAgd2luZG93Ll9fc2Nyb2xsQnVz
eSA9IGZhbHNlOwogICAgd2luZG93Ll9fd2FudE1vcmUgPSBmYWxzZTsKCiAgICBmdW5jdGlvbiBtYXJr
TGlzdFNjcm9sbGluZygpIHsKICAgICAgICB3aW5kb3cuX19zY3JvbGxCdXN5ID0gdHJ1ZTsKICAgICAg
ICB0cnkgeyBsaXN0RWwuY2xhc3NMaXN0LmFkZCgnaXMtc2Nyb2xsaW5nJyk7IH0gY2F0Y2gge30KICAg
ICAgICBpZiAoX3Njcm9sbElkbGVUKSBjbGVhclRpbWVvdXQoX3Njcm9sbElkbGVUKTsKICAgICAgICBf
c2Nyb2xsSWRsZVQgPSBzZXRUaW1lb3V0KCgpID0+IHsKICAgICAgICAgICAgX3Njcm9sbElkbGVUID0g
MDsKICAgICAgICAgICAgZmx1c2hTY3JvbGxJZGxlKCk7CiAgICAgICAgfSwgMjIwKTsKICAgIH0KCiAg
ICBmdW5jdGlvbiBmbHVzaFNjcm9sbElkbGUoKSB7CiAgICAgICAgaWYgKF9saXN0UHRyRG93bikgewog
ICAgICAgICAgICBtYXJrTGlzdFNjcm9sbGluZygpOwogICAgICAgICAgICByZXR1cm47CiAgICAgICAg
fQogICAgICAgIHdpbmRvdy5fX3Njcm9sbEJ1c3kgPSBmYWxzZTsKICAgICAgICB0cnkgeyBsaXN0RWwu
Y2xhc3NMaXN0LnJlbW92ZSgnaXMtc2Nyb2xsaW5nJyk7IH0gY2F0Y2gge30KICAgICAgICBpZiAoX3Bl
bmRpbmdBcHBlbmQpIHsKICAgICAgICAgICAgY29uc3QgcGVuZGluZyA9IF9wZW5kaW5nQXBwZW5kOwog
ICAgICAgICAgICBfcGVuZGluZ0FwcGVuZCA9IG51bGw7CiAgICAgICAgICAgIGFwcGx5QXBwZW5kUGF5
bG9hZChwZW5kaW5nKTsKICAgICAgICB9CiAgICAgICAgaWYgKHdpbmRvdy5fX3dhbnRNb3JlKQogICAg
ICAgICAgICByZXF1ZXN0TW9yZSgpOwogICAgICAgIGVsc2UgaWYgKCFsb2FkaW5nTW9yZQogICAgICAg
ICAgICAmJiBkaXNrVG90YWwgPiAwCiAgICAgICAgICAgICYmIGFsbENsaXBzLmxlbmd0aCA8IGRpc2tU
b3RhbAogICAgICAgICAgICAmJiBsaXN0RWwuc2Nyb2xsVG9wICsgbGlzdEVsLmNsaWVudEhlaWdodCA+
PSBsaXN0RWwuc2Nyb2xsSGVpZ2h0IC0gNDIwKQogICAgICAgICAgICByZXF1ZXN0TW9yZSgpOwogICAg
fQoKICAgIGZ1bmN0aW9uIG9uTGlzdFNjcm9sbCgpIHsKICAgICAgICBtYXJrTGlzdFNjcm9sbGluZygp
OwogICAgICAgIGlmIChfc2Nyb2xsUmFmKSByZXR1cm47CiAgICAgICAgX3Njcm9sbFJhZiA9IHJlcXVl
c3RBbmltYXRpb25GcmFtZSgoKSA9PiB7CiAgICAgICAgICAgIF9zY3JvbGxSYWYgPSAwOwogICAgICAg
ICAgICB0cnkgeyBoaWRlUGF0aFRpcCgpOyB9IGNhdGNoIHt9CiAgICAgICAgICAgIHVwZGF0ZVRvcEJ0
bigpOwogICAgICAgICAgICBpZiAoIWxvYWRpbmdNb3JlCiAgICAgICAgICAgICAgICAmJiBkaXNrVG90
YWwgPiAwCiAgICAgICAgICAgICAgICAmJiBhbGxDbGlwcy5sZW5ndGggPCBkaXNrVG90YWwKICAgICAg
ICAgICAgICAgICYmIGxpc3RFbC5zY3JvbGxUb3AgKyBsaXN0RWwuY2xpZW50SGVpZ2h0ID49IGxpc3RF
bC5zY3JvbGxIZWlnaHQgLSAyNDApCiAgICAgICAgICAgICAgICB3aW5kb3cuX193YW50TW9yZSA9IHRy
dWU7CiAgICAgICAgfSk7CiAgICB9CiAgICBsaXN0RWwuYWRkRXZlbnRMaXN0ZW5lcignc2Nyb2xsJywg
b25MaXN0U2Nyb2xsLCB7IHBhc3NpdmU6IHRydWUgfSk7CiAgICBsaXN0RWwuYWRkRXZlbnRMaXN0ZW5l
cignd2hlZWwnLCBtYXJrTGlzdFNjcm9sbGluZywgeyBwYXNzaXZlOiB0cnVlIH0pOwogICAgbGlzdEVs
LmFkZEV2ZW50TGlzdGVuZXIoJ3BvaW50ZXJkb3duJywgZSA9PiB7CiAgICAgICAgaWYgKGUuYnV0dG9u
ICE9PSAwKSByZXR1cm47CiAgICAgICAgX2xpc3RQdHJEb3duID0gdHJ1ZTsKICAgICAgICBtYXJrTGlz
dFNjcm9sbGluZygpOwogICAgfSwgeyBwYXNzaXZlOiB0cnVlIH0pOwogICAgd2luZG93LmFkZEV2ZW50
TGlzdGVuZXIoJ3BvaW50ZXJ1cCcsICgpID0+IHsKICAgICAgICBpZiAoIV9saXN0UHRyRG93bikgcmV0
dXJuOwogICAgICAgIF9saXN0UHRyRG93biA9IGZhbHNlOwogICAgICAgIG1hcmtMaXN0U2Nyb2xsaW5n
KCk7CiAgICB9LCB7IHBhc3NpdmU6IHRydWUgfSk7CiAgICB3aW5kb3cuYWRkRXZlbnRMaXN0ZW5lcign
cG9pbnRlcmNhbmNlbCcsICgpID0+IHsKICAgICAgICBpZiAoIV9saXN0UHRyRG93bikgcmV0dXJuOwog
ICAgICAgIF9saXN0UHRyRG93biA9IGZhbHNlOwogICAgICAgIG1hcmtMaXN0U2Nyb2xsaW5nKCk7CiAg
ICB9LCB7IHBhc3NpdmU6IHRydWUgfSk7CiAgICBidG5Ub3AuYWRkRXZlbnRMaXN0ZW5lcignY2xpY2sn
LCBlID0+IHsKICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgICAgIGxpc3RFbC5zY3JvbGxU
byh7IHRvcDogMCwgYmVoYXZpb3I6ICdzbW9vdGgnIH0pOwogICAgfSk7CgogICAgZnVuY3Rpb24gdmlz
aWJsZUxpc3QoKSB7CiAgICAgICAgY29uc3QgcSA9IFN0cmluZyhxdWVyeSB8fCAnJykudHJpbSgpOwog
ICAgICAgIC8vIEhvc3QgYWxyZWFkeSBmaWx0ZXJlZCtleHBhbmRlZCBmb3IgdGhpcyBleGFjdCBxdWVy
eSDigJQgZG9uJ3QgcmUtZmlsdGVyIChhdm9pZHMgZmxhc2ggLyBkcm9wcGVkIGZhdiBncm91cHMpCiAg
ICAgICAgbGV0IGxpc3QgPSAocSAmJiB3aW5kb3cuX19ob3N0RmlsdGVyZWQgJiYgd2luZG93Ll9faG9z
dEZpbHRlclEgPT09IHEpCiAgICAgICAgICAgID8gYWxsQ2xpcHMKICAgICAgICAgICAgOiBmaWx0ZXIo
YWxsQ2xpcHMsIGN1clRhYiwgcXVlcnkpOwogICAgICAgIC8vIOaUtuiXj+mhte+8muacrOWcsOWGjea7
pOS4gOasoe+8jOWPlua2iOaUtuiXj+WPr+eri+WIu+a2iOWkse+8jOS4jeW/heetiSBBSEsg6YeN5bu6
CiAgICAgICAgaWYgKGN1clRhYiA9PT0gJ3Bpbm5lZCcpCiAgICAgICAgICAgIGxpc3QgPSBsaXN0LmZp
bHRlcihjID0+IGlzUGlubmVkKGMpKTsKICAgICAgICByZXR1cm4gbGlzdDsKICAgIH0KICAgIGZ1bmN0
aW9uIGVzY0h0bWwocykgewogICAgICAgIHJldHVybiBTdHJpbmcocyA/PyAnJykucmVwbGFjZSgvJi9n
LCcmYW1wOycpLnJlcGxhY2UoLzwvZywnJmx0OycpLnJlcGxhY2UoLz4vZywnJmd0OycpLnJlcGxhY2Uo
LyIvZywnJnF1b3Q7Jyk7CiAgICB9CiAgICBmdW5jdGlvbiBxdWVyeVRlcm1zKHEpIHsKICAgICAgICBj
b25zdCBvdXQgPSBbXTsKICAgICAgICBmb3IgKGNvbnN0IHNlZyBvZiBTdHJpbmcocSB8fCAnJykuc3Bs
aXQoJ3wnKSkgewogICAgICAgICAgICBjb25zdCBzID0gc2VnLnRyaW0oKTsKICAgICAgICAgICAgaWYg
KCFzKSBjb250aW51ZTsKICAgICAgICAgICAgY29uc3Qgd29yZHMgPSBzLnNwbGl0KC9ccysvKS5maWx0
ZXIoQm9vbGVhbik7CiAgICAgICAgICAgIGlmICh3b3Jkcy5sZW5ndGgpIG91dC5wdXNoKC4uLndvcmRz
KTsKICAgICAgICB9CiAgICAgICAgcmV0dXJuIG91dDsKICAgIH0KICAgIGZ1bmN0aW9uIGhsSHRtbCh0
ZXh0KSB7CiAgICAgICAgY29uc3QgdGVybXMgPSBxdWVyeVRlcm1zKHF1ZXJ5KTsKICAgICAgICBjb25z
dCBzID0gU3RyaW5nKHRleHQgPz8gJycpOwogICAgICAgIGlmICghdGVybXMubGVuZ3RoKSByZXR1cm4g
ZXNjSHRtbChzKTsKICAgICAgICBjb25zdCBsb3dlciA9IHMudG9Mb3dlckNhc2UoKTsKICAgICAgICBj
b25zdCB0ZXJtTCA9IHRlcm1zLm1hcCh0ID0+IHQudG9Mb3dlckNhc2UoKSk7CiAgICAgICAgbGV0IG91
dCA9ICcnLCBpID0gMDsKICAgICAgICB3aGlsZSAoaSA8IHMubGVuZ3RoKSB7CiAgICAgICAgICAgIGxl
dCBiZXN0SiA9IC0xLCBiZXN0TGVuID0gMDsKICAgICAgICAgICAgZm9yIChsZXQgdGkgPSAwOyB0aSA8
IHRlcm1MLmxlbmd0aDsgdGkrKykgewogICAgICAgICAgICAgICAgY29uc3QgdCA9IHRlcm1MW3RpXTsK
ICAgICAgICAgICAgICAgIGlmICghdCkgY29udGludWU7CiAgICAgICAgICAgICAgICBjb25zdCBqID0g
bG93ZXIuaW5kZXhPZih0LCBpKTsKICAgICAgICAgICAgICAgIGlmIChqIDwgMCkgY29udGludWU7CiAg
ICAgICAgICAgICAgICBpZiAoYmVzdEogPCAwIHx8IGogPCBiZXN0SiB8fCAoaiA9PT0gYmVzdEogJiYg
dC5sZW5ndGggPiBiZXN0TGVuKSkgewogICAgICAgICAgICAgICAgICAgIGJlc3RKID0gajsgYmVzdExl
biA9IHQubGVuZ3RoOwogICAgICAgICAgICAgICAgfQogICAgICAgICAgICB9CiAgICAgICAgICAgIGlm
IChiZXN0SiA8IDApIHsgb3V0ICs9IGVzY0h0bWwocy5zbGljZShpKSk7IGJyZWFrOyB9CiAgICAgICAg
ICAgIG91dCArPSBlc2NIdG1sKHMuc2xpY2UoaSwgYmVzdEopKTsKICAgICAgICAgICAgb3V0ICs9ICc8
bWFyayBjbGFzcz0icS1obCI+JyArIGVzY0h0bWwocy5zbGljZShiZXN0SiwgYmVzdEogKyBiZXN0TGVu
KSkgKyAnPC9tYXJrPic7CiAgICAgICAgICAgIGkgPSBiZXN0SiArIE1hdGgubWF4KDEsIGJlc3RMZW4p
OwogICAgICAgIH0KICAgICAgICByZXR1cm4gb3V0OwogICAgfQogICAgZnVuY3Rpb24gc2V0SGxUZXh0
KGVsLCB0ZXh0KSB7CiAgICAgICAgaWYgKCFlbCkgcmV0dXJuOwogICAgICAgIGNvbnN0IHEgPSBTdHJp
bmcocXVlcnkgfHwgJycpLnRyaW0oKTsKICAgICAgICBpZiAoIXEpIHsKICAgICAgICAgICAgZWwuY2xh
c3NMaXN0LnJlbW92ZSgnaGFzLWhsJyk7CiAgICAgICAgICAgIGVsLnRleHRDb250ZW50ID0gdGV4dCA9
PSBudWxsID8gJycgOiBTdHJpbmcodGV4dCk7CiAgICAgICAgICAgIHJldHVybjsKICAgICAgICB9CiAg
ICAgICAgZWwuY2xhc3NMaXN0LmFkZCgnaGFzLWhsJyk7CiAgICAgICAgZWwuaW5uZXJIVE1MID0gaGxI
dG1sKHRleHQpOwogICAgfQoKCiAgICBmdW5jdGlvbiBhcHBseVRhYlN3aXRjaEFuaW0oKSB7CiAgICAg
ICAgaWYgKCF0YWJTd2l0Y2hBbmltRGlyIHx8ICFsaXN0RWwpIHJldHVybjsKICAgICAgICBpZiAoIWxp
c3RFbC5xdWVyeVNlbGVjdG9yKCcuaXRtLCAjZW1wdHkub24sICNsaXN0LW1vcmUnKSkKICAgICAgICAg
ICAgcmV0dXJuOwogICAgICAgIGNvbnN0IGRpciA9IHRhYlN3aXRjaEFuaW1EaXI7CiAgICAgICAgdGFi
U3dpdGNoQW5pbURpciA9IDA7CiAgICAgICAgbGlzdEVsLmNsYXNzTGlzdC5yZW1vdmUoJ3RhYi1pbi1s
cicsICd0YWItaW4tcmwnKTsKICAgICAgICB2b2lkIGxpc3RFbC5vZmZzZXRXaWR0aDsKICAgICAgICBs
aXN0RWwuY2xhc3NMaXN0LmFkZChkaXIgPiAwID8gJ3RhYi1pbi1scicgOiAndGFiLWluLXJsJyk7CiAg
ICAgICAgY2xlYXJUaW1lb3V0KGxpc3RFbC5fdGFiQW5pbVRpbWVyKTsKICAgICAgICBsaXN0RWwuX3Rh
YkFuaW1UaW1lciA9IHNldFRpbWVvdXQoKCkgPT4gewogICAgICAgICAgICBsaXN0RWwuY2xhc3NMaXN0
LnJlbW92ZSgndGFiLWluLWxyJywgJ3RhYi1pbi1ybCcpOwogICAgICAgIH0sIDQwMCk7CiAgICB9Cgog
ICAgZnVuY3Rpb24gdGFiSW5kZXgodGFiKSB7CiAgICAgICAgY29uc3QgaSA9IFRBQl9PUkRFUi5pbmRl
eE9mKHRhYik7CiAgICAgICAgcmV0dXJuIGkgPj0gMCA/IGkgOiAwOwogICAgfQoKICAgIGZ1bmN0aW9u
IG1vdmVUYWJJbmsoaW5zdGFudCwgdGFyZ2V0RWwpIHsKICAgICAgICBjb25zdCBpbmsgPSBkb2N1bWVu
dC5nZXRFbGVtZW50QnlJZCgndGFiLWluaycpOwogICAgICAgIGNvbnN0IHRhYnMgPSBkb2N1bWVudC5n
ZXRFbGVtZW50QnlJZCgndGFicycpOwogICAgICAgIGNvbnN0IGVsID0gdGFyZ2V0RWwgfHwgZG9jdW1l
bnQucXVlcnlTZWxlY3RvcignI3RhYnMgLnRhYi5vbicpOwogICAgICAgIGlmICghaW5rIHx8ICF0YWJz
IHx8ICFlbCkgcmV0dXJuOwogICAgICAgIGNvbnN0IHRyID0gdGFicy5nZXRCb3VuZGluZ0NsaWVudFJl
Y3QoKTsKICAgICAgICBjb25zdCByID0gZWwuZ2V0Qm91bmRpbmdDbGllbnRSZWN0KCk7CiAgICAgICAg
Y29uc3QgeCA9IHIubGVmdCAtIHRyLmxlZnQ7CiAgICAgICAgY29uc3QgaCA9IE1hdGgubWF4KDIwLCBN
YXRoLnJvdW5kKHIuaGVpZ2h0KSk7CiAgICAgICAgY29uc3QgeSA9IHIudG9wIC0gdHIudG9wOwogICAg
ICAgIGNvbnN0IHcgPSBNYXRoLm1heCgyNCwgci53aWR0aCk7CiAgICAgICAgY29uc3QgcG9zID0gJ3Ry
YW5zbGF0ZTNkKCcgKyB4ICsgJ3B4LCcgKyB5ICsgJ3B4LDApJzsKICAgICAgICBpbmsuc3R5bGUudHJh
bnNmb3JtT3JpZ2luID0gJ2NlbnRlciBib3R0b20nOwogICAgICAgIGluay5zdHlsZS53aWR0aCA9IHcg
KyAncHgnOwogICAgICAgIGluay5zdHlsZS5oZWlnaHQgPSBoICsgJ3B4JzsKICAgICAgICBpZiAoaW5z
dGFudCkgewogICAgICAgICAgICBpbmsuc3R5bGUudHJhbnNpdGlvbiA9ICdub25lJzsKICAgICAgICAg
ICAgaW5rLmNsYXNzTGlzdC5yZW1vdmUoJ3NxdWFzaCcpOwogICAgICAgICAgICBpbmsuc3R5bGUudHJh
bnNmb3JtID0gcG9zICsgJyBzY2FsZVgoMSknOwogICAgICAgICAgICBpbmsub2Zmc2V0SGVpZ2h0Owog
ICAgICAgICAgICBpbmsuc3R5bGUudHJhbnNpdGlvbiA9ICcnOwogICAgICAgICAgICByZXR1cm47CiAg
ICAgICAgfQogICAgICAgIC8vIFNuYXAgdG8gaG92ZXJlZCB0YWIsIGV4cGFuZCBmcm9tIGJvdHRvbS1j
ZW50ZXIg4oCUIG5vIHNsaWRpbmcgYmV0d2VlbiB0YWJzCiAgICAgICAgaW5rLnN0eWxlLnRyYW5zaXRp
b24gPSAnbm9uZSc7CiAgICAgICAgaW5rLnN0eWxlLnRyYW5zZm9ybSA9IHBvcyArICcgc2NhbGVYKDAu
MDAxKSc7CiAgICAgICAgaW5rLm9mZnNldEhlaWdodDsKICAgICAgICBpbmsuc3R5bGUudHJhbnNpdGlv
biA9ICcnOwogICAgICAgIGluay5jbGFzc0xpc3QuYWRkKCdzcXVhc2gnKTsKICAgICAgICBpbmsuc3R5
bGUudHJhbnNmb3JtID0gcG9zICsgJyBzY2FsZVgoMSknOwogICAgICAgIGNsZWFyVGltZW91dChpbmsu
X3NxdWFzaFRpbWVyKTsKICAgICAgICBpbmsuX3NxdWFzaFRpbWVyID0gc2V0VGltZW91dCgoKSA9PiBp
bmsuY2xhc3NMaXN0LnJlbW92ZSgnc3F1YXNoJyksIDM0MCk7CiAgICB9CiAgICBmdW5jdGlvbiBtYXJr
VGFiKHRhYiwgaW5zdGFudCkgewogICAgICAgIGRvY3VtZW50LnF1ZXJ5U2VsZWN0b3JBbGwoJyN0YWJz
IC50YWInKS5mb3JFYWNoKGVsID0+CiAgICAgICAgICAgIGVsLmNsYXNzTGlzdC50b2dnbGUoJ29uJywg
ZWwuZGF0YXNldC50YWIgPT09IHRhYikpOwogICAgICAgIGNvbnN0IGFwcCA9IGRvY3VtZW50LmdldEVs
ZW1lbnRCeUlkKCdhcHAnKTsKICAgICAgICBpZiAoYXBwKSBhcHAuZGF0YXNldC50YWIgPSB0YWIgfHwg
J2FsbCc7CiAgICAgICAgbW92ZVRhYkluayghIWluc3RhbnQpOwogICAgfQogICAgZnVuY3Rpb24gYmlu
ZFRhYklua0hvdmVyKCkgewogICAgICAgIGNvbnN0IHRhYnMgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJ
ZCgndGFicycpOwogICAgICAgIGlmICghdGFicyB8fCB0YWJzLl9pbmtIb3ZlckJvdW5kKSByZXR1cm47
CiAgICAgICAgdGFicy5faW5rSG92ZXJCb3VuZCA9IHRydWU7CiAgICAgICAgdGFicy5hZGRFdmVudExp
c3RlbmVyKCdwb2ludGVyb3ZlcicsIGUgPT4gewogICAgICAgICAgICBjb25zdCB0YWIgPSBlLnRhcmdl
dC5jbG9zZXN0KCcudGFiJyk7CiAgICAgICAgICAgIGlmICghdGFiIHx8ICF0YWJzLmNvbnRhaW5zKHRh
YikpIHJldHVybjsKICAgICAgICAgICAgbW92ZVRhYkluayhmYWxzZSwgdGFiKTsKICAgICAgICB9KTsK
ICAgICAgICB0YWJzLmFkZEV2ZW50TGlzdGVuZXIoJ3BvaW50ZXJsZWF2ZScsIGUgPT4gewogICAgICAg
ICAgICBpZiAoZS5yZWxhdGVkVGFyZ2V0ICYmIHRhYnMuY29udGFpbnMoZS5yZWxhdGVkVGFyZ2V0KSkg
cmV0dXJuOwogICAgICAgICAgICBtb3ZlVGFiSW5rKGZhbHNlKTsKICAgICAgICB9KTsKICAgIH0KZnVu
Y3Rpb24gc2V0VGFiKHRhYikgewogICAgICAgIGlmICh0YWIgPT09IGN1clRhYikgcmV0dXJuOwogICAg
ICAgIGNvbnN0IGZyb20gPSB0YWJJbmRleChjdXJUYWIpOwogICAgICAgIGNvbnN0IHRvID0gdGFiSW5k
ZXgodGFiKTsKICAgICAgICB0YWJTd2l0Y2hBbmltRGlyID0gdG8gPiBmcm9tID8gMSA6ICh0byA8IGZy
b20gPyAtMSA6IDApOwogICAgICAgIGN1clRhYiA9IHRhYjsKICAgICAgICBsb2FkaW5nTW9yZSA9IGZh
bHNlOwogICAgICAgIG1hcmtUYWIodGFiKTsKICAgICAgICAvLyDmiZPlvIDmlLbol4/lubbmn6XnnIvl
kI7vvIzmuIXpmaTjgIzmlrDmlLbol4/jgI3nu7/ngrkKICAgICAgICBpZiAodGFiID09PSAncGlubmVk
JykKICAgICAgICAgICAgY2xlYXJGYXZVbnNlZW4oKTsKCiAgICAgICAgLy8gS2VlcCBzZWFyY2ggInRv
ZGF5IiBmaWx0ZXIgaW4gc3luYyB3aGVuIHNlYXJjaCBpcyBvcGVuCiAgICAgICAgdHJ5IHsKICAgICAg
ICAgICAgY29uc3Qgd3JhcCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzZWFyY2gtd3JhcCcpOwog
ICAgICAgICAgICBjb25zdCBidG5Ub2RheSA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdidG4tdG9k
YXknKTsKICAgICAgICAgICAgaWYgKHdyYXAgJiYgd3JhcC5jbGFzc0xpc3QuY29udGFpbnMoJ29wZW4n
KSkgewogICAgICAgICAgICAgICAgY29uc3Qgd2FudFRvZGF5ID0gZmFsc2U7CiAgICAgICAgICAgICAg
ICBpZiAodG9kYXlPbmx5ICE9PSB3YW50VG9kYXkpIHsKICAgICAgICAgICAgICAgICAgICB0b2RheU9u
bHkgPSB3YW50VG9kYXk7CiAgICAgICAgICAgICAgICAgICAgaWYgKGJ0blRvZGF5KSBidG5Ub2RheS5j
bGFzc0xpc3QudG9nZ2xlKCdvbicsIHRvZGF5T25seSk7CiAgICAgICAgICAgICAgICB9CiAgICAgICAg
ICAgIH0KICAgICAgICB9IGNhdGNoIHt9CgogICAgICAgIHNlbGVjdGVkSWQgPSBudWxsOwogICAgICAg
IG11bHRpSWRzID0gW107CiAgICAgICAgbGlzdEVsLnNjcm9sbFRvcCA9IDA7CiAgICAgICAgY29uc3Qg
aGl0ID0gdmlld01lbS5nZXQodmlld01lbUtleSh0YWIsIHF1ZXJ5LCB0b2RheU9ubHkpKTsKICAgICAg
ICBpZiAoaGl0ICYmIEFycmF5LmlzQXJyYXkoaGl0Lml0ZW1zKSAmJiBoaXQuaXRlbXMubGVuZ3RoKSB7
CiAgICAgICAgICAgIGFsbENsaXBzID0gaGl0Lml0ZW1zLnNsaWNlKCk7CiAgICAgICAgICAgIGRpc2tU
b3RhbCA9IE51bWJlcihoaXQudG90YWwpIHx8IGhpdC5pdGVtcy5sZW5ndGg7CiAgICAgICAgICAgIHdp
bmRvdy5fX3dhaXRpbmdWaWV3ID0gZmFsc2U7CiAgICAgICAgICAgIGNsZWFyV2FpdGluZ0RhdGEoKTsK
ICAgICAgICAgICAgd2luZG93Ll9fZGF0YVJlYWR5ID0gdHJ1ZTsKICAgICAgICAgICAgaG9zdFB1c2hl
ZE9uY2UgPSB0cnVlOwogICAgICAgICAgICBzYXdOb25FbXB0eSA9IHRydWU7CiAgICAgICAgICAgIHJl
bmRlcigpOwogICAgICAgICAgICBhcHBseVRhYlN3aXRjaEFuaW0oKTsKICAgICAgICAgICAgLy8gTWVt
b3J5IHBhaW50IGZpcnN0IOKAlGJhY2tncm91bmQgc29mdC1zeW5jIGtlZXBzIEFISyBpbiBzdGVwIHdp
dGhvdXQgZG91YmxlIHJlZHJhdwogICAgICAgICAgICBzb2Z0UmVxdWVzdFZpZXcoKTsKICAgICAgICAg
ICAgcmV0dXJuOwogICAgICAgIH0KICAgICAgICAvLyBObyBjYWNoZSB5ZXQ6IGtlZXAgY3VycmVudCBy
b3dzIOKAlCBORVZFUiB3aXBlIHRvIGJsYW5rIHdoaXRlCiAgICAgICAgd2luZG93Ll9fd2FpdGluZ1Zp
ZXcgPSB0cnVlOwogICAgICAgIHNjaGVkdWxlRGVsYXllZFNrZWwoKTsKICAgICAgICBpZiAoIWFsbENs
aXBzLmxlbmd0aCkKICAgICAgICAgICAgcmVuZGVyKCk7CiAgICAgICAgcmVxdWVzdFZpZXcoKTsKICAg
ICAgICBhcHBseVRhYlN3aXRjaEFuaW0oKTsKICAgIH0KCiAgICBtb3ZlVGFiSW5rKHRydWUpOwogICAg
YmluZFRhYklua0hvdmVyKCk7CiAgICB0cnkgeyBuZXcgUmVzaXplT2JzZXJ2ZXIoKCkgPT4gbW92ZVRh
Ykluayh0cnVlKSkub2JzZXJ2ZShkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgndGFicycpKTsgfSBjYXRj
aCB7fQogICAgd2luZG93LmFkZEV2ZW50TGlzdGVuZXIoJ3Jlc2l6ZScsICgpID0+IG1vdmVUYWJJbmso
dHJ1ZSkpOwoKICAgIGZ1bmN0aW9uIHVwZGF0ZU1vcmVGb290ZXIodG90YWwpIHsKICAgICAgICBsZXQg
bW9yZUVsID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2xpc3QtbW9yZScpOwogICAgICAgIGNvbnN0
IGxvYWRlZCA9IGFsbENsaXBzLmxlbmd0aDsKICAgICAgICBpZiAobG9hZGVkID49IHRvdGFsKSB7CiAg
ICAgICAgICAgIGlmIChtb3JlRWwpIG1vcmVFbC5yZW1vdmUoKTsKICAgICAgICAgICAgcmV0dXJuOwog
ICAgICAgIH0KICAgICAgICBpZiAoIW1vcmVFbCkgewogICAgICAgICAgICBtb3JlRWwgPSBkb2N1bWVu
dC5jcmVhdGVFbGVtZW50KCdkaXYnKTsKICAgICAgICAgICAgbW9yZUVsLmlkID0gJ2xpc3QtbW9yZSc7
CiAgICAgICAgICAgIG1vcmVFbC5jbGFzc05hbWUgPSAnbGlzdC1tb3JlJzsKICAgICAgICAgICAgbGlz
dEVsLmFwcGVuZENoaWxkKG1vcmVFbCk7CiAgICAgICAgfQogICAgICAgIG1vcmVFbC50ZXh0Q29udGVu
dCA9ICfnu6fnu63kuIvmu5Hku47no4Hnm5jliqDovb3vvIgnICsgbG9hZGVkICsgJy8nICsgdG90YWwg
KyAn77yJJzsKICAgIH0KCiAgICAvKiogVXBkYXRlIGJhciAvIHBpbiBiYWRnZSB3aXRob3V0IHRvdWNo
aW5nIHRoZSBsaXN0IERPTSAqLwogICAgZnVuY3Rpb24gcmVmcmVzaExpc3RDaHJvbWUoKSB7CiAgICAg
ICAgY29uc3QgdmlzaWJsZSA9IHZpc2libGVMaXN0KCk7CiAgICAgICAgY29uc3QgbG9hZGVkID0gYWxs
Q2xpcHMubGVuZ3RoOwogICAgICAgIGNvbnN0IHNob3duQ291bnQgPSB2aXNpYmxlLmxlbmd0aDsKICAg
ICAgICBsZXQgcGlubmVkTiA9IE51bWJlcihwaW5uZWRUb3RhbCkgfHwgMDsKICAgICAgICBpZiAocGlu
bmVkTiA8IDEpIHsKICAgICAgICAgICAgaWYgKGN1clRhYiA9PT0gJ3Bpbm5lZCcpCiAgICAgICAgICAg
ICAgICBwaW5uZWROID0gTWF0aC5tYXgoTnVtYmVyKGRpc2tUb3RhbCkgfHwgMCwgbG9hZGVkKTsKICAg
ICAgICAgICAgZWxzZQogICAgICAgICAgICAgICAgcGlubmVkTiA9IGFsbENsaXBzLmZpbHRlcihjID0+
IGlzUGlubmVkKGMpKS5sZW5ndGg7CiAgICAgICAgfQogICAgICAgIHVwZGF0ZVBpbkRvdCgpOwogICAg
ICAgIGxldCBzaG93VG90YWwgPSBkaXNrVG90YWwgPiAwID8gZGlza1RvdGFsIDogKGxvYWRlZCB8fCAw
KTsKICAgICAgICBpZiAoY3VyVGFiID09PSAncGlubmVkJyAmJiBwaW5uZWROID4gc2hvd1RvdGFsKQog
ICAgICAgICAgICBzaG93VG90YWwgPSBwaW5uZWROOwogICAgICAgIGNvbnN0IHFPbiA9IFN0cmluZyhx
dWVyeSB8fCAnJykudHJpbSgpLmxlbmd0aCA+IDA7CiAgICAgICAgY29uc3QgYmFyID0gZG9jdW1lbnQu
Z2V0RWxlbWVudEJ5SWQoJ2Jhci10eHQnKTsKICAgICAgICBpZiAoYmFyKSB7CiAgICAgICAgICAgIGJh
ci50ZXh0Q29udGVudCA9IHFPbgogICAgICAgICAgICAgICAgPyAoc2hvd25Db3VudCArICcg5p2hJykK
ICAgICAgICAgICAgICAgIDogKHNob3dUb3RhbCA+IGxvYWRlZCA/IChzaG93bkNvdW50ICsgJyAvICcg
KyBzaG93VG90YWwgKyAnIOadoScpIDogKHNob3dUb3RhbCArICcg5p2hJykpOwogICAgICAgIH0KICAg
ICAgICB1cGRhdGVNb3JlRm9vdGVyKGRpc2tUb3RhbCk7CiAgICAgICAgdXBkYXRlVG9wQnRuKCk7CiAg
ICB9CgogICAgLyoqCiAgICAgKiBMb2FkLW1vcmU6IGFwcGVuZCBvbmx5IG5ldyBET00gbm9kZXMuIEZ1
bGwgcmVuZGVyKCkgbnVrZXMgZXZlcnkgLml0bSBhbmQKICAgICAqIHJlc3RvcmVzIHNjcm9sbFRvcCDi
gJQgdGhhdCBoaXRjaCBpcyB3aGF0IG1ha2VzIGRyYWdnaW5nIHRoZSBzY3JvbGxiYXIgZmVlbCBzdGlj
a3kuCiAgICAgKi8KICAgIGZ1bmN0aW9uIGFwcGVuZFJlbmRlcihwcmV2TGVuKSB7CiAgICAgICAgY29u
c3QgdmlzaWJsZSA9IHZpc2libGVMaXN0KCk7CiAgICAgICAgaWYgKCF2aXNpYmxlLmxlbmd0aCkgewog
ICAgICAgICAgICByZW5kZXIoKTsKICAgICAgICAgICAgcmV0dXJuIGZhbHNlOwogICAgICAgIH0KICAg
ICAgICBpZiAocHJldkxlbiA+IDAgJiYgcHJldkxlbiA8IGFsbENsaXBzLmxlbmd0aCkgewogICAgICAg
ICAgICBjb25zdCBzZWFtR2lkcyA9IG5ldyBTZXQoKTsKICAgICAgICAgICAgZm9yIChsZXQgaSA9IE1h
dGgubWF4KDAsIHByZXZMZW4gLSA4KTsgaSA8IE1hdGgubWluKGFsbENsaXBzLmxlbmd0aCwgcHJldkxl
biArIDgpOyBpKyspIHsKICAgICAgICAgICAgICAgIGNvbnN0IGcgPSBmYXZHcm91cE9mKGFsbENsaXBz
W2ldKTsKICAgICAgICAgICAgICAgIGlmIChnKSBzZWFtR2lkcy5hZGQoZyk7CiAgICAgICAgICAgIH0K
ICAgICAgICAgICAgaWYgKHNlYW1HaWRzLnNpemUpIHsKICAgICAgICAgICAgICAgIGZvciAoY29uc3Qg
ZyBvZiBzZWFtR2lkcykgewogICAgICAgICAgICAgICAgICAgIGxldCBiZWZvcmUgPSAwLCBhZnRlciA9
IDA7CiAgICAgICAgICAgICAgICAgICAgZm9yIChsZXQgaSA9IDA7IGkgPCBhbGxDbGlwcy5sZW5ndGg7
IGkrKykgewogICAgICAgICAgICAgICAgICAgICAgICBpZiAoZmF2R3JvdXBPZihhbGxDbGlwc1tpXSkg
IT09IGcpIGNvbnRpbnVlOwogICAgICAgICAgICAgICAgICAgICAgICBpZiAoaSA8IHByZXZMZW4pIGJl
Zm9yZSsrOwogICAgICAgICAgICAgICAgICAgICAgICBlbHNlIGFmdGVyKys7CiAgICAgICAgICAgICAg
ICAgICAgfQogICAgICAgICAgICAgICAgICAgIGlmIChiZWZvcmUgPiAwICYmIGFmdGVyID4gMCkgewog
ICAgICAgICAgICAgICAgICAgICAgICByZW5kZXIoKTsKICAgICAgICAgICAgICAgICAgICAgICAgcmV0
dXJuIGZhbHNlOwogICAgICAgICAgICAgICAgICAgIH0KICAgICAgICAgICAgICAgIH0KICAgICAgICAg
ICAgfQogICAgICAgIH0KICAgICAgICBjb25zdCBibG9ja3MgPSBidWlsZFBpbm5lZEJsb2Nrcyh2aXNp
YmxlKTsKICAgICAgICBjb25zdCBleGlzdGluZyA9IGxpc3RFbC5xdWVyeVNlbGVjdG9yQWxsKCcuaXRt
JykubGVuZ3RoOwogICAgICAgIGlmIChleGlzdGluZyA8IDEpIHsKICAgICAgICAgICAgcmVuZGVyKCk7
CiAgICAgICAgICAgIHJldHVybiBmYWxzZTsKICAgICAgICB9CiAgICAgICAgaWYgKGJsb2Nrcy5sZW5n
dGggPD0gZXhpc3RpbmcpIHsKICAgICAgICAgICAgcmVmcmVzaExpc3RDaHJvbWUoKTsKICAgICAgICAg
ICAgdHJ5IHsgbWFya1F1ZXVlUmFpbHMoKTsgfSBjYXRjaCAoZSkge30KICAgICAgICAgICAgcmV0dXJu
IHRydWU7CiAgICAgICAgfQogICAgICAgIGNvbnN0IGZyYWcgPSBkb2N1bWVudC5jcmVhdGVEb2N1bWVu
dEZyYWdtZW50KCk7CiAgICAgICAgbGV0IG51bSA9IDA7CiAgICAgICAgYmxvY2tzLmZvckVhY2goYiA9
PiB7CiAgICAgICAgICAgIG51bSArPSAxOwogICAgICAgICAgICBpZiAobnVtIDw9IGV4aXN0aW5nKSBy
ZXR1cm47CiAgICAgICAgICAgIGlmIChiLmtpbmQgPT09ICdncm91cCcgJiYgYi5pdGVtcy5sZW5ndGgg
PiAxKQogICAgICAgICAgICAgICAgZnJhZy5hcHBlbmRDaGlsZChtYWtlR3JvdXBJdGVtKGIuaXRlbXMs
IG51bSkpOwogICAgICAgICAgICBlbHNlCiAgICAgICAgICAgICAgICBmcmFnLmFwcGVuZENoaWxkKG1h
a2VJdGVtKGIuaXRlbXNbMF0sIG51bSkpOwogICAgICAgIH0pOwogICAgICAgIGNvbnN0IG1vcmVFbCA9
IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdsaXN0LW1vcmUnKTsKICAgICAgICBpZiAobW9yZUVsKQog
ICAgICAgICAgICBsaXN0RWwuaW5zZXJ0QmVmb3JlKGZyYWcsIG1vcmVFbCk7CiAgICAgICAgZWxzZQog
ICAgICAgICAgICBsaXN0RWwuYXBwZW5kQ2hpbGQoZnJhZyk7CiAgICAgICAgdHJ5IHsgbWFya1F1ZXVl
UmFpbHMoKTsgfSBjYXRjaCAoZSkge30KICAgICAgICByZWZyZXNoTGlzdENocm9tZSgpOwogICAgICAg
IHJlcXVlc3RBbmltYXRpb25GcmFtZSgoKSA9PiB7CiAgICAgICAgICAgIGlmIChhbGxDbGlwcy5sZW5n
dGggPCBkaXNrVG90YWwKICAgICAgICAgICAgICAgICYmIGxpc3RFbC5zY3JvbGxIZWlnaHQgPD0gbGlz
dEVsLmNsaWVudEhlaWdodCArIDIwKQogICAgICAgICAgICAgICAgcmVxdWVzdE1vcmUoKTsKICAgICAg
ICAgICAgdHJ5IHsgc2NoZWR1bGVGaWxlR29uZUNoZWNrKCk7IH0gY2F0Y2gge30KICAgICAgICB9KTsK
ICAgICAgICByZXR1cm4gdHJ1ZTsKICAgIH0KCiAgICBmdW5jdGlvbiBhcHBseUFwcGVuZFBheWxvYWQo
cGVuZGluZykgewogICAgICAgIGlmICghcGVuZGluZyB8fCBwZW5kaW5nLmZyb21MZW4gPT0gbnVsbCkg
cmV0dXJuOwogICAgICAgIGNvbnN0IGZyb21MZW4gPSBOdW1iZXIocGVuZGluZy5mcm9tTGVuKSB8fCAw
OwogICAgICAgIGlmIChmcm9tTGVuIDwgMCB8fCBhbGxDbGlwcy5sZW5ndGggPD0gZnJvbUxlbikgewog
ICAgICAgICAgICByZWZyZXNoTGlzdENocm9tZSgpOwogICAgICAgICAgICByZXR1cm47CiAgICAgICAg
fQogICAgICAgIGFwcGVuZFJlbmRlcihmcm9tTGVuKTsKICAgIH0KCiAgICBmdW5jdGlvbiBuYXZMaXN0
KCkgewogICAgICAgIGNvbnN0IGJsb2NrcyA9IGJ1aWxkUGlubmVkQmxvY2tzKHZpc2libGVMaXN0KCkp
OwogICAgICAgIGNvbnN0IG91dCA9IFtdOwogICAgICAgIGZvciAoY29uc3QgYiBvZiBibG9ja3MpIHsK
ICAgICAgICAgICAgaWYgKCFiIHx8ICFiLml0ZW1zKSBjb250aW51ZTsKICAgICAgICAgICAgZm9yIChj
b25zdCBjIG9mIGIuaXRlbXMpIG91dC5wdXNoKGMpOwogICAgICAgIH0KICAgICAgICByZXR1cm4gb3V0
OwogICAgfQoKICAgIGZ1bmN0aW9uIHNlbGVjdEJ5SW5kZXgoaWR4KSB7CiAgICAgICAgY29uc3Qgdmlz
ID0gbmF2TGlzdCgpOwogICAgICAgIGlmICghdmlzLmxlbmd0aCkgcmV0dXJuOwogICAgICAgIGlkeCA9
IE1hdGgubWF4KDAsIE1hdGgubWluKHZpcy5sZW5ndGggLSAxLCBpZHgpKTsKICAgICAgICBpZiAoaWR4
ID49IHZpcy5sZW5ndGggLSAxICYmIGFsbENsaXBzLmxlbmd0aCA8IGRpc2tUb3RhbCkKICAgICAgICAg
ICAgcmVxdWVzdE1vcmUoKTsKICAgICAgICBzZWxlY3RlZElkID0gdmlzW01hdGgubWluKGlkeCwgdmlz
Lmxlbmd0aCAtIDEpXS5pZDsKICAgICAgICByYW5nZUFuY2hvcklkID0gc2VsZWN0ZWRJZDsKICAgICAg
ICByYW5nZUFuY2hvckNsaWNrZWQgPSBmYWxzZTsKICAgICAgICBpZiAoK3NlbGVjdGVkSWQgIT09ICts
YXN0UGFzdGVJZCkKICAgICAgICAgICAgbG9jYXRlQWN0aXZlID0gZmFsc2U7CiAgICAgICAgdXBkYXRl
TG9jYXRlQnRuKCk7CiAgICAgICAgc3luY0l0ZW1IaWdobGlnaHQoKTsKICAgICAgICBjb25zdCBlbCA9
IGxpc3RFbC5xdWVyeVNlbGVjdG9yKCcubWctcm93W2RhdGEtaWQ9IicgKyBzZWxlY3RlZElkICsgJyJd
JykKICAgICAgICAgICAgfHwgbGlzdEVsLnF1ZXJ5U2VsZWN0b3IoJy5pdG1bZGF0YS1pZD0iJyArIHNl
bGVjdGVkSWQgKyAnIl0nKTsKICAgICAgICBpZiAoZWwpIGVsLnNjcm9sbEludG9WaWV3KHsgYmxvY2s6
ICduZWFyZXN0JyB9KTsKICAgIH0KCiAgICBmdW5jdGlvbiBzZWxlY3RlZEluZGV4KCkgewogICAgICAg
IHJldHVybiBuYXZMaXN0KCkuZmluZEluZGV4KGMgPT4gYy5pZCA9PSBzZWxlY3RlZElkKTsKICAgIH0K
CiAgICBmdW5jdGlvbiBzeW5jSXRlbUhpZ2hsaWdodCgpIHsKICAgICAgICBkb2N1bWVudC5xdWVyeVNl
bGVjdG9yQWxsKCcuaXRtJykuZm9yRWFjaChuID0+IHsKICAgICAgICAgICAgaWYgKG4uY2xhc3NMaXN0
LmNvbnRhaW5zKCdpdC1ncm91cCcpKSB7CiAgICAgICAgICAgICAgICBjb25zdCByb3dzID0gWy4uLm4u
cXVlcnlTZWxlY3RvckFsbCgnLm1nLXJvdycpXTsKICAgICAgICAgICAgICAgIGNvbnN0IGlkcyA9IHJv
d3MubWFwKHIgPT4gK3IuZGF0YXNldC5pZCk7CiAgICAgICAgICAgICAgICBjb25zdCBhbnlTZWwgPSBp
ZHMuaW5jbHVkZXMoK3NlbGVjdGVkSWQpIHx8IGlkcy5zb21lKGlkID0+IG11bHRpSWRzLmluY2x1ZGVz
KGlkKSk7CiAgICAgICAgICAgICAgICBuLmNsYXNzTGlzdC50b2dnbGUoJ3NlbCcsIGFueVNlbCk7CiAg
ICAgICAgICAgICAgICBuLmNsYXNzTGlzdC50b2dnbGUoJ211bHRpJywgaWRzLnNvbWUoaWQgPT4gbXVs
dGlJZHMuaW5jbHVkZXMoaWQpKSk7CiAgICAgICAgICAgICAgICByb3dzLmZvckVhY2gociA9PiB7CiAg
ICAgICAgICAgICAgICAgICAgY29uc3QgaWQgPSArci5kYXRhc2V0LmlkOwogICAgICAgICAgICAgICAg
ICAgIGNvbnN0IGluTXVsdGkgPSBtdWx0aUlkcy5pbmNsdWRlcyhpZCk7CiAgICAgICAgICAgICAgICAg
ICAgci5jbGFzc0xpc3QudG9nZ2xlKCdzZWwnLCBpZCA9PSBzZWxlY3RlZElkIHx8IGluTXVsdGkpOwog
ICAgICAgICAgICAgICAgICAgIHIuY2xhc3NMaXN0LnRvZ2dsZSgnbXVsdGknLCBpbk11bHRpKTsKICAg
ICAgICAgICAgICAgIH0pOwogICAgICAgICAgICAgICAgcmV0dXJuOwogICAgICAgICAgICB9CiAgICAg
ICAgICAgIGNvbnN0IGlkID0gK24uZGF0YXNldC5pZDsKICAgICAgICAgICAgY29uc3QgaW5NdWx0aSA9
IG11bHRpSWRzLmluY2x1ZGVzKGlkKTsKICAgICAgICAgICAgbi5jbGFzc0xpc3QudG9nZ2xlKCdzZWwn
LCBpZCA9PSBzZWxlY3RlZElkIHx8IGluTXVsdGkpOwogICAgICAgICAgICBuLmNsYXNzTGlzdC50b2dn
bGUoJ211bHRpJywgaW5NdWx0aSk7CiAgICAgICAgfSk7CiAgICB9CiAgICBmdW5jdGlvbiB1cGRhdGVN
dWx0aUJhZGdlKCkgewogICAgICAgIGNvbnN0IGJhciA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdt
dWx0aS1iYXInKTsKICAgICAgICBjb25zdCBlbCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdtdWx0
aS1jbnQnKTsKICAgICAgICBpZiAobXVsdGlJZHMubGVuZ3RoID4gMCkgewogICAgICAgICAgICBpZiAo
ZWwpIGVsLnRleHRDb250ZW50ID0gU3RyaW5nKG11bHRpSWRzLmxlbmd0aCk7CiAgICAgICAgICAgIGlm
IChiYXIpIHsKICAgICAgICAgICAgICAgIGNvbnN0IHdhc09mZiA9ICFiYXIuY2xhc3NMaXN0LmNvbnRh
aW5zKCdvbicpOwogICAgICAgICAgICAgICAgYmFyLmNsYXNzTGlzdC5hZGQoJ29uJyk7CiAgICAgICAg
ICAgICAgICBpZiAod2FzT2ZmKSByZXNldFBhc3RlU2VwRGVmYXVsdCgpOwogICAgICAgICAgICB9CiAg
ICAgICAgfSBlbHNlIHsKICAgICAgICAgICAgaWYgKGJhcikgYmFyLmNsYXNzTGlzdC5yZW1vdmUoJ29u
Jyk7CiAgICAgICAgICAgIGNsb3NlU2VwTWVudSgpOwogICAgICAgIH0KICAgICAgICBzeW5jSXRlbUhp
Z2hsaWdodCgpOwogICAgfQoKICAgIGNvbnN0IFNFUF9ORVdMSU5FX1RPS0VOID0gJ1vmjaLooYxdJzsK
ICAgIC8vIOWbuuWumuW4uOeUqOWIhumalOespu+8m+iHquWumuS5ieS4jei/m+WIl+ihqAogICAgY29u
c3QgU0VQX0xJU1QgPSBbJyAnLCBTRVBfTkVXTElORV9UT0tFTiwgJywnLCAnLCAnLCAn44CBJywgJ3wn
LCAnWyIiLCIiXScsICIoJycsJycpIl07CiAgICBsZXQgcGFzdGVTZXBWYWx1ZSA9ICcgJzsKCiAgICBm
dW5jdGlvbiBub3JtYWxpemVTZXBJbnB1dChyYXcpIHsKICAgICAgICBsZXQgcyA9IFN0cmluZyhyYXcg
Pz8gJycpOwogICAgICAgIGlmIChzID09PSAnJykgcmV0dXJuICcgJzsKICAgICAgICBjb25zdCB0ID0g
cy50cmltKCk7CiAgICAgICAgaWYgKHQgPT09IFNFUF9ORVdMSU5FX1RPS0VOIHx8IHQgPT09ICfmjaLo
oYwnIHx8IHQgPT09ICdcXG4nIHx8IHQgPT09ICdcbicgfHwgdCA9PT0gJ1xyXG4nKQogICAgICAgICAg
ICByZXR1cm4gU0VQX05FV0xJTkVfVE9LRU47CiAgICAgICAgaWYgKHQgPT09ICdcXHQnIHx8IHQgPT09
ICdcdCcpIHJldHVybiAnXHQnOwogICAgICAgIHJldHVybiBzOwogICAgfQogICAgZnVuY3Rpb24gc2Vw
VG9BY3R1YWwocmF3KSB7CiAgICAgICAgY29uc3QgcyA9IG5vcm1hbGl6ZVNlcElucHV0KHJhdyk7CiAg
ICAgICAgcmV0dXJuIHMgPT09IFNFUF9ORVdMSU5FX1RPS0VOID8gJ1xuJyA6IHM7CiAgICB9CiAgICBm
dW5jdGlvbiBzZXBUb0JyaWRnZShyYXcpIHsKICAgICAgICBjb25zdCBzID0gbm9ybWFsaXplU2VwSW5w
dXQocmF3KTsKICAgICAgICBpZiAocyA9PT0gU0VQX05FV0xJTkVfVE9LRU4gfHwgcyA9PT0gJ1xuJyB8
fCBzID09PSAnXHJcbicpIHJldHVybiBTRVBfTkVXTElORV9UT0tFTjsKICAgICAgICBpZiAocyA9PT0g
J1x0JykgcmV0dXJuICdb5Yi26KGo56ymXSc7CiAgICAgICAgcmV0dXJuIHM7CiAgICB9CiAgICBmdW5j
dGlvbiBzZXBEaXNwbGF5U3ltYm9sKHJhdykgewogICAgICAgIGNvbnN0IHMgPSBub3JtYWxpemVTZXBJ
bnB1dChyYXcpOwogICAgICAgIGlmIChzID09PSAnICcpIHJldHVybiAn4pCjJzsKICAgICAgICBpZiAo
cyA9PT0gU0VQX05FV0xJTkVfVE9LRU4gfHwgcyA9PT0gJ1xuJyB8fCBzID09PSAnXHJcbicpIHJldHVy
biAn4oa1JzsKICAgICAgICBpZiAocyA9PT0gJ1x0JykgcmV0dXJuICfih6UnOwogICAgICAgIGlmIChz
ID09PSAnLCcpIHJldHVybiAnLCc7CiAgICAgICAgaWYgKHMgPT09ICcsICcpIHJldHVybiAnLOKQoyc7
CiAgICAgICAgaWYgKHMgPT09ICfjgIEnKSByZXR1cm4gJ+OAgSc7CiAgICAgICAgaWYgKHMgPT09ICd8
JykgcmV0dXJuICd8JzsKICAgICAgICBpZiAocyA9PT0gJ1siIiwiIl0nKSByZXR1cm4gJ1siIiwiIl0n
OwogICAgICAgIGlmIChzID09PSAiKCcnLCcnKSIpIHJldHVybiAiKCcnLCcnKSI7CiAgICAgICAgcmV0
dXJuIHMucmVwbGFjZSgvXHJcbi9nLCAn4oa1JykucmVwbGFjZSgvXG4vZywgJ+KGtScpLnJlcGxhY2Uo
L1x0L2csICfih6UnKS5yZXBsYWNlKC9cci9nLCAnJyk7CiAgICB9CiAgICBmdW5jdGlvbiBzZXBEaXNw
bGF5TmFtZShyYXcpIHsKICAgICAgICBjb25zdCBzID0gbm9ybWFsaXplU2VwSW5wdXQocmF3KTsKICAg
ICAgICBpZiAocyA9PT0gJyAnKSByZXR1cm4gJ+epuuagvCc7CiAgICAgICAgaWYgKHMgPT09IFNFUF9O
RVdMSU5FX1RPS0VOIHx8IHMgPT09ICdcbicgfHwgcyA9PT0gJ1xyXG4nKSByZXR1cm4gJ+aNouihjCc7
CiAgICAgICAgaWYgKHMgPT09ICdcdCcpIHJldHVybiAn5Yi26KGo56ymJzsKICAgICAgICBpZiAocyA9
PT0gJywnKSByZXR1cm4gJ+mAl+WPtyc7CiAgICAgICAgaWYgKHMgPT09ICcsICcpIHJldHVybiAn6YCX
5Y+356m65qC8JzsKICAgICAgICBpZiAocyA9PT0gJ+OAgScpIHJldHVybiAn6aG/5Y+3JzsKICAgICAg
ICBpZiAocyA9PT0gJ3wnKSByZXR1cm4gJ+erlue6vyc7CiAgICAgICAgaWYgKHMgPT09ICdbIiIsIiJd
JykgcmV0dXJuICfliJfooagxJzsKICAgICAgICBpZiAocyA9PT0gIignJywnJykiKSByZXR1cm4gJ+WI
l+ihqDInOwogICAgICAgIHJldHVybiAnJzsKICAgIH0KICAgIGZ1bmN0aW9uIGZpbGxTZXBNZW51SXRl
bShidG4sIHYpIHsKICAgICAgICBidG4uaW5uZXJIVE1MID0gJyc7CiAgICAgICAgY29uc3Qgc3ltID0g
ZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnc3BhbicpOwogICAgICAgIHN5bS5jbGFzc05hbWUgPSAncGFz
dGUtc2VwLXN5bScgKyAoc2VwRGlzcGxheU5hbWUodikgPyAnJyA6ICcgb25seScpOwogICAgICAgIHN5
bS50ZXh0Q29udGVudCA9IHNlcERpc3BsYXlTeW1ib2wodik7CiAgICAgICAgYnRuLmFwcGVuZENoaWxk
KHN5bSk7CiAgICAgICAgY29uc3QgbmFtZSA9IHNlcERpc3BsYXlOYW1lKHYpOwogICAgICAgIGlmIChu
YW1lKSB7CiAgICAgICAgICAgIGNvbnN0IGxhYiA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ3NwYW4n
KTsKICAgICAgICAgICAgbGFiLmNsYXNzTmFtZSA9ICdwYXN0ZS1zZXAtbmFtZSc7CiAgICAgICAgICAg
IGxhYi50ZXh0Q29udGVudCA9IG5hbWU7CiAgICAgICAgICAgIGJ0bi5hcHBlbmRDaGlsZChsYWIpOwog
ICAgICAgIH0KICAgIH0KICAgIGZ1bmN0aW9uIHVwZGF0ZVNlcExhYmVsKCkgewogICAgICAgIGNvbnN0
IGxhYiA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdwYXN0ZS1zZXAtbGFiZWwnKTsKICAgICAgICBp
ZiAobGFiKSBsYWIudGV4dENvbnRlbnQgPSBzZXBEaXNwbGF5U3ltYm9sKHBhc3RlU2VwVmFsdWUpOwog
ICAgfQogICAgZnVuY3Rpb24gYXBwbHlTZXBhcmF0b3IocmF3LCBvcHRzID0ge30pIHsKICAgICAgICBj
b25zdCBkb1Bhc3RlID0gb3B0cy5wYXN0ZSAhPSBudWxsID8gb3B0cy5wYXN0ZSA6IG11bHRpSWRzLmxl
bmd0aCA+IDA7CiAgICAgICAgcGFzdGVTZXBWYWx1ZSA9IG5vcm1hbGl6ZVNlcElucHV0KHJhdyk7CiAg
ICAgICAgdXBkYXRlU2VwTGFiZWwoKTsKICAgICAgICBjbG9zZVNlcE1lbnUoKTsKICAgICAgICBpZiAo
ZG9QYXN0ZSkgcGFzdGVNdWx0aVNlbGVjdGlvbigpOwogICAgfQogICAgZnVuY3Rpb24gY2xvc2VTZXBN
ZW51KCkgewogICAgICAgIGNvbnN0IG1lbnUgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgncGFzdGUt
c2VwLW1lbnUnKTsKICAgICAgICBjb25zdCBidG4gPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgncGFz
dGUtc2VwLWJ0bicpOwogICAgICAgIGlmIChtZW51KSBtZW51LmNsYXNzTGlzdC5yZW1vdmUoJ29uJyk7
CiAgICAgICAgaWYgKGJ0bikgYnRuLmNsYXNzTGlzdC5yZW1vdmUoJ29wZW4nKTsKICAgIH0KICAgIGZ1
bmN0aW9uIHJlbmRlclNlcE1lbnUoKSB7CiAgICAgICAgY29uc3QgbWVudSA9IGRvY3VtZW50LmdldEVs
ZW1lbnRCeUlkKCdwYXN0ZS1zZXAtbWVudScpOwogICAgICAgIGlmICghbWVudSkgcmV0dXJuOwogICAg
ICAgIG1lbnUuaW5uZXJIVE1MID0gJyc7CiAgICAgICAgZm9yIChjb25zdCB2IG9mIFNFUF9MSVNUKSB7
CiAgICAgICAgICAgIGNvbnN0IGIgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdidXR0b24nKTsKICAg
ICAgICAgICAgYi50eXBlID0gJ2J1dHRvbic7CiAgICAgICAgICAgIGIuY2xhc3NOYW1lID0gJ3Bhc3Rl
LXNlcC1pdGVtJyArICh2ID09PSBwYXN0ZVNlcFZhbHVlID8gJyBzZWwnIDogJycpOwogICAgICAgICAg
ICBmaWxsU2VwTWVudUl0ZW0oYiwgdik7CiAgICAgICAgICAgIGIub25jbGljayA9IGUgPT4gewogICAg
ICAgICAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICAgICAgICAgIGFwcGx5U2VwYXJh
dG9yKHYpOwogICAgICAgICAgICB9OwogICAgICAgICAgICBtZW51LmFwcGVuZENoaWxkKGIpOwogICAg
ICAgIH0KICAgICAgICBjb25zdCBmb290ID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnZGl2Jyk7CiAg
ICAgICAgZm9vdC5jbGFzc05hbWUgPSAncGFzdGUtc2VwLWZvb3QnOwogICAgICAgIGNvbnN0IGlucCA9
IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2lucHV0Jyk7CiAgICAgICAgaW5wLmlkID0gJ3Bhc3RlLXNl
cC1jdXN0b20nOwogICAgICAgIGlucC50eXBlID0gJ3RleHQnOwogICAgICAgIGlucC5zaXplID0gMTsK
ICAgICAgICBpbnAucGxhY2Vob2xkZXIgPSAn6Ieq5a6a5LmJJzsKICAgICAgICBpbnAuYXV0b2NvbXBs
ZXRlID0gJ29mZic7CiAgICAgICAgaW5wLnNwZWxsY2hlY2sgPSBmYWxzZTsKICAgICAgICBpbnAudmFs
dWUgPSBTRVBfTElTVC5pbmNsdWRlcyhwYXN0ZVNlcFZhbHVlKSA/ICcnIDogcGFzdGVTZXBWYWx1ZTsK
ICAgICAgICBpbnAub25tb3VzZWRvd24gPSBlID0+IHsKICAgICAgICAgICAgZS5zdG9wUHJvcGFnYXRp
b24oKTsKICAgICAgICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOwogICAgICAgICAgICB0cnkgeyBhaGso
J2ZvY3VzUGFuZWwnKTsgfSBjYXRjaCB7fQogICAgICAgICAgICBpbnAuZm9jdXMoKTsKICAgICAgICB9
OwogICAgICAgIGlucC5vbmNsaWNrID0gZSA9PiBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgICAgIGlu
cC5vbmZvY3VzID0gKCkgPT4geyB0cnkgeyBhaGsoJ2ZvY3VzUGFuZWwnKTsgfSBjYXRjaCB7fSB9Owog
ICAgICAgIGlucC5vbmlucHV0ID0gZSA9PiBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgICAgIGlucC5v
bmtleWRvd24gPSBlID0+IHsKICAgICAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICAg
ICAgaWYgKGUua2V5ID09PSAnRW50ZXInKSB7CiAgICAgICAgICAgICAgICBlLnByZXZlbnREZWZhdWx0
KCk7CiAgICAgICAgICAgICAgICBpZiAoaW5wLnZhbHVlICE9PSAnJykgYXBwbHlTZXBhcmF0b3IoaW5w
LnZhbHVlKTsKICAgICAgICAgICAgICAgIGVsc2UgY2xvc2VTZXBNZW51KCk7CiAgICAgICAgICAgIH0g
ZWxzZSBpZiAoZS5rZXkgPT09ICdFc2NhcGUnKSB7CiAgICAgICAgICAgICAgICBlLnByZXZlbnREZWZh
dWx0KCk7CiAgICAgICAgICAgICAgICBjbG9zZVNlcE1lbnUoKTsKICAgICAgICAgICAgfQogICAgICAg
IH07CiAgICAgICAgZm9vdC5hcHBlbmRDaGlsZChpbnApOwogICAgICAgIG1lbnUuYXBwZW5kQ2hpbGQo
Zm9vdCk7CiAgICB9CiAgICBmdW5jdGlvbiByZXNldFBhc3RlU2VwRGVmYXVsdCgpIHsKICAgICAgICBw
YXN0ZVNlcFZhbHVlID0gJyAnOwogICAgICAgIHVwZGF0ZVNlcExhYmVsKCk7CiAgICAgICAgY2xvc2VT
ZXBNZW51KCk7CiAgICB9CiAgICBmdW5jdGlvbiBwYXN0ZU1hbnlXaXRoU2VwKGlkcykgewogICAgICAg
IGFoaygncGFzdGVNYW55JywgaWRzLmpvaW4oJywnKSwgc2VwVG9CcmlkZ2UocGFzdGVTZXBWYWx1ZSkp
OwogICAgfQogICAgZnVuY3Rpb24gcGFzdGVNdWx0aVNlbGVjdGlvbigpIHsKICAgICAgICBpZiAoIW11
bHRpSWRzLmxlbmd0aCkgcmV0dXJuOwogICAgICAgIGNvbnN0IGlkcyA9IG11bHRpSWRzLnNsaWNlKCk7
CiAgICAgICAgY2xlYXJNdWx0aSgpOwogICAgICAgIGlmIChpZHMuc29tZShpZCA9PiB7CiAgICAgICAg
ICAgIGNvbnN0IGl0ID0gYWxsQ2xpcHMuZmluZCh4ID0+ICt4LmlkID09PSAraWQpOwogICAgICAgICAg
ICByZXR1cm4gaXQgJiYgbm9ybVR5cGUoaXQudHlwZSkgPT09ICdyZWNlbnQnOwogICAgICAgIH0pKSB7
CiAgICAgICAgICAgIGNvbnN0IGZpcnN0ID0gYWxsQ2xpcHMuZmluZCh4ID0+ICt4LmlkID09PSAraWRz
WzBdKTsKICAgICAgICAgICAgaWYgKGZpcnN0KSBhY3RpdmF0ZUNsaXBJdGVtKGZpcnN0KTsKICAgICAg
ICAgICAgcmV0dXJuOwogICAgICAgIH0KICAgICAgICBtYXJrUGFzdGVkTG9jYWwoaWRzKTsKICAgICAg
ICBwYXN0ZU1hbnlXaXRoU2VwKGlkcyk7CiAgICB9CiAgICBmdW5jdGlvbiBpbml0U2VwVWkoKSB7CiAg
ICAgICAgdXBkYXRlU2VwTGFiZWwoKTsKICAgICAgICBjb25zdCBidG4gPSBkb2N1bWVudC5nZXRFbGVt
ZW50QnlJZCgncGFzdGUtc2VwLWJ0bicpOwogICAgICAgIGlmIChidG4pIHsKICAgICAgICAgICAgYnRu
LmFkZEV2ZW50TGlzdGVuZXIoJ2NsaWNrJywgZSA9PiB7CiAgICAgICAgICAgICAgICBlLnN0b3BQcm9w
YWdhdGlvbigpOwogICAgICAgICAgICAgICAgY29uc3QgbWVudSA9IGRvY3VtZW50LmdldEVsZW1lbnRC
eUlkKCdwYXN0ZS1zZXAtbWVudScpOwogICAgICAgICAgICAgICAgY29uc3Qgb3BlbiA9IG1lbnUgJiYg
bWVudS5jbGFzc0xpc3QuY29udGFpbnMoJ29uJyk7CiAgICAgICAgICAgICAgICBpZiAob3Blbikgewog
ICAgICAgICAgICAgICAgICAgIGNvbnN0IGlucCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdwYXN0
ZS1zZXAtY3VzdG9tJyk7CiAgICAgICAgICAgICAgICAgICAgaWYgKGlucCAmJiBpbnAudmFsdWUgIT09
ICcnKSBhcHBseVNlcGFyYXRvcihpbnAudmFsdWUsIHsgcGFzdGU6IG11bHRpSWRzLmxlbmd0aCA+IDAg
fSk7CiAgICAgICAgICAgICAgICAgICAgZWxzZSBjbG9zZVNlcE1lbnUoKTsKICAgICAgICAgICAgICAg
ICAgICByZXR1cm47CiAgICAgICAgICAgICAgICB9CiAgICAgICAgICAgICAgICByZW5kZXJTZXBNZW51
KCk7CiAgICAgICAgICAgICAgICBtZW51LmNsYXNzTGlzdC5hZGQoJ29uJyk7CiAgICAgICAgICAgICAg
ICBidG4uY2xhc3NMaXN0LmFkZCgnb3BlbicpOwogICAgICAgICAgICB9KTsKICAgICAgICB9CiAgICAg
ICAgZG9jdW1lbnQuYWRkRXZlbnRMaXN0ZW5lcignbW91c2Vkb3duJywgZSA9PiB7CiAgICAgICAgICAg
IGlmIChlLnRhcmdldC5jbG9zZXN0KCcjcGFzdGUtc2VwLXdyYXAnKSkgcmV0dXJuOwogICAgICAgICAg
ICBjb25zdCBtZW51ID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3Bhc3RlLXNlcC1tZW51Jyk7CiAg
ICAgICAgICAgIGlmICghbWVudSB8fCAhbWVudS5jbGFzc0xpc3QuY29udGFpbnMoJ29uJykpIHJldHVy
bjsKICAgICAgICAgICAgY29uc3QgaW5wID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3Bhc3RlLXNl
cC1jdXN0b20nKTsKICAgICAgICAgICAgaWYgKGlucCAmJiBpbnAudmFsdWUgIT09ICcnKSB7CiAgICAg
ICAgICAgICAgICBhcHBseVNlcGFyYXRvcihpbnAudmFsdWUpOwogICAgICAgICAgICAgICAgcmV0dXJu
OwogICAgICAgICAgICB9CiAgICAgICAgICAgIGNsb3NlU2VwTWVudSgpOwogICAgICAgIH0sIHRydWUp
OwogICAgfQoKICAgIGZ1bmN0aW9uIGNsZWFyTXVsdGkocmVzdG9yZVRvQW5jaG9yKSB7CiAgICAgICAg
Y29uc3QgYmFja0lkID0gK3JhbmdlQW5jaG9ySWQgfHwgMDsKICAgICAgICBtdWx0aUlkcyA9IFtdOwog
ICAgICAgIGlmIChyZXN0b3JlVG9BbmNob3IgJiYgYmFja0lkKQogICAgICAgICAgICBzZWxlY3RlZElk
ID0gYmFja0lkOwogICAgICAgIHJhbmdlQW5jaG9ySWQgPSBzZWxlY3RlZElkIHx8IDA7CiAgICAgICAg
cmFuZ2VBbmNob3JDbGlja2VkID0gZmFsc2U7CiAgICAgICAgdXBkYXRlTXVsdGlCYWRnZSgpOwogICAg
ICAgIGlmIChyZXN0b3JlVG9BbmNob3IgJiYgc2VsZWN0ZWRJZCkgewogICAgICAgICAgICBjb25zdCBl
bCA9IGxpc3RFbC5xdWVyeVNlbGVjdG9yKCcubWctcm93W2RhdGEtaWQ9IicgKyBzZWxlY3RlZElkICsg
JyJdJykKICAgICAgICAgICAgICAgIHx8IGxpc3RFbC5xdWVyeVNlbGVjdG9yKCcuaXRtW2RhdGEtaWQ9
IicgKyBzZWxlY3RlZElkICsgJyJdJyk7CiAgICAgICAgICAgIGlmIChlbCkgZWwuc2Nyb2xsSW50b1Zp
ZXcoeyBibG9jazogJ25lYXJlc3QnIH0pOwogICAgICAgIH0KICAgIH0KCgogICAgLyogc2hpZnQvY3Ry
bCBtdWx0aS1zZWxlY3Q6CiAgICAgKiBTaGlmdO+8muaciemAieWMuuaXtuS7peOAjOacgOS4ii/mnIDk
uIvjgI3kuLrplJrvvIzkuI3ot5/pvKDmoIfkuIrmrKHngrnlh7votbAKICAgICAqICAgLSDngrnlnKjp
gInljLrkuIvmlrkg4oaSIOS7juS4iumAieWIsOW9k+WJjQogICAgICogICAtIOeCueWcqOmAieWMuuS4
iuaWuSDihpIg5LuO5b2T5YmN5Yiw5LiL6YCJCiAgICAgKiAgIC0g54K55Zyo6YCJ5Yy66Leo5bqm5YaF
IOKGkiDloavmu6HmnIDkuIrliLDmnIDkuIvvvIjlkKvpnZ7ov57nu63nqbrmtJ7vvIkKICAgICAqIEN0
cmzvvJrpppbmrKHngrnku7vmhI/pobnvvIjlkKvpu5jorqTpq5jkuq7vvInov5vlhaXlpJrpgInlubbp
gInkuK3vvJvlho3ngrnlt7LpgInpobnlj5bmtojjgIHmnKrpgInpobnliqDlhaUKICAgICAqLwogICAg
bGV0IHJhbmdlQW5jaG9ySWQgPSAwOwogICAgbGV0IHJhbmdlQW5jaG9yQ2xpY2tlZCA9IGZhbHNlOwog
ICAgZnVuY3Rpb24gc2VsZWN0ZWRJbmRpY2VzSW5MaXN0KGxpc3QpIHsKICAgICAgICBjb25zdCBzZXQg
PSBuZXcgU2V0KChtdWx0aUlkcyB8fCBbXSkubWFwKE51bWJlcikuZmlsdGVyKEJvb2xlYW4pKTsKICAg
ICAgICBpZiAoK3NlbGVjdGVkSWQpIHNldC5hZGQoK3NlbGVjdGVkSWQpOwogICAgICAgIGNvbnN0IGlk
eHMgPSBbXTsKICAgICAgICBsaXN0LmZvckVhY2goKGMsIGkpID0+IHsKICAgICAgICAgICAgaWYgKHNl
dC5oYXMoK2MuaWQpKSBpZHhzLnB1c2goaSk7CiAgICAgICAgfSk7CiAgICAgICAgcmV0dXJuIGlkeHM7
CiAgICB9CiAgICBmdW5jdGlvbiBzZWxlY3RSYW5nZVRvKGlkKSB7CiAgICAgICAgaWQgPSAraWQ7CiAg
ICAgICAgY29uc3QgbGlzdCA9ICh0eXBlb2YgbmF2TGlzdCA9PT0gJ2Z1bmN0aW9uJyA/IG5hdkxpc3Qo
KSA6IHZpc2libGVMaXN0KCkpOwogICAgICAgIGNvbnN0IGIgPSBsaXN0LmZpbmRJbmRleChjID0+ICtj
LmlkID09PSBpZCk7CiAgICAgICAgaWYgKGIgPCAwKSByZXR1cm47CiAgICAgICAgY29uc3QgaWR4cyA9
IHNlbGVjdGVkSW5kaWNlc0luTGlzdChsaXN0KTsKICAgICAgICBsZXQgbG8sIGhpOwogICAgICAgIGlm
ICghaWR4cy5sZW5ndGgpIHsKICAgICAgICAgICAgbG8gPSBoaSA9IGI7CiAgICAgICAgfSBlbHNlIHsK
ICAgICAgICAgICAgY29uc3QgdG9wID0gTWF0aC5taW4oLi4uaWR4cyk7CiAgICAgICAgICAgIGNvbnN0
IGJvdCA9IE1hdGgubWF4KC4uLmlkeHMpOwogICAgICAgICAgICBpZiAoYiA+IGJvdCkgewogICAgICAg
ICAgICAgICAgLy8g6YCJ5Yy65LiL5pa577ya5pyA5LiKIOKGkiDlvZPliY0KICAgICAgICAgICAgICAg
IGxvID0gdG9wOwogICAgICAgICAgICAgICAgaGkgPSBiOwogICAgICAgICAgICB9IGVsc2UgaWYgKGIg
PCB0b3ApIHsKICAgICAgICAgICAgICAgIC8vIOmAieWMuuS4iuaWue+8muW9k+WJjSDihpIg5pyA5LiL
CiAgICAgICAgICAgICAgICBsbyA9IGI7CiAgICAgICAgICAgICAgICBoaSA9IGJvdDsKICAgICAgICAg
ICAgfSBlbHNlIHsKICAgICAgICAgICAgICAgIC8vIOWcqOi3qOW6puWGhe+8iOWQq+mdnui/nue7reep
uua0nu+8ie+8muaVtOauteacgOS4iuKGkuacgOS4iwogICAgICAgICAgICAgICAgbG8gPSB0b3A7CiAg
ICAgICAgICAgICAgICBoaSA9IGJvdDsKICAgICAgICAgICAgfQogICAgICAgIH0KICAgICAgICBtdWx0
aUlkcyA9IFtdOwogICAgICAgIGZvciAobGV0IGkgPSBsbzsgaSA8PSBoaTsgaSsrKQogICAgICAgICAg
ICBtdWx0aUlkcy5wdXNoKCtsaXN0W2ldLmlkKTsKICAgICAgICBzZWxlY3RlZElkID0gaWQ7CiAgICAg
ICAgLy8g5LiN5YaN5oqK6byg5qCH54K55Ye75b2T5oiQ5LiL5LiA5qyhIFNoaWZ0IOmUmueCuQogICAg
ICAgIHJhbmdlQW5jaG9ySWQgPSArbGlzdFtsb10uaWQ7CiAgICAgICAgcmFuZ2VBbmNob3JDbGlja2Vk
ID0gdHJ1ZTsKICAgICAgICB1cGRhdGVNdWx0aUJhZGdlKCk7CiAgICAgICAgY29uc3QgZWwgPSBsaXN0
RWwucXVlcnlTZWxlY3RvcignLm1nLXJvd1tkYXRhLWlkPSInICsgc2VsZWN0ZWRJZCArICciXScpCiAg
ICAgICAgICAgIHx8IGxpc3RFbC5xdWVyeVNlbGVjdG9yKCcuaXRtW2RhdGEtaWQ9IicgKyBzZWxlY3Rl
ZElkICsgJyJdJyk7CiAgICAgICAgaWYgKGVsKSBlbC5zY3JvbGxJbnRvVmlldyh7IGJsb2NrOiAnbmVh
cmVzdCcgfSk7CiAgICB9CiAgICBmdW5jdGlvbiBoYW5kbGVJdGVtQ2xpY2soZSwgYykgewogICAgICAg
IGlmIChlLnNoaWZ0S2V5KSB7CiAgICAgICAgICAgIGUucHJldmVudERlZmF1bHQoKTsgZS5zdG9wUHJv
cGFnYXRpb24oKTsKICAgICAgICAgICAgc2VsZWN0UmFuZ2VUbyhjLmlkKTsKICAgICAgICAgICAgcmV0
dXJuIHRydWU7CiAgICAgICAgfQogICAgICAgIGlmIChlLmN0cmxLZXkgfHwgZS5tZXRhS2V5KSB7CiAg
ICAgICAgICAgIGUucHJldmVudERlZmF1bHQoKTsgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICAg
ICAgdG9nZ2xlTXVsdGkoYy5pZCk7CiAgICAgICAgICAgIHJldHVybiB0cnVlOwogICAgICAgIH0KICAg
ICAgICByYW5nZUFuY2hvcklkID0gYy5pZDsKICAgICAgICByYW5nZUFuY2hvckNsaWNrZWQgPSB0cnVl
OwogICAgICAgIHJldHVybiBmYWxzZTsKICAgIH0KICAgIGZ1bmN0aW9uIHRvZ2dsZU11bHRpKGlkKSB7
CiAgICAgICAgaWQgPSAraWQ7CiAgICAgICAgLy8g6aaW5qyhIEN0cmzvvJrlj6rpgInkuK3lvZPliY3n
grnlh7vpobnvvIjlkKvpu5jorqTpq5jkuq7pobkg4oaSIOi/m+WFpeWkmumAie+8jOS4jeimgeWPlua2
iO+8iQogICAgICAgIGlmICghbXVsdGlJZHMubGVuZ3RoKSB7CiAgICAgICAgICAgIG11bHRpSWRzID0g
W2lkXTsKICAgICAgICAgICAgc2VsZWN0ZWRJZCA9IGlkOwogICAgICAgICAgICB1cGRhdGVNdWx0aUJh
ZGdlKCk7CiAgICAgICAgICAgIHJldHVybjsKICAgICAgICB9CiAgICAgICAgY29uc3QgaSA9IG11bHRp
SWRzLmluZGV4T2YoaWQpOwogICAgICAgIGlmIChpID49IDApIHsKICAgICAgICAgICAgbXVsdGlJZHMu
c3BsaWNlKGksIDEpOwogICAgICAgICAgICBpZiAoK3NlbGVjdGVkSWQgPT09IGlkKQogICAgICAgICAg
ICAgICAgc2VsZWN0ZWRJZCA9IG11bHRpSWRzLmxlbmd0aCA/IG11bHRpSWRzW211bHRpSWRzLmxlbmd0
aCAtIDFdIDogMDsKICAgICAgICB9IGVsc2UgewogICAgICAgICAgICBtdWx0aUlkcy5wdXNoKGlkKTsK
ICAgICAgICAgICAgc2VsZWN0ZWRJZCA9IGlkOwogICAgICAgIH0KICAgICAgICB1cGRhdGVNdWx0aUJh
ZGdlKCk7CiAgICB9CiAgICBmdW5jdGlvbiBzaG93U3JjVGlwKGFuY2hvciwgdGV4dCkgewogICAgICAg
IHRleHQgPSBTdHJpbmcodGV4dCB8fCAnJykudHJpbSgpOwogICAgICAgIGlmICghdGV4dCkgcmV0dXJu
OwogICAgICAgIGxldCB0aXAgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3JjLXRpcCcpOwogICAg
ICAgIGlmICghdGlwKSB7CiAgICAgICAgICAgIHRpcCA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2Rp
dicpOwogICAgICAgICAgICB0aXAuaWQgPSAnc3JjLXRpcCc7CiAgICAgICAgICAgIGRvY3VtZW50LmJv
ZHkuYXBwZW5kQ2hpbGQodGlwKTsKICAgICAgICB9CiAgICAgICAgdGlwLnRleHRDb250ZW50ID0gdGV4
dDsKICAgICAgICB0aXAuY2xhc3NMaXN0LmFkZCgnc2hvdycpOwogICAgICAgIGNvbnN0IHIgPSBhbmNo
b3IuZ2V0Qm91bmRpbmdDbGllbnRSZWN0KCk7CiAgICAgICAgY29uc3QgdHcgPSB0aXAub2Zmc2V0V2lk
dGggfHwgMTYwOwogICAgICAgIGNvbnN0IHRoID0gdGlwLm9mZnNldEhlaWdodCB8fCAyODsKICAgICAg
ICBsZXQgbGVmdCA9IHIucmlnaHQgLSB0dzsKICAgICAgICBsZXQgdG9wID0gci50b3AgLSB0aCAtIDg7
CiAgICAgICAgaWYgKGxlZnQgPCA4KSBsZWZ0ID0gODsKICAgICAgICBpZiAobGVmdCArIHR3ID4gd2lu
ZG93LmlubmVyV2lkdGggLSA4KSBsZWZ0ID0gd2luZG93LmlubmVyV2lkdGggLSB0dyAtIDg7CiAgICAg
ICAgaWYgKHRvcCA8IDgpIHRvcCA9IHIuYm90dG9tICsgODsKICAgICAgICB0aXAuc3R5bGUubGVmdCA9
IGxlZnQgKyAncHgnOwogICAgICAgIHRpcC5zdHlsZS50b3AgPSB0b3AgKyAncHgnOwogICAgICAgIGNs
ZWFyVGltZW91dCh0aXAuX2hpZGVUKTsKICAgICAgICB0aXAuX2hpZGVUID0gc2V0VGltZW91dCgoKSA9
PiB0aXAuY2xhc3NMaXN0LnJlbW92ZSgnc2hvdycpLCAyMjAwKTsKICAgIH0KICAgIC8qIGltZy1ob3Zl
ci1wcmV2aWV3LXY4ICovCiAgICBsZXQgX19pbWdIb3ZlclRpbWVyID0gMCwgX19pbWdIb3ZlckhpZGVU
aW1lciA9IDAsIF9faW1nSG92ZXJLZXkgPSAnJzsKICAgIGZ1bmN0aW9uIF9faW1nSG92ZXJFbnN1cmUo
KSB7CiAgICAgICAgbGV0IGJveCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdpbWctaG92ZXItc2lk
ZScpOwogICAgICAgIGlmICghYm94KSB7CiAgICAgICAgICAgIGJveCA9IGRvY3VtZW50LmNyZWF0ZUVs
ZW1lbnQoJ2RpdicpOyBib3guaWQgPSAnaW1nLWhvdmVyLXNpZGUnOwogICAgICAgICAgICBjb25zdCBm
cmFtZSA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOyBmcmFtZS5jbGFzc05hbWUgPSAnaWhw
LWZyYW1lJzsKICAgICAgICAgICAgY29uc3QgaW0gPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdpbWcn
KTsgaW0uYWx0ID0gJyc7CiAgICAgICAgICAgIGZyYW1lLmFwcGVuZENoaWxkKGltKTsgYm94LmFwcGVu
ZENoaWxkKGZyYW1lKTsgZG9jdW1lbnQuYm9keS5hcHBlbmRDaGlsZChib3gpOwogICAgICAgIH0KICAg
ICAgICBsZXQgc3QgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnaW1nLWhvdmVyLXNpZGUtY3NzJyk7
CiAgICAgICAgaWYgKCFzdCkgeyBzdCA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ3N0eWxlJyk7IHN0
LmlkID0gJ2ltZy1ob3Zlci1zaWRlLWNzcyc7IGRvY3VtZW50LmhlYWQuYXBwZW5kQ2hpbGQoc3QpOyB9
CiAgICAgICAgc3QudGV4dENvbnRlbnQgPSAiI2ltZy1ob3Zlci1zaWRle3Bvc2l0aW9uOmZpeGVkO3ot
aW5kZXg6MTAwMDAwO3JpZ2h0OjZweDt0b3A6NTAlO3RyYW5zZm9ybTp0cmFuc2xhdGVZKC01MCUpO3Bv
aW50ZXItZXZlbnRzOm5vbmU7b3BhY2l0eTowO3Zpc2liaWxpdHk6aGlkZGVuO21heC13aWR0aDptaW4o
NjIwcHgsOTJ2dyk7bWF4LWhlaWdodDptaW4oOTJ2aCw5MjBweCl9I2ltZy1ob3Zlci1zaWRlLnNob3d7
b3BhY2l0eToxO3Zpc2liaWxpdHk6dmlzaWJsZX0jaW1nLWhvdmVyLXNpZGUgLmlocC1mcmFtZXtwYWRk
aW5nOjNweDtiYWNrZ3JvdW5kOiNmZmY7Ym9yZGVyOjFweCBzb2xpZCAjQzVDRERDO2JvcmRlci1yYWRp
dXM6MnB4O2JveC1zaGFkb3c6MCA2cHggMThweCByZ2JhKDQ0LDQ2LDU0LC4xMil9I2ltZy1ob3Zlci1z
aWRlIGltZ3tkaXNwbGF5OmJsb2NrO21heC13aWR0aDptaW4oNjEycHgsOTB2dyk7bWF4LWhlaWdodDpt
aW4oOTB2aCw5MDBweCk7d2lkdGg6YXV0bztoZWlnaHQ6YXV0bztvYmplY3QtZml0OmNvbnRhaW47YmFj
a2dyb3VuZDojZmZmfSI7CiAgICAgICAgcmV0dXJuIGJveDsKICAgIH0KICAgIHdpbmRvdy5fX2ltZ0hv
dmVyU2hvdyA9IGZ1bmN0aW9uKGZpbGUsIGlkKSB7CiAgICAgICAgY29uc3QgYmFyZSA9IFN0cmluZyhm
aWxlIHx8ICcnKS5zcGxpdCgvW1xcXFwvXS8pLnBvcCgpOyBpZiAoIWJhcmUpIHJldHVybjsKICAgICAg
ICBjb25zdCBib3ggPSBfX2ltZ0hvdmVyRW5zdXJlKCk7IGNvbnN0IGltZyA9IGJveC5xdWVyeVNlbGVj
dG9yKCdpbWcnKTsgaWYgKCFpbWcpIHJldHVybjsKICAgICAgICBib3guY2xhc3NMaXN0LmFkZCgnc2hv
dycpOwogICAgICAgIGltZy5vbmVycm9yID0gKCkgPT4gewogICAgICAgICAgICBpbWcub25lcnJvciA9
ICgpID0+IHsgaW1nLm9uZXJyb3IgPSBudWxsOyB0cnkgeyBjb25zdCBjID0gdGh1bWJDYWNoZSAmJiB0
aHVtYkNhY2hlLmdldChTdHJpbmcoaWQpKTsgaWYgKGMpIGltZy5zcmMgPSBjOyB9IGNhdGNoIChlKSB7
fSB9OwogICAgICAgICAgICBpbWcuc3JjID0gU1RPUkVfQkFTRSArICd0aF8nICsgYmFyZS5yZXBsYWNl
KC9cLlteLl0rJC8sICcnKSArICcuanBnJzsKICAgICAgICB9OwogICAgICAgIGltZy5vbmxvYWQgPSAo
KSA9PiB7IGltZy5vbmVycm9yID0gbnVsbDsgfTsKICAgICAgICBpbWcuZGF0YXNldC5iYXJlID0gYmFy
ZTsgaW1nLnNyYyA9IFNUT1JFX0JBU0UgKyBiYXJlOwogICAgfTsKICAgIHdpbmRvdy5fX2ltZ0hvdmVy
Q2xlYXJVaSA9IGZ1bmN0aW9uKCkgewogICAgICAgIF9faW1nSG92ZXJLZXkgPSAnJzsKICAgICAgICBp
ZiAoX19pbWdIb3ZlclRpbWVyKSB7IGNsZWFyVGltZW91dChfX2ltZ0hvdmVyVGltZXIpOyBfX2ltZ0hv
dmVyVGltZXIgPSAwOyB9CiAgICAgICAgaWYgKF9faW1nSG92ZXJIaWRlVGltZXIpIHsgY2xlYXJUaW1l
b3V0KF9faW1nSG92ZXJIaWRlVGltZXIpOyBfX2ltZ0hvdmVySGlkZVRpbWVyID0gMDsgfQogICAgICAg
IGNvbnN0IGJveCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdpbWctaG92ZXItc2lkZScpOyBpZiAo
Ym94KSBib3guY2xhc3NMaXN0LnJlbW92ZSgnc2hvdycpOwogICAgICAgIGNvbnN0IGltZyA9IGJveCAm
JiBib3gucXVlcnlTZWxlY3RvcignaW1nJyk7CiAgICAgICAgaWYgKGltZykgeyBpbWcub25sb2FkID0g
bnVsbDsgaW1nLm9uZXJyb3IgPSBudWxsOyBpbWcucmVtb3ZlQXR0cmlidXRlKCdzcmMnKTsgZGVsZXRl
IGltZy5kYXRhc2V0LmJhcmU7IH0KICAgIH07CiAgICB3aW5kb3cuX19pbWdIb3ZlckhpZGUgPSBmdW5j
dGlvbigpIHsgd2luZG93Ll9faW1nSG92ZXJDbGVhclVpKCk7IH07CiAgICBmdW5jdGlvbiBiaW5kSW1n
SG92ZXJQcmV2aWV3KGVsLCBpZCwgZmlsZSkgewogICAgICAgIGlmICghZWwpIHJldHVybjsKICAgICAg
ICBjb25zdCBiYXJlID0gU3RyaW5nKGZpbGUgfHwgJycpLnNwbGl0KC9bXFxcXC9dLykucG9wKCk7IGlm
ICghYmFyZSkgcmV0dXJuOwogICAgICAgIGNvbnN0IGtleSA9IFN0cmluZyhpZCkgKyAnfCcgKyBiYXJl
OwogICAgICAgIGVsLnN0eWxlLmN1cnNvciA9ICd6b29tLWluJzsKICAgICAgICBlbC5hZGRFdmVudExp
c3RlbmVyKCdtb3VzZWVudGVyJywgKCkgPT4gewogICAgICAgICAgICBpZiAoX19pbWdIb3ZlckhpZGVU
aW1lcikgeyBjbGVhclRpbWVvdXQoX19pbWdIb3ZlckhpZGVUaW1lcik7IF9faW1nSG92ZXJIaWRlVGlt
ZXIgPSAwOyB9CiAgICAgICAgICAgIF9faW1nSG92ZXJLZXkgPSBrZXk7CiAgICAgICAgICAgIGlmIChf
X2ltZ0hvdmVyVGltZXIpIGNsZWFyVGltZW91dChfX2ltZ0hvdmVyVGltZXIpOwogICAgICAgICAgICBf
X2ltZ0hvdmVyVGltZXIgPSBzZXRUaW1lb3V0KCgpID0+IHsgaWYgKF9faW1nSG92ZXJLZXkgPT09IGtl
eSkgdHJ5IHsgd2luZG93Ll9faW1nSG92ZXJTaG93KGJhcmUsIGlkKTsgfSBjYXRjaCAoZSkge30gfSwg
NjApOwogICAgICAgIH0pOwogICAgICAgIGVsLmFkZEV2ZW50TGlzdGVuZXIoJ21vdXNlbGVhdmUnLCAo
KSA9PiB7CiAgICAgICAgICAgIGlmIChfX2ltZ0hvdmVyVGltZXIpIHsgY2xlYXJUaW1lb3V0KF9faW1n
SG92ZXJUaW1lcik7IF9faW1nSG92ZXJUaW1lciA9IDA7IH0KICAgICAgICAgICAgX19pbWdIb3Zlckhp
ZGVUaW1lciA9IHNldFRpbWVvdXQoKCkgPT4geyBpZiAoIV9faW1nSG92ZXJLZXkgfHwgX19pbWdIb3Zl
cktleSA9PT0ga2V5KSB3aW5kb3cuX19pbWdIb3ZlckhpZGUoKTsgfSwgNzApOwogICAgICAgIH0pOwog
ICAgfQoKICAgIGZ1bmN0aW9uIHJlbmRlcigpIHsKICAgICAgICBoaWRlUGF0aFRpcCgpOwoKICAgICAg
ICBjb25zdCB2aXNpYmxlID0gdmlzaWJsZUxpc3QoKTsKICAgICAgICBjb25zdCBsb2FkZWQgPSBhbGxD
bGlwcy5sZW5ndGg7CiAgICAgICAgY29uc3Qgc2hvd25Db3VudCA9IHZpc2libGUubGVuZ3RoOwogICAg
ICAgIC8vIOaUtuiXj+inkuagh++8muaUueS4uue7v+eCue+8iOacieacquafpeeci+eahOaWsOaUtuiX
j+aXtuaYvuekuu+8iQogICAgICAgIGxldCBwaW5uZWROID0gTnVtYmVyKHBpbm5lZFRvdGFsKSB8fCAw
OwogICAgICAgIGlmIChwaW5uZWROIDwgMSkgewogICAgICAgICAgICBpZiAoY3VyVGFiID09PSAncGlu
bmVkJykKICAgICAgICAgICAgICAgIHBpbm5lZE4gPSBNYXRoLm1heChOdW1iZXIoZGlza1RvdGFsKSB8
fCAwLCBsb2FkZWQpOwogICAgICAgICAgICBlbHNlCiAgICAgICAgICAgICAgICBwaW5uZWROID0gYWxs
Q2xpcHMuZmlsdGVyKGMgPT4gaXNQaW5uZWQoYykpLmxlbmd0aDsKICAgICAgICB9CiAgICAgICAgdXBk
YXRlUGluRG90KCk7CiAgICAgICAgLy8g5pS26JePIHRhYu+8mmJhciDnlKjmgLvmlbDvvJvmnKrmu6Hp
obXml7bmmL7npLog5bey5Yqg6L29L+aAu+aVsAogICAgICAgIGxldCBzaG93VG90YWwgPSBkaXNrVG90
YWwgPiAwID8gZGlza1RvdGFsIDogKGxvYWRlZCB8fCAwKTsKICAgICAgICBpZiAoY3VyVGFiID09PSAn
cGlubmVkJyAmJiBwaW5uZWROID4gc2hvd1RvdGFsKQogICAgICAgICAgICBzaG93VG90YWwgPSBwaW5u
ZWROOwogICAgICAgIGNvbnN0IHFPbiA9IFN0cmluZyhxdWVyeSB8fCAnJykudHJpbSgpLmxlbmd0aCA+
IDA7CiAgICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2Jhci10eHQnKS50ZXh0Q29udGVudCA9
IHFPbgogICAgICAgICAgICA/IChzaG93bkNvdW50ICsgJyDmnaEnKQogICAgICAgICAgICA6IChzaG93
VG90YWwgPiBsb2FkZWQgPyAoc2hvd25Db3VudCArICcgLyAnICsgc2hvd1RvdGFsICsgJyDmnaEnKSA6
IChzaG93VG90YWwgKyAnIOadoScpKTsKICAgICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnZW1w
dHktdHh0JykudGV4dENvbnRlbnQgPSBFTVBUWV9NU0dbY3VyVGFiXSB8fCBFTVBUWV9NU0cuYWxsOwoK
ICAgICAgICBjb25zdCBpZFNldCA9IG5ldyBTZXQoYWxsQ2xpcHMubWFwKGMgPT4gK2MuaWQpKTsKICAg
ICAgICBtdWx0aUlkcyA9IG11bHRpSWRzLmZpbHRlcihpZCA9PiBpZFNldC5oYXMoaWQpKTsKICAgICAg
ICB1cGRhdGVNdWx0aUJhZGdlKCk7CgogICAgICAgIGNvbnN0IHNob3duID0gdmlzaWJsZTsKCiAgICAg
ICAgbGlzdEVsLnF1ZXJ5U2VsZWN0b3JBbGwoJy5pdG0sICNsaXN0LW1vcmUnKS5mb3JFYWNoKGUgPT4g
ZS5yZW1vdmUoKSk7CiAgICAgICAgLy8g6aqo5p625bey5YWz6Zet77ya5Y2z5L2/IHdhaXRpbmcg5Lmf
5LiNIHJldHVybu+8jOacieaVsOaNruWwseebtOaOpeeUuwogICAgICAgIGlmIChza2VsRWwpIHNrZWxF
bC5jbGFzc0xpc3QucmVtb3ZlKCdvbicpOwogICAgICAgIGNvbnN0IGFwcEJvb3QgPSBkb2N1bWVudC5n
ZXRFbGVtZW50QnlJZCgnYXBwJyk7CiAgICAgICAgaWYgKGFwcEJvb3QpIGFwcEJvb3QuY2xhc3NMaXN0
LnJlbW92ZSgnYm9vdC1sb2FkaW5nJyk7CiAgICAgICAgaWYgKCh3YWl0aW5nRGF0YSB8fCAhaG9zdFB1
c2hlZE9uY2UpICYmICF2aXNpYmxlLmxlbmd0aCkgewogICAgICAgICAgICBlbXB0eUVsLmNsYXNzTGlz
dC5yZW1vdmUoJ29uJyk7CiAgICAgICAgICAgIHVwZGF0ZVRvcEJ0bigpOwogICAgICAgICAgICByZXR1
cm47CiAgICAgICAgfQogICAgICAgIGlmICghdmlzaWJsZS5sZW5ndGgpIHsKICAgICAgICAgICAgLy8g
TmV2ZXIgc2hvd+OAjOaaguaXoOiusOW9leOAjXVudGlsIHdlIGhhdmUgc2VlbiBhIHJlYWwgbm9uLWVt
cHR5IHB1c2gsCiAgICAgICAgICAgIC8vIG9yIGEgY29uZmlybWVkIGVtcHR5IGFmdGVyIHdhcm0gKHNh
d05vbkVtcHR5IGNhbiBiZSBzZXQgYnkgZW1wdHktZmFsbGJhY2spLgogICAgICAgICAgICAvLyBGaWx0
ZXJlZCBzZWFyY2ggd2l0aCAwIGhpdHMgaXMgYWxsb3dlZCBvbmNlIGhvc3QgcHVzaGVkLgogICAgICAg
ICAgICBjb25zdCBxT24gPSBTdHJpbmcocXVlcnkgfHwgJycpLnRyaW0oKS5sZW5ndGggPiAwOwogICAg
ICAgICAgICBjb25zdCBhbGxvd0VtcHR5ID0gaG9zdFB1c2hlZE9uY2UgJiYgc2F3Tm9uRW1wdHkgJiYg
IXdhaXRpbmdEYXRhICYmICFib290TG9hZGluZwogICAgICAgICAgICAgICAgJiYgKHFPbiB8fCBkaXNr
VG90YWwgPD0gMCk7CiAgICAgICAgICAgIGlmICghYWxsb3dFbXB0eSkgewogICAgICAgICAgICAgICAg
ZW1wdHlFbC5jbGFzc0xpc3QucmVtb3ZlKCdvbicpOwogICAgICAgICAgICAgICAgdXBkYXRlVG9wQnRu
KCk7CiAgICAgICAgICAgICAgICByZXR1cm47CiAgICAgICAgICAgIH0KICAgICAgICAgICAgaWYgKHNl
bGVjdEZpcnN0T25TaG93KSB7CiAgICAgICAgICAgICAgICBzZWxlY3RGaXJzdE9uU2hvdyA9IGZhbHNl
OwogICAgICAgICAgICAgICAgc2VsZWN0ZWRJZCA9IDA7CiAgICAgICAgICAgICAgICBjbGVhck11bHRp
KCk7CiAgICAgICAgICAgICAgICBsaXN0RWwuc2Nyb2xsVG9wID0gMDsKICAgICAgICAgICAgfQogICAg
ICAgICAgICBlbXB0eUVsLmNsYXNzTGlzdC5hZGQoJ29uJyk7CiAgICAgICAgICAgIHVwZGF0ZVRvcEJ0
bigpOwogICAgICAgICAgICByZXR1cm47CiAgICAgICAgfQogICAgICAgIGVtcHR5RWwuY2xhc3NMaXN0
LnJlbW92ZSgnb24nKTsKICAgICAgICBjb25zdCBmcmFnID0gZG9jdW1lbnQuY3JlYXRlRG9jdW1lbnRG
cmFnbWVudCgpOwogICAgICAgIGNvbnN0IGJsb2NrcyA9IGJ1aWxkUGlubmVkQmxvY2tzKHNob3duKTsK
ICAgICAgICBsZXQgbnVtID0gMDsKICAgICAgICBibG9ja3MuZm9yRWFjaChiID0+IHsKICAgICAgICAg
ICAgbnVtICs9IDE7CiAgICAgICAgICAgIGlmIChiLmtpbmQgPT09ICdncm91cCcgJiYgYi5pdGVtcy5s
ZW5ndGggPiAxKQogICAgICAgICAgICAgICAgZnJhZy5hcHBlbmRDaGlsZChtYWtlR3JvdXBJdGVtKGIu
aXRlbXMsIG51bSkpOwogICAgICAgICAgICBlbHNlCiAgICAgICAgICAgICAgICBmcmFnLmFwcGVuZENo
aWxkKG1ha2VJdGVtKGIuaXRlbXNbMF0sIG51bSkpOwogICAgICAgIH0pOwogICAgICAgIGxpc3RFbC5h
cHBlbmRDaGlsZChmcmFnKTsKICAgICAgICBtYXJrUXVldWVSYWlscygpOwogICAgICAgIHVwZGF0ZU1v
cmVGb290ZXIoZGlza1RvdGFsKTsKICAgICAgICBpZiAoc2VsZWN0Rmlyc3RPblNob3cpIHsKICAgICAg
ICAgICAgc2VsZWN0Rmlyc3RPblNob3cgPSBmYWxzZTsKICAgICAgICAgICAgc2VsZWN0ZWRJZCA9IHZp
c2libGVbMF0uaWQ7CiAgICAgICAgICAgIGNsZWFyTXVsdGkoKTsKICAgICAgICAgICAgbGlzdEVsLnNj
cm9sbFRvcCA9IDA7CiAgICAgICAgfSBlbHNlIGlmICghdmlzaWJsZS5zb21lKGMgPT4gYy5pZCA9PSBz
ZWxlY3RlZElkKSkgewogICAgICAgICAgICBzZWxlY3RlZElkID0gdmlzaWJsZVswXS5pZDsKICAgICAg
ICAgICAgcmFuZ2VBbmNob3JJZCA9IHNlbGVjdGVkSWQ7CiAgICAgICAgICAgIHJhbmdlQW5jaG9yQ2xp
Y2tlZCA9IGZhbHNlOwogICAgICAgIH0gZWxzZSBpZiAoIXJhbmdlQW5jaG9ySWQpIHsKICAgICAgICAg
ICAgcmFuZ2VBbmNob3JJZCA9IHNlbGVjdGVkSWQ7CiAgICAgICAgfQogICAgICAgIHN5bmNJdGVtSGln
aGxpZ2h0KCk7CiAgICAgICAgdXBkYXRlVG9wQnRuKCk7CiAgICAgICAgaWYgKHdpbmRvdy5fX3BlbmRp
bmdKdW1wSWQpIHsKICAgICAgICAgICAgY29uc3QgamlkID0gK3dpbmRvdy5fX3BlbmRpbmdKdW1wSWQ7
CiAgICAgICAgICAgIGNvbnN0IGVsID0gbGlzdEVsLnF1ZXJ5U2VsZWN0b3IoJy5tZy1yb3dbZGF0YS1p
ZD0iJyArIGppZCArICciXScpIHx8IGxpc3RFbC5xdWVyeVNlbGVjdG9yKCcuaXRtW2RhdGEtaWQ9Iicg
KyBqaWQgKyAnIl0nKTsKICAgICAgICAgICAgaWYgKGVsKSB7CiAgICAgICAgICAgICAgICBjb25zdCBo
aXQgPSAoYWxsQ2xpcHMgfHwgW10pLmZpbmQoYyA9PiArYy5pZCA9PT0gK2ppZCk7CiAgICAgICAgICAg
ICAgICBjb25zdCBnaWQgPSAoaGl0ICYmIFN0cmluZyhoaXQuZmF2R3JvdXAgfHwgJycpLnRyaW0oKSkg
fHwgbGFzdFBhc3RlR3JvdXA7CiAgICAgICAgICAgICAgICBjb25zdCBncm91cE4gPSAoKCkgPT4gewog
ICAgICAgICAgICAgICAgICAgIGlmICghZ2lkKSByZXR1cm4gMTsKICAgICAgICAgICAgICAgICAgICBy
ZXR1cm4gKGFsbENsaXBzIHx8IFtdKS5maWx0ZXIoYyA9PiBTdHJpbmcoYy5mYXZHcm91cCB8fCAnJyku
dHJpbSgpID09PSBnaWQpLmxlbmd0aDsKICAgICAgICAgICAgICAgIH0pKCk7CiAgICAgICAgICAgICAg
ICBpZiAoZ2lkICYmIGdyb3VwTiA8IDIgJiYgISh3aW5kb3cuX19qdW1wR3JvdXBFbnN1cmVkID4gMCkp
IHsKICAgICAgICAgICAgICAgICAgICB3aW5kb3cuX19qdW1wR3JvdXBFbnN1cmVkID0gKHdpbmRvdy5f
X2p1bXBHcm91cEVuc3VyZWQgfHwgMCkgKyAxOwogICAgICAgICAgICAgICAgICAgIHRyeSB7IGFoaygn
ZW5zdXJlRmF2R3JvdXBBcm91bmQnLCBTdHJpbmcoamlkKSk7IH0gY2F0Y2gge30KICAgICAgICAgICAg
ICAgICAgICBzZXRUaW1lb3V0KCgpID0+IHsgaWYgKHdpbmRvdy5fX3BlbmRpbmdKdW1wSWQpIHRyeUNv
bnRpbnVlSnVtcCgpOyB9LCAxMjApOwogICAgICAgICAgICAgICAgfSBlbHNlIHsKICAgICAgICAgICAg
ICAgICAgICB3aW5kb3cuX19wZW5kaW5nSnVtcElkID0gMDsKICAgICAgICAgICAgICAgICAgICB3aW5k
b3cuX19qdW1wTG9hZFRyaWVzID0gMDsKICAgICAgICAgICAgICAgICAgICB3aW5kb3cuX19qdW1wR3Jv
dXBFbnN1cmVkID0gMDsKICAgICAgICAgICAgICAgICAgICBmbGFzaExvY2F0ZU5vZGUoamlkKTsKICAg
ICAgICAgICAgICAgIH0KICAgICAgICAgICAgfSBlbHNlIGlmIChhbGxDbGlwcy5sZW5ndGggPCBkaXNr
VG90YWwgJiYgKHdpbmRvdy5fX2p1bXBMb2FkVHJpZXMgfHwgMCkgPCA0MCkgewogICAgICAgICAgICAg
ICAgd2luZG93Ll9fanVtcExvYWRUcmllcyA9ICh3aW5kb3cuX19qdW1wTG9hZFRyaWVzIHx8IDApICsg
MTsKICAgICAgICAgICAgICAgIHJlcXVlc3RNb3JlKCk7CiAgICAgICAgICAgIH0gZWxzZSBpZiAoY3Vy
VGFiICE9PSAnYWxsJyAmJiAhd2luZG93Ll9fanVtcEZlbGxCYWNrKSB7CiAgICAgICAgICAgICAgICAv
LyBJdGVtIGdvbmUgZnJvbSB0aGlzIHRhYiAoZS5nLiB1bnBpbm5lZCkg4oCUIGZhbGwgYmFjayB0byDl
hajpg6ggb25jZQogICAgICAgICAgICAgICAgd2luZG93Ll9fanVtcEZlbGxCYWNrID0gdHJ1ZTsKICAg
ICAgICAgICAgICAgIHdpbmRvdy5fX2p1bXBMb2FkVHJpZXMgPSAwOwogICAgICAgICAgICAgICAgY3Vy
VGFiID0gJ2FsbCc7CiAgICAgICAgICAgICAgICBtYXJrVGFiKCdhbGwnKTsKICAgICAgICAgICAgICAg
IHJlcXVlc3RWaWV3KCk7CiAgICAgICAgICAgIH0gZWxzZSB7CiAgICAgICAgICAgICAgICB3aW5kb3cu
X19wZW5kaW5nSnVtcElkID0gMDsKICAgICAgICAgICAgICAgIHdpbmRvdy5fX2p1bXBMb2FkVHJpZXMg
PSAwOwogICAgICAgICAgICAgICAgd2luZG93Ll9fanVtcEdyb3VwRW5zdXJlZCA9IDA7CiAgICAgICAg
ICAgICAgICBpZiAoYWxsQ2xpcHMuc29tZShjID0+ICtjLmlkID09PSBqaWQpKQogICAgICAgICAgICAg
ICAgICAgIHNlbGVjdGVkSWQgPSBqaWQ7CiAgICAgICAgICAgICAgICBzeW5jSXRlbUhpZ2hsaWdodCgp
OwogICAgICAgICAgICB9CiAgICAgICAgfQogICAgICAgIHJlcXVlc3RBbmltYXRpb25GcmFtZSgoKSA9
PiB7CiAgICAgICAgICAgIGlmIChhbGxDbGlwcy5sZW5ndGggPCBkaXNrVG90YWwKICAgICAgICAgICAg
ICAgICYmIGxpc3RFbC5zY3JvbGxIZWlnaHQgPD0gbGlzdEVsLmNsaWVudEhlaWdodCArIDIwKQogICAg
ICAgICAgICAgICAgcmVxdWVzdE1vcmUoKTsKICAgICAgICAgICAgc2NoZWR1bGVGaWxlR29uZUNoZWNr
KCk7CiAgICAgICAgfSk7CiAgICB9CgogICAgY29uc3QgU1ZHID0gewogICAgICAgIHRleHQ6ICAgYDxz
dmcgdmlld0JveD0iMCAwIDI0IDI0IiBmaWxsPSJub25lIiBzdHJva2U9ImN1cnJlbnRDb2xvciIgc3Ry
b2tlLXdpZHRoPSIyIj48cGF0aCBkPSJNNCA3VjRoMTZ2M005IDIwaDZNMTIgNHYxNiIvPjwvc3ZnPmAs
CiAgICAgICAgbWQ6ICAgICBgPHN2ZyB2aWV3Qm94PSIwIDAgMjQgMjQiIGZpbGw9ImN1cnJlbnRDb2xv
ciI+PHRleHQgeD0iMTIiIHk9IjE3IiB0ZXh0LWFuY2hvcj0ibWlkZGxlIiBmb250LXNpemU9IjE1IiBm
b250LXdlaWdodD0iODAwIiBmb250LWZhbWlseT0iU2Vnb2UgVUksTWljcm9zb2Z0IFlhSGVpLHNhbnMt
c2VyaWYiPk08L3RleHQ+PC9zdmc+YCwKICAgICAgICBpbWFnZTogIGA8c3ZnIHZpZXdCb3g9IjAgMCAy
NCAyNCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0cm9rZS13aWR0aD0iMS44Ij48
cmVjdCB4PSIzIiB5PSI1IiB3aWR0aD0iMTgiIGhlaWdodD0iMTQiIHJ4PSIyIi8+PGNpcmNsZSBjeD0i
OC41IiBjeT0iMTAiIHI9IjEuNSIgZmlsbD0iY3VycmVudENvbG9yIiBzdHJva2U9Im5vbmUiLz48cGF0
aCBkPSJNMyAxNmw1LTUgNCA0IDMtMyA2IDYiLz48L3N2Zz5gLAogICAgICAgIHZpZGVvOiAgYDxzdmcg
dmlld0JveD0iMCAwIDI0IDI0IiBmaWxsPSJub25lIiBzdHJva2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tl
LXdpZHRoPSIxLjgiPjxyZWN0IHg9IjMiIHk9IjYiIHdpZHRoPSIxNCIgaGVpZ2h0PSIxMiIgcng9IjIi
Lz48cGF0aCBkPSJNMTcgOS41bDQtMi41djEwbC00LTIuNVY5LjV6IiBmaWxsPSJjdXJyZW50Q29sb3Ii
IHN0cm9rZT0ibm9uZSIvPjxwYXRoIGQ9Ik04LjUgMTAuMnYzLjZsMy4yLTEuOC0zLjItMS44eiIgZmls
bD0iY3VycmVudENvbG9yIiBzdHJva2U9Im5vbmUiLz48L3N2Zz5gLAogICAgICAgIGZvbGRlcjogYDxz
dmcgdmlld0JveD0iMCAwIDI0IDI0IiBmaWxsPSJjdXJyZW50Q29sb3IiPjxwYXRoIGQ9Ik0xMCA0SDRj
LTEuMSAwLTIgLjktMiAydjEyYzAgMS4xLjkgMiAyIDJoMTZjMS4xIDAgMi0uOSAyLTJWOGMwLTEuMS0u
OS0yLTItMmgtOGwtMi0yeiIvPjwvc3ZnPmAsCiAgICAgICAgemlwOiAgICBgPHN2ZyB2aWV3Qm94PSIw
IDAgMjQgMjQiIGZpbGw9Im5vbmUiIHN0cm9rZT0iY3VycmVudENvbG9yIiBzdHJva2Utd2lkdGg9IjEu
OCI+PHBhdGggZD0iTTYgM2g5bDUgNXYxM2ExIDEgMCAwIDEtMSAxSDZhMSAxIDAgMCAxLTEtMVY0YTEg
MSAwIDAgMSAxLTF6Ii8+PHBhdGggZD0iTTE0IDN2Nmg2Ii8+PC9zdmc+YCwKICAgICAgICBhaGs6ICAg
IGA8c3ZnIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0iY3VycmVudENvbG9yIj48dGV4dCB4PSIxMiIg
eT0iMTciIHRleHQtYW5jaG9yPSJtaWRkbGUiIGZvbnQtc2l6ZT0iMTQiIGZvbnQtd2VpZ2h0PSI3MDAi
Pkg8L3RleHQ+PC9zdmc+YCwKICAgICAgICBsbms6ICAgIGA8c3ZnIHZpZXdCb3g9IjAgMCAyNCAyNCIg
ZmlsbD0ibm9uZSIgc3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0cm9rZS13aWR0aD0iMS44Ij48cGF0aCBk
PSJNMTAgMTNhNSA1IDAgMCAwIDcuMDcgMGwyLjEyLTIuMTJhNSA1IDAgMCAwLTcuMDctNy4wN0wxMSA1
Ii8+PHBhdGggZD0iTTE0IDExYTUgNSAwIDAgMC03LjA3IDBMNC44IDEzLjEyYTUgNSAwIDEgMCA3LjA3
IDcuMDdMMTMgMTkiLz48L3N2Zz5gLAogICAgICAgIGRvYzogICAgYDxzdmcgdmlld0JveD0iMCAwIDI0
IDI0IiBmaWxsPSJub25lIiBzdHJva2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIxLjgiPjxw
YXRoIGQ9Ik03IDNoN2w1IDV2MTNhMSAxIDAgMCAxLTEgMUg3YTEgMSAwIDAgMS0xLTFWNGExIDEgMCAw
IDEgMS0xeiIvPjxwYXRoIGQ9Ik0xNCAzdjZoNiIvPjwvc3ZnPmAsCiAgICAgICAgbXVsdGk6ICBgPHN2
ZyB2aWV3Qm94PSIwIDAgMjQgMjQiIGZpbGw9Im5vbmUiIHN0cm9rZT0iY3VycmVudENvbG9yIiBzdHJv
a2Utd2lkdGg9IjEuOCI+PHJlY3QgeD0iNyIgeT0iNyIgd2lkdGg9IjEyIiBoZWlnaHQ9IjE0IiByeD0i
MS41Ii8+PHBhdGggZD0iTTUgMTdWNWExIDEgMCAwIDEgMS0xaDEwIi8+PC9zdmc+YAogICAgfTsKCiAg
ICBmdW5jdGlvbiBmaWxlRXh0KHBhdGgpIHsKICAgICAgICBjb25zdCBiYXNlID0gU3RyaW5nKHBhdGgg
fHwgJycpLnNwbGl0KC9bXFwvXS8pLnBvcCgpIHx8ICcnOwogICAgICAgIGNvbnN0IGkgPSBiYXNlLmxh
c3RJbmRleE9mKCcuJyk7CiAgICAgICAgcmV0dXJuIGkgPiAwID8gYmFzZS5zbGljZShpICsgMSkudG9M
b3dlckNhc2UoKSA6ICcnOwogICAgfQogICAgY29uc3QgaXNJbWFnZUV4dCA9IGUgPT4gWydwbmcnLCdq
cGcnLCdqcGVnJywnZ2lmJywnd2VicCcsJ2JtcCcsJ2ljbycsJ3RpZicsJ3RpZmYnLCdzdmcnXS5pbmNs
dWRlcyhlKTsKICAgIGNvbnN0IGlzVmlkZW9FeHQgPSBlID0+IFsnbXA0JywnbWt2JywnYXZpJywnbW92
Jywnd212JywnZmx2Jywnd2VibScsJ200dicsJ21wZWcnLCdtcGcnLCd0cycsJ20ydHMnLCczZ3AnLCdy
bScsJ3JtdmInXS5pbmNsdWRlcyhlKTsKICAgIGNvbnN0IGlzWmlwRXh0ICAgPSBlID0+IFsnemlwJywn
cmFyJywnN3onLCd0YXInLCdneicsJ2J6MiddLmluY2x1ZGVzKGUpOwoKICAgIGZ1bmN0aW9uIGljb25G
b3JGaWxlcyhmaWxlcykgewogICAgICAgIGlmICghZmlsZXMubGVuZ3RoKSAgICByZXR1cm4geyBjbHM6
ICdmaWxlIGZ0LWRvYycsIHN2ZzogU1ZHLmRvYyB9OwogICAgICAgIGlmIChmaWxlcy5sZW5ndGggPiAx
KSByZXR1cm4geyBjbHM6ICdmaWxlIGZ0LWxuaycsIHN2ZzogU1ZHLm11bHRpIH07CiAgICAgICAgY29u
c3QgZXh0ID0gZmlsZUV4dChmaWxlc1swXSk7CiAgICAgICAgaWYgKCFleHQpICAgICAgICAgICAgICBy
ZXR1cm4geyBjbHM6ICdmaWxlIGZ0LWRpcicsIHN2ZzogU1ZHLmZvbGRlciB9OwogICAgICAgIGlmIChp
c0ltYWdlRXh0KGV4dCkpICAgcmV0dXJuIHsgY2xzOiAnZmlsZSBmdC1pbWcnLCBzdmc6IFNWRy5pbWFn
ZSB9OwogICAgICAgIGlmIChpc1ZpZGVvRXh0KGV4dCkpICAgcmV0dXJuIHsgY2xzOiAnZmlsZSBmdC12
aWQnLCBzdmc6IChTVkcudmlkZW8gfHwgU1ZHLmRvYykgfTsKICAgICAgICBpZiAoaXNaaXBFeHQoZXh0
KSkgICAgIHJldHVybiB7IGNsczogJ2ZpbGUgZnQtemlwJywgc3ZnOiBTVkcuemlwIH07CiAgICAgICAg
aWYgKGV4dCA9PT0gJ2FoaycpICAgICByZXR1cm4geyBjbHM6ICdmaWxlIGZ0LWFoaycsIHN2ZzogU1ZH
LmFoayB9OwogICAgICAgIGlmIChleHQgPT09ICdsbmsnKSAgICAgcmV0dXJuIHsgY2xzOiAnZmlsZSBm
dC1sbmsnLCBzdmc6IFNWRy5sbmsgfTsKICAgICAgICByZXR1cm4geyBjbHM6ICdmaWxlIGZ0LWRvYycs
IHN2ZzogU1ZHLmRvYyB9OwogICAgfQoKICAgIGZ1bmN0aW9uIHNyY1dpbkxhYmVsKGMpIHsKICAgICAg
ICBjb25zdCB0ID0gU3RyaW5nKGMgJiYgYy5zcmNUaXRsZSB8fCAnJykudHJpbSgpOwogICAgICAgIGlm
ICh0KSByZXR1cm4gdDsKICAgICAgICByZXR1cm4gU3RyaW5nKGMgJiYgYy5zcmNFeGUgfHwgJycpLnJl
cGxhY2UoL1wuZXhlJC9pLCAnJyk7CiAgICB9CiAgICBmdW5jdGlvbiBzcmNUaXRsZUh0bWwoYykgewog
ICAgICAgIC8vIOWIl+ihqOS4remXtC/lj7PkvqfkuI3lho3mmL7npLrnqpflj6PmoIfpopjvvIzmnaXm
upDlj6rkv53nlZnlj7Pkvqflm77moIfmgqzlgZzmj5DnpLoKICAgICAgICByZXR1cm4gJyc7CiAgICB9
CiAgICBmdW5jdGlvbiBleHBhbmRDaGV2cm9uKG9wZW4pIHsKICAgICAgICByZXR1cm4gb3BlbgogICAg
ICAgICAgICA/IGA8c3ZnIHZpZXdCb3g9IjAgMCAxNiAxNiIgd2lkdGg9IjE0IiBoZWlnaHQ9IjE0IiBm
aWxsPSJub25lIiBzdHJva2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIxLjgiIHN0cm9rZS1s
aW5lY2FwPSJyb3VuZCI+PHBvbHlsaW5lIHBvaW50cz0iNCAxMCA4IDYgMTIgMTAiLz48L3N2Zz48c3Bh
bj7mlLbotbc8L3NwYW4+YAogICAgICAgICAgICA6IGA8c3ZnIHZpZXdCb3g9IjAgMCAxNiAxNiIgd2lk
dGg9IjE0IiBoZWlnaHQ9IjE0IiBmaWxsPSJub25lIiBzdHJva2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tl
LXdpZHRoPSIxLjgiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCI+PHBvbHlsaW5lIHBvaW50cz0iNCA2IDgg
MTAgMTIgNiIvPjwvc3ZnPjxzcGFuPuWxleW8gDwvc3Bhbj5gOwogICAgfQogICAgZnVuY3Rpb24gbGlz
dEV4cGFuZE1heFB4KCkgewogICAgICAgIGNvbnN0IGggPSAobGlzdEVsICYmIGxpc3RFbC5jbGllbnRI
ZWlnaHQpIHx8IDM2MDsKICAgICAgICAvLyDlh6DkuY7ljaDmu6HliJfooajvvIzlupXpg6jnlZnnuqbk
uIDooYwKICAgICAgICByZXR1cm4gTWF0aC5tYXgoOTYsIGggLSAyOCk7CiAgICB9CiAgICBmdW5jdGlv
biBhcHBseUV4cGFuZGVkUHJldmlldyhwcmV2LCBmdWxsVGV4dCkgewogICAgICAgIGNvbnN0IG1heEgg
PSBsaXN0RXhwYW5kTWF4UHgoKTsKICAgICAgICBwcmV2LnN0eWxlLm1heEhlaWdodCA9IG1heEggKyAn
cHgnOwogICAgICAgIHByZXYuY2xhc3NMaXN0LmFkZCgnZXhwYW5kZWQnKTsKICAgICAgICBzZXRIbFRl
eHQocHJldiwgZnVsbFRleHQpOwogICAgICAgIC8vIOS7jea6ouWHuu+8muaIquaWreW5tuWcqOacq+Ww
vuWKoOOAjCAuLi7jgI0KICAgICAgICBpZiAocHJldi5zY3JvbGxIZWlnaHQgPD0gcHJldi5jbGllbnRI
ZWlnaHQgKyAyKQogICAgICAgICAgICByZXR1cm47CiAgICAgICAgbGV0IGxvID0gMCwgaGkgPSBmdWxs
VGV4dC5sZW5ndGgsIGJlc3QgPSAwOwogICAgICAgIHdoaWxlIChsbyA8PSBoaSkgewogICAgICAgICAg
ICBjb25zdCBtaWQgPSAobG8gKyBoaSkgPj4gMTsKICAgICAgICAgICAgc2V0SGxUZXh0KHByZXYsIGZ1
bGxUZXh0LnNsaWNlKDAsIG1pZCkgKyAnIC4uLicpOwogICAgICAgICAgICBpZiAocHJldi5zY3JvbGxI
ZWlnaHQgPD0gcHJldi5jbGllbnRIZWlnaHQgKyAyKSB7CiAgICAgICAgICAgICAgICBiZXN0ID0gbWlk
OwogICAgICAgICAgICAgICAgbG8gPSBtaWQgKyAxOwogICAgICAgICAgICB9IGVsc2UgewogICAgICAg
ICAgICAgICAgaGkgPSBtaWQgLSAxOwogICAgICAgICAgICB9CiAgICAgICAgfQogICAgICAgIHNldEhs
VGV4dChwcmV2LCBmdWxsVGV4dC5zbGljZSgwLCBiZXN0KSArICcgLi4uJyk7CiAgICB9CiAgICBmdW5j
dGlvbiBjb2xsYXBzZVByZXZpZXcocHJldiwgZnVsbFRleHQpIHsKICAgICAgICBwcmV2LmNsYXNzTGlz
dC5yZW1vdmUoJ2V4cGFuZGVkJyk7CiAgICAgICAgcHJldi5zdHlsZS5tYXhIZWlnaHQgPSAnJzsKICAg
ICAgICBzZXRIbFRleHQocHJldiwgZnVsbFRleHQpOwogICAgfQoKICAgIGZ1bmN0aW9uIGZhdkdyb3Vw
T2YoYykgewogICAgICAgIHJldHVybiBTdHJpbmcoYyAmJiBjLmZhdkdyb3VwIHx8ICcnKS50cmltKCk7
CiAgICB9CiAgICBmdW5jdGlvbiBjbGlwQ29udGVudFByZXZpZXcoYykgewogICAgICAgIGNvbnN0IHR5
cGUgPSBub3JtVHlwZShjLnR5cGUpOwogICAgICAgIGlmICh0eXBlID09PSAnaW1hZ2UnKSByZXR1cm4g
J1vlm77lg49dJyArIChjLndpZHRoICYmIGMuaGVpZ2h0ID8gKCcgJyArIGMud2lkdGggKyAnw5cnICsg
Yy5oZWlnaHQpIDogJycpOwogICAgICAgIGlmICh0eXBlID09PSAnZmlsZScpIHsKICAgICAgICAgICAg
Y29uc3QgZmlsZXMgPSBTdHJpbmcoYy5wcmV2aWV3IHx8IGMuZGF0YSB8fCAnJykuc3BsaXQoL1xyP1xu
LykuZmlsdGVyKEJvb2xlYW4pOwogICAgICAgICAgICByZXR1cm4gZmlsZXMubWFwKGYgPT4gZi5zcGxp
dCgvW1xcL10vKS5wb3AoKSkuam9pbignIMK3ICcpIHx8ICdb5paH5Lu2XSc7CiAgICAgICAgfQogICAg
ICAgIGxldCBfcCA9IFN0cmluZyhjLnByZXZpZXcgfHwgYy5kYXRhIHx8ICcnKTsKICAgICAgICB7IGNv
bnN0IF9uID0gTnVtYmVyKGMuY2hhckNvdW50KSB8fCAwOyBpZiAoX24gPiBfcC5sZW5ndGggJiYgX3Au
bGVuZ3RoKSBfcCArPSAnLi4uJzsgfQogICAgICAgIHJldHVybiBfcDsKICAgIH0KICAgIGZ1bmN0aW9u
IGJ1aWxkUGlubmVkQmxvY2tzKGxpc3QpIHsKICAgICAgICBjb25zdCB1c2VkID0gbmV3IFNldCgpOwog
ICAgICAgIGNvbnN0IG91dCA9IFtdOwogICAgICAgIGZvciAoY29uc3QgYyBvZiBsaXN0KSB7CiAgICAg
ICAgICAgIGlmICh1c2VkLmhhcygrYy5pZCkpIGNvbnRpbnVlOwogICAgICAgICAgICBjb25zdCBnaWQg
PSBmYXZHcm91cE9mKGMpOwogICAgICAgICAgICBpZiAoIWdpZCkgewogICAgICAgICAgICAgICAgdXNl
ZC5hZGQoK2MuaWQpOwogICAgICAgICAgICAgICAgb3V0LnB1c2goeyBraW5kOiAnc2luZ2xlJywgaXRl
bXM6IFtjXSB9KTsKICAgICAgICAgICAgICAgIGNvbnRpbnVlOwogICAgICAgICAgICB9CiAgICAgICAg
ICAgIGNvbnN0IG1lbWJlcnMgPSBsaXN0LmZpbHRlcih4ID0+IGZhdkdyb3VwT2YoeCkgPT09IGdpZCk7
CiAgICAgICAgICAgIG1lbWJlcnMuZm9yRWFjaChtID0+IHVzZWQuYWRkKCttLmlkKSk7CiAgICAgICAg
ICAgIGlmIChtZW1iZXJzLmxlbmd0aCA8IDIpCiAgICAgICAgICAgICAgICBvdXQucHVzaCh7IGtpbmQ6
ICdzaW5nbGUnLCBpdGVtczogW21lbWJlcnNbMF0gfHwgY10gfSk7CiAgICAgICAgICAgIGVsc2UKICAg
ICAgICAgICAgICAgIG91dC5wdXNoKHsga2luZDogJ2dyb3VwJywgZ2lkLCBpdGVtczogbWVtYmVycyB9
KTsKICAgICAgICB9CiAgICAgICAgcmV0dXJuIG91dDsKICAgIH0KICAgIGZ1bmN0aW9uIF9fcHJlcFBh
c3RlKCkgewogICAgICAgIHRyeSB7CiAgICAgICAgICAgIGNvbnN0IHMgPSBkb2N1bWVudC5nZXRFbGVt
ZW50QnlJZCgnc2VhcmNoJyk7CiAgICAgICAgICAgIGlmIChzICYmIGRvY3VtZW50LmFjdGl2ZUVsZW1l
bnQgPT09IHMpIHRyeSB7IHMuYmx1cigpOyB9IGNhdGNoIHt9CiAgICAgICAgICAgIGlmICh3aW5kb3cu
Z2V0U2VsZWN0aW9uKSB3aW5kb3cuZ2V0U2VsZWN0aW9uKCkucmVtb3ZlQWxsUmFuZ2VzKCk7CiAgICAg
ICAgfSBjYXRjaCB7fQogICAgfQogICAgZnVuY3Rpb24gcGFzdGVPbmUoYykgewogICAgICAgIF9fcHJl
cFBhc3RlKCk7CiAgICAgICAgc2VsZWN0ZWRJZCA9IGMuaWQ7CiAgICAgICAgaWYgKG11bHRpSWRzLmxl
bmd0aCkgY2xlYXJNdWx0aSgpOwogICAgICAgIHN5bmNJdGVtSGlnaGxpZ2h0KCk7CiAgICAgICAgbWFy
a1Bhc3RlZExvY2FsKGMuaWQpOwogICAgICAgIGFoaygncGFzdGUnLCBTdHJpbmcoYy5pZCkpOwogICAg
fQogICAgZnVuY3Rpb24gb3BlblJlY2VudERpcihwYXRoKSB7CiAgICAgICAgbGV0IHAgPSBTdHJpbmco
cGF0aCB8fCAnJykudHJpbSgpOwogICAgICAgIGlmICghcCkgcmV0dXJuOwogICAgICAgIGlmICgvXlth
LXpBLVpdOiQvLnRlc3QocCkpIHAgKz0gJ1xcJzsKICAgICAgICAvLyDnu5/kuIAgLyDvvJrpgb/lhY0g
V2ViVmlldyBob3N0L0pTT04g5ZCD5o6J5Y+N5pac5p2gCiAgICAgICAgY29uc3Qgd2lyZSA9IHAucmVw
bGFjZSgvXFwvZywgJy8nKTsKICAgICAgICBjb25zdCBzZW5kID0gKCkgPT4gewogICAgICAgICAgICAv
LyAxKSBwb3N0TWVzc2FnZSDmnIDnqLPvvIjkuI3ov5sgc3luYyBDT03vvIkKICAgICAgICAgICAgdHJ5
IHsKICAgICAgICAgICAgICAgIGlmICh3aW5kb3cuY2hyb21lICYmIGNocm9tZS53ZWJ2aWV3ICYmIHR5
cGVvZiBjaHJvbWUud2Vidmlldy5wb3N0TWVzc2FnZSA9PT0gJ2Z1bmN0aW9uJykgewogICAgICAgICAg
ICAgICAgICAgIGNocm9tZS53ZWJ2aWV3LnBvc3RNZXNzYWdlKCdvcGVuRGlyfCcgKyB3aXJlKTsKICAg
ICAgICAgICAgICAgICAgICByZXR1cm4gdHJ1ZTsKICAgICAgICAgICAgICAgIH0KICAgICAgICAgICAg
fSBjYXRjaCB7fQogICAgICAgICAgICAvLyAyKSBhc3luYyBob3N077yI6Z2eIHN5bmPvvIkKICAgICAg
ICAgICAgdHJ5IHsKICAgICAgICAgICAgICAgIGNvbnN0IGhvc3QgPSBjaHJvbWUud2Vidmlldy5ob3N0
T2JqZWN0cy5haGs7CiAgICAgICAgICAgICAgICBpZiAoaG9zdCAmJiBob3N0Lm9wZW5EaXIpIHsKICAg
ICAgICAgICAgICAgICAgICBQcm9taXNlLnJlc29sdmUoaG9zdC5vcGVuRGlyKHdpcmUpKS5jYXRjaCgo
KSA9PiB7fSk7CiAgICAgICAgICAgICAgICAgICAgcmV0dXJuIHRydWU7CiAgICAgICAgICAgICAgICB9
CiAgICAgICAgICAgIH0gY2F0Y2gge30KICAgICAgICAgICAgLy8gMykg5pyA5ZCO5omNIHN5bmMKICAg
ICAgICAgICAgdHJ5IHsgYWhrKCdvcGVuRGlyJywgd2lyZSk7IHJldHVybiB0cnVlOyB9IGNhdGNoIHt9
CiAgICAgICAgICAgIHJldHVybiBmYWxzZTsKICAgICAgICB9OwogICAgICAgIC8vIOemu+W8gCBwb2lu
dGVyIOS6i+S7tuagiOWGjeiwg++8jOmBv+WFjSBXZWJWaWV3MiDlkIzmraXmrbvplIHlr7zoh7TigJzn
grnkuobmsqHlj43lupTigJ0KICAgICAgICBzZXRUaW1lb3V0KHNlbmQsIDApOwogICAgfQogICAgZnVu
Y3Rpb24gaXNJdGVtQ2hyb21lVGFyZ2V0KHQpIHsKICAgICAgICByZXR1cm4gISEodCAmJiB0LmNsb3Nl
c3QgJiYgdC5jbG9zZXN0KCcuaS1leHBhbmQtYnRuLCAuaS1zcmMtaWNvLCAubWctc3JjLCAuZmQtYnRu
LCAuZmQtcGF0aCwgLnJmLXNlZywgYnV0dG9uLCBhLCBpbnB1dCcpKTsKICAgIH0KICAgIGZ1bmN0aW9u
IGJlZ2luUGFzdGVGcm9tSXRlbShlLCBjKSB7CiAgICAgICAgaWYgKGUuYnV0dG9uICE9IG51bGwgJiYg
ZS5idXR0b24gIT09IDApIHJldHVybjsKICAgICAgICBjb25zdCBzZWcgPSBlLnRhcmdldCAmJiBlLnRh
cmdldC5jbG9zZXN0ICYmIGUudGFyZ2V0LmNsb3Nlc3QoJy5yZi1zZWcnKTsKICAgICAgICBpZiAoc2Vn
KSB7CiAgICAgICAgICAgIGNvbnN0IG9wZW5QYXRoID0gc2VnLl9vcGVuUGF0aCB8fCBzZWcuZ2V0QXR0
cmlidXRlKCdkYXRhLXBhdGgnKSB8fCBzZWcuZGF0YXNldC5vcGVuUGF0aCB8fCAnJzsKICAgICAgICAg
ICAgaWYgKG9wZW5QYXRoKSB7CiAgICAgICAgICAgICAgICBlLnByZXZlbnREZWZhdWx0KCk7CiAgICAg
ICAgICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgICAgICAgICAgICAgb3BlblJlY2VudERp
cihvcGVuUGF0aCk7CiAgICAgICAgICAgICAgICByZXR1cm47CiAgICAgICAgICAgIH0KICAgICAgICB9
CiAgICAgICAgaWYgKGUudGFyZ2V0ICYmIGUudGFyZ2V0LmNsb3Nlc3QgJiYgZS50YXJnZXQuY2xvc2Vz
dCgnLnJmLXBhdGgnKSkKICAgICAgICAgICAgcmV0dXJuOwogICAgICAgIGlmIChpc0l0ZW1DaHJvbWVU
YXJnZXQoZS50YXJnZXQpKSByZXR1cm47CiAgICAgICAgaWYgKG5vcm1UeXBlKGMudHlwZSkgPT09ICdy
ZWNlbnQnKSB7CiAgICAgICAgICAgIGFjdGl2YXRlQ2xpcEl0ZW0oYyk7CiAgICAgICAgICAgIHJldHVy
bjsKICAgICAgICB9CiAgICAgICAgaWYgKGhhbmRsZUl0ZW1DbGljayhlLCBjKSkKICAgICAgICAgICAg
cmV0dXJuOwogICAgICAgIF9fcHJlcFBhc3RlKCk7CiAgICAgICAgc2VsZWN0ZWRJZCA9IGMuaWQ7CiAg
ICAgICAgcmFuZ2VBbmNob3JJZCA9IGMuaWQ7CiAgICAgICAgICAgIGlmIChtdWx0aUlkcy5sZW5ndGgg
PiAwICYmIG11bHRpSWRzLmluY2x1ZGVzKCtjLmlkKSkgewogICAgICAgICAgICBjb25zdCBpZHMgPSBt
dWx0aUlkcy5zbGljZSgpOwogICAgICAgICAgICBjbGVhck11bHRpKCk7CiAgICAgICAgICAgIG1hcmtQ
YXN0ZWRMb2NhbChpZHMpOwogICAgICAgICAgICBwYXN0ZU1hbnlXaXRoU2VwKGlkcyk7CiAgICAgICAg
ICAgIHJldHVybjsKICAgICAgICB9CiAgICAgICAgaWYgKG11bHRpSWRzLmxlbmd0aCkgY2xlYXJNdWx0
aSgpOwogICAgICAgIHN5bmNJdGVtSGlnaGxpZ2h0KCk7CiAgICAgICAgbWFya1Bhc3RlZExvY2FsKGMu
aWQpOwogICAgICAgIGFoaygncGFzdGUnLCBTdHJpbmcoYy5pZCkpOwogICAgfQogICAgZnVuY3Rpb24g
bWFrZUdyb3VwSXRlbShpdGVtcywgaWR4KSB7CiAgICAgICAgY29uc3QgZWwgPSBkb2N1bWVudC5jcmVh
dGVFbGVtZW50KCdkaXYnKTsKICAgICAgICBlbC5jbGFzc05hbWUgPSAnaXRtIGl0LWdyb3VwJwogICAg
ICAgICAgICArIChpdGVtcy5zb21lKGMgPT4gK2MuaWQgPT09ICtzZWxlY3RlZElkKSA/ICcgc2VsJyA6
ICcnKQogICAgICAgICAgICArIChpdGVtcy5zb21lKGMgPT4gbXVsdGlJZHMuaW5jbHVkZXMoK2MuaWQp
KSA/ICcgbXVsdGknIDogJycpOwogICAgICAgIGVsLmRhdGFzZXQuZ3JvdXAgPSBmYXZHcm91cE9mKGl0
ZW1zWzBdKSB8fCAnJzsKICAgICAgICBlbC5kYXRhc2V0LmlkID0gaXRlbXNbMF0uaWQ7CgogICAgICAg
IGNvbnN0IGhlYWQgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsKICAgICAgICBoZWFkLmNs
YXNzTmFtZSA9ICdtZy1oZWFkJzsKICAgICAgICBoZWFkLmlubmVySFRNTCA9ICc8c3BhbiBjbGFzcz0i
bWctdGFnIj7lkIjlubY8L3NwYW4+PHNwYW4+JyArIGl0ZW1zLmxlbmd0aCArICcg5p2hIMK3IOeCueWH
u+WNleadoeeymOi0tDwvc3Bhbj4nOwogICAgICAgIGVsLmFwcGVuZENoaWxkKGhlYWQpOwoKICAgICAg
ICBpdGVtcy5mb3JFYWNoKGMgPT4gewogICAgICAgICAgICBjb25zdCByb3cgPSBkb2N1bWVudC5jcmVh
dGVFbGVtZW50KCdkaXYnKTsKICAgICAgICAgICAgcm93LmNsYXNzTmFtZSA9ICdtZy1yb3cnCiAgICAg
ICAgICAgICAgICArICgrc2VsZWN0ZWRJZCA9PT0gK2MuaWQgPyAnIHNlbCcgOiAnJykKICAgICAgICAg
ICAgICAgICsgKG11bHRpSWRzLmluY2x1ZGVzKCtjLmlkKSA/ICcgbXVsdGknIDogJycpOwogICAgICAg
ICAgICByb3cuZGF0YXNldC5pZCA9IGMuaWQ7CgogICAgICAgICAgICBjb25zdCB0b3AgPSBkb2N1bWVu
dC5jcmVhdGVFbGVtZW50KCdkaXYnKTsKICAgICAgICAgICAgdG9wLmNsYXNzTmFtZSA9ICdtZy1yb3ct
dG9wJzsKICAgICAgICAgICAgY29uc3QgbWFpbiA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2Rpdicp
OwogICAgICAgICAgICBtYWluLmNsYXNzTmFtZSA9ICdtZy1yb3ctbWFpbic7CgogICAgICAgICAgICBj
b25zdCB0aXRsZSA9IFN0cmluZyhjLmZhdlRpdGxlIHx8ICcnKS50cmltKCk7CiAgICAgICAgICAgIGlm
ICh0aXRsZSkgewogICAgICAgICAgICAgICAgY29uc3QgdCA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQo
J2RpdicpOwogICAgICAgICAgICAgICAgdC5jbGFzc05hbWUgPSAnbWctdGl0bGUnOwogICAgICAgICAg
ICAgICAgc2V0SGxUZXh0KHQsIHRpdGxlKTsKICAgICAgICAgICAgICAgIG1haW4uYXBwZW5kQ2hpbGQo
dCk7CiAgICAgICAgICAgIH0KICAgICAgICAgICAgY29uc3QgYm9keSA9IGRvY3VtZW50LmNyZWF0ZUVs
ZW1lbnQoJ2RpdicpOwogICAgICAgICAgICBib2R5LmNsYXNzTmFtZSA9ICdtZy1ib2R5JyArIChub3Jt
VHlwZShjLnR5cGUpID09PSAnaW1hZ2UnID8gJyBpbWcnIDogJycpOwogICAgICAgICAgICBzZXRIbFRl
eHQoYm9keSwgY2xpcENvbnRlbnRQcmV2aWV3KGMpKTsKICAgICAgICAgICAgbWFpbi5hcHBlbmRDaGls
ZChib2R5KTsKICAgICAgICAgICAgdG9wLmFwcGVuZENoaWxkKG1haW4pOwoKICAgICAgICAgICAgY29u
c3Qgc3JjSWNvID0gU3RyaW5nKGMuc3JjSWNvbiB8fCAnJyk7CiAgICAgICAgICAgIGNvbnN0IHNyY0V4
ZSA9IFN0cmluZyhjLnNyY0V4ZSB8fCAnJyk7CiAgICAgICAgICAgIGNvbnN0IHNyY1RpdGxlID0gU3Ry
aW5nKGMuc3JjVGl0bGUgfHwgJycpOwogICAgICAgICAgICBpZiAoc3JjSWNvKSB7CiAgICAgICAgICAg
ICAgICBjb25zdCBpbWcgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdpbWcnKTsKICAgICAgICAgICAg
ICAgIGltZy5jbGFzc05hbWUgPSAnbWctc3JjJzsKICAgICAgICAgICAgICAgIGltZy5zcmMgPSBTVE9S
RV9CQVNFICsgZW5jb2RlVVJJQ29tcG9uZW50KHNyY0ljbyk7CiAgICAgICAgICAgICAgICBpbWcuYWx0
ID0gJyc7CiAgICAgICAgICAgICAgICBjb25zdCB0aXBUeHQgPSBzcmNUaXRsZSB8fCBzcmNFeGUgfHwg
J+adpea6kCc7CiAgICAgICAgICAgICAgICBpbWcudGl0bGUgPSB0aXBUeHQ7CiAgICAgICAgICAgICAg
ICBpbWcub25jbGljayA9IGUgPT4geyBlLnByZXZlbnREZWZhdWx0KCk7IGUuc3RvcFByb3BhZ2F0aW9u
KCk7IHNob3dTcmNUaXAoaW1nLCB0aXBUeHQpOyB9OwogICAgICAgICAgICAgICAgdG9wLmFwcGVuZENo
aWxkKGltZyk7CiAgICAgICAgICAgIH0KICAgICAgICAgICAgcm93LmFwcGVuZENoaWxkKHRvcCk7Cgog
ICAgICAgICAgICByb3cub25wb2ludGVyZG93biA9IGUgPT4gewogICAgICAgICAgICAgICAgaWYgKGUu
YnV0dG9uICE9PSAwKSByZXR1cm47CiAgICAgICAgICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwog
ICAgICAgICAgICAgICAgYmVnaW5QYXN0ZUZyb21JdGVtKGUsIGMpOwogICAgICAgICAgICB9OwogICAg
ICAgICAgICByb3cub25jb250ZXh0bWVudSA9IGUgPT4gewogICAgICAgICAgICAgICAgZS5wcmV2ZW50
RGVmYXVsdCgpOwogICAgICAgICAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICAgICAg
ICAgIHNlbGVjdGVkSWQgPSBjLmlkOwogICAgICAgICAgICAgICAgc2hvd0N0eChlLmNsaWVudFgsIGUu
Y2xpZW50WSwgYyk7CiAgICAgICAgICAgIH07CiAgICAgICAgICAgIGVsLmFwcGVuZENoaWxkKHJvdyk7
CiAgICAgICAgfSk7CgogICAgICAgIGVsLm9uY29udGV4dG1lbnUgPSBlID0+IHsKICAgICAgICAgICAg
aWYgKGUudGFyZ2V0LmNsb3Nlc3QoJy5tZy1yb3cnKSkgcmV0dXJuOwogICAgICAgICAgICBlLnByZXZl
bnREZWZhdWx0KCk7CiAgICAgICAgICAgIHNlbGVjdGVkSWQgPSBpdGVtc1swXS5pZDsKICAgICAgICAg
ICAgc2hvd0N0eChlLmNsaWVudFgsIGUuY2xpZW50WSwgaXRlbXNbMF0pOwogICAgICAgIH07CiAgICAg
ICAgcmV0dXJuIGVsOwogICAgfQoKCiAgICBmdW5jdGlvbiBidWlsZFJlY2VudFBhdGhDcnVtYnMoY29u
dGFpbmVyLCBmdWxsUGF0aCkgewogICAgICAgIGlmICghY29udGFpbmVyKSByZXR1cm47CiAgICAgICAg
Y29udGFpbmVyLnF1ZXJ5U2VsZWN0b3JBbGwoJy5yZi1zZWcsIC5yZi1zZXAnKS5mb3JFYWNoKG4gPT4g
bi5yZW1vdmUoKSk7CiAgICAgICAgY29uc3QgcmF3ID0gU3RyaW5nKGZ1bGxQYXRoIHx8ICcnKS5yZXBs
YWNlKC9cLy9nLCAnXFwnKS5yZXBsYWNlKC9cXCskLywgJycpOwogICAgICAgIGlmICghcmF3KSByZXR1
cm47CiAgICAgICAgY29uc3QgdW5jID0gcmF3LnN0YXJ0c1dpdGgoJ1xcXFwnKTsKICAgICAgICBsZXQg
cmVzdCA9IHVuYyA/IHJhdy5zbGljZSgyKSA6IHJhdzsKICAgICAgICBjb25zdCBwYXJ0cyA9IHJlc3Qu
c3BsaXQoJ1xcJykuZmlsdGVyKEJvb2xlYW4pOwogICAgICAgIGNvbnN0IGFkZFNlZyA9IChsYWJlbCwg
b3BlblBhdGgpID0+IHsKICAgICAgICAgICAgaWYgKGNvbnRhaW5lci5xdWVyeVNlbGVjdG9yKCcucmYt
c2VnLCAucmYtc2VwJykpIHsKICAgICAgICAgICAgICAgIGNvbnN0IHNlcCA9IGRvY3VtZW50LmNyZWF0
ZUVsZW1lbnQoJ3NwYW4nKTsKICAgICAgICAgICAgICAgIHNlcC5jbGFzc05hbWUgPSAncmYtc2VwJzsK
ICAgICAgICAgICAgICAgIHNlcC50ZXh0Q29udGVudCA9ICdcXCc7CiAgICAgICAgICAgICAgICBjb250
YWluZXIuYXBwZW5kQ2hpbGQoc2VwKTsKICAgICAgICAgICAgfQogICAgICAgICAgICAvLyBidXR0b27v
vJrlkb3kuK3mm7TnqLPvvIzkuI3ooqsgYXBwLXJlZ2lvbiAvIOeItue6pyBwb2ludGVyIOWQg+aOiQog
ICAgICAgICAgICBjb25zdCBzZWcgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdidXR0b24nKTsKICAg
ICAgICAgICAgc2VnLnR5cGUgPSAnYnV0dG9uJzsKICAgICAgICAgICAgc2VnLmNsYXNzTmFtZSA9ICdy
Zi1zZWcnOwogICAgICAgICAgICBzZXRIbFRleHQoc2VnLCBsYWJlbCk7CiAgICAgICAgICAgIHNlZy50
aXRsZSA9ICfmiZPlvIA6ICcgKyBvcGVuUGF0aDsKICAgICAgICAgICAgc2VnLnNldEF0dHJpYnV0ZSgn
ZGF0YS1wYXRoJywgb3BlblBhdGgucmVwbGFjZSgvXFwvZywgJy8nKSk7CiAgICAgICAgICAgIHNlZy5f
b3BlblBhdGggPSBvcGVuUGF0aDsKICAgICAgICAgICAgc2VnLmFkZEV2ZW50TGlzdGVuZXIoJ2NsaWNr
JywgZSA9PiB7CiAgICAgICAgICAgICAgICBlLnByZXZlbnREZWZhdWx0KCk7CiAgICAgICAgICAgICAg
ICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgICAgICAgICAgICAgb3BlblJlY2VudERpcihvcGVuUGF0
aCk7CiAgICAgICAgICAgIH0sIHRydWUpOwogICAgICAgICAgICBzZWcuYWRkRXZlbnRMaXN0ZW5lcign
cG9pbnRlcmRvd24nLCBlID0+IHsKICAgICAgICAgICAgICAgIGlmIChlLmJ1dHRvbiAhPT0gMCkgcmV0
dXJuOwogICAgICAgICAgICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOwogICAgICAgICAgICAgICAgZS5z
dG9wUHJvcGFnYXRpb24oKTsKICAgICAgICAgICAgICAgIG9wZW5SZWNlbnREaXIob3BlblBhdGgpOwog
ICAgICAgICAgICB9LCB0cnVlKTsKICAgICAgICAgICAgY29udGFpbmVyLmFwcGVuZENoaWxkKHNlZyk7
CiAgICAgICAgfTsKICAgICAgICBpZiAoIXBhcnRzLmxlbmd0aCkgewogICAgICAgICAgICBhZGRTZWco
cmF3LCByYXcpOwogICAgICAgICAgICByZXR1cm47CiAgICAgICAgfQogICAgICAgIGxldCBhY2MgPSB1
bmMgPyAnXFxcXCcgKyBwYXJ0c1swXSA6IHBhcnRzWzBdOwogICAgICAgIGlmICghdW5jICYmIC9eW2Et
ekEtWl06JC8udGVzdChwYXJ0c1swXSkpCiAgICAgICAgICAgIGFjYyA9IHBhcnRzWzBdICsgJ1xcJzsK
ICAgICAgICBhZGRTZWcocGFydHNbMF0sIGFjYyk7CiAgICAgICAgZm9yIChsZXQgaSA9IDE7IGkgPCBw
YXJ0cy5sZW5ndGg7IGkrKykgewogICAgICAgICAgICBhY2MgPSBhY2MucmVwbGFjZSgvXFwrJC8sICcn
KSArICdcXCcgKyBwYXJ0c1tpXTsKICAgICAgICAgICAgYWRkU2VnKHBhcnRzW2ldLCBhY2MpOwogICAg
ICAgIH0KICAgIH0KCiAgICBmdW5jdGlvbiBhY3RpdmF0ZUNsaXBJdGVtKGMpIHsKICAgICAgICBpZiAo
IWMpIHJldHVybjsKICAgICAgICBpZiAobm9ybVR5cGUoYy50eXBlKSA9PT0gJ3JlY2VudCcpIHsKICAg
ICAgICAgICAgX19wcmVwUGFzdGUoKTsKICAgICAgICAgICAgc2VsZWN0ZWRJZCA9IGMuaWQ7CiAgICAg
ICAgICAgIGlmIChtdWx0aUlkcy5sZW5ndGgpIGNsZWFyTXVsdGkoKTsKICAgICAgICAgICAgc3luY0l0
ZW1IaWdobGlnaHQoKTsKICAgICAgICAgICAgYWhrKCdwYXN0ZScsIFN0cmluZyhjLmlkKSk7CiAgICAg
ICAgICAgIHJldHVybjsKICAgICAgICB9CiAgICAgICAgcGFzdGVPbmUoYyk7CiAgICB9CiAgICBmdW5j
dGlvbiBtYWtlSXRlbShjLCBpZHgpIHsKICAgICAgICBjb25zdCB0eXBlICAgPSBub3JtVHlwZShjLnR5
cGUpOwogICAgICAgIGNvbnN0IHBpbm5lZCA9IGlzUGlubmVkKGMpOwogICAgICAgIGNvbnN0IHBhc3Rl
ZCA9IGlzUGFzdGVkKGMpOwogICAgICAgIGNvbnN0IGVsICAgICA9IGRvY3VtZW50LmNyZWF0ZUVsZW1l
bnQoJ2RpdicpOwogICAgICAgIGVsLmNsYXNzTmFtZSAgPSAnaXRtJwogICAgICAgICAgICArIChzZWxl
Y3RlZElkID09IGMuaWQgPyAnIHNlbCcgOiAnJykKICAgICAgICAgICAgKyAobXVsdGlJZHMuaW5jbHVk
ZXMoK2MuaWQpID8gJyBtdWx0aScgOiAnJykKICAgICAgICAgICAgKyAocGlubmVkID8gJyBpcy1waW5u
ZWQnIDogJycpOwogICAgICAgIGVsLmRhdGFzZXQuaWQgPSBjLmlkOwogICAgICAgIGNvbnN0IHFnID0g
TnVtYmVyKGMucXVldWVHcm91cCkgfHwgMDsKICAgICAgICBpZiAocWcgPiAwKSB7CiAgICAgICAgICAg
IGVsLmNsYXNzTGlzdC5hZGQoJ3EtbWVtYmVyJyk7CiAgICAgICAgICAgIGVsLmRhdGFzZXQucWcgPSBT
dHJpbmcocWcpOwogICAgICAgICAgICBlbC5kYXRhc2V0LnFpID0gU3RyaW5nKE51bWJlcihjLnF1ZXVl
SW5kZXgpIHx8IDApOwogICAgICAgICAgICBpZiAocGFzdGVkKSBlbC5jbGFzc0xpc3QuYWRkKCdxLWRv
bmUnKTsKICAgICAgICAgICAgY29uc3QgcmFpbCA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ3NwYW4n
KTsKICAgICAgICAgICAgcmFpbC5jbGFzc05hbWUgPSAncS1yYWlsJzsKICAgICAgICAgICAgY29uc3Qg
ZG90ID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnc3BhbicpOwogICAgICAgICAgICBkb3QuY2xhc3NO
YW1lID0gJ3EtZG90JzsKICAgICAgICAgICAgZG90LnRpdGxlID0gcGFzdGVkID8gJ+mYn+WIl+W3suey
mOi0tCcgOiAn57KY6LS06Zif5YiXJzsKICAgICAgICAgICAgZWwuYXBwZW5kQ2hpbGQocmFpbCk7CiAg
ICAgICAgICAgIGVsLmFwcGVuZENoaWxkKGRvdCk7CiAgICAgICAgfQoKICAgICAgICBjb25zdCBpY28g
ID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnZGl2Jyk7CiAgICAgICAgY29uc3QgYm9keSA9IGRvY3Vt
ZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOwogICAgICAgIGJvZHkuY2xhc3NOYW1lID0gJ2ktYm9keSc7
CgogICAgICAgIGlmICh0eXBlID09PSAnaW1hZ2UnKSB7CiAgICAgICAgICAgIGljby5jbGFzc05hbWUg
PSAnaS1pY28gaW1hZ2UnOwogICAgICAgICAgICBpY28uaW5uZXJIVE1MID0gU1ZHLmltYWdlOwogICAg
ICAgICAgICBiaW5kSW1nSG92ZXJQcmV2aWV3KGljbywgYy5pZCwgYy5pbWdGaWxlKTsKICAgICAgICAg
ICAgY29uc3Qgd3JhcCA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOwogICAgICAgICAgICB3
cmFwLmNsYXNzTmFtZSA9ICdpLXRodW1iLXdyYXAnOwogICAgICAgICAgICBjb25zdCBpbWcgID0gZG9j
dW1lbnQuY3JlYXRlRWxlbWVudCgnaW1nJyk7CiAgICAgICAgICAgIGltZy5jbGFzc05hbWUgPSAnaS10
aHVtYic7CiAgICAgICAgICAgIGltZy5hbHQgPSAnJzsKICAgICAgICAgICAgY29uc3QgZmlsZSA9IFN0
cmluZyhjLmltZ0ZpbGUgfHwgJycpOwogICAgICAgICAgICBsZXQgZmFsbGJhY2sgPSBTdHJpbmcoYy5k
YXRhIHx8ICcnKTsKICAgICAgICAgICAgLy8gTmV2ZXIgc3luYy1jYWxsIEFISyB0aHVtYiBoZXJlIOKA
lCBmcmVlemVzIHRhYiBzd2l0Y2hlczsgUHVzaFN0b3JlVGh1bWJzIGZpbGxzIGFzeW5jCiAgICAgICAg
ICAgIGlmICghZmFsbGJhY2suc3RhcnRzV2l0aCgnZGF0YTonKSAmJiB0aHVtYkNhY2hlLmhhcyhTdHJp
bmcoYy5pZCkpKQogICAgICAgICAgICAgICAgZmFsbGJhY2sgPSBTdHJpbmcodGh1bWJDYWNoZS5nZXQo
U3RyaW5nKGMuaWQpKSk7CiAgICAgICAgICAgIGltZy5vbmxvYWQgPSAoKSA9PiB7CiAgICAgICAgICAg
ICAgICBjb25zdCBtdyA9IHdyYXAuY2xpZW50V2lkdGggfHwgMzAwOwogICAgICAgICAgICAgICAgY29u
c3QgbncgPSBpbWcubmF0dXJhbFdpZHRoICB8fCAwOwogICAgICAgICAgICAgICAgY29uc3QgbmggPSBp
bWcubmF0dXJhbEhlaWdodCB8fCAwOwogICAgICAgICAgICAgICAgaWYgKCFudyB8fCAhbmgpIHJldHVy
bjsKICAgICAgICAgICAgICAgIGNvbnN0IHNjYWxlID0gTWF0aC5taW4oMSwgMTgwIC8gbmgsIG13IC8g
bncpOwogICAgICAgICAgICAgICAgaW1nLnN0eWxlLndpZHRoICA9IE1hdGgucm91bmQobncgKiBzY2Fs
ZSkgKyAncHgnOwogICAgICAgICAgICAgICAgaW1nLnN0eWxlLmhlaWdodCA9IE1hdGgucm91bmQobmgg
KiBzY2FsZSkgKyAncHgnOwogICAgICAgICAgICB9OwogICAgICAgICAgICBiaW5kU3RvcmVUaHVtYihp
bWcsIGZpbGUsIGMuaWQsIGZhbGxiYWNrKTsKICAgICAgICAgICAgd3JhcC5hcHBlbmRDaGlsZChpbWcp
OwogICAgICAgICAgICBjb25zdCBtZXRhID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnZGl2Jyk7CiAg
ICAgICAgICAgIG1ldGEuY2xhc3NOYW1lID0gJ2ktbWV0YSc7CiAgICAgICAgICAgIG1ldGEuaW5uZXJI
VE1MICA9IGA8c3BhbiBjbGFzcz0iaS10aW1lIj4ke2FnbyhjLnRpbWUpfTwvc3Bhbj4ke21ldGFDZW50
ZXJIdG1sKGZhbHNlKX08ZGl2IGNsYXNzPSJpLW1ldGEtcmlnaHQiPiR7Yy53aWR0aCA/IGA8c3BhbiBj
bGFzcz0iaS10YWciPiR7Yy53aWR0aH3DlyR7Yy5oZWlnaHR9IHB4PC9zcGFuPmAgOiAnJ308L2Rpdj5g
OwogICAgICAgICAgICBib2R5LmFwcGVuZENoaWxkKHdyYXApOwogICAgICAgICAgICBib2R5LmFwcGVu
ZENoaWxkKG1ldGEpOwogICAgICAgIH0gZWxzZSBpZiAodHlwZSA9PT0gJ3JlY2VudCcpIHsKICAgICAg
ICAgICAgaWNvLmNsYXNzTmFtZSA9ICdpLWljbyBmaWxlIGZ0LWRpcic7CiAgICAgICAgICAgIGljby5p
bm5lckhUTUwgPSBTVkcuZm9sZGVyOwogICAgICAgICAgICBpZiAocGlubmVkKSBlbC5jbGFzc0xpc3Qu
YWRkKCdyZi1maXhlZCcpOwogICAgICAgICAgICBjb25zdCBwYXRoID0gU3RyaW5nKGMuZGF0YSB8fCBj
LnByZXZpZXcgfHwgJycpOwogICAgICAgICAgICBjb25zdCBjcnVtYnMgPSBkb2N1bWVudC5jcmVhdGVF
bGVtZW50KCdkaXYnKTsKICAgICAgICAgICAgY3J1bWJzLmNsYXNzTmFtZSA9ICdyZi1wYXRoJzsKICAg
ICAgICAgICAgYnVpbGRSZWNlbnRQYXRoQ3J1bWJzKGNydW1icywgcGF0aCk7CiAgICAgICAgICAgIC8v
IOWbuuWumuagh+iusOWPquaUviBtZXRhIOWPs+S+p++8jOS4jeaMoei3r+W+hAogICAgICAgICAgICBj
b25zdCBtZXRhID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnZGl2Jyk7CiAgICAgICAgICAgIG1ldGEu
Y2xhc3NOYW1lID0gJ2ktbWV0YSc7CiAgICAgICAgICAgIG1ldGEuaW5uZXJIVE1MID0KICAgICAgICAg
ICAgICAgIGA8c3BhbiBjbGFzcz0iaS10aW1lIj4ke2FnbyhjLnRpbWUpfTwvc3Bhbj5gICsKICAgICAg
ICAgICAgICAgIG1ldGFDZW50ZXJIdG1sKGZhbHNlKSArCiAgICAgICAgICAgICAgICBgPGRpdiBjbGFz
cz0iaS1tZXRhLXJpZ2h0Ij4ke3Bpbm5lZCA/ICc8c3BhbiBjbGFzcz0icmYtcGluLXRhZyIgdGl0bGU9
IuW3suWbuuWumu+8jOS4jeS8muiiq+a3mOaxsCI+5Zu65a6aPC9zcGFuPicgOiAnJ308L2Rpdj5gOwog
ICAgICAgICAgICBib2R5LmFwcGVuZENoaWxkKGNydW1icyk7CiAgICAgICAgICAgIGJvZHkuYXBwZW5k
Q2hpbGQobWV0YSk7CiAgICAgICAgfSBlbHNlIGlmICh0eXBlID09PSAnZmlsZScpIHsKICAgICAgICAg
ICAgY29uc3QgZmlsZXMgPSBTdHJpbmcoYy5wcmV2aWV3IHx8IGMuZGF0YSB8fCAnJykuc3BsaXQoL1xy
P1xuLykuZmlsdGVyKEJvb2xlYW4pOwogICAgICAgICAgICBjb25zdCBpbWFnZVBhdGhzID0gZmlsZXMu
ZmlsdGVyKGYgPT4gaXNJbWFnZUV4dChmaWxlRXh0KGYpKSk7CiAgICAgICAgICAgIGNvbnN0IGljICAg
ID0gaWNvbkZvckZpbGVzKGZpbGVzKTsKICAgICAgICAgICAgaWNvLmNsYXNzTmFtZSA9ICdpLWljbyAn
ICsgaWMuY2xzOwogICAgICAgICAgICBpY28uaW5uZXJIVE1MID0gaWMuc3ZnOwoKICAgICAgICAgICAg
bGV0IHRodW1iRmlsZSA9IFN0cmluZyhjLmltZ0ZpbGUgfHwgJycpOwogICAgICAgICAgICAvKiBlbnN1
cmVGaWxlSW1nIGRlZmVycmVkOiBhdm9pZCBzeW5jIGZyZWV6ZSBvbiBmaWxlIHRhYiAqLwoKICAgICAg
ICAgICAgLy8gSW1hZ2UtZm9ybWF0IGZpbGVzOiBzYW1lIHRodW1ibmFpbCBydWxlcyBhcyBzY3JlZW5z
aG90IGNsaXBzCiAgICAgICAgICAgIGlmICh0aHVtYkZpbGUgfHwgaW1hZ2VQYXRocy5sZW5ndGgpIHsK
ICAgICAgICAgICAgICAgIGNvbnN0IHdyYXAgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsK
ICAgICAgICAgICAgICAgIHdyYXAuY2xhc3NOYW1lID0gJ2ktdGh1bWItd3JhcCc7CiAgICAgICAgICAg
ICAgICBjb25zdCBpbWcgID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnaW1nJyk7CiAgICAgICAgICAg
ICAgICBpbWcuY2xhc3NOYW1lID0gJ2ktdGh1bWInOwogICAgICAgICAgICAgICAgaW1nLmFsdCA9ICcn
OwogICAgICAgICAgICAgICAgaW1nLm9ubG9hZCA9ICgpID0+IHsKICAgICAgICAgICAgICAgICAgICBj
b25zdCBtdyA9IHdyYXAuY2xpZW50V2lkdGggfHwgMzAwOwogICAgICAgICAgICAgICAgICAgIGNvbnN0
IG53ID0gaW1nLm5hdHVyYWxXaWR0aCAgfHwgMDsKICAgICAgICAgICAgICAgICAgICBjb25zdCBuaCA9
IGltZy5uYXR1cmFsSGVpZ2h0IHx8IDA7CiAgICAgICAgICAgICAgICAgICAgaWYgKCFudyB8fCAhbmgp
IHJldHVybjsKICAgICAgICAgICAgICAgICAgICBjb25zdCBzY2FsZSA9IE1hdGgubWluKDEsIDE4MCAv
IG5oLCBtdyAvIG53KTsKICAgICAgICAgICAgICAgICAgICBpbWcuc3R5bGUud2lkdGggID0gTWF0aC5y
b3VuZChudyAqIHNjYWxlKSArICdweCc7CiAgICAgICAgICAgICAgICAgICAgaW1nLnN0eWxlLmhlaWdo
dCA9IE1hdGgucm91bmQobmggKiBzY2FsZSkgKyAncHgnOwogICAgICAgICAgICAgICAgfTsKICAgICAg
ICAgICAgLyogZW5zdXJlRmlsZUltZyBkZWZlcnJlZDogYXZvaWQgc3luYyBmcmVlemUgb24gZmlsZSB0
YWIgKi8KICAgICAgICAgICAgICAgIGJpbmRTdG9yZVRodW1iKGltZywgdGh1bWJGaWxlLCBjLmlkLCAn
Jyk7CiAgICAgICAgICAgICAgICB3cmFwLmFwcGVuZENoaWxkKGltZyk7CiAgICAgICAgICAgICAgICBi
b2R5LmFwcGVuZENoaWxkKHdyYXApOwogICAgICAgICAgICB9CgogICAgICAgICAgICBjb25zdCBuYW1l
ID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnZGl2Jyk7CiAgICAgICAgICAgIG5hbWUuY2xhc3NOYW1l
ICA9ICdpLW5hbWUnOwogICAgICAgICAgICBzZXRIbFRleHQobmFtZSwgZmlsZXMubWFwKGYgPT4gZi5z
cGxpdCgvW1xcL10vKS5wb3AoKSkuam9pbignXG4nKSB8fCAnKOaWh+S7tiknKTsKCiAgICAgICAgICAg
IGVsLl9maWxlUGF0aHMgPSBmaWxlczsKCiAgICAgICAgICAgIGNvbnN0IGRldGFpbCA9IGRvY3VtZW50
LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOwogICAgICAgICAgICBkZXRhaWwuY2xhc3NOYW1lID0gJ2ktZmls
ZS1kZXRhaWwnOwoKICAgICAgICAgICAgY29uc3QgbWV0YSA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQo
J2RpdicpOwogICAgICAgICAgICBtZXRhLmNsYXNzTmFtZSA9ICdpLW1ldGEnOwogICAgICAgICAgICBs
ZXQgcmlnaHQgPSAnJzsKICAgICAgICAgICAgcmlnaHQgKz0gYDxzcGFuIGNsYXNzPSJpLXRhZyI+JHtj
LmZpbGVDb3VudCB8fCBmaWxlcy5sZW5ndGggfHwgMX0g5Liq5paH5Lu2PC9zcGFuPmA7CiAgICAgICAg
ICAgIGlmICgodGh1bWJGaWxlIHx8IGltYWdlUGF0aHMubGVuZ3RoKSAmJiBjLndpZHRoKQogICAgICAg
ICAgICAgICAgcmlnaHQgKz0gYDxzcGFuIGNsYXNzPSJpLXRhZyI+JHtjLndpZHRofcOXJHtjLmhlaWdo
dH0gcHg8L3NwYW4+YDsKICAgICAgICAgICAgY29uc3QgZXhwYW5kSHRtbCA9IGV4cGFuZENoZXZyb24o
ZmFsc2UpOwogICAgICAgICAgICBjb25zdCBjb2xsYXBzZUh0bWwgPSBleHBhbmRDaGV2cm9uKHRydWUp
OwogICAgICAgICAgICBtZXRhLmlubmVySFRNTCA9CiAgICAgICAgICAgICAgICBgPHNwYW4gY2xhc3M9
ImktdGltZSI+JHthZ28oYy50aW1lKX08L3NwYW4+YCArCiAgICAgICAgICAgICAgICBtZXRhQ2VudGVy
SHRtbCh7IG9uOiB0cnVlLCBodG1sOiBleHBhbmRIdG1sIH0pICsKICAgICAgICAgICAgICAgIGA8ZGl2
IGNsYXNzPSJpLW1ldGEtcmlnaHQiPiR7cmlnaHR9PC9kaXY+YDsKCiAgICAgICAgICAgIGNvbnN0IGV4
cEJ0biA9IG1ldGEucXVlcnlTZWxlY3RvcignLmktZXhwYW5kLWJ0bicpOwogICAgICAgICAgICBsZXQg
ZGV0YWlsQnVpbHQgPSBmYWxzZTsKICAgICAgICAgICAgZXhwQnRuLm9uY2xpY2sgPSBlID0+IHsKICAg
ICAgICAgICAgICAgIGUucHJldmVudERlZmF1bHQoKTsKICAgICAgICAgICAgICAgIGUuc3RvcFByb3Bh
Z2F0aW9uKCk7CiAgICAgICAgICAgICAgICBjb25zdCBvcGVuID0gIWRldGFpbC5jbGFzc0xpc3QuY29u
dGFpbnMoJ29uJyk7CiAgICAgICAgICAgICAgICBpZiAob3BlbiAmJiAhZGV0YWlsQnVpbHQpIHsKICAg
ICAgICAgICAgICAgICAgICBjb25zdCBwYXRoUm93cyA9IGVsLl9wYXRoUm93cyB8fCBjaGVja0ZpbGVQ
YXRocyhlbC5fZmlsZVBhdGhzIHx8IGZpbGVzKTsKICAgICAgICAgICAgICAgICAgICBmaWxsRmlsZURl
dGFpbFBhbmVsKGRldGFpbCwgcGF0aFJvd3MpOwogICAgICAgICAgICAgICAgICAgIGRldGFpbEJ1aWx0
ID0gdHJ1ZTsKICAgICAgICAgICAgICAgIH0KICAgICAgICAgICAgICAgIGRldGFpbC5jbGFzc0xpc3Qu
dG9nZ2xlKCdvbicsIG9wZW4pOwogICAgICAgICAgICAgICAgaWYgKG9wZW4pIHsKICAgICAgICAgICAg
ICAgICAgICBkZXRhaWwuc3R5bGUubWF4SGVpZ2h0ID0gbGlzdEV4cGFuZE1heFB4KCkgKyAncHgnOwog
ICAgICAgICAgICAgICAgICAgIGRldGFpbC5zdHlsZS5vdmVyZmxvdyA9ICdhdXRvJzsKICAgICAgICAg
ICAgICAgIH0gZWxzZSB7CiAgICAgICAgICAgICAgICAgICAgZGV0YWlsLnN0eWxlLm1heEhlaWdodCA9
ICcnOwogICAgICAgICAgICAgICAgICAgIGRldGFpbC5zdHlsZS5vdmVyZmxvdyA9ICcnOwogICAgICAg
ICAgICAgICAgfQogICAgICAgICAgICAgICAgZXhwQnRuLmlubmVySFRNTCA9IG9wZW4gPyBjb2xsYXBz
ZUh0bWwgOiBleHBhbmRIdG1sOwogICAgICAgICAgICB9OwoKICAgICAgICAgICAgYm9keS5hcHBlbmRD
aGlsZChuYW1lKTsKICAgICAgICAgICAgYm9keS5hcHBlbmRDaGlsZChkZXRhaWwpOwogICAgICAgICAg
ICBib2R5LmFwcGVuZENoaWxkKG1ldGEpOwogICAgICAgIH0gZWxzZSB7CiAgICAgICAgICAgIGNvbnN0
IHVzZU0gPSBjbGlwVXNlc01JY29uKGMpOwogICAgICAgICAgICBpY28uY2xhc3NOYW1lID0gdXNlTSA/
ICdpLWljbyBtZCcgOiAnaS1pY28gdGV4dCc7CiAgICAgICAgICAgIGljby5pbm5lckhUTUwgPSB1c2VN
ID8gKFNWRy5tZCB8fCBTVkcudGV4dCkgOiBTVkcudGV4dDsKICAgICAgICAgICAgLyogcGxhaW4tbGlz
dC1wcmV2ICovCiAgICAgICAgICAgIC8qIHByZXZpZXctZWxsaXBzaXMgKi8KICAgICAgICAgICAgbGV0
IHR4dCAgPSBjLnByZXZpZXcgfHwgYy5kYXRhIHx8ICcnOwogICAgICAgICAgICB7IGNvbnN0IF9uID0g
TnVtYmVyKGMuY2hhckNvdW50KSB8fCAwOyBpZiAoX24gPiB0eHQubGVuZ3RoICYmIHR4dC5sZW5ndGgp
IHR4dCArPSAnLi4uJzsgfQogICAgICAgICAgICBjb25zdCBwcmV2ID0gZG9jdW1lbnQuY3JlYXRlRWxl
bWVudCgnZGl2Jyk7CiAgICAgICAgICAgIHByZXYuY2xhc3NOYW1lICA9ICdpLXByZXYnICsgKGlzVXJs
KHR4dCkgPyAnIHVybCcgOiAnJyk7CiAgICAgICAgICAgIHNldEhsVGV4dChwcmV2LCB0eHQpOwoKICAg
ICAgICAgICAgY29uc3QgbWV0YSA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOwogICAgICAg
ICAgICBtZXRhLmNsYXNzTmFtZSA9ICdpLW1ldGEnOwoKICAgICAgICAgICAgY29uc3QgY2hhcnMgPSBO
dW1iZXIoYy5jaGFyQ291bnQpIHx8IDA7CiAgICAgICAgICAgIGNvbnN0IHJpZ2h0SFRNTCA9IGA8c3Bh
biBjbGFzcz0iaS1jaGFycyI+PHNwYW4gY2xhc3M9Im4iPiR7Y2hhcnN9PC9zcGFuPiDlrZfnrKY8L3Nw
YW4+YDsKCiAgICAgICAgICAgIG1ldGEuaW5uZXJIVE1MID0KICAgICAgICAgICAgICAgIGA8c3BhbiBj
bGFzcz0iaS10aW1lIj4ke2FnbyhjLnRpbWUpfTwvc3Bhbj5gICsKICAgICAgICAgICAgICAgIG1ldGFD
ZW50ZXJIdG1sKHsKICAgICAgICAgICAgICAgICAgICBvbjogZmFsc2UsCiAgICAgICAgICAgICAgICAg
ICAgaHRtbDogZXhwYW5kQ2hldnJvbihmYWxzZSkKICAgICAgICAgICAgICAgIH0pICsKICAgICAgICAg
ICAgICAgIGA8ZGl2IGNsYXNzPSJpLW1ldGEtcmlnaHQgdGV4dC1tZXRhIj4ke3JpZ2h0SFRNTH08L2Rp
dj5gOwoKICAgICAgICAgICAgYm9keS5hcHBlbmRDaGlsZChwcmV2KTsKICAgICAgICAgICAgYm9keS5h
cHBlbmRDaGlsZChtZXRhKTsKCiAgICAgICAgICAgIGNvbnN0IGV4cEJ0biA9IG1ldGEucXVlcnlTZWxl
Y3RvcignLmktZXhwYW5kLWJ0bicpOwogICAgICAgICAgICBpZiAoZXhwQnRuKSB7CiAgICAgICAgICAg
ICAgICBleHBCdG4ub25jbGljayA9IGUgPT4gewogICAgICAgICAgICAgICAgICAgIGUuc3RvcFByb3Bh
Z2F0aW9uKCk7CiAgICAgICAgICAgICAgICAgICAgY29uc3Qgd2lsbEV4cGFuZCA9ICFwcmV2LmNsYXNz
TGlzdC5jb250YWlucygnZXhwYW5kZWQnKTsKICAgICAgICAgICAgICAgICAgICBpZiAod2lsbEV4cGFu
ZCkgewogICAgICAgICAgICAgICAgICAgICAgICBhcHBseUV4cGFuZGVkUHJldmlldyhwcmV2LCB0eHQp
OwogICAgICAgICAgICAgICAgICAgICAgICBleHBCdG4uaW5uZXJIVE1MID0gZXhwYW5kQ2hldnJvbih0
cnVlKTsKICAgICAgICAgICAgICAgICAgICAgICAgdHJ5IHsgZWwuc2Nyb2xsSW50b1ZpZXcoeyBibG9j
azogJ25lYXJlc3QnIH0pOyB9IGNhdGNoIHt9CiAgICAgICAgICAgICAgICAgICAgfSBlbHNlIHsKICAg
ICAgICAgICAgICAgICAgICAgICAgY29sbGFwc2VQcmV2aWV3KHByZXYsIHR4dCk7CiAgICAgICAgICAg
ICAgICAgICAgICAgIGV4cEJ0bi5pbm5lckhUTUwgPSBleHBhbmRDaGV2cm9uKGZhbHNlKTsKICAgICAg
ICAgICAgICAgICAgICB9CiAgICAgICAgICAgICAgICB9OwogICAgICAgICAgICAgICAgY29uc3QgY2hl
Y2tPdmVyZmxvdyA9ICgpID0+IHsKICAgICAgICAgICAgICAgICAgICBjb25zdCBwbGFpbkxlbiA9IFN0
cmluZyhjLnByZXZpZXcgfHwgYy5kYXRhIHx8ICcnKS5sZW5ndGg7CiAgICAgICAgICAgICAgICAgICAg
Y29uc3QgZnVsbE4gPSBOdW1iZXIoYy5jaGFyQ291bnQpIHx8IDA7CiAgICAgICAgICAgICAgICAgICAg
Y29uc3QgdHJ1bmMgPSBmdWxsTiA+IHBsYWluTGVuOwogICAgICAgICAgICAgICAgICAgIGlmIChwcmV2
LnNjcm9sbEhlaWdodCA+IHByZXYuY2xpZW50SGVpZ2h0ICsgMiB8fCB0cnVuYykKICAgICAgICAgICAg
ICAgICAgICAgICAgZXhwQnRuLmNsYXNzTGlzdC5hZGQoJ29uJyk7CiAgICAgICAgICAgICAgICAgICAg
ZWxzZQogICAgICAgICAgICAgICAgICAgICAgICBleHBCdG4uY2xhc3NMaXN0LnJlbW92ZSgnb24nKTsK
ICAgICAgICAgICAgICAgIH07CiAgICAgICAgICAgICAgICByZXF1ZXN0QW5pbWF0aW9uRnJhbWUoY2hl
Y2tPdmVyZmxvdyk7CiAgICAgICAgICAgICAgICBzZXRUaW1lb3V0KGNoZWNrT3ZlcmZsb3csIDgwKTsK
ICAgICAgICAgICAgfQogICAgICAgIH0KCiAgICAgICAgY29uc3QgZmF2VCA9IFN0cmluZyhjLmZhdlRp
dGxlIHx8ICcnKS50cmltKCk7CiAgICAgICAgaWYgKGZhdlQpIHsKICAgICAgICAgICAgY29uc3QgZnQg
PSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsKICAgICAgICAgICAgZnQuY2xhc3NOYW1lID0g
J2ktZmF2LXRpdGxlJzsKICAgICAgICAgICAgc2V0SGxUZXh0KGZ0LCBmYXZUKTsKICAgICAgICAgICAg
Ym9keS5pbnNlcnRCZWZvcmUoZnQsIGJvZHkuZmlyc3RDaGlsZCk7CiAgICAgICAgfQoKICAgICAgICBp
ZiAocGlubmVkKSB7CiAgICAgICAgICAgIGNvbnN0IGZhdkJhZGdlID0gZG9jdW1lbnQuY3JlYXRlRWxl
bWVudCgnc3BhbicpOwogICAgICAgICAgICBmYXZCYWRnZS5jbGFzc05hbWUgPSAnaS1mYXYnOwogICAg
ICAgICAgICBmYXZCYWRnZS50aXRsZSA9ICflt7LmlLbol48nOwogICAgICAgICAgICBmYXZCYWRnZS5p
bm5lckhUTUwgPSBgPHN2ZyB2aWV3Qm94PSIwIDAgMTYgMTYiIGZpbGw9ImN1cnJlbnRDb2xvciI+PHBh
dGggZD0iTTggMTMuNlMyLjQgMTAuMSAxLjIgNi43Qy40IDQuNSAxLjkgMi40IDQuMSAyLjRjMS4zIDAg
Mi40LjcgMyAxLjguNi0xLjEgMS43LTEuOCAzLTEuOCAyLjIgMCAzLjcgMi4xIDIuOSA0LjNDMTMuNiAx
MC4xIDggMTMuNiA4IDEzLjZ6Ii8+PC9zdmc+YDsKICAgICAgICAgICAgaWNvLmFwcGVuZENoaWxkKGZh
dkJhZGdlKTsKICAgICAgICB9CgogICAgICAgIGlmIChwYXN0ZWQpIHsKICAgICAgICAgICAgZWwuY2xh
c3NMaXN0LmFkZCgncGFzdGVkJyk7CiAgICAgICAgICAgIGNvbnN0IGJhZGdlID0gZG9jdW1lbnQuY3Jl
YXRlRWxlbWVudCgnc3BhbicpOwogICAgICAgICAgICBiYWRnZS5jbGFzc05hbWUgPSAnaS11c2VkJzsK
ICAgICAgICAgICAgYmFkZ2UudGl0bGUgPSAn5bey57KY6LS0JzsKICAgICAgICAgICAgYmFkZ2UuaW5u
ZXJIVE1MID0gYDxzdmcgdmlld0JveD0iMCAwIDE2IDE2IiBmaWxsPSJub25lIiBzdHJva2U9ImN1cnJl
bnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIyLjQiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIgc3Ryb2tlLWxp
bmVqb2luPSJyb3VuZCI+PHBvbHlsaW5lIHBvaW50cz0iMy41IDguNSA2LjUgMTEuNSAxMi41IDQuNSIv
Pjwvc3ZnPmA7CiAgICAgICAgICAgIGljby5hcHBlbmRDaGlsZChiYWRnZSk7CiAgICAgICAgfQoKICAg
ICAgICBjb25zdCBudW0gPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsKICAgICAgICBudW0u
Y2xhc3NOYW1lID0gJ2ktbnVtJzsKICAgICAgICBjb25zdCBudW1UeHQgPSBkb2N1bWVudC5jcmVhdGVF
bGVtZW50KCdzcGFuJyk7CiAgICAgICAgbnVtVHh0LnRleHRDb250ZW50ID0gaWR4OwogICAgICAgIG51
bS5hcHBlbmRDaGlsZChudW1UeHQpOwogICAgICAgIGNvbnN0IHNyY0ljbyA9IFN0cmluZyhjLnNyY0lj
b24gfHwgJycpOwogICAgICAgIGNvbnN0IHNyY0V4ZSA9IFN0cmluZyhjLnNyY0V4ZSB8fCAnJyk7CiAg
ICAgICAgY29uc3Qgc3JjVGl0bGUgPSBTdHJpbmcoYy5zcmNUaXRsZSB8fCAnJyk7CiAgICAgICAgaWYg
KHNyY0ljbykgewogICAgICAgICAgICBjb25zdCBpbWcgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdp
bWcnKTsKICAgICAgICAgICAgaW1nLmNsYXNzTmFtZSA9ICdpLXNyYy1pY28nOwogICAgICAgICAgICBp
bWcuc3JjID0gU1RPUkVfQkFTRSArIGVuY29kZVVSSUNvbXBvbmVudChzcmNJY28pOwogICAgICAgICAg
ICBpbWcuYWx0ID0gJyc7CiAgICAgICAgICAgIGNvbnN0IHRpcFR4dCA9IHNyY1RpdGxlIHx8IHNyY0V4
ZSB8fCAn5p2l5rqQJzsKICAgICAgICAgICAgaW1nLnRpdGxlID0gdGlwVHh0OwogICAgICAgICAgICBp
bWcub25jbGljayA9IGUgPT4geyBlLnByZXZlbnREZWZhdWx0KCk7IGUuc3RvcFByb3BhZ2F0aW9uKCk7
IHNob3dTcmNUaXAoaW1nLCB0aXBUeHQpOyB9OwogICAgICAgICAgICBudW0uYXBwZW5kQ2hpbGQoaW1n
KTsKICAgICAgICB9CgogICAgICAgIGVsLmFwcGVuZENoaWxkKGljbyk7CiAgICAgICAgZWwuYXBwZW5k
Q2hpbGQoYm9keSk7CiAgICAgICAgZWwuYXBwZW5kQ2hpbGQobnVtKTsKCiAgICAgICAgZWwub25wb2lu
dGVyZG93biA9IGUgPT4gewogICAgICAgICAgICBiZWdpblBhc3RlRnJvbUl0ZW0oZSwgYyk7CiAgICAg
ICAgfTsKICAgICAgICBlbC5vbmNvbnRleHRtZW51ID0gZSA9PiB7CiAgICAgICAgICAgIGUucHJldmVu
dERlZmF1bHQoKTsKICAgICAgICAgICAgc2VsZWN0ZWRJZCA9IGMuaWQ7CiAgICAgICAgICAgIHNob3dD
dHgoZS5jbGllbnRYLCBlLmNsaWVudFksIGMpOwogICAgICAgIH07CgogICAgICAgIHJldHVybiBlbDsK
ICAgIH0KCiAgICBmdW5jdGlvbiBpdGVtSXNRdWV1ZURvbmUocm93KSB7CiAgICAgICAgaWYgKCFyb3cp
IHJldHVybiBmYWxzZTsKICAgICAgICBpZiAocm93LmNsYXNzTGlzdC5jb250YWlucygncGFzdGVkJykg
fHwgcm93LmNsYXNzTGlzdC5jb250YWlucygncS1kb25lJykpCiAgICAgICAgICAgIHJldHVybiB0cnVl
OwogICAgICAgIGNvbnN0IGlkID0gK3Jvdy5kYXRhc2V0LmlkOwogICAgICAgIGNvbnN0IGMgPSBhbGxD
bGlwcy5maW5kKHggPT4gK3guaWQgPT09IGlkKTsKICAgICAgICByZXR1cm4gISEoYyAmJiBpc1Bhc3Rl
ZChjKSk7CiAgICB9CgogICAgZnVuY3Rpb24gbWFya1F1ZXVlUmFpbHMoKSB7CiAgICAgICAgaWYgKCFs
aXN0RWwpIHJldHVybjsKICAgICAgICBjb25zdCBub2RlcyA9IFsuLi5saXN0RWwucXVlcnlTZWxlY3Rv
ckFsbCgnLml0bS5xLW1lbWJlcicpXTsKICAgICAgICBpZiAoIW5vZGVzLmxlbmd0aCkgcmV0dXJuOwog
ICAgICAgIC8vIFJlc2V0IGxpbmsgY2xhc3Nlczsga2VlcCBzdHJ1Y3R1cmFsIGVuZHMKICAgICAgICBu
b2Rlcy5mb3JFYWNoKG4gPT4gbi5jbGFzc0xpc3QucmVtb3ZlKCdxLWZpcnN0JywgJ3EtbGFzdCcsICdx
LW9ubHknLCAncS1kb25lLWxpbmsnLCAncS1wYXN0ZWQtbmV4dCcpKTsKICAgICAgICAvLyBHcm91cCBj
b25zZWN1dGl2ZSBzYW1lIHF1ZXVlR3JvdXAgaW4gRE9NIG9yZGVyCiAgICAgICAgbGV0IGkgPSAwOwog
ICAgICAgIHdoaWxlIChpIDwgbm9kZXMubGVuZ3RoKSB7CiAgICAgICAgICAgIGNvbnN0IGcgPSBub2Rl
c1tpXS5kYXRhc2V0LnFnOwogICAgICAgICAgICBsZXQgaiA9IGkgKyAxOwogICAgICAgICAgICB3aGls
ZSAoaiA8IG5vZGVzLmxlbmd0aCAmJiBub2Rlc1tqXS5kYXRhc2V0LnFnID09PSBnKSBqKys7CiAgICAg
ICAgICAgIGNvbnN0IHNsaWNlID0gbm9kZXMuc2xpY2UoaSwgaik7CiAgICAgICAgICAgIGlmIChzbGlj
ZS5sZW5ndGggPT09IDEpIHsKICAgICAgICAgICAgICAgIHNsaWNlWzBdLmNsYXNzTGlzdC5hZGQoJ3Et
b25seScpOwogICAgICAgICAgICB9IGVsc2UgewogICAgICAgICAgICAgICAgc2xpY2VbMF0uY2xhc3NM
aXN0LmFkZCgncS1maXJzdCcpOwogICAgICAgICAgICAgICAgc2xpY2Vbc2xpY2UubGVuZ3RoIC0gMV0u
Y2xhc3NMaXN0LmFkZCgncS1sYXN0Jyk7CiAgICAgICAgICAgIH0KICAgICAgICAgICAgZm9yIChsZXQg
ayA9IDA7IGsgPCBzbGljZS5sZW5ndGg7IGsrKykgewogICAgICAgICAgICAgICAgY29uc3QgZG9uZSA9
IGl0ZW1Jc1F1ZXVlRG9uZShzbGljZVtrXSk7CiAgICAgICAgICAgICAgICBzbGljZVtrXS5jbGFzc0xp
c3QudG9nZ2xlKCdxLWRvbmUnLCBkb25lKTsKICAgICAgICAgICAgICAgIGNvbnN0IGRvdCA9IHNsaWNl
W2tdLnF1ZXJ5U2VsZWN0b3IoJy5xLWRvdCcpOwogICAgICAgICAgICAgICAgaWYgKGRvdCkgZG90LnRp
dGxlID0gZG9uZSA/ICfpmJ/liJflt7LnspjotLQnIDogJ+eymOi0tOmYn+WIlyc7CiAgICAgICAgICAg
ICAgICAvLyBHcmVlbiByYWlsIGZvciBldmVyeSBpdGVtIGluIGEgMisgZGVxdWV1ZWQgcnVuIChpbmNs
LiBmaXJzdC9sYXN0IHN0dWJzKQogICAgICAgICAgICAgICAgY29uc3QgcHJldkRvbmUgPSBrID4gMCAm
JiBpdGVtSXNRdWV1ZURvbmUoc2xpY2VbayAtIDFdKTsKICAgICAgICAgICAgICAgIGNvbnN0IG5leHRE
b25lID0gayA8IHNsaWNlLmxlbmd0aCAtIDEgJiYgaXRlbUlzUXVldWVEb25lKHNsaWNlW2sgKyAxXSk7
CiAgICAgICAgICAgICAgICBpZiAoZG9uZSAmJiAocHJldkRvbmUgfHwgbmV4dERvbmUpKQogICAgICAg
ICAgICAgICAgICAgIHNsaWNlW2tdLmNsYXNzTGlzdC5hZGQoJ3EtZG9uZS1saW5rJyk7CiAgICAgICAg
ICAgIH0KICAgICAgICAgICAgaSA9IGo7CiAgICAgICAgfQogICAgfQoKICAgIGNvbnN0IHBhdGhUaXBF
bCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdwYXRoLXRpcCcpOwogICAgbGV0IHBhdGhUaXBUaW1l
ciA9IDA7CiAgICBsZXQgcGF0aFRpcEhpZGVUaW1lciA9IDA7CiAgICBsZXQgcGF0aFRpcFRva2VuID0g
MDsKICAgIGxldCBwYXRoVGlwQW5jaG9yQnRuID0gbnVsbDsKCiAgICBmdW5jdGlvbiBoaWRlUGF0aFRp
cCgpIHsKICAgICAgICBjbGVhclRpbWVvdXQocGF0aFRpcFRpbWVyKTsKICAgICAgICBjbGVhclRpbWVv
dXQocGF0aFRpcEhpZGVUaW1lcik7CiAgICAgICAgcGF0aFRpcFRva2VuKys7CiAgICAgICAgaWYgKHBh
dGhUaXBBbmNob3JCdG4pIHsKICAgICAgICAgICAgcGF0aFRpcEFuY2hvckJ0bi5jbGFzc0xpc3QucmVt
b3ZlKCdvbicpOwogICAgICAgICAgICBwYXRoVGlwQW5jaG9yQnRuID0gbnVsbDsKICAgICAgICB9CiAg
ICAgICAgaWYgKHBhdGhUaXBFbCkgewogICAgICAgICAgICBwYXRoVGlwRWwuY2xhc3NMaXN0LnJlbW92
ZSgnb24nKTsKICAgICAgICAgICAgcGF0aFRpcEVsLnNldEF0dHJpYnV0ZSgnYXJpYS1oaWRkZW4nLCAn
dHJ1ZScpOwogICAgICAgIH0KICAgIH0KICAgIGZ1bmN0aW9uIHBsYWNlUGF0aFRpcChhbmNob3JFbCkg
ewogICAgICAgIGlmICghcGF0aFRpcEVsIHx8ICFhbmNob3JFbCkgcmV0dXJuOwogICAgICAgIGNvbnN0
IHRpcCA9IHBhdGhUaXBFbDsKICAgICAgICBjb25zdCBhciA9IGFuY2hvckVsLmdldEJvdW5kaW5nQ2xp
ZW50UmVjdCgpOwogICAgICAgIGNvbnN0IHBhZCA9IDg7CiAgICAgICAgdGlwLnN0eWxlLmxlZnQgPSAn
MHB4JzsKICAgICAgICB0aXAuc3R5bGUudG9wID0gJzBweCc7CiAgICAgICAgdGlwLmNsYXNzTGlzdC5h
ZGQoJ29uJyk7CiAgICAgICAgY29uc3QgdHcgPSB0aXAub2Zmc2V0V2lkdGg7CiAgICAgICAgY29uc3Qg
dGggPSB0aXAub2Zmc2V0SGVpZ2h0OwogICAgICAgIGxldCBsZWZ0ID0gYXIubGVmdDsKICAgICAgICBs
ZXQgdG9wID0gYXIuYm90dG9tICsgNjsKICAgICAgICBpZiAobGVmdCArIHR3ID4gd2luZG93LmlubmVy
V2lkdGggLSBwYWQpCiAgICAgICAgICAgIGxlZnQgPSBNYXRoLm1heChwYWQsIHdpbmRvdy5pbm5lcldp
ZHRoIC0gdHcgLSBwYWQpOwogICAgICAgIGlmIChsZWZ0IDwgcGFkKSBsZWZ0ID0gcGFkOwogICAgICAg
IGlmICh0b3AgKyB0aCA+IHdpbmRvdy5pbm5lckhlaWdodCAtIHBhZCkKICAgICAgICAgICAgdG9wID0g
TWF0aC5tYXgocGFkLCBhci50b3AgLSB0aCAtIDYpOwogICAgICAgIHRpcC5zdHlsZS5sZWZ0ID0gbGVm
dCArICdweCc7CiAgICAgICAgdGlwLnN0eWxlLnRvcCA9IHRvcCArICdweCc7CiAgICB9CiAgICAgICAg
ZnVuY3Rpb24gY2hlY2tGaWxlUGF0aHMocGF0aHMpIHsKICAgICAgICBjb25zdCBsaXN0ID0gKHBhdGhz
IHx8IFtdKS5tYXAocCA9PiB7CiAgICAgICAgICAgIGxldCBwYXRoID0gU3RyaW5nKHAgfHwgJycpLnRy
aW0oKTsKICAgICAgICAgICAgaWYgKChwYXRoLnN0YXJ0c1dpdGgoJyInKSAmJiBwYXRoLmVuZHNXaXRo
KCciJykpIHx8IChwYXRoLnN0YXJ0c1dpdGgoIiciKSAmJiBwYXRoLmVuZHNXaXRoKCInIikpKQogICAg
ICAgICAgICAgICAgcGF0aCA9IHBhdGguc2xpY2UoMSwgLTEpLnRyaW0oKTsKICAgICAgICAgICAgcmV0
dXJuIHBhdGg7CiAgICAgICAgfSk7CiAgICAgICAgLy8gT25lIGhvc3Qgcm91bmQtdHJpcCBmb3IgdGhl
IHdob2xlIGxpc3Qg4oCUIE7DlyBwYXRoRXhpc3RzIGZyZWV6ZXMgZmlsZSB0YWIKICAgICAgICB0cnkg
ewogICAgICAgICAgICBjb25zdCByYXcgPSBhaGtSZXQoJ2NoZWNrUGF0aHMnLCBsaXN0LmpvaW4oJ1xu
JykpOwogICAgICAgICAgICBpZiAocmF3KSB7CiAgICAgICAgICAgICAgICBjb25zdCBwYXJzZWQgPSB0
eXBlb2YgcmF3ID09PSAnc3RyaW5nJyA/IEpTT04ucGFyc2UocmF3KSA6IHJhdzsKICAgICAgICAgICAg
ICAgIGlmIChBcnJheS5pc0FycmF5KHBhcnNlZCkgJiYgcGFyc2VkLmxlbmd0aCkgewogICAgICAgICAg
ICAgICAgICAgIHJldHVybiBsaXN0Lm1hcCgocGF0aCwgaSkgPT4gewogICAgICAgICAgICAgICAgICAg
ICAgICBjb25zdCByb3cgPSBwYXJzZWRbaV0gfHwge307CiAgICAgICAgICAgICAgICAgICAgICAgIHJl
dHVybiB7CiAgICAgICAgICAgICAgICAgICAgICAgICAgICBwYXRoOiBwYXRoIHx8IFN0cmluZyhyb3cu
cGF0aCB8fCAnJyksCiAgICAgICAgICAgICAgICAgICAgICAgICAgICBleGlzdHM6IHJvdy5leGlzdHMg
PT09IHRydWUgfHwgcm93LmV4aXN0cyA9PT0gMSB8fCByb3cuZXhpc3RzID09PSAnMScsCiAgICAgICAg
ICAgICAgICAgICAgICAgICAgICBpc0RpcjogISEocm93LmlzRGlyID09PSB0cnVlIHx8IHJvdy5pc0Rp
ciA9PT0gMSB8fCByb3cuaXNEaXIgPT09ICcxJykKICAgICAgICAgICAgICAgICAgICAgICAgfTsKICAg
ICAgICAgICAgICAgICAgICB9KTsKICAgICAgICAgICAgICAgIH0KICAgICAgICAgICAgfQogICAgICAg
IH0gY2F0Y2gge30KICAgICAgICByZXR1cm4gbGlzdC5tYXAocGF0aCA9PiB7CiAgICAgICAgICAgIGlm
ICghcGF0aCkgcmV0dXJuIHsgcGF0aCwgZXhpc3RzOiBmYWxzZSwgaXNEaXI6IGZhbHNlIH07CiAgICAg
ICAgICAgIGxldCBleGlzdHMgPSBmYWxzZTsKICAgICAgICAgICAgdHJ5IHsKICAgICAgICAgICAgICAg
IGNvbnN0IGZsYWcgPSBTdHJpbmcoYWhrUmV0KCdwYXRoRXhpc3RzJywgcGF0aCkgPz8gJycpLnRyaW0o
KS50b0xvd2VyQ2FzZSgpOwogICAgICAgICAgICAgICAgZXhpc3RzID0gKGZsYWcgPT09ICcxJyB8fCBm
bGFnID09PSAndHJ1ZScpOwogICAgICAgICAgICB9IGNhdGNoIHt9CiAgICAgICAgICAgIHJldHVybiB7
IHBhdGgsIGV4aXN0cywgaXNEaXI6IGZhbHNlIH07CiAgICAgICAgfSk7CiAgICB9CiAgICBsZXQgZ29u
ZUNoZWNrVGltZXIgPSAwOwogICAgZnVuY3Rpb24gc2NoZWR1bGVGaWxlR29uZUNoZWNrKCkgewogICAg
ICAgIGlmIChnb25lQ2hlY2tUaW1lcikgcmV0dXJuOwogICAgICAgIGdvbmVDaGVja1RpbWVyID0gc2V0
VGltZW91dCgoKSA9PiB7CiAgICAgICAgICAgIGdvbmVDaGVja1RpbWVyID0gMDsKICAgICAgICAgICAg
Y29uc3Qgbm9kZXMgPSBbLi4ubGlzdEVsLnF1ZXJ5U2VsZWN0b3JBbGwoJy5pdG0nKV0uZmlsdGVyKG4g
PT4gbi5fZmlsZVBhdGhzICYmIG4uX2ZpbGVQYXRocy5sZW5ndGgpOwogICAgICAgICAgICBpZiAoIW5v
ZGVzLmxlbmd0aCkgcmV0dXJuOwogICAgICAgICAgICBjb25zdCB1bmlxdWUgPSBbXTsKICAgICAgICAg
ICAgY29uc3Qgc2VlbiA9IG5ldyBTZXQoKTsKICAgICAgICAgICAgbm9kZXMuZm9yRWFjaChuID0+IHsK
ICAgICAgICAgICAgICAgIG4uX2ZpbGVQYXRocy5mb3JFYWNoKHAgPT4gewogICAgICAgICAgICAgICAg
ICAgIGNvbnN0IHBhdGggPSBTdHJpbmcocCB8fCAnJyk7CiAgICAgICAgICAgICAgICAgICAgaWYgKCFw
YXRoIHx8IHNlZW4uaGFzKHBhdGgpKSByZXR1cm47CiAgICAgICAgICAgICAgICAgICAgc2Vlbi5hZGQo
cGF0aCk7CiAgICAgICAgICAgICAgICAgICAgdW5pcXVlLnB1c2gocGF0aCk7CiAgICAgICAgICAgICAg
ICB9KTsKICAgICAgICAgICAgfSk7CiAgICAgICAgICAgIGNvbnN0IHJvd3MgPSBjaGVja0ZpbGVQYXRo
cyh1bmlxdWUpOwogICAgICAgICAgICBjb25zdCBieVBhdGggPSBuZXcgTWFwKCk7CiAgICAgICAgICAg
IHJvd3MuZm9yRWFjaChyID0+IGJ5UGF0aC5zZXQoU3RyaW5nKHIucGF0aCB8fCAnJyksIHIpKTsKICAg
ICAgICAgICAgbm9kZXMuZm9yRWFjaChuID0+IHsKICAgICAgICAgICAgICAgIGNvbnN0IHBhdGhSb3dz
ID0gbi5fZmlsZVBhdGhzLm1hcChwID0+IHsKICAgICAgICAgICAgICAgICAgICBjb25zdCBoaXQgPSBi
eVBhdGguZ2V0KFN0cmluZyhwIHx8ICcnKSk7CiAgICAgICAgICAgICAgICAgICAgcmV0dXJuIGhpdCB8
fCB7IHBhdGg6IHAsIGV4aXN0czogdHJ1ZSwgaXNEaXI6IGZhbHNlIH07CiAgICAgICAgICAgICAgICB9
KTsKICAgICAgICAgICAgICAgIG4uX3BhdGhSb3dzID0gcGF0aFJvd3M7CiAgICAgICAgICAgICAgICBj
b25zdCBhbGxHb25lID0gcGF0aFJvd3MubGVuZ3RoID4gMCAmJiBwYXRoUm93cy5ldmVyeShyID0+IHIu
ZXhpc3RzID09PSBmYWxzZSk7CiAgICAgICAgICAgICAgICBuLmNsYXNzTGlzdC50b2dnbGUoJ2dvbmUn
LCBhbGxHb25lKTsKICAgICAgICAgICAgfSk7CiAgICAgICAgfSwgNDAwKTsKICAgIH0KICAgIGZ1bmN0
aW9uIGZpbGxGaWxlRGV0YWlsUGFuZWwoY29udGFpbmVyLCByb3dzKSB7CiAgICAgICAgY29udGFpbmVy
LmlubmVySFRNTCA9ICcnOwogICAgICAgIGlmICghcm93cy5sZW5ndGgpIHsKICAgICAgICAgICAgY29u
c3QgZW1wdHkgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsKICAgICAgICAgICAgZW1wdHku
Y2xhc3NOYW1lID0gJ2ZkLXBhdGgnOwogICAgICAgICAgICBlbXB0eS50ZXh0Q29udGVudCA9ICfml6Do
t6/lvoQnOwogICAgICAgICAgICBjb250YWluZXIuYXBwZW5kQ2hpbGQoZW1wdHkpOwogICAgICAgICAg
ICByZXR1cm47CiAgICAgICAgfQogICAgICAgIHJvd3MuZm9yRWFjaChyID0+IHsKICAgICAgICAgICAg
Y29uc3QgcGF0aCA9IFN0cmluZyhyLnBhdGggfHwgJycpOwogICAgICAgICAgICBjb25zdCBtaXNzaW5n
ID0gci5leGlzdHMgPT09IGZhbHNlOwogICAgICAgICAgICBjb25zdCBibG9jayA9IGRvY3VtZW50LmNy
ZWF0ZUVsZW1lbnQoJ2RpdicpOwogICAgICAgICAgICBibG9jay5jbGFzc05hbWUgPSAnZmQtYmxvY2sn
OwoKICAgICAgICAgICAgY29uc3QgcGF0aEVsID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnZGl2Jyk7
CiAgICAgICAgICAgIHBhdGhFbC5jbGFzc05hbWUgPSAnZmQtcGF0aCcgKyAobWlzc2luZyA/ICcgZGVh
ZCcgOiAnIGxpdmUnKTsKICAgICAgICAgICAgcGF0aEVsLnRleHRDb250ZW50ID0gcGF0aCB8fCAnKOep
uui3r+W+hCknOwogICAgICAgICAgICBpZiAoIW1pc3NpbmcpIHsKICAgICAgICAgICAgICAgIHBhdGhF
bC5vbmNsaWNrID0gZSA9PiB7CiAgICAgICAgICAgICAgICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOwog
ICAgICAgICAgICAgICAgICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAgICAgICAgICAgICAgICAg
YWhrKCdvcGVuUGF0aCcsIHBhdGgpOwogICAgICAgICAgICAgICAgfTsKICAgICAgICAgICAgfQogICAg
ICAgICAgICBibG9jay5hcHBlbmRDaGlsZChwYXRoRWwpOwoKICAgICAgICAgICAgY29uc3QgYWN0aW9u
cyA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOwogICAgICAgICAgICBhY3Rpb25zLmNsYXNz
TmFtZSA9ICdmZC1hY3Rpb25zJzsKCiAgICAgICAgICAgIGNvbnN0IGNvcHlCdG4gPSBkb2N1bWVudC5j
cmVhdGVFbGVtZW50KCdidXR0b24nKTsKICAgICAgICAgICAgY29weUJ0bi50eXBlID0gJ2J1dHRvbic7
CiAgICAgICAgICAgIGNvcHlCdG4uY2xhc3NOYW1lID0gJ2ZkLWJ0bic7CiAgICAgICAgICAgIGNvcHlC
dG4uaW5uZXJIVE1MID0gJzxzcGFuIGNsYXNzPSJmZC1pY28iPvCflJc8L3NwYW4+PHNwYW4gY2xhc3M9
ImZkLXR4dCI+5aSN5Yi26Lev5b6EPC9zcGFuPic7CiAgICAgICAgICAgIGNvcHlCdG4ub25jbGljayA9
IGUgPT4gewogICAgICAgICAgICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOwogICAgICAgICAgICAgICAg
ZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICAgICAgICAgIGFoaygnY29weVBhdGgnLCBwYXRoKTsK
ICAgICAgICAgICAgICAgIGNvcHlCdG4ucXVlcnlTZWxlY3RvcignLmZkLXR4dCcpLnRleHRDb250ZW50
ID0gJ+W3suWkjeWItic7CiAgICAgICAgICAgICAgICBjb3B5QnRuLmNsYXNzTGlzdC5hZGQoJ29rJyk7
CiAgICAgICAgICAgICAgICBzZXRUaW1lb3V0KCgpID0+IHsKICAgICAgICAgICAgICAgICAgICBjb3B5
QnRuLnF1ZXJ5U2VsZWN0b3IoJy5mZC10eHQnKS50ZXh0Q29udGVudCA9ICflpI3liLbot6/lvoQnOwog
ICAgICAgICAgICAgICAgICAgIGNvcHlCdG4uY2xhc3NMaXN0LnJlbW92ZSgnb2snKTsKICAgICAgICAg
ICAgICAgIH0sIDEyMDApOwogICAgICAgICAgICB9OwogICAgICAgICAgICBhY3Rpb25zLmFwcGVuZENo
aWxkKGNvcHlCdG4pOwoKICAgICAgICAgICAgY29uc3QgZm9sZGVyQnRuID0gZG9jdW1lbnQuY3JlYXRl
RWxlbWVudCgnYnV0dG9uJyk7CiAgICAgICAgICAgIGZvbGRlckJ0bi50eXBlID0gJ2J1dHRvbic7CiAg
ICAgICAgICAgIGZvbGRlckJ0bi5jbGFzc05hbWUgPSAnZmQtYnRuJzsKICAgICAgICAgICAgZm9sZGVy
QnRuLmlubmVySFRNTCA9ICc8c3BhbiBjbGFzcz0iZmQtaWNvIj7wn5OCPC9zcGFuPjxzcGFuIGNsYXNz
PSJmZC10eHQiPuaJk+W8gOaJgOWcqOaWh+S7tuWkuTwvc3Bhbj4nOwogICAgICAgICAgICBmb2xkZXJC
dG4ub25jbGljayA9IGUgPT4gewogICAgICAgICAgICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOwogICAg
ICAgICAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICAgICAgICAgIGFoaygnb3BlbkZv
bGRlcicsIHBhdGgpOwogICAgICAgICAgICB9OwogICAgICAgICAgICBhY3Rpb25zLmFwcGVuZENoaWxk
KGZvbGRlckJ0bik7CgogICAgICAgICAgICBibG9jay5hcHBlbmRDaGlsZChhY3Rpb25zKTsKICAgICAg
ICAgICAgY29udGFpbmVyLmFwcGVuZENoaWxkKGJsb2NrKTsKICAgICAgICB9KTsKICAgIH0KCiAgICBj
b25zdCBjdHhFbCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjdHgnKTsKICAgIGZ1bmN0aW9uIHNo
b3dDdHgoeCwgeSwgYykgewogICAgICAgIGN0eENsaXAgPSBjOwogICAgICAgIHNlbGVjdGVkSWQgPSBj
LmlkOwogICAgICAgIHJhbmdlQW5jaG9ySWQgPSBjLmlkOwogICAgICAgIHJhbmdlQW5jaG9yQ2xpY2tl
ZCA9IHRydWU7CiAgICAgICAgY29uc3QgY2xlYXJCdG4gPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgn
Yy1jbGVhci1wYXN0ZWQnKTsKICAgICAgICBpZiAoY2xlYXJCdG4pIGNsZWFyQnRuLnN0eWxlLmRpc3Bs
YXkgPSBpc1Bhc3RlZChjKSA/ICcnIDogJ25vbmUnOwogICAgICAgIGNvbnN0IHFGcm9tID0gZG9jdW1l
bnQuZ2V0RWxlbWVudEJ5SWQoJ2MtcXVldWUtZnJvbScpOwogICAgICAgIGlmIChxRnJvbSkgcUZyb20u
c3R5bGUuZGlzcGxheSA9IChOdW1iZXIoYy5xdWV1ZUdyb3VwKSA+IDApID8gJycgOiAnbm9uZSc7Cgog
ICAgICAgIGNvbnN0IHBpbkJ0biA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjLXBpbicpOwogICAg
ICAgIGNvbnN0IGNvcHlCdG4gPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYy1jb3B5Jyk7CiAgICAg
ICAgY29uc3QgaXNSZWNlbnQgPSBub3JtVHlwZShjLnR5cGUpID09PSAncmVjZW50JyB8fCBjdXJUYWIg
PT09ICdyZWNlbnQnOwogICAgICAgIGlmIChjb3B5QnRuKSB7CiAgICAgICAgICAgIGNvcHlCdG4uaW5u
ZXJIVE1MID0gaXNSZWNlbnQKICAgICAgICAgICAgICAgID8gJzxzcGFuIGNsYXNzPSJjLWljbyI+8J+U
lzwvc3Bhbj7lpI3liLbot6/lvoQnCiAgICAgICAgICAgICAgICA6ICc8c3BhbiBjbGFzcz0iYy1pY28i
PuKOmDwvc3Bhbj7lpI3liLYnOwogICAgICAgICAgICBjb3B5QnRuLnN0eWxlLmRpc3BsYXkgPSAnJzsK
ICAgICAgICB9CiAgICAgICAgaWYgKHBpbkJ0bikgewogICAgICAgICAgICBpZiAoaXNSZWNlbnQpIHsK
ICAgICAgICAgICAgICAgIC8vIFJlY2VudCBmb2xkZXJzOiBwaW4gPSBrZWVwIHBhdGggKG5vdCBjbGlw
Ym9hcmQg5pS26JePKQogICAgICAgICAgICAgICAgcGluQnRuLnN0eWxlLmRpc3BsYXkgPSAnJzsKICAg
ICAgICAgICAgICAgIGNvbnN0IG9uID0gaXNQaW5uZWQoYyk7CiAgICAgICAgICAgICAgICBwaW5CdG4u
aW5uZXJIVE1MID0gb24KICAgICAgICAgICAgICAgICAgICA/ICc8c3BhbiBjbGFzcz0iYy1pY28iPuKY
hTwvc3Bhbj7lj5bmtojlm7rlrponCiAgICAgICAgICAgICAgICAgICAgOiAnPHNwYW4gY2xhc3M9ImMt
aWNvIj7imIU8L3NwYW4+5Zu65a6a6Lev5b6EJzsKICAgICAgICAgICAgfSBlbHNlIHsKICAgICAgICAg
ICAgICAgIHBpbkJ0bi5zdHlsZS5kaXNwbGF5ID0gJyc7CiAgICAgICAgICAgICAgICBjb25zdCBtdWx0
aVBpbiA9IG11bHRpSWRzLmxlbmd0aCA+IDEgJiYgbXVsdGlJZHMuaW5jbHVkZXMoK2MuaWQpOwogICAg
ICAgICAgICAgICAgY29uc3QgcGluSWRzID0gbXVsdGlQaW4gPyBtdWx0aUlkcy5zbGljZSgpIDogWytj
LmlkXTsKICAgICAgICAgICAgICAgIGxldCBhbnlPZmYgPSBmYWxzZTsKICAgICAgICAgICAgICAgIGZv
ciAoY29uc3QgcGlkIG9mIHBpbklkcykgewogICAgICAgICAgICAgICAgICAgIGNvbnN0IHggPSAoK3Bp
ZCA9PT0gK2MuaWQpID8gYyA6IGFsbENsaXBzLmZpbmQodCA9PiArdC5pZCA9PT0gK3BpZCk7CiAgICAg
ICAgICAgICAgICAgICAgaWYgKHggJiYgIWlzUGlubmVkKHgpKSB7IGFueU9mZiA9IHRydWU7IGJyZWFr
OyB9CiAgICAgICAgICAgICAgICAgICAgaWYgKCF4ICYmICtwaWQgPT09ICtjLmlkICYmICFpc1Bpbm5l
ZChjKSkgeyBhbnlPZmYgPSB0cnVlOyBicmVhazsgfQogICAgICAgICAgICAgICAgfQogICAgICAgICAg
ICAgICAgaWYgKG11bHRpUGluKSB7CiAgICAgICAgICAgICAgICAgICAgcGluQnRuLmlubmVySFRNTCA9
IGFueU9mZgogICAgICAgICAgICAgICAgICAgICAgICA/ICgnPHNwYW4gY2xhc3M9ImMtaWNvIj7imIU8
L3NwYW4+5pS26JePICgnICsgcGluSWRzLmxlbmd0aCArICcpJykKICAgICAgICAgICAgICAgICAgICAg
ICAgOiAoJzxzcGFuIGNsYXNzPSJjLWljbyI+4piFPC9zcGFuPuWPlua2iOaUtuiXjyAoJyArIHBpbklk
cy5sZW5ndGggKyAnKScpOwogICAgICAgICAgICAgICAgfSBlbHNlIHsKICAgICAgICAgICAgICAgICAg
ICBwaW5CdG4uaW5uZXJIVE1MID0gaXNQaW5uZWQoYykKICAgICAgICAgICAgICAgICAgICAgICAgPyAn
PHNwYW4gY2xhc3M9ImMtaWNvIj7imIU8L3NwYW4+5Y+W5raI5pS26JePJwogICAgICAgICAgICAgICAg
ICAgICAgICA6ICc8c3BhbiBjbGFzcz0iYy1pY28iPuKYhTwvc3Bhbj7mlLbol48nOwogICAgICAgICAg
ICAgICAgfQogICAgICAgICAgICB9CiAgICAgICAgfQogICAgICAgIGNvbnN0IHRpdGxlQnRuID0gZG9j
dW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2MtdGl0bGUnKTsKICAgICAgICBpZiAodGl0bGVCdG4pIHsKICAg
ICAgICAgICAgLy8gTm8gZmF2LXRpdGxlIGZvciByZWNlbnQgcGF0aHMKICAgICAgICAgICAgY29uc3Qg
c2hvd1RpdGxlID0gIWlzUmVjZW50ICYmIChpc1Bpbm5lZChjKSB8fCBjdXJUYWIgPT09ICdwaW5uZWQn
KTsKICAgICAgICAgICAgdGl0bGVCdG4uc3R5bGUuZGlzcGxheSA9IHNob3dUaXRsZSA/ICcnIDogJ25v
bmUnOwogICAgICAgICAgICBpZiAoc2hvd1RpdGxlKQogICAgICAgICAgICAgICAgdGl0bGVCdG4uaW5u
ZXJIVE1MID0gKFN0cmluZyhjLmZhdlRpdGxlIHx8ICcnKS50cmltKCkgPyAnPHNwYW4gY2xhc3M9ImMt
aWNvIj7inI48L3NwYW4+57yW6L6R5qCH6aKYJyA6ICc8c3BhbiBjbGFzcz0iYy1pY28iPuKcjjwvc3Bh
bj7orr7nva7moIfpopgnKTsKICAgICAgICB9CiAgICAgICAgY29uc3QgbWVyZ2VCdG4gPSBkb2N1bWVu
dC5nZXRFbGVtZW50QnlJZCgnYy1tZXJnZScpOwogICAgICAgIGNvbnN0IHVubWVyZ2VCdG4gPSBkb2N1
bWVudC5nZXRFbGVtZW50QnlJZCgnYy11bm1lcmdlJyk7CiAgICAgICAgY29uc3Qgb25QaW5uZWQgPSBj
dXJUYWIgPT09ICdwaW5uZWQnOwogICAgICAgIGlmIChtZXJnZUJ0bikKICAgICAgICAgICAgbWVyZ2VC
dG4uc3R5bGUuZGlzcGxheSA9ICghaXNSZWNlbnQgJiYgb25QaW5uZWQgJiYgbXVsdGlJZHMubGVuZ3Ro
ID49IDIpID8gJycgOiAnbm9uZSc7CiAgICAgICAgaWYgKHVubWVyZ2VCdG4pCiAgICAgICAgICAgIHVu
bWVyZ2VCdG4uc3R5bGUuZGlzcGxheSA9ICghaXNSZWNlbnQgJiYgb25QaW5uZWQgJiYgZmF2R3JvdXBP
ZihjKSkgPyAnJyA6ICdub25lJzsKICAgICAgICBjb25zdCB0b3BCdG4gPSBkb2N1bWVudC5nZXRFbGVt
ZW50QnlJZCgnYy10b3AnKTsKICAgICAgICBpZiAodG9wQnRuKQogICAgICAgICAgICB0b3BCdG4uc3R5
bGUuZGlzcGxheSA9IGlzUmVjZW50ID8gJ25vbmUnIDogJyc7CiAgICAgICAgY29uc3QgY2xlYXJCdG4y
ID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2MtY2xlYXItcGFzdGVkJyk7CiAgICAgICAgaWYgKGNs
ZWFyQnRuMiAmJiBpc1JlY2VudCkKICAgICAgICAgICAgY2xlYXJCdG4yLnN0eWxlLmRpc3BsYXkgPSAn
bm9uZSc7CiAgICAgICAgY29uc3QgcUZyb20yID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2MtcXVl
dWUtZnJvbScpOwogICAgICAgIGlmIChxRnJvbTIgJiYgaXNSZWNlbnQpCiAgICAgICAgICAgIHFGcm9t
Mi5zdHlsZS5kaXNwbGF5ID0gJ25vbmUnOwogICAgICAgIGNvbnN0IGRlbEJ0biA9IGRvY3VtZW50Lmdl
dEVsZW1lbnRCeUlkKCdjLWRlbCcpOwogICAgICAgIGlmIChkZWxCdG4pIHsKICAgICAgICAgICAgY29u
c3QgbXVsdGlEZWwgPSBtdWx0aUlkcy5sZW5ndGggPiAxICYmIG11bHRpSWRzLmluY2x1ZGVzKCtjLmlk
KTsKICAgICAgICAgICAgY29uc3QgbiA9IG11bHRpRGVsID8gbXVsdGlJZHMubGVuZ3RoIDogMTsKICAg
ICAgICAgICAgZGVsQnRuLmlubmVySFRNTCA9IG4gPiAxCiAgICAgICAgICAgICAgICA/ICgnPHNwYW4g
Y2xhc3M9ImMtaWNvIj7inJU8L3NwYW4+5Yig6ZmkICgnICsgbiArICcpJykKICAgICAgICAgICAgICAg
IDogJzxzcGFuIGNsYXNzPSJjLWljbyI+4pyVPC9zcGFuPuWIoOmZpCc7CiAgICAgICAgfQogICAgICAg
IGNvbnN0IGRhdGFXcmFwID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2MtZGF0YS13cmFwJyk7CiAg
ICAgICAgY29uc3QgZGF0YVNlcCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjLWRhdGEtc2VwJyk7
CiAgICAgICAgY29uc3Qgc2hvd0RhdGEgPSAhaXNSZWNlbnQgJiYgKG5vcm1UeXBlKGMudHlwZSkgPT09
ICd0ZXh0JyB8fCBub3JtVHlwZShjLnR5cGUpID09PSAnbGluaycpOwogICAgICAgIGlmIChkYXRhV3Jh
cCkgZGF0YVdyYXAuc3R5bGUuZGlzcGxheSA9IHNob3dEYXRhID8gJycgOiAnbm9uZSc7CiAgICAgICAg
aWYgKGRhdGFTZXApIGRhdGFTZXAuc3R5bGUuZGlzcGxheSA9IHNob3dEYXRhID8gJycgOiAnbm9uZSc7
CiAgICAgICAgaWYgKGRhdGFXcmFwKSBkYXRhV3JhcC5jbGFzc0xpc3QucmVtb3ZlKCdvcGVuJyk7CiAg
ICAgICAgY3R4RWwuY2xhc3NMaXN0LmFkZCgnb24nKTsKICAgICAgICBjdHhFbC5zdHlsZS5sZWZ0ID0g
eCArICdweCc7CiAgICAgICAgY3R4RWwuc3R5bGUudG9wICA9IHkgKyAncHgnOwogICAgICAgIHJlcXVl
c3RBbmltYXRpb25GcmFtZSgoKSA9PiB7CiAgICAgICAgICAgIGNvbnN0IHIgPSBjdHhFbC5nZXRCb3Vu
ZGluZ0NsaWVudFJlY3QoKTsKICAgICAgICAgICAgaWYgKHIucmlnaHQgID4gaW5uZXJXaWR0aCkgIGN0
eEVsLnN0eWxlLmxlZnQgPSAoeCAtIHIud2lkdGgpICArICdweCc7CiAgICAgICAgICAgIGlmIChyLmJv
dHRvbSA+IGlubmVySGVpZ2h0KSBjdHhFbC5zdHlsZS50b3AgID0gKHkgLSByLmhlaWdodCkgKyAncHgn
OwogICAgICAgICAgICBwbGFjZURhdGFTdWJtZW51KCk7CiAgICAgICAgfSk7CiAgICB9CiAgICBmdW5j
dGlvbiBwbGFjZURhdGFTdWJtZW51KCkgewogICAgICAgIGNvbnN0IHdyYXAgPSBkb2N1bWVudC5nZXRF
bGVtZW50QnlJZCgnYy1kYXRhLXdyYXAnKTsKICAgICAgICBjb25zdCBzdWIgPSBkb2N1bWVudC5nZXRF
bGVtZW50QnlJZCgnYy1kYXRhLXN1YicpOwogICAgICAgIGlmICghd3JhcCB8fCAhc3ViIHx8IHdyYXAu
c3R5bGUuZGlzcGxheSA9PT0gJ25vbmUnKSByZXR1cm47CiAgICAgICAgY29uc3QgcGFkID0gNDsKICAg
ICAgICAvLyBNZWFzdXJlIHdoaWxlIHRlbXBvcmFyaWx5IHZpc2libGUgKHN1Ym1lbnUgbWF5IHN0aWxs
IGJlIGRpc3BsYXk6bm9uZSkKICAgICAgICBjb25zdCBwcmV2RGlzcGxheSA9IHN1Yi5zdHlsZS5kaXNw
bGF5OwogICAgICAgIGNvbnN0IHByZXZWaXNpYmlsaXR5ID0gc3ViLnN0eWxlLnZpc2liaWxpdHk7CiAg
ICAgICAgY29uc3QgcHJldkxlZnQgPSBzdWIuc3R5bGUubGVmdDsKICAgICAgICBjb25zdCBwcmV2Umln
aHQgPSBzdWIuc3R5bGUucmlnaHQ7CiAgICAgICAgc3ViLmNsYXNzTGlzdC5yZW1vdmUoJ2xlZnQnKTsK
ICAgICAgICBzdWIuc3R5bGUubGVmdCA9ICdjYWxjKDEwMCUgLSAycHgpJzsKICAgICAgICBzdWIuc3R5
bGUucmlnaHQgPSAnYXV0byc7CiAgICAgICAgc3ViLnN0eWxlLnZpc2liaWxpdHkgPSAnaGlkZGVuJzsK
ICAgICAgICBzdWIuc3R5bGUuZGlzcGxheSA9ICdibG9jayc7CiAgICAgICAgY29uc3Qgc3ViVyA9IE1h
dGguY2VpbChzdWIuZ2V0Qm91bmRpbmdDbGllbnRSZWN0KCkud2lkdGggfHwgc3ViLm9mZnNldFdpZHRo
IHx8IDApOwogICAgICAgIGNvbnN0IHdyYXBSZWN0ID0gd3JhcC5nZXRCb3VuZGluZ0NsaWVudFJlY3Qo
KTsKICAgICAgICBzdWIuc3R5bGUuZGlzcGxheSA9IHByZXZEaXNwbGF5OwogICAgICAgIHN1Yi5zdHls
ZS52aXNpYmlsaXR5ID0gcHJldlZpc2liaWxpdHk7CiAgICAgICAgc3ViLnN0eWxlLmxlZnQgPSBwcmV2
TGVmdDsKICAgICAgICBzdWIuc3R5bGUucmlnaHQgPSBwcmV2UmlnaHQ7CgogICAgICAgIGlmIChzdWJX
IDw9IDApIHJldHVybjsKICAgICAgICBjb25zdCBzcGFjZVJpZ2h0ID0gd2luZG93LmlubmVyV2lkdGgg
LSB3cmFwUmVjdC5yaWdodCAtIHBhZDsKICAgICAgICBjb25zdCBzcGFjZUxlZnQgPSB3cmFwUmVjdC5s
ZWZ0IC0gcGFkOwogICAgICAgIGNvbnN0IGZpdHNSaWdodCA9IHNwYWNlUmlnaHQgPj0gc3ViVzsKICAg
ICAgICBjb25zdCBmaXRzTGVmdCA9IHNwYWNlTGVmdCA+PSBzdWJXOwogICAgICAgIGxldCBvcGVuTGVm
dCA9IGZhbHNlOwogICAgICAgIGlmIChmaXRzUmlnaHQpIG9wZW5MZWZ0ID0gZmFsc2U7CiAgICAgICAg
ZWxzZSBpZiAoZml0c0xlZnQpIG9wZW5MZWZ0ID0gdHJ1ZTsKICAgICAgICBlbHNlIG9wZW5MZWZ0ID0g
c3BhY2VMZWZ0ID4gc3BhY2VSaWdodDsgLy8gbmVpdGhlciBmaXRzIOKAlCBwaWNrIHRoZSBsYXJnZXIg
Z2FwCgogICAgICAgIGlmIChvcGVuTGVmdCkgewogICAgICAgICAgICBzdWIuY2xhc3NMaXN0LmFkZCgn
bGVmdCcpOwogICAgICAgICAgICBzdWIuc3R5bGUubGVmdCA9ICdhdXRvJzsKICAgICAgICAgICAgc3Vi
LnN0eWxlLnJpZ2h0ID0gJ2NhbGMoMTAwJSAtIDJweCknOwogICAgICAgIH0gZWxzZSB7CiAgICAgICAg
ICAgIHN1Yi5jbGFzc0xpc3QucmVtb3ZlKCdsZWZ0Jyk7CiAgICAgICAgICAgIHN1Yi5zdHlsZS5sZWZ0
ID0gJ2NhbGMoMTAwJSAtIDJweCknOwogICAgICAgICAgICBzdWIuc3R5bGUucmlnaHQgPSAnYXV0byc7
CiAgICAgICAgfQogICAgfQogICAgZnVuY3Rpb24gaGlkZUN0eCgpIHsKICAgICAgICBjdHhFbC5jbGFz
c0xpc3QucmVtb3ZlKCdvbicpOwogICAgICAgIGN0eENsaXAgPSBudWxsOwogICAgICAgIHRyeSB7CiAg
ICAgICAgICAgIGNvbnN0IHdyYXAgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYy1kYXRhLXdyYXAn
KTsKICAgICAgICAgICAgaWYgKHdyYXApIHdyYXAuY2xhc3NMaXN0LnJlbW92ZSgnb3BlbicpOwogICAg
ICAgICAgICBjbGVhckRhdGFTdWJtZW51UGljaygpOwogICAgICAgICAgICBwcmV2aWV3RGF0YVRyYW5z
Zm9ybVNlcSsrOwogICAgICAgIH0gY2F0Y2gge30KICAgIH0KICAgIHdpbmRvdy5fX2hpZGVDdHggPSBo
aWRlQ3R4OwoKICAgIGZ1bmN0aW9uIGRpc21pc3NDdHhVbmxlc3NJbnNpZGUoZSkgewogICAgICAgIGlm
ICghY3R4RWwuY2xhc3NMaXN0LmNvbnRhaW5zKCdvbicpKSByZXR1cm47CiAgICAgICAgaWYgKGUudGFy
Z2V0LmNsb3Nlc3QoJyNjdHgnKSkgcmV0dXJuOwogICAgICAgIGhpZGVDdHgoKTsKICAgIH0KICAgIGRv
Y3VtZW50LmFkZEV2ZW50TGlzdGVuZXIoJ21vdXNlZG93bicsIGRpc21pc3NDdHhVbmxlc3NJbnNpZGUs
IHRydWUpOwogICAgZG9jdW1lbnQuYWRkRXZlbnRMaXN0ZW5lcignY2xpY2snLCBkaXNtaXNzQ3R4VW5s
ZXNzSW5zaWRlLCB0cnVlKTsKICAgIGxpc3RFbC5hZGRFdmVudExpc3RlbmVyKCdzY3JvbGwnLCBoaWRl
Q3R4LCB7IHBhc3NpdmU6IHRydWUgfSk7CiAgICBkb2N1bWVudC5hZGRFdmVudExpc3RlbmVyKCdrZXlk
b3duJywgZSA9PiB7CiAgICAgICAgLy8gRXNjOiBhbHdheXMgY2xvc2UgcGFuZWwgKHNlYXJjaCBvciBu
b3QpOyBwaW4ga2VlcHMgcGFuZWwKICAgICAgICBpZiAoZS5rZXkgPT09ICdFc2NhcGUnKSB7CiAgICAg
ICAgICAgIGUucHJldmVudERlZmF1bHQoKTsKICAgICAgICAgICAgaGlkZUN0eCgpOwogICAgICAgICAg
ICBjb25zdCB0ZCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd0aXRsZS1kbGcnKTsKICAgICAgICAg
ICAgaWYgKHRkICYmIHRkLmNsYXNzTGlzdC5jb250YWlucygnb24nKSkgewogICAgICAgICAgICAgICAg
dHJ5IHsgY2xvc2VUaXRsZURsZygpOyB9IGNhdGNoIHsgdGQuY2xhc3NMaXN0LnJlbW92ZSgnb24nKTsg
fQogICAgICAgICAgICAgICAgcmV0dXJuOwogICAgICAgICAgICB9CiAgICAgICAgICAgIGlmIChjbHJE
bGcuY2xhc3NMaXN0LmNvbnRhaW5zKCdvbicpKSB7CiAgICAgICAgICAgICAgICBjbG9zZUNsZWFyRGxn
KCk7CiAgICAgICAgICAgICAgICByZXR1cm47CiAgICAgICAgICAgIH0KICAgICAgICAgICAgaWYgKCFw
aW5uZWRVSSkgYWhrKCdoaWRlJyk7CiAgICAgICAgICAgIHJldHVybjsKICAgICAgICB9CiAgICAgICAg
Ly8gV2hpbGUgdHlwaW5nIGluIHNlYXJjaDogQ3RybCtJL0sgYW5kIGFycm93cyBtb3ZlIGxpc3QsIGRv
bid0IGxlYXZlIHRoZSBib3gKICAgICAgICBpZiAoZG9jdW1lbnQuYWN0aXZlRWxlbWVudD8uaWQgPT09
ICdzZWFyY2gnKSB7CiAgICAgICAgICAgIGlmICgoZS5jdHJsS2V5IHx8IGUubWV0YUtleSkgJiYgKGUu
a2V5ID09PSAnaScgfHwgZS5rZXkgPT09ICdJJykpIHsKICAgICAgICAgICAgICAgIGUucHJldmVudERl
ZmF1bHQoKTsgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICAgICAgICAgIHdpbmRvdy5fX25hdiAm
JiB3aW5kb3cuX19uYXYoJ3VwJyk7CiAgICAgICAgICAgICAgICByZXR1cm47CiAgICAgICAgICAgIH0K
ICAgICAgICAgICAgaWYgKChlLmN0cmxLZXkgfHwgZS5tZXRhS2V5KSAmJiAoZS5rZXkgPT09ICdrJyB8
fCBlLmtleSA9PT0gJ0snKSkgewogICAgICAgICAgICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOyBlLnN0
b3BQcm9wYWdhdGlvbigpOwogICAgICAgICAgICAgICAgd2luZG93Ll9fbmF2ICYmIHdpbmRvdy5fX25h
dignZG93bicpOwogICAgICAgICAgICAgICAgcmV0dXJuOwogICAgICAgICAgICB9CiAgICAgICAgICAg
IGlmIChlLmtleSA9PT0gJ0Fycm93RG93bicpIHsKICAgICAgICAgICAgICAgIGUucHJldmVudERlZmF1
bHQoKTsgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICAgICAgICAgIHdpbmRvdy5fX25hdiAmJiB3
aW5kb3cuX19uYXYoJ2Rvd24nKTsKICAgICAgICAgICAgICAgIHJldHVybjsKICAgICAgICAgICAgfQog
ICAgICAgICAgICBpZiAoZS5rZXkgPT09ICdBcnJvd1VwJykgewogICAgICAgICAgICAgICAgZS5wcmV2
ZW50RGVmYXVsdCgpOyBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgICAgICAgICAgICAgd2luZG93Ll9f
bmF2ICYmIHdpbmRvdy5fX25hdigndXAnKTsKICAgICAgICAgICAgICAgIHJldHVybjsKICAgICAgICAg
ICAgfQogICAgICAgICAgICByZXR1cm47CiAgICAgICAgfQogICAgICAgIGNvbnN0IHZpcyA9ICh0eXBl
b2YgbmF2TGlzdCA9PT0gJ2Z1bmN0aW9uJyA/IG5hdkxpc3QoKSA6IHZpc2libGVMaXN0KCkpOwogICAg
ICAgIGlmICghdmlzLmxlbmd0aCkgcmV0dXJuOwogICAgICAgIGxldCBpZHggPSBzZWxlY3RlZEluZGV4
KCk7CiAgICAgICAgaWYgKGlkeCA8IDApIGlkeCA9IDA7CiAgICAgICAgaWYgICAgICAoZS5rZXkgPT09
ICdBcnJvd0Rvd24nKSB7IGUucHJldmVudERlZmF1bHQoKTsgZS5zdG9wUHJvcGFnYXRpb24oKTsgc2Vs
ZWN0QnlJbmRleChpZHggKyAxKTsgfQogICAgICAgIGVsc2UgaWYgKGUua2V5ID09PSAnQXJyb3dVcCcp
ICAgeyBlLnByZXZlbnREZWZhdWx0KCk7IGUuc3RvcFByb3BhZ2F0aW9uKCk7IHNlbGVjdEJ5SW5kZXgo
aWR4IC0gMSk7IH0KICAgICAgICBlbHNlIGlmIChlLmtleSA9PT0gJ0VudGVyJykgewogICAgICAgICAg
ICBlLnByZXZlbnREZWZhdWx0KCk7CiAgICAgICAgICAgIC8vIOWbuuWumuaXtuWbnui9puS4jeeymOi0
tO+8jOWPqueCueadoeebrueymOi0tAogICAgICAgICAgICBpZiAocGlubmVkVUkpIHJldHVybjsKICAg
ICAgICAgICAgaWYgKG11bHRpSWRzLmxlbmd0aCA+PSAxKSB7CiAgICAgICAgICAgICAgICBjb25zdCBp
ZHMgPSBtdWx0aUlkcy5zbGljZSgpOwogICAgICAgICAgICAgICAgY2xlYXJNdWx0aSgpOwogICAgICAg
ICAgICAgICAgbWFya1Bhc3RlZExvY2FsKGlkcyk7CiAgICAgICAgICAgICAgICBwYXN0ZU1hbnlXaXRo
U2VwKGlkcyk7CiAgICAgICAgICAgICAgICByZXR1cm47CiAgICAgICAgICAgIH0KICAgICAgICAgICAg
Y29uc3QgYyA9IHZpc1tzZWxlY3RlZEluZGV4KCldOwogICAgICAgICAgICBpZiAoYykgewogICAgICAg
ICAgICAgICAgbWFya1Bhc3RlZExvY2FsKGMuaWQpOwogICAgICAgICAgICAgICAgYWhrKCdwYXN0ZScs
IFN0cmluZyhjLmlkKSk7CiAgICAgICAgICAgIH0KICAgICAgICB9IGVsc2UgaWYgKC9eWzEtOV0kLy50
ZXN0KGUua2V5KSkgewogICAgICAgICAgICBjb25zdCBjID0gdmlzWytlLmtleSAtIDFdOwogICAgICAg
ICAgICBpZiAoYykgewogICAgICAgICAgICAgICAgbWFya1Bhc3RlZExvY2FsKGMuaWQpOwogICAgICAg
ICAgICAgICAgYWhrKCdwYXN0ZScsIFN0cmluZyhjLmlkKSk7CiAgICAgICAgICAgIH0KICAgICAgICB9
CiAgICB9KTsKCiAgICB3aW5kb3cuX19uYXYgPSBkaXIgPT4gewogICAgICAgIGNvbnN0IHZpcyA9ICh0
eXBlb2YgbmF2TGlzdCA9PT0gJ2Z1bmN0aW9uJyA/IG5hdkxpc3QoKSA6IHZpc2libGVMaXN0KCkpOwog
ICAgICAgIGlmICghdmlzLmxlbmd0aCAmJiBkaXIgIT09ICd0YWInICYmIGRpciAhPT0gJ3RhYlByZXYn
KSByZXR1cm47CiAgICAgICAgbGV0IGlkeCA9IHNlbGVjdGVkSW5kZXgoKTsKICAgICAgICBpZiAoaWR4
IDwgMCkgaWR4ID0gMDsKICAgICAgICBpZiAoZGlyID09PSAndXAnKSBzZWxlY3RCeUluZGV4KGlkeCAt
IDEpOwogICAgICAgIGVsc2UgaWYgKGRpciA9PT0gJ2Rvd24nKSBzZWxlY3RCeUluZGV4KGlkeCArIDEp
OwogICAgICAgIGVsc2UgaWYgKGRpciA9PT0gJ2VudGVyJykgewogICAgICAgICAgICBpZiAocGlubmVk
VUkpIHJldHVybjsKICAgICAgICAgICAgX19wcmVwUGFzdGUoKTsKICAgICAgICAgICAgaWYgKG11bHRp
SWRzLmxlbmd0aCA+PSAxKSB7CiAgICAgICAgICAgICAgICBjb25zdCBpZHMgPSBtdWx0aUlkcy5zbGlj
ZSgpOwogICAgICAgICAgICAgICAgY2xlYXJNdWx0aSgpOwogICAgICAgICAgICAgICAgbWFya1Bhc3Rl
ZExvY2FsKGlkcyk7CiAgICAgICAgICAgICAgICBwYXN0ZU1hbnlXaXRoU2VwKGlkcyk7CiAgICAgICAg
ICAgICAgICByZXR1cm47CiAgICAgICAgICAgIH0KICAgICAgICAgICAgY29uc3QgYyA9IHZpc1tzZWxl
Y3RlZEluZGV4KCldOwogICAgICAgICAgICBpZiAoYykgewogICAgICAgICAgICAgICAgbWFya1Bhc3Rl
ZExvY2FsKGMuaWQpOwogICAgICAgICAgICAgICAgYWhrKCdwYXN0ZScsIFN0cmluZyhjLmlkKSk7CiAg
ICAgICAgICAgIH0KICAgICAgICB9CiAgICB9OwoKICAgIC8vIEFISyBFbnRlciBob3RrZXkgbGFuZHMg
aGVyZSAoV2ViVmlldyBtYXkgbm90IHJlY2VpdmUgdGhlIGtleSB3aGlsZSB1bnBpbm5lZCkKICAgIHdp
bmRvdy5fX2VkaXRUaXRsZSA9ICgpID0+IHsKICAgICAgICBsZXQgYyA9IG51bGw7CiAgICAgICAgaWYg
KHNlbGVjdGVkSWQpCiAgICAgICAgICAgIGMgPSBhbGxDbGlwcy5maW5kKHggPT4gK3guaWQgPT09ICtz
ZWxlY3RlZElkKSB8fCBudWxsOwogICAgICAgIGlmICghYyAmJiBjdHhDbGlwKQogICAgICAgICAgICBj
ID0gY3R4Q2xpcDsKICAgICAgICBpZiAoIWMpIHsKICAgICAgICAgICAgY29uc3QgdmlzID0gdmlzaWJs
ZUxpc3QoKTsKICAgICAgICAgICAgaWYgKHZpcy5sZW5ndGgpIGMgPSB2aXNbMF07CiAgICAgICAgfQog
ICAgICAgIGlmICghYykgcmV0dXJuOwogICAgICAgIG9wZW5UaXRsZURsZyhjKTsKICAgIH07CgogICAg
d2luZG93Ll9fb25FbnRlciA9ICgpID0+IHsKICAgICAgICBjb25zdCB0ZCA9IGRvY3VtZW50LmdldEVs
ZW1lbnRCeUlkKCd0aXRsZS1kbGcnKTsKICAgICAgICBpZiAodGQgJiYgdGQuY2xhc3NMaXN0LmNvbnRh
aW5zKCdvbicpKSB7CiAgICAgICAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd0aXRsZS1vaycp
Py5jbGljaygpOwogICAgICAgICAgICByZXR1cm47CiAgICAgICAgfQogICAgICAgIGlmIChkb2N1bWVu
dC5hY3RpdmVFbGVtZW50Py5pZCA9PT0gJ3RpdGxlLWlucHV0JykgewogICAgICAgICAgICBkb2N1bWVu
dC5nZXRFbGVtZW50QnlJZCgndGl0bGUtb2snKT8uY2xpY2soKTsKICAgICAgICAgICAgcmV0dXJuOwog
ICAgICAgIH0KICAgICAgICAvLyDoh6rlrprkuYnliIbpmpTnrKbvvJrmnKrlm7rlrprml7YgQUhLIOS8
muaKoiBFbnRlcgogICAgICAgIGNvbnN0IHNlcE1lbnUgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgn
cGFzdGUtc2VwLW1lbnUnKTsKICAgICAgICBjb25zdCBzZXBJbnAgPSBkb2N1bWVudC5nZXRFbGVtZW50
QnlJZCgncGFzdGUtc2VwLWN1c3RvbScpOwogICAgICAgIGlmIChzZXBNZW51ICYmIHNlcE1lbnUuY2xh
c3NMaXN0LmNvbnRhaW5zKCdvbicpICYmIHNlcElucCkgewogICAgICAgICAgICBpZiAoU3RyaW5nKHNl
cElucC52YWx1ZSB8fCAnJykgIT09ICcnKSBhcHBseVNlcGFyYXRvcihzZXBJbnAudmFsdWUpOwogICAg
ICAgICAgICBlbHNlIGNsb3NlU2VwTWVudSgpOwogICAgICAgICAgICByZXR1cm47CiAgICAgICAgfQog
ICAgICAgIC8vIOWbuuWumuaXtuWbnui9puS4jeeymOi0tAogICAgICAgIGlmIChwaW5uZWRVSSkgcmV0
dXJuOwogICAgICAgIC8vIFR5cGluZyBpbiBzZWFyY2g6IEVudGVyIHNob3VsZCBwYXN0ZSBzZWxlY3Rl
ZCBpdGVtCiAgICAgICAgaWYgKGRvY3VtZW50LmFjdGl2ZUVsZW1lbnQ/LmlkID09PSAnc2VhcmNoJykg
ewogICAgICAgICAgICB3aW5kb3cuX19uYXYgJiYgd2luZG93Ll9fbmF2KCdlbnRlcicpOwogICAgICAg
ICAgICByZXR1cm47CiAgICAgICAgfQogICAgICAgIHdpbmRvdy5fX25hdiAmJiB3aW5kb3cuX19uYXYo
J2VudGVyJyk7CiAgICB9OwoKICAgIHdpbmRvdy5fX2N5Y2xlVGFiID0gZGlyID0+IHsKICAgICAgICBj
b25zdCBpID0gTWF0aC5tYXgoMCwgVEFCX09SREVSLmluZGV4T2YoY3VyVGFiKSk7CiAgICAgICAgY29u
c3QgbmV4dCA9IFRBQl9PUkRFUlsoaSArIChkaXIgfCAwKSArIFRBQl9PUkRFUi5sZW5ndGggKiAxMCkg
JSBUQUJfT1JERVIubGVuZ3RoXTsKICAgICAgICBzZXRUYWIobmV4dCk7CiAgICB9OwogICAgd2luZG93
Ll9fb25QYW5lbFNob3cgPSAoa2VlcFNlYXJjaCkgPT4gewogICAgICAgIHdpbmRvdy5fX3BlcmZNYXJr
ICYmIHdpbmRvdy5fX3BlcmZNYXJrKCdqc19vblBhbmVsU2hvdyBrZWVwU2VhcmNoPScgKyAoISFrZWVw
U2VhcmNoKSk7CiAgICAgICAgdHJ5IHsgcmVzZXRQYXN0ZVNlcERlZmF1bHQoKTsgfSBjYXRjaCB7fQog
ICAgICAgIC8vIERvIE5PVCBmb2N1cyBXZWJWaWV3IOKAlCBrZWVwIGVkaXRvciBjYXJldC9mb2N1cyAo
QUhLIGhhbmRsZXMga2V5cyB2aWEgI0hvdElmKQogICAgICAgIC8vIFdpbitWOiBjb2xsYXBzZSBzZWFy
Y2guID8/IHNlYXJjaDoga2VlcC9vcGVuIHNlYXJjaCBib3guCiAgICAgICAga2VlcFNlYXJjaCA9ICEh
a2VlcFNlYXJjaDsKICAgICAgICB0cnkgeyBoaWRlQ3R4KCk7IH0gY2F0Y2gge30KICAgICAgICB0cnkg
eyBjbG9zZVRpdGxlRGxnKCk7IH0gY2F0Y2gge30KICAgICAgICB0cnkgewogICAgICAgICAgICBjb25z
dCB3cmFwID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NlYXJjaC13cmFwJyk7CiAgICAgICAgICAg
IGNvbnN0IHNyY2ggPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc2VhcmNoJyk7CiAgICAgICAgICAg
IGNvbnN0IHNjbHIgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc2VhcmNoLWNscicpOwogICAgICAg
ICAgICBpZiAoIWtlZXBTZWFyY2gpIHsKICAgICAgICAgICAgICAgIGlmICh3cmFwKSB3cmFwLmNsYXNz
TGlzdC5yZW1vdmUoJ29wZW4nKTsKICAgICAgICAgICAgICAgIGlmIChzcmNoKSB7CiAgICAgICAgICAg
ICAgICAgICAgc3JjaC52YWx1ZSA9ICcnOwogICAgICAgICAgICAgICAgICAgIHNyY2guY2xhc3NMaXN0
LnJlbW92ZSgnaGFzLXZhbCcpOwogICAgICAgICAgICAgICAgICAgIHRyeSB7IHNyY2guYmx1cigpOyB9
IGNhdGNoIHt9CiAgICAgICAgICAgICAgICB9CiAgICAgICAgICAgICAgICBpZiAoc2Nscikgc2Nsci5z
dHlsZS5kaXNwbGF5ID0gJ25vbmUnOwogICAgICAgICAgICAgICAgcXVlcnkgPSAnJzsKICAgICAgICAg
ICAgICAgIHdpbmRvdy5fX2hvc3RGaWx0ZXJlZCA9IGZhbHNlOwogICAgICAgICAgICAgICAgd2luZG93
Ll9faG9zdEZpbHRlclEgPSAnJzsKICAgICAgICAgICAgICAgIC8vIFdpbitW77ya56uL5Yi755So5pyq
6L+H5ruk57yT5a2Y6ZO65YiX6KGo77yM6YG/5YWN5YWI6Zeq6L+H5ruk57uT5p6cL+epuuWjs+WGjeet
iSBTZXRWaWV3CiAgICAgICAgICAgICAgICB0cnkgewogICAgICAgICAgICAgICAgICAgIGNvbnN0IGhp
dCA9IHZpZXdNZW0uZ2V0KHZpZXdNZW1LZXkoJ2FsbCcsICcnLCBmYWxzZSkpOwogICAgICAgICAgICAg
ICAgICAgIGlmIChoaXQgJiYgQXJyYXkuaXNBcnJheShoaXQuaXRlbXMpICYmIGhpdC5pdGVtcy5sZW5n
dGgpIHsKICAgICAgICAgICAgICAgICAgICAgICAgYWxsQ2xpcHMgPSBoaXQuaXRlbXMuc2xpY2UoKTsK
ICAgICAgICAgICAgICAgICAgICAgICAgZGlza1RvdGFsID0gTnVtYmVyKGhpdC50b3RhbCkgfHwgaGl0
Lml0ZW1zLmxlbmd0aDsKICAgICAgICAgICAgICAgICAgICAgICAgd2luZG93Ll9fZGF0YVJlYWR5ID0g
dHJ1ZTsKICAgICAgICAgICAgICAgICAgICAgICAgaG9zdFB1c2hlZE9uY2UgPSB0cnVlOwogICAgICAg
ICAgICAgICAgICAgICAgICBzYXdOb25FbXB0eSA9IHRydWU7CiAgICAgICAgICAgICAgICAgICAgICAg
IGNsZWFyV2FpdGluZ0RhdGEoKTsKICAgICAgICAgICAgICAgICAgICB9IGVsc2UgewogICAgICAgICAg
ICAgICAgICAgICAgICBzY2hlZHVsZURlbGF5ZWRTa2VsKCk7CiAgICAgICAgICAgICAgICAgICAgfQog
ICAgICAgICAgICAgICAgfSBjYXRjaCB7CiAgICAgICAgICAgICAgICAgICAgc2NoZWR1bGVEZWxheWVk
U2tlbCgpOwogICAgICAgICAgICAgICAgfQogICAgICAgICAgICB9IGVsc2UgaWYgKHdyYXApIHsKICAg
ICAgICAgICAgICAgIHdyYXAuY2xhc3NMaXN0LmFkZCgnb3BlbicpOwogICAgICAgICAgICAgICAgaWYg
KHNyY2ggJiYgc3JjaC52YWx1ZSkKICAgICAgICAgICAgICAgICAgICBxdWVyeSA9IHNyY2gudmFsdWU7
CiAgICAgICAgICAgICAgICAvLyA/PyDmkJzntKLvvJrlnKjkuLvmnLrov4fmu6Tnu5PmnpzliLDovr7l
iY3vvIzlhYjmjInlhbPplK7lrZfmnKzlnLDmu6TvvIznpoHmraLpl6rlh7rjgIzlhajpg6jjgI0KICAg
ICAgICAgICAgICAgIGlmIChTdHJpbmcocXVlcnkgfHwgJycpLnRyaW0oKSkgewogICAgICAgICAgICAg
ICAgICAgIHdpbmRvdy5fX2hvc3RGaWx0ZXJlZCA9IGZhbHNlOwogICAgICAgICAgICAgICAgICAgIHdp
bmRvdy5fX2hvc3RGaWx0ZXJRID0gJyc7CiAgICAgICAgICAgICAgICB9CiAgICAgICAgICAgIH0KICAg
ICAgICAgICAgdG9kYXlPbmx5ID0gZmFsc2U7CiAgICAgICAgICAgIHRyeSB7CiAgICAgICAgICAgICAg
ICBjb25zdCBidG5Ub2RheSA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdidG4tdG9kYXknKTsKICAg
ICAgICAgICAgICAgIGlmIChidG5Ub2RheSkgYnRuVG9kYXkuY2xhc3NMaXN0LnJlbW92ZSgnb24nKTsK
ICAgICAgICAgICAgfSBjYXRjaCB7fQogICAgICAgICAgICBjdXJUYWIgPSAnYWxsJzsKICAgICAgICAg
ICAgbG9hZGluZ01vcmUgPSBmYWxzZTsKICAgICAgICAgICAgbWFya1RhYignYWxsJyk7CiAgICAgICAg
ICAgIC8vIOS4jeimgSBhaGsoJ2JsdXJQYW5lbCcp77ya5Lya6LefIFNob3dQYW5lbCDmiqLnhKbngrnv
vIxXaW4rVi8/PyDpg73lrrnmmJPpl6rjgIHkubHot7MKICAgICAgICAgICAgcmVuZGVyKCk7CiAgICAg
ICAgICAgIC8vIOWQjOatpeW9k+WJjSB0YWIvcXVlcnkg5YiwIEFIS++8iD8/IOabvuWPqueUqCB2aWV3
VGFiIOaQnOmUmemhte+8iQogICAgICAgICAgICByZXF1ZXN0VmlldygpOwogICAgICAgIH0gY2F0Y2gg
e30KICAgICAgICBzZWxlY3RGaXJzdE9uU2hvdyA9IHRydWU7CiAgICAgICAgbG9jYXRlQWN0aXZlID0g
ZmFsc2U7CiAgICAgICAgdXBkYXRlTG9jYXRlQnRuKCk7CiAgICAgICAgY2xlYXJNdWx0aSgpOwogICAg
ICAgIGNvbnN0IHZpcyA9IHZpc2libGVMaXN0KCk7CiAgICAgICAgaWYgKHZpcy5sZW5ndGgpIHsKICAg
ICAgICAgICAgc2VsZWN0ZWRJZCA9IHZpc1swXS5pZDsKICAgICAgICAgICAgcmFuZ2VBbmNob3JJZCA9
IHNlbGVjdGVkSWQ7CiAgICAgICAgICAgIHJhbmdlQW5jaG9yQ2xpY2tlZCA9IGZhbHNlOwogICAgICAg
ICAgICBsaXN0RWwuc2Nyb2xsVG9wID0gMDsKICAgICAgICB9CiAgICAgICAgc3luY0l0ZW1IaWdobGln
aHQoKTsKICAgIH07CgogICAgZnVuY3Rpb24gY3R4QmluZChpZCwgZm4pIHsKICAgICAgICBkb2N1bWVu
dC5nZXRFbGVtZW50QnlJZChpZCkuYWRkRXZlbnRMaXN0ZW5lcignY2xpY2snLCBlID0+IHsKICAgICAg
ICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICAgICAgaWYgKGN0eENsaXApIGZuKGN0eENs
aXApOwogICAgICAgICAgICBoaWRlQ3R4KCk7CiAgICAgICAgfSk7CiAgICB9CiAgICBmdW5jdGlvbiBz
cWxRdW90ZSh2KSB7CiAgICAgICAgcmV0dXJuICInIiArIFN0cmluZyh2ID8/ICcnKS5yZXBsYWNlKC8n
L2csICInJyIpICsgIiciOwogICAgfQogICAgZnVuY3Rpb24gc3RyaXBPdXRlclF1b3Rlcyh2KSB7CiAg
ICAgICAgY29uc3QgcyA9IFN0cmluZyh2ID8/ICcnKS50cmltKCk7CiAgICAgICAgaWYgKChzLnN0YXJ0
c1dpdGgoJyInKSAmJiBzLmVuZHNXaXRoKCciJykpIHx8IChzLnN0YXJ0c1dpdGgoIiciKSAmJiBzLmVu
ZHNXaXRoKCInIikpKQogICAgICAgICAgICByZXR1cm4gcy5zbGljZSgxLCAtMSk7CiAgICAgICAgcmV0
dXJuIHM7CiAgICB9CiAgICBmdW5jdGlvbiBzcGxpdENzdlBhcnRzKHJhdykgewogICAgICAgIGNvbnN0
IHMgPSBTdHJpbmcocmF3ID8/ICcnKTsKICAgICAgICBjb25zdCBwYXJ0cyA9IFtdOwogICAgICAgIGxl
dCBjdXIgPSAnJzsKICAgICAgICBsZXQgcSA9ICcnOwogICAgICAgIGZvciAobGV0IGkgPSAwOyBpIDwg
cy5sZW5ndGg7IGkrKykgewogICAgICAgICAgICBjb25zdCBjaCA9IHNbaV07CiAgICAgICAgICAgIGlm
IChxKSB7CiAgICAgICAgICAgICAgICBpZiAoY2ggPT09IHEpIHsKICAgICAgICAgICAgICAgICAgICAv
LyBkb3VibGVkIHF1b3RlIGVzY2FwZQogICAgICAgICAgICAgICAgICAgIGlmIChzW2kgKyAxXSA9PT0g
cSkgeyBjdXIgKz0gcTsgaSsrOyB9CiAgICAgICAgICAgICAgICAgICAgZWxzZSBxID0gJyc7CiAgICAg
ICAgICAgICAgICB9IGVsc2UgY3VyICs9IGNoOwogICAgICAgICAgICAgICAgY29udGludWU7CiAgICAg
ICAgICAgIH0KICAgICAgICAgICAgaWYgKGNoID09PSAnIicgfHwgY2ggPT09ICInIikgeyBxID0gY2g7
IGNvbnRpbnVlOyB9CiAgICAgICAgICAgIGlmIChjaCA9PT0gJywnKSB7IHBhcnRzLnB1c2goY3VyLnRy
aW0oKSk7IGN1ciA9ICcnOyBjb250aW51ZTsgfQogICAgICAgICAgICBjdXIgKz0gY2g7CiAgICAgICAg
fQogICAgICAgIHBhcnRzLnB1c2goY3VyLnRyaW0oKSk7CiAgICAgICAgcmV0dXJuIHBhcnRzLmZpbHRl
cihwID0+IHAgIT09ICcnKTsKICAgIH0KICAgIGZ1bmN0aW9uIHRyYW5zZm9ybVRleHRUb1NxbFR1cGxl
KHJhdywgbW9kZSkgewogICAgICAgIGxldCBzcmMgPSBTdHJpbmcocmF3ID8/ICcnKS50cmltKCk7CiAg
ICAgICAgaWYgKCFzcmMpIHJldHVybiAnJzsKICAgICAgICBsZXQgcGFydHMgPSBbXTsKICAgICAgICBp
ZiAobW9kZSA9PT0gJ2xpbmVzJykgewogICAgICAgICAgICBwYXJ0cyA9IHNyYy5zcGxpdCgvXHI/XG4v
KS5tYXAobCA9PiBzdHJpcE91dGVyUXVvdGVzKGwudHJpbSgpKSkuZmlsdGVyKEJvb2xlYW4pOwogICAg
ICAgIH0gZWxzZSB7CiAgICAgICAgICAgIC8vIHthLGJ9IC8gYSxiIC8geyJhIiwiYiJ9CiAgICAgICAg
ICAgIGNvbnN0IG0gPSBzcmMubWF0Y2goL15ccypceyhbXHNcU10qKVx9XHMqJC8pOwogICAgICAgICAg
ICBpZiAobSkgc3JjID0gbVsxXS50cmltKCk7CiAgICAgICAgICAgIHBhcnRzID0gc3BsaXRDc3ZQYXJ0
cyhzcmMpLm1hcChzdHJpcE91dGVyUXVvdGVzKS5maWx0ZXIoQm9vbGVhbik7CiAgICAgICAgfQogICAg
ICAgIGlmICghcGFydHMubGVuZ3RoKSByZXR1cm4gJyc7CiAgICAgICAgcmV0dXJuICcoJyArIHBhcnRz
Lm1hcChzcWxRdW90ZSkuam9pbignLCcpICsgJyknOwogICAgfQogICAgZnVuY3Rpb24gYXBwbHlEYXRh
VHJhbnNmb3JtKGMsIG1vZGUpIHsKICAgICAgICBpZiAoIWMpIHJldHVybjsKICAgICAgICAvLyBEbyBu
b3QgbXV0YXRlIGNsaXAgaGlzdG9yeSDigJQgQUhLIHRyYW5zZm9ybXMgYSBjb3B5IGFuZCBwYXN0ZXMg
aXQKICAgICAgICB0cnkgeyBtYXJrUGFzdGVkTG9jYWwoYy5pZCk7IH0gY2F0Y2gge30KICAgICAgICBh
aGsoJ3RleHRUcmFuc2Zvcm0nLCBTdHJpbmcoYy5pZCksIFN0cmluZyhtb2RlIHx8ICdhdXRvJykpOwog
ICAgfQogICAgZnVuY3Rpb24gZGV0ZWN0RGF0YVRyYW5zZm9ybU1vZGUocmF3KSB7CiAgICAgICAgLy8g
VUkgbGlzdCBvbmx5IGhhcyB0cnVuY2F0ZWQgcHJldmlldyAoZGF0YT0iIikuCiAgICAgICAgLy8gQ2hl
Y2sgXCIgZmlyc3Q6IGVzY2FwZWQgSlNPTiBvZnRlbiBhbHNvIHN0YXJ0cyB3aXRoICd7Jy4KICAgICAg
ICBjb25zdCBzID0gU3RyaW5nKHJhdyA/PyAnJykudHJpbSgpOwogICAgICAgIGlmICghcykgcmV0dXJu
ICcnOwogICAgICAgIGlmIChzLmluY2x1ZGVzKCdcXCInKSkgcmV0dXJuICdqc29uJzsKICAgICAgICBp
ZiAocy5zdGFydHNXaXRoKCd7JykpIHJldHVybiAnYnJhY2UnOwogICAgICAgIGlmIChzLmluY2x1ZGVz
KCdcbicpIHx8IHMuaW5jbHVkZXMoJ1xyJykpIHJldHVybiAnbGluZXMnOwogICAgICAgIHJldHVybiAn
JzsKICAgIH0KICAgIGZ1bmN0aW9uIGNsZWFyRGF0YVN1Ym1lbnVQaWNrKCkgewogICAgICAgIHRyeSB7
CiAgICAgICAgICAgIGRvY3VtZW50LnF1ZXJ5U2VsZWN0b3JBbGwoJyNjLWRhdGEtc3ViIC5jLWl0ZW0u
cGljaycpLmZvckVhY2goZWwgPT4gZWwuY2xhc3NMaXN0LnJlbW92ZSgncGljaycpKTsKICAgICAgICB9
IGNhdGNoIHt9CiAgICB9CiAgICBmdW5jdGlvbiBoaWdobGlnaHREYXRhU3VibWVudU1vZGUobW9kZSkg
ewogICAgICAgIGNsZWFyRGF0YVN1Ym1lbnVQaWNrKCk7CiAgICAgICAgY29uc3QgaWRNYXAgPSB7IGJy
YWNlOiAnYy1kYXRhLWJyYWNlJywgbGluZXM6ICdjLWRhdGEtbGluZXMnLCBqc29uOiAnYy1kYXRhLWpz
b24nIH07CiAgICAgICAgY29uc3QgaWQgPSBpZE1hcFttb2RlXTsKICAgICAgICBpZiAoIWlkKSByZXR1
cm47CiAgICAgICAgY29uc3QgZWwgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZChpZCk7CiAgICAgICAg
aWYgKGVsKSBlbC5jbGFzc0xpc3QuYWRkKCdwaWNrJyk7CiAgICB9CiAgICBmdW5jdGlvbiBwcmV2aWV3
RGF0YVRyYW5zZm9ybU1vZGVBc3luYygpIHsKICAgICAgICBjb25zdCB0b2tlbiA9ICsrcHJldmlld0Rh
dGFUcmFuc2Zvcm1TZXE7CiAgICAgICAgY29uc3QgY2xpcCA9IGN0eENsaXA7CiAgICAgICAgc2V0VGlt
ZW91dCgoKSA9PiB7CiAgICAgICAgICAgIGlmICh0b2tlbiAhPT0gcHJldmlld0RhdGFUcmFuc2Zvcm1T
ZXEpIHJldHVybjsKICAgICAgICAgICAgaWYgKCFjbGlwIHx8IGN0eENsaXAgIT09IGNsaXApIHJldHVy
bjsKICAgICAgICAgICAgY29uc3QgcmF3ID0gU3RyaW5nKGNsaXAuZGF0YSB8fCBjbGlwLnByZXZpZXcg
fHwgJycpOwogICAgICAgICAgICBjb25zdCBtb2RlID0gZGV0ZWN0RGF0YVRyYW5zZm9ybU1vZGUocmF3
KTsKICAgICAgICAgICAgaWYgKHRva2VuICE9PSBwcmV2aWV3RGF0YVRyYW5zZm9ybVNlcSkgcmV0dXJu
OwogICAgICAgICAgICBoaWdobGlnaHREYXRhU3VibWVudU1vZGUobW9kZSk7CiAgICAgICAgfSwgMCk7
CiAgICB9CiAgICBsZXQgcHJldmlld0RhdGFUcmFuc2Zvcm1TZXEgPSAwOwogICAgY29uc3QgZGF0YVBh
cmVudCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjLWRhdGEnKTsKICAgIGNvbnN0IGRhdGFXcmFw
RWwgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYy1kYXRhLXdyYXAnKTsKICAgIGlmIChkYXRhUGFy
ZW50KSB7CiAgICAgICAgZGF0YVBhcmVudC5hZGRFdmVudExpc3RlbmVyKCdjbGljaycsIGUgPT4gewog
ICAgICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgICAgICAgICAvLyBQcmltYXJ5IGNsaWNr
ID0gYXV0byBkZXRlY3QgKyB0cmFuc2Zvcm0gKyBwYXN0ZQogICAgICAgICAgICBpZiAoY3R4Q2xpcCkg
ewogICAgICAgICAgICAgICAgYXBwbHlEYXRhVHJhbnNmb3JtKGN0eENsaXAsICdhdXRvJyk7CiAgICAg
ICAgICAgICAgICBoaWRlQ3R4KCk7CiAgICAgICAgICAgICAgICByZXR1cm47CiAgICAgICAgICAgIH0K
ICAgICAgICAgICAgY29uc3Qgd3JhcCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjLWRhdGEtd3Jh
cCcpOwogICAgICAgICAgICBpZiAod3JhcCkgewogICAgICAgICAgICAgICAgd3JhcC5jbGFzc0xpc3Qu
dG9nZ2xlKCdvcGVuJyk7CiAgICAgICAgICAgICAgICBwbGFjZURhdGFTdWJtZW51KCk7CiAgICAgICAg
ICAgICAgICBwcmV2aWV3RGF0YVRyYW5zZm9ybU1vZGVBc3luYygpOwogICAgICAgICAgICB9CiAgICAg
ICAgfSk7CiAgICB9CiAgICBpZiAoZGF0YVdyYXBFbCkgewogICAgICAgIGRhdGFXcmFwRWwuYWRkRXZl
bnRMaXN0ZW5lcignbW91c2VlbnRlcicsICgpID0+IHsKICAgICAgICAgICAgcGxhY2VEYXRhU3VibWVu
dSgpOwogICAgICAgICAgICBwcmV2aWV3RGF0YVRyYW5zZm9ybU1vZGVBc3luYygpOwogICAgICAgIH0p
OwogICAgICAgIGRhdGFXcmFwRWwuYWRkRXZlbnRMaXN0ZW5lcignbW91c2VsZWF2ZScsICgpID0+IGNs
ZWFyRGF0YVN1Ym1lbnVQaWNrKCkpOwogICAgfQogICAgY3R4QmluZCgnYy1kYXRhLWJyYWNlJywgYyA9
PiBhcHBseURhdGFUcmFuc2Zvcm0oYywgJ2JyYWNlJykpOwogICAgY3R4QmluZCgnYy1kYXRhLWxpbmVz
JywgYyA9PiBhcHBseURhdGFUcmFuc2Zvcm0oYywgJ2xpbmVzJykpOwogICAgY3R4QmluZCgnYy1kYXRh
LWpzb24nLCBjID0+IGFwcGx5RGF0YVRyYW5zZm9ybShjLCAnanNvbicpKTsKICAgIGN0eEJpbmQoJ2Mt
Y29weScsICBjID0+IHsKICAgICAgICBpZiAobm9ybVR5cGUoYy50eXBlKSA9PT0gJ3JlY2VudCcpCiAg
ICAgICAgICAgIGFoaygnY29weVBhdGgnLCBTdHJpbmcoYy5kYXRhIHx8IGMucHJldmlldyB8fCAnJykp
OwogICAgICAgIGVsc2UKICAgICAgICAgICAgYWhrKCdjb3B5QnlJZCcsIFN0cmluZyhjLmlkKSk7CiAg
ICB9KTsKICAgIGN0eEJpbmQoJ2MtcGFzdGUnLCBjID0+IHsKICAgICAgICBhY3RpdmF0ZUNsaXBJdGVt
KGMpOwogICAgfSk7CiAgICBjdHhCaW5kKCdjLXBpbicsICAgYyA9PiB7CiAgICAgICAgY29uc3QgaXNS
ZWNlbnQgPSBub3JtVHlwZShjLnR5cGUpID09PSAncmVjZW50JyB8fCBjdXJUYWIgPT09ICdyZWNlbnQn
OwogICAgICAgIC8vIE11bHRpLXNlbGVjdDogcGluL3VucGluIGFsbCBzZWxlY3RlZCB3aGVuIHJpZ2h0
LWNsaWNrIGlzIG9uIGEgc2VsZWN0ZWQgaXRlbQogICAgICAgIGxldCBpZHMgPSBbXTsKICAgICAgICBp
ZiAoIWlzUmVjZW50ICYmIG11bHRpSWRzLmxlbmd0aCA+IDEgJiYgbXVsdGlJZHMuaW5jbHVkZXMoK2Mu
aWQpKQogICAgICAgICAgICBpZHMgPSBtdWx0aUlkcy5zbGljZSgpOwogICAgICAgIGVsc2UKICAgICAg
ICAgICAgaWRzID0gWytjLmlkXTsKICAgICAgICBpZHMgPSBpZHMubWFwKHggPT4gK3gpLmZpbHRlcih4
ID0+IHggPiAwKTsKICAgICAgICBpZiAoIWlkcy5sZW5ndGgpIHJldHVybjsKCiAgICAgICAgbGV0IGFu
eU9mZiA9IGZhbHNlOwogICAgICAgIGZvciAoY29uc3QgcGlkIG9mIGlkcykgewogICAgICAgICAgICBj
b25zdCB4ID0gKCtwaWQgPT09ICtjLmlkKSA/IGMgOiBhbGxDbGlwcy5maW5kKHQgPT4gK3QuaWQgPT09
ICtwaWQpOwogICAgICAgICAgICBpZiAoeCAmJiAhaXNQaW5uZWQoeCkpIHsgYW55T2ZmID0gdHJ1ZTsg
YnJlYWs7IH0KICAgICAgICB9CiAgICAgICAgLy8gSWYgYW55IHNlbGVjdGVkIGlzIG5vdCBmYXZvcml0
ZWQg4oaSIGZhdm9yaXRlIGFsbDsgZWxzZSB1bmZhdm9yaXRlIGFsbAogICAgICAgIGNvbnN0IG5leHQg
PSBhbnlPZmY7CgogICAgICAgIGZvciAoY29uc3QgaWQgb2YgaWRzKSB7CiAgICAgICAgICAgIHBhdGNo
UGlubmVkSW5DYWNoZXMoaWQsIG5leHQpOwogICAgICAgICAgICBjb25zdCB4ID0gYWxsQ2xpcHMuZmlu
ZCh0ID0+ICt0LmlkID09PSAraWQpOwogICAgICAgICAgICBpZiAoeCkgeC5waW5uZWQgPSBuZXh0Owog
ICAgICAgICAgICBpZiAoK2lkID09PSArYy5pZCkgYy5waW5uZWQgPSBuZXh0OwogICAgICAgICAgICBp
ZiAobmV4dCkgbWFya0ZhdlVuc2VlbihpZCk7CiAgICAgICAgICAgIGVsc2UgewogICAgICAgICAgICAg
ICAgdW5zZWVuRmF2SWRzLmRlbGV0ZShpZCk7CiAgICAgICAgICAgIH0KICAgICAgICB9CiAgICAgICAg
aWYgKCFuZXh0KSB7CiAgICAgICAgICAgIHNhdmVVbnNlZW5GYXYoKTsKICAgICAgICAgICAgdXBkYXRl
UGluRG90KCk7CiAgICAgICAgfQogICAgICAgIC8vIOaUtuiXj+mhteWPlua2iO+8mueri+WIu+S7juWI
l+ihqOaRmOaOiQogICAgICAgIGlmICghbmV4dCAmJiBjdXJUYWIgPT09ICdwaW5uZWQnKSB7CiAgICAg
ICAgICAgIGNvbnN0IGlkU2V0ID0gbmV3IFNldChpZHMpOwogICAgICAgICAgICBjb25zdCBiZWZvcmUg
PSBhbGxDbGlwcy5sZW5ndGg7CiAgICAgICAgICAgIGFsbENsaXBzID0gYWxsQ2xpcHMuZmlsdGVyKHgg
PT4gIWlkU2V0LmhhcygreC5pZCkpOwogICAgICAgICAgICBjb25zdCByZW1vdmVkID0gYmVmb3JlIC0g
YWxsQ2xpcHMubGVuZ3RoOwogICAgICAgICAgICBkaXNrVG90YWwgPSBNYXRoLm1heCgwLCAoTnVtYmVy
KGRpc2tUb3RhbCkgfHwgMCkgLSByZW1vdmVkKTsKICAgICAgICAgICAgcGlubmVkVG90YWwgPSBNYXRo
Lm1heCgwLCAoTnVtYmVyKHBpbm5lZFRvdGFsKSB8fCAwKSAtIHJlbW92ZWQpOwogICAgICAgICAgICBp
ZiAoaWRTZXQuaGFzKCtzZWxlY3RlZElkKSkKICAgICAgICAgICAgICAgIHNlbGVjdGVkSWQgPSBhbGxD
bGlwcy5sZW5ndGggPyBhbGxDbGlwc1swXS5pZCA6IDA7CiAgICAgICAgICAgIHRyeSB7CiAgICAgICAg
ICAgICAgICB2aWV3TWVtLnNldCh2aWV3TWVtS2V5KGN1clRhYiwgcXVlcnksIHRvZGF5T25seSksIHsK
ICAgICAgICAgICAgICAgICAgICBpdGVtczogYWxsQ2xpcHMuc2xpY2UoKSwKICAgICAgICAgICAgICAg
ICAgICB0b3RhbDogZGlza1RvdGFsCiAgICAgICAgICAgICAgICB9KTsKICAgICAgICAgICAgfSBjYXRj
aCB7fQogICAgICAgICAgICBjbGVhckZhdlVuc2VlbigpOwogICAgICAgIH0gZWxzZSBpZiAoY3VyVGFi
ID09PSAncGlubmVkJykgewogICAgICAgICAgICBjbGVhckZhdlVuc2VlbigpOwogICAgICAgIH0KICAg
ICAgICBpZiAoaWRzLmxlbmd0aCA+IDEpCiAgICAgICAgICAgIGNsZWFyTXVsdGkoKTsKICAgICAgICBy
ZW5kZXIoKTsKICAgICAgICBpZiAoaWRzLmxlbmd0aCA9PT0gMSkKICAgICAgICAgICAgYWhrKCdwaW5N
YW55JywgU3RyaW5nKGlkc1swXSksIG5leHQgPyAnMScgOiAnMCcpOwogICAgICAgIGVsc2UKICAgICAg
ICAgICAgYWhrKCdwaW5NYW55JywgaWRzLmpvaW4oJywnKSwgbmV4dCA/ICcxJyA6ICcwJyk7CiAgICB9
KTsKICAgIGN0eEJpbmQoJ2MtdG9wJywgICBjID0+IGFoaygnbW92ZVRvVG9wJywgICAgIFN0cmluZyhj
LmlkKSkpOwogICAgY3R4QmluZCgnYy1jbGVhci1wYXN0ZWQnLCBjID0+IGFoaygnY2xlYXJQYXN0ZWQn
LCBTdHJpbmcoYy5pZCkpKTsKICAgIGN0eEJpbmQoJ2MtcXVldWUtZnJvbScsIGMgPT4gewogICAgICAg
IGFoaygncmVzZXRRdWV1ZUZyb20nLCBTdHJpbmcoYy5pZCkpOwogICAgICAgIGlmICghcGlubmVkVUkp
IGFoaygnaGlkZScpOwogICAgfSk7CiAgICBjdHhCaW5kKCdjLWRlbCcsICAgYyA9PiB7CiAgICAgICAg
Ly8g5aSa6YCJ5LiU5Y+z6ZSu54K55Zyo6YCJ5Lit6aG55LiKIOKGkiDmibnph4/liKDpmaTvvJvlkKbl
iJnlj6rliKDlvZPliY0KICAgICAgICBsZXQgaWRzID0gW107CiAgICAgICAgaWYgKG11bHRpSWRzLmxl
bmd0aCA+IDEgJiYgbXVsdGlJZHMuaW5jbHVkZXMoK2MuaWQpKQogICAgICAgICAgICBpZHMgPSBtdWx0
aUlkcy5zbGljZSgpOwogICAgICAgIGVsc2UKICAgICAgICAgICAgaWRzID0gWytjLmlkXTsKICAgICAg
ICBpZHMgPSBpZHMubWFwKHggPT4gK3gpLmZpbHRlcih4ID0+IHggPiAwKTsKICAgICAgICBpZiAoIWlk
cy5sZW5ndGgpIHJldHVybjsKICAgICAgICB0cnkgewogICAgICAgICAgICBjb25zdCBpZFNldCA9IG5l
dyBTZXQoaWRzKTsKICAgICAgICAgICAgYWxsQ2xpcHMgPSBhbGxDbGlwcy5maWx0ZXIoeCA9PiAhaWRT
ZXQuaGFzKCt4LmlkKSk7CiAgICAgICAgICAgIGRpc2tUb3RhbCA9IE1hdGgubWF4KDAsIChOdW1iZXIo
ZGlza1RvdGFsKSB8fCAwKSAtIGlkcy5sZW5ndGgpOwogICAgICAgICAgICBpZiAoaWRTZXQuaGFzKCtz
ZWxlY3RlZElkKSkKICAgICAgICAgICAgICAgIHNlbGVjdGVkSWQgPSBhbGxDbGlwcy5sZW5ndGggPyBh
bGxDbGlwc1swXS5pZCA6IDA7CiAgICAgICAgICAgIGNsZWFyTXVsdGkoKTsKICAgICAgICAgICAgcmVu
ZGVyKCk7CiAgICAgICAgfSBjYXRjaCB7fQogICAgICAgIGlmIChpZHMubGVuZ3RoID09PSAxKQogICAg
ICAgICAgICBhaGsoJ2RlbGV0ZScsIFN0cmluZyhpZHNbMF0pKTsKICAgICAgICBlbHNlCiAgICAgICAg
ICAgIGFoaygnZGVsZXRlTWFueScsIGlkcy5qb2luKCcsJykpOwogICAgfSk7CiAgICBjdHhCaW5kKCdj
LXRpdGxlJywgYyA9PiBvcGVuVGl0bGVEbGcoYykpOwogICAgY3R4QmluZCgnYy1tZXJnZScsIGMgPT4g
ewogICAgICAgIGNvbnN0IGlkcyA9IChtdWx0aUlkcy5sZW5ndGggPj0gMikgPyBtdWx0aUlkcy5zbGlj
ZSgpIDogW107CiAgICAgICAgaWYgKGlkcy5sZW5ndGggPCAyKSByZXR1cm47CiAgICAgICAgaWYgKCFp
ZHMuaW5jbHVkZXMoK2MuaWQpKSBpZHMucHVzaCgrYy5pZCk7CiAgICAgICAgYWhrKCdtZXJnZUZhdics
IGlkcy5qb2luKCcsJykpOwogICAgICAgIGNsZWFyTXVsdGkoKTsKICAgIH0pOwogICAgY3R4QmluZCgn
Yy11bm1lcmdlJywgYyA9PiB7CiAgICAgICAgYWhrKCd1bm1lcmdlRmF2JywgU3RyaW5nKGMuaWQpKTsK
ICAgICAgICBjbGVhck11bHRpKCk7CiAgICB9KTsKCiAgICBjb25zdCB0aXRsZURsZyA9IGRvY3VtZW50
LmdldEVsZW1lbnRCeUlkKCd0aXRsZS1kbGcnKTsKICAgIGNvbnN0IHRpdGxlSW5wdXQgPSBkb2N1bWVu
dC5nZXRFbGVtZW50QnlJZCgndGl0bGUtaW5wdXQnKTsKICAgIGxldCB0aXRsZURsZ0NsaXAgPSBudWxs
OwogICAgZnVuY3Rpb24gY2xvc2VUaXRsZURsZygpIHsKICAgICAgICBpZiAodGl0bGVEbGcpIHRpdGxl
RGxnLmNsYXNzTGlzdC5yZW1vdmUoJ29uJyk7CiAgICAgICAgdGl0bGVEbGdDbGlwID0gbnVsbDsKICAg
IH0KICAgIGZ1bmN0aW9uIG9wZW5UaXRsZURsZyhjKSB7CiAgICAgICAgaGlkZUN0eCgpOwogICAgICAg
IHRpdGxlRGxnQ2xpcCA9IGM7CiAgICAgICAgaWYgKHRpdGxlSW5wdXQpIHRpdGxlSW5wdXQudmFsdWUg
PSBTdHJpbmcoYy5mYXZUaXRsZSB8fCAnJykudHJpbSgpOwogICAgICAgIGlmICh0aXRsZURsZykgdGl0
bGVEbGcuY2xhc3NMaXN0LmFkZCgnb24nKTsKICAgICAgICBhaGsoJ2ZvY3VzUGFuZWwnKTsKICAgICAg
ICByZXF1ZXN0QW5pbWF0aW9uRnJhbWUoKCkgPT4gewogICAgICAgICAgICB0cnkgeyB0aXRsZUlucHV0
LmZvY3VzKCk7IHRpdGxlSW5wdXQuc2VsZWN0KCk7IH0gY2F0Y2gge30KICAgICAgICB9KTsKICAgIH0K
ICAgIGlmICh0aXRsZURsZykgewogICAgICAgIHRpdGxlRGxnLmFkZEV2ZW50TGlzdGVuZXIoJ2NsaWNr
JywgZSA9PiB7CiAgICAgICAgICAgIGlmIChlLnRhcmdldCA9PT0gdGl0bGVEbGcpIGNsb3NlVGl0bGVE
bGcoKTsKICAgICAgICB9KTsKICAgIH0KICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd0aXRsZS1j
YW5jZWwnKT8uYWRkRXZlbnRMaXN0ZW5lcignY2xpY2snLCBlID0+IHsKICAgICAgICBlLnN0b3BQcm9w
YWdhdGlvbigpOwogICAgICAgIGNsb3NlVGl0bGVEbGcoKTsKICAgICAgICBhaGsoJ2JsdXJQYW5lbCcp
OwogICAgfSk7CiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgndGl0bGUtb2snKT8uYWRkRXZlbnRM
aXN0ZW5lcignY2xpY2snLCBlID0+IHsKICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgICAg
IGlmICghdGl0bGVEbGdDbGlwKSByZXR1cm47CiAgICAgICAgY29uc3QgdCA9IFN0cmluZyh0aXRsZUlu
cHV0Py52YWx1ZSB8fCAnJykudHJpbSgpLnNsaWNlKDAsIDgwKTsKICAgICAgICBjb25zdCBpZCA9IFN0
cmluZyh0aXRsZURsZ0NsaXAuaWQpOwogICAgICAgIC8vIE9wdGltaXN0aWMgbG9jYWwgdXBkYXRlCiAg
ICAgICAgY29uc3QgaGl0ID0gYWxsQ2xpcHMuZmluZCh4ID0+ICt4LmlkID09PSAraWQpOwogICAgICAg
IGlmIChoaXQpIGhpdC5mYXZUaXRsZSA9IHQ7CiAgICAgICAgdGl0bGVEbGdDbGlwLmZhdlRpdGxlID0g
dDsKICAgICAgICBjbG9zZVRpdGxlRGxnKCk7CiAgICAgICAgYWhrKCdzZXRGYXZUaXRsZScsIGlkLCB0
KTsKICAgICAgICBhaGsoJ2JsdXJQYW5lbCcpOwogICAgICAgIHJlbmRlcigpOwogICAgfSk7CiAgICB0
aXRsZUlucHV0Py5hZGRFdmVudExpc3RlbmVyKCdrZXlkb3duJywgZSA9PiB7CiAgICAgICAgaWYgKGUu
a2V5ID09PSAnRW50ZXInKSB7CiAgICAgICAgICAgIGUucHJldmVudERlZmF1bHQoKTsKICAgICAgICAg
ICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICAgICAgZS5zdG9wSW1tZWRpYXRlUHJvcGFnYXRp
b24oKTsKICAgICAgICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3RpdGxlLW9rJyk/LmNsaWNr
KCk7CiAgICAgICAgICAgIHJldHVybjsKICAgICAgICB9CiAgICAgICAgaWYgKGUua2V5ID09PSAnRXNj
YXBlJykgewogICAgICAgICAgICBlLnByZXZlbnREZWZhdWx0KCk7CiAgICAgICAgICAgIGUuc3RvcFBy
b3BhZ2F0aW9uKCk7CiAgICAgICAgICAgIGNsb3NlVGl0bGVEbGcoKTsKICAgICAgICAgICAgYWhrKCdi
bHVyUGFuZWwnKTsKICAgICAgICAgICAgcmV0dXJuOwogICAgICAgIH0KICAgICAgICBlLnN0b3BQcm9w
YWdhdGlvbigpOwogICAgfSwgdHJ1ZSk7CgogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3RhYnMn
KS5hZGRFdmVudExpc3RlbmVyKCdjbGljaycsIGUgPT4gewogICAgICAgIGNvbnN0IHRhYiA9IGUudGFy
Z2V0LmNsb3Nlc3QoJy50YWInKTsKICAgICAgICBpZiAoIXRhYiB8fCBlLnRhcmdldC5jbG9zZXN0KCcj
dGFiLWFjdGlvbnMnKSkgcmV0dXJuOwogICAgICAgIHNldFRhYih0YWIuZGF0YXNldC50YWIpOwogICAg
fSk7CgogICAgY29uc3Qgc3JjaFdyYXAgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc2VhcmNoLXdy
YXAnKTsKICAgIGNvbnN0IGJ0blNlYXJjaCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdidG4tc2Vh
cmNoJyk7CiAgICBjb25zdCBidG5Mb2NhdGUgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYnRuLWxv
Y2F0ZScpOwogICAgY29uc3QgYnRuVG9kYXkgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYnRuLXRv
ZGF5Jyk7CiAgICBjb25zdCBzcmNoID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NlYXJjaCcpOwog
ICAgY29uc3Qgc2NsciA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzZWFyY2gtY2xyJyk7CiAgICBs
ZXQgZGViOwoKICAgIHVwZGF0ZUxvY2F0ZUJ0bigpOwogICAgaWYgKGJ0bkxvY2F0ZSkgewogICAgICAg
IGJ0bkxvY2F0ZS5hZGRFdmVudExpc3RlbmVyKCdjbGljaycsIGUgPT4gewogICAgICAgICAgICBlLnN0
b3BQcm9wYWdhdGlvbigpOwogICAgICAgICAgICBqdW1wVG9MYXN0UGFzdGUoKTsKICAgICAgICB9KTsK
ICAgIH0KCiAgICBidG5Ub2RheS5hZGRFdmVudExpc3RlbmVyKCdtb3VzZWRvd24nLCBlID0+IHsKICAg
ICAgICBlLnByZXZlbnREZWZhdWx0KCk7CiAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgIH0p
OwogICAgYnRuVG9kYXkuYWRkRXZlbnRMaXN0ZW5lcignY2xpY2snLCBlID0+IHsKICAgICAgICBlLnN0
b3BQcm9wYWdhdGlvbigpOwogICAgICAgIGUucHJldmVudERlZmF1bHQoKTsKICAgICAgICB0b2RheU9u
bHkgPSAhdG9kYXlPbmx5OwogICAgICAgIGJ0blRvZGF5LmNsYXNzTGlzdC50b2dnbGUoJ29uJywgdG9k
YXlPbmx5KTsKICAgICAgICBsaXN0RWwuc2Nyb2xsVG9wID0gMDsKICAgICAgICByZXF1ZXN0Vmlldygp
OwogICAgICAgIHRyeSB7IHNyY2guZm9jdXMoKTsgfSBjYXRjaCB7fQogICAgfSk7CgogICAgZnVuY3Rp
b24gb3BlblNlYXJjaCgpIHsKICAgICAgICBpZiAoc3JjaFdyYXAuY2xhc3NMaXN0LmNvbnRhaW5zKCdv
cGVuJykpIHsKICAgICAgICAgICAgYWhrKCdmb2N1c1BhbmVsJyk7CiAgICAgICAgICAgIHRyeSB7IHNy
Y2guZm9jdXMoKTsgfSBjYXRjaCB7fQogICAgICAgICAgICByZXR1cm47CiAgICAgICAgfQogICAgICAg
IHNyY2hXcmFwLmNsYXNzTGlzdC5hZGQoJ29wZW4nKTsKICAgICAgICAvLyBEZWZhdWx0OiDmiYDmnInp
obXmiZPlvIDmkJzntKLml7bpu5jorqTmkJzlhajpg6gKICAgICAgICBjb25zdCB3YW50VG9kYXkgPSBm
YWxzZTsKICAgICAgICBpZiAodG9kYXlPbmx5ICE9PSB3YW50VG9kYXkpIHsKICAgICAgICAgICAgdG9k
YXlPbmx5ID0gd2FudFRvZGF5OwogICAgICAgICAgICBidG5Ub2RheS5jbGFzc0xpc3QudG9nZ2xlKCdv
bicsIHRvZGF5T25seSk7CiAgICAgICAgICAgIGxpc3RFbC5zY3JvbGxUb3AgPSAwOwogICAgICAgICAg
ICByZXF1ZXN0VmlldygpOwogICAgICAgIH0gZWxzZSB7CiAgICAgICAgICAgIGJ0blRvZGF5LmNsYXNz
TGlzdC50b2dnbGUoJ29uJywgdG9kYXlPbmx5KTsKICAgICAgICB9CiAgICAgICAgYWhrKCdmb2N1c1Bh
bmVsJyk7CiAgICAgICAgcmVxdWVzdEFuaW1hdGlvbkZyYW1lKCgpID0+IHsKICAgICAgICAgICAgdHJ5
IHsgc3JjaC5mb2N1cygpOyB9IGNhdGNoIHt9CiAgICAgICAgfSk7CiAgICB9CiAgICBmdW5jdGlvbiBj
bG9zZVNlYXJjaFVpKCkgewogICAgICAgIHNyY2hXcmFwLmNsYXNzTGlzdC5yZW1vdmUoJ29wZW4nKTsK
ICAgICAgICBpZiAoIXNyY2gudmFsdWUpIHsKICAgICAgICAgICAgc3JjaC5jbGFzc0xpc3QucmVtb3Zl
KCdoYXMtdmFsJyk7CiAgICAgICAgICAgIHNjbHIuc3R5bGUuZGlzcGxheSA9ICdub25lJzsKICAgICAg
ICAgICAgLy8gTGVhdmluZyBzZWFyY2ggd2l0aCBlbXB0eSBxdWVyeSDihpIgZHJvcCB0b2RheSBmaWx0
ZXIKICAgICAgICAgICAgaWYgKHRvZGF5T25seSkgewogICAgICAgICAgICAgICAgdG9kYXlPbmx5ID0g
ZmFsc2U7CiAgICAgICAgICAgICAgICBidG5Ub2RheS5jbGFzc0xpc3QucmVtb3ZlKCdvbicpOwogICAg
ICAgICAgICAgICAgcmVxdWVzdFZpZXcoKTsKICAgICAgICAgICAgfQogICAgICAgIH0KICAgIH0KICAg
IHdpbmRvdy5fX29wZW5TZWFyY2ggPSBvcGVuU2VhcmNoOwogICAgd2luZG93Ll9fcHJlcFR5cGVTZWFy
Y2ggPSAoKSA9PiB7CiAgICAgICAgdHJ5IHsKICAgICAgICAgICAgY29uc3Qgd3JhcCA9IGRvY3VtZW50
LmdldEVsZW1lbnRCeUlkKCdzZWFyY2gtd3JhcCcpOwogICAgICAgICAgICBjb25zdCBzID0gZG9jdW1l
bnQuZ2V0RWxlbWVudEJ5SWQoJ3NlYXJjaCcpOwogICAgICAgICAgICBpZiAod3JhcCAmJiAhd3JhcC5j
bGFzc0xpc3QuY29udGFpbnMoJ29wZW4nKSkgewogICAgICAgICAgICAgICAgd3JhcC5jbGFzc0xpc3Qu
YWRkKCdvcGVuJyk7CiAgICAgICAgICAgICAgICB0cnkgewogICAgICAgICAgICAgICAgICAgIGNvbnN0
IHdhbnRUb2RheSA9IGZhbHNlOwogICAgICAgICAgICAgICAgICAgIGlmICh0eXBlb2YgdG9kYXlPbmx5
ICE9PSAndW5kZWZpbmVkJyAmJiB0b2RheU9ubHkgIT09IHdhbnRUb2RheSkgewogICAgICAgICAgICAg
ICAgICAgICAgICB0b2RheU9ubHkgPSB3YW50VG9kYXk7CiAgICAgICAgICAgICAgICAgICAgICAgIGlm
ICh0eXBlb2YgYnRuVG9kYXkgIT09ICd1bmRlZmluZWQnICYmIGJ0blRvZGF5KSBidG5Ub2RheS5jbGFz
c0xpc3QudG9nZ2xlKCdvbicsIHRvZGF5T25seSk7CiAgICAgICAgICAgICAgICAgICAgICAgIGlmICh0
eXBlb2YgbGlzdEVsICE9PSAndW5kZWZpbmVkJyAmJiBsaXN0RWwpIGxpc3RFbC5zY3JvbGxUb3AgPSAw
OwogICAgICAgICAgICAgICAgICAgICAgICBpZiAodHlwZW9mIHJlcXVlc3RWaWV3ID09PSAnZnVuY3Rp
b24nKSBzZXRUaW1lb3V0KHJlcXVlc3RWaWV3LCAwKTsKICAgICAgICAgICAgICAgICAgICB9IGVsc2Ug
aWYgKHR5cGVvZiBidG5Ub2RheSAhPT0gJ3VuZGVmaW5lZCcgJiYgYnRuVG9kYXkpIHsKICAgICAgICAg
ICAgICAgICAgICAgICAgYnRuVG9kYXkuY2xhc3NMaXN0LnRvZ2dsZSgnb24nLCAhIXRvZGF5T25seSk7
CiAgICAgICAgICAgICAgICAgICAgfQogICAgICAgICAgICAgICAgfSBjYXRjaCB7fQogICAgICAgICAg
ICB9CiAgICAgICAgICAgIC8vID8/IOmVnOWDj+aQnOe0ou+8muS4jeimgSBmb2N1c++8jOmBv+WFjeaK
oui1sOWOn+e8lui+keahhuWFieaghwogICAgICAgIH0gY2F0Y2gge30KICAgIH07CiAgICB3aW5kb3cu
X190eXBlU2VhcmNoID0gKGNoKSA9PiB7CiAgICAgICAgdHJ5IHsKICAgICAgICAgICAgd2luZG93Ll9f
cHJlcFR5cGVTZWFyY2ggJiYgd2luZG93Ll9fcHJlcFR5cGVTZWFyY2goKTsKICAgICAgICAgICAgY29u
c3QgcyA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzZWFyY2gnKTsKICAgICAgICAgICAgaWYgKCFz
KSByZXR1cm47CiAgICAgICAgICAgIHMudmFsdWUgPSBTdHJpbmcocy52YWx1ZSB8fCAnJykgKyBTdHJp
bmcoY2ggPT0gbnVsbCA/ICcnIDogY2gpOwogICAgICAgICAgICBzLmNsYXNzTGlzdC50b2dnbGUoJ2hh
cy12YWwnLCAhIXMudmFsdWUpOwogICAgICAgICAgICBzLmRpc3BhdGNoRXZlbnQobmV3IEV2ZW50KCdp
bnB1dCcsIHsgYnViYmxlczogdHJ1ZSB9KSk7CiAgICAgICAgfSBjYXRjaCB7fQogICAgfTsKICAgIHdp
bmRvdy5fX2Jrc3BTZWFyY2ggPSAoKSA9PiB7CiAgICAgICAgdHJ5IHsKICAgICAgICAgICAgd2luZG93
Ll9fcHJlcFR5cGVTZWFyY2ggJiYgd2luZG93Ll9fcHJlcFR5cGVTZWFyY2goKTsKICAgICAgICAgICAg
Y29uc3QgcyA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzZWFyY2gnKTsKICAgICAgICAgICAgaWYg
KCFzKSByZXR1cm47CiAgICAgICAgICAgIGNvbnN0IHYgPSBTdHJpbmcocy52YWx1ZSB8fCAnJyk7CiAg
ICAgICAgICAgIHMudmFsdWUgPSB2Lmxlbmd0aCA/IHYuc2xpY2UoMCwgLTEpIDogJyc7CiAgICAgICAg
ICAgIHMuY2xhc3NMaXN0LnRvZ2dsZSgnaGFzLXZhbCcsICEhcy52YWx1ZSk7CiAgICAgICAgICAgIHMu
ZGlzcGF0Y2hFdmVudChuZXcgRXZlbnQoJ2lucHV0JywgeyBidWJibGVzOiB0cnVlIH0pKTsKICAgICAg
ICB9IGNhdGNoIHt9CiAgICB9OwogICAgd2luZG93Ll9fc2V0U2VhcmNoUXVlcnkgPSAocSkgPT4gewog
ICAgICAgIHRyeSB7CiAgICAgICAgICAgIGNvbnN0IHMgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgn
c2VhcmNoJyk7CiAgICAgICAgICAgIGlmICghcykgcmV0dXJuOwogICAgICAgICAgICBjb25zdCBuZXh0
ID0gU3RyaW5nKHEgPT0gbnVsbCA/ICcnIDogcSk7CiAgICAgICAgICAgIGNvbnN0IHByZXYgPSBTdHJp
bmcocy52YWx1ZSB8fCAnJyk7CiAgICAgICAgICAgIC8vIOWQjOWFs+mUruWtl+mHjeWkjeaOqOmAge+8
muWPquS/neivgeaQnOe0ouahhuW8gOedgO+8jOemgeatouWGjSByZXF1ZXN0Vmlld++8iOS8muatu+W+
queOr+mXqu+8iQogICAgICAgICAgICBpZiAocHJldiA9PT0gbmV4dCAmJiBTdHJpbmcocXVlcnkgfHwg
JycpID09PSBuZXh0KSB7CiAgICAgICAgICAgICAgICB0cnkgewogICAgICAgICAgICAgICAgICAgIGNv
bnN0IHdyYXAgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc2VhcmNoLXdyYXAnKTsKICAgICAgICAg
ICAgICAgICAgICBpZiAod3JhcCAmJiAhd3JhcC5jbGFzc0xpc3QuY29udGFpbnMoJ29wZW4nKSkKICAg
ICAgICAgICAgICAgICAgICAgICAgd3JhcC5jbGFzc0xpc3QuYWRkKCdvcGVuJyk7CiAgICAgICAgICAg
ICAgICB9IGNhdGNoIHt9CiAgICAgICAgICAgICAgICByZXR1cm47CiAgICAgICAgICAgIH0KICAgICAg
ICAgICAgLy8g5omT5a2X5Y2z5pe25LiK5bGP77yM5LiO56OB55uY5pCc57Si6Kej6ICmCiAgICAgICAg
ICAgIHMudmFsdWUgPSBuZXh0OwogICAgICAgICAgICBzLmNsYXNzTGlzdC50b2dnbGUoJ2hhcy12YWwn
LCAhIXMudmFsdWUpOwogICAgICAgICAgICBjb25zdCBzY2xyID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5
SWQoJ3NlYXJjaC1jbHInKTsKICAgICAgICAgICAgaWYgKHNjbHIpIHNjbHIuc3R5bGUuZGlzcGxheSA9
IHMudmFsdWUgPyAnYmxvY2snIDogJ25vbmUnOwogICAgICAgICAgICBxdWVyeSA9IHMudmFsdWU7CiAg
ICAgICAgICAgIHRyeSB7CiAgICAgICAgICAgICAgICBjb25zdCB3cmFwID0gZG9jdW1lbnQuZ2V0RWxl
bWVudEJ5SWQoJ3NlYXJjaC13cmFwJyk7CiAgICAgICAgICAgICAgICBpZiAod3JhcCAmJiAhd3JhcC5j
bGFzc0xpc3QuY29udGFpbnMoJ29wZW4nKSkKICAgICAgICAgICAgICAgICAgICB3aW5kb3cuX19wcmVw
VHlwZVNlYXJjaCAmJiB3aW5kb3cuX19wcmVwVHlwZVNlYXJjaCgpOwogICAgICAgICAgICAgICAgZWxz
ZSBpZiAod3JhcCkKICAgICAgICAgICAgICAgICAgICB3cmFwLmNsYXNzTGlzdC5hZGQoJ29wZW4nKTsK
ICAgICAgICAgICAgfSBjYXRjaCB7fQogICAgICAgICAgICB3aW5kb3cuX19ob3N0RmlsdGVyZWQgPSBm
YWxzZTsKICAgICAgICAgICAgd2luZG93Ll9faG9zdEZpbHRlclEgPSAnJzsKICAgICAgICAgICAgaWYg
KFN0cmluZyhxdWVyeSB8fCAnJykudHJpbSgpKSB7CiAgICAgICAgICAgICAgICB3YWl0aW5nRGF0YSA9
IHRydWU7CiAgICAgICAgICAgICAgICB3aW5kb3cuX19kYXRhUmVhZHkgPSBmYWxzZTsKICAgICAgICAg
ICAgfQogICAgICAgICAgICB0cnkgewogICAgICAgICAgICAgICAgY29uc3QgY250ID0gZG9jdW1lbnQu
Z2V0RWxlbWVudEJ5SWQoJ2Jhci10eHQnKTsKICAgICAgICAgICAgICAgIGlmIChjbnQgJiYgU3RyaW5n
KHF1ZXJ5IHx8ICcnKS50cmltKCkpCiAgICAgICAgICAgICAgICAgICAgY250LnRleHRDb250ZW50ID0g
dmlzaWJsZUxpc3QoKS5sZW5ndGggKyAnIOadoSc7CiAgICAgICAgICAgIH0gY2F0Y2gge30KICAgICAg
ICAgICAgdHJ5IHsgcmVuZGVyKCk7IH0gY2F0Y2gge30KICAgICAgICAgICAgY2xlYXJUaW1lb3V0KHdp
bmRvdy5fX3FxVmlld0RlYik7CiAgICAgICAgICAgIHdpbmRvdy5fX3FxVmlld0RlYiA9IHNldFRpbWVv
dXQoKCkgPT4gewogICAgICAgICAgICAgICAgd2luZG93Ll9fcXFWaWV3RGViID0gMDsKICAgICAgICAg
ICAgICAgIHJlcXVlc3RWaWV3KCk7CiAgICAgICAgICAgIH0sIDcwKTsKICAgICAgICB9IGNhdGNoIHt9
CiAgICB9OwogICAgd2luZG93Ll9fY2xlYXJRUVNlYXJjaCA9ICgpID0+IHsKICAgICAgICB0cnkgewog
ICAgICAgICAgICBxdWVyeSA9ICcnOwogICAgICAgICAgICB3aW5kb3cuX19ob3N0RmlsdGVyZWQgPSBm
YWxzZTsKICAgICAgICAgICAgd2luZG93Ll9faG9zdEZpbHRlclEgPSAnJzsKICAgICAgICAgICAgY29u
c3QgcyA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzZWFyY2gnKTsKICAgICAgICAgICAgaWYgKHMp
IHsKICAgICAgICAgICAgICAgIHMudmFsdWUgPSAnJzsKICAgICAgICAgICAgICAgIHMuY2xhc3NMaXN0
LnJlbW92ZSgnaGFzLXZhbCcpOwogICAgICAgICAgICAgICAgdHJ5IHsgcy5ibHVyKCk7IH0gY2F0Y2gg
e30KICAgICAgICAgICAgfQogICAgICAgICAgICBjb25zdCBzY2xyID0gZG9jdW1lbnQuZ2V0RWxlbWVu
dEJ5SWQoJ3NlYXJjaC1jbHInKTsKICAgICAgICAgICAgaWYgKHNjbHIpIHNjbHIuc3R5bGUuZGlzcGxh
eSA9ICdub25lJzsKICAgICAgICAgICAgY29uc3Qgd3JhcCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlk
KCdzZWFyY2gtd3JhcCcpOwogICAgICAgICAgICBpZiAod3JhcCkgd3JhcC5jbGFzc0xpc3QucmVtb3Zl
KCdvcGVuJyk7CiAgICAgICAgICAgIHRyeSB7IHJlbmRlcigpOyB9IGNhdGNoIHt9CiAgICAgICAgfSBj
YXRjaCB7fQogICAgfTsKICAgIC8vIENhcHR1cmUgQ3RybCtGIGluc2lkZSBXZWJWaWV3IChDaHJvbWl1
bSBmaW5kIGlzIGRpc2FibGVkLCBidXQgc3RpbGwgaGFuZGxlIGhlcmUpCiAgICBkb2N1bWVudC5hZGRF
dmVudExpc3RlbmVyKCdrZXlkb3duJywgZSA9PiB7CiAgICAgICAgaWYgKChlLmN0cmxLZXkgfHwgZS5t
ZXRhS2V5KSAmJiAhZS5hbHRLZXkgJiYgKGUua2V5ID09PSAnZicgfHwgZS5rZXkgPT09ICdGJykpIHsK
ICAgICAgICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOwogICAgICAgICAgICBlLnN0b3BQcm9wYWdhdGlv
bigpOwogICAgICAgICAgICBvcGVuU2VhcmNoKCk7CiAgICAgICAgfQogICAgfSwgdHJ1ZSk7CiAgICBi
dG5TZWFyY2guYWRkRXZlbnRMaXN0ZW5lcignY2xpY2snLCBlID0+IHsKICAgICAgICBlLnN0b3BQcm9w
YWdhdGlvbigpOwogICAgICAgIG9wZW5TZWFyY2goKTsKICAgIH0pOwogICAgbGV0IF9fc3JjaENvbXBv
c2luZyA9IGZhbHNlOwogICAgY29uc3QgX19mbHVzaFNlYXJjaElucHV0ID0gKCkgPT4gewogICAgICAg
IHF1ZXJ5ID0gc3JjaC52YWx1ZTsKICAgICAgICBzcmNoLmNsYXNzTGlzdC50b2dnbGUoJ2hhcy12YWwn
LCAhIXF1ZXJ5KTsKICAgICAgICBzY2xyLnN0eWxlLmRpc3BsYXkgPSBxdWVyeSA/ICdibG9jaycgOiAn
bm9uZSc7CiAgICAgICAgbGlzdEVsLnNjcm9sbFRvcCA9IDA7CiAgICAgICAgd2luZG93Ll9faG9zdEZp
bHRlcmVkID0gZmFsc2U7CiAgICAgICAgd2luZG93Ll9faG9zdEZpbHRlclEgPSAnJzsKICAgICAgICB0
cnkgeyByZW5kZXIoKTsgfSBjYXRjaCB7fQogICAgICAgIGNsZWFyVGltZW91dChkZWIpOwogICAgICAg
IGRlYiA9IHNldFRpbWVvdXQocmVxdWVzdFZpZXcsIDgwKTsKICAgIH07CiAgICBzcmNoLmFkZEV2ZW50
TGlzdGVuZXIoJ2NvbXBvc2l0aW9uc3RhcnQnLCAoKSA9PiB7IF9fc3JjaENvbXBvc2luZyA9IHRydWU7
IH0pOwogICAgc3JjaC5hZGRFdmVudExpc3RlbmVyKCdjb21wb3NpdGlvbmVuZCcsICgpID0+IHsKICAg
ICAgICBfX3NyY2hDb21wb3NpbmcgPSBmYWxzZTsKICAgICAgICBfX2ZsdXNoU2VhcmNoSW5wdXQoKTsK
ICAgIH0pOwogICAgc3JjaC5hZGRFdmVudExpc3RlbmVyKCdpbnB1dCcsICgpID0+IHsKICAgICAgICBp
ZiAoX19zcmNoQ29tcG9zaW5nKSB7CiAgICAgICAgICAgIHF1ZXJ5ID0gc3JjaC52YWx1ZTsKICAgICAg
ICAgICAgc3JjaC5jbGFzc0xpc3QudG9nZ2xlKCdoYXMtdmFsJywgISFxdWVyeSk7CiAgICAgICAgICAg
IHNjbHIuc3R5bGUuZGlzcGxheSA9IHF1ZXJ5ID8gJ2Jsb2NrJyA6ICdub25lJzsKICAgICAgICAgICAg
cmV0dXJuOwogICAgICAgIH0KICAgICAgICBfX2ZsdXNoU2VhcmNoSW5wdXQoKTsKICAgIH0pOwogICAg
c3JjaC5hZGRFdmVudExpc3RlbmVyKCdmb2N1cycsICgpID0+IHsKICAgICAgICAvLyBJZGVtcG90ZW50
IG9uIEFISyBzaWRlIOKAlCBzYWZlLCBidXQgYXZvaWQgc3BhbW1pbmcgZHVyaW5nIElNRQogICAgICAg
IHRyeSB7IGFoaygnZm9jdXNQYW5lbCcpOyB9IGNhdGNoIHt9CiAgICB9KTsKICAgIHNyY2guYWRkRXZl
bnRMaXN0ZW5lcignYmx1cicsICgpID0+IHsKICAgICAgICBzZXRUaW1lb3V0KCgpID0+IHsKICAgICAg
ICAgICAgaWYgKGRvY3VtZW50LmFjdGl2ZUVsZW1lbnQgPT09IHNyY2gpIHJldHVybjsKICAgICAgICAg
ICAgaWYgKGRvY3VtZW50LmFjdGl2ZUVsZW1lbnQgPT09IHNjbHIgfHwgKHNjbHIgJiYgc2Nsci5jb250
YWlucyhkb2N1bWVudC5hY3RpdmVFbGVtZW50KSkpIHJldHVybjsKICAgICAgICAgICAgaWYgKGRvY3Vt
ZW50LmFjdGl2ZUVsZW1lbnQgPT09IGJ0blRvZGF5IHx8IChidG5Ub2RheSAmJiBidG5Ub2RheS5jb250
YWlucyhkb2N1bWVudC5hY3RpdmVFbGVtZW50KSkpIHJldHVybjsKICAgICAgICAgICAgLy8gSU1FIGNh
bmRpZGF0ZSBVSSBzdGVhbHMgZm9jdXMgYnJpZWZseSDigJQga2VlcCBzZWFyY2ggaWYgc3RpbGwgY29t
cG9zaW5nCiAgICAgICAgICAgIGlmIChfX3NyY2hDb21wb3NpbmcpIHJldHVybjsKICAgICAgICAgICAg
Y2xvc2VTZWFyY2hVaSgpOwogICAgICAgICAgICBhaGsoJ2JsdXJQYW5lbCcpOwogICAgICAgIH0sIDI4
MCk7CiAgICB9KTsKICAgIHNyY2guYWRkRXZlbnRMaXN0ZW5lcigna2V5ZG93bicsIGUgPT4gewogICAg
ICAgIC8vIEN0cmwrSSAvIEN0cmwrSzogbW92ZSBjbGlwIHNlbGVjdGlvbiAobm90IGluc2VydCBjaGFy
IC8gYnJvd3NlciBzaG9ydGN1dCkKICAgICAgICBpZiAoKGUuY3RybEtleSB8fCBlLm1ldGFLZXkpICYm
IChlLmtleSA9PT0gJ2knIHx8IGUua2V5ID09PSAnSScpKSB7CiAgICAgICAgICAgIGUucHJldmVudERl
ZmF1bHQoKTsKICAgICAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICAgICAgd2luZG93
Ll9fbmF2ICYmIHdpbmRvdy5fX25hdigndXAnKTsKICAgICAgICAgICAgcmV0dXJuOwogICAgICAgIH0K
ICAgICAgICBpZiAoKGUuY3RybEtleSB8fCBlLm1ldGFLZXkpICYmIChlLmtleSA9PT0gJ2snIHx8IGUu
a2V5ID09PSAnSycpKSB7CiAgICAgICAgICAgIGUucHJldmVudERlZmF1bHQoKTsKICAgICAgICAgICAg
ZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICAgICAgd2luZG93Ll9fbmF2ICYmIHdpbmRvdy5fX25h
dignZG93bicpOwogICAgICAgICAgICByZXR1cm47CiAgICAgICAgfQogICAgICAgIGlmIChlLmtleSA9
PT0gJ0Fycm93RG93bicpIHsKICAgICAgICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOwogICAgICAgICAg
ICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgICAgICAgICB3aW5kb3cuX19uYXYgJiYgd2luZG93Ll9f
bmF2KCdkb3duJyk7CiAgICAgICAgICAgIHJldHVybjsKICAgICAgICB9CiAgICAgICAgaWYgKGUua2V5
ID09PSAnQXJyb3dVcCcpIHsKICAgICAgICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOwogICAgICAgICAg
ICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgICAgICAgICB3aW5kb3cuX19uYXYgJiYgd2luZG93Ll9f
bmF2KCd1cCcpOwogICAgICAgICAgICByZXR1cm47CiAgICAgICAgfQogICAgICAgIGlmIChlLmtleSA9
PT0gJ0VzY2FwZScpIHsKICAgICAgICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOwogICAgICAgICAgICBl
LnN0b3BQcm9wYWdhdGlvbigpOwogICAgICAgICAgICAvLyBBbHdheXMgZGlzbWlzcyB0aGUgd2hvbGUg
cGFuZWwgKG5vdCBqdXN0IHRoZSBzZWFyY2ggZmllbGQpCiAgICAgICAgICAgIGlmICghcGlubmVkVUkp
IGFoaygnaGlkZScpOwogICAgICAgICAgICByZXR1cm47CiAgICAgICAgfQogICAgICAgIGUuc3RvcFBy
b3BhZ2F0aW9uKCk7CiAgICB9KTsKICAgIHNjbHIuYWRkRXZlbnRMaXN0ZW5lcignY2xpY2snLCBlID0+
IHsKICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgICAgIHNyY2gudmFsdWUgPSBxdWVyeSA9
ICcnOwogICAgICAgIHNjbHIuc3R5bGUuZGlzcGxheSA9ICdub25lJzsKICAgICAgICBzcmNoLmNsYXNz
TGlzdC5yZW1vdmUoJ2hhcy12YWwnKTsKICAgICAgICByZXF1ZXN0VmlldygpOwogICAgICAgIGFoaygn
Zm9jdXNQYW5lbCcpOwogICAgICAgIHNyY2guZm9jdXMoKTsKICAgIH0pOwoKICAgIGNvbnN0IFRBQl9O
QU1FUyA9IHsgYWxsOiAn5YWo6YOoJywgdGV4dDogJ+aWh+acrCcsIGltYWdlOiAn5Zu+5YOPJywgZmls
ZTogJ+aWh+S7ticsIHJlY2VudDogJ+acgOi/kScsIHBpbm5lZDogJ+aUtuiXjycgfTsKICAgIGNvbnN0
IGNsckRsZyA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjbHItZGxnJyk7CiAgICBjb25zdCBjbHJB
bGxDYiA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjbHItYWxsJyk7CiAgICBmdW5jdGlvbiBvcGVu
Q2xlYXJEbGcoKSB7CiAgICAgICAgY29uc3QgbmFtZSA9IFRBQl9OQU1FU1tjdXJUYWJdIHx8ICflvZPl
iY0nOwogICAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjbHItdGl0bGUnKS50ZXh0Q29udGVu
dCA9ICfmuIXnqbrjgIwnICsgbmFtZSArICfjgI3vvJ8nOwogICAgICAgIGRvY3VtZW50LmdldEVsZW1l
bnRCeUlkKCdjbHItZGVzYycpLnRleHRDb250ZW50ID0gY3VyVGFiID09PSAncGlubmVkJwogICAgICAg
ICAgICA/ICfpu5jorqTku4XmuIXnqbrlvZPlpKnnmoTmlLbol4/pobnjgILli77pgInjgIzmuIXnqbrm
iYDmnInjgI3lj6/muIXpmaTor6XpgInpobnljaHlhajpg6jlhoXlrrnjgIInCiAgICAgICAgICAgIDog
KGN1clRhYiA9PT0gJ3JlY2VudCcKICAgICAgICAgICAgICAgID8gJ+a4heepuuOAjOacgOi/keOAjeS8
muWIoOmZpOacquWbuuWumueahOacgOi/keebruW9leiusOW9le+8m+W3suWbuuWumueahOebruW9leS8
muS/neeVmeOAgicKICAgICAgICAgICAgICAgIDogJ+S7hea4heepuuW9k+WJjemAiemhueWNoeOAgum7
mOiupOWPqua4heW9k+Wkqe+8m+aUtuiXj+mhueS4jeS8muiiq+a4hemZpOOAguWLvumAieOAjOa4heep
uuaJgOacieOAjeWPr+a4hemZpOivpemAiemhueWNoeWFqOmDqOaXpeacn+OAgicpOwogICAgICAgIGNs
ckFsbENiLmNoZWNrZWQgPSBmYWxzZTsKICAgICAgICBjbHJEbGcuY2xhc3NMaXN0LmFkZCgnb24nKTsK
ICAgIH0KICAgIGZ1bmN0aW9uIGNsb3NlQ2xlYXJEbGcoKSB7CiAgICAgICAgY2xyRGxnLmNsYXNzTGlz
dC5yZW1vdmUoJ29uJyk7CiAgICB9CiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYnRuLWNscicp
LmFkZEV2ZW50TGlzdGVuZXIoJ2NsaWNrJywgZSA9PiB7CiAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24o
KTsKICAgICAgICBvcGVuQ2xlYXJEbGcoKTsKICAgIH0pOwogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5
SWQoJ2Nsci1jYW5jZWwnKS5hZGRFdmVudExpc3RlbmVyKCdjbGljaycsIGUgPT4gewogICAgICAgIGUu
c3RvcFByb3BhZ2F0aW9uKCk7CiAgICAgICAgY2xvc2VDbGVhckRsZygpOwogICAgfSk7CiAgICBjbHJE
bGcuYWRkRXZlbnRMaXN0ZW5lcignY2xpY2snLCBlID0+IHsKICAgICAgICBpZiAoZS50YXJnZXQgPT09
IGNsckRsZykgY2xvc2VDbGVhckRsZygpOwogICAgfSk7CiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJ
ZCgnY2xyLW9rJykuYWRkRXZlbnRMaXN0ZW5lcignY2xpY2snLCBlID0+IHsKICAgICAgICBlLnN0b3BQ
cm9wYWdhdGlvbigpOwogICAgICAgIGNvbnN0IHNjb3BlID0gKGN1clRhYiA9PT0gJ3JlY2VudCcpID8g
J2FsbCcgOiAoY2xyQWxsQ2IuY2hlY2tlZCA/ICdhbGwnIDogJ3RvZGF5Jyk7CiAgICAgICAgY2xvc2VD
bGVhckRsZygpOwogICAgICAgIGFoaygnY2xlYXInLCBjdXJUYWIsIHNjb3BlKTsKICAgIH0pOwogICAg
ZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ211bHRpLXNlbCcpLmFkZEV2ZW50TGlzdGVuZXIoJ2NsaWNr
JywgZSA9PiB7CiAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICBjbGVhck11bHRpKHRy
dWUpOwogICAgfSk7CiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYnRuLXBpbicpLmFkZEV2ZW50
TGlzdGVuZXIoJ2NsaWNrJywgZSA9PiB7CiAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAg
ICBwaW5uZWRVSSA9ICFwaW5uZWRVSTsKICAgICAgICBlLmN1cnJlbnRUYXJnZXQuY2xhc3NMaXN0LnRv
Z2dsZSgnb24nLCBwaW5uZWRVSSk7CiAgICAgICAgYWhrKCd0b2dnbGVQaW4nLCBwaW5uZWRVSSA/ICcx
JyA6ICcwJyk7CiAgICB9KTsKCiAgICB3aW5kb3cuX19wZXJmTWFyayA9IChzdGFnZSkgPT4gewogICAg
ICAgIHRyeSB7CiAgICAgICAgICAgIGlmICh3aW5kb3cuY2hyb21lICYmIGNocm9tZS53ZWJ2aWV3ICYm
IGNocm9tZS53ZWJ2aWV3LnBvc3RNZXNzYWdlKQogICAgICAgICAgICAgICAgY2hyb21lLndlYnZpZXcu
cG9zdE1lc3NhZ2UoJ3BlcmZ8JyArIFN0cmluZyhzdGFnZSB8fCAnJykpOwogICAgICAgIH0gY2F0Y2gg
e30KICAgIH07CgogICAgd2luZG93Ll9fdXBkYXRlQ2xpcHMgPSBwYXlsb2FkID0+IHsKICAgICAgICBj
b25zdCB0MCA9ICh0eXBlb2YgcGVyZm9ybWFuY2UgIT09ICd1bmRlZmluZWQnICYmIHBlcmZvcm1hbmNl
Lm5vdykgPyBwZXJmb3JtYW5jZS5ub3coKSA6IERhdGUubm93KCk7CiAgICAgICAgd2luZG93Ll9fcGVy
Zk1hcmsoJ2pzX3VwZGF0ZUNsaXBzX2VudGVyIG49JyArIChwYXlsb2FkICYmIHBheWxvYWQuaXRlbXMg
PyBwYXlsb2FkLml0ZW1zLmxlbmd0aCA6IChBcnJheS5pc0FycmF5KHBheWxvYWQpID8gcGF5bG9hZC5s
ZW5ndGggOiAwKSkpOwogICAgICAgIC8vIEtlZXAgcHJldmlvdXMgc2Nyb2xsIGZvciBsb2FkLW1vcmU7
IHJlc2V0IHdoZW4gb3BlbmluZyBwYW5lbCB0byBmaXJzdCBpdGVtCiAgICAgICAgY29uc3Qga2VlcFNj
cm9sbCA9ICFzZWxlY3RGaXJzdE9uU2hvdzsKICAgICAgICBjb25zdCBzdCA9IGxpc3RFbC5zY3JvbGxU
b3A7CiAgICAgICAgd2luZG93Ll9fd2FpdGluZ1ZpZXcgPSBmYWxzZTsKICAgICAgICBjb25zdCB3YXNB
cHBlbmQgPSBwYXlsb2FkICYmIHBheWxvYWQuYXBwZW5kOwogICAgICAgIGxvYWRpbmdNb3JlID0gZmFs
c2U7CiAgICAgICAgY29uc3QgcHJldkl0ZW1zID0gYWxsQ2xpcHM7CiAgICAgICAgbGV0IG5leHRJdGVt
cyA9IFtdOwogICAgICAgIGxldCBuZXh0VG90YWwgPSAwOwogICAgICAgIGxldCBuZXh0RmlsdGVyZWQg
PSBmYWxzZTsKICAgICAgICBsZXQgcFRhYiA9ICcnOwogICAgICAgIGxldCBwUGlubmVkVG90YWwgPSAt
MTsKICAgICAgICBpZiAoQXJyYXkuaXNBcnJheShwYXlsb2FkKSkgewogICAgICAgICAgICBuZXh0SXRl
bXMgPSBwYXlsb2FkOwogICAgICAgICAgICBuZXh0VG90YWwgPSBwYXlsb2FkLmxlbmd0aDsKICAgICAg
ICAgICAgbmV4dEZpbHRlcmVkID0gZmFsc2U7CiAgICAgICAgfSBlbHNlIGlmIChwYXlsb2FkICYmIHR5
cGVvZiBwYXlsb2FkID09PSAnb2JqZWN0JykgewogICAgICAgICAgICBuZXh0VG90YWwgPSBOdW1iZXIo
cGF5bG9hZC50b3RhbCkgfHwgMDsKICAgICAgICAgICAgbmV4dEl0ZW1zID0gQXJyYXkuaXNBcnJheShw
YXlsb2FkLml0ZW1zKSA/IHBheWxvYWQuaXRlbXMgOiBbXTsKICAgICAgICAgICAgcFRhYiA9IHBheWxv
YWQudGFiICE9IG51bGwgPyBTdHJpbmcocGF5bG9hZC50YWIpIDogJyc7CiAgICAgICAgICAgIGlmIChw
YXlsb2FkLnBpbm5lZFRvdGFsICE9IG51bGwgJiYgcGF5bG9hZC5waW5uZWRUb3RhbCAhPT0gJycpCiAg
ICAgICAgICAgICAgICBwUGlubmVkVG90YWwgPSBOdW1iZXIocGF5bG9hZC5waW5uZWRUb3RhbCkgfHwg
MDsKICAgICAgICAgICAgY29uc3QgcHEwID0gcGF5bG9hZC5xdWVyeSAhPSBudWxsID8gU3RyaW5nKHBh
eWxvYWQucXVlcnkpIDogJyc7CiAgICAgICAgICAgIG5leHRGaWx0ZXJlZCA9ICEhKHBheWxvYWQuZmls
dGVyZWQgfHwgKHBxMCAmJiBwcTAudHJpbSgpKSk7CiAgICAgICAgICAgIGlmIChwYXlsb2FkLmFwcGVu
ZCkgewogICAgICAgICAgICAgICAgLy8gQXBwZW5kIG9ubHkgYXBwbGllcyB0byB0aGUgdGFiIHdlJ3Jl
IGN1cnJlbnRseSB2aWV3aW5nCiAgICAgICAgICAgICAgICBpZiAocFRhYiAmJiBwVGFiICE9PSBjdXJU
YWIpCiAgICAgICAgICAgICAgICAgICAgcmV0dXJuOwogICAgICAgICAgICAgICAgY29uc3Qgc2VlbiA9
IG5ldyBTZXQoYWxsQ2xpcHMubWFwKGMgPT4gK2MuaWQpKTsKICAgICAgICAgICAgICAgIGNvbnN0IG1l
cmdlZCA9IGFsbENsaXBzLnNsaWNlKCk7CiAgICAgICAgICAgICAgICBuZXh0SXRlbXMuZm9yRWFjaChp
dCA9PiB7CiAgICAgICAgICAgICAgICAgICAgaWYgKCFzZWVuLmhhcygraXQuaWQpKSBtZXJnZWQucHVz
aChpdCk7CiAgICAgICAgICAgICAgICB9KTsKICAgICAgICAgICAgICAgIG5leHRJdGVtcyA9IG1lcmdl
ZDsKICAgICAgICAgICAgICAgIG5leHRUb3RhbCA9IE1hdGgubWF4KG5leHRUb3RhbCwgbmV4dEl0ZW1z
Lmxlbmd0aCk7CiAgICAgICAgICAgIH0KICAgICAgICAgICAgLy8g5pCc57Si5qGG5Lul5omT5a2X6ZWc
5YOP5Li65YeG77yM57ud5LiN6KKr5rue5ZCO55qE56OB55uY57uT5p6c5YaZ5Zue5pen5YWz6ZSu5a2X
CiAgICAgICAgICAgIHRyeSB7CiAgICAgICAgICAgICAgICBjb25zdCBzID0gZG9jdW1lbnQuZ2V0RWxl
bWVudEJ5SWQoJ3NlYXJjaCcpOwogICAgICAgICAgICAgICAgaWYgKHMgJiYgU3RyaW5nKHMudmFsdWUg
fHwgJycpLmxlbmd0aCkKICAgICAgICAgICAgICAgICAgICBxdWVyeSA9IHMudmFsdWU7CiAgICAgICAg
ICAgICAgICBlbHNlIGlmIChwcTAgIT09ICcnICYmICFTdHJpbmcocXVlcnkgfHwgJycpLnRyaW0oKSkK
ICAgICAgICAgICAgICAgICAgICBxdWVyeSA9IHBxMDsKICAgICAgICAgICAgfSBjYXRjaCB7fQogICAg
ICAgIH0gZWxzZSB7CiAgICAgICAgICAgIG5leHRJdGVtcyA9IFtdOwogICAgICAgICAgICBuZXh0VG90
YWwgPSAwOwogICAgICAgICAgICBuZXh0RmlsdGVyZWQgPSBmYWxzZTsKICAgICAgICB9CgogICAgICAg
IGNvbnN0IGJveFEgPSBTdHJpbmcocXVlcnkgfHwgJycpLnRyaW0oKTsKICAgICAgICBjb25zdCBwdXNo
USA9IChwYXlsb2FkICYmIHR5cGVvZiBwYXlsb2FkID09PSAnb2JqZWN0JyAmJiBwYXlsb2FkLnF1ZXJ5
ICE9IG51bGwpCiAgICAgICAgICAgID8gU3RyaW5nKHBheWxvYWQucXVlcnkpLnRyaW0oKSA6ICcnOwoK
ICAgICAgICAvLyBBbHdheXMgcmVmcmVzaCDmlLbol48gYmFkZ2UgZnJvbSBob3N0IHdoZW4gcHJvdmlk
ZWQKICAgICAgICBpZiAocFBpbm5lZFRvdGFsID49IDApCiAgICAgICAgICAgIHBpbm5lZFRvdGFsID0g
cFBpbm5lZFRvdGFsOwoKICAgICAgICAvLyBTdGFsZSBzZWFyY2ggcHVzaCAoZS5nLiAic3F1YXJlIGxv
Z2kiIGxhbmRzIGFmdGVyIHVzZXIgdHlwZWQgInNxdWFyZSBsb2dpbiIpIOKAlGNhY2hlIG9ubHkKICAg
ICAgICBpZiAoIXdhc0FwcGVuZCAmJiBuZXh0RmlsdGVyZWQgJiYgcHVzaFEgJiYgYm94USAmJiBwdXNo
USAhPT0gYm94USkgewogICAgICAgICAgICB2aWV3TWVtLnNldCh2aWV3TWVtS2V5KHBUYWIgfHwgY3Vy
VGFiLCBwdXNoUSwgdG9kYXlPbmx5KSwgewogICAgICAgICAgICAgICAgaXRlbXM6IG5leHRJdGVtcy5z
bGljZSgpLAogICAgICAgICAgICAgICAgdG90YWw6IG5leHRUb3RhbAogICAgICAgICAgICB9KTsKICAg
ICAgICAgICAgcmV0dXJuOwogICAgICAgIH0KCiAgICAgICAgLy8gU3RhbGUgcHVzaCBmb3IgYW5vdGhl
ciB0YWI6IG9ubHkgcmVmcmVzaCB0aGF0IHRhYidzIHZpZXdNZW0sIGRvbid0IGhpamFjayBVSQogICAg
ICAgIGlmICghd2FzQXBwZW5kICYmIHBUYWIgJiYgcFRhYiAhPT0gY3VyVGFiKSB7CiAgICAgICAgICAg
IGNvbnN0IG1lbVEgPSAocGF5bG9hZCAmJiB0eXBlb2YgcGF5bG9hZCA9PT0gJ29iamVjdCcgJiYgcGF5
bG9hZC5xdWVyeSAhPSBudWxsKQogICAgICAgICAgICAgICAgPyBTdHJpbmcocGF5bG9hZC5xdWVyeSkg
OiAnJzsKICAgICAgICAgICAgdmlld01lbS5zZXQodmlld01lbUtleShwVGFiLCBtZW1RLCB0b2RheU9u
bHkpLCB7CiAgICAgICAgICAgICAgICBpdGVtczogbmV4dEl0ZW1zLnNsaWNlKCksCiAgICAgICAgICAg
ICAgICB0b3RhbDogbmV4dFRvdGFsCiAgICAgICAgICAgIH0pOwogICAgICAgICAgICAvLyBTdGlsbCB1
cGRhdGUgcGluIGJhZGdlIGlmIGhvc3Qgc2VudCBpdAogICAgICAgICAgICB0cnkgeyB1cGRhdGVQaW5E
b3QoKTsgfSBjYXRjaCB7fQogICAgICAgICAgICAvLyBRUSDmkJzntKLmm77lm7rlrprmjqggYWxsIHRh
YiDihpIg5b2T5YmNIHRhYiDkvJrkuIDnm7TpqqjmnrbvvJvooaXkuIDmrKEgcmVxdWVzdFZpZXcKICAg
ICAgICAgICAgaWYgKHdhaXRpbmdEYXRhICYmIHB1c2hRID09PSBib3hRKSB7CiAgICAgICAgICAgICAg
ICBzZXRUaW1lb3V0KCgpID0+IHsKICAgICAgICAgICAgICAgICAgICBpZiAod2FpdGluZ0RhdGEgJiYg
Y3VyVGFiICE9PSBwVGFiKQogICAgICAgICAgICAgICAgICAgICAgICByZXF1ZXN0VmlldygpOwogICAg
ICAgICAgICAgICAgfSwgNDApOwogICAgICAgICAgICB9CiAgICAgICAgICAgIHJldHVybjsKICAgICAg
ICB9CgogICAgICAgIC8vIEJvb3RzdHJhcCByYWNlOiBBSEsgcHVzaGVkIGVtcHR5IGJlZm9yZSBXYXJt
QWxsVmlld3Mg4oCUa2VlcCBza2VsZXRvbiwgaWdub3JlCiAgICAgICAgY29uc3QgcU9uID0gU3RyaW5n
KHF1ZXJ5IHx8ICcnKS50cmltKCkubGVuZ3RoID4gMDsKICAgICAgICBpZiAoIXdhc0FwcGVuZCAmJiAh
bmV4dEl0ZW1zLmxlbmd0aCAmJiBuZXh0VG90YWwgPD0gMCAmJiAhcU9uICYmICFuZXh0RmlsdGVyZWQg
JiYgIXNhd05vbkVtcHR5KSB7CiAgICAgICAgICAgIGlmICghd2luZG93Ll9fZW1wdHlGYWxsYmFja1Qp
IHsKICAgICAgICAgICAgICAgIHdpbmRvdy5fX2VtcHR5RmFsbGJhY2tUID0gc2V0VGltZW91dCgoKSA9
PiB7CiAgICAgICAgICAgICAgICAgICAgd2luZG93Ll9fZW1wdHlGYWxsYmFja1QgPSAwOwogICAgICAg
ICAgICAgICAgICAgIGlmIChzYXdOb25FbXB0eSkgcmV0dXJuOwogICAgICAgICAgICAgICAgICAgIC8v
IFRydWx5IGVtcHR5IGluc3RhbGwgYWZ0ZXIgd2FpdAogICAgICAgICAgICAgICAgICAgIHNhd05vbkVt
cHR5ID0gdHJ1ZTsKICAgICAgICAgICAgICAgICAgICBob3N0UHVzaGVkT25jZSA9IHRydWU7CiAgICAg
ICAgICAgICAgICAgICAgd2luZG93Ll9fZGF0YVJlYWR5ID0gdHJ1ZTsKICAgICAgICAgICAgICAgICAg
ICBhbGxDbGlwcyA9IFtdOwogICAgICAgICAgICAgICAgICAgIGRpc2tUb3RhbCA9IDA7CiAgICAgICAg
ICAgICAgICAgICAgY2xlYXJXYWl0aW5nRGF0YSgpOwogICAgICAgICAgICAgICAgICAgIHRyeSB7IHJl
bmRlcigpOyB9IGNhdGNoIHt9CiAgICAgICAgICAgICAgICB9LCA0NTAwKTsKICAgICAgICAgICAgfQog
ICAgICAgICAgICB3YWl0aW5nRGF0YSA9IHRydWU7CiAgICAgICAgICAgIHdpbmRvdy5fX2RhdGFSZWFk
eSA9IGZhbHNlOwogICAgICAgICAgICBob3N0UHVzaGVkT25jZSA9IGZhbHNlOwogICAgICAgICAgICBz
ZXRCb290TG9hZGluZyh0cnVlKTsKICAgICAgICAgICAgdHJ5IHsgcmVuZGVyKCk7IH0gY2F0Y2gge30K
ICAgICAgICAgICAgcmV0dXJuOwogICAgICAgIH0KCiAgICAgICAgY2xlYXJXYWl0aW5nRGF0YSgpOwog
ICAgICAgIGFsbENsaXBzID0gbmV4dEl0ZW1zOwogICAgICAgIGRpc2tUb3RhbCA9IG5leHRUb3RhbDsK
ICAgICAgICAvLyBLZWVwIGJhciBjb25zaXN0ZW50IGlmIGxpc3QgZ3JldyBwYXN0IGEgc3RhbGUgdG90
YWwKICAgICAgICBpZiAoYWxsQ2xpcHMubGVuZ3RoID4gZGlza1RvdGFsKQogICAgICAgICAgICBkaXNr
VG90YWwgPSBhbGxDbGlwcy5sZW5ndGg7CiAgICAgICAgd2luZG93Ll9faG9zdEZpbHRlcmVkID0gbmV4
dEZpbHRlcmVkOwogICAgICAgIHdpbmRvdy5fX2hvc3RGaWx0ZXJRID0gKG5leHRGaWx0ZXJlZCAmJiBw
dXNoUSkgPyBwdXNoUSA6ICcnOwogICAgICAgIC8vIEZpbHRlcmVkIHNlYXJjaCB3aXRoIDAgaGl0cyDi
gJRtdXN0IGxlYXZlIHNrZWxldG9uIChob3N0IGRpZCByZXNwb25kKQogICAgICAgIGlmICghd2FzQXBw
ZW5kICYmIG5leHRGaWx0ZXJlZCAmJiAhYWxsQ2xpcHMubGVuZ3RoICYmIGRpc2tUb3RhbCA8PSAwKSB7
CiAgICAgICAgICAgIGhvc3RQdXNoZWRPbmNlID0gdHJ1ZTsKICAgICAgICAgICAgc2F3Tm9uRW1wdHkg
PSB0cnVlOwogICAgICAgIH0KICAgICAgICBpZiAoYWxsQ2xpcHMubGVuZ3RoIHx8IGRpc2tUb3RhbCA+
IDApCiAgICAgICAgICAgIHNhd05vbkVtcHR5ID0gdHJ1ZTsKICAgICAgICBpZiAod2luZG93Ll9fZW1w
dHlGYWxsYmFja1QpIHsKICAgICAgICAgICAgY2xlYXJUaW1lb3V0KHdpbmRvdy5fX2VtcHR5RmFsbGJh
Y2tUKTsKICAgICAgICAgICAgd2luZG93Ll9fZW1wdHlGYWxsYmFja1QgPSAwOwogICAgICAgIH0KICAg
ICAgICBpZiAoIXdhc0FwcGVuZCkgewogICAgICAgICAgICBjb25zdCBtZW1RID0gKHBheWxvYWQgJiYg
dHlwZW9mIHBheWxvYWQgPT09ICdvYmplY3QnICYmIHBheWxvYWQucXVlcnkgIT0gbnVsbCkKICAgICAg
ICAgICAgICAgID8gU3RyaW5nKHBheWxvYWQucXVlcnkpIDogcXVlcnk7CiAgICAgICAgICAgIHZpZXdN
ZW0uc2V0KHZpZXdNZW1LZXkoY3VyVGFiLCBtZW1RLCB0b2RheU9ubHkpLCB7CiAgICAgICAgICAgICAg
ICBpdGVtczogYWxsQ2xpcHMuc2xpY2UoKSwKICAgICAgICAgICAgICAgIHRvdGFsOiBkaXNrVG90YWwK
ICAgICAgICAgICAgfSk7CiAgICAgICAgfQogICAgICAgIHdpbmRvdy5fX2RhdGFSZWFkeSA9IHRydWU7
CiAgICAgICAgaG9zdFB1c2hlZE9uY2UgPSB0cnVlOwoKICAgICAgICAvLyBNaWQtd2hlZWw6IGtlZXAg
ZGF0YSwgZGVsYXkgRE9NIHNvIHNjcm9sbC9kcmFnIG5ldmVyIGhpdGNoIG9uIGFwcGVuZCBwYWludAog
ICAgICAgIGlmICh3YXNBcHBlbmQgJiYgd2luZG93Ll9fc2Nyb2xsQnVzeSAmJiAhd2luZG93Ll9fcGVu
ZGluZ0p1bXBJZCkgewogICAgICAgICAgICBjb25zdCBmcm9tTGVuID0gKHByZXZJdGVtcyAmJiBwcmV2
SXRlbXMubGVuZ3RoKSA/IHByZXZJdGVtcy5sZW5ndGggOiAwOwogICAgICAgICAgICBpZiAoIV9wZW5k
aW5nQXBwZW5kKQogICAgICAgICAgICAgICAgX3BlbmRpbmdBcHBlbmQgPSB7IGZyb21MZW46IGZyb21M
ZW4gfTsKICAgICAgICAgICAgdHJ5IHsgcmVmcmVzaExpc3RDaHJvbWUoKTsgfSBjYXRjaCB7fQogICAg
ICAgICAgICByZXR1cm47CiAgICAgICAgfQoKICAgICAgICBjb25zdCB3YXNCb290TG9hZGluZyA9IGJv
b3RMb2FkaW5nOwogICAgICAgIGxldCBzYW1lUGFpbnQgPSBmYWxzZTsKICAgICAgICBjb25zdCBwcmV2
TGVuID0gKHByZXZJdGVtcyAmJiBwcmV2SXRlbXMubGVuZ3RoKSA/IHByZXZJdGVtcy5sZW5ndGggOiAw
OwogICAgICAgIGlmICghd2FzQXBwZW5kICYmICF3YXNCb290TG9hZGluZyAmJiBwcmV2SXRlbXMgJiYg
cHJldkl0ZW1zLmxlbmd0aCA9PT0gYWxsQ2xpcHMubGVuZ3RoICYmIHByZXZJdGVtcy5sZW5ndGgpIHsK
ICAgICAgICAgICAgc2FtZVBhaW50ID0gdHJ1ZTsKICAgICAgICAgICAgZm9yIChsZXQgaSA9IDA7IGkg
PCBhbGxDbGlwcy5sZW5ndGg7IGkrKykgewogICAgICAgICAgICAgICAgaWYgKCtwcmV2SXRlbXNbaV0u
aWQgIT09ICthbGxDbGlwc1tpXS5pZCkgeyBzYW1lUGFpbnQgPSBmYWxzZTsgYnJlYWs7IH0KICAgICAg
ICAgICAgfQogICAgICAgICAgICBpZiAoc2FtZVBhaW50ICYmICFsaXN0RWwucXVlcnlTZWxlY3Rvcign
Lml0bScpKSBzYW1lUGFpbnQgPSBmYWxzZTsKICAgICAgICB9CiAgICAgICAgY29uc3QgZmluaXNoVXBk
YXRlID0gKCkgPT4gewogICAgICAgICAgICBjb25zdCB0UmVuZGVyMCA9ICh0eXBlb2YgcGVyZm9ybWFu
Y2UgIT09ICd1bmRlZmluZWQnICYmIHBlcmZvcm1hbmNlLm5vdykgPyBwZXJmb3JtYW5jZS5ub3coKSA6
IERhdGUubm93KCk7CiAgICAgICAgICAgIGNsZWFyV2FpdGluZ0RhdGEoKTsKICAgICAgICAgICAgaWYg
KHdhc0FwcGVuZCAmJiAhd2FzQm9vdExvYWRpbmcgJiYgcHJldkxlbiA+IDAgJiYgYWxsQ2xpcHMubGVu
Z3RoID4gcHJldkxlbikgewogICAgICAgICAgICAgICAgYXBwZW5kUmVuZGVyKHByZXZMZW4pOwogICAg
ICAgICAgICB9IGVsc2UgaWYgKCFzYW1lUGFpbnQpIHsKICAgICAgICAgICAgICAgIHJlbmRlcigpOwog
ICAgICAgICAgICAgICAgYXBwbHlUYWJTd2l0Y2hBbmltKCk7CiAgICAgICAgICAgICAgICBpZiAoa2Vl
cFNjcm9sbCkKICAgICAgICAgICAgICAgICAgICBsaXN0RWwuc2Nyb2xsVG9wID0gc3Q7CiAgICAgICAg
ICAgICAgICBlbHNlCiAgICAgICAgICAgICAgICAgICAgbGlzdEVsLnNjcm9sbFRvcCA9IDA7CiAgICAg
ICAgICAgIH0gZWxzZSB7CiAgICAgICAgICAgICAgICB0cnkgeyByZWZyZXNoTGlzdENocm9tZSgpOyB9
IGNhdGNoIHt9CiAgICAgICAgICAgICAgICBpZiAoa2VlcFNjcm9sbCkKICAgICAgICAgICAgICAgICAg
ICBsaXN0RWwuc2Nyb2xsVG9wID0gc3Q7CiAgICAgICAgICAgIH0KICAgICAgICAgICAgY29uc3QgdDEg
PSAodHlwZW9mIHBlcmZvcm1hbmNlICE9PSAndW5kZWZpbmVkJyAmJiBwZXJmb3JtYW5jZS5ub3cpID8g
cGVyZm9ybWFuY2Uubm93KCkgOiBEYXRlLm5vdygpOwogICAgICAgICAgICB3aW5kb3cuX19wZXJmTWFy
aygnanNfdXBkYXRlQ2xpcHNfZG9uZSByZW5kZXJNcz0nICsgTWF0aC5yb3VuZCh0MSAtIHRSZW5kZXIw
KSArICcgdG90YWxNcz0nICsgTWF0aC5yb3VuZCh0MSAtIHQwKSArICcgbj0nICsgYWxsQ2xpcHMubGVu
Z3RoKTsKICAgICAgICB9OwogICAgICAgIGlmICh3YXNCb290TG9hZGluZykgewogICAgICAgICAgICBj
b25zdCBzaW5jZSA9IHdpbmRvdy5fX3NrZWxTaW5jZSB8fCAwOwogICAgICAgICAgICBjb25zdCB3YWl0
ID0gc2luY2UgPyBNYXRoLm1heCgwLCA4MCAtIChEYXRlLm5vdygpIC0gc2luY2UpKSA6IDA7CiAgICAg
ICAgICAgIGlmICh3YWl0ID4gMCkKICAgICAgICAgICAgICAgIHNldFRpbWVvdXQoZmluaXNoVXBkYXRl
LCB3YWl0KTsKICAgICAgICAgICAgZWxzZQogICAgICAgICAgICAgICAgZmluaXNoVXBkYXRlKCk7CiAg
ICAgICAgfSBlbHNlIHsKICAgICAgICAgICAgZmluaXNoVXBkYXRlKCk7CiAgICAgICAgfQogICAgfTsK
ICAgIHdpbmRvdy5fX3NldFBpbm5lZCA9IHYgPT4gewogICAgICAgIHBpbm5lZFVJID0gISF2OwogICAg
ICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdidG4tcGluJykuY2xhc3NMaXN0LnRvZ2dsZSgnb24n
LCBwaW5uZWRVSSk7CiAgICB9OwogICAgd2luZG93Ll9fbG9hZE1vcmVEb25lID0gKCkgPT4gewogICAg
ICAgIGxvYWRpbmdNb3JlID0gZmFsc2U7CiAgICAgICAgaWYgKHdpbmRvdy5fX2xvYWRNb3JlV2F0Y2gp
IHsKICAgICAgICAgICAgY2xlYXJUaW1lb3V0KHdpbmRvdy5fX2xvYWRNb3JlV2F0Y2gpOwogICAgICAg
ICAgICB3aW5kb3cuX19sb2FkTW9yZVdhdGNoID0gMDsKICAgICAgICB9CiAgICAgICAgaWYgKHdpbmRv
dy5fX3BlbmRpbmdKdW1wSWQpCiAgICAgICAgICAgIHRyeUNvbnRpbnVlSnVtcCgpOwogICAgfTsKCiAg
ICBpbml0U2VwVWkoKTsKICAgIHVwZGF0ZVBpbkRvdCgpOwogICAgc2NoZWR1bGVEZWxheWVkU2tlbCgp
OwogICAgd2luZG93Ll9fcGVyZk1hcmsgJiYgd2luZG93Ll9fcGVyZk1hcmsoJ2pzX2Jvb3QgcmVxdWVz
dFZpZXcnKTsKICAgIHJlcXVlc3RWaWV3KCk7CiAgICAvLyBzY2hlZHVsZURlbGF5ZWRTa2VsIGFscmVh
ZHkgcmVuZGVyKCknZCB3aGVuIGVtcHR5OyBzdGlsbCBwYWludCBvbmNlIGZvciBjaHJvbWUKCiAgICA8
L3NjcmlwdD4KPC9ib2R5Pgo8L2h0bWw+
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
    pinMany(ids := "", flag := "1") {
        ; flag 1=pin, 0=unpin —batch set (not toggle)
        SetTimer(PinItemsMany.Bind(String(ids), String(flag)), -1)
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
    textTransform(id, mode := "auto") {
        SetTimer(ApplyTextTransform.Bind(id, mode), -1)
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
    ; Locate: pull full favGroup around a pasted uid so UI shows 合并组 not a lone row
    ensureFavGroupAround(id := 0) {
        SetTimer(EnsureFavGroupAroundUid.Bind(Integer(id)), -1)
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
        , thumbPushedUids, clipReady, STORE_DIR, panelVisible, listThumbUrlCache
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
        ; Never inject bare virtual-host URLs here: under SaveImage/Prune disk load
        ; WebView2 mapping often 404s, and __setThumb would poison thumbCache for the whole list.
        ; Prefer in-memory data-URL cache; otherwise queue for ProcessThumbPushQueue.
        name := String(c.imgFile)
        if IsObject(listThumbUrlCache) && listThumbUrlCache.Has(name) {
            ent := listThumbUrlCache[name]
            if IsObject(ent) && ent.HasProp("url") && ent.url != "" {
                try wvCore.ExecuteScriptAsync("window.__setThumb&&window.__setThumb(" uid "," JsonStr(ent.url) ")")
                thumbPushedUids[uid] := true
                continue
            }
        }
        q.Push({ uid: uid, imgFile: name })
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
        url := ""
        didMake := false
        ; Prefer FileRead→data-URL (listThumbUrlCache). Virtual-host URLs flake when
        ; clips_store is busy after screenshot persist / prune — that blanked the whole image tab.
        try url := ListThumbDataUrl(name, allowMake, &didMake)
        catch as e {
            ClipLog("ProcessThumbPushQueue dataUrl fail " name " " e.Message)
        }
        if didMake
            madeJpeg := true
        if url = "" && allowMake {
            try {
                if EnsureListThumbFile(name) != "" {
                    madeJpeg := true
                    didMake := false
                    try url := ListThumbDataUrl(name, false, &didMake)
                    catch {
                    }
                }
            } catch as e {
                ClipLog("ProcessThumbPushQueue Ensure fail " name " " e.Message)
            }
        }
        if url = "" && !allowMake {
            ; Encode budget used —put back and leave this tick (don't spin the queue)
            try {
                if FileExist(STORE_DIR "\" name)
                    thumbPushQueue.InsertAt(1, job)
            }
            break
        }
        if url = "" {
            ; Last resort only — may still fail under disk load
            cacheName := ListThumbCacheName(name)
            if cacheName != "" && FileExist(STORE_DIR "\" cacheName)
                url := ListThumbHostUrl(cacheName)
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

/**
    Transform text and paste immediately.
    Does NOT modify the original clip history entry.
    Modes:
    ① brace: {a,b} / a,b -> ('a','b')
    ② lines: newline-separated values -> ('a','b') (dedupe)
    ③ json: StrReplace(raw, '\"', '"') JSON quote unescape
    ④ auto: detect by content — brace / lines / json
**/

ApplyTextTransform(uid, mode := "auto") {
    global clipIgnore, uiPinned
    uid := Integer(uid)
    mode := StrLower(Trim(String(mode)))
    if mode = "bracket"
        mode := "brace"
    if mode = "unescape"
        mode := "json"
    if mode = "" || mode = "smart" || mode = "auto"
        mode := "auto"
    item := ResolveClip(uid)
    if !IsObject(item)
        return
    if !(item.type = "text" || item.type = "link")
        return
    src := item.HasProp("data") ? String(item.data) : ""
    if src = "" && item.HasProp("preview")
        src := String(item.preview)
    if mode = "auto" {
        mode := DetectDataTransformMode(src)
        if mode = ""
            return
    }
    out := TransformClipText(src, mode)
    if out = ""
        return

    eraseN := QQTypedEraseCount()
    if !uiPinned
        HidePanel()
    clipIgnore := true
    try {
        A_Clipboard := out
        MarkItemsPasted([uid])
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

/**
    Pick transform mode from raw text.
    Priority:
    ① contains \" -> json unescape (check before brace: escaped JSON also starts with {)
    ② starts with { -> brace (preview may be truncated)
    ③ has newline -> lines
**/

DetectDataTransformMode(raw) {
    s := Trim(String(raw))
    if s = ""
        return ""
    if InStr(s, "\`"")
        return "json"
    if SubStr(s, 1, 1) = "{"
        return "brace"
    if InStr(s, "`n") || InStr(s, "`r")
        return "lines"
    return ""
}

TransformClipText(raw, mode := "brace") {
    if mode = "json"
        return JsonUnescapeQuotes(raw)
    return TextToSqlTuple(raw, mode)
}

/**
    Unescape JSON quote escapes: \" -> "
**/

JsonUnescapeQuotes(raw) {
    ; StrReplace(raw, '\"', '"')
    return StrReplace(String(raw), "\`"", '"')
}

TextToSqlTuple(raw, mode := "brace") {
    raw := Trim(String(raw))
    if raw = ""
        return ""
    parts := []
    if mode = "lines" {
        seen := Map()
        for ln in StrSplit(raw, "`n", "`r") {
            t := Trim(ln)
            if t = ""
                continue
            t := StripOuterQuotes(t)
            if t = "" || seen.Has(t)
                continue
            seen[t] := true
            parts.Push(t)
        }
    } else {
        s := raw
        if RegExMatch(s, "s)^\s*\{(.*)\}\s*$", &m)
            s := Trim(m[1])
        else if RegExMatch(s, "s)^\s*\[(.*)\]\s*$", &m)
            s := Trim(m[1])
        for t in SplitCsvRespectQuotes(s) {
            t := StripOuterQuotes(Trim(t))
            if t != ""
                parts.Push(t)
        }
    }
    if !parts.Length
        return ""
    out := "("
    for i, p in parts {
        if i > 1
            out .= ","
        out .= "'" StrReplace(p, "'", "''") "'"
    }
    out .= ")"
    return out
}

StripOuterQuotes(s) {
    s := String(s)
    n := StrLen(s)
    if n >= 2 {
        a := SubStr(s, 1, 1)
        b := SubStr(s, n, 1)
        if (a = '"' && b = '"') || (a = "'" && b = "'")
            return SubStr(s, 2, n - 2)
    }
    return s
}

SplitCsvRespectQuotes(s) {
    s := String(s)
    parts := []
    cur := ""
    q := ""
    i := 1
    len := StrLen(s)
    while i <= len {
        ch := SubStr(s, i, 1)
        if q != "" {
            if ch = q {
                nxt := i < len ? SubStr(s, i + 1, 1) : ""
                if nxt = q {
                    cur .= q
                    i += 2
                    continue
                }
                q := ""
                i += 1
                continue
            }
            cur .= ch
            i += 1
            continue
        }
        if ch = '"' || ch = "'" {
            q := ch
            i += 1
            continue
        }
        if ch = "," {
            parts.Push(Trim(cur))
            cur := ""
            i += 1
            continue
        }
        cur .= ch
        i += 1
    }
    parts.Push(Trim(cur))
    out := []
    for p in parts {
        if p != ""
            out.Push(p)
    }
    return out
}

DiskReplaceItemLine(item) {
    if !IsObject(item)
        return false
    uid := Integer(item.HasProp("uid") ? item.uid : 0)
    if uid < 1
        return false
    newLine := ItemToJsonLine(item)
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
                    if line != newLine {
                        line := newLine
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

PinItemsMany(idsStr, flag := "1") {
    global clips, viewTab, viewQuery, viewToday, viewCache, recentFolders, liveFront
    wantPin := (String(flag) = "1" || String(flag) = "true")
    pinAt := wantPin ? FormatTime(, "yyyy-MM-dd HH:mm:ss") : ""
    ids := []
    seen := Map()
    for part in StrSplit(String(idsStr), ",") {
        uid := Integer(Trim(part))
        if uid < 1 || seen.Has(uid)
            continue
        seen[uid] := true
        ids.Push(uid)
    }
    if !ids.Length
        return

    ; Recent folders: set pinned flag (not clipboard 收藏)
    if IsObject(recentFolders) {
        rfHit := 0
        for uid in ids {
            for c in recentFolders {
                if !IsObject(c) || Integer(c.uid) != uid
                    continue
                c.pinned := wantPin
                rfHit += 1
                break
            }
        }
        if rfHit = ids.Length {
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

    for uid in ids {
        applied := false
        for c in clips {
            if Integer(c.uid) = uid {
                c.pinned := wantPin
                c.pinTime := pinAt
                applied := true
                break
            }
        }
        if !applied {
            it := ResolveClip(uid)
            if IsObject(it) {
                it.pinned := wantPin
                it.pinTime := pinAt
            }
        }
        for , entry in viewCache {
            if !IsObject(entry) || !entry.HasProp("items")
                continue
            for c in entry.items {
                if Integer(c.uid) = uid {
                    c.pinned := wantPin
                    c.pinTime := pinAt
                    break
                }
            }
        }
        if IsObject(liveFront) {
            for c in liveFront {
                if IsObject(c) && Integer(c.uid) = uid {
                    c.pinned := wantPin
                    c.pinTime := pinAt
                    break
                }
            }
        }
        EnqueueDiskJob(DiskSetPinned.Bind(uid, wantPin, pinAt))
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

    if viewTab = "pinned" {
        if !wantPin {
            kept := []
            for c in clips {
                if !IsObject(c) || seen.Has(Integer(c.uid))
                    continue
                kept.Push(c)
            }
            clips := kept
            viewTotal := Max(0, Integer(viewTotal) - ids.Length)
            PushClips(false)
        } else
            QueueSetView(viewTab, viewQuery, viewToday ? "1" : "0")
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

; Clear all search pools (merge/unmerge changes favGroup for every tab)
InvalidateAllSearchPools() {
    global searchPools, viewCache
    searchPools := Map()
    ; Drop cached search results — incomplete favGroup pages would keep showing 2/3 forever
    if !IsObject(viewCache)
        return
    dropKeys := []
    for key, _ in viewCache {
        tab := "", todayOnly := false, query := ""
        ParseViewCacheKey(key, &tab, &todayOnly, &query)
        if Trim(String(query)) != "" || tab = "pinned"
            dropKeys.Push(key)
    }
    for key in dropKeys
        viewCache.Delete(key)
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
    ; Rebuild search hay so compact fav title ("gogettrans") is indexed
    global searchPools
    if IsObject(searchPools)
        searchPools := Map()
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
    InvalidateAllSearchPools()
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
    InvalidateAllSearchPools()
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
        ; Keep rows even without imgFile (persist race / save failure). Dropping them
        ; made the image tab look empty until a later rescan found repaired files.
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
    ; Virtual compact title: "go get trans" → also match "gogettrans"
    favCompact := RegExReplace(favTitle, "\s+", "")
    favHay := favTitle
    if favCompact != "" && favCompact != favTitle
        favHay .= " " favCompact
    if type = "image"
        return StrLower(favHay)
    if type = "file" {
        return StrLower(String(c.HasProp("preview") ? c.preview : "") " "
            . String(c.HasProp("data") ? c.data : "") " " favHay)
    }
    prev := c.HasProp("preview") ? String(c.preview) : ""
    dataSample := ""
    if c.HasProp("data") && c.data != ""
        dataSample := SubStr(String(c.data), 1, 500)
    if prev = "" && dataSample != ""
        prev := dataSample
    hay := StrLower(prev " "
        . String(c.HasProp("linkTitle") ? c.linkTitle : "") " " favHay)
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
    favCompact := StrLower(RegExReplace(favTitle, "\s+", ""))
    favSearch := favLower
    if favCompact != "" && favCompact != favLower
        favSearch .= " " favCompact
    hay := StrLower(String(hay))
    if type = "image"
        hay := favSearch
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
                if favTitle = "" || !InStr(favSearch, tLower)
                    return false
            } else if !InStr(hay, tLower)
                return false
        }
        if !segAny {
            matchedAny := true
            tLower := StrLower(seg)
            if type = "image" {
                if favTitle = "" || !InStr(favSearch, tLower)
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
        ; SearchPoolQuery already expands+clusters; still avoid mid-group page cuts
        items := SliceKeepingFavGroups(all, offset, limit)
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
                    EnsureFavGroupsComplete(items, tab, todayOnly)
                    ClipLog("QueryDiskPage stream hit ms=" (A_TickCount - t0) " n=" items.Length)
                    return { items: items, total: knownTotal }
                }
                if items.Length >= limit {
                    approx := offset + items.Length
                    EnqueueDiskJob(RefreshTabTotalAsync.Bind(tab, todayOnly, key))
                    EnsureFavGroupsComplete(items, tab, todayOnly)
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
    EnsureFavGroupsComplete(items, tab, todayOnly)
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
    else {
        all := pool.items.Clone()
        SortPinnedClipsDesc(all)
        ; Keep merge groups contiguous —otherwise page cuts leave a lone row
        ClusterFavGroupsInPlace(all)
    }
    items := SliceKeepingFavGroups(all, offset, limit)
    return { items: items, total: all.Length }
}

; Page slice that never cuts a favGroup mid-block (may return slightly > limit)
SliceKeepingFavGroups(all, offset, limit) {
    items := []
    if !IsObject(all) || all.Length < 1
        return items
    offset := Integer(offset)
    limit := Integer(limit)
    if limit < 1
        limit := 40
    i := offset + 1
    while i <= all.Length && items.Length < limit {
        items.Push(all[i])
        i += 1
    }
    ; If last item is mid-group, keep pulling until group ends
    if items.Length {
        last := items[items.Length]
        gid := IsObject(last) && last.HasProp("favGroup") ? Trim(String(last.favGroup)) : ""
        if gid != "" {
            while i <= all.Length {
                c := all[i]
                g := IsObject(c) && c.HasProp("favGroup") ? Trim(String(c.favGroup)) : ""
                if g != gid
                    break
                items.Push(c)
                i += 1
            }
        }
    }
    return items
}

; Pull missing favGroup siblings into a page so UI can render 合并组
EnsureFavGroupsComplete(items, tab, todayOnly) {
    if !IsObject(items) || items.Length < 1
        return
    tab := StrLower(Trim(String(tab)))
    todayOnly := !!todayOnly
    have := Map()
    gids := Map()
    for c in items {
        if !IsObject(c) || !c.HasProp("uid")
            continue
        have[Integer(c.uid)] := true
        g := c.HasProp("favGroup") ? Trim(String(c.favGroup)) : ""
        if g != ""
            gids[g] := true
    }
    if !gids.Count
        return
    added := 0
    for g, _ in gids {
        for c in CollectFavGroupMembers(g) {
            if !IsObject(c) || !c.HasProp("uid")
                continue
            uid := Integer(c.uid)
            if have.Has(uid)
                continue
            if !ItemMatchesTabToday(c, tab, todayOnly)
                continue
            items.Push(c)
            have[uid] := true
            added += 1
        }
    }
    if added > 0 || gids.Count
        ClusterFavGroupsInPlace(items)
}

CollectFavGroupMembers(gid) {
    global searchPools, clips, liveFront
    gid := Trim(String(gid))
    out := []
    if gid = ""
        return out
    have := Map()
    ; Prefer in-memory search pools (already indexed by group)
    if IsObject(searchPools) {
        for , pool in searchPools {
            if !IsObject(pool) || !IsObject(pool.groups) || !pool.groups.Has(gid)
                continue
            for c in pool.groups[gid] {
                if !IsObject(c) || !c.HasProp("uid")
                    continue
                uid := Integer(c.uid)
                if have.Has(uid)
                    continue
                have[uid] := true
                out.Push(c)
            }
        }
    }
    if out.Length
        return out
    ; Fallback: scan current clips + liveFront + disk light rows
    for c in clips {
        if IsObject(c) && c.HasProp("favGroup") && Trim(String(c.favGroup)) = gid {
            uid := Integer(c.uid)
            if !have.Has(uid) {
                have[uid] := true
                out.Push(c)
            }
        }
    }
    if IsObject(liveFront) {
        for c in liveFront {
            if IsObject(c) && c.HasProp("favGroup") && Trim(String(c.favGroup)) = gid {
                uid := Integer(c.uid)
                if !have.Has(uid) {
                    have[uid] := true
                    out.Push(c)
                }
            }
        }
    }
    if out.Length >= 2
        return out
    m := LoadManifest()
    n := 0
    for name in m["pages"] {
        for c in ReadPageFile(name, true) {
            if !IsObject(c) || !(c.HasProp("favGroup") && Trim(String(c.favGroup)) = gid)
                continue
            uid := Integer(c.uid)
            if have.Has(uid)
                continue
            have[uid] := true
            out.Push(c)
            if Mod(++n, 64) = 0
                Sleep(-1)
        }
    }
    return out
}

; After paste-locate: ensure the whole merge group sits in current clips window
EnsureFavGroupAroundUid(uid) {
    global clips, viewTab, viewQuery, viewToday, viewTotal, viewCache, wvCore, panelVisible
    uid := Integer(uid)
    if uid < 1
        return
    item := ""
    if IsObject(clips) {
        for c in clips {
            if IsObject(c) && Integer(c.uid) = uid {
                item := c
                break
            }
        }
    }
    if !IsObject(item)
        item := ResolveClip(uid)
    if !IsObject(item)
        return
    gid := item.HasProp("favGroup") ? Trim(String(item.favGroup)) : ""
    if gid = ""
        return
    members := CollectFavGroupMembers(gid)
    if members.Length < 2
        return
    ; Keep only members that belong on this tab (pinned group on 全部 still ok)
    keep := []
    for c in members {
        if ItemMatchesTabToday(c, viewTab, viewToday)
            keep.Push(c)
    }
    if keep.Length < 2
        keep := members.Clone()
    if !IsObject(clips)
        clips := []
    have := Map()
    for c in clips {
        if IsObject(c) && c.HasProp("uid")
            have[Integer(c.uid)] := true
    }
    ; Find insert position = first existing group member (or target)
    insAt := 0
    loop clips.Length {
        c := clips[A_Index]
        if !IsObject(c)
            continue
        if Integer(c.uid) = uid || (c.HasProp("favGroup") && Trim(String(c.favGroup)) = gid) {
            insAt := A_Index
            break
        }
    }
    if insAt < 1
        insAt := 1
    added := 0
    for c in keep {
        id := Integer(c.uid)
        if have.Has(id)
            continue
        clips.InsertAt(insAt + added, c)
        have[id] := true
        added += 1
        viewTotal += 1
    }
    ClusterFavGroupsInPlace(clips)
    try CacheCurrentView()
    ClipLog("EnsureFavGroupAroundUid uid=" uid " gid=" gid " added=" added " n=" clips.Length)
    if IsObject(wvCore)
        PushClips(false)
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

; Keep favGroup members adjacent at first member's position (so first page is not truncated mid-group)
ClusterFavGroupsInPlace(items) {
    if !IsObject(items) || items.Length < 2
        return
    out := []
    used := Map()
    for c in items {
        if !IsObject(c) || !c.HasProp("uid")
            continue
        uid := Integer(c.uid)
        if used.Has(uid)
            continue
        g := c.HasProp("favGroup") ? Trim(String(c.favGroup)) : ""
        if g = "" {
            out.Push(c)
            used[uid] := true
            continue
        }
        for o in items {
            if !IsObject(o) || !o.HasProp("uid")
                continue
            ouid := Integer(o.uid)
            if used.Has(ouid)
                continue
            og := o.HasProp("favGroup") ? Trim(String(o.favGroup)) : ""
            if og = g {
                out.Push(o)
                used[ouid] := true
            }
        }
    }
    while items.Length > 0
        items.Pop()
    for c in out
        items.Push(c)
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
    ; pool.groups already expanded siblings above; cluster so pagination keeps the whole group on page 1
    if q != "" && all.Length
        ClusterFavGroupsInPlace(all)
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
            saved := ""
            try saved := SaveImageToStore(item.data)
            catch as e {
                ClipLogErr("PersistNewItem SaveImageToStore", e)
            }
            if saved != "" {
                item.imgFile := saved
                item.data := ""
                ; Patch in-memory / cache so UI can load thumb after write
                ApplyImgFileLocal(item.uid, item.imgFile)
                ; Don't wait for coalesced PushClips —fill the blank placeholder now
                SetTimer(InjectStoreThumbNow.Bind(Integer(item.uid), String(item.imgFile)), -10)
            } else {
                ; Keep in-memory data so InjectLiveImageThumb / retry can still show a preview
                ClipLog("PersistNewItem SaveImageToStore empty uid=" uidBefore)
            }
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
    global tabTotals, panelVisible
    tabTotals := Map()
    ClipLog("PruneOldScreenshots done")
    if panelVisible
        RequestUiPush()
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
            ; Only drop empty / near-empty snapshots (copy-before-open / race).
            ; Do NOT treat total<=VIEW_PAGE_SIZE as poison —that forced a full disk
            ; rescan on every tab switch for libraries with ≤20 items.
            poisoned := viewQuery = "" && !viewToday
                && IsObject(entry) && entry.HasProp("items")
                && entry.items.Length < 5 && entry.total <= entry.items.Length
                && (viewTab = "all" || viewTab = "image" || viewTab = "file"
                    || viewTab = "text" || viewTab = "link" || viewTab = "pinned")
            thin := !IsObject(entry) || !entry.HasProp("items") || poisoned
            if !thin {
                if myGen != viewApplyGen
                    return
                clips := []
                for c in entry.items
                    clips.Push(c)
                viewTotal := entry.total
                MergeLiveFrontIntoClips()
                EnsureFavGroupsComplete(clips, viewTab, viewToday)
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
        EnsureFavGroupsComplete(clips, viewTab, viewToday)
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
    ; Offset by unique uids already loaded (ignore favGroup siblings pulled in by Ensure*)
    have := Map()
    diskN := 0
    for c in clips {
        if !IsObject(c) || !c.HasProp("uid")
            continue
        uid := Integer(c.uid)
        if have.Has(uid)
            continue
        have[uid] := true
        diskN += 1
    }
    page := QueryDiskPage(viewTab, viewQuery, viewToday, diskN, VIEW_PAGE_SIZE)
    viewTotal := page.total
    added := 0
    for c in page.items {
        if !IsObject(c) || !c.HasProp("uid")
            continue
        uid := Integer(c.uid)
        if have.Has(uid)
            continue
        clips.Push(c)
        have[uid] := true
        added += 1
    }
    lastAppendCount := added
    ; Complete any partial merge groups at the new seam
    EnsureFavGroupsComplete(clips, viewTab, viewToday)
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
