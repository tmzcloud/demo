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
UI_CACHE_VER := "20260908-pin-back"
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
eDsgZmxleC13cmFwOiBub3dyYXA7CiAgICAgICAgICAgIHBhZGRpbmc6IDVweCA2cHggNXB4IDhweDsg
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
bG93LXk6IGF1dG87IG92ZXJmbG93LXg6IGhpZGRlbjsgcGFkZGluZzogNnB4IDhweCA2cHggMTBweDsg
Y3Vyc29yOiBkZWZhdWx0OwogICAgICAgICAgICAvKiBNVVNUIGJlIG5vLWRyYWc6IGRyYWcgcmVnaW9u
IG9uIHRoZSBzY3JvbGxlciBtYWtlcyBXZWJWaWV3MiBzY3JvbGxiYXIvd2hlZWwgaGl0Y2ggKi8KICAg
ICAgICAgICAgLXdlYmtpdC1hcHAtcmVnaW9uOiBuby1kcmFnOyBhcHAtcmVnaW9uOiBuby1kcmFnOwog
ICAgICAgICAgICBtaW4taGVpZ2h0OiAwOwogICAgICAgICAgICBvdmVyZmxvdy1hbmNob3I6IG5vbmU7
CiAgICAgICAgfQogICAgICAgIC8qIFdoaWxlIHNjcm9sbGluZzoga2lsbCBob3ZlciBhbmltYXRpb25z
IHRoYXQgY2F1c2UgbGF5b3V0L3BhaW50IHRocmFzaCAqLwogICAgICAgICNsaXN0LmlzLXNjcm9sbGlu
ZyAuaXRtIHsKICAgICAgICAgICAgdHJhbnNpdGlvbjogbm9uZSAhaW1wb3J0YW50OwogICAgICAgIH0K
ICAgICAgICAjbGlzdC5pcy1zY3JvbGxpbmcgLml0bTo6YmVmb3JlLAogICAgICAgICNsaXN0LmlzLXNj
cm9sbGluZyAuaXRtOjphZnRlciB7CiAgICAgICAgICAgIHRyYW5zaXRpb246IG5vbmUgIWltcG9ydGFu
dDsKICAgICAgICB9CiAgICAgICAgQGtleWZyYW1lcyB0YWJQYW5lSW5MciB7CiAgICAgICAgICAgIGZy
b20geyBvcGFjaXR5OiAwOyB0cmFuc2Zvcm06IHRyYW5zbGF0ZVgoLTQwcHgpOyB9CiAgICAgICAgICAg
IHRvIHsgb3BhY2l0eTogMTsgdHJhbnNmb3JtOiB0cmFuc2xhdGVYKDApOyB9CiAgICAgICAgfQogICAg
ICAgIEBrZXlmcmFtZXMgdGFiUGFuZUluUmwgewogICAgICAgICAgICBmcm9tIHsgb3BhY2l0eTogMDsg
dHJhbnNmb3JtOiB0cmFuc2xhdGVYKDQwcHgpOyB9CiAgICAgICAgICAgIHRvIHsgb3BhY2l0eTogMTsg
dHJhbnNmb3JtOiB0cmFuc2xhdGVYKDApOyB9CiAgICAgICAgfQogICAgICAgICNsaXN0LnRhYi1pbi1s
ciB7IGFuaW1hdGlvbjogdGFiUGFuZUluTHIgLjM0cyBjdWJpYy1iZXppZXIoLjIyLCAxLCAuMzYsIDEp
IGJvdGg7IH0KICAgICAgICAjbGlzdC50YWItaW4tcmwgeyBhbmltYXRpb246IHRhYlBhbmVJblJsIC4z
NHMgY3ViaWMtYmV6aWVyKC4yMiwgMSwgLjM2LCAxKSBib3RoOyB9CiAgICAgICAgI2J0bi10b3Agewog
ICAgICAgICAgICBwb3NpdGlvbjogYWJzb2x1dGU7IHJpZ2h0OiAxMHB4OyBib3R0b206IDEwcHg7IHot
aW5kZXg6IDIwOwogICAgICAgICAgICB3aWR0aDogMjhweDsgaGVpZ2h0OiAyOHB4OyBib3JkZXI6IG5v
bmU7IGJvcmRlci1yYWRpdXM6IDUwJTsKICAgICAgICAgICAgZGlzcGxheTogbm9uZTsgYWxpZ24taXRl
bXM6IGNlbnRlcjsganVzdGlmeS1jb250ZW50OiBjZW50ZXI7CiAgICAgICAgICAgIGJhY2tncm91bmQ6
ICNmZmY7IGNvbG9yOiB2YXIoLS10eHQyKTsKICAgICAgICAgICAgYm94LXNoYWRvdzogMCAycHggOHB4
IHJnYmEoMjQsMzIsNTYsLjE2KTsKICAgICAgICAgICAgY3Vyc29yOiBwb2ludGVyOwogICAgICAgICAg
ICAtd2Via2l0LWFwcC1yZWdpb246IG5vLWRyYWc7IGFwcC1yZWdpb246IG5vLWRyYWc7CiAgICAgICAg
ICAgIHRyYW5zaXRpb246IGJhY2tncm91bmQgdmFyKC0tdHIpLCBjb2xvciB2YXIoLS10ciksIGJveC1z
aGFkb3cgdmFyKC0tdHIpOwogICAgICAgIH0KICAgICAgICAjYnRuLXRvcC5vbiB7IGRpc3BsYXk6IGZs
ZXg7IH0KICAgICAgICAjYnRuLXRvcDpob3ZlciB7IGNvbG9yOiB2YXIoLS1hY2MpOyBiYWNrZ3JvdW5k
OiAjZWRmMWZmOyBib3gtc2hhZG93OiAwIDNweCAxMHB4IHJnYmEoOTEsMTE1LDIzMiwuMjUpOyB9CiAg
ICAgICAgI2J0bi10b3Agc3ZnIHsgd2lkdGg6IDE0cHg7IGhlaWdodDogMTRweDsgZGlzcGxheTogYmxv
Y2s7IH0KICAgICAgICAjZW1wdHkgewogICAgICAgICAgICBkaXNwbGF5OiBub25lOyBmbGV4LWRpcmVj
dGlvbjogY29sdW1uOyBhbGlnbi1pdGVtczogY2VudGVyOyBqdXN0aWZ5LWNvbnRlbnQ6IGNlbnRlcjsK
ICAgICAgICAgICAgcGFkZGluZzogNDhweCAxNnB4OyBjb2xvcjogdmFyKC0tdHh0Myk7IGdhcDogOHB4
OwogICAgICAgICAgICAtd2Via2l0LWFwcC1yZWdpb246IGRyYWc7IGFwcC1yZWdpb246IGRyYWc7CiAg
ICAgICAgfQogICAgICAgICNlbXB0eS5vbiB7IGRpc3BsYXk6IGZsZXg7IH0KICAgICAgICAuZS10eHQg
eyBmb250LXNpemU6IDEycHg7IHRleHQtYWxpZ246IGNlbnRlcjsgbGV0dGVyLXNwYWNpbmc6IC4wMmVt
OyB9CiAgICAgICAgI3NrZWwgewogICAgICAgICAgICBkaXNwbGF5OiBub25lICFpbXBvcnRhbnQ7IC8q
IOenkuW8gOWQjuS4jeWGjeWxleekuumqqOaetuWKqOeUuyAqLwogICAgICAgIH0KICAgICAgICAjc2tl
bC5vbiB7IGRpc3BsYXk6IG5vbmUgIWltcG9ydGFudDsgfQogICAgICAgICNhcHAuYm9vdC1sb2FkaW5n
ICNza2VsIHsKICAgICAgICAgICAgZGlzcGxheTogbm9uZSAhaW1wb3J0YW50OwogICAgICAgIH0KICAg
ICAgICAjYXBwLmJvb3QtbG9hZGluZyAjZW1wdHkgewogICAgICAgICAgICBkaXNwbGF5OiBub25lICFp
bXBvcnRhbnQ7CiAgICAgICAgfQogICAgICAgIC5zay1yb3cgewogICAgICAgICAgICBkaXNwbGF5OiBm
bGV4OyBhbGlnbi1pdGVtczogZmxleC1zdGFydDsgZ2FwOiAxMHB4OwogICAgICAgICAgICBwYWRkaW5n
OiAxMHB4IDhweDsgYm9yZGVyLXJhZGl1czogOHB4OwogICAgICAgICAgICBiYWNrZ3JvdW5kOiByZ2Jh
KDI1NSwyNTUsMjU1LC43Mik7CiAgICAgICAgICAgIGJvcmRlcjogMXB4IHNvbGlkIHJnYmEoMTcwLDE4
MCwyMDAsLjQ1KTsKICAgICAgICAgICAgcG9zaXRpb246IHJlbGF0aXZlOwogICAgICAgICAgICBvdmVy
ZmxvdzogaGlkZGVuOwogICAgICAgIH0KICAgICAgICAuc2stcm93OjphZnRlciB7CiAgICAgICAgICAg
IGNvbnRlbnQ6ICcnOwogICAgICAgICAgICBwb3NpdGlvbjogYWJzb2x1dGU7CiAgICAgICAgICAgIGlu
c2V0OiAwOwogICAgICAgICAgICBiYWNrZ3JvdW5kOiBsaW5lYXItZ3JhZGllbnQoOTBkZWcsIHRyYW5z
cGFyZW50IDAlLCByZ2JhKDI1NSwyNTUsMjU1LC43MikgNDglLCB0cmFuc3BhcmVudCAxMDAlKTsKICAg
ICAgICAgICAgdHJhbnNmb3JtOiB0cmFuc2xhdGVYKC0xMjAlKTsKICAgICAgICAgICAgYW5pbWF0aW9u
OiBzay1zd2VlcCAwLjk1cyBlYXNlLWluLW91dCBpbmZpbml0ZTsKICAgICAgICAgICAgcG9pbnRlci1l
dmVudHM6IG5vbmU7CiAgICAgICAgfQogICAgICAgIEBrZXlmcmFtZXMgc2stc3dlZXAgewogICAgICAg
ICAgICAxMDAlIHsgdHJhbnNmb3JtOiB0cmFuc2xhdGVYKDEyMCUpOyB9CiAgICAgICAgfQogICAgICAg
IC5zay1pY28sIC5zay1saW5lIHsKICAgICAgICAgICAgYmFja2dyb3VuZDogbGluZWFyLWdyYWRpZW50
KDkwZGVnLCAjYjhjMmQ4IDAlLCAjZjBmNGZhIDM4JSwgI2RjZTNmMCA1MiUsICNiOGMyZDggMTAwJSk7
CiAgICAgICAgICAgIGJhY2tncm91bmQtc2l6ZTogMjQwJSAxMDAlOwogICAgICAgICAgICBhbmltYXRp
b246IHNrLXNoaW1tZXIgMC43MnMgZWFzZS1pbi1vdXQgaW5maW5pdGU7CiAgICAgICAgICAgIHdpbGwt
Y2hhbmdlOiBiYWNrZ3JvdW5kLXBvc2l0aW9uOwogICAgICAgICAgICBib3JkZXItcmFkaXVzOiA2cHg7
CiAgICAgICAgfQogICAgICAgIC5zay1pY28geyB3aWR0aDogMzRweDsgaGVpZ2h0OiAzNHB4OyBmbGV4
LXNocmluazogMDsgYm9yZGVyLXJhZGl1czogOHB4OyB9CiAgICAgICAgLnNrLWJvZHkgeyBmbGV4OiAx
OyBtaW4td2lkdGg6IDA7IGRpc3BsYXk6IGZsZXg7IGZsZXgtZGlyZWN0aW9uOiBjb2x1bW47IGdhcDog
OHB4OyBwYWRkaW5nLXRvcDogMnB4OyB9CiAgICAgICAgLnNrLWxpbmUgeyBoZWlnaHQ6IDEwcHg7IHdp
ZHRoOiAxMDAlOyB9CiAgICAgICAgLnNrLWxpbmUuc2hvcnQgeyB3aWR0aDogNDIlOyB9CiAgICAgICAg
LnNrLWxpbmUubWlkIHsgd2lkdGg6IDY4JTsgfQogICAgICAgIC5zay1yb3c6bnRoLWNoaWxkKDIpOjph
ZnRlciB7IGFuaW1hdGlvbi1kZWxheTogLjEyczsgfQogICAgICAgIC5zay1yb3c6bnRoLWNoaWxkKDMp
OjphZnRlciB7IGFuaW1hdGlvbi1kZWxheTogLjI0czsgfQogICAgICAgIC5zay1yb3c6bnRoLWNoaWxk
KDQpOjphZnRlciB7IGFuaW1hdGlvbi1kZWxheTogLjM2czsgfQogICAgICAgIC5zay1yb3c6bnRoLWNo
aWxkKDUpOjphZnRlciB7IGFuaW1hdGlvbi1kZWxheTogLjQ4czsgfQogICAgICAgIC5zay1yb3c6bnRo
LWNoaWxkKDYpOjphZnRlciB7IGFuaW1hdGlvbi1kZWxheTogLjZzOyB9CiAgICAgICAgQGtleWZyYW1l
cyBzay1zaGltbWVyIHsKICAgICAgICAgICAgMCUgeyBiYWNrZ3JvdW5kLXBvc2l0aW9uOiAxMDAlIDA7
IH0KICAgICAgICAgICAgMTAwJSB7IGJhY2tncm91bmQtcG9zaXRpb246IC0xMDAlIDA7IH0KICAgICAg
ICB9CiAgICAgICAgLmxpc3QtbW9yZSB7CiAgICAgICAgICAgIHRleHQtYWxpZ246IGNlbnRlcjsgcGFk
ZGluZzogMTBweCA4cHggMTRweDsgZm9udC1zaXplOiAxMXB4OwogICAgICAgICAgICBjb2xvcjogdmFy
KC0tdHh0Myk7IC13ZWJraXQtYXBwLXJlZ2lvbjogbm8tZHJhZzsgYXBwLXJlZ2lvbjogbm8tZHJhZzsK
ICAgICAgICB9CiAgICAgICAgLmxpc3QtbW9yZS5kb25lIHsgZGlzcGxheTogbm9uZTsgfQoKICAgICAg
ICAuaXRtIHsKICAgICAgICAgICAgZGlzcGxheTogZmxleDsgYWxpZ24taXRlbXM6IGZsZXgtc3RhcnQ7
IGdhcDogOHB4OwogICAgICAgICAgICBwYWRkaW5nOiA4cHg7IG1hcmdpbi1ib3R0b206IDVweDsKICAg
ICAgICAgICAgYmFja2dyb3VuZDogdmFyKC0tY2FyZCk7IGJvcmRlci1yYWRpdXM6IHZhcigtLXIpOyBj
dXJzb3I6IHBvaW50ZXI7CiAgICAgICAgICAgIGJveC1zaGFkb3c6IDAgMXB4IDNweCByZ2JhKDI0LDMy
LDU2LC4wNik7CiAgICAgICAgICAgIC8qIGhvdmVyLWxpbmUgKi8KICAgICAgICAgICAgcG9zaXRpb246
IHJlbGF0aXZlOwogICAgICAgICAgICB0cmFuc2l0aW9uOiBiYWNrZ3JvdW5kIC4ycyBlYXNlLCBib3gt
c2hhZG93IC4ycyBlYXNlOwogICAgICAgICAgICAtd2Via2l0LWFwcC1yZWdpb246IG5vLWRyYWc7IGFw
cC1yZWdpb246IG5vLWRyYWc7CiAgICAgICAgICAgIG92ZXJmbG93OiB2aXNpYmxlOwogICAgICAgIH0K
ICAgICAgICAuaXRtOjpiZWZvcmUgewogICAgICAgICAgICBjb250ZW50OiAiIjsKICAgICAgICAgICAg
cG9zaXRpb246IGFic29sdXRlOwogICAgICAgICAgICBsZWZ0OiAwOyByaWdodDogMDsgYm90dG9tOiAw
OwogICAgICAgICAgICBoZWlnaHQ6IDA7CiAgICAgICAgICAgIHBvaW50ZXItZXZlbnRzOiBub25lOwog
ICAgICAgICAgICB6LWluZGV4OiAwOwogICAgICAgICAgICBib3JkZXItcmFkaXVzOiAwIDAgdmFyKC0t
cikgdmFyKC0tcik7CiAgICAgICAgICAgIGJhY2tncm91bmQ6IGxpbmVhci1ncmFkaWVudCh0byB0b3As
IHJnYmEoOTEsMTE1LDIzMiwuMzIpLCByZ2JhKDkxLDExNSwyMzIsLjEyKSA1NSUsIHRyYW5zcGFyZW50
KTsKICAgICAgICAgICAgdHJhbnNpdGlvbjogaGVpZ2h0IC4zNHMgY3ViaWMtYmV6aWVyKC4yMiwxLC4z
NiwxKTsKICAgICAgICB9CiAgICAgICAgLml0bTpob3Zlcjo6YmVmb3JlIHsgaGVpZ2h0OiAzMy4zMzMl
OyB9CiAgICAgICAgLml0bTo6YWZ0ZXIgewogICAgICAgICAgICBjb250ZW50OiAiIjsKICAgICAgICAg
ICAgcG9zaXRpb246IGFic29sdXRlOwogICAgICAgICAgICBsZWZ0OiAwOyByaWdodDogMDsgYm90dG9t
OiAwOwogICAgICAgICAgICBoZWlnaHQ6IDJweDsKICAgICAgICAgICAgcG9pbnRlci1ldmVudHM6IG5v
bmU7CiAgICAgICAgICAgIHotaW5kZXg6IDE7CiAgICAgICAgICAgIGJhY2tncm91bmQ6IHJnYmEoOTEs
MTE1LDIzMiwuOTUpOwogICAgICAgICAgICBib3JkZXItcmFkaXVzOiAxcHg7CiAgICAgICAgICAgIHRy
YW5zZm9ybTogc2NhbGVYKDApOwogICAgICAgICAgICB0cmFuc2Zvcm0tb3JpZ2luOiBjZW50ZXI7CiAg
ICAgICAgICAgIHRyYW5zaXRpb246IHRyYW5zZm9ybSAuM3MgY3ViaWMtYmV6aWVyKC4yMiwxLC4zNiwx
KTsKICAgICAgICB9CiAgICAgICAgLml0bTpob3ZlciB7CiAgICAgICAgICAgIGJhY2tncm91bmQ6IHZh
cigtLWNhcmQtaCk7CiAgICAgICAgICAgIGJveC1zaGFkb3c6IDAgMnB4IDhweCByZ2JhKDI0LDMyLDU2
LC4xKTsKICAgICAgICB9CiAgICAgICAgLml0bTpob3Zlcjo6YWZ0ZXIgewogICAgICAgICAgICB0cmFu
c2Zvcm06IHNjYWxlWCgxKTsKICAgICAgICB9CiAgICAgICAgLml0bS5zZWwgewogICAgICAgICAgICBi
b3gtc2hhZG93OiAwIDAgMCAycHggcmdiYSg5MSwxMTUsMjMyLC40NSksIDAgMnB4IDhweCByZ2JhKDkx
LDExNSwyMzIsLjE4KTsKICAgICAgICAgICAgYmFja2dyb3VuZDogI2VkZjFmZjsKICAgICAgICB9CiAg
ICAgICAgLml0bS5tdWx0aSB7CiAgICAgICAgICAgIGJveC1zaGFkb3c6IDAgMCAwIDEuNXB4IHJnYmEo
OTEsMTE1LDIzMiwuNTUpLCAwIDJweCA2cHggcmdiYSg5MSwxMTUsMjMyLC4xOCk7CiAgICAgICAgICAg
IGJhY2tncm91bmQ6ICNlZWYyZmY7CiAgICAgICAgfQogICAgICAgIC5pdG0ubXVsdGkuc2VsIHsKICAg
ICAgICAgICAgYm94LXNoYWRvdzogMCAwIDAgMnB4IHJnYmEoOTEsMTE1LDIzMiwuNyksIDAgMnB4IDhw
eCByZ2JhKDkxLDExNSwyMzIsLjIyKTsKICAgICAgICB9CgogICAgICAgICNtdWx0aS1jbnQgewogICAg
ICAgICAgICBkaXNwbGF5OiBub25lOyBhbGlnbi1pdGVtczogY2VudGVyOyBqdXN0aWZ5LWNvbnRlbnQ6
IGNlbnRlcjsKICAgICAgICAgICAgaGVpZ2h0OiAyMnB4OyBwYWRkaW5nOiAwIDhweDsgbWFyZ2luLXJp
Z2h0OiA0cHg7CiAgICAgICAgICAgIGJvcmRlcjogbm9uZTsgYm9yZGVyLXJhZGl1czogMTFweDsgY3Vy
c29yOiBwb2ludGVyOwogICAgICAgICAgICBiYWNrZ3JvdW5kOiB2YXIoLS1hY2MpOyBjb2xvcjogI2Zm
ZjsgZm9udC1zaXplOiAxMXB4OyBmb250LXdlaWdodDogNzAwOwogICAgICAgICAgICAtd2Via2l0LWFw
cC1yZWdpb246IG5vLWRyYWc7IGFwcC1yZWdpb246IG5vLWRyYWc7CiAgICAgICAgICAgIHRyYW5zaXRp
b246IG9wYWNpdHkgdmFyKC0tdHIpLCBiYWNrZ3JvdW5kIHZhcigtLXRyKTsKICAgICAgICB9CiAgICAg
ICAgI211bHRpLWNudDpob3ZlciB7IGJhY2tncm91bmQ6ICM0YTYyZDQ7IH0KICAgICAgICAjbXVsdGkt
Y250Lm9uIHsgZGlzcGxheTogaW5saW5lLWZsZXg7IH0KCiAgICAgICAgLmktaWNvIHsKICAgICAgICAg
ICAgd2lkdGg6IDI4cHg7IGhlaWdodDogMjhweDsgYm9yZGVyLXJhZGl1czogdmFyKC0tcik7IGRpc3Bs
YXk6IGZsZXg7CiAgICAgICAgICAgIGFsaWduLWl0ZW1zOiBjZW50ZXI7IGp1c3RpZnktY29udGVudDog
Y2VudGVyOyBmbGV4LXNocmluazogMDsKICAgICAgICAgICAgYmFja2dyb3VuZDogI2VkZjJmZjsgY29s
b3I6IHZhcigtLWFjYyk7CiAgICAgICAgICAgIHBvc2l0aW9uOiByZWxhdGl2ZTsgb3ZlcmZsb3c6IHZp
c2libGU7CiAgICAgICAgfQogICAgICAgIC5pLWljbyBzdmcgeyB3aWR0aDogMTZweDsgaGVpZ2h0OiAx
NnB4OyBkaXNwbGF5OiBibG9jazsgfQogICAgICAgIC5pLWljby5mdC1pbWcgeyBjb2xvcjogIzdhZDdm
ZjsgfQogICAgICAgIC5pLWljby5mdC12aWQgeyBjb2xvcjogI2MwODRmYzsgfQogICAgICAgIC5pLWlj
by5mdC16aXAgeyBjb2xvcjogIzhhYjRmZjsgfQogICAgICAgIC5pLWljby5mdC1kaXIgeyBjb2xvcjog
I2ZmZDU2YTsgfQogICAgICAgIC5pLWljby5mdC1haGsgeyBjb2xvcjogIzZkZmY5YTsgfQogICAgICAg
IC5pLWljby5tZCB7IGNvbG9yOiAjNmI4Y2ZmOyB9CiAgICAgICAgLmktaWNvLm1kIHN2ZyB7IHdpZHRo
OiAyMHB4OyBoZWlnaHQ6IDIwcHg7IH0KICAgICAgICAuaS1pY28uZnQtbG5rLCAuaS1pY28uZnQtZG9j
IHsgY29sb3I6ICNhOWJkZDA7IH0KICAgICAgICAuaS11c2VkIHsKICAgICAgICAgICAgcG9zaXRpb246
IGFic29sdXRlOyByaWdodDogMDsgYm90dG9tOiAwOwogICAgICAgICAgICB3aWR0aDogMTNweDsgaGVp
Z2h0OiAxM3B4OyBib3JkZXItcmFkaXVzOiA1MCU7CiAgICAgICAgICAgIGJhY2tncm91bmQ6ICMyMmM1
NWU7IGJvcmRlcjogMS41cHggc29saWQgI2ZmZjsKICAgICAgICAgICAgZGlzcGxheTogZmxleDsgYWxp
Z24taXRlbXM6IGNlbnRlcjsganVzdGlmeS1jb250ZW50OiBjZW50ZXI7CiAgICAgICAgICAgIHBvaW50
ZXItZXZlbnRzOiBub25lOyB6LWluZGV4OiAzOwogICAgICAgICAgICBib3gtc2hhZG93OiAwIDFweCAy
cHggcmdiYSgwLDAsMCwuMTYpOwogICAgICAgICAgICB0cmFuc2Zvcm06IHRyYW5zbGF0ZSgzMCUsIDMw
JSk7CiAgICAgICAgfQogICAgICAgIC5pLXVzZWQgc3ZnIHsgd2lkdGg6IDlweDsgaGVpZ2h0OiA5cHg7
IGNvbG9yOiAjZmZmOyBkaXNwbGF5OiBibG9jazsgfQoKICAgICAgICAvKiBQYXN0ZS1xdWV1ZSB2aXN1
YWwgY2hhaW46IGdyYXkgPSBpbiBxdWV1ZTsgZ3JlZW4gPSBkZXF1ZXVlZCAocGFzdGVkKSBjaGFpbiAq
LwogICAgICAgIC5pdG0ucS1tZW1iZXIgewogICAgICAgICAgICBwYWRkaW5nLWxlZnQ6IDE0cHg7CiAg
ICAgICAgICAgIC8qIE1VU1Qgb3ZlcnJpZGUgZ2xvYmFsIC5pdG17b3ZlcmZsb3c6aGlkZGVufSDigJQg
b3RoZXJ3aXNlIGJvdHRvbTotTiByYWlsCiAgICAgICAgICAgICAgIGlzIGNsaXBwZWQgYW5kIHRoZSBj
aGFpbiBsb29rcyDigJzmlq3nur/igJ0gYWNyb3NzIHRoZSA1cHggY2FyZCBnYXAgKi8KICAgICAgICAg
ICAgb3ZlcmZsb3c6IHZpc2libGUgIWltcG9ydGFudDsKICAgICAgICB9CiAgICAgICAgLml0bS5xLW1l
bWJlciAucS1yYWlsIHsKICAgICAgICAgICAgcG9zaXRpb246IGFic29sdXRlOwogICAgICAgICAgICBs
ZWZ0OiA1cHg7CiAgICAgICAgICAgIHRvcDogMDsKICAgICAgICAgICAgLyogQnJpZGdlIC5pdG0gbWFy
Z2luLWJvdHRvbTo1cHggc28gY29uc2VjdXRpdmUgcmFpbHMgcmVhZCBhcyBvbmUgc3Ryb2tlICovCiAg
ICAgICAgICAgIGJvdHRvbTogLTVweDsKICAgICAgICAgICAgd2lkdGg6IDJweDsKICAgICAgICAgICAg
YmFja2dyb3VuZDogIzljYTNhZjsKICAgICAgICAgICAgb3BhY2l0eTogLjcyOwogICAgICAgICAgICBw
b2ludGVyLWV2ZW50czogbm9uZTsKICAgICAgICAgICAgei1pbmRleDogNDsKICAgICAgICB9CiAgICAg
ICAgLml0bS5xLW1lbWJlci5xLWZpcnN0IC5xLXJhaWwgeyB0b3A6IDE2cHg7IGJvcmRlci1yYWRpdXM6
IDJweCAycHggMCAwOyB9CiAgICAgICAgLyogRW5kIGNoYWluIGF0IHRoZSBsYXN0IGRvdCDigJQgZG8g
bm90IGhhbmcgaW50byB0aGUgZ2FwIGJlbG93ICovCiAgICAgICAgLml0bS5xLW1lbWJlci5xLWxhc3Qg
LnEtcmFpbCB7CiAgICAgICAgICAgIGJvdHRvbTogYXV0bzsKICAgICAgICAgICAgaGVpZ2h0OiAyMnB4
OwogICAgICAgICAgICBib3JkZXItcmFkaXVzOiAwIDAgMnB4IDJweDsKICAgICAgICB9CiAgICAgICAg
Lml0bS5xLW1lbWJlci5xLWZpcnN0LnEtbGFzdCAucS1yYWlsLAogICAgICAgIC5pdG0ucS1tZW1iZXIu
cS1vbmx5IC5xLXJhaWwgeyBkaXNwbGF5OiBub25lOyB9CiAgICAgICAgLml0bS5xLW1lbWJlciAucS1k
b3QgewogICAgICAgICAgICBwb3NpdGlvbjogYWJzb2x1dGU7CiAgICAgICAgICAgIGxlZnQ6IDJweDsK
ICAgICAgICAgICAgdG9wOiAxNHB4OwogICAgICAgICAgICB3aWR0aDogOHB4OwogICAgICAgICAgICBo
ZWlnaHQ6IDhweDsKICAgICAgICAgICAgYm9yZGVyLXJhZGl1czogNTAlOwogICAgICAgICAgICBiYWNr
Z3JvdW5kOiAjOWNhM2FmOwogICAgICAgICAgICBib3JkZXI6IDEuNXB4IHNvbGlkICNmZmY7CiAgICAg
ICAgICAgIGJveC1zaGFkb3c6IDAgMCAwIDFweCByZ2JhKDE1NiwxNjMsMTc1LC40NSk7CiAgICAgICAg
ICAgIHBvaW50ZXItZXZlbnRzOiBub25lOwogICAgICAgICAgICB6LWluZGV4OiA1OwogICAgICAgIH0K
ICAgICAgICAvKiBEZXF1ZXVlZDogZ3JlZW4gZG90czsgZ3JlZW4gcmFpbCBmb3IgY29uc2VjdXRpdmUg
ZG9uZSBydW4gKi8KICAgICAgICAuaXRtLnEtbWVtYmVyLnEtZG9uZSAucS1kb3QgewogICAgICAgICAg
ICBiYWNrZ3JvdW5kOiAjMjJjNTVlOwogICAgICAgICAgICBib3gtc2hhZG93OiAwIDAgMCAxcHggcmdi
YSgzNCwxOTcsOTQsLjQpOwogICAgICAgIH0KICAgICAgICAuaXRtLnEtbWVtYmVyLnEtZG9uZS1saW5r
IC5xLXJhaWwgewogICAgICAgICAgICBiYWNrZ3JvdW5kOiAjMjJjNTVlOwogICAgICAgICAgICBvcGFj
aXR5OiAuOTI7CiAgICAgICAgfQoKICAgICAgICAuaXRtLmp1bXAtZmxhc2ggewogICAgICAgICAgICBi
b3gtc2hhZG93OiAwIDAgMCAycHggcmdiYSg5MSwxMTUsMjMyLC41NSksIDAgMnB4IDEwcHggcmdiYSg5
MSwxMTUsMjMyLC4yMik7CiAgICAgICAgICAgIGJhY2tncm91bmQ6ICNlOGVkZmY7CiAgICAgICAgICAg
IHRyYW5zaXRpb246IGJhY2tncm91bmQgLjM1cyBlYXNlLCBib3gtc2hhZG93IC4zNXMgZWFzZTsKICAg
ICAgICB9CgogICAgICAgIC5pLWJvZHkgeyBmbGV4OiAxOyBtaW4td2lkdGg6IDA7IGRpc3BsYXk6IGZs
ZXg7IGZsZXgtZGlyZWN0aW9uOiBjb2x1bW47IHBvc2l0aW9uOiByZWxhdGl2ZTsgei1pbmRleDogMjsg
fQogICAgICAgIC5pLXByZXYsIC5pLW5hbWUgewogICAgICAgICAgICBmb250LXNpemU6IDEzcHg7IGZv
bnQtd2VpZ2h0OiA1MDA7IGNvbG9yOiB2YXIoLS10eHQpOyB3b3JkLWJyZWFrOiBicmVhay1hbGw7CiAg
ICAgICAgICAgIHdoaXRlLXNwYWNlOiBwcmUtd3JhcDsgLyog5pSv5oyB5aSa5paH5Lu2L+WkmuihjOaW
h+acrOaNouihjOaYvuekuiAqLwogICAgICAgIH0KICAgICAgICAuaS1wcmV2IHsKICAgICAgICAgICAg
ZGlzcGxheTogLXdlYmtpdC1ib3g7IC13ZWJraXQtYm94LW9yaWVudDogdmVydGljYWw7IC13ZWJraXQt
bGluZS1jbGFtcDogNTsgb3ZlcmZsb3c6IGhpZGRlbjsKICAgICAgICAgICAgdGV4dC1vdmVyZmxvdzog
ZWxsaXBzaXM7CiAgICAgICAgfQogICAgICAgIC5pLW5hbWUgewogICAgICAgICAgICBkaXNwbGF5OiAt
d2Via2l0LWJveDsgLXdlYmtpdC1ib3gtb3JpZW50OiB2ZXJ0aWNhbDsgLXdlYmtpdC1saW5lLWNsYW1w
OiAyOyBvdmVyZmxvdzogaGlkZGVuOwogICAgICAgIH0KICAgICAgICAvKiBGaWxlIGNsaXAgd2hvc2Ug
cGF0aChzKSBubyBsb25nZXIgZXhpc3Qg4oCUIGxpZ2h0IGJvbGQgZ3JheSBzdHJpa2UgKi8KICAgICAg
ICAuaXRtLmdvbmUgLmktbmFtZSB7CiAgICAgICAgICAgIGNvbG9yOiAjOWFhMGIwOwogICAgICAgICAg
ICB0ZXh0LWRlY29yYXRpb246IGxpbmUtdGhyb3VnaDsKICAgICAgICAgICAgdGV4dC1kZWNvcmF0aW9u
LXRoaWNrbmVzczogMnB4OwogICAgICAgICAgICB0ZXh0LWRlY29yYXRpb24tY29sb3I6IHJnYmEoMTU0
LCAxNjAsIDE3NiwgLjU1KTsKICAgICAgICAgICAgdGV4dC1kZWNvcmF0aW9uLXNraXAtaW5rOiBub25l
OwogICAgICAgIH0KICAgICAgICAuaXRtLmdvbmUgLmktaWNvIHsgb3BhY2l0eTogLjU1OyB9CiAgICAg
ICAgLml0bS5nb25lIC5pLXRodW1iLXdyYXAgeyBvcGFjaXR5OiAuNTU7IH0KICAgICAgICAuaS1wcmV2
LnVybCB7IGNvbG9yOiB2YXIoLS1hY2MpOyB9CgogICAgICAgIC5yZi1wYXRoIHsKICAgICAgICAgICAg
ZGlzcGxheTogZmxleDsgZmxleC13cmFwOiB3cmFwOyBhbGlnbi1pdGVtczogY2VudGVyOwogICAgICAg
ICAgICBnYXA6IDA7IHJvdy1nYXA6IDNweDsKICAgICAgICAgICAgZm9udC1zaXplOiAxM3B4OyBmb250
LXdlaWdodDogNjAwOyBjb2xvcjogdmFyKC0tdHh0KTsKICAgICAgICAgICAgbGluZS1oZWlnaHQ6IDEu
NDU7IHdvcmQtYnJlYWs6IGJyZWFrLXdvcmQ7CiAgICAgICAgICAgIG1heC13aWR0aDogMTAwJTsKICAg
ICAgICAgICAgd2lkdGg6IGZpdC1jb250ZW50OwogICAgICAgICAgICBwb3NpdGlvbjogcmVsYXRpdmU7
CiAgICAgICAgICAgIHotaW5kZXg6IDY7CiAgICAgICAgICAgIC13ZWJraXQtYXBwLXJlZ2lvbjogbm8t
ZHJhZzsgYXBwLXJlZ2lvbjogbm8tZHJhZzsKICAgICAgICAgICAgcG9pbnRlci1ldmVudHM6IGF1dG87
CiAgICAgICAgfQogICAgICAgIC5yZi1zZWcgewogICAgICAgICAgICBjb2xvcjogdmFyKC0tYWNjKTsK
ICAgICAgICAgICAgY3Vyc29yOiBwb2ludGVyOwogICAgICAgICAgICBwYWRkaW5nOiAxcHggM3B4Owog
ICAgICAgICAgICBtYXJnaW46IDA7CiAgICAgICAgICAgIGJvcmRlcjogbm9uZTsKICAgICAgICAgICAg
YmFja2dyb3VuZDogdHJhbnNwYXJlbnQ7CiAgICAgICAgICAgIGJvcmRlci1yYWRpdXM6IDNweDsKICAg
ICAgICAgICAgZm9udDogaW5oZXJpdDsKICAgICAgICAgICAgZm9udC1zaXplOiAxM3B4OwogICAgICAg
ICAgICBmb250LXdlaWdodDogNjAwOwogICAgICAgICAgICBsaW5lLWhlaWdodDogMS40NTsKICAgICAg
ICAgICAgLXdlYmtpdC1hcHAtcmVnaW9uOiBuby1kcmFnOyBhcHAtcmVnaW9uOiBuby1kcmFnOwogICAg
ICAgICAgICBwb2ludGVyLWV2ZW50czogYXV0byAhaW1wb3J0YW50OwogICAgICAgICAgICBwb3NpdGlv
bjogcmVsYXRpdmU7CiAgICAgICAgICAgIHotaW5kZXg6IDg7CiAgICAgICAgICAgIHRyYW5zaXRpb246
IGJhY2tncm91bmQgLjEycyBlYXNlLCBjb2xvciAuMTJzIGVhc2U7CiAgICAgICAgfQogICAgICAgIC5y
Zi1zZWc6aG92ZXIgewogICAgICAgICAgICBiYWNrZ3JvdW5kOiByZ2JhKDkxLDExNSwyMzIsLjE0KTsK
ICAgICAgICAgICAgdGV4dC1kZWNvcmF0aW9uOiB1bmRlcmxpbmU7CiAgICAgICAgfQogICAgICAgIC5y
Zi1zZXAgewogICAgICAgICAgICBjb2xvcjogdmFyKC0tdHh0Myk7CiAgICAgICAgICAgIHBhZGRpbmc6
IDAgMnB4OwogICAgICAgICAgICBtYXJnaW46IDA7CiAgICAgICAgICAgIHVzZXItc2VsZWN0OiBub25l
OwogICAgICAgICAgICBmbGV4LXNocmluazogMDsKICAgICAgICAgICAgb3BhY2l0eTogLjU1OwogICAg
ICAgICAgICBwb2ludGVyLWV2ZW50czogbm9uZTsKICAgICAgICAgICAgZm9udC1zaXplOiAxMnB4Owog
ICAgICAgICAgICBsaW5lLWhlaWdodDogMS40NTsKICAgICAgICB9CiAgICAgICAgLml0bS5yZi1maXhl
ZCAuaS1pY28gewogICAgICAgICAgICBib3gtc2hhZG93OiAwIDAgMCAxLjVweCByZ2JhKDkxLDExNSwy
MzIsLjQ1KTsKICAgICAgICB9CiAgICAgICAgLnJmLXBpbi10YWcgewogICAgICAgICAgICBkaXNwbGF5
OiBpbmxpbmUtZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsganVzdGlmeS1jb250ZW50OiBjZW50ZXI7
CiAgICAgICAgICAgIGZsZXgtc2hyaW5rOiAwOwogICAgICAgICAgICBoZWlnaHQ6IDE2cHg7IHBhZGRp
bmc6IDAgNnB4OyBtYXJnaW4tcmlnaHQ6IDA7CiAgICAgICAgICAgIGJvcmRlci1yYWRpdXM6IDRweDsK
ICAgICAgICAgICAgZm9udC1zaXplOiAxMHB4OyBmb250LXdlaWdodDogNTAwOwogICAgICAgICAgICBj
b2xvcjogIzdhODQ5OTsKICAgICAgICAgICAgYmFja2dyb3VuZDogcmdiYSgxMjIsMTMyLDE1MywuMTIp
OwogICAgICAgICAgICBib3JkZXI6IDFweCBzb2xpZCByZ2JhKDEyMiwxMzIsMTUzLC4yMik7CiAgICAg
ICAgICAgIGxldHRlci1zcGFjaW5nOiAuMDJlbTsKICAgICAgICAgICAgd2hpdGUtc3BhY2U6IG5vd3Jh
cDsKICAgICAgICAgICAgcG9pbnRlci1ldmVudHM6IG5vbmU7CiAgICAgICAgfQogICAgICAgIC5pLXRo
dW1iLXdyYXAgewogICAgICAgICAgICB3aWR0aDogMTAwJTsgbWluLWhlaWdodDogNDhweDsgbWF4LWhl
aWdodDogMTgwcHg7IG1hcmdpbi1ib3R0b206IDRweDsKICAgICAgICAgICAgZGlzcGxheTogZmxleDsg
YWxpZ24taXRlbXM6IGNlbnRlcjsganVzdGlmeS1jb250ZW50OiBjZW50ZXI7CiAgICAgICAgICAgIGJh
Y2tncm91bmQ6ICNmM2Y1Zjk7IGJvcmRlci1yYWRpdXM6IHZhcigtLXIpOyBvdmVyZmxvdzogaGlkZGVu
OwogICAgICAgIH0KICAgICAgICAuaS10aHVtYi13cmFwLndhaXRpbmcgewogICAgICAgICAgICBtaW4t
aGVpZ2h0OiA4OHB4OwogICAgICAgICAgICBiYWNrZ3JvdW5kOiBsaW5lYXItZ3JhZGllbnQoOTBkZWcs
ICNlOGViZjIgMCUsICNmNGY2ZmEgNDUlLCAjZThlYmYyIDEwMCUpOwogICAgICAgICAgICBiYWNrZ3Jv
dW5kLXNpemU6IDIwMCUgMTAwJTsKICAgICAgICAgICAgYW5pbWF0aW9uOiB0aHVtYlNoaW1tZXIgMS4w
NXMgZWFzZS1pbi1vdXQgaW5maW5pdGU7CiAgICAgICAgfQogICAgICAgIEBrZXlmcmFtZXMgdGh1bWJT
aGltbWVyIHsKICAgICAgICAgICAgMCUgeyBiYWNrZ3JvdW5kLXBvc2l0aW9uOiAxMDAlIDA7IH0KICAg
ICAgICAgICAgMTAwJSB7IGJhY2tncm91bmQtcG9zaXRpb246IC0xMDAlIDA7IH0KICAgICAgICB9CiAg
ICAgICAgLmktdGh1bWIgeyBtYXgtd2lkdGg6IDEwMCU7IG1heC1oZWlnaHQ6IDE4MHB4OyB3aWR0aDog
YXV0bzsgaGVpZ2h0OiBhdXRvOyBvYmplY3QtZml0OiBjb250YWluOyBkaXNwbGF5OiBibG9jazsgfQog
ICAgICAgIC5pLXRodW1iLnRodW1iLWxvYWRpbmcgeyBvcGFjaXR5OiAwOyB3aWR0aDogMXB4OyBoZWln
aHQ6IDFweDsgfQoKICAgICAgICAvKiBNZXRhIGJhcjogdGltZSBsZWZ0IHwgZXhwYW5kIGNlbnRlciB8
IHRhZ3MgcmlnaHQgKi8KICAgICAgICAuaS1tZXRhIHsKICAgICAgICAgICAgZGlzcGxheTogZ3JpZDsK
ICAgICAgICAgICAgZ3JpZC10ZW1wbGF0ZS1jb2x1bW5zOiAxZnIgYXV0byAxZnI7CiAgICAgICAgICAg
IGFsaWduLWl0ZW1zOiBjZW50ZXI7CiAgICAgICAgICAgIGdhcDogNHB4OwogICAgICAgICAgICBtYXJn
aW4tdG9wOiA0cHg7CiAgICAgICAgICAgIHdpZHRoOiAxMDAlOwogICAgICAgIH0KICAgICAgICAuaS1t
ZXRhIC5pLXRpbWUgeyBqdXN0aWZ5LXNlbGY6IHN0YXJ0OyB9CiAgICAgICAgLmktbWV0YS1jZW50ZXIg
ewogICAgICAgICAgICBqdXN0aWZ5LXNlbGY6IGNlbnRlcjsKICAgICAgICAgICAgZGlzcGxheTogZmxl
eDsgYWxpZ24taXRlbXM6IGNlbnRlcjsganVzdGlmeS1jb250ZW50OiBjZW50ZXI7CiAgICAgICAgICAg
IGdhcDogNHB4OwogICAgICAgICAgICBtaW4td2lkdGg6IDFweDsgLyoga2VlcCBjZW50ZXIgY29sdW1u
IGV2ZW4gd2hlbiBleHBhbmQgaXMgaGlkZGVuICovCiAgICAgICAgfQogICAgICAgIC5pLW1ldGEtcmln
aHQgewogICAgICAgICAgICBqdXN0aWZ5LXNlbGY6IGVuZDsKICAgICAgICAgICAgZGlzcGxheTogZmxl
eDsgYWxpZ24taXRlbXM6IGNlbnRlcjsgZ2FwOiA1cHg7IGZsZXgtd3JhcDogbm93cmFwOwogICAgICAg
ICAgICBqdXN0aWZ5LWNvbnRlbnQ6IGZsZXgtZW5kOwogICAgICAgICAgICBtaW4td2lkdGg6IDA7CiAg
ICAgICAgfQogICAgICAgIC5pLW1ldGEtcmlnaHQudGV4dC1tZXRhIHsKICAgICAgICAgICAgZmxleC13
cmFwOiBub3dyYXA7CiAgICAgICAgICAgIGdhcDogNHB4OwogICAgICAgIH0KICAgICAgICAuaS1zcmMt
dGl0bGUgewogICAgICAgICAgICBmb250LXNpemU6IDEwcHg7CiAgICAgICAgICAgIGNvbG9yOiB2YXIo
LS10eHQzKTsKICAgICAgICAgICAgbWF4LXdpZHRoOiAxMWVtOwogICAgICAgICAgICBvdmVyZmxvdzog
aGlkZGVuOwogICAgICAgICAgICB0ZXh0LW92ZXJmbG93OiBlbGxpcHNpczsKICAgICAgICAgICAgd2hp
dGUtc3BhY2U6IG5vd3JhcDsKICAgICAgICAgICAgbWluLXdpZHRoOiAwOwogICAgICAgICAgICBsaW5l
LWhlaWdodDogMS40OwogICAgICAgIH0KICAgICAgICAuaS10aW1lLCAuaS10YWcgeyBmb250LXNpemU6
IDEwcHg7IGNvbG9yOiB2YXIoLS10eHQzKTsgfQogICAgICAgIC5pLXRhZyB7CiAgICAgICAgICAgIGJh
Y2tncm91bmQ6ICNmMWYzZjg7IHBhZGRpbmc6IDAgNXB4OyBib3JkZXItcmFkaXVzOiAzcHg7CiAgICAg
ICAgICAgIHdoaXRlLXNwYWNlOiBub3dyYXA7IGZsZXgtc2hyaW5rOiAwOyBsaW5lLWhlaWdodDogMS40
OwogICAgICAgIH0KICAgICAgICAuaS1jaGFycyB7CiAgICAgICAgICAgIGZvbnQtc2l6ZTogMTBweDsg
Y29sb3I6IHZhcigtLXR4dDMpOwogICAgICAgICAgICBiYWNrZ3JvdW5kOiAjZjFmM2Y4OyBwYWRkaW5n
OiAwIDVweDsgYm9yZGVyLXJhZGl1czogM3B4OwogICAgICAgICAgICBmb250LXZhcmlhbnQtbnVtZXJp
YzogdGFidWxhci1udW1zOwogICAgICAgICAgICB3aGl0ZS1zcGFjZTogbm93cmFwOwogICAgICAgICAg
ICBkaXNwbGF5OiBpbmxpbmUtZmxleDsgYWxpZ24taXRlbXM6IGJhc2VsaW5lOyBnYXA6IDJweDsKICAg
ICAgICB9CiAgICAgICAgLmktY2hhcnMgLm4gewogICAgICAgICAgICBkaXNwbGF5OiBpbmxpbmUtYmxv
Y2s7CiAgICAgICAgICAgIG1pbi13aWR0aDogNGNoOwogICAgICAgICAgICB0ZXh0LWFsaWduOiByaWdo
dDsKICAgICAgICAgICAgZm9udC1mYW1pbHk6ICdDYXNjYWRpYSBNb25vJywgJ0NvbnNvbGFzJywgJ1Nh
cmFzYSBNb25vIFNDJywgdWktbW9ub3NwYWNlLCBtb25vc3BhY2U7CiAgICAgICAgICAgIGZvbnQtd2Vp
Z2h0OiA2MDA7CiAgICAgICAgICAgIGNvbG9yOiB2YXIoLS10eHQyKTsKICAgICAgICB9CiAgICAgICAg
Lyogc3JjLXRpdGxlLXRpcCAqLwogICAgICAgIC5pLXNyYy1pY28sIC5tZy1zcmMgeyBjdXJzb3I6IHBv
aW50ZXI7IH0KICAgICAgICAjc3JjLXRpcCB7CiAgICAgICAgICAgIHBvc2l0aW9uOiBmaXhlZDsgei1p
bmRleDogOTk5OTk7CiAgICAgICAgICAgIG1heC13aWR0aDogbWluKDI4MHB4LCBjYWxjKDEwMHZ3IC0g
MTZweCkpOwogICAgICAgICAgICBwYWRkaW5nOiA2cHggMTBweDsKICAgICAgICAgICAgYm9yZGVyLXJh
ZGl1czogOHB4OwogICAgICAgICAgICBiYWNrZ3JvdW5kOiByZ2JhKDMyLDM2LDQ4LC45Mik7IGNvbG9y
OiAjZmZmOwogICAgICAgICAgICBmb250LXNpemU6IDEycHg7IGxpbmUtaGVpZ2h0OiAxLjM1OwogICAg
ICAgICAgICBib3gtc2hhZG93OiAwIDZweCAxOHB4IHJnYmEoMCwwLDAsLjIyKTsKICAgICAgICAgICAg
cG9pbnRlci1ldmVudHM6IG5vbmU7CiAgICAgICAgICAgIG9wYWNpdHk6IDA7IHRyYW5zZm9ybTogdHJh
bnNsYXRlWSg0cHgpOwogICAgICAgICAgICB0cmFuc2l0aW9uOiBvcGFjaXR5IC4ycyBlYXNlLCB0cmFu
c2Zvcm0gLjIycyBjdWJpYy1iZXppZXIoLjIyLDEsLjM2LDEpOwogICAgICAgICAgICB3b3JkLWJyZWFr
OiBicmVhay13b3JkOwogICAgICAgIH0KICAgICAgICAjc3JjLXRpcC5zaG93IHsgb3BhY2l0eTogMTsg
dHJhbnNmb3JtOiB0cmFuc2xhdGVZKDApOyB9CiAgICAgICAgLmktc3JjLWljbyB7CiAgICAgICAgICAg
IHdpZHRoOiAxNHB4OyBoZWlnaHQ6IDE0cHg7IGZsZXgtc2hyaW5rOiAwOwogICAgICAgICAgICBib3Jk
ZXItcmFkaXVzOiAycHg7IG9iamVjdC1maXQ6IGNvbnRhaW47CiAgICAgICAgICAgIGRpc3BsYXk6IGJs
b2NrOwogICAgICAgIH0KICAgICAgICAuaS1udW0gewogICAgICAgICAgICBkaXNwbGF5OiBmbGV4OyBm
bGV4LWRpcmVjdGlvbjogY29sdW1uOyBhbGlnbi1pdGVtczogZmxleC1lbmQ7CiAgICAgICAgICAgIGp1
c3RpZnktY29udGVudDogc3BhY2UtYmV0d2VlbjsKICAgICAgICAgICAgYWxpZ24tc2VsZjogc3RyZXRj
aDsKICAgICAgICAgICAgZm9udC1zaXplOiAxMHB4OyBjb2xvcjogdmFyKC0tdHh0Myk7IG1pbi13aWR0
aDogMTZweDsKICAgICAgICAgICAgdGV4dC1hbGlnbjogcmlnaHQ7IGZsZXgtc2hyaW5rOiAwOwogICAg
ICAgICAgICBwYWRkaW5nLXRvcDogMnB4OwogICAgICAgIH0KICAgICAgICAuaS1udW0gLmktc3JjLWlj
byB7IHdpZHRoOiAxNnB4OyBoZWlnaHQ6IDE2cHg7IG1hcmdpbi10b3A6IGF1dG87IH0KCiAgICAgICAg
LmktZXhwYW5kLWJ0biB7CiAgICAgICAgICAgIGJvcmRlcjogbm9uZTsgYmFja2dyb3VuZDogbm9uZTsg
Y3Vyc29yOiBwb2ludGVyOwogICAgICAgICAgICBjb2xvcjogdmFyKC0tdHh0Myk7IGZvbnQtc2l6ZTog
MTJweDsgcGFkZGluZzogM3B4IDEwcHg7CiAgICAgICAgICAgIGJvcmRlci1yYWRpdXM6IDhweDsgZGlz
cGxheTogbm9uZTsgYWxpZ24taXRlbXM6IGNlbnRlcjsgZ2FwOiA0cHg7CiAgICAgICAgICAgIHRyYW5z
aXRpb246IGNvbG9yIHZhcigtLXRyKSwgYmFja2dyb3VuZCB2YXIoLS10cik7CiAgICAgICAgICAgIC13
ZWJraXQtYXBwLXJlZ2lvbjogbm8tZHJhZzsgYXBwLXJlZ2lvbjogbm8tZHJhZzsKICAgICAgICAgICAg
bGluZS1oZWlnaHQ6IDEuMjsKICAgICAgICB9CiAgICAgICAgLmktZXhwYW5kLWJ0biBzdmcgeyB3aWR0
aDogMTRweDsgaGVpZ2h0OiAxNHB4OyBmbGV4LXNocmluazogMDsgfQogICAgICAgIC5pLWV4cGFuZC1i
dG4ub24geyBkaXNwbGF5OiBpbmxpbmUtZmxleDsgfQogICAgICAgIC5pLWV4cGFuZC1idG46aG92ZXIg
eyBjb2xvcjogdmFyKC0tYWNjKTsgYmFja2dyb3VuZDogcmdiYSg5MSwxMTUsMjMyLC4wOCk7IH0KICAg
ICAgICAuaS1wcmV2LmV4cGFuZGVkLCAuaS1uYW1lLmV4cGFuZGVkIHsKICAgICAgICAgICAgLXdlYmtp
dC1saW5lLWNsYW1wOiB1bnNldDsKICAgICAgICAgICAgZGlzcGxheTogYmxvY2s7CiAgICAgICAgICAg
IG92ZXJmbG93OiBoaWRkZW47CiAgICAgICAgICAgIC8qIOmrmOW6pueUsSBKUyDmjInliJfooajlj6/o
p4bljLrorr7lrprvvJrnuqbljaDmlbTooajlsJHkuIDooYwgKi8KICAgICAgICB9CiAgICAgICAgLmkt
c3JjLXRpdGxlIHsgZGlzcGxheTogbm9uZSAhaW1wb3J0YW50OyB9CiAgICAgICAgLmktZmlsZS1kZXRh
aWwgewogICAgICAgICAgICBkaXNwbGF5OiBub25lOwogICAgICAgICAgICBtYXJnaW4tdG9wOiA0cHg7
CiAgICAgICAgICAgIHBhZGRpbmc6IDA7CiAgICAgICAgICAgIGJhY2tncm91bmQ6IG5vbmU7CiAgICAg
ICAgICAgIGJvcmRlcjogbm9uZTsKICAgICAgICB9CiAgICAgICAgLmktZmlsZS1kZXRhaWwub24geyBk
aXNwbGF5OiBibG9jazsgfQogICAgICAgIC5mZC1ibG9jayB7CiAgICAgICAgICAgIGRpc3BsYXk6IGZs
ZXg7IGZsZXgtZGlyZWN0aW9uOiBjb2x1bW47IGdhcDogNnB4OwogICAgICAgIH0KICAgICAgICAuZmQt
YmxvY2sgKyAuZmQtYmxvY2sgeyBtYXJnaW4tdG9wOiA4cHg7IH0KICAgICAgICAuZmQtcGF0aCB7CiAg
ICAgICAgICAgIHdpZHRoOiAxMDAlOwogICAgICAgICAgICBmb250OiA2MDAgMTJweC8xLjU1ICdTZWdv
ZSBVSSBWYXJpYWJsZSBUZXh0JywnU2Vnb2UgVUknLCdNaWNyb3NvZnQgWWFIZWkgVUknLHNhbnMtc2Vy
aWY7CiAgICAgICAgICAgIGNvbG9yOiB2YXIoLS10eHQyKTsKICAgICAgICAgICAgbGV0dGVyLXNwYWNp
bmc6IC4wMWVtOwogICAgICAgICAgICB3b3JkLWJyZWFrOiBicmVhay1hbGw7CiAgICAgICAgICAgIHVz
ZXItc2VsZWN0OiB0ZXh0OwogICAgICAgICAgICAtd2Via2l0LWFwcC1yZWdpb246IG5vLWRyYWc7IGFw
cC1yZWdpb246IG5vLWRyYWc7CiAgICAgICAgfQogICAgICAgIC5mZC1wYXRoLmxpdmUgeyBjdXJzb3I6
IHBvaW50ZXI7IH0KICAgICAgICAuZmQtcGF0aC5saXZlOmhvdmVyIHsgY29sb3I6IHZhcigtLWFjYyk7
IH0KICAgICAgICAuZmQtcGF0aC5kZWFkIHsKICAgICAgICAgICAgY29sb3I6ICM5YWEwYjA7CiAgICAg
ICAgICAgIHRleHQtZGVjb3JhdGlvbjogbGluZS10aHJvdWdoOwogICAgICAgICAgICB0ZXh0LWRlY29y
YXRpb24tdGhpY2tuZXNzOiAycHg7CiAgICAgICAgICAgIHRleHQtZGVjb3JhdGlvbi1jb2xvcjogcmdi
YSgxNTQsIDE2MCwgMTc2LCAuNTUpOwogICAgICAgICAgICB0ZXh0LWRlY29yYXRpb24tc2tpcC1pbms6
IG5vbmU7CiAgICAgICAgICAgIGN1cnNvcjogZGVmYXVsdDsKICAgICAgICB9CiAgICAgICAgLmZkLWFj
dGlvbnMgewogICAgICAgICAgICBkaXNwbGF5OiBmbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBqdXN0
aWZ5LWNvbnRlbnQ6IGZsZXgtZW5kOwogICAgICAgICAgICBnYXA6IDhweDsgZmxleC13cmFwOiB3cmFw
OwogICAgICAgIH0KICAgICAgICAuZmQtYnRuIHsKICAgICAgICAgICAgYm9yZGVyOiBub25lOyBiYWNr
Z3JvdW5kOiBub25lOyBjdXJzb3I6IHBvaW50ZXI7CiAgICAgICAgICAgIGNvbG9yOiB2YXIoLS10eHQz
KTsgZm9udC1zaXplOiAxMHB4OyBmb250LXdlaWdodDogNjAwOwogICAgICAgICAgICBwYWRkaW5nOiAx
cHggMnB4OyBkaXNwbGF5OiBpbmxpbmUtZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsgZ2FwOiAycHg7
CiAgICAgICAgICAgIHdoaXRlLXNwYWNlOiBub3dyYXA7CiAgICAgICAgICAgIC13ZWJraXQtYXBwLXJl
Z2lvbjogbm8tZHJhZzsgYXBwLXJlZ2lvbjogbm8tZHJhZzsKICAgICAgICAgICAgdHJhbnNpdGlvbjog
Y29sb3IgdmFyKC0tdHIpOwogICAgICAgIH0KICAgICAgICAuZmQtYnRuOmhvdmVyIHsgY29sb3I6IHZh
cigtLWFjYyk7IH0KICAgICAgICAuZmQtYnRuLm9rIHsgY29sb3I6ICMxZjdhNTU7IH0KCiAgICAgICAg
Lyog4pSA4pSAIENvbnRleHQgbWVudSDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDi
lIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIAg
Ki8KICAgICAgICAjY3R4IHsKICAgICAgICAgICAgcG9zaXRpb246IGZpeGVkOyB6LWluZGV4OiA5OTk5
OyBtaW4td2lkdGg6IDEzMnB4OyBkaXNwbGF5OiBub25lOyBwYWRkaW5nOiA0cHg7CiAgICAgICAgICAg
IGJhY2tncm91bmQ6ICNmZmY7IGJvcmRlci1yYWRpdXM6IHZhcigtLXIpOyBib3gtc2hhZG93OiAwIDZw
eCAxNnB4IHJnYmEoMCwwLDAsLjE0KTsKICAgICAgICAgICAgLXdlYmtpdC1hcHAtcmVnaW9uOiBuby1k
cmFnOyBhcHAtcmVnaW9uOiBuby1kcmFnOwogICAgICAgIH0KICAgICAgICAjY3R4Lm9uIHsgZGlzcGxh
eTogYmxvY2s7IH0KICAgICAgICAuYy1pdGVtIHsKICAgICAgICAgICAgZGlzcGxheTogZmxleDsgYWxp
Z24taXRlbXM6IGNlbnRlcjsgZ2FwOiA3cHg7IHBhZGRpbmc6IDZweCA5cHg7CiAgICAgICAgICAgIGJv
cmRlci1yYWRpdXM6IHZhcigtLXIpOyBjdXJzb3I6IHBvaW50ZXI7IGZvbnQtc2l6ZTogMTFweDsgY29s
b3I6IHZhcigtLXR4dCk7CiAgICAgICAgfQogICAgICAgIC5jLWl0ZW06aG92ZXIgeyBiYWNrZ3JvdW5k
OiAjZjJmNGY5OyB9CiAgICAgICAgLmMtaXRlbS5kYW5nZXIgeyBjb2xvcjogI2ZmN2I5YzsgfQogICAg
ICAgIC5jLXNlcCB7IGhlaWdodDogMXB4OyBiYWNrZ3JvdW5kOiAjZWNlZmY1OyBtYXJnaW46IDNweCAw
OyB9CiAgICAgICAgLmMtaWNvIHsgd2lkdGg6IDE0cHg7IHRleHQtYWxpZ246IGNlbnRlcjsgfQoKICAg
ICAgICAvKiDilIDilIAgQ2xlYXIgY29uZmlybSDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDi
lIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDi
lIAgKi8KICAgICAgICAjY2xyLWRsZyB7CiAgICAgICAgICAgIGRpc3BsYXk6IG5vbmU7IHBvc2l0aW9u
OiBmaXhlZDsgaW5zZXQ6IDA7IHotaW5kZXg6IDEwMDAwOwogICAgICAgICAgICBiYWNrZ3JvdW5kOiBy
Z2JhKDIwLCAyMiwgMzUsIC40Mik7CiAgICAgICAgICAgIGFsaWduLWl0ZW1zOiBjZW50ZXI7IGp1c3Rp
ZnktY29udGVudDogY2VudGVyOwogICAgICAgICAgICAtd2Via2l0LWFwcC1yZWdpb246IG5vLWRyYWc7
IGFwcC1yZWdpb246IG5vLWRyYWc7CiAgICAgICAgfQogICAgICAgICNjbHItZGxnLm9uIHsgZGlzcGxh
eTogZmxleDsgfQogICAgICAgIC5jbHItYm94IHsKICAgICAgICAgICAgd2lkdGg6IG1pbigyODBweCwg
Y2FsYygxMDAlIC0gMzJweCkpOwogICAgICAgICAgICBiYWNrZ3JvdW5kOiAjZmZmOyBib3JkZXItcmFk
aXVzOiAxMnB4OwogICAgICAgICAgICBib3gtc2hhZG93OiAwIDEycHggMzJweCByZ2JhKDAsMCwwLC4x
OCk7CiAgICAgICAgICAgIHBhZGRpbmc6IDE2cHggMTZweCAxNHB4OyBjb2xvcjogdmFyKC0tdHh0KTsK
ICAgICAgICB9CiAgICAgICAgLmNsci10aXRsZSB7IGZvbnQtc2l6ZTogMTRweDsgZm9udC13ZWlnaHQ6
IDcwMDsgbWFyZ2luLWJvdHRvbTogNnB4OyB9CiAgICAgICAgLmNsci1kZXNjIHsgZm9udC1zaXplOiAx
MXB4OyBjb2xvcjogdmFyKC0tdHh0Myk7IGxpbmUtaGVpZ2h0OiAxLjU7IG1hcmdpbi1ib3R0b206IDEy
cHg7IH0KICAgICAgICAuY2xyLWNoZWNrIHsKICAgICAgICAgICAgZGlzcGxheTogZmxleDsgYWxpZ24t
aXRlbXM6IGNlbnRlcjsgZ2FwOiA3cHg7CiAgICAgICAgICAgIGZvbnQtc2l6ZTogMTJweDsgY29sb3I6
IHZhcigtLXR4dCk7IGN1cnNvcjogcG9pbnRlcjsKICAgICAgICAgICAgdXNlci1zZWxlY3Q6IG5vbmU7
IG1hcmdpbi1ib3R0b206IDE0cHg7CiAgICAgICAgfQogICAgICAgIC5jbHItY2hlY2sgaW5wdXQgewog
ICAgICAgICAgICB3aWR0aDogMTRweDsgaGVpZ2h0OiAxNHB4OyBhY2NlbnQtY29sb3I6IHZhcigtLWFj
Yyk7IGN1cnNvcjogcG9pbnRlcjsKICAgICAgICB9CiAgICAgICAgLmNsci1idG5zIHsgZGlzcGxheTog
ZmxleDsgZ2FwOiA4cHg7IGp1c3RpZnktY29udGVudDogZmxleC1lbmQ7IH0KICAgICAgICAuY2xyLWJ0
bnMgYnV0dG9uIHsKICAgICAgICAgICAgYm9yZGVyOiBub25lOyBib3JkZXItcmFkaXVzOiA4cHg7IHBh
ZGRpbmc6IDdweCAxNHB4OwogICAgICAgICAgICBmb250LXNpemU6IDEycHg7IGN1cnNvcjogcG9pbnRl
cjsgZm9udC13ZWlnaHQ6IDYwMDsKICAgICAgICAgICAgdHJhbnNpdGlvbjogYmFja2dyb3VuZCB2YXIo
LS10ciksIGNvbG9yIHZhcigtLXRyKTsKICAgICAgICB9CiAgICAgICAgI2Nsci1jYW5jZWwgeyBiYWNr
Z3JvdW5kOiAjZjFmM2Y4OyBjb2xvcjogdmFyKC0tdHh0Mik7IH0KICAgICAgICAjY2xyLWNhbmNlbDpo
b3ZlciB7IGJhY2tncm91bmQ6ICNlNmU5ZjI7IH0KICAgICAgICAjY2xyLW9rIHsgYmFja2dyb3VuZDog
cmdiYSgyNTUsMTIzLDE1NiwuMTQpOyBjb2xvcjogI2U4NWE3YTsgfQogICAgICAgICNjbHItb2s6aG92
ZXIgeyBiYWNrZ3JvdW5kOiByZ2JhKDI1NSwxMjMsMTU2LC4yNCk7IH0KCiAgICAgICAgLyog4pSA4pSA
IEZpbGUgcGF0aCB0aXAg4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA
4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSAICovCiAgICAgICAg
I3BhdGgtdGlwIHsKICAgICAgICAgICAgZGlzcGxheTogbm9uZTsgcG9zaXRpb246IGZpeGVkOyB6LWlu
ZGV4OiAxMDAwMTsKICAgICAgICAgICAgd2lkdGg6IG1pbigzMjBweCwgY2FsYygxMDB2dyAtIDE2cHgp
KTsKICAgICAgICAgICAgbWF4LWhlaWdodDogbWluKDI4MHB4LCBjYWxjKDEwMHZoIC0gMjRweCkpOwog
ICAgICAgICAgICBvdmVyZmxvdzogYXV0bzsKICAgICAgICAgICAgcGFkZGluZzogMDsKICAgICAgICAg
ICAgYmFja2dyb3VuZDogbGluZWFyLWdyYWRpZW50KDE2NWRlZywgI2ZmZmZmZiAwJSwgI2Y2ZjhmYyAx
MDAlKTsKICAgICAgICAgICAgYm9yZGVyOiAxcHggc29saWQgcmdiYSg3MCwgODQsIDEyMCwgLjEpOwog
ICAgICAgICAgICBib3JkZXItcmFkaXVzOiAxMnB4OwogICAgICAgICAgICBib3gtc2hhZG93OgogICAg
ICAgICAgICAgICAgMCA0cHggNnB4IHJnYmEoMzAsIDQwLCA3MCwgLjA0KSwKICAgICAgICAgICAgICAg
IDAgMTRweCAzNnB4IHJnYmEoMzAsIDQwLCA3MCwgLjE2KTsKICAgICAgICAgICAgY29sb3I6IHZhcigt
LXR4dCk7CiAgICAgICAgICAgIHBvaW50ZXItZXZlbnRzOiBhdXRvOwogICAgICAgICAgICBvcGFjaXR5
OiAwOwogICAgICAgICAgICB0cmFuc2Zvcm06IHRyYW5zbGF0ZVkoNHB4KSBzY2FsZSguOTgpOwogICAg
ICAgICAgICB0cmFuc2l0aW9uOiBvcGFjaXR5IC4xNHMgZWFzZSwgdHJhbnNmb3JtIC4xNHMgZWFzZTsK
ICAgICAgICAgICAgLXdlYmtpdC1hcHAtcmVnaW9uOiBuby1kcmFnOyBhcHAtcmVnaW9uOiBuby1kcmFn
OwogICAgICAgIH0KICAgICAgICAjcGF0aC10aXAub24gewogICAgICAgICAgICBkaXNwbGF5OiBibG9j
azsKICAgICAgICAgICAgb3BhY2l0eTogMTsKICAgICAgICAgICAgdHJhbnNmb3JtOiB0cmFuc2xhdGVZ
KDApIHNjYWxlKDEpOwogICAgICAgIH0KICAgICAgICAucHQtaGVhZCB7CiAgICAgICAgICAgIGRpc3Bs
YXk6IGZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGp1c3RpZnktY29udGVudDogc3BhY2UtYmV0d2Vl
bjsKICAgICAgICAgICAgZ2FwOiAxMHB4OyBwYWRkaW5nOiAxMHB4IDEycHggOHB4OwogICAgICAgICAg
ICBib3JkZXItYm90dG9tOiAxcHggc29saWQgcmdiYSg3MCwgODQsIDEyMCwgLjA3KTsKICAgICAgICB9
CiAgICAgICAgLnB0LXRpdGxlIHsKICAgICAgICAgICAgZm9udC1zaXplOiAxMXB4OyBmb250LXdlaWdo
dDogNzAwOyBsZXR0ZXItc3BhY2luZzogLjA0ZW07CiAgICAgICAgICAgIGNvbG9yOiB2YXIoLS10eHQy
KTsgdGV4dC10cmFuc2Zvcm06IHVwcGVyY2FzZTsKICAgICAgICAgICAgZmxleC1zaHJpbms6IDA7CiAg
ICAgICAgfQogICAgICAgIC5wdC1oZWFkLWJ0biB7CiAgICAgICAgICAgIGZsZXgtc2hyaW5rOiAwOyBt
YXJnaW4tbGVmdDogYXV0bzsKICAgICAgICAgICAgaGVpZ2h0OiAyMnB4OyBwYWRkaW5nOiAwIDhweDsg
ZGlzcGxheTogaW5saW5lLWZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGdhcDogNHB4OwogICAgICAg
ICAgICBib3JkZXI6IDFweCBzb2xpZCByZ2JhKDEwNywxMTIsMTI4LC4yMik7IGJvcmRlci1yYWRpdXM6
IDZweDsgY3Vyc29yOiBwb2ludGVyOwogICAgICAgICAgICBiYWNrZ3JvdW5kOiByZ2JhKDEwNywxMTIs
MTI4LC4wNik7IGNvbG9yOiAjOGE5MGEwOyBmb250LXNpemU6IDExcHg7IGZvbnQtd2VpZ2h0OiA2MDA7
CiAgICAgICAgICAgIHdoaXRlLXNwYWNlOiBub3dyYXA7CiAgICAgICAgICAgIC13ZWJraXQtYXBwLXJl
Z2lvbjogbm8tZHJhZzsgYXBwLXJlZ2lvbjogbm8tZHJhZzsKICAgICAgICAgICAgdHJhbnNpdGlvbjog
YmFja2dyb3VuZCB2YXIoLS10ciksIGNvbG9yIHZhcigtLXRyKSwgYm9yZGVyLWNvbG9yIHZhcigtLXRy
KTsKICAgICAgICB9CiAgICAgICAgLnB0LWhlYWQtYnRuOmhvdmVyIHsKICAgICAgICAgICAgYmFja2dy
b3VuZDogcmdiYSgxMDcsMTEyLDEyOCwuMTIpOyBjb2xvcjogdmFyKC0tdHh0Mik7CiAgICAgICAgICAg
IGJvcmRlci1jb2xvcjogcmdiYSgxMDcsMTEyLDEyOCwuNCk7CiAgICAgICAgfQogICAgICAgIC5wdC1s
aXN0IHsgcGFkZGluZzogNnB4IDhweCA4cHg7IGRpc3BsYXk6IGZsZXg7IGZsZXgtZGlyZWN0aW9uOiBj
b2x1bW47IGdhcDogNHB4OyB9CiAgICAgICAgLnB0LXJvdyB7CiAgICAgICAgICAgIGRpc3BsYXk6IGdy
aWQ7IGdyaWQtdGVtcGxhdGUtY29sdW1uczogOHB4IDFmcjsgZ2FwOiA4cHg7CiAgICAgICAgICAgIHBh
ZGRpbmc6IDhweCA4cHg7IGJvcmRlci1yYWRpdXM6IDhweDsKICAgICAgICAgICAgYmFja2dyb3VuZDog
cmdiYSgyNTUsMjU1LDI1NSwuNyk7CiAgICAgICAgfQogICAgICAgIC5wdC1yb3cuZGVhZCB7IGJhY2tn
cm91bmQ6IHJnYmEoMjU1LCAxMjMsIDE1NiwgLjA2KTsgfQogICAgICAgIC5wdC1kb3QgewogICAgICAg
ICAgICB3aWR0aDogOHB4OyBoZWlnaHQ6IDhweDsgYm9yZGVyLXJhZGl1czogNTAlOyBtYXJnaW4tdG9w
OiA1cHg7CiAgICAgICAgICAgIGJhY2tncm91bmQ6ICMyZWI0Nzg7IGJveC1zaGFkb3c6IDAgMCAwIDNw
eCByZ2JhKDQ2LCAxODAsIDEyMCwgLjE4KTsKICAgICAgICB9CiAgICAgICAgLnB0LXJvdy5kZWFkIC5w
dC1kb3QgewogICAgICAgICAgICBiYWNrZ3JvdW5kOiAjZTg1YTdhOyBib3gtc2hhZG93OiAwIDAgMCAz
cHggcmdiYSgyMzIsIDkwLCAxMjIsIC4xNik7CiAgICAgICAgfQogICAgICAgIC5wdC1uYW1lIHsKICAg
ICAgICAgICAgZm9udC1zaXplOiAxMnB4OyBmb250LXdlaWdodDogNjUwOyBjb2xvcjogdmFyKC0tdHh0
KTsKICAgICAgICAgICAgbGluZS1oZWlnaHQ6IDEuMzsgd29yZC1icmVhazogYnJlYWstYWxsOwogICAg
ICAgIH0KICAgICAgICAucHQtcGF0aCB7CiAgICAgICAgICAgIG1hcmdpbi10b3A6IDNweDsKICAgICAg
ICAgICAgZm9udDogMTAuNXB4LzEuNDUgJ0Nhc2NhZGlhIE1vbm8nLCdDb25zb2xhcycsJ01pY3Jvc29m
dCBZYUhlaSBVSScsbW9ub3NwYWNlOwogICAgICAgICAgICBjb2xvcjogdmFyKC0tdHh0Mik7IHdvcmQt
YnJlYWs6IGJyZWFrLWFsbDsKICAgICAgICAgICAgdXNlci1zZWxlY3Q6IHRleHQ7CiAgICAgICAgfQog
ICAgICAgIC5wdC1wYXRoLmxpdmUgewogICAgICAgICAgICBjb2xvcjogdmFyKC0tYWNjKTsgY3Vyc29y
OiBwb2ludGVyOwogICAgICAgIH0KICAgICAgICAucHQtcGF0aC5saXZlOmhvdmVyIHsgdGV4dC1kZWNv
cmF0aW9uOiB1bmRlcmxpbmU7IH0KICAgICAgICAucHQtcGF0aC5kZWFkIHsKICAgICAgICAgICAgY29s
b3I6ICNjNDNkNWM7CiAgICAgICAgICAgIHRleHQtZGVjb3JhdGlvbjogbGluZS10aHJvdWdoOwogICAg
ICAgICAgICB0ZXh0LWRlY29yYXRpb24tdGhpY2tuZXNzOiAycHg7CiAgICAgICAgICAgIHRleHQtZGVj
b3JhdGlvbi1jb2xvcjogI2UxMWQ0ODsKICAgICAgICAgICAgY3Vyc29yOiBkZWZhdWx0OwogICAgICAg
IH0KICAgICAgICAucHQtYWN0aW9ucyB7CiAgICAgICAgICAgIG1hcmdpbi10b3A6IDZweDsKICAgICAg
ICAgICAgZGlzcGxheTogZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsgZ2FwOiA2cHg7IGZsZXgtd3Jh
cDogd3JhcDsKICAgICAgICB9CiAgICAgICAgLnB0LWNvcHktYnRuIHsKICAgICAgICAgICAgaGVpZ2h0
OiAyMnB4OyBwYWRkaW5nOiAwIDhweDsgZGlzcGxheTogaW5saW5lLWZsZXg7IGFsaWduLWl0ZW1zOiBj
ZW50ZXI7CiAgICAgICAgICAgIGJvcmRlcjogMXB4IHNvbGlkIHJnYmEoMTA3LDExMiwxMjgsLjIyKTsg
Ym9yZGVyLXJhZGl1czogNnB4OyBjdXJzb3I6IHBvaW50ZXI7CiAgICAgICAgICAgIGJhY2tncm91bmQ6
IHJnYmEoMTA3LDExMiwxMjgsLjA2KTsgY29sb3I6ICM4YTkwYTA7IGZvbnQtc2l6ZTogMTFweDsgZm9u
dC13ZWlnaHQ6IDYwMDsKICAgICAgICAgICAgLXdlYmtpdC1hcHAtcmVnaW9uOiBuby1kcmFnOyBhcHAt
cmVnaW9uOiBuby1kcmFnOwogICAgICAgICAgICB0cmFuc2l0aW9uOiBiYWNrZ3JvdW5kIHZhcigtLXRy
KSwgY29sb3IgdmFyKC0tdHIpLCBib3JkZXItY29sb3IgdmFyKC0tdHIpOwogICAgICAgIH0KICAgICAg
ICAucHQtY29weS1idG46aG92ZXIgewogICAgICAgICAgICBiYWNrZ3JvdW5kOiByZ2JhKDEwNywxMTIs
MTI4LC4xMik7IGNvbG9yOiB2YXIoLS10eHQyKTsKICAgICAgICAgICAgYm9yZGVyLWNvbG9yOiByZ2Jh
KDEwNywxMTIsMTI4LC40KTsKICAgICAgICB9CiAgICAgICAgLnB0LWNvcHktYnRuLm9rIHsKICAgICAg
ICAgICAgY29sb3I6ICMxZjdhNTU7IGJvcmRlci1jb2xvcjogcmdiYSg0NiwgMTgwLCAxMjAsIC4zNSk7
CiAgICAgICAgICAgIGJhY2tncm91bmQ6IHJnYmEoNDYsIDE4MCwgMTIwLCAuMSk7CiAgICAgICAgfQog
ICAgICAgIC5pdG0uaXQtZ3JvdXAgewogICAgICAgICAgICBmbGV4LWRpcmVjdGlvbjogY29sdW1uOwog
ICAgICAgICAgICBhbGlnbi1pdGVtczogc3RyZXRjaDsKICAgICAgICAgICAgZ2FwOiAwOwogICAgICAg
ICAgICBwYWRkaW5nOiA2cHggOHB4IDRweDsKICAgICAgICAgICAgY3Vyc29yOiBkZWZhdWx0OwogICAg
ICAgIH0KICAgICAgICAuaXRtLml0LWdyb3VwOmhvdmVyIHsgYmFja2dyb3VuZDogdmFyKC0tY2FyZCk7
IH0KICAgICAgICAubWctaGVhZCB7CiAgICAgICAgICAgIGRpc3BsYXk6IGZsZXg7IGFsaWduLWl0ZW1z
OiBjZW50ZXI7IGdhcDogNnB4OwogICAgICAgICAgICBmb250LXNpemU6IDExcHg7IGNvbG9yOiB2YXIo
LS10eHQzKTsgZm9udC13ZWlnaHQ6IDYwMDsKICAgICAgICAgICAgcGFkZGluZzogMnB4IDJweCA2cHg7
IHVzZXItc2VsZWN0OiBub25lOwogICAgICAgIH0KICAgICAgICAubWctaGVhZCAubWctdGFnIHsKICAg
ICAgICAgICAgZGlzcGxheTogaW5saW5lLWZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7CiAgICAgICAg
ICAgIGhlaWdodDogMTZweDsgcGFkZGluZzogMCA2cHg7IGJvcmRlci1yYWRpdXM6IDhweDsKICAgICAg
ICAgICAgYmFja2dyb3VuZDogcmdiYSg5MSwxMTUsMjMyLC4xMik7IGNvbG9yOiB2YXIoLS1hY2MpOyBm
b250LXNpemU6IDEwcHg7CiAgICAgICAgfQogICAgICAgIC5tZy1yb3cgewogICAgICAgICAgICBwYWRk
aW5nOiA3cHggNnB4OyBtYXJnaW4tYm90dG9tOiAzcHg7CiAgICAgICAgICAgIGJvcmRlci1yYWRpdXM6
IDVweDsgY3Vyc29yOiBwb2ludGVyOwogICAgICAgICAgICBib3JkZXI6IDFweCBzb2xpZCB0cmFuc3Bh
cmVudDsKICAgICAgICAgICAgdHJhbnNpdGlvbjogYmFja2dyb3VuZCAuMTJzIGVhc2UsIGJvcmRlci1j
b2xvciAuMTJzIGVhc2U7CiAgICAgICAgfQogICAgICAgIC5tZy1yb3c6aG92ZXIgeyBiYWNrZ3JvdW5k
OiB2YXIoLS1jYXJkLWgpOyB9CiAgICAgICAgLm1nLXJvdy5zZWwgewogICAgICAgICAgICBiYWNrZ3Jv
dW5kOiAjZWRmMWZmOwogICAgICAgICAgICBib3JkZXItY29sb3I6IHJnYmEoOTEsMTE1LDIzMiwuMzUp
OwogICAgICAgICAgICBib3gtc2hhZG93OiAwIDAgMCAxcHggcmdiYSg5MSwxMTUsMjMyLC4yNSk7CiAg
ICAgICAgfQogICAgICAgIC5tZy1yb3cubXVsdGkgewogICAgICAgICAgICBiYWNrZ3JvdW5kOiAjZWVm
MmZmOwogICAgICAgICAgICBib3JkZXItY29sb3I6IHJnYmEoOTEsMTE1LDIzMiwuNDUpOwogICAgICAg
IH0KICAgICAgICAubWctdGl0bGUgewogICAgICAgICAgICBmb250LXNpemU6IDEzcHg7IGZvbnQtd2Vp
Z2h0OiA2MDA7IGNvbG9yOiB2YXIoLS1hY2MpOwogICAgICAgICAgICBtYXJnaW4tYm90dG9tOiAycHg7
IGxpbmUtaGVpZ2h0OiAxLjM1OwogICAgICAgICAgICBkaXNwbGF5OiAtd2Via2l0LWJveDsgLXdlYmtp
dC1ib3gtb3JpZW50OiB2ZXJ0aWNhbDsgLXdlYmtpdC1saW5lLWNsYW1wOiAyOwogICAgICAgICAgICBv
dmVyZmxvdzogaGlkZGVuOyB3b3JkLWJyZWFrOiBicmVhay13b3JkOwogICAgICAgIH0KICAgICAgICAu
bWctYm9keSB7CiAgICAgICAgICAgIGZvbnQtc2l6ZTogMTIuNXB4OyBmb250LXdlaWdodDogNTAwOyBj
b2xvcjogdmFyKC0tdHh0KTsKICAgICAgICAgICAgd2hpdGUtc3BhY2U6IHByZS13cmFwOyB3b3JkLWJy
ZWFrOiBicmVhay1hbGw7CiAgICAgICAgICAgIGRpc3BsYXk6IC13ZWJraXQtYm94OyAtd2Via2l0LWJv
eC1vcmllbnQ6IHZlcnRpY2FsOyAtd2Via2l0LWxpbmUtY2xhbXA6IDQ7CiAgICAgICAgICAgIG92ZXJm
bG93OiBoaWRkZW47IGxpbmUtaGVpZ2h0OiAxLjQ7CiAgICAgICAgfQogICAgICAgIC5tZy1ib2R5Lmlt
ZyB7IGNvbG9yOiB2YXIoLS10eHQyKTsgfQogICAgICAgIC5tZy1yb3ctdG9wIHsKICAgICAgICAgICAg
ZGlzcGxheTogZmxleDsgYWxpZ24taXRlbXM6IGZsZXgtc3RhcnQ7IGdhcDogOHB4OwogICAgICAgIH0K
ICAgICAgICAubWctcm93LW1haW4geyBmbGV4OiAxOyBtaW4td2lkdGg6IDA7IH0KICAgICAgICAubWct
c3JjIHsKICAgICAgICAgICAgd2lkdGg6IDE4cHg7IGhlaWdodDogMThweDsgZmxleC1zaHJpbms6IDA7
IG1hcmdpbi10b3A6IDJweDsKICAgICAgICAgICAgYm9yZGVyLXJhZGl1czogM3B4OyBvYmplY3QtZml0
OiBjb250YWluOwogICAgICAgICAgICBiYWNrZ3JvdW5kOiByZ2JhKDAsMCwwLC4wNCk7CiAgICAgICAg
fQogICAgICAgIC5pLWZhdi10aXRsZSB7CiAgICAgICAgICAgIGZvbnQtc2l6ZTogMTNweDsgZm9udC13
ZWlnaHQ6IDYwMDsgY29sb3I6IHZhcigtLWFjYyk7CiAgICAgICAgICAgIG1hcmdpbjogMCAwIDNweDsg
bGluZS1oZWlnaHQ6IDEuMzU7CiAgICAgICAgICAgIGRpc3BsYXk6IC13ZWJraXQtYm94OyAtd2Via2l0
LWJveC1vcmllbnQ6IHZlcnRpY2FsOyAtd2Via2l0LWxpbmUtY2xhbXA6IDI7CiAgICAgICAgICAgIG92
ZXJmbG93OiBoaWRkZW47IHdvcmQtYnJlYWs6IGJyZWFrLXdvcmQ7CiAgICAgICAgfQogICAgICAgICN0
aXRsZS1kbGcgewogICAgICAgICAgICBkaXNwbGF5OiBub25lOyBwb3NpdGlvbjogZml4ZWQ7IGluc2V0
OiAwOyB6LWluZGV4OiAxMDA7CiAgICAgICAgICAgIGJhY2tncm91bmQ6IHJnYmEoMTUsMTgsMjgsLjM1
KTsKICAgICAgICAgICAgYWxpZ24taXRlbXM6IGNlbnRlcjsganVzdGlmeS1jb250ZW50OiBjZW50ZXI7
CiAgICAgICAgfQogICAgICAgICN0aXRsZS1kbGcub24geyBkaXNwbGF5OiBmbGV4OyB9CiAgICAgICAg
I3RpdGxlLWRsZyAudGl0bGUtYm94IHsKICAgICAgICAgICAgd2lkdGg6IDI2MHB4OyBwYWRkaW5nOiAx
NnB4IDE2cHggMTJweDsKICAgICAgICAgICAgYmFja2dyb3VuZDogdmFyKC0tY2FyZCk7IGJvcmRlci1y
YWRpdXM6IDEwcHg7CiAgICAgICAgICAgIGJveC1zaGFkb3c6IDAgOHB4IDI4cHggcmdiYSgwLDAsMCwu
MTgpOwogICAgICAgIH0KICAgICAgICAjdGl0bGUtaW5wdXQgewogICAgICAgICAgICB3aWR0aDogMTAw
JTsgYm94LXNpemluZzogYm9yZGVyLWJveDsgbWFyZ2luOiA4cHggMCAxMnB4OwogICAgICAgICAgICBo
ZWlnaHQ6IDMycHg7IHBhZGRpbmc6IDAgMTBweDsgYm9yZGVyLXJhZGl1czogNnB4OwogICAgICAgICAg
ICBib3JkZXI6IDFweCBzb2xpZCAjZDVkYWU2OyBiYWNrZ3JvdW5kOiAjZmZmOyBjb2xvcjogdmFyKC0t
dHh0KTsKICAgICAgICAgICAgZm9udC1zaXplOiAxM3B4OyBvdXRsaW5lOiBub25lOwogICAgICAgIH0K
ICAgICAgICAjdGl0bGUtaW5wdXQ6Zm9jdXMgeyBib3JkZXItY29sb3I6IHZhcigtLWFjYyk7IH0KCiAg
ICAKICAgICAgICAvKiB1aS1ncmF5LWJnLXYxICovCiAgICAgICAgOnJvb3QgewogICAgICAgICAgICAt
LWJnOiAjZTRlN2VlICFpbXBvcnRhbnQ7CiAgICAgICAgfQogICAgICAgIGh0bWwsIGJvZHkgewogICAg
ICAgICAgICBiYWNrZ3JvdW5kOiAjZTRlN2VlICFpbXBvcnRhbnQ7CiAgICAgICAgfQogICAgICAgICNh
cHAgewogICAgICAgICAgICBiYWNrZ3JvdW5kOiBsaW5lYXItZ3JhZGllbnQoMTgwZGVnLCAjZTllY2Yz
IDAlLCAjZTBlNGVjIDEwMCUpICFpbXBvcnRhbnQ7CiAgICAgICAgfQogICAgICAgICNoZHIgewogICAg
ICAgICAgICBiYWNrZ3JvdW5kOiAjZTJlNmVlICFpbXBvcnRhbnQ7CiAgICAgICAgfQogICAgICAgICN0
YWJzIHsKICAgICAgICAgICAgYmFja2dyb3VuZDogI2UyZTZlZSAhaW1wb3J0YW50OwogICAgICAgIH0K
ICAgICAgICAjbGlzdCwgI2VtcHR5LCAjc2tlbCwgI2hkci1ncm93LCAjc2VhcmNoLXdyYXAgewogICAg
ICAgICAgICBiYWNrZ3JvdW5kOiB0cmFuc3BhcmVudCAhaW1wb3J0YW50OwogICAgICAgIH0KICAgICAg
ICAjc2VhcmNoLWJveCB7CiAgICAgICAgICAgIHRyYW5zZm9ybS1vcmlnaW46IHJpZ2h0IGNlbnRlcjsK
ICAgICAgICAgICAgYmFja2dyb3VuZDogdHJhbnNwYXJlbnQgIWltcG9ydGFudDsKICAgICAgICB9CiAg
ICAgICAgLml0bSwgLm1nLCAubWctcm93LCAubWVyZ2UtZ3JvdXAgewogICAgICAgICAgICBiYWNrZ3Jv
dW5kOiAjZmZmZmZmICFpbXBvcnRhbnQ7CiAgICAgICAgfQogICAgICAgIC5pdG06aG92ZXIgewogICAg
ICAgICAgICBiYWNrZ3JvdW5kOiAjZjhmOWZjICFpbXBvcnRhbnQ7CiAgICAgICAgfQogICAgCiAgICAg
ICAgLyogc2VsLXRpbnQtYmx1ZS12MSAqLwogICAgICAgIC5pdG0uc2VsLAogICAgICAgIC5tZy1yb3cu
c2VsLAogICAgICAgIC5pdG0ubXVsdGksCiAgICAgICAgLm1nLXJvdy5tdWx0aSwKICAgICAgICAuaXRt
Lm11bHRpLnNlbCwKICAgICAgICAuaXQtZ3JvdXAuc2VsLAogICAgICAgIC5pdC1ncm91cC5tdWx0aSB7
CiAgICAgICAgICAgIGJhY2tncm91bmQ6ICNlOGVmZmYgIWltcG9ydGFudDsKICAgICAgICB9CiAgICAg
ICAgLml0bS5zZWw6aG92ZXIsCiAgICAgICAgLml0bS5tdWx0aTpob3ZlciwKICAgICAgICAubWctcm93
LnNlbDpob3ZlciwKICAgICAgICAubWctcm93Lm11bHRpOmhvdmVyIHsKICAgICAgICAgICAgYmFja2dy
b3VuZDogI2RkZTZmZiAhaW1wb3J0YW50OwogICAgICAgIH0KICAgIAogICAgICAgIC8qIGhvdmVyLWdy
ZWVuLXJpc2UtdjIgKi8KICAgICAgICAvKiBob3Zlci1hY2NlbnQtcmlzZS12MyAqLwogICAgICAgIC5p
dG0geyBwb3NpdGlvbjogcmVsYXRpdmUgIWltcG9ydGFudDsgb3ZlcmZsb3c6IGhpZGRlbiAhaW1wb3J0
YW50OyB9CiAgICAgICAgLml0bTo6YmVmb3JlIHsKICAgICAgICAgICAgY29udGVudDogIiIgIWltcG9y
dGFudDsKICAgICAgICAgICAgcG9zaXRpb246IGFic29sdXRlICFpbXBvcnRhbnQ7CiAgICAgICAgICAg
IGxlZnQ6IDAgIWltcG9ydGFudDsgcmlnaHQ6IDAgIWltcG9ydGFudDsgYm90dG9tOiAwICFpbXBvcnRh
bnQ7CiAgICAgICAgICAgIGhlaWdodDogMCAhaW1wb3J0YW50OwogICAgICAgICAgICBwb2ludGVyLWV2
ZW50czogbm9uZSAhaW1wb3J0YW50OwogICAgICAgICAgICB6LWluZGV4OiAwICFpbXBvcnRhbnQ7CiAg
ICAgICAgICAgIGJvcmRlci1yYWRpdXM6IDAgMCB2YXIoLS1yLCA0cHgpIHZhcigtLXIsIDRweCkgIWlt
cG9ydGFudDsKICAgICAgICAgICAgYmFja2dyb3VuZDogbGluZWFyLWdyYWRpZW50KHRvIHRvcCwKICAg
ICAgICAgICAgICAgIHJnYmEoOTEsIDExNSwgMjMyLCAuMzIpIDAlLAogICAgICAgICAgICAgICAgcmdi
YSg5MSwgMTE1LCAyMzIsIC4xMikgNTUlLAogICAgICAgICAgICAgICAgcmdiYSg5MSwgMTE1LCAyMzIs
IDApIDEwMCUpICFpbXBvcnRhbnQ7CiAgICAgICAgICAgIHRyYW5zaXRpb246IGhlaWdodCAuMzRzIGN1
YmljLWJlemllciguMjIsIDEsIC4zNiwgMSkgIWltcG9ydGFudDsKICAgICAgICB9CiAgICAgICAgLml0
bTpob3Zlcjo6YmVmb3JlIHsgaGVpZ2h0OiAzMy4zMzMlICFpbXBvcnRhbnQ7IH0KICAgICAgICAuaXRt
OjphZnRlciB7CiAgICAgICAgICAgIGNvbnRlbnQ6ICIiICFpbXBvcnRhbnQ7CiAgICAgICAgICAgIHBv
c2l0aW9uOiBhYnNvbHV0ZSAhaW1wb3J0YW50OwogICAgICAgICAgICBsZWZ0OiAwICFpbXBvcnRhbnQ7
IHJpZ2h0OiAwICFpbXBvcnRhbnQ7IGJvdHRvbTogMCAhaW1wb3J0YW50OwogICAgICAgICAgICBoZWln
aHQ6IDJweCAhaW1wb3J0YW50OwogICAgICAgICAgICBwb2ludGVyLWV2ZW50czogbm9uZSAhaW1wb3J0
YW50OwogICAgICAgICAgICB6LWluZGV4OiAxICFpbXBvcnRhbnQ7CiAgICAgICAgICAgIGJhY2tncm91
bmQ6IHJnYmEoOTEsIDExNSwgMjMyLCAuOTIpICFpbXBvcnRhbnQ7CiAgICAgICAgICAgIGJvcmRlci1y
YWRpdXM6IDFweCAhaW1wb3J0YW50OwogICAgICAgICAgICB0cmFuc2Zvcm06IHNjYWxlWCgwKSAhaW1w
b3J0YW50OwogICAgICAgICAgICB0cmFuc2Zvcm0tb3JpZ2luOiBjZW50ZXIgIWltcG9ydGFudDsKICAg
ICAgICAgICAgdHJhbnNpdGlvbjogdHJhbnNmb3JtIC4zcyBjdWJpYy1iZXppZXIoLjIyLCAxLCAuMzYs
IDEpICFpbXBvcnRhbnQ7CiAgICAgICAgfQogICAgICAgIC5pdG06aG92ZXI6OmFmdGVyIHsKICAgICAg
ICAgICAgdHJhbnNmb3JtOiBzY2FsZVgoMSkgIWltcG9ydGFudDsKICAgICAgICAgICAgYmFja2dyb3Vu
ZDogcmdiYSg5MSwgMTE1LCAyMzIsIC45NSkgIWltcG9ydGFudDsKICAgICAgICB9CiAgICAgICAgLml0
bSA+ICogeyBwb3NpdGlvbjogcmVsYXRpdmU7IHotaW5kZXg6IDI7IH0KICAgICAgICAgICAgLyogd2hp
dGUtcGFuZWwtYm9yZGVyOiBvdXRlciBlZGdlIGxpbmUgcmVtb3ZlZCAqLwogICAgICAgICNhcHAgewog
ICAgICAgICAgICBib3JkZXI6IG5vbmUgIWltcG9ydGFudDsKICAgICAgICAgICAgYm9yZGVyLXJhZGl1
czogMCAhaW1wb3J0YW50OwogICAgICAgICAgICBib3gtc2l6aW5nOiBib3JkZXItYm94ICFpbXBvcnRh
bnQ7CiAgICAgICAgICAgIG92ZXJmbG93OiBoaWRkZW4gIWltcG9ydGFudDsKICAgICAgICB9CiAgICAg
ICAgLml0bSwgLm1nLCAubWctcm93LCAubWVyZ2UtZ3JvdXAgewogICAgICAgICAgICBib3JkZXI6IDFw
eCBzb2xpZCAjZmZmZmZmICFpbXBvcnRhbnQ7CiAgICAgICAgfQogICAgPC9zdHlsZT4KPC9oZWFkPgo8
Ym9keSBkYXRhLXVpLWJ1aWxkPSIyMDI2MDkwNy0yMzA3Ij4KPGRpdiBpZD0iYXBwIiBkYXRhLXVpLXZl
cj0iMjAyNjA5MDgtcGluLWJhY2siPgogICAgPGRpdiBpZD0iaGRyIj4KICAgICAgICA8ZGl2IGlkPSJo
ZWFydCI+CiAgICAgICAgICAgIDxzdmcgdmlld0JveD0iMCAwIDI0IDI0IiBmaWxsPSJub25lIiBzdHJv
a2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIxLjgiCiAgICAgICAgICAgICAgICAgc3Ryb2tl
LWxpbmVjYXA9InJvdW5kIiBzdHJva2UtbGluZWpvaW49InJvdW5kIj4KICAgICAgICAgICAgICAgIDxy
ZWN0IHg9IjkiIHk9IjIiIHdpZHRoPSI2IiBoZWlnaHQ9IjQiIHJ4PSIxIi8+CiAgICAgICAgICAgICAg
ICA8cGF0aCBkPSJNMTYgNGgyYTIgMiAwIDAgMSAyIDJ2MTRhMiAyIDAgMCAxLTIgMkg2YTIgMiAwIDAg
MS0yLTJWNmEyIDIgMCAwIDEgMi0yaDIiLz4KICAgICAgICAgICAgICAgIDxwYXRoIGQ9Ik05IDEyaDZN
OSAxNmg0Ii8+CiAgICAgICAgICAgIDwvc3ZnPgogICAgICAgIDwvZGl2PgogICAgICAgIDxkaXYgaWQ9
Imhkci1ncm93Ij48L2Rpdj4KICAgICAgICA8YnV0dG9uIGlkPSJidG4tbG9jYXRlIiB0eXBlPSJidXR0
b24iIHRpdGxlPSLlrprkvY3liLDkuIrmrKHkvb/nlKjnmoTmnaHnm64iIGRpc2FibGVkPgogICAgICAg
ICAgICA8c3ZnIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSJjdXJyZW50Q29s
b3IiIHN0cm9rZS13aWR0aD0iMiIKICAgICAgICAgICAgICAgICBzdHJva2UtbGluZWNhcD0icm91bmQi
IHN0cm9rZS1saW5lam9pbj0icm91bmQiPgogICAgICAgICAgICAgICAgPGNpcmNsZSBjeD0iMTIiIGN5
PSIxMiIgcj0iOCIvPgogICAgICAgICAgICAgICAgPGNpcmNsZSBjeD0iMTIiIGN5PSIxMiIgcj0iMy41
Ii8+CiAgICAgICAgICAgIDwvc3ZnPgogICAgICAgIDwvYnV0dG9uPgogICAgICAgIDxkaXYgaWQ9InNl
YXJjaC13cmFwIj4KICAgICAgICAgICAgPGJ1dHRvbiBpZD0iYnRuLXNlYXJjaCIgdHlwZT0iYnV0dG9u
IiB0aXRsZT0i5pCc57SiIj4KICAgICAgICAgICAgICAgIDxzdmcgdmlld0JveD0iMCAwIDI0IDI0IiBm
aWxsPSJub25lIiBzdHJva2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIyIgogICAgICAgICAg
ICAgICAgICAgICBzdHJva2UtbGluZWNhcD0icm91bmQiIHN0cm9rZS1saW5lam9pbj0icm91bmQiPgog
ICAgICAgICAgICAgICAgICAgIDxjaXJjbGUgY3g9IjExIiBjeT0iMTEiIHI9IjciLz4KICAgICAgICAg
ICAgICAgICAgICA8cGF0aCBkPSJNMjAgMjBsLTMuNS0zLjUiLz4KICAgICAgICAgICAgICAgIDwvc3Zn
PgogICAgICAgICAgICA8L2J1dHRvbj4KICAgICAgICAgICAgPGRpdiBpZD0ic2VhcmNoLWJveCI+CiAg
ICAgICAgICAgICAgICA8YnV0dG9uIGlkPSJidG4tdG9kYXkiIHR5cGU9ImJ1dHRvbiI+5b2T5aSpPC9i
dXR0b24+CiAgICAgICAgICAgICAgICA8aW5wdXQgaWQ9InNlYXJjaCIgdHlwZT0idGV4dCIgcGxhY2Vo
b2xkZXI9IuaQnOe0ouKApiDnqbrmoLzliIbor43pobvlkIzml7bljIXlkKsgwrcgYXxiIOWIhuautSIg
YXV0b2NvbXBsZXRlPSJvZmYiIHNwZWxsY2hlY2s9ImZhbHNlIj4KICAgICAgICAgICAgICAgIDxidXR0
b24gaWQ9InNlYXJjaC1jbHIiIHR5cGU9ImJ1dHRvbiI+4pyVPC9idXR0b24+CiAgICAgICAgICAgIDwv
ZGl2PgogICAgICAgIDwvZGl2PgogICAgICAgIDxidXR0b24gaWQ9ImJ0bi1waW4iIHR5cGU9ImJ1dHRv
biIgdGl0bGU9IumSieWcqOWxj+W5leS4iiI+CiAgICAgICAgICAgIDxzdmcgdmlld0JveD0iMCAwIDI0
IDI0IiBmaWxsPSJub25lIiBzdHJva2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIyIgogICAg
ICAgICAgICAgICAgIHN0cm9rZS1saW5lam9pbj0icm91bmQiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCI+
CiAgICAgICAgICAgICAgICA8bGluZSB4MT0iMTIiIHkxPSIxNyIgeDI9IjEyIiB5Mj0iMjIiLz4KICAg
ICAgICAgICAgICAgIDxwYXRoIGQ9Ik01IDE3aDE0di0xLjc2YTIgMiAwIDAgMC0xLjExLTEuNzlsLTEu
NzgtLjlBMiAyIDAgMCAxIDE1IDEwLjc2VjZoMWEyIDIgMCAwIDAgMC00SDhhMiAyIDAgMCAwIDAgNGgx
djQuNzZhMiAyIDAgMCAxLTEuMTEgMS43OWwtMS43OC45QTIgMiAwIDAgMCA1IDE1LjI0WiIvPgogICAg
ICAgICAgICA8L3N2Zz4KICAgICAgICA8L2J1dHRvbj4KICAgIDwvZGl2PgoKICAgIDxkaXYgaWQ9InRh
YnMiPgogICAgICAgIDxkaXYgaWQ9InRhYi1pbmsiIGFyaWEtaGlkZGVuPSJ0cnVlIj48L2Rpdj4KICAg
ICAgICA8ZGl2IGNsYXNzPSJ0YWIgb24iIGRhdGEtdGFiPSJhbGwiPuWFqOmDqDwvZGl2PgogICAgICAg
IDxkaXYgY2xhc3M9InRhYiIgZGF0YS10YWI9InRleHQiPuaWh+acrDwvZGl2PgogICAgICAgIDxkaXYg
Y2xhc3M9InRhYiIgZGF0YS10YWI9ImltYWdlIj7lm77lg488L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNz
PSJ0YWIiIGRhdGEtdGFiPSJmaWxlIj7mlofku7Y8L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJ0YWIi
IGRhdGEtdGFiPSJyZWNlbnQiPuacgOi/kTwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9InRhYiIgZGF0
YS10YWI9InBpbm5lZCI+5pS26JePIDxzcGFuIGNsYXNzPSJiYWRnZSIgaWQ9InBpbi1jbnQiIHN0eWxl
PSJkaXNwbGF5Om5vbmUiPjA8L3NwYW4+PC9kaXY+CiAgICAgICAgPGRpdiBpZD0idGFiLWFjdGlvbnMi
PgogICAgICAgICAgICA8YnV0dG9uIGlkPSJtdWx0aS1jbnQiIHR5cGU9ImJ1dHRvbiIgdGl0bGU9IuWP
lua2iOWkmumAiSI+MDwvYnV0dG9uPgogICAgICAgICAgICA8c3BhbiBpZD0iYmFyLXR4dCI+MDwvc3Bh
bj4KICAgICAgICAgICAgPGJ1dHRvbiBpZD0iYnRuLWNsciIgdHlwZT0iYnV0dG9uIiB0aXRsZT0i5riF
56m65Y6G5Y+yIj4KICAgICAgICAgICAgICAgIDxzdmcgdmlld0JveD0iMCAwIDI0IDI0IiBmaWxsPSJu
b25lIiBzdHJva2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIyIgogICAgICAgICAgICAgICAg
ICAgICBzdHJva2UtbGluZWNhcD0icm91bmQiIHN0cm9rZS1saW5lam9pbj0icm91bmQiPgogICAgICAg
ICAgICAgICAgICAgIDxwb2x5bGluZSBwb2ludHM9IjMgNiA1IDYgMjEgNiIvPgogICAgICAgICAgICAg
ICAgICAgIDxwYXRoIGQ9Ik0xOSA2bC0xIDE0YTIgMiAwIDAgMS0yIDJIOGEyIDIgMCAwIDEtMi0yTDUg
NiIvPgogICAgICAgICAgICAgICAgICAgIDxwYXRoIGQ9Ik0xMCAxMXY2TTE0IDExdjZNOSA2VjRoNnYy
Ii8+CiAgICAgICAgICAgICAgICA8L3N2Zz4KICAgICAgICAgICAgPC9idXR0b24+CiAgICAgICAgPC9k
aXY+CiAgICA8L2Rpdj4KCiAgICA8ZGl2IGlkPSJsaXN0Ij4KICAgICAgICA8ZGl2IGlkPSJza2VsIiBh
cmlhLWhpZGRlbj0idHJ1ZSI+CiAgICAgICAgICAgIDxkaXYgY2xhc3M9InNrLXJvdyI+PGRpdiBjbGFz
cz0ic2staWNvIj48L2Rpdj48ZGl2IGNsYXNzPSJzay1ib2R5Ij48ZGl2IGNsYXNzPSJzay1saW5lIG1p
ZCI+PC9kaXY+PGRpdiBjbGFzcz0ic2stbGluZSBzaG9ydCI+PC9kaXY+PC9kaXY+PC9kaXY+CiAgICAg
ICAgICAgIDxkaXYgY2xhc3M9InNrLXJvdyI+PGRpdiBjbGFzcz0ic2staWNvIj48L2Rpdj48ZGl2IGNs
YXNzPSJzay1ib2R5Ij48ZGl2IGNsYXNzPSJzay1saW5lIj48L2Rpdj48ZGl2IGNsYXNzPSJzay1saW5l
IG1pZCI+PC9kaXY+PC9kaXY+PC9kaXY+CiAgICAgICAgICAgIDxkaXYgY2xhc3M9InNrLXJvdyI+PGRp
diBjbGFzcz0ic2staWNvIj48L2Rpdj48ZGl2IGNsYXNzPSJzay1ib2R5Ij48ZGl2IGNsYXNzPSJzay1s
aW5lIG1pZCI+PC9kaXY+PGRpdiBjbGFzcz0ic2stbGluZSBzaG9ydCI+PC9kaXY+PC9kaXY+PC9kaXY+
CiAgICAgICAgICAgIDxkaXYgY2xhc3M9InNrLXJvdyI+PGRpdiBjbGFzcz0ic2staWNvIj48L2Rpdj48
ZGl2IGNsYXNzPSJzay1ib2R5Ij48ZGl2IGNsYXNzPSJzay1saW5lIj48L2Rpdj48ZGl2IGNsYXNzPSJz
ay1saW5lIG1pZCI+PC9kaXY+PC9kaXY+PC9kaXY+CiAgICAgICAgICAgIDxkaXYgY2xhc3M9InNrLXJv
dyI+PGRpdiBjbGFzcz0ic2staWNvIj48L2Rpdj48ZGl2IGNsYXNzPSJzay1ib2R5Ij48ZGl2IGNsYXNz
PSJzay1saW5lIG1pZCI+PC9kaXY+PGRpdiBjbGFzcz0ic2stbGluZSBzaG9ydCI+PC9kaXY+PC9kaXY+
PC9kaXY+CiAgICAgICAgICAgIDxkaXYgY2xhc3M9InNrLXJvdyI+PGRpdiBjbGFzcz0ic2staWNvIj48
L2Rpdj48ZGl2IGNsYXNzPSJzay1ib2R5Ij48ZGl2IGNsYXNzPSJzay1saW5lIj48L2Rpdj48ZGl2IGNs
YXNzPSJzay1saW5lIHNob3J0Ij48L2Rpdj48L2Rpdj48L2Rpdj4KICAgICAgICA8L2Rpdj4KICAgICAg
ICA8ZGl2IGlkPSJlbXB0eSI+CiAgICAgICAgICAgIDxkaXYgY2xhc3M9ImUtdHh0IiBpZD0iZW1wdHkt
dHh0Ij7mmoLml6DorrDlvZXvvIzlpI3liLblkI7oh6rliqjlh7rnjrA8L2Rpdj4KICAgICAgICA8L2Rp
dj4KICAgIDwvZGl2PgogICAgPGJ1dHRvbiBpZD0iYnRuLXRvcCIgdHlwZT0iYnV0dG9uIiB0aXRsZT0i
5Zue5Yiw6aG26YOoIiBhcmlhLWxhYmVsPSLlm57liLDpobbpg6giPgogICAgICAgIDxzdmcgdmlld0Jv
eD0iMCAwIDI0IDI0IiBmaWxsPSJub25lIiBzdHJva2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRo
PSIyLjIiCiAgICAgICAgICAgICBzdHJva2UtbGluZWNhcD0icm91bmQiIHN0cm9rZS1saW5lam9pbj0i
cm91bmQiPgogICAgICAgICAgICA8cGF0aCBkPSJNMTIgMTlWNSIvPgogICAgICAgICAgICA8cGF0aCBk
PSJNNSAxMmw3LTcgNyA3Ii8+CiAgICAgICAgPC9zdmc+CiAgICA8L2J1dHRvbj4KPC9kaXY+Cgo8ZGl2
IGlkPSJjdHgiPgogICAgPGRpdiBjbGFzcz0iYy1pdGVtIiBpZD0iYy1jb3B5Ij48c3BhbiBjbGFzcz0i
Yy1pY28iPuKOmDwvc3Bhbj7lpI3liLY8L2Rpdj4KICAgIDxkaXYgY2xhc3M9ImMtaXRlbSIgaWQ9ImMt
cGFzdGUiPjxzcGFuIGNsYXNzPSJjLWljbyI+4o+OPC9zcGFuPueymOi0tDwvZGl2PgogICAgPGRpdiBj
bGFzcz0iYy1zZXAiPjwvZGl2PgogICAgPGRpdiBjbGFzcz0iYy1pdGVtIiBpZD0iYy1waW4iPjxzcGFu
IGNsYXNzPSJjLWljbyI+4piFPC9zcGFuPuaUtuiXjzwvZGl2PgogICAgPGRpdiBjbGFzcz0iYy1pdGVt
IiBpZD0iYy10aXRsZSIgc3R5bGU9ImRpc3BsYXk6bm9uZSI+PHNwYW4gY2xhc3M9ImMtaWNvIj7inI48
L3NwYW4+6K6+572u5qCH6aKYPC9kaXY+CiAgICA8ZGl2IGNsYXNzPSJjLWl0ZW0iIGlkPSJjLW1lcmdl
IiBzdHlsZT0iZGlzcGxheTpub25lIj48c3BhbiBjbGFzcz0iYy1pY28iPuKniTwvc3Bhbj7lkIjlubY8
L2Rpdj4KICAgIDxkaXYgY2xhc3M9ImMtaXRlbSIgaWQ9ImMtdW5tZXJnZSIgc3R5bGU9ImRpc3BsYXk6
bm9uZSI+PHNwYW4gY2xhc3M9ImMtaWNvIj7ih4Q8L3NwYW4+5Y+W5raI5ZCI5bm2PC9kaXY+CiAgICA8
ZGl2IGNsYXNzPSJjLWl0ZW0iIGlkPSJjLXRvcCI+PHNwYW4gY2xhc3M9ImMtaWNvIj7ihpE8L3NwYW4+
56e75Yiw6aG26YOoPC9kaXY+CiAgICA8ZGl2IGNsYXNzPSJjLWl0ZW0iIGlkPSJjLWNsZWFyLXBhc3Rl
ZCIgc3R5bGU9ImRpc3BsYXk6bm9uZSI+PHNwYW4gY2xhc3M9ImMtaWNvIj7inJM8L3NwYW4+5riF6Zmk
54q25oCBPC9kaXY+CiAgICA8ZGl2IGNsYXNzPSJjLWl0ZW0iIGlkPSJjLXF1ZXVlLWZyb20iIHN0eWxl
PSJkaXNwbGF5Om5vbmUiPjxzcGFuIGNsYXNzPSJjLWljbyI+4oa7PC9zcGFuPuS7juatpOWkhOW8gOWn
i+mYn+WIlzwvZGl2PgogICAgPGRpdiBjbGFzcz0iYy1zZXAiPjwvZGl2PgogICAgPGRpdiBjbGFzcz0i
Yy1pdGVtIGRhbmdlciIgaWQ9ImMtZGVsIj48c3BhbiBjbGFzcz0iYy1pY28iPuKclTwvc3Bhbj7liKDp
maQ8L2Rpdj4KPC9kaXY+Cgo8ZGl2IGlkPSJjbHItZGxnIj4KICAgIDxkaXYgY2xhc3M9ImNsci1ib3gi
IHJvbGU9ImRpYWxvZyIgYXJpYS1tb2RhbD0idHJ1ZSI+CiAgICAgICAgPGRpdiBjbGFzcz0iY2xyLXRp
dGxlIiBpZD0iY2xyLXRpdGxlIj7noa7orqTmuIXnqbrvvJ88L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNz
PSJjbHItZGVzYyIgaWQ9ImNsci1kZXNjIj7pu5jorqTku4XmuIXnqbrlvZPlpKnlhoXlrrnjgII8L2Rp
dj4KICAgICAgICA8bGFiZWwgY2xhc3M9ImNsci1jaGVjayIgZm9yPSJjbHItYWxsIj4KICAgICAgICAg
ICAgPGlucHV0IHR5cGU9ImNoZWNrYm94IiBpZD0iY2xyLWFsbCI+CiAgICAgICAgICAgIDxzcGFuPua4
heepuuaJgOaciTwvc3Bhbj4KICAgICAgICA8L2xhYmVsPgogICAgICAgIDxkaXYgY2xhc3M9ImNsci1i
dG5zIj4KICAgICAgICAgICAgPGJ1dHRvbiB0eXBlPSJidXR0b24iIGlkPSJjbHItY2FuY2VsIj7lj5bm
tog8L2J1dHRvbj4KICAgICAgICAgICAgPGJ1dHRvbiB0eXBlPSJidXR0b24iIGlkPSJjbHItb2siPua4
heepujwvYnV0dG9uPgogICAgICAgIDwvZGl2PgogICAgPC9kaXY+CjwvZGl2PgoKPGRpdiBpZD0idGl0
bGUtZGxnIj4KICAgIDxkaXYgY2xhc3M9InRpdGxlLWJveCIgcm9sZT0iZGlhbG9nIiBhcmlhLW1vZGFs
PSJ0cnVlIj4KICAgICAgICA8ZGl2IGNsYXNzPSJjbHItdGl0bGUiPuiuvue9ruagh+mimDwvZGl2Pgog
ICAgICAgIDxkaXYgY2xhc3M9ImNsci1kZXNjIj7moIfpopjlj6/ooqvmkJzntKLmib7liLDvvIzku4Xn
lKjkuo7mlLbol4/mlbTnkIbjgII8L2Rpdj4KICAgICAgICA8aW5wdXQgaWQ9InRpdGxlLWlucHV0IiB0
eXBlPSJ0ZXh0IiBtYXhsZW5ndGg9IjgwIiBwbGFjZWhvbGRlcj0i57uZ6L+Z5p2h5pS26JeP6LW35Liq
5ZCN5a2X4oCmIiBhdXRvY29tcGxldGU9Im9mZiIgc3BlbGxjaGVjaz0iZmFsc2UiPgogICAgICAgIDxk
aXYgY2xhc3M9ImNsci1idG5zIj4KICAgICAgICAgICAgPGJ1dHRvbiB0eXBlPSJidXR0b24iIGlkPSJ0
aXRsZS1jYW5jZWwiPuWPlua2iDwvYnV0dG9uPgogICAgICAgICAgICA8YnV0dG9uIHR5cGU9ImJ1dHRv
biIgaWQ9InRpdGxlLW9rIj7kv53lrZg8L2J1dHRvbj4KICAgICAgICA8L2Rpdj4KICAgIDwvZGl2Pgo8
L2Rpdj4KPGRpdiBpZD0icGF0aC10aXAiIGFyaWEtaGlkZGVuPSJ0cnVlIj48L2Rpdj4KCjxzY3JpcHQ+
Ci8qIHNrZWwtZmFpbHNhZmU6IG9ubHkgaWYgbWFpbiBVSSBzY3JpcHQgbmV2ZXIgYm9vdGVkIOKAlG5l
dmVyIGludmVudCBlbXB0eS1zdGF0ZSAqLwooZnVuY3Rpb24oKXsKICBzZXRUaW1lb3V0KCgpID0+IHsK
ICAgIHRyeSB7CiAgICAgIGlmICh3aW5kb3cuX191aUJvb3RlZCkgcmV0dXJuOwogICAgICB2YXIgYXBw
ID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2FwcCcpOwogICAgICBpZiAoYXBwKSBhcHAuY2xhc3NM
aXN0LnJlbW92ZSgnYm9vdC1sb2FkaW5nJyk7CiAgICAgIHZhciBzID0gZG9jdW1lbnQuZ2V0RWxlbWVu
dEJ5SWQoJ3NrZWwnKTsKICAgICAgaWYgKHMpIHMuY2xhc3NMaXN0LnJlbW92ZSgnb24nKTsKICAgIH0g
Y2F0Y2ggKGVycikge30KICB9LCAzMDAwKTsKfSkoKTsKPC9zY3JpcHQ+CjxzY3JpcHQ+CiAgICBsZXQg
YWxsQ2xpcHMgPSBbXSwgY3VyVGFiID0gJ2FsbCcsIHF1ZXJ5ID0gJycsIGN0eENsaXAgPSBudWxsLCBz
ZWxlY3RlZElkID0gMCwgcGlubmVkVUkgPSBmYWxzZTsKICAgIGNvbnN0IFRBQl9PUkRFUiA9IFsnYWxs
JywgJ3RleHQnLCAnaW1hZ2UnLCAnZmlsZScsICdyZWNlbnQnLCAncGlubmVkJ107CiAgICBjb25zdCB2
aWV3TWVtID0gbmV3IE1hcCgpOwogICAgZnVuY3Rpb24gdmlld01lbUtleSh0YWIsIHEsIHRvZGF5KSB7
CiAgICAgICAgcmV0dXJuIFN0cmluZyh0YWIgfHwgJ2FsbCcpICsgJ1x0JyArIFN0cmluZyhxIHx8ICcn
KSArICdcdCcgKyAodG9kYXkgPyAnMScgOiAnMCcpOwogICAgfQogICAgbGV0IHRhYlN3aXRjaEFuaW1E
aXIgPSAwOwogICAgbGV0IG11bHRpSWRzID0gW107CiAgICBsZXQgdG9kYXlPbmx5ID0gZmFsc2U7CiAg
ICBsZXQgZGlza1RvdGFsID0gMDsKICAgIGxldCBsb2FkaW5nTW9yZSA9IGZhbHNlOwogICAgLy8gRG9u
J3Qgc2hvdyBza2VsZXRvbiBpbW1lZGlhdGVseSDigJRvbmx5IGFmdGVyIFNLRUxfREVMQVlfTVMgaWYg
ZGF0YSBzdGlsbCBtaXNzaW5nCiAgICBsZXQgYm9vdExvYWRpbmcgPSBmYWxzZTsKICAgIGxldCB3YWl0
aW5nRGF0YSA9IGZhbHNlOwogICAgbGV0IGhvc3RQdXNoZWRPbmNlID0gZmFsc2U7IC8vIG9ubHkgdGhl
biBtYXkgc2hvd+OAjOaaguaXoOiusOW9leOAjQogICAgbGV0IHNhd05vbkVtcHR5ID0gZmFsc2U7ICAg
IC8vIGlnbm9yZSBib290c3RyYXAgZW1wdHkgcHVzaGVzIGJlZm9yZSBmaXJzdCByZWFsIGxpc3QKICAg
IGxldCBwaW5uZWRUb3RhbCA9IDA7ICAgICAgICAvLyBhdXRob3JpdGF0aXZlIOaUtuiXjyBjb3VudCBm
cm9tIEFISwogICAgY29uc3QgU0tFTF9ERUxBWV9NUyA9IDYwOwogICAgd2luZG93Ll9fZGF0YVJlYWR5
ID0gZmFsc2U7CiAgICB3aW5kb3cuX191aUJvb3RlZCA9IHRydWU7CiAgICAvLyBPcGVuIHBhbmVsIHdp
dGhvdXQgcGFzdGluZyDihpIgYWx3YXlzIGxhbmQgb24gZmlyc3QgaXRlbSAoYWZ0ZXIgZGF0YSBhcnJp
dmVzKQogICAgbGV0IHNlbGVjdEZpcnN0T25TaG93ID0gZmFsc2U7CiAgICBsZXQgbGFzdFBhc3RlSWQg
PSAwOwogICAgbGV0IGxhc3RQYXN0ZVRhYiA9ICdhbGwnOwogICAgbGV0IGxvY2F0ZUFjdGl2ZSA9IGZh
bHNlOwogICAgdHJ5IHsgbGFzdFBhc3RlSWQgPSArbG9jYWxTdG9yYWdlLmdldEl0ZW0oJ2NsaXBMYXN0
UGFzdGVJZCcpIHx8IDA7IH0gY2F0Y2gge30KICAgIHRyeSB7CiAgICAgICAgY29uc3QgdCA9IGxvY2Fs
U3RvcmFnZS5nZXRJdGVtKCdjbGlwTGFzdFBhc3RlVGFiJykgfHwgJ2FsbCc7CiAgICAgICAgbGFzdFBh
c3RlVGFiID0gWydhbGwnLCd0ZXh0JywnaW1hZ2UnLCdmaWxlJywncGlubmVkJ10uaW5jbHVkZXModCkg
PyB0IDogJ2FsbCc7CiAgICB9IGNhdGNoIHt9CiAgICAvLyBQcmVmZXIgc2FtZS1vcmlnaW4gdW5kZXIg
Y2xpcHVpLmFwcCAoQVBQX0hPU1Qg4oaSIENMSVBfVjFfRElSL2NsaXBzX3N0b3JlKS4KICAgIC8vIOWL
v+eUqCAqLmxvY2Fs77ya57O757ufIG1ETlMg5Lya5Y2hIDLigJMzc+OAgmNsaXBzLnN0b3JlIOS7heS9
nCBmYWxsYmFja+OAggogICAgY29uc3QgU1RPUkVfQkFTRSA9IChsb2NhdGlvbi5vcmlnaW4gJiYgbG9j
YXRpb24ub3JpZ2luLmluZGV4T2YoJ2h0dHBzOi8vJykgPT09IDApCiAgICAgICAgPyAobG9jYXRpb24u
b3JpZ2luLnJlcGxhY2UoL1wvJC8sICcnKSArICcvY2xpcHNfc3RvcmUvJykKICAgICAgICA6ICdodHRw
czovL2NsaXB1aS5hcHAvY2xpcHNfc3RvcmUvJzsKICAgIGNvbnN0IFNUT1JFX0JBU0VfRkFMTEJBQ0sg
PSAnaHR0cHM6Ly9jbGlwcy5zdG9yZS8nOwogICAgZnVuY3Rpb24gbWV0YUNlbnRlckh0bWwoZXhwYW5k
SW5uZXIpIHsKICAgICAgICBpZiAoZXhwYW5kSW5uZXIgPT0gbnVsbCB8fCBleHBhbmRJbm5lciA9PT0g
ZmFsc2UpCiAgICAgICAgICAgIHJldHVybiBgPHNwYW4gY2xhc3M9ImktbWV0YS1jZW50ZXIiPjwvc3Bh
bj5gOwogICAgICAgIHJldHVybiBgPHNwYW4gY2xhc3M9ImktbWV0YS1jZW50ZXIiPjxidXR0b24gY2xh
c3M9ImktZXhwYW5kLWJ0biR7ZXhwYW5kSW5uZXIub24gPyAnIG9uJyA6ICcnfSIgdHlwZT0iYnV0dG9u
IiB0aXRsZT0i5bGV5byAL+aUtui1tyI+JHtleHBhbmRJbm5lci5odG1sfTwvYnV0dG9uPjwvc3Bhbj5g
OwogICAgfQoKICAgIGZ1bmN0aW9uIHJlbWVtYmVyTGFzdFBhc3RlKGlkKSB7CiAgICAgICAgbGFzdFBh
c3RlSWQgPSAraWQgfHwgMDsKICAgICAgICBsYXN0UGFzdGVUYWIgPSBjdXJUYWIgfHwgJ2FsbCc7CiAg
ICAgICAgdHJ5IHsKICAgICAgICAgICAgbG9jYWxTdG9yYWdlLnNldEl0ZW0oJ2NsaXBMYXN0UGFzdGVJ
ZCcsIFN0cmluZyhsYXN0UGFzdGVJZCkpOwogICAgICAgICAgICBsb2NhbFN0b3JhZ2Uuc2V0SXRlbSgn
Y2xpcExhc3RQYXN0ZVRhYicsIGxhc3RQYXN0ZVRhYik7CiAgICAgICAgfSBjYXRjaCB7fQogICAgICAg
IHVwZGF0ZUxvY2F0ZUJ0bigpOwogICAgfQogICAgZnVuY3Rpb24gdXBkYXRlTG9jYXRlQnRuKCkgewog
ICAgICAgIGNvbnN0IGJ0biA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdidG4tbG9jYXRlJyk7CiAg
ICAgICAgaWYgKCFidG4pIHJldHVybjsKICAgICAgICBidG4uZGlzYWJsZWQgPSAhbGFzdFBhc3RlSWQ7
CiAgICAgICAgYnRuLmNsYXNzTGlzdC50b2dnbGUoJ2hhcy10YXJnZXQnLCAhIWxhc3RQYXN0ZUlkKTsK
ICAgICAgICBidG4uY2xhc3NMaXN0LnRvZ2dsZSgnb24nLCBsb2NhdGVBY3RpdmUgJiYgISFsYXN0UGFz
dGVJZCk7CiAgICAgICAgYnRuLnRpdGxlID0gIWxhc3RQYXN0ZUlkCiAgICAgICAgICAgID8gJ+aaguaX
oOS4iuasoeS9v+eUqOS9jee9ricKICAgICAgICAgICAgOiAobG9jYXRlQWN0aXZlID8gJ+WPlua2iOWu
muS9je+8jOWbnuWIsOesrOS4gOadoScgOiAn5a6a5L2N5Yiw5LiK5qyh5L2/55So55qE5p2h55uuJyk7
CiAgICB9CiAgICBmdW5jdGlvbiBzZWxlY3RGaXJzdEl0ZW0oKSB7CiAgICAgICAgbG9jYXRlQWN0aXZl
ID0gZmFsc2U7CiAgICAgICAgd2luZG93Ll9fcGVuZGluZ0p1bXBJZCA9IDA7CiAgICAgICAgd2luZG93
Ll9fanVtcExvYWRUcmllcyA9IDA7CiAgICAgICAgc2VsZWN0Rmlyc3RPblNob3cgPSBmYWxzZTsKICAg
ICAgICBjb25zdCB2aXMgPSB2aXNpYmxlTGlzdCgpOwogICAgICAgIGlmICghdmlzLmxlbmd0aCkgewog
ICAgICAgICAgICBzZWxlY3RlZElkID0gMDsKICAgICAgICAgICAgc3luY0l0ZW1IaWdobGlnaHQoKTsK
ICAgICAgICAgICAgdXBkYXRlTG9jYXRlQnRuKCk7CiAgICAgICAgICAgIHJldHVybjsKICAgICAgICB9
CiAgICAgICAgc2VsZWN0ZWRJZCA9IHZpc1swXS5pZDsKICAgICAgICByYW5nZUFuY2hvcklkID0gc2Vs
ZWN0ZWRJZDsKICAgICAgICByYW5nZUFuY2hvckNsaWNrZWQgPSBmYWxzZTsKICAgICAgICBsaXN0RWwu
c2Nyb2xsVG9wID0gMDsKICAgICAgICBzeW5jSXRlbUhpZ2hsaWdodCgpOwogICAgICAgIGNvbnN0IGVs
ID0gbGlzdEVsLnF1ZXJ5U2VsZWN0b3IoJy5pdG1bZGF0YS1pZD0iJyArIHNlbGVjdGVkSWQgKyAnIl0n
KTsKICAgICAgICBpZiAoZWwpIGVsLnNjcm9sbEludG9WaWV3KHsgYmxvY2s6ICduZWFyZXN0JyB9KTsK
ICAgICAgICB1cGRhdGVMb2NhdGVCdG4oKTsKICAgIH0KICAgIGZ1bmN0aW9uIGp1bXBUb0xhc3RQYXN0
ZSgpIHsKICAgICAgICBpZiAoIWxhc3RQYXN0ZUlkKSByZXR1cm47CiAgICAgICAgLy8gQWxyZWFkeSBs
b2NhdGVkIG9uIGxhc3QgcGFzdGUg4oaSIGNhbmNlbCBhbmQgc2VsZWN0IGZpcnN0CiAgICAgICAgaWYg
KGxvY2F0ZUFjdGl2ZSAmJiArc2VsZWN0ZWRJZCA9PT0gK2xhc3RQYXN0ZUlkKSB7CiAgICAgICAgICAg
IHNlbGVjdEZpcnN0SXRlbSgpOwogICAgICAgICAgICByZXR1cm47CiAgICAgICAgfQogICAgICAgIGxv
Y2F0ZUFjdGl2ZSA9IHRydWU7CiAgICAgICAgc2VsZWN0Rmlyc3RPblNob3cgPSBmYWxzZTsKICAgICAg
ICAvLyBDbGVhciBmaWx0ZXJzIHNvIHRoZSBpdGVtIGlzIGZpbmRhYmxlIG9uIHRoZSB0YWIgd2hlcmUg
aXQgd2FzIHVzZWQKICAgICAgICBxdWVyeSA9ICcnOwogICAgICAgIHRvZGF5T25seSA9IGZhbHNlOwog
ICAgICAgIHRyeSB7CiAgICAgICAgICAgIGNvbnN0IHNyY2ggPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJ
ZCgnc2VhcmNoJyk7CiAgICAgICAgICAgIGNvbnN0IHNjbHIgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJ
ZCgnc2VhcmNoLWNscicpOwogICAgICAgICAgICBjb25zdCB3cmFwID0gZG9jdW1lbnQuZ2V0RWxlbWVu
dEJ5SWQoJ3NlYXJjaC13cmFwJyk7CiAgICAgICAgICAgIGNvbnN0IGJ0blRvZGF5ID0gZG9jdW1lbnQu
Z2V0RWxlbWVudEJ5SWQoJ2J0bi10b2RheScpOwogICAgICAgICAgICBpZiAoc3JjaCkgeyBzcmNoLnZh
bHVlID0gJyc7IHNyY2guY2xhc3NMaXN0LnJlbW92ZSgnaGFzLXZhbCcpOyB9CiAgICAgICAgICAgIGlm
IChzY2xyKSBzY2xyLnN0eWxlLmRpc3BsYXkgPSAnbm9uZSc7CiAgICAgICAgICAgIGlmICh3cmFwKSB3
cmFwLmNsYXNzTGlzdC5yZW1vdmUoJ29wZW4nKTsKICAgICAgICAgICAgaWYgKGJ0blRvZGF5KSBidG5U
b2RheS5jbGFzc0xpc3QucmVtb3ZlKCdvbicpOwogICAgICAgIH0gY2F0Y2gge30KICAgICAgICBjb25z
dCB0YWIgPSBbJ2FsbCcsJ3RleHQnLCdpbWFnZScsJ2ZpbGUnLCdwaW5uZWQnXS5pbmNsdWRlcyhsYXN0
UGFzdGVUYWIpCiAgICAgICAgICAgID8gbGFzdFBhc3RlVGFiIDogJ2FsbCc7CiAgICAgICAgY29uc3Qg
cHJldlRhYiA9IGN1clRhYjsKICAgICAgICBjdXJUYWIgPSB0YWI7CiAgICAgICAgbG9hZGluZ01vcmUg
PSBmYWxzZTsKICAgICAgICBtYXJrVGFiKHRhYik7CiAgICAgICAgY2xlYXJNdWx0aSgpOwogICAgICAg
IHNlbGVjdGVkSWQgPSBsYXN0UGFzdGVJZDsKICAgICAgICB3aW5kb3cuX19wZW5kaW5nSnVtcElkID0g
bGFzdFBhc3RlSWQ7CiAgICAgICAgd2luZG93Ll9fanVtcExvYWRUcmllcyA9IDA7CiAgICAgICAgd2lu
ZG93Ll9fanVtcEZlbGxCYWNrID0gZmFsc2U7CiAgICAgICAgdXBkYXRlTG9jYXRlQnRuKCk7CiAgICAg
ICAgcmVxdWVzdFZpZXcoKTsKICAgIH0KCiAgICBmdW5jdGlvbiByZXF1ZXN0VmlldygpIHsKICAgICAg
ICBjb25zdCB0YWIgPSBjdXJUYWIsIHEgPSBxdWVyeSwgdG9kYXkgPSB0b2RheU9ubHkgPyAnMScgOiAn
MCc7CiAgICAgICAgaWYgKHdpbmRvdy5fX3ZpZXdSYWYpIGNhbmNlbEFuaW1hdGlvbkZyYW1lKHdpbmRv
dy5fX3ZpZXdSYWYpOwogICAgICAgIHdpbmRvdy5fX3ZpZXdSYWYgPSByZXF1ZXN0QW5pbWF0aW9uRnJh
bWUoKCkgPT4gewogICAgICAgICAgICB3aW5kb3cuX192aWV3UmFmID0gMDsKICAgICAgICAgICAgc2V0
VGltZW91dCgoKSA9PiBhaGsoJ3NldFZpZXcnLCB0YWIsIHEsIHRvZGF5KSwgMCk7CiAgICAgICAgfSk7
CiAgICB9CiAgICAvKiogRGVib3VuY2VkIEFISyBzeW5jIGFmdGVyIHZpZXdNZW0gaW5zdGFudCBwYWlu
dCDigJRhdm9pZHMgdGFiLXN3aXRjaCBkb3VibGUgUHVzaENsaXBzICovCiAgICBmdW5jdGlvbiBzb2Z0
UmVxdWVzdFZpZXcoKSB7CiAgICAgICAgaWYgKHdpbmRvdy5fX3NvZnRWaWV3VCkgY2xlYXJUaW1lb3V0
KHdpbmRvdy5fX3NvZnRWaWV3VCk7CiAgICAgICAgd2luZG93Ll9fc29mdFZpZXdUID0gc2V0VGltZW91
dCgoKSA9PiB7CiAgICAgICAgICAgIHdpbmRvdy5fX3NvZnRWaWV3VCA9IDA7CiAgICAgICAgICAgIHJl
cXVlc3RWaWV3KCk7CiAgICAgICAgfSwgMzIwKTsKICAgIH0KICAgIGZ1bmN0aW9uIHJlcXVlc3RNb3Jl
KGZvcmNlID0gZmFsc2UpIHsKICAgICAgICBpZiAoZGlza1RvdGFsID4gMCAmJiBhbGxDbGlwcy5sZW5n
dGggPj0gZGlza1RvdGFsKSByZXR1cm47CiAgICAgICAgLy8gTG9jYXRlIC8ganVtcCBtdXN0IG5vdCB3
YWl0IG9uIHNjcm9sbC1pZGxlIG9yIGEgc3R1Y2sgbG9hZGluZ01vcmUgZmxhZwogICAgICAgIGlmICgh
Zm9yY2UpIHsKICAgICAgICAgICAgaWYgKGxvYWRpbmdNb3JlKSByZXR1cm47CiAgICAgICAgICAgIGlm
ICh3aW5kb3cuX19zY3JvbGxCdXN5IHx8IF9saXN0UHRyRG93bikgewogICAgICAgICAgICAgICAgd2lu
ZG93Ll9fd2FudE1vcmUgPSB0cnVlOwogICAgICAgICAgICAgICAgcmV0dXJuOwogICAgICAgICAgICB9
CiAgICAgICAgfSBlbHNlIHsKICAgICAgICAgICAgbG9hZGluZ01vcmUgPSBmYWxzZTsKICAgICAgICAg
ICAgd2luZG93Ll9fc2Nyb2xsQnVzeSA9IGZhbHNlOwogICAgICAgICAgICB3aW5kb3cuX193YW50TW9y
ZSA9IGZhbHNlOwogICAgICAgICAgICBfbGlzdFB0ckRvd24gPSBmYWxzZTsKICAgICAgICAgICAgdHJ5
IHsgbGlzdEVsLmNsYXNzTGlzdC5yZW1vdmUoJ2lzLXNjcm9sbGluZycpOyB9IGNhdGNoIHt9CiAgICAg
ICAgfQogICAgICAgIGlmIChsb2FkaW5nTW9yZSkgcmV0dXJuOwogICAgICAgIGxvYWRpbmdNb3JlID0g
dHJ1ZTsKICAgICAgICB3aW5kb3cuX193YW50TW9yZSA9IGZhbHNlOwogICAgICAgIGlmICh3aW5kb3cu
X19sb2FkTW9yZVdhdGNoKSBjbGVhclRpbWVvdXQod2luZG93Ll9fbG9hZE1vcmVXYXRjaCk7CiAgICAg
ICAgd2luZG93Ll9fbG9hZE1vcmVXYXRjaCA9IHNldFRpbWVvdXQoKCkgPT4gewogICAgICAgICAgICB3
aW5kb3cuX19sb2FkTW9yZVdhdGNoID0gMDsKICAgICAgICAgICAgaWYgKGxvYWRpbmdNb3JlKSB7CiAg
ICAgICAgICAgICAgICBsb2FkaW5nTW9yZSA9IGZhbHNlOwogICAgICAgICAgICAgICAgaWYgKHdpbmRv
dy5fX3BlbmRpbmdKdW1wSWQpIHRyeUNvbnRpbnVlSnVtcCgpOwogICAgICAgICAgICB9CiAgICAgICAg
fSwgMTgwMCk7CiAgICAgICAgYWhrKCdsb2FkTW9yZScpOwogICAgfQoKICAgIGZ1bmN0aW9uIHRyeUNv
bnRpbnVlSnVtcCgpIHsKICAgICAgICBjb25zdCBqaWQgPSArd2luZG93Ll9fcGVuZGluZ0p1bXBJZDsK
ICAgICAgICBpZiAoIWppZCkgcmV0dXJuOwogICAgICAgIGlmIChfcGVuZGluZ0FwcGVuZCkgewogICAg
ICAgICAgICBjb25zdCBwZW5kaW5nID0gX3BlbmRpbmdBcHBlbmQ7CiAgICAgICAgICAgIF9wZW5kaW5n
QXBwZW5kID0gbnVsbDsKICAgICAgICAgICAgYXBwbHlBcHBlbmRQYXlsb2FkKHBlbmRpbmcpOwogICAg
ICAgIH0KICAgICAgICBjb25zdCBlbCA9IGxpc3RFbC5xdWVyeVNlbGVjdG9yKCcubWctcm93W2RhdGEt
aWQ9IicgKyBqaWQgKyAnIl0nKSB8fCBsaXN0RWwucXVlcnlTZWxlY3RvcignLml0bVtkYXRhLWlkPSIn
ICsgamlkICsgJyJdJyk7CiAgICAgICAgaWYgKGVsKSB7CiAgICAgICAgICAgIHdpbmRvdy5fX3BlbmRp
bmdKdW1wSWQgPSAwOwogICAgICAgICAgICB3aW5kb3cuX19qdW1wTG9hZFRyaWVzID0gMDsKICAgICAg
ICAgICAgc2VsZWN0ZWRJZCA9IGppZDsKICAgICAgICAgICAgbG9jYXRlQWN0aXZlID0gdHJ1ZTsKICAg
ICAgICAgICAgdXBkYXRlTG9jYXRlQnRuKCk7CiAgICAgICAgICAgIHJlcXVlc3RBbmltYXRpb25GcmFt
ZSgoKSA9PiB7CiAgICAgICAgICAgICAgICBjb25zdCBub2RlID0gbGlzdEVsLnF1ZXJ5U2VsZWN0b3Io
Jy5tZy1yb3dbZGF0YS1pZD0iJyArIGppZCArICciXScpIHx8IGxpc3RFbC5xdWVyeVNlbGVjdG9yKCcu
aXRtW2RhdGEtaWQ9IicgKyBqaWQgKyAnIl0nKTsKICAgICAgICAgICAgICAgIGlmICghbm9kZSkgcmV0
dXJuOwogICAgICAgICAgICAgICAgbm9kZS5zY3JvbGxJbnRvVmlldyh7IGJsb2NrOiAnY2VudGVyJyB9
KTsKICAgICAgICAgICAgICAgIG5vZGUuY2xhc3NMaXN0LmFkZCgnanVtcC1mbGFzaCcpOwogICAgICAg
ICAgICAgICAgc2V0VGltZW91dCgoKSA9PiBub2RlLmNsYXNzTGlzdC5yZW1vdmUoJ2p1bXAtZmxhc2gn
KSwgOTAwKTsKICAgICAgICAgICAgICAgIHN5bmNJdGVtSGlnaGxpZ2h0KCk7CiAgICAgICAgICAgIH0p
OwogICAgICAgICAgICByZXR1cm47CiAgICAgICAgfQogICAgICAgIGlmIChhbGxDbGlwcy5zb21lKGMg
PT4gK2MuaWQgPT09IGppZCkpIHsKICAgICAgICAgICAgcmVuZGVyKCk7CiAgICAgICAgICAgIHJlcXVl
c3RBbmltYXRpb25GcmFtZSgoKSA9PiB0cnlDb250aW51ZUp1bXAoKSk7CiAgICAgICAgICAgIHJldHVy
bjsKICAgICAgICB9CiAgICAgICAgaWYgKGFsbENsaXBzLmxlbmd0aCA8IGRpc2tUb3RhbCAmJiAod2lu
ZG93Ll9fanVtcExvYWRUcmllcyB8fCAwKSA8IDgwKSB7CiAgICAgICAgICAgIHdpbmRvdy5fX2p1bXBM
b2FkVHJpZXMgPSAod2luZG93Ll9fanVtcExvYWRUcmllcyB8fCAwKSArIDE7CiAgICAgICAgICAgIHJl
cXVlc3RNb3JlKHRydWUpOwogICAgICAgICAgICByZXR1cm47CiAgICAgICAgfQogICAgICAgIHdpbmRv
dy5fX3BlbmRpbmdKdW1wSWQgPSAwOwogICAgICAgIHdpbmRvdy5fX2p1bXBMb2FkVHJpZXMgPSAwOwog
ICAgfQogICAgY29uc3QgRU1QVFlfTVNHID0gewogICAgICAgIGFsbDogICAgJ+aaguaXoOiusOW9le+8
jOWkjeWItuWQjuiHquWKqOWHuueOsCcsCiAgICAgICAgdGV4dDogICAn5pqC5peg5paH5pysJywKICAg
ICAgICBpbWFnZTogICfmmoLml6Dlm77lg48nLAogICAgICAgIGZpbGU6ICAgJ+aaguaXoOaWh+S7tics
CiAgICAgICAgcGlubmVkOiAn5pqC5peg5pS26JePJywKICAgICAgICByZWNlbnQ6ICfmmoLml6DmnIDo
v5HmiZPlvIDnmoTnm67lvZUnCiAgICB9OwoKICAgIGZ1bmN0aW9uIGFoa0ludm9rZShtZXRob2QsIGFy
Z3MpIHsKICAgICAgICB0cnkgewogICAgICAgICAgICBjb25zdCBob3N0ID0gY2hyb21lLndlYnZpZXcu
aG9zdE9iamVjdHMuc3luYy5haGs7CiAgICAgICAgICAgIGlmICghaG9zdCkgcmV0dXJuOwogICAgICAg
ICAgICBsZXQgY2FsbGVkID0gZmFsc2U7CiAgICAgICAgICAgIC8vIFdlYlZpZXcyOiBob3N0LmNhbGwo
bmFtZSwg4oCmKSBpcyB0aGUgcmVsaWFibGUgcGF0aC4gRGlyZWN0IGhvc3RbbWV0aG9kXSjigKYpCiAg
ICAgICAgICAgIC8vIGNhbiBtaXMtYmluZCBhcmdzIChzYXcgc2V0VmlldyB0YWIgYmVjb21lIDAg4oaS
IGZvcmV2ZXIgc2tlbGV0b24gLyB3cm9uZyB0YWIpLgogICAgICAgICAgICBpZiAodHlwZW9mIGhvc3Qu
Y2FsbCA9PT0gJ2Z1bmN0aW9uJykgewogICAgICAgICAgICAgICAgdHJ5IHsgaG9zdC5jYWxsKG1ldGhv
ZCwgLi4uYXJncyk7IGNhbGxlZCA9IHRydWU7IH0gY2F0Y2gge30KICAgICAgICAgICAgfQogICAgICAg
ICAgICBpZiAoIWNhbGxlZCAmJiB0eXBlb2YgaG9zdFttZXRob2RdID09PSAnZnVuY3Rpb24nKSB7CiAg
ICAgICAgICAgICAgICB0cnkgeyBob3N0W21ldGhvZF0oLi4uYXJncyk7IGNhbGxlZCA9IHRydWU7IH0g
Y2F0Y2ggKGUpIHsgY29uc29sZS53YXJuKCdhaGsuJyArIG1ldGhvZCwgZSk7IH0KICAgICAgICAgICAg
fQogICAgICAgICAgICBpZiAoIWNhbGxlZCAmJiBob3N0W21ldGhvZF0gIT0gbnVsbCAmJiB0eXBlb2Yg
aG9zdFttZXRob2RdICE9PSAnZnVuY3Rpb24nKSB7CiAgICAgICAgICAgICAgICB0cnkgeyB2b2lkIGhv
c3RbbWV0aG9kXTsgfSBjYXRjaCB7fQogICAgICAgICAgICB9CiAgICAgICAgfSBjYXRjaCAoZSkgeyBj
b25zb2xlLndhcm4oJ2Foay4nICsgbWV0aG9kLCBlKTsgfQogICAgfQogICAgZnVuY3Rpb24gYWhrKG1l
dGhvZCwgLi4uYXJncykgewogICAgICAgIGFoa0ludm9rZShtZXRob2QsIGFyZ3MpOwogICAgfQogICAg
ZnVuY3Rpb24gYWhrUmV0KG1ldGhvZCwgLi4uYXJncykgewogICAgICAgIHRyeSB7CiAgICAgICAgICAg
IGNvbnN0IGhvc3QgPSBjaHJvbWUud2Vidmlldy5ob3N0T2JqZWN0cy5zeW5jLmFoazsKICAgICAgICAg
ICAgaWYgKCFob3N0KSByZXR1cm4gbnVsbDsKICAgICAgICAgICAgbGV0IHJldCA9IG51bGw7CiAgICAg
ICAgICAgIGlmICh0eXBlb2YgaG9zdC5jYWxsID09PSAnZnVuY3Rpb24nKSB7CiAgICAgICAgICAgICAg
ICB0cnkgeyByZXQgPSBob3N0LmNhbGwobWV0aG9kLCAuLi5hcmdzKTsgfSBjYXRjaCB7fQogICAgICAg
ICAgICB9CiAgICAgICAgICAgIGlmIChyZXQgPT0gbnVsbCAmJiB0eXBlb2YgaG9zdFttZXRob2RdID09
PSAnZnVuY3Rpb24nKSB7CiAgICAgICAgICAgICAgICB0cnkgeyByZXQgPSBob3N0W21ldGhvZF0oLi4u
YXJncyk7IH0gY2F0Y2gge30KICAgICAgICAgICAgICAgIGlmIChyZXQgPT0gbnVsbCkgewogICAgICAg
ICAgICAgICAgICAgIHRyeSB7IHJldCA9IGhvc3RbbWV0aG9kXSguLi5hcmdzKTsgfSBjYXRjaCB7fQog
ICAgICAgICAgICAgICAgfQogICAgICAgICAgICB9CiAgICAgICAgICAgIGlmIChyZXQgPT0gbnVsbCAm
JiBob3N0W21ldGhvZF0gIT0gbnVsbCAmJiB0eXBlb2YgaG9zdFttZXRob2RdICE9PSAnZnVuY3Rpb24n
KQogICAgICAgICAgICAgICAgcmV0ID0gaG9zdFttZXRob2RdOwogICAgICAgICAgICBpZiAocmV0ID09
IG51bGwpIHJldHVybiBudWxsOwogICAgICAgICAgICBpZiAodHlwZW9mIHJldCA9PT0gJ3N0cmluZycg
fHwgdHlwZW9mIHJldCA9PT0gJ251bWJlcicgfHwgdHlwZW9mIHJldCA9PT0gJ2Jvb2xlYW4nKQogICAg
ICAgICAgICAgICAgcmV0dXJuIHJldDsKICAgICAgICAgICAgdHJ5IHsgcmV0dXJuIFN0cmluZyhyZXQp
OyB9IGNhdGNoIHsgcmV0dXJuIHJldDsgfQogICAgICAgIH0gY2F0Y2ggKGUpIHsgY29uc29sZS53YXJu
KCdhaGtSZXQuJyArIG1ldGhvZCwgZSk7IH0KICAgICAgICByZXR1cm4gbnVsbDsKICAgIH0KCiAgICAv
LyBFYXJseSBBSEsgX19zZXRUaHVtYiBjYW4gYXJyaXZlIGJlZm9yZSBET00gbm9kZXMgZXhpc3Qg4oCU
IGtlZXAgdW50aWwgYmluZAogICAgY29uc3QgdGh1bWJDYWNoZSA9IG5ldyBNYXAoKTsKCiAgICAvKiog
UHJlZmVyIGNhY2hlIC8gZGF0YS1VUkwsIHRoZW4gdGhfKi5qcGcgdmlhIHZpcnR1YWwgaG9zdCwgdGhl
biBvcmlnaW5hbCAqLwogICAgZnVuY3Rpb24gYmluZFN0b3JlVGh1bWIoaW1nLCBmaWxlLCBpZCwgZmFs
bGJhY2spIHsKICAgICAgICBpbWcuZGF0YXNldC50aHVtYklkID0gU3RyaW5nKGlkKTsKICAgICAgICBp
bWcuYWx0ID0gJyc7CiAgICAgICAgaW1nLmNsYXNzTGlzdC5hZGQoJ3RodW1iLWxvYWRpbmcnKTsKICAg
ICAgICBjb25zdCB3cmFwID0gaW1nLnBhcmVudEVsZW1lbnQ7CiAgICAgICAgaWYgKHdyYXAgJiYgd3Jh
cC5jbGFzc0xpc3QuY29udGFpbnMoJ2ktdGh1bWItd3JhcCcpKQogICAgICAgICAgICB3cmFwLmNsYXNz
TGlzdC5hZGQoJ3dhaXRpbmcnKTsKICAgICAgICBjb25zdCBjbGVhcldhaXQgPSAoKSA9PiB7CiAgICAg
ICAgICAgIGltZy5jbGFzc0xpc3QucmVtb3ZlKCd0aHVtYi1sb2FkaW5nJyk7CiAgICAgICAgICAgIGlm
ICh3cmFwKSB3cmFwLmNsYXNzTGlzdC5yZW1vdmUoJ3dhaXRpbmcnKTsKICAgICAgICAgICAgaWYgKGlt
Zy5fZmFpbFRpbWVyKSB0cnkgeyBjbGVhclRpbWVvdXQoaW1nLl9mYWlsVGltZXIpOyB9IGNhdGNoIHt9
CiAgICAgICAgfTsKICAgICAgICBjb25zdCBmYWlsVGltZXIgPSBzZXRUaW1lb3V0KCgpID0+IHsKICAg
ICAgICAgICAgaWYgKCFpbWcuc3JjIHx8IGltZy5uYXR1cmFsV2lkdGggPCAxKQogICAgICAgICAgICAg
ICAgaW1nLmFsdCA9ICfml6Dms5XliqDovb0nOwogICAgICAgICAgICBjbGVhcldhaXQoKTsKICAgICAg
ICB9LCAxMjAwMCk7CiAgICAgICAgaW1nLl9mYWlsVGltZXIgPSBmYWlsVGltZXI7CiAgICAgICAgY29u
c3QgcHJldkxvYWQgPSBpbWcub25sb2FkOwogICAgICAgIGltZy5vbmxvYWQgPSBlID0+IHsKICAgICAg
ICAgICAgY2xlYXJXYWl0KCk7CiAgICAgICAgICAgIGltZy5hbHQgPSAnJzsKICAgICAgICAgICAgaWYg
KHR5cGVvZiBwcmV2TG9hZCA9PT0gJ2Z1bmN0aW9uJykgcHJldkxvYWQuY2FsbChpbWcsIGUpOwogICAg
ICAgIH07CiAgICAgICAgY29uc3QgYmFyZSA9IGZpbGUgPyBTdHJpbmcoZmlsZSkuc3BsaXQoL1tcXC9d
LykucG9wKCkgOiAnJzsKICAgICAgICBjb25zdCB0aE5hbWUgPSBiYXJlID8gKCd0aF8nICsgYmFyZS5y
ZXBsYWNlKC9cLlteLl0rJC8sICcnKSArICcuanBnJykgOiAnJzsKICAgICAgICBpbWcub25lcnJvciA9
ICgpID0+IHsKICAgICAgICAgICAgY29uc3Qgc3RlcCA9IE51bWJlcihpbWcuZGF0YXNldC5zdGVwIHx8
IDApOwogICAgICAgICAgICBpZiAoc3RlcCA8IDIgJiYgYmFyZSkgewogICAgICAgICAgICAgICAgaW1n
LmRhdGFzZXQuc3RlcCA9ICcyJzsKICAgICAgICAgICAgICAgIGltZy5zcmMgPSBTVE9SRV9CQVNFICsg
ZW5jb2RlVVJJQ29tcG9uZW50KGJhcmUpOwogICAgICAgICAgICAgICAgcmV0dXJuOwogICAgICAgICAg
ICB9CiAgICAgICAgICAgIGlmIChzdGVwIDwgMyAmJiAodGhOYW1lIHx8IGJhcmUpKSB7CiAgICAgICAg
ICAgICAgICBpbWcuZGF0YXNldC5zdGVwID0gJzMnOwogICAgICAgICAgICAgICAgaW1nLnNyYyA9IFNU
T1JFX0JBU0VfRkFMTEJBQ0sgKyBlbmNvZGVVUklDb21wb25lbnQodGhOYW1lIHx8IGJhcmUpOwogICAg
ICAgICAgICAgICAgcmV0dXJuOwogICAgICAgICAgICB9CiAgICAgICAgICAgIGlmIChzdGVwIDwgNCAm
JiBiYXJlICYmIHRoTmFtZSkgewogICAgICAgICAgICAgICAgaW1nLmRhdGFzZXQuc3RlcCA9ICc0JzsK
ICAgICAgICAgICAgICAgIGltZy5zcmMgPSBTVE9SRV9CQVNFX0ZBTExCQUNLICsgZW5jb2RlVVJJQ29t
cG9uZW50KGJhcmUpOwogICAgICAgICAgICAgICAgcmV0dXJuOwogICAgICAgICAgICB9CiAgICAgICAg
ICAgIC8vIEtlZXAgc2hpbW1lcjsgQUhLIF9fc2V0VGh1bWIgd2lsbCBmaWxsIGluCiAgICAgICAgICAg
IGltZy5yZW1vdmVBdHRyaWJ1dGUoJ3NyYycpOwogICAgICAgICAgICBpbWcuY2xhc3NMaXN0LmFkZCgn
dGh1bWItbG9hZGluZycpOwogICAgICAgICAgICBpZiAod3JhcCkgd3JhcC5jbGFzc0xpc3QuYWRkKCd3
YWl0aW5nJyk7CiAgICAgICAgfTsKICAgICAgICBjb25zdCBjYWNoZWQgPSB0aHVtYkNhY2hlLmdldChT
dHJpbmcoaWQpKTsKICAgICAgICAvLyBBY2NlcHQgZGF0YS1VUkwgb3IgaG9zdCBVUkwgZnJvbSBwcmlv
ciBfX3NldFRodW1iIChyZS1yZW5kZXIgbXVzdCBub3QgZHJvcCBpdCkKICAgICAgICBpZiAoY2FjaGVk
ICYmIFN0cmluZyhjYWNoZWQpLmxlbmd0aCkgewogICAgICAgICAgICBpbWcuZGF0YXNldC5zdGVwID0g
JzknOwogICAgICAgICAgICBpbWcuc3JjID0gU3RyaW5nKGNhY2hlZCk7CiAgICAgICAgICAgIHJldHVy
bjsKICAgICAgICB9CiAgICAgICAgY29uc3QgZGF0YVVybCA9IChmYWxsYmFjayAmJiBTdHJpbmcoZmFs
bGJhY2spLnN0YXJ0c1dpdGgoJ2RhdGE6JykpCiAgICAgICAgICAgID8gU3RyaW5nKGZhbGxiYWNrKSA6
ICcnOwogICAgICAgIGlmIChkYXRhVXJsKSB7CiAgICAgICAgICAgIGltZy5kYXRhc2V0LnN0ZXAgPSAn
OSc7CiAgICAgICAgICAgIGltZy5zcmMgPSBkYXRhVXJsOwogICAgICAgICAgICByZXR1cm47CiAgICAg
ICAgfQogICAgICAgIGlmIChiYXJlKSB7CiAgICAgICAgICAgIC8vIFByZWZlciBsaXN0IHRodW1iIEpQ
RUcgKHNtYWxsKSBvbiBkZWRpY2F0ZWQgc3RvcmUgaG9zdAogICAgICAgICAgICBpbWcuZGF0YXNldC5z
dGVwID0gJzEnOwogICAgICAgICAgICBpbWcuc3JjID0gU1RPUkVfQkFTRSArIGVuY29kZVVSSUNvbXBv
bmVudCh0aE5hbWUgfHwgYmFyZSk7CiAgICAgICAgfSBlbHNlIHsKICAgICAgICAgICAgLy8gTm8gZmls
ZSB5ZXQgKGp1c3QgY29waWVkKSDigJRrZWVwIHNoaW1tZXI7IEluamVjdExpdmVJbWFnZVRodW1iIC8g
X19zZXRUaHVtYiBmaWxscyBpbgogICAgICAgICAgICBpbWcuY2xhc3NMaXN0LmFkZCgndGh1bWItbG9h
ZGluZycpOwogICAgICAgICAgICBpZiAod3JhcCkgd3JhcC5jbGFzc0xpc3QuYWRkKCd3YWl0aW5nJyk7
CiAgICAgICAgfQogICAgfQoKICAgIHdpbmRvdy5fX3NldFRodW1iID0gKGlkLCB1cmwpID0+IHsKICAg
ICAgICBpZiAoIXVybCkgcmV0dXJuOwogICAgICAgIGNvbnN0IGtleSA9IFN0cmluZyhpZCk7CiAgICAg
ICAgdGh1bWJDYWNoZS5zZXQoa2V5LCB1cmwpOwogICAgICAgIGNvbnN0IGFwcGx5ID0gaW1nID0+IHsK
ICAgICAgICAgICAgaWYgKGltZy5fZmFpbFRpbWVyKSB0cnkgeyBjbGVhclRpbWVvdXQoaW1nLl9mYWls
VGltZXIpOyB9IGNhdGNoIHt9CiAgICAgICAgICAgIGltZy5vbmVycm9yID0gbnVsbDsKICAgICAgICAg
ICAgaW1nLmFsdCA9ICcnOwogICAgICAgICAgICBpbWcuY2xhc3NMaXN0LnJlbW92ZSgndGh1bWItbG9h
ZGluZycpOwogICAgICAgICAgICBjb25zdCB3cmFwID0gaW1nLnBhcmVudEVsZW1lbnQ7CiAgICAgICAg
ICAgIGlmICh3cmFwKSB3cmFwLmNsYXNzTGlzdC5yZW1vdmUoJ3dhaXRpbmcnKTsKICAgICAgICAgICAg
aW1nLnNyYyA9IHVybDsKICAgICAgICB9OwogICAgICAgIGxldCBoaXQgPSAwOwogICAgICAgIGRvY3Vt
ZW50LnF1ZXJ5U2VsZWN0b3JBbGwoJy5pdG1bZGF0YS1pZD0iJyArIGtleSArICciXSBpbWcuaS10aHVt
YicpLmZvckVhY2goaW1nID0+IHsKICAgICAgICAgICAgYXBwbHkoaW1nKTsgaGl0Kys7CiAgICAgICAg
fSk7CiAgICAgICAgaWYgKCFoaXQpIHsKICAgICAgICAgICAgZG9jdW1lbnQucXVlcnlTZWxlY3RvckFs
bCgnaW1nLmktdGh1bWJbZGF0YS10aHVtYi1pZD0iJyArIGtleSArICciXScpLmZvckVhY2goYXBwbHkp
OwogICAgICAgIH0KICAgIH07CgogICAgZnVuY3Rpb24gaXNEcmFnRXhjbHVkZSh0KSB7CiAgICAgICAg
cmV0dXJuICEhdC5jbG9zZXN0KCcjc2VhcmNoLXdyYXAsICNidG4tc2VhcmNoLCAjYnRuLWxvY2F0ZSwg
I2J0bi10b2RheSwgI2J0bi1waW4sICNidG4tY2xyLCAjbXVsdGktY250LCAudGFiLCAuaXRtLCAjdGFi
LWFjdGlvbnMsICNjdHgsICNjbHItZGxnLCAjcGF0aC10aXAsIGJ1dHRvbiwgaW5wdXQsIGEnKTsKICAg
IH0KICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdhcHAnKS5hZGRFdmVudExpc3RlbmVyKCdtb3Vz
ZWRvd24nLCBlID0+IHsKICAgICAgICBpZiAoZS5idXR0b24gIT09IDApIHJldHVybjsKICAgICAgICBp
ZiAoaXNEcmFnRXhjbHVkZShlLnRhcmdldCkpIHJldHVybjsKICAgICAgICBlLnByZXZlbnREZWZhdWx0
KCk7CiAgICAgICAgYWhrKCdzdGFydERyYWcnKTsKICAgIH0sIHRydWUpOwoKICAgIGNvbnN0IGlzVXJs
ICA9IHMgPT4gL15odHRwcz86XC9cLy9pLnRlc3QoKHMgfHwgJycpLnRyaW0oKSk7CgogICAgZnVuY3Rp
b24gYWdvKGRhdGVTdHIpIHsKICAgICAgICB0cnkgewogICAgICAgICAgICBjb25zdCBkID0gbmV3IERh
dGUoU3RyaW5nKGRhdGVTdHIpLnJlcGxhY2UoJyAnLCAnVCcpKTsKICAgICAgICAgICAgY29uc3QgcyA9
IChEYXRlLm5vdygpIC0gZCkgLyAxMDAwIHwgMDsKICAgICAgICAgICAgaWYgKHMgPCA2MCkgcmV0dXJu
ICfliJrliJonOwogICAgICAgICAgICBpZiAocyA8IDM2MDApIHJldHVybiAocyAvIDYwIHwgMCkgKyAn
IOWIhumSn+WJjSc7CiAgICAgICAgICAgIGlmIChzIDwgODY0MDApIHJldHVybiAocyAvIDM2MDAgfCAw
KSArICcg5bCP5pe25YmNJzsKICAgICAgICAgICAgcmV0dXJuIChzIC8gODY0MDAgfCAwKSArICcg5aSp
5YmNJzsKICAgICAgICB9IGNhdGNoIHsgcmV0dXJuIGRhdGVTdHI7IH0KICAgIH0KCiAgICBmdW5jdGlv
biBub3JtVHlwZSh0KSB7CiAgICAgICAgdCA9IFN0cmluZyh0IHx8ICcnKS50b0xvd2VyQ2FzZSgpOwog
ICAgICAgIGlmICh0ID09PSAnaW1hZ2UnIHx8IHQgPT09ICdpbWcnIHx8IHQgPT09ICdiaXRtYXAnKSBy
ZXR1cm4gJ2ltYWdlJzsKICAgICAgICBpZiAodCA9PT0gJ2ZpbGUnICB8fCB0ID09PSAnZmlsZXMnKSBy
ZXR1cm4gJ2ZpbGUnOwogICAgICAgIGlmICh0ID09PSAncmVjZW50JyB8fCB0ID09PSAnZm9sZGVyJyB8
fCB0ID09PSAnZGlyJykgcmV0dXJuICdyZWNlbnQnOwogICAgICAgIGlmICh0ID09PSAnbGluaycgfHwg
dCA9PT0gJ3VybCcpIHJldHVybiAnbGluayc7CiAgICAgICAgcmV0dXJuICd0ZXh0JzsKICAgIH0KICAg
IGZ1bmN0aW9uIGlzUGlubmVkKGMpIHsKICAgICAgICByZXR1cm4gYy5waW5uZWQgPT09IHRydWUgfHwg
Yy5waW5uZWQgPT09IDEgfHwgYy5waW5uZWQgPT09ICd0cnVlJyB8fCBjLnBpbm5lZCA9PT0gJzEnOwog
ICAgfQogICAgZnVuY3Rpb24gaXNQYXN0ZWQoYykgewogICAgICAgIHJldHVybiBjLnBhc3RlZCA9PT0g
dHJ1ZSB8fCBjLnBhc3RlZCA9PT0gMSB8fCBjLnBhc3RlZCA9PT0gJ3RydWUnIHx8IGMucGFzdGVkID09
PSAnMSc7CiAgICB9CgogICAgZnVuY3Rpb24gaXNNYXJrZG93bih0ZXh0KSB7CiAgICAgICAgaWYgKCF0
ZXh0IHx8IHRleHQubGVuZ3RoIDwgNCkgcmV0dXJuIGZhbHNlOwogICAgICAgIHJldHVybiAvKD86Xnxc
bikjezEsNn0gfF5bLSorXSB8XCpcKlteKlxuXStcKlwqfF9fW15fXG5dK19ffCg/Ol58XG4pPiB8YGBg
fGBbXmBcbl0rYHxcW1teXF1dK1xdXChbXildK1wpfFx8LitcfC4rXHwvbS50ZXN0KHRleHQpOwogICAg
fQogICAgZnVuY3Rpb24gY2xpcFVzZXNNSWNvbihjKSB7CiAgICAgICAgaWYgKCFjKSByZXR1cm4gZmFs
c2U7CiAgICAgICAgaWYgKGMuaXNNZCA9PT0gdHJ1ZSB8fCBjLmlzTWQgPT09IDEgfHwgYy5pc01kID09
PSAndHJ1ZScgfHwgYy5pc01kID09PSAnMScpIHJldHVybiB0cnVlOwogICAgICAgIGlmIChjLmlzUmlj
aCA9PT0gdHJ1ZSB8fCBjLmlzUmljaCA9PT0gMSB8fCBjLmlzUmljaCA9PT0gJ3RydWUnIHx8IGMuaXNS
aWNoID09PSAnMScpIHJldHVybiB0cnVlOwogICAgICAgIGNvbnN0IHQgPSBTdHJpbmcoYy50eXBlIHx8
ICcnKS50b0xvd2VyQ2FzZSgpOwogICAgICAgIGlmICh0ICYmIHQgIT09ICd0ZXh0JyAmJiB0ICE9PSAn
bGluaycpIHJldHVybiBmYWxzZTsKICAgICAgICByZXR1cm4gaXNNYXJrZG93bihjLmRhdGEgfHwgYy5w
cmV2aWV3IHx8ICcnKTsKICAgIH0KICAgIGZ1bmN0aW9uIGVzY0F0dHIocykgewogICAgICAgIHJldHVy
biBTdHJpbmcocyB8fCAnJykKICAgICAgICAgICAgLnJlcGxhY2UoLyYvZywgJyZhbXA7JykKICAgICAg
ICAgICAgLnJlcGxhY2UoLyIvZywgJyZxdW90OycpCiAgICAgICAgICAgIC5yZXBsYWNlKC88L2csICcm
bHQ7JykKICAgICAgICAgICAgLnJlcGxhY2UoLz4vZywgJyZndDsnKTsKICAgIH0KCiAgICBmdW5jdGlv
biB0b2RheVByZWZpeCgpIHsKICAgICAgICBjb25zdCBkID0gbmV3IERhdGUoKTsKICAgICAgICBjb25z
dCBwID0gbiA9PiBTdHJpbmcobikucGFkU3RhcnQoMiwgJzAnKTsKICAgICAgICByZXR1cm4gZC5nZXRG
dWxsWWVhcigpICsgJy0nICsgcChkLmdldE1vbnRoKCkgKyAxKSArICctJyArIHAoZC5nZXREYXRlKCkp
OwogICAgfQogICAgZnVuY3Rpb24gaXNUb2RheUNsaXAoYykgewogICAgICAgIHJldHVybiBTdHJpbmco
Yy50aW1lIHx8ICcnKS5zdGFydHNXaXRoKHRvZGF5UHJlZml4KCkpOwogICAgfQoKICAgIGZ1bmN0aW9u
IGNsaXBIYXkoYykgewogICAgICAgIHJldHVybiBTdHJpbmcoYy5wcmV2aWV3IHx8ICcnKSArICcgJyAr
IFN0cmluZyhjLmRhdGEgfHwgJycpICsgJyAnCiAgICAgICAgICAgICsgU3RyaW5nKGMubGlua1RpdGxl
IHx8ICcnKSArICcgJyArIFN0cmluZyhjLmZhdlRpdGxlIHx8ICcnKTsKICAgIH0KICAgIC8qKiBNYXRj
aCBBSEsgSXRlbU1hdGNoZXNWaWV3IGxpc3Qgc2VhcmNoIOKAlCBwcmV2aWV3ICgrIHNob3J0IGJvZHkg
ZmFsbGJhY2spLCBub3QgZnVsbCBkYXRhICovCiAgICBmdW5jdGlvbiBjbGlwU2VhcmNoSGF5KGMpIHsK
ICAgICAgICBjb25zdCB0eXBlID0gU3RyaW5nKGMudHlwZSB8fCAnJykudG9Mb3dlckNhc2UoKTsKICAg
ICAgICBpZiAodHlwZSA9PT0gJ2ltYWdlJykKICAgICAgICAgICAgcmV0dXJuIFN0cmluZyhjLmZhdlRp
dGxlIHx8ICcnKTsKICAgICAgICBpZiAodHlwZSA9PT0gJ2ZpbGUnKSB7CiAgICAgICAgICAgIHJldHVy
biBTdHJpbmcoYy5wcmV2aWV3IHx8ICcnKSArICcgJyArIFN0cmluZyhjLmRhdGEgfHwgJycpICsgJyAn
CiAgICAgICAgICAgICAgICArIFN0cmluZyhjLmZhdlRpdGxlIHx8ICcnKTsKICAgICAgICB9CiAgICAg
ICAgbGV0IHByZXYgPSBTdHJpbmcoYy5wcmV2aWV3IHx8ICcnKTsKICAgICAgICBpZiAoIXByZXYgJiYg
Yy5kYXRhKQogICAgICAgICAgICBwcmV2ID0gU3RyaW5nKGMuZGF0YSkuc2xpY2UoMCwgNTAwKTsKICAg
ICAgICByZXR1cm4gcHJldiArICcgJyArIFN0cmluZyhjLmxpbmtUaXRsZSB8fCAnJykgKyAnICcgKyBT
dHJpbmcoYy5mYXZUaXRsZSB8fCAnJyk7CiAgICB9CiAgICBmdW5jdGlvbiBjbGlwTWF0Y2hlc1NlYXJj
aChjLCB0ZXJtTCkgewogICAgICAgIGNvbnN0IHR5cGUgPSBTdHJpbmcoYy50eXBlIHx8ICcnKS50b0xv
d2VyQ2FzZSgpOwogICAgICAgIGNvbnN0IGhheSA9ICh0eXBlID09PSAnaW1hZ2UnID8gU3RyaW5nKGMu
ZmF2VGl0bGUgfHwgJycpIDogY2xpcFNlYXJjaEhheShjKSkudG9Mb3dlckNhc2UoKTsKICAgICAgICBy
ZXR1cm4gdGVybUwuZXZlcnkodCA9PiBoYXkuaW5jbHVkZXModCkpOwogICAgfQogICAgZnVuY3Rpb24g
ZmlsdGVyKGNsaXBzLCB0YWIsIHEpIHsKICAgICAgICAvLyDkuLvmnLrlt7Lov4fmu6Tml7bku43lgZrl
iY3nq6/lhZzlupXvvJrpgb/lhY3nq57mgIHmjqjmnaXmnKrlkb3kuK3ooYwKICAgICAgICBjb25zdCB0
ZXJtcyA9IHF1ZXJ5VGVybXMocSk7CiAgICAgICAgaWYgKCF0ZXJtcy5sZW5ndGgpIHJldHVybiBjbGlw
czsKICAgICAgICBjb25zdCB0ZXJtTCA9IHRlcm1zLm1hcCh0ID0+IHQudG9Mb3dlckNhc2UoKSk7CiAg
ICAgICAgY29uc3QgbWF0Y2hlZEdyb3VwcyA9IG5ldyBTZXQoKTsKICAgICAgICBmb3IgKGNvbnN0IGMg
b2YgY2xpcHMpIHsKICAgICAgICAgICAgaWYgKCFjbGlwTWF0Y2hlc1NlYXJjaChjLCB0ZXJtTCkpIGNv
bnRpbnVlOwogICAgICAgICAgICBjb25zdCBnaWQgPSBTdHJpbmcoYyAmJiBjLmZhdkdyb3VwIHx8ICcn
KS50cmltKCk7CiAgICAgICAgICAgIGlmIChnaWQpIG1hdGNoZWRHcm91cHMuYWRkKGdpZCk7CiAgICAg
ICAgfQogICAgICAgIC8vIOWQiOW5tue7hO+8muWFs+mUruWtl+WPr+iDveWIhuaVo+WcqOS4jeWQjOih
jO+8iOagh+mimC/mraPmlofvvIkKICAgICAgICBjb25zdCBieUdyb3VwID0gbmV3IE1hcCgpOwogICAg
ICAgIGZvciAoY29uc3QgYyBvZiBjbGlwcykgewogICAgICAgICAgICBjb25zdCBnaWQgPSBTdHJpbmco
YyAmJiBjLmZhdkdyb3VwIHx8ICcnKS50cmltKCk7CiAgICAgICAgICAgIGlmICghZ2lkKSBjb250aW51
ZTsKICAgICAgICAgICAgaWYgKCFieUdyb3VwLmhhcyhnaWQpKSBieUdyb3VwLnNldChnaWQsIFtdKTsK
ICAgICAgICAgICAgYnlHcm91cC5nZXQoZ2lkKS5wdXNoKGMpOwogICAgICAgIH0KICAgICAgICBmb3Ig
KGNvbnN0IFtnaWQsIG1lbWJlcnNdIG9mIGJ5R3JvdXApIHsKICAgICAgICAgICAgaWYgKG1hdGNoZWRH
cm91cHMuaGFzKGdpZCkpIGNvbnRpbnVlOwogICAgICAgICAgICBjb25zdCB1bmlvbiA9IG1lbWJlcnMu
bWFwKGMgPT4gewogICAgICAgICAgICAgICAgY29uc3QgdHlwZSA9IFN0cmluZyhjLnR5cGUgfHwgJycp
LnRvTG93ZXJDYXNlKCk7CiAgICAgICAgICAgICAgICByZXR1cm4gKHR5cGUgPT09ICdpbWFnZScgPyBT
dHJpbmcoYy5mYXZUaXRsZSB8fCAnJykgOiBjbGlwU2VhcmNoSGF5KGMpKS50b0xvd2VyQ2FzZSgpOwog
ICAgICAgICAgICB9KS5qb2luKCcgJyk7CiAgICAgICAgICAgIGlmICh0ZXJtTC5ldmVyeSh0ID0+IHVu
aW9uLmluY2x1ZGVzKHQpKSkKICAgICAgICAgICAgICAgIG1hdGNoZWRHcm91cHMuYWRkKGdpZCk7CiAg
ICAgICAgfQogICAgICAgIHJldHVybiBjbGlwcy5maWx0ZXIoYyA9PiB7CiAgICAgICAgICAgIGlmIChj
bGlwTWF0Y2hlc1NlYXJjaChjLCB0ZXJtTCkpIHJldHVybiB0cnVlOwogICAgICAgICAgICBjb25zdCBn
aWQgPSBTdHJpbmcoYyAmJiBjLmZhdkdyb3VwIHx8ICcnKS50cmltKCk7CiAgICAgICAgICAgIHJldHVy
biBnaWQgJiYgbWF0Y2hlZEdyb3Vwcy5oYXMoZ2lkKTsKICAgICAgICB9KTsKICAgIH0KCiAgICBmdW5j
dGlvbiBtYXJrUGFzdGVkTG9jYWwoaWRzKSB7CiAgICAgICAgY29uc3QgbGlzdCA9IEFycmF5LmlzQXJy
YXkoaWRzKSA/IGlkcyA6IFtpZHNdOwogICAgICAgIGlmIChsaXN0Lmxlbmd0aCkKICAgICAgICAgICAg
cmVtZW1iZXJMYXN0UGFzdGUobGlzdFtsaXN0Lmxlbmd0aCAtIDFdKTsKICAgICAgICBjb25zdCBiYWRn
ZUh0bWwgPSBgPHN2ZyB2aWV3Qm94PSIwIDAgMTYgMTYiIGZpbGw9Im5vbmUiIHN0cm9rZT0iY3VycmVu
dENvbG9yIiBzdHJva2Utd2lkdGg9IjIuNCIgc3Ryb2tlLWxpbmVjYXA9InJvdW5kIiBzdHJva2UtbGlu
ZWpvaW49InJvdW5kIj48cG9seWxpbmUgcG9pbnRzPSIzLjUgOC41IDYuNSAxMS41IDEyLjUgNC41Ii8+
PC9zdmc+YDsKICAgICAgICBsaXN0LmZvckVhY2gocmF3SWQgPT4gewogICAgICAgICAgICBjb25zdCBp
ZCA9ICtyYXdJZDsKICAgICAgICAgICAgY29uc3QgYyA9IGFsbENsaXBzLmZpbmQoeCA9PiAreC5pZCA9
PT0gaWQpOwogICAgICAgICAgICBpZiAoYykgYy5wYXN0ZWQgPSB0cnVlOwogICAgICAgICAgICBjb25z
dCByb3cgPSBsaXN0RWwgJiYgKAogICAgICAgICAgICAgICAgbGlzdEVsLnF1ZXJ5U2VsZWN0b3IoJy5p
dG1bZGF0YS1pZD0iJyArIGlkICsgJyJdJykKICAgICAgICAgICAgICAgIHx8IGxpc3RFbC5xdWVyeVNl
bGVjdG9yKCcuaXRtW2RhdGEtaWQ9IicgKyBTdHJpbmcocmF3SWQpICsgJyJdJykKICAgICAgICAgICAg
KTsKICAgICAgICAgICAgaWYgKCFyb3cpIHJldHVybjsKICAgICAgICAgICAgcm93LmNsYXNzTGlzdC5h
ZGQoJ3Bhc3RlZCcsICdxLWRvbmUnKTsKICAgICAgICAgICAgY29uc3QgaWNvID0gcm93LnF1ZXJ5U2Vs
ZWN0b3IoJy5pLWljbycpOwogICAgICAgICAgICBpZiAoaWNvICYmICFpY28ucXVlcnlTZWxlY3Rvcign
LmktdXNlZCcpKSB7CiAgICAgICAgICAgICAgICBjb25zdCBiYWRnZSA9IGRvY3VtZW50LmNyZWF0ZUVs
ZW1lbnQoJ3NwYW4nKTsKICAgICAgICAgICAgICAgIGJhZGdlLmNsYXNzTmFtZSA9ICdpLXVzZWQnOwog
ICAgICAgICAgICAgICAgYmFkZ2UudGl0bGUgPSAn5bey57KY6LS0JzsKICAgICAgICAgICAgICAgIGJh
ZGdlLmlubmVySFRNTCA9IGJhZGdlSHRtbDsKICAgICAgICAgICAgICAgIGljby5hcHBlbmRDaGlsZChi
YWRnZSk7CiAgICAgICAgICAgIH0KICAgICAgICB9KTsKICAgICAgICB0cnkgeyBtYXJrUXVldWVSYWls
cygpOyB9IGNhdGNoIChlKSB7fQogICAgfQogICAgd2luZG93Ll9fbWFya1Bhc3RlZCA9IG1hcmtQYXN0
ZWRMb2NhbDsKCiAgICBmdW5jdGlvbiBtYXJrVW5wYXN0ZWRMb2NhbChpZHMpIHsKICAgICAgICBjb25z
dCBsaXN0ID0gQXJyYXkuaXNBcnJheShpZHMpID8gaWRzIDogW2lkc107CiAgICAgICAgbGlzdC5mb3JF
YWNoKHJhd0lkID0+IHsKICAgICAgICAgICAgY29uc3QgaWQgPSArcmF3SWQ7CiAgICAgICAgICAgIGNv
bnN0IGMgPSBhbGxDbGlwcy5maW5kKHggPT4gK3guaWQgPT09IGlkKTsKICAgICAgICAgICAgaWYgKGMp
IGMucGFzdGVkID0gZmFsc2U7CiAgICAgICAgICAgIGNvbnN0IHJvdyA9IGxpc3RFbCAmJiAoCiAgICAg
ICAgICAgICAgICBsaXN0RWwucXVlcnlTZWxlY3RvcignLml0bVtkYXRhLWlkPSInICsgaWQgKyAnIl0n
KQogICAgICAgICAgICAgICAgfHwgbGlzdEVsLnF1ZXJ5U2VsZWN0b3IoJy5pdG1bZGF0YS1pZD0iJyAr
IFN0cmluZyhyYXdJZCkgKyAnIl0nKQogICAgICAgICAgICApOwogICAgICAgICAgICBpZiAoIXJvdykg
cmV0dXJuOwogICAgICAgICAgICByb3cuY2xhc3NMaXN0LnJlbW92ZSgncGFzdGVkJywgJ3EtZG9uZScs
ICdxLWRvbmUtbGluaycpOwogICAgICAgICAgICBjb25zdCBiYWRnZSA9IHJvdy5xdWVyeVNlbGVjdG9y
KCcuaS11c2VkJyk7CiAgICAgICAgICAgIGlmIChiYWRnZSkgYmFkZ2UucmVtb3ZlKCk7CiAgICAgICAg
ICAgIGNvbnN0IGRvdCA9IHJvdy5xdWVyeVNlbGVjdG9yKCcucS1kb3QnKTsKICAgICAgICAgICAgaWYg
KGRvdCkgZG90LnRpdGxlID0gJ+eymOi0tOmYn+WIlyc7CiAgICAgICAgfSk7CiAgICAgICAgdHJ5IHsg
bWFya1F1ZXVlUmFpbHMoKTsgfSBjYXRjaCAoZSkge30KICAgIH0KICAgIHdpbmRvdy5fX21hcmtVbnBh
c3RlZCA9IG1hcmtVbnBhc3RlZExvY2FsOwoKICAgIGNvbnN0IGxpc3RFbCAgPSBkb2N1bWVudC5nZXRF
bGVtZW50QnlJZCgnbGlzdCcpOwogICAgY29uc3QgZW1wdHlFbCA9IGRvY3VtZW50LmdldEVsZW1lbnRC
eUlkKCdlbXB0eScpOwogICAgY29uc3Qgc2tlbEVsICA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdz
a2VsJyk7CiAgICBjb25zdCBidG5Ub3AgID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2J0bi10b3An
KTsKICAgIGZ1bmN0aW9uIHNldEJvb3RMb2FkaW5nKG9uKSB7CiAgICAgICAgYm9vdExvYWRpbmcgPSAh
IW9uOwogICAgICAgIC8vIOenkuW8gO+8muS4jeWGjeaJk+W8gOmqqOaetumXquWKqO+8m+WPquS/neeV
mSB3YWl0aW5nRGF0YSDpgLvovpHpmLLnqbrmgIHor6/pl6oKICAgICAgICBpZiAoc2tlbEVsKSBza2Vs
RWwuY2xhc3NMaXN0LnJlbW92ZSgnb24nKTsKICAgICAgICBpZiAob24gJiYgZW1wdHlFbCkgZW1wdHlF
bC5jbGFzc0xpc3QucmVtb3ZlKCdvbicpOwogICAgICAgIGNvbnN0IGFwcCA9IGRvY3VtZW50LmdldEVs
ZW1lbnRCeUlkKCdhcHAnKTsKICAgICAgICBpZiAoYXBwKSBhcHAuY2xhc3NMaXN0LnJlbW92ZSgnYm9v
dC1sb2FkaW5nJyk7CiAgICB9CiAgICAvKiogV2FpdCBmb3IgaG9zdCBkYXRhIOKAlOS4jeWGjeeri+WI
u+W8uemqqOaetu+8jOacieWGheWuueaXtuS/neaMgeaXp+WIl+ihqCAqLwogICAgZnVuY3Rpb24gc2No
ZWR1bGVEZWxheWVkU2tlbCgpIHsKICAgICAgICB3YWl0aW5nRGF0YSA9IHRydWU7CiAgICAgICAgd2lu
ZG93Ll9fZGF0YVJlYWR5ID0gZmFsc2U7CiAgICAgICAgaWYgKGVtcHR5RWwpIGVtcHR5RWwuY2xhc3NM
aXN0LnJlbW92ZSgnb24nKTsKICAgICAgICBpZiAod2luZG93Ll9fcGVuZGluZ1NrZWxUaW1lcikgewog
ICAgICAgICAgICBjbGVhclRpbWVvdXQod2luZG93Ll9fcGVuZGluZ1NrZWxUaW1lcik7CiAgICAgICAg
ICAgIHdpbmRvdy5fX3BlbmRpbmdTa2VsVGltZXIgPSAwOwogICAgICAgIH0KICAgICAgICB3aW5kb3cu
X19wZW5kaW5nU2tlbFNpbmNlID0gRGF0ZS5ub3coKTsKICAgICAgICAvLyDmnInml6fliJfooajlsLHk
v53nlZnvvJvnqbrliJfooajkuZ/kuI3lho3mkq3pqqjmnrbliqjnlLsKICAgIH0KICAgIGZ1bmN0aW9u
IGNsZWFyV2FpdGluZ0RhdGEoKSB7CiAgICAgICAgd2FpdGluZ0RhdGEgPSBmYWxzZTsKICAgICAgICBp
ZiAod2luZG93Ll9fcGVuZGluZ1NrZWxUaW1lcikgewogICAgICAgICAgICBjbGVhclRpbWVvdXQod2lu
ZG93Ll9fcGVuZGluZ1NrZWxUaW1lcik7CiAgICAgICAgICAgIHdpbmRvdy5fX3BlbmRpbmdTa2VsVGlt
ZXIgPSAwOwogICAgICAgIH0KICAgICAgICB3aW5kb3cuX19wZW5kaW5nU2tlbFNpbmNlID0gMDsKICAg
ICAgICBzZXRCb290TG9hZGluZyhmYWxzZSk7CiAgICB9CiAgICB3aW5kb3cuc2V0Qm9vdExvYWRpbmcg
PSBzZXRCb290TG9hZGluZzsKICAgIHdpbmRvdy5mb3JjZUVuZEJvb3RMb2FkaW5nID0gZnVuY3Rpb24o
KSB7CiAgICAgICAgY2xlYXJXYWl0aW5nRGF0YSgpOwogICAgICAgIC8vIERvIG5vdCBmYWtl44CM5pqC
5peg6K6w5b2V44CNaWYgaG9zdCBuZXZlciBwdXNoZWQKICAgICAgICBpZiAoaG9zdFB1c2hlZE9uY2Up
CiAgICAgICAgICAgIHdpbmRvdy5fX2RhdGFSZWFkeSA9IHRydWU7CiAgICAgICAgdHJ5IHsgcmVuZGVy
KCk7IH0gY2F0Y2ggKGUpIHt9CiAgICB9OwogICAgLy8gU2FmZXR5OiBkcm9wIHN0dWNrIHNrZWxldG9u
OyBzdGlsbCBuZXZlciBpbnZlbnQgZW1wdHktc3RhdGUgd2l0aG91dCBob3N0IHB1c2gKICAgIHNldFRp
bWVvdXQoKCkgPT4gewogICAgICAgIGlmIChob3N0UHVzaGVkT25jZSB8fCB3aW5kb3cuX19kYXRhUmVh
ZHkpIHJldHVybjsKICAgICAgICBpZiAoIWJvb3RMb2FkaW5nICYmICF3YWl0aW5nRGF0YSkgcmV0dXJu
OwogICAgICAgIGNsZWFyV2FpdGluZ0RhdGEoKTsKICAgICAgICB0cnkgeyByZW5kZXIoKTsgfSBjYXRj
aCB7fQogICAgfSwgODAwMCk7CgogICAgZnVuY3Rpb24gdXBkYXRlVG9wQnRuKCkgewogICAgICAgIGlm
ICghYnRuVG9wIHx8ICFsaXN0RWwpIHJldHVybjsKICAgICAgICBidG5Ub3AuY2xhc3NMaXN0LnRvZ2ds
ZSgnb24nLCBsaXN0RWwuc2Nyb2xsVG9wID4gNDgpOwogICAgfQogICAgbGV0IF9zY3JvbGxSYWYgPSAw
OwogICAgbGV0IF9zY3JvbGxJZGxlVCA9IDA7CiAgICBsZXQgX2xpc3RQdHJEb3duID0gZmFsc2U7CiAg
ICBsZXQgX3BlbmRpbmdBcHBlbmQgPSBudWxsOyAvLyB7IGZyb21MZW4gfSBxdWV1ZWQgd2hpbGUgc2Ny
b2xsaW5nCiAgICB3aW5kb3cuX19zY3JvbGxCdXN5ID0gZmFsc2U7CiAgICB3aW5kb3cuX193YW50TW9y
ZSA9IGZhbHNlOwoKICAgIGZ1bmN0aW9uIG1hcmtMaXN0U2Nyb2xsaW5nKCkgewogICAgICAgIHdpbmRv
dy5fX3Njcm9sbEJ1c3kgPSB0cnVlOwogICAgICAgIHRyeSB7IGxpc3RFbC5jbGFzc0xpc3QuYWRkKCdp
cy1zY3JvbGxpbmcnKTsgfSBjYXRjaCB7fQogICAgICAgIGlmIChfc2Nyb2xsSWRsZVQpIGNsZWFyVGlt
ZW91dChfc2Nyb2xsSWRsZVQpOwogICAgICAgIF9zY3JvbGxJZGxlVCA9IHNldFRpbWVvdXQoKCkgPT4g
ewogICAgICAgICAgICBfc2Nyb2xsSWRsZVQgPSAwOwogICAgICAgICAgICBmbHVzaFNjcm9sbElkbGUo
KTsKICAgICAgICB9LCAyMjApOwogICAgfQoKICAgIGZ1bmN0aW9uIGZsdXNoU2Nyb2xsSWRsZSgpIHsK
ICAgICAgICBpZiAoX2xpc3RQdHJEb3duKSB7CiAgICAgICAgICAgIG1hcmtMaXN0U2Nyb2xsaW5nKCk7
CiAgICAgICAgICAgIHJldHVybjsKICAgICAgICB9CiAgICAgICAgd2luZG93Ll9fc2Nyb2xsQnVzeSA9
IGZhbHNlOwogICAgICAgIHRyeSB7IGxpc3RFbC5jbGFzc0xpc3QucmVtb3ZlKCdpcy1zY3JvbGxpbmcn
KTsgfSBjYXRjaCB7fQogICAgICAgIGlmIChfcGVuZGluZ0FwcGVuZCkgewogICAgICAgICAgICBjb25z
dCBwZW5kaW5nID0gX3BlbmRpbmdBcHBlbmQ7CiAgICAgICAgICAgIF9wZW5kaW5nQXBwZW5kID0gbnVs
bDsKICAgICAgICAgICAgYXBwbHlBcHBlbmRQYXlsb2FkKHBlbmRpbmcpOwogICAgICAgIH0KICAgICAg
ICBpZiAod2luZG93Ll9fd2FudE1vcmUpCiAgICAgICAgICAgIHJlcXVlc3RNb3JlKCk7CiAgICAgICAg
ZWxzZSBpZiAoIWxvYWRpbmdNb3JlCiAgICAgICAgICAgICYmIGRpc2tUb3RhbCA+IDAKICAgICAgICAg
ICAgJiYgYWxsQ2xpcHMubGVuZ3RoIDwgZGlza1RvdGFsCiAgICAgICAgICAgICYmIGxpc3RFbC5zY3Jv
bGxUb3AgKyBsaXN0RWwuY2xpZW50SGVpZ2h0ID49IGxpc3RFbC5zY3JvbGxIZWlnaHQgLSA0MjApCiAg
ICAgICAgICAgIHJlcXVlc3RNb3JlKCk7CiAgICB9CgogICAgZnVuY3Rpb24gb25MaXN0U2Nyb2xsKCkg
ewogICAgICAgIG1hcmtMaXN0U2Nyb2xsaW5nKCk7CiAgICAgICAgaWYgKF9zY3JvbGxSYWYpIHJldHVy
bjsKICAgICAgICBfc2Nyb2xsUmFmID0gcmVxdWVzdEFuaW1hdGlvbkZyYW1lKCgpID0+IHsKICAgICAg
ICAgICAgX3Njcm9sbFJhZiA9IDA7CiAgICAgICAgICAgIHRyeSB7IGhpZGVQYXRoVGlwKCk7IH0gY2F0
Y2gge30KICAgICAgICAgICAgdXBkYXRlVG9wQnRuKCk7CiAgICAgICAgICAgIGlmICghbG9hZGluZ01v
cmUKICAgICAgICAgICAgICAgICYmIGRpc2tUb3RhbCA+IDAKICAgICAgICAgICAgICAgICYmIGFsbENs
aXBzLmxlbmd0aCA8IGRpc2tUb3RhbAogICAgICAgICAgICAgICAgJiYgbGlzdEVsLnNjcm9sbFRvcCAr
IGxpc3RFbC5jbGllbnRIZWlnaHQgPj0gbGlzdEVsLnNjcm9sbEhlaWdodCAtIDI0MCkKICAgICAgICAg
ICAgICAgIHdpbmRvdy5fX3dhbnRNb3JlID0gdHJ1ZTsKICAgICAgICB9KTsKICAgIH0KICAgIGxpc3RF
bC5hZGRFdmVudExpc3RlbmVyKCdzY3JvbGwnLCBvbkxpc3RTY3JvbGwsIHsgcGFzc2l2ZTogdHJ1ZSB9
KTsKICAgIGxpc3RFbC5hZGRFdmVudExpc3RlbmVyKCd3aGVlbCcsIG1hcmtMaXN0U2Nyb2xsaW5nLCB7
IHBhc3NpdmU6IHRydWUgfSk7CiAgICBsaXN0RWwuYWRkRXZlbnRMaXN0ZW5lcigncG9pbnRlcmRvd24n
LCBlID0+IHsKICAgICAgICBpZiAoZS5idXR0b24gIT09IDApIHJldHVybjsKICAgICAgICBfbGlzdFB0
ckRvd24gPSB0cnVlOwogICAgICAgIG1hcmtMaXN0U2Nyb2xsaW5nKCk7CiAgICB9LCB7IHBhc3NpdmU6
IHRydWUgfSk7CiAgICB3aW5kb3cuYWRkRXZlbnRMaXN0ZW5lcigncG9pbnRlcnVwJywgKCkgPT4gewog
ICAgICAgIGlmICghX2xpc3RQdHJEb3duKSByZXR1cm47CiAgICAgICAgX2xpc3RQdHJEb3duID0gZmFs
c2U7CiAgICAgICAgbWFya0xpc3RTY3JvbGxpbmcoKTsKICAgIH0sIHsgcGFzc2l2ZTogdHJ1ZSB9KTsK
ICAgIHdpbmRvdy5hZGRFdmVudExpc3RlbmVyKCdwb2ludGVyY2FuY2VsJywgKCkgPT4gewogICAgICAg
IGlmICghX2xpc3RQdHJEb3duKSByZXR1cm47CiAgICAgICAgX2xpc3RQdHJEb3duID0gZmFsc2U7CiAg
ICAgICAgbWFya0xpc3RTY3JvbGxpbmcoKTsKICAgIH0sIHsgcGFzc2l2ZTogdHJ1ZSB9KTsKICAgIGJ0
blRvcC5hZGRFdmVudExpc3RlbmVyKCdjbGljaycsIGUgPT4gewogICAgICAgIGUuc3RvcFByb3BhZ2F0
aW9uKCk7CiAgICAgICAgbGlzdEVsLnNjcm9sbFRvKHsgdG9wOiAwLCBiZWhhdmlvcjogJ3Ntb290aCcg
fSk7CiAgICB9KTsKCiAgICBmdW5jdGlvbiB2aXNpYmxlTGlzdCgpIHsKICAgICAgICBjb25zdCBxID0g
U3RyaW5nKHF1ZXJ5IHx8ICcnKS50cmltKCk7CiAgICAgICAgLy8gSG9zdCBhbHJlYWR5IGZpbHRlcmVk
K2V4cGFuZGVkIGZvciB0aGlzIGV4YWN0IHF1ZXJ5IOKAlCBkb24ndCByZS1maWx0ZXIgKGF2b2lkcyBm
bGFzaCAvIGRyb3BwZWQgZmF2IGdyb3VwcykKICAgICAgICBpZiAocSAmJiB3aW5kb3cuX19ob3N0Rmls
dGVyZWQgJiYgd2luZG93Ll9faG9zdEZpbHRlclEgPT09IHEpCiAgICAgICAgICAgIHJldHVybiBhbGxD
bGlwczsKICAgICAgICByZXR1cm4gZmlsdGVyKGFsbENsaXBzLCBjdXJUYWIsIHF1ZXJ5KTsKICAgIH0K
ICAgIGZ1bmN0aW9uIGVzY0h0bWwocykgewogICAgICAgIHJldHVybiBTdHJpbmcocyA/PyAnJykucmVw
bGFjZSgvJi9nLCcmYW1wOycpLnJlcGxhY2UoLzwvZywnJmx0OycpLnJlcGxhY2UoLz4vZywnJmd0Oycp
LnJlcGxhY2UoLyIvZywnJnF1b3Q7Jyk7CiAgICB9CiAgICBmdW5jdGlvbiBxdWVyeVRlcm1zKHEpIHsK
ICAgICAgICBjb25zdCBvdXQgPSBbXTsKICAgICAgICBmb3IgKGNvbnN0IHNlZyBvZiBTdHJpbmcocSB8
fCAnJykuc3BsaXQoJ3wnKSkgewogICAgICAgICAgICBjb25zdCBzID0gc2VnLnRyaW0oKTsKICAgICAg
ICAgICAgaWYgKCFzKSBjb250aW51ZTsKICAgICAgICAgICAgY29uc3Qgd29yZHMgPSBzLnNwbGl0KC9c
cysvKS5maWx0ZXIoQm9vbGVhbik7CiAgICAgICAgICAgIGlmICh3b3Jkcy5sZW5ndGgpIG91dC5wdXNo
KC4uLndvcmRzKTsKICAgICAgICB9CiAgICAgICAgcmV0dXJuIG91dDsKICAgIH0KICAgIGZ1bmN0aW9u
IGhsSHRtbCh0ZXh0KSB7CiAgICAgICAgY29uc3QgdGVybXMgPSBxdWVyeVRlcm1zKHF1ZXJ5KTsKICAg
ICAgICBjb25zdCBzID0gU3RyaW5nKHRleHQgPz8gJycpOwogICAgICAgIGlmICghdGVybXMubGVuZ3Ro
KSByZXR1cm4gZXNjSHRtbChzKTsKICAgICAgICBjb25zdCBsb3dlciA9IHMudG9Mb3dlckNhc2UoKTsK
ICAgICAgICBjb25zdCB0ZXJtTCA9IHRlcm1zLm1hcCh0ID0+IHQudG9Mb3dlckNhc2UoKSk7CiAgICAg
ICAgbGV0IG91dCA9ICcnLCBpID0gMDsKICAgICAgICB3aGlsZSAoaSA8IHMubGVuZ3RoKSB7CiAgICAg
ICAgICAgIGxldCBiZXN0SiA9IC0xLCBiZXN0TGVuID0gMDsKICAgICAgICAgICAgZm9yIChsZXQgdGkg
PSAwOyB0aSA8IHRlcm1MLmxlbmd0aDsgdGkrKykgewogICAgICAgICAgICAgICAgY29uc3QgdCA9IHRl
cm1MW3RpXTsKICAgICAgICAgICAgICAgIGlmICghdCkgY29udGludWU7CiAgICAgICAgICAgICAgICBj
b25zdCBqID0gbG93ZXIuaW5kZXhPZih0LCBpKTsKICAgICAgICAgICAgICAgIGlmIChqIDwgMCkgY29u
dGludWU7CiAgICAgICAgICAgICAgICBpZiAoYmVzdEogPCAwIHx8IGogPCBiZXN0SiB8fCAoaiA9PT0g
YmVzdEogJiYgdC5sZW5ndGggPiBiZXN0TGVuKSkgewogICAgICAgICAgICAgICAgICAgIGJlc3RKID0g
ajsgYmVzdExlbiA9IHQubGVuZ3RoOwogICAgICAgICAgICAgICAgfQogICAgICAgICAgICB9CiAgICAg
ICAgICAgIGlmIChiZXN0SiA8IDApIHsgb3V0ICs9IGVzY0h0bWwocy5zbGljZShpKSk7IGJyZWFrOyB9
CiAgICAgICAgICAgIG91dCArPSBlc2NIdG1sKHMuc2xpY2UoaSwgYmVzdEopKTsKICAgICAgICAgICAg
b3V0ICs9ICc8bWFyayBjbGFzcz0icS1obCI+JyArIGVzY0h0bWwocy5zbGljZShiZXN0SiwgYmVzdEog
KyBiZXN0TGVuKSkgKyAnPC9tYXJrPic7CiAgICAgICAgICAgIGkgPSBiZXN0SiArIE1hdGgubWF4KDEs
IGJlc3RMZW4pOwogICAgICAgIH0KICAgICAgICByZXR1cm4gb3V0OwogICAgfQogICAgZnVuY3Rpb24g
c2V0SGxUZXh0KGVsLCB0ZXh0KSB7CiAgICAgICAgaWYgKCFlbCkgcmV0dXJuOwogICAgICAgIGNvbnN0
IHEgPSBTdHJpbmcocXVlcnkgfHwgJycpLnRyaW0oKTsKICAgICAgICBpZiAoIXEpIHsKICAgICAgICAg
ICAgZWwuY2xhc3NMaXN0LnJlbW92ZSgnaGFzLWhsJyk7CiAgICAgICAgICAgIGVsLnRleHRDb250ZW50
ID0gdGV4dCA9PSBudWxsID8gJycgOiBTdHJpbmcodGV4dCk7CiAgICAgICAgICAgIHJldHVybjsKICAg
ICAgICB9CiAgICAgICAgZWwuY2xhc3NMaXN0LmFkZCgnaGFzLWhsJyk7CiAgICAgICAgZWwuaW5uZXJI
VE1MID0gaGxIdG1sKHRleHQpOwogICAgfQoKCiAgICBmdW5jdGlvbiBhcHBseVRhYlN3aXRjaEFuaW0o
KSB7CiAgICAgICAgaWYgKCF0YWJTd2l0Y2hBbmltRGlyIHx8ICFsaXN0RWwpIHJldHVybjsKICAgICAg
ICBpZiAoIWxpc3RFbC5xdWVyeVNlbGVjdG9yKCcuaXRtLCAjZW1wdHkub24sICNsaXN0LW1vcmUnKSkK
ICAgICAgICAgICAgcmV0dXJuOwogICAgICAgIGNvbnN0IGRpciA9IHRhYlN3aXRjaEFuaW1EaXI7CiAg
ICAgICAgdGFiU3dpdGNoQW5pbURpciA9IDA7CiAgICAgICAgbGlzdEVsLmNsYXNzTGlzdC5yZW1vdmUo
J3RhYi1pbi1scicsICd0YWItaW4tcmwnKTsKICAgICAgICB2b2lkIGxpc3RFbC5vZmZzZXRXaWR0aDsK
ICAgICAgICBsaXN0RWwuY2xhc3NMaXN0LmFkZChkaXIgPiAwID8gJ3RhYi1pbi1scicgOiAndGFiLWlu
LXJsJyk7CiAgICAgICAgY2xlYXJUaW1lb3V0KGxpc3RFbC5fdGFiQW5pbVRpbWVyKTsKICAgICAgICBs
aXN0RWwuX3RhYkFuaW1UaW1lciA9IHNldFRpbWVvdXQoKCkgPT4gewogICAgICAgICAgICBsaXN0RWwu
Y2xhc3NMaXN0LnJlbW92ZSgndGFiLWluLWxyJywgJ3RhYi1pbi1ybCcpOwogICAgICAgIH0sIDQwMCk7
CiAgICB9CgogICAgZnVuY3Rpb24gdGFiSW5kZXgodGFiKSB7CiAgICAgICAgY29uc3QgaSA9IFRBQl9P
UkRFUi5pbmRleE9mKHRhYik7CiAgICAgICAgcmV0dXJuIGkgPj0gMCA/IGkgOiAwOwogICAgfQoKICAg
IGZ1bmN0aW9uIG1vdmVUYWJJbmsoaW5zdGFudCwgdGFyZ2V0RWwpIHsKICAgICAgICBjb25zdCBpbmsg
PSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgndGFiLWluaycpOwogICAgICAgIGNvbnN0IHRhYnMgPSBk
b2N1bWVudC5nZXRFbGVtZW50QnlJZCgndGFicycpOwogICAgICAgIGNvbnN0IGVsID0gdGFyZ2V0RWwg
fHwgZG9jdW1lbnQucXVlcnlTZWxlY3RvcignI3RhYnMgLnRhYi5vbicpOwogICAgICAgIGlmICghaW5r
IHx8ICF0YWJzIHx8ICFlbCkgcmV0dXJuOwogICAgICAgIGNvbnN0IHRyID0gdGFicy5nZXRCb3VuZGlu
Z0NsaWVudFJlY3QoKTsKICAgICAgICBjb25zdCByID0gZWwuZ2V0Qm91bmRpbmdDbGllbnRSZWN0KCk7
CiAgICAgICAgY29uc3QgeCA9IHIubGVmdCAtIHRyLmxlZnQ7CiAgICAgICAgY29uc3QgaCA9IE1hdGgu
bWF4KDIwLCBNYXRoLnJvdW5kKHIuaGVpZ2h0KSk7CiAgICAgICAgY29uc3QgeSA9IHIudG9wIC0gdHIu
dG9wOwogICAgICAgIGNvbnN0IHcgPSBNYXRoLm1heCgyNCwgci53aWR0aCk7CiAgICAgICAgY29uc3Qg
cG9zID0gJ3RyYW5zbGF0ZTNkKCcgKyB4ICsgJ3B4LCcgKyB5ICsgJ3B4LDApJzsKICAgICAgICBpbmsu
c3R5bGUudHJhbnNmb3JtT3JpZ2luID0gJ2NlbnRlciBib3R0b20nOwogICAgICAgIGluay5zdHlsZS53
aWR0aCA9IHcgKyAncHgnOwogICAgICAgIGluay5zdHlsZS5oZWlnaHQgPSBoICsgJ3B4JzsKICAgICAg
ICBpZiAoaW5zdGFudCkgewogICAgICAgICAgICBpbmsuc3R5bGUudHJhbnNpdGlvbiA9ICdub25lJzsK
ICAgICAgICAgICAgaW5rLmNsYXNzTGlzdC5yZW1vdmUoJ3NxdWFzaCcpOwogICAgICAgICAgICBpbmsu
c3R5bGUudHJhbnNmb3JtID0gcG9zICsgJyBzY2FsZVgoMSknOwogICAgICAgICAgICBpbmsub2Zmc2V0
SGVpZ2h0OwogICAgICAgICAgICBpbmsuc3R5bGUudHJhbnNpdGlvbiA9ICcnOwogICAgICAgICAgICBy
ZXR1cm47CiAgICAgICAgfQogICAgICAgIC8vIFNuYXAgdG8gaG92ZXJlZCB0YWIsIGV4cGFuZCBmcm9t
IGJvdHRvbS1jZW50ZXIg4oCUIG5vIHNsaWRpbmcgYmV0d2VlbiB0YWJzCiAgICAgICAgaW5rLnN0eWxl
LnRyYW5zaXRpb24gPSAnbm9uZSc7CiAgICAgICAgaW5rLnN0eWxlLnRyYW5zZm9ybSA9IHBvcyArICcg
c2NhbGVYKDAuMDAxKSc7CiAgICAgICAgaW5rLm9mZnNldEhlaWdodDsKICAgICAgICBpbmsuc3R5bGUu
dHJhbnNpdGlvbiA9ICcnOwogICAgICAgIGluay5jbGFzc0xpc3QuYWRkKCdzcXVhc2gnKTsKICAgICAg
ICBpbmsuc3R5bGUudHJhbnNmb3JtID0gcG9zICsgJyBzY2FsZVgoMSknOwogICAgICAgIGNsZWFyVGlt
ZW91dChpbmsuX3NxdWFzaFRpbWVyKTsKICAgICAgICBpbmsuX3NxdWFzaFRpbWVyID0gc2V0VGltZW91
dCgoKSA9PiBpbmsuY2xhc3NMaXN0LnJlbW92ZSgnc3F1YXNoJyksIDM0MCk7CiAgICB9CiAgICBmdW5j
dGlvbiBtYXJrVGFiKHRhYiwgaW5zdGFudCkgewogICAgICAgIGRvY3VtZW50LnF1ZXJ5U2VsZWN0b3JB
bGwoJyN0YWJzIC50YWInKS5mb3JFYWNoKGVsID0+CiAgICAgICAgICAgIGVsLmNsYXNzTGlzdC50b2dn
bGUoJ29uJywgZWwuZGF0YXNldC50YWIgPT09IHRhYikpOwogICAgICAgIG1vdmVUYWJJbmsoISFpbnN0
YW50KTsKICAgIH0KICAgIGZ1bmN0aW9uIGJpbmRUYWJJbmtIb3ZlcigpIHsKICAgICAgICBjb25zdCB0
YWJzID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3RhYnMnKTsKICAgICAgICBpZiAoIXRhYnMgfHwg
dGFicy5faW5rSG92ZXJCb3VuZCkgcmV0dXJuOwogICAgICAgIHRhYnMuX2lua0hvdmVyQm91bmQgPSB0
cnVlOwogICAgICAgIHRhYnMuYWRkRXZlbnRMaXN0ZW5lcigncG9pbnRlcm92ZXInLCBlID0+IHsKICAg
ICAgICAgICAgY29uc3QgdGFiID0gZS50YXJnZXQuY2xvc2VzdCgnLnRhYicpOwogICAgICAgICAgICBp
ZiAoIXRhYiB8fCAhdGFicy5jb250YWlucyh0YWIpKSByZXR1cm47CiAgICAgICAgICAgIG1vdmVUYWJJ
bmsoZmFsc2UsIHRhYik7CiAgICAgICAgfSk7CiAgICAgICAgdGFicy5hZGRFdmVudExpc3RlbmVyKCdw
b2ludGVybGVhdmUnLCBlID0+IHsKICAgICAgICAgICAgaWYgKGUucmVsYXRlZFRhcmdldCAmJiB0YWJz
LmNvbnRhaW5zKGUucmVsYXRlZFRhcmdldCkpIHJldHVybjsKICAgICAgICAgICAgbW92ZVRhYkluayhm
YWxzZSk7CiAgICAgICAgfSk7CiAgICB9CmZ1bmN0aW9uIHNldFRhYih0YWIpIHsKICAgICAgICBpZiAo
dGFiID09PSBjdXJUYWIpIHJldHVybjsKICAgICAgICBjb25zdCBmcm9tID0gdGFiSW5kZXgoY3VyVGFi
KTsKICAgICAgICBjb25zdCB0byA9IHRhYkluZGV4KHRhYik7CiAgICAgICAgdGFiU3dpdGNoQW5pbURp
ciA9IHRvID4gZnJvbSA/IDEgOiAodG8gPCBmcm9tID8gLTEgOiAwKTsKICAgICAgICBjdXJUYWIgPSB0
YWI7CiAgICAgICAgbG9hZGluZ01vcmUgPSBmYWxzZTsKICAgICAgICBtYXJrVGFiKHRhYik7CgogICAg
ICAgIC8vIEtlZXAgc2VhcmNoICJ0b2RheSIgZmlsdGVyIGluIHN5bmMgd2hlbiBzZWFyY2ggaXMgb3Bl
bgogICAgICAgIHRyeSB7CiAgICAgICAgICAgIGNvbnN0IHdyYXAgPSBkb2N1bWVudC5nZXRFbGVtZW50
QnlJZCgnc2VhcmNoLXdyYXAnKTsKICAgICAgICAgICAgY29uc3QgYnRuVG9kYXkgPSBkb2N1bWVudC5n
ZXRFbGVtZW50QnlJZCgnYnRuLXRvZGF5Jyk7CiAgICAgICAgICAgIGlmICh3cmFwICYmIHdyYXAuY2xh
c3NMaXN0LmNvbnRhaW5zKCdvcGVuJykpIHsKICAgICAgICAgICAgICAgIGNvbnN0IHdhbnRUb2RheSA9
IGZhbHNlOwogICAgICAgICAgICAgICAgaWYgKHRvZGF5T25seSAhPT0gd2FudFRvZGF5KSB7CiAgICAg
ICAgICAgICAgICAgICAgdG9kYXlPbmx5ID0gd2FudFRvZGF5OwogICAgICAgICAgICAgICAgICAgIGlm
IChidG5Ub2RheSkgYnRuVG9kYXkuY2xhc3NMaXN0LnRvZ2dsZSgnb24nLCB0b2RheU9ubHkpOwogICAg
ICAgICAgICAgICAgfQogICAgICAgICAgICB9CiAgICAgICAgfSBjYXRjaCB7fQoKICAgICAgICBzZWxl
Y3RlZElkID0gbnVsbDsKICAgICAgICBtdWx0aUlkcyA9IFtdOwogICAgICAgIGxpc3RFbC5zY3JvbGxU
b3AgPSAwOwogICAgICAgIGNvbnN0IGhpdCA9IHZpZXdNZW0uZ2V0KHZpZXdNZW1LZXkodGFiLCBxdWVy
eSwgdG9kYXlPbmx5KSk7CiAgICAgICAgaWYgKGhpdCAmJiBBcnJheS5pc0FycmF5KGhpdC5pdGVtcykg
JiYgaGl0Lml0ZW1zLmxlbmd0aCkgewogICAgICAgICAgICBhbGxDbGlwcyA9IGhpdC5pdGVtcy5zbGlj
ZSgpOwogICAgICAgICAgICBkaXNrVG90YWwgPSBOdW1iZXIoaGl0LnRvdGFsKSB8fCBoaXQuaXRlbXMu
bGVuZ3RoOwogICAgICAgICAgICB3aW5kb3cuX193YWl0aW5nVmlldyA9IGZhbHNlOwogICAgICAgICAg
ICBjbGVhcldhaXRpbmdEYXRhKCk7CiAgICAgICAgICAgIHdpbmRvdy5fX2RhdGFSZWFkeSA9IHRydWU7
CiAgICAgICAgICAgIGhvc3RQdXNoZWRPbmNlID0gdHJ1ZTsKICAgICAgICAgICAgc2F3Tm9uRW1wdHkg
PSB0cnVlOwogICAgICAgICAgICByZW5kZXIoKTsKICAgICAgICAgICAgYXBwbHlUYWJTd2l0Y2hBbmlt
KCk7CiAgICAgICAgICAgIC8vIE1lbW9yeSBwYWludCBmaXJzdCDigJRiYWNrZ3JvdW5kIHNvZnQtc3lu
YyBrZWVwcyBBSEsgaW4gc3RlcCB3aXRob3V0IGRvdWJsZSByZWRyYXcKICAgICAgICAgICAgc29mdFJl
cXVlc3RWaWV3KCk7CiAgICAgICAgICAgIHJldHVybjsKICAgICAgICB9CiAgICAgICAgLy8gTm8gY2Fj
aGUgeWV0OiBrZWVwIGN1cnJlbnQgcm93cyDigJQgTkVWRVIgd2lwZSB0byBibGFuayB3aGl0ZQogICAg
ICAgIHdpbmRvdy5fX3dhaXRpbmdWaWV3ID0gdHJ1ZTsKICAgICAgICBzY2hlZHVsZURlbGF5ZWRTa2Vs
KCk7CiAgICAgICAgaWYgKCFhbGxDbGlwcy5sZW5ndGgpCiAgICAgICAgICAgIHJlbmRlcigpOwogICAg
ICAgIHJlcXVlc3RWaWV3KCk7CiAgICAgICAgYXBwbHlUYWJTd2l0Y2hBbmltKCk7CiAgICB9CgogICAg
bW92ZVRhYkluayh0cnVlKTsKICAgIGJpbmRUYWJJbmtIb3ZlcigpOwogICAgdHJ5IHsgbmV3IFJlc2l6
ZU9ic2VydmVyKCgpID0+IG1vdmVUYWJJbmsodHJ1ZSkpLm9ic2VydmUoZG9jdW1lbnQuZ2V0RWxlbWVu
dEJ5SWQoJ3RhYnMnKSk7IH0gY2F0Y2gge30KICAgIHdpbmRvdy5hZGRFdmVudExpc3RlbmVyKCdyZXNp
emUnLCAoKSA9PiBtb3ZlVGFiSW5rKHRydWUpKTsKCiAgICBmdW5jdGlvbiB1cGRhdGVNb3JlRm9vdGVy
KHRvdGFsKSB7CiAgICAgICAgbGV0IG1vcmVFbCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdsaXN0
LW1vcmUnKTsKICAgICAgICBjb25zdCBsb2FkZWQgPSBhbGxDbGlwcy5sZW5ndGg7CiAgICAgICAgaWYg
KGxvYWRlZCA+PSB0b3RhbCkgewogICAgICAgICAgICBpZiAobW9yZUVsKSBtb3JlRWwucmVtb3ZlKCk7
CiAgICAgICAgICAgIHJldHVybjsKICAgICAgICB9CiAgICAgICAgaWYgKCFtb3JlRWwpIHsKICAgICAg
ICAgICAgbW9yZUVsID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnZGl2Jyk7CiAgICAgICAgICAgIG1v
cmVFbC5pZCA9ICdsaXN0LW1vcmUnOwogICAgICAgICAgICBtb3JlRWwuY2xhc3NOYW1lID0gJ2xpc3Qt
bW9yZSc7CiAgICAgICAgICAgIGxpc3RFbC5hcHBlbmRDaGlsZChtb3JlRWwpOwogICAgICAgIH0KICAg
ICAgICBtb3JlRWwudGV4dENvbnRlbnQgPSAn57un57ut5LiL5ruR5LuO56OB55uY5Yqg6L2977yIJyAr
IGxvYWRlZCArICcvJyArIHRvdGFsICsgJ++8iSc7CiAgICB9CgogICAgLyoqIFVwZGF0ZSBiYXIgLyBw
aW4gYmFkZ2Ugd2l0aG91dCB0b3VjaGluZyB0aGUgbGlzdCBET00gKi8KICAgIGZ1bmN0aW9uIHJlZnJl
c2hMaXN0Q2hyb21lKCkgewogICAgICAgIGNvbnN0IHZpc2libGUgPSB2aXNpYmxlTGlzdCgpOwogICAg
ICAgIGNvbnN0IGxvYWRlZCA9IGFsbENsaXBzLmxlbmd0aDsKICAgICAgICBjb25zdCBzaG93bkNvdW50
ID0gdmlzaWJsZS5sZW5ndGg7CiAgICAgICAgbGV0IHBpbm5lZE4gPSBOdW1iZXIocGlubmVkVG90YWwp
IHx8IDA7CiAgICAgICAgaWYgKHBpbm5lZE4gPCAxKSB7CiAgICAgICAgICAgIGlmIChjdXJUYWIgPT09
ICdwaW5uZWQnKQogICAgICAgICAgICAgICAgcGlubmVkTiA9IE1hdGgubWF4KE51bWJlcihkaXNrVG90
YWwpIHx8IDAsIGxvYWRlZCk7CiAgICAgICAgICAgIGVsc2UKICAgICAgICAgICAgICAgIHBpbm5lZE4g
PSBhbGxDbGlwcy5maWx0ZXIoYyA9PiBpc1Bpbm5lZChjKSkubGVuZ3RoOwogICAgICAgIH0KICAgICAg
ICBjb25zdCBwaW5DbnQgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgncGluLWNudCcpOwogICAgICAg
IGlmIChwaW5DbnQpIHsKICAgICAgICAgICAgcGluQ250LnRleHRDb250ZW50ID0gcGlubmVkTjsKICAg
ICAgICAgICAgcGluQ250LnN0eWxlLmRpc3BsYXkgPSBwaW5uZWROID8gJycgOiAnbm9uZSc7CiAgICAg
ICAgfQogICAgICAgIGxldCBzaG93VG90YWwgPSBkaXNrVG90YWwgPiAwID8gZGlza1RvdGFsIDogKGxv
YWRlZCB8fCAwKTsKICAgICAgICBpZiAoY3VyVGFiID09PSAncGlubmVkJyAmJiBwaW5uZWROID4gc2hv
d1RvdGFsKQogICAgICAgICAgICBzaG93VG90YWwgPSBwaW5uZWROOwogICAgICAgIGNvbnN0IHFPbiA9
IFN0cmluZyhxdWVyeSB8fCAnJykudHJpbSgpLmxlbmd0aCA+IDA7CiAgICAgICAgY29uc3QgYmFyID0g
ZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2Jhci10eHQnKTsKICAgICAgICBpZiAoYmFyKSB7CiAgICAg
ICAgICAgIGJhci50ZXh0Q29udGVudCA9IHFPbgogICAgICAgICAgICAgICAgPyAoc2hvd25Db3VudCAr
ICcg5p2hJykKICAgICAgICAgICAgICAgIDogKHNob3dUb3RhbCA+IGxvYWRlZCA/IChzaG93bkNvdW50
ICsgJyAvICcgKyBzaG93VG90YWwgKyAnIOadoScpIDogKHNob3dUb3RhbCArICcg5p2hJykpOwogICAg
ICAgIH0KICAgICAgICB1cGRhdGVNb3JlRm9vdGVyKGRpc2tUb3RhbCk7CiAgICAgICAgdXBkYXRlVG9w
QnRuKCk7CiAgICB9CgogICAgLyoqCiAgICAgKiBMb2FkLW1vcmU6IGFwcGVuZCBvbmx5IG5ldyBET00g
bm9kZXMuIEZ1bGwgcmVuZGVyKCkgbnVrZXMgZXZlcnkgLml0bSBhbmQKICAgICAqIHJlc3RvcmVzIHNj
cm9sbFRvcCDigJQgdGhhdCBoaXRjaCBpcyB3aGF0IG1ha2VzIGRyYWdnaW5nIHRoZSBzY3JvbGxiYXIg
ZmVlbCBzdGlja3kuCiAgICAgKi8KICAgIGZ1bmN0aW9uIGFwcGVuZFJlbmRlcihwcmV2TGVuKSB7CiAg
ICAgICAgY29uc3QgdmlzaWJsZSA9IHZpc2libGVMaXN0KCk7CiAgICAgICAgaWYgKCF2aXNpYmxlLmxl
bmd0aCkgewogICAgICAgICAgICByZW5kZXIoKTsKICAgICAgICAgICAgcmV0dXJuIGZhbHNlOwogICAg
ICAgIH0KICAgICAgICBpZiAocHJldkxlbiA+IDAgJiYgcHJldkxlbiA8IGFsbENsaXBzLmxlbmd0aCkg
ewogICAgICAgICAgICBjb25zdCBzZWFtR2lkcyA9IG5ldyBTZXQoKTsKICAgICAgICAgICAgZm9yIChs
ZXQgaSA9IE1hdGgubWF4KDAsIHByZXZMZW4gLSA4KTsgaSA8IE1hdGgubWluKGFsbENsaXBzLmxlbmd0
aCwgcHJldkxlbiArIDgpOyBpKyspIHsKICAgICAgICAgICAgICAgIGNvbnN0IGcgPSBmYXZHcm91cE9m
KGFsbENsaXBzW2ldKTsKICAgICAgICAgICAgICAgIGlmIChnKSBzZWFtR2lkcy5hZGQoZyk7CiAgICAg
ICAgICAgIH0KICAgICAgICAgICAgaWYgKHNlYW1HaWRzLnNpemUpIHsKICAgICAgICAgICAgICAgIGZv
ciAoY29uc3QgZyBvZiBzZWFtR2lkcykgewogICAgICAgICAgICAgICAgICAgIGxldCBiZWZvcmUgPSAw
LCBhZnRlciA9IDA7CiAgICAgICAgICAgICAgICAgICAgZm9yIChsZXQgaSA9IDA7IGkgPCBhbGxDbGlw
cy5sZW5ndGg7IGkrKykgewogICAgICAgICAgICAgICAgICAgICAgICBpZiAoZmF2R3JvdXBPZihhbGxD
bGlwc1tpXSkgIT09IGcpIGNvbnRpbnVlOwogICAgICAgICAgICAgICAgICAgICAgICBpZiAoaSA8IHBy
ZXZMZW4pIGJlZm9yZSsrOwogICAgICAgICAgICAgICAgICAgICAgICBlbHNlIGFmdGVyKys7CiAgICAg
ICAgICAgICAgICAgICAgfQogICAgICAgICAgICAgICAgICAgIGlmIChiZWZvcmUgPiAwICYmIGFmdGVy
ID4gMCkgewogICAgICAgICAgICAgICAgICAgICAgICByZW5kZXIoKTsKICAgICAgICAgICAgICAgICAg
ICAgICAgcmV0dXJuIGZhbHNlOwogICAgICAgICAgICAgICAgICAgIH0KICAgICAgICAgICAgICAgIH0K
ICAgICAgICAgICAgfQogICAgICAgIH0KICAgICAgICBjb25zdCBibG9ja3MgPSBidWlsZFBpbm5lZEJs
b2Nrcyh2aXNpYmxlKTsKICAgICAgICBjb25zdCBleGlzdGluZyA9IGxpc3RFbC5xdWVyeVNlbGVjdG9y
QWxsKCcuaXRtJykubGVuZ3RoOwogICAgICAgIGlmIChleGlzdGluZyA8IDEpIHsKICAgICAgICAgICAg
cmVuZGVyKCk7CiAgICAgICAgICAgIHJldHVybiBmYWxzZTsKICAgICAgICB9CiAgICAgICAgaWYgKGJs
b2Nrcy5sZW5ndGggPD0gZXhpc3RpbmcpIHsKICAgICAgICAgICAgcmVmcmVzaExpc3RDaHJvbWUoKTsK
ICAgICAgICAgICAgdHJ5IHsgbWFya1F1ZXVlUmFpbHMoKTsgfSBjYXRjaCAoZSkge30KICAgICAgICAg
ICAgcmV0dXJuIHRydWU7CiAgICAgICAgfQogICAgICAgIGNvbnN0IGZyYWcgPSBkb2N1bWVudC5jcmVh
dGVEb2N1bWVudEZyYWdtZW50KCk7CiAgICAgICAgbGV0IG51bSA9IDA7CiAgICAgICAgYmxvY2tzLmZv
ckVhY2goYiA9PiB7CiAgICAgICAgICAgIG51bSArPSAxOwogICAgICAgICAgICBpZiAobnVtIDw9IGV4
aXN0aW5nKSByZXR1cm47CiAgICAgICAgICAgIGlmIChiLmtpbmQgPT09ICdncm91cCcgJiYgYi5pdGVt
cy5sZW5ndGggPiAxKQogICAgICAgICAgICAgICAgZnJhZy5hcHBlbmRDaGlsZChtYWtlR3JvdXBJdGVt
KGIuaXRlbXMsIG51bSkpOwogICAgICAgICAgICBlbHNlCiAgICAgICAgICAgICAgICBmcmFnLmFwcGVu
ZENoaWxkKG1ha2VJdGVtKGIuaXRlbXNbMF0sIG51bSkpOwogICAgICAgIH0pOwogICAgICAgIGNvbnN0
IG1vcmVFbCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdsaXN0LW1vcmUnKTsKICAgICAgICBpZiAo
bW9yZUVsKQogICAgICAgICAgICBsaXN0RWwuaW5zZXJ0QmVmb3JlKGZyYWcsIG1vcmVFbCk7CiAgICAg
ICAgZWxzZQogICAgICAgICAgICBsaXN0RWwuYXBwZW5kQ2hpbGQoZnJhZyk7CiAgICAgICAgdHJ5IHsg
bWFya1F1ZXVlUmFpbHMoKTsgfSBjYXRjaCAoZSkge30KICAgICAgICByZWZyZXNoTGlzdENocm9tZSgp
OwogICAgICAgIHJlcXVlc3RBbmltYXRpb25GcmFtZSgoKSA9PiB7CiAgICAgICAgICAgIGlmIChhbGxD
bGlwcy5sZW5ndGggPCBkaXNrVG90YWwKICAgICAgICAgICAgICAgICYmIGxpc3RFbC5zY3JvbGxIZWln
aHQgPD0gbGlzdEVsLmNsaWVudEhlaWdodCArIDIwKQogICAgICAgICAgICAgICAgcmVxdWVzdE1vcmUo
KTsKICAgICAgICAgICAgdHJ5IHsgc2NoZWR1bGVGaWxlR29uZUNoZWNrKCk7IH0gY2F0Y2gge30KICAg
ICAgICB9KTsKICAgICAgICByZXR1cm4gdHJ1ZTsKICAgIH0KCiAgICBmdW5jdGlvbiBhcHBseUFwcGVu
ZFBheWxvYWQocGVuZGluZykgewogICAgICAgIGlmICghcGVuZGluZyB8fCBwZW5kaW5nLmZyb21MZW4g
PT0gbnVsbCkgcmV0dXJuOwogICAgICAgIGNvbnN0IGZyb21MZW4gPSBOdW1iZXIocGVuZGluZy5mcm9t
TGVuKSB8fCAwOwogICAgICAgIGlmIChmcm9tTGVuIDwgMCB8fCBhbGxDbGlwcy5sZW5ndGggPD0gZnJv
bUxlbikgewogICAgICAgICAgICByZWZyZXNoTGlzdENocm9tZSgpOwogICAgICAgICAgICByZXR1cm47
CiAgICAgICAgfQogICAgICAgIGFwcGVuZFJlbmRlcihmcm9tTGVuKTsKICAgIH0KCiAgICBmdW5jdGlv
biBuYXZMaXN0KCkgewogICAgICAgIGNvbnN0IGJsb2NrcyA9IGJ1aWxkUGlubmVkQmxvY2tzKHZpc2li
bGVMaXN0KCkpOwogICAgICAgIGNvbnN0IG91dCA9IFtdOwogICAgICAgIGZvciAoY29uc3QgYiBvZiBi
bG9ja3MpIHsKICAgICAgICAgICAgaWYgKCFiIHx8ICFiLml0ZW1zKSBjb250aW51ZTsKICAgICAgICAg
ICAgZm9yIChjb25zdCBjIG9mIGIuaXRlbXMpIG91dC5wdXNoKGMpOwogICAgICAgIH0KICAgICAgICBy
ZXR1cm4gb3V0OwogICAgfQoKICAgIGZ1bmN0aW9uIHNlbGVjdEJ5SW5kZXgoaWR4KSB7CiAgICAgICAg
Y29uc3QgdmlzID0gbmF2TGlzdCgpOwogICAgICAgIGlmICghdmlzLmxlbmd0aCkgcmV0dXJuOwogICAg
ICAgIGlkeCA9IE1hdGgubWF4KDAsIE1hdGgubWluKHZpcy5sZW5ndGggLSAxLCBpZHgpKTsKICAgICAg
ICBpZiAoaWR4ID49IHZpcy5sZW5ndGggLSAxICYmIGFsbENsaXBzLmxlbmd0aCA8IGRpc2tUb3RhbCkK
ICAgICAgICAgICAgcmVxdWVzdE1vcmUoKTsKICAgICAgICBzZWxlY3RlZElkID0gdmlzW01hdGgubWlu
KGlkeCwgdmlzLmxlbmd0aCAtIDEpXS5pZDsKICAgICAgICByYW5nZUFuY2hvcklkID0gc2VsZWN0ZWRJ
ZDsKICAgICAgICByYW5nZUFuY2hvckNsaWNrZWQgPSBmYWxzZTsKICAgICAgICBpZiAoK3NlbGVjdGVk
SWQgIT09ICtsYXN0UGFzdGVJZCkKICAgICAgICAgICAgbG9jYXRlQWN0aXZlID0gZmFsc2U7CiAgICAg
ICAgdXBkYXRlTG9jYXRlQnRuKCk7CiAgICAgICAgc3luY0l0ZW1IaWdobGlnaHQoKTsKICAgICAgICBj
b25zdCBlbCA9IGxpc3RFbC5xdWVyeVNlbGVjdG9yKCcubWctcm93W2RhdGEtaWQ9IicgKyBzZWxlY3Rl
ZElkICsgJyJdJykKICAgICAgICAgICAgfHwgbGlzdEVsLnF1ZXJ5U2VsZWN0b3IoJy5pdG1bZGF0YS1p
ZD0iJyArIHNlbGVjdGVkSWQgKyAnIl0nKTsKICAgICAgICBpZiAoZWwpIGVsLnNjcm9sbEludG9WaWV3
KHsgYmxvY2s6ICduZWFyZXN0JyB9KTsKICAgIH0KCiAgICBmdW5jdGlvbiBzZWxlY3RlZEluZGV4KCkg
ewogICAgICAgIHJldHVybiBuYXZMaXN0KCkuZmluZEluZGV4KGMgPT4gYy5pZCA9PSBzZWxlY3RlZElk
KTsKICAgIH0KCiAgICBmdW5jdGlvbiBzeW5jSXRlbUhpZ2hsaWdodCgpIHsKICAgICAgICBkb2N1bWVu
dC5xdWVyeVNlbGVjdG9yQWxsKCcuaXRtJykuZm9yRWFjaChuID0+IHsKICAgICAgICAgICAgaWYgKG4u
Y2xhc3NMaXN0LmNvbnRhaW5zKCdpdC1ncm91cCcpKSB7CiAgICAgICAgICAgICAgICBjb25zdCByb3dz
ID0gWy4uLm4ucXVlcnlTZWxlY3RvckFsbCgnLm1nLXJvdycpXTsKICAgICAgICAgICAgICAgIGNvbnN0
IGlkcyA9IHJvd3MubWFwKHIgPT4gK3IuZGF0YXNldC5pZCk7CiAgICAgICAgICAgICAgICBjb25zdCBh
bnlTZWwgPSBpZHMuaW5jbHVkZXMoK3NlbGVjdGVkSWQpIHx8IGlkcy5zb21lKGlkID0+IG11bHRpSWRz
LmluY2x1ZGVzKGlkKSk7CiAgICAgICAgICAgICAgICBuLmNsYXNzTGlzdC50b2dnbGUoJ3NlbCcsIGFu
eVNlbCk7CiAgICAgICAgICAgICAgICBuLmNsYXNzTGlzdC50b2dnbGUoJ211bHRpJywgaWRzLnNvbWUo
aWQgPT4gbXVsdGlJZHMuaW5jbHVkZXMoaWQpKSk7CiAgICAgICAgICAgICAgICByb3dzLmZvckVhY2go
ciA9PiB7CiAgICAgICAgICAgICAgICAgICAgY29uc3QgaWQgPSArci5kYXRhc2V0LmlkOwogICAgICAg
ICAgICAgICAgICAgIGNvbnN0IGluTXVsdGkgPSBtdWx0aUlkcy5pbmNsdWRlcyhpZCk7CiAgICAgICAg
ICAgICAgICAgICAgci5jbGFzc0xpc3QudG9nZ2xlKCdzZWwnLCBpZCA9PSBzZWxlY3RlZElkIHx8IGlu
TXVsdGkpOwogICAgICAgICAgICAgICAgICAgIHIuY2xhc3NMaXN0LnRvZ2dsZSgnbXVsdGknLCBpbk11
bHRpKTsKICAgICAgICAgICAgICAgIH0pOwogICAgICAgICAgICAgICAgcmV0dXJuOwogICAgICAgICAg
ICB9CiAgICAgICAgICAgIGNvbnN0IGlkID0gK24uZGF0YXNldC5pZDsKICAgICAgICAgICAgY29uc3Qg
aW5NdWx0aSA9IG11bHRpSWRzLmluY2x1ZGVzKGlkKTsKICAgICAgICAgICAgbi5jbGFzc0xpc3QudG9n
Z2xlKCdzZWwnLCBpZCA9PSBzZWxlY3RlZElkIHx8IGluTXVsdGkpOwogICAgICAgICAgICBuLmNsYXNz
TGlzdC50b2dnbGUoJ211bHRpJywgaW5NdWx0aSk7CiAgICAgICAgfSk7CiAgICB9CiAgICBmdW5jdGlv
biB1cGRhdGVNdWx0aUJhZGdlKCkgewogICAgICAgIGNvbnN0IGVsID0gZG9jdW1lbnQuZ2V0RWxlbWVu
dEJ5SWQoJ211bHRpLWNudCcpOwogICAgICAgIGlmIChtdWx0aUlkcy5sZW5ndGggPiAwKSB7CiAgICAg
ICAgICAgIGVsLnRleHRDb250ZW50ID0gU3RyaW5nKG11bHRpSWRzLmxlbmd0aCk7CiAgICAgICAgICAg
IGVsLmNsYXNzTGlzdC5hZGQoJ29uJyk7CiAgICAgICAgfSBlbHNlIHsKICAgICAgICAgICAgZWwuY2xh
c3NMaXN0LnJlbW92ZSgnb24nKTsKICAgICAgICB9CiAgICAgICAgc3luY0l0ZW1IaWdobGlnaHQoKTsK
ICAgIH0KCiAgICBmdW5jdGlvbiBjbGVhck11bHRpKHJlc3RvcmVUb0FuY2hvcikgewogICAgICAgIGNv
bnN0IGJhY2tJZCA9ICtyYW5nZUFuY2hvcklkIHx8IDA7CiAgICAgICAgbXVsdGlJZHMgPSBbXTsKICAg
ICAgICBpZiAocmVzdG9yZVRvQW5jaG9yICYmIGJhY2tJZCkKICAgICAgICAgICAgc2VsZWN0ZWRJZCA9
IGJhY2tJZDsKICAgICAgICByYW5nZUFuY2hvcklkID0gc2VsZWN0ZWRJZCB8fCAwOwogICAgICAgIHJh
bmdlQW5jaG9yQ2xpY2tlZCA9IGZhbHNlOwogICAgICAgIHVwZGF0ZU11bHRpQmFkZ2UoKTsKICAgICAg
ICBpZiAocmVzdG9yZVRvQW5jaG9yICYmIHNlbGVjdGVkSWQpIHsKICAgICAgICAgICAgY29uc3QgZWwg
PSBsaXN0RWwucXVlcnlTZWxlY3RvcignLm1nLXJvd1tkYXRhLWlkPSInICsgc2VsZWN0ZWRJZCArICci
XScpCiAgICAgICAgICAgICAgICB8fCBsaXN0RWwucXVlcnlTZWxlY3RvcignLml0bVtkYXRhLWlkPSIn
ICsgc2VsZWN0ZWRJZCArICciXScpOwogICAgICAgICAgICBpZiAoZWwpIGVsLnNjcm9sbEludG9WaWV3
KHsgYmxvY2s6ICduZWFyZXN0JyB9KTsKICAgICAgICB9CiAgICB9CgoKICAgIC8qIHNoaWZ0LXJhbmdl
LXNlbGVjdC12MSAqLwogICAgbGV0IHJhbmdlQW5jaG9ySWQgPSAwOwogICAgbGV0IHJhbmdlQW5jaG9y
Q2xpY2tlZCA9IGZhbHNlOwogICAgZnVuY3Rpb24gc2VsZWN0UmFuZ2VUbyhpZCkgewogICAgICAgIGlk
ID0gK2lkOwogICAgICAgIGNvbnN0IGxpc3QgPSAodHlwZW9mIG5hdkxpc3QgPT09ICdmdW5jdGlvbicg
PyBuYXZMaXN0KCkgOiB2aXNpYmxlTGlzdCgpKTsKICAgICAgICBjb25zdCBiID0gbGlzdC5maW5kSW5k
ZXgoYyA9PiArYy5pZCA9PT0gaWQpOwogICAgICAgIGlmIChiIDwgMCkgcmV0dXJuOwogICAgICAgIGxl
dCBhbmNob3IgPSArcmFuZ2VBbmNob3JJZDsKICAgICAgICBsZXQgYSA9IGxpc3QuZmluZEluZGV4KGMg
PT4gK2MuaWQgPT09IGFuY2hvcik7CiAgICAgICAgaWYgKGEgPCAwKSB7CiAgICAgICAgICAgIGFuY2hv
ciA9ICtzZWxlY3RlZElkIHx8IGlkOwogICAgICAgICAgICBhID0gbGlzdC5maW5kSW5kZXgoYyA9PiAr
Yy5pZCA9PT0gYW5jaG9yKTsKICAgICAgICB9CiAgICAgICAgaWYgKGEgPCAwKSB7CiAgICAgICAgICAg
IHJhbmdlQW5jaG9ySWQgPSBpZDsgc2VsZWN0ZWRJZCA9IGlkOyBtdWx0aUlkcyA9IFtpZF07IHVwZGF0
ZU11bHRpQmFkZ2UoKTsgcmV0dXJuOwogICAgICAgIH0KICAgICAgICBpZiAoIXJhbmdlQW5jaG9ySWQg
fHwgbGlzdC5maW5kSW5kZXgoYyA9PiArYy5pZCA9PT0gK3JhbmdlQW5jaG9ySWQpIDwgMCkKICAgICAg
ICAgICAgcmFuZ2VBbmNob3JJZCA9IGxpc3RbYV0uaWQ7CiAgICAgICAgY29uc3QgbG8gPSBNYXRoLm1p
bihhLCBiKSwgaGkgPSBNYXRoLm1heChhLCBiKTsKICAgICAgICBtdWx0aUlkcyA9IFtdOwogICAgICAg
IGZvciAobGV0IGkgPSBsbzsgaSA8PSBoaTsgaSsrKSBtdWx0aUlkcy5wdXNoKCtsaXN0W2ldLmlkKTsK
ICAgICAgICBzZWxlY3RlZElkID0gaWQ7CiAgICAgICAgdXBkYXRlTXVsdGlCYWRnZSgpOwogICAgICAg
IGNvbnN0IGVsID0gbGlzdEVsLnF1ZXJ5U2VsZWN0b3IoJy5tZy1yb3dbZGF0YS1pZD0iJyArIHNlbGVj
dGVkSWQgKyAnIl0nKSB8fCBsaXN0RWwucXVlcnlTZWxlY3RvcignLml0bVtkYXRhLWlkPSInICsgc2Vs
ZWN0ZWRJZCArICciXScpOwogICAgICAgIGlmIChlbCkgZWwuc2Nyb2xsSW50b1ZpZXcoeyBibG9jazog
J25lYXJlc3QnIH0pOwogICAgfQogICAgZnVuY3Rpb24gc2hvd1NyY1RpcChhbmNob3IsIHRleHQpIHsK
ICAgICAgICB0ZXh0ID0gU3RyaW5nKHRleHQgfHwgJycpLnRyaW0oKTsKICAgICAgICBpZiAoIXRleHQp
IHJldHVybjsKICAgICAgICBsZXQgdGlwID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NyYy10aXAn
KTsKICAgICAgICBpZiAoIXRpcCkgewogICAgICAgICAgICB0aXAgPSBkb2N1bWVudC5jcmVhdGVFbGVt
ZW50KCdkaXYnKTsKICAgICAgICAgICAgdGlwLmlkID0gJ3NyYy10aXAnOwogICAgICAgICAgICBkb2N1
bWVudC5ib2R5LmFwcGVuZENoaWxkKHRpcCk7CiAgICAgICAgfQogICAgICAgIHRpcC50ZXh0Q29udGVu
dCA9IHRleHQ7CiAgICAgICAgdGlwLmNsYXNzTGlzdC5hZGQoJ3Nob3cnKTsKICAgICAgICBjb25zdCBy
ID0gYW5jaG9yLmdldEJvdW5kaW5nQ2xpZW50UmVjdCgpOwogICAgICAgIGNvbnN0IHR3ID0gdGlwLm9m
ZnNldFdpZHRoIHx8IDE2MDsKICAgICAgICBjb25zdCB0aCA9IHRpcC5vZmZzZXRIZWlnaHQgfHwgMjg7
CiAgICAgICAgbGV0IGxlZnQgPSByLnJpZ2h0IC0gdHc7CiAgICAgICAgbGV0IHRvcCA9IHIudG9wIC0g
dGggLSA4OwogICAgICAgIGlmIChsZWZ0IDwgOCkgbGVmdCA9IDg7CiAgICAgICAgaWYgKGxlZnQgKyB0
dyA+IHdpbmRvdy5pbm5lcldpZHRoIC0gOCkgbGVmdCA9IHdpbmRvdy5pbm5lcldpZHRoIC0gdHcgLSA4
OwogICAgICAgIGlmICh0b3AgPCA4KSB0b3AgPSByLmJvdHRvbSArIDg7CiAgICAgICAgdGlwLnN0eWxl
LmxlZnQgPSBsZWZ0ICsgJ3B4JzsKICAgICAgICB0aXAuc3R5bGUudG9wID0gdG9wICsgJ3B4JzsKICAg
ICAgICBjbGVhclRpbWVvdXQodGlwLl9oaWRlVCk7CiAgICAgICAgdGlwLl9oaWRlVCA9IHNldFRpbWVv
dXQoKCkgPT4gdGlwLmNsYXNzTGlzdC5yZW1vdmUoJ3Nob3cnKSwgMjIwMCk7CiAgICB9CiAgICAvKiBp
bWctaG92ZXItcHJldmlldy12OCAqLwogICAgbGV0IF9faW1nSG92ZXJUaW1lciA9IDAsIF9faW1nSG92
ZXJIaWRlVGltZXIgPSAwLCBfX2ltZ0hvdmVyS2V5ID0gJyc7CiAgICBmdW5jdGlvbiBfX2ltZ0hvdmVy
RW5zdXJlKCkgewogICAgICAgIGxldCBib3ggPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnaW1nLWhv
dmVyLXNpZGUnKTsKICAgICAgICBpZiAoIWJveCkgewogICAgICAgICAgICBib3ggPSBkb2N1bWVudC5j
cmVhdGVFbGVtZW50KCdkaXYnKTsgYm94LmlkID0gJ2ltZy1ob3Zlci1zaWRlJzsKICAgICAgICAgICAg
Y29uc3QgZnJhbWUgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsgZnJhbWUuY2xhc3NOYW1l
ID0gJ2locC1mcmFtZSc7CiAgICAgICAgICAgIGNvbnN0IGltID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVu
dCgnaW1nJyk7IGltLmFsdCA9ICcnOwogICAgICAgICAgICBmcmFtZS5hcHBlbmRDaGlsZChpbSk7IGJv
eC5hcHBlbmRDaGlsZChmcmFtZSk7IGRvY3VtZW50LmJvZHkuYXBwZW5kQ2hpbGQoYm94KTsKICAgICAg
ICB9CiAgICAgICAgbGV0IHN0ID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2ltZy1ob3Zlci1zaWRl
LWNzcycpOwogICAgICAgIGlmICghc3QpIHsgc3QgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdzdHls
ZScpOyBzdC5pZCA9ICdpbWctaG92ZXItc2lkZS1jc3MnOyBkb2N1bWVudC5oZWFkLmFwcGVuZENoaWxk
KHN0KTsgfQogICAgICAgIHN0LnRleHRDb250ZW50ID0gIiNpbWctaG92ZXItc2lkZXtwb3NpdGlvbjpm
aXhlZDt6LWluZGV4OjEwMDAwMDtyaWdodDo2cHg7dG9wOjUwJTt0cmFuc2Zvcm06dHJhbnNsYXRlWSgt
NTAlKTtwb2ludGVyLWV2ZW50czpub25lO29wYWNpdHk6MDt2aXNpYmlsaXR5OmhpZGRlbjttYXgtd2lk
dGg6bWluKDYyMHB4LDkydncpO21heC1oZWlnaHQ6bWluKDkydmgsOTIwcHgpfSNpbWctaG92ZXItc2lk
ZS5zaG93e29wYWNpdHk6MTt2aXNpYmlsaXR5OnZpc2libGV9I2ltZy1ob3Zlci1zaWRlIC5paHAtZnJh
bWV7cGFkZGluZzozcHg7YmFja2dyb3VuZDojZmZmO2JvcmRlcjoxcHggc29saWQgI0M1Q0REQztib3Jk
ZXItcmFkaXVzOjJweDtib3gtc2hhZG93OjAgNnB4IDE4cHggcmdiYSg0NCw0Niw1NCwuMTIpfSNpbWct
aG92ZXItc2lkZSBpbWd7ZGlzcGxheTpibG9jazttYXgtd2lkdGg6bWluKDYxMnB4LDkwdncpO21heC1o
ZWlnaHQ6bWluKDkwdmgsOTAwcHgpO3dpZHRoOmF1dG87aGVpZ2h0OmF1dG87b2JqZWN0LWZpdDpjb250
YWluO2JhY2tncm91bmQ6I2ZmZn0iOwogICAgICAgIHJldHVybiBib3g7CiAgICB9CiAgICB3aW5kb3cu
X19pbWdIb3ZlclNob3cgPSBmdW5jdGlvbihmaWxlLCBpZCkgewogICAgICAgIGNvbnN0IGJhcmUgPSBT
dHJpbmcoZmlsZSB8fCAnJykuc3BsaXQoL1tcXFxcL10vKS5wb3AoKTsgaWYgKCFiYXJlKSByZXR1cm47
CiAgICAgICAgY29uc3QgYm94ID0gX19pbWdIb3ZlckVuc3VyZSgpOyBjb25zdCBpbWcgPSBib3gucXVl
cnlTZWxlY3RvcignaW1nJyk7IGlmICghaW1nKSByZXR1cm47CiAgICAgICAgYm94LmNsYXNzTGlzdC5h
ZGQoJ3Nob3cnKTsKICAgICAgICBpbWcub25lcnJvciA9ICgpID0+IHsKICAgICAgICAgICAgaW1nLm9u
ZXJyb3IgPSAoKSA9PiB7IGltZy5vbmVycm9yID0gbnVsbDsgdHJ5IHsgY29uc3QgYyA9IHRodW1iQ2Fj
aGUgJiYgdGh1bWJDYWNoZS5nZXQoU3RyaW5nKGlkKSk7IGlmIChjKSBpbWcuc3JjID0gYzsgfSBjYXRj
aCAoZSkge30gfTsKICAgICAgICAgICAgaW1nLnNyYyA9IFNUT1JFX0JBU0UgKyAndGhfJyArIGJhcmUu
cmVwbGFjZSgvXC5bXi5dKyQvLCAnJykgKyAnLmpwZyc7CiAgICAgICAgfTsKICAgICAgICBpbWcub25s
b2FkID0gKCkgPT4geyBpbWcub25lcnJvciA9IG51bGw7IH07CiAgICAgICAgaW1nLmRhdGFzZXQuYmFy
ZSA9IGJhcmU7IGltZy5zcmMgPSBTVE9SRV9CQVNFICsgYmFyZTsKICAgIH07CiAgICB3aW5kb3cuX19p
bWdIb3ZlckNsZWFyVWkgPSBmdW5jdGlvbigpIHsKICAgICAgICBfX2ltZ0hvdmVyS2V5ID0gJyc7CiAg
ICAgICAgaWYgKF9faW1nSG92ZXJUaW1lcikgeyBjbGVhclRpbWVvdXQoX19pbWdIb3ZlclRpbWVyKTsg
X19pbWdIb3ZlclRpbWVyID0gMDsgfQogICAgICAgIGlmIChfX2ltZ0hvdmVySGlkZVRpbWVyKSB7IGNs
ZWFyVGltZW91dChfX2ltZ0hvdmVySGlkZVRpbWVyKTsgX19pbWdIb3ZlckhpZGVUaW1lciA9IDA7IH0K
ICAgICAgICBjb25zdCBib3ggPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnaW1nLWhvdmVyLXNpZGUn
KTsgaWYgKGJveCkgYm94LmNsYXNzTGlzdC5yZW1vdmUoJ3Nob3cnKTsKICAgICAgICBjb25zdCBpbWcg
PSBib3ggJiYgYm94LnF1ZXJ5U2VsZWN0b3IoJ2ltZycpOwogICAgICAgIGlmIChpbWcpIHsgaW1nLm9u
bG9hZCA9IG51bGw7IGltZy5vbmVycm9yID0gbnVsbDsgaW1nLnJlbW92ZUF0dHJpYnV0ZSgnc3JjJyk7
IGRlbGV0ZSBpbWcuZGF0YXNldC5iYXJlOyB9CiAgICB9OwogICAgd2luZG93Ll9faW1nSG92ZXJIaWRl
ID0gZnVuY3Rpb24oKSB7IHdpbmRvdy5fX2ltZ0hvdmVyQ2xlYXJVaSgpOyB9OwogICAgZnVuY3Rpb24g
YmluZEltZ0hvdmVyUHJldmlldyhlbCwgaWQsIGZpbGUpIHsKICAgICAgICBpZiAoIWVsKSByZXR1cm47
CiAgICAgICAgY29uc3QgYmFyZSA9IFN0cmluZyhmaWxlIHx8ICcnKS5zcGxpdCgvW1xcXFwvXS8pLnBv
cCgpOyBpZiAoIWJhcmUpIHJldHVybjsKICAgICAgICBjb25zdCBrZXkgPSBTdHJpbmcoaWQpICsgJ3wn
ICsgYmFyZTsKICAgICAgICBlbC5zdHlsZS5jdXJzb3IgPSAnem9vbS1pbic7CiAgICAgICAgZWwuYWRk
RXZlbnRMaXN0ZW5lcignbW91c2VlbnRlcicsICgpID0+IHsKICAgICAgICAgICAgaWYgKF9faW1nSG92
ZXJIaWRlVGltZXIpIHsgY2xlYXJUaW1lb3V0KF9faW1nSG92ZXJIaWRlVGltZXIpOyBfX2ltZ0hvdmVy
SGlkZVRpbWVyID0gMDsgfQogICAgICAgICAgICBfX2ltZ0hvdmVyS2V5ID0ga2V5OwogICAgICAgICAg
ICBpZiAoX19pbWdIb3ZlclRpbWVyKSBjbGVhclRpbWVvdXQoX19pbWdIb3ZlclRpbWVyKTsKICAgICAg
ICAgICAgX19pbWdIb3ZlclRpbWVyID0gc2V0VGltZW91dCgoKSA9PiB7IGlmIChfX2ltZ0hvdmVyS2V5
ID09PSBrZXkpIHRyeSB7IHdpbmRvdy5fX2ltZ0hvdmVyU2hvdyhiYXJlLCBpZCk7IH0gY2F0Y2ggKGUp
IHt9IH0sIDYwKTsKICAgICAgICB9KTsKICAgICAgICBlbC5hZGRFdmVudExpc3RlbmVyKCdtb3VzZWxl
YXZlJywgKCkgPT4gewogICAgICAgICAgICBpZiAoX19pbWdIb3ZlclRpbWVyKSB7IGNsZWFyVGltZW91
dChfX2ltZ0hvdmVyVGltZXIpOyBfX2ltZ0hvdmVyVGltZXIgPSAwOyB9CiAgICAgICAgICAgIF9faW1n
SG92ZXJIaWRlVGltZXIgPSBzZXRUaW1lb3V0KCgpID0+IHsgaWYgKCFfX2ltZ0hvdmVyS2V5IHx8IF9f
aW1nSG92ZXJLZXkgPT09IGtleSkgd2luZG93Ll9faW1nSG92ZXJIaWRlKCk7IH0sIDcwKTsKICAgICAg
ICB9KTsKICAgIH0KICAgIGZ1bmN0aW9uIGhhbmRsZUl0ZW1DbGljayhlLCBjKSB7CiAgICAgICAgaWYg
KGUuc2hpZnRLZXkpIHsKICAgICAgICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOyBlLnN0b3BQcm9wYWdh
dGlvbigpOwogICAgICAgICAgICBjb25zdCBsaXN0ID0gKHR5cGVvZiBuYXZMaXN0ID09PSAnZnVuY3Rp
b24nID8gbmF2TGlzdCgpIDogdmlzaWJsZUxpc3QoKSk7CiAgICAgICAgICAgIGNvbnN0IGFuY2hvck9r
ID0gcmFuZ2VBbmNob3JDbGlja2VkICYmIHJhbmdlQW5jaG9ySWQgJiYgbGlzdC5zb21lKHggPT4gK3gu
aWQgPT09ICtyYW5nZUFuY2hvcklkKTsKICAgICAgICAgICAgaWYgKCFhbmNob3JPaykgcmFuZ2VBbmNo
b3JJZCA9IHNlbGVjdGVkSWQgfHwgYy5pZDsKICAgICAgICAgICAgcmFuZ2VBbmNob3JDbGlja2VkID0g
dHJ1ZTsKICAgICAgICAgICAgc2VsZWN0UmFuZ2VUbyhjLmlkKTsKICAgICAgICAgICAgcmV0dXJuIHRy
dWU7CiAgICAgICAgfQogICAgICAgIGlmIChlLmN0cmxLZXkgfHwgZS5tZXRhS2V5KSB7CiAgICAgICAg
ICAgIGUucHJldmVudERlZmF1bHQoKTsgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICAgICAgdG9n
Z2xlTXVsdGkoYy5pZCk7CiAgICAgICAgICAgIHJldHVybiB0cnVlOwogICAgICAgIH0KICAgICAgICBy
YW5nZUFuY2hvcklkID0gYy5pZDsKICAgICAgICByYW5nZUFuY2hvckNsaWNrZWQgPSB0cnVlOwogICAg
ICAgIHJldHVybiBmYWxzZTsKICAgIH0KICAgIGZ1bmN0aW9uIHRvZ2dsZU11bHRpKGlkKSB7CiAgICAg
ICAgaWQgPSAraWQ7CiAgICAgICAgY29uc3QgaSA9IG11bHRpSWRzLmluZGV4T2YoaWQpOwogICAgICAg
IGlmIChpID49IDApIG11bHRpSWRzLnNwbGljZShpLCAxKTsKICAgICAgICBlbHNlIG11bHRpSWRzLnB1
c2goaWQpOwogICAgICAgIHNlbGVjdGVkSWQgPSBpZDsKICAgICAgICByYW5nZUFuY2hvcklkID0gaWQ7
CiAgICAgICAgcmFuZ2VBbmNob3JDbGlja2VkID0gdHJ1ZTsKICAgICAgICB1cGRhdGVNdWx0aUJhZGdl
KCk7CiAgICB9CgogICAgZnVuY3Rpb24gcmVuZGVyKCkgewogICAgICAgIGhpZGVQYXRoVGlwKCk7Cgog
ICAgICAgIGNvbnN0IHZpc2libGUgPSB2aXNpYmxlTGlzdCgpOwogICAgICAgIGNvbnN0IGxvYWRlZCA9
IGFsbENsaXBzLmxlbmd0aDsKICAgICAgICBjb25zdCBzaG93bkNvdW50ID0gdmlzaWJsZS5sZW5ndGg7
CiAgICAgICAgLy8g5pS26JeP6KeS5qCH77ya55SoIEFISyDkuIvlj5HnmoTmgLvmlbDvvIzpgb/lhY3j
gIzlvZPliY3pobXph4zmlbDlh7rmnaXnmoTjgI3lkowgYmFyIOWvueS4jeS4igogICAgICAgIGxldCBw
aW5uZWROID0gTnVtYmVyKHBpbm5lZFRvdGFsKSB8fCAwOwogICAgICAgIGlmIChwaW5uZWROIDwgMSkg
ewogICAgICAgICAgICBpZiAoY3VyVGFiID09PSAncGlubmVkJykKICAgICAgICAgICAgICAgIHBpbm5l
ZE4gPSBNYXRoLm1heChOdW1iZXIoZGlza1RvdGFsKSB8fCAwLCBsb2FkZWQpOwogICAgICAgICAgICBl
bHNlCiAgICAgICAgICAgICAgICBwaW5uZWROID0gYWxsQ2xpcHMuZmlsdGVyKGMgPT4gaXNQaW5uZWQo
YykpLmxlbmd0aDsKICAgICAgICB9CiAgICAgICAgY29uc3QgcGluQ250ICA9IGRvY3VtZW50LmdldEVs
ZW1lbnRCeUlkKCdwaW4tY250Jyk7CiAgICAgICAgcGluQ250LnRleHRDb250ZW50ICAgPSBwaW5uZWRO
OwogICAgICAgIHBpbkNudC5zdHlsZS5kaXNwbGF5ID0gcGlubmVkTiA/ICcnIDogJ25vbmUnOwogICAg
ICAgIC8vIOaUtuiXjyB0YWLvvJpiYXIg5LiO6KeS5qCH5ZCM5LiA5aWX5oC75pWw77yb5pyq5ruh6aG1
5pe25pi+56S6IOW3suWKoOi9vS/mgLvmlbAKICAgICAgICBsZXQgc2hvd1RvdGFsID0gZGlza1RvdGFs
ID4gMCA/IGRpc2tUb3RhbCA6IChsb2FkZWQgfHwgMCk7CiAgICAgICAgaWYgKGN1clRhYiA9PT0gJ3Bp
bm5lZCcgJiYgcGlubmVkTiA+IHNob3dUb3RhbCkKICAgICAgICAgICAgc2hvd1RvdGFsID0gcGlubmVk
TjsKICAgICAgICBjb25zdCBxT24gPSBTdHJpbmcocXVlcnkgfHwgJycpLnRyaW0oKS5sZW5ndGggPiAw
OwogICAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdiYXItdHh0JykudGV4dENvbnRlbnQgPSBx
T24KICAgICAgICAgICAgPyAoc2hvd25Db3VudCArICcg5p2hJykKICAgICAgICAgICAgOiAoc2hvd1Rv
dGFsID4gbG9hZGVkID8gKHNob3duQ291bnQgKyAnIC8gJyArIHNob3dUb3RhbCArICcg5p2hJykgOiAo
c2hvd1RvdGFsICsgJyDmnaEnKSk7CiAgICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2VtcHR5
LXR4dCcpLnRleHRDb250ZW50ID0gRU1QVFlfTVNHW2N1clRhYl0gfHwgRU1QVFlfTVNHLmFsbDsKCiAg
ICAgICAgY29uc3QgaWRTZXQgPSBuZXcgU2V0KGFsbENsaXBzLm1hcChjID0+ICtjLmlkKSk7CiAgICAg
ICAgbXVsdGlJZHMgPSBtdWx0aUlkcy5maWx0ZXIoaWQgPT4gaWRTZXQuaGFzKGlkKSk7CiAgICAgICAg
dXBkYXRlTXVsdGlCYWRnZSgpOwoKICAgICAgICBjb25zdCBzaG93biA9IHZpc2libGU7CgogICAgICAg
IGxpc3RFbC5xdWVyeVNlbGVjdG9yQWxsKCcuaXRtLCAjbGlzdC1tb3JlJykuZm9yRWFjaChlID0+IGUu
cmVtb3ZlKCkpOwogICAgICAgIC8vIOmqqOaetuW3suWFs+mXre+8muWNs+S9vyB3YWl0aW5nIOS5n+S4
jSByZXR1cm7vvIzmnInmlbDmja7lsLHnm7TmjqXnlLsKICAgICAgICBpZiAoc2tlbEVsKSBza2VsRWwu
Y2xhc3NMaXN0LnJlbW92ZSgnb24nKTsKICAgICAgICBjb25zdCBhcHBCb290ID0gZG9jdW1lbnQuZ2V0
RWxlbWVudEJ5SWQoJ2FwcCcpOwogICAgICAgIGlmIChhcHBCb290KSBhcHBCb290LmNsYXNzTGlzdC5y
ZW1vdmUoJ2Jvb3QtbG9hZGluZycpOwogICAgICAgIGlmICgod2FpdGluZ0RhdGEgfHwgIWhvc3RQdXNo
ZWRPbmNlKSAmJiAhdmlzaWJsZS5sZW5ndGgpIHsKICAgICAgICAgICAgZW1wdHlFbC5jbGFzc0xpc3Qu
cmVtb3ZlKCdvbicpOwogICAgICAgICAgICB1cGRhdGVUb3BCdG4oKTsKICAgICAgICAgICAgcmV0dXJu
OwogICAgICAgIH0KICAgICAgICBpZiAoIXZpc2libGUubGVuZ3RoKSB7CiAgICAgICAgICAgIC8vIE5l
dmVyIHNob3fjgIzmmoLml6DorrDlvZXjgI11bnRpbCB3ZSBoYXZlIHNlZW4gYSByZWFsIG5vbi1lbXB0
eSBwdXNoLAogICAgICAgICAgICAvLyBvciBhIGNvbmZpcm1lZCBlbXB0eSBhZnRlciB3YXJtIChzYXdO
b25FbXB0eSBjYW4gYmUgc2V0IGJ5IGVtcHR5LWZhbGxiYWNrKS4KICAgICAgICAgICAgLy8gRmlsdGVy
ZWQgc2VhcmNoIHdpdGggMCBoaXRzIGlzIGFsbG93ZWQgb25jZSBob3N0IHB1c2hlZC4KICAgICAgICAg
ICAgY29uc3QgcU9uID0gU3RyaW5nKHF1ZXJ5IHx8ICcnKS50cmltKCkubGVuZ3RoID4gMDsKICAgICAg
ICAgICAgY29uc3QgYWxsb3dFbXB0eSA9IGhvc3RQdXNoZWRPbmNlICYmIHNhd05vbkVtcHR5ICYmICF3
YWl0aW5nRGF0YSAmJiAhYm9vdExvYWRpbmcKICAgICAgICAgICAgICAgICYmIChxT24gfHwgZGlza1Rv
dGFsIDw9IDApOwogICAgICAgICAgICBpZiAoIWFsbG93RW1wdHkpIHsKICAgICAgICAgICAgICAgIGVt
cHR5RWwuY2xhc3NMaXN0LnJlbW92ZSgnb24nKTsKICAgICAgICAgICAgICAgIHVwZGF0ZVRvcEJ0bigp
OwogICAgICAgICAgICAgICAgcmV0dXJuOwogICAgICAgICAgICB9CiAgICAgICAgICAgIGlmIChzZWxl
Y3RGaXJzdE9uU2hvdykgewogICAgICAgICAgICAgICAgc2VsZWN0Rmlyc3RPblNob3cgPSBmYWxzZTsK
ICAgICAgICAgICAgICAgIHNlbGVjdGVkSWQgPSAwOwogICAgICAgICAgICAgICAgY2xlYXJNdWx0aSgp
OwogICAgICAgICAgICAgICAgbGlzdEVsLnNjcm9sbFRvcCA9IDA7CiAgICAgICAgICAgIH0KICAgICAg
ICAgICAgZW1wdHlFbC5jbGFzc0xpc3QuYWRkKCdvbicpOwogICAgICAgICAgICB1cGRhdGVUb3BCdG4o
KTsKICAgICAgICAgICAgcmV0dXJuOwogICAgICAgIH0KICAgICAgICBlbXB0eUVsLmNsYXNzTGlzdC5y
ZW1vdmUoJ29uJyk7CiAgICAgICAgY29uc3QgZnJhZyA9IGRvY3VtZW50LmNyZWF0ZURvY3VtZW50RnJh
Z21lbnQoKTsKICAgICAgICBjb25zdCBibG9ja3MgPSBidWlsZFBpbm5lZEJsb2NrcyhzaG93bik7CiAg
ICAgICAgbGV0IG51bSA9IDA7CiAgICAgICAgYmxvY2tzLmZvckVhY2goYiA9PiB7CiAgICAgICAgICAg
IG51bSArPSAxOwogICAgICAgICAgICBpZiAoYi5raW5kID09PSAnZ3JvdXAnICYmIGIuaXRlbXMubGVu
Z3RoID4gMSkKICAgICAgICAgICAgICAgIGZyYWcuYXBwZW5kQ2hpbGQobWFrZUdyb3VwSXRlbShiLml0
ZW1zLCBudW0pKTsKICAgICAgICAgICAgZWxzZQogICAgICAgICAgICAgICAgZnJhZy5hcHBlbmRDaGls
ZChtYWtlSXRlbShiLml0ZW1zWzBdLCBudW0pKTsKICAgICAgICB9KTsKICAgICAgICBsaXN0RWwuYXBw
ZW5kQ2hpbGQoZnJhZyk7CiAgICAgICAgbWFya1F1ZXVlUmFpbHMoKTsKICAgICAgICB1cGRhdGVNb3Jl
Rm9vdGVyKGRpc2tUb3RhbCk7CiAgICAgICAgaWYgKHNlbGVjdEZpcnN0T25TaG93KSB7CiAgICAgICAg
ICAgIHNlbGVjdEZpcnN0T25TaG93ID0gZmFsc2U7CiAgICAgICAgICAgIHNlbGVjdGVkSWQgPSB2aXNp
YmxlWzBdLmlkOwogICAgICAgICAgICBjbGVhck11bHRpKCk7CiAgICAgICAgICAgIGxpc3RFbC5zY3Jv
bGxUb3AgPSAwOwogICAgICAgIH0gZWxzZSBpZiAoIXZpc2libGUuc29tZShjID0+IGMuaWQgPT0gc2Vs
ZWN0ZWRJZCkpIHsKICAgICAgICAgICAgc2VsZWN0ZWRJZCA9IHZpc2libGVbMF0uaWQ7CiAgICAgICAg
ICAgIHJhbmdlQW5jaG9ySWQgPSBzZWxlY3RlZElkOwogICAgICAgICAgICByYW5nZUFuY2hvckNsaWNr
ZWQgPSBmYWxzZTsKICAgICAgICB9IGVsc2UgaWYgKCFyYW5nZUFuY2hvcklkKSB7CiAgICAgICAgICAg
IHJhbmdlQW5jaG9ySWQgPSBzZWxlY3RlZElkOwogICAgICAgIH0KICAgICAgICBzeW5jSXRlbUhpZ2hs
aWdodCgpOwogICAgICAgIHVwZGF0ZVRvcEJ0bigpOwogICAgICAgIGlmICh3aW5kb3cuX19wZW5kaW5n
SnVtcElkKSB7CiAgICAgICAgICAgIGNvbnN0IGppZCA9ICt3aW5kb3cuX19wZW5kaW5nSnVtcElkOwog
ICAgICAgICAgICBjb25zdCBlbCA9IGxpc3RFbC5xdWVyeVNlbGVjdG9yKCcubWctcm93W2RhdGEtaWQ9
IicgKyBqaWQgKyAnIl0nKSB8fCBsaXN0RWwucXVlcnlTZWxlY3RvcignLml0bVtkYXRhLWlkPSInICsg
amlkICsgJyJdJyk7CiAgICAgICAgICAgIGlmIChlbCkgewogICAgICAgICAgICAgICAgd2luZG93Ll9f
cGVuZGluZ0p1bXBJZCA9IDA7CiAgICAgICAgICAgICAgICB3aW5kb3cuX19qdW1wTG9hZFRyaWVzID0g
MDsKICAgICAgICAgICAgICAgIHNlbGVjdGVkSWQgPSBqaWQ7CiAgICAgICAgICAgICAgICByZXF1ZXN0
QW5pbWF0aW9uRnJhbWUoKCkgPT4gewogICAgICAgICAgICAgICAgICAgIGNvbnN0IG5vZGUgPSBsaXN0
RWwucXVlcnlTZWxlY3RvcignLm1nLXJvd1tkYXRhLWlkPSInICsgamlkICsgJyJdJykgfHwgbGlzdEVs
LnF1ZXJ5U2VsZWN0b3IoJy5pdG1bZGF0YS1pZD0iJyArIGppZCArICciXScpOwogICAgICAgICAgICAg
ICAgICAgIGlmICghbm9kZSkgcmV0dXJuOwogICAgICAgICAgICAgICAgICAgIG5vZGUuc2Nyb2xsSW50
b1ZpZXcoeyBibG9jazogJ2NlbnRlcicgfSk7CiAgICAgICAgICAgICAgICAgICAgbm9kZS5jbGFzc0xp
c3QuYWRkKCdqdW1wLWZsYXNoJyk7CiAgICAgICAgICAgICAgICAgICAgc2V0VGltZW91dCgoKSA9PiBu
b2RlLmNsYXNzTGlzdC5yZW1vdmUoJ2p1bXAtZmxhc2gnKSwgOTAwKTsKICAgICAgICAgICAgICAgICAg
ICBzeW5jSXRlbUhpZ2hsaWdodCgpOwogICAgICAgICAgICAgICAgfSk7CiAgICAgICAgICAgIH0gZWxz
ZSBpZiAoYWxsQ2xpcHMubGVuZ3RoIDwgZGlza1RvdGFsICYmICh3aW5kb3cuX19qdW1wTG9hZFRyaWVz
IHx8IDApIDwgNDApIHsKICAgICAgICAgICAgICAgIHdpbmRvdy5fX2p1bXBMb2FkVHJpZXMgPSAod2lu
ZG93Ll9fanVtcExvYWRUcmllcyB8fCAwKSArIDE7CiAgICAgICAgICAgICAgICByZXF1ZXN0TW9yZSgp
OwogICAgICAgICAgICB9IGVsc2UgaWYgKGN1clRhYiAhPT0gJ2FsbCcgJiYgIXdpbmRvdy5fX2p1bXBG
ZWxsQmFjaykgewogICAgICAgICAgICAgICAgLy8gSXRlbSBnb25lIGZyb20gdGhpcyB0YWIgKGUuZy4g
dW5waW5uZWQpIOKAlCBmYWxsIGJhY2sgdG8g5YWo6YOoIG9uY2UKICAgICAgICAgICAgICAgIHdpbmRv
dy5fX2p1bXBGZWxsQmFjayA9IHRydWU7CiAgICAgICAgICAgICAgICB3aW5kb3cuX19qdW1wTG9hZFRy
aWVzID0gMDsKICAgICAgICAgICAgICAgIGN1clRhYiA9ICdhbGwnOwogICAgICAgICAgICAgICAgbWFy
a1RhYignYWxsJyk7CiAgICAgICAgICAgICAgICByZXF1ZXN0VmlldygpOwogICAgICAgICAgICB9IGVs
c2UgewogICAgICAgICAgICAgICAgd2luZG93Ll9fcGVuZGluZ0p1bXBJZCA9IDA7CiAgICAgICAgICAg
ICAgICB3aW5kb3cuX19qdW1wTG9hZFRyaWVzID0gMDsKICAgICAgICAgICAgICAgIGlmIChhbGxDbGlw
cy5zb21lKGMgPT4gK2MuaWQgPT09IGppZCkpCiAgICAgICAgICAgICAgICAgICAgc2VsZWN0ZWRJZCA9
IGppZDsKICAgICAgICAgICAgICAgIHN5bmNJdGVtSGlnaGxpZ2h0KCk7CiAgICAgICAgICAgIH0KICAg
ICAgICB9CiAgICAgICAgcmVxdWVzdEFuaW1hdGlvbkZyYW1lKCgpID0+IHsKICAgICAgICAgICAgaWYg
KGFsbENsaXBzLmxlbmd0aCA8IGRpc2tUb3RhbAogICAgICAgICAgICAgICAgJiYgbGlzdEVsLnNjcm9s
bEhlaWdodCA8PSBsaXN0RWwuY2xpZW50SGVpZ2h0ICsgMjApCiAgICAgICAgICAgICAgICByZXF1ZXN0
TW9yZSgpOwogICAgICAgICAgICBzY2hlZHVsZUZpbGVHb25lQ2hlY2soKTsKICAgICAgICB9KTsKICAg
IH0KCiAgICBjb25zdCBTVkcgPSB7CiAgICAgICAgdGV4dDogICBgPHN2ZyB2aWV3Qm94PSIwIDAgMjQg
MjQiIGZpbGw9Im5vbmUiIHN0cm9rZT0iY3VycmVudENvbG9yIiBzdHJva2Utd2lkdGg9IjIiPjxwYXRo
IGQ9Ik00IDdWNGgxNnYzTTkgMjBoNk0xMiA0djE2Ii8+PC9zdmc+YCwKICAgICAgICBtZDogICAgIGA8
c3ZnIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0iY3VycmVudENvbG9yIj48dGV4dCB4PSIxMiIgeT0i
MTciIHRleHQtYW5jaG9yPSJtaWRkbGUiIGZvbnQtc2l6ZT0iMTUiIGZvbnQtd2VpZ2h0PSI4MDAiIGZv
bnQtZmFtaWx5PSJTZWdvZSBVSSxNaWNyb3NvZnQgWWFIZWksc2Fucy1zZXJpZiI+TTwvdGV4dD48L3N2
Zz5gLAogICAgICAgIGltYWdlOiAgYDxzdmcgdmlld0JveD0iMCAwIDI0IDI0IiBmaWxsPSJub25lIiBz
dHJva2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIxLjgiPjxyZWN0IHg9IjMiIHk9IjUiIHdp
ZHRoPSIxOCIgaGVpZ2h0PSIxNCIgcng9IjIiLz48Y2lyY2xlIGN4PSI4LjUiIGN5PSIxMCIgcj0iMS41
IiBmaWxsPSJjdXJyZW50Q29sb3IiIHN0cm9rZT0ibm9uZSIvPjxwYXRoIGQ9Ik0zIDE2bDUtNSA0IDQg
My0zIDYgNiIvPjwvc3ZnPmAsCiAgICAgICAgdmlkZW86ICBgPHN2ZyB2aWV3Qm94PSIwIDAgMjQgMjQi
IGZpbGw9Im5vbmUiIHN0cm9rZT0iY3VycmVudENvbG9yIiBzdHJva2Utd2lkdGg9IjEuOCI+PHJlY3Qg
eD0iMyIgeT0iNiIgd2lkdGg9IjE0IiBoZWlnaHQ9IjEyIiByeD0iMiIvPjxwYXRoIGQ9Ik0xNyA5LjVs
NC0yLjV2MTBsLTQtMi41VjkuNXoiIGZpbGw9ImN1cnJlbnRDb2xvciIgc3Ryb2tlPSJub25lIi8+PHBh
dGggZD0iTTguNSAxMC4ydjMuNmwzLjItMS44LTMuMi0xLjh6IiBmaWxsPSJjdXJyZW50Q29sb3IiIHN0
cm9rZT0ibm9uZSIvPjwvc3ZnPmAsCiAgICAgICAgZm9sZGVyOiBgPHN2ZyB2aWV3Qm94PSIwIDAgMjQg
MjQiIGZpbGw9ImN1cnJlbnRDb2xvciI+PHBhdGggZD0iTTEwIDRINGMtMS4xIDAtMiAuOS0yIDJ2MTJj
MCAxLjEuOSAyIDIgMmgxNmMxLjEgMCAyLS45IDItMlY4YzAtMS4xLS45LTItMi0yaC04bC0yLTJ6Ii8+
PC9zdmc+YCwKICAgICAgICB6aXA6ICAgIGA8c3ZnIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0ibm9u
ZSIgc3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0cm9rZS13aWR0aD0iMS44Ij48cGF0aCBkPSJNNiAzaDls
NSA1djEzYTEgMSAwIDAgMS0xIDFINmExIDEgMCAwIDEtMS0xVjRhMSAxIDAgMCAxIDEtMXoiLz48cGF0
aCBkPSJNMTQgM3Y2aDYiLz48L3N2Zz5gLAogICAgICAgIGFoazogICAgYDxzdmcgdmlld0JveD0iMCAw
IDI0IDI0IiBmaWxsPSJjdXJyZW50Q29sb3IiPjx0ZXh0IHg9IjEyIiB5PSIxNyIgdGV4dC1hbmNob3I9
Im1pZGRsZSIgZm9udC1zaXplPSIxNCIgZm9udC13ZWlnaHQ9IjcwMCI+SDwvdGV4dD48L3N2Zz5gLAog
ICAgICAgIGxuazogICAgYDxzdmcgdmlld0JveD0iMCAwIDI0IDI0IiBmaWxsPSJub25lIiBzdHJva2U9
ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIxLjgiPjxwYXRoIGQ9Ik0xMCAxM2E1IDUgMCAwIDAg
Ny4wNyAwbDIuMTItMi4xMmE1IDUgMCAwIDAtNy4wNy03LjA3TDExIDUiLz48cGF0aCBkPSJNMTQgMTFh
NSA1IDAgMCAwLTcuMDcgMEw0LjggMTMuMTJhNSA1IDAgMSAwIDcuMDcgNy4wN0wxMyAxOSIvPjwvc3Zn
PmAsCiAgICAgICAgZG9jOiAgICBgPHN2ZyB2aWV3Qm94PSIwIDAgMjQgMjQiIGZpbGw9Im5vbmUiIHN0
cm9rZT0iY3VycmVudENvbG9yIiBzdHJva2Utd2lkdGg9IjEuOCI+PHBhdGggZD0iTTcgM2g3bDUgNXYx
M2ExIDEgMCAwIDEtMSAxSDdhMSAxIDAgMCAxLTEtMVY0YTEgMSAwIDAgMSAxLTF6Ii8+PHBhdGggZD0i
TTE0IDN2Nmg2Ii8+PC9zdmc+YCwKICAgICAgICBtdWx0aTogIGA8c3ZnIHZpZXdCb3g9IjAgMCAyNCAy
NCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0cm9rZS13aWR0aD0iMS44Ij48cmVj
dCB4PSI3IiB5PSI3IiB3aWR0aD0iMTIiIGhlaWdodD0iMTQiIHJ4PSIxLjUiLz48cGF0aCBkPSJNNSAx
N1Y1YTEgMSAwIDAgMSAxLTFoMTAiLz48L3N2Zz5gCiAgICB9OwoKICAgIGZ1bmN0aW9uIGZpbGVFeHQo
cGF0aCkgewogICAgICAgIGNvbnN0IGJhc2UgPSBTdHJpbmcocGF0aCB8fCAnJykuc3BsaXQoL1tcXC9d
LykucG9wKCkgfHwgJyc7CiAgICAgICAgY29uc3QgaSA9IGJhc2UubGFzdEluZGV4T2YoJy4nKTsKICAg
ICAgICByZXR1cm4gaSA+IDAgPyBiYXNlLnNsaWNlKGkgKyAxKS50b0xvd2VyQ2FzZSgpIDogJyc7CiAg
ICB9CiAgICBjb25zdCBpc0ltYWdlRXh0ID0gZSA9PiBbJ3BuZycsJ2pwZycsJ2pwZWcnLCdnaWYnLCd3
ZWJwJywnYm1wJywnaWNvJywndGlmJywndGlmZicsJ3N2ZyddLmluY2x1ZGVzKGUpOwogICAgY29uc3Qg
aXNWaWRlb0V4dCA9IGUgPT4gWydtcDQnLCdta3YnLCdhdmknLCdtb3YnLCd3bXYnLCdmbHYnLCd3ZWJt
JywnbTR2JywnbXBlZycsJ21wZycsJ3RzJywnbTJ0cycsJzNncCcsJ3JtJywncm12YiddLmluY2x1ZGVz
KGUpOwogICAgY29uc3QgaXNaaXBFeHQgICA9IGUgPT4gWyd6aXAnLCdyYXInLCc3eicsJ3RhcicsJ2d6
JywnYnoyJ10uaW5jbHVkZXMoZSk7CgogICAgZnVuY3Rpb24gaWNvbkZvckZpbGVzKGZpbGVzKSB7CiAg
ICAgICAgaWYgKCFmaWxlcy5sZW5ndGgpICAgIHJldHVybiB7IGNsczogJ2ZpbGUgZnQtZG9jJywgc3Zn
OiBTVkcuZG9jIH07CiAgICAgICAgaWYgKGZpbGVzLmxlbmd0aCA+IDEpIHJldHVybiB7IGNsczogJ2Zp
bGUgZnQtbG5rJywgc3ZnOiBTVkcubXVsdGkgfTsKICAgICAgICBjb25zdCBleHQgPSBmaWxlRXh0KGZp
bGVzWzBdKTsKICAgICAgICBpZiAoIWV4dCkgICAgICAgICAgICAgIHJldHVybiB7IGNsczogJ2ZpbGUg
ZnQtZGlyJywgc3ZnOiBTVkcuZm9sZGVyIH07CiAgICAgICAgaWYgKGlzSW1hZ2VFeHQoZXh0KSkgICBy
ZXR1cm4geyBjbHM6ICdmaWxlIGZ0LWltZycsIHN2ZzogU1ZHLmltYWdlIH07CiAgICAgICAgaWYgKGlz
VmlkZW9FeHQoZXh0KSkgICByZXR1cm4geyBjbHM6ICdmaWxlIGZ0LXZpZCcsIHN2ZzogKFNWRy52aWRl
byB8fCBTVkcuZG9jKSB9OwogICAgICAgIGlmIChpc1ppcEV4dChleHQpKSAgICAgcmV0dXJuIHsgY2xz
OiAnZmlsZSBmdC16aXAnLCBzdmc6IFNWRy56aXAgfTsKICAgICAgICBpZiAoZXh0ID09PSAnYWhrJykg
ICAgIHJldHVybiB7IGNsczogJ2ZpbGUgZnQtYWhrJywgc3ZnOiBTVkcuYWhrIH07CiAgICAgICAgaWYg
KGV4dCA9PT0gJ2xuaycpICAgICByZXR1cm4geyBjbHM6ICdmaWxlIGZ0LWxuaycsIHN2ZzogU1ZHLmxu
ayB9OwogICAgICAgIHJldHVybiB7IGNsczogJ2ZpbGUgZnQtZG9jJywgc3ZnOiBTVkcuZG9jIH07CiAg
ICB9CgogICAgZnVuY3Rpb24gc3JjV2luTGFiZWwoYykgewogICAgICAgIGNvbnN0IHQgPSBTdHJpbmco
YyAmJiBjLnNyY1RpdGxlIHx8ICcnKS50cmltKCk7CiAgICAgICAgaWYgKHQpIHJldHVybiB0OwogICAg
ICAgIHJldHVybiBTdHJpbmcoYyAmJiBjLnNyY0V4ZSB8fCAnJykucmVwbGFjZSgvXC5leGUkL2ksICcn
KTsKICAgIH0KICAgIGZ1bmN0aW9uIHNyY1RpdGxlSHRtbChjKSB7CiAgICAgICAgLy8g5YiX6KGo5Lit
6Ze0L+WPs+S+p+S4jeWGjeaYvuekuueql+WPo+agh+mimO+8jOadpea6kOWPquS/neeVmeWPs+S+p+Wb
vuagh+aCrOWBnOaPkOekugogICAgICAgIHJldHVybiAnJzsKICAgIH0KICAgIGZ1bmN0aW9uIGV4cGFu
ZENoZXZyb24ob3BlbikgewogICAgICAgIHJldHVybiBvcGVuCiAgICAgICAgICAgID8gYDxzdmcgdmll
d0JveD0iMCAwIDE2IDE2IiB3aWR0aD0iMTQiIGhlaWdodD0iMTQiIGZpbGw9Im5vbmUiIHN0cm9rZT0i
Y3VycmVudENvbG9yIiBzdHJva2Utd2lkdGg9IjEuOCIgc3Ryb2tlLWxpbmVjYXA9InJvdW5kIj48cG9s
eWxpbmUgcG9pbnRzPSI0IDEwIDggNiAxMiAxMCIvPjwvc3ZnPjxzcGFuPuaUtui1tzwvc3Bhbj5gCiAg
ICAgICAgICAgIDogYDxzdmcgdmlld0JveD0iMCAwIDE2IDE2IiB3aWR0aD0iMTQiIGhlaWdodD0iMTQi
IGZpbGw9Im5vbmUiIHN0cm9rZT0iY3VycmVudENvbG9yIiBzdHJva2Utd2lkdGg9IjEuOCIgc3Ryb2tl
LWxpbmVjYXA9InJvdW5kIj48cG9seWxpbmUgcG9pbnRzPSI0IDYgOCAxMCAxMiA2Ii8+PC9zdmc+PHNw
YW4+5bGV5byAPC9zcGFuPmA7CiAgICB9CiAgICBmdW5jdGlvbiBsaXN0RXhwYW5kTWF4UHgoKSB7CiAg
ICAgICAgY29uc3QgaCA9IChsaXN0RWwgJiYgbGlzdEVsLmNsaWVudEhlaWdodCkgfHwgMzYwOwogICAg
ICAgIC8vIOWHoOS5juWNoOa7oeWIl+ihqO+8jOW6lemDqOeVmee6puS4gOihjAogICAgICAgIHJldHVy
biBNYXRoLm1heCg5NiwgaCAtIDI4KTsKICAgIH0KICAgIGZ1bmN0aW9uIGFwcGx5RXhwYW5kZWRQcmV2
aWV3KHByZXYsIGZ1bGxUZXh0KSB7CiAgICAgICAgY29uc3QgbWF4SCA9IGxpc3RFeHBhbmRNYXhQeCgp
OwogICAgICAgIHByZXYuc3R5bGUubWF4SGVpZ2h0ID0gbWF4SCArICdweCc7CiAgICAgICAgcHJldi5j
bGFzc0xpc3QuYWRkKCdleHBhbmRlZCcpOwogICAgICAgIHNldEhsVGV4dChwcmV2LCBmdWxsVGV4dCk7
CiAgICAgICAgLy8g5LuN5rqi5Ye677ya5oiq5pat5bm25Zyo5pyr5bC+5Yqg44CMIC4uLuOAjQogICAg
ICAgIGlmIChwcmV2LnNjcm9sbEhlaWdodCA8PSBwcmV2LmNsaWVudEhlaWdodCArIDIpCiAgICAgICAg
ICAgIHJldHVybjsKICAgICAgICBsZXQgbG8gPSAwLCBoaSA9IGZ1bGxUZXh0Lmxlbmd0aCwgYmVzdCA9
IDA7CiAgICAgICAgd2hpbGUgKGxvIDw9IGhpKSB7CiAgICAgICAgICAgIGNvbnN0IG1pZCA9IChsbyAr
IGhpKSA+PiAxOwogICAgICAgICAgICBzZXRIbFRleHQocHJldiwgZnVsbFRleHQuc2xpY2UoMCwgbWlk
KSArICcgLi4uJyk7CiAgICAgICAgICAgIGlmIChwcmV2LnNjcm9sbEhlaWdodCA8PSBwcmV2LmNsaWVu
dEhlaWdodCArIDIpIHsKICAgICAgICAgICAgICAgIGJlc3QgPSBtaWQ7CiAgICAgICAgICAgICAgICBs
byA9IG1pZCArIDE7CiAgICAgICAgICAgIH0gZWxzZSB7CiAgICAgICAgICAgICAgICBoaSA9IG1pZCAt
IDE7CiAgICAgICAgICAgIH0KICAgICAgICB9CiAgICAgICAgc2V0SGxUZXh0KHByZXYsIGZ1bGxUZXh0
LnNsaWNlKDAsIGJlc3QpICsgJyAuLi4nKTsKICAgIH0KICAgIGZ1bmN0aW9uIGNvbGxhcHNlUHJldmll
dyhwcmV2LCBmdWxsVGV4dCkgewogICAgICAgIHByZXYuY2xhc3NMaXN0LnJlbW92ZSgnZXhwYW5kZWQn
KTsKICAgICAgICBwcmV2LnN0eWxlLm1heEhlaWdodCA9ICcnOwogICAgICAgIHNldEhsVGV4dChwcmV2
LCBmdWxsVGV4dCk7CiAgICB9CgogICAgZnVuY3Rpb24gZmF2R3JvdXBPZihjKSB7CiAgICAgICAgcmV0
dXJuIFN0cmluZyhjICYmIGMuZmF2R3JvdXAgfHwgJycpLnRyaW0oKTsKICAgIH0KICAgIGZ1bmN0aW9u
IGNsaXBDb250ZW50UHJldmlldyhjKSB7CiAgICAgICAgY29uc3QgdHlwZSA9IG5vcm1UeXBlKGMudHlw
ZSk7CiAgICAgICAgaWYgKHR5cGUgPT09ICdpbWFnZScpIHJldHVybiAnW+WbvuWDj10nICsgKGMud2lk
dGggJiYgYy5oZWlnaHQgPyAoJyAnICsgYy53aWR0aCArICfDlycgKyBjLmhlaWdodCkgOiAnJyk7CiAg
ICAgICAgaWYgKHR5cGUgPT09ICdmaWxlJykgewogICAgICAgICAgICBjb25zdCBmaWxlcyA9IFN0cmlu
ZyhjLnByZXZpZXcgfHwgYy5kYXRhIHx8ICcnKS5zcGxpdCgvXHI/XG4vKS5maWx0ZXIoQm9vbGVhbik7
CiAgICAgICAgICAgIHJldHVybiBmaWxlcy5tYXAoZiA9PiBmLnNwbGl0KC9bXFwvXS8pLnBvcCgpKS5q
b2luKCcgwrcgJykgfHwgJ1vmlofku7ZdJzsKICAgICAgICB9CiAgICAgICAgbGV0IF9wID0gU3RyaW5n
KGMucHJldmlldyB8fCBjLmRhdGEgfHwgJycpOwogICAgICAgIHsgY29uc3QgX24gPSBOdW1iZXIoYy5j
aGFyQ291bnQpIHx8IDA7IGlmIChfbiA+IF9wLmxlbmd0aCAmJiBfcC5sZW5ndGgpIF9wICs9ICcuLi4n
OyB9CiAgICAgICAgcmV0dXJuIF9wOwogICAgfQogICAgZnVuY3Rpb24gYnVpbGRQaW5uZWRCbG9ja3Mo
bGlzdCkgewogICAgICAgIGNvbnN0IHVzZWQgPSBuZXcgU2V0KCk7CiAgICAgICAgY29uc3Qgb3V0ID0g
W107CiAgICAgICAgZm9yIChjb25zdCBjIG9mIGxpc3QpIHsKICAgICAgICAgICAgaWYgKHVzZWQuaGFz
KCtjLmlkKSkgY29udGludWU7CiAgICAgICAgICAgIGNvbnN0IGdpZCA9IGZhdkdyb3VwT2YoYyk7CiAg
ICAgICAgICAgIGlmICghZ2lkKSB7CiAgICAgICAgICAgICAgICB1c2VkLmFkZCgrYy5pZCk7CiAgICAg
ICAgICAgICAgICBvdXQucHVzaCh7IGtpbmQ6ICdzaW5nbGUnLCBpdGVtczogW2NdIH0pOwogICAgICAg
ICAgICAgICAgY29udGludWU7CiAgICAgICAgICAgIH0KICAgICAgICAgICAgY29uc3QgbWVtYmVycyA9
IGxpc3QuZmlsdGVyKHggPT4gZmF2R3JvdXBPZih4KSA9PT0gZ2lkKTsKICAgICAgICAgICAgbWVtYmVy
cy5mb3JFYWNoKG0gPT4gdXNlZC5hZGQoK20uaWQpKTsKICAgICAgICAgICAgaWYgKG1lbWJlcnMubGVu
Z3RoIDwgMikKICAgICAgICAgICAgICAgIG91dC5wdXNoKHsga2luZDogJ3NpbmdsZScsIGl0ZW1zOiBb
bWVtYmVyc1swXSB8fCBjXSB9KTsKICAgICAgICAgICAgZWxzZQogICAgICAgICAgICAgICAgb3V0LnB1
c2goeyBraW5kOiAnZ3JvdXAnLCBnaWQsIGl0ZW1zOiBtZW1iZXJzIH0pOwogICAgICAgIH0KICAgICAg
ICByZXR1cm4gb3V0OwogICAgfQogICAgZnVuY3Rpb24gX19wcmVwUGFzdGUoKSB7CiAgICAgICAgdHJ5
IHsKICAgICAgICAgICAgY29uc3QgcyA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzZWFyY2gnKTsK
ICAgICAgICAgICAgaWYgKHMgJiYgZG9jdW1lbnQuYWN0aXZlRWxlbWVudCA9PT0gcykgdHJ5IHsgcy5i
bHVyKCk7IH0gY2F0Y2gge30KICAgICAgICAgICAgaWYgKHdpbmRvdy5nZXRTZWxlY3Rpb24pIHdpbmRv
dy5nZXRTZWxlY3Rpb24oKS5yZW1vdmVBbGxSYW5nZXMoKTsKICAgICAgICB9IGNhdGNoIHt9CiAgICB9
CiAgICBmdW5jdGlvbiBwYXN0ZU9uZShjKSB7CiAgICAgICAgX19wcmVwUGFzdGUoKTsKICAgICAgICBz
ZWxlY3RlZElkID0gYy5pZDsKICAgICAgICBpZiAobXVsdGlJZHMubGVuZ3RoKSBjbGVhck11bHRpKCk7
CiAgICAgICAgc3luY0l0ZW1IaWdobGlnaHQoKTsKICAgICAgICBtYXJrUGFzdGVkTG9jYWwoYy5pZCk7
CiAgICAgICAgYWhrKCdwYXN0ZScsIFN0cmluZyhjLmlkKSk7CiAgICB9CiAgICBmdW5jdGlvbiBvcGVu
UmVjZW50RGlyKHBhdGgpIHsKICAgICAgICBsZXQgcCA9IFN0cmluZyhwYXRoIHx8ICcnKS50cmltKCk7
CiAgICAgICAgaWYgKCFwKSByZXR1cm47CiAgICAgICAgaWYgKC9eW2EtekEtWl06JC8udGVzdChwKSkg
cCArPSAnXFwnOwogICAgICAgIC8vIOe7n+S4gCAvIO+8mumBv+WFjSBXZWJWaWV3IGhvc3QvSlNPTiDl
kIPmjonlj43mlpzmnaAKICAgICAgICBjb25zdCB3aXJlID0gcC5yZXBsYWNlKC9cXC9nLCAnLycpOwog
ICAgICAgIGNvbnN0IHNlbmQgPSAoKSA9PiB7CiAgICAgICAgICAgIC8vIDEpIHBvc3RNZXNzYWdlIOac
gOeos++8iOS4jei/myBzeW5jIENPTe+8iQogICAgICAgICAgICB0cnkgewogICAgICAgICAgICAgICAg
aWYgKHdpbmRvdy5jaHJvbWUgJiYgY2hyb21lLndlYnZpZXcgJiYgdHlwZW9mIGNocm9tZS53ZWJ2aWV3
LnBvc3RNZXNzYWdlID09PSAnZnVuY3Rpb24nKSB7CiAgICAgICAgICAgICAgICAgICAgY2hyb21lLndl
YnZpZXcucG9zdE1lc3NhZ2UoJ29wZW5EaXJ8JyArIHdpcmUpOwogICAgICAgICAgICAgICAgICAgIHJl
dHVybiB0cnVlOwogICAgICAgICAgICAgICAgfQogICAgICAgICAgICB9IGNhdGNoIHt9CiAgICAgICAg
ICAgIC8vIDIpIGFzeW5jIGhvc3TvvIjpnZ4gc3luY++8iQogICAgICAgICAgICB0cnkgewogICAgICAg
ICAgICAgICAgY29uc3QgaG9zdCA9IGNocm9tZS53ZWJ2aWV3Lmhvc3RPYmplY3RzLmFoazsKICAgICAg
ICAgICAgICAgIGlmIChob3N0ICYmIGhvc3Qub3BlbkRpcikgewogICAgICAgICAgICAgICAgICAgIFBy
b21pc2UucmVzb2x2ZShob3N0Lm9wZW5EaXIod2lyZSkpLmNhdGNoKCgpID0+IHt9KTsKICAgICAgICAg
ICAgICAgICAgICByZXR1cm4gdHJ1ZTsKICAgICAgICAgICAgICAgIH0KICAgICAgICAgICAgfSBjYXRj
aCB7fQogICAgICAgICAgICAvLyAzKSDmnIDlkI7miY0gc3luYwogICAgICAgICAgICB0cnkgeyBhaGso
J29wZW5EaXInLCB3aXJlKTsgcmV0dXJuIHRydWU7IH0gY2F0Y2gge30KICAgICAgICAgICAgcmV0dXJu
IGZhbHNlOwogICAgICAgIH07CiAgICAgICAgLy8g56a75byAIHBvaW50ZXIg5LqL5Lu25qCI5YaN6LCD
77yM6YG/5YWNIFdlYlZpZXcyIOWQjOatpeatu+mUgeWvvOiHtOKAnOeCueS6huayoeWPjeW6lOKAnQog
ICAgICAgIHNldFRpbWVvdXQoc2VuZCwgMCk7CiAgICB9CiAgICBmdW5jdGlvbiBpc0l0ZW1DaHJvbWVU
YXJnZXQodCkgewogICAgICAgIHJldHVybiAhISh0ICYmIHQuY2xvc2VzdCAmJiB0LmNsb3Nlc3QoJy5p
LWV4cGFuZC1idG4sIC5pLXNyYy1pY28sIC5tZy1zcmMsIC5mZC1idG4sIC5mZC1wYXRoLCAucmYtc2Vn
LCBidXR0b24sIGEsIGlucHV0JykpOwogICAgfQogICAgZnVuY3Rpb24gYmVnaW5QYXN0ZUZyb21JdGVt
KGUsIGMpIHsKICAgICAgICBpZiAoZS5idXR0b24gIT0gbnVsbCAmJiBlLmJ1dHRvbiAhPT0gMCkgcmV0
dXJuOwogICAgICAgIGNvbnN0IHNlZyA9IGUudGFyZ2V0ICYmIGUudGFyZ2V0LmNsb3Nlc3QgJiYgZS50
YXJnZXQuY2xvc2VzdCgnLnJmLXNlZycpOwogICAgICAgIGlmIChzZWcpIHsKICAgICAgICAgICAgY29u
c3Qgb3BlblBhdGggPSBzZWcuX29wZW5QYXRoIHx8IHNlZy5nZXRBdHRyaWJ1dGUoJ2RhdGEtcGF0aCcp
IHx8IHNlZy5kYXRhc2V0Lm9wZW5QYXRoIHx8ICcnOwogICAgICAgICAgICBpZiAob3BlblBhdGgpIHsK
ICAgICAgICAgICAgICAgIGUucHJldmVudERlZmF1bHQoKTsKICAgICAgICAgICAgICAgIGUuc3RvcFBy
b3BhZ2F0aW9uKCk7CiAgICAgICAgICAgICAgICBvcGVuUmVjZW50RGlyKG9wZW5QYXRoKTsKICAgICAg
ICAgICAgICAgIHJldHVybjsKICAgICAgICAgICAgfQogICAgICAgIH0KICAgICAgICBpZiAoZS50YXJn
ZXQgJiYgZS50YXJnZXQuY2xvc2VzdCAmJiBlLnRhcmdldC5jbG9zZXN0KCcucmYtcGF0aCcpKQogICAg
ICAgICAgICByZXR1cm47CiAgICAgICAgaWYgKGlzSXRlbUNocm9tZVRhcmdldChlLnRhcmdldCkpIHJl
dHVybjsKICAgICAgICBpZiAobm9ybVR5cGUoYy50eXBlKSA9PT0gJ3JlY2VudCcpIHsKICAgICAgICAg
ICAgYWN0aXZhdGVDbGlwSXRlbShjKTsKICAgICAgICAgICAgcmV0dXJuOwogICAgICAgIH0KICAgICAg
ICBpZiAoaGFuZGxlSXRlbUNsaWNrKGUsIGMpKQogICAgICAgICAgICByZXR1cm47CiAgICAgICAgX19w
cmVwUGFzdGUoKTsKICAgICAgICBzZWxlY3RlZElkID0gYy5pZDsKICAgICAgICByYW5nZUFuY2hvcklk
ID0gYy5pZDsKICAgICAgICBpZiAobXVsdGlJZHMubGVuZ3RoID4gMCAmJiBtdWx0aUlkcy5pbmNsdWRl
cygrYy5pZCkpIHsKICAgICAgICAgICAgY29uc3QgaWRzID0gbXVsdGlJZHMuc2xpY2UoKTsKICAgICAg
ICAgICAgY2xlYXJNdWx0aSgpOwogICAgICAgICAgICBtYXJrUGFzdGVkTG9jYWwoaWRzKTsKICAgICAg
ICAgICAgaWYgKGlkcy5sZW5ndGggPiAxKSBhaGsoJ3Bhc3RlTWFueScsIGlkcy5qb2luKCcsJykpOwog
ICAgICAgICAgICBlbHNlIGFoaygncGFzdGUnLCBTdHJpbmcoaWRzWzBdKSk7CiAgICAgICAgICAgIHJl
dHVybjsKICAgICAgICB9CiAgICAgICAgaWYgKG11bHRpSWRzLmxlbmd0aCkgY2xlYXJNdWx0aSgpOwog
ICAgICAgIHN5bmNJdGVtSGlnaGxpZ2h0KCk7CiAgICAgICAgbWFya1Bhc3RlZExvY2FsKGMuaWQpOwog
ICAgICAgIGFoaygncGFzdGUnLCBTdHJpbmcoYy5pZCkpOwogICAgfQogICAgZnVuY3Rpb24gbWFrZUdy
b3VwSXRlbShpdGVtcywgaWR4KSB7CiAgICAgICAgY29uc3QgZWwgPSBkb2N1bWVudC5jcmVhdGVFbGVt
ZW50KCdkaXYnKTsKICAgICAgICBlbC5jbGFzc05hbWUgPSAnaXRtIGl0LWdyb3VwJwogICAgICAgICAg
ICArIChpdGVtcy5zb21lKGMgPT4gK2MuaWQgPT09ICtzZWxlY3RlZElkKSA/ICcgc2VsJyA6ICcnKQog
ICAgICAgICAgICArIChpdGVtcy5zb21lKGMgPT4gbXVsdGlJZHMuaW5jbHVkZXMoK2MuaWQpKSA/ICcg
bXVsdGknIDogJycpOwogICAgICAgIGVsLmRhdGFzZXQuZ3JvdXAgPSBmYXZHcm91cE9mKGl0ZW1zWzBd
KSB8fCAnJzsKICAgICAgICBlbC5kYXRhc2V0LmlkID0gaXRlbXNbMF0uaWQ7CgogICAgICAgIGNvbnN0
IGhlYWQgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsKICAgICAgICBoZWFkLmNsYXNzTmFt
ZSA9ICdtZy1oZWFkJzsKICAgICAgICBoZWFkLmlubmVySFRNTCA9ICc8c3BhbiBjbGFzcz0ibWctdGFn
Ij7lkIjlubY8L3NwYW4+PHNwYW4+JyArIGl0ZW1zLmxlbmd0aCArICcg5p2hIMK3IOeCueWHu+WNlead
oeeymOi0tDwvc3Bhbj4nOwogICAgICAgIGVsLmFwcGVuZENoaWxkKGhlYWQpOwoKICAgICAgICBpdGVt
cy5mb3JFYWNoKGMgPT4gewogICAgICAgICAgICBjb25zdCByb3cgPSBkb2N1bWVudC5jcmVhdGVFbGVt
ZW50KCdkaXYnKTsKICAgICAgICAgICAgcm93LmNsYXNzTmFtZSA9ICdtZy1yb3cnCiAgICAgICAgICAg
ICAgICArICgrc2VsZWN0ZWRJZCA9PT0gK2MuaWQgPyAnIHNlbCcgOiAnJykKICAgICAgICAgICAgICAg
ICsgKG11bHRpSWRzLmluY2x1ZGVzKCtjLmlkKSA/ICcgbXVsdGknIDogJycpOwogICAgICAgICAgICBy
b3cuZGF0YXNldC5pZCA9IGMuaWQ7CgogICAgICAgICAgICBjb25zdCB0b3AgPSBkb2N1bWVudC5jcmVh
dGVFbGVtZW50KCdkaXYnKTsKICAgICAgICAgICAgdG9wLmNsYXNzTmFtZSA9ICdtZy1yb3ctdG9wJzsK
ICAgICAgICAgICAgY29uc3QgbWFpbiA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOwogICAg
ICAgICAgICBtYWluLmNsYXNzTmFtZSA9ICdtZy1yb3ctbWFpbic7CgogICAgICAgICAgICBjb25zdCB0
aXRsZSA9IFN0cmluZyhjLmZhdlRpdGxlIHx8ICcnKS50cmltKCk7CiAgICAgICAgICAgIGlmICh0aXRs
ZSkgewogICAgICAgICAgICAgICAgY29uc3QgdCA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2Rpdicp
OwogICAgICAgICAgICAgICAgdC5jbGFzc05hbWUgPSAnbWctdGl0bGUnOwogICAgICAgICAgICAgICAg
c2V0SGxUZXh0KHQsIHRpdGxlKTsKICAgICAgICAgICAgICAgIG1haW4uYXBwZW5kQ2hpbGQodCk7CiAg
ICAgICAgICAgIH0KICAgICAgICAgICAgY29uc3QgYm9keSA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQo
J2RpdicpOwogICAgICAgICAgICBib2R5LmNsYXNzTmFtZSA9ICdtZy1ib2R5JyArIChub3JtVHlwZShj
LnR5cGUpID09PSAnaW1hZ2UnID8gJyBpbWcnIDogJycpOwogICAgICAgICAgICBzZXRIbFRleHQoYm9k
eSwgY2xpcENvbnRlbnRQcmV2aWV3KGMpKTsKICAgICAgICAgICAgbWFpbi5hcHBlbmRDaGlsZChib2R5
KTsKICAgICAgICAgICAgdG9wLmFwcGVuZENoaWxkKG1haW4pOwoKICAgICAgICAgICAgY29uc3Qgc3Jj
SWNvID0gU3RyaW5nKGMuc3JjSWNvbiB8fCAnJyk7CiAgICAgICAgICAgIGNvbnN0IHNyY0V4ZSA9IFN0
cmluZyhjLnNyY0V4ZSB8fCAnJyk7CiAgICAgICAgICAgIGNvbnN0IHNyY1RpdGxlID0gU3RyaW5nKGMu
c3JjVGl0bGUgfHwgJycpOwogICAgICAgICAgICBpZiAoc3JjSWNvKSB7CiAgICAgICAgICAgICAgICBj
b25zdCBpbWcgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdpbWcnKTsKICAgICAgICAgICAgICAgIGlt
Zy5jbGFzc05hbWUgPSAnbWctc3JjJzsKICAgICAgICAgICAgICAgIGltZy5zcmMgPSBTVE9SRV9CQVNF
ICsgZW5jb2RlVVJJQ29tcG9uZW50KHNyY0ljbyk7CiAgICAgICAgICAgICAgICBpbWcuYWx0ID0gJyc7
CiAgICAgICAgICAgICAgICBjb25zdCB0aXBUeHQgPSBzcmNUaXRsZSB8fCBzcmNFeGUgfHwgJ+adpea6
kCc7CiAgICAgICAgICAgICAgICBpbWcudGl0bGUgPSB0aXBUeHQ7CiAgICAgICAgICAgICAgICBpbWcu
b25jbGljayA9IGUgPT4geyBlLnByZXZlbnREZWZhdWx0KCk7IGUuc3RvcFByb3BhZ2F0aW9uKCk7IHNo
b3dTcmNUaXAoaW1nLCB0aXBUeHQpOyB9OwogICAgICAgICAgICAgICAgdG9wLmFwcGVuZENoaWxkKGlt
Zyk7CiAgICAgICAgICAgIH0KICAgICAgICAgICAgcm93LmFwcGVuZENoaWxkKHRvcCk7CgogICAgICAg
ICAgICByb3cub25wb2ludGVyZG93biA9IGUgPT4gewogICAgICAgICAgICAgICAgaWYgKGUuYnV0dG9u
ICE9PSAwKSByZXR1cm47CiAgICAgICAgICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgICAg
ICAgICAgICAgYmVnaW5QYXN0ZUZyb21JdGVtKGUsIGMpOwogICAgICAgICAgICB9OwogICAgICAgICAg
ICByb3cub25jb250ZXh0bWVudSA9IGUgPT4gewogICAgICAgICAgICAgICAgZS5wcmV2ZW50RGVmYXVs
dCgpOwogICAgICAgICAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICAgICAgICAgIHNl
bGVjdGVkSWQgPSBjLmlkOwogICAgICAgICAgICAgICAgc2hvd0N0eChlLmNsaWVudFgsIGUuY2xpZW50
WSwgYyk7CiAgICAgICAgICAgIH07CiAgICAgICAgICAgIGVsLmFwcGVuZENoaWxkKHJvdyk7CiAgICAg
ICAgfSk7CgogICAgICAgIGVsLm9uY29udGV4dG1lbnUgPSBlID0+IHsKICAgICAgICAgICAgaWYgKGUu
dGFyZ2V0LmNsb3Nlc3QoJy5tZy1yb3cnKSkgcmV0dXJuOwogICAgICAgICAgICBlLnByZXZlbnREZWZh
dWx0KCk7CiAgICAgICAgICAgIHNlbGVjdGVkSWQgPSBpdGVtc1swXS5pZDsKICAgICAgICAgICAgc2hv
d0N0eChlLmNsaWVudFgsIGUuY2xpZW50WSwgaXRlbXNbMF0pOwogICAgICAgIH07CiAgICAgICAgcmV0
dXJuIGVsOwogICAgfQoKCiAgICBmdW5jdGlvbiBidWlsZFJlY2VudFBhdGhDcnVtYnMoY29udGFpbmVy
LCBmdWxsUGF0aCkgewogICAgICAgIGlmICghY29udGFpbmVyKSByZXR1cm47CiAgICAgICAgY29udGFp
bmVyLnF1ZXJ5U2VsZWN0b3JBbGwoJy5yZi1zZWcsIC5yZi1zZXAnKS5mb3JFYWNoKG4gPT4gbi5yZW1v
dmUoKSk7CiAgICAgICAgY29uc3QgcmF3ID0gU3RyaW5nKGZ1bGxQYXRoIHx8ICcnKS5yZXBsYWNlKC9c
Ly9nLCAnXFwnKS5yZXBsYWNlKC9cXCskLywgJycpOwogICAgICAgIGlmICghcmF3KSByZXR1cm47CiAg
ICAgICAgY29uc3QgdW5jID0gcmF3LnN0YXJ0c1dpdGgoJ1xcXFwnKTsKICAgICAgICBsZXQgcmVzdCA9
IHVuYyA/IHJhdy5zbGljZSgyKSA6IHJhdzsKICAgICAgICBjb25zdCBwYXJ0cyA9IHJlc3Quc3BsaXQo
J1xcJykuZmlsdGVyKEJvb2xlYW4pOwogICAgICAgIGNvbnN0IGFkZFNlZyA9IChsYWJlbCwgb3BlblBh
dGgpID0+IHsKICAgICAgICAgICAgaWYgKGNvbnRhaW5lci5xdWVyeVNlbGVjdG9yKCcucmYtc2VnLCAu
cmYtc2VwJykpIHsKICAgICAgICAgICAgICAgIGNvbnN0IHNlcCA9IGRvY3VtZW50LmNyZWF0ZUVsZW1l
bnQoJ3NwYW4nKTsKICAgICAgICAgICAgICAgIHNlcC5jbGFzc05hbWUgPSAncmYtc2VwJzsKICAgICAg
ICAgICAgICAgIHNlcC50ZXh0Q29udGVudCA9ICdcXCc7CiAgICAgICAgICAgICAgICBjb250YWluZXIu
YXBwZW5kQ2hpbGQoc2VwKTsKICAgICAgICAgICAgfQogICAgICAgICAgICAvLyBidXR0b27vvJrlkb3k
uK3mm7TnqLPvvIzkuI3ooqsgYXBwLXJlZ2lvbiAvIOeItue6pyBwb2ludGVyIOWQg+aOiQogICAgICAg
ICAgICBjb25zdCBzZWcgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdidXR0b24nKTsKICAgICAgICAg
ICAgc2VnLnR5cGUgPSAnYnV0dG9uJzsKICAgICAgICAgICAgc2VnLmNsYXNzTmFtZSA9ICdyZi1zZWcn
OwogICAgICAgICAgICBzZXRIbFRleHQoc2VnLCBsYWJlbCk7CiAgICAgICAgICAgIHNlZy50aXRsZSA9
ICfmiZPlvIA6ICcgKyBvcGVuUGF0aDsKICAgICAgICAgICAgc2VnLnNldEF0dHJpYnV0ZSgnZGF0YS1w
YXRoJywgb3BlblBhdGgucmVwbGFjZSgvXFwvZywgJy8nKSk7CiAgICAgICAgICAgIHNlZy5fb3BlblBh
dGggPSBvcGVuUGF0aDsKICAgICAgICAgICAgc2VnLmFkZEV2ZW50TGlzdGVuZXIoJ2NsaWNrJywgZSA9
PiB7CiAgICAgICAgICAgICAgICBlLnByZXZlbnREZWZhdWx0KCk7CiAgICAgICAgICAgICAgICBlLnN0
b3BQcm9wYWdhdGlvbigpOwogICAgICAgICAgICAgICAgb3BlblJlY2VudERpcihvcGVuUGF0aCk7CiAg
ICAgICAgICAgIH0sIHRydWUpOwogICAgICAgICAgICBzZWcuYWRkRXZlbnRMaXN0ZW5lcigncG9pbnRl
cmRvd24nLCBlID0+IHsKICAgICAgICAgICAgICAgIGlmIChlLmJ1dHRvbiAhPT0gMCkgcmV0dXJuOwog
ICAgICAgICAgICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOwogICAgICAgICAgICAgICAgZS5zdG9wUHJv
cGFnYXRpb24oKTsKICAgICAgICAgICAgICAgIG9wZW5SZWNlbnREaXIob3BlblBhdGgpOwogICAgICAg
ICAgICB9LCB0cnVlKTsKICAgICAgICAgICAgY29udGFpbmVyLmFwcGVuZENoaWxkKHNlZyk7CiAgICAg
ICAgfTsKICAgICAgICBpZiAoIXBhcnRzLmxlbmd0aCkgewogICAgICAgICAgICBhZGRTZWcocmF3LCBy
YXcpOwogICAgICAgICAgICByZXR1cm47CiAgICAgICAgfQogICAgICAgIGxldCBhY2MgPSB1bmMgPyAn
XFxcXCcgKyBwYXJ0c1swXSA6IHBhcnRzWzBdOwogICAgICAgIGlmICghdW5jICYmIC9eW2EtekEtWl06
JC8udGVzdChwYXJ0c1swXSkpCiAgICAgICAgICAgIGFjYyA9IHBhcnRzWzBdICsgJ1xcJzsKICAgICAg
ICBhZGRTZWcocGFydHNbMF0sIGFjYyk7CiAgICAgICAgZm9yIChsZXQgaSA9IDE7IGkgPCBwYXJ0cy5s
ZW5ndGg7IGkrKykgewogICAgICAgICAgICBhY2MgPSBhY2MucmVwbGFjZSgvXFwrJC8sICcnKSArICdc
XCcgKyBwYXJ0c1tpXTsKICAgICAgICAgICAgYWRkU2VnKHBhcnRzW2ldLCBhY2MpOwogICAgICAgIH0K
ICAgIH0KCiAgICBmdW5jdGlvbiBhY3RpdmF0ZUNsaXBJdGVtKGMpIHsKICAgICAgICBpZiAoIWMpIHJl
dHVybjsKICAgICAgICBpZiAobm9ybVR5cGUoYy50eXBlKSA9PT0gJ3JlY2VudCcpIHsKICAgICAgICAg
ICAgX19wcmVwUGFzdGUoKTsKICAgICAgICAgICAgc2VsZWN0ZWRJZCA9IGMuaWQ7CiAgICAgICAgICAg
IGlmIChtdWx0aUlkcy5sZW5ndGgpIGNsZWFyTXVsdGkoKTsKICAgICAgICAgICAgc3luY0l0ZW1IaWdo
bGlnaHQoKTsKICAgICAgICAgICAgYWhrKCdwYXN0ZScsIFN0cmluZyhjLmlkKSk7CiAgICAgICAgICAg
IHJldHVybjsKICAgICAgICB9CiAgICAgICAgcGFzdGVPbmUoYyk7CiAgICB9CiAgICBmdW5jdGlvbiBt
YWtlSXRlbShjLCBpZHgpIHsKICAgICAgICBjb25zdCB0eXBlICAgPSBub3JtVHlwZShjLnR5cGUpOwog
ICAgICAgIGNvbnN0IHBpbm5lZCA9IGlzUGlubmVkKGMpOwogICAgICAgIGNvbnN0IHBhc3RlZCA9IGlz
UGFzdGVkKGMpOwogICAgICAgIGNvbnN0IGVsICAgICA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2Rp
dicpOwogICAgICAgIGVsLmNsYXNzTmFtZSAgPSAnaXRtJwogICAgICAgICAgICArIChzZWxlY3RlZElk
ID09IGMuaWQgPyAnIHNlbCcgOiAnJykKICAgICAgICAgICAgKyAobXVsdGlJZHMuaW5jbHVkZXMoK2Mu
aWQpID8gJyBtdWx0aScgOiAnJyk7CiAgICAgICAgZWwuZGF0YXNldC5pZCA9IGMuaWQ7CiAgICAgICAg
Y29uc3QgcWcgPSBOdW1iZXIoYy5xdWV1ZUdyb3VwKSB8fCAwOwogICAgICAgIGlmIChxZyA+IDApIHsK
ICAgICAgICAgICAgZWwuY2xhc3NMaXN0LmFkZCgncS1tZW1iZXInKTsKICAgICAgICAgICAgZWwuZGF0
YXNldC5xZyA9IFN0cmluZyhxZyk7CiAgICAgICAgICAgIGVsLmRhdGFzZXQucWkgPSBTdHJpbmcoTnVt
YmVyKGMucXVldWVJbmRleCkgfHwgMCk7CiAgICAgICAgICAgIGlmIChwYXN0ZWQpIGVsLmNsYXNzTGlz
dC5hZGQoJ3EtZG9uZScpOwogICAgICAgICAgICBjb25zdCByYWlsID0gZG9jdW1lbnQuY3JlYXRlRWxl
bWVudCgnc3BhbicpOwogICAgICAgICAgICByYWlsLmNsYXNzTmFtZSA9ICdxLXJhaWwnOwogICAgICAg
ICAgICBjb25zdCBkb3QgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdzcGFuJyk7CiAgICAgICAgICAg
IGRvdC5jbGFzc05hbWUgPSAncS1kb3QnOwogICAgICAgICAgICBkb3QudGl0bGUgPSBwYXN0ZWQgPyAn
6Zif5YiX5bey57KY6LS0JyA6ICfnspjotLTpmJ/liJcnOwogICAgICAgICAgICBlbC5hcHBlbmRDaGls
ZChyYWlsKTsKICAgICAgICAgICAgZWwuYXBwZW5kQ2hpbGQoZG90KTsKICAgICAgICB9CgogICAgICAg
IGNvbnN0IGljbyAgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsKICAgICAgICBjb25zdCBi
b2R5ID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnZGl2Jyk7CiAgICAgICAgYm9keS5jbGFzc05hbWUg
PSAnaS1ib2R5JzsKCiAgICAgICAgaWYgKHR5cGUgPT09ICdpbWFnZScpIHsKICAgICAgICAgICAgaWNv
LmNsYXNzTmFtZSA9ICdpLWljbyBpbWFnZSc7CiAgICAgICAgICAgIGljby5pbm5lckhUTUwgPSBTVkcu
aW1hZ2U7CiAgICAgICAgICAgIGJpbmRJbWdIb3ZlclByZXZpZXcoaWNvLCBjLmlkLCBjLmltZ0ZpbGUp
OwogICAgICAgICAgICBjb25zdCB3cmFwID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnZGl2Jyk7CiAg
ICAgICAgICAgIHdyYXAuY2xhc3NOYW1lID0gJ2ktdGh1bWItd3JhcCc7CiAgICAgICAgICAgIGNvbnN0
IGltZyAgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdpbWcnKTsKICAgICAgICAgICAgaW1nLmNsYXNz
TmFtZSA9ICdpLXRodW1iJzsKICAgICAgICAgICAgaW1nLmFsdCA9ICcnOwogICAgICAgICAgICBjb25z
dCBmaWxlID0gU3RyaW5nKGMuaW1nRmlsZSB8fCAnJyk7CiAgICAgICAgICAgIGxldCBmYWxsYmFjayA9
IFN0cmluZyhjLmRhdGEgfHwgJycpOwogICAgICAgICAgICAvLyBOZXZlciBzeW5jLWNhbGwgQUhLIHRo
dW1iIGhlcmUg4oCUIGZyZWV6ZXMgdGFiIHN3aXRjaGVzOyBQdXNoU3RvcmVUaHVtYnMgZmlsbHMgYXN5
bmMKICAgICAgICAgICAgaWYgKCFmYWxsYmFjay5zdGFydHNXaXRoKCdkYXRhOicpICYmIHRodW1iQ2Fj
aGUuaGFzKFN0cmluZyhjLmlkKSkpCiAgICAgICAgICAgICAgICBmYWxsYmFjayA9IFN0cmluZyh0aHVt
YkNhY2hlLmdldChTdHJpbmcoYy5pZCkpKTsKICAgICAgICAgICAgaW1nLm9ubG9hZCA9ICgpID0+IHsK
ICAgICAgICAgICAgICAgIGNvbnN0IG13ID0gd3JhcC5jbGllbnRXaWR0aCB8fCAzMDA7CiAgICAgICAg
ICAgICAgICBjb25zdCBudyA9IGltZy5uYXR1cmFsV2lkdGggIHx8IDA7CiAgICAgICAgICAgICAgICBj
b25zdCBuaCA9IGltZy5uYXR1cmFsSGVpZ2h0IHx8IDA7CiAgICAgICAgICAgICAgICBpZiAoIW53IHx8
ICFuaCkgcmV0dXJuOwogICAgICAgICAgICAgICAgY29uc3Qgc2NhbGUgPSBNYXRoLm1pbigxLCAxODAg
LyBuaCwgbXcgLyBudyk7CiAgICAgICAgICAgICAgICBpbWcuc3R5bGUud2lkdGggID0gTWF0aC5yb3Vu
ZChudyAqIHNjYWxlKSArICdweCc7CiAgICAgICAgICAgICAgICBpbWcuc3R5bGUuaGVpZ2h0ID0gTWF0
aC5yb3VuZChuaCAqIHNjYWxlKSArICdweCc7CiAgICAgICAgICAgIH07CiAgICAgICAgICAgIGJpbmRT
dG9yZVRodW1iKGltZywgZmlsZSwgYy5pZCwgZmFsbGJhY2spOwogICAgICAgICAgICB3cmFwLmFwcGVu
ZENoaWxkKGltZyk7CiAgICAgICAgICAgIGNvbnN0IG1ldGEgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50
KCdkaXYnKTsKICAgICAgICAgICAgbWV0YS5jbGFzc05hbWUgPSAnaS1tZXRhJzsKICAgICAgICAgICAg
bWV0YS5pbm5lckhUTUwgID0gYDxzcGFuIGNsYXNzPSJpLXRpbWUiPiR7YWdvKGMudGltZSl9PC9zcGFu
PiR7bWV0YUNlbnRlckh0bWwoZmFsc2UpfTxkaXYgY2xhc3M9ImktbWV0YS1yaWdodCI+JHtjLndpZHRo
ID8gYDxzcGFuIGNsYXNzPSJpLXRhZyI+JHtjLndpZHRofcOXJHtjLmhlaWdodH0gcHg8L3NwYW4+YCA6
ICcnfTwvZGl2PmA7CiAgICAgICAgICAgIGJvZHkuYXBwZW5kQ2hpbGQod3JhcCk7CiAgICAgICAgICAg
IGJvZHkuYXBwZW5kQ2hpbGQobWV0YSk7CiAgICAgICAgfSBlbHNlIGlmICh0eXBlID09PSAncmVjZW50
JykgewogICAgICAgICAgICBpY28uY2xhc3NOYW1lID0gJ2ktaWNvIGZpbGUgZnQtZGlyJzsKICAgICAg
ICAgICAgaWNvLmlubmVySFRNTCA9IFNWRy5mb2xkZXI7CiAgICAgICAgICAgIGlmIChwaW5uZWQpIGVs
LmNsYXNzTGlzdC5hZGQoJ3JmLWZpeGVkJyk7CiAgICAgICAgICAgIGNvbnN0IHBhdGggPSBTdHJpbmco
Yy5kYXRhIHx8IGMucHJldmlldyB8fCAnJyk7CiAgICAgICAgICAgIGNvbnN0IGNydW1icyA9IGRvY3Vt
ZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOwogICAgICAgICAgICBjcnVtYnMuY2xhc3NOYW1lID0gJ3Jm
LXBhdGgnOwogICAgICAgICAgICBidWlsZFJlY2VudFBhdGhDcnVtYnMoY3J1bWJzLCBwYXRoKTsKICAg
ICAgICAgICAgLy8g5Zu65a6a5qCH6K6w5Y+q5pS+IG1ldGEg5Y+z5L6n77yM5LiN5oyh6Lev5b6ECiAg
ICAgICAgICAgIGNvbnN0IG1ldGEgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsKICAgICAg
ICAgICAgbWV0YS5jbGFzc05hbWUgPSAnaS1tZXRhJzsKICAgICAgICAgICAgbWV0YS5pbm5lckhUTUwg
PQogICAgICAgICAgICAgICAgYDxzcGFuIGNsYXNzPSJpLXRpbWUiPiR7YWdvKGMudGltZSl9PC9zcGFu
PmAgKwogICAgICAgICAgICAgICAgbWV0YUNlbnRlckh0bWwoZmFsc2UpICsKICAgICAgICAgICAgICAg
IGA8ZGl2IGNsYXNzPSJpLW1ldGEtcmlnaHQiPiR7cGlubmVkID8gJzxzcGFuIGNsYXNzPSJyZi1waW4t
dGFnIiB0aXRsZT0i5bey5Zu65a6a77yM5LiN5Lya6KKr5reY5rGwIj7lm7rlrpo8L3NwYW4+JyA6ICcn
fTwvZGl2PmA7CiAgICAgICAgICAgIGJvZHkuYXBwZW5kQ2hpbGQoY3J1bWJzKTsKICAgICAgICAgICAg
Ym9keS5hcHBlbmRDaGlsZChtZXRhKTsKICAgICAgICB9IGVsc2UgaWYgKHR5cGUgPT09ICdmaWxlJykg
ewogICAgICAgICAgICBjb25zdCBmaWxlcyA9IFN0cmluZyhjLnByZXZpZXcgfHwgYy5kYXRhIHx8ICcn
KS5zcGxpdCgvXHI/XG4vKS5maWx0ZXIoQm9vbGVhbik7CiAgICAgICAgICAgIGNvbnN0IGltYWdlUGF0
aHMgPSBmaWxlcy5maWx0ZXIoZiA9PiBpc0ltYWdlRXh0KGZpbGVFeHQoZikpKTsKICAgICAgICAgICAg
Y29uc3QgaWMgICAgPSBpY29uRm9yRmlsZXMoZmlsZXMpOwogICAgICAgICAgICBpY28uY2xhc3NOYW1l
ID0gJ2ktaWNvICcgKyBpYy5jbHM7CiAgICAgICAgICAgIGljby5pbm5lckhUTUwgPSBpYy5zdmc7Cgog
ICAgICAgICAgICBsZXQgdGh1bWJGaWxlID0gU3RyaW5nKGMuaW1nRmlsZSB8fCAnJyk7CiAgICAgICAg
ICAgIC8qIGVuc3VyZUZpbGVJbWcgZGVmZXJyZWQ6IGF2b2lkIHN5bmMgZnJlZXplIG9uIGZpbGUgdGFi
ICovCgogICAgICAgICAgICAvLyBJbWFnZS1mb3JtYXQgZmlsZXM6IHNhbWUgdGh1bWJuYWlsIHJ1bGVz
IGFzIHNjcmVlbnNob3QgY2xpcHMKICAgICAgICAgICAgaWYgKHRodW1iRmlsZSB8fCBpbWFnZVBhdGhz
Lmxlbmd0aCkgewogICAgICAgICAgICAgICAgY29uc3Qgd3JhcCA9IGRvY3VtZW50LmNyZWF0ZUVsZW1l
bnQoJ2RpdicpOwogICAgICAgICAgICAgICAgd3JhcC5jbGFzc05hbWUgPSAnaS10aHVtYi13cmFwJzsK
ICAgICAgICAgICAgICAgIGNvbnN0IGltZyAgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdpbWcnKTsK
ICAgICAgICAgICAgICAgIGltZy5jbGFzc05hbWUgPSAnaS10aHVtYic7CiAgICAgICAgICAgICAgICBp
bWcuYWx0ID0gJyc7CiAgICAgICAgICAgICAgICBpbWcub25sb2FkID0gKCkgPT4gewogICAgICAgICAg
ICAgICAgICAgIGNvbnN0IG13ID0gd3JhcC5jbGllbnRXaWR0aCB8fCAzMDA7CiAgICAgICAgICAgICAg
ICAgICAgY29uc3QgbncgPSBpbWcubmF0dXJhbFdpZHRoICB8fCAwOwogICAgICAgICAgICAgICAgICAg
IGNvbnN0IG5oID0gaW1nLm5hdHVyYWxIZWlnaHQgfHwgMDsKICAgICAgICAgICAgICAgICAgICBpZiAo
IW53IHx8ICFuaCkgcmV0dXJuOwogICAgICAgICAgICAgICAgICAgIGNvbnN0IHNjYWxlID0gTWF0aC5t
aW4oMSwgMTgwIC8gbmgsIG13IC8gbncpOwogICAgICAgICAgICAgICAgICAgIGltZy5zdHlsZS53aWR0
aCAgPSBNYXRoLnJvdW5kKG53ICogc2NhbGUpICsgJ3B4JzsKICAgICAgICAgICAgICAgICAgICBpbWcu
c3R5bGUuaGVpZ2h0ID0gTWF0aC5yb3VuZChuaCAqIHNjYWxlKSArICdweCc7CiAgICAgICAgICAgICAg
ICB9OwogICAgICAgICAgICAvKiBlbnN1cmVGaWxlSW1nIGRlZmVycmVkOiBhdm9pZCBzeW5jIGZyZWV6
ZSBvbiBmaWxlIHRhYiAqLwogICAgICAgICAgICAgICAgYmluZFN0b3JlVGh1bWIoaW1nLCB0aHVtYkZp
bGUsIGMuaWQsICcnKTsKICAgICAgICAgICAgICAgIHdyYXAuYXBwZW5kQ2hpbGQoaW1nKTsKICAgICAg
ICAgICAgICAgIGJvZHkuYXBwZW5kQ2hpbGQod3JhcCk7CiAgICAgICAgICAgIH0KCiAgICAgICAgICAg
IGNvbnN0IG5hbWUgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsKICAgICAgICAgICAgbmFt
ZS5jbGFzc05hbWUgID0gJ2ktbmFtZSc7CiAgICAgICAgICAgIHNldEhsVGV4dChuYW1lLCBmaWxlcy5t
YXAoZiA9PiBmLnNwbGl0KC9bXFwvXS8pLnBvcCgpKS5qb2luKCdcbicpIHx8ICco5paH5Lu2KScpOwoK
ICAgICAgICAgICAgZWwuX2ZpbGVQYXRocyA9IGZpbGVzOwoKICAgICAgICAgICAgY29uc3QgZGV0YWls
ID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnZGl2Jyk7CiAgICAgICAgICAgIGRldGFpbC5jbGFzc05h
bWUgPSAnaS1maWxlLWRldGFpbCc7CgogICAgICAgICAgICBjb25zdCBtZXRhID0gZG9jdW1lbnQuY3Jl
YXRlRWxlbWVudCgnZGl2Jyk7CiAgICAgICAgICAgIG1ldGEuY2xhc3NOYW1lID0gJ2ktbWV0YSc7CiAg
ICAgICAgICAgIGxldCByaWdodCA9ICcnOwogICAgICAgICAgICByaWdodCArPSBgPHNwYW4gY2xhc3M9
ImktdGFnIj4ke2MuZmlsZUNvdW50IHx8IGZpbGVzLmxlbmd0aCB8fCAxfSDkuKrmlofku7Y8L3NwYW4+
YDsKICAgICAgICAgICAgaWYgKCh0aHVtYkZpbGUgfHwgaW1hZ2VQYXRocy5sZW5ndGgpICYmIGMud2lk
dGgpCiAgICAgICAgICAgICAgICByaWdodCArPSBgPHNwYW4gY2xhc3M9ImktdGFnIj4ke2Mud2lkdGh9
w5cke2MuaGVpZ2h0fSBweDwvc3Bhbj5gOwogICAgICAgICAgICBjb25zdCBleHBhbmRIdG1sID0gZXhw
YW5kQ2hldnJvbihmYWxzZSk7CiAgICAgICAgICAgIGNvbnN0IGNvbGxhcHNlSHRtbCA9IGV4cGFuZENo
ZXZyb24odHJ1ZSk7CiAgICAgICAgICAgIG1ldGEuaW5uZXJIVE1MID0KICAgICAgICAgICAgICAgIGA8
c3BhbiBjbGFzcz0iaS10aW1lIj4ke2FnbyhjLnRpbWUpfTwvc3Bhbj5gICsKICAgICAgICAgICAgICAg
IG1ldGFDZW50ZXJIdG1sKHsgb246IHRydWUsIGh0bWw6IGV4cGFuZEh0bWwgfSkgKwogICAgICAgICAg
ICAgICAgYDxkaXYgY2xhc3M9ImktbWV0YS1yaWdodCI+JHtyaWdodH08L2Rpdj5gOwoKICAgICAgICAg
ICAgY29uc3QgZXhwQnRuID0gbWV0YS5xdWVyeVNlbGVjdG9yKCcuaS1leHBhbmQtYnRuJyk7CiAgICAg
ICAgICAgIGxldCBkZXRhaWxCdWlsdCA9IGZhbHNlOwogICAgICAgICAgICBleHBCdG4ub25jbGljayA9
IGUgPT4gewogICAgICAgICAgICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOwogICAgICAgICAgICAgICAg
ZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICAgICAgICAgIGNvbnN0IG9wZW4gPSAhZGV0YWlsLmNs
YXNzTGlzdC5jb250YWlucygnb24nKTsKICAgICAgICAgICAgICAgIGlmIChvcGVuICYmICFkZXRhaWxC
dWlsdCkgewogICAgICAgICAgICAgICAgICAgIGNvbnN0IHBhdGhSb3dzID0gZWwuX3BhdGhSb3dzIHx8
IGNoZWNrRmlsZVBhdGhzKGVsLl9maWxlUGF0aHMgfHwgZmlsZXMpOwogICAgICAgICAgICAgICAgICAg
IGZpbGxGaWxlRGV0YWlsUGFuZWwoZGV0YWlsLCBwYXRoUm93cyk7CiAgICAgICAgICAgICAgICAgICAg
ZGV0YWlsQnVpbHQgPSB0cnVlOwogICAgICAgICAgICAgICAgfQogICAgICAgICAgICAgICAgZGV0YWls
LmNsYXNzTGlzdC50b2dnbGUoJ29uJywgb3Blbik7CiAgICAgICAgICAgICAgICBpZiAob3Blbikgewog
ICAgICAgICAgICAgICAgICAgIGRldGFpbC5zdHlsZS5tYXhIZWlnaHQgPSBsaXN0RXhwYW5kTWF4UHgo
KSArICdweCc7CiAgICAgICAgICAgICAgICAgICAgZGV0YWlsLnN0eWxlLm92ZXJmbG93ID0gJ2F1dG8n
OwogICAgICAgICAgICAgICAgfSBlbHNlIHsKICAgICAgICAgICAgICAgICAgICBkZXRhaWwuc3R5bGUu
bWF4SGVpZ2h0ID0gJyc7CiAgICAgICAgICAgICAgICAgICAgZGV0YWlsLnN0eWxlLm92ZXJmbG93ID0g
Jyc7CiAgICAgICAgICAgICAgICB9CiAgICAgICAgICAgICAgICBleHBCdG4uaW5uZXJIVE1MID0gb3Bl
biA/IGNvbGxhcHNlSHRtbCA6IGV4cGFuZEh0bWw7CiAgICAgICAgICAgIH07CgogICAgICAgICAgICBi
b2R5LmFwcGVuZENoaWxkKG5hbWUpOwogICAgICAgICAgICBib2R5LmFwcGVuZENoaWxkKGRldGFpbCk7
CiAgICAgICAgICAgIGJvZHkuYXBwZW5kQ2hpbGQobWV0YSk7CiAgICAgICAgfSBlbHNlIHsKICAgICAg
ICAgICAgY29uc3QgdXNlTSA9IGNsaXBVc2VzTUljb24oYyk7CiAgICAgICAgICAgIGljby5jbGFzc05h
bWUgPSB1c2VNID8gJ2ktaWNvIG1kJyA6ICdpLWljbyB0ZXh0JzsKICAgICAgICAgICAgaWNvLmlubmVy
SFRNTCA9IHVzZU0gPyAoU1ZHLm1kIHx8IFNWRy50ZXh0KSA6IFNWRy50ZXh0OwogICAgICAgICAgICAv
KiBwbGFpbi1saXN0LXByZXYgKi8KICAgICAgICAgICAgLyogcHJldmlldy1lbGxpcHNpcyAqLwogICAg
ICAgICAgICBsZXQgdHh0ICA9IGMucHJldmlldyB8fCBjLmRhdGEgfHwgJyc7CiAgICAgICAgICAgIHsg
Y29uc3QgX24gPSBOdW1iZXIoYy5jaGFyQ291bnQpIHx8IDA7IGlmIChfbiA+IHR4dC5sZW5ndGggJiYg
dHh0Lmxlbmd0aCkgdHh0ICs9ICcuLi4nOyB9CiAgICAgICAgICAgIGNvbnN0IHByZXYgPSBkb2N1bWVu
dC5jcmVhdGVFbGVtZW50KCdkaXYnKTsKICAgICAgICAgICAgcHJldi5jbGFzc05hbWUgID0gJ2ktcHJl
dicgKyAoaXNVcmwodHh0KSA/ICcgdXJsJyA6ICcnKTsKICAgICAgICAgICAgc2V0SGxUZXh0KHByZXYs
IHR4dCk7CgogICAgICAgICAgICBjb25zdCBtZXRhID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnZGl2
Jyk7CiAgICAgICAgICAgIG1ldGEuY2xhc3NOYW1lID0gJ2ktbWV0YSc7CgogICAgICAgICAgICBjb25z
dCBjaGFycyA9IE51bWJlcihjLmNoYXJDb3VudCkgfHwgMDsKICAgICAgICAgICAgY29uc3QgcmlnaHRI
VE1MID0gYDxzcGFuIGNsYXNzPSJpLWNoYXJzIj48c3BhbiBjbGFzcz0ibiI+JHtjaGFyc308L3NwYW4+
IOWtl+espjwvc3Bhbj5gOwoKICAgICAgICAgICAgbWV0YS5pbm5lckhUTUwgPQogICAgICAgICAgICAg
ICAgYDxzcGFuIGNsYXNzPSJpLXRpbWUiPiR7YWdvKGMudGltZSl9PC9zcGFuPmAgKwogICAgICAgICAg
ICAgICAgbWV0YUNlbnRlckh0bWwoewogICAgICAgICAgICAgICAgICAgIG9uOiBmYWxzZSwKICAgICAg
ICAgICAgICAgICAgICBodG1sOiBleHBhbmRDaGV2cm9uKGZhbHNlKQogICAgICAgICAgICAgICAgfSkg
KwogICAgICAgICAgICAgICAgYDxkaXYgY2xhc3M9ImktbWV0YS1yaWdodCB0ZXh0LW1ldGEiPiR7cmln
aHRIVE1MfTwvZGl2PmA7CgogICAgICAgICAgICBib2R5LmFwcGVuZENoaWxkKHByZXYpOwogICAgICAg
ICAgICBib2R5LmFwcGVuZENoaWxkKG1ldGEpOwoKICAgICAgICAgICAgY29uc3QgZXhwQnRuID0gbWV0
YS5xdWVyeVNlbGVjdG9yKCcuaS1leHBhbmQtYnRuJyk7CiAgICAgICAgICAgIGlmIChleHBCdG4pIHsK
ICAgICAgICAgICAgICAgIGV4cEJ0bi5vbmNsaWNrID0gZSA9PiB7CiAgICAgICAgICAgICAgICAgICAg
ZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICAgICAgICAgICAgICBjb25zdCB3aWxsRXhwYW5kID0g
IXByZXYuY2xhc3NMaXN0LmNvbnRhaW5zKCdleHBhbmRlZCcpOwogICAgICAgICAgICAgICAgICAgIGlm
ICh3aWxsRXhwYW5kKSB7CiAgICAgICAgICAgICAgICAgICAgICAgIGFwcGx5RXhwYW5kZWRQcmV2aWV3
KHByZXYsIHR4dCk7CiAgICAgICAgICAgICAgICAgICAgICAgIGV4cEJ0bi5pbm5lckhUTUwgPSBleHBh
bmRDaGV2cm9uKHRydWUpOwogICAgICAgICAgICAgICAgICAgICAgICB0cnkgeyBlbC5zY3JvbGxJbnRv
Vmlldyh7IGJsb2NrOiAnbmVhcmVzdCcgfSk7IH0gY2F0Y2gge30KICAgICAgICAgICAgICAgICAgICB9
IGVsc2UgewogICAgICAgICAgICAgICAgICAgICAgICBjb2xsYXBzZVByZXZpZXcocHJldiwgdHh0KTsK
ICAgICAgICAgICAgICAgICAgICAgICAgZXhwQnRuLmlubmVySFRNTCA9IGV4cGFuZENoZXZyb24oZmFs
c2UpOwogICAgICAgICAgICAgICAgICAgIH0KICAgICAgICAgICAgICAgIH07CiAgICAgICAgICAgICAg
ICBjb25zdCBjaGVja092ZXJmbG93ID0gKCkgPT4gewogICAgICAgICAgICAgICAgICAgIGNvbnN0IHBs
YWluTGVuID0gU3RyaW5nKGMucHJldmlldyB8fCBjLmRhdGEgfHwgJycpLmxlbmd0aDsKICAgICAgICAg
ICAgICAgICAgICBjb25zdCBmdWxsTiA9IE51bWJlcihjLmNoYXJDb3VudCkgfHwgMDsKICAgICAgICAg
ICAgICAgICAgICBjb25zdCB0cnVuYyA9IGZ1bGxOID4gcGxhaW5MZW47CiAgICAgICAgICAgICAgICAg
ICAgaWYgKHByZXYuc2Nyb2xsSGVpZ2h0ID4gcHJldi5jbGllbnRIZWlnaHQgKyAyIHx8IHRydW5jKQog
ICAgICAgICAgICAgICAgICAgICAgICBleHBCdG4uY2xhc3NMaXN0LmFkZCgnb24nKTsKICAgICAgICAg
ICAgICAgICAgICBlbHNlCiAgICAgICAgICAgICAgICAgICAgICAgIGV4cEJ0bi5jbGFzc0xpc3QucmVt
b3ZlKCdvbicpOwogICAgICAgICAgICAgICAgfTsKICAgICAgICAgICAgICAgIHJlcXVlc3RBbmltYXRp
b25GcmFtZShjaGVja092ZXJmbG93KTsKICAgICAgICAgICAgICAgIHNldFRpbWVvdXQoY2hlY2tPdmVy
ZmxvdywgODApOwogICAgICAgICAgICB9CiAgICAgICAgfQoKICAgICAgICBjb25zdCBmYXZUID0gU3Ry
aW5nKGMuZmF2VGl0bGUgfHwgJycpLnRyaW0oKTsKICAgICAgICBpZiAoZmF2VCkgewogICAgICAgICAg
ICBjb25zdCBmdCA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOwogICAgICAgICAgICBmdC5j
bGFzc05hbWUgPSAnaS1mYXYtdGl0bGUnOwogICAgICAgICAgICBzZXRIbFRleHQoZnQsIGZhdlQpOwog
ICAgICAgICAgICBib2R5Lmluc2VydEJlZm9yZShmdCwgYm9keS5maXJzdENoaWxkKTsKICAgICAgICB9
CgogICAgICAgIGlmIChwYXN0ZWQpIHsKICAgICAgICAgICAgZWwuY2xhc3NMaXN0LmFkZCgncGFzdGVk
Jyk7CiAgICAgICAgICAgIGNvbnN0IGJhZGdlID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnc3Bhbicp
OwogICAgICAgICAgICBiYWRnZS5jbGFzc05hbWUgPSAnaS11c2VkJzsKICAgICAgICAgICAgYmFkZ2Uu
dGl0bGUgPSAn5bey57KY6LS0JzsKICAgICAgICAgICAgYmFkZ2UuaW5uZXJIVE1MID0gYDxzdmcgdmll
d0JveD0iMCAwIDE2IDE2IiBmaWxsPSJub25lIiBzdHJva2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdp
ZHRoPSIyLjQiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIgc3Ryb2tlLWxpbmVqb2luPSJyb3VuZCI+PHBv
bHlsaW5lIHBvaW50cz0iMy41IDguNSA2LjUgMTEuNSAxMi41IDQuNSIvPjwvc3ZnPmA7CiAgICAgICAg
ICAgIGljby5hcHBlbmRDaGlsZChiYWRnZSk7CiAgICAgICAgfQoKICAgICAgICBjb25zdCBudW0gPSBk
b2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsKICAgICAgICBudW0uY2xhc3NOYW1lID0gJ2ktbnVt
JzsKICAgICAgICBjb25zdCBudW1UeHQgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdzcGFuJyk7CiAg
ICAgICAgbnVtVHh0LnRleHRDb250ZW50ID0gaWR4OwogICAgICAgIG51bS5hcHBlbmRDaGlsZChudW1U
eHQpOwogICAgICAgIGNvbnN0IHNyY0ljbyA9IFN0cmluZyhjLnNyY0ljb24gfHwgJycpOwogICAgICAg
IGNvbnN0IHNyY0V4ZSA9IFN0cmluZyhjLnNyY0V4ZSB8fCAnJyk7CiAgICAgICAgY29uc3Qgc3JjVGl0
bGUgPSBTdHJpbmcoYy5zcmNUaXRsZSB8fCAnJyk7CiAgICAgICAgaWYgKHNyY0ljbykgewogICAgICAg
ICAgICBjb25zdCBpbWcgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdpbWcnKTsKICAgICAgICAgICAg
aW1nLmNsYXNzTmFtZSA9ICdpLXNyYy1pY28nOwogICAgICAgICAgICBpbWcuc3JjID0gU1RPUkVfQkFT
RSArIGVuY29kZVVSSUNvbXBvbmVudChzcmNJY28pOwogICAgICAgICAgICBpbWcuYWx0ID0gJyc7CiAg
ICAgICAgICAgIGNvbnN0IHRpcFR4dCA9IHNyY1RpdGxlIHx8IHNyY0V4ZSB8fCAn5p2l5rqQJzsKICAg
ICAgICAgICAgaW1nLnRpdGxlID0gdGlwVHh0OwogICAgICAgICAgICBpbWcub25jbGljayA9IGUgPT4g
eyBlLnByZXZlbnREZWZhdWx0KCk7IGUuc3RvcFByb3BhZ2F0aW9uKCk7IHNob3dTcmNUaXAoaW1nLCB0
aXBUeHQpOyB9OwogICAgICAgICAgICBudW0uYXBwZW5kQ2hpbGQoaW1nKTsKICAgICAgICB9CgogICAg
ICAgIGVsLmFwcGVuZENoaWxkKGljbyk7CiAgICAgICAgZWwuYXBwZW5kQ2hpbGQoYm9keSk7CiAgICAg
ICAgZWwuYXBwZW5kQ2hpbGQobnVtKTsKCiAgICAgICAgZWwub25wb2ludGVyZG93biA9IGUgPT4gewog
ICAgICAgICAgICBiZWdpblBhc3RlRnJvbUl0ZW0oZSwgYyk7CiAgICAgICAgfTsKICAgICAgICBlbC5v
bmNvbnRleHRtZW51ID0gZSA9PiB7CiAgICAgICAgICAgIGUucHJldmVudERlZmF1bHQoKTsKICAgICAg
ICAgICAgc2VsZWN0ZWRJZCA9IGMuaWQ7CiAgICAgICAgICAgIHNob3dDdHgoZS5jbGllbnRYLCBlLmNs
aWVudFksIGMpOwogICAgICAgIH07CgogICAgICAgIHJldHVybiBlbDsKICAgIH0KCiAgICBmdW5jdGlv
biBpdGVtSXNRdWV1ZURvbmUocm93KSB7CiAgICAgICAgaWYgKCFyb3cpIHJldHVybiBmYWxzZTsKICAg
ICAgICBpZiAocm93LmNsYXNzTGlzdC5jb250YWlucygncGFzdGVkJykgfHwgcm93LmNsYXNzTGlzdC5j
b250YWlucygncS1kb25lJykpCiAgICAgICAgICAgIHJldHVybiB0cnVlOwogICAgICAgIGNvbnN0IGlk
ID0gK3Jvdy5kYXRhc2V0LmlkOwogICAgICAgIGNvbnN0IGMgPSBhbGxDbGlwcy5maW5kKHggPT4gK3gu
aWQgPT09IGlkKTsKICAgICAgICByZXR1cm4gISEoYyAmJiBpc1Bhc3RlZChjKSk7CiAgICB9CgogICAg
ZnVuY3Rpb24gbWFya1F1ZXVlUmFpbHMoKSB7CiAgICAgICAgaWYgKCFsaXN0RWwpIHJldHVybjsKICAg
ICAgICBjb25zdCBub2RlcyA9IFsuLi5saXN0RWwucXVlcnlTZWxlY3RvckFsbCgnLml0bS5xLW1lbWJl
cicpXTsKICAgICAgICBpZiAoIW5vZGVzLmxlbmd0aCkgcmV0dXJuOwogICAgICAgIC8vIFJlc2V0IGxp
bmsgY2xhc3Nlczsga2VlcCBzdHJ1Y3R1cmFsIGVuZHMKICAgICAgICBub2Rlcy5mb3JFYWNoKG4gPT4g
bi5jbGFzc0xpc3QucmVtb3ZlKCdxLWZpcnN0JywgJ3EtbGFzdCcsICdxLW9ubHknLCAncS1kb25lLWxp
bmsnLCAncS1wYXN0ZWQtbmV4dCcpKTsKICAgICAgICAvLyBHcm91cCBjb25zZWN1dGl2ZSBzYW1lIHF1
ZXVlR3JvdXAgaW4gRE9NIG9yZGVyCiAgICAgICAgbGV0IGkgPSAwOwogICAgICAgIHdoaWxlIChpIDwg
bm9kZXMubGVuZ3RoKSB7CiAgICAgICAgICAgIGNvbnN0IGcgPSBub2Rlc1tpXS5kYXRhc2V0LnFnOwog
ICAgICAgICAgICBsZXQgaiA9IGkgKyAxOwogICAgICAgICAgICB3aGlsZSAoaiA8IG5vZGVzLmxlbmd0
aCAmJiBub2Rlc1tqXS5kYXRhc2V0LnFnID09PSBnKSBqKys7CiAgICAgICAgICAgIGNvbnN0IHNsaWNl
ID0gbm9kZXMuc2xpY2UoaSwgaik7CiAgICAgICAgICAgIGlmIChzbGljZS5sZW5ndGggPT09IDEpIHsK
ICAgICAgICAgICAgICAgIHNsaWNlWzBdLmNsYXNzTGlzdC5hZGQoJ3Etb25seScpOwogICAgICAgICAg
ICB9IGVsc2UgewogICAgICAgICAgICAgICAgc2xpY2VbMF0uY2xhc3NMaXN0LmFkZCgncS1maXJzdCcp
OwogICAgICAgICAgICAgICAgc2xpY2Vbc2xpY2UubGVuZ3RoIC0gMV0uY2xhc3NMaXN0LmFkZCgncS1s
YXN0Jyk7CiAgICAgICAgICAgIH0KICAgICAgICAgICAgZm9yIChsZXQgayA9IDA7IGsgPCBzbGljZS5s
ZW5ndGg7IGsrKykgewogICAgICAgICAgICAgICAgY29uc3QgZG9uZSA9IGl0ZW1Jc1F1ZXVlRG9uZShz
bGljZVtrXSk7CiAgICAgICAgICAgICAgICBzbGljZVtrXS5jbGFzc0xpc3QudG9nZ2xlKCdxLWRvbmUn
LCBkb25lKTsKICAgICAgICAgICAgICAgIGNvbnN0IGRvdCA9IHNsaWNlW2tdLnF1ZXJ5U2VsZWN0b3Io
Jy5xLWRvdCcpOwogICAgICAgICAgICAgICAgaWYgKGRvdCkgZG90LnRpdGxlID0gZG9uZSA/ICfpmJ/l
iJflt7LnspjotLQnIDogJ+eymOi0tOmYn+WIlyc7CiAgICAgICAgICAgICAgICAvLyBHcmVlbiByYWls
IGZvciBldmVyeSBpdGVtIGluIGEgMisgZGVxdWV1ZWQgcnVuIChpbmNsLiBmaXJzdC9sYXN0IHN0dWJz
KQogICAgICAgICAgICAgICAgY29uc3QgcHJldkRvbmUgPSBrID4gMCAmJiBpdGVtSXNRdWV1ZURvbmUo
c2xpY2VbayAtIDFdKTsKICAgICAgICAgICAgICAgIGNvbnN0IG5leHREb25lID0gayA8IHNsaWNlLmxl
bmd0aCAtIDEgJiYgaXRlbUlzUXVldWVEb25lKHNsaWNlW2sgKyAxXSk7CiAgICAgICAgICAgICAgICBp
ZiAoZG9uZSAmJiAocHJldkRvbmUgfHwgbmV4dERvbmUpKQogICAgICAgICAgICAgICAgICAgIHNsaWNl
W2tdLmNsYXNzTGlzdC5hZGQoJ3EtZG9uZS1saW5rJyk7CiAgICAgICAgICAgIH0KICAgICAgICAgICAg
aSA9IGo7CiAgICAgICAgfQogICAgfQoKICAgIGNvbnN0IHBhdGhUaXBFbCA9IGRvY3VtZW50LmdldEVs
ZW1lbnRCeUlkKCdwYXRoLXRpcCcpOwogICAgbGV0IHBhdGhUaXBUaW1lciA9IDA7CiAgICBsZXQgcGF0
aFRpcEhpZGVUaW1lciA9IDA7CiAgICBsZXQgcGF0aFRpcFRva2VuID0gMDsKICAgIGxldCBwYXRoVGlw
QW5jaG9yQnRuID0gbnVsbDsKCiAgICBmdW5jdGlvbiBoaWRlUGF0aFRpcCgpIHsKICAgICAgICBjbGVh
clRpbWVvdXQocGF0aFRpcFRpbWVyKTsKICAgICAgICBjbGVhclRpbWVvdXQocGF0aFRpcEhpZGVUaW1l
cik7CiAgICAgICAgcGF0aFRpcFRva2VuKys7CiAgICAgICAgaWYgKHBhdGhUaXBBbmNob3JCdG4pIHsK
ICAgICAgICAgICAgcGF0aFRpcEFuY2hvckJ0bi5jbGFzc0xpc3QucmVtb3ZlKCdvbicpOwogICAgICAg
ICAgICBwYXRoVGlwQW5jaG9yQnRuID0gbnVsbDsKICAgICAgICB9CiAgICAgICAgaWYgKHBhdGhUaXBF
bCkgewogICAgICAgICAgICBwYXRoVGlwRWwuY2xhc3NMaXN0LnJlbW92ZSgnb24nKTsKICAgICAgICAg
ICAgcGF0aFRpcEVsLnNldEF0dHJpYnV0ZSgnYXJpYS1oaWRkZW4nLCAndHJ1ZScpOwogICAgICAgIH0K
ICAgIH0KICAgIGZ1bmN0aW9uIHBsYWNlUGF0aFRpcChhbmNob3JFbCkgewogICAgICAgIGlmICghcGF0
aFRpcEVsIHx8ICFhbmNob3JFbCkgcmV0dXJuOwogICAgICAgIGNvbnN0IHRpcCA9IHBhdGhUaXBFbDsK
ICAgICAgICBjb25zdCBhciA9IGFuY2hvckVsLmdldEJvdW5kaW5nQ2xpZW50UmVjdCgpOwogICAgICAg
IGNvbnN0IHBhZCA9IDg7CiAgICAgICAgdGlwLnN0eWxlLmxlZnQgPSAnMHB4JzsKICAgICAgICB0aXAu
c3R5bGUudG9wID0gJzBweCc7CiAgICAgICAgdGlwLmNsYXNzTGlzdC5hZGQoJ29uJyk7CiAgICAgICAg
Y29uc3QgdHcgPSB0aXAub2Zmc2V0V2lkdGg7CiAgICAgICAgY29uc3QgdGggPSB0aXAub2Zmc2V0SGVp
Z2h0OwogICAgICAgIGxldCBsZWZ0ID0gYXIubGVmdDsKICAgICAgICBsZXQgdG9wID0gYXIuYm90dG9t
ICsgNjsKICAgICAgICBpZiAobGVmdCArIHR3ID4gd2luZG93LmlubmVyV2lkdGggLSBwYWQpCiAgICAg
ICAgICAgIGxlZnQgPSBNYXRoLm1heChwYWQsIHdpbmRvdy5pbm5lcldpZHRoIC0gdHcgLSBwYWQpOwog
ICAgICAgIGlmIChsZWZ0IDwgcGFkKSBsZWZ0ID0gcGFkOwogICAgICAgIGlmICh0b3AgKyB0aCA+IHdp
bmRvdy5pbm5lckhlaWdodCAtIHBhZCkKICAgICAgICAgICAgdG9wID0gTWF0aC5tYXgocGFkLCBhci50
b3AgLSB0aCAtIDYpOwogICAgICAgIHRpcC5zdHlsZS5sZWZ0ID0gbGVmdCArICdweCc7CiAgICAgICAg
dGlwLnN0eWxlLnRvcCA9IHRvcCArICdweCc7CiAgICB9CiAgICAgICAgZnVuY3Rpb24gY2hlY2tGaWxl
UGF0aHMocGF0aHMpIHsKICAgICAgICBjb25zdCBsaXN0ID0gKHBhdGhzIHx8IFtdKS5tYXAocCA9PiB7
CiAgICAgICAgICAgIGxldCBwYXRoID0gU3RyaW5nKHAgfHwgJycpLnRyaW0oKTsKICAgICAgICAgICAg
aWYgKChwYXRoLnN0YXJ0c1dpdGgoJyInKSAmJiBwYXRoLmVuZHNXaXRoKCciJykpIHx8IChwYXRoLnN0
YXJ0c1dpdGgoIiciKSAmJiBwYXRoLmVuZHNXaXRoKCInIikpKQogICAgICAgICAgICAgICAgcGF0aCA9
IHBhdGguc2xpY2UoMSwgLTEpLnRyaW0oKTsKICAgICAgICAgICAgcmV0dXJuIHBhdGg7CiAgICAgICAg
fSk7CiAgICAgICAgLy8gT25lIGhvc3Qgcm91bmQtdHJpcCBmb3IgdGhlIHdob2xlIGxpc3Qg4oCUIE7D
lyBwYXRoRXhpc3RzIGZyZWV6ZXMgZmlsZSB0YWIKICAgICAgICB0cnkgewogICAgICAgICAgICBjb25z
dCByYXcgPSBhaGtSZXQoJ2NoZWNrUGF0aHMnLCBsaXN0LmpvaW4oJ1xuJykpOwogICAgICAgICAgICBp
ZiAocmF3KSB7CiAgICAgICAgICAgICAgICBjb25zdCBwYXJzZWQgPSB0eXBlb2YgcmF3ID09PSAnc3Ry
aW5nJyA/IEpTT04ucGFyc2UocmF3KSA6IHJhdzsKICAgICAgICAgICAgICAgIGlmIChBcnJheS5pc0Fy
cmF5KHBhcnNlZCkgJiYgcGFyc2VkLmxlbmd0aCkgewogICAgICAgICAgICAgICAgICAgIHJldHVybiBs
aXN0Lm1hcCgocGF0aCwgaSkgPT4gewogICAgICAgICAgICAgICAgICAgICAgICBjb25zdCByb3cgPSBw
YXJzZWRbaV0gfHwge307CiAgICAgICAgICAgICAgICAgICAgICAgIHJldHVybiB7CiAgICAgICAgICAg
ICAgICAgICAgICAgICAgICBwYXRoOiBwYXRoIHx8IFN0cmluZyhyb3cucGF0aCB8fCAnJyksCiAgICAg
ICAgICAgICAgICAgICAgICAgICAgICBleGlzdHM6IHJvdy5leGlzdHMgPT09IHRydWUgfHwgcm93LmV4
aXN0cyA9PT0gMSB8fCByb3cuZXhpc3RzID09PSAnMScsCiAgICAgICAgICAgICAgICAgICAgICAgICAg
ICBpc0RpcjogISEocm93LmlzRGlyID09PSB0cnVlIHx8IHJvdy5pc0RpciA9PT0gMSB8fCByb3cuaXNE
aXIgPT09ICcxJykKICAgICAgICAgICAgICAgICAgICAgICAgfTsKICAgICAgICAgICAgICAgICAgICB9
KTsKICAgICAgICAgICAgICAgIH0KICAgICAgICAgICAgfQogICAgICAgIH0gY2F0Y2gge30KICAgICAg
ICByZXR1cm4gbGlzdC5tYXAocGF0aCA9PiB7CiAgICAgICAgICAgIGlmICghcGF0aCkgcmV0dXJuIHsg
cGF0aCwgZXhpc3RzOiBmYWxzZSwgaXNEaXI6IGZhbHNlIH07CiAgICAgICAgICAgIGxldCBleGlzdHMg
PSBmYWxzZTsKICAgICAgICAgICAgdHJ5IHsKICAgICAgICAgICAgICAgIGNvbnN0IGZsYWcgPSBTdHJp
bmcoYWhrUmV0KCdwYXRoRXhpc3RzJywgcGF0aCkgPz8gJycpLnRyaW0oKS50b0xvd2VyQ2FzZSgpOwog
ICAgICAgICAgICAgICAgZXhpc3RzID0gKGZsYWcgPT09ICcxJyB8fCBmbGFnID09PSAndHJ1ZScpOwog
ICAgICAgICAgICB9IGNhdGNoIHt9CiAgICAgICAgICAgIHJldHVybiB7IHBhdGgsIGV4aXN0cywgaXNE
aXI6IGZhbHNlIH07CiAgICAgICAgfSk7CiAgICB9CiAgICBsZXQgZ29uZUNoZWNrVGltZXIgPSAwOwog
ICAgZnVuY3Rpb24gc2NoZWR1bGVGaWxlR29uZUNoZWNrKCkgewogICAgICAgIGlmIChnb25lQ2hlY2tU
aW1lcikgcmV0dXJuOwogICAgICAgIGdvbmVDaGVja1RpbWVyID0gc2V0VGltZW91dCgoKSA9PiB7CiAg
ICAgICAgICAgIGdvbmVDaGVja1RpbWVyID0gMDsKICAgICAgICAgICAgY29uc3Qgbm9kZXMgPSBbLi4u
bGlzdEVsLnF1ZXJ5U2VsZWN0b3JBbGwoJy5pdG0nKV0uZmlsdGVyKG4gPT4gbi5fZmlsZVBhdGhzICYm
IG4uX2ZpbGVQYXRocy5sZW5ndGgpOwogICAgICAgICAgICBpZiAoIW5vZGVzLmxlbmd0aCkgcmV0dXJu
OwogICAgICAgICAgICBjb25zdCB1bmlxdWUgPSBbXTsKICAgICAgICAgICAgY29uc3Qgc2VlbiA9IG5l
dyBTZXQoKTsKICAgICAgICAgICAgbm9kZXMuZm9yRWFjaChuID0+IHsKICAgICAgICAgICAgICAgIG4u
X2ZpbGVQYXRocy5mb3JFYWNoKHAgPT4gewogICAgICAgICAgICAgICAgICAgIGNvbnN0IHBhdGggPSBT
dHJpbmcocCB8fCAnJyk7CiAgICAgICAgICAgICAgICAgICAgaWYgKCFwYXRoIHx8IHNlZW4uaGFzKHBh
dGgpKSByZXR1cm47CiAgICAgICAgICAgICAgICAgICAgc2Vlbi5hZGQocGF0aCk7CiAgICAgICAgICAg
ICAgICAgICAgdW5pcXVlLnB1c2gocGF0aCk7CiAgICAgICAgICAgICAgICB9KTsKICAgICAgICAgICAg
fSk7CiAgICAgICAgICAgIGNvbnN0IHJvd3MgPSBjaGVja0ZpbGVQYXRocyh1bmlxdWUpOwogICAgICAg
ICAgICBjb25zdCBieVBhdGggPSBuZXcgTWFwKCk7CiAgICAgICAgICAgIHJvd3MuZm9yRWFjaChyID0+
IGJ5UGF0aC5zZXQoU3RyaW5nKHIucGF0aCB8fCAnJyksIHIpKTsKICAgICAgICAgICAgbm9kZXMuZm9y
RWFjaChuID0+IHsKICAgICAgICAgICAgICAgIGNvbnN0IHBhdGhSb3dzID0gbi5fZmlsZVBhdGhzLm1h
cChwID0+IHsKICAgICAgICAgICAgICAgICAgICBjb25zdCBoaXQgPSBieVBhdGguZ2V0KFN0cmluZyhw
IHx8ICcnKSk7CiAgICAgICAgICAgICAgICAgICAgcmV0dXJuIGhpdCB8fCB7IHBhdGg6IHAsIGV4aXN0
czogdHJ1ZSwgaXNEaXI6IGZhbHNlIH07CiAgICAgICAgICAgICAgICB9KTsKICAgICAgICAgICAgICAg
IG4uX3BhdGhSb3dzID0gcGF0aFJvd3M7CiAgICAgICAgICAgICAgICBjb25zdCBhbGxHb25lID0gcGF0
aFJvd3MubGVuZ3RoID4gMCAmJiBwYXRoUm93cy5ldmVyeShyID0+IHIuZXhpc3RzID09PSBmYWxzZSk7
CiAgICAgICAgICAgICAgICBuLmNsYXNzTGlzdC50b2dnbGUoJ2dvbmUnLCBhbGxHb25lKTsKICAgICAg
ICAgICAgfSk7CiAgICAgICAgfSwgNDAwKTsKICAgIH0KICAgIGZ1bmN0aW9uIGZpbGxGaWxlRGV0YWls
UGFuZWwoY29udGFpbmVyLCByb3dzKSB7CiAgICAgICAgY29udGFpbmVyLmlubmVySFRNTCA9ICcnOwog
ICAgICAgIGlmICghcm93cy5sZW5ndGgpIHsKICAgICAgICAgICAgY29uc3QgZW1wdHkgPSBkb2N1bWVu
dC5jcmVhdGVFbGVtZW50KCdkaXYnKTsKICAgICAgICAgICAgZW1wdHkuY2xhc3NOYW1lID0gJ2ZkLXBh
dGgnOwogICAgICAgICAgICBlbXB0eS50ZXh0Q29udGVudCA9ICfml6Dot6/lvoQnOwogICAgICAgICAg
ICBjb250YWluZXIuYXBwZW5kQ2hpbGQoZW1wdHkpOwogICAgICAgICAgICByZXR1cm47CiAgICAgICAg
fQogICAgICAgIHJvd3MuZm9yRWFjaChyID0+IHsKICAgICAgICAgICAgY29uc3QgcGF0aCA9IFN0cmlu
ZyhyLnBhdGggfHwgJycpOwogICAgICAgICAgICBjb25zdCBtaXNzaW5nID0gci5leGlzdHMgPT09IGZh
bHNlOwogICAgICAgICAgICBjb25zdCBibG9jayA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2Rpdicp
OwogICAgICAgICAgICBibG9jay5jbGFzc05hbWUgPSAnZmQtYmxvY2snOwoKICAgICAgICAgICAgY29u
c3QgcGF0aEVsID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnZGl2Jyk7CiAgICAgICAgICAgIHBhdGhF
bC5jbGFzc05hbWUgPSAnZmQtcGF0aCcgKyAobWlzc2luZyA/ICcgZGVhZCcgOiAnIGxpdmUnKTsKICAg
ICAgICAgICAgcGF0aEVsLnRleHRDb250ZW50ID0gcGF0aCB8fCAnKOepuui3r+W+hCknOwogICAgICAg
ICAgICBpZiAoIW1pc3NpbmcpIHsKICAgICAgICAgICAgICAgIHBhdGhFbC5vbmNsaWNrID0gZSA9PiB7
CiAgICAgICAgICAgICAgICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOwogICAgICAgICAgICAgICAgICAg
IGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAgICAgICAgICAgICAgICAgYWhrKCdvcGVuUGF0aCcsIHBh
dGgpOwogICAgICAgICAgICAgICAgfTsKICAgICAgICAgICAgfQogICAgICAgICAgICBibG9jay5hcHBl
bmRDaGlsZChwYXRoRWwpOwoKICAgICAgICAgICAgY29uc3QgYWN0aW9ucyA9IGRvY3VtZW50LmNyZWF0
ZUVsZW1lbnQoJ2RpdicpOwogICAgICAgICAgICBhY3Rpb25zLmNsYXNzTmFtZSA9ICdmZC1hY3Rpb25z
JzsKCiAgICAgICAgICAgIGNvbnN0IGNvcHlCdG4gPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdidXR0
b24nKTsKICAgICAgICAgICAgY29weUJ0bi50eXBlID0gJ2J1dHRvbic7CiAgICAgICAgICAgIGNvcHlC
dG4uY2xhc3NOYW1lID0gJ2ZkLWJ0bic7CiAgICAgICAgICAgIGNvcHlCdG4uaW5uZXJIVE1MID0gJzxz
cGFuIGNsYXNzPSJmZC1pY28iPvCflJc8L3NwYW4+PHNwYW4gY2xhc3M9ImZkLXR4dCI+5aSN5Yi26Lev
5b6EPC9zcGFuPic7CiAgICAgICAgICAgIGNvcHlCdG4ub25jbGljayA9IGUgPT4gewogICAgICAgICAg
ICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOwogICAgICAgICAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24o
KTsKICAgICAgICAgICAgICAgIGFoaygnY29weVBhdGgnLCBwYXRoKTsKICAgICAgICAgICAgICAgIGNv
cHlCdG4ucXVlcnlTZWxlY3RvcignLmZkLXR4dCcpLnRleHRDb250ZW50ID0gJ+W3suWkjeWItic7CiAg
ICAgICAgICAgICAgICBjb3B5QnRuLmNsYXNzTGlzdC5hZGQoJ29rJyk7CiAgICAgICAgICAgICAgICBz
ZXRUaW1lb3V0KCgpID0+IHsKICAgICAgICAgICAgICAgICAgICBjb3B5QnRuLnF1ZXJ5U2VsZWN0b3Io
Jy5mZC10eHQnKS50ZXh0Q29udGVudCA9ICflpI3liLbot6/lvoQnOwogICAgICAgICAgICAgICAgICAg
IGNvcHlCdG4uY2xhc3NMaXN0LnJlbW92ZSgnb2snKTsKICAgICAgICAgICAgICAgIH0sIDEyMDApOwog
ICAgICAgICAgICB9OwogICAgICAgICAgICBhY3Rpb25zLmFwcGVuZENoaWxkKGNvcHlCdG4pOwoKICAg
ICAgICAgICAgY29uc3QgZm9sZGVyQnRuID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnYnV0dG9uJyk7
CiAgICAgICAgICAgIGZvbGRlckJ0bi50eXBlID0gJ2J1dHRvbic7CiAgICAgICAgICAgIGZvbGRlckJ0
bi5jbGFzc05hbWUgPSAnZmQtYnRuJzsKICAgICAgICAgICAgZm9sZGVyQnRuLmlubmVySFRNTCA9ICc8
c3BhbiBjbGFzcz0iZmQtaWNvIj7wn5OCPC9zcGFuPjxzcGFuIGNsYXNzPSJmZC10eHQiPuaJk+W8gOaJ
gOWcqOaWh+S7tuWkuTwvc3Bhbj4nOwogICAgICAgICAgICBmb2xkZXJCdG4ub25jbGljayA9IGUgPT4g
ewogICAgICAgICAgICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOwogICAgICAgICAgICAgICAgZS5zdG9w
UHJvcGFnYXRpb24oKTsKICAgICAgICAgICAgICAgIGFoaygnb3BlbkZvbGRlcicsIHBhdGgpOwogICAg
ICAgICAgICB9OwogICAgICAgICAgICBhY3Rpb25zLmFwcGVuZENoaWxkKGZvbGRlckJ0bik7CgogICAg
ICAgICAgICBibG9jay5hcHBlbmRDaGlsZChhY3Rpb25zKTsKICAgICAgICAgICAgY29udGFpbmVyLmFw
cGVuZENoaWxkKGJsb2NrKTsKICAgICAgICB9KTsKICAgIH0KCiAgICBjb25zdCBjdHhFbCA9IGRvY3Vt
ZW50LmdldEVsZW1lbnRCeUlkKCdjdHgnKTsKICAgIGZ1bmN0aW9uIHNob3dDdHgoeCwgeSwgYykgewog
ICAgICAgIGN0eENsaXAgPSBjOwogICAgICAgIHNlbGVjdGVkSWQgPSBjLmlkOwogICAgICAgIHJhbmdl
QW5jaG9ySWQgPSBjLmlkOwogICAgICAgIHJhbmdlQW5jaG9yQ2xpY2tlZCA9IHRydWU7CiAgICAgICAg
Y29uc3QgY2xlYXJCdG4gPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYy1jbGVhci1wYXN0ZWQnKTsK
ICAgICAgICBpZiAoY2xlYXJCdG4pIGNsZWFyQnRuLnN0eWxlLmRpc3BsYXkgPSBpc1Bhc3RlZChjKSA/
ICcnIDogJ25vbmUnOwogICAgICAgIGNvbnN0IHFGcm9tID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQo
J2MtcXVldWUtZnJvbScpOwogICAgICAgIGlmIChxRnJvbSkgcUZyb20uc3R5bGUuZGlzcGxheSA9IChO
dW1iZXIoYy5xdWV1ZUdyb3VwKSA+IDApID8gJycgOiAnbm9uZSc7CgogICAgICAgIGNvbnN0IHBpbkJ0
biA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjLXBpbicpOwogICAgICAgIGNvbnN0IGNvcHlCdG4g
PSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYy1jb3B5Jyk7CiAgICAgICAgY29uc3QgaXNSZWNlbnQg
PSBub3JtVHlwZShjLnR5cGUpID09PSAncmVjZW50JyB8fCBjdXJUYWIgPT09ICdyZWNlbnQnOwogICAg
ICAgIGlmIChjb3B5QnRuKSB7CiAgICAgICAgICAgIGNvcHlCdG4uaW5uZXJIVE1MID0gaXNSZWNlbnQK
ICAgICAgICAgICAgICAgID8gJzxzcGFuIGNsYXNzPSJjLWljbyI+8J+Ulzwvc3Bhbj7lpI3liLbot6/l
voQnCiAgICAgICAgICAgICAgICA6ICc8c3BhbiBjbGFzcz0iYy1pY28iPuKOmDwvc3Bhbj7lpI3liLYn
OwogICAgICAgICAgICBjb3B5QnRuLnN0eWxlLmRpc3BsYXkgPSAnJzsKICAgICAgICB9CiAgICAgICAg
aWYgKHBpbkJ0bikgewogICAgICAgICAgICBpZiAoaXNSZWNlbnQpIHsKICAgICAgICAgICAgICAgIC8v
IFJlY2VudCBmb2xkZXJzOiBwaW4gPSBrZWVwIHBhdGggKG5vdCBjbGlwYm9hcmQg5pS26JePKQogICAg
ICAgICAgICAgICAgcGluQnRuLnN0eWxlLmRpc3BsYXkgPSAnJzsKICAgICAgICAgICAgICAgIGNvbnN0
IG9uID0gaXNQaW5uZWQoYyk7CiAgICAgICAgICAgICAgICBwaW5CdG4uaW5uZXJIVE1MID0gb24KICAg
ICAgICAgICAgICAgICAgICA/ICc8c3BhbiBjbGFzcz0iYy1pY28iPuKYhTwvc3Bhbj7lj5bmtojlm7rl
rponCiAgICAgICAgICAgICAgICAgICAgOiAnPHNwYW4gY2xhc3M9ImMtaWNvIj7imIU8L3NwYW4+5Zu6
5a6a6Lev5b6EJzsKICAgICAgICAgICAgfSBlbHNlIHsKICAgICAgICAgICAgICAgIHBpbkJ0bi5zdHls
ZS5kaXNwbGF5ID0gJyc7CiAgICAgICAgICAgICAgICBjb25zdCBvbiA9IGlzUGlubmVkKGMpOwogICAg
ICAgICAgICAgICAgcGluQnRuLmlubmVySFRNTCA9IG9uCiAgICAgICAgICAgICAgICAgICAgPyAnPHNw
YW4gY2xhc3M9ImMtaWNvIj7imIU8L3NwYW4+5Y+W5raI5pS26JePJwogICAgICAgICAgICAgICAgICAg
IDogJzxzcGFuIGNsYXNzPSJjLWljbyI+4piFPC9zcGFuPuaUtuiXjyc7CiAgICAgICAgICAgIH0KICAg
ICAgICB9CiAgICAgICAgY29uc3QgdGl0bGVCdG4gPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYy10
aXRsZScpOwogICAgICAgIGlmICh0aXRsZUJ0bikgewogICAgICAgICAgICAvLyBObyBmYXYtdGl0bGUg
Zm9yIHJlY2VudCBwYXRocwogICAgICAgICAgICBjb25zdCBzaG93VGl0bGUgPSAhaXNSZWNlbnQgJiYg
KGlzUGlubmVkKGMpIHx8IGN1clRhYiA9PT0gJ3Bpbm5lZCcpOwogICAgICAgICAgICB0aXRsZUJ0bi5z
dHlsZS5kaXNwbGF5ID0gc2hvd1RpdGxlID8gJycgOiAnbm9uZSc7CiAgICAgICAgICAgIGlmIChzaG93
VGl0bGUpCiAgICAgICAgICAgICAgICB0aXRsZUJ0bi5pbm5lckhUTUwgPSAoU3RyaW5nKGMuZmF2VGl0
bGUgfHwgJycpLnRyaW0oKSA/ICc8c3BhbiBjbGFzcz0iYy1pY28iPuKcjjwvc3Bhbj7nvJbovpHmoIfp
opgnIDogJzxzcGFuIGNsYXNzPSJjLWljbyI+4pyOPC9zcGFuPuiuvue9ruagh+mimCcpOwogICAgICAg
IH0KICAgICAgICBjb25zdCBtZXJnZUJ0biA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjLW1lcmdl
Jyk7CiAgICAgICAgY29uc3QgdW5tZXJnZUJ0biA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjLXVu
bWVyZ2UnKTsKICAgICAgICBjb25zdCBvblBpbm5lZCA9IGN1clRhYiA9PT0gJ3Bpbm5lZCc7CiAgICAg
ICAgaWYgKG1lcmdlQnRuKQogICAgICAgICAgICBtZXJnZUJ0bi5zdHlsZS5kaXNwbGF5ID0gKCFpc1Jl
Y2VudCAmJiBvblBpbm5lZCAmJiBtdWx0aUlkcy5sZW5ndGggPj0gMikgPyAnJyA6ICdub25lJzsKICAg
ICAgICBpZiAodW5tZXJnZUJ0bikKICAgICAgICAgICAgdW5tZXJnZUJ0bi5zdHlsZS5kaXNwbGF5ID0g
KCFpc1JlY2VudCAmJiBvblBpbm5lZCAmJiBmYXZHcm91cE9mKGMpKSA/ICcnIDogJ25vbmUnOwogICAg
ICAgIGNvbnN0IHRvcEJ0biA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjLXRvcCcpOwogICAgICAg
IGlmICh0b3BCdG4pCiAgICAgICAgICAgIHRvcEJ0bi5zdHlsZS5kaXNwbGF5ID0gaXNSZWNlbnQgPyAn
bm9uZScgOiAnJzsKICAgICAgICBjb25zdCBjbGVhckJ0bjIgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJ
ZCgnYy1jbGVhci1wYXN0ZWQnKTsKICAgICAgICBpZiAoY2xlYXJCdG4yICYmIGlzUmVjZW50KQogICAg
ICAgICAgICBjbGVhckJ0bjIuc3R5bGUuZGlzcGxheSA9ICdub25lJzsKICAgICAgICBjb25zdCBxRnJv
bTIgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYy1xdWV1ZS1mcm9tJyk7CiAgICAgICAgaWYgKHFG
cm9tMiAmJiBpc1JlY2VudCkKICAgICAgICAgICAgcUZyb20yLnN0eWxlLmRpc3BsYXkgPSAnbm9uZSc7
CiAgICAgICAgY29uc3QgZGVsQnRuID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2MtZGVsJyk7CiAg
ICAgICAgaWYgKGRlbEJ0bikgewogICAgICAgICAgICBjb25zdCBtdWx0aURlbCA9IG11bHRpSWRzLmxl
bmd0aCA+IDEgJiYgbXVsdGlJZHMuaW5jbHVkZXMoK2MuaWQpOwogICAgICAgICAgICBjb25zdCBuID0g
bXVsdGlEZWwgPyBtdWx0aUlkcy5sZW5ndGggOiAxOwogICAgICAgICAgICBkZWxCdG4uaW5uZXJIVE1M
ID0gbiA+IDEKICAgICAgICAgICAgICAgID8gKCc8c3BhbiBjbGFzcz0iYy1pY28iPuKclTwvc3Bhbj7l
iKDpmaQgKCcgKyBuICsgJyknKQogICAgICAgICAgICAgICAgOiAnPHNwYW4gY2xhc3M9ImMtaWNvIj7i
nJU8L3NwYW4+5Yig6ZmkJzsKICAgICAgICB9CiAgICAgICAgY3R4RWwuY2xhc3NMaXN0LmFkZCgnb24n
KTsKICAgICAgICBjdHhFbC5zdHlsZS5sZWZ0ID0geCArICdweCc7CiAgICAgICAgY3R4RWwuc3R5bGUu
dG9wICA9IHkgKyAncHgnOwogICAgICAgIHJlcXVlc3RBbmltYXRpb25GcmFtZSgoKSA9PiB7CiAgICAg
ICAgICAgIGNvbnN0IHIgPSBjdHhFbC5nZXRCb3VuZGluZ0NsaWVudFJlY3QoKTsKICAgICAgICAgICAg
aWYgKHIucmlnaHQgID4gaW5uZXJXaWR0aCkgIGN0eEVsLnN0eWxlLmxlZnQgPSAoeCAtIHIud2lkdGgp
ICArICdweCc7CiAgICAgICAgICAgIGlmIChyLmJvdHRvbSA+IGlubmVySGVpZ2h0KSBjdHhFbC5zdHls
ZS50b3AgID0gKHkgLSByLmhlaWdodCkgKyAncHgnOwogICAgICAgIH0pOwogICAgfQogICAgZnVuY3Rp
b24gaGlkZUN0eCgpIHsgY3R4RWwuY2xhc3NMaXN0LnJlbW92ZSgnb24nKTsgY3R4Q2xpcCA9IG51bGw7
IH0KICAgIHdpbmRvdy5fX2hpZGVDdHggPSBoaWRlQ3R4OwoKICAgIGZ1bmN0aW9uIGRpc21pc3NDdHhV
bmxlc3NJbnNpZGUoZSkgewogICAgICAgIGlmICghY3R4RWwuY2xhc3NMaXN0LmNvbnRhaW5zKCdvbicp
KSByZXR1cm47CiAgICAgICAgaWYgKGUudGFyZ2V0LmNsb3Nlc3QoJyNjdHgnKSkgcmV0dXJuOwogICAg
ICAgIGhpZGVDdHgoKTsKICAgIH0KICAgIGRvY3VtZW50LmFkZEV2ZW50TGlzdGVuZXIoJ21vdXNlZG93
bicsIGRpc21pc3NDdHhVbmxlc3NJbnNpZGUsIHRydWUpOwogICAgZG9jdW1lbnQuYWRkRXZlbnRMaXN0
ZW5lcignY2xpY2snLCBkaXNtaXNzQ3R4VW5sZXNzSW5zaWRlLCB0cnVlKTsKICAgIGxpc3RFbC5hZGRF
dmVudExpc3RlbmVyKCdzY3JvbGwnLCBoaWRlQ3R4LCB7IHBhc3NpdmU6IHRydWUgfSk7CiAgICBkb2N1
bWVudC5hZGRFdmVudExpc3RlbmVyKCdrZXlkb3duJywgZSA9PiB7CiAgICAgICAgLy8gRXNjOiBhbHdh
eXMgY2xvc2UgcGFuZWwgKHNlYXJjaCBvciBub3QpOyBwaW4ga2VlcHMgcGFuZWwKICAgICAgICBpZiAo
ZS5rZXkgPT09ICdFc2NhcGUnKSB7CiAgICAgICAgICAgIGUucHJldmVudERlZmF1bHQoKTsKICAgICAg
ICAgICAgaGlkZUN0eCgpOwogICAgICAgICAgICBjb25zdCB0ZCA9IGRvY3VtZW50LmdldEVsZW1lbnRC
eUlkKCd0aXRsZS1kbGcnKTsKICAgICAgICAgICAgaWYgKHRkICYmIHRkLmNsYXNzTGlzdC5jb250YWlu
cygnb24nKSkgewogICAgICAgICAgICAgICAgdHJ5IHsgY2xvc2VUaXRsZURsZygpOyB9IGNhdGNoIHsg
dGQuY2xhc3NMaXN0LnJlbW92ZSgnb24nKTsgfQogICAgICAgICAgICAgICAgcmV0dXJuOwogICAgICAg
ICAgICB9CiAgICAgICAgICAgIGlmIChjbHJEbGcuY2xhc3NMaXN0LmNvbnRhaW5zKCdvbicpKSB7CiAg
ICAgICAgICAgICAgICBjbG9zZUNsZWFyRGxnKCk7CiAgICAgICAgICAgICAgICByZXR1cm47CiAgICAg
ICAgICAgIH0KICAgICAgICAgICAgaWYgKCFwaW5uZWRVSSkgYWhrKCdoaWRlJyk7CiAgICAgICAgICAg
IHJldHVybjsKICAgICAgICB9CiAgICAgICAgLy8gV2hpbGUgdHlwaW5nIGluIHNlYXJjaDogQ3RybCtJ
L0sgYW5kIGFycm93cyBtb3ZlIGxpc3QsIGRvbid0IGxlYXZlIHRoZSBib3gKICAgICAgICBpZiAoZG9j
dW1lbnQuYWN0aXZlRWxlbWVudD8uaWQgPT09ICdzZWFyY2gnKSB7CiAgICAgICAgICAgIGlmICgoZS5j
dHJsS2V5IHx8IGUubWV0YUtleSkgJiYgKGUua2V5ID09PSAnaScgfHwgZS5rZXkgPT09ICdJJykpIHsK
ICAgICAgICAgICAgICAgIGUucHJldmVudERlZmF1bHQoKTsgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAg
ICAgICAgICAgICAgIHdpbmRvdy5fX25hdiAmJiB3aW5kb3cuX19uYXYoJ3VwJyk7CiAgICAgICAgICAg
ICAgICByZXR1cm47CiAgICAgICAgICAgIH0KICAgICAgICAgICAgaWYgKChlLmN0cmxLZXkgfHwgZS5t
ZXRhS2V5KSAmJiAoZS5rZXkgPT09ICdrJyB8fCBlLmtleSA9PT0gJ0snKSkgewogICAgICAgICAgICAg
ICAgZS5wcmV2ZW50RGVmYXVsdCgpOyBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgICAgICAgICAgICAg
d2luZG93Ll9fbmF2ICYmIHdpbmRvdy5fX25hdignZG93bicpOwogICAgICAgICAgICAgICAgcmV0dXJu
OwogICAgICAgICAgICB9CiAgICAgICAgICAgIGlmIChlLmtleSA9PT0gJ0Fycm93RG93bicpIHsKICAg
ICAgICAgICAgICAgIGUucHJldmVudERlZmF1bHQoKTsgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAg
ICAgICAgICAgIHdpbmRvdy5fX25hdiAmJiB3aW5kb3cuX19uYXYoJ2Rvd24nKTsKICAgICAgICAgICAg
ICAgIHJldHVybjsKICAgICAgICAgICAgfQogICAgICAgICAgICBpZiAoZS5rZXkgPT09ICdBcnJvd1Vw
JykgewogICAgICAgICAgICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOyBlLnN0b3BQcm9wYWdhdGlvbigp
OwogICAgICAgICAgICAgICAgd2luZG93Ll9fbmF2ICYmIHdpbmRvdy5fX25hdigndXAnKTsKICAgICAg
ICAgICAgICAgIHJldHVybjsKICAgICAgICAgICAgfQogICAgICAgICAgICByZXR1cm47CiAgICAgICAg
fQogICAgICAgIGNvbnN0IHZpcyA9ICh0eXBlb2YgbmF2TGlzdCA9PT0gJ2Z1bmN0aW9uJyA/IG5hdkxp
c3QoKSA6IHZpc2libGVMaXN0KCkpOwogICAgICAgIGlmICghdmlzLmxlbmd0aCkgcmV0dXJuOwogICAg
ICAgIGxldCBpZHggPSBzZWxlY3RlZEluZGV4KCk7CiAgICAgICAgaWYgKGlkeCA8IDApIGlkeCA9IDA7
CiAgICAgICAgaWYgICAgICAoZS5rZXkgPT09ICdBcnJvd0Rvd24nKSB7IGUucHJldmVudERlZmF1bHQo
KTsgZS5zdG9wUHJvcGFnYXRpb24oKTsgc2VsZWN0QnlJbmRleChpZHggKyAxKTsgfQogICAgICAgIGVs
c2UgaWYgKGUua2V5ID09PSAnQXJyb3dVcCcpICAgeyBlLnByZXZlbnREZWZhdWx0KCk7IGUuc3RvcFBy
b3BhZ2F0aW9uKCk7IHNlbGVjdEJ5SW5kZXgoaWR4IC0gMSk7IH0KICAgICAgICBlbHNlIGlmIChlLmtl
eSA9PT0gJ0VudGVyJykgewogICAgICAgICAgICBlLnByZXZlbnREZWZhdWx0KCk7CiAgICAgICAgICAg
IC8vIOWbuuWumuaXtuWbnui9puS4jeeymOi0tO+8jOWPqueCueadoeebrueymOi0tAogICAgICAgICAg
ICBpZiAocGlubmVkVUkpIHJldHVybjsKICAgICAgICAgICAgaWYgKG11bHRpSWRzLmxlbmd0aCA+IDEp
IHsKICAgICAgICAgICAgICAgIGNvbnN0IGlkcyA9IG11bHRpSWRzLnNsaWNlKCk7CiAgICAgICAgICAg
ICAgICBjbGVhck11bHRpKCk7CiAgICAgICAgICAgICAgICBtYXJrUGFzdGVkTG9jYWwoaWRzKTsKICAg
ICAgICAgICAgICAgIGFoaygncGFzdGVNYW55JywgaWRzLmpvaW4oJywnKSk7CiAgICAgICAgICAgICAg
ICByZXR1cm47CiAgICAgICAgICAgIH0KICAgICAgICAgICAgaWYgKG11bHRpSWRzLmxlbmd0aCA9PT0g
MSkgewogICAgICAgICAgICAgICAgY29uc3QgaWQgPSBtdWx0aUlkc1swXTsKICAgICAgICAgICAgICAg
IGNsZWFyTXVsdGkoKTsKICAgICAgICAgICAgICAgIG1hcmtQYXN0ZWRMb2NhbChpZCk7CiAgICAgICAg
ICAgICAgICBhaGsoJ3Bhc3RlJywgU3RyaW5nKGlkKSk7CiAgICAgICAgICAgICAgICByZXR1cm47CiAg
ICAgICAgICAgIH0KICAgICAgICAgICAgY29uc3QgYyA9IHZpc1tzZWxlY3RlZEluZGV4KCldOwogICAg
ICAgICAgICBpZiAoYykgewogICAgICAgICAgICAgICAgbWFya1Bhc3RlZExvY2FsKGMuaWQpOwogICAg
ICAgICAgICAgICAgYWhrKCdwYXN0ZScsIFN0cmluZyhjLmlkKSk7CiAgICAgICAgICAgIH0KICAgICAg
ICB9IGVsc2UgaWYgKC9eWzEtOV0kLy50ZXN0KGUua2V5KSkgewogICAgICAgICAgICBjb25zdCBjID0g
dmlzWytlLmtleSAtIDFdOwogICAgICAgICAgICBpZiAoYykgewogICAgICAgICAgICAgICAgbWFya1Bh
c3RlZExvY2FsKGMuaWQpOwogICAgICAgICAgICAgICAgYWhrKCdwYXN0ZScsIFN0cmluZyhjLmlkKSk7
CiAgICAgICAgICAgIH0KICAgICAgICB9CiAgICB9KTsKCiAgICB3aW5kb3cuX19uYXYgPSBkaXIgPT4g
ewogICAgICAgIGNvbnN0IHZpcyA9ICh0eXBlb2YgbmF2TGlzdCA9PT0gJ2Z1bmN0aW9uJyA/IG5hdkxp
c3QoKSA6IHZpc2libGVMaXN0KCkpOwogICAgICAgIGlmICghdmlzLmxlbmd0aCAmJiBkaXIgIT09ICd0
YWInICYmIGRpciAhPT0gJ3RhYlByZXYnKSByZXR1cm47CiAgICAgICAgbGV0IGlkeCA9IHNlbGVjdGVk
SW5kZXgoKTsKICAgICAgICBpZiAoaWR4IDwgMCkgaWR4ID0gMDsKICAgICAgICBpZiAoZGlyID09PSAn
dXAnKSBzZWxlY3RCeUluZGV4KGlkeCAtIDEpOwogICAgICAgIGVsc2UgaWYgKGRpciA9PT0gJ2Rvd24n
KSBzZWxlY3RCeUluZGV4KGlkeCArIDEpOwogICAgICAgIGVsc2UgaWYgKGRpciA9PT0gJ2VudGVyJykg
ewogICAgICAgICAgICBpZiAocGlubmVkVUkpIHJldHVybjsKICAgICAgICAgICAgX19wcmVwUGFzdGUo
KTsKICAgICAgICAgICAgaWYgKG11bHRpSWRzLmxlbmd0aCA+IDEpIHsKICAgICAgICAgICAgICAgIGNv
bnN0IGlkcyA9IG11bHRpSWRzLnNsaWNlKCk7CiAgICAgICAgICAgICAgICBjbGVhck11bHRpKCk7CiAg
ICAgICAgICAgICAgICBtYXJrUGFzdGVkTG9jYWwoaWRzKTsKICAgICAgICAgICAgICAgIGFoaygncGFz
dGVNYW55JywgaWRzLmpvaW4oJywnKSk7CiAgICAgICAgICAgICAgICByZXR1cm47CiAgICAgICAgICAg
IH0KICAgICAgICAgICAgaWYgKG11bHRpSWRzLmxlbmd0aCA9PT0gMSkgewogICAgICAgICAgICAgICAg
Y29uc3QgaWQgPSBtdWx0aUlkc1swXTsKICAgICAgICAgICAgICAgIGNsZWFyTXVsdGkoKTsKICAgICAg
ICAgICAgICAgIG1hcmtQYXN0ZWRMb2NhbChpZCk7CiAgICAgICAgICAgICAgICBhaGsoJ3Bhc3RlJywg
U3RyaW5nKGlkKSk7CiAgICAgICAgICAgICAgICByZXR1cm47CiAgICAgICAgICAgIH0KICAgICAgICAg
ICAgY29uc3QgYyA9IHZpc1tzZWxlY3RlZEluZGV4KCldOwogICAgICAgICAgICBpZiAoYykgewogICAg
ICAgICAgICAgICAgbWFya1Bhc3RlZExvY2FsKGMuaWQpOwogICAgICAgICAgICAgICAgYWhrKCdwYXN0
ZScsIFN0cmluZyhjLmlkKSk7CiAgICAgICAgICAgIH0KICAgICAgICB9CiAgICB9OwoKICAgIC8vIEFI
SyBFbnRlciBob3RrZXkgbGFuZHMgaGVyZSAoV2ViVmlldyBtYXkgbm90IHJlY2VpdmUgdGhlIGtleSB3
aGlsZSB1bnBpbm5lZCkKICAgIHdpbmRvdy5fX2VkaXRUaXRsZSA9ICgpID0+IHsKICAgICAgICBsZXQg
YyA9IG51bGw7CiAgICAgICAgaWYgKHNlbGVjdGVkSWQpCiAgICAgICAgICAgIGMgPSBhbGxDbGlwcy5m
aW5kKHggPT4gK3guaWQgPT09ICtzZWxlY3RlZElkKSB8fCBudWxsOwogICAgICAgIGlmICghYyAmJiBj
dHhDbGlwKQogICAgICAgICAgICBjID0gY3R4Q2xpcDsKICAgICAgICBpZiAoIWMpIHsKICAgICAgICAg
ICAgY29uc3QgdmlzID0gdmlzaWJsZUxpc3QoKTsKICAgICAgICAgICAgaWYgKHZpcy5sZW5ndGgpIGMg
PSB2aXNbMF07CiAgICAgICAgfQogICAgICAgIGlmICghYykgcmV0dXJuOwogICAgICAgIG9wZW5UaXRs
ZURsZyhjKTsKICAgIH07CgogICAgd2luZG93Ll9fb25FbnRlciA9ICgpID0+IHsKICAgICAgICBjb25z
dCB0ZCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd0aXRsZS1kbGcnKTsKICAgICAgICBpZiAodGQg
JiYgdGQuY2xhc3NMaXN0LmNvbnRhaW5zKCdvbicpKSB7CiAgICAgICAgICAgIGRvY3VtZW50LmdldEVs
ZW1lbnRCeUlkKCd0aXRsZS1vaycpPy5jbGljaygpOwogICAgICAgICAgICByZXR1cm47CiAgICAgICAg
fQogICAgICAgIGlmIChkb2N1bWVudC5hY3RpdmVFbGVtZW50Py5pZCA9PT0gJ3RpdGxlLWlucHV0Jykg
ewogICAgICAgICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgndGl0bGUtb2snKT8uY2xpY2soKTsK
ICAgICAgICAgICAgcmV0dXJuOwogICAgICAgIH0KICAgICAgICAvLyDlm7rlrprml7blm57ovabkuI3n
spjotLQKICAgICAgICBpZiAocGlubmVkVUkpIHJldHVybjsKICAgICAgICAvLyBUeXBpbmcgaW4gc2Vh
cmNoOiBFbnRlciBzaG91bGQgcGFzdGUgc2VsZWN0ZWQgaXRlbQogICAgICAgIGlmIChkb2N1bWVudC5h
Y3RpdmVFbGVtZW50Py5pZCA9PT0gJ3NlYXJjaCcpIHsKICAgICAgICAgICAgd2luZG93Ll9fbmF2ICYm
IHdpbmRvdy5fX25hdignZW50ZXInKTsKICAgICAgICAgICAgcmV0dXJuOwogICAgICAgIH0KICAgICAg
ICB3aW5kb3cuX19uYXYgJiYgd2luZG93Ll9fbmF2KCdlbnRlcicpOwogICAgfTsKCiAgICB3aW5kb3cu
X19jeWNsZVRhYiA9IGRpciA9PiB7CiAgICAgICAgY29uc3QgaSA9IE1hdGgubWF4KDAsIFRBQl9PUkRF
Ui5pbmRleE9mKGN1clRhYikpOwogICAgICAgIGNvbnN0IG5leHQgPSBUQUJfT1JERVJbKGkgKyAoZGly
IHwgMCkgKyBUQUJfT1JERVIubGVuZ3RoICogMTApICUgVEFCX09SREVSLmxlbmd0aF07CiAgICAgICAg
c2V0VGFiKG5leHQpOwogICAgfTsKICAgIHdpbmRvdy5fX29uUGFuZWxTaG93ID0gKGtlZXBTZWFyY2gp
ID0+IHsKICAgICAgICB3aW5kb3cuX19wZXJmTWFyayAmJiB3aW5kb3cuX19wZXJmTWFyaygnanNfb25Q
YW5lbFNob3cga2VlcFNlYXJjaD0nICsgKCEha2VlcFNlYXJjaCkpOwogICAgICAgIC8vIERvIE5PVCBm
b2N1cyBXZWJWaWV3IOKAlCBrZWVwIGVkaXRvciBjYXJldC9mb2N1cyAoQUhLIGhhbmRsZXMga2V5cyB2
aWEgI0hvdElmKQogICAgICAgIC8vIFdpbitWOiBjb2xsYXBzZSBzZWFyY2guID8/IHNlYXJjaDoga2Vl
cC9vcGVuIHNlYXJjaCBib3guCiAgICAgICAga2VlcFNlYXJjaCA9ICEha2VlcFNlYXJjaDsKICAgICAg
ICB0cnkgeyBoaWRlQ3R4KCk7IH0gY2F0Y2gge30KICAgICAgICB0cnkgeyBjbG9zZVRpdGxlRGxnKCk7
IH0gY2F0Y2gge30KICAgICAgICB0cnkgewogICAgICAgICAgICBjb25zdCB3cmFwID0gZG9jdW1lbnQu
Z2V0RWxlbWVudEJ5SWQoJ3NlYXJjaC13cmFwJyk7CiAgICAgICAgICAgIGNvbnN0IHNyY2ggPSBkb2N1
bWVudC5nZXRFbGVtZW50QnlJZCgnc2VhcmNoJyk7CiAgICAgICAgICAgIGNvbnN0IHNjbHIgPSBkb2N1
bWVudC5nZXRFbGVtZW50QnlJZCgnc2VhcmNoLWNscicpOwogICAgICAgICAgICBpZiAoIWtlZXBTZWFy
Y2gpIHsKICAgICAgICAgICAgICAgIGlmICh3cmFwKSB3cmFwLmNsYXNzTGlzdC5yZW1vdmUoJ29wZW4n
KTsKICAgICAgICAgICAgICAgIGlmIChzcmNoKSB7CiAgICAgICAgICAgICAgICAgICAgc3JjaC52YWx1
ZSA9ICcnOwogICAgICAgICAgICAgICAgICAgIHNyY2guY2xhc3NMaXN0LnJlbW92ZSgnaGFzLXZhbCcp
OwogICAgICAgICAgICAgICAgICAgIHRyeSB7IHNyY2guYmx1cigpOyB9IGNhdGNoIHt9CiAgICAgICAg
ICAgICAgICB9CiAgICAgICAgICAgICAgICBpZiAoc2Nscikgc2Nsci5zdHlsZS5kaXNwbGF5ID0gJ25v
bmUnOwogICAgICAgICAgICAgICAgcXVlcnkgPSAnJzsKICAgICAgICAgICAgICAgIHdpbmRvdy5fX2hv
c3RGaWx0ZXJlZCA9IGZhbHNlOwogICAgICAgICAgICAgICAgd2luZG93Ll9faG9zdEZpbHRlclEgPSAn
JzsKICAgICAgICAgICAgICAgIC8vIFdpbitW77ya56uL5Yi755So5pyq6L+H5ruk57yT5a2Y6ZO65YiX
6KGo77yM6YG/5YWN5YWI6Zeq6L+H5ruk57uT5p6cL+epuuWjs+WGjeetiSBTZXRWaWV3CiAgICAgICAg
ICAgICAgICB0cnkgewogICAgICAgICAgICAgICAgICAgIGNvbnN0IGhpdCA9IHZpZXdNZW0uZ2V0KHZp
ZXdNZW1LZXkoJ2FsbCcsICcnLCBmYWxzZSkpOwogICAgICAgICAgICAgICAgICAgIGlmIChoaXQgJiYg
QXJyYXkuaXNBcnJheShoaXQuaXRlbXMpICYmIGhpdC5pdGVtcy5sZW5ndGgpIHsKICAgICAgICAgICAg
ICAgICAgICAgICAgYWxsQ2xpcHMgPSBoaXQuaXRlbXMuc2xpY2UoKTsKICAgICAgICAgICAgICAgICAg
ICAgICAgZGlza1RvdGFsID0gTnVtYmVyKGhpdC50b3RhbCkgfHwgaGl0Lml0ZW1zLmxlbmd0aDsKICAg
ICAgICAgICAgICAgICAgICAgICAgd2luZG93Ll9fZGF0YVJlYWR5ID0gdHJ1ZTsKICAgICAgICAgICAg
ICAgICAgICAgICAgaG9zdFB1c2hlZE9uY2UgPSB0cnVlOwogICAgICAgICAgICAgICAgICAgICAgICBz
YXdOb25FbXB0eSA9IHRydWU7CiAgICAgICAgICAgICAgICAgICAgICAgIGNsZWFyV2FpdGluZ0RhdGEo
KTsKICAgICAgICAgICAgICAgICAgICB9IGVsc2UgewogICAgICAgICAgICAgICAgICAgICAgICBzY2hl
ZHVsZURlbGF5ZWRTa2VsKCk7CiAgICAgICAgICAgICAgICAgICAgfQogICAgICAgICAgICAgICAgfSBj
YXRjaCB7CiAgICAgICAgICAgICAgICAgICAgc2NoZWR1bGVEZWxheWVkU2tlbCgpOwogICAgICAgICAg
ICAgICAgfQogICAgICAgICAgICB9IGVsc2UgaWYgKHdyYXApIHsKICAgICAgICAgICAgICAgIHdyYXAu
Y2xhc3NMaXN0LmFkZCgnb3BlbicpOwogICAgICAgICAgICAgICAgaWYgKHNyY2ggJiYgc3JjaC52YWx1
ZSkKICAgICAgICAgICAgICAgICAgICBxdWVyeSA9IHNyY2gudmFsdWU7CiAgICAgICAgICAgICAgICAv
LyA/PyDmkJzntKLvvJrlnKjkuLvmnLrov4fmu6Tnu5PmnpzliLDovr7liY3vvIzlhYjmjInlhbPplK7l
rZfmnKzlnLDmu6TvvIznpoHmraLpl6rlh7rjgIzlhajpg6jjgI0KICAgICAgICAgICAgICAgIGlmIChT
dHJpbmcocXVlcnkgfHwgJycpLnRyaW0oKSkgewogICAgICAgICAgICAgICAgICAgIHdpbmRvdy5fX2hv
c3RGaWx0ZXJlZCA9IGZhbHNlOwogICAgICAgICAgICAgICAgICAgIHdpbmRvdy5fX2hvc3RGaWx0ZXJR
ID0gJyc7CiAgICAgICAgICAgICAgICB9CiAgICAgICAgICAgIH0KICAgICAgICAgICAgdG9kYXlPbmx5
ID0gZmFsc2U7CiAgICAgICAgICAgIHRyeSB7CiAgICAgICAgICAgICAgICBjb25zdCBidG5Ub2RheSA9
IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdidG4tdG9kYXknKTsKICAgICAgICAgICAgICAgIGlmIChi
dG5Ub2RheSkgYnRuVG9kYXkuY2xhc3NMaXN0LnJlbW92ZSgnb24nKTsKICAgICAgICAgICAgfSBjYXRj
aCB7fQogICAgICAgICAgICBjdXJUYWIgPSAnYWxsJzsKICAgICAgICAgICAgbG9hZGluZ01vcmUgPSBm
YWxzZTsKICAgICAgICAgICAgbWFya1RhYignYWxsJyk7CiAgICAgICAgICAgIC8vIOS4jeimgSBhaGso
J2JsdXJQYW5lbCcp77ya5Lya6LefIFNob3dQYW5lbCDmiqLnhKbngrnvvIxXaW4rVi8/PyDpg73lrrnm
mJPpl6rjgIHkubHot7MKICAgICAgICAgICAgcmVuZGVyKCk7CiAgICAgICAgICAgIC8vIOWQjOatpeW9
k+WJjSB0YWIvcXVlcnkg5YiwIEFIS++8iD8/IOabvuWPqueUqCB2aWV3VGFiIOaQnOmUmemhte+8iQog
ICAgICAgICAgICByZXF1ZXN0VmlldygpOwogICAgICAgIH0gY2F0Y2gge30KICAgICAgICBzZWxlY3RG
aXJzdE9uU2hvdyA9IHRydWU7CiAgICAgICAgbG9jYXRlQWN0aXZlID0gZmFsc2U7CiAgICAgICAgdXBk
YXRlTG9jYXRlQnRuKCk7CiAgICAgICAgY2xlYXJNdWx0aSgpOwogICAgICAgIGNvbnN0IHZpcyA9IHZp
c2libGVMaXN0KCk7CiAgICAgICAgaWYgKHZpcy5sZW5ndGgpIHsKICAgICAgICAgICAgc2VsZWN0ZWRJ
ZCA9IHZpc1swXS5pZDsKICAgICAgICAgICAgcmFuZ2VBbmNob3JJZCA9IHNlbGVjdGVkSWQ7CiAgICAg
ICAgICAgIHJhbmdlQW5jaG9yQ2xpY2tlZCA9IGZhbHNlOwogICAgICAgICAgICBsaXN0RWwuc2Nyb2xs
VG9wID0gMDsKICAgICAgICB9CiAgICAgICAgc3luY0l0ZW1IaWdobGlnaHQoKTsKICAgIH07CgogICAg
ZnVuY3Rpb24gY3R4QmluZChpZCwgZm4pIHsKICAgICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZChp
ZCkuYWRkRXZlbnRMaXN0ZW5lcignY2xpY2snLCBlID0+IHsKICAgICAgICAgICAgZS5zdG9wUHJvcGFn
YXRpb24oKTsKICAgICAgICAgICAgaWYgKGN0eENsaXApIGZuKGN0eENsaXApOwogICAgICAgICAgICBo
aWRlQ3R4KCk7CiAgICAgICAgfSk7CiAgICB9CiAgICBjdHhCaW5kKCdjLWNvcHknLCAgYyA9PiB7CiAg
ICAgICAgaWYgKG5vcm1UeXBlKGMudHlwZSkgPT09ICdyZWNlbnQnKQogICAgICAgICAgICBhaGsoJ2Nv
cHlQYXRoJywgU3RyaW5nKGMuZGF0YSB8fCBjLnByZXZpZXcgfHwgJycpKTsKICAgICAgICBlbHNlCiAg
ICAgICAgICAgIGFoaygnY29weUJ5SWQnLCBTdHJpbmcoYy5pZCkpOwogICAgfSk7CiAgICBjdHhCaW5k
KCdjLXBhc3RlJywgYyA9PiB7CiAgICAgICAgYWN0aXZhdGVDbGlwSXRlbShjKTsKICAgIH0pOwogICAg
Y3R4QmluZCgnYy1waW4nLCAgIGMgPT4gewogICAgICAgIC8vIE9wdGltaXN0aWMgZmxpcCDigJQg5Zu6
5a6a5Y+q6Ziy5reY5rGw77yM5LiN572u6aG277yb5YaN5qyh6K6/6Zeu5omN6Z2gIFJlY29yZCDpobbl
iLDkuIrpnaIKICAgICAgICBjb25zdCBuZXh0ID0gIWlzUGlubmVkKGMpOwogICAgICAgIGMucGlubmVk
ID0gbmV4dDsKICAgICAgICBjb25zdCBpZCA9ICtjLmlkOwogICAgICAgIGZvciAoY29uc3QgeCBvZiBh
bGxDbGlwcykgewogICAgICAgICAgICBpZiAoK3guaWQgPT09IGlkKSB4LnBpbm5lZCA9IG5leHQ7CiAg
ICAgICAgfQogICAgICAgIHJlbmRlcigpOwogICAgICAgIGFoaygncGluJywgU3RyaW5nKGMuaWQpKTsK
ICAgIH0pOwogICAgY3R4QmluZCgnYy10b3AnLCAgIGMgPT4gYWhrKCdtb3ZlVG9Ub3AnLCAgICAgU3Ry
aW5nKGMuaWQpKSk7CiAgICBjdHhCaW5kKCdjLWNsZWFyLXBhc3RlZCcsIGMgPT4gYWhrKCdjbGVhclBh
c3RlZCcsIFN0cmluZyhjLmlkKSkpOwogICAgY3R4QmluZCgnYy1xdWV1ZS1mcm9tJywgYyA9PiB7CiAg
ICAgICAgYWhrKCdyZXNldFF1ZXVlRnJvbScsIFN0cmluZyhjLmlkKSk7CiAgICAgICAgaWYgKCFwaW5u
ZWRVSSkgYWhrKCdoaWRlJyk7CiAgICB9KTsKICAgIGN0eEJpbmQoJ2MtZGVsJywgICBjID0+IHsKICAg
ICAgICAvLyDlpJrpgInkuJTlj7PplK7ngrnlnKjpgInkuK3pobnkuIog4oaSIOaJuemHj+WIoOmZpO+8
m+WQpuWImeWPquWIoOW9k+WJjQogICAgICAgIGxldCBpZHMgPSBbXTsKICAgICAgICBpZiAobXVsdGlJ
ZHMubGVuZ3RoID4gMSAmJiBtdWx0aUlkcy5pbmNsdWRlcygrYy5pZCkpCiAgICAgICAgICAgIGlkcyA9
IG11bHRpSWRzLnNsaWNlKCk7CiAgICAgICAgZWxzZQogICAgICAgICAgICBpZHMgPSBbK2MuaWRdOwog
ICAgICAgIGlkcyA9IGlkcy5tYXAoeCA9PiAreCkuZmlsdGVyKHggPT4geCA+IDApOwogICAgICAgIGlm
ICghaWRzLmxlbmd0aCkgcmV0dXJuOwogICAgICAgIHRyeSB7CiAgICAgICAgICAgIGNvbnN0IGlkU2V0
ID0gbmV3IFNldChpZHMpOwogICAgICAgICAgICBhbGxDbGlwcyA9IGFsbENsaXBzLmZpbHRlcih4ID0+
ICFpZFNldC5oYXMoK3guaWQpKTsKICAgICAgICAgICAgZGlza1RvdGFsID0gTWF0aC5tYXgoMCwgKE51
bWJlcihkaXNrVG90YWwpIHx8IDApIC0gaWRzLmxlbmd0aCk7CiAgICAgICAgICAgIGlmIChpZFNldC5o
YXMoK3NlbGVjdGVkSWQpKQogICAgICAgICAgICAgICAgc2VsZWN0ZWRJZCA9IGFsbENsaXBzLmxlbmd0
aCA/IGFsbENsaXBzWzBdLmlkIDogMDsKICAgICAgICAgICAgY2xlYXJNdWx0aSgpOwogICAgICAgICAg
ICByZW5kZXIoKTsKICAgICAgICB9IGNhdGNoIHt9CiAgICAgICAgaWYgKGlkcy5sZW5ndGggPT09IDEp
CiAgICAgICAgICAgIGFoaygnZGVsZXRlJywgU3RyaW5nKGlkc1swXSkpOwogICAgICAgIGVsc2UKICAg
ICAgICAgICAgYWhrKCdkZWxldGVNYW55JywgaWRzLmpvaW4oJywnKSk7CiAgICB9KTsKICAgIGN0eEJp
bmQoJ2MtdGl0bGUnLCBjID0+IG9wZW5UaXRsZURsZyhjKSk7CiAgICBjdHhCaW5kKCdjLW1lcmdlJywg
YyA9PiB7CiAgICAgICAgY29uc3QgaWRzID0gKG11bHRpSWRzLmxlbmd0aCA+PSAyKSA/IG11bHRpSWRz
LnNsaWNlKCkgOiBbXTsKICAgICAgICBpZiAoaWRzLmxlbmd0aCA8IDIpIHJldHVybjsKICAgICAgICBp
ZiAoIWlkcy5pbmNsdWRlcygrYy5pZCkpIGlkcy5wdXNoKCtjLmlkKTsKICAgICAgICBhaGsoJ21lcmdl
RmF2JywgaWRzLmpvaW4oJywnKSk7CiAgICAgICAgY2xlYXJNdWx0aSgpOwogICAgfSk7CiAgICBjdHhC
aW5kKCdjLXVubWVyZ2UnLCBjID0+IHsKICAgICAgICBhaGsoJ3VubWVyZ2VGYXYnLCBTdHJpbmcoYy5p
ZCkpOwogICAgICAgIGNsZWFyTXVsdGkoKTsKICAgIH0pOwoKICAgIGNvbnN0IHRpdGxlRGxnID0gZG9j
dW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3RpdGxlLWRsZycpOwogICAgY29uc3QgdGl0bGVJbnB1dCA9IGRv
Y3VtZW50LmdldEVsZW1lbnRCeUlkKCd0aXRsZS1pbnB1dCcpOwogICAgbGV0IHRpdGxlRGxnQ2xpcCA9
IG51bGw7CiAgICBmdW5jdGlvbiBjbG9zZVRpdGxlRGxnKCkgewogICAgICAgIGlmICh0aXRsZURsZykg
dGl0bGVEbGcuY2xhc3NMaXN0LnJlbW92ZSgnb24nKTsKICAgICAgICB0aXRsZURsZ0NsaXAgPSBudWxs
OwogICAgfQogICAgZnVuY3Rpb24gb3BlblRpdGxlRGxnKGMpIHsKICAgICAgICBoaWRlQ3R4KCk7CiAg
ICAgICAgdGl0bGVEbGdDbGlwID0gYzsKICAgICAgICBpZiAodGl0bGVJbnB1dCkgdGl0bGVJbnB1dC52
YWx1ZSA9IFN0cmluZyhjLmZhdlRpdGxlIHx8ICcnKS50cmltKCk7CiAgICAgICAgaWYgKHRpdGxlRGxn
KSB0aXRsZURsZy5jbGFzc0xpc3QuYWRkKCdvbicpOwogICAgICAgIGFoaygnZm9jdXNQYW5lbCcpOwog
ICAgICAgIHJlcXVlc3RBbmltYXRpb25GcmFtZSgoKSA9PiB7CiAgICAgICAgICAgIHRyeSB7IHRpdGxl
SW5wdXQuZm9jdXMoKTsgdGl0bGVJbnB1dC5zZWxlY3QoKTsgfSBjYXRjaCB7fQogICAgICAgIH0pOwog
ICAgfQogICAgaWYgKHRpdGxlRGxnKSB7CiAgICAgICAgdGl0bGVEbGcuYWRkRXZlbnRMaXN0ZW5lcign
Y2xpY2snLCBlID0+IHsKICAgICAgICAgICAgaWYgKGUudGFyZ2V0ID09PSB0aXRsZURsZykgY2xvc2VU
aXRsZURsZygpOwogICAgICAgIH0pOwogICAgfQogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3Rp
dGxlLWNhbmNlbCcpPy5hZGRFdmVudExpc3RlbmVyKCdjbGljaycsIGUgPT4gewogICAgICAgIGUuc3Rv
cFByb3BhZ2F0aW9uKCk7CiAgICAgICAgY2xvc2VUaXRsZURsZygpOwogICAgICAgIGFoaygnYmx1clBh
bmVsJyk7CiAgICB9KTsKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd0aXRsZS1vaycpPy5hZGRF
dmVudExpc3RlbmVyKCdjbGljaycsIGUgPT4gewogICAgICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAg
ICAgICAgaWYgKCF0aXRsZURsZ0NsaXApIHJldHVybjsKICAgICAgICBjb25zdCB0ID0gU3RyaW5nKHRp
dGxlSW5wdXQ/LnZhbHVlIHx8ICcnKS50cmltKCkuc2xpY2UoMCwgODApOwogICAgICAgIGNvbnN0IGlk
ID0gU3RyaW5nKHRpdGxlRGxnQ2xpcC5pZCk7CiAgICAgICAgLy8gT3B0aW1pc3RpYyBsb2NhbCB1cGRh
dGUKICAgICAgICBjb25zdCBoaXQgPSBhbGxDbGlwcy5maW5kKHggPT4gK3guaWQgPT09ICtpZCk7CiAg
ICAgICAgaWYgKGhpdCkgaGl0LmZhdlRpdGxlID0gdDsKICAgICAgICB0aXRsZURsZ0NsaXAuZmF2VGl0
bGUgPSB0OwogICAgICAgIGNsb3NlVGl0bGVEbGcoKTsKICAgICAgICBhaGsoJ3NldEZhdlRpdGxlJywg
aWQsIHQpOwogICAgICAgIGFoaygnYmx1clBhbmVsJyk7CiAgICAgICAgcmVuZGVyKCk7CiAgICB9KTsK
ICAgIHRpdGxlSW5wdXQ/LmFkZEV2ZW50TGlzdGVuZXIoJ2tleWRvd24nLCBlID0+IHsKICAgICAgICBp
ZiAoZS5rZXkgPT09ICdFbnRlcicpIHsKICAgICAgICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOwogICAg
ICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgICAgICAgICBlLnN0b3BJbW1lZGlhdGVQcm9w
YWdhdGlvbigpOwogICAgICAgICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgndGl0bGUtb2snKT8u
Y2xpY2soKTsKICAgICAgICAgICAgcmV0dXJuOwogICAgICAgIH0KICAgICAgICBpZiAoZS5rZXkgPT09
ICdFc2NhcGUnKSB7CiAgICAgICAgICAgIGUucHJldmVudERlZmF1bHQoKTsKICAgICAgICAgICAgZS5z
dG9wUHJvcGFnYXRpb24oKTsKICAgICAgICAgICAgY2xvc2VUaXRsZURsZygpOwogICAgICAgICAgICBh
aGsoJ2JsdXJQYW5lbCcpOwogICAgICAgICAgICByZXR1cm47CiAgICAgICAgfQogICAgICAgIGUuc3Rv
cFByb3BhZ2F0aW9uKCk7CiAgICB9LCB0cnVlKTsKCiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgn
dGFicycpLmFkZEV2ZW50TGlzdGVuZXIoJ2NsaWNrJywgZSA9PiB7CiAgICAgICAgY29uc3QgdGFiID0g
ZS50YXJnZXQuY2xvc2VzdCgnLnRhYicpOwogICAgICAgIGlmICghdGFiIHx8IGUudGFyZ2V0LmNsb3Nl
c3QoJyN0YWItYWN0aW9ucycpKSByZXR1cm47CiAgICAgICAgc2V0VGFiKHRhYi5kYXRhc2V0LnRhYik7
CiAgICB9KTsKCiAgICBjb25zdCBzcmNoV3JhcCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzZWFy
Y2gtd3JhcCcpOwogICAgY29uc3QgYnRuU2VhcmNoID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2J0
bi1zZWFyY2gnKTsKICAgIGNvbnN0IGJ0bkxvY2F0ZSA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdi
dG4tbG9jYXRlJyk7CiAgICBjb25zdCBidG5Ub2RheSA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdi
dG4tdG9kYXknKTsKICAgIGNvbnN0IHNyY2ggPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc2VhcmNo
Jyk7CiAgICBjb25zdCBzY2xyID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NlYXJjaC1jbHInKTsK
ICAgIGxldCBkZWI7CgogICAgdXBkYXRlTG9jYXRlQnRuKCk7CiAgICBpZiAoYnRuTG9jYXRlKSB7CiAg
ICAgICAgYnRuTG9jYXRlLmFkZEV2ZW50TGlzdGVuZXIoJ2NsaWNrJywgZSA9PiB7CiAgICAgICAgICAg
IGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAgICAgICAgIGp1bXBUb0xhc3RQYXN0ZSgpOwogICAgICAg
IH0pOwogICAgfQoKICAgIGJ0blRvZGF5LmFkZEV2ZW50TGlzdGVuZXIoJ21vdXNlZG93bicsIGUgPT4g
ewogICAgICAgIGUucHJldmVudERlZmF1bHQoKTsKICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwog
ICAgfSk7CiAgICBidG5Ub2RheS5hZGRFdmVudExpc3RlbmVyKCdjbGljaycsIGUgPT4gewogICAgICAg
IGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOwogICAgICAgIHRv
ZGF5T25seSA9ICF0b2RheU9ubHk7CiAgICAgICAgYnRuVG9kYXkuY2xhc3NMaXN0LnRvZ2dsZSgnb24n
LCB0b2RheU9ubHkpOwogICAgICAgIGxpc3RFbC5zY3JvbGxUb3AgPSAwOwogICAgICAgIHJlcXVlc3RW
aWV3KCk7CiAgICAgICAgdHJ5IHsgc3JjaC5mb2N1cygpOyB9IGNhdGNoIHt9CiAgICB9KTsKCiAgICBm
dW5jdGlvbiBvcGVuU2VhcmNoKCkgewogICAgICAgIGlmIChzcmNoV3JhcC5jbGFzc0xpc3QuY29udGFp
bnMoJ29wZW4nKSkgewogICAgICAgICAgICBhaGsoJ2ZvY3VzUGFuZWwnKTsKICAgICAgICAgICAgdHJ5
IHsgc3JjaC5mb2N1cygpOyB9IGNhdGNoIHt9CiAgICAgICAgICAgIHJldHVybjsKICAgICAgICB9CiAg
ICAgICAgc3JjaFdyYXAuY2xhc3NMaXN0LmFkZCgnb3BlbicpOwogICAgICAgIC8vIERlZmF1bHQ6IOaJ
gOaciemhteaJk+W8gOaQnOe0ouaXtum7mOiupOaQnOWFqOmDqAogICAgICAgIGNvbnN0IHdhbnRUb2Rh
eSA9IGZhbHNlOwogICAgICAgIGlmICh0b2RheU9ubHkgIT09IHdhbnRUb2RheSkgewogICAgICAgICAg
ICB0b2RheU9ubHkgPSB3YW50VG9kYXk7CiAgICAgICAgICAgIGJ0blRvZGF5LmNsYXNzTGlzdC50b2dn
bGUoJ29uJywgdG9kYXlPbmx5KTsKICAgICAgICAgICAgbGlzdEVsLnNjcm9sbFRvcCA9IDA7CiAgICAg
ICAgICAgIHJlcXVlc3RWaWV3KCk7CiAgICAgICAgfSBlbHNlIHsKICAgICAgICAgICAgYnRuVG9kYXku
Y2xhc3NMaXN0LnRvZ2dsZSgnb24nLCB0b2RheU9ubHkpOwogICAgICAgIH0KICAgICAgICBhaGsoJ2Zv
Y3VzUGFuZWwnKTsKICAgICAgICByZXF1ZXN0QW5pbWF0aW9uRnJhbWUoKCkgPT4gewogICAgICAgICAg
ICB0cnkgeyBzcmNoLmZvY3VzKCk7IH0gY2F0Y2gge30KICAgICAgICB9KTsKICAgIH0KICAgIGZ1bmN0
aW9uIGNsb3NlU2VhcmNoVWkoKSB7CiAgICAgICAgc3JjaFdyYXAuY2xhc3NMaXN0LnJlbW92ZSgnb3Bl
bicpOwogICAgICAgIGlmICghc3JjaC52YWx1ZSkgewogICAgICAgICAgICBzcmNoLmNsYXNzTGlzdC5y
ZW1vdmUoJ2hhcy12YWwnKTsKICAgICAgICAgICAgc2Nsci5zdHlsZS5kaXNwbGF5ID0gJ25vbmUnOwog
ICAgICAgICAgICAvLyBMZWF2aW5nIHNlYXJjaCB3aXRoIGVtcHR5IHF1ZXJ5IOKGkiBkcm9wIHRvZGF5
IGZpbHRlcgogICAgICAgICAgICBpZiAodG9kYXlPbmx5KSB7CiAgICAgICAgICAgICAgICB0b2RheU9u
bHkgPSBmYWxzZTsKICAgICAgICAgICAgICAgIGJ0blRvZGF5LmNsYXNzTGlzdC5yZW1vdmUoJ29uJyk7
CiAgICAgICAgICAgICAgICByZXF1ZXN0VmlldygpOwogICAgICAgICAgICB9CiAgICAgICAgfQogICAg
fQogICAgd2luZG93Ll9fb3BlblNlYXJjaCA9IG9wZW5TZWFyY2g7CiAgICB3aW5kb3cuX19wcmVwVHlw
ZVNlYXJjaCA9ICgpID0+IHsKICAgICAgICB0cnkgewogICAgICAgICAgICBjb25zdCB3cmFwID0gZG9j
dW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NlYXJjaC13cmFwJyk7CiAgICAgICAgICAgIGNvbnN0IHMgPSBk
b2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc2VhcmNoJyk7CiAgICAgICAgICAgIGlmICh3cmFwICYmICF3
cmFwLmNsYXNzTGlzdC5jb250YWlucygnb3BlbicpKSB7CiAgICAgICAgICAgICAgICB3cmFwLmNsYXNz
TGlzdC5hZGQoJ29wZW4nKTsKICAgICAgICAgICAgICAgIHRyeSB7CiAgICAgICAgICAgICAgICAgICAg
Y29uc3Qgd2FudFRvZGF5ID0gZmFsc2U7CiAgICAgICAgICAgICAgICAgICAgaWYgKHR5cGVvZiB0b2Rh
eU9ubHkgIT09ICd1bmRlZmluZWQnICYmIHRvZGF5T25seSAhPT0gd2FudFRvZGF5KSB7CiAgICAgICAg
ICAgICAgICAgICAgICAgIHRvZGF5T25seSA9IHdhbnRUb2RheTsKICAgICAgICAgICAgICAgICAgICAg
ICAgaWYgKHR5cGVvZiBidG5Ub2RheSAhPT0gJ3VuZGVmaW5lZCcgJiYgYnRuVG9kYXkpIGJ0blRvZGF5
LmNsYXNzTGlzdC50b2dnbGUoJ29uJywgdG9kYXlPbmx5KTsKICAgICAgICAgICAgICAgICAgICAgICAg
aWYgKHR5cGVvZiBsaXN0RWwgIT09ICd1bmRlZmluZWQnICYmIGxpc3RFbCkgbGlzdEVsLnNjcm9sbFRv
cCA9IDA7CiAgICAgICAgICAgICAgICAgICAgICAgIGlmICh0eXBlb2YgcmVxdWVzdFZpZXcgPT09ICdm
dW5jdGlvbicpIHNldFRpbWVvdXQocmVxdWVzdFZpZXcsIDApOwogICAgICAgICAgICAgICAgICAgIH0g
ZWxzZSBpZiAodHlwZW9mIGJ0blRvZGF5ICE9PSAndW5kZWZpbmVkJyAmJiBidG5Ub2RheSkgewogICAg
ICAgICAgICAgICAgICAgICAgICBidG5Ub2RheS5jbGFzc0xpc3QudG9nZ2xlKCdvbicsICEhdG9kYXlP
bmx5KTsKICAgICAgICAgICAgICAgICAgICB9CiAgICAgICAgICAgICAgICB9IGNhdGNoIHt9CiAgICAg
ICAgICAgIH0KICAgICAgICAgICAgLy8gPz8g6ZWc5YOP5pCc57Si77ya5LiN6KaBIGZvY3Vz77yM6YG/
5YWN5oqi6LWw5Y6f57yW6L6R5qGG5YWJ5qCHCiAgICAgICAgfSBjYXRjaCB7fQogICAgfTsKICAgIHdp
bmRvdy5fX3R5cGVTZWFyY2ggPSAoY2gpID0+IHsKICAgICAgICB0cnkgewogICAgICAgICAgICB3aW5k
b3cuX19wcmVwVHlwZVNlYXJjaCAmJiB3aW5kb3cuX19wcmVwVHlwZVNlYXJjaCgpOwogICAgICAgICAg
ICBjb25zdCBzID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NlYXJjaCcpOwogICAgICAgICAgICBp
ZiAoIXMpIHJldHVybjsKICAgICAgICAgICAgcy52YWx1ZSA9IFN0cmluZyhzLnZhbHVlIHx8ICcnKSAr
IFN0cmluZyhjaCA9PSBudWxsID8gJycgOiBjaCk7CiAgICAgICAgICAgIHMuY2xhc3NMaXN0LnRvZ2ds
ZSgnaGFzLXZhbCcsICEhcy52YWx1ZSk7CiAgICAgICAgICAgIHMuZGlzcGF0Y2hFdmVudChuZXcgRXZl
bnQoJ2lucHV0JywgeyBidWJibGVzOiB0cnVlIH0pKTsKICAgICAgICB9IGNhdGNoIHt9CiAgICB9Owog
ICAgd2luZG93Ll9fYmtzcFNlYXJjaCA9ICgpID0+IHsKICAgICAgICB0cnkgewogICAgICAgICAgICB3
aW5kb3cuX19wcmVwVHlwZVNlYXJjaCAmJiB3aW5kb3cuX19wcmVwVHlwZVNlYXJjaCgpOwogICAgICAg
ICAgICBjb25zdCBzID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NlYXJjaCcpOwogICAgICAgICAg
ICBpZiAoIXMpIHJldHVybjsKICAgICAgICAgICAgY29uc3QgdiA9IFN0cmluZyhzLnZhbHVlIHx8ICcn
KTsKICAgICAgICAgICAgcy52YWx1ZSA9IHYubGVuZ3RoID8gdi5zbGljZSgwLCAtMSkgOiAnJzsKICAg
ICAgICAgICAgcy5jbGFzc0xpc3QudG9nZ2xlKCdoYXMtdmFsJywgISFzLnZhbHVlKTsKICAgICAgICAg
ICAgcy5kaXNwYXRjaEV2ZW50KG5ldyBFdmVudCgnaW5wdXQnLCB7IGJ1YmJsZXM6IHRydWUgfSkpOwog
ICAgICAgIH0gY2F0Y2gge30KICAgIH07CiAgICB3aW5kb3cuX19zZXRTZWFyY2hRdWVyeSA9IChxKSA9
PiB7CiAgICAgICAgdHJ5IHsKICAgICAgICAgICAgY29uc3QgcyA9IGRvY3VtZW50LmdldEVsZW1lbnRC
eUlkKCdzZWFyY2gnKTsKICAgICAgICAgICAgaWYgKCFzKSByZXR1cm47CiAgICAgICAgICAgIGNvbnN0
IG5leHQgPSBTdHJpbmcocSA9PSBudWxsID8gJycgOiBxKTsKICAgICAgICAgICAgY29uc3QgcHJldiA9
IFN0cmluZyhzLnZhbHVlIHx8ICcnKTsKICAgICAgICAgICAgLy8g5ZCM5YWz6ZSu5a2X6YeN5aSN5o6o
6YCB77ya5Y+q5L+d6K+B5pCc57Si5qGG5byA552A77yM56aB5q2i5YaNIHJlcXVlc3RWaWV377yI5Lya
5q275b6q546v6Zeq77yJCiAgICAgICAgICAgIGlmIChwcmV2ID09PSBuZXh0ICYmIFN0cmluZyhxdWVy
eSB8fCAnJykgPT09IG5leHQpIHsKICAgICAgICAgICAgICAgIHRyeSB7CiAgICAgICAgICAgICAgICAg
ICAgY29uc3Qgd3JhcCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzZWFyY2gtd3JhcCcpOwogICAg
ICAgICAgICAgICAgICAgIGlmICh3cmFwICYmICF3cmFwLmNsYXNzTGlzdC5jb250YWlucygnb3Blbicp
KQogICAgICAgICAgICAgICAgICAgICAgICB3cmFwLmNsYXNzTGlzdC5hZGQoJ29wZW4nKTsKICAgICAg
ICAgICAgICAgIH0gY2F0Y2gge30KICAgICAgICAgICAgICAgIHJldHVybjsKICAgICAgICAgICAgfQog
ICAgICAgICAgICAvLyDmiZPlrZfljbPml7bkuIrlsY/vvIzkuI7no4Hnm5jmkJzntKLop6PogKYKICAg
ICAgICAgICAgcy52YWx1ZSA9IG5leHQ7CiAgICAgICAgICAgIHMuY2xhc3NMaXN0LnRvZ2dsZSgnaGFz
LXZhbCcsICEhcy52YWx1ZSk7CiAgICAgICAgICAgIGNvbnN0IHNjbHIgPSBkb2N1bWVudC5nZXRFbGVt
ZW50QnlJZCgnc2VhcmNoLWNscicpOwogICAgICAgICAgICBpZiAoc2Nscikgc2Nsci5zdHlsZS5kaXNw
bGF5ID0gcy52YWx1ZSA/ICdibG9jaycgOiAnbm9uZSc7CiAgICAgICAgICAgIHF1ZXJ5ID0gcy52YWx1
ZTsKICAgICAgICAgICAgdHJ5IHsKICAgICAgICAgICAgICAgIGNvbnN0IHdyYXAgPSBkb2N1bWVudC5n
ZXRFbGVtZW50QnlJZCgnc2VhcmNoLXdyYXAnKTsKICAgICAgICAgICAgICAgIGlmICh3cmFwICYmICF3
cmFwLmNsYXNzTGlzdC5jb250YWlucygnb3BlbicpKQogICAgICAgICAgICAgICAgICAgIHdpbmRvdy5f
X3ByZXBUeXBlU2VhcmNoICYmIHdpbmRvdy5fX3ByZXBUeXBlU2VhcmNoKCk7CiAgICAgICAgICAgICAg
ICBlbHNlIGlmICh3cmFwKQogICAgICAgICAgICAgICAgICAgIHdyYXAuY2xhc3NMaXN0LmFkZCgnb3Bl
bicpOwogICAgICAgICAgICB9IGNhdGNoIHt9CiAgICAgICAgICAgIHdpbmRvdy5fX2hvc3RGaWx0ZXJl
ZCA9IGZhbHNlOwogICAgICAgICAgICB3aW5kb3cuX19ob3N0RmlsdGVyUSA9ICcnOwogICAgICAgICAg
ICBpZiAoU3RyaW5nKHF1ZXJ5IHx8ICcnKS50cmltKCkpIHsKICAgICAgICAgICAgICAgIHdhaXRpbmdE
YXRhID0gdHJ1ZTsKICAgICAgICAgICAgICAgIHdpbmRvdy5fX2RhdGFSZWFkeSA9IGZhbHNlOwogICAg
ICAgICAgICB9CiAgICAgICAgICAgIHRyeSB7CiAgICAgICAgICAgICAgICBjb25zdCBjbnQgPSBkb2N1
bWVudC5nZXRFbGVtZW50QnlJZCgnYmFyLXR4dCcpOwogICAgICAgICAgICAgICAgaWYgKGNudCAmJiBT
dHJpbmcocXVlcnkgfHwgJycpLnRyaW0oKSkKICAgICAgICAgICAgICAgICAgICBjbnQudGV4dENvbnRl
bnQgPSB2aXNpYmxlTGlzdCgpLmxlbmd0aCArICcg5p2hJzsKICAgICAgICAgICAgfSBjYXRjaCB7fQog
ICAgICAgICAgICB0cnkgeyByZW5kZXIoKTsgfSBjYXRjaCB7fQogICAgICAgICAgICBjbGVhclRpbWVv
dXQod2luZG93Ll9fcXFWaWV3RGViKTsKICAgICAgICAgICAgd2luZG93Ll9fcXFWaWV3RGViID0gc2V0
VGltZW91dCgoKSA9PiB7CiAgICAgICAgICAgICAgICB3aW5kb3cuX19xcVZpZXdEZWIgPSAwOwogICAg
ICAgICAgICAgICAgcmVxdWVzdFZpZXcoKTsKICAgICAgICAgICAgfSwgNzApOwogICAgICAgIH0gY2F0
Y2gge30KICAgIH07CiAgICB3aW5kb3cuX19jbGVhclFRU2VhcmNoID0gKCkgPT4gewogICAgICAgIHRy
eSB7CiAgICAgICAgICAgIHF1ZXJ5ID0gJyc7CiAgICAgICAgICAgIHdpbmRvdy5fX2hvc3RGaWx0ZXJl
ZCA9IGZhbHNlOwogICAgICAgICAgICB3aW5kb3cuX19ob3N0RmlsdGVyUSA9ICcnOwogICAgICAgICAg
ICBjb25zdCBzID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NlYXJjaCcpOwogICAgICAgICAgICBp
ZiAocykgewogICAgICAgICAgICAgICAgcy52YWx1ZSA9ICcnOwogICAgICAgICAgICAgICAgcy5jbGFz
c0xpc3QucmVtb3ZlKCdoYXMtdmFsJyk7CiAgICAgICAgICAgICAgICB0cnkgeyBzLmJsdXIoKTsgfSBj
YXRjaCB7fQogICAgICAgICAgICB9CiAgICAgICAgICAgIGNvbnN0IHNjbHIgPSBkb2N1bWVudC5nZXRF
bGVtZW50QnlJZCgnc2VhcmNoLWNscicpOwogICAgICAgICAgICBpZiAoc2Nscikgc2Nsci5zdHlsZS5k
aXNwbGF5ID0gJ25vbmUnOwogICAgICAgICAgICBjb25zdCB3cmFwID0gZG9jdW1lbnQuZ2V0RWxlbWVu
dEJ5SWQoJ3NlYXJjaC13cmFwJyk7CiAgICAgICAgICAgIGlmICh3cmFwKSB3cmFwLmNsYXNzTGlzdC5y
ZW1vdmUoJ29wZW4nKTsKICAgICAgICAgICAgdHJ5IHsgcmVuZGVyKCk7IH0gY2F0Y2gge30KICAgICAg
ICB9IGNhdGNoIHt9CiAgICB9OwogICAgLy8gQ2FwdHVyZSBDdHJsK0YgaW5zaWRlIFdlYlZpZXcgKENo
cm9taXVtIGZpbmQgaXMgZGlzYWJsZWQsIGJ1dCBzdGlsbCBoYW5kbGUgaGVyZSkKICAgIGRvY3VtZW50
LmFkZEV2ZW50TGlzdGVuZXIoJ2tleWRvd24nLCBlID0+IHsKICAgICAgICBpZiAoKGUuY3RybEtleSB8
fCBlLm1ldGFLZXkpICYmICFlLmFsdEtleSAmJiAoZS5rZXkgPT09ICdmJyB8fCBlLmtleSA9PT0gJ0Yn
KSkgewogICAgICAgICAgICBlLnByZXZlbnREZWZhdWx0KCk7CiAgICAgICAgICAgIGUuc3RvcFByb3Bh
Z2F0aW9uKCk7CiAgICAgICAgICAgIG9wZW5TZWFyY2goKTsKICAgICAgICB9CiAgICB9LCB0cnVlKTsK
ICAgIGJ0blNlYXJjaC5hZGRFdmVudExpc3RlbmVyKCdjbGljaycsIGUgPT4gewogICAgICAgIGUuc3Rv
cFByb3BhZ2F0aW9uKCk7CiAgICAgICAgb3BlblNlYXJjaCgpOwogICAgfSk7CiAgICBsZXQgX19zcmNo
Q29tcG9zaW5nID0gZmFsc2U7CiAgICBjb25zdCBfX2ZsdXNoU2VhcmNoSW5wdXQgPSAoKSA9PiB7CiAg
ICAgICAgcXVlcnkgPSBzcmNoLnZhbHVlOwogICAgICAgIHNyY2guY2xhc3NMaXN0LnRvZ2dsZSgnaGFz
LXZhbCcsICEhcXVlcnkpOwogICAgICAgIHNjbHIuc3R5bGUuZGlzcGxheSA9IHF1ZXJ5ID8gJ2Jsb2Nr
JyA6ICdub25lJzsKICAgICAgICBsaXN0RWwuc2Nyb2xsVG9wID0gMDsKICAgICAgICB3aW5kb3cuX19o
b3N0RmlsdGVyZWQgPSBmYWxzZTsKICAgICAgICB3aW5kb3cuX19ob3N0RmlsdGVyUSA9ICcnOwogICAg
ICAgIHRyeSB7IHJlbmRlcigpOyB9IGNhdGNoIHt9CiAgICAgICAgY2xlYXJUaW1lb3V0KGRlYik7CiAg
ICAgICAgZGViID0gc2V0VGltZW91dChyZXF1ZXN0VmlldywgODApOwogICAgfTsKICAgIHNyY2guYWRk
RXZlbnRMaXN0ZW5lcignY29tcG9zaXRpb25zdGFydCcsICgpID0+IHsgX19zcmNoQ29tcG9zaW5nID0g
dHJ1ZTsgfSk7CiAgICBzcmNoLmFkZEV2ZW50TGlzdGVuZXIoJ2NvbXBvc2l0aW9uZW5kJywgKCkgPT4g
ewogICAgICAgIF9fc3JjaENvbXBvc2luZyA9IGZhbHNlOwogICAgICAgIF9fZmx1c2hTZWFyY2hJbnB1
dCgpOwogICAgfSk7CiAgICBzcmNoLmFkZEV2ZW50TGlzdGVuZXIoJ2lucHV0JywgKCkgPT4gewogICAg
ICAgIGlmIChfX3NyY2hDb21wb3NpbmcpIHsKICAgICAgICAgICAgcXVlcnkgPSBzcmNoLnZhbHVlOwog
ICAgICAgICAgICBzcmNoLmNsYXNzTGlzdC50b2dnbGUoJ2hhcy12YWwnLCAhIXF1ZXJ5KTsKICAgICAg
ICAgICAgc2Nsci5zdHlsZS5kaXNwbGF5ID0gcXVlcnkgPyAnYmxvY2snIDogJ25vbmUnOwogICAgICAg
ICAgICByZXR1cm47CiAgICAgICAgfQogICAgICAgIF9fZmx1c2hTZWFyY2hJbnB1dCgpOwogICAgfSk7
CiAgICBzcmNoLmFkZEV2ZW50TGlzdGVuZXIoJ2ZvY3VzJywgKCkgPT4gewogICAgICAgIC8vIElkZW1w
b3RlbnQgb24gQUhLIHNpZGUg4oCUIHNhZmUsIGJ1dCBhdm9pZCBzcGFtbWluZyBkdXJpbmcgSU1FCiAg
ICAgICAgdHJ5IHsgYWhrKCdmb2N1c1BhbmVsJyk7IH0gY2F0Y2gge30KICAgIH0pOwogICAgc3JjaC5h
ZGRFdmVudExpc3RlbmVyKCdibHVyJywgKCkgPT4gewogICAgICAgIHNldFRpbWVvdXQoKCkgPT4gewog
ICAgICAgICAgICBpZiAoZG9jdW1lbnQuYWN0aXZlRWxlbWVudCA9PT0gc3JjaCkgcmV0dXJuOwogICAg
ICAgICAgICBpZiAoZG9jdW1lbnQuYWN0aXZlRWxlbWVudCA9PT0gc2NsciB8fCAoc2NsciAmJiBzY2xy
LmNvbnRhaW5zKGRvY3VtZW50LmFjdGl2ZUVsZW1lbnQpKSkgcmV0dXJuOwogICAgICAgICAgICBpZiAo
ZG9jdW1lbnQuYWN0aXZlRWxlbWVudCA9PT0gYnRuVG9kYXkgfHwgKGJ0blRvZGF5ICYmIGJ0blRvZGF5
LmNvbnRhaW5zKGRvY3VtZW50LmFjdGl2ZUVsZW1lbnQpKSkgcmV0dXJuOwogICAgICAgICAgICAvLyBJ
TUUgY2FuZGlkYXRlIFVJIHN0ZWFscyBmb2N1cyBicmllZmx5IOKAlCBrZWVwIHNlYXJjaCBpZiBzdGls
bCBjb21wb3NpbmcKICAgICAgICAgICAgaWYgKF9fc3JjaENvbXBvc2luZykgcmV0dXJuOwogICAgICAg
ICAgICBjbG9zZVNlYXJjaFVpKCk7CiAgICAgICAgICAgIGFoaygnYmx1clBhbmVsJyk7CiAgICAgICAg
fSwgMjgwKTsKICAgIH0pOwogICAgc3JjaC5hZGRFdmVudExpc3RlbmVyKCdrZXlkb3duJywgZSA9PiB7
CiAgICAgICAgLy8gQ3RybCtJIC8gQ3RybCtLOiBtb3ZlIGNsaXAgc2VsZWN0aW9uIChub3QgaW5zZXJ0
IGNoYXIgLyBicm93c2VyIHNob3J0Y3V0KQogICAgICAgIGlmICgoZS5jdHJsS2V5IHx8IGUubWV0YUtl
eSkgJiYgKGUua2V5ID09PSAnaScgfHwgZS5rZXkgPT09ICdJJykpIHsKICAgICAgICAgICAgZS5wcmV2
ZW50RGVmYXVsdCgpOwogICAgICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgICAgICAgICB3
aW5kb3cuX19uYXYgJiYgd2luZG93Ll9fbmF2KCd1cCcpOwogICAgICAgICAgICByZXR1cm47CiAgICAg
ICAgfQogICAgICAgIGlmICgoZS5jdHJsS2V5IHx8IGUubWV0YUtleSkgJiYgKGUua2V5ID09PSAnaycg
fHwgZS5rZXkgPT09ICdLJykpIHsKICAgICAgICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOwogICAgICAg
ICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgICAgICAgICB3aW5kb3cuX19uYXYgJiYgd2luZG93
Ll9fbmF2KCdkb3duJyk7CiAgICAgICAgICAgIHJldHVybjsKICAgICAgICB9CiAgICAgICAgaWYgKGUu
a2V5ID09PSAnQXJyb3dEb3duJykgewogICAgICAgICAgICBlLnByZXZlbnREZWZhdWx0KCk7CiAgICAg
ICAgICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAgICAgICAgIHdpbmRvdy5fX25hdiAmJiB3aW5k
b3cuX19uYXYoJ2Rvd24nKTsKICAgICAgICAgICAgcmV0dXJuOwogICAgICAgIH0KICAgICAgICBpZiAo
ZS5rZXkgPT09ICdBcnJvd1VwJykgewogICAgICAgICAgICBlLnByZXZlbnREZWZhdWx0KCk7CiAgICAg
ICAgICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAgICAgICAgIHdpbmRvdy5fX25hdiAmJiB3aW5k
b3cuX19uYXYoJ3VwJyk7CiAgICAgICAgICAgIHJldHVybjsKICAgICAgICB9CiAgICAgICAgaWYgKGUu
a2V5ID09PSAnRXNjYXBlJykgewogICAgICAgICAgICBlLnByZXZlbnREZWZhdWx0KCk7CiAgICAgICAg
ICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAgICAgICAgIC8vIEFsd2F5cyBkaXNtaXNzIHRoZSB3
aG9sZSBwYW5lbCAobm90IGp1c3QgdGhlIHNlYXJjaCBmaWVsZCkKICAgICAgICAgICAgaWYgKCFwaW5u
ZWRVSSkgYWhrKCdoaWRlJyk7CiAgICAgICAgICAgIHJldHVybjsKICAgICAgICB9CiAgICAgICAgZS5z
dG9wUHJvcGFnYXRpb24oKTsKICAgIH0pOwogICAgc2Nsci5hZGRFdmVudExpc3RlbmVyKCdjbGljaycs
IGUgPT4gewogICAgICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAgICAgc3JjaC52YWx1ZSA9IHF1
ZXJ5ID0gJyc7CiAgICAgICAgc2Nsci5zdHlsZS5kaXNwbGF5ID0gJ25vbmUnOwogICAgICAgIHNyY2gu
Y2xhc3NMaXN0LnJlbW92ZSgnaGFzLXZhbCcpOwogICAgICAgIHJlcXVlc3RWaWV3KCk7CiAgICAgICAg
YWhrKCdmb2N1c1BhbmVsJyk7CiAgICAgICAgc3JjaC5mb2N1cygpOwogICAgfSk7CgogICAgY29uc3Qg
VEFCX05BTUVTID0geyBhbGw6ICflhajpg6gnLCB0ZXh0OiAn5paH5pysJywgaW1hZ2U6ICflm77lg48n
LCBmaWxlOiAn5paH5Lu2JywgcmVjZW50OiAn5pyA6L+RJywgcGlubmVkOiAn5pS26JePJyB9OwogICAg
Y29uc3QgY2xyRGxnID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2Nsci1kbGcnKTsKICAgIGNvbnN0
IGNsckFsbENiID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2Nsci1hbGwnKTsKICAgIGZ1bmN0aW9u
IG9wZW5DbGVhckRsZygpIHsKICAgICAgICBjb25zdCBuYW1lID0gVEFCX05BTUVTW2N1clRhYl0gfHwg
J+W9k+WJjSc7CiAgICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2Nsci10aXRsZScpLnRleHRD
b250ZW50ID0gJ+a4heepuuOAjCcgKyBuYW1lICsgJ+OAje+8nyc7CiAgICAgICAgZG9jdW1lbnQuZ2V0
RWxlbWVudEJ5SWQoJ2Nsci1kZXNjJykudGV4dENvbnRlbnQgPSBjdXJUYWIgPT09ICdwaW5uZWQnCiAg
ICAgICAgICAgID8gJ+m7mOiupOS7hea4heepuuW9k+WkqeeahOaUtuiXj+mhueOAguWLvumAieOAjOa4
heepuuaJgOacieOAjeWPr+a4hemZpOivpemAiemhueWNoeWFqOmDqOWGheWuueOAgicKICAgICAgICAg
ICAgOiAoY3VyVGFiID09PSAncmVjZW50JwogICAgICAgICAgICAgICAgPyAn5riF56m644CM5pyA6L+R
44CN5Lya5Yig6Zmk5pyq5Zu65a6a55qE5pyA6L+R55uu5b2V6K6w5b2V77yb5bey5Zu65a6a55qE55uu
5b2V5Lya5L+d55WZ44CCJwogICAgICAgICAgICAgICAgOiAn5LuF5riF56m65b2T5YmN6YCJ6aG55Y2h
44CC6buY6K6k5Y+q5riF5b2T5aSp77yb5pS26JeP6aG55LiN5Lya6KKr5riF6Zmk44CC5Yu+6YCJ44CM
5riF56m65omA5pyJ44CN5Y+v5riF6Zmk6K+l6YCJ6aG55Y2h5YWo6YOo5pel5pyf44CCJyk7CiAgICAg
ICAgY2xyQWxsQ2IuY2hlY2tlZCA9IGZhbHNlOwogICAgICAgIGNsckRsZy5jbGFzc0xpc3QuYWRkKCdv
bicpOwogICAgfQogICAgZnVuY3Rpb24gY2xvc2VDbGVhckRsZygpIHsKICAgICAgICBjbHJEbGcuY2xh
c3NMaXN0LnJlbW92ZSgnb24nKTsKICAgIH0KICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdidG4t
Y2xyJykuYWRkRXZlbnRMaXN0ZW5lcignY2xpY2snLCBlID0+IHsKICAgICAgICBlLnN0b3BQcm9wYWdh
dGlvbigpOwogICAgICAgIG9wZW5DbGVhckRsZygpOwogICAgfSk7CiAgICBkb2N1bWVudC5nZXRFbGVt
ZW50QnlJZCgnY2xyLWNhbmNlbCcpLmFkZEV2ZW50TGlzdGVuZXIoJ2NsaWNrJywgZSA9PiB7CiAgICAg
ICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICBjbG9zZUNsZWFyRGxnKCk7CiAgICB9KTsKICAg
IGNsckRsZy5hZGRFdmVudExpc3RlbmVyKCdjbGljaycsIGUgPT4gewogICAgICAgIGlmIChlLnRhcmdl
dCA9PT0gY2xyRGxnKSBjbG9zZUNsZWFyRGxnKCk7CiAgICB9KTsKICAgIGRvY3VtZW50LmdldEVsZW1l
bnRCeUlkKCdjbHItb2snKS5hZGRFdmVudExpc3RlbmVyKCdjbGljaycsIGUgPT4gewogICAgICAgIGUu
c3RvcFByb3BhZ2F0aW9uKCk7CiAgICAgICAgY29uc3Qgc2NvcGUgPSAoY3VyVGFiID09PSAncmVjZW50
JykgPyAnYWxsJyA6IChjbHJBbGxDYi5jaGVja2VkID8gJ2FsbCcgOiAndG9kYXknKTsKICAgICAgICBj
bG9zZUNsZWFyRGxnKCk7CiAgICAgICAgYWhrKCdjbGVhcicsIGN1clRhYiwgc2NvcGUpOwogICAgfSk7
CiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbXVsdGktY250JykuYWRkRXZlbnRMaXN0ZW5lcign
Y2xpY2snLCBlID0+IHsKICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgICAgIGNsZWFyTXVs
dGkodHJ1ZSk7CiAgICB9KTsKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdidG4tcGluJykuYWRk
RXZlbnRMaXN0ZW5lcignY2xpY2snLCBlID0+IHsKICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwog
ICAgICAgIHBpbm5lZFVJID0gIXBpbm5lZFVJOwogICAgICAgIGUuY3VycmVudFRhcmdldC5jbGFzc0xp
c3QudG9nZ2xlKCdvbicsIHBpbm5lZFVJKTsKICAgICAgICBhaGsoJ3RvZ2dsZVBpbicsIHBpbm5lZFVJ
ID8gJzEnIDogJzAnKTsKICAgIH0pOwoKICAgIHdpbmRvdy5fX3BlcmZNYXJrID0gKHN0YWdlKSA9PiB7
CiAgICAgICAgdHJ5IHsKICAgICAgICAgICAgaWYgKHdpbmRvdy5jaHJvbWUgJiYgY2hyb21lLndlYnZp
ZXcgJiYgY2hyb21lLndlYnZpZXcucG9zdE1lc3NhZ2UpCiAgICAgICAgICAgICAgICBjaHJvbWUud2Vi
dmlldy5wb3N0TWVzc2FnZSgncGVyZnwnICsgU3RyaW5nKHN0YWdlIHx8ICcnKSk7CiAgICAgICAgfSBj
YXRjaCB7fQogICAgfTsKCiAgICB3aW5kb3cuX191cGRhdGVDbGlwcyA9IHBheWxvYWQgPT4gewogICAg
ICAgIGNvbnN0IHQwID0gKHR5cGVvZiBwZXJmb3JtYW5jZSAhPT0gJ3VuZGVmaW5lZCcgJiYgcGVyZm9y
bWFuY2Uubm93KSA/IHBlcmZvcm1hbmNlLm5vdygpIDogRGF0ZS5ub3coKTsKICAgICAgICB3aW5kb3cu
X19wZXJmTWFyaygnanNfdXBkYXRlQ2xpcHNfZW50ZXIgbj0nICsgKHBheWxvYWQgJiYgcGF5bG9hZC5p
dGVtcyA/IHBheWxvYWQuaXRlbXMubGVuZ3RoIDogKEFycmF5LmlzQXJyYXkocGF5bG9hZCkgPyBwYXls
b2FkLmxlbmd0aCA6IDApKSk7CiAgICAgICAgLy8gS2VlcCBwcmV2aW91cyBzY3JvbGwgZm9yIGxvYWQt
bW9yZTsgcmVzZXQgd2hlbiBvcGVuaW5nIHBhbmVsIHRvIGZpcnN0IGl0ZW0KICAgICAgICBjb25zdCBr
ZWVwU2Nyb2xsID0gIXNlbGVjdEZpcnN0T25TaG93OwogICAgICAgIGNvbnN0IHN0ID0gbGlzdEVsLnNj
cm9sbFRvcDsKICAgICAgICB3aW5kb3cuX193YWl0aW5nVmlldyA9IGZhbHNlOwogICAgICAgIGNvbnN0
IHdhc0FwcGVuZCA9IHBheWxvYWQgJiYgcGF5bG9hZC5hcHBlbmQ7CiAgICAgICAgbG9hZGluZ01vcmUg
PSBmYWxzZTsKICAgICAgICBjb25zdCBwcmV2SXRlbXMgPSBhbGxDbGlwczsKICAgICAgICBsZXQgbmV4
dEl0ZW1zID0gW107CiAgICAgICAgbGV0IG5leHRUb3RhbCA9IDA7CiAgICAgICAgbGV0IG5leHRGaWx0
ZXJlZCA9IGZhbHNlOwogICAgICAgIGxldCBwVGFiID0gJyc7CiAgICAgICAgbGV0IHBQaW5uZWRUb3Rh
bCA9IC0xOwogICAgICAgIGlmIChBcnJheS5pc0FycmF5KHBheWxvYWQpKSB7CiAgICAgICAgICAgIG5l
eHRJdGVtcyA9IHBheWxvYWQ7CiAgICAgICAgICAgIG5leHRUb3RhbCA9IHBheWxvYWQubGVuZ3RoOwog
ICAgICAgICAgICBuZXh0RmlsdGVyZWQgPSBmYWxzZTsKICAgICAgICB9IGVsc2UgaWYgKHBheWxvYWQg
JiYgdHlwZW9mIHBheWxvYWQgPT09ICdvYmplY3QnKSB7CiAgICAgICAgICAgIG5leHRUb3RhbCA9IE51
bWJlcihwYXlsb2FkLnRvdGFsKSB8fCAwOwogICAgICAgICAgICBuZXh0SXRlbXMgPSBBcnJheS5pc0Fy
cmF5KHBheWxvYWQuaXRlbXMpID8gcGF5bG9hZC5pdGVtcyA6IFtdOwogICAgICAgICAgICBwVGFiID0g
cGF5bG9hZC50YWIgIT0gbnVsbCA/IFN0cmluZyhwYXlsb2FkLnRhYikgOiAnJzsKICAgICAgICAgICAg
aWYgKHBheWxvYWQucGlubmVkVG90YWwgIT0gbnVsbCAmJiBwYXlsb2FkLnBpbm5lZFRvdGFsICE9PSAn
JykKICAgICAgICAgICAgICAgIHBQaW5uZWRUb3RhbCA9IE51bWJlcihwYXlsb2FkLnBpbm5lZFRvdGFs
KSB8fCAwOwogICAgICAgICAgICBjb25zdCBwcTAgPSBwYXlsb2FkLnF1ZXJ5ICE9IG51bGwgPyBTdHJp
bmcocGF5bG9hZC5xdWVyeSkgOiAnJzsKICAgICAgICAgICAgbmV4dEZpbHRlcmVkID0gISEocGF5bG9h
ZC5maWx0ZXJlZCB8fCAocHEwICYmIHBxMC50cmltKCkpKTsKICAgICAgICAgICAgaWYgKHBheWxvYWQu
YXBwZW5kKSB7CiAgICAgICAgICAgICAgICAvLyBBcHBlbmQgb25seSBhcHBsaWVzIHRvIHRoZSB0YWIg
d2UncmUgY3VycmVudGx5IHZpZXdpbmcKICAgICAgICAgICAgICAgIGlmIChwVGFiICYmIHBUYWIgIT09
IGN1clRhYikKICAgICAgICAgICAgICAgICAgICByZXR1cm47CiAgICAgICAgICAgICAgICBjb25zdCBz
ZWVuID0gbmV3IFNldChhbGxDbGlwcy5tYXAoYyA9PiArYy5pZCkpOwogICAgICAgICAgICAgICAgY29u
c3QgbWVyZ2VkID0gYWxsQ2xpcHMuc2xpY2UoKTsKICAgICAgICAgICAgICAgIG5leHRJdGVtcy5mb3JF
YWNoKGl0ID0+IHsKICAgICAgICAgICAgICAgICAgICBpZiAoIXNlZW4uaGFzKCtpdC5pZCkpIG1lcmdl
ZC5wdXNoKGl0KTsKICAgICAgICAgICAgICAgIH0pOwogICAgICAgICAgICAgICAgbmV4dEl0ZW1zID0g
bWVyZ2VkOwogICAgICAgICAgICAgICAgbmV4dFRvdGFsID0gTWF0aC5tYXgobmV4dFRvdGFsLCBuZXh0
SXRlbXMubGVuZ3RoKTsKICAgICAgICAgICAgfQogICAgICAgICAgICAvLyDmkJzntKLmoYbku6XmiZPl
rZfplZzlg4/kuLrlh4bvvIznu53kuI3ooqvmu57lkI7nmoTno4Hnm5jnu5Pmnpzlhpnlm57ml6flhbPp
lK7lrZcKICAgICAgICAgICAgdHJ5IHsKICAgICAgICAgICAgICAgIGNvbnN0IHMgPSBkb2N1bWVudC5n
ZXRFbGVtZW50QnlJZCgnc2VhcmNoJyk7CiAgICAgICAgICAgICAgICBpZiAocyAmJiBTdHJpbmcocy52
YWx1ZSB8fCAnJykubGVuZ3RoKQogICAgICAgICAgICAgICAgICAgIHF1ZXJ5ID0gcy52YWx1ZTsKICAg
ICAgICAgICAgICAgIGVsc2UgaWYgKHBxMCAhPT0gJycgJiYgIVN0cmluZyhxdWVyeSB8fCAnJykudHJp
bSgpKQogICAgICAgICAgICAgICAgICAgIHF1ZXJ5ID0gcHEwOwogICAgICAgICAgICB9IGNhdGNoIHt9
CiAgICAgICAgfSBlbHNlIHsKICAgICAgICAgICAgbmV4dEl0ZW1zID0gW107CiAgICAgICAgICAgIG5l
eHRUb3RhbCA9IDA7CiAgICAgICAgICAgIG5leHRGaWx0ZXJlZCA9IGZhbHNlOwogICAgICAgIH0KCiAg
ICAgICAgY29uc3QgYm94USA9IFN0cmluZyhxdWVyeSB8fCAnJykudHJpbSgpOwogICAgICAgIGNvbnN0
IHB1c2hRID0gKHBheWxvYWQgJiYgdHlwZW9mIHBheWxvYWQgPT09ICdvYmplY3QnICYmIHBheWxvYWQu
cXVlcnkgIT0gbnVsbCkKICAgICAgICAgICAgPyBTdHJpbmcocGF5bG9hZC5xdWVyeSkudHJpbSgpIDog
Jyc7CgogICAgICAgIC8vIEFsd2F5cyByZWZyZXNoIOaUtuiXjyBiYWRnZSBmcm9tIGhvc3Qgd2hlbiBw
cm92aWRlZAogICAgICAgIGlmIChwUGlubmVkVG90YWwgPj0gMCkKICAgICAgICAgICAgcGlubmVkVG90
YWwgPSBwUGlubmVkVG90YWw7CgogICAgICAgIC8vIFN0YWxlIHNlYXJjaCBwdXNoIChlLmcuICJzcXVh
cmUgbG9naSIgbGFuZHMgYWZ0ZXIgdXNlciB0eXBlZCAic3F1YXJlIGxvZ2luIikg4oCUY2FjaGUgb25s
eQogICAgICAgIGlmICghd2FzQXBwZW5kICYmIG5leHRGaWx0ZXJlZCAmJiBwdXNoUSAmJiBib3hRICYm
IHB1c2hRICE9PSBib3hRKSB7CiAgICAgICAgICAgIHZpZXdNZW0uc2V0KHZpZXdNZW1LZXkocFRhYiB8
fCBjdXJUYWIsIHB1c2hRLCB0b2RheU9ubHkpLCB7CiAgICAgICAgICAgICAgICBpdGVtczogbmV4dEl0
ZW1zLnNsaWNlKCksCiAgICAgICAgICAgICAgICB0b3RhbDogbmV4dFRvdGFsCiAgICAgICAgICAgIH0p
OwogICAgICAgICAgICByZXR1cm47CiAgICAgICAgfQoKICAgICAgICAvLyBTdGFsZSBwdXNoIGZvciBh
bm90aGVyIHRhYjogb25seSByZWZyZXNoIHRoYXQgdGFiJ3Mgdmlld01lbSwgZG9uJ3QgaGlqYWNrIFVJ
CiAgICAgICAgaWYgKCF3YXNBcHBlbmQgJiYgcFRhYiAmJiBwVGFiICE9PSBjdXJUYWIpIHsKICAgICAg
ICAgICAgY29uc3QgbWVtUSA9IChwYXlsb2FkICYmIHR5cGVvZiBwYXlsb2FkID09PSAnb2JqZWN0JyAm
JiBwYXlsb2FkLnF1ZXJ5ICE9IG51bGwpCiAgICAgICAgICAgICAgICA/IFN0cmluZyhwYXlsb2FkLnF1
ZXJ5KSA6ICcnOwogICAgICAgICAgICB2aWV3TWVtLnNldCh2aWV3TWVtS2V5KHBUYWIsIG1lbVEsIHRv
ZGF5T25seSksIHsKICAgICAgICAgICAgICAgIGl0ZW1zOiBuZXh0SXRlbXMuc2xpY2UoKSwKICAgICAg
ICAgICAgICAgIHRvdGFsOiBuZXh0VG90YWwKICAgICAgICAgICAgfSk7CiAgICAgICAgICAgIC8vIFN0
aWxsIHVwZGF0ZSBwaW4gYmFkZ2UgaWYgaG9zdCBzZW50IGl0CiAgICAgICAgICAgIHRyeSB7CiAgICAg
ICAgICAgICAgICBjb25zdCBwaW5DbnQgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgncGluLWNudCcp
OwogICAgICAgICAgICAgICAgaWYgKHBpbkNudCAmJiBwaW5uZWRUb3RhbCA+IDApIHsKICAgICAgICAg
ICAgICAgICAgICBwaW5DbnQudGV4dENvbnRlbnQgPSBwaW5uZWRUb3RhbDsKICAgICAgICAgICAgICAg
ICAgICBwaW5DbnQuc3R5bGUuZGlzcGxheSA9ICcnOwogICAgICAgICAgICAgICAgfQogICAgICAgICAg
ICB9IGNhdGNoIHt9CiAgICAgICAgICAgIC8vIFFRIOaQnOe0ouabvuWbuuWumuaOqCBhbGwgdGFiIOKG
kiDlvZPliY0gdGFiIOS8muS4gOebtOmqqOaetu+8m+ihpeS4gOasoSByZXF1ZXN0VmlldwogICAgICAg
ICAgICBpZiAod2FpdGluZ0RhdGEgJiYgcHVzaFEgPT09IGJveFEpIHsKICAgICAgICAgICAgICAgIHNl
dFRpbWVvdXQoKCkgPT4gewogICAgICAgICAgICAgICAgICAgIGlmICh3YWl0aW5nRGF0YSAmJiBjdXJU
YWIgIT09IHBUYWIpCiAgICAgICAgICAgICAgICAgICAgICAgIHJlcXVlc3RWaWV3KCk7CiAgICAgICAg
ICAgICAgICB9LCA0MCk7CiAgICAgICAgICAgIH0KICAgICAgICAgICAgcmV0dXJuOwogICAgICAgIH0K
CiAgICAgICAgLy8gQm9vdHN0cmFwIHJhY2U6IEFISyBwdXNoZWQgZW1wdHkgYmVmb3JlIFdhcm1BbGxW
aWV3cyDigJRrZWVwIHNrZWxldG9uLCBpZ25vcmUKICAgICAgICBjb25zdCBxT24gPSBTdHJpbmcocXVl
cnkgfHwgJycpLnRyaW0oKS5sZW5ndGggPiAwOwogICAgICAgIGlmICghd2FzQXBwZW5kICYmICFuZXh0
SXRlbXMubGVuZ3RoICYmIG5leHRUb3RhbCA8PSAwICYmICFxT24gJiYgIW5leHRGaWx0ZXJlZCAmJiAh
c2F3Tm9uRW1wdHkpIHsKICAgICAgICAgICAgaWYgKCF3aW5kb3cuX19lbXB0eUZhbGxiYWNrVCkgewog
ICAgICAgICAgICAgICAgd2luZG93Ll9fZW1wdHlGYWxsYmFja1QgPSBzZXRUaW1lb3V0KCgpID0+IHsK
ICAgICAgICAgICAgICAgICAgICB3aW5kb3cuX19lbXB0eUZhbGxiYWNrVCA9IDA7CiAgICAgICAgICAg
ICAgICAgICAgaWYgKHNhd05vbkVtcHR5KSByZXR1cm47CiAgICAgICAgICAgICAgICAgICAgLy8gVHJ1
bHkgZW1wdHkgaW5zdGFsbCBhZnRlciB3YWl0CiAgICAgICAgICAgICAgICAgICAgc2F3Tm9uRW1wdHkg
PSB0cnVlOwogICAgICAgICAgICAgICAgICAgIGhvc3RQdXNoZWRPbmNlID0gdHJ1ZTsKICAgICAgICAg
ICAgICAgICAgICB3aW5kb3cuX19kYXRhUmVhZHkgPSB0cnVlOwogICAgICAgICAgICAgICAgICAgIGFs
bENsaXBzID0gW107CiAgICAgICAgICAgICAgICAgICAgZGlza1RvdGFsID0gMDsKICAgICAgICAgICAg
ICAgICAgICBjbGVhcldhaXRpbmdEYXRhKCk7CiAgICAgICAgICAgICAgICAgICAgdHJ5IHsgcmVuZGVy
KCk7IH0gY2F0Y2gge30KICAgICAgICAgICAgICAgIH0sIDQ1MDApOwogICAgICAgICAgICB9CiAgICAg
ICAgICAgIHdhaXRpbmdEYXRhID0gdHJ1ZTsKICAgICAgICAgICAgd2luZG93Ll9fZGF0YVJlYWR5ID0g
ZmFsc2U7CiAgICAgICAgICAgIGhvc3RQdXNoZWRPbmNlID0gZmFsc2U7CiAgICAgICAgICAgIHNldEJv
b3RMb2FkaW5nKHRydWUpOwogICAgICAgICAgICB0cnkgeyByZW5kZXIoKTsgfSBjYXRjaCB7fQogICAg
ICAgICAgICByZXR1cm47CiAgICAgICAgfQoKICAgICAgICBjbGVhcldhaXRpbmdEYXRhKCk7CiAgICAg
ICAgYWxsQ2xpcHMgPSBuZXh0SXRlbXM7CiAgICAgICAgZGlza1RvdGFsID0gbmV4dFRvdGFsOwogICAg
ICAgIC8vIEtlZXAgYmFyIGNvbnNpc3RlbnQgaWYgbGlzdCBncmV3IHBhc3QgYSBzdGFsZSB0b3RhbAog
ICAgICAgIGlmIChhbGxDbGlwcy5sZW5ndGggPiBkaXNrVG90YWwpCiAgICAgICAgICAgIGRpc2tUb3Rh
bCA9IGFsbENsaXBzLmxlbmd0aDsKICAgICAgICB3aW5kb3cuX19ob3N0RmlsdGVyZWQgPSBuZXh0Rmls
dGVyZWQ7CiAgICAgICAgd2luZG93Ll9faG9zdEZpbHRlclEgPSAobmV4dEZpbHRlcmVkICYmIHB1c2hR
KSA/IHB1c2hRIDogJyc7CiAgICAgICAgLy8gRmlsdGVyZWQgc2VhcmNoIHdpdGggMCBoaXRzIOKAlG11
c3QgbGVhdmUgc2tlbGV0b24gKGhvc3QgZGlkIHJlc3BvbmQpCiAgICAgICAgaWYgKCF3YXNBcHBlbmQg
JiYgbmV4dEZpbHRlcmVkICYmICFhbGxDbGlwcy5sZW5ndGggJiYgZGlza1RvdGFsIDw9IDApIHsKICAg
ICAgICAgICAgaG9zdFB1c2hlZE9uY2UgPSB0cnVlOwogICAgICAgICAgICBzYXdOb25FbXB0eSA9IHRy
dWU7CiAgICAgICAgfQogICAgICAgIGlmIChhbGxDbGlwcy5sZW5ndGggfHwgZGlza1RvdGFsID4gMCkK
ICAgICAgICAgICAgc2F3Tm9uRW1wdHkgPSB0cnVlOwogICAgICAgIGlmICh3aW5kb3cuX19lbXB0eUZh
bGxiYWNrVCkgewogICAgICAgICAgICBjbGVhclRpbWVvdXQod2luZG93Ll9fZW1wdHlGYWxsYmFja1Qp
OwogICAgICAgICAgICB3aW5kb3cuX19lbXB0eUZhbGxiYWNrVCA9IDA7CiAgICAgICAgfQogICAgICAg
IGlmICghd2FzQXBwZW5kKSB7CiAgICAgICAgICAgIGNvbnN0IG1lbVEgPSAocGF5bG9hZCAmJiB0eXBl
b2YgcGF5bG9hZCA9PT0gJ29iamVjdCcgJiYgcGF5bG9hZC5xdWVyeSAhPSBudWxsKQogICAgICAgICAg
ICAgICAgPyBTdHJpbmcocGF5bG9hZC5xdWVyeSkgOiBxdWVyeTsKICAgICAgICAgICAgdmlld01lbS5z
ZXQodmlld01lbUtleShjdXJUYWIsIG1lbVEsIHRvZGF5T25seSksIHsKICAgICAgICAgICAgICAgIGl0
ZW1zOiBhbGxDbGlwcy5zbGljZSgpLAogICAgICAgICAgICAgICAgdG90YWw6IGRpc2tUb3RhbAogICAg
ICAgICAgICB9KTsKICAgICAgICB9CiAgICAgICAgd2luZG93Ll9fZGF0YVJlYWR5ID0gdHJ1ZTsKICAg
ICAgICBob3N0UHVzaGVkT25jZSA9IHRydWU7CgogICAgICAgIC8vIE1pZC13aGVlbDoga2VlcCBkYXRh
LCBkZWxheSBET00gc28gc2Nyb2xsL2RyYWcgbmV2ZXIgaGl0Y2ggb24gYXBwZW5kIHBhaW50CiAgICAg
ICAgaWYgKHdhc0FwcGVuZCAmJiB3aW5kb3cuX19zY3JvbGxCdXN5ICYmICF3aW5kb3cuX19wZW5kaW5n
SnVtcElkKSB7CiAgICAgICAgICAgIGNvbnN0IGZyb21MZW4gPSAocHJldkl0ZW1zICYmIHByZXZJdGVt
cy5sZW5ndGgpID8gcHJldkl0ZW1zLmxlbmd0aCA6IDA7CiAgICAgICAgICAgIGlmICghX3BlbmRpbmdB
cHBlbmQpCiAgICAgICAgICAgICAgICBfcGVuZGluZ0FwcGVuZCA9IHsgZnJvbUxlbjogZnJvbUxlbiB9
OwogICAgICAgICAgICB0cnkgeyByZWZyZXNoTGlzdENocm9tZSgpOyB9IGNhdGNoIHt9CiAgICAgICAg
ICAgIHJldHVybjsKICAgICAgICB9CgogICAgICAgIGNvbnN0IHdhc0Jvb3RMb2FkaW5nID0gYm9vdExv
YWRpbmc7CiAgICAgICAgbGV0IHNhbWVQYWludCA9IGZhbHNlOwogICAgICAgIGNvbnN0IHByZXZMZW4g
PSAocHJldkl0ZW1zICYmIHByZXZJdGVtcy5sZW5ndGgpID8gcHJldkl0ZW1zLmxlbmd0aCA6IDA7CiAg
ICAgICAgaWYgKCF3YXNBcHBlbmQgJiYgIXdhc0Jvb3RMb2FkaW5nICYmIHByZXZJdGVtcyAmJiBwcmV2
SXRlbXMubGVuZ3RoID09PSBhbGxDbGlwcy5sZW5ndGggJiYgcHJldkl0ZW1zLmxlbmd0aCkgewogICAg
ICAgICAgICBzYW1lUGFpbnQgPSB0cnVlOwogICAgICAgICAgICBmb3IgKGxldCBpID0gMDsgaSA8IGFs
bENsaXBzLmxlbmd0aDsgaSsrKSB7CiAgICAgICAgICAgICAgICBpZiAoK3ByZXZJdGVtc1tpXS5pZCAh
PT0gK2FsbENsaXBzW2ldLmlkKSB7IHNhbWVQYWludCA9IGZhbHNlOyBicmVhazsgfQogICAgICAgICAg
ICB9CiAgICAgICAgICAgIGlmIChzYW1lUGFpbnQgJiYgIWxpc3RFbC5xdWVyeVNlbGVjdG9yKCcuaXRt
JykpIHNhbWVQYWludCA9IGZhbHNlOwogICAgICAgIH0KICAgICAgICBjb25zdCBmaW5pc2hVcGRhdGUg
PSAoKSA9PiB7CiAgICAgICAgICAgIGNvbnN0IHRSZW5kZXIwID0gKHR5cGVvZiBwZXJmb3JtYW5jZSAh
PT0gJ3VuZGVmaW5lZCcgJiYgcGVyZm9ybWFuY2Uubm93KSA/IHBlcmZvcm1hbmNlLm5vdygpIDogRGF0
ZS5ub3coKTsKICAgICAgICAgICAgY2xlYXJXYWl0aW5nRGF0YSgpOwogICAgICAgICAgICBpZiAod2Fz
QXBwZW5kICYmICF3YXNCb290TG9hZGluZyAmJiBwcmV2TGVuID4gMCAmJiBhbGxDbGlwcy5sZW5ndGgg
PiBwcmV2TGVuKSB7CiAgICAgICAgICAgICAgICBhcHBlbmRSZW5kZXIocHJldkxlbik7CiAgICAgICAg
ICAgIH0gZWxzZSBpZiAoIXNhbWVQYWludCkgewogICAgICAgICAgICAgICAgcmVuZGVyKCk7CiAgICAg
ICAgICAgICAgICBhcHBseVRhYlN3aXRjaEFuaW0oKTsKICAgICAgICAgICAgICAgIGlmIChrZWVwU2Ny
b2xsKQogICAgICAgICAgICAgICAgICAgIGxpc3RFbC5zY3JvbGxUb3AgPSBzdDsKICAgICAgICAgICAg
ICAgIGVsc2UKICAgICAgICAgICAgICAgICAgICBsaXN0RWwuc2Nyb2xsVG9wID0gMDsKICAgICAgICAg
ICAgfSBlbHNlIHsKICAgICAgICAgICAgICAgIHRyeSB7IHJlZnJlc2hMaXN0Q2hyb21lKCk7IH0gY2F0
Y2gge30KICAgICAgICAgICAgICAgIGlmIChrZWVwU2Nyb2xsKQogICAgICAgICAgICAgICAgICAgIGxp
c3RFbC5zY3JvbGxUb3AgPSBzdDsKICAgICAgICAgICAgfQogICAgICAgICAgICBjb25zdCB0MSA9ICh0
eXBlb2YgcGVyZm9ybWFuY2UgIT09ICd1bmRlZmluZWQnICYmIHBlcmZvcm1hbmNlLm5vdykgPyBwZXJm
b3JtYW5jZS5ub3coKSA6IERhdGUubm93KCk7CiAgICAgICAgICAgIHdpbmRvdy5fX3BlcmZNYXJrKCdq
c191cGRhdGVDbGlwc19kb25lIHJlbmRlck1zPScgKyBNYXRoLnJvdW5kKHQxIC0gdFJlbmRlcjApICsg
JyB0b3RhbE1zPScgKyBNYXRoLnJvdW5kKHQxIC0gdDApICsgJyBuPScgKyBhbGxDbGlwcy5sZW5ndGgp
OwogICAgICAgIH07CiAgICAgICAgaWYgKHdhc0Jvb3RMb2FkaW5nKSB7CiAgICAgICAgICAgIGNvbnN0
IHNpbmNlID0gd2luZG93Ll9fc2tlbFNpbmNlIHx8IDA7CiAgICAgICAgICAgIGNvbnN0IHdhaXQgPSBz
aW5jZSA/IE1hdGgubWF4KDAsIDgwIC0gKERhdGUubm93KCkgLSBzaW5jZSkpIDogMDsKICAgICAgICAg
ICAgaWYgKHdhaXQgPiAwKQogICAgICAgICAgICAgICAgc2V0VGltZW91dChmaW5pc2hVcGRhdGUsIHdh
aXQpOwogICAgICAgICAgICBlbHNlCiAgICAgICAgICAgICAgICBmaW5pc2hVcGRhdGUoKTsKICAgICAg
ICB9IGVsc2UgewogICAgICAgICAgICBmaW5pc2hVcGRhdGUoKTsKICAgICAgICB9CiAgICB9OwogICAg
d2luZG93Ll9fc2V0UGlubmVkID0gdiA9PiB7CiAgICAgICAgcGlubmVkVUkgPSAhIXY7CiAgICAgICAg
ZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2J0bi1waW4nKS5jbGFzc0xpc3QudG9nZ2xlKCdvbicsIHBp
bm5lZFVJKTsKICAgIH07CiAgICB3aW5kb3cuX19sb2FkTW9yZURvbmUgPSAoKSA9PiB7CiAgICAgICAg
bG9hZGluZ01vcmUgPSBmYWxzZTsKICAgICAgICBpZiAod2luZG93Ll9fbG9hZE1vcmVXYXRjaCkgewog
ICAgICAgICAgICBjbGVhclRpbWVvdXQod2luZG93Ll9fbG9hZE1vcmVXYXRjaCk7CiAgICAgICAgICAg
IHdpbmRvdy5fX2xvYWRNb3JlV2F0Y2ggPSAwOwogICAgICAgIH0KICAgICAgICBpZiAod2luZG93Ll9f
cGVuZGluZ0p1bXBJZCkKICAgICAgICAgICAgdHJ5Q29udGludWVKdW1wKCk7CiAgICB9OwoKICAgIHNj
aGVkdWxlRGVsYXllZFNrZWwoKTsKICAgIHdpbmRvdy5fX3BlcmZNYXJrICYmIHdpbmRvdy5fX3BlcmZN
YXJrKCdqc19ib290IHJlcXVlc3RWaWV3Jyk7CiAgICByZXF1ZXN0VmlldygpOwogICAgLy8gc2NoZWR1
bGVEZWxheWVkU2tlbCBhbHJlYWR5IHJlbmRlcigpJ2Qgd2hlbiBlbXB0eTsgc3RpbGwgcGFpbnQgb25j
ZSBmb3IgY2hyb21lCgogICAgPC9zY3JpcHQ+CjwvYm9keT4KPC9odG1sPg==
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
        if FileClipLooksLikeImage(item)
            SetTimer(EnsureFileClipThumbAndInject.Bind(item), -30)
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
        try wv.DefaultBackgroundColor := 0xFFF0F1F5

        wvCore := wv.CoreWebView2
        wvCore.Settings.AreDefaultContextMenusEnabled := false
        wvCore.Settings.IsStatusBarEnabled := false
        ; Stop Chromium Ctrl+F find from eating our search shortcut
        try wvCore.Settings.AreBrowserAcceleratorKeysEnabled := false
        try wvCore.Settings.IsNonClientRegionSupportEnabled := true

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
    global uiNavReady
    uiNavReady := true
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
    } else if item.type = "file" {
        ; 复制的图片文件：必须写入 clips_store + 注入缩略图（前端已不再 sync ensureFileImg）
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
