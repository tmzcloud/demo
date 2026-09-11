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
UI_CACHE_VER := "20260910-fav-compact"
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
NjA5MTAtZmF2LWNvbXBhY3QiIGRhdGEtdGFiPSJhbGwiPgogICAgPGRpdiBpZD0iaGRyIj4KICAgICAg
ICA8ZGl2IGlkPSJoZWFydCI+CiAgICAgICAgICAgIDxzdmcgdmlld0JveD0iMCAwIDI0IDI0IiBmaWxs
PSJub25lIiBzdHJva2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIxLjgiCiAgICAgICAgICAg
ICAgICAgc3Ryb2tlLWxpbmVjYXA9InJvdW5kIiBzdHJva2UtbGluZWpvaW49InJvdW5kIj4KICAgICAg
ICAgICAgICAgIDxyZWN0IHg9IjkiIHk9IjIiIHdpZHRoPSI2IiBoZWlnaHQ9IjQiIHJ4PSIxIi8+CiAg
ICAgICAgICAgICAgICA8cGF0aCBkPSJNMTYgNGgyYTIgMiAwIDAgMSAyIDJ2MTRhMiAyIDAgMCAxLTIg
Mkg2YTIgMiAwIDAgMS0yLTJWNmEyIDIgMCAwIDEgMi0yaDIiLz4KICAgICAgICAgICAgICAgIDxwYXRo
IGQ9Ik05IDEyaDZNOSAxNmg0Ii8+CiAgICAgICAgICAgIDwvc3ZnPgogICAgICAgIDwvZGl2PgogICAg
ICAgIDxkaXYgaWQ9Imhkci1ncm93Ij48L2Rpdj4KICAgICAgICA8ZGl2IGlkPSJtdWx0aS1iYXIiPgog
ICAgICAgICAgICA8YnV0dG9uIGlkPSJtdWx0aS1zZWwiIHR5cGU9ImJ1dHRvbiIgdGl0bGU9IuWPlua2
iOWkmumAiSI+CiAgICAgICAgICAgICAgICA8c3BhbiBpZD0ibXVsdGktc2VsLWxhYiI+5bey6YCJPC9z
cGFuPgogICAgICAgICAgICAgICAgPHNwYW4gaWQ9Im11bHRpLWNudCI+MDwvc3Bhbj4KICAgICAgICAg
ICAgPC9idXR0b24+CiAgICAgICAgICAgIDxkaXYgaWQ9InBhc3RlLXNlcC13cmFwIj4KICAgICAgICAg
ICAgICAgIDxidXR0b24gaWQ9InBhc3RlLXNlcC1idG4iIHR5cGU9ImJ1dHRvbiIgdGl0bGU9IueymOi0
tOWIhumalOespu+8iOeCuemAieeUqOW5tueymOi0tO+8iSI+CiAgICAgICAgICAgICAgICAgICAgPHNw
YW4gaWQ9InBhc3RlLXNlcC1sYWJlbCI+4pCjPC9zcGFuPgogICAgICAgICAgICAgICAgPC9idXR0b24+
CiAgICAgICAgICAgICAgICA8ZGl2IGlkPSJwYXN0ZS1zZXAtbWVudSI+PC9kaXY+CiAgICAgICAgICAg
IDwvZGl2PgogICAgICAgIDwvZGl2PgogICAgICAgIDxidXR0b24gaWQ9ImJ0bi1sb2NhdGUiIHR5cGU9
ImJ1dHRvbiIgdGl0bGU9IuWumuS9jeWIsOS4iuasoeS9v+eUqOeahOadoeebriIgZGlzYWJsZWQ+CiAg
ICAgICAgICAgIDxzdmcgdmlld0JveD0iMCAwIDI0IDI0IiBmaWxsPSJub25lIiBzdHJva2U9ImN1cnJl
bnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIyIgogICAgICAgICAgICAgICAgIHN0cm9rZS1saW5lY2FwPSJy
b3VuZCIgc3Ryb2tlLWxpbmVqb2luPSJyb3VuZCI+CiAgICAgICAgICAgICAgICA8Y2lyY2xlIGN4PSIx
MiIgY3k9IjEyIiByPSI4Ii8+CiAgICAgICAgICAgICAgICA8Y2lyY2xlIGN4PSIxMiIgY3k9IjEyIiBy
PSIzLjUiLz4KICAgICAgICAgICAgPC9zdmc+CiAgICAgICAgPC9idXR0b24+CiAgICAgICAgPGRpdiBp
ZD0ic2VhcmNoLXdyYXAiPgogICAgICAgICAgICA8YnV0dG9uIGlkPSJidG4tc2VhcmNoIiB0eXBlPSJi
dXR0b24iIHRpdGxlPSLmkJzntKIiPgogICAgICAgICAgICAgICAgPHN2ZyB2aWV3Qm94PSIwIDAgMjQg
MjQiIGZpbGw9Im5vbmUiIHN0cm9rZT0iY3VycmVudENvbG9yIiBzdHJva2Utd2lkdGg9IjIiCiAgICAg
ICAgICAgICAgICAgICAgIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIgc3Ryb2tlLWxpbmVqb2luPSJyb3Vu
ZCI+CiAgICAgICAgICAgICAgICAgICAgPGNpcmNsZSBjeD0iMTEiIGN5PSIxMSIgcj0iNyIvPgogICAg
ICAgICAgICAgICAgICAgIDxwYXRoIGQ9Ik0yMCAyMGwtMy41LTMuNSIvPgogICAgICAgICAgICAgICAg
PC9zdmc+CiAgICAgICAgICAgIDwvYnV0dG9uPgogICAgICAgICAgICA8ZGl2IGlkPSJzZWFyY2gtYm94
Ij4KICAgICAgICAgICAgICAgIDxidXR0b24gaWQ9ImJ0bi10b2RheSIgdHlwZT0iYnV0dG9uIj7lvZPl
pKk8L2J1dHRvbj4KICAgICAgICAgICAgICAgIDxpbnB1dCBpZD0ic2VhcmNoIiB0eXBlPSJ0ZXh0IiBw
bGFjZWhvbGRlcj0i5pCc57Si4oCmIOepuuagvOWIhuivjemhu+WQjOaXtuWMheWQqyDCtyBhfGIg5YiG
5q61IiBhdXRvY29tcGxldGU9Im9mZiIgc3BlbGxjaGVjaz0iZmFsc2UiPgogICAgICAgICAgICAgICAg
PGJ1dHRvbiBpZD0ic2VhcmNoLWNsciIgdHlwZT0iYnV0dG9uIj7inJU8L2J1dHRvbj4KICAgICAgICAg
ICAgPC9kaXY+CiAgICAgICAgPC9kaXY+CiAgICAgICAgPGJ1dHRvbiBpZD0iYnRuLXBpbiIgdHlwZT0i
YnV0dG9uIiB0aXRsZT0i6ZKJ5Zyo5bGP5bmV5LiKIj4KICAgICAgICAgICAgPHN2ZyB2aWV3Qm94PSIw
IDAgMjQgMjQiIGZpbGw9Im5vbmUiIHN0cm9rZT0iY3VycmVudENvbG9yIiBzdHJva2Utd2lkdGg9IjIi
CiAgICAgICAgICAgICAgICAgc3Ryb2tlLWxpbmVqb2luPSJyb3VuZCIgc3Ryb2tlLWxpbmVjYXA9InJv
dW5kIj4KICAgICAgICAgICAgICAgIDxsaW5lIHgxPSIxMiIgeTE9IjE3IiB4Mj0iMTIiIHkyPSIyMiIv
PgogICAgICAgICAgICAgICAgPHBhdGggZD0iTTUgMTdoMTR2LTEuNzZhMiAyIDAgMCAwLTEuMTEtMS43
OWwtMS43OC0uOUEyIDIgMCAwIDEgMTUgMTAuNzZWNmgxYTIgMiAwIDAgMCAwLTRIOGEyIDIgMCAwIDAg
MCA0aDF2NC43NmEyIDIgMCAwIDEtMS4xMSAxLjc5bC0xLjc4LjlBMiAyIDAgMCAwIDUgMTUuMjRaIi8+
CiAgICAgICAgICAgIDwvc3ZnPgogICAgICAgIDwvYnV0dG9uPgogICAgPC9kaXY+CgogICAgPGRpdiBp
ZD0idGFicyI+CiAgICAgICAgPGRpdiBpZD0idGFiLWluayIgYXJpYS1oaWRkZW49InRydWUiPjwvZGl2
PgogICAgICAgIDxkaXYgY2xhc3M9InRhYiBvbiIgZGF0YS10YWI9ImFsbCI+5YWo6YOoPC9kaXY+CiAg
ICAgICAgPGRpdiBjbGFzcz0idGFiIiBkYXRhLXRhYj0idGV4dCI+5paH5pysPC9kaXY+CiAgICAgICAg
PGRpdiBjbGFzcz0idGFiIiBkYXRhLXRhYj0iaW1hZ2UiPuWbvuWDjzwvZGl2PgogICAgICAgIDxkaXYg
Y2xhc3M9InRhYiIgZGF0YS10YWI9ImZpbGUiPuaWh+S7tjwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9
InRhYiIgZGF0YS10YWI9InJlY2VudCI+5pyA6L+RPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0idGFi
IiBkYXRhLXRhYj0icGlubmVkIj7mlLbol48gPHNwYW4gaWQ9InBpbi1kb3QiIHRpdGxlPSLmnInmlrDm
lLbol48iPjwvc3Bhbj48L2Rpdj4KICAgICAgICA8ZGl2IGlkPSJ0YWItYWN0aW9ucyI+CiAgICAgICAg
ICAgIDxzcGFuIGlkPSJiYXItdHh0Ij4wPC9zcGFuPgogICAgICAgICAgICA8YnV0dG9uIGlkPSJidG4t
Y2xyIiB0eXBlPSJidXR0b24iIHRpdGxlPSLmuIXnqbrljoblj7IiPgogICAgICAgICAgICAgICAgPHN2
ZyB2aWV3Qm94PSIwIDAgMjQgMjQiIGZpbGw9Im5vbmUiIHN0cm9rZT0iY3VycmVudENvbG9yIiBzdHJv
a2Utd2lkdGg9IjIiCiAgICAgICAgICAgICAgICAgICAgIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIgc3Ry
b2tlLWxpbmVqb2luPSJyb3VuZCI+CiAgICAgICAgICAgICAgICAgICAgPHBvbHlsaW5lIHBvaW50cz0i
MyA2IDUgNiAyMSA2Ii8+CiAgICAgICAgICAgICAgICAgICAgPHBhdGggZD0iTTE5IDZsLTEgMTRhMiAy
IDAgMCAxLTIgMkg4YTIgMiAwIDAgMS0yLTJMNSA2Ii8+CiAgICAgICAgICAgICAgICAgICAgPHBhdGgg
ZD0iTTEwIDExdjZNMTQgMTF2Nk05IDZWNGg2djIiLz4KICAgICAgICAgICAgICAgIDwvc3ZnPgogICAg
ICAgICAgICA8L2J1dHRvbj4KICAgICAgICA8L2Rpdj4KICAgIDwvZGl2PgoKICAgIDxkaXYgaWQ9Imxp
c3QiPgogICAgICAgIDxkaXYgaWQ9InNrZWwiIGFyaWEtaGlkZGVuPSJ0cnVlIj4KICAgICAgICAgICAg
PGRpdiBjbGFzcz0ic2stcm93Ij48ZGl2IGNsYXNzPSJzay1pY28iPjwvZGl2PjxkaXYgY2xhc3M9InNr
LWJvZHkiPjxkaXYgY2xhc3M9InNrLWxpbmUgbWlkIj48L2Rpdj48ZGl2IGNsYXNzPSJzay1saW5lIHNo
b3J0Ij48L2Rpdj48L2Rpdj48L2Rpdj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0ic2stcm93Ij48ZGl2
IGNsYXNzPSJzay1pY28iPjwvZGl2PjxkaXYgY2xhc3M9InNrLWJvZHkiPjxkaXYgY2xhc3M9InNrLWxp
bmUiPjwvZGl2PjxkaXYgY2xhc3M9InNrLWxpbmUgbWlkIj48L2Rpdj48L2Rpdj48L2Rpdj4KICAgICAg
ICAgICAgPGRpdiBjbGFzcz0ic2stcm93Ij48ZGl2IGNsYXNzPSJzay1pY28iPjwvZGl2PjxkaXYgY2xh
c3M9InNrLWJvZHkiPjxkaXYgY2xhc3M9InNrLWxpbmUgbWlkIj48L2Rpdj48ZGl2IGNsYXNzPSJzay1s
aW5lIHNob3J0Ij48L2Rpdj48L2Rpdj48L2Rpdj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0ic2stcm93
Ij48ZGl2IGNsYXNzPSJzay1pY28iPjwvZGl2PjxkaXYgY2xhc3M9InNrLWJvZHkiPjxkaXYgY2xhc3M9
InNrLWxpbmUiPjwvZGl2PjxkaXYgY2xhc3M9InNrLWxpbmUgbWlkIj48L2Rpdj48L2Rpdj48L2Rpdj4K
ICAgICAgICAgICAgPGRpdiBjbGFzcz0ic2stcm93Ij48ZGl2IGNsYXNzPSJzay1pY28iPjwvZGl2Pjxk
aXYgY2xhc3M9InNrLWJvZHkiPjxkaXYgY2xhc3M9InNrLWxpbmUgbWlkIj48L2Rpdj48ZGl2IGNsYXNz
PSJzay1saW5lIHNob3J0Ij48L2Rpdj48L2Rpdj48L2Rpdj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0i
c2stcm93Ij48ZGl2IGNsYXNzPSJzay1pY28iPjwvZGl2PjxkaXYgY2xhc3M9InNrLWJvZHkiPjxkaXYg
Y2xhc3M9InNrLWxpbmUiPjwvZGl2PjxkaXYgY2xhc3M9InNrLWxpbmUgc2hvcnQiPjwvZGl2PjwvZGl2
PjwvZGl2PgogICAgICAgIDwvZGl2PgogICAgICAgIDxkaXYgaWQ9ImVtcHR5Ij4KICAgICAgICAgICAg
PGRpdiBjbGFzcz0iZS10eHQiIGlkPSJlbXB0eS10eHQiPuaaguaXoOiusOW9le+8jOWkjeWItuWQjuiH
quWKqOWHuueOsDwvZGl2PgogICAgICAgIDwvZGl2PgogICAgPC9kaXY+CiAgICA8YnV0dG9uIGlkPSJi
dG4tdG9wIiB0eXBlPSJidXR0b24iIHRpdGxlPSLlm57liLDpobbpg6giIGFyaWEtbGFiZWw9IuWbnuWI
sOmhtumDqCI+CiAgICAgICAgPHN2ZyB2aWV3Qm94PSIwIDAgMjQgMjQiIGZpbGw9Im5vbmUiIHN0cm9r
ZT0iY3VycmVudENvbG9yIiBzdHJva2Utd2lkdGg9IjIuMiIKICAgICAgICAgICAgIHN0cm9rZS1saW5l
Y2FwPSJyb3VuZCIgc3Ryb2tlLWxpbmVqb2luPSJyb3VuZCI+CiAgICAgICAgICAgIDxwYXRoIGQ9Ik0x
MiAxOVY1Ii8+CiAgICAgICAgICAgIDxwYXRoIGQ9Ik01IDEybDctNyA3IDciLz4KICAgICAgICA8L3N2
Zz4KICAgIDwvYnV0dG9uPgo8L2Rpdj4KCjxkaXYgaWQ9ImN0eCI+CiAgICA8ZGl2IGNsYXNzPSJjLWl0
ZW0iIGlkPSJjLWNvcHkiPjxzcGFuIGNsYXNzPSJjLWljbyI+4o6YPC9zcGFuPuWkjeWItjwvZGl2Pgog
ICAgPGRpdiBjbGFzcz0iYy1pdGVtIiBpZD0iYy1wYXN0ZSI+PHNwYW4gY2xhc3M9ImMtaWNvIj7ij448
L3NwYW4+57KY6LS0PC9kaXY+CiAgICA8ZGl2IGNsYXNzPSJjLXNlcCIgaWQ9ImMtZGF0YS1zZXAiIHN0
eWxlPSJkaXNwbGF5Om5vbmUiPjwvZGl2PgogICAgPGRpdiBjbGFzcz0iYy1zdWJ3cmFwIiBpZD0iYy1k
YXRhLXdyYXAiIHN0eWxlPSJkaXNwbGF5Om5vbmUiPgogICAgICAgIDxkaXYgY2xhc3M9ImMtaXRlbSIg
aWQ9ImMtZGF0YSI+PHNwYW4gY2xhc3M9ImMtaWNvIj7Oozwvc3Bhbj7mlbDmja7lpITnkIY8c3BhbiBj
bGFzcz0iYy1jYXJldCI+4oC6PC9zcGFuPjwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9ImMtc3ViIiBp
ZD0iYy1kYXRhLXN1YiI+CiAgICAgICAgICAgIDxkaXYgY2xhc3M9ImMtaXRlbSIgaWQ9ImMtZGF0YS1i
cmFjZSIgdGl0bGU9InthLGJ9IC8gYSxiIOKGkiBTUUwiPgogICAgICAgICAgICAgICAgPHNwYW4gY2xh
c3M9ImMtbnVtIj4xPC9zcGFuPjxzcGFuIGNsYXNzPSJjLWZyb20iPnthLGJ9PC9zcGFuPjxzcGFuIGNs
YXNzPSJjLWFycm93Ij7ihpI8L3NwYW4+PHNwYW4gY2xhc3M9ImMtdG8iPignYScsJ2InKTwvc3Bhbj4K
ICAgICAgICAgICAgPC9kaXY+CiAgICAgICAgICAgIDxkaXYgY2xhc3M9ImMtaXRlbSIgaWQ9ImMtZGF0
YS1saW5lcyIgdGl0bGU9IuaNouihjOWIhumalCDihpIgU1FMIj4KICAgICAgICAgICAgICAgIDxzcGFu
IGNsYXNzPSJjLW51bSI+Mjwvc3Bhbj48c3BhbiBjbGFzcz0iYy1mcm9tIj5hIFxuIGI8L3NwYW4+PHNw
YW4gY2xhc3M9ImMtYXJyb3ciPuKGkjwvc3Bhbj48c3BhbiBjbGFzcz0iYy10byI+KCdhJywnYicpPC9z
cGFuPgogICAgICAgICAgICA8L2Rpdj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0iYy1pdGVtIiBpZD0i
Yy1kYXRhLWpzb24iIHRpdGxlPSJKU09OIOWOu+i9rOS5ie+8mlwmcXVvdDsg4oaSICZxdW90OyI+CiAg
ICAgICAgICAgICAgICA8c3BhbiBjbGFzcz0iYy1udW0iPjM8L3NwYW4+PHNwYW4gY2xhc3M9ImMtZnJv
bSI+anNvbiAgJnF1b3Q7XCZxdW90Ozwvc3Bhbj48c3BhbiBjbGFzcz0iYy1hcnJvdyI+4oaSPC9zcGFu
PjxzcGFuIGNsYXNzPSJjLXRvIj4mcXVvdDsgJnF1b3Q7PC9zcGFuPgogICAgICAgICAgICA8L2Rpdj4K
ICAgICAgICA8L2Rpdj4KICAgIDwvZGl2PgogICAgPGRpdiBjbGFzcz0iYy1zZXAiPjwvZGl2PgogICAg
PGRpdiBjbGFzcz0iYy1pdGVtIiBpZD0iYy1waW4iPjxzcGFuIGNsYXNzPSJjLWljbyI+4piFPC9zcGFu
PuaUtuiXjzwvZGl2PgogICAgPGRpdiBjbGFzcz0iYy1pdGVtIiBpZD0iYy10aXRsZSIgc3R5bGU9ImRp
c3BsYXk6bm9uZSI+PHNwYW4gY2xhc3M9ImMtaWNvIj7inI48L3NwYW4+6K6+572u5qCH6aKYPC9kaXY+
CiAgICA8ZGl2IGNsYXNzPSJjLWl0ZW0iIGlkPSJjLW1lcmdlIiBzdHlsZT0iZGlzcGxheTpub25lIj48
c3BhbiBjbGFzcz0iYy1pY28iPuKniTwvc3Bhbj7lkIjlubY8L2Rpdj4KICAgIDxkaXYgY2xhc3M9ImMt
aXRlbSIgaWQ9ImMtdW5tZXJnZSIgc3R5bGU9ImRpc3BsYXk6bm9uZSI+PHNwYW4gY2xhc3M9ImMtaWNv
Ij7ih4Q8L3NwYW4+5Y+W5raI5ZCI5bm2PC9kaXY+CiAgICA8ZGl2IGNsYXNzPSJjLWl0ZW0iIGlkPSJj
LXRvcCI+PHNwYW4gY2xhc3M9ImMtaWNvIj7ihpE8L3NwYW4+56e75Yiw6aG26YOoPC9kaXY+CiAgICA8
ZGl2IGNsYXNzPSJjLWl0ZW0iIGlkPSJjLWNsZWFyLXBhc3RlZCIgc3R5bGU9ImRpc3BsYXk6bm9uZSI+
PHNwYW4gY2xhc3M9ImMtaWNvIj7inJM8L3NwYW4+5riF6Zmk54q25oCBPC9kaXY+CiAgICA8ZGl2IGNs
YXNzPSJjLWl0ZW0iIGlkPSJjLXF1ZXVlLWZyb20iIHN0eWxlPSJkaXNwbGF5Om5vbmUiPjxzcGFuIGNs
YXNzPSJjLWljbyI+4oa7PC9zcGFuPuS7juatpOWkhOW8gOWni+mYn+WIlzwvZGl2PgogICAgPGRpdiBj
bGFzcz0iYy1zZXAiPjwvZGl2PgogICAgPGRpdiBjbGFzcz0iYy1pdGVtIGRhbmdlciIgaWQ9ImMtZGVs
Ij48c3BhbiBjbGFzcz0iYy1pY28iPuKclTwvc3Bhbj7liKDpmaQ8L2Rpdj4KPC9kaXY+Cgo8ZGl2IGlk
PSJjbHItZGxnIj4KICAgIDxkaXYgY2xhc3M9ImNsci1ib3giIHJvbGU9ImRpYWxvZyIgYXJpYS1tb2Rh
bD0idHJ1ZSI+CiAgICAgICAgPGRpdiBjbGFzcz0iY2xyLXRpdGxlIiBpZD0iY2xyLXRpdGxlIj7noa7o
rqTmuIXnqbrvvJ88L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJjbHItZGVzYyIgaWQ9ImNsci1kZXNj
Ij7pu5jorqTku4XmuIXnqbrlvZPlpKnlhoXlrrnjgII8L2Rpdj4KICAgICAgICA8bGFiZWwgY2xhc3M9
ImNsci1jaGVjayIgZm9yPSJjbHItYWxsIj4KICAgICAgICAgICAgPGlucHV0IHR5cGU9ImNoZWNrYm94
IiBpZD0iY2xyLWFsbCI+CiAgICAgICAgICAgIDxzcGFuPua4heepuuaJgOaciTwvc3Bhbj4KICAgICAg
ICA8L2xhYmVsPgogICAgICAgIDxkaXYgY2xhc3M9ImNsci1idG5zIj4KICAgICAgICAgICAgPGJ1dHRv
biB0eXBlPSJidXR0b24iIGlkPSJjbHItY2FuY2VsIj7lj5bmtog8L2J1dHRvbj4KICAgICAgICAgICAg
PGJ1dHRvbiB0eXBlPSJidXR0b24iIGlkPSJjbHItb2siPua4heepujwvYnV0dG9uPgogICAgICAgIDwv
ZGl2PgogICAgPC9kaXY+CjwvZGl2PgoKPGRpdiBpZD0idGl0bGUtZGxnIj4KICAgIDxkaXYgY2xhc3M9
InRpdGxlLWJveCIgcm9sZT0iZGlhbG9nIiBhcmlhLW1vZGFsPSJ0cnVlIj4KICAgICAgICA8ZGl2IGNs
YXNzPSJjbHItdGl0bGUiPuiuvue9ruagh+mimDwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9ImNsci1k
ZXNjIj7moIfpopjlj6/ooqvmkJzntKLmib7liLDvvIzku4XnlKjkuo7mlLbol4/mlbTnkIbjgII8L2Rp
dj4KICAgICAgICA8aW5wdXQgaWQ9InRpdGxlLWlucHV0IiB0eXBlPSJ0ZXh0IiBtYXhsZW5ndGg9Ijgw
IiBwbGFjZWhvbGRlcj0i57uZ6L+Z5p2h5pS26JeP6LW35Liq5ZCN5a2X4oCmIiBhdXRvY29tcGxldGU9
Im9mZiIgc3BlbGxjaGVjaz0iZmFsc2UiPgogICAgICAgIDxkaXYgY2xhc3M9ImNsci1idG5zIj4KICAg
ICAgICAgICAgPGJ1dHRvbiB0eXBlPSJidXR0b24iIGlkPSJ0aXRsZS1jYW5jZWwiPuWPlua2iDwvYnV0
dG9uPgogICAgICAgICAgICA8YnV0dG9uIHR5cGU9ImJ1dHRvbiIgaWQ9InRpdGxlLW9rIj7kv53lrZg8
L2J1dHRvbj4KICAgICAgICA8L2Rpdj4KICAgIDwvZGl2Pgo8L2Rpdj4KPGRpdiBpZD0icGF0aC10aXAi
IGFyaWEtaGlkZGVuPSJ0cnVlIj48L2Rpdj4KCjxzY3JpcHQ+Ci8qIOemgeatoiBDdHJsK+a7mui9rue8
qeaUvu+8iFdlYlZpZXcg6K6+572uICsg6aG16Z2i5YWc5bqV77yJICovCihmdW5jdGlvbigpewogIGNv
bnN0IGJsb2NrWm9vbSA9IGUgPT4gewogICAgaWYgKGUuY3RybEtleSB8fCBlLm1ldGFLZXkpIHsKICAg
ICAgZS5wcmV2ZW50RGVmYXVsdCgpOwogICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgfQogIH07
CiAgd2luZG93LmFkZEV2ZW50TGlzdGVuZXIoJ3doZWVsJywgYmxvY2tab29tLCB7IHBhc3NpdmU6IGZh
bHNlLCBjYXB0dXJlOiB0cnVlIH0pOwogIHdpbmRvdy5hZGRFdmVudExpc3RlbmVyKCdnZXN0dXJlc3Rh
cnQnLCBlID0+IGUucHJldmVudERlZmF1bHQoKSwgeyBwYXNzaXZlOiBmYWxzZSwgY2FwdHVyZTogdHJ1
ZSB9KTsKICBkb2N1bWVudC5hZGRFdmVudExpc3RlbmVyKCdrZXlkb3duJywgZSA9PiB7CiAgICBpZiAo
IShlLmN0cmxLZXkgfHwgZS5tZXRhS2V5KSkgcmV0dXJuOwogICAgaWYgKGUua2V5ID09PSAnKycgfHwg
ZS5rZXkgPT09ICctJyB8fCBlLmtleSA9PT0gJz0nIHx8IGUua2V5ID09PSAnXycKICAgICAgICB8fCBl
LmNvZGUgPT09ICdOdW1wYWRBZGQnIHx8IGUuY29kZSA9PT0gJ051bXBhZFN1YnRyYWN0JwogICAgICAg
IHx8IGUua2V5ID09PSAnMCcpIHsKICAgICAgLy8gYWxsb3cgbm90aGluZyBmb3Igem9vbTsgQ3RybCsw
IC8gwrEKICAgICAgaWYgKGUua2V5ID09PSAnMCcgfHwgZS5rZXkgPT09ICcrJyB8fCBlLmtleSA9PT0g
Jy0nIHx8IGUua2V5ID09PSAnPScgfHwgZS5rZXkgPT09ICdfJwogICAgICAgICAgfHwgZS5jb2RlID09
PSAnTnVtcGFkQWRkJyB8fCBlLmNvZGUgPT09ICdOdW1wYWRTdWJ0cmFjdCcpIHsKICAgICAgICBlLnBy
ZXZlbnREZWZhdWx0KCk7CiAgICAgIH0KICAgIH0KICB9LCB0cnVlKTsKfSkoKTsKPC9zY3JpcHQ+Cjxz
Y3JpcHQ+Ci8qIHNrZWwtZmFpbHNhZmU6IG9ubHkgaWYgbWFpbiBVSSBzY3JpcHQgbmV2ZXIgYm9vdGVk
IOKAlG5ldmVyIGludmVudCBlbXB0eS1zdGF0ZSAqLwooZnVuY3Rpb24oKXsKICBzZXRUaW1lb3V0KCgp
ID0+IHsKICAgIHRyeSB7CiAgICAgIGlmICh3aW5kb3cuX191aUJvb3RlZCkgcmV0dXJuOwogICAgICB2
YXIgYXBwID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2FwcCcpOwogICAgICBpZiAoYXBwKSBhcHAu
Y2xhc3NMaXN0LnJlbW92ZSgnYm9vdC1sb2FkaW5nJyk7CiAgICAgIHZhciBzID0gZG9jdW1lbnQuZ2V0
RWxlbWVudEJ5SWQoJ3NrZWwnKTsKICAgICAgaWYgKHMpIHMuY2xhc3NMaXN0LnJlbW92ZSgnb24nKTsK
ICAgIH0gY2F0Y2ggKGVycikge30KICB9LCAzMDAwKTsKfSkoKTsKPC9zY3JpcHQ+CjxzY3JpcHQ+CiAg
ICBsZXQgYWxsQ2xpcHMgPSBbXSwgY3VyVGFiID0gJ2FsbCcsIHF1ZXJ5ID0gJycsIGN0eENsaXAgPSBu
dWxsLCBzZWxlY3RlZElkID0gMCwgcGlubmVkVUkgPSBmYWxzZTsKICAgIGNvbnN0IFRBQl9PUkRFUiA9
IFsnYWxsJywgJ3RleHQnLCAnaW1hZ2UnLCAnZmlsZScsICdyZWNlbnQnLCAncGlubmVkJ107CiAgICBj
b25zdCB2aWV3TWVtID0gbmV3IE1hcCgpOwogICAgZnVuY3Rpb24gdmlld01lbUtleSh0YWIsIHEsIHRv
ZGF5KSB7CiAgICAgICAgcmV0dXJuIFN0cmluZyh0YWIgfHwgJ2FsbCcpICsgJ1x0JyArIFN0cmluZyhx
IHx8ICcnKSArICdcdCcgKyAodG9kYXkgPyAnMScgOiAnMCcpOwogICAgfQogICAgbGV0IHRhYlN3aXRj
aEFuaW1EaXIgPSAwOwogICAgbGV0IG11bHRpSWRzID0gW107CiAgICBsZXQgdG9kYXlPbmx5ID0gZmFs
c2U7CiAgICBsZXQgZGlza1RvdGFsID0gMDsKICAgIGxldCBsb2FkaW5nTW9yZSA9IGZhbHNlOwogICAg
Ly8gRG9uJ3Qgc2hvdyBza2VsZXRvbiBpbW1lZGlhdGVseSDigJRvbmx5IGFmdGVyIFNLRUxfREVMQVlf
TVMgaWYgZGF0YSBzdGlsbCBtaXNzaW5nCiAgICBsZXQgYm9vdExvYWRpbmcgPSBmYWxzZTsKICAgIGxl
dCB3YWl0aW5nRGF0YSA9IGZhbHNlOwogICAgbGV0IGhvc3RQdXNoZWRPbmNlID0gZmFsc2U7IC8vIG9u
bHkgdGhlbiBtYXkgc2hvd+OAjOaaguaXoOiusOW9leOAjQogICAgbGV0IHNhd05vbkVtcHR5ID0gZmFs
c2U7ICAgIC8vIGlnbm9yZSBib290c3RyYXAgZW1wdHkgcHVzaGVzIGJlZm9yZSBmaXJzdCByZWFsIGxp
c3QKICAgIGxldCBwaW5uZWRUb3RhbCA9IDA7ICAgICAgICAvLyBhdXRob3JpdGF0aXZlIOaUtuiXjyBj
b3VudCBmcm9tIEFISwogICAgbGV0IHVuc2VlbkZhdklkcyA9IG5ldyBTZXQoKTsKICAgIHRyeSB7CiAg
ICAgICAgY29uc3QgcmF3ID0gbG9jYWxTdG9yYWdlLmdldEl0ZW0oJ2NsaXBfdW5zZWVuX2ZhdicpOwog
ICAgICAgIGlmIChyYXcpIEpTT04ucGFyc2UocmF3KS5mb3JFYWNoKGlkID0+IHsgaWQgPSAraWQ7IGlm
IChpZCkgdW5zZWVuRmF2SWRzLmFkZChpZCk7IH0pOwogICAgfSBjYXRjaCB7fQogICAgZnVuY3Rpb24g
c2F2ZVVuc2VlbkZhdigpIHsKICAgICAgICB0cnkgeyBsb2NhbFN0b3JhZ2Uuc2V0SXRlbSgnY2xpcF91
bnNlZW5fZmF2JywgSlNPTi5zdHJpbmdpZnkoWy4uLnVuc2VlbkZhdklkc10pKTsgfSBjYXRjaCB7fQog
ICAgfQogICAgZnVuY3Rpb24gdXBkYXRlUGluRG90KCkgewogICAgICAgIGNvbnN0IGVsID0gZG9jdW1l
bnQuZ2V0RWxlbWVudEJ5SWQoJ3Bpbi1kb3QnKTsKICAgICAgICBpZiAoIWVsKSByZXR1cm47CiAgICAg
ICAgZWwuY2xhc3NMaXN0LnRvZ2dsZSgnb24nLCB1bnNlZW5GYXZJZHMuc2l6ZSA+IDApOwogICAgfQog
ICAgZnVuY3Rpb24gbWFya0ZhdlVuc2VlbihpZCkgewogICAgICAgIGlkID0gK2lkOwogICAgICAgIGlm
ICghaWQpIHJldHVybjsKICAgICAgICB1bnNlZW5GYXZJZHMuYWRkKGlkKTsKICAgICAgICBzYXZlVW5z
ZWVuRmF2KCk7CiAgICAgICAgdXBkYXRlUGluRG90KCk7CiAgICB9CiAgICBmdW5jdGlvbiBjbGVhckZh
dlVuc2VlbigpIHsKICAgICAgICBpZiAoIXVuc2VlbkZhdklkcy5zaXplKSB7CiAgICAgICAgICAgIHVw
ZGF0ZVBpbkRvdCgpOwogICAgICAgICAgICByZXR1cm47CiAgICAgICAgfQogICAgICAgIHVuc2VlbkZh
dklkcy5jbGVhcigpOwogICAgICAgIHNhdmVVbnNlZW5GYXYoKTsKICAgICAgICB1cGRhdGVQaW5Eb3Qo
KTsKICAgIH0KICAgIGNvbnN0IFNLRUxfREVMQVlfTVMgPSA2MDsKICAgIHdpbmRvdy5fX2RhdGFSZWFk
eSA9IGZhbHNlOwogICAgd2luZG93Ll9fdWlCb290ZWQgPSB0cnVlOwogICAgLy8gT3BlbiBwYW5lbCB3
aXRob3V0IHBhc3Rpbmcg4oaSIGFsd2F5cyBsYW5kIG9uIGZpcnN0IGl0ZW0gKGFmdGVyIGRhdGEgYXJy
aXZlcykKICAgIGxldCBzZWxlY3RGaXJzdE9uU2hvdyA9IGZhbHNlOwogICAgbGV0IGxhc3RQYXN0ZUlk
ID0gMDsKICAgIGxldCBsYXN0UGFzdGVUYWIgPSAnYWxsJzsKICAgIGxldCBsb2NhdGVBY3RpdmUgPSBm
YWxzZTsKICAgIHRyeSB7IGxhc3RQYXN0ZUlkID0gK2xvY2FsU3RvcmFnZS5nZXRJdGVtKCdjbGlwTGFz
dFBhc3RlSWQnKSB8fCAwOyB9IGNhdGNoIHt9CiAgICB0cnkgewogICAgICAgIGNvbnN0IHQgPSBsb2Nh
bFN0b3JhZ2UuZ2V0SXRlbSgnY2xpcExhc3RQYXN0ZVRhYicpIHx8ICdhbGwnOwogICAgICAgIGxhc3RQ
YXN0ZVRhYiA9IFsnYWxsJywndGV4dCcsJ2ltYWdlJywnZmlsZScsJ3Bpbm5lZCddLmluY2x1ZGVzKHQp
ID8gdCA6ICdhbGwnOwogICAgfSBjYXRjaCB7fQogICAgLy8gTG9jYWwgV2ViVmlldyB2aXJ0dWFsLWhv
c3Qgb25seSDigJQgbmV2ZXIgcmVxdWVzdCB0aGUgcHVibGljIGludGVybmV0CiAgICBmdW5jdGlvbiBz
dG9yZUJhc2VVcmwoKSB7CiAgICAgICAgdHJ5IHsKICAgICAgICAgICAgaWYgKGxvY2F0aW9uLm9yaWdp
biAmJiAvXmh0dHBzPzpcL1wvL2kudGVzdChsb2NhdGlvbi5vcmlnaW4pKQogICAgICAgICAgICAgICAg
cmV0dXJuIGxvY2F0aW9uLm9yaWdpbi5yZXBsYWNlKC9cLyQvLCAnJykgKyAnL2NsaXBzX3N0b3JlLyc7
CiAgICAgICAgfSBjYXRjaCB7fQogICAgICAgIHJldHVybiAnL2NsaXBzX3N0b3JlLyc7CiAgICB9CiAg
ICBjb25zdCBTVE9SRV9CQVNFID0gc3RvcmVCYXNlVXJsKCk7CiAgICBjb25zdCBTVE9SRV9CQVNFX0ZB
TExCQUNLID0gU1RPUkVfQkFTRTsKICAgIGZ1bmN0aW9uIG1ldGFDZW50ZXJIdG1sKGV4cGFuZElubmVy
KSB7CiAgICAgICAgaWYgKGV4cGFuZElubmVyID09IG51bGwgfHwgZXhwYW5kSW5uZXIgPT09IGZhbHNl
KQogICAgICAgICAgICByZXR1cm4gYDxzcGFuIGNsYXNzPSJpLW1ldGEtY2VudGVyIj48L3NwYW4+YDsK
ICAgICAgICByZXR1cm4gYDxzcGFuIGNsYXNzPSJpLW1ldGEtY2VudGVyIj48YnV0dG9uIGNsYXNzPSJp
LWV4cGFuZC1idG4ke2V4cGFuZElubmVyLm9uID8gJyBvbicgOiAnJ30iIHR5cGU9ImJ1dHRvbiIgdGl0
bGU9IuWxleW8gC/mlLbotbciPiR7ZXhwYW5kSW5uZXIuaHRtbH08L2J1dHRvbj48L3NwYW4+YDsKICAg
IH0KCiAgICBmdW5jdGlvbiByZW1lbWJlckxhc3RQYXN0ZShpZCkgewogICAgICAgIGxhc3RQYXN0ZUlk
ID0gK2lkIHx8IDA7CiAgICAgICAgbGFzdFBhc3RlVGFiID0gY3VyVGFiIHx8ICdhbGwnOwogICAgICAg
IHRyeSB7CiAgICAgICAgICAgIGxvY2FsU3RvcmFnZS5zZXRJdGVtKCdjbGlwTGFzdFBhc3RlSWQnLCBT
dHJpbmcobGFzdFBhc3RlSWQpKTsKICAgICAgICAgICAgbG9jYWxTdG9yYWdlLnNldEl0ZW0oJ2NsaXBM
YXN0UGFzdGVUYWInLCBsYXN0UGFzdGVUYWIpOwogICAgICAgIH0gY2F0Y2gge30KICAgICAgICB1cGRh
dGVMb2NhdGVCdG4oKTsKICAgIH0KICAgIGZ1bmN0aW9uIHVwZGF0ZUxvY2F0ZUJ0bigpIHsKICAgICAg
ICBjb25zdCBidG4gPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYnRuLWxvY2F0ZScpOwogICAgICAg
IGlmICghYnRuKSByZXR1cm47CiAgICAgICAgYnRuLmRpc2FibGVkID0gIWxhc3RQYXN0ZUlkOwogICAg
ICAgIGJ0bi5jbGFzc0xpc3QudG9nZ2xlKCdoYXMtdGFyZ2V0JywgISFsYXN0UGFzdGVJZCk7CiAgICAg
ICAgYnRuLmNsYXNzTGlzdC50b2dnbGUoJ29uJywgbG9jYXRlQWN0aXZlICYmICEhbGFzdFBhc3RlSWQp
OwogICAgICAgIGJ0bi50aXRsZSA9ICFsYXN0UGFzdGVJZAogICAgICAgICAgICA/ICfmmoLml6DkuIrm
rKHkvb/nlKjkvY3nva4nCiAgICAgICAgICAgIDogKGxvY2F0ZUFjdGl2ZSA/ICflj5bmtojlrprkvY3v
vIzlm57liLDnrKzkuIDmnaEnIDogJ+WumuS9jeWIsOS4iuasoeS9v+eUqOeahOadoeebricpOwogICAg
fQogICAgZnVuY3Rpb24gc2VsZWN0Rmlyc3RJdGVtKCkgewogICAgICAgIGxvY2F0ZUFjdGl2ZSA9IGZh
bHNlOwogICAgICAgIHdpbmRvdy5fX3BlbmRpbmdKdW1wSWQgPSAwOwogICAgICAgIHdpbmRvdy5fX2p1
bXBMb2FkVHJpZXMgPSAwOwogICAgICAgIHNlbGVjdEZpcnN0T25TaG93ID0gZmFsc2U7CiAgICAgICAg
Y29uc3QgdmlzID0gdmlzaWJsZUxpc3QoKTsKICAgICAgICBpZiAoIXZpcy5sZW5ndGgpIHsKICAgICAg
ICAgICAgc2VsZWN0ZWRJZCA9IDA7CiAgICAgICAgICAgIHN5bmNJdGVtSGlnaGxpZ2h0KCk7CiAgICAg
ICAgICAgIHVwZGF0ZUxvY2F0ZUJ0bigpOwogICAgICAgICAgICByZXR1cm47CiAgICAgICAgfQogICAg
ICAgIHNlbGVjdGVkSWQgPSB2aXNbMF0uaWQ7CiAgICAgICAgcmFuZ2VBbmNob3JJZCA9IHNlbGVjdGVk
SWQ7CiAgICAgICAgcmFuZ2VBbmNob3JDbGlja2VkID0gZmFsc2U7CiAgICAgICAgbGlzdEVsLnNjcm9s
bFRvcCA9IDA7CiAgICAgICAgc3luY0l0ZW1IaWdobGlnaHQoKTsKICAgICAgICBjb25zdCBlbCA9IGxp
c3RFbC5xdWVyeVNlbGVjdG9yKCcuaXRtW2RhdGEtaWQ9IicgKyBzZWxlY3RlZElkICsgJyJdJyk7CiAg
ICAgICAgaWYgKGVsKSBlbC5zY3JvbGxJbnRvVmlldyh7IGJsb2NrOiAnbmVhcmVzdCcgfSk7CiAgICAg
ICAgdXBkYXRlTG9jYXRlQnRuKCk7CiAgICB9CiAgICBmdW5jdGlvbiBqdW1wVG9MYXN0UGFzdGUoKSB7
CiAgICAgICAgaWYgKCFsYXN0UGFzdGVJZCkgcmV0dXJuOwogICAgICAgIC8vIEFscmVhZHkgbG9jYXRl
ZCBvbiBsYXN0IHBhc3RlIOKGkiBjYW5jZWwgYW5kIHNlbGVjdCBmaXJzdAogICAgICAgIGlmIChsb2Nh
dGVBY3RpdmUgJiYgK3NlbGVjdGVkSWQgPT09ICtsYXN0UGFzdGVJZCkgewogICAgICAgICAgICBzZWxl
Y3RGaXJzdEl0ZW0oKTsKICAgICAgICAgICAgcmV0dXJuOwogICAgICAgIH0KICAgICAgICBsb2NhdGVB
Y3RpdmUgPSB0cnVlOwogICAgICAgIHNlbGVjdEZpcnN0T25TaG93ID0gZmFsc2U7CiAgICAgICAgLy8g
Q2xlYXIgZmlsdGVycyBzbyB0aGUgaXRlbSBpcyBmaW5kYWJsZSBvbiB0aGUgdGFiIHdoZXJlIGl0IHdh
cyB1c2VkCiAgICAgICAgcXVlcnkgPSAnJzsKICAgICAgICB0b2RheU9ubHkgPSBmYWxzZTsKICAgICAg
ICB0cnkgewogICAgICAgICAgICBjb25zdCBzcmNoID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3Nl
YXJjaCcpOwogICAgICAgICAgICBjb25zdCBzY2xyID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3Nl
YXJjaC1jbHInKTsKICAgICAgICAgICAgY29uc3Qgd3JhcCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlk
KCdzZWFyY2gtd3JhcCcpOwogICAgICAgICAgICBjb25zdCBidG5Ub2RheSA9IGRvY3VtZW50LmdldEVs
ZW1lbnRCeUlkKCdidG4tdG9kYXknKTsKICAgICAgICAgICAgaWYgKHNyY2gpIHsgc3JjaC52YWx1ZSA9
ICcnOyBzcmNoLmNsYXNzTGlzdC5yZW1vdmUoJ2hhcy12YWwnKTsgfQogICAgICAgICAgICBpZiAoc2Ns
cikgc2Nsci5zdHlsZS5kaXNwbGF5ID0gJ25vbmUnOwogICAgICAgICAgICBpZiAod3JhcCkgd3JhcC5j
bGFzc0xpc3QucmVtb3ZlKCdvcGVuJyk7CiAgICAgICAgICAgIGlmIChidG5Ub2RheSkgYnRuVG9kYXku
Y2xhc3NMaXN0LnJlbW92ZSgnb24nKTsKICAgICAgICB9IGNhdGNoIHt9CiAgICAgICAgY29uc3QgdGFi
ID0gWydhbGwnLCd0ZXh0JywnaW1hZ2UnLCdmaWxlJywncGlubmVkJ10uaW5jbHVkZXMobGFzdFBhc3Rl
VGFiKQogICAgICAgICAgICA/IGxhc3RQYXN0ZVRhYiA6ICdhbGwnOwogICAgICAgIGNvbnN0IHByZXZU
YWIgPSBjdXJUYWI7CiAgICAgICAgY3VyVGFiID0gdGFiOwogICAgICAgIGxvYWRpbmdNb3JlID0gZmFs
c2U7CiAgICAgICAgbWFya1RhYih0YWIpOwogICAgICAgIGNsZWFyTXVsdGkoKTsKICAgICAgICBzZWxl
Y3RlZElkID0gbGFzdFBhc3RlSWQ7CiAgICAgICAgd2luZG93Ll9fcGVuZGluZ0p1bXBJZCA9IGxhc3RQ
YXN0ZUlkOwogICAgICAgIHdpbmRvdy5fX2p1bXBMb2FkVHJpZXMgPSAwOwogICAgICAgIHdpbmRvdy5f
X2p1bXBGZWxsQmFjayA9IGZhbHNlOwogICAgICAgIHVwZGF0ZUxvY2F0ZUJ0bigpOwogICAgICAgIHJl
cXVlc3RWaWV3KCk7CiAgICB9CgogICAgZnVuY3Rpb24gcmVxdWVzdFZpZXcoKSB7CiAgICAgICAgY29u
c3QgdGFiID0gY3VyVGFiLCBxID0gcXVlcnksIHRvZGF5ID0gdG9kYXlPbmx5ID8gJzEnIDogJzAnOwog
ICAgICAgIGlmICh3aW5kb3cuX192aWV3UmFmKSBjYW5jZWxBbmltYXRpb25GcmFtZSh3aW5kb3cuX192
aWV3UmFmKTsKICAgICAgICB3aW5kb3cuX192aWV3UmFmID0gcmVxdWVzdEFuaW1hdGlvbkZyYW1lKCgp
ID0+IHsKICAgICAgICAgICAgd2luZG93Ll9fdmlld1JhZiA9IDA7CiAgICAgICAgICAgIHNldFRpbWVv
dXQoKCkgPT4gYWhrKCdzZXRWaWV3JywgdGFiLCBxLCB0b2RheSksIDApOwogICAgICAgIH0pOwogICAg
fQogICAgLyoqIERlYm91bmNlZCBBSEsgc3luYyBhZnRlciB2aWV3TWVtIGluc3RhbnQgcGFpbnQg4oCU
YXZvaWRzIHRhYi1zd2l0Y2ggZG91YmxlIFB1c2hDbGlwcyAqLwogICAgZnVuY3Rpb24gc29mdFJlcXVl
c3RWaWV3KCkgewogICAgICAgIGlmICh3aW5kb3cuX19zb2Z0Vmlld1QpIGNsZWFyVGltZW91dCh3aW5k
b3cuX19zb2Z0Vmlld1QpOwogICAgICAgIHdpbmRvdy5fX3NvZnRWaWV3VCA9IHNldFRpbWVvdXQoKCkg
PT4gewogICAgICAgICAgICB3aW5kb3cuX19zb2Z0Vmlld1QgPSAwOwogICAgICAgICAgICByZXF1ZXN0
VmlldygpOwogICAgICAgIH0sIDMyMCk7CiAgICB9CiAgICBmdW5jdGlvbiByZXF1ZXN0TW9yZShmb3Jj
ZSA9IGZhbHNlKSB7CiAgICAgICAgaWYgKGRpc2tUb3RhbCA+IDAgJiYgYWxsQ2xpcHMubGVuZ3RoID49
IGRpc2tUb3RhbCkgcmV0dXJuOwogICAgICAgIC8vIExvY2F0ZSAvIGp1bXAgbXVzdCBub3Qgd2FpdCBv
biBzY3JvbGwtaWRsZSBvciBhIHN0dWNrIGxvYWRpbmdNb3JlIGZsYWcKICAgICAgICBpZiAoIWZvcmNl
KSB7CiAgICAgICAgICAgIGlmIChsb2FkaW5nTW9yZSkgcmV0dXJuOwogICAgICAgICAgICBpZiAod2lu
ZG93Ll9fc2Nyb2xsQnVzeSB8fCBfbGlzdFB0ckRvd24pIHsKICAgICAgICAgICAgICAgIHdpbmRvdy5f
X3dhbnRNb3JlID0gdHJ1ZTsKICAgICAgICAgICAgICAgIHJldHVybjsKICAgICAgICAgICAgfQogICAg
ICAgIH0gZWxzZSB7CiAgICAgICAgICAgIGxvYWRpbmdNb3JlID0gZmFsc2U7CiAgICAgICAgICAgIHdp
bmRvdy5fX3Njcm9sbEJ1c3kgPSBmYWxzZTsKICAgICAgICAgICAgd2luZG93Ll9fd2FudE1vcmUgPSBm
YWxzZTsKICAgICAgICAgICAgX2xpc3RQdHJEb3duID0gZmFsc2U7CiAgICAgICAgICAgIHRyeSB7IGxp
c3RFbC5jbGFzc0xpc3QucmVtb3ZlKCdpcy1zY3JvbGxpbmcnKTsgfSBjYXRjaCB7fQogICAgICAgIH0K
ICAgICAgICBpZiAobG9hZGluZ01vcmUpIHJldHVybjsKICAgICAgICBsb2FkaW5nTW9yZSA9IHRydWU7
CiAgICAgICAgd2luZG93Ll9fd2FudE1vcmUgPSBmYWxzZTsKICAgICAgICBpZiAod2luZG93Ll9fbG9h
ZE1vcmVXYXRjaCkgY2xlYXJUaW1lb3V0KHdpbmRvdy5fX2xvYWRNb3JlV2F0Y2gpOwogICAgICAgIHdp
bmRvdy5fX2xvYWRNb3JlV2F0Y2ggPSBzZXRUaW1lb3V0KCgpID0+IHsKICAgICAgICAgICAgd2luZG93
Ll9fbG9hZE1vcmVXYXRjaCA9IDA7CiAgICAgICAgICAgIGlmIChsb2FkaW5nTW9yZSkgewogICAgICAg
ICAgICAgICAgbG9hZGluZ01vcmUgPSBmYWxzZTsKICAgICAgICAgICAgICAgIGlmICh3aW5kb3cuX19w
ZW5kaW5nSnVtcElkKSB0cnlDb250aW51ZUp1bXAoKTsKICAgICAgICAgICAgfQogICAgICAgIH0sIDE4
MDApOwogICAgICAgIGFoaygnbG9hZE1vcmUnKTsKICAgIH0KCiAgICBmdW5jdGlvbiB0cnlDb250aW51
ZUp1bXAoKSB7CiAgICAgICAgY29uc3QgamlkID0gK3dpbmRvdy5fX3BlbmRpbmdKdW1wSWQ7CiAgICAg
ICAgaWYgKCFqaWQpIHJldHVybjsKICAgICAgICBpZiAoX3BlbmRpbmdBcHBlbmQpIHsKICAgICAgICAg
ICAgY29uc3QgcGVuZGluZyA9IF9wZW5kaW5nQXBwZW5kOwogICAgICAgICAgICBfcGVuZGluZ0FwcGVu
ZCA9IG51bGw7CiAgICAgICAgICAgIGFwcGx5QXBwZW5kUGF5bG9hZChwZW5kaW5nKTsKICAgICAgICB9
CiAgICAgICAgY29uc3QgZWwgPSBsaXN0RWwucXVlcnlTZWxlY3RvcignLm1nLXJvd1tkYXRhLWlkPSIn
ICsgamlkICsgJyJdJykgfHwgbGlzdEVsLnF1ZXJ5U2VsZWN0b3IoJy5pdG1bZGF0YS1pZD0iJyArIGpp
ZCArICciXScpOwogICAgICAgIGlmIChlbCkgewogICAgICAgICAgICB3aW5kb3cuX19wZW5kaW5nSnVt
cElkID0gMDsKICAgICAgICAgICAgd2luZG93Ll9fanVtcExvYWRUcmllcyA9IDA7CiAgICAgICAgICAg
IHNlbGVjdGVkSWQgPSBqaWQ7CiAgICAgICAgICAgIGxvY2F0ZUFjdGl2ZSA9IHRydWU7CiAgICAgICAg
ICAgIHVwZGF0ZUxvY2F0ZUJ0bigpOwogICAgICAgICAgICByZXF1ZXN0QW5pbWF0aW9uRnJhbWUoKCkg
PT4gewogICAgICAgICAgICAgICAgY29uc3Qgbm9kZSA9IGxpc3RFbC5xdWVyeVNlbGVjdG9yKCcubWct
cm93W2RhdGEtaWQ9IicgKyBqaWQgKyAnIl0nKSB8fCBsaXN0RWwucXVlcnlTZWxlY3RvcignLml0bVtk
YXRhLWlkPSInICsgamlkICsgJyJdJyk7CiAgICAgICAgICAgICAgICBpZiAoIW5vZGUpIHJldHVybjsK
ICAgICAgICAgICAgICAgIG5vZGUuc2Nyb2xsSW50b1ZpZXcoeyBibG9jazogJ2NlbnRlcicgfSk7CiAg
ICAgICAgICAgICAgICBub2RlLmNsYXNzTGlzdC5hZGQoJ2p1bXAtZmxhc2gnKTsKICAgICAgICAgICAg
ICAgIHNldFRpbWVvdXQoKCkgPT4gbm9kZS5jbGFzc0xpc3QucmVtb3ZlKCdqdW1wLWZsYXNoJyksIDkw
MCk7CiAgICAgICAgICAgICAgICBzeW5jSXRlbUhpZ2hsaWdodCgpOwogICAgICAgICAgICB9KTsKICAg
ICAgICAgICAgcmV0dXJuOwogICAgICAgIH0KICAgICAgICBpZiAoYWxsQ2xpcHMuc29tZShjID0+ICtj
LmlkID09PSBqaWQpKSB7CiAgICAgICAgICAgIHJlbmRlcigpOwogICAgICAgICAgICByZXF1ZXN0QW5p
bWF0aW9uRnJhbWUoKCkgPT4gdHJ5Q29udGludWVKdW1wKCkpOwogICAgICAgICAgICByZXR1cm47CiAg
ICAgICAgfQogICAgICAgIGlmIChhbGxDbGlwcy5sZW5ndGggPCBkaXNrVG90YWwgJiYgKHdpbmRvdy5f
X2p1bXBMb2FkVHJpZXMgfHwgMCkgPCA4MCkgewogICAgICAgICAgICB3aW5kb3cuX19qdW1wTG9hZFRy
aWVzID0gKHdpbmRvdy5fX2p1bXBMb2FkVHJpZXMgfHwgMCkgKyAxOwogICAgICAgICAgICByZXF1ZXN0
TW9yZSh0cnVlKTsKICAgICAgICAgICAgcmV0dXJuOwogICAgICAgIH0KICAgICAgICB3aW5kb3cuX19w
ZW5kaW5nSnVtcElkID0gMDsKICAgICAgICB3aW5kb3cuX19qdW1wTG9hZFRyaWVzID0gMDsKICAgIH0K
ICAgIGNvbnN0IEVNUFRZX01TRyA9IHsKICAgICAgICBhbGw6ICAgICfmmoLml6DorrDlvZXvvIzlpI3l
iLblkI7oh6rliqjlh7rnjrAnLAogICAgICAgIHRleHQ6ICAgJ+aaguaXoOaWh+acrCcsCiAgICAgICAg
aW1hZ2U6ICAn5pqC5peg5Zu+5YOPJywKICAgICAgICBmaWxlOiAgICfmmoLml6Dmlofku7YnLAogICAg
ICAgIHBpbm5lZDogJ+aaguaXoOaUtuiXjycsCiAgICAgICAgcmVjZW50OiAn5pqC5peg5pyA6L+R5omT
5byA55qE55uu5b2VJwogICAgfTsKCiAgICBmdW5jdGlvbiBhaGtJbnZva2UobWV0aG9kLCBhcmdzKSB7
CiAgICAgICAgdHJ5IHsKICAgICAgICAgICAgY29uc3QgaG9zdCA9IGNocm9tZS53ZWJ2aWV3Lmhvc3RP
YmplY3RzLnN5bmMuYWhrOwogICAgICAgICAgICBpZiAoIWhvc3QpIHJldHVybjsKICAgICAgICAgICAg
bGV0IGNhbGxlZCA9IGZhbHNlOwogICAgICAgICAgICAvLyBXZWJWaWV3MjogaG9zdC5jYWxsKG5hbWUs
IOKApikgaXMgdGhlIHJlbGlhYmxlIHBhdGguIERpcmVjdCBob3N0W21ldGhvZF0o4oCmKQogICAgICAg
ICAgICAvLyBjYW4gbWlzLWJpbmQgYXJncyAoc2F3IHNldFZpZXcgdGFiIGJlY29tZSAwIOKGkiBmb3Jl
dmVyIHNrZWxldG9uIC8gd3JvbmcgdGFiKS4KICAgICAgICAgICAgaWYgKHR5cGVvZiBob3N0LmNhbGwg
PT09ICdmdW5jdGlvbicpIHsKICAgICAgICAgICAgICAgIHRyeSB7IGhvc3QuY2FsbChtZXRob2QsIC4u
LmFyZ3MpOyBjYWxsZWQgPSB0cnVlOyB9IGNhdGNoIHt9CiAgICAgICAgICAgIH0KICAgICAgICAgICAg
aWYgKCFjYWxsZWQgJiYgdHlwZW9mIGhvc3RbbWV0aG9kXSA9PT0gJ2Z1bmN0aW9uJykgewogICAgICAg
ICAgICAgICAgdHJ5IHsgaG9zdFttZXRob2RdKC4uLmFyZ3MpOyBjYWxsZWQgPSB0cnVlOyB9IGNhdGNo
IChlKSB7IGNvbnNvbGUud2FybignYWhrLicgKyBtZXRob2QsIGUpOyB9CiAgICAgICAgICAgIH0KICAg
ICAgICAgICAgaWYgKCFjYWxsZWQgJiYgaG9zdFttZXRob2RdICE9IG51bGwgJiYgdHlwZW9mIGhvc3Rb
bWV0aG9kXSAhPT0gJ2Z1bmN0aW9uJykgewogICAgICAgICAgICAgICAgdHJ5IHsgdm9pZCBob3N0W21l
dGhvZF07IH0gY2F0Y2gge30KICAgICAgICAgICAgfQogICAgICAgIH0gY2F0Y2ggKGUpIHsgY29uc29s
ZS53YXJuKCdhaGsuJyArIG1ldGhvZCwgZSk7IH0KICAgIH0KICAgIGZ1bmN0aW9uIGFoayhtZXRob2Qs
IC4uLmFyZ3MpIHsKICAgICAgICBhaGtJbnZva2UobWV0aG9kLCBhcmdzKTsKICAgIH0KICAgIGZ1bmN0
aW9uIGFoa1JldChtZXRob2QsIC4uLmFyZ3MpIHsKICAgICAgICB0cnkgewogICAgICAgICAgICBjb25z
dCBob3N0ID0gY2hyb21lLndlYnZpZXcuaG9zdE9iamVjdHMuc3luYy5haGs7CiAgICAgICAgICAgIGlm
ICghaG9zdCkgcmV0dXJuIG51bGw7CiAgICAgICAgICAgIGxldCByZXQgPSBudWxsOwogICAgICAgICAg
ICBpZiAodHlwZW9mIGhvc3QuY2FsbCA9PT0gJ2Z1bmN0aW9uJykgewogICAgICAgICAgICAgICAgdHJ5
IHsgcmV0ID0gaG9zdC5jYWxsKG1ldGhvZCwgLi4uYXJncyk7IH0gY2F0Y2gge30KICAgICAgICAgICAg
fQogICAgICAgICAgICBpZiAocmV0ID09IG51bGwgJiYgdHlwZW9mIGhvc3RbbWV0aG9kXSA9PT0gJ2Z1
bmN0aW9uJykgewogICAgICAgICAgICAgICAgdHJ5IHsgcmV0ID0gaG9zdFttZXRob2RdKC4uLmFyZ3Mp
OyB9IGNhdGNoIHt9CiAgICAgICAgICAgICAgICBpZiAocmV0ID09IG51bGwpIHsKICAgICAgICAgICAg
ICAgICAgICB0cnkgeyByZXQgPSBob3N0W21ldGhvZF0oLi4uYXJncyk7IH0gY2F0Y2gge30KICAgICAg
ICAgICAgICAgIH0KICAgICAgICAgICAgfQogICAgICAgICAgICBpZiAocmV0ID09IG51bGwgJiYgaG9z
dFttZXRob2RdICE9IG51bGwgJiYgdHlwZW9mIGhvc3RbbWV0aG9kXSAhPT0gJ2Z1bmN0aW9uJykKICAg
ICAgICAgICAgICAgIHJldCA9IGhvc3RbbWV0aG9kXTsKICAgICAgICAgICAgaWYgKHJldCA9PSBudWxs
KSByZXR1cm4gbnVsbDsKICAgICAgICAgICAgaWYgKHR5cGVvZiByZXQgPT09ICdzdHJpbmcnIHx8IHR5
cGVvZiByZXQgPT09ICdudW1iZXInIHx8IHR5cGVvZiByZXQgPT09ICdib29sZWFuJykKICAgICAgICAg
ICAgICAgIHJldHVybiByZXQ7CiAgICAgICAgICAgIHRyeSB7IHJldHVybiBTdHJpbmcocmV0KTsgfSBj
YXRjaCB7IHJldHVybiByZXQ7IH0KICAgICAgICB9IGNhdGNoIChlKSB7IGNvbnNvbGUud2FybignYWhr
UmV0LicgKyBtZXRob2QsIGUpOyB9CiAgICAgICAgcmV0dXJuIG51bGw7CiAgICB9CgogICAgLy8gRWFy
bHkgQUhLIF9fc2V0VGh1bWIgY2FuIGFycml2ZSBiZWZvcmUgRE9NIG5vZGVzIGV4aXN0IOKAlCBrZWVw
IHVudGlsIGJpbmQKICAgIGNvbnN0IHRodW1iQ2FjaGUgPSBuZXcgTWFwKCk7CgogICAgLyoqIFByZWZl
ciBjYWNoZSAvIGRhdGEtVVJMLCB0aGVuIHRoXyouanBnIHZpYSB2aXJ0dWFsIGhvc3QsIHRoZW4gb3Jp
Z2luYWwgKi8KICAgIGZ1bmN0aW9uIGJpbmRTdG9yZVRodW1iKGltZywgZmlsZSwgaWQsIGZhbGxiYWNr
KSB7CiAgICAgICAgaW1nLmRhdGFzZXQudGh1bWJJZCA9IFN0cmluZyhpZCk7CiAgICAgICAgaW1nLmFs
dCA9ICcnOwogICAgICAgIGltZy5jbGFzc0xpc3QuYWRkKCd0aHVtYi1sb2FkaW5nJyk7CiAgICAgICAg
Y29uc3Qgd3JhcCA9IGltZy5wYXJlbnRFbGVtZW50OwogICAgICAgIGlmICh3cmFwICYmIHdyYXAuY2xh
c3NMaXN0LmNvbnRhaW5zKCdpLXRodW1iLXdyYXAnKSkKICAgICAgICAgICAgd3JhcC5jbGFzc0xpc3Qu
YWRkKCd3YWl0aW5nJyk7CiAgICAgICAgY29uc3QgY2xlYXJXYWl0ID0gKCkgPT4gewogICAgICAgICAg
ICBpbWcuY2xhc3NMaXN0LnJlbW92ZSgndGh1bWItbG9hZGluZycpOwogICAgICAgICAgICBpZiAod3Jh
cCkgd3JhcC5jbGFzc0xpc3QucmVtb3ZlKCd3YWl0aW5nJyk7CiAgICAgICAgICAgIGlmIChpbWcuX2Zh
aWxUaW1lcikgdHJ5IHsgY2xlYXJUaW1lb3V0KGltZy5fZmFpbFRpbWVyKTsgfSBjYXRjaCB7fQogICAg
ICAgIH07CiAgICAgICAgY29uc3QgZmFpbFRpbWVyID0gc2V0VGltZW91dCgoKSA9PiB7CiAgICAgICAg
ICAgIGlmICghaW1nLnNyYyB8fCBpbWcubmF0dXJhbFdpZHRoIDwgMSkKICAgICAgICAgICAgICAgIGlt
Zy5hbHQgPSAn5peg5rOV5Yqg6L29JzsKICAgICAgICAgICAgY2xlYXJXYWl0KCk7CiAgICAgICAgfSwg
MTIwMDApOwogICAgICAgIGltZy5fZmFpbFRpbWVyID0gZmFpbFRpbWVyOwogICAgICAgIGNvbnN0IHBy
ZXZMb2FkID0gaW1nLm9ubG9hZDsKICAgICAgICBpbWcub25sb2FkID0gZSA9PiB7CiAgICAgICAgICAg
IGNsZWFyV2FpdCgpOwogICAgICAgICAgICBpbWcuYWx0ID0gJyc7CiAgICAgICAgICAgIGlmICh0eXBl
b2YgcHJldkxvYWQgPT09ICdmdW5jdGlvbicpIHByZXZMb2FkLmNhbGwoaW1nLCBlKTsKICAgICAgICB9
OwogICAgICAgIGNvbnN0IGJhcmUgPSBmaWxlID8gU3RyaW5nKGZpbGUpLnNwbGl0KC9bXFwvXS8pLnBv
cCgpIDogJyc7CiAgICAgICAgY29uc3QgdGhOYW1lID0gYmFyZSA/ICgndGhfJyArIGJhcmUucmVwbGFj
ZSgvXC5bXi5dKyQvLCAnJykgKyAnLmpwZycpIDogJyc7CiAgICAgICAgaW1nLm9uZXJyb3IgPSAoKSA9
PiB7CiAgICAgICAgICAgIGNvbnN0IHN0ZXAgPSBOdW1iZXIoaW1nLmRhdGFzZXQuc3RlcCB8fCAwKTsK
ICAgICAgICAgICAgaWYgKHN0ZXAgPCAyICYmIGJhcmUpIHsKICAgICAgICAgICAgICAgIGltZy5kYXRh
c2V0LnN0ZXAgPSAnMic7CiAgICAgICAgICAgICAgICBpbWcuc3JjID0gU1RPUkVfQkFTRSArIGVuY29k
ZVVSSUNvbXBvbmVudChiYXJlKTsKICAgICAgICAgICAgICAgIHJldHVybjsKICAgICAgICAgICAgfQog
ICAgICAgICAgICBpZiAoc3RlcCA8IDMgJiYgKHRoTmFtZSB8fCBiYXJlKSkgewogICAgICAgICAgICAg
ICAgaW1nLmRhdGFzZXQuc3RlcCA9ICczJzsKICAgICAgICAgICAgICAgIGltZy5zcmMgPSBTVE9SRV9C
QVNFX0ZBTExCQUNLICsgZW5jb2RlVVJJQ29tcG9uZW50KHRoTmFtZSB8fCBiYXJlKTsKICAgICAgICAg
ICAgICAgIHJldHVybjsKICAgICAgICAgICAgfQogICAgICAgICAgICBpZiAoc3RlcCA8IDQgJiYgYmFy
ZSAmJiB0aE5hbWUpIHsKICAgICAgICAgICAgICAgIGltZy5kYXRhc2V0LnN0ZXAgPSAnNCc7CiAgICAg
ICAgICAgICAgICBpbWcuc3JjID0gU1RPUkVfQkFTRV9GQUxMQkFDSyArIGVuY29kZVVSSUNvbXBvbmVu
dChiYXJlKTsKICAgICAgICAgICAgICAgIHJldHVybjsKICAgICAgICAgICAgfQogICAgICAgICAgICAv
LyBLZWVwIHNoaW1tZXI7IEFISyBfX3NldFRodW1iIHdpbGwgZmlsbCBpbgogICAgICAgICAgICBpbWcu
cmVtb3ZlQXR0cmlidXRlKCdzcmMnKTsKICAgICAgICAgICAgaW1nLmNsYXNzTGlzdC5hZGQoJ3RodW1i
LWxvYWRpbmcnKTsKICAgICAgICAgICAgaWYgKHdyYXApIHdyYXAuY2xhc3NMaXN0LmFkZCgnd2FpdGlu
ZycpOwogICAgICAgIH07CiAgICAgICAgY29uc3QgY2FjaGVkID0gdGh1bWJDYWNoZS5nZXQoU3RyaW5n
KGlkKSk7CiAgICAgICAgLy8gQWNjZXB0IGRhdGEtVVJMIG9yIGhvc3QgVVJMIGZyb20gcHJpb3IgX19z
ZXRUaHVtYiAocmUtcmVuZGVyIG11c3Qgbm90IGRyb3AgaXQpCiAgICAgICAgaWYgKGNhY2hlZCAmJiBT
dHJpbmcoY2FjaGVkKS5sZW5ndGgpIHsKICAgICAgICAgICAgaW1nLmRhdGFzZXQuc3RlcCA9ICc5JzsK
ICAgICAgICAgICAgaW1nLnNyYyA9IFN0cmluZyhjYWNoZWQpOwogICAgICAgICAgICByZXR1cm47CiAg
ICAgICAgfQogICAgICAgIGNvbnN0IGRhdGFVcmwgPSAoZmFsbGJhY2sgJiYgU3RyaW5nKGZhbGxiYWNr
KS5zdGFydHNXaXRoKCdkYXRhOicpKQogICAgICAgICAgICA/IFN0cmluZyhmYWxsYmFjaykgOiAnJzsK
ICAgICAgICBpZiAoZGF0YVVybCkgewogICAgICAgICAgICBpbWcuZGF0YXNldC5zdGVwID0gJzknOwog
ICAgICAgICAgICBpbWcuc3JjID0gZGF0YVVybDsKICAgICAgICAgICAgcmV0dXJuOwogICAgICAgIH0K
ICAgICAgICBpZiAoYmFyZSkgewogICAgICAgICAgICAvLyBQcmVmZXIgbGlzdCB0aHVtYiBKUEVHIChz
bWFsbCkgb24gZGVkaWNhdGVkIHN0b3JlIGhvc3QKICAgICAgICAgICAgaW1nLmRhdGFzZXQuc3RlcCA9
ICcxJzsKICAgICAgICAgICAgaW1nLnNyYyA9IFNUT1JFX0JBU0UgKyBlbmNvZGVVUklDb21wb25lbnQo
dGhOYW1lIHx8IGJhcmUpOwogICAgICAgIH0gZWxzZSB7CiAgICAgICAgICAgIC8vIE5vIGZpbGUgeWV0
IChqdXN0IGNvcGllZCkg4oCUa2VlcCBzaGltbWVyOyBJbmplY3RMaXZlSW1hZ2VUaHVtYiAvIF9fc2V0
VGh1bWIgZmlsbHMgaW4KICAgICAgICAgICAgaW1nLmNsYXNzTGlzdC5hZGQoJ3RodW1iLWxvYWRpbmcn
KTsKICAgICAgICAgICAgaWYgKHdyYXApIHdyYXAuY2xhc3NMaXN0LmFkZCgnd2FpdGluZycpOwogICAg
ICAgIH0KICAgIH0KCiAgICB3aW5kb3cuX19zZXRUaHVtYiA9IChpZCwgdXJsKSA9PiB7CiAgICAgICAg
aWYgKCF1cmwpIHJldHVybjsKICAgICAgICBjb25zdCBrZXkgPSBTdHJpbmcoaWQpOwogICAgICAgIHRo
dW1iQ2FjaGUuc2V0KGtleSwgdXJsKTsKICAgICAgICBjb25zdCBhcHBseSA9IGltZyA9PiB7CiAgICAg
ICAgICAgIGlmIChpbWcuX2ZhaWxUaW1lcikgdHJ5IHsgY2xlYXJUaW1lb3V0KGltZy5fZmFpbFRpbWVy
KTsgfSBjYXRjaCB7fQogICAgICAgICAgICBpbWcub25lcnJvciA9IG51bGw7CiAgICAgICAgICAgIGlt
Zy5hbHQgPSAnJzsKICAgICAgICAgICAgaW1nLmNsYXNzTGlzdC5yZW1vdmUoJ3RodW1iLWxvYWRpbmcn
KTsKICAgICAgICAgICAgY29uc3Qgd3JhcCA9IGltZy5wYXJlbnRFbGVtZW50OwogICAgICAgICAgICBp
ZiAod3JhcCkgd3JhcC5jbGFzc0xpc3QucmVtb3ZlKCd3YWl0aW5nJyk7CiAgICAgICAgICAgIGltZy5z
cmMgPSB1cmw7CiAgICAgICAgfTsKICAgICAgICBsZXQgaGl0ID0gMDsKICAgICAgICBkb2N1bWVudC5x
dWVyeVNlbGVjdG9yQWxsKCcuaXRtW2RhdGEtaWQ9IicgKyBrZXkgKyAnIl0gaW1nLmktdGh1bWInKS5m
b3JFYWNoKGltZyA9PiB7CiAgICAgICAgICAgIGFwcGx5KGltZyk7IGhpdCsrOwogICAgICAgIH0pOwog
ICAgICAgIGlmICghaGl0KSB7CiAgICAgICAgICAgIGRvY3VtZW50LnF1ZXJ5U2VsZWN0b3JBbGwoJ2lt
Zy5pLXRodW1iW2RhdGEtdGh1bWItaWQ9IicgKyBrZXkgKyAnIl0nKS5mb3JFYWNoKGFwcGx5KTsKICAg
ICAgICB9CiAgICB9OwoKICAgIGZ1bmN0aW9uIGlzRHJhZ0V4Y2x1ZGUodCkgewogICAgICAgIHJldHVy
biAhIXQuY2xvc2VzdCgnI3NlYXJjaC13cmFwLCAjYnRuLXNlYXJjaCwgI2J0bi1sb2NhdGUsICNidG4t
dG9kYXksICNidG4tcGluLCAjYnRuLWNsciwgI211bHRpLWJhciwgI211bHRpLXNlbCwgI211bHRpLWNu
dCwgI3Bhc3RlLXNlcC13cmFwLCAudGFiLCAuaXRtLCAjdGFiLWFjdGlvbnMsICNjdHgsICNjbHItZGxn
LCAjcGF0aC10aXAsIGJ1dHRvbiwgaW5wdXQsIGEnKTsKICAgIH0KICAgIGRvY3VtZW50LmdldEVsZW1l
bnRCeUlkKCdhcHAnKS5hZGRFdmVudExpc3RlbmVyKCdtb3VzZWRvd24nLCBlID0+IHsKICAgICAgICBp
ZiAoZS5idXR0b24gIT09IDApIHJldHVybjsKICAgICAgICBpZiAoaXNEcmFnRXhjbHVkZShlLnRhcmdl
dCkpIHJldHVybjsKICAgICAgICBlLnByZXZlbnREZWZhdWx0KCk7CiAgICAgICAgYWhrKCdzdGFydERy
YWcnKTsKICAgIH0sIHRydWUpOwoKICAgIGNvbnN0IGlzVXJsICA9IHMgPT4gL15odHRwcz86XC9cLy9p
LnRlc3QoKHMgfHwgJycpLnRyaW0oKSk7CgogICAgZnVuY3Rpb24gYWdvKGRhdGVTdHIpIHsKICAgICAg
ICB0cnkgewogICAgICAgICAgICBjb25zdCBkID0gbmV3IERhdGUoU3RyaW5nKGRhdGVTdHIpLnJlcGxh
Y2UoJyAnLCAnVCcpKTsKICAgICAgICAgICAgY29uc3QgcyA9IChEYXRlLm5vdygpIC0gZCkgLyAxMDAw
IHwgMDsKICAgICAgICAgICAgaWYgKHMgPCA2MCkgcmV0dXJuICfliJrliJonOwogICAgICAgICAgICBp
ZiAocyA8IDM2MDApIHJldHVybiAocyAvIDYwIHwgMCkgKyAnIOWIhumSn+WJjSc7CiAgICAgICAgICAg
IGlmIChzIDwgODY0MDApIHJldHVybiAocyAvIDM2MDAgfCAwKSArICcg5bCP5pe25YmNJzsKICAgICAg
ICAgICAgcmV0dXJuIChzIC8gODY0MDAgfCAwKSArICcg5aSp5YmNJzsKICAgICAgICB9IGNhdGNoIHsg
cmV0dXJuIGRhdGVTdHI7IH0KICAgIH0KCiAgICBmdW5jdGlvbiBub3JtVHlwZSh0KSB7CiAgICAgICAg
dCA9IFN0cmluZyh0IHx8ICcnKS50b0xvd2VyQ2FzZSgpOwogICAgICAgIGlmICh0ID09PSAnaW1hZ2Un
IHx8IHQgPT09ICdpbWcnIHx8IHQgPT09ICdiaXRtYXAnKSByZXR1cm4gJ2ltYWdlJzsKICAgICAgICBp
ZiAodCA9PT0gJ2ZpbGUnICB8fCB0ID09PSAnZmlsZXMnKSByZXR1cm4gJ2ZpbGUnOwogICAgICAgIGlm
ICh0ID09PSAncmVjZW50JyB8fCB0ID09PSAnZm9sZGVyJyB8fCB0ID09PSAnZGlyJykgcmV0dXJuICdy
ZWNlbnQnOwogICAgICAgIGlmICh0ID09PSAnbGluaycgfHwgdCA9PT0gJ3VybCcpIHJldHVybiAnbGlu
ayc7CiAgICAgICAgcmV0dXJuICd0ZXh0JzsKICAgIH0KICAgIGZ1bmN0aW9uIGlzUGlubmVkKGMpIHsK
ICAgICAgICByZXR1cm4gYy5waW5uZWQgPT09IHRydWUgfHwgYy5waW5uZWQgPT09IDEgfHwgYy5waW5u
ZWQgPT09ICd0cnVlJyB8fCBjLnBpbm5lZCA9PT0gJzEnOwogICAgfQogICAgLyoqIOWQjOatpeaJgOac
iSB0YWIg57yT5a2Y6YeM55qE5pS26JeP5qCH6K6w77yM6YG/5YWN5pS26JeP6aG15Y+W5raI5ZCO5YW2
5a6D5YiX6KGo5LuN5pi+56S644CM5Y+W5raI5pS26JeP44CNICovCiAgICBmdW5jdGlvbiBwYXRjaFBp
bm5lZEluQ2FjaGVzKGlkLCBwaW5uZWQpIHsKICAgICAgICBpZCA9ICtpZDsKICAgICAgICBpZiAoIWlk
KSByZXR1cm47CiAgICAgICAgY29uc3QgYXBwbHkgPSAoYykgPT4gewogICAgICAgICAgICBpZiAoIWMg
fHwgK2MuaWQgIT09IGlkKSByZXR1cm47CiAgICAgICAgICAgIGMucGlubmVkID0gISFwaW5uZWQ7CiAg
ICAgICAgICAgIGlmICghcGlubmVkKSBjLnBpblRpbWUgPSAnJzsKICAgICAgICB9OwogICAgICAgIGZv
ciAoY29uc3QgeCBvZiBhbGxDbGlwcykgYXBwbHkoeCk7CiAgICAgICAgdHJ5IHsKICAgICAgICAgICAg
Zm9yIChjb25zdCBba2V5LCBoaXRdIG9mIHZpZXdNZW0uZW50cmllcygpKSB7CiAgICAgICAgICAgICAg
ICBpZiAoIWhpdCB8fCAhQXJyYXkuaXNBcnJheShoaXQuaXRlbXMpKSBjb250aW51ZTsKICAgICAgICAg
ICAgICAgIGZvciAoY29uc3QgeCBvZiBoaXQuaXRlbXMpIGFwcGx5KHgpOwogICAgICAgICAgICAgICAg
Ly8g5pS26JePIHRhYiDnvJPlrZjvvJrlj5bmtojlkI7nm7TmjqXnp7vlh7oKICAgICAgICAgICAgICAg
IGlmICghcGlubmVkICYmIFN0cmluZyhrZXkpLnN0YXJ0c1dpdGgoJ3Bpbm5lZFx0JykpIHsKICAgICAg
ICAgICAgICAgICAgICBjb25zdCBiZWZvcmUgPSBoaXQuaXRlbXMubGVuZ3RoOwogICAgICAgICAgICAg
ICAgICAgIGhpdC5pdGVtcyA9IGhpdC5pdGVtcy5maWx0ZXIoeCA9PiAreC5pZCAhPT0gaWQpOwogICAg
ICAgICAgICAgICAgICAgIGlmIChoaXQuaXRlbXMubGVuZ3RoICE9PSBiZWZvcmUpCiAgICAgICAgICAg
ICAgICAgICAgICAgIGhpdC50b3RhbCA9IE1hdGgubWF4KDAsIChOdW1iZXIoaGl0LnRvdGFsKSB8fCBi
ZWZvcmUpIC0gKGJlZm9yZSAtIGhpdC5pdGVtcy5sZW5ndGgpKTsKICAgICAgICAgICAgICAgICAgICB2
aWV3TWVtLnNldChrZXksIGhpdCk7CiAgICAgICAgICAgICAgICB9CiAgICAgICAgICAgIH0KICAgICAg
ICB9IGNhdGNoIHt9CiAgICB9CiAgICBmdW5jdGlvbiBpc1Bhc3RlZChjKSB7CiAgICAgICAgcmV0dXJu
IGMucGFzdGVkID09PSB0cnVlIHx8IGMucGFzdGVkID09PSAxIHx8IGMucGFzdGVkID09PSAndHJ1ZScg
fHwgYy5wYXN0ZWQgPT09ICcxJzsKICAgIH0KCiAgICBmdW5jdGlvbiBpc01hcmtkb3duKHRleHQpIHsK
ICAgICAgICBpZiAoIXRleHQgfHwgdGV4dC5sZW5ndGggPCA0KSByZXR1cm4gZmFsc2U7CiAgICAgICAg
cmV0dXJuIC8oPzpefFxuKSN7MSw2fSB8XlstKitdIHxcKlwqW14qXG5dK1wqXCp8X19bXl9cbl0rX198
KD86Xnxcbik+IHxgYGB8YFteYFxuXStgfFxbW15cXV0rXF1cKFteKV0rXCl8XHwuK1x8LitcfC9tLnRl
c3QodGV4dCk7CiAgICB9CiAgICBmdW5jdGlvbiBjbGlwVXNlc01JY29uKGMpIHsKICAgICAgICBpZiAo
IWMpIHJldHVybiBmYWxzZTsKICAgICAgICBpZiAoYy5pc01kID09PSB0cnVlIHx8IGMuaXNNZCA9PT0g
MSB8fCBjLmlzTWQgPT09ICd0cnVlJyB8fCBjLmlzTWQgPT09ICcxJykgcmV0dXJuIHRydWU7CiAgICAg
ICAgaWYgKGMuaXNSaWNoID09PSB0cnVlIHx8IGMuaXNSaWNoID09PSAxIHx8IGMuaXNSaWNoID09PSAn
dHJ1ZScgfHwgYy5pc1JpY2ggPT09ICcxJykgcmV0dXJuIHRydWU7CiAgICAgICAgY29uc3QgdCA9IFN0
cmluZyhjLnR5cGUgfHwgJycpLnRvTG93ZXJDYXNlKCk7CiAgICAgICAgaWYgKHQgJiYgdCAhPT0gJ3Rl
eHQnICYmIHQgIT09ICdsaW5rJykgcmV0dXJuIGZhbHNlOwogICAgICAgIHJldHVybiBpc01hcmtkb3du
KGMuZGF0YSB8fCBjLnByZXZpZXcgfHwgJycpOwogICAgfQogICAgZnVuY3Rpb24gZXNjQXR0cihzKSB7
CiAgICAgICAgcmV0dXJuIFN0cmluZyhzIHx8ICcnKQogICAgICAgICAgICAucmVwbGFjZSgvJi9nLCAn
JmFtcDsnKQogICAgICAgICAgICAucmVwbGFjZSgvIi9nLCAnJnF1b3Q7JykKICAgICAgICAgICAgLnJl
cGxhY2UoLzwvZywgJyZsdDsnKQogICAgICAgICAgICAucmVwbGFjZSgvPi9nLCAnJmd0OycpOwogICAg
fQoKICAgIGZ1bmN0aW9uIHRvZGF5UHJlZml4KCkgewogICAgICAgIGNvbnN0IGQgPSBuZXcgRGF0ZSgp
OwogICAgICAgIGNvbnN0IHAgPSBuID0+IFN0cmluZyhuKS5wYWRTdGFydCgyLCAnMCcpOwogICAgICAg
IHJldHVybiBkLmdldEZ1bGxZZWFyKCkgKyAnLScgKyBwKGQuZ2V0TW9udGgoKSArIDEpICsgJy0nICsg
cChkLmdldERhdGUoKSk7CiAgICB9CiAgICBmdW5jdGlvbiBpc1RvZGF5Q2xpcChjKSB7CiAgICAgICAg
cmV0dXJuIFN0cmluZyhjLnRpbWUgfHwgJycpLnN0YXJ0c1dpdGgodG9kYXlQcmVmaXgoKSk7CiAgICB9
CgogICAgZnVuY3Rpb24gY2xpcEhheShjKSB7CiAgICAgICAgY29uc3QgZmF2ID0gU3RyaW5nKGMuZmF2
VGl0bGUgfHwgJycpOwogICAgICAgIGNvbnN0IGZhdkNvbXBhY3QgPSBmYXYucmVwbGFjZSgvXHMrL2cs
ICcnKTsKICAgICAgICByZXR1cm4gU3RyaW5nKGMucHJldmlldyB8fCAnJykgKyAnICcgKyBTdHJpbmco
Yy5kYXRhIHx8ICcnKSArICcgJwogICAgICAgICAgICArIFN0cmluZyhjLmxpbmtUaXRsZSB8fCAnJykg
KyAnICcgKyBmYXYKICAgICAgICAgICAgKyAoZmF2Q29tcGFjdCAmJiBmYXZDb21wYWN0ICE9PSBmYXYg
PyAoJyAnICsgZmF2Q29tcGFjdCkgOiAnJyk7CiAgICB9CiAgICAvKiogTWF0Y2ggQUhLIEl0ZW1NYXRj
aGVzVmlldyBsaXN0IHNlYXJjaCDigJQgcHJldmlldyAoKyBzaG9ydCBib2R5IGZhbGxiYWNrKSwgbm90
IGZ1bGwgZGF0YSAqLwogICAgZnVuY3Rpb24gZmF2VGl0bGVIYXkoZmF2KSB7CiAgICAgICAgZmF2ID0g
U3RyaW5nKGZhdiB8fCAnJyk7CiAgICAgICAgY29uc3QgY29tcGFjdCA9IGZhdi5yZXBsYWNlKC9ccysv
ZywgJycpOwogICAgICAgIGlmIChjb21wYWN0ICYmIGNvbXBhY3QgIT09IGZhdikKICAgICAgICAgICAg
cmV0dXJuIGZhdiArICcgJyArIGNvbXBhY3Q7CiAgICAgICAgcmV0dXJuIGZhdjsKICAgIH0KICAgIGZ1
bmN0aW9uIGNsaXBTZWFyY2hIYXkoYykgewogICAgICAgIGNvbnN0IHR5cGUgPSBTdHJpbmcoYy50eXBl
IHx8ICcnKS50b0xvd2VyQ2FzZSgpOwogICAgICAgIGNvbnN0IGZhdiA9IGZhdlRpdGxlSGF5KGMuZmF2
VGl0bGUpOwogICAgICAgIGlmICh0eXBlID09PSAnaW1hZ2UnKQogICAgICAgICAgICByZXR1cm4gZmF2
OwogICAgICAgIGlmICh0eXBlID09PSAnZmlsZScpIHsKICAgICAgICAgICAgcmV0dXJuIFN0cmluZyhj
LnByZXZpZXcgfHwgJycpICsgJyAnICsgU3RyaW5nKGMuZGF0YSB8fCAnJykgKyAnICcgKyBmYXY7CiAg
ICAgICAgfQogICAgICAgIGxldCBwcmV2ID0gU3RyaW5nKGMucHJldmlldyB8fCAnJyk7CiAgICAgICAg
aWYgKCFwcmV2ICYmIGMuZGF0YSkKICAgICAgICAgICAgcHJldiA9IFN0cmluZyhjLmRhdGEpLnNsaWNl
KDAsIDUwMCk7CiAgICAgICAgcmV0dXJuIHByZXYgKyAnICcgKyBTdHJpbmcoYy5saW5rVGl0bGUgfHwg
JycpICsgJyAnICsgZmF2OwogICAgfQogICAgZnVuY3Rpb24gY2xpcE1hdGNoZXNTZWFyY2goYywgdGVy
bUwpIHsKICAgICAgICBjb25zdCB0eXBlID0gU3RyaW5nKGMudHlwZSB8fCAnJykudG9Mb3dlckNhc2Uo
KTsKICAgICAgICBjb25zdCBoYXkgPSAodHlwZSA9PT0gJ2ltYWdlJyA/IGZhdlRpdGxlSGF5KGMuZmF2
VGl0bGUpIDogY2xpcFNlYXJjaEhheShjKSkudG9Mb3dlckNhc2UoKTsKICAgICAgICByZXR1cm4gdGVy
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
YXNlKCk7CiAgICAgICAgICAgICAgICByZXR1cm4gKHR5cGUgPT09ICdpbWFnZScgPyBmYXZUaXRsZUhh
eShjLmZhdlRpdGxlKSA6IGNsaXBTZWFyY2hIYXkoYykpLnRvTG93ZXJDYXNlKCk7CiAgICAgICAgICAg
IH0pLmpvaW4oJyAnKTsKICAgICAgICAgICAgaWYgKHRlcm1MLmV2ZXJ5KHQgPT4gdW5pb24uaW5jbHVk
ZXModCkpKQogICAgICAgICAgICAgICAgbWF0Y2hlZEdyb3Vwcy5hZGQoZ2lkKTsKICAgICAgICB9CiAg
ICAgICAgcmV0dXJuIGNsaXBzLmZpbHRlcihjID0+IHsKICAgICAgICAgICAgaWYgKGNsaXBNYXRjaGVz
U2VhcmNoKGMsIHRlcm1MKSkgcmV0dXJuIHRydWU7CiAgICAgICAgICAgIGNvbnN0IGdpZCA9IFN0cmlu
ZyhjICYmIGMuZmF2R3JvdXAgfHwgJycpLnRyaW0oKTsKICAgICAgICAgICAgcmV0dXJuIGdpZCAmJiBt
YXRjaGVkR3JvdXBzLmhhcyhnaWQpOwogICAgICAgIH0pOwogICAgfQoKICAgIGZ1bmN0aW9uIG1hcmtQ
YXN0ZWRMb2NhbChpZHMpIHsKICAgICAgICBjb25zdCBsaXN0ID0gQXJyYXkuaXNBcnJheShpZHMpID8g
aWRzIDogW2lkc107CiAgICAgICAgaWYgKGxpc3QubGVuZ3RoKQogICAgICAgICAgICByZW1lbWJlckxh
c3RQYXN0ZShsaXN0W2xpc3QubGVuZ3RoIC0gMV0pOwogICAgICAgIGNvbnN0IGJhZGdlSHRtbCA9IGA8
c3ZnIHZpZXdCb3g9IjAgMCAxNiAxNiIgZmlsbD0ibm9uZSIgc3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0
cm9rZS13aWR0aD0iMi40IiBzdHJva2UtbGluZWNhcD0icm91bmQiIHN0cm9rZS1saW5lam9pbj0icm91
bmQiPjxwb2x5bGluZSBwb2ludHM9IjMuNSA4LjUgNi41IDExLjUgMTIuNSA0LjUiLz48L3N2Zz5gOwog
ICAgICAgIGxpc3QuZm9yRWFjaChyYXdJZCA9PiB7CiAgICAgICAgICAgIGNvbnN0IGlkID0gK3Jhd0lk
OwogICAgICAgICAgICBjb25zdCBjID0gYWxsQ2xpcHMuZmluZCh4ID0+ICt4LmlkID09PSBpZCk7CiAg
ICAgICAgICAgIGlmIChjKSBjLnBhc3RlZCA9IHRydWU7CiAgICAgICAgICAgIGNvbnN0IHJvdyA9IGxp
c3RFbCAmJiAoCiAgICAgICAgICAgICAgICBsaXN0RWwucXVlcnlTZWxlY3RvcignLml0bVtkYXRhLWlk
PSInICsgaWQgKyAnIl0nKQogICAgICAgICAgICAgICAgfHwgbGlzdEVsLnF1ZXJ5U2VsZWN0b3IoJy5p
dG1bZGF0YS1pZD0iJyArIFN0cmluZyhyYXdJZCkgKyAnIl0nKQogICAgICAgICAgICApOwogICAgICAg
ICAgICBpZiAoIXJvdykgcmV0dXJuOwogICAgICAgICAgICByb3cuY2xhc3NMaXN0LmFkZCgncGFzdGVk
JywgJ3EtZG9uZScpOwogICAgICAgICAgICBjb25zdCBpY28gPSByb3cucXVlcnlTZWxlY3RvcignLmkt
aWNvJyk7CiAgICAgICAgICAgIGlmIChpY28gJiYgIWljby5xdWVyeVNlbGVjdG9yKCcuaS11c2VkJykp
IHsKICAgICAgICAgICAgICAgIGNvbnN0IGJhZGdlID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnc3Bh
bicpOwogICAgICAgICAgICAgICAgYmFkZ2UuY2xhc3NOYW1lID0gJ2ktdXNlZCc7CiAgICAgICAgICAg
ICAgICBiYWRnZS50aXRsZSA9ICflt7LnspjotLQnOwogICAgICAgICAgICAgICAgYmFkZ2UuaW5uZXJI
VE1MID0gYmFkZ2VIdG1sOwogICAgICAgICAgICAgICAgaWNvLmFwcGVuZENoaWxkKGJhZGdlKTsKICAg
ICAgICAgICAgfQogICAgICAgIH0pOwogICAgICAgIHRyeSB7IG1hcmtRdWV1ZVJhaWxzKCk7IH0gY2F0
Y2ggKGUpIHt9CiAgICB9CiAgICB3aW5kb3cuX19tYXJrUGFzdGVkID0gbWFya1Bhc3RlZExvY2FsOwoK
ICAgIGZ1bmN0aW9uIG1hcmtVbnBhc3RlZExvY2FsKGlkcykgewogICAgICAgIGNvbnN0IGxpc3QgPSBB
cnJheS5pc0FycmF5KGlkcykgPyBpZHMgOiBbaWRzXTsKICAgICAgICBsaXN0LmZvckVhY2gocmF3SWQg
PT4gewogICAgICAgICAgICBjb25zdCBpZCA9ICtyYXdJZDsKICAgICAgICAgICAgY29uc3QgYyA9IGFs
bENsaXBzLmZpbmQoeCA9PiAreC5pZCA9PT0gaWQpOwogICAgICAgICAgICBpZiAoYykgYy5wYXN0ZWQg
PSBmYWxzZTsKICAgICAgICAgICAgY29uc3Qgcm93ID0gbGlzdEVsICYmICgKICAgICAgICAgICAgICAg
IGxpc3RFbC5xdWVyeVNlbGVjdG9yKCcuaXRtW2RhdGEtaWQ9IicgKyBpZCArICciXScpCiAgICAgICAg
ICAgICAgICB8fCBsaXN0RWwucXVlcnlTZWxlY3RvcignLml0bVtkYXRhLWlkPSInICsgU3RyaW5nKHJh
d0lkKSArICciXScpCiAgICAgICAgICAgICk7CiAgICAgICAgICAgIGlmICghcm93KSByZXR1cm47CiAg
ICAgICAgICAgIHJvdy5jbGFzc0xpc3QucmVtb3ZlKCdwYXN0ZWQnLCAncS1kb25lJywgJ3EtZG9uZS1s
aW5rJyk7CiAgICAgICAgICAgIGNvbnN0IGJhZGdlID0gcm93LnF1ZXJ5U2VsZWN0b3IoJy5pLXVzZWQn
KTsKICAgICAgICAgICAgaWYgKGJhZGdlKSBiYWRnZS5yZW1vdmUoKTsKICAgICAgICAgICAgY29uc3Qg
ZG90ID0gcm93LnF1ZXJ5U2VsZWN0b3IoJy5xLWRvdCcpOwogICAgICAgICAgICBpZiAoZG90KSBkb3Qu
dGl0bGUgPSAn57KY6LS06Zif5YiXJzsKICAgICAgICB9KTsKICAgICAgICB0cnkgeyBtYXJrUXVldWVS
YWlscygpOyB9IGNhdGNoIChlKSB7fQogICAgfQogICAgd2luZG93Ll9fbWFya1VucGFzdGVkID0gbWFy
a1VucGFzdGVkTG9jYWw7CgogICAgY29uc3QgbGlzdEVsICA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlk
KCdsaXN0Jyk7CiAgICBjb25zdCBlbXB0eUVsID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2VtcHR5
Jyk7CiAgICBjb25zdCBza2VsRWwgID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NrZWwnKTsKICAg
IGNvbnN0IGJ0blRvcCAgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYnRuLXRvcCcpOwogICAgZnVu
Y3Rpb24gc2V0Qm9vdExvYWRpbmcob24pIHsKICAgICAgICBib290TG9hZGluZyA9ICEhb247CiAgICAg
ICAgLy8g56eS5byA77ya5LiN5YaN5omT5byA6aqo5p626Zeq5Yqo77yb5Y+q5L+d55WZIHdhaXRpbmdE
YXRhIOmAu+i+kemYsuepuuaAgeivr+mXqgogICAgICAgIGlmIChza2VsRWwpIHNrZWxFbC5jbGFzc0xp
c3QucmVtb3ZlKCdvbicpOwogICAgICAgIGlmIChvbiAmJiBlbXB0eUVsKSBlbXB0eUVsLmNsYXNzTGlz
dC5yZW1vdmUoJ29uJyk7CiAgICAgICAgY29uc3QgYXBwID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQo
J2FwcCcpOwogICAgICAgIGlmIChhcHApIGFwcC5jbGFzc0xpc3QucmVtb3ZlKCdib290LWxvYWRpbmcn
KTsKICAgIH0KICAgIC8qKiBXYWl0IGZvciBob3N0IGRhdGEg4oCU5LiN5YaN56uL5Yi75by56aqo5p62
77yM5pyJ5YaF5a655pe25L+d5oyB5pen5YiX6KGoICovCiAgICBmdW5jdGlvbiBzY2hlZHVsZURlbGF5
ZWRTa2VsKCkgewogICAgICAgIHdhaXRpbmdEYXRhID0gdHJ1ZTsKICAgICAgICB3aW5kb3cuX19kYXRh
UmVhZHkgPSBmYWxzZTsKICAgICAgICBpZiAoZW1wdHlFbCkgZW1wdHlFbC5jbGFzc0xpc3QucmVtb3Zl
KCdvbicpOwogICAgICAgIGlmICh3aW5kb3cuX19wZW5kaW5nU2tlbFRpbWVyKSB7CiAgICAgICAgICAg
IGNsZWFyVGltZW91dCh3aW5kb3cuX19wZW5kaW5nU2tlbFRpbWVyKTsKICAgICAgICAgICAgd2luZG93
Ll9fcGVuZGluZ1NrZWxUaW1lciA9IDA7CiAgICAgICAgfQogICAgICAgIHdpbmRvdy5fX3BlbmRpbmdT
a2VsU2luY2UgPSBEYXRlLm5vdygpOwogICAgICAgIC8vIOacieaXp+WIl+ihqOWwseS/neeVme+8m+ep
uuWIl+ihqOS5n+S4jeWGjeaSremqqOaetuWKqOeUuwogICAgfQogICAgZnVuY3Rpb24gY2xlYXJXYWl0
aW5nRGF0YSgpIHsKICAgICAgICB3YWl0aW5nRGF0YSA9IGZhbHNlOwogICAgICAgIGlmICh3aW5kb3cu
X19wZW5kaW5nU2tlbFRpbWVyKSB7CiAgICAgICAgICAgIGNsZWFyVGltZW91dCh3aW5kb3cuX19wZW5k
aW5nU2tlbFRpbWVyKTsKICAgICAgICAgICAgd2luZG93Ll9fcGVuZGluZ1NrZWxUaW1lciA9IDA7CiAg
ICAgICAgfQogICAgICAgIHdpbmRvdy5fX3BlbmRpbmdTa2VsU2luY2UgPSAwOwogICAgICAgIHNldEJv
b3RMb2FkaW5nKGZhbHNlKTsKICAgIH0KICAgIHdpbmRvdy5zZXRCb290TG9hZGluZyA9IHNldEJvb3RM
b2FkaW5nOwogICAgd2luZG93LmZvcmNlRW5kQm9vdExvYWRpbmcgPSBmdW5jdGlvbigpIHsKICAgICAg
ICBjbGVhcldhaXRpbmdEYXRhKCk7CiAgICAgICAgLy8gRG8gbm90IGZha2XjgIzmmoLml6DorrDlvZXj
gI1pZiBob3N0IG5ldmVyIHB1c2hlZAogICAgICAgIGlmIChob3N0UHVzaGVkT25jZSkKICAgICAgICAg
ICAgd2luZG93Ll9fZGF0YVJlYWR5ID0gdHJ1ZTsKICAgICAgICB0cnkgeyByZW5kZXIoKTsgfSBjYXRj
aCAoZSkge30KICAgIH07CiAgICAvLyBTYWZldHk6IGRyb3Agc3R1Y2sgc2tlbGV0b247IHN0aWxsIG5l
dmVyIGludmVudCBlbXB0eS1zdGF0ZSB3aXRob3V0IGhvc3QgcHVzaAogICAgc2V0VGltZW91dCgoKSA9
PiB7CiAgICAgICAgaWYgKGhvc3RQdXNoZWRPbmNlIHx8IHdpbmRvdy5fX2RhdGFSZWFkeSkgcmV0dXJu
OwogICAgICAgIGlmICghYm9vdExvYWRpbmcgJiYgIXdhaXRpbmdEYXRhKSByZXR1cm47CiAgICAgICAg
Y2xlYXJXYWl0aW5nRGF0YSgpOwogICAgICAgIHRyeSB7IHJlbmRlcigpOyB9IGNhdGNoIHt9CiAgICB9
LCA4MDAwKTsKCiAgICBmdW5jdGlvbiB1cGRhdGVUb3BCdG4oKSB7CiAgICAgICAgaWYgKCFidG5Ub3Ag
fHwgIWxpc3RFbCkgcmV0dXJuOwogICAgICAgIGJ0blRvcC5jbGFzc0xpc3QudG9nZ2xlKCdvbicsIGxp
c3RFbC5zY3JvbGxUb3AgPiA0OCk7CiAgICB9CiAgICBsZXQgX3Njcm9sbFJhZiA9IDA7CiAgICBsZXQg
X3Njcm9sbElkbGVUID0gMDsKICAgIGxldCBfbGlzdFB0ckRvd24gPSBmYWxzZTsKICAgIGxldCBfcGVu
ZGluZ0FwcGVuZCA9IG51bGw7IC8vIHsgZnJvbUxlbiB9IHF1ZXVlZCB3aGlsZSBzY3JvbGxpbmcKICAg
IHdpbmRvdy5fX3Njcm9sbEJ1c3kgPSBmYWxzZTsKICAgIHdpbmRvdy5fX3dhbnRNb3JlID0gZmFsc2U7
CgogICAgZnVuY3Rpb24gbWFya0xpc3RTY3JvbGxpbmcoKSB7CiAgICAgICAgd2luZG93Ll9fc2Nyb2xs
QnVzeSA9IHRydWU7CiAgICAgICAgdHJ5IHsgbGlzdEVsLmNsYXNzTGlzdC5hZGQoJ2lzLXNjcm9sbGlu
ZycpOyB9IGNhdGNoIHt9CiAgICAgICAgaWYgKF9zY3JvbGxJZGxlVCkgY2xlYXJUaW1lb3V0KF9zY3Jv
bGxJZGxlVCk7CiAgICAgICAgX3Njcm9sbElkbGVUID0gc2V0VGltZW91dCgoKSA9PiB7CiAgICAgICAg
ICAgIF9zY3JvbGxJZGxlVCA9IDA7CiAgICAgICAgICAgIGZsdXNoU2Nyb2xsSWRsZSgpOwogICAgICAg
IH0sIDIyMCk7CiAgICB9CgogICAgZnVuY3Rpb24gZmx1c2hTY3JvbGxJZGxlKCkgewogICAgICAgIGlm
IChfbGlzdFB0ckRvd24pIHsKICAgICAgICAgICAgbWFya0xpc3RTY3JvbGxpbmcoKTsKICAgICAgICAg
ICAgcmV0dXJuOwogICAgICAgIH0KICAgICAgICB3aW5kb3cuX19zY3JvbGxCdXN5ID0gZmFsc2U7CiAg
ICAgICAgdHJ5IHsgbGlzdEVsLmNsYXNzTGlzdC5yZW1vdmUoJ2lzLXNjcm9sbGluZycpOyB9IGNhdGNo
IHt9CiAgICAgICAgaWYgKF9wZW5kaW5nQXBwZW5kKSB7CiAgICAgICAgICAgIGNvbnN0IHBlbmRpbmcg
PSBfcGVuZGluZ0FwcGVuZDsKICAgICAgICAgICAgX3BlbmRpbmdBcHBlbmQgPSBudWxsOwogICAgICAg
ICAgICBhcHBseUFwcGVuZFBheWxvYWQocGVuZGluZyk7CiAgICAgICAgfQogICAgICAgIGlmICh3aW5k
b3cuX193YW50TW9yZSkKICAgICAgICAgICAgcmVxdWVzdE1vcmUoKTsKICAgICAgICBlbHNlIGlmICgh
bG9hZGluZ01vcmUKICAgICAgICAgICAgJiYgZGlza1RvdGFsID4gMAogICAgICAgICAgICAmJiBhbGxD
bGlwcy5sZW5ndGggPCBkaXNrVG90YWwKICAgICAgICAgICAgJiYgbGlzdEVsLnNjcm9sbFRvcCArIGxp
c3RFbC5jbGllbnRIZWlnaHQgPj0gbGlzdEVsLnNjcm9sbEhlaWdodCAtIDQyMCkKICAgICAgICAgICAg
cmVxdWVzdE1vcmUoKTsKICAgIH0KCiAgICBmdW5jdGlvbiBvbkxpc3RTY3JvbGwoKSB7CiAgICAgICAg
bWFya0xpc3RTY3JvbGxpbmcoKTsKICAgICAgICBpZiAoX3Njcm9sbFJhZikgcmV0dXJuOwogICAgICAg
IF9zY3JvbGxSYWYgPSByZXF1ZXN0QW5pbWF0aW9uRnJhbWUoKCkgPT4gewogICAgICAgICAgICBfc2Ny
b2xsUmFmID0gMDsKICAgICAgICAgICAgdHJ5IHsgaGlkZVBhdGhUaXAoKTsgfSBjYXRjaCB7fQogICAg
ICAgICAgICB1cGRhdGVUb3BCdG4oKTsKICAgICAgICAgICAgaWYgKCFsb2FkaW5nTW9yZQogICAgICAg
ICAgICAgICAgJiYgZGlza1RvdGFsID4gMAogICAgICAgICAgICAgICAgJiYgYWxsQ2xpcHMubGVuZ3Ro
IDwgZGlza1RvdGFsCiAgICAgICAgICAgICAgICAmJiBsaXN0RWwuc2Nyb2xsVG9wICsgbGlzdEVsLmNs
aWVudEhlaWdodCA+PSBsaXN0RWwuc2Nyb2xsSGVpZ2h0IC0gMjQwKQogICAgICAgICAgICAgICAgd2lu
ZG93Ll9fd2FudE1vcmUgPSB0cnVlOwogICAgICAgIH0pOwogICAgfQogICAgbGlzdEVsLmFkZEV2ZW50
TGlzdGVuZXIoJ3Njcm9sbCcsIG9uTGlzdFNjcm9sbCwgeyBwYXNzaXZlOiB0cnVlIH0pOwogICAgbGlz
dEVsLmFkZEV2ZW50TGlzdGVuZXIoJ3doZWVsJywgbWFya0xpc3RTY3JvbGxpbmcsIHsgcGFzc2l2ZTog
dHJ1ZSB9KTsKICAgIGxpc3RFbC5hZGRFdmVudExpc3RlbmVyKCdwb2ludGVyZG93bicsIGUgPT4gewog
ICAgICAgIGlmIChlLmJ1dHRvbiAhPT0gMCkgcmV0dXJuOwogICAgICAgIF9saXN0UHRyRG93biA9IHRy
dWU7CiAgICAgICAgbWFya0xpc3RTY3JvbGxpbmcoKTsKICAgIH0sIHsgcGFzc2l2ZTogdHJ1ZSB9KTsK
ICAgIHdpbmRvdy5hZGRFdmVudExpc3RlbmVyKCdwb2ludGVydXAnLCAoKSA9PiB7CiAgICAgICAgaWYg
KCFfbGlzdFB0ckRvd24pIHJldHVybjsKICAgICAgICBfbGlzdFB0ckRvd24gPSBmYWxzZTsKICAgICAg
ICBtYXJrTGlzdFNjcm9sbGluZygpOwogICAgfSwgeyBwYXNzaXZlOiB0cnVlIH0pOwogICAgd2luZG93
LmFkZEV2ZW50TGlzdGVuZXIoJ3BvaW50ZXJjYW5jZWwnLCAoKSA9PiB7CiAgICAgICAgaWYgKCFfbGlz
dFB0ckRvd24pIHJldHVybjsKICAgICAgICBfbGlzdFB0ckRvd24gPSBmYWxzZTsKICAgICAgICBtYXJr
TGlzdFNjcm9sbGluZygpOwogICAgfSwgeyBwYXNzaXZlOiB0cnVlIH0pOwogICAgYnRuVG9wLmFkZEV2
ZW50TGlzdGVuZXIoJ2NsaWNrJywgZSA9PiB7CiAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAg
ICAgICBsaXN0RWwuc2Nyb2xsVG8oeyB0b3A6IDAsIGJlaGF2aW9yOiAnc21vb3RoJyB9KTsKICAgIH0p
OwoKICAgIGZ1bmN0aW9uIHZpc2libGVMaXN0KCkgewogICAgICAgIGNvbnN0IHEgPSBTdHJpbmcocXVl
cnkgfHwgJycpLnRyaW0oKTsKICAgICAgICAvLyBIb3N0IGFscmVhZHkgZmlsdGVyZWQrZXhwYW5kZWQg
Zm9yIHRoaXMgZXhhY3QgcXVlcnkg4oCUIGRvbid0IHJlLWZpbHRlciAoYXZvaWRzIGZsYXNoIC8gZHJv
cHBlZCBmYXYgZ3JvdXBzKQogICAgICAgIGxldCBsaXN0ID0gKHEgJiYgd2luZG93Ll9faG9zdEZpbHRl
cmVkICYmIHdpbmRvdy5fX2hvc3RGaWx0ZXJRID09PSBxKQogICAgICAgICAgICA/IGFsbENsaXBzCiAg
ICAgICAgICAgIDogZmlsdGVyKGFsbENsaXBzLCBjdXJUYWIsIHF1ZXJ5KTsKICAgICAgICAvLyDmlLbo
l4/pobXvvJrmnKzlnLDlho3mu6TkuIDmrKHvvIzlj5bmtojmlLbol4/lj6/nq4vliLvmtojlpLHvvIzk
uI3lv4XnrYkgQUhLIOmHjeW7ugogICAgICAgIGlmIChjdXJUYWIgPT09ICdwaW5uZWQnKQogICAgICAg
ICAgICBsaXN0ID0gbGlzdC5maWx0ZXIoYyA9PiBpc1Bpbm5lZChjKSk7CiAgICAgICAgcmV0dXJuIGxp
c3Q7CiAgICB9CiAgICBmdW5jdGlvbiBlc2NIdG1sKHMpIHsKICAgICAgICByZXR1cm4gU3RyaW5nKHMg
Pz8gJycpLnJlcGxhY2UoLyYvZywnJmFtcDsnKS5yZXBsYWNlKC88L2csJyZsdDsnKS5yZXBsYWNlKC8+
L2csJyZndDsnKS5yZXBsYWNlKC8iL2csJyZxdW90OycpOwogICAgfQogICAgZnVuY3Rpb24gcXVlcnlU
ZXJtcyhxKSB7CiAgICAgICAgY29uc3Qgb3V0ID0gW107CiAgICAgICAgZm9yIChjb25zdCBzZWcgb2Yg
U3RyaW5nKHEgfHwgJycpLnNwbGl0KCd8JykpIHsKICAgICAgICAgICAgY29uc3QgcyA9IHNlZy50cmlt
KCk7CiAgICAgICAgICAgIGlmICghcykgY29udGludWU7CiAgICAgICAgICAgIGNvbnN0IHdvcmRzID0g
cy5zcGxpdCgvXHMrLykuZmlsdGVyKEJvb2xlYW4pOwogICAgICAgICAgICBpZiAod29yZHMubGVuZ3Ro
KSBvdXQucHVzaCguLi53b3Jkcyk7CiAgICAgICAgfQogICAgICAgIHJldHVybiBvdXQ7CiAgICB9CiAg
ICBmdW5jdGlvbiBobEh0bWwodGV4dCkgewogICAgICAgIGNvbnN0IHRlcm1zID0gcXVlcnlUZXJtcyhx
dWVyeSk7CiAgICAgICAgY29uc3QgcyA9IFN0cmluZyh0ZXh0ID8/ICcnKTsKICAgICAgICBpZiAoIXRl
cm1zLmxlbmd0aCkgcmV0dXJuIGVzY0h0bWwocyk7CiAgICAgICAgY29uc3QgbG93ZXIgPSBzLnRvTG93
ZXJDYXNlKCk7CiAgICAgICAgY29uc3QgdGVybUwgPSB0ZXJtcy5tYXAodCA9PiB0LnRvTG93ZXJDYXNl
KCkpOwogICAgICAgIGxldCBvdXQgPSAnJywgaSA9IDA7CiAgICAgICAgd2hpbGUgKGkgPCBzLmxlbmd0
aCkgewogICAgICAgICAgICBsZXQgYmVzdEogPSAtMSwgYmVzdExlbiA9IDA7CiAgICAgICAgICAgIGZv
ciAobGV0IHRpID0gMDsgdGkgPCB0ZXJtTC5sZW5ndGg7IHRpKyspIHsKICAgICAgICAgICAgICAgIGNv
bnN0IHQgPSB0ZXJtTFt0aV07CiAgICAgICAgICAgICAgICBpZiAoIXQpIGNvbnRpbnVlOwogICAgICAg
ICAgICAgICAgY29uc3QgaiA9IGxvd2VyLmluZGV4T2YodCwgaSk7CiAgICAgICAgICAgICAgICBpZiAo
aiA8IDApIGNvbnRpbnVlOwogICAgICAgICAgICAgICAgaWYgKGJlc3RKIDwgMCB8fCBqIDwgYmVzdEog
fHwgKGogPT09IGJlc3RKICYmIHQubGVuZ3RoID4gYmVzdExlbikpIHsKICAgICAgICAgICAgICAgICAg
ICBiZXN0SiA9IGo7IGJlc3RMZW4gPSB0Lmxlbmd0aDsKICAgICAgICAgICAgICAgIH0KICAgICAgICAg
ICAgfQogICAgICAgICAgICBpZiAoYmVzdEogPCAwKSB7IG91dCArPSBlc2NIdG1sKHMuc2xpY2UoaSkp
OyBicmVhazsgfQogICAgICAgICAgICBvdXQgKz0gZXNjSHRtbChzLnNsaWNlKGksIGJlc3RKKSk7CiAg
ICAgICAgICAgIG91dCArPSAnPG1hcmsgY2xhc3M9InEtaGwiPicgKyBlc2NIdG1sKHMuc2xpY2UoYmVz
dEosIGJlc3RKICsgYmVzdExlbikpICsgJzwvbWFyaz4nOwogICAgICAgICAgICBpID0gYmVzdEogKyBN
YXRoLm1heCgxLCBiZXN0TGVuKTsKICAgICAgICB9CiAgICAgICAgcmV0dXJuIG91dDsKICAgIH0KICAg
IGZ1bmN0aW9uIHNldEhsVGV4dChlbCwgdGV4dCkgewogICAgICAgIGlmICghZWwpIHJldHVybjsKICAg
ICAgICBjb25zdCBxID0gU3RyaW5nKHF1ZXJ5IHx8ICcnKS50cmltKCk7CiAgICAgICAgaWYgKCFxKSB7
CiAgICAgICAgICAgIGVsLmNsYXNzTGlzdC5yZW1vdmUoJ2hhcy1obCcpOwogICAgICAgICAgICBlbC50
ZXh0Q29udGVudCA9IHRleHQgPT0gbnVsbCA/ICcnIDogU3RyaW5nKHRleHQpOwogICAgICAgICAgICBy
ZXR1cm47CiAgICAgICAgfQogICAgICAgIGVsLmNsYXNzTGlzdC5hZGQoJ2hhcy1obCcpOwogICAgICAg
IGVsLmlubmVySFRNTCA9IGhsSHRtbCh0ZXh0KTsKICAgIH0KCgogICAgZnVuY3Rpb24gYXBwbHlUYWJT
d2l0Y2hBbmltKCkgewogICAgICAgIGlmICghdGFiU3dpdGNoQW5pbURpciB8fCAhbGlzdEVsKSByZXR1
cm47CiAgICAgICAgaWYgKCFsaXN0RWwucXVlcnlTZWxlY3RvcignLml0bSwgI2VtcHR5Lm9uLCAjbGlz
dC1tb3JlJykpCiAgICAgICAgICAgIHJldHVybjsKICAgICAgICBjb25zdCBkaXIgPSB0YWJTd2l0Y2hB
bmltRGlyOwogICAgICAgIHRhYlN3aXRjaEFuaW1EaXIgPSAwOwogICAgICAgIGxpc3RFbC5jbGFzc0xp
c3QucmVtb3ZlKCd0YWItaW4tbHInLCAndGFiLWluLXJsJyk7CiAgICAgICAgdm9pZCBsaXN0RWwub2Zm
c2V0V2lkdGg7CiAgICAgICAgbGlzdEVsLmNsYXNzTGlzdC5hZGQoZGlyID4gMCA/ICd0YWItaW4tbHIn
IDogJ3RhYi1pbi1ybCcpOwogICAgICAgIGNsZWFyVGltZW91dChsaXN0RWwuX3RhYkFuaW1UaW1lcik7
CiAgICAgICAgbGlzdEVsLl90YWJBbmltVGltZXIgPSBzZXRUaW1lb3V0KCgpID0+IHsKICAgICAgICAg
ICAgbGlzdEVsLmNsYXNzTGlzdC5yZW1vdmUoJ3RhYi1pbi1scicsICd0YWItaW4tcmwnKTsKICAgICAg
ICB9LCA0MDApOwogICAgfQoKICAgIGZ1bmN0aW9uIHRhYkluZGV4KHRhYikgewogICAgICAgIGNvbnN0
IGkgPSBUQUJfT1JERVIuaW5kZXhPZih0YWIpOwogICAgICAgIHJldHVybiBpID49IDAgPyBpIDogMDsK
ICAgIH0KCiAgICBmdW5jdGlvbiBtb3ZlVGFiSW5rKGluc3RhbnQsIHRhcmdldEVsKSB7CiAgICAgICAg
Y29uc3QgaW5rID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3RhYi1pbmsnKTsKICAgICAgICBjb25z
dCB0YWJzID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3RhYnMnKTsKICAgICAgICBjb25zdCBlbCA9
IHRhcmdldEVsIHx8IGRvY3VtZW50LnF1ZXJ5U2VsZWN0b3IoJyN0YWJzIC50YWIub24nKTsKICAgICAg
ICBpZiAoIWluayB8fCAhdGFicyB8fCAhZWwpIHJldHVybjsKICAgICAgICBjb25zdCB0ciA9IHRhYnMu
Z2V0Qm91bmRpbmdDbGllbnRSZWN0KCk7CiAgICAgICAgY29uc3QgciA9IGVsLmdldEJvdW5kaW5nQ2xp
ZW50UmVjdCgpOwogICAgICAgIGNvbnN0IHggPSByLmxlZnQgLSB0ci5sZWZ0OwogICAgICAgIGNvbnN0
IGggPSBNYXRoLm1heCgyMCwgTWF0aC5yb3VuZChyLmhlaWdodCkpOwogICAgICAgIGNvbnN0IHkgPSBy
LnRvcCAtIHRyLnRvcDsKICAgICAgICBjb25zdCB3ID0gTWF0aC5tYXgoMjQsIHIud2lkdGgpOwogICAg
ICAgIGNvbnN0IHBvcyA9ICd0cmFuc2xhdGUzZCgnICsgeCArICdweCwnICsgeSArICdweCwwKSc7CiAg
ICAgICAgaW5rLnN0eWxlLnRyYW5zZm9ybU9yaWdpbiA9ICdjZW50ZXIgYm90dG9tJzsKICAgICAgICBp
bmsuc3R5bGUud2lkdGggPSB3ICsgJ3B4JzsKICAgICAgICBpbmsuc3R5bGUuaGVpZ2h0ID0gaCArICdw
eCc7CiAgICAgICAgaWYgKGluc3RhbnQpIHsKICAgICAgICAgICAgaW5rLnN0eWxlLnRyYW5zaXRpb24g
PSAnbm9uZSc7CiAgICAgICAgICAgIGluay5jbGFzc0xpc3QucmVtb3ZlKCdzcXVhc2gnKTsKICAgICAg
ICAgICAgaW5rLnN0eWxlLnRyYW5zZm9ybSA9IHBvcyArICcgc2NhbGVYKDEpJzsKICAgICAgICAgICAg
aW5rLm9mZnNldEhlaWdodDsKICAgICAgICAgICAgaW5rLnN0eWxlLnRyYW5zaXRpb24gPSAnJzsKICAg
ICAgICAgICAgcmV0dXJuOwogICAgICAgIH0KICAgICAgICAvLyBTbmFwIHRvIGhvdmVyZWQgdGFiLCBl
eHBhbmQgZnJvbSBib3R0b20tY2VudGVyIOKAlCBubyBzbGlkaW5nIGJldHdlZW4gdGFicwogICAgICAg
IGluay5zdHlsZS50cmFuc2l0aW9uID0gJ25vbmUnOwogICAgICAgIGluay5zdHlsZS50cmFuc2Zvcm0g
PSBwb3MgKyAnIHNjYWxlWCgwLjAwMSknOwogICAgICAgIGluay5vZmZzZXRIZWlnaHQ7CiAgICAgICAg
aW5rLnN0eWxlLnRyYW5zaXRpb24gPSAnJzsKICAgICAgICBpbmsuY2xhc3NMaXN0LmFkZCgnc3F1YXNo
Jyk7CiAgICAgICAgaW5rLnN0eWxlLnRyYW5zZm9ybSA9IHBvcyArICcgc2NhbGVYKDEpJzsKICAgICAg
ICBjbGVhclRpbWVvdXQoaW5rLl9zcXVhc2hUaW1lcik7CiAgICAgICAgaW5rLl9zcXVhc2hUaW1lciA9
IHNldFRpbWVvdXQoKCkgPT4gaW5rLmNsYXNzTGlzdC5yZW1vdmUoJ3NxdWFzaCcpLCAzNDApOwogICAg
fQogICAgZnVuY3Rpb24gbWFya1RhYih0YWIsIGluc3RhbnQpIHsKICAgICAgICBkb2N1bWVudC5xdWVy
eVNlbGVjdG9yQWxsKCcjdGFicyAudGFiJykuZm9yRWFjaChlbCA9PgogICAgICAgICAgICBlbC5jbGFz
c0xpc3QudG9nZ2xlKCdvbicsIGVsLmRhdGFzZXQudGFiID09PSB0YWIpKTsKICAgICAgICBjb25zdCBh
cHAgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYXBwJyk7CiAgICAgICAgaWYgKGFwcCkgYXBwLmRh
dGFzZXQudGFiID0gdGFiIHx8ICdhbGwnOwogICAgICAgIG1vdmVUYWJJbmsoISFpbnN0YW50KTsKICAg
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
ICAgbG9hZGluZ01vcmUgPSBmYWxzZTsKICAgICAgICBtYXJrVGFiKHRhYik7CiAgICAgICAgLy8g5omT
5byA5pS26JeP5bm25p+l55yL5ZCO77yM5riF6Zmk44CM5paw5pS26JeP44CN57u/54K5CiAgICAgICAg
aWYgKHRhYiA9PT0gJ3Bpbm5lZCcpCiAgICAgICAgICAgIGNsZWFyRmF2VW5zZWVuKCk7CgogICAgICAg
IC8vIEtlZXAgc2VhcmNoICJ0b2RheSIgZmlsdGVyIGluIHN5bmMgd2hlbiBzZWFyY2ggaXMgb3Blbgog
ICAgICAgIHRyeSB7CiAgICAgICAgICAgIGNvbnN0IHdyYXAgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJ
ZCgnc2VhcmNoLXdyYXAnKTsKICAgICAgICAgICAgY29uc3QgYnRuVG9kYXkgPSBkb2N1bWVudC5nZXRF
bGVtZW50QnlJZCgnYnRuLXRvZGF5Jyk7CiAgICAgICAgICAgIGlmICh3cmFwICYmIHdyYXAuY2xhc3NM
aXN0LmNvbnRhaW5zKCdvcGVuJykpIHsKICAgICAgICAgICAgICAgIGNvbnN0IHdhbnRUb2RheSA9IGZh
bHNlOwogICAgICAgICAgICAgICAgaWYgKHRvZGF5T25seSAhPT0gd2FudFRvZGF5KSB7CiAgICAgICAg
ICAgICAgICAgICAgdG9kYXlPbmx5ID0gd2FudFRvZGF5OwogICAgICAgICAgICAgICAgICAgIGlmIChi
dG5Ub2RheSkgYnRuVG9kYXkuY2xhc3NMaXN0LnRvZ2dsZSgnb24nLCB0b2RheU9ubHkpOwogICAgICAg
ICAgICAgICAgfQogICAgICAgICAgICB9CiAgICAgICAgfSBjYXRjaCB7fQoKICAgICAgICBzZWxlY3Rl
ZElkID0gbnVsbDsKICAgICAgICBtdWx0aUlkcyA9IFtdOwogICAgICAgIGxpc3RFbC5zY3JvbGxUb3Ag
PSAwOwogICAgICAgIGNvbnN0IGhpdCA9IHZpZXdNZW0uZ2V0KHZpZXdNZW1LZXkodGFiLCBxdWVyeSwg
dG9kYXlPbmx5KSk7CiAgICAgICAgaWYgKGhpdCAmJiBBcnJheS5pc0FycmF5KGhpdC5pdGVtcykgJiYg
aGl0Lml0ZW1zLmxlbmd0aCkgewogICAgICAgICAgICBhbGxDbGlwcyA9IGhpdC5pdGVtcy5zbGljZSgp
OwogICAgICAgICAgICBkaXNrVG90YWwgPSBOdW1iZXIoaGl0LnRvdGFsKSB8fCBoaXQuaXRlbXMubGVu
Z3RoOwogICAgICAgICAgICB3aW5kb3cuX193YWl0aW5nVmlldyA9IGZhbHNlOwogICAgICAgICAgICBj
bGVhcldhaXRpbmdEYXRhKCk7CiAgICAgICAgICAgIHdpbmRvdy5fX2RhdGFSZWFkeSA9IHRydWU7CiAg
ICAgICAgICAgIGhvc3RQdXNoZWRPbmNlID0gdHJ1ZTsKICAgICAgICAgICAgc2F3Tm9uRW1wdHkgPSB0
cnVlOwogICAgICAgICAgICByZW5kZXIoKTsKICAgICAgICAgICAgYXBwbHlUYWJTd2l0Y2hBbmltKCk7
CiAgICAgICAgICAgIC8vIE1lbW9yeSBwYWludCBmaXJzdCDigJRiYWNrZ3JvdW5kIHNvZnQtc3luYyBr
ZWVwcyBBSEsgaW4gc3RlcCB3aXRob3V0IGRvdWJsZSByZWRyYXcKICAgICAgICAgICAgc29mdFJlcXVl
c3RWaWV3KCk7CiAgICAgICAgICAgIHJldHVybjsKICAgICAgICB9CiAgICAgICAgLy8gTm8gY2FjaGUg
eWV0OiBrZWVwIGN1cnJlbnQgcm93cyDigJQgTkVWRVIgd2lwZSB0byBibGFuayB3aGl0ZQogICAgICAg
IHdpbmRvdy5fX3dhaXRpbmdWaWV3ID0gdHJ1ZTsKICAgICAgICBzY2hlZHVsZURlbGF5ZWRTa2VsKCk7
CiAgICAgICAgaWYgKCFhbGxDbGlwcy5sZW5ndGgpCiAgICAgICAgICAgIHJlbmRlcigpOwogICAgICAg
IHJlcXVlc3RWaWV3KCk7CiAgICAgICAgYXBwbHlUYWJTd2l0Y2hBbmltKCk7CiAgICB9CgogICAgbW92
ZVRhYkluayh0cnVlKTsKICAgIGJpbmRUYWJJbmtIb3ZlcigpOwogICAgdHJ5IHsgbmV3IFJlc2l6ZU9i
c2VydmVyKCgpID0+IG1vdmVUYWJJbmsodHJ1ZSkpLm9ic2VydmUoZG9jdW1lbnQuZ2V0RWxlbWVudEJ5
SWQoJ3RhYnMnKSk7IH0gY2F0Y2gge30KICAgIHdpbmRvdy5hZGRFdmVudExpc3RlbmVyKCdyZXNpemUn
LCAoKSA9PiBtb3ZlVGFiSW5rKHRydWUpKTsKCiAgICBmdW5jdGlvbiB1cGRhdGVNb3JlRm9vdGVyKHRv
dGFsKSB7CiAgICAgICAgbGV0IG1vcmVFbCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdsaXN0LW1v
cmUnKTsKICAgICAgICBjb25zdCBsb2FkZWQgPSBhbGxDbGlwcy5sZW5ndGg7CiAgICAgICAgaWYgKGxv
YWRlZCA+PSB0b3RhbCkgewogICAgICAgICAgICBpZiAobW9yZUVsKSBtb3JlRWwucmVtb3ZlKCk7CiAg
ICAgICAgICAgIHJldHVybjsKICAgICAgICB9CiAgICAgICAgaWYgKCFtb3JlRWwpIHsKICAgICAgICAg
ICAgbW9yZUVsID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnZGl2Jyk7CiAgICAgICAgICAgIG1vcmVF
bC5pZCA9ICdsaXN0LW1vcmUnOwogICAgICAgICAgICBtb3JlRWwuY2xhc3NOYW1lID0gJ2xpc3QtbW9y
ZSc7CiAgICAgICAgICAgIGxpc3RFbC5hcHBlbmRDaGlsZChtb3JlRWwpOwogICAgICAgIH0KICAgICAg
ICBtb3JlRWwudGV4dENvbnRlbnQgPSAn57un57ut5LiL5ruR5LuO56OB55uY5Yqg6L2977yIJyArIGxv
YWRlZCArICcvJyArIHRvdGFsICsgJ++8iSc7CiAgICB9CgogICAgLyoqIFVwZGF0ZSBiYXIgLyBwaW4g
YmFkZ2Ugd2l0aG91dCB0b3VjaGluZyB0aGUgbGlzdCBET00gKi8KICAgIGZ1bmN0aW9uIHJlZnJlc2hM
aXN0Q2hyb21lKCkgewogICAgICAgIGNvbnN0IHZpc2libGUgPSB2aXNpYmxlTGlzdCgpOwogICAgICAg
IGNvbnN0IGxvYWRlZCA9IGFsbENsaXBzLmxlbmd0aDsKICAgICAgICBjb25zdCBzaG93bkNvdW50ID0g
dmlzaWJsZS5sZW5ndGg7CiAgICAgICAgbGV0IHBpbm5lZE4gPSBOdW1iZXIocGlubmVkVG90YWwpIHx8
IDA7CiAgICAgICAgaWYgKHBpbm5lZE4gPCAxKSB7CiAgICAgICAgICAgIGlmIChjdXJUYWIgPT09ICdw
aW5uZWQnKQogICAgICAgICAgICAgICAgcGlubmVkTiA9IE1hdGgubWF4KE51bWJlcihkaXNrVG90YWwp
IHx8IDAsIGxvYWRlZCk7CiAgICAgICAgICAgIGVsc2UKICAgICAgICAgICAgICAgIHBpbm5lZE4gPSBh
bGxDbGlwcy5maWx0ZXIoYyA9PiBpc1Bpbm5lZChjKSkubGVuZ3RoOwogICAgICAgIH0KICAgICAgICB1
cGRhdGVQaW5Eb3QoKTsKICAgICAgICBsZXQgc2hvd1RvdGFsID0gZGlza1RvdGFsID4gMCA/IGRpc2tU
b3RhbCA6IChsb2FkZWQgfHwgMCk7CiAgICAgICAgaWYgKGN1clRhYiA9PT0gJ3Bpbm5lZCcgJiYgcGlu
bmVkTiA+IHNob3dUb3RhbCkKICAgICAgICAgICAgc2hvd1RvdGFsID0gcGlubmVkTjsKICAgICAgICBj
b25zdCBxT24gPSBTdHJpbmcocXVlcnkgfHwgJycpLnRyaW0oKS5sZW5ndGggPiAwOwogICAgICAgIGNv
bnN0IGJhciA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdiYXItdHh0Jyk7CiAgICAgICAgaWYgKGJh
cikgewogICAgICAgICAgICBiYXIudGV4dENvbnRlbnQgPSBxT24KICAgICAgICAgICAgICAgID8gKHNo
b3duQ291bnQgKyAnIOadoScpCiAgICAgICAgICAgICAgICA6IChzaG93VG90YWwgPiBsb2FkZWQgPyAo
c2hvd25Db3VudCArICcgLyAnICsgc2hvd1RvdGFsICsgJyDmnaEnKSA6IChzaG93VG90YWwgKyAnIOad
oScpKTsKICAgICAgICB9CiAgICAgICAgdXBkYXRlTW9yZUZvb3RlcihkaXNrVG90YWwpOwogICAgICAg
IHVwZGF0ZVRvcEJ0bigpOwogICAgfQoKICAgIC8qKgogICAgICogTG9hZC1tb3JlOiBhcHBlbmQgb25s
eSBuZXcgRE9NIG5vZGVzLiBGdWxsIHJlbmRlcigpIG51a2VzIGV2ZXJ5IC5pdG0gYW5kCiAgICAgKiBy
ZXN0b3JlcyBzY3JvbGxUb3Ag4oCUIHRoYXQgaGl0Y2ggaXMgd2hhdCBtYWtlcyBkcmFnZ2luZyB0aGUg
c2Nyb2xsYmFyIGZlZWwgc3RpY2t5LgogICAgICovCiAgICBmdW5jdGlvbiBhcHBlbmRSZW5kZXIocHJl
dkxlbikgewogICAgICAgIGNvbnN0IHZpc2libGUgPSB2aXNpYmxlTGlzdCgpOwogICAgICAgIGlmICgh
dmlzaWJsZS5sZW5ndGgpIHsKICAgICAgICAgICAgcmVuZGVyKCk7CiAgICAgICAgICAgIHJldHVybiBm
YWxzZTsKICAgICAgICB9CiAgICAgICAgaWYgKHByZXZMZW4gPiAwICYmIHByZXZMZW4gPCBhbGxDbGlw
cy5sZW5ndGgpIHsKICAgICAgICAgICAgY29uc3Qgc2VhbUdpZHMgPSBuZXcgU2V0KCk7CiAgICAgICAg
ICAgIGZvciAobGV0IGkgPSBNYXRoLm1heCgwLCBwcmV2TGVuIC0gOCk7IGkgPCBNYXRoLm1pbihhbGxD
bGlwcy5sZW5ndGgsIHByZXZMZW4gKyA4KTsgaSsrKSB7CiAgICAgICAgICAgICAgICBjb25zdCBnID0g
ZmF2R3JvdXBPZihhbGxDbGlwc1tpXSk7CiAgICAgICAgICAgICAgICBpZiAoZykgc2VhbUdpZHMuYWRk
KGcpOwogICAgICAgICAgICB9CiAgICAgICAgICAgIGlmIChzZWFtR2lkcy5zaXplKSB7CiAgICAgICAg
ICAgICAgICBmb3IgKGNvbnN0IGcgb2Ygc2VhbUdpZHMpIHsKICAgICAgICAgICAgICAgICAgICBsZXQg
YmVmb3JlID0gMCwgYWZ0ZXIgPSAwOwogICAgICAgICAgICAgICAgICAgIGZvciAobGV0IGkgPSAwOyBp
IDwgYWxsQ2xpcHMubGVuZ3RoOyBpKyspIHsKICAgICAgICAgICAgICAgICAgICAgICAgaWYgKGZhdkdy
b3VwT2YoYWxsQ2xpcHNbaV0pICE9PSBnKSBjb250aW51ZTsKICAgICAgICAgICAgICAgICAgICAgICAg
aWYgKGkgPCBwcmV2TGVuKSBiZWZvcmUrKzsKICAgICAgICAgICAgICAgICAgICAgICAgZWxzZSBhZnRl
cisrOwogICAgICAgICAgICAgICAgICAgIH0KICAgICAgICAgICAgICAgICAgICBpZiAoYmVmb3JlID4g
MCAmJiBhZnRlciA+IDApIHsKICAgICAgICAgICAgICAgICAgICAgICAgcmVuZGVyKCk7CiAgICAgICAg
ICAgICAgICAgICAgICAgIHJldHVybiBmYWxzZTsKICAgICAgICAgICAgICAgICAgICB9CiAgICAgICAg
ICAgICAgICB9CiAgICAgICAgICAgIH0KICAgICAgICB9CiAgICAgICAgY29uc3QgYmxvY2tzID0gYnVp
bGRQaW5uZWRCbG9ja3ModmlzaWJsZSk7CiAgICAgICAgY29uc3QgZXhpc3RpbmcgPSBsaXN0RWwucXVl
cnlTZWxlY3RvckFsbCgnLml0bScpLmxlbmd0aDsKICAgICAgICBpZiAoZXhpc3RpbmcgPCAxKSB7CiAg
ICAgICAgICAgIHJlbmRlcigpOwogICAgICAgICAgICByZXR1cm4gZmFsc2U7CiAgICAgICAgfQogICAg
ICAgIGlmIChibG9ja3MubGVuZ3RoIDw9IGV4aXN0aW5nKSB7CiAgICAgICAgICAgIHJlZnJlc2hMaXN0
Q2hyb21lKCk7CiAgICAgICAgICAgIHRyeSB7IG1hcmtRdWV1ZVJhaWxzKCk7IH0gY2F0Y2ggKGUpIHt9
CiAgICAgICAgICAgIHJldHVybiB0cnVlOwogICAgICAgIH0KICAgICAgICBjb25zdCBmcmFnID0gZG9j
dW1lbnQuY3JlYXRlRG9jdW1lbnRGcmFnbWVudCgpOwogICAgICAgIGxldCBudW0gPSAwOwogICAgICAg
IGJsb2Nrcy5mb3JFYWNoKGIgPT4gewogICAgICAgICAgICBudW0gKz0gMTsKICAgICAgICAgICAgaWYg
KG51bSA8PSBleGlzdGluZykgcmV0dXJuOwogICAgICAgICAgICBpZiAoYi5raW5kID09PSAnZ3JvdXAn
ICYmIGIuaXRlbXMubGVuZ3RoID4gMSkKICAgICAgICAgICAgICAgIGZyYWcuYXBwZW5kQ2hpbGQobWFr
ZUdyb3VwSXRlbShiLml0ZW1zLCBudW0pKTsKICAgICAgICAgICAgZWxzZQogICAgICAgICAgICAgICAg
ZnJhZy5hcHBlbmRDaGlsZChtYWtlSXRlbShiLml0ZW1zWzBdLCBudW0pKTsKICAgICAgICB9KTsKICAg
ICAgICBjb25zdCBtb3JlRWwgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbGlzdC1tb3JlJyk7CiAg
ICAgICAgaWYgKG1vcmVFbCkKICAgICAgICAgICAgbGlzdEVsLmluc2VydEJlZm9yZShmcmFnLCBtb3Jl
RWwpOwogICAgICAgIGVsc2UKICAgICAgICAgICAgbGlzdEVsLmFwcGVuZENoaWxkKGZyYWcpOwogICAg
ICAgIHRyeSB7IG1hcmtRdWV1ZVJhaWxzKCk7IH0gY2F0Y2ggKGUpIHt9CiAgICAgICAgcmVmcmVzaExp
c3RDaHJvbWUoKTsKICAgICAgICByZXF1ZXN0QW5pbWF0aW9uRnJhbWUoKCkgPT4gewogICAgICAgICAg
ICBpZiAoYWxsQ2xpcHMubGVuZ3RoIDwgZGlza1RvdGFsCiAgICAgICAgICAgICAgICAmJiBsaXN0RWwu
c2Nyb2xsSGVpZ2h0IDw9IGxpc3RFbC5jbGllbnRIZWlnaHQgKyAyMCkKICAgICAgICAgICAgICAgIHJl
cXVlc3RNb3JlKCk7CiAgICAgICAgICAgIHRyeSB7IHNjaGVkdWxlRmlsZUdvbmVDaGVjaygpOyB9IGNh
dGNoIHt9CiAgICAgICAgfSk7CiAgICAgICAgcmV0dXJuIHRydWU7CiAgICB9CgogICAgZnVuY3Rpb24g
YXBwbHlBcHBlbmRQYXlsb2FkKHBlbmRpbmcpIHsKICAgICAgICBpZiAoIXBlbmRpbmcgfHwgcGVuZGlu
Zy5mcm9tTGVuID09IG51bGwpIHJldHVybjsKICAgICAgICBjb25zdCBmcm9tTGVuID0gTnVtYmVyKHBl
bmRpbmcuZnJvbUxlbikgfHwgMDsKICAgICAgICBpZiAoZnJvbUxlbiA8IDAgfHwgYWxsQ2xpcHMubGVu
Z3RoIDw9IGZyb21MZW4pIHsKICAgICAgICAgICAgcmVmcmVzaExpc3RDaHJvbWUoKTsKICAgICAgICAg
ICAgcmV0dXJuOwogICAgICAgIH0KICAgICAgICBhcHBlbmRSZW5kZXIoZnJvbUxlbik7CiAgICB9Cgog
ICAgZnVuY3Rpb24gbmF2TGlzdCgpIHsKICAgICAgICBjb25zdCBibG9ja3MgPSBidWlsZFBpbm5lZEJs
b2Nrcyh2aXNpYmxlTGlzdCgpKTsKICAgICAgICBjb25zdCBvdXQgPSBbXTsKICAgICAgICBmb3IgKGNv
bnN0IGIgb2YgYmxvY2tzKSB7CiAgICAgICAgICAgIGlmICghYiB8fCAhYi5pdGVtcykgY29udGludWU7
CiAgICAgICAgICAgIGZvciAoY29uc3QgYyBvZiBiLml0ZW1zKSBvdXQucHVzaChjKTsKICAgICAgICB9
CiAgICAgICAgcmV0dXJuIG91dDsKICAgIH0KCiAgICBmdW5jdGlvbiBzZWxlY3RCeUluZGV4KGlkeCkg
ewogICAgICAgIGNvbnN0IHZpcyA9IG5hdkxpc3QoKTsKICAgICAgICBpZiAoIXZpcy5sZW5ndGgpIHJl
dHVybjsKICAgICAgICBpZHggPSBNYXRoLm1heCgwLCBNYXRoLm1pbih2aXMubGVuZ3RoIC0gMSwgaWR4
KSk7CiAgICAgICAgaWYgKGlkeCA+PSB2aXMubGVuZ3RoIC0gMSAmJiBhbGxDbGlwcy5sZW5ndGggPCBk
aXNrVG90YWwpCiAgICAgICAgICAgIHJlcXVlc3RNb3JlKCk7CiAgICAgICAgc2VsZWN0ZWRJZCA9IHZp
c1tNYXRoLm1pbihpZHgsIHZpcy5sZW5ndGggLSAxKV0uaWQ7CiAgICAgICAgcmFuZ2VBbmNob3JJZCA9
IHNlbGVjdGVkSWQ7CiAgICAgICAgcmFuZ2VBbmNob3JDbGlja2VkID0gZmFsc2U7CiAgICAgICAgaWYg
KCtzZWxlY3RlZElkICE9PSArbGFzdFBhc3RlSWQpCiAgICAgICAgICAgIGxvY2F0ZUFjdGl2ZSA9IGZh
bHNlOwogICAgICAgIHVwZGF0ZUxvY2F0ZUJ0bigpOwogICAgICAgIHN5bmNJdGVtSGlnaGxpZ2h0KCk7
CiAgICAgICAgY29uc3QgZWwgPSBsaXN0RWwucXVlcnlTZWxlY3RvcignLm1nLXJvd1tkYXRhLWlkPSIn
ICsgc2VsZWN0ZWRJZCArICciXScpCiAgICAgICAgICAgIHx8IGxpc3RFbC5xdWVyeVNlbGVjdG9yKCcu
aXRtW2RhdGEtaWQ9IicgKyBzZWxlY3RlZElkICsgJyJdJyk7CiAgICAgICAgaWYgKGVsKSBlbC5zY3Jv
bGxJbnRvVmlldyh7IGJsb2NrOiAnbmVhcmVzdCcgfSk7CiAgICB9CgogICAgZnVuY3Rpb24gc2VsZWN0
ZWRJbmRleCgpIHsKICAgICAgICByZXR1cm4gbmF2TGlzdCgpLmZpbmRJbmRleChjID0+IGMuaWQgPT0g
c2VsZWN0ZWRJZCk7CiAgICB9CgogICAgZnVuY3Rpb24gc3luY0l0ZW1IaWdobGlnaHQoKSB7CiAgICAg
ICAgZG9jdW1lbnQucXVlcnlTZWxlY3RvckFsbCgnLml0bScpLmZvckVhY2gobiA9PiB7CiAgICAgICAg
ICAgIGlmIChuLmNsYXNzTGlzdC5jb250YWlucygnaXQtZ3JvdXAnKSkgewogICAgICAgICAgICAgICAg
Y29uc3Qgcm93cyA9IFsuLi5uLnF1ZXJ5U2VsZWN0b3JBbGwoJy5tZy1yb3cnKV07CiAgICAgICAgICAg
ICAgICBjb25zdCBpZHMgPSByb3dzLm1hcChyID0+ICtyLmRhdGFzZXQuaWQpOwogICAgICAgICAgICAg
ICAgY29uc3QgYW55U2VsID0gaWRzLmluY2x1ZGVzKCtzZWxlY3RlZElkKSB8fCBpZHMuc29tZShpZCA9
PiBtdWx0aUlkcy5pbmNsdWRlcyhpZCkpOwogICAgICAgICAgICAgICAgbi5jbGFzc0xpc3QudG9nZ2xl
KCdzZWwnLCBhbnlTZWwpOwogICAgICAgICAgICAgICAgbi5jbGFzc0xpc3QudG9nZ2xlKCdtdWx0aScs
IGlkcy5zb21lKGlkID0+IG11bHRpSWRzLmluY2x1ZGVzKGlkKSkpOwogICAgICAgICAgICAgICAgcm93
cy5mb3JFYWNoKHIgPT4gewogICAgICAgICAgICAgICAgICAgIGNvbnN0IGlkID0gK3IuZGF0YXNldC5p
ZDsKICAgICAgICAgICAgICAgICAgICBjb25zdCBpbk11bHRpID0gbXVsdGlJZHMuaW5jbHVkZXMoaWQp
OwogICAgICAgICAgICAgICAgICAgIHIuY2xhc3NMaXN0LnRvZ2dsZSgnc2VsJywgaWQgPT0gc2VsZWN0
ZWRJZCB8fCBpbk11bHRpKTsKICAgICAgICAgICAgICAgICAgICByLmNsYXNzTGlzdC50b2dnbGUoJ211
bHRpJywgaW5NdWx0aSk7CiAgICAgICAgICAgICAgICB9KTsKICAgICAgICAgICAgICAgIHJldHVybjsK
ICAgICAgICAgICAgfQogICAgICAgICAgICBjb25zdCBpZCA9ICtuLmRhdGFzZXQuaWQ7CiAgICAgICAg
ICAgIGNvbnN0IGluTXVsdGkgPSBtdWx0aUlkcy5pbmNsdWRlcyhpZCk7CiAgICAgICAgICAgIG4uY2xh
c3NMaXN0LnRvZ2dsZSgnc2VsJywgaWQgPT0gc2VsZWN0ZWRJZCB8fCBpbk11bHRpKTsKICAgICAgICAg
ICAgbi5jbGFzc0xpc3QudG9nZ2xlKCdtdWx0aScsIGluTXVsdGkpOwogICAgICAgIH0pOwogICAgfQog
ICAgZnVuY3Rpb24gdXBkYXRlTXVsdGlCYWRnZSgpIHsKICAgICAgICBjb25zdCBiYXIgPSBkb2N1bWVu
dC5nZXRFbGVtZW50QnlJZCgnbXVsdGktYmFyJyk7CiAgICAgICAgY29uc3QgZWwgPSBkb2N1bWVudC5n
ZXRFbGVtZW50QnlJZCgnbXVsdGktY250Jyk7CiAgICAgICAgaWYgKG11bHRpSWRzLmxlbmd0aCA+IDAp
IHsKICAgICAgICAgICAgaWYgKGVsKSBlbC50ZXh0Q29udGVudCA9IFN0cmluZyhtdWx0aUlkcy5sZW5n
dGgpOwogICAgICAgICAgICBpZiAoYmFyKSB7CiAgICAgICAgICAgICAgICBjb25zdCB3YXNPZmYgPSAh
YmFyLmNsYXNzTGlzdC5jb250YWlucygnb24nKTsKICAgICAgICAgICAgICAgIGJhci5jbGFzc0xpc3Qu
YWRkKCdvbicpOwogICAgICAgICAgICAgICAgaWYgKHdhc09mZikgcmVzZXRQYXN0ZVNlcERlZmF1bHQo
KTsKICAgICAgICAgICAgfQogICAgICAgIH0gZWxzZSB7CiAgICAgICAgICAgIGlmIChiYXIpIGJhci5j
bGFzc0xpc3QucmVtb3ZlKCdvbicpOwogICAgICAgICAgICBjbG9zZVNlcE1lbnUoKTsKICAgICAgICB9
CiAgICAgICAgc3luY0l0ZW1IaWdobGlnaHQoKTsKICAgIH0KCiAgICBjb25zdCBTRVBfTkVXTElORV9U
T0tFTiA9ICdb5o2i6KGMXSc7CiAgICAvLyDlm7rlrprluLjnlKjliIbpmpTnrKbvvJvoh6rlrprkuYnk
uI3ov5vliJfooagKICAgIGNvbnN0IFNFUF9MSVNUID0gWycgJywgU0VQX05FV0xJTkVfVE9LRU4sICcs
JywgJywgJywgJ+OAgScsICd8JywgJ1siIiwiIl0nLCAiKCcnLCcnKSJdOwogICAgbGV0IHBhc3RlU2Vw
VmFsdWUgPSAnICc7CgogICAgZnVuY3Rpb24gbm9ybWFsaXplU2VwSW5wdXQocmF3KSB7CiAgICAgICAg
bGV0IHMgPSBTdHJpbmcocmF3ID8/ICcnKTsKICAgICAgICBpZiAocyA9PT0gJycpIHJldHVybiAnICc7
CiAgICAgICAgY29uc3QgdCA9IHMudHJpbSgpOwogICAgICAgIGlmICh0ID09PSBTRVBfTkVXTElORV9U
T0tFTiB8fCB0ID09PSAn5o2i6KGMJyB8fCB0ID09PSAnXFxuJyB8fCB0ID09PSAnXG4nIHx8IHQgPT09
ICdcclxuJykKICAgICAgICAgICAgcmV0dXJuIFNFUF9ORVdMSU5FX1RPS0VOOwogICAgICAgIGlmICh0
ID09PSAnXFx0JyB8fCB0ID09PSAnXHQnKSByZXR1cm4gJ1x0JzsKICAgICAgICByZXR1cm4gczsKICAg
IH0KICAgIGZ1bmN0aW9uIHNlcFRvQWN0dWFsKHJhdykgewogICAgICAgIGNvbnN0IHMgPSBub3JtYWxp
emVTZXBJbnB1dChyYXcpOwogICAgICAgIHJldHVybiBzID09PSBTRVBfTkVXTElORV9UT0tFTiA/ICdc
bicgOiBzOwogICAgfQogICAgZnVuY3Rpb24gc2VwVG9CcmlkZ2UocmF3KSB7CiAgICAgICAgY29uc3Qg
cyA9IG5vcm1hbGl6ZVNlcElucHV0KHJhdyk7CiAgICAgICAgaWYgKHMgPT09IFNFUF9ORVdMSU5FX1RP
S0VOIHx8IHMgPT09ICdcbicgfHwgcyA9PT0gJ1xyXG4nKSByZXR1cm4gU0VQX05FV0xJTkVfVE9LRU47
CiAgICAgICAgaWYgKHMgPT09ICdcdCcpIHJldHVybiAnW+WItuihqOespl0nOwogICAgICAgIHJldHVy
biBzOwogICAgfQogICAgZnVuY3Rpb24gc2VwRGlzcGxheVN5bWJvbChyYXcpIHsKICAgICAgICBjb25z
dCBzID0gbm9ybWFsaXplU2VwSW5wdXQocmF3KTsKICAgICAgICBpZiAocyA9PT0gJyAnKSByZXR1cm4g
J+KQoyc7CiAgICAgICAgaWYgKHMgPT09IFNFUF9ORVdMSU5FX1RPS0VOIHx8IHMgPT09ICdcbicgfHwg
cyA9PT0gJ1xyXG4nKSByZXR1cm4gJ+KGtSc7CiAgICAgICAgaWYgKHMgPT09ICdcdCcpIHJldHVybiAn
4oelJzsKICAgICAgICBpZiAocyA9PT0gJywnKSByZXR1cm4gJywnOwogICAgICAgIGlmIChzID09PSAn
LCAnKSByZXR1cm4gJyzikKMnOwogICAgICAgIGlmIChzID09PSAn44CBJykgcmV0dXJuICfjgIEnOwog
ICAgICAgIGlmIChzID09PSAnfCcpIHJldHVybiAnfCc7CiAgICAgICAgaWYgKHMgPT09ICdbIiIsIiJd
JykgcmV0dXJuICdbIiIsIiJdJzsKICAgICAgICBpZiAocyA9PT0gIignJywnJykiKSByZXR1cm4gIign
JywnJykiOwogICAgICAgIHJldHVybiBzLnJlcGxhY2UoL1xyXG4vZywgJ+KGtScpLnJlcGxhY2UoL1xu
L2csICfihrUnKS5yZXBsYWNlKC9cdC9nLCAn4oelJykucmVwbGFjZSgvXHIvZywgJycpOwogICAgfQog
ICAgZnVuY3Rpb24gc2VwRGlzcGxheU5hbWUocmF3KSB7CiAgICAgICAgY29uc3QgcyA9IG5vcm1hbGl6
ZVNlcElucHV0KHJhdyk7CiAgICAgICAgaWYgKHMgPT09ICcgJykgcmV0dXJuICfnqbrmoLwnOwogICAg
ICAgIGlmIChzID09PSBTRVBfTkVXTElORV9UT0tFTiB8fCBzID09PSAnXG4nIHx8IHMgPT09ICdcclxu
JykgcmV0dXJuICfmjaLooYwnOwogICAgICAgIGlmIChzID09PSAnXHQnKSByZXR1cm4gJ+WItuihqOes
pic7CiAgICAgICAgaWYgKHMgPT09ICcsJykgcmV0dXJuICfpgJflj7cnOwogICAgICAgIGlmIChzID09
PSAnLCAnKSByZXR1cm4gJ+mAl+WPt+epuuagvCc7CiAgICAgICAgaWYgKHMgPT09ICfjgIEnKSByZXR1
cm4gJ+mhv+WPtyc7CiAgICAgICAgaWYgKHMgPT09ICd8JykgcmV0dXJuICfnq5bnur8nOwogICAgICAg
IGlmIChzID09PSAnWyIiLCIiXScpIHJldHVybiAn5YiX6KGoMSc7CiAgICAgICAgaWYgKHMgPT09ICIo
JycsJycpIikgcmV0dXJuICfliJfooagyJzsKICAgICAgICByZXR1cm4gJyc7CiAgICB9CiAgICBmdW5j
dGlvbiBmaWxsU2VwTWVudUl0ZW0oYnRuLCB2KSB7CiAgICAgICAgYnRuLmlubmVySFRNTCA9ICcnOwog
ICAgICAgIGNvbnN0IHN5bSA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ3NwYW4nKTsKICAgICAgICBz
eW0uY2xhc3NOYW1lID0gJ3Bhc3RlLXNlcC1zeW0nICsgKHNlcERpc3BsYXlOYW1lKHYpID8gJycgOiAn
IG9ubHknKTsKICAgICAgICBzeW0udGV4dENvbnRlbnQgPSBzZXBEaXNwbGF5U3ltYm9sKHYpOwogICAg
ICAgIGJ0bi5hcHBlbmRDaGlsZChzeW0pOwogICAgICAgIGNvbnN0IG5hbWUgPSBzZXBEaXNwbGF5TmFt
ZSh2KTsKICAgICAgICBpZiAobmFtZSkgewogICAgICAgICAgICBjb25zdCBsYWIgPSBkb2N1bWVudC5j
cmVhdGVFbGVtZW50KCdzcGFuJyk7CiAgICAgICAgICAgIGxhYi5jbGFzc05hbWUgPSAncGFzdGUtc2Vw
LW5hbWUnOwogICAgICAgICAgICBsYWIudGV4dENvbnRlbnQgPSBuYW1lOwogICAgICAgICAgICBidG4u
YXBwZW5kQ2hpbGQobGFiKTsKICAgICAgICB9CiAgICB9CiAgICBmdW5jdGlvbiB1cGRhdGVTZXBMYWJl
bCgpIHsKICAgICAgICBjb25zdCBsYWIgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgncGFzdGUtc2Vw
LWxhYmVsJyk7CiAgICAgICAgaWYgKGxhYikgbGFiLnRleHRDb250ZW50ID0gc2VwRGlzcGxheVN5bWJv
bChwYXN0ZVNlcFZhbHVlKTsKICAgIH0KICAgIGZ1bmN0aW9uIGFwcGx5U2VwYXJhdG9yKHJhdywgb3B0
cyA9IHt9KSB7CiAgICAgICAgY29uc3QgZG9QYXN0ZSA9IG9wdHMucGFzdGUgIT0gbnVsbCA/IG9wdHMu
cGFzdGUgOiBtdWx0aUlkcy5sZW5ndGggPiAwOwogICAgICAgIHBhc3RlU2VwVmFsdWUgPSBub3JtYWxp
emVTZXBJbnB1dChyYXcpOwogICAgICAgIHVwZGF0ZVNlcExhYmVsKCk7CiAgICAgICAgY2xvc2VTZXBN
ZW51KCk7CiAgICAgICAgaWYgKGRvUGFzdGUpIHBhc3RlTXVsdGlTZWxlY3Rpb24oKTsKICAgIH0KICAg
IGZ1bmN0aW9uIGNsb3NlU2VwTWVudSgpIHsKICAgICAgICBjb25zdCBtZW51ID0gZG9jdW1lbnQuZ2V0
RWxlbWVudEJ5SWQoJ3Bhc3RlLXNlcC1tZW51Jyk7CiAgICAgICAgY29uc3QgYnRuID0gZG9jdW1lbnQu
Z2V0RWxlbWVudEJ5SWQoJ3Bhc3RlLXNlcC1idG4nKTsKICAgICAgICBpZiAobWVudSkgbWVudS5jbGFz
c0xpc3QucmVtb3ZlKCdvbicpOwogICAgICAgIGlmIChidG4pIGJ0bi5jbGFzc0xpc3QucmVtb3ZlKCdv
cGVuJyk7CiAgICB9CiAgICBmdW5jdGlvbiByZW5kZXJTZXBNZW51KCkgewogICAgICAgIGNvbnN0IG1l
bnUgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgncGFzdGUtc2VwLW1lbnUnKTsKICAgICAgICBpZiAo
IW1lbnUpIHJldHVybjsKICAgICAgICBtZW51LmlubmVySFRNTCA9ICcnOwogICAgICAgIGZvciAoY29u
c3QgdiBvZiBTRVBfTElTVCkgewogICAgICAgICAgICBjb25zdCBiID0gZG9jdW1lbnQuY3JlYXRlRWxl
bWVudCgnYnV0dG9uJyk7CiAgICAgICAgICAgIGIudHlwZSA9ICdidXR0b24nOwogICAgICAgICAgICBi
LmNsYXNzTmFtZSA9ICdwYXN0ZS1zZXAtaXRlbScgKyAodiA9PT0gcGFzdGVTZXBWYWx1ZSA/ICcgc2Vs
JyA6ICcnKTsKICAgICAgICAgICAgZmlsbFNlcE1lbnVJdGVtKGIsIHYpOwogICAgICAgICAgICBiLm9u
Y2xpY2sgPSBlID0+IHsKICAgICAgICAgICAgICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAgICAg
ICAgICAgICBhcHBseVNlcGFyYXRvcih2KTsKICAgICAgICAgICAgfTsKICAgICAgICAgICAgbWVudS5h
cHBlbmRDaGlsZChiKTsKICAgICAgICB9CiAgICAgICAgY29uc3QgZm9vdCA9IGRvY3VtZW50LmNyZWF0
ZUVsZW1lbnQoJ2RpdicpOwogICAgICAgIGZvb3QuY2xhc3NOYW1lID0gJ3Bhc3RlLXNlcC1mb290JzsK
ICAgICAgICBjb25zdCBpbnAgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdpbnB1dCcpOwogICAgICAg
IGlucC5pZCA9ICdwYXN0ZS1zZXAtY3VzdG9tJzsKICAgICAgICBpbnAudHlwZSA9ICd0ZXh0JzsKICAg
ICAgICBpbnAuc2l6ZSA9IDE7CiAgICAgICAgaW5wLnBsYWNlaG9sZGVyID0gJ+iHquWumuS5iSc7CiAg
ICAgICAgaW5wLmF1dG9jb21wbGV0ZSA9ICdvZmYnOwogICAgICAgIGlucC5zcGVsbGNoZWNrID0gZmFs
c2U7CiAgICAgICAgaW5wLnZhbHVlID0gU0VQX0xJU1QuaW5jbHVkZXMocGFzdGVTZXBWYWx1ZSkgPyAn
JyA6IHBhc3RlU2VwVmFsdWU7CiAgICAgICAgaW5wLm9ubW91c2Vkb3duID0gZSA9PiB7CiAgICAgICAg
ICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAgICAgICAgIGUucHJldmVudERlZmF1bHQoKTsKICAg
ICAgICAgICAgdHJ5IHsgYWhrKCdmb2N1c1BhbmVsJyk7IH0gY2F0Y2gge30KICAgICAgICAgICAgaW5w
LmZvY3VzKCk7CiAgICAgICAgfTsKICAgICAgICBpbnAub25jbGljayA9IGUgPT4gZS5zdG9wUHJvcGFn
YXRpb24oKTsKICAgICAgICBpbnAub25mb2N1cyA9ICgpID0+IHsgdHJ5IHsgYWhrKCdmb2N1c1BhbmVs
Jyk7IH0gY2F0Y2gge30gfTsKICAgICAgICBpbnAub25pbnB1dCA9IGUgPT4gZS5zdG9wUHJvcGFnYXRp
b24oKTsKICAgICAgICBpbnAub25rZXlkb3duID0gZSA9PiB7CiAgICAgICAgICAgIGUuc3RvcFByb3Bh
Z2F0aW9uKCk7CiAgICAgICAgICAgIGlmIChlLmtleSA9PT0gJ0VudGVyJykgewogICAgICAgICAgICAg
ICAgZS5wcmV2ZW50RGVmYXVsdCgpOwogICAgICAgICAgICAgICAgaWYgKGlucC52YWx1ZSAhPT0gJycp
IGFwcGx5U2VwYXJhdG9yKGlucC52YWx1ZSk7CiAgICAgICAgICAgICAgICBlbHNlIGNsb3NlU2VwTWVu
dSgpOwogICAgICAgICAgICB9IGVsc2UgaWYgKGUua2V5ID09PSAnRXNjYXBlJykgewogICAgICAgICAg
ICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOwogICAgICAgICAgICAgICAgY2xvc2VTZXBNZW51KCk7CiAg
ICAgICAgICAgIH0KICAgICAgICB9OwogICAgICAgIGZvb3QuYXBwZW5kQ2hpbGQoaW5wKTsKICAgICAg
ICBtZW51LmFwcGVuZENoaWxkKGZvb3QpOwogICAgfQogICAgZnVuY3Rpb24gcmVzZXRQYXN0ZVNlcERl
ZmF1bHQoKSB7CiAgICAgICAgcGFzdGVTZXBWYWx1ZSA9ICcgJzsKICAgICAgICB1cGRhdGVTZXBMYWJl
bCgpOwogICAgICAgIGNsb3NlU2VwTWVudSgpOwogICAgfQogICAgZnVuY3Rpb24gcGFzdGVNYW55V2l0
aFNlcChpZHMpIHsKICAgICAgICBhaGsoJ3Bhc3RlTWFueScsIGlkcy5qb2luKCcsJyksIHNlcFRvQnJp
ZGdlKHBhc3RlU2VwVmFsdWUpKTsKICAgIH0KICAgIGZ1bmN0aW9uIHBhc3RlTXVsdGlTZWxlY3Rpb24o
KSB7CiAgICAgICAgaWYgKCFtdWx0aUlkcy5sZW5ndGgpIHJldHVybjsKICAgICAgICBjb25zdCBpZHMg
PSBtdWx0aUlkcy5zbGljZSgpOwogICAgICAgIGNsZWFyTXVsdGkoKTsKICAgICAgICBpZiAoaWRzLnNv
bWUoaWQgPT4gewogICAgICAgICAgICBjb25zdCBpdCA9IGFsbENsaXBzLmZpbmQoeCA9PiAreC5pZCA9
PT0gK2lkKTsKICAgICAgICAgICAgcmV0dXJuIGl0ICYmIG5vcm1UeXBlKGl0LnR5cGUpID09PSAncmVj
ZW50JzsKICAgICAgICB9KSkgewogICAgICAgICAgICBjb25zdCBmaXJzdCA9IGFsbENsaXBzLmZpbmQo
eCA9PiAreC5pZCA9PT0gK2lkc1swXSk7CiAgICAgICAgICAgIGlmIChmaXJzdCkgYWN0aXZhdGVDbGlw
SXRlbShmaXJzdCk7CiAgICAgICAgICAgIHJldHVybjsKICAgICAgICB9CiAgICAgICAgbWFya1Bhc3Rl
ZExvY2FsKGlkcyk7CiAgICAgICAgcGFzdGVNYW55V2l0aFNlcChpZHMpOwogICAgfQogICAgZnVuY3Rp
b24gaW5pdFNlcFVpKCkgewogICAgICAgIHVwZGF0ZVNlcExhYmVsKCk7CiAgICAgICAgY29uc3QgYnRu
ID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3Bhc3RlLXNlcC1idG4nKTsKICAgICAgICBpZiAoYnRu
KSB7CiAgICAgICAgICAgIGJ0bi5hZGRFdmVudExpc3RlbmVyKCdjbGljaycsIGUgPT4gewogICAgICAg
ICAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICAgICAgICAgIGNvbnN0IG1lbnUgPSBk
b2N1bWVudC5nZXRFbGVtZW50QnlJZCgncGFzdGUtc2VwLW1lbnUnKTsKICAgICAgICAgICAgICAgIGNv
bnN0IG9wZW4gPSBtZW51ICYmIG1lbnUuY2xhc3NMaXN0LmNvbnRhaW5zKCdvbicpOwogICAgICAgICAg
ICAgICAgaWYgKG9wZW4pIHsKICAgICAgICAgICAgICAgICAgICBjb25zdCBpbnAgPSBkb2N1bWVudC5n
ZXRFbGVtZW50QnlJZCgncGFzdGUtc2VwLWN1c3RvbScpOwogICAgICAgICAgICAgICAgICAgIGlmIChp
bnAgJiYgaW5wLnZhbHVlICE9PSAnJykgYXBwbHlTZXBhcmF0b3IoaW5wLnZhbHVlLCB7IHBhc3RlOiBt
dWx0aUlkcy5sZW5ndGggPiAwIH0pOwogICAgICAgICAgICAgICAgICAgIGVsc2UgY2xvc2VTZXBNZW51
KCk7CiAgICAgICAgICAgICAgICAgICAgcmV0dXJuOwogICAgICAgICAgICAgICAgfQogICAgICAgICAg
ICAgICAgcmVuZGVyU2VwTWVudSgpOwogICAgICAgICAgICAgICAgbWVudS5jbGFzc0xpc3QuYWRkKCdv
bicpOwogICAgICAgICAgICAgICAgYnRuLmNsYXNzTGlzdC5hZGQoJ29wZW4nKTsKICAgICAgICAgICAg
fSk7CiAgICAgICAgfQogICAgICAgIGRvY3VtZW50LmFkZEV2ZW50TGlzdGVuZXIoJ21vdXNlZG93bics
IGUgPT4gewogICAgICAgICAgICBpZiAoZS50YXJnZXQuY2xvc2VzdCgnI3Bhc3RlLXNlcC13cmFwJykp
IHJldHVybjsKICAgICAgICAgICAgY29uc3QgbWVudSA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdw
YXN0ZS1zZXAtbWVudScpOwogICAgICAgICAgICBpZiAoIW1lbnUgfHwgIW1lbnUuY2xhc3NMaXN0LmNv
bnRhaW5zKCdvbicpKSByZXR1cm47CiAgICAgICAgICAgIGNvbnN0IGlucCA9IGRvY3VtZW50LmdldEVs
ZW1lbnRCeUlkKCdwYXN0ZS1zZXAtY3VzdG9tJyk7CiAgICAgICAgICAgIGlmIChpbnAgJiYgaW5wLnZh
bHVlICE9PSAnJykgewogICAgICAgICAgICAgICAgYXBwbHlTZXBhcmF0b3IoaW5wLnZhbHVlKTsKICAg
ICAgICAgICAgICAgIHJldHVybjsKICAgICAgICAgICAgfQogICAgICAgICAgICBjbG9zZVNlcE1lbnUo
KTsKICAgICAgICB9LCB0cnVlKTsKICAgIH0KCiAgICBmdW5jdGlvbiBjbGVhck11bHRpKHJlc3RvcmVU
b0FuY2hvcikgewogICAgICAgIGNvbnN0IGJhY2tJZCA9ICtyYW5nZUFuY2hvcklkIHx8IDA7CiAgICAg
ICAgbXVsdGlJZHMgPSBbXTsKICAgICAgICBpZiAocmVzdG9yZVRvQW5jaG9yICYmIGJhY2tJZCkKICAg
ICAgICAgICAgc2VsZWN0ZWRJZCA9IGJhY2tJZDsKICAgICAgICByYW5nZUFuY2hvcklkID0gc2VsZWN0
ZWRJZCB8fCAwOwogICAgICAgIHJhbmdlQW5jaG9yQ2xpY2tlZCA9IGZhbHNlOwogICAgICAgIHVwZGF0
ZU11bHRpQmFkZ2UoKTsKICAgICAgICBpZiAocmVzdG9yZVRvQW5jaG9yICYmIHNlbGVjdGVkSWQpIHsK
ICAgICAgICAgICAgY29uc3QgZWwgPSBsaXN0RWwucXVlcnlTZWxlY3RvcignLm1nLXJvd1tkYXRhLWlk
PSInICsgc2VsZWN0ZWRJZCArICciXScpCiAgICAgICAgICAgICAgICB8fCBsaXN0RWwucXVlcnlTZWxl
Y3RvcignLml0bVtkYXRhLWlkPSInICsgc2VsZWN0ZWRJZCArICciXScpOwogICAgICAgICAgICBpZiAo
ZWwpIGVsLnNjcm9sbEludG9WaWV3KHsgYmxvY2s6ICduZWFyZXN0JyB9KTsKICAgICAgICB9CiAgICB9
CgoKICAgIC8qIHNoaWZ0L2N0cmwgbXVsdGktc2VsZWN0OgogICAgICogU2hpZnTvvJrmnInpgInljLrm
l7bku6XjgIzmnIDkuIov5pyA5LiL44CN5Li66ZSa77yM5LiN6Lef6byg5qCH5LiK5qyh54K55Ye76LWw
CiAgICAgKiAgIC0g54K55Zyo6YCJ5Yy65LiL5pa5IOKGkiDku47kuIrpgInliLDlvZPliY0KICAgICAq
ICAgLSDngrnlnKjpgInljLrkuIrmlrkg4oaSIOS7juW9k+WJjeWIsOS4i+mAiQogICAgICogICAtIOeC
ueWcqOmAieWMuui3qOW6puWGhSDihpIg5aGr5ruh5pyA5LiK5Yiw5pyA5LiL77yI5ZCr6Z2e6L+e57ut
56m65rSe77yJCiAgICAgKiBDdHJs77ya6aaW5qyh54K55Lu75oSP6aG577yI5ZCr6buY6K6k6auY5Lqu
77yJ6L+b5YWl5aSa6YCJ5bm26YCJ5Lit77yb5YaN54K55bey6YCJ6aG55Y+W5raI44CB5pyq6YCJ6aG5
5Yqg5YWlCiAgICAgKi8KICAgIGxldCByYW5nZUFuY2hvcklkID0gMDsKICAgIGxldCByYW5nZUFuY2hv
ckNsaWNrZWQgPSBmYWxzZTsKICAgIGZ1bmN0aW9uIHNlbGVjdGVkSW5kaWNlc0luTGlzdChsaXN0KSB7
CiAgICAgICAgY29uc3Qgc2V0ID0gbmV3IFNldCgobXVsdGlJZHMgfHwgW10pLm1hcChOdW1iZXIpLmZp
bHRlcihCb29sZWFuKSk7CiAgICAgICAgaWYgKCtzZWxlY3RlZElkKSBzZXQuYWRkKCtzZWxlY3RlZElk
KTsKICAgICAgICBjb25zdCBpZHhzID0gW107CiAgICAgICAgbGlzdC5mb3JFYWNoKChjLCBpKSA9PiB7
CiAgICAgICAgICAgIGlmIChzZXQuaGFzKCtjLmlkKSkgaWR4cy5wdXNoKGkpOwogICAgICAgIH0pOwog
ICAgICAgIHJldHVybiBpZHhzOwogICAgfQogICAgZnVuY3Rpb24gc2VsZWN0UmFuZ2VUbyhpZCkgewog
ICAgICAgIGlkID0gK2lkOwogICAgICAgIGNvbnN0IGxpc3QgPSAodHlwZW9mIG5hdkxpc3QgPT09ICdm
dW5jdGlvbicgPyBuYXZMaXN0KCkgOiB2aXNpYmxlTGlzdCgpKTsKICAgICAgICBjb25zdCBiID0gbGlz
dC5maW5kSW5kZXgoYyA9PiArYy5pZCA9PT0gaWQpOwogICAgICAgIGlmIChiIDwgMCkgcmV0dXJuOwog
ICAgICAgIGNvbnN0IGlkeHMgPSBzZWxlY3RlZEluZGljZXNJbkxpc3QobGlzdCk7CiAgICAgICAgbGV0
IGxvLCBoaTsKICAgICAgICBpZiAoIWlkeHMubGVuZ3RoKSB7CiAgICAgICAgICAgIGxvID0gaGkgPSBi
OwogICAgICAgIH0gZWxzZSB7CiAgICAgICAgICAgIGNvbnN0IHRvcCA9IE1hdGgubWluKC4uLmlkeHMp
OwogICAgICAgICAgICBjb25zdCBib3QgPSBNYXRoLm1heCguLi5pZHhzKTsKICAgICAgICAgICAgaWYg
KGIgPiBib3QpIHsKICAgICAgICAgICAgICAgIC8vIOmAieWMuuS4i+aWue+8muacgOS4iiDihpIg5b2T
5YmNCiAgICAgICAgICAgICAgICBsbyA9IHRvcDsKICAgICAgICAgICAgICAgIGhpID0gYjsKICAgICAg
ICAgICAgfSBlbHNlIGlmIChiIDwgdG9wKSB7CiAgICAgICAgICAgICAgICAvLyDpgInljLrkuIrmlrnv
vJrlvZPliY0g4oaSIOacgOS4iwogICAgICAgICAgICAgICAgbG8gPSBiOwogICAgICAgICAgICAgICAg
aGkgPSBib3Q7CiAgICAgICAgICAgIH0gZWxzZSB7CiAgICAgICAgICAgICAgICAvLyDlnKjot6jluqbl
hoXvvIjlkKvpnZ7ov57nu63nqbrmtJ7vvInvvJrmlbTmrrXmnIDkuIrihpLmnIDkuIsKICAgICAgICAg
ICAgICAgIGxvID0gdG9wOwogICAgICAgICAgICAgICAgaGkgPSBib3Q7CiAgICAgICAgICAgIH0KICAg
ICAgICB9CiAgICAgICAgbXVsdGlJZHMgPSBbXTsKICAgICAgICBmb3IgKGxldCBpID0gbG87IGkgPD0g
aGk7IGkrKykKICAgICAgICAgICAgbXVsdGlJZHMucHVzaCgrbGlzdFtpXS5pZCk7CiAgICAgICAgc2Vs
ZWN0ZWRJZCA9IGlkOwogICAgICAgIC8vIOS4jeWGjeaKium8oOagh+eCueWHu+W9k+aIkOS4i+S4gOas
oSBTaGlmdCDplJrngrkKICAgICAgICByYW5nZUFuY2hvcklkID0gK2xpc3RbbG9dLmlkOwogICAgICAg
IHJhbmdlQW5jaG9yQ2xpY2tlZCA9IHRydWU7CiAgICAgICAgdXBkYXRlTXVsdGlCYWRnZSgpOwogICAg
ICAgIGNvbnN0IGVsID0gbGlzdEVsLnF1ZXJ5U2VsZWN0b3IoJy5tZy1yb3dbZGF0YS1pZD0iJyArIHNl
bGVjdGVkSWQgKyAnIl0nKQogICAgICAgICAgICB8fCBsaXN0RWwucXVlcnlTZWxlY3RvcignLml0bVtk
YXRhLWlkPSInICsgc2VsZWN0ZWRJZCArICciXScpOwogICAgICAgIGlmIChlbCkgZWwuc2Nyb2xsSW50
b1ZpZXcoeyBibG9jazogJ25lYXJlc3QnIH0pOwogICAgfQogICAgZnVuY3Rpb24gaGFuZGxlSXRlbUNs
aWNrKGUsIGMpIHsKICAgICAgICBpZiAoZS5zaGlmdEtleSkgewogICAgICAgICAgICBlLnByZXZlbnRE
ZWZhdWx0KCk7IGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAgICAgICAgIHNlbGVjdFJhbmdlVG8oYy5p
ZCk7CiAgICAgICAgICAgIHJldHVybiB0cnVlOwogICAgICAgIH0KICAgICAgICBpZiAoZS5jdHJsS2V5
IHx8IGUubWV0YUtleSkgewogICAgICAgICAgICBlLnByZXZlbnREZWZhdWx0KCk7IGUuc3RvcFByb3Bh
Z2F0aW9uKCk7CiAgICAgICAgICAgIHRvZ2dsZU11bHRpKGMuaWQpOwogICAgICAgICAgICByZXR1cm4g
dHJ1ZTsKICAgICAgICB9CiAgICAgICAgcmFuZ2VBbmNob3JJZCA9IGMuaWQ7CiAgICAgICAgcmFuZ2VB
bmNob3JDbGlja2VkID0gdHJ1ZTsKICAgICAgICByZXR1cm4gZmFsc2U7CiAgICB9CiAgICBmdW5jdGlv
biB0b2dnbGVNdWx0aShpZCkgewogICAgICAgIGlkID0gK2lkOwogICAgICAgIC8vIOmmluasoSBDdHJs
77ya5Y+q6YCJ5Lit5b2T5YmN54K55Ye76aG577yI5ZCr6buY6K6k6auY5Lqu6aG5IOKGkiDov5vlhaXl
pJrpgInvvIzkuI3opoHlj5bmtojvvIkKICAgICAgICBpZiAoIW11bHRpSWRzLmxlbmd0aCkgewogICAg
ICAgICAgICBtdWx0aUlkcyA9IFtpZF07CiAgICAgICAgICAgIHNlbGVjdGVkSWQgPSBpZDsKICAgICAg
ICAgICAgdXBkYXRlTXVsdGlCYWRnZSgpOwogICAgICAgICAgICByZXR1cm47CiAgICAgICAgfQogICAg
ICAgIGNvbnN0IGkgPSBtdWx0aUlkcy5pbmRleE9mKGlkKTsKICAgICAgICBpZiAoaSA+PSAwKSB7CiAg
ICAgICAgICAgIG11bHRpSWRzLnNwbGljZShpLCAxKTsKICAgICAgICAgICAgaWYgKCtzZWxlY3RlZElk
ID09PSBpZCkKICAgICAgICAgICAgICAgIHNlbGVjdGVkSWQgPSBtdWx0aUlkcy5sZW5ndGggPyBtdWx0
aUlkc1ttdWx0aUlkcy5sZW5ndGggLSAxXSA6IDA7CiAgICAgICAgfSBlbHNlIHsKICAgICAgICAgICAg
bXVsdGlJZHMucHVzaChpZCk7CiAgICAgICAgICAgIHNlbGVjdGVkSWQgPSBpZDsKICAgICAgICB9CiAg
ICAgICAgdXBkYXRlTXVsdGlCYWRnZSgpOwogICAgfQogICAgZnVuY3Rpb24gc2hvd1NyY1RpcChhbmNo
b3IsIHRleHQpIHsKICAgICAgICB0ZXh0ID0gU3RyaW5nKHRleHQgfHwgJycpLnRyaW0oKTsKICAgICAg
ICBpZiAoIXRleHQpIHJldHVybjsKICAgICAgICBsZXQgdGlwID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5
SWQoJ3NyYy10aXAnKTsKICAgICAgICBpZiAoIXRpcCkgewogICAgICAgICAgICB0aXAgPSBkb2N1bWVu
dC5jcmVhdGVFbGVtZW50KCdkaXYnKTsKICAgICAgICAgICAgdGlwLmlkID0gJ3NyYy10aXAnOwogICAg
ICAgICAgICBkb2N1bWVudC5ib2R5LmFwcGVuZENoaWxkKHRpcCk7CiAgICAgICAgfQogICAgICAgIHRp
cC50ZXh0Q29udGVudCA9IHRleHQ7CiAgICAgICAgdGlwLmNsYXNzTGlzdC5hZGQoJ3Nob3cnKTsKICAg
ICAgICBjb25zdCByID0gYW5jaG9yLmdldEJvdW5kaW5nQ2xpZW50UmVjdCgpOwogICAgICAgIGNvbnN0
IHR3ID0gdGlwLm9mZnNldFdpZHRoIHx8IDE2MDsKICAgICAgICBjb25zdCB0aCA9IHRpcC5vZmZzZXRI
ZWlnaHQgfHwgMjg7CiAgICAgICAgbGV0IGxlZnQgPSByLnJpZ2h0IC0gdHc7CiAgICAgICAgbGV0IHRv
cCA9IHIudG9wIC0gdGggLSA4OwogICAgICAgIGlmIChsZWZ0IDwgOCkgbGVmdCA9IDg7CiAgICAgICAg
aWYgKGxlZnQgKyB0dyA+IHdpbmRvdy5pbm5lcldpZHRoIC0gOCkgbGVmdCA9IHdpbmRvdy5pbm5lcldp
ZHRoIC0gdHcgLSA4OwogICAgICAgIGlmICh0b3AgPCA4KSB0b3AgPSByLmJvdHRvbSArIDg7CiAgICAg
ICAgdGlwLnN0eWxlLmxlZnQgPSBsZWZ0ICsgJ3B4JzsKICAgICAgICB0aXAuc3R5bGUudG9wID0gdG9w
ICsgJ3B4JzsKICAgICAgICBjbGVhclRpbWVvdXQodGlwLl9oaWRlVCk7CiAgICAgICAgdGlwLl9oaWRl
VCA9IHNldFRpbWVvdXQoKCkgPT4gdGlwLmNsYXNzTGlzdC5yZW1vdmUoJ3Nob3cnKSwgMjIwMCk7CiAg
ICB9CiAgICAvKiBpbWctaG92ZXItcHJldmlldy12OCAqLwogICAgbGV0IF9faW1nSG92ZXJUaW1lciA9
IDAsIF9faW1nSG92ZXJIaWRlVGltZXIgPSAwLCBfX2ltZ0hvdmVyS2V5ID0gJyc7CiAgICBmdW5jdGlv
biBfX2ltZ0hvdmVyRW5zdXJlKCkgewogICAgICAgIGxldCBib3ggPSBkb2N1bWVudC5nZXRFbGVtZW50
QnlJZCgnaW1nLWhvdmVyLXNpZGUnKTsKICAgICAgICBpZiAoIWJveCkgewogICAgICAgICAgICBib3gg
PSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsgYm94LmlkID0gJ2ltZy1ob3Zlci1zaWRlJzsK
ICAgICAgICAgICAgY29uc3QgZnJhbWUgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsgZnJh
bWUuY2xhc3NOYW1lID0gJ2locC1mcmFtZSc7CiAgICAgICAgICAgIGNvbnN0IGltID0gZG9jdW1lbnQu
Y3JlYXRlRWxlbWVudCgnaW1nJyk7IGltLmFsdCA9ICcnOwogICAgICAgICAgICBmcmFtZS5hcHBlbmRD
aGlsZChpbSk7IGJveC5hcHBlbmRDaGlsZChmcmFtZSk7IGRvY3VtZW50LmJvZHkuYXBwZW5kQ2hpbGQo
Ym94KTsKICAgICAgICB9CiAgICAgICAgbGV0IHN0ID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2lt
Zy1ob3Zlci1zaWRlLWNzcycpOwogICAgICAgIGlmICghc3QpIHsgc3QgPSBkb2N1bWVudC5jcmVhdGVF
bGVtZW50KCdzdHlsZScpOyBzdC5pZCA9ICdpbWctaG92ZXItc2lkZS1jc3MnOyBkb2N1bWVudC5oZWFk
LmFwcGVuZENoaWxkKHN0KTsgfQogICAgICAgIHN0LnRleHRDb250ZW50ID0gIiNpbWctaG92ZXItc2lk
ZXtwb3NpdGlvbjpmaXhlZDt6LWluZGV4OjEwMDAwMDtyaWdodDo2cHg7dG9wOjUwJTt0cmFuc2Zvcm06
dHJhbnNsYXRlWSgtNTAlKTtwb2ludGVyLWV2ZW50czpub25lO29wYWNpdHk6MDt2aXNpYmlsaXR5Omhp
ZGRlbjttYXgtd2lkdGg6bWluKDYyMHB4LDkydncpO21heC1oZWlnaHQ6bWluKDkydmgsOTIwcHgpfSNp
bWctaG92ZXItc2lkZS5zaG93e29wYWNpdHk6MTt2aXNpYmlsaXR5OnZpc2libGV9I2ltZy1ob3Zlci1z
aWRlIC5paHAtZnJhbWV7cGFkZGluZzozcHg7YmFja2dyb3VuZDojZmZmO2JvcmRlcjoxcHggc29saWQg
I0M1Q0REQztib3JkZXItcmFkaXVzOjJweDtib3gtc2hhZG93OjAgNnB4IDE4cHggcmdiYSg0NCw0Niw1
NCwuMTIpfSNpbWctaG92ZXItc2lkZSBpbWd7ZGlzcGxheTpibG9jazttYXgtd2lkdGg6bWluKDYxMnB4
LDkwdncpO21heC1oZWlnaHQ6bWluKDkwdmgsOTAwcHgpO3dpZHRoOmF1dG87aGVpZ2h0OmF1dG87b2Jq
ZWN0LWZpdDpjb250YWluO2JhY2tncm91bmQ6I2ZmZn0iOwogICAgICAgIHJldHVybiBib3g7CiAgICB9
CiAgICB3aW5kb3cuX19pbWdIb3ZlclNob3cgPSBmdW5jdGlvbihmaWxlLCBpZCkgewogICAgICAgIGNv
bnN0IGJhcmUgPSBTdHJpbmcoZmlsZSB8fCAnJykuc3BsaXQoL1tcXFxcL10vKS5wb3AoKTsgaWYgKCFi
YXJlKSByZXR1cm47CiAgICAgICAgY29uc3QgYm94ID0gX19pbWdIb3ZlckVuc3VyZSgpOyBjb25zdCBp
bWcgPSBib3gucXVlcnlTZWxlY3RvcignaW1nJyk7IGlmICghaW1nKSByZXR1cm47CiAgICAgICAgYm94
LmNsYXNzTGlzdC5hZGQoJ3Nob3cnKTsKICAgICAgICBpbWcub25lcnJvciA9ICgpID0+IHsKICAgICAg
ICAgICAgaW1nLm9uZXJyb3IgPSAoKSA9PiB7IGltZy5vbmVycm9yID0gbnVsbDsgdHJ5IHsgY29uc3Qg
YyA9IHRodW1iQ2FjaGUgJiYgdGh1bWJDYWNoZS5nZXQoU3RyaW5nKGlkKSk7IGlmIChjKSBpbWcuc3Jj
ID0gYzsgfSBjYXRjaCAoZSkge30gfTsKICAgICAgICAgICAgaW1nLnNyYyA9IFNUT1JFX0JBU0UgKyAn
dGhfJyArIGJhcmUucmVwbGFjZSgvXC5bXi5dKyQvLCAnJykgKyAnLmpwZyc7CiAgICAgICAgfTsKICAg
ICAgICBpbWcub25sb2FkID0gKCkgPT4geyBpbWcub25lcnJvciA9IG51bGw7IH07CiAgICAgICAgaW1n
LmRhdGFzZXQuYmFyZSA9IGJhcmU7IGltZy5zcmMgPSBTVE9SRV9CQVNFICsgYmFyZTsKICAgIH07CiAg
ICB3aW5kb3cuX19pbWdIb3ZlckNsZWFyVWkgPSBmdW5jdGlvbigpIHsKICAgICAgICBfX2ltZ0hvdmVy
S2V5ID0gJyc7CiAgICAgICAgaWYgKF9faW1nSG92ZXJUaW1lcikgeyBjbGVhclRpbWVvdXQoX19pbWdI
b3ZlclRpbWVyKTsgX19pbWdIb3ZlclRpbWVyID0gMDsgfQogICAgICAgIGlmIChfX2ltZ0hvdmVySGlk
ZVRpbWVyKSB7IGNsZWFyVGltZW91dChfX2ltZ0hvdmVySGlkZVRpbWVyKTsgX19pbWdIb3ZlckhpZGVU
aW1lciA9IDA7IH0KICAgICAgICBjb25zdCBib3ggPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnaW1n
LWhvdmVyLXNpZGUnKTsgaWYgKGJveCkgYm94LmNsYXNzTGlzdC5yZW1vdmUoJ3Nob3cnKTsKICAgICAg
ICBjb25zdCBpbWcgPSBib3ggJiYgYm94LnF1ZXJ5U2VsZWN0b3IoJ2ltZycpOwogICAgICAgIGlmIChp
bWcpIHsgaW1nLm9ubG9hZCA9IG51bGw7IGltZy5vbmVycm9yID0gbnVsbDsgaW1nLnJlbW92ZUF0dHJp
YnV0ZSgnc3JjJyk7IGRlbGV0ZSBpbWcuZGF0YXNldC5iYXJlOyB9CiAgICB9OwogICAgd2luZG93Ll9f
aW1nSG92ZXJIaWRlID0gZnVuY3Rpb24oKSB7IHdpbmRvdy5fX2ltZ0hvdmVyQ2xlYXJVaSgpOyB9Owog
ICAgZnVuY3Rpb24gYmluZEltZ0hvdmVyUHJldmlldyhlbCwgaWQsIGZpbGUpIHsKICAgICAgICBpZiAo
IWVsKSByZXR1cm47CiAgICAgICAgY29uc3QgYmFyZSA9IFN0cmluZyhmaWxlIHx8ICcnKS5zcGxpdCgv
W1xcXFwvXS8pLnBvcCgpOyBpZiAoIWJhcmUpIHJldHVybjsKICAgICAgICBjb25zdCBrZXkgPSBTdHJp
bmcoaWQpICsgJ3wnICsgYmFyZTsKICAgICAgICBlbC5zdHlsZS5jdXJzb3IgPSAnem9vbS1pbic7CiAg
ICAgICAgZWwuYWRkRXZlbnRMaXN0ZW5lcignbW91c2VlbnRlcicsICgpID0+IHsKICAgICAgICAgICAg
aWYgKF9faW1nSG92ZXJIaWRlVGltZXIpIHsgY2xlYXJUaW1lb3V0KF9faW1nSG92ZXJIaWRlVGltZXIp
OyBfX2ltZ0hvdmVySGlkZVRpbWVyID0gMDsgfQogICAgICAgICAgICBfX2ltZ0hvdmVyS2V5ID0ga2V5
OwogICAgICAgICAgICBpZiAoX19pbWdIb3ZlclRpbWVyKSBjbGVhclRpbWVvdXQoX19pbWdIb3ZlclRp
bWVyKTsKICAgICAgICAgICAgX19pbWdIb3ZlclRpbWVyID0gc2V0VGltZW91dCgoKSA9PiB7IGlmIChf
X2ltZ0hvdmVyS2V5ID09PSBrZXkpIHRyeSB7IHdpbmRvdy5fX2ltZ0hvdmVyU2hvdyhiYXJlLCBpZCk7
IH0gY2F0Y2ggKGUpIHt9IH0sIDYwKTsKICAgICAgICB9KTsKICAgICAgICBlbC5hZGRFdmVudExpc3Rl
bmVyKCdtb3VzZWxlYXZlJywgKCkgPT4gewogICAgICAgICAgICBpZiAoX19pbWdIb3ZlclRpbWVyKSB7
IGNsZWFyVGltZW91dChfX2ltZ0hvdmVyVGltZXIpOyBfX2ltZ0hvdmVyVGltZXIgPSAwOyB9CiAgICAg
ICAgICAgIF9faW1nSG92ZXJIaWRlVGltZXIgPSBzZXRUaW1lb3V0KCgpID0+IHsgaWYgKCFfX2ltZ0hv
dmVyS2V5IHx8IF9faW1nSG92ZXJLZXkgPT09IGtleSkgd2luZG93Ll9faW1nSG92ZXJIaWRlKCk7IH0s
IDcwKTsKICAgICAgICB9KTsKICAgIH0KCiAgICBmdW5jdGlvbiByZW5kZXIoKSB7CiAgICAgICAgaGlk
ZVBhdGhUaXAoKTsKCiAgICAgICAgY29uc3QgdmlzaWJsZSA9IHZpc2libGVMaXN0KCk7CiAgICAgICAg
Y29uc3QgbG9hZGVkID0gYWxsQ2xpcHMubGVuZ3RoOwogICAgICAgIGNvbnN0IHNob3duQ291bnQgPSB2
aXNpYmxlLmxlbmd0aDsKICAgICAgICAvLyDmlLbol4/op5LmoIfvvJrmlLnkuLrnu7/ngrnvvIjmnInm
nKrmn6XnnIvnmoTmlrDmlLbol4/ml7bmmL7npLrvvIkKICAgICAgICBsZXQgcGlubmVkTiA9IE51bWJl
cihwaW5uZWRUb3RhbCkgfHwgMDsKICAgICAgICBpZiAocGlubmVkTiA8IDEpIHsKICAgICAgICAgICAg
aWYgKGN1clRhYiA9PT0gJ3Bpbm5lZCcpCiAgICAgICAgICAgICAgICBwaW5uZWROID0gTWF0aC5tYXgo
TnVtYmVyKGRpc2tUb3RhbCkgfHwgMCwgbG9hZGVkKTsKICAgICAgICAgICAgZWxzZQogICAgICAgICAg
ICAgICAgcGlubmVkTiA9IGFsbENsaXBzLmZpbHRlcihjID0+IGlzUGlubmVkKGMpKS5sZW5ndGg7CiAg
ICAgICAgfQogICAgICAgIHVwZGF0ZVBpbkRvdCgpOwogICAgICAgIC8vIOaUtuiXjyB0YWLvvJpiYXIg
55So5oC75pWw77yb5pyq5ruh6aG15pe25pi+56S6IOW3suWKoOi9vS/mgLvmlbAKICAgICAgICBsZXQg
c2hvd1RvdGFsID0gZGlza1RvdGFsID4gMCA/IGRpc2tUb3RhbCA6IChsb2FkZWQgfHwgMCk7CiAgICAg
ICAgaWYgKGN1clRhYiA9PT0gJ3Bpbm5lZCcgJiYgcGlubmVkTiA+IHNob3dUb3RhbCkKICAgICAgICAg
ICAgc2hvd1RvdGFsID0gcGlubmVkTjsKICAgICAgICBjb25zdCBxT24gPSBTdHJpbmcocXVlcnkgfHwg
JycpLnRyaW0oKS5sZW5ndGggPiAwOwogICAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdiYXIt
dHh0JykudGV4dENvbnRlbnQgPSBxT24KICAgICAgICAgICAgPyAoc2hvd25Db3VudCArICcg5p2hJykK
ICAgICAgICAgICAgOiAoc2hvd1RvdGFsID4gbG9hZGVkID8gKHNob3duQ291bnQgKyAnIC8gJyArIHNo
b3dUb3RhbCArICcg5p2hJykgOiAoc2hvd1RvdGFsICsgJyDmnaEnKSk7CiAgICAgICAgZG9jdW1lbnQu
Z2V0RWxlbWVudEJ5SWQoJ2VtcHR5LXR4dCcpLnRleHRDb250ZW50ID0gRU1QVFlfTVNHW2N1clRhYl0g
fHwgRU1QVFlfTVNHLmFsbDsKCiAgICAgICAgY29uc3QgaWRTZXQgPSBuZXcgU2V0KGFsbENsaXBzLm1h
cChjID0+ICtjLmlkKSk7CiAgICAgICAgbXVsdGlJZHMgPSBtdWx0aUlkcy5maWx0ZXIoaWQgPT4gaWRT
ZXQuaGFzKGlkKSk7CiAgICAgICAgdXBkYXRlTXVsdGlCYWRnZSgpOwoKICAgICAgICBjb25zdCBzaG93
biA9IHZpc2libGU7CgogICAgICAgIGxpc3RFbC5xdWVyeVNlbGVjdG9yQWxsKCcuaXRtLCAjbGlzdC1t
b3JlJykuZm9yRWFjaChlID0+IGUucmVtb3ZlKCkpOwogICAgICAgIC8vIOmqqOaetuW3suWFs+mXre+8
muWNs+S9vyB3YWl0aW5nIOS5n+S4jSByZXR1cm7vvIzmnInmlbDmja7lsLHnm7TmjqXnlLsKICAgICAg
ICBpZiAoc2tlbEVsKSBza2VsRWwuY2xhc3NMaXN0LnJlbW92ZSgnb24nKTsKICAgICAgICBjb25zdCBh
cHBCb290ID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2FwcCcpOwogICAgICAgIGlmIChhcHBCb290
KSBhcHBCb290LmNsYXNzTGlzdC5yZW1vdmUoJ2Jvb3QtbG9hZGluZycpOwogICAgICAgIGlmICgod2Fp
dGluZ0RhdGEgfHwgIWhvc3RQdXNoZWRPbmNlKSAmJiAhdmlzaWJsZS5sZW5ndGgpIHsKICAgICAgICAg
ICAgZW1wdHlFbC5jbGFzc0xpc3QucmVtb3ZlKCdvbicpOwogICAgICAgICAgICB1cGRhdGVUb3BCdG4o
KTsKICAgICAgICAgICAgcmV0dXJuOwogICAgICAgIH0KICAgICAgICBpZiAoIXZpc2libGUubGVuZ3Ro
KSB7CiAgICAgICAgICAgIC8vIE5ldmVyIHNob3fjgIzmmoLml6DorrDlvZXjgI11bnRpbCB3ZSBoYXZl
IHNlZW4gYSByZWFsIG5vbi1lbXB0eSBwdXNoLAogICAgICAgICAgICAvLyBvciBhIGNvbmZpcm1lZCBl
bXB0eSBhZnRlciB3YXJtIChzYXdOb25FbXB0eSBjYW4gYmUgc2V0IGJ5IGVtcHR5LWZhbGxiYWNrKS4K
ICAgICAgICAgICAgLy8gRmlsdGVyZWQgc2VhcmNoIHdpdGggMCBoaXRzIGlzIGFsbG93ZWQgb25jZSBo
b3N0IHB1c2hlZC4KICAgICAgICAgICAgY29uc3QgcU9uID0gU3RyaW5nKHF1ZXJ5IHx8ICcnKS50cmlt
KCkubGVuZ3RoID4gMDsKICAgICAgICAgICAgY29uc3QgYWxsb3dFbXB0eSA9IGhvc3RQdXNoZWRPbmNl
ICYmIHNhd05vbkVtcHR5ICYmICF3YWl0aW5nRGF0YSAmJiAhYm9vdExvYWRpbmcKICAgICAgICAgICAg
ICAgICYmIChxT24gfHwgZGlza1RvdGFsIDw9IDApOwogICAgICAgICAgICBpZiAoIWFsbG93RW1wdHkp
IHsKICAgICAgICAgICAgICAgIGVtcHR5RWwuY2xhc3NMaXN0LnJlbW92ZSgnb24nKTsKICAgICAgICAg
ICAgICAgIHVwZGF0ZVRvcEJ0bigpOwogICAgICAgICAgICAgICAgcmV0dXJuOwogICAgICAgICAgICB9
CiAgICAgICAgICAgIGlmIChzZWxlY3RGaXJzdE9uU2hvdykgewogICAgICAgICAgICAgICAgc2VsZWN0
Rmlyc3RPblNob3cgPSBmYWxzZTsKICAgICAgICAgICAgICAgIHNlbGVjdGVkSWQgPSAwOwogICAgICAg
ICAgICAgICAgY2xlYXJNdWx0aSgpOwogICAgICAgICAgICAgICAgbGlzdEVsLnNjcm9sbFRvcCA9IDA7
CiAgICAgICAgICAgIH0KICAgICAgICAgICAgZW1wdHlFbC5jbGFzc0xpc3QuYWRkKCdvbicpOwogICAg
ICAgICAgICB1cGRhdGVUb3BCdG4oKTsKICAgICAgICAgICAgcmV0dXJuOwogICAgICAgIH0KICAgICAg
ICBlbXB0eUVsLmNsYXNzTGlzdC5yZW1vdmUoJ29uJyk7CiAgICAgICAgY29uc3QgZnJhZyA9IGRvY3Vt
ZW50LmNyZWF0ZURvY3VtZW50RnJhZ21lbnQoKTsKICAgICAgICBjb25zdCBibG9ja3MgPSBidWlsZFBp
bm5lZEJsb2NrcyhzaG93bik7CiAgICAgICAgbGV0IG51bSA9IDA7CiAgICAgICAgYmxvY2tzLmZvckVh
Y2goYiA9PiB7CiAgICAgICAgICAgIG51bSArPSAxOwogICAgICAgICAgICBpZiAoYi5raW5kID09PSAn
Z3JvdXAnICYmIGIuaXRlbXMubGVuZ3RoID4gMSkKICAgICAgICAgICAgICAgIGZyYWcuYXBwZW5kQ2hp
bGQobWFrZUdyb3VwSXRlbShiLml0ZW1zLCBudW0pKTsKICAgICAgICAgICAgZWxzZQogICAgICAgICAg
ICAgICAgZnJhZy5hcHBlbmRDaGlsZChtYWtlSXRlbShiLml0ZW1zWzBdLCBudW0pKTsKICAgICAgICB9
KTsKICAgICAgICBsaXN0RWwuYXBwZW5kQ2hpbGQoZnJhZyk7CiAgICAgICAgbWFya1F1ZXVlUmFpbHMo
KTsKICAgICAgICB1cGRhdGVNb3JlRm9vdGVyKGRpc2tUb3RhbCk7CiAgICAgICAgaWYgKHNlbGVjdEZp
cnN0T25TaG93KSB7CiAgICAgICAgICAgIHNlbGVjdEZpcnN0T25TaG93ID0gZmFsc2U7CiAgICAgICAg
ICAgIHNlbGVjdGVkSWQgPSB2aXNpYmxlWzBdLmlkOwogICAgICAgICAgICBjbGVhck11bHRpKCk7CiAg
ICAgICAgICAgIGxpc3RFbC5zY3JvbGxUb3AgPSAwOwogICAgICAgIH0gZWxzZSBpZiAoIXZpc2libGUu
c29tZShjID0+IGMuaWQgPT0gc2VsZWN0ZWRJZCkpIHsKICAgICAgICAgICAgc2VsZWN0ZWRJZCA9IHZp
c2libGVbMF0uaWQ7CiAgICAgICAgICAgIHJhbmdlQW5jaG9ySWQgPSBzZWxlY3RlZElkOwogICAgICAg
ICAgICByYW5nZUFuY2hvckNsaWNrZWQgPSBmYWxzZTsKICAgICAgICB9IGVsc2UgaWYgKCFyYW5nZUFu
Y2hvcklkKSB7CiAgICAgICAgICAgIHJhbmdlQW5jaG9ySWQgPSBzZWxlY3RlZElkOwogICAgICAgIH0K
ICAgICAgICBzeW5jSXRlbUhpZ2hsaWdodCgpOwogICAgICAgIHVwZGF0ZVRvcEJ0bigpOwogICAgICAg
IGlmICh3aW5kb3cuX19wZW5kaW5nSnVtcElkKSB7CiAgICAgICAgICAgIGNvbnN0IGppZCA9ICt3aW5k
b3cuX19wZW5kaW5nSnVtcElkOwogICAgICAgICAgICBjb25zdCBlbCA9IGxpc3RFbC5xdWVyeVNlbGVj
dG9yKCcubWctcm93W2RhdGEtaWQ9IicgKyBqaWQgKyAnIl0nKSB8fCBsaXN0RWwucXVlcnlTZWxlY3Rv
cignLml0bVtkYXRhLWlkPSInICsgamlkICsgJyJdJyk7CiAgICAgICAgICAgIGlmIChlbCkgewogICAg
ICAgICAgICAgICAgd2luZG93Ll9fcGVuZGluZ0p1bXBJZCA9IDA7CiAgICAgICAgICAgICAgICB3aW5k
b3cuX19qdW1wTG9hZFRyaWVzID0gMDsKICAgICAgICAgICAgICAgIHNlbGVjdGVkSWQgPSBqaWQ7CiAg
ICAgICAgICAgICAgICByZXF1ZXN0QW5pbWF0aW9uRnJhbWUoKCkgPT4gewogICAgICAgICAgICAgICAg
ICAgIGNvbnN0IG5vZGUgPSBsaXN0RWwucXVlcnlTZWxlY3RvcignLm1nLXJvd1tkYXRhLWlkPSInICsg
amlkICsgJyJdJykgfHwgbGlzdEVsLnF1ZXJ5U2VsZWN0b3IoJy5pdG1bZGF0YS1pZD0iJyArIGppZCAr
ICciXScpOwogICAgICAgICAgICAgICAgICAgIGlmICghbm9kZSkgcmV0dXJuOwogICAgICAgICAgICAg
ICAgICAgIG5vZGUuc2Nyb2xsSW50b1ZpZXcoeyBibG9jazogJ2NlbnRlcicgfSk7CiAgICAgICAgICAg
ICAgICAgICAgbm9kZS5jbGFzc0xpc3QuYWRkKCdqdW1wLWZsYXNoJyk7CiAgICAgICAgICAgICAgICAg
ICAgc2V0VGltZW91dCgoKSA9PiBub2RlLmNsYXNzTGlzdC5yZW1vdmUoJ2p1bXAtZmxhc2gnKSwgOTAw
KTsKICAgICAgICAgICAgICAgICAgICBzeW5jSXRlbUhpZ2hsaWdodCgpOwogICAgICAgICAgICAgICAg
fSk7CiAgICAgICAgICAgIH0gZWxzZSBpZiAoYWxsQ2xpcHMubGVuZ3RoIDwgZGlza1RvdGFsICYmICh3
aW5kb3cuX19qdW1wTG9hZFRyaWVzIHx8IDApIDwgNDApIHsKICAgICAgICAgICAgICAgIHdpbmRvdy5f
X2p1bXBMb2FkVHJpZXMgPSAod2luZG93Ll9fanVtcExvYWRUcmllcyB8fCAwKSArIDE7CiAgICAgICAg
ICAgICAgICByZXF1ZXN0TW9yZSgpOwogICAgICAgICAgICB9IGVsc2UgaWYgKGN1clRhYiAhPT0gJ2Fs
bCcgJiYgIXdpbmRvdy5fX2p1bXBGZWxsQmFjaykgewogICAgICAgICAgICAgICAgLy8gSXRlbSBnb25l
IGZyb20gdGhpcyB0YWIgKGUuZy4gdW5waW5uZWQpIOKAlCBmYWxsIGJhY2sgdG8g5YWo6YOoIG9uY2UK
ICAgICAgICAgICAgICAgIHdpbmRvdy5fX2p1bXBGZWxsQmFjayA9IHRydWU7CiAgICAgICAgICAgICAg
ICB3aW5kb3cuX19qdW1wTG9hZFRyaWVzID0gMDsKICAgICAgICAgICAgICAgIGN1clRhYiA9ICdhbGwn
OwogICAgICAgICAgICAgICAgbWFya1RhYignYWxsJyk7CiAgICAgICAgICAgICAgICByZXF1ZXN0Vmll
dygpOwogICAgICAgICAgICB9IGVsc2UgewogICAgICAgICAgICAgICAgd2luZG93Ll9fcGVuZGluZ0p1
bXBJZCA9IDA7CiAgICAgICAgICAgICAgICB3aW5kb3cuX19qdW1wTG9hZFRyaWVzID0gMDsKICAgICAg
ICAgICAgICAgIGlmIChhbGxDbGlwcy5zb21lKGMgPT4gK2MuaWQgPT09IGppZCkpCiAgICAgICAgICAg
ICAgICAgICAgc2VsZWN0ZWRJZCA9IGppZDsKICAgICAgICAgICAgICAgIHN5bmNJdGVtSGlnaGxpZ2h0
KCk7CiAgICAgICAgICAgIH0KICAgICAgICB9CiAgICAgICAgcmVxdWVzdEFuaW1hdGlvbkZyYW1lKCgp
ID0+IHsKICAgICAgICAgICAgaWYgKGFsbENsaXBzLmxlbmd0aCA8IGRpc2tUb3RhbAogICAgICAgICAg
ICAgICAgJiYgbGlzdEVsLnNjcm9sbEhlaWdodCA8PSBsaXN0RWwuY2xpZW50SGVpZ2h0ICsgMjApCiAg
ICAgICAgICAgICAgICByZXF1ZXN0TW9yZSgpOwogICAgICAgICAgICBzY2hlZHVsZUZpbGVHb25lQ2hl
Y2soKTsKICAgICAgICB9KTsKICAgIH0KCiAgICBjb25zdCBTVkcgPSB7CiAgICAgICAgdGV4dDogICBg
PHN2ZyB2aWV3Qm94PSIwIDAgMjQgMjQiIGZpbGw9Im5vbmUiIHN0cm9rZT0iY3VycmVudENvbG9yIiBz
dHJva2Utd2lkdGg9IjIiPjxwYXRoIGQ9Ik00IDdWNGgxNnYzTTkgMjBoNk0xMiA0djE2Ii8+PC9zdmc+
YCwKICAgICAgICBtZDogICAgIGA8c3ZnIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0iY3VycmVudENv
bG9yIj48dGV4dCB4PSIxMiIgeT0iMTciIHRleHQtYW5jaG9yPSJtaWRkbGUiIGZvbnQtc2l6ZT0iMTUi
IGZvbnQtd2VpZ2h0PSI4MDAiIGZvbnQtZmFtaWx5PSJTZWdvZSBVSSxNaWNyb3NvZnQgWWFIZWksc2Fu
cy1zZXJpZiI+TTwvdGV4dD48L3N2Zz5gLAogICAgICAgIGltYWdlOiAgYDxzdmcgdmlld0JveD0iMCAw
IDI0IDI0IiBmaWxsPSJub25lIiBzdHJva2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIxLjgi
PjxyZWN0IHg9IjMiIHk9IjUiIHdpZHRoPSIxOCIgaGVpZ2h0PSIxNCIgcng9IjIiLz48Y2lyY2xlIGN4
PSI4LjUiIGN5PSIxMCIgcj0iMS41IiBmaWxsPSJjdXJyZW50Q29sb3IiIHN0cm9rZT0ibm9uZSIvPjxw
YXRoIGQ9Ik0zIDE2bDUtNSA0IDQgMy0zIDYgNiIvPjwvc3ZnPmAsCiAgICAgICAgdmlkZW86ICBgPHN2
ZyB2aWV3Qm94PSIwIDAgMjQgMjQiIGZpbGw9Im5vbmUiIHN0cm9rZT0iY3VycmVudENvbG9yIiBzdHJv
a2Utd2lkdGg9IjEuOCI+PHJlY3QgeD0iMyIgeT0iNiIgd2lkdGg9IjE0IiBoZWlnaHQ9IjEyIiByeD0i
MiIvPjxwYXRoIGQ9Ik0xNyA5LjVsNC0yLjV2MTBsLTQtMi41VjkuNXoiIGZpbGw9ImN1cnJlbnRDb2xv
ciIgc3Ryb2tlPSJub25lIi8+PHBhdGggZD0iTTguNSAxMC4ydjMuNmwzLjItMS44LTMuMi0xLjh6IiBm
aWxsPSJjdXJyZW50Q29sb3IiIHN0cm9rZT0ibm9uZSIvPjwvc3ZnPmAsCiAgICAgICAgZm9sZGVyOiBg
PHN2ZyB2aWV3Qm94PSIwIDAgMjQgMjQiIGZpbGw9ImN1cnJlbnRDb2xvciI+PHBhdGggZD0iTTEwIDRI
NGMtMS4xIDAtMiAuOS0yIDJ2MTJjMCAxLjEuOSAyIDIgMmgxNmMxLjEgMCAyLS45IDItMlY4YzAtMS4x
LS45LTItMi0yaC04bC0yLTJ6Ii8+PC9zdmc+YCwKICAgICAgICB6aXA6ICAgIGA8c3ZnIHZpZXdCb3g9
IjAgMCAyNCAyNCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0cm9rZS13aWR0aD0i
MS44Ij48cGF0aCBkPSJNNiAzaDlsNSA1djEzYTEgMSAwIDAgMS0xIDFINmExIDEgMCAwIDEtMS0xVjRh
MSAxIDAgMCAxIDEtMXoiLz48cGF0aCBkPSJNMTQgM3Y2aDYiLz48L3N2Zz5gLAogICAgICAgIGFoazog
ICAgYDxzdmcgdmlld0JveD0iMCAwIDI0IDI0IiBmaWxsPSJjdXJyZW50Q29sb3IiPjx0ZXh0IHg9IjEy
IiB5PSIxNyIgdGV4dC1hbmNob3I9Im1pZGRsZSIgZm9udC1zaXplPSIxNCIgZm9udC13ZWlnaHQ9Ijcw
MCI+SDwvdGV4dD48L3N2Zz5gLAogICAgICAgIGxuazogICAgYDxzdmcgdmlld0JveD0iMCAwIDI0IDI0
IiBmaWxsPSJub25lIiBzdHJva2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIxLjgiPjxwYXRo
IGQ9Ik0xMCAxM2E1IDUgMCAwIDAgNy4wNyAwbDIuMTItMi4xMmE1IDUgMCAwIDAtNy4wNy03LjA3TDEx
IDUiLz48cGF0aCBkPSJNMTQgMTFhNSA1IDAgMCAwLTcuMDcgMEw0LjggMTMuMTJhNSA1IDAgMSAwIDcu
MDcgNy4wN0wxMyAxOSIvPjwvc3ZnPmAsCiAgICAgICAgZG9jOiAgICBgPHN2ZyB2aWV3Qm94PSIwIDAg
MjQgMjQiIGZpbGw9Im5vbmUiIHN0cm9rZT0iY3VycmVudENvbG9yIiBzdHJva2Utd2lkdGg9IjEuOCI+
PHBhdGggZD0iTTcgM2g3bDUgNXYxM2ExIDEgMCAwIDEtMSAxSDdhMSAxIDAgMCAxLTEtMVY0YTEgMSAw
IDAgMSAxLTF6Ii8+PHBhdGggZD0iTTE0IDN2Nmg2Ii8+PC9zdmc+YCwKICAgICAgICBtdWx0aTogIGA8
c3ZnIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0
cm9rZS13aWR0aD0iMS44Ij48cmVjdCB4PSI3IiB5PSI3IiB3aWR0aD0iMTIiIGhlaWdodD0iMTQiIHJ4
PSIxLjUiLz48cGF0aCBkPSJNNSAxN1Y1YTEgMSAwIDAgMSAxLTFoMTAiLz48L3N2Zz5gCiAgICB9OwoK
ICAgIGZ1bmN0aW9uIGZpbGVFeHQocGF0aCkgewogICAgICAgIGNvbnN0IGJhc2UgPSBTdHJpbmcocGF0
aCB8fCAnJykuc3BsaXQoL1tcXC9dLykucG9wKCkgfHwgJyc7CiAgICAgICAgY29uc3QgaSA9IGJhc2Uu
bGFzdEluZGV4T2YoJy4nKTsKICAgICAgICByZXR1cm4gaSA+IDAgPyBiYXNlLnNsaWNlKGkgKyAxKS50
b0xvd2VyQ2FzZSgpIDogJyc7CiAgICB9CiAgICBjb25zdCBpc0ltYWdlRXh0ID0gZSA9PiBbJ3BuZycs
J2pwZycsJ2pwZWcnLCdnaWYnLCd3ZWJwJywnYm1wJywnaWNvJywndGlmJywndGlmZicsJ3N2ZyddLmlu
Y2x1ZGVzKGUpOwogICAgY29uc3QgaXNWaWRlb0V4dCA9IGUgPT4gWydtcDQnLCdta3YnLCdhdmknLCdt
b3YnLCd3bXYnLCdmbHYnLCd3ZWJtJywnbTR2JywnbXBlZycsJ21wZycsJ3RzJywnbTJ0cycsJzNncCcs
J3JtJywncm12YiddLmluY2x1ZGVzKGUpOwogICAgY29uc3QgaXNaaXBFeHQgICA9IGUgPT4gWyd6aXAn
LCdyYXInLCc3eicsJ3RhcicsJ2d6JywnYnoyJ10uaW5jbHVkZXMoZSk7CgogICAgZnVuY3Rpb24gaWNv
bkZvckZpbGVzKGZpbGVzKSB7CiAgICAgICAgaWYgKCFmaWxlcy5sZW5ndGgpICAgIHJldHVybiB7IGNs
czogJ2ZpbGUgZnQtZG9jJywgc3ZnOiBTVkcuZG9jIH07CiAgICAgICAgaWYgKGZpbGVzLmxlbmd0aCA+
IDEpIHJldHVybiB7IGNsczogJ2ZpbGUgZnQtbG5rJywgc3ZnOiBTVkcubXVsdGkgfTsKICAgICAgICBj
b25zdCBleHQgPSBmaWxlRXh0KGZpbGVzWzBdKTsKICAgICAgICBpZiAoIWV4dCkgICAgICAgICAgICAg
IHJldHVybiB7IGNsczogJ2ZpbGUgZnQtZGlyJywgc3ZnOiBTVkcuZm9sZGVyIH07CiAgICAgICAgaWYg
KGlzSW1hZ2VFeHQoZXh0KSkgICByZXR1cm4geyBjbHM6ICdmaWxlIGZ0LWltZycsIHN2ZzogU1ZHLmlt
YWdlIH07CiAgICAgICAgaWYgKGlzVmlkZW9FeHQoZXh0KSkgICByZXR1cm4geyBjbHM6ICdmaWxlIGZ0
LXZpZCcsIHN2ZzogKFNWRy52aWRlbyB8fCBTVkcuZG9jKSB9OwogICAgICAgIGlmIChpc1ppcEV4dChl
eHQpKSAgICAgcmV0dXJuIHsgY2xzOiAnZmlsZSBmdC16aXAnLCBzdmc6IFNWRy56aXAgfTsKICAgICAg
ICBpZiAoZXh0ID09PSAnYWhrJykgICAgIHJldHVybiB7IGNsczogJ2ZpbGUgZnQtYWhrJywgc3ZnOiBT
VkcuYWhrIH07CiAgICAgICAgaWYgKGV4dCA9PT0gJ2xuaycpICAgICByZXR1cm4geyBjbHM6ICdmaWxl
IGZ0LWxuaycsIHN2ZzogU1ZHLmxuayB9OwogICAgICAgIHJldHVybiB7IGNsczogJ2ZpbGUgZnQtZG9j
Jywgc3ZnOiBTVkcuZG9jIH07CiAgICB9CgogICAgZnVuY3Rpb24gc3JjV2luTGFiZWwoYykgewogICAg
ICAgIGNvbnN0IHQgPSBTdHJpbmcoYyAmJiBjLnNyY1RpdGxlIHx8ICcnKS50cmltKCk7CiAgICAgICAg
aWYgKHQpIHJldHVybiB0OwogICAgICAgIHJldHVybiBTdHJpbmcoYyAmJiBjLnNyY0V4ZSB8fCAnJyku
cmVwbGFjZSgvXC5leGUkL2ksICcnKTsKICAgIH0KICAgIGZ1bmN0aW9uIHNyY1RpdGxlSHRtbChjKSB7
CiAgICAgICAgLy8g5YiX6KGo5Lit6Ze0L+WPs+S+p+S4jeWGjeaYvuekuueql+WPo+agh+mimO+8jOad
pea6kOWPquS/neeVmeWPs+S+p+Wbvuagh+aCrOWBnOaPkOekugogICAgICAgIHJldHVybiAnJzsKICAg
IH0KICAgIGZ1bmN0aW9uIGV4cGFuZENoZXZyb24ob3BlbikgewogICAgICAgIHJldHVybiBvcGVuCiAg
ICAgICAgICAgID8gYDxzdmcgdmlld0JveD0iMCAwIDE2IDE2IiB3aWR0aD0iMTQiIGhlaWdodD0iMTQi
IGZpbGw9Im5vbmUiIHN0cm9rZT0iY3VycmVudENvbG9yIiBzdHJva2Utd2lkdGg9IjEuOCIgc3Ryb2tl
LWxpbmVjYXA9InJvdW5kIj48cG9seWxpbmUgcG9pbnRzPSI0IDEwIDggNiAxMiAxMCIvPjwvc3ZnPjxz
cGFuPuaUtui1tzwvc3Bhbj5gCiAgICAgICAgICAgIDogYDxzdmcgdmlld0JveD0iMCAwIDE2IDE2IiB3
aWR0aD0iMTQiIGhlaWdodD0iMTQiIGZpbGw9Im5vbmUiIHN0cm9rZT0iY3VycmVudENvbG9yIiBzdHJv
a2Utd2lkdGg9IjEuOCIgc3Ryb2tlLWxpbmVjYXA9InJvdW5kIj48cG9seWxpbmUgcG9pbnRzPSI0IDYg
OCAxMCAxMiA2Ii8+PC9zdmc+PHNwYW4+5bGV5byAPC9zcGFuPmA7CiAgICB9CiAgICBmdW5jdGlvbiBs
aXN0RXhwYW5kTWF4UHgoKSB7CiAgICAgICAgY29uc3QgaCA9IChsaXN0RWwgJiYgbGlzdEVsLmNsaWVu
dEhlaWdodCkgfHwgMzYwOwogICAgICAgIC8vIOWHoOS5juWNoOa7oeWIl+ihqO+8jOW6lemDqOeVmee6
puS4gOihjAogICAgICAgIHJldHVybiBNYXRoLm1heCg5NiwgaCAtIDI4KTsKICAgIH0KICAgIGZ1bmN0
aW9uIGFwcGx5RXhwYW5kZWRQcmV2aWV3KHByZXYsIGZ1bGxUZXh0KSB7CiAgICAgICAgY29uc3QgbWF4
SCA9IGxpc3RFeHBhbmRNYXhQeCgpOwogICAgICAgIHByZXYuc3R5bGUubWF4SGVpZ2h0ID0gbWF4SCAr
ICdweCc7CiAgICAgICAgcHJldi5jbGFzc0xpc3QuYWRkKCdleHBhbmRlZCcpOwogICAgICAgIHNldEhs
VGV4dChwcmV2LCBmdWxsVGV4dCk7CiAgICAgICAgLy8g5LuN5rqi5Ye677ya5oiq5pat5bm25Zyo5pyr
5bC+5Yqg44CMIC4uLuOAjQogICAgICAgIGlmIChwcmV2LnNjcm9sbEhlaWdodCA8PSBwcmV2LmNsaWVu
dEhlaWdodCArIDIpCiAgICAgICAgICAgIHJldHVybjsKICAgICAgICBsZXQgbG8gPSAwLCBoaSA9IGZ1
bGxUZXh0Lmxlbmd0aCwgYmVzdCA9IDA7CiAgICAgICAgd2hpbGUgKGxvIDw9IGhpKSB7CiAgICAgICAg
ICAgIGNvbnN0IG1pZCA9IChsbyArIGhpKSA+PiAxOwogICAgICAgICAgICBzZXRIbFRleHQocHJldiwg
ZnVsbFRleHQuc2xpY2UoMCwgbWlkKSArICcgLi4uJyk7CiAgICAgICAgICAgIGlmIChwcmV2LnNjcm9s
bEhlaWdodCA8PSBwcmV2LmNsaWVudEhlaWdodCArIDIpIHsKICAgICAgICAgICAgICAgIGJlc3QgPSBt
aWQ7CiAgICAgICAgICAgICAgICBsbyA9IG1pZCArIDE7CiAgICAgICAgICAgIH0gZWxzZSB7CiAgICAg
ICAgICAgICAgICBoaSA9IG1pZCAtIDE7CiAgICAgICAgICAgIH0KICAgICAgICB9CiAgICAgICAgc2V0
SGxUZXh0KHByZXYsIGZ1bGxUZXh0LnNsaWNlKDAsIGJlc3QpICsgJyAuLi4nKTsKICAgIH0KICAgIGZ1
bmN0aW9uIGNvbGxhcHNlUHJldmlldyhwcmV2LCBmdWxsVGV4dCkgewogICAgICAgIHByZXYuY2xhc3NM
aXN0LnJlbW92ZSgnZXhwYW5kZWQnKTsKICAgICAgICBwcmV2LnN0eWxlLm1heEhlaWdodCA9ICcnOwog
ICAgICAgIHNldEhsVGV4dChwcmV2LCBmdWxsVGV4dCk7CiAgICB9CgogICAgZnVuY3Rpb24gZmF2R3Jv
dXBPZihjKSB7CiAgICAgICAgcmV0dXJuIFN0cmluZyhjICYmIGMuZmF2R3JvdXAgfHwgJycpLnRyaW0o
KTsKICAgIH0KICAgIGZ1bmN0aW9uIGNsaXBDb250ZW50UHJldmlldyhjKSB7CiAgICAgICAgY29uc3Qg
dHlwZSA9IG5vcm1UeXBlKGMudHlwZSk7CiAgICAgICAgaWYgKHR5cGUgPT09ICdpbWFnZScpIHJldHVy
biAnW+WbvuWDj10nICsgKGMud2lkdGggJiYgYy5oZWlnaHQgPyAoJyAnICsgYy53aWR0aCArICfDlycg
KyBjLmhlaWdodCkgOiAnJyk7CiAgICAgICAgaWYgKHR5cGUgPT09ICdmaWxlJykgewogICAgICAgICAg
ICBjb25zdCBmaWxlcyA9IFN0cmluZyhjLnByZXZpZXcgfHwgYy5kYXRhIHx8ICcnKS5zcGxpdCgvXHI/
XG4vKS5maWx0ZXIoQm9vbGVhbik7CiAgICAgICAgICAgIHJldHVybiBmaWxlcy5tYXAoZiA9PiBmLnNw
bGl0KC9bXFwvXS8pLnBvcCgpKS5qb2luKCcgwrcgJykgfHwgJ1vmlofku7ZdJzsKICAgICAgICB9CiAg
ICAgICAgbGV0IF9wID0gU3RyaW5nKGMucHJldmlldyB8fCBjLmRhdGEgfHwgJycpOwogICAgICAgIHsg
Y29uc3QgX24gPSBOdW1iZXIoYy5jaGFyQ291bnQpIHx8IDA7IGlmIChfbiA+IF9wLmxlbmd0aCAmJiBf
cC5sZW5ndGgpIF9wICs9ICcuLi4nOyB9CiAgICAgICAgcmV0dXJuIF9wOwogICAgfQogICAgZnVuY3Rp
b24gYnVpbGRQaW5uZWRCbG9ja3MobGlzdCkgewogICAgICAgIGNvbnN0IHVzZWQgPSBuZXcgU2V0KCk7
CiAgICAgICAgY29uc3Qgb3V0ID0gW107CiAgICAgICAgZm9yIChjb25zdCBjIG9mIGxpc3QpIHsKICAg
ICAgICAgICAgaWYgKHVzZWQuaGFzKCtjLmlkKSkgY29udGludWU7CiAgICAgICAgICAgIGNvbnN0IGdp
ZCA9IGZhdkdyb3VwT2YoYyk7CiAgICAgICAgICAgIGlmICghZ2lkKSB7CiAgICAgICAgICAgICAgICB1
c2VkLmFkZCgrYy5pZCk7CiAgICAgICAgICAgICAgICBvdXQucHVzaCh7IGtpbmQ6ICdzaW5nbGUnLCBp
dGVtczogW2NdIH0pOwogICAgICAgICAgICAgICAgY29udGludWU7CiAgICAgICAgICAgIH0KICAgICAg
ICAgICAgY29uc3QgbWVtYmVycyA9IGxpc3QuZmlsdGVyKHggPT4gZmF2R3JvdXBPZih4KSA9PT0gZ2lk
KTsKICAgICAgICAgICAgbWVtYmVycy5mb3JFYWNoKG0gPT4gdXNlZC5hZGQoK20uaWQpKTsKICAgICAg
ICAgICAgaWYgKG1lbWJlcnMubGVuZ3RoIDwgMikKICAgICAgICAgICAgICAgIG91dC5wdXNoKHsga2lu
ZDogJ3NpbmdsZScsIGl0ZW1zOiBbbWVtYmVyc1swXSB8fCBjXSB9KTsKICAgICAgICAgICAgZWxzZQog
ICAgICAgICAgICAgICAgb3V0LnB1c2goeyBraW5kOiAnZ3JvdXAnLCBnaWQsIGl0ZW1zOiBtZW1iZXJz
IH0pOwogICAgICAgIH0KICAgICAgICByZXR1cm4gb3V0OwogICAgfQogICAgZnVuY3Rpb24gX19wcmVw
UGFzdGUoKSB7CiAgICAgICAgdHJ5IHsKICAgICAgICAgICAgY29uc3QgcyA9IGRvY3VtZW50LmdldEVs
ZW1lbnRCeUlkKCdzZWFyY2gnKTsKICAgICAgICAgICAgaWYgKHMgJiYgZG9jdW1lbnQuYWN0aXZlRWxl
bWVudCA9PT0gcykgdHJ5IHsgcy5ibHVyKCk7IH0gY2F0Y2gge30KICAgICAgICAgICAgaWYgKHdpbmRv
dy5nZXRTZWxlY3Rpb24pIHdpbmRvdy5nZXRTZWxlY3Rpb24oKS5yZW1vdmVBbGxSYW5nZXMoKTsKICAg
ICAgICB9IGNhdGNoIHt9CiAgICB9CiAgICBmdW5jdGlvbiBwYXN0ZU9uZShjKSB7CiAgICAgICAgX19w
cmVwUGFzdGUoKTsKICAgICAgICBzZWxlY3RlZElkID0gYy5pZDsKICAgICAgICBpZiAobXVsdGlJZHMu
bGVuZ3RoKSBjbGVhck11bHRpKCk7CiAgICAgICAgc3luY0l0ZW1IaWdobGlnaHQoKTsKICAgICAgICBt
YXJrUGFzdGVkTG9jYWwoYy5pZCk7CiAgICAgICAgYWhrKCdwYXN0ZScsIFN0cmluZyhjLmlkKSk7CiAg
ICB9CiAgICBmdW5jdGlvbiBvcGVuUmVjZW50RGlyKHBhdGgpIHsKICAgICAgICBsZXQgcCA9IFN0cmlu
ZyhwYXRoIHx8ICcnKS50cmltKCk7CiAgICAgICAgaWYgKCFwKSByZXR1cm47CiAgICAgICAgaWYgKC9e
W2EtekEtWl06JC8udGVzdChwKSkgcCArPSAnXFwnOwogICAgICAgIC8vIOe7n+S4gCAvIO+8mumBv+WF
jSBXZWJWaWV3IGhvc3QvSlNPTiDlkIPmjonlj43mlpzmnaAKICAgICAgICBjb25zdCB3aXJlID0gcC5y
ZXBsYWNlKC9cXC9nLCAnLycpOwogICAgICAgIGNvbnN0IHNlbmQgPSAoKSA9PiB7CiAgICAgICAgICAg
IC8vIDEpIHBvc3RNZXNzYWdlIOacgOeos++8iOS4jei/myBzeW5jIENPTe+8iQogICAgICAgICAgICB0
cnkgewogICAgICAgICAgICAgICAgaWYgKHdpbmRvdy5jaHJvbWUgJiYgY2hyb21lLndlYnZpZXcgJiYg
dHlwZW9mIGNocm9tZS53ZWJ2aWV3LnBvc3RNZXNzYWdlID09PSAnZnVuY3Rpb24nKSB7CiAgICAgICAg
ICAgICAgICAgICAgY2hyb21lLndlYnZpZXcucG9zdE1lc3NhZ2UoJ29wZW5EaXJ8JyArIHdpcmUpOwog
ICAgICAgICAgICAgICAgICAgIHJldHVybiB0cnVlOwogICAgICAgICAgICAgICAgfQogICAgICAgICAg
ICB9IGNhdGNoIHt9CiAgICAgICAgICAgIC8vIDIpIGFzeW5jIGhvc3TvvIjpnZ4gc3luY++8iQogICAg
ICAgICAgICB0cnkgewogICAgICAgICAgICAgICAgY29uc3QgaG9zdCA9IGNocm9tZS53ZWJ2aWV3Lmhv
c3RPYmplY3RzLmFoazsKICAgICAgICAgICAgICAgIGlmIChob3N0ICYmIGhvc3Qub3BlbkRpcikgewog
ICAgICAgICAgICAgICAgICAgIFByb21pc2UucmVzb2x2ZShob3N0Lm9wZW5EaXIod2lyZSkpLmNhdGNo
KCgpID0+IHt9KTsKICAgICAgICAgICAgICAgICAgICByZXR1cm4gdHJ1ZTsKICAgICAgICAgICAgICAg
IH0KICAgICAgICAgICAgfSBjYXRjaCB7fQogICAgICAgICAgICAvLyAzKSDmnIDlkI7miY0gc3luYwog
ICAgICAgICAgICB0cnkgeyBhaGsoJ29wZW5EaXInLCB3aXJlKTsgcmV0dXJuIHRydWU7IH0gY2F0Y2gg
e30KICAgICAgICAgICAgcmV0dXJuIGZhbHNlOwogICAgICAgIH07CiAgICAgICAgLy8g56a75byAIHBv
aW50ZXIg5LqL5Lu25qCI5YaN6LCD77yM6YG/5YWNIFdlYlZpZXcyIOWQjOatpeatu+mUgeWvvOiHtOKA
nOeCueS6huayoeWPjeW6lOKAnQogICAgICAgIHNldFRpbWVvdXQoc2VuZCwgMCk7CiAgICB9CiAgICBm
dW5jdGlvbiBpc0l0ZW1DaHJvbWVUYXJnZXQodCkgewogICAgICAgIHJldHVybiAhISh0ICYmIHQuY2xv
c2VzdCAmJiB0LmNsb3Nlc3QoJy5pLWV4cGFuZC1idG4sIC5pLXNyYy1pY28sIC5tZy1zcmMsIC5mZC1i
dG4sIC5mZC1wYXRoLCAucmYtc2VnLCBidXR0b24sIGEsIGlucHV0JykpOwogICAgfQogICAgZnVuY3Rp
b24gYmVnaW5QYXN0ZUZyb21JdGVtKGUsIGMpIHsKICAgICAgICBpZiAoZS5idXR0b24gIT0gbnVsbCAm
JiBlLmJ1dHRvbiAhPT0gMCkgcmV0dXJuOwogICAgICAgIGNvbnN0IHNlZyA9IGUudGFyZ2V0ICYmIGUu
dGFyZ2V0LmNsb3Nlc3QgJiYgZS50YXJnZXQuY2xvc2VzdCgnLnJmLXNlZycpOwogICAgICAgIGlmIChz
ZWcpIHsKICAgICAgICAgICAgY29uc3Qgb3BlblBhdGggPSBzZWcuX29wZW5QYXRoIHx8IHNlZy5nZXRB
dHRyaWJ1dGUoJ2RhdGEtcGF0aCcpIHx8IHNlZy5kYXRhc2V0Lm9wZW5QYXRoIHx8ICcnOwogICAgICAg
ICAgICBpZiAob3BlblBhdGgpIHsKICAgICAgICAgICAgICAgIGUucHJldmVudERlZmF1bHQoKTsKICAg
ICAgICAgICAgICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAgICAgICAgICAgICBvcGVuUmVjZW50
RGlyKG9wZW5QYXRoKTsKICAgICAgICAgICAgICAgIHJldHVybjsKICAgICAgICAgICAgfQogICAgICAg
IH0KICAgICAgICBpZiAoZS50YXJnZXQgJiYgZS50YXJnZXQuY2xvc2VzdCAmJiBlLnRhcmdldC5jbG9z
ZXN0KCcucmYtcGF0aCcpKQogICAgICAgICAgICByZXR1cm47CiAgICAgICAgaWYgKGlzSXRlbUNocm9t
ZVRhcmdldChlLnRhcmdldCkpIHJldHVybjsKICAgICAgICBpZiAobm9ybVR5cGUoYy50eXBlKSA9PT0g
J3JlY2VudCcpIHsKICAgICAgICAgICAgYWN0aXZhdGVDbGlwSXRlbShjKTsKICAgICAgICAgICAgcmV0
dXJuOwogICAgICAgIH0KICAgICAgICBpZiAoaGFuZGxlSXRlbUNsaWNrKGUsIGMpKQogICAgICAgICAg
ICByZXR1cm47CiAgICAgICAgX19wcmVwUGFzdGUoKTsKICAgICAgICBzZWxlY3RlZElkID0gYy5pZDsK
ICAgICAgICByYW5nZUFuY2hvcklkID0gYy5pZDsKICAgICAgICAgICAgaWYgKG11bHRpSWRzLmxlbmd0
aCA+IDAgJiYgbXVsdGlJZHMuaW5jbHVkZXMoK2MuaWQpKSB7CiAgICAgICAgICAgIGNvbnN0IGlkcyA9
IG11bHRpSWRzLnNsaWNlKCk7CiAgICAgICAgICAgIGNsZWFyTXVsdGkoKTsKICAgICAgICAgICAgbWFy
a1Bhc3RlZExvY2FsKGlkcyk7CiAgICAgICAgICAgIHBhc3RlTWFueVdpdGhTZXAoaWRzKTsKICAgICAg
ICAgICAgcmV0dXJuOwogICAgICAgIH0KICAgICAgICBpZiAobXVsdGlJZHMubGVuZ3RoKSBjbGVhck11
bHRpKCk7CiAgICAgICAgc3luY0l0ZW1IaWdobGlnaHQoKTsKICAgICAgICBtYXJrUGFzdGVkTG9jYWwo
Yy5pZCk7CiAgICAgICAgYWhrKCdwYXN0ZScsIFN0cmluZyhjLmlkKSk7CiAgICB9CiAgICBmdW5jdGlv
biBtYWtlR3JvdXBJdGVtKGl0ZW1zLCBpZHgpIHsKICAgICAgICBjb25zdCBlbCA9IGRvY3VtZW50LmNy
ZWF0ZUVsZW1lbnQoJ2RpdicpOwogICAgICAgIGVsLmNsYXNzTmFtZSA9ICdpdG0gaXQtZ3JvdXAnCiAg
ICAgICAgICAgICsgKGl0ZW1zLnNvbWUoYyA9PiArYy5pZCA9PT0gK3NlbGVjdGVkSWQpID8gJyBzZWwn
IDogJycpCiAgICAgICAgICAgICsgKGl0ZW1zLnNvbWUoYyA9PiBtdWx0aUlkcy5pbmNsdWRlcygrYy5p
ZCkpID8gJyBtdWx0aScgOiAnJyk7CiAgICAgICAgZWwuZGF0YXNldC5ncm91cCA9IGZhdkdyb3VwT2Yo
aXRlbXNbMF0pIHx8ICcnOwogICAgICAgIGVsLmRhdGFzZXQuaWQgPSBpdGVtc1swXS5pZDsKCiAgICAg
ICAgY29uc3QgaGVhZCA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOwogICAgICAgIGhlYWQu
Y2xhc3NOYW1lID0gJ21nLWhlYWQnOwogICAgICAgIGhlYWQuaW5uZXJIVE1MID0gJzxzcGFuIGNsYXNz
PSJtZy10YWciPuWQiOW5tjwvc3Bhbj48c3Bhbj4nICsgaXRlbXMubGVuZ3RoICsgJyDmnaEgwrcg54K5
5Ye75Y2V5p2h57KY6LS0PC9zcGFuPic7CiAgICAgICAgZWwuYXBwZW5kQ2hpbGQoaGVhZCk7CgogICAg
ICAgIGl0ZW1zLmZvckVhY2goYyA9PiB7CiAgICAgICAgICAgIGNvbnN0IHJvdyA9IGRvY3VtZW50LmNy
ZWF0ZUVsZW1lbnQoJ2RpdicpOwogICAgICAgICAgICByb3cuY2xhc3NOYW1lID0gJ21nLXJvdycKICAg
ICAgICAgICAgICAgICsgKCtzZWxlY3RlZElkID09PSArYy5pZCA/ICcgc2VsJyA6ICcnKQogICAgICAg
ICAgICAgICAgKyAobXVsdGlJZHMuaW5jbHVkZXMoK2MuaWQpID8gJyBtdWx0aScgOiAnJyk7CiAgICAg
ICAgICAgIHJvdy5kYXRhc2V0LmlkID0gYy5pZDsKCiAgICAgICAgICAgIGNvbnN0IHRvcCA9IGRvY3Vt
ZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOwogICAgICAgICAgICB0b3AuY2xhc3NOYW1lID0gJ21nLXJv
dy10b3AnOwogICAgICAgICAgICBjb25zdCBtYWluID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnZGl2
Jyk7CiAgICAgICAgICAgIG1haW4uY2xhc3NOYW1lID0gJ21nLXJvdy1tYWluJzsKCiAgICAgICAgICAg
IGNvbnN0IHRpdGxlID0gU3RyaW5nKGMuZmF2VGl0bGUgfHwgJycpLnRyaW0oKTsKICAgICAgICAgICAg
aWYgKHRpdGxlKSB7CiAgICAgICAgICAgICAgICBjb25zdCB0ID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVu
dCgnZGl2Jyk7CiAgICAgICAgICAgICAgICB0LmNsYXNzTmFtZSA9ICdtZy10aXRsZSc7CiAgICAgICAg
ICAgICAgICBzZXRIbFRleHQodCwgdGl0bGUpOwogICAgICAgICAgICAgICAgbWFpbi5hcHBlbmRDaGls
ZCh0KTsKICAgICAgICAgICAgfQogICAgICAgICAgICBjb25zdCBib2R5ID0gZG9jdW1lbnQuY3JlYXRl
RWxlbWVudCgnZGl2Jyk7CiAgICAgICAgICAgIGJvZHkuY2xhc3NOYW1lID0gJ21nLWJvZHknICsgKG5v
cm1UeXBlKGMudHlwZSkgPT09ICdpbWFnZScgPyAnIGltZycgOiAnJyk7CiAgICAgICAgICAgIHNldEhs
VGV4dChib2R5LCBjbGlwQ29udGVudFByZXZpZXcoYykpOwogICAgICAgICAgICBtYWluLmFwcGVuZENo
aWxkKGJvZHkpOwogICAgICAgICAgICB0b3AuYXBwZW5kQ2hpbGQobWFpbik7CgogICAgICAgICAgICBj
b25zdCBzcmNJY28gPSBTdHJpbmcoYy5zcmNJY29uIHx8ICcnKTsKICAgICAgICAgICAgY29uc3Qgc3Jj
RXhlID0gU3RyaW5nKGMuc3JjRXhlIHx8ICcnKTsKICAgICAgICAgICAgY29uc3Qgc3JjVGl0bGUgPSBT
dHJpbmcoYy5zcmNUaXRsZSB8fCAnJyk7CiAgICAgICAgICAgIGlmIChzcmNJY28pIHsKICAgICAgICAg
ICAgICAgIGNvbnN0IGltZyA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2ltZycpOwogICAgICAgICAg
ICAgICAgaW1nLmNsYXNzTmFtZSA9ICdtZy1zcmMnOwogICAgICAgICAgICAgICAgaW1nLnNyYyA9IFNU
T1JFX0JBU0UgKyBlbmNvZGVVUklDb21wb25lbnQoc3JjSWNvKTsKICAgICAgICAgICAgICAgIGltZy5h
bHQgPSAnJzsKICAgICAgICAgICAgICAgIGNvbnN0IHRpcFR4dCA9IHNyY1RpdGxlIHx8IHNyY0V4ZSB8
fCAn5p2l5rqQJzsKICAgICAgICAgICAgICAgIGltZy50aXRsZSA9IHRpcFR4dDsKICAgICAgICAgICAg
ICAgIGltZy5vbmNsaWNrID0gZSA9PiB7IGUucHJldmVudERlZmF1bHQoKTsgZS5zdG9wUHJvcGFnYXRp
b24oKTsgc2hvd1NyY1RpcChpbWcsIHRpcFR4dCk7IH07CiAgICAgICAgICAgICAgICB0b3AuYXBwZW5k
Q2hpbGQoaW1nKTsKICAgICAgICAgICAgfQogICAgICAgICAgICByb3cuYXBwZW5kQ2hpbGQodG9wKTsK
CiAgICAgICAgICAgIHJvdy5vbnBvaW50ZXJkb3duID0gZSA9PiB7CiAgICAgICAgICAgICAgICBpZiAo
ZS5idXR0b24gIT09IDApIHJldHVybjsKICAgICAgICAgICAgICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7
CiAgICAgICAgICAgICAgICBiZWdpblBhc3RlRnJvbUl0ZW0oZSwgYyk7CiAgICAgICAgICAgIH07CiAg
ICAgICAgICAgIHJvdy5vbmNvbnRleHRtZW51ID0gZSA9PiB7CiAgICAgICAgICAgICAgICBlLnByZXZl
bnREZWZhdWx0KCk7CiAgICAgICAgICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgICAgICAg
ICAgICAgc2VsZWN0ZWRJZCA9IGMuaWQ7CiAgICAgICAgICAgICAgICBzaG93Q3R4KGUuY2xpZW50WCwg
ZS5jbGllbnRZLCBjKTsKICAgICAgICAgICAgfTsKICAgICAgICAgICAgZWwuYXBwZW5kQ2hpbGQocm93
KTsKICAgICAgICB9KTsKCiAgICAgICAgZWwub25jb250ZXh0bWVudSA9IGUgPT4gewogICAgICAgICAg
ICBpZiAoZS50YXJnZXQuY2xvc2VzdCgnLm1nLXJvdycpKSByZXR1cm47CiAgICAgICAgICAgIGUucHJl
dmVudERlZmF1bHQoKTsKICAgICAgICAgICAgc2VsZWN0ZWRJZCA9IGl0ZW1zWzBdLmlkOwogICAgICAg
ICAgICBzaG93Q3R4KGUuY2xpZW50WCwgZS5jbGllbnRZLCBpdGVtc1swXSk7CiAgICAgICAgfTsKICAg
ICAgICByZXR1cm4gZWw7CiAgICB9CgoKICAgIGZ1bmN0aW9uIGJ1aWxkUmVjZW50UGF0aENydW1icyhj
b250YWluZXIsIGZ1bGxQYXRoKSB7CiAgICAgICAgaWYgKCFjb250YWluZXIpIHJldHVybjsKICAgICAg
ICBjb250YWluZXIucXVlcnlTZWxlY3RvckFsbCgnLnJmLXNlZywgLnJmLXNlcCcpLmZvckVhY2gobiA9
PiBuLnJlbW92ZSgpKTsKICAgICAgICBjb25zdCByYXcgPSBTdHJpbmcoZnVsbFBhdGggfHwgJycpLnJl
cGxhY2UoL1wvL2csICdcXCcpLnJlcGxhY2UoL1xcKyQvLCAnJyk7CiAgICAgICAgaWYgKCFyYXcpIHJl
dHVybjsKICAgICAgICBjb25zdCB1bmMgPSByYXcuc3RhcnRzV2l0aCgnXFxcXCcpOwogICAgICAgIGxl
dCByZXN0ID0gdW5jID8gcmF3LnNsaWNlKDIpIDogcmF3OwogICAgICAgIGNvbnN0IHBhcnRzID0gcmVz
dC5zcGxpdCgnXFwnKS5maWx0ZXIoQm9vbGVhbik7CiAgICAgICAgY29uc3QgYWRkU2VnID0gKGxhYmVs
LCBvcGVuUGF0aCkgPT4gewogICAgICAgICAgICBpZiAoY29udGFpbmVyLnF1ZXJ5U2VsZWN0b3IoJy5y
Zi1zZWcsIC5yZi1zZXAnKSkgewogICAgICAgICAgICAgICAgY29uc3Qgc2VwID0gZG9jdW1lbnQuY3Jl
YXRlRWxlbWVudCgnc3BhbicpOwogICAgICAgICAgICAgICAgc2VwLmNsYXNzTmFtZSA9ICdyZi1zZXAn
OwogICAgICAgICAgICAgICAgc2VwLnRleHRDb250ZW50ID0gJ1xcJzsKICAgICAgICAgICAgICAgIGNv
bnRhaW5lci5hcHBlbmRDaGlsZChzZXApOwogICAgICAgICAgICB9CiAgICAgICAgICAgIC8vIGJ1dHRv
bu+8muWRveS4reabtOeos++8jOS4jeiiqyBhcHAtcmVnaW9uIC8g54i257qnIHBvaW50ZXIg5ZCD5o6J
CiAgICAgICAgICAgIGNvbnN0IHNlZyA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2J1dHRvbicpOwog
ICAgICAgICAgICBzZWcudHlwZSA9ICdidXR0b24nOwogICAgICAgICAgICBzZWcuY2xhc3NOYW1lID0g
J3JmLXNlZyc7CiAgICAgICAgICAgIHNldEhsVGV4dChzZWcsIGxhYmVsKTsKICAgICAgICAgICAgc2Vn
LnRpdGxlID0gJ+aJk+W8gDogJyArIG9wZW5QYXRoOwogICAgICAgICAgICBzZWcuc2V0QXR0cmlidXRl
KCdkYXRhLXBhdGgnLCBvcGVuUGF0aC5yZXBsYWNlKC9cXC9nLCAnLycpKTsKICAgICAgICAgICAgc2Vn
Ll9vcGVuUGF0aCA9IG9wZW5QYXRoOwogICAgICAgICAgICBzZWcuYWRkRXZlbnRMaXN0ZW5lcignY2xp
Y2snLCBlID0+IHsKICAgICAgICAgICAgICAgIGUucHJldmVudERlZmF1bHQoKTsKICAgICAgICAgICAg
ICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAgICAgICAgICAgICBvcGVuUmVjZW50RGlyKG9wZW5Q
YXRoKTsKICAgICAgICAgICAgfSwgdHJ1ZSk7CiAgICAgICAgICAgIHNlZy5hZGRFdmVudExpc3RlbmVy
KCdwb2ludGVyZG93bicsIGUgPT4gewogICAgICAgICAgICAgICAgaWYgKGUuYnV0dG9uICE9PSAwKSBy
ZXR1cm47CiAgICAgICAgICAgICAgICBlLnByZXZlbnREZWZhdWx0KCk7CiAgICAgICAgICAgICAgICBl
LnN0b3BQcm9wYWdhdGlvbigpOwogICAgICAgICAgICAgICAgb3BlblJlY2VudERpcihvcGVuUGF0aCk7
CiAgICAgICAgICAgIH0sIHRydWUpOwogICAgICAgICAgICBjb250YWluZXIuYXBwZW5kQ2hpbGQoc2Vn
KTsKICAgICAgICB9OwogICAgICAgIGlmICghcGFydHMubGVuZ3RoKSB7CiAgICAgICAgICAgIGFkZFNl
ZyhyYXcsIHJhdyk7CiAgICAgICAgICAgIHJldHVybjsKICAgICAgICB9CiAgICAgICAgbGV0IGFjYyA9
IHVuYyA/ICdcXFxcJyArIHBhcnRzWzBdIDogcGFydHNbMF07CiAgICAgICAgaWYgKCF1bmMgJiYgL15b
YS16QS1aXTokLy50ZXN0KHBhcnRzWzBdKSkKICAgICAgICAgICAgYWNjID0gcGFydHNbMF0gKyAnXFwn
OwogICAgICAgIGFkZFNlZyhwYXJ0c1swXSwgYWNjKTsKICAgICAgICBmb3IgKGxldCBpID0gMTsgaSA8
IHBhcnRzLmxlbmd0aDsgaSsrKSB7CiAgICAgICAgICAgIGFjYyA9IGFjYy5yZXBsYWNlKC9cXCskLywg
JycpICsgJ1xcJyArIHBhcnRzW2ldOwogICAgICAgICAgICBhZGRTZWcocGFydHNbaV0sIGFjYyk7CiAg
ICAgICAgfQogICAgfQoKICAgIGZ1bmN0aW9uIGFjdGl2YXRlQ2xpcEl0ZW0oYykgewogICAgICAgIGlm
ICghYykgcmV0dXJuOwogICAgICAgIGlmIChub3JtVHlwZShjLnR5cGUpID09PSAncmVjZW50Jykgewog
ICAgICAgICAgICBfX3ByZXBQYXN0ZSgpOwogICAgICAgICAgICBzZWxlY3RlZElkID0gYy5pZDsKICAg
ICAgICAgICAgaWYgKG11bHRpSWRzLmxlbmd0aCkgY2xlYXJNdWx0aSgpOwogICAgICAgICAgICBzeW5j
SXRlbUhpZ2hsaWdodCgpOwogICAgICAgICAgICBhaGsoJ3Bhc3RlJywgU3RyaW5nKGMuaWQpKTsKICAg
ICAgICAgICAgcmV0dXJuOwogICAgICAgIH0KICAgICAgICBwYXN0ZU9uZShjKTsKICAgIH0KICAgIGZ1
bmN0aW9uIG1ha2VJdGVtKGMsIGlkeCkgewogICAgICAgIGNvbnN0IHR5cGUgICA9IG5vcm1UeXBlKGMu
dHlwZSk7CiAgICAgICAgY29uc3QgcGlubmVkID0gaXNQaW5uZWQoYyk7CiAgICAgICAgY29uc3QgcGFz
dGVkID0gaXNQYXN0ZWQoYyk7CiAgICAgICAgY29uc3QgZWwgICAgID0gZG9jdW1lbnQuY3JlYXRlRWxl
bWVudCgnZGl2Jyk7CiAgICAgICAgZWwuY2xhc3NOYW1lICA9ICdpdG0nCiAgICAgICAgICAgICsgKHNl
bGVjdGVkSWQgPT0gYy5pZCA/ICcgc2VsJyA6ICcnKQogICAgICAgICAgICArIChtdWx0aUlkcy5pbmNs
dWRlcygrYy5pZCkgPyAnIG11bHRpJyA6ICcnKQogICAgICAgICAgICArIChwaW5uZWQgPyAnIGlzLXBp
bm5lZCcgOiAnJyk7CiAgICAgICAgZWwuZGF0YXNldC5pZCA9IGMuaWQ7CiAgICAgICAgY29uc3QgcWcg
PSBOdW1iZXIoYy5xdWV1ZUdyb3VwKSB8fCAwOwogICAgICAgIGlmIChxZyA+IDApIHsKICAgICAgICAg
ICAgZWwuY2xhc3NMaXN0LmFkZCgncS1tZW1iZXInKTsKICAgICAgICAgICAgZWwuZGF0YXNldC5xZyA9
IFN0cmluZyhxZyk7CiAgICAgICAgICAgIGVsLmRhdGFzZXQucWkgPSBTdHJpbmcoTnVtYmVyKGMucXVl
dWVJbmRleCkgfHwgMCk7CiAgICAgICAgICAgIGlmIChwYXN0ZWQpIGVsLmNsYXNzTGlzdC5hZGQoJ3Et
ZG9uZScpOwogICAgICAgICAgICBjb25zdCByYWlsID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnc3Bh
bicpOwogICAgICAgICAgICByYWlsLmNsYXNzTmFtZSA9ICdxLXJhaWwnOwogICAgICAgICAgICBjb25z
dCBkb3QgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdzcGFuJyk7CiAgICAgICAgICAgIGRvdC5jbGFz
c05hbWUgPSAncS1kb3QnOwogICAgICAgICAgICBkb3QudGl0bGUgPSBwYXN0ZWQgPyAn6Zif5YiX5bey
57KY6LS0JyA6ICfnspjotLTpmJ/liJcnOwogICAgICAgICAgICBlbC5hcHBlbmRDaGlsZChyYWlsKTsK
ICAgICAgICAgICAgZWwuYXBwZW5kQ2hpbGQoZG90KTsKICAgICAgICB9CgogICAgICAgIGNvbnN0IGlj
byAgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsKICAgICAgICBjb25zdCBib2R5ID0gZG9j
dW1lbnQuY3JlYXRlRWxlbWVudCgnZGl2Jyk7CiAgICAgICAgYm9keS5jbGFzc05hbWUgPSAnaS1ib2R5
JzsKCiAgICAgICAgaWYgKHR5cGUgPT09ICdpbWFnZScpIHsKICAgICAgICAgICAgaWNvLmNsYXNzTmFt
ZSA9ICdpLWljbyBpbWFnZSc7CiAgICAgICAgICAgIGljby5pbm5lckhUTUwgPSBTVkcuaW1hZ2U7CiAg
ICAgICAgICAgIGJpbmRJbWdIb3ZlclByZXZpZXcoaWNvLCBjLmlkLCBjLmltZ0ZpbGUpOwogICAgICAg
ICAgICBjb25zdCB3cmFwID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnZGl2Jyk7CiAgICAgICAgICAg
IHdyYXAuY2xhc3NOYW1lID0gJ2ktdGh1bWItd3JhcCc7CiAgICAgICAgICAgIGNvbnN0IGltZyAgPSBk
b2N1bWVudC5jcmVhdGVFbGVtZW50KCdpbWcnKTsKICAgICAgICAgICAgaW1nLmNsYXNzTmFtZSA9ICdp
LXRodW1iJzsKICAgICAgICAgICAgaW1nLmFsdCA9ICcnOwogICAgICAgICAgICBjb25zdCBmaWxlID0g
U3RyaW5nKGMuaW1nRmlsZSB8fCAnJyk7CiAgICAgICAgICAgIGxldCBmYWxsYmFjayA9IFN0cmluZyhj
LmRhdGEgfHwgJycpOwogICAgICAgICAgICAvLyBOZXZlciBzeW5jLWNhbGwgQUhLIHRodW1iIGhlcmUg
4oCUIGZyZWV6ZXMgdGFiIHN3aXRjaGVzOyBQdXNoU3RvcmVUaHVtYnMgZmlsbHMgYXN5bmMKICAgICAg
ICAgICAgaWYgKCFmYWxsYmFjay5zdGFydHNXaXRoKCdkYXRhOicpICYmIHRodW1iQ2FjaGUuaGFzKFN0
cmluZyhjLmlkKSkpCiAgICAgICAgICAgICAgICBmYWxsYmFjayA9IFN0cmluZyh0aHVtYkNhY2hlLmdl
dChTdHJpbmcoYy5pZCkpKTsKICAgICAgICAgICAgaW1nLm9ubG9hZCA9ICgpID0+IHsKICAgICAgICAg
ICAgICAgIGNvbnN0IG13ID0gd3JhcC5jbGllbnRXaWR0aCB8fCAzMDA7CiAgICAgICAgICAgICAgICBj
b25zdCBudyA9IGltZy5uYXR1cmFsV2lkdGggIHx8IDA7CiAgICAgICAgICAgICAgICBjb25zdCBuaCA9
IGltZy5uYXR1cmFsSGVpZ2h0IHx8IDA7CiAgICAgICAgICAgICAgICBpZiAoIW53IHx8ICFuaCkgcmV0
dXJuOwogICAgICAgICAgICAgICAgY29uc3Qgc2NhbGUgPSBNYXRoLm1pbigxLCAxODAgLyBuaCwgbXcg
LyBudyk7CiAgICAgICAgICAgICAgICBpbWcuc3R5bGUud2lkdGggID0gTWF0aC5yb3VuZChudyAqIHNj
YWxlKSArICdweCc7CiAgICAgICAgICAgICAgICBpbWcuc3R5bGUuaGVpZ2h0ID0gTWF0aC5yb3VuZChu
aCAqIHNjYWxlKSArICdweCc7CiAgICAgICAgICAgIH07CiAgICAgICAgICAgIGJpbmRTdG9yZVRodW1i
KGltZywgZmlsZSwgYy5pZCwgZmFsbGJhY2spOwogICAgICAgICAgICB3cmFwLmFwcGVuZENoaWxkKGlt
Zyk7CiAgICAgICAgICAgIGNvbnN0IG1ldGEgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsK
ICAgICAgICAgICAgbWV0YS5jbGFzc05hbWUgPSAnaS1tZXRhJzsKICAgICAgICAgICAgbWV0YS5pbm5l
ckhUTUwgID0gYDxzcGFuIGNsYXNzPSJpLXRpbWUiPiR7YWdvKGMudGltZSl9PC9zcGFuPiR7bWV0YUNl
bnRlckh0bWwoZmFsc2UpfTxkaXYgY2xhc3M9ImktbWV0YS1yaWdodCI+JHtjLndpZHRoID8gYDxzcGFu
IGNsYXNzPSJpLXRhZyI+JHtjLndpZHRofcOXJHtjLmhlaWdodH0gcHg8L3NwYW4+YCA6ICcnfTwvZGl2
PmA7CiAgICAgICAgICAgIGJvZHkuYXBwZW5kQ2hpbGQod3JhcCk7CiAgICAgICAgICAgIGJvZHkuYXBw
ZW5kQ2hpbGQobWV0YSk7CiAgICAgICAgfSBlbHNlIGlmICh0eXBlID09PSAncmVjZW50JykgewogICAg
ICAgICAgICBpY28uY2xhc3NOYW1lID0gJ2ktaWNvIGZpbGUgZnQtZGlyJzsKICAgICAgICAgICAgaWNv
LmlubmVySFRNTCA9IFNWRy5mb2xkZXI7CiAgICAgICAgICAgIGlmIChwaW5uZWQpIGVsLmNsYXNzTGlz
dC5hZGQoJ3JmLWZpeGVkJyk7CiAgICAgICAgICAgIGNvbnN0IHBhdGggPSBTdHJpbmcoYy5kYXRhIHx8
IGMucHJldmlldyB8fCAnJyk7CiAgICAgICAgICAgIGNvbnN0IGNydW1icyA9IGRvY3VtZW50LmNyZWF0
ZUVsZW1lbnQoJ2RpdicpOwogICAgICAgICAgICBjcnVtYnMuY2xhc3NOYW1lID0gJ3JmLXBhdGgnOwog
ICAgICAgICAgICBidWlsZFJlY2VudFBhdGhDcnVtYnMoY3J1bWJzLCBwYXRoKTsKICAgICAgICAgICAg
Ly8g5Zu65a6a5qCH6K6w5Y+q5pS+IG1ldGEg5Y+z5L6n77yM5LiN5oyh6Lev5b6ECiAgICAgICAgICAg
IGNvbnN0IG1ldGEgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsKICAgICAgICAgICAgbWV0
YS5jbGFzc05hbWUgPSAnaS1tZXRhJzsKICAgICAgICAgICAgbWV0YS5pbm5lckhUTUwgPQogICAgICAg
ICAgICAgICAgYDxzcGFuIGNsYXNzPSJpLXRpbWUiPiR7YWdvKGMudGltZSl9PC9zcGFuPmAgKwogICAg
ICAgICAgICAgICAgbWV0YUNlbnRlckh0bWwoZmFsc2UpICsKICAgICAgICAgICAgICAgIGA8ZGl2IGNs
YXNzPSJpLW1ldGEtcmlnaHQiPiR7cGlubmVkID8gJzxzcGFuIGNsYXNzPSJyZi1waW4tdGFnIiB0aXRs
ZT0i5bey5Zu65a6a77yM5LiN5Lya6KKr5reY5rGwIj7lm7rlrpo8L3NwYW4+JyA6ICcnfTwvZGl2PmA7
CiAgICAgICAgICAgIGJvZHkuYXBwZW5kQ2hpbGQoY3J1bWJzKTsKICAgICAgICAgICAgYm9keS5hcHBl
bmRDaGlsZChtZXRhKTsKICAgICAgICB9IGVsc2UgaWYgKHR5cGUgPT09ICdmaWxlJykgewogICAgICAg
ICAgICBjb25zdCBmaWxlcyA9IFN0cmluZyhjLnByZXZpZXcgfHwgYy5kYXRhIHx8ICcnKS5zcGxpdCgv
XHI/XG4vKS5maWx0ZXIoQm9vbGVhbik7CiAgICAgICAgICAgIGNvbnN0IGltYWdlUGF0aHMgPSBmaWxl
cy5maWx0ZXIoZiA9PiBpc0ltYWdlRXh0KGZpbGVFeHQoZikpKTsKICAgICAgICAgICAgY29uc3QgaWMg
ICAgPSBpY29uRm9yRmlsZXMoZmlsZXMpOwogICAgICAgICAgICBpY28uY2xhc3NOYW1lID0gJ2ktaWNv
ICcgKyBpYy5jbHM7CiAgICAgICAgICAgIGljby5pbm5lckhUTUwgPSBpYy5zdmc7CgogICAgICAgICAg
ICBsZXQgdGh1bWJGaWxlID0gU3RyaW5nKGMuaW1nRmlsZSB8fCAnJyk7CiAgICAgICAgICAgIC8qIGVu
c3VyZUZpbGVJbWcgZGVmZXJyZWQ6IGF2b2lkIHN5bmMgZnJlZXplIG9uIGZpbGUgdGFiICovCgogICAg
ICAgICAgICAvLyBJbWFnZS1mb3JtYXQgZmlsZXM6IHNhbWUgdGh1bWJuYWlsIHJ1bGVzIGFzIHNjcmVl
bnNob3QgY2xpcHMKICAgICAgICAgICAgaWYgKHRodW1iRmlsZSB8fCBpbWFnZVBhdGhzLmxlbmd0aCkg
ewogICAgICAgICAgICAgICAgY29uc3Qgd3JhcCA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2Rpdicp
OwogICAgICAgICAgICAgICAgd3JhcC5jbGFzc05hbWUgPSAnaS10aHVtYi13cmFwJzsKICAgICAgICAg
ICAgICAgIGNvbnN0IGltZyAgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdpbWcnKTsKICAgICAgICAg
ICAgICAgIGltZy5jbGFzc05hbWUgPSAnaS10aHVtYic7CiAgICAgICAgICAgICAgICBpbWcuYWx0ID0g
Jyc7CiAgICAgICAgICAgICAgICBpbWcub25sb2FkID0gKCkgPT4gewogICAgICAgICAgICAgICAgICAg
IGNvbnN0IG13ID0gd3JhcC5jbGllbnRXaWR0aCB8fCAzMDA7CiAgICAgICAgICAgICAgICAgICAgY29u
c3QgbncgPSBpbWcubmF0dXJhbFdpZHRoICB8fCAwOwogICAgICAgICAgICAgICAgICAgIGNvbnN0IG5o
ID0gaW1nLm5hdHVyYWxIZWlnaHQgfHwgMDsKICAgICAgICAgICAgICAgICAgICBpZiAoIW53IHx8ICFu
aCkgcmV0dXJuOwogICAgICAgICAgICAgICAgICAgIGNvbnN0IHNjYWxlID0gTWF0aC5taW4oMSwgMTgw
IC8gbmgsIG13IC8gbncpOwogICAgICAgICAgICAgICAgICAgIGltZy5zdHlsZS53aWR0aCAgPSBNYXRo
LnJvdW5kKG53ICogc2NhbGUpICsgJ3B4JzsKICAgICAgICAgICAgICAgICAgICBpbWcuc3R5bGUuaGVp
Z2h0ID0gTWF0aC5yb3VuZChuaCAqIHNjYWxlKSArICdweCc7CiAgICAgICAgICAgICAgICB9OwogICAg
ICAgICAgICAvKiBlbnN1cmVGaWxlSW1nIGRlZmVycmVkOiBhdm9pZCBzeW5jIGZyZWV6ZSBvbiBmaWxl
IHRhYiAqLwogICAgICAgICAgICAgICAgYmluZFN0b3JlVGh1bWIoaW1nLCB0aHVtYkZpbGUsIGMuaWQs
ICcnKTsKICAgICAgICAgICAgICAgIHdyYXAuYXBwZW5kQ2hpbGQoaW1nKTsKICAgICAgICAgICAgICAg
IGJvZHkuYXBwZW5kQ2hpbGQod3JhcCk7CiAgICAgICAgICAgIH0KCiAgICAgICAgICAgIGNvbnN0IG5h
bWUgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsKICAgICAgICAgICAgbmFtZS5jbGFzc05h
bWUgID0gJ2ktbmFtZSc7CiAgICAgICAgICAgIHNldEhsVGV4dChuYW1lLCBmaWxlcy5tYXAoZiA9PiBm
LnNwbGl0KC9bXFwvXS8pLnBvcCgpKS5qb2luKCdcbicpIHx8ICco5paH5Lu2KScpOwoKICAgICAgICAg
ICAgZWwuX2ZpbGVQYXRocyA9IGZpbGVzOwoKICAgICAgICAgICAgY29uc3QgZGV0YWlsID0gZG9jdW1l
bnQuY3JlYXRlRWxlbWVudCgnZGl2Jyk7CiAgICAgICAgICAgIGRldGFpbC5jbGFzc05hbWUgPSAnaS1m
aWxlLWRldGFpbCc7CgogICAgICAgICAgICBjb25zdCBtZXRhID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVu
dCgnZGl2Jyk7CiAgICAgICAgICAgIG1ldGEuY2xhc3NOYW1lID0gJ2ktbWV0YSc7CiAgICAgICAgICAg
IGxldCByaWdodCA9ICcnOwogICAgICAgICAgICByaWdodCArPSBgPHNwYW4gY2xhc3M9ImktdGFnIj4k
e2MuZmlsZUNvdW50IHx8IGZpbGVzLmxlbmd0aCB8fCAxfSDkuKrmlofku7Y8L3NwYW4+YDsKICAgICAg
ICAgICAgaWYgKCh0aHVtYkZpbGUgfHwgaW1hZ2VQYXRocy5sZW5ndGgpICYmIGMud2lkdGgpCiAgICAg
ICAgICAgICAgICByaWdodCArPSBgPHNwYW4gY2xhc3M9ImktdGFnIj4ke2Mud2lkdGh9w5cke2MuaGVp
Z2h0fSBweDwvc3Bhbj5gOwogICAgICAgICAgICBjb25zdCBleHBhbmRIdG1sID0gZXhwYW5kQ2hldnJv
bihmYWxzZSk7CiAgICAgICAgICAgIGNvbnN0IGNvbGxhcHNlSHRtbCA9IGV4cGFuZENoZXZyb24odHJ1
ZSk7CiAgICAgICAgICAgIG1ldGEuaW5uZXJIVE1MID0KICAgICAgICAgICAgICAgIGA8c3BhbiBjbGFz
cz0iaS10aW1lIj4ke2FnbyhjLnRpbWUpfTwvc3Bhbj5gICsKICAgICAgICAgICAgICAgIG1ldGFDZW50
ZXJIdG1sKHsgb246IHRydWUsIGh0bWw6IGV4cGFuZEh0bWwgfSkgKwogICAgICAgICAgICAgICAgYDxk
aXYgY2xhc3M9ImktbWV0YS1yaWdodCI+JHtyaWdodH08L2Rpdj5gOwoKICAgICAgICAgICAgY29uc3Qg
ZXhwQnRuID0gbWV0YS5xdWVyeVNlbGVjdG9yKCcuaS1leHBhbmQtYnRuJyk7CiAgICAgICAgICAgIGxl
dCBkZXRhaWxCdWlsdCA9IGZhbHNlOwogICAgICAgICAgICBleHBCdG4ub25jbGljayA9IGUgPT4gewog
ICAgICAgICAgICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOwogICAgICAgICAgICAgICAgZS5zdG9wUHJv
cGFnYXRpb24oKTsKICAgICAgICAgICAgICAgIGNvbnN0IG9wZW4gPSAhZGV0YWlsLmNsYXNzTGlzdC5j
b250YWlucygnb24nKTsKICAgICAgICAgICAgICAgIGlmIChvcGVuICYmICFkZXRhaWxCdWlsdCkgewog
ICAgICAgICAgICAgICAgICAgIGNvbnN0IHBhdGhSb3dzID0gZWwuX3BhdGhSb3dzIHx8IGNoZWNrRmls
ZVBhdGhzKGVsLl9maWxlUGF0aHMgfHwgZmlsZXMpOwogICAgICAgICAgICAgICAgICAgIGZpbGxGaWxl
RGV0YWlsUGFuZWwoZGV0YWlsLCBwYXRoUm93cyk7CiAgICAgICAgICAgICAgICAgICAgZGV0YWlsQnVp
bHQgPSB0cnVlOwogICAgICAgICAgICAgICAgfQogICAgICAgICAgICAgICAgZGV0YWlsLmNsYXNzTGlz
dC50b2dnbGUoJ29uJywgb3Blbik7CiAgICAgICAgICAgICAgICBpZiAob3BlbikgewogICAgICAgICAg
ICAgICAgICAgIGRldGFpbC5zdHlsZS5tYXhIZWlnaHQgPSBsaXN0RXhwYW5kTWF4UHgoKSArICdweCc7
CiAgICAgICAgICAgICAgICAgICAgZGV0YWlsLnN0eWxlLm92ZXJmbG93ID0gJ2F1dG8nOwogICAgICAg
ICAgICAgICAgfSBlbHNlIHsKICAgICAgICAgICAgICAgICAgICBkZXRhaWwuc3R5bGUubWF4SGVpZ2h0
ID0gJyc7CiAgICAgICAgICAgICAgICAgICAgZGV0YWlsLnN0eWxlLm92ZXJmbG93ID0gJyc7CiAgICAg
ICAgICAgICAgICB9CiAgICAgICAgICAgICAgICBleHBCdG4uaW5uZXJIVE1MID0gb3BlbiA/IGNvbGxh
cHNlSHRtbCA6IGV4cGFuZEh0bWw7CiAgICAgICAgICAgIH07CgogICAgICAgICAgICBib2R5LmFwcGVu
ZENoaWxkKG5hbWUpOwogICAgICAgICAgICBib2R5LmFwcGVuZENoaWxkKGRldGFpbCk7CiAgICAgICAg
ICAgIGJvZHkuYXBwZW5kQ2hpbGQobWV0YSk7CiAgICAgICAgfSBlbHNlIHsKICAgICAgICAgICAgY29u
c3QgdXNlTSA9IGNsaXBVc2VzTUljb24oYyk7CiAgICAgICAgICAgIGljby5jbGFzc05hbWUgPSB1c2VN
ID8gJ2ktaWNvIG1kJyA6ICdpLWljbyB0ZXh0JzsKICAgICAgICAgICAgaWNvLmlubmVySFRNTCA9IHVz
ZU0gPyAoU1ZHLm1kIHx8IFNWRy50ZXh0KSA6IFNWRy50ZXh0OwogICAgICAgICAgICAvKiBwbGFpbi1s
aXN0LXByZXYgKi8KICAgICAgICAgICAgLyogcHJldmlldy1lbGxpcHNpcyAqLwogICAgICAgICAgICBs
ZXQgdHh0ICA9IGMucHJldmlldyB8fCBjLmRhdGEgfHwgJyc7CiAgICAgICAgICAgIHsgY29uc3QgX24g
PSBOdW1iZXIoYy5jaGFyQ291bnQpIHx8IDA7IGlmIChfbiA+IHR4dC5sZW5ndGggJiYgdHh0Lmxlbmd0
aCkgdHh0ICs9ICcuLi4nOyB9CiAgICAgICAgICAgIGNvbnN0IHByZXYgPSBkb2N1bWVudC5jcmVhdGVF
bGVtZW50KCdkaXYnKTsKICAgICAgICAgICAgcHJldi5jbGFzc05hbWUgID0gJ2ktcHJldicgKyAoaXNV
cmwodHh0KSA/ICcgdXJsJyA6ICcnKTsKICAgICAgICAgICAgc2V0SGxUZXh0KHByZXYsIHR4dCk7Cgog
ICAgICAgICAgICBjb25zdCBtZXRhID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnZGl2Jyk7CiAgICAg
ICAgICAgIG1ldGEuY2xhc3NOYW1lID0gJ2ktbWV0YSc7CgogICAgICAgICAgICBjb25zdCBjaGFycyA9
IE51bWJlcihjLmNoYXJDb3VudCkgfHwgMDsKICAgICAgICAgICAgY29uc3QgcmlnaHRIVE1MID0gYDxz
cGFuIGNsYXNzPSJpLWNoYXJzIj48c3BhbiBjbGFzcz0ibiI+JHtjaGFyc308L3NwYW4+IOWtl+espjwv
c3Bhbj5gOwoKICAgICAgICAgICAgbWV0YS5pbm5lckhUTUwgPQogICAgICAgICAgICAgICAgYDxzcGFu
IGNsYXNzPSJpLXRpbWUiPiR7YWdvKGMudGltZSl9PC9zcGFuPmAgKwogICAgICAgICAgICAgICAgbWV0
YUNlbnRlckh0bWwoewogICAgICAgICAgICAgICAgICAgIG9uOiBmYWxzZSwKICAgICAgICAgICAgICAg
ICAgICBodG1sOiBleHBhbmRDaGV2cm9uKGZhbHNlKQogICAgICAgICAgICAgICAgfSkgKwogICAgICAg
ICAgICAgICAgYDxkaXYgY2xhc3M9ImktbWV0YS1yaWdodCB0ZXh0LW1ldGEiPiR7cmlnaHRIVE1MfTwv
ZGl2PmA7CgogICAgICAgICAgICBib2R5LmFwcGVuZENoaWxkKHByZXYpOwogICAgICAgICAgICBib2R5
LmFwcGVuZENoaWxkKG1ldGEpOwoKICAgICAgICAgICAgY29uc3QgZXhwQnRuID0gbWV0YS5xdWVyeVNl
bGVjdG9yKCcuaS1leHBhbmQtYnRuJyk7CiAgICAgICAgICAgIGlmIChleHBCdG4pIHsKICAgICAgICAg
ICAgICAgIGV4cEJ0bi5vbmNsaWNrID0gZSA9PiB7CiAgICAgICAgICAgICAgICAgICAgZS5zdG9wUHJv
cGFnYXRpb24oKTsKICAgICAgICAgICAgICAgICAgICBjb25zdCB3aWxsRXhwYW5kID0gIXByZXYuY2xh
c3NMaXN0LmNvbnRhaW5zKCdleHBhbmRlZCcpOwogICAgICAgICAgICAgICAgICAgIGlmICh3aWxsRXhw
YW5kKSB7CiAgICAgICAgICAgICAgICAgICAgICAgIGFwcGx5RXhwYW5kZWRQcmV2aWV3KHByZXYsIHR4
dCk7CiAgICAgICAgICAgICAgICAgICAgICAgIGV4cEJ0bi5pbm5lckhUTUwgPSBleHBhbmRDaGV2cm9u
KHRydWUpOwogICAgICAgICAgICAgICAgICAgICAgICB0cnkgeyBlbC5zY3JvbGxJbnRvVmlldyh7IGJs
b2NrOiAnbmVhcmVzdCcgfSk7IH0gY2F0Y2gge30KICAgICAgICAgICAgICAgICAgICB9IGVsc2Ugewog
ICAgICAgICAgICAgICAgICAgICAgICBjb2xsYXBzZVByZXZpZXcocHJldiwgdHh0KTsKICAgICAgICAg
ICAgICAgICAgICAgICAgZXhwQnRuLmlubmVySFRNTCA9IGV4cGFuZENoZXZyb24oZmFsc2UpOwogICAg
ICAgICAgICAgICAgICAgIH0KICAgICAgICAgICAgICAgIH07CiAgICAgICAgICAgICAgICBjb25zdCBj
aGVja092ZXJmbG93ID0gKCkgPT4gewogICAgICAgICAgICAgICAgICAgIGNvbnN0IHBsYWluTGVuID0g
U3RyaW5nKGMucHJldmlldyB8fCBjLmRhdGEgfHwgJycpLmxlbmd0aDsKICAgICAgICAgICAgICAgICAg
ICBjb25zdCBmdWxsTiA9IE51bWJlcihjLmNoYXJDb3VudCkgfHwgMDsKICAgICAgICAgICAgICAgICAg
ICBjb25zdCB0cnVuYyA9IGZ1bGxOID4gcGxhaW5MZW47CiAgICAgICAgICAgICAgICAgICAgaWYgKHBy
ZXYuc2Nyb2xsSGVpZ2h0ID4gcHJldi5jbGllbnRIZWlnaHQgKyAyIHx8IHRydW5jKQogICAgICAgICAg
ICAgICAgICAgICAgICBleHBCdG4uY2xhc3NMaXN0LmFkZCgnb24nKTsKICAgICAgICAgICAgICAgICAg
ICBlbHNlCiAgICAgICAgICAgICAgICAgICAgICAgIGV4cEJ0bi5jbGFzc0xpc3QucmVtb3ZlKCdvbicp
OwogICAgICAgICAgICAgICAgfTsKICAgICAgICAgICAgICAgIHJlcXVlc3RBbmltYXRpb25GcmFtZShj
aGVja092ZXJmbG93KTsKICAgICAgICAgICAgICAgIHNldFRpbWVvdXQoY2hlY2tPdmVyZmxvdywgODAp
OwogICAgICAgICAgICB9CiAgICAgICAgfQoKICAgICAgICBjb25zdCBmYXZUID0gU3RyaW5nKGMuZmF2
VGl0bGUgfHwgJycpLnRyaW0oKTsKICAgICAgICBpZiAoZmF2VCkgewogICAgICAgICAgICBjb25zdCBm
dCA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOwogICAgICAgICAgICBmdC5jbGFzc05hbWUg
PSAnaS1mYXYtdGl0bGUnOwogICAgICAgICAgICBzZXRIbFRleHQoZnQsIGZhdlQpOwogICAgICAgICAg
ICBib2R5Lmluc2VydEJlZm9yZShmdCwgYm9keS5maXJzdENoaWxkKTsKICAgICAgICB9CgogICAgICAg
IGlmIChwaW5uZWQpIHsKICAgICAgICAgICAgY29uc3QgZmF2QmFkZ2UgPSBkb2N1bWVudC5jcmVhdGVF
bGVtZW50KCdzcGFuJyk7CiAgICAgICAgICAgIGZhdkJhZGdlLmNsYXNzTmFtZSA9ICdpLWZhdic7CiAg
ICAgICAgICAgIGZhdkJhZGdlLnRpdGxlID0gJ+W3suaUtuiXjyc7CiAgICAgICAgICAgIGZhdkJhZGdl
LmlubmVySFRNTCA9IGA8c3ZnIHZpZXdCb3g9IjAgMCAxNiAxNiIgZmlsbD0iY3VycmVudENvbG9yIj48
cGF0aCBkPSJNOCAxMy42UzIuNCAxMC4xIDEuMiA2LjdDLjQgNC41IDEuOSAyLjQgNC4xIDIuNGMxLjMg
MCAyLjQuNyAzIDEuOC42LTEuMSAxLjctMS44IDMtMS44IDIuMiAwIDMuNyAyLjEgMi45IDQuM0MxMy42
IDEwLjEgOCAxMy42IDggMTMuNnoiLz48L3N2Zz5gOwogICAgICAgICAgICBpY28uYXBwZW5kQ2hpbGQo
ZmF2QmFkZ2UpOwogICAgICAgIH0KCiAgICAgICAgaWYgKHBhc3RlZCkgewogICAgICAgICAgICBlbC5j
bGFzc0xpc3QuYWRkKCdwYXN0ZWQnKTsKICAgICAgICAgICAgY29uc3QgYmFkZ2UgPSBkb2N1bWVudC5j
cmVhdGVFbGVtZW50KCdzcGFuJyk7CiAgICAgICAgICAgIGJhZGdlLmNsYXNzTmFtZSA9ICdpLXVzZWQn
OwogICAgICAgICAgICBiYWRnZS50aXRsZSA9ICflt7LnspjotLQnOwogICAgICAgICAgICBiYWRnZS5p
bm5lckhUTUwgPSBgPHN2ZyB2aWV3Qm94PSIwIDAgMTYgMTYiIGZpbGw9Im5vbmUiIHN0cm9rZT0iY3Vy
cmVudENvbG9yIiBzdHJva2Utd2lkdGg9IjIuNCIgc3Ryb2tlLWxpbmVjYXA9InJvdW5kIiBzdHJva2Ut
bGluZWpvaW49InJvdW5kIj48cG9seWxpbmUgcG9pbnRzPSIzLjUgOC41IDYuNSAxMS41IDEyLjUgNC41
Ii8+PC9zdmc+YDsKICAgICAgICAgICAgaWNvLmFwcGVuZENoaWxkKGJhZGdlKTsKICAgICAgICB9Cgog
ICAgICAgIGNvbnN0IG51bSA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOwogICAgICAgIG51
bS5jbGFzc05hbWUgPSAnaS1udW0nOwogICAgICAgIGNvbnN0IG51bVR4dCA9IGRvY3VtZW50LmNyZWF0
ZUVsZW1lbnQoJ3NwYW4nKTsKICAgICAgICBudW1UeHQudGV4dENvbnRlbnQgPSBpZHg7CiAgICAgICAg
bnVtLmFwcGVuZENoaWxkKG51bVR4dCk7CiAgICAgICAgY29uc3Qgc3JjSWNvID0gU3RyaW5nKGMuc3Jj
SWNvbiB8fCAnJyk7CiAgICAgICAgY29uc3Qgc3JjRXhlID0gU3RyaW5nKGMuc3JjRXhlIHx8ICcnKTsK
ICAgICAgICBjb25zdCBzcmNUaXRsZSA9IFN0cmluZyhjLnNyY1RpdGxlIHx8ICcnKTsKICAgICAgICBp
ZiAoc3JjSWNvKSB7CiAgICAgICAgICAgIGNvbnN0IGltZyA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQo
J2ltZycpOwogICAgICAgICAgICBpbWcuY2xhc3NOYW1lID0gJ2ktc3JjLWljbyc7CiAgICAgICAgICAg
IGltZy5zcmMgPSBTVE9SRV9CQVNFICsgZW5jb2RlVVJJQ29tcG9uZW50KHNyY0ljbyk7CiAgICAgICAg
ICAgIGltZy5hbHQgPSAnJzsKICAgICAgICAgICAgY29uc3QgdGlwVHh0ID0gc3JjVGl0bGUgfHwgc3Jj
RXhlIHx8ICfmnaXmupAnOwogICAgICAgICAgICBpbWcudGl0bGUgPSB0aXBUeHQ7CiAgICAgICAgICAg
IGltZy5vbmNsaWNrID0gZSA9PiB7IGUucHJldmVudERlZmF1bHQoKTsgZS5zdG9wUHJvcGFnYXRpb24o
KTsgc2hvd1NyY1RpcChpbWcsIHRpcFR4dCk7IH07CiAgICAgICAgICAgIG51bS5hcHBlbmRDaGlsZChp
bWcpOwogICAgICAgIH0KCiAgICAgICAgZWwuYXBwZW5kQ2hpbGQoaWNvKTsKICAgICAgICBlbC5hcHBl
bmRDaGlsZChib2R5KTsKICAgICAgICBlbC5hcHBlbmRDaGlsZChudW0pOwoKICAgICAgICBlbC5vbnBv
aW50ZXJkb3duID0gZSA9PiB7CiAgICAgICAgICAgIGJlZ2luUGFzdGVGcm9tSXRlbShlLCBjKTsKICAg
ICAgICB9OwogICAgICAgIGVsLm9uY29udGV4dG1lbnUgPSBlID0+IHsKICAgICAgICAgICAgZS5wcmV2
ZW50RGVmYXVsdCgpOwogICAgICAgICAgICBzZWxlY3RlZElkID0gYy5pZDsKICAgICAgICAgICAgc2hv
d0N0eChlLmNsaWVudFgsIGUuY2xpZW50WSwgYyk7CiAgICAgICAgfTsKCiAgICAgICAgcmV0dXJuIGVs
OwogICAgfQoKICAgIGZ1bmN0aW9uIGl0ZW1Jc1F1ZXVlRG9uZShyb3cpIHsKICAgICAgICBpZiAoIXJv
dykgcmV0dXJuIGZhbHNlOwogICAgICAgIGlmIChyb3cuY2xhc3NMaXN0LmNvbnRhaW5zKCdwYXN0ZWQn
KSB8fCByb3cuY2xhc3NMaXN0LmNvbnRhaW5zKCdxLWRvbmUnKSkKICAgICAgICAgICAgcmV0dXJuIHRy
dWU7CiAgICAgICAgY29uc3QgaWQgPSArcm93LmRhdGFzZXQuaWQ7CiAgICAgICAgY29uc3QgYyA9IGFs
bENsaXBzLmZpbmQoeCA9PiAreC5pZCA9PT0gaWQpOwogICAgICAgIHJldHVybiAhIShjICYmIGlzUGFz
dGVkKGMpKTsKICAgIH0KCiAgICBmdW5jdGlvbiBtYXJrUXVldWVSYWlscygpIHsKICAgICAgICBpZiAo
IWxpc3RFbCkgcmV0dXJuOwogICAgICAgIGNvbnN0IG5vZGVzID0gWy4uLmxpc3RFbC5xdWVyeVNlbGVj
dG9yQWxsKCcuaXRtLnEtbWVtYmVyJyldOwogICAgICAgIGlmICghbm9kZXMubGVuZ3RoKSByZXR1cm47
CiAgICAgICAgLy8gUmVzZXQgbGluayBjbGFzc2VzOyBrZWVwIHN0cnVjdHVyYWwgZW5kcwogICAgICAg
IG5vZGVzLmZvckVhY2gobiA9PiBuLmNsYXNzTGlzdC5yZW1vdmUoJ3EtZmlyc3QnLCAncS1sYXN0Jywg
J3Etb25seScsICdxLWRvbmUtbGluaycsICdxLXBhc3RlZC1uZXh0JykpOwogICAgICAgIC8vIEdyb3Vw
IGNvbnNlY3V0aXZlIHNhbWUgcXVldWVHcm91cCBpbiBET00gb3JkZXIKICAgICAgICBsZXQgaSA9IDA7
CiAgICAgICAgd2hpbGUgKGkgPCBub2Rlcy5sZW5ndGgpIHsKICAgICAgICAgICAgY29uc3QgZyA9IG5v
ZGVzW2ldLmRhdGFzZXQucWc7CiAgICAgICAgICAgIGxldCBqID0gaSArIDE7CiAgICAgICAgICAgIHdo
aWxlIChqIDwgbm9kZXMubGVuZ3RoICYmIG5vZGVzW2pdLmRhdGFzZXQucWcgPT09IGcpIGorKzsKICAg
ICAgICAgICAgY29uc3Qgc2xpY2UgPSBub2Rlcy5zbGljZShpLCBqKTsKICAgICAgICAgICAgaWYgKHNs
aWNlLmxlbmd0aCA9PT0gMSkgewogICAgICAgICAgICAgICAgc2xpY2VbMF0uY2xhc3NMaXN0LmFkZCgn
cS1vbmx5Jyk7CiAgICAgICAgICAgIH0gZWxzZSB7CiAgICAgICAgICAgICAgICBzbGljZVswXS5jbGFz
c0xpc3QuYWRkKCdxLWZpcnN0Jyk7CiAgICAgICAgICAgICAgICBzbGljZVtzbGljZS5sZW5ndGggLSAx
XS5jbGFzc0xpc3QuYWRkKCdxLWxhc3QnKTsKICAgICAgICAgICAgfQogICAgICAgICAgICBmb3IgKGxl
dCBrID0gMDsgayA8IHNsaWNlLmxlbmd0aDsgaysrKSB7CiAgICAgICAgICAgICAgICBjb25zdCBkb25l
ID0gaXRlbUlzUXVldWVEb25lKHNsaWNlW2tdKTsKICAgICAgICAgICAgICAgIHNsaWNlW2tdLmNsYXNz
TGlzdC50b2dnbGUoJ3EtZG9uZScsIGRvbmUpOwogICAgICAgICAgICAgICAgY29uc3QgZG90ID0gc2xp
Y2Vba10ucXVlcnlTZWxlY3RvcignLnEtZG90Jyk7CiAgICAgICAgICAgICAgICBpZiAoZG90KSBkb3Qu
dGl0bGUgPSBkb25lID8gJ+mYn+WIl+W3sueymOi0tCcgOiAn57KY6LS06Zif5YiXJzsKICAgICAgICAg
ICAgICAgIC8vIEdyZWVuIHJhaWwgZm9yIGV2ZXJ5IGl0ZW0gaW4gYSAyKyBkZXF1ZXVlZCBydW4gKGlu
Y2wuIGZpcnN0L2xhc3Qgc3R1YnMpCiAgICAgICAgICAgICAgICBjb25zdCBwcmV2RG9uZSA9IGsgPiAw
ICYmIGl0ZW1Jc1F1ZXVlRG9uZShzbGljZVtrIC0gMV0pOwogICAgICAgICAgICAgICAgY29uc3QgbmV4
dERvbmUgPSBrIDwgc2xpY2UubGVuZ3RoIC0gMSAmJiBpdGVtSXNRdWV1ZURvbmUoc2xpY2VbayArIDFd
KTsKICAgICAgICAgICAgICAgIGlmIChkb25lICYmIChwcmV2RG9uZSB8fCBuZXh0RG9uZSkpCiAgICAg
ICAgICAgICAgICAgICAgc2xpY2Vba10uY2xhc3NMaXN0LmFkZCgncS1kb25lLWxpbmsnKTsKICAgICAg
ICAgICAgfQogICAgICAgICAgICBpID0gajsKICAgICAgICB9CiAgICB9CgogICAgY29uc3QgcGF0aFRp
cEVsID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3BhdGgtdGlwJyk7CiAgICBsZXQgcGF0aFRpcFRp
bWVyID0gMDsKICAgIGxldCBwYXRoVGlwSGlkZVRpbWVyID0gMDsKICAgIGxldCBwYXRoVGlwVG9rZW4g
PSAwOwogICAgbGV0IHBhdGhUaXBBbmNob3JCdG4gPSBudWxsOwoKICAgIGZ1bmN0aW9uIGhpZGVQYXRo
VGlwKCkgewogICAgICAgIGNsZWFyVGltZW91dChwYXRoVGlwVGltZXIpOwogICAgICAgIGNsZWFyVGlt
ZW91dChwYXRoVGlwSGlkZVRpbWVyKTsKICAgICAgICBwYXRoVGlwVG9rZW4rKzsKICAgICAgICBpZiAo
cGF0aFRpcEFuY2hvckJ0bikgewogICAgICAgICAgICBwYXRoVGlwQW5jaG9yQnRuLmNsYXNzTGlzdC5y
ZW1vdmUoJ29uJyk7CiAgICAgICAgICAgIHBhdGhUaXBBbmNob3JCdG4gPSBudWxsOwogICAgICAgIH0K
ICAgICAgICBpZiAocGF0aFRpcEVsKSB7CiAgICAgICAgICAgIHBhdGhUaXBFbC5jbGFzc0xpc3QucmVt
b3ZlKCdvbicpOwogICAgICAgICAgICBwYXRoVGlwRWwuc2V0QXR0cmlidXRlKCdhcmlhLWhpZGRlbics
ICd0cnVlJyk7CiAgICAgICAgfQogICAgfQogICAgZnVuY3Rpb24gcGxhY2VQYXRoVGlwKGFuY2hvckVs
KSB7CiAgICAgICAgaWYgKCFwYXRoVGlwRWwgfHwgIWFuY2hvckVsKSByZXR1cm47CiAgICAgICAgY29u
c3QgdGlwID0gcGF0aFRpcEVsOwogICAgICAgIGNvbnN0IGFyID0gYW5jaG9yRWwuZ2V0Qm91bmRpbmdD
bGllbnRSZWN0KCk7CiAgICAgICAgY29uc3QgcGFkID0gODsKICAgICAgICB0aXAuc3R5bGUubGVmdCA9
ICcwcHgnOwogICAgICAgIHRpcC5zdHlsZS50b3AgPSAnMHB4JzsKICAgICAgICB0aXAuY2xhc3NMaXN0
LmFkZCgnb24nKTsKICAgICAgICBjb25zdCB0dyA9IHRpcC5vZmZzZXRXaWR0aDsKICAgICAgICBjb25z
dCB0aCA9IHRpcC5vZmZzZXRIZWlnaHQ7CiAgICAgICAgbGV0IGxlZnQgPSBhci5sZWZ0OwogICAgICAg
IGxldCB0b3AgPSBhci5ib3R0b20gKyA2OwogICAgICAgIGlmIChsZWZ0ICsgdHcgPiB3aW5kb3cuaW5u
ZXJXaWR0aCAtIHBhZCkKICAgICAgICAgICAgbGVmdCA9IE1hdGgubWF4KHBhZCwgd2luZG93LmlubmVy
V2lkdGggLSB0dyAtIHBhZCk7CiAgICAgICAgaWYgKGxlZnQgPCBwYWQpIGxlZnQgPSBwYWQ7CiAgICAg
ICAgaWYgKHRvcCArIHRoID4gd2luZG93LmlubmVySGVpZ2h0IC0gcGFkKQogICAgICAgICAgICB0b3Ag
PSBNYXRoLm1heChwYWQsIGFyLnRvcCAtIHRoIC0gNik7CiAgICAgICAgdGlwLnN0eWxlLmxlZnQgPSBs
ZWZ0ICsgJ3B4JzsKICAgICAgICB0aXAuc3R5bGUudG9wID0gdG9wICsgJ3B4JzsKICAgIH0KICAgICAg
ICBmdW5jdGlvbiBjaGVja0ZpbGVQYXRocyhwYXRocykgewogICAgICAgIGNvbnN0IGxpc3QgPSAocGF0
aHMgfHwgW10pLm1hcChwID0+IHsKICAgICAgICAgICAgbGV0IHBhdGggPSBTdHJpbmcocCB8fCAnJyku
dHJpbSgpOwogICAgICAgICAgICBpZiAoKHBhdGguc3RhcnRzV2l0aCgnIicpICYmIHBhdGguZW5kc1dp
dGgoJyInKSkgfHwgKHBhdGguc3RhcnRzV2l0aCgiJyIpICYmIHBhdGguZW5kc1dpdGgoIiciKSkpCiAg
ICAgICAgICAgICAgICBwYXRoID0gcGF0aC5zbGljZSgxLCAtMSkudHJpbSgpOwogICAgICAgICAgICBy
ZXR1cm4gcGF0aDsKICAgICAgICB9KTsKICAgICAgICAvLyBPbmUgaG9zdCByb3VuZC10cmlwIGZvciB0
aGUgd2hvbGUgbGlzdCDigJQgTsOXIHBhdGhFeGlzdHMgZnJlZXplcyBmaWxlIHRhYgogICAgICAgIHRy
eSB7CiAgICAgICAgICAgIGNvbnN0IHJhdyA9IGFoa1JldCgnY2hlY2tQYXRocycsIGxpc3Quam9pbign
XG4nKSk7CiAgICAgICAgICAgIGlmIChyYXcpIHsKICAgICAgICAgICAgICAgIGNvbnN0IHBhcnNlZCA9
IHR5cGVvZiByYXcgPT09ICdzdHJpbmcnID8gSlNPTi5wYXJzZShyYXcpIDogcmF3OwogICAgICAgICAg
ICAgICAgaWYgKEFycmF5LmlzQXJyYXkocGFyc2VkKSAmJiBwYXJzZWQubGVuZ3RoKSB7CiAgICAgICAg
ICAgICAgICAgICAgcmV0dXJuIGxpc3QubWFwKChwYXRoLCBpKSA9PiB7CiAgICAgICAgICAgICAgICAg
ICAgICAgIGNvbnN0IHJvdyA9IHBhcnNlZFtpXSB8fCB7fTsKICAgICAgICAgICAgICAgICAgICAgICAg
cmV0dXJuIHsKICAgICAgICAgICAgICAgICAgICAgICAgICAgIHBhdGg6IHBhdGggfHwgU3RyaW5nKHJv
dy5wYXRoIHx8ICcnKSwKICAgICAgICAgICAgICAgICAgICAgICAgICAgIGV4aXN0czogcm93LmV4aXN0
cyA9PT0gdHJ1ZSB8fCByb3cuZXhpc3RzID09PSAxIHx8IHJvdy5leGlzdHMgPT09ICcxJywKICAgICAg
ICAgICAgICAgICAgICAgICAgICAgIGlzRGlyOiAhIShyb3cuaXNEaXIgPT09IHRydWUgfHwgcm93Lmlz
RGlyID09PSAxIHx8IHJvdy5pc0RpciA9PT0gJzEnKQogICAgICAgICAgICAgICAgICAgICAgICB9Owog
ICAgICAgICAgICAgICAgICAgIH0pOwogICAgICAgICAgICAgICAgfQogICAgICAgICAgICB9CiAgICAg
ICAgfSBjYXRjaCB7fQogICAgICAgIHJldHVybiBsaXN0Lm1hcChwYXRoID0+IHsKICAgICAgICAgICAg
aWYgKCFwYXRoKSByZXR1cm4geyBwYXRoLCBleGlzdHM6IGZhbHNlLCBpc0RpcjogZmFsc2UgfTsKICAg
ICAgICAgICAgbGV0IGV4aXN0cyA9IGZhbHNlOwogICAgICAgICAgICB0cnkgewogICAgICAgICAgICAg
ICAgY29uc3QgZmxhZyA9IFN0cmluZyhhaGtSZXQoJ3BhdGhFeGlzdHMnLCBwYXRoKSA/PyAnJykudHJp
bSgpLnRvTG93ZXJDYXNlKCk7CiAgICAgICAgICAgICAgICBleGlzdHMgPSAoZmxhZyA9PT0gJzEnIHx8
IGZsYWcgPT09ICd0cnVlJyk7CiAgICAgICAgICAgIH0gY2F0Y2gge30KICAgICAgICAgICAgcmV0dXJu
IHsgcGF0aCwgZXhpc3RzLCBpc0RpcjogZmFsc2UgfTsKICAgICAgICB9KTsKICAgIH0KICAgIGxldCBn
b25lQ2hlY2tUaW1lciA9IDA7CiAgICBmdW5jdGlvbiBzY2hlZHVsZUZpbGVHb25lQ2hlY2soKSB7CiAg
ICAgICAgaWYgKGdvbmVDaGVja1RpbWVyKSByZXR1cm47CiAgICAgICAgZ29uZUNoZWNrVGltZXIgPSBz
ZXRUaW1lb3V0KCgpID0+IHsKICAgICAgICAgICAgZ29uZUNoZWNrVGltZXIgPSAwOwogICAgICAgICAg
ICBjb25zdCBub2RlcyA9IFsuLi5saXN0RWwucXVlcnlTZWxlY3RvckFsbCgnLml0bScpXS5maWx0ZXIo
biA9PiBuLl9maWxlUGF0aHMgJiYgbi5fZmlsZVBhdGhzLmxlbmd0aCk7CiAgICAgICAgICAgIGlmICgh
bm9kZXMubGVuZ3RoKSByZXR1cm47CiAgICAgICAgICAgIGNvbnN0IHVuaXF1ZSA9IFtdOwogICAgICAg
ICAgICBjb25zdCBzZWVuID0gbmV3IFNldCgpOwogICAgICAgICAgICBub2Rlcy5mb3JFYWNoKG4gPT4g
ewogICAgICAgICAgICAgICAgbi5fZmlsZVBhdGhzLmZvckVhY2gocCA9PiB7CiAgICAgICAgICAgICAg
ICAgICAgY29uc3QgcGF0aCA9IFN0cmluZyhwIHx8ICcnKTsKICAgICAgICAgICAgICAgICAgICBpZiAo
IXBhdGggfHwgc2Vlbi5oYXMocGF0aCkpIHJldHVybjsKICAgICAgICAgICAgICAgICAgICBzZWVuLmFk
ZChwYXRoKTsKICAgICAgICAgICAgICAgICAgICB1bmlxdWUucHVzaChwYXRoKTsKICAgICAgICAgICAg
ICAgIH0pOwogICAgICAgICAgICB9KTsKICAgICAgICAgICAgY29uc3Qgcm93cyA9IGNoZWNrRmlsZVBh
dGhzKHVuaXF1ZSk7CiAgICAgICAgICAgIGNvbnN0IGJ5UGF0aCA9IG5ldyBNYXAoKTsKICAgICAgICAg
ICAgcm93cy5mb3JFYWNoKHIgPT4gYnlQYXRoLnNldChTdHJpbmcoci5wYXRoIHx8ICcnKSwgcikpOwog
ICAgICAgICAgICBub2Rlcy5mb3JFYWNoKG4gPT4gewogICAgICAgICAgICAgICAgY29uc3QgcGF0aFJv
d3MgPSBuLl9maWxlUGF0aHMubWFwKHAgPT4gewogICAgICAgICAgICAgICAgICAgIGNvbnN0IGhpdCA9
IGJ5UGF0aC5nZXQoU3RyaW5nKHAgfHwgJycpKTsKICAgICAgICAgICAgICAgICAgICByZXR1cm4gaGl0
IHx8IHsgcGF0aDogcCwgZXhpc3RzOiB0cnVlLCBpc0RpcjogZmFsc2UgfTsKICAgICAgICAgICAgICAg
IH0pOwogICAgICAgICAgICAgICAgbi5fcGF0aFJvd3MgPSBwYXRoUm93czsKICAgICAgICAgICAgICAg
IGNvbnN0IGFsbEdvbmUgPSBwYXRoUm93cy5sZW5ndGggPiAwICYmIHBhdGhSb3dzLmV2ZXJ5KHIgPT4g
ci5leGlzdHMgPT09IGZhbHNlKTsKICAgICAgICAgICAgICAgIG4uY2xhc3NMaXN0LnRvZ2dsZSgnZ29u
ZScsIGFsbEdvbmUpOwogICAgICAgICAgICB9KTsKICAgICAgICB9LCA0MDApOwogICAgfQogICAgZnVu
Y3Rpb24gZmlsbEZpbGVEZXRhaWxQYW5lbChjb250YWluZXIsIHJvd3MpIHsKICAgICAgICBjb250YWlu
ZXIuaW5uZXJIVE1MID0gJyc7CiAgICAgICAgaWYgKCFyb3dzLmxlbmd0aCkgewogICAgICAgICAgICBj
b25zdCBlbXB0eSA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOwogICAgICAgICAgICBlbXB0
eS5jbGFzc05hbWUgPSAnZmQtcGF0aCc7CiAgICAgICAgICAgIGVtcHR5LnRleHRDb250ZW50ID0gJ+aX
oOi3r+W+hCc7CiAgICAgICAgICAgIGNvbnRhaW5lci5hcHBlbmRDaGlsZChlbXB0eSk7CiAgICAgICAg
ICAgIHJldHVybjsKICAgICAgICB9CiAgICAgICAgcm93cy5mb3JFYWNoKHIgPT4gewogICAgICAgICAg
ICBjb25zdCBwYXRoID0gU3RyaW5nKHIucGF0aCB8fCAnJyk7CiAgICAgICAgICAgIGNvbnN0IG1pc3Np
bmcgPSByLmV4aXN0cyA9PT0gZmFsc2U7CiAgICAgICAgICAgIGNvbnN0IGJsb2NrID0gZG9jdW1lbnQu
Y3JlYXRlRWxlbWVudCgnZGl2Jyk7CiAgICAgICAgICAgIGJsb2NrLmNsYXNzTmFtZSA9ICdmZC1ibG9j
ayc7CgogICAgICAgICAgICBjb25zdCBwYXRoRWwgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYn
KTsKICAgICAgICAgICAgcGF0aEVsLmNsYXNzTmFtZSA9ICdmZC1wYXRoJyArIChtaXNzaW5nID8gJyBk
ZWFkJyA6ICcgbGl2ZScpOwogICAgICAgICAgICBwYXRoRWwudGV4dENvbnRlbnQgPSBwYXRoIHx8ICco
56m66Lev5b6EKSc7CiAgICAgICAgICAgIGlmICghbWlzc2luZykgewogICAgICAgICAgICAgICAgcGF0
aEVsLm9uY2xpY2sgPSBlID0+IHsKICAgICAgICAgICAgICAgICAgICBlLnByZXZlbnREZWZhdWx0KCk7
CiAgICAgICAgICAgICAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICAgICAgICAgICAg
ICBhaGsoJ29wZW5QYXRoJywgcGF0aCk7CiAgICAgICAgICAgICAgICB9OwogICAgICAgICAgICB9CiAg
ICAgICAgICAgIGJsb2NrLmFwcGVuZENoaWxkKHBhdGhFbCk7CgogICAgICAgICAgICBjb25zdCBhY3Rp
b25zID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnZGl2Jyk7CiAgICAgICAgICAgIGFjdGlvbnMuY2xh
c3NOYW1lID0gJ2ZkLWFjdGlvbnMnOwoKICAgICAgICAgICAgY29uc3QgY29weUJ0biA9IGRvY3VtZW50
LmNyZWF0ZUVsZW1lbnQoJ2J1dHRvbicpOwogICAgICAgICAgICBjb3B5QnRuLnR5cGUgPSAnYnV0dG9u
JzsKICAgICAgICAgICAgY29weUJ0bi5jbGFzc05hbWUgPSAnZmQtYnRuJzsKICAgICAgICAgICAgY29w
eUJ0bi5pbm5lckhUTUwgPSAnPHNwYW4gY2xhc3M9ImZkLWljbyI+8J+Ulzwvc3Bhbj48c3BhbiBjbGFz
cz0iZmQtdHh0Ij7lpI3liLbot6/lvoQ8L3NwYW4+JzsKICAgICAgICAgICAgY29weUJ0bi5vbmNsaWNr
ID0gZSA9PiB7CiAgICAgICAgICAgICAgICBlLnByZXZlbnREZWZhdWx0KCk7CiAgICAgICAgICAgICAg
ICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgICAgICAgICAgICAgYWhrKCdjb3B5UGF0aCcsIHBhdGgp
OwogICAgICAgICAgICAgICAgY29weUJ0bi5xdWVyeVNlbGVjdG9yKCcuZmQtdHh0JykudGV4dENvbnRl
bnQgPSAn5bey5aSN5Yi2JzsKICAgICAgICAgICAgICAgIGNvcHlCdG4uY2xhc3NMaXN0LmFkZCgnb2sn
KTsKICAgICAgICAgICAgICAgIHNldFRpbWVvdXQoKCkgPT4gewogICAgICAgICAgICAgICAgICAgIGNv
cHlCdG4ucXVlcnlTZWxlY3RvcignLmZkLXR4dCcpLnRleHRDb250ZW50ID0gJ+WkjeWItui3r+W+hCc7
CiAgICAgICAgICAgICAgICAgICAgY29weUJ0bi5jbGFzc0xpc3QucmVtb3ZlKCdvaycpOwogICAgICAg
ICAgICAgICAgfSwgMTIwMCk7CiAgICAgICAgICAgIH07CiAgICAgICAgICAgIGFjdGlvbnMuYXBwZW5k
Q2hpbGQoY29weUJ0bik7CgogICAgICAgICAgICBjb25zdCBmb2xkZXJCdG4gPSBkb2N1bWVudC5jcmVh
dGVFbGVtZW50KCdidXR0b24nKTsKICAgICAgICAgICAgZm9sZGVyQnRuLnR5cGUgPSAnYnV0dG9uJzsK
ICAgICAgICAgICAgZm9sZGVyQnRuLmNsYXNzTmFtZSA9ICdmZC1idG4nOwogICAgICAgICAgICBmb2xk
ZXJCdG4uaW5uZXJIVE1MID0gJzxzcGFuIGNsYXNzPSJmZC1pY28iPvCfk4I8L3NwYW4+PHNwYW4gY2xh
c3M9ImZkLXR4dCI+5omT5byA5omA5Zyo5paH5Lu25aS5PC9zcGFuPic7CiAgICAgICAgICAgIGZvbGRl
ckJ0bi5vbmNsaWNrID0gZSA9PiB7CiAgICAgICAgICAgICAgICBlLnByZXZlbnREZWZhdWx0KCk7CiAg
ICAgICAgICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgICAgICAgICAgICAgYWhrKCdvcGVu
Rm9sZGVyJywgcGF0aCk7CiAgICAgICAgICAgIH07CiAgICAgICAgICAgIGFjdGlvbnMuYXBwZW5kQ2hp
bGQoZm9sZGVyQnRuKTsKCiAgICAgICAgICAgIGJsb2NrLmFwcGVuZENoaWxkKGFjdGlvbnMpOwogICAg
ICAgICAgICBjb250YWluZXIuYXBwZW5kQ2hpbGQoYmxvY2spOwogICAgICAgIH0pOwogICAgfQoKICAg
IGNvbnN0IGN0eEVsID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2N0eCcpOwogICAgZnVuY3Rpb24g
c2hvd0N0eCh4LCB5LCBjKSB7CiAgICAgICAgY3R4Q2xpcCA9IGM7CiAgICAgICAgc2VsZWN0ZWRJZCA9
IGMuaWQ7CiAgICAgICAgcmFuZ2VBbmNob3JJZCA9IGMuaWQ7CiAgICAgICAgcmFuZ2VBbmNob3JDbGlj
a2VkID0gdHJ1ZTsKICAgICAgICBjb25zdCBjbGVhckJ0biA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlk
KCdjLWNsZWFyLXBhc3RlZCcpOwogICAgICAgIGlmIChjbGVhckJ0bikgY2xlYXJCdG4uc3R5bGUuZGlz
cGxheSA9IGlzUGFzdGVkKGMpID8gJycgOiAnbm9uZSc7CiAgICAgICAgY29uc3QgcUZyb20gPSBkb2N1
bWVudC5nZXRFbGVtZW50QnlJZCgnYy1xdWV1ZS1mcm9tJyk7CiAgICAgICAgaWYgKHFGcm9tKSBxRnJv
bS5zdHlsZS5kaXNwbGF5ID0gKE51bWJlcihjLnF1ZXVlR3JvdXApID4gMCkgPyAnJyA6ICdub25lJzsK
CiAgICAgICAgY29uc3QgcGluQnRuID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2MtcGluJyk7CiAg
ICAgICAgY29uc3QgY29weUJ0biA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjLWNvcHknKTsKICAg
ICAgICBjb25zdCBpc1JlY2VudCA9IG5vcm1UeXBlKGMudHlwZSkgPT09ICdyZWNlbnQnIHx8IGN1clRh
YiA9PT0gJ3JlY2VudCc7CiAgICAgICAgaWYgKGNvcHlCdG4pIHsKICAgICAgICAgICAgY29weUJ0bi5p
bm5lckhUTUwgPSBpc1JlY2VudAogICAgICAgICAgICAgICAgPyAnPHNwYW4gY2xhc3M9ImMtaWNvIj7w
n5SXPC9zcGFuPuWkjeWItui3r+W+hCcKICAgICAgICAgICAgICAgIDogJzxzcGFuIGNsYXNzPSJjLWlj
byI+4o6YPC9zcGFuPuWkjeWItic7CiAgICAgICAgICAgIGNvcHlCdG4uc3R5bGUuZGlzcGxheSA9ICcn
OwogICAgICAgIH0KICAgICAgICBpZiAocGluQnRuKSB7CiAgICAgICAgICAgIGlmIChpc1JlY2VudCkg
ewogICAgICAgICAgICAgICAgLy8gUmVjZW50IGZvbGRlcnM6IHBpbiA9IGtlZXAgcGF0aCAobm90IGNs
aXBib2FyZCDmlLbol48pCiAgICAgICAgICAgICAgICBwaW5CdG4uc3R5bGUuZGlzcGxheSA9ICcnOwog
ICAgICAgICAgICAgICAgY29uc3Qgb24gPSBpc1Bpbm5lZChjKTsKICAgICAgICAgICAgICAgIHBpbkJ0
bi5pbm5lckhUTUwgPSBvbgogICAgICAgICAgICAgICAgICAgID8gJzxzcGFuIGNsYXNzPSJjLWljbyI+
4piFPC9zcGFuPuWPlua2iOWbuuWumicKICAgICAgICAgICAgICAgICAgICA6ICc8c3BhbiBjbGFzcz0i
Yy1pY28iPuKYhTwvc3Bhbj7lm7rlrprot6/lvoQnOwogICAgICAgICAgICB9IGVsc2UgewogICAgICAg
ICAgICAgICAgcGluQnRuLnN0eWxlLmRpc3BsYXkgPSAnJzsKICAgICAgICAgICAgICAgIGNvbnN0IG11
bHRpUGluID0gbXVsdGlJZHMubGVuZ3RoID4gMSAmJiBtdWx0aUlkcy5pbmNsdWRlcygrYy5pZCk7CiAg
ICAgICAgICAgICAgICBjb25zdCBwaW5JZHMgPSBtdWx0aVBpbiA/IG11bHRpSWRzLnNsaWNlKCkgOiBb
K2MuaWRdOwogICAgICAgICAgICAgICAgbGV0IGFueU9mZiA9IGZhbHNlOwogICAgICAgICAgICAgICAg
Zm9yIChjb25zdCBwaWQgb2YgcGluSWRzKSB7CiAgICAgICAgICAgICAgICAgICAgY29uc3QgeCA9ICgr
cGlkID09PSArYy5pZCkgPyBjIDogYWxsQ2xpcHMuZmluZCh0ID0+ICt0LmlkID09PSArcGlkKTsKICAg
ICAgICAgICAgICAgICAgICBpZiAoeCAmJiAhaXNQaW5uZWQoeCkpIHsgYW55T2ZmID0gdHJ1ZTsgYnJl
YWs7IH0KICAgICAgICAgICAgICAgICAgICBpZiAoIXggJiYgK3BpZCA9PT0gK2MuaWQgJiYgIWlzUGlu
bmVkKGMpKSB7IGFueU9mZiA9IHRydWU7IGJyZWFrOyB9CiAgICAgICAgICAgICAgICB9CiAgICAgICAg
ICAgICAgICBpZiAobXVsdGlQaW4pIHsKICAgICAgICAgICAgICAgICAgICBwaW5CdG4uaW5uZXJIVE1M
ID0gYW55T2ZmCiAgICAgICAgICAgICAgICAgICAgICAgID8gKCc8c3BhbiBjbGFzcz0iYy1pY28iPuKY
hTwvc3Bhbj7mlLbol48gKCcgKyBwaW5JZHMubGVuZ3RoICsgJyknKQogICAgICAgICAgICAgICAgICAg
ICAgICA6ICgnPHNwYW4gY2xhc3M9ImMtaWNvIj7imIU8L3NwYW4+5Y+W5raI5pS26JePICgnICsgcGlu
SWRzLmxlbmd0aCArICcpJyk7CiAgICAgICAgICAgICAgICB9IGVsc2UgewogICAgICAgICAgICAgICAg
ICAgIHBpbkJ0bi5pbm5lckhUTUwgPSBpc1Bpbm5lZChjKQogICAgICAgICAgICAgICAgICAgICAgICA/
ICc8c3BhbiBjbGFzcz0iYy1pY28iPuKYhTwvc3Bhbj7lj5bmtojmlLbol48nCiAgICAgICAgICAgICAg
ICAgICAgICAgIDogJzxzcGFuIGNsYXNzPSJjLWljbyI+4piFPC9zcGFuPuaUtuiXjyc7CiAgICAgICAg
ICAgICAgICB9CiAgICAgICAgICAgIH0KICAgICAgICB9CiAgICAgICAgY29uc3QgdGl0bGVCdG4gPSBk
b2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYy10aXRsZScpOwogICAgICAgIGlmICh0aXRsZUJ0bikgewog
ICAgICAgICAgICAvLyBObyBmYXYtdGl0bGUgZm9yIHJlY2VudCBwYXRocwogICAgICAgICAgICBjb25z
dCBzaG93VGl0bGUgPSAhaXNSZWNlbnQgJiYgKGlzUGlubmVkKGMpIHx8IGN1clRhYiA9PT0gJ3Bpbm5l
ZCcpOwogICAgICAgICAgICB0aXRsZUJ0bi5zdHlsZS5kaXNwbGF5ID0gc2hvd1RpdGxlID8gJycgOiAn
bm9uZSc7CiAgICAgICAgICAgIGlmIChzaG93VGl0bGUpCiAgICAgICAgICAgICAgICB0aXRsZUJ0bi5p
bm5lckhUTUwgPSAoU3RyaW5nKGMuZmF2VGl0bGUgfHwgJycpLnRyaW0oKSA/ICc8c3BhbiBjbGFzcz0i
Yy1pY28iPuKcjjwvc3Bhbj7nvJbovpHmoIfpopgnIDogJzxzcGFuIGNsYXNzPSJjLWljbyI+4pyOPC9z
cGFuPuiuvue9ruagh+mimCcpOwogICAgICAgIH0KICAgICAgICBjb25zdCBtZXJnZUJ0biA9IGRvY3Vt
ZW50LmdldEVsZW1lbnRCeUlkKCdjLW1lcmdlJyk7CiAgICAgICAgY29uc3QgdW5tZXJnZUJ0biA9IGRv
Y3VtZW50LmdldEVsZW1lbnRCeUlkKCdjLXVubWVyZ2UnKTsKICAgICAgICBjb25zdCBvblBpbm5lZCA9
IGN1clRhYiA9PT0gJ3Bpbm5lZCc7CiAgICAgICAgaWYgKG1lcmdlQnRuKQogICAgICAgICAgICBtZXJn
ZUJ0bi5zdHlsZS5kaXNwbGF5ID0gKCFpc1JlY2VudCAmJiBvblBpbm5lZCAmJiBtdWx0aUlkcy5sZW5n
dGggPj0gMikgPyAnJyA6ICdub25lJzsKICAgICAgICBpZiAodW5tZXJnZUJ0bikKICAgICAgICAgICAg
dW5tZXJnZUJ0bi5zdHlsZS5kaXNwbGF5ID0gKCFpc1JlY2VudCAmJiBvblBpbm5lZCAmJiBmYXZHcm91
cE9mKGMpKSA/ICcnIDogJ25vbmUnOwogICAgICAgIGNvbnN0IHRvcEJ0biA9IGRvY3VtZW50LmdldEVs
ZW1lbnRCeUlkKCdjLXRvcCcpOwogICAgICAgIGlmICh0b3BCdG4pCiAgICAgICAgICAgIHRvcEJ0bi5z
dHlsZS5kaXNwbGF5ID0gaXNSZWNlbnQgPyAnbm9uZScgOiAnJzsKICAgICAgICBjb25zdCBjbGVhckJ0
bjIgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYy1jbGVhci1wYXN0ZWQnKTsKICAgICAgICBpZiAo
Y2xlYXJCdG4yICYmIGlzUmVjZW50KQogICAgICAgICAgICBjbGVhckJ0bjIuc3R5bGUuZGlzcGxheSA9
ICdub25lJzsKICAgICAgICBjb25zdCBxRnJvbTIgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYy1x
dWV1ZS1mcm9tJyk7CiAgICAgICAgaWYgKHFGcm9tMiAmJiBpc1JlY2VudCkKICAgICAgICAgICAgcUZy
b20yLnN0eWxlLmRpc3BsYXkgPSAnbm9uZSc7CiAgICAgICAgY29uc3QgZGVsQnRuID0gZG9jdW1lbnQu
Z2V0RWxlbWVudEJ5SWQoJ2MtZGVsJyk7CiAgICAgICAgaWYgKGRlbEJ0bikgewogICAgICAgICAgICBj
b25zdCBtdWx0aURlbCA9IG11bHRpSWRzLmxlbmd0aCA+IDEgJiYgbXVsdGlJZHMuaW5jbHVkZXMoK2Mu
aWQpOwogICAgICAgICAgICBjb25zdCBuID0gbXVsdGlEZWwgPyBtdWx0aUlkcy5sZW5ndGggOiAxOwog
ICAgICAgICAgICBkZWxCdG4uaW5uZXJIVE1MID0gbiA+IDEKICAgICAgICAgICAgICAgID8gKCc8c3Bh
biBjbGFzcz0iYy1pY28iPuKclTwvc3Bhbj7liKDpmaQgKCcgKyBuICsgJyknKQogICAgICAgICAgICAg
ICAgOiAnPHNwYW4gY2xhc3M9ImMtaWNvIj7inJU8L3NwYW4+5Yig6ZmkJzsKICAgICAgICB9CiAgICAg
ICAgY29uc3QgZGF0YVdyYXAgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYy1kYXRhLXdyYXAnKTsK
ICAgICAgICBjb25zdCBkYXRhU2VwID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2MtZGF0YS1zZXAn
KTsKICAgICAgICBjb25zdCBzaG93RGF0YSA9ICFpc1JlY2VudCAmJiAobm9ybVR5cGUoYy50eXBlKSA9
PT0gJ3RleHQnIHx8IG5vcm1UeXBlKGMudHlwZSkgPT09ICdsaW5rJyk7CiAgICAgICAgaWYgKGRhdGFX
cmFwKSBkYXRhV3JhcC5zdHlsZS5kaXNwbGF5ID0gc2hvd0RhdGEgPyAnJyA6ICdub25lJzsKICAgICAg
ICBpZiAoZGF0YVNlcCkgZGF0YVNlcC5zdHlsZS5kaXNwbGF5ID0gc2hvd0RhdGEgPyAnJyA6ICdub25l
JzsKICAgICAgICBpZiAoZGF0YVdyYXApIGRhdGFXcmFwLmNsYXNzTGlzdC5yZW1vdmUoJ29wZW4nKTsK
ICAgICAgICBjdHhFbC5jbGFzc0xpc3QuYWRkKCdvbicpOwogICAgICAgIGN0eEVsLnN0eWxlLmxlZnQg
PSB4ICsgJ3B4JzsKICAgICAgICBjdHhFbC5zdHlsZS50b3AgID0geSArICdweCc7CiAgICAgICAgcmVx
dWVzdEFuaW1hdGlvbkZyYW1lKCgpID0+IHsKICAgICAgICAgICAgY29uc3QgciA9IGN0eEVsLmdldEJv
dW5kaW5nQ2xpZW50UmVjdCgpOwogICAgICAgICAgICBpZiAoci5yaWdodCAgPiBpbm5lcldpZHRoKSAg
Y3R4RWwuc3R5bGUubGVmdCA9ICh4IC0gci53aWR0aCkgICsgJ3B4JzsKICAgICAgICAgICAgaWYgKHIu
Ym90dG9tID4gaW5uZXJIZWlnaHQpIGN0eEVsLnN0eWxlLnRvcCAgPSAoeSAtIHIuaGVpZ2h0KSArICdw
eCc7CiAgICAgICAgICAgIHBsYWNlRGF0YVN1Ym1lbnUoKTsKICAgICAgICB9KTsKICAgIH0KICAgIGZ1
bmN0aW9uIHBsYWNlRGF0YVN1Ym1lbnUoKSB7CiAgICAgICAgY29uc3Qgd3JhcCA9IGRvY3VtZW50Lmdl
dEVsZW1lbnRCeUlkKCdjLWRhdGEtd3JhcCcpOwogICAgICAgIGNvbnN0IHN1YiA9IGRvY3VtZW50Lmdl
dEVsZW1lbnRCeUlkKCdjLWRhdGEtc3ViJyk7CiAgICAgICAgaWYgKCF3cmFwIHx8ICFzdWIgfHwgd3Jh
cC5zdHlsZS5kaXNwbGF5ID09PSAnbm9uZScpIHJldHVybjsKICAgICAgICBjb25zdCBwYWQgPSA0Owog
ICAgICAgIC8vIE1lYXN1cmUgd2hpbGUgdGVtcG9yYXJpbHkgdmlzaWJsZSAoc3VibWVudSBtYXkgc3Rp
bGwgYmUgZGlzcGxheTpub25lKQogICAgICAgIGNvbnN0IHByZXZEaXNwbGF5ID0gc3ViLnN0eWxlLmRp
c3BsYXk7CiAgICAgICAgY29uc3QgcHJldlZpc2liaWxpdHkgPSBzdWIuc3R5bGUudmlzaWJpbGl0eTsK
ICAgICAgICBjb25zdCBwcmV2TGVmdCA9IHN1Yi5zdHlsZS5sZWZ0OwogICAgICAgIGNvbnN0IHByZXZS
aWdodCA9IHN1Yi5zdHlsZS5yaWdodDsKICAgICAgICBzdWIuY2xhc3NMaXN0LnJlbW92ZSgnbGVmdCcp
OwogICAgICAgIHN1Yi5zdHlsZS5sZWZ0ID0gJ2NhbGMoMTAwJSAtIDJweCknOwogICAgICAgIHN1Yi5z
dHlsZS5yaWdodCA9ICdhdXRvJzsKICAgICAgICBzdWIuc3R5bGUudmlzaWJpbGl0eSA9ICdoaWRkZW4n
OwogICAgICAgIHN1Yi5zdHlsZS5kaXNwbGF5ID0gJ2Jsb2NrJzsKICAgICAgICBjb25zdCBzdWJXID0g
TWF0aC5jZWlsKHN1Yi5nZXRCb3VuZGluZ0NsaWVudFJlY3QoKS53aWR0aCB8fCBzdWIub2Zmc2V0V2lk
dGggfHwgMCk7CiAgICAgICAgY29uc3Qgd3JhcFJlY3QgPSB3cmFwLmdldEJvdW5kaW5nQ2xpZW50UmVj
dCgpOwogICAgICAgIHN1Yi5zdHlsZS5kaXNwbGF5ID0gcHJldkRpc3BsYXk7CiAgICAgICAgc3ViLnN0
eWxlLnZpc2liaWxpdHkgPSBwcmV2VmlzaWJpbGl0eTsKICAgICAgICBzdWIuc3R5bGUubGVmdCA9IHBy
ZXZMZWZ0OwogICAgICAgIHN1Yi5zdHlsZS5yaWdodCA9IHByZXZSaWdodDsKCiAgICAgICAgaWYgKHN1
YlcgPD0gMCkgcmV0dXJuOwogICAgICAgIGNvbnN0IHNwYWNlUmlnaHQgPSB3aW5kb3cuaW5uZXJXaWR0
aCAtIHdyYXBSZWN0LnJpZ2h0IC0gcGFkOwogICAgICAgIGNvbnN0IHNwYWNlTGVmdCA9IHdyYXBSZWN0
LmxlZnQgLSBwYWQ7CiAgICAgICAgY29uc3QgZml0c1JpZ2h0ID0gc3BhY2VSaWdodCA+PSBzdWJXOwog
ICAgICAgIGNvbnN0IGZpdHNMZWZ0ID0gc3BhY2VMZWZ0ID49IHN1Ylc7CiAgICAgICAgbGV0IG9wZW5M
ZWZ0ID0gZmFsc2U7CiAgICAgICAgaWYgKGZpdHNSaWdodCkgb3BlbkxlZnQgPSBmYWxzZTsKICAgICAg
ICBlbHNlIGlmIChmaXRzTGVmdCkgb3BlbkxlZnQgPSB0cnVlOwogICAgICAgIGVsc2Ugb3BlbkxlZnQg
PSBzcGFjZUxlZnQgPiBzcGFjZVJpZ2h0OyAvLyBuZWl0aGVyIGZpdHMg4oCUIHBpY2sgdGhlIGxhcmdl
ciBnYXAKCiAgICAgICAgaWYgKG9wZW5MZWZ0KSB7CiAgICAgICAgICAgIHN1Yi5jbGFzc0xpc3QuYWRk
KCdsZWZ0Jyk7CiAgICAgICAgICAgIHN1Yi5zdHlsZS5sZWZ0ID0gJ2F1dG8nOwogICAgICAgICAgICBz
dWIuc3R5bGUucmlnaHQgPSAnY2FsYygxMDAlIC0gMnB4KSc7CiAgICAgICAgfSBlbHNlIHsKICAgICAg
ICAgICAgc3ViLmNsYXNzTGlzdC5yZW1vdmUoJ2xlZnQnKTsKICAgICAgICAgICAgc3ViLnN0eWxlLmxl
ZnQgPSAnY2FsYygxMDAlIC0gMnB4KSc7CiAgICAgICAgICAgIHN1Yi5zdHlsZS5yaWdodCA9ICdhdXRv
JzsKICAgICAgICB9CiAgICB9CiAgICBmdW5jdGlvbiBoaWRlQ3R4KCkgewogICAgICAgIGN0eEVsLmNs
YXNzTGlzdC5yZW1vdmUoJ29uJyk7CiAgICAgICAgY3R4Q2xpcCA9IG51bGw7CiAgICAgICAgdHJ5IHsK
ICAgICAgICAgICAgY29uc3Qgd3JhcCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjLWRhdGEtd3Jh
cCcpOwogICAgICAgICAgICBpZiAod3JhcCkgd3JhcC5jbGFzc0xpc3QucmVtb3ZlKCdvcGVuJyk7CiAg
ICAgICAgICAgIGNsZWFyRGF0YVN1Ym1lbnVQaWNrKCk7CiAgICAgICAgICAgIHByZXZpZXdEYXRhVHJh
bnNmb3JtU2VxKys7CiAgICAgICAgfSBjYXRjaCB7fQogICAgfQogICAgd2luZG93Ll9faGlkZUN0eCA9
IGhpZGVDdHg7CgogICAgZnVuY3Rpb24gZGlzbWlzc0N0eFVubGVzc0luc2lkZShlKSB7CiAgICAgICAg
aWYgKCFjdHhFbC5jbGFzc0xpc3QuY29udGFpbnMoJ29uJykpIHJldHVybjsKICAgICAgICBpZiAoZS50
YXJnZXQuY2xvc2VzdCgnI2N0eCcpKSByZXR1cm47CiAgICAgICAgaGlkZUN0eCgpOwogICAgfQogICAg
ZG9jdW1lbnQuYWRkRXZlbnRMaXN0ZW5lcignbW91c2Vkb3duJywgZGlzbWlzc0N0eFVubGVzc0luc2lk
ZSwgdHJ1ZSk7CiAgICBkb2N1bWVudC5hZGRFdmVudExpc3RlbmVyKCdjbGljaycsIGRpc21pc3NDdHhV
bmxlc3NJbnNpZGUsIHRydWUpOwogICAgbGlzdEVsLmFkZEV2ZW50TGlzdGVuZXIoJ3Njcm9sbCcsIGhp
ZGVDdHgsIHsgcGFzc2l2ZTogdHJ1ZSB9KTsKICAgIGRvY3VtZW50LmFkZEV2ZW50TGlzdGVuZXIoJ2tl
eWRvd24nLCBlID0+IHsKICAgICAgICAvLyBFc2M6IGFsd2F5cyBjbG9zZSBwYW5lbCAoc2VhcmNoIG9y
IG5vdCk7IHBpbiBrZWVwcyBwYW5lbAogICAgICAgIGlmIChlLmtleSA9PT0gJ0VzY2FwZScpIHsKICAg
ICAgICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOwogICAgICAgICAgICBoaWRlQ3R4KCk7CiAgICAgICAg
ICAgIGNvbnN0IHRkID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3RpdGxlLWRsZycpOwogICAgICAg
ICAgICBpZiAodGQgJiYgdGQuY2xhc3NMaXN0LmNvbnRhaW5zKCdvbicpKSB7CiAgICAgICAgICAgICAg
ICB0cnkgeyBjbG9zZVRpdGxlRGxnKCk7IH0gY2F0Y2ggeyB0ZC5jbGFzc0xpc3QucmVtb3ZlKCdvbicp
OyB9CiAgICAgICAgICAgICAgICByZXR1cm47CiAgICAgICAgICAgIH0KICAgICAgICAgICAgaWYgKGNs
ckRsZy5jbGFzc0xpc3QuY29udGFpbnMoJ29uJykpIHsKICAgICAgICAgICAgICAgIGNsb3NlQ2xlYXJE
bGcoKTsKICAgICAgICAgICAgICAgIHJldHVybjsKICAgICAgICAgICAgfQogICAgICAgICAgICBpZiAo
IXBpbm5lZFVJKSBhaGsoJ2hpZGUnKTsKICAgICAgICAgICAgcmV0dXJuOwogICAgICAgIH0KICAgICAg
ICAvLyBXaGlsZSB0eXBpbmcgaW4gc2VhcmNoOiBDdHJsK0kvSyBhbmQgYXJyb3dzIG1vdmUgbGlzdCwg
ZG9uJ3QgbGVhdmUgdGhlIGJveAogICAgICAgIGlmIChkb2N1bWVudC5hY3RpdmVFbGVtZW50Py5pZCA9
PT0gJ3NlYXJjaCcpIHsKICAgICAgICAgICAgaWYgKChlLmN0cmxLZXkgfHwgZS5tZXRhS2V5KSAmJiAo
ZS5rZXkgPT09ICdpJyB8fCBlLmtleSA9PT0gJ0knKSkgewogICAgICAgICAgICAgICAgZS5wcmV2ZW50
RGVmYXVsdCgpOyBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgICAgICAgICAgICAgd2luZG93Ll9fbmF2
ICYmIHdpbmRvdy5fX25hdigndXAnKTsKICAgICAgICAgICAgICAgIHJldHVybjsKICAgICAgICAgICAg
fQogICAgICAgICAgICBpZiAoKGUuY3RybEtleSB8fCBlLm1ldGFLZXkpICYmIChlLmtleSA9PT0gJ2sn
IHx8IGUua2V5ID09PSAnSycpKSB7CiAgICAgICAgICAgICAgICBlLnByZXZlbnREZWZhdWx0KCk7IGUu
c3RvcFByb3BhZ2F0aW9uKCk7CiAgICAgICAgICAgICAgICB3aW5kb3cuX19uYXYgJiYgd2luZG93Ll9f
bmF2KCdkb3duJyk7CiAgICAgICAgICAgICAgICByZXR1cm47CiAgICAgICAgICAgIH0KICAgICAgICAg
ICAgaWYgKGUua2V5ID09PSAnQXJyb3dEb3duJykgewogICAgICAgICAgICAgICAgZS5wcmV2ZW50RGVm
YXVsdCgpOyBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgICAgICAgICAgICAgd2luZG93Ll9fbmF2ICYm
IHdpbmRvdy5fX25hdignZG93bicpOwogICAgICAgICAgICAgICAgcmV0dXJuOwogICAgICAgICAgICB9
CiAgICAgICAgICAgIGlmIChlLmtleSA9PT0gJ0Fycm93VXAnKSB7CiAgICAgICAgICAgICAgICBlLnBy
ZXZlbnREZWZhdWx0KCk7IGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAgICAgICAgICAgICB3aW5kb3cu
X19uYXYgJiYgd2luZG93Ll9fbmF2KCd1cCcpOwogICAgICAgICAgICAgICAgcmV0dXJuOwogICAgICAg
ICAgICB9CiAgICAgICAgICAgIHJldHVybjsKICAgICAgICB9CiAgICAgICAgY29uc3QgdmlzID0gKHR5
cGVvZiBuYXZMaXN0ID09PSAnZnVuY3Rpb24nID8gbmF2TGlzdCgpIDogdmlzaWJsZUxpc3QoKSk7CiAg
ICAgICAgaWYgKCF2aXMubGVuZ3RoKSByZXR1cm47CiAgICAgICAgbGV0IGlkeCA9IHNlbGVjdGVkSW5k
ZXgoKTsKICAgICAgICBpZiAoaWR4IDwgMCkgaWR4ID0gMDsKICAgICAgICBpZiAgICAgIChlLmtleSA9
PT0gJ0Fycm93RG93bicpIHsgZS5wcmV2ZW50RGVmYXVsdCgpOyBlLnN0b3BQcm9wYWdhdGlvbigpOyBz
ZWxlY3RCeUluZGV4KGlkeCArIDEpOyB9CiAgICAgICAgZWxzZSBpZiAoZS5rZXkgPT09ICdBcnJvd1Vw
JykgICB7IGUucHJldmVudERlZmF1bHQoKTsgZS5zdG9wUHJvcGFnYXRpb24oKTsgc2VsZWN0QnlJbmRl
eChpZHggLSAxKTsgfQogICAgICAgIGVsc2UgaWYgKGUua2V5ID09PSAnRW50ZXInKSB7CiAgICAgICAg
ICAgIGUucHJldmVudERlZmF1bHQoKTsKICAgICAgICAgICAgLy8g5Zu65a6a5pe25Zue6L2m5LiN57KY
6LS077yM5Y+q54K55p2h55uu57KY6LS0CiAgICAgICAgICAgIGlmIChwaW5uZWRVSSkgcmV0dXJuOwog
ICAgICAgICAgICBpZiAobXVsdGlJZHMubGVuZ3RoID49IDEpIHsKICAgICAgICAgICAgICAgIGNvbnN0
IGlkcyA9IG11bHRpSWRzLnNsaWNlKCk7CiAgICAgICAgICAgICAgICBjbGVhck11bHRpKCk7CiAgICAg
ICAgICAgICAgICBtYXJrUGFzdGVkTG9jYWwoaWRzKTsKICAgICAgICAgICAgICAgIHBhc3RlTWFueVdp
dGhTZXAoaWRzKTsKICAgICAgICAgICAgICAgIHJldHVybjsKICAgICAgICAgICAgfQogICAgICAgICAg
ICBjb25zdCBjID0gdmlzW3NlbGVjdGVkSW5kZXgoKV07CiAgICAgICAgICAgIGlmIChjKSB7CiAgICAg
ICAgICAgICAgICBtYXJrUGFzdGVkTG9jYWwoYy5pZCk7CiAgICAgICAgICAgICAgICBhaGsoJ3Bhc3Rl
JywgU3RyaW5nKGMuaWQpKTsKICAgICAgICAgICAgfQogICAgICAgIH0gZWxzZSBpZiAoL15bMS05XSQv
LnRlc3QoZS5rZXkpKSB7CiAgICAgICAgICAgIGNvbnN0IGMgPSB2aXNbK2Uua2V5IC0gMV07CiAgICAg
ICAgICAgIGlmIChjKSB7CiAgICAgICAgICAgICAgICBtYXJrUGFzdGVkTG9jYWwoYy5pZCk7CiAgICAg
ICAgICAgICAgICBhaGsoJ3Bhc3RlJywgU3RyaW5nKGMuaWQpKTsKICAgICAgICAgICAgfQogICAgICAg
IH0KICAgIH0pOwoKICAgIHdpbmRvdy5fX25hdiA9IGRpciA9PiB7CiAgICAgICAgY29uc3QgdmlzID0g
KHR5cGVvZiBuYXZMaXN0ID09PSAnZnVuY3Rpb24nID8gbmF2TGlzdCgpIDogdmlzaWJsZUxpc3QoKSk7
CiAgICAgICAgaWYgKCF2aXMubGVuZ3RoICYmIGRpciAhPT0gJ3RhYicgJiYgZGlyICE9PSAndGFiUHJl
dicpIHJldHVybjsKICAgICAgICBsZXQgaWR4ID0gc2VsZWN0ZWRJbmRleCgpOwogICAgICAgIGlmIChp
ZHggPCAwKSBpZHggPSAwOwogICAgICAgIGlmIChkaXIgPT09ICd1cCcpIHNlbGVjdEJ5SW5kZXgoaWR4
IC0gMSk7CiAgICAgICAgZWxzZSBpZiAoZGlyID09PSAnZG93bicpIHNlbGVjdEJ5SW5kZXgoaWR4ICsg
MSk7CiAgICAgICAgZWxzZSBpZiAoZGlyID09PSAnZW50ZXInKSB7CiAgICAgICAgICAgIGlmIChwaW5u
ZWRVSSkgcmV0dXJuOwogICAgICAgICAgICBfX3ByZXBQYXN0ZSgpOwogICAgICAgICAgICBpZiAobXVs
dGlJZHMubGVuZ3RoID49IDEpIHsKICAgICAgICAgICAgICAgIGNvbnN0IGlkcyA9IG11bHRpSWRzLnNs
aWNlKCk7CiAgICAgICAgICAgICAgICBjbGVhck11bHRpKCk7CiAgICAgICAgICAgICAgICBtYXJrUGFz
dGVkTG9jYWwoaWRzKTsKICAgICAgICAgICAgICAgIHBhc3RlTWFueVdpdGhTZXAoaWRzKTsKICAgICAg
ICAgICAgICAgIHJldHVybjsKICAgICAgICAgICAgfQogICAgICAgICAgICBjb25zdCBjID0gdmlzW3Nl
bGVjdGVkSW5kZXgoKV07CiAgICAgICAgICAgIGlmIChjKSB7CiAgICAgICAgICAgICAgICBtYXJrUGFz
dGVkTG9jYWwoYy5pZCk7CiAgICAgICAgICAgICAgICBhaGsoJ3Bhc3RlJywgU3RyaW5nKGMuaWQpKTsK
ICAgICAgICAgICAgfQogICAgICAgIH0KICAgIH07CgogICAgLy8gQUhLIEVudGVyIGhvdGtleSBsYW5k
cyBoZXJlIChXZWJWaWV3IG1heSBub3QgcmVjZWl2ZSB0aGUga2V5IHdoaWxlIHVucGlubmVkKQogICAg
d2luZG93Ll9fZWRpdFRpdGxlID0gKCkgPT4gewogICAgICAgIGxldCBjID0gbnVsbDsKICAgICAgICBp
ZiAoc2VsZWN0ZWRJZCkKICAgICAgICAgICAgYyA9IGFsbENsaXBzLmZpbmQoeCA9PiAreC5pZCA9PT0g
K3NlbGVjdGVkSWQpIHx8IG51bGw7CiAgICAgICAgaWYgKCFjICYmIGN0eENsaXApCiAgICAgICAgICAg
IGMgPSBjdHhDbGlwOwogICAgICAgIGlmICghYykgewogICAgICAgICAgICBjb25zdCB2aXMgPSB2aXNp
YmxlTGlzdCgpOwogICAgICAgICAgICBpZiAodmlzLmxlbmd0aCkgYyA9IHZpc1swXTsKICAgICAgICB9
CiAgICAgICAgaWYgKCFjKSByZXR1cm47CiAgICAgICAgb3BlblRpdGxlRGxnKGMpOwogICAgfTsKCiAg
ICB3aW5kb3cuX19vbkVudGVyID0gKCkgPT4gewogICAgICAgIGNvbnN0IHRkID0gZG9jdW1lbnQuZ2V0
RWxlbWVudEJ5SWQoJ3RpdGxlLWRsZycpOwogICAgICAgIGlmICh0ZCAmJiB0ZC5jbGFzc0xpc3QuY29u
dGFpbnMoJ29uJykpIHsKICAgICAgICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3RpdGxlLW9r
Jyk/LmNsaWNrKCk7CiAgICAgICAgICAgIHJldHVybjsKICAgICAgICB9CiAgICAgICAgaWYgKGRvY3Vt
ZW50LmFjdGl2ZUVsZW1lbnQ/LmlkID09PSAndGl0bGUtaW5wdXQnKSB7CiAgICAgICAgICAgIGRvY3Vt
ZW50LmdldEVsZW1lbnRCeUlkKCd0aXRsZS1vaycpPy5jbGljaygpOwogICAgICAgICAgICByZXR1cm47
CiAgICAgICAgfQogICAgICAgIC8vIOiHquWumuS5ieWIhumalOespu+8muacquWbuuWumuaXtiBBSEsg
5Lya5oqiIEVudGVyCiAgICAgICAgY29uc3Qgc2VwTWVudSA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlk
KCdwYXN0ZS1zZXAtbWVudScpOwogICAgICAgIGNvbnN0IHNlcElucCA9IGRvY3VtZW50LmdldEVsZW1l
bnRCeUlkKCdwYXN0ZS1zZXAtY3VzdG9tJyk7CiAgICAgICAgaWYgKHNlcE1lbnUgJiYgc2VwTWVudS5j
bGFzc0xpc3QuY29udGFpbnMoJ29uJykgJiYgc2VwSW5wKSB7CiAgICAgICAgICAgIGlmIChTdHJpbmco
c2VwSW5wLnZhbHVlIHx8ICcnKSAhPT0gJycpIGFwcGx5U2VwYXJhdG9yKHNlcElucC52YWx1ZSk7CiAg
ICAgICAgICAgIGVsc2UgY2xvc2VTZXBNZW51KCk7CiAgICAgICAgICAgIHJldHVybjsKICAgICAgICB9
CiAgICAgICAgLy8g5Zu65a6a5pe25Zue6L2m5LiN57KY6LS0CiAgICAgICAgaWYgKHBpbm5lZFVJKSBy
ZXR1cm47CiAgICAgICAgLy8gVHlwaW5nIGluIHNlYXJjaDogRW50ZXIgc2hvdWxkIHBhc3RlIHNlbGVj
dGVkIGl0ZW0KICAgICAgICBpZiAoZG9jdW1lbnQuYWN0aXZlRWxlbWVudD8uaWQgPT09ICdzZWFyY2gn
KSB7CiAgICAgICAgICAgIHdpbmRvdy5fX25hdiAmJiB3aW5kb3cuX19uYXYoJ2VudGVyJyk7CiAgICAg
ICAgICAgIHJldHVybjsKICAgICAgICB9CiAgICAgICAgd2luZG93Ll9fbmF2ICYmIHdpbmRvdy5fX25h
dignZW50ZXInKTsKICAgIH07CgogICAgd2luZG93Ll9fY3ljbGVUYWIgPSBkaXIgPT4gewogICAgICAg
IGNvbnN0IGkgPSBNYXRoLm1heCgwLCBUQUJfT1JERVIuaW5kZXhPZihjdXJUYWIpKTsKICAgICAgICBj
b25zdCBuZXh0ID0gVEFCX09SREVSWyhpICsgKGRpciB8IDApICsgVEFCX09SREVSLmxlbmd0aCAqIDEw
KSAlIFRBQl9PUkRFUi5sZW5ndGhdOwogICAgICAgIHNldFRhYihuZXh0KTsKICAgIH07CiAgICB3aW5k
b3cuX19vblBhbmVsU2hvdyA9IChrZWVwU2VhcmNoKSA9PiB7CiAgICAgICAgd2luZG93Ll9fcGVyZk1h
cmsgJiYgd2luZG93Ll9fcGVyZk1hcmsoJ2pzX29uUGFuZWxTaG93IGtlZXBTZWFyY2g9JyArICghIWtl
ZXBTZWFyY2gpKTsKICAgICAgICB0cnkgeyByZXNldFBhc3RlU2VwRGVmYXVsdCgpOyB9IGNhdGNoIHt9
CiAgICAgICAgLy8gRG8gTk9UIGZvY3VzIFdlYlZpZXcg4oCUIGtlZXAgZWRpdG9yIGNhcmV0L2ZvY3Vz
IChBSEsgaGFuZGxlcyBrZXlzIHZpYSAjSG90SWYpCiAgICAgICAgLy8gV2luK1Y6IGNvbGxhcHNlIHNl
YXJjaC4gPz8gc2VhcmNoOiBrZWVwL29wZW4gc2VhcmNoIGJveC4KICAgICAgICBrZWVwU2VhcmNoID0g
ISFrZWVwU2VhcmNoOwogICAgICAgIHRyeSB7IGhpZGVDdHgoKTsgfSBjYXRjaCB7fQogICAgICAgIHRy
eSB7IGNsb3NlVGl0bGVEbGcoKTsgfSBjYXRjaCB7fQogICAgICAgIHRyeSB7CiAgICAgICAgICAgIGNv
bnN0IHdyYXAgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc2VhcmNoLXdyYXAnKTsKICAgICAgICAg
ICAgY29uc3Qgc3JjaCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzZWFyY2gnKTsKICAgICAgICAg
ICAgY29uc3Qgc2NsciA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzZWFyY2gtY2xyJyk7CiAgICAg
ICAgICAgIGlmICgha2VlcFNlYXJjaCkgewogICAgICAgICAgICAgICAgaWYgKHdyYXApIHdyYXAuY2xh
c3NMaXN0LnJlbW92ZSgnb3BlbicpOwogICAgICAgICAgICAgICAgaWYgKHNyY2gpIHsKICAgICAgICAg
ICAgICAgICAgICBzcmNoLnZhbHVlID0gJyc7CiAgICAgICAgICAgICAgICAgICAgc3JjaC5jbGFzc0xp
c3QucmVtb3ZlKCdoYXMtdmFsJyk7CiAgICAgICAgICAgICAgICAgICAgdHJ5IHsgc3JjaC5ibHVyKCk7
IH0gY2F0Y2gge30KICAgICAgICAgICAgICAgIH0KICAgICAgICAgICAgICAgIGlmIChzY2xyKSBzY2xy
LnN0eWxlLmRpc3BsYXkgPSAnbm9uZSc7CiAgICAgICAgICAgICAgICBxdWVyeSA9ICcnOwogICAgICAg
ICAgICAgICAgd2luZG93Ll9faG9zdEZpbHRlcmVkID0gZmFsc2U7CiAgICAgICAgICAgICAgICB3aW5k
b3cuX19ob3N0RmlsdGVyUSA9ICcnOwogICAgICAgICAgICAgICAgLy8gV2luK1bvvJrnq4vliLvnlKjm
nKrov4fmu6TnvJPlrZjpk7rliJfooajvvIzpgb/lhY3lhYjpl6rov4fmu6Tnu5Pmnpwv56m65aOz5YaN
562JIFNldFZpZXcKICAgICAgICAgICAgICAgIHRyeSB7CiAgICAgICAgICAgICAgICAgICAgY29uc3Qg
aGl0ID0gdmlld01lbS5nZXQodmlld01lbUtleSgnYWxsJywgJycsIGZhbHNlKSk7CiAgICAgICAgICAg
ICAgICAgICAgaWYgKGhpdCAmJiBBcnJheS5pc0FycmF5KGhpdC5pdGVtcykgJiYgaGl0Lml0ZW1zLmxl
bmd0aCkgewogICAgICAgICAgICAgICAgICAgICAgICBhbGxDbGlwcyA9IGhpdC5pdGVtcy5zbGljZSgp
OwogICAgICAgICAgICAgICAgICAgICAgICBkaXNrVG90YWwgPSBOdW1iZXIoaGl0LnRvdGFsKSB8fCBo
aXQuaXRlbXMubGVuZ3RoOwogICAgICAgICAgICAgICAgICAgICAgICB3aW5kb3cuX19kYXRhUmVhZHkg
PSB0cnVlOwogICAgICAgICAgICAgICAgICAgICAgICBob3N0UHVzaGVkT25jZSA9IHRydWU7CiAgICAg
ICAgICAgICAgICAgICAgICAgIHNhd05vbkVtcHR5ID0gdHJ1ZTsKICAgICAgICAgICAgICAgICAgICAg
ICAgY2xlYXJXYWl0aW5nRGF0YSgpOwogICAgICAgICAgICAgICAgICAgIH0gZWxzZSB7CiAgICAgICAg
ICAgICAgICAgICAgICAgIHNjaGVkdWxlRGVsYXllZFNrZWwoKTsKICAgICAgICAgICAgICAgICAgICB9
CiAgICAgICAgICAgICAgICB9IGNhdGNoIHsKICAgICAgICAgICAgICAgICAgICBzY2hlZHVsZURlbGF5
ZWRTa2VsKCk7CiAgICAgICAgICAgICAgICB9CiAgICAgICAgICAgIH0gZWxzZSBpZiAod3JhcCkgewog
ICAgICAgICAgICAgICAgd3JhcC5jbGFzc0xpc3QuYWRkKCdvcGVuJyk7CiAgICAgICAgICAgICAgICBp
ZiAoc3JjaCAmJiBzcmNoLnZhbHVlKQogICAgICAgICAgICAgICAgICAgIHF1ZXJ5ID0gc3JjaC52YWx1
ZTsKICAgICAgICAgICAgICAgIC8vID8/IOaQnOe0ou+8muWcqOS4u+acuui/h+a7pOe7k+aenOWIsOi+
vuWJje+8jOWFiOaMieWFs+mUruWtl+acrOWcsOa7pO+8jOemgeatoumXquWHuuOAjOWFqOmDqOOAjQog
ICAgICAgICAgICAgICAgaWYgKFN0cmluZyhxdWVyeSB8fCAnJykudHJpbSgpKSB7CiAgICAgICAgICAg
ICAgICAgICAgd2luZG93Ll9faG9zdEZpbHRlcmVkID0gZmFsc2U7CiAgICAgICAgICAgICAgICAgICAg
d2luZG93Ll9faG9zdEZpbHRlclEgPSAnJzsKICAgICAgICAgICAgICAgIH0KICAgICAgICAgICAgfQog
ICAgICAgICAgICB0b2RheU9ubHkgPSBmYWxzZTsKICAgICAgICAgICAgdHJ5IHsKICAgICAgICAgICAg
ICAgIGNvbnN0IGJ0blRvZGF5ID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2J0bi10b2RheScpOwog
ICAgICAgICAgICAgICAgaWYgKGJ0blRvZGF5KSBidG5Ub2RheS5jbGFzc0xpc3QucmVtb3ZlKCdvbicp
OwogICAgICAgICAgICB9IGNhdGNoIHt9CiAgICAgICAgICAgIGN1clRhYiA9ICdhbGwnOwogICAgICAg
ICAgICBsb2FkaW5nTW9yZSA9IGZhbHNlOwogICAgICAgICAgICBtYXJrVGFiKCdhbGwnKTsKICAgICAg
ICAgICAgLy8g5LiN6KaBIGFoaygnYmx1clBhbmVsJynvvJrkvJrot58gU2hvd1BhbmVsIOaKoueEpueC
ue+8jFdpbitWLz8/IOmDveWuueaYk+mXquOAgeS5sei3swogICAgICAgICAgICByZW5kZXIoKTsKICAg
ICAgICAgICAgLy8g5ZCM5q2l5b2T5YmNIHRhYi9xdWVyeSDliLAgQUhL77yIPz8g5pu+5Y+q55SoIHZp
ZXdUYWIg5pCc6ZSZ6aG177yJCiAgICAgICAgICAgIHJlcXVlc3RWaWV3KCk7CiAgICAgICAgfSBjYXRj
aCB7fQogICAgICAgIHNlbGVjdEZpcnN0T25TaG93ID0gdHJ1ZTsKICAgICAgICBsb2NhdGVBY3RpdmUg
PSBmYWxzZTsKICAgICAgICB1cGRhdGVMb2NhdGVCdG4oKTsKICAgICAgICBjbGVhck11bHRpKCk7CiAg
ICAgICAgY29uc3QgdmlzID0gdmlzaWJsZUxpc3QoKTsKICAgICAgICBpZiAodmlzLmxlbmd0aCkgewog
ICAgICAgICAgICBzZWxlY3RlZElkID0gdmlzWzBdLmlkOwogICAgICAgICAgICByYW5nZUFuY2hvcklk
ID0gc2VsZWN0ZWRJZDsKICAgICAgICAgICAgcmFuZ2VBbmNob3JDbGlja2VkID0gZmFsc2U7CiAgICAg
ICAgICAgIGxpc3RFbC5zY3JvbGxUb3AgPSAwOwogICAgICAgIH0KICAgICAgICBzeW5jSXRlbUhpZ2hs
aWdodCgpOwogICAgfTsKCiAgICBmdW5jdGlvbiBjdHhCaW5kKGlkLCBmbikgewogICAgICAgIGRvY3Vt
ZW50LmdldEVsZW1lbnRCeUlkKGlkKS5hZGRFdmVudExpc3RlbmVyKCdjbGljaycsIGUgPT4gewogICAg
ICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgICAgICAgICBpZiAoY3R4Q2xpcCkgZm4oY3R4
Q2xpcCk7CiAgICAgICAgICAgIGhpZGVDdHgoKTsKICAgICAgICB9KTsKICAgIH0KICAgIGZ1bmN0aW9u
IHNxbFF1b3RlKHYpIHsKICAgICAgICByZXR1cm4gIiciICsgU3RyaW5nKHYgPz8gJycpLnJlcGxhY2Uo
LycvZywgIicnIikgKyAiJyI7CiAgICB9CiAgICBmdW5jdGlvbiBzdHJpcE91dGVyUXVvdGVzKHYpIHsK
ICAgICAgICBjb25zdCBzID0gU3RyaW5nKHYgPz8gJycpLnRyaW0oKTsKICAgICAgICBpZiAoKHMuc3Rh
cnRzV2l0aCgnIicpICYmIHMuZW5kc1dpdGgoJyInKSkgfHwgKHMuc3RhcnRzV2l0aCgiJyIpICYmIHMu
ZW5kc1dpdGgoIiciKSkpCiAgICAgICAgICAgIHJldHVybiBzLnNsaWNlKDEsIC0xKTsKICAgICAgICBy
ZXR1cm4gczsKICAgIH0KICAgIGZ1bmN0aW9uIHNwbGl0Q3N2UGFydHMocmF3KSB7CiAgICAgICAgY29u
c3QgcyA9IFN0cmluZyhyYXcgPz8gJycpOwogICAgICAgIGNvbnN0IHBhcnRzID0gW107CiAgICAgICAg
bGV0IGN1ciA9ICcnOwogICAgICAgIGxldCBxID0gJyc7CiAgICAgICAgZm9yIChsZXQgaSA9IDA7IGkg
PCBzLmxlbmd0aDsgaSsrKSB7CiAgICAgICAgICAgIGNvbnN0IGNoID0gc1tpXTsKICAgICAgICAgICAg
aWYgKHEpIHsKICAgICAgICAgICAgICAgIGlmIChjaCA9PT0gcSkgewogICAgICAgICAgICAgICAgICAg
IC8vIGRvdWJsZWQgcXVvdGUgZXNjYXBlCiAgICAgICAgICAgICAgICAgICAgaWYgKHNbaSArIDFdID09
PSBxKSB7IGN1ciArPSBxOyBpKys7IH0KICAgICAgICAgICAgICAgICAgICBlbHNlIHEgPSAnJzsKICAg
ICAgICAgICAgICAgIH0gZWxzZSBjdXIgKz0gY2g7CiAgICAgICAgICAgICAgICBjb250aW51ZTsKICAg
ICAgICAgICAgfQogICAgICAgICAgICBpZiAoY2ggPT09ICciJyB8fCBjaCA9PT0gIiciKSB7IHEgPSBj
aDsgY29udGludWU7IH0KICAgICAgICAgICAgaWYgKGNoID09PSAnLCcpIHsgcGFydHMucHVzaChjdXIu
dHJpbSgpKTsgY3VyID0gJyc7IGNvbnRpbnVlOyB9CiAgICAgICAgICAgIGN1ciArPSBjaDsKICAgICAg
ICB9CiAgICAgICAgcGFydHMucHVzaChjdXIudHJpbSgpKTsKICAgICAgICByZXR1cm4gcGFydHMuZmls
dGVyKHAgPT4gcCAhPT0gJycpOwogICAgfQogICAgZnVuY3Rpb24gdHJhbnNmb3JtVGV4dFRvU3FsVHVw
bGUocmF3LCBtb2RlKSB7CiAgICAgICAgbGV0IHNyYyA9IFN0cmluZyhyYXcgPz8gJycpLnRyaW0oKTsK
ICAgICAgICBpZiAoIXNyYykgcmV0dXJuICcnOwogICAgICAgIGxldCBwYXJ0cyA9IFtdOwogICAgICAg
IGlmIChtb2RlID09PSAnbGluZXMnKSB7CiAgICAgICAgICAgIHBhcnRzID0gc3JjLnNwbGl0KC9ccj9c
bi8pLm1hcChsID0+IHN0cmlwT3V0ZXJRdW90ZXMobC50cmltKCkpKS5maWx0ZXIoQm9vbGVhbik7CiAg
ICAgICAgfSBlbHNlIHsKICAgICAgICAgICAgLy8ge2EsYn0gLyBhLGIgLyB7ImEiLCJiIn0KICAgICAg
ICAgICAgY29uc3QgbSA9IHNyYy5tYXRjaCgvXlxzKlx7KFtcc1xTXSopXH1ccyokLyk7CiAgICAgICAg
ICAgIGlmIChtKSBzcmMgPSBtWzFdLnRyaW0oKTsKICAgICAgICAgICAgcGFydHMgPSBzcGxpdENzdlBh
cnRzKHNyYykubWFwKHN0cmlwT3V0ZXJRdW90ZXMpLmZpbHRlcihCb29sZWFuKTsKICAgICAgICB9CiAg
ICAgICAgaWYgKCFwYXJ0cy5sZW5ndGgpIHJldHVybiAnJzsKICAgICAgICByZXR1cm4gJygnICsgcGFy
dHMubWFwKHNxbFF1b3RlKS5qb2luKCcsJykgKyAnKSc7CiAgICB9CiAgICBmdW5jdGlvbiBhcHBseURh
dGFUcmFuc2Zvcm0oYywgbW9kZSkgewogICAgICAgIGlmICghYykgcmV0dXJuOwogICAgICAgIC8vIERv
IG5vdCBtdXRhdGUgY2xpcCBoaXN0b3J5IOKAlCBBSEsgdHJhbnNmb3JtcyBhIGNvcHkgYW5kIHBhc3Rl
cyBpdAogICAgICAgIHRyeSB7IG1hcmtQYXN0ZWRMb2NhbChjLmlkKTsgfSBjYXRjaCB7fQogICAgICAg
IGFoaygndGV4dFRyYW5zZm9ybScsIFN0cmluZyhjLmlkKSwgU3RyaW5nKG1vZGUgfHwgJ2F1dG8nKSk7
CiAgICB9CiAgICBmdW5jdGlvbiBkZXRlY3REYXRhVHJhbnNmb3JtTW9kZShyYXcpIHsKICAgICAgICAv
LyBVSSBsaXN0IG9ubHkgaGFzIHRydW5jYXRlZCBwcmV2aWV3IChkYXRhPSIiKS4KICAgICAgICAvLyBD
aGVjayBcIiBmaXJzdDogZXNjYXBlZCBKU09OIG9mdGVuIGFsc28gc3RhcnRzIHdpdGggJ3snLgogICAg
ICAgIGNvbnN0IHMgPSBTdHJpbmcocmF3ID8/ICcnKS50cmltKCk7CiAgICAgICAgaWYgKCFzKSByZXR1
cm4gJyc7CiAgICAgICAgaWYgKHMuaW5jbHVkZXMoJ1xcIicpKSByZXR1cm4gJ2pzb24nOwogICAgICAg
IGlmIChzLnN0YXJ0c1dpdGgoJ3snKSkgcmV0dXJuICdicmFjZSc7CiAgICAgICAgaWYgKHMuaW5jbHVk
ZXMoJ1xuJykgfHwgcy5pbmNsdWRlcygnXHInKSkgcmV0dXJuICdsaW5lcyc7CiAgICAgICAgcmV0dXJu
ICcnOwogICAgfQogICAgZnVuY3Rpb24gY2xlYXJEYXRhU3VibWVudVBpY2soKSB7CiAgICAgICAgdHJ5
IHsKICAgICAgICAgICAgZG9jdW1lbnQucXVlcnlTZWxlY3RvckFsbCgnI2MtZGF0YS1zdWIgLmMtaXRl
bS5waWNrJykuZm9yRWFjaChlbCA9PiBlbC5jbGFzc0xpc3QucmVtb3ZlKCdwaWNrJykpOwogICAgICAg
IH0gY2F0Y2gge30KICAgIH0KICAgIGZ1bmN0aW9uIGhpZ2hsaWdodERhdGFTdWJtZW51TW9kZShtb2Rl
KSB7CiAgICAgICAgY2xlYXJEYXRhU3VibWVudVBpY2soKTsKICAgICAgICBjb25zdCBpZE1hcCA9IHsg
YnJhY2U6ICdjLWRhdGEtYnJhY2UnLCBsaW5lczogJ2MtZGF0YS1saW5lcycsIGpzb246ICdjLWRhdGEt
anNvbicgfTsKICAgICAgICBjb25zdCBpZCA9IGlkTWFwW21vZGVdOwogICAgICAgIGlmICghaWQpIHJl
dHVybjsKICAgICAgICBjb25zdCBlbCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKGlkKTsKICAgICAg
ICBpZiAoZWwpIGVsLmNsYXNzTGlzdC5hZGQoJ3BpY2snKTsKICAgIH0KICAgIGZ1bmN0aW9uIHByZXZp
ZXdEYXRhVHJhbnNmb3JtTW9kZUFzeW5jKCkgewogICAgICAgIGNvbnN0IHRva2VuID0gKytwcmV2aWV3
RGF0YVRyYW5zZm9ybVNlcTsKICAgICAgICBjb25zdCBjbGlwID0gY3R4Q2xpcDsKICAgICAgICBzZXRU
aW1lb3V0KCgpID0+IHsKICAgICAgICAgICAgaWYgKHRva2VuICE9PSBwcmV2aWV3RGF0YVRyYW5zZm9y
bVNlcSkgcmV0dXJuOwogICAgICAgICAgICBpZiAoIWNsaXAgfHwgY3R4Q2xpcCAhPT0gY2xpcCkgcmV0
dXJuOwogICAgICAgICAgICBjb25zdCByYXcgPSBTdHJpbmcoY2xpcC5kYXRhIHx8IGNsaXAucHJldmll
dyB8fCAnJyk7CiAgICAgICAgICAgIGNvbnN0IG1vZGUgPSBkZXRlY3REYXRhVHJhbnNmb3JtTW9kZShy
YXcpOwogICAgICAgICAgICBpZiAodG9rZW4gIT09IHByZXZpZXdEYXRhVHJhbnNmb3JtU2VxKSByZXR1
cm47CiAgICAgICAgICAgIGhpZ2hsaWdodERhdGFTdWJtZW51TW9kZShtb2RlKTsKICAgICAgICB9LCAw
KTsKICAgIH0KICAgIGxldCBwcmV2aWV3RGF0YVRyYW5zZm9ybVNlcSA9IDA7CiAgICBjb25zdCBkYXRh
UGFyZW50ID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2MtZGF0YScpOwogICAgY29uc3QgZGF0YVdy
YXBFbCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjLWRhdGEtd3JhcCcpOwogICAgaWYgKGRhdGFQ
YXJlbnQpIHsKICAgICAgICBkYXRhUGFyZW50LmFkZEV2ZW50TGlzdGVuZXIoJ2NsaWNrJywgZSA9PiB7
CiAgICAgICAgICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAgICAgICAgIC8vIFByaW1hcnkgY2xp
Y2sgPSBhdXRvIGRldGVjdCArIHRyYW5zZm9ybSArIHBhc3RlCiAgICAgICAgICAgIGlmIChjdHhDbGlw
KSB7CiAgICAgICAgICAgICAgICBhcHBseURhdGFUcmFuc2Zvcm0oY3R4Q2xpcCwgJ2F1dG8nKTsKICAg
ICAgICAgICAgICAgIGhpZGVDdHgoKTsKICAgICAgICAgICAgICAgIHJldHVybjsKICAgICAgICAgICAg
fQogICAgICAgICAgICBjb25zdCB3cmFwID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2MtZGF0YS13
cmFwJyk7CiAgICAgICAgICAgIGlmICh3cmFwKSB7CiAgICAgICAgICAgICAgICB3cmFwLmNsYXNzTGlz
dC50b2dnbGUoJ29wZW4nKTsKICAgICAgICAgICAgICAgIHBsYWNlRGF0YVN1Ym1lbnUoKTsKICAgICAg
ICAgICAgICAgIHByZXZpZXdEYXRhVHJhbnNmb3JtTW9kZUFzeW5jKCk7CiAgICAgICAgICAgIH0KICAg
ICAgICB9KTsKICAgIH0KICAgIGlmIChkYXRhV3JhcEVsKSB7CiAgICAgICAgZGF0YVdyYXBFbC5hZGRF
dmVudExpc3RlbmVyKCdtb3VzZWVudGVyJywgKCkgPT4gewogICAgICAgICAgICBwbGFjZURhdGFTdWJt
ZW51KCk7CiAgICAgICAgICAgIHByZXZpZXdEYXRhVHJhbnNmb3JtTW9kZUFzeW5jKCk7CiAgICAgICAg
fSk7CiAgICAgICAgZGF0YVdyYXBFbC5hZGRFdmVudExpc3RlbmVyKCdtb3VzZWxlYXZlJywgKCkgPT4g
Y2xlYXJEYXRhU3VibWVudVBpY2soKSk7CiAgICB9CiAgICBjdHhCaW5kKCdjLWRhdGEtYnJhY2UnLCBj
ID0+IGFwcGx5RGF0YVRyYW5zZm9ybShjLCAnYnJhY2UnKSk7CiAgICBjdHhCaW5kKCdjLWRhdGEtbGlu
ZXMnLCBjID0+IGFwcGx5RGF0YVRyYW5zZm9ybShjLCAnbGluZXMnKSk7CiAgICBjdHhCaW5kKCdjLWRh
dGEtanNvbicsIGMgPT4gYXBwbHlEYXRhVHJhbnNmb3JtKGMsICdqc29uJykpOwogICAgY3R4QmluZCgn
Yy1jb3B5JywgIGMgPT4gewogICAgICAgIGlmIChub3JtVHlwZShjLnR5cGUpID09PSAncmVjZW50JykK
ICAgICAgICAgICAgYWhrKCdjb3B5UGF0aCcsIFN0cmluZyhjLmRhdGEgfHwgYy5wcmV2aWV3IHx8ICcn
KSk7CiAgICAgICAgZWxzZQogICAgICAgICAgICBhaGsoJ2NvcHlCeUlkJywgU3RyaW5nKGMuaWQpKTsK
ICAgIH0pOwogICAgY3R4QmluZCgnYy1wYXN0ZScsIGMgPT4gewogICAgICAgIGFjdGl2YXRlQ2xpcEl0
ZW0oYyk7CiAgICB9KTsKICAgIGN0eEJpbmQoJ2MtcGluJywgICBjID0+IHsKICAgICAgICBjb25zdCBp
c1JlY2VudCA9IG5vcm1UeXBlKGMudHlwZSkgPT09ICdyZWNlbnQnIHx8IGN1clRhYiA9PT0gJ3JlY2Vu
dCc7CiAgICAgICAgLy8gTXVsdGktc2VsZWN0OiBwaW4vdW5waW4gYWxsIHNlbGVjdGVkIHdoZW4gcmln
aHQtY2xpY2sgaXMgb24gYSBzZWxlY3RlZCBpdGVtCiAgICAgICAgbGV0IGlkcyA9IFtdOwogICAgICAg
IGlmICghaXNSZWNlbnQgJiYgbXVsdGlJZHMubGVuZ3RoID4gMSAmJiBtdWx0aUlkcy5pbmNsdWRlcygr
Yy5pZCkpCiAgICAgICAgICAgIGlkcyA9IG11bHRpSWRzLnNsaWNlKCk7CiAgICAgICAgZWxzZQogICAg
ICAgICAgICBpZHMgPSBbK2MuaWRdOwogICAgICAgIGlkcyA9IGlkcy5tYXAoeCA9PiAreCkuZmlsdGVy
KHggPT4geCA+IDApOwogICAgICAgIGlmICghaWRzLmxlbmd0aCkgcmV0dXJuOwoKICAgICAgICBsZXQg
YW55T2ZmID0gZmFsc2U7CiAgICAgICAgZm9yIChjb25zdCBwaWQgb2YgaWRzKSB7CiAgICAgICAgICAg
IGNvbnN0IHggPSAoK3BpZCA9PT0gK2MuaWQpID8gYyA6IGFsbENsaXBzLmZpbmQodCA9PiArdC5pZCA9
PT0gK3BpZCk7CiAgICAgICAgICAgIGlmICh4ICYmICFpc1Bpbm5lZCh4KSkgeyBhbnlPZmYgPSB0cnVl
OyBicmVhazsgfQogICAgICAgIH0KICAgICAgICAvLyBJZiBhbnkgc2VsZWN0ZWQgaXMgbm90IGZhdm9y
aXRlZCDihpIgZmF2b3JpdGUgYWxsOyBlbHNlIHVuZmF2b3JpdGUgYWxsCiAgICAgICAgY29uc3QgbmV4
dCA9IGFueU9mZjsKCiAgICAgICAgZm9yIChjb25zdCBpZCBvZiBpZHMpIHsKICAgICAgICAgICAgcGF0
Y2hQaW5uZWRJbkNhY2hlcyhpZCwgbmV4dCk7CiAgICAgICAgICAgIGNvbnN0IHggPSBhbGxDbGlwcy5m
aW5kKHQgPT4gK3QuaWQgPT09ICtpZCk7CiAgICAgICAgICAgIGlmICh4KSB4LnBpbm5lZCA9IG5leHQ7
CiAgICAgICAgICAgIGlmICgraWQgPT09ICtjLmlkKSBjLnBpbm5lZCA9IG5leHQ7CiAgICAgICAgICAg
IGlmIChuZXh0KSBtYXJrRmF2VW5zZWVuKGlkKTsKICAgICAgICAgICAgZWxzZSB7CiAgICAgICAgICAg
ICAgICB1bnNlZW5GYXZJZHMuZGVsZXRlKGlkKTsKICAgICAgICAgICAgfQogICAgICAgIH0KICAgICAg
ICBpZiAoIW5leHQpIHsKICAgICAgICAgICAgc2F2ZVVuc2VlbkZhdigpOwogICAgICAgICAgICB1cGRh
dGVQaW5Eb3QoKTsKICAgICAgICB9CiAgICAgICAgLy8g5pS26JeP6aG15Y+W5raI77ya56uL5Yi75LuO
5YiX6KGo5pGY5o6JCiAgICAgICAgaWYgKCFuZXh0ICYmIGN1clRhYiA9PT0gJ3Bpbm5lZCcpIHsKICAg
ICAgICAgICAgY29uc3QgaWRTZXQgPSBuZXcgU2V0KGlkcyk7CiAgICAgICAgICAgIGNvbnN0IGJlZm9y
ZSA9IGFsbENsaXBzLmxlbmd0aDsKICAgICAgICAgICAgYWxsQ2xpcHMgPSBhbGxDbGlwcy5maWx0ZXIo
eCA9PiAhaWRTZXQuaGFzKCt4LmlkKSk7CiAgICAgICAgICAgIGNvbnN0IHJlbW92ZWQgPSBiZWZvcmUg
LSBhbGxDbGlwcy5sZW5ndGg7CiAgICAgICAgICAgIGRpc2tUb3RhbCA9IE1hdGgubWF4KDAsIChOdW1i
ZXIoZGlza1RvdGFsKSB8fCAwKSAtIHJlbW92ZWQpOwogICAgICAgICAgICBwaW5uZWRUb3RhbCA9IE1h
dGgubWF4KDAsIChOdW1iZXIocGlubmVkVG90YWwpIHx8IDApIC0gcmVtb3ZlZCk7CiAgICAgICAgICAg
IGlmIChpZFNldC5oYXMoK3NlbGVjdGVkSWQpKQogICAgICAgICAgICAgICAgc2VsZWN0ZWRJZCA9IGFs
bENsaXBzLmxlbmd0aCA/IGFsbENsaXBzWzBdLmlkIDogMDsKICAgICAgICAgICAgdHJ5IHsKICAgICAg
ICAgICAgICAgIHZpZXdNZW0uc2V0KHZpZXdNZW1LZXkoY3VyVGFiLCBxdWVyeSwgdG9kYXlPbmx5KSwg
ewogICAgICAgICAgICAgICAgICAgIGl0ZW1zOiBhbGxDbGlwcy5zbGljZSgpLAogICAgICAgICAgICAg
ICAgICAgIHRvdGFsOiBkaXNrVG90YWwKICAgICAgICAgICAgICAgIH0pOwogICAgICAgICAgICB9IGNh
dGNoIHt9CiAgICAgICAgICAgIGNsZWFyRmF2VW5zZWVuKCk7CiAgICAgICAgfSBlbHNlIGlmIChjdXJU
YWIgPT09ICdwaW5uZWQnKSB7CiAgICAgICAgICAgIGNsZWFyRmF2VW5zZWVuKCk7CiAgICAgICAgfQog
ICAgICAgIGlmIChpZHMubGVuZ3RoID4gMSkKICAgICAgICAgICAgY2xlYXJNdWx0aSgpOwogICAgICAg
IHJlbmRlcigpOwogICAgICAgIGlmIChpZHMubGVuZ3RoID09PSAxKQogICAgICAgICAgICBhaGsoJ3Bp
bk1hbnknLCBTdHJpbmcoaWRzWzBdKSwgbmV4dCA/ICcxJyA6ICcwJyk7CiAgICAgICAgZWxzZQogICAg
ICAgICAgICBhaGsoJ3Bpbk1hbnknLCBpZHMuam9pbignLCcpLCBuZXh0ID8gJzEnIDogJzAnKTsKICAg
IH0pOwogICAgY3R4QmluZCgnYy10b3AnLCAgIGMgPT4gYWhrKCdtb3ZlVG9Ub3AnLCAgICAgU3RyaW5n
KGMuaWQpKSk7CiAgICBjdHhCaW5kKCdjLWNsZWFyLXBhc3RlZCcsIGMgPT4gYWhrKCdjbGVhclBhc3Rl
ZCcsIFN0cmluZyhjLmlkKSkpOwogICAgY3R4QmluZCgnYy1xdWV1ZS1mcm9tJywgYyA9PiB7CiAgICAg
ICAgYWhrKCdyZXNldFF1ZXVlRnJvbScsIFN0cmluZyhjLmlkKSk7CiAgICAgICAgaWYgKCFwaW5uZWRV
SSkgYWhrKCdoaWRlJyk7CiAgICB9KTsKICAgIGN0eEJpbmQoJ2MtZGVsJywgICBjID0+IHsKICAgICAg
ICAvLyDlpJrpgInkuJTlj7PplK7ngrnlnKjpgInkuK3pobnkuIog4oaSIOaJuemHj+WIoOmZpO+8m+WQ
puWImeWPquWIoOW9k+WJjQogICAgICAgIGxldCBpZHMgPSBbXTsKICAgICAgICBpZiAobXVsdGlJZHMu
bGVuZ3RoID4gMSAmJiBtdWx0aUlkcy5pbmNsdWRlcygrYy5pZCkpCiAgICAgICAgICAgIGlkcyA9IG11
bHRpSWRzLnNsaWNlKCk7CiAgICAgICAgZWxzZQogICAgICAgICAgICBpZHMgPSBbK2MuaWRdOwogICAg
ICAgIGlkcyA9IGlkcy5tYXAoeCA9PiAreCkuZmlsdGVyKHggPT4geCA+IDApOwogICAgICAgIGlmICgh
aWRzLmxlbmd0aCkgcmV0dXJuOwogICAgICAgIHRyeSB7CiAgICAgICAgICAgIGNvbnN0IGlkU2V0ID0g
bmV3IFNldChpZHMpOwogICAgICAgICAgICBhbGxDbGlwcyA9IGFsbENsaXBzLmZpbHRlcih4ID0+ICFp
ZFNldC5oYXMoK3guaWQpKTsKICAgICAgICAgICAgZGlza1RvdGFsID0gTWF0aC5tYXgoMCwgKE51bWJl
cihkaXNrVG90YWwpIHx8IDApIC0gaWRzLmxlbmd0aCk7CiAgICAgICAgICAgIGlmIChpZFNldC5oYXMo
K3NlbGVjdGVkSWQpKQogICAgICAgICAgICAgICAgc2VsZWN0ZWRJZCA9IGFsbENsaXBzLmxlbmd0aCA/
IGFsbENsaXBzWzBdLmlkIDogMDsKICAgICAgICAgICAgY2xlYXJNdWx0aSgpOwogICAgICAgICAgICBy
ZW5kZXIoKTsKICAgICAgICB9IGNhdGNoIHt9CiAgICAgICAgaWYgKGlkcy5sZW5ndGggPT09IDEpCiAg
ICAgICAgICAgIGFoaygnZGVsZXRlJywgU3RyaW5nKGlkc1swXSkpOwogICAgICAgIGVsc2UKICAgICAg
ICAgICAgYWhrKCdkZWxldGVNYW55JywgaWRzLmpvaW4oJywnKSk7CiAgICB9KTsKICAgIGN0eEJpbmQo
J2MtdGl0bGUnLCBjID0+IG9wZW5UaXRsZURsZyhjKSk7CiAgICBjdHhCaW5kKCdjLW1lcmdlJywgYyA9
PiB7CiAgICAgICAgY29uc3QgaWRzID0gKG11bHRpSWRzLmxlbmd0aCA+PSAyKSA/IG11bHRpSWRzLnNs
aWNlKCkgOiBbXTsKICAgICAgICBpZiAoaWRzLmxlbmd0aCA8IDIpIHJldHVybjsKICAgICAgICBpZiAo
IWlkcy5pbmNsdWRlcygrYy5pZCkpIGlkcy5wdXNoKCtjLmlkKTsKICAgICAgICBhaGsoJ21lcmdlRmF2
JywgaWRzLmpvaW4oJywnKSk7CiAgICAgICAgY2xlYXJNdWx0aSgpOwogICAgfSk7CiAgICBjdHhCaW5k
KCdjLXVubWVyZ2UnLCBjID0+IHsKICAgICAgICBhaGsoJ3VubWVyZ2VGYXYnLCBTdHJpbmcoYy5pZCkp
OwogICAgICAgIGNsZWFyTXVsdGkoKTsKICAgIH0pOwoKICAgIGNvbnN0IHRpdGxlRGxnID0gZG9jdW1l
bnQuZ2V0RWxlbWVudEJ5SWQoJ3RpdGxlLWRsZycpOwogICAgY29uc3QgdGl0bGVJbnB1dCA9IGRvY3Vt
ZW50LmdldEVsZW1lbnRCeUlkKCd0aXRsZS1pbnB1dCcpOwogICAgbGV0IHRpdGxlRGxnQ2xpcCA9IG51
bGw7CiAgICBmdW5jdGlvbiBjbG9zZVRpdGxlRGxnKCkgewogICAgICAgIGlmICh0aXRsZURsZykgdGl0
bGVEbGcuY2xhc3NMaXN0LnJlbW92ZSgnb24nKTsKICAgICAgICB0aXRsZURsZ0NsaXAgPSBudWxsOwog
ICAgfQogICAgZnVuY3Rpb24gb3BlblRpdGxlRGxnKGMpIHsKICAgICAgICBoaWRlQ3R4KCk7CiAgICAg
ICAgdGl0bGVEbGdDbGlwID0gYzsKICAgICAgICBpZiAodGl0bGVJbnB1dCkgdGl0bGVJbnB1dC52YWx1
ZSA9IFN0cmluZyhjLmZhdlRpdGxlIHx8ICcnKS50cmltKCk7CiAgICAgICAgaWYgKHRpdGxlRGxnKSB0
aXRsZURsZy5jbGFzc0xpc3QuYWRkKCdvbicpOwogICAgICAgIGFoaygnZm9jdXNQYW5lbCcpOwogICAg
ICAgIHJlcXVlc3RBbmltYXRpb25GcmFtZSgoKSA9PiB7CiAgICAgICAgICAgIHRyeSB7IHRpdGxlSW5w
dXQuZm9jdXMoKTsgdGl0bGVJbnB1dC5zZWxlY3QoKTsgfSBjYXRjaCB7fQogICAgICAgIH0pOwogICAg
fQogICAgaWYgKHRpdGxlRGxnKSB7CiAgICAgICAgdGl0bGVEbGcuYWRkRXZlbnRMaXN0ZW5lcignY2xp
Y2snLCBlID0+IHsKICAgICAgICAgICAgaWYgKGUudGFyZ2V0ID09PSB0aXRsZURsZykgY2xvc2VUaXRs
ZURsZygpOwogICAgICAgIH0pOwogICAgfQogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3RpdGxl
LWNhbmNlbCcpPy5hZGRFdmVudExpc3RlbmVyKCdjbGljaycsIGUgPT4gewogICAgICAgIGUuc3RvcFBy
b3BhZ2F0aW9uKCk7CiAgICAgICAgY2xvc2VUaXRsZURsZygpOwogICAgICAgIGFoaygnYmx1clBhbmVs
Jyk7CiAgICB9KTsKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd0aXRsZS1vaycpPy5hZGRFdmVu
dExpc3RlbmVyKCdjbGljaycsIGUgPT4gewogICAgICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAg
ICAgaWYgKCF0aXRsZURsZ0NsaXApIHJldHVybjsKICAgICAgICBjb25zdCB0ID0gU3RyaW5nKHRpdGxl
SW5wdXQ/LnZhbHVlIHx8ICcnKS50cmltKCkuc2xpY2UoMCwgODApOwogICAgICAgIGNvbnN0IGlkID0g
U3RyaW5nKHRpdGxlRGxnQ2xpcC5pZCk7CiAgICAgICAgLy8gT3B0aW1pc3RpYyBsb2NhbCB1cGRhdGUK
ICAgICAgICBjb25zdCBoaXQgPSBhbGxDbGlwcy5maW5kKHggPT4gK3guaWQgPT09ICtpZCk7CiAgICAg
ICAgaWYgKGhpdCkgaGl0LmZhdlRpdGxlID0gdDsKICAgICAgICB0aXRsZURsZ0NsaXAuZmF2VGl0bGUg
PSB0OwogICAgICAgIGNsb3NlVGl0bGVEbGcoKTsKICAgICAgICBhaGsoJ3NldEZhdlRpdGxlJywgaWQs
IHQpOwogICAgICAgIGFoaygnYmx1clBhbmVsJyk7CiAgICAgICAgcmVuZGVyKCk7CiAgICB9KTsKICAg
IHRpdGxlSW5wdXQ/LmFkZEV2ZW50TGlzdGVuZXIoJ2tleWRvd24nLCBlID0+IHsKICAgICAgICBpZiAo
ZS5rZXkgPT09ICdFbnRlcicpIHsKICAgICAgICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOwogICAgICAg
ICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgICAgICAgICBlLnN0b3BJbW1lZGlhdGVQcm9wYWdh
dGlvbigpOwogICAgICAgICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgndGl0bGUtb2snKT8uY2xp
Y2soKTsKICAgICAgICAgICAgcmV0dXJuOwogICAgICAgIH0KICAgICAgICBpZiAoZS5rZXkgPT09ICdF
c2NhcGUnKSB7CiAgICAgICAgICAgIGUucHJldmVudERlZmF1bHQoKTsKICAgICAgICAgICAgZS5zdG9w
UHJvcGFnYXRpb24oKTsKICAgICAgICAgICAgY2xvc2VUaXRsZURsZygpOwogICAgICAgICAgICBhaGso
J2JsdXJQYW5lbCcpOwogICAgICAgICAgICByZXR1cm47CiAgICAgICAgfQogICAgICAgIGUuc3RvcFBy
b3BhZ2F0aW9uKCk7CiAgICB9LCB0cnVlKTsKCiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgndGFi
cycpLmFkZEV2ZW50TGlzdGVuZXIoJ2NsaWNrJywgZSA9PiB7CiAgICAgICAgY29uc3QgdGFiID0gZS50
YXJnZXQuY2xvc2VzdCgnLnRhYicpOwogICAgICAgIGlmICghdGFiIHx8IGUudGFyZ2V0LmNsb3Nlc3Qo
JyN0YWItYWN0aW9ucycpKSByZXR1cm47CiAgICAgICAgc2V0VGFiKHRhYi5kYXRhc2V0LnRhYik7CiAg
ICB9KTsKCiAgICBjb25zdCBzcmNoV3JhcCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzZWFyY2gt
d3JhcCcpOwogICAgY29uc3QgYnRuU2VhcmNoID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2J0bi1z
ZWFyY2gnKTsKICAgIGNvbnN0IGJ0bkxvY2F0ZSA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdidG4t
bG9jYXRlJyk7CiAgICBjb25zdCBidG5Ub2RheSA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdidG4t
dG9kYXknKTsKICAgIGNvbnN0IHNyY2ggPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc2VhcmNoJyk7
CiAgICBjb25zdCBzY2xyID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NlYXJjaC1jbHInKTsKICAg
IGxldCBkZWI7CgogICAgdXBkYXRlTG9jYXRlQnRuKCk7CiAgICBpZiAoYnRuTG9jYXRlKSB7CiAgICAg
ICAgYnRuTG9jYXRlLmFkZEV2ZW50TGlzdGVuZXIoJ2NsaWNrJywgZSA9PiB7CiAgICAgICAgICAgIGUu
c3RvcFByb3BhZ2F0aW9uKCk7CiAgICAgICAgICAgIGp1bXBUb0xhc3RQYXN0ZSgpOwogICAgICAgIH0p
OwogICAgfQoKICAgIGJ0blRvZGF5LmFkZEV2ZW50TGlzdGVuZXIoJ21vdXNlZG93bicsIGUgPT4gewog
ICAgICAgIGUucHJldmVudERlZmF1bHQoKTsKICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAg
fSk7CiAgICBidG5Ub2RheS5hZGRFdmVudExpc3RlbmVyKCdjbGljaycsIGUgPT4gewogICAgICAgIGUu
c3RvcFByb3BhZ2F0aW9uKCk7CiAgICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOwogICAgICAgIHRvZGF5
T25seSA9ICF0b2RheU9ubHk7CiAgICAgICAgYnRuVG9kYXkuY2xhc3NMaXN0LnRvZ2dsZSgnb24nLCB0
b2RheU9ubHkpOwogICAgICAgIGxpc3RFbC5zY3JvbGxUb3AgPSAwOwogICAgICAgIHJlcXVlc3RWaWV3
KCk7CiAgICAgICAgdHJ5IHsgc3JjaC5mb2N1cygpOyB9IGNhdGNoIHt9CiAgICB9KTsKCiAgICBmdW5j
dGlvbiBvcGVuU2VhcmNoKCkgewogICAgICAgIGlmIChzcmNoV3JhcC5jbGFzc0xpc3QuY29udGFpbnMo
J29wZW4nKSkgewogICAgICAgICAgICBhaGsoJ2ZvY3VzUGFuZWwnKTsKICAgICAgICAgICAgdHJ5IHsg
c3JjaC5mb2N1cygpOyB9IGNhdGNoIHt9CiAgICAgICAgICAgIHJldHVybjsKICAgICAgICB9CiAgICAg
ICAgc3JjaFdyYXAuY2xhc3NMaXN0LmFkZCgnb3BlbicpOwogICAgICAgIC8vIERlZmF1bHQ6IOaJgOac
iemhteaJk+W8gOaQnOe0ouaXtum7mOiupOaQnOWFqOmDqAogICAgICAgIGNvbnN0IHdhbnRUb2RheSA9
IGZhbHNlOwogICAgICAgIGlmICh0b2RheU9ubHkgIT09IHdhbnRUb2RheSkgewogICAgICAgICAgICB0
b2RheU9ubHkgPSB3YW50VG9kYXk7CiAgICAgICAgICAgIGJ0blRvZGF5LmNsYXNzTGlzdC50b2dnbGUo
J29uJywgdG9kYXlPbmx5KTsKICAgICAgICAgICAgbGlzdEVsLnNjcm9sbFRvcCA9IDA7CiAgICAgICAg
ICAgIHJlcXVlc3RWaWV3KCk7CiAgICAgICAgfSBlbHNlIHsKICAgICAgICAgICAgYnRuVG9kYXkuY2xh
c3NMaXN0LnRvZ2dsZSgnb24nLCB0b2RheU9ubHkpOwogICAgICAgIH0KICAgICAgICBhaGsoJ2ZvY3Vz
UGFuZWwnKTsKICAgICAgICByZXF1ZXN0QW5pbWF0aW9uRnJhbWUoKCkgPT4gewogICAgICAgICAgICB0
cnkgeyBzcmNoLmZvY3VzKCk7IH0gY2F0Y2gge30KICAgICAgICB9KTsKICAgIH0KICAgIGZ1bmN0aW9u
IGNsb3NlU2VhcmNoVWkoKSB7CiAgICAgICAgc3JjaFdyYXAuY2xhc3NMaXN0LnJlbW92ZSgnb3Blbicp
OwogICAgICAgIGlmICghc3JjaC52YWx1ZSkgewogICAgICAgICAgICBzcmNoLmNsYXNzTGlzdC5yZW1v
dmUoJ2hhcy12YWwnKTsKICAgICAgICAgICAgc2Nsci5zdHlsZS5kaXNwbGF5ID0gJ25vbmUnOwogICAg
ICAgICAgICAvLyBMZWF2aW5nIHNlYXJjaCB3aXRoIGVtcHR5IHF1ZXJ5IOKGkiBkcm9wIHRvZGF5IGZp
bHRlcgogICAgICAgICAgICBpZiAodG9kYXlPbmx5KSB7CiAgICAgICAgICAgICAgICB0b2RheU9ubHkg
PSBmYWxzZTsKICAgICAgICAgICAgICAgIGJ0blRvZGF5LmNsYXNzTGlzdC5yZW1vdmUoJ29uJyk7CiAg
ICAgICAgICAgICAgICByZXF1ZXN0VmlldygpOwogICAgICAgICAgICB9CiAgICAgICAgfQogICAgfQog
ICAgd2luZG93Ll9fb3BlblNlYXJjaCA9IG9wZW5TZWFyY2g7CiAgICB3aW5kb3cuX19wcmVwVHlwZVNl
YXJjaCA9ICgpID0+IHsKICAgICAgICB0cnkgewogICAgICAgICAgICBjb25zdCB3cmFwID0gZG9jdW1l
bnQuZ2V0RWxlbWVudEJ5SWQoJ3NlYXJjaC13cmFwJyk7CiAgICAgICAgICAgIGNvbnN0IHMgPSBkb2N1
bWVudC5nZXRFbGVtZW50QnlJZCgnc2VhcmNoJyk7CiAgICAgICAgICAgIGlmICh3cmFwICYmICF3cmFw
LmNsYXNzTGlzdC5jb250YWlucygnb3BlbicpKSB7CiAgICAgICAgICAgICAgICB3cmFwLmNsYXNzTGlz
dC5hZGQoJ29wZW4nKTsKICAgICAgICAgICAgICAgIHRyeSB7CiAgICAgICAgICAgICAgICAgICAgY29u
c3Qgd2FudFRvZGF5ID0gZmFsc2U7CiAgICAgICAgICAgICAgICAgICAgaWYgKHR5cGVvZiB0b2RheU9u
bHkgIT09ICd1bmRlZmluZWQnICYmIHRvZGF5T25seSAhPT0gd2FudFRvZGF5KSB7CiAgICAgICAgICAg
ICAgICAgICAgICAgIHRvZGF5T25seSA9IHdhbnRUb2RheTsKICAgICAgICAgICAgICAgICAgICAgICAg
aWYgKHR5cGVvZiBidG5Ub2RheSAhPT0gJ3VuZGVmaW5lZCcgJiYgYnRuVG9kYXkpIGJ0blRvZGF5LmNs
YXNzTGlzdC50b2dnbGUoJ29uJywgdG9kYXlPbmx5KTsKICAgICAgICAgICAgICAgICAgICAgICAgaWYg
KHR5cGVvZiBsaXN0RWwgIT09ICd1bmRlZmluZWQnICYmIGxpc3RFbCkgbGlzdEVsLnNjcm9sbFRvcCA9
IDA7CiAgICAgICAgICAgICAgICAgICAgICAgIGlmICh0eXBlb2YgcmVxdWVzdFZpZXcgPT09ICdmdW5j
dGlvbicpIHNldFRpbWVvdXQocmVxdWVzdFZpZXcsIDApOwogICAgICAgICAgICAgICAgICAgIH0gZWxz
ZSBpZiAodHlwZW9mIGJ0blRvZGF5ICE9PSAndW5kZWZpbmVkJyAmJiBidG5Ub2RheSkgewogICAgICAg
ICAgICAgICAgICAgICAgICBidG5Ub2RheS5jbGFzc0xpc3QudG9nZ2xlKCdvbicsICEhdG9kYXlPbmx5
KTsKICAgICAgICAgICAgICAgICAgICB9CiAgICAgICAgICAgICAgICB9IGNhdGNoIHt9CiAgICAgICAg
ICAgIH0KICAgICAgICAgICAgLy8gPz8g6ZWc5YOP5pCc57Si77ya5LiN6KaBIGZvY3Vz77yM6YG/5YWN
5oqi6LWw5Y6f57yW6L6R5qGG5YWJ5qCHCiAgICAgICAgfSBjYXRjaCB7fQogICAgfTsKICAgIHdpbmRv
dy5fX3R5cGVTZWFyY2ggPSAoY2gpID0+IHsKICAgICAgICB0cnkgewogICAgICAgICAgICB3aW5kb3cu
X19wcmVwVHlwZVNlYXJjaCAmJiB3aW5kb3cuX19wcmVwVHlwZVNlYXJjaCgpOwogICAgICAgICAgICBj
b25zdCBzID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NlYXJjaCcpOwogICAgICAgICAgICBpZiAo
IXMpIHJldHVybjsKICAgICAgICAgICAgcy52YWx1ZSA9IFN0cmluZyhzLnZhbHVlIHx8ICcnKSArIFN0
cmluZyhjaCA9PSBudWxsID8gJycgOiBjaCk7CiAgICAgICAgICAgIHMuY2xhc3NMaXN0LnRvZ2dsZSgn
aGFzLXZhbCcsICEhcy52YWx1ZSk7CiAgICAgICAgICAgIHMuZGlzcGF0Y2hFdmVudChuZXcgRXZlbnQo
J2lucHV0JywgeyBidWJibGVzOiB0cnVlIH0pKTsKICAgICAgICB9IGNhdGNoIHt9CiAgICB9OwogICAg
d2luZG93Ll9fYmtzcFNlYXJjaCA9ICgpID0+IHsKICAgICAgICB0cnkgewogICAgICAgICAgICB3aW5k
b3cuX19wcmVwVHlwZVNlYXJjaCAmJiB3aW5kb3cuX19wcmVwVHlwZVNlYXJjaCgpOwogICAgICAgICAg
ICBjb25zdCBzID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NlYXJjaCcpOwogICAgICAgICAgICBp
ZiAoIXMpIHJldHVybjsKICAgICAgICAgICAgY29uc3QgdiA9IFN0cmluZyhzLnZhbHVlIHx8ICcnKTsK
ICAgICAgICAgICAgcy52YWx1ZSA9IHYubGVuZ3RoID8gdi5zbGljZSgwLCAtMSkgOiAnJzsKICAgICAg
ICAgICAgcy5jbGFzc0xpc3QudG9nZ2xlKCdoYXMtdmFsJywgISFzLnZhbHVlKTsKICAgICAgICAgICAg
cy5kaXNwYXRjaEV2ZW50KG5ldyBFdmVudCgnaW5wdXQnLCB7IGJ1YmJsZXM6IHRydWUgfSkpOwogICAg
ICAgIH0gY2F0Y2gge30KICAgIH07CiAgICB3aW5kb3cuX19zZXRTZWFyY2hRdWVyeSA9IChxKSA9PiB7
CiAgICAgICAgdHJ5IHsKICAgICAgICAgICAgY29uc3QgcyA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlk
KCdzZWFyY2gnKTsKICAgICAgICAgICAgaWYgKCFzKSByZXR1cm47CiAgICAgICAgICAgIGNvbnN0IG5l
eHQgPSBTdHJpbmcocSA9PSBudWxsID8gJycgOiBxKTsKICAgICAgICAgICAgY29uc3QgcHJldiA9IFN0
cmluZyhzLnZhbHVlIHx8ICcnKTsKICAgICAgICAgICAgLy8g5ZCM5YWz6ZSu5a2X6YeN5aSN5o6o6YCB
77ya5Y+q5L+d6K+B5pCc57Si5qGG5byA552A77yM56aB5q2i5YaNIHJlcXVlc3RWaWV377yI5Lya5q27
5b6q546v6Zeq77yJCiAgICAgICAgICAgIGlmIChwcmV2ID09PSBuZXh0ICYmIFN0cmluZyhxdWVyeSB8
fCAnJykgPT09IG5leHQpIHsKICAgICAgICAgICAgICAgIHRyeSB7CiAgICAgICAgICAgICAgICAgICAg
Y29uc3Qgd3JhcCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzZWFyY2gtd3JhcCcpOwogICAgICAg
ICAgICAgICAgICAgIGlmICh3cmFwICYmICF3cmFwLmNsYXNzTGlzdC5jb250YWlucygnb3BlbicpKQog
ICAgICAgICAgICAgICAgICAgICAgICB3cmFwLmNsYXNzTGlzdC5hZGQoJ29wZW4nKTsKICAgICAgICAg
ICAgICAgIH0gY2F0Y2gge30KICAgICAgICAgICAgICAgIHJldHVybjsKICAgICAgICAgICAgfQogICAg
ICAgICAgICAvLyDmiZPlrZfljbPml7bkuIrlsY/vvIzkuI7no4Hnm5jmkJzntKLop6PogKYKICAgICAg
ICAgICAgcy52YWx1ZSA9IG5leHQ7CiAgICAgICAgICAgIHMuY2xhc3NMaXN0LnRvZ2dsZSgnaGFzLXZh
bCcsICEhcy52YWx1ZSk7CiAgICAgICAgICAgIGNvbnN0IHNjbHIgPSBkb2N1bWVudC5nZXRFbGVtZW50
QnlJZCgnc2VhcmNoLWNscicpOwogICAgICAgICAgICBpZiAoc2Nscikgc2Nsci5zdHlsZS5kaXNwbGF5
ID0gcy52YWx1ZSA/ICdibG9jaycgOiAnbm9uZSc7CiAgICAgICAgICAgIHF1ZXJ5ID0gcy52YWx1ZTsK
ICAgICAgICAgICAgdHJ5IHsKICAgICAgICAgICAgICAgIGNvbnN0IHdyYXAgPSBkb2N1bWVudC5nZXRF
bGVtZW50QnlJZCgnc2VhcmNoLXdyYXAnKTsKICAgICAgICAgICAgICAgIGlmICh3cmFwICYmICF3cmFw
LmNsYXNzTGlzdC5jb250YWlucygnb3BlbicpKQogICAgICAgICAgICAgICAgICAgIHdpbmRvdy5fX3By
ZXBUeXBlU2VhcmNoICYmIHdpbmRvdy5fX3ByZXBUeXBlU2VhcmNoKCk7CiAgICAgICAgICAgICAgICBl
bHNlIGlmICh3cmFwKQogICAgICAgICAgICAgICAgICAgIHdyYXAuY2xhc3NMaXN0LmFkZCgnb3Blbicp
OwogICAgICAgICAgICB9IGNhdGNoIHt9CiAgICAgICAgICAgIHdpbmRvdy5fX2hvc3RGaWx0ZXJlZCA9
IGZhbHNlOwogICAgICAgICAgICB3aW5kb3cuX19ob3N0RmlsdGVyUSA9ICcnOwogICAgICAgICAgICBp
ZiAoU3RyaW5nKHF1ZXJ5IHx8ICcnKS50cmltKCkpIHsKICAgICAgICAgICAgICAgIHdhaXRpbmdEYXRh
ID0gdHJ1ZTsKICAgICAgICAgICAgICAgIHdpbmRvdy5fX2RhdGFSZWFkeSA9IGZhbHNlOwogICAgICAg
ICAgICB9CiAgICAgICAgICAgIHRyeSB7CiAgICAgICAgICAgICAgICBjb25zdCBjbnQgPSBkb2N1bWVu
dC5nZXRFbGVtZW50QnlJZCgnYmFyLXR4dCcpOwogICAgICAgICAgICAgICAgaWYgKGNudCAmJiBTdHJp
bmcocXVlcnkgfHwgJycpLnRyaW0oKSkKICAgICAgICAgICAgICAgICAgICBjbnQudGV4dENvbnRlbnQg
PSB2aXNpYmxlTGlzdCgpLmxlbmd0aCArICcg5p2hJzsKICAgICAgICAgICAgfSBjYXRjaCB7fQogICAg
ICAgICAgICB0cnkgeyByZW5kZXIoKTsgfSBjYXRjaCB7fQogICAgICAgICAgICBjbGVhclRpbWVvdXQo
d2luZG93Ll9fcXFWaWV3RGViKTsKICAgICAgICAgICAgd2luZG93Ll9fcXFWaWV3RGViID0gc2V0VGlt
ZW91dCgoKSA9PiB7CiAgICAgICAgICAgICAgICB3aW5kb3cuX19xcVZpZXdEZWIgPSAwOwogICAgICAg
ICAgICAgICAgcmVxdWVzdFZpZXcoKTsKICAgICAgICAgICAgfSwgNzApOwogICAgICAgIH0gY2F0Y2gg
e30KICAgIH07CiAgICB3aW5kb3cuX19jbGVhclFRU2VhcmNoID0gKCkgPT4gewogICAgICAgIHRyeSB7
CiAgICAgICAgICAgIHF1ZXJ5ID0gJyc7CiAgICAgICAgICAgIHdpbmRvdy5fX2hvc3RGaWx0ZXJlZCA9
IGZhbHNlOwogICAgICAgICAgICB3aW5kb3cuX19ob3N0RmlsdGVyUSA9ICcnOwogICAgICAgICAgICBj
b25zdCBzID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NlYXJjaCcpOwogICAgICAgICAgICBpZiAo
cykgewogICAgICAgICAgICAgICAgcy52YWx1ZSA9ICcnOwogICAgICAgICAgICAgICAgcy5jbGFzc0xp
c3QucmVtb3ZlKCdoYXMtdmFsJyk7CiAgICAgICAgICAgICAgICB0cnkgeyBzLmJsdXIoKTsgfSBjYXRj
aCB7fQogICAgICAgICAgICB9CiAgICAgICAgICAgIGNvbnN0IHNjbHIgPSBkb2N1bWVudC5nZXRFbGVt
ZW50QnlJZCgnc2VhcmNoLWNscicpOwogICAgICAgICAgICBpZiAoc2Nscikgc2Nsci5zdHlsZS5kaXNw
bGF5ID0gJ25vbmUnOwogICAgICAgICAgICBjb25zdCB3cmFwID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5
SWQoJ3NlYXJjaC13cmFwJyk7CiAgICAgICAgICAgIGlmICh3cmFwKSB3cmFwLmNsYXNzTGlzdC5yZW1v
dmUoJ29wZW4nKTsKICAgICAgICAgICAgdHJ5IHsgcmVuZGVyKCk7IH0gY2F0Y2gge30KICAgICAgICB9
IGNhdGNoIHt9CiAgICB9OwogICAgLy8gQ2FwdHVyZSBDdHJsK0YgaW5zaWRlIFdlYlZpZXcgKENocm9t
aXVtIGZpbmQgaXMgZGlzYWJsZWQsIGJ1dCBzdGlsbCBoYW5kbGUgaGVyZSkKICAgIGRvY3VtZW50LmFk
ZEV2ZW50TGlzdGVuZXIoJ2tleWRvd24nLCBlID0+IHsKICAgICAgICBpZiAoKGUuY3RybEtleSB8fCBl
Lm1ldGFLZXkpICYmICFlLmFsdEtleSAmJiAoZS5rZXkgPT09ICdmJyB8fCBlLmtleSA9PT0gJ0YnKSkg
ewogICAgICAgICAgICBlLnByZXZlbnREZWZhdWx0KCk7CiAgICAgICAgICAgIGUuc3RvcFByb3BhZ2F0
aW9uKCk7CiAgICAgICAgICAgIG9wZW5TZWFyY2goKTsKICAgICAgICB9CiAgICB9LCB0cnVlKTsKICAg
IGJ0blNlYXJjaC5hZGRFdmVudExpc3RlbmVyKCdjbGljaycsIGUgPT4gewogICAgICAgIGUuc3RvcFBy
b3BhZ2F0aW9uKCk7CiAgICAgICAgb3BlblNlYXJjaCgpOwogICAgfSk7CiAgICBsZXQgX19zcmNoQ29t
cG9zaW5nID0gZmFsc2U7CiAgICBjb25zdCBfX2ZsdXNoU2VhcmNoSW5wdXQgPSAoKSA9PiB7CiAgICAg
ICAgcXVlcnkgPSBzcmNoLnZhbHVlOwogICAgICAgIHNyY2guY2xhc3NMaXN0LnRvZ2dsZSgnaGFzLXZh
bCcsICEhcXVlcnkpOwogICAgICAgIHNjbHIuc3R5bGUuZGlzcGxheSA9IHF1ZXJ5ID8gJ2Jsb2NrJyA6
ICdub25lJzsKICAgICAgICBsaXN0RWwuc2Nyb2xsVG9wID0gMDsKICAgICAgICB3aW5kb3cuX19ob3N0
RmlsdGVyZWQgPSBmYWxzZTsKICAgICAgICB3aW5kb3cuX19ob3N0RmlsdGVyUSA9ICcnOwogICAgICAg
IHRyeSB7IHJlbmRlcigpOyB9IGNhdGNoIHt9CiAgICAgICAgY2xlYXJUaW1lb3V0KGRlYik7CiAgICAg
ICAgZGViID0gc2V0VGltZW91dChyZXF1ZXN0VmlldywgODApOwogICAgfTsKICAgIHNyY2guYWRkRXZl
bnRMaXN0ZW5lcignY29tcG9zaXRpb25zdGFydCcsICgpID0+IHsgX19zcmNoQ29tcG9zaW5nID0gdHJ1
ZTsgfSk7CiAgICBzcmNoLmFkZEV2ZW50TGlzdGVuZXIoJ2NvbXBvc2l0aW9uZW5kJywgKCkgPT4gewog
ICAgICAgIF9fc3JjaENvbXBvc2luZyA9IGZhbHNlOwogICAgICAgIF9fZmx1c2hTZWFyY2hJbnB1dCgp
OwogICAgfSk7CiAgICBzcmNoLmFkZEV2ZW50TGlzdGVuZXIoJ2lucHV0JywgKCkgPT4gewogICAgICAg
IGlmIChfX3NyY2hDb21wb3NpbmcpIHsKICAgICAgICAgICAgcXVlcnkgPSBzcmNoLnZhbHVlOwogICAg
ICAgICAgICBzcmNoLmNsYXNzTGlzdC50b2dnbGUoJ2hhcy12YWwnLCAhIXF1ZXJ5KTsKICAgICAgICAg
ICAgc2Nsci5zdHlsZS5kaXNwbGF5ID0gcXVlcnkgPyAnYmxvY2snIDogJ25vbmUnOwogICAgICAgICAg
ICByZXR1cm47CiAgICAgICAgfQogICAgICAgIF9fZmx1c2hTZWFyY2hJbnB1dCgpOwogICAgfSk7CiAg
ICBzcmNoLmFkZEV2ZW50TGlzdGVuZXIoJ2ZvY3VzJywgKCkgPT4gewogICAgICAgIC8vIElkZW1wb3Rl
bnQgb24gQUhLIHNpZGUg4oCUIHNhZmUsIGJ1dCBhdm9pZCBzcGFtbWluZyBkdXJpbmcgSU1FCiAgICAg
ICAgdHJ5IHsgYWhrKCdmb2N1c1BhbmVsJyk7IH0gY2F0Y2gge30KICAgIH0pOwogICAgc3JjaC5hZGRF
dmVudExpc3RlbmVyKCdibHVyJywgKCkgPT4gewogICAgICAgIHNldFRpbWVvdXQoKCkgPT4gewogICAg
ICAgICAgICBpZiAoZG9jdW1lbnQuYWN0aXZlRWxlbWVudCA9PT0gc3JjaCkgcmV0dXJuOwogICAgICAg
ICAgICBpZiAoZG9jdW1lbnQuYWN0aXZlRWxlbWVudCA9PT0gc2NsciB8fCAoc2NsciAmJiBzY2xyLmNv
bnRhaW5zKGRvY3VtZW50LmFjdGl2ZUVsZW1lbnQpKSkgcmV0dXJuOwogICAgICAgICAgICBpZiAoZG9j
dW1lbnQuYWN0aXZlRWxlbWVudCA9PT0gYnRuVG9kYXkgfHwgKGJ0blRvZGF5ICYmIGJ0blRvZGF5LmNv
bnRhaW5zKGRvY3VtZW50LmFjdGl2ZUVsZW1lbnQpKSkgcmV0dXJuOwogICAgICAgICAgICAvLyBJTUUg
Y2FuZGlkYXRlIFVJIHN0ZWFscyBmb2N1cyBicmllZmx5IOKAlCBrZWVwIHNlYXJjaCBpZiBzdGlsbCBj
b21wb3NpbmcKICAgICAgICAgICAgaWYgKF9fc3JjaENvbXBvc2luZykgcmV0dXJuOwogICAgICAgICAg
ICBjbG9zZVNlYXJjaFVpKCk7CiAgICAgICAgICAgIGFoaygnYmx1clBhbmVsJyk7CiAgICAgICAgfSwg
MjgwKTsKICAgIH0pOwogICAgc3JjaC5hZGRFdmVudExpc3RlbmVyKCdrZXlkb3duJywgZSA9PiB7CiAg
ICAgICAgLy8gQ3RybCtJIC8gQ3RybCtLOiBtb3ZlIGNsaXAgc2VsZWN0aW9uIChub3QgaW5zZXJ0IGNo
YXIgLyBicm93c2VyIHNob3J0Y3V0KQogICAgICAgIGlmICgoZS5jdHJsS2V5IHx8IGUubWV0YUtleSkg
JiYgKGUua2V5ID09PSAnaScgfHwgZS5rZXkgPT09ICdJJykpIHsKICAgICAgICAgICAgZS5wcmV2ZW50
RGVmYXVsdCgpOwogICAgICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgICAgICAgICB3aW5k
b3cuX19uYXYgJiYgd2luZG93Ll9fbmF2KCd1cCcpOwogICAgICAgICAgICByZXR1cm47CiAgICAgICAg
fQogICAgICAgIGlmICgoZS5jdHJsS2V5IHx8IGUubWV0YUtleSkgJiYgKGUua2V5ID09PSAnaycgfHwg
ZS5rZXkgPT09ICdLJykpIHsKICAgICAgICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOwogICAgICAgICAg
ICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgICAgICAgICB3aW5kb3cuX19uYXYgJiYgd2luZG93Ll9f
bmF2KCdkb3duJyk7CiAgICAgICAgICAgIHJldHVybjsKICAgICAgICB9CiAgICAgICAgaWYgKGUua2V5
ID09PSAnQXJyb3dEb3duJykgewogICAgICAgICAgICBlLnByZXZlbnREZWZhdWx0KCk7CiAgICAgICAg
ICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAgICAgICAgIHdpbmRvdy5fX25hdiAmJiB3aW5kb3cu
X19uYXYoJ2Rvd24nKTsKICAgICAgICAgICAgcmV0dXJuOwogICAgICAgIH0KICAgICAgICBpZiAoZS5r
ZXkgPT09ICdBcnJvd1VwJykgewogICAgICAgICAgICBlLnByZXZlbnREZWZhdWx0KCk7CiAgICAgICAg
ICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAgICAgICAgIHdpbmRvdy5fX25hdiAmJiB3aW5kb3cu
X19uYXYoJ3VwJyk7CiAgICAgICAgICAgIHJldHVybjsKICAgICAgICB9CiAgICAgICAgaWYgKGUua2V5
ID09PSAnRXNjYXBlJykgewogICAgICAgICAgICBlLnByZXZlbnREZWZhdWx0KCk7CiAgICAgICAgICAg
IGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAgICAgICAgIC8vIEFsd2F5cyBkaXNtaXNzIHRoZSB3aG9s
ZSBwYW5lbCAobm90IGp1c3QgdGhlIHNlYXJjaCBmaWVsZCkKICAgICAgICAgICAgaWYgKCFwaW5uZWRV
SSkgYWhrKCdoaWRlJyk7CiAgICAgICAgICAgIHJldHVybjsKICAgICAgICB9CiAgICAgICAgZS5zdG9w
UHJvcGFnYXRpb24oKTsKICAgIH0pOwogICAgc2Nsci5hZGRFdmVudExpc3RlbmVyKCdjbGljaycsIGUg
PT4gewogICAgICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAgICAgc3JjaC52YWx1ZSA9IHF1ZXJ5
ID0gJyc7CiAgICAgICAgc2Nsci5zdHlsZS5kaXNwbGF5ID0gJ25vbmUnOwogICAgICAgIHNyY2guY2xh
c3NMaXN0LnJlbW92ZSgnaGFzLXZhbCcpOwogICAgICAgIHJlcXVlc3RWaWV3KCk7CiAgICAgICAgYWhr
KCdmb2N1c1BhbmVsJyk7CiAgICAgICAgc3JjaC5mb2N1cygpOwogICAgfSk7CgogICAgY29uc3QgVEFC
X05BTUVTID0geyBhbGw6ICflhajpg6gnLCB0ZXh0OiAn5paH5pysJywgaW1hZ2U6ICflm77lg48nLCBm
aWxlOiAn5paH5Lu2JywgcmVjZW50OiAn5pyA6L+RJywgcGlubmVkOiAn5pS26JePJyB9OwogICAgY29u
c3QgY2xyRGxnID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2Nsci1kbGcnKTsKICAgIGNvbnN0IGNs
ckFsbENiID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2Nsci1hbGwnKTsKICAgIGZ1bmN0aW9uIG9w
ZW5DbGVhckRsZygpIHsKICAgICAgICBjb25zdCBuYW1lID0gVEFCX05BTUVTW2N1clRhYl0gfHwgJ+W9
k+WJjSc7CiAgICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2Nsci10aXRsZScpLnRleHRDb250
ZW50ID0gJ+a4heepuuOAjCcgKyBuYW1lICsgJ+OAje+8nyc7CiAgICAgICAgZG9jdW1lbnQuZ2V0RWxl
bWVudEJ5SWQoJ2Nsci1kZXNjJykudGV4dENvbnRlbnQgPSBjdXJUYWIgPT09ICdwaW5uZWQnCiAgICAg
ICAgICAgID8gJ+m7mOiupOS7hea4heepuuW9k+WkqeeahOaUtuiXj+mhueOAguWLvumAieOAjOa4heep
uuaJgOacieOAjeWPr+a4hemZpOivpemAiemhueWNoeWFqOmDqOWGheWuueOAgicKICAgICAgICAgICAg
OiAoY3VyVGFiID09PSAncmVjZW50JwogICAgICAgICAgICAgICAgPyAn5riF56m644CM5pyA6L+R44CN
5Lya5Yig6Zmk5pyq5Zu65a6a55qE5pyA6L+R55uu5b2V6K6w5b2V77yb5bey5Zu65a6a55qE55uu5b2V
5Lya5L+d55WZ44CCJwogICAgICAgICAgICAgICAgOiAn5LuF5riF56m65b2T5YmN6YCJ6aG55Y2h44CC
6buY6K6k5Y+q5riF5b2T5aSp77yb5pS26JeP6aG55LiN5Lya6KKr5riF6Zmk44CC5Yu+6YCJ44CM5riF
56m65omA5pyJ44CN5Y+v5riF6Zmk6K+l6YCJ6aG55Y2h5YWo6YOo5pel5pyf44CCJyk7CiAgICAgICAg
Y2xyQWxsQ2IuY2hlY2tlZCA9IGZhbHNlOwogICAgICAgIGNsckRsZy5jbGFzc0xpc3QuYWRkKCdvbicp
OwogICAgfQogICAgZnVuY3Rpb24gY2xvc2VDbGVhckRsZygpIHsKICAgICAgICBjbHJEbGcuY2xhc3NM
aXN0LnJlbW92ZSgnb24nKTsKICAgIH0KICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdidG4tY2xy
JykuYWRkRXZlbnRMaXN0ZW5lcignY2xpY2snLCBlID0+IHsKICAgICAgICBlLnN0b3BQcm9wYWdhdGlv
bigpOwogICAgICAgIG9wZW5DbGVhckRsZygpOwogICAgfSk7CiAgICBkb2N1bWVudC5nZXRFbGVtZW50
QnlJZCgnY2xyLWNhbmNlbCcpLmFkZEV2ZW50TGlzdGVuZXIoJ2NsaWNrJywgZSA9PiB7CiAgICAgICAg
ZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICBjbG9zZUNsZWFyRGxnKCk7CiAgICB9KTsKICAgIGNs
ckRsZy5hZGRFdmVudExpc3RlbmVyKCdjbGljaycsIGUgPT4gewogICAgICAgIGlmIChlLnRhcmdldCA9
PT0gY2xyRGxnKSBjbG9zZUNsZWFyRGxnKCk7CiAgICB9KTsKICAgIGRvY3VtZW50LmdldEVsZW1lbnRC
eUlkKCdjbHItb2snKS5hZGRFdmVudExpc3RlbmVyKCdjbGljaycsIGUgPT4gewogICAgICAgIGUuc3Rv
cFByb3BhZ2F0aW9uKCk7CiAgICAgICAgY29uc3Qgc2NvcGUgPSAoY3VyVGFiID09PSAncmVjZW50Jykg
PyAnYWxsJyA6IChjbHJBbGxDYi5jaGVja2VkID8gJ2FsbCcgOiAndG9kYXknKTsKICAgICAgICBjbG9z
ZUNsZWFyRGxnKCk7CiAgICAgICAgYWhrKCdjbGVhcicsIGN1clRhYiwgc2NvcGUpOwogICAgfSk7CiAg
ICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbXVsdGktc2VsJykuYWRkRXZlbnRMaXN0ZW5lcignY2xp
Y2snLCBlID0+IHsKICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgICAgIGNsZWFyTXVsdGko
dHJ1ZSk7CiAgICB9KTsKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdidG4tcGluJykuYWRkRXZl
bnRMaXN0ZW5lcignY2xpY2snLCBlID0+IHsKICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAg
ICAgIHBpbm5lZFVJID0gIXBpbm5lZFVJOwogICAgICAgIGUuY3VycmVudFRhcmdldC5jbGFzc0xpc3Qu
dG9nZ2xlKCdvbicsIHBpbm5lZFVJKTsKICAgICAgICBhaGsoJ3RvZ2dsZVBpbicsIHBpbm5lZFVJID8g
JzEnIDogJzAnKTsKICAgIH0pOwoKICAgIHdpbmRvdy5fX3BlcmZNYXJrID0gKHN0YWdlKSA9PiB7CiAg
ICAgICAgdHJ5IHsKICAgICAgICAgICAgaWYgKHdpbmRvdy5jaHJvbWUgJiYgY2hyb21lLndlYnZpZXcg
JiYgY2hyb21lLndlYnZpZXcucG9zdE1lc3NhZ2UpCiAgICAgICAgICAgICAgICBjaHJvbWUud2Vidmll
dy5wb3N0TWVzc2FnZSgncGVyZnwnICsgU3RyaW5nKHN0YWdlIHx8ICcnKSk7CiAgICAgICAgfSBjYXRj
aCB7fQogICAgfTsKCiAgICB3aW5kb3cuX191cGRhdGVDbGlwcyA9IHBheWxvYWQgPT4gewogICAgICAg
IGNvbnN0IHQwID0gKHR5cGVvZiBwZXJmb3JtYW5jZSAhPT0gJ3VuZGVmaW5lZCcgJiYgcGVyZm9ybWFu
Y2Uubm93KSA/IHBlcmZvcm1hbmNlLm5vdygpIDogRGF0ZS5ub3coKTsKICAgICAgICB3aW5kb3cuX19w
ZXJmTWFyaygnanNfdXBkYXRlQ2xpcHNfZW50ZXIgbj0nICsgKHBheWxvYWQgJiYgcGF5bG9hZC5pdGVt
cyA/IHBheWxvYWQuaXRlbXMubGVuZ3RoIDogKEFycmF5LmlzQXJyYXkocGF5bG9hZCkgPyBwYXlsb2Fk
Lmxlbmd0aCA6IDApKSk7CiAgICAgICAgLy8gS2VlcCBwcmV2aW91cyBzY3JvbGwgZm9yIGxvYWQtbW9y
ZTsgcmVzZXQgd2hlbiBvcGVuaW5nIHBhbmVsIHRvIGZpcnN0IGl0ZW0KICAgICAgICBjb25zdCBrZWVw
U2Nyb2xsID0gIXNlbGVjdEZpcnN0T25TaG93OwogICAgICAgIGNvbnN0IHN0ID0gbGlzdEVsLnNjcm9s
bFRvcDsKICAgICAgICB3aW5kb3cuX193YWl0aW5nVmlldyA9IGZhbHNlOwogICAgICAgIGNvbnN0IHdh
c0FwcGVuZCA9IHBheWxvYWQgJiYgcGF5bG9hZC5hcHBlbmQ7CiAgICAgICAgbG9hZGluZ01vcmUgPSBm
YWxzZTsKICAgICAgICBjb25zdCBwcmV2SXRlbXMgPSBhbGxDbGlwczsKICAgICAgICBsZXQgbmV4dEl0
ZW1zID0gW107CiAgICAgICAgbGV0IG5leHRUb3RhbCA9IDA7CiAgICAgICAgbGV0IG5leHRGaWx0ZXJl
ZCA9IGZhbHNlOwogICAgICAgIGxldCBwVGFiID0gJyc7CiAgICAgICAgbGV0IHBQaW5uZWRUb3RhbCA9
IC0xOwogICAgICAgIGlmIChBcnJheS5pc0FycmF5KHBheWxvYWQpKSB7CiAgICAgICAgICAgIG5leHRJ
dGVtcyA9IHBheWxvYWQ7CiAgICAgICAgICAgIG5leHRUb3RhbCA9IHBheWxvYWQubGVuZ3RoOwogICAg
ICAgICAgICBuZXh0RmlsdGVyZWQgPSBmYWxzZTsKICAgICAgICB9IGVsc2UgaWYgKHBheWxvYWQgJiYg
dHlwZW9mIHBheWxvYWQgPT09ICdvYmplY3QnKSB7CiAgICAgICAgICAgIG5leHRUb3RhbCA9IE51bWJl
cihwYXlsb2FkLnRvdGFsKSB8fCAwOwogICAgICAgICAgICBuZXh0SXRlbXMgPSBBcnJheS5pc0FycmF5
KHBheWxvYWQuaXRlbXMpID8gcGF5bG9hZC5pdGVtcyA6IFtdOwogICAgICAgICAgICBwVGFiID0gcGF5
bG9hZC50YWIgIT0gbnVsbCA/IFN0cmluZyhwYXlsb2FkLnRhYikgOiAnJzsKICAgICAgICAgICAgaWYg
KHBheWxvYWQucGlubmVkVG90YWwgIT0gbnVsbCAmJiBwYXlsb2FkLnBpbm5lZFRvdGFsICE9PSAnJykK
ICAgICAgICAgICAgICAgIHBQaW5uZWRUb3RhbCA9IE51bWJlcihwYXlsb2FkLnBpbm5lZFRvdGFsKSB8
fCAwOwogICAgICAgICAgICBjb25zdCBwcTAgPSBwYXlsb2FkLnF1ZXJ5ICE9IG51bGwgPyBTdHJpbmco
cGF5bG9hZC5xdWVyeSkgOiAnJzsKICAgICAgICAgICAgbmV4dEZpbHRlcmVkID0gISEocGF5bG9hZC5m
aWx0ZXJlZCB8fCAocHEwICYmIHBxMC50cmltKCkpKTsKICAgICAgICAgICAgaWYgKHBheWxvYWQuYXBw
ZW5kKSB7CiAgICAgICAgICAgICAgICAvLyBBcHBlbmQgb25seSBhcHBsaWVzIHRvIHRoZSB0YWIgd2Un
cmUgY3VycmVudGx5IHZpZXdpbmcKICAgICAgICAgICAgICAgIGlmIChwVGFiICYmIHBUYWIgIT09IGN1
clRhYikKICAgICAgICAgICAgICAgICAgICByZXR1cm47CiAgICAgICAgICAgICAgICBjb25zdCBzZWVu
ID0gbmV3IFNldChhbGxDbGlwcy5tYXAoYyA9PiArYy5pZCkpOwogICAgICAgICAgICAgICAgY29uc3Qg
bWVyZ2VkID0gYWxsQ2xpcHMuc2xpY2UoKTsKICAgICAgICAgICAgICAgIG5leHRJdGVtcy5mb3JFYWNo
KGl0ID0+IHsKICAgICAgICAgICAgICAgICAgICBpZiAoIXNlZW4uaGFzKCtpdC5pZCkpIG1lcmdlZC5w
dXNoKGl0KTsKICAgICAgICAgICAgICAgIH0pOwogICAgICAgICAgICAgICAgbmV4dEl0ZW1zID0gbWVy
Z2VkOwogICAgICAgICAgICAgICAgbmV4dFRvdGFsID0gTWF0aC5tYXgobmV4dFRvdGFsLCBuZXh0SXRl
bXMubGVuZ3RoKTsKICAgICAgICAgICAgfQogICAgICAgICAgICAvLyDmkJzntKLmoYbku6XmiZPlrZfp
lZzlg4/kuLrlh4bvvIznu53kuI3ooqvmu57lkI7nmoTno4Hnm5jnu5Pmnpzlhpnlm57ml6flhbPplK7l
rZcKICAgICAgICAgICAgdHJ5IHsKICAgICAgICAgICAgICAgIGNvbnN0IHMgPSBkb2N1bWVudC5nZXRF
bGVtZW50QnlJZCgnc2VhcmNoJyk7CiAgICAgICAgICAgICAgICBpZiAocyAmJiBTdHJpbmcocy52YWx1
ZSB8fCAnJykubGVuZ3RoKQogICAgICAgICAgICAgICAgICAgIHF1ZXJ5ID0gcy52YWx1ZTsKICAgICAg
ICAgICAgICAgIGVsc2UgaWYgKHBxMCAhPT0gJycgJiYgIVN0cmluZyhxdWVyeSB8fCAnJykudHJpbSgp
KQogICAgICAgICAgICAgICAgICAgIHF1ZXJ5ID0gcHEwOwogICAgICAgICAgICB9IGNhdGNoIHt9CiAg
ICAgICAgfSBlbHNlIHsKICAgICAgICAgICAgbmV4dEl0ZW1zID0gW107CiAgICAgICAgICAgIG5leHRU
b3RhbCA9IDA7CiAgICAgICAgICAgIG5leHRGaWx0ZXJlZCA9IGZhbHNlOwogICAgICAgIH0KCiAgICAg
ICAgY29uc3QgYm94USA9IFN0cmluZyhxdWVyeSB8fCAnJykudHJpbSgpOwogICAgICAgIGNvbnN0IHB1
c2hRID0gKHBheWxvYWQgJiYgdHlwZW9mIHBheWxvYWQgPT09ICdvYmplY3QnICYmIHBheWxvYWQucXVl
cnkgIT0gbnVsbCkKICAgICAgICAgICAgPyBTdHJpbmcocGF5bG9hZC5xdWVyeSkudHJpbSgpIDogJyc7
CgogICAgICAgIC8vIEFsd2F5cyByZWZyZXNoIOaUtuiXjyBiYWRnZSBmcm9tIGhvc3Qgd2hlbiBwcm92
aWRlZAogICAgICAgIGlmIChwUGlubmVkVG90YWwgPj0gMCkKICAgICAgICAgICAgcGlubmVkVG90YWwg
PSBwUGlubmVkVG90YWw7CgogICAgICAgIC8vIFN0YWxlIHNlYXJjaCBwdXNoIChlLmcuICJzcXVhcmUg
bG9naSIgbGFuZHMgYWZ0ZXIgdXNlciB0eXBlZCAic3F1YXJlIGxvZ2luIikg4oCUY2FjaGUgb25seQog
ICAgICAgIGlmICghd2FzQXBwZW5kICYmIG5leHRGaWx0ZXJlZCAmJiBwdXNoUSAmJiBib3hRICYmIHB1
c2hRICE9PSBib3hRKSB7CiAgICAgICAgICAgIHZpZXdNZW0uc2V0KHZpZXdNZW1LZXkocFRhYiB8fCBj
dXJUYWIsIHB1c2hRLCB0b2RheU9ubHkpLCB7CiAgICAgICAgICAgICAgICBpdGVtczogbmV4dEl0ZW1z
LnNsaWNlKCksCiAgICAgICAgICAgICAgICB0b3RhbDogbmV4dFRvdGFsCiAgICAgICAgICAgIH0pOwog
ICAgICAgICAgICByZXR1cm47CiAgICAgICAgfQoKICAgICAgICAvLyBTdGFsZSBwdXNoIGZvciBhbm90
aGVyIHRhYjogb25seSByZWZyZXNoIHRoYXQgdGFiJ3Mgdmlld01lbSwgZG9uJ3QgaGlqYWNrIFVJCiAg
ICAgICAgaWYgKCF3YXNBcHBlbmQgJiYgcFRhYiAmJiBwVGFiICE9PSBjdXJUYWIpIHsKICAgICAgICAg
ICAgY29uc3QgbWVtUSA9IChwYXlsb2FkICYmIHR5cGVvZiBwYXlsb2FkID09PSAnb2JqZWN0JyAmJiBw
YXlsb2FkLnF1ZXJ5ICE9IG51bGwpCiAgICAgICAgICAgICAgICA/IFN0cmluZyhwYXlsb2FkLnF1ZXJ5
KSA6ICcnOwogICAgICAgICAgICB2aWV3TWVtLnNldCh2aWV3TWVtS2V5KHBUYWIsIG1lbVEsIHRvZGF5
T25seSksIHsKICAgICAgICAgICAgICAgIGl0ZW1zOiBuZXh0SXRlbXMuc2xpY2UoKSwKICAgICAgICAg
ICAgICAgIHRvdGFsOiBuZXh0VG90YWwKICAgICAgICAgICAgfSk7CiAgICAgICAgICAgIC8vIFN0aWxs
IHVwZGF0ZSBwaW4gYmFkZ2UgaWYgaG9zdCBzZW50IGl0CiAgICAgICAgICAgIHRyeSB7IHVwZGF0ZVBp
bkRvdCgpOyB9IGNhdGNoIHt9CiAgICAgICAgICAgIC8vIFFRIOaQnOe0ouabvuWbuuWumuaOqCBhbGwg
dGFiIOKGkiDlvZPliY0gdGFiIOS8muS4gOebtOmqqOaetu+8m+ihpeS4gOasoSByZXF1ZXN0Vmlldwog
ICAgICAgICAgICBpZiAod2FpdGluZ0RhdGEgJiYgcHVzaFEgPT09IGJveFEpIHsKICAgICAgICAgICAg
ICAgIHNldFRpbWVvdXQoKCkgPT4gewogICAgICAgICAgICAgICAgICAgIGlmICh3YWl0aW5nRGF0YSAm
JiBjdXJUYWIgIT09IHBUYWIpCiAgICAgICAgICAgICAgICAgICAgICAgIHJlcXVlc3RWaWV3KCk7CiAg
ICAgICAgICAgICAgICB9LCA0MCk7CiAgICAgICAgICAgIH0KICAgICAgICAgICAgcmV0dXJuOwogICAg
ICAgIH0KCiAgICAgICAgLy8gQm9vdHN0cmFwIHJhY2U6IEFISyBwdXNoZWQgZW1wdHkgYmVmb3JlIFdh
cm1BbGxWaWV3cyDigJRrZWVwIHNrZWxldG9uLCBpZ25vcmUKICAgICAgICBjb25zdCBxT24gPSBTdHJp
bmcocXVlcnkgfHwgJycpLnRyaW0oKS5sZW5ndGggPiAwOwogICAgICAgIGlmICghd2FzQXBwZW5kICYm
ICFuZXh0SXRlbXMubGVuZ3RoICYmIG5leHRUb3RhbCA8PSAwICYmICFxT24gJiYgIW5leHRGaWx0ZXJl
ZCAmJiAhc2F3Tm9uRW1wdHkpIHsKICAgICAgICAgICAgaWYgKCF3aW5kb3cuX19lbXB0eUZhbGxiYWNr
VCkgewogICAgICAgICAgICAgICAgd2luZG93Ll9fZW1wdHlGYWxsYmFja1QgPSBzZXRUaW1lb3V0KCgp
ID0+IHsKICAgICAgICAgICAgICAgICAgICB3aW5kb3cuX19lbXB0eUZhbGxiYWNrVCA9IDA7CiAgICAg
ICAgICAgICAgICAgICAgaWYgKHNhd05vbkVtcHR5KSByZXR1cm47CiAgICAgICAgICAgICAgICAgICAg
Ly8gVHJ1bHkgZW1wdHkgaW5zdGFsbCBhZnRlciB3YWl0CiAgICAgICAgICAgICAgICAgICAgc2F3Tm9u
RW1wdHkgPSB0cnVlOwogICAgICAgICAgICAgICAgICAgIGhvc3RQdXNoZWRPbmNlID0gdHJ1ZTsKICAg
ICAgICAgICAgICAgICAgICB3aW5kb3cuX19kYXRhUmVhZHkgPSB0cnVlOwogICAgICAgICAgICAgICAg
ICAgIGFsbENsaXBzID0gW107CiAgICAgICAgICAgICAgICAgICAgZGlza1RvdGFsID0gMDsKICAgICAg
ICAgICAgICAgICAgICBjbGVhcldhaXRpbmdEYXRhKCk7CiAgICAgICAgICAgICAgICAgICAgdHJ5IHsg
cmVuZGVyKCk7IH0gY2F0Y2gge30KICAgICAgICAgICAgICAgIH0sIDQ1MDApOwogICAgICAgICAgICB9
CiAgICAgICAgICAgIHdhaXRpbmdEYXRhID0gdHJ1ZTsKICAgICAgICAgICAgd2luZG93Ll9fZGF0YVJl
YWR5ID0gZmFsc2U7CiAgICAgICAgICAgIGhvc3RQdXNoZWRPbmNlID0gZmFsc2U7CiAgICAgICAgICAg
IHNldEJvb3RMb2FkaW5nKHRydWUpOwogICAgICAgICAgICB0cnkgeyByZW5kZXIoKTsgfSBjYXRjaCB7
fQogICAgICAgICAgICByZXR1cm47CiAgICAgICAgfQoKICAgICAgICBjbGVhcldhaXRpbmdEYXRhKCk7
CiAgICAgICAgYWxsQ2xpcHMgPSBuZXh0SXRlbXM7CiAgICAgICAgZGlza1RvdGFsID0gbmV4dFRvdGFs
OwogICAgICAgIC8vIEtlZXAgYmFyIGNvbnNpc3RlbnQgaWYgbGlzdCBncmV3IHBhc3QgYSBzdGFsZSB0
b3RhbAogICAgICAgIGlmIChhbGxDbGlwcy5sZW5ndGggPiBkaXNrVG90YWwpCiAgICAgICAgICAgIGRp
c2tUb3RhbCA9IGFsbENsaXBzLmxlbmd0aDsKICAgICAgICB3aW5kb3cuX19ob3N0RmlsdGVyZWQgPSBu
ZXh0RmlsdGVyZWQ7CiAgICAgICAgd2luZG93Ll9faG9zdEZpbHRlclEgPSAobmV4dEZpbHRlcmVkICYm
IHB1c2hRKSA/IHB1c2hRIDogJyc7CiAgICAgICAgLy8gRmlsdGVyZWQgc2VhcmNoIHdpdGggMCBoaXRz
IOKAlG11c3QgbGVhdmUgc2tlbGV0b24gKGhvc3QgZGlkIHJlc3BvbmQpCiAgICAgICAgaWYgKCF3YXNB
cHBlbmQgJiYgbmV4dEZpbHRlcmVkICYmICFhbGxDbGlwcy5sZW5ndGggJiYgZGlza1RvdGFsIDw9IDAp
IHsKICAgICAgICAgICAgaG9zdFB1c2hlZE9uY2UgPSB0cnVlOwogICAgICAgICAgICBzYXdOb25FbXB0
eSA9IHRydWU7CiAgICAgICAgfQogICAgICAgIGlmIChhbGxDbGlwcy5sZW5ndGggfHwgZGlza1RvdGFs
ID4gMCkKICAgICAgICAgICAgc2F3Tm9uRW1wdHkgPSB0cnVlOwogICAgICAgIGlmICh3aW5kb3cuX19l
bXB0eUZhbGxiYWNrVCkgewogICAgICAgICAgICBjbGVhclRpbWVvdXQod2luZG93Ll9fZW1wdHlGYWxs
YmFja1QpOwogICAgICAgICAgICB3aW5kb3cuX19lbXB0eUZhbGxiYWNrVCA9IDA7CiAgICAgICAgfQog
ICAgICAgIGlmICghd2FzQXBwZW5kKSB7CiAgICAgICAgICAgIGNvbnN0IG1lbVEgPSAocGF5bG9hZCAm
JiB0eXBlb2YgcGF5bG9hZCA9PT0gJ29iamVjdCcgJiYgcGF5bG9hZC5xdWVyeSAhPSBudWxsKQogICAg
ICAgICAgICAgICAgPyBTdHJpbmcocGF5bG9hZC5xdWVyeSkgOiBxdWVyeTsKICAgICAgICAgICAgdmll
d01lbS5zZXQodmlld01lbUtleShjdXJUYWIsIG1lbVEsIHRvZGF5T25seSksIHsKICAgICAgICAgICAg
ICAgIGl0ZW1zOiBhbGxDbGlwcy5zbGljZSgpLAogICAgICAgICAgICAgICAgdG90YWw6IGRpc2tUb3Rh
bAogICAgICAgICAgICB9KTsKICAgICAgICB9CiAgICAgICAgd2luZG93Ll9fZGF0YVJlYWR5ID0gdHJ1
ZTsKICAgICAgICBob3N0UHVzaGVkT25jZSA9IHRydWU7CgogICAgICAgIC8vIE1pZC13aGVlbDoga2Vl
cCBkYXRhLCBkZWxheSBET00gc28gc2Nyb2xsL2RyYWcgbmV2ZXIgaGl0Y2ggb24gYXBwZW5kIHBhaW50
CiAgICAgICAgaWYgKHdhc0FwcGVuZCAmJiB3aW5kb3cuX19zY3JvbGxCdXN5ICYmICF3aW5kb3cuX19w
ZW5kaW5nSnVtcElkKSB7CiAgICAgICAgICAgIGNvbnN0IGZyb21MZW4gPSAocHJldkl0ZW1zICYmIHBy
ZXZJdGVtcy5sZW5ndGgpID8gcHJldkl0ZW1zLmxlbmd0aCA6IDA7CiAgICAgICAgICAgIGlmICghX3Bl
bmRpbmdBcHBlbmQpCiAgICAgICAgICAgICAgICBfcGVuZGluZ0FwcGVuZCA9IHsgZnJvbUxlbjogZnJv
bUxlbiB9OwogICAgICAgICAgICB0cnkgeyByZWZyZXNoTGlzdENocm9tZSgpOyB9IGNhdGNoIHt9CiAg
ICAgICAgICAgIHJldHVybjsKICAgICAgICB9CgogICAgICAgIGNvbnN0IHdhc0Jvb3RMb2FkaW5nID0g
Ym9vdExvYWRpbmc7CiAgICAgICAgbGV0IHNhbWVQYWludCA9IGZhbHNlOwogICAgICAgIGNvbnN0IHBy
ZXZMZW4gPSAocHJldkl0ZW1zICYmIHByZXZJdGVtcy5sZW5ndGgpID8gcHJldkl0ZW1zLmxlbmd0aCA6
IDA7CiAgICAgICAgaWYgKCF3YXNBcHBlbmQgJiYgIXdhc0Jvb3RMb2FkaW5nICYmIHByZXZJdGVtcyAm
JiBwcmV2SXRlbXMubGVuZ3RoID09PSBhbGxDbGlwcy5sZW5ndGggJiYgcHJldkl0ZW1zLmxlbmd0aCkg
ewogICAgICAgICAgICBzYW1lUGFpbnQgPSB0cnVlOwogICAgICAgICAgICBmb3IgKGxldCBpID0gMDsg
aSA8IGFsbENsaXBzLmxlbmd0aDsgaSsrKSB7CiAgICAgICAgICAgICAgICBpZiAoK3ByZXZJdGVtc1tp
XS5pZCAhPT0gK2FsbENsaXBzW2ldLmlkKSB7IHNhbWVQYWludCA9IGZhbHNlOyBicmVhazsgfQogICAg
ICAgICAgICB9CiAgICAgICAgICAgIGlmIChzYW1lUGFpbnQgJiYgIWxpc3RFbC5xdWVyeVNlbGVjdG9y
KCcuaXRtJykpIHNhbWVQYWludCA9IGZhbHNlOwogICAgICAgIH0KICAgICAgICBjb25zdCBmaW5pc2hV
cGRhdGUgPSAoKSA9PiB7CiAgICAgICAgICAgIGNvbnN0IHRSZW5kZXIwID0gKHR5cGVvZiBwZXJmb3Jt
YW5jZSAhPT0gJ3VuZGVmaW5lZCcgJiYgcGVyZm9ybWFuY2Uubm93KSA/IHBlcmZvcm1hbmNlLm5vdygp
IDogRGF0ZS5ub3coKTsKICAgICAgICAgICAgY2xlYXJXYWl0aW5nRGF0YSgpOwogICAgICAgICAgICBp
ZiAod2FzQXBwZW5kICYmICF3YXNCb290TG9hZGluZyAmJiBwcmV2TGVuID4gMCAmJiBhbGxDbGlwcy5s
ZW5ndGggPiBwcmV2TGVuKSB7CiAgICAgICAgICAgICAgICBhcHBlbmRSZW5kZXIocHJldkxlbik7CiAg
ICAgICAgICAgIH0gZWxzZSBpZiAoIXNhbWVQYWludCkgewogICAgICAgICAgICAgICAgcmVuZGVyKCk7
CiAgICAgICAgICAgICAgICBhcHBseVRhYlN3aXRjaEFuaW0oKTsKICAgICAgICAgICAgICAgIGlmIChr
ZWVwU2Nyb2xsKQogICAgICAgICAgICAgICAgICAgIGxpc3RFbC5zY3JvbGxUb3AgPSBzdDsKICAgICAg
ICAgICAgICAgIGVsc2UKICAgICAgICAgICAgICAgICAgICBsaXN0RWwuc2Nyb2xsVG9wID0gMDsKICAg
ICAgICAgICAgfSBlbHNlIHsKICAgICAgICAgICAgICAgIHRyeSB7IHJlZnJlc2hMaXN0Q2hyb21lKCk7
IH0gY2F0Y2gge30KICAgICAgICAgICAgICAgIGlmIChrZWVwU2Nyb2xsKQogICAgICAgICAgICAgICAg
ICAgIGxpc3RFbC5zY3JvbGxUb3AgPSBzdDsKICAgICAgICAgICAgfQogICAgICAgICAgICBjb25zdCB0
MSA9ICh0eXBlb2YgcGVyZm9ybWFuY2UgIT09ICd1bmRlZmluZWQnICYmIHBlcmZvcm1hbmNlLm5vdykg
PyBwZXJmb3JtYW5jZS5ub3coKSA6IERhdGUubm93KCk7CiAgICAgICAgICAgIHdpbmRvdy5fX3BlcmZN
YXJrKCdqc191cGRhdGVDbGlwc19kb25lIHJlbmRlck1zPScgKyBNYXRoLnJvdW5kKHQxIC0gdFJlbmRl
cjApICsgJyB0b3RhbE1zPScgKyBNYXRoLnJvdW5kKHQxIC0gdDApICsgJyBuPScgKyBhbGxDbGlwcy5s
ZW5ndGgpOwogICAgICAgIH07CiAgICAgICAgaWYgKHdhc0Jvb3RMb2FkaW5nKSB7CiAgICAgICAgICAg
IGNvbnN0IHNpbmNlID0gd2luZG93Ll9fc2tlbFNpbmNlIHx8IDA7CiAgICAgICAgICAgIGNvbnN0IHdh
aXQgPSBzaW5jZSA/IE1hdGgubWF4KDAsIDgwIC0gKERhdGUubm93KCkgLSBzaW5jZSkpIDogMDsKICAg
ICAgICAgICAgaWYgKHdhaXQgPiAwKQogICAgICAgICAgICAgICAgc2V0VGltZW91dChmaW5pc2hVcGRh
dGUsIHdhaXQpOwogICAgICAgICAgICBlbHNlCiAgICAgICAgICAgICAgICBmaW5pc2hVcGRhdGUoKTsK
ICAgICAgICB9IGVsc2UgewogICAgICAgICAgICBmaW5pc2hVcGRhdGUoKTsKICAgICAgICB9CiAgICB9
OwogICAgd2luZG93Ll9fc2V0UGlubmVkID0gdiA9PiB7CiAgICAgICAgcGlubmVkVUkgPSAhIXY7CiAg
ICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2J0bi1waW4nKS5jbGFzc0xpc3QudG9nZ2xlKCdv
bicsIHBpbm5lZFVJKTsKICAgIH07CiAgICB3aW5kb3cuX19sb2FkTW9yZURvbmUgPSAoKSA9PiB7CiAg
ICAgICAgbG9hZGluZ01vcmUgPSBmYWxzZTsKICAgICAgICBpZiAod2luZG93Ll9fbG9hZE1vcmVXYXRj
aCkgewogICAgICAgICAgICBjbGVhclRpbWVvdXQod2luZG93Ll9fbG9hZE1vcmVXYXRjaCk7CiAgICAg
ICAgICAgIHdpbmRvdy5fX2xvYWRNb3JlV2F0Y2ggPSAwOwogICAgICAgIH0KICAgICAgICBpZiAod2lu
ZG93Ll9fcGVuZGluZ0p1bXBJZCkKICAgICAgICAgICAgdHJ5Q29udGludWVKdW1wKCk7CiAgICB9OwoK
ICAgIGluaXRTZXBVaSgpOwogICAgdXBkYXRlUGluRG90KCk7CiAgICBzY2hlZHVsZURlbGF5ZWRTa2Vs
KCk7CiAgICB3aW5kb3cuX19wZXJmTWFyayAmJiB3aW5kb3cuX19wZXJmTWFyaygnanNfYm9vdCByZXF1
ZXN0VmlldycpOwogICAgcmVxdWVzdFZpZXcoKTsKICAgIC8vIHNjaGVkdWxlRGVsYXllZFNrZWwgYWxy
ZWFkeSByZW5kZXIoKSdkIHdoZW4gZW1wdHk7IHN0aWxsIHBhaW50IG9uY2UgZm9yIGNocm9tZQoKICAg
IDwvc2NyaXB0Pgo8L2JvZHk+CjwvaHRtbD4=
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
