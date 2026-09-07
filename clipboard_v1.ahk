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
UI_CACHE_VER := "20260908-no-skel"
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
fQoKICAgICAgICAjYnRuLXBpbiB7CiAgICAgICAgICAgIGRpc3BsYXk6IG5vbmUgIWltcG9ydGFudDsg
Lyog5bey5byD55So6ZKJ5bGP5YWl5Y+jICovCiAgICAgICAgICAgIHdpZHRoOiAyOHB4OyBoZWlnaHQ6
IDI4cHg7IGZsZXgtc2hyaW5rOiAwOwogICAgICAgICAgICBhbGlnbi1pdGVtczogY2VudGVyOyBqdXN0
aWZ5LWNvbnRlbnQ6IGNlbnRlcjsKICAgICAgICAgICAgYm9yZGVyOiAxLjVweCBzb2xpZCB0cmFuc3Bh
cmVudDsgYmFja2dyb3VuZDogbm9uZTsgY3Vyc29yOiBwb2ludGVyOwogICAgICAgICAgICBjb2xvcjog
dmFyKC0tdHh0Myk7IGJvcmRlci1yYWRpdXM6IHZhcigtLXIpOwogICAgICAgICAgICAtd2Via2l0LWFw
cC1yZWdpb246IG5vLWRyYWc7IGFwcC1yZWdpb246IG5vLWRyYWc7CiAgICAgICAgICAgIHRyYW5zaXRp
b246IGNvbG9yIHZhcigtLXRyKSwgYmFja2dyb3VuZCB2YXIoLS10ciksIGJvcmRlci1jb2xvciB2YXIo
LS10cik7CiAgICAgICAgfQogICAgICAgICNidG4tcGluOmhvdmVyIHsgY29sb3I6IHZhcigtLWFjYyk7
IGJhY2tncm91bmQ6IHJnYmEoOTEsMTE1LDIzMiwuMSk7IH0KICAgICAgICAjYnRuLXBpbi5vbiAgewog
ICAgICAgICAgICBjb2xvcjogdmFyKC0tYWNjKTsKICAgICAgICAgICAgYmFja2dyb3VuZDogcmdiYSg5
MSwxMTUsMjMyLC4xOCk7CiAgICAgICAgICAgIGJvcmRlci1jb2xvcjogcmdiYSg5MSwxMTUsMjMyLC41
NSk7CiAgICAgICAgfQogICAgICAgICNidG4tcGluIHN2ZyB7IHdpZHRoOiAxNHB4OyBoZWlnaHQ6IDE0
cHg7IGRpc3BsYXk6IGJsb2NrOyB9CgogICAgICAgICNidG4tbG9jYXRlIHsKICAgICAgICAgICAgd2lk
dGg6IDI4cHg7IGhlaWdodDogMjhweDsgZmxleC1zaHJpbms6IDA7CiAgICAgICAgICAgIGRpc3BsYXk6
IGZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGp1c3RpZnktY29udGVudDogY2VudGVyOwogICAgICAg
ICAgICBib3JkZXI6IG5vbmU7IGJhY2tncm91bmQ6IG5vbmU7IGN1cnNvcjogcG9pbnRlcjsKICAgICAg
ICAgICAgY29sb3I6IHZhcigtLXR4dDMpOyBib3JkZXItcmFkaXVzOiB2YXIoLS1yKTsKICAgICAgICAg
ICAgLXdlYmtpdC1hcHAtcmVnaW9uOiBuby1kcmFnOyBhcHAtcmVnaW9uOiBuby1kcmFnOwogICAgICAg
ICAgICB0cmFuc2l0aW9uOiBjb2xvciB2YXIoLS10ciksIGJhY2tncm91bmQgdmFyKC0tdHIpLCBvcGFj
aXR5IHZhcigtLXRyKTsKICAgICAgICB9CiAgICAgICAgI2J0bi1sb2NhdGU6aG92ZXI6bm90KDpkaXNh
YmxlZCkgeyBjb2xvcjogdmFyKC0tYWNjKTsgYmFja2dyb3VuZDogcmdiYSg5MSwxMTUsMjMyLC4xKTsg
fQogICAgICAgICNidG4tbG9jYXRlOmRpc2FibGVkIHsgb3BhY2l0eTogLjM1OyBjdXJzb3I6IGRlZmF1
bHQ7IH0KICAgICAgICAjYnRuLWxvY2F0ZS5oYXMtdGFyZ2V0IHsgY29sb3I6IHZhcigtLWFjYyk7IH0K
ICAgICAgICAjYnRuLWxvY2F0ZS5vbiB7CiAgICAgICAgICAgIGNvbG9yOiB2YXIoLS1hY2MpOwogICAg
ICAgICAgICBiYWNrZ3JvdW5kOiByZ2JhKDkxLDExNSwyMzIsLjE4KTsKICAgICAgICB9CiAgICAgICAg
I2J0bi1sb2NhdGUgc3ZnIHsgd2lkdGg6IDE1cHg7IGhlaWdodDogMTVweDsgZGlzcGxheTogYmxvY2s7
IH0KICAgICAgICAjaGRyOmhhcygjc2VhcmNoLXdyYXAub3BlbikgI2J0bi1sb2NhdGUgewogICAgICAg
ICAgICBkaXNwbGF5OiBub25lOwogICAgICAgIH0KCiAgICAgICAgLyog4pSA4pSAIFJvdyAyIOKUgOKU
gOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKU
gOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgCAqLwogICAg
ICAgICN0YWJzIHsKICAgICAgICAgICAgcG9zaXRpb246IHJlbGF0aXZlOwogICAgICAgICAgICBkaXNw
bGF5OiBmbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBnYXA6IDJweDsgZmxleC13cmFwOiBub3dyYXA7
CiAgICAgICAgICAgIHBhZGRpbmc6IDVweCA2cHggNXB4IDhweDsgZmxleC1zaHJpbms6IDA7CiAgICAg
ICAgICAgIGJhY2tncm91bmQ6ICNmMmY0Zjk7CiAgICAgICAgICAgIG1pbi13aWR0aDogMDsKICAgICAg
ICB9CiAgICAgICAgI3RhYi1pbmsgewogICAgICAgICAgICBwb3NpdGlvbjogYWJzb2x1dGU7CiAgICAg
ICAgICAgIGxlZnQ6IDA7IHRvcDogMDsKICAgICAgICAgICAgaGVpZ2h0OiAyMnB4OwogICAgICAgICAg
ICBib3JkZXItcmFkaXVzOiA5OTlweDsKICAgICAgICAgICAgYmFja2dyb3VuZDogI2ZmZjsKICAgICAg
ICAgICAgYm94LXNoYWRvdzogMCAxcHggM3B4IHJnYmEoMCwwLDAsLjA3KSwgMCAwIDAgMXB4IHJnYmEo
OTEsMTE1LDIzMiwuMDYpOwogICAgICAgICAgICBwb2ludGVyLWV2ZW50czogbm9uZTsKICAgICAgICAg
ICAgei1pbmRleDogMDsKICAgICAgICAgICAgdHJhbnNmb3JtOiB0cmFuc2xhdGUzZCgwLDAsMCkgc2Nh
bGVYKDEpOwogICAgICAgICAgICB0cmFuc2Zvcm0tb3JpZ2luOiBjZW50ZXIgYm90dG9tOwogICAgICAg
ICAgICB0cmFuc2l0aW9uOgogICAgICAgICAgICAgICAgdHJhbnNmb3JtIDAuMzRzIGN1YmljLWJlemll
cigwLjIyLCAxLjE4LCAwLjMyLCAxKSwKICAgICAgICAgICAgICAgIGhlaWdodCAwLjI0cyBlYXNlOwog
ICAgICAgICAgICB3aWxsLWNoYW5nZTogdHJhbnNmb3JtLCBoZWlnaHQ7CiAgICAgICAgfQogICAgICAg
ICN0YWItaW5rLnNxdWFzaCB7CiAgICAgICAgICAgIHRyYW5zaXRpb246CiAgICAgICAgICAgICAgICB0
cmFuc2Zvcm0gMC4zMHMgY3ViaWMtYmV6aWVyKDAuMzQsIDEuMjgsIDAuNDQsIDEpLAogICAgICAgICAg
ICAgICAgaGVpZ2h0IDAuMjBzIGVhc2U7CiAgICAgICAgfQogICAgICAgIC50YWIgewogICAgICAgICAg
ICBwb3NpdGlvbjogcmVsYXRpdmU7CiAgICAgICAgICAgIHotaW5kZXg6IDE7CiAgICAgICAgICAgIHBh
ZGRpbmc6IDNweCA5cHg7IGZvbnQtc2l6ZTogMTFweDsgY29sb3I6IHZhcigtLXR4dDIpOyBjdXJzb3I6
IHBvaW50ZXI7CiAgICAgICAgICAgIGJvcmRlci1yYWRpdXM6IDk5OXB4OyB3aGl0ZS1zcGFjZTogbm93
cmFwOwogICAgICAgICAgICBiYWNrZ3JvdW5kOiB0cmFuc3BhcmVudDsKICAgICAgICAgICAgZmxleDog
MCAwIGF1dG87CiAgICAgICAgICAgIHRyYW5zaXRpb246IGNvbG9yIDAuMjhzIGN1YmljLWJlemllcigw
LjIyLCAxLCAwLjM2LCAxKSwKICAgICAgICAgICAgICAgICAgICAgICAgdHJhbnNmb3JtIDAuMjhzIGN1
YmljLWJlemllcigwLjIyLCAxLCAwLjM2LCAxKTsKICAgICAgICAgICAgLXdlYmtpdC1hcHAtcmVnaW9u
OiBuby1kcmFnOyBhcHAtcmVnaW9uOiBuby1kcmFnOwogICAgICAgIH0KICAgICAgICAudGFiOmhvdmVy
IHsgY29sb3I6IHZhcigtLXR4dCk7IGJhY2tncm91bmQ6IHRyYW5zcGFyZW50OyB9CiAgICAgICAgLnRh
YjphY3RpdmUgeyB0cmFuc2Zvcm06IHNjYWxlKDAuOTYpOyB9CiAgICAgICAgLnRhYi5vbiB7IGNvbG9y
OiB2YXIoLS1hY2MpOyBiYWNrZ3JvdW5kOiB0cmFuc3BhcmVudDsgYm94LXNoYWRvdzogbm9uZTsgZm9u
dC13ZWlnaHQ6IDYwMDsgfQogICAgICAgIC5iYWRnZSB7CiAgICAgICAgICAgIGRpc3BsYXk6IGlubGlu
ZS1mbGV4OyBtaW4td2lkdGg6IDEzcHg7IGhlaWdodDogMTNweDsgcGFkZGluZzogMCAycHg7CiAgICAg
ICAgICAgIGFsaWduLWl0ZW1zOiBjZW50ZXI7IGp1c3RpZnktY29udGVudDogY2VudGVyOwogICAgICAg
ICAgICBiYWNrZ3JvdW5kOiB2YXIoLS1hY2MpOyBjb2xvcjogI2ZmZjsgZm9udC1zaXplOiA5cHg7IGJv
cmRlci1yYWRpdXM6IDdweDsgZm9udC13ZWlnaHQ6IDcwMDsKICAgICAgICAgICAgbWFyZ2luLWxlZnQ6
IDFweDsKICAgICAgICB9CiAgICAgICAgI3RhYi1hY3Rpb25zIHsKICAgICAgICAgICAgbWFyZ2luLWxl
ZnQ6IGF1dG87IGRpc3BsYXk6IGZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGdhcDogM3B4OwogICAg
ICAgICAgICBjb2xvcjogdmFyKC0tdHh0Myk7IGZvbnQtc2l6ZTogMTBweDsKICAgICAgICAgICAgZmxl
eDogMCAwIGF1dG87CiAgICAgICAgICAgIG1pbi13aWR0aDogMDsKICAgICAgICAgICAgLXdlYmtpdC1h
cHAtcmVnaW9uOiBuby1kcmFnOyBhcHAtcmVnaW9uOiBuby1kcmFnOwogICAgICAgIH0KICAgICAgICAj
YmFyLXR4dCB7IHdoaXRlLXNwYWNlOiBub3dyYXA7IGZvbnQtc2l6ZTogMTBweDsgbWF4LXdpZHRoOiA4
LjVlbTsgb3ZlcmZsb3c6IGhpZGRlbjsgdGV4dC1vdmVyZmxvdzogZWxsaXBzaXM7IH0KICAgICAgICAj
YnRuLWNsciB7CiAgICAgICAgICAgIGRpc3BsYXk6IGZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGp1
c3RpZnktY29udGVudDogY2VudGVyOwogICAgICAgICAgICB3aWR0aDogMjZweDsgaGVpZ2h0OiAyNnB4
OyBib3JkZXI6IG5vbmU7IGJhY2tncm91bmQ6IG5vbmU7IGNvbG9yOiB2YXIoLS10eHQzKTsKICAgICAg
ICAgICAgY3Vyc29yOiBwb2ludGVyOyBib3JkZXItcmFkaXVzOiB2YXIoLS1yKTsKICAgICAgICAgICAg
LXdlYmtpdC1hcHAtcmVnaW9uOiBuby1kcmFnOyBhcHAtcmVnaW9uOiBuby1kcmFnOwogICAgICAgICAg
ICB0cmFuc2l0aW9uOiBjb2xvciB2YXIoLS10ciksIGJhY2tncm91bmQgdmFyKC0tdHIpOwogICAgICAg
IH0KICAgICAgICAjYnRuLWNscjpob3ZlciB7IGNvbG9yOiAjZmY3YjljOyBiYWNrZ3JvdW5kOiByZ2Jh
KDI1NSwxMjMsMTU2LC4wOCk7IH0KICAgICAgICAjYnRuLWNsciBzdmcgeyB3aWR0aDogMTRweDsgaGVp
Z2h0OiAxNHB4OyBkaXNwbGF5OiBibG9jazsgfQoKICAgICAgICAvKiDilIDilIAgTGlzdCDilIDilIDi
lIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDi
lIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIAgKi8KICAg
ICAgICAjbGlzdCB7CiAgICAgICAgICAgIGZsZXg6IDE7IG92ZXJmbG93LXk6IGF1dG87IG92ZXJmbG93
LXg6IGhpZGRlbjsgcGFkZGluZzogNnB4IDhweCA2cHggMTBweDsgY3Vyc29yOiBkZWZhdWx0OwogICAg
ICAgICAgICAvKiBNVVNUIGJlIG5vLWRyYWc6IGRyYWcgcmVnaW9uIG9uIHRoZSBzY3JvbGxlciBtYWtl
cyBXZWJWaWV3MiBzY3JvbGxiYXIvd2hlZWwgaGl0Y2ggKi8KICAgICAgICAgICAgLXdlYmtpdC1hcHAt
cmVnaW9uOiBuby1kcmFnOyBhcHAtcmVnaW9uOiBuby1kcmFnOwogICAgICAgICAgICBtaW4taGVpZ2h0
OiAwOwogICAgICAgICAgICBvdmVyZmxvdy1hbmNob3I6IG5vbmU7CiAgICAgICAgfQogICAgICAgIC8q
IFdoaWxlIHNjcm9sbGluZzoga2lsbCBob3ZlciBhbmltYXRpb25zIHRoYXQgY2F1c2UgbGF5b3V0L3Bh
aW50IHRocmFzaCAqLwogICAgICAgICNsaXN0LmlzLXNjcm9sbGluZyAuaXRtIHsKICAgICAgICAgICAg
dHJhbnNpdGlvbjogbm9uZSAhaW1wb3J0YW50OwogICAgICAgIH0KICAgICAgICAjbGlzdC5pcy1zY3Jv
bGxpbmcgLml0bTo6YmVmb3JlLAogICAgICAgICNsaXN0LmlzLXNjcm9sbGluZyAuaXRtOjphZnRlciB7
CiAgICAgICAgICAgIHRyYW5zaXRpb246IG5vbmUgIWltcG9ydGFudDsKICAgICAgICB9CiAgICAgICAg
QGtleWZyYW1lcyB0YWJQYW5lSW5MciB7CiAgICAgICAgICAgIGZyb20geyBvcGFjaXR5OiAwOyB0cmFu
c2Zvcm06IHRyYW5zbGF0ZVgoLTQwcHgpOyB9CiAgICAgICAgICAgIHRvIHsgb3BhY2l0eTogMTsgdHJh
bnNmb3JtOiB0cmFuc2xhdGVYKDApOyB9CiAgICAgICAgfQogICAgICAgIEBrZXlmcmFtZXMgdGFiUGFu
ZUluUmwgewogICAgICAgICAgICBmcm9tIHsgb3BhY2l0eTogMDsgdHJhbnNmb3JtOiB0cmFuc2xhdGVY
KDQwcHgpOyB9CiAgICAgICAgICAgIHRvIHsgb3BhY2l0eTogMTsgdHJhbnNmb3JtOiB0cmFuc2xhdGVY
KDApOyB9CiAgICAgICAgfQogICAgICAgICNsaXN0LnRhYi1pbi1sciB7IGFuaW1hdGlvbjogdGFiUGFu
ZUluTHIgLjM0cyBjdWJpYy1iZXppZXIoLjIyLCAxLCAuMzYsIDEpIGJvdGg7IH0KICAgICAgICAjbGlz
dC50YWItaW4tcmwgeyBhbmltYXRpb246IHRhYlBhbmVJblJsIC4zNHMgY3ViaWMtYmV6aWVyKC4yMiwg
MSwgLjM2LCAxKSBib3RoOyB9CiAgICAgICAgI2J0bi10b3AgewogICAgICAgICAgICBwb3NpdGlvbjog
YWJzb2x1dGU7IHJpZ2h0OiAxMHB4OyBib3R0b206IDEwcHg7IHotaW5kZXg6IDIwOwogICAgICAgICAg
ICB3aWR0aDogMjhweDsgaGVpZ2h0OiAyOHB4OyBib3JkZXI6IG5vbmU7IGJvcmRlci1yYWRpdXM6IDUw
JTsKICAgICAgICAgICAgZGlzcGxheTogbm9uZTsgYWxpZ24taXRlbXM6IGNlbnRlcjsganVzdGlmeS1j
b250ZW50OiBjZW50ZXI7CiAgICAgICAgICAgIGJhY2tncm91bmQ6ICNmZmY7IGNvbG9yOiB2YXIoLS10
eHQyKTsKICAgICAgICAgICAgYm94LXNoYWRvdzogMCAycHggOHB4IHJnYmEoMjQsMzIsNTYsLjE2KTsK
ICAgICAgICAgICAgY3Vyc29yOiBwb2ludGVyOwogICAgICAgICAgICAtd2Via2l0LWFwcC1yZWdpb246
IG5vLWRyYWc7IGFwcC1yZWdpb246IG5vLWRyYWc7CiAgICAgICAgICAgIHRyYW5zaXRpb246IGJhY2tn
cm91bmQgdmFyKC0tdHIpLCBjb2xvciB2YXIoLS10ciksIGJveC1zaGFkb3cgdmFyKC0tdHIpOwogICAg
ICAgIH0KICAgICAgICAjYnRuLXRvcC5vbiB7IGRpc3BsYXk6IGZsZXg7IH0KICAgICAgICAjYnRuLXRv
cDpob3ZlciB7IGNvbG9yOiB2YXIoLS1hY2MpOyBiYWNrZ3JvdW5kOiAjZWRmMWZmOyBib3gtc2hhZG93
OiAwIDNweCAxMHB4IHJnYmEoOTEsMTE1LDIzMiwuMjUpOyB9CiAgICAgICAgI2J0bi10b3Agc3ZnIHsg
d2lkdGg6IDE0cHg7IGhlaWdodDogMTRweDsgZGlzcGxheTogYmxvY2s7IH0KICAgICAgICAjZW1wdHkg
ewogICAgICAgICAgICBkaXNwbGF5OiBub25lOyBmbGV4LWRpcmVjdGlvbjogY29sdW1uOyBhbGlnbi1p
dGVtczogY2VudGVyOyBqdXN0aWZ5LWNvbnRlbnQ6IGNlbnRlcjsKICAgICAgICAgICAgcGFkZGluZzog
NDhweCAxNnB4OyBjb2xvcjogdmFyKC0tdHh0Myk7IGdhcDogOHB4OwogICAgICAgICAgICAtd2Via2l0
LWFwcC1yZWdpb246IGRyYWc7IGFwcC1yZWdpb246IGRyYWc7CiAgICAgICAgfQogICAgICAgICNlbXB0
eS5vbiB7IGRpc3BsYXk6IGZsZXg7IH0KICAgICAgICAuZS10eHQgeyBmb250LXNpemU6IDEycHg7IHRl
eHQtYWxpZ246IGNlbnRlcjsgbGV0dGVyLXNwYWNpbmc6IC4wMmVtOyB9CiAgICAgICAgI3NrZWwgewog
ICAgICAgICAgICBkaXNwbGF5OiBub25lICFpbXBvcnRhbnQ7IC8qIOenkuW8gOWQjuS4jeWGjeWxleek
uumqqOaetuWKqOeUuyAqLwogICAgICAgIH0KICAgICAgICAjc2tlbC5vbiB7IGRpc3BsYXk6IG5vbmUg
IWltcG9ydGFudDsgfQogICAgICAgICNhcHAuYm9vdC1sb2FkaW5nICNza2VsIHsKICAgICAgICAgICAg
ZGlzcGxheTogbm9uZSAhaW1wb3J0YW50OwogICAgICAgIH0KICAgICAgICAjYXBwLmJvb3QtbG9hZGlu
ZyAjZW1wdHkgewogICAgICAgICAgICBkaXNwbGF5OiBub25lICFpbXBvcnRhbnQ7CiAgICAgICAgfQog
ICAgICAgIC5zay1yb3cgewogICAgICAgICAgICBkaXNwbGF5OiBmbGV4OyBhbGlnbi1pdGVtczogZmxl
eC1zdGFydDsgZ2FwOiAxMHB4OwogICAgICAgICAgICBwYWRkaW5nOiAxMHB4IDhweDsgYm9yZGVyLXJh
ZGl1czogOHB4OwogICAgICAgICAgICBiYWNrZ3JvdW5kOiByZ2JhKDI1NSwyNTUsMjU1LC43Mik7CiAg
ICAgICAgICAgIGJvcmRlcjogMXB4IHNvbGlkIHJnYmEoMTcwLDE4MCwyMDAsLjQ1KTsKICAgICAgICAg
ICAgcG9zaXRpb246IHJlbGF0aXZlOwogICAgICAgICAgICBvdmVyZmxvdzogaGlkZGVuOwogICAgICAg
IH0KICAgICAgICAuc2stcm93OjphZnRlciB7CiAgICAgICAgICAgIGNvbnRlbnQ6ICcnOwogICAgICAg
ICAgICBwb3NpdGlvbjogYWJzb2x1dGU7CiAgICAgICAgICAgIGluc2V0OiAwOwogICAgICAgICAgICBi
YWNrZ3JvdW5kOiBsaW5lYXItZ3JhZGllbnQoOTBkZWcsIHRyYW5zcGFyZW50IDAlLCByZ2JhKDI1NSwy
NTUsMjU1LC43MikgNDglLCB0cmFuc3BhcmVudCAxMDAlKTsKICAgICAgICAgICAgdHJhbnNmb3JtOiB0
cmFuc2xhdGVYKC0xMjAlKTsKICAgICAgICAgICAgYW5pbWF0aW9uOiBzay1zd2VlcCAwLjk1cyBlYXNl
LWluLW91dCBpbmZpbml0ZTsKICAgICAgICAgICAgcG9pbnRlci1ldmVudHM6IG5vbmU7CiAgICAgICAg
fQogICAgICAgIEBrZXlmcmFtZXMgc2stc3dlZXAgewogICAgICAgICAgICAxMDAlIHsgdHJhbnNmb3Jt
OiB0cmFuc2xhdGVYKDEyMCUpOyB9CiAgICAgICAgfQogICAgICAgIC5zay1pY28sIC5zay1saW5lIHsK
ICAgICAgICAgICAgYmFja2dyb3VuZDogbGluZWFyLWdyYWRpZW50KDkwZGVnLCAjYjhjMmQ4IDAlLCAj
ZjBmNGZhIDM4JSwgI2RjZTNmMCA1MiUsICNiOGMyZDggMTAwJSk7CiAgICAgICAgICAgIGJhY2tncm91
bmQtc2l6ZTogMjQwJSAxMDAlOwogICAgICAgICAgICBhbmltYXRpb246IHNrLXNoaW1tZXIgMC43MnMg
ZWFzZS1pbi1vdXQgaW5maW5pdGU7CiAgICAgICAgICAgIHdpbGwtY2hhbmdlOiBiYWNrZ3JvdW5kLXBv
c2l0aW9uOwogICAgICAgICAgICBib3JkZXItcmFkaXVzOiA2cHg7CiAgICAgICAgfQogICAgICAgIC5z
ay1pY28geyB3aWR0aDogMzRweDsgaGVpZ2h0OiAzNHB4OyBmbGV4LXNocmluazogMDsgYm9yZGVyLXJh
ZGl1czogOHB4OyB9CiAgICAgICAgLnNrLWJvZHkgeyBmbGV4OiAxOyBtaW4td2lkdGg6IDA7IGRpc3Bs
YXk6IGZsZXg7IGZsZXgtZGlyZWN0aW9uOiBjb2x1bW47IGdhcDogOHB4OyBwYWRkaW5nLXRvcDogMnB4
OyB9CiAgICAgICAgLnNrLWxpbmUgeyBoZWlnaHQ6IDEwcHg7IHdpZHRoOiAxMDAlOyB9CiAgICAgICAg
LnNrLWxpbmUuc2hvcnQgeyB3aWR0aDogNDIlOyB9CiAgICAgICAgLnNrLWxpbmUubWlkIHsgd2lkdGg6
IDY4JTsgfQogICAgICAgIC5zay1yb3c6bnRoLWNoaWxkKDIpOjphZnRlciB7IGFuaW1hdGlvbi1kZWxh
eTogLjEyczsgfQogICAgICAgIC5zay1yb3c6bnRoLWNoaWxkKDMpOjphZnRlciB7IGFuaW1hdGlvbi1k
ZWxheTogLjI0czsgfQogICAgICAgIC5zay1yb3c6bnRoLWNoaWxkKDQpOjphZnRlciB7IGFuaW1hdGlv
bi1kZWxheTogLjM2czsgfQogICAgICAgIC5zay1yb3c6bnRoLWNoaWxkKDUpOjphZnRlciB7IGFuaW1h
dGlvbi1kZWxheTogLjQ4czsgfQogICAgICAgIC5zay1yb3c6bnRoLWNoaWxkKDYpOjphZnRlciB7IGFu
aW1hdGlvbi1kZWxheTogLjZzOyB9CiAgICAgICAgQGtleWZyYW1lcyBzay1zaGltbWVyIHsKICAgICAg
ICAgICAgMCUgeyBiYWNrZ3JvdW5kLXBvc2l0aW9uOiAxMDAlIDA7IH0KICAgICAgICAgICAgMTAwJSB7
IGJhY2tncm91bmQtcG9zaXRpb246IC0xMDAlIDA7IH0KICAgICAgICB9CiAgICAgICAgLmxpc3QtbW9y
ZSB7CiAgICAgICAgICAgIHRleHQtYWxpZ246IGNlbnRlcjsgcGFkZGluZzogMTBweCA4cHggMTRweDsg
Zm9udC1zaXplOiAxMXB4OwogICAgICAgICAgICBjb2xvcjogdmFyKC0tdHh0Myk7IC13ZWJraXQtYXBw
LXJlZ2lvbjogbm8tZHJhZzsgYXBwLXJlZ2lvbjogbm8tZHJhZzsKICAgICAgICB9CiAgICAgICAgLmxp
c3QtbW9yZS5kb25lIHsgZGlzcGxheTogbm9uZTsgfQoKICAgICAgICAuaXRtIHsKICAgICAgICAgICAg
ZGlzcGxheTogZmxleDsgYWxpZ24taXRlbXM6IGZsZXgtc3RhcnQ7IGdhcDogOHB4OwogICAgICAgICAg
ICBwYWRkaW5nOiA4cHg7IG1hcmdpbi1ib3R0b206IDVweDsKICAgICAgICAgICAgYmFja2dyb3VuZDog
dmFyKC0tY2FyZCk7IGJvcmRlci1yYWRpdXM6IHZhcigtLXIpOyBjdXJzb3I6IHBvaW50ZXI7CiAgICAg
ICAgICAgIGJveC1zaGFkb3c6IDAgMXB4IDNweCByZ2JhKDI0LDMyLDU2LC4wNik7CiAgICAgICAgICAg
IC8qIGhvdmVyLWxpbmUgKi8KICAgICAgICAgICAgcG9zaXRpb246IHJlbGF0aXZlOwogICAgICAgICAg
ICB0cmFuc2l0aW9uOiBiYWNrZ3JvdW5kIC4ycyBlYXNlLCBib3gtc2hhZG93IC4ycyBlYXNlOwogICAg
ICAgICAgICAtd2Via2l0LWFwcC1yZWdpb246IG5vLWRyYWc7IGFwcC1yZWdpb246IG5vLWRyYWc7CiAg
ICAgICAgICAgIG92ZXJmbG93OiB2aXNpYmxlOwogICAgICAgIH0KICAgICAgICAuaXRtOjpiZWZvcmUg
ewogICAgICAgICAgICBjb250ZW50OiAiIjsKICAgICAgICAgICAgcG9zaXRpb246IGFic29sdXRlOwog
ICAgICAgICAgICBsZWZ0OiAwOyByaWdodDogMDsgYm90dG9tOiAwOwogICAgICAgICAgICBoZWlnaHQ6
IDA7CiAgICAgICAgICAgIHBvaW50ZXItZXZlbnRzOiBub25lOwogICAgICAgICAgICB6LWluZGV4OiAw
OwogICAgICAgICAgICBib3JkZXItcmFkaXVzOiAwIDAgdmFyKC0tcikgdmFyKC0tcik7CiAgICAgICAg
ICAgIGJhY2tncm91bmQ6IGxpbmVhci1ncmFkaWVudCh0byB0b3AsIHJnYmEoOTEsMTE1LDIzMiwuMzIp
LCByZ2JhKDkxLDExNSwyMzIsLjEyKSA1NSUsIHRyYW5zcGFyZW50KTsKICAgICAgICAgICAgdHJhbnNp
dGlvbjogaGVpZ2h0IC4zNHMgY3ViaWMtYmV6aWVyKC4yMiwxLC4zNiwxKTsKICAgICAgICB9CiAgICAg
ICAgLml0bTpob3Zlcjo6YmVmb3JlIHsgaGVpZ2h0OiAzMy4zMzMlOyB9CiAgICAgICAgLml0bTo6YWZ0
ZXIgewogICAgICAgICAgICBjb250ZW50OiAiIjsKICAgICAgICAgICAgcG9zaXRpb246IGFic29sdXRl
OwogICAgICAgICAgICBsZWZ0OiAwOyByaWdodDogMDsgYm90dG9tOiAwOwogICAgICAgICAgICBoZWln
aHQ6IDJweDsKICAgICAgICAgICAgcG9pbnRlci1ldmVudHM6IG5vbmU7CiAgICAgICAgICAgIHotaW5k
ZXg6IDE7CiAgICAgICAgICAgIGJhY2tncm91bmQ6IHJnYmEoOTEsMTE1LDIzMiwuOTUpOwogICAgICAg
ICAgICBib3JkZXItcmFkaXVzOiAxcHg7CiAgICAgICAgICAgIHRyYW5zZm9ybTogc2NhbGVYKDApOwog
ICAgICAgICAgICB0cmFuc2Zvcm0tb3JpZ2luOiBjZW50ZXI7CiAgICAgICAgICAgIHRyYW5zaXRpb246
IHRyYW5zZm9ybSAuM3MgY3ViaWMtYmV6aWVyKC4yMiwxLC4zNiwxKTsKICAgICAgICB9CiAgICAgICAg
Lml0bTpob3ZlciB7CiAgICAgICAgICAgIGJhY2tncm91bmQ6IHZhcigtLWNhcmQtaCk7CiAgICAgICAg
ICAgIGJveC1zaGFkb3c6IDAgMnB4IDhweCByZ2JhKDI0LDMyLDU2LC4xKTsKICAgICAgICB9CiAgICAg
ICAgLml0bTpob3Zlcjo6YWZ0ZXIgewogICAgICAgICAgICB0cmFuc2Zvcm06IHNjYWxlWCgxKTsKICAg
ICAgICB9CiAgICAgICAgLml0bS5zZWwgewogICAgICAgICAgICBib3gtc2hhZG93OiAwIDAgMCAycHgg
cmdiYSg5MSwxMTUsMjMyLC40NSksIDAgMnB4IDhweCByZ2JhKDkxLDExNSwyMzIsLjE4KTsKICAgICAg
ICAgICAgYmFja2dyb3VuZDogI2VkZjFmZjsKICAgICAgICB9CiAgICAgICAgLml0bS5tdWx0aSB7CiAg
ICAgICAgICAgIGJveC1zaGFkb3c6IDAgMCAwIDEuNXB4IHJnYmEoOTEsMTE1LDIzMiwuNTUpLCAwIDJw
eCA2cHggcmdiYSg5MSwxMTUsMjMyLC4xOCk7CiAgICAgICAgICAgIGJhY2tncm91bmQ6ICNlZWYyZmY7
CiAgICAgICAgfQogICAgICAgIC5pdG0ubXVsdGkuc2VsIHsKICAgICAgICAgICAgYm94LXNoYWRvdzog
MCAwIDAgMnB4IHJnYmEoOTEsMTE1LDIzMiwuNyksIDAgMnB4IDhweCByZ2JhKDkxLDExNSwyMzIsLjIy
KTsKICAgICAgICB9CgogICAgICAgICNtdWx0aS1jbnQgewogICAgICAgICAgICBkaXNwbGF5OiBub25l
OyBhbGlnbi1pdGVtczogY2VudGVyOyBqdXN0aWZ5LWNvbnRlbnQ6IGNlbnRlcjsKICAgICAgICAgICAg
aGVpZ2h0OiAyMnB4OyBwYWRkaW5nOiAwIDhweDsgbWFyZ2luLXJpZ2h0OiA0cHg7CiAgICAgICAgICAg
IGJvcmRlcjogbm9uZTsgYm9yZGVyLXJhZGl1czogMTFweDsgY3Vyc29yOiBwb2ludGVyOwogICAgICAg
ICAgICBiYWNrZ3JvdW5kOiB2YXIoLS1hY2MpOyBjb2xvcjogI2ZmZjsgZm9udC1zaXplOiAxMXB4OyBm
b250LXdlaWdodDogNzAwOwogICAgICAgICAgICAtd2Via2l0LWFwcC1yZWdpb246IG5vLWRyYWc7IGFw
cC1yZWdpb246IG5vLWRyYWc7CiAgICAgICAgICAgIHRyYW5zaXRpb246IG9wYWNpdHkgdmFyKC0tdHIp
LCBiYWNrZ3JvdW5kIHZhcigtLXRyKTsKICAgICAgICB9CiAgICAgICAgI211bHRpLWNudDpob3ZlciB7
IGJhY2tncm91bmQ6ICM0YTYyZDQ7IH0KICAgICAgICAjbXVsdGktY250Lm9uIHsgZGlzcGxheTogaW5s
aW5lLWZsZXg7IH0KCiAgICAgICAgLmktaWNvIHsKICAgICAgICAgICAgd2lkdGg6IDI4cHg7IGhlaWdo
dDogMjhweDsgYm9yZGVyLXJhZGl1czogdmFyKC0tcik7IGRpc3BsYXk6IGZsZXg7CiAgICAgICAgICAg
IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGp1c3RpZnktY29udGVudDogY2VudGVyOyBmbGV4LXNocmluazog
MDsKICAgICAgICAgICAgYmFja2dyb3VuZDogI2VkZjJmZjsgY29sb3I6IHZhcigtLWFjYyk7CiAgICAg
ICAgICAgIHBvc2l0aW9uOiByZWxhdGl2ZTsgb3ZlcmZsb3c6IHZpc2libGU7CiAgICAgICAgfQogICAg
ICAgIC5pLWljbyBzdmcgeyB3aWR0aDogMTZweDsgaGVpZ2h0OiAxNnB4OyBkaXNwbGF5OiBibG9jazsg
fQogICAgICAgIC5pLWljby5mdC1pbWcgeyBjb2xvcjogIzdhZDdmZjsgfQogICAgICAgIC5pLWljby5m
dC12aWQgeyBjb2xvcjogI2MwODRmYzsgfQogICAgICAgIC5pLWljby5mdC16aXAgeyBjb2xvcjogIzhh
YjRmZjsgfQogICAgICAgIC5pLWljby5mdC1kaXIgeyBjb2xvcjogI2ZmZDU2YTsgfQogICAgICAgIC5p
LWljby5mdC1haGsgeyBjb2xvcjogIzZkZmY5YTsgfQogICAgICAgIC5pLWljby5tZCB7IGNvbG9yOiAj
NmI4Y2ZmOyB9CiAgICAgICAgLmktaWNvLm1kIHN2ZyB7IHdpZHRoOiAyMHB4OyBoZWlnaHQ6IDIwcHg7
IH0KICAgICAgICAuaS1pY28uZnQtbG5rLCAuaS1pY28uZnQtZG9jIHsgY29sb3I6ICNhOWJkZDA7IH0K
ICAgICAgICAuaS11c2VkIHsKICAgICAgICAgICAgcG9zaXRpb246IGFic29sdXRlOyByaWdodDogMDsg
Ym90dG9tOiAwOwogICAgICAgICAgICB3aWR0aDogMTNweDsgaGVpZ2h0OiAxM3B4OyBib3JkZXItcmFk
aXVzOiA1MCU7CiAgICAgICAgICAgIGJhY2tncm91bmQ6ICMyMmM1NWU7IGJvcmRlcjogMS41cHggc29s
aWQgI2ZmZjsKICAgICAgICAgICAgZGlzcGxheTogZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsganVz
dGlmeS1jb250ZW50OiBjZW50ZXI7CiAgICAgICAgICAgIHBvaW50ZXItZXZlbnRzOiBub25lOyB6LWlu
ZGV4OiAzOwogICAgICAgICAgICBib3gtc2hhZG93OiAwIDFweCAycHggcmdiYSgwLDAsMCwuMTYpOwog
ICAgICAgICAgICB0cmFuc2Zvcm06IHRyYW5zbGF0ZSgzMCUsIDMwJSk7CiAgICAgICAgfQogICAgICAg
IC5pLXVzZWQgc3ZnIHsgd2lkdGg6IDlweDsgaGVpZ2h0OiA5cHg7IGNvbG9yOiAjZmZmOyBkaXNwbGF5
OiBibG9jazsgfQoKICAgICAgICAvKiBQYXN0ZS1xdWV1ZSB2aXN1YWwgY2hhaW46IGdyYXkgPSBpbiBx
dWV1ZTsgZ3JlZW4gPSBkZXF1ZXVlZCAocGFzdGVkKSBjaGFpbiAqLwogICAgICAgIC5pdG0ucS1tZW1i
ZXIgewogICAgICAgICAgICBwYWRkaW5nLWxlZnQ6IDE0cHg7CiAgICAgICAgICAgIC8qIE1VU1Qgb3Zl
cnJpZGUgZ2xvYmFsIC5pdG17b3ZlcmZsb3c6aGlkZGVufSDigJQgb3RoZXJ3aXNlIGJvdHRvbTotTiBy
YWlsCiAgICAgICAgICAgICAgIGlzIGNsaXBwZWQgYW5kIHRoZSBjaGFpbiBsb29rcyDigJzmlq3nur/i
gJ0gYWNyb3NzIHRoZSA1cHggY2FyZCBnYXAgKi8KICAgICAgICAgICAgb3ZlcmZsb3c6IHZpc2libGUg
IWltcG9ydGFudDsKICAgICAgICB9CiAgICAgICAgLml0bS5xLW1lbWJlciAucS1yYWlsIHsKICAgICAg
ICAgICAgcG9zaXRpb246IGFic29sdXRlOwogICAgICAgICAgICBsZWZ0OiA1cHg7CiAgICAgICAgICAg
IHRvcDogMDsKICAgICAgICAgICAgLyogQnJpZGdlIC5pdG0gbWFyZ2luLWJvdHRvbTo1cHggc28gY29u
c2VjdXRpdmUgcmFpbHMgcmVhZCBhcyBvbmUgc3Ryb2tlICovCiAgICAgICAgICAgIGJvdHRvbTogLTVw
eDsKICAgICAgICAgICAgd2lkdGg6IDJweDsKICAgICAgICAgICAgYmFja2dyb3VuZDogIzljYTNhZjsK
ICAgICAgICAgICAgb3BhY2l0eTogLjcyOwogICAgICAgICAgICBwb2ludGVyLWV2ZW50czogbm9uZTsK
ICAgICAgICAgICAgei1pbmRleDogNDsKICAgICAgICB9CiAgICAgICAgLml0bS5xLW1lbWJlci5xLWZp
cnN0IC5xLXJhaWwgeyB0b3A6IDE2cHg7IGJvcmRlci1yYWRpdXM6IDJweCAycHggMCAwOyB9CiAgICAg
ICAgLyogRW5kIGNoYWluIGF0IHRoZSBsYXN0IGRvdCDigJQgZG8gbm90IGhhbmcgaW50byB0aGUgZ2Fw
IGJlbG93ICovCiAgICAgICAgLml0bS5xLW1lbWJlci5xLWxhc3QgLnEtcmFpbCB7CiAgICAgICAgICAg
IGJvdHRvbTogYXV0bzsKICAgICAgICAgICAgaGVpZ2h0OiAyMnB4OwogICAgICAgICAgICBib3JkZXIt
cmFkaXVzOiAwIDAgMnB4IDJweDsKICAgICAgICB9CiAgICAgICAgLml0bS5xLW1lbWJlci5xLWZpcnN0
LnEtbGFzdCAucS1yYWlsLAogICAgICAgIC5pdG0ucS1tZW1iZXIucS1vbmx5IC5xLXJhaWwgeyBkaXNw
bGF5OiBub25lOyB9CiAgICAgICAgLml0bS5xLW1lbWJlciAucS1kb3QgewogICAgICAgICAgICBwb3Np
dGlvbjogYWJzb2x1dGU7CiAgICAgICAgICAgIGxlZnQ6IDJweDsKICAgICAgICAgICAgdG9wOiAxNHB4
OwogICAgICAgICAgICB3aWR0aDogOHB4OwogICAgICAgICAgICBoZWlnaHQ6IDhweDsKICAgICAgICAg
ICAgYm9yZGVyLXJhZGl1czogNTAlOwogICAgICAgICAgICBiYWNrZ3JvdW5kOiAjOWNhM2FmOwogICAg
ICAgICAgICBib3JkZXI6IDEuNXB4IHNvbGlkICNmZmY7CiAgICAgICAgICAgIGJveC1zaGFkb3c6IDAg
MCAwIDFweCByZ2JhKDE1NiwxNjMsMTc1LC40NSk7CiAgICAgICAgICAgIHBvaW50ZXItZXZlbnRzOiBu
b25lOwogICAgICAgICAgICB6LWluZGV4OiA1OwogICAgICAgIH0KICAgICAgICAvKiBEZXF1ZXVlZDog
Z3JlZW4gZG90czsgZ3JlZW4gcmFpbCBmb3IgY29uc2VjdXRpdmUgZG9uZSBydW4gKi8KICAgICAgICAu
aXRtLnEtbWVtYmVyLnEtZG9uZSAucS1kb3QgewogICAgICAgICAgICBiYWNrZ3JvdW5kOiAjMjJjNTVl
OwogICAgICAgICAgICBib3gtc2hhZG93OiAwIDAgMCAxcHggcmdiYSgzNCwxOTcsOTQsLjQpOwogICAg
ICAgIH0KICAgICAgICAuaXRtLnEtbWVtYmVyLnEtZG9uZS1saW5rIC5xLXJhaWwgewogICAgICAgICAg
ICBiYWNrZ3JvdW5kOiAjMjJjNTVlOwogICAgICAgICAgICBvcGFjaXR5OiAuOTI7CiAgICAgICAgfQoK
ICAgICAgICAuaXRtLmp1bXAtZmxhc2ggewogICAgICAgICAgICBib3gtc2hhZG93OiAwIDAgMCAycHgg
cmdiYSg5MSwxMTUsMjMyLC41NSksIDAgMnB4IDEwcHggcmdiYSg5MSwxMTUsMjMyLC4yMik7CiAgICAg
ICAgICAgIGJhY2tncm91bmQ6ICNlOGVkZmY7CiAgICAgICAgICAgIHRyYW5zaXRpb246IGJhY2tncm91
bmQgLjM1cyBlYXNlLCBib3gtc2hhZG93IC4zNXMgZWFzZTsKICAgICAgICB9CgogICAgICAgIC5pLWJv
ZHkgeyBmbGV4OiAxOyBtaW4td2lkdGg6IDA7IGRpc3BsYXk6IGZsZXg7IGZsZXgtZGlyZWN0aW9uOiBj
b2x1bW47IHBvc2l0aW9uOiByZWxhdGl2ZTsgei1pbmRleDogMjsgfQogICAgICAgIC5pLXByZXYsIC5p
LW5hbWUgewogICAgICAgICAgICBmb250LXNpemU6IDEzcHg7IGZvbnQtd2VpZ2h0OiA1MDA7IGNvbG9y
OiB2YXIoLS10eHQpOyB3b3JkLWJyZWFrOiBicmVhay1hbGw7CiAgICAgICAgICAgIHdoaXRlLXNwYWNl
OiBwcmUtd3JhcDsgLyog5pSv5oyB5aSa5paH5Lu2L+WkmuihjOaWh+acrOaNouihjOaYvuekuiAqLwog
ICAgICAgIH0KICAgICAgICAuaS1wcmV2IHsKICAgICAgICAgICAgZGlzcGxheTogLXdlYmtpdC1ib3g7
IC13ZWJraXQtYm94LW9yaWVudDogdmVydGljYWw7IC13ZWJraXQtbGluZS1jbGFtcDogNTsgb3ZlcmZs
b3c6IGhpZGRlbjsKICAgICAgICAgICAgdGV4dC1vdmVyZmxvdzogZWxsaXBzaXM7CiAgICAgICAgfQog
ICAgICAgIC5pLW5hbWUgewogICAgICAgICAgICBkaXNwbGF5OiAtd2Via2l0LWJveDsgLXdlYmtpdC1i
b3gtb3JpZW50OiB2ZXJ0aWNhbDsgLXdlYmtpdC1saW5lLWNsYW1wOiAyOyBvdmVyZmxvdzogaGlkZGVu
OwogICAgICAgIH0KICAgICAgICAvKiBGaWxlIGNsaXAgd2hvc2UgcGF0aChzKSBubyBsb25nZXIgZXhp
c3Qg4oCUIGxpZ2h0IGJvbGQgZ3JheSBzdHJpa2UgKi8KICAgICAgICAuaXRtLmdvbmUgLmktbmFtZSB7
CiAgICAgICAgICAgIGNvbG9yOiAjOWFhMGIwOwogICAgICAgICAgICB0ZXh0LWRlY29yYXRpb246IGxp
bmUtdGhyb3VnaDsKICAgICAgICAgICAgdGV4dC1kZWNvcmF0aW9uLXRoaWNrbmVzczogMnB4OwogICAg
ICAgICAgICB0ZXh0LWRlY29yYXRpb24tY29sb3I6IHJnYmEoMTU0LCAxNjAsIDE3NiwgLjU1KTsKICAg
ICAgICAgICAgdGV4dC1kZWNvcmF0aW9uLXNraXAtaW5rOiBub25lOwogICAgICAgIH0KICAgICAgICAu
aXRtLmdvbmUgLmktaWNvIHsgb3BhY2l0eTogLjU1OyB9CiAgICAgICAgLml0bS5nb25lIC5pLXRodW1i
LXdyYXAgeyBvcGFjaXR5OiAuNTU7IH0KICAgICAgICAuaS1wcmV2LnVybCB7IGNvbG9yOiB2YXIoLS1h
Y2MpOyB9CgogICAgICAgIC5yZi1wYXRoIHsKICAgICAgICAgICAgZGlzcGxheTogZmxleDsgZmxleC13
cmFwOiB3cmFwOyBhbGlnbi1pdGVtczogY2VudGVyOwogICAgICAgICAgICBnYXA6IDA7IHJvdy1nYXA6
IDNweDsKICAgICAgICAgICAgZm9udC1zaXplOiAxM3B4OyBmb250LXdlaWdodDogNjAwOyBjb2xvcjog
dmFyKC0tdHh0KTsKICAgICAgICAgICAgbGluZS1oZWlnaHQ6IDEuNDU7IHdvcmQtYnJlYWs6IGJyZWFr
LXdvcmQ7CiAgICAgICAgICAgIG1heC13aWR0aDogMTAwJTsKICAgICAgICAgICAgd2lkdGg6IGZpdC1j
b250ZW50OwogICAgICAgICAgICBwb3NpdGlvbjogcmVsYXRpdmU7CiAgICAgICAgICAgIHotaW5kZXg6
IDY7CiAgICAgICAgICAgIC13ZWJraXQtYXBwLXJlZ2lvbjogbm8tZHJhZzsgYXBwLXJlZ2lvbjogbm8t
ZHJhZzsKICAgICAgICAgICAgcG9pbnRlci1ldmVudHM6IGF1dG87CiAgICAgICAgfQogICAgICAgIC5y
Zi1zZWcgewogICAgICAgICAgICBjb2xvcjogdmFyKC0tYWNjKTsKICAgICAgICAgICAgY3Vyc29yOiBw
b2ludGVyOwogICAgICAgICAgICBwYWRkaW5nOiAxcHggM3B4OwogICAgICAgICAgICBtYXJnaW46IDA7
CiAgICAgICAgICAgIGJvcmRlcjogbm9uZTsKICAgICAgICAgICAgYmFja2dyb3VuZDogdHJhbnNwYXJl
bnQ7CiAgICAgICAgICAgIGJvcmRlci1yYWRpdXM6IDNweDsKICAgICAgICAgICAgZm9udDogaW5oZXJp
dDsKICAgICAgICAgICAgZm9udC1zaXplOiAxM3B4OwogICAgICAgICAgICBmb250LXdlaWdodDogNjAw
OwogICAgICAgICAgICBsaW5lLWhlaWdodDogMS40NTsKICAgICAgICAgICAgLXdlYmtpdC1hcHAtcmVn
aW9uOiBuby1kcmFnOyBhcHAtcmVnaW9uOiBuby1kcmFnOwogICAgICAgICAgICBwb2ludGVyLWV2ZW50
czogYXV0byAhaW1wb3J0YW50OwogICAgICAgICAgICBwb3NpdGlvbjogcmVsYXRpdmU7CiAgICAgICAg
ICAgIHotaW5kZXg6IDg7CiAgICAgICAgICAgIHRyYW5zaXRpb246IGJhY2tncm91bmQgLjEycyBlYXNl
LCBjb2xvciAuMTJzIGVhc2U7CiAgICAgICAgfQogICAgICAgIC5yZi1zZWc6aG92ZXIgewogICAgICAg
ICAgICBiYWNrZ3JvdW5kOiByZ2JhKDkxLDExNSwyMzIsLjE0KTsKICAgICAgICAgICAgdGV4dC1kZWNv
cmF0aW9uOiB1bmRlcmxpbmU7CiAgICAgICAgfQogICAgICAgIC5yZi1zZXAgewogICAgICAgICAgICBj
b2xvcjogdmFyKC0tdHh0Myk7CiAgICAgICAgICAgIHBhZGRpbmc6IDAgMnB4OwogICAgICAgICAgICBt
YXJnaW46IDA7CiAgICAgICAgICAgIHVzZXItc2VsZWN0OiBub25lOwogICAgICAgICAgICBmbGV4LXNo
cmluazogMDsKICAgICAgICAgICAgb3BhY2l0eTogLjU1OwogICAgICAgICAgICBwb2ludGVyLWV2ZW50
czogbm9uZTsKICAgICAgICAgICAgZm9udC1zaXplOiAxMnB4OwogICAgICAgICAgICBsaW5lLWhlaWdo
dDogMS40NTsKICAgICAgICB9CiAgICAgICAgLml0bS5yZi1maXhlZCAuaS1pY28gewogICAgICAgICAg
ICBib3gtc2hhZG93OiAwIDAgMCAxLjVweCByZ2JhKDkxLDExNSwyMzIsLjQ1KTsKICAgICAgICB9CiAg
ICAgICAgLnJmLXBpbi10YWcgewogICAgICAgICAgICBkaXNwbGF5OiBpbmxpbmUtZmxleDsgYWxpZ24t
aXRlbXM6IGNlbnRlcjsganVzdGlmeS1jb250ZW50OiBjZW50ZXI7CiAgICAgICAgICAgIGZsZXgtc2hy
aW5rOiAwOwogICAgICAgICAgICBoZWlnaHQ6IDE2cHg7IHBhZGRpbmc6IDAgNnB4OyBtYXJnaW4tcmln
aHQ6IDA7CiAgICAgICAgICAgIGJvcmRlci1yYWRpdXM6IDRweDsKICAgICAgICAgICAgZm9udC1zaXpl
OiAxMHB4OyBmb250LXdlaWdodDogNTAwOwogICAgICAgICAgICBjb2xvcjogIzdhODQ5OTsKICAgICAg
ICAgICAgYmFja2dyb3VuZDogcmdiYSgxMjIsMTMyLDE1MywuMTIpOwogICAgICAgICAgICBib3JkZXI6
IDFweCBzb2xpZCByZ2JhKDEyMiwxMzIsMTUzLC4yMik7CiAgICAgICAgICAgIGxldHRlci1zcGFjaW5n
OiAuMDJlbTsKICAgICAgICAgICAgd2hpdGUtc3BhY2U6IG5vd3JhcDsKICAgICAgICAgICAgcG9pbnRl
ci1ldmVudHM6IG5vbmU7CiAgICAgICAgfQogICAgICAgIC5pLXRodW1iLXdyYXAgewogICAgICAgICAg
ICB3aWR0aDogMTAwJTsgbWluLWhlaWdodDogNDhweDsgbWF4LWhlaWdodDogMTgwcHg7IG1hcmdpbi1i
b3R0b206IDRweDsKICAgICAgICAgICAgZGlzcGxheTogZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsg
anVzdGlmeS1jb250ZW50OiBjZW50ZXI7CiAgICAgICAgICAgIGJhY2tncm91bmQ6ICNmM2Y1Zjk7IGJv
cmRlci1yYWRpdXM6IHZhcigtLXIpOyBvdmVyZmxvdzogaGlkZGVuOwogICAgICAgIH0KICAgICAgICAu
aS10aHVtYi13cmFwLndhaXRpbmcgewogICAgICAgICAgICBtaW4taGVpZ2h0OiA4OHB4OwogICAgICAg
ICAgICBiYWNrZ3JvdW5kOiBsaW5lYXItZ3JhZGllbnQoOTBkZWcsICNlOGViZjIgMCUsICNmNGY2ZmEg
NDUlLCAjZThlYmYyIDEwMCUpOwogICAgICAgICAgICBiYWNrZ3JvdW5kLXNpemU6IDIwMCUgMTAwJTsK
ICAgICAgICAgICAgYW5pbWF0aW9uOiB0aHVtYlNoaW1tZXIgMS4wNXMgZWFzZS1pbi1vdXQgaW5maW5p
dGU7CiAgICAgICAgfQogICAgICAgIEBrZXlmcmFtZXMgdGh1bWJTaGltbWVyIHsKICAgICAgICAgICAg
MCUgeyBiYWNrZ3JvdW5kLXBvc2l0aW9uOiAxMDAlIDA7IH0KICAgICAgICAgICAgMTAwJSB7IGJhY2tn
cm91bmQtcG9zaXRpb246IC0xMDAlIDA7IH0KICAgICAgICB9CiAgICAgICAgLmktdGh1bWIgeyBtYXgt
d2lkdGg6IDEwMCU7IG1heC1oZWlnaHQ6IDE4MHB4OyB3aWR0aDogYXV0bzsgaGVpZ2h0OiBhdXRvOyBv
YmplY3QtZml0OiBjb250YWluOyBkaXNwbGF5OiBibG9jazsgfQogICAgICAgIC5pLXRodW1iLnRodW1i
LWxvYWRpbmcgeyBvcGFjaXR5OiAwOyB3aWR0aDogMXB4OyBoZWlnaHQ6IDFweDsgfQoKICAgICAgICAv
KiBNZXRhIGJhcjogdGltZSBsZWZ0IHwgZXhwYW5kIGNlbnRlciB8IHRhZ3MgcmlnaHQgKi8KICAgICAg
ICAuaS1tZXRhIHsKICAgICAgICAgICAgZGlzcGxheTogZ3JpZDsKICAgICAgICAgICAgZ3JpZC10ZW1w
bGF0ZS1jb2x1bW5zOiAxZnIgYXV0byAxZnI7CiAgICAgICAgICAgIGFsaWduLWl0ZW1zOiBjZW50ZXI7
CiAgICAgICAgICAgIGdhcDogNHB4OwogICAgICAgICAgICBtYXJnaW4tdG9wOiA0cHg7CiAgICAgICAg
ICAgIHdpZHRoOiAxMDAlOwogICAgICAgIH0KICAgICAgICAuaS1tZXRhIC5pLXRpbWUgeyBqdXN0aWZ5
LXNlbGY6IHN0YXJ0OyB9CiAgICAgICAgLmktbWV0YS1jZW50ZXIgewogICAgICAgICAgICBqdXN0aWZ5
LXNlbGY6IGNlbnRlcjsKICAgICAgICAgICAgZGlzcGxheTogZmxleDsgYWxpZ24taXRlbXM6IGNlbnRl
cjsganVzdGlmeS1jb250ZW50OiBjZW50ZXI7CiAgICAgICAgICAgIGdhcDogNHB4OwogICAgICAgICAg
ICBtaW4td2lkdGg6IDFweDsgLyoga2VlcCBjZW50ZXIgY29sdW1uIGV2ZW4gd2hlbiBleHBhbmQgaXMg
aGlkZGVuICovCiAgICAgICAgfQogICAgICAgIC5pLW1ldGEtcmlnaHQgewogICAgICAgICAgICBqdXN0
aWZ5LXNlbGY6IGVuZDsKICAgICAgICAgICAgZGlzcGxheTogZmxleDsgYWxpZ24taXRlbXM6IGNlbnRl
cjsgZ2FwOiA1cHg7IGZsZXgtd3JhcDogbm93cmFwOwogICAgICAgICAgICBqdXN0aWZ5LWNvbnRlbnQ6
IGZsZXgtZW5kOwogICAgICAgICAgICBtaW4td2lkdGg6IDA7CiAgICAgICAgfQogICAgICAgIC5pLW1l
dGEtcmlnaHQudGV4dC1tZXRhIHsKICAgICAgICAgICAgZmxleC13cmFwOiBub3dyYXA7CiAgICAgICAg
ICAgIGdhcDogNHB4OwogICAgICAgIH0KICAgICAgICAuaS1zcmMtdGl0bGUgewogICAgICAgICAgICBm
b250LXNpemU6IDEwcHg7CiAgICAgICAgICAgIGNvbG9yOiB2YXIoLS10eHQzKTsKICAgICAgICAgICAg
bWF4LXdpZHRoOiAxMWVtOwogICAgICAgICAgICBvdmVyZmxvdzogaGlkZGVuOwogICAgICAgICAgICB0
ZXh0LW92ZXJmbG93OiBlbGxpcHNpczsKICAgICAgICAgICAgd2hpdGUtc3BhY2U6IG5vd3JhcDsKICAg
ICAgICAgICAgbWluLXdpZHRoOiAwOwogICAgICAgICAgICBsaW5lLWhlaWdodDogMS40OwogICAgICAg
IH0KICAgICAgICAuaS10aW1lLCAuaS10YWcgeyBmb250LXNpemU6IDEwcHg7IGNvbG9yOiB2YXIoLS10
eHQzKTsgfQogICAgICAgIC5pLXRhZyB7CiAgICAgICAgICAgIGJhY2tncm91bmQ6ICNmMWYzZjg7IHBh
ZGRpbmc6IDAgNXB4OyBib3JkZXItcmFkaXVzOiAzcHg7CiAgICAgICAgICAgIHdoaXRlLXNwYWNlOiBu
b3dyYXA7IGZsZXgtc2hyaW5rOiAwOyBsaW5lLWhlaWdodDogMS40OwogICAgICAgIH0KICAgICAgICAu
aS1jaGFycyB7CiAgICAgICAgICAgIGZvbnQtc2l6ZTogMTBweDsgY29sb3I6IHZhcigtLXR4dDMpOwog
ICAgICAgICAgICBiYWNrZ3JvdW5kOiAjZjFmM2Y4OyBwYWRkaW5nOiAwIDVweDsgYm9yZGVyLXJhZGl1
czogM3B4OwogICAgICAgICAgICBmb250LXZhcmlhbnQtbnVtZXJpYzogdGFidWxhci1udW1zOwogICAg
ICAgICAgICB3aGl0ZS1zcGFjZTogbm93cmFwOwogICAgICAgICAgICBkaXNwbGF5OiBpbmxpbmUtZmxl
eDsgYWxpZ24taXRlbXM6IGJhc2VsaW5lOyBnYXA6IDJweDsKICAgICAgICB9CiAgICAgICAgLmktY2hh
cnMgLm4gewogICAgICAgICAgICBkaXNwbGF5OiBpbmxpbmUtYmxvY2s7CiAgICAgICAgICAgIG1pbi13
aWR0aDogNGNoOwogICAgICAgICAgICB0ZXh0LWFsaWduOiByaWdodDsKICAgICAgICAgICAgZm9udC1m
YW1pbHk6ICdDYXNjYWRpYSBNb25vJywgJ0NvbnNvbGFzJywgJ1NhcmFzYSBNb25vIFNDJywgdWktbW9u
b3NwYWNlLCBtb25vc3BhY2U7CiAgICAgICAgICAgIGZvbnQtd2VpZ2h0OiA2MDA7CiAgICAgICAgICAg
IGNvbG9yOiB2YXIoLS10eHQyKTsKICAgICAgICB9CiAgICAgICAgLyogc3JjLXRpdGxlLXRpcCAqLwog
ICAgICAgIC5pLXNyYy1pY28sIC5tZy1zcmMgeyBjdXJzb3I6IHBvaW50ZXI7IH0KICAgICAgICAjc3Jj
LXRpcCB7CiAgICAgICAgICAgIHBvc2l0aW9uOiBmaXhlZDsgei1pbmRleDogOTk5OTk7CiAgICAgICAg
ICAgIG1heC13aWR0aDogbWluKDI4MHB4LCBjYWxjKDEwMHZ3IC0gMTZweCkpOwogICAgICAgICAgICBw
YWRkaW5nOiA2cHggMTBweDsKICAgICAgICAgICAgYm9yZGVyLXJhZGl1czogOHB4OwogICAgICAgICAg
ICBiYWNrZ3JvdW5kOiByZ2JhKDMyLDM2LDQ4LC45Mik7IGNvbG9yOiAjZmZmOwogICAgICAgICAgICBm
b250LXNpemU6IDEycHg7IGxpbmUtaGVpZ2h0OiAxLjM1OwogICAgICAgICAgICBib3gtc2hhZG93OiAw
IDZweCAxOHB4IHJnYmEoMCwwLDAsLjIyKTsKICAgICAgICAgICAgcG9pbnRlci1ldmVudHM6IG5vbmU7
CiAgICAgICAgICAgIG9wYWNpdHk6IDA7IHRyYW5zZm9ybTogdHJhbnNsYXRlWSg0cHgpOwogICAgICAg
ICAgICB0cmFuc2l0aW9uOiBvcGFjaXR5IC4ycyBlYXNlLCB0cmFuc2Zvcm0gLjIycyBjdWJpYy1iZXpp
ZXIoLjIyLDEsLjM2LDEpOwogICAgICAgICAgICB3b3JkLWJyZWFrOiBicmVhay13b3JkOwogICAgICAg
IH0KICAgICAgICAjc3JjLXRpcC5zaG93IHsgb3BhY2l0eTogMTsgdHJhbnNmb3JtOiB0cmFuc2xhdGVZ
KDApOyB9CiAgICAgICAgLmktc3JjLWljbyB7CiAgICAgICAgICAgIHdpZHRoOiAxNHB4OyBoZWlnaHQ6
IDE0cHg7IGZsZXgtc2hyaW5rOiAwOwogICAgICAgICAgICBib3JkZXItcmFkaXVzOiAycHg7IG9iamVj
dC1maXQ6IGNvbnRhaW47CiAgICAgICAgICAgIGRpc3BsYXk6IGJsb2NrOwogICAgICAgIH0KICAgICAg
ICAuaS1udW0gewogICAgICAgICAgICBkaXNwbGF5OiBmbGV4OyBmbGV4LWRpcmVjdGlvbjogY29sdW1u
OyBhbGlnbi1pdGVtczogZmxleC1lbmQ7CiAgICAgICAgICAgIGp1c3RpZnktY29udGVudDogc3BhY2Ut
YmV0d2VlbjsKICAgICAgICAgICAgYWxpZ24tc2VsZjogc3RyZXRjaDsKICAgICAgICAgICAgZm9udC1z
aXplOiAxMHB4OyBjb2xvcjogdmFyKC0tdHh0Myk7IG1pbi13aWR0aDogMTZweDsKICAgICAgICAgICAg
dGV4dC1hbGlnbjogcmlnaHQ7IGZsZXgtc2hyaW5rOiAwOwogICAgICAgICAgICBwYWRkaW5nLXRvcDog
MnB4OwogICAgICAgIH0KICAgICAgICAuaS1udW0gLmktc3JjLWljbyB7IHdpZHRoOiAxNnB4OyBoZWln
aHQ6IDE2cHg7IG1hcmdpbi10b3A6IGF1dG87IH0KCiAgICAgICAgLmktZXhwYW5kLWJ0biB7CiAgICAg
ICAgICAgIGJvcmRlcjogbm9uZTsgYmFja2dyb3VuZDogbm9uZTsgY3Vyc29yOiBwb2ludGVyOwogICAg
ICAgICAgICBjb2xvcjogdmFyKC0tdHh0Myk7IGZvbnQtc2l6ZTogMTJweDsgcGFkZGluZzogM3B4IDEw
cHg7CiAgICAgICAgICAgIGJvcmRlci1yYWRpdXM6IDhweDsgZGlzcGxheTogbm9uZTsgYWxpZ24taXRl
bXM6IGNlbnRlcjsgZ2FwOiA0cHg7CiAgICAgICAgICAgIHRyYW5zaXRpb246IGNvbG9yIHZhcigtLXRy
KSwgYmFja2dyb3VuZCB2YXIoLS10cik7CiAgICAgICAgICAgIC13ZWJraXQtYXBwLXJlZ2lvbjogbm8t
ZHJhZzsgYXBwLXJlZ2lvbjogbm8tZHJhZzsKICAgICAgICAgICAgbGluZS1oZWlnaHQ6IDEuMjsKICAg
ICAgICB9CiAgICAgICAgLmktZXhwYW5kLWJ0biBzdmcgeyB3aWR0aDogMTRweDsgaGVpZ2h0OiAxNHB4
OyBmbGV4LXNocmluazogMDsgfQogICAgICAgIC5pLWV4cGFuZC1idG4ub24geyBkaXNwbGF5OiBpbmxp
bmUtZmxleDsgfQogICAgICAgIC5pLWV4cGFuZC1idG46aG92ZXIgeyBjb2xvcjogdmFyKC0tYWNjKTsg
YmFja2dyb3VuZDogcmdiYSg5MSwxMTUsMjMyLC4wOCk7IH0KICAgICAgICAuaS1wcmV2LmV4cGFuZGVk
LCAuaS1uYW1lLmV4cGFuZGVkIHsKICAgICAgICAgICAgLXdlYmtpdC1saW5lLWNsYW1wOiB1bnNldDsK
ICAgICAgICAgICAgZGlzcGxheTogYmxvY2s7CiAgICAgICAgICAgIG92ZXJmbG93OiBoaWRkZW47CiAg
ICAgICAgICAgIC8qIOmrmOW6pueUsSBKUyDmjInliJfooajlj6/op4bljLrorr7lrprvvJrnuqbljaDm
lbTooajlsJHkuIDooYwgKi8KICAgICAgICB9CiAgICAgICAgLmktc3JjLXRpdGxlIHsgZGlzcGxheTog
bm9uZSAhaW1wb3J0YW50OyB9CiAgICAgICAgLmktZmlsZS1kZXRhaWwgewogICAgICAgICAgICBkaXNw
bGF5OiBub25lOwogICAgICAgICAgICBtYXJnaW4tdG9wOiA0cHg7CiAgICAgICAgICAgIHBhZGRpbmc6
IDA7CiAgICAgICAgICAgIGJhY2tncm91bmQ6IG5vbmU7CiAgICAgICAgICAgIGJvcmRlcjogbm9uZTsK
ICAgICAgICB9CiAgICAgICAgLmktZmlsZS1kZXRhaWwub24geyBkaXNwbGF5OiBibG9jazsgfQogICAg
ICAgIC5mZC1ibG9jayB7CiAgICAgICAgICAgIGRpc3BsYXk6IGZsZXg7IGZsZXgtZGlyZWN0aW9uOiBj
b2x1bW47IGdhcDogNnB4OwogICAgICAgIH0KICAgICAgICAuZmQtYmxvY2sgKyAuZmQtYmxvY2sgeyBt
YXJnaW4tdG9wOiA4cHg7IH0KICAgICAgICAuZmQtcGF0aCB7CiAgICAgICAgICAgIHdpZHRoOiAxMDAl
OwogICAgICAgICAgICBmb250OiA2MDAgMTJweC8xLjU1ICdTZWdvZSBVSSBWYXJpYWJsZSBUZXh0Jywn
U2Vnb2UgVUknLCdNaWNyb3NvZnQgWWFIZWkgVUknLHNhbnMtc2VyaWY7CiAgICAgICAgICAgIGNvbG9y
OiB2YXIoLS10eHQyKTsKICAgICAgICAgICAgbGV0dGVyLXNwYWNpbmc6IC4wMWVtOwogICAgICAgICAg
ICB3b3JkLWJyZWFrOiBicmVhay1hbGw7CiAgICAgICAgICAgIHVzZXItc2VsZWN0OiB0ZXh0OwogICAg
ICAgICAgICAtd2Via2l0LWFwcC1yZWdpb246IG5vLWRyYWc7IGFwcC1yZWdpb246IG5vLWRyYWc7CiAg
ICAgICAgfQogICAgICAgIC5mZC1wYXRoLmxpdmUgeyBjdXJzb3I6IHBvaW50ZXI7IH0KICAgICAgICAu
ZmQtcGF0aC5saXZlOmhvdmVyIHsgY29sb3I6IHZhcigtLWFjYyk7IH0KICAgICAgICAuZmQtcGF0aC5k
ZWFkIHsKICAgICAgICAgICAgY29sb3I6ICM5YWEwYjA7CiAgICAgICAgICAgIHRleHQtZGVjb3JhdGlv
bjogbGluZS10aHJvdWdoOwogICAgICAgICAgICB0ZXh0LWRlY29yYXRpb24tdGhpY2tuZXNzOiAycHg7
CiAgICAgICAgICAgIHRleHQtZGVjb3JhdGlvbi1jb2xvcjogcmdiYSgxNTQsIDE2MCwgMTc2LCAuNTUp
OwogICAgICAgICAgICB0ZXh0LWRlY29yYXRpb24tc2tpcC1pbms6IG5vbmU7CiAgICAgICAgICAgIGN1
cnNvcjogZGVmYXVsdDsKICAgICAgICB9CiAgICAgICAgLmZkLWFjdGlvbnMgewogICAgICAgICAgICBk
aXNwbGF5OiBmbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBqdXN0aWZ5LWNvbnRlbnQ6IGZsZXgtZW5k
OwogICAgICAgICAgICBnYXA6IDhweDsgZmxleC13cmFwOiB3cmFwOwogICAgICAgIH0KICAgICAgICAu
ZmQtYnRuIHsKICAgICAgICAgICAgYm9yZGVyOiBub25lOyBiYWNrZ3JvdW5kOiBub25lOyBjdXJzb3I6
IHBvaW50ZXI7CiAgICAgICAgICAgIGNvbG9yOiB2YXIoLS10eHQzKTsgZm9udC1zaXplOiAxMHB4OyBm
b250LXdlaWdodDogNjAwOwogICAgICAgICAgICBwYWRkaW5nOiAxcHggMnB4OyBkaXNwbGF5OiBpbmxp
bmUtZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsgZ2FwOiAycHg7CiAgICAgICAgICAgIHdoaXRlLXNw
YWNlOiBub3dyYXA7CiAgICAgICAgICAgIC13ZWJraXQtYXBwLXJlZ2lvbjogbm8tZHJhZzsgYXBwLXJl
Z2lvbjogbm8tZHJhZzsKICAgICAgICAgICAgdHJhbnNpdGlvbjogY29sb3IgdmFyKC0tdHIpOwogICAg
ICAgIH0KICAgICAgICAuZmQtYnRuOmhvdmVyIHsgY29sb3I6IHZhcigtLWFjYyk7IH0KICAgICAgICAu
ZmQtYnRuLm9rIHsgY29sb3I6ICMxZjdhNTU7IH0KCiAgICAgICAgLyog4pSA4pSAIENvbnRleHQgbWVu
dSDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDi
lIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIAgKi8KICAgICAgICAjY3R4IHsKICAg
ICAgICAgICAgcG9zaXRpb246IGZpeGVkOyB6LWluZGV4OiA5OTk5OyBtaW4td2lkdGg6IDEzMnB4OyBk
aXNwbGF5OiBub25lOyBwYWRkaW5nOiA0cHg7CiAgICAgICAgICAgIGJhY2tncm91bmQ6ICNmZmY7IGJv
cmRlci1yYWRpdXM6IHZhcigtLXIpOyBib3gtc2hhZG93OiAwIDZweCAxNnB4IHJnYmEoMCwwLDAsLjE0
KTsKICAgICAgICAgICAgLXdlYmtpdC1hcHAtcmVnaW9uOiBuby1kcmFnOyBhcHAtcmVnaW9uOiBuby1k
cmFnOwogICAgICAgIH0KICAgICAgICAjY3R4Lm9uIHsgZGlzcGxheTogYmxvY2s7IH0KICAgICAgICAu
Yy1pdGVtIHsKICAgICAgICAgICAgZGlzcGxheTogZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsgZ2Fw
OiA3cHg7IHBhZGRpbmc6IDZweCA5cHg7CiAgICAgICAgICAgIGJvcmRlci1yYWRpdXM6IHZhcigtLXIp
OyBjdXJzb3I6IHBvaW50ZXI7IGZvbnQtc2l6ZTogMTFweDsgY29sb3I6IHZhcigtLXR4dCk7CiAgICAg
ICAgfQogICAgICAgIC5jLWl0ZW06aG92ZXIgeyBiYWNrZ3JvdW5kOiAjZjJmNGY5OyB9CiAgICAgICAg
LmMtaXRlbS5kYW5nZXIgeyBjb2xvcjogI2ZmN2I5YzsgfQogICAgICAgIC5jLXNlcCB7IGhlaWdodDog
MXB4OyBiYWNrZ3JvdW5kOiAjZWNlZmY1OyBtYXJnaW46IDNweCAwOyB9CiAgICAgICAgLmMtaWNvIHsg
d2lkdGg6IDE0cHg7IHRleHQtYWxpZ246IGNlbnRlcjsgfQoKICAgICAgICAvKiDilIDilIAgQ2xlYXIg
Y29uZmlybSDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDi
lIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIAgKi8KICAgICAgICAjY2xyLWRs
ZyB7CiAgICAgICAgICAgIGRpc3BsYXk6IG5vbmU7IHBvc2l0aW9uOiBmaXhlZDsgaW5zZXQ6IDA7IHot
aW5kZXg6IDEwMDAwOwogICAgICAgICAgICBiYWNrZ3JvdW5kOiByZ2JhKDIwLCAyMiwgMzUsIC40Mik7
CiAgICAgICAgICAgIGFsaWduLWl0ZW1zOiBjZW50ZXI7IGp1c3RpZnktY29udGVudDogY2VudGVyOwog
ICAgICAgICAgICAtd2Via2l0LWFwcC1yZWdpb246IG5vLWRyYWc7IGFwcC1yZWdpb246IG5vLWRyYWc7
CiAgICAgICAgfQogICAgICAgICNjbHItZGxnLm9uIHsgZGlzcGxheTogZmxleDsgfQogICAgICAgIC5j
bHItYm94IHsKICAgICAgICAgICAgd2lkdGg6IG1pbigyODBweCwgY2FsYygxMDAlIC0gMzJweCkpOwog
ICAgICAgICAgICBiYWNrZ3JvdW5kOiAjZmZmOyBib3JkZXItcmFkaXVzOiAxMnB4OwogICAgICAgICAg
ICBib3gtc2hhZG93OiAwIDEycHggMzJweCByZ2JhKDAsMCwwLC4xOCk7CiAgICAgICAgICAgIHBhZGRp
bmc6IDE2cHggMTZweCAxNHB4OyBjb2xvcjogdmFyKC0tdHh0KTsKICAgICAgICB9CiAgICAgICAgLmNs
ci10aXRsZSB7IGZvbnQtc2l6ZTogMTRweDsgZm9udC13ZWlnaHQ6IDcwMDsgbWFyZ2luLWJvdHRvbTog
NnB4OyB9CiAgICAgICAgLmNsci1kZXNjIHsgZm9udC1zaXplOiAxMXB4OyBjb2xvcjogdmFyKC0tdHh0
Myk7IGxpbmUtaGVpZ2h0OiAxLjU7IG1hcmdpbi1ib3R0b206IDEycHg7IH0KICAgICAgICAuY2xyLWNo
ZWNrIHsKICAgICAgICAgICAgZGlzcGxheTogZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsgZ2FwOiA3
cHg7CiAgICAgICAgICAgIGZvbnQtc2l6ZTogMTJweDsgY29sb3I6IHZhcigtLXR4dCk7IGN1cnNvcjog
cG9pbnRlcjsKICAgICAgICAgICAgdXNlci1zZWxlY3Q6IG5vbmU7IG1hcmdpbi1ib3R0b206IDE0cHg7
CiAgICAgICAgfQogICAgICAgIC5jbHItY2hlY2sgaW5wdXQgewogICAgICAgICAgICB3aWR0aDogMTRw
eDsgaGVpZ2h0OiAxNHB4OyBhY2NlbnQtY29sb3I6IHZhcigtLWFjYyk7IGN1cnNvcjogcG9pbnRlcjsK
ICAgICAgICB9CiAgICAgICAgLmNsci1idG5zIHsgZGlzcGxheTogZmxleDsgZ2FwOiA4cHg7IGp1c3Rp
ZnktY29udGVudDogZmxleC1lbmQ7IH0KICAgICAgICAuY2xyLWJ0bnMgYnV0dG9uIHsKICAgICAgICAg
ICAgYm9yZGVyOiBub25lOyBib3JkZXItcmFkaXVzOiA4cHg7IHBhZGRpbmc6IDdweCAxNHB4OwogICAg
ICAgICAgICBmb250LXNpemU6IDEycHg7IGN1cnNvcjogcG9pbnRlcjsgZm9udC13ZWlnaHQ6IDYwMDsK
ICAgICAgICAgICAgdHJhbnNpdGlvbjogYmFja2dyb3VuZCB2YXIoLS10ciksIGNvbG9yIHZhcigtLXRy
KTsKICAgICAgICB9CiAgICAgICAgI2Nsci1jYW5jZWwgeyBiYWNrZ3JvdW5kOiAjZjFmM2Y4OyBjb2xv
cjogdmFyKC0tdHh0Mik7IH0KICAgICAgICAjY2xyLWNhbmNlbDpob3ZlciB7IGJhY2tncm91bmQ6ICNl
NmU5ZjI7IH0KICAgICAgICAjY2xyLW9rIHsgYmFja2dyb3VuZDogcmdiYSgyNTUsMTIzLDE1NiwuMTQp
OyBjb2xvcjogI2U4NWE3YTsgfQogICAgICAgICNjbHItb2s6aG92ZXIgeyBiYWNrZ3JvdW5kOiByZ2Jh
KDI1NSwxMjMsMTU2LC4yNCk7IH0KCiAgICAgICAgLyog4pSA4pSAIEZpbGUgcGF0aCB0aXAg4pSA4pSA
4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA
4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSAICovCiAgICAgICAgI3BhdGgtdGlwIHsKICAgICAgICAg
ICAgZGlzcGxheTogbm9uZTsgcG9zaXRpb246IGZpeGVkOyB6LWluZGV4OiAxMDAwMTsKICAgICAgICAg
ICAgd2lkdGg6IG1pbigzMjBweCwgY2FsYygxMDB2dyAtIDE2cHgpKTsKICAgICAgICAgICAgbWF4LWhl
aWdodDogbWluKDI4MHB4LCBjYWxjKDEwMHZoIC0gMjRweCkpOwogICAgICAgICAgICBvdmVyZmxvdzog
YXV0bzsKICAgICAgICAgICAgcGFkZGluZzogMDsKICAgICAgICAgICAgYmFja2dyb3VuZDogbGluZWFy
LWdyYWRpZW50KDE2NWRlZywgI2ZmZmZmZiAwJSwgI2Y2ZjhmYyAxMDAlKTsKICAgICAgICAgICAgYm9y
ZGVyOiAxcHggc29saWQgcmdiYSg3MCwgODQsIDEyMCwgLjEpOwogICAgICAgICAgICBib3JkZXItcmFk
aXVzOiAxMnB4OwogICAgICAgICAgICBib3gtc2hhZG93OgogICAgICAgICAgICAgICAgMCA0cHggNnB4
IHJnYmEoMzAsIDQwLCA3MCwgLjA0KSwKICAgICAgICAgICAgICAgIDAgMTRweCAzNnB4IHJnYmEoMzAs
IDQwLCA3MCwgLjE2KTsKICAgICAgICAgICAgY29sb3I6IHZhcigtLXR4dCk7CiAgICAgICAgICAgIHBv
aW50ZXItZXZlbnRzOiBhdXRvOwogICAgICAgICAgICBvcGFjaXR5OiAwOwogICAgICAgICAgICB0cmFu
c2Zvcm06IHRyYW5zbGF0ZVkoNHB4KSBzY2FsZSguOTgpOwogICAgICAgICAgICB0cmFuc2l0aW9uOiBv
cGFjaXR5IC4xNHMgZWFzZSwgdHJhbnNmb3JtIC4xNHMgZWFzZTsKICAgICAgICAgICAgLXdlYmtpdC1h
cHAtcmVnaW9uOiBuby1kcmFnOyBhcHAtcmVnaW9uOiBuby1kcmFnOwogICAgICAgIH0KICAgICAgICAj
cGF0aC10aXAub24gewogICAgICAgICAgICBkaXNwbGF5OiBibG9jazsKICAgICAgICAgICAgb3BhY2l0
eTogMTsKICAgICAgICAgICAgdHJhbnNmb3JtOiB0cmFuc2xhdGVZKDApIHNjYWxlKDEpOwogICAgICAg
IH0KICAgICAgICAucHQtaGVhZCB7CiAgICAgICAgICAgIGRpc3BsYXk6IGZsZXg7IGFsaWduLWl0ZW1z
OiBjZW50ZXI7IGp1c3RpZnktY29udGVudDogc3BhY2UtYmV0d2VlbjsKICAgICAgICAgICAgZ2FwOiAx
MHB4OyBwYWRkaW5nOiAxMHB4IDEycHggOHB4OwogICAgICAgICAgICBib3JkZXItYm90dG9tOiAxcHgg
c29saWQgcmdiYSg3MCwgODQsIDEyMCwgLjA3KTsKICAgICAgICB9CiAgICAgICAgLnB0LXRpdGxlIHsK
ICAgICAgICAgICAgZm9udC1zaXplOiAxMXB4OyBmb250LXdlaWdodDogNzAwOyBsZXR0ZXItc3BhY2lu
ZzogLjA0ZW07CiAgICAgICAgICAgIGNvbG9yOiB2YXIoLS10eHQyKTsgdGV4dC10cmFuc2Zvcm06IHVw
cGVyY2FzZTsKICAgICAgICAgICAgZmxleC1zaHJpbms6IDA7CiAgICAgICAgfQogICAgICAgIC5wdC1o
ZWFkLWJ0biB7CiAgICAgICAgICAgIGZsZXgtc2hyaW5rOiAwOyBtYXJnaW4tbGVmdDogYXV0bzsKICAg
ICAgICAgICAgaGVpZ2h0OiAyMnB4OyBwYWRkaW5nOiAwIDhweDsgZGlzcGxheTogaW5saW5lLWZsZXg7
IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGdhcDogNHB4OwogICAgICAgICAgICBib3JkZXI6IDFweCBzb2xp
ZCByZ2JhKDEwNywxMTIsMTI4LC4yMik7IGJvcmRlci1yYWRpdXM6IDZweDsgY3Vyc29yOiBwb2ludGVy
OwogICAgICAgICAgICBiYWNrZ3JvdW5kOiByZ2JhKDEwNywxMTIsMTI4LC4wNik7IGNvbG9yOiAjOGE5
MGEwOyBmb250LXNpemU6IDExcHg7IGZvbnQtd2VpZ2h0OiA2MDA7CiAgICAgICAgICAgIHdoaXRlLXNw
YWNlOiBub3dyYXA7CiAgICAgICAgICAgIC13ZWJraXQtYXBwLXJlZ2lvbjogbm8tZHJhZzsgYXBwLXJl
Z2lvbjogbm8tZHJhZzsKICAgICAgICAgICAgdHJhbnNpdGlvbjogYmFja2dyb3VuZCB2YXIoLS10ciks
IGNvbG9yIHZhcigtLXRyKSwgYm9yZGVyLWNvbG9yIHZhcigtLXRyKTsKICAgICAgICB9CiAgICAgICAg
LnB0LWhlYWQtYnRuOmhvdmVyIHsKICAgICAgICAgICAgYmFja2dyb3VuZDogcmdiYSgxMDcsMTEyLDEy
OCwuMTIpOyBjb2xvcjogdmFyKC0tdHh0Mik7CiAgICAgICAgICAgIGJvcmRlci1jb2xvcjogcmdiYSgx
MDcsMTEyLDEyOCwuNCk7CiAgICAgICAgfQogICAgICAgIC5wdC1saXN0IHsgcGFkZGluZzogNnB4IDhw
eCA4cHg7IGRpc3BsYXk6IGZsZXg7IGZsZXgtZGlyZWN0aW9uOiBjb2x1bW47IGdhcDogNHB4OyB9CiAg
ICAgICAgLnB0LXJvdyB7CiAgICAgICAgICAgIGRpc3BsYXk6IGdyaWQ7IGdyaWQtdGVtcGxhdGUtY29s
dW1uczogOHB4IDFmcjsgZ2FwOiA4cHg7CiAgICAgICAgICAgIHBhZGRpbmc6IDhweCA4cHg7IGJvcmRl
ci1yYWRpdXM6IDhweDsKICAgICAgICAgICAgYmFja2dyb3VuZDogcmdiYSgyNTUsMjU1LDI1NSwuNyk7
CiAgICAgICAgfQogICAgICAgIC5wdC1yb3cuZGVhZCB7IGJhY2tncm91bmQ6IHJnYmEoMjU1LCAxMjMs
IDE1NiwgLjA2KTsgfQogICAgICAgIC5wdC1kb3QgewogICAgICAgICAgICB3aWR0aDogOHB4OyBoZWln
aHQ6IDhweDsgYm9yZGVyLXJhZGl1czogNTAlOyBtYXJnaW4tdG9wOiA1cHg7CiAgICAgICAgICAgIGJh
Y2tncm91bmQ6ICMyZWI0Nzg7IGJveC1zaGFkb3c6IDAgMCAwIDNweCByZ2JhKDQ2LCAxODAsIDEyMCwg
LjE4KTsKICAgICAgICB9CiAgICAgICAgLnB0LXJvdy5kZWFkIC5wdC1kb3QgewogICAgICAgICAgICBi
YWNrZ3JvdW5kOiAjZTg1YTdhOyBib3gtc2hhZG93OiAwIDAgMCAzcHggcmdiYSgyMzIsIDkwLCAxMjIs
IC4xNik7CiAgICAgICAgfQogICAgICAgIC5wdC1uYW1lIHsKICAgICAgICAgICAgZm9udC1zaXplOiAx
MnB4OyBmb250LXdlaWdodDogNjUwOyBjb2xvcjogdmFyKC0tdHh0KTsKICAgICAgICAgICAgbGluZS1o
ZWlnaHQ6IDEuMzsgd29yZC1icmVhazogYnJlYWstYWxsOwogICAgICAgIH0KICAgICAgICAucHQtcGF0
aCB7CiAgICAgICAgICAgIG1hcmdpbi10b3A6IDNweDsKICAgICAgICAgICAgZm9udDogMTAuNXB4LzEu
NDUgJ0Nhc2NhZGlhIE1vbm8nLCdDb25zb2xhcycsJ01pY3Jvc29mdCBZYUhlaSBVSScsbW9ub3NwYWNl
OwogICAgICAgICAgICBjb2xvcjogdmFyKC0tdHh0Mik7IHdvcmQtYnJlYWs6IGJyZWFrLWFsbDsKICAg
ICAgICAgICAgdXNlci1zZWxlY3Q6IHRleHQ7CiAgICAgICAgfQogICAgICAgIC5wdC1wYXRoLmxpdmUg
ewogICAgICAgICAgICBjb2xvcjogdmFyKC0tYWNjKTsgY3Vyc29yOiBwb2ludGVyOwogICAgICAgIH0K
ICAgICAgICAucHQtcGF0aC5saXZlOmhvdmVyIHsgdGV4dC1kZWNvcmF0aW9uOiB1bmRlcmxpbmU7IH0K
ICAgICAgICAucHQtcGF0aC5kZWFkIHsKICAgICAgICAgICAgY29sb3I6ICNjNDNkNWM7CiAgICAgICAg
ICAgIHRleHQtZGVjb3JhdGlvbjogbGluZS10aHJvdWdoOwogICAgICAgICAgICB0ZXh0LWRlY29yYXRp
b24tdGhpY2tuZXNzOiAycHg7CiAgICAgICAgICAgIHRleHQtZGVjb3JhdGlvbi1jb2xvcjogI2UxMWQ0
ODsKICAgICAgICAgICAgY3Vyc29yOiBkZWZhdWx0OwogICAgICAgIH0KICAgICAgICAucHQtYWN0aW9u
cyB7CiAgICAgICAgICAgIG1hcmdpbi10b3A6IDZweDsKICAgICAgICAgICAgZGlzcGxheTogZmxleDsg
YWxpZ24taXRlbXM6IGNlbnRlcjsgZ2FwOiA2cHg7IGZsZXgtd3JhcDogd3JhcDsKICAgICAgICB9CiAg
ICAgICAgLnB0LWNvcHktYnRuIHsKICAgICAgICAgICAgaGVpZ2h0OiAyMnB4OyBwYWRkaW5nOiAwIDhw
eDsgZGlzcGxheTogaW5saW5lLWZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7CiAgICAgICAgICAgIGJv
cmRlcjogMXB4IHNvbGlkIHJnYmEoMTA3LDExMiwxMjgsLjIyKTsgYm9yZGVyLXJhZGl1czogNnB4OyBj
dXJzb3I6IHBvaW50ZXI7CiAgICAgICAgICAgIGJhY2tncm91bmQ6IHJnYmEoMTA3LDExMiwxMjgsLjA2
KTsgY29sb3I6ICM4YTkwYTA7IGZvbnQtc2l6ZTogMTFweDsgZm9udC13ZWlnaHQ6IDYwMDsKICAgICAg
ICAgICAgLXdlYmtpdC1hcHAtcmVnaW9uOiBuby1kcmFnOyBhcHAtcmVnaW9uOiBuby1kcmFnOwogICAg
ICAgICAgICB0cmFuc2l0aW9uOiBiYWNrZ3JvdW5kIHZhcigtLXRyKSwgY29sb3IgdmFyKC0tdHIpLCBi
b3JkZXItY29sb3IgdmFyKC0tdHIpOwogICAgICAgIH0KICAgICAgICAucHQtY29weS1idG46aG92ZXIg
ewogICAgICAgICAgICBiYWNrZ3JvdW5kOiByZ2JhKDEwNywxMTIsMTI4LC4xMik7IGNvbG9yOiB2YXIo
LS10eHQyKTsKICAgICAgICAgICAgYm9yZGVyLWNvbG9yOiByZ2JhKDEwNywxMTIsMTI4LC40KTsKICAg
ICAgICB9CiAgICAgICAgLnB0LWNvcHktYnRuLm9rIHsKICAgICAgICAgICAgY29sb3I6ICMxZjdhNTU7
IGJvcmRlci1jb2xvcjogcmdiYSg0NiwgMTgwLCAxMjAsIC4zNSk7CiAgICAgICAgICAgIGJhY2tncm91
bmQ6IHJnYmEoNDYsIDE4MCwgMTIwLCAuMSk7CiAgICAgICAgfQogICAgICAgIC5pdG0uaXQtZ3JvdXAg
ewogICAgICAgICAgICBmbGV4LWRpcmVjdGlvbjogY29sdW1uOwogICAgICAgICAgICBhbGlnbi1pdGVt
czogc3RyZXRjaDsKICAgICAgICAgICAgZ2FwOiAwOwogICAgICAgICAgICBwYWRkaW5nOiA2cHggOHB4
IDRweDsKICAgICAgICAgICAgY3Vyc29yOiBkZWZhdWx0OwogICAgICAgIH0KICAgICAgICAuaXRtLml0
LWdyb3VwOmhvdmVyIHsgYmFja2dyb3VuZDogdmFyKC0tY2FyZCk7IH0KICAgICAgICAubWctaGVhZCB7
CiAgICAgICAgICAgIGRpc3BsYXk6IGZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGdhcDogNnB4Owog
ICAgICAgICAgICBmb250LXNpemU6IDExcHg7IGNvbG9yOiB2YXIoLS10eHQzKTsgZm9udC13ZWlnaHQ6
IDYwMDsKICAgICAgICAgICAgcGFkZGluZzogMnB4IDJweCA2cHg7IHVzZXItc2VsZWN0OiBub25lOwog
ICAgICAgIH0KICAgICAgICAubWctaGVhZCAubWctdGFnIHsKICAgICAgICAgICAgZGlzcGxheTogaW5s
aW5lLWZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7CiAgICAgICAgICAgIGhlaWdodDogMTZweDsgcGFk
ZGluZzogMCA2cHg7IGJvcmRlci1yYWRpdXM6IDhweDsKICAgICAgICAgICAgYmFja2dyb3VuZDogcmdi
YSg5MSwxMTUsMjMyLC4xMik7IGNvbG9yOiB2YXIoLS1hY2MpOyBmb250LXNpemU6IDEwcHg7CiAgICAg
ICAgfQogICAgICAgIC5tZy1yb3cgewogICAgICAgICAgICBwYWRkaW5nOiA3cHggNnB4OyBtYXJnaW4t
Ym90dG9tOiAzcHg7CiAgICAgICAgICAgIGJvcmRlci1yYWRpdXM6IDVweDsgY3Vyc29yOiBwb2ludGVy
OwogICAgICAgICAgICBib3JkZXI6IDFweCBzb2xpZCB0cmFuc3BhcmVudDsKICAgICAgICAgICAgdHJh
bnNpdGlvbjogYmFja2dyb3VuZCAuMTJzIGVhc2UsIGJvcmRlci1jb2xvciAuMTJzIGVhc2U7CiAgICAg
ICAgfQogICAgICAgIC5tZy1yb3c6aG92ZXIgeyBiYWNrZ3JvdW5kOiB2YXIoLS1jYXJkLWgpOyB9CiAg
ICAgICAgLm1nLXJvdy5zZWwgewogICAgICAgICAgICBiYWNrZ3JvdW5kOiAjZWRmMWZmOwogICAgICAg
ICAgICBib3JkZXItY29sb3I6IHJnYmEoOTEsMTE1LDIzMiwuMzUpOwogICAgICAgICAgICBib3gtc2hh
ZG93OiAwIDAgMCAxcHggcmdiYSg5MSwxMTUsMjMyLC4yNSk7CiAgICAgICAgfQogICAgICAgIC5tZy1y
b3cubXVsdGkgewogICAgICAgICAgICBiYWNrZ3JvdW5kOiAjZWVmMmZmOwogICAgICAgICAgICBib3Jk
ZXItY29sb3I6IHJnYmEoOTEsMTE1LDIzMiwuNDUpOwogICAgICAgIH0KICAgICAgICAubWctdGl0bGUg
ewogICAgICAgICAgICBmb250LXNpemU6IDEzcHg7IGZvbnQtd2VpZ2h0OiA2MDA7IGNvbG9yOiB2YXIo
LS1hY2MpOwogICAgICAgICAgICBtYXJnaW4tYm90dG9tOiAycHg7IGxpbmUtaGVpZ2h0OiAxLjM1Owog
ICAgICAgICAgICBkaXNwbGF5OiAtd2Via2l0LWJveDsgLXdlYmtpdC1ib3gtb3JpZW50OiB2ZXJ0aWNh
bDsgLXdlYmtpdC1saW5lLWNsYW1wOiAyOwogICAgICAgICAgICBvdmVyZmxvdzogaGlkZGVuOyB3b3Jk
LWJyZWFrOiBicmVhay13b3JkOwogICAgICAgIH0KICAgICAgICAubWctYm9keSB7CiAgICAgICAgICAg
IGZvbnQtc2l6ZTogMTIuNXB4OyBmb250LXdlaWdodDogNTAwOyBjb2xvcjogdmFyKC0tdHh0KTsKICAg
ICAgICAgICAgd2hpdGUtc3BhY2U6IHByZS13cmFwOyB3b3JkLWJyZWFrOiBicmVhay1hbGw7CiAgICAg
ICAgICAgIGRpc3BsYXk6IC13ZWJraXQtYm94OyAtd2Via2l0LWJveC1vcmllbnQ6IHZlcnRpY2FsOyAt
d2Via2l0LWxpbmUtY2xhbXA6IDQ7CiAgICAgICAgICAgIG92ZXJmbG93OiBoaWRkZW47IGxpbmUtaGVp
Z2h0OiAxLjQ7CiAgICAgICAgfQogICAgICAgIC5tZy1ib2R5LmltZyB7IGNvbG9yOiB2YXIoLS10eHQy
KTsgfQogICAgICAgIC5tZy1yb3ctdG9wIHsKICAgICAgICAgICAgZGlzcGxheTogZmxleDsgYWxpZ24t
aXRlbXM6IGZsZXgtc3RhcnQ7IGdhcDogOHB4OwogICAgICAgIH0KICAgICAgICAubWctcm93LW1haW4g
eyBmbGV4OiAxOyBtaW4td2lkdGg6IDA7IH0KICAgICAgICAubWctc3JjIHsKICAgICAgICAgICAgd2lk
dGg6IDE4cHg7IGhlaWdodDogMThweDsgZmxleC1zaHJpbms6IDA7IG1hcmdpbi10b3A6IDJweDsKICAg
ICAgICAgICAgYm9yZGVyLXJhZGl1czogM3B4OyBvYmplY3QtZml0OiBjb250YWluOwogICAgICAgICAg
ICBiYWNrZ3JvdW5kOiByZ2JhKDAsMCwwLC4wNCk7CiAgICAgICAgfQogICAgICAgIC5pLWZhdi10aXRs
ZSB7CiAgICAgICAgICAgIGZvbnQtc2l6ZTogMTNweDsgZm9udC13ZWlnaHQ6IDYwMDsgY29sb3I6IHZh
cigtLWFjYyk7CiAgICAgICAgICAgIG1hcmdpbjogMCAwIDNweDsgbGluZS1oZWlnaHQ6IDEuMzU7CiAg
ICAgICAgICAgIGRpc3BsYXk6IC13ZWJraXQtYm94OyAtd2Via2l0LWJveC1vcmllbnQ6IHZlcnRpY2Fs
OyAtd2Via2l0LWxpbmUtY2xhbXA6IDI7CiAgICAgICAgICAgIG92ZXJmbG93OiBoaWRkZW47IHdvcmQt
YnJlYWs6IGJyZWFrLXdvcmQ7CiAgICAgICAgfQogICAgICAgICN0aXRsZS1kbGcgewogICAgICAgICAg
ICBkaXNwbGF5OiBub25lOyBwb3NpdGlvbjogZml4ZWQ7IGluc2V0OiAwOyB6LWluZGV4OiAxMDA7CiAg
ICAgICAgICAgIGJhY2tncm91bmQ6IHJnYmEoMTUsMTgsMjgsLjM1KTsKICAgICAgICAgICAgYWxpZ24t
aXRlbXM6IGNlbnRlcjsganVzdGlmeS1jb250ZW50OiBjZW50ZXI7CiAgICAgICAgfQogICAgICAgICN0
aXRsZS1kbGcub24geyBkaXNwbGF5OiBmbGV4OyB9CiAgICAgICAgI3RpdGxlLWRsZyAudGl0bGUtYm94
IHsKICAgICAgICAgICAgd2lkdGg6IDI2MHB4OyBwYWRkaW5nOiAxNnB4IDE2cHggMTJweDsKICAgICAg
ICAgICAgYmFja2dyb3VuZDogdmFyKC0tY2FyZCk7IGJvcmRlci1yYWRpdXM6IDEwcHg7CiAgICAgICAg
ICAgIGJveC1zaGFkb3c6IDAgOHB4IDI4cHggcmdiYSgwLDAsMCwuMTgpOwogICAgICAgIH0KICAgICAg
ICAjdGl0bGUtaW5wdXQgewogICAgICAgICAgICB3aWR0aDogMTAwJTsgYm94LXNpemluZzogYm9yZGVy
LWJveDsgbWFyZ2luOiA4cHggMCAxMnB4OwogICAgICAgICAgICBoZWlnaHQ6IDMycHg7IHBhZGRpbmc6
IDAgMTBweDsgYm9yZGVyLXJhZGl1czogNnB4OwogICAgICAgICAgICBib3JkZXI6IDFweCBzb2xpZCAj
ZDVkYWU2OyBiYWNrZ3JvdW5kOiAjZmZmOyBjb2xvcjogdmFyKC0tdHh0KTsKICAgICAgICAgICAgZm9u
dC1zaXplOiAxM3B4OyBvdXRsaW5lOiBub25lOwogICAgICAgIH0KICAgICAgICAjdGl0bGUtaW5wdXQ6
Zm9jdXMgeyBib3JkZXItY29sb3I6IHZhcigtLWFjYyk7IH0KCiAgICAKICAgICAgICAvKiB1aS1ncmF5
LWJnLXYxICovCiAgICAgICAgOnJvb3QgewogICAgICAgICAgICAtLWJnOiAjZTRlN2VlICFpbXBvcnRh
bnQ7CiAgICAgICAgfQogICAgICAgIGh0bWwsIGJvZHkgewogICAgICAgICAgICBiYWNrZ3JvdW5kOiAj
ZTRlN2VlICFpbXBvcnRhbnQ7CiAgICAgICAgfQogICAgICAgICNhcHAgewogICAgICAgICAgICBiYWNr
Z3JvdW5kOiBsaW5lYXItZ3JhZGllbnQoMTgwZGVnLCAjZTllY2YzIDAlLCAjZTBlNGVjIDEwMCUpICFp
bXBvcnRhbnQ7CiAgICAgICAgfQogICAgICAgICNoZHIgewogICAgICAgICAgICBiYWNrZ3JvdW5kOiAj
ZTJlNmVlICFpbXBvcnRhbnQ7CiAgICAgICAgfQogICAgICAgICN0YWJzIHsKICAgICAgICAgICAgYmFj
a2dyb3VuZDogI2UyZTZlZSAhaW1wb3J0YW50OwogICAgICAgIH0KICAgICAgICAjbGlzdCwgI2VtcHR5
LCAjc2tlbCwgI2hkci1ncm93LCAjc2VhcmNoLXdyYXAgewogICAgICAgICAgICBiYWNrZ3JvdW5kOiB0
cmFuc3BhcmVudCAhaW1wb3J0YW50OwogICAgICAgIH0KICAgICAgICAjc2VhcmNoLWJveCB7CiAgICAg
ICAgICAgIHRyYW5zZm9ybS1vcmlnaW46IHJpZ2h0IGNlbnRlcjsKICAgICAgICAgICAgYmFja2dyb3Vu
ZDogdHJhbnNwYXJlbnQgIWltcG9ydGFudDsKICAgICAgICB9CiAgICAgICAgLml0bSwgLm1nLCAubWct
cm93LCAubWVyZ2UtZ3JvdXAgewogICAgICAgICAgICBiYWNrZ3JvdW5kOiAjZmZmZmZmICFpbXBvcnRh
bnQ7CiAgICAgICAgfQogICAgICAgIC5pdG06aG92ZXIgewogICAgICAgICAgICBiYWNrZ3JvdW5kOiAj
ZjhmOWZjICFpbXBvcnRhbnQ7CiAgICAgICAgfQogICAgCiAgICAgICAgLyogc2VsLXRpbnQtYmx1ZS12
MSAqLwogICAgICAgIC5pdG0uc2VsLAogICAgICAgIC5tZy1yb3cuc2VsLAogICAgICAgIC5pdG0ubXVs
dGksCiAgICAgICAgLm1nLXJvdy5tdWx0aSwKICAgICAgICAuaXRtLm11bHRpLnNlbCwKICAgICAgICAu
aXQtZ3JvdXAuc2VsLAogICAgICAgIC5pdC1ncm91cC5tdWx0aSB7CiAgICAgICAgICAgIGJhY2tncm91
bmQ6ICNlOGVmZmYgIWltcG9ydGFudDsKICAgICAgICB9CiAgICAgICAgLml0bS5zZWw6aG92ZXIsCiAg
ICAgICAgLml0bS5tdWx0aTpob3ZlciwKICAgICAgICAubWctcm93LnNlbDpob3ZlciwKICAgICAgICAu
bWctcm93Lm11bHRpOmhvdmVyIHsKICAgICAgICAgICAgYmFja2dyb3VuZDogI2RkZTZmZiAhaW1wb3J0
YW50OwogICAgICAgIH0KICAgIAogICAgICAgIC8qIGhvdmVyLWdyZWVuLXJpc2UtdjIgKi8KICAgICAg
ICAvKiBob3Zlci1hY2NlbnQtcmlzZS12MyAqLwogICAgICAgIC5pdG0geyBwb3NpdGlvbjogcmVsYXRp
dmUgIWltcG9ydGFudDsgb3ZlcmZsb3c6IGhpZGRlbiAhaW1wb3J0YW50OyB9CiAgICAgICAgLml0bTo6
YmVmb3JlIHsKICAgICAgICAgICAgY29udGVudDogIiIgIWltcG9ydGFudDsKICAgICAgICAgICAgcG9z
aXRpb246IGFic29sdXRlICFpbXBvcnRhbnQ7CiAgICAgICAgICAgIGxlZnQ6IDAgIWltcG9ydGFudDsg
cmlnaHQ6IDAgIWltcG9ydGFudDsgYm90dG9tOiAwICFpbXBvcnRhbnQ7CiAgICAgICAgICAgIGhlaWdo
dDogMCAhaW1wb3J0YW50OwogICAgICAgICAgICBwb2ludGVyLWV2ZW50czogbm9uZSAhaW1wb3J0YW50
OwogICAgICAgICAgICB6LWluZGV4OiAwICFpbXBvcnRhbnQ7CiAgICAgICAgICAgIGJvcmRlci1yYWRp
dXM6IDAgMCB2YXIoLS1yLCA0cHgpIHZhcigtLXIsIDRweCkgIWltcG9ydGFudDsKICAgICAgICAgICAg
YmFja2dyb3VuZDogbGluZWFyLWdyYWRpZW50KHRvIHRvcCwKICAgICAgICAgICAgICAgIHJnYmEoOTEs
IDExNSwgMjMyLCAuMzIpIDAlLAogICAgICAgICAgICAgICAgcmdiYSg5MSwgMTE1LCAyMzIsIC4xMikg
NTUlLAogICAgICAgICAgICAgICAgcmdiYSg5MSwgMTE1LCAyMzIsIDApIDEwMCUpICFpbXBvcnRhbnQ7
CiAgICAgICAgICAgIHRyYW5zaXRpb246IGhlaWdodCAuMzRzIGN1YmljLWJlemllciguMjIsIDEsIC4z
NiwgMSkgIWltcG9ydGFudDsKICAgICAgICB9CiAgICAgICAgLml0bTpob3Zlcjo6YmVmb3JlIHsgaGVp
Z2h0OiAzMy4zMzMlICFpbXBvcnRhbnQ7IH0KICAgICAgICAuaXRtOjphZnRlciB7CiAgICAgICAgICAg
IGNvbnRlbnQ6ICIiICFpbXBvcnRhbnQ7CiAgICAgICAgICAgIHBvc2l0aW9uOiBhYnNvbHV0ZSAhaW1w
b3J0YW50OwogICAgICAgICAgICBsZWZ0OiAwICFpbXBvcnRhbnQ7IHJpZ2h0OiAwICFpbXBvcnRhbnQ7
IGJvdHRvbTogMCAhaW1wb3J0YW50OwogICAgICAgICAgICBoZWlnaHQ6IDJweCAhaW1wb3J0YW50Owog
ICAgICAgICAgICBwb2ludGVyLWV2ZW50czogbm9uZSAhaW1wb3J0YW50OwogICAgICAgICAgICB6LWlu
ZGV4OiAxICFpbXBvcnRhbnQ7CiAgICAgICAgICAgIGJhY2tncm91bmQ6IHJnYmEoOTEsIDExNSwgMjMy
LCAuOTIpICFpbXBvcnRhbnQ7CiAgICAgICAgICAgIGJvcmRlci1yYWRpdXM6IDFweCAhaW1wb3J0YW50
OwogICAgICAgICAgICB0cmFuc2Zvcm06IHNjYWxlWCgwKSAhaW1wb3J0YW50OwogICAgICAgICAgICB0
cmFuc2Zvcm0tb3JpZ2luOiBjZW50ZXIgIWltcG9ydGFudDsKICAgICAgICAgICAgdHJhbnNpdGlvbjog
dHJhbnNmb3JtIC4zcyBjdWJpYy1iZXppZXIoLjIyLCAxLCAuMzYsIDEpICFpbXBvcnRhbnQ7CiAgICAg
ICAgfQogICAgICAgIC5pdG06aG92ZXI6OmFmdGVyIHsKICAgICAgICAgICAgdHJhbnNmb3JtOiBzY2Fs
ZVgoMSkgIWltcG9ydGFudDsKICAgICAgICAgICAgYmFja2dyb3VuZDogcmdiYSg5MSwgMTE1LCAyMzIs
IC45NSkgIWltcG9ydGFudDsKICAgICAgICB9CiAgICAgICAgLml0bSA+ICogeyBwb3NpdGlvbjogcmVs
YXRpdmU7IHotaW5kZXg6IDI7IH0KICAgICAgICAgICAgLyogd2hpdGUtcGFuZWwtYm9yZGVyOiBvdXRl
ciBlZGdlIGxpbmUgcmVtb3ZlZCAqLwogICAgICAgICNhcHAgewogICAgICAgICAgICBib3JkZXI6IG5v
bmUgIWltcG9ydGFudDsKICAgICAgICAgICAgYm9yZGVyLXJhZGl1czogMCAhaW1wb3J0YW50OwogICAg
ICAgICAgICBib3gtc2l6aW5nOiBib3JkZXItYm94ICFpbXBvcnRhbnQ7CiAgICAgICAgICAgIG92ZXJm
bG93OiBoaWRkZW4gIWltcG9ydGFudDsKICAgICAgICB9CiAgICAgICAgLml0bSwgLm1nLCAubWctcm93
LCAubWVyZ2UtZ3JvdXAgewogICAgICAgICAgICBib3JkZXI6IDFweCBzb2xpZCAjZmZmZmZmICFpbXBv
cnRhbnQ7CiAgICAgICAgfQogICAgPC9zdHlsZT4KPC9oZWFkPgo8Ym9keSBkYXRhLXVpLWJ1aWxkPSIy
MDI2MDkwNy0yMzA3Ij4KPGRpdiBpZD0iYXBwIiBkYXRhLXVpLXZlcj0iMjAyNjA5MDgtbm8tc2tlbCI+
CiAgICA8ZGl2IGlkPSJoZHIiPgogICAgICAgIDxkaXYgaWQ9ImhlYXJ0Ij4KICAgICAgICAgICAgPHN2
ZyB2aWV3Qm94PSIwIDAgMjQgMjQiIGZpbGw9Im5vbmUiIHN0cm9rZT0iY3VycmVudENvbG9yIiBzdHJv
a2Utd2lkdGg9IjEuOCIKICAgICAgICAgICAgICAgICBzdHJva2UtbGluZWNhcD0icm91bmQiIHN0cm9r
ZS1saW5lam9pbj0icm91bmQiPgogICAgICAgICAgICAgICAgPHJlY3QgeD0iOSIgeT0iMiIgd2lkdGg9
IjYiIGhlaWdodD0iNCIgcng9IjEiLz4KICAgICAgICAgICAgICAgIDxwYXRoIGQ9Ik0xNiA0aDJhMiAy
IDAgMCAxIDIgMnYxNGEyIDIgMCAwIDEtMiAySDZhMiAyIDAgMCAxLTItMlY2YTIgMiAwIDAgMSAyLTJo
MiIvPgogICAgICAgICAgICAgICAgPHBhdGggZD0iTTkgMTJoNk05IDE2aDQiLz4KICAgICAgICAgICAg
PC9zdmc+CiAgICAgICAgPC9kaXY+CiAgICAgICAgPGRpdiBpZD0iaGRyLWdyb3ciPjwvZGl2PgogICAg
ICAgIDxidXR0b24gaWQ9ImJ0bi1sb2NhdGUiIHR5cGU9ImJ1dHRvbiIgdGl0bGU9IuWumuS9jeWIsOS4
iuasoeS9v+eUqOeahOadoeebriIgZGlzYWJsZWQ+CiAgICAgICAgICAgIDxzdmcgdmlld0JveD0iMCAw
IDI0IDI0IiBmaWxsPSJub25lIiBzdHJva2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIyIgog
ICAgICAgICAgICAgICAgIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIgc3Ryb2tlLWxpbmVqb2luPSJyb3Vu
ZCI+CiAgICAgICAgICAgICAgICA8Y2lyY2xlIGN4PSIxMiIgY3k9IjEyIiByPSI4Ii8+CiAgICAgICAg
ICAgICAgICA8Y2lyY2xlIGN4PSIxMiIgY3k9IjEyIiByPSIzLjUiLz4KICAgICAgICAgICAgPC9zdmc+
CiAgICAgICAgPC9idXR0b24+CiAgICAgICAgPGRpdiBpZD0ic2VhcmNoLXdyYXAiPgogICAgICAgICAg
ICA8YnV0dG9uIGlkPSJidG4tc2VhcmNoIiB0eXBlPSJidXR0b24iIHRpdGxlPSLmkJzntKIiPgogICAg
ICAgICAgICAgICAgPHN2ZyB2aWV3Qm94PSIwIDAgMjQgMjQiIGZpbGw9Im5vbmUiIHN0cm9rZT0iY3Vy
cmVudENvbG9yIiBzdHJva2Utd2lkdGg9IjIiCiAgICAgICAgICAgICAgICAgICAgIHN0cm9rZS1saW5l
Y2FwPSJyb3VuZCIgc3Ryb2tlLWxpbmVqb2luPSJyb3VuZCI+CiAgICAgICAgICAgICAgICAgICAgPGNp
cmNsZSBjeD0iMTEiIGN5PSIxMSIgcj0iNyIvPgogICAgICAgICAgICAgICAgICAgIDxwYXRoIGQ9Ik0y
MCAyMGwtMy41LTMuNSIvPgogICAgICAgICAgICAgICAgPC9zdmc+CiAgICAgICAgICAgIDwvYnV0dG9u
PgogICAgICAgICAgICA8ZGl2IGlkPSJzZWFyY2gtYm94Ij4KICAgICAgICAgICAgICAgIDxidXR0b24g
aWQ9ImJ0bi10b2RheSIgdHlwZT0iYnV0dG9uIj7lvZPlpKk8L2J1dHRvbj4KICAgICAgICAgICAgICAg
IDxpbnB1dCBpZD0ic2VhcmNoIiB0eXBlPSJ0ZXh0IiBwbGFjZWhvbGRlcj0i5pCc57Si4oCmIOepuuag
vOWIhuivjemhu+WQjOaXtuWMheWQqyDCtyBhfGIg5YiG5q61IiBhdXRvY29tcGxldGU9Im9mZiIgc3Bl
bGxjaGVjaz0iZmFsc2UiPgogICAgICAgICAgICAgICAgPGJ1dHRvbiBpZD0ic2VhcmNoLWNsciIgdHlw
ZT0iYnV0dG9uIj7inJU8L2J1dHRvbj4KICAgICAgICAgICAgPC9kaXY+CiAgICAgICAgPC9kaXY+CiAg
ICAgICAgPGJ1dHRvbiBpZD0iYnRuLXBpbiIgdHlwZT0iYnV0dG9uIiB0aXRsZT0i6ZKJ5Zyo5bGP5bmV
5LiKIj4KICAgICAgICAgICAgPHN2ZyB2aWV3Qm94PSIwIDAgMjQgMjQiIGZpbGw9Im5vbmUiIHN0cm9r
ZT0iY3VycmVudENvbG9yIiBzdHJva2Utd2lkdGg9IjIiCiAgICAgICAgICAgICAgICAgc3Ryb2tlLWxp
bmVqb2luPSJyb3VuZCIgc3Ryb2tlLWxpbmVjYXA9InJvdW5kIj4KICAgICAgICAgICAgICAgIDxsaW5l
IHgxPSIxMiIgeTE9IjE3IiB4Mj0iMTIiIHkyPSIyMiIvPgogICAgICAgICAgICAgICAgPHBhdGggZD0i
TTUgMTdoMTR2LTEuNzZhMiAyIDAgMCAwLTEuMTEtMS43OWwtMS43OC0uOUEyIDIgMCAwIDEgMTUgMTAu
NzZWNmgxYTIgMiAwIDAgMCAwLTRIOGEyIDIgMCAwIDAgMCA0aDF2NC43NmEyIDIgMCAwIDEtMS4xMSAx
Ljc5bC0xLjc4LjlBMiAyIDAgMCAwIDUgMTUuMjRaIi8+CiAgICAgICAgICAgIDwvc3ZnPgogICAgICAg
IDwvYnV0dG9uPgogICAgPC9kaXY+CgogICAgPGRpdiBpZD0idGFicyI+CiAgICAgICAgPGRpdiBpZD0i
dGFiLWluayIgYXJpYS1oaWRkZW49InRydWUiPjwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9InRhYiBv
biIgZGF0YS10YWI9ImFsbCI+5YWo6YOoPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0idGFiIiBkYXRh
LXRhYj0idGV4dCI+5paH5pysPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0idGFiIiBkYXRhLXRhYj0i
aW1hZ2UiPuWbvuWDjzwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9InRhYiIgZGF0YS10YWI9ImZpbGUi
PuaWh+S7tjwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9InRhYiIgZGF0YS10YWI9InJlY2VudCI+5pyA
6L+RPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0idGFiIiBkYXRhLXRhYj0icGlubmVkIj7mlLbol48g
PHNwYW4gY2xhc3M9ImJhZGdlIiBpZD0icGluLWNudCIgc3R5bGU9ImRpc3BsYXk6bm9uZSI+MDwvc3Bh
bj48L2Rpdj4KICAgICAgICA8ZGl2IGlkPSJ0YWItYWN0aW9ucyI+CiAgICAgICAgICAgIDxidXR0b24g
aWQ9Im11bHRpLWNudCIgdHlwZT0iYnV0dG9uIiB0aXRsZT0i5Y+W5raI5aSa6YCJIj4wPC9idXR0b24+
CiAgICAgICAgICAgIDxzcGFuIGlkPSJiYXItdHh0Ij4wPC9zcGFuPgogICAgICAgICAgICA8YnV0dG9u
IGlkPSJidG4tY2xyIiB0eXBlPSJidXR0b24iIHRpdGxlPSLmuIXnqbrljoblj7IiPgogICAgICAgICAg
ICAgICAgPHN2ZyB2aWV3Qm94PSIwIDAgMjQgMjQiIGZpbGw9Im5vbmUiIHN0cm9rZT0iY3VycmVudENv
bG9yIiBzdHJva2Utd2lkdGg9IjIiCiAgICAgICAgICAgICAgICAgICAgIHN0cm9rZS1saW5lY2FwPSJy
b3VuZCIgc3Ryb2tlLWxpbmVqb2luPSJyb3VuZCI+CiAgICAgICAgICAgICAgICAgICAgPHBvbHlsaW5l
IHBvaW50cz0iMyA2IDUgNiAyMSA2Ii8+CiAgICAgICAgICAgICAgICAgICAgPHBhdGggZD0iTTE5IDZs
LTEgMTRhMiAyIDAgMCAxLTIgMkg4YTIgMiAwIDAgMS0yLTJMNSA2Ii8+CiAgICAgICAgICAgICAgICAg
ICAgPHBhdGggZD0iTTEwIDExdjZNMTQgMTF2Nk05IDZWNGg2djIiLz4KICAgICAgICAgICAgICAgIDwv
c3ZnPgogICAgICAgICAgICA8L2J1dHRvbj4KICAgICAgICA8L2Rpdj4KICAgIDwvZGl2PgoKICAgIDxk
aXYgaWQ9Imxpc3QiPgogICAgICAgIDxkaXYgaWQ9InNrZWwiIGFyaWEtaGlkZGVuPSJ0cnVlIj4KICAg
ICAgICAgICAgPGRpdiBjbGFzcz0ic2stcm93Ij48ZGl2IGNsYXNzPSJzay1pY28iPjwvZGl2PjxkaXYg
Y2xhc3M9InNrLWJvZHkiPjxkaXYgY2xhc3M9InNrLWxpbmUgbWlkIj48L2Rpdj48ZGl2IGNsYXNzPSJz
ay1saW5lIHNob3J0Ij48L2Rpdj48L2Rpdj48L2Rpdj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0ic2st
cm93Ij48ZGl2IGNsYXNzPSJzay1pY28iPjwvZGl2PjxkaXYgY2xhc3M9InNrLWJvZHkiPjxkaXYgY2xh
c3M9InNrLWxpbmUiPjwvZGl2PjxkaXYgY2xhc3M9InNrLWxpbmUgbWlkIj48L2Rpdj48L2Rpdj48L2Rp
dj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0ic2stcm93Ij48ZGl2IGNsYXNzPSJzay1pY28iPjwvZGl2
PjxkaXYgY2xhc3M9InNrLWJvZHkiPjxkaXYgY2xhc3M9InNrLWxpbmUgbWlkIj48L2Rpdj48ZGl2IGNs
YXNzPSJzay1saW5lIHNob3J0Ij48L2Rpdj48L2Rpdj48L2Rpdj4KICAgICAgICAgICAgPGRpdiBjbGFz
cz0ic2stcm93Ij48ZGl2IGNsYXNzPSJzay1pY28iPjwvZGl2PjxkaXYgY2xhc3M9InNrLWJvZHkiPjxk
aXYgY2xhc3M9InNrLWxpbmUiPjwvZGl2PjxkaXYgY2xhc3M9InNrLWxpbmUgbWlkIj48L2Rpdj48L2Rp
dj48L2Rpdj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0ic2stcm93Ij48ZGl2IGNsYXNzPSJzay1pY28i
PjwvZGl2PjxkaXYgY2xhc3M9InNrLWJvZHkiPjxkaXYgY2xhc3M9InNrLWxpbmUgbWlkIj48L2Rpdj48
ZGl2IGNsYXNzPSJzay1saW5lIHNob3J0Ij48L2Rpdj48L2Rpdj48L2Rpdj4KICAgICAgICAgICAgPGRp
diBjbGFzcz0ic2stcm93Ij48ZGl2IGNsYXNzPSJzay1pY28iPjwvZGl2PjxkaXYgY2xhc3M9InNrLWJv
ZHkiPjxkaXYgY2xhc3M9InNrLWxpbmUiPjwvZGl2PjxkaXYgY2xhc3M9InNrLWxpbmUgc2hvcnQiPjwv
ZGl2PjwvZGl2PjwvZGl2PgogICAgICAgIDwvZGl2PgogICAgICAgIDxkaXYgaWQ9ImVtcHR5Ij4KICAg
ICAgICAgICAgPGRpdiBjbGFzcz0iZS10eHQiIGlkPSJlbXB0eS10eHQiPuaaguaXoOiusOW9le+8jOWk
jeWItuWQjuiHquWKqOWHuueOsDwvZGl2PgogICAgICAgIDwvZGl2PgogICAgPC9kaXY+CiAgICA8YnV0
dG9uIGlkPSJidG4tdG9wIiB0eXBlPSJidXR0b24iIHRpdGxlPSLlm57liLDpobbpg6giIGFyaWEtbGFi
ZWw9IuWbnuWIsOmhtumDqCI+CiAgICAgICAgPHN2ZyB2aWV3Qm94PSIwIDAgMjQgMjQiIGZpbGw9Im5v
bmUiIHN0cm9rZT0iY3VycmVudENvbG9yIiBzdHJva2Utd2lkdGg9IjIuMiIKICAgICAgICAgICAgIHN0
cm9rZS1saW5lY2FwPSJyb3VuZCIgc3Ryb2tlLWxpbmVqb2luPSJyb3VuZCI+CiAgICAgICAgICAgIDxw
YXRoIGQ9Ik0xMiAxOVY1Ii8+CiAgICAgICAgICAgIDxwYXRoIGQ9Ik01IDEybDctNyA3IDciLz4KICAg
ICAgICA8L3N2Zz4KICAgIDwvYnV0dG9uPgo8L2Rpdj4KCjxkaXYgaWQ9ImN0eCI+CiAgICA8ZGl2IGNs
YXNzPSJjLWl0ZW0iIGlkPSJjLWNvcHkiPjxzcGFuIGNsYXNzPSJjLWljbyI+4o6YPC9zcGFuPuWkjeWI
tjwvZGl2PgogICAgPGRpdiBjbGFzcz0iYy1pdGVtIiBpZD0iYy1wYXN0ZSI+PHNwYW4gY2xhc3M9ImMt
aWNvIj7ij448L3NwYW4+57KY6LS0PC9kaXY+CiAgICA8ZGl2IGNsYXNzPSJjLXNlcCI+PC9kaXY+CiAg
ICA8ZGl2IGNsYXNzPSJjLWl0ZW0iIGlkPSJjLXBpbiI+PHNwYW4gY2xhc3M9ImMtaWNvIj7imIU8L3Nw
YW4+5pS26JePPC9kaXY+CiAgICA8ZGl2IGNsYXNzPSJjLWl0ZW0iIGlkPSJjLXRpdGxlIiBzdHlsZT0i
ZGlzcGxheTpub25lIj48c3BhbiBjbGFzcz0iYy1pY28iPuKcjjwvc3Bhbj7orr7nva7moIfpopg8L2Rp
dj4KICAgIDxkaXYgY2xhc3M9ImMtaXRlbSIgaWQ9ImMtbWVyZ2UiIHN0eWxlPSJkaXNwbGF5Om5vbmUi
PjxzcGFuIGNsYXNzPSJjLWljbyI+4qeJPC9zcGFuPuWQiOW5tjwvZGl2PgogICAgPGRpdiBjbGFzcz0i
Yy1pdGVtIiBpZD0iYy11bm1lcmdlIiBzdHlsZT0iZGlzcGxheTpub25lIj48c3BhbiBjbGFzcz0iYy1p
Y28iPuKHhDwvc3Bhbj7lj5bmtojlkIjlubY8L2Rpdj4KICAgIDxkaXYgY2xhc3M9ImMtaXRlbSIgaWQ9
ImMtdG9wIj48c3BhbiBjbGFzcz0iYy1pY28iPuKGkTwvc3Bhbj7np7vliLDpobbpg6g8L2Rpdj4KICAg
IDxkaXYgY2xhc3M9ImMtaXRlbSIgaWQ9ImMtY2xlYXItcGFzdGVkIiBzdHlsZT0iZGlzcGxheTpub25l
Ij48c3BhbiBjbGFzcz0iYy1pY28iPuKckzwvc3Bhbj7muIXpmaTnirbmgIE8L2Rpdj4KICAgIDxkaXYg
Y2xhc3M9ImMtaXRlbSIgaWQ9ImMtcXVldWUtZnJvbSIgc3R5bGU9ImRpc3BsYXk6bm9uZSI+PHNwYW4g
Y2xhc3M9ImMtaWNvIj7ihrs8L3NwYW4+5LuO5q2k5aSE5byA5aeL6Zif5YiXPC9kaXY+CiAgICA8ZGl2
IGNsYXNzPSJjLXNlcCI+PC9kaXY+CiAgICA8ZGl2IGNsYXNzPSJjLWl0ZW0gZGFuZ2VyIiBpZD0iYy1k
ZWwiPjxzcGFuIGNsYXNzPSJjLWljbyI+4pyVPC9zcGFuPuWIoOmZpDwvZGl2Pgo8L2Rpdj4KCjxkaXYg
aWQ9ImNsci1kbGciPgogICAgPGRpdiBjbGFzcz0iY2xyLWJveCIgcm9sZT0iZGlhbG9nIiBhcmlhLW1v
ZGFsPSJ0cnVlIj4KICAgICAgICA8ZGl2IGNsYXNzPSJjbHItdGl0bGUiIGlkPSJjbHItdGl0bGUiPueh
ruiupOa4heepuu+8nzwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9ImNsci1kZXNjIiBpZD0iY2xyLWRl
c2MiPum7mOiupOS7hea4heepuuW9k+WkqeWGheWuueOAgjwvZGl2PgogICAgICAgIDxsYWJlbCBjbGFz
cz0iY2xyLWNoZWNrIiBmb3I9ImNsci1hbGwiPgogICAgICAgICAgICA8aW5wdXQgdHlwZT0iY2hlY2ti
b3giIGlkPSJjbHItYWxsIj4KICAgICAgICAgICAgPHNwYW4+5riF56m65omA5pyJPC9zcGFuPgogICAg
ICAgIDwvbGFiZWw+CiAgICAgICAgPGRpdiBjbGFzcz0iY2xyLWJ0bnMiPgogICAgICAgICAgICA8YnV0
dG9uIHR5cGU9ImJ1dHRvbiIgaWQ9ImNsci1jYW5jZWwiPuWPlua2iDwvYnV0dG9uPgogICAgICAgICAg
ICA8YnV0dG9uIHR5cGU9ImJ1dHRvbiIgaWQ9ImNsci1vayI+5riF56m6PC9idXR0b24+CiAgICAgICAg
PC9kaXY+CiAgICA8L2Rpdj4KPC9kaXY+Cgo8ZGl2IGlkPSJ0aXRsZS1kbGciPgogICAgPGRpdiBjbGFz
cz0idGl0bGUtYm94IiByb2xlPSJkaWFsb2ciIGFyaWEtbW9kYWw9InRydWUiPgogICAgICAgIDxkaXYg
Y2xhc3M9ImNsci10aXRsZSI+6K6+572u5qCH6aKYPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0iY2xy
LWRlc2MiPuagh+mimOWPr+iiq+aQnOe0ouaJvuWIsO+8jOS7heeUqOS6juaUtuiXj+aVtOeQhuOAgjwv
ZGl2PgogICAgICAgIDxpbnB1dCBpZD0idGl0bGUtaW5wdXQiIHR5cGU9InRleHQiIG1heGxlbmd0aD0i
ODAiIHBsYWNlaG9sZGVyPSLnu5nov5nmnaHmlLbol4/otbfkuKrlkI3lrZfigKYiIGF1dG9jb21wbGV0
ZT0ib2ZmIiBzcGVsbGNoZWNrPSJmYWxzZSI+CiAgICAgICAgPGRpdiBjbGFzcz0iY2xyLWJ0bnMiPgog
ICAgICAgICAgICA8YnV0dG9uIHR5cGU9ImJ1dHRvbiIgaWQ9InRpdGxlLWNhbmNlbCI+5Y+W5raIPC9i
dXR0b24+CiAgICAgICAgICAgIDxidXR0b24gdHlwZT0iYnV0dG9uIiBpZD0idGl0bGUtb2siPuS/neWt
mDwvYnV0dG9uPgogICAgICAgIDwvZGl2PgogICAgPC9kaXY+CjwvZGl2Pgo8ZGl2IGlkPSJwYXRoLXRp
cCIgYXJpYS1oaWRkZW49InRydWUiPjwvZGl2PgoKPHNjcmlwdD4KLyogc2tlbC1mYWlsc2FmZTogb25s
eSBpZiBtYWluIFVJIHNjcmlwdCBuZXZlciBib290ZWQg4oCUbmV2ZXIgaW52ZW50IGVtcHR5LXN0YXRl
ICovCihmdW5jdGlvbigpewogIHNldFRpbWVvdXQoKCkgPT4gewogICAgdHJ5IHsKICAgICAgaWYgKHdp
bmRvdy5fX3VpQm9vdGVkKSByZXR1cm47CiAgICAgIHZhciBhcHAgPSBkb2N1bWVudC5nZXRFbGVtZW50
QnlJZCgnYXBwJyk7CiAgICAgIGlmIChhcHApIGFwcC5jbGFzc0xpc3QucmVtb3ZlKCdib290LWxvYWRp
bmcnKTsKICAgICAgdmFyIHMgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc2tlbCcpOwogICAgICBp
ZiAocykgcy5jbGFzc0xpc3QucmVtb3ZlKCdvbicpOwogICAgfSBjYXRjaCAoZXJyKSB7fQogIH0sIDMw
MDApOwp9KSgpOwo8L3NjcmlwdD4KPHNjcmlwdD4KICAgIGxldCBhbGxDbGlwcyA9IFtdLCBjdXJUYWIg
PSAnYWxsJywgcXVlcnkgPSAnJywgY3R4Q2xpcCA9IG51bGwsIHNlbGVjdGVkSWQgPSAwLCBwaW5uZWRV
SSA9IGZhbHNlOwogICAgY29uc3QgVEFCX09SREVSID0gWydhbGwnLCAndGV4dCcsICdpbWFnZScsICdm
aWxlJywgJ3JlY2VudCcsICdwaW5uZWQnXTsKICAgIGNvbnN0IHZpZXdNZW0gPSBuZXcgTWFwKCk7CiAg
ICBmdW5jdGlvbiB2aWV3TWVtS2V5KHRhYiwgcSwgdG9kYXkpIHsKICAgICAgICByZXR1cm4gU3RyaW5n
KHRhYiB8fCAnYWxsJykgKyAnXHQnICsgU3RyaW5nKHEgfHwgJycpICsgJ1x0JyArICh0b2RheSA/ICcx
JyA6ICcwJyk7CiAgICB9CiAgICBsZXQgdGFiU3dpdGNoQW5pbURpciA9IDA7CiAgICBsZXQgbXVsdGlJ
ZHMgPSBbXTsKICAgIGxldCB0b2RheU9ubHkgPSBmYWxzZTsKICAgIGxldCBkaXNrVG90YWwgPSAwOwog
ICAgbGV0IGxvYWRpbmdNb3JlID0gZmFsc2U7CiAgICAvLyBEb24ndCBzaG93IHNrZWxldG9uIGltbWVk
aWF0ZWx5IOKAlG9ubHkgYWZ0ZXIgU0tFTF9ERUxBWV9NUyBpZiBkYXRhIHN0aWxsIG1pc3NpbmcKICAg
IGxldCBib290TG9hZGluZyA9IGZhbHNlOwogICAgbGV0IHdhaXRpbmdEYXRhID0gZmFsc2U7CiAgICBs
ZXQgaG9zdFB1c2hlZE9uY2UgPSBmYWxzZTsgLy8gb25seSB0aGVuIG1heSBzaG9344CM5pqC5peg6K6w
5b2V44CNCiAgICBsZXQgc2F3Tm9uRW1wdHkgPSBmYWxzZTsgICAgLy8gaWdub3JlIGJvb3RzdHJhcCBl
bXB0eSBwdXNoZXMgYmVmb3JlIGZpcnN0IHJlYWwgbGlzdAogICAgbGV0IHBpbm5lZFRvdGFsID0gMDsg
ICAgICAgIC8vIGF1dGhvcml0YXRpdmUg5pS26JePIGNvdW50IGZyb20gQUhLCiAgICBjb25zdCBTS0VM
X0RFTEFZX01TID0gNjA7CiAgICB3aW5kb3cuX19kYXRhUmVhZHkgPSBmYWxzZTsKICAgIHdpbmRvdy5f
X3VpQm9vdGVkID0gdHJ1ZTsKICAgIC8vIE9wZW4gcGFuZWwgd2l0aG91dCBwYXN0aW5nIOKGkiBhbHdh
eXMgbGFuZCBvbiBmaXJzdCBpdGVtIChhZnRlciBkYXRhIGFycml2ZXMpCiAgICBsZXQgc2VsZWN0Rmly
c3RPblNob3cgPSBmYWxzZTsKICAgIGxldCBsYXN0UGFzdGVJZCA9IDA7CiAgICBsZXQgbGFzdFBhc3Rl
VGFiID0gJ2FsbCc7CiAgICBsZXQgbG9jYXRlQWN0aXZlID0gZmFsc2U7CiAgICB0cnkgeyBsYXN0UGFz
dGVJZCA9ICtsb2NhbFN0b3JhZ2UuZ2V0SXRlbSgnY2xpcExhc3RQYXN0ZUlkJykgfHwgMDsgfSBjYXRj
aCB7fQogICAgdHJ5IHsKICAgICAgICBjb25zdCB0ID0gbG9jYWxTdG9yYWdlLmdldEl0ZW0oJ2NsaXBM
YXN0UGFzdGVUYWInKSB8fCAnYWxsJzsKICAgICAgICBsYXN0UGFzdGVUYWIgPSBbJ2FsbCcsJ3RleHQn
LCdpbWFnZScsJ2ZpbGUnLCdwaW5uZWQnXS5pbmNsdWRlcyh0KSA/IHQgOiAnYWxsJzsKICAgIH0gY2F0
Y2gge30KICAgIC8vIFByZWZlciBzYW1lLW9yaWdpbiB1bmRlciBjbGlwdWkuYXBwIChBUFBfSE9TVCDi
hpIgQ0xJUF9WMV9ESVIvY2xpcHNfc3RvcmUpLgogICAgLy8g5Yu/55SoICoubG9jYWzvvJrns7vnu58g
bUROUyDkvJrljaEgMuKAkzNz44CCY2xpcHMuc3RvcmUg5LuF5L2cIGZhbGxiYWNr44CCCiAgICBjb25z
dCBTVE9SRV9CQVNFID0gKGxvY2F0aW9uLm9yaWdpbiAmJiBsb2NhdGlvbi5vcmlnaW4uaW5kZXhPZign
aHR0cHM6Ly8nKSA9PT0gMCkKICAgICAgICA/IChsb2NhdGlvbi5vcmlnaW4ucmVwbGFjZSgvXC8kLywg
JycpICsgJy9jbGlwc19zdG9yZS8nKQogICAgICAgIDogJ2h0dHBzOi8vY2xpcHVpLmFwcC9jbGlwc19z
dG9yZS8nOwogICAgY29uc3QgU1RPUkVfQkFTRV9GQUxMQkFDSyA9ICdodHRwczovL2NsaXBzLnN0b3Jl
Lyc7CiAgICBmdW5jdGlvbiBtZXRhQ2VudGVySHRtbChleHBhbmRJbm5lcikgewogICAgICAgIGlmIChl
eHBhbmRJbm5lciA9PSBudWxsIHx8IGV4cGFuZElubmVyID09PSBmYWxzZSkKICAgICAgICAgICAgcmV0
dXJuIGA8c3BhbiBjbGFzcz0iaS1tZXRhLWNlbnRlciI+PC9zcGFuPmA7CiAgICAgICAgcmV0dXJuIGA8
c3BhbiBjbGFzcz0iaS1tZXRhLWNlbnRlciI+PGJ1dHRvbiBjbGFzcz0iaS1leHBhbmQtYnRuJHtleHBh
bmRJbm5lci5vbiA/ICcgb24nIDogJyd9IiB0eXBlPSJidXR0b24iIHRpdGxlPSLlsZXlvIAv5pS26LW3
Ij4ke2V4cGFuZElubmVyLmh0bWx9PC9idXR0b24+PC9zcGFuPmA7CiAgICB9CgogICAgZnVuY3Rpb24g
cmVtZW1iZXJMYXN0UGFzdGUoaWQpIHsKICAgICAgICBsYXN0UGFzdGVJZCA9ICtpZCB8fCAwOwogICAg
ICAgIGxhc3RQYXN0ZVRhYiA9IGN1clRhYiB8fCAnYWxsJzsKICAgICAgICB0cnkgewogICAgICAgICAg
ICBsb2NhbFN0b3JhZ2Uuc2V0SXRlbSgnY2xpcExhc3RQYXN0ZUlkJywgU3RyaW5nKGxhc3RQYXN0ZUlk
KSk7CiAgICAgICAgICAgIGxvY2FsU3RvcmFnZS5zZXRJdGVtKCdjbGlwTGFzdFBhc3RlVGFiJywgbGFz
dFBhc3RlVGFiKTsKICAgICAgICB9IGNhdGNoIHt9CiAgICAgICAgdXBkYXRlTG9jYXRlQnRuKCk7CiAg
ICB9CiAgICBmdW5jdGlvbiB1cGRhdGVMb2NhdGVCdG4oKSB7CiAgICAgICAgY29uc3QgYnRuID0gZG9j
dW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2J0bi1sb2NhdGUnKTsKICAgICAgICBpZiAoIWJ0bikgcmV0dXJu
OwogICAgICAgIGJ0bi5kaXNhYmxlZCA9ICFsYXN0UGFzdGVJZDsKICAgICAgICBidG4uY2xhc3NMaXN0
LnRvZ2dsZSgnaGFzLXRhcmdldCcsICEhbGFzdFBhc3RlSWQpOwogICAgICAgIGJ0bi5jbGFzc0xpc3Qu
dG9nZ2xlKCdvbicsIGxvY2F0ZUFjdGl2ZSAmJiAhIWxhc3RQYXN0ZUlkKTsKICAgICAgICBidG4udGl0
bGUgPSAhbGFzdFBhc3RlSWQKICAgICAgICAgICAgPyAn5pqC5peg5LiK5qyh5L2/55So5L2N572uJwog
ICAgICAgICAgICA6IChsb2NhdGVBY3RpdmUgPyAn5Y+W5raI5a6a5L2N77yM5Zue5Yiw56ys5LiA5p2h
JyA6ICflrprkvY3liLDkuIrmrKHkvb/nlKjnmoTmnaHnm64nKTsKICAgIH0KICAgIGZ1bmN0aW9uIHNl
bGVjdEZpcnN0SXRlbSgpIHsKICAgICAgICBsb2NhdGVBY3RpdmUgPSBmYWxzZTsKICAgICAgICB3aW5k
b3cuX19wZW5kaW5nSnVtcElkID0gMDsKICAgICAgICB3aW5kb3cuX19qdW1wTG9hZFRyaWVzID0gMDsK
ICAgICAgICBzZWxlY3RGaXJzdE9uU2hvdyA9IGZhbHNlOwogICAgICAgIGNvbnN0IHZpcyA9IHZpc2li
bGVMaXN0KCk7CiAgICAgICAgaWYgKCF2aXMubGVuZ3RoKSB7CiAgICAgICAgICAgIHNlbGVjdGVkSWQg
PSAwOwogICAgICAgICAgICBzeW5jSXRlbUhpZ2hsaWdodCgpOwogICAgICAgICAgICB1cGRhdGVMb2Nh
dGVCdG4oKTsKICAgICAgICAgICAgcmV0dXJuOwogICAgICAgIH0KICAgICAgICBzZWxlY3RlZElkID0g
dmlzWzBdLmlkOwogICAgICAgIHJhbmdlQW5jaG9ySWQgPSBzZWxlY3RlZElkOwogICAgICAgIHJhbmdl
QW5jaG9yQ2xpY2tlZCA9IGZhbHNlOwogICAgICAgIGxpc3RFbC5zY3JvbGxUb3AgPSAwOwogICAgICAg
IHN5bmNJdGVtSGlnaGxpZ2h0KCk7CiAgICAgICAgY29uc3QgZWwgPSBsaXN0RWwucXVlcnlTZWxlY3Rv
cignLml0bVtkYXRhLWlkPSInICsgc2VsZWN0ZWRJZCArICciXScpOwogICAgICAgIGlmIChlbCkgZWwu
c2Nyb2xsSW50b1ZpZXcoeyBibG9jazogJ25lYXJlc3QnIH0pOwogICAgICAgIHVwZGF0ZUxvY2F0ZUJ0
bigpOwogICAgfQogICAgZnVuY3Rpb24ganVtcFRvTGFzdFBhc3RlKCkgewogICAgICAgIGlmICghbGFz
dFBhc3RlSWQpIHJldHVybjsKICAgICAgICAvLyBBbHJlYWR5IGxvY2F0ZWQgb24gbGFzdCBwYXN0ZSDi
hpIgY2FuY2VsIGFuZCBzZWxlY3QgZmlyc3QKICAgICAgICBpZiAobG9jYXRlQWN0aXZlICYmICtzZWxl
Y3RlZElkID09PSArbGFzdFBhc3RlSWQpIHsKICAgICAgICAgICAgc2VsZWN0Rmlyc3RJdGVtKCk7CiAg
ICAgICAgICAgIHJldHVybjsKICAgICAgICB9CiAgICAgICAgbG9jYXRlQWN0aXZlID0gdHJ1ZTsKICAg
ICAgICBzZWxlY3RGaXJzdE9uU2hvdyA9IGZhbHNlOwogICAgICAgIC8vIENsZWFyIGZpbHRlcnMgc28g
dGhlIGl0ZW0gaXMgZmluZGFibGUgb24gdGhlIHRhYiB3aGVyZSBpdCB3YXMgdXNlZAogICAgICAgIHF1
ZXJ5ID0gJyc7CiAgICAgICAgdG9kYXlPbmx5ID0gZmFsc2U7CiAgICAgICAgdHJ5IHsKICAgICAgICAg
ICAgY29uc3Qgc3JjaCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzZWFyY2gnKTsKICAgICAgICAg
ICAgY29uc3Qgc2NsciA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzZWFyY2gtY2xyJyk7CiAgICAg
ICAgICAgIGNvbnN0IHdyYXAgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc2VhcmNoLXdyYXAnKTsK
ICAgICAgICAgICAgY29uc3QgYnRuVG9kYXkgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYnRuLXRv
ZGF5Jyk7CiAgICAgICAgICAgIGlmIChzcmNoKSB7IHNyY2gudmFsdWUgPSAnJzsgc3JjaC5jbGFzc0xp
c3QucmVtb3ZlKCdoYXMtdmFsJyk7IH0KICAgICAgICAgICAgaWYgKHNjbHIpIHNjbHIuc3R5bGUuZGlz
cGxheSA9ICdub25lJzsKICAgICAgICAgICAgaWYgKHdyYXApIHdyYXAuY2xhc3NMaXN0LnJlbW92ZSgn
b3BlbicpOwogICAgICAgICAgICBpZiAoYnRuVG9kYXkpIGJ0blRvZGF5LmNsYXNzTGlzdC5yZW1vdmUo
J29uJyk7CiAgICAgICAgfSBjYXRjaCB7fQogICAgICAgIGNvbnN0IHRhYiA9IFsnYWxsJywndGV4dCcs
J2ltYWdlJywnZmlsZScsJ3Bpbm5lZCddLmluY2x1ZGVzKGxhc3RQYXN0ZVRhYikKICAgICAgICAgICAg
PyBsYXN0UGFzdGVUYWIgOiAnYWxsJzsKICAgICAgICBjb25zdCBwcmV2VGFiID0gY3VyVGFiOwogICAg
ICAgIGN1clRhYiA9IHRhYjsKICAgICAgICBsb2FkaW5nTW9yZSA9IGZhbHNlOwogICAgICAgIG1hcmtU
YWIodGFiKTsKICAgICAgICBjbGVhck11bHRpKCk7CiAgICAgICAgc2VsZWN0ZWRJZCA9IGxhc3RQYXN0
ZUlkOwogICAgICAgIHdpbmRvdy5fX3BlbmRpbmdKdW1wSWQgPSBsYXN0UGFzdGVJZDsKICAgICAgICB3
aW5kb3cuX19qdW1wTG9hZFRyaWVzID0gMDsKICAgICAgICB3aW5kb3cuX19qdW1wRmVsbEJhY2sgPSBm
YWxzZTsKICAgICAgICB1cGRhdGVMb2NhdGVCdG4oKTsKICAgICAgICByZXF1ZXN0VmlldygpOwogICAg
fQoKICAgIGZ1bmN0aW9uIHJlcXVlc3RWaWV3KCkgewogICAgICAgIGNvbnN0IHRhYiA9IGN1clRhYiwg
cSA9IHF1ZXJ5LCB0b2RheSA9IHRvZGF5T25seSA/ICcxJyA6ICcwJzsKICAgICAgICBpZiAod2luZG93
Ll9fdmlld1JhZikgY2FuY2VsQW5pbWF0aW9uRnJhbWUod2luZG93Ll9fdmlld1JhZik7CiAgICAgICAg
d2luZG93Ll9fdmlld1JhZiA9IHJlcXVlc3RBbmltYXRpb25GcmFtZSgoKSA9PiB7CiAgICAgICAgICAg
IHdpbmRvdy5fX3ZpZXdSYWYgPSAwOwogICAgICAgICAgICBzZXRUaW1lb3V0KCgpID0+IGFoaygnc2V0
VmlldycsIHRhYiwgcSwgdG9kYXkpLCAwKTsKICAgICAgICB9KTsKICAgIH0KICAgIC8qKiBEZWJvdW5j
ZWQgQUhLIHN5bmMgYWZ0ZXIgdmlld01lbSBpbnN0YW50IHBhaW50IOKAlGF2b2lkcyB0YWItc3dpdGNo
IGRvdWJsZSBQdXNoQ2xpcHMgKi8KICAgIGZ1bmN0aW9uIHNvZnRSZXF1ZXN0VmlldygpIHsKICAgICAg
ICBpZiAod2luZG93Ll9fc29mdFZpZXdUKSBjbGVhclRpbWVvdXQod2luZG93Ll9fc29mdFZpZXdUKTsK
ICAgICAgICB3aW5kb3cuX19zb2Z0Vmlld1QgPSBzZXRUaW1lb3V0KCgpID0+IHsKICAgICAgICAgICAg
d2luZG93Ll9fc29mdFZpZXdUID0gMDsKICAgICAgICAgICAgcmVxdWVzdFZpZXcoKTsKICAgICAgICB9
LCAzMjApOwogICAgfQogICAgZnVuY3Rpb24gcmVxdWVzdE1vcmUoZm9yY2UgPSBmYWxzZSkgewogICAg
ICAgIGlmIChkaXNrVG90YWwgPiAwICYmIGFsbENsaXBzLmxlbmd0aCA+PSBkaXNrVG90YWwpIHJldHVy
bjsKICAgICAgICAvLyBMb2NhdGUgLyBqdW1wIG11c3Qgbm90IHdhaXQgb24gc2Nyb2xsLWlkbGUgb3Ig
YSBzdHVjayBsb2FkaW5nTW9yZSBmbGFnCiAgICAgICAgaWYgKCFmb3JjZSkgewogICAgICAgICAgICBp
ZiAobG9hZGluZ01vcmUpIHJldHVybjsKICAgICAgICAgICAgaWYgKHdpbmRvdy5fX3Njcm9sbEJ1c3kg
fHwgX2xpc3RQdHJEb3duKSB7CiAgICAgICAgICAgICAgICB3aW5kb3cuX193YW50TW9yZSA9IHRydWU7
CiAgICAgICAgICAgICAgICByZXR1cm47CiAgICAgICAgICAgIH0KICAgICAgICB9IGVsc2UgewogICAg
ICAgICAgICBsb2FkaW5nTW9yZSA9IGZhbHNlOwogICAgICAgICAgICB3aW5kb3cuX19zY3JvbGxCdXN5
ID0gZmFsc2U7CiAgICAgICAgICAgIHdpbmRvdy5fX3dhbnRNb3JlID0gZmFsc2U7CiAgICAgICAgICAg
IF9saXN0UHRyRG93biA9IGZhbHNlOwogICAgICAgICAgICB0cnkgeyBsaXN0RWwuY2xhc3NMaXN0LnJl
bW92ZSgnaXMtc2Nyb2xsaW5nJyk7IH0gY2F0Y2gge30KICAgICAgICB9CiAgICAgICAgaWYgKGxvYWRp
bmdNb3JlKSByZXR1cm47CiAgICAgICAgbG9hZGluZ01vcmUgPSB0cnVlOwogICAgICAgIHdpbmRvdy5f
X3dhbnRNb3JlID0gZmFsc2U7CiAgICAgICAgaWYgKHdpbmRvdy5fX2xvYWRNb3JlV2F0Y2gpIGNsZWFy
VGltZW91dCh3aW5kb3cuX19sb2FkTW9yZVdhdGNoKTsKICAgICAgICB3aW5kb3cuX19sb2FkTW9yZVdh
dGNoID0gc2V0VGltZW91dCgoKSA9PiB7CiAgICAgICAgICAgIHdpbmRvdy5fX2xvYWRNb3JlV2F0Y2gg
PSAwOwogICAgICAgICAgICBpZiAobG9hZGluZ01vcmUpIHsKICAgICAgICAgICAgICAgIGxvYWRpbmdN
b3JlID0gZmFsc2U7CiAgICAgICAgICAgICAgICBpZiAod2luZG93Ll9fcGVuZGluZ0p1bXBJZCkgdHJ5
Q29udGludWVKdW1wKCk7CiAgICAgICAgICAgIH0KICAgICAgICB9LCAxODAwKTsKICAgICAgICBhaGso
J2xvYWRNb3JlJyk7CiAgICB9CgogICAgZnVuY3Rpb24gdHJ5Q29udGludWVKdW1wKCkgewogICAgICAg
IGNvbnN0IGppZCA9ICt3aW5kb3cuX19wZW5kaW5nSnVtcElkOwogICAgICAgIGlmICghamlkKSByZXR1
cm47CiAgICAgICAgaWYgKF9wZW5kaW5nQXBwZW5kKSB7CiAgICAgICAgICAgIGNvbnN0IHBlbmRpbmcg
PSBfcGVuZGluZ0FwcGVuZDsKICAgICAgICAgICAgX3BlbmRpbmdBcHBlbmQgPSBudWxsOwogICAgICAg
ICAgICBhcHBseUFwcGVuZFBheWxvYWQocGVuZGluZyk7CiAgICAgICAgfQogICAgICAgIGNvbnN0IGVs
ID0gbGlzdEVsLnF1ZXJ5U2VsZWN0b3IoJy5tZy1yb3dbZGF0YS1pZD0iJyArIGppZCArICciXScpIHx8
IGxpc3RFbC5xdWVyeVNlbGVjdG9yKCcuaXRtW2RhdGEtaWQ9IicgKyBqaWQgKyAnIl0nKTsKICAgICAg
ICBpZiAoZWwpIHsKICAgICAgICAgICAgd2luZG93Ll9fcGVuZGluZ0p1bXBJZCA9IDA7CiAgICAgICAg
ICAgIHdpbmRvdy5fX2p1bXBMb2FkVHJpZXMgPSAwOwogICAgICAgICAgICBzZWxlY3RlZElkID0gamlk
OwogICAgICAgICAgICBsb2NhdGVBY3RpdmUgPSB0cnVlOwogICAgICAgICAgICB1cGRhdGVMb2NhdGVC
dG4oKTsKICAgICAgICAgICAgcmVxdWVzdEFuaW1hdGlvbkZyYW1lKCgpID0+IHsKICAgICAgICAgICAg
ICAgIGNvbnN0IG5vZGUgPSBsaXN0RWwucXVlcnlTZWxlY3RvcignLm1nLXJvd1tkYXRhLWlkPSInICsg
amlkICsgJyJdJykgfHwgbGlzdEVsLnF1ZXJ5U2VsZWN0b3IoJy5pdG1bZGF0YS1pZD0iJyArIGppZCAr
ICciXScpOwogICAgICAgICAgICAgICAgaWYgKCFub2RlKSByZXR1cm47CiAgICAgICAgICAgICAgICBu
b2RlLnNjcm9sbEludG9WaWV3KHsgYmxvY2s6ICdjZW50ZXInIH0pOwogICAgICAgICAgICAgICAgbm9k
ZS5jbGFzc0xpc3QuYWRkKCdqdW1wLWZsYXNoJyk7CiAgICAgICAgICAgICAgICBzZXRUaW1lb3V0KCgp
ID0+IG5vZGUuY2xhc3NMaXN0LnJlbW92ZSgnanVtcC1mbGFzaCcpLCA5MDApOwogICAgICAgICAgICAg
ICAgc3luY0l0ZW1IaWdobGlnaHQoKTsKICAgICAgICAgICAgfSk7CiAgICAgICAgICAgIHJldHVybjsK
ICAgICAgICB9CiAgICAgICAgaWYgKGFsbENsaXBzLnNvbWUoYyA9PiArYy5pZCA9PT0gamlkKSkgewog
ICAgICAgICAgICByZW5kZXIoKTsKICAgICAgICAgICAgcmVxdWVzdEFuaW1hdGlvbkZyYW1lKCgpID0+
IHRyeUNvbnRpbnVlSnVtcCgpKTsKICAgICAgICAgICAgcmV0dXJuOwogICAgICAgIH0KICAgICAgICBp
ZiAoYWxsQ2xpcHMubGVuZ3RoIDwgZGlza1RvdGFsICYmICh3aW5kb3cuX19qdW1wTG9hZFRyaWVzIHx8
IDApIDwgODApIHsKICAgICAgICAgICAgd2luZG93Ll9fanVtcExvYWRUcmllcyA9ICh3aW5kb3cuX19q
dW1wTG9hZFRyaWVzIHx8IDApICsgMTsKICAgICAgICAgICAgcmVxdWVzdE1vcmUodHJ1ZSk7CiAgICAg
ICAgICAgIHJldHVybjsKICAgICAgICB9CiAgICAgICAgd2luZG93Ll9fcGVuZGluZ0p1bXBJZCA9IDA7
CiAgICAgICAgd2luZG93Ll9fanVtcExvYWRUcmllcyA9IDA7CiAgICB9CiAgICBjb25zdCBFTVBUWV9N
U0cgPSB7CiAgICAgICAgYWxsOiAgICAn5pqC5peg6K6w5b2V77yM5aSN5Yi25ZCO6Ieq5Yqo5Ye6546w
JywKICAgICAgICB0ZXh0OiAgICfmmoLml6DmlofmnKwnLAogICAgICAgIGltYWdlOiAgJ+aaguaXoOWb
vuWDjycsCiAgICAgICAgZmlsZTogICAn5pqC5peg5paH5Lu2JywKICAgICAgICBwaW5uZWQ6ICfmmoLm
l6DmlLbol48nLAogICAgICAgIHJlY2VudDogJ+aaguaXoOacgOi/keaJk+W8gOeahOebruW9lScKICAg
IH07CgogICAgZnVuY3Rpb24gYWhrSW52b2tlKG1ldGhvZCwgYXJncykgewogICAgICAgIHRyeSB7CiAg
ICAgICAgICAgIGNvbnN0IGhvc3QgPSBjaHJvbWUud2Vidmlldy5ob3N0T2JqZWN0cy5zeW5jLmFoazsK
ICAgICAgICAgICAgaWYgKCFob3N0KSByZXR1cm47CiAgICAgICAgICAgIGxldCBjYWxsZWQgPSBmYWxz
ZTsKICAgICAgICAgICAgLy8gV2ViVmlldzI6IGhvc3QuY2FsbChuYW1lLCDigKYpIGlzIHRoZSByZWxp
YWJsZSBwYXRoLiBEaXJlY3QgaG9zdFttZXRob2RdKOKApikKICAgICAgICAgICAgLy8gY2FuIG1pcy1i
aW5kIGFyZ3MgKHNhdyBzZXRWaWV3IHRhYiBiZWNvbWUgMCDihpIgZm9yZXZlciBza2VsZXRvbiAvIHdy
b25nIHRhYikuCiAgICAgICAgICAgIGlmICh0eXBlb2YgaG9zdC5jYWxsID09PSAnZnVuY3Rpb24nKSB7
CiAgICAgICAgICAgICAgICB0cnkgeyBob3N0LmNhbGwobWV0aG9kLCAuLi5hcmdzKTsgY2FsbGVkID0g
dHJ1ZTsgfSBjYXRjaCB7fQogICAgICAgICAgICB9CiAgICAgICAgICAgIGlmICghY2FsbGVkICYmIHR5
cGVvZiBob3N0W21ldGhvZF0gPT09ICdmdW5jdGlvbicpIHsKICAgICAgICAgICAgICAgIHRyeSB7IGhv
c3RbbWV0aG9kXSguLi5hcmdzKTsgY2FsbGVkID0gdHJ1ZTsgfSBjYXRjaCAoZSkgeyBjb25zb2xlLndh
cm4oJ2Foay4nICsgbWV0aG9kLCBlKTsgfQogICAgICAgICAgICB9CiAgICAgICAgICAgIGlmICghY2Fs
bGVkICYmIGhvc3RbbWV0aG9kXSAhPSBudWxsICYmIHR5cGVvZiBob3N0W21ldGhvZF0gIT09ICdmdW5j
dGlvbicpIHsKICAgICAgICAgICAgICAgIHRyeSB7IHZvaWQgaG9zdFttZXRob2RdOyB9IGNhdGNoIHt9
CiAgICAgICAgICAgIH0KICAgICAgICB9IGNhdGNoIChlKSB7IGNvbnNvbGUud2FybignYWhrLicgKyBt
ZXRob2QsIGUpOyB9CiAgICB9CiAgICBmdW5jdGlvbiBhaGsobWV0aG9kLCAuLi5hcmdzKSB7CiAgICAg
ICAgYWhrSW52b2tlKG1ldGhvZCwgYXJncyk7CiAgICB9CiAgICBmdW5jdGlvbiBhaGtSZXQobWV0aG9k
LCAuLi5hcmdzKSB7CiAgICAgICAgdHJ5IHsKICAgICAgICAgICAgY29uc3QgaG9zdCA9IGNocm9tZS53
ZWJ2aWV3Lmhvc3RPYmplY3RzLnN5bmMuYWhrOwogICAgICAgICAgICBpZiAoIWhvc3QpIHJldHVybiBu
dWxsOwogICAgICAgICAgICBsZXQgcmV0ID0gbnVsbDsKICAgICAgICAgICAgaWYgKHR5cGVvZiBob3N0
LmNhbGwgPT09ICdmdW5jdGlvbicpIHsKICAgICAgICAgICAgICAgIHRyeSB7IHJldCA9IGhvc3QuY2Fs
bChtZXRob2QsIC4uLmFyZ3MpOyB9IGNhdGNoIHt9CiAgICAgICAgICAgIH0KICAgICAgICAgICAgaWYg
KHJldCA9PSBudWxsICYmIHR5cGVvZiBob3N0W21ldGhvZF0gPT09ICdmdW5jdGlvbicpIHsKICAgICAg
ICAgICAgICAgIHRyeSB7IHJldCA9IGhvc3RbbWV0aG9kXSguLi5hcmdzKTsgfSBjYXRjaCB7fQogICAg
ICAgICAgICAgICAgaWYgKHJldCA9PSBudWxsKSB7CiAgICAgICAgICAgICAgICAgICAgdHJ5IHsgcmV0
ID0gaG9zdFttZXRob2RdKC4uLmFyZ3MpOyB9IGNhdGNoIHt9CiAgICAgICAgICAgICAgICB9CiAgICAg
ICAgICAgIH0KICAgICAgICAgICAgaWYgKHJldCA9PSBudWxsICYmIGhvc3RbbWV0aG9kXSAhPSBudWxs
ICYmIHR5cGVvZiBob3N0W21ldGhvZF0gIT09ICdmdW5jdGlvbicpCiAgICAgICAgICAgICAgICByZXQg
PSBob3N0W21ldGhvZF07CiAgICAgICAgICAgIGlmIChyZXQgPT0gbnVsbCkgcmV0dXJuIG51bGw7CiAg
ICAgICAgICAgIGlmICh0eXBlb2YgcmV0ID09PSAnc3RyaW5nJyB8fCB0eXBlb2YgcmV0ID09PSAnbnVt
YmVyJyB8fCB0eXBlb2YgcmV0ID09PSAnYm9vbGVhbicpCiAgICAgICAgICAgICAgICByZXR1cm4gcmV0
OwogICAgICAgICAgICB0cnkgeyByZXR1cm4gU3RyaW5nKHJldCk7IH0gY2F0Y2ggeyByZXR1cm4gcmV0
OyB9CiAgICAgICAgfSBjYXRjaCAoZSkgeyBjb25zb2xlLndhcm4oJ2Foa1JldC4nICsgbWV0aG9kLCBl
KTsgfQogICAgICAgIHJldHVybiBudWxsOwogICAgfQoKICAgIC8vIEVhcmx5IEFISyBfX3NldFRodW1i
IGNhbiBhcnJpdmUgYmVmb3JlIERPTSBub2RlcyBleGlzdCDigJQga2VlcCB1bnRpbCBiaW5kCiAgICBj
b25zdCB0aHVtYkNhY2hlID0gbmV3IE1hcCgpOwoKICAgIC8qKiBQcmVmZXIgY2FjaGUgLyBkYXRhLVVS
TCwgdGhlbiB0aF8qLmpwZyB2aWEgdmlydHVhbCBob3N0LCB0aGVuIG9yaWdpbmFsICovCiAgICBmdW5j
dGlvbiBiaW5kU3RvcmVUaHVtYihpbWcsIGZpbGUsIGlkLCBmYWxsYmFjaykgewogICAgICAgIGltZy5k
YXRhc2V0LnRodW1iSWQgPSBTdHJpbmcoaWQpOwogICAgICAgIGltZy5hbHQgPSAnJzsKICAgICAgICBp
bWcuY2xhc3NMaXN0LmFkZCgndGh1bWItbG9hZGluZycpOwogICAgICAgIGNvbnN0IHdyYXAgPSBpbWcu
cGFyZW50RWxlbWVudDsKICAgICAgICBpZiAod3JhcCAmJiB3cmFwLmNsYXNzTGlzdC5jb250YWlucygn
aS10aHVtYi13cmFwJykpCiAgICAgICAgICAgIHdyYXAuY2xhc3NMaXN0LmFkZCgnd2FpdGluZycpOwog
ICAgICAgIGNvbnN0IGNsZWFyV2FpdCA9ICgpID0+IHsKICAgICAgICAgICAgaW1nLmNsYXNzTGlzdC5y
ZW1vdmUoJ3RodW1iLWxvYWRpbmcnKTsKICAgICAgICAgICAgaWYgKHdyYXApIHdyYXAuY2xhc3NMaXN0
LnJlbW92ZSgnd2FpdGluZycpOwogICAgICAgICAgICBpZiAoaW1nLl9mYWlsVGltZXIpIHRyeSB7IGNs
ZWFyVGltZW91dChpbWcuX2ZhaWxUaW1lcik7IH0gY2F0Y2gge30KICAgICAgICB9OwogICAgICAgIGNv
bnN0IGZhaWxUaW1lciA9IHNldFRpbWVvdXQoKCkgPT4gewogICAgICAgICAgICBpZiAoIWltZy5zcmMg
fHwgaW1nLm5hdHVyYWxXaWR0aCA8IDEpCiAgICAgICAgICAgICAgICBpbWcuYWx0ID0gJ+aXoOazleWK
oOi9vSc7CiAgICAgICAgICAgIGNsZWFyV2FpdCgpOwogICAgICAgIH0sIDEyMDAwKTsKICAgICAgICBp
bWcuX2ZhaWxUaW1lciA9IGZhaWxUaW1lcjsKICAgICAgICBjb25zdCBwcmV2TG9hZCA9IGltZy5vbmxv
YWQ7CiAgICAgICAgaW1nLm9ubG9hZCA9IGUgPT4gewogICAgICAgICAgICBjbGVhcldhaXQoKTsKICAg
ICAgICAgICAgaW1nLmFsdCA9ICcnOwogICAgICAgICAgICBpZiAodHlwZW9mIHByZXZMb2FkID09PSAn
ZnVuY3Rpb24nKSBwcmV2TG9hZC5jYWxsKGltZywgZSk7CiAgICAgICAgfTsKICAgICAgICBjb25zdCBi
YXJlID0gZmlsZSA/IFN0cmluZyhmaWxlKS5zcGxpdCgvW1xcL10vKS5wb3AoKSA6ICcnOwogICAgICAg
IGNvbnN0IHRoTmFtZSA9IGJhcmUgPyAoJ3RoXycgKyBiYXJlLnJlcGxhY2UoL1wuW14uXSskLywgJycp
ICsgJy5qcGcnKSA6ICcnOwogICAgICAgIGltZy5vbmVycm9yID0gKCkgPT4gewogICAgICAgICAgICBj
b25zdCBzdGVwID0gTnVtYmVyKGltZy5kYXRhc2V0LnN0ZXAgfHwgMCk7CiAgICAgICAgICAgIGlmIChz
dGVwIDwgMiAmJiBiYXJlKSB7CiAgICAgICAgICAgICAgICBpbWcuZGF0YXNldC5zdGVwID0gJzInOwog
ICAgICAgICAgICAgICAgaW1nLnNyYyA9IFNUT1JFX0JBU0UgKyBlbmNvZGVVUklDb21wb25lbnQoYmFy
ZSk7CiAgICAgICAgICAgICAgICByZXR1cm47CiAgICAgICAgICAgIH0KICAgICAgICAgICAgaWYgKHN0
ZXAgPCAzICYmICh0aE5hbWUgfHwgYmFyZSkpIHsKICAgICAgICAgICAgICAgIGltZy5kYXRhc2V0LnN0
ZXAgPSAnMyc7CiAgICAgICAgICAgICAgICBpbWcuc3JjID0gU1RPUkVfQkFTRV9GQUxMQkFDSyArIGVu
Y29kZVVSSUNvbXBvbmVudCh0aE5hbWUgfHwgYmFyZSk7CiAgICAgICAgICAgICAgICByZXR1cm47CiAg
ICAgICAgICAgIH0KICAgICAgICAgICAgaWYgKHN0ZXAgPCA0ICYmIGJhcmUgJiYgdGhOYW1lKSB7CiAg
ICAgICAgICAgICAgICBpbWcuZGF0YXNldC5zdGVwID0gJzQnOwogICAgICAgICAgICAgICAgaW1nLnNy
YyA9IFNUT1JFX0JBU0VfRkFMTEJBQ0sgKyBlbmNvZGVVUklDb21wb25lbnQoYmFyZSk7CiAgICAgICAg
ICAgICAgICByZXR1cm47CiAgICAgICAgICAgIH0KICAgICAgICAgICAgLy8gS2VlcCBzaGltbWVyOyBB
SEsgX19zZXRUaHVtYiB3aWxsIGZpbGwgaW4KICAgICAgICAgICAgaW1nLnJlbW92ZUF0dHJpYnV0ZSgn
c3JjJyk7CiAgICAgICAgICAgIGltZy5jbGFzc0xpc3QuYWRkKCd0aHVtYi1sb2FkaW5nJyk7CiAgICAg
ICAgICAgIGlmICh3cmFwKSB3cmFwLmNsYXNzTGlzdC5hZGQoJ3dhaXRpbmcnKTsKICAgICAgICB9Owog
ICAgICAgIGNvbnN0IGNhY2hlZCA9IHRodW1iQ2FjaGUuZ2V0KFN0cmluZyhpZCkpOwogICAgICAgIC8v
IEFjY2VwdCBkYXRhLVVSTCBvciBob3N0IFVSTCBmcm9tIHByaW9yIF9fc2V0VGh1bWIgKHJlLXJlbmRl
ciBtdXN0IG5vdCBkcm9wIGl0KQogICAgICAgIGlmIChjYWNoZWQgJiYgU3RyaW5nKGNhY2hlZCkubGVu
Z3RoKSB7CiAgICAgICAgICAgIGltZy5kYXRhc2V0LnN0ZXAgPSAnOSc7CiAgICAgICAgICAgIGltZy5z
cmMgPSBTdHJpbmcoY2FjaGVkKTsKICAgICAgICAgICAgcmV0dXJuOwogICAgICAgIH0KICAgICAgICBj
b25zdCBkYXRhVXJsID0gKGZhbGxiYWNrICYmIFN0cmluZyhmYWxsYmFjaykuc3RhcnRzV2l0aCgnZGF0
YTonKSkKICAgICAgICAgICAgPyBTdHJpbmcoZmFsbGJhY2spIDogJyc7CiAgICAgICAgaWYgKGRhdGFV
cmwpIHsKICAgICAgICAgICAgaW1nLmRhdGFzZXQuc3RlcCA9ICc5JzsKICAgICAgICAgICAgaW1nLnNy
YyA9IGRhdGFVcmw7CiAgICAgICAgICAgIHJldHVybjsKICAgICAgICB9CiAgICAgICAgaWYgKGJhcmUp
IHsKICAgICAgICAgICAgLy8gUHJlZmVyIGxpc3QgdGh1bWIgSlBFRyAoc21hbGwpIG9uIGRlZGljYXRl
ZCBzdG9yZSBob3N0CiAgICAgICAgICAgIGltZy5kYXRhc2V0LnN0ZXAgPSAnMSc7CiAgICAgICAgICAg
IGltZy5zcmMgPSBTVE9SRV9CQVNFICsgZW5jb2RlVVJJQ29tcG9uZW50KHRoTmFtZSB8fCBiYXJlKTsK
ICAgICAgICB9IGVsc2UgewogICAgICAgICAgICAvLyBObyBmaWxlIHlldCAoanVzdCBjb3BpZWQpIOKA
lGtlZXAgc2hpbW1lcjsgSW5qZWN0TGl2ZUltYWdlVGh1bWIgLyBfX3NldFRodW1iIGZpbGxzIGluCiAg
ICAgICAgICAgIGltZy5jbGFzc0xpc3QuYWRkKCd0aHVtYi1sb2FkaW5nJyk7CiAgICAgICAgICAgIGlm
ICh3cmFwKSB3cmFwLmNsYXNzTGlzdC5hZGQoJ3dhaXRpbmcnKTsKICAgICAgICB9CiAgICB9CgogICAg
d2luZG93Ll9fc2V0VGh1bWIgPSAoaWQsIHVybCkgPT4gewogICAgICAgIGlmICghdXJsKSByZXR1cm47
CiAgICAgICAgY29uc3Qga2V5ID0gU3RyaW5nKGlkKTsKICAgICAgICB0aHVtYkNhY2hlLnNldChrZXks
IHVybCk7CiAgICAgICAgY29uc3QgYXBwbHkgPSBpbWcgPT4gewogICAgICAgICAgICBpZiAoaW1nLl9m
YWlsVGltZXIpIHRyeSB7IGNsZWFyVGltZW91dChpbWcuX2ZhaWxUaW1lcik7IH0gY2F0Y2gge30KICAg
ICAgICAgICAgaW1nLm9uZXJyb3IgPSBudWxsOwogICAgICAgICAgICBpbWcuYWx0ID0gJyc7CiAgICAg
ICAgICAgIGltZy5jbGFzc0xpc3QucmVtb3ZlKCd0aHVtYi1sb2FkaW5nJyk7CiAgICAgICAgICAgIGNv
bnN0IHdyYXAgPSBpbWcucGFyZW50RWxlbWVudDsKICAgICAgICAgICAgaWYgKHdyYXApIHdyYXAuY2xh
c3NMaXN0LnJlbW92ZSgnd2FpdGluZycpOwogICAgICAgICAgICBpbWcuc3JjID0gdXJsOwogICAgICAg
IH07CiAgICAgICAgbGV0IGhpdCA9IDA7CiAgICAgICAgZG9jdW1lbnQucXVlcnlTZWxlY3RvckFsbCgn
Lml0bVtkYXRhLWlkPSInICsga2V5ICsgJyJdIGltZy5pLXRodW1iJykuZm9yRWFjaChpbWcgPT4gewog
ICAgICAgICAgICBhcHBseShpbWcpOyBoaXQrKzsKICAgICAgICB9KTsKICAgICAgICBpZiAoIWhpdCkg
ewogICAgICAgICAgICBkb2N1bWVudC5xdWVyeVNlbGVjdG9yQWxsKCdpbWcuaS10aHVtYltkYXRhLXRo
dW1iLWlkPSInICsga2V5ICsgJyJdJykuZm9yRWFjaChhcHBseSk7CiAgICAgICAgfQogICAgfTsKCiAg
ICBmdW5jdGlvbiBpc0RyYWdFeGNsdWRlKHQpIHsKICAgICAgICByZXR1cm4gISF0LmNsb3Nlc3QoJyNz
ZWFyY2gtd3JhcCwgI2J0bi1zZWFyY2gsICNidG4tbG9jYXRlLCAjYnRuLXRvZGF5LCAjYnRuLXBpbiwg
I2J0bi1jbHIsICNtdWx0aS1jbnQsIC50YWIsIC5pdG0sICN0YWItYWN0aW9ucywgI2N0eCwgI2Nsci1k
bGcsICNwYXRoLXRpcCwgYnV0dG9uLCBpbnB1dCwgYScpOwogICAgfQogICAgZG9jdW1lbnQuZ2V0RWxl
bWVudEJ5SWQoJ2FwcCcpLmFkZEV2ZW50TGlzdGVuZXIoJ21vdXNlZG93bicsIGUgPT4gewogICAgICAg
IGlmIChlLmJ1dHRvbiAhPT0gMCkgcmV0dXJuOwogICAgICAgIGlmIChpc0RyYWdFeGNsdWRlKGUudGFy
Z2V0KSkgcmV0dXJuOwogICAgICAgIGUucHJldmVudERlZmF1bHQoKTsKICAgICAgICBhaGsoJ3N0YXJ0
RHJhZycpOwogICAgfSwgdHJ1ZSk7CgogICAgY29uc3QgaXNVcmwgID0gcyA9PiAvXmh0dHBzPzpcL1wv
L2kudGVzdCgocyB8fCAnJykudHJpbSgpKTsKCiAgICBmdW5jdGlvbiBhZ28oZGF0ZVN0cikgewogICAg
ICAgIHRyeSB7CiAgICAgICAgICAgIGNvbnN0IGQgPSBuZXcgRGF0ZShTdHJpbmcoZGF0ZVN0cikucmVw
bGFjZSgnICcsICdUJykpOwogICAgICAgICAgICBjb25zdCBzID0gKERhdGUubm93KCkgLSBkKSAvIDEw
MDAgfCAwOwogICAgICAgICAgICBpZiAocyA8IDYwKSByZXR1cm4gJ+WImuWImic7CiAgICAgICAgICAg
IGlmIChzIDwgMzYwMCkgcmV0dXJuIChzIC8gNjAgfCAwKSArICcg5YiG6ZKf5YmNJzsKICAgICAgICAg
ICAgaWYgKHMgPCA4NjQwMCkgcmV0dXJuIChzIC8gMzYwMCB8IDApICsgJyDlsI/ml7bliY0nOwogICAg
ICAgICAgICByZXR1cm4gKHMgLyA4NjQwMCB8IDApICsgJyDlpKnliY0nOwogICAgICAgIH0gY2F0Y2gg
eyByZXR1cm4gZGF0ZVN0cjsgfQogICAgfQoKICAgIGZ1bmN0aW9uIG5vcm1UeXBlKHQpIHsKICAgICAg
ICB0ID0gU3RyaW5nKHQgfHwgJycpLnRvTG93ZXJDYXNlKCk7CiAgICAgICAgaWYgKHQgPT09ICdpbWFn
ZScgfHwgdCA9PT0gJ2ltZycgfHwgdCA9PT0gJ2JpdG1hcCcpIHJldHVybiAnaW1hZ2UnOwogICAgICAg
IGlmICh0ID09PSAnZmlsZScgIHx8IHQgPT09ICdmaWxlcycpIHJldHVybiAnZmlsZSc7CiAgICAgICAg
aWYgKHQgPT09ICdyZWNlbnQnIHx8IHQgPT09ICdmb2xkZXInIHx8IHQgPT09ICdkaXInKSByZXR1cm4g
J3JlY2VudCc7CiAgICAgICAgaWYgKHQgPT09ICdsaW5rJyB8fCB0ID09PSAndXJsJykgcmV0dXJuICds
aW5rJzsKICAgICAgICByZXR1cm4gJ3RleHQnOwogICAgfQogICAgZnVuY3Rpb24gaXNQaW5uZWQoYykg
ewogICAgICAgIHJldHVybiBjLnBpbm5lZCA9PT0gdHJ1ZSB8fCBjLnBpbm5lZCA9PT0gMSB8fCBjLnBp
bm5lZCA9PT0gJ3RydWUnIHx8IGMucGlubmVkID09PSAnMSc7CiAgICB9CiAgICBmdW5jdGlvbiBpc1Bh
c3RlZChjKSB7CiAgICAgICAgcmV0dXJuIGMucGFzdGVkID09PSB0cnVlIHx8IGMucGFzdGVkID09PSAx
IHx8IGMucGFzdGVkID09PSAndHJ1ZScgfHwgYy5wYXN0ZWQgPT09ICcxJzsKICAgIH0KCiAgICBmdW5j
dGlvbiBpc01hcmtkb3duKHRleHQpIHsKICAgICAgICBpZiAoIXRleHQgfHwgdGV4dC5sZW5ndGggPCA0
KSByZXR1cm4gZmFsc2U7CiAgICAgICAgcmV0dXJuIC8oPzpefFxuKSN7MSw2fSB8XlstKitdIHxcKlwq
W14qXG5dK1wqXCp8X19bXl9cbl0rX198KD86Xnxcbik+IHxgYGB8YFteYFxuXStgfFxbW15cXV0rXF1c
KFteKV0rXCl8XHwuK1x8LitcfC9tLnRlc3QodGV4dCk7CiAgICB9CiAgICBmdW5jdGlvbiBjbGlwVXNl
c01JY29uKGMpIHsKICAgICAgICBpZiAoIWMpIHJldHVybiBmYWxzZTsKICAgICAgICBpZiAoYy5pc01k
ID09PSB0cnVlIHx8IGMuaXNNZCA9PT0gMSB8fCBjLmlzTWQgPT09ICd0cnVlJyB8fCBjLmlzTWQgPT09
ICcxJykgcmV0dXJuIHRydWU7CiAgICAgICAgaWYgKGMuaXNSaWNoID09PSB0cnVlIHx8IGMuaXNSaWNo
ID09PSAxIHx8IGMuaXNSaWNoID09PSAndHJ1ZScgfHwgYy5pc1JpY2ggPT09ICcxJykgcmV0dXJuIHRy
dWU7CiAgICAgICAgY29uc3QgdCA9IFN0cmluZyhjLnR5cGUgfHwgJycpLnRvTG93ZXJDYXNlKCk7CiAg
ICAgICAgaWYgKHQgJiYgdCAhPT0gJ3RleHQnICYmIHQgIT09ICdsaW5rJykgcmV0dXJuIGZhbHNlOwog
ICAgICAgIHJldHVybiBpc01hcmtkb3duKGMuZGF0YSB8fCBjLnByZXZpZXcgfHwgJycpOwogICAgfQog
ICAgZnVuY3Rpb24gZXNjQXR0cihzKSB7CiAgICAgICAgcmV0dXJuIFN0cmluZyhzIHx8ICcnKQogICAg
ICAgICAgICAucmVwbGFjZSgvJi9nLCAnJmFtcDsnKQogICAgICAgICAgICAucmVwbGFjZSgvIi9nLCAn
JnF1b3Q7JykKICAgICAgICAgICAgLnJlcGxhY2UoLzwvZywgJyZsdDsnKQogICAgICAgICAgICAucmVw
bGFjZSgvPi9nLCAnJmd0OycpOwogICAgfQoKICAgIGZ1bmN0aW9uIHRvZGF5UHJlZml4KCkgewogICAg
ICAgIGNvbnN0IGQgPSBuZXcgRGF0ZSgpOwogICAgICAgIGNvbnN0IHAgPSBuID0+IFN0cmluZyhuKS5w
YWRTdGFydCgyLCAnMCcpOwogICAgICAgIHJldHVybiBkLmdldEZ1bGxZZWFyKCkgKyAnLScgKyBwKGQu
Z2V0TW9udGgoKSArIDEpICsgJy0nICsgcChkLmdldERhdGUoKSk7CiAgICB9CiAgICBmdW5jdGlvbiBp
c1RvZGF5Q2xpcChjKSB7CiAgICAgICAgcmV0dXJuIFN0cmluZyhjLnRpbWUgfHwgJycpLnN0YXJ0c1dp
dGgodG9kYXlQcmVmaXgoKSk7CiAgICB9CgogICAgZnVuY3Rpb24gY2xpcEhheShjKSB7CiAgICAgICAg
cmV0dXJuIFN0cmluZyhjLnByZXZpZXcgfHwgJycpICsgJyAnICsgU3RyaW5nKGMuZGF0YSB8fCAnJykg
KyAnICcKICAgICAgICAgICAgKyBTdHJpbmcoYy5saW5rVGl0bGUgfHwgJycpICsgJyAnICsgU3RyaW5n
KGMuZmF2VGl0bGUgfHwgJycpOwogICAgfQogICAgLyoqIE1hdGNoIEFISyBJdGVtTWF0Y2hlc1ZpZXcg
bGlzdCBzZWFyY2gg4oCUIHByZXZpZXcgKCsgc2hvcnQgYm9keSBmYWxsYmFjayksIG5vdCBmdWxsIGRh
dGEgKi8KICAgIGZ1bmN0aW9uIGNsaXBTZWFyY2hIYXkoYykgewogICAgICAgIGNvbnN0IHR5cGUgPSBT
dHJpbmcoYy50eXBlIHx8ICcnKS50b0xvd2VyQ2FzZSgpOwogICAgICAgIGlmICh0eXBlID09PSAnaW1h
Z2UnKQogICAgICAgICAgICByZXR1cm4gU3RyaW5nKGMuZmF2VGl0bGUgfHwgJycpOwogICAgICAgIGlm
ICh0eXBlID09PSAnZmlsZScpIHsKICAgICAgICAgICAgcmV0dXJuIFN0cmluZyhjLnByZXZpZXcgfHwg
JycpICsgJyAnICsgU3RyaW5nKGMuZGF0YSB8fCAnJykgKyAnICcKICAgICAgICAgICAgICAgICsgU3Ry
aW5nKGMuZmF2VGl0bGUgfHwgJycpOwogICAgICAgIH0KICAgICAgICBsZXQgcHJldiA9IFN0cmluZyhj
LnByZXZpZXcgfHwgJycpOwogICAgICAgIGlmICghcHJldiAmJiBjLmRhdGEpCiAgICAgICAgICAgIHBy
ZXYgPSBTdHJpbmcoYy5kYXRhKS5zbGljZSgwLCA1MDApOwogICAgICAgIHJldHVybiBwcmV2ICsgJyAn
ICsgU3RyaW5nKGMubGlua1RpdGxlIHx8ICcnKSArICcgJyArIFN0cmluZyhjLmZhdlRpdGxlIHx8ICcn
KTsKICAgIH0KICAgIGZ1bmN0aW9uIGNsaXBNYXRjaGVzU2VhcmNoKGMsIHRlcm1MKSB7CiAgICAgICAg
Y29uc3QgdHlwZSA9IFN0cmluZyhjLnR5cGUgfHwgJycpLnRvTG93ZXJDYXNlKCk7CiAgICAgICAgY29u
c3QgaGF5ID0gKHR5cGUgPT09ICdpbWFnZScgPyBTdHJpbmcoYy5mYXZUaXRsZSB8fCAnJykgOiBjbGlw
U2VhcmNoSGF5KGMpKS50b0xvd2VyQ2FzZSgpOwogICAgICAgIHJldHVybiB0ZXJtTC5ldmVyeSh0ID0+
IGhheS5pbmNsdWRlcyh0KSk7CiAgICB9CiAgICBmdW5jdGlvbiBmaWx0ZXIoY2xpcHMsIHRhYiwgcSkg
ewogICAgICAgIC8vIOS4u+acuuW3sui/h+a7pOaXtuS7jeWBmuWJjeerr+WFnOW6le+8mumBv+WFjeer
nuaAgeaOqOadpeacquWRveS4reihjAogICAgICAgIGNvbnN0IHRlcm1zID0gcXVlcnlUZXJtcyhxKTsK
ICAgICAgICBpZiAoIXRlcm1zLmxlbmd0aCkgcmV0dXJuIGNsaXBzOwogICAgICAgIGNvbnN0IHRlcm1M
ID0gdGVybXMubWFwKHQgPT4gdC50b0xvd2VyQ2FzZSgpKTsKICAgICAgICBjb25zdCBtYXRjaGVkR3Jv
dXBzID0gbmV3IFNldCgpOwogICAgICAgIGZvciAoY29uc3QgYyBvZiBjbGlwcykgewogICAgICAgICAg
ICBpZiAoIWNsaXBNYXRjaGVzU2VhcmNoKGMsIHRlcm1MKSkgY29udGludWU7CiAgICAgICAgICAgIGNv
bnN0IGdpZCA9IFN0cmluZyhjICYmIGMuZmF2R3JvdXAgfHwgJycpLnRyaW0oKTsKICAgICAgICAgICAg
aWYgKGdpZCkgbWF0Y2hlZEdyb3Vwcy5hZGQoZ2lkKTsKICAgICAgICB9CiAgICAgICAgLy8g5ZCI5bm2
57uE77ya5YWz6ZSu5a2X5Y+v6IO95YiG5pWj5Zyo5LiN5ZCM6KGM77yI5qCH6aKYL+ato+aWh++8iQog
ICAgICAgIGNvbnN0IGJ5R3JvdXAgPSBuZXcgTWFwKCk7CiAgICAgICAgZm9yIChjb25zdCBjIG9mIGNs
aXBzKSB7CiAgICAgICAgICAgIGNvbnN0IGdpZCA9IFN0cmluZyhjICYmIGMuZmF2R3JvdXAgfHwgJycp
LnRyaW0oKTsKICAgICAgICAgICAgaWYgKCFnaWQpIGNvbnRpbnVlOwogICAgICAgICAgICBpZiAoIWJ5
R3JvdXAuaGFzKGdpZCkpIGJ5R3JvdXAuc2V0KGdpZCwgW10pOwogICAgICAgICAgICBieUdyb3VwLmdl
dChnaWQpLnB1c2goYyk7CiAgICAgICAgfQogICAgICAgIGZvciAoY29uc3QgW2dpZCwgbWVtYmVyc10g
b2YgYnlHcm91cCkgewogICAgICAgICAgICBpZiAobWF0Y2hlZEdyb3Vwcy5oYXMoZ2lkKSkgY29udGlu
dWU7CiAgICAgICAgICAgIGNvbnN0IHVuaW9uID0gbWVtYmVycy5tYXAoYyA9PiB7CiAgICAgICAgICAg
ICAgICBjb25zdCB0eXBlID0gU3RyaW5nKGMudHlwZSB8fCAnJykudG9Mb3dlckNhc2UoKTsKICAgICAg
ICAgICAgICAgIHJldHVybiAodHlwZSA9PT0gJ2ltYWdlJyA/IFN0cmluZyhjLmZhdlRpdGxlIHx8ICcn
KSA6IGNsaXBTZWFyY2hIYXkoYykpLnRvTG93ZXJDYXNlKCk7CiAgICAgICAgICAgIH0pLmpvaW4oJyAn
KTsKICAgICAgICAgICAgaWYgKHRlcm1MLmV2ZXJ5KHQgPT4gdW5pb24uaW5jbHVkZXModCkpKQogICAg
ICAgICAgICAgICAgbWF0Y2hlZEdyb3Vwcy5hZGQoZ2lkKTsKICAgICAgICB9CiAgICAgICAgcmV0dXJu
IGNsaXBzLmZpbHRlcihjID0+IHsKICAgICAgICAgICAgaWYgKGNsaXBNYXRjaGVzU2VhcmNoKGMsIHRl
cm1MKSkgcmV0dXJuIHRydWU7CiAgICAgICAgICAgIGNvbnN0IGdpZCA9IFN0cmluZyhjICYmIGMuZmF2
R3JvdXAgfHwgJycpLnRyaW0oKTsKICAgICAgICAgICAgcmV0dXJuIGdpZCAmJiBtYXRjaGVkR3JvdXBz
LmhhcyhnaWQpOwogICAgICAgIH0pOwogICAgfQoKICAgIGZ1bmN0aW9uIG1hcmtQYXN0ZWRMb2NhbChp
ZHMpIHsKICAgICAgICBjb25zdCBsaXN0ID0gQXJyYXkuaXNBcnJheShpZHMpID8gaWRzIDogW2lkc107
CiAgICAgICAgaWYgKGxpc3QubGVuZ3RoKQogICAgICAgICAgICByZW1lbWJlckxhc3RQYXN0ZShsaXN0
W2xpc3QubGVuZ3RoIC0gMV0pOwogICAgICAgIGNvbnN0IGJhZGdlSHRtbCA9IGA8c3ZnIHZpZXdCb3g9
IjAgMCAxNiAxNiIgZmlsbD0ibm9uZSIgc3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0cm9rZS13aWR0aD0i
Mi40IiBzdHJva2UtbGluZWNhcD0icm91bmQiIHN0cm9rZS1saW5lam9pbj0icm91bmQiPjxwb2x5bGlu
ZSBwb2ludHM9IjMuNSA4LjUgNi41IDExLjUgMTIuNSA0LjUiLz48L3N2Zz5gOwogICAgICAgIGxpc3Qu
Zm9yRWFjaChyYXdJZCA9PiB7CiAgICAgICAgICAgIGNvbnN0IGlkID0gK3Jhd0lkOwogICAgICAgICAg
ICBjb25zdCBjID0gYWxsQ2xpcHMuZmluZCh4ID0+ICt4LmlkID09PSBpZCk7CiAgICAgICAgICAgIGlm
IChjKSBjLnBhc3RlZCA9IHRydWU7CiAgICAgICAgICAgIGNvbnN0IHJvdyA9IGxpc3RFbCAmJiAoCiAg
ICAgICAgICAgICAgICBsaXN0RWwucXVlcnlTZWxlY3RvcignLml0bVtkYXRhLWlkPSInICsgaWQgKyAn
Il0nKQogICAgICAgICAgICAgICAgfHwgbGlzdEVsLnF1ZXJ5U2VsZWN0b3IoJy5pdG1bZGF0YS1pZD0i
JyArIFN0cmluZyhyYXdJZCkgKyAnIl0nKQogICAgICAgICAgICApOwogICAgICAgICAgICBpZiAoIXJv
dykgcmV0dXJuOwogICAgICAgICAgICByb3cuY2xhc3NMaXN0LmFkZCgncGFzdGVkJywgJ3EtZG9uZScp
OwogICAgICAgICAgICBjb25zdCBpY28gPSByb3cucXVlcnlTZWxlY3RvcignLmktaWNvJyk7CiAgICAg
ICAgICAgIGlmIChpY28gJiYgIWljby5xdWVyeVNlbGVjdG9yKCcuaS11c2VkJykpIHsKICAgICAgICAg
ICAgICAgIGNvbnN0IGJhZGdlID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnc3BhbicpOwogICAgICAg
ICAgICAgICAgYmFkZ2UuY2xhc3NOYW1lID0gJ2ktdXNlZCc7CiAgICAgICAgICAgICAgICBiYWRnZS50
aXRsZSA9ICflt7LnspjotLQnOwogICAgICAgICAgICAgICAgYmFkZ2UuaW5uZXJIVE1MID0gYmFkZ2VI
dG1sOwogICAgICAgICAgICAgICAgaWNvLmFwcGVuZENoaWxkKGJhZGdlKTsKICAgICAgICAgICAgfQog
ICAgICAgIH0pOwogICAgICAgIHRyeSB7IG1hcmtRdWV1ZVJhaWxzKCk7IH0gY2F0Y2ggKGUpIHt9CiAg
ICB9CiAgICB3aW5kb3cuX19tYXJrUGFzdGVkID0gbWFya1Bhc3RlZExvY2FsOwoKICAgIGZ1bmN0aW9u
IG1hcmtVbnBhc3RlZExvY2FsKGlkcykgewogICAgICAgIGNvbnN0IGxpc3QgPSBBcnJheS5pc0FycmF5
KGlkcykgPyBpZHMgOiBbaWRzXTsKICAgICAgICBsaXN0LmZvckVhY2gocmF3SWQgPT4gewogICAgICAg
ICAgICBjb25zdCBpZCA9ICtyYXdJZDsKICAgICAgICAgICAgY29uc3QgYyA9IGFsbENsaXBzLmZpbmQo
eCA9PiAreC5pZCA9PT0gaWQpOwogICAgICAgICAgICBpZiAoYykgYy5wYXN0ZWQgPSBmYWxzZTsKICAg
ICAgICAgICAgY29uc3Qgcm93ID0gbGlzdEVsICYmICgKICAgICAgICAgICAgICAgIGxpc3RFbC5xdWVy
eVNlbGVjdG9yKCcuaXRtW2RhdGEtaWQ9IicgKyBpZCArICciXScpCiAgICAgICAgICAgICAgICB8fCBs
aXN0RWwucXVlcnlTZWxlY3RvcignLml0bVtkYXRhLWlkPSInICsgU3RyaW5nKHJhd0lkKSArICciXScp
CiAgICAgICAgICAgICk7CiAgICAgICAgICAgIGlmICghcm93KSByZXR1cm47CiAgICAgICAgICAgIHJv
dy5jbGFzc0xpc3QucmVtb3ZlKCdwYXN0ZWQnLCAncS1kb25lJywgJ3EtZG9uZS1saW5rJyk7CiAgICAg
ICAgICAgIGNvbnN0IGJhZGdlID0gcm93LnF1ZXJ5U2VsZWN0b3IoJy5pLXVzZWQnKTsKICAgICAgICAg
ICAgaWYgKGJhZGdlKSBiYWRnZS5yZW1vdmUoKTsKICAgICAgICAgICAgY29uc3QgZG90ID0gcm93LnF1
ZXJ5U2VsZWN0b3IoJy5xLWRvdCcpOwogICAgICAgICAgICBpZiAoZG90KSBkb3QudGl0bGUgPSAn57KY
6LS06Zif5YiXJzsKICAgICAgICB9KTsKICAgICAgICB0cnkgeyBtYXJrUXVldWVSYWlscygpOyB9IGNh
dGNoIChlKSB7fQogICAgfQogICAgd2luZG93Ll9fbWFya1VucGFzdGVkID0gbWFya1VucGFzdGVkTG9j
YWw7CgogICAgY29uc3QgbGlzdEVsICA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdsaXN0Jyk7CiAg
ICBjb25zdCBlbXB0eUVsID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2VtcHR5Jyk7CiAgICBjb25z
dCBza2VsRWwgID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NrZWwnKTsKICAgIGNvbnN0IGJ0blRv
cCAgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYnRuLXRvcCcpOwogICAgZnVuY3Rpb24gc2V0Qm9v
dExvYWRpbmcob24pIHsKICAgICAgICBib290TG9hZGluZyA9ICEhb247CiAgICAgICAgLy8g56eS5byA
77ya5LiN5YaN5omT5byA6aqo5p626Zeq5Yqo77yb5Y+q5L+d55WZIHdhaXRpbmdEYXRhIOmAu+i+kemY
suepuuaAgeivr+mXqgogICAgICAgIGlmIChza2VsRWwpIHNrZWxFbC5jbGFzc0xpc3QucmVtb3ZlKCdv
bicpOwogICAgICAgIGlmIChvbiAmJiBlbXB0eUVsKSBlbXB0eUVsLmNsYXNzTGlzdC5yZW1vdmUoJ29u
Jyk7CiAgICAgICAgY29uc3QgYXBwID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2FwcCcpOwogICAg
ICAgIGlmIChhcHApIGFwcC5jbGFzc0xpc3QucmVtb3ZlKCdib290LWxvYWRpbmcnKTsKICAgIH0KICAg
IC8qKiBXYWl0IGZvciBob3N0IGRhdGEg4oCU5LiN5YaN56uL5Yi75by56aqo5p6277yM5pyJ5YaF5a65
5pe25L+d5oyB5pen5YiX6KGoICovCiAgICBmdW5jdGlvbiBzY2hlZHVsZURlbGF5ZWRTa2VsKCkgewog
ICAgICAgIHdhaXRpbmdEYXRhID0gdHJ1ZTsKICAgICAgICB3aW5kb3cuX19kYXRhUmVhZHkgPSBmYWxz
ZTsKICAgICAgICBpZiAoZW1wdHlFbCkgZW1wdHlFbC5jbGFzc0xpc3QucmVtb3ZlKCdvbicpOwogICAg
ICAgIGlmICh3aW5kb3cuX19wZW5kaW5nU2tlbFRpbWVyKSB7CiAgICAgICAgICAgIGNsZWFyVGltZW91
dCh3aW5kb3cuX19wZW5kaW5nU2tlbFRpbWVyKTsKICAgICAgICAgICAgd2luZG93Ll9fcGVuZGluZ1Nr
ZWxUaW1lciA9IDA7CiAgICAgICAgfQogICAgICAgIHdpbmRvdy5fX3BlbmRpbmdTa2VsU2luY2UgPSBE
YXRlLm5vdygpOwogICAgICAgIC8vIOacieaXp+WIl+ihqOWwseS/neeVme+8m+epuuWIl+ihqOS5n+S4
jeWGjeaSremqqOaetuWKqOeUuwogICAgfQogICAgZnVuY3Rpb24gY2xlYXJXYWl0aW5nRGF0YSgpIHsK
ICAgICAgICB3YWl0aW5nRGF0YSA9IGZhbHNlOwogICAgICAgIGlmICh3aW5kb3cuX19wZW5kaW5nU2tl
bFRpbWVyKSB7CiAgICAgICAgICAgIGNsZWFyVGltZW91dCh3aW5kb3cuX19wZW5kaW5nU2tlbFRpbWVy
KTsKICAgICAgICAgICAgd2luZG93Ll9fcGVuZGluZ1NrZWxUaW1lciA9IDA7CiAgICAgICAgfQogICAg
ICAgIHdpbmRvdy5fX3BlbmRpbmdTa2VsU2luY2UgPSAwOwogICAgICAgIHNldEJvb3RMb2FkaW5nKGZh
bHNlKTsKICAgIH0KICAgIHdpbmRvdy5zZXRCb290TG9hZGluZyA9IHNldEJvb3RMb2FkaW5nOwogICAg
d2luZG93LmZvcmNlRW5kQm9vdExvYWRpbmcgPSBmdW5jdGlvbigpIHsKICAgICAgICBjbGVhcldhaXRp
bmdEYXRhKCk7CiAgICAgICAgLy8gRG8gbm90IGZha2XjgIzmmoLml6DorrDlvZXjgI1pZiBob3N0IG5l
dmVyIHB1c2hlZAogICAgICAgIGlmIChob3N0UHVzaGVkT25jZSkKICAgICAgICAgICAgd2luZG93Ll9f
ZGF0YVJlYWR5ID0gdHJ1ZTsKICAgICAgICB0cnkgeyByZW5kZXIoKTsgfSBjYXRjaCAoZSkge30KICAg
IH07CiAgICAvLyBTYWZldHk6IGRyb3Agc3R1Y2sgc2tlbGV0b247IHN0aWxsIG5ldmVyIGludmVudCBl
bXB0eS1zdGF0ZSB3aXRob3V0IGhvc3QgcHVzaAogICAgc2V0VGltZW91dCgoKSA9PiB7CiAgICAgICAg
aWYgKGhvc3RQdXNoZWRPbmNlIHx8IHdpbmRvdy5fX2RhdGFSZWFkeSkgcmV0dXJuOwogICAgICAgIGlm
ICghYm9vdExvYWRpbmcgJiYgIXdhaXRpbmdEYXRhKSByZXR1cm47CiAgICAgICAgY2xlYXJXYWl0aW5n
RGF0YSgpOwogICAgICAgIHRyeSB7IHJlbmRlcigpOyB9IGNhdGNoIHt9CiAgICB9LCA4MDAwKTsKCiAg
ICBmdW5jdGlvbiB1cGRhdGVUb3BCdG4oKSB7CiAgICAgICAgaWYgKCFidG5Ub3AgfHwgIWxpc3RFbCkg
cmV0dXJuOwogICAgICAgIGJ0blRvcC5jbGFzc0xpc3QudG9nZ2xlKCdvbicsIGxpc3RFbC5zY3JvbGxU
b3AgPiA0OCk7CiAgICB9CiAgICBsZXQgX3Njcm9sbFJhZiA9IDA7CiAgICBsZXQgX3Njcm9sbElkbGVU
ID0gMDsKICAgIGxldCBfbGlzdFB0ckRvd24gPSBmYWxzZTsKICAgIGxldCBfcGVuZGluZ0FwcGVuZCA9
IG51bGw7IC8vIHsgZnJvbUxlbiB9IHF1ZXVlZCB3aGlsZSBzY3JvbGxpbmcKICAgIHdpbmRvdy5fX3Nj
cm9sbEJ1c3kgPSBmYWxzZTsKICAgIHdpbmRvdy5fX3dhbnRNb3JlID0gZmFsc2U7CgogICAgZnVuY3Rp
b24gbWFya0xpc3RTY3JvbGxpbmcoKSB7CiAgICAgICAgd2luZG93Ll9fc2Nyb2xsQnVzeSA9IHRydWU7
CiAgICAgICAgdHJ5IHsgbGlzdEVsLmNsYXNzTGlzdC5hZGQoJ2lzLXNjcm9sbGluZycpOyB9IGNhdGNo
IHt9CiAgICAgICAgaWYgKF9zY3JvbGxJZGxlVCkgY2xlYXJUaW1lb3V0KF9zY3JvbGxJZGxlVCk7CiAg
ICAgICAgX3Njcm9sbElkbGVUID0gc2V0VGltZW91dCgoKSA9PiB7CiAgICAgICAgICAgIF9zY3JvbGxJ
ZGxlVCA9IDA7CiAgICAgICAgICAgIGZsdXNoU2Nyb2xsSWRsZSgpOwogICAgICAgIH0sIDIyMCk7CiAg
ICB9CgogICAgZnVuY3Rpb24gZmx1c2hTY3JvbGxJZGxlKCkgewogICAgICAgIGlmIChfbGlzdFB0ckRv
d24pIHsKICAgICAgICAgICAgbWFya0xpc3RTY3JvbGxpbmcoKTsKICAgICAgICAgICAgcmV0dXJuOwog
ICAgICAgIH0KICAgICAgICB3aW5kb3cuX19zY3JvbGxCdXN5ID0gZmFsc2U7CiAgICAgICAgdHJ5IHsg
bGlzdEVsLmNsYXNzTGlzdC5yZW1vdmUoJ2lzLXNjcm9sbGluZycpOyB9IGNhdGNoIHt9CiAgICAgICAg
aWYgKF9wZW5kaW5nQXBwZW5kKSB7CiAgICAgICAgICAgIGNvbnN0IHBlbmRpbmcgPSBfcGVuZGluZ0Fw
cGVuZDsKICAgICAgICAgICAgX3BlbmRpbmdBcHBlbmQgPSBudWxsOwogICAgICAgICAgICBhcHBseUFw
cGVuZFBheWxvYWQocGVuZGluZyk7CiAgICAgICAgfQogICAgICAgIGlmICh3aW5kb3cuX193YW50TW9y
ZSkKICAgICAgICAgICAgcmVxdWVzdE1vcmUoKTsKICAgICAgICBlbHNlIGlmICghbG9hZGluZ01vcmUK
ICAgICAgICAgICAgJiYgZGlza1RvdGFsID4gMAogICAgICAgICAgICAmJiBhbGxDbGlwcy5sZW5ndGgg
PCBkaXNrVG90YWwKICAgICAgICAgICAgJiYgbGlzdEVsLnNjcm9sbFRvcCArIGxpc3RFbC5jbGllbnRI
ZWlnaHQgPj0gbGlzdEVsLnNjcm9sbEhlaWdodCAtIDQyMCkKICAgICAgICAgICAgcmVxdWVzdE1vcmUo
KTsKICAgIH0KCiAgICBmdW5jdGlvbiBvbkxpc3RTY3JvbGwoKSB7CiAgICAgICAgbWFya0xpc3RTY3Jv
bGxpbmcoKTsKICAgICAgICBpZiAoX3Njcm9sbFJhZikgcmV0dXJuOwogICAgICAgIF9zY3JvbGxSYWYg
PSByZXF1ZXN0QW5pbWF0aW9uRnJhbWUoKCkgPT4gewogICAgICAgICAgICBfc2Nyb2xsUmFmID0gMDsK
ICAgICAgICAgICAgdHJ5IHsgaGlkZVBhdGhUaXAoKTsgfSBjYXRjaCB7fQogICAgICAgICAgICB1cGRh
dGVUb3BCdG4oKTsKICAgICAgICAgICAgaWYgKCFsb2FkaW5nTW9yZQogICAgICAgICAgICAgICAgJiYg
ZGlza1RvdGFsID4gMAogICAgICAgICAgICAgICAgJiYgYWxsQ2xpcHMubGVuZ3RoIDwgZGlza1RvdGFs
CiAgICAgICAgICAgICAgICAmJiBsaXN0RWwuc2Nyb2xsVG9wICsgbGlzdEVsLmNsaWVudEhlaWdodCA+
PSBsaXN0RWwuc2Nyb2xsSGVpZ2h0IC0gMjQwKQogICAgICAgICAgICAgICAgd2luZG93Ll9fd2FudE1v
cmUgPSB0cnVlOwogICAgICAgIH0pOwogICAgfQogICAgbGlzdEVsLmFkZEV2ZW50TGlzdGVuZXIoJ3Nj
cm9sbCcsIG9uTGlzdFNjcm9sbCwgeyBwYXNzaXZlOiB0cnVlIH0pOwogICAgbGlzdEVsLmFkZEV2ZW50
TGlzdGVuZXIoJ3doZWVsJywgbWFya0xpc3RTY3JvbGxpbmcsIHsgcGFzc2l2ZTogdHJ1ZSB9KTsKICAg
IGxpc3RFbC5hZGRFdmVudExpc3RlbmVyKCdwb2ludGVyZG93bicsIGUgPT4gewogICAgICAgIGlmIChl
LmJ1dHRvbiAhPT0gMCkgcmV0dXJuOwogICAgICAgIF9saXN0UHRyRG93biA9IHRydWU7CiAgICAgICAg
bWFya0xpc3RTY3JvbGxpbmcoKTsKICAgIH0sIHsgcGFzc2l2ZTogdHJ1ZSB9KTsKICAgIHdpbmRvdy5h
ZGRFdmVudExpc3RlbmVyKCdwb2ludGVydXAnLCAoKSA9PiB7CiAgICAgICAgaWYgKCFfbGlzdFB0ckRv
d24pIHJldHVybjsKICAgICAgICBfbGlzdFB0ckRvd24gPSBmYWxzZTsKICAgICAgICBtYXJrTGlzdFNj
cm9sbGluZygpOwogICAgfSwgeyBwYXNzaXZlOiB0cnVlIH0pOwogICAgd2luZG93LmFkZEV2ZW50TGlz
dGVuZXIoJ3BvaW50ZXJjYW5jZWwnLCAoKSA9PiB7CiAgICAgICAgaWYgKCFfbGlzdFB0ckRvd24pIHJl
dHVybjsKICAgICAgICBfbGlzdFB0ckRvd24gPSBmYWxzZTsKICAgICAgICBtYXJrTGlzdFNjcm9sbGlu
ZygpOwogICAgfSwgeyBwYXNzaXZlOiB0cnVlIH0pOwogICAgYnRuVG9wLmFkZEV2ZW50TGlzdGVuZXIo
J2NsaWNrJywgZSA9PiB7CiAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICBsaXN0RWwu
c2Nyb2xsVG8oeyB0b3A6IDAsIGJlaGF2aW9yOiAnc21vb3RoJyB9KTsKICAgIH0pOwoKICAgIGZ1bmN0
aW9uIHZpc2libGVMaXN0KCkgewogICAgICAgIGNvbnN0IHEgPSBTdHJpbmcocXVlcnkgfHwgJycpLnRy
aW0oKTsKICAgICAgICAvLyBIb3N0IGFscmVhZHkgZmlsdGVyZWQrZXhwYW5kZWQgZm9yIHRoaXMgZXhh
Y3QgcXVlcnkg4oCUIGRvbid0IHJlLWZpbHRlciAoYXZvaWRzIGZsYXNoIC8gZHJvcHBlZCBmYXYgZ3Jv
dXBzKQogICAgICAgIGlmIChxICYmIHdpbmRvdy5fX2hvc3RGaWx0ZXJlZCAmJiB3aW5kb3cuX19ob3N0
RmlsdGVyUSA9PT0gcSkKICAgICAgICAgICAgcmV0dXJuIGFsbENsaXBzOwogICAgICAgIHJldHVybiBm
aWx0ZXIoYWxsQ2xpcHMsIGN1clRhYiwgcXVlcnkpOwogICAgfQogICAgZnVuY3Rpb24gZXNjSHRtbChz
KSB7CiAgICAgICAgcmV0dXJuIFN0cmluZyhzID8/ICcnKS5yZXBsYWNlKC8mL2csJyZhbXA7JykucmVw
bGFjZSgvPC9nLCcmbHQ7JykucmVwbGFjZSgvPi9nLCcmZ3Q7JykucmVwbGFjZSgvIi9nLCcmcXVvdDsn
KTsKICAgIH0KICAgIGZ1bmN0aW9uIHF1ZXJ5VGVybXMocSkgewogICAgICAgIGNvbnN0IG91dCA9IFtd
OwogICAgICAgIGZvciAoY29uc3Qgc2VnIG9mIFN0cmluZyhxIHx8ICcnKS5zcGxpdCgnfCcpKSB7CiAg
ICAgICAgICAgIGNvbnN0IHMgPSBzZWcudHJpbSgpOwogICAgICAgICAgICBpZiAoIXMpIGNvbnRpbnVl
OwogICAgICAgICAgICBjb25zdCB3b3JkcyA9IHMuc3BsaXQoL1xzKy8pLmZpbHRlcihCb29sZWFuKTsK
ICAgICAgICAgICAgaWYgKHdvcmRzLmxlbmd0aCkgb3V0LnB1c2goLi4ud29yZHMpOwogICAgICAgIH0K
ICAgICAgICByZXR1cm4gb3V0OwogICAgfQogICAgZnVuY3Rpb24gaGxIdG1sKHRleHQpIHsKICAgICAg
ICBjb25zdCB0ZXJtcyA9IHF1ZXJ5VGVybXMocXVlcnkpOwogICAgICAgIGNvbnN0IHMgPSBTdHJpbmco
dGV4dCA/PyAnJyk7CiAgICAgICAgaWYgKCF0ZXJtcy5sZW5ndGgpIHJldHVybiBlc2NIdG1sKHMpOwog
ICAgICAgIGNvbnN0IGxvd2VyID0gcy50b0xvd2VyQ2FzZSgpOwogICAgICAgIGNvbnN0IHRlcm1MID0g
dGVybXMubWFwKHQgPT4gdC50b0xvd2VyQ2FzZSgpKTsKICAgICAgICBsZXQgb3V0ID0gJycsIGkgPSAw
OwogICAgICAgIHdoaWxlIChpIDwgcy5sZW5ndGgpIHsKICAgICAgICAgICAgbGV0IGJlc3RKID0gLTEs
IGJlc3RMZW4gPSAwOwogICAgICAgICAgICBmb3IgKGxldCB0aSA9IDA7IHRpIDwgdGVybUwubGVuZ3Ro
OyB0aSsrKSB7CiAgICAgICAgICAgICAgICBjb25zdCB0ID0gdGVybUxbdGldOwogICAgICAgICAgICAg
ICAgaWYgKCF0KSBjb250aW51ZTsKICAgICAgICAgICAgICAgIGNvbnN0IGogPSBsb3dlci5pbmRleE9m
KHQsIGkpOwogICAgICAgICAgICAgICAgaWYgKGogPCAwKSBjb250aW51ZTsKICAgICAgICAgICAgICAg
IGlmIChiZXN0SiA8IDAgfHwgaiA8IGJlc3RKIHx8IChqID09PSBiZXN0SiAmJiB0Lmxlbmd0aCA+IGJl
c3RMZW4pKSB7CiAgICAgICAgICAgICAgICAgICAgYmVzdEogPSBqOyBiZXN0TGVuID0gdC5sZW5ndGg7
CiAgICAgICAgICAgICAgICB9CiAgICAgICAgICAgIH0KICAgICAgICAgICAgaWYgKGJlc3RKIDwgMCkg
eyBvdXQgKz0gZXNjSHRtbChzLnNsaWNlKGkpKTsgYnJlYWs7IH0KICAgICAgICAgICAgb3V0ICs9IGVz
Y0h0bWwocy5zbGljZShpLCBiZXN0SikpOwogICAgICAgICAgICBvdXQgKz0gJzxtYXJrIGNsYXNzPSJx
LWhsIj4nICsgZXNjSHRtbChzLnNsaWNlKGJlc3RKLCBiZXN0SiArIGJlc3RMZW4pKSArICc8L21hcms+
JzsKICAgICAgICAgICAgaSA9IGJlc3RKICsgTWF0aC5tYXgoMSwgYmVzdExlbik7CiAgICAgICAgfQog
ICAgICAgIHJldHVybiBvdXQ7CiAgICB9CiAgICBmdW5jdGlvbiBzZXRIbFRleHQoZWwsIHRleHQpIHsK
ICAgICAgICBpZiAoIWVsKSByZXR1cm47CiAgICAgICAgY29uc3QgcSA9IFN0cmluZyhxdWVyeSB8fCAn
JykudHJpbSgpOwogICAgICAgIGlmICghcSkgewogICAgICAgICAgICBlbC5jbGFzc0xpc3QucmVtb3Zl
KCdoYXMtaGwnKTsKICAgICAgICAgICAgZWwudGV4dENvbnRlbnQgPSB0ZXh0ID09IG51bGwgPyAnJyA6
IFN0cmluZyh0ZXh0KTsKICAgICAgICAgICAgcmV0dXJuOwogICAgICAgIH0KICAgICAgICBlbC5jbGFz
c0xpc3QuYWRkKCdoYXMtaGwnKTsKICAgICAgICBlbC5pbm5lckhUTUwgPSBobEh0bWwodGV4dCk7CiAg
ICB9CgoKICAgIGZ1bmN0aW9uIGFwcGx5VGFiU3dpdGNoQW5pbSgpIHsKICAgICAgICBpZiAoIXRhYlN3
aXRjaEFuaW1EaXIgfHwgIWxpc3RFbCkgcmV0dXJuOwogICAgICAgIGlmICghbGlzdEVsLnF1ZXJ5U2Vs
ZWN0b3IoJy5pdG0sICNlbXB0eS5vbiwgI2xpc3QtbW9yZScpKQogICAgICAgICAgICByZXR1cm47CiAg
ICAgICAgY29uc3QgZGlyID0gdGFiU3dpdGNoQW5pbURpcjsKICAgICAgICB0YWJTd2l0Y2hBbmltRGly
ID0gMDsKICAgICAgICBsaXN0RWwuY2xhc3NMaXN0LnJlbW92ZSgndGFiLWluLWxyJywgJ3RhYi1pbi1y
bCcpOwogICAgICAgIHZvaWQgbGlzdEVsLm9mZnNldFdpZHRoOwogICAgICAgIGxpc3RFbC5jbGFzc0xp
c3QuYWRkKGRpciA+IDAgPyAndGFiLWluLWxyJyA6ICd0YWItaW4tcmwnKTsKICAgICAgICBjbGVhclRp
bWVvdXQobGlzdEVsLl90YWJBbmltVGltZXIpOwogICAgICAgIGxpc3RFbC5fdGFiQW5pbVRpbWVyID0g
c2V0VGltZW91dCgoKSA9PiB7CiAgICAgICAgICAgIGxpc3RFbC5jbGFzc0xpc3QucmVtb3ZlKCd0YWIt
aW4tbHInLCAndGFiLWluLXJsJyk7CiAgICAgICAgfSwgNDAwKTsKICAgIH0KCiAgICBmdW5jdGlvbiB0
YWJJbmRleCh0YWIpIHsKICAgICAgICBjb25zdCBpID0gVEFCX09SREVSLmluZGV4T2YodGFiKTsKICAg
ICAgICByZXR1cm4gaSA+PSAwID8gaSA6IDA7CiAgICB9CgogICAgZnVuY3Rpb24gbW92ZVRhYkluayhp
bnN0YW50LCB0YXJnZXRFbCkgewogICAgICAgIGNvbnN0IGluayA9IGRvY3VtZW50LmdldEVsZW1lbnRC
eUlkKCd0YWItaW5rJyk7CiAgICAgICAgY29uc3QgdGFicyA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlk
KCd0YWJzJyk7CiAgICAgICAgY29uc3QgZWwgPSB0YXJnZXRFbCB8fCBkb2N1bWVudC5xdWVyeVNlbGVj
dG9yKCcjdGFicyAudGFiLm9uJyk7CiAgICAgICAgaWYgKCFpbmsgfHwgIXRhYnMgfHwgIWVsKSByZXR1
cm47CiAgICAgICAgY29uc3QgdHIgPSB0YWJzLmdldEJvdW5kaW5nQ2xpZW50UmVjdCgpOwogICAgICAg
IGNvbnN0IHIgPSBlbC5nZXRCb3VuZGluZ0NsaWVudFJlY3QoKTsKICAgICAgICBjb25zdCB4ID0gci5s
ZWZ0IC0gdHIubGVmdDsKICAgICAgICBjb25zdCBoID0gTWF0aC5tYXgoMjAsIE1hdGgucm91bmQoci5o
ZWlnaHQpKTsKICAgICAgICBjb25zdCB5ID0gci50b3AgLSB0ci50b3A7CiAgICAgICAgY29uc3QgdyA9
IE1hdGgubWF4KDI0LCByLndpZHRoKTsKICAgICAgICBjb25zdCBwb3MgPSAndHJhbnNsYXRlM2QoJyAr
IHggKyAncHgsJyArIHkgKyAncHgsMCknOwogICAgICAgIGluay5zdHlsZS50cmFuc2Zvcm1PcmlnaW4g
PSAnY2VudGVyIGJvdHRvbSc7CiAgICAgICAgaW5rLnN0eWxlLndpZHRoID0gdyArICdweCc7CiAgICAg
ICAgaW5rLnN0eWxlLmhlaWdodCA9IGggKyAncHgnOwogICAgICAgIGlmIChpbnN0YW50KSB7CiAgICAg
ICAgICAgIGluay5zdHlsZS50cmFuc2l0aW9uID0gJ25vbmUnOwogICAgICAgICAgICBpbmsuY2xhc3NM
aXN0LnJlbW92ZSgnc3F1YXNoJyk7CiAgICAgICAgICAgIGluay5zdHlsZS50cmFuc2Zvcm0gPSBwb3Mg
KyAnIHNjYWxlWCgxKSc7CiAgICAgICAgICAgIGluay5vZmZzZXRIZWlnaHQ7CiAgICAgICAgICAgIGlu
ay5zdHlsZS50cmFuc2l0aW9uID0gJyc7CiAgICAgICAgICAgIHJldHVybjsKICAgICAgICB9CiAgICAg
ICAgLy8gU25hcCB0byBob3ZlcmVkIHRhYiwgZXhwYW5kIGZyb20gYm90dG9tLWNlbnRlciDigJQgbm8g
c2xpZGluZyBiZXR3ZWVuIHRhYnMKICAgICAgICBpbmsuc3R5bGUudHJhbnNpdGlvbiA9ICdub25lJzsK
ICAgICAgICBpbmsuc3R5bGUudHJhbnNmb3JtID0gcG9zICsgJyBzY2FsZVgoMC4wMDEpJzsKICAgICAg
ICBpbmsub2Zmc2V0SGVpZ2h0OwogICAgICAgIGluay5zdHlsZS50cmFuc2l0aW9uID0gJyc7CiAgICAg
ICAgaW5rLmNsYXNzTGlzdC5hZGQoJ3NxdWFzaCcpOwogICAgICAgIGluay5zdHlsZS50cmFuc2Zvcm0g
PSBwb3MgKyAnIHNjYWxlWCgxKSc7CiAgICAgICAgY2xlYXJUaW1lb3V0KGluay5fc3F1YXNoVGltZXIp
OwogICAgICAgIGluay5fc3F1YXNoVGltZXIgPSBzZXRUaW1lb3V0KCgpID0+IGluay5jbGFzc0xpc3Qu
cmVtb3ZlKCdzcXVhc2gnKSwgMzQwKTsKICAgIH0KICAgIGZ1bmN0aW9uIG1hcmtUYWIodGFiLCBpbnN0
YW50KSB7CiAgICAgICAgZG9jdW1lbnQucXVlcnlTZWxlY3RvckFsbCgnI3RhYnMgLnRhYicpLmZvckVh
Y2goZWwgPT4KICAgICAgICAgICAgZWwuY2xhc3NMaXN0LnRvZ2dsZSgnb24nLCBlbC5kYXRhc2V0LnRh
YiA9PT0gdGFiKSk7CiAgICAgICAgbW92ZVRhYkluayghIWluc3RhbnQpOwogICAgfQogICAgZnVuY3Rp
b24gYmluZFRhYklua0hvdmVyKCkgewogICAgICAgIGNvbnN0IHRhYnMgPSBkb2N1bWVudC5nZXRFbGVt
ZW50QnlJZCgndGFicycpOwogICAgICAgIGlmICghdGFicyB8fCB0YWJzLl9pbmtIb3ZlckJvdW5kKSBy
ZXR1cm47CiAgICAgICAgdGFicy5faW5rSG92ZXJCb3VuZCA9IHRydWU7CiAgICAgICAgdGFicy5hZGRF
dmVudExpc3RlbmVyKCdwb2ludGVyb3ZlcicsIGUgPT4gewogICAgICAgICAgICBjb25zdCB0YWIgPSBl
LnRhcmdldC5jbG9zZXN0KCcudGFiJyk7CiAgICAgICAgICAgIGlmICghdGFiIHx8ICF0YWJzLmNvbnRh
aW5zKHRhYikpIHJldHVybjsKICAgICAgICAgICAgbW92ZVRhYkluayhmYWxzZSwgdGFiKTsKICAgICAg
ICB9KTsKICAgICAgICB0YWJzLmFkZEV2ZW50TGlzdGVuZXIoJ3BvaW50ZXJsZWF2ZScsIGUgPT4gewog
ICAgICAgICAgICBpZiAoZS5yZWxhdGVkVGFyZ2V0ICYmIHRhYnMuY29udGFpbnMoZS5yZWxhdGVkVGFy
Z2V0KSkgcmV0dXJuOwogICAgICAgICAgICBtb3ZlVGFiSW5rKGZhbHNlKTsKICAgICAgICB9KTsKICAg
IH0KZnVuY3Rpb24gc2V0VGFiKHRhYikgewogICAgICAgIGlmICh0YWIgPT09IGN1clRhYikgcmV0dXJu
OwogICAgICAgIGNvbnN0IGZyb20gPSB0YWJJbmRleChjdXJUYWIpOwogICAgICAgIGNvbnN0IHRvID0g
dGFiSW5kZXgodGFiKTsKICAgICAgICB0YWJTd2l0Y2hBbmltRGlyID0gdG8gPiBmcm9tID8gMSA6ICh0
byA8IGZyb20gPyAtMSA6IDApOwogICAgICAgIGN1clRhYiA9IHRhYjsKICAgICAgICBsb2FkaW5nTW9y
ZSA9IGZhbHNlOwogICAgICAgIG1hcmtUYWIodGFiKTsKCiAgICAgICAgLy8gS2VlcCBzZWFyY2ggInRv
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
IGlzUGlubmVkKGMpKS5sZW5ndGg7CiAgICAgICAgfQogICAgICAgIGNvbnN0IHBpbkNudCA9IGRvY3Vt
ZW50LmdldEVsZW1lbnRCeUlkKCdwaW4tY250Jyk7CiAgICAgICAgaWYgKHBpbkNudCkgewogICAgICAg
ICAgICBwaW5DbnQudGV4dENvbnRlbnQgPSBwaW5uZWROOwogICAgICAgICAgICBwaW5DbnQuc3R5bGUu
ZGlzcGxheSA9IHBpbm5lZE4gPyAnJyA6ICdub25lJzsKICAgICAgICB9CiAgICAgICAgbGV0IHNob3dU
b3RhbCA9IGRpc2tUb3RhbCA+IDAgPyBkaXNrVG90YWwgOiAobG9hZGVkIHx8IDApOwogICAgICAgIGlm
IChjdXJUYWIgPT09ICdwaW5uZWQnICYmIHBpbm5lZE4gPiBzaG93VG90YWwpCiAgICAgICAgICAgIHNo
b3dUb3RhbCA9IHBpbm5lZE47CiAgICAgICAgY29uc3QgcU9uID0gU3RyaW5nKHF1ZXJ5IHx8ICcnKS50
cmltKCkubGVuZ3RoID4gMDsKICAgICAgICBjb25zdCBiYXIgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJ
ZCgnYmFyLXR4dCcpOwogICAgICAgIGlmIChiYXIpIHsKICAgICAgICAgICAgYmFyLnRleHRDb250ZW50
ID0gcU9uCiAgICAgICAgICAgICAgICA/IChzaG93bkNvdW50ICsgJyDmnaEnKQogICAgICAgICAgICAg
ICAgOiAoc2hvd1RvdGFsID4gbG9hZGVkID8gKHNob3duQ291bnQgKyAnIC8gJyArIHNob3dUb3RhbCAr
ICcg5p2hJykgOiAoc2hvd1RvdGFsICsgJyDmnaEnKSk7CiAgICAgICAgfQogICAgICAgIHVwZGF0ZU1v
cmVGb290ZXIoZGlza1RvdGFsKTsKICAgICAgICB1cGRhdGVUb3BCdG4oKTsKICAgIH0KCiAgICAvKioK
ICAgICAqIExvYWQtbW9yZTogYXBwZW5kIG9ubHkgbmV3IERPTSBub2Rlcy4gRnVsbCByZW5kZXIoKSBu
dWtlcyBldmVyeSAuaXRtIGFuZAogICAgICogcmVzdG9yZXMgc2Nyb2xsVG9wIOKAlCB0aGF0IGhpdGNo
IGlzIHdoYXQgbWFrZXMgZHJhZ2dpbmcgdGhlIHNjcm9sbGJhciBmZWVsIHN0aWNreS4KICAgICAqLwog
ICAgZnVuY3Rpb24gYXBwZW5kUmVuZGVyKHByZXZMZW4pIHsKICAgICAgICBjb25zdCB2aXNpYmxlID0g
dmlzaWJsZUxpc3QoKTsKICAgICAgICBpZiAoIXZpc2libGUubGVuZ3RoKSB7CiAgICAgICAgICAgIHJl
bmRlcigpOwogICAgICAgICAgICByZXR1cm4gZmFsc2U7CiAgICAgICAgfQogICAgICAgIGlmIChwcmV2
TGVuID4gMCAmJiBwcmV2TGVuIDwgYWxsQ2xpcHMubGVuZ3RoKSB7CiAgICAgICAgICAgIGNvbnN0IHNl
YW1HaWRzID0gbmV3IFNldCgpOwogICAgICAgICAgICBmb3IgKGxldCBpID0gTWF0aC5tYXgoMCwgcHJl
dkxlbiAtIDgpOyBpIDwgTWF0aC5taW4oYWxsQ2xpcHMubGVuZ3RoLCBwcmV2TGVuICsgOCk7IGkrKykg
ewogICAgICAgICAgICAgICAgY29uc3QgZyA9IGZhdkdyb3VwT2YoYWxsQ2xpcHNbaV0pOwogICAgICAg
ICAgICAgICAgaWYgKGcpIHNlYW1HaWRzLmFkZChnKTsKICAgICAgICAgICAgfQogICAgICAgICAgICBp
ZiAoc2VhbUdpZHMuc2l6ZSkgewogICAgICAgICAgICAgICAgZm9yIChjb25zdCBnIG9mIHNlYW1HaWRz
KSB7CiAgICAgICAgICAgICAgICAgICAgbGV0IGJlZm9yZSA9IDAsIGFmdGVyID0gMDsKICAgICAgICAg
ICAgICAgICAgICBmb3IgKGxldCBpID0gMDsgaSA8IGFsbENsaXBzLmxlbmd0aDsgaSsrKSB7CiAgICAg
ICAgICAgICAgICAgICAgICAgIGlmIChmYXZHcm91cE9mKGFsbENsaXBzW2ldKSAhPT0gZykgY29udGlu
dWU7CiAgICAgICAgICAgICAgICAgICAgICAgIGlmIChpIDwgcHJldkxlbikgYmVmb3JlKys7CiAgICAg
ICAgICAgICAgICAgICAgICAgIGVsc2UgYWZ0ZXIrKzsKICAgICAgICAgICAgICAgICAgICB9CiAgICAg
ICAgICAgICAgICAgICAgaWYgKGJlZm9yZSA+IDAgJiYgYWZ0ZXIgPiAwKSB7CiAgICAgICAgICAgICAg
ICAgICAgICAgIHJlbmRlcigpOwogICAgICAgICAgICAgICAgICAgICAgICByZXR1cm4gZmFsc2U7CiAg
ICAgICAgICAgICAgICAgICAgfQogICAgICAgICAgICAgICAgfQogICAgICAgICAgICB9CiAgICAgICAg
fQogICAgICAgIGNvbnN0IGJsb2NrcyA9IGJ1aWxkUGlubmVkQmxvY2tzKHZpc2libGUpOwogICAgICAg
IGNvbnN0IGV4aXN0aW5nID0gbGlzdEVsLnF1ZXJ5U2VsZWN0b3JBbGwoJy5pdG0nKS5sZW5ndGg7CiAg
ICAgICAgaWYgKGV4aXN0aW5nIDwgMSkgewogICAgICAgICAgICByZW5kZXIoKTsKICAgICAgICAgICAg
cmV0dXJuIGZhbHNlOwogICAgICAgIH0KICAgICAgICBpZiAoYmxvY2tzLmxlbmd0aCA8PSBleGlzdGlu
ZykgewogICAgICAgICAgICByZWZyZXNoTGlzdENocm9tZSgpOwogICAgICAgICAgICB0cnkgeyBtYXJr
UXVldWVSYWlscygpOyB9IGNhdGNoIChlKSB7fQogICAgICAgICAgICByZXR1cm4gdHJ1ZTsKICAgICAg
ICB9CiAgICAgICAgY29uc3QgZnJhZyA9IGRvY3VtZW50LmNyZWF0ZURvY3VtZW50RnJhZ21lbnQoKTsK
ICAgICAgICBsZXQgbnVtID0gMDsKICAgICAgICBibG9ja3MuZm9yRWFjaChiID0+IHsKICAgICAgICAg
ICAgbnVtICs9IDE7CiAgICAgICAgICAgIGlmIChudW0gPD0gZXhpc3RpbmcpIHJldHVybjsKICAgICAg
ICAgICAgaWYgKGIua2luZCA9PT0gJ2dyb3VwJyAmJiBiLml0ZW1zLmxlbmd0aCA+IDEpCiAgICAgICAg
ICAgICAgICBmcmFnLmFwcGVuZENoaWxkKG1ha2VHcm91cEl0ZW0oYi5pdGVtcywgbnVtKSk7CiAgICAg
ICAgICAgIGVsc2UKICAgICAgICAgICAgICAgIGZyYWcuYXBwZW5kQ2hpbGQobWFrZUl0ZW0oYi5pdGVt
c1swXSwgbnVtKSk7CiAgICAgICAgfSk7CiAgICAgICAgY29uc3QgbW9yZUVsID0gZG9jdW1lbnQuZ2V0
RWxlbWVudEJ5SWQoJ2xpc3QtbW9yZScpOwogICAgICAgIGlmIChtb3JlRWwpCiAgICAgICAgICAgIGxp
c3RFbC5pbnNlcnRCZWZvcmUoZnJhZywgbW9yZUVsKTsKICAgICAgICBlbHNlCiAgICAgICAgICAgIGxp
c3RFbC5hcHBlbmRDaGlsZChmcmFnKTsKICAgICAgICB0cnkgeyBtYXJrUXVldWVSYWlscygpOyB9IGNh
dGNoIChlKSB7fQogICAgICAgIHJlZnJlc2hMaXN0Q2hyb21lKCk7CiAgICAgICAgcmVxdWVzdEFuaW1h
dGlvbkZyYW1lKCgpID0+IHsKICAgICAgICAgICAgaWYgKGFsbENsaXBzLmxlbmd0aCA8IGRpc2tUb3Rh
bAogICAgICAgICAgICAgICAgJiYgbGlzdEVsLnNjcm9sbEhlaWdodCA8PSBsaXN0RWwuY2xpZW50SGVp
Z2h0ICsgMjApCiAgICAgICAgICAgICAgICByZXF1ZXN0TW9yZSgpOwogICAgICAgICAgICB0cnkgeyBz
Y2hlZHVsZUZpbGVHb25lQ2hlY2soKTsgfSBjYXRjaCB7fQogICAgICAgIH0pOwogICAgICAgIHJldHVy
biB0cnVlOwogICAgfQoKICAgIGZ1bmN0aW9uIGFwcGx5QXBwZW5kUGF5bG9hZChwZW5kaW5nKSB7CiAg
ICAgICAgaWYgKCFwZW5kaW5nIHx8IHBlbmRpbmcuZnJvbUxlbiA9PSBudWxsKSByZXR1cm47CiAgICAg
ICAgY29uc3QgZnJvbUxlbiA9IE51bWJlcihwZW5kaW5nLmZyb21MZW4pIHx8IDA7CiAgICAgICAgaWYg
KGZyb21MZW4gPCAwIHx8IGFsbENsaXBzLmxlbmd0aCA8PSBmcm9tTGVuKSB7CiAgICAgICAgICAgIHJl
ZnJlc2hMaXN0Q2hyb21lKCk7CiAgICAgICAgICAgIHJldHVybjsKICAgICAgICB9CiAgICAgICAgYXBw
ZW5kUmVuZGVyKGZyb21MZW4pOwogICAgfQoKICAgIGZ1bmN0aW9uIG5hdkxpc3QoKSB7CiAgICAgICAg
Y29uc3QgYmxvY2tzID0gYnVpbGRQaW5uZWRCbG9ja3ModmlzaWJsZUxpc3QoKSk7CiAgICAgICAgY29u
c3Qgb3V0ID0gW107CiAgICAgICAgZm9yIChjb25zdCBiIG9mIGJsb2NrcykgewogICAgICAgICAgICBp
ZiAoIWIgfHwgIWIuaXRlbXMpIGNvbnRpbnVlOwogICAgICAgICAgICBmb3IgKGNvbnN0IGMgb2YgYi5p
dGVtcykgb3V0LnB1c2goYyk7CiAgICAgICAgfQogICAgICAgIHJldHVybiBvdXQ7CiAgICB9CgogICAg
ZnVuY3Rpb24gc2VsZWN0QnlJbmRleChpZHgpIHsKICAgICAgICBjb25zdCB2aXMgPSBuYXZMaXN0KCk7
CiAgICAgICAgaWYgKCF2aXMubGVuZ3RoKSByZXR1cm47CiAgICAgICAgaWR4ID0gTWF0aC5tYXgoMCwg
TWF0aC5taW4odmlzLmxlbmd0aCAtIDEsIGlkeCkpOwogICAgICAgIGlmIChpZHggPj0gdmlzLmxlbmd0
aCAtIDEgJiYgYWxsQ2xpcHMubGVuZ3RoIDwgZGlza1RvdGFsKQogICAgICAgICAgICByZXF1ZXN0TW9y
ZSgpOwogICAgICAgIHNlbGVjdGVkSWQgPSB2aXNbTWF0aC5taW4oaWR4LCB2aXMubGVuZ3RoIC0gMSld
LmlkOwogICAgICAgIHJhbmdlQW5jaG9ySWQgPSBzZWxlY3RlZElkOwogICAgICAgIHJhbmdlQW5jaG9y
Q2xpY2tlZCA9IGZhbHNlOwogICAgICAgIGlmICgrc2VsZWN0ZWRJZCAhPT0gK2xhc3RQYXN0ZUlkKQog
ICAgICAgICAgICBsb2NhdGVBY3RpdmUgPSBmYWxzZTsKICAgICAgICB1cGRhdGVMb2NhdGVCdG4oKTsK
ICAgICAgICBzeW5jSXRlbUhpZ2hsaWdodCgpOwogICAgICAgIGNvbnN0IGVsID0gbGlzdEVsLnF1ZXJ5
U2VsZWN0b3IoJy5tZy1yb3dbZGF0YS1pZD0iJyArIHNlbGVjdGVkSWQgKyAnIl0nKQogICAgICAgICAg
ICB8fCBsaXN0RWwucXVlcnlTZWxlY3RvcignLml0bVtkYXRhLWlkPSInICsgc2VsZWN0ZWRJZCArICci
XScpOwogICAgICAgIGlmIChlbCkgZWwuc2Nyb2xsSW50b1ZpZXcoeyBibG9jazogJ25lYXJlc3QnIH0p
OwogICAgfQoKICAgIGZ1bmN0aW9uIHNlbGVjdGVkSW5kZXgoKSB7CiAgICAgICAgcmV0dXJuIG5hdkxp
c3QoKS5maW5kSW5kZXgoYyA9PiBjLmlkID09IHNlbGVjdGVkSWQpOwogICAgfQoKICAgIGZ1bmN0aW9u
IHN5bmNJdGVtSGlnaGxpZ2h0KCkgewogICAgICAgIGRvY3VtZW50LnF1ZXJ5U2VsZWN0b3JBbGwoJy5p
dG0nKS5mb3JFYWNoKG4gPT4gewogICAgICAgICAgICBpZiAobi5jbGFzc0xpc3QuY29udGFpbnMoJ2l0
LWdyb3VwJykpIHsKICAgICAgICAgICAgICAgIGNvbnN0IHJvd3MgPSBbLi4ubi5xdWVyeVNlbGVjdG9y
QWxsKCcubWctcm93JyldOwogICAgICAgICAgICAgICAgY29uc3QgaWRzID0gcm93cy5tYXAociA9PiAr
ci5kYXRhc2V0LmlkKTsKICAgICAgICAgICAgICAgIGNvbnN0IGFueVNlbCA9IGlkcy5pbmNsdWRlcygr
c2VsZWN0ZWRJZCkgfHwgaWRzLnNvbWUoaWQgPT4gbXVsdGlJZHMuaW5jbHVkZXMoaWQpKTsKICAgICAg
ICAgICAgICAgIG4uY2xhc3NMaXN0LnRvZ2dsZSgnc2VsJywgYW55U2VsKTsKICAgICAgICAgICAgICAg
IG4uY2xhc3NMaXN0LnRvZ2dsZSgnbXVsdGknLCBpZHMuc29tZShpZCA9PiBtdWx0aUlkcy5pbmNsdWRl
cyhpZCkpKTsKICAgICAgICAgICAgICAgIHJvd3MuZm9yRWFjaChyID0+IHsKICAgICAgICAgICAgICAg
ICAgICBjb25zdCBpZCA9ICtyLmRhdGFzZXQuaWQ7CiAgICAgICAgICAgICAgICAgICAgY29uc3QgaW5N
dWx0aSA9IG11bHRpSWRzLmluY2x1ZGVzKGlkKTsKICAgICAgICAgICAgICAgICAgICByLmNsYXNzTGlz
dC50b2dnbGUoJ3NlbCcsIGlkID09IHNlbGVjdGVkSWQgfHwgaW5NdWx0aSk7CiAgICAgICAgICAgICAg
ICAgICAgci5jbGFzc0xpc3QudG9nZ2xlKCdtdWx0aScsIGluTXVsdGkpOwogICAgICAgICAgICAgICAg
fSk7CiAgICAgICAgICAgICAgICByZXR1cm47CiAgICAgICAgICAgIH0KICAgICAgICAgICAgY29uc3Qg
aWQgPSArbi5kYXRhc2V0LmlkOwogICAgICAgICAgICBjb25zdCBpbk11bHRpID0gbXVsdGlJZHMuaW5j
bHVkZXMoaWQpOwogICAgICAgICAgICBuLmNsYXNzTGlzdC50b2dnbGUoJ3NlbCcsIGlkID09IHNlbGVj
dGVkSWQgfHwgaW5NdWx0aSk7CiAgICAgICAgICAgIG4uY2xhc3NMaXN0LnRvZ2dsZSgnbXVsdGknLCBp
bk11bHRpKTsKICAgICAgICB9KTsKICAgIH0KICAgIGZ1bmN0aW9uIHVwZGF0ZU11bHRpQmFkZ2UoKSB7
CiAgICAgICAgY29uc3QgZWwgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbXVsdGktY250Jyk7CiAg
ICAgICAgaWYgKG11bHRpSWRzLmxlbmd0aCA+IDApIHsKICAgICAgICAgICAgZWwudGV4dENvbnRlbnQg
PSBTdHJpbmcobXVsdGlJZHMubGVuZ3RoKTsKICAgICAgICAgICAgZWwuY2xhc3NMaXN0LmFkZCgnb24n
KTsKICAgICAgICB9IGVsc2UgewogICAgICAgICAgICBlbC5jbGFzc0xpc3QucmVtb3ZlKCdvbicpOwog
ICAgICAgIH0KICAgICAgICBzeW5jSXRlbUhpZ2hsaWdodCgpOwogICAgfQoKICAgIGZ1bmN0aW9uIGNs
ZWFyTXVsdGkocmVzdG9yZVRvQW5jaG9yKSB7CiAgICAgICAgY29uc3QgYmFja0lkID0gK3JhbmdlQW5j
aG9ySWQgfHwgMDsKICAgICAgICBtdWx0aUlkcyA9IFtdOwogICAgICAgIGlmIChyZXN0b3JlVG9BbmNo
b3IgJiYgYmFja0lkKQogICAgICAgICAgICBzZWxlY3RlZElkID0gYmFja0lkOwogICAgICAgIHJhbmdl
QW5jaG9ySWQgPSBzZWxlY3RlZElkIHx8IDA7CiAgICAgICAgcmFuZ2VBbmNob3JDbGlja2VkID0gZmFs
c2U7CiAgICAgICAgdXBkYXRlTXVsdGlCYWRnZSgpOwogICAgICAgIGlmIChyZXN0b3JlVG9BbmNob3Ig
JiYgc2VsZWN0ZWRJZCkgewogICAgICAgICAgICBjb25zdCBlbCA9IGxpc3RFbC5xdWVyeVNlbGVjdG9y
KCcubWctcm93W2RhdGEtaWQ9IicgKyBzZWxlY3RlZElkICsgJyJdJykKICAgICAgICAgICAgICAgIHx8
IGxpc3RFbC5xdWVyeVNlbGVjdG9yKCcuaXRtW2RhdGEtaWQ9IicgKyBzZWxlY3RlZElkICsgJyJdJyk7
CiAgICAgICAgICAgIGlmIChlbCkgZWwuc2Nyb2xsSW50b1ZpZXcoeyBibG9jazogJ25lYXJlc3QnIH0p
OwogICAgICAgIH0KICAgIH0KCgogICAgLyogc2hpZnQtcmFuZ2Utc2VsZWN0LXYxICovCiAgICBsZXQg
cmFuZ2VBbmNob3JJZCA9IDA7CiAgICBsZXQgcmFuZ2VBbmNob3JDbGlja2VkID0gZmFsc2U7CiAgICBm
dW5jdGlvbiBzZWxlY3RSYW5nZVRvKGlkKSB7CiAgICAgICAgaWQgPSAraWQ7CiAgICAgICAgY29uc3Qg
bGlzdCA9ICh0eXBlb2YgbmF2TGlzdCA9PT0gJ2Z1bmN0aW9uJyA/IG5hdkxpc3QoKSA6IHZpc2libGVM
aXN0KCkpOwogICAgICAgIGNvbnN0IGIgPSBsaXN0LmZpbmRJbmRleChjID0+ICtjLmlkID09PSBpZCk7
CiAgICAgICAgaWYgKGIgPCAwKSByZXR1cm47CiAgICAgICAgbGV0IGFuY2hvciA9ICtyYW5nZUFuY2hv
cklkOwogICAgICAgIGxldCBhID0gbGlzdC5maW5kSW5kZXgoYyA9PiArYy5pZCA9PT0gYW5jaG9yKTsK
ICAgICAgICBpZiAoYSA8IDApIHsKICAgICAgICAgICAgYW5jaG9yID0gK3NlbGVjdGVkSWQgfHwgaWQ7
CiAgICAgICAgICAgIGEgPSBsaXN0LmZpbmRJbmRleChjID0+ICtjLmlkID09PSBhbmNob3IpOwogICAg
ICAgIH0KICAgICAgICBpZiAoYSA8IDApIHsKICAgICAgICAgICAgcmFuZ2VBbmNob3JJZCA9IGlkOyBz
ZWxlY3RlZElkID0gaWQ7IG11bHRpSWRzID0gW2lkXTsgdXBkYXRlTXVsdGlCYWRnZSgpOyByZXR1cm47
CiAgICAgICAgfQogICAgICAgIGlmICghcmFuZ2VBbmNob3JJZCB8fCBsaXN0LmZpbmRJbmRleChjID0+
ICtjLmlkID09PSArcmFuZ2VBbmNob3JJZCkgPCAwKQogICAgICAgICAgICByYW5nZUFuY2hvcklkID0g
bGlzdFthXS5pZDsKICAgICAgICBjb25zdCBsbyA9IE1hdGgubWluKGEsIGIpLCBoaSA9IE1hdGgubWF4
KGEsIGIpOwogICAgICAgIG11bHRpSWRzID0gW107CiAgICAgICAgZm9yIChsZXQgaSA9IGxvOyBpIDw9
IGhpOyBpKyspIG11bHRpSWRzLnB1c2goK2xpc3RbaV0uaWQpOwogICAgICAgIHNlbGVjdGVkSWQgPSBp
ZDsKICAgICAgICB1cGRhdGVNdWx0aUJhZGdlKCk7CiAgICAgICAgY29uc3QgZWwgPSBsaXN0RWwucXVl
cnlTZWxlY3RvcignLm1nLXJvd1tkYXRhLWlkPSInICsgc2VsZWN0ZWRJZCArICciXScpIHx8IGxpc3RF
bC5xdWVyeVNlbGVjdG9yKCcuaXRtW2RhdGEtaWQ9IicgKyBzZWxlY3RlZElkICsgJyJdJyk7CiAgICAg
ICAgaWYgKGVsKSBlbC5zY3JvbGxJbnRvVmlldyh7IGJsb2NrOiAnbmVhcmVzdCcgfSk7CiAgICB9CiAg
ICBmdW5jdGlvbiBzaG93U3JjVGlwKGFuY2hvciwgdGV4dCkgewogICAgICAgIHRleHQgPSBTdHJpbmco
dGV4dCB8fCAnJykudHJpbSgpOwogICAgICAgIGlmICghdGV4dCkgcmV0dXJuOwogICAgICAgIGxldCB0
aXAgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3JjLXRpcCcpOwogICAgICAgIGlmICghdGlwKSB7
CiAgICAgICAgICAgIHRpcCA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOwogICAgICAgICAg
ICB0aXAuaWQgPSAnc3JjLXRpcCc7CiAgICAgICAgICAgIGRvY3VtZW50LmJvZHkuYXBwZW5kQ2hpbGQo
dGlwKTsKICAgICAgICB9CiAgICAgICAgdGlwLnRleHRDb250ZW50ID0gdGV4dDsKICAgICAgICB0aXAu
Y2xhc3NMaXN0LmFkZCgnc2hvdycpOwogICAgICAgIGNvbnN0IHIgPSBhbmNob3IuZ2V0Qm91bmRpbmdD
bGllbnRSZWN0KCk7CiAgICAgICAgY29uc3QgdHcgPSB0aXAub2Zmc2V0V2lkdGggfHwgMTYwOwogICAg
ICAgIGNvbnN0IHRoID0gdGlwLm9mZnNldEhlaWdodCB8fCAyODsKICAgICAgICBsZXQgbGVmdCA9IHIu
cmlnaHQgLSB0dzsKICAgICAgICBsZXQgdG9wID0gci50b3AgLSB0aCAtIDg7CiAgICAgICAgaWYgKGxl
ZnQgPCA4KSBsZWZ0ID0gODsKICAgICAgICBpZiAobGVmdCArIHR3ID4gd2luZG93LmlubmVyV2lkdGgg
LSA4KSBsZWZ0ID0gd2luZG93LmlubmVyV2lkdGggLSB0dyAtIDg7CiAgICAgICAgaWYgKHRvcCA8IDgp
IHRvcCA9IHIuYm90dG9tICsgODsKICAgICAgICB0aXAuc3R5bGUubGVmdCA9IGxlZnQgKyAncHgnOwog
ICAgICAgIHRpcC5zdHlsZS50b3AgPSB0b3AgKyAncHgnOwogICAgICAgIGNsZWFyVGltZW91dCh0aXAu
X2hpZGVUKTsKICAgICAgICB0aXAuX2hpZGVUID0gc2V0VGltZW91dCgoKSA9PiB0aXAuY2xhc3NMaXN0
LnJlbW92ZSgnc2hvdycpLCAyMjAwKTsKICAgIH0KICAgIC8qIGltZy1ob3Zlci1wcmV2aWV3LXY4ICov
CiAgICBsZXQgX19pbWdIb3ZlclRpbWVyID0gMCwgX19pbWdIb3ZlckhpZGVUaW1lciA9IDAsIF9faW1n
SG92ZXJLZXkgPSAnJzsKICAgIGZ1bmN0aW9uIF9faW1nSG92ZXJFbnN1cmUoKSB7CiAgICAgICAgbGV0
IGJveCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdpbWctaG92ZXItc2lkZScpOwogICAgICAgIGlm
ICghYm94KSB7CiAgICAgICAgICAgIGJveCA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOyBi
b3guaWQgPSAnaW1nLWhvdmVyLXNpZGUnOwogICAgICAgICAgICBjb25zdCBmcmFtZSA9IGRvY3VtZW50
LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOyBmcmFtZS5jbGFzc05hbWUgPSAnaWhwLWZyYW1lJzsKICAgICAg
ICAgICAgY29uc3QgaW0gPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdpbWcnKTsgaW0uYWx0ID0gJyc7
CiAgICAgICAgICAgIGZyYW1lLmFwcGVuZENoaWxkKGltKTsgYm94LmFwcGVuZENoaWxkKGZyYW1lKTsg
ZG9jdW1lbnQuYm9keS5hcHBlbmRDaGlsZChib3gpOwogICAgICAgIH0KICAgICAgICBsZXQgc3QgPSBk
b2N1bWVudC5nZXRFbGVtZW50QnlJZCgnaW1nLWhvdmVyLXNpZGUtY3NzJyk7CiAgICAgICAgaWYgKCFz
dCkgeyBzdCA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ3N0eWxlJyk7IHN0LmlkID0gJ2ltZy1ob3Zl
ci1zaWRlLWNzcyc7IGRvY3VtZW50LmhlYWQuYXBwZW5kQ2hpbGQoc3QpOyB9CiAgICAgICAgc3QudGV4
dENvbnRlbnQgPSAiI2ltZy1ob3Zlci1zaWRle3Bvc2l0aW9uOmZpeGVkO3otaW5kZXg6MTAwMDAwO3Jp
Z2h0OjZweDt0b3A6NTAlO3RyYW5zZm9ybTp0cmFuc2xhdGVZKC01MCUpO3BvaW50ZXItZXZlbnRzOm5v
bmU7b3BhY2l0eTowO3Zpc2liaWxpdHk6aGlkZGVuO21heC13aWR0aDptaW4oNjIwcHgsOTJ2dyk7bWF4
LWhlaWdodDptaW4oOTJ2aCw5MjBweCl9I2ltZy1ob3Zlci1zaWRlLnNob3d7b3BhY2l0eToxO3Zpc2li
aWxpdHk6dmlzaWJsZX0jaW1nLWhvdmVyLXNpZGUgLmlocC1mcmFtZXtwYWRkaW5nOjNweDtiYWNrZ3Jv
dW5kOiNmZmY7Ym9yZGVyOjFweCBzb2xpZCAjQzVDRERDO2JvcmRlci1yYWRpdXM6MnB4O2JveC1zaGFk
b3c6MCA2cHggMThweCByZ2JhKDQ0LDQ2LDU0LC4xMil9I2ltZy1ob3Zlci1zaWRlIGltZ3tkaXNwbGF5
OmJsb2NrO21heC13aWR0aDptaW4oNjEycHgsOTB2dyk7bWF4LWhlaWdodDptaW4oOTB2aCw5MDBweCk7
d2lkdGg6YXV0bztoZWlnaHQ6YXV0bztvYmplY3QtZml0OmNvbnRhaW47YmFja2dyb3VuZDojZmZmfSI7
CiAgICAgICAgcmV0dXJuIGJveDsKICAgIH0KICAgIHdpbmRvdy5fX2ltZ0hvdmVyU2hvdyA9IGZ1bmN0
aW9uKGZpbGUsIGlkKSB7CiAgICAgICAgY29uc3QgYmFyZSA9IFN0cmluZyhmaWxlIHx8ICcnKS5zcGxp
dCgvW1xcXFwvXS8pLnBvcCgpOyBpZiAoIWJhcmUpIHJldHVybjsKICAgICAgICBjb25zdCBib3ggPSBf
X2ltZ0hvdmVyRW5zdXJlKCk7IGNvbnN0IGltZyA9IGJveC5xdWVyeVNlbGVjdG9yKCdpbWcnKTsgaWYg
KCFpbWcpIHJldHVybjsKICAgICAgICBib3guY2xhc3NMaXN0LmFkZCgnc2hvdycpOwogICAgICAgIGlt
Zy5vbmVycm9yID0gKCkgPT4gewogICAgICAgICAgICBpbWcub25lcnJvciA9ICgpID0+IHsgaW1nLm9u
ZXJyb3IgPSBudWxsOyB0cnkgeyBjb25zdCBjID0gdGh1bWJDYWNoZSAmJiB0aHVtYkNhY2hlLmdldChT
dHJpbmcoaWQpKTsgaWYgKGMpIGltZy5zcmMgPSBjOyB9IGNhdGNoIChlKSB7fSB9OwogICAgICAgICAg
ICBpbWcuc3JjID0gU1RPUkVfQkFTRSArICd0aF8nICsgYmFyZS5yZXBsYWNlKC9cLlteLl0rJC8sICcn
KSArICcuanBnJzsKICAgICAgICB9OwogICAgICAgIGltZy5vbmxvYWQgPSAoKSA9PiB7IGltZy5vbmVy
cm9yID0gbnVsbDsgfTsKICAgICAgICBpbWcuZGF0YXNldC5iYXJlID0gYmFyZTsgaW1nLnNyYyA9IFNU
T1JFX0JBU0UgKyBiYXJlOwogICAgfTsKICAgIHdpbmRvdy5fX2ltZ0hvdmVyQ2xlYXJVaSA9IGZ1bmN0
aW9uKCkgewogICAgICAgIF9faW1nSG92ZXJLZXkgPSAnJzsKICAgICAgICBpZiAoX19pbWdIb3ZlclRp
bWVyKSB7IGNsZWFyVGltZW91dChfX2ltZ0hvdmVyVGltZXIpOyBfX2ltZ0hvdmVyVGltZXIgPSAwOyB9
CiAgICAgICAgaWYgKF9faW1nSG92ZXJIaWRlVGltZXIpIHsgY2xlYXJUaW1lb3V0KF9faW1nSG92ZXJI
aWRlVGltZXIpOyBfX2ltZ0hvdmVySGlkZVRpbWVyID0gMDsgfQogICAgICAgIGNvbnN0IGJveCA9IGRv
Y3VtZW50LmdldEVsZW1lbnRCeUlkKCdpbWctaG92ZXItc2lkZScpOyBpZiAoYm94KSBib3guY2xhc3NM
aXN0LnJlbW92ZSgnc2hvdycpOwogICAgICAgIGNvbnN0IGltZyA9IGJveCAmJiBib3gucXVlcnlTZWxl
Y3RvcignaW1nJyk7CiAgICAgICAgaWYgKGltZykgeyBpbWcub25sb2FkID0gbnVsbDsgaW1nLm9uZXJy
b3IgPSBudWxsOyBpbWcucmVtb3ZlQXR0cmlidXRlKCdzcmMnKTsgZGVsZXRlIGltZy5kYXRhc2V0LmJh
cmU7IH0KICAgIH07CiAgICB3aW5kb3cuX19pbWdIb3ZlckhpZGUgPSBmdW5jdGlvbigpIHsgd2luZG93
Ll9faW1nSG92ZXJDbGVhclVpKCk7IH07CiAgICBmdW5jdGlvbiBiaW5kSW1nSG92ZXJQcmV2aWV3KGVs
LCBpZCwgZmlsZSkgewogICAgICAgIGlmICghZWwpIHJldHVybjsKICAgICAgICBjb25zdCBiYXJlID0g
U3RyaW5nKGZpbGUgfHwgJycpLnNwbGl0KC9bXFxcXC9dLykucG9wKCk7IGlmICghYmFyZSkgcmV0dXJu
OwogICAgICAgIGNvbnN0IGtleSA9IFN0cmluZyhpZCkgKyAnfCcgKyBiYXJlOwogICAgICAgIGVsLnN0
eWxlLmN1cnNvciA9ICd6b29tLWluJzsKICAgICAgICBlbC5hZGRFdmVudExpc3RlbmVyKCdtb3VzZWVu
dGVyJywgKCkgPT4gewogICAgICAgICAgICBpZiAoX19pbWdIb3ZlckhpZGVUaW1lcikgeyBjbGVhclRp
bWVvdXQoX19pbWdIb3ZlckhpZGVUaW1lcik7IF9faW1nSG92ZXJIaWRlVGltZXIgPSAwOyB9CiAgICAg
ICAgICAgIF9faW1nSG92ZXJLZXkgPSBrZXk7CiAgICAgICAgICAgIGlmIChfX2ltZ0hvdmVyVGltZXIp
IGNsZWFyVGltZW91dChfX2ltZ0hvdmVyVGltZXIpOwogICAgICAgICAgICBfX2ltZ0hvdmVyVGltZXIg
PSBzZXRUaW1lb3V0KCgpID0+IHsgaWYgKF9faW1nSG92ZXJLZXkgPT09IGtleSkgdHJ5IHsgd2luZG93
Ll9faW1nSG92ZXJTaG93KGJhcmUsIGlkKTsgfSBjYXRjaCAoZSkge30gfSwgNjApOwogICAgICAgIH0p
OwogICAgICAgIGVsLmFkZEV2ZW50TGlzdGVuZXIoJ21vdXNlbGVhdmUnLCAoKSA9PiB7CiAgICAgICAg
ICAgIGlmIChfX2ltZ0hvdmVyVGltZXIpIHsgY2xlYXJUaW1lb3V0KF9faW1nSG92ZXJUaW1lcik7IF9f
aW1nSG92ZXJUaW1lciA9IDA7IH0KICAgICAgICAgICAgX19pbWdIb3ZlckhpZGVUaW1lciA9IHNldFRp
bWVvdXQoKCkgPT4geyBpZiAoIV9faW1nSG92ZXJLZXkgfHwgX19pbWdIb3ZlcktleSA9PT0ga2V5KSB3
aW5kb3cuX19pbWdIb3ZlckhpZGUoKTsgfSwgNzApOwogICAgICAgIH0pOwogICAgfQogICAgZnVuY3Rp
b24gaGFuZGxlSXRlbUNsaWNrKGUsIGMpIHsKICAgICAgICBpZiAoZS5zaGlmdEtleSkgewogICAgICAg
ICAgICBlLnByZXZlbnREZWZhdWx0KCk7IGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAgICAgICAgIGNv
bnN0IGxpc3QgPSAodHlwZW9mIG5hdkxpc3QgPT09ICdmdW5jdGlvbicgPyBuYXZMaXN0KCkgOiB2aXNp
YmxlTGlzdCgpKTsKICAgICAgICAgICAgY29uc3QgYW5jaG9yT2sgPSByYW5nZUFuY2hvckNsaWNrZWQg
JiYgcmFuZ2VBbmNob3JJZCAmJiBsaXN0LnNvbWUoeCA9PiAreC5pZCA9PT0gK3JhbmdlQW5jaG9ySWQp
OwogICAgICAgICAgICBpZiAoIWFuY2hvck9rKSByYW5nZUFuY2hvcklkID0gc2VsZWN0ZWRJZCB8fCBj
LmlkOwogICAgICAgICAgICByYW5nZUFuY2hvckNsaWNrZWQgPSB0cnVlOwogICAgICAgICAgICBzZWxl
Y3RSYW5nZVRvKGMuaWQpOwogICAgICAgICAgICByZXR1cm4gdHJ1ZTsKICAgICAgICB9CiAgICAgICAg
aWYgKGUuY3RybEtleSB8fCBlLm1ldGFLZXkpIHsKICAgICAgICAgICAgZS5wcmV2ZW50RGVmYXVsdCgp
OyBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgICAgICAgICB0b2dnbGVNdWx0aShjLmlkKTsKICAgICAg
ICAgICAgcmV0dXJuIHRydWU7CiAgICAgICAgfQogICAgICAgIHJhbmdlQW5jaG9ySWQgPSBjLmlkOwog
ICAgICAgIHJhbmdlQW5jaG9yQ2xpY2tlZCA9IHRydWU7CiAgICAgICAgcmV0dXJuIGZhbHNlOwogICAg
fQogICAgZnVuY3Rpb24gdG9nZ2xlTXVsdGkoaWQpIHsKICAgICAgICBpZCA9ICtpZDsKICAgICAgICBj
b25zdCBpID0gbXVsdGlJZHMuaW5kZXhPZihpZCk7CiAgICAgICAgaWYgKGkgPj0gMCkgbXVsdGlJZHMu
c3BsaWNlKGksIDEpOwogICAgICAgIGVsc2UgbXVsdGlJZHMucHVzaChpZCk7CiAgICAgICAgc2VsZWN0
ZWRJZCA9IGlkOwogICAgICAgIHJhbmdlQW5jaG9ySWQgPSBpZDsKICAgICAgICByYW5nZUFuY2hvckNs
aWNrZWQgPSB0cnVlOwogICAgICAgIHVwZGF0ZU11bHRpQmFkZ2UoKTsKICAgIH0KCiAgICBmdW5jdGlv
biByZW5kZXIoKSB7CiAgICAgICAgaGlkZVBhdGhUaXAoKTsKCiAgICAgICAgY29uc3QgdmlzaWJsZSA9
IHZpc2libGVMaXN0KCk7CiAgICAgICAgY29uc3QgbG9hZGVkID0gYWxsQ2xpcHMubGVuZ3RoOwogICAg
ICAgIGNvbnN0IHNob3duQ291bnQgPSB2aXNpYmxlLmxlbmd0aDsKICAgICAgICAvLyDmlLbol4/op5Lm
oIfvvJrnlKggQUhLIOS4i+WPkeeahOaAu+aVsO+8jOmBv+WFjeOAjOW9k+WJjemhtemHjOaVsOWHuuad
peeahOOAjeWSjCBiYXIg5a+55LiN5LiKCiAgICAgICAgbGV0IHBpbm5lZE4gPSBOdW1iZXIocGlubmVk
VG90YWwpIHx8IDA7CiAgICAgICAgaWYgKHBpbm5lZE4gPCAxKSB7CiAgICAgICAgICAgIGlmIChjdXJU
YWIgPT09ICdwaW5uZWQnKQogICAgICAgICAgICAgICAgcGlubmVkTiA9IE1hdGgubWF4KE51bWJlcihk
aXNrVG90YWwpIHx8IDAsIGxvYWRlZCk7CiAgICAgICAgICAgIGVsc2UKICAgICAgICAgICAgICAgIHBp
bm5lZE4gPSBhbGxDbGlwcy5maWx0ZXIoYyA9PiBpc1Bpbm5lZChjKSkubGVuZ3RoOwogICAgICAgIH0K
ICAgICAgICBjb25zdCBwaW5DbnQgID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3Bpbi1jbnQnKTsK
ICAgICAgICBwaW5DbnQudGV4dENvbnRlbnQgICA9IHBpbm5lZE47CiAgICAgICAgcGluQ250LnN0eWxl
LmRpc3BsYXkgPSBwaW5uZWROID8gJycgOiAnbm9uZSc7CiAgICAgICAgLy8g5pS26JePIHRhYu+8mmJh
ciDkuI7op5LmoIflkIzkuIDlpZfmgLvmlbDvvJvmnKrmu6HpobXml7bmmL7npLog5bey5Yqg6L29L+aA
u+aVsAogICAgICAgIGxldCBzaG93VG90YWwgPSBkaXNrVG90YWwgPiAwID8gZGlza1RvdGFsIDogKGxv
YWRlZCB8fCAwKTsKICAgICAgICBpZiAoY3VyVGFiID09PSAncGlubmVkJyAmJiBwaW5uZWROID4gc2hv
d1RvdGFsKQogICAgICAgICAgICBzaG93VG90YWwgPSBwaW5uZWROOwogICAgICAgIGNvbnN0IHFPbiA9
IFN0cmluZyhxdWVyeSB8fCAnJykudHJpbSgpLmxlbmd0aCA+IDA7CiAgICAgICAgZG9jdW1lbnQuZ2V0
RWxlbWVudEJ5SWQoJ2Jhci10eHQnKS50ZXh0Q29udGVudCA9IHFPbgogICAgICAgICAgICA/IChzaG93
bkNvdW50ICsgJyDmnaEnKQogICAgICAgICAgICA6IChzaG93VG90YWwgPiBsb2FkZWQgPyAoc2hvd25D
b3VudCArICcgLyAnICsgc2hvd1RvdGFsICsgJyDmnaEnKSA6IChzaG93VG90YWwgKyAnIOadoScpKTsK
ICAgICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnZW1wdHktdHh0JykudGV4dENvbnRlbnQgPSBF
TVBUWV9NU0dbY3VyVGFiXSB8fCBFTVBUWV9NU0cuYWxsOwoKICAgICAgICBjb25zdCBpZFNldCA9IG5l
dyBTZXQoYWxsQ2xpcHMubWFwKGMgPT4gK2MuaWQpKTsKICAgICAgICBtdWx0aUlkcyA9IG11bHRpSWRz
LmZpbHRlcihpZCA9PiBpZFNldC5oYXMoaWQpKTsKICAgICAgICB1cGRhdGVNdWx0aUJhZGdlKCk7Cgog
ICAgICAgIGNvbnN0IHNob3duID0gdmlzaWJsZTsKCiAgICAgICAgbGlzdEVsLnF1ZXJ5U2VsZWN0b3JB
bGwoJy5pdG0sICNsaXN0LW1vcmUnKS5mb3JFYWNoKGUgPT4gZS5yZW1vdmUoKSk7CiAgICAgICAgLy8g
6aqo5p625bey5YWz6Zet77ya5Y2z5L2/IHdhaXRpbmcg5Lmf5LiNIHJldHVybu+8jOacieaVsOaNruWw
seebtOaOpeeUuwogICAgICAgIGlmIChza2VsRWwpIHNrZWxFbC5jbGFzc0xpc3QucmVtb3ZlKCdvbicp
OwogICAgICAgIGNvbnN0IGFwcEJvb3QgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYXBwJyk7CiAg
ICAgICAgaWYgKGFwcEJvb3QpIGFwcEJvb3QuY2xhc3NMaXN0LnJlbW92ZSgnYm9vdC1sb2FkaW5nJyk7
CiAgICAgICAgaWYgKCh3YWl0aW5nRGF0YSB8fCAhaG9zdFB1c2hlZE9uY2UpICYmICF2aXNpYmxlLmxl
bmd0aCkgewogICAgICAgICAgICBlbXB0eUVsLmNsYXNzTGlzdC5yZW1vdmUoJ29uJyk7CiAgICAgICAg
ICAgIHVwZGF0ZVRvcEJ0bigpOwogICAgICAgICAgICByZXR1cm47CiAgICAgICAgfQogICAgICAgIGlm
ICghdmlzaWJsZS5sZW5ndGgpIHsKICAgICAgICAgICAgLy8gTmV2ZXIgc2hvd+OAjOaaguaXoOiusOW9
leOAjXVudGlsIHdlIGhhdmUgc2VlbiBhIHJlYWwgbm9uLWVtcHR5IHB1c2gsCiAgICAgICAgICAgIC8v
IG9yIGEgY29uZmlybWVkIGVtcHR5IGFmdGVyIHdhcm0gKHNhd05vbkVtcHR5IGNhbiBiZSBzZXQgYnkg
ZW1wdHktZmFsbGJhY2spLgogICAgICAgICAgICAvLyBGaWx0ZXJlZCBzZWFyY2ggd2l0aCAwIGhpdHMg
aXMgYWxsb3dlZCBvbmNlIGhvc3QgcHVzaGVkLgogICAgICAgICAgICBjb25zdCBxT24gPSBTdHJpbmco
cXVlcnkgfHwgJycpLnRyaW0oKS5sZW5ndGggPiAwOwogICAgICAgICAgICBjb25zdCBhbGxvd0VtcHR5
ID0gaG9zdFB1c2hlZE9uY2UgJiYgc2F3Tm9uRW1wdHkgJiYgIXdhaXRpbmdEYXRhICYmICFib290TG9h
ZGluZwogICAgICAgICAgICAgICAgJiYgKHFPbiB8fCBkaXNrVG90YWwgPD0gMCk7CiAgICAgICAgICAg
IGlmICghYWxsb3dFbXB0eSkgewogICAgICAgICAgICAgICAgZW1wdHlFbC5jbGFzc0xpc3QucmVtb3Zl
KCdvbicpOwogICAgICAgICAgICAgICAgdXBkYXRlVG9wQnRuKCk7CiAgICAgICAgICAgICAgICByZXR1
cm47CiAgICAgICAgICAgIH0KICAgICAgICAgICAgaWYgKHNlbGVjdEZpcnN0T25TaG93KSB7CiAgICAg
ICAgICAgICAgICBzZWxlY3RGaXJzdE9uU2hvdyA9IGZhbHNlOwogICAgICAgICAgICAgICAgc2VsZWN0
ZWRJZCA9IDA7CiAgICAgICAgICAgICAgICBjbGVhck11bHRpKCk7CiAgICAgICAgICAgICAgICBsaXN0
RWwuc2Nyb2xsVG9wID0gMDsKICAgICAgICAgICAgfQogICAgICAgICAgICBlbXB0eUVsLmNsYXNzTGlz
dC5hZGQoJ29uJyk7CiAgICAgICAgICAgIHVwZGF0ZVRvcEJ0bigpOwogICAgICAgICAgICByZXR1cm47
CiAgICAgICAgfQogICAgICAgIGVtcHR5RWwuY2xhc3NMaXN0LnJlbW92ZSgnb24nKTsKICAgICAgICBj
b25zdCBmcmFnID0gZG9jdW1lbnQuY3JlYXRlRG9jdW1lbnRGcmFnbWVudCgpOwogICAgICAgIGNvbnN0
IGJsb2NrcyA9IGJ1aWxkUGlubmVkQmxvY2tzKHNob3duKTsKICAgICAgICBsZXQgbnVtID0gMDsKICAg
ICAgICBibG9ja3MuZm9yRWFjaChiID0+IHsKICAgICAgICAgICAgbnVtICs9IDE7CiAgICAgICAgICAg
IGlmIChiLmtpbmQgPT09ICdncm91cCcgJiYgYi5pdGVtcy5sZW5ndGggPiAxKQogICAgICAgICAgICAg
ICAgZnJhZy5hcHBlbmRDaGlsZChtYWtlR3JvdXBJdGVtKGIuaXRlbXMsIG51bSkpOwogICAgICAgICAg
ICBlbHNlCiAgICAgICAgICAgICAgICBmcmFnLmFwcGVuZENoaWxkKG1ha2VJdGVtKGIuaXRlbXNbMF0s
IG51bSkpOwogICAgICAgIH0pOwogICAgICAgIGxpc3RFbC5hcHBlbmRDaGlsZChmcmFnKTsKICAgICAg
ICBtYXJrUXVldWVSYWlscygpOwogICAgICAgIHVwZGF0ZU1vcmVGb290ZXIoZGlza1RvdGFsKTsKICAg
ICAgICBpZiAoc2VsZWN0Rmlyc3RPblNob3cpIHsKICAgICAgICAgICAgc2VsZWN0Rmlyc3RPblNob3cg
PSBmYWxzZTsKICAgICAgICAgICAgc2VsZWN0ZWRJZCA9IHZpc2libGVbMF0uaWQ7CiAgICAgICAgICAg
IGNsZWFyTXVsdGkoKTsKICAgICAgICAgICAgbGlzdEVsLnNjcm9sbFRvcCA9IDA7CiAgICAgICAgfSBl
bHNlIGlmICghdmlzaWJsZS5zb21lKGMgPT4gYy5pZCA9PSBzZWxlY3RlZElkKSkgewogICAgICAgICAg
ICBzZWxlY3RlZElkID0gdmlzaWJsZVswXS5pZDsKICAgICAgICAgICAgcmFuZ2VBbmNob3JJZCA9IHNl
bGVjdGVkSWQ7CiAgICAgICAgICAgIHJhbmdlQW5jaG9yQ2xpY2tlZCA9IGZhbHNlOwogICAgICAgIH0g
ZWxzZSBpZiAoIXJhbmdlQW5jaG9ySWQpIHsKICAgICAgICAgICAgcmFuZ2VBbmNob3JJZCA9IHNlbGVj
dGVkSWQ7CiAgICAgICAgfQogICAgICAgIHN5bmNJdGVtSGlnaGxpZ2h0KCk7CiAgICAgICAgdXBkYXRl
VG9wQnRuKCk7CiAgICAgICAgaWYgKHdpbmRvdy5fX3BlbmRpbmdKdW1wSWQpIHsKICAgICAgICAgICAg
Y29uc3QgamlkID0gK3dpbmRvdy5fX3BlbmRpbmdKdW1wSWQ7CiAgICAgICAgICAgIGNvbnN0IGVsID0g
bGlzdEVsLnF1ZXJ5U2VsZWN0b3IoJy5tZy1yb3dbZGF0YS1pZD0iJyArIGppZCArICciXScpIHx8IGxp
c3RFbC5xdWVyeVNlbGVjdG9yKCcuaXRtW2RhdGEtaWQ9IicgKyBqaWQgKyAnIl0nKTsKICAgICAgICAg
ICAgaWYgKGVsKSB7CiAgICAgICAgICAgICAgICB3aW5kb3cuX19wZW5kaW5nSnVtcElkID0gMDsKICAg
ICAgICAgICAgICAgIHdpbmRvdy5fX2p1bXBMb2FkVHJpZXMgPSAwOwogICAgICAgICAgICAgICAgc2Vs
ZWN0ZWRJZCA9IGppZDsKICAgICAgICAgICAgICAgIHJlcXVlc3RBbmltYXRpb25GcmFtZSgoKSA9PiB7
CiAgICAgICAgICAgICAgICAgICAgY29uc3Qgbm9kZSA9IGxpc3RFbC5xdWVyeVNlbGVjdG9yKCcubWct
cm93W2RhdGEtaWQ9IicgKyBqaWQgKyAnIl0nKSB8fCBsaXN0RWwucXVlcnlTZWxlY3RvcignLml0bVtk
YXRhLWlkPSInICsgamlkICsgJyJdJyk7CiAgICAgICAgICAgICAgICAgICAgaWYgKCFub2RlKSByZXR1
cm47CiAgICAgICAgICAgICAgICAgICAgbm9kZS5zY3JvbGxJbnRvVmlldyh7IGJsb2NrOiAnY2VudGVy
JyB9KTsKICAgICAgICAgICAgICAgICAgICBub2RlLmNsYXNzTGlzdC5hZGQoJ2p1bXAtZmxhc2gnKTsK
ICAgICAgICAgICAgICAgICAgICBzZXRUaW1lb3V0KCgpID0+IG5vZGUuY2xhc3NMaXN0LnJlbW92ZSgn
anVtcC1mbGFzaCcpLCA5MDApOwogICAgICAgICAgICAgICAgICAgIHN5bmNJdGVtSGlnaGxpZ2h0KCk7
CiAgICAgICAgICAgICAgICB9KTsKICAgICAgICAgICAgfSBlbHNlIGlmIChhbGxDbGlwcy5sZW5ndGgg
PCBkaXNrVG90YWwgJiYgKHdpbmRvdy5fX2p1bXBMb2FkVHJpZXMgfHwgMCkgPCA0MCkgewogICAgICAg
ICAgICAgICAgd2luZG93Ll9fanVtcExvYWRUcmllcyA9ICh3aW5kb3cuX19qdW1wTG9hZFRyaWVzIHx8
IDApICsgMTsKICAgICAgICAgICAgICAgIHJlcXVlc3RNb3JlKCk7CiAgICAgICAgICAgIH0gZWxzZSBp
ZiAoY3VyVGFiICE9PSAnYWxsJyAmJiAhd2luZG93Ll9fanVtcEZlbGxCYWNrKSB7CiAgICAgICAgICAg
ICAgICAvLyBJdGVtIGdvbmUgZnJvbSB0aGlzIHRhYiAoZS5nLiB1bnBpbm5lZCkg4oCUIGZhbGwgYmFj
ayB0byDlhajpg6ggb25jZQogICAgICAgICAgICAgICAgd2luZG93Ll9fanVtcEZlbGxCYWNrID0gdHJ1
ZTsKICAgICAgICAgICAgICAgIHdpbmRvdy5fX2p1bXBMb2FkVHJpZXMgPSAwOwogICAgICAgICAgICAg
ICAgY3VyVGFiID0gJ2FsbCc7CiAgICAgICAgICAgICAgICBtYXJrVGFiKCdhbGwnKTsKICAgICAgICAg
ICAgICAgIHJlcXVlc3RWaWV3KCk7CiAgICAgICAgICAgIH0gZWxzZSB7CiAgICAgICAgICAgICAgICB3
aW5kb3cuX19wZW5kaW5nSnVtcElkID0gMDsKICAgICAgICAgICAgICAgIHdpbmRvdy5fX2p1bXBMb2Fk
VHJpZXMgPSAwOwogICAgICAgICAgICAgICAgaWYgKGFsbENsaXBzLnNvbWUoYyA9PiArYy5pZCA9PT0g
amlkKSkKICAgICAgICAgICAgICAgICAgICBzZWxlY3RlZElkID0gamlkOwogICAgICAgICAgICAgICAg
c3luY0l0ZW1IaWdobGlnaHQoKTsKICAgICAgICAgICAgfQogICAgICAgIH0KICAgICAgICByZXF1ZXN0
QW5pbWF0aW9uRnJhbWUoKCkgPT4gewogICAgICAgICAgICBpZiAoYWxsQ2xpcHMubGVuZ3RoIDwgZGlz
a1RvdGFsCiAgICAgICAgICAgICAgICAmJiBsaXN0RWwuc2Nyb2xsSGVpZ2h0IDw9IGxpc3RFbC5jbGll
bnRIZWlnaHQgKyAyMCkKICAgICAgICAgICAgICAgIHJlcXVlc3RNb3JlKCk7CiAgICAgICAgICAgIHNj
aGVkdWxlRmlsZUdvbmVDaGVjaygpOwogICAgICAgIH0pOwogICAgfQoKICAgIGNvbnN0IFNWRyA9IHsK
ICAgICAgICB0ZXh0OiAgIGA8c3ZnIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0ibm9uZSIgc3Ryb2tl
PSJjdXJyZW50Q29sb3IiIHN0cm9rZS13aWR0aD0iMiI+PHBhdGggZD0iTTQgN1Y0aDE2djNNOSAyMGg2
TTEyIDR2MTYiLz48L3N2Zz5gLAogICAgICAgIG1kOiAgICAgYDxzdmcgdmlld0JveD0iMCAwIDI0IDI0
IiBmaWxsPSJjdXJyZW50Q29sb3IiPjx0ZXh0IHg9IjEyIiB5PSIxNyIgdGV4dC1hbmNob3I9Im1pZGRs
ZSIgZm9udC1zaXplPSIxNSIgZm9udC13ZWlnaHQ9IjgwMCIgZm9udC1mYW1pbHk9IlNlZ29lIFVJLE1p
Y3Jvc29mdCBZYUhlaSxzYW5zLXNlcmlmIj5NPC90ZXh0Pjwvc3ZnPmAsCiAgICAgICAgaW1hZ2U6ICBg
PHN2ZyB2aWV3Qm94PSIwIDAgMjQgMjQiIGZpbGw9Im5vbmUiIHN0cm9rZT0iY3VycmVudENvbG9yIiBz
dHJva2Utd2lkdGg9IjEuOCI+PHJlY3QgeD0iMyIgeT0iNSIgd2lkdGg9IjE4IiBoZWlnaHQ9IjE0IiBy
eD0iMiIvPjxjaXJjbGUgY3g9IjguNSIgY3k9IjEwIiByPSIxLjUiIGZpbGw9ImN1cnJlbnRDb2xvciIg
c3Ryb2tlPSJub25lIi8+PHBhdGggZD0iTTMgMTZsNS01IDQgNCAzLTMgNiA2Ii8+PC9zdmc+YCwKICAg
ICAgICB2aWRlbzogIGA8c3ZnIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSJj
dXJyZW50Q29sb3IiIHN0cm9rZS13aWR0aD0iMS44Ij48cmVjdCB4PSIzIiB5PSI2IiB3aWR0aD0iMTQi
IGhlaWdodD0iMTIiIHJ4PSIyIi8+PHBhdGggZD0iTTE3IDkuNWw0LTIuNXYxMGwtNC0yLjVWOS41eiIg
ZmlsbD0iY3VycmVudENvbG9yIiBzdHJva2U9Im5vbmUiLz48cGF0aCBkPSJNOC41IDEwLjJ2My42bDMu
Mi0xLjgtMy4yLTEuOHoiIGZpbGw9ImN1cnJlbnRDb2xvciIgc3Ryb2tlPSJub25lIi8+PC9zdmc+YCwK
ICAgICAgICBmb2xkZXI6IGA8c3ZnIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0iY3VycmVudENvbG9y
Ij48cGF0aCBkPSJNMTAgNEg0Yy0xLjEgMC0yIC45LTIgMnYxMmMwIDEuMS45IDIgMiAyaDE2YzEuMSAw
IDItLjkgMi0yVjhjMC0xLjEtLjktMi0yLTJoLThsLTItMnoiLz48L3N2Zz5gLAogICAgICAgIHppcDog
ICAgYDxzdmcgdmlld0JveD0iMCAwIDI0IDI0IiBmaWxsPSJub25lIiBzdHJva2U9ImN1cnJlbnRDb2xv
ciIgc3Ryb2tlLXdpZHRoPSIxLjgiPjxwYXRoIGQ9Ik02IDNoOWw1IDV2MTNhMSAxIDAgMCAxLTEgMUg2
YTEgMSAwIDAgMS0xLTFWNGExIDEgMCAwIDEgMS0xeiIvPjxwYXRoIGQ9Ik0xNCAzdjZoNiIvPjwvc3Zn
PmAsCiAgICAgICAgYWhrOiAgICBgPHN2ZyB2aWV3Qm94PSIwIDAgMjQgMjQiIGZpbGw9ImN1cnJlbnRD
b2xvciI+PHRleHQgeD0iMTIiIHk9IjE3IiB0ZXh0LWFuY2hvcj0ibWlkZGxlIiBmb250LXNpemU9IjE0
IiBmb250LXdlaWdodD0iNzAwIj5IPC90ZXh0Pjwvc3ZnPmAsCiAgICAgICAgbG5rOiAgICBgPHN2ZyB2
aWV3Qm94PSIwIDAgMjQgMjQiIGZpbGw9Im5vbmUiIHN0cm9rZT0iY3VycmVudENvbG9yIiBzdHJva2Ut
d2lkdGg9IjEuOCI+PHBhdGggZD0iTTEwIDEzYTUgNSAwIDAgMCA3LjA3IDBsMi4xMi0yLjEyYTUgNSAw
IDAgMC03LjA3LTcuMDdMMTEgNSIvPjxwYXRoIGQ9Ik0xNCAxMWE1IDUgMCAwIDAtNy4wNyAwTDQuOCAx
My4xMmE1IDUgMCAxIDAgNy4wNyA3LjA3TDEzIDE5Ii8+PC9zdmc+YCwKICAgICAgICBkb2M6ICAgIGA8
c3ZnIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0
cm9rZS13aWR0aD0iMS44Ij48cGF0aCBkPSJNNyAzaDdsNSA1djEzYTEgMSAwIDAgMS0xIDFIN2ExIDEg
MCAwIDEtMS0xVjRhMSAxIDAgMCAxIDEtMXoiLz48cGF0aCBkPSJNMTQgM3Y2aDYiLz48L3N2Zz5gLAog
ICAgICAgIG11bHRpOiAgYDxzdmcgdmlld0JveD0iMCAwIDI0IDI0IiBmaWxsPSJub25lIiBzdHJva2U9
ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIxLjgiPjxyZWN0IHg9IjciIHk9IjciIHdpZHRoPSIx
MiIgaGVpZ2h0PSIxNCIgcng9IjEuNSIvPjxwYXRoIGQ9Ik01IDE3VjVhMSAxIDAgMCAxIDEtMWgxMCIv
Pjwvc3ZnPmAKICAgIH07CgogICAgZnVuY3Rpb24gZmlsZUV4dChwYXRoKSB7CiAgICAgICAgY29uc3Qg
YmFzZSA9IFN0cmluZyhwYXRoIHx8ICcnKS5zcGxpdCgvW1xcL10vKS5wb3AoKSB8fCAnJzsKICAgICAg
ICBjb25zdCBpID0gYmFzZS5sYXN0SW5kZXhPZignLicpOwogICAgICAgIHJldHVybiBpID4gMCA/IGJh
c2Uuc2xpY2UoaSArIDEpLnRvTG93ZXJDYXNlKCkgOiAnJzsKICAgIH0KICAgIGNvbnN0IGlzSW1hZ2VF
eHQgPSBlID0+IFsncG5nJywnanBnJywnanBlZycsJ2dpZicsJ3dlYnAnLCdibXAnLCdpY28nLCd0aWYn
LCd0aWZmJywnc3ZnJ10uaW5jbHVkZXMoZSk7CiAgICBjb25zdCBpc1ZpZGVvRXh0ID0gZSA9PiBbJ21w
NCcsJ21rdicsJ2F2aScsJ21vdicsJ3dtdicsJ2ZsdicsJ3dlYm0nLCdtNHYnLCdtcGVnJywnbXBnJywn
dHMnLCdtMnRzJywnM2dwJywncm0nLCdybXZiJ10uaW5jbHVkZXMoZSk7CiAgICBjb25zdCBpc1ppcEV4
dCAgID0gZSA9PiBbJ3ppcCcsJ3JhcicsJzd6JywndGFyJywnZ3onLCdiejInXS5pbmNsdWRlcyhlKTsK
CiAgICBmdW5jdGlvbiBpY29uRm9yRmlsZXMoZmlsZXMpIHsKICAgICAgICBpZiAoIWZpbGVzLmxlbmd0
aCkgICAgcmV0dXJuIHsgY2xzOiAnZmlsZSBmdC1kb2MnLCBzdmc6IFNWRy5kb2MgfTsKICAgICAgICBp
ZiAoZmlsZXMubGVuZ3RoID4gMSkgcmV0dXJuIHsgY2xzOiAnZmlsZSBmdC1sbmsnLCBzdmc6IFNWRy5t
dWx0aSB9OwogICAgICAgIGNvbnN0IGV4dCA9IGZpbGVFeHQoZmlsZXNbMF0pOwogICAgICAgIGlmICgh
ZXh0KSAgICAgICAgICAgICAgcmV0dXJuIHsgY2xzOiAnZmlsZSBmdC1kaXInLCBzdmc6IFNWRy5mb2xk
ZXIgfTsKICAgICAgICBpZiAoaXNJbWFnZUV4dChleHQpKSAgIHJldHVybiB7IGNsczogJ2ZpbGUgZnQt
aW1nJywgc3ZnOiBTVkcuaW1hZ2UgfTsKICAgICAgICBpZiAoaXNWaWRlb0V4dChleHQpKSAgIHJldHVy
biB7IGNsczogJ2ZpbGUgZnQtdmlkJywgc3ZnOiAoU1ZHLnZpZGVvIHx8IFNWRy5kb2MpIH07CiAgICAg
ICAgaWYgKGlzWmlwRXh0KGV4dCkpICAgICByZXR1cm4geyBjbHM6ICdmaWxlIGZ0LXppcCcsIHN2Zzog
U1ZHLnppcCB9OwogICAgICAgIGlmIChleHQgPT09ICdhaGsnKSAgICAgcmV0dXJuIHsgY2xzOiAnZmls
ZSBmdC1haGsnLCBzdmc6IFNWRy5haGsgfTsKICAgICAgICBpZiAoZXh0ID09PSAnbG5rJykgICAgIHJl
dHVybiB7IGNsczogJ2ZpbGUgZnQtbG5rJywgc3ZnOiBTVkcubG5rIH07CiAgICAgICAgcmV0dXJuIHsg
Y2xzOiAnZmlsZSBmdC1kb2MnLCBzdmc6IFNWRy5kb2MgfTsKICAgIH0KCiAgICBmdW5jdGlvbiBzcmNX
aW5MYWJlbChjKSB7CiAgICAgICAgY29uc3QgdCA9IFN0cmluZyhjICYmIGMuc3JjVGl0bGUgfHwgJycp
LnRyaW0oKTsKICAgICAgICBpZiAodCkgcmV0dXJuIHQ7CiAgICAgICAgcmV0dXJuIFN0cmluZyhjICYm
IGMuc3JjRXhlIHx8ICcnKS5yZXBsYWNlKC9cLmV4ZSQvaSwgJycpOwogICAgfQogICAgZnVuY3Rpb24g
c3JjVGl0bGVIdG1sKGMpIHsKICAgICAgICAvLyDliJfooajkuK3pl7Qv5Y+z5L6n5LiN5YaN5pi+56S6
56qX5Y+j5qCH6aKY77yM5p2l5rqQ5Y+q5L+d55WZ5Y+z5L6n5Zu+5qCH5oKs5YGc5o+Q56S6CiAgICAg
ICAgcmV0dXJuICcnOwogICAgfQogICAgZnVuY3Rpb24gZXhwYW5kQ2hldnJvbihvcGVuKSB7CiAgICAg
ICAgcmV0dXJuIG9wZW4KICAgICAgICAgICAgPyBgPHN2ZyB2aWV3Qm94PSIwIDAgMTYgMTYiIHdpZHRo
PSIxNCIgaGVpZ2h0PSIxNCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0cm9rZS13
aWR0aD0iMS44IiBzdHJva2UtbGluZWNhcD0icm91bmQiPjxwb2x5bGluZSBwb2ludHM9IjQgMTAgOCA2
IDEyIDEwIi8+PC9zdmc+PHNwYW4+5pS26LW3PC9zcGFuPmAKICAgICAgICAgICAgOiBgPHN2ZyB2aWV3
Qm94PSIwIDAgMTYgMTYiIHdpZHRoPSIxNCIgaGVpZ2h0PSIxNCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSJj
dXJyZW50Q29sb3IiIHN0cm9rZS13aWR0aD0iMS44IiBzdHJva2UtbGluZWNhcD0icm91bmQiPjxwb2x5
bGluZSBwb2ludHM9IjQgNiA4IDEwIDEyIDYiLz48L3N2Zz48c3Bhbj7lsZXlvIA8L3NwYW4+YDsKICAg
IH0KICAgIGZ1bmN0aW9uIGxpc3RFeHBhbmRNYXhQeCgpIHsKICAgICAgICBjb25zdCBoID0gKGxpc3RF
bCAmJiBsaXN0RWwuY2xpZW50SGVpZ2h0KSB8fCAzNjA7CiAgICAgICAgLy8g5Yeg5LmO5Y2g5ruh5YiX
6KGo77yM5bqV6YOo55WZ57qm5LiA6KGMCiAgICAgICAgcmV0dXJuIE1hdGgubWF4KDk2LCBoIC0gMjgp
OwogICAgfQogICAgZnVuY3Rpb24gYXBwbHlFeHBhbmRlZFByZXZpZXcocHJldiwgZnVsbFRleHQpIHsK
ICAgICAgICBjb25zdCBtYXhIID0gbGlzdEV4cGFuZE1heFB4KCk7CiAgICAgICAgcHJldi5zdHlsZS5t
YXhIZWlnaHQgPSBtYXhIICsgJ3B4JzsKICAgICAgICBwcmV2LmNsYXNzTGlzdC5hZGQoJ2V4cGFuZGVk
Jyk7CiAgICAgICAgc2V0SGxUZXh0KHByZXYsIGZ1bGxUZXh0KTsKICAgICAgICAvLyDku43muqLlh7rv
vJrmiKrmlq3lubblnKjmnKvlsL7liqDjgIwgLi4u44CNCiAgICAgICAgaWYgKHByZXYuc2Nyb2xsSGVp
Z2h0IDw9IHByZXYuY2xpZW50SGVpZ2h0ICsgMikKICAgICAgICAgICAgcmV0dXJuOwogICAgICAgIGxl
dCBsbyA9IDAsIGhpID0gZnVsbFRleHQubGVuZ3RoLCBiZXN0ID0gMDsKICAgICAgICB3aGlsZSAobG8g
PD0gaGkpIHsKICAgICAgICAgICAgY29uc3QgbWlkID0gKGxvICsgaGkpID4+IDE7CiAgICAgICAgICAg
IHNldEhsVGV4dChwcmV2LCBmdWxsVGV4dC5zbGljZSgwLCBtaWQpICsgJyAuLi4nKTsKICAgICAgICAg
ICAgaWYgKHByZXYuc2Nyb2xsSGVpZ2h0IDw9IHByZXYuY2xpZW50SGVpZ2h0ICsgMikgewogICAgICAg
ICAgICAgICAgYmVzdCA9IG1pZDsKICAgICAgICAgICAgICAgIGxvID0gbWlkICsgMTsKICAgICAgICAg
ICAgfSBlbHNlIHsKICAgICAgICAgICAgICAgIGhpID0gbWlkIC0gMTsKICAgICAgICAgICAgfQogICAg
ICAgIH0KICAgICAgICBzZXRIbFRleHQocHJldiwgZnVsbFRleHQuc2xpY2UoMCwgYmVzdCkgKyAnIC4u
LicpOwogICAgfQogICAgZnVuY3Rpb24gY29sbGFwc2VQcmV2aWV3KHByZXYsIGZ1bGxUZXh0KSB7CiAg
ICAgICAgcHJldi5jbGFzc0xpc3QucmVtb3ZlKCdleHBhbmRlZCcpOwogICAgICAgIHByZXYuc3R5bGUu
bWF4SGVpZ2h0ID0gJyc7CiAgICAgICAgc2V0SGxUZXh0KHByZXYsIGZ1bGxUZXh0KTsKICAgIH0KCiAg
ICBmdW5jdGlvbiBmYXZHcm91cE9mKGMpIHsKICAgICAgICByZXR1cm4gU3RyaW5nKGMgJiYgYy5mYXZH
cm91cCB8fCAnJykudHJpbSgpOwogICAgfQogICAgZnVuY3Rpb24gY2xpcENvbnRlbnRQcmV2aWV3KGMp
IHsKICAgICAgICBjb25zdCB0eXBlID0gbm9ybVR5cGUoYy50eXBlKTsKICAgICAgICBpZiAodHlwZSA9
PT0gJ2ltYWdlJykgcmV0dXJuICdb5Zu+5YOPXScgKyAoYy53aWR0aCAmJiBjLmhlaWdodCA/ICgnICcg
KyBjLndpZHRoICsgJ8OXJyArIGMuaGVpZ2h0KSA6ICcnKTsKICAgICAgICBpZiAodHlwZSA9PT0gJ2Zp
bGUnKSB7CiAgICAgICAgICAgIGNvbnN0IGZpbGVzID0gU3RyaW5nKGMucHJldmlldyB8fCBjLmRhdGEg
fHwgJycpLnNwbGl0KC9ccj9cbi8pLmZpbHRlcihCb29sZWFuKTsKICAgICAgICAgICAgcmV0dXJuIGZp
bGVzLm1hcChmID0+IGYuc3BsaXQoL1tcXC9dLykucG9wKCkpLmpvaW4oJyDCtyAnKSB8fCAnW+aWh+S7
tl0nOwogICAgICAgIH0KICAgICAgICBsZXQgX3AgPSBTdHJpbmcoYy5wcmV2aWV3IHx8IGMuZGF0YSB8
fCAnJyk7CiAgICAgICAgeyBjb25zdCBfbiA9IE51bWJlcihjLmNoYXJDb3VudCkgfHwgMDsgaWYgKF9u
ID4gX3AubGVuZ3RoICYmIF9wLmxlbmd0aCkgX3AgKz0gJy4uLic7IH0KICAgICAgICByZXR1cm4gX3A7
CiAgICB9CiAgICBmdW5jdGlvbiBidWlsZFBpbm5lZEJsb2NrcyhsaXN0KSB7CiAgICAgICAgY29uc3Qg
dXNlZCA9IG5ldyBTZXQoKTsKICAgICAgICBjb25zdCBvdXQgPSBbXTsKICAgICAgICBmb3IgKGNvbnN0
IGMgb2YgbGlzdCkgewogICAgICAgICAgICBpZiAodXNlZC5oYXMoK2MuaWQpKSBjb250aW51ZTsKICAg
ICAgICAgICAgY29uc3QgZ2lkID0gZmF2R3JvdXBPZihjKTsKICAgICAgICAgICAgaWYgKCFnaWQpIHsK
ICAgICAgICAgICAgICAgIHVzZWQuYWRkKCtjLmlkKTsKICAgICAgICAgICAgICAgIG91dC5wdXNoKHsg
a2luZDogJ3NpbmdsZScsIGl0ZW1zOiBbY10gfSk7CiAgICAgICAgICAgICAgICBjb250aW51ZTsKICAg
ICAgICAgICAgfQogICAgICAgICAgICBjb25zdCBtZW1iZXJzID0gbGlzdC5maWx0ZXIoeCA9PiBmYXZH
cm91cE9mKHgpID09PSBnaWQpOwogICAgICAgICAgICBtZW1iZXJzLmZvckVhY2gobSA9PiB1c2VkLmFk
ZCgrbS5pZCkpOwogICAgICAgICAgICBpZiAobWVtYmVycy5sZW5ndGggPCAyKQogICAgICAgICAgICAg
ICAgb3V0LnB1c2goeyBraW5kOiAnc2luZ2xlJywgaXRlbXM6IFttZW1iZXJzWzBdIHx8IGNdIH0pOwog
ICAgICAgICAgICBlbHNlCiAgICAgICAgICAgICAgICBvdXQucHVzaCh7IGtpbmQ6ICdncm91cCcsIGdp
ZCwgaXRlbXM6IG1lbWJlcnMgfSk7CiAgICAgICAgfQogICAgICAgIHJldHVybiBvdXQ7CiAgICB9CiAg
ICBmdW5jdGlvbiBfX3ByZXBQYXN0ZSgpIHsKICAgICAgICB0cnkgewogICAgICAgICAgICBjb25zdCBz
ID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NlYXJjaCcpOwogICAgICAgICAgICBpZiAocyAmJiBk
b2N1bWVudC5hY3RpdmVFbGVtZW50ID09PSBzKSB0cnkgeyBzLmJsdXIoKTsgfSBjYXRjaCB7fQogICAg
ICAgICAgICBpZiAod2luZG93LmdldFNlbGVjdGlvbikgd2luZG93LmdldFNlbGVjdGlvbigpLnJlbW92
ZUFsbFJhbmdlcygpOwogICAgICAgIH0gY2F0Y2gge30KICAgIH0KICAgIGZ1bmN0aW9uIHBhc3RlT25l
KGMpIHsKICAgICAgICBfX3ByZXBQYXN0ZSgpOwogICAgICAgIHNlbGVjdGVkSWQgPSBjLmlkOwogICAg
ICAgIGlmIChtdWx0aUlkcy5sZW5ndGgpIGNsZWFyTXVsdGkoKTsKICAgICAgICBzeW5jSXRlbUhpZ2hs
aWdodCgpOwogICAgICAgIG1hcmtQYXN0ZWRMb2NhbChjLmlkKTsKICAgICAgICBhaGsoJ3Bhc3RlJywg
U3RyaW5nKGMuaWQpKTsKICAgIH0KICAgIGZ1bmN0aW9uIG9wZW5SZWNlbnREaXIocGF0aCkgewogICAg
ICAgIGxldCBwID0gU3RyaW5nKHBhdGggfHwgJycpLnRyaW0oKTsKICAgICAgICBpZiAoIXApIHJldHVy
bjsKICAgICAgICBpZiAoL15bYS16QS1aXTokLy50ZXN0KHApKSBwICs9ICdcXCc7CiAgICAgICAgLy8g
57uf5LiAIC8g77ya6YG/5YWNIFdlYlZpZXcgaG9zdC9KU09OIOWQg+aOieWPjeaWnOadoAogICAgICAg
IGNvbnN0IHdpcmUgPSBwLnJlcGxhY2UoL1xcL2csICcvJyk7CiAgICAgICAgY29uc3Qgc2VuZCA9ICgp
ID0+IHsKICAgICAgICAgICAgLy8gMSkgcG9zdE1lc3NhZ2Ug5pyA56iz77yI5LiN6L+bIHN5bmMgQ09N
77yJCiAgICAgICAgICAgIHRyeSB7CiAgICAgICAgICAgICAgICBpZiAod2luZG93LmNocm9tZSAmJiBj
aHJvbWUud2VidmlldyAmJiB0eXBlb2YgY2hyb21lLndlYnZpZXcucG9zdE1lc3NhZ2UgPT09ICdmdW5j
dGlvbicpIHsKICAgICAgICAgICAgICAgICAgICBjaHJvbWUud2Vidmlldy5wb3N0TWVzc2FnZSgnb3Bl
bkRpcnwnICsgd2lyZSk7CiAgICAgICAgICAgICAgICAgICAgcmV0dXJuIHRydWU7CiAgICAgICAgICAg
ICAgICB9CiAgICAgICAgICAgIH0gY2F0Y2gge30KICAgICAgICAgICAgLy8gMikgYXN5bmMgaG9zdO+8
iOmdniBzeW5j77yJCiAgICAgICAgICAgIHRyeSB7CiAgICAgICAgICAgICAgICBjb25zdCBob3N0ID0g
Y2hyb21lLndlYnZpZXcuaG9zdE9iamVjdHMuYWhrOwogICAgICAgICAgICAgICAgaWYgKGhvc3QgJiYg
aG9zdC5vcGVuRGlyKSB7CiAgICAgICAgICAgICAgICAgICAgUHJvbWlzZS5yZXNvbHZlKGhvc3Qub3Bl
bkRpcih3aXJlKSkuY2F0Y2goKCkgPT4ge30pOwogICAgICAgICAgICAgICAgICAgIHJldHVybiB0cnVl
OwogICAgICAgICAgICAgICAgfQogICAgICAgICAgICB9IGNhdGNoIHt9CiAgICAgICAgICAgIC8vIDMp
IOacgOWQjuaJjSBzeW5jCiAgICAgICAgICAgIHRyeSB7IGFoaygnb3BlbkRpcicsIHdpcmUpOyByZXR1
cm4gdHJ1ZTsgfSBjYXRjaCB7fQogICAgICAgICAgICByZXR1cm4gZmFsc2U7CiAgICAgICAgfTsKICAg
ICAgICAvLyDnprvlvIAgcG9pbnRlciDkuovku7bmoIjlho3osIPvvIzpgb/lhY0gV2ViVmlldzIg5ZCM
5q2l5q276ZSB5a+86Ie04oCc54K55LqG5rKh5Y+N5bqU4oCdCiAgICAgICAgc2V0VGltZW91dChzZW5k
LCAwKTsKICAgIH0KICAgIGZ1bmN0aW9uIGlzSXRlbUNocm9tZVRhcmdldCh0KSB7CiAgICAgICAgcmV0
dXJuICEhKHQgJiYgdC5jbG9zZXN0ICYmIHQuY2xvc2VzdCgnLmktZXhwYW5kLWJ0biwgLmktc3JjLWlj
bywgLm1nLXNyYywgLmZkLWJ0biwgLmZkLXBhdGgsIC5yZi1zZWcsIGJ1dHRvbiwgYSwgaW5wdXQnKSk7
CiAgICB9CiAgICBmdW5jdGlvbiBiZWdpblBhc3RlRnJvbUl0ZW0oZSwgYykgewogICAgICAgIGlmIChl
LmJ1dHRvbiAhPSBudWxsICYmIGUuYnV0dG9uICE9PSAwKSByZXR1cm47CiAgICAgICAgY29uc3Qgc2Vn
ID0gZS50YXJnZXQgJiYgZS50YXJnZXQuY2xvc2VzdCAmJiBlLnRhcmdldC5jbG9zZXN0KCcucmYtc2Vn
Jyk7CiAgICAgICAgaWYgKHNlZykgewogICAgICAgICAgICBjb25zdCBvcGVuUGF0aCA9IHNlZy5fb3Bl
blBhdGggfHwgc2VnLmdldEF0dHJpYnV0ZSgnZGF0YS1wYXRoJykgfHwgc2VnLmRhdGFzZXQub3BlblBh
dGggfHwgJyc7CiAgICAgICAgICAgIGlmIChvcGVuUGF0aCkgewogICAgICAgICAgICAgICAgZS5wcmV2
ZW50RGVmYXVsdCgpOwogICAgICAgICAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICAg
ICAgICAgIG9wZW5SZWNlbnREaXIob3BlblBhdGgpOwogICAgICAgICAgICAgICAgcmV0dXJuOwogICAg
ICAgICAgICB9CiAgICAgICAgfQogICAgICAgIGlmIChlLnRhcmdldCAmJiBlLnRhcmdldC5jbG9zZXN0
ICYmIGUudGFyZ2V0LmNsb3Nlc3QoJy5yZi1wYXRoJykpCiAgICAgICAgICAgIHJldHVybjsKICAgICAg
ICBpZiAoaXNJdGVtQ2hyb21lVGFyZ2V0KGUudGFyZ2V0KSkgcmV0dXJuOwogICAgICAgIGlmIChub3Jt
VHlwZShjLnR5cGUpID09PSAncmVjZW50JykgewogICAgICAgICAgICBhY3RpdmF0ZUNsaXBJdGVtKGMp
OwogICAgICAgICAgICByZXR1cm47CiAgICAgICAgfQogICAgICAgIGlmIChoYW5kbGVJdGVtQ2xpY2so
ZSwgYykpCiAgICAgICAgICAgIHJldHVybjsKICAgICAgICBfX3ByZXBQYXN0ZSgpOwogICAgICAgIHNl
bGVjdGVkSWQgPSBjLmlkOwogICAgICAgIHJhbmdlQW5jaG9ySWQgPSBjLmlkOwogICAgICAgIGlmICht
dWx0aUlkcy5sZW5ndGggPiAwICYmIG11bHRpSWRzLmluY2x1ZGVzKCtjLmlkKSkgewogICAgICAgICAg
ICBjb25zdCBpZHMgPSBtdWx0aUlkcy5zbGljZSgpOwogICAgICAgICAgICBjbGVhck11bHRpKCk7CiAg
ICAgICAgICAgIG1hcmtQYXN0ZWRMb2NhbChpZHMpOwogICAgICAgICAgICBpZiAoaWRzLmxlbmd0aCA+
IDEpIGFoaygncGFzdGVNYW55JywgaWRzLmpvaW4oJywnKSk7CiAgICAgICAgICAgIGVsc2UgYWhrKCdw
YXN0ZScsIFN0cmluZyhpZHNbMF0pKTsKICAgICAgICAgICAgcmV0dXJuOwogICAgICAgIH0KICAgICAg
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
OwogICAgICAgICAgICBpZiAobXVsdGlJZHMubGVuZ3RoID4gMSkgewogICAgICAgICAgICAgICAgY29u
c3QgaWRzID0gbXVsdGlJZHMuc2xpY2UoKTsKICAgICAgICAgICAgICAgIGNsZWFyTXVsdGkoKTsKICAg
ICAgICAgICAgICAgIG1hcmtQYXN0ZWRMb2NhbChpZHMpOwogICAgICAgICAgICAgICAgYWhrKCdwYXN0
ZU1hbnknLCBpZHMuam9pbignLCcpKTsKICAgICAgICAgICAgICAgIHJldHVybjsKICAgICAgICAgICAg
fQogICAgICAgICAgICBpZiAobXVsdGlJZHMubGVuZ3RoID09PSAxKSB7CiAgICAgICAgICAgICAgICBj
b25zdCBpZCA9IG11bHRpSWRzWzBdOwogICAgICAgICAgICAgICAgY2xlYXJNdWx0aSgpOwogICAgICAg
ICAgICAgICAgbWFya1Bhc3RlZExvY2FsKGlkKTsKICAgICAgICAgICAgICAgIGFoaygncGFzdGUnLCBT
dHJpbmcoaWQpKTsKICAgICAgICAgICAgICAgIHJldHVybjsKICAgICAgICAgICAgfQogICAgICAgICAg
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
dGlJZHMubGVuZ3RoID4gMSkgewogICAgICAgICAgICAgICAgY29uc3QgaWRzID0gbXVsdGlJZHMuc2xp
Y2UoKTsKICAgICAgICAgICAgICAgIGNsZWFyTXVsdGkoKTsKICAgICAgICAgICAgICAgIG1hcmtQYXN0
ZWRMb2NhbChpZHMpOwogICAgICAgICAgICAgICAgYWhrKCdwYXN0ZU1hbnknLCBpZHMuam9pbignLCcp
KTsKICAgICAgICAgICAgICAgIHJldHVybjsKICAgICAgICAgICAgfQogICAgICAgICAgICBpZiAobXVs
dGlJZHMubGVuZ3RoID09PSAxKSB7CiAgICAgICAgICAgICAgICBjb25zdCBpZCA9IG11bHRpSWRzWzBd
OwogICAgICAgICAgICAgICAgY2xlYXJNdWx0aSgpOwogICAgICAgICAgICAgICAgbWFya1Bhc3RlZExv
Y2FsKGlkKTsKICAgICAgICAgICAgICAgIGFoaygncGFzdGUnLCBTdHJpbmcoaWQpKTsKICAgICAgICAg
ICAgICAgIHJldHVybjsKICAgICAgICAgICAgfQogICAgICAgICAgICBjb25zdCBjID0gdmlzW3NlbGVj
dGVkSW5kZXgoKV07CiAgICAgICAgICAgIGlmIChjKSB7CiAgICAgICAgICAgICAgICBtYXJrUGFzdGVk
TG9jYWwoYy5pZCk7CiAgICAgICAgICAgICAgICBhaGsoJ3Bhc3RlJywgU3RyaW5nKGMuaWQpKTsKICAg
ICAgICAgICAgfQogICAgICAgIH0KICAgIH07CgogICAgLy8gQUhLIEVudGVyIGhvdGtleSBsYW5kcyBo
ZXJlIChXZWJWaWV3IG1heSBub3QgcmVjZWl2ZSB0aGUga2V5IHdoaWxlIHVucGlubmVkKQogICAgd2lu
ZG93Ll9fZWRpdFRpdGxlID0gKCkgPT4gewogICAgICAgIGxldCBjID0gbnVsbDsKICAgICAgICBpZiAo
c2VsZWN0ZWRJZCkKICAgICAgICAgICAgYyA9IGFsbENsaXBzLmZpbmQoeCA9PiAreC5pZCA9PT0gK3Nl
bGVjdGVkSWQpIHx8IG51bGw7CiAgICAgICAgaWYgKCFjICYmIGN0eENsaXApCiAgICAgICAgICAgIGMg
PSBjdHhDbGlwOwogICAgICAgIGlmICghYykgewogICAgICAgICAgICBjb25zdCB2aXMgPSB2aXNpYmxl
TGlzdCgpOwogICAgICAgICAgICBpZiAodmlzLmxlbmd0aCkgYyA9IHZpc1swXTsKICAgICAgICB9CiAg
ICAgICAgaWYgKCFjKSByZXR1cm47CiAgICAgICAgb3BlblRpdGxlRGxnKGMpOwogICAgfTsKCiAgICB3
aW5kb3cuX19vbkVudGVyID0gKCkgPT4gewogICAgICAgIGNvbnN0IHRkID0gZG9jdW1lbnQuZ2V0RWxl
bWVudEJ5SWQoJ3RpdGxlLWRsZycpOwogICAgICAgIGlmICh0ZCAmJiB0ZC5jbGFzc0xpc3QuY29udGFp
bnMoJ29uJykpIHsKICAgICAgICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3RpdGxlLW9rJyk/
LmNsaWNrKCk7CiAgICAgICAgICAgIHJldHVybjsKICAgICAgICB9CiAgICAgICAgaWYgKGRvY3VtZW50
LmFjdGl2ZUVsZW1lbnQ/LmlkID09PSAndGl0bGUtaW5wdXQnKSB7CiAgICAgICAgICAgIGRvY3VtZW50
LmdldEVsZW1lbnRCeUlkKCd0aXRsZS1vaycpPy5jbGljaygpOwogICAgICAgICAgICByZXR1cm47CiAg
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
KyAoISFrZWVwU2VhcmNoKSk7CiAgICAgICAgLy8gRG8gTk9UIGZvY3VzIFdlYlZpZXcg4oCUIGtlZXAg
ZWRpdG9yIGNhcmV0L2ZvY3VzIChBSEsgaGFuZGxlcyBrZXlzIHZpYSAjSG90SWYpCiAgICAgICAgLy8g
V2luK1Y6IGNvbGxhcHNlIHNlYXJjaC4gPz8gc2VhcmNoOiBrZWVwL29wZW4gc2VhcmNoIGJveC4KICAg
ICAgICBrZWVwU2VhcmNoID0gISFrZWVwU2VhcmNoOwogICAgICAgIHRyeSB7IGhpZGVDdHgoKTsgfSBj
YXRjaCB7fQogICAgICAgIHRyeSB7IGNsb3NlVGl0bGVEbGcoKTsgfSBjYXRjaCB7fQogICAgICAgIHRy
eSB7CiAgICAgICAgICAgIGNvbnN0IHdyYXAgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc2VhcmNo
LXdyYXAnKTsKICAgICAgICAgICAgY29uc3Qgc3JjaCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdz
ZWFyY2gnKTsKICAgICAgICAgICAgY29uc3Qgc2NsciA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdz
ZWFyY2gtY2xyJyk7CiAgICAgICAgICAgIGlmICgha2VlcFNlYXJjaCkgewogICAgICAgICAgICAgICAg
aWYgKHdyYXApIHdyYXAuY2xhc3NMaXN0LnJlbW92ZSgnb3BlbicpOwogICAgICAgICAgICAgICAgaWYg
KHNyY2gpIHsKICAgICAgICAgICAgICAgICAgICBzcmNoLnZhbHVlID0gJyc7CiAgICAgICAgICAgICAg
ICAgICAgc3JjaC5jbGFzc0xpc3QucmVtb3ZlKCdoYXMtdmFsJyk7CiAgICAgICAgICAgICAgICAgICAg
dHJ5IHsgc3JjaC5ibHVyKCk7IH0gY2F0Y2gge30KICAgICAgICAgICAgICAgIH0KICAgICAgICAgICAg
ICAgIGlmIChzY2xyKSBzY2xyLnN0eWxlLmRpc3BsYXkgPSAnbm9uZSc7CiAgICAgICAgICAgICAgICBx
dWVyeSA9ICcnOwogICAgICAgICAgICAgICAgd2luZG93Ll9faG9zdEZpbHRlcmVkID0gZmFsc2U7CiAg
ICAgICAgICAgICAgICB3aW5kb3cuX19ob3N0RmlsdGVyUSA9ICcnOwogICAgICAgICAgICAgICAgLy8g
V2luK1bvvJrnq4vliLvnlKjmnKrov4fmu6TnvJPlrZjpk7rliJfooajvvIzpgb/lhY3lhYjpl6rov4fm
u6Tnu5Pmnpwv56m65aOz5YaN562JIFNldFZpZXcKICAgICAgICAgICAgICAgIHRyeSB7CiAgICAgICAg
ICAgICAgICAgICAgY29uc3QgaGl0ID0gdmlld01lbS5nZXQodmlld01lbUtleSgnYWxsJywgJycsIGZh
bHNlKSk7CiAgICAgICAgICAgICAgICAgICAgaWYgKGhpdCAmJiBBcnJheS5pc0FycmF5KGhpdC5pdGVt
cykgJiYgaGl0Lml0ZW1zLmxlbmd0aCkgewogICAgICAgICAgICAgICAgICAgICAgICBhbGxDbGlwcyA9
IGhpdC5pdGVtcy5zbGljZSgpOwogICAgICAgICAgICAgICAgICAgICAgICBkaXNrVG90YWwgPSBOdW1i
ZXIoaGl0LnRvdGFsKSB8fCBoaXQuaXRlbXMubGVuZ3RoOwogICAgICAgICAgICAgICAgICAgICAgICB3
aW5kb3cuX19kYXRhUmVhZHkgPSB0cnVlOwogICAgICAgICAgICAgICAgICAgICAgICBob3N0UHVzaGVk
T25jZSA9IHRydWU7CiAgICAgICAgICAgICAgICAgICAgICAgIHNhd05vbkVtcHR5ID0gdHJ1ZTsKICAg
ICAgICAgICAgICAgICAgICAgICAgY2xlYXJXYWl0aW5nRGF0YSgpOwogICAgICAgICAgICAgICAgICAg
IH0gZWxzZSB7CiAgICAgICAgICAgICAgICAgICAgICAgIHNjaGVkdWxlRGVsYXllZFNrZWwoKTsKICAg
ICAgICAgICAgICAgICAgICB9CiAgICAgICAgICAgICAgICB9IGNhdGNoIHsKICAgICAgICAgICAgICAg
ICAgICBzY2hlZHVsZURlbGF5ZWRTa2VsKCk7CiAgICAgICAgICAgICAgICB9CiAgICAgICAgICAgIH0g
ZWxzZSBpZiAod3JhcCkgewogICAgICAgICAgICAgICAgd3JhcC5jbGFzc0xpc3QuYWRkKCdvcGVuJyk7
CiAgICAgICAgICAgICAgICBpZiAoc3JjaCAmJiBzcmNoLnZhbHVlKQogICAgICAgICAgICAgICAgICAg
IHF1ZXJ5ID0gc3JjaC52YWx1ZTsKICAgICAgICAgICAgICAgIC8vID8/IOaQnOe0ou+8muWcqOS4u+ac
uui/h+a7pOe7k+aenOWIsOi+vuWJje+8jOWFiOaMieWFs+mUruWtl+acrOWcsOa7pO+8jOemgeatoumX
quWHuuOAjOWFqOmDqOOAjQogICAgICAgICAgICAgICAgaWYgKFN0cmluZyhxdWVyeSB8fCAnJykudHJp
bSgpKSB7CiAgICAgICAgICAgICAgICAgICAgd2luZG93Ll9faG9zdEZpbHRlcmVkID0gZmFsc2U7CiAg
ICAgICAgICAgICAgICAgICAgd2luZG93Ll9faG9zdEZpbHRlclEgPSAnJzsKICAgICAgICAgICAgICAg
IH0KICAgICAgICAgICAgfQogICAgICAgICAgICB0b2RheU9ubHkgPSBmYWxzZTsKICAgICAgICAgICAg
dHJ5IHsKICAgICAgICAgICAgICAgIGNvbnN0IGJ0blRvZGF5ID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5
SWQoJ2J0bi10b2RheScpOwogICAgICAgICAgICAgICAgaWYgKGJ0blRvZGF5KSBidG5Ub2RheS5jbGFz
c0xpc3QucmVtb3ZlKCdvbicpOwogICAgICAgICAgICB9IGNhdGNoIHt9CiAgICAgICAgICAgIGN1clRh
YiA9ICdhbGwnOwogICAgICAgICAgICBsb2FkaW5nTW9yZSA9IGZhbHNlOwogICAgICAgICAgICBtYXJr
VGFiKCdhbGwnKTsKICAgICAgICAgICAgLy8g5LiN6KaBIGFoaygnYmx1clBhbmVsJynvvJrkvJrot58g
U2hvd1BhbmVsIOaKoueEpueCue+8jFdpbitWLz8/IOmDveWuueaYk+mXquOAgeS5sei3swogICAgICAg
ICAgICByZW5kZXIoKTsKICAgICAgICAgICAgLy8g5ZCM5q2l5b2T5YmNIHRhYi9xdWVyeSDliLAgQUhL
77yIPz8g5pu+5Y+q55SoIHZpZXdUYWIg5pCc6ZSZ6aG177yJCiAgICAgICAgICAgIHJlcXVlc3RWaWV3
KCk7CiAgICAgICAgfSBjYXRjaCB7fQogICAgICAgIHNlbGVjdEZpcnN0T25TaG93ID0gdHJ1ZTsKICAg
ICAgICBsb2NhdGVBY3RpdmUgPSBmYWxzZTsKICAgICAgICB1cGRhdGVMb2NhdGVCdG4oKTsKICAgICAg
ICBjbGVhck11bHRpKCk7CiAgICAgICAgY29uc3QgdmlzID0gdmlzaWJsZUxpc3QoKTsKICAgICAgICBp
ZiAodmlzLmxlbmd0aCkgewogICAgICAgICAgICBzZWxlY3RlZElkID0gdmlzWzBdLmlkOwogICAgICAg
ICAgICByYW5nZUFuY2hvcklkID0gc2VsZWN0ZWRJZDsKICAgICAgICAgICAgcmFuZ2VBbmNob3JDbGlj
a2VkID0gZmFsc2U7CiAgICAgICAgICAgIGxpc3RFbC5zY3JvbGxUb3AgPSAwOwogICAgICAgIH0KICAg
ICAgICBzeW5jSXRlbUhpZ2hsaWdodCgpOwogICAgfTsKCiAgICBmdW5jdGlvbiBjdHhCaW5kKGlkLCBm
bikgewogICAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKGlkKS5hZGRFdmVudExpc3RlbmVyKCdj
bGljaycsIGUgPT4gewogICAgICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgICAgICAgICBp
ZiAoY3R4Q2xpcCkgZm4oY3R4Q2xpcCk7CiAgICAgICAgICAgIGhpZGVDdHgoKTsKICAgICAgICB9KTsK
ICAgIH0KICAgIGN0eEJpbmQoJ2MtY29weScsICBjID0+IHsKICAgICAgICBpZiAobm9ybVR5cGUoYy50
eXBlKSA9PT0gJ3JlY2VudCcpCiAgICAgICAgICAgIGFoaygnY29weVBhdGgnLCBTdHJpbmcoYy5kYXRh
IHx8IGMucHJldmlldyB8fCAnJykpOwogICAgICAgIGVsc2UKICAgICAgICAgICAgYWhrKCdjb3B5QnlJ
ZCcsIFN0cmluZyhjLmlkKSk7CiAgICB9KTsKICAgIGN0eEJpbmQoJ2MtcGFzdGUnLCBjID0+IHsKICAg
ICAgICBhY3RpdmF0ZUNsaXBJdGVtKGMpOwogICAgfSk7CiAgICBjdHhCaW5kKCdjLXBpbicsICAgYyA9
PiB7CiAgICAgICAgLy8gT3B0aW1pc3RpYyBmbGlwIOKAlCDlm7rlrprlj6rpmLLmt5jmsbDvvIzkuI3n
va7pobbvvJvlho3mrKHorr/pl67miY3pnaAgUmVjb3JkIOmhtuWIsOS4iumdogogICAgICAgIGNvbnN0
IG5leHQgPSAhaXNQaW5uZWQoYyk7CiAgICAgICAgYy5waW5uZWQgPSBuZXh0OwogICAgICAgIGNvbnN0
IGlkID0gK2MuaWQ7CiAgICAgICAgZm9yIChjb25zdCB4IG9mIGFsbENsaXBzKSB7CiAgICAgICAgICAg
IGlmICgreC5pZCA9PT0gaWQpIHgucGlubmVkID0gbmV4dDsKICAgICAgICB9CiAgICAgICAgcmVuZGVy
KCk7CiAgICAgICAgYWhrKCdwaW4nLCBTdHJpbmcoYy5pZCkpOwogICAgfSk7CiAgICBjdHhCaW5kKCdj
LXRvcCcsICAgYyA9PiBhaGsoJ21vdmVUb1RvcCcsICAgICBTdHJpbmcoYy5pZCkpKTsKICAgIGN0eEJp
bmQoJ2MtY2xlYXItcGFzdGVkJywgYyA9PiBhaGsoJ2NsZWFyUGFzdGVkJywgU3RyaW5nKGMuaWQpKSk7
CiAgICBjdHhCaW5kKCdjLXF1ZXVlLWZyb20nLCBjID0+IHsKICAgICAgICBhaGsoJ3Jlc2V0UXVldWVG
cm9tJywgU3RyaW5nKGMuaWQpKTsKICAgICAgICBpZiAoIXBpbm5lZFVJKSBhaGsoJ2hpZGUnKTsKICAg
IH0pOwogICAgY3R4QmluZCgnYy1kZWwnLCAgIGMgPT4gewogICAgICAgIC8vIOWkmumAieS4lOWPs+mU
rueCueWcqOmAieS4remhueS4iiDihpIg5om56YeP5Yig6Zmk77yb5ZCm5YiZ5Y+q5Yig5b2T5YmNCiAg
ICAgICAgbGV0IGlkcyA9IFtdOwogICAgICAgIGlmIChtdWx0aUlkcy5sZW5ndGggPiAxICYmIG11bHRp
SWRzLmluY2x1ZGVzKCtjLmlkKSkKICAgICAgICAgICAgaWRzID0gbXVsdGlJZHMuc2xpY2UoKTsKICAg
ICAgICBlbHNlCiAgICAgICAgICAgIGlkcyA9IFsrYy5pZF07CiAgICAgICAgaWRzID0gaWRzLm1hcCh4
ID0+ICt4KS5maWx0ZXIoeCA9PiB4ID4gMCk7CiAgICAgICAgaWYgKCFpZHMubGVuZ3RoKSByZXR1cm47
CiAgICAgICAgdHJ5IHsKICAgICAgICAgICAgY29uc3QgaWRTZXQgPSBuZXcgU2V0KGlkcyk7CiAgICAg
ICAgICAgIGFsbENsaXBzID0gYWxsQ2xpcHMuZmlsdGVyKHggPT4gIWlkU2V0LmhhcygreC5pZCkpOwog
ICAgICAgICAgICBkaXNrVG90YWwgPSBNYXRoLm1heCgwLCAoTnVtYmVyKGRpc2tUb3RhbCkgfHwgMCkg
LSBpZHMubGVuZ3RoKTsKICAgICAgICAgICAgaWYgKGlkU2V0Lmhhcygrc2VsZWN0ZWRJZCkpCiAgICAg
ICAgICAgICAgICBzZWxlY3RlZElkID0gYWxsQ2xpcHMubGVuZ3RoID8gYWxsQ2xpcHNbMF0uaWQgOiAw
OwogICAgICAgICAgICBjbGVhck11bHRpKCk7CiAgICAgICAgICAgIHJlbmRlcigpOwogICAgICAgIH0g
Y2F0Y2gge30KICAgICAgICBpZiAoaWRzLmxlbmd0aCA9PT0gMSkKICAgICAgICAgICAgYWhrKCdkZWxl
dGUnLCBTdHJpbmcoaWRzWzBdKSk7CiAgICAgICAgZWxzZQogICAgICAgICAgICBhaGsoJ2RlbGV0ZU1h
bnknLCBpZHMuam9pbignLCcpKTsKICAgIH0pOwogICAgY3R4QmluZCgnYy10aXRsZScsIGMgPT4gb3Bl
blRpdGxlRGxnKGMpKTsKICAgIGN0eEJpbmQoJ2MtbWVyZ2UnLCBjID0+IHsKICAgICAgICBjb25zdCBp
ZHMgPSAobXVsdGlJZHMubGVuZ3RoID49IDIpID8gbXVsdGlJZHMuc2xpY2UoKSA6IFtdOwogICAgICAg
IGlmIChpZHMubGVuZ3RoIDwgMikgcmV0dXJuOwogICAgICAgIGlmICghaWRzLmluY2x1ZGVzKCtjLmlk
KSkgaWRzLnB1c2goK2MuaWQpOwogICAgICAgIGFoaygnbWVyZ2VGYXYnLCBpZHMuam9pbignLCcpKTsK
ICAgICAgICBjbGVhck11bHRpKCk7CiAgICB9KTsKICAgIGN0eEJpbmQoJ2MtdW5tZXJnZScsIGMgPT4g
ewogICAgICAgIGFoaygndW5tZXJnZUZhdicsIFN0cmluZyhjLmlkKSk7CiAgICAgICAgY2xlYXJNdWx0
aSgpOwogICAgfSk7CgogICAgY29uc3QgdGl0bGVEbGcgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgn
dGl0bGUtZGxnJyk7CiAgICBjb25zdCB0aXRsZUlucHV0ID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQo
J3RpdGxlLWlucHV0Jyk7CiAgICBsZXQgdGl0bGVEbGdDbGlwID0gbnVsbDsKICAgIGZ1bmN0aW9uIGNs
b3NlVGl0bGVEbGcoKSB7CiAgICAgICAgaWYgKHRpdGxlRGxnKSB0aXRsZURsZy5jbGFzc0xpc3QucmVt
b3ZlKCdvbicpOwogICAgICAgIHRpdGxlRGxnQ2xpcCA9IG51bGw7CiAgICB9CiAgICBmdW5jdGlvbiBv
cGVuVGl0bGVEbGcoYykgewogICAgICAgIGhpZGVDdHgoKTsKICAgICAgICB0aXRsZURsZ0NsaXAgPSBj
OwogICAgICAgIGlmICh0aXRsZUlucHV0KSB0aXRsZUlucHV0LnZhbHVlID0gU3RyaW5nKGMuZmF2VGl0
bGUgfHwgJycpLnRyaW0oKTsKICAgICAgICBpZiAodGl0bGVEbGcpIHRpdGxlRGxnLmNsYXNzTGlzdC5h
ZGQoJ29uJyk7CiAgICAgICAgYWhrKCdmb2N1c1BhbmVsJyk7CiAgICAgICAgcmVxdWVzdEFuaW1hdGlv
bkZyYW1lKCgpID0+IHsKICAgICAgICAgICAgdHJ5IHsgdGl0bGVJbnB1dC5mb2N1cygpOyB0aXRsZUlu
cHV0LnNlbGVjdCgpOyB9IGNhdGNoIHt9CiAgICAgICAgfSk7CiAgICB9CiAgICBpZiAodGl0bGVEbGcp
IHsKICAgICAgICB0aXRsZURsZy5hZGRFdmVudExpc3RlbmVyKCdjbGljaycsIGUgPT4gewogICAgICAg
ICAgICBpZiAoZS50YXJnZXQgPT09IHRpdGxlRGxnKSBjbG9zZVRpdGxlRGxnKCk7CiAgICAgICAgfSk7
CiAgICB9CiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgndGl0bGUtY2FuY2VsJyk/LmFkZEV2ZW50
TGlzdGVuZXIoJ2NsaWNrJywgZSA9PiB7CiAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAg
ICBjbG9zZVRpdGxlRGxnKCk7CiAgICAgICAgYWhrKCdibHVyUGFuZWwnKTsKICAgIH0pOwogICAgZG9j
dW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3RpdGxlLW9rJyk/LmFkZEV2ZW50TGlzdGVuZXIoJ2NsaWNrJywg
ZSA9PiB7CiAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICBpZiAoIXRpdGxlRGxnQ2xp
cCkgcmV0dXJuOwogICAgICAgIGNvbnN0IHQgPSBTdHJpbmcodGl0bGVJbnB1dD8udmFsdWUgfHwgJycp
LnRyaW0oKS5zbGljZSgwLCA4MCk7CiAgICAgICAgY29uc3QgaWQgPSBTdHJpbmcodGl0bGVEbGdDbGlw
LmlkKTsKICAgICAgICAvLyBPcHRpbWlzdGljIGxvY2FsIHVwZGF0ZQogICAgICAgIGNvbnN0IGhpdCA9
IGFsbENsaXBzLmZpbmQoeCA9PiAreC5pZCA9PT0gK2lkKTsKICAgICAgICBpZiAoaGl0KSBoaXQuZmF2
VGl0bGUgPSB0OwogICAgICAgIHRpdGxlRGxnQ2xpcC5mYXZUaXRsZSA9IHQ7CiAgICAgICAgY2xvc2VU
aXRsZURsZygpOwogICAgICAgIGFoaygnc2V0RmF2VGl0bGUnLCBpZCwgdCk7CiAgICAgICAgYWhrKCdi
bHVyUGFuZWwnKTsKICAgICAgICByZW5kZXIoKTsKICAgIH0pOwogICAgdGl0bGVJbnB1dD8uYWRkRXZl
bnRMaXN0ZW5lcigna2V5ZG93bicsIGUgPT4gewogICAgICAgIGlmIChlLmtleSA9PT0gJ0VudGVyJykg
ewogICAgICAgICAgICBlLnByZXZlbnREZWZhdWx0KCk7CiAgICAgICAgICAgIGUuc3RvcFByb3BhZ2F0
aW9uKCk7CiAgICAgICAgICAgIGUuc3RvcEltbWVkaWF0ZVByb3BhZ2F0aW9uKCk7CiAgICAgICAgICAg
IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd0aXRsZS1vaycpPy5jbGljaygpOwogICAgICAgICAgICBy
ZXR1cm47CiAgICAgICAgfQogICAgICAgIGlmIChlLmtleSA9PT0gJ0VzY2FwZScpIHsKICAgICAgICAg
ICAgZS5wcmV2ZW50RGVmYXVsdCgpOwogICAgICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAg
ICAgICAgICBjbG9zZVRpdGxlRGxnKCk7CiAgICAgICAgICAgIGFoaygnYmx1clBhbmVsJyk7CiAgICAg
ICAgICAgIHJldHVybjsKICAgICAgICB9CiAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgIH0s
IHRydWUpOwoKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd0YWJzJykuYWRkRXZlbnRMaXN0ZW5l
cignY2xpY2snLCBlID0+IHsKICAgICAgICBjb25zdCB0YWIgPSBlLnRhcmdldC5jbG9zZXN0KCcudGFi
Jyk7CiAgICAgICAgaWYgKCF0YWIgfHwgZS50YXJnZXQuY2xvc2VzdCgnI3RhYi1hY3Rpb25zJykpIHJl
dHVybjsKICAgICAgICBzZXRUYWIodGFiLmRhdGFzZXQudGFiKTsKICAgIH0pOwoKICAgIGNvbnN0IHNy
Y2hXcmFwID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NlYXJjaC13cmFwJyk7CiAgICBjb25zdCBi
dG5TZWFyY2ggPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYnRuLXNlYXJjaCcpOwogICAgY29uc3Qg
YnRuTG9jYXRlID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2J0bi1sb2NhdGUnKTsKICAgIGNvbnN0
IGJ0blRvZGF5ID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2J0bi10b2RheScpOwogICAgY29uc3Qg
c3JjaCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzZWFyY2gnKTsKICAgIGNvbnN0IHNjbHIgPSBk
b2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc2VhcmNoLWNscicpOwogICAgbGV0IGRlYjsKCiAgICB1cGRh
dGVMb2NhdGVCdG4oKTsKICAgIGlmIChidG5Mb2NhdGUpIHsKICAgICAgICBidG5Mb2NhdGUuYWRkRXZl
bnRMaXN0ZW5lcignY2xpY2snLCBlID0+IHsKICAgICAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsK
ICAgICAgICAgICAganVtcFRvTGFzdFBhc3RlKCk7CiAgICAgICAgfSk7CiAgICB9CgogICAgYnRuVG9k
YXkuYWRkRXZlbnRMaXN0ZW5lcignbW91c2Vkb3duJywgZSA9PiB7CiAgICAgICAgZS5wcmV2ZW50RGVm
YXVsdCgpOwogICAgICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICB9KTsKICAgIGJ0blRvZGF5LmFk
ZEV2ZW50TGlzdGVuZXIoJ2NsaWNrJywgZSA9PiB7CiAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsK
ICAgICAgICBlLnByZXZlbnREZWZhdWx0KCk7CiAgICAgICAgdG9kYXlPbmx5ID0gIXRvZGF5T25seTsK
ICAgICAgICBidG5Ub2RheS5jbGFzc0xpc3QudG9nZ2xlKCdvbicsIHRvZGF5T25seSk7CiAgICAgICAg
bGlzdEVsLnNjcm9sbFRvcCA9IDA7CiAgICAgICAgcmVxdWVzdFZpZXcoKTsKICAgICAgICB0cnkgeyBz
cmNoLmZvY3VzKCk7IH0gY2F0Y2gge30KICAgIH0pOwoKICAgIGZ1bmN0aW9uIG9wZW5TZWFyY2goKSB7
CiAgICAgICAgaWYgKHNyY2hXcmFwLmNsYXNzTGlzdC5jb250YWlucygnb3BlbicpKSB7CiAgICAgICAg
ICAgIGFoaygnZm9jdXNQYW5lbCcpOwogICAgICAgICAgICB0cnkgeyBzcmNoLmZvY3VzKCk7IH0gY2F0
Y2gge30KICAgICAgICAgICAgcmV0dXJuOwogICAgICAgIH0KICAgICAgICBzcmNoV3JhcC5jbGFzc0xp
c3QuYWRkKCdvcGVuJyk7CiAgICAgICAgLy8gRGVmYXVsdDog5omA5pyJ6aG15omT5byA5pCc57Si5pe2
6buY6K6k5pCc5YWo6YOoCiAgICAgICAgY29uc3Qgd2FudFRvZGF5ID0gZmFsc2U7CiAgICAgICAgaWYg
KHRvZGF5T25seSAhPT0gd2FudFRvZGF5KSB7CiAgICAgICAgICAgIHRvZGF5T25seSA9IHdhbnRUb2Rh
eTsKICAgICAgICAgICAgYnRuVG9kYXkuY2xhc3NMaXN0LnRvZ2dsZSgnb24nLCB0b2RheU9ubHkpOwog
ICAgICAgICAgICBsaXN0RWwuc2Nyb2xsVG9wID0gMDsKICAgICAgICAgICAgcmVxdWVzdFZpZXcoKTsK
ICAgICAgICB9IGVsc2UgewogICAgICAgICAgICBidG5Ub2RheS5jbGFzc0xpc3QudG9nZ2xlKCdvbics
IHRvZGF5T25seSk7CiAgICAgICAgfQogICAgICAgIGFoaygnZm9jdXNQYW5lbCcpOwogICAgICAgIHJl
cXVlc3RBbmltYXRpb25GcmFtZSgoKSA9PiB7CiAgICAgICAgICAgIHRyeSB7IHNyY2guZm9jdXMoKTsg
fSBjYXRjaCB7fQogICAgICAgIH0pOwogICAgfQogICAgZnVuY3Rpb24gY2xvc2VTZWFyY2hVaSgpIHsK
ICAgICAgICBzcmNoV3JhcC5jbGFzc0xpc3QucmVtb3ZlKCdvcGVuJyk7CiAgICAgICAgaWYgKCFzcmNo
LnZhbHVlKSB7CiAgICAgICAgICAgIHNyY2guY2xhc3NMaXN0LnJlbW92ZSgnaGFzLXZhbCcpOwogICAg
ICAgICAgICBzY2xyLnN0eWxlLmRpc3BsYXkgPSAnbm9uZSc7CiAgICAgICAgICAgIC8vIExlYXZpbmcg
c2VhcmNoIHdpdGggZW1wdHkgcXVlcnkg4oaSIGRyb3AgdG9kYXkgZmlsdGVyCiAgICAgICAgICAgIGlm
ICh0b2RheU9ubHkpIHsKICAgICAgICAgICAgICAgIHRvZGF5T25seSA9IGZhbHNlOwogICAgICAgICAg
ICAgICAgYnRuVG9kYXkuY2xhc3NMaXN0LnJlbW92ZSgnb24nKTsKICAgICAgICAgICAgICAgIHJlcXVl
c3RWaWV3KCk7CiAgICAgICAgICAgIH0KICAgICAgICB9CiAgICB9CiAgICB3aW5kb3cuX19vcGVuU2Vh
cmNoID0gb3BlblNlYXJjaDsKICAgIHdpbmRvdy5fX3ByZXBUeXBlU2VhcmNoID0gKCkgPT4gewogICAg
ICAgIHRyeSB7CiAgICAgICAgICAgIGNvbnN0IHdyYXAgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgn
c2VhcmNoLXdyYXAnKTsKICAgICAgICAgICAgY29uc3QgcyA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlk
KCdzZWFyY2gnKTsKICAgICAgICAgICAgaWYgKHdyYXAgJiYgIXdyYXAuY2xhc3NMaXN0LmNvbnRhaW5z
KCdvcGVuJykpIHsKICAgICAgICAgICAgICAgIHdyYXAuY2xhc3NMaXN0LmFkZCgnb3BlbicpOwogICAg
ICAgICAgICAgICAgdHJ5IHsKICAgICAgICAgICAgICAgICAgICBjb25zdCB3YW50VG9kYXkgPSBmYWxz
ZTsKICAgICAgICAgICAgICAgICAgICBpZiAodHlwZW9mIHRvZGF5T25seSAhPT0gJ3VuZGVmaW5lZCcg
JiYgdG9kYXlPbmx5ICE9PSB3YW50VG9kYXkpIHsKICAgICAgICAgICAgICAgICAgICAgICAgdG9kYXlP
bmx5ID0gd2FudFRvZGF5OwogICAgICAgICAgICAgICAgICAgICAgICBpZiAodHlwZW9mIGJ0blRvZGF5
ICE9PSAndW5kZWZpbmVkJyAmJiBidG5Ub2RheSkgYnRuVG9kYXkuY2xhc3NMaXN0LnRvZ2dsZSgnb24n
LCB0b2RheU9ubHkpOwogICAgICAgICAgICAgICAgICAgICAgICBpZiAodHlwZW9mIGxpc3RFbCAhPT0g
J3VuZGVmaW5lZCcgJiYgbGlzdEVsKSBsaXN0RWwuc2Nyb2xsVG9wID0gMDsKICAgICAgICAgICAgICAg
ICAgICAgICAgaWYgKHR5cGVvZiByZXF1ZXN0VmlldyA9PT0gJ2Z1bmN0aW9uJykgc2V0VGltZW91dChy
ZXF1ZXN0VmlldywgMCk7CiAgICAgICAgICAgICAgICAgICAgfSBlbHNlIGlmICh0eXBlb2YgYnRuVG9k
YXkgIT09ICd1bmRlZmluZWQnICYmIGJ0blRvZGF5KSB7CiAgICAgICAgICAgICAgICAgICAgICAgIGJ0
blRvZGF5LmNsYXNzTGlzdC50b2dnbGUoJ29uJywgISF0b2RheU9ubHkpOwogICAgICAgICAgICAgICAg
ICAgIH0KICAgICAgICAgICAgICAgIH0gY2F0Y2gge30KICAgICAgICAgICAgfQogICAgICAgICAgICAv
LyA/PyDplZzlg4/mkJzntKLvvJrkuI3opoEgZm9jdXPvvIzpgb/lhY3miqLotbDljp/nvJbovpHmoYbl
hYnmoIcKICAgICAgICB9IGNhdGNoIHt9CiAgICB9OwogICAgd2luZG93Ll9fdHlwZVNlYXJjaCA9IChj
aCkgPT4gewogICAgICAgIHRyeSB7CiAgICAgICAgICAgIHdpbmRvdy5fX3ByZXBUeXBlU2VhcmNoICYm
IHdpbmRvdy5fX3ByZXBUeXBlU2VhcmNoKCk7CiAgICAgICAgICAgIGNvbnN0IHMgPSBkb2N1bWVudC5n
ZXRFbGVtZW50QnlJZCgnc2VhcmNoJyk7CiAgICAgICAgICAgIGlmICghcykgcmV0dXJuOwogICAgICAg
ICAgICBzLnZhbHVlID0gU3RyaW5nKHMudmFsdWUgfHwgJycpICsgU3RyaW5nKGNoID09IG51bGwgPyAn
JyA6IGNoKTsKICAgICAgICAgICAgcy5jbGFzc0xpc3QudG9nZ2xlKCdoYXMtdmFsJywgISFzLnZhbHVl
KTsKICAgICAgICAgICAgcy5kaXNwYXRjaEV2ZW50KG5ldyBFdmVudCgnaW5wdXQnLCB7IGJ1YmJsZXM6
IHRydWUgfSkpOwogICAgICAgIH0gY2F0Y2gge30KICAgIH07CiAgICB3aW5kb3cuX19ia3NwU2VhcmNo
ID0gKCkgPT4gewogICAgICAgIHRyeSB7CiAgICAgICAgICAgIHdpbmRvdy5fX3ByZXBUeXBlU2VhcmNo
ICYmIHdpbmRvdy5fX3ByZXBUeXBlU2VhcmNoKCk7CiAgICAgICAgICAgIGNvbnN0IHMgPSBkb2N1bWVu
dC5nZXRFbGVtZW50QnlJZCgnc2VhcmNoJyk7CiAgICAgICAgICAgIGlmICghcykgcmV0dXJuOwogICAg
ICAgICAgICBjb25zdCB2ID0gU3RyaW5nKHMudmFsdWUgfHwgJycpOwogICAgICAgICAgICBzLnZhbHVl
ID0gdi5sZW5ndGggPyB2LnNsaWNlKDAsIC0xKSA6ICcnOwogICAgICAgICAgICBzLmNsYXNzTGlzdC50
b2dnbGUoJ2hhcy12YWwnLCAhIXMudmFsdWUpOwogICAgICAgICAgICBzLmRpc3BhdGNoRXZlbnQobmV3
IEV2ZW50KCdpbnB1dCcsIHsgYnViYmxlczogdHJ1ZSB9KSk7CiAgICAgICAgfSBjYXRjaCB7fQogICAg
fTsKICAgIHdpbmRvdy5fX3NldFNlYXJjaFF1ZXJ5ID0gKHEpID0+IHsKICAgICAgICB0cnkgewogICAg
ICAgICAgICBjb25zdCBzID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NlYXJjaCcpOwogICAgICAg
ICAgICBpZiAoIXMpIHJldHVybjsKICAgICAgICAgICAgY29uc3QgbmV4dCA9IFN0cmluZyhxID09IG51
bGwgPyAnJyA6IHEpOwogICAgICAgICAgICBjb25zdCBwcmV2ID0gU3RyaW5nKHMudmFsdWUgfHwgJycp
OwogICAgICAgICAgICAvLyDlkIzlhbPplK7lrZfph43lpI3mjqjpgIHvvJrlj6rkv53or4HmkJzntKLm
oYblvIDnnYDvvIznpoHmraLlho0gcmVxdWVzdFZpZXfvvIjkvJrmrbvlvqrnjq/pl6rvvIkKICAgICAg
ICAgICAgaWYgKHByZXYgPT09IG5leHQgJiYgU3RyaW5nKHF1ZXJ5IHx8ICcnKSA9PT0gbmV4dCkgewog
ICAgICAgICAgICAgICAgdHJ5IHsKICAgICAgICAgICAgICAgICAgICBjb25zdCB3cmFwID0gZG9jdW1l
bnQuZ2V0RWxlbWVudEJ5SWQoJ3NlYXJjaC13cmFwJyk7CiAgICAgICAgICAgICAgICAgICAgaWYgKHdy
YXAgJiYgIXdyYXAuY2xhc3NMaXN0LmNvbnRhaW5zKCdvcGVuJykpCiAgICAgICAgICAgICAgICAgICAg
ICAgIHdyYXAuY2xhc3NMaXN0LmFkZCgnb3BlbicpOwogICAgICAgICAgICAgICAgfSBjYXRjaCB7fQog
ICAgICAgICAgICAgICAgcmV0dXJuOwogICAgICAgICAgICB9CiAgICAgICAgICAgIC8vIOaJk+Wtl+WN
s+aXtuS4iuWxj++8jOS4juejgeebmOaQnOe0ouino+iApgogICAgICAgICAgICBzLnZhbHVlID0gbmV4
dDsKICAgICAgICAgICAgcy5jbGFzc0xpc3QudG9nZ2xlKCdoYXMtdmFsJywgISFzLnZhbHVlKTsKICAg
ICAgICAgICAgY29uc3Qgc2NsciA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzZWFyY2gtY2xyJyk7
CiAgICAgICAgICAgIGlmIChzY2xyKSBzY2xyLnN0eWxlLmRpc3BsYXkgPSBzLnZhbHVlID8gJ2Jsb2Nr
JyA6ICdub25lJzsKICAgICAgICAgICAgcXVlcnkgPSBzLnZhbHVlOwogICAgICAgICAgICB0cnkgewog
ICAgICAgICAgICAgICAgY29uc3Qgd3JhcCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzZWFyY2gt
d3JhcCcpOwogICAgICAgICAgICAgICAgaWYgKHdyYXAgJiYgIXdyYXAuY2xhc3NMaXN0LmNvbnRhaW5z
KCdvcGVuJykpCiAgICAgICAgICAgICAgICAgICAgd2luZG93Ll9fcHJlcFR5cGVTZWFyY2ggJiYgd2lu
ZG93Ll9fcHJlcFR5cGVTZWFyY2goKTsKICAgICAgICAgICAgICAgIGVsc2UgaWYgKHdyYXApCiAgICAg
ICAgICAgICAgICAgICAgd3JhcC5jbGFzc0xpc3QuYWRkKCdvcGVuJyk7CiAgICAgICAgICAgIH0gY2F0
Y2gge30KICAgICAgICAgICAgd2luZG93Ll9faG9zdEZpbHRlcmVkID0gZmFsc2U7CiAgICAgICAgICAg
IHdpbmRvdy5fX2hvc3RGaWx0ZXJRID0gJyc7CiAgICAgICAgICAgIGlmIChTdHJpbmcocXVlcnkgfHwg
JycpLnRyaW0oKSkgewogICAgICAgICAgICAgICAgd2FpdGluZ0RhdGEgPSB0cnVlOwogICAgICAgICAg
ICAgICAgd2luZG93Ll9fZGF0YVJlYWR5ID0gZmFsc2U7CiAgICAgICAgICAgIH0KICAgICAgICAgICAg
dHJ5IHsKICAgICAgICAgICAgICAgIGNvbnN0IGNudCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdi
YXItdHh0Jyk7CiAgICAgICAgICAgICAgICBpZiAoY250ICYmIFN0cmluZyhxdWVyeSB8fCAnJykudHJp
bSgpKQogICAgICAgICAgICAgICAgICAgIGNudC50ZXh0Q29udGVudCA9IHZpc2libGVMaXN0KCkubGVu
Z3RoICsgJyDmnaEnOwogICAgICAgICAgICB9IGNhdGNoIHt9CiAgICAgICAgICAgIHRyeSB7IHJlbmRl
cigpOyB9IGNhdGNoIHt9CiAgICAgICAgICAgIGNsZWFyVGltZW91dCh3aW5kb3cuX19xcVZpZXdEZWIp
OwogICAgICAgICAgICB3aW5kb3cuX19xcVZpZXdEZWIgPSBzZXRUaW1lb3V0KCgpID0+IHsKICAgICAg
ICAgICAgICAgIHdpbmRvdy5fX3FxVmlld0RlYiA9IDA7CiAgICAgICAgICAgICAgICByZXF1ZXN0Vmll
dygpOwogICAgICAgICAgICB9LCA3MCk7CiAgICAgICAgfSBjYXRjaCB7fQogICAgfTsKICAgIHdpbmRv
dy5fX2NsZWFyUVFTZWFyY2ggPSAoKSA9PiB7CiAgICAgICAgdHJ5IHsKICAgICAgICAgICAgcXVlcnkg
PSAnJzsKICAgICAgICAgICAgd2luZG93Ll9faG9zdEZpbHRlcmVkID0gZmFsc2U7CiAgICAgICAgICAg
IHdpbmRvdy5fX2hvc3RGaWx0ZXJRID0gJyc7CiAgICAgICAgICAgIGNvbnN0IHMgPSBkb2N1bWVudC5n
ZXRFbGVtZW50QnlJZCgnc2VhcmNoJyk7CiAgICAgICAgICAgIGlmIChzKSB7CiAgICAgICAgICAgICAg
ICBzLnZhbHVlID0gJyc7CiAgICAgICAgICAgICAgICBzLmNsYXNzTGlzdC5yZW1vdmUoJ2hhcy12YWwn
KTsKICAgICAgICAgICAgICAgIHRyeSB7IHMuYmx1cigpOyB9IGNhdGNoIHt9CiAgICAgICAgICAgIH0K
ICAgICAgICAgICAgY29uc3Qgc2NsciA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzZWFyY2gtY2xy
Jyk7CiAgICAgICAgICAgIGlmIChzY2xyKSBzY2xyLnN0eWxlLmRpc3BsYXkgPSAnbm9uZSc7CiAgICAg
ICAgICAgIGNvbnN0IHdyYXAgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc2VhcmNoLXdyYXAnKTsK
ICAgICAgICAgICAgaWYgKHdyYXApIHdyYXAuY2xhc3NMaXN0LnJlbW92ZSgnb3BlbicpOwogICAgICAg
ICAgICB0cnkgeyByZW5kZXIoKTsgfSBjYXRjaCB7fQogICAgICAgIH0gY2F0Y2gge30KICAgIH07CiAg
ICAvLyBDYXB0dXJlIEN0cmwrRiBpbnNpZGUgV2ViVmlldyAoQ2hyb21pdW0gZmluZCBpcyBkaXNhYmxl
ZCwgYnV0IHN0aWxsIGhhbmRsZSBoZXJlKQogICAgZG9jdW1lbnQuYWRkRXZlbnRMaXN0ZW5lcigna2V5
ZG93bicsIGUgPT4gewogICAgICAgIGlmICgoZS5jdHJsS2V5IHx8IGUubWV0YUtleSkgJiYgIWUuYWx0
S2V5ICYmIChlLmtleSA9PT0gJ2YnIHx8IGUua2V5ID09PSAnRicpKSB7CiAgICAgICAgICAgIGUucHJl
dmVudERlZmF1bHQoKTsKICAgICAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICAgICAg
b3BlblNlYXJjaCgpOwogICAgICAgIH0KICAgIH0sIHRydWUpOwogICAgYnRuU2VhcmNoLmFkZEV2ZW50
TGlzdGVuZXIoJ2NsaWNrJywgZSA9PiB7CiAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAg
ICBvcGVuU2VhcmNoKCk7CiAgICB9KTsKICAgIGxldCBfX3NyY2hDb21wb3NpbmcgPSBmYWxzZTsKICAg
IGNvbnN0IF9fZmx1c2hTZWFyY2hJbnB1dCA9ICgpID0+IHsKICAgICAgICBxdWVyeSA9IHNyY2gudmFs
dWU7CiAgICAgICAgc3JjaC5jbGFzc0xpc3QudG9nZ2xlKCdoYXMtdmFsJywgISFxdWVyeSk7CiAgICAg
ICAgc2Nsci5zdHlsZS5kaXNwbGF5ID0gcXVlcnkgPyAnYmxvY2snIDogJ25vbmUnOwogICAgICAgIGxp
c3RFbC5zY3JvbGxUb3AgPSAwOwogICAgICAgIHdpbmRvdy5fX2hvc3RGaWx0ZXJlZCA9IGZhbHNlOwog
ICAgICAgIHdpbmRvdy5fX2hvc3RGaWx0ZXJRID0gJyc7CiAgICAgICAgdHJ5IHsgcmVuZGVyKCk7IH0g
Y2F0Y2gge30KICAgICAgICBjbGVhclRpbWVvdXQoZGViKTsKICAgICAgICBkZWIgPSBzZXRUaW1lb3V0
KHJlcXVlc3RWaWV3LCA4MCk7CiAgICB9OwogICAgc3JjaC5hZGRFdmVudExpc3RlbmVyKCdjb21wb3Np
dGlvbnN0YXJ0JywgKCkgPT4geyBfX3NyY2hDb21wb3NpbmcgPSB0cnVlOyB9KTsKICAgIHNyY2guYWRk
RXZlbnRMaXN0ZW5lcignY29tcG9zaXRpb25lbmQnLCAoKSA9PiB7CiAgICAgICAgX19zcmNoQ29tcG9z
aW5nID0gZmFsc2U7CiAgICAgICAgX19mbHVzaFNlYXJjaElucHV0KCk7CiAgICB9KTsKICAgIHNyY2gu
YWRkRXZlbnRMaXN0ZW5lcignaW5wdXQnLCAoKSA9PiB7CiAgICAgICAgaWYgKF9fc3JjaENvbXBvc2lu
ZykgewogICAgICAgICAgICBxdWVyeSA9IHNyY2gudmFsdWU7CiAgICAgICAgICAgIHNyY2guY2xhc3NM
aXN0LnRvZ2dsZSgnaGFzLXZhbCcsICEhcXVlcnkpOwogICAgICAgICAgICBzY2xyLnN0eWxlLmRpc3Bs
YXkgPSBxdWVyeSA/ICdibG9jaycgOiAnbm9uZSc7CiAgICAgICAgICAgIHJldHVybjsKICAgICAgICB9
CiAgICAgICAgX19mbHVzaFNlYXJjaElucHV0KCk7CiAgICB9KTsKICAgIHNyY2guYWRkRXZlbnRMaXN0
ZW5lcignZm9jdXMnLCAoKSA9PiB7CiAgICAgICAgLy8gSWRlbXBvdGVudCBvbiBBSEsgc2lkZSDigJQg
c2FmZSwgYnV0IGF2b2lkIHNwYW1taW5nIGR1cmluZyBJTUUKICAgICAgICB0cnkgeyBhaGsoJ2ZvY3Vz
UGFuZWwnKTsgfSBjYXRjaCB7fQogICAgfSk7CiAgICBzcmNoLmFkZEV2ZW50TGlzdGVuZXIoJ2JsdXIn
LCAoKSA9PiB7CiAgICAgICAgc2V0VGltZW91dCgoKSA9PiB7CiAgICAgICAgICAgIGlmIChkb2N1bWVu
dC5hY3RpdmVFbGVtZW50ID09PSBzcmNoKSByZXR1cm47CiAgICAgICAgICAgIGlmIChkb2N1bWVudC5h
Y3RpdmVFbGVtZW50ID09PSBzY2xyIHx8IChzY2xyICYmIHNjbHIuY29udGFpbnMoZG9jdW1lbnQuYWN0
aXZlRWxlbWVudCkpKSByZXR1cm47CiAgICAgICAgICAgIGlmIChkb2N1bWVudC5hY3RpdmVFbGVtZW50
ID09PSBidG5Ub2RheSB8fCAoYnRuVG9kYXkgJiYgYnRuVG9kYXkuY29udGFpbnMoZG9jdW1lbnQuYWN0
aXZlRWxlbWVudCkpKSByZXR1cm47CiAgICAgICAgICAgIC8vIElNRSBjYW5kaWRhdGUgVUkgc3RlYWxz
IGZvY3VzIGJyaWVmbHkg4oCUIGtlZXAgc2VhcmNoIGlmIHN0aWxsIGNvbXBvc2luZwogICAgICAgICAg
ICBpZiAoX19zcmNoQ29tcG9zaW5nKSByZXR1cm47CiAgICAgICAgICAgIGNsb3NlU2VhcmNoVWkoKTsK
ICAgICAgICAgICAgYWhrKCdibHVyUGFuZWwnKTsKICAgICAgICB9LCAyODApOwogICAgfSk7CiAgICBz
cmNoLmFkZEV2ZW50TGlzdGVuZXIoJ2tleWRvd24nLCBlID0+IHsKICAgICAgICAvLyBDdHJsK0kgLyBD
dHJsK0s6IG1vdmUgY2xpcCBzZWxlY3Rpb24gKG5vdCBpbnNlcnQgY2hhciAvIGJyb3dzZXIgc2hvcnRj
dXQpCiAgICAgICAgaWYgKChlLmN0cmxLZXkgfHwgZS5tZXRhS2V5KSAmJiAoZS5rZXkgPT09ICdpJyB8
fCBlLmtleSA9PT0gJ0knKSkgewogICAgICAgICAgICBlLnByZXZlbnREZWZhdWx0KCk7CiAgICAgICAg
ICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAgICAgICAgIHdpbmRvdy5fX25hdiAmJiB3aW5kb3cu
X19uYXYoJ3VwJyk7CiAgICAgICAgICAgIHJldHVybjsKICAgICAgICB9CiAgICAgICAgaWYgKChlLmN0
cmxLZXkgfHwgZS5tZXRhS2V5KSAmJiAoZS5rZXkgPT09ICdrJyB8fCBlLmtleSA9PT0gJ0snKSkgewog
ICAgICAgICAgICBlLnByZXZlbnREZWZhdWx0KCk7CiAgICAgICAgICAgIGUuc3RvcFByb3BhZ2F0aW9u
KCk7CiAgICAgICAgICAgIHdpbmRvdy5fX25hdiAmJiB3aW5kb3cuX19uYXYoJ2Rvd24nKTsKICAgICAg
ICAgICAgcmV0dXJuOwogICAgICAgIH0KICAgICAgICBpZiAoZS5rZXkgPT09ICdBcnJvd0Rvd24nKSB7
CiAgICAgICAgICAgIGUucHJldmVudERlZmF1bHQoKTsKICAgICAgICAgICAgZS5zdG9wUHJvcGFnYXRp
b24oKTsKICAgICAgICAgICAgd2luZG93Ll9fbmF2ICYmIHdpbmRvdy5fX25hdignZG93bicpOwogICAg
ICAgICAgICByZXR1cm47CiAgICAgICAgfQogICAgICAgIGlmIChlLmtleSA9PT0gJ0Fycm93VXAnKSB7
CiAgICAgICAgICAgIGUucHJldmVudERlZmF1bHQoKTsKICAgICAgICAgICAgZS5zdG9wUHJvcGFnYXRp
b24oKTsKICAgICAgICAgICAgd2luZG93Ll9fbmF2ICYmIHdpbmRvdy5fX25hdigndXAnKTsKICAgICAg
ICAgICAgcmV0dXJuOwogICAgICAgIH0KICAgICAgICBpZiAoZS5rZXkgPT09ICdFc2NhcGUnKSB7CiAg
ICAgICAgICAgIGUucHJldmVudERlZmF1bHQoKTsKICAgICAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24o
KTsKICAgICAgICAgICAgLy8gQWx3YXlzIGRpc21pc3MgdGhlIHdob2xlIHBhbmVsIChub3QganVzdCB0
aGUgc2VhcmNoIGZpZWxkKQogICAgICAgICAgICBpZiAoIXBpbm5lZFVJKSBhaGsoJ2hpZGUnKTsKICAg
ICAgICAgICAgcmV0dXJuOwogICAgICAgIH0KICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAg
fSk7CiAgICBzY2xyLmFkZEV2ZW50TGlzdGVuZXIoJ2NsaWNrJywgZSA9PiB7CiAgICAgICAgZS5zdG9w
UHJvcGFnYXRpb24oKTsKICAgICAgICBzcmNoLnZhbHVlID0gcXVlcnkgPSAnJzsKICAgICAgICBzY2xy
LnN0eWxlLmRpc3BsYXkgPSAnbm9uZSc7CiAgICAgICAgc3JjaC5jbGFzc0xpc3QucmVtb3ZlKCdoYXMt
dmFsJyk7CiAgICAgICAgcmVxdWVzdFZpZXcoKTsKICAgICAgICBhaGsoJ2ZvY3VzUGFuZWwnKTsKICAg
ICAgICBzcmNoLmZvY3VzKCk7CiAgICB9KTsKCiAgICBjb25zdCBUQUJfTkFNRVMgPSB7IGFsbDogJ+WF
qOmDqCcsIHRleHQ6ICfmlofmnKwnLCBpbWFnZTogJ+WbvuWDjycsIGZpbGU6ICfmlofku7YnLCByZWNl
bnQ6ICfmnIDov5EnLCBwaW5uZWQ6ICfmlLbol48nIH07CiAgICBjb25zdCBjbHJEbGcgPSBkb2N1bWVu
dC5nZXRFbGVtZW50QnlJZCgnY2xyLWRsZycpOwogICAgY29uc3QgY2xyQWxsQ2IgPSBkb2N1bWVudC5n
ZXRFbGVtZW50QnlJZCgnY2xyLWFsbCcpOwogICAgZnVuY3Rpb24gb3BlbkNsZWFyRGxnKCkgewogICAg
ICAgIGNvbnN0IG5hbWUgPSBUQUJfTkFNRVNbY3VyVGFiXSB8fCAn5b2T5YmNJzsKICAgICAgICBkb2N1
bWVudC5nZXRFbGVtZW50QnlJZCgnY2xyLXRpdGxlJykudGV4dENvbnRlbnQgPSAn5riF56m644CMJyAr
IG5hbWUgKyAn44CN77yfJzsKICAgICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnY2xyLWRlc2Mn
KS50ZXh0Q29udGVudCA9IGN1clRhYiA9PT0gJ3Bpbm5lZCcKICAgICAgICAgICAgPyAn6buY6K6k5LuF
5riF56m65b2T5aSp55qE5pS26JeP6aG544CC5Yu+6YCJ44CM5riF56m65omA5pyJ44CN5Y+v5riF6Zmk
6K+l6YCJ6aG55Y2h5YWo6YOo5YaF5a6544CCJwogICAgICAgICAgICA6IChjdXJUYWIgPT09ICdyZWNl
bnQnCiAgICAgICAgICAgICAgICA/ICfmuIXnqbrjgIzmnIDov5HjgI3kvJrliKDpmaTmnKrlm7rlrprn
moTmnIDov5Hnm67lvZXorrDlvZXvvJvlt7Llm7rlrprnmoTnm67lvZXkvJrkv53nlZnjgIInCiAgICAg
ICAgICAgICAgICA6ICfku4XmuIXnqbrlvZPliY3pgInpobnljaHjgILpu5jorqTlj6rmuIXlvZPlpKnv
vJvmlLbol4/pobnkuI3kvJrooqvmuIXpmaTjgILli77pgInjgIzmuIXnqbrmiYDmnInjgI3lj6/muIXp
maTor6XpgInpobnljaHlhajpg6jml6XmnJ/jgIInKTsKICAgICAgICBjbHJBbGxDYi5jaGVja2VkID0g
ZmFsc2U7CiAgICAgICAgY2xyRGxnLmNsYXNzTGlzdC5hZGQoJ29uJyk7CiAgICB9CiAgICBmdW5jdGlv
biBjbG9zZUNsZWFyRGxnKCkgewogICAgICAgIGNsckRsZy5jbGFzc0xpc3QucmVtb3ZlKCdvbicpOwog
ICAgfQogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2J0bi1jbHInKS5hZGRFdmVudExpc3RlbmVy
KCdjbGljaycsIGUgPT4gewogICAgICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAgICAgb3BlbkNs
ZWFyRGxnKCk7CiAgICB9KTsKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjbHItY2FuY2VsJyku
YWRkRXZlbnRMaXN0ZW5lcignY2xpY2snLCBlID0+IHsKICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigp
OwogICAgICAgIGNsb3NlQ2xlYXJEbGcoKTsKICAgIH0pOwogICAgY2xyRGxnLmFkZEV2ZW50TGlzdGVu
ZXIoJ2NsaWNrJywgZSA9PiB7CiAgICAgICAgaWYgKGUudGFyZ2V0ID09PSBjbHJEbGcpIGNsb3NlQ2xl
YXJEbGcoKTsKICAgIH0pOwogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2Nsci1vaycpLmFkZEV2
ZW50TGlzdGVuZXIoJ2NsaWNrJywgZSA9PiB7CiAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAg
ICAgICBjb25zdCBzY29wZSA9IChjdXJUYWIgPT09ICdyZWNlbnQnKSA/ICdhbGwnIDogKGNsckFsbENi
LmNoZWNrZWQgPyAnYWxsJyA6ICd0b2RheScpOwogICAgICAgIGNsb3NlQ2xlYXJEbGcoKTsKICAgICAg
ICBhaGsoJ2NsZWFyJywgY3VyVGFiLCBzY29wZSk7CiAgICB9KTsKICAgIGRvY3VtZW50LmdldEVsZW1l
bnRCeUlkKCdtdWx0aS1jbnQnKS5hZGRFdmVudExpc3RlbmVyKCdjbGljaycsIGUgPT4gewogICAgICAg
IGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAgICAgY2xlYXJNdWx0aSh0cnVlKTsKICAgIH0pOwogICAg
ZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2J0bi1waW4nKS5hZGRFdmVudExpc3RlbmVyKCdjbGljaycs
IGUgPT4gewogICAgICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAgICAgcGlubmVkVUkgPSAhcGlu
bmVkVUk7CiAgICAgICAgZS5jdXJyZW50VGFyZ2V0LmNsYXNzTGlzdC50b2dnbGUoJ29uJywgcGlubmVk
VUkpOwogICAgICAgIGFoaygndG9nZ2xlUGluJywgcGlubmVkVUkgPyAnMScgOiAnMCcpOwogICAgfSk7
CgogICAgd2luZG93Ll9fcGVyZk1hcmsgPSAoc3RhZ2UpID0+IHsKICAgICAgICB0cnkgewogICAgICAg
ICAgICBpZiAod2luZG93LmNocm9tZSAmJiBjaHJvbWUud2VidmlldyAmJiBjaHJvbWUud2Vidmlldy5w
b3N0TWVzc2FnZSkKICAgICAgICAgICAgICAgIGNocm9tZS53ZWJ2aWV3LnBvc3RNZXNzYWdlKCdwZXJm
fCcgKyBTdHJpbmcoc3RhZ2UgfHwgJycpKTsKICAgICAgICB9IGNhdGNoIHt9CiAgICB9OwoKICAgIHdp
bmRvdy5fX3VwZGF0ZUNsaXBzID0gcGF5bG9hZCA9PiB7CiAgICAgICAgY29uc3QgdDAgPSAodHlwZW9m
IHBlcmZvcm1hbmNlICE9PSAndW5kZWZpbmVkJyAmJiBwZXJmb3JtYW5jZS5ub3cpID8gcGVyZm9ybWFu
Y2Uubm93KCkgOiBEYXRlLm5vdygpOwogICAgICAgIHdpbmRvdy5fX3BlcmZNYXJrKCdqc191cGRhdGVD
bGlwc19lbnRlciBuPScgKyAocGF5bG9hZCAmJiBwYXlsb2FkLml0ZW1zID8gcGF5bG9hZC5pdGVtcy5s
ZW5ndGggOiAoQXJyYXkuaXNBcnJheShwYXlsb2FkKSA/IHBheWxvYWQubGVuZ3RoIDogMCkpKTsKICAg
ICAgICAvLyBLZWVwIHByZXZpb3VzIHNjcm9sbCBmb3IgbG9hZC1tb3JlOyByZXNldCB3aGVuIG9wZW5p
bmcgcGFuZWwgdG8gZmlyc3QgaXRlbQogICAgICAgIGNvbnN0IGtlZXBTY3JvbGwgPSAhc2VsZWN0Rmly
c3RPblNob3c7CiAgICAgICAgY29uc3Qgc3QgPSBsaXN0RWwuc2Nyb2xsVG9wOwogICAgICAgIHdpbmRv
dy5fX3dhaXRpbmdWaWV3ID0gZmFsc2U7CiAgICAgICAgY29uc3Qgd2FzQXBwZW5kID0gcGF5bG9hZCAm
JiBwYXlsb2FkLmFwcGVuZDsKICAgICAgICBsb2FkaW5nTW9yZSA9IGZhbHNlOwogICAgICAgIGNvbnN0
IHByZXZJdGVtcyA9IGFsbENsaXBzOwogICAgICAgIGxldCBuZXh0SXRlbXMgPSBbXTsKICAgICAgICBs
ZXQgbmV4dFRvdGFsID0gMDsKICAgICAgICBsZXQgbmV4dEZpbHRlcmVkID0gZmFsc2U7CiAgICAgICAg
bGV0IHBUYWIgPSAnJzsKICAgICAgICBsZXQgcFBpbm5lZFRvdGFsID0gLTE7CiAgICAgICAgaWYgKEFy
cmF5LmlzQXJyYXkocGF5bG9hZCkpIHsKICAgICAgICAgICAgbmV4dEl0ZW1zID0gcGF5bG9hZDsKICAg
ICAgICAgICAgbmV4dFRvdGFsID0gcGF5bG9hZC5sZW5ndGg7CiAgICAgICAgICAgIG5leHRGaWx0ZXJl
ZCA9IGZhbHNlOwogICAgICAgIH0gZWxzZSBpZiAocGF5bG9hZCAmJiB0eXBlb2YgcGF5bG9hZCA9PT0g
J29iamVjdCcpIHsKICAgICAgICAgICAgbmV4dFRvdGFsID0gTnVtYmVyKHBheWxvYWQudG90YWwpIHx8
IDA7CiAgICAgICAgICAgIG5leHRJdGVtcyA9IEFycmF5LmlzQXJyYXkocGF5bG9hZC5pdGVtcykgPyBw
YXlsb2FkLml0ZW1zIDogW107CiAgICAgICAgICAgIHBUYWIgPSBwYXlsb2FkLnRhYiAhPSBudWxsID8g
U3RyaW5nKHBheWxvYWQudGFiKSA6ICcnOwogICAgICAgICAgICBpZiAocGF5bG9hZC5waW5uZWRUb3Rh
bCAhPSBudWxsICYmIHBheWxvYWQucGlubmVkVG90YWwgIT09ICcnKQogICAgICAgICAgICAgICAgcFBp
bm5lZFRvdGFsID0gTnVtYmVyKHBheWxvYWQucGlubmVkVG90YWwpIHx8IDA7CiAgICAgICAgICAgIGNv
bnN0IHBxMCA9IHBheWxvYWQucXVlcnkgIT0gbnVsbCA/IFN0cmluZyhwYXlsb2FkLnF1ZXJ5KSA6ICcn
OwogICAgICAgICAgICBuZXh0RmlsdGVyZWQgPSAhIShwYXlsb2FkLmZpbHRlcmVkIHx8IChwcTAgJiYg
cHEwLnRyaW0oKSkpOwogICAgICAgICAgICBpZiAocGF5bG9hZC5hcHBlbmQpIHsKICAgICAgICAgICAg
ICAgIC8vIEFwcGVuZCBvbmx5IGFwcGxpZXMgdG8gdGhlIHRhYiB3ZSdyZSBjdXJyZW50bHkgdmlld2lu
ZwogICAgICAgICAgICAgICAgaWYgKHBUYWIgJiYgcFRhYiAhPT0gY3VyVGFiKQogICAgICAgICAgICAg
ICAgICAgIHJldHVybjsKICAgICAgICAgICAgICAgIGNvbnN0IHNlZW4gPSBuZXcgU2V0KGFsbENsaXBz
Lm1hcChjID0+ICtjLmlkKSk7CiAgICAgICAgICAgICAgICBjb25zdCBtZXJnZWQgPSBhbGxDbGlwcy5z
bGljZSgpOwogICAgICAgICAgICAgICAgbmV4dEl0ZW1zLmZvckVhY2goaXQgPT4gewogICAgICAgICAg
ICAgICAgICAgIGlmICghc2Vlbi5oYXMoK2l0LmlkKSkgbWVyZ2VkLnB1c2goaXQpOwogICAgICAgICAg
ICAgICAgfSk7CiAgICAgICAgICAgICAgICBuZXh0SXRlbXMgPSBtZXJnZWQ7CiAgICAgICAgICAgICAg
ICBuZXh0VG90YWwgPSBNYXRoLm1heChuZXh0VG90YWwsIG5leHRJdGVtcy5sZW5ndGgpOwogICAgICAg
ICAgICB9CiAgICAgICAgICAgIC8vIOaQnOe0ouahhuS7peaJk+Wtl+mVnOWDj+S4uuWHhu+8jOe7neS4
jeiiq+a7nuWQjueahOejgeebmOe7k+aenOWGmeWbnuaXp+WFs+mUruWtlwogICAgICAgICAgICB0cnkg
ewogICAgICAgICAgICAgICAgY29uc3QgcyA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzZWFyY2gn
KTsKICAgICAgICAgICAgICAgIGlmIChzICYmIFN0cmluZyhzLnZhbHVlIHx8ICcnKS5sZW5ndGgpCiAg
ICAgICAgICAgICAgICAgICAgcXVlcnkgPSBzLnZhbHVlOwogICAgICAgICAgICAgICAgZWxzZSBpZiAo
cHEwICE9PSAnJyAmJiAhU3RyaW5nKHF1ZXJ5IHx8ICcnKS50cmltKCkpCiAgICAgICAgICAgICAgICAg
ICAgcXVlcnkgPSBwcTA7CiAgICAgICAgICAgIH0gY2F0Y2gge30KICAgICAgICB9IGVsc2UgewogICAg
ICAgICAgICBuZXh0SXRlbXMgPSBbXTsKICAgICAgICAgICAgbmV4dFRvdGFsID0gMDsKICAgICAgICAg
ICAgbmV4dEZpbHRlcmVkID0gZmFsc2U7CiAgICAgICAgfQoKICAgICAgICBjb25zdCBib3hRID0gU3Ry
aW5nKHF1ZXJ5IHx8ICcnKS50cmltKCk7CiAgICAgICAgY29uc3QgcHVzaFEgPSAocGF5bG9hZCAmJiB0
eXBlb2YgcGF5bG9hZCA9PT0gJ29iamVjdCcgJiYgcGF5bG9hZC5xdWVyeSAhPSBudWxsKQogICAgICAg
ICAgICA/IFN0cmluZyhwYXlsb2FkLnF1ZXJ5KS50cmltKCkgOiAnJzsKCiAgICAgICAgLy8gQWx3YXlz
IHJlZnJlc2gg5pS26JePIGJhZGdlIGZyb20gaG9zdCB3aGVuIHByb3ZpZGVkCiAgICAgICAgaWYgKHBQ
aW5uZWRUb3RhbCA+PSAwKQogICAgICAgICAgICBwaW5uZWRUb3RhbCA9IHBQaW5uZWRUb3RhbDsKCiAg
ICAgICAgLy8gU3RhbGUgc2VhcmNoIHB1c2ggKGUuZy4gInNxdWFyZSBsb2dpIiBsYW5kcyBhZnRlciB1
c2VyIHR5cGVkICJzcXVhcmUgbG9naW4iKSDigJRjYWNoZSBvbmx5CiAgICAgICAgaWYgKCF3YXNBcHBl
bmQgJiYgbmV4dEZpbHRlcmVkICYmIHB1c2hRICYmIGJveFEgJiYgcHVzaFEgIT09IGJveFEpIHsKICAg
ICAgICAgICAgdmlld01lbS5zZXQodmlld01lbUtleShwVGFiIHx8IGN1clRhYiwgcHVzaFEsIHRvZGF5
T25seSksIHsKICAgICAgICAgICAgICAgIGl0ZW1zOiBuZXh0SXRlbXMuc2xpY2UoKSwKICAgICAgICAg
ICAgICAgIHRvdGFsOiBuZXh0VG90YWwKICAgICAgICAgICAgfSk7CiAgICAgICAgICAgIHJldHVybjsK
ICAgICAgICB9CgogICAgICAgIC8vIFN0YWxlIHB1c2ggZm9yIGFub3RoZXIgdGFiOiBvbmx5IHJlZnJl
c2ggdGhhdCB0YWIncyB2aWV3TWVtLCBkb24ndCBoaWphY2sgVUkKICAgICAgICBpZiAoIXdhc0FwcGVu
ZCAmJiBwVGFiICYmIHBUYWIgIT09IGN1clRhYikgewogICAgICAgICAgICBjb25zdCBtZW1RID0gKHBh
eWxvYWQgJiYgdHlwZW9mIHBheWxvYWQgPT09ICdvYmplY3QnICYmIHBheWxvYWQucXVlcnkgIT0gbnVs
bCkKICAgICAgICAgICAgICAgID8gU3RyaW5nKHBheWxvYWQucXVlcnkpIDogJyc7CiAgICAgICAgICAg
IHZpZXdNZW0uc2V0KHZpZXdNZW1LZXkocFRhYiwgbWVtUSwgdG9kYXlPbmx5KSwgewogICAgICAgICAg
ICAgICAgaXRlbXM6IG5leHRJdGVtcy5zbGljZSgpLAogICAgICAgICAgICAgICAgdG90YWw6IG5leHRU
b3RhbAogICAgICAgICAgICB9KTsKICAgICAgICAgICAgLy8gU3RpbGwgdXBkYXRlIHBpbiBiYWRnZSBp
ZiBob3N0IHNlbnQgaXQKICAgICAgICAgICAgdHJ5IHsKICAgICAgICAgICAgICAgIGNvbnN0IHBpbkNu
dCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdwaW4tY250Jyk7CiAgICAgICAgICAgICAgICBpZiAo
cGluQ250ICYmIHBpbm5lZFRvdGFsID4gMCkgewogICAgICAgICAgICAgICAgICAgIHBpbkNudC50ZXh0
Q29udGVudCA9IHBpbm5lZFRvdGFsOwogICAgICAgICAgICAgICAgICAgIHBpbkNudC5zdHlsZS5kaXNw
bGF5ID0gJyc7CiAgICAgICAgICAgICAgICB9CiAgICAgICAgICAgIH0gY2F0Y2gge30KICAgICAgICAg
ICAgLy8gUVEg5pCc57Si5pu+5Zu65a6a5o6oIGFsbCB0YWIg4oaSIOW9k+WJjSB0YWIg5Lya5LiA55u0
6aqo5p6277yb6KGl5LiA5qyhIHJlcXVlc3RWaWV3CiAgICAgICAgICAgIGlmICh3YWl0aW5nRGF0YSAm
JiBwdXNoUSA9PT0gYm94USkgewogICAgICAgICAgICAgICAgc2V0VGltZW91dCgoKSA9PiB7CiAgICAg
ICAgICAgICAgICAgICAgaWYgKHdhaXRpbmdEYXRhICYmIGN1clRhYiAhPT0gcFRhYikKICAgICAgICAg
ICAgICAgICAgICAgICAgcmVxdWVzdFZpZXcoKTsKICAgICAgICAgICAgICAgIH0sIDQwKTsKICAgICAg
ICAgICAgfQogICAgICAgICAgICByZXR1cm47CiAgICAgICAgfQoKICAgICAgICAvLyBCb290c3RyYXAg
cmFjZTogQUhLIHB1c2hlZCBlbXB0eSBiZWZvcmUgV2FybUFsbFZpZXdzIOKAlGtlZXAgc2tlbGV0b24s
IGlnbm9yZQogICAgICAgIGNvbnN0IHFPbiA9IFN0cmluZyhxdWVyeSB8fCAnJykudHJpbSgpLmxlbmd0
aCA+IDA7CiAgICAgICAgaWYgKCF3YXNBcHBlbmQgJiYgIW5leHRJdGVtcy5sZW5ndGggJiYgbmV4dFRv
dGFsIDw9IDAgJiYgIXFPbiAmJiAhbmV4dEZpbHRlcmVkICYmICFzYXdOb25FbXB0eSkgewogICAgICAg
ICAgICBpZiAoIXdpbmRvdy5fX2VtcHR5RmFsbGJhY2tUKSB7CiAgICAgICAgICAgICAgICB3aW5kb3cu
X19lbXB0eUZhbGxiYWNrVCA9IHNldFRpbWVvdXQoKCkgPT4gewogICAgICAgICAgICAgICAgICAgIHdp
bmRvdy5fX2VtcHR5RmFsbGJhY2tUID0gMDsKICAgICAgICAgICAgICAgICAgICBpZiAoc2F3Tm9uRW1w
dHkpIHJldHVybjsKICAgICAgICAgICAgICAgICAgICAvLyBUcnVseSBlbXB0eSBpbnN0YWxsIGFmdGVy
IHdhaXQKICAgICAgICAgICAgICAgICAgICBzYXdOb25FbXB0eSA9IHRydWU7CiAgICAgICAgICAgICAg
ICAgICAgaG9zdFB1c2hlZE9uY2UgPSB0cnVlOwogICAgICAgICAgICAgICAgICAgIHdpbmRvdy5fX2Rh
dGFSZWFkeSA9IHRydWU7CiAgICAgICAgICAgICAgICAgICAgYWxsQ2xpcHMgPSBbXTsKICAgICAgICAg
ICAgICAgICAgICBkaXNrVG90YWwgPSAwOwogICAgICAgICAgICAgICAgICAgIGNsZWFyV2FpdGluZ0Rh
dGEoKTsKICAgICAgICAgICAgICAgICAgICB0cnkgeyByZW5kZXIoKTsgfSBjYXRjaCB7fQogICAgICAg
ICAgICAgICAgfSwgNDUwMCk7CiAgICAgICAgICAgIH0KICAgICAgICAgICAgd2FpdGluZ0RhdGEgPSB0
cnVlOwogICAgICAgICAgICB3aW5kb3cuX19kYXRhUmVhZHkgPSBmYWxzZTsKICAgICAgICAgICAgaG9z
dFB1c2hlZE9uY2UgPSBmYWxzZTsKICAgICAgICAgICAgc2V0Qm9vdExvYWRpbmcodHJ1ZSk7CiAgICAg
ICAgICAgIHRyeSB7IHJlbmRlcigpOyB9IGNhdGNoIHt9CiAgICAgICAgICAgIHJldHVybjsKICAgICAg
ICB9CgogICAgICAgIGNsZWFyV2FpdGluZ0RhdGEoKTsKICAgICAgICBhbGxDbGlwcyA9IG5leHRJdGVt
czsKICAgICAgICBkaXNrVG90YWwgPSBuZXh0VG90YWw7CiAgICAgICAgLy8gS2VlcCBiYXIgY29uc2lz
dGVudCBpZiBsaXN0IGdyZXcgcGFzdCBhIHN0YWxlIHRvdGFsCiAgICAgICAgaWYgKGFsbENsaXBzLmxl
bmd0aCA+IGRpc2tUb3RhbCkKICAgICAgICAgICAgZGlza1RvdGFsID0gYWxsQ2xpcHMubGVuZ3RoOwog
ICAgICAgIHdpbmRvdy5fX2hvc3RGaWx0ZXJlZCA9IG5leHRGaWx0ZXJlZDsKICAgICAgICB3aW5kb3cu
X19ob3N0RmlsdGVyUSA9IChuZXh0RmlsdGVyZWQgJiYgcHVzaFEpID8gcHVzaFEgOiAnJzsKICAgICAg
ICAvLyBGaWx0ZXJlZCBzZWFyY2ggd2l0aCAwIGhpdHMg4oCUbXVzdCBsZWF2ZSBza2VsZXRvbiAoaG9z
dCBkaWQgcmVzcG9uZCkKICAgICAgICBpZiAoIXdhc0FwcGVuZCAmJiBuZXh0RmlsdGVyZWQgJiYgIWFs
bENsaXBzLmxlbmd0aCAmJiBkaXNrVG90YWwgPD0gMCkgewogICAgICAgICAgICBob3N0UHVzaGVkT25j
ZSA9IHRydWU7CiAgICAgICAgICAgIHNhd05vbkVtcHR5ID0gdHJ1ZTsKICAgICAgICB9CiAgICAgICAg
aWYgKGFsbENsaXBzLmxlbmd0aCB8fCBkaXNrVG90YWwgPiAwKQogICAgICAgICAgICBzYXdOb25FbXB0
eSA9IHRydWU7CiAgICAgICAgaWYgKHdpbmRvdy5fX2VtcHR5RmFsbGJhY2tUKSB7CiAgICAgICAgICAg
IGNsZWFyVGltZW91dCh3aW5kb3cuX19lbXB0eUZhbGxiYWNrVCk7CiAgICAgICAgICAgIHdpbmRvdy5f
X2VtcHR5RmFsbGJhY2tUID0gMDsKICAgICAgICB9CiAgICAgICAgaWYgKCF3YXNBcHBlbmQpIHsKICAg
ICAgICAgICAgY29uc3QgbWVtUSA9IChwYXlsb2FkICYmIHR5cGVvZiBwYXlsb2FkID09PSAnb2JqZWN0
JyAmJiBwYXlsb2FkLnF1ZXJ5ICE9IG51bGwpCiAgICAgICAgICAgICAgICA/IFN0cmluZyhwYXlsb2Fk
LnF1ZXJ5KSA6IHF1ZXJ5OwogICAgICAgICAgICB2aWV3TWVtLnNldCh2aWV3TWVtS2V5KGN1clRhYiwg
bWVtUSwgdG9kYXlPbmx5KSwgewogICAgICAgICAgICAgICAgaXRlbXM6IGFsbENsaXBzLnNsaWNlKCks
CiAgICAgICAgICAgICAgICB0b3RhbDogZGlza1RvdGFsCiAgICAgICAgICAgIH0pOwogICAgICAgIH0K
ICAgICAgICB3aW5kb3cuX19kYXRhUmVhZHkgPSB0cnVlOwogICAgICAgIGhvc3RQdXNoZWRPbmNlID0g
dHJ1ZTsKCiAgICAgICAgLy8gTWlkLXdoZWVsOiBrZWVwIGRhdGEsIGRlbGF5IERPTSBzbyBzY3JvbGwv
ZHJhZyBuZXZlciBoaXRjaCBvbiBhcHBlbmQgcGFpbnQKICAgICAgICBpZiAod2FzQXBwZW5kICYmIHdp
bmRvdy5fX3Njcm9sbEJ1c3kgJiYgIXdpbmRvdy5fX3BlbmRpbmdKdW1wSWQpIHsKICAgICAgICAgICAg
Y29uc3QgZnJvbUxlbiA9IChwcmV2SXRlbXMgJiYgcHJldkl0ZW1zLmxlbmd0aCkgPyBwcmV2SXRlbXMu
bGVuZ3RoIDogMDsKICAgICAgICAgICAgaWYgKCFfcGVuZGluZ0FwcGVuZCkKICAgICAgICAgICAgICAg
IF9wZW5kaW5nQXBwZW5kID0geyBmcm9tTGVuOiBmcm9tTGVuIH07CiAgICAgICAgICAgIHRyeSB7IHJl
ZnJlc2hMaXN0Q2hyb21lKCk7IH0gY2F0Y2gge30KICAgICAgICAgICAgcmV0dXJuOwogICAgICAgIH0K
CiAgICAgICAgY29uc3Qgd2FzQm9vdExvYWRpbmcgPSBib290TG9hZGluZzsKICAgICAgICBsZXQgc2Ft
ZVBhaW50ID0gZmFsc2U7CiAgICAgICAgY29uc3QgcHJldkxlbiA9IChwcmV2SXRlbXMgJiYgcHJldkl0
ZW1zLmxlbmd0aCkgPyBwcmV2SXRlbXMubGVuZ3RoIDogMDsKICAgICAgICBpZiAoIXdhc0FwcGVuZCAm
JiAhd2FzQm9vdExvYWRpbmcgJiYgcHJldkl0ZW1zICYmIHByZXZJdGVtcy5sZW5ndGggPT09IGFsbENs
aXBzLmxlbmd0aCAmJiBwcmV2SXRlbXMubGVuZ3RoKSB7CiAgICAgICAgICAgIHNhbWVQYWludCA9IHRy
dWU7CiAgICAgICAgICAgIGZvciAobGV0IGkgPSAwOyBpIDwgYWxsQ2xpcHMubGVuZ3RoOyBpKyspIHsK
ICAgICAgICAgICAgICAgIGlmICgrcHJldkl0ZW1zW2ldLmlkICE9PSArYWxsQ2xpcHNbaV0uaWQpIHsg
c2FtZVBhaW50ID0gZmFsc2U7IGJyZWFrOyB9CiAgICAgICAgICAgIH0KICAgICAgICAgICAgaWYgKHNh
bWVQYWludCAmJiAhbGlzdEVsLnF1ZXJ5U2VsZWN0b3IoJy5pdG0nKSkgc2FtZVBhaW50ID0gZmFsc2U7
CiAgICAgICAgfQogICAgICAgIGNvbnN0IGZpbmlzaFVwZGF0ZSA9ICgpID0+IHsKICAgICAgICAgICAg
Y29uc3QgdFJlbmRlcjAgPSAodHlwZW9mIHBlcmZvcm1hbmNlICE9PSAndW5kZWZpbmVkJyAmJiBwZXJm
b3JtYW5jZS5ub3cpID8gcGVyZm9ybWFuY2Uubm93KCkgOiBEYXRlLm5vdygpOwogICAgICAgICAgICBj
bGVhcldhaXRpbmdEYXRhKCk7CiAgICAgICAgICAgIGlmICh3YXNBcHBlbmQgJiYgIXdhc0Jvb3RMb2Fk
aW5nICYmIHByZXZMZW4gPiAwICYmIGFsbENsaXBzLmxlbmd0aCA+IHByZXZMZW4pIHsKICAgICAgICAg
ICAgICAgIGFwcGVuZFJlbmRlcihwcmV2TGVuKTsKICAgICAgICAgICAgfSBlbHNlIGlmICghc2FtZVBh
aW50KSB7CiAgICAgICAgICAgICAgICByZW5kZXIoKTsKICAgICAgICAgICAgICAgIGFwcGx5VGFiU3dp
dGNoQW5pbSgpOwogICAgICAgICAgICAgICAgaWYgKGtlZXBTY3JvbGwpCiAgICAgICAgICAgICAgICAg
ICAgbGlzdEVsLnNjcm9sbFRvcCA9IHN0OwogICAgICAgICAgICAgICAgZWxzZQogICAgICAgICAgICAg
ICAgICAgIGxpc3RFbC5zY3JvbGxUb3AgPSAwOwogICAgICAgICAgICB9IGVsc2UgewogICAgICAgICAg
ICAgICAgdHJ5IHsgcmVmcmVzaExpc3RDaHJvbWUoKTsgfSBjYXRjaCB7fQogICAgICAgICAgICAgICAg
aWYgKGtlZXBTY3JvbGwpCiAgICAgICAgICAgICAgICAgICAgbGlzdEVsLnNjcm9sbFRvcCA9IHN0Owog
ICAgICAgICAgICB9CiAgICAgICAgICAgIGNvbnN0IHQxID0gKHR5cGVvZiBwZXJmb3JtYW5jZSAhPT0g
J3VuZGVmaW5lZCcgJiYgcGVyZm9ybWFuY2Uubm93KSA/IHBlcmZvcm1hbmNlLm5vdygpIDogRGF0ZS5u
b3coKTsKICAgICAgICAgICAgd2luZG93Ll9fcGVyZk1hcmsoJ2pzX3VwZGF0ZUNsaXBzX2RvbmUgcmVu
ZGVyTXM9JyArIE1hdGgucm91bmQodDEgLSB0UmVuZGVyMCkgKyAnIHRvdGFsTXM9JyArIE1hdGgucm91
bmQodDEgLSB0MCkgKyAnIG49JyArIGFsbENsaXBzLmxlbmd0aCk7CiAgICAgICAgfTsKICAgICAgICBp
ZiAod2FzQm9vdExvYWRpbmcpIHsKICAgICAgICAgICAgY29uc3Qgc2luY2UgPSB3aW5kb3cuX19za2Vs
U2luY2UgfHwgMDsKICAgICAgICAgICAgY29uc3Qgd2FpdCA9IHNpbmNlID8gTWF0aC5tYXgoMCwgODAg
LSAoRGF0ZS5ub3coKSAtIHNpbmNlKSkgOiAwOwogICAgICAgICAgICBpZiAod2FpdCA+IDApCiAgICAg
ICAgICAgICAgICBzZXRUaW1lb3V0KGZpbmlzaFVwZGF0ZSwgd2FpdCk7CiAgICAgICAgICAgIGVsc2UK
ICAgICAgICAgICAgICAgIGZpbmlzaFVwZGF0ZSgpOwogICAgICAgIH0gZWxzZSB7CiAgICAgICAgICAg
IGZpbmlzaFVwZGF0ZSgpOwogICAgICAgIH0KICAgIH07CiAgICB3aW5kb3cuX19zZXRQaW5uZWQgPSB2
ID0+IHsKICAgICAgICBwaW5uZWRVSSA9ICEhdjsKICAgICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJ
ZCgnYnRuLXBpbicpLmNsYXNzTGlzdC50b2dnbGUoJ29uJywgcGlubmVkVUkpOwogICAgfTsKICAgIHdp
bmRvdy5fX2xvYWRNb3JlRG9uZSA9ICgpID0+IHsKICAgICAgICBsb2FkaW5nTW9yZSA9IGZhbHNlOwog
ICAgICAgIGlmICh3aW5kb3cuX19sb2FkTW9yZVdhdGNoKSB7CiAgICAgICAgICAgIGNsZWFyVGltZW91
dCh3aW5kb3cuX19sb2FkTW9yZVdhdGNoKTsKICAgICAgICAgICAgd2luZG93Ll9fbG9hZE1vcmVXYXRj
aCA9IDA7CiAgICAgICAgfQogICAgICAgIGlmICh3aW5kb3cuX19wZW5kaW5nSnVtcElkKQogICAgICAg
ICAgICB0cnlDb250aW51ZUp1bXAoKTsKICAgIH07CgogICAgc2NoZWR1bGVEZWxheWVkU2tlbCgpOwog
ICAgd2luZG93Ll9fcGVyZk1hcmsgJiYgd2luZG93Ll9fcGVyZk1hcmsoJ2pzX2Jvb3QgcmVxdWVzdFZp
ZXcnKTsKICAgIHJlcXVlc3RWaWV3KCk7CiAgICAvLyBzY2hlZHVsZURlbGF5ZWRTa2VsIGFscmVhZHkg
cmVuZGVyKCknZCB3aGVuIGVtcHR5OyBzdGlsbCBwYWludCBvbmNlIGZvciBjaHJvbWUKCiAgICA8L3Nj
cmlwdD4KPC9ib2R5Pgo8L2h0bWw+
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
