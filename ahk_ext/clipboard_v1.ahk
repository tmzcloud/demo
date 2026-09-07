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
APP_HOST     := "clipui.local"   ; HTML via virtual host so clips.store thumbs work
DEBUG_LOG    := CLIP_V1_DIR "\debug.log"
ERROR_LOG    := CLIP_V1_DIR "\error.log"
QUEUE_STATE_FILE := CLIP_V1_DIR "\paste_queue.json"
QUEUE_META_FILE  := CLIP_V1_DIR "\queue_meta.tsv"   ; uid -> group/index (sync, survives restart)

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
ICAgdXNlci1zZWxlY3Q6IG5vbmU7CiAgICAgICAgfQogICAgICAgIDo6LXdlYmtpdC1zY3JvbGxiYXIg
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
LXNocmluazogMDsKICAgICAgICAgICAgcGFkZGluZzogNXB4IDZweCA1cHggOHB4OyBnYXA6IDRweDsK
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
fQoKICAgICAgICAjYnRuLXBpbiB7CiAgICAgICAgICAgIHdpZHRoOiAyOHB4OyBoZWlnaHQ6IDI4cHg7
IGZsZXgtc2hyaW5rOiAwOwogICAgICAgICAgICBkaXNwbGF5OiBmbGV4OyBhbGlnbi1pdGVtczogY2Vu
dGVyOyBqdXN0aWZ5LWNvbnRlbnQ6IGNlbnRlcjsKICAgICAgICAgICAgYm9yZGVyOiAxLjVweCBzb2xp
ZCB0cmFuc3BhcmVudDsgYmFja2dyb3VuZDogbm9uZTsgY3Vyc29yOiBwb2ludGVyOwogICAgICAgICAg
ICBjb2xvcjogdmFyKC0tdHh0Myk7IGJvcmRlci1yYWRpdXM6IHZhcigtLXIpOwogICAgICAgICAgICAt
d2Via2l0LWFwcC1yZWdpb246IG5vLWRyYWc7IGFwcC1yZWdpb246IG5vLWRyYWc7CiAgICAgICAgICAg
IHRyYW5zaXRpb246IGNvbG9yIHZhcigtLXRyKSwgYmFja2dyb3VuZCB2YXIoLS10ciksIGJvcmRlci1j
b2xvciB2YXIoLS10cik7CiAgICAgICAgfQogICAgICAgICNidG4tcGluOmhvdmVyIHsgY29sb3I6IHZh
cigtLWFjYyk7IGJhY2tncm91bmQ6IHJnYmEoOTEsMTE1LDIzMiwuMSk7IH0KICAgICAgICAjYnRuLXBp
bi5vbiAgewogICAgICAgICAgICBjb2xvcjogdmFyKC0tYWNjKTsKICAgICAgICAgICAgYmFja2dyb3Vu
ZDogcmdiYSg5MSwxMTUsMjMyLC4xOCk7CiAgICAgICAgICAgIGJvcmRlci1jb2xvcjogcmdiYSg5MSwx
MTUsMjMyLC41NSk7CiAgICAgICAgfQogICAgICAgICNidG4tcGluIHN2ZyB7IHdpZHRoOiAxNHB4OyBo
ZWlnaHQ6IDE0cHg7IGRpc3BsYXk6IGJsb2NrOyB9CgogICAgICAgICNidG4tbG9jYXRlIHsKICAgICAg
ICAgICAgd2lkdGg6IDI4cHg7IGhlaWdodDogMjhweDsgZmxleC1zaHJpbms6IDA7CiAgICAgICAgICAg
IGRpc3BsYXk6IGZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGp1c3RpZnktY29udGVudDogY2VudGVy
OwogICAgICAgICAgICBib3JkZXI6IG5vbmU7IGJhY2tncm91bmQ6IG5vbmU7IGN1cnNvcjogcG9pbnRl
cjsKICAgICAgICAgICAgY29sb3I6IHZhcigtLXR4dDMpOyBib3JkZXItcmFkaXVzOiB2YXIoLS1yKTsK
ICAgICAgICAgICAgLXdlYmtpdC1hcHAtcmVnaW9uOiBuby1kcmFnOyBhcHAtcmVnaW9uOiBuby1kcmFn
OwogICAgICAgICAgICB0cmFuc2l0aW9uOiBjb2xvciB2YXIoLS10ciksIGJhY2tncm91bmQgdmFyKC0t
dHIpLCBvcGFjaXR5IHZhcigtLXRyKTsKICAgICAgICB9CiAgICAgICAgI2J0bi1sb2NhdGU6aG92ZXI6
bm90KDpkaXNhYmxlZCkgeyBjb2xvcjogdmFyKC0tYWNjKTsgYmFja2dyb3VuZDogcmdiYSg5MSwxMTUs
MjMyLC4xKTsgfQogICAgICAgICNidG4tbG9jYXRlOmRpc2FibGVkIHsgb3BhY2l0eTogLjM1OyBjdXJz
b3I6IGRlZmF1bHQ7IH0KICAgICAgICAjYnRuLWxvY2F0ZS5oYXMtdGFyZ2V0IHsgY29sb3I6IHZhcigt
LWFjYyk7IH0KICAgICAgICAjYnRuLWxvY2F0ZS5vbiB7CiAgICAgICAgICAgIGNvbG9yOiB2YXIoLS1h
Y2MpOwogICAgICAgICAgICBiYWNrZ3JvdW5kOiByZ2JhKDkxLDExNSwyMzIsLjE4KTsKICAgICAgICB9
CiAgICAgICAgI2J0bi1sb2NhdGUgc3ZnIHsgd2lkdGg6IDE1cHg7IGhlaWdodDogMTVweDsgZGlzcGxh
eTogYmxvY2s7IH0KICAgICAgICAjaGRyOmhhcygjc2VhcmNoLXdyYXAub3BlbikgI2J0bi1sb2NhdGUg
ewogICAgICAgICAgICBkaXNwbGF5OiBub25lOwogICAgICAgIH0KCiAgICAgICAgLyog4pSA4pSAIFJv
dyAyIOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKU
gOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKU
gCAqLwogICAgICAgICN0YWJzIHsKICAgICAgICAgICAgcG9zaXRpb246IHJlbGF0aXZlOwogICAgICAg
ICAgICBkaXNwbGF5OiBmbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBnYXA6IDJweDsgZmxleC13cmFw
OiBub3dyYXA7CiAgICAgICAgICAgIHBhZGRpbmc6IDVweCA2cHggNXB4IDhweDsgZmxleC1zaHJpbms6
IDA7CiAgICAgICAgICAgIGJhY2tncm91bmQ6ICNmMmY0Zjk7CiAgICAgICAgfQogICAgICAgICN0YWIt
aW5rIHsKICAgICAgICAgICAgcG9zaXRpb246IGFic29sdXRlOwogICAgICAgICAgICBsZWZ0OiAwOyB0
b3A6IDA7CiAgICAgICAgICAgIGhlaWdodDogMjJweDsKICAgICAgICAgICAgYm9yZGVyLXJhZGl1czog
OTk5cHg7CiAgICAgICAgICAgIGJhY2tncm91bmQ6ICNmZmY7CiAgICAgICAgICAgIGJveC1zaGFkb3c6
IDAgMXB4IDNweCByZ2JhKDAsMCwwLC4wNyksIDAgMCAwIDFweCByZ2JhKDkxLDExNSwyMzIsLjA2KTsK
ICAgICAgICAgICAgcG9pbnRlci1ldmVudHM6IG5vbmU7CiAgICAgICAgICAgIHotaW5kZXg6IDA7CiAg
ICAgICAgICAgIHRyYW5zZm9ybTogdHJhbnNsYXRlM2QoMCwwLDApIHNjYWxlWCgxKTsKICAgICAgICAg
ICAgdHJhbnNmb3JtLW9yaWdpbjogY2VudGVyIGJvdHRvbTsKICAgICAgICAgICAgdHJhbnNpdGlvbjoK
ICAgICAgICAgICAgICAgIHRyYW5zZm9ybSAwLjM0cyBjdWJpYy1iZXppZXIoMC4yMiwgMS4xOCwgMC4z
MiwgMSksCiAgICAgICAgICAgICAgICBoZWlnaHQgMC4yNHMgZWFzZTsKICAgICAgICAgICAgd2lsbC1j
aGFuZ2U6IHRyYW5zZm9ybSwgaGVpZ2h0OwogICAgICAgIH0KICAgICAgICAjdGFiLWluay5zcXVhc2gg
ewogICAgICAgICAgICB0cmFuc2l0aW9uOgogICAgICAgICAgICAgICAgdHJhbnNmb3JtIDAuMzBzIGN1
YmljLWJlemllcigwLjM0LCAxLjI4LCAwLjQ0LCAxKSwKICAgICAgICAgICAgICAgIGhlaWdodCAwLjIw
cyBlYXNlOwogICAgICAgIH0KICAgICAgICAudGFiIHsKICAgICAgICAgICAgcG9zaXRpb246IHJlbGF0
aXZlOwogICAgICAgICAgICB6LWluZGV4OiAxOwogICAgICAgICAgICBwYWRkaW5nOiAzcHggMTBweDsg
Zm9udC1zaXplOiAxMXB4OyBjb2xvcjogdmFyKC0tdHh0Mik7IGN1cnNvcjogcG9pbnRlcjsKICAgICAg
ICAgICAgYm9yZGVyLXJhZGl1czogOTk5cHg7IHdoaXRlLXNwYWNlOiBub3dyYXA7CiAgICAgICAgICAg
IGJhY2tncm91bmQ6IHRyYW5zcGFyZW50OwogICAgICAgICAgICB0cmFuc2l0aW9uOiBjb2xvciAwLjI4
cyBjdWJpYy1iZXppZXIoMC4yMiwgMSwgMC4zNiwgMSksCiAgICAgICAgICAgICAgICAgICAgICAgIHRy
YW5zZm9ybSAwLjI4cyBjdWJpYy1iZXppZXIoMC4yMiwgMSwgMC4zNiwgMSk7CiAgICAgICAgICAgIC13
ZWJraXQtYXBwLXJlZ2lvbjogbm8tZHJhZzsgYXBwLXJlZ2lvbjogbm8tZHJhZzsKICAgICAgICB9CiAg
ICAgICAgLnRhYjpob3ZlciB7IGNvbG9yOiB2YXIoLS10eHQpOyBiYWNrZ3JvdW5kOiB0cmFuc3BhcmVu
dDsgfQogICAgICAgIC50YWI6YWN0aXZlIHsgdHJhbnNmb3JtOiBzY2FsZSgwLjk2KTsgfQogICAgICAg
IC50YWIub24geyBjb2xvcjogdmFyKC0tYWNjKTsgYmFja2dyb3VuZDogdHJhbnNwYXJlbnQ7IGJveC1z
aGFkb3c6IG5vbmU7IGZvbnQtd2VpZ2h0OiA2MDA7IH0KICAgICAgICAuYmFkZ2UgewogICAgICAgICAg
ICBkaXNwbGF5OiBpbmxpbmUtZmxleDsgbWluLXdpZHRoOiAxNHB4OyBoZWlnaHQ6IDE0cHg7IHBhZGRp
bmc6IDAgM3B4OwogICAgICAgICAgICBhbGlnbi1pdGVtczogY2VudGVyOyBqdXN0aWZ5LWNvbnRlbnQ6
IGNlbnRlcjsKICAgICAgICAgICAgYmFja2dyb3VuZDogdmFyKC0tYWNjKTsgY29sb3I6ICNmZmY7IGZv
bnQtc2l6ZTogOXB4OyBib3JkZXItcmFkaXVzOiA3cHg7IGZvbnQtd2VpZ2h0OiA3MDA7CiAgICAgICAg
fQogICAgICAgICN0YWItYWN0aW9ucyB7CiAgICAgICAgICAgIG1hcmdpbi1sZWZ0OiBhdXRvOyBkaXNw
bGF5OiBmbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBnYXA6IDRweDsKICAgICAgICAgICAgY29sb3I6
IHZhcigtLXR4dDMpOyBmb250LXNpemU6IDEwcHg7CiAgICAgICAgICAgIC13ZWJraXQtYXBwLXJlZ2lv
bjogbm8tZHJhZzsgYXBwLXJlZ2lvbjogbm8tZHJhZzsKICAgICAgICB9CiAgICAgICAgI2Jhci10eHQg
eyB3aGl0ZS1zcGFjZTogbm93cmFwOyB9CiAgICAgICAgI2J0bi1jbHIgewogICAgICAgICAgICBkaXNw
bGF5OiBmbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBqdXN0aWZ5LWNvbnRlbnQ6IGNlbnRlcjsKICAg
ICAgICAgICAgd2lkdGg6IDI2cHg7IGhlaWdodDogMjZweDsgYm9yZGVyOiBub25lOyBiYWNrZ3JvdW5k
OiBub25lOyBjb2xvcjogdmFyKC0tdHh0Myk7CiAgICAgICAgICAgIGN1cnNvcjogcG9pbnRlcjsgYm9y
ZGVyLXJhZGl1czogdmFyKC0tcik7CiAgICAgICAgICAgIC13ZWJraXQtYXBwLXJlZ2lvbjogbm8tZHJh
ZzsgYXBwLXJlZ2lvbjogbm8tZHJhZzsKICAgICAgICAgICAgdHJhbnNpdGlvbjogY29sb3IgdmFyKC0t
dHIpLCBiYWNrZ3JvdW5kIHZhcigtLXRyKTsKICAgICAgICB9CiAgICAgICAgI2J0bi1jbHI6aG92ZXIg
eyBjb2xvcjogI2ZmN2I5YzsgYmFja2dyb3VuZDogcmdiYSgyNTUsMTIzLDE1NiwuMDgpOyB9CiAgICAg
ICAgI2J0bi1jbHIgc3ZnIHsgd2lkdGg6IDE0cHg7IGhlaWdodDogMTRweDsgZGlzcGxheTogYmxvY2s7
IH0KCiAgICAgICAgLyog4pSA4pSAIExpc3Qg4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA
4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA
4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSAICovCiAgICAgICAgI2xpc3QgewogICAgICAgICAgICBm
bGV4OiAxOyBvdmVyZmxvdy15OiBhdXRvOyBvdmVyZmxvdy14OiBoaWRkZW47IHBhZGRpbmc6IDZweCA4
cHggNnB4IDEwcHg7IGN1cnNvcjogZGVmYXVsdDsKICAgICAgICAgICAgLyogTVVTVCBiZSBuby1kcmFn
OiBkcmFnIHJlZ2lvbiBvbiB0aGUgc2Nyb2xsZXIgbWFrZXMgV2ViVmlldzIgc2Nyb2xsYmFyL3doZWVs
IGhpdGNoICovCiAgICAgICAgICAgIC13ZWJraXQtYXBwLXJlZ2lvbjogbm8tZHJhZzsgYXBwLXJlZ2lv
bjogbm8tZHJhZzsKICAgICAgICAgICAgbWluLWhlaWdodDogMDsKICAgICAgICAgICAgb3ZlcmZsb3ct
YW5jaG9yOiBub25lOwogICAgICAgIH0KICAgICAgICAvKiBXaGlsZSBzY3JvbGxpbmc6IGtpbGwgaG92
ZXIgYW5pbWF0aW9ucyB0aGF0IGNhdXNlIGxheW91dC9wYWludCB0aHJhc2ggKi8KICAgICAgICAjbGlz
dC5pcy1zY3JvbGxpbmcgLml0bSB7CiAgICAgICAgICAgIHRyYW5zaXRpb246IG5vbmUgIWltcG9ydGFu
dDsKICAgICAgICB9CiAgICAgICAgI2xpc3QuaXMtc2Nyb2xsaW5nIC5pdG06OmJlZm9yZSwKICAgICAg
ICAjbGlzdC5pcy1zY3JvbGxpbmcgLml0bTo6YWZ0ZXIgewogICAgICAgICAgICB0cmFuc2l0aW9uOiBu
b25lICFpbXBvcnRhbnQ7CiAgICAgICAgfQogICAgICAgIEBrZXlmcmFtZXMgdGFiUGFuZUluTHIgewog
ICAgICAgICAgICBmcm9tIHsgb3BhY2l0eTogMDsgdHJhbnNmb3JtOiB0cmFuc2xhdGVYKC00MHB4KTsg
fQogICAgICAgICAgICB0byB7IG9wYWNpdHk6IDE7IHRyYW5zZm9ybTogdHJhbnNsYXRlWCgwKTsgfQog
ICAgICAgIH0KICAgICAgICBAa2V5ZnJhbWVzIHRhYlBhbmVJblJsIHsKICAgICAgICAgICAgZnJvbSB7
IG9wYWNpdHk6IDA7IHRyYW5zZm9ybTogdHJhbnNsYXRlWCg0MHB4KTsgfQogICAgICAgICAgICB0byB7
IG9wYWNpdHk6IDE7IHRyYW5zZm9ybTogdHJhbnNsYXRlWCgwKTsgfQogICAgICAgIH0KICAgICAgICAj
bGlzdC50YWItaW4tbHIgeyBhbmltYXRpb246IHRhYlBhbmVJbkxyIC4zNHMgY3ViaWMtYmV6aWVyKC4y
MiwgMSwgLjM2LCAxKSBib3RoOyB9CiAgICAgICAgI2xpc3QudGFiLWluLXJsIHsgYW5pbWF0aW9uOiB0
YWJQYW5lSW5SbCAuMzRzIGN1YmljLWJlemllciguMjIsIDEsIC4zNiwgMSkgYm90aDsgfQogICAgICAg
ICNidG4tdG9wIHsKICAgICAgICAgICAgcG9zaXRpb246IGFic29sdXRlOyByaWdodDogMTBweDsgYm90
dG9tOiAxMHB4OyB6LWluZGV4OiAyMDsKICAgICAgICAgICAgd2lkdGg6IDI4cHg7IGhlaWdodDogMjhw
eDsgYm9yZGVyOiBub25lOyBib3JkZXItcmFkaXVzOiA1MCU7CiAgICAgICAgICAgIGRpc3BsYXk6IG5v
bmU7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGp1c3RpZnktY29udGVudDogY2VudGVyOwogICAgICAgICAg
ICBiYWNrZ3JvdW5kOiAjZmZmOyBjb2xvcjogdmFyKC0tdHh0Mik7CiAgICAgICAgICAgIGJveC1zaGFk
b3c6IDAgMnB4IDhweCByZ2JhKDI0LDMyLDU2LC4xNik7CiAgICAgICAgICAgIGN1cnNvcjogcG9pbnRl
cjsKICAgICAgICAgICAgLXdlYmtpdC1hcHAtcmVnaW9uOiBuby1kcmFnOyBhcHAtcmVnaW9uOiBuby1k
cmFnOwogICAgICAgICAgICB0cmFuc2l0aW9uOiBiYWNrZ3JvdW5kIHZhcigtLXRyKSwgY29sb3IgdmFy
KC0tdHIpLCBib3gtc2hhZG93IHZhcigtLXRyKTsKICAgICAgICB9CiAgICAgICAgI2J0bi10b3Aub24g
eyBkaXNwbGF5OiBmbGV4OyB9CiAgICAgICAgI2J0bi10b3A6aG92ZXIgeyBjb2xvcjogdmFyKC0tYWNj
KTsgYmFja2dyb3VuZDogI2VkZjFmZjsgYm94LXNoYWRvdzogMCAzcHggMTBweCByZ2JhKDkxLDExNSwy
MzIsLjI1KTsgfQogICAgICAgICNidG4tdG9wIHN2ZyB7IHdpZHRoOiAxNHB4OyBoZWlnaHQ6IDE0cHg7
IGRpc3BsYXk6IGJsb2NrOyB9CiAgICAgICAgI2VtcHR5IHsKICAgICAgICAgICAgZGlzcGxheTogbm9u
ZTsgZmxleC1kaXJlY3Rpb246IGNvbHVtbjsgYWxpZ24taXRlbXM6IGNlbnRlcjsganVzdGlmeS1jb250
ZW50OiBjZW50ZXI7CiAgICAgICAgICAgIHBhZGRpbmc6IDQ4cHggMTZweDsgY29sb3I6IHZhcigtLXR4
dDMpOyBnYXA6IDhweDsKICAgICAgICAgICAgLXdlYmtpdC1hcHAtcmVnaW9uOiBkcmFnOyBhcHAtcmVn
aW9uOiBkcmFnOwogICAgICAgIH0KICAgICAgICAjZW1wdHkub24geyBkaXNwbGF5OiBmbGV4OyB9CiAg
ICAgICAgLmUtdHh0IHsgZm9udC1zaXplOiAxMnB4OyB0ZXh0LWFsaWduOiBjZW50ZXI7IGxldHRlci1z
cGFjaW5nOiAuMDJlbTsgfQogICAgICAgICNza2VsIHsKICAgICAgICAgICAgZGlzcGxheTogbm9uZTsg
ZmxleC1kaXJlY3Rpb246IGNvbHVtbjsgZ2FwOiA4cHg7CiAgICAgICAgICAgIHBhZGRpbmc6IDRweCAy
cHggMTBweDsgLXdlYmtpdC1hcHAtcmVnaW9uOiBkcmFnOyBhcHAtcmVnaW9uOiBkcmFnOwogICAgICAg
IH0KICAgICAgICAjc2tlbC5vbiB7IGRpc3BsYXk6IGZsZXg7IH0KICAgICAgICAjYXBwLmJvb3QtbG9h
ZGluZyAjc2tlbCB7CiAgICAgICAgICAgIGRpc3BsYXk6IGZsZXggIWltcG9ydGFudDsKICAgICAgICB9
CiAgICAgICAgI2FwcC5ib290LWxvYWRpbmcgI2VtcHR5IHsKICAgICAgICAgICAgZGlzcGxheTogbm9u
ZSAhaW1wb3J0YW50OwogICAgICAgIH0KICAgICAgICAuc2stcm93IHsKICAgICAgICAgICAgZGlzcGxh
eTogZmxleDsgYWxpZ24taXRlbXM6IGZsZXgtc3RhcnQ7IGdhcDogMTBweDsKICAgICAgICAgICAgcGFk
ZGluZzogMTBweCA4cHg7IGJvcmRlci1yYWRpdXM6IDhweDsKICAgICAgICAgICAgYmFja2dyb3VuZDog
cmdiYSgyNTUsMjU1LDI1NSwuNzIpOwogICAgICAgICAgICBib3JkZXI6IDFweCBzb2xpZCByZ2JhKDE3
MCwxODAsMjAwLC40NSk7CiAgICAgICAgICAgIHBvc2l0aW9uOiByZWxhdGl2ZTsKICAgICAgICAgICAg
b3ZlcmZsb3c6IGhpZGRlbjsKICAgICAgICB9CiAgICAgICAgLnNrLXJvdzo6YWZ0ZXIgewogICAgICAg
ICAgICBjb250ZW50OiAnJzsKICAgICAgICAgICAgcG9zaXRpb246IGFic29sdXRlOwogICAgICAgICAg
ICBpbnNldDogMDsKICAgICAgICAgICAgYmFja2dyb3VuZDogbGluZWFyLWdyYWRpZW50KDkwZGVnLCB0
cmFuc3BhcmVudCAwJSwgcmdiYSgyNTUsMjU1LDI1NSwuNzIpIDQ4JSwgdHJhbnNwYXJlbnQgMTAwJSk7
CiAgICAgICAgICAgIHRyYW5zZm9ybTogdHJhbnNsYXRlWCgtMTIwJSk7CiAgICAgICAgICAgIGFuaW1h
dGlvbjogc2stc3dlZXAgMC45NXMgZWFzZS1pbi1vdXQgaW5maW5pdGU7CiAgICAgICAgICAgIHBvaW50
ZXItZXZlbnRzOiBub25lOwogICAgICAgIH0KICAgICAgICBAa2V5ZnJhbWVzIHNrLXN3ZWVwIHsKICAg
ICAgICAgICAgMTAwJSB7IHRyYW5zZm9ybTogdHJhbnNsYXRlWCgxMjAlKTsgfQogICAgICAgIH0KICAg
ICAgICAuc2staWNvLCAuc2stbGluZSB7CiAgICAgICAgICAgIGJhY2tncm91bmQ6IGxpbmVhci1ncmFk
aWVudCg5MGRlZywgI2I4YzJkOCAwJSwgI2YwZjRmYSAzOCUsICNkY2UzZjAgNTIlLCAjYjhjMmQ4IDEw
MCUpOwogICAgICAgICAgICBiYWNrZ3JvdW5kLXNpemU6IDI0MCUgMTAwJTsKICAgICAgICAgICAgYW5p
bWF0aW9uOiBzay1zaGltbWVyIDAuNzJzIGVhc2UtaW4tb3V0IGluZmluaXRlOwogICAgICAgICAgICB3
aWxsLWNoYW5nZTogYmFja2dyb3VuZC1wb3NpdGlvbjsKICAgICAgICAgICAgYm9yZGVyLXJhZGl1czog
NnB4OwogICAgICAgIH0KICAgICAgICAuc2staWNvIHsgd2lkdGg6IDM0cHg7IGhlaWdodDogMzRweDsg
ZmxleC1zaHJpbms6IDA7IGJvcmRlci1yYWRpdXM6IDhweDsgfQogICAgICAgIC5zay1ib2R5IHsgZmxl
eDogMTsgbWluLXdpZHRoOiAwOyBkaXNwbGF5OiBmbGV4OyBmbGV4LWRpcmVjdGlvbjogY29sdW1uOyBn
YXA6IDhweDsgcGFkZGluZy10b3A6IDJweDsgfQogICAgICAgIC5zay1saW5lIHsgaGVpZ2h0OiAxMHB4
OyB3aWR0aDogMTAwJTsgfQogICAgICAgIC5zay1saW5lLnNob3J0IHsgd2lkdGg6IDQyJTsgfQogICAg
ICAgIC5zay1saW5lLm1pZCB7IHdpZHRoOiA2OCU7IH0KICAgICAgICAuc2stcm93Om50aC1jaGlsZCgy
KTo6YWZ0ZXIgeyBhbmltYXRpb24tZGVsYXk6IC4xMnM7IH0KICAgICAgICAuc2stcm93Om50aC1jaGls
ZCgzKTo6YWZ0ZXIgeyBhbmltYXRpb24tZGVsYXk6IC4yNHM7IH0KICAgICAgICAuc2stcm93Om50aC1j
aGlsZCg0KTo6YWZ0ZXIgeyBhbmltYXRpb24tZGVsYXk6IC4zNnM7IH0KICAgICAgICAuc2stcm93Om50
aC1jaGlsZCg1KTo6YWZ0ZXIgeyBhbmltYXRpb24tZGVsYXk6IC40OHM7IH0KICAgICAgICAuc2stcm93
Om50aC1jaGlsZCg2KTo6YWZ0ZXIgeyBhbmltYXRpb24tZGVsYXk6IC42czsgfQogICAgICAgIEBrZXlm
cmFtZXMgc2stc2hpbW1lciB7CiAgICAgICAgICAgIDAlIHsgYmFja2dyb3VuZC1wb3NpdGlvbjogMTAw
JSAwOyB9CiAgICAgICAgICAgIDEwMCUgeyBiYWNrZ3JvdW5kLXBvc2l0aW9uOiAtMTAwJSAwOyB9CiAg
ICAgICAgfQogICAgICAgIC5saXN0LW1vcmUgewogICAgICAgICAgICB0ZXh0LWFsaWduOiBjZW50ZXI7
IHBhZGRpbmc6IDEwcHggOHB4IDE0cHg7IGZvbnQtc2l6ZTogMTFweDsKICAgICAgICAgICAgY29sb3I6
IHZhcigtLXR4dDMpOyAtd2Via2l0LWFwcC1yZWdpb246IG5vLWRyYWc7IGFwcC1yZWdpb246IG5vLWRy
YWc7CiAgICAgICAgfQogICAgICAgIC5saXN0LW1vcmUuZG9uZSB7IGRpc3BsYXk6IG5vbmU7IH0KCiAg
ICAgICAgLml0bSB7CiAgICAgICAgICAgIGRpc3BsYXk6IGZsZXg7IGFsaWduLWl0ZW1zOiBmbGV4LXN0
YXJ0OyBnYXA6IDhweDsKICAgICAgICAgICAgcGFkZGluZzogOHB4OyBtYXJnaW4tYm90dG9tOiA1cHg7
CiAgICAgICAgICAgIGJhY2tncm91bmQ6IHZhcigtLWNhcmQpOyBib3JkZXItcmFkaXVzOiB2YXIoLS1y
KTsgY3Vyc29yOiBwb2ludGVyOwogICAgICAgICAgICBib3gtc2hhZG93OiAwIDFweCAzcHggcmdiYSgy
NCwzMiw1NiwuMDYpOwogICAgICAgICAgICAvKiBob3Zlci1saW5lICovCiAgICAgICAgICAgIHBvc2l0
aW9uOiByZWxhdGl2ZTsKICAgICAgICAgICAgdHJhbnNpdGlvbjogYmFja2dyb3VuZCAuMnMgZWFzZSwg
Ym94LXNoYWRvdyAuMnMgZWFzZTsKICAgICAgICAgICAgLXdlYmtpdC1hcHAtcmVnaW9uOiBuby1kcmFn
OyBhcHAtcmVnaW9uOiBuby1kcmFnOwogICAgICAgICAgICBvdmVyZmxvdzogdmlzaWJsZTsKICAgICAg
ICB9CiAgICAgICAgLml0bTo6YmVmb3JlIHsKICAgICAgICAgICAgY29udGVudDogIiI7CiAgICAgICAg
ICAgIHBvc2l0aW9uOiBhYnNvbHV0ZTsKICAgICAgICAgICAgbGVmdDogMDsgcmlnaHQ6IDA7IGJvdHRv
bTogMDsKICAgICAgICAgICAgaGVpZ2h0OiAwOwogICAgICAgICAgICBwb2ludGVyLWV2ZW50czogbm9u
ZTsKICAgICAgICAgICAgei1pbmRleDogMDsKICAgICAgICAgICAgYm9yZGVyLXJhZGl1czogMCAwIHZh
cigtLXIpIHZhcigtLXIpOwogICAgICAgICAgICBiYWNrZ3JvdW5kOiBsaW5lYXItZ3JhZGllbnQodG8g
dG9wLCByZ2JhKDkxLDExNSwyMzIsLjMyKSwgcmdiYSg5MSwxMTUsMjMyLC4xMikgNTUlLCB0cmFuc3Bh
cmVudCk7CiAgICAgICAgICAgIHRyYW5zaXRpb246IGhlaWdodCAuMzRzIGN1YmljLWJlemllciguMjIs
MSwuMzYsMSk7CiAgICAgICAgfQogICAgICAgIC5pdG06aG92ZXI6OmJlZm9yZSB7IGhlaWdodDogMzMu
MzMzJTsgfQogICAgICAgIC5pdG06OmFmdGVyIHsKICAgICAgICAgICAgY29udGVudDogIiI7CiAgICAg
ICAgICAgIHBvc2l0aW9uOiBhYnNvbHV0ZTsKICAgICAgICAgICAgbGVmdDogMDsgcmlnaHQ6IDA7IGJv
dHRvbTogMDsKICAgICAgICAgICAgaGVpZ2h0OiAycHg7CiAgICAgICAgICAgIHBvaW50ZXItZXZlbnRz
OiBub25lOwogICAgICAgICAgICB6LWluZGV4OiAxOwogICAgICAgICAgICBiYWNrZ3JvdW5kOiByZ2Jh
KDkxLDExNSwyMzIsLjk1KTsKICAgICAgICAgICAgYm9yZGVyLXJhZGl1czogMXB4OwogICAgICAgICAg
ICB0cmFuc2Zvcm06IHNjYWxlWCgwKTsKICAgICAgICAgICAgdHJhbnNmb3JtLW9yaWdpbjogY2VudGVy
OwogICAgICAgICAgICB0cmFuc2l0aW9uOiB0cmFuc2Zvcm0gLjNzIGN1YmljLWJlemllciguMjIsMSwu
MzYsMSk7CiAgICAgICAgfQogICAgICAgIC5pdG06aG92ZXIgewogICAgICAgICAgICBiYWNrZ3JvdW5k
OiB2YXIoLS1jYXJkLWgpOwogICAgICAgICAgICBib3gtc2hhZG93OiAwIDJweCA4cHggcmdiYSgyNCwz
Miw1NiwuMSk7CiAgICAgICAgfQogICAgICAgIC5pdG06aG92ZXI6OmFmdGVyIHsKICAgICAgICAgICAg
dHJhbnNmb3JtOiBzY2FsZVgoMSk7CiAgICAgICAgfQogICAgICAgIC5pdG0uc2VsIHsKICAgICAgICAg
ICAgYm94LXNoYWRvdzogMCAwIDAgMnB4IHJnYmEoOTEsMTE1LDIzMiwuNDUpLCAwIDJweCA4cHggcmdi
YSg5MSwxMTUsMjMyLC4xOCk7CiAgICAgICAgICAgIGJhY2tncm91bmQ6ICNlZGYxZmY7CiAgICAgICAg
fQogICAgICAgIC5pdG0ubXVsdGkgewogICAgICAgICAgICBib3gtc2hhZG93OiAwIDAgMCAxLjVweCBy
Z2JhKDkxLDExNSwyMzIsLjU1KSwgMCAycHggNnB4IHJnYmEoOTEsMTE1LDIzMiwuMTgpOwogICAgICAg
ICAgICBiYWNrZ3JvdW5kOiAjZWVmMmZmOwogICAgICAgIH0KICAgICAgICAuaXRtLm11bHRpLnNlbCB7
CiAgICAgICAgICAgIGJveC1zaGFkb3c6IDAgMCAwIDJweCByZ2JhKDkxLDExNSwyMzIsLjcpLCAwIDJw
eCA4cHggcmdiYSg5MSwxMTUsMjMyLC4yMik7CiAgICAgICAgfQoKICAgICAgICAjbXVsdGktY250IHsK
ICAgICAgICAgICAgZGlzcGxheTogbm9uZTsgYWxpZ24taXRlbXM6IGNlbnRlcjsganVzdGlmeS1jb250
ZW50OiBjZW50ZXI7CiAgICAgICAgICAgIGhlaWdodDogMjJweDsgcGFkZGluZzogMCA4cHg7IG1hcmdp
bi1yaWdodDogNHB4OwogICAgICAgICAgICBib3JkZXI6IG5vbmU7IGJvcmRlci1yYWRpdXM6IDExcHg7
IGN1cnNvcjogcG9pbnRlcjsKICAgICAgICAgICAgYmFja2dyb3VuZDogdmFyKC0tYWNjKTsgY29sb3I6
ICNmZmY7IGZvbnQtc2l6ZTogMTFweDsgZm9udC13ZWlnaHQ6IDcwMDsKICAgICAgICAgICAgLXdlYmtp
dC1hcHAtcmVnaW9uOiBuby1kcmFnOyBhcHAtcmVnaW9uOiBuby1kcmFnOwogICAgICAgICAgICB0cmFu
c2l0aW9uOiBvcGFjaXR5IHZhcigtLXRyKSwgYmFja2dyb3VuZCB2YXIoLS10cik7CiAgICAgICAgfQog
ICAgICAgICNtdWx0aS1jbnQ6aG92ZXIgeyBiYWNrZ3JvdW5kOiAjNGE2MmQ0OyB9CiAgICAgICAgI211
bHRpLWNudC5vbiB7IGRpc3BsYXk6IGlubGluZS1mbGV4OyB9CgogICAgICAgIC5pLWljbyB7CiAgICAg
ICAgICAgIHdpZHRoOiAyOHB4OyBoZWlnaHQ6IDI4cHg7IGJvcmRlci1yYWRpdXM6IHZhcigtLXIpOyBk
aXNwbGF5OiBmbGV4OwogICAgICAgICAgICBhbGlnbi1pdGVtczogY2VudGVyOyBqdXN0aWZ5LWNvbnRl
bnQ6IGNlbnRlcjsgZmxleC1zaHJpbms6IDA7CiAgICAgICAgICAgIGJhY2tncm91bmQ6ICNlZGYyZmY7
IGNvbG9yOiB2YXIoLS1hY2MpOwogICAgICAgICAgICBwb3NpdGlvbjogcmVsYXRpdmU7IG92ZXJmbG93
OiB2aXNpYmxlOwogICAgICAgIH0KICAgICAgICAuaS1pY28gc3ZnIHsgd2lkdGg6IDE2cHg7IGhlaWdo
dDogMTZweDsgZGlzcGxheTogYmxvY2s7IH0KICAgICAgICAuaS1pY28uZnQtaW1nIHsgY29sb3I6ICM3
YWQ3ZmY7IH0KICAgICAgICAuaS1pY28uZnQtdmlkIHsgY29sb3I6ICNjMDg0ZmM7IH0KICAgICAgICAu
aS1pY28uZnQtemlwIHsgY29sb3I6ICM4YWI0ZmY7IH0KICAgICAgICAuaS1pY28uZnQtZGlyIHsgY29s
b3I6ICNmZmQ1NmE7IH0KICAgICAgICAuaS1pY28uZnQtYWhrIHsgY29sb3I6ICM2ZGZmOWE7IH0KICAg
ICAgICAuaS1pY28ubWQgeyBjb2xvcjogIzZiOGNmZjsgfQogICAgICAgIC5pLWljby5tZCBzdmcgeyB3
aWR0aDogMjBweDsgaGVpZ2h0OiAyMHB4OyB9CiAgICAgICAgLmktaWNvLmZ0LWxuaywgLmktaWNvLmZ0
LWRvYyB7IGNvbG9yOiAjYTliZGQwOyB9CiAgICAgICAgLmktdXNlZCB7CiAgICAgICAgICAgIHBvc2l0
aW9uOiBhYnNvbHV0ZTsgcmlnaHQ6IDA7IGJvdHRvbTogMDsKICAgICAgICAgICAgd2lkdGg6IDEzcHg7
IGhlaWdodDogMTNweDsgYm9yZGVyLXJhZGl1czogNTAlOwogICAgICAgICAgICBiYWNrZ3JvdW5kOiAj
MjJjNTVlOyBib3JkZXI6IDEuNXB4IHNvbGlkICNmZmY7CiAgICAgICAgICAgIGRpc3BsYXk6IGZsZXg7
IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGp1c3RpZnktY29udGVudDogY2VudGVyOwogICAgICAgICAgICBw
b2ludGVyLWV2ZW50czogbm9uZTsgei1pbmRleDogMzsKICAgICAgICAgICAgYm94LXNoYWRvdzogMCAx
cHggMnB4IHJnYmEoMCwwLDAsLjE2KTsKICAgICAgICAgICAgdHJhbnNmb3JtOiB0cmFuc2xhdGUoMzAl
LCAzMCUpOwogICAgICAgIH0KICAgICAgICAuaS11c2VkIHN2ZyB7IHdpZHRoOiA5cHg7IGhlaWdodDog
OXB4OyBjb2xvcjogI2ZmZjsgZGlzcGxheTogYmxvY2s7IH0KCiAgICAgICAgLyogUGFzdGUtcXVldWUg
dmlzdWFsIGNoYWluOiBncmF5ID0gaW4gcXVldWU7IGdyZWVuID0gZGVxdWV1ZWQgKHBhc3RlZCkgY2hh
aW4gKi8KICAgICAgICAuaXRtLnEtbWVtYmVyIHsKICAgICAgICAgICAgcGFkZGluZy1sZWZ0OiAxNHB4
OwogICAgICAgICAgICAvKiBNVVNUIG92ZXJyaWRlIGdsb2JhbCAuaXRte292ZXJmbG93OmhpZGRlbn0g
4oCUIG90aGVyd2lzZSBib3R0b206LU4gcmFpbAogICAgICAgICAgICAgICBpcyBjbGlwcGVkIGFuZCB0
aGUgY2hhaW4gbG9va3Mg4oCc5pat57q/4oCdIGFjcm9zcyB0aGUgNXB4IGNhcmQgZ2FwICovCiAgICAg
ICAgICAgIG92ZXJmbG93OiB2aXNpYmxlICFpbXBvcnRhbnQ7CiAgICAgICAgfQogICAgICAgIC5pdG0u
cS1tZW1iZXIgLnEtcmFpbCB7CiAgICAgICAgICAgIHBvc2l0aW9uOiBhYnNvbHV0ZTsKICAgICAgICAg
ICAgbGVmdDogNXB4OwogICAgICAgICAgICB0b3A6IDA7CiAgICAgICAgICAgIC8qIEJyaWRnZSAuaXRt
IG1hcmdpbi1ib3R0b206NXB4IHNvIGNvbnNlY3V0aXZlIHJhaWxzIHJlYWQgYXMgb25lIHN0cm9rZSAq
LwogICAgICAgICAgICBib3R0b206IC01cHg7CiAgICAgICAgICAgIHdpZHRoOiAycHg7CiAgICAgICAg
ICAgIGJhY2tncm91bmQ6ICM5Y2EzYWY7CiAgICAgICAgICAgIG9wYWNpdHk6IC43MjsKICAgICAgICAg
ICAgcG9pbnRlci1ldmVudHM6IG5vbmU7CiAgICAgICAgICAgIHotaW5kZXg6IDQ7CiAgICAgICAgfQog
ICAgICAgIC5pdG0ucS1tZW1iZXIucS1maXJzdCAucS1yYWlsIHsgdG9wOiAxNnB4OyBib3JkZXItcmFk
aXVzOiAycHggMnB4IDAgMDsgfQogICAgICAgIC8qIEVuZCBjaGFpbiBhdCB0aGUgbGFzdCBkb3Qg4oCU
IGRvIG5vdCBoYW5nIGludG8gdGhlIGdhcCBiZWxvdyAqLwogICAgICAgIC5pdG0ucS1tZW1iZXIucS1s
YXN0IC5xLXJhaWwgewogICAgICAgICAgICBib3R0b206IGF1dG87CiAgICAgICAgICAgIGhlaWdodDog
MjJweDsKICAgICAgICAgICAgYm9yZGVyLXJhZGl1czogMCAwIDJweCAycHg7CiAgICAgICAgfQogICAg
ICAgIC5pdG0ucS1tZW1iZXIucS1maXJzdC5xLWxhc3QgLnEtcmFpbCwKICAgICAgICAuaXRtLnEtbWVt
YmVyLnEtb25seSAucS1yYWlsIHsgZGlzcGxheTogbm9uZTsgfQogICAgICAgIC5pdG0ucS1tZW1iZXIg
LnEtZG90IHsKICAgICAgICAgICAgcG9zaXRpb246IGFic29sdXRlOwogICAgICAgICAgICBsZWZ0OiAy
cHg7CiAgICAgICAgICAgIHRvcDogMTRweDsKICAgICAgICAgICAgd2lkdGg6IDhweDsKICAgICAgICAg
ICAgaGVpZ2h0OiA4cHg7CiAgICAgICAgICAgIGJvcmRlci1yYWRpdXM6IDUwJTsKICAgICAgICAgICAg
YmFja2dyb3VuZDogIzljYTNhZjsKICAgICAgICAgICAgYm9yZGVyOiAxLjVweCBzb2xpZCAjZmZmOwog
ICAgICAgICAgICBib3gtc2hhZG93OiAwIDAgMCAxcHggcmdiYSgxNTYsMTYzLDE3NSwuNDUpOwogICAg
ICAgICAgICBwb2ludGVyLWV2ZW50czogbm9uZTsKICAgICAgICAgICAgei1pbmRleDogNTsKICAgICAg
ICB9CiAgICAgICAgLyogRGVxdWV1ZWQ6IGdyZWVuIGRvdHM7IGdyZWVuIHJhaWwgZm9yIGNvbnNlY3V0
aXZlIGRvbmUgcnVuICovCiAgICAgICAgLml0bS5xLW1lbWJlci5xLWRvbmUgLnEtZG90IHsKICAgICAg
ICAgICAgYmFja2dyb3VuZDogIzIyYzU1ZTsKICAgICAgICAgICAgYm94LXNoYWRvdzogMCAwIDAgMXB4
IHJnYmEoMzQsMTk3LDk0LC40KTsKICAgICAgICB9CiAgICAgICAgLml0bS5xLW1lbWJlci5xLWRvbmUt
bGluayAucS1yYWlsIHsKICAgICAgICAgICAgYmFja2dyb3VuZDogIzIyYzU1ZTsKICAgICAgICAgICAg
b3BhY2l0eTogLjkyOwogICAgICAgIH0KCiAgICAgICAgLml0bS5qdW1wLWZsYXNoIHsKICAgICAgICAg
ICAgYm94LXNoYWRvdzogMCAwIDAgMnB4IHJnYmEoOTEsMTE1LDIzMiwuNTUpLCAwIDJweCAxMHB4IHJn
YmEoOTEsMTE1LDIzMiwuMjIpOwogICAgICAgICAgICBiYWNrZ3JvdW5kOiAjZThlZGZmOwogICAgICAg
ICAgICB0cmFuc2l0aW9uOiBiYWNrZ3JvdW5kIC4zNXMgZWFzZSwgYm94LXNoYWRvdyAuMzVzIGVhc2U7
CiAgICAgICAgfQoKICAgICAgICAuaS1ib2R5IHsgZmxleDogMTsgbWluLXdpZHRoOiAwOyBkaXNwbGF5
OiBmbGV4OyBmbGV4LWRpcmVjdGlvbjogY29sdW1uOyB9CiAgICAgICAgLmktcHJldiwgLmktbmFtZSB7
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
ICAgICAgICAuaS10aHVtYi13cmFwIHsKICAgICAgICAgICAgd2lkdGg6IDEwMCU7IG1pbi1oZWlnaHQ6
IDQ4cHg7IG1heC1oZWlnaHQ6IDE4MHB4OyBtYXJnaW4tYm90dG9tOiA0cHg7CiAgICAgICAgICAgIGRp
c3BsYXk6IGZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGp1c3RpZnktY29udGVudDogY2VudGVyOwog
ICAgICAgICAgICBiYWNrZ3JvdW5kOiAjZjNmNWY5OyBib3JkZXItcmFkaXVzOiB2YXIoLS1yKTsgb3Zl
cmZsb3c6IGhpZGRlbjsKICAgICAgICB9CiAgICAgICAgLmktdGh1bWItd3JhcC53YWl0aW5nIHsKICAg
ICAgICAgICAgbWluLWhlaWdodDogODhweDsKICAgICAgICAgICAgYmFja2dyb3VuZDogbGluZWFyLWdy
YWRpZW50KDkwZGVnLCAjZThlYmYyIDAlLCAjZjRmNmZhIDQ1JSwgI2U4ZWJmMiAxMDAlKTsKICAgICAg
ICAgICAgYmFja2dyb3VuZC1zaXplOiAyMDAlIDEwMCU7CiAgICAgICAgICAgIGFuaW1hdGlvbjogdGh1
bWJTaGltbWVyIDEuMDVzIGVhc2UtaW4tb3V0IGluZmluaXRlOwogICAgICAgIH0KICAgICAgICBAa2V5
ZnJhbWVzIHRodW1iU2hpbW1lciB7CiAgICAgICAgICAgIDAlIHsgYmFja2dyb3VuZC1wb3NpdGlvbjog
MTAwJSAwOyB9CiAgICAgICAgICAgIDEwMCUgeyBiYWNrZ3JvdW5kLXBvc2l0aW9uOiAtMTAwJSAwOyB9
CiAgICAgICAgfQogICAgICAgIC5pLXRodW1iIHsgbWF4LXdpZHRoOiAxMDAlOyBtYXgtaGVpZ2h0OiAx
ODBweDsgd2lkdGg6IGF1dG87IGhlaWdodDogYXV0bzsgb2JqZWN0LWZpdDogY29udGFpbjsgZGlzcGxh
eTogYmxvY2s7IH0KICAgICAgICAuaS10aHVtYi50aHVtYi1sb2FkaW5nIHsgb3BhY2l0eTogMDsgd2lk
dGg6IDFweDsgaGVpZ2h0OiAxcHg7IH0KCiAgICAgICAgLyogTWV0YSBiYXI6IHRpbWUgbGVmdCB8IGV4
cGFuZCBjZW50ZXIgfCB0YWdzIHJpZ2h0ICovCiAgICAgICAgLmktbWV0YSB7CiAgICAgICAgICAgIGRp
c3BsYXk6IGdyaWQ7CiAgICAgICAgICAgIGdyaWQtdGVtcGxhdGUtY29sdW1uczogMWZyIGF1dG8gMWZy
OwogICAgICAgICAgICBhbGlnbi1pdGVtczogY2VudGVyOwogICAgICAgICAgICBnYXA6IDRweDsKICAg
ICAgICAgICAgbWFyZ2luLXRvcDogNHB4OwogICAgICAgICAgICB3aWR0aDogMTAwJTsKICAgICAgICB9
CiAgICAgICAgLmktbWV0YSAuaS10aW1lIHsganVzdGlmeS1zZWxmOiBzdGFydDsgfQogICAgICAgIC5p
LW1ldGEtY2VudGVyIHsKICAgICAgICAgICAganVzdGlmeS1zZWxmOiBjZW50ZXI7CiAgICAgICAgICAg
IGRpc3BsYXk6IGZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGp1c3RpZnktY29udGVudDogY2VudGVy
OwogICAgICAgICAgICBnYXA6IDRweDsKICAgICAgICAgICAgbWluLXdpZHRoOiAxcHg7IC8qIGtlZXAg
Y2VudGVyIGNvbHVtbiBldmVuIHdoZW4gZXhwYW5kIGlzIGhpZGRlbiAqLwogICAgICAgIH0KICAgICAg
ICAuaS1tZXRhLXJpZ2h0IHsKICAgICAgICAgICAganVzdGlmeS1zZWxmOiBlbmQ7CiAgICAgICAgICAg
IGRpc3BsYXk6IGZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGdhcDogNXB4OyBmbGV4LXdyYXA6IG5v
d3JhcDsKICAgICAgICAgICAganVzdGlmeS1jb250ZW50OiBmbGV4LWVuZDsKICAgICAgICAgICAgbWlu
LXdpZHRoOiAwOwogICAgICAgIH0KICAgICAgICAuaS1tZXRhLXJpZ2h0LnRleHQtbWV0YSB7CiAgICAg
ICAgICAgIGZsZXgtd3JhcDogbm93cmFwOwogICAgICAgICAgICBnYXA6IDRweDsKICAgICAgICB9CiAg
ICAgICAgLmktc3JjLXRpdGxlIHsKICAgICAgICAgICAgZm9udC1zaXplOiAxMHB4OwogICAgICAgICAg
ICBjb2xvcjogdmFyKC0tdHh0Myk7CiAgICAgICAgICAgIG1heC13aWR0aDogMTFlbTsKICAgICAgICAg
ICAgb3ZlcmZsb3c6IGhpZGRlbjsKICAgICAgICAgICAgdGV4dC1vdmVyZmxvdzogZWxsaXBzaXM7CiAg
ICAgICAgICAgIHdoaXRlLXNwYWNlOiBub3dyYXA7CiAgICAgICAgICAgIG1pbi13aWR0aDogMDsKICAg
ICAgICAgICAgbGluZS1oZWlnaHQ6IDEuNDsKICAgICAgICB9CiAgICAgICAgLmktdGltZSwgLmktdGFn
IHsgZm9udC1zaXplOiAxMHB4OyBjb2xvcjogdmFyKC0tdHh0Myk7IH0KICAgICAgICAuaS10YWcgewog
ICAgICAgICAgICBiYWNrZ3JvdW5kOiAjZjFmM2Y4OyBwYWRkaW5nOiAwIDVweDsgYm9yZGVyLXJhZGl1
czogM3B4OwogICAgICAgICAgICB3aGl0ZS1zcGFjZTogbm93cmFwOyBmbGV4LXNocmluazogMDsgbGlu
ZS1oZWlnaHQ6IDEuNDsKICAgICAgICB9CiAgICAgICAgLmktY2hhcnMgewogICAgICAgICAgICBmb250
LXNpemU6IDEwcHg7IGNvbG9yOiB2YXIoLS10eHQzKTsKICAgICAgICAgICAgYmFja2dyb3VuZDogI2Yx
ZjNmODsgcGFkZGluZzogMCA1cHg7IGJvcmRlci1yYWRpdXM6IDNweDsKICAgICAgICAgICAgZm9udC12
YXJpYW50LW51bWVyaWM6IHRhYnVsYXItbnVtczsKICAgICAgICAgICAgd2hpdGUtc3BhY2U6IG5vd3Jh
cDsKICAgICAgICAgICAgZGlzcGxheTogaW5saW5lLWZsZXg7IGFsaWduLWl0ZW1zOiBiYXNlbGluZTsg
Z2FwOiAycHg7CiAgICAgICAgfQogICAgICAgIC5pLWNoYXJzIC5uIHsKICAgICAgICAgICAgZGlzcGxh
eTogaW5saW5lLWJsb2NrOwogICAgICAgICAgICBtaW4td2lkdGg6IDRjaDsKICAgICAgICAgICAgdGV4
dC1hbGlnbjogcmlnaHQ7CiAgICAgICAgICAgIGZvbnQtZmFtaWx5OiAnQ2FzY2FkaWEgTW9ubycsICdD
b25zb2xhcycsICdTYXJhc2EgTW9ubyBTQycsIHVpLW1vbm9zcGFjZSwgbW9ub3NwYWNlOwogICAgICAg
ICAgICBmb250LXdlaWdodDogNjAwOwogICAgICAgICAgICBjb2xvcjogdmFyKC0tdHh0Mik7CiAgICAg
ICAgfQogICAgICAgIC8qIHNyYy10aXRsZS10aXAgKi8KICAgICAgICAuaS1zcmMtaWNvLCAubWctc3Jj
IHsgY3Vyc29yOiBwb2ludGVyOyB9CiAgICAgICAgI3NyYy10aXAgewogICAgICAgICAgICBwb3NpdGlv
bjogZml4ZWQ7IHotaW5kZXg6IDk5OTk5OwogICAgICAgICAgICBtYXgtd2lkdGg6IG1pbigyODBweCwg
Y2FsYygxMDB2dyAtIDE2cHgpKTsKICAgICAgICAgICAgcGFkZGluZzogNnB4IDEwcHg7CiAgICAgICAg
ICAgIGJvcmRlci1yYWRpdXM6IDhweDsKICAgICAgICAgICAgYmFja2dyb3VuZDogcmdiYSgzMiwzNiw0
OCwuOTIpOyBjb2xvcjogI2ZmZjsKICAgICAgICAgICAgZm9udC1zaXplOiAxMnB4OyBsaW5lLWhlaWdo
dDogMS4zNTsKICAgICAgICAgICAgYm94LXNoYWRvdzogMCA2cHggMThweCByZ2JhKDAsMCwwLC4yMik7
CiAgICAgICAgICAgIHBvaW50ZXItZXZlbnRzOiBub25lOwogICAgICAgICAgICBvcGFjaXR5OiAwOyB0
cmFuc2Zvcm06IHRyYW5zbGF0ZVkoNHB4KTsKICAgICAgICAgICAgdHJhbnNpdGlvbjogb3BhY2l0eSAu
MnMgZWFzZSwgdHJhbnNmb3JtIC4yMnMgY3ViaWMtYmV6aWVyKC4yMiwxLC4zNiwxKTsKICAgICAgICAg
ICAgd29yZC1icmVhazogYnJlYWstd29yZDsKICAgICAgICB9CiAgICAgICAgI3NyYy10aXAuc2hvdyB7
IG9wYWNpdHk6IDE7IHRyYW5zZm9ybTogdHJhbnNsYXRlWSgwKTsgfQogICAgICAgIC5pLXNyYy1pY28g
ewogICAgICAgICAgICB3aWR0aDogMTRweDsgaGVpZ2h0OiAxNHB4OyBmbGV4LXNocmluazogMDsKICAg
ICAgICAgICAgYm9yZGVyLXJhZGl1czogMnB4OyBvYmplY3QtZml0OiBjb250YWluOwogICAgICAgICAg
ICBkaXNwbGF5OiBibG9jazsKICAgICAgICB9CiAgICAgICAgLmktbnVtIHsKICAgICAgICAgICAgZGlz
cGxheTogZmxleDsgZmxleC1kaXJlY3Rpb246IGNvbHVtbjsgYWxpZ24taXRlbXM6IGZsZXgtZW5kOwog
ICAgICAgICAgICBqdXN0aWZ5LWNvbnRlbnQ6IHNwYWNlLWJldHdlZW47CiAgICAgICAgICAgIGFsaWdu
LXNlbGY6IHN0cmV0Y2g7CiAgICAgICAgICAgIGZvbnQtc2l6ZTogMTBweDsgY29sb3I6IHZhcigtLXR4
dDMpOyBtaW4td2lkdGg6IDE2cHg7CiAgICAgICAgICAgIHRleHQtYWxpZ246IHJpZ2h0OyBmbGV4LXNo
cmluazogMDsKICAgICAgICAgICAgcGFkZGluZy10b3A6IDJweDsKICAgICAgICB9CiAgICAgICAgLmkt
bnVtIC5pLXNyYy1pY28geyB3aWR0aDogMTZweDsgaGVpZ2h0OiAxNnB4OyBtYXJnaW4tdG9wOiBhdXRv
OyB9CgogICAgICAgIC5pLWV4cGFuZC1idG4gewogICAgICAgICAgICBib3JkZXI6IG5vbmU7IGJhY2tn
cm91bmQ6IG5vbmU7IGN1cnNvcjogcG9pbnRlcjsKICAgICAgICAgICAgY29sb3I6IHZhcigtLXR4dDMp
OyBmb250LXNpemU6IDEycHg7IHBhZGRpbmc6IDNweCAxMHB4OwogICAgICAgICAgICBib3JkZXItcmFk
aXVzOiA4cHg7IGRpc3BsYXk6IG5vbmU7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGdhcDogNHB4OwogICAg
ICAgICAgICB0cmFuc2l0aW9uOiBjb2xvciB2YXIoLS10ciksIGJhY2tncm91bmQgdmFyKC0tdHIpOwog
ICAgICAgICAgICAtd2Via2l0LWFwcC1yZWdpb246IG5vLWRyYWc7IGFwcC1yZWdpb246IG5vLWRyYWc7
CiAgICAgICAgICAgIGxpbmUtaGVpZ2h0OiAxLjI7CiAgICAgICAgfQogICAgICAgIC5pLWV4cGFuZC1i
dG4gc3ZnIHsgd2lkdGg6IDE0cHg7IGhlaWdodDogMTRweDsgZmxleC1zaHJpbms6IDA7IH0KICAgICAg
ICAuaS1leHBhbmQtYnRuLm9uIHsgZGlzcGxheTogaW5saW5lLWZsZXg7IH0KICAgICAgICAuaS1leHBh
bmQtYnRuOmhvdmVyIHsgY29sb3I6IHZhcigtLWFjYyk7IGJhY2tncm91bmQ6IHJnYmEoOTEsMTE1LDIz
MiwuMDgpOyB9CiAgICAgICAgLmktcHJldi5leHBhbmRlZCwgLmktbmFtZS5leHBhbmRlZCB7CiAgICAg
ICAgICAgIC13ZWJraXQtbGluZS1jbGFtcDogdW5zZXQ7CiAgICAgICAgICAgIGRpc3BsYXk6IGJsb2Nr
OwogICAgICAgICAgICBvdmVyZmxvdzogaGlkZGVuOwogICAgICAgICAgICAvKiDpq5jluqbnlLEgSlMg
5oyJ5YiX6KGo5Y+v6KeG5Yy66K6+5a6a77ya57qm5Y2g5pW06KGo5bCR5LiA6KGMICovCiAgICAgICAg
fQogICAgICAgIC5pLXNyYy10aXRsZSB7IGRpc3BsYXk6IG5vbmUgIWltcG9ydGFudDsgfQogICAgICAg
IC5pLWZpbGUtZGV0YWlsIHsKICAgICAgICAgICAgZGlzcGxheTogbm9uZTsKICAgICAgICAgICAgbWFy
Z2luLXRvcDogNHB4OwogICAgICAgICAgICBwYWRkaW5nOiAwOwogICAgICAgICAgICBiYWNrZ3JvdW5k
OiBub25lOwogICAgICAgICAgICBib3JkZXI6IG5vbmU7CiAgICAgICAgfQogICAgICAgIC5pLWZpbGUt
ZGV0YWlsLm9uIHsgZGlzcGxheTogYmxvY2s7IH0KICAgICAgICAuZmQtYmxvY2sgewogICAgICAgICAg
ICBkaXNwbGF5OiBmbGV4OyBmbGV4LWRpcmVjdGlvbjogY29sdW1uOyBnYXA6IDZweDsKICAgICAgICB9
CiAgICAgICAgLmZkLWJsb2NrICsgLmZkLWJsb2NrIHsgbWFyZ2luLXRvcDogOHB4OyB9CiAgICAgICAg
LmZkLXBhdGggewogICAgICAgICAgICB3aWR0aDogMTAwJTsKICAgICAgICAgICAgZm9udDogNjAwIDEy
cHgvMS41NSAnU2Vnb2UgVUkgVmFyaWFibGUgVGV4dCcsJ1NlZ29lIFVJJywnTWljcm9zb2Z0IFlhSGVp
IFVJJyxzYW5zLXNlcmlmOwogICAgICAgICAgICBjb2xvcjogdmFyKC0tdHh0Mik7CiAgICAgICAgICAg
IGxldHRlci1zcGFjaW5nOiAuMDFlbTsKICAgICAgICAgICAgd29yZC1icmVhazogYnJlYWstYWxsOwog
ICAgICAgICAgICB1c2VyLXNlbGVjdDogdGV4dDsKICAgICAgICAgICAgLXdlYmtpdC1hcHAtcmVnaW9u
OiBuby1kcmFnOyBhcHAtcmVnaW9uOiBuby1kcmFnOwogICAgICAgIH0KICAgICAgICAuZmQtcGF0aC5s
aXZlIHsgY3Vyc29yOiBwb2ludGVyOyB9CiAgICAgICAgLmZkLXBhdGgubGl2ZTpob3ZlciB7IGNvbG9y
OiB2YXIoLS1hY2MpOyB9CiAgICAgICAgLmZkLXBhdGguZGVhZCB7CiAgICAgICAgICAgIGNvbG9yOiAj
OWFhMGIwOwogICAgICAgICAgICB0ZXh0LWRlY29yYXRpb246IGxpbmUtdGhyb3VnaDsKICAgICAgICAg
ICAgdGV4dC1kZWNvcmF0aW9uLXRoaWNrbmVzczogMnB4OwogICAgICAgICAgICB0ZXh0LWRlY29yYXRp
b24tY29sb3I6IHJnYmEoMTU0LCAxNjAsIDE3NiwgLjU1KTsKICAgICAgICAgICAgdGV4dC1kZWNvcmF0
aW9uLXNraXAtaW5rOiBub25lOwogICAgICAgICAgICBjdXJzb3I6IGRlZmF1bHQ7CiAgICAgICAgfQog
ICAgICAgIC5mZC1hY3Rpb25zIHsKICAgICAgICAgICAgZGlzcGxheTogZmxleDsgYWxpZ24taXRlbXM6
IGNlbnRlcjsganVzdGlmeS1jb250ZW50OiBmbGV4LWVuZDsKICAgICAgICAgICAgZ2FwOiA4cHg7IGZs
ZXgtd3JhcDogd3JhcDsKICAgICAgICB9CiAgICAgICAgLmZkLWJ0biB7CiAgICAgICAgICAgIGJvcmRl
cjogbm9uZTsgYmFja2dyb3VuZDogbm9uZTsgY3Vyc29yOiBwb2ludGVyOwogICAgICAgICAgICBjb2xv
cjogdmFyKC0tdHh0Myk7IGZvbnQtc2l6ZTogMTBweDsgZm9udC13ZWlnaHQ6IDYwMDsKICAgICAgICAg
ICAgcGFkZGluZzogMXB4IDJweDsgZGlzcGxheTogaW5saW5lLWZsZXg7IGFsaWduLWl0ZW1zOiBjZW50
ZXI7IGdhcDogMnB4OwogICAgICAgICAgICB3aGl0ZS1zcGFjZTogbm93cmFwOwogICAgICAgICAgICAt
d2Via2l0LWFwcC1yZWdpb246IG5vLWRyYWc7IGFwcC1yZWdpb246IG5vLWRyYWc7CiAgICAgICAgICAg
IHRyYW5zaXRpb246IGNvbG9yIHZhcigtLXRyKTsKICAgICAgICB9CiAgICAgICAgLmZkLWJ0bjpob3Zl
ciB7IGNvbG9yOiB2YXIoLS1hY2MpOyB9CiAgICAgICAgLmZkLWJ0bi5vayB7IGNvbG9yOiAjMWY3YTU1
OyB9CgogICAgICAgIC8qIOKUgOKUgCBDb250ZXh0IG1lbnUg4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA
4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA
4pSA4pSA4pSA4pSAICovCiAgICAgICAgI2N0eCB7CiAgICAgICAgICAgIHBvc2l0aW9uOiBmaXhlZDsg
ei1pbmRleDogOTk5OTsgbWluLXdpZHRoOiAxMzJweDsgZGlzcGxheTogbm9uZTsgcGFkZGluZzogNHB4
OwogICAgICAgICAgICBiYWNrZ3JvdW5kOiAjZmZmOyBib3JkZXItcmFkaXVzOiB2YXIoLS1yKTsgYm94
LXNoYWRvdzogMCA2cHggMTZweCByZ2JhKDAsMCwwLC4xNCk7CiAgICAgICAgICAgIC13ZWJraXQtYXBw
LXJlZ2lvbjogbm8tZHJhZzsgYXBwLXJlZ2lvbjogbm8tZHJhZzsKICAgICAgICB9CiAgICAgICAgI2N0
eC5vbiB7IGRpc3BsYXk6IGJsb2NrOyB9CiAgICAgICAgLmMtaXRlbSB7CiAgICAgICAgICAgIGRpc3Bs
YXk6IGZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGdhcDogN3B4OyBwYWRkaW5nOiA2cHggOXB4Owog
ICAgICAgICAgICBib3JkZXItcmFkaXVzOiB2YXIoLS1yKTsgY3Vyc29yOiBwb2ludGVyOyBmb250LXNp
emU6IDExcHg7IGNvbG9yOiB2YXIoLS10eHQpOwogICAgICAgIH0KICAgICAgICAuYy1pdGVtOmhvdmVy
IHsgYmFja2dyb3VuZDogI2YyZjRmOTsgfQogICAgICAgIC5jLWl0ZW0uZGFuZ2VyIHsgY29sb3I6ICNm
ZjdiOWM7IH0KICAgICAgICAuYy1zZXAgeyBoZWlnaHQ6IDFweDsgYmFja2dyb3VuZDogI2VjZWZmNTsg
bWFyZ2luOiAzcHggMDsgfQogICAgICAgIC5jLWljbyB7IHdpZHRoOiAxNHB4OyB0ZXh0LWFsaWduOiBj
ZW50ZXI7IH0KCiAgICAgICAgLyog4pSA4pSAIENsZWFyIGNvbmZpcm0g4pSA4pSA4pSA4pSA4pSA4pSA
4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA
4pSA4pSA4pSA4pSA4pSAICovCiAgICAgICAgI2Nsci1kbGcgewogICAgICAgICAgICBkaXNwbGF5OiBu
b25lOyBwb3NpdGlvbjogZml4ZWQ7IGluc2V0OiAwOyB6LWluZGV4OiAxMDAwMDsKICAgICAgICAgICAg
YmFja2dyb3VuZDogcmdiYSgyMCwgMjIsIDM1LCAuNDIpOwogICAgICAgICAgICBhbGlnbi1pdGVtczog
Y2VudGVyOyBqdXN0aWZ5LWNvbnRlbnQ6IGNlbnRlcjsKICAgICAgICAgICAgLXdlYmtpdC1hcHAtcmVn
aW9uOiBuby1kcmFnOyBhcHAtcmVnaW9uOiBuby1kcmFnOwogICAgICAgIH0KICAgICAgICAjY2xyLWRs
Zy5vbiB7IGRpc3BsYXk6IGZsZXg7IH0KICAgICAgICAuY2xyLWJveCB7CiAgICAgICAgICAgIHdpZHRo
OiBtaW4oMjgwcHgsIGNhbGMoMTAwJSAtIDMycHgpKTsKICAgICAgICAgICAgYmFja2dyb3VuZDogI2Zm
ZjsgYm9yZGVyLXJhZGl1czogMTJweDsKICAgICAgICAgICAgYm94LXNoYWRvdzogMCAxMnB4IDMycHgg
cmdiYSgwLDAsMCwuMTgpOwogICAgICAgICAgICBwYWRkaW5nOiAxNnB4IDE2cHggMTRweDsgY29sb3I6
IHZhcigtLXR4dCk7CiAgICAgICAgfQogICAgICAgIC5jbHItdGl0bGUgeyBmb250LXNpemU6IDE0cHg7
IGZvbnQtd2VpZ2h0OiA3MDA7IG1hcmdpbi1ib3R0b206IDZweDsgfQogICAgICAgIC5jbHItZGVzYyB7
IGZvbnQtc2l6ZTogMTFweDsgY29sb3I6IHZhcigtLXR4dDMpOyBsaW5lLWhlaWdodDogMS41OyBtYXJn
aW4tYm90dG9tOiAxMnB4OyB9CiAgICAgICAgLmNsci1jaGVjayB7CiAgICAgICAgICAgIGRpc3BsYXk6
IGZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGdhcDogN3B4OwogICAgICAgICAgICBmb250LXNpemU6
IDEycHg7IGNvbG9yOiB2YXIoLS10eHQpOyBjdXJzb3I6IHBvaW50ZXI7CiAgICAgICAgICAgIHVzZXIt
c2VsZWN0OiBub25lOyBtYXJnaW4tYm90dG9tOiAxNHB4OwogICAgICAgIH0KICAgICAgICAuY2xyLWNo
ZWNrIGlucHV0IHsKICAgICAgICAgICAgd2lkdGg6IDE0cHg7IGhlaWdodDogMTRweDsgYWNjZW50LWNv
bG9yOiB2YXIoLS1hY2MpOyBjdXJzb3I6IHBvaW50ZXI7CiAgICAgICAgfQogICAgICAgIC5jbHItYnRu
cyB7IGRpc3BsYXk6IGZsZXg7IGdhcDogOHB4OyBqdXN0aWZ5LWNvbnRlbnQ6IGZsZXgtZW5kOyB9CiAg
ICAgICAgLmNsci1idG5zIGJ1dHRvbiB7CiAgICAgICAgICAgIGJvcmRlcjogbm9uZTsgYm9yZGVyLXJh
ZGl1czogOHB4OyBwYWRkaW5nOiA3cHggMTRweDsKICAgICAgICAgICAgZm9udC1zaXplOiAxMnB4OyBj
dXJzb3I6IHBvaW50ZXI7IGZvbnQtd2VpZ2h0OiA2MDA7CiAgICAgICAgICAgIHRyYW5zaXRpb246IGJh
Y2tncm91bmQgdmFyKC0tdHIpLCBjb2xvciB2YXIoLS10cik7CiAgICAgICAgfQogICAgICAgICNjbHIt
Y2FuY2VsIHsgYmFja2dyb3VuZDogI2YxZjNmODsgY29sb3I6IHZhcigtLXR4dDIpOyB9CiAgICAgICAg
I2Nsci1jYW5jZWw6aG92ZXIgeyBiYWNrZ3JvdW5kOiAjZTZlOWYyOyB9CiAgICAgICAgI2Nsci1vayB7
IGJhY2tncm91bmQ6IHJnYmEoMjU1LDEyMywxNTYsLjE0KTsgY29sb3I6ICNlODVhN2E7IH0KICAgICAg
ICAjY2xyLW9rOmhvdmVyIHsgYmFja2dyb3VuZDogcmdiYSgyNTUsMTIzLDE1NiwuMjQpOyB9CgogICAg
ICAgIC8qIOKUgOKUgCBGaWxlIHBhdGggdGlwIOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKU
gOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKU
gCAqLwogICAgICAgICNwYXRoLXRpcCB7CiAgICAgICAgICAgIGRpc3BsYXk6IG5vbmU7IHBvc2l0aW9u
OiBmaXhlZDsgei1pbmRleDogMTAwMDE7CiAgICAgICAgICAgIHdpZHRoOiBtaW4oMzIwcHgsIGNhbGMo
MTAwdncgLSAxNnB4KSk7CiAgICAgICAgICAgIG1heC1oZWlnaHQ6IG1pbigyODBweCwgY2FsYygxMDB2
aCAtIDI0cHgpKTsKICAgICAgICAgICAgb3ZlcmZsb3c6IGF1dG87CiAgICAgICAgICAgIHBhZGRpbmc6
IDA7CiAgICAgICAgICAgIGJhY2tncm91bmQ6IGxpbmVhci1ncmFkaWVudCgxNjVkZWcsICNmZmZmZmYg
MCUsICNmNmY4ZmMgMTAwJSk7CiAgICAgICAgICAgIGJvcmRlcjogMXB4IHNvbGlkIHJnYmEoNzAsIDg0
LCAxMjAsIC4xKTsKICAgICAgICAgICAgYm9yZGVyLXJhZGl1czogMTJweDsKICAgICAgICAgICAgYm94
LXNoYWRvdzoKICAgICAgICAgICAgICAgIDAgNHB4IDZweCByZ2JhKDMwLCA0MCwgNzAsIC4wNCksCiAg
ICAgICAgICAgICAgICAwIDE0cHggMzZweCByZ2JhKDMwLCA0MCwgNzAsIC4xNik7CiAgICAgICAgICAg
IGNvbG9yOiB2YXIoLS10eHQpOwogICAgICAgICAgICBwb2ludGVyLWV2ZW50czogYXV0bzsKICAgICAg
ICAgICAgb3BhY2l0eTogMDsKICAgICAgICAgICAgdHJhbnNmb3JtOiB0cmFuc2xhdGVZKDRweCkgc2Nh
bGUoLjk4KTsKICAgICAgICAgICAgdHJhbnNpdGlvbjogb3BhY2l0eSAuMTRzIGVhc2UsIHRyYW5zZm9y
bSAuMTRzIGVhc2U7CiAgICAgICAgICAgIC13ZWJraXQtYXBwLXJlZ2lvbjogbm8tZHJhZzsgYXBwLXJl
Z2lvbjogbm8tZHJhZzsKICAgICAgICB9CiAgICAgICAgI3BhdGgtdGlwLm9uIHsKICAgICAgICAgICAg
ZGlzcGxheTogYmxvY2s7CiAgICAgICAgICAgIG9wYWNpdHk6IDE7CiAgICAgICAgICAgIHRyYW5zZm9y
bTogdHJhbnNsYXRlWSgwKSBzY2FsZSgxKTsKICAgICAgICB9CiAgICAgICAgLnB0LWhlYWQgewogICAg
ICAgICAgICBkaXNwbGF5OiBmbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBqdXN0aWZ5LWNvbnRlbnQ6
IHNwYWNlLWJldHdlZW47CiAgICAgICAgICAgIGdhcDogMTBweDsgcGFkZGluZzogMTBweCAxMnB4IDhw
eDsKICAgICAgICAgICAgYm9yZGVyLWJvdHRvbTogMXB4IHNvbGlkIHJnYmEoNzAsIDg0LCAxMjAsIC4w
Nyk7CiAgICAgICAgfQogICAgICAgIC5wdC10aXRsZSB7CiAgICAgICAgICAgIGZvbnQtc2l6ZTogMTFw
eDsgZm9udC13ZWlnaHQ6IDcwMDsgbGV0dGVyLXNwYWNpbmc6IC4wNGVtOwogICAgICAgICAgICBjb2xv
cjogdmFyKC0tdHh0Mik7IHRleHQtdHJhbnNmb3JtOiB1cHBlcmNhc2U7CiAgICAgICAgICAgIGZsZXgt
c2hyaW5rOiAwOwogICAgICAgIH0KICAgICAgICAucHQtaGVhZC1idG4gewogICAgICAgICAgICBmbGV4
LXNocmluazogMDsgbWFyZ2luLWxlZnQ6IGF1dG87CiAgICAgICAgICAgIGhlaWdodDogMjJweDsgcGFk
ZGluZzogMCA4cHg7IGRpc3BsYXk6IGlubGluZS1mbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBnYXA6
IDRweDsKICAgICAgICAgICAgYm9yZGVyOiAxcHggc29saWQgcmdiYSgxMDcsMTEyLDEyOCwuMjIpOyBi
b3JkZXItcmFkaXVzOiA2cHg7IGN1cnNvcjogcG9pbnRlcjsKICAgICAgICAgICAgYmFja2dyb3VuZDog
cmdiYSgxMDcsMTEyLDEyOCwuMDYpOyBjb2xvcjogIzhhOTBhMDsgZm9udC1zaXplOiAxMXB4OyBmb250
LXdlaWdodDogNjAwOwogICAgICAgICAgICB3aGl0ZS1zcGFjZTogbm93cmFwOwogICAgICAgICAgICAt
d2Via2l0LWFwcC1yZWdpb246IG5vLWRyYWc7IGFwcC1yZWdpb246IG5vLWRyYWc7CiAgICAgICAgICAg
IHRyYW5zaXRpb246IGJhY2tncm91bmQgdmFyKC0tdHIpLCBjb2xvciB2YXIoLS10ciksIGJvcmRlci1j
b2xvciB2YXIoLS10cik7CiAgICAgICAgfQogICAgICAgIC5wdC1oZWFkLWJ0bjpob3ZlciB7CiAgICAg
ICAgICAgIGJhY2tncm91bmQ6IHJnYmEoMTA3LDExMiwxMjgsLjEyKTsgY29sb3I6IHZhcigtLXR4dDIp
OwogICAgICAgICAgICBib3JkZXItY29sb3I6IHJnYmEoMTA3LDExMiwxMjgsLjQpOwogICAgICAgIH0K
ICAgICAgICAucHQtbGlzdCB7IHBhZGRpbmc6IDZweCA4cHggOHB4OyBkaXNwbGF5OiBmbGV4OyBmbGV4
LWRpcmVjdGlvbjogY29sdW1uOyBnYXA6IDRweDsgfQogICAgICAgIC5wdC1yb3cgewogICAgICAgICAg
ICBkaXNwbGF5OiBncmlkOyBncmlkLXRlbXBsYXRlLWNvbHVtbnM6IDhweCAxZnI7IGdhcDogOHB4Owog
ICAgICAgICAgICBwYWRkaW5nOiA4cHggOHB4OyBib3JkZXItcmFkaXVzOiA4cHg7CiAgICAgICAgICAg
IGJhY2tncm91bmQ6IHJnYmEoMjU1LDI1NSwyNTUsLjcpOwogICAgICAgIH0KICAgICAgICAucHQtcm93
LmRlYWQgeyBiYWNrZ3JvdW5kOiByZ2JhKDI1NSwgMTIzLCAxNTYsIC4wNik7IH0KICAgICAgICAucHQt
ZG90IHsKICAgICAgICAgICAgd2lkdGg6IDhweDsgaGVpZ2h0OiA4cHg7IGJvcmRlci1yYWRpdXM6IDUw
JTsgbWFyZ2luLXRvcDogNXB4OwogICAgICAgICAgICBiYWNrZ3JvdW5kOiAjMmViNDc4OyBib3gtc2hh
ZG93OiAwIDAgMCAzcHggcmdiYSg0NiwgMTgwLCAxMjAsIC4xOCk7CiAgICAgICAgfQogICAgICAgIC5w
dC1yb3cuZGVhZCAucHQtZG90IHsKICAgICAgICAgICAgYmFja2dyb3VuZDogI2U4NWE3YTsgYm94LXNo
YWRvdzogMCAwIDAgM3B4IHJnYmEoMjMyLCA5MCwgMTIyLCAuMTYpOwogICAgICAgIH0KICAgICAgICAu
cHQtbmFtZSB7CiAgICAgICAgICAgIGZvbnQtc2l6ZTogMTJweDsgZm9udC13ZWlnaHQ6IDY1MDsgY29s
b3I6IHZhcigtLXR4dCk7CiAgICAgICAgICAgIGxpbmUtaGVpZ2h0OiAxLjM7IHdvcmQtYnJlYWs6IGJy
ZWFrLWFsbDsKICAgICAgICB9CiAgICAgICAgLnB0LXBhdGggewogICAgICAgICAgICBtYXJnaW4tdG9w
OiAzcHg7CiAgICAgICAgICAgIGZvbnQ6IDEwLjVweC8xLjQ1ICdDYXNjYWRpYSBNb25vJywnQ29uc29s
YXMnLCdNaWNyb3NvZnQgWWFIZWkgVUknLG1vbm9zcGFjZTsKICAgICAgICAgICAgY29sb3I6IHZhcigt
LXR4dDIpOyB3b3JkLWJyZWFrOiBicmVhay1hbGw7CiAgICAgICAgICAgIHVzZXItc2VsZWN0OiB0ZXh0
OwogICAgICAgIH0KICAgICAgICAucHQtcGF0aC5saXZlIHsKICAgICAgICAgICAgY29sb3I6IHZhcigt
LWFjYyk7IGN1cnNvcjogcG9pbnRlcjsKICAgICAgICB9CiAgICAgICAgLnB0LXBhdGgubGl2ZTpob3Zl
ciB7IHRleHQtZGVjb3JhdGlvbjogdW5kZXJsaW5lOyB9CiAgICAgICAgLnB0LXBhdGguZGVhZCB7CiAg
ICAgICAgICAgIGNvbG9yOiAjYzQzZDVjOwogICAgICAgICAgICB0ZXh0LWRlY29yYXRpb246IGxpbmUt
dGhyb3VnaDsKICAgICAgICAgICAgdGV4dC1kZWNvcmF0aW9uLXRoaWNrbmVzczogMnB4OwogICAgICAg
ICAgICB0ZXh0LWRlY29yYXRpb24tY29sb3I6ICNlMTFkNDg7CiAgICAgICAgICAgIGN1cnNvcjogZGVm
YXVsdDsKICAgICAgICB9CiAgICAgICAgLnB0LWFjdGlvbnMgewogICAgICAgICAgICBtYXJnaW4tdG9w
OiA2cHg7CiAgICAgICAgICAgIGRpc3BsYXk6IGZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGdhcDog
NnB4OyBmbGV4LXdyYXA6IHdyYXA7CiAgICAgICAgfQogICAgICAgIC5wdC1jb3B5LWJ0biB7CiAgICAg
ICAgICAgIGhlaWdodDogMjJweDsgcGFkZGluZzogMCA4cHg7IGRpc3BsYXk6IGlubGluZS1mbGV4OyBh
bGlnbi1pdGVtczogY2VudGVyOwogICAgICAgICAgICBib3JkZXI6IDFweCBzb2xpZCByZ2JhKDEwNywx
MTIsMTI4LC4yMik7IGJvcmRlci1yYWRpdXM6IDZweDsgY3Vyc29yOiBwb2ludGVyOwogICAgICAgICAg
ICBiYWNrZ3JvdW5kOiByZ2JhKDEwNywxMTIsMTI4LC4wNik7IGNvbG9yOiAjOGE5MGEwOyBmb250LXNp
emU6IDExcHg7IGZvbnQtd2VpZ2h0OiA2MDA7CiAgICAgICAgICAgIC13ZWJraXQtYXBwLXJlZ2lvbjog
bm8tZHJhZzsgYXBwLXJlZ2lvbjogbm8tZHJhZzsKICAgICAgICAgICAgdHJhbnNpdGlvbjogYmFja2dy
b3VuZCB2YXIoLS10ciksIGNvbG9yIHZhcigtLXRyKSwgYm9yZGVyLWNvbG9yIHZhcigtLXRyKTsKICAg
ICAgICB9CiAgICAgICAgLnB0LWNvcHktYnRuOmhvdmVyIHsKICAgICAgICAgICAgYmFja2dyb3VuZDog
cmdiYSgxMDcsMTEyLDEyOCwuMTIpOyBjb2xvcjogdmFyKC0tdHh0Mik7CiAgICAgICAgICAgIGJvcmRl
ci1jb2xvcjogcmdiYSgxMDcsMTEyLDEyOCwuNCk7CiAgICAgICAgfQogICAgICAgIC5wdC1jb3B5LWJ0
bi5vayB7CiAgICAgICAgICAgIGNvbG9yOiAjMWY3YTU1OyBib3JkZXItY29sb3I6IHJnYmEoNDYsIDE4
MCwgMTIwLCAuMzUpOwogICAgICAgICAgICBiYWNrZ3JvdW5kOiByZ2JhKDQ2LCAxODAsIDEyMCwgLjEp
OwogICAgICAgIH0KICAgICAgICAuaXRtLml0LWdyb3VwIHsKICAgICAgICAgICAgZmxleC1kaXJlY3Rp
b246IGNvbHVtbjsKICAgICAgICAgICAgYWxpZ24taXRlbXM6IHN0cmV0Y2g7CiAgICAgICAgICAgIGdh
cDogMDsKICAgICAgICAgICAgcGFkZGluZzogNnB4IDhweCA0cHg7CiAgICAgICAgICAgIGN1cnNvcjog
ZGVmYXVsdDsKICAgICAgICB9CiAgICAgICAgLml0bS5pdC1ncm91cDpob3ZlciB7IGJhY2tncm91bmQ6
IHZhcigtLWNhcmQpOyB9CiAgICAgICAgLm1nLWhlYWQgewogICAgICAgICAgICBkaXNwbGF5OiBmbGV4
OyBhbGlnbi1pdGVtczogY2VudGVyOyBnYXA6IDZweDsKICAgICAgICAgICAgZm9udC1zaXplOiAxMXB4
OyBjb2xvcjogdmFyKC0tdHh0Myk7IGZvbnQtd2VpZ2h0OiA2MDA7CiAgICAgICAgICAgIHBhZGRpbmc6
IDJweCAycHggNnB4OyB1c2VyLXNlbGVjdDogbm9uZTsKICAgICAgICB9CiAgICAgICAgLm1nLWhlYWQg
Lm1nLXRhZyB7CiAgICAgICAgICAgIGRpc3BsYXk6IGlubGluZS1mbGV4OyBhbGlnbi1pdGVtczogY2Vu
dGVyOwogICAgICAgICAgICBoZWlnaHQ6IDE2cHg7IHBhZGRpbmc6IDAgNnB4OyBib3JkZXItcmFkaXVz
OiA4cHg7CiAgICAgICAgICAgIGJhY2tncm91bmQ6IHJnYmEoOTEsMTE1LDIzMiwuMTIpOyBjb2xvcjog
dmFyKC0tYWNjKTsgZm9udC1zaXplOiAxMHB4OwogICAgICAgIH0KICAgICAgICAubWctcm93IHsKICAg
ICAgICAgICAgcGFkZGluZzogN3B4IDZweDsgbWFyZ2luLWJvdHRvbTogM3B4OwogICAgICAgICAgICBi
b3JkZXItcmFkaXVzOiA1cHg7IGN1cnNvcjogcG9pbnRlcjsKICAgICAgICAgICAgYm9yZGVyOiAxcHgg
c29saWQgdHJhbnNwYXJlbnQ7CiAgICAgICAgICAgIHRyYW5zaXRpb246IGJhY2tncm91bmQgLjEycyBl
YXNlLCBib3JkZXItY29sb3IgLjEycyBlYXNlOwogICAgICAgIH0KICAgICAgICAubWctcm93OmhvdmVy
IHsgYmFja2dyb3VuZDogdmFyKC0tY2FyZC1oKTsgfQogICAgICAgIC5tZy1yb3cuc2VsIHsKICAgICAg
ICAgICAgYmFja2dyb3VuZDogI2VkZjFmZjsKICAgICAgICAgICAgYm9yZGVyLWNvbG9yOiByZ2JhKDkx
LDExNSwyMzIsLjM1KTsKICAgICAgICAgICAgYm94LXNoYWRvdzogMCAwIDAgMXB4IHJnYmEoOTEsMTE1
LDIzMiwuMjUpOwogICAgICAgIH0KICAgICAgICAubWctcm93Lm11bHRpIHsKICAgICAgICAgICAgYmFj
a2dyb3VuZDogI2VlZjJmZjsKICAgICAgICAgICAgYm9yZGVyLWNvbG9yOiByZ2JhKDkxLDExNSwyMzIs
LjQ1KTsKICAgICAgICB9CiAgICAgICAgLm1nLXRpdGxlIHsKICAgICAgICAgICAgZm9udC1zaXplOiAx
M3B4OyBmb250LXdlaWdodDogNjAwOyBjb2xvcjogdmFyKC0tYWNjKTsKICAgICAgICAgICAgbWFyZ2lu
LWJvdHRvbTogMnB4OyBsaW5lLWhlaWdodDogMS4zNTsKICAgICAgICAgICAgZGlzcGxheTogLXdlYmtp
dC1ib3g7IC13ZWJraXQtYm94LW9yaWVudDogdmVydGljYWw7IC13ZWJraXQtbGluZS1jbGFtcDogMjsK
ICAgICAgICAgICAgb3ZlcmZsb3c6IGhpZGRlbjsgd29yZC1icmVhazogYnJlYWstd29yZDsKICAgICAg
ICB9CiAgICAgICAgLm1nLWJvZHkgewogICAgICAgICAgICBmb250LXNpemU6IDEyLjVweDsgZm9udC13
ZWlnaHQ6IDUwMDsgY29sb3I6IHZhcigtLXR4dCk7CiAgICAgICAgICAgIHdoaXRlLXNwYWNlOiBwcmUt
d3JhcDsgd29yZC1icmVhazogYnJlYWstYWxsOwogICAgICAgICAgICBkaXNwbGF5OiAtd2Via2l0LWJv
eDsgLXdlYmtpdC1ib3gtb3JpZW50OiB2ZXJ0aWNhbDsgLXdlYmtpdC1saW5lLWNsYW1wOiA0OwogICAg
ICAgICAgICBvdmVyZmxvdzogaGlkZGVuOyBsaW5lLWhlaWdodDogMS40OwogICAgICAgIH0KICAgICAg
ICAubWctYm9keS5pbWcgeyBjb2xvcjogdmFyKC0tdHh0Mik7IH0KICAgICAgICAubWctcm93LXRvcCB7
CiAgICAgICAgICAgIGRpc3BsYXk6IGZsZXg7IGFsaWduLWl0ZW1zOiBmbGV4LXN0YXJ0OyBnYXA6IDhw
eDsKICAgICAgICB9CiAgICAgICAgLm1nLXJvdy1tYWluIHsgZmxleDogMTsgbWluLXdpZHRoOiAwOyB9
CiAgICAgICAgLm1nLXNyYyB7CiAgICAgICAgICAgIHdpZHRoOiAxOHB4OyBoZWlnaHQ6IDE4cHg7IGZs
ZXgtc2hyaW5rOiAwOyBtYXJnaW4tdG9wOiAycHg7CiAgICAgICAgICAgIGJvcmRlci1yYWRpdXM6IDNw
eDsgb2JqZWN0LWZpdDogY29udGFpbjsKICAgICAgICAgICAgYmFja2dyb3VuZDogcmdiYSgwLDAsMCwu
MDQpOwogICAgICAgIH0KICAgICAgICAuaS1mYXYtdGl0bGUgewogICAgICAgICAgICBmb250LXNpemU6
IDEzcHg7IGZvbnQtd2VpZ2h0OiA2MDA7IGNvbG9yOiB2YXIoLS1hY2MpOwogICAgICAgICAgICBtYXJn
aW46IDAgMCAzcHg7IGxpbmUtaGVpZ2h0OiAxLjM1OwogICAgICAgICAgICBkaXNwbGF5OiAtd2Via2l0
LWJveDsgLXdlYmtpdC1ib3gtb3JpZW50OiB2ZXJ0aWNhbDsgLXdlYmtpdC1saW5lLWNsYW1wOiAyOwog
ICAgICAgICAgICBvdmVyZmxvdzogaGlkZGVuOyB3b3JkLWJyZWFrOiBicmVhay13b3JkOwogICAgICAg
IH0KICAgICAgICAjdGl0bGUtZGxnIHsKICAgICAgICAgICAgZGlzcGxheTogbm9uZTsgcG9zaXRpb246
IGZpeGVkOyBpbnNldDogMDsgei1pbmRleDogMTAwOwogICAgICAgICAgICBiYWNrZ3JvdW5kOiByZ2Jh
KDE1LDE4LDI4LC4zNSk7CiAgICAgICAgICAgIGFsaWduLWl0ZW1zOiBjZW50ZXI7IGp1c3RpZnktY29u
dGVudDogY2VudGVyOwogICAgICAgIH0KICAgICAgICAjdGl0bGUtZGxnLm9uIHsgZGlzcGxheTogZmxl
eDsgfQogICAgICAgICN0aXRsZS1kbGcgLnRpdGxlLWJveCB7CiAgICAgICAgICAgIHdpZHRoOiAyNjBw
eDsgcGFkZGluZzogMTZweCAxNnB4IDEycHg7CiAgICAgICAgICAgIGJhY2tncm91bmQ6IHZhcigtLWNh
cmQpOyBib3JkZXItcmFkaXVzOiAxMHB4OwogICAgICAgICAgICBib3gtc2hhZG93OiAwIDhweCAyOHB4
IHJnYmEoMCwwLDAsLjE4KTsKICAgICAgICB9CiAgICAgICAgI3RpdGxlLWlucHV0IHsKICAgICAgICAg
ICAgd2lkdGg6IDEwMCU7IGJveC1zaXppbmc6IGJvcmRlci1ib3g7IG1hcmdpbjogOHB4IDAgMTJweDsK
ICAgICAgICAgICAgaGVpZ2h0OiAzMnB4OyBwYWRkaW5nOiAwIDEwcHg7IGJvcmRlci1yYWRpdXM6IDZw
eDsKICAgICAgICAgICAgYm9yZGVyOiAxcHggc29saWQgI2Q1ZGFlNjsgYmFja2dyb3VuZDogI2ZmZjsg
Y29sb3I6IHZhcigtLXR4dCk7CiAgICAgICAgICAgIGZvbnQtc2l6ZTogMTNweDsgb3V0bGluZTogbm9u
ZTsKICAgICAgICB9CiAgICAgICAgI3RpdGxlLWlucHV0OmZvY3VzIHsgYm9yZGVyLWNvbG9yOiB2YXIo
LS1hY2MpOyB9CgogICAgCiAgICAgICAgLyogdWktZ3JheS1iZy12MSAqLwogICAgICAgIDpyb290IHsK
ICAgICAgICAgICAgLS1iZzogI2U0ZTdlZSAhaW1wb3J0YW50OwogICAgICAgIH0KICAgICAgICBodG1s
LCBib2R5IHsKICAgICAgICAgICAgYmFja2dyb3VuZDogI2U0ZTdlZSAhaW1wb3J0YW50OwogICAgICAg
IH0KICAgICAgICAjYXBwIHsKICAgICAgICAgICAgYmFja2dyb3VuZDogbGluZWFyLWdyYWRpZW50KDE4
MGRlZywgI2U5ZWNmMyAwJSwgI2UwZTRlYyAxMDAlKSAhaW1wb3J0YW50OwogICAgICAgIH0KICAgICAg
ICAjaGRyIHsKICAgICAgICAgICAgYmFja2dyb3VuZDogI2UyZTZlZSAhaW1wb3J0YW50OwogICAgICAg
IH0KICAgICAgICAjdGFicyB7CiAgICAgICAgICAgIGJhY2tncm91bmQ6ICNlMmU2ZWUgIWltcG9ydGFu
dDsKICAgICAgICB9CiAgICAgICAgI2xpc3QsICNlbXB0eSwgI3NrZWwsICNoZHItZ3JvdywgI3NlYXJj
aC13cmFwIHsKICAgICAgICAgICAgYmFja2dyb3VuZDogdHJhbnNwYXJlbnQgIWltcG9ydGFudDsKICAg
ICAgICB9CiAgICAgICAgI3NlYXJjaC1ib3ggewogICAgICAgICAgICB0cmFuc2Zvcm0tb3JpZ2luOiBy
aWdodCBjZW50ZXI7CiAgICAgICAgICAgIGJhY2tncm91bmQ6IHRyYW5zcGFyZW50ICFpbXBvcnRhbnQ7
CiAgICAgICAgfQogICAgICAgIC5pdG0sIC5tZywgLm1nLXJvdywgLm1lcmdlLWdyb3VwIHsKICAgICAg
ICAgICAgYmFja2dyb3VuZDogI2ZmZmZmZiAhaW1wb3J0YW50OwogICAgICAgIH0KICAgICAgICAuaXRt
OmhvdmVyIHsKICAgICAgICAgICAgYmFja2dyb3VuZDogI2Y4ZjlmYyAhaW1wb3J0YW50OwogICAgICAg
IH0KICAgIAogICAgICAgIC8qIHNlbC10aW50LWJsdWUtdjEgKi8KICAgICAgICAuaXRtLnNlbCwKICAg
ICAgICAubWctcm93LnNlbCwKICAgICAgICAuaXRtLm11bHRpLAogICAgICAgIC5tZy1yb3cubXVsdGks
CiAgICAgICAgLml0bS5tdWx0aS5zZWwsCiAgICAgICAgLml0LWdyb3VwLnNlbCwKICAgICAgICAuaXQt
Z3JvdXAubXVsdGkgewogICAgICAgICAgICBiYWNrZ3JvdW5kOiAjZThlZmZmICFpbXBvcnRhbnQ7CiAg
ICAgICAgfQogICAgICAgIC5pdG0uc2VsOmhvdmVyLAogICAgICAgIC5pdG0ubXVsdGk6aG92ZXIsCiAg
ICAgICAgLm1nLXJvdy5zZWw6aG92ZXIsCiAgICAgICAgLm1nLXJvdy5tdWx0aTpob3ZlciB7CiAgICAg
ICAgICAgIGJhY2tncm91bmQ6ICNkZGU2ZmYgIWltcG9ydGFudDsKICAgICAgICB9CiAgICAKICAgICAg
ICAvKiBob3Zlci1ncmVlbi1yaXNlLXYyICovCiAgICAgICAgLyogaG92ZXItYWNjZW50LXJpc2UtdjMg
Ki8KICAgICAgICAuaXRtIHsgcG9zaXRpb246IHJlbGF0aXZlICFpbXBvcnRhbnQ7IG92ZXJmbG93OiBo
aWRkZW4gIWltcG9ydGFudDsgfQogICAgICAgIC5pdG06OmJlZm9yZSB7CiAgICAgICAgICAgIGNvbnRl
bnQ6ICIiICFpbXBvcnRhbnQ7CiAgICAgICAgICAgIHBvc2l0aW9uOiBhYnNvbHV0ZSAhaW1wb3J0YW50
OwogICAgICAgICAgICBsZWZ0OiAwICFpbXBvcnRhbnQ7IHJpZ2h0OiAwICFpbXBvcnRhbnQ7IGJvdHRv
bTogMCAhaW1wb3J0YW50OwogICAgICAgICAgICBoZWlnaHQ6IDAgIWltcG9ydGFudDsKICAgICAgICAg
ICAgcG9pbnRlci1ldmVudHM6IG5vbmUgIWltcG9ydGFudDsKICAgICAgICAgICAgei1pbmRleDogMCAh
aW1wb3J0YW50OwogICAgICAgICAgICBib3JkZXItcmFkaXVzOiAwIDAgdmFyKC0tciwgNHB4KSB2YXIo
LS1yLCA0cHgpICFpbXBvcnRhbnQ7CiAgICAgICAgICAgIGJhY2tncm91bmQ6IGxpbmVhci1ncmFkaWVu
dCh0byB0b3AsCiAgICAgICAgICAgICAgICByZ2JhKDkxLCAxMTUsIDIzMiwgLjMyKSAwJSwKICAgICAg
ICAgICAgICAgIHJnYmEoOTEsIDExNSwgMjMyLCAuMTIpIDU1JSwKICAgICAgICAgICAgICAgIHJnYmEo
OTEsIDExNSwgMjMyLCAwKSAxMDAlKSAhaW1wb3J0YW50OwogICAgICAgICAgICB0cmFuc2l0aW9uOiBo
ZWlnaHQgLjM0cyBjdWJpYy1iZXppZXIoLjIyLCAxLCAuMzYsIDEpICFpbXBvcnRhbnQ7CiAgICAgICAg
fQogICAgICAgIC5pdG06aG92ZXI6OmJlZm9yZSB7IGhlaWdodDogMzMuMzMzJSAhaW1wb3J0YW50OyB9
CiAgICAgICAgLml0bTo6YWZ0ZXIgewogICAgICAgICAgICBjb250ZW50OiAiIiAhaW1wb3J0YW50Owog
ICAgICAgICAgICBwb3NpdGlvbjogYWJzb2x1dGUgIWltcG9ydGFudDsKICAgICAgICAgICAgbGVmdDog
MCAhaW1wb3J0YW50OyByaWdodDogMCAhaW1wb3J0YW50OyBib3R0b206IDAgIWltcG9ydGFudDsKICAg
ICAgICAgICAgaGVpZ2h0OiAycHggIWltcG9ydGFudDsKICAgICAgICAgICAgcG9pbnRlci1ldmVudHM6
IG5vbmUgIWltcG9ydGFudDsKICAgICAgICAgICAgei1pbmRleDogMSAhaW1wb3J0YW50OwogICAgICAg
ICAgICBiYWNrZ3JvdW5kOiByZ2JhKDkxLCAxMTUsIDIzMiwgLjkyKSAhaW1wb3J0YW50OwogICAgICAg
ICAgICBib3JkZXItcmFkaXVzOiAxcHggIWltcG9ydGFudDsKICAgICAgICAgICAgdHJhbnNmb3JtOiBz
Y2FsZVgoMCkgIWltcG9ydGFudDsKICAgICAgICAgICAgdHJhbnNmb3JtLW9yaWdpbjogY2VudGVyICFp
bXBvcnRhbnQ7CiAgICAgICAgICAgIHRyYW5zaXRpb246IHRyYW5zZm9ybSAuM3MgY3ViaWMtYmV6aWVy
KC4yMiwgMSwgLjM2LCAxKSAhaW1wb3J0YW50OwogICAgICAgIH0KICAgICAgICAuaXRtOmhvdmVyOjph
ZnRlciB7CiAgICAgICAgICAgIHRyYW5zZm9ybTogc2NhbGVYKDEpICFpbXBvcnRhbnQ7CiAgICAgICAg
ICAgIGJhY2tncm91bmQ6IHJnYmEoOTEsIDExNSwgMjMyLCAuOTUpICFpbXBvcnRhbnQ7CiAgICAgICAg
fQogICAgICAgIC5pdG0gPiAqIHsgcG9zaXRpb246IHJlbGF0aXZlOyB6LWluZGV4OiAyOyB9CiAgICAg
ICAgICAgIC8qIHdoaXRlLXBhbmVsLWJvcmRlcjogb3V0ZXIgZWRnZSBsaW5lIHJlbW92ZWQgKi8KICAg
ICAgICAjYXBwIHsKICAgICAgICAgICAgYm9yZGVyOiBub25lICFpbXBvcnRhbnQ7CiAgICAgICAgICAg
IGJvcmRlci1yYWRpdXM6IDAgIWltcG9ydGFudDsKICAgICAgICAgICAgYm94LXNpemluZzogYm9yZGVy
LWJveCAhaW1wb3J0YW50OwogICAgICAgICAgICBvdmVyZmxvdzogaGlkZGVuICFpbXBvcnRhbnQ7CiAg
ICAgICAgfQogICAgICAgIC5pdG0sIC5tZywgLm1nLXJvdywgLm1lcmdlLWdyb3VwIHsKICAgICAgICAg
ICAgYm9yZGVyOiAxcHggc29saWQgI2ZmZmZmZiAhaW1wb3J0YW50OwogICAgICAgIH0KICAgIDwvc3R5
bGU+CjwvaGVhZD4KPGJvZHk+CjxkaXYgaWQ9ImFwcCI+CiAgICA8ZGl2IGlkPSJoZHIiPgogICAgICAg
IDxkaXYgaWQ9ImhlYXJ0Ij4KICAgICAgICAgICAgPHN2ZyB2aWV3Qm94PSIwIDAgMjQgMjQiIGZpbGw9
Im5vbmUiIHN0cm9rZT0iY3VycmVudENvbG9yIiBzdHJva2Utd2lkdGg9IjEuOCIKICAgICAgICAgICAg
ICAgICBzdHJva2UtbGluZWNhcD0icm91bmQiIHN0cm9rZS1saW5lam9pbj0icm91bmQiPgogICAgICAg
ICAgICAgICAgPHJlY3QgeD0iOSIgeT0iMiIgd2lkdGg9IjYiIGhlaWdodD0iNCIgcng9IjEiLz4KICAg
ICAgICAgICAgICAgIDxwYXRoIGQ9Ik0xNiA0aDJhMiAyIDAgMCAxIDIgMnYxNGEyIDIgMCAwIDEtMiAy
SDZhMiAyIDAgMCAxLTItMlY2YTIgMiAwIDAgMSAyLTJoMiIvPgogICAgICAgICAgICAgICAgPHBhdGgg
ZD0iTTkgMTJoNk05IDE2aDQiLz4KICAgICAgICAgICAgPC9zdmc+CiAgICAgICAgPC9kaXY+CiAgICAg
ICAgPGRpdiBpZD0iaGRyLWdyb3ciPjwvZGl2PgogICAgICAgIDxidXR0b24gaWQ9ImJ0bi1sb2NhdGUi
IHR5cGU9ImJ1dHRvbiIgdGl0bGU9IuWumuS9jeWIsOS4iuasoeS9v+eUqOeahOadoeebriIgZGlzYWJs
ZWQ+CiAgICAgICAgICAgIDxzdmcgdmlld0JveD0iMCAwIDI0IDI0IiBmaWxsPSJub25lIiBzdHJva2U9
ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIyIgogICAgICAgICAgICAgICAgIHN0cm9rZS1saW5l
Y2FwPSJyb3VuZCIgc3Ryb2tlLWxpbmVqb2luPSJyb3VuZCI+CiAgICAgICAgICAgICAgICA8Y2lyY2xl
IGN4PSIxMiIgY3k9IjEyIiByPSI4Ii8+CiAgICAgICAgICAgICAgICA8Y2lyY2xlIGN4PSIxMiIgY3k9
IjEyIiByPSIzLjUiLz4KICAgICAgICAgICAgPC9zdmc+CiAgICAgICAgPC9idXR0b24+CiAgICAgICAg
PGRpdiBpZD0ic2VhcmNoLXdyYXAiPgogICAgICAgICAgICA8YnV0dG9uIGlkPSJidG4tc2VhcmNoIiB0
eXBlPSJidXR0b24iIHRpdGxlPSLmkJzntKIiPgogICAgICAgICAgICAgICAgPHN2ZyB2aWV3Qm94PSIw
IDAgMjQgMjQiIGZpbGw9Im5vbmUiIHN0cm9rZT0iY3VycmVudENvbG9yIiBzdHJva2Utd2lkdGg9IjIi
CiAgICAgICAgICAgICAgICAgICAgIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIgc3Ryb2tlLWxpbmVqb2lu
PSJyb3VuZCI+CiAgICAgICAgICAgICAgICAgICAgPGNpcmNsZSBjeD0iMTEiIGN5PSIxMSIgcj0iNyIv
PgogICAgICAgICAgICAgICAgICAgIDxwYXRoIGQ9Ik0yMCAyMGwtMy41LTMuNSIvPgogICAgICAgICAg
ICAgICAgPC9zdmc+CiAgICAgICAgICAgIDwvYnV0dG9uPgogICAgICAgICAgICA8ZGl2IGlkPSJzZWFy
Y2gtYm94Ij4KICAgICAgICAgICAgICAgIDxidXR0b24gaWQ9ImJ0bi10b2RheSIgdHlwZT0iYnV0dG9u
Ij7lvZPlpKk8L2J1dHRvbj4KICAgICAgICAgICAgICAgIDxpbnB1dCBpZD0ic2VhcmNoIiB0eXBlPSJ0
ZXh0IiBwbGFjZWhvbGRlcj0i5pCc57Si4oCmIOepuuagvOWIhuivjemhu+WQjOaXtuWMheWQqyDCtyBh
fGIg5YiG5q61IiBhdXRvY29tcGxldGU9Im9mZiIgc3BlbGxjaGVjaz0iZmFsc2UiPgogICAgICAgICAg
ICAgICAgPGJ1dHRvbiBpZD0ic2VhcmNoLWNsciIgdHlwZT0iYnV0dG9uIj7inJU8L2J1dHRvbj4KICAg
ICAgICAgICAgPC9kaXY+CiAgICAgICAgPC9kaXY+CiAgICAgICAgPGJ1dHRvbiBpZD0iYnRuLXBpbiIg
dHlwZT0iYnV0dG9uIiB0aXRsZT0i6ZKJ5Zyo5bGP5bmV5LiKIj4KICAgICAgICAgICAgPHN2ZyB2aWV3
Qm94PSIwIDAgMjQgMjQiIGZpbGw9Im5vbmUiIHN0cm9rZT0iY3VycmVudENvbG9yIiBzdHJva2Utd2lk
dGg9IjIiCiAgICAgICAgICAgICAgICAgc3Ryb2tlLWxpbmVqb2luPSJyb3VuZCIgc3Ryb2tlLWxpbmVj
YXA9InJvdW5kIj4KICAgICAgICAgICAgICAgIDxsaW5lIHgxPSIxMiIgeTE9IjE3IiB4Mj0iMTIiIHky
PSIyMiIvPgogICAgICAgICAgICAgICAgPHBhdGggZD0iTTUgMTdoMTR2LTEuNzZhMiAyIDAgMCAwLTEu
MTEtMS43OWwtMS43OC0uOUEyIDIgMCAwIDEgMTUgMTAuNzZWNmgxYTIgMiAwIDAgMCAwLTRIOGEyIDIg
MCAwIDAgMCA0aDF2NC43NmEyIDIgMCAwIDEtMS4xMSAxLjc5bC0xLjc4LjlBMiAyIDAgMCAwIDUgMTUu
MjRaIi8+CiAgICAgICAgICAgIDwvc3ZnPgogICAgICAgIDwvYnV0dG9uPgogICAgPC9kaXY+CgogICAg
PGRpdiBpZD0idGFicyI+CiAgICAgICAgPGRpdiBpZD0idGFiLWluayIgYXJpYS1oaWRkZW49InRydWUi
PjwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9InRhYiBvbiIgZGF0YS10YWI9ImFsbCI+5YWo6YOoPC9k
aXY+CiAgICAgICAgPGRpdiBjbGFzcz0idGFiIiBkYXRhLXRhYj0idGV4dCI+5paH5pysPC9kaXY+CiAg
ICAgICAgPGRpdiBjbGFzcz0idGFiIiBkYXRhLXRhYj0iaW1hZ2UiPuWbvuWDjzwvZGl2PgogICAgICAg
IDxkaXYgY2xhc3M9InRhYiIgZGF0YS10YWI9ImZpbGUiPuaWh+S7tjwvZGl2PgogICAgICAgIDxkaXYg
Y2xhc3M9InRhYiIgZGF0YS10YWI9InBpbm5lZCI+5pS26JePIDxzcGFuIGNsYXNzPSJiYWRnZSIgaWQ9
InBpbi1jbnQiIHN0eWxlPSJkaXNwbGF5Om5vbmUiPjA8L3NwYW4+PC9kaXY+CiAgICAgICAgPGRpdiBp
ZD0idGFiLWFjdGlvbnMiPgogICAgICAgICAgICA8YnV0dG9uIGlkPSJtdWx0aS1jbnQiIHR5cGU9ImJ1
dHRvbiIgdGl0bGU9IuWPlua2iOWkmumAiSI+MDwvYnV0dG9uPgogICAgICAgICAgICA8c3BhbiBpZD0i
YmFyLXR4dCI+MDwvc3Bhbj4KICAgICAgICAgICAgPGJ1dHRvbiBpZD0iYnRuLWNsciIgdHlwZT0iYnV0
dG9uIiB0aXRsZT0i5riF56m65Y6G5Y+yIj4KICAgICAgICAgICAgICAgIDxzdmcgdmlld0JveD0iMCAw
IDI0IDI0IiBmaWxsPSJub25lIiBzdHJva2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIyIgog
ICAgICAgICAgICAgICAgICAgICBzdHJva2UtbGluZWNhcD0icm91bmQiIHN0cm9rZS1saW5lam9pbj0i
cm91bmQiPgogICAgICAgICAgICAgICAgICAgIDxwb2x5bGluZSBwb2ludHM9IjMgNiA1IDYgMjEgNiIv
PgogICAgICAgICAgICAgICAgICAgIDxwYXRoIGQ9Ik0xOSA2bC0xIDE0YTIgMiAwIDAgMS0yIDJIOGEy
IDIgMCAwIDEtMi0yTDUgNiIvPgogICAgICAgICAgICAgICAgICAgIDxwYXRoIGQ9Ik0xMCAxMXY2TTE0
IDExdjZNOSA2VjRoNnYyIi8+CiAgICAgICAgICAgICAgICA8L3N2Zz4KICAgICAgICAgICAgPC9idXR0
b24+CiAgICAgICAgPC9kaXY+CiAgICA8L2Rpdj4KCiAgICA8ZGl2IGlkPSJsaXN0Ij4KICAgICAgICA8
ZGl2IGlkPSJza2VsIiBhcmlhLWhpZGRlbj0idHJ1ZSI+CiAgICAgICAgICAgIDxkaXYgY2xhc3M9InNr
LXJvdyI+PGRpdiBjbGFzcz0ic2staWNvIj48L2Rpdj48ZGl2IGNsYXNzPSJzay1ib2R5Ij48ZGl2IGNs
YXNzPSJzay1saW5lIG1pZCI+PC9kaXY+PGRpdiBjbGFzcz0ic2stbGluZSBzaG9ydCI+PC9kaXY+PC9k
aXY+PC9kaXY+CiAgICAgICAgICAgIDxkaXYgY2xhc3M9InNrLXJvdyI+PGRpdiBjbGFzcz0ic2staWNv
Ij48L2Rpdj48ZGl2IGNsYXNzPSJzay1ib2R5Ij48ZGl2IGNsYXNzPSJzay1saW5lIj48L2Rpdj48ZGl2
IGNsYXNzPSJzay1saW5lIG1pZCI+PC9kaXY+PC9kaXY+PC9kaXY+CiAgICAgICAgICAgIDxkaXYgY2xh
c3M9InNrLXJvdyI+PGRpdiBjbGFzcz0ic2staWNvIj48L2Rpdj48ZGl2IGNsYXNzPSJzay1ib2R5Ij48
ZGl2IGNsYXNzPSJzay1saW5lIG1pZCI+PC9kaXY+PGRpdiBjbGFzcz0ic2stbGluZSBzaG9ydCI+PC9k
aXY+PC9kaXY+PC9kaXY+CiAgICAgICAgICAgIDxkaXYgY2xhc3M9InNrLXJvdyI+PGRpdiBjbGFzcz0i
c2staWNvIj48L2Rpdj48ZGl2IGNsYXNzPSJzay1ib2R5Ij48ZGl2IGNsYXNzPSJzay1saW5lIj48L2Rp
dj48ZGl2IGNsYXNzPSJzay1saW5lIG1pZCI+PC9kaXY+PC9kaXY+PC9kaXY+CiAgICAgICAgICAgIDxk
aXYgY2xhc3M9InNrLXJvdyI+PGRpdiBjbGFzcz0ic2staWNvIj48L2Rpdj48ZGl2IGNsYXNzPSJzay1i
b2R5Ij48ZGl2IGNsYXNzPSJzay1saW5lIG1pZCI+PC9kaXY+PGRpdiBjbGFzcz0ic2stbGluZSBzaG9y
dCI+PC9kaXY+PC9kaXY+PC9kaXY+CiAgICAgICAgICAgIDxkaXYgY2xhc3M9InNrLXJvdyI+PGRpdiBj
bGFzcz0ic2staWNvIj48L2Rpdj48ZGl2IGNsYXNzPSJzay1ib2R5Ij48ZGl2IGNsYXNzPSJzay1saW5l
Ij48L2Rpdj48ZGl2IGNsYXNzPSJzay1saW5lIHNob3J0Ij48L2Rpdj48L2Rpdj48L2Rpdj4KICAgICAg
ICA8L2Rpdj4KICAgICAgICA8ZGl2IGlkPSJlbXB0eSI+CiAgICAgICAgICAgIDxkaXYgY2xhc3M9ImUt
dHh0IiBpZD0iZW1wdHktdHh0Ij7mmoLml6DorrDlvZXvvIzlpI3liLblkI7oh6rliqjlh7rnjrA8L2Rp
dj4KICAgICAgICA8L2Rpdj4KICAgIDwvZGl2PgogICAgPGJ1dHRvbiBpZD0iYnRuLXRvcCIgdHlwZT0i
YnV0dG9uIiB0aXRsZT0i5Zue5Yiw6aG26YOoIiBhcmlhLWxhYmVsPSLlm57liLDpobbpg6giPgogICAg
ICAgIDxzdmcgdmlld0JveD0iMCAwIDI0IDI0IiBmaWxsPSJub25lIiBzdHJva2U9ImN1cnJlbnRDb2xv
ciIgc3Ryb2tlLXdpZHRoPSIyLjIiCiAgICAgICAgICAgICBzdHJva2UtbGluZWNhcD0icm91bmQiIHN0
cm9rZS1saW5lam9pbj0icm91bmQiPgogICAgICAgICAgICA8cGF0aCBkPSJNMTIgMTlWNSIvPgogICAg
ICAgICAgICA8cGF0aCBkPSJNNSAxMmw3LTcgNyA3Ii8+CiAgICAgICAgPC9zdmc+CiAgICA8L2J1dHRv
bj4KPC9kaXY+Cgo8ZGl2IGlkPSJjdHgiPgogICAgPGRpdiBjbGFzcz0iYy1pdGVtIiBpZD0iYy1jb3B5
Ij48c3BhbiBjbGFzcz0iYy1pY28iPuKOmDwvc3Bhbj7lpI3liLY8L2Rpdj4KICAgIDxkaXYgY2xhc3M9
ImMtaXRlbSIgaWQ9ImMtcGFzdGUiPjxzcGFuIGNsYXNzPSJjLWljbyI+4o+OPC9zcGFuPueymOi0tDwv
ZGl2PgogICAgPGRpdiBjbGFzcz0iYy1zZXAiPjwvZGl2PgogICAgPGRpdiBjbGFzcz0iYy1pdGVtIiBp
ZD0iYy1waW4iPjxzcGFuIGNsYXNzPSJjLWljbyI+4piFPC9zcGFuPuaUtuiXjzwvZGl2PgogICAgPGRp
diBjbGFzcz0iYy1pdGVtIiBpZD0iYy10aXRsZSIgc3R5bGU9ImRpc3BsYXk6bm9uZSI+PHNwYW4gY2xh
c3M9ImMtaWNvIj7inI48L3NwYW4+6K6+572u5qCH6aKYPC9kaXY+CiAgICA8ZGl2IGNsYXNzPSJjLWl0
ZW0iIGlkPSJjLW1lcmdlIiBzdHlsZT0iZGlzcGxheTpub25lIj48c3BhbiBjbGFzcz0iYy1pY28iPuKn
iTwvc3Bhbj7lkIjlubY8L2Rpdj4KICAgIDxkaXYgY2xhc3M9ImMtaXRlbSIgaWQ9ImMtdW5tZXJnZSIg
c3R5bGU9ImRpc3BsYXk6bm9uZSI+PHNwYW4gY2xhc3M9ImMtaWNvIj7ih4Q8L3NwYW4+5Y+W5raI5ZCI
5bm2PC9kaXY+CiAgICA8ZGl2IGNsYXNzPSJjLWl0ZW0iIGlkPSJjLXRvcCI+PHNwYW4gY2xhc3M9ImMt
aWNvIj7ihpE8L3NwYW4+56e75Yiw6aG26YOoPC9kaXY+CiAgICA8ZGl2IGNsYXNzPSJjLWl0ZW0iIGlk
PSJjLWNsZWFyLXBhc3RlZCIgc3R5bGU9ImRpc3BsYXk6bm9uZSI+PHNwYW4gY2xhc3M9ImMtaWNvIj7i
nJM8L3NwYW4+5riF6Zmk54q25oCBPC9kaXY+CiAgICA8ZGl2IGNsYXNzPSJjLWl0ZW0iIGlkPSJjLXF1
ZXVlLWZyb20iIHN0eWxlPSJkaXNwbGF5Om5vbmUiPjxzcGFuIGNsYXNzPSJjLWljbyI+4oa7PC9zcGFu
PuS7juatpOWkhOW8gOWni+mYn+WIlzwvZGl2PgogICAgPGRpdiBjbGFzcz0iYy1zZXAiPjwvZGl2Pgog
ICAgPGRpdiBjbGFzcz0iYy1pdGVtIGRhbmdlciIgaWQ9ImMtZGVsIj48c3BhbiBjbGFzcz0iYy1pY28i
PuKclTwvc3Bhbj7liKDpmaQ8L2Rpdj4KPC9kaXY+Cgo8ZGl2IGlkPSJjbHItZGxnIj4KICAgIDxkaXYg
Y2xhc3M9ImNsci1ib3giIHJvbGU9ImRpYWxvZyIgYXJpYS1tb2RhbD0idHJ1ZSI+CiAgICAgICAgPGRp
diBjbGFzcz0iY2xyLXRpdGxlIiBpZD0iY2xyLXRpdGxlIj7noa7orqTmuIXnqbrvvJ88L2Rpdj4KICAg
ICAgICA8ZGl2IGNsYXNzPSJjbHItZGVzYyIgaWQ9ImNsci1kZXNjIj7pu5jorqTku4XmuIXnqbrlvZPl
pKnlhoXlrrnjgII8L2Rpdj4KICAgICAgICA8bGFiZWwgY2xhc3M9ImNsci1jaGVjayIgZm9yPSJjbHIt
YWxsIj4KICAgICAgICAgICAgPGlucHV0IHR5cGU9ImNoZWNrYm94IiBpZD0iY2xyLWFsbCI+CiAgICAg
ICAgICAgIDxzcGFuPua4heepuuaJgOaciTwvc3Bhbj4KICAgICAgICA8L2xhYmVsPgogICAgICAgIDxk
aXYgY2xhc3M9ImNsci1idG5zIj4KICAgICAgICAgICAgPGJ1dHRvbiB0eXBlPSJidXR0b24iIGlkPSJj
bHItY2FuY2VsIj7lj5bmtog8L2J1dHRvbj4KICAgICAgICAgICAgPGJ1dHRvbiB0eXBlPSJidXR0b24i
IGlkPSJjbHItb2siPua4heepujwvYnV0dG9uPgogICAgICAgIDwvZGl2PgogICAgPC9kaXY+CjwvZGl2
PgoKPGRpdiBpZD0idGl0bGUtZGxnIj4KICAgIDxkaXYgY2xhc3M9InRpdGxlLWJveCIgcm9sZT0iZGlh
bG9nIiBhcmlhLW1vZGFsPSJ0cnVlIj4KICAgICAgICA8ZGl2IGNsYXNzPSJjbHItdGl0bGUiPuiuvue9
ruagh+mimDwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9ImNsci1kZXNjIj7moIfpopjlj6/ooqvmkJzn
tKLmib7liLDvvIzku4XnlKjkuo7mlLbol4/mlbTnkIbjgII8L2Rpdj4KICAgICAgICA8aW5wdXQgaWQ9
InRpdGxlLWlucHV0IiB0eXBlPSJ0ZXh0IiBtYXhsZW5ndGg9IjgwIiBwbGFjZWhvbGRlcj0i57uZ6L+Z
5p2h5pS26JeP6LW35Liq5ZCN5a2X4oCmIiBhdXRvY29tcGxldGU9Im9mZiIgc3BlbGxjaGVjaz0iZmFs
c2UiPgogICAgICAgIDxkaXYgY2xhc3M9ImNsci1idG5zIj4KICAgICAgICAgICAgPGJ1dHRvbiB0eXBl
PSJidXR0b24iIGlkPSJ0aXRsZS1jYW5jZWwiPuWPlua2iDwvYnV0dG9uPgogICAgICAgICAgICA8YnV0
dG9uIHR5cGU9ImJ1dHRvbiIgaWQ9InRpdGxlLW9rIj7kv53lrZg8L2J1dHRvbj4KICAgICAgICA8L2Rp
dj4KICAgIDwvZGl2Pgo8L2Rpdj4KPGRpdiBpZD0icGF0aC10aXAiIGFyaWEtaGlkZGVuPSJ0cnVlIj48
L2Rpdj4KCjxzY3JpcHQ+Ci8qIHNrZWwtZmFpbHNhZmU6IG9ubHkgaWYgbWFpbiBVSSBzY3JpcHQgbmV2
ZXIgYm9vdGVkIOKAlG5ldmVyIGludmVudCBlbXB0eS1zdGF0ZSAqLwooZnVuY3Rpb24oKXsKICBzZXRU
aW1lb3V0KCgpID0+IHsKICAgIHRyeSB7CiAgICAgIGlmICh3aW5kb3cuX191aUJvb3RlZCkgcmV0dXJu
OwogICAgICB2YXIgYXBwID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2FwcCcpOwogICAgICBpZiAo
YXBwKSBhcHAuY2xhc3NMaXN0LnJlbW92ZSgnYm9vdC1sb2FkaW5nJyk7CiAgICAgIHZhciBzID0gZG9j
dW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NrZWwnKTsKICAgICAgaWYgKHMpIHMuY2xhc3NMaXN0LnJlbW92
ZSgnb24nKTsKICAgIH0gY2F0Y2ggKGVycikge30KICB9LCAzMDAwKTsKfSkoKTsKPC9zY3JpcHQ+Cjxz
Y3JpcHQ+CiAgICBsZXQgYWxsQ2xpcHMgPSBbXSwgY3VyVGFiID0gJ2FsbCcsIHF1ZXJ5ID0gJycsIGN0
eENsaXAgPSBudWxsLCBzZWxlY3RlZElkID0gMCwgcGlubmVkVUkgPSBmYWxzZTsKICAgIGNvbnN0IFRB
Ql9PUkRFUiA9IFsnYWxsJywgJ3RleHQnLCAnaW1hZ2UnLCAnZmlsZScsICdwaW5uZWQnXTsKICAgIGNv
bnN0IHZpZXdNZW0gPSBuZXcgTWFwKCk7CiAgICBmdW5jdGlvbiB2aWV3TWVtS2V5KHRhYiwgcSwgdG9k
YXkpIHsKICAgICAgICByZXR1cm4gU3RyaW5nKHRhYiB8fCAnYWxsJykgKyAnXHQnICsgU3RyaW5nKHEg
fHwgJycpICsgJ1x0JyArICh0b2RheSA/ICcxJyA6ICcwJyk7CiAgICB9CiAgICBsZXQgdGFiU3dpdGNo
QW5pbURpciA9IDA7CiAgICBsZXQgbXVsdGlJZHMgPSBbXTsKICAgIGxldCB0b2RheU9ubHkgPSBmYWxz
ZTsKICAgIGxldCBkaXNrVG90YWwgPSAwOwogICAgbGV0IGxvYWRpbmdNb3JlID0gZmFsc2U7CiAgICAv
LyBEb24ndCBzaG93IHNrZWxldG9uIGltbWVkaWF0ZWx5IOKAlG9ubHkgYWZ0ZXIgU0tFTF9ERUxBWV9N
UyBpZiBkYXRhIHN0aWxsIG1pc3NpbmcKICAgIGxldCBib290TG9hZGluZyA9IGZhbHNlOwogICAgbGV0
IHdhaXRpbmdEYXRhID0gZmFsc2U7CiAgICBsZXQgaG9zdFB1c2hlZE9uY2UgPSBmYWxzZTsgLy8gb25s
eSB0aGVuIG1heSBzaG9344CM5pqC5peg6K6w5b2V44CNCiAgICBsZXQgc2F3Tm9uRW1wdHkgPSBmYWxz
ZTsgICAgLy8gaWdub3JlIGJvb3RzdHJhcCBlbXB0eSBwdXNoZXMgYmVmb3JlIGZpcnN0IHJlYWwgbGlz
dAogICAgbGV0IHBpbm5lZFRvdGFsID0gMDsgICAgICAgIC8vIGF1dGhvcml0YXRpdmUg5pS26JePIGNv
dW50IGZyb20gQUhLCiAgICBjb25zdCBTS0VMX0RFTEFZX01TID0gNjA7CiAgICB3aW5kb3cuX19kYXRh
UmVhZHkgPSBmYWxzZTsKICAgIHdpbmRvdy5fX3VpQm9vdGVkID0gdHJ1ZTsKICAgIC8vIE9wZW4gcGFu
ZWwgd2l0aG91dCBwYXN0aW5nIOKGkiBhbHdheXMgbGFuZCBvbiBmaXJzdCBpdGVtIChhZnRlciBkYXRh
IGFycml2ZXMpCiAgICBsZXQgc2VsZWN0Rmlyc3RPblNob3cgPSBmYWxzZTsKICAgIGxldCBsYXN0UGFz
dGVJZCA9IDA7CiAgICBsZXQgbGFzdFBhc3RlVGFiID0gJ2FsbCc7CiAgICBsZXQgbG9jYXRlQWN0aXZl
ID0gZmFsc2U7CiAgICB0cnkgeyBsYXN0UGFzdGVJZCA9ICtsb2NhbFN0b3JhZ2UuZ2V0SXRlbSgnY2xp
cExhc3RQYXN0ZUlkJykgfHwgMDsgfSBjYXRjaCB7fQogICAgdHJ5IHsKICAgICAgICBjb25zdCB0ID0g
bG9jYWxTdG9yYWdlLmdldEl0ZW0oJ2NsaXBMYXN0UGFzdGVUYWInKSB8fCAnYWxsJzsKICAgICAgICBs
YXN0UGFzdGVUYWIgPSBbJ2FsbCcsJ3RleHQnLCdpbWFnZScsJ2ZpbGUnLCdwaW5uZWQnXS5pbmNsdWRl
cyh0KSA/IHQgOiAnYWxsJzsKICAgIH0gY2F0Y2gge30KICAgIC8vIFByZWZlciBzYW1lLW9yaWdpbiB1
bmRlciBjbGlwdWkubG9jYWwgKEFQUF9IT1NUIOKGkiBDTElQX1YxX0RJUi9jbGlwc19zdG9yZSkuCiAg
ICAvLyBjbGlwcy5zdG9yZSBpcyBhIGRlZGljYXRlZCBtYXBwaW5nIGZhbGxiYWNrIHdoZW4gc2FtZS1v
cmlnaW4gZmFpbHMuCiAgICBjb25zdCBTVE9SRV9CQVNFID0gKGxvY2F0aW9uLm9yaWdpbiAmJiBsb2Nh
dGlvbi5vcmlnaW4uaW5kZXhPZignaHR0cHM6Ly8nKSA9PT0gMCkKICAgICAgICA/IChsb2NhdGlvbi5v
cmlnaW4ucmVwbGFjZSgvXC8kLywgJycpICsgJy9jbGlwc19zdG9yZS8nKQogICAgICAgIDogJ2h0dHBz
Oi8vY2xpcHVpLmxvY2FsL2NsaXBzX3N0b3JlLyc7CiAgICBjb25zdCBTVE9SRV9CQVNFX0ZBTExCQUNL
ID0gJ2h0dHBzOi8vY2xpcHMuc3RvcmUvJzsKICAgIGZ1bmN0aW9uIG1ldGFDZW50ZXJIdG1sKGV4cGFu
ZElubmVyKSB7CiAgICAgICAgaWYgKGV4cGFuZElubmVyID09IG51bGwgfHwgZXhwYW5kSW5uZXIgPT09
IGZhbHNlKQogICAgICAgICAgICByZXR1cm4gYDxzcGFuIGNsYXNzPSJpLW1ldGEtY2VudGVyIj48L3Nw
YW4+YDsKICAgICAgICByZXR1cm4gYDxzcGFuIGNsYXNzPSJpLW1ldGEtY2VudGVyIj48YnV0dG9uIGNs
YXNzPSJpLWV4cGFuZC1idG4ke2V4cGFuZElubmVyLm9uID8gJyBvbicgOiAnJ30iIHR5cGU9ImJ1dHRv
biIgdGl0bGU9IuWxleW8gC/mlLbotbciPiR7ZXhwYW5kSW5uZXIuaHRtbH08L2J1dHRvbj48L3NwYW4+
YDsKICAgIH0KCiAgICBmdW5jdGlvbiByZW1lbWJlckxhc3RQYXN0ZShpZCkgewogICAgICAgIGxhc3RQ
YXN0ZUlkID0gK2lkIHx8IDA7CiAgICAgICAgbGFzdFBhc3RlVGFiID0gY3VyVGFiIHx8ICdhbGwnOwog
ICAgICAgIHRyeSB7CiAgICAgICAgICAgIGxvY2FsU3RvcmFnZS5zZXRJdGVtKCdjbGlwTGFzdFBhc3Rl
SWQnLCBTdHJpbmcobGFzdFBhc3RlSWQpKTsKICAgICAgICAgICAgbG9jYWxTdG9yYWdlLnNldEl0ZW0o
J2NsaXBMYXN0UGFzdGVUYWInLCBsYXN0UGFzdGVUYWIpOwogICAgICAgIH0gY2F0Y2gge30KICAgICAg
ICB1cGRhdGVMb2NhdGVCdG4oKTsKICAgIH0KICAgIGZ1bmN0aW9uIHVwZGF0ZUxvY2F0ZUJ0bigpIHsK
ICAgICAgICBjb25zdCBidG4gPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYnRuLWxvY2F0ZScpOwog
ICAgICAgIGlmICghYnRuKSByZXR1cm47CiAgICAgICAgYnRuLmRpc2FibGVkID0gIWxhc3RQYXN0ZUlk
OwogICAgICAgIGJ0bi5jbGFzc0xpc3QudG9nZ2xlKCdoYXMtdGFyZ2V0JywgISFsYXN0UGFzdGVJZCk7
CiAgICAgICAgYnRuLmNsYXNzTGlzdC50b2dnbGUoJ29uJywgbG9jYXRlQWN0aXZlICYmICEhbGFzdFBh
c3RlSWQpOwogICAgICAgIGJ0bi50aXRsZSA9ICFsYXN0UGFzdGVJZAogICAgICAgICAgICA/ICfmmoLm
l6DkuIrmrKHkvb/nlKjkvY3nva4nCiAgICAgICAgICAgIDogKGxvY2F0ZUFjdGl2ZSA/ICflj5bmtojl
rprkvY3vvIzlm57liLDnrKzkuIDmnaEnIDogJ+WumuS9jeWIsOS4iuasoeS9v+eUqOeahOadoeebricp
OwogICAgfQogICAgZnVuY3Rpb24gc2VsZWN0Rmlyc3RJdGVtKCkgewogICAgICAgIGxvY2F0ZUFjdGl2
ZSA9IGZhbHNlOwogICAgICAgIHdpbmRvdy5fX3BlbmRpbmdKdW1wSWQgPSAwOwogICAgICAgIHdpbmRv
dy5fX2p1bXBMb2FkVHJpZXMgPSAwOwogICAgICAgIHNlbGVjdEZpcnN0T25TaG93ID0gZmFsc2U7CiAg
ICAgICAgY29uc3QgdmlzID0gdmlzaWJsZUxpc3QoKTsKICAgICAgICBpZiAoIXZpcy5sZW5ndGgpIHsK
ICAgICAgICAgICAgc2VsZWN0ZWRJZCA9IDA7CiAgICAgICAgICAgIHN5bmNJdGVtSGlnaGxpZ2h0KCk7
CiAgICAgICAgICAgIHVwZGF0ZUxvY2F0ZUJ0bigpOwogICAgICAgICAgICByZXR1cm47CiAgICAgICAg
fQogICAgICAgIHNlbGVjdGVkSWQgPSB2aXNbMF0uaWQ7CiAgICAgICAgcmFuZ2VBbmNob3JJZCA9IHNl
bGVjdGVkSWQ7CiAgICAgICAgcmFuZ2VBbmNob3JDbGlja2VkID0gZmFsc2U7CiAgICAgICAgbGlzdEVs
LnNjcm9sbFRvcCA9IDA7CiAgICAgICAgc3luY0l0ZW1IaWdobGlnaHQoKTsKICAgICAgICBjb25zdCBl
bCA9IGxpc3RFbC5xdWVyeVNlbGVjdG9yKCcuaXRtW2RhdGEtaWQ9IicgKyBzZWxlY3RlZElkICsgJyJd
Jyk7CiAgICAgICAgaWYgKGVsKSBlbC5zY3JvbGxJbnRvVmlldyh7IGJsb2NrOiAnbmVhcmVzdCcgfSk7
CiAgICAgICAgdXBkYXRlTG9jYXRlQnRuKCk7CiAgICB9CiAgICBmdW5jdGlvbiBqdW1wVG9MYXN0UGFz
dGUoKSB7CiAgICAgICAgaWYgKCFsYXN0UGFzdGVJZCkgcmV0dXJuOwogICAgICAgIC8vIEFscmVhZHkg
bG9jYXRlZCBvbiBsYXN0IHBhc3RlIOKGkiBjYW5jZWwgYW5kIHNlbGVjdCBmaXJzdAogICAgICAgIGlm
IChsb2NhdGVBY3RpdmUgJiYgK3NlbGVjdGVkSWQgPT09ICtsYXN0UGFzdGVJZCkgewogICAgICAgICAg
ICBzZWxlY3RGaXJzdEl0ZW0oKTsKICAgICAgICAgICAgcmV0dXJuOwogICAgICAgIH0KICAgICAgICBs
b2NhdGVBY3RpdmUgPSB0cnVlOwogICAgICAgIHNlbGVjdEZpcnN0T25TaG93ID0gZmFsc2U7CiAgICAg
ICAgLy8gQ2xlYXIgZmlsdGVycyBzbyB0aGUgaXRlbSBpcyBmaW5kYWJsZSBvbiB0aGUgdGFiIHdoZXJl
IGl0IHdhcyB1c2VkCiAgICAgICAgcXVlcnkgPSAnJzsKICAgICAgICB0b2RheU9ubHkgPSBmYWxzZTsK
ICAgICAgICB0cnkgewogICAgICAgICAgICBjb25zdCBzcmNoID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5
SWQoJ3NlYXJjaCcpOwogICAgICAgICAgICBjb25zdCBzY2xyID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5
SWQoJ3NlYXJjaC1jbHInKTsKICAgICAgICAgICAgY29uc3Qgd3JhcCA9IGRvY3VtZW50LmdldEVsZW1l
bnRCeUlkKCdzZWFyY2gtd3JhcCcpOwogICAgICAgICAgICBjb25zdCBidG5Ub2RheSA9IGRvY3VtZW50
LmdldEVsZW1lbnRCeUlkKCdidG4tdG9kYXknKTsKICAgICAgICAgICAgaWYgKHNyY2gpIHsgc3JjaC52
YWx1ZSA9ICcnOyBzcmNoLmNsYXNzTGlzdC5yZW1vdmUoJ2hhcy12YWwnKTsgfQogICAgICAgICAgICBp
ZiAoc2Nscikgc2Nsci5zdHlsZS5kaXNwbGF5ID0gJ25vbmUnOwogICAgICAgICAgICBpZiAod3JhcCkg
d3JhcC5jbGFzc0xpc3QucmVtb3ZlKCdvcGVuJyk7CiAgICAgICAgICAgIGlmIChidG5Ub2RheSkgYnRu
VG9kYXkuY2xhc3NMaXN0LnJlbW92ZSgnb24nKTsKICAgICAgICB9IGNhdGNoIHt9CiAgICAgICAgY29u
c3QgdGFiID0gWydhbGwnLCd0ZXh0JywnaW1hZ2UnLCdmaWxlJywncGlubmVkJ10uaW5jbHVkZXMobGFz
dFBhc3RlVGFiKQogICAgICAgICAgICA/IGxhc3RQYXN0ZVRhYiA6ICdhbGwnOwogICAgICAgIGNvbnN0
IHByZXZUYWIgPSBjdXJUYWI7CiAgICAgICAgY3VyVGFiID0gdGFiOwogICAgICAgIGxvYWRpbmdNb3Jl
ID0gZmFsc2U7CiAgICAgICAgbWFya1RhYih0YWIpOwogICAgICAgIGNsZWFyTXVsdGkoKTsKICAgICAg
ICBzZWxlY3RlZElkID0gbGFzdFBhc3RlSWQ7CiAgICAgICAgd2luZG93Ll9fcGVuZGluZ0p1bXBJZCA9
IGxhc3RQYXN0ZUlkOwogICAgICAgIHdpbmRvdy5fX2p1bXBMb2FkVHJpZXMgPSAwOwogICAgICAgIHdp
bmRvdy5fX2p1bXBGZWxsQmFjayA9IGZhbHNlOwogICAgICAgIHVwZGF0ZUxvY2F0ZUJ0bigpOwogICAg
ICAgIHJlcXVlc3RWaWV3KCk7CiAgICB9CgogICAgZnVuY3Rpb24gcmVxdWVzdFZpZXcoKSB7CiAgICAg
ICAgY29uc3QgdGFiID0gY3VyVGFiLCBxID0gcXVlcnksIHRvZGF5ID0gdG9kYXlPbmx5ID8gJzEnIDog
JzAnOwogICAgICAgIGlmICh3aW5kb3cuX192aWV3UmFmKSBjYW5jZWxBbmltYXRpb25GcmFtZSh3aW5k
b3cuX192aWV3UmFmKTsKICAgICAgICB3aW5kb3cuX192aWV3UmFmID0gcmVxdWVzdEFuaW1hdGlvbkZy
YW1lKCgpID0+IHsKICAgICAgICAgICAgd2luZG93Ll9fdmlld1JhZiA9IDA7CiAgICAgICAgICAgIHNl
dFRpbWVvdXQoKCkgPT4gYWhrKCdzZXRWaWV3JywgdGFiLCBxLCB0b2RheSksIDApOwogICAgICAgIH0p
OwogICAgfQogICAgLyoqIERlYm91bmNlZCBBSEsgc3luYyBhZnRlciB2aWV3TWVtIGluc3RhbnQgcGFp
bnQg4oCUYXZvaWRzIHRhYi1zd2l0Y2ggZG91YmxlIFB1c2hDbGlwcyAqLwogICAgZnVuY3Rpb24gc29m
dFJlcXVlc3RWaWV3KCkgewogICAgICAgIGlmICh3aW5kb3cuX19zb2Z0Vmlld1QpIGNsZWFyVGltZW91
dCh3aW5kb3cuX19zb2Z0Vmlld1QpOwogICAgICAgIHdpbmRvdy5fX3NvZnRWaWV3VCA9IHNldFRpbWVv
dXQoKCkgPT4gewogICAgICAgICAgICB3aW5kb3cuX19zb2Z0Vmlld1QgPSAwOwogICAgICAgICAgICBy
ZXF1ZXN0VmlldygpOwogICAgICAgIH0sIDMyMCk7CiAgICB9CiAgICBmdW5jdGlvbiByZXF1ZXN0TW9y
ZShmb3JjZSA9IGZhbHNlKSB7CiAgICAgICAgaWYgKGRpc2tUb3RhbCA+IDAgJiYgYWxsQ2xpcHMubGVu
Z3RoID49IGRpc2tUb3RhbCkgcmV0dXJuOwogICAgICAgIC8vIExvY2F0ZSAvIGp1bXAgbXVzdCBub3Qg
d2FpdCBvbiBzY3JvbGwtaWRsZSBvciBhIHN0dWNrIGxvYWRpbmdNb3JlIGZsYWcKICAgICAgICBpZiAo
IWZvcmNlKSB7CiAgICAgICAgICAgIGlmIChsb2FkaW5nTW9yZSkgcmV0dXJuOwogICAgICAgICAgICBp
ZiAod2luZG93Ll9fc2Nyb2xsQnVzeSB8fCBfbGlzdFB0ckRvd24pIHsKICAgICAgICAgICAgICAgIHdp
bmRvdy5fX3dhbnRNb3JlID0gdHJ1ZTsKICAgICAgICAgICAgICAgIHJldHVybjsKICAgICAgICAgICAg
fQogICAgICAgIH0gZWxzZSB7CiAgICAgICAgICAgIGxvYWRpbmdNb3JlID0gZmFsc2U7CiAgICAgICAg
ICAgIHdpbmRvdy5fX3Njcm9sbEJ1c3kgPSBmYWxzZTsKICAgICAgICAgICAgd2luZG93Ll9fd2FudE1v
cmUgPSBmYWxzZTsKICAgICAgICAgICAgX2xpc3RQdHJEb3duID0gZmFsc2U7CiAgICAgICAgICAgIHRy
eSB7IGxpc3RFbC5jbGFzc0xpc3QucmVtb3ZlKCdpcy1zY3JvbGxpbmcnKTsgfSBjYXRjaCB7fQogICAg
ICAgIH0KICAgICAgICBpZiAobG9hZGluZ01vcmUpIHJldHVybjsKICAgICAgICBsb2FkaW5nTW9yZSA9
IHRydWU7CiAgICAgICAgd2luZG93Ll9fd2FudE1vcmUgPSBmYWxzZTsKICAgICAgICBpZiAod2luZG93
Ll9fbG9hZE1vcmVXYXRjaCkgY2xlYXJUaW1lb3V0KHdpbmRvdy5fX2xvYWRNb3JlV2F0Y2gpOwogICAg
ICAgIHdpbmRvdy5fX2xvYWRNb3JlV2F0Y2ggPSBzZXRUaW1lb3V0KCgpID0+IHsKICAgICAgICAgICAg
d2luZG93Ll9fbG9hZE1vcmVXYXRjaCA9IDA7CiAgICAgICAgICAgIGlmIChsb2FkaW5nTW9yZSkgewog
ICAgICAgICAgICAgICAgbG9hZGluZ01vcmUgPSBmYWxzZTsKICAgICAgICAgICAgICAgIGlmICh3aW5k
b3cuX19wZW5kaW5nSnVtcElkKSB0cnlDb250aW51ZUp1bXAoKTsKICAgICAgICAgICAgfQogICAgICAg
IH0sIDE4MDApOwogICAgICAgIGFoaygnbG9hZE1vcmUnKTsKICAgIH0KCiAgICBmdW5jdGlvbiB0cnlD
b250aW51ZUp1bXAoKSB7CiAgICAgICAgY29uc3QgamlkID0gK3dpbmRvdy5fX3BlbmRpbmdKdW1wSWQ7
CiAgICAgICAgaWYgKCFqaWQpIHJldHVybjsKICAgICAgICBpZiAoX3BlbmRpbmdBcHBlbmQpIHsKICAg
ICAgICAgICAgY29uc3QgcGVuZGluZyA9IF9wZW5kaW5nQXBwZW5kOwogICAgICAgICAgICBfcGVuZGlu
Z0FwcGVuZCA9IG51bGw7CiAgICAgICAgICAgIGFwcGx5QXBwZW5kUGF5bG9hZChwZW5kaW5nKTsKICAg
ICAgICB9CiAgICAgICAgY29uc3QgZWwgPSBsaXN0RWwucXVlcnlTZWxlY3RvcignLm1nLXJvd1tkYXRh
LWlkPSInICsgamlkICsgJyJdJykgfHwgbGlzdEVsLnF1ZXJ5U2VsZWN0b3IoJy5pdG1bZGF0YS1pZD0i
JyArIGppZCArICciXScpOwogICAgICAgIGlmIChlbCkgewogICAgICAgICAgICB3aW5kb3cuX19wZW5k
aW5nSnVtcElkID0gMDsKICAgICAgICAgICAgd2luZG93Ll9fanVtcExvYWRUcmllcyA9IDA7CiAgICAg
ICAgICAgIHNlbGVjdGVkSWQgPSBqaWQ7CiAgICAgICAgICAgIGxvY2F0ZUFjdGl2ZSA9IHRydWU7CiAg
ICAgICAgICAgIHVwZGF0ZUxvY2F0ZUJ0bigpOwogICAgICAgICAgICByZXF1ZXN0QW5pbWF0aW9uRnJh
bWUoKCkgPT4gewogICAgICAgICAgICAgICAgY29uc3Qgbm9kZSA9IGxpc3RFbC5xdWVyeVNlbGVjdG9y
KCcubWctcm93W2RhdGEtaWQ9IicgKyBqaWQgKyAnIl0nKSB8fCBsaXN0RWwucXVlcnlTZWxlY3Rvcign
Lml0bVtkYXRhLWlkPSInICsgamlkICsgJyJdJyk7CiAgICAgICAgICAgICAgICBpZiAoIW5vZGUpIHJl
dHVybjsKICAgICAgICAgICAgICAgIG5vZGUuc2Nyb2xsSW50b1ZpZXcoeyBibG9jazogJ2NlbnRlcicg
fSk7CiAgICAgICAgICAgICAgICBub2RlLmNsYXNzTGlzdC5hZGQoJ2p1bXAtZmxhc2gnKTsKICAgICAg
ICAgICAgICAgIHNldFRpbWVvdXQoKCkgPT4gbm9kZS5jbGFzc0xpc3QucmVtb3ZlKCdqdW1wLWZsYXNo
JyksIDkwMCk7CiAgICAgICAgICAgICAgICBzeW5jSXRlbUhpZ2hsaWdodCgpOwogICAgICAgICAgICB9
KTsKICAgICAgICAgICAgcmV0dXJuOwogICAgICAgIH0KICAgICAgICBpZiAoYWxsQ2xpcHMuc29tZShj
ID0+ICtjLmlkID09PSBqaWQpKSB7CiAgICAgICAgICAgIHJlbmRlcigpOwogICAgICAgICAgICByZXF1
ZXN0QW5pbWF0aW9uRnJhbWUoKCkgPT4gdHJ5Q29udGludWVKdW1wKCkpOwogICAgICAgICAgICByZXR1
cm47CiAgICAgICAgfQogICAgICAgIGlmIChhbGxDbGlwcy5sZW5ndGggPCBkaXNrVG90YWwgJiYgKHdp
bmRvdy5fX2p1bXBMb2FkVHJpZXMgfHwgMCkgPCA4MCkgewogICAgICAgICAgICB3aW5kb3cuX19qdW1w
TG9hZFRyaWVzID0gKHdpbmRvdy5fX2p1bXBMb2FkVHJpZXMgfHwgMCkgKyAxOwogICAgICAgICAgICBy
ZXF1ZXN0TW9yZSh0cnVlKTsKICAgICAgICAgICAgcmV0dXJuOwogICAgICAgIH0KICAgICAgICB3aW5k
b3cuX19wZW5kaW5nSnVtcElkID0gMDsKICAgICAgICB3aW5kb3cuX19qdW1wTG9hZFRyaWVzID0gMDsK
ICAgIH0KICAgIGNvbnN0IEVNUFRZX01TRyA9IHsKICAgICAgICBhbGw6ICAgICfmmoLml6DorrDlvZXv
vIzlpI3liLblkI7oh6rliqjlh7rnjrAnLAogICAgICAgIHRleHQ6ICAgJ+aaguaXoOaWh+acrCcsCiAg
ICAgICAgaW1hZ2U6ICAn5pqC5peg5Zu+5YOPJywKICAgICAgICBmaWxlOiAgICfmmoLml6Dmlofku7Yn
LAogICAgICAgIHBpbm5lZDogJ+aaguaXoOaUtuiXjycKICAgIH07CgogICAgZnVuY3Rpb24gYWhrSW52
b2tlKG1ldGhvZCwgYXJncykgewogICAgICAgIHRyeSB7CiAgICAgICAgICAgIGNvbnN0IGhvc3QgPSBj
aHJvbWUud2Vidmlldy5ob3N0T2JqZWN0cy5zeW5jLmFoazsKICAgICAgICAgICAgaWYgKCFob3N0KSBy
ZXR1cm47CiAgICAgICAgICAgIGxldCBjYWxsZWQgPSBmYWxzZTsKICAgICAgICAgICAgaWYgKHR5cGVv
ZiBob3N0LmNhbGwgPT09ICdmdW5jdGlvbicpIHsKICAgICAgICAgICAgICAgIHRyeSB7IGhvc3QuY2Fs
bChtZXRob2QsIC4uLmFyZ3MpOyBjYWxsZWQgPSB0cnVlOyB9IGNhdGNoIHt9CiAgICAgICAgICAgIH0K
ICAgICAgICAgICAgaWYgKCFjYWxsZWQgJiYgdHlwZW9mIGhvc3RbbWV0aG9kXSA9PT0gJ2Z1bmN0aW9u
JykgewogICAgICAgICAgICAgICAgdHJ5IHsgaG9zdFttZXRob2RdKC4uLmFyZ3MpOyBjYWxsZWQgPSB0
cnVlOyB9IGNhdGNoIHt9CiAgICAgICAgICAgICAgICBpZiAoIWNhbGxlZCkgewogICAgICAgICAgICAg
ICAgICAgIHRyeSB7IGhvc3RbbWV0aG9kXSguLi5hcmdzKTsgY2FsbGVkID0gdHJ1ZTsgfSBjYXRjaCB7
fQogICAgICAgICAgICAgICAgfQogICAgICAgICAgICB9CiAgICAgICAgICAgIGlmICghY2FsbGVkICYm
IGhvc3RbbWV0aG9kXSAhPSBudWxsICYmIHR5cGVvZiBob3N0W21ldGhvZF0gIT09ICdmdW5jdGlvbicp
IHsKICAgICAgICAgICAgICAgIHRyeSB7IHZvaWQgaG9zdFttZXRob2RdOyB9IGNhdGNoIHt9CiAgICAg
ICAgICAgIH0KICAgICAgICB9IGNhdGNoIChlKSB7IGNvbnNvbGUud2FybignYWhrLicgKyBtZXRob2Qs
IGUpOyB9CiAgICB9CiAgICBmdW5jdGlvbiBhaGsobWV0aG9kLCAuLi5hcmdzKSB7CiAgICAgICAgYWhr
SW52b2tlKG1ldGhvZCwgYXJncyk7CiAgICB9CiAgICBmdW5jdGlvbiBhaGtSZXQobWV0aG9kLCAuLi5h
cmdzKSB7CiAgICAgICAgdHJ5IHsKICAgICAgICAgICAgY29uc3QgaG9zdCA9IGNocm9tZS53ZWJ2aWV3
Lmhvc3RPYmplY3RzLnN5bmMuYWhrOwogICAgICAgICAgICBpZiAoIWhvc3QpIHJldHVybiBudWxsOwog
ICAgICAgICAgICBsZXQgcmV0ID0gbnVsbDsKICAgICAgICAgICAgaWYgKHR5cGVvZiBob3N0LmNhbGwg
PT09ICdmdW5jdGlvbicpIHsKICAgICAgICAgICAgICAgIHRyeSB7IHJldCA9IGhvc3QuY2FsbChtZXRo
b2QsIC4uLmFyZ3MpOyB9IGNhdGNoIHt9CiAgICAgICAgICAgIH0KICAgICAgICAgICAgaWYgKHJldCA9
PSBudWxsICYmIHR5cGVvZiBob3N0W21ldGhvZF0gPT09ICdmdW5jdGlvbicpIHsKICAgICAgICAgICAg
ICAgIHRyeSB7IHJldCA9IGhvc3RbbWV0aG9kXSguLi5hcmdzKTsgfSBjYXRjaCB7fQogICAgICAgICAg
ICAgICAgaWYgKHJldCA9PSBudWxsKSB7CiAgICAgICAgICAgICAgICAgICAgdHJ5IHsgcmV0ID0gaG9z
dFttZXRob2RdKC4uLmFyZ3MpOyB9IGNhdGNoIHt9CiAgICAgICAgICAgICAgICB9CiAgICAgICAgICAg
IH0KICAgICAgICAgICAgaWYgKHJldCA9PSBudWxsICYmIGhvc3RbbWV0aG9kXSAhPSBudWxsICYmIHR5
cGVvZiBob3N0W21ldGhvZF0gIT09ICdmdW5jdGlvbicpCiAgICAgICAgICAgICAgICByZXQgPSBob3N0
W21ldGhvZF07CiAgICAgICAgICAgIGlmIChyZXQgPT0gbnVsbCkgcmV0dXJuIG51bGw7CiAgICAgICAg
ICAgIGlmICh0eXBlb2YgcmV0ID09PSAnc3RyaW5nJyB8fCB0eXBlb2YgcmV0ID09PSAnbnVtYmVyJyB8
fCB0eXBlb2YgcmV0ID09PSAnYm9vbGVhbicpCiAgICAgICAgICAgICAgICByZXR1cm4gcmV0OwogICAg
ICAgICAgICB0cnkgeyByZXR1cm4gU3RyaW5nKHJldCk7IH0gY2F0Y2ggeyByZXR1cm4gcmV0OyB9CiAg
ICAgICAgfSBjYXRjaCAoZSkgeyBjb25zb2xlLndhcm4oJ2Foa1JldC4nICsgbWV0aG9kLCBlKTsgfQog
ICAgICAgIHJldHVybiBudWxsOwogICAgfQoKICAgIC8vIEVhcmx5IEFISyBfX3NldFRodW1iIGNhbiBh
cnJpdmUgYmVmb3JlIERPTSBub2RlcyBleGlzdCDigJQga2VlcCB1bnRpbCBiaW5kCiAgICBjb25zdCB0
aHVtYkNhY2hlID0gbmV3IE1hcCgpOwoKICAgIC8qKiBQcmVmZXIgY2FjaGUgLyBkYXRhLVVSTCwgdGhl
biB0aF8qLmpwZyB2aWEgdmlydHVhbCBob3N0LCB0aGVuIG9yaWdpbmFsICovCiAgICBmdW5jdGlvbiBi
aW5kU3RvcmVUaHVtYihpbWcsIGZpbGUsIGlkLCBmYWxsYmFjaykgewogICAgICAgIGltZy5kYXRhc2V0
LnRodW1iSWQgPSBTdHJpbmcoaWQpOwogICAgICAgIGltZy5hbHQgPSAnJzsKICAgICAgICBpbWcuY2xh
c3NMaXN0LmFkZCgndGh1bWItbG9hZGluZycpOwogICAgICAgIGNvbnN0IHdyYXAgPSBpbWcucGFyZW50
RWxlbWVudDsKICAgICAgICBpZiAod3JhcCAmJiB3cmFwLmNsYXNzTGlzdC5jb250YWlucygnaS10aHVt
Yi13cmFwJykpCiAgICAgICAgICAgIHdyYXAuY2xhc3NMaXN0LmFkZCgnd2FpdGluZycpOwogICAgICAg
IGNvbnN0IGNsZWFyV2FpdCA9ICgpID0+IHsKICAgICAgICAgICAgaW1nLmNsYXNzTGlzdC5yZW1vdmUo
J3RodW1iLWxvYWRpbmcnKTsKICAgICAgICAgICAgaWYgKHdyYXApIHdyYXAuY2xhc3NMaXN0LnJlbW92
ZSgnd2FpdGluZycpOwogICAgICAgICAgICBpZiAoaW1nLl9mYWlsVGltZXIpIHRyeSB7IGNsZWFyVGlt
ZW91dChpbWcuX2ZhaWxUaW1lcik7IH0gY2F0Y2gge30KICAgICAgICB9OwogICAgICAgIGNvbnN0IGZh
aWxUaW1lciA9IHNldFRpbWVvdXQoKCkgPT4gewogICAgICAgICAgICBpZiAoIWltZy5zcmMgfHwgaW1n
Lm5hdHVyYWxXaWR0aCA8IDEpCiAgICAgICAgICAgICAgICBpbWcuYWx0ID0gJ+aXoOazleWKoOi9vSc7
CiAgICAgICAgICAgIGNsZWFyV2FpdCgpOwogICAgICAgIH0sIDEyMDAwKTsKICAgICAgICBpbWcuX2Zh
aWxUaW1lciA9IGZhaWxUaW1lcjsKICAgICAgICBjb25zdCBwcmV2TG9hZCA9IGltZy5vbmxvYWQ7CiAg
ICAgICAgaW1nLm9ubG9hZCA9IGUgPT4gewogICAgICAgICAgICBjbGVhcldhaXQoKTsKICAgICAgICAg
ICAgaW1nLmFsdCA9ICcnOwogICAgICAgICAgICBpZiAodHlwZW9mIHByZXZMb2FkID09PSAnZnVuY3Rp
b24nKSBwcmV2TG9hZC5jYWxsKGltZywgZSk7CiAgICAgICAgfTsKICAgICAgICBjb25zdCBiYXJlID0g
ZmlsZSA/IFN0cmluZyhmaWxlKS5zcGxpdCgvW1xcL10vKS5wb3AoKSA6ICcnOwogICAgICAgIGNvbnN0
IHRoTmFtZSA9IGJhcmUgPyAoJ3RoXycgKyBiYXJlLnJlcGxhY2UoL1wuW14uXSskLywgJycpICsgJy5q
cGcnKSA6ICcnOwogICAgICAgIGltZy5vbmVycm9yID0gKCkgPT4gewogICAgICAgICAgICBjb25zdCBz
dGVwID0gTnVtYmVyKGltZy5kYXRhc2V0LnN0ZXAgfHwgMCk7CiAgICAgICAgICAgIGlmIChzdGVwIDwg
MiAmJiBiYXJlKSB7CiAgICAgICAgICAgICAgICBpbWcuZGF0YXNldC5zdGVwID0gJzInOwogICAgICAg
ICAgICAgICAgaW1nLnNyYyA9IFNUT1JFX0JBU0UgKyBlbmNvZGVVUklDb21wb25lbnQoYmFyZSk7CiAg
ICAgICAgICAgICAgICByZXR1cm47CiAgICAgICAgICAgIH0KICAgICAgICAgICAgaWYgKHN0ZXAgPCAz
ICYmICh0aE5hbWUgfHwgYmFyZSkpIHsKICAgICAgICAgICAgICAgIGltZy5kYXRhc2V0LnN0ZXAgPSAn
Myc7CiAgICAgICAgICAgICAgICBpbWcuc3JjID0gU1RPUkVfQkFTRV9GQUxMQkFDSyArIGVuY29kZVVS
SUNvbXBvbmVudCh0aE5hbWUgfHwgYmFyZSk7CiAgICAgICAgICAgICAgICByZXR1cm47CiAgICAgICAg
ICAgIH0KICAgICAgICAgICAgaWYgKHN0ZXAgPCA0ICYmIGJhcmUgJiYgdGhOYW1lKSB7CiAgICAgICAg
ICAgICAgICBpbWcuZGF0YXNldC5zdGVwID0gJzQnOwogICAgICAgICAgICAgICAgaW1nLnNyYyA9IFNU
T1JFX0JBU0VfRkFMTEJBQ0sgKyBlbmNvZGVVUklDb21wb25lbnQoYmFyZSk7CiAgICAgICAgICAgICAg
ICByZXR1cm47CiAgICAgICAgICAgIH0KICAgICAgICAgICAgLy8gS2VlcCBzaGltbWVyOyBBSEsgX19z
ZXRUaHVtYiB3aWxsIGZpbGwgaW4KICAgICAgICAgICAgaW1nLnJlbW92ZUF0dHJpYnV0ZSgnc3JjJyk7
CiAgICAgICAgICAgIGltZy5jbGFzc0xpc3QuYWRkKCd0aHVtYi1sb2FkaW5nJyk7CiAgICAgICAgICAg
IGlmICh3cmFwKSB3cmFwLmNsYXNzTGlzdC5hZGQoJ3dhaXRpbmcnKTsKICAgICAgICB9OwogICAgICAg
IGNvbnN0IGNhY2hlZCA9IHRodW1iQ2FjaGUuZ2V0KFN0cmluZyhpZCkpOwogICAgICAgIC8vIEFjY2Vw
dCBkYXRhLVVSTCBvciBob3N0IFVSTCBmcm9tIHByaW9yIF9fc2V0VGh1bWIgKHJlLXJlbmRlciBtdXN0
IG5vdCBkcm9wIGl0KQogICAgICAgIGlmIChjYWNoZWQgJiYgU3RyaW5nKGNhY2hlZCkubGVuZ3RoKSB7
CiAgICAgICAgICAgIGltZy5kYXRhc2V0LnN0ZXAgPSAnOSc7CiAgICAgICAgICAgIGltZy5zcmMgPSBT
dHJpbmcoY2FjaGVkKTsKICAgICAgICAgICAgcmV0dXJuOwogICAgICAgIH0KICAgICAgICBjb25zdCBk
YXRhVXJsID0gKGZhbGxiYWNrICYmIFN0cmluZyhmYWxsYmFjaykuc3RhcnRzV2l0aCgnZGF0YTonKSkK
ICAgICAgICAgICAgPyBTdHJpbmcoZmFsbGJhY2spIDogJyc7CiAgICAgICAgaWYgKGRhdGFVcmwpIHsK
ICAgICAgICAgICAgaW1nLmRhdGFzZXQuc3RlcCA9ICc5JzsKICAgICAgICAgICAgaW1nLnNyYyA9IGRh
dGFVcmw7CiAgICAgICAgICAgIHJldHVybjsKICAgICAgICB9CiAgICAgICAgaWYgKGJhcmUpIHsKICAg
ICAgICAgICAgLy8gUHJlZmVyIGxpc3QgdGh1bWIgSlBFRyAoc21hbGwpIG9uIGRlZGljYXRlZCBzdG9y
ZSBob3N0CiAgICAgICAgICAgIGltZy5kYXRhc2V0LnN0ZXAgPSAnMSc7CiAgICAgICAgICAgIGltZy5z
cmMgPSBTVE9SRV9CQVNFICsgZW5jb2RlVVJJQ29tcG9uZW50KHRoTmFtZSB8fCBiYXJlKTsKICAgICAg
ICB9IGVsc2UgewogICAgICAgICAgICAvLyBObyBmaWxlIHlldCAoanVzdCBjb3BpZWQpIOKAlGtlZXAg
c2hpbW1lcjsgSW5qZWN0TGl2ZUltYWdlVGh1bWIgLyBfX3NldFRodW1iIGZpbGxzIGluCiAgICAgICAg
ICAgIGltZy5jbGFzc0xpc3QuYWRkKCd0aHVtYi1sb2FkaW5nJyk7CiAgICAgICAgICAgIGlmICh3cmFw
KSB3cmFwLmNsYXNzTGlzdC5hZGQoJ3dhaXRpbmcnKTsKICAgICAgICB9CiAgICB9CgogICAgd2luZG93
Ll9fc2V0VGh1bWIgPSAoaWQsIHVybCkgPT4gewogICAgICAgIGlmICghdXJsKSByZXR1cm47CiAgICAg
ICAgY29uc3Qga2V5ID0gU3RyaW5nKGlkKTsKICAgICAgICB0aHVtYkNhY2hlLnNldChrZXksIHVybCk7
CiAgICAgICAgY29uc3QgYXBwbHkgPSBpbWcgPT4gewogICAgICAgICAgICBpZiAoaW1nLl9mYWlsVGlt
ZXIpIHRyeSB7IGNsZWFyVGltZW91dChpbWcuX2ZhaWxUaW1lcik7IH0gY2F0Y2gge30KICAgICAgICAg
ICAgaW1nLm9uZXJyb3IgPSBudWxsOwogICAgICAgICAgICBpbWcuYWx0ID0gJyc7CiAgICAgICAgICAg
IGltZy5jbGFzc0xpc3QucmVtb3ZlKCd0aHVtYi1sb2FkaW5nJyk7CiAgICAgICAgICAgIGNvbnN0IHdy
YXAgPSBpbWcucGFyZW50RWxlbWVudDsKICAgICAgICAgICAgaWYgKHdyYXApIHdyYXAuY2xhc3NMaXN0
LnJlbW92ZSgnd2FpdGluZycpOwogICAgICAgICAgICBpbWcuc3JjID0gdXJsOwogICAgICAgIH07CiAg
ICAgICAgbGV0IGhpdCA9IDA7CiAgICAgICAgZG9jdW1lbnQucXVlcnlTZWxlY3RvckFsbCgnLml0bVtk
YXRhLWlkPSInICsga2V5ICsgJyJdIGltZy5pLXRodW1iJykuZm9yRWFjaChpbWcgPT4gewogICAgICAg
ICAgICBhcHBseShpbWcpOyBoaXQrKzsKICAgICAgICB9KTsKICAgICAgICBpZiAoIWhpdCkgewogICAg
ICAgICAgICBkb2N1bWVudC5xdWVyeVNlbGVjdG9yQWxsKCdpbWcuaS10aHVtYltkYXRhLXRodW1iLWlk
PSInICsga2V5ICsgJyJdJykuZm9yRWFjaChhcHBseSk7CiAgICAgICAgfQogICAgfTsKCiAgICBmdW5j
dGlvbiBpc0RyYWdFeGNsdWRlKHQpIHsKICAgICAgICByZXR1cm4gISF0LmNsb3Nlc3QoJyNzZWFyY2gt
d3JhcCwgI2J0bi1zZWFyY2gsICNidG4tbG9jYXRlLCAjYnRuLXRvZGF5LCAjYnRuLXBpbiwgI2J0bi1j
bHIsICNtdWx0aS1jbnQsIC50YWIsIC5pdG0sICN0YWItYWN0aW9ucywgI2N0eCwgI2Nsci1kbGcsICNw
YXRoLXRpcCwgYnV0dG9uLCBpbnB1dCwgYScpOwogICAgfQogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5
SWQoJ2FwcCcpLmFkZEV2ZW50TGlzdGVuZXIoJ21vdXNlZG93bicsIGUgPT4gewogICAgICAgIGlmIChl
LmJ1dHRvbiAhPT0gMCkgcmV0dXJuOwogICAgICAgIGlmIChpc0RyYWdFeGNsdWRlKGUudGFyZ2V0KSkg
cmV0dXJuOwogICAgICAgIGUucHJldmVudERlZmF1bHQoKTsKICAgICAgICBhaGsoJ3N0YXJ0RHJhZycp
OwogICAgfSwgdHJ1ZSk7CgogICAgY29uc3QgaXNVcmwgID0gcyA9PiAvXmh0dHBzPzpcL1wvL2kudGVz
dCgocyB8fCAnJykudHJpbSgpKTsKCiAgICBmdW5jdGlvbiBhZ28oZGF0ZVN0cikgewogICAgICAgIHRy
eSB7CiAgICAgICAgICAgIGNvbnN0IGQgPSBuZXcgRGF0ZShTdHJpbmcoZGF0ZVN0cikucmVwbGFjZSgn
ICcsICdUJykpOwogICAgICAgICAgICBjb25zdCBzID0gKERhdGUubm93KCkgLSBkKSAvIDEwMDAgfCAw
OwogICAgICAgICAgICBpZiAocyA8IDYwKSByZXR1cm4gJ+WImuWImic7CiAgICAgICAgICAgIGlmIChz
IDwgMzYwMCkgcmV0dXJuIChzIC8gNjAgfCAwKSArICcg5YiG6ZKf5YmNJzsKICAgICAgICAgICAgaWYg
KHMgPCA4NjQwMCkgcmV0dXJuIChzIC8gMzYwMCB8IDApICsgJyDlsI/ml7bliY0nOwogICAgICAgICAg
ICByZXR1cm4gKHMgLyA4NjQwMCB8IDApICsgJyDlpKnliY0nOwogICAgICAgIH0gY2F0Y2ggeyByZXR1
cm4gZGF0ZVN0cjsgfQogICAgfQoKICAgIGZ1bmN0aW9uIG5vcm1UeXBlKHQpIHsKICAgICAgICB0ID0g
U3RyaW5nKHQgfHwgJycpLnRvTG93ZXJDYXNlKCk7CiAgICAgICAgaWYgKHQgPT09ICdpbWFnZScgfHwg
dCA9PT0gJ2ltZycgfHwgdCA9PT0gJ2JpdG1hcCcpIHJldHVybiAnaW1hZ2UnOwogICAgICAgIGlmICh0
ID09PSAnZmlsZScgIHx8IHQgPT09ICdmaWxlcycpIHJldHVybiAnZmlsZSc7CiAgICAgICAgcmV0dXJu
ICd0ZXh0JzsKICAgIH0KICAgIGZ1bmN0aW9uIGlzUGlubmVkKGMpIHsKICAgICAgICByZXR1cm4gYy5w
aW5uZWQgPT09IHRydWUgfHwgYy5waW5uZWQgPT09IDEgfHwgYy5waW5uZWQgPT09ICd0cnVlJyB8fCBj
LnBpbm5lZCA9PT0gJzEnOwogICAgfQogICAgZnVuY3Rpb24gaXNQYXN0ZWQoYykgewogICAgICAgIHJl
dHVybiBjLnBhc3RlZCA9PT0gdHJ1ZSB8fCBjLnBhc3RlZCA9PT0gMSB8fCBjLnBhc3RlZCA9PT0gJ3Ry
dWUnIHx8IGMucGFzdGVkID09PSAnMSc7CiAgICB9CgogICAgZnVuY3Rpb24gaXNNYXJrZG93bih0ZXh0
KSB7CiAgICAgICAgaWYgKCF0ZXh0IHx8IHRleHQubGVuZ3RoIDwgNCkgcmV0dXJuIGZhbHNlOwogICAg
ICAgIHJldHVybiAvKD86XnxcbikjezEsNn0gfF5bLSorXSB8XCpcKlteKlxuXStcKlwqfF9fW15fXG5d
K19ffCg/Ol58XG4pPiB8YGBgfGBbXmBcbl0rYHxcW1teXF1dK1xdXChbXildK1wpfFx8LitcfC4rXHwv
bS50ZXN0KHRleHQpOwogICAgfQogICAgZnVuY3Rpb24gY2xpcFVzZXNNSWNvbihjKSB7CiAgICAgICAg
aWYgKCFjKSByZXR1cm4gZmFsc2U7CiAgICAgICAgaWYgKGMuaXNNZCA9PT0gdHJ1ZSB8fCBjLmlzTWQg
PT09IDEgfHwgYy5pc01kID09PSAndHJ1ZScgfHwgYy5pc01kID09PSAnMScpIHJldHVybiB0cnVlOwog
ICAgICAgIGlmIChjLmlzUmljaCA9PT0gdHJ1ZSB8fCBjLmlzUmljaCA9PT0gMSB8fCBjLmlzUmljaCA9
PT0gJ3RydWUnIHx8IGMuaXNSaWNoID09PSAnMScpIHJldHVybiB0cnVlOwogICAgICAgIGNvbnN0IHQg
PSBTdHJpbmcoYy50eXBlIHx8ICcnKS50b0xvd2VyQ2FzZSgpOwogICAgICAgIGlmICh0ICYmIHQgIT09
ICd0ZXh0JyAmJiB0ICE9PSAnbGluaycpIHJldHVybiBmYWxzZTsKICAgICAgICByZXR1cm4gaXNNYXJr
ZG93bihjLmRhdGEgfHwgYy5wcmV2aWV3IHx8ICcnKTsKICAgIH0KICAgIGZ1bmN0aW9uIGVzY0F0dHIo
cykgewogICAgICAgIHJldHVybiBTdHJpbmcocyB8fCAnJykKICAgICAgICAgICAgLnJlcGxhY2UoLyYv
ZywgJyZhbXA7JykKICAgICAgICAgICAgLnJlcGxhY2UoLyIvZywgJyZxdW90OycpCiAgICAgICAgICAg
IC5yZXBsYWNlKC88L2csICcmbHQ7JykKICAgICAgICAgICAgLnJlcGxhY2UoLz4vZywgJyZndDsnKTsK
ICAgIH0KCiAgICBmdW5jdGlvbiB0b2RheVByZWZpeCgpIHsKICAgICAgICBjb25zdCBkID0gbmV3IERh
dGUoKTsKICAgICAgICBjb25zdCBwID0gbiA9PiBTdHJpbmcobikucGFkU3RhcnQoMiwgJzAnKTsKICAg
ICAgICByZXR1cm4gZC5nZXRGdWxsWWVhcigpICsgJy0nICsgcChkLmdldE1vbnRoKCkgKyAxKSArICct
JyArIHAoZC5nZXREYXRlKCkpOwogICAgfQogICAgZnVuY3Rpb24gaXNUb2RheUNsaXAoYykgewogICAg
ICAgIHJldHVybiBTdHJpbmcoYy50aW1lIHx8ICcnKS5zdGFydHNXaXRoKHRvZGF5UHJlZml4KCkpOwog
ICAgfQoKICAgIGZ1bmN0aW9uIGNsaXBIYXkoYykgewogICAgICAgIHJldHVybiBTdHJpbmcoYy5wcmV2
aWV3IHx8ICcnKSArICcgJyArIFN0cmluZyhjLmRhdGEgfHwgJycpICsgJyAnCiAgICAgICAgICAgICsg
U3RyaW5nKGMubGlua1RpdGxlIHx8ICcnKSArICcgJyArIFN0cmluZyhjLmZhdlRpdGxlIHx8ICcnKTsK
ICAgIH0KICAgIC8qKiBNYXRjaCBBSEsgSXRlbU1hdGNoZXNWaWV3IGxpc3Qgc2VhcmNoIOKAlCBwcmV2
aWV3ICgrIHNob3J0IGJvZHkgZmFsbGJhY2spLCBub3QgZnVsbCBkYXRhICovCiAgICBmdW5jdGlvbiBj
bGlwU2VhcmNoSGF5KGMpIHsKICAgICAgICBjb25zdCB0eXBlID0gU3RyaW5nKGMudHlwZSB8fCAnJyku
dG9Mb3dlckNhc2UoKTsKICAgICAgICBpZiAodHlwZSA9PT0gJ2ltYWdlJykKICAgICAgICAgICAgcmV0
dXJuIFN0cmluZyhjLmZhdlRpdGxlIHx8ICcnKTsKICAgICAgICBpZiAodHlwZSA9PT0gJ2ZpbGUnKSB7
CiAgICAgICAgICAgIHJldHVybiBTdHJpbmcoYy5wcmV2aWV3IHx8ICcnKSArICcgJyArIFN0cmluZyhj
LmRhdGEgfHwgJycpICsgJyAnCiAgICAgICAgICAgICAgICArIFN0cmluZyhjLmZhdlRpdGxlIHx8ICcn
KTsKICAgICAgICB9CiAgICAgICAgbGV0IHByZXYgPSBTdHJpbmcoYy5wcmV2aWV3IHx8ICcnKTsKICAg
ICAgICBpZiAoIXByZXYgJiYgYy5kYXRhKQogICAgICAgICAgICBwcmV2ID0gU3RyaW5nKGMuZGF0YSku
c2xpY2UoMCwgNTAwKTsKICAgICAgICByZXR1cm4gcHJldiArICcgJyArIFN0cmluZyhjLmxpbmtUaXRs
ZSB8fCAnJykgKyAnICcgKyBTdHJpbmcoYy5mYXZUaXRsZSB8fCAnJyk7CiAgICB9CiAgICBmdW5jdGlv
biBjbGlwTWF0Y2hlc1NlYXJjaChjLCB0ZXJtTCkgewogICAgICAgIGNvbnN0IHR5cGUgPSBTdHJpbmco
Yy50eXBlIHx8ICcnKS50b0xvd2VyQ2FzZSgpOwogICAgICAgIGNvbnN0IGhheSA9ICh0eXBlID09PSAn
aW1hZ2UnID8gU3RyaW5nKGMuZmF2VGl0bGUgfHwgJycpIDogY2xpcFNlYXJjaEhheShjKSkudG9Mb3dl
ckNhc2UoKTsKICAgICAgICByZXR1cm4gdGVybUwuZXZlcnkodCA9PiBoYXkuaW5jbHVkZXModCkpOwog
ICAgfQogICAgZnVuY3Rpb24gZmlsdGVyKGNsaXBzLCB0YWIsIHEpIHsKICAgICAgICAvLyDkuLvmnLrl
t7Lov4fmu6Tml7bku43lgZrliY3nq6/lhZzlupXvvJrpgb/lhY3nq57mgIHmjqjmnaXmnKrlkb3kuK3o
oYwKICAgICAgICBjb25zdCB0ZXJtcyA9IHF1ZXJ5VGVybXMocSk7CiAgICAgICAgaWYgKCF0ZXJtcy5s
ZW5ndGgpIHJldHVybiBjbGlwczsKICAgICAgICBjb25zdCB0ZXJtTCA9IHRlcm1zLm1hcCh0ID0+IHQu
dG9Mb3dlckNhc2UoKSk7CiAgICAgICAgY29uc3QgbWF0Y2hlZEdyb3VwcyA9IG5ldyBTZXQoKTsKICAg
ICAgICBmb3IgKGNvbnN0IGMgb2YgY2xpcHMpIHsKICAgICAgICAgICAgaWYgKCFjbGlwTWF0Y2hlc1Nl
YXJjaChjLCB0ZXJtTCkpIGNvbnRpbnVlOwogICAgICAgICAgICBjb25zdCBnaWQgPSBTdHJpbmcoYyAm
JiBjLmZhdkdyb3VwIHx8ICcnKS50cmltKCk7CiAgICAgICAgICAgIGlmIChnaWQpIG1hdGNoZWRHcm91
cHMuYWRkKGdpZCk7CiAgICAgICAgfQogICAgICAgIC8vIOWQiOW5tue7hO+8muWFs+mUruWtl+WPr+iD
veWIhuaVo+WcqOS4jeWQjOihjO+8iOagh+mimC/mraPmlofvvIkKICAgICAgICBjb25zdCBieUdyb3Vw
ID0gbmV3IE1hcCgpOwogICAgICAgIGZvciAoY29uc3QgYyBvZiBjbGlwcykgewogICAgICAgICAgICBj
b25zdCBnaWQgPSBTdHJpbmcoYyAmJiBjLmZhdkdyb3VwIHx8ICcnKS50cmltKCk7CiAgICAgICAgICAg
IGlmICghZ2lkKSBjb250aW51ZTsKICAgICAgICAgICAgaWYgKCFieUdyb3VwLmhhcyhnaWQpKSBieUdy
b3VwLnNldChnaWQsIFtdKTsKICAgICAgICAgICAgYnlHcm91cC5nZXQoZ2lkKS5wdXNoKGMpOwogICAg
ICAgIH0KICAgICAgICBmb3IgKGNvbnN0IFtnaWQsIG1lbWJlcnNdIG9mIGJ5R3JvdXApIHsKICAgICAg
ICAgICAgaWYgKG1hdGNoZWRHcm91cHMuaGFzKGdpZCkpIGNvbnRpbnVlOwogICAgICAgICAgICBjb25z
dCB1bmlvbiA9IG1lbWJlcnMubWFwKGMgPT4gewogICAgICAgICAgICAgICAgY29uc3QgdHlwZSA9IFN0
cmluZyhjLnR5cGUgfHwgJycpLnRvTG93ZXJDYXNlKCk7CiAgICAgICAgICAgICAgICByZXR1cm4gKHR5
cGUgPT09ICdpbWFnZScgPyBTdHJpbmcoYy5mYXZUaXRsZSB8fCAnJykgOiBjbGlwU2VhcmNoSGF5KGMp
KS50b0xvd2VyQ2FzZSgpOwogICAgICAgICAgICB9KS5qb2luKCcgJyk7CiAgICAgICAgICAgIGlmICh0
ZXJtTC5ldmVyeSh0ID0+IHVuaW9uLmluY2x1ZGVzKHQpKSkKICAgICAgICAgICAgICAgIG1hdGNoZWRH
cm91cHMuYWRkKGdpZCk7CiAgICAgICAgfQogICAgICAgIHJldHVybiBjbGlwcy5maWx0ZXIoYyA9PiB7
CiAgICAgICAgICAgIGlmIChjbGlwTWF0Y2hlc1NlYXJjaChjLCB0ZXJtTCkpIHJldHVybiB0cnVlOwog
ICAgICAgICAgICBjb25zdCBnaWQgPSBTdHJpbmcoYyAmJiBjLmZhdkdyb3VwIHx8ICcnKS50cmltKCk7
CiAgICAgICAgICAgIHJldHVybiBnaWQgJiYgbWF0Y2hlZEdyb3Vwcy5oYXMoZ2lkKTsKICAgICAgICB9
KTsKICAgIH0KCiAgICBmdW5jdGlvbiBtYXJrUGFzdGVkTG9jYWwoaWRzKSB7CiAgICAgICAgY29uc3Qg
bGlzdCA9IEFycmF5LmlzQXJyYXkoaWRzKSA/IGlkcyA6IFtpZHNdOwogICAgICAgIGlmIChsaXN0Lmxl
bmd0aCkKICAgICAgICAgICAgcmVtZW1iZXJMYXN0UGFzdGUobGlzdFtsaXN0Lmxlbmd0aCAtIDFdKTsK
ICAgICAgICBjb25zdCBiYWRnZUh0bWwgPSBgPHN2ZyB2aWV3Qm94PSIwIDAgMTYgMTYiIGZpbGw9Im5v
bmUiIHN0cm9rZT0iY3VycmVudENvbG9yIiBzdHJva2Utd2lkdGg9IjIuNCIgc3Ryb2tlLWxpbmVjYXA9
InJvdW5kIiBzdHJva2UtbGluZWpvaW49InJvdW5kIj48cG9seWxpbmUgcG9pbnRzPSIzLjUgOC41IDYu
NSAxMS41IDEyLjUgNC41Ii8+PC9zdmc+YDsKICAgICAgICBsaXN0LmZvckVhY2gocmF3SWQgPT4gewog
ICAgICAgICAgICBjb25zdCBpZCA9ICtyYXdJZDsKICAgICAgICAgICAgY29uc3QgYyA9IGFsbENsaXBz
LmZpbmQoeCA9PiAreC5pZCA9PT0gaWQpOwogICAgICAgICAgICBpZiAoYykgYy5wYXN0ZWQgPSB0cnVl
OwogICAgICAgICAgICBjb25zdCByb3cgPSBsaXN0RWwgJiYgKAogICAgICAgICAgICAgICAgbGlzdEVs
LnF1ZXJ5U2VsZWN0b3IoJy5pdG1bZGF0YS1pZD0iJyArIGlkICsgJyJdJykKICAgICAgICAgICAgICAg
IHx8IGxpc3RFbC5xdWVyeVNlbGVjdG9yKCcuaXRtW2RhdGEtaWQ9IicgKyBTdHJpbmcocmF3SWQpICsg
JyJdJykKICAgICAgICAgICAgKTsKICAgICAgICAgICAgaWYgKCFyb3cpIHJldHVybjsKICAgICAgICAg
ICAgcm93LmNsYXNzTGlzdC5hZGQoJ3Bhc3RlZCcsICdxLWRvbmUnKTsKICAgICAgICAgICAgY29uc3Qg
aWNvID0gcm93LnF1ZXJ5U2VsZWN0b3IoJy5pLWljbycpOwogICAgICAgICAgICBpZiAoaWNvICYmICFp
Y28ucXVlcnlTZWxlY3RvcignLmktdXNlZCcpKSB7CiAgICAgICAgICAgICAgICBjb25zdCBiYWRnZSA9
IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ3NwYW4nKTsKICAgICAgICAgICAgICAgIGJhZGdlLmNsYXNz
TmFtZSA9ICdpLXVzZWQnOwogICAgICAgICAgICAgICAgYmFkZ2UudGl0bGUgPSAn5bey57KY6LS0JzsK
ICAgICAgICAgICAgICAgIGJhZGdlLmlubmVySFRNTCA9IGJhZGdlSHRtbDsKICAgICAgICAgICAgICAg
IGljby5hcHBlbmRDaGlsZChiYWRnZSk7CiAgICAgICAgICAgIH0KICAgICAgICB9KTsKICAgICAgICB0
cnkgeyBtYXJrUXVldWVSYWlscygpOyB9IGNhdGNoIChlKSB7fQogICAgfQogICAgd2luZG93Ll9fbWFy
a1Bhc3RlZCA9IG1hcmtQYXN0ZWRMb2NhbDsKCiAgICBmdW5jdGlvbiBtYXJrVW5wYXN0ZWRMb2NhbChp
ZHMpIHsKICAgICAgICBjb25zdCBsaXN0ID0gQXJyYXkuaXNBcnJheShpZHMpID8gaWRzIDogW2lkc107
CiAgICAgICAgbGlzdC5mb3JFYWNoKHJhd0lkID0+IHsKICAgICAgICAgICAgY29uc3QgaWQgPSArcmF3
SWQ7CiAgICAgICAgICAgIGNvbnN0IGMgPSBhbGxDbGlwcy5maW5kKHggPT4gK3guaWQgPT09IGlkKTsK
ICAgICAgICAgICAgaWYgKGMpIGMucGFzdGVkID0gZmFsc2U7CiAgICAgICAgICAgIGNvbnN0IHJvdyA9
IGxpc3RFbCAmJiAoCiAgICAgICAgICAgICAgICBsaXN0RWwucXVlcnlTZWxlY3RvcignLml0bVtkYXRh
LWlkPSInICsgaWQgKyAnIl0nKQogICAgICAgICAgICAgICAgfHwgbGlzdEVsLnF1ZXJ5U2VsZWN0b3Io
Jy5pdG1bZGF0YS1pZD0iJyArIFN0cmluZyhyYXdJZCkgKyAnIl0nKQogICAgICAgICAgICApOwogICAg
ICAgICAgICBpZiAoIXJvdykgcmV0dXJuOwogICAgICAgICAgICByb3cuY2xhc3NMaXN0LnJlbW92ZSgn
cGFzdGVkJywgJ3EtZG9uZScsICdxLWRvbmUtbGluaycpOwogICAgICAgICAgICBjb25zdCBiYWRnZSA9
IHJvdy5xdWVyeVNlbGVjdG9yKCcuaS11c2VkJyk7CiAgICAgICAgICAgIGlmIChiYWRnZSkgYmFkZ2Uu
cmVtb3ZlKCk7CiAgICAgICAgICAgIGNvbnN0IGRvdCA9IHJvdy5xdWVyeVNlbGVjdG9yKCcucS1kb3Qn
KTsKICAgICAgICAgICAgaWYgKGRvdCkgZG90LnRpdGxlID0gJ+eymOi0tOmYn+WIlyc7CiAgICAgICAg
fSk7CiAgICAgICAgdHJ5IHsgbWFya1F1ZXVlUmFpbHMoKTsgfSBjYXRjaCAoZSkge30KICAgIH0KICAg
IHdpbmRvdy5fX21hcmtVbnBhc3RlZCA9IG1hcmtVbnBhc3RlZExvY2FsOwoKICAgIGNvbnN0IGxpc3RF
bCAgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbGlzdCcpOwogICAgY29uc3QgZW1wdHlFbCA9IGRv
Y3VtZW50LmdldEVsZW1lbnRCeUlkKCdlbXB0eScpOwogICAgY29uc3Qgc2tlbEVsICA9IGRvY3VtZW50
LmdldEVsZW1lbnRCeUlkKCdza2VsJyk7CiAgICBjb25zdCBidG5Ub3AgID0gZG9jdW1lbnQuZ2V0RWxl
bWVudEJ5SWQoJ2J0bi10b3AnKTsKICAgIGZ1bmN0aW9uIHNldEJvb3RMb2FkaW5nKG9uKSB7CiAgICAg
ICAgYm9vdExvYWRpbmcgPSAhIW9uOwogICAgICAgIGlmIChib290TG9hZGluZykgd2luZG93Ll9fc2tl
bFNpbmNlID0gRGF0ZS5ub3coKTsKICAgICAgICBpZiAoc2tlbEVsKSBza2VsRWwuY2xhc3NMaXN0LnRv
Z2dsZSgnb24nLCBib290TG9hZGluZyk7CiAgICAgICAgaWYgKGJvb3RMb2FkaW5nICYmIGVtcHR5RWwp
IGVtcHR5RWwuY2xhc3NMaXN0LnJlbW92ZSgnb24nKTsKICAgICAgICBjb25zdCBhcHAgPSBkb2N1bWVu
dC5nZXRFbGVtZW50QnlJZCgnYXBwJyk7CiAgICAgICAgaWYgKGFwcCkgYXBwLmNsYXNzTGlzdC50b2dn
bGUoJ2Jvb3QtbG9hZGluZycsIGJvb3RMb2FkaW5nKTsKICAgIH0KICAgIC8qKiBXYWl0IGZvciBob3N0
IGRhdGEuIEVtcHR5IGxpc3Qg4oaSc2tlbGV0b24gbm93IChubyBibGFuaykuIEhhcyBjb250ZW50IOKG
kmRlbGF5LiAqLwogICAgZnVuY3Rpb24gc2NoZWR1bGVEZWxheWVkU2tlbCgpIHsKICAgICAgICB3YWl0
aW5nRGF0YSA9IHRydWU7CiAgICAgICAgd2luZG93Ll9fZGF0YVJlYWR5ID0gZmFsc2U7CiAgICAgICAg
aWYgKGVtcHR5RWwpIGVtcHR5RWwuY2xhc3NMaXN0LnJlbW92ZSgnb24nKTsKICAgICAgICBpZiAod2lu
ZG93Ll9fcGVuZGluZ1NrZWxUaW1lcikgewogICAgICAgICAgICBjbGVhclRpbWVvdXQod2luZG93Ll9f
cGVuZGluZ1NrZWxUaW1lcik7CiAgICAgICAgICAgIHdpbmRvdy5fX3BlbmRpbmdTa2VsVGltZXIgPSAw
OwogICAgICAgIH0KICAgICAgICB3aW5kb3cuX19wZW5kaW5nU2tlbFNpbmNlID0gRGF0ZS5ub3coKTsK
ICAgICAgICBjb25zdCBoYXNQYWludCA9IChhbGxDbGlwcyAmJiBhbGxDbGlwcy5sZW5ndGggPiAwKQog
ICAgICAgICAgICB8fCAhIShsaXN0RWwgJiYgbGlzdEVsLnF1ZXJ5U2VsZWN0b3IoJy5pdG0nKSk7CiAg
ICAgICAgaWYgKCFoYXNQYWludCkgewogICAgICAgICAgICAvLyBOb3RoaW5nIG9uIHNjcmVlbiDigJRz
aG93IHNrZWxldG9uIGltbWVkaWF0ZWx5IHNvIHBhbmVsIGlzIG5ldmVyIGJsYW5rCiAgICAgICAgICAg
IHNldEJvb3RMb2FkaW5nKHRydWUpOwogICAgICAgICAgICB0cnkgeyByZW5kZXIoKTsgfSBjYXRjaCB7
fQogICAgICAgICAgICByZXR1cm47CiAgICAgICAgfQogICAgICAgIC8vIEFscmVhZHkgc2hvd2luZyBy
b3dzIOKAlG9ubHkgc3dhcCB0byBza2VsZXRvbiBpZiByZWZyZXNoIGlzIHNsb3cKICAgICAgICB3aW5k
b3cuX19wZW5kaW5nU2tlbFRpbWVyID0gc2V0VGltZW91dCgoKSA9PiB7CiAgICAgICAgICAgIHdpbmRv
dy5fX3BlbmRpbmdTa2VsVGltZXIgPSAwOwogICAgICAgICAgICBpZiAod2FpdGluZ0RhdGEgJiYgIXdp
bmRvdy5fX2RhdGFSZWFkeSkgewogICAgICAgICAgICAgICAgc2V0Qm9vdExvYWRpbmcodHJ1ZSk7CiAg
ICAgICAgICAgICAgICB0cnkgeyByZW5kZXIoKTsgfSBjYXRjaCB7fQogICAgICAgICAgICB9CiAgICAg
ICAgfSwgU0tFTF9ERUxBWV9NUyk7CiAgICB9CiAgICBmdW5jdGlvbiBjbGVhcldhaXRpbmdEYXRhKCkg
ewogICAgICAgIHdhaXRpbmdEYXRhID0gZmFsc2U7CiAgICAgICAgaWYgKHdpbmRvdy5fX3BlbmRpbmdT
a2VsVGltZXIpIHsKICAgICAgICAgICAgY2xlYXJUaW1lb3V0KHdpbmRvdy5fX3BlbmRpbmdTa2VsVGlt
ZXIpOwogICAgICAgICAgICB3aW5kb3cuX19wZW5kaW5nU2tlbFRpbWVyID0gMDsKICAgICAgICB9CiAg
ICAgICAgd2luZG93Ll9fcGVuZGluZ1NrZWxTaW5jZSA9IDA7CiAgICAgICAgc2V0Qm9vdExvYWRpbmco
ZmFsc2UpOwogICAgfQogICAgd2luZG93LnNldEJvb3RMb2FkaW5nID0gc2V0Qm9vdExvYWRpbmc7CiAg
ICB3aW5kb3cuZm9yY2VFbmRCb290TG9hZGluZyA9IGZ1bmN0aW9uKCkgewogICAgICAgIGNsZWFyV2Fp
dGluZ0RhdGEoKTsKICAgICAgICAvLyBEbyBub3QgZmFrZeOAjOaaguaXoOiusOW9leOAjWlmIGhvc3Qg
bmV2ZXIgcHVzaGVkCiAgICAgICAgaWYgKGhvc3RQdXNoZWRPbmNlKQogICAgICAgICAgICB3aW5kb3cu
X19kYXRhUmVhZHkgPSB0cnVlOwogICAgICAgIHRyeSB7IHJlbmRlcigpOyB9IGNhdGNoIChlKSB7fQog
ICAgfTsKICAgIC8vIFNhZmV0eTogZHJvcCBzdHVjayBza2VsZXRvbjsgc3RpbGwgbmV2ZXIgaW52ZW50
IGVtcHR5LXN0YXRlIHdpdGhvdXQgaG9zdCBwdXNoCiAgICBzZXRUaW1lb3V0KCgpID0+IHsKICAgICAg
ICBpZiAoaG9zdFB1c2hlZE9uY2UgfHwgd2luZG93Ll9fZGF0YVJlYWR5KSByZXR1cm47CiAgICAgICAg
aWYgKCFib290TG9hZGluZyAmJiAhd2FpdGluZ0RhdGEpIHJldHVybjsKICAgICAgICBjbGVhcldhaXRp
bmdEYXRhKCk7CiAgICAgICAgdHJ5IHsgcmVuZGVyKCk7IH0gY2F0Y2gge30KICAgIH0sIDgwMDApOwoK
ICAgIGZ1bmN0aW9uIHVwZGF0ZVRvcEJ0bigpIHsKICAgICAgICBpZiAoIWJ0blRvcCB8fCAhbGlzdEVs
KSByZXR1cm47CiAgICAgICAgYnRuVG9wLmNsYXNzTGlzdC50b2dnbGUoJ29uJywgbGlzdEVsLnNjcm9s
bFRvcCA+IDQ4KTsKICAgIH0KICAgIGxldCBfc2Nyb2xsUmFmID0gMDsKICAgIGxldCBfc2Nyb2xsSWRs
ZVQgPSAwOwogICAgbGV0IF9saXN0UHRyRG93biA9IGZhbHNlOwogICAgbGV0IF9wZW5kaW5nQXBwZW5k
ID0gbnVsbDsgLy8geyBmcm9tTGVuIH0gcXVldWVkIHdoaWxlIHNjcm9sbGluZwogICAgd2luZG93Ll9f
c2Nyb2xsQnVzeSA9IGZhbHNlOwogICAgd2luZG93Ll9fd2FudE1vcmUgPSBmYWxzZTsKCiAgICBmdW5j
dGlvbiBtYXJrTGlzdFNjcm9sbGluZygpIHsKICAgICAgICB3aW5kb3cuX19zY3JvbGxCdXN5ID0gdHJ1
ZTsKICAgICAgICB0cnkgeyBsaXN0RWwuY2xhc3NMaXN0LmFkZCgnaXMtc2Nyb2xsaW5nJyk7IH0gY2F0
Y2gge30KICAgICAgICBpZiAoX3Njcm9sbElkbGVUKSBjbGVhclRpbWVvdXQoX3Njcm9sbElkbGVUKTsK
ICAgICAgICBfc2Nyb2xsSWRsZVQgPSBzZXRUaW1lb3V0KCgpID0+IHsKICAgICAgICAgICAgX3Njcm9s
bElkbGVUID0gMDsKICAgICAgICAgICAgZmx1c2hTY3JvbGxJZGxlKCk7CiAgICAgICAgfSwgMjIwKTsK
ICAgIH0KCiAgICBmdW5jdGlvbiBmbHVzaFNjcm9sbElkbGUoKSB7CiAgICAgICAgaWYgKF9saXN0UHRy
RG93bikgewogICAgICAgICAgICBtYXJrTGlzdFNjcm9sbGluZygpOwogICAgICAgICAgICByZXR1cm47
CiAgICAgICAgfQogICAgICAgIHdpbmRvdy5fX3Njcm9sbEJ1c3kgPSBmYWxzZTsKICAgICAgICB0cnkg
eyBsaXN0RWwuY2xhc3NMaXN0LnJlbW92ZSgnaXMtc2Nyb2xsaW5nJyk7IH0gY2F0Y2gge30KICAgICAg
ICBpZiAoX3BlbmRpbmdBcHBlbmQpIHsKICAgICAgICAgICAgY29uc3QgcGVuZGluZyA9IF9wZW5kaW5n
QXBwZW5kOwogICAgICAgICAgICBfcGVuZGluZ0FwcGVuZCA9IG51bGw7CiAgICAgICAgICAgIGFwcGx5
QXBwZW5kUGF5bG9hZChwZW5kaW5nKTsKICAgICAgICB9CiAgICAgICAgaWYgKHdpbmRvdy5fX3dhbnRN
b3JlKQogICAgICAgICAgICByZXF1ZXN0TW9yZSgpOwogICAgICAgIGVsc2UgaWYgKCFsb2FkaW5nTW9y
ZQogICAgICAgICAgICAmJiBkaXNrVG90YWwgPiAwCiAgICAgICAgICAgICYmIGFsbENsaXBzLmxlbmd0
aCA8IGRpc2tUb3RhbAogICAgICAgICAgICAmJiBsaXN0RWwuc2Nyb2xsVG9wICsgbGlzdEVsLmNsaWVu
dEhlaWdodCA+PSBsaXN0RWwuc2Nyb2xsSGVpZ2h0IC0gNDIwKQogICAgICAgICAgICByZXF1ZXN0TW9y
ZSgpOwogICAgfQoKICAgIGZ1bmN0aW9uIG9uTGlzdFNjcm9sbCgpIHsKICAgICAgICBtYXJrTGlzdFNj
cm9sbGluZygpOwogICAgICAgIGlmIChfc2Nyb2xsUmFmKSByZXR1cm47CiAgICAgICAgX3Njcm9sbFJh
ZiA9IHJlcXVlc3RBbmltYXRpb25GcmFtZSgoKSA9PiB7CiAgICAgICAgICAgIF9zY3JvbGxSYWYgPSAw
OwogICAgICAgICAgICB0cnkgeyBoaWRlUGF0aFRpcCgpOyB9IGNhdGNoIHt9CiAgICAgICAgICAgIHVw
ZGF0ZVRvcEJ0bigpOwogICAgICAgICAgICBpZiAoIWxvYWRpbmdNb3JlCiAgICAgICAgICAgICAgICAm
JiBkaXNrVG90YWwgPiAwCiAgICAgICAgICAgICAgICAmJiBhbGxDbGlwcy5sZW5ndGggPCBkaXNrVG90
YWwKICAgICAgICAgICAgICAgICYmIGxpc3RFbC5zY3JvbGxUb3AgKyBsaXN0RWwuY2xpZW50SGVpZ2h0
ID49IGxpc3RFbC5zY3JvbGxIZWlnaHQgLSAyNDApCiAgICAgICAgICAgICAgICB3aW5kb3cuX193YW50
TW9yZSA9IHRydWU7CiAgICAgICAgfSk7CiAgICB9CiAgICBsaXN0RWwuYWRkRXZlbnRMaXN0ZW5lcign
c2Nyb2xsJywgb25MaXN0U2Nyb2xsLCB7IHBhc3NpdmU6IHRydWUgfSk7CiAgICBsaXN0RWwuYWRkRXZl
bnRMaXN0ZW5lcignd2hlZWwnLCBtYXJrTGlzdFNjcm9sbGluZywgeyBwYXNzaXZlOiB0cnVlIH0pOwog
ICAgbGlzdEVsLmFkZEV2ZW50TGlzdGVuZXIoJ3BvaW50ZXJkb3duJywgZSA9PiB7CiAgICAgICAgaWYg
KGUuYnV0dG9uICE9PSAwKSByZXR1cm47CiAgICAgICAgX2xpc3RQdHJEb3duID0gdHJ1ZTsKICAgICAg
ICBtYXJrTGlzdFNjcm9sbGluZygpOwogICAgfSwgeyBwYXNzaXZlOiB0cnVlIH0pOwogICAgd2luZG93
LmFkZEV2ZW50TGlzdGVuZXIoJ3BvaW50ZXJ1cCcsICgpID0+IHsKICAgICAgICBpZiAoIV9saXN0UHRy
RG93bikgcmV0dXJuOwogICAgICAgIF9saXN0UHRyRG93biA9IGZhbHNlOwogICAgICAgIG1hcmtMaXN0
U2Nyb2xsaW5nKCk7CiAgICB9LCB7IHBhc3NpdmU6IHRydWUgfSk7CiAgICB3aW5kb3cuYWRkRXZlbnRM
aXN0ZW5lcigncG9pbnRlcmNhbmNlbCcsICgpID0+IHsKICAgICAgICBpZiAoIV9saXN0UHRyRG93bikg
cmV0dXJuOwogICAgICAgIF9saXN0UHRyRG93biA9IGZhbHNlOwogICAgICAgIG1hcmtMaXN0U2Nyb2xs
aW5nKCk7CiAgICB9LCB7IHBhc3NpdmU6IHRydWUgfSk7CiAgICBidG5Ub3AuYWRkRXZlbnRMaXN0ZW5l
cignY2xpY2snLCBlID0+IHsKICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgICAgIGxpc3RF
bC5zY3JvbGxUbyh7IHRvcDogMCwgYmVoYXZpb3I6ICdzbW9vdGgnIH0pOwogICAgfSk7CgogICAgZnVu
Y3Rpb24gdmlzaWJsZUxpc3QoKSB7CiAgICAgICAgY29uc3QgcSA9IFN0cmluZyhxdWVyeSB8fCAnJyku
dHJpbSgpOwogICAgICAgIC8vIEhvc3QgYWxyZWFkeSBmaWx0ZXJlZCtleHBhbmRlZCBmb3IgdGhpcyBl
eGFjdCBxdWVyeSDigJQgZG9uJ3QgcmUtZmlsdGVyIChhdm9pZHMgZmxhc2ggLyBkcm9wcGVkIGZhdiBn
cm91cHMpCiAgICAgICAgaWYgKHEgJiYgd2luZG93Ll9faG9zdEZpbHRlcmVkICYmIHdpbmRvdy5fX2hv
c3RGaWx0ZXJRID09PSBxKQogICAgICAgICAgICByZXR1cm4gYWxsQ2xpcHM7CiAgICAgICAgcmV0dXJu
IGZpbHRlcihhbGxDbGlwcywgY3VyVGFiLCBxdWVyeSk7CiAgICB9CiAgICBmdW5jdGlvbiBlc2NIdG1s
KHMpIHsKICAgICAgICByZXR1cm4gU3RyaW5nKHMgPz8gJycpLnJlcGxhY2UoLyYvZywnJmFtcDsnKS5y
ZXBsYWNlKC88L2csJyZsdDsnKS5yZXBsYWNlKC8+L2csJyZndDsnKS5yZXBsYWNlKC8iL2csJyZxdW90
OycpOwogICAgfQogICAgZnVuY3Rpb24gcXVlcnlUZXJtcyhxKSB7CiAgICAgICAgY29uc3Qgb3V0ID0g
W107CiAgICAgICAgZm9yIChjb25zdCBzZWcgb2YgU3RyaW5nKHEgfHwgJycpLnNwbGl0KCd8JykpIHsK
ICAgICAgICAgICAgY29uc3QgcyA9IHNlZy50cmltKCk7CiAgICAgICAgICAgIGlmICghcykgY29udGlu
dWU7CiAgICAgICAgICAgIGNvbnN0IHdvcmRzID0gcy5zcGxpdCgvXHMrLykuZmlsdGVyKEJvb2xlYW4p
OwogICAgICAgICAgICBpZiAod29yZHMubGVuZ3RoKSBvdXQucHVzaCguLi53b3Jkcyk7CiAgICAgICAg
fQogICAgICAgIHJldHVybiBvdXQ7CiAgICB9CiAgICBmdW5jdGlvbiBobEh0bWwodGV4dCkgewogICAg
ICAgIGNvbnN0IHRlcm1zID0gcXVlcnlUZXJtcyhxdWVyeSk7CiAgICAgICAgY29uc3QgcyA9IFN0cmlu
Zyh0ZXh0ID8/ICcnKTsKICAgICAgICBpZiAoIXRlcm1zLmxlbmd0aCkgcmV0dXJuIGVzY0h0bWwocyk7
CiAgICAgICAgY29uc3QgbG93ZXIgPSBzLnRvTG93ZXJDYXNlKCk7CiAgICAgICAgY29uc3QgdGVybUwg
PSB0ZXJtcy5tYXAodCA9PiB0LnRvTG93ZXJDYXNlKCkpOwogICAgICAgIGxldCBvdXQgPSAnJywgaSA9
IDA7CiAgICAgICAgd2hpbGUgKGkgPCBzLmxlbmd0aCkgewogICAgICAgICAgICBsZXQgYmVzdEogPSAt
MSwgYmVzdExlbiA9IDA7CiAgICAgICAgICAgIGZvciAobGV0IHRpID0gMDsgdGkgPCB0ZXJtTC5sZW5n
dGg7IHRpKyspIHsKICAgICAgICAgICAgICAgIGNvbnN0IHQgPSB0ZXJtTFt0aV07CiAgICAgICAgICAg
ICAgICBpZiAoIXQpIGNvbnRpbnVlOwogICAgICAgICAgICAgICAgY29uc3QgaiA9IGxvd2VyLmluZGV4
T2YodCwgaSk7CiAgICAgICAgICAgICAgICBpZiAoaiA8IDApIGNvbnRpbnVlOwogICAgICAgICAgICAg
ICAgaWYgKGJlc3RKIDwgMCB8fCBqIDwgYmVzdEogfHwgKGogPT09IGJlc3RKICYmIHQubGVuZ3RoID4g
YmVzdExlbikpIHsKICAgICAgICAgICAgICAgICAgICBiZXN0SiA9IGo7IGJlc3RMZW4gPSB0Lmxlbmd0
aDsKICAgICAgICAgICAgICAgIH0KICAgICAgICAgICAgfQogICAgICAgICAgICBpZiAoYmVzdEogPCAw
KSB7IG91dCArPSBlc2NIdG1sKHMuc2xpY2UoaSkpOyBicmVhazsgfQogICAgICAgICAgICBvdXQgKz0g
ZXNjSHRtbChzLnNsaWNlKGksIGJlc3RKKSk7CiAgICAgICAgICAgIG91dCArPSAnPG1hcmsgY2xhc3M9
InEtaGwiPicgKyBlc2NIdG1sKHMuc2xpY2UoYmVzdEosIGJlc3RKICsgYmVzdExlbikpICsgJzwvbWFy
az4nOwogICAgICAgICAgICBpID0gYmVzdEogKyBNYXRoLm1heCgxLCBiZXN0TGVuKTsKICAgICAgICB9
CiAgICAgICAgcmV0dXJuIG91dDsKICAgIH0KICAgIGZ1bmN0aW9uIHNldEhsVGV4dChlbCwgdGV4dCkg
ewogICAgICAgIGlmICghZWwpIHJldHVybjsKICAgICAgICBjb25zdCBxID0gU3RyaW5nKHF1ZXJ5IHx8
ICcnKS50cmltKCk7CiAgICAgICAgaWYgKCFxKSB7CiAgICAgICAgICAgIGVsLmNsYXNzTGlzdC5yZW1v
dmUoJ2hhcy1obCcpOwogICAgICAgICAgICBlbC50ZXh0Q29udGVudCA9IHRleHQgPT0gbnVsbCA/ICcn
IDogU3RyaW5nKHRleHQpOwogICAgICAgICAgICByZXR1cm47CiAgICAgICAgfQogICAgICAgIGVsLmNs
YXNzTGlzdC5hZGQoJ2hhcy1obCcpOwogICAgICAgIGVsLmlubmVySFRNTCA9IGhsSHRtbCh0ZXh0KTsK
ICAgIH0KCgogICAgZnVuY3Rpb24gYXBwbHlUYWJTd2l0Y2hBbmltKCkgewogICAgICAgIGlmICghdGFi
U3dpdGNoQW5pbURpciB8fCAhbGlzdEVsKSByZXR1cm47CiAgICAgICAgaWYgKCFsaXN0RWwucXVlcnlT
ZWxlY3RvcignLml0bSwgI2VtcHR5Lm9uLCAjbGlzdC1tb3JlJykpCiAgICAgICAgICAgIHJldHVybjsK
ICAgICAgICBjb25zdCBkaXIgPSB0YWJTd2l0Y2hBbmltRGlyOwogICAgICAgIHRhYlN3aXRjaEFuaW1E
aXIgPSAwOwogICAgICAgIGxpc3RFbC5jbGFzc0xpc3QucmVtb3ZlKCd0YWItaW4tbHInLCAndGFiLWlu
LXJsJyk7CiAgICAgICAgdm9pZCBsaXN0RWwub2Zmc2V0V2lkdGg7CiAgICAgICAgbGlzdEVsLmNsYXNz
TGlzdC5hZGQoZGlyID4gMCA/ICd0YWItaW4tbHInIDogJ3RhYi1pbi1ybCcpOwogICAgICAgIGNsZWFy
VGltZW91dChsaXN0RWwuX3RhYkFuaW1UaW1lcik7CiAgICAgICAgbGlzdEVsLl90YWJBbmltVGltZXIg
PSBzZXRUaW1lb3V0KCgpID0+IHsKICAgICAgICAgICAgbGlzdEVsLmNsYXNzTGlzdC5yZW1vdmUoJ3Rh
Yi1pbi1scicsICd0YWItaW4tcmwnKTsKICAgICAgICB9LCA0MDApOwogICAgfQoKICAgIGZ1bmN0aW9u
IHRhYkluZGV4KHRhYikgewogICAgICAgIGNvbnN0IGkgPSBUQUJfT1JERVIuaW5kZXhPZih0YWIpOwog
ICAgICAgIHJldHVybiBpID49IDAgPyBpIDogMDsKICAgIH0KCiAgICBmdW5jdGlvbiBtb3ZlVGFiSW5r
KGluc3RhbnQsIHRhcmdldEVsKSB7CiAgICAgICAgY29uc3QgaW5rID0gZG9jdW1lbnQuZ2V0RWxlbWVu
dEJ5SWQoJ3RhYi1pbmsnKTsKICAgICAgICBjb25zdCB0YWJzID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5
SWQoJ3RhYnMnKTsKICAgICAgICBjb25zdCBlbCA9IHRhcmdldEVsIHx8IGRvY3VtZW50LnF1ZXJ5U2Vs
ZWN0b3IoJyN0YWJzIC50YWIub24nKTsKICAgICAgICBpZiAoIWluayB8fCAhdGFicyB8fCAhZWwpIHJl
dHVybjsKICAgICAgICBjb25zdCB0ciA9IHRhYnMuZ2V0Qm91bmRpbmdDbGllbnRSZWN0KCk7CiAgICAg
ICAgY29uc3QgciA9IGVsLmdldEJvdW5kaW5nQ2xpZW50UmVjdCgpOwogICAgICAgIGNvbnN0IHggPSBy
LmxlZnQgLSB0ci5sZWZ0OwogICAgICAgIGNvbnN0IGggPSBNYXRoLm1heCgyMCwgTWF0aC5yb3VuZChy
LmhlaWdodCkpOwogICAgICAgIGNvbnN0IHkgPSByLnRvcCAtIHRyLnRvcDsKICAgICAgICBjb25zdCB3
ID0gTWF0aC5tYXgoMjQsIHIud2lkdGgpOwogICAgICAgIGNvbnN0IHBvcyA9ICd0cmFuc2xhdGUzZCgn
ICsgeCArICdweCwnICsgeSArICdweCwwKSc7CiAgICAgICAgaW5rLnN0eWxlLnRyYW5zZm9ybU9yaWdp
biA9ICdjZW50ZXIgYm90dG9tJzsKICAgICAgICBpbmsuc3R5bGUud2lkdGggPSB3ICsgJ3B4JzsKICAg
ICAgICBpbmsuc3R5bGUuaGVpZ2h0ID0gaCArICdweCc7CiAgICAgICAgaWYgKGluc3RhbnQpIHsKICAg
ICAgICAgICAgaW5rLnN0eWxlLnRyYW5zaXRpb24gPSAnbm9uZSc7CiAgICAgICAgICAgIGluay5jbGFz
c0xpc3QucmVtb3ZlKCdzcXVhc2gnKTsKICAgICAgICAgICAgaW5rLnN0eWxlLnRyYW5zZm9ybSA9IHBv
cyArICcgc2NhbGVYKDEpJzsKICAgICAgICAgICAgaW5rLm9mZnNldEhlaWdodDsKICAgICAgICAgICAg
aW5rLnN0eWxlLnRyYW5zaXRpb24gPSAnJzsKICAgICAgICAgICAgcmV0dXJuOwogICAgICAgIH0KICAg
ICAgICAvLyBTbmFwIHRvIGhvdmVyZWQgdGFiLCBleHBhbmQgZnJvbSBib3R0b20tY2VudGVyIOKAlCBu
byBzbGlkaW5nIGJldHdlZW4gdGFicwogICAgICAgIGluay5zdHlsZS50cmFuc2l0aW9uID0gJ25vbmUn
OwogICAgICAgIGluay5zdHlsZS50cmFuc2Zvcm0gPSBwb3MgKyAnIHNjYWxlWCgwLjAwMSknOwogICAg
ICAgIGluay5vZmZzZXRIZWlnaHQ7CiAgICAgICAgaW5rLnN0eWxlLnRyYW5zaXRpb24gPSAnJzsKICAg
ICAgICBpbmsuY2xhc3NMaXN0LmFkZCgnc3F1YXNoJyk7CiAgICAgICAgaW5rLnN0eWxlLnRyYW5zZm9y
bSA9IHBvcyArICcgc2NhbGVYKDEpJzsKICAgICAgICBjbGVhclRpbWVvdXQoaW5rLl9zcXVhc2hUaW1l
cik7CiAgICAgICAgaW5rLl9zcXVhc2hUaW1lciA9IHNldFRpbWVvdXQoKCkgPT4gaW5rLmNsYXNzTGlz
dC5yZW1vdmUoJ3NxdWFzaCcpLCAzNDApOwogICAgfQogICAgZnVuY3Rpb24gbWFya1RhYih0YWIsIGlu
c3RhbnQpIHsKICAgICAgICBkb2N1bWVudC5xdWVyeVNlbGVjdG9yQWxsKCcjdGFicyAudGFiJykuZm9y
RWFjaChlbCA9PgogICAgICAgICAgICBlbC5jbGFzc0xpc3QudG9nZ2xlKCdvbicsIGVsLmRhdGFzZXQu
dGFiID09PSB0YWIpKTsKICAgICAgICBtb3ZlVGFiSW5rKCEhaW5zdGFudCk7CiAgICB9CiAgICBmdW5j
dGlvbiBiaW5kVGFiSW5rSG92ZXIoKSB7CiAgICAgICAgY29uc3QgdGFicyA9IGRvY3VtZW50LmdldEVs
ZW1lbnRCeUlkKCd0YWJzJyk7CiAgICAgICAgaWYgKCF0YWJzIHx8IHRhYnMuX2lua0hvdmVyQm91bmQp
IHJldHVybjsKICAgICAgICB0YWJzLl9pbmtIb3ZlckJvdW5kID0gdHJ1ZTsKICAgICAgICB0YWJzLmFk
ZEV2ZW50TGlzdGVuZXIoJ3BvaW50ZXJvdmVyJywgZSA9PiB7CiAgICAgICAgICAgIGNvbnN0IHRhYiA9
IGUudGFyZ2V0LmNsb3Nlc3QoJy50YWInKTsKICAgICAgICAgICAgaWYgKCF0YWIgfHwgIXRhYnMuY29u
dGFpbnModGFiKSkgcmV0dXJuOwogICAgICAgICAgICBtb3ZlVGFiSW5rKGZhbHNlLCB0YWIpOwogICAg
ICAgIH0pOwogICAgICAgIHRhYnMuYWRkRXZlbnRMaXN0ZW5lcigncG9pbnRlcmxlYXZlJywgZSA9PiB7
CiAgICAgICAgICAgIGlmIChlLnJlbGF0ZWRUYXJnZXQgJiYgdGFicy5jb250YWlucyhlLnJlbGF0ZWRU
YXJnZXQpKSByZXR1cm47CiAgICAgICAgICAgIG1vdmVUYWJJbmsoZmFsc2UpOwogICAgICAgIH0pOwog
ICAgfQpmdW5jdGlvbiBzZXRUYWIodGFiKSB7CiAgICAgICAgaWYgKHRhYiA9PT0gY3VyVGFiKSByZXR1
cm47CiAgICAgICAgY29uc3QgZnJvbSA9IHRhYkluZGV4KGN1clRhYik7CiAgICAgICAgY29uc3QgdG8g
PSB0YWJJbmRleCh0YWIpOwogICAgICAgIHRhYlN3aXRjaEFuaW1EaXIgPSB0byA+IGZyb20gPyAxIDog
KHRvIDwgZnJvbSA/IC0xIDogMCk7CiAgICAgICAgY3VyVGFiID0gdGFiOwogICAgICAgIGxvYWRpbmdN
b3JlID0gZmFsc2U7CiAgICAgICAgbWFya1RhYih0YWIpOwoKICAgICAgICAvLyBLZWVwIHNlYXJjaCAi
dG9kYXkiIGZpbHRlciBpbiBzeW5jIHdoZW4gc2VhcmNoIGlzIG9wZW4KICAgICAgICB0cnkgewogICAg
ICAgICAgICBjb25zdCB3cmFwID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NlYXJjaC13cmFwJyk7
CiAgICAgICAgICAgIGNvbnN0IGJ0blRvZGF5ID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2J0bi10
b2RheScpOwogICAgICAgICAgICBpZiAod3JhcCAmJiB3cmFwLmNsYXNzTGlzdC5jb250YWlucygnb3Bl
bicpKSB7CiAgICAgICAgICAgICAgICBjb25zdCB3YW50VG9kYXkgPSBmYWxzZTsKICAgICAgICAgICAg
ICAgIGlmICh0b2RheU9ubHkgIT09IHdhbnRUb2RheSkgewogICAgICAgICAgICAgICAgICAgIHRvZGF5
T25seSA9IHdhbnRUb2RheTsKICAgICAgICAgICAgICAgICAgICBpZiAoYnRuVG9kYXkpIGJ0blRvZGF5
LmNsYXNzTGlzdC50b2dnbGUoJ29uJywgdG9kYXlPbmx5KTsKICAgICAgICAgICAgICAgIH0KICAgICAg
ICAgICAgfQogICAgICAgIH0gY2F0Y2gge30KCiAgICAgICAgc2VsZWN0ZWRJZCA9IG51bGw7CiAgICAg
ICAgbXVsdGlJZHMgPSBbXTsKICAgICAgICBsaXN0RWwuc2Nyb2xsVG9wID0gMDsKICAgICAgICBjb25z
dCBoaXQgPSB2aWV3TWVtLmdldCh2aWV3TWVtS2V5KHRhYiwgcXVlcnksIHRvZGF5T25seSkpOwogICAg
ICAgIGlmIChoaXQgJiYgQXJyYXkuaXNBcnJheShoaXQuaXRlbXMpICYmIGhpdC5pdGVtcy5sZW5ndGgp
IHsKICAgICAgICAgICAgYWxsQ2xpcHMgPSBoaXQuaXRlbXMuc2xpY2UoKTsKICAgICAgICAgICAgZGlz
a1RvdGFsID0gTnVtYmVyKGhpdC50b3RhbCkgfHwgaGl0Lml0ZW1zLmxlbmd0aDsKICAgICAgICAgICAg
d2luZG93Ll9fd2FpdGluZ1ZpZXcgPSBmYWxzZTsKICAgICAgICAgICAgY2xlYXJXYWl0aW5nRGF0YSgp
OwogICAgICAgICAgICB3aW5kb3cuX19kYXRhUmVhZHkgPSB0cnVlOwogICAgICAgICAgICBob3N0UHVz
aGVkT25jZSA9IHRydWU7CiAgICAgICAgICAgIHNhd05vbkVtcHR5ID0gdHJ1ZTsKICAgICAgICAgICAg
cmVuZGVyKCk7CiAgICAgICAgICAgIGFwcGx5VGFiU3dpdGNoQW5pbSgpOwogICAgICAgICAgICAvLyBN
ZW1vcnkgcGFpbnQgZmlyc3Qg4oCUYmFja2dyb3VuZCBzb2Z0LXN5bmMga2VlcHMgQUhLIGluIHN0ZXAg
d2l0aG91dCBkb3VibGUgcmVkcmF3CiAgICAgICAgICAgIHNvZnRSZXF1ZXN0VmlldygpOwogICAgICAg
ICAgICByZXR1cm47CiAgICAgICAgfQogICAgICAgIGFsbENsaXBzID0gW107CiAgICAgICAgZGlza1Rv
dGFsID0gMDsKICAgICAgICB3aW5kb3cuX193YWl0aW5nVmlldyA9IHRydWU7CiAgICAgICAgc2NoZWR1
bGVEZWxheWVkU2tlbCgpOwogICAgICAgIHJlcXVlc3RWaWV3KCk7CiAgICAgICAgcmVuZGVyKCk7CiAg
ICAgICAgYXBwbHlUYWJTd2l0Y2hBbmltKCk7CiAgICB9CgogICAgbW92ZVRhYkluayh0cnVlKTsKICAg
IGJpbmRUYWJJbmtIb3ZlcigpOwogICAgdHJ5IHsgbmV3IFJlc2l6ZU9ic2VydmVyKCgpID0+IG1vdmVU
YWJJbmsodHJ1ZSkpLm9ic2VydmUoZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3RhYnMnKSk7IH0gY2F0
Y2gge30KICAgIHdpbmRvdy5hZGRFdmVudExpc3RlbmVyKCdyZXNpemUnLCAoKSA9PiBtb3ZlVGFiSW5r
KHRydWUpKTsKCiAgICBmdW5jdGlvbiB1cGRhdGVNb3JlRm9vdGVyKHRvdGFsKSB7CiAgICAgICAgbGV0
IG1vcmVFbCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdsaXN0LW1vcmUnKTsKICAgICAgICBjb25z
dCBsb2FkZWQgPSBhbGxDbGlwcy5sZW5ndGg7CiAgICAgICAgaWYgKGxvYWRlZCA+PSB0b3RhbCkgewog
ICAgICAgICAgICBpZiAobW9yZUVsKSBtb3JlRWwucmVtb3ZlKCk7CiAgICAgICAgICAgIHJldHVybjsK
ICAgICAgICB9CiAgICAgICAgaWYgKCFtb3JlRWwpIHsKICAgICAgICAgICAgbW9yZUVsID0gZG9jdW1l
bnQuY3JlYXRlRWxlbWVudCgnZGl2Jyk7CiAgICAgICAgICAgIG1vcmVFbC5pZCA9ICdsaXN0LW1vcmUn
OwogICAgICAgICAgICBtb3JlRWwuY2xhc3NOYW1lID0gJ2xpc3QtbW9yZSc7CiAgICAgICAgICAgIGxp
c3RFbC5hcHBlbmRDaGlsZChtb3JlRWwpOwogICAgICAgIH0KICAgICAgICBtb3JlRWwudGV4dENvbnRl
bnQgPSAn57un57ut5LiL5ruR5LuO56OB55uY5Yqg6L2977yIJyArIGxvYWRlZCArICcvJyArIHRvdGFs
ICsgJ++8iSc7CiAgICB9CgogICAgLyoqIFVwZGF0ZSBiYXIgLyBwaW4gYmFkZ2Ugd2l0aG91dCB0b3Vj
aGluZyB0aGUgbGlzdCBET00gKi8KICAgIGZ1bmN0aW9uIHJlZnJlc2hMaXN0Q2hyb21lKCkgewogICAg
ICAgIGNvbnN0IHZpc2libGUgPSB2aXNpYmxlTGlzdCgpOwogICAgICAgIGNvbnN0IGxvYWRlZCA9IGFs
bENsaXBzLmxlbmd0aDsKICAgICAgICBjb25zdCBzaG93bkNvdW50ID0gdmlzaWJsZS5sZW5ndGg7CiAg
ICAgICAgbGV0IHBpbm5lZE4gPSBOdW1iZXIocGlubmVkVG90YWwpIHx8IDA7CiAgICAgICAgaWYgKHBp
bm5lZE4gPCAxKSB7CiAgICAgICAgICAgIGlmIChjdXJUYWIgPT09ICdwaW5uZWQnKQogICAgICAgICAg
ICAgICAgcGlubmVkTiA9IE1hdGgubWF4KE51bWJlcihkaXNrVG90YWwpIHx8IDAsIGxvYWRlZCk7CiAg
ICAgICAgICAgIGVsc2UKICAgICAgICAgICAgICAgIHBpbm5lZE4gPSBhbGxDbGlwcy5maWx0ZXIoYyA9
PiBpc1Bpbm5lZChjKSkubGVuZ3RoOwogICAgICAgIH0KICAgICAgICBjb25zdCBwaW5DbnQgPSBkb2N1
bWVudC5nZXRFbGVtZW50QnlJZCgncGluLWNudCcpOwogICAgICAgIGlmIChwaW5DbnQpIHsKICAgICAg
ICAgICAgcGluQ250LnRleHRDb250ZW50ID0gcGlubmVkTjsKICAgICAgICAgICAgcGluQ250LnN0eWxl
LmRpc3BsYXkgPSBwaW5uZWROID8gJycgOiAnbm9uZSc7CiAgICAgICAgfQogICAgICAgIGxldCBzaG93
VG90YWwgPSBkaXNrVG90YWwgPiAwID8gZGlza1RvdGFsIDogKGxvYWRlZCB8fCAwKTsKICAgICAgICBp
ZiAoY3VyVGFiID09PSAncGlubmVkJyAmJiBwaW5uZWROID4gc2hvd1RvdGFsKQogICAgICAgICAgICBz
aG93VG90YWwgPSBwaW5uZWROOwogICAgICAgIGNvbnN0IHFPbiA9IFN0cmluZyhxdWVyeSB8fCAnJyku
dHJpbSgpLmxlbmd0aCA+IDA7CiAgICAgICAgY29uc3QgYmFyID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5
SWQoJ2Jhci10eHQnKTsKICAgICAgICBpZiAoYmFyKSB7CiAgICAgICAgICAgIGJhci50ZXh0Q29udGVu
dCA9IHFPbgogICAgICAgICAgICAgICAgPyAoc2hvd25Db3VudCArICcg5p2hJykKICAgICAgICAgICAg
ICAgIDogKHNob3dUb3RhbCA+IGxvYWRlZCA/IChzaG93bkNvdW50ICsgJyAvICcgKyBzaG93VG90YWwg
KyAnIOadoScpIDogKHNob3dUb3RhbCArICcg5p2hJykpOwogICAgICAgIH0KICAgICAgICB1cGRhdGVN
b3JlRm9vdGVyKGRpc2tUb3RhbCk7CiAgICAgICAgdXBkYXRlVG9wQnRuKCk7CiAgICB9CgogICAgLyoq
CiAgICAgKiBMb2FkLW1vcmU6IGFwcGVuZCBvbmx5IG5ldyBET00gbm9kZXMuIEZ1bGwgcmVuZGVyKCkg
bnVrZXMgZXZlcnkgLml0bSBhbmQKICAgICAqIHJlc3RvcmVzIHNjcm9sbFRvcCDigJQgdGhhdCBoaXRj
aCBpcyB3aGF0IG1ha2VzIGRyYWdnaW5nIHRoZSBzY3JvbGxiYXIgZmVlbCBzdGlja3kuCiAgICAgKi8K
ICAgIGZ1bmN0aW9uIGFwcGVuZFJlbmRlcihwcmV2TGVuKSB7CiAgICAgICAgY29uc3QgdmlzaWJsZSA9
IHZpc2libGVMaXN0KCk7CiAgICAgICAgaWYgKCF2aXNpYmxlLmxlbmd0aCkgewogICAgICAgICAgICBy
ZW5kZXIoKTsKICAgICAgICAgICAgcmV0dXJuIGZhbHNlOwogICAgICAgIH0KICAgICAgICBpZiAocHJl
dkxlbiA+IDAgJiYgcHJldkxlbiA8IGFsbENsaXBzLmxlbmd0aCkgewogICAgICAgICAgICBjb25zdCBz
ZWFtR2lkcyA9IG5ldyBTZXQoKTsKICAgICAgICAgICAgZm9yIChsZXQgaSA9IE1hdGgubWF4KDAsIHBy
ZXZMZW4gLSA4KTsgaSA8IE1hdGgubWluKGFsbENsaXBzLmxlbmd0aCwgcHJldkxlbiArIDgpOyBpKysp
IHsKICAgICAgICAgICAgICAgIGNvbnN0IGcgPSBmYXZHcm91cE9mKGFsbENsaXBzW2ldKTsKICAgICAg
ICAgICAgICAgIGlmIChnKSBzZWFtR2lkcy5hZGQoZyk7CiAgICAgICAgICAgIH0KICAgICAgICAgICAg
aWYgKHNlYW1HaWRzLnNpemUpIHsKICAgICAgICAgICAgICAgIGZvciAoY29uc3QgZyBvZiBzZWFtR2lk
cykgewogICAgICAgICAgICAgICAgICAgIGxldCBiZWZvcmUgPSAwLCBhZnRlciA9IDA7CiAgICAgICAg
ICAgICAgICAgICAgZm9yIChsZXQgaSA9IDA7IGkgPCBhbGxDbGlwcy5sZW5ndGg7IGkrKykgewogICAg
ICAgICAgICAgICAgICAgICAgICBpZiAoZmF2R3JvdXBPZihhbGxDbGlwc1tpXSkgIT09IGcpIGNvbnRp
bnVlOwogICAgICAgICAgICAgICAgICAgICAgICBpZiAoaSA8IHByZXZMZW4pIGJlZm9yZSsrOwogICAg
ICAgICAgICAgICAgICAgICAgICBlbHNlIGFmdGVyKys7CiAgICAgICAgICAgICAgICAgICAgfQogICAg
ICAgICAgICAgICAgICAgIGlmIChiZWZvcmUgPiAwICYmIGFmdGVyID4gMCkgewogICAgICAgICAgICAg
ICAgICAgICAgICByZW5kZXIoKTsKICAgICAgICAgICAgICAgICAgICAgICAgcmV0dXJuIGZhbHNlOwog
ICAgICAgICAgICAgICAgICAgIH0KICAgICAgICAgICAgICAgIH0KICAgICAgICAgICAgfQogICAgICAg
IH0KICAgICAgICBjb25zdCBibG9ja3MgPSBidWlsZFBpbm5lZEJsb2Nrcyh2aXNpYmxlKTsKICAgICAg
ICBjb25zdCBleGlzdGluZyA9IGxpc3RFbC5xdWVyeVNlbGVjdG9yQWxsKCcuaXRtJykubGVuZ3RoOwog
ICAgICAgIGlmIChleGlzdGluZyA8IDEpIHsKICAgICAgICAgICAgcmVuZGVyKCk7CiAgICAgICAgICAg
IHJldHVybiBmYWxzZTsKICAgICAgICB9CiAgICAgICAgaWYgKGJsb2Nrcy5sZW5ndGggPD0gZXhpc3Rp
bmcpIHsKICAgICAgICAgICAgcmVmcmVzaExpc3RDaHJvbWUoKTsKICAgICAgICAgICAgdHJ5IHsgbWFy
a1F1ZXVlUmFpbHMoKTsgfSBjYXRjaCAoZSkge30KICAgICAgICAgICAgcmV0dXJuIHRydWU7CiAgICAg
ICAgfQogICAgICAgIGNvbnN0IGZyYWcgPSBkb2N1bWVudC5jcmVhdGVEb2N1bWVudEZyYWdtZW50KCk7
CiAgICAgICAgbGV0IG51bSA9IDA7CiAgICAgICAgYmxvY2tzLmZvckVhY2goYiA9PiB7CiAgICAgICAg
ICAgIG51bSArPSAxOwogICAgICAgICAgICBpZiAobnVtIDw9IGV4aXN0aW5nKSByZXR1cm47CiAgICAg
ICAgICAgIGlmIChiLmtpbmQgPT09ICdncm91cCcgJiYgYi5pdGVtcy5sZW5ndGggPiAxKQogICAgICAg
ICAgICAgICAgZnJhZy5hcHBlbmRDaGlsZChtYWtlR3JvdXBJdGVtKGIuaXRlbXMsIG51bSkpOwogICAg
ICAgICAgICBlbHNlCiAgICAgICAgICAgICAgICBmcmFnLmFwcGVuZENoaWxkKG1ha2VJdGVtKGIuaXRl
bXNbMF0sIG51bSkpOwogICAgICAgIH0pOwogICAgICAgIGNvbnN0IG1vcmVFbCA9IGRvY3VtZW50Lmdl
dEVsZW1lbnRCeUlkKCdsaXN0LW1vcmUnKTsKICAgICAgICBpZiAobW9yZUVsKQogICAgICAgICAgICBs
aXN0RWwuaW5zZXJ0QmVmb3JlKGZyYWcsIG1vcmVFbCk7CiAgICAgICAgZWxzZQogICAgICAgICAgICBs
aXN0RWwuYXBwZW5kQ2hpbGQoZnJhZyk7CiAgICAgICAgdHJ5IHsgbWFya1F1ZXVlUmFpbHMoKTsgfSBj
YXRjaCAoZSkge30KICAgICAgICByZWZyZXNoTGlzdENocm9tZSgpOwogICAgICAgIHJlcXVlc3RBbmlt
YXRpb25GcmFtZSgoKSA9PiB7CiAgICAgICAgICAgIGlmIChhbGxDbGlwcy5sZW5ndGggPCBkaXNrVG90
YWwKICAgICAgICAgICAgICAgICYmIGxpc3RFbC5zY3JvbGxIZWlnaHQgPD0gbGlzdEVsLmNsaWVudEhl
aWdodCArIDIwKQogICAgICAgICAgICAgICAgcmVxdWVzdE1vcmUoKTsKICAgICAgICAgICAgdHJ5IHsg
c2NoZWR1bGVGaWxlR29uZUNoZWNrKCk7IH0gY2F0Y2gge30KICAgICAgICB9KTsKICAgICAgICByZXR1
cm4gdHJ1ZTsKICAgIH0KCiAgICBmdW5jdGlvbiBhcHBseUFwcGVuZFBheWxvYWQocGVuZGluZykgewog
ICAgICAgIGlmICghcGVuZGluZyB8fCBwZW5kaW5nLmZyb21MZW4gPT0gbnVsbCkgcmV0dXJuOwogICAg
ICAgIGNvbnN0IGZyb21MZW4gPSBOdW1iZXIocGVuZGluZy5mcm9tTGVuKSB8fCAwOwogICAgICAgIGlm
IChmcm9tTGVuIDwgMCB8fCBhbGxDbGlwcy5sZW5ndGggPD0gZnJvbUxlbikgewogICAgICAgICAgICBy
ZWZyZXNoTGlzdENocm9tZSgpOwogICAgICAgICAgICByZXR1cm47CiAgICAgICAgfQogICAgICAgIGFw
cGVuZFJlbmRlcihmcm9tTGVuKTsKICAgIH0KCiAgICBmdW5jdGlvbiBuYXZMaXN0KCkgewogICAgICAg
IGNvbnN0IGJsb2NrcyA9IGJ1aWxkUGlubmVkQmxvY2tzKHZpc2libGVMaXN0KCkpOwogICAgICAgIGNv
bnN0IG91dCA9IFtdOwogICAgICAgIGZvciAoY29uc3QgYiBvZiBibG9ja3MpIHsKICAgICAgICAgICAg
aWYgKCFiIHx8ICFiLml0ZW1zKSBjb250aW51ZTsKICAgICAgICAgICAgZm9yIChjb25zdCBjIG9mIGIu
aXRlbXMpIG91dC5wdXNoKGMpOwogICAgICAgIH0KICAgICAgICByZXR1cm4gb3V0OwogICAgfQoKICAg
IGZ1bmN0aW9uIHNlbGVjdEJ5SW5kZXgoaWR4KSB7CiAgICAgICAgY29uc3QgdmlzID0gbmF2TGlzdCgp
OwogICAgICAgIGlmICghdmlzLmxlbmd0aCkgcmV0dXJuOwogICAgICAgIGlkeCA9IE1hdGgubWF4KDAs
IE1hdGgubWluKHZpcy5sZW5ndGggLSAxLCBpZHgpKTsKICAgICAgICBpZiAoaWR4ID49IHZpcy5sZW5n
dGggLSAxICYmIGFsbENsaXBzLmxlbmd0aCA8IGRpc2tUb3RhbCkKICAgICAgICAgICAgcmVxdWVzdE1v
cmUoKTsKICAgICAgICBzZWxlY3RlZElkID0gdmlzW01hdGgubWluKGlkeCwgdmlzLmxlbmd0aCAtIDEp
XS5pZDsKICAgICAgICByYW5nZUFuY2hvcklkID0gc2VsZWN0ZWRJZDsKICAgICAgICByYW5nZUFuY2hv
ckNsaWNrZWQgPSBmYWxzZTsKICAgICAgICBpZiAoK3NlbGVjdGVkSWQgIT09ICtsYXN0UGFzdGVJZCkK
ICAgICAgICAgICAgbG9jYXRlQWN0aXZlID0gZmFsc2U7CiAgICAgICAgdXBkYXRlTG9jYXRlQnRuKCk7
CiAgICAgICAgc3luY0l0ZW1IaWdobGlnaHQoKTsKICAgICAgICBjb25zdCBlbCA9IGxpc3RFbC5xdWVy
eVNlbGVjdG9yKCcubWctcm93W2RhdGEtaWQ9IicgKyBzZWxlY3RlZElkICsgJyJdJykKICAgICAgICAg
ICAgfHwgbGlzdEVsLnF1ZXJ5U2VsZWN0b3IoJy5pdG1bZGF0YS1pZD0iJyArIHNlbGVjdGVkSWQgKyAn
Il0nKTsKICAgICAgICBpZiAoZWwpIGVsLnNjcm9sbEludG9WaWV3KHsgYmxvY2s6ICduZWFyZXN0JyB9
KTsKICAgIH0KCiAgICBmdW5jdGlvbiBzZWxlY3RlZEluZGV4KCkgewogICAgICAgIHJldHVybiBuYXZM
aXN0KCkuZmluZEluZGV4KGMgPT4gYy5pZCA9PSBzZWxlY3RlZElkKTsKICAgIH0KCiAgICBmdW5jdGlv
biBzeW5jSXRlbUhpZ2hsaWdodCgpIHsKICAgICAgICBkb2N1bWVudC5xdWVyeVNlbGVjdG9yQWxsKCcu
aXRtJykuZm9yRWFjaChuID0+IHsKICAgICAgICAgICAgaWYgKG4uY2xhc3NMaXN0LmNvbnRhaW5zKCdp
dC1ncm91cCcpKSB7CiAgICAgICAgICAgICAgICBjb25zdCByb3dzID0gWy4uLm4ucXVlcnlTZWxlY3Rv
ckFsbCgnLm1nLXJvdycpXTsKICAgICAgICAgICAgICAgIGNvbnN0IGlkcyA9IHJvd3MubWFwKHIgPT4g
K3IuZGF0YXNldC5pZCk7CiAgICAgICAgICAgICAgICBjb25zdCBhbnlTZWwgPSBpZHMuaW5jbHVkZXMo
K3NlbGVjdGVkSWQpIHx8IGlkcy5zb21lKGlkID0+IG11bHRpSWRzLmluY2x1ZGVzKGlkKSk7CiAgICAg
ICAgICAgICAgICBuLmNsYXNzTGlzdC50b2dnbGUoJ3NlbCcsIGFueVNlbCk7CiAgICAgICAgICAgICAg
ICBuLmNsYXNzTGlzdC50b2dnbGUoJ211bHRpJywgaWRzLnNvbWUoaWQgPT4gbXVsdGlJZHMuaW5jbHVk
ZXMoaWQpKSk7CiAgICAgICAgICAgICAgICByb3dzLmZvckVhY2gociA9PiB7CiAgICAgICAgICAgICAg
ICAgICAgY29uc3QgaWQgPSArci5kYXRhc2V0LmlkOwogICAgICAgICAgICAgICAgICAgIGNvbnN0IGlu
TXVsdGkgPSBtdWx0aUlkcy5pbmNsdWRlcyhpZCk7CiAgICAgICAgICAgICAgICAgICAgci5jbGFzc0xp
c3QudG9nZ2xlKCdzZWwnLCBpZCA9PSBzZWxlY3RlZElkIHx8IGluTXVsdGkpOwogICAgICAgICAgICAg
ICAgICAgIHIuY2xhc3NMaXN0LnRvZ2dsZSgnbXVsdGknLCBpbk11bHRpKTsKICAgICAgICAgICAgICAg
IH0pOwogICAgICAgICAgICAgICAgcmV0dXJuOwogICAgICAgICAgICB9CiAgICAgICAgICAgIGNvbnN0
IGlkID0gK24uZGF0YXNldC5pZDsKICAgICAgICAgICAgY29uc3QgaW5NdWx0aSA9IG11bHRpSWRzLmlu
Y2x1ZGVzKGlkKTsKICAgICAgICAgICAgbi5jbGFzc0xpc3QudG9nZ2xlKCdzZWwnLCBpZCA9PSBzZWxl
Y3RlZElkIHx8IGluTXVsdGkpOwogICAgICAgICAgICBuLmNsYXNzTGlzdC50b2dnbGUoJ211bHRpJywg
aW5NdWx0aSk7CiAgICAgICAgfSk7CiAgICB9CiAgICBmdW5jdGlvbiB1cGRhdGVNdWx0aUJhZGdlKCkg
ewogICAgICAgIGNvbnN0IGVsID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ211bHRpLWNudCcpOwog
ICAgICAgIGlmIChtdWx0aUlkcy5sZW5ndGggPiAwKSB7CiAgICAgICAgICAgIGVsLnRleHRDb250ZW50
ID0gU3RyaW5nKG11bHRpSWRzLmxlbmd0aCk7CiAgICAgICAgICAgIGVsLmNsYXNzTGlzdC5hZGQoJ29u
Jyk7CiAgICAgICAgfSBlbHNlIHsKICAgICAgICAgICAgZWwuY2xhc3NMaXN0LnJlbW92ZSgnb24nKTsK
ICAgICAgICB9CiAgICAgICAgc3luY0l0ZW1IaWdobGlnaHQoKTsKICAgIH0KCiAgICBmdW5jdGlvbiBj
bGVhck11bHRpKHJlc3RvcmVUb0FuY2hvcikgewogICAgICAgIGNvbnN0IGJhY2tJZCA9ICtyYW5nZUFu
Y2hvcklkIHx8IDA7CiAgICAgICAgbXVsdGlJZHMgPSBbXTsKICAgICAgICBpZiAocmVzdG9yZVRvQW5j
aG9yICYmIGJhY2tJZCkKICAgICAgICAgICAgc2VsZWN0ZWRJZCA9IGJhY2tJZDsKICAgICAgICByYW5n
ZUFuY2hvcklkID0gc2VsZWN0ZWRJZCB8fCAwOwogICAgICAgIHJhbmdlQW5jaG9yQ2xpY2tlZCA9IGZh
bHNlOwogICAgICAgIHVwZGF0ZU11bHRpQmFkZ2UoKTsKICAgICAgICBpZiAocmVzdG9yZVRvQW5jaG9y
ICYmIHNlbGVjdGVkSWQpIHsKICAgICAgICAgICAgY29uc3QgZWwgPSBsaXN0RWwucXVlcnlTZWxlY3Rv
cignLm1nLXJvd1tkYXRhLWlkPSInICsgc2VsZWN0ZWRJZCArICciXScpCiAgICAgICAgICAgICAgICB8
fCBsaXN0RWwucXVlcnlTZWxlY3RvcignLml0bVtkYXRhLWlkPSInICsgc2VsZWN0ZWRJZCArICciXScp
OwogICAgICAgICAgICBpZiAoZWwpIGVsLnNjcm9sbEludG9WaWV3KHsgYmxvY2s6ICduZWFyZXN0JyB9
KTsKICAgICAgICB9CiAgICB9CgoKICAgIC8qIHNoaWZ0LXJhbmdlLXNlbGVjdC12MSAqLwogICAgbGV0
IHJhbmdlQW5jaG9ySWQgPSAwOwogICAgbGV0IHJhbmdlQW5jaG9yQ2xpY2tlZCA9IGZhbHNlOwogICAg
ZnVuY3Rpb24gc2VsZWN0UmFuZ2VUbyhpZCkgewogICAgICAgIGlkID0gK2lkOwogICAgICAgIGNvbnN0
IGxpc3QgPSAodHlwZW9mIG5hdkxpc3QgPT09ICdmdW5jdGlvbicgPyBuYXZMaXN0KCkgOiB2aXNpYmxl
TGlzdCgpKTsKICAgICAgICBjb25zdCBiID0gbGlzdC5maW5kSW5kZXgoYyA9PiArYy5pZCA9PT0gaWQp
OwogICAgICAgIGlmIChiIDwgMCkgcmV0dXJuOwogICAgICAgIGxldCBhbmNob3IgPSArcmFuZ2VBbmNo
b3JJZDsKICAgICAgICBsZXQgYSA9IGxpc3QuZmluZEluZGV4KGMgPT4gK2MuaWQgPT09IGFuY2hvcik7
CiAgICAgICAgaWYgKGEgPCAwKSB7CiAgICAgICAgICAgIGFuY2hvciA9ICtzZWxlY3RlZElkIHx8IGlk
OwogICAgICAgICAgICBhID0gbGlzdC5maW5kSW5kZXgoYyA9PiArYy5pZCA9PT0gYW5jaG9yKTsKICAg
ICAgICB9CiAgICAgICAgaWYgKGEgPCAwKSB7CiAgICAgICAgICAgIHJhbmdlQW5jaG9ySWQgPSBpZDsg
c2VsZWN0ZWRJZCA9IGlkOyBtdWx0aUlkcyA9IFtpZF07IHVwZGF0ZU11bHRpQmFkZ2UoKTsgcmV0dXJu
OwogICAgICAgIH0KICAgICAgICBpZiAoIXJhbmdlQW5jaG9ySWQgfHwgbGlzdC5maW5kSW5kZXgoYyA9
PiArYy5pZCA9PT0gK3JhbmdlQW5jaG9ySWQpIDwgMCkKICAgICAgICAgICAgcmFuZ2VBbmNob3JJZCA9
IGxpc3RbYV0uaWQ7CiAgICAgICAgY29uc3QgbG8gPSBNYXRoLm1pbihhLCBiKSwgaGkgPSBNYXRoLm1h
eChhLCBiKTsKICAgICAgICBtdWx0aUlkcyA9IFtdOwogICAgICAgIGZvciAobGV0IGkgPSBsbzsgaSA8
PSBoaTsgaSsrKSBtdWx0aUlkcy5wdXNoKCtsaXN0W2ldLmlkKTsKICAgICAgICBzZWxlY3RlZElkID0g
aWQ7CiAgICAgICAgdXBkYXRlTXVsdGlCYWRnZSgpOwogICAgICAgIGNvbnN0IGVsID0gbGlzdEVsLnF1
ZXJ5U2VsZWN0b3IoJy5tZy1yb3dbZGF0YS1pZD0iJyArIHNlbGVjdGVkSWQgKyAnIl0nKSB8fCBsaXN0
RWwucXVlcnlTZWxlY3RvcignLml0bVtkYXRhLWlkPSInICsgc2VsZWN0ZWRJZCArICciXScpOwogICAg
ICAgIGlmIChlbCkgZWwuc2Nyb2xsSW50b1ZpZXcoeyBibG9jazogJ25lYXJlc3QnIH0pOwogICAgfQog
ICAgZnVuY3Rpb24gc2hvd1NyY1RpcChhbmNob3IsIHRleHQpIHsKICAgICAgICB0ZXh0ID0gU3RyaW5n
KHRleHQgfHwgJycpLnRyaW0oKTsKICAgICAgICBpZiAoIXRleHQpIHJldHVybjsKICAgICAgICBsZXQg
dGlwID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NyYy10aXAnKTsKICAgICAgICBpZiAoIXRpcCkg
ewogICAgICAgICAgICB0aXAgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsKICAgICAgICAg
ICAgdGlwLmlkID0gJ3NyYy10aXAnOwogICAgICAgICAgICBkb2N1bWVudC5ib2R5LmFwcGVuZENoaWxk
KHRpcCk7CiAgICAgICAgfQogICAgICAgIHRpcC50ZXh0Q29udGVudCA9IHRleHQ7CiAgICAgICAgdGlw
LmNsYXNzTGlzdC5hZGQoJ3Nob3cnKTsKICAgICAgICBjb25zdCByID0gYW5jaG9yLmdldEJvdW5kaW5n
Q2xpZW50UmVjdCgpOwogICAgICAgIGNvbnN0IHR3ID0gdGlwLm9mZnNldFdpZHRoIHx8IDE2MDsKICAg
ICAgICBjb25zdCB0aCA9IHRpcC5vZmZzZXRIZWlnaHQgfHwgMjg7CiAgICAgICAgbGV0IGxlZnQgPSBy
LnJpZ2h0IC0gdHc7CiAgICAgICAgbGV0IHRvcCA9IHIudG9wIC0gdGggLSA4OwogICAgICAgIGlmIChs
ZWZ0IDwgOCkgbGVmdCA9IDg7CiAgICAgICAgaWYgKGxlZnQgKyB0dyA+IHdpbmRvdy5pbm5lcldpZHRo
IC0gOCkgbGVmdCA9IHdpbmRvdy5pbm5lcldpZHRoIC0gdHcgLSA4OwogICAgICAgIGlmICh0b3AgPCA4
KSB0b3AgPSByLmJvdHRvbSArIDg7CiAgICAgICAgdGlwLnN0eWxlLmxlZnQgPSBsZWZ0ICsgJ3B4JzsK
ICAgICAgICB0aXAuc3R5bGUudG9wID0gdG9wICsgJ3B4JzsKICAgICAgICBjbGVhclRpbWVvdXQodGlw
Ll9oaWRlVCk7CiAgICAgICAgdGlwLl9oaWRlVCA9IHNldFRpbWVvdXQoKCkgPT4gdGlwLmNsYXNzTGlz
dC5yZW1vdmUoJ3Nob3cnKSwgMjIwMCk7CiAgICB9CiAgICAvKiBpbWctaG92ZXItcHJldmlldy12OCAq
LwogICAgbGV0IF9faW1nSG92ZXJUaW1lciA9IDAsIF9faW1nSG92ZXJIaWRlVGltZXIgPSAwLCBfX2lt
Z0hvdmVyS2V5ID0gJyc7CiAgICBmdW5jdGlvbiBfX2ltZ0hvdmVyRW5zdXJlKCkgewogICAgICAgIGxl
dCBib3ggPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnaW1nLWhvdmVyLXNpZGUnKTsKICAgICAgICBp
ZiAoIWJveCkgewogICAgICAgICAgICBib3ggPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsg
Ym94LmlkID0gJ2ltZy1ob3Zlci1zaWRlJzsKICAgICAgICAgICAgY29uc3QgZnJhbWUgPSBkb2N1bWVu
dC5jcmVhdGVFbGVtZW50KCdkaXYnKTsgZnJhbWUuY2xhc3NOYW1lID0gJ2locC1mcmFtZSc7CiAgICAg
ICAgICAgIGNvbnN0IGltID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnaW1nJyk7IGltLmFsdCA9ICcn
OwogICAgICAgICAgICBmcmFtZS5hcHBlbmRDaGlsZChpbSk7IGJveC5hcHBlbmRDaGlsZChmcmFtZSk7
IGRvY3VtZW50LmJvZHkuYXBwZW5kQ2hpbGQoYm94KTsKICAgICAgICB9CiAgICAgICAgbGV0IHN0ID0g
ZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2ltZy1ob3Zlci1zaWRlLWNzcycpOwogICAgICAgIGlmICgh
c3QpIHsgc3QgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdzdHlsZScpOyBzdC5pZCA9ICdpbWctaG92
ZXItc2lkZS1jc3MnOyBkb2N1bWVudC5oZWFkLmFwcGVuZENoaWxkKHN0KTsgfQogICAgICAgIHN0LnRl
eHRDb250ZW50ID0gIiNpbWctaG92ZXItc2lkZXtwb3NpdGlvbjpmaXhlZDt6LWluZGV4OjEwMDAwMDty
aWdodDo2cHg7dG9wOjUwJTt0cmFuc2Zvcm06dHJhbnNsYXRlWSgtNTAlKTtwb2ludGVyLWV2ZW50czpu
b25lO29wYWNpdHk6MDt2aXNpYmlsaXR5OmhpZGRlbjttYXgtd2lkdGg6bWluKDYyMHB4LDkydncpO21h
eC1oZWlnaHQ6bWluKDkydmgsOTIwcHgpfSNpbWctaG92ZXItc2lkZS5zaG93e29wYWNpdHk6MTt2aXNp
YmlsaXR5OnZpc2libGV9I2ltZy1ob3Zlci1zaWRlIC5paHAtZnJhbWV7cGFkZGluZzozcHg7YmFja2dy
b3VuZDojZmZmO2JvcmRlcjoxcHggc29saWQgI0M1Q0REQztib3JkZXItcmFkaXVzOjJweDtib3gtc2hh
ZG93OjAgNnB4IDE4cHggcmdiYSg0NCw0Niw1NCwuMTIpfSNpbWctaG92ZXItc2lkZSBpbWd7ZGlzcGxh
eTpibG9jazttYXgtd2lkdGg6bWluKDYxMnB4LDkwdncpO21heC1oZWlnaHQ6bWluKDkwdmgsOTAwcHgp
O3dpZHRoOmF1dG87aGVpZ2h0OmF1dG87b2JqZWN0LWZpdDpjb250YWluO2JhY2tncm91bmQ6I2ZmZn0i
OwogICAgICAgIHJldHVybiBib3g7CiAgICB9CiAgICB3aW5kb3cuX19pbWdIb3ZlclNob3cgPSBmdW5j
dGlvbihmaWxlLCBpZCkgewogICAgICAgIGNvbnN0IGJhcmUgPSBTdHJpbmcoZmlsZSB8fCAnJykuc3Bs
aXQoL1tcXFxcL10vKS5wb3AoKTsgaWYgKCFiYXJlKSByZXR1cm47CiAgICAgICAgY29uc3QgYm94ID0g
X19pbWdIb3ZlckVuc3VyZSgpOyBjb25zdCBpbWcgPSBib3gucXVlcnlTZWxlY3RvcignaW1nJyk7IGlm
ICghaW1nKSByZXR1cm47CiAgICAgICAgYm94LmNsYXNzTGlzdC5hZGQoJ3Nob3cnKTsKICAgICAgICBp
bWcub25lcnJvciA9ICgpID0+IHsKICAgICAgICAgICAgaW1nLm9uZXJyb3IgPSAoKSA9PiB7IGltZy5v
bmVycm9yID0gbnVsbDsgdHJ5IHsgY29uc3QgYyA9IHRodW1iQ2FjaGUgJiYgdGh1bWJDYWNoZS5nZXQo
U3RyaW5nKGlkKSk7IGlmIChjKSBpbWcuc3JjID0gYzsgfSBjYXRjaCAoZSkge30gfTsKICAgICAgICAg
ICAgaW1nLnNyYyA9IFNUT1JFX0JBU0UgKyAndGhfJyArIGJhcmUucmVwbGFjZSgvXC5bXi5dKyQvLCAn
JykgKyAnLmpwZyc7CiAgICAgICAgfTsKICAgICAgICBpbWcub25sb2FkID0gKCkgPT4geyBpbWcub25l
cnJvciA9IG51bGw7IH07CiAgICAgICAgaW1nLmRhdGFzZXQuYmFyZSA9IGJhcmU7IGltZy5zcmMgPSBT
VE9SRV9CQVNFICsgYmFyZTsKICAgIH07CiAgICB3aW5kb3cuX19pbWdIb3ZlckNsZWFyVWkgPSBmdW5j
dGlvbigpIHsKICAgICAgICBfX2ltZ0hvdmVyS2V5ID0gJyc7CiAgICAgICAgaWYgKF9faW1nSG92ZXJU
aW1lcikgeyBjbGVhclRpbWVvdXQoX19pbWdIb3ZlclRpbWVyKTsgX19pbWdIb3ZlclRpbWVyID0gMDsg
fQogICAgICAgIGlmIChfX2ltZ0hvdmVySGlkZVRpbWVyKSB7IGNsZWFyVGltZW91dChfX2ltZ0hvdmVy
SGlkZVRpbWVyKTsgX19pbWdIb3ZlckhpZGVUaW1lciA9IDA7IH0KICAgICAgICBjb25zdCBib3ggPSBk
b2N1bWVudC5nZXRFbGVtZW50QnlJZCgnaW1nLWhvdmVyLXNpZGUnKTsgaWYgKGJveCkgYm94LmNsYXNz
TGlzdC5yZW1vdmUoJ3Nob3cnKTsKICAgICAgICBjb25zdCBpbWcgPSBib3ggJiYgYm94LnF1ZXJ5U2Vs
ZWN0b3IoJ2ltZycpOwogICAgICAgIGlmIChpbWcpIHsgaW1nLm9ubG9hZCA9IG51bGw7IGltZy5vbmVy
cm9yID0gbnVsbDsgaW1nLnJlbW92ZUF0dHJpYnV0ZSgnc3JjJyk7IGRlbGV0ZSBpbWcuZGF0YXNldC5i
YXJlOyB9CiAgICB9OwogICAgd2luZG93Ll9faW1nSG92ZXJIaWRlID0gZnVuY3Rpb24oKSB7IHdpbmRv
dy5fX2ltZ0hvdmVyQ2xlYXJVaSgpOyB9OwogICAgZnVuY3Rpb24gYmluZEltZ0hvdmVyUHJldmlldyhl
bCwgaWQsIGZpbGUpIHsKICAgICAgICBpZiAoIWVsKSByZXR1cm47CiAgICAgICAgY29uc3QgYmFyZSA9
IFN0cmluZyhmaWxlIHx8ICcnKS5zcGxpdCgvW1xcXFwvXS8pLnBvcCgpOyBpZiAoIWJhcmUpIHJldHVy
bjsKICAgICAgICBjb25zdCBrZXkgPSBTdHJpbmcoaWQpICsgJ3wnICsgYmFyZTsKICAgICAgICBlbC5z
dHlsZS5jdXJzb3IgPSAnem9vbS1pbic7CiAgICAgICAgZWwuYWRkRXZlbnRMaXN0ZW5lcignbW91c2Vl
bnRlcicsICgpID0+IHsKICAgICAgICAgICAgaWYgKF9faW1nSG92ZXJIaWRlVGltZXIpIHsgY2xlYXJU
aW1lb3V0KF9faW1nSG92ZXJIaWRlVGltZXIpOyBfX2ltZ0hvdmVySGlkZVRpbWVyID0gMDsgfQogICAg
ICAgICAgICBfX2ltZ0hvdmVyS2V5ID0ga2V5OwogICAgICAgICAgICBpZiAoX19pbWdIb3ZlclRpbWVy
KSBjbGVhclRpbWVvdXQoX19pbWdIb3ZlclRpbWVyKTsKICAgICAgICAgICAgX19pbWdIb3ZlclRpbWVy
ID0gc2V0VGltZW91dCgoKSA9PiB7IGlmIChfX2ltZ0hvdmVyS2V5ID09PSBrZXkpIHRyeSB7IHdpbmRv
dy5fX2ltZ0hvdmVyU2hvdyhiYXJlLCBpZCk7IH0gY2F0Y2ggKGUpIHt9IH0sIDYwKTsKICAgICAgICB9
KTsKICAgICAgICBlbC5hZGRFdmVudExpc3RlbmVyKCdtb3VzZWxlYXZlJywgKCkgPT4gewogICAgICAg
ICAgICBpZiAoX19pbWdIb3ZlclRpbWVyKSB7IGNsZWFyVGltZW91dChfX2ltZ0hvdmVyVGltZXIpOyBf
X2ltZ0hvdmVyVGltZXIgPSAwOyB9CiAgICAgICAgICAgIF9faW1nSG92ZXJIaWRlVGltZXIgPSBzZXRU
aW1lb3V0KCgpID0+IHsgaWYgKCFfX2ltZ0hvdmVyS2V5IHx8IF9faW1nSG92ZXJLZXkgPT09IGtleSkg
d2luZG93Ll9faW1nSG92ZXJIaWRlKCk7IH0sIDcwKTsKICAgICAgICB9KTsKICAgIH0KICAgIGZ1bmN0
aW9uIGhhbmRsZUl0ZW1DbGljayhlLCBjKSB7CiAgICAgICAgaWYgKGUuc2hpZnRLZXkpIHsKICAgICAg
ICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOyBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgICAgICAgICBj
b25zdCBsaXN0ID0gKHR5cGVvZiBuYXZMaXN0ID09PSAnZnVuY3Rpb24nID8gbmF2TGlzdCgpIDogdmlz
aWJsZUxpc3QoKSk7CiAgICAgICAgICAgIGNvbnN0IGFuY2hvck9rID0gcmFuZ2VBbmNob3JDbGlja2Vk
ICYmIHJhbmdlQW5jaG9ySWQgJiYgbGlzdC5zb21lKHggPT4gK3guaWQgPT09ICtyYW5nZUFuY2hvcklk
KTsKICAgICAgICAgICAgaWYgKCFhbmNob3JPaykgcmFuZ2VBbmNob3JJZCA9IHNlbGVjdGVkSWQgfHwg
Yy5pZDsKICAgICAgICAgICAgcmFuZ2VBbmNob3JDbGlja2VkID0gdHJ1ZTsKICAgICAgICAgICAgc2Vs
ZWN0UmFuZ2VUbyhjLmlkKTsKICAgICAgICAgICAgcmV0dXJuIHRydWU7CiAgICAgICAgfQogICAgICAg
IGlmIChlLmN0cmxLZXkgfHwgZS5tZXRhS2V5KSB7CiAgICAgICAgICAgIGUucHJldmVudERlZmF1bHQo
KTsgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICAgICAgdG9nZ2xlTXVsdGkoYy5pZCk7CiAgICAg
ICAgICAgIHJldHVybiB0cnVlOwogICAgICAgIH0KICAgICAgICByYW5nZUFuY2hvcklkID0gYy5pZDsK
ICAgICAgICByYW5nZUFuY2hvckNsaWNrZWQgPSB0cnVlOwogICAgICAgIHJldHVybiBmYWxzZTsKICAg
IH0KICAgIGZ1bmN0aW9uIHRvZ2dsZU11bHRpKGlkKSB7CiAgICAgICAgaWQgPSAraWQ7CiAgICAgICAg
Y29uc3QgaSA9IG11bHRpSWRzLmluZGV4T2YoaWQpOwogICAgICAgIGlmIChpID49IDApIG11bHRpSWRz
LnNwbGljZShpLCAxKTsKICAgICAgICBlbHNlIG11bHRpSWRzLnB1c2goaWQpOwogICAgICAgIHNlbGVj
dGVkSWQgPSBpZDsKICAgICAgICByYW5nZUFuY2hvcklkID0gaWQ7CiAgICAgICAgcmFuZ2VBbmNob3JD
bGlja2VkID0gdHJ1ZTsKICAgICAgICB1cGRhdGVNdWx0aUJhZGdlKCk7CiAgICB9CgogICAgZnVuY3Rp
b24gcmVuZGVyKCkgewogICAgICAgIGhpZGVQYXRoVGlwKCk7CgogICAgICAgIGNvbnN0IHZpc2libGUg
PSB2aXNpYmxlTGlzdCgpOwogICAgICAgIGNvbnN0IGxvYWRlZCA9IGFsbENsaXBzLmxlbmd0aDsKICAg
ICAgICBjb25zdCBzaG93bkNvdW50ID0gdmlzaWJsZS5sZW5ndGg7CiAgICAgICAgLy8g5pS26JeP6KeS
5qCH77ya55SoIEFISyDkuIvlj5HnmoTmgLvmlbDvvIzpgb/lhY3jgIzlvZPliY3pobXph4zmlbDlh7rm
naXnmoTjgI3lkowgYmFyIOWvueS4jeS4igogICAgICAgIGxldCBwaW5uZWROID0gTnVtYmVyKHBpbm5l
ZFRvdGFsKSB8fCAwOwogICAgICAgIGlmIChwaW5uZWROIDwgMSkgewogICAgICAgICAgICBpZiAoY3Vy
VGFiID09PSAncGlubmVkJykKICAgICAgICAgICAgICAgIHBpbm5lZE4gPSBNYXRoLm1heChOdW1iZXIo
ZGlza1RvdGFsKSB8fCAwLCBsb2FkZWQpOwogICAgICAgICAgICBlbHNlCiAgICAgICAgICAgICAgICBw
aW5uZWROID0gYWxsQ2xpcHMuZmlsdGVyKGMgPT4gaXNQaW5uZWQoYykpLmxlbmd0aDsKICAgICAgICB9
CiAgICAgICAgY29uc3QgcGluQ250ICA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdwaW4tY250Jyk7
CiAgICAgICAgcGluQ250LnRleHRDb250ZW50ICAgPSBwaW5uZWROOwogICAgICAgIHBpbkNudC5zdHls
ZS5kaXNwbGF5ID0gcGlubmVkTiA/ICcnIDogJ25vbmUnOwogICAgICAgIC8vIOaUtuiXjyB0YWLvvJpi
YXIg5LiO6KeS5qCH5ZCM5LiA5aWX5oC75pWw77yb5pyq5ruh6aG15pe25pi+56S6IOW3suWKoOi9vS/m
gLvmlbAKICAgICAgICBsZXQgc2hvd1RvdGFsID0gZGlza1RvdGFsID4gMCA/IGRpc2tUb3RhbCA6IChs
b2FkZWQgfHwgMCk7CiAgICAgICAgaWYgKGN1clRhYiA9PT0gJ3Bpbm5lZCcgJiYgcGlubmVkTiA+IHNo
b3dUb3RhbCkKICAgICAgICAgICAgc2hvd1RvdGFsID0gcGlubmVkTjsKICAgICAgICBjb25zdCBxT24g
PSBTdHJpbmcocXVlcnkgfHwgJycpLnRyaW0oKS5sZW5ndGggPiAwOwogICAgICAgIGRvY3VtZW50Lmdl
dEVsZW1lbnRCeUlkKCdiYXItdHh0JykudGV4dENvbnRlbnQgPSBxT24KICAgICAgICAgICAgPyAoc2hv
d25Db3VudCArICcg5p2hJykKICAgICAgICAgICAgOiAoc2hvd1RvdGFsID4gbG9hZGVkID8gKHNob3du
Q291bnQgKyAnIC8gJyArIHNob3dUb3RhbCArICcg5p2hJykgOiAoc2hvd1RvdGFsICsgJyDmnaEnKSk7
CiAgICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2VtcHR5LXR4dCcpLnRleHRDb250ZW50ID0g
RU1QVFlfTVNHW2N1clRhYl0gfHwgRU1QVFlfTVNHLmFsbDsKCiAgICAgICAgY29uc3QgaWRTZXQgPSBu
ZXcgU2V0KGFsbENsaXBzLm1hcChjID0+ICtjLmlkKSk7CiAgICAgICAgbXVsdGlJZHMgPSBtdWx0aUlk
cy5maWx0ZXIoaWQgPT4gaWRTZXQuaGFzKGlkKSk7CiAgICAgICAgdXBkYXRlTXVsdGlCYWRnZSgpOwoK
ICAgICAgICBjb25zdCBzaG93biA9IHZpc2libGU7CgogICAgICAgIGxpc3RFbC5xdWVyeVNlbGVjdG9y
QWxsKCcuaXRtLCAjbGlzdC1tb3JlJykuZm9yRWFjaChlID0+IGUucmVtb3ZlKCkpOwogICAgICAgIGlm
IChib290TG9hZGluZykgewogICAgICAgICAgICBpZiAoc2tlbEVsKSBza2VsRWwuY2xhc3NMaXN0LmFk
ZCgnb24nKTsKICAgICAgICAgICAgZW1wdHlFbC5jbGFzc0xpc3QucmVtb3ZlKCdvbicpOwogICAgICAg
ICAgICB1cGRhdGVUb3BCdG4oKTsKICAgICAgICAgICAgcmV0dXJuOwogICAgICAgIH0KICAgICAgICAv
LyBXYWl0aW5nIGZvciBmaXJzdCBkYXRhLCBvciBob3N0IG5ldmVyIGNvbmZpcm1lZCDigJRkb24ndCBm
bGFzaOOAjOaaguaXoOiusOW9leOAjQogICAgICAgIGlmICgod2FpdGluZ0RhdGEgfHwgIWhvc3RQdXNo
ZWRPbmNlKSAmJiAhdmlzaWJsZS5sZW5ndGgpIHsKICAgICAgICAgICAgLy8gS2VlcCBza2VsZXRvbiBp
ZiBhbHJlYWR5IG9uOyBuZXZlciBzdHJpcCBpdCB3aGlsZSB3YWl0aW5nCiAgICAgICAgICAgIGlmIChz
a2VsRWwgJiYgc2tlbEVsLmNsYXNzTGlzdC5jb250YWlucygnb24nKSkgewogICAgICAgICAgICAgICAg
ZW1wdHlFbC5jbGFzc0xpc3QucmVtb3ZlKCdvbicpOwogICAgICAgICAgICAgICAgdXBkYXRlVG9wQnRu
KCk7CiAgICAgICAgICAgICAgICByZXR1cm47CiAgICAgICAgICAgIH0KICAgICAgICAgICAgaWYgKHNr
ZWxFbCkgc2tlbEVsLmNsYXNzTGlzdC5yZW1vdmUoJ29uJyk7CiAgICAgICAgICAgIGNvbnN0IHFXYWl0
ID0gU3RyaW5nKHF1ZXJ5IHx8ICcnKS50cmltKCkubGVuZ3RoID4gMDsKICAgICAgICAgICAgaWYgKHFX
YWl0ICYmICFob3N0UHVzaGVkT25jZSkgewogICAgICAgICAgICAgICAgaWYgKHNrZWxFbCkgc2tlbEVs
LmNsYXNzTGlzdC5hZGQoJ29uJyk7CiAgICAgICAgICAgICAgICBlbXB0eUVsLmNsYXNzTGlzdC5yZW1v
dmUoJ29uJyk7CiAgICAgICAgICAgICAgICB1cGRhdGVUb3BCdG4oKTsKICAgICAgICAgICAgICAgIHJl
dHVybjsKICAgICAgICAgICAgfQogICAgICAgICAgICBlbXB0eUVsLmNsYXNzTGlzdC5yZW1vdmUoJ29u
Jyk7CiAgICAgICAgICAgIHVwZGF0ZVRvcEJ0bigpOwogICAgICAgICAgICByZXR1cm47CiAgICAgICAg
fQogICAgICAgIGlmIChza2VsRWwpIHNrZWxFbC5jbGFzc0xpc3QucmVtb3ZlKCdvbicpOwogICAgICAg
IGlmICghdmlzaWJsZS5sZW5ndGgpIHsKICAgICAgICAgICAgLy8gTmV2ZXIgc2hvd+OAjOaaguaXoOiu
sOW9leOAjXVudGlsIHdlIGhhdmUgc2VlbiBhIHJlYWwgbm9uLWVtcHR5IHB1c2gsCiAgICAgICAgICAg
IC8vIG9yIGEgY29uZmlybWVkIGVtcHR5IGFmdGVyIHdhcm0gKHNhd05vbkVtcHR5IGNhbiBiZSBzZXQg
YnkgZW1wdHktZmFsbGJhY2spLgogICAgICAgICAgICAvLyBGaWx0ZXJlZCBzZWFyY2ggd2l0aCAwIGhp
dHMgaXMgYWxsb3dlZCBvbmNlIGhvc3QgcHVzaGVkLgogICAgICAgICAgICBjb25zdCBxT24gPSBTdHJp
bmcocXVlcnkgfHwgJycpLnRyaW0oKS5sZW5ndGggPiAwOwogICAgICAgICAgICBjb25zdCBhbGxvd0Vt
cHR5ID0gaG9zdFB1c2hlZE9uY2UgJiYgc2F3Tm9uRW1wdHkgJiYgIXdhaXRpbmdEYXRhICYmICFib290
TG9hZGluZwogICAgICAgICAgICAgICAgJiYgKHFPbiB8fCBkaXNrVG90YWwgPD0gMCk7CiAgICAgICAg
ICAgIGlmICghYWxsb3dFbXB0eSkgewogICAgICAgICAgICAgICAgZW1wdHlFbC5jbGFzc0xpc3QucmVt
b3ZlKCdvbicpOwogICAgICAgICAgICAgICAgLy8gUHJlZmVyIHNrZWxldG9uIG92ZXIgYmxhbmsgd2hp
bGUgc3RpbGwgYm9vdHN0cmFwcGluZwogICAgICAgICAgICAgICAgaWYgKCFob3N0UHVzaGVkT25jZSB8
fCB3YWl0aW5nRGF0YSkgewogICAgICAgICAgICAgICAgICAgIGlmIChza2VsRWwpIHNrZWxFbC5jbGFz
c0xpc3QuYWRkKCdvbicpOwogICAgICAgICAgICAgICAgICAgIGNvbnN0IGFwcCA9IGRvY3VtZW50Lmdl
dEVsZW1lbnRCeUlkKCdhcHAnKTsKICAgICAgICAgICAgICAgICAgICBpZiAoYXBwKSBhcHAuY2xhc3NM
aXN0LmFkZCgnYm9vdC1sb2FkaW5nJyk7CiAgICAgICAgICAgICAgICAgICAgYm9vdExvYWRpbmcgPSB0
cnVlOwogICAgICAgICAgICAgICAgfQogICAgICAgICAgICAgICAgdXBkYXRlVG9wQnRuKCk7CiAgICAg
ICAgICAgICAgICByZXR1cm47CiAgICAgICAgICAgIH0KICAgICAgICAgICAgaWYgKHNlbGVjdEZpcnN0
T25TaG93KSB7CiAgICAgICAgICAgICAgICBzZWxlY3RGaXJzdE9uU2hvdyA9IGZhbHNlOwogICAgICAg
ICAgICAgICAgc2VsZWN0ZWRJZCA9IDA7CiAgICAgICAgICAgICAgICBjbGVhck11bHRpKCk7CiAgICAg
ICAgICAgICAgICBsaXN0RWwuc2Nyb2xsVG9wID0gMDsKICAgICAgICAgICAgfQogICAgICAgICAgICBl
bXB0eUVsLmNsYXNzTGlzdC5hZGQoJ29uJyk7CiAgICAgICAgICAgIHVwZGF0ZVRvcEJ0bigpOwogICAg
ICAgICAgICByZXR1cm47CiAgICAgICAgfQogICAgICAgIGVtcHR5RWwuY2xhc3NMaXN0LnJlbW92ZSgn
b24nKTsKICAgICAgICBjb25zdCBmcmFnID0gZG9jdW1lbnQuY3JlYXRlRG9jdW1lbnRGcmFnbWVudCgp
OwogICAgICAgIGNvbnN0IGJsb2NrcyA9IGJ1aWxkUGlubmVkQmxvY2tzKHNob3duKTsKICAgICAgICBs
ZXQgbnVtID0gMDsKICAgICAgICBibG9ja3MuZm9yRWFjaChiID0+IHsKICAgICAgICAgICAgbnVtICs9
IDE7CiAgICAgICAgICAgIGlmIChiLmtpbmQgPT09ICdncm91cCcgJiYgYi5pdGVtcy5sZW5ndGggPiAx
KQogICAgICAgICAgICAgICAgZnJhZy5hcHBlbmRDaGlsZChtYWtlR3JvdXBJdGVtKGIuaXRlbXMsIG51
bSkpOwogICAgICAgICAgICBlbHNlCiAgICAgICAgICAgICAgICBmcmFnLmFwcGVuZENoaWxkKG1ha2VJ
dGVtKGIuaXRlbXNbMF0sIG51bSkpOwogICAgICAgIH0pOwogICAgICAgIGxpc3RFbC5hcHBlbmRDaGls
ZChmcmFnKTsKICAgICAgICBtYXJrUXVldWVSYWlscygpOwogICAgICAgIHVwZGF0ZU1vcmVGb290ZXIo
ZGlza1RvdGFsKTsKICAgICAgICBpZiAoc2VsZWN0Rmlyc3RPblNob3cpIHsKICAgICAgICAgICAgc2Vs
ZWN0Rmlyc3RPblNob3cgPSBmYWxzZTsKICAgICAgICAgICAgc2VsZWN0ZWRJZCA9IHZpc2libGVbMF0u
aWQ7CiAgICAgICAgICAgIGNsZWFyTXVsdGkoKTsKICAgICAgICAgICAgbGlzdEVsLnNjcm9sbFRvcCA9
IDA7CiAgICAgICAgfSBlbHNlIGlmICghdmlzaWJsZS5zb21lKGMgPT4gYy5pZCA9PSBzZWxlY3RlZElk
KSkgewogICAgICAgICAgICBzZWxlY3RlZElkID0gdmlzaWJsZVswXS5pZDsKICAgICAgICAgICAgcmFu
Z2VBbmNob3JJZCA9IHNlbGVjdGVkSWQ7CiAgICAgICAgICAgIHJhbmdlQW5jaG9yQ2xpY2tlZCA9IGZh
bHNlOwogICAgICAgIH0gZWxzZSBpZiAoIXJhbmdlQW5jaG9ySWQpIHsKICAgICAgICAgICAgcmFuZ2VB
bmNob3JJZCA9IHNlbGVjdGVkSWQ7CiAgICAgICAgfQogICAgICAgIHN5bmNJdGVtSGlnaGxpZ2h0KCk7
CiAgICAgICAgdXBkYXRlVG9wQnRuKCk7CiAgICAgICAgaWYgKHdpbmRvdy5fX3BlbmRpbmdKdW1wSWQp
IHsKICAgICAgICAgICAgY29uc3QgamlkID0gK3dpbmRvdy5fX3BlbmRpbmdKdW1wSWQ7CiAgICAgICAg
ICAgIGNvbnN0IGVsID0gbGlzdEVsLnF1ZXJ5U2VsZWN0b3IoJy5tZy1yb3dbZGF0YS1pZD0iJyArIGpp
ZCArICciXScpIHx8IGxpc3RFbC5xdWVyeVNlbGVjdG9yKCcuaXRtW2RhdGEtaWQ9IicgKyBqaWQgKyAn
Il0nKTsKICAgICAgICAgICAgaWYgKGVsKSB7CiAgICAgICAgICAgICAgICB3aW5kb3cuX19wZW5kaW5n
SnVtcElkID0gMDsKICAgICAgICAgICAgICAgIHdpbmRvdy5fX2p1bXBMb2FkVHJpZXMgPSAwOwogICAg
ICAgICAgICAgICAgc2VsZWN0ZWRJZCA9IGppZDsKICAgICAgICAgICAgICAgIHJlcXVlc3RBbmltYXRp
b25GcmFtZSgoKSA9PiB7CiAgICAgICAgICAgICAgICAgICAgY29uc3Qgbm9kZSA9IGxpc3RFbC5xdWVy
eVNlbGVjdG9yKCcubWctcm93W2RhdGEtaWQ9IicgKyBqaWQgKyAnIl0nKSB8fCBsaXN0RWwucXVlcnlT
ZWxlY3RvcignLml0bVtkYXRhLWlkPSInICsgamlkICsgJyJdJyk7CiAgICAgICAgICAgICAgICAgICAg
aWYgKCFub2RlKSByZXR1cm47CiAgICAgICAgICAgICAgICAgICAgbm9kZS5zY3JvbGxJbnRvVmlldyh7
IGJsb2NrOiAnY2VudGVyJyB9KTsKICAgICAgICAgICAgICAgICAgICBub2RlLmNsYXNzTGlzdC5hZGQo
J2p1bXAtZmxhc2gnKTsKICAgICAgICAgICAgICAgICAgICBzZXRUaW1lb3V0KCgpID0+IG5vZGUuY2xh
c3NMaXN0LnJlbW92ZSgnanVtcC1mbGFzaCcpLCA5MDApOwogICAgICAgICAgICAgICAgICAgIHN5bmNJ
dGVtSGlnaGxpZ2h0KCk7CiAgICAgICAgICAgICAgICB9KTsKICAgICAgICAgICAgfSBlbHNlIGlmIChh
bGxDbGlwcy5sZW5ndGggPCBkaXNrVG90YWwgJiYgKHdpbmRvdy5fX2p1bXBMb2FkVHJpZXMgfHwgMCkg
PCA0MCkgewogICAgICAgICAgICAgICAgd2luZG93Ll9fanVtcExvYWRUcmllcyA9ICh3aW5kb3cuX19q
dW1wTG9hZFRyaWVzIHx8IDApICsgMTsKICAgICAgICAgICAgICAgIHJlcXVlc3RNb3JlKCk7CiAgICAg
ICAgICAgIH0gZWxzZSBpZiAoY3VyVGFiICE9PSAnYWxsJyAmJiAhd2luZG93Ll9fanVtcEZlbGxCYWNr
KSB7CiAgICAgICAgICAgICAgICAvLyBJdGVtIGdvbmUgZnJvbSB0aGlzIHRhYiAoZS5nLiB1bnBpbm5l
ZCkg4oCUIGZhbGwgYmFjayB0byDlhajpg6ggb25jZQogICAgICAgICAgICAgICAgd2luZG93Ll9fanVt
cEZlbGxCYWNrID0gdHJ1ZTsKICAgICAgICAgICAgICAgIHdpbmRvdy5fX2p1bXBMb2FkVHJpZXMgPSAw
OwogICAgICAgICAgICAgICAgY3VyVGFiID0gJ2FsbCc7CiAgICAgICAgICAgICAgICBtYXJrVGFiKCdh
bGwnKTsKICAgICAgICAgICAgICAgIHJlcXVlc3RWaWV3KCk7CiAgICAgICAgICAgIH0gZWxzZSB7CiAg
ICAgICAgICAgICAgICB3aW5kb3cuX19wZW5kaW5nSnVtcElkID0gMDsKICAgICAgICAgICAgICAgIHdp
bmRvdy5fX2p1bXBMb2FkVHJpZXMgPSAwOwogICAgICAgICAgICAgICAgaWYgKGFsbENsaXBzLnNvbWUo
YyA9PiArYy5pZCA9PT0gamlkKSkKICAgICAgICAgICAgICAgICAgICBzZWxlY3RlZElkID0gamlkOwog
ICAgICAgICAgICAgICAgc3luY0l0ZW1IaWdobGlnaHQoKTsKICAgICAgICAgICAgfQogICAgICAgIH0K
ICAgICAgICByZXF1ZXN0QW5pbWF0aW9uRnJhbWUoKCkgPT4gewogICAgICAgICAgICBpZiAoYWxsQ2xp
cHMubGVuZ3RoIDwgZGlza1RvdGFsCiAgICAgICAgICAgICAgICAmJiBsaXN0RWwuc2Nyb2xsSGVpZ2h0
IDw9IGxpc3RFbC5jbGllbnRIZWlnaHQgKyAyMCkKICAgICAgICAgICAgICAgIHJlcXVlc3RNb3JlKCk7
CiAgICAgICAgICAgIHNjaGVkdWxlRmlsZUdvbmVDaGVjaygpOwogICAgICAgIH0pOwogICAgfQoKICAg
IGNvbnN0IFNWRyA9IHsKICAgICAgICB0ZXh0OiAgIGA8c3ZnIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmls
bD0ibm9uZSIgc3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0cm9rZS13aWR0aD0iMiI+PHBhdGggZD0iTTQg
N1Y0aDE2djNNOSAyMGg2TTEyIDR2MTYiLz48L3N2Zz5gLAogICAgICAgIG1kOiAgICAgYDxzdmcgdmll
d0JveD0iMCAwIDI0IDI0IiBmaWxsPSJjdXJyZW50Q29sb3IiPjx0ZXh0IHg9IjEyIiB5PSIxNyIgdGV4
dC1hbmNob3I9Im1pZGRsZSIgZm9udC1zaXplPSIxNSIgZm9udC13ZWlnaHQ9IjgwMCIgZm9udC1mYW1p
bHk9IlNlZ29lIFVJLE1pY3Jvc29mdCBZYUhlaSxzYW5zLXNlcmlmIj5NPC90ZXh0Pjwvc3ZnPmAsCiAg
ICAgICAgaW1hZ2U6ICBgPHN2ZyB2aWV3Qm94PSIwIDAgMjQgMjQiIGZpbGw9Im5vbmUiIHN0cm9rZT0i
Y3VycmVudENvbG9yIiBzdHJva2Utd2lkdGg9IjEuOCI+PHJlY3QgeD0iMyIgeT0iNSIgd2lkdGg9IjE4
IiBoZWlnaHQ9IjE0IiByeD0iMiIvPjxjaXJjbGUgY3g9IjguNSIgY3k9IjEwIiByPSIxLjUiIGZpbGw9
ImN1cnJlbnRDb2xvciIgc3Ryb2tlPSJub25lIi8+PHBhdGggZD0iTTMgMTZsNS01IDQgNCAzLTMgNiA2
Ii8+PC9zdmc+YCwKICAgICAgICB2aWRlbzogIGA8c3ZnIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0i
bm9uZSIgc3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0cm9rZS13aWR0aD0iMS44Ij48cmVjdCB4PSIzIiB5
PSI2IiB3aWR0aD0iMTQiIGhlaWdodD0iMTIiIHJ4PSIyIi8+PHBhdGggZD0iTTE3IDkuNWw0LTIuNXYx
MGwtNC0yLjVWOS41eiIgZmlsbD0iY3VycmVudENvbG9yIiBzdHJva2U9Im5vbmUiLz48cGF0aCBkPSJN
OC41IDEwLjJ2My42bDMuMi0xLjgtMy4yLTEuOHoiIGZpbGw9ImN1cnJlbnRDb2xvciIgc3Ryb2tlPSJu
b25lIi8+PC9zdmc+YCwKICAgICAgICBmb2xkZXI6IGA8c3ZnIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmls
bD0iY3VycmVudENvbG9yIj48cGF0aCBkPSJNMTAgNEg0Yy0xLjEgMC0yIC45LTIgMnYxMmMwIDEuMS45
IDIgMiAyaDE2YzEuMSAwIDItLjkgMi0yVjhjMC0xLjEtLjktMi0yLTJoLThsLTItMnoiLz48L3N2Zz5g
LAogICAgICAgIHppcDogICAgYDxzdmcgdmlld0JveD0iMCAwIDI0IDI0IiBmaWxsPSJub25lIiBzdHJv
a2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIxLjgiPjxwYXRoIGQ9Ik02IDNoOWw1IDV2MTNh
MSAxIDAgMCAxLTEgMUg2YTEgMSAwIDAgMS0xLTFWNGExIDEgMCAwIDEgMS0xeiIvPjxwYXRoIGQ9Ik0x
NCAzdjZoNiIvPjwvc3ZnPmAsCiAgICAgICAgYWhrOiAgICBgPHN2ZyB2aWV3Qm94PSIwIDAgMjQgMjQi
IGZpbGw9ImN1cnJlbnRDb2xvciI+PHRleHQgeD0iMTIiIHk9IjE3IiB0ZXh0LWFuY2hvcj0ibWlkZGxl
IiBmb250LXNpemU9IjE0IiBmb250LXdlaWdodD0iNzAwIj5IPC90ZXh0Pjwvc3ZnPmAsCiAgICAgICAg
bG5rOiAgICBgPHN2ZyB2aWV3Qm94PSIwIDAgMjQgMjQiIGZpbGw9Im5vbmUiIHN0cm9rZT0iY3VycmVu
dENvbG9yIiBzdHJva2Utd2lkdGg9IjEuOCI+PHBhdGggZD0iTTEwIDEzYTUgNSAwIDAgMCA3LjA3IDBs
Mi4xMi0yLjEyYTUgNSAwIDAgMC03LjA3LTcuMDdMMTEgNSIvPjxwYXRoIGQ9Ik0xNCAxMWE1IDUgMCAw
IDAtNy4wNyAwTDQuOCAxMy4xMmE1IDUgMCAxIDAgNy4wNyA3LjA3TDEzIDE5Ii8+PC9zdmc+YCwKICAg
ICAgICBkb2M6ICAgIGA8c3ZnIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSJj
dXJyZW50Q29sb3IiIHN0cm9rZS13aWR0aD0iMS44Ij48cGF0aCBkPSJNNyAzaDdsNSA1djEzYTEgMSAw
IDAgMS0xIDFIN2ExIDEgMCAwIDEtMS0xVjRhMSAxIDAgMCAxIDEtMXoiLz48cGF0aCBkPSJNMTQgM3Y2
aDYiLz48L3N2Zz5gLAogICAgICAgIG11bHRpOiAgYDxzdmcgdmlld0JveD0iMCAwIDI0IDI0IiBmaWxs
PSJub25lIiBzdHJva2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIxLjgiPjxyZWN0IHg9Ijci
IHk9IjciIHdpZHRoPSIxMiIgaGVpZ2h0PSIxNCIgcng9IjEuNSIvPjxwYXRoIGQ9Ik01IDE3VjVhMSAx
IDAgMCAxIDEtMWgxMCIvPjwvc3ZnPmAKICAgIH07CgogICAgZnVuY3Rpb24gZmlsZUV4dChwYXRoKSB7
CiAgICAgICAgY29uc3QgYmFzZSA9IFN0cmluZyhwYXRoIHx8ICcnKS5zcGxpdCgvW1xcL10vKS5wb3Ao
KSB8fCAnJzsKICAgICAgICBjb25zdCBpID0gYmFzZS5sYXN0SW5kZXhPZignLicpOwogICAgICAgIHJl
dHVybiBpID4gMCA/IGJhc2Uuc2xpY2UoaSArIDEpLnRvTG93ZXJDYXNlKCkgOiAnJzsKICAgIH0KICAg
IGNvbnN0IGlzSW1hZ2VFeHQgPSBlID0+IFsncG5nJywnanBnJywnanBlZycsJ2dpZicsJ3dlYnAnLCdi
bXAnLCdpY28nLCd0aWYnLCd0aWZmJywnc3ZnJ10uaW5jbHVkZXMoZSk7CiAgICBjb25zdCBpc1ZpZGVv
RXh0ID0gZSA9PiBbJ21wNCcsJ21rdicsJ2F2aScsJ21vdicsJ3dtdicsJ2ZsdicsJ3dlYm0nLCdtNHYn
LCdtcGVnJywnbXBnJywndHMnLCdtMnRzJywnM2dwJywncm0nLCdybXZiJ10uaW5jbHVkZXMoZSk7CiAg
ICBjb25zdCBpc1ppcEV4dCAgID0gZSA9PiBbJ3ppcCcsJ3JhcicsJzd6JywndGFyJywnZ3onLCdiejIn
XS5pbmNsdWRlcyhlKTsKCiAgICBmdW5jdGlvbiBpY29uRm9yRmlsZXMoZmlsZXMpIHsKICAgICAgICBp
ZiAoIWZpbGVzLmxlbmd0aCkgICAgcmV0dXJuIHsgY2xzOiAnZmlsZSBmdC1kb2MnLCBzdmc6IFNWRy5k
b2MgfTsKICAgICAgICBpZiAoZmlsZXMubGVuZ3RoID4gMSkgcmV0dXJuIHsgY2xzOiAnZmlsZSBmdC1s
bmsnLCBzdmc6IFNWRy5tdWx0aSB9OwogICAgICAgIGNvbnN0IGV4dCA9IGZpbGVFeHQoZmlsZXNbMF0p
OwogICAgICAgIGlmICghZXh0KSAgICAgICAgICAgICAgcmV0dXJuIHsgY2xzOiAnZmlsZSBmdC1kaXIn
LCBzdmc6IFNWRy5mb2xkZXIgfTsKICAgICAgICBpZiAoaXNJbWFnZUV4dChleHQpKSAgIHJldHVybiB7
IGNsczogJ2ZpbGUgZnQtaW1nJywgc3ZnOiBTVkcuaW1hZ2UgfTsKICAgICAgICBpZiAoaXNWaWRlb0V4
dChleHQpKSAgIHJldHVybiB7IGNsczogJ2ZpbGUgZnQtdmlkJywgc3ZnOiAoU1ZHLnZpZGVvIHx8IFNW
Ry5kb2MpIH07CiAgICAgICAgaWYgKGlzWmlwRXh0KGV4dCkpICAgICByZXR1cm4geyBjbHM6ICdmaWxl
IGZ0LXppcCcsIHN2ZzogU1ZHLnppcCB9OwogICAgICAgIGlmIChleHQgPT09ICdhaGsnKSAgICAgcmV0
dXJuIHsgY2xzOiAnZmlsZSBmdC1haGsnLCBzdmc6IFNWRy5haGsgfTsKICAgICAgICBpZiAoZXh0ID09
PSAnbG5rJykgICAgIHJldHVybiB7IGNsczogJ2ZpbGUgZnQtbG5rJywgc3ZnOiBTVkcubG5rIH07CiAg
ICAgICAgcmV0dXJuIHsgY2xzOiAnZmlsZSBmdC1kb2MnLCBzdmc6IFNWRy5kb2MgfTsKICAgIH0KCiAg
ICBmdW5jdGlvbiBzcmNXaW5MYWJlbChjKSB7CiAgICAgICAgY29uc3QgdCA9IFN0cmluZyhjICYmIGMu
c3JjVGl0bGUgfHwgJycpLnRyaW0oKTsKICAgICAgICBpZiAodCkgcmV0dXJuIHQ7CiAgICAgICAgcmV0
dXJuIFN0cmluZyhjICYmIGMuc3JjRXhlIHx8ICcnKS5yZXBsYWNlKC9cLmV4ZSQvaSwgJycpOwogICAg
fQogICAgZnVuY3Rpb24gc3JjVGl0bGVIdG1sKGMpIHsKICAgICAgICAvLyDliJfooajkuK3pl7Qv5Y+z
5L6n5LiN5YaN5pi+56S656qX5Y+j5qCH6aKY77yM5p2l5rqQ5Y+q5L+d55WZ5Y+z5L6n5Zu+5qCH5oKs
5YGc5o+Q56S6CiAgICAgICAgcmV0dXJuICcnOwogICAgfQogICAgZnVuY3Rpb24gZXhwYW5kQ2hldnJv
bihvcGVuKSB7CiAgICAgICAgcmV0dXJuIG9wZW4KICAgICAgICAgICAgPyBgPHN2ZyB2aWV3Qm94PSIw
IDAgMTYgMTYiIHdpZHRoPSIxNCIgaGVpZ2h0PSIxNCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSJjdXJyZW50
Q29sb3IiIHN0cm9rZS13aWR0aD0iMS44IiBzdHJva2UtbGluZWNhcD0icm91bmQiPjxwb2x5bGluZSBw
b2ludHM9IjQgMTAgOCA2IDEyIDEwIi8+PC9zdmc+PHNwYW4+5pS26LW3PC9zcGFuPmAKICAgICAgICAg
ICAgOiBgPHN2ZyB2aWV3Qm94PSIwIDAgMTYgMTYiIHdpZHRoPSIxNCIgaGVpZ2h0PSIxNCIgZmlsbD0i
bm9uZSIgc3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0cm9rZS13aWR0aD0iMS44IiBzdHJva2UtbGluZWNh
cD0icm91bmQiPjxwb2x5bGluZSBwb2ludHM9IjQgNiA4IDEwIDEyIDYiLz48L3N2Zz48c3Bhbj7lsZXl
vIA8L3NwYW4+YDsKICAgIH0KICAgIGZ1bmN0aW9uIGxpc3RFeHBhbmRNYXhQeCgpIHsKICAgICAgICBj
b25zdCBoID0gKGxpc3RFbCAmJiBsaXN0RWwuY2xpZW50SGVpZ2h0KSB8fCAzNjA7CiAgICAgICAgLy8g
5Yeg5LmO5Y2g5ruh5YiX6KGo77yM5bqV6YOo55WZ57qm5LiA6KGMCiAgICAgICAgcmV0dXJuIE1hdGgu
bWF4KDk2LCBoIC0gMjgpOwogICAgfQogICAgZnVuY3Rpb24gYXBwbHlFeHBhbmRlZFByZXZpZXcocHJl
diwgZnVsbFRleHQpIHsKICAgICAgICBjb25zdCBtYXhIID0gbGlzdEV4cGFuZE1heFB4KCk7CiAgICAg
ICAgcHJldi5zdHlsZS5tYXhIZWlnaHQgPSBtYXhIICsgJ3B4JzsKICAgICAgICBwcmV2LmNsYXNzTGlz
dC5hZGQoJ2V4cGFuZGVkJyk7CiAgICAgICAgc2V0SGxUZXh0KHByZXYsIGZ1bGxUZXh0KTsKICAgICAg
ICAvLyDku43muqLlh7rvvJrmiKrmlq3lubblnKjmnKvlsL7liqDjgIwgLi4u44CNCiAgICAgICAgaWYg
KHByZXYuc2Nyb2xsSGVpZ2h0IDw9IHByZXYuY2xpZW50SGVpZ2h0ICsgMikKICAgICAgICAgICAgcmV0
dXJuOwogICAgICAgIGxldCBsbyA9IDAsIGhpID0gZnVsbFRleHQubGVuZ3RoLCBiZXN0ID0gMDsKICAg
ICAgICB3aGlsZSAobG8gPD0gaGkpIHsKICAgICAgICAgICAgY29uc3QgbWlkID0gKGxvICsgaGkpID4+
IDE7CiAgICAgICAgICAgIHNldEhsVGV4dChwcmV2LCBmdWxsVGV4dC5zbGljZSgwLCBtaWQpICsgJyAu
Li4nKTsKICAgICAgICAgICAgaWYgKHByZXYuc2Nyb2xsSGVpZ2h0IDw9IHByZXYuY2xpZW50SGVpZ2h0
ICsgMikgewogICAgICAgICAgICAgICAgYmVzdCA9IG1pZDsKICAgICAgICAgICAgICAgIGxvID0gbWlk
ICsgMTsKICAgICAgICAgICAgfSBlbHNlIHsKICAgICAgICAgICAgICAgIGhpID0gbWlkIC0gMTsKICAg
ICAgICAgICAgfQogICAgICAgIH0KICAgICAgICBzZXRIbFRleHQocHJldiwgZnVsbFRleHQuc2xpY2Uo
MCwgYmVzdCkgKyAnIC4uLicpOwogICAgfQogICAgZnVuY3Rpb24gY29sbGFwc2VQcmV2aWV3KHByZXYs
IGZ1bGxUZXh0KSB7CiAgICAgICAgcHJldi5jbGFzc0xpc3QucmVtb3ZlKCdleHBhbmRlZCcpOwogICAg
ICAgIHByZXYuc3R5bGUubWF4SGVpZ2h0ID0gJyc7CiAgICAgICAgc2V0SGxUZXh0KHByZXYsIGZ1bGxU
ZXh0KTsKICAgIH0KCiAgICBmdW5jdGlvbiBmYXZHcm91cE9mKGMpIHsKICAgICAgICByZXR1cm4gU3Ry
aW5nKGMgJiYgYy5mYXZHcm91cCB8fCAnJykudHJpbSgpOwogICAgfQogICAgZnVuY3Rpb24gY2xpcENv
bnRlbnRQcmV2aWV3KGMpIHsKICAgICAgICBjb25zdCB0eXBlID0gbm9ybVR5cGUoYy50eXBlKTsKICAg
ICAgICBpZiAodHlwZSA9PT0gJ2ltYWdlJykgcmV0dXJuICdb5Zu+5YOPXScgKyAoYy53aWR0aCAmJiBj
LmhlaWdodCA/ICgnICcgKyBjLndpZHRoICsgJ8OXJyArIGMuaGVpZ2h0KSA6ICcnKTsKICAgICAgICBp
ZiAodHlwZSA9PT0gJ2ZpbGUnKSB7CiAgICAgICAgICAgIGNvbnN0IGZpbGVzID0gU3RyaW5nKGMucHJl
dmlldyB8fCBjLmRhdGEgfHwgJycpLnNwbGl0KC9ccj9cbi8pLmZpbHRlcihCb29sZWFuKTsKICAgICAg
ICAgICAgcmV0dXJuIGZpbGVzLm1hcChmID0+IGYuc3BsaXQoL1tcXC9dLykucG9wKCkpLmpvaW4oJyDC
tyAnKSB8fCAnW+aWh+S7tl0nOwogICAgICAgIH0KICAgICAgICBsZXQgX3AgPSBTdHJpbmcoYy5wcmV2
aWV3IHx8IGMuZGF0YSB8fCAnJyk7CiAgICAgICAgeyBjb25zdCBfbiA9IE51bWJlcihjLmNoYXJDb3Vu
dCkgfHwgMDsgaWYgKF9uID4gX3AubGVuZ3RoICYmIF9wLmxlbmd0aCkgX3AgKz0gJy4uLic7IH0KICAg
ICAgICByZXR1cm4gX3A7CiAgICB9CiAgICBmdW5jdGlvbiBidWlsZFBpbm5lZEJsb2NrcyhsaXN0KSB7
CiAgICAgICAgY29uc3QgdXNlZCA9IG5ldyBTZXQoKTsKICAgICAgICBjb25zdCBvdXQgPSBbXTsKICAg
ICAgICBmb3IgKGNvbnN0IGMgb2YgbGlzdCkgewogICAgICAgICAgICBpZiAodXNlZC5oYXMoK2MuaWQp
KSBjb250aW51ZTsKICAgICAgICAgICAgY29uc3QgZ2lkID0gZmF2R3JvdXBPZihjKTsKICAgICAgICAg
ICAgaWYgKCFnaWQpIHsKICAgICAgICAgICAgICAgIHVzZWQuYWRkKCtjLmlkKTsKICAgICAgICAgICAg
ICAgIG91dC5wdXNoKHsga2luZDogJ3NpbmdsZScsIGl0ZW1zOiBbY10gfSk7CiAgICAgICAgICAgICAg
ICBjb250aW51ZTsKICAgICAgICAgICAgfQogICAgICAgICAgICBjb25zdCBtZW1iZXJzID0gbGlzdC5m
aWx0ZXIoeCA9PiBmYXZHcm91cE9mKHgpID09PSBnaWQpOwogICAgICAgICAgICBtZW1iZXJzLmZvckVh
Y2gobSA9PiB1c2VkLmFkZCgrbS5pZCkpOwogICAgICAgICAgICBpZiAobWVtYmVycy5sZW5ndGggPCAy
KQogICAgICAgICAgICAgICAgb3V0LnB1c2goeyBraW5kOiAnc2luZ2xlJywgaXRlbXM6IFttZW1iZXJz
WzBdIHx8IGNdIH0pOwogICAgICAgICAgICBlbHNlCiAgICAgICAgICAgICAgICBvdXQucHVzaCh7IGtp
bmQ6ICdncm91cCcsIGdpZCwgaXRlbXM6IG1lbWJlcnMgfSk7CiAgICAgICAgfQogICAgICAgIHJldHVy
biBvdXQ7CiAgICB9CiAgICBmdW5jdGlvbiBfX3ByZXBQYXN0ZSgpIHsKICAgICAgICB0cnkgewogICAg
ICAgICAgICBjb25zdCBzID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NlYXJjaCcpOwogICAgICAg
ICAgICBpZiAocyAmJiBkb2N1bWVudC5hY3RpdmVFbGVtZW50ID09PSBzKSB0cnkgeyBzLmJsdXIoKTsg
fSBjYXRjaCB7fQogICAgICAgICAgICBpZiAod2luZG93LmdldFNlbGVjdGlvbikgd2luZG93LmdldFNl
bGVjdGlvbigpLnJlbW92ZUFsbFJhbmdlcygpOwogICAgICAgIH0gY2F0Y2gge30KICAgIH0KICAgIGZ1
bmN0aW9uIHBhc3RlT25lKGMpIHsKICAgICAgICBfX3ByZXBQYXN0ZSgpOwogICAgICAgIHNlbGVjdGVk
SWQgPSBjLmlkOwogICAgICAgIGlmIChtdWx0aUlkcy5sZW5ndGgpIGNsZWFyTXVsdGkoKTsKICAgICAg
ICBzeW5jSXRlbUhpZ2hsaWdodCgpOwogICAgICAgIG1hcmtQYXN0ZWRMb2NhbChjLmlkKTsKICAgICAg
ICBhaGsoJ3Bhc3RlJywgU3RyaW5nKGMuaWQpKTsKICAgIH0KICAgIGZ1bmN0aW9uIGlzSXRlbUNocm9t
ZVRhcmdldCh0KSB7CiAgICAgICAgcmV0dXJuICEhKHQgJiYgdC5jbG9zZXN0ICYmIHQuY2xvc2VzdCgn
LmktZXhwYW5kLWJ0biwgLmktc3JjLWljbywgLm1nLXNyYywgLmZkLWJ0biwgLmZkLXBhdGgsIGJ1dHRv
biwgYSwgaW5wdXQnKSk7CiAgICB9CiAgICBmdW5jdGlvbiBiZWdpblBhc3RlRnJvbUl0ZW0oZSwgYykg
ewogICAgICAgIGlmIChlLmJ1dHRvbiAhPSBudWxsICYmIGUuYnV0dG9uICE9PSAwKSByZXR1cm47CiAg
ICAgICAgaWYgKGlzSXRlbUNocm9tZVRhcmdldChlLnRhcmdldCkpIHJldHVybjsKICAgICAgICBpZiAo
aGFuZGxlSXRlbUNsaWNrKGUsIGMpKQogICAgICAgICAgICByZXR1cm47CiAgICAgICAgX19wcmVwUGFz
dGUoKTsKICAgICAgICBzZWxlY3RlZElkID0gYy5pZDsKICAgICAgICByYW5nZUFuY2hvcklkID0gYy5p
ZDsKICAgICAgICBpZiAobXVsdGlJZHMubGVuZ3RoID4gMCAmJiBtdWx0aUlkcy5pbmNsdWRlcygrYy5p
ZCkpIHsKICAgICAgICAgICAgY29uc3QgaWRzID0gbXVsdGlJZHMuc2xpY2UoKTsKICAgICAgICAgICAg
Y2xlYXJNdWx0aSgpOwogICAgICAgICAgICBtYXJrUGFzdGVkTG9jYWwoaWRzKTsKICAgICAgICAgICAg
aWYgKGlkcy5sZW5ndGggPiAxKSBhaGsoJ3Bhc3RlTWFueScsIGlkcy5qb2luKCcsJykpOwogICAgICAg
ICAgICBlbHNlIGFoaygncGFzdGUnLCBTdHJpbmcoaWRzWzBdKSk7CiAgICAgICAgICAgIHJldHVybjsK
ICAgICAgICB9CiAgICAgICAgaWYgKG11bHRpSWRzLmxlbmd0aCkgY2xlYXJNdWx0aSgpOwogICAgICAg
IHN5bmNJdGVtSGlnaGxpZ2h0KCk7CiAgICAgICAgbWFya1Bhc3RlZExvY2FsKGMuaWQpOwogICAgICAg
IGFoaygncGFzdGUnLCBTdHJpbmcoYy5pZCkpOwogICAgfQogICAgZnVuY3Rpb24gbWFrZUdyb3VwSXRl
bShpdGVtcywgaWR4KSB7CiAgICAgICAgY29uc3QgZWwgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdk
aXYnKTsKICAgICAgICBlbC5jbGFzc05hbWUgPSAnaXRtIGl0LWdyb3VwJwogICAgICAgICAgICArIChp
dGVtcy5zb21lKGMgPT4gK2MuaWQgPT09ICtzZWxlY3RlZElkKSA/ICcgc2VsJyA6ICcnKQogICAgICAg
ICAgICArIChpdGVtcy5zb21lKGMgPT4gbXVsdGlJZHMuaW5jbHVkZXMoK2MuaWQpKSA/ICcgbXVsdGkn
IDogJycpOwogICAgICAgIGVsLmRhdGFzZXQuZ3JvdXAgPSBmYXZHcm91cE9mKGl0ZW1zWzBdKSB8fCAn
JzsKICAgICAgICBlbC5kYXRhc2V0LmlkID0gaXRlbXNbMF0uaWQ7CgogICAgICAgIGNvbnN0IGhlYWQg
PSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsKICAgICAgICBoZWFkLmNsYXNzTmFtZSA9ICdt
Zy1oZWFkJzsKICAgICAgICBoZWFkLmlubmVySFRNTCA9ICc8c3BhbiBjbGFzcz0ibWctdGFnIj7lkIjl
ubY8L3NwYW4+PHNwYW4+JyArIGl0ZW1zLmxlbmd0aCArICcg5p2hIMK3IOeCueWHu+WNleadoeeymOi0
tDwvc3Bhbj4nOwogICAgICAgIGVsLmFwcGVuZENoaWxkKGhlYWQpOwoKICAgICAgICBpdGVtcy5mb3JF
YWNoKGMgPT4gewogICAgICAgICAgICBjb25zdCByb3cgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdk
aXYnKTsKICAgICAgICAgICAgcm93LmNsYXNzTmFtZSA9ICdtZy1yb3cnCiAgICAgICAgICAgICAgICAr
ICgrc2VsZWN0ZWRJZCA9PT0gK2MuaWQgPyAnIHNlbCcgOiAnJykKICAgICAgICAgICAgICAgICsgKG11
bHRpSWRzLmluY2x1ZGVzKCtjLmlkKSA/ICcgbXVsdGknIDogJycpOwogICAgICAgICAgICByb3cuZGF0
YXNldC5pZCA9IGMuaWQ7CgogICAgICAgICAgICBjb25zdCB0b3AgPSBkb2N1bWVudC5jcmVhdGVFbGVt
ZW50KCdkaXYnKTsKICAgICAgICAgICAgdG9wLmNsYXNzTmFtZSA9ICdtZy1yb3ctdG9wJzsKICAgICAg
ICAgICAgY29uc3QgbWFpbiA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOwogICAgICAgICAg
ICBtYWluLmNsYXNzTmFtZSA9ICdtZy1yb3ctbWFpbic7CgogICAgICAgICAgICBjb25zdCB0aXRsZSA9
IFN0cmluZyhjLmZhdlRpdGxlIHx8ICcnKS50cmltKCk7CiAgICAgICAgICAgIGlmICh0aXRsZSkgewog
ICAgICAgICAgICAgICAgY29uc3QgdCA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOwogICAg
ICAgICAgICAgICAgdC5jbGFzc05hbWUgPSAnbWctdGl0bGUnOwogICAgICAgICAgICAgICAgc2V0SGxU
ZXh0KHQsIHRpdGxlKTsKICAgICAgICAgICAgICAgIG1haW4uYXBwZW5kQ2hpbGQodCk7CiAgICAgICAg
ICAgIH0KICAgICAgICAgICAgY29uc3QgYm9keSA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2Rpdicp
OwogICAgICAgICAgICBib2R5LmNsYXNzTmFtZSA9ICdtZy1ib2R5JyArIChub3JtVHlwZShjLnR5cGUp
ID09PSAnaW1hZ2UnID8gJyBpbWcnIDogJycpOwogICAgICAgICAgICBzZXRIbFRleHQoYm9keSwgY2xp
cENvbnRlbnRQcmV2aWV3KGMpKTsKICAgICAgICAgICAgbWFpbi5hcHBlbmRDaGlsZChib2R5KTsKICAg
ICAgICAgICAgdG9wLmFwcGVuZENoaWxkKG1haW4pOwoKICAgICAgICAgICAgY29uc3Qgc3JjSWNvID0g
U3RyaW5nKGMuc3JjSWNvbiB8fCAnJyk7CiAgICAgICAgICAgIGNvbnN0IHNyY0V4ZSA9IFN0cmluZyhj
LnNyY0V4ZSB8fCAnJyk7CiAgICAgICAgICAgIGNvbnN0IHNyY1RpdGxlID0gU3RyaW5nKGMuc3JjVGl0
bGUgfHwgJycpOwogICAgICAgICAgICBpZiAoc3JjSWNvKSB7CiAgICAgICAgICAgICAgICBjb25zdCBp
bWcgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdpbWcnKTsKICAgICAgICAgICAgICAgIGltZy5jbGFz
c05hbWUgPSAnbWctc3JjJzsKICAgICAgICAgICAgICAgIGltZy5zcmMgPSBTVE9SRV9CQVNFICsgZW5j
b2RlVVJJQ29tcG9uZW50KHNyY0ljbyk7CiAgICAgICAgICAgICAgICBpbWcuYWx0ID0gJyc7CiAgICAg
ICAgICAgICAgICBjb25zdCB0aXBUeHQgPSBzcmNUaXRsZSB8fCBzcmNFeGUgfHwgJ+adpea6kCc7CiAg
ICAgICAgICAgICAgICBpbWcudGl0bGUgPSB0aXBUeHQ7CiAgICAgICAgICAgICAgICBpbWcub25jbGlj
ayA9IGUgPT4geyBlLnByZXZlbnREZWZhdWx0KCk7IGUuc3RvcFByb3BhZ2F0aW9uKCk7IHNob3dTcmNU
aXAoaW1nLCB0aXBUeHQpOyB9OwogICAgICAgICAgICAgICAgdG9wLmFwcGVuZENoaWxkKGltZyk7CiAg
ICAgICAgICAgIH0KICAgICAgICAgICAgcm93LmFwcGVuZENoaWxkKHRvcCk7CgogICAgICAgICAgICBy
b3cub25wb2ludGVyZG93biA9IGUgPT4gewogICAgICAgICAgICAgICAgaWYgKGUuYnV0dG9uICE9PSAw
KSByZXR1cm47CiAgICAgICAgICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgICAgICAgICAg
ICAgYmVnaW5QYXN0ZUZyb21JdGVtKGUsIGMpOwogICAgICAgICAgICB9OwogICAgICAgICAgICByb3cu
b25jb250ZXh0bWVudSA9IGUgPT4gewogICAgICAgICAgICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOwog
ICAgICAgICAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICAgICAgICAgIHNlbGVjdGVk
SWQgPSBjLmlkOwogICAgICAgICAgICAgICAgc2hvd0N0eChlLmNsaWVudFgsIGUuY2xpZW50WSwgYyk7
CiAgICAgICAgICAgIH07CiAgICAgICAgICAgIGVsLmFwcGVuZENoaWxkKHJvdyk7CiAgICAgICAgfSk7
CgogICAgICAgIGVsLm9uY29udGV4dG1lbnUgPSBlID0+IHsKICAgICAgICAgICAgaWYgKGUudGFyZ2V0
LmNsb3Nlc3QoJy5tZy1yb3cnKSkgcmV0dXJuOwogICAgICAgICAgICBlLnByZXZlbnREZWZhdWx0KCk7
CiAgICAgICAgICAgIHNlbGVjdGVkSWQgPSBpdGVtc1swXS5pZDsKICAgICAgICAgICAgc2hvd0N0eChl
LmNsaWVudFgsIGUuY2xpZW50WSwgaXRlbXNbMF0pOwogICAgICAgIH07CiAgICAgICAgcmV0dXJuIGVs
OwogICAgfQoKICAgIGZ1bmN0aW9uIG1ha2VJdGVtKGMsIGlkeCkgewogICAgICAgIGNvbnN0IHR5cGUg
ICA9IG5vcm1UeXBlKGMudHlwZSk7CiAgICAgICAgY29uc3QgcGlubmVkID0gaXNQaW5uZWQoYyk7CiAg
ICAgICAgY29uc3QgcGFzdGVkID0gaXNQYXN0ZWQoYyk7CiAgICAgICAgY29uc3QgZWwgICAgID0gZG9j
dW1lbnQuY3JlYXRlRWxlbWVudCgnZGl2Jyk7CiAgICAgICAgZWwuY2xhc3NOYW1lICA9ICdpdG0nCiAg
ICAgICAgICAgICsgKHNlbGVjdGVkSWQgPT0gYy5pZCA/ICcgc2VsJyA6ICcnKQogICAgICAgICAgICAr
IChtdWx0aUlkcy5pbmNsdWRlcygrYy5pZCkgPyAnIG11bHRpJyA6ICcnKTsKICAgICAgICBlbC5kYXRh
c2V0LmlkID0gYy5pZDsKICAgICAgICBjb25zdCBxZyA9IE51bWJlcihjLnF1ZXVlR3JvdXApIHx8IDA7
CiAgICAgICAgaWYgKHFnID4gMCkgewogICAgICAgICAgICBlbC5jbGFzc0xpc3QuYWRkKCdxLW1lbWJl
cicpOwogICAgICAgICAgICBlbC5kYXRhc2V0LnFnID0gU3RyaW5nKHFnKTsKICAgICAgICAgICAgZWwu
ZGF0YXNldC5xaSA9IFN0cmluZyhOdW1iZXIoYy5xdWV1ZUluZGV4KSB8fCAwKTsKICAgICAgICAgICAg
aWYgKHBhc3RlZCkgZWwuY2xhc3NMaXN0LmFkZCgncS1kb25lJyk7CiAgICAgICAgICAgIGNvbnN0IHJh
aWwgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdzcGFuJyk7CiAgICAgICAgICAgIHJhaWwuY2xhc3NO
YW1lID0gJ3EtcmFpbCc7CiAgICAgICAgICAgIGNvbnN0IGRvdCA9IGRvY3VtZW50LmNyZWF0ZUVsZW1l
bnQoJ3NwYW4nKTsKICAgICAgICAgICAgZG90LmNsYXNzTmFtZSA9ICdxLWRvdCc7CiAgICAgICAgICAg
IGRvdC50aXRsZSA9IHBhc3RlZCA/ICfpmJ/liJflt7LnspjotLQnIDogJ+eymOi0tOmYn+WIlyc7CiAg
ICAgICAgICAgIGVsLmFwcGVuZENoaWxkKHJhaWwpOwogICAgICAgICAgICBlbC5hcHBlbmRDaGlsZChk
b3QpOwogICAgICAgIH0KCiAgICAgICAgY29uc3QgaWNvICA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQo
J2RpdicpOwogICAgICAgIGNvbnN0IGJvZHkgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsK
ICAgICAgICBib2R5LmNsYXNzTmFtZSA9ICdpLWJvZHknOwoKICAgICAgICBpZiAodHlwZSA9PT0gJ2lt
YWdlJykgewogICAgICAgICAgICBpY28uY2xhc3NOYW1lID0gJ2ktaWNvIGltYWdlJzsKICAgICAgICAg
ICAgaWNvLmlubmVySFRNTCA9IFNWRy5pbWFnZTsKICAgICAgICAgICAgYmluZEltZ0hvdmVyUHJldmll
dyhpY28sIGMuaWQsIGMuaW1nRmlsZSk7CiAgICAgICAgICAgIGNvbnN0IHdyYXAgPSBkb2N1bWVudC5j
cmVhdGVFbGVtZW50KCdkaXYnKTsKICAgICAgICAgICAgd3JhcC5jbGFzc05hbWUgPSAnaS10aHVtYi13
cmFwJzsKICAgICAgICAgICAgY29uc3QgaW1nICA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2ltZycp
OwogICAgICAgICAgICBpbWcuY2xhc3NOYW1lID0gJ2ktdGh1bWInOwogICAgICAgICAgICBpbWcuYWx0
ID0gJyc7CiAgICAgICAgICAgIGNvbnN0IGZpbGUgPSBTdHJpbmcoYy5pbWdGaWxlIHx8ICcnKTsKICAg
ICAgICAgICAgbGV0IGZhbGxiYWNrID0gU3RyaW5nKGMuZGF0YSB8fCAnJyk7CiAgICAgICAgICAgIC8v
IE5ldmVyIHN5bmMtY2FsbCBBSEsgdGh1bWIgaGVyZSDigJQgZnJlZXplcyB0YWIgc3dpdGNoZXM7IFB1
c2hTdG9yZVRodW1icyBmaWxscyBhc3luYwogICAgICAgICAgICBpZiAoIWZhbGxiYWNrLnN0YXJ0c1dp
dGgoJ2RhdGE6JykgJiYgdGh1bWJDYWNoZS5oYXMoU3RyaW5nKGMuaWQpKSkKICAgICAgICAgICAgICAg
IGZhbGxiYWNrID0gU3RyaW5nKHRodW1iQ2FjaGUuZ2V0KFN0cmluZyhjLmlkKSkpOwogICAgICAgICAg
ICBpbWcub25sb2FkID0gKCkgPT4gewogICAgICAgICAgICAgICAgY29uc3QgbXcgPSB3cmFwLmNsaWVu
dFdpZHRoIHx8IDMwMDsKICAgICAgICAgICAgICAgIGNvbnN0IG53ID0gaW1nLm5hdHVyYWxXaWR0aCAg
fHwgMDsKICAgICAgICAgICAgICAgIGNvbnN0IG5oID0gaW1nLm5hdHVyYWxIZWlnaHQgfHwgMDsKICAg
ICAgICAgICAgICAgIGlmICghbncgfHwgIW5oKSByZXR1cm47CiAgICAgICAgICAgICAgICBjb25zdCBz
Y2FsZSA9IE1hdGgubWluKDEsIDE4MCAvIG5oLCBtdyAvIG53KTsKICAgICAgICAgICAgICAgIGltZy5z
dHlsZS53aWR0aCAgPSBNYXRoLnJvdW5kKG53ICogc2NhbGUpICsgJ3B4JzsKICAgICAgICAgICAgICAg
IGltZy5zdHlsZS5oZWlnaHQgPSBNYXRoLnJvdW5kKG5oICogc2NhbGUpICsgJ3B4JzsKICAgICAgICAg
ICAgfTsKICAgICAgICAgICAgYmluZFN0b3JlVGh1bWIoaW1nLCBmaWxlLCBjLmlkLCBmYWxsYmFjayk7
CiAgICAgICAgICAgIHdyYXAuYXBwZW5kQ2hpbGQoaW1nKTsKICAgICAgICAgICAgY29uc3QgbWV0YSA9
IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOwogICAgICAgICAgICBtZXRhLmNsYXNzTmFtZSA9
ICdpLW1ldGEnOwogICAgICAgICAgICBtZXRhLmlubmVySFRNTCAgPSBgPHNwYW4gY2xhc3M9ImktdGlt
ZSI+JHthZ28oYy50aW1lKX08L3NwYW4+JHttZXRhQ2VudGVySHRtbChmYWxzZSl9PGRpdiBjbGFzcz0i
aS1tZXRhLXJpZ2h0Ij4ke2Mud2lkdGggPyBgPHNwYW4gY2xhc3M9ImktdGFnIj4ke2Mud2lkdGh9w5ck
e2MuaGVpZ2h0fSBweDwvc3Bhbj5gIDogJyd9PC9kaXY+YDsKICAgICAgICAgICAgYm9keS5hcHBlbmRD
aGlsZCh3cmFwKTsKICAgICAgICAgICAgYm9keS5hcHBlbmRDaGlsZChtZXRhKTsKICAgICAgICB9IGVs
c2UgaWYgKHR5cGUgPT09ICdmaWxlJykgewogICAgICAgICAgICBjb25zdCBmaWxlcyA9IFN0cmluZyhj
LnByZXZpZXcgfHwgYy5kYXRhIHx8ICcnKS5zcGxpdCgvXHI/XG4vKS5maWx0ZXIoQm9vbGVhbik7CiAg
ICAgICAgICAgIGNvbnN0IGltYWdlUGF0aHMgPSBmaWxlcy5maWx0ZXIoZiA9PiBpc0ltYWdlRXh0KGZp
bGVFeHQoZikpKTsKICAgICAgICAgICAgY29uc3QgaWMgICAgPSBpY29uRm9yRmlsZXMoZmlsZXMpOwog
ICAgICAgICAgICBpY28uY2xhc3NOYW1lID0gJ2ktaWNvICcgKyBpYy5jbHM7CiAgICAgICAgICAgIGlj
by5pbm5lckhUTUwgPSBpYy5zdmc7CgogICAgICAgICAgICBsZXQgdGh1bWJGaWxlID0gU3RyaW5nKGMu
aW1nRmlsZSB8fCAnJyk7CiAgICAgICAgICAgIC8qIGVuc3VyZUZpbGVJbWcgZGVmZXJyZWQ6IGF2b2lk
IHN5bmMgZnJlZXplIG9uIGZpbGUgdGFiICovCgogICAgICAgICAgICAvLyBJbWFnZS1mb3JtYXQgZmls
ZXM6IHNhbWUgdGh1bWJuYWlsIHJ1bGVzIGFzIHNjcmVlbnNob3QgY2xpcHMKICAgICAgICAgICAgaWYg
KHRodW1iRmlsZSB8fCBpbWFnZVBhdGhzLmxlbmd0aCkgewogICAgICAgICAgICAgICAgY29uc3Qgd3Jh
cCA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOwogICAgICAgICAgICAgICAgd3JhcC5jbGFz
c05hbWUgPSAnaS10aHVtYi13cmFwJzsKICAgICAgICAgICAgICAgIGNvbnN0IGltZyAgPSBkb2N1bWVu
dC5jcmVhdGVFbGVtZW50KCdpbWcnKTsKICAgICAgICAgICAgICAgIGltZy5jbGFzc05hbWUgPSAnaS10
aHVtYic7CiAgICAgICAgICAgICAgICBpbWcuYWx0ID0gJyc7CiAgICAgICAgICAgICAgICBpbWcub25s
b2FkID0gKCkgPT4gewogICAgICAgICAgICAgICAgICAgIGNvbnN0IG13ID0gd3JhcC5jbGllbnRXaWR0
aCB8fCAzMDA7CiAgICAgICAgICAgICAgICAgICAgY29uc3QgbncgPSBpbWcubmF0dXJhbFdpZHRoICB8
fCAwOwogICAgICAgICAgICAgICAgICAgIGNvbnN0IG5oID0gaW1nLm5hdHVyYWxIZWlnaHQgfHwgMDsK
ICAgICAgICAgICAgICAgICAgICBpZiAoIW53IHx8ICFuaCkgcmV0dXJuOwogICAgICAgICAgICAgICAg
ICAgIGNvbnN0IHNjYWxlID0gTWF0aC5taW4oMSwgMTgwIC8gbmgsIG13IC8gbncpOwogICAgICAgICAg
ICAgICAgICAgIGltZy5zdHlsZS53aWR0aCAgPSBNYXRoLnJvdW5kKG53ICogc2NhbGUpICsgJ3B4JzsK
ICAgICAgICAgICAgICAgICAgICBpbWcuc3R5bGUuaGVpZ2h0ID0gTWF0aC5yb3VuZChuaCAqIHNjYWxl
KSArICdweCc7CiAgICAgICAgICAgICAgICB9OwogICAgICAgICAgICAvKiBlbnN1cmVGaWxlSW1nIGRl
ZmVycmVkOiBhdm9pZCBzeW5jIGZyZWV6ZSBvbiBmaWxlIHRhYiAqLwogICAgICAgICAgICAgICAgYmlu
ZFN0b3JlVGh1bWIoaW1nLCB0aHVtYkZpbGUsIGMuaWQsICcnKTsKICAgICAgICAgICAgICAgIHdyYXAu
YXBwZW5kQ2hpbGQoaW1nKTsKICAgICAgICAgICAgICAgIGJvZHkuYXBwZW5kQ2hpbGQod3JhcCk7CiAg
ICAgICAgICAgIH0KCiAgICAgICAgICAgIGNvbnN0IG5hbWUgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50
KCdkaXYnKTsKICAgICAgICAgICAgbmFtZS5jbGFzc05hbWUgID0gJ2ktbmFtZSc7CiAgICAgICAgICAg
IHNldEhsVGV4dChuYW1lLCBmaWxlcy5tYXAoZiA9PiBmLnNwbGl0KC9bXFwvXS8pLnBvcCgpKS5qb2lu
KCdcbicpIHx8ICco5paH5Lu2KScpOwoKICAgICAgICAgICAgZWwuX2ZpbGVQYXRocyA9IGZpbGVzOwoK
ICAgICAgICAgICAgY29uc3QgZGV0YWlsID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnZGl2Jyk7CiAg
ICAgICAgICAgIGRldGFpbC5jbGFzc05hbWUgPSAnaS1maWxlLWRldGFpbCc7CgogICAgICAgICAgICBj
b25zdCBtZXRhID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnZGl2Jyk7CiAgICAgICAgICAgIG1ldGEu
Y2xhc3NOYW1lID0gJ2ktbWV0YSc7CiAgICAgICAgICAgIGxldCByaWdodCA9ICcnOwogICAgICAgICAg
ICByaWdodCArPSBgPHNwYW4gY2xhc3M9ImktdGFnIj4ke2MuZmlsZUNvdW50IHx8IGZpbGVzLmxlbmd0
aCB8fCAxfSDkuKrmlofku7Y8L3NwYW4+YDsKICAgICAgICAgICAgaWYgKCh0aHVtYkZpbGUgfHwgaW1h
Z2VQYXRocy5sZW5ndGgpICYmIGMud2lkdGgpCiAgICAgICAgICAgICAgICByaWdodCArPSBgPHNwYW4g
Y2xhc3M9ImktdGFnIj4ke2Mud2lkdGh9w5cke2MuaGVpZ2h0fSBweDwvc3Bhbj5gOwogICAgICAgICAg
ICBjb25zdCBleHBhbmRIdG1sID0gZXhwYW5kQ2hldnJvbihmYWxzZSk7CiAgICAgICAgICAgIGNvbnN0
IGNvbGxhcHNlSHRtbCA9IGV4cGFuZENoZXZyb24odHJ1ZSk7CiAgICAgICAgICAgIG1ldGEuaW5uZXJI
VE1MID0KICAgICAgICAgICAgICAgIGA8c3BhbiBjbGFzcz0iaS10aW1lIj4ke2FnbyhjLnRpbWUpfTwv
c3Bhbj5gICsKICAgICAgICAgICAgICAgIG1ldGFDZW50ZXJIdG1sKHsgb246IHRydWUsIGh0bWw6IGV4
cGFuZEh0bWwgfSkgKwogICAgICAgICAgICAgICAgYDxkaXYgY2xhc3M9ImktbWV0YS1yaWdodCI+JHty
aWdodH08L2Rpdj5gOwoKICAgICAgICAgICAgY29uc3QgZXhwQnRuID0gbWV0YS5xdWVyeVNlbGVjdG9y
KCcuaS1leHBhbmQtYnRuJyk7CiAgICAgICAgICAgIGxldCBkZXRhaWxCdWlsdCA9IGZhbHNlOwogICAg
ICAgICAgICBleHBCdG4ub25jbGljayA9IGUgPT4gewogICAgICAgICAgICAgICAgZS5wcmV2ZW50RGVm
YXVsdCgpOwogICAgICAgICAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICAgICAgICAg
IGNvbnN0IG9wZW4gPSAhZGV0YWlsLmNsYXNzTGlzdC5jb250YWlucygnb24nKTsKICAgICAgICAgICAg
ICAgIGlmIChvcGVuICYmICFkZXRhaWxCdWlsdCkgewogICAgICAgICAgICAgICAgICAgIGNvbnN0IHBh
dGhSb3dzID0gZWwuX3BhdGhSb3dzIHx8IGNoZWNrRmlsZVBhdGhzKGVsLl9maWxlUGF0aHMgfHwgZmls
ZXMpOwogICAgICAgICAgICAgICAgICAgIGZpbGxGaWxlRGV0YWlsUGFuZWwoZGV0YWlsLCBwYXRoUm93
cyk7CiAgICAgICAgICAgICAgICAgICAgZGV0YWlsQnVpbHQgPSB0cnVlOwogICAgICAgICAgICAgICAg
fQogICAgICAgICAgICAgICAgZGV0YWlsLmNsYXNzTGlzdC50b2dnbGUoJ29uJywgb3Blbik7CiAgICAg
ICAgICAgICAgICBpZiAob3BlbikgewogICAgICAgICAgICAgICAgICAgIGRldGFpbC5zdHlsZS5tYXhI
ZWlnaHQgPSBsaXN0RXhwYW5kTWF4UHgoKSArICdweCc7CiAgICAgICAgICAgICAgICAgICAgZGV0YWls
LnN0eWxlLm92ZXJmbG93ID0gJ2F1dG8nOwogICAgICAgICAgICAgICAgfSBlbHNlIHsKICAgICAgICAg
ICAgICAgICAgICBkZXRhaWwuc3R5bGUubWF4SGVpZ2h0ID0gJyc7CiAgICAgICAgICAgICAgICAgICAg
ZGV0YWlsLnN0eWxlLm92ZXJmbG93ID0gJyc7CiAgICAgICAgICAgICAgICB9CiAgICAgICAgICAgICAg
ICBleHBCdG4uaW5uZXJIVE1MID0gb3BlbiA/IGNvbGxhcHNlSHRtbCA6IGV4cGFuZEh0bWw7CiAgICAg
ICAgICAgIH07CgogICAgICAgICAgICBib2R5LmFwcGVuZENoaWxkKG5hbWUpOwogICAgICAgICAgICBi
b2R5LmFwcGVuZENoaWxkKGRldGFpbCk7CiAgICAgICAgICAgIGJvZHkuYXBwZW5kQ2hpbGQobWV0YSk7
CiAgICAgICAgfSBlbHNlIHsKICAgICAgICAgICAgY29uc3QgdXNlTSA9IGNsaXBVc2VzTUljb24oYyk7
CiAgICAgICAgICAgIGljby5jbGFzc05hbWUgPSB1c2VNID8gJ2ktaWNvIG1kJyA6ICdpLWljbyB0ZXh0
JzsKICAgICAgICAgICAgaWNvLmlubmVySFRNTCA9IHVzZU0gPyAoU1ZHLm1kIHx8IFNWRy50ZXh0KSA6
IFNWRy50ZXh0OwogICAgICAgICAgICAvKiBwbGFpbi1saXN0LXByZXYgKi8KICAgICAgICAgICAgLyog
cHJldmlldy1lbGxpcHNpcyAqLwogICAgICAgICAgICBsZXQgdHh0ICA9IGMucHJldmlldyB8fCBjLmRh
dGEgfHwgJyc7CiAgICAgICAgICAgIHsgY29uc3QgX24gPSBOdW1iZXIoYy5jaGFyQ291bnQpIHx8IDA7
IGlmIChfbiA+IHR4dC5sZW5ndGggJiYgdHh0Lmxlbmd0aCkgdHh0ICs9ICcuLi4nOyB9CiAgICAgICAg
ICAgIGNvbnN0IHByZXYgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsKICAgICAgICAgICAg
cHJldi5jbGFzc05hbWUgID0gJ2ktcHJldicgKyAoaXNVcmwodHh0KSA/ICcgdXJsJyA6ICcnKTsKICAg
ICAgICAgICAgc2V0SGxUZXh0KHByZXYsIHR4dCk7CgogICAgICAgICAgICBjb25zdCBtZXRhID0gZG9j
dW1lbnQuY3JlYXRlRWxlbWVudCgnZGl2Jyk7CiAgICAgICAgICAgIG1ldGEuY2xhc3NOYW1lID0gJ2kt
bWV0YSc7CgogICAgICAgICAgICBjb25zdCBjaGFycyA9IE51bWJlcihjLmNoYXJDb3VudCkgfHwgMDsK
ICAgICAgICAgICAgY29uc3QgcmlnaHRIVE1MID0gYDxzcGFuIGNsYXNzPSJpLWNoYXJzIj48c3BhbiBj
bGFzcz0ibiI+JHtjaGFyc308L3NwYW4+IOWtl+espjwvc3Bhbj5gOwoKICAgICAgICAgICAgbWV0YS5p
bm5lckhUTUwgPQogICAgICAgICAgICAgICAgYDxzcGFuIGNsYXNzPSJpLXRpbWUiPiR7YWdvKGMudGlt
ZSl9PC9zcGFuPmAgKwogICAgICAgICAgICAgICAgbWV0YUNlbnRlckh0bWwoewogICAgICAgICAgICAg
ICAgICAgIG9uOiBmYWxzZSwKICAgICAgICAgICAgICAgICAgICBodG1sOiBleHBhbmRDaGV2cm9uKGZh
bHNlKQogICAgICAgICAgICAgICAgfSkgKwogICAgICAgICAgICAgICAgYDxkaXYgY2xhc3M9ImktbWV0
YS1yaWdodCB0ZXh0LW1ldGEiPiR7cmlnaHRIVE1MfTwvZGl2PmA7CgogICAgICAgICAgICBib2R5LmFw
cGVuZENoaWxkKHByZXYpOwogICAgICAgICAgICBib2R5LmFwcGVuZENoaWxkKG1ldGEpOwoKICAgICAg
ICAgICAgY29uc3QgZXhwQnRuID0gbWV0YS5xdWVyeVNlbGVjdG9yKCcuaS1leHBhbmQtYnRuJyk7CiAg
ICAgICAgICAgIGlmIChleHBCdG4pIHsKICAgICAgICAgICAgICAgIGV4cEJ0bi5vbmNsaWNrID0gZSA9
PiB7CiAgICAgICAgICAgICAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICAgICAgICAg
ICAgICBjb25zdCB3aWxsRXhwYW5kID0gIXByZXYuY2xhc3NMaXN0LmNvbnRhaW5zKCdleHBhbmRlZCcp
OwogICAgICAgICAgICAgICAgICAgIGlmICh3aWxsRXhwYW5kKSB7CiAgICAgICAgICAgICAgICAgICAg
ICAgIGFwcGx5RXhwYW5kZWRQcmV2aWV3KHByZXYsIHR4dCk7CiAgICAgICAgICAgICAgICAgICAgICAg
IGV4cEJ0bi5pbm5lckhUTUwgPSBleHBhbmRDaGV2cm9uKHRydWUpOwogICAgICAgICAgICAgICAgICAg
ICAgICB0cnkgeyBlbC5zY3JvbGxJbnRvVmlldyh7IGJsb2NrOiAnbmVhcmVzdCcgfSk7IH0gY2F0Y2gg
e30KICAgICAgICAgICAgICAgICAgICB9IGVsc2UgewogICAgICAgICAgICAgICAgICAgICAgICBjb2xs
YXBzZVByZXZpZXcocHJldiwgdHh0KTsKICAgICAgICAgICAgICAgICAgICAgICAgZXhwQnRuLmlubmVy
SFRNTCA9IGV4cGFuZENoZXZyb24oZmFsc2UpOwogICAgICAgICAgICAgICAgICAgIH0KICAgICAgICAg
ICAgICAgIH07CiAgICAgICAgICAgICAgICBjb25zdCBjaGVja092ZXJmbG93ID0gKCkgPT4gewogICAg
ICAgICAgICAgICAgICAgIGNvbnN0IHBsYWluTGVuID0gU3RyaW5nKGMucHJldmlldyB8fCBjLmRhdGEg
fHwgJycpLmxlbmd0aDsKICAgICAgICAgICAgICAgICAgICBjb25zdCBmdWxsTiA9IE51bWJlcihjLmNo
YXJDb3VudCkgfHwgMDsKICAgICAgICAgICAgICAgICAgICBjb25zdCB0cnVuYyA9IGZ1bGxOID4gcGxh
aW5MZW47CiAgICAgICAgICAgICAgICAgICAgaWYgKHByZXYuc2Nyb2xsSGVpZ2h0ID4gcHJldi5jbGll
bnRIZWlnaHQgKyAyIHx8IHRydW5jKQogICAgICAgICAgICAgICAgICAgICAgICBleHBCdG4uY2xhc3NM
aXN0LmFkZCgnb24nKTsKICAgICAgICAgICAgICAgICAgICBlbHNlCiAgICAgICAgICAgICAgICAgICAg
ICAgIGV4cEJ0bi5jbGFzc0xpc3QucmVtb3ZlKCdvbicpOwogICAgICAgICAgICAgICAgfTsKICAgICAg
ICAgICAgICAgIHJlcXVlc3RBbmltYXRpb25GcmFtZShjaGVja092ZXJmbG93KTsKICAgICAgICAgICAg
ICAgIHNldFRpbWVvdXQoY2hlY2tPdmVyZmxvdywgODApOwogICAgICAgICAgICB9CiAgICAgICAgfQoK
ICAgICAgICBjb25zdCBmYXZUID0gU3RyaW5nKGMuZmF2VGl0bGUgfHwgJycpLnRyaW0oKTsKICAgICAg
ICBpZiAoZmF2VCkgewogICAgICAgICAgICBjb25zdCBmdCA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQo
J2RpdicpOwogICAgICAgICAgICBmdC5jbGFzc05hbWUgPSAnaS1mYXYtdGl0bGUnOwogICAgICAgICAg
ICBzZXRIbFRleHQoZnQsIGZhdlQpOwogICAgICAgICAgICBib2R5Lmluc2VydEJlZm9yZShmdCwgYm9k
eS5maXJzdENoaWxkKTsKICAgICAgICB9CgogICAgICAgIGlmIChwYXN0ZWQpIHsKICAgICAgICAgICAg
ZWwuY2xhc3NMaXN0LmFkZCgncGFzdGVkJyk7CiAgICAgICAgICAgIGNvbnN0IGJhZGdlID0gZG9jdW1l
bnQuY3JlYXRlRWxlbWVudCgnc3BhbicpOwogICAgICAgICAgICBiYWRnZS5jbGFzc05hbWUgPSAnaS11
c2VkJzsKICAgICAgICAgICAgYmFkZ2UudGl0bGUgPSAn5bey57KY6LS0JzsKICAgICAgICAgICAgYmFk
Z2UuaW5uZXJIVE1MID0gYDxzdmcgdmlld0JveD0iMCAwIDE2IDE2IiBmaWxsPSJub25lIiBzdHJva2U9
ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIyLjQiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIgc3Ry
b2tlLWxpbmVqb2luPSJyb3VuZCI+PHBvbHlsaW5lIHBvaW50cz0iMy41IDguNSA2LjUgMTEuNSAxMi41
IDQuNSIvPjwvc3ZnPmA7CiAgICAgICAgICAgIGljby5hcHBlbmRDaGlsZChiYWRnZSk7CiAgICAgICAg
fQoKICAgICAgICBjb25zdCBudW0gPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsKICAgICAg
ICBudW0uY2xhc3NOYW1lID0gJ2ktbnVtJzsKICAgICAgICBjb25zdCBudW1UeHQgPSBkb2N1bWVudC5j
cmVhdGVFbGVtZW50KCdzcGFuJyk7CiAgICAgICAgbnVtVHh0LnRleHRDb250ZW50ID0gaWR4OwogICAg
ICAgIG51bS5hcHBlbmRDaGlsZChudW1UeHQpOwogICAgICAgIGNvbnN0IHNyY0ljbyA9IFN0cmluZyhj
LnNyY0ljb24gfHwgJycpOwogICAgICAgIGNvbnN0IHNyY0V4ZSA9IFN0cmluZyhjLnNyY0V4ZSB8fCAn
Jyk7CiAgICAgICAgY29uc3Qgc3JjVGl0bGUgPSBTdHJpbmcoYy5zcmNUaXRsZSB8fCAnJyk7CiAgICAg
ICAgaWYgKHNyY0ljbykgewogICAgICAgICAgICBjb25zdCBpbWcgPSBkb2N1bWVudC5jcmVhdGVFbGVt
ZW50KCdpbWcnKTsKICAgICAgICAgICAgaW1nLmNsYXNzTmFtZSA9ICdpLXNyYy1pY28nOwogICAgICAg
ICAgICBpbWcuc3JjID0gU1RPUkVfQkFTRSArIGVuY29kZVVSSUNvbXBvbmVudChzcmNJY28pOwogICAg
ICAgICAgICBpbWcuYWx0ID0gJyc7CiAgICAgICAgICAgIGNvbnN0IHRpcFR4dCA9IHNyY1RpdGxlIHx8
IHNyY0V4ZSB8fCAn5p2l5rqQJzsKICAgICAgICAgICAgaW1nLnRpdGxlID0gdGlwVHh0OwogICAgICAg
ICAgICBpbWcub25jbGljayA9IGUgPT4geyBlLnByZXZlbnREZWZhdWx0KCk7IGUuc3RvcFByb3BhZ2F0
aW9uKCk7IHNob3dTcmNUaXAoaW1nLCB0aXBUeHQpOyB9OwogICAgICAgICAgICBudW0uYXBwZW5kQ2hp
bGQoaW1nKTsKICAgICAgICB9CgogICAgICAgIGVsLmFwcGVuZENoaWxkKGljbyk7CiAgICAgICAgZWwu
YXBwZW5kQ2hpbGQoYm9keSk7CiAgICAgICAgZWwuYXBwZW5kQ2hpbGQobnVtKTsKCiAgICAgICAgZWwu
b25wb2ludGVyZG93biA9IGUgPT4gewogICAgICAgICAgICBiZWdpblBhc3RlRnJvbUl0ZW0oZSwgYyk7
CiAgICAgICAgfTsKICAgICAgICBlbC5vbmNvbnRleHRtZW51ID0gZSA9PiB7CiAgICAgICAgICAgIGUu
cHJldmVudERlZmF1bHQoKTsKICAgICAgICAgICAgc2VsZWN0ZWRJZCA9IGMuaWQ7CiAgICAgICAgICAg
IHNob3dDdHgoZS5jbGllbnRYLCBlLmNsaWVudFksIGMpOwogICAgICAgIH07CgogICAgICAgIHJldHVy
biBlbDsKICAgIH0KCiAgICBmdW5jdGlvbiBpdGVtSXNRdWV1ZURvbmUocm93KSB7CiAgICAgICAgaWYg
KCFyb3cpIHJldHVybiBmYWxzZTsKICAgICAgICBpZiAocm93LmNsYXNzTGlzdC5jb250YWlucygncGFz
dGVkJykgfHwgcm93LmNsYXNzTGlzdC5jb250YWlucygncS1kb25lJykpCiAgICAgICAgICAgIHJldHVy
biB0cnVlOwogICAgICAgIGNvbnN0IGlkID0gK3Jvdy5kYXRhc2V0LmlkOwogICAgICAgIGNvbnN0IGMg
PSBhbGxDbGlwcy5maW5kKHggPT4gK3guaWQgPT09IGlkKTsKICAgICAgICByZXR1cm4gISEoYyAmJiBp
c1Bhc3RlZChjKSk7CiAgICB9CgogICAgZnVuY3Rpb24gbWFya1F1ZXVlUmFpbHMoKSB7CiAgICAgICAg
aWYgKCFsaXN0RWwpIHJldHVybjsKICAgICAgICBjb25zdCBub2RlcyA9IFsuLi5saXN0RWwucXVlcnlT
ZWxlY3RvckFsbCgnLml0bS5xLW1lbWJlcicpXTsKICAgICAgICBpZiAoIW5vZGVzLmxlbmd0aCkgcmV0
dXJuOwogICAgICAgIC8vIFJlc2V0IGxpbmsgY2xhc3Nlczsga2VlcCBzdHJ1Y3R1cmFsIGVuZHMKICAg
ICAgICBub2Rlcy5mb3JFYWNoKG4gPT4gbi5jbGFzc0xpc3QucmVtb3ZlKCdxLWZpcnN0JywgJ3EtbGFz
dCcsICdxLW9ubHknLCAncS1kb25lLWxpbmsnLCAncS1wYXN0ZWQtbmV4dCcpKTsKICAgICAgICAvLyBH
cm91cCBjb25zZWN1dGl2ZSBzYW1lIHF1ZXVlR3JvdXAgaW4gRE9NIG9yZGVyCiAgICAgICAgbGV0IGkg
PSAwOwogICAgICAgIHdoaWxlIChpIDwgbm9kZXMubGVuZ3RoKSB7CiAgICAgICAgICAgIGNvbnN0IGcg
PSBub2Rlc1tpXS5kYXRhc2V0LnFnOwogICAgICAgICAgICBsZXQgaiA9IGkgKyAxOwogICAgICAgICAg
ICB3aGlsZSAoaiA8IG5vZGVzLmxlbmd0aCAmJiBub2Rlc1tqXS5kYXRhc2V0LnFnID09PSBnKSBqKys7
CiAgICAgICAgICAgIGNvbnN0IHNsaWNlID0gbm9kZXMuc2xpY2UoaSwgaik7CiAgICAgICAgICAgIGlm
IChzbGljZS5sZW5ndGggPT09IDEpIHsKICAgICAgICAgICAgICAgIHNsaWNlWzBdLmNsYXNzTGlzdC5h
ZGQoJ3Etb25seScpOwogICAgICAgICAgICB9IGVsc2UgewogICAgICAgICAgICAgICAgc2xpY2VbMF0u
Y2xhc3NMaXN0LmFkZCgncS1maXJzdCcpOwogICAgICAgICAgICAgICAgc2xpY2Vbc2xpY2UubGVuZ3Ro
IC0gMV0uY2xhc3NMaXN0LmFkZCgncS1sYXN0Jyk7CiAgICAgICAgICAgIH0KICAgICAgICAgICAgZm9y
IChsZXQgayA9IDA7IGsgPCBzbGljZS5sZW5ndGg7IGsrKykgewogICAgICAgICAgICAgICAgY29uc3Qg
ZG9uZSA9IGl0ZW1Jc1F1ZXVlRG9uZShzbGljZVtrXSk7CiAgICAgICAgICAgICAgICBzbGljZVtrXS5j
bGFzc0xpc3QudG9nZ2xlKCdxLWRvbmUnLCBkb25lKTsKICAgICAgICAgICAgICAgIGNvbnN0IGRvdCA9
IHNsaWNlW2tdLnF1ZXJ5U2VsZWN0b3IoJy5xLWRvdCcpOwogICAgICAgICAgICAgICAgaWYgKGRvdCkg
ZG90LnRpdGxlID0gZG9uZSA/ICfpmJ/liJflt7LnspjotLQnIDogJ+eymOi0tOmYn+WIlyc7CiAgICAg
ICAgICAgICAgICAvLyBHcmVlbiByYWlsIGZvciBldmVyeSBpdGVtIGluIGEgMisgZGVxdWV1ZWQgcnVu
IChpbmNsLiBmaXJzdC9sYXN0IHN0dWJzKQogICAgICAgICAgICAgICAgY29uc3QgcHJldkRvbmUgPSBr
ID4gMCAmJiBpdGVtSXNRdWV1ZURvbmUoc2xpY2VbayAtIDFdKTsKICAgICAgICAgICAgICAgIGNvbnN0
IG5leHREb25lID0gayA8IHNsaWNlLmxlbmd0aCAtIDEgJiYgaXRlbUlzUXVldWVEb25lKHNsaWNlW2sg
KyAxXSk7CiAgICAgICAgICAgICAgICBpZiAoZG9uZSAmJiAocHJldkRvbmUgfHwgbmV4dERvbmUpKQog
ICAgICAgICAgICAgICAgICAgIHNsaWNlW2tdLmNsYXNzTGlzdC5hZGQoJ3EtZG9uZS1saW5rJyk7CiAg
ICAgICAgICAgIH0KICAgICAgICAgICAgaSA9IGo7CiAgICAgICAgfQogICAgfQoKICAgIGNvbnN0IHBh
dGhUaXBFbCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdwYXRoLXRpcCcpOwogICAgbGV0IHBhdGhU
aXBUaW1lciA9IDA7CiAgICBsZXQgcGF0aFRpcEhpZGVUaW1lciA9IDA7CiAgICBsZXQgcGF0aFRpcFRv
a2VuID0gMDsKICAgIGxldCBwYXRoVGlwQW5jaG9yQnRuID0gbnVsbDsKCiAgICBmdW5jdGlvbiBoaWRl
UGF0aFRpcCgpIHsKICAgICAgICBjbGVhclRpbWVvdXQocGF0aFRpcFRpbWVyKTsKICAgICAgICBjbGVh
clRpbWVvdXQocGF0aFRpcEhpZGVUaW1lcik7CiAgICAgICAgcGF0aFRpcFRva2VuKys7CiAgICAgICAg
aWYgKHBhdGhUaXBBbmNob3JCdG4pIHsKICAgICAgICAgICAgcGF0aFRpcEFuY2hvckJ0bi5jbGFzc0xp
c3QucmVtb3ZlKCdvbicpOwogICAgICAgICAgICBwYXRoVGlwQW5jaG9yQnRuID0gbnVsbDsKICAgICAg
ICB9CiAgICAgICAgaWYgKHBhdGhUaXBFbCkgewogICAgICAgICAgICBwYXRoVGlwRWwuY2xhc3NMaXN0
LnJlbW92ZSgnb24nKTsKICAgICAgICAgICAgcGF0aFRpcEVsLnNldEF0dHJpYnV0ZSgnYXJpYS1oaWRk
ZW4nLCAndHJ1ZScpOwogICAgICAgIH0KICAgIH0KICAgIGZ1bmN0aW9uIHBsYWNlUGF0aFRpcChhbmNo
b3JFbCkgewogICAgICAgIGlmICghcGF0aFRpcEVsIHx8ICFhbmNob3JFbCkgcmV0dXJuOwogICAgICAg
IGNvbnN0IHRpcCA9IHBhdGhUaXBFbDsKICAgICAgICBjb25zdCBhciA9IGFuY2hvckVsLmdldEJvdW5k
aW5nQ2xpZW50UmVjdCgpOwogICAgICAgIGNvbnN0IHBhZCA9IDg7CiAgICAgICAgdGlwLnN0eWxlLmxl
ZnQgPSAnMHB4JzsKICAgICAgICB0aXAuc3R5bGUudG9wID0gJzBweCc7CiAgICAgICAgdGlwLmNsYXNz
TGlzdC5hZGQoJ29uJyk7CiAgICAgICAgY29uc3QgdHcgPSB0aXAub2Zmc2V0V2lkdGg7CiAgICAgICAg
Y29uc3QgdGggPSB0aXAub2Zmc2V0SGVpZ2h0OwogICAgICAgIGxldCBsZWZ0ID0gYXIubGVmdDsKICAg
ICAgICBsZXQgdG9wID0gYXIuYm90dG9tICsgNjsKICAgICAgICBpZiAobGVmdCArIHR3ID4gd2luZG93
LmlubmVyV2lkdGggLSBwYWQpCiAgICAgICAgICAgIGxlZnQgPSBNYXRoLm1heChwYWQsIHdpbmRvdy5p
bm5lcldpZHRoIC0gdHcgLSBwYWQpOwogICAgICAgIGlmIChsZWZ0IDwgcGFkKSBsZWZ0ID0gcGFkOwog
ICAgICAgIGlmICh0b3AgKyB0aCA+IHdpbmRvdy5pbm5lckhlaWdodCAtIHBhZCkKICAgICAgICAgICAg
dG9wID0gTWF0aC5tYXgocGFkLCBhci50b3AgLSB0aCAtIDYpOwogICAgICAgIHRpcC5zdHlsZS5sZWZ0
ID0gbGVmdCArICdweCc7CiAgICAgICAgdGlwLnN0eWxlLnRvcCA9IHRvcCArICdweCc7CiAgICB9CiAg
ICAgICAgZnVuY3Rpb24gY2hlY2tGaWxlUGF0aHMocGF0aHMpIHsKICAgICAgICBjb25zdCBsaXN0ID0g
KHBhdGhzIHx8IFtdKS5tYXAocCA9PiB7CiAgICAgICAgICAgIGxldCBwYXRoID0gU3RyaW5nKHAgfHwg
JycpLnRyaW0oKTsKICAgICAgICAgICAgaWYgKChwYXRoLnN0YXJ0c1dpdGgoJyInKSAmJiBwYXRoLmVu
ZHNXaXRoKCciJykpIHx8IChwYXRoLnN0YXJ0c1dpdGgoIiciKSAmJiBwYXRoLmVuZHNXaXRoKCInIikp
KQogICAgICAgICAgICAgICAgcGF0aCA9IHBhdGguc2xpY2UoMSwgLTEpLnRyaW0oKTsKICAgICAgICAg
ICAgcmV0dXJuIHBhdGg7CiAgICAgICAgfSk7CiAgICAgICAgLy8gT25lIGhvc3Qgcm91bmQtdHJpcCBm
b3IgdGhlIHdob2xlIGxpc3Qg4oCUIE7DlyBwYXRoRXhpc3RzIGZyZWV6ZXMgZmlsZSB0YWIKICAgICAg
ICB0cnkgewogICAgICAgICAgICBjb25zdCByYXcgPSBhaGtSZXQoJ2NoZWNrUGF0aHMnLCBsaXN0Lmpv
aW4oJ1xuJykpOwogICAgICAgICAgICBpZiAocmF3KSB7CiAgICAgICAgICAgICAgICBjb25zdCBwYXJz
ZWQgPSB0eXBlb2YgcmF3ID09PSAnc3RyaW5nJyA/IEpTT04ucGFyc2UocmF3KSA6IHJhdzsKICAgICAg
ICAgICAgICAgIGlmIChBcnJheS5pc0FycmF5KHBhcnNlZCkgJiYgcGFyc2VkLmxlbmd0aCkgewogICAg
ICAgICAgICAgICAgICAgIHJldHVybiBsaXN0Lm1hcCgocGF0aCwgaSkgPT4gewogICAgICAgICAgICAg
ICAgICAgICAgICBjb25zdCByb3cgPSBwYXJzZWRbaV0gfHwge307CiAgICAgICAgICAgICAgICAgICAg
ICAgIHJldHVybiB7CiAgICAgICAgICAgICAgICAgICAgICAgICAgICBwYXRoOiBwYXRoIHx8IFN0cmlu
Zyhyb3cucGF0aCB8fCAnJyksCiAgICAgICAgICAgICAgICAgICAgICAgICAgICBleGlzdHM6IHJvdy5l
eGlzdHMgPT09IHRydWUgfHwgcm93LmV4aXN0cyA9PT0gMSB8fCByb3cuZXhpc3RzID09PSAnMScsCiAg
ICAgICAgICAgICAgICAgICAgICAgICAgICBpc0RpcjogISEocm93LmlzRGlyID09PSB0cnVlIHx8IHJv
dy5pc0RpciA9PT0gMSB8fCByb3cuaXNEaXIgPT09ICcxJykKICAgICAgICAgICAgICAgICAgICAgICAg
fTsKICAgICAgICAgICAgICAgICAgICB9KTsKICAgICAgICAgICAgICAgIH0KICAgICAgICAgICAgfQog
ICAgICAgIH0gY2F0Y2gge30KICAgICAgICByZXR1cm4gbGlzdC5tYXAocGF0aCA9PiB7CiAgICAgICAg
ICAgIGlmICghcGF0aCkgcmV0dXJuIHsgcGF0aCwgZXhpc3RzOiBmYWxzZSwgaXNEaXI6IGZhbHNlIH07
CiAgICAgICAgICAgIGxldCBleGlzdHMgPSBmYWxzZTsKICAgICAgICAgICAgdHJ5IHsKICAgICAgICAg
ICAgICAgIGNvbnN0IGZsYWcgPSBTdHJpbmcoYWhrUmV0KCdwYXRoRXhpc3RzJywgcGF0aCkgPz8gJycp
LnRyaW0oKS50b0xvd2VyQ2FzZSgpOwogICAgICAgICAgICAgICAgZXhpc3RzID0gKGZsYWcgPT09ICcx
JyB8fCBmbGFnID09PSAndHJ1ZScpOwogICAgICAgICAgICB9IGNhdGNoIHt9CiAgICAgICAgICAgIHJl
dHVybiB7IHBhdGgsIGV4aXN0cywgaXNEaXI6IGZhbHNlIH07CiAgICAgICAgfSk7CiAgICB9CiAgICBs
ZXQgZ29uZUNoZWNrVGltZXIgPSAwOwogICAgZnVuY3Rpb24gc2NoZWR1bGVGaWxlR29uZUNoZWNrKCkg
ewogICAgICAgIGlmIChnb25lQ2hlY2tUaW1lcikgcmV0dXJuOwogICAgICAgIGdvbmVDaGVja1RpbWVy
ID0gc2V0VGltZW91dCgoKSA9PiB7CiAgICAgICAgICAgIGdvbmVDaGVja1RpbWVyID0gMDsKICAgICAg
ICAgICAgY29uc3Qgbm9kZXMgPSBbLi4ubGlzdEVsLnF1ZXJ5U2VsZWN0b3JBbGwoJy5pdG0nKV0uZmls
dGVyKG4gPT4gbi5fZmlsZVBhdGhzICYmIG4uX2ZpbGVQYXRocy5sZW5ndGgpOwogICAgICAgICAgICBp
ZiAoIW5vZGVzLmxlbmd0aCkgcmV0dXJuOwogICAgICAgICAgICBjb25zdCB1bmlxdWUgPSBbXTsKICAg
ICAgICAgICAgY29uc3Qgc2VlbiA9IG5ldyBTZXQoKTsKICAgICAgICAgICAgbm9kZXMuZm9yRWFjaChu
ID0+IHsKICAgICAgICAgICAgICAgIG4uX2ZpbGVQYXRocy5mb3JFYWNoKHAgPT4gewogICAgICAgICAg
ICAgICAgICAgIGNvbnN0IHBhdGggPSBTdHJpbmcocCB8fCAnJyk7CiAgICAgICAgICAgICAgICAgICAg
aWYgKCFwYXRoIHx8IHNlZW4uaGFzKHBhdGgpKSByZXR1cm47CiAgICAgICAgICAgICAgICAgICAgc2Vl
bi5hZGQocGF0aCk7CiAgICAgICAgICAgICAgICAgICAgdW5pcXVlLnB1c2gocGF0aCk7CiAgICAgICAg
ICAgICAgICB9KTsKICAgICAgICAgICAgfSk7CiAgICAgICAgICAgIGNvbnN0IHJvd3MgPSBjaGVja0Zp
bGVQYXRocyh1bmlxdWUpOwogICAgICAgICAgICBjb25zdCBieVBhdGggPSBuZXcgTWFwKCk7CiAgICAg
ICAgICAgIHJvd3MuZm9yRWFjaChyID0+IGJ5UGF0aC5zZXQoU3RyaW5nKHIucGF0aCB8fCAnJyksIHIp
KTsKICAgICAgICAgICAgbm9kZXMuZm9yRWFjaChuID0+IHsKICAgICAgICAgICAgICAgIGNvbnN0IHBh
dGhSb3dzID0gbi5fZmlsZVBhdGhzLm1hcChwID0+IHsKICAgICAgICAgICAgICAgICAgICBjb25zdCBo
aXQgPSBieVBhdGguZ2V0KFN0cmluZyhwIHx8ICcnKSk7CiAgICAgICAgICAgICAgICAgICAgcmV0dXJu
IGhpdCB8fCB7IHBhdGg6IHAsIGV4aXN0czogdHJ1ZSwgaXNEaXI6IGZhbHNlIH07CiAgICAgICAgICAg
ICAgICB9KTsKICAgICAgICAgICAgICAgIG4uX3BhdGhSb3dzID0gcGF0aFJvd3M7CiAgICAgICAgICAg
ICAgICBjb25zdCBhbGxHb25lID0gcGF0aFJvd3MubGVuZ3RoID4gMCAmJiBwYXRoUm93cy5ldmVyeShy
ID0+IHIuZXhpc3RzID09PSBmYWxzZSk7CiAgICAgICAgICAgICAgICBuLmNsYXNzTGlzdC50b2dnbGUo
J2dvbmUnLCBhbGxHb25lKTsKICAgICAgICAgICAgfSk7CiAgICAgICAgfSwgNDAwKTsKICAgIH0KICAg
IGZ1bmN0aW9uIGZpbGxGaWxlRGV0YWlsUGFuZWwoY29udGFpbmVyLCByb3dzKSB7CiAgICAgICAgY29u
dGFpbmVyLmlubmVySFRNTCA9ICcnOwogICAgICAgIGlmICghcm93cy5sZW5ndGgpIHsKICAgICAgICAg
ICAgY29uc3QgZW1wdHkgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsKICAgICAgICAgICAg
ZW1wdHkuY2xhc3NOYW1lID0gJ2ZkLXBhdGgnOwogICAgICAgICAgICBlbXB0eS50ZXh0Q29udGVudCA9
ICfml6Dot6/lvoQnOwogICAgICAgICAgICBjb250YWluZXIuYXBwZW5kQ2hpbGQoZW1wdHkpOwogICAg
ICAgICAgICByZXR1cm47CiAgICAgICAgfQogICAgICAgIHJvd3MuZm9yRWFjaChyID0+IHsKICAgICAg
ICAgICAgY29uc3QgcGF0aCA9IFN0cmluZyhyLnBhdGggfHwgJycpOwogICAgICAgICAgICBjb25zdCBt
aXNzaW5nID0gci5leGlzdHMgPT09IGZhbHNlOwogICAgICAgICAgICBjb25zdCBibG9jayA9IGRvY3Vt
ZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOwogICAgICAgICAgICBibG9jay5jbGFzc05hbWUgPSAnZmQt
YmxvY2snOwoKICAgICAgICAgICAgY29uc3QgcGF0aEVsID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgn
ZGl2Jyk7CiAgICAgICAgICAgIHBhdGhFbC5jbGFzc05hbWUgPSAnZmQtcGF0aCcgKyAobWlzc2luZyA/
ICcgZGVhZCcgOiAnIGxpdmUnKTsKICAgICAgICAgICAgcGF0aEVsLnRleHRDb250ZW50ID0gcGF0aCB8
fCAnKOepuui3r+W+hCknOwogICAgICAgICAgICBpZiAoIW1pc3NpbmcpIHsKICAgICAgICAgICAgICAg
IHBhdGhFbC5vbmNsaWNrID0gZSA9PiB7CiAgICAgICAgICAgICAgICAgICAgZS5wcmV2ZW50RGVmYXVs
dCgpOwogICAgICAgICAgICAgICAgICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAgICAgICAgICAg
ICAgICAgYWhrKCdvcGVuUGF0aCcsIHBhdGgpOwogICAgICAgICAgICAgICAgfTsKICAgICAgICAgICAg
fQogICAgICAgICAgICBibG9jay5hcHBlbmRDaGlsZChwYXRoRWwpOwoKICAgICAgICAgICAgY29uc3Qg
YWN0aW9ucyA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOwogICAgICAgICAgICBhY3Rpb25z
LmNsYXNzTmFtZSA9ICdmZC1hY3Rpb25zJzsKCiAgICAgICAgICAgIGNvbnN0IGNvcHlCdG4gPSBkb2N1
bWVudC5jcmVhdGVFbGVtZW50KCdidXR0b24nKTsKICAgICAgICAgICAgY29weUJ0bi50eXBlID0gJ2J1
dHRvbic7CiAgICAgICAgICAgIGNvcHlCdG4uY2xhc3NOYW1lID0gJ2ZkLWJ0bic7CiAgICAgICAgICAg
IGNvcHlCdG4uaW5uZXJIVE1MID0gJzxzcGFuIGNsYXNzPSJmZC1pY28iPvCflJc8L3NwYW4+PHNwYW4g
Y2xhc3M9ImZkLXR4dCI+5aSN5Yi26Lev5b6EPC9zcGFuPic7CiAgICAgICAgICAgIGNvcHlCdG4ub25j
bGljayA9IGUgPT4gewogICAgICAgICAgICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOwogICAgICAgICAg
ICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICAgICAgICAgIGFoaygnY29weVBhdGgnLCBw
YXRoKTsKICAgICAgICAgICAgICAgIGNvcHlCdG4ucXVlcnlTZWxlY3RvcignLmZkLXR4dCcpLnRleHRD
b250ZW50ID0gJ+W3suWkjeWItic7CiAgICAgICAgICAgICAgICBjb3B5QnRuLmNsYXNzTGlzdC5hZGQo
J29rJyk7CiAgICAgICAgICAgICAgICBzZXRUaW1lb3V0KCgpID0+IHsKICAgICAgICAgICAgICAgICAg
ICBjb3B5QnRuLnF1ZXJ5U2VsZWN0b3IoJy5mZC10eHQnKS50ZXh0Q29udGVudCA9ICflpI3liLbot6/l
voQnOwogICAgICAgICAgICAgICAgICAgIGNvcHlCdG4uY2xhc3NMaXN0LnJlbW92ZSgnb2snKTsKICAg
ICAgICAgICAgICAgIH0sIDEyMDApOwogICAgICAgICAgICB9OwogICAgICAgICAgICBhY3Rpb25zLmFw
cGVuZENoaWxkKGNvcHlCdG4pOwoKICAgICAgICAgICAgY29uc3QgZm9sZGVyQnRuID0gZG9jdW1lbnQu
Y3JlYXRlRWxlbWVudCgnYnV0dG9uJyk7CiAgICAgICAgICAgIGZvbGRlckJ0bi50eXBlID0gJ2J1dHRv
bic7CiAgICAgICAgICAgIGZvbGRlckJ0bi5jbGFzc05hbWUgPSAnZmQtYnRuJzsKICAgICAgICAgICAg
Zm9sZGVyQnRuLmlubmVySFRNTCA9ICc8c3BhbiBjbGFzcz0iZmQtaWNvIj7wn5OCPC9zcGFuPjxzcGFu
IGNsYXNzPSJmZC10eHQiPuaJk+W8gOaJgOWcqOaWh+S7tuWkuTwvc3Bhbj4nOwogICAgICAgICAgICBm
b2xkZXJCdG4ub25jbGljayA9IGUgPT4gewogICAgICAgICAgICAgICAgZS5wcmV2ZW50RGVmYXVsdCgp
OwogICAgICAgICAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICAgICAgICAgIGFoaygn
b3BlbkZvbGRlcicsIHBhdGgpOwogICAgICAgICAgICB9OwogICAgICAgICAgICBhY3Rpb25zLmFwcGVu
ZENoaWxkKGZvbGRlckJ0bik7CgogICAgICAgICAgICBibG9jay5hcHBlbmRDaGlsZChhY3Rpb25zKTsK
ICAgICAgICAgICAgY29udGFpbmVyLmFwcGVuZENoaWxkKGJsb2NrKTsKICAgICAgICB9KTsKICAgIH0K
CiAgICBjb25zdCBjdHhFbCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjdHgnKTsKICAgIGZ1bmN0
aW9uIHNob3dDdHgoeCwgeSwgYykgewogICAgICAgIGN0eENsaXAgPSBjOwogICAgICAgIHNlbGVjdGVk
SWQgPSBjLmlkOwogICAgICAgIHJhbmdlQW5jaG9ySWQgPSBjLmlkOwogICAgICAgIHJhbmdlQW5jaG9y
Q2xpY2tlZCA9IHRydWU7CiAgICAgICAgY29uc3QgY2xlYXJCdG4gPSBkb2N1bWVudC5nZXRFbGVtZW50
QnlJZCgnYy1jbGVhci1wYXN0ZWQnKTsKICAgICAgICBpZiAoY2xlYXJCdG4pIGNsZWFyQnRuLnN0eWxl
LmRpc3BsYXkgPSBpc1Bhc3RlZChjKSA/ICcnIDogJ25vbmUnOwogICAgICAgIGNvbnN0IHFGcm9tID0g
ZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2MtcXVldWUtZnJvbScpOwogICAgICAgIGlmIChxRnJvbSkg
cUZyb20uc3R5bGUuZGlzcGxheSA9IChOdW1iZXIoYy5xdWV1ZUdyb3VwKSA+IDApID8gJycgOiAnbm9u
ZSc7CgogICAgICAgIGNvbnN0IHBpbkJ0biA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjLXBpbicp
OwogICAgICAgIGlmIChwaW5CdG4pIHsKICAgICAgICAgICAgY29uc3Qgb24gPSBpc1Bpbm5lZChjKTsK
ICAgICAgICAgICAgcGluQnRuLmlubmVySFRNTCA9IG9uCiAgICAgICAgICAgICAgICA/ICc8c3BhbiBj
bGFzcz0iYy1pY28iPuKYhTwvc3Bhbj7lj5bmtojmlLbol48nCiAgICAgICAgICAgICAgICA6ICc8c3Bh
biBjbGFzcz0iYy1pY28iPuKYhTwvc3Bhbj7mlLbol48nOwogICAgICAgIH0KICAgICAgICBjb25zdCB0
aXRsZUJ0biA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjLXRpdGxlJyk7CiAgICAgICAgaWYgKHRp
dGxlQnRuKSB7CiAgICAgICAgICAgIGNvbnN0IHNob3dUaXRsZSA9IGlzUGlubmVkKGMpIHx8IGN1clRh
YiA9PT0gJ3Bpbm5lZCc7CiAgICAgICAgICAgIHRpdGxlQnRuLnN0eWxlLmRpc3BsYXkgPSBzaG93VGl0
bGUgPyAnJyA6ICdub25lJzsKICAgICAgICAgICAgaWYgKHNob3dUaXRsZSkKICAgICAgICAgICAgICAg
IHRpdGxlQnRuLmlubmVySFRNTCA9IChTdHJpbmcoYy5mYXZUaXRsZSB8fCAnJykudHJpbSgpID8gJzxz
cGFuIGNsYXNzPSJjLWljbyI+4pyOPC9zcGFuPue8lui+keagh+mimCcgOiAnPHNwYW4gY2xhc3M9ImMt
aWNvIj7inI48L3NwYW4+6K6+572u5qCH6aKYJyk7CiAgICAgICAgfQogICAgICAgIGNvbnN0IG1lcmdl
QnRuID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2MtbWVyZ2UnKTsKICAgICAgICBjb25zdCB1bm1l
cmdlQnRuID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2MtdW5tZXJnZScpOwogICAgICAgIGNvbnN0
IG9uUGlubmVkID0gY3VyVGFiID09PSAncGlubmVkJzsKICAgICAgICBpZiAobWVyZ2VCdG4pCiAgICAg
ICAgICAgIG1lcmdlQnRuLnN0eWxlLmRpc3BsYXkgPSAob25QaW5uZWQgJiYgbXVsdGlJZHMubGVuZ3Ro
ID49IDIpID8gJycgOiAnbm9uZSc7CiAgICAgICAgaWYgKHVubWVyZ2VCdG4pCiAgICAgICAgICAgIHVu
bWVyZ2VCdG4uc3R5bGUuZGlzcGxheSA9IChvblBpbm5lZCAmJiBmYXZHcm91cE9mKGMpKSA/ICcnIDog
J25vbmUnOwogICAgICAgIGNvbnN0IGRlbEJ0biA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjLWRl
bCcpOwogICAgICAgIGlmIChkZWxCdG4pIHsKICAgICAgICAgICAgY29uc3QgbXVsdGlEZWwgPSBtdWx0
aUlkcy5sZW5ndGggPiAxICYmIG11bHRpSWRzLmluY2x1ZGVzKCtjLmlkKTsKICAgICAgICAgICAgY29u
c3QgbiA9IG11bHRpRGVsID8gbXVsdGlJZHMubGVuZ3RoIDogMTsKICAgICAgICAgICAgZGVsQnRuLmlu
bmVySFRNTCA9IG4gPiAxCiAgICAgICAgICAgICAgICA/ICgnPHNwYW4gY2xhc3M9ImMtaWNvIj7inJU8
L3NwYW4+5Yig6ZmkICgnICsgbiArICcpJykKICAgICAgICAgICAgICAgIDogJzxzcGFuIGNsYXNzPSJj
LWljbyI+4pyVPC9zcGFuPuWIoOmZpCc7CiAgICAgICAgfQogICAgICAgIGN0eEVsLmNsYXNzTGlzdC5h
ZGQoJ29uJyk7CiAgICAgICAgY3R4RWwuc3R5bGUubGVmdCA9IHggKyAncHgnOwogICAgICAgIGN0eEVs
LnN0eWxlLnRvcCAgPSB5ICsgJ3B4JzsKICAgICAgICByZXF1ZXN0QW5pbWF0aW9uRnJhbWUoKCkgPT4g
ewogICAgICAgICAgICBjb25zdCByID0gY3R4RWwuZ2V0Qm91bmRpbmdDbGllbnRSZWN0KCk7CiAgICAg
ICAgICAgIGlmIChyLnJpZ2h0ICA+IGlubmVyV2lkdGgpICBjdHhFbC5zdHlsZS5sZWZ0ID0gKHggLSBy
LndpZHRoKSAgKyAncHgnOwogICAgICAgICAgICBpZiAoci5ib3R0b20gPiBpbm5lckhlaWdodCkgY3R4
RWwuc3R5bGUudG9wICA9ICh5IC0gci5oZWlnaHQpICsgJ3B4JzsKICAgICAgICB9KTsKICAgIH0KICAg
IGZ1bmN0aW9uIGhpZGVDdHgoKSB7IGN0eEVsLmNsYXNzTGlzdC5yZW1vdmUoJ29uJyk7IGN0eENsaXAg
PSBudWxsOyB9CiAgICB3aW5kb3cuX19oaWRlQ3R4ID0gaGlkZUN0eDsKCiAgICBmdW5jdGlvbiBkaXNt
aXNzQ3R4VW5sZXNzSW5zaWRlKGUpIHsKICAgICAgICBpZiAoIWN0eEVsLmNsYXNzTGlzdC5jb250YWlu
cygnb24nKSkgcmV0dXJuOwogICAgICAgIGlmIChlLnRhcmdldC5jbG9zZXN0KCcjY3R4JykpIHJldHVy
bjsKICAgICAgICBoaWRlQ3R4KCk7CiAgICB9CiAgICBkb2N1bWVudC5hZGRFdmVudExpc3RlbmVyKCdt
b3VzZWRvd24nLCBkaXNtaXNzQ3R4VW5sZXNzSW5zaWRlLCB0cnVlKTsKICAgIGRvY3VtZW50LmFkZEV2
ZW50TGlzdGVuZXIoJ2NsaWNrJywgZGlzbWlzc0N0eFVubGVzc0luc2lkZSwgdHJ1ZSk7CiAgICBsaXN0
RWwuYWRkRXZlbnRMaXN0ZW5lcignc2Nyb2xsJywgaGlkZUN0eCwgeyBwYXNzaXZlOiB0cnVlIH0pOwog
ICAgZG9jdW1lbnQuYWRkRXZlbnRMaXN0ZW5lcigna2V5ZG93bicsIGUgPT4gewogICAgICAgIC8vIEVz
YzogYWx3YXlzIGNsb3NlIHBhbmVsIChzZWFyY2ggb3Igbm90KTsgcGluIGtlZXBzIHBhbmVsCiAgICAg
ICAgaWYgKGUua2V5ID09PSAnRXNjYXBlJykgewogICAgICAgICAgICBlLnByZXZlbnREZWZhdWx0KCk7
CiAgICAgICAgICAgIGhpZGVDdHgoKTsKICAgICAgICAgICAgY29uc3QgdGQgPSBkb2N1bWVudC5nZXRF
bGVtZW50QnlJZCgndGl0bGUtZGxnJyk7CiAgICAgICAgICAgIGlmICh0ZCAmJiB0ZC5jbGFzc0xpc3Qu
Y29udGFpbnMoJ29uJykpIHsKICAgICAgICAgICAgICAgIHRyeSB7IGNsb3NlVGl0bGVEbGcoKTsgfSBj
YXRjaCB7IHRkLmNsYXNzTGlzdC5yZW1vdmUoJ29uJyk7IH0KICAgICAgICAgICAgICAgIHJldHVybjsK
ICAgICAgICAgICAgfQogICAgICAgICAgICBpZiAoY2xyRGxnLmNsYXNzTGlzdC5jb250YWlucygnb24n
KSkgewogICAgICAgICAgICAgICAgY2xvc2VDbGVhckRsZygpOwogICAgICAgICAgICAgICAgcmV0dXJu
OwogICAgICAgICAgICB9CiAgICAgICAgICAgIGlmICghcGlubmVkVUkpIGFoaygnaGlkZScpOwogICAg
ICAgICAgICByZXR1cm47CiAgICAgICAgfQogICAgICAgIC8vIFdoaWxlIHR5cGluZyBpbiBzZWFyY2g6
IEN0cmwrSS9LIGFuZCBhcnJvd3MgbW92ZSBsaXN0LCBkb24ndCBsZWF2ZSB0aGUgYm94CiAgICAgICAg
aWYgKGRvY3VtZW50LmFjdGl2ZUVsZW1lbnQ/LmlkID09PSAnc2VhcmNoJykgewogICAgICAgICAgICBp
ZiAoKGUuY3RybEtleSB8fCBlLm1ldGFLZXkpICYmIChlLmtleSA9PT0gJ2knIHx8IGUua2V5ID09PSAn
SScpKSB7CiAgICAgICAgICAgICAgICBlLnByZXZlbnREZWZhdWx0KCk7IGUuc3RvcFByb3BhZ2F0aW9u
KCk7CiAgICAgICAgICAgICAgICB3aW5kb3cuX19uYXYgJiYgd2luZG93Ll9fbmF2KCd1cCcpOwogICAg
ICAgICAgICAgICAgcmV0dXJuOwogICAgICAgICAgICB9CiAgICAgICAgICAgIGlmICgoZS5jdHJsS2V5
IHx8IGUubWV0YUtleSkgJiYgKGUua2V5ID09PSAnaycgfHwgZS5rZXkgPT09ICdLJykpIHsKICAgICAg
ICAgICAgICAgIGUucHJldmVudERlZmF1bHQoKTsgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICAg
ICAgICAgIHdpbmRvdy5fX25hdiAmJiB3aW5kb3cuX19uYXYoJ2Rvd24nKTsKICAgICAgICAgICAgICAg
IHJldHVybjsKICAgICAgICAgICAgfQogICAgICAgICAgICBpZiAoZS5rZXkgPT09ICdBcnJvd0Rvd24n
KSB7CiAgICAgICAgICAgICAgICBlLnByZXZlbnREZWZhdWx0KCk7IGUuc3RvcFByb3BhZ2F0aW9uKCk7
CiAgICAgICAgICAgICAgICB3aW5kb3cuX19uYXYgJiYgd2luZG93Ll9fbmF2KCdkb3duJyk7CiAgICAg
ICAgICAgICAgICByZXR1cm47CiAgICAgICAgICAgIH0KICAgICAgICAgICAgaWYgKGUua2V5ID09PSAn
QXJyb3dVcCcpIHsKICAgICAgICAgICAgICAgIGUucHJldmVudERlZmF1bHQoKTsgZS5zdG9wUHJvcGFn
YXRpb24oKTsKICAgICAgICAgICAgICAgIHdpbmRvdy5fX25hdiAmJiB3aW5kb3cuX19uYXYoJ3VwJyk7
CiAgICAgICAgICAgICAgICByZXR1cm47CiAgICAgICAgICAgIH0KICAgICAgICAgICAgcmV0dXJuOwog
ICAgICAgIH0KICAgICAgICBjb25zdCB2aXMgPSAodHlwZW9mIG5hdkxpc3QgPT09ICdmdW5jdGlvbicg
PyBuYXZMaXN0KCkgOiB2aXNpYmxlTGlzdCgpKTsKICAgICAgICBpZiAoIXZpcy5sZW5ndGgpIHJldHVy
bjsKICAgICAgICBsZXQgaWR4ID0gc2VsZWN0ZWRJbmRleCgpOwogICAgICAgIGlmIChpZHggPCAwKSBp
ZHggPSAwOwogICAgICAgIGlmICAgICAgKGUua2V5ID09PSAnQXJyb3dEb3duJykgeyBlLnByZXZlbnRE
ZWZhdWx0KCk7IGUuc3RvcFByb3BhZ2F0aW9uKCk7IHNlbGVjdEJ5SW5kZXgoaWR4ICsgMSk7IH0KICAg
ICAgICBlbHNlIGlmIChlLmtleSA9PT0gJ0Fycm93VXAnKSAgIHsgZS5wcmV2ZW50RGVmYXVsdCgpOyBl
LnN0b3BQcm9wYWdhdGlvbigpOyBzZWxlY3RCeUluZGV4KGlkeCAtIDEpOyB9CiAgICAgICAgZWxzZSBp
ZiAoZS5rZXkgPT09ICdFbnRlcicpIHsKICAgICAgICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOwogICAg
ICAgICAgICAvLyDlm7rlrprml7blm57ovabkuI3nspjotLTvvIzlj6rngrnmnaHnm67nspjotLQKICAg
ICAgICAgICAgaWYgKHBpbm5lZFVJKSByZXR1cm47CiAgICAgICAgICAgIGlmIChtdWx0aUlkcy5sZW5n
dGggPiAxKSB7CiAgICAgICAgICAgICAgICBjb25zdCBpZHMgPSBtdWx0aUlkcy5zbGljZSgpOwogICAg
ICAgICAgICAgICAgY2xlYXJNdWx0aSgpOwogICAgICAgICAgICAgICAgbWFya1Bhc3RlZExvY2FsKGlk
cyk7CiAgICAgICAgICAgICAgICBhaGsoJ3Bhc3RlTWFueScsIGlkcy5qb2luKCcsJykpOwogICAgICAg
ICAgICAgICAgcmV0dXJuOwogICAgICAgICAgICB9CiAgICAgICAgICAgIGlmIChtdWx0aUlkcy5sZW5n
dGggPT09IDEpIHsKICAgICAgICAgICAgICAgIGNvbnN0IGlkID0gbXVsdGlJZHNbMF07CiAgICAgICAg
ICAgICAgICBjbGVhck11bHRpKCk7CiAgICAgICAgICAgICAgICBtYXJrUGFzdGVkTG9jYWwoaWQpOwog
ICAgICAgICAgICAgICAgYWhrKCdwYXN0ZScsIFN0cmluZyhpZCkpOwogICAgICAgICAgICAgICAgcmV0
dXJuOwogICAgICAgICAgICB9CiAgICAgICAgICAgIGNvbnN0IGMgPSB2aXNbc2VsZWN0ZWRJbmRleCgp
XTsKICAgICAgICAgICAgaWYgKGMpIHsKICAgICAgICAgICAgICAgIG1hcmtQYXN0ZWRMb2NhbChjLmlk
KTsKICAgICAgICAgICAgICAgIGFoaygncGFzdGUnLCBTdHJpbmcoYy5pZCkpOwogICAgICAgICAgICB9
CiAgICAgICAgfSBlbHNlIGlmICgvXlsxLTldJC8udGVzdChlLmtleSkpIHsKICAgICAgICAgICAgY29u
c3QgYyA9IHZpc1srZS5rZXkgLSAxXTsKICAgICAgICAgICAgaWYgKGMpIHsKICAgICAgICAgICAgICAg
IG1hcmtQYXN0ZWRMb2NhbChjLmlkKTsKICAgICAgICAgICAgICAgIGFoaygncGFzdGUnLCBTdHJpbmco
Yy5pZCkpOwogICAgICAgICAgICB9CiAgICAgICAgfQogICAgfSk7CgogICAgd2luZG93Ll9fbmF2ID0g
ZGlyID0+IHsKICAgICAgICBjb25zdCB2aXMgPSAodHlwZW9mIG5hdkxpc3QgPT09ICdmdW5jdGlvbicg
PyBuYXZMaXN0KCkgOiB2aXNpYmxlTGlzdCgpKTsKICAgICAgICBpZiAoIXZpcy5sZW5ndGggJiYgZGly
ICE9PSAndGFiJyAmJiBkaXIgIT09ICd0YWJQcmV2JykgcmV0dXJuOwogICAgICAgIGxldCBpZHggPSBz
ZWxlY3RlZEluZGV4KCk7CiAgICAgICAgaWYgKGlkeCA8IDApIGlkeCA9IDA7CiAgICAgICAgaWYgKGRp
ciA9PT0gJ3VwJykgc2VsZWN0QnlJbmRleChpZHggLSAxKTsKICAgICAgICBlbHNlIGlmIChkaXIgPT09
ICdkb3duJykgc2VsZWN0QnlJbmRleChpZHggKyAxKTsKICAgICAgICBlbHNlIGlmIChkaXIgPT09ICdl
bnRlcicpIHsKICAgICAgICAgICAgaWYgKHBpbm5lZFVJKSByZXR1cm47CiAgICAgICAgICAgIF9fcHJl
cFBhc3RlKCk7CiAgICAgICAgICAgIGlmIChtdWx0aUlkcy5sZW5ndGggPiAxKSB7CiAgICAgICAgICAg
ICAgICBjb25zdCBpZHMgPSBtdWx0aUlkcy5zbGljZSgpOwogICAgICAgICAgICAgICAgY2xlYXJNdWx0
aSgpOwogICAgICAgICAgICAgICAgbWFya1Bhc3RlZExvY2FsKGlkcyk7CiAgICAgICAgICAgICAgICBh
aGsoJ3Bhc3RlTWFueScsIGlkcy5qb2luKCcsJykpOwogICAgICAgICAgICAgICAgcmV0dXJuOwogICAg
ICAgICAgICB9CiAgICAgICAgICAgIGlmIChtdWx0aUlkcy5sZW5ndGggPT09IDEpIHsKICAgICAgICAg
ICAgICAgIGNvbnN0IGlkID0gbXVsdGlJZHNbMF07CiAgICAgICAgICAgICAgICBjbGVhck11bHRpKCk7
CiAgICAgICAgICAgICAgICBtYXJrUGFzdGVkTG9jYWwoaWQpOwogICAgICAgICAgICAgICAgYWhrKCdw
YXN0ZScsIFN0cmluZyhpZCkpOwogICAgICAgICAgICAgICAgcmV0dXJuOwogICAgICAgICAgICB9CiAg
ICAgICAgICAgIGNvbnN0IGMgPSB2aXNbc2VsZWN0ZWRJbmRleCgpXTsKICAgICAgICAgICAgaWYgKGMp
IHsKICAgICAgICAgICAgICAgIG1hcmtQYXN0ZWRMb2NhbChjLmlkKTsKICAgICAgICAgICAgICAgIGFo
aygncGFzdGUnLCBTdHJpbmcoYy5pZCkpOwogICAgICAgICAgICB9CiAgICAgICAgfQogICAgfTsKCiAg
ICAvLyBBSEsgRW50ZXIgaG90a2V5IGxhbmRzIGhlcmUgKFdlYlZpZXcgbWF5IG5vdCByZWNlaXZlIHRo
ZSBrZXkgd2hpbGUgdW5waW5uZWQpCiAgICB3aW5kb3cuX19lZGl0VGl0bGUgPSAoKSA9PiB7CiAgICAg
ICAgbGV0IGMgPSBudWxsOwogICAgICAgIGlmIChzZWxlY3RlZElkKQogICAgICAgICAgICBjID0gYWxs
Q2xpcHMuZmluZCh4ID0+ICt4LmlkID09PSArc2VsZWN0ZWRJZCkgfHwgbnVsbDsKICAgICAgICBpZiAo
IWMgJiYgY3R4Q2xpcCkKICAgICAgICAgICAgYyA9IGN0eENsaXA7CiAgICAgICAgaWYgKCFjKSB7CiAg
ICAgICAgICAgIGNvbnN0IHZpcyA9IHZpc2libGVMaXN0KCk7CiAgICAgICAgICAgIGlmICh2aXMubGVu
Z3RoKSBjID0gdmlzWzBdOwogICAgICAgIH0KICAgICAgICBpZiAoIWMpIHJldHVybjsKICAgICAgICBv
cGVuVGl0bGVEbGcoYyk7CiAgICB9OwoKICAgIHdpbmRvdy5fX29uRW50ZXIgPSAoKSA9PiB7CiAgICAg
ICAgY29uc3QgdGQgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgndGl0bGUtZGxnJyk7CiAgICAgICAg
aWYgKHRkICYmIHRkLmNsYXNzTGlzdC5jb250YWlucygnb24nKSkgewogICAgICAgICAgICBkb2N1bWVu
dC5nZXRFbGVtZW50QnlJZCgndGl0bGUtb2snKT8uY2xpY2soKTsKICAgICAgICAgICAgcmV0dXJuOwog
ICAgICAgIH0KICAgICAgICBpZiAoZG9jdW1lbnQuYWN0aXZlRWxlbWVudD8uaWQgPT09ICd0aXRsZS1p
bnB1dCcpIHsKICAgICAgICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3RpdGxlLW9rJyk/LmNs
aWNrKCk7CiAgICAgICAgICAgIHJldHVybjsKICAgICAgICB9CiAgICAgICAgLy8g5Zu65a6a5pe25Zue
6L2m5LiN57KY6LS0CiAgICAgICAgaWYgKHBpbm5lZFVJKSByZXR1cm47CiAgICAgICAgLy8gVHlwaW5n
IGluIHNlYXJjaDogRW50ZXIgc2hvdWxkIHBhc3RlIHNlbGVjdGVkIGl0ZW0KICAgICAgICBpZiAoZG9j
dW1lbnQuYWN0aXZlRWxlbWVudD8uaWQgPT09ICdzZWFyY2gnKSB7CiAgICAgICAgICAgIHdpbmRvdy5f
X25hdiAmJiB3aW5kb3cuX19uYXYoJ2VudGVyJyk7CiAgICAgICAgICAgIHJldHVybjsKICAgICAgICB9
CiAgICAgICAgd2luZG93Ll9fbmF2ICYmIHdpbmRvdy5fX25hdignZW50ZXInKTsKICAgIH07CgogICAg
d2luZG93Ll9fY3ljbGVUYWIgPSBkaXIgPT4gewogICAgICAgIGNvbnN0IGkgPSBNYXRoLm1heCgwLCBU
QUJfT1JERVIuaW5kZXhPZihjdXJUYWIpKTsKICAgICAgICBjb25zdCBuZXh0ID0gVEFCX09SREVSWyhp
ICsgKGRpciB8IDApICsgVEFCX09SREVSLmxlbmd0aCAqIDEwKSAlIFRBQl9PUkRFUi5sZW5ndGhdOwog
ICAgICAgIHNldFRhYihuZXh0KTsKICAgIH07CiAgICB3aW5kb3cuX19vblBhbmVsU2hvdyA9IChrZWVw
U2VhcmNoKSA9PiB7CiAgICAgICAgLy8gRG8gTk9UIGZvY3VzIFdlYlZpZXcg4oCUIGtlZXAgZWRpdG9y
IGNhcmV0L2ZvY3VzIChBSEsgaGFuZGxlcyBrZXlzIHZpYSAjSG90SWYpCiAgICAgICAgLy8gV2luK1Y6
IGNvbGxhcHNlIHNlYXJjaC4gPz8gc2VhcmNoOiBrZWVwL29wZW4gc2VhcmNoIGJveC4KICAgICAgICBr
ZWVwU2VhcmNoID0gISFrZWVwU2VhcmNoOwogICAgICAgIHRyeSB7IGhpZGVDdHgoKTsgfSBjYXRjaCB7
fQogICAgICAgIHRyeSB7IGNsb3NlVGl0bGVEbGcoKTsgfSBjYXRjaCB7fQogICAgICAgIHRyeSB7CiAg
ICAgICAgICAgIGNvbnN0IHdyYXAgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc2VhcmNoLXdyYXAn
KTsKICAgICAgICAgICAgY29uc3Qgc3JjaCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzZWFyY2gn
KTsKICAgICAgICAgICAgY29uc3Qgc2NsciA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzZWFyY2gt
Y2xyJyk7CiAgICAgICAgICAgIGlmICgha2VlcFNlYXJjaCkgewogICAgICAgICAgICAgICAgaWYgKHdy
YXApIHdyYXAuY2xhc3NMaXN0LnJlbW92ZSgnb3BlbicpOwogICAgICAgICAgICAgICAgaWYgKHNyY2gp
IHsKICAgICAgICAgICAgICAgICAgICBzcmNoLnZhbHVlID0gJyc7CiAgICAgICAgICAgICAgICAgICAg
c3JjaC5jbGFzc0xpc3QucmVtb3ZlKCdoYXMtdmFsJyk7CiAgICAgICAgICAgICAgICAgICAgdHJ5IHsg
c3JjaC5ibHVyKCk7IH0gY2F0Y2gge30KICAgICAgICAgICAgICAgIH0KICAgICAgICAgICAgICAgIGlm
IChzY2xyKSBzY2xyLnN0eWxlLmRpc3BsYXkgPSAnbm9uZSc7CiAgICAgICAgICAgICAgICBxdWVyeSA9
ICcnOwogICAgICAgICAgICAgICAgd2luZG93Ll9faG9zdEZpbHRlcmVkID0gZmFsc2U7CiAgICAgICAg
ICAgICAgICB3aW5kb3cuX19ob3N0RmlsdGVyUSA9ICcnOwogICAgICAgICAgICAgICAgLy8gV2luK1bv
vJrnq4vliLvnlKjmnKrov4fmu6TnvJPlrZjpk7rliJfooajvvIzpgb/lhY3lhYjpl6rov4fmu6Tnu5Pm
npwv56m65aOz5YaN562JIFNldFZpZXcKICAgICAgICAgICAgICAgIHRyeSB7CiAgICAgICAgICAgICAg
ICAgICAgY29uc3QgaGl0ID0gdmlld01lbS5nZXQodmlld01lbUtleSgnYWxsJywgJycsIGZhbHNlKSk7
CiAgICAgICAgICAgICAgICAgICAgaWYgKGhpdCAmJiBBcnJheS5pc0FycmF5KGhpdC5pdGVtcykgJiYg
aGl0Lml0ZW1zLmxlbmd0aCkgewogICAgICAgICAgICAgICAgICAgICAgICBhbGxDbGlwcyA9IGhpdC5p
dGVtcy5zbGljZSgpOwogICAgICAgICAgICAgICAgICAgICAgICBkaXNrVG90YWwgPSBOdW1iZXIoaGl0
LnRvdGFsKSB8fCBoaXQuaXRlbXMubGVuZ3RoOwogICAgICAgICAgICAgICAgICAgICAgICB3aW5kb3cu
X19kYXRhUmVhZHkgPSB0cnVlOwogICAgICAgICAgICAgICAgICAgICAgICBob3N0UHVzaGVkT25jZSA9
IHRydWU7CiAgICAgICAgICAgICAgICAgICAgICAgIHNhd05vbkVtcHR5ID0gdHJ1ZTsKICAgICAgICAg
ICAgICAgICAgICAgICAgY2xlYXJXYWl0aW5nRGF0YSgpOwogICAgICAgICAgICAgICAgICAgIH0gZWxz
ZSB7CiAgICAgICAgICAgICAgICAgICAgICAgIHNjaGVkdWxlRGVsYXllZFNrZWwoKTsKICAgICAgICAg
ICAgICAgICAgICB9CiAgICAgICAgICAgICAgICB9IGNhdGNoIHsKICAgICAgICAgICAgICAgICAgICBz
Y2hlZHVsZURlbGF5ZWRTa2VsKCk7CiAgICAgICAgICAgICAgICB9CiAgICAgICAgICAgIH0gZWxzZSBp
ZiAod3JhcCkgewogICAgICAgICAgICAgICAgd3JhcC5jbGFzc0xpc3QuYWRkKCdvcGVuJyk7CiAgICAg
ICAgICAgICAgICBpZiAoc3JjaCAmJiBzcmNoLnZhbHVlKQogICAgICAgICAgICAgICAgICAgIHF1ZXJ5
ID0gc3JjaC52YWx1ZTsKICAgICAgICAgICAgICAgIC8vID8/IOaQnOe0ou+8muWcqOS4u+acuui/h+a7
pOe7k+aenOWIsOi+vuWJje+8jOWFiOaMieWFs+mUruWtl+acrOWcsOa7pO+8jOemgeatoumXquWHuuOA
jOWFqOmDqOOAjQogICAgICAgICAgICAgICAgaWYgKFN0cmluZyhxdWVyeSB8fCAnJykudHJpbSgpKSB7
CiAgICAgICAgICAgICAgICAgICAgd2luZG93Ll9faG9zdEZpbHRlcmVkID0gZmFsc2U7CiAgICAgICAg
ICAgICAgICAgICAgd2luZG93Ll9faG9zdEZpbHRlclEgPSAnJzsKICAgICAgICAgICAgICAgIH0KICAg
ICAgICAgICAgfQogICAgICAgICAgICB0b2RheU9ubHkgPSBmYWxzZTsKICAgICAgICAgICAgdHJ5IHsK
ICAgICAgICAgICAgICAgIGNvbnN0IGJ0blRvZGF5ID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2J0
bi10b2RheScpOwogICAgICAgICAgICAgICAgaWYgKGJ0blRvZGF5KSBidG5Ub2RheS5jbGFzc0xpc3Qu
cmVtb3ZlKCdvbicpOwogICAgICAgICAgICB9IGNhdGNoIHt9CiAgICAgICAgICAgIGN1clRhYiA9ICdh
bGwnOwogICAgICAgICAgICBsb2FkaW5nTW9yZSA9IGZhbHNlOwogICAgICAgICAgICBtYXJrVGFiKCdh
bGwnKTsKICAgICAgICAgICAgLy8g5LiN6KaBIGFoaygnYmx1clBhbmVsJynvvJrkvJrot58gU2hvd1Bh
bmVsIOaKoueEpueCue+8jFdpbitWLz8/IOmDveWuueaYk+mXquOAgeS5sei3swogICAgICAgICAgICBy
ZW5kZXIoKTsKICAgICAgICAgICAgLy8g5ZCM5q2l5b2T5YmNIHRhYi9xdWVyeSDliLAgQUhL77yIPz8g
5pu+5Y+q55SoIHZpZXdUYWIg5pCc6ZSZ6aG177yJCiAgICAgICAgICAgIHJlcXVlc3RWaWV3KCk7CiAg
ICAgICAgfSBjYXRjaCB7fQogICAgICAgIHNlbGVjdEZpcnN0T25TaG93ID0gdHJ1ZTsKICAgICAgICBs
b2NhdGVBY3RpdmUgPSBmYWxzZTsKICAgICAgICB1cGRhdGVMb2NhdGVCdG4oKTsKICAgICAgICBjbGVh
ck11bHRpKCk7CiAgICAgICAgY29uc3QgdmlzID0gdmlzaWJsZUxpc3QoKTsKICAgICAgICBpZiAodmlz
Lmxlbmd0aCkgewogICAgICAgICAgICBzZWxlY3RlZElkID0gdmlzWzBdLmlkOwogICAgICAgICAgICBy
YW5nZUFuY2hvcklkID0gc2VsZWN0ZWRJZDsKICAgICAgICAgICAgcmFuZ2VBbmNob3JDbGlja2VkID0g
ZmFsc2U7CiAgICAgICAgICAgIGxpc3RFbC5zY3JvbGxUb3AgPSAwOwogICAgICAgIH0KICAgICAgICBz
eW5jSXRlbUhpZ2hsaWdodCgpOwogICAgfTsKCiAgICBmdW5jdGlvbiBjdHhCaW5kKGlkLCBmbikgewog
ICAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKGlkKS5hZGRFdmVudExpc3RlbmVyKCdjbGljaycs
IGUgPT4gewogICAgICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgICAgICAgICBpZiAoY3R4
Q2xpcCkgZm4oY3R4Q2xpcCk7CiAgICAgICAgICAgIGhpZGVDdHgoKTsKICAgICAgICB9KTsKICAgIH0K
ICAgIGN0eEJpbmQoJ2MtY29weScsICBjID0+IGFoaygnY29weUJ5SWQnLCAgICAgU3RyaW5nKGMuaWQp
KSk7CiAgICBjdHhCaW5kKCdjLXBhc3RlJywgYyA9PiB7CiAgICAgICAgbWFya1Bhc3RlZExvY2FsKGMu
aWQpOwogICAgICAgIGFoaygncGFzdGUnLCBTdHJpbmcoYy5pZCkpOwogICAgfSk7CiAgICBjdHhCaW5k
KCdjLXBpbicsICAgYyA9PiBhaGsoJ3BpbicsICAgICAgICAgICBTdHJpbmcoYy5pZCkpKTsKICAgIGN0
eEJpbmQoJ2MtdG9wJywgICBjID0+IGFoaygnbW92ZVRvVG9wJywgICAgIFN0cmluZyhjLmlkKSkpOwog
ICAgY3R4QmluZCgnYy1jbGVhci1wYXN0ZWQnLCBjID0+IGFoaygnY2xlYXJQYXN0ZWQnLCBTdHJpbmco
Yy5pZCkpKTsKICAgIGN0eEJpbmQoJ2MtcXVldWUtZnJvbScsIGMgPT4gewogICAgICAgIGFoaygncmVz
ZXRRdWV1ZUZyb20nLCBTdHJpbmcoYy5pZCkpOwogICAgICAgIGlmICghcGlubmVkVUkpIGFoaygnaGlk
ZScpOwogICAgfSk7CiAgICBjdHhCaW5kKCdjLWRlbCcsICAgYyA9PiB7CiAgICAgICAgLy8g5aSa6YCJ
5LiU5Y+z6ZSu54K55Zyo6YCJ5Lit6aG55LiKIOKGkiDmibnph4/liKDpmaTvvJvlkKbliJnlj6rliKDl
vZPliY0KICAgICAgICBsZXQgaWRzID0gW107CiAgICAgICAgaWYgKG11bHRpSWRzLmxlbmd0aCA+IDEg
JiYgbXVsdGlJZHMuaW5jbHVkZXMoK2MuaWQpKQogICAgICAgICAgICBpZHMgPSBtdWx0aUlkcy5zbGlj
ZSgpOwogICAgICAgIGVsc2UKICAgICAgICAgICAgaWRzID0gWytjLmlkXTsKICAgICAgICBpZHMgPSBp
ZHMubWFwKHggPT4gK3gpLmZpbHRlcih4ID0+IHggPiAwKTsKICAgICAgICBpZiAoIWlkcy5sZW5ndGgp
IHJldHVybjsKICAgICAgICB0cnkgewogICAgICAgICAgICBjb25zdCBpZFNldCA9IG5ldyBTZXQoaWRz
KTsKICAgICAgICAgICAgYWxsQ2xpcHMgPSBhbGxDbGlwcy5maWx0ZXIoeCA9PiAhaWRTZXQuaGFzKCt4
LmlkKSk7CiAgICAgICAgICAgIGRpc2tUb3RhbCA9IE1hdGgubWF4KDAsIChOdW1iZXIoZGlza1RvdGFs
KSB8fCAwKSAtIGlkcy5sZW5ndGgpOwogICAgICAgICAgICBpZiAoaWRTZXQuaGFzKCtzZWxlY3RlZElk
KSkKICAgICAgICAgICAgICAgIHNlbGVjdGVkSWQgPSBhbGxDbGlwcy5sZW5ndGggPyBhbGxDbGlwc1sw
XS5pZCA6IDA7CiAgICAgICAgICAgIGNsZWFyTXVsdGkoKTsKICAgICAgICAgICAgcmVuZGVyKCk7CiAg
ICAgICAgfSBjYXRjaCB7fQogICAgICAgIGlmIChpZHMubGVuZ3RoID09PSAxKQogICAgICAgICAgICBh
aGsoJ2RlbGV0ZScsIFN0cmluZyhpZHNbMF0pKTsKICAgICAgICBlbHNlCiAgICAgICAgICAgIGFoaygn
ZGVsZXRlTWFueScsIGlkcy5qb2luKCcsJykpOwogICAgfSk7CiAgICBjdHhCaW5kKCdjLXRpdGxlJywg
YyA9PiBvcGVuVGl0bGVEbGcoYykpOwogICAgY3R4QmluZCgnYy1tZXJnZScsIGMgPT4gewogICAgICAg
IGNvbnN0IGlkcyA9IChtdWx0aUlkcy5sZW5ndGggPj0gMikgPyBtdWx0aUlkcy5zbGljZSgpIDogW107
CiAgICAgICAgaWYgKGlkcy5sZW5ndGggPCAyKSByZXR1cm47CiAgICAgICAgaWYgKCFpZHMuaW5jbHVk
ZXMoK2MuaWQpKSBpZHMucHVzaCgrYy5pZCk7CiAgICAgICAgYWhrKCdtZXJnZUZhdicsIGlkcy5qb2lu
KCcsJykpOwogICAgICAgIGNsZWFyTXVsdGkoKTsKICAgIH0pOwogICAgY3R4QmluZCgnYy11bm1lcmdl
JywgYyA9PiB7CiAgICAgICAgYWhrKCd1bm1lcmdlRmF2JywgU3RyaW5nKGMuaWQpKTsKICAgICAgICBj
bGVhck11bHRpKCk7CiAgICB9KTsKCiAgICBjb25zdCB0aXRsZURsZyA9IGRvY3VtZW50LmdldEVsZW1l
bnRCeUlkKCd0aXRsZS1kbGcnKTsKICAgIGNvbnN0IHRpdGxlSW5wdXQgPSBkb2N1bWVudC5nZXRFbGVt
ZW50QnlJZCgndGl0bGUtaW5wdXQnKTsKICAgIGxldCB0aXRsZURsZ0NsaXAgPSBudWxsOwogICAgZnVu
Y3Rpb24gY2xvc2VUaXRsZURsZygpIHsKICAgICAgICBpZiAodGl0bGVEbGcpIHRpdGxlRGxnLmNsYXNz
TGlzdC5yZW1vdmUoJ29uJyk7CiAgICAgICAgdGl0bGVEbGdDbGlwID0gbnVsbDsKICAgIH0KICAgIGZ1
bmN0aW9uIG9wZW5UaXRsZURsZyhjKSB7CiAgICAgICAgaGlkZUN0eCgpOwogICAgICAgIHRpdGxlRGxn
Q2xpcCA9IGM7CiAgICAgICAgaWYgKHRpdGxlSW5wdXQpIHRpdGxlSW5wdXQudmFsdWUgPSBTdHJpbmco
Yy5mYXZUaXRsZSB8fCAnJykudHJpbSgpOwogICAgICAgIGlmICh0aXRsZURsZykgdGl0bGVEbGcuY2xh
c3NMaXN0LmFkZCgnb24nKTsKICAgICAgICBhaGsoJ2ZvY3VzUGFuZWwnKTsKICAgICAgICByZXF1ZXN0
QW5pbWF0aW9uRnJhbWUoKCkgPT4gewogICAgICAgICAgICB0cnkgeyB0aXRsZUlucHV0LmZvY3VzKCk7
IHRpdGxlSW5wdXQuc2VsZWN0KCk7IH0gY2F0Y2gge30KICAgICAgICB9KTsKICAgIH0KICAgIGlmICh0
aXRsZURsZykgewogICAgICAgIHRpdGxlRGxnLmFkZEV2ZW50TGlzdGVuZXIoJ2NsaWNrJywgZSA9PiB7
CiAgICAgICAgICAgIGlmIChlLnRhcmdldCA9PT0gdGl0bGVEbGcpIGNsb3NlVGl0bGVEbGcoKTsKICAg
ICAgICB9KTsKICAgIH0KICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd0aXRsZS1jYW5jZWwnKT8u
YWRkRXZlbnRMaXN0ZW5lcignY2xpY2snLCBlID0+IHsKICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigp
OwogICAgICAgIGNsb3NlVGl0bGVEbGcoKTsKICAgICAgICBhaGsoJ2JsdXJQYW5lbCcpOwogICAgfSk7
CiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgndGl0bGUtb2snKT8uYWRkRXZlbnRMaXN0ZW5lcign
Y2xpY2snLCBlID0+IHsKICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgICAgIGlmICghdGl0
bGVEbGdDbGlwKSByZXR1cm47CiAgICAgICAgY29uc3QgdCA9IFN0cmluZyh0aXRsZUlucHV0Py52YWx1
ZSB8fCAnJykudHJpbSgpLnNsaWNlKDAsIDgwKTsKICAgICAgICBjb25zdCBpZCA9IFN0cmluZyh0aXRs
ZURsZ0NsaXAuaWQpOwogICAgICAgIC8vIE9wdGltaXN0aWMgbG9jYWwgdXBkYXRlCiAgICAgICAgY29u
c3QgaGl0ID0gYWxsQ2xpcHMuZmluZCh4ID0+ICt4LmlkID09PSAraWQpOwogICAgICAgIGlmIChoaXQp
IGhpdC5mYXZUaXRsZSA9IHQ7CiAgICAgICAgdGl0bGVEbGdDbGlwLmZhdlRpdGxlID0gdDsKICAgICAg
ICBjbG9zZVRpdGxlRGxnKCk7CiAgICAgICAgYWhrKCdzZXRGYXZUaXRsZScsIGlkLCB0KTsKICAgICAg
ICBhaGsoJ2JsdXJQYW5lbCcpOwogICAgICAgIHJlbmRlcigpOwogICAgfSk7CiAgICB0aXRsZUlucHV0
Py5hZGRFdmVudExpc3RlbmVyKCdrZXlkb3duJywgZSA9PiB7CiAgICAgICAgaWYgKGUua2V5ID09PSAn
RW50ZXInKSB7CiAgICAgICAgICAgIGUucHJldmVudERlZmF1bHQoKTsKICAgICAgICAgICAgZS5zdG9w
UHJvcGFnYXRpb24oKTsKICAgICAgICAgICAgZS5zdG9wSW1tZWRpYXRlUHJvcGFnYXRpb24oKTsKICAg
ICAgICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3RpdGxlLW9rJyk/LmNsaWNrKCk7CiAgICAg
ICAgICAgIHJldHVybjsKICAgICAgICB9CiAgICAgICAgaWYgKGUua2V5ID09PSAnRXNjYXBlJykgewog
ICAgICAgICAgICBlLnByZXZlbnREZWZhdWx0KCk7CiAgICAgICAgICAgIGUuc3RvcFByb3BhZ2F0aW9u
KCk7CiAgICAgICAgICAgIGNsb3NlVGl0bGVEbGcoKTsKICAgICAgICAgICAgYWhrKCdibHVyUGFuZWwn
KTsKICAgICAgICAgICAgcmV0dXJuOwogICAgICAgIH0KICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigp
OwogICAgfSwgdHJ1ZSk7CgogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3RhYnMnKS5hZGRFdmVu
dExpc3RlbmVyKCdjbGljaycsIGUgPT4gewogICAgICAgIGNvbnN0IHRhYiA9IGUudGFyZ2V0LmNsb3Nl
c3QoJy50YWInKTsKICAgICAgICBpZiAoIXRhYiB8fCBlLnRhcmdldC5jbG9zZXN0KCcjdGFiLWFjdGlv
bnMnKSkgcmV0dXJuOwogICAgICAgIHNldFRhYih0YWIuZGF0YXNldC50YWIpOwogICAgfSk7CgogICAg
Y29uc3Qgc3JjaFdyYXAgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc2VhcmNoLXdyYXAnKTsKICAg
IGNvbnN0IGJ0blNlYXJjaCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdidG4tc2VhcmNoJyk7CiAg
ICBjb25zdCBidG5Mb2NhdGUgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYnRuLWxvY2F0ZScpOwog
ICAgY29uc3QgYnRuVG9kYXkgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYnRuLXRvZGF5Jyk7CiAg
ICBjb25zdCBzcmNoID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NlYXJjaCcpOwogICAgY29uc3Qg
c2NsciA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzZWFyY2gtY2xyJyk7CiAgICBsZXQgZGViOwoK
ICAgIHVwZGF0ZUxvY2F0ZUJ0bigpOwogICAgaWYgKGJ0bkxvY2F0ZSkgewogICAgICAgIGJ0bkxvY2F0
ZS5hZGRFdmVudExpc3RlbmVyKCdjbGljaycsIGUgPT4gewogICAgICAgICAgICBlLnN0b3BQcm9wYWdh
dGlvbigpOwogICAgICAgICAgICBqdW1wVG9MYXN0UGFzdGUoKTsKICAgICAgICB9KTsKICAgIH0KCiAg
ICBidG5Ub2RheS5hZGRFdmVudExpc3RlbmVyKCdtb3VzZWRvd24nLCBlID0+IHsKICAgICAgICBlLnBy
ZXZlbnREZWZhdWx0KCk7CiAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgIH0pOwogICAgYnRu
VG9kYXkuYWRkRXZlbnRMaXN0ZW5lcignY2xpY2snLCBlID0+IHsKICAgICAgICBlLnN0b3BQcm9wYWdh
dGlvbigpOwogICAgICAgIGUucHJldmVudERlZmF1bHQoKTsKICAgICAgICB0b2RheU9ubHkgPSAhdG9k
YXlPbmx5OwogICAgICAgIGJ0blRvZGF5LmNsYXNzTGlzdC50b2dnbGUoJ29uJywgdG9kYXlPbmx5KTsK
ICAgICAgICBsaXN0RWwuc2Nyb2xsVG9wID0gMDsKICAgICAgICByZXF1ZXN0VmlldygpOwogICAgICAg
IHRyeSB7IHNyY2guZm9jdXMoKTsgfSBjYXRjaCB7fQogICAgfSk7CgogICAgZnVuY3Rpb24gb3BlblNl
YXJjaCgpIHsKICAgICAgICBpZiAoc3JjaFdyYXAuY2xhc3NMaXN0LmNvbnRhaW5zKCdvcGVuJykpIHsK
ICAgICAgICAgICAgYWhrKCdmb2N1c1BhbmVsJyk7CiAgICAgICAgICAgIHRyeSB7IHNyY2guZm9jdXMo
KTsgfSBjYXRjaCB7fQogICAgICAgICAgICByZXR1cm47CiAgICAgICAgfQogICAgICAgIHNyY2hXcmFw
LmNsYXNzTGlzdC5hZGQoJ29wZW4nKTsKICAgICAgICAvLyBEZWZhdWx0OiDmiYDmnInpobXmiZPlvIDm
kJzntKLml7bpu5jorqTmkJzlhajpg6gKICAgICAgICBjb25zdCB3YW50VG9kYXkgPSBmYWxzZTsKICAg
ICAgICBpZiAodG9kYXlPbmx5ICE9PSB3YW50VG9kYXkpIHsKICAgICAgICAgICAgdG9kYXlPbmx5ID0g
d2FudFRvZGF5OwogICAgICAgICAgICBidG5Ub2RheS5jbGFzc0xpc3QudG9nZ2xlKCdvbicsIHRvZGF5
T25seSk7CiAgICAgICAgICAgIGxpc3RFbC5zY3JvbGxUb3AgPSAwOwogICAgICAgICAgICByZXF1ZXN0
VmlldygpOwogICAgICAgIH0gZWxzZSB7CiAgICAgICAgICAgIGJ0blRvZGF5LmNsYXNzTGlzdC50b2dn
bGUoJ29uJywgdG9kYXlPbmx5KTsKICAgICAgICB9CiAgICAgICAgYWhrKCdmb2N1c1BhbmVsJyk7CiAg
ICAgICAgcmVxdWVzdEFuaW1hdGlvbkZyYW1lKCgpID0+IHsKICAgICAgICAgICAgdHJ5IHsgc3JjaC5m
b2N1cygpOyB9IGNhdGNoIHt9CiAgICAgICAgfSk7CiAgICB9CiAgICBmdW5jdGlvbiBjbG9zZVNlYXJj
aFVpKCkgewogICAgICAgIHNyY2hXcmFwLmNsYXNzTGlzdC5yZW1vdmUoJ29wZW4nKTsKICAgICAgICBp
ZiAoIXNyY2gudmFsdWUpIHsKICAgICAgICAgICAgc3JjaC5jbGFzc0xpc3QucmVtb3ZlKCdoYXMtdmFs
Jyk7CiAgICAgICAgICAgIHNjbHIuc3R5bGUuZGlzcGxheSA9ICdub25lJzsKICAgICAgICAgICAgLy8g
TGVhdmluZyBzZWFyY2ggd2l0aCBlbXB0eSBxdWVyeSDihpIgZHJvcCB0b2RheSBmaWx0ZXIKICAgICAg
ICAgICAgaWYgKHRvZGF5T25seSkgewogICAgICAgICAgICAgICAgdG9kYXlPbmx5ID0gZmFsc2U7CiAg
ICAgICAgICAgICAgICBidG5Ub2RheS5jbGFzc0xpc3QucmVtb3ZlKCdvbicpOwogICAgICAgICAgICAg
ICAgcmVxdWVzdFZpZXcoKTsKICAgICAgICAgICAgfQogICAgICAgIH0KICAgIH0KICAgIHdpbmRvdy5f
X29wZW5TZWFyY2ggPSBvcGVuU2VhcmNoOwogICAgd2luZG93Ll9fcHJlcFR5cGVTZWFyY2ggPSAoKSA9
PiB7CiAgICAgICAgdHJ5IHsKICAgICAgICAgICAgY29uc3Qgd3JhcCA9IGRvY3VtZW50LmdldEVsZW1l
bnRCeUlkKCdzZWFyY2gtd3JhcCcpOwogICAgICAgICAgICBjb25zdCBzID0gZG9jdW1lbnQuZ2V0RWxl
bWVudEJ5SWQoJ3NlYXJjaCcpOwogICAgICAgICAgICBpZiAod3JhcCAmJiAhd3JhcC5jbGFzc0xpc3Qu
Y29udGFpbnMoJ29wZW4nKSkgewogICAgICAgICAgICAgICAgd3JhcC5jbGFzc0xpc3QuYWRkKCdvcGVu
Jyk7CiAgICAgICAgICAgICAgICB0cnkgewogICAgICAgICAgICAgICAgICAgIGNvbnN0IHdhbnRUb2Rh
eSA9IGZhbHNlOwogICAgICAgICAgICAgICAgICAgIGlmICh0eXBlb2YgdG9kYXlPbmx5ICE9PSAndW5k
ZWZpbmVkJyAmJiB0b2RheU9ubHkgIT09IHdhbnRUb2RheSkgewogICAgICAgICAgICAgICAgICAgICAg
ICB0b2RheU9ubHkgPSB3YW50VG9kYXk7CiAgICAgICAgICAgICAgICAgICAgICAgIGlmICh0eXBlb2Yg
YnRuVG9kYXkgIT09ICd1bmRlZmluZWQnICYmIGJ0blRvZGF5KSBidG5Ub2RheS5jbGFzc0xpc3QudG9n
Z2xlKCdvbicsIHRvZGF5T25seSk7CiAgICAgICAgICAgICAgICAgICAgICAgIGlmICh0eXBlb2YgbGlz
dEVsICE9PSAndW5kZWZpbmVkJyAmJiBsaXN0RWwpIGxpc3RFbC5zY3JvbGxUb3AgPSAwOwogICAgICAg
ICAgICAgICAgICAgICAgICBpZiAodHlwZW9mIHJlcXVlc3RWaWV3ID09PSAnZnVuY3Rpb24nKSBzZXRU
aW1lb3V0KHJlcXVlc3RWaWV3LCAwKTsKICAgICAgICAgICAgICAgICAgICB9IGVsc2UgaWYgKHR5cGVv
ZiBidG5Ub2RheSAhPT0gJ3VuZGVmaW5lZCcgJiYgYnRuVG9kYXkpIHsKICAgICAgICAgICAgICAgICAg
ICAgICAgYnRuVG9kYXkuY2xhc3NMaXN0LnRvZ2dsZSgnb24nLCAhIXRvZGF5T25seSk7CiAgICAgICAg
ICAgICAgICAgICAgfQogICAgICAgICAgICAgICAgfSBjYXRjaCB7fQogICAgICAgICAgICB9CiAgICAg
ICAgICAgIC8vID8/IOmVnOWDj+aQnOe0ou+8muS4jeimgSBmb2N1c++8jOmBv+WFjeaKoui1sOWOn+e8
lui+keahhuWFieaghwogICAgICAgIH0gY2F0Y2gge30KICAgIH07CiAgICB3aW5kb3cuX190eXBlU2Vh
cmNoID0gKGNoKSA9PiB7CiAgICAgICAgdHJ5IHsKICAgICAgICAgICAgd2luZG93Ll9fcHJlcFR5cGVT
ZWFyY2ggJiYgd2luZG93Ll9fcHJlcFR5cGVTZWFyY2goKTsKICAgICAgICAgICAgY29uc3QgcyA9IGRv
Y3VtZW50LmdldEVsZW1lbnRCeUlkKCdzZWFyY2gnKTsKICAgICAgICAgICAgaWYgKCFzKSByZXR1cm47
CiAgICAgICAgICAgIHMudmFsdWUgPSBTdHJpbmcocy52YWx1ZSB8fCAnJykgKyBTdHJpbmcoY2ggPT0g
bnVsbCA/ICcnIDogY2gpOwogICAgICAgICAgICBzLmNsYXNzTGlzdC50b2dnbGUoJ2hhcy12YWwnLCAh
IXMudmFsdWUpOwogICAgICAgICAgICBzLmRpc3BhdGNoRXZlbnQobmV3IEV2ZW50KCdpbnB1dCcsIHsg
YnViYmxlczogdHJ1ZSB9KSk7CiAgICAgICAgfSBjYXRjaCB7fQogICAgfTsKICAgIHdpbmRvdy5fX2Jr
c3BTZWFyY2ggPSAoKSA9PiB7CiAgICAgICAgdHJ5IHsKICAgICAgICAgICAgd2luZG93Ll9fcHJlcFR5
cGVTZWFyY2ggJiYgd2luZG93Ll9fcHJlcFR5cGVTZWFyY2goKTsKICAgICAgICAgICAgY29uc3QgcyA9
IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzZWFyY2gnKTsKICAgICAgICAgICAgaWYgKCFzKSByZXR1
cm47CiAgICAgICAgICAgIGNvbnN0IHYgPSBTdHJpbmcocy52YWx1ZSB8fCAnJyk7CiAgICAgICAgICAg
IHMudmFsdWUgPSB2Lmxlbmd0aCA/IHYuc2xpY2UoMCwgLTEpIDogJyc7CiAgICAgICAgICAgIHMuY2xh
c3NMaXN0LnRvZ2dsZSgnaGFzLXZhbCcsICEhcy52YWx1ZSk7CiAgICAgICAgICAgIHMuZGlzcGF0Y2hF
dmVudChuZXcgRXZlbnQoJ2lucHV0JywgeyBidWJibGVzOiB0cnVlIH0pKTsKICAgICAgICB9IGNhdGNo
IHt9CiAgICB9OwogICAgd2luZG93Ll9fc2V0U2VhcmNoUXVlcnkgPSAocSkgPT4gewogICAgICAgIHRy
eSB7CiAgICAgICAgICAgIGNvbnN0IHMgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc2VhcmNoJyk7
CiAgICAgICAgICAgIGlmICghcykgcmV0dXJuOwogICAgICAgICAgICBjb25zdCBuZXh0ID0gU3RyaW5n
KHEgPT0gbnVsbCA/ICcnIDogcSk7CiAgICAgICAgICAgIGNvbnN0IHByZXYgPSBTdHJpbmcocy52YWx1
ZSB8fCAnJyk7CiAgICAgICAgICAgIC8vIOWQjOWFs+mUruWtl+mHjeWkjeaOqOmAge+8muWPquS/neiv
geaQnOe0ouahhuW8gOedgO+8jOemgeatouWGjSByZXF1ZXN0Vmlld++8iOS8muatu+W+queOr+mXqu+8
iQogICAgICAgICAgICBpZiAocHJldiA9PT0gbmV4dCAmJiBTdHJpbmcocXVlcnkgfHwgJycpID09PSBu
ZXh0KSB7CiAgICAgICAgICAgICAgICB0cnkgewogICAgICAgICAgICAgICAgICAgIGNvbnN0IHdyYXAg
PSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc2VhcmNoLXdyYXAnKTsKICAgICAgICAgICAgICAgICAg
ICBpZiAod3JhcCAmJiAhd3JhcC5jbGFzc0xpc3QuY29udGFpbnMoJ29wZW4nKSkKICAgICAgICAgICAg
ICAgICAgICAgICAgd3JhcC5jbGFzc0xpc3QuYWRkKCdvcGVuJyk7CiAgICAgICAgICAgICAgICB9IGNh
dGNoIHt9CiAgICAgICAgICAgICAgICByZXR1cm47CiAgICAgICAgICAgIH0KICAgICAgICAgICAgLy8g
5omT5a2X5Y2z5pe25LiK5bGP77yM5LiO56OB55uY5pCc57Si6Kej6ICmCiAgICAgICAgICAgIHMudmFs
dWUgPSBuZXh0OwogICAgICAgICAgICBzLmNsYXNzTGlzdC50b2dnbGUoJ2hhcy12YWwnLCAhIXMudmFs
dWUpOwogICAgICAgICAgICBjb25zdCBzY2xyID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NlYXJj
aC1jbHInKTsKICAgICAgICAgICAgaWYgKHNjbHIpIHNjbHIuc3R5bGUuZGlzcGxheSA9IHMudmFsdWUg
PyAnYmxvY2snIDogJ25vbmUnOwogICAgICAgICAgICBxdWVyeSA9IHMudmFsdWU7CiAgICAgICAgICAg
IHRyeSB7CiAgICAgICAgICAgICAgICBjb25zdCB3cmFwID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQo
J3NlYXJjaC13cmFwJyk7CiAgICAgICAgICAgICAgICBpZiAod3JhcCAmJiAhd3JhcC5jbGFzc0xpc3Qu
Y29udGFpbnMoJ29wZW4nKSkKICAgICAgICAgICAgICAgICAgICB3aW5kb3cuX19wcmVwVHlwZVNlYXJj
aCAmJiB3aW5kb3cuX19wcmVwVHlwZVNlYXJjaCgpOwogICAgICAgICAgICAgICAgZWxzZSBpZiAod3Jh
cCkKICAgICAgICAgICAgICAgICAgICB3cmFwLmNsYXNzTGlzdC5hZGQoJ29wZW4nKTsKICAgICAgICAg
ICAgfSBjYXRjaCB7fQogICAgICAgICAgICB3aW5kb3cuX19ob3N0RmlsdGVyZWQgPSBmYWxzZTsKICAg
ICAgICAgICAgd2luZG93Ll9faG9zdEZpbHRlclEgPSAnJzsKICAgICAgICAgICAgaWYgKFN0cmluZyhx
dWVyeSB8fCAnJykudHJpbSgpKSB7CiAgICAgICAgICAgICAgICB3YWl0aW5nRGF0YSA9IHRydWU7CiAg
ICAgICAgICAgICAgICB3aW5kb3cuX19kYXRhUmVhZHkgPSBmYWxzZTsKICAgICAgICAgICAgfQogICAg
ICAgICAgICB0cnkgewogICAgICAgICAgICAgICAgY29uc3QgY250ID0gZG9jdW1lbnQuZ2V0RWxlbWVu
dEJ5SWQoJ2Jhci10eHQnKTsKICAgICAgICAgICAgICAgIGlmIChjbnQgJiYgU3RyaW5nKHF1ZXJ5IHx8
ICcnKS50cmltKCkpCiAgICAgICAgICAgICAgICAgICAgY250LnRleHRDb250ZW50ID0gdmlzaWJsZUxp
c3QoKS5sZW5ndGggKyAnIOadoSc7CiAgICAgICAgICAgIH0gY2F0Y2gge30KICAgICAgICAgICAgdHJ5
IHsgcmVuZGVyKCk7IH0gY2F0Y2gge30KICAgICAgICAgICAgY2xlYXJUaW1lb3V0KHdpbmRvdy5fX3Fx
Vmlld0RlYik7CiAgICAgICAgICAgIHdpbmRvdy5fX3FxVmlld0RlYiA9IHNldFRpbWVvdXQoKCkgPT4g
ewogICAgICAgICAgICAgICAgd2luZG93Ll9fcXFWaWV3RGViID0gMDsKICAgICAgICAgICAgICAgIHJl
cXVlc3RWaWV3KCk7CiAgICAgICAgICAgIH0sIDcwKTsKICAgICAgICB9IGNhdGNoIHt9CiAgICB9Owog
ICAgLy8gQ2FwdHVyZSBDdHJsK0YgaW5zaWRlIFdlYlZpZXcgKENocm9taXVtIGZpbmQgaXMgZGlzYWJs
ZWQsIGJ1dCBzdGlsbCBoYW5kbGUgaGVyZSkKICAgIGRvY3VtZW50LmFkZEV2ZW50TGlzdGVuZXIoJ2tl
eWRvd24nLCBlID0+IHsKICAgICAgICBpZiAoKGUuY3RybEtleSB8fCBlLm1ldGFLZXkpICYmICFlLmFs
dEtleSAmJiAoZS5rZXkgPT09ICdmJyB8fCBlLmtleSA9PT0gJ0YnKSkgewogICAgICAgICAgICBlLnBy
ZXZlbnREZWZhdWx0KCk7CiAgICAgICAgICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAgICAgICAg
IG9wZW5TZWFyY2goKTsKICAgICAgICB9CiAgICB9LCB0cnVlKTsKICAgIGJ0blNlYXJjaC5hZGRFdmVu
dExpc3RlbmVyKCdjbGljaycsIGUgPT4gewogICAgICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAg
ICAgb3BlblNlYXJjaCgpOwogICAgfSk7CiAgICBsZXQgX19zcmNoQ29tcG9zaW5nID0gZmFsc2U7CiAg
ICBjb25zdCBfX2ZsdXNoU2VhcmNoSW5wdXQgPSAoKSA9PiB7CiAgICAgICAgcXVlcnkgPSBzcmNoLnZh
bHVlOwogICAgICAgIHNyY2guY2xhc3NMaXN0LnRvZ2dsZSgnaGFzLXZhbCcsICEhcXVlcnkpOwogICAg
ICAgIHNjbHIuc3R5bGUuZGlzcGxheSA9IHF1ZXJ5ID8gJ2Jsb2NrJyA6ICdub25lJzsKICAgICAgICBs
aXN0RWwuc2Nyb2xsVG9wID0gMDsKICAgICAgICB3aW5kb3cuX19ob3N0RmlsdGVyZWQgPSBmYWxzZTsK
ICAgICAgICB3aW5kb3cuX19ob3N0RmlsdGVyUSA9ICcnOwogICAgICAgIHRyeSB7IHJlbmRlcigpOyB9
IGNhdGNoIHt9CiAgICAgICAgY2xlYXJUaW1lb3V0KGRlYik7CiAgICAgICAgZGViID0gc2V0VGltZW91
dChyZXF1ZXN0VmlldywgODApOwogICAgfTsKICAgIHNyY2guYWRkRXZlbnRMaXN0ZW5lcignY29tcG9z
aXRpb25zdGFydCcsICgpID0+IHsgX19zcmNoQ29tcG9zaW5nID0gdHJ1ZTsgfSk7CiAgICBzcmNoLmFk
ZEV2ZW50TGlzdGVuZXIoJ2NvbXBvc2l0aW9uZW5kJywgKCkgPT4gewogICAgICAgIF9fc3JjaENvbXBv
c2luZyA9IGZhbHNlOwogICAgICAgIF9fZmx1c2hTZWFyY2hJbnB1dCgpOwogICAgfSk7CiAgICBzcmNo
LmFkZEV2ZW50TGlzdGVuZXIoJ2lucHV0JywgKCkgPT4gewogICAgICAgIGlmIChfX3NyY2hDb21wb3Np
bmcpIHsKICAgICAgICAgICAgcXVlcnkgPSBzcmNoLnZhbHVlOwogICAgICAgICAgICBzcmNoLmNsYXNz
TGlzdC50b2dnbGUoJ2hhcy12YWwnLCAhIXF1ZXJ5KTsKICAgICAgICAgICAgc2Nsci5zdHlsZS5kaXNw
bGF5ID0gcXVlcnkgPyAnYmxvY2snIDogJ25vbmUnOwogICAgICAgICAgICByZXR1cm47CiAgICAgICAg
fQogICAgICAgIF9fZmx1c2hTZWFyY2hJbnB1dCgpOwogICAgfSk7CiAgICBzcmNoLmFkZEV2ZW50TGlz
dGVuZXIoJ2ZvY3VzJywgKCkgPT4gewogICAgICAgIC8vIElkZW1wb3RlbnQgb24gQUhLIHNpZGUg4oCU
IHNhZmUsIGJ1dCBhdm9pZCBzcGFtbWluZyBkdXJpbmcgSU1FCiAgICAgICAgdHJ5IHsgYWhrKCdmb2N1
c1BhbmVsJyk7IH0gY2F0Y2gge30KICAgIH0pOwogICAgc3JjaC5hZGRFdmVudExpc3RlbmVyKCdibHVy
JywgKCkgPT4gewogICAgICAgIHNldFRpbWVvdXQoKCkgPT4gewogICAgICAgICAgICBpZiAoZG9jdW1l
bnQuYWN0aXZlRWxlbWVudCA9PT0gc3JjaCkgcmV0dXJuOwogICAgICAgICAgICBpZiAoZG9jdW1lbnQu
YWN0aXZlRWxlbWVudCA9PT0gc2NsciB8fCAoc2NsciAmJiBzY2xyLmNvbnRhaW5zKGRvY3VtZW50LmFj
dGl2ZUVsZW1lbnQpKSkgcmV0dXJuOwogICAgICAgICAgICBpZiAoZG9jdW1lbnQuYWN0aXZlRWxlbWVu
dCA9PT0gYnRuVG9kYXkgfHwgKGJ0blRvZGF5ICYmIGJ0blRvZGF5LmNvbnRhaW5zKGRvY3VtZW50LmFj
dGl2ZUVsZW1lbnQpKSkgcmV0dXJuOwogICAgICAgICAgICAvLyBJTUUgY2FuZGlkYXRlIFVJIHN0ZWFs
cyBmb2N1cyBicmllZmx5IOKAlCBrZWVwIHNlYXJjaCBpZiBzdGlsbCBjb21wb3NpbmcKICAgICAgICAg
ICAgaWYgKF9fc3JjaENvbXBvc2luZykgcmV0dXJuOwogICAgICAgICAgICBjbG9zZVNlYXJjaFVpKCk7
CiAgICAgICAgICAgIGFoaygnYmx1clBhbmVsJyk7CiAgICAgICAgfSwgMjgwKTsKICAgIH0pOwogICAg
c3JjaC5hZGRFdmVudExpc3RlbmVyKCdrZXlkb3duJywgZSA9PiB7CiAgICAgICAgLy8gQ3RybCtJIC8g
Q3RybCtLOiBtb3ZlIGNsaXAgc2VsZWN0aW9uIChub3QgaW5zZXJ0IGNoYXIgLyBicm93c2VyIHNob3J0
Y3V0KQogICAgICAgIGlmICgoZS5jdHJsS2V5IHx8IGUubWV0YUtleSkgJiYgKGUua2V5ID09PSAnaScg
fHwgZS5rZXkgPT09ICdJJykpIHsKICAgICAgICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOwogICAgICAg
ICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgICAgICAgICB3aW5kb3cuX19uYXYgJiYgd2luZG93
Ll9fbmF2KCd1cCcpOwogICAgICAgICAgICByZXR1cm47CiAgICAgICAgfQogICAgICAgIGlmICgoZS5j
dHJsS2V5IHx8IGUubWV0YUtleSkgJiYgKGUua2V5ID09PSAnaycgfHwgZS5rZXkgPT09ICdLJykpIHsK
ICAgICAgICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOwogICAgICAgICAgICBlLnN0b3BQcm9wYWdhdGlv
bigpOwogICAgICAgICAgICB3aW5kb3cuX19uYXYgJiYgd2luZG93Ll9fbmF2KCdkb3duJyk7CiAgICAg
ICAgICAgIHJldHVybjsKICAgICAgICB9CiAgICAgICAgaWYgKGUua2V5ID09PSAnQXJyb3dEb3duJykg
ewogICAgICAgICAgICBlLnByZXZlbnREZWZhdWx0KCk7CiAgICAgICAgICAgIGUuc3RvcFByb3BhZ2F0
aW9uKCk7CiAgICAgICAgICAgIHdpbmRvdy5fX25hdiAmJiB3aW5kb3cuX19uYXYoJ2Rvd24nKTsKICAg
ICAgICAgICAgcmV0dXJuOwogICAgICAgIH0KICAgICAgICBpZiAoZS5rZXkgPT09ICdBcnJvd1VwJykg
ewogICAgICAgICAgICBlLnByZXZlbnREZWZhdWx0KCk7CiAgICAgICAgICAgIGUuc3RvcFByb3BhZ2F0
aW9uKCk7CiAgICAgICAgICAgIHdpbmRvdy5fX25hdiAmJiB3aW5kb3cuX19uYXYoJ3VwJyk7CiAgICAg
ICAgICAgIHJldHVybjsKICAgICAgICB9CiAgICAgICAgaWYgKGUua2V5ID09PSAnRXNjYXBlJykgewog
ICAgICAgICAgICBlLnByZXZlbnREZWZhdWx0KCk7CiAgICAgICAgICAgIGUuc3RvcFByb3BhZ2F0aW9u
KCk7CiAgICAgICAgICAgIC8vIEFsd2F5cyBkaXNtaXNzIHRoZSB3aG9sZSBwYW5lbCAobm90IGp1c3Qg
dGhlIHNlYXJjaCBmaWVsZCkKICAgICAgICAgICAgaWYgKCFwaW5uZWRVSSkgYWhrKCdoaWRlJyk7CiAg
ICAgICAgICAgIHJldHVybjsKICAgICAgICB9CiAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAg
IH0pOwogICAgc2Nsci5hZGRFdmVudExpc3RlbmVyKCdjbGljaycsIGUgPT4gewogICAgICAgIGUuc3Rv
cFByb3BhZ2F0aW9uKCk7CiAgICAgICAgc3JjaC52YWx1ZSA9IHF1ZXJ5ID0gJyc7CiAgICAgICAgc2Ns
ci5zdHlsZS5kaXNwbGF5ID0gJ25vbmUnOwogICAgICAgIHNyY2guY2xhc3NMaXN0LnJlbW92ZSgnaGFz
LXZhbCcpOwogICAgICAgIHJlcXVlc3RWaWV3KCk7CiAgICAgICAgYWhrKCdmb2N1c1BhbmVsJyk7CiAg
ICAgICAgc3JjaC5mb2N1cygpOwogICAgfSk7CgogICAgY29uc3QgVEFCX05BTUVTID0geyBhbGw6ICfl
hajpg6gnLCB0ZXh0OiAn5paH5pysJywgaW1hZ2U6ICflm77lg48nLCBmaWxlOiAn5paH5Lu2JywgcGlu
bmVkOiAn5pS26JePJyB9OwogICAgY29uc3QgY2xyRGxnID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQo
J2Nsci1kbGcnKTsKICAgIGNvbnN0IGNsckFsbENiID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2Ns
ci1hbGwnKTsKICAgIGZ1bmN0aW9uIG9wZW5DbGVhckRsZygpIHsKICAgICAgICBjb25zdCBuYW1lID0g
VEFCX05BTUVTW2N1clRhYl0gfHwgJ+W9k+WJjSc7CiAgICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5
SWQoJ2Nsci10aXRsZScpLnRleHRDb250ZW50ID0gJ+a4heepuuOAjCcgKyBuYW1lICsgJ+OAje+8nyc7
CiAgICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2Nsci1kZXNjJykudGV4dENvbnRlbnQgPSBj
dXJUYWIgPT09ICdwaW5uZWQnCiAgICAgICAgICAgID8gJ+m7mOiupOS7hea4heepuuW9k+WkqeeahOaU
tuiXj+mhueOAguWLvumAieOAjOa4heepuuaJgOacieOAjeWPr+a4hemZpOivpemAiemhueWNoeWFqOmD
qOWGheWuueOAgicKICAgICAgICAgICAgOiAn5LuF5riF56m65b2T5YmN6YCJ6aG55Y2h44CC6buY6K6k
5Y+q5riF5b2T5aSp77yb5pS26JeP6aG55LiN5Lya6KKr5riF6Zmk44CC5Yu+6YCJ44CM5riF56m65omA
5pyJ44CN5Y+v5riF6Zmk6K+l6YCJ6aG55Y2h5YWo6YOo5pel5pyf44CCJzsKICAgICAgICBjbHJBbGxD
Yi5jaGVja2VkID0gZmFsc2U7CiAgICAgICAgY2xyRGxnLmNsYXNzTGlzdC5hZGQoJ29uJyk7CiAgICB9
CiAgICBmdW5jdGlvbiBjbG9zZUNsZWFyRGxnKCkgewogICAgICAgIGNsckRsZy5jbGFzc0xpc3QucmVt
b3ZlKCdvbicpOwogICAgfQogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2J0bi1jbHInKS5hZGRF
dmVudExpc3RlbmVyKCdjbGljaycsIGUgPT4gewogICAgICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAg
ICAgICAgb3BlbkNsZWFyRGxnKCk7CiAgICB9KTsKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdj
bHItY2FuY2VsJykuYWRkRXZlbnRMaXN0ZW5lcignY2xpY2snLCBlID0+IHsKICAgICAgICBlLnN0b3BQ
cm9wYWdhdGlvbigpOwogICAgICAgIGNsb3NlQ2xlYXJEbGcoKTsKICAgIH0pOwogICAgY2xyRGxnLmFk
ZEV2ZW50TGlzdGVuZXIoJ2NsaWNrJywgZSA9PiB7CiAgICAgICAgaWYgKGUudGFyZ2V0ID09PSBjbHJE
bGcpIGNsb3NlQ2xlYXJEbGcoKTsKICAgIH0pOwogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2Ns
ci1vaycpLmFkZEV2ZW50TGlzdGVuZXIoJ2NsaWNrJywgZSA9PiB7CiAgICAgICAgZS5zdG9wUHJvcGFn
YXRpb24oKTsKICAgICAgICBjb25zdCBzY29wZSA9IGNsckFsbENiLmNoZWNrZWQgPyAnYWxsJyA6ICd0
b2RheSc7CiAgICAgICAgY2xvc2VDbGVhckRsZygpOwogICAgICAgIGFoaygnY2xlYXInLCBjdXJUYWIs
IHNjb3BlKTsKICAgIH0pOwogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ211bHRpLWNudCcpLmFk
ZEV2ZW50TGlzdGVuZXIoJ2NsaWNrJywgZSA9PiB7CiAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsK
ICAgICAgICBjbGVhck11bHRpKHRydWUpOwogICAgfSk7CiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJ
ZCgnYnRuLXBpbicpLmFkZEV2ZW50TGlzdGVuZXIoJ2NsaWNrJywgZSA9PiB7CiAgICAgICAgZS5zdG9w
UHJvcGFnYXRpb24oKTsKICAgICAgICBwaW5uZWRVSSA9ICFwaW5uZWRVSTsKICAgICAgICBlLmN1cnJl
bnRUYXJnZXQuY2xhc3NMaXN0LnRvZ2dsZSgnb24nLCBwaW5uZWRVSSk7CiAgICAgICAgYWhrKCd0b2dn
bGVQaW4nLCBwaW5uZWRVSSA/ICcxJyA6ICcwJyk7CiAgICB9KTsKCiAgICB3aW5kb3cuX191cGRhdGVD
bGlwcyA9IHBheWxvYWQgPT4gewogICAgICAgIC8vIEtlZXAgcHJldmlvdXMgc2Nyb2xsIGZvciBsb2Fk
LW1vcmU7IHJlc2V0IHdoZW4gb3BlbmluZyBwYW5lbCB0byBmaXJzdCBpdGVtCiAgICAgICAgY29uc3Qg
a2VlcFNjcm9sbCA9ICFzZWxlY3RGaXJzdE9uU2hvdzsKICAgICAgICBjb25zdCBzdCA9IGxpc3RFbC5z
Y3JvbGxUb3A7CiAgICAgICAgd2luZG93Ll9fd2FpdGluZ1ZpZXcgPSBmYWxzZTsKICAgICAgICBjb25z
dCB3YXNBcHBlbmQgPSBwYXlsb2FkICYmIHBheWxvYWQuYXBwZW5kOwogICAgICAgIGxvYWRpbmdNb3Jl
ID0gZmFsc2U7CiAgICAgICAgY29uc3QgcHJldkl0ZW1zID0gYWxsQ2xpcHM7CiAgICAgICAgbGV0IG5l
eHRJdGVtcyA9IFtdOwogICAgICAgIGxldCBuZXh0VG90YWwgPSAwOwogICAgICAgIGxldCBuZXh0Rmls
dGVyZWQgPSBmYWxzZTsKICAgICAgICBsZXQgcFRhYiA9ICcnOwogICAgICAgIGxldCBwUGlubmVkVG90
YWwgPSAtMTsKICAgICAgICBpZiAoQXJyYXkuaXNBcnJheShwYXlsb2FkKSkgewogICAgICAgICAgICBu
ZXh0SXRlbXMgPSBwYXlsb2FkOwogICAgICAgICAgICBuZXh0VG90YWwgPSBwYXlsb2FkLmxlbmd0aDsK
ICAgICAgICAgICAgbmV4dEZpbHRlcmVkID0gZmFsc2U7CiAgICAgICAgfSBlbHNlIGlmIChwYXlsb2Fk
ICYmIHR5cGVvZiBwYXlsb2FkID09PSAnb2JqZWN0JykgewogICAgICAgICAgICBuZXh0VG90YWwgPSBO
dW1iZXIocGF5bG9hZC50b3RhbCkgfHwgMDsKICAgICAgICAgICAgbmV4dEl0ZW1zID0gQXJyYXkuaXNB
cnJheShwYXlsb2FkLml0ZW1zKSA/IHBheWxvYWQuaXRlbXMgOiBbXTsKICAgICAgICAgICAgcFRhYiA9
IHBheWxvYWQudGFiICE9IG51bGwgPyBTdHJpbmcocGF5bG9hZC50YWIpIDogJyc7CiAgICAgICAgICAg
IGlmIChwYXlsb2FkLnBpbm5lZFRvdGFsICE9IG51bGwgJiYgcGF5bG9hZC5waW5uZWRUb3RhbCAhPT0g
JycpCiAgICAgICAgICAgICAgICBwUGlubmVkVG90YWwgPSBOdW1iZXIocGF5bG9hZC5waW5uZWRUb3Rh
bCkgfHwgMDsKICAgICAgICAgICAgY29uc3QgcHEwID0gcGF5bG9hZC5xdWVyeSAhPSBudWxsID8gU3Ry
aW5nKHBheWxvYWQucXVlcnkpIDogJyc7CiAgICAgICAgICAgIG5leHRGaWx0ZXJlZCA9ICEhKHBheWxv
YWQuZmlsdGVyZWQgfHwgKHBxMCAmJiBwcTAudHJpbSgpKSk7CiAgICAgICAgICAgIGlmIChwYXlsb2Fk
LmFwcGVuZCkgewogICAgICAgICAgICAgICAgLy8gQXBwZW5kIG9ubHkgYXBwbGllcyB0byB0aGUgdGFi
IHdlJ3JlIGN1cnJlbnRseSB2aWV3aW5nCiAgICAgICAgICAgICAgICBpZiAocFRhYiAmJiBwVGFiICE9
PSBjdXJUYWIpCiAgICAgICAgICAgICAgICAgICAgcmV0dXJuOwogICAgICAgICAgICAgICAgY29uc3Qg
c2VlbiA9IG5ldyBTZXQoYWxsQ2xpcHMubWFwKGMgPT4gK2MuaWQpKTsKICAgICAgICAgICAgICAgIGNv
bnN0IG1lcmdlZCA9IGFsbENsaXBzLnNsaWNlKCk7CiAgICAgICAgICAgICAgICBuZXh0SXRlbXMuZm9y
RWFjaChpdCA9PiB7CiAgICAgICAgICAgICAgICAgICAgaWYgKCFzZWVuLmhhcygraXQuaWQpKSBtZXJn
ZWQucHVzaChpdCk7CiAgICAgICAgICAgICAgICB9KTsKICAgICAgICAgICAgICAgIG5leHRJdGVtcyA9
IG1lcmdlZDsKICAgICAgICAgICAgICAgIG5leHRUb3RhbCA9IE1hdGgubWF4KG5leHRUb3RhbCwgbmV4
dEl0ZW1zLmxlbmd0aCk7CiAgICAgICAgICAgIH0KICAgICAgICAgICAgLy8g5pCc57Si5qGG5Lul5omT
5a2X6ZWc5YOP5Li65YeG77yM57ud5LiN6KKr5rue5ZCO55qE56OB55uY57uT5p6c5YaZ5Zue5pen5YWz
6ZSu5a2XCiAgICAgICAgICAgIHRyeSB7CiAgICAgICAgICAgICAgICBjb25zdCBzID0gZG9jdW1lbnQu
Z2V0RWxlbWVudEJ5SWQoJ3NlYXJjaCcpOwogICAgICAgICAgICAgICAgaWYgKHMgJiYgU3RyaW5nKHMu
dmFsdWUgfHwgJycpLmxlbmd0aCkKICAgICAgICAgICAgICAgICAgICBxdWVyeSA9IHMudmFsdWU7CiAg
ICAgICAgICAgICAgICBlbHNlIGlmIChwcTAgIT09ICcnICYmICFTdHJpbmcocXVlcnkgfHwgJycpLnRy
aW0oKSkKICAgICAgICAgICAgICAgICAgICBxdWVyeSA9IHBxMDsKICAgICAgICAgICAgfSBjYXRjaCB7
fQogICAgICAgIH0gZWxzZSB7CiAgICAgICAgICAgIG5leHRJdGVtcyA9IFtdOwogICAgICAgICAgICBu
ZXh0VG90YWwgPSAwOwogICAgICAgICAgICBuZXh0RmlsdGVyZWQgPSBmYWxzZTsKICAgICAgICB9Cgog
ICAgICAgIGNvbnN0IGJveFEgPSBTdHJpbmcocXVlcnkgfHwgJycpLnRyaW0oKTsKICAgICAgICBjb25z
dCBwdXNoUSA9IChwYXlsb2FkICYmIHR5cGVvZiBwYXlsb2FkID09PSAnb2JqZWN0JyAmJiBwYXlsb2Fk
LnF1ZXJ5ICE9IG51bGwpCiAgICAgICAgICAgID8gU3RyaW5nKHBheWxvYWQucXVlcnkpLnRyaW0oKSA6
ICcnOwoKICAgICAgICAvLyBBbHdheXMgcmVmcmVzaCDmlLbol48gYmFkZ2UgZnJvbSBob3N0IHdoZW4g
cHJvdmlkZWQKICAgICAgICBpZiAocFBpbm5lZFRvdGFsID49IDApCiAgICAgICAgICAgIHBpbm5lZFRv
dGFsID0gcFBpbm5lZFRvdGFsOwoKICAgICAgICAvLyBTdGFsZSBzZWFyY2ggcHVzaCAoZS5nLiAic3F1
YXJlIGxvZ2kiIGxhbmRzIGFmdGVyIHVzZXIgdHlwZWQgInNxdWFyZSBsb2dpbiIpIOKAlGNhY2hlIG9u
bHkKICAgICAgICBpZiAoIXdhc0FwcGVuZCAmJiBuZXh0RmlsdGVyZWQgJiYgcHVzaFEgJiYgYm94USAm
JiBwdXNoUSAhPT0gYm94USkgewogICAgICAgICAgICB2aWV3TWVtLnNldCh2aWV3TWVtS2V5KHBUYWIg
fHwgY3VyVGFiLCBwdXNoUSwgdG9kYXlPbmx5KSwgewogICAgICAgICAgICAgICAgaXRlbXM6IG5leHRJ
dGVtcy5zbGljZSgpLAogICAgICAgICAgICAgICAgdG90YWw6IG5leHRUb3RhbAogICAgICAgICAgICB9
KTsKICAgICAgICAgICAgcmV0dXJuOwogICAgICAgIH0KCiAgICAgICAgLy8gU3RhbGUgcHVzaCBmb3Ig
YW5vdGhlciB0YWI6IG9ubHkgcmVmcmVzaCB0aGF0IHRhYidzIHZpZXdNZW0sIGRvbid0IGhpamFjayBV
SQogICAgICAgIGlmICghd2FzQXBwZW5kICYmIHBUYWIgJiYgcFRhYiAhPT0gY3VyVGFiKSB7CiAgICAg
ICAgICAgIGNvbnN0IG1lbVEgPSAocGF5bG9hZCAmJiB0eXBlb2YgcGF5bG9hZCA9PT0gJ29iamVjdCcg
JiYgcGF5bG9hZC5xdWVyeSAhPSBudWxsKQogICAgICAgICAgICAgICAgPyBTdHJpbmcocGF5bG9hZC5x
dWVyeSkgOiAnJzsKICAgICAgICAgICAgdmlld01lbS5zZXQodmlld01lbUtleShwVGFiLCBtZW1RLCB0
b2RheU9ubHkpLCB7CiAgICAgICAgICAgICAgICBpdGVtczogbmV4dEl0ZW1zLnNsaWNlKCksCiAgICAg
ICAgICAgICAgICB0b3RhbDogbmV4dFRvdGFsCiAgICAgICAgICAgIH0pOwogICAgICAgICAgICAvLyBT
dGlsbCB1cGRhdGUgcGluIGJhZGdlIGlmIGhvc3Qgc2VudCBpdAogICAgICAgICAgICB0cnkgewogICAg
ICAgICAgICAgICAgY29uc3QgcGluQ250ID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3Bpbi1jbnQn
KTsKICAgICAgICAgICAgICAgIGlmIChwaW5DbnQgJiYgcGlubmVkVG90YWwgPiAwKSB7CiAgICAgICAg
ICAgICAgICAgICAgcGluQ250LnRleHRDb250ZW50ID0gcGlubmVkVG90YWw7CiAgICAgICAgICAgICAg
ICAgICAgcGluQ250LnN0eWxlLmRpc3BsYXkgPSAnJzsKICAgICAgICAgICAgICAgIH0KICAgICAgICAg
ICAgfSBjYXRjaCB7fQogICAgICAgICAgICAvLyBRUSDmkJzntKLmm77lm7rlrprmjqggYWxsIHRhYiDi
hpIg5b2T5YmNIHRhYiDkvJrkuIDnm7TpqqjmnrbvvJvooaXkuIDmrKEgcmVxdWVzdFZpZXcKICAgICAg
ICAgICAgaWYgKHdhaXRpbmdEYXRhICYmIHB1c2hRID09PSBib3hRKSB7CiAgICAgICAgICAgICAgICBz
ZXRUaW1lb3V0KCgpID0+IHsKICAgICAgICAgICAgICAgICAgICBpZiAod2FpdGluZ0RhdGEgJiYgY3Vy
VGFiICE9PSBwVGFiKQogICAgICAgICAgICAgICAgICAgICAgICByZXF1ZXN0VmlldygpOwogICAgICAg
ICAgICAgICAgfSwgNDApOwogICAgICAgICAgICB9CiAgICAgICAgICAgIHJldHVybjsKICAgICAgICB9
CgogICAgICAgIC8vIEJvb3RzdHJhcCByYWNlOiBBSEsgcHVzaGVkIGVtcHR5IGJlZm9yZSBXYXJtQWxs
Vmlld3Mg4oCUa2VlcCBza2VsZXRvbiwgaWdub3JlCiAgICAgICAgY29uc3QgcU9uID0gU3RyaW5nKHF1
ZXJ5IHx8ICcnKS50cmltKCkubGVuZ3RoID4gMDsKICAgICAgICBpZiAoIXdhc0FwcGVuZCAmJiAhbmV4
dEl0ZW1zLmxlbmd0aCAmJiBuZXh0VG90YWwgPD0gMCAmJiAhcU9uICYmICFuZXh0RmlsdGVyZWQgJiYg
IXNhd05vbkVtcHR5KSB7CiAgICAgICAgICAgIGlmICghd2luZG93Ll9fZW1wdHlGYWxsYmFja1QpIHsK
ICAgICAgICAgICAgICAgIHdpbmRvdy5fX2VtcHR5RmFsbGJhY2tUID0gc2V0VGltZW91dCgoKSA9PiB7
CiAgICAgICAgICAgICAgICAgICAgd2luZG93Ll9fZW1wdHlGYWxsYmFja1QgPSAwOwogICAgICAgICAg
ICAgICAgICAgIGlmIChzYXdOb25FbXB0eSkgcmV0dXJuOwogICAgICAgICAgICAgICAgICAgIC8vIFRy
dWx5IGVtcHR5IGluc3RhbGwgYWZ0ZXIgd2FpdAogICAgICAgICAgICAgICAgICAgIHNhd05vbkVtcHR5
ID0gdHJ1ZTsKICAgICAgICAgICAgICAgICAgICBob3N0UHVzaGVkT25jZSA9IHRydWU7CiAgICAgICAg
ICAgICAgICAgICAgd2luZG93Ll9fZGF0YVJlYWR5ID0gdHJ1ZTsKICAgICAgICAgICAgICAgICAgICBh
bGxDbGlwcyA9IFtdOwogICAgICAgICAgICAgICAgICAgIGRpc2tUb3RhbCA9IDA7CiAgICAgICAgICAg
ICAgICAgICAgY2xlYXJXYWl0aW5nRGF0YSgpOwogICAgICAgICAgICAgICAgICAgIHRyeSB7IHJlbmRl
cigpOyB9IGNhdGNoIHt9CiAgICAgICAgICAgICAgICB9LCA0NTAwKTsKICAgICAgICAgICAgfQogICAg
ICAgICAgICB3YWl0aW5nRGF0YSA9IHRydWU7CiAgICAgICAgICAgIHdpbmRvdy5fX2RhdGFSZWFkeSA9
IGZhbHNlOwogICAgICAgICAgICBob3N0UHVzaGVkT25jZSA9IGZhbHNlOwogICAgICAgICAgICBzZXRC
b290TG9hZGluZyh0cnVlKTsKICAgICAgICAgICAgdHJ5IHsgcmVuZGVyKCk7IH0gY2F0Y2gge30KICAg
ICAgICAgICAgcmV0dXJuOwogICAgICAgIH0KCiAgICAgICAgY2xlYXJXYWl0aW5nRGF0YSgpOwogICAg
ICAgIGFsbENsaXBzID0gbmV4dEl0ZW1zOwogICAgICAgIGRpc2tUb3RhbCA9IG5leHRUb3RhbDsKICAg
ICAgICAvLyBLZWVwIGJhciBjb25zaXN0ZW50IGlmIGxpc3QgZ3JldyBwYXN0IGEgc3RhbGUgdG90YWwK
ICAgICAgICBpZiAoYWxsQ2xpcHMubGVuZ3RoID4gZGlza1RvdGFsKQogICAgICAgICAgICBkaXNrVG90
YWwgPSBhbGxDbGlwcy5sZW5ndGg7CiAgICAgICAgd2luZG93Ll9faG9zdEZpbHRlcmVkID0gbmV4dEZp
bHRlcmVkOwogICAgICAgIHdpbmRvdy5fX2hvc3RGaWx0ZXJRID0gKG5leHRGaWx0ZXJlZCAmJiBwdXNo
USkgPyBwdXNoUSA6ICcnOwogICAgICAgIC8vIEZpbHRlcmVkIHNlYXJjaCB3aXRoIDAgaGl0cyDigJRt
dXN0IGxlYXZlIHNrZWxldG9uIChob3N0IGRpZCByZXNwb25kKQogICAgICAgIGlmICghd2FzQXBwZW5k
ICYmIG5leHRGaWx0ZXJlZCAmJiAhYWxsQ2xpcHMubGVuZ3RoICYmIGRpc2tUb3RhbCA8PSAwKSB7CiAg
ICAgICAgICAgIGhvc3RQdXNoZWRPbmNlID0gdHJ1ZTsKICAgICAgICAgICAgc2F3Tm9uRW1wdHkgPSB0
cnVlOwogICAgICAgIH0KICAgICAgICBpZiAoYWxsQ2xpcHMubGVuZ3RoIHx8IGRpc2tUb3RhbCA+IDAp
CiAgICAgICAgICAgIHNhd05vbkVtcHR5ID0gdHJ1ZTsKICAgICAgICBpZiAod2luZG93Ll9fZW1wdHlG
YWxsYmFja1QpIHsKICAgICAgICAgICAgY2xlYXJUaW1lb3V0KHdpbmRvdy5fX2VtcHR5RmFsbGJhY2tU
KTsKICAgICAgICAgICAgd2luZG93Ll9fZW1wdHlGYWxsYmFja1QgPSAwOwogICAgICAgIH0KICAgICAg
ICBpZiAoIXdhc0FwcGVuZCkgewogICAgICAgICAgICBjb25zdCBtZW1RID0gKHBheWxvYWQgJiYgdHlw
ZW9mIHBheWxvYWQgPT09ICdvYmplY3QnICYmIHBheWxvYWQucXVlcnkgIT0gbnVsbCkKICAgICAgICAg
ICAgICAgID8gU3RyaW5nKHBheWxvYWQucXVlcnkpIDogcXVlcnk7CiAgICAgICAgICAgIHZpZXdNZW0u
c2V0KHZpZXdNZW1LZXkoY3VyVGFiLCBtZW1RLCB0b2RheU9ubHkpLCB7CiAgICAgICAgICAgICAgICBp
dGVtczogYWxsQ2xpcHMuc2xpY2UoKSwKICAgICAgICAgICAgICAgIHRvdGFsOiBkaXNrVG90YWwKICAg
ICAgICAgICAgfSk7CiAgICAgICAgfQogICAgICAgIHdpbmRvdy5fX2RhdGFSZWFkeSA9IHRydWU7CiAg
ICAgICAgaG9zdFB1c2hlZE9uY2UgPSB0cnVlOwoKICAgICAgICAvLyBNaWQtd2hlZWw6IGtlZXAgZGF0
YSwgZGVsYXkgRE9NIHNvIHNjcm9sbC9kcmFnIG5ldmVyIGhpdGNoIG9uIGFwcGVuZCBwYWludAogICAg
ICAgIGlmICh3YXNBcHBlbmQgJiYgd2luZG93Ll9fc2Nyb2xsQnVzeSAmJiAhd2luZG93Ll9fcGVuZGlu
Z0p1bXBJZCkgewogICAgICAgICAgICBjb25zdCBmcm9tTGVuID0gKHByZXZJdGVtcyAmJiBwcmV2SXRl
bXMubGVuZ3RoKSA/IHByZXZJdGVtcy5sZW5ndGggOiAwOwogICAgICAgICAgICBpZiAoIV9wZW5kaW5n
QXBwZW5kKQogICAgICAgICAgICAgICAgX3BlbmRpbmdBcHBlbmQgPSB7IGZyb21MZW46IGZyb21MZW4g
fTsKICAgICAgICAgICAgdHJ5IHsgcmVmcmVzaExpc3RDaHJvbWUoKTsgfSBjYXRjaCB7fQogICAgICAg
ICAgICByZXR1cm47CiAgICAgICAgfQoKICAgICAgICBjb25zdCB3YXNCb290TG9hZGluZyA9IGJvb3RM
b2FkaW5nOwogICAgICAgIGxldCBzYW1lUGFpbnQgPSBmYWxzZTsKICAgICAgICBjb25zdCBwcmV2TGVu
ID0gKHByZXZJdGVtcyAmJiBwcmV2SXRlbXMubGVuZ3RoKSA/IHByZXZJdGVtcy5sZW5ndGggOiAwOwog
ICAgICAgIGlmICghd2FzQXBwZW5kICYmICF3YXNCb290TG9hZGluZyAmJiBwcmV2SXRlbXMgJiYgcHJl
dkl0ZW1zLmxlbmd0aCA9PT0gYWxsQ2xpcHMubGVuZ3RoICYmIHByZXZJdGVtcy5sZW5ndGgpIHsKICAg
ICAgICAgICAgc2FtZVBhaW50ID0gdHJ1ZTsKICAgICAgICAgICAgZm9yIChsZXQgaSA9IDA7IGkgPCBh
bGxDbGlwcy5sZW5ndGg7IGkrKykgewogICAgICAgICAgICAgICAgaWYgKCtwcmV2SXRlbXNbaV0uaWQg
IT09ICthbGxDbGlwc1tpXS5pZCkgeyBzYW1lUGFpbnQgPSBmYWxzZTsgYnJlYWs7IH0KICAgICAgICAg
ICAgfQogICAgICAgICAgICBpZiAoc2FtZVBhaW50ICYmICFsaXN0RWwucXVlcnlTZWxlY3RvcignLml0
bScpKSBzYW1lUGFpbnQgPSBmYWxzZTsKICAgICAgICB9CiAgICAgICAgY29uc3QgZmluaXNoVXBkYXRl
ID0gKCkgPT4gewogICAgICAgICAgICBjbGVhcldhaXRpbmdEYXRhKCk7CiAgICAgICAgICAgIGlmICh3
YXNBcHBlbmQgJiYgIXdhc0Jvb3RMb2FkaW5nICYmIHByZXZMZW4gPiAwICYmIGFsbENsaXBzLmxlbmd0
aCA+IHByZXZMZW4pIHsKICAgICAgICAgICAgICAgIGFwcGVuZFJlbmRlcihwcmV2TGVuKTsKICAgICAg
ICAgICAgfSBlbHNlIGlmICghc2FtZVBhaW50KSB7CiAgICAgICAgICAgICAgICByZW5kZXIoKTsKICAg
ICAgICAgICAgICAgIGFwcGx5VGFiU3dpdGNoQW5pbSgpOwogICAgICAgICAgICAgICAgaWYgKGtlZXBT
Y3JvbGwpCiAgICAgICAgICAgICAgICAgICAgbGlzdEVsLnNjcm9sbFRvcCA9IHN0OwogICAgICAgICAg
ICAgICAgZWxzZQogICAgICAgICAgICAgICAgICAgIGxpc3RFbC5zY3JvbGxUb3AgPSAwOwogICAgICAg
ICAgICB9IGVsc2UgewogICAgICAgICAgICAgICAgdHJ5IHsgcmVmcmVzaExpc3RDaHJvbWUoKTsgfSBj
YXRjaCB7fQogICAgICAgICAgICAgICAgaWYgKGtlZXBTY3JvbGwpCiAgICAgICAgICAgICAgICAgICAg
bGlzdEVsLnNjcm9sbFRvcCA9IHN0OwogICAgICAgICAgICB9CiAgICAgICAgfTsKICAgICAgICBpZiAo
d2FzQm9vdExvYWRpbmcpIHsKICAgICAgICAgICAgY29uc3Qgc2luY2UgPSB3aW5kb3cuX19za2VsU2lu
Y2UgfHwgMDsKICAgICAgICAgICAgY29uc3Qgd2FpdCA9IHNpbmNlID8gTWF0aC5tYXgoMCwgODAgLSAo
RGF0ZS5ub3coKSAtIHNpbmNlKSkgOiAwOwogICAgICAgICAgICBpZiAod2FpdCA+IDApCiAgICAgICAg
ICAgICAgICBzZXRUaW1lb3V0KGZpbmlzaFVwZGF0ZSwgd2FpdCk7CiAgICAgICAgICAgIGVsc2UKICAg
ICAgICAgICAgICAgIGZpbmlzaFVwZGF0ZSgpOwogICAgICAgIH0gZWxzZSB7CiAgICAgICAgICAgIGZp
bmlzaFVwZGF0ZSgpOwogICAgICAgIH0KICAgIH07CiAgICB3aW5kb3cuX19zZXRQaW5uZWQgPSB2ID0+
IHsKICAgICAgICBwaW5uZWRVSSA9ICEhdjsKICAgICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgn
YnRuLXBpbicpLmNsYXNzTGlzdC50b2dnbGUoJ29uJywgcGlubmVkVUkpOwogICAgfTsKICAgIHdpbmRv
dy5fX2xvYWRNb3JlRG9uZSA9ICgpID0+IHsKICAgICAgICBsb2FkaW5nTW9yZSA9IGZhbHNlOwogICAg
ICAgIGlmICh3aW5kb3cuX19sb2FkTW9yZVdhdGNoKSB7CiAgICAgICAgICAgIGNsZWFyVGltZW91dCh3
aW5kb3cuX19sb2FkTW9yZVdhdGNoKTsKICAgICAgICAgICAgd2luZG93Ll9fbG9hZE1vcmVXYXRjaCA9
IDA7CiAgICAgICAgfQogICAgICAgIGlmICh3aW5kb3cuX19wZW5kaW5nSnVtcElkKQogICAgICAgICAg
ICB0cnlDb250aW51ZUp1bXAoKTsKICAgIH07CgogICAgc2NoZWR1bGVEZWxheWVkU2tlbCgpOwogICAg
cmVxdWVzdFZpZXcoKTsKICAgIC8vIHNjaGVkdWxlRGVsYXllZFNrZWwgYWxyZWFkeSByZW5kZXIoKSdk
IHdoZW4gZW1wdHk7IHN0aWxsIHBhaW50IG9uY2UgZm9yIGNocm9tZQoKICAgIDwvc2NyaXB0Pgo8L2Jv
ZHk+CjwvaHRtbD4=
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
global diskScanBusy := false      ; true while PreloadAllViews / heavy disk scan
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
        ; NEVER FileCopy/GDI+ here —thumbs are lazy via ensureFileImg
        ClipLog("AddClipItem file skip eager thumb (lazy ensureFileImg)")
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
    pasteMany(ids) {
        RequestPasteMany(ids)
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
        OpenContainingFolder(path)
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
        QueueSetView(String(tab), String(query), String(today))
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
    global guiWin, wv, wvCore, lastCaretX, lastCaretY, hasCaretPos, panelVisible, uiPinned, prevActiveWin, linkMetaPausedUntil, viewToday, viewTab, qqSearchOn, qqQuery
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

    if !IsObject(guiWin)
        BuildGui()
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
    ClipLog("BuildGui ENTER")
    if IsObject(guiWin) || wvBuilding {
        ClipLog("BuildGui skip already building/built")
        return
    }    wvBuilding := true

    guiWin := Gui("-Caption -Border +ToolWindow +AlwaysOnTop")
    guiWin.BackColor := "f0f1f5"
    guiWin.MarginX := 0
    guiWin.MarginY := 0
    guiWin.OnEvent("Close", (*) => HidePanel())
    guiWin.OnEvent("Size", OnGuiSize)
    ; WS_EX_NOACTIVATE: showing the panel must not steal keyboard focus
    try guiWin.Opt("+E0x08000000")

    CalcUiSize(&uiW, &uiH)
    guiWin.Show("NA x-32000 y-32000 w" uiW " h" uiH)
    EnableDwmShadow(guiWin.Hwnd)

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
    try {
        wv := controller
        wv.Fill()
        wv.IsVisible := true
        try wv.DefaultBackgroundColor := 0xFFF0F1F5

        wvCore := wv.CoreWebView2
        wvCore.Settings.AreDefaultContextMenusEnabled := false
        wvCore.Settings.IsStatusBarEnabled := false
        ; Stop Chromium Ctrl+F find from eating our search shortcut
        try wvCore.Settings.AreBrowserAcceleratorKeysEnabled := false
        try wvCore.Settings.IsNonClientRegionSupportEnabled := true

        ; Virtual hosts: UI at https://clipui.local/ ; thumbs at /clips_store/...
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

        try wvCore.InjectAhkComponent()
        wvCore.AddHostObjectToScript("ahk", ClipBridge())

        if !FileExist(HTML_FILE)
            throw Error("找不到界面文件`n" HTML_FILE)

            wvCore.add_NavigationCompleted((core, args) => (
                ; Warm first VIEW_PAGE_SIZE for every tab, then show 鍏ㄩ儴
                SetTimer(WarmAllViewsAfterNav, -50),
                SetTimer(() => PushPinStateToUi(), -100)
            ))
        ; Must Navigate (not NavigateToString) so /clips_store/ thumbs resolve; bust WV2 cache
        wvCore.Navigate("https://" APP_HOST "/index.html?v=" A_Now)
        wvBuilding := false
        ; If user already opened the panel while we were creating, push data once ready
        if panelVisible
            SetTimer(() => (
                IsObject(wv) && (wv.Fill(), wv.IsVisible := true, wv.NotifyParentWindowPositionChanged()),
                RequestUiPush()
            ), -80)
    } catch as e {
        wvBuilding := false
        TrayTip("WebView2 init failed", e.Message, "Iconx")
        try FileAppend(FormatTime() " WebView2: " e.Message "`n", CLIP_V1_DIR "\error.log", "UTF-8")
    }
}

WarmAllViewsAfterNav(*) {
    global diskScanBusy, qqSearchOn, viewTab, viewQuery, clips
    ClipLog("WarmAllViews START")
    diskScanBusy := true
    try {
        ; 不要 Invalidate：清缓存会让随后切 tab 全走磁盘，又卡又容易误关面板
        PreloadAllViews("0")
        ClipLog("WarmAllViews Preload done")
        ; Preload may already have painted 全部 —avoid a second full PushClips
        already := (viewTab = "all" && viewQuery = "" && IsObject(clips) && clips.Length > 0)
        if !qqSearchOn && !already
            SetView("all", "", "0")
    } catch as e {
        ClipLogErr("WarmAllViews", e)
    } finally {
        diskScanBusy := false
        ClipLog("WarmAllViews END")
    }
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
    hRgn := DllCall("CreateRoundRectRgn",
        "Int", 0, "Int", 0, "Int", w + 1, "Int", h + 1,
        "Int", r * 2, "Int", r * 2, "Ptr")
    DllCall("SetWindowRgn", "Ptr", hwnd, "Ptr", hRgn, "Int", true)
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
    q := String(viewQuery)
    ; 扫盘中途可能 Sleep 让出：此时 viewQuery 已新、clips 仍旧 → 绝不推「伪过滤」列表
    if viewApplying && Trim(q) != ""
        return
    sendList := clips
    sendTotal := Integer(viewTotal)
    ; Boot/warm race: empty push makes UI flash「暂无记录」before disk lands
    if !append && (!IsObject(sendList) || sendList.Length = 0) && sendTotal <= 0 && Trim(q) = "" {
        if diskScanBusy || !clipReady {
            ClipLog("PushClips SKIP empty while warm/boot")
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
    payload := "{"
    payload .= '"append":' (append ? "true" : "false") ","
    payload .= '"tab":' JsonStr(String(viewTab)) ","
    payload .= '"total":' sendTotal ","
    payload .= '"pinnedTotal":' Integer(PinnedTotalForUi()) ","
    payload .= '"query":' JsonStr(q) ","
    payload .= '"filtered":' (filtered ? "true" : "false") ","
    payload .= '"items":' ClipsListToJson(sendList, append)
    payload .= "}"
    try wvCore.ExecuteScriptAsync("window.__updateClips && window.__updateClips(" payload ");window.__loadMoreDone&&window.__loadMoreDone()")
    ; Virtual-host thumbs flaky; inject data-URLs in small chunks (never block AHK thread)
    ScheduleStoreThumbs(append)
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
        if !IsObject(c) || !c.HasProp("imgFile") || c.imgFile = ""
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

PasteMany(idsStr) {
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
    if items.Length = 1 {
        PasteItem(uids[1])
        return
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

RequestPasteMany(ids) {
    global pasteLockUntil
    if A_TickCount < pasteLockUntil
        return
    pasteLockUntil := A_TickCount + 500
    pasteIds := ids
    SetTimer(() => PasteMany(pasteIds), -10)
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
    global clips, viewTab, viewQuery, viewToday, wvCore, viewCache
    uid := Integer(uid)
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
        if panelVisible && IsObject(wvCore)
            SetTimer(() => PushClips(false), -40)
        break
    }
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
        case "pinned":
            if !(c.HasProp("pinned") && c.pinned)
                return false
        default:
            if type = "link"
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
    m := LoadManifest()
    for name in m["pages"] {
        for c in ReadPageFile(name, true) {
            if ItemMatchesView(c, tab, query, todayOnly)
                total += 1
        }
    }
    return total
}

QueryDiskPage(tab, query, todayOnly, offset, limit) {
    global tabTotals
    tab := StrLower(Trim(String(tab)))
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
    m := LoadManifest()
    for name in m["pages"] {
        for c in ReadPageFile(name, true) {
            if !ItemMatchesView(c, tab, query, todayOnly)
                continue
            if total >= offset && items.Length < limit
                items.Push(c)
            total += 1
            ; Page filled and we already know the tab total →stop scanning
            if items.Length >= limit && knownTotal >= 0 && knownTotal >= (offset + limit) {
                tabTotals[key] := knownTotal
                return { items: items, total: knownTotal }
            }
            if Mod(++n, 48) = 0
                Sleep(-1)
        }
    }
    tabTotals[key] := total
    return { items: items, total: total }
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
    global clips, liveFront, PAYLOAD_DIR
    uid := Integer(uid)
    if uid < 1
        return ""
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
    }
    if keepQg > 0 {
        item.queueGroup := keepQg
        item.queueIndex := keepQi
        ; Force uid stable — never accept Inherit from a partial path above
        if uidBefore > 0
            item.uid := uidBefore
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

; Preload first VIEW_PAGE_SIZE for every tab in ONE disk pass (fast parse)
PreloadAllViews(today := "") {
    global viewCache, viewToday, VIEW_PAGE_SIZE, qqSearchOn, tabTotals, searchPools
        , clips, viewTab, viewQuery, viewTotal, viewApplying, wvCore
    ; 不要 Critical：切 tab / 预热时会卡住整线程，松手后外侧点击容易把面板藏掉
    try {
        if today = ""
            todayFlag := viewToday
        else
            todayFlag := (String(today) = "1" || String(today) = "true")
        tabs := ["all", "text", "image", "file", "link", "pinned"]
        buckets := Map()
        spBuckets := Map()
        for tab in tabs {
            key := ViewCacheKey(tab, "", todayFlag)
            if !viewCache.Has(key)
                buckets[tab] := { key: key, items: [], total: 0 }
        }
        ; 搜索池只建 全部 + 收藏
        for tab in ["all", "pinned"] {
            spKey := SearchPoolKey(tab, todayFlag)
            if !searchPools.Has(spKey)
                spBuckets[tab] := { key: spKey, items: [], groups: Map() }
        }
        if buckets.Count < 1 && spBuckets.Count < 1
            return

        m := LoadManifest()
        allShown := false
        n := 0
        for name in m["pages"] {
            path := PagePath(name)
            if !FileExist(path)
                continue
            try {
                loop read path, "UTF-8" {
                    c := ParseNdjsonLineFast(A_LoopReadLine)
                    if !IsObject(c)
                        continue
                    for tab, b in buckets {
                        if !ItemMatchesView(c, tab, "", todayFlag)
                            continue
                        if tab = "pinned" || b.items.Length < VIEW_PAGE_SIZE
                            b.items.Push(c)
                        b.total += 1
                    }
                    for tab, sb in spBuckets {
                        if !ItemMatchesTabToday(c, tab, todayFlag)
                            continue
                        h := ClipSearchHay(c)
                        c._searchHay := h
                        sb.items.Push(c)
                        g := (c.HasProp("favGroup") ? Trim(String(c.favGroup)) : "")
                        if g != "" {
                            if !sb.groups.Has(g)
                                sb.groups[g] := []
                            sb.groups[g].Push(c)
                        }
                    }
                    ; ?? 搜索进行中：禁止用空查询 SetView 盖掉搜索结果
                    ; 首屏只推 UI，不把 total≈PAGE 写入 viewCache（否则会毒化「全部」）
                    if !qqSearchOn && !allShown && buckets.Has("all") && buckets["all"].items.Length >= VIEW_PAGE_SIZE {
                        b := buckets["all"]
                        clips := b.items.Clone()
                        viewTab := "all"
                        viewQuery := ""
                        viewToday := todayFlag
                        viewTotal := Max(b.total, VIEW_PAGE_SIZE)
                        viewApplying := false
                        if IsObject(wvCore)
                            PushClips(false)
                        allShown := true
                    }
                    if Mod(++n, 24) = 0
                        Sleep(-1)
                }
            } catch {
            }
        }
        for tab, b in buckets {
            if tab = "pinned" {
                SortPinnedClipsDesc(b.items)
                if b.items.Length > VIEW_PAGE_SIZE {
                    trimmed := []
                    loop VIEW_PAGE_SIZE
                        trimmed.Push(b.items[A_Index])
                    b.items := trimmed
                }
            }
            viewCache[b.key] := { items: b.items, total: b.total }
            if IsObject(tabTotals)
                tabTotals[b.key] := Integer(b.total)
        }
        for tab, sb in spBuckets {
            searchPools[sb.key] := { items: sb.items, groups: sb.groups }
            ClipLog("PreloadSearchPool tab=" tab " n=" sb.items.Length)
        }
        ; Mid-preload already painted 全部 —skip second SetView/PushClips
        if !qqSearchOn && !allShown && buckets.Has("all")
            SetView("all", "", todayFlag ? "1" : "0")
    }
}

; Kept for callers that still name the old helper
PreloadNonLinkViews(today := "") {
    PreloadAllViews(today)
}

QueueSetView(tab, query, today) {
    global pendingViewTab, pendingViewQuery, pendingViewToday, pendingViewArmed
        , qqSearchOn, qqQuery
    ; ?? 搜索中前端偶发带空 query 的 setView：改写为当前关键字，避免冲掉命中
    if qqSearchOn {
        want := Trim(String(qqQuery))
        if want != "" && Trim(String(query)) = ""
            query := qqQuery
    }
    pendingViewTab := tab
    pendingViewQuery := query
    pendingViewToday := today
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
    global clips, viewTab, viewQuery, viewToday, viewTotal, VIEW_PAGE_SIZE, lastAppendCount, wvCore, viewCache
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
    if newTab = ""
        newTab := "all"
    newQuery := String(query)
    newToday := (String(today) = "1" || String(today) = "true")
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
        page := QueryDiskPage(viewTab, viewQuery, viewToday, 0, VIEW_PAGE_SIZE)
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
; One-shot: trim historical screenshots over the cap (file images untouched)
EnqueueDiskJob(PruneOldScreenshots)

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

; WebView2 is created lazily on first Win+V  — avoid spawning Edge at script start

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
    global HTML_FILE, HTML_B64
    ; Always refresh UI from embedded HTML_B64 (single-file source of truth)
    B64DecodeToFile(HTML_B64, HTML_FILE)
}

; =================================================
;  Ctrl+V: save clipboard image(s) into the active folder (not ahk\clip_v1)
; =================================================
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
