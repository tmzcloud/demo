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
UI_CACHE_VER := "20260908-sep-single"
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
ICAgICAgICAgbWFyZ2luLWxlZnQ6IDFweDsKICAgICAgICB9CiAgICAgICAgI3RhYi1hY3Rpb25zIHsK
ICAgICAgICAgICAgbWFyZ2luLWxlZnQ6IGF1dG87IGRpc3BsYXk6IGZsZXg7IGFsaWduLWl0ZW1zOiBj
ZW50ZXI7IGdhcDogM3B4OwogICAgICAgICAgICBjb2xvcjogdmFyKC0tdHh0Myk7IGZvbnQtc2l6ZTog
MTBweDsKICAgICAgICAgICAgZmxleDogMCAwIGF1dG87CiAgICAgICAgICAgIG1pbi13aWR0aDogMDsK
ICAgICAgICAgICAgLXdlYmtpdC1hcHAtcmVnaW9uOiBuby1kcmFnOyBhcHAtcmVnaW9uOiBuby1kcmFn
OwogICAgICAgIH0KICAgICAgICAjYmFyLXR4dCB7IHdoaXRlLXNwYWNlOiBub3dyYXA7IGZvbnQtc2l6
ZTogMTBweDsgbWF4LXdpZHRoOiA4LjVlbTsgb3ZlcmZsb3c6IGhpZGRlbjsgdGV4dC1vdmVyZmxvdzog
ZWxsaXBzaXM7IH0KICAgICAgICAjYnRuLWNsciB7CiAgICAgICAgICAgIGRpc3BsYXk6IGZsZXg7IGFs
aWduLWl0ZW1zOiBjZW50ZXI7IGp1c3RpZnktY29udGVudDogY2VudGVyOwogICAgICAgICAgICB3aWR0
aDogMjZweDsgaGVpZ2h0OiAyNnB4OyBib3JkZXI6IG5vbmU7IGJhY2tncm91bmQ6IG5vbmU7IGNvbG9y
OiB2YXIoLS10eHQzKTsKICAgICAgICAgICAgY3Vyc29yOiBwb2ludGVyOyBib3JkZXItcmFkaXVzOiB2
YXIoLS1yKTsKICAgICAgICAgICAgLXdlYmtpdC1hcHAtcmVnaW9uOiBuby1kcmFnOyBhcHAtcmVnaW9u
OiBuby1kcmFnOwogICAgICAgICAgICB0cmFuc2l0aW9uOiBjb2xvciB2YXIoLS10ciksIGJhY2tncm91
bmQgdmFyKC0tdHIpOwogICAgICAgIH0KICAgICAgICAjYnRuLWNscjpob3ZlciB7IGNvbG9yOiAjZmY3
YjljOyBiYWNrZ3JvdW5kOiByZ2JhKDI1NSwxMjMsMTU2LC4wOCk7IH0KICAgICAgICAjYnRuLWNsciBz
dmcgeyB3aWR0aDogMTRweDsgaGVpZ2h0OiAxNHB4OyBkaXNwbGF5OiBibG9jazsgfQoKICAgICAgICAv
KiDilIDilIAgTGlzdCDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDi
lIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDi
lIDilIDilIDilIDilIAgKi8KICAgICAgICAjbGlzdCB7CiAgICAgICAgICAgIGZsZXg6IDE7IG92ZXJm
bG93LXk6IGF1dG87IG92ZXJmbG93LXg6IGhpZGRlbjsKICAgICAgICAgICAgLyog5bemIDEwIC8g5Y+z
IDXvvJrlj7Pkvqfmu5rliqjmnaHnuqbljaAgNXB477yM6KeG6KeJ5bem5Y+z5a+56b2QICovCiAgICAg
ICAgICAgIHBhZGRpbmc6IDRweCA1cHggNHB4IDEwcHg7CiAgICAgICAgICAgIGN1cnNvcjogZGVmYXVs
dDsKICAgICAgICAgICAgLyogTVVTVCBiZSBuby1kcmFnOiBkcmFnIHJlZ2lvbiBvbiB0aGUgc2Nyb2xs
ZXIgbWFrZXMgV2ViVmlldzIgc2Nyb2xsYmFyL3doZWVsIGhpdGNoICovCiAgICAgICAgICAgIC13ZWJr
aXQtYXBwLXJlZ2lvbjogbm8tZHJhZzsgYXBwLXJlZ2lvbjogbm8tZHJhZzsKICAgICAgICAgICAgbWlu
LWhlaWdodDogMDsKICAgICAgICAgICAgb3ZlcmZsb3ctYW5jaG9yOiBub25lOwogICAgICAgIH0KICAg
ICAgICAvKiBXaGlsZSBzY3JvbGxpbmc6IGtpbGwgaG92ZXIgYW5pbWF0aW9ucyB0aGF0IGNhdXNlIGxh
eW91dC9wYWludCB0aHJhc2ggKi8KICAgICAgICAjbGlzdC5pcy1zY3JvbGxpbmcgLml0bSB7CiAgICAg
ICAgICAgIHRyYW5zaXRpb246IG5vbmUgIWltcG9ydGFudDsKICAgICAgICB9CiAgICAgICAgI2xpc3Qu
aXMtc2Nyb2xsaW5nIC5pdG06OmJlZm9yZSwKICAgICAgICAjbGlzdC5pcy1zY3JvbGxpbmcgLml0bTo6
YWZ0ZXIgewogICAgICAgICAgICB0cmFuc2l0aW9uOiBub25lICFpbXBvcnRhbnQ7CiAgICAgICAgfQog
ICAgICAgIEBrZXlmcmFtZXMgdGFiUGFuZUluTHIgewogICAgICAgICAgICBmcm9tIHsgb3BhY2l0eTog
MDsgdHJhbnNmb3JtOiB0cmFuc2xhdGVYKC00MHB4KTsgfQogICAgICAgICAgICB0byB7IG9wYWNpdHk6
IDE7IHRyYW5zZm9ybTogdHJhbnNsYXRlWCgwKTsgfQogICAgICAgIH0KICAgICAgICBAa2V5ZnJhbWVz
IHRhYlBhbmVJblJsIHsKICAgICAgICAgICAgZnJvbSB7IG9wYWNpdHk6IDA7IHRyYW5zZm9ybTogdHJh
bnNsYXRlWCg0MHB4KTsgfQogICAgICAgICAgICB0byB7IG9wYWNpdHk6IDE7IHRyYW5zZm9ybTogdHJh
bnNsYXRlWCgwKTsgfQogICAgICAgIH0KICAgICAgICAjbGlzdC50YWItaW4tbHIgeyBhbmltYXRpb246
IHRhYlBhbmVJbkxyIC4zNHMgY3ViaWMtYmV6aWVyKC4yMiwgMSwgLjM2LCAxKSBib3RoOyB9CiAgICAg
ICAgI2xpc3QudGFiLWluLXJsIHsgYW5pbWF0aW9uOiB0YWJQYW5lSW5SbCAuMzRzIGN1YmljLWJlemll
ciguMjIsIDEsIC4zNiwgMSkgYm90aDsgfQogICAgICAgICNidG4tdG9wIHsKICAgICAgICAgICAgcG9z
aXRpb246IGFic29sdXRlOyByaWdodDogMTBweDsgYm90dG9tOiAxMHB4OyB6LWluZGV4OiAyMDsKICAg
ICAgICAgICAgd2lkdGg6IDI4cHg7IGhlaWdodDogMjhweDsgYm9yZGVyOiBub25lOyBib3JkZXItcmFk
aXVzOiA1MCU7CiAgICAgICAgICAgIGRpc3BsYXk6IG5vbmU7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGp1
c3RpZnktY29udGVudDogY2VudGVyOwogICAgICAgICAgICBiYWNrZ3JvdW5kOiAjZmZmOyBjb2xvcjog
dmFyKC0tdHh0Mik7CiAgICAgICAgICAgIGJveC1zaGFkb3c6IDAgMnB4IDhweCByZ2JhKDI0LDMyLDU2
LC4xNik7CiAgICAgICAgICAgIGN1cnNvcjogcG9pbnRlcjsKICAgICAgICAgICAgLXdlYmtpdC1hcHAt
cmVnaW9uOiBuby1kcmFnOyBhcHAtcmVnaW9uOiBuby1kcmFnOwogICAgICAgICAgICB0cmFuc2l0aW9u
OiBiYWNrZ3JvdW5kIHZhcigtLXRyKSwgY29sb3IgdmFyKC0tdHIpLCBib3gtc2hhZG93IHZhcigtLXRy
KTsKICAgICAgICB9CiAgICAgICAgI2J0bi10b3Aub24geyBkaXNwbGF5OiBmbGV4OyB9CiAgICAgICAg
I2J0bi10b3A6aG92ZXIgeyBjb2xvcjogdmFyKC0tYWNjKTsgYmFja2dyb3VuZDogI2VkZjFmZjsgYm94
LXNoYWRvdzogMCAzcHggMTBweCByZ2JhKDkxLDExNSwyMzIsLjI1KTsgfQogICAgICAgICNidG4tdG9w
IHN2ZyB7IHdpZHRoOiAxNHB4OyBoZWlnaHQ6IDE0cHg7IGRpc3BsYXk6IGJsb2NrOyB9CiAgICAgICAg
I2VtcHR5IHsKICAgICAgICAgICAgZGlzcGxheTogbm9uZTsgZmxleC1kaXJlY3Rpb246IGNvbHVtbjsg
YWxpZ24taXRlbXM6IGNlbnRlcjsganVzdGlmeS1jb250ZW50OiBjZW50ZXI7CiAgICAgICAgICAgIHBh
ZGRpbmc6IDQ4cHggMTZweDsgY29sb3I6IHZhcigtLXR4dDMpOyBnYXA6IDhweDsKICAgICAgICAgICAg
LXdlYmtpdC1hcHAtcmVnaW9uOiBkcmFnOyBhcHAtcmVnaW9uOiBkcmFnOwogICAgICAgIH0KICAgICAg
ICAjZW1wdHkub24geyBkaXNwbGF5OiBmbGV4OyB9CiAgICAgICAgLmUtdHh0IHsgZm9udC1zaXplOiAx
MnB4OyB0ZXh0LWFsaWduOiBjZW50ZXI7IGxldHRlci1zcGFjaW5nOiAuMDJlbTsgfQogICAgICAgICNz
a2VsIHsKICAgICAgICAgICAgZGlzcGxheTogbm9uZSAhaW1wb3J0YW50OyAvKiDnp5LlvIDlkI7kuI3l
ho3lsZXnpLrpqqjmnrbliqjnlLsgKi8KICAgICAgICB9CiAgICAgICAgI3NrZWwub24geyBkaXNwbGF5
OiBub25lICFpbXBvcnRhbnQ7IH0KICAgICAgICAjYXBwLmJvb3QtbG9hZGluZyAjc2tlbCB7CiAgICAg
ICAgICAgIGRpc3BsYXk6IG5vbmUgIWltcG9ydGFudDsKICAgICAgICB9CiAgICAgICAgI2FwcC5ib290
LWxvYWRpbmcgI2VtcHR5IHsKICAgICAgICAgICAgZGlzcGxheTogbm9uZSAhaW1wb3J0YW50OwogICAg
ICAgIH0KICAgICAgICAuc2stcm93IHsKICAgICAgICAgICAgZGlzcGxheTogZmxleDsgYWxpZ24taXRl
bXM6IGZsZXgtc3RhcnQ7IGdhcDogMTBweDsKICAgICAgICAgICAgcGFkZGluZzogMTBweCA4cHg7IGJv
cmRlci1yYWRpdXM6IDhweDsKICAgICAgICAgICAgYmFja2dyb3VuZDogcmdiYSgyNTUsMjU1LDI1NSwu
NzIpOwogICAgICAgICAgICBib3JkZXI6IDFweCBzb2xpZCByZ2JhKDE3MCwxODAsMjAwLC40NSk7CiAg
ICAgICAgICAgIHBvc2l0aW9uOiByZWxhdGl2ZTsKICAgICAgICAgICAgb3ZlcmZsb3c6IGhpZGRlbjsK
ICAgICAgICB9CiAgICAgICAgLnNrLXJvdzo6YWZ0ZXIgewogICAgICAgICAgICBjb250ZW50OiAnJzsK
ICAgICAgICAgICAgcG9zaXRpb246IGFic29sdXRlOwogICAgICAgICAgICBpbnNldDogMDsKICAgICAg
ICAgICAgYmFja2dyb3VuZDogbGluZWFyLWdyYWRpZW50KDkwZGVnLCB0cmFuc3BhcmVudCAwJSwgcmdi
YSgyNTUsMjU1LDI1NSwuNzIpIDQ4JSwgdHJhbnNwYXJlbnQgMTAwJSk7CiAgICAgICAgICAgIHRyYW5z
Zm9ybTogdHJhbnNsYXRlWCgtMTIwJSk7CiAgICAgICAgICAgIGFuaW1hdGlvbjogc2stc3dlZXAgMC45
NXMgZWFzZS1pbi1vdXQgaW5maW5pdGU7CiAgICAgICAgICAgIHBvaW50ZXItZXZlbnRzOiBub25lOwog
ICAgICAgIH0KICAgICAgICBAa2V5ZnJhbWVzIHNrLXN3ZWVwIHsKICAgICAgICAgICAgMTAwJSB7IHRy
YW5zZm9ybTogdHJhbnNsYXRlWCgxMjAlKTsgfQogICAgICAgIH0KICAgICAgICAuc2staWNvLCAuc2st
bGluZSB7CiAgICAgICAgICAgIGJhY2tncm91bmQ6IGxpbmVhci1ncmFkaWVudCg5MGRlZywgI2I4YzJk
OCAwJSwgI2YwZjRmYSAzOCUsICNkY2UzZjAgNTIlLCAjYjhjMmQ4IDEwMCUpOwogICAgICAgICAgICBi
YWNrZ3JvdW5kLXNpemU6IDI0MCUgMTAwJTsKICAgICAgICAgICAgYW5pbWF0aW9uOiBzay1zaGltbWVy
IDAuNzJzIGVhc2UtaW4tb3V0IGluZmluaXRlOwogICAgICAgICAgICB3aWxsLWNoYW5nZTogYmFja2dy
b3VuZC1wb3NpdGlvbjsKICAgICAgICAgICAgYm9yZGVyLXJhZGl1czogNnB4OwogICAgICAgIH0KICAg
ICAgICAuc2staWNvIHsgd2lkdGg6IDM0cHg7IGhlaWdodDogMzRweDsgZmxleC1zaHJpbms6IDA7IGJv
cmRlci1yYWRpdXM6IDhweDsgfQogICAgICAgIC5zay1ib2R5IHsgZmxleDogMTsgbWluLXdpZHRoOiAw
OyBkaXNwbGF5OiBmbGV4OyBmbGV4LWRpcmVjdGlvbjogY29sdW1uOyBnYXA6IDhweDsgcGFkZGluZy10
b3A6IDJweDsgfQogICAgICAgIC5zay1saW5lIHsgaGVpZ2h0OiAxMHB4OyB3aWR0aDogMTAwJTsgfQog
ICAgICAgIC5zay1saW5lLnNob3J0IHsgd2lkdGg6IDQyJTsgfQogICAgICAgIC5zay1saW5lLm1pZCB7
IHdpZHRoOiA2OCU7IH0KICAgICAgICAuc2stcm93Om50aC1jaGlsZCgyKTo6YWZ0ZXIgeyBhbmltYXRp
b24tZGVsYXk6IC4xMnM7IH0KICAgICAgICAuc2stcm93Om50aC1jaGlsZCgzKTo6YWZ0ZXIgeyBhbmlt
YXRpb24tZGVsYXk6IC4yNHM7IH0KICAgICAgICAuc2stcm93Om50aC1jaGlsZCg0KTo6YWZ0ZXIgeyBh
bmltYXRpb24tZGVsYXk6IC4zNnM7IH0KICAgICAgICAuc2stcm93Om50aC1jaGlsZCg1KTo6YWZ0ZXIg
eyBhbmltYXRpb24tZGVsYXk6IC40OHM7IH0KICAgICAgICAuc2stcm93Om50aC1jaGlsZCg2KTo6YWZ0
ZXIgeyBhbmltYXRpb24tZGVsYXk6IC42czsgfQogICAgICAgIEBrZXlmcmFtZXMgc2stc2hpbW1lciB7
CiAgICAgICAgICAgIDAlIHsgYmFja2dyb3VuZC1wb3NpdGlvbjogMTAwJSAwOyB9CiAgICAgICAgICAg
IDEwMCUgeyBiYWNrZ3JvdW5kLXBvc2l0aW9uOiAtMTAwJSAwOyB9CiAgICAgICAgfQogICAgICAgIC5s
aXN0LW1vcmUgewogICAgICAgICAgICB0ZXh0LWFsaWduOiBjZW50ZXI7IHBhZGRpbmc6IDEwcHggOHB4
IDE0cHg7IGZvbnQtc2l6ZTogMTFweDsKICAgICAgICAgICAgY29sb3I6IHZhcigtLXR4dDMpOyAtd2Vi
a2l0LWFwcC1yZWdpb246IG5vLWRyYWc7IGFwcC1yZWdpb246IG5vLWRyYWc7CiAgICAgICAgfQogICAg
ICAgIC5saXN0LW1vcmUuZG9uZSB7IGRpc3BsYXk6IG5vbmU7IH0KCiAgICAgICAgLml0bSB7CiAgICAg
ICAgICAgIGRpc3BsYXk6IGZsZXg7IGFsaWduLWl0ZW1zOiBmbGV4LXN0YXJ0OyBnYXA6IDhweDsKICAg
ICAgICAgICAgcGFkZGluZzogOHB4OyBtYXJnaW4tYm90dG9tOiA1cHg7CiAgICAgICAgICAgIGJhY2tn
cm91bmQ6IHZhcigtLWNhcmQpOyBib3JkZXItcmFkaXVzOiA0cHg7IGN1cnNvcjogcG9pbnRlcjsKICAg
ICAgICAgICAgYm9yZGVyOiBub25lOwogICAgICAgICAgICBib3gtc2hhZG93OgogICAgICAgICAgICAg
ICAgMCAxcHggMnB4IHJnYmEoMjQsMzIsNTYsLjA1KSwKICAgICAgICAgICAgICAgIDAgM3B4IDEwcHgg
cmdiYSgyNCwzMiw1NiwuMDgpOwogICAgICAgICAgICAvKiBob3Zlci1saW5lICovCiAgICAgICAgICAg
IHBvc2l0aW9uOiByZWxhdGl2ZTsKICAgICAgICAgICAgdHJhbnNpdGlvbjogYmFja2dyb3VuZCAuMnMg
ZWFzZSwgYm94LXNoYWRvdyAuMnMgZWFzZSwgdHJhbnNmb3JtIC4ycyBlYXNlOwogICAgICAgICAgICAt
d2Via2l0LWFwcC1yZWdpb246IG5vLWRyYWc7IGFwcC1yZWdpb246IG5vLWRyYWc7CiAgICAgICAgICAg
IG92ZXJmbG93OiB2aXNpYmxlOwogICAgICAgIH0KICAgICAgICAuaXRtOjpiZWZvcmUgewogICAgICAg
ICAgICBjb250ZW50OiAiIjsKICAgICAgICAgICAgcG9zaXRpb246IGFic29sdXRlOwogICAgICAgICAg
ICBsZWZ0OiAwOyByaWdodDogMDsgYm90dG9tOiAwOwogICAgICAgICAgICBoZWlnaHQ6IDA7CiAgICAg
ICAgICAgIHBvaW50ZXItZXZlbnRzOiBub25lOwogICAgICAgICAgICB6LWluZGV4OiAwOwogICAgICAg
ICAgICBib3JkZXItcmFkaXVzOiAwIDAgdmFyKC0tcikgdmFyKC0tcik7CiAgICAgICAgICAgIGJhY2tn
cm91bmQ6IGxpbmVhci1ncmFkaWVudCh0byB0b3AsIHJnYmEoOTEsMTE1LDIzMiwuMzIpLCByZ2JhKDkx
LDExNSwyMzIsLjEyKSA1NSUsIHRyYW5zcGFyZW50KTsKICAgICAgICAgICAgdHJhbnNpdGlvbjogaGVp
Z2h0IC4zNHMgY3ViaWMtYmV6aWVyKC4yMiwxLC4zNiwxKTsKICAgICAgICB9CiAgICAgICAgLml0bTpo
b3Zlcjo6YmVmb3JlIHsgaGVpZ2h0OiAzMy4zMzMlOyB9CiAgICAgICAgLml0bTo6YWZ0ZXIgewogICAg
ICAgICAgICBjb250ZW50OiAiIjsKICAgICAgICAgICAgcG9zaXRpb246IGFic29sdXRlOwogICAgICAg
ICAgICBsZWZ0OiAwOyByaWdodDogMDsgYm90dG9tOiAwOwogICAgICAgICAgICBoZWlnaHQ6IDJweDsK
ICAgICAgICAgICAgcG9pbnRlci1ldmVudHM6IG5vbmU7CiAgICAgICAgICAgIHotaW5kZXg6IDE7CiAg
ICAgICAgICAgIGJhY2tncm91bmQ6IHJnYmEoOTEsMTE1LDIzMiwuOTUpOwogICAgICAgICAgICBib3Jk
ZXItcmFkaXVzOiAxcHg7CiAgICAgICAgICAgIHRyYW5zZm9ybTogc2NhbGVYKDApOwogICAgICAgICAg
ICB0cmFuc2Zvcm0tb3JpZ2luOiBjZW50ZXI7CiAgICAgICAgICAgIHRyYW5zaXRpb246IHRyYW5zZm9y
bSAuM3MgY3ViaWMtYmV6aWVyKC4yMiwxLC4zNiwxKTsKICAgICAgICB9CiAgICAgICAgLml0bTpob3Zl
ciB7CiAgICAgICAgICAgIGJhY2tncm91bmQ6IHZhcigtLWNhcmQtaCk7CiAgICAgICAgICAgIGJveC1z
aGFkb3c6CiAgICAgICAgICAgICAgICAwIDJweCA0cHggcmdiYSgyNCwzMiw1NiwuMDcpLAogICAgICAg
ICAgICAgICAgMCA2cHggMTZweCByZ2JhKDI0LDMyLDU2LC4xMik7CiAgICAgICAgfQogICAgICAgIC5p
dG06aG92ZXI6OmFmdGVyIHsKICAgICAgICAgICAgdHJhbnNmb3JtOiBzY2FsZVgoMSk7CiAgICAgICAg
fQogICAgICAgIC5pdG0uc2VsIHsKICAgICAgICAgICAgYm94LXNoYWRvdzoKICAgICAgICAgICAgICAg
IDAgMCAwIDJweCByZ2JhKDkxLDExNSwyMzIsLjQyKSwKICAgICAgICAgICAgICAgIDAgMnB4IDRweCBy
Z2JhKDkxLDExNSwyMzIsLjEwKSwKICAgICAgICAgICAgICAgIDAgNnB4IDE0cHggcmdiYSg5MSwxMTUs
MjMyLC4xNik7CiAgICAgICAgICAgIGJhY2tncm91bmQ6ICNlZGYxZmY7CiAgICAgICAgfQogICAgICAg
IC5pdG0ubXVsdGkgewogICAgICAgICAgICBib3gtc2hhZG93OiAwIDAgMCAxLjVweCByZ2JhKDkxLDEx
NSwyMzIsLjU1KSwgMCAycHggNnB4IHJnYmEoOTEsMTE1LDIzMiwuMTgpOwogICAgICAgICAgICBiYWNr
Z3JvdW5kOiAjZWVmMmZmOwogICAgICAgIH0KICAgICAgICAuaXRtLm11bHRpLnNlbCB7CiAgICAgICAg
ICAgIGJveC1zaGFkb3c6IDAgMCAwIDJweCByZ2JhKDkxLDExNSwyMzIsLjcpLCAwIDJweCA4cHggcmdi
YSg5MSwxMTUsMjMyLC4yMik7CiAgICAgICAgfQoKICAgICAgICAjbXVsdGktYmFyIHsKICAgICAgICAg
ICAgZGlzcGxheTogbm9uZTsKICAgICAgICAgICAgYWxpZ24taXRlbXM6IGNlbnRlcjsKICAgICAgICAg
ICAgZ2FwOiA0cHg7CiAgICAgICAgICAgIG1hcmdpbjogMCAycHggMCAwOwogICAgICAgICAgICBmbGV4
LXNocmluazogMDsKICAgICAgICAgICAgLXdlYmtpdC1hcHAtcmVnaW9uOiBuby1kcmFnOyBhcHAtcmVn
aW9uOiBuby1kcmFnOwogICAgICAgIH0KICAgICAgICAjbXVsdGktYmFyLm9uIHsgZGlzcGxheTogaW5s
aW5lLWZsZXg7IH0KICAgICAgICAjbXVsdGktc2VsIHsKICAgICAgICAgICAgZGlzcGxheTogaW5saW5l
LWZsZXg7CiAgICAgICAgICAgIGFsaWduLWl0ZW1zOiBjZW50ZXI7CiAgICAgICAgICAgIGdhcDogNHB4
OwogICAgICAgICAgICBoZWlnaHQ6IDIycHg7CiAgICAgICAgICAgIHBhZGRpbmc6IDAgOXB4OwogICAg
ICAgICAgICBmbGV4LXNocmluazogMDsKICAgICAgICAgICAgYm9yZGVyOiBub25lOwogICAgICAgICAg
ICBib3JkZXItcmFkaXVzOiAxMXB4OwogICAgICAgICAgICBiYWNrZ3JvdW5kOiB2YXIoLS1hY2MpOwog
ICAgICAgICAgICBjb2xvcjogI2ZmZjsKICAgICAgICAgICAgY3Vyc29yOiBwb2ludGVyOwogICAgICAg
ICAgICAtd2Via2l0LWFwcC1yZWdpb246IG5vLWRyYWc7IGFwcC1yZWdpb246IG5vLWRyYWc7CiAgICAg
ICAgICAgIHRyYW5zaXRpb246IGJhY2tncm91bmQgdmFyKC0tdHIpLCBvcGFjaXR5IHZhcigtLXRyKTsK
ICAgICAgICB9CiAgICAgICAgI211bHRpLXNlbDpob3ZlciB7IGJhY2tncm91bmQ6ICM0YTYyZDQ7IH0K
ICAgICAgICAjbXVsdGktc2VsLWxhYiB7CiAgICAgICAgICAgIGZvbnQtc2l6ZTogMTFweDsKICAgICAg
ICAgICAgZm9udC13ZWlnaHQ6IDYwMDsKICAgICAgICAgICAgY29sb3I6ICNmZmY7CiAgICAgICAgICAg
IGxldHRlci1zcGFjaW5nOiAuMDJlbTsKICAgICAgICAgICAgbGluZS1oZWlnaHQ6IDE7CiAgICAgICAg
ICAgIHVzZXItc2VsZWN0OiBub25lOwogICAgICAgIH0KICAgICAgICAjbXVsdGktY250IHsKICAgICAg
ICAgICAgZGlzcGxheTogaW5saW5lLWZsZXg7CiAgICAgICAgICAgIGFsaWduLWl0ZW1zOiBjZW50ZXI7
CiAgICAgICAgICAgIGp1c3RpZnktY29udGVudDogY2VudGVyOwogICAgICAgICAgICBtaW4td2lkdGg6
IDFlbTsKICAgICAgICAgICAgZm9udC1zaXplOiAxMXB4OwogICAgICAgICAgICBmb250LXdlaWdodDog
NzAwOwogICAgICAgICAgICBjb2xvcjogI2ZmZjsKICAgICAgICAgICAgbGluZS1oZWlnaHQ6IDE7CiAg
ICAgICAgICAgIHVzZXItc2VsZWN0OiBub25lOwogICAgICAgIH0KCiAgICAgICAgI3Bhc3RlLXNlcC13
cmFwIHsKICAgICAgICAgICAgcG9zaXRpb246IHJlbGF0aXZlOyBmbGV4LXNocmluazogMDsKICAgICAg
ICB9CiAgICAgICAgI3Bhc3RlLXNlcC1idG4gewogICAgICAgICAgICBkaXNwbGF5OiBpbmxpbmUtZmxl
eDsgYWxpZ24taXRlbXM6IGNlbnRlcjsKICAgICAgICAgICAgaGVpZ2h0OiAyMnB4OyBwYWRkaW5nOiAw
IDhweDsKICAgICAgICAgICAgYm9yZGVyOiBub25lOyBib3JkZXItcmFkaXVzOiAxMXB4OyBjdXJzb3I6
IHBvaW50ZXI7CiAgICAgICAgICAgIGJhY2tncm91bmQ6IHJnYmEoOTEsMTE1LDIzMiwuMTApOyBjb2xv
cjogdmFyKC0tYWNjKTsKICAgICAgICAgICAgZm9udC1zaXplOiAxMnB4OyBsaW5lLWhlaWdodDogMTsg
Zm9udC13ZWlnaHQ6IDcwMDsKICAgICAgICAgICAgZm9udC1mYW1pbHk6IHVpLW1vbm9zcGFjZSwgQ29u
c29sYXMsICJDYXNjYWRpYSBNb25vIiwgbW9ub3NwYWNlOwogICAgICAgICAgICAtd2Via2l0LWFwcC1y
ZWdpb246IG5vLWRyYWc7IGFwcC1yZWdpb246IG5vLWRyYWc7CiAgICAgICAgICAgIHRyYW5zaXRpb246
IGJhY2tncm91bmQgdmFyKC0tdHIpLCBjb2xvciB2YXIoLS10cik7CiAgICAgICAgfQogICAgICAgICNw
YXN0ZS1zZXAtYnRuOmhvdmVyLCAjcGFzdGUtc2VwLWJ0bi5vcGVuIHsKICAgICAgICAgICAgYmFja2dy
b3VuZDogcmdiYSg5MSwxMTUsMjMyLC4xOCk7IGNvbG9yOiAjNGE2MmQ0OwogICAgICAgIH0KICAgICAg
ICAjcGFzdGUtc2VwLW1lbnUgewogICAgICAgICAgICBkaXNwbGF5OiBub25lOyBwb3NpdGlvbjogYWJz
b2x1dGU7IHRvcDogY2FsYygxMDAlICsgNXB4KTsgcmlnaHQ6IDA7CiAgICAgICAgICAgIHdpZHRoOiBt
YXgtY29udGVudDsgbWF4LXdpZHRoOiAxNDBweDsgbWF4LWhlaWdodDogMjgwcHg7CiAgICAgICAgICAg
IG92ZXJmbG93LXk6IGF1dG87IHotaW5kZXg6IDEyMDsKICAgICAgICAgICAgYmFja2dyb3VuZDogcmdi
YSgyNTAsMjUxLDI1NCwuOTcpOwogICAgICAgICAgICBib3JkZXI6IDFweCBzb2xpZCByZ2JhKDAsMCww
LC4wNSk7CiAgICAgICAgICAgIGJvcmRlci1yYWRpdXM6IDhweDsKICAgICAgICAgICAgYm94LXNoYWRv
dzogMCA2cHggMjBweCByZ2JhKDQ0LDQ2LDU0LC4xKTsKICAgICAgICAgICAgcGFkZGluZzogM3B4Owog
ICAgICAgICAgICBiYWNrZHJvcC1maWx0ZXI6IGJsdXIoOHB4KTsKICAgICAgICB9CiAgICAgICAgI3Bh
c3RlLXNlcC1tZW51Lm9uIHsKICAgICAgICAgICAgZGlzcGxheTogZmxleDsgZmxleC1kaXJlY3Rpb246
IGNvbHVtbjsgYWxpZ24taXRlbXM6IHN0cmV0Y2g7CiAgICAgICAgfQogICAgICAgIC5wYXN0ZS1zZXAt
aXRlbSB7CiAgICAgICAgICAgIGRpc3BsYXk6IGZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGp1c3Rp
ZnktY29udGVudDogc3BhY2UtYmV0d2VlbjsgZ2FwOiA4cHg7CiAgICAgICAgICAgIHdpZHRoOiAxMDAl
OyBib3gtc2l6aW5nOiBib3JkZXItYm94OyB0ZXh0LWFsaWduOiBsZWZ0OwogICAgICAgICAgICBwYWRk
aW5nOiA0cHggNnB4OyBib3JkZXI6IG5vbmU7IGJvcmRlci1yYWRpdXM6IDZweDsKICAgICAgICAgICAg
YmFja2dyb3VuZDogbm9uZTsgY29sb3I6IHZhcigtLXR4dDIpOwogICAgICAgICAgICBmb250LXNpemU6
IDEwcHg7IGN1cnNvcjogcG9pbnRlcjsgd2hpdGUtc3BhY2U6IG5vd3JhcDsKICAgICAgICAgICAgb3Zl
cmZsb3c6IGhpZGRlbjsKICAgICAgICAgICAgdHJhbnNpdGlvbjogYmFja2dyb3VuZCB2YXIoLS10ciks
IGNvbG9yIHZhcigtLXRyKTsKICAgICAgICB9CiAgICAgICAgLnBhc3RlLXNlcC1zeW0gewogICAgICAg
ICAgICBmbGV4LXNocmluazogMDsKICAgICAgICAgICAgZm9udC1mYW1pbHk6IHVpLW1vbm9zcGFjZSwg
Q29uc29sYXMsICJDYXNjYWRpYSBNb25vIiwgbW9ub3NwYWNlOwogICAgICAgICAgICBmb250LXNpemU6
IDEwcHg7IGZvbnQtd2VpZ2h0OiA3MDA7IGNvbG9yOiB2YXIoLS1hY2MpOwogICAgICAgICAgICBsZXR0
ZXItc3BhY2luZzogLTAuMDNlbTsKICAgICAgICB9CiAgICAgICAgLnBhc3RlLXNlcC1zeW0ub25seSB7
IG1pbi13aWR0aDogMDsgfQogICAgICAgIC5wYXN0ZS1zZXAtbmFtZSB7CiAgICAgICAgICAgIGZsZXg6
IDAgMCBhdXRvOyBtYXJnaW4tbGVmdDogYXV0bzsKICAgICAgICAgICAgZm9udC1zaXplOiAxMHB4OyBj
b2xvcjogdmFyKC0tdHh0Myk7CiAgICAgICAgICAgIG92ZXJmbG93OiBoaWRkZW47IHRleHQtb3ZlcmZs
b3c6IGVsbGlwc2lzOwogICAgICAgIH0KICAgICAgICAucGFzdGUtc2VwLWl0ZW06aG92ZXIgeyBiYWNr
Z3JvdW5kOiByZ2JhKDkxLDExNSwyMzIsLjA4KTsgfQogICAgICAgIC5wYXN0ZS1zZXAtaXRlbTpob3Zl
ciAucGFzdGUtc2VwLW5hbWUgeyBjb2xvcjogdmFyKC0tdHh0Mik7IH0KICAgICAgICAucGFzdGUtc2Vw
LWl0ZW0uc2VsIHsgYmFja2dyb3VuZDogcmdiYSg5MSwxMTUsMjMyLC4xMik7IH0KICAgICAgICAucGFz
dGUtc2VwLWl0ZW0uc2VsIC5wYXN0ZS1zZXAtbmFtZSB7IGNvbG9yOiB2YXIoLS1hY2MpOyBmb250LXdl
aWdodDogNjAwOyB9CiAgICAgICAgLnBhc3RlLXNlcC1mb290IHsKICAgICAgICAgICAgbWFyZ2luLXRv
cDogM3B4OyBwYWRkaW5nLXRvcDogM3B4OwogICAgICAgICAgICBib3JkZXItdG9wOiAxcHggc29saWQg
cmdiYSgwLDAsMCwuMDUpOwogICAgICAgICAgICBtaW4td2lkdGg6IDA7IGFsaWduLXNlbGY6IHN0cmV0
Y2g7CiAgICAgICAgfQogICAgICAgICNwYXN0ZS1zZXAtY3VzdG9tIHsKICAgICAgICAgICAgZGlzcGxh
eTogYmxvY2s7IHdpZHRoOiAxMDAlOyBtaW4td2lkdGg6IDA7IG1heC13aWR0aDogMTAwJTsKICAgICAg
ICAgICAgYm94LXNpemluZzogYm9yZGVyLWJveDsKICAgICAgICAgICAgaGVpZ2h0OiAyMnB4OyBwYWRk
aW5nOiAwIDZweDsKICAgICAgICAgICAgYm9yZGVyOiBub25lOyBib3JkZXItcmFkaXVzOiA1cHg7CiAg
ICAgICAgICAgIGJhY2tncm91bmQ6IHJnYmEoOTEsMTE1LDIzMiwuMDYpOwogICAgICAgICAgICBjb2xv
cjogdmFyKC0tdHh0Mik7IGZvbnQtc2l6ZTogMTBweDsKICAgICAgICAgICAgLXdlYmtpdC1hcHAtcmVn
aW9uOiBuby1kcmFnOyBhcHAtcmVnaW9uOiBuby1kcmFnOwogICAgICAgIH0KICAgICAgICAjcGFzdGUt
c2VwLWN1c3RvbTpmb2N1cyB7CiAgICAgICAgICAgIG91dGxpbmU6IG5vbmU7IGJhY2tncm91bmQ6IHJn
YmEoOTEsMTE1LDIzMiwuMSk7IGNvbG9yOiB2YXIoLS10eHQpOwogICAgICAgIH0KICAgICAgICAjcGFz
dGUtc2VwLWN1c3RvbTo6cGxhY2Vob2xkZXIgeyBjb2xvcjogdmFyKC0tdHh0Myk7IH0KCiAgICAgICAg
LmktaWNvIHsKICAgICAgICAgICAgd2lkdGg6IDI4cHg7IGhlaWdodDogMjhweDsgYm9yZGVyLXJhZGl1
czogdmFyKC0tcik7IGRpc3BsYXk6IGZsZXg7CiAgICAgICAgICAgIGFsaWduLWl0ZW1zOiBjZW50ZXI7
IGp1c3RpZnktY29udGVudDogY2VudGVyOyBmbGV4LXNocmluazogMDsKICAgICAgICAgICAgYmFja2dy
b3VuZDogI2VkZjJmZjsgY29sb3I6IHZhcigtLWFjYyk7CiAgICAgICAgICAgIHBvc2l0aW9uOiByZWxh
dGl2ZTsgb3ZlcmZsb3c6IHZpc2libGU7CiAgICAgICAgfQogICAgICAgIC5pLWljbyBzdmcgeyB3aWR0
aDogMTZweDsgaGVpZ2h0OiAxNnB4OyBkaXNwbGF5OiBibG9jazsgfQogICAgICAgIC5pLWljby5mdC1p
bWcgeyBjb2xvcjogIzdhZDdmZjsgfQogICAgICAgIC5pLWljby5mdC12aWQgeyBjb2xvcjogI2MwODRm
YzsgfQogICAgICAgIC5pLWljby5mdC16aXAgeyBjb2xvcjogIzhhYjRmZjsgfQogICAgICAgIC5pLWlj
by5mdC1kaXIgeyBjb2xvcjogI2ZmZDU2YTsgfQogICAgICAgIC5pLWljby5mdC1haGsgeyBjb2xvcjog
IzZkZmY5YTsgfQogICAgICAgIC5pLWljby5tZCB7IGNvbG9yOiAjNmI4Y2ZmOyB9CiAgICAgICAgLmkt
aWNvLm1kIHN2ZyB7IHdpZHRoOiAyMHB4OyBoZWlnaHQ6IDIwcHg7IH0KICAgICAgICAuaS1pY28uZnQt
bG5rLCAuaS1pY28uZnQtZG9jIHsgY29sb3I6ICNhOWJkZDA7IH0KICAgICAgICAuaS11c2VkIHsKICAg
ICAgICAgICAgcG9zaXRpb246IGFic29sdXRlOyByaWdodDogMDsgYm90dG9tOiAwOwogICAgICAgICAg
ICB3aWR0aDogMTNweDsgaGVpZ2h0OiAxM3B4OyBib3JkZXItcmFkaXVzOiA1MCU7CiAgICAgICAgICAg
IGJhY2tncm91bmQ6ICMyMmM1NWU7IGJvcmRlcjogMS41cHggc29saWQgI2ZmZjsKICAgICAgICAgICAg
ZGlzcGxheTogZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsganVzdGlmeS1jb250ZW50OiBjZW50ZXI7
CiAgICAgICAgICAgIHBvaW50ZXItZXZlbnRzOiBub25lOyB6LWluZGV4OiAzOwogICAgICAgICAgICBi
b3gtc2hhZG93OiAwIDFweCAycHggcmdiYSgwLDAsMCwuMTYpOwogICAgICAgICAgICB0cmFuc2Zvcm06
IHRyYW5zbGF0ZSgzMCUsIDMwJSk7CiAgICAgICAgfQogICAgICAgIC5pLXVzZWQgc3ZnIHsgd2lkdGg6
IDlweDsgaGVpZ2h0OiA5cHg7IGNvbG9yOiAjZmZmOyBkaXNwbGF5OiBibG9jazsgfQoKICAgICAgICAv
KiBQYXN0ZS1xdWV1ZSB2aXN1YWwgY2hhaW46IGdyYXkgPSBpbiBxdWV1ZTsgZ3JlZW4gPSBkZXF1ZXVl
ZCAocGFzdGVkKSBjaGFpbiAqLwogICAgICAgIC5pdG0ucS1tZW1iZXIgewogICAgICAgICAgICBwYWRk
aW5nLWxlZnQ6IDE0cHg7CiAgICAgICAgICAgIC8qIE1VU1Qgb3ZlcnJpZGUgZ2xvYmFsIC5pdG17b3Zl
cmZsb3c6aGlkZGVufSDigJQgb3RoZXJ3aXNlIGJvdHRvbTotTiByYWlsCiAgICAgICAgICAgICAgIGlz
IGNsaXBwZWQgYW5kIHRoZSBjaGFpbiBsb29rcyDigJzmlq3nur/igJ0gYWNyb3NzIHRoZSA1cHggY2Fy
ZCBnYXAgKi8KICAgICAgICAgICAgb3ZlcmZsb3c6IHZpc2libGUgIWltcG9ydGFudDsKICAgICAgICB9
CiAgICAgICAgLml0bS5xLW1lbWJlciAucS1yYWlsIHsKICAgICAgICAgICAgcG9zaXRpb246IGFic29s
dXRlOwogICAgICAgICAgICBsZWZ0OiA1cHg7CiAgICAgICAgICAgIHRvcDogMDsKICAgICAgICAgICAg
LyogQnJpZGdlIC5pdG0gbWFyZ2luLWJvdHRvbTo1cHggc28gY29uc2VjdXRpdmUgcmFpbHMgcmVhZCBh
cyBvbmUgc3Ryb2tlICovCiAgICAgICAgICAgIGJvdHRvbTogLTVweDsKICAgICAgICAgICAgd2lkdGg6
IDJweDsKICAgICAgICAgICAgYmFja2dyb3VuZDogIzljYTNhZjsKICAgICAgICAgICAgb3BhY2l0eTog
LjcyOwogICAgICAgICAgICBwb2ludGVyLWV2ZW50czogbm9uZTsKICAgICAgICAgICAgei1pbmRleDog
NDsKICAgICAgICB9CiAgICAgICAgLml0bS5xLW1lbWJlci5xLWZpcnN0IC5xLXJhaWwgeyB0b3A6IDE2
cHg7IGJvcmRlci1yYWRpdXM6IDJweCAycHggMCAwOyB9CiAgICAgICAgLyogRW5kIGNoYWluIGF0IHRo
ZSBsYXN0IGRvdCDigJQgZG8gbm90IGhhbmcgaW50byB0aGUgZ2FwIGJlbG93ICovCiAgICAgICAgLml0
bS5xLW1lbWJlci5xLWxhc3QgLnEtcmFpbCB7CiAgICAgICAgICAgIGJvdHRvbTogYXV0bzsKICAgICAg
ICAgICAgaGVpZ2h0OiAyMnB4OwogICAgICAgICAgICBib3JkZXItcmFkaXVzOiAwIDAgMnB4IDJweDsK
ICAgICAgICB9CiAgICAgICAgLml0bS5xLW1lbWJlci5xLWZpcnN0LnEtbGFzdCAucS1yYWlsLAogICAg
ICAgIC5pdG0ucS1tZW1iZXIucS1vbmx5IC5xLXJhaWwgeyBkaXNwbGF5OiBub25lOyB9CiAgICAgICAg
Lml0bS5xLW1lbWJlciAucS1kb3QgewogICAgICAgICAgICBwb3NpdGlvbjogYWJzb2x1dGU7CiAgICAg
ICAgICAgIGxlZnQ6IDJweDsKICAgICAgICAgICAgdG9wOiAxNHB4OwogICAgICAgICAgICB3aWR0aDog
OHB4OwogICAgICAgICAgICBoZWlnaHQ6IDhweDsKICAgICAgICAgICAgYm9yZGVyLXJhZGl1czogNTAl
OwogICAgICAgICAgICBiYWNrZ3JvdW5kOiAjOWNhM2FmOwogICAgICAgICAgICBib3JkZXI6IDEuNXB4
IHNvbGlkICNmZmY7CiAgICAgICAgICAgIGJveC1zaGFkb3c6IDAgMCAwIDFweCByZ2JhKDE1NiwxNjMs
MTc1LC40NSk7CiAgICAgICAgICAgIHBvaW50ZXItZXZlbnRzOiBub25lOwogICAgICAgICAgICB6LWlu
ZGV4OiA1OwogICAgICAgIH0KICAgICAgICAvKiBEZXF1ZXVlZDogZ3JlZW4gZG90czsgZ3JlZW4gcmFp
bCBmb3IgY29uc2VjdXRpdmUgZG9uZSBydW4gKi8KICAgICAgICAuaXRtLnEtbWVtYmVyLnEtZG9uZSAu
cS1kb3QgewogICAgICAgICAgICBiYWNrZ3JvdW5kOiAjMjJjNTVlOwogICAgICAgICAgICBib3gtc2hh
ZG93OiAwIDAgMCAxcHggcmdiYSgzNCwxOTcsOTQsLjQpOwogICAgICAgIH0KICAgICAgICAuaXRtLnEt
bWVtYmVyLnEtZG9uZS1saW5rIC5xLXJhaWwgewogICAgICAgICAgICBiYWNrZ3JvdW5kOiAjMjJjNTVl
OwogICAgICAgICAgICBvcGFjaXR5OiAuOTI7CiAgICAgICAgfQoKICAgICAgICAuaXRtLmp1bXAtZmxh
c2ggewogICAgICAgICAgICBib3gtc2hhZG93OiAwIDAgMCAycHggcmdiYSg5MSwxMTUsMjMyLC41NSks
IDAgMnB4IDEwcHggcmdiYSg5MSwxMTUsMjMyLC4yMik7CiAgICAgICAgICAgIGJhY2tncm91bmQ6ICNl
OGVkZmY7CiAgICAgICAgICAgIHRyYW5zaXRpb246IGJhY2tncm91bmQgLjM1cyBlYXNlLCBib3gtc2hh
ZG93IC4zNXMgZWFzZTsKICAgICAgICB9CgogICAgICAgIC5pLWJvZHkgeyBmbGV4OiAxOyBtaW4td2lk
dGg6IDA7IGRpc3BsYXk6IGZsZXg7IGZsZXgtZGlyZWN0aW9uOiBjb2x1bW47IHBvc2l0aW9uOiByZWxh
dGl2ZTsgei1pbmRleDogMjsgfQogICAgICAgIC5pLXByZXYsIC5pLW5hbWUgewogICAgICAgICAgICBm
b250LXNpemU6IDEzcHg7IGZvbnQtd2VpZ2h0OiA1MDA7IGNvbG9yOiB2YXIoLS10eHQpOyB3b3JkLWJy
ZWFrOiBicmVhay1hbGw7CiAgICAgICAgICAgIHdoaXRlLXNwYWNlOiBwcmUtd3JhcDsgLyog5pSv5oyB
5aSa5paH5Lu2L+WkmuihjOaWh+acrOaNouihjOaYvuekuiAqLwogICAgICAgIH0KICAgICAgICAuaS1w
cmV2IHsKICAgICAgICAgICAgZGlzcGxheTogLXdlYmtpdC1ib3g7IC13ZWJraXQtYm94LW9yaWVudDog
dmVydGljYWw7IC13ZWJraXQtbGluZS1jbGFtcDogNTsgb3ZlcmZsb3c6IGhpZGRlbjsKICAgICAgICAg
ICAgdGV4dC1vdmVyZmxvdzogZWxsaXBzaXM7CiAgICAgICAgfQogICAgICAgIC5pLW5hbWUgewogICAg
ICAgICAgICBkaXNwbGF5OiAtd2Via2l0LWJveDsgLXdlYmtpdC1ib3gtb3JpZW50OiB2ZXJ0aWNhbDsg
LXdlYmtpdC1saW5lLWNsYW1wOiAyOyBvdmVyZmxvdzogaGlkZGVuOwogICAgICAgIH0KICAgICAgICAv
KiBGaWxlIGNsaXAgd2hvc2UgcGF0aChzKSBubyBsb25nZXIgZXhpc3Qg4oCUIGxpZ2h0IGJvbGQgZ3Jh
eSBzdHJpa2UgKi8KICAgICAgICAuaXRtLmdvbmUgLmktbmFtZSB7CiAgICAgICAgICAgIGNvbG9yOiAj
OWFhMGIwOwogICAgICAgICAgICB0ZXh0LWRlY29yYXRpb246IGxpbmUtdGhyb3VnaDsKICAgICAgICAg
ICAgdGV4dC1kZWNvcmF0aW9uLXRoaWNrbmVzczogMnB4OwogICAgICAgICAgICB0ZXh0LWRlY29yYXRp
b24tY29sb3I6IHJnYmEoMTU0LCAxNjAsIDE3NiwgLjU1KTsKICAgICAgICAgICAgdGV4dC1kZWNvcmF0
aW9uLXNraXAtaW5rOiBub25lOwogICAgICAgIH0KICAgICAgICAuaXRtLmdvbmUgLmktaWNvIHsgb3Bh
Y2l0eTogLjU1OyB9CiAgICAgICAgLml0bS5nb25lIC5pLXRodW1iLXdyYXAgeyBvcGFjaXR5OiAuNTU7
IH0KICAgICAgICAuaS1wcmV2LnVybCB7IGNvbG9yOiB2YXIoLS1hY2MpOyB9CgogICAgICAgIC5yZi1w
YXRoIHsKICAgICAgICAgICAgZGlzcGxheTogZmxleDsgZmxleC13cmFwOiB3cmFwOyBhbGlnbi1pdGVt
czogY2VudGVyOwogICAgICAgICAgICBnYXA6IDA7IHJvdy1nYXA6IDNweDsKICAgICAgICAgICAgZm9u
dC1zaXplOiAxM3B4OyBmb250LXdlaWdodDogNjAwOyBjb2xvcjogdmFyKC0tdHh0KTsKICAgICAgICAg
ICAgbGluZS1oZWlnaHQ6IDEuNDU7IHdvcmQtYnJlYWs6IGJyZWFrLXdvcmQ7CiAgICAgICAgICAgIG1h
eC13aWR0aDogMTAwJTsKICAgICAgICAgICAgd2lkdGg6IGZpdC1jb250ZW50OwogICAgICAgICAgICBw
b3NpdGlvbjogcmVsYXRpdmU7CiAgICAgICAgICAgIHotaW5kZXg6IDY7CiAgICAgICAgICAgIC13ZWJr
aXQtYXBwLXJlZ2lvbjogbm8tZHJhZzsgYXBwLXJlZ2lvbjogbm8tZHJhZzsKICAgICAgICAgICAgcG9p
bnRlci1ldmVudHM6IGF1dG87CiAgICAgICAgfQogICAgICAgIC5yZi1zZWcgewogICAgICAgICAgICBj
b2xvcjogdmFyKC0tYWNjKTsKICAgICAgICAgICAgY3Vyc29yOiBwb2ludGVyOwogICAgICAgICAgICBw
YWRkaW5nOiAxcHggM3B4OwogICAgICAgICAgICBtYXJnaW46IDA7CiAgICAgICAgICAgIGJvcmRlcjog
bm9uZTsKICAgICAgICAgICAgYmFja2dyb3VuZDogdHJhbnNwYXJlbnQ7CiAgICAgICAgICAgIGJvcmRl
ci1yYWRpdXM6IDNweDsKICAgICAgICAgICAgZm9udDogaW5oZXJpdDsKICAgICAgICAgICAgZm9udC1z
aXplOiAxM3B4OwogICAgICAgICAgICBmb250LXdlaWdodDogNjAwOwogICAgICAgICAgICBsaW5lLWhl
aWdodDogMS40NTsKICAgICAgICAgICAgLXdlYmtpdC1hcHAtcmVnaW9uOiBuby1kcmFnOyBhcHAtcmVn
aW9uOiBuby1kcmFnOwogICAgICAgICAgICBwb2ludGVyLWV2ZW50czogYXV0byAhaW1wb3J0YW50Owog
ICAgICAgICAgICBwb3NpdGlvbjogcmVsYXRpdmU7CiAgICAgICAgICAgIHotaW5kZXg6IDg7CiAgICAg
ICAgICAgIHRyYW5zaXRpb246IGJhY2tncm91bmQgLjEycyBlYXNlLCBjb2xvciAuMTJzIGVhc2U7CiAg
ICAgICAgfQogICAgICAgIC5yZi1zZWc6aG92ZXIgewogICAgICAgICAgICBiYWNrZ3JvdW5kOiByZ2Jh
KDkxLDExNSwyMzIsLjE0KTsKICAgICAgICAgICAgdGV4dC1kZWNvcmF0aW9uOiB1bmRlcmxpbmU7CiAg
ICAgICAgfQogICAgICAgIC5yZi1zZXAgewogICAgICAgICAgICBjb2xvcjogdmFyKC0tdHh0Myk7CiAg
ICAgICAgICAgIHBhZGRpbmc6IDAgMnB4OwogICAgICAgICAgICBtYXJnaW46IDA7CiAgICAgICAgICAg
IHVzZXItc2VsZWN0OiBub25lOwogICAgICAgICAgICBmbGV4LXNocmluazogMDsKICAgICAgICAgICAg
b3BhY2l0eTogLjU1OwogICAgICAgICAgICBwb2ludGVyLWV2ZW50czogbm9uZTsKICAgICAgICAgICAg
Zm9udC1zaXplOiAxMnB4OwogICAgICAgICAgICBsaW5lLWhlaWdodDogMS40NTsKICAgICAgICB9CiAg
ICAgICAgLml0bS5yZi1maXhlZCAuaS1pY28gewogICAgICAgICAgICBib3gtc2hhZG93OiAwIDAgMCAx
LjVweCByZ2JhKDkxLDExNSwyMzIsLjQ1KTsKICAgICAgICB9CiAgICAgICAgLnJmLXBpbi10YWcgewog
ICAgICAgICAgICBkaXNwbGF5OiBpbmxpbmUtZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsganVzdGlm
eS1jb250ZW50OiBjZW50ZXI7CiAgICAgICAgICAgIGZsZXgtc2hyaW5rOiAwOwogICAgICAgICAgICBo
ZWlnaHQ6IDE2cHg7IHBhZGRpbmc6IDAgNnB4OyBtYXJnaW4tcmlnaHQ6IDA7CiAgICAgICAgICAgIGJv
cmRlci1yYWRpdXM6IDRweDsKICAgICAgICAgICAgZm9udC1zaXplOiAxMHB4OyBmb250LXdlaWdodDog
NTAwOwogICAgICAgICAgICBjb2xvcjogIzdhODQ5OTsKICAgICAgICAgICAgYmFja2dyb3VuZDogcmdi
YSgxMjIsMTMyLDE1MywuMTIpOwogICAgICAgICAgICBib3JkZXI6IDFweCBzb2xpZCByZ2JhKDEyMiwx
MzIsMTUzLC4yMik7CiAgICAgICAgICAgIGxldHRlci1zcGFjaW5nOiAuMDJlbTsKICAgICAgICAgICAg
d2hpdGUtc3BhY2U6IG5vd3JhcDsKICAgICAgICAgICAgcG9pbnRlci1ldmVudHM6IG5vbmU7CiAgICAg
ICAgfQogICAgICAgIC5pLXRodW1iLXdyYXAgewogICAgICAgICAgICB3aWR0aDogMTAwJTsgbWluLWhl
aWdodDogNDhweDsgbWF4LWhlaWdodDogMTgwcHg7IG1hcmdpbi1ib3R0b206IDRweDsKICAgICAgICAg
ICAgZGlzcGxheTogZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsganVzdGlmeS1jb250ZW50OiBjZW50
ZXI7CiAgICAgICAgICAgIGJhY2tncm91bmQ6ICNmM2Y1Zjk7IGJvcmRlci1yYWRpdXM6IHZhcigtLXIp
OyBvdmVyZmxvdzogaGlkZGVuOwogICAgICAgIH0KICAgICAgICAuaS10aHVtYi13cmFwLndhaXRpbmcg
ewogICAgICAgICAgICBtaW4taGVpZ2h0OiA4OHB4OwogICAgICAgICAgICBiYWNrZ3JvdW5kOiBsaW5l
YXItZ3JhZGllbnQoOTBkZWcsICNlOGViZjIgMCUsICNmNGY2ZmEgNDUlLCAjZThlYmYyIDEwMCUpOwog
ICAgICAgICAgICBiYWNrZ3JvdW5kLXNpemU6IDIwMCUgMTAwJTsKICAgICAgICAgICAgYW5pbWF0aW9u
OiB0aHVtYlNoaW1tZXIgMS4wNXMgZWFzZS1pbi1vdXQgaW5maW5pdGU7CiAgICAgICAgfQogICAgICAg
IEBrZXlmcmFtZXMgdGh1bWJTaGltbWVyIHsKICAgICAgICAgICAgMCUgeyBiYWNrZ3JvdW5kLXBvc2l0
aW9uOiAxMDAlIDA7IH0KICAgICAgICAgICAgMTAwJSB7IGJhY2tncm91bmQtcG9zaXRpb246IC0xMDAl
IDA7IH0KICAgICAgICB9CiAgICAgICAgLmktdGh1bWIgeyBtYXgtd2lkdGg6IDEwMCU7IG1heC1oZWln
aHQ6IDE4MHB4OyB3aWR0aDogYXV0bzsgaGVpZ2h0OiBhdXRvOyBvYmplY3QtZml0OiBjb250YWluOyBk
aXNwbGF5OiBibG9jazsgfQogICAgICAgIC5pLXRodW1iLnRodW1iLWxvYWRpbmcgeyBvcGFjaXR5OiAw
OyB3aWR0aDogMXB4OyBoZWlnaHQ6IDFweDsgfQoKICAgICAgICAvKiBNZXRhIGJhcjogdGltZSBsZWZ0
IHwgZXhwYW5kIGNlbnRlciB8IHRhZ3MgcmlnaHQgKi8KICAgICAgICAuaS1tZXRhIHsKICAgICAgICAg
ICAgZGlzcGxheTogZ3JpZDsKICAgICAgICAgICAgZ3JpZC10ZW1wbGF0ZS1jb2x1bW5zOiAxZnIgYXV0
byAxZnI7CiAgICAgICAgICAgIGFsaWduLWl0ZW1zOiBjZW50ZXI7CiAgICAgICAgICAgIGdhcDogNHB4
OwogICAgICAgICAgICBtYXJnaW4tdG9wOiA0cHg7CiAgICAgICAgICAgIHdpZHRoOiAxMDAlOwogICAg
ICAgIH0KICAgICAgICAuaS1tZXRhIC5pLXRpbWUgeyBqdXN0aWZ5LXNlbGY6IHN0YXJ0OyB9CiAgICAg
ICAgLmktbWV0YS1jZW50ZXIgewogICAgICAgICAgICBqdXN0aWZ5LXNlbGY6IGNlbnRlcjsKICAgICAg
ICAgICAgZGlzcGxheTogZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsganVzdGlmeS1jb250ZW50OiBj
ZW50ZXI7CiAgICAgICAgICAgIGdhcDogNHB4OwogICAgICAgICAgICBtaW4td2lkdGg6IDFweDsgLyog
a2VlcCBjZW50ZXIgY29sdW1uIGV2ZW4gd2hlbiBleHBhbmQgaXMgaGlkZGVuICovCiAgICAgICAgfQog
ICAgICAgIC5pLW1ldGEtcmlnaHQgewogICAgICAgICAgICBqdXN0aWZ5LXNlbGY6IGVuZDsKICAgICAg
ICAgICAgZGlzcGxheTogZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsgZ2FwOiA1cHg7IGZsZXgtd3Jh
cDogbm93cmFwOwogICAgICAgICAgICBqdXN0aWZ5LWNvbnRlbnQ6IGZsZXgtZW5kOwogICAgICAgICAg
ICBtaW4td2lkdGg6IDA7CiAgICAgICAgfQogICAgICAgIC5pLW1ldGEtcmlnaHQudGV4dC1tZXRhIHsK
ICAgICAgICAgICAgZmxleC13cmFwOiBub3dyYXA7CiAgICAgICAgICAgIGdhcDogNHB4OwogICAgICAg
IH0KICAgICAgICAuaS1zcmMtdGl0bGUgewogICAgICAgICAgICBmb250LXNpemU6IDEwcHg7CiAgICAg
ICAgICAgIGNvbG9yOiB2YXIoLS10eHQzKTsKICAgICAgICAgICAgbWF4LXdpZHRoOiAxMWVtOwogICAg
ICAgICAgICBvdmVyZmxvdzogaGlkZGVuOwogICAgICAgICAgICB0ZXh0LW92ZXJmbG93OiBlbGxpcHNp
czsKICAgICAgICAgICAgd2hpdGUtc3BhY2U6IG5vd3JhcDsKICAgICAgICAgICAgbWluLXdpZHRoOiAw
OwogICAgICAgICAgICBsaW5lLWhlaWdodDogMS40OwogICAgICAgIH0KICAgICAgICAuaS10aW1lLCAu
aS10YWcgeyBmb250LXNpemU6IDEwcHg7IGNvbG9yOiB2YXIoLS10eHQzKTsgfQogICAgICAgIC5pLXRh
ZyB7CiAgICAgICAgICAgIGJhY2tncm91bmQ6ICNmMWYzZjg7IHBhZGRpbmc6IDAgNXB4OyBib3JkZXIt
cmFkaXVzOiAzcHg7CiAgICAgICAgICAgIHdoaXRlLXNwYWNlOiBub3dyYXA7IGZsZXgtc2hyaW5rOiAw
OyBsaW5lLWhlaWdodDogMS40OwogICAgICAgIH0KICAgICAgICAuaS1jaGFycyB7CiAgICAgICAgICAg
IGZvbnQtc2l6ZTogMTBweDsgY29sb3I6IHZhcigtLXR4dDMpOwogICAgICAgICAgICBiYWNrZ3JvdW5k
OiAjZjFmM2Y4OyBwYWRkaW5nOiAwIDVweDsgYm9yZGVyLXJhZGl1czogM3B4OwogICAgICAgICAgICBm
b250LXZhcmlhbnQtbnVtZXJpYzogdGFidWxhci1udW1zOwogICAgICAgICAgICB3aGl0ZS1zcGFjZTog
bm93cmFwOwogICAgICAgICAgICBkaXNwbGF5OiBpbmxpbmUtZmxleDsgYWxpZ24taXRlbXM6IGJhc2Vs
aW5lOyBnYXA6IDJweDsKICAgICAgICB9CiAgICAgICAgLmktY2hhcnMgLm4gewogICAgICAgICAgICBk
aXNwbGF5OiBpbmxpbmUtYmxvY2s7CiAgICAgICAgICAgIG1pbi13aWR0aDogNGNoOwogICAgICAgICAg
ICB0ZXh0LWFsaWduOiByaWdodDsKICAgICAgICAgICAgZm9udC1mYW1pbHk6ICdDYXNjYWRpYSBNb25v
JywgJ0NvbnNvbGFzJywgJ1NhcmFzYSBNb25vIFNDJywgdWktbW9ub3NwYWNlLCBtb25vc3BhY2U7CiAg
ICAgICAgICAgIGZvbnQtd2VpZ2h0OiA2MDA7CiAgICAgICAgICAgIGNvbG9yOiB2YXIoLS10eHQyKTsK
ICAgICAgICB9CiAgICAgICAgLyogc3JjLXRpdGxlLXRpcCAqLwogICAgICAgIC5pLXNyYy1pY28sIC5t
Zy1zcmMgeyBjdXJzb3I6IHBvaW50ZXI7IH0KICAgICAgICAjc3JjLXRpcCB7CiAgICAgICAgICAgIHBv
c2l0aW9uOiBmaXhlZDsgei1pbmRleDogOTk5OTk7CiAgICAgICAgICAgIG1heC13aWR0aDogbWluKDI4
MHB4LCBjYWxjKDEwMHZ3IC0gMTZweCkpOwogICAgICAgICAgICBwYWRkaW5nOiA2cHggMTBweDsKICAg
ICAgICAgICAgYm9yZGVyLXJhZGl1czogOHB4OwogICAgICAgICAgICBiYWNrZ3JvdW5kOiByZ2JhKDMy
LDM2LDQ4LC45Mik7IGNvbG9yOiAjZmZmOwogICAgICAgICAgICBmb250LXNpemU6IDEycHg7IGxpbmUt
aGVpZ2h0OiAxLjM1OwogICAgICAgICAgICBib3gtc2hhZG93OiAwIDZweCAxOHB4IHJnYmEoMCwwLDAs
LjIyKTsKICAgICAgICAgICAgcG9pbnRlci1ldmVudHM6IG5vbmU7CiAgICAgICAgICAgIG9wYWNpdHk6
IDA7IHRyYW5zZm9ybTogdHJhbnNsYXRlWSg0cHgpOwogICAgICAgICAgICB0cmFuc2l0aW9uOiBvcGFj
aXR5IC4ycyBlYXNlLCB0cmFuc2Zvcm0gLjIycyBjdWJpYy1iZXppZXIoLjIyLDEsLjM2LDEpOwogICAg
ICAgICAgICB3b3JkLWJyZWFrOiBicmVhay13b3JkOwogICAgICAgIH0KICAgICAgICAjc3JjLXRpcC5z
aG93IHsgb3BhY2l0eTogMTsgdHJhbnNmb3JtOiB0cmFuc2xhdGVZKDApOyB9CiAgICAgICAgLmktc3Jj
LWljbyB7CiAgICAgICAgICAgIHdpZHRoOiAxNHB4OyBoZWlnaHQ6IDE0cHg7IGZsZXgtc2hyaW5rOiAw
OwogICAgICAgICAgICBib3JkZXItcmFkaXVzOiAycHg7IG9iamVjdC1maXQ6IGNvbnRhaW47CiAgICAg
ICAgICAgIGRpc3BsYXk6IGJsb2NrOwogICAgICAgIH0KICAgICAgICAuaS1udW0gewogICAgICAgICAg
ICBkaXNwbGF5OiBmbGV4OyBmbGV4LWRpcmVjdGlvbjogY29sdW1uOyBhbGlnbi1pdGVtczogZmxleC1l
bmQ7CiAgICAgICAgICAgIGp1c3RpZnktY29udGVudDogc3BhY2UtYmV0d2VlbjsKICAgICAgICAgICAg
YWxpZ24tc2VsZjogc3RyZXRjaDsKICAgICAgICAgICAgZm9udC1zaXplOiAxMHB4OyBjb2xvcjogdmFy
KC0tdHh0Myk7IG1pbi13aWR0aDogMTZweDsKICAgICAgICAgICAgdGV4dC1hbGlnbjogcmlnaHQ7IGZs
ZXgtc2hyaW5rOiAwOwogICAgICAgICAgICBwYWRkaW5nLXRvcDogMnB4OwogICAgICAgIH0KICAgICAg
ICAuaS1udW0gLmktc3JjLWljbyB7IHdpZHRoOiAxNnB4OyBoZWlnaHQ6IDE2cHg7IG1hcmdpbi10b3A6
IGF1dG87IH0KCiAgICAgICAgLmktZXhwYW5kLWJ0biB7CiAgICAgICAgICAgIGJvcmRlcjogbm9uZTsg
YmFja2dyb3VuZDogbm9uZTsgY3Vyc29yOiBwb2ludGVyOwogICAgICAgICAgICBjb2xvcjogdmFyKC0t
dHh0Myk7IGZvbnQtc2l6ZTogMTJweDsgcGFkZGluZzogM3B4IDEwcHg7CiAgICAgICAgICAgIGJvcmRl
ci1yYWRpdXM6IDhweDsgZGlzcGxheTogbm9uZTsgYWxpZ24taXRlbXM6IGNlbnRlcjsgZ2FwOiA0cHg7
CiAgICAgICAgICAgIHRyYW5zaXRpb246IGNvbG9yIHZhcigtLXRyKSwgYmFja2dyb3VuZCB2YXIoLS10
cik7CiAgICAgICAgICAgIC13ZWJraXQtYXBwLXJlZ2lvbjogbm8tZHJhZzsgYXBwLXJlZ2lvbjogbm8t
ZHJhZzsKICAgICAgICAgICAgbGluZS1oZWlnaHQ6IDEuMjsKICAgICAgICB9CiAgICAgICAgLmktZXhw
YW5kLWJ0biBzdmcgeyB3aWR0aDogMTRweDsgaGVpZ2h0OiAxNHB4OyBmbGV4LXNocmluazogMDsgfQog
ICAgICAgIC5pLWV4cGFuZC1idG4ub24geyBkaXNwbGF5OiBpbmxpbmUtZmxleDsgfQogICAgICAgIC5p
LWV4cGFuZC1idG46aG92ZXIgeyBjb2xvcjogdmFyKC0tYWNjKTsgYmFja2dyb3VuZDogcmdiYSg5MSwx
MTUsMjMyLC4wOCk7IH0KICAgICAgICAuaS1wcmV2LmV4cGFuZGVkLCAuaS1uYW1lLmV4cGFuZGVkIHsK
ICAgICAgICAgICAgLXdlYmtpdC1saW5lLWNsYW1wOiB1bnNldDsKICAgICAgICAgICAgZGlzcGxheTog
YmxvY2s7CiAgICAgICAgICAgIG92ZXJmbG93OiBoaWRkZW47CiAgICAgICAgICAgIC8qIOmrmOW6pueU
sSBKUyDmjInliJfooajlj6/op4bljLrorr7lrprvvJrnuqbljaDmlbTooajlsJHkuIDooYwgKi8KICAg
ICAgICB9CiAgICAgICAgLmktc3JjLXRpdGxlIHsgZGlzcGxheTogbm9uZSAhaW1wb3J0YW50OyB9CiAg
ICAgICAgLmktZmlsZS1kZXRhaWwgewogICAgICAgICAgICBkaXNwbGF5OiBub25lOwogICAgICAgICAg
ICBtYXJnaW4tdG9wOiA0cHg7CiAgICAgICAgICAgIHBhZGRpbmc6IDA7CiAgICAgICAgICAgIGJhY2tn
cm91bmQ6IG5vbmU7CiAgICAgICAgICAgIGJvcmRlcjogbm9uZTsKICAgICAgICB9CiAgICAgICAgLmkt
ZmlsZS1kZXRhaWwub24geyBkaXNwbGF5OiBibG9jazsgfQogICAgICAgIC5mZC1ibG9jayB7CiAgICAg
ICAgICAgIGRpc3BsYXk6IGZsZXg7IGZsZXgtZGlyZWN0aW9uOiBjb2x1bW47IGdhcDogNnB4OwogICAg
ICAgIH0KICAgICAgICAuZmQtYmxvY2sgKyAuZmQtYmxvY2sgeyBtYXJnaW4tdG9wOiA4cHg7IH0KICAg
ICAgICAuZmQtcGF0aCB7CiAgICAgICAgICAgIHdpZHRoOiAxMDAlOwogICAgICAgICAgICBmb250OiA2
MDAgMTJweC8xLjU1ICdTZWdvZSBVSSBWYXJpYWJsZSBUZXh0JywnU2Vnb2UgVUknLCdNaWNyb3NvZnQg
WWFIZWkgVUknLHNhbnMtc2VyaWY7CiAgICAgICAgICAgIGNvbG9yOiB2YXIoLS10eHQyKTsKICAgICAg
ICAgICAgbGV0dGVyLXNwYWNpbmc6IC4wMWVtOwogICAgICAgICAgICB3b3JkLWJyZWFrOiBicmVhay1h
bGw7CiAgICAgICAgICAgIHVzZXItc2VsZWN0OiB0ZXh0OwogICAgICAgICAgICAtd2Via2l0LWFwcC1y
ZWdpb246IG5vLWRyYWc7IGFwcC1yZWdpb246IG5vLWRyYWc7CiAgICAgICAgfQogICAgICAgIC5mZC1w
YXRoLmxpdmUgeyBjdXJzb3I6IHBvaW50ZXI7IH0KICAgICAgICAuZmQtcGF0aC5saXZlOmhvdmVyIHsg
Y29sb3I6IHZhcigtLWFjYyk7IH0KICAgICAgICAuZmQtcGF0aC5kZWFkIHsKICAgICAgICAgICAgY29s
b3I6ICM5YWEwYjA7CiAgICAgICAgICAgIHRleHQtZGVjb3JhdGlvbjogbGluZS10aHJvdWdoOwogICAg
ICAgICAgICB0ZXh0LWRlY29yYXRpb24tdGhpY2tuZXNzOiAycHg7CiAgICAgICAgICAgIHRleHQtZGVj
b3JhdGlvbi1jb2xvcjogcmdiYSgxNTQsIDE2MCwgMTc2LCAuNTUpOwogICAgICAgICAgICB0ZXh0LWRl
Y29yYXRpb24tc2tpcC1pbms6IG5vbmU7CiAgICAgICAgICAgIGN1cnNvcjogZGVmYXVsdDsKICAgICAg
ICB9CiAgICAgICAgLmZkLWFjdGlvbnMgewogICAgICAgICAgICBkaXNwbGF5OiBmbGV4OyBhbGlnbi1p
dGVtczogY2VudGVyOyBqdXN0aWZ5LWNvbnRlbnQ6IGZsZXgtZW5kOwogICAgICAgICAgICBnYXA6IDhw
eDsgZmxleC13cmFwOiB3cmFwOwogICAgICAgIH0KICAgICAgICAuZmQtYnRuIHsKICAgICAgICAgICAg
Ym9yZGVyOiBub25lOyBiYWNrZ3JvdW5kOiBub25lOyBjdXJzb3I6IHBvaW50ZXI7CiAgICAgICAgICAg
IGNvbG9yOiB2YXIoLS10eHQzKTsgZm9udC1zaXplOiAxMHB4OyBmb250LXdlaWdodDogNjAwOwogICAg
ICAgICAgICBwYWRkaW5nOiAxcHggMnB4OyBkaXNwbGF5OiBpbmxpbmUtZmxleDsgYWxpZ24taXRlbXM6
IGNlbnRlcjsgZ2FwOiAycHg7CiAgICAgICAgICAgIHdoaXRlLXNwYWNlOiBub3dyYXA7CiAgICAgICAg
ICAgIC13ZWJraXQtYXBwLXJlZ2lvbjogbm8tZHJhZzsgYXBwLXJlZ2lvbjogbm8tZHJhZzsKICAgICAg
ICAgICAgdHJhbnNpdGlvbjogY29sb3IgdmFyKC0tdHIpOwogICAgICAgIH0KICAgICAgICAuZmQtYnRu
OmhvdmVyIHsgY29sb3I6IHZhcigtLWFjYyk7IH0KICAgICAgICAuZmQtYnRuLm9rIHsgY29sb3I6ICMx
ZjdhNTU7IH0KCiAgICAgICAgLyog4pSA4pSAIENvbnRleHQgbWVudSDilIDilIDilIDilIDilIDilIDi
lIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDi
lIDilIDilIDilIDilIDilIAgKi8KICAgICAgICAjY3R4IHsKICAgICAgICAgICAgcG9zaXRpb246IGZp
eGVkOyB6LWluZGV4OiA5OTk5OyBtaW4td2lkdGg6IDEzMnB4OyBkaXNwbGF5OiBub25lOyBwYWRkaW5n
OiA0cHg7CiAgICAgICAgICAgIGJhY2tncm91bmQ6ICNmZmY7IGJvcmRlci1yYWRpdXM6IHZhcigtLXIp
OyBib3gtc2hhZG93OiAwIDZweCAxNnB4IHJnYmEoMCwwLDAsLjE0KTsKICAgICAgICAgICAgLXdlYmtp
dC1hcHAtcmVnaW9uOiBuby1kcmFnOyBhcHAtcmVnaW9uOiBuby1kcmFnOwogICAgICAgIH0KICAgICAg
ICAjY3R4Lm9uIHsgZGlzcGxheTogYmxvY2s7IH0KICAgICAgICAuYy1pdGVtIHsKICAgICAgICAgICAg
ZGlzcGxheTogZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsgZ2FwOiA3cHg7IHBhZGRpbmc6IDZweCA5
cHg7CiAgICAgICAgICAgIGJvcmRlci1yYWRpdXM6IHZhcigtLXIpOyBjdXJzb3I6IHBvaW50ZXI7IGZv
bnQtc2l6ZTogMTFweDsgY29sb3I6IHZhcigtLXR4dCk7CiAgICAgICAgfQogICAgICAgIC5jLWl0ZW06
aG92ZXIgeyBiYWNrZ3JvdW5kOiAjZjJmNGY5OyB9CiAgICAgICAgLmMtaXRlbS5kYW5nZXIgeyBjb2xv
cjogI2ZmN2I5YzsgfQogICAgICAgIC5jLXNlcCB7IGhlaWdodDogMXB4OyBiYWNrZ3JvdW5kOiAjZWNl
ZmY1OyBtYXJnaW46IDNweCAwOyB9CiAgICAgICAgLmMtaWNvIHsgd2lkdGg6IDE0cHg7IHRleHQtYWxp
Z246IGNlbnRlcjsgfQoKICAgICAgICAvKiDilIDilIAgQ2xlYXIgY29uZmlybSDilIDilIDilIDilIDi
lIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDi
lIDilIDilIDilIDilIDilIDilIAgKi8KICAgICAgICAjY2xyLWRsZyB7CiAgICAgICAgICAgIGRpc3Bs
YXk6IG5vbmU7IHBvc2l0aW9uOiBmaXhlZDsgaW5zZXQ6IDA7IHotaW5kZXg6IDEwMDAwOwogICAgICAg
ICAgICBiYWNrZ3JvdW5kOiByZ2JhKDIwLCAyMiwgMzUsIC40Mik7CiAgICAgICAgICAgIGFsaWduLWl0
ZW1zOiBjZW50ZXI7IGp1c3RpZnktY29udGVudDogY2VudGVyOwogICAgICAgICAgICAtd2Via2l0LWFw
cC1yZWdpb246IG5vLWRyYWc7IGFwcC1yZWdpb246IG5vLWRyYWc7CiAgICAgICAgfQogICAgICAgICNj
bHItZGxnLm9uIHsgZGlzcGxheTogZmxleDsgfQogICAgICAgIC5jbHItYm94IHsKICAgICAgICAgICAg
d2lkdGg6IG1pbigyODBweCwgY2FsYygxMDAlIC0gMzJweCkpOwogICAgICAgICAgICBiYWNrZ3JvdW5k
OiAjZmZmOyBib3JkZXItcmFkaXVzOiAxMnB4OwogICAgICAgICAgICBib3gtc2hhZG93OiAwIDEycHgg
MzJweCByZ2JhKDAsMCwwLC4xOCk7CiAgICAgICAgICAgIHBhZGRpbmc6IDE2cHggMTZweCAxNHB4OyBj
b2xvcjogdmFyKC0tdHh0KTsKICAgICAgICB9CiAgICAgICAgLmNsci10aXRsZSB7IGZvbnQtc2l6ZTog
MTRweDsgZm9udC13ZWlnaHQ6IDcwMDsgbWFyZ2luLWJvdHRvbTogNnB4OyB9CiAgICAgICAgLmNsci1k
ZXNjIHsgZm9udC1zaXplOiAxMXB4OyBjb2xvcjogdmFyKC0tdHh0Myk7IGxpbmUtaGVpZ2h0OiAxLjU7
IG1hcmdpbi1ib3R0b206IDEycHg7IH0KICAgICAgICAuY2xyLWNoZWNrIHsKICAgICAgICAgICAgZGlz
cGxheTogZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsgZ2FwOiA3cHg7CiAgICAgICAgICAgIGZvbnQt
c2l6ZTogMTJweDsgY29sb3I6IHZhcigtLXR4dCk7IGN1cnNvcjogcG9pbnRlcjsKICAgICAgICAgICAg
dXNlci1zZWxlY3Q6IG5vbmU7IG1hcmdpbi1ib3R0b206IDE0cHg7CiAgICAgICAgfQogICAgICAgIC5j
bHItY2hlY2sgaW5wdXQgewogICAgICAgICAgICB3aWR0aDogMTRweDsgaGVpZ2h0OiAxNHB4OyBhY2Nl
bnQtY29sb3I6IHZhcigtLWFjYyk7IGN1cnNvcjogcG9pbnRlcjsKICAgICAgICB9CiAgICAgICAgLmNs
ci1idG5zIHsgZGlzcGxheTogZmxleDsgZ2FwOiA4cHg7IGp1c3RpZnktY29udGVudDogZmxleC1lbmQ7
IH0KICAgICAgICAuY2xyLWJ0bnMgYnV0dG9uIHsKICAgICAgICAgICAgYm9yZGVyOiBub25lOyBib3Jk
ZXItcmFkaXVzOiA4cHg7IHBhZGRpbmc6IDdweCAxNHB4OwogICAgICAgICAgICBmb250LXNpemU6IDEy
cHg7IGN1cnNvcjogcG9pbnRlcjsgZm9udC13ZWlnaHQ6IDYwMDsKICAgICAgICAgICAgdHJhbnNpdGlv
bjogYmFja2dyb3VuZCB2YXIoLS10ciksIGNvbG9yIHZhcigtLXRyKTsKICAgICAgICB9CiAgICAgICAg
I2Nsci1jYW5jZWwgeyBiYWNrZ3JvdW5kOiAjZjFmM2Y4OyBjb2xvcjogdmFyKC0tdHh0Mik7IH0KICAg
ICAgICAjY2xyLWNhbmNlbDpob3ZlciB7IGJhY2tncm91bmQ6ICNlNmU5ZjI7IH0KICAgICAgICAjY2xy
LW9rIHsgYmFja2dyb3VuZDogcmdiYSgyNTUsMTIzLDE1NiwuMTQpOyBjb2xvcjogI2U4NWE3YTsgfQog
ICAgICAgICNjbHItb2s6aG92ZXIgeyBiYWNrZ3JvdW5kOiByZ2JhKDI1NSwxMjMsMTU2LC4yNCk7IH0K
CiAgICAgICAgLyog4pSA4pSAIEZpbGUgcGF0aCB0aXAg4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA
4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA
4pSA4pSAICovCiAgICAgICAgI3BhdGgtdGlwIHsKICAgICAgICAgICAgZGlzcGxheTogbm9uZTsgcG9z
aXRpb246IGZpeGVkOyB6LWluZGV4OiAxMDAwMTsKICAgICAgICAgICAgd2lkdGg6IG1pbigzMjBweCwg
Y2FsYygxMDB2dyAtIDE2cHgpKTsKICAgICAgICAgICAgbWF4LWhlaWdodDogbWluKDI4MHB4LCBjYWxj
KDEwMHZoIC0gMjRweCkpOwogICAgICAgICAgICBvdmVyZmxvdzogYXV0bzsKICAgICAgICAgICAgcGFk
ZGluZzogMDsKICAgICAgICAgICAgYmFja2dyb3VuZDogbGluZWFyLWdyYWRpZW50KDE2NWRlZywgI2Zm
ZmZmZiAwJSwgI2Y2ZjhmYyAxMDAlKTsKICAgICAgICAgICAgYm9yZGVyOiAxcHggc29saWQgcmdiYSg3
MCwgODQsIDEyMCwgLjEpOwogICAgICAgICAgICBib3JkZXItcmFkaXVzOiAxMnB4OwogICAgICAgICAg
ICBib3gtc2hhZG93OgogICAgICAgICAgICAgICAgMCA0cHggNnB4IHJnYmEoMzAsIDQwLCA3MCwgLjA0
KSwKICAgICAgICAgICAgICAgIDAgMTRweCAzNnB4IHJnYmEoMzAsIDQwLCA3MCwgLjE2KTsKICAgICAg
ICAgICAgY29sb3I6IHZhcigtLXR4dCk7CiAgICAgICAgICAgIHBvaW50ZXItZXZlbnRzOiBhdXRvOwog
ICAgICAgICAgICBvcGFjaXR5OiAwOwogICAgICAgICAgICB0cmFuc2Zvcm06IHRyYW5zbGF0ZVkoNHB4
KSBzY2FsZSguOTgpOwogICAgICAgICAgICB0cmFuc2l0aW9uOiBvcGFjaXR5IC4xNHMgZWFzZSwgdHJh
bnNmb3JtIC4xNHMgZWFzZTsKICAgICAgICAgICAgLXdlYmtpdC1hcHAtcmVnaW9uOiBuby1kcmFnOyBh
cHAtcmVnaW9uOiBuby1kcmFnOwogICAgICAgIH0KICAgICAgICAjcGF0aC10aXAub24gewogICAgICAg
ICAgICBkaXNwbGF5OiBibG9jazsKICAgICAgICAgICAgb3BhY2l0eTogMTsKICAgICAgICAgICAgdHJh
bnNmb3JtOiB0cmFuc2xhdGVZKDApIHNjYWxlKDEpOwogICAgICAgIH0KICAgICAgICAucHQtaGVhZCB7
CiAgICAgICAgICAgIGRpc3BsYXk6IGZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGp1c3RpZnktY29u
dGVudDogc3BhY2UtYmV0d2VlbjsKICAgICAgICAgICAgZ2FwOiAxMHB4OyBwYWRkaW5nOiAxMHB4IDEy
cHggOHB4OwogICAgICAgICAgICBib3JkZXItYm90dG9tOiAxcHggc29saWQgcmdiYSg3MCwgODQsIDEy
MCwgLjA3KTsKICAgICAgICB9CiAgICAgICAgLnB0LXRpdGxlIHsKICAgICAgICAgICAgZm9udC1zaXpl
OiAxMXB4OyBmb250LXdlaWdodDogNzAwOyBsZXR0ZXItc3BhY2luZzogLjA0ZW07CiAgICAgICAgICAg
IGNvbG9yOiB2YXIoLS10eHQyKTsgdGV4dC10cmFuc2Zvcm06IHVwcGVyY2FzZTsKICAgICAgICAgICAg
ZmxleC1zaHJpbms6IDA7CiAgICAgICAgfQogICAgICAgIC5wdC1oZWFkLWJ0biB7CiAgICAgICAgICAg
IGZsZXgtc2hyaW5rOiAwOyBtYXJnaW4tbGVmdDogYXV0bzsKICAgICAgICAgICAgaGVpZ2h0OiAyMnB4
OyBwYWRkaW5nOiAwIDhweDsgZGlzcGxheTogaW5saW5lLWZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7
IGdhcDogNHB4OwogICAgICAgICAgICBib3JkZXI6IDFweCBzb2xpZCByZ2JhKDEwNywxMTIsMTI4LC4y
Mik7IGJvcmRlci1yYWRpdXM6IDZweDsgY3Vyc29yOiBwb2ludGVyOwogICAgICAgICAgICBiYWNrZ3Jv
dW5kOiByZ2JhKDEwNywxMTIsMTI4LC4wNik7IGNvbG9yOiAjOGE5MGEwOyBmb250LXNpemU6IDExcHg7
IGZvbnQtd2VpZ2h0OiA2MDA7CiAgICAgICAgICAgIHdoaXRlLXNwYWNlOiBub3dyYXA7CiAgICAgICAg
ICAgIC13ZWJraXQtYXBwLXJlZ2lvbjogbm8tZHJhZzsgYXBwLXJlZ2lvbjogbm8tZHJhZzsKICAgICAg
ICAgICAgdHJhbnNpdGlvbjogYmFja2dyb3VuZCB2YXIoLS10ciksIGNvbG9yIHZhcigtLXRyKSwgYm9y
ZGVyLWNvbG9yIHZhcigtLXRyKTsKICAgICAgICB9CiAgICAgICAgLnB0LWhlYWQtYnRuOmhvdmVyIHsK
ICAgICAgICAgICAgYmFja2dyb3VuZDogcmdiYSgxMDcsMTEyLDEyOCwuMTIpOyBjb2xvcjogdmFyKC0t
dHh0Mik7CiAgICAgICAgICAgIGJvcmRlci1jb2xvcjogcmdiYSgxMDcsMTEyLDEyOCwuNCk7CiAgICAg
ICAgfQogICAgICAgIC5wdC1saXN0IHsgcGFkZGluZzogNnB4IDhweCA4cHg7IGRpc3BsYXk6IGZsZXg7
IGZsZXgtZGlyZWN0aW9uOiBjb2x1bW47IGdhcDogNHB4OyB9CiAgICAgICAgLnB0LXJvdyB7CiAgICAg
ICAgICAgIGRpc3BsYXk6IGdyaWQ7IGdyaWQtdGVtcGxhdGUtY29sdW1uczogOHB4IDFmcjsgZ2FwOiA4
cHg7CiAgICAgICAgICAgIHBhZGRpbmc6IDhweCA4cHg7IGJvcmRlci1yYWRpdXM6IDhweDsKICAgICAg
ICAgICAgYmFja2dyb3VuZDogcmdiYSgyNTUsMjU1LDI1NSwuNyk7CiAgICAgICAgfQogICAgICAgIC5w
dC1yb3cuZGVhZCB7IGJhY2tncm91bmQ6IHJnYmEoMjU1LCAxMjMsIDE1NiwgLjA2KTsgfQogICAgICAg
IC5wdC1kb3QgewogICAgICAgICAgICB3aWR0aDogOHB4OyBoZWlnaHQ6IDhweDsgYm9yZGVyLXJhZGl1
czogNTAlOyBtYXJnaW4tdG9wOiA1cHg7CiAgICAgICAgICAgIGJhY2tncm91bmQ6ICMyZWI0Nzg7IGJv
eC1zaGFkb3c6IDAgMCAwIDNweCByZ2JhKDQ2LCAxODAsIDEyMCwgLjE4KTsKICAgICAgICB9CiAgICAg
ICAgLnB0LXJvdy5kZWFkIC5wdC1kb3QgewogICAgICAgICAgICBiYWNrZ3JvdW5kOiAjZTg1YTdhOyBi
b3gtc2hhZG93OiAwIDAgMCAzcHggcmdiYSgyMzIsIDkwLCAxMjIsIC4xNik7CiAgICAgICAgfQogICAg
ICAgIC5wdC1uYW1lIHsKICAgICAgICAgICAgZm9udC1zaXplOiAxMnB4OyBmb250LXdlaWdodDogNjUw
OyBjb2xvcjogdmFyKC0tdHh0KTsKICAgICAgICAgICAgbGluZS1oZWlnaHQ6IDEuMzsgd29yZC1icmVh
azogYnJlYWstYWxsOwogICAgICAgIH0KICAgICAgICAucHQtcGF0aCB7CiAgICAgICAgICAgIG1hcmdp
bi10b3A6IDNweDsKICAgICAgICAgICAgZm9udDogMTAuNXB4LzEuNDUgJ0Nhc2NhZGlhIE1vbm8nLCdD
b25zb2xhcycsJ01pY3Jvc29mdCBZYUhlaSBVSScsbW9ub3NwYWNlOwogICAgICAgICAgICBjb2xvcjog
dmFyKC0tdHh0Mik7IHdvcmQtYnJlYWs6IGJyZWFrLWFsbDsKICAgICAgICAgICAgdXNlci1zZWxlY3Q6
IHRleHQ7CiAgICAgICAgfQogICAgICAgIC5wdC1wYXRoLmxpdmUgewogICAgICAgICAgICBjb2xvcjog
dmFyKC0tYWNjKTsgY3Vyc29yOiBwb2ludGVyOwogICAgICAgIH0KICAgICAgICAucHQtcGF0aC5saXZl
OmhvdmVyIHsgdGV4dC1kZWNvcmF0aW9uOiB1bmRlcmxpbmU7IH0KICAgICAgICAucHQtcGF0aC5kZWFk
IHsKICAgICAgICAgICAgY29sb3I6ICNjNDNkNWM7CiAgICAgICAgICAgIHRleHQtZGVjb3JhdGlvbjog
bGluZS10aHJvdWdoOwogICAgICAgICAgICB0ZXh0LWRlY29yYXRpb24tdGhpY2tuZXNzOiAycHg7CiAg
ICAgICAgICAgIHRleHQtZGVjb3JhdGlvbi1jb2xvcjogI2UxMWQ0ODsKICAgICAgICAgICAgY3Vyc29y
OiBkZWZhdWx0OwogICAgICAgIH0KICAgICAgICAucHQtYWN0aW9ucyB7CiAgICAgICAgICAgIG1hcmdp
bi10b3A6IDZweDsKICAgICAgICAgICAgZGlzcGxheTogZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsg
Z2FwOiA2cHg7IGZsZXgtd3JhcDogd3JhcDsKICAgICAgICB9CiAgICAgICAgLnB0LWNvcHktYnRuIHsK
ICAgICAgICAgICAgaGVpZ2h0OiAyMnB4OyBwYWRkaW5nOiAwIDhweDsgZGlzcGxheTogaW5saW5lLWZs
ZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7CiAgICAgICAgICAgIGJvcmRlcjogMXB4IHNvbGlkIHJnYmEo
MTA3LDExMiwxMjgsLjIyKTsgYm9yZGVyLXJhZGl1czogNnB4OyBjdXJzb3I6IHBvaW50ZXI7CiAgICAg
ICAgICAgIGJhY2tncm91bmQ6IHJnYmEoMTA3LDExMiwxMjgsLjA2KTsgY29sb3I6ICM4YTkwYTA7IGZv
bnQtc2l6ZTogMTFweDsgZm9udC13ZWlnaHQ6IDYwMDsKICAgICAgICAgICAgLXdlYmtpdC1hcHAtcmVn
aW9uOiBuby1kcmFnOyBhcHAtcmVnaW9uOiBuby1kcmFnOwogICAgICAgICAgICB0cmFuc2l0aW9uOiBi
YWNrZ3JvdW5kIHZhcigtLXRyKSwgY29sb3IgdmFyKC0tdHIpLCBib3JkZXItY29sb3IgdmFyKC0tdHIp
OwogICAgICAgIH0KICAgICAgICAucHQtY29weS1idG46aG92ZXIgewogICAgICAgICAgICBiYWNrZ3Jv
dW5kOiByZ2JhKDEwNywxMTIsMTI4LC4xMik7IGNvbG9yOiB2YXIoLS10eHQyKTsKICAgICAgICAgICAg
Ym9yZGVyLWNvbG9yOiByZ2JhKDEwNywxMTIsMTI4LC40KTsKICAgICAgICB9CiAgICAgICAgLnB0LWNv
cHktYnRuLm9rIHsKICAgICAgICAgICAgY29sb3I6ICMxZjdhNTU7IGJvcmRlci1jb2xvcjogcmdiYSg0
NiwgMTgwLCAxMjAsIC4zNSk7CiAgICAgICAgICAgIGJhY2tncm91bmQ6IHJnYmEoNDYsIDE4MCwgMTIw
LCAuMSk7CiAgICAgICAgfQogICAgICAgIC5pdG0uaXQtZ3JvdXAgewogICAgICAgICAgICBmbGV4LWRp
cmVjdGlvbjogY29sdW1uOwogICAgICAgICAgICBhbGlnbi1pdGVtczogc3RyZXRjaDsKICAgICAgICAg
ICAgZ2FwOiAwOwogICAgICAgICAgICBwYWRkaW5nOiA2cHggOHB4IDRweDsKICAgICAgICAgICAgY3Vy
c29yOiBkZWZhdWx0OwogICAgICAgIH0KICAgICAgICAuaXRtLml0LWdyb3VwOmhvdmVyIHsgYmFja2dy
b3VuZDogdmFyKC0tY2FyZCk7IH0KICAgICAgICAubWctaGVhZCB7CiAgICAgICAgICAgIGRpc3BsYXk6
IGZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGdhcDogNnB4OwogICAgICAgICAgICBmb250LXNpemU6
IDExcHg7IGNvbG9yOiB2YXIoLS10eHQzKTsgZm9udC13ZWlnaHQ6IDYwMDsKICAgICAgICAgICAgcGFk
ZGluZzogMnB4IDJweCA2cHg7IHVzZXItc2VsZWN0OiBub25lOwogICAgICAgIH0KICAgICAgICAubWct
aGVhZCAubWctdGFnIHsKICAgICAgICAgICAgZGlzcGxheTogaW5saW5lLWZsZXg7IGFsaWduLWl0ZW1z
OiBjZW50ZXI7CiAgICAgICAgICAgIGhlaWdodDogMTZweDsgcGFkZGluZzogMCA2cHg7IGJvcmRlci1y
YWRpdXM6IDhweDsKICAgICAgICAgICAgYmFja2dyb3VuZDogcmdiYSg5MSwxMTUsMjMyLC4xMik7IGNv
bG9yOiB2YXIoLS1hY2MpOyBmb250LXNpemU6IDEwcHg7CiAgICAgICAgfQogICAgICAgIC5tZy1yb3cg
ewogICAgICAgICAgICBwYWRkaW5nOiA3cHggNnB4OyBtYXJnaW4tYm90dG9tOiAzcHg7CiAgICAgICAg
ICAgIGJvcmRlci1yYWRpdXM6IDVweDsgY3Vyc29yOiBwb2ludGVyOwogICAgICAgICAgICBib3JkZXI6
IDFweCBzb2xpZCB0cmFuc3BhcmVudDsKICAgICAgICAgICAgdHJhbnNpdGlvbjogYmFja2dyb3VuZCAu
MTJzIGVhc2UsIGJvcmRlci1jb2xvciAuMTJzIGVhc2U7CiAgICAgICAgfQogICAgICAgIC5tZy1yb3c6
aG92ZXIgeyBiYWNrZ3JvdW5kOiB2YXIoLS1jYXJkLWgpOyB9CiAgICAgICAgLm1nLXJvdy5zZWwgewog
ICAgICAgICAgICBiYWNrZ3JvdW5kOiAjZWRmMWZmOwogICAgICAgICAgICBib3JkZXItY29sb3I6IHJn
YmEoOTEsMTE1LDIzMiwuMzUpOwogICAgICAgICAgICBib3gtc2hhZG93OiAwIDAgMCAxcHggcmdiYSg5
MSwxMTUsMjMyLC4yNSk7CiAgICAgICAgfQogICAgICAgIC5tZy1yb3cubXVsdGkgewogICAgICAgICAg
ICBiYWNrZ3JvdW5kOiAjZWVmMmZmOwogICAgICAgICAgICBib3JkZXItY29sb3I6IHJnYmEoOTEsMTE1
LDIzMiwuNDUpOwogICAgICAgIH0KICAgICAgICAubWctdGl0bGUgewogICAgICAgICAgICBmb250LXNp
emU6IDEzcHg7IGZvbnQtd2VpZ2h0OiA2MDA7IGNvbG9yOiB2YXIoLS1hY2MpOwogICAgICAgICAgICBt
YXJnaW4tYm90dG9tOiAycHg7IGxpbmUtaGVpZ2h0OiAxLjM1OwogICAgICAgICAgICBkaXNwbGF5OiAt
d2Via2l0LWJveDsgLXdlYmtpdC1ib3gtb3JpZW50OiB2ZXJ0aWNhbDsgLXdlYmtpdC1saW5lLWNsYW1w
OiAyOwogICAgICAgICAgICBvdmVyZmxvdzogaGlkZGVuOyB3b3JkLWJyZWFrOiBicmVhay13b3JkOwog
ICAgICAgIH0KICAgICAgICAubWctYm9keSB7CiAgICAgICAgICAgIGZvbnQtc2l6ZTogMTIuNXB4OyBm
b250LXdlaWdodDogNTAwOyBjb2xvcjogdmFyKC0tdHh0KTsKICAgICAgICAgICAgd2hpdGUtc3BhY2U6
IHByZS13cmFwOyB3b3JkLWJyZWFrOiBicmVhay1hbGw7CiAgICAgICAgICAgIGRpc3BsYXk6IC13ZWJr
aXQtYm94OyAtd2Via2l0LWJveC1vcmllbnQ6IHZlcnRpY2FsOyAtd2Via2l0LWxpbmUtY2xhbXA6IDQ7
CiAgICAgICAgICAgIG92ZXJmbG93OiBoaWRkZW47IGxpbmUtaGVpZ2h0OiAxLjQ7CiAgICAgICAgfQog
ICAgICAgIC5tZy1ib2R5LmltZyB7IGNvbG9yOiB2YXIoLS10eHQyKTsgfQogICAgICAgIC5tZy1yb3ct
dG9wIHsKICAgICAgICAgICAgZGlzcGxheTogZmxleDsgYWxpZ24taXRlbXM6IGZsZXgtc3RhcnQ7IGdh
cDogOHB4OwogICAgICAgIH0KICAgICAgICAubWctcm93LW1haW4geyBmbGV4OiAxOyBtaW4td2lkdGg6
IDA7IH0KICAgICAgICAubWctc3JjIHsKICAgICAgICAgICAgd2lkdGg6IDE4cHg7IGhlaWdodDogMThw
eDsgZmxleC1zaHJpbms6IDA7IG1hcmdpbi10b3A6IDJweDsKICAgICAgICAgICAgYm9yZGVyLXJhZGl1
czogM3B4OyBvYmplY3QtZml0OiBjb250YWluOwogICAgICAgICAgICBiYWNrZ3JvdW5kOiByZ2JhKDAs
MCwwLC4wNCk7CiAgICAgICAgfQogICAgICAgIC5pLWZhdi10aXRsZSB7CiAgICAgICAgICAgIGZvbnQt
c2l6ZTogMTNweDsgZm9udC13ZWlnaHQ6IDYwMDsgY29sb3I6IHZhcigtLWFjYyk7CiAgICAgICAgICAg
IG1hcmdpbjogMCAwIDNweDsgbGluZS1oZWlnaHQ6IDEuMzU7CiAgICAgICAgICAgIGRpc3BsYXk6IC13
ZWJraXQtYm94OyAtd2Via2l0LWJveC1vcmllbnQ6IHZlcnRpY2FsOyAtd2Via2l0LWxpbmUtY2xhbXA6
IDI7CiAgICAgICAgICAgIG92ZXJmbG93OiBoaWRkZW47IHdvcmQtYnJlYWs6IGJyZWFrLXdvcmQ7CiAg
ICAgICAgfQogICAgICAgICN0aXRsZS1kbGcgewogICAgICAgICAgICBkaXNwbGF5OiBub25lOyBwb3Np
dGlvbjogZml4ZWQ7IGluc2V0OiAwOyB6LWluZGV4OiAxMDA7CiAgICAgICAgICAgIGJhY2tncm91bmQ6
IHJnYmEoMTUsMTgsMjgsLjM1KTsKICAgICAgICAgICAgYWxpZ24taXRlbXM6IGNlbnRlcjsganVzdGlm
eS1jb250ZW50OiBjZW50ZXI7CiAgICAgICAgfQogICAgICAgICN0aXRsZS1kbGcub24geyBkaXNwbGF5
OiBmbGV4OyB9CiAgICAgICAgI3RpdGxlLWRsZyAudGl0bGUtYm94IHsKICAgICAgICAgICAgd2lkdGg6
IDI2MHB4OyBwYWRkaW5nOiAxNnB4IDE2cHggMTJweDsKICAgICAgICAgICAgYmFja2dyb3VuZDogdmFy
KC0tY2FyZCk7IGJvcmRlci1yYWRpdXM6IDEwcHg7CiAgICAgICAgICAgIGJveC1zaGFkb3c6IDAgOHB4
IDI4cHggcmdiYSgwLDAsMCwuMTgpOwogICAgICAgIH0KICAgICAgICAjdGl0bGUtaW5wdXQgewogICAg
ICAgICAgICB3aWR0aDogMTAwJTsgYm94LXNpemluZzogYm9yZGVyLWJveDsgbWFyZ2luOiA4cHggMCAx
MnB4OwogICAgICAgICAgICBoZWlnaHQ6IDMycHg7IHBhZGRpbmc6IDAgMTBweDsgYm9yZGVyLXJhZGl1
czogNnB4OwogICAgICAgICAgICBib3JkZXI6IDFweCBzb2xpZCAjZDVkYWU2OyBiYWNrZ3JvdW5kOiAj
ZmZmOyBjb2xvcjogdmFyKC0tdHh0KTsKICAgICAgICAgICAgZm9udC1zaXplOiAxM3B4OyBvdXRsaW5l
OiBub25lOwogICAgICAgIH0KICAgICAgICAjdGl0bGUtaW5wdXQ6Zm9jdXMgeyBib3JkZXItY29sb3I6
IHZhcigtLWFjYyk7IH0KCiAgICAKICAgICAgICAvKiB1aS1ncmF5LWJnLXYxICovCiAgICAgICAgOnJv
b3QgewogICAgICAgICAgICAtLWJnOiAjZTRlN2VlICFpbXBvcnRhbnQ7CiAgICAgICAgfQogICAgICAg
IGh0bWwsIGJvZHkgewogICAgICAgICAgICBiYWNrZ3JvdW5kOiAjZTRlN2VlICFpbXBvcnRhbnQ7CiAg
ICAgICAgfQogICAgICAgICNhcHAgewogICAgICAgICAgICBiYWNrZ3JvdW5kOiBsaW5lYXItZ3JhZGll
bnQoMTgwZGVnLCAjZTllY2YzIDAlLCAjZTBlNGVjIDEwMCUpICFpbXBvcnRhbnQ7CiAgICAgICAgfQog
ICAgICAgICNoZHIgewogICAgICAgICAgICBiYWNrZ3JvdW5kOiAjZTJlNmVlICFpbXBvcnRhbnQ7CiAg
ICAgICAgfQogICAgICAgICN0YWJzIHsKICAgICAgICAgICAgYmFja2dyb3VuZDogI2UyZTZlZSAhaW1w
b3J0YW50OwogICAgICAgIH0KICAgICAgICAjbGlzdCwgI2VtcHR5LCAjc2tlbCwgI2hkci1ncm93LCAj
c2VhcmNoLXdyYXAgewogICAgICAgICAgICBiYWNrZ3JvdW5kOiB0cmFuc3BhcmVudCAhaW1wb3J0YW50
OwogICAgICAgIH0KICAgICAgICAjc2VhcmNoLWJveCB7CiAgICAgICAgICAgIHRyYW5zZm9ybS1vcmln
aW46IHJpZ2h0IGNlbnRlcjsKICAgICAgICAgICAgYmFja2dyb3VuZDogdHJhbnNwYXJlbnQgIWltcG9y
dGFudDsKICAgICAgICB9CiAgICAgICAgLml0bSwgLm1nLCAubWctcm93LCAubWVyZ2UtZ3JvdXAgewog
ICAgICAgICAgICBiYWNrZ3JvdW5kOiAjZmZmZmZmICFpbXBvcnRhbnQ7CiAgICAgICAgfQogICAgICAg
IC5pdG06aG92ZXIgewogICAgICAgICAgICBiYWNrZ3JvdW5kOiAjZjhmOWZjICFpbXBvcnRhbnQ7CiAg
ICAgICAgfQogICAgCiAgICAgICAgLyogc2VsLXRpbnQtYmx1ZS12MSAqLwogICAgICAgIC5pdG0uc2Vs
LAogICAgICAgIC5tZy1yb3cuc2VsLAogICAgICAgIC5pdG0ubXVsdGksCiAgICAgICAgLm1nLXJvdy5t
dWx0aSwKICAgICAgICAuaXRtLm11bHRpLnNlbCwKICAgICAgICAuaXQtZ3JvdXAuc2VsLAogICAgICAg
IC5pdC1ncm91cC5tdWx0aSB7CiAgICAgICAgICAgIGJhY2tncm91bmQ6ICNlOGVmZmYgIWltcG9ydGFu
dDsKICAgICAgICB9CiAgICAgICAgLml0bS5zZWw6aG92ZXIsCiAgICAgICAgLml0bS5tdWx0aTpob3Zl
ciwKICAgICAgICAubWctcm93LnNlbDpob3ZlciwKICAgICAgICAubWctcm93Lm11bHRpOmhvdmVyIHsK
ICAgICAgICAgICAgYmFja2dyb3VuZDogI2RkZTZmZiAhaW1wb3J0YW50OwogICAgICAgIH0KICAgIAog
ICAgICAgIC8qIGhvdmVyLWdyZWVuLXJpc2UtdjIgKi8KICAgICAgICAvKiBob3Zlci1hY2NlbnQtcmlz
ZS12MyAqLwogICAgICAgIC5pdG0geyBwb3NpdGlvbjogcmVsYXRpdmUgIWltcG9ydGFudDsgb3ZlcmZs
b3c6IGhpZGRlbiAhaW1wb3J0YW50OyB9CiAgICAgICAgLml0bTo6YmVmb3JlIHsKICAgICAgICAgICAg
Y29udGVudDogIiIgIWltcG9ydGFudDsKICAgICAgICAgICAgcG9zaXRpb246IGFic29sdXRlICFpbXBv
cnRhbnQ7CiAgICAgICAgICAgIGxlZnQ6IDAgIWltcG9ydGFudDsgcmlnaHQ6IDAgIWltcG9ydGFudDsg
Ym90dG9tOiAwICFpbXBvcnRhbnQ7CiAgICAgICAgICAgIGhlaWdodDogMCAhaW1wb3J0YW50OwogICAg
ICAgICAgICBwb2ludGVyLWV2ZW50czogbm9uZSAhaW1wb3J0YW50OwogICAgICAgICAgICB6LWluZGV4
OiAwICFpbXBvcnRhbnQ7CiAgICAgICAgICAgIGJvcmRlci1yYWRpdXM6IDAgMCB2YXIoLS1yLCA0cHgp
IHZhcigtLXIsIDRweCkgIWltcG9ydGFudDsKICAgICAgICAgICAgYmFja2dyb3VuZDogbGluZWFyLWdy
YWRpZW50KHRvIHRvcCwKICAgICAgICAgICAgICAgIHJnYmEoOTEsIDExNSwgMjMyLCAuMzIpIDAlLAog
ICAgICAgICAgICAgICAgcmdiYSg5MSwgMTE1LCAyMzIsIC4xMikgNTUlLAogICAgICAgICAgICAgICAg
cmdiYSg5MSwgMTE1LCAyMzIsIDApIDEwMCUpICFpbXBvcnRhbnQ7CiAgICAgICAgICAgIHRyYW5zaXRp
b246IGhlaWdodCAuMzRzIGN1YmljLWJlemllciguMjIsIDEsIC4zNiwgMSkgIWltcG9ydGFudDsKICAg
ICAgICB9CiAgICAgICAgLml0bTpob3Zlcjo6YmVmb3JlIHsgaGVpZ2h0OiAzMy4zMzMlICFpbXBvcnRh
bnQ7IH0KICAgICAgICAuaXRtOjphZnRlciB7CiAgICAgICAgICAgIGNvbnRlbnQ6ICIiICFpbXBvcnRh
bnQ7CiAgICAgICAgICAgIHBvc2l0aW9uOiBhYnNvbHV0ZSAhaW1wb3J0YW50OwogICAgICAgICAgICBs
ZWZ0OiAwICFpbXBvcnRhbnQ7IHJpZ2h0OiAwICFpbXBvcnRhbnQ7IGJvdHRvbTogMCAhaW1wb3J0YW50
OwogICAgICAgICAgICBoZWlnaHQ6IDJweCAhaW1wb3J0YW50OwogICAgICAgICAgICBwb2ludGVyLWV2
ZW50czogbm9uZSAhaW1wb3J0YW50OwogICAgICAgICAgICB6LWluZGV4OiAxICFpbXBvcnRhbnQ7CiAg
ICAgICAgICAgIGJhY2tncm91bmQ6IHJnYmEoOTEsIDExNSwgMjMyLCAuOTIpICFpbXBvcnRhbnQ7CiAg
ICAgICAgICAgIGJvcmRlci1yYWRpdXM6IDFweCAhaW1wb3J0YW50OwogICAgICAgICAgICB0cmFuc2Zv
cm06IHNjYWxlWCgwKSAhaW1wb3J0YW50OwogICAgICAgICAgICB0cmFuc2Zvcm0tb3JpZ2luOiBjZW50
ZXIgIWltcG9ydGFudDsKICAgICAgICAgICAgdHJhbnNpdGlvbjogdHJhbnNmb3JtIC4zcyBjdWJpYy1i
ZXppZXIoLjIyLCAxLCAuMzYsIDEpICFpbXBvcnRhbnQ7CiAgICAgICAgfQogICAgICAgIC5pdG06aG92
ZXI6OmFmdGVyIHsKICAgICAgICAgICAgdHJhbnNmb3JtOiBzY2FsZVgoMSkgIWltcG9ydGFudDsKICAg
ICAgICAgICAgYmFja2dyb3VuZDogcmdiYSg5MSwgMTE1LCAyMzIsIC45NSkgIWltcG9ydGFudDsKICAg
ICAgICB9CiAgICAgICAgLml0bSA+ICogeyBwb3NpdGlvbjogcmVsYXRpdmU7IHotaW5kZXg6IDI7IH0K
ICAgICAgICAvKiDljrvmjonpnaLmnb/mnIDlpJbmj4/ovrnvvJvmnaHnm67ljaHniYfovbvmgqzmta7l
jprluqYgKi8KICAgICAgICBodG1sLCBib2R5LCAjYXBwIHsKICAgICAgICAgICAgYm9yZGVyOiBub25l
ICFpbXBvcnRhbnQ7CiAgICAgICAgICAgIG91dGxpbmU6IG5vbmUgIWltcG9ydGFudDsKICAgICAgICAg
ICAgYm94LXNoYWRvdzogbm9uZSAhaW1wb3J0YW50OwogICAgICAgIH0KICAgICAgICAjYXBwIHsKICAg
ICAgICAgICAgYm9yZGVyLXJhZGl1czogMCAhaW1wb3J0YW50OwogICAgICAgICAgICBib3gtc2l6aW5n
OiBib3JkZXItYm94ICFpbXBvcnRhbnQ7CiAgICAgICAgICAgIG92ZXJmbG93OiBoaWRkZW4gIWltcG9y
dGFudDsKICAgICAgICB9CiAgICAgICAgLml0bSwgLm1nLCAubWVyZ2UtZ3JvdXAgewogICAgICAgICAg
ICBib3JkZXI6IG5vbmUgIWltcG9ydGFudDsKICAgICAgICAgICAgYm9yZGVyLXJhZGl1czogNHB4ICFp
bXBvcnRhbnQ7CiAgICAgICAgICAgIGJveC1zaGFkb3c6CiAgICAgICAgICAgICAgICAwIDFweCAycHgg
cmdiYSgyNCwgMzIsIDU2LCAuMDUpLAogICAgICAgICAgICAgICAgMCAzcHggMTBweCByZ2JhKDI0LCAz
MiwgNTYsIC4wOSkgIWltcG9ydGFudDsKICAgICAgICB9CiAgICAgICAgLml0bTpob3ZlciwgLm1nOmhv
dmVyLCAubWVyZ2UtZ3JvdXA6aG92ZXIgewogICAgICAgICAgICBib3gtc2hhZG93OgogICAgICAgICAg
ICAgICAgMCAycHggNHB4IHJnYmEoMjQsIDMyLCA1NiwgLjA3KSwKICAgICAgICAgICAgICAgIDAgNnB4
IDE2cHggcmdiYSgyNCwgMzIsIDU2LCAuMTMpICFpbXBvcnRhbnQ7CiAgICAgICAgfQogICAgICAgIC5p
dG0uc2VsLAogICAgICAgIC5tZy1yb3cuc2VsLAogICAgICAgIC5pdG0ubXVsdGksCiAgICAgICAgLm1n
LXJvdy5tdWx0aSwKICAgICAgICAuaXRtLm11bHRpLnNlbCwKICAgICAgICAuaXQtZ3JvdXAuc2VsLAog
ICAgICAgIC5pdC1ncm91cC5tdWx0aSB7CiAgICAgICAgICAgIGJveC1zaGFkb3c6CiAgICAgICAgICAg
ICAgICAwIDAgMCAycHggcmdiYSg5MSwgMTE1LCAyMzIsIC40MiksCiAgICAgICAgICAgICAgICAwIDJw
eCA0cHggcmdiYSg5MSwgMTE1LCAyMzIsIC4xMCksCiAgICAgICAgICAgICAgICAwIDZweCAxNHB4IHJn
YmEoOTEsIDExNSwgMjMyLCAuMTYpICFpbXBvcnRhbnQ7CiAgICAgICAgfQogICAgPC9zdHlsZT4KPC9o
ZWFkPgo8Ym9keSBkYXRhLXVpLWJ1aWxkPSIyMDI2MDkwNy0yMzA3Ij4KPGRpdiBpZD0iYXBwIiBkYXRh
LXVpLXZlcj0iMjAyNjA5MDgtc2VwLXNpbmdsZSI+CiAgICA8ZGl2IGlkPSJoZHIiPgogICAgICAgIDxk
aXYgaWQ9ImhlYXJ0Ij4KICAgICAgICAgICAgPHN2ZyB2aWV3Qm94PSIwIDAgMjQgMjQiIGZpbGw9Im5v
bmUiIHN0cm9rZT0iY3VycmVudENvbG9yIiBzdHJva2Utd2lkdGg9IjEuOCIKICAgICAgICAgICAgICAg
ICBzdHJva2UtbGluZWNhcD0icm91bmQiIHN0cm9rZS1saW5lam9pbj0icm91bmQiPgogICAgICAgICAg
ICAgICAgPHJlY3QgeD0iOSIgeT0iMiIgd2lkdGg9IjYiIGhlaWdodD0iNCIgcng9IjEiLz4KICAgICAg
ICAgICAgICAgIDxwYXRoIGQ9Ik0xNiA0aDJhMiAyIDAgMCAxIDIgMnYxNGEyIDIgMCAwIDEtMiAySDZh
MiAyIDAgMCAxLTItMlY2YTIgMiAwIDAgMSAyLTJoMiIvPgogICAgICAgICAgICAgICAgPHBhdGggZD0i
TTkgMTJoNk05IDE2aDQiLz4KICAgICAgICAgICAgPC9zdmc+CiAgICAgICAgPC9kaXY+CiAgICAgICAg
PGRpdiBpZD0iaGRyLWdyb3ciPjwvZGl2PgogICAgICAgIDxkaXYgaWQ9Im11bHRpLWJhciI+CiAgICAg
ICAgICAgIDxidXR0b24gaWQ9Im11bHRpLXNlbCIgdHlwZT0iYnV0dG9uIiB0aXRsZT0i5Y+W5raI5aSa
6YCJIj4KICAgICAgICAgICAgICAgIDxzcGFuIGlkPSJtdWx0aS1zZWwtbGFiIj7lt7LpgIk8L3NwYW4+
CiAgICAgICAgICAgICAgICA8c3BhbiBpZD0ibXVsdGktY250Ij4wPC9zcGFuPgogICAgICAgICAgICA8
L2J1dHRvbj4KICAgICAgICAgICAgPGRpdiBpZD0icGFzdGUtc2VwLXdyYXAiPgogICAgICAgICAgICAg
ICAgPGJ1dHRvbiBpZD0icGFzdGUtc2VwLWJ0biIgdHlwZT0iYnV0dG9uIiB0aXRsZT0i57KY6LS05YiG
6ZqU56ym77yI54K56YCJ55So5bm257KY6LS077yJIj4KICAgICAgICAgICAgICAgICAgICA8c3BhbiBp
ZD0icGFzdGUtc2VwLWxhYmVsIj7ikKM8L3NwYW4+CiAgICAgICAgICAgICAgICA8L2J1dHRvbj4KICAg
ICAgICAgICAgICAgIDxkaXYgaWQ9InBhc3RlLXNlcC1tZW51Ij48L2Rpdj4KICAgICAgICAgICAgPC9k
aXY+CiAgICAgICAgPC9kaXY+CiAgICAgICAgPGJ1dHRvbiBpZD0iYnRuLWxvY2F0ZSIgdHlwZT0iYnV0
dG9uIiB0aXRsZT0i5a6a5L2N5Yiw5LiK5qyh5L2/55So55qE5p2h55uuIiBkaXNhYmxlZD4KICAgICAg
ICAgICAgPHN2ZyB2aWV3Qm94PSIwIDAgMjQgMjQiIGZpbGw9Im5vbmUiIHN0cm9rZT0iY3VycmVudENv
bG9yIiBzdHJva2Utd2lkdGg9IjIiCiAgICAgICAgICAgICAgICAgc3Ryb2tlLWxpbmVjYXA9InJvdW5k
IiBzdHJva2UtbGluZWpvaW49InJvdW5kIj4KICAgICAgICAgICAgICAgIDxjaXJjbGUgY3g9IjEyIiBj
eT0iMTIiIHI9IjgiLz4KICAgICAgICAgICAgICAgIDxjaXJjbGUgY3g9IjEyIiBjeT0iMTIiIHI9IjMu
NSIvPgogICAgICAgICAgICA8L3N2Zz4KICAgICAgICA8L2J1dHRvbj4KICAgICAgICA8ZGl2IGlkPSJz
ZWFyY2gtd3JhcCI+CiAgICAgICAgICAgIDxidXR0b24gaWQ9ImJ0bi1zZWFyY2giIHR5cGU9ImJ1dHRv
biIgdGl0bGU9IuaQnOe0oiI+CiAgICAgICAgICAgICAgICA8c3ZnIHZpZXdCb3g9IjAgMCAyNCAyNCIg
ZmlsbD0ibm9uZSIgc3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0cm9rZS13aWR0aD0iMiIKICAgICAgICAg
ICAgICAgICAgICAgc3Ryb2tlLWxpbmVjYXA9InJvdW5kIiBzdHJva2UtbGluZWpvaW49InJvdW5kIj4K
ICAgICAgICAgICAgICAgICAgICA8Y2lyY2xlIGN4PSIxMSIgY3k9IjExIiByPSI3Ii8+CiAgICAgICAg
ICAgICAgICAgICAgPHBhdGggZD0iTTIwIDIwbC0zLjUtMy41Ii8+CiAgICAgICAgICAgICAgICA8L3N2
Zz4KICAgICAgICAgICAgPC9idXR0b24+CiAgICAgICAgICAgIDxkaXYgaWQ9InNlYXJjaC1ib3giPgog
ICAgICAgICAgICAgICAgPGJ1dHRvbiBpZD0iYnRuLXRvZGF5IiB0eXBlPSJidXR0b24iPuW9k+WkqTwv
YnV0dG9uPgogICAgICAgICAgICAgICAgPGlucHV0IGlkPSJzZWFyY2giIHR5cGU9InRleHQiIHBsYWNl
aG9sZGVyPSLmkJzntKLigKYg56m65qC85YiG6K+N6aG75ZCM5pe25YyF5ZCrIMK3IGF8YiDliIbmrrUi
IGF1dG9jb21wbGV0ZT0ib2ZmIiBzcGVsbGNoZWNrPSJmYWxzZSI+CiAgICAgICAgICAgICAgICA8YnV0
dG9uIGlkPSJzZWFyY2gtY2xyIiB0eXBlPSJidXR0b24iPuKclTwvYnV0dG9uPgogICAgICAgICAgICA8
L2Rpdj4KICAgICAgICA8L2Rpdj4KICAgICAgICA8YnV0dG9uIGlkPSJidG4tcGluIiB0eXBlPSJidXR0
b24iIHRpdGxlPSLpkonlnKjlsY/luZXkuIoiPgogICAgICAgICAgICA8c3ZnIHZpZXdCb3g9IjAgMCAy
NCAyNCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0cm9rZS13aWR0aD0iMiIKICAg
ICAgICAgICAgICAgICBzdHJva2UtbGluZWpvaW49InJvdW5kIiBzdHJva2UtbGluZWNhcD0icm91bmQi
PgogICAgICAgICAgICAgICAgPGxpbmUgeDE9IjEyIiB5MT0iMTciIHgyPSIxMiIgeTI9IjIyIi8+CiAg
ICAgICAgICAgICAgICA8cGF0aCBkPSJNNSAxN2gxNHYtMS43NmEyIDIgMCAwIDAtMS4xMS0xLjc5bC0x
Ljc4LS45QTIgMiAwIDAgMSAxNSAxMC43NlY2aDFhMiAyIDAgMCAwIDAtNEg4YTIgMiAwIDAgMCAwIDRo
MXY0Ljc2YTIgMiAwIDAgMS0xLjExIDEuNzlsLTEuNzguOUEyIDIgMCAwIDAgNSAxNS4yNFoiLz4KICAg
ICAgICAgICAgPC9zdmc+CiAgICAgICAgPC9idXR0b24+CiAgICA8L2Rpdj4KCiAgICA8ZGl2IGlkPSJ0
YWJzIj4KICAgICAgICA8ZGl2IGlkPSJ0YWItaW5rIiBhcmlhLWhpZGRlbj0idHJ1ZSI+PC9kaXY+CiAg
ICAgICAgPGRpdiBjbGFzcz0idGFiIG9uIiBkYXRhLXRhYj0iYWxsIj7lhajpg6g8L2Rpdj4KICAgICAg
ICA8ZGl2IGNsYXNzPSJ0YWIiIGRhdGEtdGFiPSJ0ZXh0Ij7mlofmnKw8L2Rpdj4KICAgICAgICA8ZGl2
IGNsYXNzPSJ0YWIiIGRhdGEtdGFiPSJpbWFnZSI+5Zu+5YOPPC9kaXY+CiAgICAgICAgPGRpdiBjbGFz
cz0idGFiIiBkYXRhLXRhYj0iZmlsZSI+5paH5Lu2PC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0idGFi
IiBkYXRhLXRhYj0icmVjZW50Ij7mnIDov5E8L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJ0YWIiIGRh
dGEtdGFiPSJwaW5uZWQiPuaUtuiXjyA8c3BhbiBjbGFzcz0iYmFkZ2UiIGlkPSJwaW4tY250IiBzdHls
ZT0iZGlzcGxheTpub25lIj4wPC9zcGFuPjwvZGl2PgogICAgICAgIDxkaXYgaWQ9InRhYi1hY3Rpb25z
Ij4KICAgICAgICAgICAgPHNwYW4gaWQ9ImJhci10eHQiPjA8L3NwYW4+CiAgICAgICAgICAgIDxidXR0
b24gaWQ9ImJ0bi1jbHIiIHR5cGU9ImJ1dHRvbiIgdGl0bGU9Iua4heepuuWOhuWPsiI+CiAgICAgICAg
ICAgICAgICA8c3ZnIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSJjdXJyZW50
Q29sb3IiIHN0cm9rZS13aWR0aD0iMiIKICAgICAgICAgICAgICAgICAgICAgc3Ryb2tlLWxpbmVjYXA9
InJvdW5kIiBzdHJva2UtbGluZWpvaW49InJvdW5kIj4KICAgICAgICAgICAgICAgICAgICA8cG9seWxp
bmUgcG9pbnRzPSIzIDYgNSA2IDIxIDYiLz4KICAgICAgICAgICAgICAgICAgICA8cGF0aCBkPSJNMTkg
NmwtMSAxNGEyIDIgMCAwIDEtMiAySDhhMiAyIDAgMCAxLTItMkw1IDYiLz4KICAgICAgICAgICAgICAg
ICAgICA8cGF0aCBkPSJNMTAgMTF2Nk0xNCAxMXY2TTkgNlY0aDZ2MiIvPgogICAgICAgICAgICAgICAg
PC9zdmc+CiAgICAgICAgICAgIDwvYnV0dG9uPgogICAgICAgIDwvZGl2PgogICAgPC9kaXY+CgogICAg
PGRpdiBpZD0ibGlzdCI+CiAgICAgICAgPGRpdiBpZD0ic2tlbCIgYXJpYS1oaWRkZW49InRydWUiPgog
ICAgICAgICAgICA8ZGl2IGNsYXNzPSJzay1yb3ciPjxkaXYgY2xhc3M9InNrLWljbyI+PC9kaXY+PGRp
diBjbGFzcz0ic2stYm9keSI+PGRpdiBjbGFzcz0ic2stbGluZSBtaWQiPjwvZGl2PjxkaXYgY2xhc3M9
InNrLWxpbmUgc2hvcnQiPjwvZGl2PjwvZGl2PjwvZGl2PgogICAgICAgICAgICA8ZGl2IGNsYXNzPSJz
ay1yb3ciPjxkaXYgY2xhc3M9InNrLWljbyI+PC9kaXY+PGRpdiBjbGFzcz0ic2stYm9keSI+PGRpdiBj
bGFzcz0ic2stbGluZSI+PC9kaXY+PGRpdiBjbGFzcz0ic2stbGluZSBtaWQiPjwvZGl2PjwvZGl2Pjwv
ZGl2PgogICAgICAgICAgICA8ZGl2IGNsYXNzPSJzay1yb3ciPjxkaXYgY2xhc3M9InNrLWljbyI+PC9k
aXY+PGRpdiBjbGFzcz0ic2stYm9keSI+PGRpdiBjbGFzcz0ic2stbGluZSBtaWQiPjwvZGl2PjxkaXYg
Y2xhc3M9InNrLWxpbmUgc2hvcnQiPjwvZGl2PjwvZGl2PjwvZGl2PgogICAgICAgICAgICA8ZGl2IGNs
YXNzPSJzay1yb3ciPjxkaXYgY2xhc3M9InNrLWljbyI+PC9kaXY+PGRpdiBjbGFzcz0ic2stYm9keSI+
PGRpdiBjbGFzcz0ic2stbGluZSI+PC9kaXY+PGRpdiBjbGFzcz0ic2stbGluZSBtaWQiPjwvZGl2Pjwv
ZGl2PjwvZGl2PgogICAgICAgICAgICA8ZGl2IGNsYXNzPSJzay1yb3ciPjxkaXYgY2xhc3M9InNrLWlj
byI+PC9kaXY+PGRpdiBjbGFzcz0ic2stYm9keSI+PGRpdiBjbGFzcz0ic2stbGluZSBtaWQiPjwvZGl2
PjxkaXYgY2xhc3M9InNrLWxpbmUgc2hvcnQiPjwvZGl2PjwvZGl2PjwvZGl2PgogICAgICAgICAgICA8
ZGl2IGNsYXNzPSJzay1yb3ciPjxkaXYgY2xhc3M9InNrLWljbyI+PC9kaXY+PGRpdiBjbGFzcz0ic2st
Ym9keSI+PGRpdiBjbGFzcz0ic2stbGluZSI+PC9kaXY+PGRpdiBjbGFzcz0ic2stbGluZSBzaG9ydCI+
PC9kaXY+PC9kaXY+PC9kaXY+CiAgICAgICAgPC9kaXY+CiAgICAgICAgPGRpdiBpZD0iZW1wdHkiPgog
ICAgICAgICAgICA8ZGl2IGNsYXNzPSJlLXR4dCIgaWQ9ImVtcHR5LXR4dCI+5pqC5peg6K6w5b2V77yM
5aSN5Yi25ZCO6Ieq5Yqo5Ye6546wPC9kaXY+CiAgICAgICAgPC9kaXY+CiAgICA8L2Rpdj4KICAgIDxi
dXR0b24gaWQ9ImJ0bi10b3AiIHR5cGU9ImJ1dHRvbiIgdGl0bGU9IuWbnuWIsOmhtumDqCIgYXJpYS1s
YWJlbD0i5Zue5Yiw6aG26YOoIj4KICAgICAgICA8c3ZnIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0i
bm9uZSIgc3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0cm9rZS13aWR0aD0iMi4yIgogICAgICAgICAgICAg
c3Ryb2tlLWxpbmVjYXA9InJvdW5kIiBzdHJva2UtbGluZWpvaW49InJvdW5kIj4KICAgICAgICAgICAg
PHBhdGggZD0iTTEyIDE5VjUiLz4KICAgICAgICAgICAgPHBhdGggZD0iTTUgMTJsNy03IDcgNyIvPgog
ICAgICAgIDwvc3ZnPgogICAgPC9idXR0b24+CjwvZGl2PgoKPGRpdiBpZD0iY3R4Ij4KICAgIDxkaXYg
Y2xhc3M9ImMtaXRlbSIgaWQ9ImMtY29weSI+PHNwYW4gY2xhc3M9ImMtaWNvIj7ijpg8L3NwYW4+5aSN
5Yi2PC9kaXY+CiAgICA8ZGl2IGNsYXNzPSJjLWl0ZW0iIGlkPSJjLXBhc3RlIj48c3BhbiBjbGFzcz0i
Yy1pY28iPuKPjjwvc3Bhbj7nspjotLQ8L2Rpdj4KICAgIDxkaXYgY2xhc3M9ImMtc2VwIj48L2Rpdj4K
ICAgIDxkaXYgY2xhc3M9ImMtaXRlbSIgaWQ9ImMtcGluIj48c3BhbiBjbGFzcz0iYy1pY28iPuKYhTwv
c3Bhbj7mlLbol488L2Rpdj4KICAgIDxkaXYgY2xhc3M9ImMtaXRlbSIgaWQ9ImMtdGl0bGUiIHN0eWxl
PSJkaXNwbGF5Om5vbmUiPjxzcGFuIGNsYXNzPSJjLWljbyI+4pyOPC9zcGFuPuiuvue9ruagh+mimDwv
ZGl2PgogICAgPGRpdiBjbGFzcz0iYy1pdGVtIiBpZD0iYy1tZXJnZSIgc3R5bGU9ImRpc3BsYXk6bm9u
ZSI+PHNwYW4gY2xhc3M9ImMtaWNvIj7ip4k8L3NwYW4+5ZCI5bm2PC9kaXY+CiAgICA8ZGl2IGNsYXNz
PSJjLWl0ZW0iIGlkPSJjLXVubWVyZ2UiIHN0eWxlPSJkaXNwbGF5Om5vbmUiPjxzcGFuIGNsYXNzPSJj
LWljbyI+4oeEPC9zcGFuPuWPlua2iOWQiOW5tjwvZGl2PgogICAgPGRpdiBjbGFzcz0iYy1pdGVtIiBp
ZD0iYy10b3AiPjxzcGFuIGNsYXNzPSJjLWljbyI+4oaRPC9zcGFuPuenu+WIsOmhtumDqDwvZGl2Pgog
ICAgPGRpdiBjbGFzcz0iYy1pdGVtIiBpZD0iYy1jbGVhci1wYXN0ZWQiIHN0eWxlPSJkaXNwbGF5Om5v
bmUiPjxzcGFuIGNsYXNzPSJjLWljbyI+4pyTPC9zcGFuPua4hemZpOeKtuaAgTwvZGl2PgogICAgPGRp
diBjbGFzcz0iYy1pdGVtIiBpZD0iYy1xdWV1ZS1mcm9tIiBzdHlsZT0iZGlzcGxheTpub25lIj48c3Bh
biBjbGFzcz0iYy1pY28iPuKGuzwvc3Bhbj7ku47mraTlpITlvIDlp4vpmJ/liJc8L2Rpdj4KICAgIDxk
aXYgY2xhc3M9ImMtc2VwIj48L2Rpdj4KICAgIDxkaXYgY2xhc3M9ImMtaXRlbSBkYW5nZXIiIGlkPSJj
LWRlbCI+PHNwYW4gY2xhc3M9ImMtaWNvIj7inJU8L3NwYW4+5Yig6ZmkPC9kaXY+CjwvZGl2PgoKPGRp
diBpZD0iY2xyLWRsZyI+CiAgICA8ZGl2IGNsYXNzPSJjbHItYm94IiByb2xlPSJkaWFsb2ciIGFyaWEt
bW9kYWw9InRydWUiPgogICAgICAgIDxkaXYgY2xhc3M9ImNsci10aXRsZSIgaWQ9ImNsci10aXRsZSI+
56Gu6K6k5riF56m677yfPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0iY2xyLWRlc2MiIGlkPSJjbHIt
ZGVzYyI+6buY6K6k5LuF5riF56m65b2T5aSp5YaF5a6544CCPC9kaXY+CiAgICAgICAgPGxhYmVsIGNs
YXNzPSJjbHItY2hlY2siIGZvcj0iY2xyLWFsbCI+CiAgICAgICAgICAgIDxpbnB1dCB0eXBlPSJjaGVj
a2JveCIgaWQ9ImNsci1hbGwiPgogICAgICAgICAgICA8c3Bhbj7muIXnqbrmiYDmnIk8L3NwYW4+CiAg
ICAgICAgPC9sYWJlbD4KICAgICAgICA8ZGl2IGNsYXNzPSJjbHItYnRucyI+CiAgICAgICAgICAgIDxi
dXR0b24gdHlwZT0iYnV0dG9uIiBpZD0iY2xyLWNhbmNlbCI+5Y+W5raIPC9idXR0b24+CiAgICAgICAg
ICAgIDxidXR0b24gdHlwZT0iYnV0dG9uIiBpZD0iY2xyLW9rIj7muIXnqbo8L2J1dHRvbj4KICAgICAg
ICA8L2Rpdj4KICAgIDwvZGl2Pgo8L2Rpdj4KCjxkaXYgaWQ9InRpdGxlLWRsZyI+CiAgICA8ZGl2IGNs
YXNzPSJ0aXRsZS1ib3giIHJvbGU9ImRpYWxvZyIgYXJpYS1tb2RhbD0idHJ1ZSI+CiAgICAgICAgPGRp
diBjbGFzcz0iY2xyLXRpdGxlIj7orr7nva7moIfpopg8L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJj
bHItZGVzYyI+5qCH6aKY5Y+v6KKr5pCc57Si5om+5Yiw77yM5LuF55So5LqO5pS26JeP5pW055CG44CC
PC9kaXY+CiAgICAgICAgPGlucHV0IGlkPSJ0aXRsZS1pbnB1dCIgdHlwZT0idGV4dCIgbWF4bGVuZ3Ro
PSI4MCIgcGxhY2Vob2xkZXI9Iue7mei/meadoeaUtuiXj+i1t+S4quWQjeWtl+KApiIgYXV0b2NvbXBs
ZXRlPSJvZmYiIHNwZWxsY2hlY2s9ImZhbHNlIj4KICAgICAgICA8ZGl2IGNsYXNzPSJjbHItYnRucyI+
CiAgICAgICAgICAgIDxidXR0b24gdHlwZT0iYnV0dG9uIiBpZD0idGl0bGUtY2FuY2VsIj7lj5bmtog8
L2J1dHRvbj4KICAgICAgICAgICAgPGJ1dHRvbiB0eXBlPSJidXR0b24iIGlkPSJ0aXRsZS1vayI+5L+d
5a2YPC9idXR0b24+CiAgICAgICAgPC9kaXY+CiAgICA8L2Rpdj4KPC9kaXY+CjxkaXYgaWQ9InBhdGgt
dGlwIiBhcmlhLWhpZGRlbj0idHJ1ZSI+PC9kaXY+Cgo8c2NyaXB0PgovKiDnpoHmraIgQ3RybCvmu5ro
va7nvKnmlL7vvIhXZWJWaWV3IOiuvue9riArIOmhtemdouWFnOW6le+8iSAqLwooZnVuY3Rpb24oKXsK
ICBjb25zdCBibG9ja1pvb20gPSBlID0+IHsKICAgIGlmIChlLmN0cmxLZXkgfHwgZS5tZXRhS2V5KSB7
CiAgICAgIGUucHJldmVudERlZmF1bHQoKTsKICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgIH0K
ICB9OwogIHdpbmRvdy5hZGRFdmVudExpc3RlbmVyKCd3aGVlbCcsIGJsb2NrWm9vbSwgeyBwYXNzaXZl
OiBmYWxzZSwgY2FwdHVyZTogdHJ1ZSB9KTsKICB3aW5kb3cuYWRkRXZlbnRMaXN0ZW5lcignZ2VzdHVy
ZXN0YXJ0JywgZSA9PiBlLnByZXZlbnREZWZhdWx0KCksIHsgcGFzc2l2ZTogZmFsc2UsIGNhcHR1cmU6
IHRydWUgfSk7CiAgZG9jdW1lbnQuYWRkRXZlbnRMaXN0ZW5lcigna2V5ZG93bicsIGUgPT4gewogICAg
aWYgKCEoZS5jdHJsS2V5IHx8IGUubWV0YUtleSkpIHJldHVybjsKICAgIGlmIChlLmtleSA9PT0gJysn
IHx8IGUua2V5ID09PSAnLScgfHwgZS5rZXkgPT09ICc9JyB8fCBlLmtleSA9PT0gJ18nCiAgICAgICAg
fHwgZS5jb2RlID09PSAnTnVtcGFkQWRkJyB8fCBlLmNvZGUgPT09ICdOdW1wYWRTdWJ0cmFjdCcKICAg
ICAgICB8fCBlLmtleSA9PT0gJzAnKSB7CiAgICAgIC8vIGFsbG93IG5vdGhpbmcgZm9yIHpvb207IEN0
cmwrMCAvIMKxCiAgICAgIGlmIChlLmtleSA9PT0gJzAnIHx8IGUua2V5ID09PSAnKycgfHwgZS5rZXkg
PT09ICctJyB8fCBlLmtleSA9PT0gJz0nIHx8IGUua2V5ID09PSAnXycKICAgICAgICAgIHx8IGUuY29k
ZSA9PT0gJ051bXBhZEFkZCcgfHwgZS5jb2RlID09PSAnTnVtcGFkU3VidHJhY3QnKSB7CiAgICAgICAg
ZS5wcmV2ZW50RGVmYXVsdCgpOwogICAgICB9CiAgICB9CiAgfSwgdHJ1ZSk7Cn0pKCk7Cjwvc2NyaXB0
Pgo8c2NyaXB0PgovKiBza2VsLWZhaWxzYWZlOiBvbmx5IGlmIG1haW4gVUkgc2NyaXB0IG5ldmVyIGJv
b3RlZCDigJRuZXZlciBpbnZlbnQgZW1wdHktc3RhdGUgKi8KKGZ1bmN0aW9uKCl7CiAgc2V0VGltZW91
dCgoKSA9PiB7CiAgICB0cnkgewogICAgICBpZiAod2luZG93Ll9fdWlCb290ZWQpIHJldHVybjsKICAg
ICAgdmFyIGFwcCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdhcHAnKTsKICAgICAgaWYgKGFwcCkg
YXBwLmNsYXNzTGlzdC5yZW1vdmUoJ2Jvb3QtbG9hZGluZycpOwogICAgICB2YXIgcyA9IGRvY3VtZW50
LmdldEVsZW1lbnRCeUlkKCdza2VsJyk7CiAgICAgIGlmIChzKSBzLmNsYXNzTGlzdC5yZW1vdmUoJ29u
Jyk7CiAgICB9IGNhdGNoIChlcnIpIHt9CiAgfSwgMzAwMCk7Cn0pKCk7Cjwvc2NyaXB0Pgo8c2NyaXB0
PgogICAgbGV0IGFsbENsaXBzID0gW10sIGN1clRhYiA9ICdhbGwnLCBxdWVyeSA9ICcnLCBjdHhDbGlw
ID0gbnVsbCwgc2VsZWN0ZWRJZCA9IDAsIHBpbm5lZFVJID0gZmFsc2U7CiAgICBjb25zdCBUQUJfT1JE
RVIgPSBbJ2FsbCcsICd0ZXh0JywgJ2ltYWdlJywgJ2ZpbGUnLCAncmVjZW50JywgJ3Bpbm5lZCddOwog
ICAgY29uc3Qgdmlld01lbSA9IG5ldyBNYXAoKTsKICAgIGZ1bmN0aW9uIHZpZXdNZW1LZXkodGFiLCBx
LCB0b2RheSkgewogICAgICAgIHJldHVybiBTdHJpbmcodGFiIHx8ICdhbGwnKSArICdcdCcgKyBTdHJp
bmcocSB8fCAnJykgKyAnXHQnICsgKHRvZGF5ID8gJzEnIDogJzAnKTsKICAgIH0KICAgIGxldCB0YWJT
d2l0Y2hBbmltRGlyID0gMDsKICAgIGxldCBtdWx0aUlkcyA9IFtdOwogICAgbGV0IHRvZGF5T25seSA9
IGZhbHNlOwogICAgbGV0IGRpc2tUb3RhbCA9IDA7CiAgICBsZXQgbG9hZGluZ01vcmUgPSBmYWxzZTsK
ICAgIC8vIERvbid0IHNob3cgc2tlbGV0b24gaW1tZWRpYXRlbHkg4oCUb25seSBhZnRlciBTS0VMX0RF
TEFZX01TIGlmIGRhdGEgc3RpbGwgbWlzc2luZwogICAgbGV0IGJvb3RMb2FkaW5nID0gZmFsc2U7CiAg
ICBsZXQgd2FpdGluZ0RhdGEgPSBmYWxzZTsKICAgIGxldCBob3N0UHVzaGVkT25jZSA9IGZhbHNlOyAv
LyBvbmx5IHRoZW4gbWF5IHNob3fjgIzmmoLml6DorrDlvZXjgI0KICAgIGxldCBzYXdOb25FbXB0eSA9
IGZhbHNlOyAgICAvLyBpZ25vcmUgYm9vdHN0cmFwIGVtcHR5IHB1c2hlcyBiZWZvcmUgZmlyc3QgcmVh
bCBsaXN0CiAgICBsZXQgcGlubmVkVG90YWwgPSAwOyAgICAgICAgLy8gYXV0aG9yaXRhdGl2ZSDmlLbo
l48gY291bnQgZnJvbSBBSEsKICAgIGNvbnN0IFNLRUxfREVMQVlfTVMgPSA2MDsKICAgIHdpbmRvdy5f
X2RhdGFSZWFkeSA9IGZhbHNlOwogICAgd2luZG93Ll9fdWlCb290ZWQgPSB0cnVlOwogICAgLy8gT3Bl
biBwYW5lbCB3aXRob3V0IHBhc3Rpbmcg4oaSIGFsd2F5cyBsYW5kIG9uIGZpcnN0IGl0ZW0gKGFmdGVy
IGRhdGEgYXJyaXZlcykKICAgIGxldCBzZWxlY3RGaXJzdE9uU2hvdyA9IGZhbHNlOwogICAgbGV0IGxh
c3RQYXN0ZUlkID0gMDsKICAgIGxldCBsYXN0UGFzdGVUYWIgPSAnYWxsJzsKICAgIGxldCBsb2NhdGVB
Y3RpdmUgPSBmYWxzZTsKICAgIHRyeSB7IGxhc3RQYXN0ZUlkID0gK2xvY2FsU3RvcmFnZS5nZXRJdGVt
KCdjbGlwTGFzdFBhc3RlSWQnKSB8fCAwOyB9IGNhdGNoIHt9CiAgICB0cnkgewogICAgICAgIGNvbnN0
IHQgPSBsb2NhbFN0b3JhZ2UuZ2V0SXRlbSgnY2xpcExhc3RQYXN0ZVRhYicpIHx8ICdhbGwnOwogICAg
ICAgIGxhc3RQYXN0ZVRhYiA9IFsnYWxsJywndGV4dCcsJ2ltYWdlJywnZmlsZScsJ3Bpbm5lZCddLmlu
Y2x1ZGVzKHQpID8gdCA6ICdhbGwnOwogICAgfSBjYXRjaCB7fQogICAgLy8gUHJlZmVyIHNhbWUtb3Jp
Z2luIHVuZGVyIGNsaXB1aS5hcHAgKEFQUF9IT1NUIOKGkiBDTElQX1YxX0RJUi9jbGlwc19zdG9yZSku
CiAgICAvLyDli7/nlKggKi5sb2NhbO+8muezu+e7nyBtRE5TIOS8muWNoSAy4oCTM3PjgIJjbGlwcy5z
dG9yZSDku4XkvZwgZmFsbGJhY2vjgIIKICAgIGNvbnN0IFNUT1JFX0JBU0UgPSAobG9jYXRpb24ub3Jp
Z2luICYmIGxvY2F0aW9uLm9yaWdpbi5pbmRleE9mKCdodHRwczovLycpID09PSAwKQogICAgICAgID8g
KGxvY2F0aW9uLm9yaWdpbi5yZXBsYWNlKC9cLyQvLCAnJykgKyAnL2NsaXBzX3N0b3JlLycpCiAgICAg
ICAgOiAnaHR0cHM6Ly9jbGlwdWkuYXBwL2NsaXBzX3N0b3JlLyc7CiAgICBjb25zdCBTVE9SRV9CQVNF
X0ZBTExCQUNLID0gJ2h0dHBzOi8vY2xpcHMuc3RvcmUvJzsKICAgIGZ1bmN0aW9uIG1ldGFDZW50ZXJI
dG1sKGV4cGFuZElubmVyKSB7CiAgICAgICAgaWYgKGV4cGFuZElubmVyID09IG51bGwgfHwgZXhwYW5k
SW5uZXIgPT09IGZhbHNlKQogICAgICAgICAgICByZXR1cm4gYDxzcGFuIGNsYXNzPSJpLW1ldGEtY2Vu
dGVyIj48L3NwYW4+YDsKICAgICAgICByZXR1cm4gYDxzcGFuIGNsYXNzPSJpLW1ldGEtY2VudGVyIj48
YnV0dG9uIGNsYXNzPSJpLWV4cGFuZC1idG4ke2V4cGFuZElubmVyLm9uID8gJyBvbicgOiAnJ30iIHR5
cGU9ImJ1dHRvbiIgdGl0bGU9IuWxleW8gC/mlLbotbciPiR7ZXhwYW5kSW5uZXIuaHRtbH08L2J1dHRv
bj48L3NwYW4+YDsKICAgIH0KCiAgICBmdW5jdGlvbiByZW1lbWJlckxhc3RQYXN0ZShpZCkgewogICAg
ICAgIGxhc3RQYXN0ZUlkID0gK2lkIHx8IDA7CiAgICAgICAgbGFzdFBhc3RlVGFiID0gY3VyVGFiIHx8
ICdhbGwnOwogICAgICAgIHRyeSB7CiAgICAgICAgICAgIGxvY2FsU3RvcmFnZS5zZXRJdGVtKCdjbGlw
TGFzdFBhc3RlSWQnLCBTdHJpbmcobGFzdFBhc3RlSWQpKTsKICAgICAgICAgICAgbG9jYWxTdG9yYWdl
LnNldEl0ZW0oJ2NsaXBMYXN0UGFzdGVUYWInLCBsYXN0UGFzdGVUYWIpOwogICAgICAgIH0gY2F0Y2gg
e30KICAgICAgICB1cGRhdGVMb2NhdGVCdG4oKTsKICAgIH0KICAgIGZ1bmN0aW9uIHVwZGF0ZUxvY2F0
ZUJ0bigpIHsKICAgICAgICBjb25zdCBidG4gPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYnRuLWxv
Y2F0ZScpOwogICAgICAgIGlmICghYnRuKSByZXR1cm47CiAgICAgICAgYnRuLmRpc2FibGVkID0gIWxh
c3RQYXN0ZUlkOwogICAgICAgIGJ0bi5jbGFzc0xpc3QudG9nZ2xlKCdoYXMtdGFyZ2V0JywgISFsYXN0
UGFzdGVJZCk7CiAgICAgICAgYnRuLmNsYXNzTGlzdC50b2dnbGUoJ29uJywgbG9jYXRlQWN0aXZlICYm
ICEhbGFzdFBhc3RlSWQpOwogICAgICAgIGJ0bi50aXRsZSA9ICFsYXN0UGFzdGVJZAogICAgICAgICAg
ICA/ICfmmoLml6DkuIrmrKHkvb/nlKjkvY3nva4nCiAgICAgICAgICAgIDogKGxvY2F0ZUFjdGl2ZSA/
ICflj5bmtojlrprkvY3vvIzlm57liLDnrKzkuIDmnaEnIDogJ+WumuS9jeWIsOS4iuasoeS9v+eUqOea
hOadoeebricpOwogICAgfQogICAgZnVuY3Rpb24gc2VsZWN0Rmlyc3RJdGVtKCkgewogICAgICAgIGxv
Y2F0ZUFjdGl2ZSA9IGZhbHNlOwogICAgICAgIHdpbmRvdy5fX3BlbmRpbmdKdW1wSWQgPSAwOwogICAg
ICAgIHdpbmRvdy5fX2p1bXBMb2FkVHJpZXMgPSAwOwogICAgICAgIHNlbGVjdEZpcnN0T25TaG93ID0g
ZmFsc2U7CiAgICAgICAgY29uc3QgdmlzID0gdmlzaWJsZUxpc3QoKTsKICAgICAgICBpZiAoIXZpcy5s
ZW5ndGgpIHsKICAgICAgICAgICAgc2VsZWN0ZWRJZCA9IDA7CiAgICAgICAgICAgIHN5bmNJdGVtSGln
aGxpZ2h0KCk7CiAgICAgICAgICAgIHVwZGF0ZUxvY2F0ZUJ0bigpOwogICAgICAgICAgICByZXR1cm47
CiAgICAgICAgfQogICAgICAgIHNlbGVjdGVkSWQgPSB2aXNbMF0uaWQ7CiAgICAgICAgcmFuZ2VBbmNo
b3JJZCA9IHNlbGVjdGVkSWQ7CiAgICAgICAgcmFuZ2VBbmNob3JDbGlja2VkID0gZmFsc2U7CiAgICAg
ICAgbGlzdEVsLnNjcm9sbFRvcCA9IDA7CiAgICAgICAgc3luY0l0ZW1IaWdobGlnaHQoKTsKICAgICAg
ICBjb25zdCBlbCA9IGxpc3RFbC5xdWVyeVNlbGVjdG9yKCcuaXRtW2RhdGEtaWQ9IicgKyBzZWxlY3Rl
ZElkICsgJyJdJyk7CiAgICAgICAgaWYgKGVsKSBlbC5zY3JvbGxJbnRvVmlldyh7IGJsb2NrOiAnbmVh
cmVzdCcgfSk7CiAgICAgICAgdXBkYXRlTG9jYXRlQnRuKCk7CiAgICB9CiAgICBmdW5jdGlvbiBqdW1w
VG9MYXN0UGFzdGUoKSB7CiAgICAgICAgaWYgKCFsYXN0UGFzdGVJZCkgcmV0dXJuOwogICAgICAgIC8v
IEFscmVhZHkgbG9jYXRlZCBvbiBsYXN0IHBhc3RlIOKGkiBjYW5jZWwgYW5kIHNlbGVjdCBmaXJzdAog
ICAgICAgIGlmIChsb2NhdGVBY3RpdmUgJiYgK3NlbGVjdGVkSWQgPT09ICtsYXN0UGFzdGVJZCkgewog
ICAgICAgICAgICBzZWxlY3RGaXJzdEl0ZW0oKTsKICAgICAgICAgICAgcmV0dXJuOwogICAgICAgIH0K
ICAgICAgICBsb2NhdGVBY3RpdmUgPSB0cnVlOwogICAgICAgIHNlbGVjdEZpcnN0T25TaG93ID0gZmFs
c2U7CiAgICAgICAgLy8gQ2xlYXIgZmlsdGVycyBzbyB0aGUgaXRlbSBpcyBmaW5kYWJsZSBvbiB0aGUg
dGFiIHdoZXJlIGl0IHdhcyB1c2VkCiAgICAgICAgcXVlcnkgPSAnJzsKICAgICAgICB0b2RheU9ubHkg
PSBmYWxzZTsKICAgICAgICB0cnkgewogICAgICAgICAgICBjb25zdCBzcmNoID0gZG9jdW1lbnQuZ2V0
RWxlbWVudEJ5SWQoJ3NlYXJjaCcpOwogICAgICAgICAgICBjb25zdCBzY2xyID0gZG9jdW1lbnQuZ2V0
RWxlbWVudEJ5SWQoJ3NlYXJjaC1jbHInKTsKICAgICAgICAgICAgY29uc3Qgd3JhcCA9IGRvY3VtZW50
LmdldEVsZW1lbnRCeUlkKCdzZWFyY2gtd3JhcCcpOwogICAgICAgICAgICBjb25zdCBidG5Ub2RheSA9
IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdidG4tdG9kYXknKTsKICAgICAgICAgICAgaWYgKHNyY2gp
IHsgc3JjaC52YWx1ZSA9ICcnOyBzcmNoLmNsYXNzTGlzdC5yZW1vdmUoJ2hhcy12YWwnKTsgfQogICAg
ICAgICAgICBpZiAoc2Nscikgc2Nsci5zdHlsZS5kaXNwbGF5ID0gJ25vbmUnOwogICAgICAgICAgICBp
ZiAod3JhcCkgd3JhcC5jbGFzc0xpc3QucmVtb3ZlKCdvcGVuJyk7CiAgICAgICAgICAgIGlmIChidG5U
b2RheSkgYnRuVG9kYXkuY2xhc3NMaXN0LnJlbW92ZSgnb24nKTsKICAgICAgICB9IGNhdGNoIHt9CiAg
ICAgICAgY29uc3QgdGFiID0gWydhbGwnLCd0ZXh0JywnaW1hZ2UnLCdmaWxlJywncGlubmVkJ10uaW5j
bHVkZXMobGFzdFBhc3RlVGFiKQogICAgICAgICAgICA/IGxhc3RQYXN0ZVRhYiA6ICdhbGwnOwogICAg
ICAgIGNvbnN0IHByZXZUYWIgPSBjdXJUYWI7CiAgICAgICAgY3VyVGFiID0gdGFiOwogICAgICAgIGxv
YWRpbmdNb3JlID0gZmFsc2U7CiAgICAgICAgbWFya1RhYih0YWIpOwogICAgICAgIGNsZWFyTXVsdGko
KTsKICAgICAgICBzZWxlY3RlZElkID0gbGFzdFBhc3RlSWQ7CiAgICAgICAgd2luZG93Ll9fcGVuZGlu
Z0p1bXBJZCA9IGxhc3RQYXN0ZUlkOwogICAgICAgIHdpbmRvdy5fX2p1bXBMb2FkVHJpZXMgPSAwOwog
ICAgICAgIHdpbmRvdy5fX2p1bXBGZWxsQmFjayA9IGZhbHNlOwogICAgICAgIHVwZGF0ZUxvY2F0ZUJ0
bigpOwogICAgICAgIHJlcXVlc3RWaWV3KCk7CiAgICB9CgogICAgZnVuY3Rpb24gcmVxdWVzdFZpZXco
KSB7CiAgICAgICAgY29uc3QgdGFiID0gY3VyVGFiLCBxID0gcXVlcnksIHRvZGF5ID0gdG9kYXlPbmx5
ID8gJzEnIDogJzAnOwogICAgICAgIGlmICh3aW5kb3cuX192aWV3UmFmKSBjYW5jZWxBbmltYXRpb25G
cmFtZSh3aW5kb3cuX192aWV3UmFmKTsKICAgICAgICB3aW5kb3cuX192aWV3UmFmID0gcmVxdWVzdEFu
aW1hdGlvbkZyYW1lKCgpID0+IHsKICAgICAgICAgICAgd2luZG93Ll9fdmlld1JhZiA9IDA7CiAgICAg
ICAgICAgIHNldFRpbWVvdXQoKCkgPT4gYWhrKCdzZXRWaWV3JywgdGFiLCBxLCB0b2RheSksIDApOwog
ICAgICAgIH0pOwogICAgfQogICAgLyoqIERlYm91bmNlZCBBSEsgc3luYyBhZnRlciB2aWV3TWVtIGlu
c3RhbnQgcGFpbnQg4oCUYXZvaWRzIHRhYi1zd2l0Y2ggZG91YmxlIFB1c2hDbGlwcyAqLwogICAgZnVu
Y3Rpb24gc29mdFJlcXVlc3RWaWV3KCkgewogICAgICAgIGlmICh3aW5kb3cuX19zb2Z0Vmlld1QpIGNs
ZWFyVGltZW91dCh3aW5kb3cuX19zb2Z0Vmlld1QpOwogICAgICAgIHdpbmRvdy5fX3NvZnRWaWV3VCA9
IHNldFRpbWVvdXQoKCkgPT4gewogICAgICAgICAgICB3aW5kb3cuX19zb2Z0Vmlld1QgPSAwOwogICAg
ICAgICAgICByZXF1ZXN0VmlldygpOwogICAgICAgIH0sIDMyMCk7CiAgICB9CiAgICBmdW5jdGlvbiBy
ZXF1ZXN0TW9yZShmb3JjZSA9IGZhbHNlKSB7CiAgICAgICAgaWYgKGRpc2tUb3RhbCA+IDAgJiYgYWxs
Q2xpcHMubGVuZ3RoID49IGRpc2tUb3RhbCkgcmV0dXJuOwogICAgICAgIC8vIExvY2F0ZSAvIGp1bXAg
bXVzdCBub3Qgd2FpdCBvbiBzY3JvbGwtaWRsZSBvciBhIHN0dWNrIGxvYWRpbmdNb3JlIGZsYWcKICAg
ICAgICBpZiAoIWZvcmNlKSB7CiAgICAgICAgICAgIGlmIChsb2FkaW5nTW9yZSkgcmV0dXJuOwogICAg
ICAgICAgICBpZiAod2luZG93Ll9fc2Nyb2xsQnVzeSB8fCBfbGlzdFB0ckRvd24pIHsKICAgICAgICAg
ICAgICAgIHdpbmRvdy5fX3dhbnRNb3JlID0gdHJ1ZTsKICAgICAgICAgICAgICAgIHJldHVybjsKICAg
ICAgICAgICAgfQogICAgICAgIH0gZWxzZSB7CiAgICAgICAgICAgIGxvYWRpbmdNb3JlID0gZmFsc2U7
CiAgICAgICAgICAgIHdpbmRvdy5fX3Njcm9sbEJ1c3kgPSBmYWxzZTsKICAgICAgICAgICAgd2luZG93
Ll9fd2FudE1vcmUgPSBmYWxzZTsKICAgICAgICAgICAgX2xpc3RQdHJEb3duID0gZmFsc2U7CiAgICAg
ICAgICAgIHRyeSB7IGxpc3RFbC5jbGFzc0xpc3QucmVtb3ZlKCdpcy1zY3JvbGxpbmcnKTsgfSBjYXRj
aCB7fQogICAgICAgIH0KICAgICAgICBpZiAobG9hZGluZ01vcmUpIHJldHVybjsKICAgICAgICBsb2Fk
aW5nTW9yZSA9IHRydWU7CiAgICAgICAgd2luZG93Ll9fd2FudE1vcmUgPSBmYWxzZTsKICAgICAgICBp
ZiAod2luZG93Ll9fbG9hZE1vcmVXYXRjaCkgY2xlYXJUaW1lb3V0KHdpbmRvdy5fX2xvYWRNb3JlV2F0
Y2gpOwogICAgICAgIHdpbmRvdy5fX2xvYWRNb3JlV2F0Y2ggPSBzZXRUaW1lb3V0KCgpID0+IHsKICAg
ICAgICAgICAgd2luZG93Ll9fbG9hZE1vcmVXYXRjaCA9IDA7CiAgICAgICAgICAgIGlmIChsb2FkaW5n
TW9yZSkgewogICAgICAgICAgICAgICAgbG9hZGluZ01vcmUgPSBmYWxzZTsKICAgICAgICAgICAgICAg
IGlmICh3aW5kb3cuX19wZW5kaW5nSnVtcElkKSB0cnlDb250aW51ZUp1bXAoKTsKICAgICAgICAgICAg
fQogICAgICAgIH0sIDE4MDApOwogICAgICAgIGFoaygnbG9hZE1vcmUnKTsKICAgIH0KCiAgICBmdW5j
dGlvbiB0cnlDb250aW51ZUp1bXAoKSB7CiAgICAgICAgY29uc3QgamlkID0gK3dpbmRvdy5fX3BlbmRp
bmdKdW1wSWQ7CiAgICAgICAgaWYgKCFqaWQpIHJldHVybjsKICAgICAgICBpZiAoX3BlbmRpbmdBcHBl
bmQpIHsKICAgICAgICAgICAgY29uc3QgcGVuZGluZyA9IF9wZW5kaW5nQXBwZW5kOwogICAgICAgICAg
ICBfcGVuZGluZ0FwcGVuZCA9IG51bGw7CiAgICAgICAgICAgIGFwcGx5QXBwZW5kUGF5bG9hZChwZW5k
aW5nKTsKICAgICAgICB9CiAgICAgICAgY29uc3QgZWwgPSBsaXN0RWwucXVlcnlTZWxlY3RvcignLm1n
LXJvd1tkYXRhLWlkPSInICsgamlkICsgJyJdJykgfHwgbGlzdEVsLnF1ZXJ5U2VsZWN0b3IoJy5pdG1b
ZGF0YS1pZD0iJyArIGppZCArICciXScpOwogICAgICAgIGlmIChlbCkgewogICAgICAgICAgICB3aW5k
b3cuX19wZW5kaW5nSnVtcElkID0gMDsKICAgICAgICAgICAgd2luZG93Ll9fanVtcExvYWRUcmllcyA9
IDA7CiAgICAgICAgICAgIHNlbGVjdGVkSWQgPSBqaWQ7CiAgICAgICAgICAgIGxvY2F0ZUFjdGl2ZSA9
IHRydWU7CiAgICAgICAgICAgIHVwZGF0ZUxvY2F0ZUJ0bigpOwogICAgICAgICAgICByZXF1ZXN0QW5p
bWF0aW9uRnJhbWUoKCkgPT4gewogICAgICAgICAgICAgICAgY29uc3Qgbm9kZSA9IGxpc3RFbC5xdWVy
eVNlbGVjdG9yKCcubWctcm93W2RhdGEtaWQ9IicgKyBqaWQgKyAnIl0nKSB8fCBsaXN0RWwucXVlcnlT
ZWxlY3RvcignLml0bVtkYXRhLWlkPSInICsgamlkICsgJyJdJyk7CiAgICAgICAgICAgICAgICBpZiAo
IW5vZGUpIHJldHVybjsKICAgICAgICAgICAgICAgIG5vZGUuc2Nyb2xsSW50b1ZpZXcoeyBibG9jazog
J2NlbnRlcicgfSk7CiAgICAgICAgICAgICAgICBub2RlLmNsYXNzTGlzdC5hZGQoJ2p1bXAtZmxhc2gn
KTsKICAgICAgICAgICAgICAgIHNldFRpbWVvdXQoKCkgPT4gbm9kZS5jbGFzc0xpc3QucmVtb3ZlKCdq
dW1wLWZsYXNoJyksIDkwMCk7CiAgICAgICAgICAgICAgICBzeW5jSXRlbUhpZ2hsaWdodCgpOwogICAg
ICAgICAgICB9KTsKICAgICAgICAgICAgcmV0dXJuOwogICAgICAgIH0KICAgICAgICBpZiAoYWxsQ2xp
cHMuc29tZShjID0+ICtjLmlkID09PSBqaWQpKSB7CiAgICAgICAgICAgIHJlbmRlcigpOwogICAgICAg
ICAgICByZXF1ZXN0QW5pbWF0aW9uRnJhbWUoKCkgPT4gdHJ5Q29udGludWVKdW1wKCkpOwogICAgICAg
ICAgICByZXR1cm47CiAgICAgICAgfQogICAgICAgIGlmIChhbGxDbGlwcy5sZW5ndGggPCBkaXNrVG90
YWwgJiYgKHdpbmRvdy5fX2p1bXBMb2FkVHJpZXMgfHwgMCkgPCA4MCkgewogICAgICAgICAgICB3aW5k
b3cuX19qdW1wTG9hZFRyaWVzID0gKHdpbmRvdy5fX2p1bXBMb2FkVHJpZXMgfHwgMCkgKyAxOwogICAg
ICAgICAgICByZXF1ZXN0TW9yZSh0cnVlKTsKICAgICAgICAgICAgcmV0dXJuOwogICAgICAgIH0KICAg
ICAgICB3aW5kb3cuX19wZW5kaW5nSnVtcElkID0gMDsKICAgICAgICB3aW5kb3cuX19qdW1wTG9hZFRy
aWVzID0gMDsKICAgIH0KICAgIGNvbnN0IEVNUFRZX01TRyA9IHsKICAgICAgICBhbGw6ICAgICfmmoLm
l6DorrDlvZXvvIzlpI3liLblkI7oh6rliqjlh7rnjrAnLAogICAgICAgIHRleHQ6ICAgJ+aaguaXoOaW
h+acrCcsCiAgICAgICAgaW1hZ2U6ICAn5pqC5peg5Zu+5YOPJywKICAgICAgICBmaWxlOiAgICfmmoLm
l6Dmlofku7YnLAogICAgICAgIHBpbm5lZDogJ+aaguaXoOaUtuiXjycsCiAgICAgICAgcmVjZW50OiAn
5pqC5peg5pyA6L+R5omT5byA55qE55uu5b2VJwogICAgfTsKCiAgICBmdW5jdGlvbiBhaGtJbnZva2Uo
bWV0aG9kLCBhcmdzKSB7CiAgICAgICAgdHJ5IHsKICAgICAgICAgICAgY29uc3QgaG9zdCA9IGNocm9t
ZS53ZWJ2aWV3Lmhvc3RPYmplY3RzLnN5bmMuYWhrOwogICAgICAgICAgICBpZiAoIWhvc3QpIHJldHVy
bjsKICAgICAgICAgICAgbGV0IGNhbGxlZCA9IGZhbHNlOwogICAgICAgICAgICAvLyBXZWJWaWV3Mjog
aG9zdC5jYWxsKG5hbWUsIOKApikgaXMgdGhlIHJlbGlhYmxlIHBhdGguIERpcmVjdCBob3N0W21ldGhv
ZF0o4oCmKQogICAgICAgICAgICAvLyBjYW4gbWlzLWJpbmQgYXJncyAoc2F3IHNldFZpZXcgdGFiIGJl
Y29tZSAwIOKGkiBmb3JldmVyIHNrZWxldG9uIC8gd3JvbmcgdGFiKS4KICAgICAgICAgICAgaWYgKHR5
cGVvZiBob3N0LmNhbGwgPT09ICdmdW5jdGlvbicpIHsKICAgICAgICAgICAgICAgIHRyeSB7IGhvc3Qu
Y2FsbChtZXRob2QsIC4uLmFyZ3MpOyBjYWxsZWQgPSB0cnVlOyB9IGNhdGNoIHt9CiAgICAgICAgICAg
IH0KICAgICAgICAgICAgaWYgKCFjYWxsZWQgJiYgdHlwZW9mIGhvc3RbbWV0aG9kXSA9PT0gJ2Z1bmN0
aW9uJykgewogICAgICAgICAgICAgICAgdHJ5IHsgaG9zdFttZXRob2RdKC4uLmFyZ3MpOyBjYWxsZWQg
PSB0cnVlOyB9IGNhdGNoIChlKSB7IGNvbnNvbGUud2FybignYWhrLicgKyBtZXRob2QsIGUpOyB9CiAg
ICAgICAgICAgIH0KICAgICAgICAgICAgaWYgKCFjYWxsZWQgJiYgaG9zdFttZXRob2RdICE9IG51bGwg
JiYgdHlwZW9mIGhvc3RbbWV0aG9kXSAhPT0gJ2Z1bmN0aW9uJykgewogICAgICAgICAgICAgICAgdHJ5
IHsgdm9pZCBob3N0W21ldGhvZF07IH0gY2F0Y2gge30KICAgICAgICAgICAgfQogICAgICAgIH0gY2F0
Y2ggKGUpIHsgY29uc29sZS53YXJuKCdhaGsuJyArIG1ldGhvZCwgZSk7IH0KICAgIH0KICAgIGZ1bmN0
aW9uIGFoayhtZXRob2QsIC4uLmFyZ3MpIHsKICAgICAgICBhaGtJbnZva2UobWV0aG9kLCBhcmdzKTsK
ICAgIH0KICAgIGZ1bmN0aW9uIGFoa1JldChtZXRob2QsIC4uLmFyZ3MpIHsKICAgICAgICB0cnkgewog
ICAgICAgICAgICBjb25zdCBob3N0ID0gY2hyb21lLndlYnZpZXcuaG9zdE9iamVjdHMuc3luYy5haGs7
CiAgICAgICAgICAgIGlmICghaG9zdCkgcmV0dXJuIG51bGw7CiAgICAgICAgICAgIGxldCByZXQgPSBu
dWxsOwogICAgICAgICAgICBpZiAodHlwZW9mIGhvc3QuY2FsbCA9PT0gJ2Z1bmN0aW9uJykgewogICAg
ICAgICAgICAgICAgdHJ5IHsgcmV0ID0gaG9zdC5jYWxsKG1ldGhvZCwgLi4uYXJncyk7IH0gY2F0Y2gg
e30KICAgICAgICAgICAgfQogICAgICAgICAgICBpZiAocmV0ID09IG51bGwgJiYgdHlwZW9mIGhvc3Rb
bWV0aG9kXSA9PT0gJ2Z1bmN0aW9uJykgewogICAgICAgICAgICAgICAgdHJ5IHsgcmV0ID0gaG9zdFtt
ZXRob2RdKC4uLmFyZ3MpOyB9IGNhdGNoIHt9CiAgICAgICAgICAgICAgICBpZiAocmV0ID09IG51bGwp
IHsKICAgICAgICAgICAgICAgICAgICB0cnkgeyByZXQgPSBob3N0W21ldGhvZF0oLi4uYXJncyk7IH0g
Y2F0Y2gge30KICAgICAgICAgICAgICAgIH0KICAgICAgICAgICAgfQogICAgICAgICAgICBpZiAocmV0
ID09IG51bGwgJiYgaG9zdFttZXRob2RdICE9IG51bGwgJiYgdHlwZW9mIGhvc3RbbWV0aG9kXSAhPT0g
J2Z1bmN0aW9uJykKICAgICAgICAgICAgICAgIHJldCA9IGhvc3RbbWV0aG9kXTsKICAgICAgICAgICAg
aWYgKHJldCA9PSBudWxsKSByZXR1cm4gbnVsbDsKICAgICAgICAgICAgaWYgKHR5cGVvZiByZXQgPT09
ICdzdHJpbmcnIHx8IHR5cGVvZiByZXQgPT09ICdudW1iZXInIHx8IHR5cGVvZiByZXQgPT09ICdib29s
ZWFuJykKICAgICAgICAgICAgICAgIHJldHVybiByZXQ7CiAgICAgICAgICAgIHRyeSB7IHJldHVybiBT
dHJpbmcocmV0KTsgfSBjYXRjaCB7IHJldHVybiByZXQ7IH0KICAgICAgICB9IGNhdGNoIChlKSB7IGNv
bnNvbGUud2FybignYWhrUmV0LicgKyBtZXRob2QsIGUpOyB9CiAgICAgICAgcmV0dXJuIG51bGw7CiAg
ICB9CgogICAgLy8gRWFybHkgQUhLIF9fc2V0VGh1bWIgY2FuIGFycml2ZSBiZWZvcmUgRE9NIG5vZGVz
IGV4aXN0IOKAlCBrZWVwIHVudGlsIGJpbmQKICAgIGNvbnN0IHRodW1iQ2FjaGUgPSBuZXcgTWFwKCk7
CgogICAgLyoqIFByZWZlciBjYWNoZSAvIGRhdGEtVVJMLCB0aGVuIHRoXyouanBnIHZpYSB2aXJ0dWFs
IGhvc3QsIHRoZW4gb3JpZ2luYWwgKi8KICAgIGZ1bmN0aW9uIGJpbmRTdG9yZVRodW1iKGltZywgZmls
ZSwgaWQsIGZhbGxiYWNrKSB7CiAgICAgICAgaW1nLmRhdGFzZXQudGh1bWJJZCA9IFN0cmluZyhpZCk7
CiAgICAgICAgaW1nLmFsdCA9ICcnOwogICAgICAgIGltZy5jbGFzc0xpc3QuYWRkKCd0aHVtYi1sb2Fk
aW5nJyk7CiAgICAgICAgY29uc3Qgd3JhcCA9IGltZy5wYXJlbnRFbGVtZW50OwogICAgICAgIGlmICh3
cmFwICYmIHdyYXAuY2xhc3NMaXN0LmNvbnRhaW5zKCdpLXRodW1iLXdyYXAnKSkKICAgICAgICAgICAg
d3JhcC5jbGFzc0xpc3QuYWRkKCd3YWl0aW5nJyk7CiAgICAgICAgY29uc3QgY2xlYXJXYWl0ID0gKCkg
PT4gewogICAgICAgICAgICBpbWcuY2xhc3NMaXN0LnJlbW92ZSgndGh1bWItbG9hZGluZycpOwogICAg
ICAgICAgICBpZiAod3JhcCkgd3JhcC5jbGFzc0xpc3QucmVtb3ZlKCd3YWl0aW5nJyk7CiAgICAgICAg
ICAgIGlmIChpbWcuX2ZhaWxUaW1lcikgdHJ5IHsgY2xlYXJUaW1lb3V0KGltZy5fZmFpbFRpbWVyKTsg
fSBjYXRjaCB7fQogICAgICAgIH07CiAgICAgICAgY29uc3QgZmFpbFRpbWVyID0gc2V0VGltZW91dCgo
KSA9PiB7CiAgICAgICAgICAgIGlmICghaW1nLnNyYyB8fCBpbWcubmF0dXJhbFdpZHRoIDwgMSkKICAg
ICAgICAgICAgICAgIGltZy5hbHQgPSAn5peg5rOV5Yqg6L29JzsKICAgICAgICAgICAgY2xlYXJXYWl0
KCk7CiAgICAgICAgfSwgMTIwMDApOwogICAgICAgIGltZy5fZmFpbFRpbWVyID0gZmFpbFRpbWVyOwog
ICAgICAgIGNvbnN0IHByZXZMb2FkID0gaW1nLm9ubG9hZDsKICAgICAgICBpbWcub25sb2FkID0gZSA9
PiB7CiAgICAgICAgICAgIGNsZWFyV2FpdCgpOwogICAgICAgICAgICBpbWcuYWx0ID0gJyc7CiAgICAg
ICAgICAgIGlmICh0eXBlb2YgcHJldkxvYWQgPT09ICdmdW5jdGlvbicpIHByZXZMb2FkLmNhbGwoaW1n
LCBlKTsKICAgICAgICB9OwogICAgICAgIGNvbnN0IGJhcmUgPSBmaWxlID8gU3RyaW5nKGZpbGUpLnNw
bGl0KC9bXFwvXS8pLnBvcCgpIDogJyc7CiAgICAgICAgY29uc3QgdGhOYW1lID0gYmFyZSA/ICgndGhf
JyArIGJhcmUucmVwbGFjZSgvXC5bXi5dKyQvLCAnJykgKyAnLmpwZycpIDogJyc7CiAgICAgICAgaW1n
Lm9uZXJyb3IgPSAoKSA9PiB7CiAgICAgICAgICAgIGNvbnN0IHN0ZXAgPSBOdW1iZXIoaW1nLmRhdGFz
ZXQuc3RlcCB8fCAwKTsKICAgICAgICAgICAgaWYgKHN0ZXAgPCAyICYmIGJhcmUpIHsKICAgICAgICAg
ICAgICAgIGltZy5kYXRhc2V0LnN0ZXAgPSAnMic7CiAgICAgICAgICAgICAgICBpbWcuc3JjID0gU1RP
UkVfQkFTRSArIGVuY29kZVVSSUNvbXBvbmVudChiYXJlKTsKICAgICAgICAgICAgICAgIHJldHVybjsK
ICAgICAgICAgICAgfQogICAgICAgICAgICBpZiAoc3RlcCA8IDMgJiYgKHRoTmFtZSB8fCBiYXJlKSkg
ewogICAgICAgICAgICAgICAgaW1nLmRhdGFzZXQuc3RlcCA9ICczJzsKICAgICAgICAgICAgICAgIGlt
Zy5zcmMgPSBTVE9SRV9CQVNFX0ZBTExCQUNLICsgZW5jb2RlVVJJQ29tcG9uZW50KHRoTmFtZSB8fCBi
YXJlKTsKICAgICAgICAgICAgICAgIHJldHVybjsKICAgICAgICAgICAgfQogICAgICAgICAgICBpZiAo
c3RlcCA8IDQgJiYgYmFyZSAmJiB0aE5hbWUpIHsKICAgICAgICAgICAgICAgIGltZy5kYXRhc2V0LnN0
ZXAgPSAnNCc7CiAgICAgICAgICAgICAgICBpbWcuc3JjID0gU1RPUkVfQkFTRV9GQUxMQkFDSyArIGVu
Y29kZVVSSUNvbXBvbmVudChiYXJlKTsKICAgICAgICAgICAgICAgIHJldHVybjsKICAgICAgICAgICAg
fQogICAgICAgICAgICAvLyBLZWVwIHNoaW1tZXI7IEFISyBfX3NldFRodW1iIHdpbGwgZmlsbCBpbgog
ICAgICAgICAgICBpbWcucmVtb3ZlQXR0cmlidXRlKCdzcmMnKTsKICAgICAgICAgICAgaW1nLmNsYXNz
TGlzdC5hZGQoJ3RodW1iLWxvYWRpbmcnKTsKICAgICAgICAgICAgaWYgKHdyYXApIHdyYXAuY2xhc3NM
aXN0LmFkZCgnd2FpdGluZycpOwogICAgICAgIH07CiAgICAgICAgY29uc3QgY2FjaGVkID0gdGh1bWJD
YWNoZS5nZXQoU3RyaW5nKGlkKSk7CiAgICAgICAgLy8gQWNjZXB0IGRhdGEtVVJMIG9yIGhvc3QgVVJM
IGZyb20gcHJpb3IgX19zZXRUaHVtYiAocmUtcmVuZGVyIG11c3Qgbm90IGRyb3AgaXQpCiAgICAgICAg
aWYgKGNhY2hlZCAmJiBTdHJpbmcoY2FjaGVkKS5sZW5ndGgpIHsKICAgICAgICAgICAgaW1nLmRhdGFz
ZXQuc3RlcCA9ICc5JzsKICAgICAgICAgICAgaW1nLnNyYyA9IFN0cmluZyhjYWNoZWQpOwogICAgICAg
ICAgICByZXR1cm47CiAgICAgICAgfQogICAgICAgIGNvbnN0IGRhdGFVcmwgPSAoZmFsbGJhY2sgJiYg
U3RyaW5nKGZhbGxiYWNrKS5zdGFydHNXaXRoKCdkYXRhOicpKQogICAgICAgICAgICA/IFN0cmluZyhm
YWxsYmFjaykgOiAnJzsKICAgICAgICBpZiAoZGF0YVVybCkgewogICAgICAgICAgICBpbWcuZGF0YXNl
dC5zdGVwID0gJzknOwogICAgICAgICAgICBpbWcuc3JjID0gZGF0YVVybDsKICAgICAgICAgICAgcmV0
dXJuOwogICAgICAgIH0KICAgICAgICBpZiAoYmFyZSkgewogICAgICAgICAgICAvLyBQcmVmZXIgbGlz
dCB0aHVtYiBKUEVHIChzbWFsbCkgb24gZGVkaWNhdGVkIHN0b3JlIGhvc3QKICAgICAgICAgICAgaW1n
LmRhdGFzZXQuc3RlcCA9ICcxJzsKICAgICAgICAgICAgaW1nLnNyYyA9IFNUT1JFX0JBU0UgKyBlbmNv
ZGVVUklDb21wb25lbnQodGhOYW1lIHx8IGJhcmUpOwogICAgICAgIH0gZWxzZSB7CiAgICAgICAgICAg
IC8vIE5vIGZpbGUgeWV0IChqdXN0IGNvcGllZCkg4oCUa2VlcCBzaGltbWVyOyBJbmplY3RMaXZlSW1h
Z2VUaHVtYiAvIF9fc2V0VGh1bWIgZmlsbHMgaW4KICAgICAgICAgICAgaW1nLmNsYXNzTGlzdC5hZGQo
J3RodW1iLWxvYWRpbmcnKTsKICAgICAgICAgICAgaWYgKHdyYXApIHdyYXAuY2xhc3NMaXN0LmFkZCgn
d2FpdGluZycpOwogICAgICAgIH0KICAgIH0KCiAgICB3aW5kb3cuX19zZXRUaHVtYiA9IChpZCwgdXJs
KSA9PiB7CiAgICAgICAgaWYgKCF1cmwpIHJldHVybjsKICAgICAgICBjb25zdCBrZXkgPSBTdHJpbmco
aWQpOwogICAgICAgIHRodW1iQ2FjaGUuc2V0KGtleSwgdXJsKTsKICAgICAgICBjb25zdCBhcHBseSA9
IGltZyA9PiB7CiAgICAgICAgICAgIGlmIChpbWcuX2ZhaWxUaW1lcikgdHJ5IHsgY2xlYXJUaW1lb3V0
KGltZy5fZmFpbFRpbWVyKTsgfSBjYXRjaCB7fQogICAgICAgICAgICBpbWcub25lcnJvciA9IG51bGw7
CiAgICAgICAgICAgIGltZy5hbHQgPSAnJzsKICAgICAgICAgICAgaW1nLmNsYXNzTGlzdC5yZW1vdmUo
J3RodW1iLWxvYWRpbmcnKTsKICAgICAgICAgICAgY29uc3Qgd3JhcCA9IGltZy5wYXJlbnRFbGVtZW50
OwogICAgICAgICAgICBpZiAod3JhcCkgd3JhcC5jbGFzc0xpc3QucmVtb3ZlKCd3YWl0aW5nJyk7CiAg
ICAgICAgICAgIGltZy5zcmMgPSB1cmw7CiAgICAgICAgfTsKICAgICAgICBsZXQgaGl0ID0gMDsKICAg
ICAgICBkb2N1bWVudC5xdWVyeVNlbGVjdG9yQWxsKCcuaXRtW2RhdGEtaWQ9IicgKyBrZXkgKyAnIl0g
aW1nLmktdGh1bWInKS5mb3JFYWNoKGltZyA9PiB7CiAgICAgICAgICAgIGFwcGx5KGltZyk7IGhpdCsr
OwogICAgICAgIH0pOwogICAgICAgIGlmICghaGl0KSB7CiAgICAgICAgICAgIGRvY3VtZW50LnF1ZXJ5
U2VsZWN0b3JBbGwoJ2ltZy5pLXRodW1iW2RhdGEtdGh1bWItaWQ9IicgKyBrZXkgKyAnIl0nKS5mb3JF
YWNoKGFwcGx5KTsKICAgICAgICB9CiAgICB9OwoKICAgIGZ1bmN0aW9uIGlzRHJhZ0V4Y2x1ZGUodCkg
ewogICAgICAgIHJldHVybiAhIXQuY2xvc2VzdCgnI3NlYXJjaC13cmFwLCAjYnRuLXNlYXJjaCwgI2J0
bi1sb2NhdGUsICNidG4tdG9kYXksICNidG4tcGluLCAjYnRuLWNsciwgI211bHRpLWJhciwgI211bHRp
LXNlbCwgI211bHRpLWNudCwgI3Bhc3RlLXNlcC13cmFwLCAudGFiLCAuaXRtLCAjdGFiLWFjdGlvbnMs
ICNjdHgsICNjbHItZGxnLCAjcGF0aC10aXAsIGJ1dHRvbiwgaW5wdXQsIGEnKTsKICAgIH0KICAgIGRv
Y3VtZW50LmdldEVsZW1lbnRCeUlkKCdhcHAnKS5hZGRFdmVudExpc3RlbmVyKCdtb3VzZWRvd24nLCBl
ID0+IHsKICAgICAgICBpZiAoZS5idXR0b24gIT09IDApIHJldHVybjsKICAgICAgICBpZiAoaXNEcmFn
RXhjbHVkZShlLnRhcmdldCkpIHJldHVybjsKICAgICAgICBlLnByZXZlbnREZWZhdWx0KCk7CiAgICAg
ICAgYWhrKCdzdGFydERyYWcnKTsKICAgIH0sIHRydWUpOwoKICAgIGNvbnN0IGlzVXJsICA9IHMgPT4g
L15odHRwcz86XC9cLy9pLnRlc3QoKHMgfHwgJycpLnRyaW0oKSk7CgogICAgZnVuY3Rpb24gYWdvKGRh
dGVTdHIpIHsKICAgICAgICB0cnkgewogICAgICAgICAgICBjb25zdCBkID0gbmV3IERhdGUoU3RyaW5n
KGRhdGVTdHIpLnJlcGxhY2UoJyAnLCAnVCcpKTsKICAgICAgICAgICAgY29uc3QgcyA9IChEYXRlLm5v
dygpIC0gZCkgLyAxMDAwIHwgMDsKICAgICAgICAgICAgaWYgKHMgPCA2MCkgcmV0dXJuICfliJrliJon
OwogICAgICAgICAgICBpZiAocyA8IDM2MDApIHJldHVybiAocyAvIDYwIHwgMCkgKyAnIOWIhumSn+WJ
jSc7CiAgICAgICAgICAgIGlmIChzIDwgODY0MDApIHJldHVybiAocyAvIDM2MDAgfCAwKSArICcg5bCP
5pe25YmNJzsKICAgICAgICAgICAgcmV0dXJuIChzIC8gODY0MDAgfCAwKSArICcg5aSp5YmNJzsKICAg
ICAgICB9IGNhdGNoIHsgcmV0dXJuIGRhdGVTdHI7IH0KICAgIH0KCiAgICBmdW5jdGlvbiBub3JtVHlw
ZSh0KSB7CiAgICAgICAgdCA9IFN0cmluZyh0IHx8ICcnKS50b0xvd2VyQ2FzZSgpOwogICAgICAgIGlm
ICh0ID09PSAnaW1hZ2UnIHx8IHQgPT09ICdpbWcnIHx8IHQgPT09ICdiaXRtYXAnKSByZXR1cm4gJ2lt
YWdlJzsKICAgICAgICBpZiAodCA9PT0gJ2ZpbGUnICB8fCB0ID09PSAnZmlsZXMnKSByZXR1cm4gJ2Zp
bGUnOwogICAgICAgIGlmICh0ID09PSAncmVjZW50JyB8fCB0ID09PSAnZm9sZGVyJyB8fCB0ID09PSAn
ZGlyJykgcmV0dXJuICdyZWNlbnQnOwogICAgICAgIGlmICh0ID09PSAnbGluaycgfHwgdCA9PT0gJ3Vy
bCcpIHJldHVybiAnbGluayc7CiAgICAgICAgcmV0dXJuICd0ZXh0JzsKICAgIH0KICAgIGZ1bmN0aW9u
IGlzUGlubmVkKGMpIHsKICAgICAgICByZXR1cm4gYy5waW5uZWQgPT09IHRydWUgfHwgYy5waW5uZWQg
PT09IDEgfHwgYy5waW5uZWQgPT09ICd0cnVlJyB8fCBjLnBpbm5lZCA9PT0gJzEnOwogICAgfQogICAg
ZnVuY3Rpb24gaXNQYXN0ZWQoYykgewogICAgICAgIHJldHVybiBjLnBhc3RlZCA9PT0gdHJ1ZSB8fCBj
LnBhc3RlZCA9PT0gMSB8fCBjLnBhc3RlZCA9PT0gJ3RydWUnIHx8IGMucGFzdGVkID09PSAnMSc7CiAg
ICB9CgogICAgZnVuY3Rpb24gaXNNYXJrZG93bih0ZXh0KSB7CiAgICAgICAgaWYgKCF0ZXh0IHx8IHRl
eHQubGVuZ3RoIDwgNCkgcmV0dXJuIGZhbHNlOwogICAgICAgIHJldHVybiAvKD86XnxcbikjezEsNn0g
fF5bLSorXSB8XCpcKlteKlxuXStcKlwqfF9fW15fXG5dK19ffCg/Ol58XG4pPiB8YGBgfGBbXmBcbl0r
YHxcW1teXF1dK1xdXChbXildK1wpfFx8LitcfC4rXHwvbS50ZXN0KHRleHQpOwogICAgfQogICAgZnVu
Y3Rpb24gY2xpcFVzZXNNSWNvbihjKSB7CiAgICAgICAgaWYgKCFjKSByZXR1cm4gZmFsc2U7CiAgICAg
ICAgaWYgKGMuaXNNZCA9PT0gdHJ1ZSB8fCBjLmlzTWQgPT09IDEgfHwgYy5pc01kID09PSAndHJ1ZScg
fHwgYy5pc01kID09PSAnMScpIHJldHVybiB0cnVlOwogICAgICAgIGlmIChjLmlzUmljaCA9PT0gdHJ1
ZSB8fCBjLmlzUmljaCA9PT0gMSB8fCBjLmlzUmljaCA9PT0gJ3RydWUnIHx8IGMuaXNSaWNoID09PSAn
MScpIHJldHVybiB0cnVlOwogICAgICAgIGNvbnN0IHQgPSBTdHJpbmcoYy50eXBlIHx8ICcnKS50b0xv
d2VyQ2FzZSgpOwogICAgICAgIGlmICh0ICYmIHQgIT09ICd0ZXh0JyAmJiB0ICE9PSAnbGluaycpIHJl
dHVybiBmYWxzZTsKICAgICAgICByZXR1cm4gaXNNYXJrZG93bihjLmRhdGEgfHwgYy5wcmV2aWV3IHx8
ICcnKTsKICAgIH0KICAgIGZ1bmN0aW9uIGVzY0F0dHIocykgewogICAgICAgIHJldHVybiBTdHJpbmco
cyB8fCAnJykKICAgICAgICAgICAgLnJlcGxhY2UoLyYvZywgJyZhbXA7JykKICAgICAgICAgICAgLnJl
cGxhY2UoLyIvZywgJyZxdW90OycpCiAgICAgICAgICAgIC5yZXBsYWNlKC88L2csICcmbHQ7JykKICAg
ICAgICAgICAgLnJlcGxhY2UoLz4vZywgJyZndDsnKTsKICAgIH0KCiAgICBmdW5jdGlvbiB0b2RheVBy
ZWZpeCgpIHsKICAgICAgICBjb25zdCBkID0gbmV3IERhdGUoKTsKICAgICAgICBjb25zdCBwID0gbiA9
PiBTdHJpbmcobikucGFkU3RhcnQoMiwgJzAnKTsKICAgICAgICByZXR1cm4gZC5nZXRGdWxsWWVhcigp
ICsgJy0nICsgcChkLmdldE1vbnRoKCkgKyAxKSArICctJyArIHAoZC5nZXREYXRlKCkpOwogICAgfQog
ICAgZnVuY3Rpb24gaXNUb2RheUNsaXAoYykgewogICAgICAgIHJldHVybiBTdHJpbmcoYy50aW1lIHx8
ICcnKS5zdGFydHNXaXRoKHRvZGF5UHJlZml4KCkpOwogICAgfQoKICAgIGZ1bmN0aW9uIGNsaXBIYXko
YykgewogICAgICAgIHJldHVybiBTdHJpbmcoYy5wcmV2aWV3IHx8ICcnKSArICcgJyArIFN0cmluZyhj
LmRhdGEgfHwgJycpICsgJyAnCiAgICAgICAgICAgICsgU3RyaW5nKGMubGlua1RpdGxlIHx8ICcnKSAr
ICcgJyArIFN0cmluZyhjLmZhdlRpdGxlIHx8ICcnKTsKICAgIH0KICAgIC8qKiBNYXRjaCBBSEsgSXRl
bU1hdGNoZXNWaWV3IGxpc3Qgc2VhcmNoIOKAlCBwcmV2aWV3ICgrIHNob3J0IGJvZHkgZmFsbGJhY2sp
LCBub3QgZnVsbCBkYXRhICovCiAgICBmdW5jdGlvbiBjbGlwU2VhcmNoSGF5KGMpIHsKICAgICAgICBj
b25zdCB0eXBlID0gU3RyaW5nKGMudHlwZSB8fCAnJykudG9Mb3dlckNhc2UoKTsKICAgICAgICBpZiAo
dHlwZSA9PT0gJ2ltYWdlJykKICAgICAgICAgICAgcmV0dXJuIFN0cmluZyhjLmZhdlRpdGxlIHx8ICcn
KTsKICAgICAgICBpZiAodHlwZSA9PT0gJ2ZpbGUnKSB7CiAgICAgICAgICAgIHJldHVybiBTdHJpbmco
Yy5wcmV2aWV3IHx8ICcnKSArICcgJyArIFN0cmluZyhjLmRhdGEgfHwgJycpICsgJyAnCiAgICAgICAg
ICAgICAgICArIFN0cmluZyhjLmZhdlRpdGxlIHx8ICcnKTsKICAgICAgICB9CiAgICAgICAgbGV0IHBy
ZXYgPSBTdHJpbmcoYy5wcmV2aWV3IHx8ICcnKTsKICAgICAgICBpZiAoIXByZXYgJiYgYy5kYXRhKQog
ICAgICAgICAgICBwcmV2ID0gU3RyaW5nKGMuZGF0YSkuc2xpY2UoMCwgNTAwKTsKICAgICAgICByZXR1
cm4gcHJldiArICcgJyArIFN0cmluZyhjLmxpbmtUaXRsZSB8fCAnJykgKyAnICcgKyBTdHJpbmcoYy5m
YXZUaXRsZSB8fCAnJyk7CiAgICB9CiAgICBmdW5jdGlvbiBjbGlwTWF0Y2hlc1NlYXJjaChjLCB0ZXJt
TCkgewogICAgICAgIGNvbnN0IHR5cGUgPSBTdHJpbmcoYy50eXBlIHx8ICcnKS50b0xvd2VyQ2FzZSgp
OwogICAgICAgIGNvbnN0IGhheSA9ICh0eXBlID09PSAnaW1hZ2UnID8gU3RyaW5nKGMuZmF2VGl0bGUg
fHwgJycpIDogY2xpcFNlYXJjaEhheShjKSkudG9Mb3dlckNhc2UoKTsKICAgICAgICByZXR1cm4gdGVy
bUwuZXZlcnkodCA9PiBoYXkuaW5jbHVkZXModCkpOwogICAgfQogICAgZnVuY3Rpb24gZmlsdGVyKGNs
aXBzLCB0YWIsIHEpIHsKICAgICAgICAvLyDkuLvmnLrlt7Lov4fmu6Tml7bku43lgZrliY3nq6/lhZzl
upXvvJrpgb/lhY3nq57mgIHmjqjmnaXmnKrlkb3kuK3ooYwKICAgICAgICBjb25zdCB0ZXJtcyA9IHF1
ZXJ5VGVybXMocSk7CiAgICAgICAgaWYgKCF0ZXJtcy5sZW5ndGgpIHJldHVybiBjbGlwczsKICAgICAg
ICBjb25zdCB0ZXJtTCA9IHRlcm1zLm1hcCh0ID0+IHQudG9Mb3dlckNhc2UoKSk7CiAgICAgICAgY29u
c3QgbWF0Y2hlZEdyb3VwcyA9IG5ldyBTZXQoKTsKICAgICAgICBmb3IgKGNvbnN0IGMgb2YgY2xpcHMp
IHsKICAgICAgICAgICAgaWYgKCFjbGlwTWF0Y2hlc1NlYXJjaChjLCB0ZXJtTCkpIGNvbnRpbnVlOwog
ICAgICAgICAgICBjb25zdCBnaWQgPSBTdHJpbmcoYyAmJiBjLmZhdkdyb3VwIHx8ICcnKS50cmltKCk7
CiAgICAgICAgICAgIGlmIChnaWQpIG1hdGNoZWRHcm91cHMuYWRkKGdpZCk7CiAgICAgICAgfQogICAg
ICAgIC8vIOWQiOW5tue7hO+8muWFs+mUruWtl+WPr+iDveWIhuaVo+WcqOS4jeWQjOihjO+8iOagh+mi
mC/mraPmlofvvIkKICAgICAgICBjb25zdCBieUdyb3VwID0gbmV3IE1hcCgpOwogICAgICAgIGZvciAo
Y29uc3QgYyBvZiBjbGlwcykgewogICAgICAgICAgICBjb25zdCBnaWQgPSBTdHJpbmcoYyAmJiBjLmZh
dkdyb3VwIHx8ICcnKS50cmltKCk7CiAgICAgICAgICAgIGlmICghZ2lkKSBjb250aW51ZTsKICAgICAg
ICAgICAgaWYgKCFieUdyb3VwLmhhcyhnaWQpKSBieUdyb3VwLnNldChnaWQsIFtdKTsKICAgICAgICAg
ICAgYnlHcm91cC5nZXQoZ2lkKS5wdXNoKGMpOwogICAgICAgIH0KICAgICAgICBmb3IgKGNvbnN0IFtn
aWQsIG1lbWJlcnNdIG9mIGJ5R3JvdXApIHsKICAgICAgICAgICAgaWYgKG1hdGNoZWRHcm91cHMuaGFz
KGdpZCkpIGNvbnRpbnVlOwogICAgICAgICAgICBjb25zdCB1bmlvbiA9IG1lbWJlcnMubWFwKGMgPT4g
ewogICAgICAgICAgICAgICAgY29uc3QgdHlwZSA9IFN0cmluZyhjLnR5cGUgfHwgJycpLnRvTG93ZXJD
YXNlKCk7CiAgICAgICAgICAgICAgICByZXR1cm4gKHR5cGUgPT09ICdpbWFnZScgPyBTdHJpbmcoYy5m
YXZUaXRsZSB8fCAnJykgOiBjbGlwU2VhcmNoSGF5KGMpKS50b0xvd2VyQ2FzZSgpOwogICAgICAgICAg
ICB9KS5qb2luKCcgJyk7CiAgICAgICAgICAgIGlmICh0ZXJtTC5ldmVyeSh0ID0+IHVuaW9uLmluY2x1
ZGVzKHQpKSkKICAgICAgICAgICAgICAgIG1hdGNoZWRHcm91cHMuYWRkKGdpZCk7CiAgICAgICAgfQog
ICAgICAgIHJldHVybiBjbGlwcy5maWx0ZXIoYyA9PiB7CiAgICAgICAgICAgIGlmIChjbGlwTWF0Y2hl
c1NlYXJjaChjLCB0ZXJtTCkpIHJldHVybiB0cnVlOwogICAgICAgICAgICBjb25zdCBnaWQgPSBTdHJp
bmcoYyAmJiBjLmZhdkdyb3VwIHx8ICcnKS50cmltKCk7CiAgICAgICAgICAgIHJldHVybiBnaWQgJiYg
bWF0Y2hlZEdyb3Vwcy5oYXMoZ2lkKTsKICAgICAgICB9KTsKICAgIH0KCiAgICBmdW5jdGlvbiBtYXJr
UGFzdGVkTG9jYWwoaWRzKSB7CiAgICAgICAgY29uc3QgbGlzdCA9IEFycmF5LmlzQXJyYXkoaWRzKSA/
IGlkcyA6IFtpZHNdOwogICAgICAgIGlmIChsaXN0Lmxlbmd0aCkKICAgICAgICAgICAgcmVtZW1iZXJM
YXN0UGFzdGUobGlzdFtsaXN0Lmxlbmd0aCAtIDFdKTsKICAgICAgICBjb25zdCBiYWRnZUh0bWwgPSBg
PHN2ZyB2aWV3Qm94PSIwIDAgMTYgMTYiIGZpbGw9Im5vbmUiIHN0cm9rZT0iY3VycmVudENvbG9yIiBz
dHJva2Utd2lkdGg9IjIuNCIgc3Ryb2tlLWxpbmVjYXA9InJvdW5kIiBzdHJva2UtbGluZWpvaW49InJv
dW5kIj48cG9seWxpbmUgcG9pbnRzPSIzLjUgOC41IDYuNSAxMS41IDEyLjUgNC41Ii8+PC9zdmc+YDsK
ICAgICAgICBsaXN0LmZvckVhY2gocmF3SWQgPT4gewogICAgICAgICAgICBjb25zdCBpZCA9ICtyYXdJ
ZDsKICAgICAgICAgICAgY29uc3QgYyA9IGFsbENsaXBzLmZpbmQoeCA9PiAreC5pZCA9PT0gaWQpOwog
ICAgICAgICAgICBpZiAoYykgYy5wYXN0ZWQgPSB0cnVlOwogICAgICAgICAgICBjb25zdCByb3cgPSBs
aXN0RWwgJiYgKAogICAgICAgICAgICAgICAgbGlzdEVsLnF1ZXJ5U2VsZWN0b3IoJy5pdG1bZGF0YS1p
ZD0iJyArIGlkICsgJyJdJykKICAgICAgICAgICAgICAgIHx8IGxpc3RFbC5xdWVyeVNlbGVjdG9yKCcu
aXRtW2RhdGEtaWQ9IicgKyBTdHJpbmcocmF3SWQpICsgJyJdJykKICAgICAgICAgICAgKTsKICAgICAg
ICAgICAgaWYgKCFyb3cpIHJldHVybjsKICAgICAgICAgICAgcm93LmNsYXNzTGlzdC5hZGQoJ3Bhc3Rl
ZCcsICdxLWRvbmUnKTsKICAgICAgICAgICAgY29uc3QgaWNvID0gcm93LnF1ZXJ5U2VsZWN0b3IoJy5p
LWljbycpOwogICAgICAgICAgICBpZiAoaWNvICYmICFpY28ucXVlcnlTZWxlY3RvcignLmktdXNlZCcp
KSB7CiAgICAgICAgICAgICAgICBjb25zdCBiYWRnZSA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ3Nw
YW4nKTsKICAgICAgICAgICAgICAgIGJhZGdlLmNsYXNzTmFtZSA9ICdpLXVzZWQnOwogICAgICAgICAg
ICAgICAgYmFkZ2UudGl0bGUgPSAn5bey57KY6LS0JzsKICAgICAgICAgICAgICAgIGJhZGdlLmlubmVy
SFRNTCA9IGJhZGdlSHRtbDsKICAgICAgICAgICAgICAgIGljby5hcHBlbmRDaGlsZChiYWRnZSk7CiAg
ICAgICAgICAgIH0KICAgICAgICB9KTsKICAgICAgICB0cnkgeyBtYXJrUXVldWVSYWlscygpOyB9IGNh
dGNoIChlKSB7fQogICAgfQogICAgd2luZG93Ll9fbWFya1Bhc3RlZCA9IG1hcmtQYXN0ZWRMb2NhbDsK
CiAgICBmdW5jdGlvbiBtYXJrVW5wYXN0ZWRMb2NhbChpZHMpIHsKICAgICAgICBjb25zdCBsaXN0ID0g
QXJyYXkuaXNBcnJheShpZHMpID8gaWRzIDogW2lkc107CiAgICAgICAgbGlzdC5mb3JFYWNoKHJhd0lk
ID0+IHsKICAgICAgICAgICAgY29uc3QgaWQgPSArcmF3SWQ7CiAgICAgICAgICAgIGNvbnN0IGMgPSBh
bGxDbGlwcy5maW5kKHggPT4gK3guaWQgPT09IGlkKTsKICAgICAgICAgICAgaWYgKGMpIGMucGFzdGVk
ID0gZmFsc2U7CiAgICAgICAgICAgIGNvbnN0IHJvdyA9IGxpc3RFbCAmJiAoCiAgICAgICAgICAgICAg
ICBsaXN0RWwucXVlcnlTZWxlY3RvcignLml0bVtkYXRhLWlkPSInICsgaWQgKyAnIl0nKQogICAgICAg
ICAgICAgICAgfHwgbGlzdEVsLnF1ZXJ5U2VsZWN0b3IoJy5pdG1bZGF0YS1pZD0iJyArIFN0cmluZyhy
YXdJZCkgKyAnIl0nKQogICAgICAgICAgICApOwogICAgICAgICAgICBpZiAoIXJvdykgcmV0dXJuOwog
ICAgICAgICAgICByb3cuY2xhc3NMaXN0LnJlbW92ZSgncGFzdGVkJywgJ3EtZG9uZScsICdxLWRvbmUt
bGluaycpOwogICAgICAgICAgICBjb25zdCBiYWRnZSA9IHJvdy5xdWVyeVNlbGVjdG9yKCcuaS11c2Vk
Jyk7CiAgICAgICAgICAgIGlmIChiYWRnZSkgYmFkZ2UucmVtb3ZlKCk7CiAgICAgICAgICAgIGNvbnN0
IGRvdCA9IHJvdy5xdWVyeVNlbGVjdG9yKCcucS1kb3QnKTsKICAgICAgICAgICAgaWYgKGRvdCkgZG90
LnRpdGxlID0gJ+eymOi0tOmYn+WIlyc7CiAgICAgICAgfSk7CiAgICAgICAgdHJ5IHsgbWFya1F1ZXVl
UmFpbHMoKTsgfSBjYXRjaCAoZSkge30KICAgIH0KICAgIHdpbmRvdy5fX21hcmtVbnBhc3RlZCA9IG1h
cmtVbnBhc3RlZExvY2FsOwoKICAgIGNvbnN0IGxpc3RFbCAgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJ
ZCgnbGlzdCcpOwogICAgY29uc3QgZW1wdHlFbCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdlbXB0
eScpOwogICAgY29uc3Qgc2tlbEVsICA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdza2VsJyk7CiAg
ICBjb25zdCBidG5Ub3AgID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2J0bi10b3AnKTsKICAgIGZ1
bmN0aW9uIHNldEJvb3RMb2FkaW5nKG9uKSB7CiAgICAgICAgYm9vdExvYWRpbmcgPSAhIW9uOwogICAg
ICAgIC8vIOenkuW8gO+8muS4jeWGjeaJk+W8gOmqqOaetumXquWKqO+8m+WPquS/neeVmSB3YWl0aW5n
RGF0YSDpgLvovpHpmLLnqbrmgIHor6/pl6oKICAgICAgICBpZiAoc2tlbEVsKSBza2VsRWwuY2xhc3NM
aXN0LnJlbW92ZSgnb24nKTsKICAgICAgICBpZiAob24gJiYgZW1wdHlFbCkgZW1wdHlFbC5jbGFzc0xp
c3QucmVtb3ZlKCdvbicpOwogICAgICAgIGNvbnN0IGFwcCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlk
KCdhcHAnKTsKICAgICAgICBpZiAoYXBwKSBhcHAuY2xhc3NMaXN0LnJlbW92ZSgnYm9vdC1sb2FkaW5n
Jyk7CiAgICB9CiAgICAvKiogV2FpdCBmb3IgaG9zdCBkYXRhIOKAlOS4jeWGjeeri+WIu+W8uemqqOae
tu+8jOacieWGheWuueaXtuS/neaMgeaXp+WIl+ihqCAqLwogICAgZnVuY3Rpb24gc2NoZWR1bGVEZWxh
eWVkU2tlbCgpIHsKICAgICAgICB3YWl0aW5nRGF0YSA9IHRydWU7CiAgICAgICAgd2luZG93Ll9fZGF0
YVJlYWR5ID0gZmFsc2U7CiAgICAgICAgaWYgKGVtcHR5RWwpIGVtcHR5RWwuY2xhc3NMaXN0LnJlbW92
ZSgnb24nKTsKICAgICAgICBpZiAod2luZG93Ll9fcGVuZGluZ1NrZWxUaW1lcikgewogICAgICAgICAg
ICBjbGVhclRpbWVvdXQod2luZG93Ll9fcGVuZGluZ1NrZWxUaW1lcik7CiAgICAgICAgICAgIHdpbmRv
dy5fX3BlbmRpbmdTa2VsVGltZXIgPSAwOwogICAgICAgIH0KICAgICAgICB3aW5kb3cuX19wZW5kaW5n
U2tlbFNpbmNlID0gRGF0ZS5ub3coKTsKICAgICAgICAvLyDmnInml6fliJfooajlsLHkv53nlZnvvJvn
qbrliJfooajkuZ/kuI3lho3mkq3pqqjmnrbliqjnlLsKICAgIH0KICAgIGZ1bmN0aW9uIGNsZWFyV2Fp
dGluZ0RhdGEoKSB7CiAgICAgICAgd2FpdGluZ0RhdGEgPSBmYWxzZTsKICAgICAgICBpZiAod2luZG93
Ll9fcGVuZGluZ1NrZWxUaW1lcikgewogICAgICAgICAgICBjbGVhclRpbWVvdXQod2luZG93Ll9fcGVu
ZGluZ1NrZWxUaW1lcik7CiAgICAgICAgICAgIHdpbmRvdy5fX3BlbmRpbmdTa2VsVGltZXIgPSAwOwog
ICAgICAgIH0KICAgICAgICB3aW5kb3cuX19wZW5kaW5nU2tlbFNpbmNlID0gMDsKICAgICAgICBzZXRC
b290TG9hZGluZyhmYWxzZSk7CiAgICB9CiAgICB3aW5kb3cuc2V0Qm9vdExvYWRpbmcgPSBzZXRCb290
TG9hZGluZzsKICAgIHdpbmRvdy5mb3JjZUVuZEJvb3RMb2FkaW5nID0gZnVuY3Rpb24oKSB7CiAgICAg
ICAgY2xlYXJXYWl0aW5nRGF0YSgpOwogICAgICAgIC8vIERvIG5vdCBmYWtl44CM5pqC5peg6K6w5b2V
44CNaWYgaG9zdCBuZXZlciBwdXNoZWQKICAgICAgICBpZiAoaG9zdFB1c2hlZE9uY2UpCiAgICAgICAg
ICAgIHdpbmRvdy5fX2RhdGFSZWFkeSA9IHRydWU7CiAgICAgICAgdHJ5IHsgcmVuZGVyKCk7IH0gY2F0
Y2ggKGUpIHt9CiAgICB9OwogICAgLy8gU2FmZXR5OiBkcm9wIHN0dWNrIHNrZWxldG9uOyBzdGlsbCBu
ZXZlciBpbnZlbnQgZW1wdHktc3RhdGUgd2l0aG91dCBob3N0IHB1c2gKICAgIHNldFRpbWVvdXQoKCkg
PT4gewogICAgICAgIGlmIChob3N0UHVzaGVkT25jZSB8fCB3aW5kb3cuX19kYXRhUmVhZHkpIHJldHVy
bjsKICAgICAgICBpZiAoIWJvb3RMb2FkaW5nICYmICF3YWl0aW5nRGF0YSkgcmV0dXJuOwogICAgICAg
IGNsZWFyV2FpdGluZ0RhdGEoKTsKICAgICAgICB0cnkgeyByZW5kZXIoKTsgfSBjYXRjaCB7fQogICAg
fSwgODAwMCk7CgogICAgZnVuY3Rpb24gdXBkYXRlVG9wQnRuKCkgewogICAgICAgIGlmICghYnRuVG9w
IHx8ICFsaXN0RWwpIHJldHVybjsKICAgICAgICBidG5Ub3AuY2xhc3NMaXN0LnRvZ2dsZSgnb24nLCBs
aXN0RWwuc2Nyb2xsVG9wID4gNDgpOwogICAgfQogICAgbGV0IF9zY3JvbGxSYWYgPSAwOwogICAgbGV0
IF9zY3JvbGxJZGxlVCA9IDA7CiAgICBsZXQgX2xpc3RQdHJEb3duID0gZmFsc2U7CiAgICBsZXQgX3Bl
bmRpbmdBcHBlbmQgPSBudWxsOyAvLyB7IGZyb21MZW4gfSBxdWV1ZWQgd2hpbGUgc2Nyb2xsaW5nCiAg
ICB3aW5kb3cuX19zY3JvbGxCdXN5ID0gZmFsc2U7CiAgICB3aW5kb3cuX193YW50TW9yZSA9IGZhbHNl
OwoKICAgIGZ1bmN0aW9uIG1hcmtMaXN0U2Nyb2xsaW5nKCkgewogICAgICAgIHdpbmRvdy5fX3Njcm9s
bEJ1c3kgPSB0cnVlOwogICAgICAgIHRyeSB7IGxpc3RFbC5jbGFzc0xpc3QuYWRkKCdpcy1zY3JvbGxp
bmcnKTsgfSBjYXRjaCB7fQogICAgICAgIGlmIChfc2Nyb2xsSWRsZVQpIGNsZWFyVGltZW91dChfc2Ny
b2xsSWRsZVQpOwogICAgICAgIF9zY3JvbGxJZGxlVCA9IHNldFRpbWVvdXQoKCkgPT4gewogICAgICAg
ICAgICBfc2Nyb2xsSWRsZVQgPSAwOwogICAgICAgICAgICBmbHVzaFNjcm9sbElkbGUoKTsKICAgICAg
ICB9LCAyMjApOwogICAgfQoKICAgIGZ1bmN0aW9uIGZsdXNoU2Nyb2xsSWRsZSgpIHsKICAgICAgICBp
ZiAoX2xpc3RQdHJEb3duKSB7CiAgICAgICAgICAgIG1hcmtMaXN0U2Nyb2xsaW5nKCk7CiAgICAgICAg
ICAgIHJldHVybjsKICAgICAgICB9CiAgICAgICAgd2luZG93Ll9fc2Nyb2xsQnVzeSA9IGZhbHNlOwog
ICAgICAgIHRyeSB7IGxpc3RFbC5jbGFzc0xpc3QucmVtb3ZlKCdpcy1zY3JvbGxpbmcnKTsgfSBjYXRj
aCB7fQogICAgICAgIGlmIChfcGVuZGluZ0FwcGVuZCkgewogICAgICAgICAgICBjb25zdCBwZW5kaW5n
ID0gX3BlbmRpbmdBcHBlbmQ7CiAgICAgICAgICAgIF9wZW5kaW5nQXBwZW5kID0gbnVsbDsKICAgICAg
ICAgICAgYXBwbHlBcHBlbmRQYXlsb2FkKHBlbmRpbmcpOwogICAgICAgIH0KICAgICAgICBpZiAod2lu
ZG93Ll9fd2FudE1vcmUpCiAgICAgICAgICAgIHJlcXVlc3RNb3JlKCk7CiAgICAgICAgZWxzZSBpZiAo
IWxvYWRpbmdNb3JlCiAgICAgICAgICAgICYmIGRpc2tUb3RhbCA+IDAKICAgICAgICAgICAgJiYgYWxs
Q2xpcHMubGVuZ3RoIDwgZGlza1RvdGFsCiAgICAgICAgICAgICYmIGxpc3RFbC5zY3JvbGxUb3AgKyBs
aXN0RWwuY2xpZW50SGVpZ2h0ID49IGxpc3RFbC5zY3JvbGxIZWlnaHQgLSA0MjApCiAgICAgICAgICAg
IHJlcXVlc3RNb3JlKCk7CiAgICB9CgogICAgZnVuY3Rpb24gb25MaXN0U2Nyb2xsKCkgewogICAgICAg
IG1hcmtMaXN0U2Nyb2xsaW5nKCk7CiAgICAgICAgaWYgKF9zY3JvbGxSYWYpIHJldHVybjsKICAgICAg
ICBfc2Nyb2xsUmFmID0gcmVxdWVzdEFuaW1hdGlvbkZyYW1lKCgpID0+IHsKICAgICAgICAgICAgX3Nj
cm9sbFJhZiA9IDA7CiAgICAgICAgICAgIHRyeSB7IGhpZGVQYXRoVGlwKCk7IH0gY2F0Y2gge30KICAg
ICAgICAgICAgdXBkYXRlVG9wQnRuKCk7CiAgICAgICAgICAgIGlmICghbG9hZGluZ01vcmUKICAgICAg
ICAgICAgICAgICYmIGRpc2tUb3RhbCA+IDAKICAgICAgICAgICAgICAgICYmIGFsbENsaXBzLmxlbmd0
aCA8IGRpc2tUb3RhbAogICAgICAgICAgICAgICAgJiYgbGlzdEVsLnNjcm9sbFRvcCArIGxpc3RFbC5j
bGllbnRIZWlnaHQgPj0gbGlzdEVsLnNjcm9sbEhlaWdodCAtIDI0MCkKICAgICAgICAgICAgICAgIHdp
bmRvdy5fX3dhbnRNb3JlID0gdHJ1ZTsKICAgICAgICB9KTsKICAgIH0KICAgIGxpc3RFbC5hZGRFdmVu
dExpc3RlbmVyKCdzY3JvbGwnLCBvbkxpc3RTY3JvbGwsIHsgcGFzc2l2ZTogdHJ1ZSB9KTsKICAgIGxp
c3RFbC5hZGRFdmVudExpc3RlbmVyKCd3aGVlbCcsIG1hcmtMaXN0U2Nyb2xsaW5nLCB7IHBhc3NpdmU6
IHRydWUgfSk7CiAgICBsaXN0RWwuYWRkRXZlbnRMaXN0ZW5lcigncG9pbnRlcmRvd24nLCBlID0+IHsK
ICAgICAgICBpZiAoZS5idXR0b24gIT09IDApIHJldHVybjsKICAgICAgICBfbGlzdFB0ckRvd24gPSB0
cnVlOwogICAgICAgIG1hcmtMaXN0U2Nyb2xsaW5nKCk7CiAgICB9LCB7IHBhc3NpdmU6IHRydWUgfSk7
CiAgICB3aW5kb3cuYWRkRXZlbnRMaXN0ZW5lcigncG9pbnRlcnVwJywgKCkgPT4gewogICAgICAgIGlm
ICghX2xpc3RQdHJEb3duKSByZXR1cm47CiAgICAgICAgX2xpc3RQdHJEb3duID0gZmFsc2U7CiAgICAg
ICAgbWFya0xpc3RTY3JvbGxpbmcoKTsKICAgIH0sIHsgcGFzc2l2ZTogdHJ1ZSB9KTsKICAgIHdpbmRv
dy5hZGRFdmVudExpc3RlbmVyKCdwb2ludGVyY2FuY2VsJywgKCkgPT4gewogICAgICAgIGlmICghX2xp
c3RQdHJEb3duKSByZXR1cm47CiAgICAgICAgX2xpc3RQdHJEb3duID0gZmFsc2U7CiAgICAgICAgbWFy
a0xpc3RTY3JvbGxpbmcoKTsKICAgIH0sIHsgcGFzc2l2ZTogdHJ1ZSB9KTsKICAgIGJ0blRvcC5hZGRF
dmVudExpc3RlbmVyKCdjbGljaycsIGUgPT4gewogICAgICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAg
ICAgICAgbGlzdEVsLnNjcm9sbFRvKHsgdG9wOiAwLCBiZWhhdmlvcjogJ3Ntb290aCcgfSk7CiAgICB9
KTsKCiAgICBmdW5jdGlvbiB2aXNpYmxlTGlzdCgpIHsKICAgICAgICBjb25zdCBxID0gU3RyaW5nKHF1
ZXJ5IHx8ICcnKS50cmltKCk7CiAgICAgICAgLy8gSG9zdCBhbHJlYWR5IGZpbHRlcmVkK2V4cGFuZGVk
IGZvciB0aGlzIGV4YWN0IHF1ZXJ5IOKAlCBkb24ndCByZS1maWx0ZXIgKGF2b2lkcyBmbGFzaCAvIGRy
b3BwZWQgZmF2IGdyb3VwcykKICAgICAgICBpZiAocSAmJiB3aW5kb3cuX19ob3N0RmlsdGVyZWQgJiYg
d2luZG93Ll9faG9zdEZpbHRlclEgPT09IHEpCiAgICAgICAgICAgIHJldHVybiBhbGxDbGlwczsKICAg
ICAgICByZXR1cm4gZmlsdGVyKGFsbENsaXBzLCBjdXJUYWIsIHF1ZXJ5KTsKICAgIH0KICAgIGZ1bmN0
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
ZWwuZGF0YXNldC50YWIgPT09IHRhYikpOwogICAgICAgIG1vdmVUYWJJbmsoISFpbnN0YW50KTsKICAg
IH0KICAgIGZ1bmN0aW9uIGJpbmRUYWJJbmtIb3ZlcigpIHsKICAgICAgICBjb25zdCB0YWJzID0gZG9j
dW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3RhYnMnKTsKICAgICAgICBpZiAoIXRhYnMgfHwgdGFicy5faW5r
SG92ZXJCb3VuZCkgcmV0dXJuOwogICAgICAgIHRhYnMuX2lua0hvdmVyQm91bmQgPSB0cnVlOwogICAg
ICAgIHRhYnMuYWRkRXZlbnRMaXN0ZW5lcigncG9pbnRlcm92ZXInLCBlID0+IHsKICAgICAgICAgICAg
Y29uc3QgdGFiID0gZS50YXJnZXQuY2xvc2VzdCgnLnRhYicpOwogICAgICAgICAgICBpZiAoIXRhYiB8
fCAhdGFicy5jb250YWlucyh0YWIpKSByZXR1cm47CiAgICAgICAgICAgIG1vdmVUYWJJbmsoZmFsc2Us
IHRhYik7CiAgICAgICAgfSk7CiAgICAgICAgdGFicy5hZGRFdmVudExpc3RlbmVyKCdwb2ludGVybGVh
dmUnLCBlID0+IHsKICAgICAgICAgICAgaWYgKGUucmVsYXRlZFRhcmdldCAmJiB0YWJzLmNvbnRhaW5z
KGUucmVsYXRlZFRhcmdldCkpIHJldHVybjsKICAgICAgICAgICAgbW92ZVRhYkluayhmYWxzZSk7CiAg
ICAgICAgfSk7CiAgICB9CmZ1bmN0aW9uIHNldFRhYih0YWIpIHsKICAgICAgICBpZiAodGFiID09PSBj
dXJUYWIpIHJldHVybjsKICAgICAgICBjb25zdCBmcm9tID0gdGFiSW5kZXgoY3VyVGFiKTsKICAgICAg
ICBjb25zdCB0byA9IHRhYkluZGV4KHRhYik7CiAgICAgICAgdGFiU3dpdGNoQW5pbURpciA9IHRvID4g
ZnJvbSA/IDEgOiAodG8gPCBmcm9tID8gLTEgOiAwKTsKICAgICAgICBjdXJUYWIgPSB0YWI7CiAgICAg
ICAgbG9hZGluZ01vcmUgPSBmYWxzZTsKICAgICAgICBtYXJrVGFiKHRhYik7CgogICAgICAgIC8vIEtl
ZXAgc2VhcmNoICJ0b2RheSIgZmlsdGVyIGluIHN5bmMgd2hlbiBzZWFyY2ggaXMgb3BlbgogICAgICAg
IHRyeSB7CiAgICAgICAgICAgIGNvbnN0IHdyYXAgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc2Vh
cmNoLXdyYXAnKTsKICAgICAgICAgICAgY29uc3QgYnRuVG9kYXkgPSBkb2N1bWVudC5nZXRFbGVtZW50
QnlJZCgnYnRuLXRvZGF5Jyk7CiAgICAgICAgICAgIGlmICh3cmFwICYmIHdyYXAuY2xhc3NMaXN0LmNv
bnRhaW5zKCdvcGVuJykpIHsKICAgICAgICAgICAgICAgIGNvbnN0IHdhbnRUb2RheSA9IGZhbHNlOwog
ICAgICAgICAgICAgICAgaWYgKHRvZGF5T25seSAhPT0gd2FudFRvZGF5KSB7CiAgICAgICAgICAgICAg
ICAgICAgdG9kYXlPbmx5ID0gd2FudFRvZGF5OwogICAgICAgICAgICAgICAgICAgIGlmIChidG5Ub2Rh
eSkgYnRuVG9kYXkuY2xhc3NMaXN0LnRvZ2dsZSgnb24nLCB0b2RheU9ubHkpOwogICAgICAgICAgICAg
ICAgfQogICAgICAgICAgICB9CiAgICAgICAgfSBjYXRjaCB7fQoKICAgICAgICBzZWxlY3RlZElkID0g
bnVsbDsKICAgICAgICBtdWx0aUlkcyA9IFtdOwogICAgICAgIGxpc3RFbC5zY3JvbGxUb3AgPSAwOwog
ICAgICAgIGNvbnN0IGhpdCA9IHZpZXdNZW0uZ2V0KHZpZXdNZW1LZXkodGFiLCBxdWVyeSwgdG9kYXlP
bmx5KSk7CiAgICAgICAgaWYgKGhpdCAmJiBBcnJheS5pc0FycmF5KGhpdC5pdGVtcykgJiYgaGl0Lml0
ZW1zLmxlbmd0aCkgewogICAgICAgICAgICBhbGxDbGlwcyA9IGhpdC5pdGVtcy5zbGljZSgpOwogICAg
ICAgICAgICBkaXNrVG90YWwgPSBOdW1iZXIoaGl0LnRvdGFsKSB8fCBoaXQuaXRlbXMubGVuZ3RoOwog
ICAgICAgICAgICB3aW5kb3cuX193YWl0aW5nVmlldyA9IGZhbHNlOwogICAgICAgICAgICBjbGVhcldh
aXRpbmdEYXRhKCk7CiAgICAgICAgICAgIHdpbmRvdy5fX2RhdGFSZWFkeSA9IHRydWU7CiAgICAgICAg
ICAgIGhvc3RQdXNoZWRPbmNlID0gdHJ1ZTsKICAgICAgICAgICAgc2F3Tm9uRW1wdHkgPSB0cnVlOwog
ICAgICAgICAgICByZW5kZXIoKTsKICAgICAgICAgICAgYXBwbHlUYWJTd2l0Y2hBbmltKCk7CiAgICAg
ICAgICAgIC8vIE1lbW9yeSBwYWludCBmaXJzdCDigJRiYWNrZ3JvdW5kIHNvZnQtc3luYyBrZWVwcyBB
SEsgaW4gc3RlcCB3aXRob3V0IGRvdWJsZSByZWRyYXcKICAgICAgICAgICAgc29mdFJlcXVlc3RWaWV3
KCk7CiAgICAgICAgICAgIHJldHVybjsKICAgICAgICB9CiAgICAgICAgLy8gTm8gY2FjaGUgeWV0OiBr
ZWVwIGN1cnJlbnQgcm93cyDigJQgTkVWRVIgd2lwZSB0byBibGFuayB3aGl0ZQogICAgICAgIHdpbmRv
dy5fX3dhaXRpbmdWaWV3ID0gdHJ1ZTsKICAgICAgICBzY2hlZHVsZURlbGF5ZWRTa2VsKCk7CiAgICAg
ICAgaWYgKCFhbGxDbGlwcy5sZW5ndGgpCiAgICAgICAgICAgIHJlbmRlcigpOwogICAgICAgIHJlcXVl
c3RWaWV3KCk7CiAgICAgICAgYXBwbHlUYWJTd2l0Y2hBbmltKCk7CiAgICB9CgogICAgbW92ZVRhYklu
ayh0cnVlKTsKICAgIGJpbmRUYWJJbmtIb3ZlcigpOwogICAgdHJ5IHsgbmV3IFJlc2l6ZU9ic2VydmVy
KCgpID0+IG1vdmVUYWJJbmsodHJ1ZSkpLm9ic2VydmUoZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3Rh
YnMnKSk7IH0gY2F0Y2gge30KICAgIHdpbmRvdy5hZGRFdmVudExpc3RlbmVyKCdyZXNpemUnLCAoKSA9
PiBtb3ZlVGFiSW5rKHRydWUpKTsKCiAgICBmdW5jdGlvbiB1cGRhdGVNb3JlRm9vdGVyKHRvdGFsKSB7
CiAgICAgICAgbGV0IG1vcmVFbCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdsaXN0LW1vcmUnKTsK
ICAgICAgICBjb25zdCBsb2FkZWQgPSBhbGxDbGlwcy5sZW5ndGg7CiAgICAgICAgaWYgKGxvYWRlZCA+
PSB0b3RhbCkgewogICAgICAgICAgICBpZiAobW9yZUVsKSBtb3JlRWwucmVtb3ZlKCk7CiAgICAgICAg
ICAgIHJldHVybjsKICAgICAgICB9CiAgICAgICAgaWYgKCFtb3JlRWwpIHsKICAgICAgICAgICAgbW9y
ZUVsID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnZGl2Jyk7CiAgICAgICAgICAgIG1vcmVFbC5pZCA9
ICdsaXN0LW1vcmUnOwogICAgICAgICAgICBtb3JlRWwuY2xhc3NOYW1lID0gJ2xpc3QtbW9yZSc7CiAg
ICAgICAgICAgIGxpc3RFbC5hcHBlbmRDaGlsZChtb3JlRWwpOwogICAgICAgIH0KICAgICAgICBtb3Jl
RWwudGV4dENvbnRlbnQgPSAn57un57ut5LiL5ruR5LuO56OB55uY5Yqg6L2977yIJyArIGxvYWRlZCAr
ICcvJyArIHRvdGFsICsgJ++8iSc7CiAgICB9CgogICAgLyoqIFVwZGF0ZSBiYXIgLyBwaW4gYmFkZ2Ug
d2l0aG91dCB0b3VjaGluZyB0aGUgbGlzdCBET00gKi8KICAgIGZ1bmN0aW9uIHJlZnJlc2hMaXN0Q2hy
b21lKCkgewogICAgICAgIGNvbnN0IHZpc2libGUgPSB2aXNpYmxlTGlzdCgpOwogICAgICAgIGNvbnN0
IGxvYWRlZCA9IGFsbENsaXBzLmxlbmd0aDsKICAgICAgICBjb25zdCBzaG93bkNvdW50ID0gdmlzaWJs
ZS5sZW5ndGg7CiAgICAgICAgbGV0IHBpbm5lZE4gPSBOdW1iZXIocGlubmVkVG90YWwpIHx8IDA7CiAg
ICAgICAgaWYgKHBpbm5lZE4gPCAxKSB7CiAgICAgICAgICAgIGlmIChjdXJUYWIgPT09ICdwaW5uZWQn
KQogICAgICAgICAgICAgICAgcGlubmVkTiA9IE1hdGgubWF4KE51bWJlcihkaXNrVG90YWwpIHx8IDAs
IGxvYWRlZCk7CiAgICAgICAgICAgIGVsc2UKICAgICAgICAgICAgICAgIHBpbm5lZE4gPSBhbGxDbGlw
cy5maWx0ZXIoYyA9PiBpc1Bpbm5lZChjKSkubGVuZ3RoOwogICAgICAgIH0KICAgICAgICBjb25zdCBw
aW5DbnQgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgncGluLWNudCcpOwogICAgICAgIGlmIChwaW5D
bnQpIHsKICAgICAgICAgICAgcGluQ250LnRleHRDb250ZW50ID0gcGlubmVkTjsKICAgICAgICAgICAg
cGluQ250LnN0eWxlLmRpc3BsYXkgPSBwaW5uZWROID8gJycgOiAnbm9uZSc7CiAgICAgICAgfQogICAg
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
ICAgIC8vIOaUtuiXj+inkuagh++8mueUqCBBSEsg5LiL5Y+R55qE5oC75pWw77yM6YG/5YWN44CM5b2T
5YmN6aG16YeM5pWw5Ye65p2l55qE44CN5ZKMIGJhciDlr7nkuI3kuIoKICAgICAgICBsZXQgcGlubmVk
TiA9IE51bWJlcihwaW5uZWRUb3RhbCkgfHwgMDsKICAgICAgICBpZiAocGlubmVkTiA8IDEpIHsKICAg
ICAgICAgICAgaWYgKGN1clRhYiA9PT0gJ3Bpbm5lZCcpCiAgICAgICAgICAgICAgICBwaW5uZWROID0g
TWF0aC5tYXgoTnVtYmVyKGRpc2tUb3RhbCkgfHwgMCwgbG9hZGVkKTsKICAgICAgICAgICAgZWxzZQog
ICAgICAgICAgICAgICAgcGlubmVkTiA9IGFsbENsaXBzLmZpbHRlcihjID0+IGlzUGlubmVkKGMpKS5s
ZW5ndGg7CiAgICAgICAgfQogICAgICAgIGNvbnN0IHBpbkNudCAgPSBkb2N1bWVudC5nZXRFbGVtZW50
QnlJZCgncGluLWNudCcpOwogICAgICAgIHBpbkNudC50ZXh0Q29udGVudCAgID0gcGlubmVkTjsKICAg
ICAgICBwaW5DbnQuc3R5bGUuZGlzcGxheSA9IHBpbm5lZE4gPyAnJyA6ICdub25lJzsKICAgICAgICAv
LyDmlLbol48gdGFi77yaYmFyIOS4juinkuagh+WQjOS4gOWll+aAu+aVsO+8m+acqua7oemhteaXtuaY
vuekuiDlt7LliqDovb0v5oC75pWwCiAgICAgICAgbGV0IHNob3dUb3RhbCA9IGRpc2tUb3RhbCA+IDAg
PyBkaXNrVG90YWwgOiAobG9hZGVkIHx8IDApOwogICAgICAgIGlmIChjdXJUYWIgPT09ICdwaW5uZWQn
ICYmIHBpbm5lZE4gPiBzaG93VG90YWwpCiAgICAgICAgICAgIHNob3dUb3RhbCA9IHBpbm5lZE47CiAg
ICAgICAgY29uc3QgcU9uID0gU3RyaW5nKHF1ZXJ5IHx8ICcnKS50cmltKCkubGVuZ3RoID4gMDsKICAg
ICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYmFyLXR4dCcpLnRleHRDb250ZW50ID0gcU9uCiAg
ICAgICAgICAgID8gKHNob3duQ291bnQgKyAnIOadoScpCiAgICAgICAgICAgIDogKHNob3dUb3RhbCA+
IGxvYWRlZCA/IChzaG93bkNvdW50ICsgJyAvICcgKyBzaG93VG90YWwgKyAnIOadoScpIDogKHNob3dU
b3RhbCArICcg5p2hJykpOwogICAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdlbXB0eS10eHQn
KS50ZXh0Q29udGVudCA9IEVNUFRZX01TR1tjdXJUYWJdIHx8IEVNUFRZX01TRy5hbGw7CgogICAgICAg
IGNvbnN0IGlkU2V0ID0gbmV3IFNldChhbGxDbGlwcy5tYXAoYyA9PiArYy5pZCkpOwogICAgICAgIG11
bHRpSWRzID0gbXVsdGlJZHMuZmlsdGVyKGlkID0+IGlkU2V0LmhhcyhpZCkpOwogICAgICAgIHVwZGF0
ZU11bHRpQmFkZ2UoKTsKCiAgICAgICAgY29uc3Qgc2hvd24gPSB2aXNpYmxlOwoKICAgICAgICBsaXN0
RWwucXVlcnlTZWxlY3RvckFsbCgnLml0bSwgI2xpc3QtbW9yZScpLmZvckVhY2goZSA9PiBlLnJlbW92
ZSgpKTsKICAgICAgICAvLyDpqqjmnrblt7LlhbPpl63vvJrljbPkvb8gd2FpdGluZyDkuZ/kuI0gcmV0
dXJu77yM5pyJ5pWw5o2u5bCx55u05o6l55S7CiAgICAgICAgaWYgKHNrZWxFbCkgc2tlbEVsLmNsYXNz
TGlzdC5yZW1vdmUoJ29uJyk7CiAgICAgICAgY29uc3QgYXBwQm9vdCA9IGRvY3VtZW50LmdldEVsZW1l
bnRCeUlkKCdhcHAnKTsKICAgICAgICBpZiAoYXBwQm9vdCkgYXBwQm9vdC5jbGFzc0xpc3QucmVtb3Zl
KCdib290LWxvYWRpbmcnKTsKICAgICAgICBpZiAoKHdhaXRpbmdEYXRhIHx8ICFob3N0UHVzaGVkT25j
ZSkgJiYgIXZpc2libGUubGVuZ3RoKSB7CiAgICAgICAgICAgIGVtcHR5RWwuY2xhc3NMaXN0LnJlbW92
ZSgnb24nKTsKICAgICAgICAgICAgdXBkYXRlVG9wQnRuKCk7CiAgICAgICAgICAgIHJldHVybjsKICAg
ICAgICB9CiAgICAgICAgaWYgKCF2aXNpYmxlLmxlbmd0aCkgewogICAgICAgICAgICAvLyBOZXZlciBz
aG9344CM5pqC5peg6K6w5b2V44CNdW50aWwgd2UgaGF2ZSBzZWVuIGEgcmVhbCBub24tZW1wdHkgcHVz
aCwKICAgICAgICAgICAgLy8gb3IgYSBjb25maXJtZWQgZW1wdHkgYWZ0ZXIgd2FybSAoc2F3Tm9uRW1w
dHkgY2FuIGJlIHNldCBieSBlbXB0eS1mYWxsYmFjaykuCiAgICAgICAgICAgIC8vIEZpbHRlcmVkIHNl
YXJjaCB3aXRoIDAgaGl0cyBpcyBhbGxvd2VkIG9uY2UgaG9zdCBwdXNoZWQuCiAgICAgICAgICAgIGNv
bnN0IHFPbiA9IFN0cmluZyhxdWVyeSB8fCAnJykudHJpbSgpLmxlbmd0aCA+IDA7CiAgICAgICAgICAg
IGNvbnN0IGFsbG93RW1wdHkgPSBob3N0UHVzaGVkT25jZSAmJiBzYXdOb25FbXB0eSAmJiAhd2FpdGlu
Z0RhdGEgJiYgIWJvb3RMb2FkaW5nCiAgICAgICAgICAgICAgICAmJiAocU9uIHx8IGRpc2tUb3RhbCA8
PSAwKTsKICAgICAgICAgICAgaWYgKCFhbGxvd0VtcHR5KSB7CiAgICAgICAgICAgICAgICBlbXB0eUVs
LmNsYXNzTGlzdC5yZW1vdmUoJ29uJyk7CiAgICAgICAgICAgICAgICB1cGRhdGVUb3BCdG4oKTsKICAg
ICAgICAgICAgICAgIHJldHVybjsKICAgICAgICAgICAgfQogICAgICAgICAgICBpZiAoc2VsZWN0Rmly
c3RPblNob3cpIHsKICAgICAgICAgICAgICAgIHNlbGVjdEZpcnN0T25TaG93ID0gZmFsc2U7CiAgICAg
ICAgICAgICAgICBzZWxlY3RlZElkID0gMDsKICAgICAgICAgICAgICAgIGNsZWFyTXVsdGkoKTsKICAg
ICAgICAgICAgICAgIGxpc3RFbC5zY3JvbGxUb3AgPSAwOwogICAgICAgICAgICB9CiAgICAgICAgICAg
IGVtcHR5RWwuY2xhc3NMaXN0LmFkZCgnb24nKTsKICAgICAgICAgICAgdXBkYXRlVG9wQnRuKCk7CiAg
ICAgICAgICAgIHJldHVybjsKICAgICAgICB9CiAgICAgICAgZW1wdHlFbC5jbGFzc0xpc3QucmVtb3Zl
KCdvbicpOwogICAgICAgIGNvbnN0IGZyYWcgPSBkb2N1bWVudC5jcmVhdGVEb2N1bWVudEZyYWdtZW50
KCk7CiAgICAgICAgY29uc3QgYmxvY2tzID0gYnVpbGRQaW5uZWRCbG9ja3Moc2hvd24pOwogICAgICAg
IGxldCBudW0gPSAwOwogICAgICAgIGJsb2Nrcy5mb3JFYWNoKGIgPT4gewogICAgICAgICAgICBudW0g
Kz0gMTsKICAgICAgICAgICAgaWYgKGIua2luZCA9PT0gJ2dyb3VwJyAmJiBiLml0ZW1zLmxlbmd0aCA+
IDEpCiAgICAgICAgICAgICAgICBmcmFnLmFwcGVuZENoaWxkKG1ha2VHcm91cEl0ZW0oYi5pdGVtcywg
bnVtKSk7CiAgICAgICAgICAgIGVsc2UKICAgICAgICAgICAgICAgIGZyYWcuYXBwZW5kQ2hpbGQobWFr
ZUl0ZW0oYi5pdGVtc1swXSwgbnVtKSk7CiAgICAgICAgfSk7CiAgICAgICAgbGlzdEVsLmFwcGVuZENo
aWxkKGZyYWcpOwogICAgICAgIG1hcmtRdWV1ZVJhaWxzKCk7CiAgICAgICAgdXBkYXRlTW9yZUZvb3Rl
cihkaXNrVG90YWwpOwogICAgICAgIGlmIChzZWxlY3RGaXJzdE9uU2hvdykgewogICAgICAgICAgICBz
ZWxlY3RGaXJzdE9uU2hvdyA9IGZhbHNlOwogICAgICAgICAgICBzZWxlY3RlZElkID0gdmlzaWJsZVsw
XS5pZDsKICAgICAgICAgICAgY2xlYXJNdWx0aSgpOwogICAgICAgICAgICBsaXN0RWwuc2Nyb2xsVG9w
ID0gMDsKICAgICAgICB9IGVsc2UgaWYgKCF2aXNpYmxlLnNvbWUoYyA9PiBjLmlkID09IHNlbGVjdGVk
SWQpKSB7CiAgICAgICAgICAgIHNlbGVjdGVkSWQgPSB2aXNpYmxlWzBdLmlkOwogICAgICAgICAgICBy
YW5nZUFuY2hvcklkID0gc2VsZWN0ZWRJZDsKICAgICAgICAgICAgcmFuZ2VBbmNob3JDbGlja2VkID0g
ZmFsc2U7CiAgICAgICAgfSBlbHNlIGlmICghcmFuZ2VBbmNob3JJZCkgewogICAgICAgICAgICByYW5n
ZUFuY2hvcklkID0gc2VsZWN0ZWRJZDsKICAgICAgICB9CiAgICAgICAgc3luY0l0ZW1IaWdobGlnaHQo
KTsKICAgICAgICB1cGRhdGVUb3BCdG4oKTsKICAgICAgICBpZiAod2luZG93Ll9fcGVuZGluZ0p1bXBJ
ZCkgewogICAgICAgICAgICBjb25zdCBqaWQgPSArd2luZG93Ll9fcGVuZGluZ0p1bXBJZDsKICAgICAg
ICAgICAgY29uc3QgZWwgPSBsaXN0RWwucXVlcnlTZWxlY3RvcignLm1nLXJvd1tkYXRhLWlkPSInICsg
amlkICsgJyJdJykgfHwgbGlzdEVsLnF1ZXJ5U2VsZWN0b3IoJy5pdG1bZGF0YS1pZD0iJyArIGppZCAr
ICciXScpOwogICAgICAgICAgICBpZiAoZWwpIHsKICAgICAgICAgICAgICAgIHdpbmRvdy5fX3BlbmRp
bmdKdW1wSWQgPSAwOwogICAgICAgICAgICAgICAgd2luZG93Ll9fanVtcExvYWRUcmllcyA9IDA7CiAg
ICAgICAgICAgICAgICBzZWxlY3RlZElkID0gamlkOwogICAgICAgICAgICAgICAgcmVxdWVzdEFuaW1h
dGlvbkZyYW1lKCgpID0+IHsKICAgICAgICAgICAgICAgICAgICBjb25zdCBub2RlID0gbGlzdEVsLnF1
ZXJ5U2VsZWN0b3IoJy5tZy1yb3dbZGF0YS1pZD0iJyArIGppZCArICciXScpIHx8IGxpc3RFbC5xdWVy
eVNlbGVjdG9yKCcuaXRtW2RhdGEtaWQ9IicgKyBqaWQgKyAnIl0nKTsKICAgICAgICAgICAgICAgICAg
ICBpZiAoIW5vZGUpIHJldHVybjsKICAgICAgICAgICAgICAgICAgICBub2RlLnNjcm9sbEludG9WaWV3
KHsgYmxvY2s6ICdjZW50ZXInIH0pOwogICAgICAgICAgICAgICAgICAgIG5vZGUuY2xhc3NMaXN0LmFk
ZCgnanVtcC1mbGFzaCcpOwogICAgICAgICAgICAgICAgICAgIHNldFRpbWVvdXQoKCkgPT4gbm9kZS5j
bGFzc0xpc3QucmVtb3ZlKCdqdW1wLWZsYXNoJyksIDkwMCk7CiAgICAgICAgICAgICAgICAgICAgc3lu
Y0l0ZW1IaWdobGlnaHQoKTsKICAgICAgICAgICAgICAgIH0pOwogICAgICAgICAgICB9IGVsc2UgaWYg
KGFsbENsaXBzLmxlbmd0aCA8IGRpc2tUb3RhbCAmJiAod2luZG93Ll9fanVtcExvYWRUcmllcyB8fCAw
KSA8IDQwKSB7CiAgICAgICAgICAgICAgICB3aW5kb3cuX19qdW1wTG9hZFRyaWVzID0gKHdpbmRvdy5f
X2p1bXBMb2FkVHJpZXMgfHwgMCkgKyAxOwogICAgICAgICAgICAgICAgcmVxdWVzdE1vcmUoKTsKICAg
ICAgICAgICAgfSBlbHNlIGlmIChjdXJUYWIgIT09ICdhbGwnICYmICF3aW5kb3cuX19qdW1wRmVsbEJh
Y2spIHsKICAgICAgICAgICAgICAgIC8vIEl0ZW0gZ29uZSBmcm9tIHRoaXMgdGFiIChlLmcuIHVucGlu
bmVkKSDigJQgZmFsbCBiYWNrIHRvIOWFqOmDqCBvbmNlCiAgICAgICAgICAgICAgICB3aW5kb3cuX19q
dW1wRmVsbEJhY2sgPSB0cnVlOwogICAgICAgICAgICAgICAgd2luZG93Ll9fanVtcExvYWRUcmllcyA9
IDA7CiAgICAgICAgICAgICAgICBjdXJUYWIgPSAnYWxsJzsKICAgICAgICAgICAgICAgIG1hcmtUYWIo
J2FsbCcpOwogICAgICAgICAgICAgICAgcmVxdWVzdFZpZXcoKTsKICAgICAgICAgICAgfSBlbHNlIHsK
ICAgICAgICAgICAgICAgIHdpbmRvdy5fX3BlbmRpbmdKdW1wSWQgPSAwOwogICAgICAgICAgICAgICAg
d2luZG93Ll9fanVtcExvYWRUcmllcyA9IDA7CiAgICAgICAgICAgICAgICBpZiAoYWxsQ2xpcHMuc29t
ZShjID0+ICtjLmlkID09PSBqaWQpKQogICAgICAgICAgICAgICAgICAgIHNlbGVjdGVkSWQgPSBqaWQ7
CiAgICAgICAgICAgICAgICBzeW5jSXRlbUhpZ2hsaWdodCgpOwogICAgICAgICAgICB9CiAgICAgICAg
fQogICAgICAgIHJlcXVlc3RBbmltYXRpb25GcmFtZSgoKSA9PiB7CiAgICAgICAgICAgIGlmIChhbGxD
bGlwcy5sZW5ndGggPCBkaXNrVG90YWwKICAgICAgICAgICAgICAgICYmIGxpc3RFbC5zY3JvbGxIZWln
aHQgPD0gbGlzdEVsLmNsaWVudEhlaWdodCArIDIwKQogICAgICAgICAgICAgICAgcmVxdWVzdE1vcmUo
KTsKICAgICAgICAgICAgc2NoZWR1bGVGaWxlR29uZUNoZWNrKCk7CiAgICAgICAgfSk7CiAgICB9Cgog
ICAgY29uc3QgU1ZHID0gewogICAgICAgIHRleHQ6ICAgYDxzdmcgdmlld0JveD0iMCAwIDI0IDI0IiBm
aWxsPSJub25lIiBzdHJva2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIyIj48cGF0aCBkPSJN
NCA3VjRoMTZ2M005IDIwaDZNMTIgNHYxNiIvPjwvc3ZnPmAsCiAgICAgICAgbWQ6ICAgICBgPHN2ZyB2
aWV3Qm94PSIwIDAgMjQgMjQiIGZpbGw9ImN1cnJlbnRDb2xvciI+PHRleHQgeD0iMTIiIHk9IjE3IiB0
ZXh0LWFuY2hvcj0ibWlkZGxlIiBmb250LXNpemU9IjE1IiBmb250LXdlaWdodD0iODAwIiBmb250LWZh
bWlseT0iU2Vnb2UgVUksTWljcm9zb2Z0IFlhSGVpLHNhbnMtc2VyaWYiPk08L3RleHQ+PC9zdmc+YCwK
ICAgICAgICBpbWFnZTogIGA8c3ZnIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0ibm9uZSIgc3Ryb2tl
PSJjdXJyZW50Q29sb3IiIHN0cm9rZS13aWR0aD0iMS44Ij48cmVjdCB4PSIzIiB5PSI1IiB3aWR0aD0i
MTgiIGhlaWdodD0iMTQiIHJ4PSIyIi8+PGNpcmNsZSBjeD0iOC41IiBjeT0iMTAiIHI9IjEuNSIgZmls
bD0iY3VycmVudENvbG9yIiBzdHJva2U9Im5vbmUiLz48cGF0aCBkPSJNMyAxNmw1LTUgNCA0IDMtMyA2
IDYiLz48L3N2Zz5gLAogICAgICAgIHZpZGVvOiAgYDxzdmcgdmlld0JveD0iMCAwIDI0IDI0IiBmaWxs
PSJub25lIiBzdHJva2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIxLjgiPjxyZWN0IHg9IjMi
IHk9IjYiIHdpZHRoPSIxNCIgaGVpZ2h0PSIxMiIgcng9IjIiLz48cGF0aCBkPSJNMTcgOS41bDQtMi41
djEwbC00LTIuNVY5LjV6IiBmaWxsPSJjdXJyZW50Q29sb3IiIHN0cm9rZT0ibm9uZSIvPjxwYXRoIGQ9
Ik04LjUgMTAuMnYzLjZsMy4yLTEuOC0zLjItMS44eiIgZmlsbD0iY3VycmVudENvbG9yIiBzdHJva2U9
Im5vbmUiLz48L3N2Zz5gLAogICAgICAgIGZvbGRlcjogYDxzdmcgdmlld0JveD0iMCAwIDI0IDI0IiBm
aWxsPSJjdXJyZW50Q29sb3IiPjxwYXRoIGQ9Ik0xMCA0SDRjLTEuMSAwLTIgLjktMiAydjEyYzAgMS4x
LjkgMiAyIDJoMTZjMS4xIDAgMi0uOSAyLTJWOGMwLTEuMS0uOS0yLTItMmgtOGwtMi0yeiIvPjwvc3Zn
PmAsCiAgICAgICAgemlwOiAgICBgPHN2ZyB2aWV3Qm94PSIwIDAgMjQgMjQiIGZpbGw9Im5vbmUiIHN0
cm9rZT0iY3VycmVudENvbG9yIiBzdHJva2Utd2lkdGg9IjEuOCI+PHBhdGggZD0iTTYgM2g5bDUgNXYx
M2ExIDEgMCAwIDEtMSAxSDZhMSAxIDAgMCAxLTEtMVY0YTEgMSAwIDAgMSAxLTF6Ii8+PHBhdGggZD0i
TTE0IDN2Nmg2Ii8+PC9zdmc+YCwKICAgICAgICBhaGs6ICAgIGA8c3ZnIHZpZXdCb3g9IjAgMCAyNCAy
NCIgZmlsbD0iY3VycmVudENvbG9yIj48dGV4dCB4PSIxMiIgeT0iMTciIHRleHQtYW5jaG9yPSJtaWRk
bGUiIGZvbnQtc2l6ZT0iMTQiIGZvbnQtd2VpZ2h0PSI3MDAiPkg8L3RleHQ+PC9zdmc+YCwKICAgICAg
ICBsbms6ICAgIGA8c3ZnIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSJjdXJy
ZW50Q29sb3IiIHN0cm9rZS13aWR0aD0iMS44Ij48cGF0aCBkPSJNMTAgMTNhNSA1IDAgMCAwIDcuMDcg
MGwyLjEyLTIuMTJhNSA1IDAgMCAwLTcuMDctNy4wN0wxMSA1Ii8+PHBhdGggZD0iTTE0IDExYTUgNSAw
IDAgMC03LjA3IDBMNC44IDEzLjEyYTUgNSAwIDEgMCA3LjA3IDcuMDdMMTMgMTkiLz48L3N2Zz5gLAog
ICAgICAgIGRvYzogICAgYDxzdmcgdmlld0JveD0iMCAwIDI0IDI0IiBmaWxsPSJub25lIiBzdHJva2U9
ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIxLjgiPjxwYXRoIGQ9Ik03IDNoN2w1IDV2MTNhMSAx
IDAgMCAxLTEgMUg3YTEgMSAwIDAgMS0xLTFWNGExIDEgMCAwIDEgMS0xeiIvPjxwYXRoIGQ9Ik0xNCAz
djZoNiIvPjwvc3ZnPmAsCiAgICAgICAgbXVsdGk6ICBgPHN2ZyB2aWV3Qm94PSIwIDAgMjQgMjQiIGZp
bGw9Im5vbmUiIHN0cm9rZT0iY3VycmVudENvbG9yIiBzdHJva2Utd2lkdGg9IjEuOCI+PHJlY3QgeD0i
NyIgeT0iNyIgd2lkdGg9IjEyIiBoZWlnaHQ9IjE0IiByeD0iMS41Ii8+PHBhdGggZD0iTTUgMTdWNWEx
IDEgMCAwIDEgMS0xaDEwIi8+PC9zdmc+YAogICAgfTsKCiAgICBmdW5jdGlvbiBmaWxlRXh0KHBhdGgp
IHsKICAgICAgICBjb25zdCBiYXNlID0gU3RyaW5nKHBhdGggfHwgJycpLnNwbGl0KC9bXFwvXS8pLnBv
cCgpIHx8ICcnOwogICAgICAgIGNvbnN0IGkgPSBiYXNlLmxhc3RJbmRleE9mKCcuJyk7CiAgICAgICAg
cmV0dXJuIGkgPiAwID8gYmFzZS5zbGljZShpICsgMSkudG9Mb3dlckNhc2UoKSA6ICcnOwogICAgfQog
ICAgY29uc3QgaXNJbWFnZUV4dCA9IGUgPT4gWydwbmcnLCdqcGcnLCdqcGVnJywnZ2lmJywnd2VicCcs
J2JtcCcsJ2ljbycsJ3RpZicsJ3RpZmYnLCdzdmcnXS5pbmNsdWRlcyhlKTsKICAgIGNvbnN0IGlzVmlk
ZW9FeHQgPSBlID0+IFsnbXA0JywnbWt2JywnYXZpJywnbW92Jywnd212JywnZmx2Jywnd2VibScsJ200
dicsJ21wZWcnLCdtcGcnLCd0cycsJ20ydHMnLCczZ3AnLCdybScsJ3JtdmInXS5pbmNsdWRlcyhlKTsK
ICAgIGNvbnN0IGlzWmlwRXh0ICAgPSBlID0+IFsnemlwJywncmFyJywnN3onLCd0YXInLCdneicsJ2J6
MiddLmluY2x1ZGVzKGUpOwoKICAgIGZ1bmN0aW9uIGljb25Gb3JGaWxlcyhmaWxlcykgewogICAgICAg
IGlmICghZmlsZXMubGVuZ3RoKSAgICByZXR1cm4geyBjbHM6ICdmaWxlIGZ0LWRvYycsIHN2ZzogU1ZH
LmRvYyB9OwogICAgICAgIGlmIChmaWxlcy5sZW5ndGggPiAxKSByZXR1cm4geyBjbHM6ICdmaWxlIGZ0
LWxuaycsIHN2ZzogU1ZHLm11bHRpIH07CiAgICAgICAgY29uc3QgZXh0ID0gZmlsZUV4dChmaWxlc1sw
XSk7CiAgICAgICAgaWYgKCFleHQpICAgICAgICAgICAgICByZXR1cm4geyBjbHM6ICdmaWxlIGZ0LWRp
cicsIHN2ZzogU1ZHLmZvbGRlciB9OwogICAgICAgIGlmIChpc0ltYWdlRXh0KGV4dCkpICAgcmV0dXJu
IHsgY2xzOiAnZmlsZSBmdC1pbWcnLCBzdmc6IFNWRy5pbWFnZSB9OwogICAgICAgIGlmIChpc1ZpZGVv
RXh0KGV4dCkpICAgcmV0dXJuIHsgY2xzOiAnZmlsZSBmdC12aWQnLCBzdmc6IChTVkcudmlkZW8gfHwg
U1ZHLmRvYykgfTsKICAgICAgICBpZiAoaXNaaXBFeHQoZXh0KSkgICAgIHJldHVybiB7IGNsczogJ2Zp
bGUgZnQtemlwJywgc3ZnOiBTVkcuemlwIH07CiAgICAgICAgaWYgKGV4dCA9PT0gJ2FoaycpICAgICBy
ZXR1cm4geyBjbHM6ICdmaWxlIGZ0LWFoaycsIHN2ZzogU1ZHLmFoayB9OwogICAgICAgIGlmIChleHQg
PT09ICdsbmsnKSAgICAgcmV0dXJuIHsgY2xzOiAnZmlsZSBmdC1sbmsnLCBzdmc6IFNWRy5sbmsgfTsK
ICAgICAgICByZXR1cm4geyBjbHM6ICdmaWxlIGZ0LWRvYycsIHN2ZzogU1ZHLmRvYyB9OwogICAgfQoK
ICAgIGZ1bmN0aW9uIHNyY1dpbkxhYmVsKGMpIHsKICAgICAgICBjb25zdCB0ID0gU3RyaW5nKGMgJiYg
Yy5zcmNUaXRsZSB8fCAnJykudHJpbSgpOwogICAgICAgIGlmICh0KSByZXR1cm4gdDsKICAgICAgICBy
ZXR1cm4gU3RyaW5nKGMgJiYgYy5zcmNFeGUgfHwgJycpLnJlcGxhY2UoL1wuZXhlJC9pLCAnJyk7CiAg
ICB9CiAgICBmdW5jdGlvbiBzcmNUaXRsZUh0bWwoYykgewogICAgICAgIC8vIOWIl+ihqOS4remXtC/l
j7PkvqfkuI3lho3mmL7npLrnqpflj6PmoIfpopjvvIzmnaXmupDlj6rkv53nlZnlj7Pkvqflm77moIfm
gqzlgZzmj5DnpLoKICAgICAgICByZXR1cm4gJyc7CiAgICB9CiAgICBmdW5jdGlvbiBleHBhbmRDaGV2
cm9uKG9wZW4pIHsKICAgICAgICByZXR1cm4gb3BlbgogICAgICAgICAgICA/IGA8c3ZnIHZpZXdCb3g9
IjAgMCAxNiAxNiIgd2lkdGg9IjE0IiBoZWlnaHQ9IjE0IiBmaWxsPSJub25lIiBzdHJva2U9ImN1cnJl
bnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIxLjgiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCI+PHBvbHlsaW5l
IHBvaW50cz0iNCAxMCA4IDYgMTIgMTAiLz48L3N2Zz48c3Bhbj7mlLbotbc8L3NwYW4+YAogICAgICAg
ICAgICA6IGA8c3ZnIHZpZXdCb3g9IjAgMCAxNiAxNiIgd2lkdGg9IjE0IiBoZWlnaHQ9IjE0IiBmaWxs
PSJub25lIiBzdHJva2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIxLjgiIHN0cm9rZS1saW5l
Y2FwPSJyb3VuZCI+PHBvbHlsaW5lIHBvaW50cz0iNCA2IDggMTAgMTIgNiIvPjwvc3ZnPjxzcGFuPuWx
leW8gDwvc3Bhbj5gOwogICAgfQogICAgZnVuY3Rpb24gbGlzdEV4cGFuZE1heFB4KCkgewogICAgICAg
IGNvbnN0IGggPSAobGlzdEVsICYmIGxpc3RFbC5jbGllbnRIZWlnaHQpIHx8IDM2MDsKICAgICAgICAv
LyDlh6DkuY7ljaDmu6HliJfooajvvIzlupXpg6jnlZnnuqbkuIDooYwKICAgICAgICByZXR1cm4gTWF0
aC5tYXgoOTYsIGggLSAyOCk7CiAgICB9CiAgICBmdW5jdGlvbiBhcHBseUV4cGFuZGVkUHJldmlldyhw
cmV2LCBmdWxsVGV4dCkgewogICAgICAgIGNvbnN0IG1heEggPSBsaXN0RXhwYW5kTWF4UHgoKTsKICAg
ICAgICBwcmV2LnN0eWxlLm1heEhlaWdodCA9IG1heEggKyAncHgnOwogICAgICAgIHByZXYuY2xhc3NM
aXN0LmFkZCgnZXhwYW5kZWQnKTsKICAgICAgICBzZXRIbFRleHQocHJldiwgZnVsbFRleHQpOwogICAg
ICAgIC8vIOS7jea6ouWHuu+8muaIquaWreW5tuWcqOacq+WwvuWKoOOAjCAuLi7jgI0KICAgICAgICBp
ZiAocHJldi5zY3JvbGxIZWlnaHQgPD0gcHJldi5jbGllbnRIZWlnaHQgKyAyKQogICAgICAgICAgICBy
ZXR1cm47CiAgICAgICAgbGV0IGxvID0gMCwgaGkgPSBmdWxsVGV4dC5sZW5ndGgsIGJlc3QgPSAwOwog
ICAgICAgIHdoaWxlIChsbyA8PSBoaSkgewogICAgICAgICAgICBjb25zdCBtaWQgPSAobG8gKyBoaSkg
Pj4gMTsKICAgICAgICAgICAgc2V0SGxUZXh0KHByZXYsIGZ1bGxUZXh0LnNsaWNlKDAsIG1pZCkgKyAn
IC4uLicpOwogICAgICAgICAgICBpZiAocHJldi5zY3JvbGxIZWlnaHQgPD0gcHJldi5jbGllbnRIZWln
aHQgKyAyKSB7CiAgICAgICAgICAgICAgICBiZXN0ID0gbWlkOwogICAgICAgICAgICAgICAgbG8gPSBt
aWQgKyAxOwogICAgICAgICAgICB9IGVsc2UgewogICAgICAgICAgICAgICAgaGkgPSBtaWQgLSAxOwog
ICAgICAgICAgICB9CiAgICAgICAgfQogICAgICAgIHNldEhsVGV4dChwcmV2LCBmdWxsVGV4dC5zbGlj
ZSgwLCBiZXN0KSArICcgLi4uJyk7CiAgICB9CiAgICBmdW5jdGlvbiBjb2xsYXBzZVByZXZpZXcocHJl
diwgZnVsbFRleHQpIHsKICAgICAgICBwcmV2LmNsYXNzTGlzdC5yZW1vdmUoJ2V4cGFuZGVkJyk7CiAg
ICAgICAgcHJldi5zdHlsZS5tYXhIZWlnaHQgPSAnJzsKICAgICAgICBzZXRIbFRleHQocHJldiwgZnVs
bFRleHQpOwogICAgfQoKICAgIGZ1bmN0aW9uIGZhdkdyb3VwT2YoYykgewogICAgICAgIHJldHVybiBT
dHJpbmcoYyAmJiBjLmZhdkdyb3VwIHx8ICcnKS50cmltKCk7CiAgICB9CiAgICBmdW5jdGlvbiBjbGlw
Q29udGVudFByZXZpZXcoYykgewogICAgICAgIGNvbnN0IHR5cGUgPSBub3JtVHlwZShjLnR5cGUpOwog
ICAgICAgIGlmICh0eXBlID09PSAnaW1hZ2UnKSByZXR1cm4gJ1vlm77lg49dJyArIChjLndpZHRoICYm
IGMuaGVpZ2h0ID8gKCcgJyArIGMud2lkdGggKyAnw5cnICsgYy5oZWlnaHQpIDogJycpOwogICAgICAg
IGlmICh0eXBlID09PSAnZmlsZScpIHsKICAgICAgICAgICAgY29uc3QgZmlsZXMgPSBTdHJpbmcoYy5w
cmV2aWV3IHx8IGMuZGF0YSB8fCAnJykuc3BsaXQoL1xyP1xuLykuZmlsdGVyKEJvb2xlYW4pOwogICAg
ICAgICAgICByZXR1cm4gZmlsZXMubWFwKGYgPT4gZi5zcGxpdCgvW1xcL10vKS5wb3AoKSkuam9pbign
IMK3ICcpIHx8ICdb5paH5Lu2XSc7CiAgICAgICAgfQogICAgICAgIGxldCBfcCA9IFN0cmluZyhjLnBy
ZXZpZXcgfHwgYy5kYXRhIHx8ICcnKTsKICAgICAgICB7IGNvbnN0IF9uID0gTnVtYmVyKGMuY2hhckNv
dW50KSB8fCAwOyBpZiAoX24gPiBfcC5sZW5ndGggJiYgX3AubGVuZ3RoKSBfcCArPSAnLi4uJzsgfQog
ICAgICAgIHJldHVybiBfcDsKICAgIH0KICAgIGZ1bmN0aW9uIGJ1aWxkUGlubmVkQmxvY2tzKGxpc3Qp
IHsKICAgICAgICBjb25zdCB1c2VkID0gbmV3IFNldCgpOwogICAgICAgIGNvbnN0IG91dCA9IFtdOwog
ICAgICAgIGZvciAoY29uc3QgYyBvZiBsaXN0KSB7CiAgICAgICAgICAgIGlmICh1c2VkLmhhcygrYy5p
ZCkpIGNvbnRpbnVlOwogICAgICAgICAgICBjb25zdCBnaWQgPSBmYXZHcm91cE9mKGMpOwogICAgICAg
ICAgICBpZiAoIWdpZCkgewogICAgICAgICAgICAgICAgdXNlZC5hZGQoK2MuaWQpOwogICAgICAgICAg
ICAgICAgb3V0LnB1c2goeyBraW5kOiAnc2luZ2xlJywgaXRlbXM6IFtjXSB9KTsKICAgICAgICAgICAg
ICAgIGNvbnRpbnVlOwogICAgICAgICAgICB9CiAgICAgICAgICAgIGNvbnN0IG1lbWJlcnMgPSBsaXN0
LmZpbHRlcih4ID0+IGZhdkdyb3VwT2YoeCkgPT09IGdpZCk7CiAgICAgICAgICAgIG1lbWJlcnMuZm9y
RWFjaChtID0+IHVzZWQuYWRkKCttLmlkKSk7CiAgICAgICAgICAgIGlmIChtZW1iZXJzLmxlbmd0aCA8
IDIpCiAgICAgICAgICAgICAgICBvdXQucHVzaCh7IGtpbmQ6ICdzaW5nbGUnLCBpdGVtczogW21lbWJl
cnNbMF0gfHwgY10gfSk7CiAgICAgICAgICAgIGVsc2UKICAgICAgICAgICAgICAgIG91dC5wdXNoKHsg
a2luZDogJ2dyb3VwJywgZ2lkLCBpdGVtczogbWVtYmVycyB9KTsKICAgICAgICB9CiAgICAgICAgcmV0
dXJuIG91dDsKICAgIH0KICAgIGZ1bmN0aW9uIF9fcHJlcFBhc3RlKCkgewogICAgICAgIHRyeSB7CiAg
ICAgICAgICAgIGNvbnN0IHMgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc2VhcmNoJyk7CiAgICAg
ICAgICAgIGlmIChzICYmIGRvY3VtZW50LmFjdGl2ZUVsZW1lbnQgPT09IHMpIHRyeSB7IHMuYmx1cigp
OyB9IGNhdGNoIHt9CiAgICAgICAgICAgIGlmICh3aW5kb3cuZ2V0U2VsZWN0aW9uKSB3aW5kb3cuZ2V0
U2VsZWN0aW9uKCkucmVtb3ZlQWxsUmFuZ2VzKCk7CiAgICAgICAgfSBjYXRjaCB7fQogICAgfQogICAg
ZnVuY3Rpb24gcGFzdGVPbmUoYykgewogICAgICAgIF9fcHJlcFBhc3RlKCk7CiAgICAgICAgc2VsZWN0
ZWRJZCA9IGMuaWQ7CiAgICAgICAgaWYgKG11bHRpSWRzLmxlbmd0aCkgY2xlYXJNdWx0aSgpOwogICAg
ICAgIHN5bmNJdGVtSGlnaGxpZ2h0KCk7CiAgICAgICAgbWFya1Bhc3RlZExvY2FsKGMuaWQpOwogICAg
ICAgIGFoaygncGFzdGUnLCBTdHJpbmcoYy5pZCkpOwogICAgfQogICAgZnVuY3Rpb24gb3BlblJlY2Vu
dERpcihwYXRoKSB7CiAgICAgICAgbGV0IHAgPSBTdHJpbmcocGF0aCB8fCAnJykudHJpbSgpOwogICAg
ICAgIGlmICghcCkgcmV0dXJuOwogICAgICAgIGlmICgvXlthLXpBLVpdOiQvLnRlc3QocCkpIHAgKz0g
J1xcJzsKICAgICAgICAvLyDnu5/kuIAgLyDvvJrpgb/lhY0gV2ViVmlldyBob3N0L0pTT04g5ZCD5o6J
5Y+N5pac5p2gCiAgICAgICAgY29uc3Qgd2lyZSA9IHAucmVwbGFjZSgvXFwvZywgJy8nKTsKICAgICAg
ICBjb25zdCBzZW5kID0gKCkgPT4gewogICAgICAgICAgICAvLyAxKSBwb3N0TWVzc2FnZSDmnIDnqLPv
vIjkuI3ov5sgc3luYyBDT03vvIkKICAgICAgICAgICAgdHJ5IHsKICAgICAgICAgICAgICAgIGlmICh3
aW5kb3cuY2hyb21lICYmIGNocm9tZS53ZWJ2aWV3ICYmIHR5cGVvZiBjaHJvbWUud2Vidmlldy5wb3N0
TWVzc2FnZSA9PT0gJ2Z1bmN0aW9uJykgewogICAgICAgICAgICAgICAgICAgIGNocm9tZS53ZWJ2aWV3
LnBvc3RNZXNzYWdlKCdvcGVuRGlyfCcgKyB3aXJlKTsKICAgICAgICAgICAgICAgICAgICByZXR1cm4g
dHJ1ZTsKICAgICAgICAgICAgICAgIH0KICAgICAgICAgICAgfSBjYXRjaCB7fQogICAgICAgICAgICAv
LyAyKSBhc3luYyBob3N077yI6Z2eIHN5bmPvvIkKICAgICAgICAgICAgdHJ5IHsKICAgICAgICAgICAg
ICAgIGNvbnN0IGhvc3QgPSBjaHJvbWUud2Vidmlldy5ob3N0T2JqZWN0cy5haGs7CiAgICAgICAgICAg
ICAgICBpZiAoaG9zdCAmJiBob3N0Lm9wZW5EaXIpIHsKICAgICAgICAgICAgICAgICAgICBQcm9taXNl
LnJlc29sdmUoaG9zdC5vcGVuRGlyKHdpcmUpKS5jYXRjaCgoKSA9PiB7fSk7CiAgICAgICAgICAgICAg
ICAgICAgcmV0dXJuIHRydWU7CiAgICAgICAgICAgICAgICB9CiAgICAgICAgICAgIH0gY2F0Y2gge30K
ICAgICAgICAgICAgLy8gMykg5pyA5ZCO5omNIHN5bmMKICAgICAgICAgICAgdHJ5IHsgYWhrKCdvcGVu
RGlyJywgd2lyZSk7IHJldHVybiB0cnVlOyB9IGNhdGNoIHt9CiAgICAgICAgICAgIHJldHVybiBmYWxz
ZTsKICAgICAgICB9OwogICAgICAgIC8vIOemu+W8gCBwb2ludGVyIOS6i+S7tuagiOWGjeiwg++8jOmB
v+WFjSBXZWJWaWV3MiDlkIzmraXmrbvplIHlr7zoh7TigJzngrnkuobmsqHlj43lupTigJ0KICAgICAg
ICBzZXRUaW1lb3V0KHNlbmQsIDApOwogICAgfQogICAgZnVuY3Rpb24gaXNJdGVtQ2hyb21lVGFyZ2V0
KHQpIHsKICAgICAgICByZXR1cm4gISEodCAmJiB0LmNsb3Nlc3QgJiYgdC5jbG9zZXN0KCcuaS1leHBh
bmQtYnRuLCAuaS1zcmMtaWNvLCAubWctc3JjLCAuZmQtYnRuLCAuZmQtcGF0aCwgLnJmLXNlZywgYnV0
dG9uLCBhLCBpbnB1dCcpKTsKICAgIH0KICAgIGZ1bmN0aW9uIGJlZ2luUGFzdGVGcm9tSXRlbShlLCBj
KSB7CiAgICAgICAgaWYgKGUuYnV0dG9uICE9IG51bGwgJiYgZS5idXR0b24gIT09IDApIHJldHVybjsK
ICAgICAgICBjb25zdCBzZWcgPSBlLnRhcmdldCAmJiBlLnRhcmdldC5jbG9zZXN0ICYmIGUudGFyZ2V0
LmNsb3Nlc3QoJy5yZi1zZWcnKTsKICAgICAgICBpZiAoc2VnKSB7CiAgICAgICAgICAgIGNvbnN0IG9w
ZW5QYXRoID0gc2VnLl9vcGVuUGF0aCB8fCBzZWcuZ2V0QXR0cmlidXRlKCdkYXRhLXBhdGgnKSB8fCBz
ZWcuZGF0YXNldC5vcGVuUGF0aCB8fCAnJzsKICAgICAgICAgICAgaWYgKG9wZW5QYXRoKSB7CiAgICAg
ICAgICAgICAgICBlLnByZXZlbnREZWZhdWx0KCk7CiAgICAgICAgICAgICAgICBlLnN0b3BQcm9wYWdh
dGlvbigpOwogICAgICAgICAgICAgICAgb3BlblJlY2VudERpcihvcGVuUGF0aCk7CiAgICAgICAgICAg
ICAgICByZXR1cm47CiAgICAgICAgICAgIH0KICAgICAgICB9CiAgICAgICAgaWYgKGUudGFyZ2V0ICYm
IGUudGFyZ2V0LmNsb3Nlc3QgJiYgZS50YXJnZXQuY2xvc2VzdCgnLnJmLXBhdGgnKSkKICAgICAgICAg
ICAgcmV0dXJuOwogICAgICAgIGlmIChpc0l0ZW1DaHJvbWVUYXJnZXQoZS50YXJnZXQpKSByZXR1cm47
CiAgICAgICAgaWYgKG5vcm1UeXBlKGMudHlwZSkgPT09ICdyZWNlbnQnKSB7CiAgICAgICAgICAgIGFj
dGl2YXRlQ2xpcEl0ZW0oYyk7CiAgICAgICAgICAgIHJldHVybjsKICAgICAgICB9CiAgICAgICAgaWYg
KGhhbmRsZUl0ZW1DbGljayhlLCBjKSkKICAgICAgICAgICAgcmV0dXJuOwogICAgICAgIF9fcHJlcFBh
c3RlKCk7CiAgICAgICAgc2VsZWN0ZWRJZCA9IGMuaWQ7CiAgICAgICAgcmFuZ2VBbmNob3JJZCA9IGMu
aWQ7CiAgICAgICAgICAgIGlmIChtdWx0aUlkcy5sZW5ndGggPiAwICYmIG11bHRpSWRzLmluY2x1ZGVz
KCtjLmlkKSkgewogICAgICAgICAgICBjb25zdCBpZHMgPSBtdWx0aUlkcy5zbGljZSgpOwogICAgICAg
ICAgICBjbGVhck11bHRpKCk7CiAgICAgICAgICAgIG1hcmtQYXN0ZWRMb2NhbChpZHMpOwogICAgICAg
ICAgICBwYXN0ZU1hbnlXaXRoU2VwKGlkcyk7CiAgICAgICAgICAgIHJldHVybjsKICAgICAgICB9CiAg
ICAgICAgaWYgKG11bHRpSWRzLmxlbmd0aCkgY2xlYXJNdWx0aSgpOwogICAgICAgIHN5bmNJdGVtSGln
aGxpZ2h0KCk7CiAgICAgICAgbWFya1Bhc3RlZExvY2FsKGMuaWQpOwogICAgICAgIGFoaygncGFzdGUn
LCBTdHJpbmcoYy5pZCkpOwogICAgfQogICAgZnVuY3Rpb24gbWFrZUdyb3VwSXRlbShpdGVtcywgaWR4
KSB7CiAgICAgICAgY29uc3QgZWwgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsKICAgICAg
ICBlbC5jbGFzc05hbWUgPSAnaXRtIGl0LWdyb3VwJwogICAgICAgICAgICArIChpdGVtcy5zb21lKGMg
PT4gK2MuaWQgPT09ICtzZWxlY3RlZElkKSA/ICcgc2VsJyA6ICcnKQogICAgICAgICAgICArIChpdGVt
cy5zb21lKGMgPT4gbXVsdGlJZHMuaW5jbHVkZXMoK2MuaWQpKSA/ICcgbXVsdGknIDogJycpOwogICAg
ICAgIGVsLmRhdGFzZXQuZ3JvdXAgPSBmYXZHcm91cE9mKGl0ZW1zWzBdKSB8fCAnJzsKICAgICAgICBl
bC5kYXRhc2V0LmlkID0gaXRlbXNbMF0uaWQ7CgogICAgICAgIGNvbnN0IGhlYWQgPSBkb2N1bWVudC5j
cmVhdGVFbGVtZW50KCdkaXYnKTsKICAgICAgICBoZWFkLmNsYXNzTmFtZSA9ICdtZy1oZWFkJzsKICAg
ICAgICBoZWFkLmlubmVySFRNTCA9ICc8c3BhbiBjbGFzcz0ibWctdGFnIj7lkIjlubY8L3NwYW4+PHNw
YW4+JyArIGl0ZW1zLmxlbmd0aCArICcg5p2hIMK3IOeCueWHu+WNleadoeeymOi0tDwvc3Bhbj4nOwog
ICAgICAgIGVsLmFwcGVuZENoaWxkKGhlYWQpOwoKICAgICAgICBpdGVtcy5mb3JFYWNoKGMgPT4gewog
ICAgICAgICAgICBjb25zdCByb3cgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsKICAgICAg
ICAgICAgcm93LmNsYXNzTmFtZSA9ICdtZy1yb3cnCiAgICAgICAgICAgICAgICArICgrc2VsZWN0ZWRJ
ZCA9PT0gK2MuaWQgPyAnIHNlbCcgOiAnJykKICAgICAgICAgICAgICAgICsgKG11bHRpSWRzLmluY2x1
ZGVzKCtjLmlkKSA/ICcgbXVsdGknIDogJycpOwogICAgICAgICAgICByb3cuZGF0YXNldC5pZCA9IGMu
aWQ7CgogICAgICAgICAgICBjb25zdCB0b3AgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsK
ICAgICAgICAgICAgdG9wLmNsYXNzTmFtZSA9ICdtZy1yb3ctdG9wJzsKICAgICAgICAgICAgY29uc3Qg
bWFpbiA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOwogICAgICAgICAgICBtYWluLmNsYXNz
TmFtZSA9ICdtZy1yb3ctbWFpbic7CgogICAgICAgICAgICBjb25zdCB0aXRsZSA9IFN0cmluZyhjLmZh
dlRpdGxlIHx8ICcnKS50cmltKCk7CiAgICAgICAgICAgIGlmICh0aXRsZSkgewogICAgICAgICAgICAg
ICAgY29uc3QgdCA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOwogICAgICAgICAgICAgICAg
dC5jbGFzc05hbWUgPSAnbWctdGl0bGUnOwogICAgICAgICAgICAgICAgc2V0SGxUZXh0KHQsIHRpdGxl
KTsKICAgICAgICAgICAgICAgIG1haW4uYXBwZW5kQ2hpbGQodCk7CiAgICAgICAgICAgIH0KICAgICAg
ICAgICAgY29uc3QgYm9keSA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOwogICAgICAgICAg
ICBib2R5LmNsYXNzTmFtZSA9ICdtZy1ib2R5JyArIChub3JtVHlwZShjLnR5cGUpID09PSAnaW1hZ2Un
ID8gJyBpbWcnIDogJycpOwogICAgICAgICAgICBzZXRIbFRleHQoYm9keSwgY2xpcENvbnRlbnRQcmV2
aWV3KGMpKTsKICAgICAgICAgICAgbWFpbi5hcHBlbmRDaGlsZChib2R5KTsKICAgICAgICAgICAgdG9w
LmFwcGVuZENoaWxkKG1haW4pOwoKICAgICAgICAgICAgY29uc3Qgc3JjSWNvID0gU3RyaW5nKGMuc3Jj
SWNvbiB8fCAnJyk7CiAgICAgICAgICAgIGNvbnN0IHNyY0V4ZSA9IFN0cmluZyhjLnNyY0V4ZSB8fCAn
Jyk7CiAgICAgICAgICAgIGNvbnN0IHNyY1RpdGxlID0gU3RyaW5nKGMuc3JjVGl0bGUgfHwgJycpOwog
ICAgICAgICAgICBpZiAoc3JjSWNvKSB7CiAgICAgICAgICAgICAgICBjb25zdCBpbWcgPSBkb2N1bWVu
dC5jcmVhdGVFbGVtZW50KCdpbWcnKTsKICAgICAgICAgICAgICAgIGltZy5jbGFzc05hbWUgPSAnbWct
c3JjJzsKICAgICAgICAgICAgICAgIGltZy5zcmMgPSBTVE9SRV9CQVNFICsgZW5jb2RlVVJJQ29tcG9u
ZW50KHNyY0ljbyk7CiAgICAgICAgICAgICAgICBpbWcuYWx0ID0gJyc7CiAgICAgICAgICAgICAgICBj
b25zdCB0aXBUeHQgPSBzcmNUaXRsZSB8fCBzcmNFeGUgfHwgJ+adpea6kCc7CiAgICAgICAgICAgICAg
ICBpbWcudGl0bGUgPSB0aXBUeHQ7CiAgICAgICAgICAgICAgICBpbWcub25jbGljayA9IGUgPT4geyBl
LnByZXZlbnREZWZhdWx0KCk7IGUuc3RvcFByb3BhZ2F0aW9uKCk7IHNob3dTcmNUaXAoaW1nLCB0aXBU
eHQpOyB9OwogICAgICAgICAgICAgICAgdG9wLmFwcGVuZENoaWxkKGltZyk7CiAgICAgICAgICAgIH0K
ICAgICAgICAgICAgcm93LmFwcGVuZENoaWxkKHRvcCk7CgogICAgICAgICAgICByb3cub25wb2ludGVy
ZG93biA9IGUgPT4gewogICAgICAgICAgICAgICAgaWYgKGUuYnV0dG9uICE9PSAwKSByZXR1cm47CiAg
ICAgICAgICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgICAgICAgICAgICAgYmVnaW5QYXN0
ZUZyb21JdGVtKGUsIGMpOwogICAgICAgICAgICB9OwogICAgICAgICAgICByb3cub25jb250ZXh0bWVu
dSA9IGUgPT4gewogICAgICAgICAgICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOwogICAgICAgICAgICAg
ICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICAgICAgICAgIHNlbGVjdGVkSWQgPSBjLmlkOwog
ICAgICAgICAgICAgICAgc2hvd0N0eChlLmNsaWVudFgsIGUuY2xpZW50WSwgYyk7CiAgICAgICAgICAg
IH07CiAgICAgICAgICAgIGVsLmFwcGVuZENoaWxkKHJvdyk7CiAgICAgICAgfSk7CgogICAgICAgIGVs
Lm9uY29udGV4dG1lbnUgPSBlID0+IHsKICAgICAgICAgICAgaWYgKGUudGFyZ2V0LmNsb3Nlc3QoJy5t
Zy1yb3cnKSkgcmV0dXJuOwogICAgICAgICAgICBlLnByZXZlbnREZWZhdWx0KCk7CiAgICAgICAgICAg
IHNlbGVjdGVkSWQgPSBpdGVtc1swXS5pZDsKICAgICAgICAgICAgc2hvd0N0eChlLmNsaWVudFgsIGUu
Y2xpZW50WSwgaXRlbXNbMF0pOwogICAgICAgIH07CiAgICAgICAgcmV0dXJuIGVsOwogICAgfQoKCiAg
ICBmdW5jdGlvbiBidWlsZFJlY2VudFBhdGhDcnVtYnMoY29udGFpbmVyLCBmdWxsUGF0aCkgewogICAg
ICAgIGlmICghY29udGFpbmVyKSByZXR1cm47CiAgICAgICAgY29udGFpbmVyLnF1ZXJ5U2VsZWN0b3JB
bGwoJy5yZi1zZWcsIC5yZi1zZXAnKS5mb3JFYWNoKG4gPT4gbi5yZW1vdmUoKSk7CiAgICAgICAgY29u
c3QgcmF3ID0gU3RyaW5nKGZ1bGxQYXRoIHx8ICcnKS5yZXBsYWNlKC9cLy9nLCAnXFwnKS5yZXBsYWNl
KC9cXCskLywgJycpOwogICAgICAgIGlmICghcmF3KSByZXR1cm47CiAgICAgICAgY29uc3QgdW5jID0g
cmF3LnN0YXJ0c1dpdGgoJ1xcXFwnKTsKICAgICAgICBsZXQgcmVzdCA9IHVuYyA/IHJhdy5zbGljZSgy
KSA6IHJhdzsKICAgICAgICBjb25zdCBwYXJ0cyA9IHJlc3Quc3BsaXQoJ1xcJykuZmlsdGVyKEJvb2xl
YW4pOwogICAgICAgIGNvbnN0IGFkZFNlZyA9IChsYWJlbCwgb3BlblBhdGgpID0+IHsKICAgICAgICAg
ICAgaWYgKGNvbnRhaW5lci5xdWVyeVNlbGVjdG9yKCcucmYtc2VnLCAucmYtc2VwJykpIHsKICAgICAg
ICAgICAgICAgIGNvbnN0IHNlcCA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ3NwYW4nKTsKICAgICAg
ICAgICAgICAgIHNlcC5jbGFzc05hbWUgPSAncmYtc2VwJzsKICAgICAgICAgICAgICAgIHNlcC50ZXh0
Q29udGVudCA9ICdcXCc7CiAgICAgICAgICAgICAgICBjb250YWluZXIuYXBwZW5kQ2hpbGQoc2VwKTsK
ICAgICAgICAgICAgfQogICAgICAgICAgICAvLyBidXR0b27vvJrlkb3kuK3mm7TnqLPvvIzkuI3ooqsg
YXBwLXJlZ2lvbiAvIOeItue6pyBwb2ludGVyIOWQg+aOiQogICAgICAgICAgICBjb25zdCBzZWcgPSBk
b2N1bWVudC5jcmVhdGVFbGVtZW50KCdidXR0b24nKTsKICAgICAgICAgICAgc2VnLnR5cGUgPSAnYnV0
dG9uJzsKICAgICAgICAgICAgc2VnLmNsYXNzTmFtZSA9ICdyZi1zZWcnOwogICAgICAgICAgICBzZXRI
bFRleHQoc2VnLCBsYWJlbCk7CiAgICAgICAgICAgIHNlZy50aXRsZSA9ICfmiZPlvIA6ICcgKyBvcGVu
UGF0aDsKICAgICAgICAgICAgc2VnLnNldEF0dHJpYnV0ZSgnZGF0YS1wYXRoJywgb3BlblBhdGgucmVw
bGFjZSgvXFwvZywgJy8nKSk7CiAgICAgICAgICAgIHNlZy5fb3BlblBhdGggPSBvcGVuUGF0aDsKICAg
ICAgICAgICAgc2VnLmFkZEV2ZW50TGlzdGVuZXIoJ2NsaWNrJywgZSA9PiB7CiAgICAgICAgICAgICAg
ICBlLnByZXZlbnREZWZhdWx0KCk7CiAgICAgICAgICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwog
ICAgICAgICAgICAgICAgb3BlblJlY2VudERpcihvcGVuUGF0aCk7CiAgICAgICAgICAgIH0sIHRydWUp
OwogICAgICAgICAgICBzZWcuYWRkRXZlbnRMaXN0ZW5lcigncG9pbnRlcmRvd24nLCBlID0+IHsKICAg
ICAgICAgICAgICAgIGlmIChlLmJ1dHRvbiAhPT0gMCkgcmV0dXJuOwogICAgICAgICAgICAgICAgZS5w
cmV2ZW50RGVmYXVsdCgpOwogICAgICAgICAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAg
ICAgICAgICAgIG9wZW5SZWNlbnREaXIob3BlblBhdGgpOwogICAgICAgICAgICB9LCB0cnVlKTsKICAg
ICAgICAgICAgY29udGFpbmVyLmFwcGVuZENoaWxkKHNlZyk7CiAgICAgICAgfTsKICAgICAgICBpZiAo
IXBhcnRzLmxlbmd0aCkgewogICAgICAgICAgICBhZGRTZWcocmF3LCByYXcpOwogICAgICAgICAgICBy
ZXR1cm47CiAgICAgICAgfQogICAgICAgIGxldCBhY2MgPSB1bmMgPyAnXFxcXCcgKyBwYXJ0c1swXSA6
IHBhcnRzWzBdOwogICAgICAgIGlmICghdW5jICYmIC9eW2EtekEtWl06JC8udGVzdChwYXJ0c1swXSkp
CiAgICAgICAgICAgIGFjYyA9IHBhcnRzWzBdICsgJ1xcJzsKICAgICAgICBhZGRTZWcocGFydHNbMF0s
IGFjYyk7CiAgICAgICAgZm9yIChsZXQgaSA9IDE7IGkgPCBwYXJ0cy5sZW5ndGg7IGkrKykgewogICAg
ICAgICAgICBhY2MgPSBhY2MucmVwbGFjZSgvXFwrJC8sICcnKSArICdcXCcgKyBwYXJ0c1tpXTsKICAg
ICAgICAgICAgYWRkU2VnKHBhcnRzW2ldLCBhY2MpOwogICAgICAgIH0KICAgIH0KCiAgICBmdW5jdGlv
biBhY3RpdmF0ZUNsaXBJdGVtKGMpIHsKICAgICAgICBpZiAoIWMpIHJldHVybjsKICAgICAgICBpZiAo
bm9ybVR5cGUoYy50eXBlKSA9PT0gJ3JlY2VudCcpIHsKICAgICAgICAgICAgX19wcmVwUGFzdGUoKTsK
ICAgICAgICAgICAgc2VsZWN0ZWRJZCA9IGMuaWQ7CiAgICAgICAgICAgIGlmIChtdWx0aUlkcy5sZW5n
dGgpIGNsZWFyTXVsdGkoKTsKICAgICAgICAgICAgc3luY0l0ZW1IaWdobGlnaHQoKTsKICAgICAgICAg
ICAgYWhrKCdwYXN0ZScsIFN0cmluZyhjLmlkKSk7CiAgICAgICAgICAgIHJldHVybjsKICAgICAgICB9
CiAgICAgICAgcGFzdGVPbmUoYyk7CiAgICB9CiAgICBmdW5jdGlvbiBtYWtlSXRlbShjLCBpZHgpIHsK
ICAgICAgICBjb25zdCB0eXBlICAgPSBub3JtVHlwZShjLnR5cGUpOwogICAgICAgIGNvbnN0IHBpbm5l
ZCA9IGlzUGlubmVkKGMpOwogICAgICAgIGNvbnN0IHBhc3RlZCA9IGlzUGFzdGVkKGMpOwogICAgICAg
IGNvbnN0IGVsICAgICA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOwogICAgICAgIGVsLmNs
YXNzTmFtZSAgPSAnaXRtJwogICAgICAgICAgICArIChzZWxlY3RlZElkID09IGMuaWQgPyAnIHNlbCcg
OiAnJykKICAgICAgICAgICAgKyAobXVsdGlJZHMuaW5jbHVkZXMoK2MuaWQpID8gJyBtdWx0aScgOiAn
Jyk7CiAgICAgICAgZWwuZGF0YXNldC5pZCA9IGMuaWQ7CiAgICAgICAgY29uc3QgcWcgPSBOdW1iZXIo
Yy5xdWV1ZUdyb3VwKSB8fCAwOwogICAgICAgIGlmIChxZyA+IDApIHsKICAgICAgICAgICAgZWwuY2xh
c3NMaXN0LmFkZCgncS1tZW1iZXInKTsKICAgICAgICAgICAgZWwuZGF0YXNldC5xZyA9IFN0cmluZyhx
Zyk7CiAgICAgICAgICAgIGVsLmRhdGFzZXQucWkgPSBTdHJpbmcoTnVtYmVyKGMucXVldWVJbmRleCkg
fHwgMCk7CiAgICAgICAgICAgIGlmIChwYXN0ZWQpIGVsLmNsYXNzTGlzdC5hZGQoJ3EtZG9uZScpOwog
ICAgICAgICAgICBjb25zdCByYWlsID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnc3BhbicpOwogICAg
ICAgICAgICByYWlsLmNsYXNzTmFtZSA9ICdxLXJhaWwnOwogICAgICAgICAgICBjb25zdCBkb3QgPSBk
b2N1bWVudC5jcmVhdGVFbGVtZW50KCdzcGFuJyk7CiAgICAgICAgICAgIGRvdC5jbGFzc05hbWUgPSAn
cS1kb3QnOwogICAgICAgICAgICBkb3QudGl0bGUgPSBwYXN0ZWQgPyAn6Zif5YiX5bey57KY6LS0JyA6
ICfnspjotLTpmJ/liJcnOwogICAgICAgICAgICBlbC5hcHBlbmRDaGlsZChyYWlsKTsKICAgICAgICAg
ICAgZWwuYXBwZW5kQ2hpbGQoZG90KTsKICAgICAgICB9CgogICAgICAgIGNvbnN0IGljbyAgPSBkb2N1
bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsKICAgICAgICBjb25zdCBib2R5ID0gZG9jdW1lbnQuY3Jl
YXRlRWxlbWVudCgnZGl2Jyk7CiAgICAgICAgYm9keS5jbGFzc05hbWUgPSAnaS1ib2R5JzsKCiAgICAg
ICAgaWYgKHR5cGUgPT09ICdpbWFnZScpIHsKICAgICAgICAgICAgaWNvLmNsYXNzTmFtZSA9ICdpLWlj
byBpbWFnZSc7CiAgICAgICAgICAgIGljby5pbm5lckhUTUwgPSBTVkcuaW1hZ2U7CiAgICAgICAgICAg
IGJpbmRJbWdIb3ZlclByZXZpZXcoaWNvLCBjLmlkLCBjLmltZ0ZpbGUpOwogICAgICAgICAgICBjb25z
dCB3cmFwID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnZGl2Jyk7CiAgICAgICAgICAgIHdyYXAuY2xh
c3NOYW1lID0gJ2ktdGh1bWItd3JhcCc7CiAgICAgICAgICAgIGNvbnN0IGltZyAgPSBkb2N1bWVudC5j
cmVhdGVFbGVtZW50KCdpbWcnKTsKICAgICAgICAgICAgaW1nLmNsYXNzTmFtZSA9ICdpLXRodW1iJzsK
ICAgICAgICAgICAgaW1nLmFsdCA9ICcnOwogICAgICAgICAgICBjb25zdCBmaWxlID0gU3RyaW5nKGMu
aW1nRmlsZSB8fCAnJyk7CiAgICAgICAgICAgIGxldCBmYWxsYmFjayA9IFN0cmluZyhjLmRhdGEgfHwg
JycpOwogICAgICAgICAgICAvLyBOZXZlciBzeW5jLWNhbGwgQUhLIHRodW1iIGhlcmUg4oCUIGZyZWV6
ZXMgdGFiIHN3aXRjaGVzOyBQdXNoU3RvcmVUaHVtYnMgZmlsbHMgYXN5bmMKICAgICAgICAgICAgaWYg
KCFmYWxsYmFjay5zdGFydHNXaXRoKCdkYXRhOicpICYmIHRodW1iQ2FjaGUuaGFzKFN0cmluZyhjLmlk
KSkpCiAgICAgICAgICAgICAgICBmYWxsYmFjayA9IFN0cmluZyh0aHVtYkNhY2hlLmdldChTdHJpbmco
Yy5pZCkpKTsKICAgICAgICAgICAgaW1nLm9ubG9hZCA9ICgpID0+IHsKICAgICAgICAgICAgICAgIGNv
bnN0IG13ID0gd3JhcC5jbGllbnRXaWR0aCB8fCAzMDA7CiAgICAgICAgICAgICAgICBjb25zdCBudyA9
IGltZy5uYXR1cmFsV2lkdGggIHx8IDA7CiAgICAgICAgICAgICAgICBjb25zdCBuaCA9IGltZy5uYXR1
cmFsSGVpZ2h0IHx8IDA7CiAgICAgICAgICAgICAgICBpZiAoIW53IHx8ICFuaCkgcmV0dXJuOwogICAg
ICAgICAgICAgICAgY29uc3Qgc2NhbGUgPSBNYXRoLm1pbigxLCAxODAgLyBuaCwgbXcgLyBudyk7CiAg
ICAgICAgICAgICAgICBpbWcuc3R5bGUud2lkdGggID0gTWF0aC5yb3VuZChudyAqIHNjYWxlKSArICdw
eCc7CiAgICAgICAgICAgICAgICBpbWcuc3R5bGUuaGVpZ2h0ID0gTWF0aC5yb3VuZChuaCAqIHNjYWxl
KSArICdweCc7CiAgICAgICAgICAgIH07CiAgICAgICAgICAgIGJpbmRTdG9yZVRodW1iKGltZywgZmls
ZSwgYy5pZCwgZmFsbGJhY2spOwogICAgICAgICAgICB3cmFwLmFwcGVuZENoaWxkKGltZyk7CiAgICAg
ICAgICAgIGNvbnN0IG1ldGEgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsKICAgICAgICAg
ICAgbWV0YS5jbGFzc05hbWUgPSAnaS1tZXRhJzsKICAgICAgICAgICAgbWV0YS5pbm5lckhUTUwgID0g
YDxzcGFuIGNsYXNzPSJpLXRpbWUiPiR7YWdvKGMudGltZSl9PC9zcGFuPiR7bWV0YUNlbnRlckh0bWwo
ZmFsc2UpfTxkaXYgY2xhc3M9ImktbWV0YS1yaWdodCI+JHtjLndpZHRoID8gYDxzcGFuIGNsYXNzPSJp
LXRhZyI+JHtjLndpZHRofcOXJHtjLmhlaWdodH0gcHg8L3NwYW4+YCA6ICcnfTwvZGl2PmA7CiAgICAg
ICAgICAgIGJvZHkuYXBwZW5kQ2hpbGQod3JhcCk7CiAgICAgICAgICAgIGJvZHkuYXBwZW5kQ2hpbGQo
bWV0YSk7CiAgICAgICAgfSBlbHNlIGlmICh0eXBlID09PSAncmVjZW50JykgewogICAgICAgICAgICBp
Y28uY2xhc3NOYW1lID0gJ2ktaWNvIGZpbGUgZnQtZGlyJzsKICAgICAgICAgICAgaWNvLmlubmVySFRN
TCA9IFNWRy5mb2xkZXI7CiAgICAgICAgICAgIGlmIChwaW5uZWQpIGVsLmNsYXNzTGlzdC5hZGQoJ3Jm
LWZpeGVkJyk7CiAgICAgICAgICAgIGNvbnN0IHBhdGggPSBTdHJpbmcoYy5kYXRhIHx8IGMucHJldmll
dyB8fCAnJyk7CiAgICAgICAgICAgIGNvbnN0IGNydW1icyA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQo
J2RpdicpOwogICAgICAgICAgICBjcnVtYnMuY2xhc3NOYW1lID0gJ3JmLXBhdGgnOwogICAgICAgICAg
ICBidWlsZFJlY2VudFBhdGhDcnVtYnMoY3J1bWJzLCBwYXRoKTsKICAgICAgICAgICAgLy8g5Zu65a6a
5qCH6K6w5Y+q5pS+IG1ldGEg5Y+z5L6n77yM5LiN5oyh6Lev5b6ECiAgICAgICAgICAgIGNvbnN0IG1l
dGEgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsKICAgICAgICAgICAgbWV0YS5jbGFzc05h
bWUgPSAnaS1tZXRhJzsKICAgICAgICAgICAgbWV0YS5pbm5lckhUTUwgPQogICAgICAgICAgICAgICAg
YDxzcGFuIGNsYXNzPSJpLXRpbWUiPiR7YWdvKGMudGltZSl9PC9zcGFuPmAgKwogICAgICAgICAgICAg
ICAgbWV0YUNlbnRlckh0bWwoZmFsc2UpICsKICAgICAgICAgICAgICAgIGA8ZGl2IGNsYXNzPSJpLW1l
dGEtcmlnaHQiPiR7cGlubmVkID8gJzxzcGFuIGNsYXNzPSJyZi1waW4tdGFnIiB0aXRsZT0i5bey5Zu6
5a6a77yM5LiN5Lya6KKr5reY5rGwIj7lm7rlrpo8L3NwYW4+JyA6ICcnfTwvZGl2PmA7CiAgICAgICAg
ICAgIGJvZHkuYXBwZW5kQ2hpbGQoY3J1bWJzKTsKICAgICAgICAgICAgYm9keS5hcHBlbmRDaGlsZCht
ZXRhKTsKICAgICAgICB9IGVsc2UgaWYgKHR5cGUgPT09ICdmaWxlJykgewogICAgICAgICAgICBjb25z
dCBmaWxlcyA9IFN0cmluZyhjLnByZXZpZXcgfHwgYy5kYXRhIHx8ICcnKS5zcGxpdCgvXHI/XG4vKS5m
aWx0ZXIoQm9vbGVhbik7CiAgICAgICAgICAgIGNvbnN0IGltYWdlUGF0aHMgPSBmaWxlcy5maWx0ZXIo
ZiA9PiBpc0ltYWdlRXh0KGZpbGVFeHQoZikpKTsKICAgICAgICAgICAgY29uc3QgaWMgICAgPSBpY29u
Rm9yRmlsZXMoZmlsZXMpOwogICAgICAgICAgICBpY28uY2xhc3NOYW1lID0gJ2ktaWNvICcgKyBpYy5j
bHM7CiAgICAgICAgICAgIGljby5pbm5lckhUTUwgPSBpYy5zdmc7CgogICAgICAgICAgICBsZXQgdGh1
bWJGaWxlID0gU3RyaW5nKGMuaW1nRmlsZSB8fCAnJyk7CiAgICAgICAgICAgIC8qIGVuc3VyZUZpbGVJ
bWcgZGVmZXJyZWQ6IGF2b2lkIHN5bmMgZnJlZXplIG9uIGZpbGUgdGFiICovCgogICAgICAgICAgICAv
LyBJbWFnZS1mb3JtYXQgZmlsZXM6IHNhbWUgdGh1bWJuYWlsIHJ1bGVzIGFzIHNjcmVlbnNob3QgY2xp
cHMKICAgICAgICAgICAgaWYgKHRodW1iRmlsZSB8fCBpbWFnZVBhdGhzLmxlbmd0aCkgewogICAgICAg
ICAgICAgICAgY29uc3Qgd3JhcCA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOwogICAgICAg
ICAgICAgICAgd3JhcC5jbGFzc05hbWUgPSAnaS10aHVtYi13cmFwJzsKICAgICAgICAgICAgICAgIGNv
bnN0IGltZyAgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdpbWcnKTsKICAgICAgICAgICAgICAgIGlt
Zy5jbGFzc05hbWUgPSAnaS10aHVtYic7CiAgICAgICAgICAgICAgICBpbWcuYWx0ID0gJyc7CiAgICAg
ICAgICAgICAgICBpbWcub25sb2FkID0gKCkgPT4gewogICAgICAgICAgICAgICAgICAgIGNvbnN0IG13
ID0gd3JhcC5jbGllbnRXaWR0aCB8fCAzMDA7CiAgICAgICAgICAgICAgICAgICAgY29uc3QgbncgPSBp
bWcubmF0dXJhbFdpZHRoICB8fCAwOwogICAgICAgICAgICAgICAgICAgIGNvbnN0IG5oID0gaW1nLm5h
dHVyYWxIZWlnaHQgfHwgMDsKICAgICAgICAgICAgICAgICAgICBpZiAoIW53IHx8ICFuaCkgcmV0dXJu
OwogICAgICAgICAgICAgICAgICAgIGNvbnN0IHNjYWxlID0gTWF0aC5taW4oMSwgMTgwIC8gbmgsIG13
IC8gbncpOwogICAgICAgICAgICAgICAgICAgIGltZy5zdHlsZS53aWR0aCAgPSBNYXRoLnJvdW5kKG53
ICogc2NhbGUpICsgJ3B4JzsKICAgICAgICAgICAgICAgICAgICBpbWcuc3R5bGUuaGVpZ2h0ID0gTWF0
aC5yb3VuZChuaCAqIHNjYWxlKSArICdweCc7CiAgICAgICAgICAgICAgICB9OwogICAgICAgICAgICAv
KiBlbnN1cmVGaWxlSW1nIGRlZmVycmVkOiBhdm9pZCBzeW5jIGZyZWV6ZSBvbiBmaWxlIHRhYiAqLwog
ICAgICAgICAgICAgICAgYmluZFN0b3JlVGh1bWIoaW1nLCB0aHVtYkZpbGUsIGMuaWQsICcnKTsKICAg
ICAgICAgICAgICAgIHdyYXAuYXBwZW5kQ2hpbGQoaW1nKTsKICAgICAgICAgICAgICAgIGJvZHkuYXBw
ZW5kQ2hpbGQod3JhcCk7CiAgICAgICAgICAgIH0KCiAgICAgICAgICAgIGNvbnN0IG5hbWUgPSBkb2N1
bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsKICAgICAgICAgICAgbmFtZS5jbGFzc05hbWUgID0gJ2kt
bmFtZSc7CiAgICAgICAgICAgIHNldEhsVGV4dChuYW1lLCBmaWxlcy5tYXAoZiA9PiBmLnNwbGl0KC9b
XFwvXS8pLnBvcCgpKS5qb2luKCdcbicpIHx8ICco5paH5Lu2KScpOwoKICAgICAgICAgICAgZWwuX2Zp
bGVQYXRocyA9IGZpbGVzOwoKICAgICAgICAgICAgY29uc3QgZGV0YWlsID0gZG9jdW1lbnQuY3JlYXRl
RWxlbWVudCgnZGl2Jyk7CiAgICAgICAgICAgIGRldGFpbC5jbGFzc05hbWUgPSAnaS1maWxlLWRldGFp
bCc7CgogICAgICAgICAgICBjb25zdCBtZXRhID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnZGl2Jyk7
CiAgICAgICAgICAgIG1ldGEuY2xhc3NOYW1lID0gJ2ktbWV0YSc7CiAgICAgICAgICAgIGxldCByaWdo
dCA9ICcnOwogICAgICAgICAgICByaWdodCArPSBgPHNwYW4gY2xhc3M9ImktdGFnIj4ke2MuZmlsZUNv
dW50IHx8IGZpbGVzLmxlbmd0aCB8fCAxfSDkuKrmlofku7Y8L3NwYW4+YDsKICAgICAgICAgICAgaWYg
KCh0aHVtYkZpbGUgfHwgaW1hZ2VQYXRocy5sZW5ndGgpICYmIGMud2lkdGgpCiAgICAgICAgICAgICAg
ICByaWdodCArPSBgPHNwYW4gY2xhc3M9ImktdGFnIj4ke2Mud2lkdGh9w5cke2MuaGVpZ2h0fSBweDwv
c3Bhbj5gOwogICAgICAgICAgICBjb25zdCBleHBhbmRIdG1sID0gZXhwYW5kQ2hldnJvbihmYWxzZSk7
CiAgICAgICAgICAgIGNvbnN0IGNvbGxhcHNlSHRtbCA9IGV4cGFuZENoZXZyb24odHJ1ZSk7CiAgICAg
ICAgICAgIG1ldGEuaW5uZXJIVE1MID0KICAgICAgICAgICAgICAgIGA8c3BhbiBjbGFzcz0iaS10aW1l
Ij4ke2FnbyhjLnRpbWUpfTwvc3Bhbj5gICsKICAgICAgICAgICAgICAgIG1ldGFDZW50ZXJIdG1sKHsg
b246IHRydWUsIGh0bWw6IGV4cGFuZEh0bWwgfSkgKwogICAgICAgICAgICAgICAgYDxkaXYgY2xhc3M9
ImktbWV0YS1yaWdodCI+JHtyaWdodH08L2Rpdj5gOwoKICAgICAgICAgICAgY29uc3QgZXhwQnRuID0g
bWV0YS5xdWVyeVNlbGVjdG9yKCcuaS1leHBhbmQtYnRuJyk7CiAgICAgICAgICAgIGxldCBkZXRhaWxC
dWlsdCA9IGZhbHNlOwogICAgICAgICAgICBleHBCdG4ub25jbGljayA9IGUgPT4gewogICAgICAgICAg
ICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOwogICAgICAgICAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24o
KTsKICAgICAgICAgICAgICAgIGNvbnN0IG9wZW4gPSAhZGV0YWlsLmNsYXNzTGlzdC5jb250YWlucygn
b24nKTsKICAgICAgICAgICAgICAgIGlmIChvcGVuICYmICFkZXRhaWxCdWlsdCkgewogICAgICAgICAg
ICAgICAgICAgIGNvbnN0IHBhdGhSb3dzID0gZWwuX3BhdGhSb3dzIHx8IGNoZWNrRmlsZVBhdGhzKGVs
Ll9maWxlUGF0aHMgfHwgZmlsZXMpOwogICAgICAgICAgICAgICAgICAgIGZpbGxGaWxlRGV0YWlsUGFu
ZWwoZGV0YWlsLCBwYXRoUm93cyk7CiAgICAgICAgICAgICAgICAgICAgZGV0YWlsQnVpbHQgPSB0cnVl
OwogICAgICAgICAgICAgICAgfQogICAgICAgICAgICAgICAgZGV0YWlsLmNsYXNzTGlzdC50b2dnbGUo
J29uJywgb3Blbik7CiAgICAgICAgICAgICAgICBpZiAob3BlbikgewogICAgICAgICAgICAgICAgICAg
IGRldGFpbC5zdHlsZS5tYXhIZWlnaHQgPSBsaXN0RXhwYW5kTWF4UHgoKSArICdweCc7CiAgICAgICAg
ICAgICAgICAgICAgZGV0YWlsLnN0eWxlLm92ZXJmbG93ID0gJ2F1dG8nOwogICAgICAgICAgICAgICAg
fSBlbHNlIHsKICAgICAgICAgICAgICAgICAgICBkZXRhaWwuc3R5bGUubWF4SGVpZ2h0ID0gJyc7CiAg
ICAgICAgICAgICAgICAgICAgZGV0YWlsLnN0eWxlLm92ZXJmbG93ID0gJyc7CiAgICAgICAgICAgICAg
ICB9CiAgICAgICAgICAgICAgICBleHBCdG4uaW5uZXJIVE1MID0gb3BlbiA/IGNvbGxhcHNlSHRtbCA6
IGV4cGFuZEh0bWw7CiAgICAgICAgICAgIH07CgogICAgICAgICAgICBib2R5LmFwcGVuZENoaWxkKG5h
bWUpOwogICAgICAgICAgICBib2R5LmFwcGVuZENoaWxkKGRldGFpbCk7CiAgICAgICAgICAgIGJvZHku
YXBwZW5kQ2hpbGQobWV0YSk7CiAgICAgICAgfSBlbHNlIHsKICAgICAgICAgICAgY29uc3QgdXNlTSA9
IGNsaXBVc2VzTUljb24oYyk7CiAgICAgICAgICAgIGljby5jbGFzc05hbWUgPSB1c2VNID8gJ2ktaWNv
IG1kJyA6ICdpLWljbyB0ZXh0JzsKICAgICAgICAgICAgaWNvLmlubmVySFRNTCA9IHVzZU0gPyAoU1ZH
Lm1kIHx8IFNWRy50ZXh0KSA6IFNWRy50ZXh0OwogICAgICAgICAgICAvKiBwbGFpbi1saXN0LXByZXYg
Ki8KICAgICAgICAgICAgLyogcHJldmlldy1lbGxpcHNpcyAqLwogICAgICAgICAgICBsZXQgdHh0ICA9
IGMucHJldmlldyB8fCBjLmRhdGEgfHwgJyc7CiAgICAgICAgICAgIHsgY29uc3QgX24gPSBOdW1iZXIo
Yy5jaGFyQ291bnQpIHx8IDA7IGlmIChfbiA+IHR4dC5sZW5ndGggJiYgdHh0Lmxlbmd0aCkgdHh0ICs9
ICcuLi4nOyB9CiAgICAgICAgICAgIGNvbnN0IHByZXYgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdk
aXYnKTsKICAgICAgICAgICAgcHJldi5jbGFzc05hbWUgID0gJ2ktcHJldicgKyAoaXNVcmwodHh0KSA/
ICcgdXJsJyA6ICcnKTsKICAgICAgICAgICAgc2V0SGxUZXh0KHByZXYsIHR4dCk7CgogICAgICAgICAg
ICBjb25zdCBtZXRhID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnZGl2Jyk7CiAgICAgICAgICAgIG1l
dGEuY2xhc3NOYW1lID0gJ2ktbWV0YSc7CgogICAgICAgICAgICBjb25zdCBjaGFycyA9IE51bWJlcihj
LmNoYXJDb3VudCkgfHwgMDsKICAgICAgICAgICAgY29uc3QgcmlnaHRIVE1MID0gYDxzcGFuIGNsYXNz
PSJpLWNoYXJzIj48c3BhbiBjbGFzcz0ibiI+JHtjaGFyc308L3NwYW4+IOWtl+espjwvc3Bhbj5gOwoK
ICAgICAgICAgICAgbWV0YS5pbm5lckhUTUwgPQogICAgICAgICAgICAgICAgYDxzcGFuIGNsYXNzPSJp
LXRpbWUiPiR7YWdvKGMudGltZSl9PC9zcGFuPmAgKwogICAgICAgICAgICAgICAgbWV0YUNlbnRlckh0
bWwoewogICAgICAgICAgICAgICAgICAgIG9uOiBmYWxzZSwKICAgICAgICAgICAgICAgICAgICBodG1s
OiBleHBhbmRDaGV2cm9uKGZhbHNlKQogICAgICAgICAgICAgICAgfSkgKwogICAgICAgICAgICAgICAg
YDxkaXYgY2xhc3M9ImktbWV0YS1yaWdodCB0ZXh0LW1ldGEiPiR7cmlnaHRIVE1MfTwvZGl2PmA7Cgog
ICAgICAgICAgICBib2R5LmFwcGVuZENoaWxkKHByZXYpOwogICAgICAgICAgICBib2R5LmFwcGVuZENo
aWxkKG1ldGEpOwoKICAgICAgICAgICAgY29uc3QgZXhwQnRuID0gbWV0YS5xdWVyeVNlbGVjdG9yKCcu
aS1leHBhbmQtYnRuJyk7CiAgICAgICAgICAgIGlmIChleHBCdG4pIHsKICAgICAgICAgICAgICAgIGV4
cEJ0bi5vbmNsaWNrID0gZSA9PiB7CiAgICAgICAgICAgICAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24o
KTsKICAgICAgICAgICAgICAgICAgICBjb25zdCB3aWxsRXhwYW5kID0gIXByZXYuY2xhc3NMaXN0LmNv
bnRhaW5zKCdleHBhbmRlZCcpOwogICAgICAgICAgICAgICAgICAgIGlmICh3aWxsRXhwYW5kKSB7CiAg
ICAgICAgICAgICAgICAgICAgICAgIGFwcGx5RXhwYW5kZWRQcmV2aWV3KHByZXYsIHR4dCk7CiAgICAg
ICAgICAgICAgICAgICAgICAgIGV4cEJ0bi5pbm5lckhUTUwgPSBleHBhbmRDaGV2cm9uKHRydWUpOwog
ICAgICAgICAgICAgICAgICAgICAgICB0cnkgeyBlbC5zY3JvbGxJbnRvVmlldyh7IGJsb2NrOiAnbmVh
cmVzdCcgfSk7IH0gY2F0Y2gge30KICAgICAgICAgICAgICAgICAgICB9IGVsc2UgewogICAgICAgICAg
ICAgICAgICAgICAgICBjb2xsYXBzZVByZXZpZXcocHJldiwgdHh0KTsKICAgICAgICAgICAgICAgICAg
ICAgICAgZXhwQnRuLmlubmVySFRNTCA9IGV4cGFuZENoZXZyb24oZmFsc2UpOwogICAgICAgICAgICAg
ICAgICAgIH0KICAgICAgICAgICAgICAgIH07CiAgICAgICAgICAgICAgICBjb25zdCBjaGVja092ZXJm
bG93ID0gKCkgPT4gewogICAgICAgICAgICAgICAgICAgIGNvbnN0IHBsYWluTGVuID0gU3RyaW5nKGMu
cHJldmlldyB8fCBjLmRhdGEgfHwgJycpLmxlbmd0aDsKICAgICAgICAgICAgICAgICAgICBjb25zdCBm
dWxsTiA9IE51bWJlcihjLmNoYXJDb3VudCkgfHwgMDsKICAgICAgICAgICAgICAgICAgICBjb25zdCB0
cnVuYyA9IGZ1bGxOID4gcGxhaW5MZW47CiAgICAgICAgICAgICAgICAgICAgaWYgKHByZXYuc2Nyb2xs
SGVpZ2h0ID4gcHJldi5jbGllbnRIZWlnaHQgKyAyIHx8IHRydW5jKQogICAgICAgICAgICAgICAgICAg
ICAgICBleHBCdG4uY2xhc3NMaXN0LmFkZCgnb24nKTsKICAgICAgICAgICAgICAgICAgICBlbHNlCiAg
ICAgICAgICAgICAgICAgICAgICAgIGV4cEJ0bi5jbGFzc0xpc3QucmVtb3ZlKCdvbicpOwogICAgICAg
ICAgICAgICAgfTsKICAgICAgICAgICAgICAgIHJlcXVlc3RBbmltYXRpb25GcmFtZShjaGVja092ZXJm
bG93KTsKICAgICAgICAgICAgICAgIHNldFRpbWVvdXQoY2hlY2tPdmVyZmxvdywgODApOwogICAgICAg
ICAgICB9CiAgICAgICAgfQoKICAgICAgICBjb25zdCBmYXZUID0gU3RyaW5nKGMuZmF2VGl0bGUgfHwg
JycpLnRyaW0oKTsKICAgICAgICBpZiAoZmF2VCkgewogICAgICAgICAgICBjb25zdCBmdCA9IGRvY3Vt
ZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOwogICAgICAgICAgICBmdC5jbGFzc05hbWUgPSAnaS1mYXYt
dGl0bGUnOwogICAgICAgICAgICBzZXRIbFRleHQoZnQsIGZhdlQpOwogICAgICAgICAgICBib2R5Lmlu
c2VydEJlZm9yZShmdCwgYm9keS5maXJzdENoaWxkKTsKICAgICAgICB9CgogICAgICAgIGlmIChwYXN0
ZWQpIHsKICAgICAgICAgICAgZWwuY2xhc3NMaXN0LmFkZCgncGFzdGVkJyk7CiAgICAgICAgICAgIGNv
bnN0IGJhZGdlID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnc3BhbicpOwogICAgICAgICAgICBiYWRn
ZS5jbGFzc05hbWUgPSAnaS11c2VkJzsKICAgICAgICAgICAgYmFkZ2UudGl0bGUgPSAn5bey57KY6LS0
JzsKICAgICAgICAgICAgYmFkZ2UuaW5uZXJIVE1MID0gYDxzdmcgdmlld0JveD0iMCAwIDE2IDE2IiBm
aWxsPSJub25lIiBzdHJva2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIyLjQiIHN0cm9rZS1s
aW5lY2FwPSJyb3VuZCIgc3Ryb2tlLWxpbmVqb2luPSJyb3VuZCI+PHBvbHlsaW5lIHBvaW50cz0iMy41
IDguNSA2LjUgMTEuNSAxMi41IDQuNSIvPjwvc3ZnPmA7CiAgICAgICAgICAgIGljby5hcHBlbmRDaGls
ZChiYWRnZSk7CiAgICAgICAgfQoKICAgICAgICBjb25zdCBudW0gPSBkb2N1bWVudC5jcmVhdGVFbGVt
ZW50KCdkaXYnKTsKICAgICAgICBudW0uY2xhc3NOYW1lID0gJ2ktbnVtJzsKICAgICAgICBjb25zdCBu
dW1UeHQgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdzcGFuJyk7CiAgICAgICAgbnVtVHh0LnRleHRD
b250ZW50ID0gaWR4OwogICAgICAgIG51bS5hcHBlbmRDaGlsZChudW1UeHQpOwogICAgICAgIGNvbnN0
IHNyY0ljbyA9IFN0cmluZyhjLnNyY0ljb24gfHwgJycpOwogICAgICAgIGNvbnN0IHNyY0V4ZSA9IFN0
cmluZyhjLnNyY0V4ZSB8fCAnJyk7CiAgICAgICAgY29uc3Qgc3JjVGl0bGUgPSBTdHJpbmcoYy5zcmNU
aXRsZSB8fCAnJyk7CiAgICAgICAgaWYgKHNyY0ljbykgewogICAgICAgICAgICBjb25zdCBpbWcgPSBk
b2N1bWVudC5jcmVhdGVFbGVtZW50KCdpbWcnKTsKICAgICAgICAgICAgaW1nLmNsYXNzTmFtZSA9ICdp
LXNyYy1pY28nOwogICAgICAgICAgICBpbWcuc3JjID0gU1RPUkVfQkFTRSArIGVuY29kZVVSSUNvbXBv
bmVudChzcmNJY28pOwogICAgICAgICAgICBpbWcuYWx0ID0gJyc7CiAgICAgICAgICAgIGNvbnN0IHRp
cFR4dCA9IHNyY1RpdGxlIHx8IHNyY0V4ZSB8fCAn5p2l5rqQJzsKICAgICAgICAgICAgaW1nLnRpdGxl
ID0gdGlwVHh0OwogICAgICAgICAgICBpbWcub25jbGljayA9IGUgPT4geyBlLnByZXZlbnREZWZhdWx0
KCk7IGUuc3RvcFByb3BhZ2F0aW9uKCk7IHNob3dTcmNUaXAoaW1nLCB0aXBUeHQpOyB9OwogICAgICAg
ICAgICBudW0uYXBwZW5kQ2hpbGQoaW1nKTsKICAgICAgICB9CgogICAgICAgIGVsLmFwcGVuZENoaWxk
KGljbyk7CiAgICAgICAgZWwuYXBwZW5kQ2hpbGQoYm9keSk7CiAgICAgICAgZWwuYXBwZW5kQ2hpbGQo
bnVtKTsKCiAgICAgICAgZWwub25wb2ludGVyZG93biA9IGUgPT4gewogICAgICAgICAgICBiZWdpblBh
c3RlRnJvbUl0ZW0oZSwgYyk7CiAgICAgICAgfTsKICAgICAgICBlbC5vbmNvbnRleHRtZW51ID0gZSA9
PiB7CiAgICAgICAgICAgIGUucHJldmVudERlZmF1bHQoKTsKICAgICAgICAgICAgc2VsZWN0ZWRJZCA9
IGMuaWQ7CiAgICAgICAgICAgIHNob3dDdHgoZS5jbGllbnRYLCBlLmNsaWVudFksIGMpOwogICAgICAg
IH07CgogICAgICAgIHJldHVybiBlbDsKICAgIH0KCiAgICBmdW5jdGlvbiBpdGVtSXNRdWV1ZURvbmUo
cm93KSB7CiAgICAgICAgaWYgKCFyb3cpIHJldHVybiBmYWxzZTsKICAgICAgICBpZiAocm93LmNsYXNz
TGlzdC5jb250YWlucygncGFzdGVkJykgfHwgcm93LmNsYXNzTGlzdC5jb250YWlucygncS1kb25lJykp
CiAgICAgICAgICAgIHJldHVybiB0cnVlOwogICAgICAgIGNvbnN0IGlkID0gK3Jvdy5kYXRhc2V0Lmlk
OwogICAgICAgIGNvbnN0IGMgPSBhbGxDbGlwcy5maW5kKHggPT4gK3guaWQgPT09IGlkKTsKICAgICAg
ICByZXR1cm4gISEoYyAmJiBpc1Bhc3RlZChjKSk7CiAgICB9CgogICAgZnVuY3Rpb24gbWFya1F1ZXVl
UmFpbHMoKSB7CiAgICAgICAgaWYgKCFsaXN0RWwpIHJldHVybjsKICAgICAgICBjb25zdCBub2RlcyA9
IFsuLi5saXN0RWwucXVlcnlTZWxlY3RvckFsbCgnLml0bS5xLW1lbWJlcicpXTsKICAgICAgICBpZiAo
IW5vZGVzLmxlbmd0aCkgcmV0dXJuOwogICAgICAgIC8vIFJlc2V0IGxpbmsgY2xhc3Nlczsga2VlcCBz
dHJ1Y3R1cmFsIGVuZHMKICAgICAgICBub2Rlcy5mb3JFYWNoKG4gPT4gbi5jbGFzc0xpc3QucmVtb3Zl
KCdxLWZpcnN0JywgJ3EtbGFzdCcsICdxLW9ubHknLCAncS1kb25lLWxpbmsnLCAncS1wYXN0ZWQtbmV4
dCcpKTsKICAgICAgICAvLyBHcm91cCBjb25zZWN1dGl2ZSBzYW1lIHF1ZXVlR3JvdXAgaW4gRE9NIG9y
ZGVyCiAgICAgICAgbGV0IGkgPSAwOwogICAgICAgIHdoaWxlIChpIDwgbm9kZXMubGVuZ3RoKSB7CiAg
ICAgICAgICAgIGNvbnN0IGcgPSBub2Rlc1tpXS5kYXRhc2V0LnFnOwogICAgICAgICAgICBsZXQgaiA9
IGkgKyAxOwogICAgICAgICAgICB3aGlsZSAoaiA8IG5vZGVzLmxlbmd0aCAmJiBub2Rlc1tqXS5kYXRh
c2V0LnFnID09PSBnKSBqKys7CiAgICAgICAgICAgIGNvbnN0IHNsaWNlID0gbm9kZXMuc2xpY2UoaSwg
aik7CiAgICAgICAgICAgIGlmIChzbGljZS5sZW5ndGggPT09IDEpIHsKICAgICAgICAgICAgICAgIHNs
aWNlWzBdLmNsYXNzTGlzdC5hZGQoJ3Etb25seScpOwogICAgICAgICAgICB9IGVsc2UgewogICAgICAg
ICAgICAgICAgc2xpY2VbMF0uY2xhc3NMaXN0LmFkZCgncS1maXJzdCcpOwogICAgICAgICAgICAgICAg
c2xpY2Vbc2xpY2UubGVuZ3RoIC0gMV0uY2xhc3NMaXN0LmFkZCgncS1sYXN0Jyk7CiAgICAgICAgICAg
IH0KICAgICAgICAgICAgZm9yIChsZXQgayA9IDA7IGsgPCBzbGljZS5sZW5ndGg7IGsrKykgewogICAg
ICAgICAgICAgICAgY29uc3QgZG9uZSA9IGl0ZW1Jc1F1ZXVlRG9uZShzbGljZVtrXSk7CiAgICAgICAg
ICAgICAgICBzbGljZVtrXS5jbGFzc0xpc3QudG9nZ2xlKCdxLWRvbmUnLCBkb25lKTsKICAgICAgICAg
ICAgICAgIGNvbnN0IGRvdCA9IHNsaWNlW2tdLnF1ZXJ5U2VsZWN0b3IoJy5xLWRvdCcpOwogICAgICAg
ICAgICAgICAgaWYgKGRvdCkgZG90LnRpdGxlID0gZG9uZSA/ICfpmJ/liJflt7LnspjotLQnIDogJ+ey
mOi0tOmYn+WIlyc7CiAgICAgICAgICAgICAgICAvLyBHcmVlbiByYWlsIGZvciBldmVyeSBpdGVtIGlu
IGEgMisgZGVxdWV1ZWQgcnVuIChpbmNsLiBmaXJzdC9sYXN0IHN0dWJzKQogICAgICAgICAgICAgICAg
Y29uc3QgcHJldkRvbmUgPSBrID4gMCAmJiBpdGVtSXNRdWV1ZURvbmUoc2xpY2VbayAtIDFdKTsKICAg
ICAgICAgICAgICAgIGNvbnN0IG5leHREb25lID0gayA8IHNsaWNlLmxlbmd0aCAtIDEgJiYgaXRlbUlz
UXVldWVEb25lKHNsaWNlW2sgKyAxXSk7CiAgICAgICAgICAgICAgICBpZiAoZG9uZSAmJiAocHJldkRv
bmUgfHwgbmV4dERvbmUpKQogICAgICAgICAgICAgICAgICAgIHNsaWNlW2tdLmNsYXNzTGlzdC5hZGQo
J3EtZG9uZS1saW5rJyk7CiAgICAgICAgICAgIH0KICAgICAgICAgICAgaSA9IGo7CiAgICAgICAgfQog
ICAgfQoKICAgIGNvbnN0IHBhdGhUaXBFbCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdwYXRoLXRp
cCcpOwogICAgbGV0IHBhdGhUaXBUaW1lciA9IDA7CiAgICBsZXQgcGF0aFRpcEhpZGVUaW1lciA9IDA7
CiAgICBsZXQgcGF0aFRpcFRva2VuID0gMDsKICAgIGxldCBwYXRoVGlwQW5jaG9yQnRuID0gbnVsbDsK
CiAgICBmdW5jdGlvbiBoaWRlUGF0aFRpcCgpIHsKICAgICAgICBjbGVhclRpbWVvdXQocGF0aFRpcFRp
bWVyKTsKICAgICAgICBjbGVhclRpbWVvdXQocGF0aFRpcEhpZGVUaW1lcik7CiAgICAgICAgcGF0aFRp
cFRva2VuKys7CiAgICAgICAgaWYgKHBhdGhUaXBBbmNob3JCdG4pIHsKICAgICAgICAgICAgcGF0aFRp
cEFuY2hvckJ0bi5jbGFzc0xpc3QucmVtb3ZlKCdvbicpOwogICAgICAgICAgICBwYXRoVGlwQW5jaG9y
QnRuID0gbnVsbDsKICAgICAgICB9CiAgICAgICAgaWYgKHBhdGhUaXBFbCkgewogICAgICAgICAgICBw
YXRoVGlwRWwuY2xhc3NMaXN0LnJlbW92ZSgnb24nKTsKICAgICAgICAgICAgcGF0aFRpcEVsLnNldEF0
dHJpYnV0ZSgnYXJpYS1oaWRkZW4nLCAndHJ1ZScpOwogICAgICAgIH0KICAgIH0KICAgIGZ1bmN0aW9u
IHBsYWNlUGF0aFRpcChhbmNob3JFbCkgewogICAgICAgIGlmICghcGF0aFRpcEVsIHx8ICFhbmNob3JF
bCkgcmV0dXJuOwogICAgICAgIGNvbnN0IHRpcCA9IHBhdGhUaXBFbDsKICAgICAgICBjb25zdCBhciA9
IGFuY2hvckVsLmdldEJvdW5kaW5nQ2xpZW50UmVjdCgpOwogICAgICAgIGNvbnN0IHBhZCA9IDg7CiAg
ICAgICAgdGlwLnN0eWxlLmxlZnQgPSAnMHB4JzsKICAgICAgICB0aXAuc3R5bGUudG9wID0gJzBweCc7
CiAgICAgICAgdGlwLmNsYXNzTGlzdC5hZGQoJ29uJyk7CiAgICAgICAgY29uc3QgdHcgPSB0aXAub2Zm
c2V0V2lkdGg7CiAgICAgICAgY29uc3QgdGggPSB0aXAub2Zmc2V0SGVpZ2h0OwogICAgICAgIGxldCBs
ZWZ0ID0gYXIubGVmdDsKICAgICAgICBsZXQgdG9wID0gYXIuYm90dG9tICsgNjsKICAgICAgICBpZiAo
bGVmdCArIHR3ID4gd2luZG93LmlubmVyV2lkdGggLSBwYWQpCiAgICAgICAgICAgIGxlZnQgPSBNYXRo
Lm1heChwYWQsIHdpbmRvdy5pbm5lcldpZHRoIC0gdHcgLSBwYWQpOwogICAgICAgIGlmIChsZWZ0IDwg
cGFkKSBsZWZ0ID0gcGFkOwogICAgICAgIGlmICh0b3AgKyB0aCA+IHdpbmRvdy5pbm5lckhlaWdodCAt
IHBhZCkKICAgICAgICAgICAgdG9wID0gTWF0aC5tYXgocGFkLCBhci50b3AgLSB0aCAtIDYpOwogICAg
ICAgIHRpcC5zdHlsZS5sZWZ0ID0gbGVmdCArICdweCc7CiAgICAgICAgdGlwLnN0eWxlLnRvcCA9IHRv
cCArICdweCc7CiAgICB9CiAgICAgICAgZnVuY3Rpb24gY2hlY2tGaWxlUGF0aHMocGF0aHMpIHsKICAg
ICAgICBjb25zdCBsaXN0ID0gKHBhdGhzIHx8IFtdKS5tYXAocCA9PiB7CiAgICAgICAgICAgIGxldCBw
YXRoID0gU3RyaW5nKHAgfHwgJycpLnRyaW0oKTsKICAgICAgICAgICAgaWYgKChwYXRoLnN0YXJ0c1dp
dGgoJyInKSAmJiBwYXRoLmVuZHNXaXRoKCciJykpIHx8IChwYXRoLnN0YXJ0c1dpdGgoIiciKSAmJiBw
YXRoLmVuZHNXaXRoKCInIikpKQogICAgICAgICAgICAgICAgcGF0aCA9IHBhdGguc2xpY2UoMSwgLTEp
LnRyaW0oKTsKICAgICAgICAgICAgcmV0dXJuIHBhdGg7CiAgICAgICAgfSk7CiAgICAgICAgLy8gT25l
IGhvc3Qgcm91bmQtdHJpcCBmb3IgdGhlIHdob2xlIGxpc3Qg4oCUIE7DlyBwYXRoRXhpc3RzIGZyZWV6
ZXMgZmlsZSB0YWIKICAgICAgICB0cnkgewogICAgICAgICAgICBjb25zdCByYXcgPSBhaGtSZXQoJ2No
ZWNrUGF0aHMnLCBsaXN0LmpvaW4oJ1xuJykpOwogICAgICAgICAgICBpZiAocmF3KSB7CiAgICAgICAg
ICAgICAgICBjb25zdCBwYXJzZWQgPSB0eXBlb2YgcmF3ID09PSAnc3RyaW5nJyA/IEpTT04ucGFyc2Uo
cmF3KSA6IHJhdzsKICAgICAgICAgICAgICAgIGlmIChBcnJheS5pc0FycmF5KHBhcnNlZCkgJiYgcGFy
c2VkLmxlbmd0aCkgewogICAgICAgICAgICAgICAgICAgIHJldHVybiBsaXN0Lm1hcCgocGF0aCwgaSkg
PT4gewogICAgICAgICAgICAgICAgICAgICAgICBjb25zdCByb3cgPSBwYXJzZWRbaV0gfHwge307CiAg
ICAgICAgICAgICAgICAgICAgICAgIHJldHVybiB7CiAgICAgICAgICAgICAgICAgICAgICAgICAgICBw
YXRoOiBwYXRoIHx8IFN0cmluZyhyb3cucGF0aCB8fCAnJyksCiAgICAgICAgICAgICAgICAgICAgICAg
ICAgICBleGlzdHM6IHJvdy5leGlzdHMgPT09IHRydWUgfHwgcm93LmV4aXN0cyA9PT0gMSB8fCByb3cu
ZXhpc3RzID09PSAnMScsCiAgICAgICAgICAgICAgICAgICAgICAgICAgICBpc0RpcjogISEocm93Lmlz
RGlyID09PSB0cnVlIHx8IHJvdy5pc0RpciA9PT0gMSB8fCByb3cuaXNEaXIgPT09ICcxJykKICAgICAg
ICAgICAgICAgICAgICAgICAgfTsKICAgICAgICAgICAgICAgICAgICB9KTsKICAgICAgICAgICAgICAg
IH0KICAgICAgICAgICAgfQogICAgICAgIH0gY2F0Y2gge30KICAgICAgICByZXR1cm4gbGlzdC5tYXAo
cGF0aCA9PiB7CiAgICAgICAgICAgIGlmICghcGF0aCkgcmV0dXJuIHsgcGF0aCwgZXhpc3RzOiBmYWxz
ZSwgaXNEaXI6IGZhbHNlIH07CiAgICAgICAgICAgIGxldCBleGlzdHMgPSBmYWxzZTsKICAgICAgICAg
ICAgdHJ5IHsKICAgICAgICAgICAgICAgIGNvbnN0IGZsYWcgPSBTdHJpbmcoYWhrUmV0KCdwYXRoRXhp
c3RzJywgcGF0aCkgPz8gJycpLnRyaW0oKS50b0xvd2VyQ2FzZSgpOwogICAgICAgICAgICAgICAgZXhp
c3RzID0gKGZsYWcgPT09ICcxJyB8fCBmbGFnID09PSAndHJ1ZScpOwogICAgICAgICAgICB9IGNhdGNo
IHt9CiAgICAgICAgICAgIHJldHVybiB7IHBhdGgsIGV4aXN0cywgaXNEaXI6IGZhbHNlIH07CiAgICAg
ICAgfSk7CiAgICB9CiAgICBsZXQgZ29uZUNoZWNrVGltZXIgPSAwOwogICAgZnVuY3Rpb24gc2NoZWR1
bGVGaWxlR29uZUNoZWNrKCkgewogICAgICAgIGlmIChnb25lQ2hlY2tUaW1lcikgcmV0dXJuOwogICAg
ICAgIGdvbmVDaGVja1RpbWVyID0gc2V0VGltZW91dCgoKSA9PiB7CiAgICAgICAgICAgIGdvbmVDaGVj
a1RpbWVyID0gMDsKICAgICAgICAgICAgY29uc3Qgbm9kZXMgPSBbLi4ubGlzdEVsLnF1ZXJ5U2VsZWN0
b3JBbGwoJy5pdG0nKV0uZmlsdGVyKG4gPT4gbi5fZmlsZVBhdGhzICYmIG4uX2ZpbGVQYXRocy5sZW5n
dGgpOwogICAgICAgICAgICBpZiAoIW5vZGVzLmxlbmd0aCkgcmV0dXJuOwogICAgICAgICAgICBjb25z
dCB1bmlxdWUgPSBbXTsKICAgICAgICAgICAgY29uc3Qgc2VlbiA9IG5ldyBTZXQoKTsKICAgICAgICAg
ICAgbm9kZXMuZm9yRWFjaChuID0+IHsKICAgICAgICAgICAgICAgIG4uX2ZpbGVQYXRocy5mb3JFYWNo
KHAgPT4gewogICAgICAgICAgICAgICAgICAgIGNvbnN0IHBhdGggPSBTdHJpbmcocCB8fCAnJyk7CiAg
ICAgICAgICAgICAgICAgICAgaWYgKCFwYXRoIHx8IHNlZW4uaGFzKHBhdGgpKSByZXR1cm47CiAgICAg
ICAgICAgICAgICAgICAgc2Vlbi5hZGQocGF0aCk7CiAgICAgICAgICAgICAgICAgICAgdW5pcXVlLnB1
c2gocGF0aCk7CiAgICAgICAgICAgICAgICB9KTsKICAgICAgICAgICAgfSk7CiAgICAgICAgICAgIGNv
bnN0IHJvd3MgPSBjaGVja0ZpbGVQYXRocyh1bmlxdWUpOwogICAgICAgICAgICBjb25zdCBieVBhdGgg
PSBuZXcgTWFwKCk7CiAgICAgICAgICAgIHJvd3MuZm9yRWFjaChyID0+IGJ5UGF0aC5zZXQoU3RyaW5n
KHIucGF0aCB8fCAnJyksIHIpKTsKICAgICAgICAgICAgbm9kZXMuZm9yRWFjaChuID0+IHsKICAgICAg
ICAgICAgICAgIGNvbnN0IHBhdGhSb3dzID0gbi5fZmlsZVBhdGhzLm1hcChwID0+IHsKICAgICAgICAg
ICAgICAgICAgICBjb25zdCBoaXQgPSBieVBhdGguZ2V0KFN0cmluZyhwIHx8ICcnKSk7CiAgICAgICAg
ICAgICAgICAgICAgcmV0dXJuIGhpdCB8fCB7IHBhdGg6IHAsIGV4aXN0czogdHJ1ZSwgaXNEaXI6IGZh
bHNlIH07CiAgICAgICAgICAgICAgICB9KTsKICAgICAgICAgICAgICAgIG4uX3BhdGhSb3dzID0gcGF0
aFJvd3M7CiAgICAgICAgICAgICAgICBjb25zdCBhbGxHb25lID0gcGF0aFJvd3MubGVuZ3RoID4gMCAm
JiBwYXRoUm93cy5ldmVyeShyID0+IHIuZXhpc3RzID09PSBmYWxzZSk7CiAgICAgICAgICAgICAgICBu
LmNsYXNzTGlzdC50b2dnbGUoJ2dvbmUnLCBhbGxHb25lKTsKICAgICAgICAgICAgfSk7CiAgICAgICAg
fSwgNDAwKTsKICAgIH0KICAgIGZ1bmN0aW9uIGZpbGxGaWxlRGV0YWlsUGFuZWwoY29udGFpbmVyLCBy
b3dzKSB7CiAgICAgICAgY29udGFpbmVyLmlubmVySFRNTCA9ICcnOwogICAgICAgIGlmICghcm93cy5s
ZW5ndGgpIHsKICAgICAgICAgICAgY29uc3QgZW1wdHkgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdk
aXYnKTsKICAgICAgICAgICAgZW1wdHkuY2xhc3NOYW1lID0gJ2ZkLXBhdGgnOwogICAgICAgICAgICBl
bXB0eS50ZXh0Q29udGVudCA9ICfml6Dot6/lvoQnOwogICAgICAgICAgICBjb250YWluZXIuYXBwZW5k
Q2hpbGQoZW1wdHkpOwogICAgICAgICAgICByZXR1cm47CiAgICAgICAgfQogICAgICAgIHJvd3MuZm9y
RWFjaChyID0+IHsKICAgICAgICAgICAgY29uc3QgcGF0aCA9IFN0cmluZyhyLnBhdGggfHwgJycpOwog
ICAgICAgICAgICBjb25zdCBtaXNzaW5nID0gci5leGlzdHMgPT09IGZhbHNlOwogICAgICAgICAgICBj
b25zdCBibG9jayA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOwogICAgICAgICAgICBibG9j
ay5jbGFzc05hbWUgPSAnZmQtYmxvY2snOwoKICAgICAgICAgICAgY29uc3QgcGF0aEVsID0gZG9jdW1l
bnQuY3JlYXRlRWxlbWVudCgnZGl2Jyk7CiAgICAgICAgICAgIHBhdGhFbC5jbGFzc05hbWUgPSAnZmQt
cGF0aCcgKyAobWlzc2luZyA/ICcgZGVhZCcgOiAnIGxpdmUnKTsKICAgICAgICAgICAgcGF0aEVsLnRl
eHRDb250ZW50ID0gcGF0aCB8fCAnKOepuui3r+W+hCknOwogICAgICAgICAgICBpZiAoIW1pc3Npbmcp
IHsKICAgICAgICAgICAgICAgIHBhdGhFbC5vbmNsaWNrID0gZSA9PiB7CiAgICAgICAgICAgICAgICAg
ICAgZS5wcmV2ZW50RGVmYXVsdCgpOwogICAgICAgICAgICAgICAgICAgIGUuc3RvcFByb3BhZ2F0aW9u
KCk7CiAgICAgICAgICAgICAgICAgICAgYWhrKCdvcGVuUGF0aCcsIHBhdGgpOwogICAgICAgICAgICAg
ICAgfTsKICAgICAgICAgICAgfQogICAgICAgICAgICBibG9jay5hcHBlbmRDaGlsZChwYXRoRWwpOwoK
ICAgICAgICAgICAgY29uc3QgYWN0aW9ucyA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOwog
ICAgICAgICAgICBhY3Rpb25zLmNsYXNzTmFtZSA9ICdmZC1hY3Rpb25zJzsKCiAgICAgICAgICAgIGNv
bnN0IGNvcHlCdG4gPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdidXR0b24nKTsKICAgICAgICAgICAg
Y29weUJ0bi50eXBlID0gJ2J1dHRvbic7CiAgICAgICAgICAgIGNvcHlCdG4uY2xhc3NOYW1lID0gJ2Zk
LWJ0bic7CiAgICAgICAgICAgIGNvcHlCdG4uaW5uZXJIVE1MID0gJzxzcGFuIGNsYXNzPSJmZC1pY28i
PvCflJc8L3NwYW4+PHNwYW4gY2xhc3M9ImZkLXR4dCI+5aSN5Yi26Lev5b6EPC9zcGFuPic7CiAgICAg
ICAgICAgIGNvcHlCdG4ub25jbGljayA9IGUgPT4gewogICAgICAgICAgICAgICAgZS5wcmV2ZW50RGVm
YXVsdCgpOwogICAgICAgICAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICAgICAgICAg
IGFoaygnY29weVBhdGgnLCBwYXRoKTsKICAgICAgICAgICAgICAgIGNvcHlCdG4ucXVlcnlTZWxlY3Rv
cignLmZkLXR4dCcpLnRleHRDb250ZW50ID0gJ+W3suWkjeWItic7CiAgICAgICAgICAgICAgICBjb3B5
QnRuLmNsYXNzTGlzdC5hZGQoJ29rJyk7CiAgICAgICAgICAgICAgICBzZXRUaW1lb3V0KCgpID0+IHsK
ICAgICAgICAgICAgICAgICAgICBjb3B5QnRuLnF1ZXJ5U2VsZWN0b3IoJy5mZC10eHQnKS50ZXh0Q29u
dGVudCA9ICflpI3liLbot6/lvoQnOwogICAgICAgICAgICAgICAgICAgIGNvcHlCdG4uY2xhc3NMaXN0
LnJlbW92ZSgnb2snKTsKICAgICAgICAgICAgICAgIH0sIDEyMDApOwogICAgICAgICAgICB9OwogICAg
ICAgICAgICBhY3Rpb25zLmFwcGVuZENoaWxkKGNvcHlCdG4pOwoKICAgICAgICAgICAgY29uc3QgZm9s
ZGVyQnRuID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnYnV0dG9uJyk7CiAgICAgICAgICAgIGZvbGRl
ckJ0bi50eXBlID0gJ2J1dHRvbic7CiAgICAgICAgICAgIGZvbGRlckJ0bi5jbGFzc05hbWUgPSAnZmQt
YnRuJzsKICAgICAgICAgICAgZm9sZGVyQnRuLmlubmVySFRNTCA9ICc8c3BhbiBjbGFzcz0iZmQtaWNv
Ij7wn5OCPC9zcGFuPjxzcGFuIGNsYXNzPSJmZC10eHQiPuaJk+W8gOaJgOWcqOaWh+S7tuWkuTwvc3Bh
bj4nOwogICAgICAgICAgICBmb2xkZXJCdG4ub25jbGljayA9IGUgPT4gewogICAgICAgICAgICAgICAg
ZS5wcmV2ZW50RGVmYXVsdCgpOwogICAgICAgICAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAg
ICAgICAgICAgICAgIGFoaygnb3BlbkZvbGRlcicsIHBhdGgpOwogICAgICAgICAgICB9OwogICAgICAg
ICAgICBhY3Rpb25zLmFwcGVuZENoaWxkKGZvbGRlckJ0bik7CgogICAgICAgICAgICBibG9jay5hcHBl
bmRDaGlsZChhY3Rpb25zKTsKICAgICAgICAgICAgY29udGFpbmVyLmFwcGVuZENoaWxkKGJsb2NrKTsK
ICAgICAgICB9KTsKICAgIH0KCiAgICBjb25zdCBjdHhFbCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlk
KCdjdHgnKTsKICAgIGZ1bmN0aW9uIHNob3dDdHgoeCwgeSwgYykgewogICAgICAgIGN0eENsaXAgPSBj
OwogICAgICAgIHNlbGVjdGVkSWQgPSBjLmlkOwogICAgICAgIHJhbmdlQW5jaG9ySWQgPSBjLmlkOwog
ICAgICAgIHJhbmdlQW5jaG9yQ2xpY2tlZCA9IHRydWU7CiAgICAgICAgY29uc3QgY2xlYXJCdG4gPSBk
b2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYy1jbGVhci1wYXN0ZWQnKTsKICAgICAgICBpZiAoY2xlYXJC
dG4pIGNsZWFyQnRuLnN0eWxlLmRpc3BsYXkgPSBpc1Bhc3RlZChjKSA/ICcnIDogJ25vbmUnOwogICAg
ICAgIGNvbnN0IHFGcm9tID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2MtcXVldWUtZnJvbScpOwog
ICAgICAgIGlmIChxRnJvbSkgcUZyb20uc3R5bGUuZGlzcGxheSA9IChOdW1iZXIoYy5xdWV1ZUdyb3Vw
KSA+IDApID8gJycgOiAnbm9uZSc7CgogICAgICAgIGNvbnN0IHBpbkJ0biA9IGRvY3VtZW50LmdldEVs
ZW1lbnRCeUlkKCdjLXBpbicpOwogICAgICAgIGNvbnN0IGNvcHlCdG4gPSBkb2N1bWVudC5nZXRFbGVt
ZW50QnlJZCgnYy1jb3B5Jyk7CiAgICAgICAgY29uc3QgaXNSZWNlbnQgPSBub3JtVHlwZShjLnR5cGUp
ID09PSAncmVjZW50JyB8fCBjdXJUYWIgPT09ICdyZWNlbnQnOwogICAgICAgIGlmIChjb3B5QnRuKSB7
CiAgICAgICAgICAgIGNvcHlCdG4uaW5uZXJIVE1MID0gaXNSZWNlbnQKICAgICAgICAgICAgICAgID8g
JzxzcGFuIGNsYXNzPSJjLWljbyI+8J+Ulzwvc3Bhbj7lpI3liLbot6/lvoQnCiAgICAgICAgICAgICAg
ICA6ICc8c3BhbiBjbGFzcz0iYy1pY28iPuKOmDwvc3Bhbj7lpI3liLYnOwogICAgICAgICAgICBjb3B5
QnRuLnN0eWxlLmRpc3BsYXkgPSAnJzsKICAgICAgICB9CiAgICAgICAgaWYgKHBpbkJ0bikgewogICAg
ICAgICAgICBpZiAoaXNSZWNlbnQpIHsKICAgICAgICAgICAgICAgIC8vIFJlY2VudCBmb2xkZXJzOiBw
aW4gPSBrZWVwIHBhdGggKG5vdCBjbGlwYm9hcmQg5pS26JePKQogICAgICAgICAgICAgICAgcGluQnRu
LnN0eWxlLmRpc3BsYXkgPSAnJzsKICAgICAgICAgICAgICAgIGNvbnN0IG9uID0gaXNQaW5uZWQoYyk7
CiAgICAgICAgICAgICAgICBwaW5CdG4uaW5uZXJIVE1MID0gb24KICAgICAgICAgICAgICAgICAgICA/
ICc8c3BhbiBjbGFzcz0iYy1pY28iPuKYhTwvc3Bhbj7lj5bmtojlm7rlrponCiAgICAgICAgICAgICAg
ICAgICAgOiAnPHNwYW4gY2xhc3M9ImMtaWNvIj7imIU8L3NwYW4+5Zu65a6a6Lev5b6EJzsKICAgICAg
ICAgICAgfSBlbHNlIHsKICAgICAgICAgICAgICAgIHBpbkJ0bi5zdHlsZS5kaXNwbGF5ID0gJyc7CiAg
ICAgICAgICAgICAgICBjb25zdCBvbiA9IGlzUGlubmVkKGMpOwogICAgICAgICAgICAgICAgcGluQnRu
LmlubmVySFRNTCA9IG9uCiAgICAgICAgICAgICAgICAgICAgPyAnPHNwYW4gY2xhc3M9ImMtaWNvIj7i
mIU8L3NwYW4+5Y+W5raI5pS26JePJwogICAgICAgICAgICAgICAgICAgIDogJzxzcGFuIGNsYXNzPSJj
LWljbyI+4piFPC9zcGFuPuaUtuiXjyc7CiAgICAgICAgICAgIH0KICAgICAgICB9CiAgICAgICAgY29u
c3QgdGl0bGVCdG4gPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYy10aXRsZScpOwogICAgICAgIGlm
ICh0aXRsZUJ0bikgewogICAgICAgICAgICAvLyBObyBmYXYtdGl0bGUgZm9yIHJlY2VudCBwYXRocwog
ICAgICAgICAgICBjb25zdCBzaG93VGl0bGUgPSAhaXNSZWNlbnQgJiYgKGlzUGlubmVkKGMpIHx8IGN1
clRhYiA9PT0gJ3Bpbm5lZCcpOwogICAgICAgICAgICB0aXRsZUJ0bi5zdHlsZS5kaXNwbGF5ID0gc2hv
d1RpdGxlID8gJycgOiAnbm9uZSc7CiAgICAgICAgICAgIGlmIChzaG93VGl0bGUpCiAgICAgICAgICAg
ICAgICB0aXRsZUJ0bi5pbm5lckhUTUwgPSAoU3RyaW5nKGMuZmF2VGl0bGUgfHwgJycpLnRyaW0oKSA/
ICc8c3BhbiBjbGFzcz0iYy1pY28iPuKcjjwvc3Bhbj7nvJbovpHmoIfpopgnIDogJzxzcGFuIGNsYXNz
PSJjLWljbyI+4pyOPC9zcGFuPuiuvue9ruagh+mimCcpOwogICAgICAgIH0KICAgICAgICBjb25zdCBt
ZXJnZUJ0biA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjLW1lcmdlJyk7CiAgICAgICAgY29uc3Qg
dW5tZXJnZUJ0biA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjLXVubWVyZ2UnKTsKICAgICAgICBj
b25zdCBvblBpbm5lZCA9IGN1clRhYiA9PT0gJ3Bpbm5lZCc7CiAgICAgICAgaWYgKG1lcmdlQnRuKQog
ICAgICAgICAgICBtZXJnZUJ0bi5zdHlsZS5kaXNwbGF5ID0gKCFpc1JlY2VudCAmJiBvblBpbm5lZCAm
JiBtdWx0aUlkcy5sZW5ndGggPj0gMikgPyAnJyA6ICdub25lJzsKICAgICAgICBpZiAodW5tZXJnZUJ0
bikKICAgICAgICAgICAgdW5tZXJnZUJ0bi5zdHlsZS5kaXNwbGF5ID0gKCFpc1JlY2VudCAmJiBvblBp
bm5lZCAmJiBmYXZHcm91cE9mKGMpKSA/ICcnIDogJ25vbmUnOwogICAgICAgIGNvbnN0IHRvcEJ0biA9
IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjLXRvcCcpOwogICAgICAgIGlmICh0b3BCdG4pCiAgICAg
ICAgICAgIHRvcEJ0bi5zdHlsZS5kaXNwbGF5ID0gaXNSZWNlbnQgPyAnbm9uZScgOiAnJzsKICAgICAg
ICBjb25zdCBjbGVhckJ0bjIgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYy1jbGVhci1wYXN0ZWQn
KTsKICAgICAgICBpZiAoY2xlYXJCdG4yICYmIGlzUmVjZW50KQogICAgICAgICAgICBjbGVhckJ0bjIu
c3R5bGUuZGlzcGxheSA9ICdub25lJzsKICAgICAgICBjb25zdCBxRnJvbTIgPSBkb2N1bWVudC5nZXRF
bGVtZW50QnlJZCgnYy1xdWV1ZS1mcm9tJyk7CiAgICAgICAgaWYgKHFGcm9tMiAmJiBpc1JlY2VudCkK
ICAgICAgICAgICAgcUZyb20yLnN0eWxlLmRpc3BsYXkgPSAnbm9uZSc7CiAgICAgICAgY29uc3QgZGVs
QnRuID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2MtZGVsJyk7CiAgICAgICAgaWYgKGRlbEJ0bikg
ewogICAgICAgICAgICBjb25zdCBtdWx0aURlbCA9IG11bHRpSWRzLmxlbmd0aCA+IDEgJiYgbXVsdGlJ
ZHMuaW5jbHVkZXMoK2MuaWQpOwogICAgICAgICAgICBjb25zdCBuID0gbXVsdGlEZWwgPyBtdWx0aUlk
cy5sZW5ndGggOiAxOwogICAgICAgICAgICBkZWxCdG4uaW5uZXJIVE1MID0gbiA+IDEKICAgICAgICAg
ICAgICAgID8gKCc8c3BhbiBjbGFzcz0iYy1pY28iPuKclTwvc3Bhbj7liKDpmaQgKCcgKyBuICsgJykn
KQogICAgICAgICAgICAgICAgOiAnPHNwYW4gY2xhc3M9ImMtaWNvIj7inJU8L3NwYW4+5Yig6ZmkJzsK
ICAgICAgICB9CiAgICAgICAgY3R4RWwuY2xhc3NMaXN0LmFkZCgnb24nKTsKICAgICAgICBjdHhFbC5z
dHlsZS5sZWZ0ID0geCArICdweCc7CiAgICAgICAgY3R4RWwuc3R5bGUudG9wICA9IHkgKyAncHgnOwog
ICAgICAgIHJlcXVlc3RBbmltYXRpb25GcmFtZSgoKSA9PiB7CiAgICAgICAgICAgIGNvbnN0IHIgPSBj
dHhFbC5nZXRCb3VuZGluZ0NsaWVudFJlY3QoKTsKICAgICAgICAgICAgaWYgKHIucmlnaHQgID4gaW5u
ZXJXaWR0aCkgIGN0eEVsLnN0eWxlLmxlZnQgPSAoeCAtIHIud2lkdGgpICArICdweCc7CiAgICAgICAg
ICAgIGlmIChyLmJvdHRvbSA+IGlubmVySGVpZ2h0KSBjdHhFbC5zdHlsZS50b3AgID0gKHkgLSByLmhl
aWdodCkgKyAncHgnOwogICAgICAgIH0pOwogICAgfQogICAgZnVuY3Rpb24gaGlkZUN0eCgpIHsgY3R4
RWwuY2xhc3NMaXN0LnJlbW92ZSgnb24nKTsgY3R4Q2xpcCA9IG51bGw7IH0KICAgIHdpbmRvdy5fX2hp
ZGVDdHggPSBoaWRlQ3R4OwoKICAgIGZ1bmN0aW9uIGRpc21pc3NDdHhVbmxlc3NJbnNpZGUoZSkgewog
ICAgICAgIGlmICghY3R4RWwuY2xhc3NMaXN0LmNvbnRhaW5zKCdvbicpKSByZXR1cm47CiAgICAgICAg
aWYgKGUudGFyZ2V0LmNsb3Nlc3QoJyNjdHgnKSkgcmV0dXJuOwogICAgICAgIGhpZGVDdHgoKTsKICAg
IH0KICAgIGRvY3VtZW50LmFkZEV2ZW50TGlzdGVuZXIoJ21vdXNlZG93bicsIGRpc21pc3NDdHhVbmxl
c3NJbnNpZGUsIHRydWUpOwogICAgZG9jdW1lbnQuYWRkRXZlbnRMaXN0ZW5lcignY2xpY2snLCBkaXNt
aXNzQ3R4VW5sZXNzSW5zaWRlLCB0cnVlKTsKICAgIGxpc3RFbC5hZGRFdmVudExpc3RlbmVyKCdzY3Jv
bGwnLCBoaWRlQ3R4LCB7IHBhc3NpdmU6IHRydWUgfSk7CiAgICBkb2N1bWVudC5hZGRFdmVudExpc3Rl
bmVyKCdrZXlkb3duJywgZSA9PiB7CiAgICAgICAgLy8gRXNjOiBhbHdheXMgY2xvc2UgcGFuZWwgKHNl
YXJjaCBvciBub3QpOyBwaW4ga2VlcHMgcGFuZWwKICAgICAgICBpZiAoZS5rZXkgPT09ICdFc2NhcGUn
KSB7CiAgICAgICAgICAgIGUucHJldmVudERlZmF1bHQoKTsKICAgICAgICAgICAgaGlkZUN0eCgpOwog
ICAgICAgICAgICBjb25zdCB0ZCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd0aXRsZS1kbGcnKTsK
ICAgICAgICAgICAgaWYgKHRkICYmIHRkLmNsYXNzTGlzdC5jb250YWlucygnb24nKSkgewogICAgICAg
ICAgICAgICAgdHJ5IHsgY2xvc2VUaXRsZURsZygpOyB9IGNhdGNoIHsgdGQuY2xhc3NMaXN0LnJlbW92
ZSgnb24nKTsgfQogICAgICAgICAgICAgICAgcmV0dXJuOwogICAgICAgICAgICB9CiAgICAgICAgICAg
IGlmIChjbHJEbGcuY2xhc3NMaXN0LmNvbnRhaW5zKCdvbicpKSB7CiAgICAgICAgICAgICAgICBjbG9z
ZUNsZWFyRGxnKCk7CiAgICAgICAgICAgICAgICByZXR1cm47CiAgICAgICAgICAgIH0KICAgICAgICAg
ICAgaWYgKCFwaW5uZWRVSSkgYWhrKCdoaWRlJyk7CiAgICAgICAgICAgIHJldHVybjsKICAgICAgICB9
CiAgICAgICAgLy8gV2hpbGUgdHlwaW5nIGluIHNlYXJjaDogQ3RybCtJL0sgYW5kIGFycm93cyBtb3Zl
IGxpc3QsIGRvbid0IGxlYXZlIHRoZSBib3gKICAgICAgICBpZiAoZG9jdW1lbnQuYWN0aXZlRWxlbWVu
dD8uaWQgPT09ICdzZWFyY2gnKSB7CiAgICAgICAgICAgIGlmICgoZS5jdHJsS2V5IHx8IGUubWV0YUtl
eSkgJiYgKGUua2V5ID09PSAnaScgfHwgZS5rZXkgPT09ICdJJykpIHsKICAgICAgICAgICAgICAgIGUu
cHJldmVudERlZmF1bHQoKTsgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICAgICAgICAgIHdpbmRv
dy5fX25hdiAmJiB3aW5kb3cuX19uYXYoJ3VwJyk7CiAgICAgICAgICAgICAgICByZXR1cm47CiAgICAg
ICAgICAgIH0KICAgICAgICAgICAgaWYgKChlLmN0cmxLZXkgfHwgZS5tZXRhS2V5KSAmJiAoZS5rZXkg
PT09ICdrJyB8fCBlLmtleSA9PT0gJ0snKSkgewogICAgICAgICAgICAgICAgZS5wcmV2ZW50RGVmYXVs
dCgpOyBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgICAgICAgICAgICAgd2luZG93Ll9fbmF2ICYmIHdp
bmRvdy5fX25hdignZG93bicpOwogICAgICAgICAgICAgICAgcmV0dXJuOwogICAgICAgICAgICB9CiAg
ICAgICAgICAgIGlmIChlLmtleSA9PT0gJ0Fycm93RG93bicpIHsKICAgICAgICAgICAgICAgIGUucHJl
dmVudERlZmF1bHQoKTsgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICAgICAgICAgIHdpbmRvdy5f
X25hdiAmJiB3aW5kb3cuX19uYXYoJ2Rvd24nKTsKICAgICAgICAgICAgICAgIHJldHVybjsKICAgICAg
ICAgICAgfQogICAgICAgICAgICBpZiAoZS5rZXkgPT09ICdBcnJvd1VwJykgewogICAgICAgICAgICAg
ICAgZS5wcmV2ZW50RGVmYXVsdCgpOyBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgICAgICAgICAgICAg
d2luZG93Ll9fbmF2ICYmIHdpbmRvdy5fX25hdigndXAnKTsKICAgICAgICAgICAgICAgIHJldHVybjsK
ICAgICAgICAgICAgfQogICAgICAgICAgICByZXR1cm47CiAgICAgICAgfQogICAgICAgIGNvbnN0IHZp
cyA9ICh0eXBlb2YgbmF2TGlzdCA9PT0gJ2Z1bmN0aW9uJyA/IG5hdkxpc3QoKSA6IHZpc2libGVMaXN0
KCkpOwogICAgICAgIGlmICghdmlzLmxlbmd0aCkgcmV0dXJuOwogICAgICAgIGxldCBpZHggPSBzZWxl
Y3RlZEluZGV4KCk7CiAgICAgICAgaWYgKGlkeCA8IDApIGlkeCA9IDA7CiAgICAgICAgaWYgICAgICAo
ZS5rZXkgPT09ICdBcnJvd0Rvd24nKSB7IGUucHJldmVudERlZmF1bHQoKTsgZS5zdG9wUHJvcGFnYXRp
b24oKTsgc2VsZWN0QnlJbmRleChpZHggKyAxKTsgfQogICAgICAgIGVsc2UgaWYgKGUua2V5ID09PSAn
QXJyb3dVcCcpICAgeyBlLnByZXZlbnREZWZhdWx0KCk7IGUuc3RvcFByb3BhZ2F0aW9uKCk7IHNlbGVj
dEJ5SW5kZXgoaWR4IC0gMSk7IH0KICAgICAgICBlbHNlIGlmIChlLmtleSA9PT0gJ0VudGVyJykgewog
ICAgICAgICAgICBlLnByZXZlbnREZWZhdWx0KCk7CiAgICAgICAgICAgIC8vIOWbuuWumuaXtuWbnui9
puS4jeeymOi0tO+8jOWPqueCueadoeebrueymOi0tAogICAgICAgICAgICBpZiAocGlubmVkVUkpIHJl
dHVybjsKICAgICAgICAgICAgaWYgKG11bHRpSWRzLmxlbmd0aCA+PSAxKSB7CiAgICAgICAgICAgICAg
ICBjb25zdCBpZHMgPSBtdWx0aUlkcy5zbGljZSgpOwogICAgICAgICAgICAgICAgY2xlYXJNdWx0aSgp
OwogICAgICAgICAgICAgICAgbWFya1Bhc3RlZExvY2FsKGlkcyk7CiAgICAgICAgICAgICAgICBwYXN0
ZU1hbnlXaXRoU2VwKGlkcyk7CiAgICAgICAgICAgICAgICByZXR1cm47CiAgICAgICAgICAgIH0KICAg
ICAgICAgICAgY29uc3QgYyA9IHZpc1tzZWxlY3RlZEluZGV4KCldOwogICAgICAgICAgICBpZiAoYykg
ewogICAgICAgICAgICAgICAgbWFya1Bhc3RlZExvY2FsKGMuaWQpOwogICAgICAgICAgICAgICAgYWhr
KCdwYXN0ZScsIFN0cmluZyhjLmlkKSk7CiAgICAgICAgICAgIH0KICAgICAgICB9IGVsc2UgaWYgKC9e
WzEtOV0kLy50ZXN0KGUua2V5KSkgewogICAgICAgICAgICBjb25zdCBjID0gdmlzWytlLmtleSAtIDFd
OwogICAgICAgICAgICBpZiAoYykgewogICAgICAgICAgICAgICAgbWFya1Bhc3RlZExvY2FsKGMuaWQp
OwogICAgICAgICAgICAgICAgYWhrKCdwYXN0ZScsIFN0cmluZyhjLmlkKSk7CiAgICAgICAgICAgIH0K
ICAgICAgICB9CiAgICB9KTsKCiAgICB3aW5kb3cuX19uYXYgPSBkaXIgPT4gewogICAgICAgIGNvbnN0
IHZpcyA9ICh0eXBlb2YgbmF2TGlzdCA9PT0gJ2Z1bmN0aW9uJyA/IG5hdkxpc3QoKSA6IHZpc2libGVM
aXN0KCkpOwogICAgICAgIGlmICghdmlzLmxlbmd0aCAmJiBkaXIgIT09ICd0YWInICYmIGRpciAhPT0g
J3RhYlByZXYnKSByZXR1cm47CiAgICAgICAgbGV0IGlkeCA9IHNlbGVjdGVkSW5kZXgoKTsKICAgICAg
ICBpZiAoaWR4IDwgMCkgaWR4ID0gMDsKICAgICAgICBpZiAoZGlyID09PSAndXAnKSBzZWxlY3RCeUlu
ZGV4KGlkeCAtIDEpOwogICAgICAgIGVsc2UgaWYgKGRpciA9PT0gJ2Rvd24nKSBzZWxlY3RCeUluZGV4
KGlkeCArIDEpOwogICAgICAgIGVsc2UgaWYgKGRpciA9PT0gJ2VudGVyJykgewogICAgICAgICAgICBp
ZiAocGlubmVkVUkpIHJldHVybjsKICAgICAgICAgICAgX19wcmVwUGFzdGUoKTsKICAgICAgICAgICAg
aWYgKG11bHRpSWRzLmxlbmd0aCA+PSAxKSB7CiAgICAgICAgICAgICAgICBjb25zdCBpZHMgPSBtdWx0
aUlkcy5zbGljZSgpOwogICAgICAgICAgICAgICAgY2xlYXJNdWx0aSgpOwogICAgICAgICAgICAgICAg
bWFya1Bhc3RlZExvY2FsKGlkcyk7CiAgICAgICAgICAgICAgICBwYXN0ZU1hbnlXaXRoU2VwKGlkcyk7
CiAgICAgICAgICAgICAgICByZXR1cm47CiAgICAgICAgICAgIH0KICAgICAgICAgICAgY29uc3QgYyA9
IHZpc1tzZWxlY3RlZEluZGV4KCldOwogICAgICAgICAgICBpZiAoYykgewogICAgICAgICAgICAgICAg
bWFya1Bhc3RlZExvY2FsKGMuaWQpOwogICAgICAgICAgICAgICAgYWhrKCdwYXN0ZScsIFN0cmluZyhj
LmlkKSk7CiAgICAgICAgICAgIH0KICAgICAgICB9CiAgICB9OwoKICAgIC8vIEFISyBFbnRlciBob3Rr
ZXkgbGFuZHMgaGVyZSAoV2ViVmlldyBtYXkgbm90IHJlY2VpdmUgdGhlIGtleSB3aGlsZSB1bnBpbm5l
ZCkKICAgIHdpbmRvdy5fX2VkaXRUaXRsZSA9ICgpID0+IHsKICAgICAgICBsZXQgYyA9IG51bGw7CiAg
ICAgICAgaWYgKHNlbGVjdGVkSWQpCiAgICAgICAgICAgIGMgPSBhbGxDbGlwcy5maW5kKHggPT4gK3gu
aWQgPT09ICtzZWxlY3RlZElkKSB8fCBudWxsOwogICAgICAgIGlmICghYyAmJiBjdHhDbGlwKQogICAg
ICAgICAgICBjID0gY3R4Q2xpcDsKICAgICAgICBpZiAoIWMpIHsKICAgICAgICAgICAgY29uc3Qgdmlz
ID0gdmlzaWJsZUxpc3QoKTsKICAgICAgICAgICAgaWYgKHZpcy5sZW5ndGgpIGMgPSB2aXNbMF07CiAg
ICAgICAgfQogICAgICAgIGlmICghYykgcmV0dXJuOwogICAgICAgIG9wZW5UaXRsZURsZyhjKTsKICAg
IH07CgogICAgd2luZG93Ll9fb25FbnRlciA9ICgpID0+IHsKICAgICAgICBjb25zdCB0ZCA9IGRvY3Vt
ZW50LmdldEVsZW1lbnRCeUlkKCd0aXRsZS1kbGcnKTsKICAgICAgICBpZiAodGQgJiYgdGQuY2xhc3NM
aXN0LmNvbnRhaW5zKCdvbicpKSB7CiAgICAgICAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd0
aXRsZS1vaycpPy5jbGljaygpOwogICAgICAgICAgICByZXR1cm47CiAgICAgICAgfQogICAgICAgIGlm
IChkb2N1bWVudC5hY3RpdmVFbGVtZW50Py5pZCA9PT0gJ3RpdGxlLWlucHV0JykgewogICAgICAgICAg
ICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgndGl0bGUtb2snKT8uY2xpY2soKTsKICAgICAgICAgICAg
cmV0dXJuOwogICAgICAgIH0KICAgICAgICAvLyDoh6rlrprkuYnliIbpmpTnrKbvvJrmnKrlm7rlrprm
l7YgQUhLIOS8muaKoiBFbnRlcgogICAgICAgIGNvbnN0IHNlcE1lbnUgPSBkb2N1bWVudC5nZXRFbGVt
ZW50QnlJZCgncGFzdGUtc2VwLW1lbnUnKTsKICAgICAgICBjb25zdCBzZXBJbnAgPSBkb2N1bWVudC5n
ZXRFbGVtZW50QnlJZCgncGFzdGUtc2VwLWN1c3RvbScpOwogICAgICAgIGlmIChzZXBNZW51ICYmIHNl
cE1lbnUuY2xhc3NMaXN0LmNvbnRhaW5zKCdvbicpICYmIHNlcElucCkgewogICAgICAgICAgICBpZiAo
U3RyaW5nKHNlcElucC52YWx1ZSB8fCAnJykgIT09ICcnKSBhcHBseVNlcGFyYXRvcihzZXBJbnAudmFs
dWUpOwogICAgICAgICAgICBlbHNlIGNsb3NlU2VwTWVudSgpOwogICAgICAgICAgICByZXR1cm47CiAg
ICAgICAgfQogICAgICAgIC8vIOWbuuWumuaXtuWbnui9puS4jeeymOi0tAogICAgICAgIGlmIChwaW5u
ZWRVSSkgcmV0dXJuOwogICAgICAgIC8vIFR5cGluZyBpbiBzZWFyY2g6IEVudGVyIHNob3VsZCBwYXN0
ZSBzZWxlY3RlZCBpdGVtCiAgICAgICAgaWYgKGRvY3VtZW50LmFjdGl2ZUVsZW1lbnQ/LmlkID09PSAn
c2VhcmNoJykgewogICAgICAgICAgICB3aW5kb3cuX19uYXYgJiYgd2luZG93Ll9fbmF2KCdlbnRlcicp
OwogICAgICAgICAgICByZXR1cm47CiAgICAgICAgfQogICAgICAgIHdpbmRvdy5fX25hdiAmJiB3aW5k
b3cuX19uYXYoJ2VudGVyJyk7CiAgICB9OwoKICAgIHdpbmRvdy5fX2N5Y2xlVGFiID0gZGlyID0+IHsK
ICAgICAgICBjb25zdCBpID0gTWF0aC5tYXgoMCwgVEFCX09SREVSLmluZGV4T2YoY3VyVGFiKSk7CiAg
ICAgICAgY29uc3QgbmV4dCA9IFRBQl9PUkRFUlsoaSArIChkaXIgfCAwKSArIFRBQl9PUkRFUi5sZW5n
dGggKiAxMCkgJSBUQUJfT1JERVIubGVuZ3RoXTsKICAgICAgICBzZXRUYWIobmV4dCk7CiAgICB9Owog
ICAgd2luZG93Ll9fb25QYW5lbFNob3cgPSAoa2VlcFNlYXJjaCkgPT4gewogICAgICAgIHdpbmRvdy5f
X3BlcmZNYXJrICYmIHdpbmRvdy5fX3BlcmZNYXJrKCdqc19vblBhbmVsU2hvdyBrZWVwU2VhcmNoPScg
KyAoISFrZWVwU2VhcmNoKSk7CiAgICAgICAgdHJ5IHsgcmVzZXRQYXN0ZVNlcERlZmF1bHQoKTsgfSBj
YXRjaCB7fQogICAgICAgIC8vIERvIE5PVCBmb2N1cyBXZWJWaWV3IOKAlCBrZWVwIGVkaXRvciBjYXJl
dC9mb2N1cyAoQUhLIGhhbmRsZXMga2V5cyB2aWEgI0hvdElmKQogICAgICAgIC8vIFdpbitWOiBjb2xs
YXBzZSBzZWFyY2guID8/IHNlYXJjaDoga2VlcC9vcGVuIHNlYXJjaCBib3guCiAgICAgICAga2VlcFNl
YXJjaCA9ICEha2VlcFNlYXJjaDsKICAgICAgICB0cnkgeyBoaWRlQ3R4KCk7IH0gY2F0Y2gge30KICAg
ICAgICB0cnkgeyBjbG9zZVRpdGxlRGxnKCk7IH0gY2F0Y2gge30KICAgICAgICB0cnkgewogICAgICAg
ICAgICBjb25zdCB3cmFwID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NlYXJjaC13cmFwJyk7CiAg
ICAgICAgICAgIGNvbnN0IHNyY2ggPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc2VhcmNoJyk7CiAg
ICAgICAgICAgIGNvbnN0IHNjbHIgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc2VhcmNoLWNscicp
OwogICAgICAgICAgICBpZiAoIWtlZXBTZWFyY2gpIHsKICAgICAgICAgICAgICAgIGlmICh3cmFwKSB3
cmFwLmNsYXNzTGlzdC5yZW1vdmUoJ29wZW4nKTsKICAgICAgICAgICAgICAgIGlmIChzcmNoKSB7CiAg
ICAgICAgICAgICAgICAgICAgc3JjaC52YWx1ZSA9ICcnOwogICAgICAgICAgICAgICAgICAgIHNyY2gu
Y2xhc3NMaXN0LnJlbW92ZSgnaGFzLXZhbCcpOwogICAgICAgICAgICAgICAgICAgIHRyeSB7IHNyY2gu
Ymx1cigpOyB9IGNhdGNoIHt9CiAgICAgICAgICAgICAgICB9CiAgICAgICAgICAgICAgICBpZiAoc2Ns
cikgc2Nsci5zdHlsZS5kaXNwbGF5ID0gJ25vbmUnOwogICAgICAgICAgICAgICAgcXVlcnkgPSAnJzsK
ICAgICAgICAgICAgICAgIHdpbmRvdy5fX2hvc3RGaWx0ZXJlZCA9IGZhbHNlOwogICAgICAgICAgICAg
ICAgd2luZG93Ll9faG9zdEZpbHRlclEgPSAnJzsKICAgICAgICAgICAgICAgIC8vIFdpbitW77ya56uL
5Yi755So5pyq6L+H5ruk57yT5a2Y6ZO65YiX6KGo77yM6YG/5YWN5YWI6Zeq6L+H5ruk57uT5p6cL+ep
uuWjs+WGjeetiSBTZXRWaWV3CiAgICAgICAgICAgICAgICB0cnkgewogICAgICAgICAgICAgICAgICAg
IGNvbnN0IGhpdCA9IHZpZXdNZW0uZ2V0KHZpZXdNZW1LZXkoJ2FsbCcsICcnLCBmYWxzZSkpOwogICAg
ICAgICAgICAgICAgICAgIGlmIChoaXQgJiYgQXJyYXkuaXNBcnJheShoaXQuaXRlbXMpICYmIGhpdC5p
dGVtcy5sZW5ndGgpIHsKICAgICAgICAgICAgICAgICAgICAgICAgYWxsQ2xpcHMgPSBoaXQuaXRlbXMu
c2xpY2UoKTsKICAgICAgICAgICAgICAgICAgICAgICAgZGlza1RvdGFsID0gTnVtYmVyKGhpdC50b3Rh
bCkgfHwgaGl0Lml0ZW1zLmxlbmd0aDsKICAgICAgICAgICAgICAgICAgICAgICAgd2luZG93Ll9fZGF0
YVJlYWR5ID0gdHJ1ZTsKICAgICAgICAgICAgICAgICAgICAgICAgaG9zdFB1c2hlZE9uY2UgPSB0cnVl
OwogICAgICAgICAgICAgICAgICAgICAgICBzYXdOb25FbXB0eSA9IHRydWU7CiAgICAgICAgICAgICAg
ICAgICAgICAgIGNsZWFyV2FpdGluZ0RhdGEoKTsKICAgICAgICAgICAgICAgICAgICB9IGVsc2Ugewog
ICAgICAgICAgICAgICAgICAgICAgICBzY2hlZHVsZURlbGF5ZWRTa2VsKCk7CiAgICAgICAgICAgICAg
ICAgICAgfQogICAgICAgICAgICAgICAgfSBjYXRjaCB7CiAgICAgICAgICAgICAgICAgICAgc2NoZWR1
bGVEZWxheWVkU2tlbCgpOwogICAgICAgICAgICAgICAgfQogICAgICAgICAgICB9IGVsc2UgaWYgKHdy
YXApIHsKICAgICAgICAgICAgICAgIHdyYXAuY2xhc3NMaXN0LmFkZCgnb3BlbicpOwogICAgICAgICAg
ICAgICAgaWYgKHNyY2ggJiYgc3JjaC52YWx1ZSkKICAgICAgICAgICAgICAgICAgICBxdWVyeSA9IHNy
Y2gudmFsdWU7CiAgICAgICAgICAgICAgICAvLyA/PyDmkJzntKLvvJrlnKjkuLvmnLrov4fmu6Tnu5Pm
npzliLDovr7liY3vvIzlhYjmjInlhbPplK7lrZfmnKzlnLDmu6TvvIznpoHmraLpl6rlh7rjgIzlhajp
g6jjgI0KICAgICAgICAgICAgICAgIGlmIChTdHJpbmcocXVlcnkgfHwgJycpLnRyaW0oKSkgewogICAg
ICAgICAgICAgICAgICAgIHdpbmRvdy5fX2hvc3RGaWx0ZXJlZCA9IGZhbHNlOwogICAgICAgICAgICAg
ICAgICAgIHdpbmRvdy5fX2hvc3RGaWx0ZXJRID0gJyc7CiAgICAgICAgICAgICAgICB9CiAgICAgICAg
ICAgIH0KICAgICAgICAgICAgdG9kYXlPbmx5ID0gZmFsc2U7CiAgICAgICAgICAgIHRyeSB7CiAgICAg
ICAgICAgICAgICBjb25zdCBidG5Ub2RheSA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdidG4tdG9k
YXknKTsKICAgICAgICAgICAgICAgIGlmIChidG5Ub2RheSkgYnRuVG9kYXkuY2xhc3NMaXN0LnJlbW92
ZSgnb24nKTsKICAgICAgICAgICAgfSBjYXRjaCB7fQogICAgICAgICAgICBjdXJUYWIgPSAnYWxsJzsK
ICAgICAgICAgICAgbG9hZGluZ01vcmUgPSBmYWxzZTsKICAgICAgICAgICAgbWFya1RhYignYWxsJyk7
CiAgICAgICAgICAgIC8vIOS4jeimgSBhaGsoJ2JsdXJQYW5lbCcp77ya5Lya6LefIFNob3dQYW5lbCDm
iqLnhKbngrnvvIxXaW4rVi8/PyDpg73lrrnmmJPpl6rjgIHkubHot7MKICAgICAgICAgICAgcmVuZGVy
KCk7CiAgICAgICAgICAgIC8vIOWQjOatpeW9k+WJjSB0YWIvcXVlcnkg5YiwIEFIS++8iD8/IOabvuWP
queUqCB2aWV3VGFiIOaQnOmUmemhte+8iQogICAgICAgICAgICByZXF1ZXN0VmlldygpOwogICAgICAg
IH0gY2F0Y2gge30KICAgICAgICBzZWxlY3RGaXJzdE9uU2hvdyA9IHRydWU7CiAgICAgICAgbG9jYXRl
QWN0aXZlID0gZmFsc2U7CiAgICAgICAgdXBkYXRlTG9jYXRlQnRuKCk7CiAgICAgICAgY2xlYXJNdWx0
aSgpOwogICAgICAgIGNvbnN0IHZpcyA9IHZpc2libGVMaXN0KCk7CiAgICAgICAgaWYgKHZpcy5sZW5n
dGgpIHsKICAgICAgICAgICAgc2VsZWN0ZWRJZCA9IHZpc1swXS5pZDsKICAgICAgICAgICAgcmFuZ2VB
bmNob3JJZCA9IHNlbGVjdGVkSWQ7CiAgICAgICAgICAgIHJhbmdlQW5jaG9yQ2xpY2tlZCA9IGZhbHNl
OwogICAgICAgICAgICBsaXN0RWwuc2Nyb2xsVG9wID0gMDsKICAgICAgICB9CiAgICAgICAgc3luY0l0
ZW1IaWdobGlnaHQoKTsKICAgIH07CgogICAgZnVuY3Rpb24gY3R4QmluZChpZCwgZm4pIHsKICAgICAg
ICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZChpZCkuYWRkRXZlbnRMaXN0ZW5lcignY2xpY2snLCBlID0+
IHsKICAgICAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICAgICAgaWYgKGN0eENsaXAp
IGZuKGN0eENsaXApOwogICAgICAgICAgICBoaWRlQ3R4KCk7CiAgICAgICAgfSk7CiAgICB9CiAgICBj
dHhCaW5kKCdjLWNvcHknLCAgYyA9PiB7CiAgICAgICAgaWYgKG5vcm1UeXBlKGMudHlwZSkgPT09ICdy
ZWNlbnQnKQogICAgICAgICAgICBhaGsoJ2NvcHlQYXRoJywgU3RyaW5nKGMuZGF0YSB8fCBjLnByZXZp
ZXcgfHwgJycpKTsKICAgICAgICBlbHNlCiAgICAgICAgICAgIGFoaygnY29weUJ5SWQnLCBTdHJpbmco
Yy5pZCkpOwogICAgfSk7CiAgICBjdHhCaW5kKCdjLXBhc3RlJywgYyA9PiB7CiAgICAgICAgYWN0aXZh
dGVDbGlwSXRlbShjKTsKICAgIH0pOwogICAgY3R4QmluZCgnYy1waW4nLCAgIGMgPT4gewogICAgICAg
IC8vIE9wdGltaXN0aWMgZmxpcCDigJQg5Zu65a6a5Y+q6Ziy5reY5rGw77yM5LiN572u6aG277yb5YaN
5qyh6K6/6Zeu5omN6Z2gIFJlY29yZCDpobbliLDkuIrpnaIKICAgICAgICBjb25zdCBuZXh0ID0gIWlz
UGlubmVkKGMpOwogICAgICAgIGMucGlubmVkID0gbmV4dDsKICAgICAgICBjb25zdCBpZCA9ICtjLmlk
OwogICAgICAgIGZvciAoY29uc3QgeCBvZiBhbGxDbGlwcykgewogICAgICAgICAgICBpZiAoK3guaWQg
PT09IGlkKSB4LnBpbm5lZCA9IG5leHQ7CiAgICAgICAgfQogICAgICAgIHJlbmRlcigpOwogICAgICAg
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
IGl0CiAgICAgICAgICAgIHRyeSB7CiAgICAgICAgICAgICAgICBjb25zdCBwaW5DbnQgPSBkb2N1bWVu
dC5nZXRFbGVtZW50QnlJZCgncGluLWNudCcpOwogICAgICAgICAgICAgICAgaWYgKHBpbkNudCAmJiBw
aW5uZWRUb3RhbCA+IDApIHsKICAgICAgICAgICAgICAgICAgICBwaW5DbnQudGV4dENvbnRlbnQgPSBw
aW5uZWRUb3RhbDsKICAgICAgICAgICAgICAgICAgICBwaW5DbnQuc3R5bGUuZGlzcGxheSA9ICcnOwog
ICAgICAgICAgICAgICAgfQogICAgICAgICAgICB9IGNhdGNoIHt9CiAgICAgICAgICAgIC8vIFFRIOaQ
nOe0ouabvuWbuuWumuaOqCBhbGwgdGFiIOKGkiDlvZPliY0gdGFiIOS8muS4gOebtOmqqOaetu+8m+ih
peS4gOasoSByZXF1ZXN0VmlldwogICAgICAgICAgICBpZiAod2FpdGluZ0RhdGEgJiYgcHVzaFEgPT09
IGJveFEpIHsKICAgICAgICAgICAgICAgIHNldFRpbWVvdXQoKCkgPT4gewogICAgICAgICAgICAgICAg
ICAgIGlmICh3YWl0aW5nRGF0YSAmJiBjdXJUYWIgIT09IHBUYWIpCiAgICAgICAgICAgICAgICAgICAg
ICAgIHJlcXVlc3RWaWV3KCk7CiAgICAgICAgICAgICAgICB9LCA0MCk7CiAgICAgICAgICAgIH0KICAg
ICAgICAgICAgcmV0dXJuOwogICAgICAgIH0KCiAgICAgICAgLy8gQm9vdHN0cmFwIHJhY2U6IEFISyBw
dXNoZWQgZW1wdHkgYmVmb3JlIFdhcm1BbGxWaWV3cyDigJRrZWVwIHNrZWxldG9uLCBpZ25vcmUKICAg
ICAgICBjb25zdCBxT24gPSBTdHJpbmcocXVlcnkgfHwgJycpLnRyaW0oKS5sZW5ndGggPiAwOwogICAg
ICAgIGlmICghd2FzQXBwZW5kICYmICFuZXh0SXRlbXMubGVuZ3RoICYmIG5leHRUb3RhbCA8PSAwICYm
ICFxT24gJiYgIW5leHRGaWx0ZXJlZCAmJiAhc2F3Tm9uRW1wdHkpIHsKICAgICAgICAgICAgaWYgKCF3
aW5kb3cuX19lbXB0eUZhbGxiYWNrVCkgewogICAgICAgICAgICAgICAgd2luZG93Ll9fZW1wdHlGYWxs
YmFja1QgPSBzZXRUaW1lb3V0KCgpID0+IHsKICAgICAgICAgICAgICAgICAgICB3aW5kb3cuX19lbXB0
eUZhbGxiYWNrVCA9IDA7CiAgICAgICAgICAgICAgICAgICAgaWYgKHNhd05vbkVtcHR5KSByZXR1cm47
CiAgICAgICAgICAgICAgICAgICAgLy8gVHJ1bHkgZW1wdHkgaW5zdGFsbCBhZnRlciB3YWl0CiAgICAg
ICAgICAgICAgICAgICAgc2F3Tm9uRW1wdHkgPSB0cnVlOwogICAgICAgICAgICAgICAgICAgIGhvc3RQ
dXNoZWRPbmNlID0gdHJ1ZTsKICAgICAgICAgICAgICAgICAgICB3aW5kb3cuX19kYXRhUmVhZHkgPSB0
cnVlOwogICAgICAgICAgICAgICAgICAgIGFsbENsaXBzID0gW107CiAgICAgICAgICAgICAgICAgICAg
ZGlza1RvdGFsID0gMDsKICAgICAgICAgICAgICAgICAgICBjbGVhcldhaXRpbmdEYXRhKCk7CiAgICAg
ICAgICAgICAgICAgICAgdHJ5IHsgcmVuZGVyKCk7IH0gY2F0Y2gge30KICAgICAgICAgICAgICAgIH0s
IDQ1MDApOwogICAgICAgICAgICB9CiAgICAgICAgICAgIHdhaXRpbmdEYXRhID0gdHJ1ZTsKICAgICAg
ICAgICAgd2luZG93Ll9fZGF0YVJlYWR5ID0gZmFsc2U7CiAgICAgICAgICAgIGhvc3RQdXNoZWRPbmNl
ID0gZmFsc2U7CiAgICAgICAgICAgIHNldEJvb3RMb2FkaW5nKHRydWUpOwogICAgICAgICAgICB0cnkg
eyByZW5kZXIoKTsgfSBjYXRjaCB7fQogICAgICAgICAgICByZXR1cm47CiAgICAgICAgfQoKICAgICAg
ICBjbGVhcldhaXRpbmdEYXRhKCk7CiAgICAgICAgYWxsQ2xpcHMgPSBuZXh0SXRlbXM7CiAgICAgICAg
ZGlza1RvdGFsID0gbmV4dFRvdGFsOwogICAgICAgIC8vIEtlZXAgYmFyIGNvbnNpc3RlbnQgaWYgbGlz
dCBncmV3IHBhc3QgYSBzdGFsZSB0b3RhbAogICAgICAgIGlmIChhbGxDbGlwcy5sZW5ndGggPiBkaXNr
VG90YWwpCiAgICAgICAgICAgIGRpc2tUb3RhbCA9IGFsbENsaXBzLmxlbmd0aDsKICAgICAgICB3aW5k
b3cuX19ob3N0RmlsdGVyZWQgPSBuZXh0RmlsdGVyZWQ7CiAgICAgICAgd2luZG93Ll9faG9zdEZpbHRl
clEgPSAobmV4dEZpbHRlcmVkICYmIHB1c2hRKSA/IHB1c2hRIDogJyc7CiAgICAgICAgLy8gRmlsdGVy
ZWQgc2VhcmNoIHdpdGggMCBoaXRzIOKAlG11c3QgbGVhdmUgc2tlbGV0b24gKGhvc3QgZGlkIHJlc3Bv
bmQpCiAgICAgICAgaWYgKCF3YXNBcHBlbmQgJiYgbmV4dEZpbHRlcmVkICYmICFhbGxDbGlwcy5sZW5n
dGggJiYgZGlza1RvdGFsIDw9IDApIHsKICAgICAgICAgICAgaG9zdFB1c2hlZE9uY2UgPSB0cnVlOwog
ICAgICAgICAgICBzYXdOb25FbXB0eSA9IHRydWU7CiAgICAgICAgfQogICAgICAgIGlmIChhbGxDbGlw
cy5sZW5ndGggfHwgZGlza1RvdGFsID4gMCkKICAgICAgICAgICAgc2F3Tm9uRW1wdHkgPSB0cnVlOwog
ICAgICAgIGlmICh3aW5kb3cuX19lbXB0eUZhbGxiYWNrVCkgewogICAgICAgICAgICBjbGVhclRpbWVv
dXQod2luZG93Ll9fZW1wdHlGYWxsYmFja1QpOwogICAgICAgICAgICB3aW5kb3cuX19lbXB0eUZhbGxi
YWNrVCA9IDA7CiAgICAgICAgfQogICAgICAgIGlmICghd2FzQXBwZW5kKSB7CiAgICAgICAgICAgIGNv
bnN0IG1lbVEgPSAocGF5bG9hZCAmJiB0eXBlb2YgcGF5bG9hZCA9PT0gJ29iamVjdCcgJiYgcGF5bG9h
ZC5xdWVyeSAhPSBudWxsKQogICAgICAgICAgICAgICAgPyBTdHJpbmcocGF5bG9hZC5xdWVyeSkgOiBx
dWVyeTsKICAgICAgICAgICAgdmlld01lbS5zZXQodmlld01lbUtleShjdXJUYWIsIG1lbVEsIHRvZGF5
T25seSksIHsKICAgICAgICAgICAgICAgIGl0ZW1zOiBhbGxDbGlwcy5zbGljZSgpLAogICAgICAgICAg
ICAgICAgdG90YWw6IGRpc2tUb3RhbAogICAgICAgICAgICB9KTsKICAgICAgICB9CiAgICAgICAgd2lu
ZG93Ll9fZGF0YVJlYWR5ID0gdHJ1ZTsKICAgICAgICBob3N0UHVzaGVkT25jZSA9IHRydWU7CgogICAg
ICAgIC8vIE1pZC13aGVlbDoga2VlcCBkYXRhLCBkZWxheSBET00gc28gc2Nyb2xsL2RyYWcgbmV2ZXIg
aGl0Y2ggb24gYXBwZW5kIHBhaW50CiAgICAgICAgaWYgKHdhc0FwcGVuZCAmJiB3aW5kb3cuX19zY3Jv
bGxCdXN5ICYmICF3aW5kb3cuX19wZW5kaW5nSnVtcElkKSB7CiAgICAgICAgICAgIGNvbnN0IGZyb21M
ZW4gPSAocHJldkl0ZW1zICYmIHByZXZJdGVtcy5sZW5ndGgpID8gcHJldkl0ZW1zLmxlbmd0aCA6IDA7
CiAgICAgICAgICAgIGlmICghX3BlbmRpbmdBcHBlbmQpCiAgICAgICAgICAgICAgICBfcGVuZGluZ0Fw
cGVuZCA9IHsgZnJvbUxlbjogZnJvbUxlbiB9OwogICAgICAgICAgICB0cnkgeyByZWZyZXNoTGlzdENo
cm9tZSgpOyB9IGNhdGNoIHt9CiAgICAgICAgICAgIHJldHVybjsKICAgICAgICB9CgogICAgICAgIGNv
bnN0IHdhc0Jvb3RMb2FkaW5nID0gYm9vdExvYWRpbmc7CiAgICAgICAgbGV0IHNhbWVQYWludCA9IGZh
bHNlOwogICAgICAgIGNvbnN0IHByZXZMZW4gPSAocHJldkl0ZW1zICYmIHByZXZJdGVtcy5sZW5ndGgp
ID8gcHJldkl0ZW1zLmxlbmd0aCA6IDA7CiAgICAgICAgaWYgKCF3YXNBcHBlbmQgJiYgIXdhc0Jvb3RM
b2FkaW5nICYmIHByZXZJdGVtcyAmJiBwcmV2SXRlbXMubGVuZ3RoID09PSBhbGxDbGlwcy5sZW5ndGgg
JiYgcHJldkl0ZW1zLmxlbmd0aCkgewogICAgICAgICAgICBzYW1lUGFpbnQgPSB0cnVlOwogICAgICAg
ICAgICBmb3IgKGxldCBpID0gMDsgaSA8IGFsbENsaXBzLmxlbmd0aDsgaSsrKSB7CiAgICAgICAgICAg
ICAgICBpZiAoK3ByZXZJdGVtc1tpXS5pZCAhPT0gK2FsbENsaXBzW2ldLmlkKSB7IHNhbWVQYWludCA9
IGZhbHNlOyBicmVhazsgfQogICAgICAgICAgICB9CiAgICAgICAgICAgIGlmIChzYW1lUGFpbnQgJiYg
IWxpc3RFbC5xdWVyeVNlbGVjdG9yKCcuaXRtJykpIHNhbWVQYWludCA9IGZhbHNlOwogICAgICAgIH0K
ICAgICAgICBjb25zdCBmaW5pc2hVcGRhdGUgPSAoKSA9PiB7CiAgICAgICAgICAgIGNvbnN0IHRSZW5k
ZXIwID0gKHR5cGVvZiBwZXJmb3JtYW5jZSAhPT0gJ3VuZGVmaW5lZCcgJiYgcGVyZm9ybWFuY2Uubm93
KSA/IHBlcmZvcm1hbmNlLm5vdygpIDogRGF0ZS5ub3coKTsKICAgICAgICAgICAgY2xlYXJXYWl0aW5n
RGF0YSgpOwogICAgICAgICAgICBpZiAod2FzQXBwZW5kICYmICF3YXNCb290TG9hZGluZyAmJiBwcmV2
TGVuID4gMCAmJiBhbGxDbGlwcy5sZW5ndGggPiBwcmV2TGVuKSB7CiAgICAgICAgICAgICAgICBhcHBl
bmRSZW5kZXIocHJldkxlbik7CiAgICAgICAgICAgIH0gZWxzZSBpZiAoIXNhbWVQYWludCkgewogICAg
ICAgICAgICAgICAgcmVuZGVyKCk7CiAgICAgICAgICAgICAgICBhcHBseVRhYlN3aXRjaEFuaW0oKTsK
ICAgICAgICAgICAgICAgIGlmIChrZWVwU2Nyb2xsKQogICAgICAgICAgICAgICAgICAgIGxpc3RFbC5z
Y3JvbGxUb3AgPSBzdDsKICAgICAgICAgICAgICAgIGVsc2UKICAgICAgICAgICAgICAgICAgICBsaXN0
RWwuc2Nyb2xsVG9wID0gMDsKICAgICAgICAgICAgfSBlbHNlIHsKICAgICAgICAgICAgICAgIHRyeSB7
IHJlZnJlc2hMaXN0Q2hyb21lKCk7IH0gY2F0Y2gge30KICAgICAgICAgICAgICAgIGlmIChrZWVwU2Ny
b2xsKQogICAgICAgICAgICAgICAgICAgIGxpc3RFbC5zY3JvbGxUb3AgPSBzdDsKICAgICAgICAgICAg
fQogICAgICAgICAgICBjb25zdCB0MSA9ICh0eXBlb2YgcGVyZm9ybWFuY2UgIT09ICd1bmRlZmluZWQn
ICYmIHBlcmZvcm1hbmNlLm5vdykgPyBwZXJmb3JtYW5jZS5ub3coKSA6IERhdGUubm93KCk7CiAgICAg
ICAgICAgIHdpbmRvdy5fX3BlcmZNYXJrKCdqc191cGRhdGVDbGlwc19kb25lIHJlbmRlck1zPScgKyBN
YXRoLnJvdW5kKHQxIC0gdFJlbmRlcjApICsgJyB0b3RhbE1zPScgKyBNYXRoLnJvdW5kKHQxIC0gdDAp
ICsgJyBuPScgKyBhbGxDbGlwcy5sZW5ndGgpOwogICAgICAgIH07CiAgICAgICAgaWYgKHdhc0Jvb3RM
b2FkaW5nKSB7CiAgICAgICAgICAgIGNvbnN0IHNpbmNlID0gd2luZG93Ll9fc2tlbFNpbmNlIHx8IDA7
CiAgICAgICAgICAgIGNvbnN0IHdhaXQgPSBzaW5jZSA/IE1hdGgubWF4KDAsIDgwIC0gKERhdGUubm93
KCkgLSBzaW5jZSkpIDogMDsKICAgICAgICAgICAgaWYgKHdhaXQgPiAwKQogICAgICAgICAgICAgICAg
c2V0VGltZW91dChmaW5pc2hVcGRhdGUsIHdhaXQpOwogICAgICAgICAgICBlbHNlCiAgICAgICAgICAg
ICAgICBmaW5pc2hVcGRhdGUoKTsKICAgICAgICB9IGVsc2UgewogICAgICAgICAgICBmaW5pc2hVcGRh
dGUoKTsKICAgICAgICB9CiAgICB9OwogICAgd2luZG93Ll9fc2V0UGlubmVkID0gdiA9PiB7CiAgICAg
ICAgcGlubmVkVUkgPSAhIXY7CiAgICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2J0bi1waW4n
KS5jbGFzc0xpc3QudG9nZ2xlKCdvbicsIHBpbm5lZFVJKTsKICAgIH07CiAgICB3aW5kb3cuX19sb2Fk
TW9yZURvbmUgPSAoKSA9PiB7CiAgICAgICAgbG9hZGluZ01vcmUgPSBmYWxzZTsKICAgICAgICBpZiAo
d2luZG93Ll9fbG9hZE1vcmVXYXRjaCkgewogICAgICAgICAgICBjbGVhclRpbWVvdXQod2luZG93Ll9f
bG9hZE1vcmVXYXRjaCk7CiAgICAgICAgICAgIHdpbmRvdy5fX2xvYWRNb3JlV2F0Y2ggPSAwOwogICAg
ICAgIH0KICAgICAgICBpZiAod2luZG93Ll9fcGVuZGluZ0p1bXBJZCkKICAgICAgICAgICAgdHJ5Q29u
dGludWVKdW1wKCk7CiAgICB9OwoKICAgIGluaXRTZXBVaSgpOwogICAgc2NoZWR1bGVEZWxheWVkU2tl
bCgpOwogICAgd2luZG93Ll9fcGVyZk1hcmsgJiYgd2luZG93Ll9fcGVyZk1hcmsoJ2pzX2Jvb3QgcmVx
dWVzdFZpZXcnKTsKICAgIHJlcXVlc3RWaWV3KCk7CiAgICAvLyBzY2hlZHVsZURlbGF5ZWRTa2VsIGFs
cmVhZHkgcmVuZGVyKCknZCB3aGVuIGVtcHR5OyBzdGlsbCBwYWludCBvbmNlIGZvciBjaHJvbWUKCiAg
ICA8L3NjcmlwdD4KPC9ib2R5Pgo8L2h0bWw+
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
    ; Persist async —sync disk + SetView made pin clicks hitch
    EnqueueDiskJob(DiskSetPinned.Bind(uid, newPin, pinAt))
    if viewTab = "pinned" || viewQuery != ""
        QueueSetView(viewTab, viewQuery, viewToday ? "1" : "0")
    else
        RequestUiPush()
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
        if item.imgFile = ""
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
