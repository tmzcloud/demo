#Requires AutoHotkey v2.0
#NoTrayIcon
#Include %A_Temp%\WebView2.ahk
#SingleInstance Force
#UseHook
Persistent


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
; Larger chunk = fewer AHK round-trips while dragging the scrollbar
VIEW_PAGE_SIZE := 28
; Clipboard screenshots (type=image) retention; file-copy thumbs (type=file / fimg_*) are permanent
MAX_SCREENSHOTS := 100
MAX_RECENT_FOLDERS := 20
; Data root: prefer HELPME_HOME (synced runtime); else script-local ahk\clip_v1
CLIP_V1_DIR  := ResolveClipV1Dir()
HTML_FILE    := CLIP_V1_DIR "\index.html"
SAVE_FILE    := CLIP_V1_DIR "\clips.json"          ; legacy (migrated once)
PAGES_DIR    := CLIP_V1_DIR "\clips_pages"
MANIFEST_FILE := PAGES_DIR "\manifest.json"
STORE_DIR    := CLIP_V1_DIR "\clips_store"
PAYLOAD_DIR  := CLIP_V1_DIR "\clips_payloads"
RECENT_FOLDERS_FILE := CLIP_V1_DIR "\recent_folders.json"
PAYLOAD_INLINE_MAX := 4000   ; larger text/link bodies go to external files
STORE_HOST   := "clips.store"
APP_HOST     := "clipui.local"   ; HTML via virtual host so clips.store thumbs work
DEBUG_LOG    := CLIP_V1_DIR "\debug.log"
ERROR_LOG    := CLIP_V1_DIR "\error.log"

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
ICAgICBkaXNwbGF5OiBmbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBnYXA6IDA7IGZsZXgtd3JhcDog
bm93cmFwOwogICAgICAgICAgICBwYWRkaW5nOiA1cHggNnB4IDVweCA4cHg7IGZsZXgtc2hyaW5rOiAw
OwogICAgICAgICAgICBiYWNrZ3JvdW5kOiAjZjJmNGY5OwogICAgICAgIH0KICAgICAgICAjdGFiLWlu
ayB7CiAgICAgICAgICAgIHBvc2l0aW9uOiBhYnNvbHV0ZTsKICAgICAgICAgICAgbGVmdDogMDsgdG9w
OiAwOwogICAgICAgICAgICBoZWlnaHQ6IDIycHg7CiAgICAgICAgICAgIGJvcmRlci1yYWRpdXM6IDk5
OXB4OwogICAgICAgICAgICBiYWNrZ3JvdW5kOiAjZmZmOwogICAgICAgICAgICBib3gtc2hhZG93OiAw
IDFweCAzcHggcmdiYSgwLDAsMCwuMDcpLCAwIDAgMCAxcHggcmdiYSg5MSwxMTUsMjMyLC4wNik7CiAg
ICAgICAgICAgIHBvaW50ZXItZXZlbnRzOiBub25lOwogICAgICAgICAgICB6LWluZGV4OiAwOwogICAg
ICAgICAgICB0cmFuc2Zvcm06IHRyYW5zbGF0ZTNkKDAsMCwwKSBzY2FsZVgoMSk7CiAgICAgICAgICAg
IHRyYW5zZm9ybS1vcmlnaW46IGNlbnRlciBib3R0b207CiAgICAgICAgICAgIHRyYW5zaXRpb246CiAg
ICAgICAgICAgICAgICB0cmFuc2Zvcm0gMC4zNHMgY3ViaWMtYmV6aWVyKDAuMjIsIDEuMTgsIDAuMzIs
IDEpLAogICAgICAgICAgICAgICAgaGVpZ2h0IDAuMjRzIGVhc2U7CiAgICAgICAgICAgIHdpbGwtY2hh
bmdlOiB0cmFuc2Zvcm0sIGhlaWdodDsKICAgICAgICB9CiAgICAgICAgI3RhYi1pbmsuc3F1YXNoIHsK
ICAgICAgICAgICAgdHJhbnNpdGlvbjoKICAgICAgICAgICAgICAgIHRyYW5zZm9ybSAwLjMwcyBjdWJp
Yy1iZXppZXIoMC4zNCwgMS4yOCwgMC40NCwgMSksCiAgICAgICAgICAgICAgICBoZWlnaHQgMC4yMHMg
ZWFzZTsKICAgICAgICB9CiAgICAgICAgLnRhYiB7CiAgICAgICAgICAgIHBvc2l0aW9uOiByZWxhdGl2
ZTsKICAgICAgICAgICAgei1pbmRleDogMTsKICAgICAgICAgICAgcGFkZGluZzogM3B4IDhweDsgZm9u
dC1zaXplOiAxMXB4OyBjb2xvcjogdmFyKC0tdHh0Mik7IGN1cnNvcjogcG9pbnRlcjsKICAgICAgICAg
ICAgYm9yZGVyLXJhZGl1czogOTk5cHg7IHdoaXRlLXNwYWNlOiBub3dyYXA7CiAgICAgICAgICAgIGJh
Y2tncm91bmQ6IHRyYW5zcGFyZW50OwogICAgICAgICAgICB0cmFuc2l0aW9uOiBjb2xvciAwLjI4cyBj
dWJpYy1iZXppZXIoMC4yMiwgMSwgMC4zNiwgMSksCiAgICAgICAgICAgICAgICAgICAgICAgIHRyYW5z
Zm9ybSAwLjI4cyBjdWJpYy1iZXppZXIoMC4yMiwgMSwgMC4zNiwgMSk7CiAgICAgICAgICAgIC13ZWJr
aXQtYXBwLXJlZ2lvbjogbm8tZHJhZzsgYXBwLXJlZ2lvbjogbm8tZHJhZzsKICAgICAgICB9CiAgICAg
ICAgLnRhYjpob3ZlciB7IGNvbG9yOiB2YXIoLS10eHQpOyBiYWNrZ3JvdW5kOiB0cmFuc3BhcmVudDsg
fQogICAgICAgIC50YWI6YWN0aXZlIHsgdHJhbnNmb3JtOiBzY2FsZSgwLjk2KTsgfQogICAgICAgIC50
YWIub24geyBjb2xvcjogdmFyKC0tYWNjKTsgYmFja2dyb3VuZDogdHJhbnNwYXJlbnQ7IGJveC1zaGFk
b3c6IG5vbmU7IGZvbnQtd2VpZ2h0OiA2MDA7IH0KICAgICAgICAuYmFkZ2UgewogICAgICAgICAgICBk
aXNwbGF5OiBpbmxpbmUtZmxleDsgbWluLXdpZHRoOiAxNHB4OyBoZWlnaHQ6IDE0cHg7IHBhZGRpbmc6
IDAgM3B4OwogICAgICAgICAgICBhbGlnbi1pdGVtczogY2VudGVyOyBqdXN0aWZ5LWNvbnRlbnQ6IGNl
bnRlcjsKICAgICAgICAgICAgYmFja2dyb3VuZDogdmFyKC0tYWNjKTsgY29sb3I6ICNmZmY7IGZvbnQt
c2l6ZTogOXB4OyBib3JkZXItcmFkaXVzOiA3cHg7IGZvbnQtd2VpZ2h0OiA3MDA7CiAgICAgICAgfQog
ICAgICAgICN0YWItYWN0aW9ucyB7CiAgICAgICAgICAgIG1hcmdpbi1sZWZ0OiBhdXRvOyBkaXNwbGF5
OiBmbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBnYXA6IDRweDsKICAgICAgICAgICAgY29sb3I6IHZh
cigtLXR4dDMpOyBmb250LXNpemU6IDEwcHg7CiAgICAgICAgICAgIC13ZWJraXQtYXBwLXJlZ2lvbjog
bm8tZHJhZzsgYXBwLXJlZ2lvbjogbm8tZHJhZzsKICAgICAgICB9CiAgICAgICAgI2Jhci10eHQgeyB3
aGl0ZS1zcGFjZTogbm93cmFwOyB9CiAgICAgICAgI2J0bi1jbHIgewogICAgICAgICAgICBkaXNwbGF5
OiBmbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBqdXN0aWZ5LWNvbnRlbnQ6IGNlbnRlcjsKICAgICAg
ICAgICAgd2lkdGg6IDI2cHg7IGhlaWdodDogMjZweDsgYm9yZGVyOiBub25lOyBiYWNrZ3JvdW5kOiBu
b25lOyBjb2xvcjogdmFyKC0tdHh0Myk7CiAgICAgICAgICAgIGN1cnNvcjogcG9pbnRlcjsgYm9yZGVy
LXJhZGl1czogdmFyKC0tcik7CiAgICAgICAgICAgIC13ZWJraXQtYXBwLXJlZ2lvbjogbm8tZHJhZzsg
YXBwLXJlZ2lvbjogbm8tZHJhZzsKICAgICAgICAgICAgdHJhbnNpdGlvbjogY29sb3IgdmFyKC0tdHIp
LCBiYWNrZ3JvdW5kIHZhcigtLXRyKTsKICAgICAgICB9CiAgICAgICAgI2J0bi1jbHI6aG92ZXIgeyBj
b2xvcjogI2ZmN2I5YzsgYmFja2dyb3VuZDogcmdiYSgyNTUsMTIzLDE1NiwuMDgpOyB9CiAgICAgICAg
I2J0bi1jbHIgc3ZnIHsgd2lkdGg6IDE0cHg7IGhlaWdodDogMTRweDsgZGlzcGxheTogYmxvY2s7IH0K
CiAgICAgICAgLyog4pSA4pSAIExpc3Qg4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA
4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA
4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSAICovCiAgICAgICAgI2xpc3QgewogICAgICAgICAgICBmbGV4
OiAxOyBvdmVyZmxvdy15OiBhdXRvOyBvdmVyZmxvdy14OiBoaWRkZW47IHBhZGRpbmc6IDZweCA4cHgg
NnB4IDEwcHg7IGN1cnNvcjogZGVmYXVsdDsKICAgICAgICAgICAgLyogTVVTVCBiZSBuby1kcmFnOiBk
cmFnIHJlZ2lvbiBvbiB0aGUgc2Nyb2xsZXIgbWFrZXMgV2ViVmlldzIgc2Nyb2xsYmFyL3doZWVsIGhp
dGNoICovCiAgICAgICAgICAgIC13ZWJraXQtYXBwLXJlZ2lvbjogbm8tZHJhZzsgYXBwLXJlZ2lvbjog
bm8tZHJhZzsKICAgICAgICAgICAgbWluLWhlaWdodDogMDsKICAgICAgICAgICAgb3ZlcmZsb3ctYW5j
aG9yOiBub25lOwogICAgICAgIH0KICAgICAgICAvKiBXaGlsZSBzY3JvbGxpbmc6IGtpbGwgaG92ZXIg
YW5pbWF0aW9ucyB0aGF0IGNhdXNlIGxheW91dC9wYWludCB0aHJhc2gKICAgICAgICAgICBEbyBOT1Qg
c2V0IHBvaW50ZXItZXZlbnRzOm5vbmUg4oCUIHRoYXQgc3dhbGxvd2VkIGNvbnRleHRtZW51IG9uIHJp
Z2h0LWNsaWNrICovCiAgICAgICAgI2xpc3QuaXMtc2Nyb2xsaW5nIC5pdG0gewogICAgICAgICAgICB0
cmFuc2l0aW9uOiBub25lICFpbXBvcnRhbnQ7CiAgICAgICAgfQogICAgICAgICNsaXN0LmlzLXNjcm9s
bGluZyAuaXRtOjpiZWZvcmUsCiAgICAgICAgI2xpc3QuaXMtc2Nyb2xsaW5nIC5pdG06OmFmdGVyIHsK
ICAgICAgICAgICAgdHJhbnNpdGlvbjogbm9uZSAhaW1wb3J0YW50OwogICAgICAgIH0KICAgICAgICBA
a2V5ZnJhbWVzIHRhYlBhbmVJbkxyIHsKICAgICAgICAgICAgZnJvbSB7IG9wYWNpdHk6IDA7IHRyYW5z
Zm9ybTogdHJhbnNsYXRlWCgtNDBweCk7IH0KICAgICAgICAgICAgdG8geyBvcGFjaXR5OiAxOyB0cmFu
c2Zvcm06IHRyYW5zbGF0ZVgoMCk7IH0KICAgICAgICB9CiAgICAgICAgQGtleWZyYW1lcyB0YWJQYW5l
SW5SbCB7CiAgICAgICAgICAgIGZyb20geyBvcGFjaXR5OiAwOyB0cmFuc2Zvcm06IHRyYW5zbGF0ZVgo
NDBweCk7IH0KICAgICAgICAgICAgdG8geyBvcGFjaXR5OiAxOyB0cmFuc2Zvcm06IHRyYW5zbGF0ZVgo
MCk7IH0KICAgICAgICB9CiAgICAgICAgI2xpc3QudGFiLWluLWxyIHsgYW5pbWF0aW9uOiB0YWJQYW5l
SW5MciAuMzRzIGN1YmljLWJlemllciguMjIsIDEsIC4zNiwgMSkgYm90aDsgfQogICAgICAgICNsaXN0
LnRhYi1pbi1ybCB7IGFuaW1hdGlvbjogdGFiUGFuZUluUmwgLjM0cyBjdWJpYy1iZXppZXIoLjIyLCAx
LCAuMzYsIDEpIGJvdGg7IH0KICAgICAgICAjYnRuLXRvcCB7CiAgICAgICAgICAgIHBvc2l0aW9uOiBh
YnNvbHV0ZTsgcmlnaHQ6IDEwcHg7IGJvdHRvbTogMTBweDsgei1pbmRleDogMjA7CiAgICAgICAgICAg
IHdpZHRoOiAyOHB4OyBoZWlnaHQ6IDI4cHg7IGJvcmRlcjogbm9uZTsgYm9yZGVyLXJhZGl1czogNTAl
OwogICAgICAgICAgICBkaXNwbGF5OiBub25lOyBhbGlnbi1pdGVtczogY2VudGVyOyBqdXN0aWZ5LWNv
bnRlbnQ6IGNlbnRlcjsKICAgICAgICAgICAgYmFja2dyb3VuZDogI2ZmZjsgY29sb3I6IHZhcigtLXR4
dDIpOwogICAgICAgICAgICBib3gtc2hhZG93OiAwIDJweCA4cHggcmdiYSgyNCwzMiw1NiwuMTYpOwog
ICAgICAgICAgICBjdXJzb3I6IHBvaW50ZXI7CiAgICAgICAgICAgIC13ZWJraXQtYXBwLXJlZ2lvbjog
bm8tZHJhZzsgYXBwLXJlZ2lvbjogbm8tZHJhZzsKICAgICAgICAgICAgdHJhbnNpdGlvbjogYmFja2dy
b3VuZCB2YXIoLS10ciksIGNvbG9yIHZhcigtLXRyKSwgYm94LXNoYWRvdyB2YXIoLS10cik7CiAgICAg
ICAgfQogICAgICAgICNidG4tdG9wLm9uIHsgZGlzcGxheTogZmxleDsgfQogICAgICAgICNidG4tdG9w
OmhvdmVyIHsgY29sb3I6IHZhcigtLWFjYyk7IGJhY2tncm91bmQ6ICNlZGYxZmY7IGJveC1zaGFkb3c6
IDAgM3B4IDEwcHggcmdiYSg5MSwxMTUsMjMyLC4yNSk7IH0KICAgICAgICAjYnRuLXRvcCBzdmcgeyB3
aWR0aDogMTRweDsgaGVpZ2h0OiAxNHB4OyBkaXNwbGF5OiBibG9jazsgfQogICAgICAgICNlbXB0eSB7
CiAgICAgICAgICAgIGRpc3BsYXk6IG5vbmU7IGZsZXgtZGlyZWN0aW9uOiBjb2x1bW47IGFsaWduLWl0
ZW1zOiBjZW50ZXI7IGp1c3RpZnktY29udGVudDogY2VudGVyOwogICAgICAgICAgICBwYWRkaW5nOiA0
OHB4IDE2cHg7IGNvbG9yOiB2YXIoLS10eHQzKTsgZ2FwOiA4cHg7CiAgICAgICAgICAgIC13ZWJraXQt
YXBwLXJlZ2lvbjogZHJhZzsgYXBwLXJlZ2lvbjogZHJhZzsKICAgICAgICB9CiAgICAgICAgI2VtcHR5
Lm9uIHsgZGlzcGxheTogZmxleDsgfQogICAgICAgIC5lLXR4dCB7IGZvbnQtc2l6ZTogMTJweDsgdGV4
dC1hbGlnbjogY2VudGVyOyBsZXR0ZXItc3BhY2luZzogLjAyZW07IH0KICAgICAgICAjc2tlbCB7CiAg
ICAgICAgICAgIGRpc3BsYXk6IG5vbmU7IGZsZXgtZGlyZWN0aW9uOiBjb2x1bW47IGdhcDogOHB4Owog
ICAgICAgICAgICBwYWRkaW5nOiA0cHggMnB4IDEwcHg7IC13ZWJraXQtYXBwLXJlZ2lvbjogZHJhZzsg
YXBwLXJlZ2lvbjogZHJhZzsKICAgICAgICB9CiAgICAgICAgI3NrZWwub24geyBkaXNwbGF5OiBmbGV4
OyB9CiAgICAgICAgI2FwcC5ib290LWxvYWRpbmcgI3NrZWwgewogICAgICAgICAgICBkaXNwbGF5OiBm
bGV4ICFpbXBvcnRhbnQ7CiAgICAgICAgfQogICAgICAgICNhcHAuYm9vdC1sb2FkaW5nICNlbXB0eSB7
CiAgICAgICAgICAgIGRpc3BsYXk6IG5vbmUgIWltcG9ydGFudDsKICAgICAgICB9CiAgICAgICAgLnNr
LXJvdyB7CiAgICAgICAgICAgIGRpc3BsYXk6IGZsZXg7IGFsaWduLWl0ZW1zOiBmbGV4LXN0YXJ0OyBn
YXA6IDEwcHg7CiAgICAgICAgICAgIHBhZGRpbmc6IDEwcHggOHB4OyBib3JkZXItcmFkaXVzOiA4cHg7
CiAgICAgICAgICAgIGJhY2tncm91bmQ6IHJnYmEoMjU1LDI1NSwyNTUsLjcyKTsKICAgICAgICAgICAg
Ym9yZGVyOiAxcHggc29saWQgcmdiYSgxNzAsMTgwLDIwMCwuNDUpOwogICAgICAgICAgICBwb3NpdGlv
bjogcmVsYXRpdmU7CiAgICAgICAgICAgIG92ZXJmbG93OiBoaWRkZW47CiAgICAgICAgfQogICAgICAg
IC5zay1yb3c6OmFmdGVyIHsKICAgICAgICAgICAgY29udGVudDogJyc7CiAgICAgICAgICAgIHBvc2l0
aW9uOiBhYnNvbHV0ZTsKICAgICAgICAgICAgaW5zZXQ6IDA7CiAgICAgICAgICAgIGJhY2tncm91bmQ6
IGxpbmVhci1ncmFkaWVudCg5MGRlZywgdHJhbnNwYXJlbnQgMCUsIHJnYmEoMjU1LDI1NSwyNTUsLjcy
KSA0OCUsIHRyYW5zcGFyZW50IDEwMCUpOwogICAgICAgICAgICB0cmFuc2Zvcm06IHRyYW5zbGF0ZVgo
LTEyMCUpOwogICAgICAgICAgICBhbmltYXRpb246IHNrLXN3ZWVwIDAuOTVzIGVhc2UtaW4tb3V0IGlu
ZmluaXRlOwogICAgICAgICAgICBwb2ludGVyLWV2ZW50czogbm9uZTsKICAgICAgICB9CiAgICAgICAg
QGtleWZyYW1lcyBzay1zd2VlcCB7CiAgICAgICAgICAgIDEwMCUgeyB0cmFuc2Zvcm06IHRyYW5zbGF0
ZVgoMTIwJSk7IH0KICAgICAgICB9CiAgICAgICAgLnNrLWljbywgLnNrLWxpbmUgewogICAgICAgICAg
ICBiYWNrZ3JvdW5kOiBsaW5lYXItZ3JhZGllbnQoOTBkZWcsICNiOGMyZDggMCUsICNmMGY0ZmEgMzgl
LCAjZGNlM2YwIDUyJSwgI2I4YzJkOCAxMDAlKTsKICAgICAgICAgICAgYmFja2dyb3VuZC1zaXplOiAy
NDAlIDEwMCU7CiAgICAgICAgICAgIGFuaW1hdGlvbjogc2stc2hpbW1lciAwLjcycyBlYXNlLWluLW91
dCBpbmZpbml0ZTsKICAgICAgICAgICAgd2lsbC1jaGFuZ2U6IGJhY2tncm91bmQtcG9zaXRpb247CiAg
ICAgICAgICAgIGJvcmRlci1yYWRpdXM6IDZweDsKICAgICAgICB9CiAgICAgICAgLnNrLWljbyB7IHdp
ZHRoOiAzNHB4OyBoZWlnaHQ6IDM0cHg7IGZsZXgtc2hyaW5rOiAwOyBib3JkZXItcmFkaXVzOiA4cHg7
IH0KICAgICAgICAuc2stYm9keSB7IGZsZXg6IDE7IG1pbi13aWR0aDogMDsgZGlzcGxheTogZmxleDsg
ZmxleC1kaXJlY3Rpb246IGNvbHVtbjsgZ2FwOiA4cHg7IHBhZGRpbmctdG9wOiAycHg7IH0KICAgICAg
ICAuc2stbGluZSB7IGhlaWdodDogMTBweDsgd2lkdGg6IDEwMCU7IH0KICAgICAgICAuc2stbGluZS5z
aG9ydCB7IHdpZHRoOiA0MiU7IH0KICAgICAgICAuc2stbGluZS5taWQgeyB3aWR0aDogNjglOyB9CiAg
ICAgICAgLnNrLXJvdzpudGgtY2hpbGQoMik6OmFmdGVyIHsgYW5pbWF0aW9uLWRlbGF5OiAuMTJzOyB9
CiAgICAgICAgLnNrLXJvdzpudGgtY2hpbGQoMyk6OmFmdGVyIHsgYW5pbWF0aW9uLWRlbGF5OiAuMjRz
OyB9CiAgICAgICAgLnNrLXJvdzpudGgtY2hpbGQoNCk6OmFmdGVyIHsgYW5pbWF0aW9uLWRlbGF5OiAu
MzZzOyB9CiAgICAgICAgLnNrLXJvdzpudGgtY2hpbGQoNSk6OmFmdGVyIHsgYW5pbWF0aW9uLWRlbGF5
OiAuNDhzOyB9CiAgICAgICAgLnNrLXJvdzpudGgtY2hpbGQoNik6OmFmdGVyIHsgYW5pbWF0aW9uLWRl
bGF5OiAuNnM7IH0KICAgICAgICBAa2V5ZnJhbWVzIHNrLXNoaW1tZXIgewogICAgICAgICAgICAwJSB7
IGJhY2tncm91bmQtcG9zaXRpb246IDEwMCUgMDsgfQogICAgICAgICAgICAxMDAlIHsgYmFja2dyb3Vu
ZC1wb3NpdGlvbjogLTEwMCUgMDsgfQogICAgICAgIH0KICAgICAgICAubGlzdC1tb3JlIHsKICAgICAg
ICAgICAgdGV4dC1hbGlnbjogY2VudGVyOyBwYWRkaW5nOiAxMHB4IDhweCAxNHB4OyBmb250LXNpemU6
IDExcHg7CiAgICAgICAgICAgIGNvbG9yOiB2YXIoLS10eHQzKTsgLXdlYmtpdC1hcHAtcmVnaW9uOiBu
by1kcmFnOyBhcHAtcmVnaW9uOiBuby1kcmFnOwogICAgICAgIH0KICAgICAgICAubGlzdC1tb3JlLmRv
bmUgeyBkaXNwbGF5OiBub25lOyB9CgogICAgICAgIC5pdG0gewogICAgICAgICAgICBkaXNwbGF5OiBm
bGV4OyBhbGlnbi1pdGVtczogZmxleC1zdGFydDsgZ2FwOiA4cHg7CiAgICAgICAgICAgIHBhZGRpbmc6
IDhweDsgbWFyZ2luLWJvdHRvbTogNXB4OwogICAgICAgICAgICBiYWNrZ3JvdW5kOiB2YXIoLS1jYXJk
KTsgYm9yZGVyLXJhZGl1czogdmFyKC0tcik7IGN1cnNvcjogcG9pbnRlcjsKICAgICAgICAgICAgYm94
LXNoYWRvdzogMCAxcHggM3B4IHJnYmEoMjQsMzIsNTYsLjA2KTsKICAgICAgICAgICAgLyogaG92ZXIt
bGluZSAqLwogICAgICAgICAgICBwb3NpdGlvbjogcmVsYXRpdmU7CiAgICAgICAgICAgIHRyYW5zaXRp
b246IGJhY2tncm91bmQgLjJzIGVhc2UsIGJveC1zaGFkb3cgLjJzIGVhc2U7CiAgICAgICAgICAgIC13
ZWJraXQtYXBwLXJlZ2lvbjogbm8tZHJhZzsgYXBwLXJlZ2lvbjogbm8tZHJhZzsKICAgICAgICAgICAg
b3ZlcmZsb3c6IHZpc2libGU7CiAgICAgICAgICAgIC8qIFNraXAgbGF5b3V0L3BhaW50IGZvciBvZmYt
c2NyZWVuIHJvd3Mgd2hpbGUgZHJhZ2dpbmcgc2Nyb2xsYmFyICovCiAgICAgICAgICAgIGNvbnRlbnQt
dmlzaWJpbGl0eTogYXV0bzsKICAgICAgICAgICAgY29udGFpbi1pbnRyaW5zaWMtc2l6ZTogYXV0byA2
NHB4OwogICAgICAgIH0KICAgICAgICAuaXRtOjpiZWZvcmUgewogICAgICAgICAgICBjb250ZW50OiAi
IjsKICAgICAgICAgICAgcG9zaXRpb246IGFic29sdXRlOwogICAgICAgICAgICBsZWZ0OiAwOyByaWdo
dDogMDsgYm90dG9tOiAwOwogICAgICAgICAgICBoZWlnaHQ6IDA7CiAgICAgICAgICAgIHBvaW50ZXIt
ZXZlbnRzOiBub25lOwogICAgICAgICAgICB6LWluZGV4OiAwOwogICAgICAgICAgICBib3JkZXItcmFk
aXVzOiAwIDAgdmFyKC0tcikgdmFyKC0tcik7CiAgICAgICAgICAgIGJhY2tncm91bmQ6IGxpbmVhci1n
cmFkaWVudCh0byB0b3AsIHJnYmEoOTEsMTE1LDIzMiwuMzIpLCByZ2JhKDkxLDExNSwyMzIsLjEyKSA1
NSUsIHRyYW5zcGFyZW50KTsKICAgICAgICAgICAgdHJhbnNpdGlvbjogaGVpZ2h0IC4zNHMgY3ViaWMt
YmV6aWVyKC4yMiwxLC4zNiwxKTsKICAgICAgICB9CiAgICAgICAgLml0bTpob3Zlcjo6YmVmb3JlIHsg
aGVpZ2h0OiAzMy4zMzMlOyB9CiAgICAgICAgLml0bTo6YWZ0ZXIgewogICAgICAgICAgICBjb250ZW50
OiAiIjsKICAgICAgICAgICAgcG9zaXRpb246IGFic29sdXRlOwogICAgICAgICAgICBsZWZ0OiAwOyBy
aWdodDogMDsgYm90dG9tOiAwOwogICAgICAgICAgICBoZWlnaHQ6IDJweDsKICAgICAgICAgICAgcG9p
bnRlci1ldmVudHM6IG5vbmU7CiAgICAgICAgICAgIHotaW5kZXg6IDE7CiAgICAgICAgICAgIGJhY2tn
cm91bmQ6IHJnYmEoOTEsMTE1LDIzMiwuOTUpOwogICAgICAgICAgICBib3JkZXItcmFkaXVzOiAxcHg7
CiAgICAgICAgICAgIHRyYW5zZm9ybTogc2NhbGVYKDApOwogICAgICAgICAgICB0cmFuc2Zvcm0tb3Jp
Z2luOiBjZW50ZXI7CiAgICAgICAgICAgIHRyYW5zaXRpb246IHRyYW5zZm9ybSAuM3MgY3ViaWMtYmV6
aWVyKC4yMiwxLC4zNiwxKTsKICAgICAgICB9CiAgICAgICAgLml0bTpob3ZlciB7CiAgICAgICAgICAg
IGJhY2tncm91bmQ6IHZhcigtLWNhcmQtaCk7CiAgICAgICAgICAgIGJveC1zaGFkb3c6IDAgMnB4IDhw
eCByZ2JhKDI0LDMyLDU2LC4xKTsKICAgICAgICB9CiAgICAgICAgLml0bTpob3Zlcjo6YWZ0ZXIgewog
ICAgICAgICAgICB0cmFuc2Zvcm06IHNjYWxlWCgxKTsKICAgICAgICB9CiAgICAgICAgLml0bS5zZWwg
ewogICAgICAgICAgICBib3gtc2hhZG93OiAwIDAgMCAycHggcmdiYSg5MSwxMTUsMjMyLC40NSksIDAg
MnB4IDhweCByZ2JhKDkxLDExNSwyMzIsLjE4KTsKICAgICAgICAgICAgYmFja2dyb3VuZDogI2VkZjFm
ZjsKICAgICAgICB9CiAgICAgICAgLml0bS5tdWx0aSB7CiAgICAgICAgICAgIGJveC1zaGFkb3c6IDAg
MCAwIDEuNXB4IHJnYmEoOTEsMTE1LDIzMiwuNTUpLCAwIDJweCA2cHggcmdiYSg5MSwxMTUsMjMyLC4x
OCk7CiAgICAgICAgICAgIGJhY2tncm91bmQ6ICNlZWYyZmY7CiAgICAgICAgfQogICAgICAgIC5pdG0u
bXVsdGkuc2VsIHsKICAgICAgICAgICAgYm94LXNoYWRvdzogMCAwIDAgMnB4IHJnYmEoOTEsMTE1LDIz
MiwuNyksIDAgMnB4IDhweCByZ2JhKDkxLDExNSwyMzIsLjIyKTsKICAgICAgICB9CgogICAgICAgICNt
dWx0aS1iYXIgewogICAgICAgICAgICBkaXNwbGF5OiBub25lOyBhbGlnbi1pdGVtczogY2VudGVyOyBn
YXA6IDFweDsgZmxleC1zaHJpbms6IDA7CiAgICAgICAgICAgIC13ZWJraXQtYXBwLXJlZ2lvbjogbm8t
ZHJhZzsgYXBwLXJlZ2lvbjogbm8tZHJhZzsKICAgICAgICB9CiAgICAgICAgI211bHRpLWJhci5vbiB7
IGRpc3BsYXk6IGlubGluZS1mbGV4OyB9CgogICAgICAgICNtdWx0aS1jbnQgewogICAgICAgICAgICBk
aXNwbGF5OiBpbmxpbmUtZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsganVzdGlmeS1jb250ZW50OiBj
ZW50ZXI7CiAgICAgICAgICAgIGhlaWdodDogMjJweDsgcGFkZGluZzogMCA5cHg7IGZsZXgtc2hyaW5r
OiAwOwogICAgICAgICAgICBib3JkZXI6IG5vbmU7IGJvcmRlci1yYWRpdXM6IDExcHg7IGN1cnNvcjog
cG9pbnRlcjsKICAgICAgICAgICAgYmFja2dyb3VuZDogdmFyKC0tYWNjKTsgY29sb3I6ICNmZmY7CiAg
ICAgICAgICAgIGZvbnQtc2l6ZTogMTFweDsgZm9udC13ZWlnaHQ6IDcwMDsKICAgICAgICAgICAgYm94
LXNoYWRvdzogMCAxcHggNHB4IHJnYmEoOTEsMTE1LDIzMiwuMjgpOwogICAgICAgICAgICAtd2Via2l0
LWFwcC1yZWdpb246IG5vLWRyYWc7IGFwcC1yZWdpb246IG5vLWRyYWc7CiAgICAgICAgICAgIHRyYW5z
aXRpb246IGJhY2tncm91bmQgdmFyKC0tdHIpLCBib3gtc2hhZG93IHZhcigtLXRyKTsKICAgICAgICB9
CiAgICAgICAgI211bHRpLWNudDpob3ZlciB7CiAgICAgICAgICAgIGJhY2tncm91bmQ6ICM0YTYyZDQ7
CiAgICAgICAgICAgIGJveC1zaGFkb3c6IDAgMnB4IDZweCByZ2JhKDkxLDExNSwyMzIsLjM1KTsKICAg
ICAgICB9CgogICAgICAgIC5tdWx0aS1iYXItZG90IHsKICAgICAgICAgICAgY29sb3I6IHZhcigtLXR4
dDMpOyBmb250LXNpemU6IDEwcHg7IG9wYWNpdHk6IC40NTsKICAgICAgICAgICAgdXNlci1zZWxlY3Q6
IG5vbmU7IGxpbmUtaGVpZ2h0OiAxOyBwYWRkaW5nOiAwIDFweDsKICAgICAgICB9CgogICAgICAgICNw
YXN0ZS1zZXAtd3JhcCB7CiAgICAgICAgICAgIHBvc2l0aW9uOiByZWxhdGl2ZTsgZmxleC1zaHJpbms6
IDA7CiAgICAgICAgfQogICAgICAgICNwYXN0ZS1zZXAtYnRuIHsKICAgICAgICAgICAgZGlzcGxheTog
aW5saW5lLWZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGdhcDogMnB4OwogICAgICAgICAgICBoZWln
aHQ6IDIwcHg7IHBhZGRpbmc6IDAgNnB4OwogICAgICAgICAgICBib3JkZXI6IG5vbmU7IGJvcmRlci1y
YWRpdXM6IDEwcHg7IGN1cnNvcjogcG9pbnRlcjsKICAgICAgICAgICAgYmFja2dyb3VuZDogdHJhbnNw
YXJlbnQ7IGNvbG9yOiB2YXIoLS10eHQzKTsKICAgICAgICAgICAgZm9udC1zaXplOiAxMXB4OyBsaW5l
LWhlaWdodDogMTsgZm9udC13ZWlnaHQ6IDcwMDsKICAgICAgICAgICAgZm9udC1mYW1pbHk6IHVpLW1v
bm9zcGFjZSwgQ29uc29sYXMsICJDYXNjYWRpYSBNb25vIiwgbW9ub3NwYWNlOwogICAgICAgICAgICBj
b2xvcjogdmFyKC0tYWNjKTsKICAgICAgICAgICAgLXdlYmtpdC1hcHAtcmVnaW9uOiBuby1kcmFnOyBh
cHAtcmVnaW9uOiBuby1kcmFnOwogICAgICAgICAgICB0cmFuc2l0aW9uOiBiYWNrZ3JvdW5kIHZhcigt
LXRyKSwgY29sb3IgdmFyKC0tdHIpOwogICAgICAgIH0KICAgICAgICAjcGFzdGUtc2VwLWJ0bjpob3Zl
ciwgI3Bhc3RlLXNlcC1idG4ub3BlbiB7CiAgICAgICAgICAgIGJhY2tncm91bmQ6IHJnYmEoOTEsMTE1
LDIzMiwuMDgpOyBjb2xvcjogdmFyKC0tdHh0Mik7CiAgICAgICAgfQoKICAgICAgICAjcGFzdGUtc2Vw
LW1lbnUgewogICAgICAgICAgICBkaXNwbGF5OiBub25lOyBwb3NpdGlvbjogYWJzb2x1dGU7IHRvcDog
Y2FsYygxMDAlICsgNXB4KTsgbGVmdDogMDsKICAgICAgICAgICAgbWluLXdpZHRoOiAxMDhweDsgbWF4
LXdpZHRoOiAxNjBweDsgbWF4LWhlaWdodDogMjQwcHg7CiAgICAgICAgICAgIG92ZXJmbG93LXk6IGF1
dG87IHotaW5kZXg6IDEyMDsKICAgICAgICAgICAgYmFja2dyb3VuZDogcmdiYSgyNTAsMjUxLDI1NCwu
OTcpOwogICAgICAgICAgICBib3JkZXI6IDFweCBzb2xpZCByZ2JhKDAsMCwwLC4wNSk7CiAgICAgICAg
ICAgIGJvcmRlci1yYWRpdXM6IDhweDsKICAgICAgICAgICAgYm94LXNoYWRvdzogMCA2cHggMjBweCBy
Z2JhKDQ0LDQ2LDU0LC4xKTsKICAgICAgICAgICAgcGFkZGluZzogNHB4OwogICAgICAgICAgICBiYWNr
ZHJvcC1maWx0ZXI6IGJsdXIoOHB4KTsKICAgICAgICB9CiAgICAgICAgI3Bhc3RlLXNlcC1tZW51Lm9u
IHsgZGlzcGxheTogYmxvY2s7IH0KICAgICAgICAucGFzdGUtc2VwLWl0ZW0gewogICAgICAgICAgICBk
aXNwbGF5OiBmbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBnYXA6IDZweDsKICAgICAgICAgICAgd2lk
dGg6IDEwMCU7IHRleHQtYWxpZ246IGxlZnQ7CiAgICAgICAgICAgIHBhZGRpbmc6IDVweCA4cHg7IGJv
cmRlcjogbm9uZTsgYm9yZGVyLXJhZGl1czogNnB4OwogICAgICAgICAgICBiYWNrZ3JvdW5kOiBub25l
OyBjb2xvcjogdmFyKC0tdHh0Mik7CiAgICAgICAgICAgIGZvbnQtc2l6ZTogMTBweDsgY3Vyc29yOiBw
b2ludGVyOyB3aGl0ZS1zcGFjZTogbm93cmFwOwogICAgICAgICAgICBvdmVyZmxvdzogaGlkZGVuOwog
ICAgICAgICAgICB0cmFuc2l0aW9uOiBiYWNrZ3JvdW5kIHZhcigtLXRyKSwgY29sb3IgdmFyKC0tdHIp
OwogICAgICAgIH0KICAgICAgICAucGFzdGUtc2VwLXN5bSB7CiAgICAgICAgICAgIGZsZXgtc2hyaW5r
OiAwOyBtaW4td2lkdGg6IDMwcHg7CiAgICAgICAgICAgIGZvbnQtZmFtaWx5OiB1aS1tb25vc3BhY2Us
IENvbnNvbGFzLCAiQ2FzY2FkaWEgTW9ubyIsIG1vbm9zcGFjZTsKICAgICAgICAgICAgZm9udC1zaXpl
OiAxMnB4OyBmb250LXdlaWdodDogNzAwOyBjb2xvcjogdmFyKC0tYWNjKTsKICAgICAgICB9CiAgICAg
ICAgLnBhc3RlLXNlcC1zeW0ub25seSB7IG1pbi13aWR0aDogMDsgfQogICAgICAgIC5wYXN0ZS1zZXAt
bmFtZSB7CiAgICAgICAgICAgIGZsZXg6IDE7IG1pbi13aWR0aDogMDsKICAgICAgICAgICAgZm9udC1z
aXplOiAxMHB4OyBjb2xvcjogdmFyKC0tdHh0Myk7CiAgICAgICAgICAgIG92ZXJmbG93OiBoaWRkZW47
IHRleHQtb3ZlcmZsb3c6IGVsbGlwc2lzOwogICAgICAgIH0KICAgICAgICAucGFzdGUtc2VwLWl0ZW06
aG92ZXIgeyBiYWNrZ3JvdW5kOiByZ2JhKDkxLDExNSwyMzIsLjA4KTsgfQogICAgICAgIC5wYXN0ZS1z
ZXAtaXRlbTpob3ZlciAucGFzdGUtc2VwLW5hbWUgeyBjb2xvcjogdmFyKC0tdHh0Mik7IH0KICAgICAg
ICAucGFzdGUtc2VwLWl0ZW0uc2VsIHsgYmFja2dyb3VuZDogcmdiYSg5MSwxMTUsMjMyLC4xMik7IH0K
ICAgICAgICAucGFzdGUtc2VwLWl0ZW0uc2VsIC5wYXN0ZS1zZXAtbmFtZSB7IGNvbG9yOiB2YXIoLS1h
Y2MpOyBmb250LXdlaWdodDogNjAwOyB9CiAgICAgICAgLnBhc3RlLXNlcC1mb290IHsKICAgICAgICAg
ICAgbWFyZ2luLXRvcDogM3B4OyBwYWRkaW5nLXRvcDogM3B4OwogICAgICAgICAgICBib3JkZXItdG9w
OiAxcHggc29saWQgcmdiYSgwLDAsMCwuMDUpOwogICAgICAgIH0KICAgICAgICAjcGFzdGUtc2VwLWN1
c3RvbSB7CiAgICAgICAgICAgIHdpZHRoOiAxMDAlOyBib3gtc2l6aW5nOiBib3JkZXItYm94OwogICAg
ICAgICAgICBoZWlnaHQ6IDIycHg7IHBhZGRpbmc6IDAgN3B4OwogICAgICAgICAgICBib3JkZXI6IG5v
bmU7IGJvcmRlci1yYWRpdXM6IDVweDsKICAgICAgICAgICAgYmFja2dyb3VuZDogcmdiYSg5MSwxMTUs
MjMyLC4wNik7CiAgICAgICAgICAgIGNvbG9yOiB2YXIoLS10eHQyKTsgZm9udC1zaXplOiAxMHB4Owog
ICAgICAgICAgICAtd2Via2l0LWFwcC1yZWdpb246IG5vLWRyYWc7IGFwcC1yZWdpb246IG5vLWRyYWc7
CiAgICAgICAgfQogICAgICAgICNwYXN0ZS1zZXAtY3VzdG9tOmZvY3VzIHsKICAgICAgICAgICAgb3V0
bGluZTogbm9uZTsgYmFja2dyb3VuZDogcmdiYSg5MSwxMTUsMjMyLC4xKTsgY29sb3I6IHZhcigtLXR4
dCk7CiAgICAgICAgfQogICAgICAgICNwYXN0ZS1zZXAtY3VzdG9tOjpwbGFjZWhvbGRlciB7IGNvbG9y
OiB2YXIoLS10eHQzKTsgfQoKICAgICAgICAuaS1pY28gewogICAgICAgICAgICB3aWR0aDogMjhweDsg
aGVpZ2h0OiAyOHB4OyBib3JkZXItcmFkaXVzOiB2YXIoLS1yKTsgZGlzcGxheTogZmxleDsKICAgICAg
ICAgICAgYWxpZ24taXRlbXM6IGNlbnRlcjsganVzdGlmeS1jb250ZW50OiBjZW50ZXI7IGZsZXgtc2hy
aW5rOiAwOwogICAgICAgICAgICBiYWNrZ3JvdW5kOiAjZWRmMmZmOyBjb2xvcjogdmFyKC0tYWNjKTsK
ICAgICAgICAgICAgcG9zaXRpb246IHJlbGF0aXZlOyBvdmVyZmxvdzogdmlzaWJsZTsKICAgICAgICB9
CiAgICAgICAgLmktaWNvIHN2ZyB7IHdpZHRoOiAxNnB4OyBoZWlnaHQ6IDE2cHg7IGRpc3BsYXk6IGJs
b2NrOyB9CiAgICAgICAgLmktaWNvLmZ0LWltZyB7IGNvbG9yOiAjN2FkN2ZmOyB9CiAgICAgICAgLmkt
aWNvLmZ0LXZpZCB7IGNvbG9yOiAjYzA4NGZjOyB9CiAgICAgICAgLmktaWNvLmZ0LXppcCB7IGNvbG9y
OiAjOGFiNGZmOyB9CiAgICAgICAgLmktaWNvLmZ0LWRpciB7IGNvbG9yOiAjZmZkNTZhOyB9CiAgICAg
ICAgLmktaWNvLmZ0LWFoayB7IGNvbG9yOiAjNmRmZjlhOyB9CiAgICAgICAgLmktaWNvLm1kIHsgY29s
b3I6ICM2YjhjZmY7IH0KICAgICAgICAuaS1pY28ubWQgc3ZnIHsgd2lkdGg6IDIwcHg7IGhlaWdodDog
MjBweDsgfQogICAgICAgIC5pLWljby5mdC1sbmssIC5pLWljby5mdC1kb2MgeyBjb2xvcjogI2E5YmRk
MDsgfQogICAgICAgIC5pLXVzZWQgewogICAgICAgICAgICBwb3NpdGlvbjogYWJzb2x1dGU7IHJpZ2h0
OiAwOyBib3R0b206IDA7CiAgICAgICAgICAgIHdpZHRoOiAxM3B4OyBoZWlnaHQ6IDEzcHg7IGJvcmRl
ci1yYWRpdXM6IDUwJTsKICAgICAgICAgICAgYmFja2dyb3VuZDogIzIyYzU1ZTsgYm9yZGVyOiAxLjVw
eCBzb2xpZCAjZmZmOwogICAgICAgICAgICBkaXNwbGF5OiBmbGV4OyBhbGlnbi1pdGVtczogY2VudGVy
OyBqdXN0aWZ5LWNvbnRlbnQ6IGNlbnRlcjsKICAgICAgICAgICAgcG9pbnRlci1ldmVudHM6IG5vbmU7
IHotaW5kZXg6IDM7CiAgICAgICAgICAgIGJveC1zaGFkb3c6IDAgMXB4IDJweCByZ2JhKDAsMCwwLC4x
Nik7CiAgICAgICAgICAgIHRyYW5zZm9ybTogdHJhbnNsYXRlKDMwJSwgMzAlKTsKICAgICAgICB9CiAg
ICAgICAgLmktdXNlZCBzdmcgeyB3aWR0aDogOXB4OyBoZWlnaHQ6IDlweDsgY29sb3I6ICNmZmY7IGRp
c3BsYXk6IGJsb2NrOyB9CgogICAgICAgIC5pdG0uanVtcC1mbGFzaCB7CiAgICAgICAgICAgIGJveC1z
aGFkb3c6IDAgMCAwIDJweCByZ2JhKDkxLDExNSwyMzIsLjU1KSwgMCAycHggMTBweCByZ2JhKDkxLDEx
NSwyMzIsLjIyKTsKICAgICAgICAgICAgYmFja2dyb3VuZDogI2U4ZWRmZjsKICAgICAgICAgICAgdHJh
bnNpdGlvbjogYmFja2dyb3VuZCAuMzVzIGVhc2UsIGJveC1zaGFkb3cgLjM1cyBlYXNlOwogICAgICAg
IH0KCiAgICAgICAgLmktYm9keSB7IGZsZXg6IDE7IG1pbi13aWR0aDogMDsgZGlzcGxheTogZmxleDsg
ZmxleC1kaXJlY3Rpb246IGNvbHVtbjsgfQogICAgICAgIC5pLXByZXYsIC5pLW5hbWUgewogICAgICAg
ICAgICBmb250LXNpemU6IDEzcHg7IGZvbnQtd2VpZ2h0OiA1MDA7IGNvbG9yOiB2YXIoLS10eHQpOyB3
b3JkLWJyZWFrOiBicmVhay1hbGw7CiAgICAgICAgICAgIHdoaXRlLXNwYWNlOiBwcmUtd3JhcDsgLyog
5pSv5oyB5aSa5paH5Lu2L+WkmuihjOaWh+acrOaNouihjOaYvuekuiAqLwogICAgICAgIH0KICAgICAg
ICAuaS1wcmV2IHsKICAgICAgICAgICAgZGlzcGxheTogLXdlYmtpdC1ib3g7IC13ZWJraXQtYm94LW9y
aWVudDogdmVydGljYWw7IC13ZWJraXQtbGluZS1jbGFtcDogNTsgb3ZlcmZsb3c6IGhpZGRlbjsKICAg
ICAgICAgICAgdGV4dC1vdmVyZmxvdzogZWxsaXBzaXM7CiAgICAgICAgfQogICAgICAgIC5pLW5hbWUg
ewogICAgICAgICAgICBkaXNwbGF5OiAtd2Via2l0LWJveDsgLXdlYmtpdC1ib3gtb3JpZW50OiB2ZXJ0
aWNhbDsgLXdlYmtpdC1saW5lLWNsYW1wOiAyOyBvdmVyZmxvdzogaGlkZGVuOwogICAgICAgIH0KICAg
ICAgICAvKiBGaWxlIGNsaXAgd2hvc2UgcGF0aChzKSBubyBsb25nZXIgZXhpc3Qg4oCUIGxpZ2h0IGJv
bGQgZ3JheSBzdHJpa2UgKi8KICAgICAgICAuaXRtLmdvbmUgLmktbmFtZSB7CiAgICAgICAgICAgIGNv
bG9yOiAjOWFhMGIwOwogICAgICAgICAgICB0ZXh0LWRlY29yYXRpb246IGxpbmUtdGhyb3VnaDsKICAg
ICAgICAgICAgdGV4dC1kZWNvcmF0aW9uLXRoaWNrbmVzczogMnB4OwogICAgICAgICAgICB0ZXh0LWRl
Y29yYXRpb24tY29sb3I6IHJnYmEoMTU0LCAxNjAsIDE3NiwgLjU1KTsKICAgICAgICAgICAgdGV4dC1k
ZWNvcmF0aW9uLXNraXAtaW5rOiBub25lOwogICAgICAgIH0KICAgICAgICAuaXRtLmdvbmUgLmktaWNv
IHsgb3BhY2l0eTogLjU1OyB9CiAgICAgICAgLml0bS5nb25lIC5pLXRodW1iLXdyYXAgeyBvcGFjaXR5
OiAuNTU7IH0KICAgICAgICAuaS1wcmV2LnVybCB7IGNvbG9yOiB2YXIoLS1hY2MpOyB9CiAgICAgICAg
LnJmLXBhdGggewogICAgICAgICAgICBkaXNwbGF5OiBmbGV4OyBmbGV4LXdyYXA6IHdyYXA7IGFsaWdu
LWl0ZW1zOiBjZW50ZXI7CiAgICAgICAgICAgIGdhcDogMDsgcm93LWdhcDogMnB4OwogICAgICAgICAg
ICBmb250LXNpemU6IDEzcHg7IGZvbnQtd2VpZ2h0OiA1MDA7IGNvbG9yOiB2YXIoLS10eHQpOwogICAg
ICAgICAgICBsaW5lLWhlaWdodDogMS40NTsgd29yZC1icmVhazogbm9ybWFsOwogICAgICAgIH0KICAg
ICAgICAucmYtc2VnIHsKICAgICAgICAgICAgY29sb3I6IHZhcigtLWFjYyk7CiAgICAgICAgICAgIGN1
cnNvcjogcG9pbnRlcjsKICAgICAgICAgICAgcGFkZGluZzogMCAxcHg7CiAgICAgICAgICAgIGJvcmRl
ci1yYWRpdXM6IDNweDsKICAgICAgICAgICAgd2hpdGUtc3BhY2U6IG5vd3JhcDsKICAgICAgICAgICAg
LXdlYmtpdC1hcHAtcmVnaW9uOiBuby1kcmFnOyBhcHAtcmVnaW9uOiBuby1kcmFnOwogICAgICAgICAg
ICB0cmFuc2l0aW9uOiBiYWNrZ3JvdW5kIC4xMnMgZWFzZSwgY29sb3IgLjEycyBlYXNlOwogICAgICAg
IH0KICAgICAgICAucmYtc2VnOmhvdmVyIHsKICAgICAgICAgICAgYmFja2dyb3VuZDogcmdiYSg5MSwx
MTUsMjMyLC4xMik7CiAgICAgICAgICAgIHRleHQtZGVjb3JhdGlvbjogdW5kZXJsaW5lOwogICAgICAg
IH0KICAgICAgICAucmYtc2VwIHsKICAgICAgICAgICAgY29sb3I6IHZhcigtLXR4dDMpOwogICAgICAg
ICAgICBwYWRkaW5nOiAwIDFweDsKICAgICAgICAgICAgdXNlci1zZWxlY3Q6IG5vbmU7CiAgICAgICAg
ICAgIGZsZXgtc2hyaW5rOiAwOwogICAgICAgICAgICB3aGl0ZS1zcGFjZTogbm93cmFwOwogICAgICAg
IH0KICAgICAgICAuaS10aHVtYi13cmFwIHsKICAgICAgICAgICAgd2lkdGg6IDEwMCU7IG1pbi1oZWln
aHQ6IDQ4cHg7IG1heC1oZWlnaHQ6IDE4MHB4OyBtYXJnaW4tYm90dG9tOiA0cHg7CiAgICAgICAgICAg
IGRpc3BsYXk6IGZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGp1c3RpZnktY29udGVudDogY2VudGVy
OwogICAgICAgICAgICBiYWNrZ3JvdW5kOiAjZjNmNWY5OyBib3JkZXItcmFkaXVzOiB2YXIoLS1yKTsg
b3ZlcmZsb3c6IGhpZGRlbjsKICAgICAgICB9CiAgICAgICAgLmktdGh1bWItd3JhcC53YWl0aW5nIHsK
ICAgICAgICAgICAgbWluLWhlaWdodDogODhweDsKICAgICAgICAgICAgYmFja2dyb3VuZDogbGluZWFy
LWdyYWRpZW50KDkwZGVnLCAjZThlYmYyIDAlLCAjZjRmNmZhIDQ1JSwgI2U4ZWJmMiAxMDAlKTsKICAg
ICAgICAgICAgYmFja2dyb3VuZC1zaXplOiAyMDAlIDEwMCU7CiAgICAgICAgICAgIGFuaW1hdGlvbjog
dGh1bWJTaGltbWVyIDEuMDVzIGVhc2UtaW4tb3V0IGluZmluaXRlOwogICAgICAgIH0KICAgICAgICBA
a2V5ZnJhbWVzIHRodW1iU2hpbW1lciB7CiAgICAgICAgICAgIDAlIHsgYmFja2dyb3VuZC1wb3NpdGlv
bjogMTAwJSAwOyB9CiAgICAgICAgICAgIDEwMCUgeyBiYWNrZ3JvdW5kLXBvc2l0aW9uOiAtMTAwJSAw
OyB9CiAgICAgICAgfQogICAgICAgIC5pLXRodW1iIHsgbWF4LXdpZHRoOiAxMDAlOyBtYXgtaGVpZ2h0
OiAxODBweDsgd2lkdGg6IGF1dG87IGhlaWdodDogYXV0bzsgb2JqZWN0LWZpdDogY29udGFpbjsgZGlz
cGxheTogYmxvY2s7IH0KICAgICAgICAuaS10aHVtYi50aHVtYi1sb2FkaW5nIHsgb3BhY2l0eTogMDsg
d2lkdGg6IDFweDsgaGVpZ2h0OiAxcHg7IH0KCiAgICAgICAgLyogTWV0YSBiYXI6IHRpbWUgbGVmdCB8
IGV4cGFuZCBjZW50ZXIgfCB0YWdzIHJpZ2h0ICovCiAgICAgICAgLmktbWV0YSB7CiAgICAgICAgICAg
IGRpc3BsYXk6IGdyaWQ7CiAgICAgICAgICAgIGdyaWQtdGVtcGxhdGUtY29sdW1uczogMWZyIGF1dG8g
MWZyOwogICAgICAgICAgICBhbGlnbi1pdGVtczogY2VudGVyOwogICAgICAgICAgICBnYXA6IDRweDsK
ICAgICAgICAgICAgbWFyZ2luLXRvcDogNHB4OwogICAgICAgICAgICB3aWR0aDogMTAwJTsKICAgICAg
ICB9CiAgICAgICAgLmktbWV0YSAuaS10aW1lIHsganVzdGlmeS1zZWxmOiBzdGFydDsgfQogICAgICAg
IC5pLW1ldGEtY2VudGVyIHsKICAgICAgICAgICAganVzdGlmeS1zZWxmOiBjZW50ZXI7CiAgICAgICAg
ICAgIGRpc3BsYXk6IGZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGp1c3RpZnktY29udGVudDogY2Vu
dGVyOwogICAgICAgICAgICBnYXA6IDRweDsKICAgICAgICAgICAgbWluLXdpZHRoOiAxcHg7IC8qIGtl
ZXAgY2VudGVyIGNvbHVtbiBldmVuIHdoZW4gZXhwYW5kIGlzIGhpZGRlbiAqLwogICAgICAgIH0KICAg
ICAgICAuaS1tZXRhLXJpZ2h0IHsKICAgICAgICAgICAganVzdGlmeS1zZWxmOiBlbmQ7CiAgICAgICAg
ICAgIGRpc3BsYXk6IGZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGdhcDogNXB4OyBmbGV4LXdyYXA6
IG5vd3JhcDsKICAgICAgICAgICAganVzdGlmeS1jb250ZW50OiBmbGV4LWVuZDsKICAgICAgICAgICAg
bWluLXdpZHRoOiAwOwogICAgICAgIH0KICAgICAgICAuaS1tZXRhLXJpZ2h0LnRleHQtbWV0YSB7CiAg
ICAgICAgICAgIGZsZXgtd3JhcDogbm93cmFwOwogICAgICAgICAgICBnYXA6IDRweDsKICAgICAgICB9
CiAgICAgICAgLmktc3JjLXRpdGxlIHsKICAgICAgICAgICAgZm9udC1zaXplOiAxMHB4OwogICAgICAg
ICAgICBjb2xvcjogdmFyKC0tdHh0Myk7CiAgICAgICAgICAgIG1heC13aWR0aDogMTFlbTsKICAgICAg
ICAgICAgb3ZlcmZsb3c6IGhpZGRlbjsKICAgICAgICAgICAgdGV4dC1vdmVyZmxvdzogZWxsaXBzaXM7
CiAgICAgICAgICAgIHdoaXRlLXNwYWNlOiBub3dyYXA7CiAgICAgICAgICAgIG1pbi13aWR0aDogMDsK
ICAgICAgICAgICAgbGluZS1oZWlnaHQ6IDEuNDsKICAgICAgICB9CiAgICAgICAgLmktdGltZSwgLmkt
dGFnIHsgZm9udC1zaXplOiAxMHB4OyBjb2xvcjogdmFyKC0tdHh0Myk7IH0KICAgICAgICAuaS10YWcg
ewogICAgICAgICAgICBiYWNrZ3JvdW5kOiAjZjFmM2Y4OyBwYWRkaW5nOiAwIDVweDsgYm9yZGVyLXJh
ZGl1czogM3B4OwogICAgICAgICAgICB3aGl0ZS1zcGFjZTogbm93cmFwOyBmbGV4LXNocmluazogMDsg
bGluZS1oZWlnaHQ6IDEuNDsKICAgICAgICB9CiAgICAgICAgLmktY2hhcnMgewogICAgICAgICAgICBm
b250LXNpemU6IDEwcHg7IGNvbG9yOiB2YXIoLS10eHQzKTsKICAgICAgICAgICAgYmFja2dyb3VuZDog
I2YxZjNmODsgcGFkZGluZzogMCA1cHg7IGJvcmRlci1yYWRpdXM6IDNweDsKICAgICAgICAgICAgZm9u
dC12YXJpYW50LW51bWVyaWM6IHRhYnVsYXItbnVtczsKICAgICAgICAgICAgd2hpdGUtc3BhY2U6IG5v
d3JhcDsKICAgICAgICAgICAgZGlzcGxheTogaW5saW5lLWZsZXg7IGFsaWduLWl0ZW1zOiBiYXNlbGlu
ZTsgZ2FwOiAycHg7CiAgICAgICAgfQogICAgICAgIC5pLWNoYXJzIC5uIHsKICAgICAgICAgICAgZGlz
cGxheTogaW5saW5lLWJsb2NrOwogICAgICAgICAgICBtaW4td2lkdGg6IDRjaDsKICAgICAgICAgICAg
dGV4dC1hbGlnbjogcmlnaHQ7CiAgICAgICAgICAgIGZvbnQtZmFtaWx5OiAnQ2FzY2FkaWEgTW9ubycs
ICdDb25zb2xhcycsICdTYXJhc2EgTW9ubyBTQycsIHVpLW1vbm9zcGFjZSwgbW9ub3NwYWNlOwogICAg
ICAgICAgICBmb250LXdlaWdodDogNjAwOwogICAgICAgICAgICBjb2xvcjogdmFyKC0tdHh0Mik7CiAg
ICAgICAgfQogICAgICAgIC8qIHNyYy10aXRsZS10aXAgKi8KICAgICAgICAuaS1zcmMtaWNvLCAubWct
c3JjIHsgY3Vyc29yOiBwb2ludGVyOyB9CiAgICAgICAgI3NyYy10aXAgewogICAgICAgICAgICBwb3Np
dGlvbjogZml4ZWQ7IHotaW5kZXg6IDk5OTk5OwogICAgICAgICAgICBtYXgtd2lkdGg6IG1pbigyODBw
eCwgY2FsYygxMDB2dyAtIDE2cHgpKTsKICAgICAgICAgICAgcGFkZGluZzogNnB4IDEwcHg7CiAgICAg
ICAgICAgIGJvcmRlci1yYWRpdXM6IDhweDsKICAgICAgICAgICAgYmFja2dyb3VuZDogcmdiYSgzMiwz
Niw0OCwuOTIpOyBjb2xvcjogI2ZmZjsKICAgICAgICAgICAgZm9udC1zaXplOiAxMnB4OyBsaW5lLWhl
aWdodDogMS4zNTsKICAgICAgICAgICAgYm94LXNoYWRvdzogMCA2cHggMThweCByZ2JhKDAsMCwwLC4y
Mik7CiAgICAgICAgICAgIHBvaW50ZXItZXZlbnRzOiBub25lOwogICAgICAgICAgICBvcGFjaXR5OiAw
OyB0cmFuc2Zvcm06IHRyYW5zbGF0ZVkoNHB4KTsKICAgICAgICAgICAgdHJhbnNpdGlvbjogb3BhY2l0
eSAuMnMgZWFzZSwgdHJhbnNmb3JtIC4yMnMgY3ViaWMtYmV6aWVyKC4yMiwxLC4zNiwxKTsKICAgICAg
ICAgICAgd29yZC1icmVhazogYnJlYWstd29yZDsKICAgICAgICB9CiAgICAgICAgI3NyYy10aXAuc2hv
dyB7IG9wYWNpdHk6IDE7IHRyYW5zZm9ybTogdHJhbnNsYXRlWSgwKTsgfQogICAgICAgIC5pLXNyYy1p
Y28gewogICAgICAgICAgICB3aWR0aDogMTRweDsgaGVpZ2h0OiAxNHB4OyBmbGV4LXNocmluazogMDsK
ICAgICAgICAgICAgYm9yZGVyLXJhZGl1czogMnB4OyBvYmplY3QtZml0OiBjb250YWluOwogICAgICAg
ICAgICBkaXNwbGF5OiBibG9jazsKICAgICAgICB9CiAgICAgICAgLmktbnVtIHsKICAgICAgICAgICAg
ZGlzcGxheTogZmxleDsgZmxleC1kaXJlY3Rpb246IGNvbHVtbjsgYWxpZ24taXRlbXM6IGZsZXgtZW5k
OwogICAgICAgICAgICBqdXN0aWZ5LWNvbnRlbnQ6IHNwYWNlLWJldHdlZW47CiAgICAgICAgICAgIGFs
aWduLXNlbGY6IHN0cmV0Y2g7CiAgICAgICAgICAgIGZvbnQtc2l6ZTogMTBweDsgY29sb3I6IHZhcigt
LXR4dDMpOyBtaW4td2lkdGg6IDE2cHg7CiAgICAgICAgICAgIHRleHQtYWxpZ246IHJpZ2h0OyBmbGV4
LXNocmluazogMDsKICAgICAgICAgICAgcGFkZGluZy10b3A6IDJweDsKICAgICAgICB9CiAgICAgICAg
LmktbnVtIC5pLXNyYy1pY28geyB3aWR0aDogMTZweDsgaGVpZ2h0OiAxNnB4OyBtYXJnaW4tdG9wOiBh
dXRvOyB9CgogICAgICAgIC5pLWV4cGFuZC1idG4gewogICAgICAgICAgICBib3JkZXI6IG5vbmU7IGJh
Y2tncm91bmQ6IG5vbmU7IGN1cnNvcjogcG9pbnRlcjsKICAgICAgICAgICAgY29sb3I6IHZhcigtLXR4
dDMpOyBmb250LXNpemU6IDEycHg7IHBhZGRpbmc6IDNweCAxMHB4OwogICAgICAgICAgICBib3JkZXIt
cmFkaXVzOiA4cHg7IGRpc3BsYXk6IG5vbmU7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGdhcDogNHB4Owog
ICAgICAgICAgICB0cmFuc2l0aW9uOiBjb2xvciB2YXIoLS10ciksIGJhY2tncm91bmQgdmFyKC0tdHIp
OwogICAgICAgICAgICAtd2Via2l0LWFwcC1yZWdpb246IG5vLWRyYWc7IGFwcC1yZWdpb246IG5vLWRy
YWc7CiAgICAgICAgICAgIGxpbmUtaGVpZ2h0OiAxLjI7CiAgICAgICAgfQogICAgICAgIC5pLWV4cGFu
ZC1idG4gc3ZnIHsgd2lkdGg6IDE0cHg7IGhlaWdodDogMTRweDsgZmxleC1zaHJpbms6IDA7IH0KICAg
ICAgICAuaS1leHBhbmQtYnRuLm9uIHsgZGlzcGxheTogaW5saW5lLWZsZXg7IH0KICAgICAgICAuaS1l
eHBhbmQtYnRuOmhvdmVyIHsgY29sb3I6IHZhcigtLWFjYyk7IGJhY2tncm91bmQ6IHJnYmEoOTEsMTE1
LDIzMiwuMDgpOyB9CiAgICAgICAgLmktcHJldi5leHBhbmRlZCwgLmktbmFtZS5leHBhbmRlZCB7CiAg
ICAgICAgICAgIC13ZWJraXQtbGluZS1jbGFtcDogdW5zZXQ7CiAgICAgICAgICAgIGRpc3BsYXk6IGJs
b2NrOwogICAgICAgICAgICBvdmVyZmxvdzogaGlkZGVuOwogICAgICAgICAgICAvKiDpq5jluqbnlLEg
SlMg5oyJ5YiX6KGo5Y+v6KeG5Yy66K6+5a6a77ya57qm5Y2g5pW06KGo5bCR5LiA6KGMICovCiAgICAg
ICAgfQogICAgICAgIC5pLXNyYy10aXRsZSB7IGRpc3BsYXk6IG5vbmUgIWltcG9ydGFudDsgfQogICAg
ICAgIC5pLWZpbGUtZGV0YWlsIHsKICAgICAgICAgICAgZGlzcGxheTogbm9uZTsKICAgICAgICAgICAg
bWFyZ2luLXRvcDogNHB4OwogICAgICAgICAgICBwYWRkaW5nOiAwOwogICAgICAgICAgICBiYWNrZ3Jv
dW5kOiBub25lOwogICAgICAgICAgICBib3JkZXI6IG5vbmU7CiAgICAgICAgfQogICAgICAgIC5pLWZp
bGUtZGV0YWlsLm9uIHsgZGlzcGxheTogYmxvY2s7IH0KICAgICAgICAuZmQtYmxvY2sgewogICAgICAg
ICAgICBkaXNwbGF5OiBmbGV4OyBmbGV4LWRpcmVjdGlvbjogY29sdW1uOyBnYXA6IDZweDsKICAgICAg
ICB9CiAgICAgICAgLmZkLWJsb2NrICsgLmZkLWJsb2NrIHsgbWFyZ2luLXRvcDogOHB4OyB9CiAgICAg
ICAgLmZkLXBhdGggewogICAgICAgICAgICB3aWR0aDogMTAwJTsKICAgICAgICAgICAgZm9udDogNjAw
IDEycHgvMS41NSAnU2Vnb2UgVUkgVmFyaWFibGUgVGV4dCcsJ1NlZ29lIFVJJywnTWljcm9zb2Z0IFlh
SGVpIFVJJyxzYW5zLXNlcmlmOwogICAgICAgICAgICBjb2xvcjogdmFyKC0tdHh0Mik7CiAgICAgICAg
ICAgIGxldHRlci1zcGFjaW5nOiAuMDFlbTsKICAgICAgICAgICAgd29yZC1icmVhazogYnJlYWstYWxs
OwogICAgICAgICAgICB1c2VyLXNlbGVjdDogdGV4dDsKICAgICAgICAgICAgLXdlYmtpdC1hcHAtcmVn
aW9uOiBuby1kcmFnOyBhcHAtcmVnaW9uOiBuby1kcmFnOwogICAgICAgIH0KICAgICAgICAuZmQtcGF0
aC5saXZlIHsgY3Vyc29yOiBwb2ludGVyOyB9CiAgICAgICAgLmZkLXBhdGgubGl2ZTpob3ZlciB7IGNv
bG9yOiB2YXIoLS1hY2MpOyB9CiAgICAgICAgLmZkLXBhdGguZGVhZCB7CiAgICAgICAgICAgIGNvbG9y
OiAjOWFhMGIwOwogICAgICAgICAgICB0ZXh0LWRlY29yYXRpb246IGxpbmUtdGhyb3VnaDsKICAgICAg
ICAgICAgdGV4dC1kZWNvcmF0aW9uLXRoaWNrbmVzczogMnB4OwogICAgICAgICAgICB0ZXh0LWRlY29y
YXRpb24tY29sb3I6IHJnYmEoMTU0LCAxNjAsIDE3NiwgLjU1KTsKICAgICAgICAgICAgdGV4dC1kZWNv
cmF0aW9uLXNraXAtaW5rOiBub25lOwogICAgICAgICAgICBjdXJzb3I6IGRlZmF1bHQ7CiAgICAgICAg
fQogICAgICAgIC5mZC1hY3Rpb25zIHsKICAgICAgICAgICAgZGlzcGxheTogZmxleDsgYWxpZ24taXRl
bXM6IGNlbnRlcjsganVzdGlmeS1jb250ZW50OiBmbGV4LWVuZDsKICAgICAgICAgICAgZ2FwOiA4cHg7
IGZsZXgtd3JhcDogd3JhcDsKICAgICAgICB9CiAgICAgICAgLmZkLWJ0biB7CiAgICAgICAgICAgIGJv
cmRlcjogbm9uZTsgYmFja2dyb3VuZDogbm9uZTsgY3Vyc29yOiBwb2ludGVyOwogICAgICAgICAgICBj
b2xvcjogdmFyKC0tdHh0Myk7IGZvbnQtc2l6ZTogMTBweDsgZm9udC13ZWlnaHQ6IDYwMDsKICAgICAg
ICAgICAgcGFkZGluZzogMXB4IDJweDsgZGlzcGxheTogaW5saW5lLWZsZXg7IGFsaWduLWl0ZW1zOiBj
ZW50ZXI7IGdhcDogMnB4OwogICAgICAgICAgICB3aGl0ZS1zcGFjZTogbm93cmFwOwogICAgICAgICAg
ICAtd2Via2l0LWFwcC1yZWdpb246IG5vLWRyYWc7IGFwcC1yZWdpb246IG5vLWRyYWc7CiAgICAgICAg
ICAgIHRyYW5zaXRpb246IGNvbG9yIHZhcigtLXRyKTsKICAgICAgICB9CiAgICAgICAgLmZkLWJ0bjpo
b3ZlciB7IGNvbG9yOiB2YXIoLS1hY2MpOyB9CiAgICAgICAgLmZkLWJ0bi5vayB7IGNvbG9yOiAjMWY3
YTU1OyB9CgogICAgICAgIC8qIOKUgOKUgCBDb250ZXh0IG1lbnUg4pSA4pSA4pSA4pSA4pSA4pSA4pSA
4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA
4pSA4pSA4pSA4pSA4pSAICovCiAgICAgICAgI2N0eCB7CiAgICAgICAgICAgIHBvc2l0aW9uOiBmaXhl
ZDsgei1pbmRleDogOTk5OTsgbWluLXdpZHRoOiAxMzJweDsgZGlzcGxheTogbm9uZTsgcGFkZGluZzog
NHB4OwogICAgICAgICAgICBiYWNrZ3JvdW5kOiAjZmZmOyBib3JkZXItcmFkaXVzOiB2YXIoLS1yKTsg
Ym94LXNoYWRvdzogMCA2cHggMTZweCByZ2JhKDAsMCwwLC4xNCk7CiAgICAgICAgICAgIC13ZWJraXQt
YXBwLXJlZ2lvbjogbm8tZHJhZzsgYXBwLXJlZ2lvbjogbm8tZHJhZzsKICAgICAgICB9CiAgICAgICAg
I2N0eC5vbiB7IGRpc3BsYXk6IGJsb2NrOyB9CiAgICAgICAgLmMtaXRlbSB7CiAgICAgICAgICAgIGRp
c3BsYXk6IGZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGdhcDogN3B4OyBwYWRkaW5nOiA2cHggOXB4
OwogICAgICAgICAgICBib3JkZXItcmFkaXVzOiB2YXIoLS1yKTsgY3Vyc29yOiBwb2ludGVyOyBmb250
LXNpemU6IDExcHg7IGNvbG9yOiB2YXIoLS10eHQpOwogICAgICAgIH0KICAgICAgICAuYy1pdGVtOmhv
dmVyIHsgYmFja2dyb3VuZDogI2YyZjRmOTsgfQogICAgICAgIC5jLWl0ZW0uZGFuZ2VyIHsgY29sb3I6
ICNmZjdiOWM7IH0KICAgICAgICAuYy1zZXAgeyBoZWlnaHQ6IDFweDsgYmFja2dyb3VuZDogI2VjZWZm
NTsgbWFyZ2luOiAzcHggMDsgfQogICAgICAgIC5jLWljbyB7IHdpZHRoOiAxNHB4OyB0ZXh0LWFsaWdu
OiBjZW50ZXI7IH0KCiAgICAgICAgLyog4pSA4pSAIENsZWFyIGNvbmZpcm0g4pSA4pSA4pSA4pSA4pSA
4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA
4pSA4pSA4pSA4pSA4pSA4pSAICovCiAgICAgICAgI2Nsci1kbGcgewogICAgICAgICAgICBkaXNwbGF5
OiBub25lOyBwb3NpdGlvbjogZml4ZWQ7IGluc2V0OiAwOyB6LWluZGV4OiAxMDAwMDsKICAgICAgICAg
ICAgYmFja2dyb3VuZDogcmdiYSgyMCwgMjIsIDM1LCAuNDIpOwogICAgICAgICAgICBhbGlnbi1pdGVt
czogY2VudGVyOyBqdXN0aWZ5LWNvbnRlbnQ6IGNlbnRlcjsKICAgICAgICAgICAgLXdlYmtpdC1hcHAt
cmVnaW9uOiBuby1kcmFnOyBhcHAtcmVnaW9uOiBuby1kcmFnOwogICAgICAgIH0KICAgICAgICAjY2xy
LWRsZy5vbiB7IGRpc3BsYXk6IGZsZXg7IH0KICAgICAgICAuY2xyLWJveCB7CiAgICAgICAgICAgIHdp
ZHRoOiBtaW4oMjgwcHgsIGNhbGMoMTAwJSAtIDMycHgpKTsKICAgICAgICAgICAgYmFja2dyb3VuZDog
I2ZmZjsgYm9yZGVyLXJhZGl1czogMTJweDsKICAgICAgICAgICAgYm94LXNoYWRvdzogMCAxMnB4IDMy
cHggcmdiYSgwLDAsMCwuMTgpOwogICAgICAgICAgICBwYWRkaW5nOiAxNnB4IDE2cHggMTRweDsgY29s
b3I6IHZhcigtLXR4dCk7CiAgICAgICAgfQogICAgICAgIC5jbHItdGl0bGUgeyBmb250LXNpemU6IDE0
cHg7IGZvbnQtd2VpZ2h0OiA3MDA7IG1hcmdpbi1ib3R0b206IDZweDsgfQogICAgICAgIC5jbHItZGVz
YyB7IGZvbnQtc2l6ZTogMTFweDsgY29sb3I6IHZhcigtLXR4dDMpOyBsaW5lLWhlaWdodDogMS41OyBt
YXJnaW4tYm90dG9tOiAxMnB4OyB9CiAgICAgICAgLmNsci1jaGVjayB7CiAgICAgICAgICAgIGRpc3Bs
YXk6IGZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGdhcDogN3B4OwogICAgICAgICAgICBmb250LXNp
emU6IDEycHg7IGNvbG9yOiB2YXIoLS10eHQpOyBjdXJzb3I6IHBvaW50ZXI7CiAgICAgICAgICAgIHVz
ZXItc2VsZWN0OiBub25lOyBtYXJnaW4tYm90dG9tOiAxNHB4OwogICAgICAgIH0KICAgICAgICAuY2xy
LWNoZWNrIGlucHV0IHsKICAgICAgICAgICAgd2lkdGg6IDE0cHg7IGhlaWdodDogMTRweDsgYWNjZW50
LWNvbG9yOiB2YXIoLS1hY2MpOyBjdXJzb3I6IHBvaW50ZXI7CiAgICAgICAgfQogICAgICAgIC5jbHIt
YnRucyB7IGRpc3BsYXk6IGZsZXg7IGdhcDogOHB4OyBqdXN0aWZ5LWNvbnRlbnQ6IGZsZXgtZW5kOyB9
CiAgICAgICAgLmNsci1idG5zIGJ1dHRvbiB7CiAgICAgICAgICAgIGJvcmRlcjogbm9uZTsgYm9yZGVy
LXJhZGl1czogOHB4OyBwYWRkaW5nOiA3cHggMTRweDsKICAgICAgICAgICAgZm9udC1zaXplOiAxMnB4
OyBjdXJzb3I6IHBvaW50ZXI7IGZvbnQtd2VpZ2h0OiA2MDA7CiAgICAgICAgICAgIHRyYW5zaXRpb246
IGJhY2tncm91bmQgdmFyKC0tdHIpLCBjb2xvciB2YXIoLS10cik7CiAgICAgICAgfQogICAgICAgICNj
bHItY2FuY2VsIHsgYmFja2dyb3VuZDogI2YxZjNmODsgY29sb3I6IHZhcigtLXR4dDIpOyB9CiAgICAg
ICAgI2Nsci1jYW5jZWw6aG92ZXIgeyBiYWNrZ3JvdW5kOiAjZTZlOWYyOyB9CiAgICAgICAgI2Nsci1v
ayB7IGJhY2tncm91bmQ6IHJnYmEoMjU1LDEyMywxNTYsLjE0KTsgY29sb3I6ICNlODVhN2E7IH0KICAg
ICAgICAjY2xyLW9rOmhvdmVyIHsgYmFja2dyb3VuZDogcmdiYSgyNTUsMTIzLDE1NiwuMjQpOyB9Cgog
ICAgICAgIC8qIOKUgOKUgCBGaWxlIHBhdGggdGlwIOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKU
gOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKU
gOKUgCAqLwogICAgICAgICNwYXRoLXRpcCB7CiAgICAgICAgICAgIGRpc3BsYXk6IG5vbmU7IHBvc2l0
aW9uOiBmaXhlZDsgei1pbmRleDogMTAwMDE7CiAgICAgICAgICAgIHdpZHRoOiBtaW4oMzIwcHgsIGNh
bGMoMTAwdncgLSAxNnB4KSk7CiAgICAgICAgICAgIG1heC1oZWlnaHQ6IG1pbigyODBweCwgY2FsYygx
MDB2aCAtIDI0cHgpKTsKICAgICAgICAgICAgb3ZlcmZsb3c6IGF1dG87CiAgICAgICAgICAgIHBhZGRp
bmc6IDA7CiAgICAgICAgICAgIGJhY2tncm91bmQ6IGxpbmVhci1ncmFkaWVudCgxNjVkZWcsICNmZmZm
ZmYgMCUsICNmNmY4ZmMgMTAwJSk7CiAgICAgICAgICAgIGJvcmRlcjogMXB4IHNvbGlkIHJnYmEoNzAs
IDg0LCAxMjAsIC4xKTsKICAgICAgICAgICAgYm9yZGVyLXJhZGl1czogMTJweDsKICAgICAgICAgICAg
Ym94LXNoYWRvdzoKICAgICAgICAgICAgICAgIDAgNHB4IDZweCByZ2JhKDMwLCA0MCwgNzAsIC4wNCks
CiAgICAgICAgICAgICAgICAwIDE0cHggMzZweCByZ2JhKDMwLCA0MCwgNzAsIC4xNik7CiAgICAgICAg
ICAgIGNvbG9yOiB2YXIoLS10eHQpOwogICAgICAgICAgICBwb2ludGVyLWV2ZW50czogYXV0bzsKICAg
ICAgICAgICAgb3BhY2l0eTogMDsKICAgICAgICAgICAgdHJhbnNmb3JtOiB0cmFuc2xhdGVZKDRweCkg
c2NhbGUoLjk4KTsKICAgICAgICAgICAgdHJhbnNpdGlvbjogb3BhY2l0eSAuMTRzIGVhc2UsIHRyYW5z
Zm9ybSAuMTRzIGVhc2U7CiAgICAgICAgICAgIC13ZWJraXQtYXBwLXJlZ2lvbjogbm8tZHJhZzsgYXBw
LXJlZ2lvbjogbm8tZHJhZzsKICAgICAgICB9CiAgICAgICAgI3BhdGgtdGlwLm9uIHsKICAgICAgICAg
ICAgZGlzcGxheTogYmxvY2s7CiAgICAgICAgICAgIG9wYWNpdHk6IDE7CiAgICAgICAgICAgIHRyYW5z
Zm9ybTogdHJhbnNsYXRlWSgwKSBzY2FsZSgxKTsKICAgICAgICB9CiAgICAgICAgLnB0LWhlYWQgewog
ICAgICAgICAgICBkaXNwbGF5OiBmbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBqdXN0aWZ5LWNvbnRl
bnQ6IHNwYWNlLWJldHdlZW47CiAgICAgICAgICAgIGdhcDogMTBweDsgcGFkZGluZzogMTBweCAxMnB4
IDhweDsKICAgICAgICAgICAgYm9yZGVyLWJvdHRvbTogMXB4IHNvbGlkIHJnYmEoNzAsIDg0LCAxMjAs
IC4wNyk7CiAgICAgICAgfQogICAgICAgIC5wdC10aXRsZSB7CiAgICAgICAgICAgIGZvbnQtc2l6ZTog
MTFweDsgZm9udC13ZWlnaHQ6IDcwMDsgbGV0dGVyLXNwYWNpbmc6IC4wNGVtOwogICAgICAgICAgICBj
b2xvcjogdmFyKC0tdHh0Mik7IHRleHQtdHJhbnNmb3JtOiB1cHBlcmNhc2U7CiAgICAgICAgICAgIGZs
ZXgtc2hyaW5rOiAwOwogICAgICAgIH0KICAgICAgICAucHQtaGVhZC1idG4gewogICAgICAgICAgICBm
bGV4LXNocmluazogMDsgbWFyZ2luLWxlZnQ6IGF1dG87CiAgICAgICAgICAgIGhlaWdodDogMjJweDsg
cGFkZGluZzogMCA4cHg7IGRpc3BsYXk6IGlubGluZS1mbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBn
YXA6IDRweDsKICAgICAgICAgICAgYm9yZGVyOiAxcHggc29saWQgcmdiYSgxMDcsMTEyLDEyOCwuMjIp
OyBib3JkZXItcmFkaXVzOiA2cHg7IGN1cnNvcjogcG9pbnRlcjsKICAgICAgICAgICAgYmFja2dyb3Vu
ZDogcmdiYSgxMDcsMTEyLDEyOCwuMDYpOyBjb2xvcjogIzhhOTBhMDsgZm9udC1zaXplOiAxMXB4OyBm
b250LXdlaWdodDogNjAwOwogICAgICAgICAgICB3aGl0ZS1zcGFjZTogbm93cmFwOwogICAgICAgICAg
ICAtd2Via2l0LWFwcC1yZWdpb246IG5vLWRyYWc7IGFwcC1yZWdpb246IG5vLWRyYWc7CiAgICAgICAg
ICAgIHRyYW5zaXRpb246IGJhY2tncm91bmQgdmFyKC0tdHIpLCBjb2xvciB2YXIoLS10ciksIGJvcmRl
ci1jb2xvciB2YXIoLS10cik7CiAgICAgICAgfQogICAgICAgIC5wdC1oZWFkLWJ0bjpob3ZlciB7CiAg
ICAgICAgICAgIGJhY2tncm91bmQ6IHJnYmEoMTA3LDExMiwxMjgsLjEyKTsgY29sb3I6IHZhcigtLXR4
dDIpOwogICAgICAgICAgICBib3JkZXItY29sb3I6IHJnYmEoMTA3LDExMiwxMjgsLjQpOwogICAgICAg
IH0KICAgICAgICAucHQtbGlzdCB7IHBhZGRpbmc6IDZweCA4cHggOHB4OyBkaXNwbGF5OiBmbGV4OyBm
bGV4LWRpcmVjdGlvbjogY29sdW1uOyBnYXA6IDRweDsgfQogICAgICAgIC5wdC1yb3cgewogICAgICAg
ICAgICBkaXNwbGF5OiBncmlkOyBncmlkLXRlbXBsYXRlLWNvbHVtbnM6IDhweCAxZnI7IGdhcDogOHB4
OwogICAgICAgICAgICBwYWRkaW5nOiA4cHggOHB4OyBib3JkZXItcmFkaXVzOiA4cHg7CiAgICAgICAg
ICAgIGJhY2tncm91bmQ6IHJnYmEoMjU1LDI1NSwyNTUsLjcpOwogICAgICAgIH0KICAgICAgICAucHQt
cm93LmRlYWQgeyBiYWNrZ3JvdW5kOiByZ2JhKDI1NSwgMTIzLCAxNTYsIC4wNik7IH0KICAgICAgICAu
cHQtZG90IHsKICAgICAgICAgICAgd2lkdGg6IDhweDsgaGVpZ2h0OiA4cHg7IGJvcmRlci1yYWRpdXM6
IDUwJTsgbWFyZ2luLXRvcDogNXB4OwogICAgICAgICAgICBiYWNrZ3JvdW5kOiAjMmViNDc4OyBib3gt
c2hhZG93OiAwIDAgMCAzcHggcmdiYSg0NiwgMTgwLCAxMjAsIC4xOCk7CiAgICAgICAgfQogICAgICAg
IC5wdC1yb3cuZGVhZCAucHQtZG90IHsKICAgICAgICAgICAgYmFja2dyb3VuZDogI2U4NWE3YTsgYm94
LXNoYWRvdzogMCAwIDAgM3B4IHJnYmEoMjMyLCA5MCwgMTIyLCAuMTYpOwogICAgICAgIH0KICAgICAg
ICAucHQtbmFtZSB7CiAgICAgICAgICAgIGZvbnQtc2l6ZTogMTJweDsgZm9udC13ZWlnaHQ6IDY1MDsg
Y29sb3I6IHZhcigtLXR4dCk7CiAgICAgICAgICAgIGxpbmUtaGVpZ2h0OiAxLjM7IHdvcmQtYnJlYWs6
IGJyZWFrLWFsbDsKICAgICAgICB9CiAgICAgICAgLnB0LXBhdGggewogICAgICAgICAgICBtYXJnaW4t
dG9wOiAzcHg7CiAgICAgICAgICAgIGZvbnQ6IDEwLjVweC8xLjQ1ICdDYXNjYWRpYSBNb25vJywnQ29u
c29sYXMnLCdNaWNyb3NvZnQgWWFIZWkgVUknLG1vbm9zcGFjZTsKICAgICAgICAgICAgY29sb3I6IHZh
cigtLXR4dDIpOyB3b3JkLWJyZWFrOiBicmVhay1hbGw7CiAgICAgICAgICAgIHVzZXItc2VsZWN0OiB0
ZXh0OwogICAgICAgIH0KICAgICAgICAucHQtcGF0aC5saXZlIHsKICAgICAgICAgICAgY29sb3I6IHZh
cigtLWFjYyk7IGN1cnNvcjogcG9pbnRlcjsKICAgICAgICB9CiAgICAgICAgLnB0LXBhdGgubGl2ZTpo
b3ZlciB7IHRleHQtZGVjb3JhdGlvbjogdW5kZXJsaW5lOyB9CiAgICAgICAgLnB0LXBhdGguZGVhZCB7
CiAgICAgICAgICAgIGNvbG9yOiAjYzQzZDVjOwogICAgICAgICAgICB0ZXh0LWRlY29yYXRpb246IGxp
bmUtdGhyb3VnaDsKICAgICAgICAgICAgdGV4dC1kZWNvcmF0aW9uLXRoaWNrbmVzczogMnB4OwogICAg
ICAgICAgICB0ZXh0LWRlY29yYXRpb24tY29sb3I6ICNlMTFkNDg7CiAgICAgICAgICAgIGN1cnNvcjog
ZGVmYXVsdDsKICAgICAgICB9CiAgICAgICAgLnB0LWFjdGlvbnMgewogICAgICAgICAgICBtYXJnaW4t
dG9wOiA2cHg7CiAgICAgICAgICAgIGRpc3BsYXk6IGZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGdh
cDogNnB4OyBmbGV4LXdyYXA6IHdyYXA7CiAgICAgICAgfQogICAgICAgIC5wdC1jb3B5LWJ0biB7CiAg
ICAgICAgICAgIGhlaWdodDogMjJweDsgcGFkZGluZzogMCA4cHg7IGRpc3BsYXk6IGlubGluZS1mbGV4
OyBhbGlnbi1pdGVtczogY2VudGVyOwogICAgICAgICAgICBib3JkZXI6IDFweCBzb2xpZCByZ2JhKDEw
NywxMTIsMTI4LC4yMik7IGJvcmRlci1yYWRpdXM6IDZweDsgY3Vyc29yOiBwb2ludGVyOwogICAgICAg
ICAgICBiYWNrZ3JvdW5kOiByZ2JhKDEwNywxMTIsMTI4LC4wNik7IGNvbG9yOiAjOGE5MGEwOyBmb250
LXNpemU6IDExcHg7IGZvbnQtd2VpZ2h0OiA2MDA7CiAgICAgICAgICAgIC13ZWJraXQtYXBwLXJlZ2lv
bjogbm8tZHJhZzsgYXBwLXJlZ2lvbjogbm8tZHJhZzsKICAgICAgICAgICAgdHJhbnNpdGlvbjogYmFj
a2dyb3VuZCB2YXIoLS10ciksIGNvbG9yIHZhcigtLXRyKSwgYm9yZGVyLWNvbG9yIHZhcigtLXRyKTsK
ICAgICAgICB9CiAgICAgICAgLnB0LWNvcHktYnRuOmhvdmVyIHsKICAgICAgICAgICAgYmFja2dyb3Vu
ZDogcmdiYSgxMDcsMTEyLDEyOCwuMTIpOyBjb2xvcjogdmFyKC0tdHh0Mik7CiAgICAgICAgICAgIGJv
cmRlci1jb2xvcjogcmdiYSgxMDcsMTEyLDEyOCwuNCk7CiAgICAgICAgfQogICAgICAgIC5wdC1jb3B5
LWJ0bi5vayB7CiAgICAgICAgICAgIGNvbG9yOiAjMWY3YTU1OyBib3JkZXItY29sb3I6IHJnYmEoNDYs
IDE4MCwgMTIwLCAuMzUpOwogICAgICAgICAgICBiYWNrZ3JvdW5kOiByZ2JhKDQ2LCAxODAsIDEyMCwg
LjEpOwogICAgICAgIH0KICAgICAgICAuaXRtLml0LWdyb3VwIHsKICAgICAgICAgICAgZmxleC1kaXJl
Y3Rpb246IGNvbHVtbjsKICAgICAgICAgICAgYWxpZ24taXRlbXM6IHN0cmV0Y2g7CiAgICAgICAgICAg
IGdhcDogMDsKICAgICAgICAgICAgcGFkZGluZzogNnB4IDhweCA0cHg7CiAgICAgICAgICAgIGN1cnNv
cjogZGVmYXVsdDsKICAgICAgICB9CiAgICAgICAgLml0bS5pdC1ncm91cDpob3ZlciB7IGJhY2tncm91
bmQ6IHZhcigtLWNhcmQpOyB9CiAgICAgICAgLm1nLWhlYWQgewogICAgICAgICAgICBkaXNwbGF5OiBm
bGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBnYXA6IDZweDsKICAgICAgICAgICAgZm9udC1zaXplOiAx
MXB4OyBjb2xvcjogdmFyKC0tdHh0Myk7IGZvbnQtd2VpZ2h0OiA2MDA7CiAgICAgICAgICAgIHBhZGRp
bmc6IDJweCAycHggNnB4OyB1c2VyLXNlbGVjdDogbm9uZTsKICAgICAgICB9CiAgICAgICAgLm1nLWhl
YWQgLm1nLXRhZyB7CiAgICAgICAgICAgIGRpc3BsYXk6IGlubGluZS1mbGV4OyBhbGlnbi1pdGVtczog
Y2VudGVyOwogICAgICAgICAgICBoZWlnaHQ6IDE2cHg7IHBhZGRpbmc6IDAgNnB4OyBib3JkZXItcmFk
aXVzOiA4cHg7CiAgICAgICAgICAgIGJhY2tncm91bmQ6IHJnYmEoOTEsMTE1LDIzMiwuMTIpOyBjb2xv
cjogdmFyKC0tYWNjKTsgZm9udC1zaXplOiAxMHB4OwogICAgICAgIH0KICAgICAgICAubWctcm93IHsK
ICAgICAgICAgICAgcGFkZGluZzogN3B4IDZweDsgbWFyZ2luLWJvdHRvbTogM3B4OwogICAgICAgICAg
ICBib3JkZXItcmFkaXVzOiA1cHg7IGN1cnNvcjogcG9pbnRlcjsKICAgICAgICAgICAgYm9yZGVyOiAx
cHggc29saWQgdHJhbnNwYXJlbnQ7CiAgICAgICAgICAgIHRyYW5zaXRpb246IGJhY2tncm91bmQgLjEy
cyBlYXNlLCBib3JkZXItY29sb3IgLjEycyBlYXNlOwogICAgICAgIH0KICAgICAgICAubWctcm93Omhv
dmVyIHsgYmFja2dyb3VuZDogdmFyKC0tY2FyZC1oKTsgfQogICAgICAgIC5tZy1yb3cuc2VsIHsKICAg
ICAgICAgICAgYmFja2dyb3VuZDogI2VkZjFmZjsKICAgICAgICAgICAgYm9yZGVyLWNvbG9yOiByZ2Jh
KDkxLDExNSwyMzIsLjM1KTsKICAgICAgICAgICAgYm94LXNoYWRvdzogMCAwIDAgMXB4IHJnYmEoOTEs
MTE1LDIzMiwuMjUpOwogICAgICAgIH0KICAgICAgICAubWctcm93Lm11bHRpIHsKICAgICAgICAgICAg
YmFja2dyb3VuZDogI2VlZjJmZjsKICAgICAgICAgICAgYm9yZGVyLWNvbG9yOiByZ2JhKDkxLDExNSwy
MzIsLjQ1KTsKICAgICAgICB9CiAgICAgICAgLm1nLXRpdGxlIHsKICAgICAgICAgICAgZm9udC1zaXpl
OiAxM3B4OyBmb250LXdlaWdodDogNjAwOyBjb2xvcjogdmFyKC0tYWNjKTsKICAgICAgICAgICAgbWFy
Z2luLWJvdHRvbTogMnB4OyBsaW5lLWhlaWdodDogMS4zNTsKICAgICAgICAgICAgZGlzcGxheTogLXdl
YmtpdC1ib3g7IC13ZWJraXQtYm94LW9yaWVudDogdmVydGljYWw7IC13ZWJraXQtbGluZS1jbGFtcDog
MjsKICAgICAgICAgICAgb3ZlcmZsb3c6IGhpZGRlbjsgd29yZC1icmVhazogYnJlYWstd29yZDsKICAg
ICAgICB9CiAgICAgICAgLm1nLWJvZHkgewogICAgICAgICAgICBmb250LXNpemU6IDEyLjVweDsgZm9u
dC13ZWlnaHQ6IDUwMDsgY29sb3I6IHZhcigtLXR4dCk7CiAgICAgICAgICAgIHdoaXRlLXNwYWNlOiBw
cmUtd3JhcDsgd29yZC1icmVhazogYnJlYWstYWxsOwogICAgICAgICAgICBkaXNwbGF5OiAtd2Via2l0
LWJveDsgLXdlYmtpdC1ib3gtb3JpZW50OiB2ZXJ0aWNhbDsgLXdlYmtpdC1saW5lLWNsYW1wOiA0Owog
ICAgICAgICAgICBvdmVyZmxvdzogaGlkZGVuOyBsaW5lLWhlaWdodDogMS40OwogICAgICAgIH0KICAg
ICAgICAubWctYm9keS5pbWcgeyBjb2xvcjogdmFyKC0tdHh0Mik7IH0KICAgICAgICAubWctcm93LXRv
cCB7CiAgICAgICAgICAgIGRpc3BsYXk6IGZsZXg7IGFsaWduLWl0ZW1zOiBmbGV4LXN0YXJ0OyBnYXA6
IDhweDsKICAgICAgICB9CiAgICAgICAgLm1nLXJvdy1tYWluIHsgZmxleDogMTsgbWluLXdpZHRoOiAw
OyB9CiAgICAgICAgLm1nLXNyYyB7CiAgICAgICAgICAgIHdpZHRoOiAxOHB4OyBoZWlnaHQ6IDE4cHg7
IGZsZXgtc2hyaW5rOiAwOyBtYXJnaW4tdG9wOiAycHg7CiAgICAgICAgICAgIGJvcmRlci1yYWRpdXM6
IDNweDsgb2JqZWN0LWZpdDogY29udGFpbjsKICAgICAgICAgICAgYmFja2dyb3VuZDogcmdiYSgwLDAs
MCwuMDQpOwogICAgICAgIH0KICAgICAgICAuaS1mYXYtdGl0bGUgewogICAgICAgICAgICBmb250LXNp
emU6IDEzcHg7IGZvbnQtd2VpZ2h0OiA2MDA7IGNvbG9yOiB2YXIoLS1hY2MpOwogICAgICAgICAgICBt
YXJnaW46IDAgMCAzcHg7IGxpbmUtaGVpZ2h0OiAxLjM1OwogICAgICAgICAgICBkaXNwbGF5OiAtd2Vi
a2l0LWJveDsgLXdlYmtpdC1ib3gtb3JpZW50OiB2ZXJ0aWNhbDsgLXdlYmtpdC1saW5lLWNsYW1wOiAy
OwogICAgICAgICAgICBvdmVyZmxvdzogaGlkZGVuOyB3b3JkLWJyZWFrOiBicmVhay13b3JkOwogICAg
ICAgIH0KICAgICAgICAjdGl0bGUtZGxnIHsKICAgICAgICAgICAgZGlzcGxheTogbm9uZTsgcG9zaXRp
b246IGZpeGVkOyBpbnNldDogMDsgei1pbmRleDogMTAwOwogICAgICAgICAgICBiYWNrZ3JvdW5kOiBy
Z2JhKDE1LDE4LDI4LC4zNSk7CiAgICAgICAgICAgIGFsaWduLWl0ZW1zOiBjZW50ZXI7IGp1c3RpZnkt
Y29udGVudDogY2VudGVyOwogICAgICAgIH0KICAgICAgICAjdGl0bGUtZGxnLm9uIHsgZGlzcGxheTog
ZmxleDsgfQogICAgICAgICN0aXRsZS1kbGcgLnRpdGxlLWJveCB7CiAgICAgICAgICAgIHdpZHRoOiAy
NjBweDsgcGFkZGluZzogMTZweCAxNnB4IDEycHg7CiAgICAgICAgICAgIGJhY2tncm91bmQ6IHZhcigt
LWNhcmQpOyBib3JkZXItcmFkaXVzOiAxMHB4OwogICAgICAgICAgICBib3gtc2hhZG93OiAwIDhweCAy
OHB4IHJnYmEoMCwwLDAsLjE4KTsKICAgICAgICB9CiAgICAgICAgI3RpdGxlLWlucHV0IHsKICAgICAg
ICAgICAgd2lkdGg6IDEwMCU7IGJveC1zaXppbmc6IGJvcmRlci1ib3g7IG1hcmdpbjogOHB4IDAgMTJw
eDsKICAgICAgICAgICAgaGVpZ2h0OiAzMnB4OyBwYWRkaW5nOiAwIDEwcHg7IGJvcmRlci1yYWRpdXM6
IDZweDsKICAgICAgICAgICAgYm9yZGVyOiAxcHggc29saWQgI2Q1ZGFlNjsgYmFja2dyb3VuZDogI2Zm
ZjsgY29sb3I6IHZhcigtLXR4dCk7CiAgICAgICAgICAgIGZvbnQtc2l6ZTogMTNweDsgb3V0bGluZTog
bm9uZTsKICAgICAgICB9CiAgICAgICAgI3RpdGxlLWlucHV0OmZvY3VzIHsgYm9yZGVyLWNvbG9yOiB2
YXIoLS1hY2MpOyB9CgogICAgCiAgICAgICAgLyogdWktZ3JheS1iZy12MSAqLwogICAgICAgIDpyb290
IHsKICAgICAgICAgICAgLS1iZzogI2U0ZTdlZSAhaW1wb3J0YW50OwogICAgICAgIH0KICAgICAgICBo
dG1sLCBib2R5IHsKICAgICAgICAgICAgYmFja2dyb3VuZDogI2U0ZTdlZSAhaW1wb3J0YW50OwogICAg
ICAgIH0KICAgICAgICAjYXBwIHsKICAgICAgICAgICAgYmFja2dyb3VuZDogbGluZWFyLWdyYWRpZW50
KDE4MGRlZywgI2U5ZWNmMyAwJSwgI2UwZTRlYyAxMDAlKSAhaW1wb3J0YW50OwogICAgICAgIH0KICAg
ICAgICAjaGRyIHsKICAgICAgICAgICAgYmFja2dyb3VuZDogI2UyZTZlZSAhaW1wb3J0YW50OwogICAg
ICAgIH0KICAgICAgICAjdGFicyB7CiAgICAgICAgICAgIGJhY2tncm91bmQ6ICNlMmU2ZWUgIWltcG9y
dGFudDsKICAgICAgICB9CiAgICAgICAgI2xpc3QsICNlbXB0eSwgI3NrZWwsICNoZHItZ3JvdywgI3Nl
YXJjaC13cmFwIHsKICAgICAgICAgICAgYmFja2dyb3VuZDogdHJhbnNwYXJlbnQgIWltcG9ydGFudDsK
ICAgICAgICB9CiAgICAgICAgI3NlYXJjaC1ib3ggewogICAgICAgICAgICB0cmFuc2Zvcm0tb3JpZ2lu
OiByaWdodCBjZW50ZXI7CiAgICAgICAgICAgIGJhY2tncm91bmQ6IHRyYW5zcGFyZW50ICFpbXBvcnRh
bnQ7CiAgICAgICAgfQogICAgICAgIC5pdG0sIC5tZywgLm1nLXJvdywgLm1lcmdlLWdyb3VwIHsKICAg
ICAgICAgICAgYmFja2dyb3VuZDogI2ZmZmZmZiAhaW1wb3J0YW50OwogICAgICAgIH0KICAgICAgICAu
aXRtOmhvdmVyIHsKICAgICAgICAgICAgYmFja2dyb3VuZDogI2Y4ZjlmYyAhaW1wb3J0YW50OwogICAg
ICAgIH0KICAgIAogICAgICAgIC8qIHNlbC10aW50LWJsdWUtdjEgKi8KICAgICAgICAuaXRtLnNlbCwK
ICAgICAgICAubWctcm93LnNlbCwKICAgICAgICAuaXRtLm11bHRpLAogICAgICAgIC5tZy1yb3cubXVs
dGksCiAgICAgICAgLml0bS5tdWx0aS5zZWwsCiAgICAgICAgLml0LWdyb3VwLnNlbCwKICAgICAgICAu
aXQtZ3JvdXAubXVsdGkgewogICAgICAgICAgICBiYWNrZ3JvdW5kOiAjZThlZmZmICFpbXBvcnRhbnQ7
CiAgICAgICAgfQogICAgICAgIC5pdG0uc2VsOmhvdmVyLAogICAgICAgIC5pdG0ubXVsdGk6aG92ZXIs
CiAgICAgICAgLm1nLXJvdy5zZWw6aG92ZXIsCiAgICAgICAgLm1nLXJvdy5tdWx0aTpob3ZlciB7CiAg
ICAgICAgICAgIGJhY2tncm91bmQ6ICNkZGU2ZmYgIWltcG9ydGFudDsKICAgICAgICB9CiAgICAKICAg
ICAgICAvKiBob3Zlci1ncmVlbi1yaXNlLXYyICovCiAgICAgICAgLyogaG92ZXItYWNjZW50LXJpc2Ut
djMgKi8KICAgICAgICAuaXRtIHsgcG9zaXRpb246IHJlbGF0aXZlICFpbXBvcnRhbnQ7IG92ZXJmbG93
OiBoaWRkZW4gIWltcG9ydGFudDsgfQogICAgICAgIC5pdG06OmJlZm9yZSB7CiAgICAgICAgICAgIGNv
bnRlbnQ6ICIiICFpbXBvcnRhbnQ7CiAgICAgICAgICAgIHBvc2l0aW9uOiBhYnNvbHV0ZSAhaW1wb3J0
YW50OwogICAgICAgICAgICBsZWZ0OiAwICFpbXBvcnRhbnQ7IHJpZ2h0OiAwICFpbXBvcnRhbnQ7IGJv
dHRvbTogMCAhaW1wb3J0YW50OwogICAgICAgICAgICBoZWlnaHQ6IDAgIWltcG9ydGFudDsKICAgICAg
ICAgICAgcG9pbnRlci1ldmVudHM6IG5vbmUgIWltcG9ydGFudDsKICAgICAgICAgICAgei1pbmRleDog
MCAhaW1wb3J0YW50OwogICAgICAgICAgICBib3JkZXItcmFkaXVzOiAwIDAgdmFyKC0tciwgNHB4KSB2
YXIoLS1yLCA0cHgpICFpbXBvcnRhbnQ7CiAgICAgICAgICAgIGJhY2tncm91bmQ6IGxpbmVhci1ncmFk
aWVudCh0byB0b3AsCiAgICAgICAgICAgICAgICByZ2JhKDkxLCAxMTUsIDIzMiwgLjMyKSAwJSwKICAg
ICAgICAgICAgICAgIHJnYmEoOTEsIDExNSwgMjMyLCAuMTIpIDU1JSwKICAgICAgICAgICAgICAgIHJn
YmEoOTEsIDExNSwgMjMyLCAwKSAxMDAlKSAhaW1wb3J0YW50OwogICAgICAgICAgICB0cmFuc2l0aW9u
OiBoZWlnaHQgLjM0cyBjdWJpYy1iZXppZXIoLjIyLCAxLCAuMzYsIDEpICFpbXBvcnRhbnQ7CiAgICAg
ICAgfQogICAgICAgIC5pdG06aG92ZXI6OmJlZm9yZSB7IGhlaWdodDogMzMuMzMzJSAhaW1wb3J0YW50
OyB9CiAgICAgICAgLml0bTo6YWZ0ZXIgewogICAgICAgICAgICBjb250ZW50OiAiIiAhaW1wb3J0YW50
OwogICAgICAgICAgICBwb3NpdGlvbjogYWJzb2x1dGUgIWltcG9ydGFudDsKICAgICAgICAgICAgbGVm
dDogMCAhaW1wb3J0YW50OyByaWdodDogMCAhaW1wb3J0YW50OyBib3R0b206IDAgIWltcG9ydGFudDsK
ICAgICAgICAgICAgaGVpZ2h0OiAycHggIWltcG9ydGFudDsKICAgICAgICAgICAgcG9pbnRlci1ldmVu
dHM6IG5vbmUgIWltcG9ydGFudDsKICAgICAgICAgICAgei1pbmRleDogMSAhaW1wb3J0YW50OwogICAg
ICAgICAgICBiYWNrZ3JvdW5kOiByZ2JhKDkxLCAxMTUsIDIzMiwgLjkyKSAhaW1wb3J0YW50OwogICAg
ICAgICAgICBib3JkZXItcmFkaXVzOiAxcHggIWltcG9ydGFudDsKICAgICAgICAgICAgdHJhbnNmb3Jt
OiBzY2FsZVgoMCkgIWltcG9ydGFudDsKICAgICAgICAgICAgdHJhbnNmb3JtLW9yaWdpbjogY2VudGVy
ICFpbXBvcnRhbnQ7CiAgICAgICAgICAgIHRyYW5zaXRpb246IHRyYW5zZm9ybSAuM3MgY3ViaWMtYmV6
aWVyKC4yMiwgMSwgLjM2LCAxKSAhaW1wb3J0YW50OwogICAgICAgIH0KICAgICAgICAuaXRtOmhvdmVy
OjphZnRlciB7CiAgICAgICAgICAgIHRyYW5zZm9ybTogc2NhbGVYKDEpICFpbXBvcnRhbnQ7CiAgICAg
ICAgICAgIGJhY2tncm91bmQ6IHJnYmEoOTEsIDExNSwgMjMyLCAuOTUpICFpbXBvcnRhbnQ7CiAgICAg
ICAgfQogICAgICAgIC5pdG0gPiAqIHsgcG9zaXRpb246IHJlbGF0aXZlOyB6LWluZGV4OiAyOyB9CiAg
ICAgICAgICAgIC8qIHBhbmVsLW91dGVyOiBEV00gQUEgY29ybmVycyArIENTUyBjbGlwIH44cHggKi8K
ICAgICAgICBodG1sLCBib2R5IHsKICAgICAgICAgICAgYm9yZGVyOiBub25lICFpbXBvcnRhbnQ7CiAg
ICAgICAgICAgIG91dGxpbmU6IG5vbmUgIWltcG9ydGFudDsKICAgICAgICAgICAgYm94LXNoYWRvdzog
bm9uZSAhaW1wb3J0YW50OwogICAgICAgICAgICBib3JkZXItcmFkaXVzOiA4cHggIWltcG9ydGFudDsK
ICAgICAgICAgICAgb3ZlcmZsb3c6IGhpZGRlbiAhaW1wb3J0YW50OwogICAgICAgIH0KICAgICAgICAj
YXBwIHsKICAgICAgICAgICAgYm9yZGVyOiBub25lICFpbXBvcnRhbnQ7CiAgICAgICAgICAgIG91dGxp
bmU6IG5vbmUgIWltcG9ydGFudDsKICAgICAgICAgICAgYm94LXNoYWRvdzogbm9uZSAhaW1wb3J0YW50
OwogICAgICAgICAgICBib3JkZXItcmFkaXVzOiA4cHggIWltcG9ydGFudDsKICAgICAgICAgICAgYm94
LXNpemluZzogYm9yZGVyLWJveCAhaW1wb3J0YW50OwogICAgICAgICAgICBvdmVyZmxvdzogaGlkZGVu
ICFpbXBvcnRhbnQ7CiAgICAgICAgfQogICAgICAgIC5pdG0sIC5tZywgLm1nLXJvdywgLm1lcmdlLWdy
b3VwIHsKICAgICAgICAgICAgYm9yZGVyOiBub25lICFpbXBvcnRhbnQ7CiAgICAgICAgfQogICAgPC9z
dHlsZT4KPC9oZWFkPgo8Ym9keT4KPGRpdiBpZD0iYXBwIj4KICAgIDxkaXYgaWQ9ImhkciI+CiAgICAg
ICAgPGRpdiBpZD0iaGVhcnQiPgogICAgICAgICAgICA8c3ZnIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmls
bD0ibm9uZSIgc3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0cm9rZS13aWR0aD0iMS44IgogICAgICAgICAg
ICAgICAgIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIgc3Ryb2tlLWxpbmVqb2luPSJyb3VuZCI+CiAgICAg
ICAgICAgICAgICA8cmVjdCB4PSI5IiB5PSIyIiB3aWR0aD0iNiIgaGVpZ2h0PSI0IiByeD0iMSIvPgog
ICAgICAgICAgICAgICAgPHBhdGggZD0iTTE2IDRoMmEyIDIgMCAwIDEgMiAydjE0YTIgMiAwIDAgMS0y
IDJINmEyIDIgMCAwIDEtMi0yVjZhMiAyIDAgMCAxIDItMmgyIi8+CiAgICAgICAgICAgICAgICA8cGF0
aCBkPSJNOSAxMmg2TTkgMTZoNCIvPgogICAgICAgICAgICA8L3N2Zz4KICAgICAgICA8L2Rpdj4KICAg
ICAgICA8ZGl2IGlkPSJoZHItZ3JvdyI+PC9kaXY+CiAgICAgICAgPGRpdiBpZD0ibXVsdGktYmFyIj4K
ICAgICAgICAgICAgPGJ1dHRvbiBpZD0ibXVsdGktY250IiB0eXBlPSJidXR0b24iIHRpdGxlPSLlj5bm
tojlpJrpgIkiPuW3sumAiTA8L2J1dHRvbj4KICAgICAgICAgICAgPHNwYW4gY2xhc3M9Im11bHRpLWJh
ci1kb3QiIGFyaWEtaGlkZGVuPSJ0cnVlIj7Ctzwvc3Bhbj4KICAgICAgICAgICAgPGRpdiBpZD0icGFz
dGUtc2VwLXdyYXAiPgogICAgICAgICAgICAgICAgPGJ1dHRvbiBpZD0icGFzdGUtc2VwLWJ0biIgdHlw
ZT0iYnV0dG9uIiB0aXRsZT0i57KY6LS05YiG6ZqU56ymIj4KICAgICAgICAgICAgICAgICAgICA8c3Bh
biBpZD0icGFzdGUtc2VwLWxhYmVsIj7ikKM8L3NwYW4+CiAgICAgICAgICAgICAgICA8L2J1dHRvbj4K
ICAgICAgICAgICAgICAgIDxkaXYgaWQ9InBhc3RlLXNlcC1tZW51Ij48L2Rpdj4KICAgICAgICAgICAg
PC9kaXY+CiAgICAgICAgPC9kaXY+CiAgICAgICAgPGJ1dHRvbiBpZD0iYnRuLWxvY2F0ZSIgdHlwZT0i
YnV0dG9uIiB0aXRsZT0i5a6a5L2N5Yiw5LiK5qyh5L2/55So55qE5p2h55uuIiBkaXNhYmxlZD4KICAg
ICAgICAgICAgPHN2ZyB2aWV3Qm94PSIwIDAgMjQgMjQiIGZpbGw9Im5vbmUiIHN0cm9rZT0iY3VycmVu
dENvbG9yIiBzdHJva2Utd2lkdGg9IjIiCiAgICAgICAgICAgICAgICAgc3Ryb2tlLWxpbmVjYXA9InJv
dW5kIiBzdHJva2UtbGluZWpvaW49InJvdW5kIj4KICAgICAgICAgICAgICAgIDxjaXJjbGUgY3g9IjEy
IiBjeT0iMTIiIHI9IjgiLz4KICAgICAgICAgICAgICAgIDxjaXJjbGUgY3g9IjEyIiBjeT0iMTIiIHI9
IjMuNSIvPgogICAgICAgICAgICA8L3N2Zz4KICAgICAgICA8L2J1dHRvbj4KICAgICAgICA8ZGl2IGlk
PSJzZWFyY2gtd3JhcCI+CiAgICAgICAgICAgIDxidXR0b24gaWQ9ImJ0bi1zZWFyY2giIHR5cGU9ImJ1
dHRvbiIgdGl0bGU9IuaQnOe0oiI+CiAgICAgICAgICAgICAgICA8c3ZnIHZpZXdCb3g9IjAgMCAyNCAy
NCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0cm9rZS13aWR0aD0iMiIKICAgICAg
ICAgICAgICAgICAgICAgc3Ryb2tlLWxpbmVjYXA9InJvdW5kIiBzdHJva2UtbGluZWpvaW49InJvdW5k
Ij4KICAgICAgICAgICAgICAgICAgICA8Y2lyY2xlIGN4PSIxMSIgY3k9IjExIiByPSI3Ii8+CiAgICAg
ICAgICAgICAgICAgICAgPHBhdGggZD0iTTIwIDIwbC0zLjUtMy41Ii8+CiAgICAgICAgICAgICAgICA8
L3N2Zz4KICAgICAgICAgICAgPC9idXR0b24+CiAgICAgICAgICAgIDxkaXYgaWQ9InNlYXJjaC1ib3gi
PgogICAgICAgICAgICAgICAgPGJ1dHRvbiBpZD0iYnRuLXRvZGF5IiB0eXBlPSJidXR0b24iPuW9k+Wk
qTwvYnV0dG9uPgogICAgICAgICAgICAgICAgPGlucHV0IGlkPSJzZWFyY2giIHR5cGU9InRleHQiIHBs
YWNlaG9sZGVyPSLmkJzntKLigKYg56m65qC85YiG6K+N6aG75ZCM5pe25YyF5ZCrIMK3IGF8YiDliIbm
rrUiIGF1dG9jb21wbGV0ZT0ib2ZmIiBzcGVsbGNoZWNrPSJmYWxzZSI+CiAgICAgICAgICAgICAgICA8
YnV0dG9uIGlkPSJzZWFyY2gtY2xyIiB0eXBlPSJidXR0b24iPuKclTwvYnV0dG9uPgogICAgICAgICAg
ICA8L2Rpdj4KICAgICAgICA8L2Rpdj4KICAgICAgICA8YnV0dG9uIGlkPSJidG4tcGluIiB0eXBlPSJi
dXR0b24iIHRpdGxlPSLpkonlnKjlsY/luZXkuIoiPgogICAgICAgICAgICA8c3ZnIHZpZXdCb3g9IjAg
MCAyNCAyNCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0cm9rZS13aWR0aD0iMiIK
ICAgICAgICAgICAgICAgICBzdHJva2UtbGluZWpvaW49InJvdW5kIiBzdHJva2UtbGluZWNhcD0icm91
bmQiPgogICAgICAgICAgICAgICAgPGxpbmUgeDE9IjEyIiB5MT0iMTciIHgyPSIxMiIgeTI9IjIyIi8+
CiAgICAgICAgICAgICAgICA8cGF0aCBkPSJNNSAxN2gxNHYtMS43NmEyIDIgMCAwIDAtMS4xMS0xLjc5
bC0xLjc4LS45QTIgMiAwIDAgMSAxNSAxMC43NlY2aDFhMiAyIDAgMCAwIDAtNEg4YTIgMiAwIDAgMCAw
IDRoMXY0Ljc2YTIgMiAwIDAgMS0xLjExIDEuNzlsLTEuNzguOUEyIDIgMCAwIDAgNSAxNS4yNFoiLz4K
ICAgICAgICAgICAgPC9zdmc+CiAgICAgICAgPC9idXR0b24+CiAgICA8L2Rpdj4KCiAgICA8ZGl2IGlk
PSJ0YWJzIj4KICAgICAgICA8ZGl2IGlkPSJ0YWItaW5rIiBhcmlhLWhpZGRlbj0idHJ1ZSI+PC9kaXY+
CiAgICAgICAgPGRpdiBjbGFzcz0idGFiIG9uIiBkYXRhLXRhYj0iYWxsIj7lhajpg6g8L2Rpdj4KICAg
ICAgICA8ZGl2IGNsYXNzPSJ0YWIiIGRhdGEtdGFiPSJ0ZXh0Ij7mlofmnKw8L2Rpdj4KICAgICAgICA8
ZGl2IGNsYXNzPSJ0YWIiIGRhdGEtdGFiPSJpbWFnZSI+5Zu+5YOPPC9kaXY+CiAgICAgICAgPGRpdiBj
bGFzcz0idGFiIiBkYXRhLXRhYj0iZmlsZSI+5paH5Lu2PC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0i
dGFiIiBkYXRhLXRhYj0icmVjZW50Ij7mnIDov5E8L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJ0YWIi
IGRhdGEtdGFiPSJwaW5uZWQiPuaUtuiXjyA8c3BhbiBjbGFzcz0iYmFkZ2UiIGlkPSJwaW4tY250IiBz
dHlsZT0iZGlzcGxheTpub25lIj4wPC9zcGFuPjwvZGl2PgogICAgICAgIDxkaXYgaWQ9InRhYi1hY3Rp
b25zIj4KICAgICAgICAgICAgPHNwYW4gaWQ9ImJhci10eHQiPjA8L3NwYW4+CiAgICAgICAgICAgIDxi
dXR0b24gaWQ9ImJ0bi1jbHIiIHR5cGU9ImJ1dHRvbiIgdGl0bGU9Iua4heepuuWOhuWPsiI+CiAgICAg
ICAgICAgICAgICA8c3ZnIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSJjdXJy
ZW50Q29sb3IiIHN0cm9rZS13aWR0aD0iMiIKICAgICAgICAgICAgICAgICAgICAgc3Ryb2tlLWxpbmVj
YXA9InJvdW5kIiBzdHJva2UtbGluZWpvaW49InJvdW5kIj4KICAgICAgICAgICAgICAgICAgICA8cG9s
eWxpbmUgcG9pbnRzPSIzIDYgNSA2IDIxIDYiLz4KICAgICAgICAgICAgICAgICAgICA8cGF0aCBkPSJN
MTkgNmwtMSAxNGEyIDIgMCAwIDEtMiAySDhhMiAyIDAgMCAxLTItMkw1IDYiLz4KICAgICAgICAgICAg
ICAgICAgICA8cGF0aCBkPSJNMTAgMTF2Nk0xNCAxMXY2TTkgNlY0aDZ2MiIvPgogICAgICAgICAgICAg
ICAgPC9zdmc+CiAgICAgICAgICAgIDwvYnV0dG9uPgogICAgICAgIDwvZGl2PgogICAgPC9kaXY+Cgog
ICAgPGRpdiBpZD0ibGlzdCI+CiAgICAgICAgPGRpdiBpZD0ic2tlbCIgYXJpYS1oaWRkZW49InRydWUi
PgogICAgICAgICAgICA8ZGl2IGNsYXNzPSJzay1yb3ciPjxkaXYgY2xhc3M9InNrLWljbyI+PC9kaXY+
PGRpdiBjbGFzcz0ic2stYm9keSI+PGRpdiBjbGFzcz0ic2stbGluZSBtaWQiPjwvZGl2PjxkaXYgY2xh
c3M9InNrLWxpbmUgc2hvcnQiPjwvZGl2PjwvZGl2PjwvZGl2PgogICAgICAgICAgICA8ZGl2IGNsYXNz
PSJzay1yb3ciPjxkaXYgY2xhc3M9InNrLWljbyI+PC9kaXY+PGRpdiBjbGFzcz0ic2stYm9keSI+PGRp
diBjbGFzcz0ic2stbGluZSI+PC9kaXY+PGRpdiBjbGFzcz0ic2stbGluZSBtaWQiPjwvZGl2PjwvZGl2
PjwvZGl2PgogICAgICAgICAgICA8ZGl2IGNsYXNzPSJzay1yb3ciPjxkaXYgY2xhc3M9InNrLWljbyI+
PC9kaXY+PGRpdiBjbGFzcz0ic2stYm9keSI+PGRpdiBjbGFzcz0ic2stbGluZSBtaWQiPjwvZGl2Pjxk
aXYgY2xhc3M9InNrLWxpbmUgc2hvcnQiPjwvZGl2PjwvZGl2PjwvZGl2PgogICAgICAgICAgICA8ZGl2
IGNsYXNzPSJzay1yb3ciPjxkaXYgY2xhc3M9InNrLWljbyI+PC9kaXY+PGRpdiBjbGFzcz0ic2stYm9k
eSI+PGRpdiBjbGFzcz0ic2stbGluZSI+PC9kaXY+PGRpdiBjbGFzcz0ic2stbGluZSBtaWQiPjwvZGl2
PjwvZGl2PjwvZGl2PgogICAgICAgICAgICA8ZGl2IGNsYXNzPSJzay1yb3ciPjxkaXYgY2xhc3M9InNr
LWljbyI+PC9kaXY+PGRpdiBjbGFzcz0ic2stYm9keSI+PGRpdiBjbGFzcz0ic2stbGluZSBtaWQiPjwv
ZGl2PjxkaXYgY2xhc3M9InNrLWxpbmUgc2hvcnQiPjwvZGl2PjwvZGl2PjwvZGl2PgogICAgICAgICAg
ICA8ZGl2IGNsYXNzPSJzay1yb3ciPjxkaXYgY2xhc3M9InNrLWljbyI+PC9kaXY+PGRpdiBjbGFzcz0i
c2stYm9keSI+PGRpdiBjbGFzcz0ic2stbGluZSI+PC9kaXY+PGRpdiBjbGFzcz0ic2stbGluZSBzaG9y
dCI+PC9kaXY+PC9kaXY+PC9kaXY+CiAgICAgICAgPC9kaXY+CiAgICAgICAgPGRpdiBpZD0iZW1wdHki
PgogICAgICAgICAgICA8ZGl2IGNsYXNzPSJlLXR4dCIgaWQ9ImVtcHR5LXR4dCI+5pqC5peg6K6w5b2V
77yM5aSN5Yi25ZCO6Ieq5Yqo5Ye6546wPC9kaXY+CiAgICAgICAgPC9kaXY+CiAgICA8L2Rpdj4KICAg
IDxidXR0b24gaWQ9ImJ0bi10b3AiIHR5cGU9ImJ1dHRvbiIgdGl0bGU9IuWbnuWIsOmhtumDqCIgYXJp
YS1sYWJlbD0i5Zue5Yiw6aG26YOoIj4KICAgICAgICA8c3ZnIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmls
bD0ibm9uZSIgc3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0cm9rZS13aWR0aD0iMi4yIgogICAgICAgICAg
ICAgc3Ryb2tlLWxpbmVjYXA9InJvdW5kIiBzdHJva2UtbGluZWpvaW49InJvdW5kIj4KICAgICAgICAg
ICAgPHBhdGggZD0iTTEyIDE5VjUiLz4KICAgICAgICAgICAgPHBhdGggZD0iTTUgMTJsNy03IDcgNyIv
PgogICAgICAgIDwvc3ZnPgogICAgPC9idXR0b24+CjwvZGl2PgoKPGRpdiBpZD0iY3R4Ij4KICAgIDxk
aXYgY2xhc3M9ImMtaXRlbSIgaWQ9ImMtY29weSI+PHNwYW4gY2xhc3M9ImMtaWNvIj7ijpg8L3NwYW4+
5aSN5Yi2PC9kaXY+CiAgICA8ZGl2IGNsYXNzPSJjLWl0ZW0iIGlkPSJjLXBhc3RlIj48c3BhbiBjbGFz
cz0iYy1pY28iPuKPjjwvc3Bhbj7nspjotLQ8L2Rpdj4KICAgIDxkaXYgY2xhc3M9ImMtc2VwIj48L2Rp
dj4KICAgIDxkaXYgY2xhc3M9ImMtaXRlbSIgaWQ9ImMtcGluIj48c3BhbiBjbGFzcz0iYy1pY28iPuKY
hTwvc3Bhbj7mlLbol488L2Rpdj4KICAgIDxkaXYgY2xhc3M9ImMtaXRlbSIgaWQ9ImMtdGl0bGUiIHN0
eWxlPSJkaXNwbGF5Om5vbmUiPjxzcGFuIGNsYXNzPSJjLWljbyI+4pyOPC9zcGFuPuiuvue9ruagh+mi
mDwvZGl2PgogICAgPGRpdiBjbGFzcz0iYy1pdGVtIiBpZD0iYy1tZXJnZSIgc3R5bGU9ImRpc3BsYXk6
bm9uZSI+PHNwYW4gY2xhc3M9ImMtaWNvIj7ip4k8L3NwYW4+5ZCI5bm2PC9kaXY+CiAgICA8ZGl2IGNs
YXNzPSJjLWl0ZW0iIGlkPSJjLXVubWVyZ2UiIHN0eWxlPSJkaXNwbGF5Om5vbmUiPjxzcGFuIGNsYXNz
PSJjLWljbyI+4oeEPC9zcGFuPuWPlua2iOWQiOW5tjwvZGl2PgogICAgPGRpdiBjbGFzcz0iYy1pdGVt
IiBpZD0iYy10b3AiPjxzcGFuIGNsYXNzPSJjLWljbyI+4oaRPC9zcGFuPuenu+WIsOmhtumDqDwvZGl2
PgogICAgPGRpdiBjbGFzcz0iYy1pdGVtIiBpZD0iYy1jbGVhci1wYXN0ZWQiIHN0eWxlPSJkaXNwbGF5
Om5vbmUiPjxzcGFuIGNsYXNzPSJjLWljbyI+4pyTPC9zcGFuPua4hemZpOeKtuaAgTwvZGl2PgogICAg
PGRpdiBjbGFzcz0iYy1zZXAiPjwvZGl2PgogICAgPGRpdiBjbGFzcz0iYy1pdGVtIGRhbmdlciIgaWQ9
ImMtZGVsIj48c3BhbiBjbGFzcz0iYy1pY28iPuKclTwvc3Bhbj7liKDpmaQ8L2Rpdj4KPC9kaXY+Cgo8
ZGl2IGlkPSJjbHItZGxnIj4KICAgIDxkaXYgY2xhc3M9ImNsci1ib3giIHJvbGU9ImRpYWxvZyIgYXJp
YS1tb2RhbD0idHJ1ZSI+CiAgICAgICAgPGRpdiBjbGFzcz0iY2xyLXRpdGxlIiBpZD0iY2xyLXRpdGxl
Ij7noa7orqTmuIXnqbrvvJ88L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJjbHItZGVzYyIgaWQ9ImNs
ci1kZXNjIj7pu5jorqTku4XmuIXnqbrlvZPlpKnlhoXlrrnjgII8L2Rpdj4KICAgICAgICA8bGFiZWwg
Y2xhc3M9ImNsci1jaGVjayIgZm9yPSJjbHItYWxsIj4KICAgICAgICAgICAgPGlucHV0IHR5cGU9ImNo
ZWNrYm94IiBpZD0iY2xyLWFsbCI+CiAgICAgICAgICAgIDxzcGFuPua4heepuuaJgOaciTwvc3Bhbj4K
ICAgICAgICA8L2xhYmVsPgogICAgICAgIDxkaXYgY2xhc3M9ImNsci1idG5zIj4KICAgICAgICAgICAg
PGJ1dHRvbiB0eXBlPSJidXR0b24iIGlkPSJjbHItY2FuY2VsIj7lj5bmtog8L2J1dHRvbj4KICAgICAg
ICAgICAgPGJ1dHRvbiB0eXBlPSJidXR0b24iIGlkPSJjbHItb2siPua4heepujwvYnV0dG9uPgogICAg
ICAgIDwvZGl2PgogICAgPC9kaXY+CjwvZGl2PgoKPGRpdiBpZD0idGl0bGUtZGxnIj4KICAgIDxkaXYg
Y2xhc3M9InRpdGxlLWJveCIgcm9sZT0iZGlhbG9nIiBhcmlhLW1vZGFsPSJ0cnVlIj4KICAgICAgICA8
ZGl2IGNsYXNzPSJjbHItdGl0bGUiPuiuvue9ruagh+mimDwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9
ImNsci1kZXNjIj7moIfpopjlj6/ooqvmkJzntKLmib7liLDvvIzku4XnlKjkuo7mlLbol4/mlbTnkIbj
gII8L2Rpdj4KICAgICAgICA8aW5wdXQgaWQ9InRpdGxlLWlucHV0IiB0eXBlPSJ0ZXh0IiBtYXhsZW5n
dGg9IjgwIiBwbGFjZWhvbGRlcj0i57uZ6L+Z5p2h5pS26JeP6LW35Liq5ZCN5a2X4oCmIiBhdXRvY29t
cGxldGU9Im9mZiIgc3BlbGxjaGVjaz0iZmFsc2UiPgogICAgICAgIDxkaXYgY2xhc3M9ImNsci1idG5z
Ij4KICAgICAgICAgICAgPGJ1dHRvbiB0eXBlPSJidXR0b24iIGlkPSJ0aXRsZS1jYW5jZWwiPuWPlua2
iDwvYnV0dG9uPgogICAgICAgICAgICA8YnV0dG9uIHR5cGU9ImJ1dHRvbiIgaWQ9InRpdGxlLW9rIj7k
v53lrZg8L2J1dHRvbj4KICAgICAgICA8L2Rpdj4KICAgIDwvZGl2Pgo8L2Rpdj4KPGRpdiBpZD0icGF0
aC10aXAiIGFyaWEtaGlkZGVuPSJ0cnVlIj48L2Rpdj4KCjxzY3JpcHQ+Ci8qIHNrZWwtZmFpbHNhZmU6
IG9ubHkgaWYgbWFpbiBVSSBzY3JpcHQgbmV2ZXIgYm9vdGVkIOKAlG5ldmVyIGludmVudCBlbXB0eS1z
dGF0ZSAqLwooZnVuY3Rpb24oKXsKICBzZXRUaW1lb3V0KCgpID0+IHsKICAgIHRyeSB7CiAgICAgIGlm
ICh3aW5kb3cuX191aUJvb3RlZCkgcmV0dXJuOwogICAgICB2YXIgYXBwID0gZG9jdW1lbnQuZ2V0RWxl
bWVudEJ5SWQoJ2FwcCcpOwogICAgICBpZiAoYXBwKSBhcHAuY2xhc3NMaXN0LnJlbW92ZSgnYm9vdC1s
b2FkaW5nJyk7CiAgICAgIHZhciBzID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NrZWwnKTsKICAg
ICAgaWYgKHMpIHMuY2xhc3NMaXN0LnJlbW92ZSgnb24nKTsKICAgIH0gY2F0Y2ggKGVycikge30KICB9
LCAzMDAwKTsKfSkoKTsKPC9zY3JpcHQ+CjxzY3JpcHQ+CiAgICBsZXQgYWxsQ2xpcHMgPSBbXSwgY3Vy
VGFiID0gJ2FsbCcsIHF1ZXJ5ID0gJycsIGN0eENsaXAgPSBudWxsLCBzZWxlY3RlZElkID0gMCwgcGlu
bmVkVUkgPSBmYWxzZTsKICAgIGNvbnN0IFRBQl9PUkRFUiA9IFsnYWxsJywgJ3RleHQnLCAnaW1hZ2Un
LCAnZmlsZScsICdyZWNlbnQnLCAncGlubmVkJ107CiAgICBjb25zdCB2aWV3TWVtID0gbmV3IE1hcCgp
OwogICAgZnVuY3Rpb24gdmlld01lbUtleSh0YWIsIHEsIHRvZGF5KSB7CiAgICAgICAgcmV0dXJuIFN0
cmluZyh0YWIgfHwgJ2FsbCcpICsgJ1x0JyArIFN0cmluZyhxIHx8ICcnKSArICdcdCcgKyAodG9kYXkg
PyAnMScgOiAnMCcpOwogICAgfQogICAgbGV0IHRhYlN3aXRjaEFuaW1EaXIgPSAwOwogICAgbGV0IG11
bHRpSWRzID0gW107CiAgICBsZXQgdG9kYXlPbmx5ID0gZmFsc2U7CiAgICBsZXQgZGlza1RvdGFsID0g
MDsKICAgIGxldCBsb2FkaW5nTW9yZSA9IGZhbHNlOwogICAgLy8gRG9uJ3Qgc2hvdyBza2VsZXRvbiBp
bW1lZGlhdGVseSDigJRvbmx5IGFmdGVyIFNLRUxfREVMQVlfTVMgaWYgZGF0YSBzdGlsbCBtaXNzaW5n
CiAgICBsZXQgYm9vdExvYWRpbmcgPSBmYWxzZTsKICAgIGxldCB3YWl0aW5nRGF0YSA9IGZhbHNlOwog
ICAgbGV0IGhvc3RQdXNoZWRPbmNlID0gZmFsc2U7IC8vIG9ubHkgdGhlbiBtYXkgc2hvd+OAjOaaguaX
oOiusOW9leOAjQogICAgbGV0IHNhd05vbkVtcHR5ID0gZmFsc2U7ICAgIC8vIGlnbm9yZSBib290c3Ry
YXAgZW1wdHkgcHVzaGVzIGJlZm9yZSBmaXJzdCByZWFsIGxpc3QKICAgIGxldCBwaW5uZWRUb3RhbCA9
IDA7ICAgICAgICAvLyBhdXRob3JpdGF0aXZlIOaUtuiXjyBjb3VudCBmcm9tIEFISwogICAgY29uc3Qg
U0tFTF9ERUxBWV9NUyA9IDYwOwogICAgd2luZG93Ll9fZGF0YVJlYWR5ID0gZmFsc2U7CiAgICB3aW5k
b3cuX191aUJvb3RlZCA9IHRydWU7CiAgICAvLyBPcGVuIHBhbmVsIHdpdGhvdXQgcGFzdGluZyDihpIg
YWx3YXlzIGxhbmQgb24gZmlyc3QgaXRlbSAoYWZ0ZXIgZGF0YSBhcnJpdmVzKQogICAgbGV0IHNlbGVj
dEZpcnN0T25TaG93ID0gZmFsc2U7CiAgICBsZXQgbGFzdFBhc3RlSWQgPSAwOwogICAgbGV0IGxhc3RQ
YXN0ZVRhYiA9ICdhbGwnOwogICAgbGV0IGxvY2F0ZUFjdGl2ZSA9IGZhbHNlOwogICAgdHJ5IHsgbGFz
dFBhc3RlSWQgPSArbG9jYWxTdG9yYWdlLmdldEl0ZW0oJ2NsaXBMYXN0UGFzdGVJZCcpIHx8IDA7IH0g
Y2F0Y2gge30KICAgIHRyeSB7CiAgICAgICAgY29uc3QgdCA9IGxvY2FsU3RvcmFnZS5nZXRJdGVtKCdj
bGlwTGFzdFBhc3RlVGFiJykgfHwgJ2FsbCc7CiAgICAgICAgbGFzdFBhc3RlVGFiID0gWydhbGwnLCd0
ZXh0JywnaW1hZ2UnLCdmaWxlJywncGlubmVkJ10uaW5jbHVkZXModCkgPyB0IDogJ2FsbCc7CiAgICB9
IGNhdGNoIHt9CiAgICAvLyBQcmVmZXIgc2FtZS1vcmlnaW4gdW5kZXIgY2xpcHVpLmxvY2FsIChBUFBf
SE9TVCDihpIgQ0xJUF9WMV9ESVIvY2xpcHNfc3RvcmUpLgogICAgLy8gY2xpcHMuc3RvcmUgaXMgYSBk
ZWRpY2F0ZWQgbWFwcGluZyBmYWxsYmFjayB3aGVuIHNhbWUtb3JpZ2luIGZhaWxzLgogICAgY29uc3Qg
U1RPUkVfQkFTRSA9IChsb2NhdGlvbi5vcmlnaW4gJiYgbG9jYXRpb24ub3JpZ2luLmluZGV4T2YoJ2h0
dHBzOi8vJykgPT09IDApCiAgICAgICAgPyAobG9jYXRpb24ub3JpZ2luLnJlcGxhY2UoL1wvJC8sICcn
KSArICcvY2xpcHNfc3RvcmUvJykKICAgICAgICA6ICdodHRwczovL2NsaXB1aS5sb2NhbC9jbGlwc19z
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
J2ltYWdlJywnZmlsZScsJ3JlY2VudCcsJ3Bpbm5lZCddLmluY2x1ZGVzKGxhc3RQYXN0ZVRhYikKICAg
ICAgICAgICAgPyBsYXN0UGFzdGVUYWIgOiAnYWxsJzsKICAgICAgICBjdXJUYWIgPSB0YWI7CiAgICAg
ICAgbG9hZGluZ01vcmUgPSBmYWxzZTsKICAgICAgICB3aW5kb3cuX19zY3JvbGxCdXN5ID0gZmFsc2U7
CiAgICAgICAgd2luZG93Ll9fd2FudE1vcmUgPSBmYWxzZTsKICAgICAgICBfcGVuZGluZ0FwcGVuZCA9
IG51bGw7CiAgICAgICAgbWFya1RhYih0YWIpOwogICAgICAgIGNsZWFyTXVsdGkoKTsKICAgICAgICBz
ZWxlY3RlZElkID0gbGFzdFBhc3RlSWQ7CiAgICAgICAgd2luZG93Ll9fcGVuZGluZ0p1bXBJZCA9IGxh
c3RQYXN0ZUlkOwogICAgICAgIHdpbmRvdy5fX2p1bXBMb2FkVHJpZXMgPSAwOwogICAgICAgIHdpbmRv
dy5fX2p1bXBGZWxsQmFjayA9IGZhbHNlOwogICAgICAgIHVwZGF0ZUxvY2F0ZUJ0bigpOwogICAgICAg
IC8vIEFscmVhZHkgbG9hZGVkIGluIGN1cnJlbnQgbGlzdCDigJQganVtcCB3aXRob3V0IHdhaXRpbmcg
Zm9yIEFISwogICAgICAgIGlmIChjdXJUYWIgPT09IHRhYiAmJiBhbGxDbGlwcy5zb21lKGMgPT4gK2Mu
aWQgPT09ICtsYXN0UGFzdGVJZCkpIHsKICAgICAgICAgICAgdHJ5Q29udGludWVKdW1wKCk7CiAgICAg
ICAgICAgIHJldHVybjsKICAgICAgICB9CiAgICAgICAgcmVxdWVzdFZpZXcoKTsKICAgIH0KCiAgICBm
dW5jdGlvbiByZXF1ZXN0VmlldygpIHsKICAgICAgICBjb25zdCB0YWIgPSBjdXJUYWIsIHEgPSBxdWVy
eSwgdG9kYXkgPSB0b2RheU9ubHkgPyAnMScgOiAnMCc7CiAgICAgICAgaWYgKHdpbmRvdy5fX3ZpZXdS
YWYpIGNhbmNlbEFuaW1hdGlvbkZyYW1lKHdpbmRvdy5fX3ZpZXdSYWYpOwogICAgICAgIHdpbmRvdy5f
X3ZpZXdSYWYgPSByZXF1ZXN0QW5pbWF0aW9uRnJhbWUoKCkgPT4gewogICAgICAgICAgICB3aW5kb3cu
X192aWV3UmFmID0gMDsKICAgICAgICAgICAgc2V0VGltZW91dCgoKSA9PiBhaGsoJ3NldFZpZXcnLCB0
YWIsIHEsIHRvZGF5KSwgMCk7CiAgICAgICAgfSk7CiAgICB9CiAgICAvKiogRGVib3VuY2VkIEFISyBz
eW5jIGFmdGVyIHZpZXdNZW0gaW5zdGFudCBwYWludCDigJRhdm9pZHMgdGFiLXN3aXRjaCBkb3VibGUg
UHVzaENsaXBzICovCiAgICBmdW5jdGlvbiBzb2Z0UmVxdWVzdFZpZXcoKSB7CiAgICAgICAgaWYgKHdp
bmRvdy5fX3NvZnRWaWV3VCkgY2xlYXJUaW1lb3V0KHdpbmRvdy5fX3NvZnRWaWV3VCk7CiAgICAgICAg
d2luZG93Ll9fc29mdFZpZXdUID0gc2V0VGltZW91dCgoKSA9PiB7CiAgICAgICAgICAgIHdpbmRvdy5f
X3NvZnRWaWV3VCA9IDA7CiAgICAgICAgICAgIHJlcXVlc3RWaWV3KCk7CiAgICAgICAgfSwgMzIwKTsK
ICAgIH0KICAgIGZ1bmN0aW9uIHJlcXVlc3RNb3JlKGZvcmNlID0gZmFsc2UpIHsKICAgICAgICBpZiAo
ZGlza1RvdGFsID4gMCAmJiBhbGxDbGlwcy5sZW5ndGggPj0gZGlza1RvdGFsKSByZXR1cm47CiAgICAg
ICAgLy8gTG9jYXRlIC8ganVtcCBtdXN0IG5vdCB3YWl0IG9uIHNjcm9sbC1pZGxlIG9yIGEgc3R1Y2sg
bG9hZGluZ01vcmUgZmxhZwogICAgICAgIGlmICghZm9yY2UpIHsKICAgICAgICAgICAgaWYgKGxvYWRp
bmdNb3JlKSByZXR1cm47CiAgICAgICAgICAgIGlmICh3aW5kb3cuX19zY3JvbGxCdXN5IHx8IF9saXN0
UHRyRG93bikgewogICAgICAgICAgICAgICAgd2luZG93Ll9fd2FudE1vcmUgPSB0cnVlOwogICAgICAg
ICAgICAgICAgcmV0dXJuOwogICAgICAgICAgICB9CiAgICAgICAgfSBlbHNlIHsKICAgICAgICAgICAg
bG9hZGluZ01vcmUgPSBmYWxzZTsKICAgICAgICAgICAgd2luZG93Ll9fc2Nyb2xsQnVzeSA9IGZhbHNl
OwogICAgICAgICAgICB3aW5kb3cuX193YW50TW9yZSA9IGZhbHNlOwogICAgICAgICAgICBfbGlzdFB0
ckRvd24gPSBmYWxzZTsKICAgICAgICAgICAgdHJ5IHsgbGlzdEVsLmNsYXNzTGlzdC5yZW1vdmUoJ2lz
LXNjcm9sbGluZycpOyB9IGNhdGNoIHt9CiAgICAgICAgfQogICAgICAgIGlmIChsb2FkaW5nTW9yZSkg
cmV0dXJuOwogICAgICAgIGxvYWRpbmdNb3JlID0gdHJ1ZTsKICAgICAgICB3aW5kb3cuX193YW50TW9y
ZSA9IGZhbHNlOwogICAgICAgIC8vIFNhZmV0eTogbmV2ZXIgbGVhdmUgbG9hZGluZ01vcmUgc3R1Y2sg
KEFISyBkZWZlciAvIG1pc3NlZCBfX2xvYWRNb3JlRG9uZSkKICAgICAgICBpZiAod2luZG93Ll9fbG9h
ZE1vcmVXYXRjaCkgY2xlYXJUaW1lb3V0KHdpbmRvdy5fX2xvYWRNb3JlV2F0Y2gpOwogICAgICAgIHdp
bmRvdy5fX2xvYWRNb3JlV2F0Y2ggPSBzZXRUaW1lb3V0KCgpID0+IHsKICAgICAgICAgICAgd2luZG93
Ll9fbG9hZE1vcmVXYXRjaCA9IDA7CiAgICAgICAgICAgIGlmIChsb2FkaW5nTW9yZSkgewogICAgICAg
ICAgICAgICAgbG9hZGluZ01vcmUgPSBmYWxzZTsKICAgICAgICAgICAgICAgIGlmICh3aW5kb3cuX19w
ZW5kaW5nSnVtcElkKSB0cnlDb250aW51ZUp1bXAoKTsKICAgICAgICAgICAgfQogICAgICAgIH0sIDE4
MDApOwogICAgICAgIC8vIHN5bmMgaG9zdCBpcyBmaW5lOiBBSEsgbG9hZE1vcmUgb25seSBTZXRUaW1l
cigtMSkgYW5kIHJldHVybnMgaW1tZWRpYXRlbHkKICAgICAgICBhaGsoJ2xvYWRNb3JlJyk7CiAgICB9
CgogICAgZnVuY3Rpb24gdHJ5Q29udGludWVKdW1wKCkgewogICAgICAgIGNvbnN0IGppZCA9ICt3aW5k
b3cuX19wZW5kaW5nSnVtcElkOwogICAgICAgIGlmICghamlkKSByZXR1cm47CiAgICAgICAgLy8gRmx1
c2ggYW55IHNjcm9sbC1kZWZlcnJlZCBET00gc28gcXVlcnlTZWxlY3RvciBjYW4gc2VlIGxvYWRlZCBy
b3dzCiAgICAgICAgaWYgKF9wZW5kaW5nQXBwZW5kKSB7CiAgICAgICAgICAgIGNvbnN0IHBlbmRpbmcg
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
ICAgICAgICB9CiAgICAgICAgLy8gQWxyZWFkeSBpbiBtZW1vcnkgYnV0IERPTSBub3QgYnVpbHQgKGZ1
bGwgcmVuZGVyIG5lZWRlZCkKICAgICAgICBpZiAoYWxsQ2xpcHMuc29tZShjID0+ICtjLmlkID09PSBq
aWQpKSB7CiAgICAgICAgICAgIHJlbmRlcigpOwogICAgICAgICAgICByZXF1ZXN0QW5pbWF0aW9uRnJh
bWUoKCkgPT4gdHJ5Q29udGludWVKdW1wKCkpOwogICAgICAgICAgICByZXR1cm47CiAgICAgICAgfQog
ICAgICAgIGlmIChhbGxDbGlwcy5sZW5ndGggPCBkaXNrVG90YWwgJiYgKHdpbmRvdy5fX2p1bXBMb2Fk
VHJpZXMgfHwgMCkgPCA4MCkgewogICAgICAgICAgICB3aW5kb3cuX19qdW1wTG9hZFRyaWVzID0gKHdp
bmRvdy5fX2p1bXBMb2FkVHJpZXMgfHwgMCkgKyAxOwogICAgICAgICAgICByZXF1ZXN0TW9yZSh0cnVl
KTsKICAgICAgICAgICAgcmV0dXJuOwogICAgICAgIH0KICAgICAgICBpZiAoY3VyVGFiICE9PSAnYWxs
JyAmJiAhd2luZG93Ll9fanVtcEZlbGxCYWNrKSB7CiAgICAgICAgICAgIHdpbmRvdy5fX2p1bXBGZWxs
QmFjayA9IHRydWU7CiAgICAgICAgICAgIHdpbmRvdy5fX2p1bXBMb2FkVHJpZXMgPSAwOwogICAgICAg
ICAgICBjdXJUYWIgPSAnYWxsJzsKICAgICAgICAgICAgbWFya1RhYignYWxsJyk7CiAgICAgICAgICAg
IHJlcXVlc3RWaWV3KCk7CiAgICAgICAgICAgIHJldHVybjsKICAgICAgICB9CiAgICAgICAgd2luZG93
Ll9fcGVuZGluZ0p1bXBJZCA9IDA7CiAgICAgICAgd2luZG93Ll9fanVtcExvYWRUcmllcyA9IDA7CiAg
ICAgICAgc3luY0l0ZW1IaWdobGlnaHQoKTsKICAgIH0KICAgIGNvbnN0IEVNUFRZX01TRyA9IHsKICAg
ICAgICBhbGw6ICAgICfmmoLml6DorrDlvZXvvIzlpI3liLblkI7oh6rliqjlh7rnjrAnLAogICAgICAg
IHRleHQ6ICAgJ+aaguaXoOaWh+acrCcsCiAgICAgICAgaW1hZ2U6ICAn5pqC5peg5Zu+5YOPJywKICAg
ICAgICBmaWxlOiAgICfmmoLml6Dmlofku7YnLAogICAgICAgIHJlY2VudDogJ+aaguaXoOacgOi/keaW
h+S7tuWkue+8jOWcqOi1hOa6kOeuoeeQhuWZqOS4rei/m+WFpeebruW9leWQjuWHuueOsCcsCiAgICAg
ICAgcGlubmVkOiAn5pqC5peg5pS26JePJwogICAgfTsKCiAgICBmdW5jdGlvbiBhaGtJbnZva2UobWV0
aG9kLCBhcmdzKSB7CiAgICAgICAgdHJ5IHsKICAgICAgICAgICAgY29uc3QgaG9zdCA9IGNocm9tZS53
ZWJ2aWV3Lmhvc3RPYmplY3RzLnN5bmMuYWhrOwogICAgICAgICAgICBpZiAoIWhvc3QpIHJldHVybjsK
ICAgICAgICAgICAgbGV0IGNhbGxlZCA9IGZhbHNlOwogICAgICAgICAgICBpZiAodHlwZW9mIGhvc3Qu
Y2FsbCA9PT0gJ2Z1bmN0aW9uJykgewogICAgICAgICAgICAgICAgdHJ5IHsgaG9zdC5jYWxsKG1ldGhv
ZCwgLi4uYXJncyk7IGNhbGxlZCA9IHRydWU7IH0gY2F0Y2gge30KICAgICAgICAgICAgfQogICAgICAg
ICAgICBpZiAoIWNhbGxlZCAmJiB0eXBlb2YgaG9zdFttZXRob2RdID09PSAnZnVuY3Rpb24nKSB7CiAg
ICAgICAgICAgICAgICB0cnkgeyBob3N0W21ldGhvZF0oLi4uYXJncyk7IGNhbGxlZCA9IHRydWU7IH0g
Y2F0Y2gge30KICAgICAgICAgICAgICAgIGlmICghY2FsbGVkKSB7CiAgICAgICAgICAgICAgICAgICAg
dHJ5IHsgaG9zdFttZXRob2RdKC4uLmFyZ3MpOyBjYWxsZWQgPSB0cnVlOyB9IGNhdGNoIHt9CiAgICAg
ICAgICAgICAgICB9CiAgICAgICAgICAgIH0KICAgICAgICAgICAgaWYgKCFjYWxsZWQgJiYgaG9zdFtt
ZXRob2RdICE9IG51bGwgJiYgdHlwZW9mIGhvc3RbbWV0aG9kXSAhPT0gJ2Z1bmN0aW9uJykgewogICAg
ICAgICAgICAgICAgdHJ5IHsgdm9pZCBob3N0W21ldGhvZF07IH0gY2F0Y2gge30KICAgICAgICAgICAg
fQogICAgICAgIH0gY2F0Y2ggKGUpIHsgY29uc29sZS53YXJuKCdhaGsuJyArIG1ldGhvZCwgZSk7IH0K
ICAgIH0KICAgIGZ1bmN0aW9uIGFoayhtZXRob2QsIC4uLmFyZ3MpIHsKICAgICAgICBhaGtJbnZva2Uo
bWV0aG9kLCBhcmdzKTsKICAgIH0KCiAgICBjb25zdCBTRVBfTkVXTElORV9UT0tFTiA9ICdb5o2i6KGM
XSc7CiAgICAvLyBGaXhlZCBjb21tb24gc2VwYXJhdG9ycyBvbmx5IOKAlCBjdXN0b20gdmFsdWVzIGFy
ZSBuZXZlciBhZGRlZCB0byB0aGlzIGxpc3QKICAgIGNvbnN0IFNFUF9MSVNUID0gWycgJywgU0VQX05F
V0xJTkVfVE9LRU4sICcsJywgJywgJywgJ+OAgScsICd8J107CiAgICBsZXQgcGFzdGVTZXBWYWx1ZSA9
ICcgJzsKICAgIGxldCBtdWx0aUJhcldhc09uID0gZmFsc2U7CgogICAgZnVuY3Rpb24gbm9ybWFsaXpl
U2VwSW5wdXQocmF3KSB7CiAgICAgICAgbGV0IHMgPSBTdHJpbmcocmF3ID8/ICcnKTsKICAgICAgICBp
ZiAocyA9PT0gJycpIHJldHVybiAnICc7CiAgICAgICAgLy8gQWNjZXB0IGFsaWFzZXMgdHlwZWQgaW4g
dGhlIGN1c3RvbSBib3gKICAgICAgICBjb25zdCB0ID0gcy50cmltKCk7CiAgICAgICAgaWYgKHQgPT09
IFNFUF9ORVdMSU5FX1RPS0VOIHx8IHQgPT09ICfmjaLooYwnIHx8IHQgPT09ICdcXG4nIHx8IHQgPT09
ICdcbicgfHwgdCA9PT0gJ1xyXG4nKQogICAgICAgICAgICByZXR1cm4gU0VQX05FV0xJTkVfVE9LRU47
CiAgICAgICAgaWYgKHQgPT09ICdcXHQnIHx8IHQgPT09ICdcdCcpIHJldHVybiAnXHQnOwogICAgICAg
IHJldHVybiBzOwogICAgfQogICAgZnVuY3Rpb24gc2VwVG9BY3R1YWwocmF3KSB7CiAgICAgICAgY29u
c3QgcyA9IG5vcm1hbGl6ZVNlcElucHV0KHJhdyk7CiAgICAgICAgcmV0dXJuIHMgPT09IFNFUF9ORVdM
SU5FX1RPS0VOID8gJ1xuJyA6IHM7CiAgICB9CiAgICAvKiogQnJpZGdlLXNhZmUgc2VwIGZvciBBSEsg
aG9zdE9iamVjdHMgKHJlYWwgXFxuIG9mdGVuIGdldHMgc3RyaXBwZWQpICovCiAgICBmdW5jdGlvbiBz
ZXBUb0JyaWRnZShyYXcpIHsKICAgICAgICBjb25zdCBzID0gbm9ybWFsaXplU2VwSW5wdXQocmF3KTsK
ICAgICAgICBpZiAocyA9PT0gU0VQX05FV0xJTkVfVE9LRU4gfHwgcyA9PT0gJ1xuJyB8fCBzID09PSAn
XHJcbicpIHJldHVybiBTRVBfTkVXTElORV9UT0tFTjsKICAgICAgICBpZiAocyA9PT0gJ1x0JykgcmV0
dXJuICdb5Yi26KGo56ymXSc7CiAgICAgICAgcmV0dXJuIHM7CiAgICB9CiAgICBmdW5jdGlvbiBzZXBE
aXNwbGF5U3ltYm9sKHJhdykgewogICAgICAgIGNvbnN0IHMgPSBub3JtYWxpemVTZXBJbnB1dChyYXcp
OwogICAgICAgIGlmIChzID09PSAnICcpIHJldHVybiAn4pCjJzsKICAgICAgICBpZiAocyA9PT0gU0VQ
X05FV0xJTkVfVE9LRU4pIHJldHVybiAn4oa1JzsKICAgICAgICBpZiAocyA9PT0gJ1x0JykgcmV0dXJu
ICfih6UnOwogICAgICAgIGlmIChzID09PSAnXG4nKSByZXR1cm4gJ+KGtSc7CiAgICAgICAgaWYgKHMg
PT09ICdcclxuJykgcmV0dXJuICfihrUnOwogICAgICAgIGlmIChzID09PSAnLCcpIHJldHVybiAnLCc7
CiAgICAgICAgaWYgKHMgPT09ICcsICcpIHJldHVybiAnLOKQoyc7CiAgICAgICAgaWYgKHMgPT09ICfj
gIEnKSByZXR1cm4gJ+OAgSc7CiAgICAgICAgaWYgKHMgPT09ICd8JykgcmV0dXJuICd8JzsKICAgICAg
ICByZXR1cm4gcwogICAgICAgICAgICAucmVwbGFjZSgvXHJcbi9nLCAn4oa1JykKICAgICAgICAgICAg
LnJlcGxhY2UoL1xuL2csICfihrUnKQogICAgICAgICAgICAucmVwbGFjZSgvXHQvZywgJ+KHpScpCiAg
ICAgICAgICAgIC5yZXBsYWNlKC9cci9nLCAnJyk7CiAgICB9CiAgICBmdW5jdGlvbiBzZXBEaXNwbGF5
TmFtZShyYXcpIHsKICAgICAgICBjb25zdCBzID0gbm9ybWFsaXplU2VwSW5wdXQocmF3KTsKICAgICAg
ICBpZiAocyA9PT0gJyAnKSByZXR1cm4gJ+epuuagvCc7CiAgICAgICAgaWYgKHMgPT09IFNFUF9ORVdM
SU5FX1RPS0VOIHx8IHMgPT09ICdcbicgfHwgcyA9PT0gJ1xyXG4nKSByZXR1cm4gJ+aNouihjCc7CiAg
ICAgICAgaWYgKHMgPT09ICdcdCcpIHJldHVybiAn5Yi26KGo56ymJzsKICAgICAgICBpZiAocyA9PT0g
JywnKSByZXR1cm4gJ+mAl+WPtyc7CiAgICAgICAgaWYgKHMgPT09ICcsICcpIHJldHVybiAn6YCX5Y+3
56m65qC8JzsKICAgICAgICBpZiAocyA9PT0gJ+OAgScpIHJldHVybiAn6aG/5Y+3JzsKICAgICAgICBp
ZiAocyA9PT0gJ3wnKSByZXR1cm4gJ+erlue6vyc7CiAgICAgICAgcmV0dXJuICcnOwogICAgfQogICAg
ZnVuY3Rpb24gc2VwRGlzcGxheUxhYmVsKHJhdykgewogICAgICAgIHJldHVybiBzZXBEaXNwbGF5U3lt
Ym9sKHJhdyk7CiAgICB9CiAgICBmdW5jdGlvbiBmaWxsU2VwTWVudUl0ZW0oYnRuLCB2KSB7CiAgICAg
ICAgYnRuLmlubmVySFRNTCA9ICcnOwogICAgICAgIGNvbnN0IHN5bSA9IGRvY3VtZW50LmNyZWF0ZUVs
ZW1lbnQoJ3NwYW4nKTsKICAgICAgICBzeW0uY2xhc3NOYW1lID0gJ3Bhc3RlLXNlcC1zeW0nICsgKHNl
cERpc3BsYXlOYW1lKHYpID8gJycgOiAnIG9ubHknKTsKICAgICAgICBzeW0udGV4dENvbnRlbnQgPSBz
ZXBEaXNwbGF5U3ltYm9sKHYpOwogICAgICAgIGJ0bi5hcHBlbmRDaGlsZChzeW0pOwogICAgICAgIGNv
bnN0IG5hbWUgPSBzZXBEaXNwbGF5TmFtZSh2KTsKICAgICAgICBpZiAobmFtZSkgewogICAgICAgICAg
ICBjb25zdCBsYWIgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdzcGFuJyk7CiAgICAgICAgICAgIGxh
Yi5jbGFzc05hbWUgPSAncGFzdGUtc2VwLW5hbWUnOwogICAgICAgICAgICBsYWIudGV4dENvbnRlbnQg
PSBuYW1lOwogICAgICAgICAgICBidG4uYXBwZW5kQ2hpbGQobGFiKTsKICAgICAgICB9CiAgICB9CiAg
ICBmdW5jdGlvbiBsb2FkU2VwTGlzdCgpIHsKICAgICAgICByZXR1cm4gU0VQX0xJU1Quc2xpY2UoKTsK
ICAgIH0KICAgIGZ1bmN0aW9uIHVwZGF0ZVNlcExhYmVsKCkgewogICAgICAgIGNvbnN0IGxhYiA9IGRv
Y3VtZW50LmdldEVsZW1lbnRCeUlkKCdwYXN0ZS1zZXAtbGFiZWwnKTsKICAgICAgICBpZiAobGFiKSBs
YWIudGV4dENvbnRlbnQgPSBzZXBEaXNwbGF5TGFiZWwocGFzdGVTZXBWYWx1ZSk7CiAgICB9CiAgICBm
dW5jdGlvbiBhcHBseVNlcGFyYXRvcihyYXcsIG9wdHMgPSB7fSkgewogICAgICAgIGNvbnN0IGRvUGFz
dGUgPSBvcHRzLnBhc3RlICE9IG51bGwgPyBvcHRzLnBhc3RlIDogbXVsdGlJZHMubGVuZ3RoID4gMDsK
ICAgICAgICBwYXN0ZVNlcFZhbHVlID0gbm9ybWFsaXplU2VwSW5wdXQocmF3KTsKICAgICAgICB1cGRh
dGVTZXBMYWJlbCgpOwogICAgICAgIGNsb3NlU2VwTWVudSgpOwogICAgICAgIGlmIChkb1Bhc3RlKSBw
YXN0ZU11bHRpU2VsZWN0aW9uKCk7CiAgICB9CiAgICBmdW5jdGlvbiBjbG9zZVNlcE1lbnUoKSB7CiAg
ICAgICAgY29uc3QgbWVudSA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdwYXN0ZS1zZXAtbWVudScp
OwogICAgICAgIGNvbnN0IGJ0biA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdwYXN0ZS1zZXAtYnRu
Jyk7CiAgICAgICAgaWYgKG1lbnUpIG1lbnUuY2xhc3NMaXN0LnJlbW92ZSgnb24nKTsKICAgICAgICBp
ZiAoYnRuKSBidG4uY2xhc3NMaXN0LnJlbW92ZSgnb3BlbicpOwogICAgfQogICAgZnVuY3Rpb24gcmVu
ZGVyU2VwTWVudSgpIHsKICAgICAgICBjb25zdCBtZW51ID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQo
J3Bhc3RlLXNlcC1tZW51Jyk7CiAgICAgICAgaWYgKCFtZW51KSByZXR1cm47CiAgICAgICAgbWVudS5p
bm5lckhUTUwgPSAnJzsKICAgICAgICBmb3IgKGNvbnN0IHYgb2YgbG9hZFNlcExpc3QoKSkgewogICAg
ICAgICAgICBjb25zdCBiID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnYnV0dG9uJyk7CiAgICAgICAg
ICAgIGIudHlwZSA9ICdidXR0b24nOwogICAgICAgICAgICBiLmNsYXNzTmFtZSA9ICdwYXN0ZS1zZXAt
aXRlbScgKyAodiA9PT0gcGFzdGVTZXBWYWx1ZSA/ICcgc2VsJyA6ICcnKTsKICAgICAgICAgICAgZmls
bFNlcE1lbnVJdGVtKGIsIHYpOwogICAgICAgICAgICBiLm9uY2xpY2sgPSBlID0+IHsKICAgICAgICAg
ICAgICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAgICAgICAgICAgICBhcHBseVNlcGFyYXRvcih2
KTsKICAgICAgICAgICAgfTsKICAgICAgICAgICAgbWVudS5hcHBlbmRDaGlsZChiKTsKICAgICAgICB9
CiAgICAgICAgY29uc3QgZm9vdCA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOwogICAgICAg
IGZvb3QuY2xhc3NOYW1lID0gJ3Bhc3RlLXNlcC1mb290JzsKICAgICAgICBjb25zdCBpbnAgPSBkb2N1
bWVudC5jcmVhdGVFbGVtZW50KCdpbnB1dCcpOwogICAgICAgIGlucC5pZCA9ICdwYXN0ZS1zZXAtY3Vz
dG9tJzsKICAgICAgICBpbnAudHlwZSA9ICd0ZXh0JzsKICAgICAgICBpbnAucGxhY2Vob2xkZXIgPSAn
6Ieq5a6a5LmJ4oCmIFvmjaLooYxdJzsKICAgICAgICBpbnAuYXV0b2NvbXBsZXRlID0gJ29mZic7CiAg
ICAgICAgaW5wLnNwZWxsY2hlY2sgPSBmYWxzZTsKICAgICAgICBpbnAudmFsdWUgPSBsb2FkU2VwTGlz
dCgpLmluY2x1ZGVzKHBhc3RlU2VwVmFsdWUpID8gJycgOiBwYXN0ZVNlcFZhbHVlOwogICAgICAgIGlu
cC5vbm1vdXNlZG93biA9IGUgPT4gewogICAgICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAg
ICAgICAgICBlLnByZXZlbnREZWZhdWx0KCk7CiAgICAgICAgICAgIHRyeSB7IGFoaygnZm9jdXNQYW5l
bCcpOyB9IGNhdGNoIHt9CiAgICAgICAgICAgIGlucC5mb2N1cygpOwogICAgICAgIH07CiAgICAgICAg
aW5wLm9uY2xpY2sgPSBlID0+IGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAgICAgaW5wLm9uZm9jdXMg
PSAoKSA9PiB7IHRyeSB7IGFoaygnZm9jdXNQYW5lbCcpOyB9IGNhdGNoIHt9IH07CiAgICAgICAgaW5w
Lm9uaW5wdXQgPSBlID0+IGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAgICAgaW5wLm9ua2V5ZG93biA9
IGUgPT4gewogICAgICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgICAgICAgICBpZiAoZS5r
ZXkgPT09ICdFbnRlcicpIHsKICAgICAgICAgICAgICAgIGUucHJldmVudERlZmF1bHQoKTsKICAgICAg
ICAgICAgICAgIGlmIChpbnAudmFsdWUgIT09ICcnKSBhcHBseVNlcGFyYXRvcihpbnAudmFsdWUpOwog
ICAgICAgICAgICAgICAgZWxzZSBjbG9zZVNlcE1lbnUoKTsKICAgICAgICAgICAgfSBlbHNlIGlmIChl
LmtleSA9PT0gJ0VzY2FwZScpIHsKICAgICAgICAgICAgICAgIGUucHJldmVudERlZmF1bHQoKTsKICAg
ICAgICAgICAgICAgIGNsb3NlU2VwTWVudSgpOwogICAgICAgICAgICB9CiAgICAgICAgfTsKICAgICAg
ICBmb290LmFwcGVuZENoaWxkKGlucCk7CiAgICAgICAgbWVudS5hcHBlbmRDaGlsZChmb290KTsKICAg
IH0KICAgIGZ1bmN0aW9uIHJlc2V0UGFzdGVTZXBEZWZhdWx0KCkgewogICAgICAgIHBhc3RlU2VwVmFs
dWUgPSAnICc7CiAgICAgICAgdXBkYXRlU2VwTGFiZWwoKTsKICAgICAgICBjbG9zZVNlcE1lbnUoKTsK
ICAgIH0KICAgIGZ1bmN0aW9uIGdldFBhc3RlU2VwQWN0dWFsKCkgewogICAgICAgIHJldHVybiBzZXBU
b0FjdHVhbChwYXN0ZVNlcFZhbHVlKTsKICAgIH0KICAgIGZ1bmN0aW9uIHBhc3RlTWFueVdpdGhTZXAo
aWRzLCByZW1lbWJlciA9IHRydWUpIHsKICAgICAgICBhaGsoJ3Bhc3RlTWFueScsIGlkcy5qb2luKCcs
JyksIHNlcFRvQnJpZGdlKHBhc3RlU2VwVmFsdWUpKTsKICAgIH0KICAgIGZ1bmN0aW9uIGluaXRTZXBV
aSgpIHsKICAgICAgICB1cGRhdGVTZXBMYWJlbCgpOwogICAgICAgIHJlbmRlclNlcE1lbnUoKTsKICAg
ICAgICBjb25zdCBidG4gPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgncGFzdGUtc2VwLWJ0bicpOwog
ICAgICAgIGlmIChidG4pIHsKICAgICAgICAgICAgYnRuLmFkZEV2ZW50TGlzdGVuZXIoJ2NsaWNrJywg
ZSA9PiB7CiAgICAgICAgICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgICAgICAgICAgICAg
Y29uc3QgbWVudSA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdwYXN0ZS1zZXAtbWVudScpOwogICAg
ICAgICAgICAgICAgY29uc3Qgb3BlbiA9IG1lbnUgJiYgbWVudS5jbGFzc0xpc3QuY29udGFpbnMoJ29u
Jyk7CiAgICAgICAgICAgICAgICBpZiAob3BlbikgewogICAgICAgICAgICAgICAgICAgIGNvbnN0IGlu
cCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdwYXN0ZS1zZXAtY3VzdG9tJyk7CiAgICAgICAgICAg
ICAgICAgICAgaWYgKGlucCAmJiBpbnAudmFsdWUgIT09ICcnKSBhcHBseVNlcGFyYXRvcihpbnAudmFs
dWUsIHsgcGFzdGU6IG11bHRpSWRzLmxlbmd0aCA+IDAgfSk7CiAgICAgICAgICAgICAgICAgICAgZWxz
ZSBjbG9zZVNlcE1lbnUoKTsKICAgICAgICAgICAgICAgICAgICByZXR1cm47CiAgICAgICAgICAgICAg
ICB9CiAgICAgICAgICAgICAgICByZW5kZXJTZXBNZW51KCk7CiAgICAgICAgICAgICAgICBtZW51LmNs
YXNzTGlzdC5hZGQoJ29uJyk7CiAgICAgICAgICAgICAgICBidG4uY2xhc3NMaXN0LmFkZCgnb3Blbicp
OwogICAgICAgICAgICB9KTsKICAgICAgICB9CiAgICAgICAgZG9jdW1lbnQuYWRkRXZlbnRMaXN0ZW5l
cignbW91c2Vkb3duJywgZSA9PiB7CiAgICAgICAgICAgIGlmIChlLnRhcmdldC5jbG9zZXN0KCcjcGFz
dGUtc2VwLXdyYXAnKSkgcmV0dXJuOwogICAgICAgICAgICBjb25zdCBtZW51ID0gZG9jdW1lbnQuZ2V0
RWxlbWVudEJ5SWQoJ3Bhc3RlLXNlcC1tZW51Jyk7CiAgICAgICAgICAgIGlmICghbWVudSB8fCAhbWVu
dS5jbGFzc0xpc3QuY29udGFpbnMoJ29uJykpIHJldHVybjsKICAgICAgICAgICAgY29uc3QgaW5wID0g
ZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3Bhc3RlLXNlcC1jdXN0b20nKTsKICAgICAgICAgICAgaWYg
KGlucCAmJiBpbnAudmFsdWUgIT09ICcnKSB7CiAgICAgICAgICAgICAgICBhcHBseVNlcGFyYXRvcihp
bnAudmFsdWUpOwogICAgICAgICAgICAgICAgcmV0dXJuOwogICAgICAgICAgICB9CiAgICAgICAgICAg
IGNsb3NlU2VwTWVudSgpOwogICAgICAgIH0sIHRydWUpOwogICAgfQoKICAgIGZ1bmN0aW9uIGFoa1Jl
dChtZXRob2QsIC4uLmFyZ3MpIHsKICAgICAgICB0cnkgewogICAgICAgICAgICBjb25zdCBob3N0ID0g
Y2hyb21lLndlYnZpZXcuaG9zdE9iamVjdHMuc3luYy5haGs7CiAgICAgICAgICAgIGlmICghaG9zdCkg
cmV0dXJuIG51bGw7CiAgICAgICAgICAgIGxldCByZXQgPSBudWxsOwogICAgICAgICAgICBpZiAodHlw
ZW9mIGhvc3QuY2FsbCA9PT0gJ2Z1bmN0aW9uJykgewogICAgICAgICAgICAgICAgdHJ5IHsgcmV0ID0g
aG9zdC5jYWxsKG1ldGhvZCwgLi4uYXJncyk7IH0gY2F0Y2gge30KICAgICAgICAgICAgfQogICAgICAg
ICAgICBpZiAocmV0ID09IG51bGwgJiYgdHlwZW9mIGhvc3RbbWV0aG9kXSA9PT0gJ2Z1bmN0aW9uJykg
ewogICAgICAgICAgICAgICAgdHJ5IHsgcmV0ID0gaG9zdFttZXRob2RdKC4uLmFyZ3MpOyB9IGNhdGNo
IHt9CiAgICAgICAgICAgICAgICBpZiAocmV0ID09IG51bGwpIHsKICAgICAgICAgICAgICAgICAgICB0
cnkgeyByZXQgPSBob3N0W21ldGhvZF0oLi4uYXJncyk7IH0gY2F0Y2gge30KICAgICAgICAgICAgICAg
IH0KICAgICAgICAgICAgfQogICAgICAgICAgICBpZiAocmV0ID09IG51bGwgJiYgaG9zdFttZXRob2Rd
ICE9IG51bGwgJiYgdHlwZW9mIGhvc3RbbWV0aG9kXSAhPT0gJ2Z1bmN0aW9uJykKICAgICAgICAgICAg
ICAgIHJldCA9IGhvc3RbbWV0aG9kXTsKICAgICAgICAgICAgaWYgKHJldCA9PSBudWxsKSByZXR1cm4g
bnVsbDsKICAgICAgICAgICAgaWYgKHR5cGVvZiByZXQgPT09ICdzdHJpbmcnIHx8IHR5cGVvZiByZXQg
PT09ICdudW1iZXInIHx8IHR5cGVvZiByZXQgPT09ICdib29sZWFuJykKICAgICAgICAgICAgICAgIHJl
dHVybiByZXQ7CiAgICAgICAgICAgIHRyeSB7IHJldHVybiBTdHJpbmcocmV0KTsgfSBjYXRjaCB7IHJl
dHVybiByZXQ7IH0KICAgICAgICB9IGNhdGNoIChlKSB7IGNvbnNvbGUud2FybignYWhrUmV0LicgKyBt
ZXRob2QsIGUpOyB9CiAgICAgICAgcmV0dXJuIG51bGw7CiAgICB9CgogICAgLy8gRWFybHkgQUhLIF9f
c2V0VGh1bWIgY2FuIGFycml2ZSBiZWZvcmUgRE9NIG5vZGVzIGV4aXN0IOKAlCBrZWVwIHVudGlsIGJp
bmQKICAgIGNvbnN0IHRodW1iQ2FjaGUgPSBuZXcgTWFwKCk7CgogICAgLyoqIFByZWZlciBjYWNoZSAv
IGRhdGEtVVJMLCB0aGVuIHRoXyouanBnIHZpYSB2aXJ0dWFsIGhvc3QsIHRoZW4gb3JpZ2luYWwgKi8K
ICAgIGZ1bmN0aW9uIGJpbmRTdG9yZVRodW1iKGltZywgZmlsZSwgaWQsIGZhbGxiYWNrKSB7CiAgICAg
ICAgaW1nLmRhdGFzZXQudGh1bWJJZCA9IFN0cmluZyhpZCk7CiAgICAgICAgaW1nLmFsdCA9ICcnOwog
ICAgICAgIGltZy5jbGFzc0xpc3QuYWRkKCd0aHVtYi1sb2FkaW5nJyk7CiAgICAgICAgY29uc3Qgd3Jh
cCA9IGltZy5wYXJlbnRFbGVtZW50OwogICAgICAgIGlmICh3cmFwICYmIHdyYXAuY2xhc3NMaXN0LmNv
bnRhaW5zKCdpLXRodW1iLXdyYXAnKSkKICAgICAgICAgICAgd3JhcC5jbGFzc0xpc3QuYWRkKCd3YWl0
aW5nJyk7CiAgICAgICAgY29uc3QgY2xlYXJXYWl0ID0gKCkgPT4gewogICAgICAgICAgICBpbWcuY2xh
c3NMaXN0LnJlbW92ZSgndGh1bWItbG9hZGluZycpOwogICAgICAgICAgICBpZiAod3JhcCkgd3JhcC5j
bGFzc0xpc3QucmVtb3ZlKCd3YWl0aW5nJyk7CiAgICAgICAgICAgIGlmIChpbWcuX2ZhaWxUaW1lcikg
dHJ5IHsgY2xlYXJUaW1lb3V0KGltZy5fZmFpbFRpbWVyKTsgfSBjYXRjaCB7fQogICAgICAgIH07CiAg
ICAgICAgY29uc3QgZmFpbFRpbWVyID0gc2V0VGltZW91dCgoKSA9PiB7CiAgICAgICAgICAgIGlmICgh
aW1nLnNyYyB8fCBpbWcubmF0dXJhbFdpZHRoIDwgMSkKICAgICAgICAgICAgICAgIGltZy5hbHQgPSAn
5peg5rOV5Yqg6L29JzsKICAgICAgICAgICAgY2xlYXJXYWl0KCk7CiAgICAgICAgfSwgMTIwMDApOwog
ICAgICAgIGltZy5fZmFpbFRpbWVyID0gZmFpbFRpbWVyOwogICAgICAgIGNvbnN0IHByZXZMb2FkID0g
aW1nLm9ubG9hZDsKICAgICAgICBpbWcub25sb2FkID0gZSA9PiB7CiAgICAgICAgICAgIGNsZWFyV2Fp
dCgpOwogICAgICAgICAgICBpbWcuYWx0ID0gJyc7CiAgICAgICAgICAgIGlmICh0eXBlb2YgcHJldkxv
YWQgPT09ICdmdW5jdGlvbicpIHByZXZMb2FkLmNhbGwoaW1nLCBlKTsKICAgICAgICB9OwogICAgICAg
IGNvbnN0IGJhcmUgPSBmaWxlID8gU3RyaW5nKGZpbGUpLnNwbGl0KC9bXFwvXS8pLnBvcCgpIDogJyc7
CiAgICAgICAgY29uc3QgdGhOYW1lID0gYmFyZSA/ICgndGhfJyArIGJhcmUucmVwbGFjZSgvXC5bXi5d
KyQvLCAnJykgKyAnLmpwZycpIDogJyc7CiAgICAgICAgaW1nLm9uZXJyb3IgPSAoKSA9PiB7CiAgICAg
ICAgICAgIGNvbnN0IHN0ZXAgPSBOdW1iZXIoaW1nLmRhdGFzZXQuc3RlcCB8fCAwKTsKICAgICAgICAg
ICAgaWYgKHN0ZXAgPCAyICYmIGJhcmUpIHsKICAgICAgICAgICAgICAgIGltZy5kYXRhc2V0LnN0ZXAg
PSAnMic7CiAgICAgICAgICAgICAgICBpbWcuc3JjID0gU1RPUkVfQkFTRSArIGVuY29kZVVSSUNvbXBv
bmVudChiYXJlKTsKICAgICAgICAgICAgICAgIHJldHVybjsKICAgICAgICAgICAgfQogICAgICAgICAg
ICBpZiAoc3RlcCA8IDMgJiYgKHRoTmFtZSB8fCBiYXJlKSkgewogICAgICAgICAgICAgICAgaW1nLmRh
dGFzZXQuc3RlcCA9ICczJzsKICAgICAgICAgICAgICAgIGltZy5zcmMgPSBTVE9SRV9CQVNFX0ZBTExC
QUNLICsgZW5jb2RlVVJJQ29tcG9uZW50KHRoTmFtZSB8fCBiYXJlKTsKICAgICAgICAgICAgICAgIHJl
dHVybjsKICAgICAgICAgICAgfQogICAgICAgICAgICBpZiAoc3RlcCA8IDQgJiYgYmFyZSAmJiB0aE5h
bWUpIHsKICAgICAgICAgICAgICAgIGltZy5kYXRhc2V0LnN0ZXAgPSAnNCc7CiAgICAgICAgICAgICAg
ICBpbWcuc3JjID0gU1RPUkVfQkFTRV9GQUxMQkFDSyArIGVuY29kZVVSSUNvbXBvbmVudChiYXJlKTsK
ICAgICAgICAgICAgICAgIHJldHVybjsKICAgICAgICAgICAgfQogICAgICAgICAgICAvLyBLZWVwIHNo
aW1tZXI7IEFISyBfX3NldFRodW1iIHdpbGwgZmlsbCBpbgogICAgICAgICAgICBpbWcucmVtb3ZlQXR0
cmlidXRlKCdzcmMnKTsKICAgICAgICAgICAgaW1nLmNsYXNzTGlzdC5hZGQoJ3RodW1iLWxvYWRpbmcn
KTsKICAgICAgICAgICAgaWYgKHdyYXApIHdyYXAuY2xhc3NMaXN0LmFkZCgnd2FpdGluZycpOwogICAg
ICAgIH07CiAgICAgICAgY29uc3QgY2FjaGVkID0gdGh1bWJDYWNoZS5nZXQoU3RyaW5nKGlkKSk7CiAg
ICAgICAgLy8gQWNjZXB0IGRhdGEtVVJMIG9yIGhvc3QgVVJMIGZyb20gcHJpb3IgX19zZXRUaHVtYiAo
cmUtcmVuZGVyIG11c3Qgbm90IGRyb3AgaXQpCiAgICAgICAgaWYgKGNhY2hlZCAmJiBTdHJpbmcoY2Fj
aGVkKS5sZW5ndGgpIHsKICAgICAgICAgICAgaW1nLmRhdGFzZXQuc3RlcCA9ICc5JzsKICAgICAgICAg
ICAgaW1nLnNyYyA9IFN0cmluZyhjYWNoZWQpOwogICAgICAgICAgICByZXR1cm47CiAgICAgICAgfQog
ICAgICAgIGNvbnN0IGRhdGFVcmwgPSAoZmFsbGJhY2sgJiYgU3RyaW5nKGZhbGxiYWNrKS5zdGFydHNX
aXRoKCdkYXRhOicpKQogICAgICAgICAgICA/IFN0cmluZyhmYWxsYmFjaykgOiAnJzsKICAgICAgICBp
ZiAoZGF0YVVybCkgewogICAgICAgICAgICBpbWcuZGF0YXNldC5zdGVwID0gJzknOwogICAgICAgICAg
ICBpbWcuc3JjID0gZGF0YVVybDsKICAgICAgICAgICAgcmV0dXJuOwogICAgICAgIH0KICAgICAgICBp
ZiAoYmFyZSkgewogICAgICAgICAgICAvLyBQcmVmZXIgbGlzdCB0aHVtYiBKUEVHIChzbWFsbCkgb24g
ZGVkaWNhdGVkIHN0b3JlIGhvc3QKICAgICAgICAgICAgaW1nLmRhdGFzZXQuc3RlcCA9ICcxJzsKICAg
ICAgICAgICAgaW1nLnNyYyA9IFNUT1JFX0JBU0UgKyBlbmNvZGVVUklDb21wb25lbnQodGhOYW1lIHx8
IGJhcmUpOwogICAgICAgIH0gZWxzZSB7CiAgICAgICAgICAgIC8vIE5vIGZpbGUgeWV0IChqdXN0IGNv
cGllZCkg4oCUa2VlcCBzaGltbWVyOyBJbmplY3RMaXZlSW1hZ2VUaHVtYiAvIF9fc2V0VGh1bWIgZmls
bHMgaW4KICAgICAgICAgICAgaW1nLmNsYXNzTGlzdC5hZGQoJ3RodW1iLWxvYWRpbmcnKTsKICAgICAg
ICAgICAgaWYgKHdyYXApIHdyYXAuY2xhc3NMaXN0LmFkZCgnd2FpdGluZycpOwogICAgICAgIH0KICAg
IH0KCiAgICB3aW5kb3cuX19zZXRUaHVtYiA9IChpZCwgdXJsKSA9PiB7CiAgICAgICAgaWYgKCF1cmwp
IHJldHVybjsKICAgICAgICBjb25zdCBrZXkgPSBTdHJpbmcoaWQpOwogICAgICAgIHRodW1iQ2FjaGUu
c2V0KGtleSwgdXJsKTsKICAgICAgICBjb25zdCBhcHBseSA9IGltZyA9PiB7CiAgICAgICAgICAgIGlm
IChpbWcuX2ZhaWxUaW1lcikgdHJ5IHsgY2xlYXJUaW1lb3V0KGltZy5fZmFpbFRpbWVyKTsgfSBjYXRj
aCB7fQogICAgICAgICAgICBpbWcub25lcnJvciA9IG51bGw7CiAgICAgICAgICAgIGltZy5hbHQgPSAn
JzsKICAgICAgICAgICAgaW1nLmNsYXNzTGlzdC5yZW1vdmUoJ3RodW1iLWxvYWRpbmcnKTsKICAgICAg
ICAgICAgY29uc3Qgd3JhcCA9IGltZy5wYXJlbnRFbGVtZW50OwogICAgICAgICAgICBpZiAod3JhcCkg
d3JhcC5jbGFzc0xpc3QucmVtb3ZlKCd3YWl0aW5nJyk7CiAgICAgICAgICAgIGltZy5zcmMgPSB1cmw7
CiAgICAgICAgfTsKICAgICAgICBsZXQgaGl0ID0gMDsKICAgICAgICBkb2N1bWVudC5xdWVyeVNlbGVj
dG9yQWxsKCcuaXRtW2RhdGEtaWQ9IicgKyBrZXkgKyAnIl0gaW1nLmktdGh1bWInKS5mb3JFYWNoKGlt
ZyA9PiB7CiAgICAgICAgICAgIGFwcGx5KGltZyk7IGhpdCsrOwogICAgICAgIH0pOwogICAgICAgIGlm
ICghaGl0KSB7CiAgICAgICAgICAgIGRvY3VtZW50LnF1ZXJ5U2VsZWN0b3JBbGwoJ2ltZy5pLXRodW1i
W2RhdGEtdGh1bWItaWQ9IicgKyBrZXkgKyAnIl0nKS5mb3JFYWNoKGFwcGx5KTsKICAgICAgICB9CiAg
ICB9OwoKICAgIGZ1bmN0aW9uIGlzRHJhZ0V4Y2x1ZGUodCkgewogICAgICAgIC8vIEluY2x1ZGUgI2xp
c3Qgc28gc2Nyb2xsYmFyIC8gbGlzdCBwYWRkaW5nIG5ldmVyIHN0ZWFscyB0aGUgZ2VzdHVyZSBpbnRv
IHN0YXJ0RHJhZwogICAgICAgIHJldHVybiAhIXQuY2xvc2VzdCgnI2xpc3QsICNzZWFyY2gtd3JhcCwg
I2J0bi1zZWFyY2gsICNidG4tbG9jYXRlLCAjYnRuLXRvZGF5LCAjYnRuLXBpbiwgI2J0bi1jbHIsICNt
dWx0aS1iYXIsICNtdWx0aS1jbnQsICNwYXN0ZS1zZXAtd3JhcCwgI3Bhc3RlLXNlcC1idG4sICNwYXN0
ZS1zZXAtbWVudSwgLnRhYiwgLml0bSwgI3RhYi1hY3Rpb25zLCAjY3R4LCAjY2xyLWRsZywgI3BhdGgt
dGlwLCBidXR0b24sIGlucHV0LCBhJyk7CiAgICB9CiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgn
YXBwJykuYWRkRXZlbnRMaXN0ZW5lcignbW91c2Vkb3duJywgZSA9PiB7CiAgICAgICAgaWYgKGUuYnV0
dG9uICE9PSAwKSByZXR1cm47CiAgICAgICAgaWYgKGlzRHJhZ0V4Y2x1ZGUoZS50YXJnZXQpKSByZXR1
cm47CiAgICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOwogICAgICAgIC8vIE1VU1QgYmUgc3luYyBob3N0
ICsgUG9zdE1lc3NhZ2UgaW4gdGhlIHNhbWUgZ2VzdHVyZSDigJQgYXN5bmMgYnJlYWtzIHdpbmRvdyBk
cmFnCiAgICAgICAgYWhrKCdzdGFydERyYWcnKTsKICAgIH0sIHRydWUpOwoKICAgIGNvbnN0IGlzVXJs
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
fCB0ID09PSAnZGlyJykgcmV0dXJuICdyZWNlbnQnOwogICAgICAgIHJldHVybiAndGV4dCc7CiAgICB9
CiAgICBmdW5jdGlvbiBpc1Bpbm5lZChjKSB7CiAgICAgICAgcmV0dXJuIGMucGlubmVkID09PSB0cnVl
IHx8IGMucGlubmVkID09PSAxIHx8IGMucGlubmVkID09PSAndHJ1ZScgfHwgYy5waW5uZWQgPT09ICcx
JzsKICAgIH0KICAgIGZ1bmN0aW9uIGlzUGFzdGVkKGMpIHsKICAgICAgICByZXR1cm4gYy5wYXN0ZWQg
PT09IHRydWUgfHwgYy5wYXN0ZWQgPT09IDEgfHwgYy5wYXN0ZWQgPT09ICd0cnVlJyB8fCBjLnBhc3Rl
ZCA9PT0gJzEnOwogICAgfQoKICAgIGZ1bmN0aW9uIGlzTWFya2Rvd24odGV4dCkgewogICAgICAgIGlm
ICghdGV4dCB8fCB0ZXh0Lmxlbmd0aCA8IDQpIHJldHVybiBmYWxzZTsKICAgICAgICByZXR1cm4gLyg/
Ol58XG4pI3sxLDZ9IHxeWy0qK10gfFwqXCpbXipcbl0rXCpcKnxfX1teX1xuXStfX3woPzpefFxuKT4g
fGBgYHxgW15gXG5dK2B8XFtbXlxdXStcXVwoW14pXStcKXxcfC4rXHwuK1x8L20udGVzdCh0ZXh0KTsK
ICAgIH0KICAgIGZ1bmN0aW9uIGNsaXBVc2VzTUljb24oYykgewogICAgICAgIGlmICghYykgcmV0dXJu
IGZhbHNlOwogICAgICAgIGlmIChjLmlzTWQgPT09IHRydWUgfHwgYy5pc01kID09PSAxIHx8IGMuaXNN
ZCA9PT0gJ3RydWUnIHx8IGMuaXNNZCA9PT0gJzEnKSByZXR1cm4gdHJ1ZTsKICAgICAgICBpZiAoYy5p
c1JpY2ggPT09IHRydWUgfHwgYy5pc1JpY2ggPT09IDEgfHwgYy5pc1JpY2ggPT09ICd0cnVlJyB8fCBj
LmlzUmljaCA9PT0gJzEnKSByZXR1cm4gdHJ1ZTsKICAgICAgICBjb25zdCB0ID0gU3RyaW5nKGMudHlw
ZSB8fCAnJykudG9Mb3dlckNhc2UoKTsKICAgICAgICBpZiAodCAmJiB0ICE9PSAndGV4dCcgJiYgdCAh
PT0gJ2xpbmsnKSByZXR1cm4gZmFsc2U7CiAgICAgICAgcmV0dXJuIGlzTWFya2Rvd24oYy5kYXRhIHx8
IGMucHJldmlldyB8fCAnJyk7CiAgICB9CiAgICBmdW5jdGlvbiBlc2NBdHRyKHMpIHsKICAgICAgICBy
ZXR1cm4gU3RyaW5nKHMgfHwgJycpCiAgICAgICAgICAgIC5yZXBsYWNlKC8mL2csICcmYW1wOycpCiAg
ICAgICAgICAgIC5yZXBsYWNlKC8iL2csICcmcXVvdDsnKQogICAgICAgICAgICAucmVwbGFjZSgvPC9n
LCAnJmx0OycpCiAgICAgICAgICAgIC5yZXBsYWNlKC8+L2csICcmZ3Q7Jyk7CiAgICB9CgogICAgZnVu
Y3Rpb24gdG9kYXlQcmVmaXgoKSB7CiAgICAgICAgY29uc3QgZCA9IG5ldyBEYXRlKCk7CiAgICAgICAg
Y29uc3QgcCA9IG4gPT4gU3RyaW5nKG4pLnBhZFN0YXJ0KDIsICcwJyk7CiAgICAgICAgcmV0dXJuIGQu
Z2V0RnVsbFllYXIoKSArICctJyArIHAoZC5nZXRNb250aCgpICsgMSkgKyAnLScgKyBwKGQuZ2V0RGF0
ZSgpKTsKICAgIH0KICAgIGZ1bmN0aW9uIGlzVG9kYXlDbGlwKGMpIHsKICAgICAgICByZXR1cm4gU3Ry
aW5nKGMudGltZSB8fCAnJykuc3RhcnRzV2l0aCh0b2RheVByZWZpeCgpKTsKICAgIH0KCiAgICBmdW5j
dGlvbiBjbGlwSGF5KGMpIHsKICAgICAgICByZXR1cm4gU3RyaW5nKGMucHJldmlldyB8fCAnJykgKyAn
ICcgKyBTdHJpbmcoYy5kYXRhIHx8ICcnKSArICcgJwogICAgICAgICAgICArIFN0cmluZyhjLmxpbmtU
aXRsZSB8fCAnJykgKyAnICcgKyBTdHJpbmcoYy5mYXZUaXRsZSB8fCAnJyk7CiAgICB9CiAgICAvKiog
TWF0Y2ggQUhLIEl0ZW1NYXRjaGVzVmlldyBsaXN0IHNlYXJjaCDigJQgcHJldmlldyAoKyBzaG9ydCBi
b2R5IGZhbGxiYWNrKSwgbm90IGZ1bGwgZGF0YSAqLwogICAgZnVuY3Rpb24gY2xpcFNlYXJjaEhheShj
KSB7CiAgICAgICAgY29uc3QgdHlwZSA9IFN0cmluZyhjLnR5cGUgfHwgJycpLnRvTG93ZXJDYXNlKCk7
CiAgICAgICAgaWYgKHR5cGUgPT09ICdpbWFnZScpCiAgICAgICAgICAgIHJldHVybiBTdHJpbmcoYy5m
YXZUaXRsZSB8fCAnJyk7CiAgICAgICAgaWYgKHR5cGUgPT09ICdyZWNlbnQnIHx8IHR5cGUgPT09ICdm
b2xkZXInIHx8IHR5cGUgPT09ICdkaXInKSB7CiAgICAgICAgICAgIHJldHVybiBTdHJpbmcoYy5wcmV2
aWV3IHx8ICcnKSArICcgJyArIFN0cmluZyhjLmRhdGEgfHwgJycpICsgJyAnCiAgICAgICAgICAgICAg
ICArIFN0cmluZyhjLmZhdlRpdGxlIHx8ICcnKTsKICAgICAgICB9CiAgICAgICAgaWYgKHR5cGUgPT09
ICdmaWxlJykgewogICAgICAgICAgICByZXR1cm4gU3RyaW5nKGMucHJldmlldyB8fCAnJykgKyAnICcg
KyBTdHJpbmcoYy5kYXRhIHx8ICcnKSArICcgJwogICAgICAgICAgICAgICAgKyBTdHJpbmcoYy5mYXZU
aXRsZSB8fCAnJyk7CiAgICAgICAgfQogICAgICAgIGxldCBwcmV2ID0gU3RyaW5nKGMucHJldmlldyB8
fCAnJyk7CiAgICAgICAgaWYgKCFwcmV2ICYmIGMuZGF0YSkKICAgICAgICAgICAgcHJldiA9IFN0cmlu
ZyhjLmRhdGEpLnNsaWNlKDAsIDUwMCk7CiAgICAgICAgcmV0dXJuIHByZXYgKyAnICcgKyBTdHJpbmco
Yy5saW5rVGl0bGUgfHwgJycpICsgJyAnICsgU3RyaW5nKGMuZmF2VGl0bGUgfHwgJycpOwogICAgfQog
ICAgZnVuY3Rpb24gY2xpcE1hdGNoZXNTZWFyY2goYywgdGVybUwpIHsKICAgICAgICBjb25zdCB0eXBl
ID0gU3RyaW5nKGMudHlwZSB8fCAnJykudG9Mb3dlckNhc2UoKTsKICAgICAgICBjb25zdCBoYXkgPSAo
dHlwZSA9PT0gJ2ltYWdlJyA/IFN0cmluZyhjLmZhdlRpdGxlIHx8ICcnKSA6IGNsaXBTZWFyY2hIYXko
YykpLnRvTG93ZXJDYXNlKCk7CiAgICAgICAgcmV0dXJuIHRlcm1MLmV2ZXJ5KHQgPT4gaGF5LmluY2x1
ZGVzKHQpKTsKICAgIH0KICAgIGZ1bmN0aW9uIGZpbHRlcihjbGlwcywgdGFiLCBxKSB7CiAgICAgICAg
Ly8g5Li75py65bey6L+H5ruk5pe25LuN5YGa5YmN56uv5YWc5bqV77ya6YG/5YWN56ue5oCB5o6o5p2l
5pyq5ZG95Lit6KGMCiAgICAgICAgY29uc3QgdGVybXMgPSBxdWVyeVRlcm1zKHEpOwogICAgICAgIGlm
ICghdGVybXMubGVuZ3RoKSByZXR1cm4gY2xpcHM7CiAgICAgICAgY29uc3QgdGVybUwgPSB0ZXJtcy5t
YXAodCA9PiB0LnRvTG93ZXJDYXNlKCkpOwogICAgICAgIGNvbnN0IG1hdGNoZWRHcm91cHMgPSBuZXcg
U2V0KCk7CiAgICAgICAgZm9yIChjb25zdCBjIG9mIGNsaXBzKSB7CiAgICAgICAgICAgIGlmICghY2xp
cE1hdGNoZXNTZWFyY2goYywgdGVybUwpKSBjb250aW51ZTsKICAgICAgICAgICAgY29uc3QgZ2lkID0g
U3RyaW5nKGMgJiYgYy5mYXZHcm91cCB8fCAnJykudHJpbSgpOwogICAgICAgICAgICBpZiAoZ2lkKSBt
YXRjaGVkR3JvdXBzLmFkZChnaWQpOwogICAgICAgIH0KICAgICAgICAvLyDlkIjlubbnu4TvvJrlhbPp
lK7lrZflj6/og73liIbmlaPlnKjkuI3lkIzooYzvvIjmoIfpopgv5q2j5paH77yJCiAgICAgICAgY29u
c3QgYnlHcm91cCA9IG5ldyBNYXAoKTsKICAgICAgICBmb3IgKGNvbnN0IGMgb2YgY2xpcHMpIHsKICAg
ICAgICAgICAgY29uc3QgZ2lkID0gU3RyaW5nKGMgJiYgYy5mYXZHcm91cCB8fCAnJykudHJpbSgpOwog
ICAgICAgICAgICBpZiAoIWdpZCkgY29udGludWU7CiAgICAgICAgICAgIGlmICghYnlHcm91cC5oYXMo
Z2lkKSkgYnlHcm91cC5zZXQoZ2lkLCBbXSk7CiAgICAgICAgICAgIGJ5R3JvdXAuZ2V0KGdpZCkucHVz
aChjKTsKICAgICAgICB9CiAgICAgICAgZm9yIChjb25zdCBbZ2lkLCBtZW1iZXJzXSBvZiBieUdyb3Vw
KSB7CiAgICAgICAgICAgIGlmIChtYXRjaGVkR3JvdXBzLmhhcyhnaWQpKSBjb250aW51ZTsKICAgICAg
ICAgICAgY29uc3QgdW5pb24gPSBtZW1iZXJzLm1hcChjID0+IHsKICAgICAgICAgICAgICAgIGNvbnN0
IHR5cGUgPSBTdHJpbmcoYy50eXBlIHx8ICcnKS50b0xvd2VyQ2FzZSgpOwogICAgICAgICAgICAgICAg
cmV0dXJuICh0eXBlID09PSAnaW1hZ2UnID8gU3RyaW5nKGMuZmF2VGl0bGUgfHwgJycpIDogY2xpcFNl
YXJjaEhheShjKSkudG9Mb3dlckNhc2UoKTsKICAgICAgICAgICAgfSkuam9pbignICcpOwogICAgICAg
ICAgICBpZiAodGVybUwuZXZlcnkodCA9PiB1bmlvbi5pbmNsdWRlcyh0KSkpCiAgICAgICAgICAgICAg
ICBtYXRjaGVkR3JvdXBzLmFkZChnaWQpOwogICAgICAgIH0KICAgICAgICByZXR1cm4gY2xpcHMuZmls
dGVyKGMgPT4gewogICAgICAgICAgICBpZiAoY2xpcE1hdGNoZXNTZWFyY2goYywgdGVybUwpKSByZXR1
cm4gdHJ1ZTsKICAgICAgICAgICAgY29uc3QgZ2lkID0gU3RyaW5nKGMgJiYgYy5mYXZHcm91cCB8fCAn
JykudHJpbSgpOwogICAgICAgICAgICByZXR1cm4gZ2lkICYmIG1hdGNoZWRHcm91cHMuaGFzKGdpZCk7
CiAgICAgICAgfSk7CiAgICB9CgogICAgZnVuY3Rpb24gbWFya1Bhc3RlZExvY2FsKGlkcykgewogICAg
ICAgIGNvbnN0IGxpc3QgPSBBcnJheS5pc0FycmF5KGlkcykgPyBpZHMgOiBbaWRzXTsKICAgICAgICBp
ZiAobGlzdC5sZW5ndGgpCiAgICAgICAgICAgIHJlbWVtYmVyTGFzdFBhc3RlKGxpc3RbbGlzdC5sZW5n
dGggLSAxXSk7CiAgICAgICAgY29uc3QgYmFkZ2VIdG1sID0gYDxzdmcgdmlld0JveD0iMCAwIDE2IDE2
IiBmaWxsPSJub25lIiBzdHJva2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIyLjQiIHN0cm9r
ZS1saW5lY2FwPSJyb3VuZCIgc3Ryb2tlLWxpbmVqb2luPSJyb3VuZCI+PHBvbHlsaW5lIHBvaW50cz0i
My41IDguNSA2LjUgMTEuNSAxMi41IDQuNSIvPjwvc3ZnPmA7CiAgICAgICAgbGlzdC5mb3JFYWNoKGlk
ID0+IHsKICAgICAgICAgICAgY29uc3QgYyA9IGFsbENsaXBzLmZpbmQoeCA9PiAreC5pZCA9PT0gK2lk
KTsKICAgICAgICAgICAgaWYgKGMpIGMucGFzdGVkID0gdHJ1ZTsKICAgICAgICAgICAgY29uc3QgaWNv
ID0gbGlzdEVsLnF1ZXJ5U2VsZWN0b3IoJy5pdG1bZGF0YS1pZD0iJyArIGlkICsgJyJdIC5pLWljbycp
OwogICAgICAgICAgICBpZiAoaWNvICYmICFpY28ucXVlcnlTZWxlY3RvcignLmktdXNlZCcpKSB7CiAg
ICAgICAgICAgICAgICBjb25zdCBiYWRnZSA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ3NwYW4nKTsK
ICAgICAgICAgICAgICAgIGJhZGdlLmNsYXNzTmFtZSA9ICdpLXVzZWQnOwogICAgICAgICAgICAgICAg
YmFkZ2UudGl0bGUgPSAn5bey57KY6LS0JzsKICAgICAgICAgICAgICAgIGJhZGdlLmlubmVySFRNTCA9
IGJhZGdlSHRtbDsKICAgICAgICAgICAgICAgIGljby5hcHBlbmRDaGlsZChiYWRnZSk7CiAgICAgICAg
ICAgIH0KICAgICAgICB9KTsKICAgIH0KCiAgICBmdW5jdGlvbiBjbGVhclBhc3RlZExvY2FsKGlkKSB7
CiAgICAgICAgY29uc3Qga2V5ID0gU3RyaW5nKGlkKTsKICAgICAgICBjb25zdCBjID0gYWxsQ2xpcHMu
ZmluZCh4ID0+ICt4LmlkID09PSAraWQpOwogICAgICAgIGlmIChjKSBjLnBhc3RlZCA9IGZhbHNlOwog
ICAgICAgIGRvY3VtZW50LnF1ZXJ5U2VsZWN0b3JBbGwoJy5pdG1bZGF0YS1pZD0iJyArIGtleSArICci
XSAuaS11c2VkJykuZm9yRWFjaChlbCA9PiB7CiAgICAgICAgICAgIHRyeSB7IGVsLnJlbW92ZSgpOyB9
IGNhdGNoIHt9CiAgICAgICAgfSk7CiAgICB9CgogICAgZnVuY3Rpb24gcGFzdGVNdWx0aVNlbGVjdGlv
bigpIHsKICAgICAgICBpZiAoIW11bHRpSWRzLmxlbmd0aCkgcmV0dXJuOwogICAgICAgIGNvbnN0IGlk
cyA9IG11bHRpSWRzLnNsaWNlKCk7CiAgICAgICAgY2xlYXJNdWx0aSgpOwogICAgICAgIGlmIChpZHMu
c29tZShpZCA9PiB7CiAgICAgICAgICAgIGNvbnN0IGl0ID0gYWxsQ2xpcHMuZmluZCh4ID0+ICt4Lmlk
ID09PSAraWQpOwogICAgICAgICAgICByZXR1cm4gaXQgJiYgbm9ybVR5cGUoaXQudHlwZSkgPT09ICdy
ZWNlbnQnOwogICAgICAgIH0pKSB7CiAgICAgICAgICAgIGNvbnN0IGZpcnN0ID0gYWxsQ2xpcHMuZmlu
ZCh4ID0+ICt4LmlkID09PSAraWRzWzBdKTsKICAgICAgICAgICAgaWYgKGZpcnN0KSBhY3RpdmF0ZUNs
aXBJdGVtKGZpcnN0KTsKICAgICAgICAgICAgcmV0dXJuOwogICAgICAgIH0KICAgICAgICBtYXJrUGFz
dGVkTG9jYWwoaWRzKTsKICAgICAgICBpZiAoaWRzLmxlbmd0aCA+IDEpIHBhc3RlTWFueVdpdGhTZXAo
aWRzLCBmYWxzZSk7CiAgICAgICAgZWxzZSBhaGsoJ3Bhc3RlJywgU3RyaW5nKGlkc1swXSkpOwogICAg
fQoKICAgIGNvbnN0IGxpc3RFbCAgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbGlzdCcpOwogICAg
Y29uc3QgZW1wdHlFbCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdlbXB0eScpOwogICAgY29uc3Qg
c2tlbEVsICA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdza2VsJyk7CiAgICBjb25zdCBidG5Ub3Ag
ID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2J0bi10b3AnKTsKICAgIGZ1bmN0aW9uIHNldEJvb3RM
b2FkaW5nKG9uKSB7CiAgICAgICAgYm9vdExvYWRpbmcgPSAhIW9uOwogICAgICAgIGlmIChib290TG9h
ZGluZykgd2luZG93Ll9fc2tlbFNpbmNlID0gRGF0ZS5ub3coKTsKICAgICAgICBpZiAoc2tlbEVsKSBz
a2VsRWwuY2xhc3NMaXN0LnRvZ2dsZSgnb24nLCBib290TG9hZGluZyk7CiAgICAgICAgaWYgKGJvb3RM
b2FkaW5nICYmIGVtcHR5RWwpIGVtcHR5RWwuY2xhc3NMaXN0LnJlbW92ZSgnb24nKTsKICAgICAgICBj
b25zdCBhcHAgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYXBwJyk7CiAgICAgICAgaWYgKGFwcCkg
YXBwLmNsYXNzTGlzdC50b2dnbGUoJ2Jvb3QtbG9hZGluZycsIGJvb3RMb2FkaW5nKTsKICAgIH0KICAg
IC8qKiBXYWl0IGZvciBob3N0IGRhdGEuIEVtcHR5IGxpc3Qg4oaSc2tlbGV0b24gbm93IChubyBibGFu
aykuIEhhcyBjb250ZW50IOKGkmRlbGF5LiAqLwogICAgZnVuY3Rpb24gc2NoZWR1bGVEZWxheWVkU2tl
bCgpIHsKICAgICAgICB3YWl0aW5nRGF0YSA9IHRydWU7CiAgICAgICAgd2luZG93Ll9fZGF0YVJlYWR5
ID0gZmFsc2U7CiAgICAgICAgaWYgKGVtcHR5RWwpIGVtcHR5RWwuY2xhc3NMaXN0LnJlbW92ZSgnb24n
KTsKICAgICAgICBpZiAod2luZG93Ll9fcGVuZGluZ1NrZWxUaW1lcikgewogICAgICAgICAgICBjbGVh
clRpbWVvdXQod2luZG93Ll9fcGVuZGluZ1NrZWxUaW1lcik7CiAgICAgICAgICAgIHdpbmRvdy5fX3Bl
bmRpbmdTa2VsVGltZXIgPSAwOwogICAgICAgIH0KICAgICAgICB3aW5kb3cuX19wZW5kaW5nU2tlbFNp
bmNlID0gRGF0ZS5ub3coKTsKICAgICAgICBjb25zdCBoYXNQYWludCA9IChhbGxDbGlwcyAmJiBhbGxD
bGlwcy5sZW5ndGggPiAwKQogICAgICAgICAgICB8fCAhIShsaXN0RWwgJiYgbGlzdEVsLnF1ZXJ5U2Vs
ZWN0b3IoJy5pdG0nKSk7CiAgICAgICAgaWYgKCFoYXNQYWludCkgewogICAgICAgICAgICAvLyBOb3Ro
aW5nIG9uIHNjcmVlbiDigJRzaG93IHNrZWxldG9uIGltbWVkaWF0ZWx5IHNvIHBhbmVsIGlzIG5ldmVy
IGJsYW5rCiAgICAgICAgICAgIHNldEJvb3RMb2FkaW5nKHRydWUpOwogICAgICAgICAgICB0cnkgeyBy
ZW5kZXIoKTsgfSBjYXRjaCB7fQogICAgICAgICAgICByZXR1cm47CiAgICAgICAgfQogICAgICAgIC8v
IEFscmVhZHkgc2hvd2luZyByb3dzIOKAlG9ubHkgc3dhcCB0byBza2VsZXRvbiBpZiByZWZyZXNoIGlz
IHNsb3cKICAgICAgICB3aW5kb3cuX19wZW5kaW5nU2tlbFRpbWVyID0gc2V0VGltZW91dCgoKSA9PiB7
CiAgICAgICAgICAgIHdpbmRvdy5fX3BlbmRpbmdTa2VsVGltZXIgPSAwOwogICAgICAgICAgICBpZiAo
d2FpdGluZ0RhdGEgJiYgIXdpbmRvdy5fX2RhdGFSZWFkeSkgewogICAgICAgICAgICAgICAgc2V0Qm9v
dExvYWRpbmcodHJ1ZSk7CiAgICAgICAgICAgICAgICB0cnkgeyByZW5kZXIoKTsgfSBjYXRjaCB7fQog
ICAgICAgICAgICB9CiAgICAgICAgfSwgU0tFTF9ERUxBWV9NUyk7CiAgICB9CiAgICBmdW5jdGlvbiBj
bGVhcldhaXRpbmdEYXRhKCkgewogICAgICAgIHdhaXRpbmdEYXRhID0gZmFsc2U7CiAgICAgICAgaWYg
KHdpbmRvdy5fX3BlbmRpbmdTa2VsVGltZXIpIHsKICAgICAgICAgICAgY2xlYXJUaW1lb3V0KHdpbmRv
dy5fX3BlbmRpbmdTa2VsVGltZXIpOwogICAgICAgICAgICB3aW5kb3cuX19wZW5kaW5nU2tlbFRpbWVy
ID0gMDsKICAgICAgICB9CiAgICAgICAgd2luZG93Ll9fcGVuZGluZ1NrZWxTaW5jZSA9IDA7CiAgICAg
ICAgc2V0Qm9vdExvYWRpbmcoZmFsc2UpOwogICAgfQogICAgd2luZG93LnNldEJvb3RMb2FkaW5nID0g
c2V0Qm9vdExvYWRpbmc7CiAgICB3aW5kb3cuZm9yY2VFbmRCb290TG9hZGluZyA9IGZ1bmN0aW9uKCkg
ewogICAgICAgIGNsZWFyV2FpdGluZ0RhdGEoKTsKICAgICAgICAvLyBEbyBub3QgZmFrZeOAjOaaguaX
oOiusOW9leOAjWlmIGhvc3QgbmV2ZXIgcHVzaGVkCiAgICAgICAgaWYgKGhvc3RQdXNoZWRPbmNlKQog
ICAgICAgICAgICB3aW5kb3cuX19kYXRhUmVhZHkgPSB0cnVlOwogICAgICAgIHRyeSB7IHJlbmRlcigp
OyB9IGNhdGNoIChlKSB7fQogICAgfTsKICAgIC8vIFNhZmV0eTogZHJvcCBzdHVjayBza2VsZXRvbjsg
c3RpbGwgbmV2ZXIgaW52ZW50IGVtcHR5LXN0YXRlIHdpdGhvdXQgaG9zdCBwdXNoCiAgICBzZXRUaW1l
b3V0KCgpID0+IHsKICAgICAgICBpZiAoaG9zdFB1c2hlZE9uY2UgfHwgd2luZG93Ll9fZGF0YVJlYWR5
KSByZXR1cm47CiAgICAgICAgaWYgKCFib290TG9hZGluZyAmJiAhd2FpdGluZ0RhdGEpIHJldHVybjsK
ICAgICAgICBjbGVhcldhaXRpbmdEYXRhKCk7CiAgICAgICAgdHJ5IHsgcmVuZGVyKCk7IH0gY2F0Y2gg
e30KICAgIH0sIDgwMDApOwoKICAgIGZ1bmN0aW9uIHVwZGF0ZVRvcEJ0bigpIHsKICAgICAgICBpZiAo
IWJ0blRvcCB8fCAhbGlzdEVsKSByZXR1cm47CiAgICAgICAgYnRuVG9wLmNsYXNzTGlzdC50b2dnbGUo
J29uJywgbGlzdEVsLnNjcm9sbFRvcCA+IDQ4KTsKICAgIH0KICAgIGxldCBfc2Nyb2xsUmFmID0gMDsK
ICAgIGxldCBfc2Nyb2xsSWRsZVQgPSAwOwogICAgbGV0IF9saXN0UHRyRG93biA9IGZhbHNlOwogICAg
bGV0IF9wZW5kaW5nQXBwZW5kID0gbnVsbDsgLy8geyBmcm9tTGVuIH0gcXVldWVkIHdoaWxlIHNjcm9s
bGluZwogICAgd2luZG93Ll9fc2Nyb2xsQnVzeSA9IGZhbHNlOwogICAgd2luZG93Ll9fd2FudE1vcmUg
PSBmYWxzZTsKCiAgICBmdW5jdGlvbiBtYXJrTGlzdFNjcm9sbGluZygpIHsKICAgICAgICB3aW5kb3cu
X19zY3JvbGxCdXN5ID0gdHJ1ZTsKICAgICAgICB0cnkgeyBsaXN0RWwuY2xhc3NMaXN0LmFkZCgnaXMt
c2Nyb2xsaW5nJyk7IH0gY2F0Y2gge30KICAgICAgICBpZiAoX3Njcm9sbElkbGVUKSBjbGVhclRpbWVv
dXQoX3Njcm9sbElkbGVUKTsKICAgICAgICAvLyBXYWl0IHVudGlsIHdoZWVsL3Njcm9sbGJhciBnZXN0
dXJlIGZ1bGx5IHNldHRsZXMgYmVmb3JlIEFISy9ET00gd29yawogICAgICAgIF9zY3JvbGxJZGxlVCA9
IHNldFRpbWVvdXQoKCkgPT4gewogICAgICAgICAgICBfc2Nyb2xsSWRsZVQgPSAwOwogICAgICAgICAg
ICBmbHVzaFNjcm9sbElkbGUoKTsKICAgICAgICB9LCAyMjApOwogICAgfQoKICAgIGZ1bmN0aW9uIGZs
dXNoU2Nyb2xsSWRsZSgpIHsKICAgICAgICAvLyBTdGlsbCBob2xkaW5nIHNjcm9sbGJhciAvIGZpbmdl
ciDigJQgZG9uJ3QgbG9hZCBvciBwYWludCB5ZXQKICAgICAgICBpZiAoX2xpc3RQdHJEb3duKSB7CiAg
ICAgICAgICAgIG1hcmtMaXN0U2Nyb2xsaW5nKCk7CiAgICAgICAgICAgIHJldHVybjsKICAgICAgICB9
CiAgICAgICAgd2luZG93Ll9fc2Nyb2xsQnVzeSA9IGZhbHNlOwogICAgICAgIHRyeSB7IGxpc3RFbC5j
bGFzc0xpc3QucmVtb3ZlKCdpcy1zY3JvbGxpbmcnKTsgfSBjYXRjaCB7fQogICAgICAgIC8vIEFwcGx5
IERPTSBhcHBlbmQgb25seSBhZnRlciBzY3JvbGwgZ2VzdHVyZSBlbmRzCiAgICAgICAgaWYgKF9wZW5k
aW5nQXBwZW5kKSB7CiAgICAgICAgICAgIGNvbnN0IHBlbmRpbmcgPSBfcGVuZGluZ0FwcGVuZDsKICAg
ICAgICAgICAgX3BlbmRpbmdBcHBlbmQgPSBudWxsOwogICAgICAgICAgICBhcHBseUFwcGVuZFBheWxv
YWQocGVuZGluZyk7CiAgICAgICAgfQogICAgICAgIGlmICh3aW5kb3cuX193YW50TW9yZSkKICAgICAg
ICAgICAgcmVxdWVzdE1vcmUoKTsKICAgICAgICBlbHNlIGlmICghbG9hZGluZ01vcmUKICAgICAgICAg
ICAgJiYgZGlza1RvdGFsID4gMAogICAgICAgICAgICAmJiBhbGxDbGlwcy5sZW5ndGggPCBkaXNrVG90
YWwKICAgICAgICAgICAgJiYgbGlzdEVsLnNjcm9sbFRvcCArIGxpc3RFbC5jbGllbnRIZWlnaHQgPj0g
bGlzdEVsLnNjcm9sbEhlaWdodCAtIDQyMCkKICAgICAgICAgICAgcmVxdWVzdE1vcmUoKTsKICAgIH0K
CiAgICBmdW5jdGlvbiBvbkxpc3RTY3JvbGwoKSB7CiAgICAgICAgbWFya0xpc3RTY3JvbGxpbmcoKTsK
ICAgICAgICBpZiAoX3Njcm9sbFJhZikgcmV0dXJuOwogICAgICAgIF9zY3JvbGxSYWYgPSByZXF1ZXN0
QW5pbWF0aW9uRnJhbWUoKCkgPT4gewogICAgICAgICAgICBfc2Nyb2xsUmFmID0gMDsKICAgICAgICAg
ICAgdHJ5IHsgaGlkZVBhdGhUaXAoKTsgfSBjYXRjaCB7fQogICAgICAgICAgICB1cGRhdGVUb3BCdG4o
KTsKICAgICAgICAgICAgLy8gTWFyayBpbnRlbnQgb25seSDigJQgYWN0dWFsIEFISyBsb2FkIHdhaXRz
IGZvciBpZGxlICsgcG9pbnRlciB1cAogICAgICAgICAgICBpZiAoIWxvYWRpbmdNb3JlCiAgICAgICAg
ICAgICAgICAmJiBkaXNrVG90YWwgPiAwCiAgICAgICAgICAgICAgICAmJiBhbGxDbGlwcy5sZW5ndGgg
PCBkaXNrVG90YWwKICAgICAgICAgICAgICAgICYmIGxpc3RFbC5zY3JvbGxUb3AgKyBsaXN0RWwuY2xp
ZW50SGVpZ2h0ID49IGxpc3RFbC5zY3JvbGxIZWlnaHQgLSA0MjApCiAgICAgICAgICAgICAgICB3aW5k
b3cuX193YW50TW9yZSA9IHRydWU7CiAgICAgICAgfSk7CiAgICB9CiAgICBsaXN0RWwuYWRkRXZlbnRM
aXN0ZW5lcignc2Nyb2xsJywgb25MaXN0U2Nyb2xsLCB7IHBhc3NpdmU6IHRydWUgfSk7CiAgICBsaXN0
RWwuYWRkRXZlbnRMaXN0ZW5lcignd2hlZWwnLCBtYXJrTGlzdFNjcm9sbGluZywgeyBwYXNzaXZlOiB0
cnVlIH0pOwogICAgbGlzdEVsLmFkZEV2ZW50TGlzdGVuZXIoJ3BvaW50ZXJkb3duJywgZSA9PiB7CiAg
ICAgICAgLy8gT25seSBwcmltYXJ5IGJ1dHRvbiAoc2Nyb2xsYmFyIGRyYWcgLyBsZWZ0IHByZXNzKS4g
UmlnaHQtY2xpY2sgbXVzdCBub3QKICAgICAgICAvLyBlbnRlciAic2Nyb2xsaW5nIiBtb2RlIG9yIGNv
bnRleHRtZW51IG5ldmVyIHJlYWNoZXMgLml0bSBoYW5kbGVycy4KICAgICAgICBpZiAoZS5idXR0b24g
IT09IDApIHJldHVybjsKICAgICAgICBfbGlzdFB0ckRvd24gPSB0cnVlOwogICAgICAgIG1hcmtMaXN0
U2Nyb2xsaW5nKCk7CiAgICB9LCB7IHBhc3NpdmU6IHRydWUgfSk7CiAgICB3aW5kb3cuYWRkRXZlbnRM
aXN0ZW5lcigncG9pbnRlcnVwJywgKCkgPT4gewogICAgICAgIGlmICghX2xpc3RQdHJEb3duKSByZXR1
cm47CiAgICAgICAgX2xpc3RQdHJEb3duID0gZmFsc2U7CiAgICAgICAgbWFya0xpc3RTY3JvbGxpbmco
KTsKICAgIH0sIHsgcGFzc2l2ZTogdHJ1ZSB9KTsKICAgIHdpbmRvdy5hZGRFdmVudExpc3RlbmVyKCdw
b2ludGVyY2FuY2VsJywgKCkgPT4gewogICAgICAgIGlmICghX2xpc3RQdHJEb3duKSByZXR1cm47CiAg
ICAgICAgX2xpc3RQdHJEb3duID0gZmFsc2U7CiAgICAgICAgbWFya0xpc3RTY3JvbGxpbmcoKTsKICAg
IH0sIHsgcGFzc2l2ZTogdHJ1ZSB9KTsKICAgIGJ0blRvcC5hZGRFdmVudExpc3RlbmVyKCdjbGljaycs
IGUgPT4gewogICAgICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAgICAgbGlzdEVsLnNjcm9sbFRv
KHsgdG9wOiAwLCBiZWhhdmlvcjogJ3Ntb290aCcgfSk7CiAgICB9KTsKCiAgICBmdW5jdGlvbiB2aXNp
YmxlTGlzdCgpIHsKICAgICAgICBjb25zdCBxID0gU3RyaW5nKHF1ZXJ5IHx8ICcnKS50cmltKCk7CiAg
ICAgICAgLy8gSG9zdCBhbHJlYWR5IGZpbHRlcmVkK2V4cGFuZGVkIGZvciB0aGlzIGV4YWN0IHF1ZXJ5
IOKAlCBkb24ndCByZS1maWx0ZXIgKGF2b2lkcyBmbGFzaCAvIGRyb3BwZWQgZmF2IGdyb3VwcykKICAg
ICAgICBpZiAocSAmJiB3aW5kb3cuX19ob3N0RmlsdGVyZWQgJiYgd2luZG93Ll9faG9zdEZpbHRlclEg
PT09IHEpCiAgICAgICAgICAgIHJldHVybiBhbGxDbGlwczsKICAgICAgICByZXR1cm4gZmlsdGVyKGFs
bENsaXBzLCBjdXJUYWIsIHF1ZXJ5KTsKICAgIH0KICAgIGZ1bmN0aW9uIGVzY0h0bWwocykgewogICAg
ICAgIHJldHVybiBTdHJpbmcocyA/PyAnJykucmVwbGFjZSgvJi9nLCcmYW1wOycpLnJlcGxhY2UoLzwv
ZywnJmx0OycpLnJlcGxhY2UoLz4vZywnJmd0OycpLnJlcGxhY2UoLyIvZywnJnF1b3Q7Jyk7CiAgICB9
CiAgICBmdW5jdGlvbiBxdWVyeVRlcm1zKHEpIHsKICAgICAgICBjb25zdCBvdXQgPSBbXTsKICAgICAg
ICBmb3IgKGNvbnN0IHNlZyBvZiBTdHJpbmcocSB8fCAnJykuc3BsaXQoJ3wnKSkgewogICAgICAgICAg
ICBjb25zdCBzID0gc2VnLnRyaW0oKTsKICAgICAgICAgICAgaWYgKCFzKSBjb250aW51ZTsKICAgICAg
ICAgICAgY29uc3Qgd29yZHMgPSBzLnNwbGl0KC9ccysvKS5maWx0ZXIoQm9vbGVhbik7CiAgICAgICAg
ICAgIGlmICh3b3Jkcy5sZW5ndGgpIG91dC5wdXNoKC4uLndvcmRzKTsKICAgICAgICB9CiAgICAgICAg
cmV0dXJuIG91dDsKICAgIH0KICAgIGZ1bmN0aW9uIGhsSHRtbCh0ZXh0KSB7CiAgICAgICAgY29uc3Qg
dGVybXMgPSBxdWVyeVRlcm1zKHF1ZXJ5KTsKICAgICAgICBjb25zdCBzID0gU3RyaW5nKHRleHQgPz8g
JycpOwogICAgICAgIGlmICghdGVybXMubGVuZ3RoKSByZXR1cm4gZXNjSHRtbChzKTsKICAgICAgICBj
b25zdCBsb3dlciA9IHMudG9Mb3dlckNhc2UoKTsKICAgICAgICBjb25zdCB0ZXJtTCA9IHRlcm1zLm1h
cCh0ID0+IHQudG9Mb3dlckNhc2UoKSk7CiAgICAgICAgbGV0IG91dCA9ICcnLCBpID0gMDsKICAgICAg
ICB3aGlsZSAoaSA8IHMubGVuZ3RoKSB7CiAgICAgICAgICAgIGxldCBiZXN0SiA9IC0xLCBiZXN0TGVu
ID0gMDsKICAgICAgICAgICAgZm9yIChsZXQgdGkgPSAwOyB0aSA8IHRlcm1MLmxlbmd0aDsgdGkrKykg
ewogICAgICAgICAgICAgICAgY29uc3QgdCA9IHRlcm1MW3RpXTsKICAgICAgICAgICAgICAgIGlmICgh
dCkgY29udGludWU7CiAgICAgICAgICAgICAgICBjb25zdCBqID0gbG93ZXIuaW5kZXhPZih0LCBpKTsK
ICAgICAgICAgICAgICAgIGlmIChqIDwgMCkgY29udGludWU7CiAgICAgICAgICAgICAgICBpZiAoYmVz
dEogPCAwIHx8IGogPCBiZXN0SiB8fCAoaiA9PT0gYmVzdEogJiYgdC5sZW5ndGggPiBiZXN0TGVuKSkg
ewogICAgICAgICAgICAgICAgICAgIGJlc3RKID0gajsgYmVzdExlbiA9IHQubGVuZ3RoOwogICAgICAg
ICAgICAgICAgfQogICAgICAgICAgICB9CiAgICAgICAgICAgIGlmIChiZXN0SiA8IDApIHsgb3V0ICs9
IGVzY0h0bWwocy5zbGljZShpKSk7IGJyZWFrOyB9CiAgICAgICAgICAgIG91dCArPSBlc2NIdG1sKHMu
c2xpY2UoaSwgYmVzdEopKTsKICAgICAgICAgICAgb3V0ICs9ICc8bWFyayBjbGFzcz0icS1obCI+JyAr
IGVzY0h0bWwocy5zbGljZShiZXN0SiwgYmVzdEogKyBiZXN0TGVuKSkgKyAnPC9tYXJrPic7CiAgICAg
ICAgICAgIGkgPSBiZXN0SiArIE1hdGgubWF4KDEsIGJlc3RMZW4pOwogICAgICAgIH0KICAgICAgICBy
ZXR1cm4gb3V0OwogICAgfQogICAgZnVuY3Rpb24gc2V0SGxUZXh0KGVsLCB0ZXh0KSB7CiAgICAgICAg
aWYgKCFlbCkgcmV0dXJuOwogICAgICAgIGNvbnN0IHEgPSBTdHJpbmcocXVlcnkgfHwgJycpLnRyaW0o
KTsKICAgICAgICBpZiAoIXEpIHsKICAgICAgICAgICAgZWwuY2xhc3NMaXN0LnJlbW92ZSgnaGFzLWhs
Jyk7CiAgICAgICAgICAgIGVsLnRleHRDb250ZW50ID0gdGV4dCA9PSBudWxsID8gJycgOiBTdHJpbmco
dGV4dCk7CiAgICAgICAgICAgIHJldHVybjsKICAgICAgICB9CiAgICAgICAgZWwuY2xhc3NMaXN0LmFk
ZCgnaGFzLWhsJyk7CiAgICAgICAgZWwuaW5uZXJIVE1MID0gaGxIdG1sKHRleHQpOwogICAgfQoKCiAg
ICBmdW5jdGlvbiBhcHBseVRhYlN3aXRjaEFuaW0oKSB7CiAgICAgICAgaWYgKCF0YWJTd2l0Y2hBbmlt
RGlyIHx8ICFsaXN0RWwpIHJldHVybjsKICAgICAgICBpZiAoIWxpc3RFbC5xdWVyeVNlbGVjdG9yKCcu
aXRtLCAjZW1wdHkub24sICNsaXN0LW1vcmUnKSkKICAgICAgICAgICAgcmV0dXJuOwogICAgICAgIGNv
bnN0IGRpciA9IHRhYlN3aXRjaEFuaW1EaXI7CiAgICAgICAgdGFiU3dpdGNoQW5pbURpciA9IDA7CiAg
ICAgICAgbGlzdEVsLmNsYXNzTGlzdC5yZW1vdmUoJ3RhYi1pbi1scicsICd0YWItaW4tcmwnKTsKICAg
ICAgICB2b2lkIGxpc3RFbC5vZmZzZXRXaWR0aDsKICAgICAgICBsaXN0RWwuY2xhc3NMaXN0LmFkZChk
aXIgPiAwID8gJ3RhYi1pbi1scicgOiAndGFiLWluLXJsJyk7CiAgICAgICAgY2xlYXJUaW1lb3V0KGxp
c3RFbC5fdGFiQW5pbVRpbWVyKTsKICAgICAgICBsaXN0RWwuX3RhYkFuaW1UaW1lciA9IHNldFRpbWVv
dXQoKCkgPT4gewogICAgICAgICAgICBsaXN0RWwuY2xhc3NMaXN0LnJlbW92ZSgndGFiLWluLWxyJywg
J3RhYi1pbi1ybCcpOwogICAgICAgIH0sIDQwMCk7CiAgICB9CgogICAgZnVuY3Rpb24gdGFiSW5kZXgo
dGFiKSB7CiAgICAgICAgY29uc3QgaSA9IFRBQl9PUkRFUi5pbmRleE9mKHRhYik7CiAgICAgICAgcmV0
dXJuIGkgPj0gMCA/IGkgOiAwOwogICAgfQoKICAgIGZ1bmN0aW9uIG1vdmVUYWJJbmsoaW5zdGFudCwg
dGFyZ2V0RWwpIHsKICAgICAgICBjb25zdCBpbmsgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgndGFi
LWluaycpOwogICAgICAgIGNvbnN0IHRhYnMgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgndGFicycp
OwogICAgICAgIGNvbnN0IGVsID0gdGFyZ2V0RWwgfHwgZG9jdW1lbnQucXVlcnlTZWxlY3RvcignI3Rh
YnMgLnRhYi5vbicpOwogICAgICAgIGlmICghaW5rIHx8ICF0YWJzIHx8ICFlbCkgcmV0dXJuOwogICAg
ICAgIGNvbnN0IHRyID0gdGFicy5nZXRCb3VuZGluZ0NsaWVudFJlY3QoKTsKICAgICAgICBjb25zdCBy
ID0gZWwuZ2V0Qm91bmRpbmdDbGllbnRSZWN0KCk7CiAgICAgICAgY29uc3QgeCA9IHIubGVmdCAtIHRy
LmxlZnQ7CiAgICAgICAgY29uc3QgaCA9IE1hdGgubWF4KDIwLCBNYXRoLnJvdW5kKHIuaGVpZ2h0KSk7
CiAgICAgICAgY29uc3QgeSA9IHIudG9wIC0gdHIudG9wOwogICAgICAgIGNvbnN0IHcgPSBNYXRoLm1h
eCgyNCwgci53aWR0aCk7CiAgICAgICAgY29uc3QgcG9zID0gJ3RyYW5zbGF0ZTNkKCcgKyB4ICsgJ3B4
LCcgKyB5ICsgJ3B4LDApJzsKICAgICAgICBpbmsuc3R5bGUudHJhbnNmb3JtT3JpZ2luID0gJ2NlbnRl
ciBib3R0b20nOwogICAgICAgIGluay5zdHlsZS53aWR0aCA9IHcgKyAncHgnOwogICAgICAgIGluay5z
dHlsZS5oZWlnaHQgPSBoICsgJ3B4JzsKICAgICAgICBpZiAoaW5zdGFudCkgewogICAgICAgICAgICBp
bmsuc3R5bGUudHJhbnNpdGlvbiA9ICdub25lJzsKICAgICAgICAgICAgaW5rLmNsYXNzTGlzdC5yZW1v
dmUoJ3NxdWFzaCcpOwogICAgICAgICAgICBpbmsuc3R5bGUudHJhbnNmb3JtID0gcG9zICsgJyBzY2Fs
ZVgoMSknOwogICAgICAgICAgICBpbmsub2Zmc2V0SGVpZ2h0OwogICAgICAgICAgICBpbmsuc3R5bGUu
dHJhbnNpdGlvbiA9ICcnOwogICAgICAgICAgICByZXR1cm47CiAgICAgICAgfQogICAgICAgIC8vIFNu
YXAgdG8gaG92ZXJlZCB0YWIsIGV4cGFuZCBmcm9tIGJvdHRvbS1jZW50ZXIg4oCUIG5vIHNsaWRpbmcg
YmV0d2VlbiB0YWJzCiAgICAgICAgaW5rLnN0eWxlLnRyYW5zaXRpb24gPSAnbm9uZSc7CiAgICAgICAg
aW5rLnN0eWxlLnRyYW5zZm9ybSA9IHBvcyArICcgc2NhbGVYKDAuMDAxKSc7CiAgICAgICAgaW5rLm9m
ZnNldEhlaWdodDsKICAgICAgICBpbmsuc3R5bGUudHJhbnNpdGlvbiA9ICcnOwogICAgICAgIGluay5j
bGFzc0xpc3QuYWRkKCdzcXVhc2gnKTsKICAgICAgICBpbmsuc3R5bGUudHJhbnNmb3JtID0gcG9zICsg
JyBzY2FsZVgoMSknOwogICAgICAgIGNsZWFyVGltZW91dChpbmsuX3NxdWFzaFRpbWVyKTsKICAgICAg
ICBpbmsuX3NxdWFzaFRpbWVyID0gc2V0VGltZW91dCgoKSA9PiBpbmsuY2xhc3NMaXN0LnJlbW92ZSgn
c3F1YXNoJyksIDM0MCk7CiAgICB9CiAgICBmdW5jdGlvbiBtYXJrVGFiKHRhYiwgaW5zdGFudCkgewog
ICAgICAgIGRvY3VtZW50LnF1ZXJ5U2VsZWN0b3JBbGwoJyN0YWJzIC50YWInKS5mb3JFYWNoKGVsID0+
CiAgICAgICAgICAgIGVsLmNsYXNzTGlzdC50b2dnbGUoJ29uJywgZWwuZGF0YXNldC50YWIgPT09IHRh
YikpOwogICAgICAgIG1vdmVUYWJJbmsoISFpbnN0YW50KTsKICAgIH0KICAgIGZ1bmN0aW9uIGJpbmRU
YWJJbmtIb3ZlcigpIHsKICAgICAgICBjb25zdCB0YWJzID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQo
J3RhYnMnKTsKICAgICAgICBpZiAoIXRhYnMgfHwgdGFicy5faW5rSG92ZXJCb3VuZCkgcmV0dXJuOwog
ICAgICAgIHRhYnMuX2lua0hvdmVyQm91bmQgPSB0cnVlOwogICAgICAgIHRhYnMuYWRkRXZlbnRMaXN0
ZW5lcigncG9pbnRlcm92ZXInLCBlID0+IHsKICAgICAgICAgICAgY29uc3QgdGFiID0gZS50YXJnZXQu
Y2xvc2VzdCgnLnRhYicpOwogICAgICAgICAgICBpZiAoIXRhYiB8fCAhdGFicy5jb250YWlucyh0YWIp
KSByZXR1cm47CiAgICAgICAgICAgIG1vdmVUYWJJbmsoZmFsc2UsIHRhYik7CiAgICAgICAgfSk7CiAg
ICAgICAgdGFicy5hZGRFdmVudExpc3RlbmVyKCdwb2ludGVybGVhdmUnLCBlID0+IHsKICAgICAgICAg
ICAgaWYgKGUucmVsYXRlZFRhcmdldCAmJiB0YWJzLmNvbnRhaW5zKGUucmVsYXRlZFRhcmdldCkpIHJl
dHVybjsKICAgICAgICAgICAgbW92ZVRhYkluayhmYWxzZSk7CiAgICAgICAgfSk7CiAgICB9CmZ1bmN0
aW9uIHNldFRhYih0YWIpIHsKICAgICAgICBpZiAodGFiID09PSBjdXJUYWIpIHJldHVybjsKICAgICAg
ICBjb25zdCBmcm9tID0gdGFiSW5kZXgoY3VyVGFiKTsKICAgICAgICBjb25zdCB0byA9IHRhYkluZGV4
KHRhYik7CiAgICAgICAgdGFiU3dpdGNoQW5pbURpciA9IHRvID4gZnJvbSA/IDEgOiAodG8gPCBmcm9t
ID8gLTEgOiAwKTsKICAgICAgICBjdXJUYWIgPSB0YWI7CiAgICAgICAgbG9hZGluZ01vcmUgPSBmYWxz
ZTsKICAgICAgICBtYXJrVGFiKHRhYik7CgogICAgICAgIC8vIEtlZXAgc2VhcmNoICJ0b2RheSIgZmls
dGVyIGluIHN5bmMgd2hlbiBzZWFyY2ggaXMgb3BlbgogICAgICAgIHRyeSB7CiAgICAgICAgICAgIGNv
bnN0IHdyYXAgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc2VhcmNoLXdyYXAnKTsKICAgICAgICAg
ICAgY29uc3QgYnRuVG9kYXkgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYnRuLXRvZGF5Jyk7CiAg
ICAgICAgICAgIGlmICh3cmFwICYmIHdyYXAuY2xhc3NMaXN0LmNvbnRhaW5zKCdvcGVuJykpIHsKICAg
ICAgICAgICAgICAgIGNvbnN0IHdhbnRUb2RheSA9IGZhbHNlOwogICAgICAgICAgICAgICAgaWYgKHRv
ZGF5T25seSAhPT0gd2FudFRvZGF5KSB7CiAgICAgICAgICAgICAgICAgICAgdG9kYXlPbmx5ID0gd2Fu
dFRvZGF5OwogICAgICAgICAgICAgICAgICAgIGlmIChidG5Ub2RheSkgYnRuVG9kYXkuY2xhc3NMaXN0
LnRvZ2dsZSgnb24nLCB0b2RheU9ubHkpOwogICAgICAgICAgICAgICAgfQogICAgICAgICAgICB9CiAg
ICAgICAgfSBjYXRjaCB7fQoKICAgICAgICBzZWxlY3RlZElkID0gbnVsbDsKICAgICAgICBtdWx0aUlk
cyA9IFtdOwogICAgICAgIGxpc3RFbC5zY3JvbGxUb3AgPSAwOwogICAgICAgIGNvbnN0IGhpdCA9IHZp
ZXdNZW0uZ2V0KHZpZXdNZW1LZXkodGFiLCBxdWVyeSwgdG9kYXlPbmx5KSk7CiAgICAgICAgaWYgKGhp
dCAmJiBBcnJheS5pc0FycmF5KGhpdC5pdGVtcykgJiYgaGl0Lml0ZW1zLmxlbmd0aCkgewogICAgICAg
ICAgICBhbGxDbGlwcyA9IGhpdC5pdGVtcy5zbGljZSgpOwogICAgICAgICAgICBkaXNrVG90YWwgPSBO
dW1iZXIoaGl0LnRvdGFsKSB8fCBoaXQuaXRlbXMubGVuZ3RoOwogICAgICAgICAgICB3aW5kb3cuX193
YWl0aW5nVmlldyA9IGZhbHNlOwogICAgICAgICAgICBjbGVhcldhaXRpbmdEYXRhKCk7CiAgICAgICAg
ICAgIHdpbmRvdy5fX2RhdGFSZWFkeSA9IHRydWU7CiAgICAgICAgICAgIGhvc3RQdXNoZWRPbmNlID0g
dHJ1ZTsKICAgICAgICAgICAgc2F3Tm9uRW1wdHkgPSB0cnVlOwogICAgICAgICAgICByZW5kZXIoKTsK
ICAgICAgICAgICAgYXBwbHlUYWJTd2l0Y2hBbmltKCk7CiAgICAgICAgICAgIC8vIE1lbW9yeSBwYWlu
dCBmaXJzdCDigJRiYWNrZ3JvdW5kIHNvZnQtc3luYyBrZWVwcyBBSEsgaW4gc3RlcCB3aXRob3V0IGRv
dWJsZSByZWRyYXcKICAgICAgICAgICAgc29mdFJlcXVlc3RWaWV3KCk7CiAgICAgICAgICAgIHJldHVy
bjsKICAgICAgICB9CiAgICAgICAgYWxsQ2xpcHMgPSBbXTsKICAgICAgICBkaXNrVG90YWwgPSAwOwog
ICAgICAgIHdpbmRvdy5fX3dhaXRpbmdWaWV3ID0gdHJ1ZTsKICAgICAgICBzY2hlZHVsZURlbGF5ZWRT
a2VsKCk7CiAgICAgICAgcmVxdWVzdFZpZXcoKTsKICAgICAgICByZW5kZXIoKTsKICAgICAgICBhcHBs
eVRhYlN3aXRjaEFuaW0oKTsKICAgIH0KCiAgICBtb3ZlVGFiSW5rKHRydWUpOwogICAgYmluZFRhYklu
a0hvdmVyKCk7CiAgICB0cnkgeyBuZXcgUmVzaXplT2JzZXJ2ZXIoKCkgPT4gbW92ZVRhYkluayh0cnVl
KSkub2JzZXJ2ZShkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgndGFicycpKTsgfSBjYXRjaCB7fQogICAg
d2luZG93LmFkZEV2ZW50TGlzdGVuZXIoJ3Jlc2l6ZScsICgpID0+IG1vdmVUYWJJbmsodHJ1ZSkpOwoK
ICAgIGZ1bmN0aW9uIHVwZGF0ZU1vcmVGb290ZXIodG90YWwpIHsKICAgICAgICBsZXQgbW9yZUVsID0g
ZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2xpc3QtbW9yZScpOwogICAgICAgIGNvbnN0IGxvYWRlZCA9
IGFsbENsaXBzLmxlbmd0aDsKICAgICAgICBpZiAobG9hZGVkID49IHRvdGFsKSB7CiAgICAgICAgICAg
IGlmIChtb3JlRWwpIG1vcmVFbC5yZW1vdmUoKTsKICAgICAgICAgICAgcmV0dXJuOwogICAgICAgIH0K
ICAgICAgICBpZiAoIW1vcmVFbCkgewogICAgICAgICAgICBtb3JlRWwgPSBkb2N1bWVudC5jcmVhdGVF
bGVtZW50KCdkaXYnKTsKICAgICAgICAgICAgbW9yZUVsLmlkID0gJ2xpc3QtbW9yZSc7CiAgICAgICAg
ICAgIG1vcmVFbC5jbGFzc05hbWUgPSAnbGlzdC1tb3JlJzsKICAgICAgICAgICAgbGlzdEVsLmFwcGVu
ZENoaWxkKG1vcmVFbCk7CiAgICAgICAgfQogICAgICAgIG1vcmVFbC50ZXh0Q29udGVudCA9ICfnu6fn
u63kuIvmu5Hku47no4Hnm5jliqDovb3vvIgnICsgbG9hZGVkICsgJy8nICsgdG90YWwgKyAn77yJJzsK
ICAgIH0KCiAgICAvKiogVXBkYXRlIGJhciAvIHBpbiBiYWRnZSB3aXRob3V0IHRvdWNoaW5nIHRoZSBs
aXN0IERPTSAqLwogICAgZnVuY3Rpb24gcmVmcmVzaExpc3RDaHJvbWUoKSB7CiAgICAgICAgY29uc3Qg
dmlzaWJsZSA9IHZpc2libGVMaXN0KCk7CiAgICAgICAgY29uc3QgbG9hZGVkID0gYWxsQ2xpcHMubGVu
Z3RoOwogICAgICAgIGNvbnN0IHNob3duQ291bnQgPSB2aXNpYmxlLmxlbmd0aDsKICAgICAgICBsZXQg
cGlubmVkTiA9IE51bWJlcihwaW5uZWRUb3RhbCkgfHwgMDsKICAgICAgICBpZiAocGlubmVkTiA8IDEp
IHsKICAgICAgICAgICAgaWYgKGN1clRhYiA9PT0gJ3Bpbm5lZCcpCiAgICAgICAgICAgICAgICBwaW5u
ZWROID0gTWF0aC5tYXgoTnVtYmVyKGRpc2tUb3RhbCkgfHwgMCwgbG9hZGVkKTsKICAgICAgICAgICAg
ZWxzZQogICAgICAgICAgICAgICAgcGlubmVkTiA9IGFsbENsaXBzLmZpbHRlcihjID0+IGlzUGlubmVk
KGMpKS5sZW5ndGg7CiAgICAgICAgfQogICAgICAgIGNvbnN0IHBpbkNudCA9IGRvY3VtZW50LmdldEVs
ZW1lbnRCeUlkKCdwaW4tY250Jyk7CiAgICAgICAgaWYgKHBpbkNudCkgewogICAgICAgICAgICBwaW5D
bnQudGV4dENvbnRlbnQgPSBwaW5uZWROOwogICAgICAgICAgICBwaW5DbnQuc3R5bGUuZGlzcGxheSA9
IHBpbm5lZE4gPyAnJyA6ICdub25lJzsKICAgICAgICB9CiAgICAgICAgbGV0IHNob3dUb3RhbCA9IGRp
c2tUb3RhbCA+IDAgPyBkaXNrVG90YWwgOiAobG9hZGVkIHx8IDApOwogICAgICAgIGlmIChjdXJUYWIg
PT09ICdwaW5uZWQnICYmIHBpbm5lZE4gPiBzaG93VG90YWwpCiAgICAgICAgICAgIHNob3dUb3RhbCA9
IHBpbm5lZE47CiAgICAgICAgY29uc3QgcU9uID0gU3RyaW5nKHF1ZXJ5IHx8ICcnKS50cmltKCkubGVu
Z3RoID4gMDsKICAgICAgICBjb25zdCBiYXIgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYmFyLXR4
dCcpOwogICAgICAgIGlmIChiYXIpIHsKICAgICAgICAgICAgYmFyLnRleHRDb250ZW50ID0gcU9uCiAg
ICAgICAgICAgICAgICA/IChzaG93bkNvdW50ICsgJyDmnaEnKQogICAgICAgICAgICAgICAgOiAoc2hv
d1RvdGFsID4gbG9hZGVkID8gKHNob3duQ291bnQgKyAnIC8gJyArIHNob3dUb3RhbCArICcg5p2hJykg
OiAoc2hvd1RvdGFsICsgJyDmnaEnKSk7CiAgICAgICAgfQogICAgICAgIHVwZGF0ZU1vcmVGb290ZXIo
ZGlza1RvdGFsKTsKICAgICAgICB1cGRhdGVUb3BCdG4oKTsKICAgIH0KCiAgICAvKioKICAgICAqIExv
YWQtbW9yZTogYXBwZW5kIG9ubHkgbmV3IERPTSBub2Rlcy4gRnVsbCByZW5kZXIoKSBudWtlcyBldmVy
eSAuaXRtIGFuZAogICAgICogcmVzdG9yZXMgc2Nyb2xsVG9wIOKAlCB0aGF0IGhpdGNoIGlzIHdoYXQg
bWFrZXMgZHJhZ2dpbmcgdGhlIHNjcm9sbGJhciBmZWVsIHN0aWNreS4KICAgICAqIEZhbGxzIGJhY2sg
dG8gZnVsbCByZW5kZXIgaWYgZmF2LWdyb3VwcyBuZWVkIHJlZ3JvdXBpbmcgYWNyb3NzIHRoZSBzZWFt
LgogICAgICovCiAgICBmdW5jdGlvbiBhcHBlbmRSZW5kZXIocHJldkxlbikgewogICAgICAgIGNvbnN0
IHZpc2libGUgPSB2aXNpYmxlTGlzdCgpOwogICAgICAgIGlmICghdmlzaWJsZS5sZW5ndGgpIHsKICAg
ICAgICAgICAgcmVuZGVyKCk7CiAgICAgICAgICAgIHJldHVybiBmYWxzZTsKICAgICAgICB9CiAgICAg
ICAgLy8gSWYgYSBmYXZHcm91cCBzdHJhZGRsZXMgb2xkL25ldyBwYWdlcywgYmxvY2sgc3RydWN0dXJl
IG1heSBjaGFuZ2Ug4oaSIGZ1bGwgcmVidWlsZAogICAgICAgIGlmIChwcmV2TGVuID4gMCAmJiBwcmV2
TGVuIDwgYWxsQ2xpcHMubGVuZ3RoKSB7CiAgICAgICAgICAgIGNvbnN0IHNlYW1HaWRzID0gbmV3IFNl
dCgpOwogICAgICAgICAgICBmb3IgKGxldCBpID0gTWF0aC5tYXgoMCwgcHJldkxlbiAtIDgpOyBpIDwg
TWF0aC5taW4oYWxsQ2xpcHMubGVuZ3RoLCBwcmV2TGVuICsgOCk7IGkrKykgewogICAgICAgICAgICAg
ICAgY29uc3QgZyA9IGZhdkdyb3VwT2YoYWxsQ2xpcHNbaV0pOwogICAgICAgICAgICAgICAgaWYgKGcp
IHNlYW1HaWRzLmFkZChnKTsKICAgICAgICAgICAgfQogICAgICAgICAgICBpZiAoc2VhbUdpZHMuc2l6
ZSkgewogICAgICAgICAgICAgICAgZm9yIChjb25zdCBnIG9mIHNlYW1HaWRzKSB7CiAgICAgICAgICAg
ICAgICAgICAgbGV0IGJlZm9yZSA9IDAsIGFmdGVyID0gMDsKICAgICAgICAgICAgICAgICAgICBmb3Ig
KGxldCBpID0gMDsgaSA8IGFsbENsaXBzLmxlbmd0aDsgaSsrKSB7CiAgICAgICAgICAgICAgICAgICAg
ICAgIGlmIChmYXZHcm91cE9mKGFsbENsaXBzW2ldKSAhPT0gZykgY29udGludWU7CiAgICAgICAgICAg
ICAgICAgICAgICAgIGlmIChpIDwgcHJldkxlbikgYmVmb3JlKys7CiAgICAgICAgICAgICAgICAgICAg
ICAgIGVsc2UgYWZ0ZXIrKzsKICAgICAgICAgICAgICAgICAgICB9CiAgICAgICAgICAgICAgICAgICAg
aWYgKGJlZm9yZSA+IDAgJiYgYWZ0ZXIgPiAwKSB7CiAgICAgICAgICAgICAgICAgICAgICAgIHJlbmRl
cigpOwogICAgICAgICAgICAgICAgICAgICAgICByZXR1cm4gZmFsc2U7CiAgICAgICAgICAgICAgICAg
ICAgfQogICAgICAgICAgICAgICAgfQogICAgICAgICAgICB9CiAgICAgICAgfQogICAgICAgIGNvbnN0
IGJsb2NrcyA9IGJ1aWxkUGlubmVkQmxvY2tzKHZpc2libGUpOwogICAgICAgIGNvbnN0IGV4aXN0aW5n
ID0gbGlzdEVsLnF1ZXJ5U2VsZWN0b3JBbGwoJy5pdG0nKS5sZW5ndGg7CiAgICAgICAgaWYgKGV4aXN0
aW5nIDwgMSkgewogICAgICAgICAgICByZW5kZXIoKTsKICAgICAgICAgICAgcmV0dXJuIGZhbHNlOwog
ICAgICAgIH0KICAgICAgICBpZiAoYmxvY2tzLmxlbmd0aCA8PSBleGlzdGluZykgewogICAgICAgICAg
ICByZWZyZXNoTGlzdENocm9tZSgpOwogICAgICAgICAgICByZXR1cm4gdHJ1ZTsKICAgICAgICB9CiAg
ICAgICAgY29uc3QgZnJhZyA9IGRvY3VtZW50LmNyZWF0ZURvY3VtZW50RnJhZ21lbnQoKTsKICAgICAg
ICBsZXQgbnVtID0gMDsKICAgICAgICBibG9ja3MuZm9yRWFjaChiID0+IHsKICAgICAgICAgICAgbnVt
ICs9IDE7CiAgICAgICAgICAgIGlmIChudW0gPD0gZXhpc3RpbmcpIHJldHVybjsKICAgICAgICAgICAg
aWYgKGIua2luZCA9PT0gJ2dyb3VwJyAmJiBiLml0ZW1zLmxlbmd0aCA+IDEpCiAgICAgICAgICAgICAg
ICBmcmFnLmFwcGVuZENoaWxkKG1ha2VHcm91cEl0ZW0oYi5pdGVtcywgbnVtKSk7CiAgICAgICAgICAg
IGVsc2UKICAgICAgICAgICAgICAgIGZyYWcuYXBwZW5kQ2hpbGQobWFrZUl0ZW0oYi5pdGVtc1swXSwg
bnVtKSk7CiAgICAgICAgfSk7CiAgICAgICAgY29uc3QgbW9yZUVsID0gZG9jdW1lbnQuZ2V0RWxlbWVu
dEJ5SWQoJ2xpc3QtbW9yZScpOwogICAgICAgIGlmIChtb3JlRWwpCiAgICAgICAgICAgIGxpc3RFbC5p
bnNlcnRCZWZvcmUoZnJhZywgbW9yZUVsKTsKICAgICAgICBlbHNlCiAgICAgICAgICAgIGxpc3RFbC5h
cHBlbmRDaGlsZChmcmFnKTsKICAgICAgICByZWZyZXNoTGlzdENocm9tZSgpOwogICAgICAgIHJlcXVl
c3RBbmltYXRpb25GcmFtZSgoKSA9PiB7CiAgICAgICAgICAgIGlmIChhbGxDbGlwcy5sZW5ndGggPCBk
aXNrVG90YWwKICAgICAgICAgICAgICAgICYmIGxpc3RFbC5zY3JvbGxIZWlnaHQgPD0gbGlzdEVsLmNs
aWVudEhlaWdodCArIDIwKQogICAgICAgICAgICAgICAgcmVxdWVzdE1vcmUoKTsKICAgICAgICAgICAg
c2NoZWR1bGVGaWxlR29uZUNoZWNrKCk7CiAgICAgICAgfSk7CiAgICAgICAgcmV0dXJuIHRydWU7CiAg
ICB9CgogICAgLyoqIFBhaW50IERPTSBmb3IgZGF0YSBhbHJlYWR5IG1lcmdlZCBpbnRvIGFsbENsaXBz
IHdoaWxlIHRoZSB3aGVlbCB3YXMgbW92aW5nICovCiAgICBmdW5jdGlvbiBhcHBseUFwcGVuZFBheWxv
YWQocGVuZGluZykgewogICAgICAgIGlmICghcGVuZGluZyB8fCBwZW5kaW5nLmZyb21MZW4gPT0gbnVs
bCkgcmV0dXJuOwogICAgICAgIGNvbnN0IGZyb21MZW4gPSBOdW1iZXIocGVuZGluZy5mcm9tTGVuKSB8
fCAwOwogICAgICAgIGlmIChmcm9tTGVuIDwgMCB8fCBhbGxDbGlwcy5sZW5ndGggPD0gZnJvbUxlbikg
ewogICAgICAgICAgICByZWZyZXNoTGlzdENocm9tZSgpOwogICAgICAgICAgICByZXR1cm47CiAgICAg
ICAgfQogICAgICAgIGFwcGVuZFJlbmRlcihmcm9tTGVuKTsKICAgIH0KCiAgICBmdW5jdGlvbiBuYXZM
aXN0KCkgewogICAgICAgIGNvbnN0IGJsb2NrcyA9IGJ1aWxkUGlubmVkQmxvY2tzKHZpc2libGVMaXN0
KCkpOwogICAgICAgIGNvbnN0IG91dCA9IFtdOwogICAgICAgIGZvciAoY29uc3QgYiBvZiBibG9ja3Mp
IHsKICAgICAgICAgICAgaWYgKCFiIHx8ICFiLml0ZW1zKSBjb250aW51ZTsKICAgICAgICAgICAgZm9y
IChjb25zdCBjIG9mIGIuaXRlbXMpIG91dC5wdXNoKGMpOwogICAgICAgIH0KICAgICAgICByZXR1cm4g
b3V0OwogICAgfQoKICAgIGZ1bmN0aW9uIHNlbGVjdEJ5SW5kZXgoaWR4KSB7CiAgICAgICAgY29uc3Qg
dmlzID0gbmF2TGlzdCgpOwogICAgICAgIGlmICghdmlzLmxlbmd0aCkgcmV0dXJuOwogICAgICAgIGlk
eCA9IE1hdGgubWF4KDAsIE1hdGgubWluKHZpcy5sZW5ndGggLSAxLCBpZHgpKTsKICAgICAgICBpZiAo
aWR4ID49IHZpcy5sZW5ndGggLSAxICYmIGFsbENsaXBzLmxlbmd0aCA8IGRpc2tUb3RhbCkKICAgICAg
ICAgICAgcmVxdWVzdE1vcmUoKTsKICAgICAgICBzZWxlY3RlZElkID0gdmlzW01hdGgubWluKGlkeCwg
dmlzLmxlbmd0aCAtIDEpXS5pZDsKICAgICAgICByYW5nZUFuY2hvcklkID0gc2VsZWN0ZWRJZDsKICAg
ICAgICByYW5nZUFuY2hvckNsaWNrZWQgPSBmYWxzZTsKICAgICAgICBpZiAoK3NlbGVjdGVkSWQgIT09
ICtsYXN0UGFzdGVJZCkKICAgICAgICAgICAgbG9jYXRlQWN0aXZlID0gZmFsc2U7CiAgICAgICAgdXBk
YXRlTG9jYXRlQnRuKCk7CiAgICAgICAgc3luY0l0ZW1IaWdobGlnaHQoKTsKICAgICAgICBjb25zdCBl
bCA9IGxpc3RFbC5xdWVyeVNlbGVjdG9yKCcubWctcm93W2RhdGEtaWQ9IicgKyBzZWxlY3RlZElkICsg
JyJdJykKICAgICAgICAgICAgfHwgbGlzdEVsLnF1ZXJ5U2VsZWN0b3IoJy5pdG1bZGF0YS1pZD0iJyAr
IHNlbGVjdGVkSWQgKyAnIl0nKTsKICAgICAgICBpZiAoZWwpIGVsLnNjcm9sbEludG9WaWV3KHsgYmxv
Y2s6ICduZWFyZXN0JyB9KTsKICAgIH0KCiAgICBmdW5jdGlvbiBzZWxlY3RlZEluZGV4KCkgewogICAg
ICAgIHJldHVybiBuYXZMaXN0KCkuZmluZEluZGV4KGMgPT4gYy5pZCA9PSBzZWxlY3RlZElkKTsKICAg
IH0KCiAgICBmdW5jdGlvbiBzeW5jSXRlbUhpZ2hsaWdodCgpIHsKICAgICAgICBjb25zdCBtdWx0aU9u
ID0gbXVsdGlJZHMubGVuZ3RoID4gMDsKICAgICAgICBjb25zdCBpbk11bHRpSWQgPSBpZCA9PiBtdWx0
aUlkcy5zb21lKHggPT4gK3ggPT09ICtpZCk7CiAgICAgICAgZG9jdW1lbnQucXVlcnlTZWxlY3RvckFs
bCgnLml0bScpLmZvckVhY2gobiA9PiB7CiAgICAgICAgICAgIGlmIChuLmNsYXNzTGlzdC5jb250YWlu
cygnaXQtZ3JvdXAnKSkgewogICAgICAgICAgICAgICAgY29uc3Qgcm93cyA9IFsuLi5uLnF1ZXJ5U2Vs
ZWN0b3JBbGwoJy5tZy1yb3cnKV07CiAgICAgICAgICAgICAgICBjb25zdCBpZHMgPSByb3dzLm1hcChy
ID0+ICtyLmRhdGFzZXQuaWQpOwogICAgICAgICAgICAgICAgY29uc3QgYW55U2VsID0gbXVsdGlPbgog
ICAgICAgICAgICAgICAgICAgID8gaWRzLnNvbWUoaWQgPT4gaW5NdWx0aUlkKGlkKSkKICAgICAgICAg
ICAgICAgICAgICA6IGlkcy5pbmNsdWRlcygrc2VsZWN0ZWRJZCk7CiAgICAgICAgICAgICAgICBuLmNs
YXNzTGlzdC50b2dnbGUoJ3NlbCcsIGFueVNlbCk7CiAgICAgICAgICAgICAgICBuLmNsYXNzTGlzdC50
b2dnbGUoJ211bHRpJywgaWRzLnNvbWUoaWQgPT4gaW5NdWx0aUlkKGlkKSkpOwogICAgICAgICAgICAg
ICAgcm93cy5mb3JFYWNoKHIgPT4gewogICAgICAgICAgICAgICAgICAgIGNvbnN0IGlkID0gK3IuZGF0
YXNldC5pZDsKICAgICAgICAgICAgICAgICAgICBjb25zdCBpbk11bHRpID0gaW5NdWx0aUlkKGlkKTsK
ICAgICAgICAgICAgICAgICAgICBjb25zdCBzaG93U2VsID0gbXVsdGlPbiA/IGluTXVsdGkgOiAoaWQg
PT0gc2VsZWN0ZWRJZCk7CiAgICAgICAgICAgICAgICAgICAgci5jbGFzc0xpc3QudG9nZ2xlKCdzZWwn
LCBzaG93U2VsKTsKICAgICAgICAgICAgICAgICAgICByLmNsYXNzTGlzdC50b2dnbGUoJ211bHRpJywg
aW5NdWx0aSk7CiAgICAgICAgICAgICAgICB9KTsKICAgICAgICAgICAgICAgIHJldHVybjsKICAgICAg
ICAgICAgfQogICAgICAgICAgICBjb25zdCBpZCA9ICtuLmRhdGFzZXQuaWQ7CiAgICAgICAgICAgIGNv
bnN0IGluTXVsdGkgPSBpbk11bHRpSWQoaWQpOwogICAgICAgICAgICBjb25zdCBzaG93U2VsID0gbXVs
dGlPbiA/IGluTXVsdGkgOiAoaWQgPT0gc2VsZWN0ZWRJZCk7CiAgICAgICAgICAgIG4uY2xhc3NMaXN0
LnRvZ2dsZSgnc2VsJywgc2hvd1NlbCk7CiAgICAgICAgICAgIG4uY2xhc3NMaXN0LnRvZ2dsZSgnbXVs
dGknLCBpbk11bHRpKTsKICAgICAgICB9KTsKICAgIH0KICAgIGZ1bmN0aW9uIHVwZGF0ZU11bHRpQmFk
Z2UoKSB7CiAgICAgICAgY29uc3QgYmFyID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ211bHRpLWJh
cicpOwogICAgICAgIGNvbnN0IGVsID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ211bHRpLWNudCcp
OwogICAgICAgIGNvbnN0IG9uID0gbXVsdGlJZHMubGVuZ3RoID4gMDsKICAgICAgICBpZiAob24pIHsK
ICAgICAgICAgICAgaWYgKCFtdWx0aUJhcldhc09uKSByZXNldFBhc3RlU2VwRGVmYXVsdCgpOwogICAg
ICAgICAgICBlbC50ZXh0Q29udGVudCA9ICflt7LpgIknICsgbXVsdGlJZHMubGVuZ3RoOwogICAgICAg
ICAgICBiYXIuY2xhc3NMaXN0LmFkZCgnb24nKTsKICAgICAgICB9IGVsc2UgewogICAgICAgICAgICBi
YXIuY2xhc3NMaXN0LnJlbW92ZSgnb24nKTsKICAgICAgICAgICAgY2xvc2VTZXBNZW51KCk7CiAgICAg
ICAgfQogICAgICAgIG11bHRpQmFyV2FzT24gPSBvbjsKICAgICAgICBzeW5jSXRlbUhpZ2hsaWdodCgp
OwogICAgfQoKICAgIGZ1bmN0aW9uIGNsZWFyTXVsdGkocmVzdG9yZVRvQW5jaG9yKSB7CiAgICAgICAg
Y29uc3QgYmFja0lkID0gK3JhbmdlQW5jaG9ySWQgfHwgMDsKICAgICAgICBtdWx0aUlkcyA9IFtdOwog
ICAgICAgIGlmIChyZXN0b3JlVG9BbmNob3IgJiYgYmFja0lkKQogICAgICAgICAgICBzZWxlY3RlZElk
ID0gYmFja0lkOwogICAgICAgIHJhbmdlQW5jaG9ySWQgPSBzZWxlY3RlZElkIHx8IDA7CiAgICAgICAg
cmFuZ2VBbmNob3JDbGlja2VkID0gZmFsc2U7CiAgICAgICAgdXBkYXRlTXVsdGlCYWRnZSgpOwogICAg
ICAgIGlmIChyZXN0b3JlVG9BbmNob3IgJiYgc2VsZWN0ZWRJZCkgewogICAgICAgICAgICBjb25zdCBl
bCA9IGxpc3RFbC5xdWVyeVNlbGVjdG9yKCcubWctcm93W2RhdGEtaWQ9IicgKyBzZWxlY3RlZElkICsg
JyJdJykKICAgICAgICAgICAgICAgIHx8IGxpc3RFbC5xdWVyeVNlbGVjdG9yKCcuaXRtW2RhdGEtaWQ9
IicgKyBzZWxlY3RlZElkICsgJyJdJyk7CiAgICAgICAgICAgIGlmIChlbCkgZWwuc2Nyb2xsSW50b1Zp
ZXcoeyBibG9jazogJ25lYXJlc3QnIH0pOwogICAgICAgIH0KICAgIH0KCgogICAgLyogc2hpZnQtcmFu
Z2Utc2VsZWN0LXYxICovCiAgICBsZXQgcmFuZ2VBbmNob3JJZCA9IDA7CiAgICBsZXQgcmFuZ2VBbmNo
b3JDbGlja2VkID0gZmFsc2U7CgogICAgZnVuY3Rpb24gZ2V0Rmlyc3RTZWxlY3RlZExpc3RJZChsaXN0
KSB7CiAgICAgICAgY29uc3QgcGlja2VkID0gbmV3IFNldCgpOwogICAgICAgIGlmIChzZWxlY3RlZElk
KSBwaWNrZWQuYWRkKCtzZWxlY3RlZElkKTsKICAgICAgICBmb3IgKGNvbnN0IGlkIG9mIG11bHRpSWRz
KSBwaWNrZWQuYWRkKCtpZCk7CiAgICAgICAgaWYgKCFwaWNrZWQuc2l6ZSkgcmV0dXJuIDA7CiAgICAg
ICAgZm9yIChjb25zdCBjIG9mIGxpc3QpIHsKICAgICAgICAgICAgaWYgKHBpY2tlZC5oYXMoK2MuaWQp
KSByZXR1cm4gK2MuaWQ7CiAgICAgICAgfQogICAgICAgIHJldHVybiAwOwogICAgfQoKICAgIGZ1bmN0
aW9uIHNlbGVjdFJhbmdlVG8oaWQpIHsKICAgICAgICBpZCA9ICtpZDsKICAgICAgICBjb25zdCBsaXN0
ID0gKHR5cGVvZiBuYXZMaXN0ID09PSAnZnVuY3Rpb24nID8gbmF2TGlzdCgpIDogdmlzaWJsZUxpc3Qo
KSk7CiAgICAgICAgY29uc3QgYiA9IGxpc3QuZmluZEluZGV4KGMgPT4gK2MuaWQgPT09IGlkKTsKICAg
ICAgICBpZiAoYiA8IDApIHJldHVybjsKICAgICAgICBsZXQgYW5jaG9yID0gK3JhbmdlQW5jaG9ySWQ7
CiAgICAgICAgbGV0IGEgPSBsaXN0LmZpbmRJbmRleChjID0+ICtjLmlkID09PSBhbmNob3IpOwogICAg
ICAgIGlmIChhIDwgMCkgewogICAgICAgICAgICBhbmNob3IgPSBnZXRGaXJzdFNlbGVjdGVkTGlzdElk
KGxpc3QpIHx8ICtzZWxlY3RlZElkIHx8IGlkOwogICAgICAgICAgICBhID0gbGlzdC5maW5kSW5kZXgo
YyA9PiArYy5pZCA9PT0gYW5jaG9yKTsKICAgICAgICB9CiAgICAgICAgaWYgKGEgPCAwKSB7CiAgICAg
ICAgICAgIHJhbmdlQW5jaG9ySWQgPSBpZDsgc2VsZWN0ZWRJZCA9IGlkOyBtdWx0aUlkcyA9IFtpZF07
IHVwZGF0ZU11bHRpQmFkZ2UoKTsgcmV0dXJuOwogICAgICAgIH0KICAgICAgICByYW5nZUFuY2hvcklk
ID0gK2xpc3RbYV0uaWQ7CiAgICAgICAgY29uc3QgbG8gPSBNYXRoLm1pbihhLCBiKSwgaGkgPSBNYXRo
Lm1heChhLCBiKTsKICAgICAgICBtdWx0aUlkcyA9IFtdOwogICAgICAgIGZvciAobGV0IGkgPSBsbzsg
aSA8PSBoaTsgaSsrKSBtdWx0aUlkcy5wdXNoKCtsaXN0W2ldLmlkKTsKICAgICAgICBzZWxlY3RlZElk
ID0gaWQ7CiAgICAgICAgdXBkYXRlTXVsdGlCYWRnZSgpOwogICAgICAgIGNvbnN0IGVsID0gbGlzdEVs
LnF1ZXJ5U2VsZWN0b3IoJy5tZy1yb3dbZGF0YS1pZD0iJyArIHNlbGVjdGVkSWQgKyAnIl0nKSB8fCBs
aXN0RWwucXVlcnlTZWxlY3RvcignLml0bVtkYXRhLWlkPSInICsgc2VsZWN0ZWRJZCArICciXScpOwog
ICAgICAgIGlmIChlbCkgZWwuc2Nyb2xsSW50b1ZpZXcoeyBibG9jazogJ25lYXJlc3QnIH0pOwogICAg
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
eSkgd2luZG93Ll9faW1nSG92ZXJIaWRlKCk7IH0sIDcwKTsKICAgICAgICB9KTsKICAgIH0KICAgIGZ1
bmN0aW9uIGhhbmRsZUl0ZW1DbGljayhlLCBjKSB7CiAgICAgICAgaWYgKGUuc2hpZnRLZXkpIHsKICAg
ICAgICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOyBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgICAgICAg
ICBjb25zdCBsaXN0ID0gKHR5cGVvZiBuYXZMaXN0ID09PSAnZnVuY3Rpb24nID8gbmF2TGlzdCgpIDog
dmlzaWJsZUxpc3QoKSk7CiAgICAgICAgICAgIGNvbnN0IGZpcnN0U2VsID0gZ2V0Rmlyc3RTZWxlY3Rl
ZExpc3RJZChsaXN0KTsKICAgICAgICAgICAgaWYgKGZpcnN0U2VsKSByYW5nZUFuY2hvcklkID0gZmly
c3RTZWw7CiAgICAgICAgICAgIGVsc2UgaWYgKCFyYW5nZUFuY2hvcklkIHx8ICFsaXN0LnNvbWUoeCA9
PiAreC5pZCA9PT0gK3JhbmdlQW5jaG9ySWQpKQogICAgICAgICAgICAgICAgcmFuZ2VBbmNob3JJZCA9
IHNlbGVjdGVkSWQgfHwgYy5pZDsKICAgICAgICAgICAgcmFuZ2VBbmNob3JDbGlja2VkID0gdHJ1ZTsK
ICAgICAgICAgICAgc2VsZWN0UmFuZ2VUbyhjLmlkKTsKICAgICAgICAgICAgcmV0dXJuIHRydWU7CiAg
ICAgICAgfQogICAgICAgIGlmIChlLmN0cmxLZXkgfHwgZS5tZXRhS2V5KSB7CiAgICAgICAgICAgIGUu
cHJldmVudERlZmF1bHQoKTsgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICAgICAgdG9nZ2xlTXVs
dGkoYy5pZCk7CiAgICAgICAgICAgIHJldHVybiB0cnVlOwogICAgICAgIH0KICAgICAgICByYW5nZUFu
Y2hvcklkID0gYy5pZDsKICAgICAgICByYW5nZUFuY2hvckNsaWNrZWQgPSB0cnVlOwogICAgICAgIHJl
dHVybiBmYWxzZTsKICAgIH0KICAgIGZ1bmN0aW9uIHRvZ2dsZU11bHRpKGlkKSB7CiAgICAgICAgaWQg
PSAraWQ7CiAgICAgICAgY29uc3QgaSA9IG11bHRpSWRzLmZpbmRJbmRleCh4ID0+ICt4ID09PSBpZCk7
CiAgICAgICAgaWYgKGkgPj0gMCkgewogICAgICAgICAgICBtdWx0aUlkcy5zcGxpY2UoaSwgMSk7CiAg
ICAgICAgICAgIGlmICgrc2VsZWN0ZWRJZCA9PT0gaWQpCiAgICAgICAgICAgICAgICBzZWxlY3RlZElk
ID0gbXVsdGlJZHMubGVuZ3RoID8gK211bHRpSWRzW211bHRpSWRzLmxlbmd0aCAtIDFdIDogaWQ7CiAg
ICAgICAgfSBlbHNlIHsKICAgICAgICAgICAgaWYgKCFtdWx0aUlkcy5sZW5ndGgpIHJhbmdlQW5jaG9y
SWQgPSBpZDsKICAgICAgICAgICAgbXVsdGlJZHMucHVzaChpZCk7CiAgICAgICAgICAgIHNlbGVjdGVk
SWQgPSBpZDsKICAgICAgICB9CiAgICAgICAgcmFuZ2VBbmNob3JDbGlja2VkID0gdHJ1ZTsKICAgICAg
ICB1cGRhdGVNdWx0aUJhZGdlKCk7CiAgICB9CgogICAgZnVuY3Rpb24gcmVuZGVyKCkgewogICAgICAg
IGhpZGVQYXRoVGlwKCk7CgogICAgICAgIGNvbnN0IHZpc2libGUgPSB2aXNpYmxlTGlzdCgpOwogICAg
ICAgIGNvbnN0IGxvYWRlZCA9IGFsbENsaXBzLmxlbmd0aDsKICAgICAgICBjb25zdCBzaG93bkNvdW50
ID0gdmlzaWJsZS5sZW5ndGg7CiAgICAgICAgLy8g5pS26JeP6KeS5qCH77ya55SoIEFISyDkuIvlj5Hn
moTmgLvmlbDvvIzpgb/lhY3jgIzlvZPliY3pobXph4zmlbDlh7rmnaXnmoTjgI3lkowgYmFyIOWvueS4
jeS4igogICAgICAgIGxldCBwaW5uZWROID0gTnVtYmVyKHBpbm5lZFRvdGFsKSB8fCAwOwogICAgICAg
IGlmIChwaW5uZWROIDwgMSkgewogICAgICAgICAgICBpZiAoY3VyVGFiID09PSAncGlubmVkJykKICAg
ICAgICAgICAgICAgIHBpbm5lZE4gPSBNYXRoLm1heChOdW1iZXIoZGlza1RvdGFsKSB8fCAwLCBsb2Fk
ZWQpOwogICAgICAgICAgICBlbHNlCiAgICAgICAgICAgICAgICBwaW5uZWROID0gYWxsQ2xpcHMuZmls
dGVyKGMgPT4gaXNQaW5uZWQoYykpLmxlbmd0aDsKICAgICAgICB9CiAgICAgICAgY29uc3QgcGluQ250
ICA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdwaW4tY250Jyk7CiAgICAgICAgcGluQ250LnRleHRD
b250ZW50ICAgPSBwaW5uZWROOwogICAgICAgIHBpbkNudC5zdHlsZS5kaXNwbGF5ID0gcGlubmVkTiA/
ICcnIDogJ25vbmUnOwogICAgICAgIC8vIOaUtuiXjyB0YWLvvJpiYXIg5LiO6KeS5qCH5ZCM5LiA5aWX
5oC75pWw77yb5pyq5ruh6aG15pe25pi+56S6IOW3suWKoOi9vS/mgLvmlbAKICAgICAgICBsZXQgc2hv
d1RvdGFsID0gZGlza1RvdGFsID4gMCA/IGRpc2tUb3RhbCA6IChsb2FkZWQgfHwgMCk7CiAgICAgICAg
aWYgKGN1clRhYiA9PT0gJ3Bpbm5lZCcgJiYgcGlubmVkTiA+IHNob3dUb3RhbCkKICAgICAgICAgICAg
c2hvd1RvdGFsID0gcGlubmVkTjsKICAgICAgICBjb25zdCBxT24gPSBTdHJpbmcocXVlcnkgfHwgJycp
LnRyaW0oKS5sZW5ndGggPiAwOwogICAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdiYXItdHh0
JykudGV4dENvbnRlbnQgPSBxT24KICAgICAgICAgICAgPyAoc2hvd25Db3VudCArICcg5p2hJykKICAg
ICAgICAgICAgOiAoc2hvd1RvdGFsID4gbG9hZGVkID8gKHNob3duQ291bnQgKyAnIC8gJyArIHNob3dU
b3RhbCArICcg5p2hJykgOiAoc2hvd1RvdGFsICsgJyDmnaEnKSk7CiAgICAgICAgZG9jdW1lbnQuZ2V0
RWxlbWVudEJ5SWQoJ2VtcHR5LXR4dCcpLnRleHRDb250ZW50ID0gRU1QVFlfTVNHW2N1clRhYl0gfHwg
RU1QVFlfTVNHLmFsbDsKCiAgICAgICAgY29uc3QgaWRTZXQgPSBuZXcgU2V0KGFsbENsaXBzLm1hcChj
ID0+ICtjLmlkKSk7CiAgICAgICAgbXVsdGlJZHMgPSBtdWx0aUlkcy5maWx0ZXIoaWQgPT4gaWRTZXQu
aGFzKGlkKSk7CiAgICAgICAgdXBkYXRlTXVsdGlCYWRnZSgpOwoKICAgICAgICBjb25zdCBzaG93biA9
IHZpc2libGU7CgogICAgICAgIGxpc3RFbC5xdWVyeVNlbGVjdG9yQWxsKCcuaXRtLCAjbGlzdC1tb3Jl
JykuZm9yRWFjaChlID0+IGUucmVtb3ZlKCkpOwogICAgICAgIGlmIChib290TG9hZGluZykgewogICAg
ICAgICAgICBpZiAoc2tlbEVsKSBza2VsRWwuY2xhc3NMaXN0LmFkZCgnb24nKTsKICAgICAgICAgICAg
ZW1wdHlFbC5jbGFzc0xpc3QucmVtb3ZlKCdvbicpOwogICAgICAgICAgICB1cGRhdGVUb3BCdG4oKTsK
ICAgICAgICAgICAgcmV0dXJuOwogICAgICAgIH0KICAgICAgICAvLyBXYWl0aW5nIGZvciBmaXJzdCBk
YXRhLCBvciBob3N0IG5ldmVyIGNvbmZpcm1lZCDigJRkb24ndCBmbGFzaOOAjOaaguaXoOiusOW9leOA
jQogICAgICAgIGlmICgod2FpdGluZ0RhdGEgfHwgIWhvc3RQdXNoZWRPbmNlKSAmJiAhdmlzaWJsZS5s
ZW5ndGgpIHsKICAgICAgICAgICAgLy8gS2VlcCBza2VsZXRvbiBpZiBhbHJlYWR5IG9uOyBuZXZlciBz
dHJpcCBpdCB3aGlsZSB3YWl0aW5nCiAgICAgICAgICAgIGlmIChza2VsRWwgJiYgc2tlbEVsLmNsYXNz
TGlzdC5jb250YWlucygnb24nKSkgewogICAgICAgICAgICAgICAgZW1wdHlFbC5jbGFzc0xpc3QucmVt
b3ZlKCdvbicpOwogICAgICAgICAgICAgICAgdXBkYXRlVG9wQnRuKCk7CiAgICAgICAgICAgICAgICBy
ZXR1cm47CiAgICAgICAgICAgIH0KICAgICAgICAgICAgaWYgKHNrZWxFbCkgc2tlbEVsLmNsYXNzTGlz
dC5yZW1vdmUoJ29uJyk7CiAgICAgICAgICAgIGNvbnN0IHFXYWl0ID0gU3RyaW5nKHF1ZXJ5IHx8ICcn
KS50cmltKCkubGVuZ3RoID4gMDsKICAgICAgICAgICAgaWYgKHFXYWl0ICYmICFob3N0UHVzaGVkT25j
ZSkgewogICAgICAgICAgICAgICAgaWYgKHNrZWxFbCkgc2tlbEVsLmNsYXNzTGlzdC5hZGQoJ29uJyk7
CiAgICAgICAgICAgICAgICBlbXB0eUVsLmNsYXNzTGlzdC5yZW1vdmUoJ29uJyk7CiAgICAgICAgICAg
ICAgICB1cGRhdGVUb3BCdG4oKTsKICAgICAgICAgICAgICAgIHJldHVybjsKICAgICAgICAgICAgfQog
ICAgICAgICAgICBlbXB0eUVsLmNsYXNzTGlzdC5yZW1vdmUoJ29uJyk7CiAgICAgICAgICAgIHVwZGF0
ZVRvcEJ0bigpOwogICAgICAgICAgICByZXR1cm47CiAgICAgICAgfQogICAgICAgIGlmIChza2VsRWwp
IHNrZWxFbC5jbGFzc0xpc3QucmVtb3ZlKCdvbicpOwogICAgICAgIGlmICghdmlzaWJsZS5sZW5ndGgp
IHsKICAgICAgICAgICAgLy8gTmV2ZXIgc2hvd+OAjOaaguaXoOiusOW9leOAjXVudGlsIHdlIGhhdmUg
c2VlbiBhIHJlYWwgbm9uLWVtcHR5IHB1c2gsCiAgICAgICAgICAgIC8vIG9yIGEgY29uZmlybWVkIGVt
cHR5IGFmdGVyIHdhcm0gKHNhd05vbkVtcHR5IGNhbiBiZSBzZXQgYnkgZW1wdHktZmFsbGJhY2spLgog
ICAgICAgICAgICAvLyBGaWx0ZXJlZCBzZWFyY2ggd2l0aCAwIGhpdHMgaXMgYWxsb3dlZCBvbmNlIGhv
c3QgcHVzaGVkLgogICAgICAgICAgICBjb25zdCBxT24gPSBTdHJpbmcocXVlcnkgfHwgJycpLnRyaW0o
KS5sZW5ndGggPiAwOwogICAgICAgICAgICBjb25zdCBhbGxvd0VtcHR5ID0gaG9zdFB1c2hlZE9uY2Ug
JiYgc2F3Tm9uRW1wdHkgJiYgIXdhaXRpbmdEYXRhICYmICFib290TG9hZGluZwogICAgICAgICAgICAg
ICAgJiYgKHFPbiB8fCBkaXNrVG90YWwgPD0gMCk7CiAgICAgICAgICAgIGlmICghYWxsb3dFbXB0eSkg
ewogICAgICAgICAgICAgICAgZW1wdHlFbC5jbGFzc0xpc3QucmVtb3ZlKCdvbicpOwogICAgICAgICAg
ICAgICAgLy8gUHJlZmVyIHNrZWxldG9uIG92ZXIgYmxhbmsgd2hpbGUgc3RpbGwgYm9vdHN0cmFwcGlu
ZwogICAgICAgICAgICAgICAgaWYgKCFob3N0UHVzaGVkT25jZSB8fCB3YWl0aW5nRGF0YSkgewogICAg
ICAgICAgICAgICAgICAgIGlmIChza2VsRWwpIHNrZWxFbC5jbGFzc0xpc3QuYWRkKCdvbicpOwogICAg
ICAgICAgICAgICAgICAgIGNvbnN0IGFwcCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdhcHAnKTsK
ICAgICAgICAgICAgICAgICAgICBpZiAoYXBwKSBhcHAuY2xhc3NMaXN0LmFkZCgnYm9vdC1sb2FkaW5n
Jyk7CiAgICAgICAgICAgICAgICAgICAgYm9vdExvYWRpbmcgPSB0cnVlOwogICAgICAgICAgICAgICAg
fQogICAgICAgICAgICAgICAgdXBkYXRlVG9wQnRuKCk7CiAgICAgICAgICAgICAgICByZXR1cm47CiAg
ICAgICAgICAgIH0KICAgICAgICAgICAgaWYgKHNlbGVjdEZpcnN0T25TaG93KSB7CiAgICAgICAgICAg
ICAgICBzZWxlY3RGaXJzdE9uU2hvdyA9IGZhbHNlOwogICAgICAgICAgICAgICAgc2VsZWN0ZWRJZCA9
IDA7CiAgICAgICAgICAgICAgICBjbGVhck11bHRpKCk7CiAgICAgICAgICAgICAgICBsaXN0RWwuc2Ny
b2xsVG9wID0gMDsKICAgICAgICAgICAgfQogICAgICAgICAgICBlbXB0eUVsLmNsYXNzTGlzdC5hZGQo
J29uJyk7CiAgICAgICAgICAgIHVwZGF0ZVRvcEJ0bigpOwogICAgICAgICAgICByZXR1cm47CiAgICAg
ICAgfQogICAgICAgIGVtcHR5RWwuY2xhc3NMaXN0LnJlbW92ZSgnb24nKTsKICAgICAgICBjb25zdCBm
cmFnID0gZG9jdW1lbnQuY3JlYXRlRG9jdW1lbnRGcmFnbWVudCgpOwogICAgICAgIGNvbnN0IGJsb2Nr
cyA9IGJ1aWxkUGlubmVkQmxvY2tzKHNob3duKTsKICAgICAgICBsZXQgbnVtID0gMDsKICAgICAgICBi
bG9ja3MuZm9yRWFjaChiID0+IHsKICAgICAgICAgICAgbnVtICs9IDE7CiAgICAgICAgICAgIGlmIChi
LmtpbmQgPT09ICdncm91cCcgJiYgYi5pdGVtcy5sZW5ndGggPiAxKQogICAgICAgICAgICAgICAgZnJh
Zy5hcHBlbmRDaGlsZChtYWtlR3JvdXBJdGVtKGIuaXRlbXMsIG51bSkpOwogICAgICAgICAgICBlbHNl
CiAgICAgICAgICAgICAgICBmcmFnLmFwcGVuZENoaWxkKG1ha2VJdGVtKGIuaXRlbXNbMF0sIG51bSkp
OwogICAgICAgIH0pOwogICAgICAgIGxpc3RFbC5hcHBlbmRDaGlsZChmcmFnKTsKICAgICAgICB1cGRh
dGVNb3JlRm9vdGVyKGRpc2tUb3RhbCk7CiAgICAgICAgaWYgKHNlbGVjdEZpcnN0T25TaG93KSB7CiAg
ICAgICAgICAgIHNlbGVjdEZpcnN0T25TaG93ID0gZmFsc2U7CiAgICAgICAgICAgIHNlbGVjdGVkSWQg
PSB2aXNpYmxlWzBdLmlkOwogICAgICAgICAgICBjbGVhck11bHRpKCk7CiAgICAgICAgICAgIGxpc3RF
bC5zY3JvbGxUb3AgPSAwOwogICAgICAgIH0gZWxzZSBpZiAoIXZpc2libGUuc29tZShjID0+IGMuaWQg
PT0gc2VsZWN0ZWRJZCkpIHsKICAgICAgICAgICAgc2VsZWN0ZWRJZCA9IHZpc2libGVbMF0uaWQ7CiAg
ICAgICAgICAgIHJhbmdlQW5jaG9ySWQgPSBzZWxlY3RlZElkOwogICAgICAgICAgICByYW5nZUFuY2hv
ckNsaWNrZWQgPSBmYWxzZTsKICAgICAgICB9IGVsc2UgaWYgKCFyYW5nZUFuY2hvcklkKSB7CiAgICAg
ICAgICAgIHJhbmdlQW5jaG9ySWQgPSBzZWxlY3RlZElkOwogICAgICAgIH0KICAgICAgICBzeW5jSXRl
bUhpZ2hsaWdodCgpOwogICAgICAgIHVwZGF0ZVRvcEJ0bigpOwogICAgICAgIGlmICh3aW5kb3cuX19w
ZW5kaW5nSnVtcElkKQogICAgICAgICAgICB0cnlDb250aW51ZUp1bXAoKTsKICAgICAgICByZXF1ZXN0
QW5pbWF0aW9uRnJhbWUoKCkgPT4gewogICAgICAgICAgICBpZiAoIXdpbmRvdy5fX3BlbmRpbmdKdW1w
SWQKICAgICAgICAgICAgICAgICYmIGFsbENsaXBzLmxlbmd0aCA8IGRpc2tUb3RhbAogICAgICAgICAg
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
ICAgICB9IGNhdGNoIHt9CiAgICB9CiAgICBmdW5jdGlvbiBhY3RpdmF0ZUNsaXBJdGVtKGMpIHsKICAg
ICAgICBpZiAoIWMpIHJldHVybjsKICAgICAgICBpZiAobm9ybVR5cGUoYy50eXBlKSA9PT0gJ3JlY2Vu
dCcpIHsKICAgICAgICAgICAgX19wcmVwUGFzdGUoKTsKICAgICAgICAgICAgc2VsZWN0ZWRJZCA9IGMu
aWQ7CiAgICAgICAgICAgIGlmIChtdWx0aUlkcy5sZW5ndGgpIGNsZWFyTXVsdGkoKTsKICAgICAgICAg
ICAgc3luY0l0ZW1IaWdobGlnaHQoKTsKICAgICAgICAgICAgY29uc3QgcGF0aCA9IFN0cmluZyhjLmRh
dGEgfHwgYy5wcmV2aWV3IHx8ICcnKTsKICAgICAgICAgICAgaWYgKHBhdGgpIGFoaygnb3BlbkRpcics
IHBhdGgpOwogICAgICAgICAgICByZXR1cm47CiAgICAgICAgfQogICAgICAgIG1hcmtQYXN0ZWRMb2Nh
bChjLmlkKTsKICAgICAgICBhaGsoJ3Bhc3RlJywgU3RyaW5nKGMuaWQpKTsKICAgIH0KICAgIGZ1bmN0
aW9uIHBhc3RlT25lKGMpIHsKICAgICAgICBfX3ByZXBQYXN0ZSgpOwogICAgICAgIHNlbGVjdGVkSWQg
PSBjLmlkOwogICAgICAgIGlmIChtdWx0aUlkcy5sZW5ndGgpIGNsZWFyTXVsdGkoKTsKICAgICAgICBz
eW5jSXRlbUhpZ2hsaWdodCgpOwogICAgICAgIGFjdGl2YXRlQ2xpcEl0ZW0oYyk7CiAgICB9CiAgICBm
dW5jdGlvbiBpc0l0ZW1DaHJvbWVUYXJnZXQodCkgewogICAgICAgIHJldHVybiAhISh0ICYmIHQuY2xv
c2VzdCAmJiB0LmNsb3Nlc3QoJy5pLWV4cGFuZC1idG4sIC5pLXNyYy1pY28sIC5tZy1zcmMsIC5mZC1i
dG4sIC5mZC1wYXRoLCAucmYtc2VnLCBidXR0b24sIGEsIGlucHV0JykpOwogICAgfQogICAgZnVuY3Rp
b24gYmVnaW5QYXN0ZUZyb21JdGVtKGUsIGMpIHsKICAgICAgICBpZiAoZS5idXR0b24gIT0gbnVsbCAm
JiBlLmJ1dHRvbiAhPT0gMCkgcmV0dXJuOwogICAgICAgIGlmIChpc0l0ZW1DaHJvbWVUYXJnZXQoZS50
YXJnZXQpKSByZXR1cm47CiAgICAgICAgaWYgKGhhbmRsZUl0ZW1DbGljayhlLCBjKSkKICAgICAgICAg
ICAgcmV0dXJuOwogICAgICAgIF9fcHJlcFBhc3RlKCk7CiAgICAgICAgc2VsZWN0ZWRJZCA9IGMuaWQ7
CiAgICAgICAgcmFuZ2VBbmNob3JJZCA9IGMuaWQ7CiAgICAgICAgaWYgKG11bHRpSWRzLmxlbmd0aCA+
IDAgJiYgbXVsdGlJZHMuaW5jbHVkZXMoK2MuaWQpKSB7CiAgICAgICAgICAgIGNvbnN0IGlkcyA9IG11
bHRpSWRzLnNsaWNlKCk7CiAgICAgICAgICAgIGNsZWFyTXVsdGkoKTsKICAgICAgICAgICAgaWYgKGlk
cy5zb21lKGlkID0+IHsKICAgICAgICAgICAgICAgIGNvbnN0IGl0ID0gYWxsQ2xpcHMuZmluZCh4ID0+
ICt4LmlkID09PSAraWQpOwogICAgICAgICAgICAgICAgcmV0dXJuIGl0ICYmIG5vcm1UeXBlKGl0LnR5
cGUpID09PSAncmVjZW50JzsKICAgICAgICAgICAgfSkpIHsKICAgICAgICAgICAgICAgIGNvbnN0IGZp
cnN0ID0gYWxsQ2xpcHMuZmluZCh4ID0+ICt4LmlkID09PSAraWRzWzBdKTsKICAgICAgICAgICAgICAg
IGlmIChmaXJzdCkgYWN0aXZhdGVDbGlwSXRlbShmaXJzdCk7CiAgICAgICAgICAgICAgICByZXR1cm47
CiAgICAgICAgICAgIH0KICAgICAgICAgICAgbWFya1Bhc3RlZExvY2FsKGlkcyk7CiAgICAgICAgICAg
IGlmIChpZHMubGVuZ3RoID4gMSkgcGFzdGVNYW55V2l0aFNlcChpZHMsIGZhbHNlKTsKICAgICAgICAg
ICAgZWxzZSBhaGsoJ3Bhc3RlJywgU3RyaW5nKGlkc1swXSkpOwogICAgICAgICAgICByZXR1cm47CiAg
ICAgICAgfQogICAgICAgIGlmIChtdWx0aUlkcy5sZW5ndGgpIGNsZWFyTXVsdGkoKTsKICAgICAgICBz
eW5jSXRlbUhpZ2hsaWdodCgpOwogICAgICAgIGFjdGl2YXRlQ2xpcEl0ZW0oYyk7CiAgICB9CiAgICBm
dW5jdGlvbiBtYWtlR3JvdXBJdGVtKGl0ZW1zLCBpZHgpIHsKICAgICAgICBjb25zdCBlbCA9IGRvY3Vt
ZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOwogICAgICAgIGVsLmNsYXNzTmFtZSA9ICdpdG0gaXQtZ3Jv
dXAnCiAgICAgICAgICAgICsgKGl0ZW1zLnNvbWUoYyA9PiArYy5pZCA9PT0gK3NlbGVjdGVkSWQpID8g
JyBzZWwnIDogJycpCiAgICAgICAgICAgICsgKGl0ZW1zLnNvbWUoYyA9PiBtdWx0aUlkcy5pbmNsdWRl
cygrYy5pZCkpID8gJyBtdWx0aScgOiAnJyk7CiAgICAgICAgZWwuZGF0YXNldC5ncm91cCA9IGZhdkdy
b3VwT2YoaXRlbXNbMF0pIHx8ICcnOwogICAgICAgIGVsLmRhdGFzZXQuaWQgPSBpdGVtc1swXS5pZDsK
CiAgICAgICAgY29uc3QgaGVhZCA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOwogICAgICAg
IGhlYWQuY2xhc3NOYW1lID0gJ21nLWhlYWQnOwogICAgICAgIGhlYWQuaW5uZXJIVE1MID0gJzxzcGFu
IGNsYXNzPSJtZy10YWciPuWQiOW5tjwvc3Bhbj48c3Bhbj4nICsgaXRlbXMubGVuZ3RoICsgJyDmnaEg
wrcg54K55Ye75Y2V5p2h57KY6LS0PC9zcGFuPic7CiAgICAgICAgZWwuYXBwZW5kQ2hpbGQoaGVhZCk7
CgogICAgICAgIGl0ZW1zLmZvckVhY2goYyA9PiB7CiAgICAgICAgICAgIGNvbnN0IHJvdyA9IGRvY3Vt
ZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOwogICAgICAgICAgICByb3cuY2xhc3NOYW1lID0gJ21nLXJv
dycKICAgICAgICAgICAgICAgICsgKCtzZWxlY3RlZElkID09PSArYy5pZCA/ICcgc2VsJyA6ICcnKQog
ICAgICAgICAgICAgICAgKyAobXVsdGlJZHMuaW5jbHVkZXMoK2MuaWQpID8gJyBtdWx0aScgOiAnJyk7
CiAgICAgICAgICAgIHJvdy5kYXRhc2V0LmlkID0gYy5pZDsKCiAgICAgICAgICAgIGNvbnN0IHRvcCA9
IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOwogICAgICAgICAgICB0b3AuY2xhc3NOYW1lID0g
J21nLXJvdy10b3AnOwogICAgICAgICAgICBjb25zdCBtYWluID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVu
dCgnZGl2Jyk7CiAgICAgICAgICAgIG1haW4uY2xhc3NOYW1lID0gJ21nLXJvdy1tYWluJzsKCiAgICAg
ICAgICAgIGNvbnN0IHRpdGxlID0gU3RyaW5nKGMuZmF2VGl0bGUgfHwgJycpLnRyaW0oKTsKICAgICAg
ICAgICAgaWYgKHRpdGxlKSB7CiAgICAgICAgICAgICAgICBjb25zdCB0ID0gZG9jdW1lbnQuY3JlYXRl
RWxlbWVudCgnZGl2Jyk7CiAgICAgICAgICAgICAgICB0LmNsYXNzTmFtZSA9ICdtZy10aXRsZSc7CiAg
ICAgICAgICAgICAgICBzZXRIbFRleHQodCwgdGl0bGUpOwogICAgICAgICAgICAgICAgbWFpbi5hcHBl
bmRDaGlsZCh0KTsKICAgICAgICAgICAgfQogICAgICAgICAgICBjb25zdCBib2R5ID0gZG9jdW1lbnQu
Y3JlYXRlRWxlbWVudCgnZGl2Jyk7CiAgICAgICAgICAgIGJvZHkuY2xhc3NOYW1lID0gJ21nLWJvZHkn
ICsgKG5vcm1UeXBlKGMudHlwZSkgPT09ICdpbWFnZScgPyAnIGltZycgOiAnJyk7CiAgICAgICAgICAg
IHNldEhsVGV4dChib2R5LCBjbGlwQ29udGVudFByZXZpZXcoYykpOwogICAgICAgICAgICBtYWluLmFw
cGVuZENoaWxkKGJvZHkpOwogICAgICAgICAgICB0b3AuYXBwZW5kQ2hpbGQobWFpbik7CgogICAgICAg
ICAgICBjb25zdCBzcmNJY28gPSBTdHJpbmcoYy5zcmNJY29uIHx8ICcnKTsKICAgICAgICAgICAgY29u
c3Qgc3JjRXhlID0gU3RyaW5nKGMuc3JjRXhlIHx8ICcnKTsKICAgICAgICAgICAgY29uc3Qgc3JjVGl0
bGUgPSBTdHJpbmcoYy5zcmNUaXRsZSB8fCAnJyk7CiAgICAgICAgICAgIGlmIChzcmNJY28pIHsKICAg
ICAgICAgICAgICAgIGNvbnN0IGltZyA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2ltZycpOwogICAg
ICAgICAgICAgICAgaW1nLmNsYXNzTmFtZSA9ICdtZy1zcmMnOwogICAgICAgICAgICAgICAgaW1nLnNy
YyA9IFNUT1JFX0JBU0UgKyBlbmNvZGVVUklDb21wb25lbnQoc3JjSWNvKTsKICAgICAgICAgICAgICAg
IGltZy5hbHQgPSAnJzsKICAgICAgICAgICAgICAgIGNvbnN0IHRpcFR4dCA9IHNyY1RpdGxlIHx8IHNy
Y0V4ZSB8fCAn5p2l5rqQJzsKICAgICAgICAgICAgICAgIGltZy50aXRsZSA9IHRpcFR4dDsKICAgICAg
ICAgICAgICAgIGltZy5vbmNsaWNrID0gZSA9PiB7IGUucHJldmVudERlZmF1bHQoKTsgZS5zdG9wUHJv
cGFnYXRpb24oKTsgc2hvd1NyY1RpcChpbWcsIHRpcFR4dCk7IH07CiAgICAgICAgICAgICAgICB0b3Au
YXBwZW5kQ2hpbGQoaW1nKTsKICAgICAgICAgICAgfQogICAgICAgICAgICByb3cuYXBwZW5kQ2hpbGQo
dG9wKTsKCiAgICAgICAgICAgIHJvdy5vbnBvaW50ZXJkb3duID0gZSA9PiB7CiAgICAgICAgICAgICAg
ICBpZiAoZS5idXR0b24gIT09IDApIHJldHVybjsKICAgICAgICAgICAgICAgIGUuc3RvcFByb3BhZ2F0
aW9uKCk7CiAgICAgICAgICAgICAgICBiZWdpblBhc3RlRnJvbUl0ZW0oZSwgYyk7CiAgICAgICAgICAg
IH07CiAgICAgICAgICAgIHJvdy5vbmNvbnRleHRtZW51ID0gZSA9PiB7CiAgICAgICAgICAgICAgICBl
LnByZXZlbnREZWZhdWx0KCk7CiAgICAgICAgICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAg
ICAgICAgICAgICAgc2VsZWN0ZWRJZCA9IGMuaWQ7CiAgICAgICAgICAgICAgICBzaG93Q3R4KGUuY2xp
ZW50WCwgZS5jbGllbnRZLCBjKTsKICAgICAgICAgICAgfTsKICAgICAgICAgICAgZWwuYXBwZW5kQ2hp
bGQocm93KTsKICAgICAgICB9KTsKCiAgICAgICAgZWwub25jb250ZXh0bWVudSA9IGUgPT4gewogICAg
ICAgICAgICBpZiAoZS50YXJnZXQuY2xvc2VzdCgnLm1nLXJvdycpKSByZXR1cm47CiAgICAgICAgICAg
IGUucHJldmVudERlZmF1bHQoKTsKICAgICAgICAgICAgc2VsZWN0ZWRJZCA9IGl0ZW1zWzBdLmlkOwog
ICAgICAgICAgICBzaG93Q3R4KGUuY2xpZW50WCwgZS5jbGllbnRZLCBpdGVtc1swXSk7CiAgICAgICAg
fTsKICAgICAgICByZXR1cm4gZWw7CiAgICB9CgogICAgZnVuY3Rpb24gYnVpbGRSZWNlbnRQYXRoQ3J1
bWJzKGNvbnRhaW5lciwgZnVsbFBhdGgpIHsKICAgICAgICBpZiAoIWNvbnRhaW5lcikgcmV0dXJuOwog
ICAgICAgIGNvbnRhaW5lci5yZXBsYWNlQ2hpbGRyZW4oKTsKICAgICAgICBjb25zdCByYXcgPSBTdHJp
bmcoZnVsbFBhdGggfHwgJycpLnJlcGxhY2UoL1wvL2csICdcXCcpLnJlcGxhY2UoL1xcKyQvLCAnJyk7
CiAgICAgICAgaWYgKCFyYXcpIHJldHVybjsKICAgICAgICBjb25zdCB1bmMgPSByYXcuc3RhcnRzV2l0
aCgnXFxcXCcpOwogICAgICAgIGxldCByZXN0ID0gdW5jID8gcmF3LnNsaWNlKDIpIDogcmF3OwogICAg
ICAgIGNvbnN0IHBhcnRzID0gcmVzdC5zcGxpdCgnXFwnKS5maWx0ZXIoQm9vbGVhbik7CiAgICAgICAg
aWYgKCFwYXJ0cy5sZW5ndGgpIHsKICAgICAgICAgICAgY29uc3Qgb25seSA9IGRvY3VtZW50LmNyZWF0
ZUVsZW1lbnQoJ3NwYW4nKTsKICAgICAgICAgICAgb25seS5jbGFzc05hbWUgPSAncmYtc2VnJzsKICAg
ICAgICAgICAgb25seS50ZXh0Q29udGVudCA9IHJhdzsKICAgICAgICAgICAgb25seS50aXRsZSA9IHJh
dzsKICAgICAgICAgICAgb25seS5vbnBvaW50ZXJkb3duID0gZSA9PiB7CiAgICAgICAgICAgICAgICAv
LyBMZWZ0IGNsaWNrIG9wZW5zIGZvbGRlcjsgcmlnaHQtY2xpY2sgbXVzdCBzaG93IGNvbnRleHQgbWVu
dSAobm90IG9wZW5EaXIpCiAgICAgICAgICAgICAgICBpZiAoZS5idXR0b24gIT09IDApIHJldHVybjsK
ICAgICAgICAgICAgICAgIGUucHJldmVudERlZmF1bHQoKTsgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAg
ICAgICAgICAgICAgIGFoaygnb3BlbkRpcicsIHJhdyk7CiAgICAgICAgICAgIH07CiAgICAgICAgICAg
IGNvbnRhaW5lci5hcHBlbmRDaGlsZChvbmx5KTsKICAgICAgICAgICAgcmV0dXJuOwogICAgICAgIH0K
ICAgICAgICBsZXQgYWNjID0gdW5jID8gJ1xcXFwnICsgcGFydHNbMF0gOiBwYXJ0c1swXTsKICAgICAg
ICAvLyBkcml2ZSByb290IGxpa2UgQzog4oCUIG9wZW4gcGF0aCBuZWVkcyB0cmFpbGluZyBcLCBsYWJl
bCBkb2VzIG5vdAogICAgICAgIGlmICghdW5jICYmIC9eW2EtekEtWl06JC8udGVzdChwYXJ0c1swXSkp
CiAgICAgICAgICAgIGFjYyA9IHBhcnRzWzBdICsgJ1xcJzsKICAgICAgICBjb25zdCBhZGRTZWcgPSAo
bGFiZWwsIG9wZW5QYXRoKSA9PiB7CiAgICAgICAgICAgIGlmIChjb250YWluZXIuY2hpbGROb2Rlcy5s
ZW5ndGgpIHsKICAgICAgICAgICAgICAgIGNvbnN0IHNlcCA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQo
J3NwYW4nKTsKICAgICAgICAgICAgICAgIHNlcC5jbGFzc05hbWUgPSAncmYtc2VwJzsKICAgICAgICAg
ICAgICAgIHNlcC50ZXh0Q29udGVudCA9ICdcXCc7CiAgICAgICAgICAgICAgICBjb250YWluZXIuYXBw
ZW5kQ2hpbGQoc2VwKTsKICAgICAgICAgICAgfQogICAgICAgICAgICBjb25zdCBzZWcgPSBkb2N1bWVu
dC5jcmVhdGVFbGVtZW50KCdzcGFuJyk7CiAgICAgICAgICAgIHNlZy5jbGFzc05hbWUgPSAncmYtc2Vn
JzsKICAgICAgICAgICAgc2V0SGxUZXh0KHNlZywgbGFiZWwpOwogICAgICAgICAgICBzZWcudGl0bGUg
PSBvcGVuUGF0aDsKICAgICAgICAgICAgc2VnLm9ucG9pbnRlcmRvd24gPSBlID0+IHsKICAgICAgICAg
ICAgICAgIC8vIExlZnQgY2xpY2sgb3BlbnMgZm9sZGVyOyByaWdodC1jbGljayBtdXN0IHNob3cgY29u
dGV4dCBtZW51IChub3Qgb3BlbkRpcikKICAgICAgICAgICAgICAgIGlmIChlLmJ1dHRvbiAhPT0gMCkg
cmV0dXJuOwogICAgICAgICAgICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOwogICAgICAgICAgICAgICAg
ZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICAgICAgICAgIGFoaygnb3BlbkRpcicsIG9wZW5QYXRo
KTsKICAgICAgICAgICAgfTsKICAgICAgICAgICAgY29udGFpbmVyLmFwcGVuZENoaWxkKHNlZyk7CiAg
ICAgICAgfTsKICAgICAgICBhZGRTZWcocGFydHNbMF0sIGFjYyk7CiAgICAgICAgZm9yIChsZXQgaSA9
IDE7IGkgPCBwYXJ0cy5sZW5ndGg7IGkrKykgewogICAgICAgICAgICBhY2MgPSBhY2MucmVwbGFjZSgv
XFwrJC8sICcnKSArICdcXCcgKyBwYXJ0c1tpXTsKICAgICAgICAgICAgYWRkU2VnKHBhcnRzW2ldLCBh
Y2MpOwogICAgICAgIH0KICAgIH0KCiAgICBmdW5jdGlvbiBtYWtlSXRlbShjLCBpZHgpIHsKICAgICAg
ICBjb25zdCB0eXBlICAgPSBub3JtVHlwZShjLnR5cGUpOwogICAgICAgIGNvbnN0IHBpbm5lZCA9IGlz
UGlubmVkKGMpOwogICAgICAgIGNvbnN0IHBhc3RlZCA9IGlzUGFzdGVkKGMpOwogICAgICAgIGNvbnN0
IGVsICAgICA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOwogICAgICAgIGVsLmNsYXNzTmFt
ZSAgPSAnaXRtJwogICAgICAgICAgICArIChzZWxlY3RlZElkID09IGMuaWQgPyAnIHNlbCcgOiAnJykK
ICAgICAgICAgICAgKyAobXVsdGlJZHMuaW5jbHVkZXMoK2MuaWQpID8gJyBtdWx0aScgOiAnJyk7CiAg
ICAgICAgZWwuZGF0YXNldC5pZCA9IGMuaWQ7CgogICAgICAgIGNvbnN0IGljbyAgPSBkb2N1bWVudC5j
cmVhdGVFbGVtZW50KCdkaXYnKTsKICAgICAgICBjb25zdCBib2R5ID0gZG9jdW1lbnQuY3JlYXRlRWxl
bWVudCgnZGl2Jyk7CiAgICAgICAgYm9keS5jbGFzc05hbWUgPSAnaS1ib2R5JzsKCiAgICAgICAgaWYg
KHR5cGUgPT09ICdpbWFnZScpIHsKICAgICAgICAgICAgaWNvLmNsYXNzTmFtZSA9ICdpLWljbyBpbWFn
ZSc7CiAgICAgICAgICAgIGljby5pbm5lckhUTUwgPSBTVkcuaW1hZ2U7CiAgICAgICAgICAgIGJpbmRJ
bWdIb3ZlclByZXZpZXcoaWNvLCBjLmlkLCBjLmltZ0ZpbGUpOwogICAgICAgICAgICBjb25zdCB3cmFw
ID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnZGl2Jyk7CiAgICAgICAgICAgIHdyYXAuY2xhc3NOYW1l
ID0gJ2ktdGh1bWItd3JhcCc7CiAgICAgICAgICAgIGNvbnN0IGltZyAgPSBkb2N1bWVudC5jcmVhdGVF
bGVtZW50KCdpbWcnKTsKICAgICAgICAgICAgaW1nLmNsYXNzTmFtZSA9ICdpLXRodW1iJzsKICAgICAg
ICAgICAgaW1nLmFsdCA9ICcnOwogICAgICAgICAgICBjb25zdCBmaWxlID0gU3RyaW5nKGMuaW1nRmls
ZSB8fCAnJyk7CiAgICAgICAgICAgIGxldCBmYWxsYmFjayA9IFN0cmluZyhjLmRhdGEgfHwgJycpOwog
ICAgICAgICAgICAvLyBOZXZlciBzeW5jLWNhbGwgQUhLIHRodW1iIGhlcmUg4oCUIGZyZWV6ZXMgdGFi
IHN3aXRjaGVzOyBQdXNoU3RvcmVUaHVtYnMgZmlsbHMgYXN5bmMKICAgICAgICAgICAgaWYgKCFmYWxs
YmFjay5zdGFydHNXaXRoKCdkYXRhOicpICYmIHRodW1iQ2FjaGUuaGFzKFN0cmluZyhjLmlkKSkpCiAg
ICAgICAgICAgICAgICBmYWxsYmFjayA9IFN0cmluZyh0aHVtYkNhY2hlLmdldChTdHJpbmcoYy5pZCkp
KTsKICAgICAgICAgICAgaW1nLm9ubG9hZCA9ICgpID0+IHsKICAgICAgICAgICAgICAgIGNvbnN0IG13
ID0gd3JhcC5jbGllbnRXaWR0aCB8fCAzMDA7CiAgICAgICAgICAgICAgICBjb25zdCBudyA9IGltZy5u
YXR1cmFsV2lkdGggIHx8IDA7CiAgICAgICAgICAgICAgICBjb25zdCBuaCA9IGltZy5uYXR1cmFsSGVp
Z2h0IHx8IDA7CiAgICAgICAgICAgICAgICBpZiAoIW53IHx8ICFuaCkgcmV0dXJuOwogICAgICAgICAg
ICAgICAgY29uc3Qgc2NhbGUgPSBNYXRoLm1pbigxLCAxODAgLyBuaCwgbXcgLyBudyk7CiAgICAgICAg
ICAgICAgICBpbWcuc3R5bGUud2lkdGggID0gTWF0aC5yb3VuZChudyAqIHNjYWxlKSArICdweCc7CiAg
ICAgICAgICAgICAgICBpbWcuc3R5bGUuaGVpZ2h0ID0gTWF0aC5yb3VuZChuaCAqIHNjYWxlKSArICdw
eCc7CiAgICAgICAgICAgIH07CiAgICAgICAgICAgIGJpbmRTdG9yZVRodW1iKGltZywgZmlsZSwgYy5p
ZCwgZmFsbGJhY2spOwogICAgICAgICAgICB3cmFwLmFwcGVuZENoaWxkKGltZyk7CiAgICAgICAgICAg
IGNvbnN0IG1ldGEgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsKICAgICAgICAgICAgbWV0
YS5jbGFzc05hbWUgPSAnaS1tZXRhJzsKICAgICAgICAgICAgbWV0YS5pbm5lckhUTUwgID0gYDxzcGFu
IGNsYXNzPSJpLXRpbWUiPiR7YWdvKGMudGltZSl9PC9zcGFuPiR7bWV0YUNlbnRlckh0bWwoZmFsc2Up
fTxkaXYgY2xhc3M9ImktbWV0YS1yaWdodCI+JHtjLndpZHRoID8gYDxzcGFuIGNsYXNzPSJpLXRhZyI+
JHtjLndpZHRofcOXJHtjLmhlaWdodH0gcHg8L3NwYW4+YCA6ICcnfTwvZGl2PmA7CiAgICAgICAgICAg
IGJvZHkuYXBwZW5kQ2hpbGQod3JhcCk7CiAgICAgICAgICAgIGJvZHkuYXBwZW5kQ2hpbGQobWV0YSk7
CiAgICAgICAgfSBlbHNlIGlmICh0eXBlID09PSAncmVjZW50JykgewogICAgICAgICAgICBpY28uY2xh
c3NOYW1lID0gJ2ktaWNvIGZpbGUgZnQtZGlyJzsKICAgICAgICAgICAgaWNvLmlubmVySFRNTCA9IFNW
Ry5mb2xkZXI7CiAgICAgICAgICAgIGNvbnN0IHBhdGggPSBTdHJpbmcoYy5kYXRhIHx8IGMucHJldmll
dyB8fCAnJyk7CiAgICAgICAgICAgIGNvbnN0IGNydW1icyA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQo
J2RpdicpOwogICAgICAgICAgICBjcnVtYnMuY2xhc3NOYW1lID0gJ3JmLXBhdGgnOwogICAgICAgICAg
ICBidWlsZFJlY2VudFBhdGhDcnVtYnMoY3J1bWJzLCBwYXRoKTsKICAgICAgICAgICAgY29uc3QgbWV0
YSA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOwogICAgICAgICAgICBtZXRhLmNsYXNzTmFt
ZSA9ICdpLW1ldGEnOwogICAgICAgICAgICBtZXRhLmlubmVySFRNTCA9CiAgICAgICAgICAgICAgICBg
PHNwYW4gY2xhc3M9ImktdGltZSI+JHthZ28oYy50aW1lKX08L3NwYW4+YCArCiAgICAgICAgICAgICAg
ICBtZXRhQ2VudGVySHRtbChmYWxzZSkgKwogICAgICAgICAgICAgICAgYDxkaXYgY2xhc3M9ImktbWV0
YS1yaWdodCI+JHtwaW5uZWQgPyAnPHNwYW4gY2xhc3M9ImktdGFnIj7lm7rlrpo8L3NwYW4+JyA6ICcn
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
CgogICAgICAgIGlmIChwYXN0ZWQpIHsKICAgICAgICAgICAgY29uc3QgYmFkZ2UgPSBkb2N1bWVudC5j
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
OwogICAgfQoKICAgIGNvbnN0IHBhdGhUaXBFbCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdwYXRo
LXRpcCcpOwogICAgbGV0IHBhdGhUaXBUaW1lciA9IDA7CiAgICBsZXQgcGF0aFRpcEhpZGVUaW1lciA9
IDA7CiAgICBsZXQgcGF0aFRpcFRva2VuID0gMDsKICAgIGxldCBwYXRoVGlwQW5jaG9yQnRuID0gbnVs
bDsKCiAgICBmdW5jdGlvbiBoaWRlUGF0aFRpcCgpIHsKICAgICAgICBjbGVhclRpbWVvdXQocGF0aFRp
cFRpbWVyKTsKICAgICAgICBjbGVhclRpbWVvdXQocGF0aFRpcEhpZGVUaW1lcik7CiAgICAgICAgcGF0
aFRpcFRva2VuKys7CiAgICAgICAgaWYgKHBhdGhUaXBBbmNob3JCdG4pIHsKICAgICAgICAgICAgcGF0
aFRpcEFuY2hvckJ0bi5jbGFzc0xpc3QucmVtb3ZlKCdvbicpOwogICAgICAgICAgICBwYXRoVGlwQW5j
aG9yQnRuID0gbnVsbDsKICAgICAgICB9CiAgICAgICAgaWYgKHBhdGhUaXBFbCkgewogICAgICAgICAg
ICBwYXRoVGlwRWwuY2xhc3NMaXN0LnJlbW92ZSgnb24nKTsKICAgICAgICAgICAgcGF0aFRpcEVsLnNl
dEF0dHJpYnV0ZSgnYXJpYS1oaWRkZW4nLCAndHJ1ZScpOwogICAgICAgIH0KICAgIH0KICAgIGZ1bmN0
aW9uIHBsYWNlUGF0aFRpcChhbmNob3JFbCkgewogICAgICAgIGlmICghcGF0aFRpcEVsIHx8ICFhbmNo
b3JFbCkgcmV0dXJuOwogICAgICAgIGNvbnN0IHRpcCA9IHBhdGhUaXBFbDsKICAgICAgICBjb25zdCBh
ciA9IGFuY2hvckVsLmdldEJvdW5kaW5nQ2xpZW50UmVjdCgpOwogICAgICAgIGNvbnN0IHBhZCA9IDg7
CiAgICAgICAgdGlwLnN0eWxlLmxlZnQgPSAnMHB4JzsKICAgICAgICB0aXAuc3R5bGUudG9wID0gJzBw
eCc7CiAgICAgICAgdGlwLmNsYXNzTGlzdC5hZGQoJ29uJyk7CiAgICAgICAgY29uc3QgdHcgPSB0aXAu
b2Zmc2V0V2lkdGg7CiAgICAgICAgY29uc3QgdGggPSB0aXAub2Zmc2V0SGVpZ2h0OwogICAgICAgIGxl
dCBsZWZ0ID0gYXIubGVmdDsKICAgICAgICBsZXQgdG9wID0gYXIuYm90dG9tICsgNjsKICAgICAgICBp
ZiAobGVmdCArIHR3ID4gd2luZG93LmlubmVyV2lkdGggLSBwYWQpCiAgICAgICAgICAgIGxlZnQgPSBN
YXRoLm1heChwYWQsIHdpbmRvdy5pbm5lcldpZHRoIC0gdHcgLSBwYWQpOwogICAgICAgIGlmIChsZWZ0
IDwgcGFkKSBsZWZ0ID0gcGFkOwogICAgICAgIGlmICh0b3AgKyB0aCA+IHdpbmRvdy5pbm5lckhlaWdo
dCAtIHBhZCkKICAgICAgICAgICAgdG9wID0gTWF0aC5tYXgocGFkLCBhci50b3AgLSB0aCAtIDYpOwog
ICAgICAgIHRpcC5zdHlsZS5sZWZ0ID0gbGVmdCArICdweCc7CiAgICAgICAgdGlwLnN0eWxlLnRvcCA9
IHRvcCArICdweCc7CiAgICB9CiAgICAgICAgZnVuY3Rpb24gY2hlY2tGaWxlUGF0aHMocGF0aHMpIHsK
ICAgICAgICBjb25zdCBsaXN0ID0gKHBhdGhzIHx8IFtdKS5tYXAocCA9PiB7CiAgICAgICAgICAgIGxl
dCBwYXRoID0gU3RyaW5nKHAgfHwgJycpLnRyaW0oKTsKICAgICAgICAgICAgaWYgKChwYXRoLnN0YXJ0
c1dpdGgoJyInKSAmJiBwYXRoLmVuZHNXaXRoKCciJykpIHx8IChwYXRoLnN0YXJ0c1dpdGgoIiciKSAm
JiBwYXRoLmVuZHNXaXRoKCInIikpKQogICAgICAgICAgICAgICAgcGF0aCA9IHBhdGguc2xpY2UoMSwg
LTEpLnRyaW0oKTsKICAgICAgICAgICAgcmV0dXJuIHBhdGg7CiAgICAgICAgfSk7CiAgICAgICAgLy8g
T25lIGhvc3Qgcm91bmQtdHJpcCBmb3IgdGhlIHdob2xlIGxpc3Qg4oCUIE7DlyBwYXRoRXhpc3RzIGZy
ZWV6ZXMgZmlsZSB0YWIKICAgICAgICB0cnkgewogICAgICAgICAgICBjb25zdCByYXcgPSBhaGtSZXQo
J2NoZWNrUGF0aHMnLCBsaXN0LmpvaW4oJ1xuJykpOwogICAgICAgICAgICBpZiAocmF3KSB7CiAgICAg
ICAgICAgICAgICBjb25zdCBwYXJzZWQgPSB0eXBlb2YgcmF3ID09PSAnc3RyaW5nJyA/IEpTT04ucGFy
c2UocmF3KSA6IHJhdzsKICAgICAgICAgICAgICAgIGlmIChBcnJheS5pc0FycmF5KHBhcnNlZCkgJiYg
cGFyc2VkLmxlbmd0aCkgewogICAgICAgICAgICAgICAgICAgIHJldHVybiBsaXN0Lm1hcCgocGF0aCwg
aSkgPT4gewogICAgICAgICAgICAgICAgICAgICAgICBjb25zdCByb3cgPSBwYXJzZWRbaV0gfHwge307
CiAgICAgICAgICAgICAgICAgICAgICAgIHJldHVybiB7CiAgICAgICAgICAgICAgICAgICAgICAgICAg
ICBwYXRoOiBwYXRoIHx8IFN0cmluZyhyb3cucGF0aCB8fCAnJyksCiAgICAgICAgICAgICAgICAgICAg
ICAgICAgICBleGlzdHM6IHJvdy5leGlzdHMgPT09IHRydWUgfHwgcm93LmV4aXN0cyA9PT0gMSB8fCBy
b3cuZXhpc3RzID09PSAnMScsCiAgICAgICAgICAgICAgICAgICAgICAgICAgICBpc0RpcjogISEocm93
LmlzRGlyID09PSB0cnVlIHx8IHJvdy5pc0RpciA9PT0gMSB8fCByb3cuaXNEaXIgPT09ICcxJykKICAg
ICAgICAgICAgICAgICAgICAgICAgfTsKICAgICAgICAgICAgICAgICAgICB9KTsKICAgICAgICAgICAg
ICAgIH0KICAgICAgICAgICAgfQogICAgICAgIH0gY2F0Y2gge30KICAgICAgICByZXR1cm4gbGlzdC5t
YXAocGF0aCA9PiB7CiAgICAgICAgICAgIGlmICghcGF0aCkgcmV0dXJuIHsgcGF0aCwgZXhpc3RzOiBm
YWxzZSwgaXNEaXI6IGZhbHNlIH07CiAgICAgICAgICAgIGxldCBleGlzdHMgPSBmYWxzZTsKICAgICAg
ICAgICAgdHJ5IHsKICAgICAgICAgICAgICAgIGNvbnN0IGZsYWcgPSBTdHJpbmcoYWhrUmV0KCdwYXRo
RXhpc3RzJywgcGF0aCkgPz8gJycpLnRyaW0oKS50b0xvd2VyQ2FzZSgpOwogICAgICAgICAgICAgICAg
ZXhpc3RzID0gKGZsYWcgPT09ICcxJyB8fCBmbGFnID09PSAndHJ1ZScpOwogICAgICAgICAgICB9IGNh
dGNoIHt9CiAgICAgICAgICAgIHJldHVybiB7IHBhdGgsIGV4aXN0cywgaXNEaXI6IGZhbHNlIH07CiAg
ICAgICAgfSk7CiAgICB9CiAgICBsZXQgZ29uZUNoZWNrVGltZXIgPSAwOwogICAgZnVuY3Rpb24gc2No
ZWR1bGVGaWxlR29uZUNoZWNrKCkgewogICAgICAgIGlmIChnb25lQ2hlY2tUaW1lcikgcmV0dXJuOwog
ICAgICAgIGdvbmVDaGVja1RpbWVyID0gc2V0VGltZW91dCgoKSA9PiB7CiAgICAgICAgICAgIGdvbmVD
aGVja1RpbWVyID0gMDsKICAgICAgICAgICAgY29uc3Qgbm9kZXMgPSBbLi4ubGlzdEVsLnF1ZXJ5U2Vs
ZWN0b3JBbGwoJy5pdG0nKV0uZmlsdGVyKG4gPT4gbi5fZmlsZVBhdGhzICYmIG4uX2ZpbGVQYXRocy5s
ZW5ndGgpOwogICAgICAgICAgICBpZiAoIW5vZGVzLmxlbmd0aCkgcmV0dXJuOwogICAgICAgICAgICBj
b25zdCB1bmlxdWUgPSBbXTsKICAgICAgICAgICAgY29uc3Qgc2VlbiA9IG5ldyBTZXQoKTsKICAgICAg
ICAgICAgbm9kZXMuZm9yRWFjaChuID0+IHsKICAgICAgICAgICAgICAgIG4uX2ZpbGVQYXRocy5mb3JF
YWNoKHAgPT4gewogICAgICAgICAgICAgICAgICAgIGNvbnN0IHBhdGggPSBTdHJpbmcocCB8fCAnJyk7
CiAgICAgICAgICAgICAgICAgICAgaWYgKCFwYXRoIHx8IHNlZW4uaGFzKHBhdGgpKSByZXR1cm47CiAg
ICAgICAgICAgICAgICAgICAgc2Vlbi5hZGQocGF0aCk7CiAgICAgICAgICAgICAgICAgICAgdW5pcXVl
LnB1c2gocGF0aCk7CiAgICAgICAgICAgICAgICB9KTsKICAgICAgICAgICAgfSk7CiAgICAgICAgICAg
IGNvbnN0IHJvd3MgPSBjaGVja0ZpbGVQYXRocyh1bmlxdWUpOwogICAgICAgICAgICBjb25zdCBieVBh
dGggPSBuZXcgTWFwKCk7CiAgICAgICAgICAgIHJvd3MuZm9yRWFjaChyID0+IGJ5UGF0aC5zZXQoU3Ry
aW5nKHIucGF0aCB8fCAnJyksIHIpKTsKICAgICAgICAgICAgbm9kZXMuZm9yRWFjaChuID0+IHsKICAg
ICAgICAgICAgICAgIGNvbnN0IHBhdGhSb3dzID0gbi5fZmlsZVBhdGhzLm1hcChwID0+IHsKICAgICAg
ICAgICAgICAgICAgICBjb25zdCBoaXQgPSBieVBhdGguZ2V0KFN0cmluZyhwIHx8ICcnKSk7CiAgICAg
ICAgICAgICAgICAgICAgcmV0dXJuIGhpdCB8fCB7IHBhdGg6IHAsIGV4aXN0czogdHJ1ZSwgaXNEaXI6
IGZhbHNlIH07CiAgICAgICAgICAgICAgICB9KTsKICAgICAgICAgICAgICAgIG4uX3BhdGhSb3dzID0g
cGF0aFJvd3M7CiAgICAgICAgICAgICAgICBjb25zdCBhbGxHb25lID0gcGF0aFJvd3MubGVuZ3RoID4g
MCAmJiBwYXRoUm93cy5ldmVyeShyID0+IHIuZXhpc3RzID09PSBmYWxzZSk7CiAgICAgICAgICAgICAg
ICBuLmNsYXNzTGlzdC50b2dnbGUoJ2dvbmUnLCBhbGxHb25lKTsKICAgICAgICAgICAgfSk7CiAgICAg
ICAgfSwgNDAwKTsKICAgIH0KICAgIGZ1bmN0aW9uIGZpbGxGaWxlRGV0YWlsUGFuZWwoY29udGFpbmVy
LCByb3dzKSB7CiAgICAgICAgY29udGFpbmVyLmlubmVySFRNTCA9ICcnOwogICAgICAgIGlmICghcm93
cy5sZW5ndGgpIHsKICAgICAgICAgICAgY29uc3QgZW1wdHkgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50
KCdkaXYnKTsKICAgICAgICAgICAgZW1wdHkuY2xhc3NOYW1lID0gJ2ZkLXBhdGgnOwogICAgICAgICAg
ICBlbXB0eS50ZXh0Q29udGVudCA9ICfml6Dot6/lvoQnOwogICAgICAgICAgICBjb250YWluZXIuYXBw
ZW5kQ2hpbGQoZW1wdHkpOwogICAgICAgICAgICByZXR1cm47CiAgICAgICAgfQogICAgICAgIHJvd3Mu
Zm9yRWFjaChyID0+IHsKICAgICAgICAgICAgY29uc3QgcGF0aCA9IFN0cmluZyhyLnBhdGggfHwgJycp
OwogICAgICAgICAgICBjb25zdCBtaXNzaW5nID0gci5leGlzdHMgPT09IGZhbHNlOwogICAgICAgICAg
ICBjb25zdCBibG9jayA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOwogICAgICAgICAgICBi
bG9jay5jbGFzc05hbWUgPSAnZmQtYmxvY2snOwoKICAgICAgICAgICAgY29uc3QgcGF0aEVsID0gZG9j
dW1lbnQuY3JlYXRlRWxlbWVudCgnZGl2Jyk7CiAgICAgICAgICAgIHBhdGhFbC5jbGFzc05hbWUgPSAn
ZmQtcGF0aCcgKyAobWlzc2luZyA/ICcgZGVhZCcgOiAnIGxpdmUnKTsKICAgICAgICAgICAgcGF0aEVs
LnRleHRDb250ZW50ID0gcGF0aCB8fCAnKOepuui3r+W+hCknOwogICAgICAgICAgICBpZiAoIW1pc3Np
bmcpIHsKICAgICAgICAgICAgICAgIHBhdGhFbC5vbmNsaWNrID0gZSA9PiB7CiAgICAgICAgICAgICAg
ICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOwogICAgICAgICAgICAgICAgICAgIGUuc3RvcFByb3BhZ2F0
aW9uKCk7CiAgICAgICAgICAgICAgICAgICAgYWhrKCdvcGVuUGF0aCcsIHBhdGgpOwogICAgICAgICAg
ICAgICAgfTsKICAgICAgICAgICAgfQogICAgICAgICAgICBibG9jay5hcHBlbmRDaGlsZChwYXRoRWwp
OwoKICAgICAgICAgICAgY29uc3QgYWN0aW9ucyA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2Rpdicp
OwogICAgICAgICAgICBhY3Rpb25zLmNsYXNzTmFtZSA9ICdmZC1hY3Rpb25zJzsKCiAgICAgICAgICAg
IGNvbnN0IGNvcHlCdG4gPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdidXR0b24nKTsKICAgICAgICAg
ICAgY29weUJ0bi50eXBlID0gJ2J1dHRvbic7CiAgICAgICAgICAgIGNvcHlCdG4uY2xhc3NOYW1lID0g
J2ZkLWJ0bic7CiAgICAgICAgICAgIGNvcHlCdG4uaW5uZXJIVE1MID0gJzxzcGFuIGNsYXNzPSJmZC1p
Y28iPvCflJc8L3NwYW4+PHNwYW4gY2xhc3M9ImZkLXR4dCI+5aSN5Yi26Lev5b6EPC9zcGFuPic7CiAg
ICAgICAgICAgIGNvcHlCdG4ub25jbGljayA9IGUgPT4gewogICAgICAgICAgICAgICAgZS5wcmV2ZW50
RGVmYXVsdCgpOwogICAgICAgICAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICAgICAg
ICAgIGFoaygnY29weVBhdGgnLCBwYXRoKTsKICAgICAgICAgICAgICAgIGNvcHlCdG4ucXVlcnlTZWxl
Y3RvcignLmZkLXR4dCcpLnRleHRDb250ZW50ID0gJ+W3suWkjeWItic7CiAgICAgICAgICAgICAgICBj
b3B5QnRuLmNsYXNzTGlzdC5hZGQoJ29rJyk7CiAgICAgICAgICAgICAgICBzZXRUaW1lb3V0KCgpID0+
IHsKICAgICAgICAgICAgICAgICAgICBjb3B5QnRuLnF1ZXJ5U2VsZWN0b3IoJy5mZC10eHQnKS50ZXh0
Q29udGVudCA9ICflpI3liLbot6/lvoQnOwogICAgICAgICAgICAgICAgICAgIGNvcHlCdG4uY2xhc3NM
aXN0LnJlbW92ZSgnb2snKTsKICAgICAgICAgICAgICAgIH0sIDEyMDApOwogICAgICAgICAgICB9Owog
ICAgICAgICAgICBhY3Rpb25zLmFwcGVuZENoaWxkKGNvcHlCdG4pOwoKICAgICAgICAgICAgY29uc3Qg
Zm9sZGVyQnRuID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnYnV0dG9uJyk7CiAgICAgICAgICAgIGZv
bGRlckJ0bi50eXBlID0gJ2J1dHRvbic7CiAgICAgICAgICAgIGZvbGRlckJ0bi5jbGFzc05hbWUgPSAn
ZmQtYnRuJzsKICAgICAgICAgICAgZm9sZGVyQnRuLmlubmVySFRNTCA9ICc8c3BhbiBjbGFzcz0iZmQt
aWNvIj7wn5OCPC9zcGFuPjxzcGFuIGNsYXNzPSJmZC10eHQiPuaJk+W8gOaJgOWcqOaWh+S7tuWkuTwv
c3Bhbj4nOwogICAgICAgICAgICBmb2xkZXJCdG4ub25jbGljayA9IGUgPT4gewogICAgICAgICAgICAg
ICAgZS5wcmV2ZW50RGVmYXVsdCgpOwogICAgICAgICAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsK
ICAgICAgICAgICAgICAgIGFoaygnb3BlbkZvbGRlcicsIHBhdGgpOwogICAgICAgICAgICB9OwogICAg
ICAgICAgICBhY3Rpb25zLmFwcGVuZENoaWxkKGZvbGRlckJ0bik7CgogICAgICAgICAgICBibG9jay5h
cHBlbmRDaGlsZChhY3Rpb25zKTsKICAgICAgICAgICAgY29udGFpbmVyLmFwcGVuZENoaWxkKGJsb2Nr
KTsKICAgICAgICB9KTsKICAgIH0KCiAgICBjb25zdCBjdHhFbCA9IGRvY3VtZW50LmdldEVsZW1lbnRC
eUlkKCdjdHgnKTsKICAgIGZ1bmN0aW9uIHNob3dDdHgoeCwgeSwgYykgewogICAgICAgIGN0eENsaXAg
PSBjOwogICAgICAgIHNlbGVjdGVkSWQgPSBjLmlkOwogICAgICAgIHJhbmdlQW5jaG9ySWQgPSBjLmlk
OwogICAgICAgIHJhbmdlQW5jaG9yQ2xpY2tlZCA9IHRydWU7CiAgICAgICAgY29uc3QgY2xlYXJCdG4g
PSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYy1jbGVhci1wYXN0ZWQnKTsKICAgICAgICBpZiAoY2xl
YXJCdG4pIGNsZWFyQnRuLnN0eWxlLmRpc3BsYXkgPSBpc1Bhc3RlZChjKSA/ICcnIDogJ25vbmUnOwoK
ICAgICAgICBjb25zdCBwaW5CdG4gPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYy1waW4nKTsKICAg
ICAgICBjb25zdCBpc1JlY2VudCA9IG5vcm1UeXBlKGMudHlwZSkgPT09ICdyZWNlbnQnIHx8IGN1clRh
YiA9PT0gJ3JlY2VudCc7CiAgICAgICAgaWYgKHBpbkJ0bikgewogICAgICAgICAgICBwaW5CdG4uc3R5
bGUuZGlzcGxheSA9ICcnOwogICAgICAgICAgICBjb25zdCBvbiA9IGlzUGlubmVkKGMpOwogICAgICAg
ICAgICBpZiAoaXNSZWNlbnQpIHsKICAgICAgICAgICAgICAgIHBpbkJ0bi5pbm5lckhUTUwgPSBvbgog
ICAgICAgICAgICAgICAgICAgID8gJzxzcGFuIGNsYXNzPSJjLWljbyI+4piFPC9zcGFuPuWPlua2iOWb
uuWumicKICAgICAgICAgICAgICAgICAgICA6ICc8c3BhbiBjbGFzcz0iYy1pY28iPuKYhTwvc3Bhbj7l
m7rlrponOwogICAgICAgICAgICB9IGVsc2UgewogICAgICAgICAgICAgICAgcGluQnRuLmlubmVySFRN
TCA9IG9uCiAgICAgICAgICAgICAgICAgICAgPyAnPHNwYW4gY2xhc3M9ImMtaWNvIj7imIU8L3NwYW4+
5Y+W5raI5pS26JePJwogICAgICAgICAgICAgICAgICAgIDogJzxzcGFuIGNsYXNzPSJjLWljbyI+4piF
PC9zcGFuPuaUtuiXjyc7CiAgICAgICAgICAgIH0KICAgICAgICB9CiAgICAgICAgY29uc3QgcGFzdGVC
dG4gPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYy1wYXN0ZScpOwogICAgICAgIGlmIChwYXN0ZUJ0
bikgewogICAgICAgICAgICBwYXN0ZUJ0bi5zdHlsZS5kaXNwbGF5ID0gJyc7CiAgICAgICAgICAgIHBh
c3RlQnRuLmlubmVySFRNTCA9IGlzUmVjZW50CiAgICAgICAgICAgICAgICA/ICc8c3BhbiBjbGFzcz0i
Yy1pY28iPvCfk4I8L3NwYW4+5omT5byA5paH5Lu25aS5JwogICAgICAgICAgICAgICAgOiAnPHNwYW4g
Y2xhc3M9ImMtaWNvIj7wn5OLPC9zcGFuPueymOi0tCc7CiAgICAgICAgfQogICAgICAgIGNvbnN0IHRp
dGxlQnRuID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2MtdGl0bGUnKTsKICAgICAgICBpZiAodGl0
bGVCdG4pIHsKICAgICAgICAgICAgY29uc3Qgc2hvd1RpdGxlID0gIWlzUmVjZW50ICYmIChpc1Bpbm5l
ZChjKSB8fCBjdXJUYWIgPT09ICdwaW5uZWQnKTsKICAgICAgICAgICAgdGl0bGVCdG4uc3R5bGUuZGlz
cGxheSA9IHNob3dUaXRsZSA/ICcnIDogJ25vbmUnOwogICAgICAgICAgICBpZiAoc2hvd1RpdGxlKQog
ICAgICAgICAgICAgICAgdGl0bGVCdG4uaW5uZXJIVE1MID0gKFN0cmluZyhjLmZhdlRpdGxlIHx8ICcn
KS50cmltKCkgPyAnPHNwYW4gY2xhc3M9ImMtaWNvIj7inI48L3NwYW4+57yW6L6R5qCH6aKYJyA6ICc8
c3BhbiBjbGFzcz0iYy1pY28iPuKcjjwvc3Bhbj7orr7nva7moIfpopgnKTsKICAgICAgICB9CiAgICAg
ICAgY29uc3QgbWVyZ2VCdG4gPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYy1tZXJnZScpOwogICAg
ICAgIGNvbnN0IHVubWVyZ2VCdG4gPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYy11bm1lcmdlJyk7
CiAgICAgICAgY29uc3Qgb25QaW5uZWQgPSAhaXNSZWNlbnQgJiYgY3VyVGFiID09PSAncGlubmVkJzsK
ICAgICAgICBpZiAobWVyZ2VCdG4pCiAgICAgICAgICAgIG1lcmdlQnRuLnN0eWxlLmRpc3BsYXkgPSAo
b25QaW5uZWQgJiYgbXVsdGlJZHMubGVuZ3RoID49IDIpID8gJycgOiAnbm9uZSc7CiAgICAgICAgaWYg
KHVubWVyZ2VCdG4pCiAgICAgICAgICAgIHVubWVyZ2VCdG4uc3R5bGUuZGlzcGxheSA9IChvblBpbm5l
ZCAmJiBmYXZHcm91cE9mKGMpKSA/ICcnIDogJ25vbmUnOwogICAgICAgIGNvbnN0IHRvcEJ0biA9IGRv
Y3VtZW50LmdldEVsZW1lbnRCeUlkKCdjLXRvcCcpOwogICAgICAgIGlmICh0b3BCdG4pIHRvcEJ0bi5z
dHlsZS5kaXNwbGF5ID0gaXNSZWNlbnQgPyAnbm9uZScgOiAnJzsKICAgICAgICBjb25zdCBjb3B5QnRu
ID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2MtY29weScpOwogICAgICAgIGlmIChjb3B5QnRuKSB7
CiAgICAgICAgICAgIGNvcHlCdG4uc3R5bGUuZGlzcGxheSA9ICcnOwogICAgICAgICAgICBjb3B5QnRu
LmlubmVySFRNTCA9IGlzUmVjZW50CiAgICAgICAgICAgICAgICA/ICc8c3BhbiBjbGFzcz0iYy1pY28i
PvCfk4Q8L3NwYW4+5aSN5Yi26Lev5b6EJwogICAgICAgICAgICAgICAgOiAnPHNwYW4gY2xhc3M9ImMt
aWNvIj7wn5OEPC9zcGFuPuWkjeWItic7CiAgICAgICAgfQogICAgICAgIGN0eEVsLmNsYXNzTGlzdC5h
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
ICAgICAgICAgICAgY2xlYXJNdWx0aSgpOwogICAgICAgICAgICAgICAgY29uc3QgZmlyc3QgPSBhbGxD
bGlwcy5maW5kKHggPT4gK3guaWQgPT09ICtpZHNbMF0pOwogICAgICAgICAgICAgICAgaWYgKGZpcnN0
ICYmIG5vcm1UeXBlKGZpcnN0LnR5cGUpID09PSAncmVjZW50JykgewogICAgICAgICAgICAgICAgICAg
IGFjdGl2YXRlQ2xpcEl0ZW0oZmlyc3QpOwogICAgICAgICAgICAgICAgICAgIHJldHVybjsKICAgICAg
ICAgICAgICAgIH0KICAgICAgICAgICAgICAgIG1hcmtQYXN0ZWRMb2NhbChpZHMpOwogICAgICAgICAg
ICAgICAgcGFzdGVNYW55V2l0aFNlcChpZHMpOwogICAgICAgICAgICAgICAgcmV0dXJuOwogICAgICAg
ICAgICB9CiAgICAgICAgICAgIGlmIChtdWx0aUlkcy5sZW5ndGggPT09IDEpIHsKICAgICAgICAgICAg
ICAgIGNvbnN0IGlkID0gbXVsdGlJZHNbMF07CiAgICAgICAgICAgICAgICBjbGVhck11bHRpKCk7CiAg
ICAgICAgICAgICAgICBjb25zdCBvbmUgPSBhbGxDbGlwcy5maW5kKHggPT4gK3guaWQgPT09ICtpZCkg
fHwgeyBpZCB9OwogICAgICAgICAgICAgICAgYWN0aXZhdGVDbGlwSXRlbShvbmUpOwogICAgICAgICAg
ICAgICAgcmV0dXJuOwogICAgICAgICAgICB9CiAgICAgICAgICAgIGNvbnN0IGMgPSB2aXNbc2VsZWN0
ZWRJbmRleCgpXTsKICAgICAgICAgICAgaWYgKGMpIGFjdGl2YXRlQ2xpcEl0ZW0oYyk7CiAgICAgICAg
fSBlbHNlIGlmICgvXlsxLTldJC8udGVzdChlLmtleSkpIHsKICAgICAgICAgICAgY29uc3QgYyA9IHZp
c1srZS5rZXkgLSAxXTsKICAgICAgICAgICAgaWYgKGMpIGFjdGl2YXRlQ2xpcEl0ZW0oYyk7CiAgICAg
ICAgfQogICAgfSk7CgogICAgd2luZG93Ll9fbmF2ID0gZGlyID0+IHsKICAgICAgICBjb25zdCB2aXMg
PSAodHlwZW9mIG5hdkxpc3QgPT09ICdmdW5jdGlvbicgPyBuYXZMaXN0KCkgOiB2aXNpYmxlTGlzdCgp
KTsKICAgICAgICBpZiAoIXZpcy5sZW5ndGggJiYgZGlyICE9PSAndGFiJyAmJiBkaXIgIT09ICd0YWJQ
cmV2JykgcmV0dXJuOwogICAgICAgIGxldCBpZHggPSBzZWxlY3RlZEluZGV4KCk7CiAgICAgICAgaWYg
KGlkeCA8IDApIGlkeCA9IDA7CiAgICAgICAgaWYgKGRpciA9PT0gJ3VwJykgc2VsZWN0QnlJbmRleChp
ZHggLSAxKTsKICAgICAgICBlbHNlIGlmIChkaXIgPT09ICdkb3duJykgc2VsZWN0QnlJbmRleChpZHgg
KyAxKTsKICAgICAgICBlbHNlIGlmIChkaXIgPT09ICdlbnRlcicpIHsKICAgICAgICAgICAgaWYgKHBp
bm5lZFVJKSByZXR1cm47CiAgICAgICAgICAgIF9fcHJlcFBhc3RlKCk7CiAgICAgICAgICAgIGlmICht
dWx0aUlkcy5sZW5ndGggPiAxKSB7CiAgICAgICAgICAgICAgICBjb25zdCBpZHMgPSBtdWx0aUlkcy5z
bGljZSgpOwogICAgICAgICAgICAgICAgY2xlYXJNdWx0aSgpOwogICAgICAgICAgICAgICAgY29uc3Qg
Zmlyc3QgPSBhbGxDbGlwcy5maW5kKHggPT4gK3guaWQgPT09ICtpZHNbMF0pOwogICAgICAgICAgICAg
ICAgaWYgKGZpcnN0ICYmIG5vcm1UeXBlKGZpcnN0LnR5cGUpID09PSAncmVjZW50JykgewogICAgICAg
ICAgICAgICAgICAgIGFjdGl2YXRlQ2xpcEl0ZW0oZmlyc3QpOwogICAgICAgICAgICAgICAgICAgIHJl
dHVybjsKICAgICAgICAgICAgICAgIH0KICAgICAgICAgICAgICAgIG1hcmtQYXN0ZWRMb2NhbChpZHMp
OwogICAgICAgICAgICAgICAgcGFzdGVNYW55V2l0aFNlcChpZHMpOwogICAgICAgICAgICAgICAgcmV0
dXJuOwogICAgICAgICAgICB9CiAgICAgICAgICAgIGlmIChtdWx0aUlkcy5sZW5ndGggPT09IDEpIHsK
ICAgICAgICAgICAgICAgIGNvbnN0IGlkID0gbXVsdGlJZHNbMF07CiAgICAgICAgICAgICAgICBjbGVh
ck11bHRpKCk7CiAgICAgICAgICAgICAgICBjb25zdCBvbmUgPSBhbGxDbGlwcy5maW5kKHggPT4gK3gu
aWQgPT09ICtpZCkgfHwgeyBpZCB9OwogICAgICAgICAgICAgICAgYWN0aXZhdGVDbGlwSXRlbShvbmUp
OwogICAgICAgICAgICAgICAgcmV0dXJuOwogICAgICAgICAgICB9CiAgICAgICAgICAgIGNvbnN0IGMg
PSB2aXNbc2VsZWN0ZWRJbmRleCgpXTsKICAgICAgICAgICAgaWYgKGMpIGFjdGl2YXRlQ2xpcEl0ZW0o
Yyk7CiAgICAgICAgfQogICAgfTsKCiAgICAvLyBBSEsgRW50ZXIgaG90a2V5IGxhbmRzIGhlcmUgKFdl
YlZpZXcgbWF5IG5vdCByZWNlaXZlIHRoZSBrZXkgd2hpbGUgdW5waW5uZWQpCiAgICB3aW5kb3cuX19l
ZGl0VGl0bGUgPSAoKSA9PiB7CiAgICAgICAgbGV0IGMgPSBudWxsOwogICAgICAgIGlmIChzZWxlY3Rl
ZElkKQogICAgICAgICAgICBjID0gYWxsQ2xpcHMuZmluZCh4ID0+ICt4LmlkID09PSArc2VsZWN0ZWRJ
ZCkgfHwgbnVsbDsKICAgICAgICBpZiAoIWMgJiYgY3R4Q2xpcCkKICAgICAgICAgICAgYyA9IGN0eENs
aXA7CiAgICAgICAgaWYgKCFjKSB7CiAgICAgICAgICAgIGNvbnN0IHZpcyA9IHZpc2libGVMaXN0KCk7
CiAgICAgICAgICAgIGlmICh2aXMubGVuZ3RoKSBjID0gdmlzWzBdOwogICAgICAgIH0KICAgICAgICBp
ZiAoIWMpIHJldHVybjsKICAgICAgICBvcGVuVGl0bGVEbGcoYyk7CiAgICB9OwoKICAgIHdpbmRvdy5f
X29uRW50ZXIgPSAoKSA9PiB7CiAgICAgICAgY29uc3QgdGQgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJ
ZCgndGl0bGUtZGxnJyk7CiAgICAgICAgaWYgKHRkICYmIHRkLmNsYXNzTGlzdC5jb250YWlucygnb24n
KSkgewogICAgICAgICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgndGl0bGUtb2snKT8uY2xpY2so
KTsKICAgICAgICAgICAgcmV0dXJuOwogICAgICAgIH0KICAgICAgICBpZiAoZG9jdW1lbnQuYWN0aXZl
RWxlbWVudD8uaWQgPT09ICd0aXRsZS1pbnB1dCcpIHsKICAgICAgICAgICAgZG9jdW1lbnQuZ2V0RWxl
bWVudEJ5SWQoJ3RpdGxlLW9rJyk/LmNsaWNrKCk7CiAgICAgICAgICAgIHJldHVybjsKICAgICAgICB9
CiAgICAgICAgLy8gQ3VzdG9tIHNlcGFyYXRvciBib3g6IEFISyBzdGVhbHMgRW50ZXIgd2hpbGUgdW5w
aW5uZWQg4oCUIGFwcGx5IGhlcmUKICAgICAgICBjb25zdCBzZXBNZW51ID0gZG9jdW1lbnQuZ2V0RWxl
bWVudEJ5SWQoJ3Bhc3RlLXNlcC1tZW51Jyk7CiAgICAgICAgY29uc3Qgc2VwSW5wID0gZG9jdW1lbnQu
Z2V0RWxlbWVudEJ5SWQoJ3Bhc3RlLXNlcC1jdXN0b20nKTsKICAgICAgICBpZiAoc2VwTWVudSAmJiBz
ZXBNZW51LmNsYXNzTGlzdC5jb250YWlucygnb24nKSAmJiBzZXBJbnApIHsKICAgICAgICAgICAgaWYg
KFN0cmluZyhzZXBJbnAudmFsdWUgfHwgJycpICE9PSAnJykgYXBwbHlTZXBhcmF0b3Ioc2VwSW5wLnZh
bHVlKTsKICAgICAgICAgICAgZWxzZSBjbG9zZVNlcE1lbnUoKTsKICAgICAgICAgICAgcmV0dXJuOwog
ICAgICAgIH0KICAgICAgICAvLyDlm7rlrprml7blm57ovabkuI3nspjotLQKICAgICAgICBpZiAocGlu
bmVkVUkpIHJldHVybjsKICAgICAgICAvLyBUeXBpbmcgaW4gc2VhcmNoOiBFbnRlciBzaG91bGQgcGFz
dGUgc2VsZWN0ZWQgaXRlbQogICAgICAgIGlmIChkb2N1bWVudC5hY3RpdmVFbGVtZW50Py5pZCA9PT0g
J3NlYXJjaCcpIHsKICAgICAgICAgICAgd2luZG93Ll9fbmF2ICYmIHdpbmRvdy5fX25hdignZW50ZXIn
KTsKICAgICAgICAgICAgcmV0dXJuOwogICAgICAgIH0KICAgICAgICB3aW5kb3cuX19uYXYgJiYgd2lu
ZG93Ll9fbmF2KCdlbnRlcicpOwogICAgfTsKCiAgICB3aW5kb3cuX19jeWNsZVRhYiA9IGRpciA9PiB7
CiAgICAgICAgY29uc3QgaSA9IE1hdGgubWF4KDAsIFRBQl9PUkRFUi5pbmRleE9mKGN1clRhYikpOwog
ICAgICAgIGNvbnN0IG5leHQgPSBUQUJfT1JERVJbKGkgKyAoZGlyIHwgMCkgKyBUQUJfT1JERVIubGVu
Z3RoICogMTApICUgVEFCX09SREVSLmxlbmd0aF07CiAgICAgICAgc2V0VGFiKG5leHQpOwogICAgfTsK
ICAgIHdpbmRvdy5fX29uUGFuZWxTaG93ID0gKGtlZXBTZWFyY2gpID0+IHsKICAgICAgICAvLyBEbyBO
T1QgZm9jdXMgV2ViVmlldyDigJQga2VlcCBlZGl0b3IgY2FyZXQvZm9jdXMgKEFISyBoYW5kbGVzIGtl
eXMgdmlhICNIb3RJZikKICAgICAgICAvLyBXaW4rVjogY29sbGFwc2Ugc2VhcmNoLiA/PyBzZWFyY2g6
IGtlZXAvb3BlbiBzZWFyY2ggYm94LgogICAgICAgIGtlZXBTZWFyY2ggPSAhIWtlZXBTZWFyY2g7CiAg
ICAgICAgdHJ5IHsgaGlkZUN0eCgpOyB9IGNhdGNoIHt9CiAgICAgICAgdHJ5IHsgY2xvc2VUaXRsZURs
ZygpOyB9IGNhdGNoIHt9CiAgICAgICAgdHJ5IHsgcmVzZXRQYXN0ZVNlcERlZmF1bHQoKTsgfSBjYXRj
aCB7fQogICAgICAgIHRyeSB7CiAgICAgICAgICAgIGNvbnN0IHdyYXAgPSBkb2N1bWVudC5nZXRFbGVt
ZW50QnlJZCgnc2VhcmNoLXdyYXAnKTsKICAgICAgICAgICAgY29uc3Qgc3JjaCA9IGRvY3VtZW50Lmdl
dEVsZW1lbnRCeUlkKCdzZWFyY2gnKTsKICAgICAgICAgICAgY29uc3Qgc2NsciA9IGRvY3VtZW50Lmdl
dEVsZW1lbnRCeUlkKCdzZWFyY2gtY2xyJyk7CiAgICAgICAgICAgIGlmICgha2VlcFNlYXJjaCkgewog
ICAgICAgICAgICAgICAgaWYgKHdyYXApIHdyYXAuY2xhc3NMaXN0LnJlbW92ZSgnb3BlbicpOwogICAg
ICAgICAgICAgICAgaWYgKHNyY2gpIHsKICAgICAgICAgICAgICAgICAgICBzcmNoLnZhbHVlID0gJyc7
CiAgICAgICAgICAgICAgICAgICAgc3JjaC5jbGFzc0xpc3QucmVtb3ZlKCdoYXMtdmFsJyk7CiAgICAg
ICAgICAgICAgICAgICAgdHJ5IHsgc3JjaC5ibHVyKCk7IH0gY2F0Y2gge30KICAgICAgICAgICAgICAg
IH0KICAgICAgICAgICAgICAgIGlmIChzY2xyKSBzY2xyLnN0eWxlLmRpc3BsYXkgPSAnbm9uZSc7CiAg
ICAgICAgICAgICAgICBxdWVyeSA9ICcnOwogICAgICAgICAgICAgICAgd2luZG93Ll9faG9zdEZpbHRl
cmVkID0gZmFsc2U7CiAgICAgICAgICAgICAgICB3aW5kb3cuX19ob3N0RmlsdGVyUSA9ICcnOwogICAg
ICAgICAgICAgICAgLy8gV2luK1bvvJrnq4vliLvnlKjmnKrov4fmu6TnvJPlrZjpk7rliJfooajvvIzp
gb/lhY3lhYjpl6rov4fmu6Tnu5Pmnpwv56m65aOz5YaN562JIFNldFZpZXcKICAgICAgICAgICAgICAg
IHRyeSB7CiAgICAgICAgICAgICAgICAgICAgY29uc3QgaGl0ID0gdmlld01lbS5nZXQodmlld01lbUtl
eSgnYWxsJywgJycsIGZhbHNlKSk7CiAgICAgICAgICAgICAgICAgICAgaWYgKGhpdCAmJiBBcnJheS5p
c0FycmF5KGhpdC5pdGVtcykgJiYgaGl0Lml0ZW1zLmxlbmd0aCkgewogICAgICAgICAgICAgICAgICAg
ICAgICBhbGxDbGlwcyA9IGhpdC5pdGVtcy5zbGljZSgpOwogICAgICAgICAgICAgICAgICAgICAgICBk
aXNrVG90YWwgPSBOdW1iZXIoaGl0LnRvdGFsKSB8fCBoaXQuaXRlbXMubGVuZ3RoOwogICAgICAgICAg
ICAgICAgICAgICAgICB3aW5kb3cuX19kYXRhUmVhZHkgPSB0cnVlOwogICAgICAgICAgICAgICAgICAg
ICAgICBob3N0UHVzaGVkT25jZSA9IHRydWU7CiAgICAgICAgICAgICAgICAgICAgICAgIHNhd05vbkVt
cHR5ID0gdHJ1ZTsKICAgICAgICAgICAgICAgICAgICAgICAgY2xlYXJXYWl0aW5nRGF0YSgpOwogICAg
ICAgICAgICAgICAgICAgIH0gZWxzZSB7CiAgICAgICAgICAgICAgICAgICAgICAgIHNjaGVkdWxlRGVs
YXllZFNrZWwoKTsKICAgICAgICAgICAgICAgICAgICB9CiAgICAgICAgICAgICAgICB9IGNhdGNoIHsK
ICAgICAgICAgICAgICAgICAgICBzY2hlZHVsZURlbGF5ZWRTa2VsKCk7CiAgICAgICAgICAgICAgICB9
CiAgICAgICAgICAgIH0gZWxzZSBpZiAod3JhcCkgewogICAgICAgICAgICAgICAgd3JhcC5jbGFzc0xp
c3QuYWRkKCdvcGVuJyk7CiAgICAgICAgICAgICAgICBpZiAoc3JjaCAmJiBzcmNoLnZhbHVlKQogICAg
ICAgICAgICAgICAgICAgIHF1ZXJ5ID0gc3JjaC52YWx1ZTsKICAgICAgICAgICAgICAgIC8vID8/IOaQ
nOe0ou+8muWcqOS4u+acuui/h+a7pOe7k+aenOWIsOi+vuWJje+8jOWFiOaMieWFs+mUruWtl+acrOWc
sOa7pO+8jOemgeatoumXquWHuuOAjOWFqOmDqOOAjQogICAgICAgICAgICAgICAgaWYgKFN0cmluZyhx
dWVyeSB8fCAnJykudHJpbSgpKSB7CiAgICAgICAgICAgICAgICAgICAgd2luZG93Ll9faG9zdEZpbHRl
cmVkID0gZmFsc2U7CiAgICAgICAgICAgICAgICAgICAgd2luZG93Ll9faG9zdEZpbHRlclEgPSAnJzsK
ICAgICAgICAgICAgICAgIH0KICAgICAgICAgICAgfQogICAgICAgICAgICB0b2RheU9ubHkgPSBmYWxz
ZTsKICAgICAgICAgICAgdHJ5IHsKICAgICAgICAgICAgICAgIGNvbnN0IGJ0blRvZGF5ID0gZG9jdW1l
bnQuZ2V0RWxlbWVudEJ5SWQoJ2J0bi10b2RheScpOwogICAgICAgICAgICAgICAgaWYgKGJ0blRvZGF5
KSBidG5Ub2RheS5jbGFzc0xpc3QucmVtb3ZlKCdvbicpOwogICAgICAgICAgICB9IGNhdGNoIHt9CiAg
ICAgICAgICAgIGN1clRhYiA9ICdhbGwnOwogICAgICAgICAgICBsb2FkaW5nTW9yZSA9IGZhbHNlOwog
ICAgICAgICAgICBtYXJrVGFiKCdhbGwnKTsKICAgICAgICAgICAgLy8g5LiN6KaBIGFoaygnYmx1clBh
bmVsJynvvJrkvJrot58gU2hvd1BhbmVsIOaKoueEpueCue+8jFdpbitWLz8/IOmDveWuueaYk+mXquOA
geS5sei3swogICAgICAgICAgICByZW5kZXIoKTsKICAgICAgICAgICAgLy8g5ZCM5q2l5b2T5YmNIHRh
Yi9xdWVyeSDliLAgQUhL77yIPz8g5pu+5Y+q55SoIHZpZXdUYWIg5pCc6ZSZ6aG177yJCiAgICAgICAg
ICAgIHJlcXVlc3RWaWV3KCk7CiAgICAgICAgfSBjYXRjaCB7fQogICAgICAgIHNlbGVjdEZpcnN0T25T
aG93ID0gdHJ1ZTsKICAgICAgICBsb2NhdGVBY3RpdmUgPSBmYWxzZTsKICAgICAgICB1cGRhdGVMb2Nh
dGVCdG4oKTsKICAgICAgICBjbGVhck11bHRpKCk7CiAgICAgICAgY29uc3QgdmlzID0gdmlzaWJsZUxp
c3QoKTsKICAgICAgICBpZiAodmlzLmxlbmd0aCkgewogICAgICAgICAgICBzZWxlY3RlZElkID0gdmlz
WzBdLmlkOwogICAgICAgICAgICByYW5nZUFuY2hvcklkID0gc2VsZWN0ZWRJZDsKICAgICAgICAgICAg
cmFuZ2VBbmNob3JDbGlja2VkID0gZmFsc2U7CiAgICAgICAgICAgIGxpc3RFbC5zY3JvbGxUb3AgPSAw
OwogICAgICAgIH0KICAgICAgICBzeW5jSXRlbUhpZ2hsaWdodCgpOwogICAgfTsKCiAgICBmdW5jdGlv
biBjdHhCaW5kKGlkLCBmbikgewogICAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKGlkKS5hZGRF
dmVudExpc3RlbmVyKCdjbGljaycsIGUgPT4gewogICAgICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigp
OwogICAgICAgICAgICBpZiAoY3R4Q2xpcCkgZm4oY3R4Q2xpcCk7CiAgICAgICAgICAgIGhpZGVDdHgo
KTsKICAgICAgICB9KTsKICAgIH0KICAgIGN0eEJpbmQoJ2MtY29weScsICBjID0+IHsKICAgICAgICBp
ZiAobm9ybVR5cGUoYy50eXBlKSA9PT0gJ3JlY2VudCcpCiAgICAgICAgICAgIGFoaygnY29weVBhdGgn
LCBTdHJpbmcoYy5kYXRhIHx8IGMucHJldmlldyB8fCAnJykpOwogICAgICAgIGVsc2UKICAgICAgICAg
ICAgYWhrKCdjb3B5QnlJZCcsIFN0cmluZyhjLmlkKSk7CiAgICB9KTsKICAgIGN0eEJpbmQoJ2MtcGFz
dGUnLCBjID0+IHsKICAgICAgICBhY3RpdmF0ZUNsaXBJdGVtKGMpOwogICAgfSk7CiAgICBjdHhCaW5k
KCdjLXBpbicsICAgYyA9PiB7CiAgICAgICAgaWYgKG5vcm1UeXBlKGMudHlwZSkgPT09ICdyZWNlbnQn
KSB7CiAgICAgICAgICAgIHRyeSB7CiAgICAgICAgICAgICAgICBjb25zdCBuZXh0ID0gIWlzUGlubmVk
KGMpOwogICAgICAgICAgICAgICAgY29uc3QgaGl0ID0gYWxsQ2xpcHMuZmluZCh4ID0+ICt4LmlkID09
PSArYy5pZCk7CiAgICAgICAgICAgICAgICBpZiAoaGl0KSBoaXQucGlubmVkID0gbmV4dDsKICAgICAg
ICAgICAgICAgIGMucGlubmVkID0gbmV4dDsKICAgICAgICAgICAgICAgIHJlbmRlcigpOwogICAgICAg
ICAgICB9IGNhdGNoIHt9CiAgICAgICAgfQogICAgICAgIGFoaygncGluJywgU3RyaW5nKGMuaWQpKTsK
ICAgIH0pOwogICAgY3R4QmluZCgnYy10b3AnLCAgIGMgPT4gYWhrKCdtb3ZlVG9Ub3AnLCAgICAgU3Ry
aW5nKGMuaWQpKSk7CiAgICBjdHhCaW5kKCdjLWNsZWFyLXBhc3RlZCcsIGMgPT4gewogICAgICAgIHRy
eSB7IGNsZWFyUGFzdGVkTG9jYWwoYy5pZCk7IH0gY2F0Y2gge30KICAgICAgICBhaGsoJ2NsZWFyUGFz
dGVkJywgU3RyaW5nKGMuaWQpKTsKICAgIH0pOwogICAgY3R4QmluZCgnYy1kZWwnLCAgIGMgPT4gewog
ICAgICAgIC8vIOacrOWcsOWFiOWIoO+8jOeVjOmdouS4jeWNoe+8m0FISyDlkI7lj7DokL3nm5gKICAg
ICAgICB0cnkgewogICAgICAgICAgICBjb25zdCBpZCA9ICtjLmlkOwogICAgICAgICAgICBhbGxDbGlw
cyA9IGFsbENsaXBzLmZpbHRlcih4ID0+ICt4LmlkICE9PSBpZCk7CiAgICAgICAgICAgIGRpc2tUb3Rh
bCA9IE1hdGgubWF4KDAsIChOdW1iZXIoZGlza1RvdGFsKSB8fCAwKSAtIDEpOwogICAgICAgICAgICBp
ZiAoK3NlbGVjdGVkSWQgPT09IGlkKSBzZWxlY3RlZElkID0gYWxsQ2xpcHMubGVuZ3RoID8gYWxsQ2xp
cHNbMF0uaWQgOiAwOwogICAgICAgICAgICByZW5kZXIoKTsKICAgICAgICB9IGNhdGNoIHt9CiAgICAg
ICAgYWhrKCdkZWxldGUnLCBTdHJpbmcoYy5pZCkpOwogICAgfSk7CiAgICBjdHhCaW5kKCdjLXRpdGxl
JywgYyA9PiBvcGVuVGl0bGVEbGcoYykpOwogICAgY3R4QmluZCgnYy1tZXJnZScsIGMgPT4gewogICAg
ICAgIGNvbnN0IGlkcyA9IChtdWx0aUlkcy5sZW5ndGggPj0gMikgPyBtdWx0aUlkcy5zbGljZSgpIDog
W107CiAgICAgICAgaWYgKGlkcy5sZW5ndGggPCAyKSByZXR1cm47CiAgICAgICAgaWYgKCFpZHMuaW5j
bHVkZXMoK2MuaWQpKSBpZHMucHVzaCgrYy5pZCk7CiAgICAgICAgYWhrKCdtZXJnZUZhdicsIGlkcy5q
b2luKCcsJykpOwogICAgICAgIGNsZWFyTXVsdGkoKTsKICAgIH0pOwogICAgY3R4QmluZCgnYy11bm1l
cmdlJywgYyA9PiB7CiAgICAgICAgYWhrKCd1bm1lcmdlRmF2JywgU3RyaW5nKGMuaWQpKTsKICAgICAg
ICBjbGVhck11bHRpKCk7CiAgICB9KTsKCiAgICBjb25zdCB0aXRsZURsZyA9IGRvY3VtZW50LmdldEVs
ZW1lbnRCeUlkKCd0aXRsZS1kbGcnKTsKICAgIGNvbnN0IHRpdGxlSW5wdXQgPSBkb2N1bWVudC5nZXRF
bGVtZW50QnlJZCgndGl0bGUtaW5wdXQnKTsKICAgIGxldCB0aXRsZURsZ0NsaXAgPSBudWxsOwogICAg
ZnVuY3Rpb24gY2xvc2VUaXRsZURsZygpIHsKICAgICAgICBpZiAodGl0bGVEbGcpIHRpdGxlRGxnLmNs
YXNzTGlzdC5yZW1vdmUoJ29uJyk7CiAgICAgICAgdGl0bGVEbGdDbGlwID0gbnVsbDsKICAgIH0KICAg
IGZ1bmN0aW9uIG9wZW5UaXRsZURsZyhjKSB7CiAgICAgICAgaGlkZUN0eCgpOwogICAgICAgIHRpdGxl
RGxnQ2xpcCA9IGM7CiAgICAgICAgaWYgKHRpdGxlSW5wdXQpIHRpdGxlSW5wdXQudmFsdWUgPSBTdHJp
bmcoYy5mYXZUaXRsZSB8fCAnJykudHJpbSgpOwogICAgICAgIGlmICh0aXRsZURsZykgdGl0bGVEbGcu
Y2xhc3NMaXN0LmFkZCgnb24nKTsKICAgICAgICBhaGsoJ2ZvY3VzUGFuZWwnKTsKICAgICAgICByZXF1
ZXN0QW5pbWF0aW9uRnJhbWUoKCkgPT4gewogICAgICAgICAgICB0cnkgeyB0aXRsZUlucHV0LmZvY3Vz
KCk7IHRpdGxlSW5wdXQuc2VsZWN0KCk7IH0gY2F0Y2gge30KICAgICAgICB9KTsKICAgIH0KICAgIGlm
ICh0aXRsZURsZykgewogICAgICAgIHRpdGxlRGxnLmFkZEV2ZW50TGlzdGVuZXIoJ2NsaWNrJywgZSA9
PiB7CiAgICAgICAgICAgIGlmIChlLnRhcmdldCA9PT0gdGl0bGVEbGcpIGNsb3NlVGl0bGVEbGcoKTsK
ICAgICAgICB9KTsKICAgIH0KICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd0aXRsZS1jYW5jZWwn
KT8uYWRkRXZlbnRMaXN0ZW5lcignY2xpY2snLCBlID0+IHsKICAgICAgICBlLnN0b3BQcm9wYWdhdGlv
bigpOwogICAgICAgIGNsb3NlVGl0bGVEbGcoKTsKICAgICAgICBhaGsoJ2JsdXJQYW5lbCcpOwogICAg
fSk7CiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgndGl0bGUtb2snKT8uYWRkRXZlbnRMaXN0ZW5l
cignY2xpY2snLCBlID0+IHsKICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgICAgIGlmICgh
dGl0bGVEbGdDbGlwKSByZXR1cm47CiAgICAgICAgY29uc3QgdCA9IFN0cmluZyh0aXRsZUlucHV0Py52
YWx1ZSB8fCAnJykudHJpbSgpLnNsaWNlKDAsIDgwKTsKICAgICAgICBjb25zdCBpZCA9IFN0cmluZyh0
aXRsZURsZ0NsaXAuaWQpOwogICAgICAgIC8vIE9wdGltaXN0aWMgbG9jYWwgdXBkYXRlCiAgICAgICAg
Y29uc3QgaGl0ID0gYWxsQ2xpcHMuZmluZCh4ID0+ICt4LmlkID09PSAraWQpOwogICAgICAgIGlmICho
aXQpIGhpdC5mYXZUaXRsZSA9IHQ7CiAgICAgICAgdGl0bGVEbGdDbGlwLmZhdlRpdGxlID0gdDsKICAg
ICAgICBjbG9zZVRpdGxlRGxnKCk7CiAgICAgICAgYWhrKCdzZXRGYXZUaXRsZScsIGlkLCB0KTsKICAg
ICAgICBhaGsoJ2JsdXJQYW5lbCcpOwogICAgICAgIHJlbmRlcigpOwogICAgfSk7CiAgICB0aXRsZUlu
cHV0Py5hZGRFdmVudExpc3RlbmVyKCdrZXlkb3duJywgZSA9PiB7CiAgICAgICAgaWYgKGUua2V5ID09
PSAnRW50ZXInKSB7CiAgICAgICAgICAgIGUucHJldmVudERlZmF1bHQoKTsKICAgICAgICAgICAgZS5z
dG9wUHJvcGFnYXRpb24oKTsKICAgICAgICAgICAgZS5zdG9wSW1tZWRpYXRlUHJvcGFnYXRpb24oKTsK
ICAgICAgICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3RpdGxlLW9rJyk/LmNsaWNrKCk7CiAg
ICAgICAgICAgIHJldHVybjsKICAgICAgICB9CiAgICAgICAgaWYgKGUua2V5ID09PSAnRXNjYXBlJykg
ewogICAgICAgICAgICBlLnByZXZlbnREZWZhdWx0KCk7CiAgICAgICAgICAgIGUuc3RvcFByb3BhZ2F0
aW9uKCk7CiAgICAgICAgICAgIGNsb3NlVGl0bGVEbGcoKTsKICAgICAgICAgICAgYWhrKCdibHVyUGFu
ZWwnKTsKICAgICAgICAgICAgcmV0dXJuOwogICAgICAgIH0KICAgICAgICBlLnN0b3BQcm9wYWdhdGlv
bigpOwogICAgfSwgdHJ1ZSk7CgogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3RhYnMnKS5hZGRF
dmVudExpc3RlbmVyKCdjbGljaycsIGUgPT4gewogICAgICAgIGNvbnN0IHRhYiA9IGUudGFyZ2V0LmNs
b3Nlc3QoJy50YWInKTsKICAgICAgICBpZiAoIXRhYiB8fCBlLnRhcmdldC5jbG9zZXN0KCcjdGFiLWFj
dGlvbnMnKSkgcmV0dXJuOwogICAgICAgIHNldFRhYih0YWIuZGF0YXNldC50YWIpOwogICAgfSk7Cgog
ICAgY29uc3Qgc3JjaFdyYXAgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc2VhcmNoLXdyYXAnKTsK
ICAgIGNvbnN0IGJ0blNlYXJjaCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdidG4tc2VhcmNoJyk7
CiAgICBjb25zdCBidG5Mb2NhdGUgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYnRuLWxvY2F0ZScp
OwogICAgY29uc3QgYnRuVG9kYXkgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYnRuLXRvZGF5Jyk7
CiAgICBjb25zdCBzcmNoID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NlYXJjaCcpOwogICAgY29u
c3Qgc2NsciA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzZWFyY2gtY2xyJyk7CiAgICBsZXQgZGVi
OwoKICAgIHVwZGF0ZUxvY2F0ZUJ0bigpOwogICAgaWYgKGJ0bkxvY2F0ZSkgewogICAgICAgIGJ0bkxv
Y2F0ZS5hZGRFdmVudExpc3RlbmVyKCdjbGljaycsIGUgPT4gewogICAgICAgICAgICBlLnN0b3BQcm9w
YWdhdGlvbigpOwogICAgICAgICAgICBqdW1wVG9MYXN0UGFzdGUoKTsKICAgICAgICB9KTsKICAgIH0K
CiAgICBidG5Ub2RheS5hZGRFdmVudExpc3RlbmVyKCdtb3VzZWRvd24nLCBlID0+IHsKICAgICAgICBl
LnByZXZlbnREZWZhdWx0KCk7CiAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgIH0pOwogICAg
YnRuVG9kYXkuYWRkRXZlbnRMaXN0ZW5lcignY2xpY2snLCBlID0+IHsKICAgICAgICBlLnN0b3BQcm9w
YWdhdGlvbigpOwogICAgICAgIGUucHJldmVudERlZmF1bHQoKTsKICAgICAgICB0b2RheU9ubHkgPSAh
dG9kYXlPbmx5OwogICAgICAgIGJ0blRvZGF5LmNsYXNzTGlzdC50b2dnbGUoJ29uJywgdG9kYXlPbmx5
KTsKICAgICAgICBsaXN0RWwuc2Nyb2xsVG9wID0gMDsKICAgICAgICByZXF1ZXN0VmlldygpOwogICAg
ICAgIHRyeSB7IHNyY2guZm9jdXMoKTsgfSBjYXRjaCB7fQogICAgfSk7CgogICAgZnVuY3Rpb24gb3Bl
blNlYXJjaCgpIHsKICAgICAgICBpZiAoc3JjaFdyYXAuY2xhc3NMaXN0LmNvbnRhaW5zKCdvcGVuJykp
IHsKICAgICAgICAgICAgYWhrKCdmb2N1c1BhbmVsJyk7CiAgICAgICAgICAgIHRyeSB7IHNyY2guZm9j
dXMoKTsgfSBjYXRjaCB7fQogICAgICAgICAgICByZXR1cm47CiAgICAgICAgfQogICAgICAgIHNyY2hX
cmFwLmNsYXNzTGlzdC5hZGQoJ29wZW4nKTsKICAgICAgICAvLyBEZWZhdWx0OiDmiYDmnInpobXmiZPl
vIDmkJzntKLml7bpu5jorqTmkJzlhajpg6gKICAgICAgICBjb25zdCB3YW50VG9kYXkgPSBmYWxzZTsK
ICAgICAgICBpZiAodG9kYXlPbmx5ICE9PSB3YW50VG9kYXkpIHsKICAgICAgICAgICAgdG9kYXlPbmx5
ID0gd2FudFRvZGF5OwogICAgICAgICAgICBidG5Ub2RheS5jbGFzc0xpc3QudG9nZ2xlKCdvbicsIHRv
ZGF5T25seSk7CiAgICAgICAgICAgIGxpc3RFbC5zY3JvbGxUb3AgPSAwOwogICAgICAgICAgICByZXF1
ZXN0VmlldygpOwogICAgICAgIH0gZWxzZSB7CiAgICAgICAgICAgIGJ0blRvZGF5LmNsYXNzTGlzdC50
b2dnbGUoJ29uJywgdG9kYXlPbmx5KTsKICAgICAgICB9CiAgICAgICAgYWhrKCdmb2N1c1BhbmVsJyk7
CiAgICAgICAgcmVxdWVzdEFuaW1hdGlvbkZyYW1lKCgpID0+IHsKICAgICAgICAgICAgdHJ5IHsgc3Jj
aC5mb2N1cygpOyB9IGNhdGNoIHt9CiAgICAgICAgfSk7CiAgICB9CiAgICBmdW5jdGlvbiBjbG9zZVNl
YXJjaFVpKCkgewogICAgICAgIHNyY2hXcmFwLmNsYXNzTGlzdC5yZW1vdmUoJ29wZW4nKTsKICAgICAg
ICBpZiAoIXNyY2gudmFsdWUpIHsKICAgICAgICAgICAgc3JjaC5jbGFzc0xpc3QucmVtb3ZlKCdoYXMt
dmFsJyk7CiAgICAgICAgICAgIHNjbHIuc3R5bGUuZGlzcGxheSA9ICdub25lJzsKICAgICAgICAgICAg
Ly8gTGVhdmluZyBzZWFyY2ggd2l0aCBlbXB0eSBxdWVyeSDihpIgZHJvcCB0b2RheSBmaWx0ZXIKICAg
ICAgICAgICAgaWYgKHRvZGF5T25seSkgewogICAgICAgICAgICAgICAgdG9kYXlPbmx5ID0gZmFsc2U7
CiAgICAgICAgICAgICAgICBidG5Ub2RheS5jbGFzc0xpc3QucmVtb3ZlKCdvbicpOwogICAgICAgICAg
ICAgICAgcmVxdWVzdFZpZXcoKTsKICAgICAgICAgICAgfQogICAgICAgIH0KICAgIH0KICAgIHdpbmRv
dy5fX29wZW5TZWFyY2ggPSBvcGVuU2VhcmNoOwogICAgd2luZG93Ll9fcHJlcFR5cGVTZWFyY2ggPSAo
KSA9PiB7CiAgICAgICAgdHJ5IHsKICAgICAgICAgICAgY29uc3Qgd3JhcCA9IGRvY3VtZW50LmdldEVs
ZW1lbnRCeUlkKCdzZWFyY2gtd3JhcCcpOwogICAgICAgICAgICBjb25zdCBzID0gZG9jdW1lbnQuZ2V0
RWxlbWVudEJ5SWQoJ3NlYXJjaCcpOwogICAgICAgICAgICBpZiAod3JhcCAmJiAhd3JhcC5jbGFzc0xp
c3QuY29udGFpbnMoJ29wZW4nKSkgewogICAgICAgICAgICAgICAgd3JhcC5jbGFzc0xpc3QuYWRkKCdv
cGVuJyk7CiAgICAgICAgICAgICAgICB0cnkgewogICAgICAgICAgICAgICAgICAgIGNvbnN0IHdhbnRU
b2RheSA9IGZhbHNlOwogICAgICAgICAgICAgICAgICAgIGlmICh0eXBlb2YgdG9kYXlPbmx5ICE9PSAn
dW5kZWZpbmVkJyAmJiB0b2RheU9ubHkgIT09IHdhbnRUb2RheSkgewogICAgICAgICAgICAgICAgICAg
ICAgICB0b2RheU9ubHkgPSB3YW50VG9kYXk7CiAgICAgICAgICAgICAgICAgICAgICAgIGlmICh0eXBl
b2YgYnRuVG9kYXkgIT09ICd1bmRlZmluZWQnICYmIGJ0blRvZGF5KSBidG5Ub2RheS5jbGFzc0xpc3Qu
dG9nZ2xlKCdvbicsIHRvZGF5T25seSk7CiAgICAgICAgICAgICAgICAgICAgICAgIGlmICh0eXBlb2Yg
bGlzdEVsICE9PSAndW5kZWZpbmVkJyAmJiBsaXN0RWwpIGxpc3RFbC5zY3JvbGxUb3AgPSAwOwogICAg
ICAgICAgICAgICAgICAgICAgICBpZiAodHlwZW9mIHJlcXVlc3RWaWV3ID09PSAnZnVuY3Rpb24nKSBz
ZXRUaW1lb3V0KHJlcXVlc3RWaWV3LCAwKTsKICAgICAgICAgICAgICAgICAgICB9IGVsc2UgaWYgKHR5
cGVvZiBidG5Ub2RheSAhPT0gJ3VuZGVmaW5lZCcgJiYgYnRuVG9kYXkpIHsKICAgICAgICAgICAgICAg
ICAgICAgICAgYnRuVG9kYXkuY2xhc3NMaXN0LnRvZ2dsZSgnb24nLCAhIXRvZGF5T25seSk7CiAgICAg
ICAgICAgICAgICAgICAgfQogICAgICAgICAgICAgICAgfSBjYXRjaCB7fQogICAgICAgICAgICB9CiAg
ICAgICAgICAgIC8vID8/IOmVnOWDj+aQnOe0ou+8muS4jeimgSBmb2N1c++8jOmBv+WFjeaKoui1sOWO
n+e8lui+keahhuWFieaghwogICAgICAgIH0gY2F0Y2gge30KICAgIH07CiAgICB3aW5kb3cuX190eXBl
U2VhcmNoID0gKGNoKSA9PiB7CiAgICAgICAgdHJ5IHsKICAgICAgICAgICAgd2luZG93Ll9fcHJlcFR5
cGVTZWFyY2ggJiYgd2luZG93Ll9fcHJlcFR5cGVTZWFyY2goKTsKICAgICAgICAgICAgY29uc3QgcyA9
IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzZWFyY2gnKTsKICAgICAgICAgICAgaWYgKCFzKSByZXR1
cm47CiAgICAgICAgICAgIHMudmFsdWUgPSBTdHJpbmcocy52YWx1ZSB8fCAnJykgKyBTdHJpbmcoY2gg
PT0gbnVsbCA/ICcnIDogY2gpOwogICAgICAgICAgICBzLmNsYXNzTGlzdC50b2dnbGUoJ2hhcy12YWwn
LCAhIXMudmFsdWUpOwogICAgICAgICAgICBzLmRpc3BhdGNoRXZlbnQobmV3IEV2ZW50KCdpbnB1dCcs
IHsgYnViYmxlczogdHJ1ZSB9KSk7CiAgICAgICAgfSBjYXRjaCB7fQogICAgfTsKICAgIHdpbmRvdy5f
X2Jrc3BTZWFyY2ggPSAoKSA9PiB7CiAgICAgICAgdHJ5IHsKICAgICAgICAgICAgd2luZG93Ll9fcHJl
cFR5cGVTZWFyY2ggJiYgd2luZG93Ll9fcHJlcFR5cGVTZWFyY2goKTsKICAgICAgICAgICAgY29uc3Qg
cyA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzZWFyY2gnKTsKICAgICAgICAgICAgaWYgKCFzKSBy
ZXR1cm47CiAgICAgICAgICAgIGNvbnN0IHYgPSBTdHJpbmcocy52YWx1ZSB8fCAnJyk7CiAgICAgICAg
ICAgIHMudmFsdWUgPSB2Lmxlbmd0aCA/IHYuc2xpY2UoMCwgLTEpIDogJyc7CiAgICAgICAgICAgIHMu
Y2xhc3NMaXN0LnRvZ2dsZSgnaGFzLXZhbCcsICEhcy52YWx1ZSk7CiAgICAgICAgICAgIHMuZGlzcGF0
Y2hFdmVudChuZXcgRXZlbnQoJ2lucHV0JywgeyBidWJibGVzOiB0cnVlIH0pKTsKICAgICAgICB9IGNh
dGNoIHt9CiAgICB9OwogICAgd2luZG93Ll9fc2V0U2VhcmNoUXVlcnkgPSAocSkgPT4gewogICAgICAg
IHRyeSB7CiAgICAgICAgICAgIGNvbnN0IHMgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc2VhcmNo
Jyk7CiAgICAgICAgICAgIGlmICghcykgcmV0dXJuOwogICAgICAgICAgICBjb25zdCBuZXh0ID0gU3Ry
aW5nKHEgPT0gbnVsbCA/ICcnIDogcSk7CiAgICAgICAgICAgIGNvbnN0IHByZXYgPSBTdHJpbmcocy52
YWx1ZSB8fCAnJyk7CiAgICAgICAgICAgIC8vIOWQjOWFs+mUruWtl+mHjeWkjeaOqOmAge+8muWPquS/
neivgeaQnOe0ouahhuW8gOedgO+8jOemgeatouWGjSByZXF1ZXN0Vmlld++8iOS8muatu+W+queOr+mX
qu+8iQogICAgICAgICAgICBpZiAocHJldiA9PT0gbmV4dCAmJiBTdHJpbmcocXVlcnkgfHwgJycpID09
PSBuZXh0KSB7CiAgICAgICAgICAgICAgICB0cnkgewogICAgICAgICAgICAgICAgICAgIGNvbnN0IHdy
YXAgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc2VhcmNoLXdyYXAnKTsKICAgICAgICAgICAgICAg
ICAgICBpZiAod3JhcCAmJiAhd3JhcC5jbGFzc0xpc3QuY29udGFpbnMoJ29wZW4nKSkKICAgICAgICAg
ICAgICAgICAgICAgICAgd3JhcC5jbGFzc0xpc3QuYWRkKCdvcGVuJyk7CiAgICAgICAgICAgICAgICB9
IGNhdGNoIHt9CiAgICAgICAgICAgICAgICByZXR1cm47CiAgICAgICAgICAgIH0KICAgICAgICAgICAg
Ly8g5omT5a2X5Y2z5pe25LiK5bGP77yM5LiO56OB55uY5pCc57Si6Kej6ICmCiAgICAgICAgICAgIHMu
dmFsdWUgPSBuZXh0OwogICAgICAgICAgICBzLmNsYXNzTGlzdC50b2dnbGUoJ2hhcy12YWwnLCAhIXMu
dmFsdWUpOwogICAgICAgICAgICBjb25zdCBzY2xyID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3Nl
YXJjaC1jbHInKTsKICAgICAgICAgICAgaWYgKHNjbHIpIHNjbHIuc3R5bGUuZGlzcGxheSA9IHMudmFs
dWUgPyAnYmxvY2snIDogJ25vbmUnOwogICAgICAgICAgICBxdWVyeSA9IHMudmFsdWU7CiAgICAgICAg
ICAgIHRyeSB7CiAgICAgICAgICAgICAgICBjb25zdCB3cmFwID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5
SWQoJ3NlYXJjaC13cmFwJyk7CiAgICAgICAgICAgICAgICBpZiAod3JhcCAmJiAhd3JhcC5jbGFzc0xp
c3QuY29udGFpbnMoJ29wZW4nKSkKICAgICAgICAgICAgICAgICAgICB3aW5kb3cuX19wcmVwVHlwZVNl
YXJjaCAmJiB3aW5kb3cuX19wcmVwVHlwZVNlYXJjaCgpOwogICAgICAgICAgICAgICAgZWxzZSBpZiAo
d3JhcCkKICAgICAgICAgICAgICAgICAgICB3cmFwLmNsYXNzTGlzdC5hZGQoJ29wZW4nKTsKICAgICAg
ICAgICAgfSBjYXRjaCB7fQogICAgICAgICAgICB3aW5kb3cuX19ob3N0RmlsdGVyZWQgPSBmYWxzZTsK
ICAgICAgICAgICAgd2luZG93Ll9faG9zdEZpbHRlclEgPSAnJzsKICAgICAgICAgICAgaWYgKFN0cmlu
ZyhxdWVyeSB8fCAnJykudHJpbSgpKSB7CiAgICAgICAgICAgICAgICB3YWl0aW5nRGF0YSA9IHRydWU7
CiAgICAgICAgICAgICAgICB3aW5kb3cuX19kYXRhUmVhZHkgPSBmYWxzZTsKICAgICAgICAgICAgfQog
ICAgICAgICAgICB0cnkgewogICAgICAgICAgICAgICAgY29uc3QgY250ID0gZG9jdW1lbnQuZ2V0RWxl
bWVudEJ5SWQoJ2Jhci10eHQnKTsKICAgICAgICAgICAgICAgIGlmIChjbnQgJiYgU3RyaW5nKHF1ZXJ5
IHx8ICcnKS50cmltKCkpCiAgICAgICAgICAgICAgICAgICAgY250LnRleHRDb250ZW50ID0gdmlzaWJs
ZUxpc3QoKS5sZW5ndGggKyAnIOadoSc7CiAgICAgICAgICAgIH0gY2F0Y2gge30KICAgICAgICAgICAg
dHJ5IHsgcmVuZGVyKCk7IH0gY2F0Y2gge30KICAgICAgICAgICAgY2xlYXJUaW1lb3V0KHdpbmRvdy5f
X3FxVmlld0RlYik7CiAgICAgICAgICAgIHdpbmRvdy5fX3FxVmlld0RlYiA9IHNldFRpbWVvdXQoKCkg
PT4gewogICAgICAgICAgICAgICAgd2luZG93Ll9fcXFWaWV3RGViID0gMDsKICAgICAgICAgICAgICAg
IHJlcXVlc3RWaWV3KCk7CiAgICAgICAgICAgIH0sIDcwKTsKICAgICAgICB9IGNhdGNoIHt9CiAgICB9
OwogICAgd2luZG93Ll9fY2xlYXJRUVNlYXJjaCA9ICgpID0+IHsKICAgICAgICB0cnkgewogICAgICAg
ICAgICBxdWVyeSA9ICcnOwogICAgICAgICAgICB3aW5kb3cuX19ob3N0RmlsdGVyZWQgPSBmYWxzZTsK
ICAgICAgICAgICAgd2luZG93Ll9faG9zdEZpbHRlclEgPSAnJzsKICAgICAgICAgICAgY29uc3QgcyA9
IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzZWFyY2gnKTsKICAgICAgICAgICAgaWYgKHMpIHsKICAg
ICAgICAgICAgICAgIHMudmFsdWUgPSAnJzsKICAgICAgICAgICAgICAgIHMuY2xhc3NMaXN0LnJlbW92
ZSgnaGFzLXZhbCcpOwogICAgICAgICAgICAgICAgdHJ5IHsgcy5ibHVyKCk7IH0gY2F0Y2gge30KICAg
ICAgICAgICAgfQogICAgICAgICAgICBjb25zdCBzY2xyID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQo
J3NlYXJjaC1jbHInKTsKICAgICAgICAgICAgaWYgKHNjbHIpIHNjbHIuc3R5bGUuZGlzcGxheSA9ICdu
b25lJzsKICAgICAgICAgICAgY29uc3Qgd3JhcCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzZWFy
Y2gtd3JhcCcpOwogICAgICAgICAgICBpZiAod3JhcCkgd3JhcC5jbGFzc0xpc3QucmVtb3ZlKCdvcGVu
Jyk7CiAgICAgICAgICAgIHRyeSB7IHJlbmRlcigpOyB9IGNhdGNoIHt9CiAgICAgICAgfSBjYXRjaCB7
fQogICAgfTsKICAgIC8vIENhcHR1cmUgQ3RybCtGIGluc2lkZSBXZWJWaWV3IChDaHJvbWl1bSBmaW5k
IGlzIGRpc2FibGVkLCBidXQgc3RpbGwgaGFuZGxlIGhlcmUpCiAgICBkb2N1bWVudC5hZGRFdmVudExp
c3RlbmVyKCdrZXlkb3duJywgZSA9PiB7CiAgICAgICAgaWYgKChlLmN0cmxLZXkgfHwgZS5tZXRhS2V5
KSAmJiAhZS5hbHRLZXkgJiYgKGUua2V5ID09PSAnZicgfHwgZS5rZXkgPT09ICdGJykpIHsKICAgICAg
ICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOwogICAgICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwog
ICAgICAgICAgICBvcGVuU2VhcmNoKCk7CiAgICAgICAgfQogICAgfSwgdHJ1ZSk7CiAgICBidG5TZWFy
Y2guYWRkRXZlbnRMaXN0ZW5lcignY2xpY2snLCBlID0+IHsKICAgICAgICBlLnN0b3BQcm9wYWdhdGlv
bigpOwogICAgICAgIG9wZW5TZWFyY2goKTsKICAgIH0pOwogICAgbGV0IF9fc3JjaENvbXBvc2luZyA9
IGZhbHNlOwogICAgY29uc3QgX19mbHVzaFNlYXJjaElucHV0ID0gKCkgPT4gewogICAgICAgIHF1ZXJ5
ID0gc3JjaC52YWx1ZTsKICAgICAgICBzcmNoLmNsYXNzTGlzdC50b2dnbGUoJ2hhcy12YWwnLCAhIXF1
ZXJ5KTsKICAgICAgICBzY2xyLnN0eWxlLmRpc3BsYXkgPSBxdWVyeSA/ICdibG9jaycgOiAnbm9uZSc7
CiAgICAgICAgbGlzdEVsLnNjcm9sbFRvcCA9IDA7CiAgICAgICAgd2luZG93Ll9faG9zdEZpbHRlcmVk
ID0gZmFsc2U7CiAgICAgICAgd2luZG93Ll9faG9zdEZpbHRlclEgPSAnJzsKICAgICAgICB0cnkgeyBy
ZW5kZXIoKTsgfSBjYXRjaCB7fQogICAgICAgIGNsZWFyVGltZW91dChkZWIpOwogICAgICAgIGRlYiA9
IHNldFRpbWVvdXQocmVxdWVzdFZpZXcsIDgwKTsKICAgIH07CiAgICBzcmNoLmFkZEV2ZW50TGlzdGVu
ZXIoJ2NvbXBvc2l0aW9uc3RhcnQnLCAoKSA9PiB7IF9fc3JjaENvbXBvc2luZyA9IHRydWU7IH0pOwog
ICAgc3JjaC5hZGRFdmVudExpc3RlbmVyKCdjb21wb3NpdGlvbmVuZCcsICgpID0+IHsKICAgICAgICBf
X3NyY2hDb21wb3NpbmcgPSBmYWxzZTsKICAgICAgICBfX2ZsdXNoU2VhcmNoSW5wdXQoKTsKICAgIH0p
OwogICAgc3JjaC5hZGRFdmVudExpc3RlbmVyKCdpbnB1dCcsICgpID0+IHsKICAgICAgICBpZiAoX19z
cmNoQ29tcG9zaW5nKSB7CiAgICAgICAgICAgIHF1ZXJ5ID0gc3JjaC52YWx1ZTsKICAgICAgICAgICAg
c3JjaC5jbGFzc0xpc3QudG9nZ2xlKCdoYXMtdmFsJywgISFxdWVyeSk7CiAgICAgICAgICAgIHNjbHIu
c3R5bGUuZGlzcGxheSA9IHF1ZXJ5ID8gJ2Jsb2NrJyA6ICdub25lJzsKICAgICAgICAgICAgcmV0dXJu
OwogICAgICAgIH0KICAgICAgICBfX2ZsdXNoU2VhcmNoSW5wdXQoKTsKICAgIH0pOwogICAgc3JjaC5h
ZGRFdmVudExpc3RlbmVyKCdmb2N1cycsICgpID0+IHsKICAgICAgICAvLyBJZGVtcG90ZW50IG9uIEFI
SyBzaWRlIOKAlCBzYWZlLCBidXQgYXZvaWQgc3BhbW1pbmcgZHVyaW5nIElNRQogICAgICAgIHRyeSB7
IGFoaygnZm9jdXNQYW5lbCcpOyB9IGNhdGNoIHt9CiAgICB9KTsKICAgIHNyY2guYWRkRXZlbnRMaXN0
ZW5lcignYmx1cicsICgpID0+IHsKICAgICAgICBzZXRUaW1lb3V0KCgpID0+IHsKICAgICAgICAgICAg
aWYgKGRvY3VtZW50LmFjdGl2ZUVsZW1lbnQgPT09IHNyY2gpIHJldHVybjsKICAgICAgICAgICAgaWYg
KGRvY3VtZW50LmFjdGl2ZUVsZW1lbnQgPT09IHNjbHIgfHwgKHNjbHIgJiYgc2Nsci5jb250YWlucyhk
b2N1bWVudC5hY3RpdmVFbGVtZW50KSkpIHJldHVybjsKICAgICAgICAgICAgaWYgKGRvY3VtZW50LmFj
dGl2ZUVsZW1lbnQgPT09IGJ0blRvZGF5IHx8IChidG5Ub2RheSAmJiBidG5Ub2RheS5jb250YWlucyhk
b2N1bWVudC5hY3RpdmVFbGVtZW50KSkpIHJldHVybjsKICAgICAgICAgICAgLy8gSU1FIGNhbmRpZGF0
ZSBVSSBzdGVhbHMgZm9jdXMgYnJpZWZseSDigJQga2VlcCBzZWFyY2ggaWYgc3RpbGwgY29tcG9zaW5n
CiAgICAgICAgICAgIGlmIChfX3NyY2hDb21wb3NpbmcpIHJldHVybjsKICAgICAgICAgICAgY2xvc2VT
ZWFyY2hVaSgpOwogICAgICAgICAgICBhaGsoJ2JsdXJQYW5lbCcpOwogICAgICAgIH0sIDI4MCk7CiAg
ICB9KTsKICAgIHNyY2guYWRkRXZlbnRMaXN0ZW5lcigna2V5ZG93bicsIGUgPT4gewogICAgICAgIC8v
IEN0cmwrSSAvIEN0cmwrSzogbW92ZSBjbGlwIHNlbGVjdGlvbiAobm90IGluc2VydCBjaGFyIC8gYnJv
d3NlciBzaG9ydGN1dCkKICAgICAgICBpZiAoKGUuY3RybEtleSB8fCBlLm1ldGFLZXkpICYmIChlLmtl
eSA9PT0gJ2knIHx8IGUua2V5ID09PSAnSScpKSB7CiAgICAgICAgICAgIGUucHJldmVudERlZmF1bHQo
KTsKICAgICAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICAgICAgd2luZG93Ll9fbmF2
ICYmIHdpbmRvdy5fX25hdigndXAnKTsKICAgICAgICAgICAgcmV0dXJuOwogICAgICAgIH0KICAgICAg
ICBpZiAoKGUuY3RybEtleSB8fCBlLm1ldGFLZXkpICYmIChlLmtleSA9PT0gJ2snIHx8IGUua2V5ID09
PSAnSycpKSB7CiAgICAgICAgICAgIGUucHJldmVudERlZmF1bHQoKTsKICAgICAgICAgICAgZS5zdG9w
UHJvcGFnYXRpb24oKTsKICAgICAgICAgICAgd2luZG93Ll9fbmF2ICYmIHdpbmRvdy5fX25hdignZG93
bicpOwogICAgICAgICAgICByZXR1cm47CiAgICAgICAgfQogICAgICAgIGlmIChlLmtleSA9PT0gJ0Fy
cm93RG93bicpIHsKICAgICAgICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOwogICAgICAgICAgICBlLnN0
b3BQcm9wYWdhdGlvbigpOwogICAgICAgICAgICB3aW5kb3cuX19uYXYgJiYgd2luZG93Ll9fbmF2KCdk
b3duJyk7CiAgICAgICAgICAgIHJldHVybjsKICAgICAgICB9CiAgICAgICAgaWYgKGUua2V5ID09PSAn
QXJyb3dVcCcpIHsKICAgICAgICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOwogICAgICAgICAgICBlLnN0
b3BQcm9wYWdhdGlvbigpOwogICAgICAgICAgICB3aW5kb3cuX19uYXYgJiYgd2luZG93Ll9fbmF2KCd1
cCcpOwogICAgICAgICAgICByZXR1cm47CiAgICAgICAgfQogICAgICAgIGlmIChlLmtleSA9PT0gJ0Vz
Y2FwZScpIHsKICAgICAgICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOwogICAgICAgICAgICBlLnN0b3BQ
cm9wYWdhdGlvbigpOwogICAgICAgICAgICAvLyBBbHdheXMgZGlzbWlzcyB0aGUgd2hvbGUgcGFuZWwg
KG5vdCBqdXN0IHRoZSBzZWFyY2ggZmllbGQpCiAgICAgICAgICAgIGlmICghcGlubmVkVUkpIGFoaygn
aGlkZScpOwogICAgICAgICAgICByZXR1cm47CiAgICAgICAgfQogICAgICAgIGUuc3RvcFByb3BhZ2F0
aW9uKCk7CiAgICB9KTsKICAgIHNjbHIuYWRkRXZlbnRMaXN0ZW5lcignY2xpY2snLCBlID0+IHsKICAg
ICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgICAgIHNyY2gudmFsdWUgPSBxdWVyeSA9ICcnOwog
ICAgICAgIHNjbHIuc3R5bGUuZGlzcGxheSA9ICdub25lJzsKICAgICAgICBzcmNoLmNsYXNzTGlzdC5y
ZW1vdmUoJ2hhcy12YWwnKTsKICAgICAgICByZXF1ZXN0VmlldygpOwogICAgICAgIGFoaygnZm9jdXNQ
YW5lbCcpOwogICAgICAgIHNyY2guZm9jdXMoKTsKICAgIH0pOwoKICAgIGNvbnN0IFRBQl9OQU1FUyA9
IHsgYWxsOiAn5YWo6YOoJywgdGV4dDogJ+aWh+acrCcsIGltYWdlOiAn5Zu+5YOPJywgZmlsZTogJ+aW
h+S7ticsIHJlY2VudDogJ+acgOi/kScsIHBpbm5lZDogJ+aUtuiXjycgfTsKICAgIGNvbnN0IGNsckRs
ZyA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjbHItZGxnJyk7CiAgICBjb25zdCBjbHJBbGxDYiA9
IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjbHItYWxsJyk7CiAgICBmdW5jdGlvbiBvcGVuQ2xlYXJE
bGcoKSB7CiAgICAgICAgY29uc3QgbmFtZSA9IFRBQl9OQU1FU1tjdXJUYWJdIHx8ICflvZPliY0nOwog
ICAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjbHItdGl0bGUnKS50ZXh0Q29udGVudCA9ICfm
uIXnqbrjgIwnICsgbmFtZSArICfjgI3vvJ8nOwogICAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlk
KCdjbHItZGVzYycpLnRleHRDb250ZW50ID0gY3VyVGFiID09PSAncmVjZW50JwogICAgICAgICAgICA/
ICfmuIXnqbrmnKrlm7rlrprnmoTmnIDov5Hmlofku7blpLnvvJvlt7Llm7rlrprnmoTot6/lvoTkvJrk
v53nlZnjgIInCiAgICAgICAgICAgIDogKGN1clRhYiA9PT0gJ3Bpbm5lZCcKICAgICAgICAgICAgPyAn
6buY6K6k5LuF5riF56m65b2T5aSp55qE5pS26JeP6aG544CC5Yu+6YCJ44CM5riF56m65omA5pyJ44CN
5Y+v5riF6Zmk6K+l6YCJ6aG55Y2h5YWo6YOo5YaF5a6544CCJwogICAgICAgICAgICA6ICfku4XmuIXn
qbrlvZPliY3pgInpobnljaHjgILpu5jorqTlj6rmuIXlvZPlpKnvvJvmlLbol4/pobnkuI3kvJrooqvm
uIXpmaTjgILli77pgInjgIzmuIXnqbrmiYDmnInjgI3lj6/muIXpmaTor6XpgInpobnljaHlhajpg6jm
l6XmnJ/jgIInKTsKICAgICAgICBjbHJBbGxDYi5jaGVja2VkID0gZmFsc2U7CiAgICAgICAgY2xyRGxn
LmNsYXNzTGlzdC5hZGQoJ29uJyk7CiAgICB9CiAgICBmdW5jdGlvbiBjbG9zZUNsZWFyRGxnKCkgewog
ICAgICAgIGNsckRsZy5jbGFzc0xpc3QucmVtb3ZlKCdvbicpOwogICAgfQogICAgZG9jdW1lbnQuZ2V0
RWxlbWVudEJ5SWQoJ2J0bi1jbHInKS5hZGRFdmVudExpc3RlbmVyKCdjbGljaycsIGUgPT4gewogICAg
ICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAgICAgb3BlbkNsZWFyRGxnKCk7CiAgICB9KTsKICAg
IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjbHItY2FuY2VsJykuYWRkRXZlbnRMaXN0ZW5lcignY2xp
Y2snLCBlID0+IHsKICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgICAgIGNsb3NlQ2xlYXJE
bGcoKTsKICAgIH0pOwogICAgY2xyRGxnLmFkZEV2ZW50TGlzdGVuZXIoJ2NsaWNrJywgZSA9PiB7CiAg
ICAgICAgaWYgKGUudGFyZ2V0ID09PSBjbHJEbGcpIGNsb3NlQ2xlYXJEbGcoKTsKICAgIH0pOwogICAg
ZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2Nsci1vaycpLmFkZEV2ZW50TGlzdGVuZXIoJ2NsaWNrJywg
ZSA9PiB7CiAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICBjb25zdCBzY29wZSA9IChj
dXJUYWIgPT09ICdyZWNlbnQnKSA/ICdhbGwnIDogKGNsckFsbENiLmNoZWNrZWQgPyAnYWxsJyA6ICd0
b2RheScpOwogICAgICAgIGNsb3NlQ2xlYXJEbGcoKTsKICAgICAgICBhaGsoJ2NsZWFyJywgY3VyVGFi
LCBzY29wZSk7CiAgICB9KTsKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdtdWx0aS1jbnQnKS5h
ZGRFdmVudExpc3RlbmVyKCdjbGljaycsIGUgPT4gewogICAgICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7
CiAgICAgICAgY2xlYXJNdWx0aSh0cnVlKTsKICAgIH0pOwogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5
SWQoJ2J0bi1waW4nKS5hZGRFdmVudExpc3RlbmVyKCdjbGljaycsIGUgPT4gewogICAgICAgIGUuc3Rv
cFByb3BhZ2F0aW9uKCk7CiAgICAgICAgcGlubmVkVUkgPSAhcGlubmVkVUk7CiAgICAgICAgZS5jdXJy
ZW50VGFyZ2V0LmNsYXNzTGlzdC50b2dnbGUoJ29uJywgcGlubmVkVUkpOwogICAgICAgIGFoaygndG9n
Z2xlUGluJywgcGlubmVkVUkgPyAnMScgOiAnMCcpOwogICAgfSk7CgogICAgd2luZG93Ll9fdXBkYXRl
Q2xpcHMgPSBwYXlsb2FkID0+IHsKICAgICAgICAvLyBLZWVwIHByZXZpb3VzIHNjcm9sbCBmb3IgbG9h
ZC1tb3JlOyByZXNldCB3aGVuIG9wZW5pbmcgcGFuZWwgdG8gZmlyc3QgaXRlbQogICAgICAgIGNvbnN0
IGtlZXBTY3JvbGwgPSAhc2VsZWN0Rmlyc3RPblNob3c7CiAgICAgICAgY29uc3Qgc3QgPSBsaXN0RWwu
c2Nyb2xsVG9wOwogICAgICAgIHdpbmRvdy5fX3dhaXRpbmdWaWV3ID0gZmFsc2U7CiAgICAgICAgY29u
c3Qgd2FzQXBwZW5kID0gcGF5bG9hZCAmJiBwYXlsb2FkLmFwcGVuZDsKICAgICAgICBsb2FkaW5nTW9y
ZSA9IGZhbHNlOwogICAgICAgIGlmICh3aW5kb3cuX19sb2FkTW9yZVdhdGNoKSB7CiAgICAgICAgICAg
IGNsZWFyVGltZW91dCh3aW5kb3cuX19sb2FkTW9yZVdhdGNoKTsKICAgICAgICAgICAgd2luZG93Ll9f
bG9hZE1vcmVXYXRjaCA9IDA7CiAgICAgICAgfQogICAgICAgIGNvbnN0IHByZXZJdGVtcyA9IGFsbENs
aXBzOwogICAgICAgIGxldCBuZXh0SXRlbXMgPSBbXTsKICAgICAgICBsZXQgbmV4dFRvdGFsID0gMDsK
ICAgICAgICBsZXQgbmV4dEZpbHRlcmVkID0gZmFsc2U7CiAgICAgICAgbGV0IHBUYWIgPSAnJzsKICAg
ICAgICBsZXQgcFBpbm5lZFRvdGFsID0gLTE7CiAgICAgICAgaWYgKEFycmF5LmlzQXJyYXkocGF5bG9h
ZCkpIHsKICAgICAgICAgICAgbmV4dEl0ZW1zID0gcGF5bG9hZDsKICAgICAgICAgICAgbmV4dFRvdGFs
ID0gcGF5bG9hZC5sZW5ndGg7CiAgICAgICAgICAgIG5leHRGaWx0ZXJlZCA9IGZhbHNlOwogICAgICAg
IH0gZWxzZSBpZiAocGF5bG9hZCAmJiB0eXBlb2YgcGF5bG9hZCA9PT0gJ29iamVjdCcpIHsKICAgICAg
ICAgICAgbmV4dFRvdGFsID0gTnVtYmVyKHBheWxvYWQudG90YWwpIHx8IDA7CiAgICAgICAgICAgIG5l
eHRJdGVtcyA9IEFycmF5LmlzQXJyYXkocGF5bG9hZC5pdGVtcykgPyBwYXlsb2FkLml0ZW1zIDogW107
CiAgICAgICAgICAgIHBUYWIgPSBwYXlsb2FkLnRhYiAhPSBudWxsID8gU3RyaW5nKHBheWxvYWQudGFi
KSA6ICcnOwogICAgICAgICAgICBpZiAocGF5bG9hZC5waW5uZWRUb3RhbCAhPSBudWxsICYmIHBheWxv
YWQucGlubmVkVG90YWwgIT09ICcnKQogICAgICAgICAgICAgICAgcFBpbm5lZFRvdGFsID0gTnVtYmVy
KHBheWxvYWQucGlubmVkVG90YWwpIHx8IDA7CiAgICAgICAgICAgIGNvbnN0IHBxMCA9IHBheWxvYWQu
cXVlcnkgIT0gbnVsbCA/IFN0cmluZyhwYXlsb2FkLnF1ZXJ5KSA6ICcnOwogICAgICAgICAgICBuZXh0
RmlsdGVyZWQgPSAhIShwYXlsb2FkLmZpbHRlcmVkIHx8IChwcTAgJiYgcHEwLnRyaW0oKSkpOwogICAg
ICAgICAgICBpZiAocGF5bG9hZC5hcHBlbmQpIHsKICAgICAgICAgICAgICAgIC8vIEFwcGVuZCBvbmx5
IGFwcGxpZXMgdG8gdGhlIHRhYiB3ZSdyZSBjdXJyZW50bHkgdmlld2luZwogICAgICAgICAgICAgICAg
aWYgKHBUYWIgJiYgcFRhYiAhPT0gY3VyVGFiKQogICAgICAgICAgICAgICAgICAgIHJldHVybjsKICAg
ICAgICAgICAgICAgIGNvbnN0IHNlZW4gPSBuZXcgU2V0KGFsbENsaXBzLm1hcChjID0+ICtjLmlkKSk7
CiAgICAgICAgICAgICAgICBjb25zdCBtZXJnZWQgPSBhbGxDbGlwcy5zbGljZSgpOwogICAgICAgICAg
ICAgICAgbmV4dEl0ZW1zLmZvckVhY2goaXQgPT4gewogICAgICAgICAgICAgICAgICAgIGlmICghc2Vl
bi5oYXMoK2l0LmlkKSkgbWVyZ2VkLnB1c2goaXQpOwogICAgICAgICAgICAgICAgfSk7CiAgICAgICAg
ICAgICAgICBuZXh0SXRlbXMgPSBtZXJnZWQ7CiAgICAgICAgICAgICAgICBuZXh0VG90YWwgPSBNYXRo
Lm1heChuZXh0VG90YWwsIG5leHRJdGVtcy5sZW5ndGgpOwogICAgICAgICAgICB9CiAgICAgICAgICAg
IC8vIOaQnOe0ouahhuS7peaJk+Wtl+mVnOWDj+S4uuWHhu+8jOe7neS4jeiiq+a7nuWQjueahOejgeeb
mOe7k+aenOWGmeWbnuaXp+WFs+mUruWtlwogICAgICAgICAgICB0cnkgewogICAgICAgICAgICAgICAg
Y29uc3QgcyA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzZWFyY2gnKTsKICAgICAgICAgICAgICAg
IGlmIChzICYmIFN0cmluZyhzLnZhbHVlIHx8ICcnKS5sZW5ndGgpCiAgICAgICAgICAgICAgICAgICAg
cXVlcnkgPSBzLnZhbHVlOwogICAgICAgICAgICAgICAgZWxzZSBpZiAocHEwICE9PSAnJyAmJiAhU3Ry
aW5nKHF1ZXJ5IHx8ICcnKS50cmltKCkpCiAgICAgICAgICAgICAgICAgICAgcXVlcnkgPSBwcTA7CiAg
ICAgICAgICAgIH0gY2F0Y2gge30KICAgICAgICB9IGVsc2UgewogICAgICAgICAgICBuZXh0SXRlbXMg
PSBbXTsKICAgICAgICAgICAgbmV4dFRvdGFsID0gMDsKICAgICAgICAgICAgbmV4dEZpbHRlcmVkID0g
ZmFsc2U7CiAgICAgICAgfQoKICAgICAgICBjb25zdCBib3hRID0gU3RyaW5nKHF1ZXJ5IHx8ICcnKS50
cmltKCk7CiAgICAgICAgY29uc3QgcHVzaFEgPSAocGF5bG9hZCAmJiB0eXBlb2YgcGF5bG9hZCA9PT0g
J29iamVjdCcgJiYgcGF5bG9hZC5xdWVyeSAhPSBudWxsKQogICAgICAgICAgICA/IFN0cmluZyhwYXls
b2FkLnF1ZXJ5KS50cmltKCkgOiAnJzsKCiAgICAgICAgLy8gQWx3YXlzIHJlZnJlc2gg5pS26JePIGJh
ZGdlIGZyb20gaG9zdCB3aGVuIHByb3ZpZGVkCiAgICAgICAgaWYgKHBQaW5uZWRUb3RhbCA+PSAwKQog
ICAgICAgICAgICBwaW5uZWRUb3RhbCA9IHBQaW5uZWRUb3RhbDsKCiAgICAgICAgLy8gU3RhbGUgc2Vh
cmNoIHB1c2ggKGUuZy4gInNxdWFyZSBsb2dpIiBsYW5kcyBhZnRlciB1c2VyIHR5cGVkICJzcXVhcmUg
bG9naW4iKSDigJRjYWNoZSBvbmx5CiAgICAgICAgaWYgKCF3YXNBcHBlbmQgJiYgbmV4dEZpbHRlcmVk
ICYmIHB1c2hRICYmIGJveFEgJiYgcHVzaFEgIT09IGJveFEpIHsKICAgICAgICAgICAgdmlld01lbS5z
ZXQodmlld01lbUtleShwVGFiIHx8IGN1clRhYiwgcHVzaFEsIHRvZGF5T25seSksIHsKICAgICAgICAg
ICAgICAgIGl0ZW1zOiBuZXh0SXRlbXMuc2xpY2UoKSwKICAgICAgICAgICAgICAgIHRvdGFsOiBuZXh0
VG90YWwKICAgICAgICAgICAgfSk7CiAgICAgICAgICAgIHJldHVybjsKICAgICAgICB9CgogICAgICAg
IC8vIFN0YWxlIHB1c2ggZm9yIGFub3RoZXIgdGFiOiBvbmx5IHJlZnJlc2ggdGhhdCB0YWIncyB2aWV3
TWVtLCBkb24ndCBoaWphY2sgVUkKICAgICAgICBpZiAoIXdhc0FwcGVuZCAmJiBwVGFiICYmIHBUYWIg
IT09IGN1clRhYikgewogICAgICAgICAgICBjb25zdCBtZW1RID0gKHBheWxvYWQgJiYgdHlwZW9mIHBh
eWxvYWQgPT09ICdvYmplY3QnICYmIHBheWxvYWQucXVlcnkgIT0gbnVsbCkKICAgICAgICAgICAgICAg
ID8gU3RyaW5nKHBheWxvYWQucXVlcnkpIDogJyc7CiAgICAgICAgICAgIHZpZXdNZW0uc2V0KHZpZXdN
ZW1LZXkocFRhYiwgbWVtUSwgdG9kYXlPbmx5KSwgewogICAgICAgICAgICAgICAgaXRlbXM6IG5leHRJ
dGVtcy5zbGljZSgpLAogICAgICAgICAgICAgICAgdG90YWw6IG5leHRUb3RhbAogICAgICAgICAgICB9
KTsKICAgICAgICAgICAgLy8gU3RpbGwgdXBkYXRlIHBpbiBiYWRnZSBpZiBob3N0IHNlbnQgaXQKICAg
ICAgICAgICAgdHJ5IHsKICAgICAgICAgICAgICAgIGNvbnN0IHBpbkNudCA9IGRvY3VtZW50LmdldEVs
ZW1lbnRCeUlkKCdwaW4tY250Jyk7CiAgICAgICAgICAgICAgICBpZiAocGluQ250ICYmIHBpbm5lZFRv
dGFsID4gMCkgewogICAgICAgICAgICAgICAgICAgIHBpbkNudC50ZXh0Q29udGVudCA9IHBpbm5lZFRv
dGFsOwogICAgICAgICAgICAgICAgICAgIHBpbkNudC5zdHlsZS5kaXNwbGF5ID0gJyc7CiAgICAgICAg
ICAgICAgICB9CiAgICAgICAgICAgIH0gY2F0Y2gge30KICAgICAgICAgICAgLy8gUVEg5pCc57Si5pu+
5Zu65a6a5o6oIGFsbCB0YWIg4oaSIOW9k+WJjSB0YWIg5Lya5LiA55u06aqo5p6277yb6KGl5LiA5qyh
IHJlcXVlc3RWaWV3CiAgICAgICAgICAgIGlmICh3YWl0aW5nRGF0YSAmJiBwdXNoUSA9PT0gYm94USkg
ewogICAgICAgICAgICAgICAgc2V0VGltZW91dCgoKSA9PiB7CiAgICAgICAgICAgICAgICAgICAgaWYg
KHdhaXRpbmdEYXRhICYmIGN1clRhYiAhPT0gcFRhYikKICAgICAgICAgICAgICAgICAgICAgICAgcmVx
dWVzdFZpZXcoKTsKICAgICAgICAgICAgICAgIH0sIDQwKTsKICAgICAgICAgICAgfQogICAgICAgICAg
ICByZXR1cm47CiAgICAgICAgfQoKICAgICAgICAvLyBCb290c3RyYXAgcmFjZTogQUhLIHB1c2hlZCBl
bXB0eSBiZWZvcmUgV2FybUFsbFZpZXdzIOKAlGtlZXAgc2tlbGV0b24sIGlnbm9yZQogICAgICAgIGNv
bnN0IHFPbiA9IFN0cmluZyhxdWVyeSB8fCAnJykudHJpbSgpLmxlbmd0aCA+IDA7CiAgICAgICAgaWYg
KCF3YXNBcHBlbmQgJiYgIW5leHRJdGVtcy5sZW5ndGggJiYgbmV4dFRvdGFsIDw9IDAgJiYgIXFPbiAm
JiAhbmV4dEZpbHRlcmVkICYmICFzYXdOb25FbXB0eSkgewogICAgICAgICAgICBpZiAoIXdpbmRvdy5f
X2VtcHR5RmFsbGJhY2tUKSB7CiAgICAgICAgICAgICAgICB3aW5kb3cuX19lbXB0eUZhbGxiYWNrVCA9
IHNldFRpbWVvdXQoKCkgPT4gewogICAgICAgICAgICAgICAgICAgIHdpbmRvdy5fX2VtcHR5RmFsbGJh
Y2tUID0gMDsKICAgICAgICAgICAgICAgICAgICBpZiAoc2F3Tm9uRW1wdHkpIHJldHVybjsKICAgICAg
ICAgICAgICAgICAgICAvLyBUcnVseSBlbXB0eSBpbnN0YWxsIGFmdGVyIHdhaXQKICAgICAgICAgICAg
ICAgICAgICBzYXdOb25FbXB0eSA9IHRydWU7CiAgICAgICAgICAgICAgICAgICAgaG9zdFB1c2hlZE9u
Y2UgPSB0cnVlOwogICAgICAgICAgICAgICAgICAgIHdpbmRvdy5fX2RhdGFSZWFkeSA9IHRydWU7CiAg
ICAgICAgICAgICAgICAgICAgYWxsQ2xpcHMgPSBbXTsKICAgICAgICAgICAgICAgICAgICBkaXNrVG90
YWwgPSAwOwogICAgICAgICAgICAgICAgICAgIGNsZWFyV2FpdGluZ0RhdGEoKTsKICAgICAgICAgICAg
ICAgICAgICB0cnkgeyByZW5kZXIoKTsgfSBjYXRjaCB7fQogICAgICAgICAgICAgICAgfSwgNDUwMCk7
CiAgICAgICAgICAgIH0KICAgICAgICAgICAgd2FpdGluZ0RhdGEgPSB0cnVlOwogICAgICAgICAgICB3
aW5kb3cuX19kYXRhUmVhZHkgPSBmYWxzZTsKICAgICAgICAgICAgaG9zdFB1c2hlZE9uY2UgPSBmYWxz
ZTsKICAgICAgICAgICAgc2V0Qm9vdExvYWRpbmcodHJ1ZSk7CiAgICAgICAgICAgIHRyeSB7IHJlbmRl
cigpOyB9IGNhdGNoIHt9CiAgICAgICAgICAgIHJldHVybjsKICAgICAgICB9CgogICAgICAgIGNsZWFy
V2FpdGluZ0RhdGEoKTsKICAgICAgICBhbGxDbGlwcyA9IG5leHRJdGVtczsKICAgICAgICBkaXNrVG90
YWwgPSBuZXh0VG90YWw7CiAgICAgICAgLy8gS2VlcCBiYXIgY29uc2lzdGVudCBpZiBsaXN0IGdyZXcg
cGFzdCBhIHN0YWxlIHRvdGFsCiAgICAgICAgaWYgKGFsbENsaXBzLmxlbmd0aCA+IGRpc2tUb3RhbCkK
ICAgICAgICAgICAgZGlza1RvdGFsID0gYWxsQ2xpcHMubGVuZ3RoOwogICAgICAgIHdpbmRvdy5fX2hv
c3RGaWx0ZXJlZCA9IG5leHRGaWx0ZXJlZDsKICAgICAgICB3aW5kb3cuX19ob3N0RmlsdGVyUSA9IChu
ZXh0RmlsdGVyZWQgJiYgcHVzaFEpID8gcHVzaFEgOiAnJzsKICAgICAgICAvLyBGaWx0ZXJlZCBzZWFy
Y2ggd2l0aCAwIGhpdHMg4oCUbXVzdCBsZWF2ZSBza2VsZXRvbiAoaG9zdCBkaWQgcmVzcG9uZCkKICAg
ICAgICBpZiAoIXdhc0FwcGVuZCAmJiBuZXh0RmlsdGVyZWQgJiYgIWFsbENsaXBzLmxlbmd0aCAmJiBk
aXNrVG90YWwgPD0gMCkgewogICAgICAgICAgICBob3N0UHVzaGVkT25jZSA9IHRydWU7CiAgICAgICAg
ICAgIHNhd05vbkVtcHR5ID0gdHJ1ZTsKICAgICAgICB9CiAgICAgICAgaWYgKGFsbENsaXBzLmxlbmd0
aCB8fCBkaXNrVG90YWwgPiAwKQogICAgICAgICAgICBzYXdOb25FbXB0eSA9IHRydWU7CiAgICAgICAg
aWYgKHdpbmRvdy5fX2VtcHR5RmFsbGJhY2tUKSB7CiAgICAgICAgICAgIGNsZWFyVGltZW91dCh3aW5k
b3cuX19lbXB0eUZhbGxiYWNrVCk7CiAgICAgICAgICAgIHdpbmRvdy5fX2VtcHR5RmFsbGJhY2tUID0g
MDsKICAgICAgICB9CiAgICAgICAgaWYgKCF3YXNBcHBlbmQpIHsKICAgICAgICAgICAgY29uc3QgbWVt
USA9IChwYXlsb2FkICYmIHR5cGVvZiBwYXlsb2FkID09PSAnb2JqZWN0JyAmJiBwYXlsb2FkLnF1ZXJ5
ICE9IG51bGwpCiAgICAgICAgICAgICAgICA/IFN0cmluZyhwYXlsb2FkLnF1ZXJ5KSA6IHF1ZXJ5Owog
ICAgICAgICAgICB2aWV3TWVtLnNldCh2aWV3TWVtS2V5KGN1clRhYiwgbWVtUSwgdG9kYXlPbmx5KSwg
ewogICAgICAgICAgICAgICAgaXRlbXM6IGFsbENsaXBzLnNsaWNlKCksCiAgICAgICAgICAgICAgICB0
b3RhbDogZGlza1RvdGFsCiAgICAgICAgICAgIH0pOwogICAgICAgIH0KICAgICAgICB3aW5kb3cuX19k
YXRhUmVhZHkgPSB0cnVlOwogICAgICAgIGhvc3RQdXNoZWRPbmNlID0gdHJ1ZTsKCiAgICAgICAgLy8g
TWlkLXdoZWVsOiBrZWVwIGRhdGEsIGRlbGF5IERPTSBzbyBzY3JvbGwvZHJhZyBuZXZlciBoaXRjaCBv
biBhcHBlbmQgcGFpbnQKICAgICAgICAvLyBFeGNlcHRpb246IGxvY2F0aW5nIGEgcGFzdGUgdGFyZ2V0
IOKAlCBtdXN0IHBhaW50IGltbWVkaWF0ZWx5CiAgICAgICAgaWYgKHdhc0FwcGVuZCAmJiB3aW5kb3cu
X19zY3JvbGxCdXN5ICYmICF3aW5kb3cuX19wZW5kaW5nSnVtcElkKSB7CiAgICAgICAgICAgIGNvbnN0
IGZyb21MZW4gPSAocHJldkl0ZW1zICYmIHByZXZJdGVtcy5sZW5ndGgpID8gcHJldkl0ZW1zLmxlbmd0
aCA6IDA7CiAgICAgICAgICAgIGlmICghX3BlbmRpbmdBcHBlbmQpCiAgICAgICAgICAgICAgICBfcGVu
ZGluZ0FwcGVuZCA9IHsgZnJvbUxlbjogZnJvbUxlbiB9OwogICAgICAgICAgICB0cnkgeyByZWZyZXNo
TGlzdENocm9tZSgpOyB9IGNhdGNoIHt9CiAgICAgICAgICAgIHJldHVybjsKICAgICAgICB9CgogICAg
ICAgIGNvbnN0IHdhc0Jvb3RMb2FkaW5nID0gYm9vdExvYWRpbmc7CiAgICAgICAgbGV0IHNhbWVQYWlu
dCA9IGZhbHNlOwogICAgICAgIGNvbnN0IHByZXZMZW4gPSAocHJldkl0ZW1zICYmIHByZXZJdGVtcy5s
ZW5ndGgpID8gcHJldkl0ZW1zLmxlbmd0aCA6IDA7CiAgICAgICAgaWYgKCF3YXNBcHBlbmQgJiYgIXdh
c0Jvb3RMb2FkaW5nICYmIHByZXZJdGVtcyAmJiBwcmV2SXRlbXMubGVuZ3RoID09PSBhbGxDbGlwcy5s
ZW5ndGggJiYgcHJldkl0ZW1zLmxlbmd0aCkgewogICAgICAgICAgICBzYW1lUGFpbnQgPSB0cnVlOwog
ICAgICAgICAgICBmb3IgKGxldCBpID0gMDsgaSA8IGFsbENsaXBzLmxlbmd0aDsgaSsrKSB7CiAgICAg
ICAgICAgICAgICBpZiAoK3ByZXZJdGVtc1tpXS5pZCAhPT0gK2FsbENsaXBzW2ldLmlkKSB7IHNhbWVQ
YWludCA9IGZhbHNlOyBicmVhazsgfQogICAgICAgICAgICB9CiAgICAgICAgICAgIGlmIChzYW1lUGFp
bnQgJiYgIWxpc3RFbC5xdWVyeVNlbGVjdG9yKCcuaXRtJykpIHNhbWVQYWludCA9IGZhbHNlOwogICAg
ICAgIH0KICAgICAgICBjb25zdCBmaW5pc2hVcGRhdGUgPSAoKSA9PiB7CiAgICAgICAgICAgIGNsZWFy
V2FpdGluZ0RhdGEoKTsKICAgICAgICAgICAgaWYgKHdhc0FwcGVuZCAmJiAhd2FzQm9vdExvYWRpbmcg
JiYgcHJldkxlbiA+IDAgJiYgYWxsQ2xpcHMubGVuZ3RoID4gcHJldkxlbikgewogICAgICAgICAgICAg
ICAgLy8gSW5jcmVtZW50YWwgRE9NIOKAlCBrZWVwIG5hdGl2ZSBzY3JvbGwgcG9zaXRpb24gKG5vIHNj
cm9sbFRvcCByZXN0b3JlKQogICAgICAgICAgICAgICAgYXBwZW5kUmVuZGVyKHByZXZMZW4pOwogICAg
ICAgICAgICB9IGVsc2UgaWYgKCFzYW1lUGFpbnQpIHsKICAgICAgICAgICAgICAgIHJlbmRlcigpOwog
ICAgICAgICAgICAgICAgYXBwbHlUYWJTd2l0Y2hBbmltKCk7CiAgICAgICAgICAgICAgICBpZiAoa2Vl
cFNjcm9sbCkKICAgICAgICAgICAgICAgICAgICBsaXN0RWwuc2Nyb2xsVG9wID0gc3Q7CiAgICAgICAg
ICAgICAgICBlbHNlCiAgICAgICAgICAgICAgICAgICAgbGlzdEVsLnNjcm9sbFRvcCA9IDA7CiAgICAg
ICAgICAgIH0gZWxzZSB7CiAgICAgICAgICAgICAgICAvLyBzYW1lIGlkcyDigJRzdGlsbCByZWZyZXNo
IGNvdW50cyAocGlubmVkVG90YWwgLyBkaXNrVG90YWwgbWF5IGhhdmUgY2hhbmdlZCkKICAgICAgICAg
ICAgICAgIHRyeSB7CiAgICAgICAgICAgICAgICAgICAgcmVmcmVzaExpc3RDaHJvbWUoKTsKICAgICAg
ICAgICAgICAgIH0gY2F0Y2gge30KICAgICAgICAgICAgICAgIGlmIChrZWVwU2Nyb2xsKQogICAgICAg
ICAgICAgICAgICAgIGxpc3RFbC5zY3JvbGxUb3AgPSBzdDsKICAgICAgICAgICAgfQogICAgICAgIH07
CiAgICAgICAgaWYgKHdhc0Jvb3RMb2FkaW5nKSB7CiAgICAgICAgICAgIGNvbnN0IHNpbmNlID0gd2lu
ZG93Ll9fc2tlbFNpbmNlIHx8IDA7CiAgICAgICAgICAgIGNvbnN0IHdhaXQgPSBzaW5jZSA/IE1hdGgu
bWF4KDAsIDgwIC0gKERhdGUubm93KCkgLSBzaW5jZSkpIDogMDsKICAgICAgICAgICAgaWYgKHdhaXQg
PiAwKQogICAgICAgICAgICAgICAgc2V0VGltZW91dChmaW5pc2hVcGRhdGUsIHdhaXQpOwogICAgICAg
ICAgICBlbHNlCiAgICAgICAgICAgICAgICBmaW5pc2hVcGRhdGUoKTsKICAgICAgICB9IGVsc2Ugewog
ICAgICAgICAgICBmaW5pc2hVcGRhdGUoKTsKICAgICAgICB9CiAgICB9OwogICAgd2luZG93Ll9fc2V0
UGlubmVkID0gdiA9PiB7CiAgICAgICAgcGlubmVkVUkgPSAhIXY7CiAgICAgICAgZG9jdW1lbnQuZ2V0
RWxlbWVudEJ5SWQoJ2J0bi1waW4nKS5jbGFzc0xpc3QudG9nZ2xlKCdvbicsIHBpbm5lZFVJKTsKICAg
IH07CiAgICB3aW5kb3cuX19sb2FkTW9yZURvbmUgPSAoKSA9PiB7CiAgICAgICAgbG9hZGluZ01vcmUg
PSBmYWxzZTsKICAgICAgICBpZiAod2luZG93Ll9fbG9hZE1vcmVXYXRjaCkgewogICAgICAgICAgICBj
bGVhclRpbWVvdXQod2luZG93Ll9fbG9hZE1vcmVXYXRjaCk7CiAgICAgICAgICAgIHdpbmRvdy5fX2xv
YWRNb3JlV2F0Y2ggPSAwOwogICAgICAgIH0KICAgICAgICBpZiAod2luZG93Ll9fcGVuZGluZ0p1bXBJ
ZCkKICAgICAgICAgICAgdHJ5Q29udGludWVKdW1wKCk7CiAgICB9OwoKICAgIHNjaGVkdWxlRGVsYXll
ZFNrZWwoKTsKICAgIGluaXRTZXBVaSgpOwogICAgcmVzZXRQYXN0ZVNlcERlZmF1bHQoKTsKICAgIHJl
cXVlc3RWaWV3KCk7CiAgICAvLyBzY2hlZHVsZURlbGF5ZWRTa2VsIGFscmVhZHkgcmVuZGVyKCknZCB3
aGVuIGVtcHR5OyBzdGlsbCBwYWludCBvbmNlIGZvciBjaHJvbWUKCiAgICA8L3NjcmlwdD4KPC9ib2R5
Pgo8L2h0bWw+
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
global pasteIds := ""
global pasteSep := " "
global pasteSending := false
; Interactive ops (paste/drag/click) bump this — background LoadMore/thumbs must yield
global uiUrgentUntil := 0
global loadMoreDeferCount := 0
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
global recentFolders := []  ; recent Explorer folders (type=recent), newest first
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
global fileThumbEnsureQueued := Map() ; file clip uid → lazy fimg_ copy queued
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
        ClipLog("ClipChanged branch=text")
        txt := A_Clipboard
        if txt = "" {
            Sleep 60
            txt := A_Clipboard
        }
        if txt = "" || txt = lastTxt
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
    if item.type = "text" {
        old := MemoryTakeTextEqual(item.data)
        InheritClipMeta(item, old)
        lastTxt := item.data
    } else if item.type = "link" {
        old := MemoryTakeLinkEqual(item.data)
        InheritClipMeta(item, old)
        if IsObject(old) && old.HasProp("linkTitle") && old.linkTitle != ""
            item.linkTitle := old.linkTitle
    }
    ClipLog("AddClipItem MemoryInsertFront")
    MemoryInsertFront(item)
    ; Never call WebView sync from OnClipboardChange —it often drops the update.
    ; Defer a coalesced UI push so the open panel shows the new item immediately.
    RequestUiPush()
    ; Image payload is stripped from list JSON —inject a list thumb ASAP so UI is not blank
    if item.type = "image" && item.HasProp("data") && item.data != ""
        SetTimer(InjectLiveImageThumb.Bind(Integer(item.uid)), -15)
    ClipLog("AddClipItem Enqueue PersistNewItem")
    EnqueueDiskJob(PersistNewItem.Bind(item))
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
    pasteMany(ids, sep := " ") {
        RequestPasteMany(ids, sep)
    }
    delete(id) {
        MarkUiUrgent(600)
        ; 立刻返回，避免 WebView 同步调用卡死界面
        SetTimer(DeleteItem.Bind(id), -1)
    }
    pin(id) {
        MarkUiUrgent(600)
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
        ; Defer —sync DiskSetPasted from WebView host freezes / drops the clear
        SetTimer(ClearPasted.Bind(id), -1)
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
    openDir(path := "") {
        OpenFolderDir(path)
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
        ; Sync only — async host + preventDefault broke window drag entirely
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
    ApplyRoundedCorners(guiWin.Hwnd, uiW, uiH, 8)
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
    guiWin.BackColor := "e4e7ee"
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

; Soft rounded corners via DWM (anti-aliased). Never use CreateRoundRectRgn —
; GDI window regions are 1-bit masks and look heavily jagged.
ApplyRoundedCorners(hwnd, w := 0, h := 0, r := 8) {
    ; Clear any previous GDI region so DWM can smooth the edge
    try DllCall("SetWindowRgn", "Ptr", hwnd, "Ptr", 0, "Int", true)
    EnableDwmShadow(hwnd)
}

EnableDwmRoundedCorners(hwnd) {
    ; DWMWA_WINDOW_CORNER_PREFERENCE=33, DWMWCP_ROUND=2 (~8px, anti-aliased)
    try DllCall("dwmapi\DwmSetWindowAttribute",
        "Ptr", hwnd, "UInt", 33, "Int*", 2, "UInt", 4)
    ; Match panel bg instead of COLOR_NONE — COLOR_NONE often kills the drop shadow
    try {
        ; #e4e7ee as COLORREF (0x00BBGGRR)
        col := 0x00EEE7E4
        DllCall("dwmapi\DwmSetWindowAttribute",
            "Ptr", hwnd, "UInt", 34, "UInt*", col, "UInt", 4)
    }
}

EnableDwmShadow(hwnd) {
    ; DWMWA_NCRENDERING_POLICY=2, DWMNCRP_ENABLED=2 — allow DWM shadow on borderless
    try DllCall("dwmapi\DwmSetWindowAttribute",
        "Ptr", hwnd, "UInt", 2, "Int*", 2, "UInt", 4)
    ; 1px frame into client on all sides: classic borderless drop-shadow trigger
    try {
        m := Buffer(16, 0)
        NumPut("Int", 1, m, 0)   ; left
        NumPut("Int", 1, m, 4)   ; right
        NumPut("Int", 1, m, 8)   ; top
        NumPut("Int", 1, m, 12)  ; bottom
        DllCall("dwmapi\DwmExtendFrameIntoClientArea", "Ptr", hwnd, "Ptr", m)
    }
    EnableDwmRoundedCorners(hwnd)
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
    ; Do NOT defer append pushes on UiIsUrgent — that left JS loadingMore=true and
    ; broke 定位 / paste-follow-up loadMore. Yield inside ClipsListToJson instead.
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
    ; Append path: skip pinned recount (UI keeps last badge) — saves a cache walk mid-scroll
    if append
        payload .= '"pinnedTotal":-1,'
    else
        payload .= '"pinnedTotal":' Integer(PinnedTotalForUi()) ","
    payload .= '"query":' JsonStr(q) ","
    payload .= '"filtered":' (filtered ? "true" : "false") ","
    payload .= '"items":' ClipsListToJson(sendList, append)
    payload .= "}"
    try wvCore.ExecuteScriptAsync("window.__updateClips && window.__updateClips(" payload ");window.__loadMoreDone&&window.__loadMoreDone()")
    ; Virtual-host thumbs flaky; inject data-URLs in small chunks (never block AHK thread)
    ; Append while user may still be scrolling — defer thumbs longer
    if append
        SetTimer(ScheduleStoreThumbs.Bind(true), -400)
    else
        ScheduleStoreThumbs(false)
}

; True when a 收藏 viewCache entry was poisoned (e.g. LoadMore race wrote 全部 rows)
PinnedCacheLooksPoisoned(entry) {
    if !IsObject(entry) || !entry.HasProp("items") || !IsObject(entry.items)
        return true
    if entry.items.Length < 1 {
        ; Empty window with a huge total is also suspect
        return Integer(entry.HasProp("total") ? entry.total : 0) > 0
    }
    for c in entry.items {
        if !IsObject(c) || !(c.HasProp("pinned") && c.pinned)
            return true
    }
    return false
}

; Badge on 收藏 tab —prefer pinned viewCache total, else count current window
PinnedTotalForUi(*) {
    global viewCache, viewToday, viewTab, viewTotal, clips, tabTotals
    try {
        key := ViewCacheKey("pinned", "", viewToday)
        if viewCache.Has(key) {
            entry := viewCache[key]
            if !PinnedCacheLooksPoisoned(entry) {
                t := Integer(entry.total)
                if t > 0
                    return t
            }
        }
        if IsObject(tabTotals) && tabTotals.Has(key) {
            t := Integer(tabTotals[key])
            if t > 0
                return t
        }
    }
    if viewTab = "pinned" {
        ; Only trust viewTotal when the live window is actually 收藏 rows
        nPin := 0
        n := 0
        try n := clips.Length
        if IsObject(clips) {
            for c in clips {
                if IsObject(c) && c.HasProp("pinned") && c.pinned
                    nPin += 1
            }
        }
        if n > 0 && nPin = n
            return Max(Integer(viewTotal), n)
        if nPin > 0
            return nPin
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
        , thumbPushedUids, fileThumbEnsureQueued, clipReady, STORE_DIR, panelVisible
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
        ; Do NOT wipe fileThumbEnsureQueued — avoids re-queue storms while copy is in flight
    }
    q := []
    i := start
    while i <= clips.Length {
        c := clips[i]
        i += 1
        if !IsObject(c) || (c.type != "image" && c.type != "file")
            continue
        uid := Integer(c.uid)
        if thumbPushedUids.Has(uid)
            continue
        ; Lazy: copy image file path into clips_store (was never wired after UI dropped sync ensureFileImg)
        if c.type = "file" && (!c.HasProp("imgFile") || c.imgFile = "") && FileClipLooksLikeImage(c) {
            if !fileThumbEnsureQueued.Has(uid) {
                fileThumbEnsureQueued[uid] := true
                EnqueueDiskJob(EnsureFileClipThumbByUid.Bind(uid))
            }
            continue
        }
        if !c.HasProp("imgFile") || c.imgFile = ""
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
        ; Append while scrolling: delay thumb work so drag/wheel stays smooth
        SetTimer(ProcessThumbPushQueue, append ? -180 : -20)
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
    ; Paste/drag wins — thumbs wait
    if UiIsUrgent() {
        thumbPushArmed := true
        SetTimer(ProcessThumbPushQueue, -120)
        return
    }
    myGen := thumbPushGen
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
    built := 0
    ; Append payloads stay tiny so paste/drag can preempt between Sleeps
    prevMax := append ? 120 : 500
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
            if StrLen(data) > prevMax
                data := SubStr(data, 1, prevMax)
        } else if c.type = "file" {
            data := preview != "" ? preview : String(c.HasProp("data") ? c.data : "")
            if preview = ""
                preview := data
            if StrLen(data) > prevMax
                data := SubStr(data, 1, prevMax)
        } else {
            data := ""
            if preview = "" && c.HasProp("data") && c.data != ""
                preview := SubStr(String(c.data), 1, prevMax)
        }
        if StrLen(preview) > prevMax
            preview := SubStr(preview, 1, prevMax)
        uid := c.HasProp("uid") ? Integer(c.uid) : i
        out .= "{"
        out .= '"id":' uid ","
        out .= '"type":"' c.type '",'
        out .= '"time":"' c.time '",'
        out .= '"pinned":' (c.pinned ? "true" : "false") ","
        out .= '"pasted":' ((c.HasProp("pasted") && c.pasted) ? "true" : "false") ","
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
        built += 1
        ; Yield so paste/drag SetTimers can run mid-serialize
        if Mod(built, 5) = 0
            Sleep(-1)
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
    global prevActiveWin, clipIgnore, uiPinned
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

PasteMany(idsStr, sep := " ") {
    global prevActiveWin, clipIgnore, uiPinned
    sep := NormalizePasteSep(sep)
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

    if PasteItemsAreJoinableText(items) {
        parts := []
        for it in items
            parts.Push(String(it.HasProp("data") ? it.data : ""))
        joined := JoinPasteParts(parts, sep)
        eraseN := QQTypedEraseCount()
        if !uiPinned
            HidePanel()
        clipIgnore := true
        try {
            A_Clipboard := joined
            target := ResolvePasteTargetWin()
            if target {
                DllCall("SetForegroundWindow", "Ptr", target)
                Sleep 30
            }
            QQEraseTypedInEditor(eraseN)
            TriggerPasteKey()
            MarkItemsPasted(uids)
        } finally {
            SetTimer(() => (clipIgnore := false), -500)
            if uiPinned
                SetTimer(RaiseClipboardPanel, -50)
        }
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

; Bridge entry: leave WebView sync stack + debounce (click→host.call re-entrancy = double paste)
RequestPaste(id) {
    global pasteLockUntil
    ; Brief urgent window so LoadMore yields; keep short so drag/paste aren't starved by defer loops
    MarkUiUrgent(400)
    if A_TickCount < pasteLockUntil
        return
    pasteLockUntil := A_TickCount + 500
    pasteId := id
    SetTimer(() => PasteItem(pasteId), -1)
}

RequestPasteMany(ids, sep := " ") {
    global pasteLockUntil, pasteIds, pasteSep
    MarkUiUrgent(400)
    if A_TickCount < pasteLockUntil
        return
    pasteLockUntil := A_TickCount + 500
    pasteIds := ids
    pasteSep := NormalizePasteSep(sep)
    SetTimer(() => PasteMany(pasteIds, pasteSep), -1)
}

; Paste / drag / pin must preempt background paging
MarkUiUrgent(ms := 800) {
    global uiUrgentUntil
    t := A_TickCount + Integer(ms)
    if t > uiUrgentUntil
        uiUrgentUntil := t
}

UiIsUrgent(*) {
    global uiUrgentUntil
    return A_TickCount < uiUrgentUntil
}

NormalizePasteSep(sep) {
    s := String(sep)
    if s = "" || s = " "
        return " "
    if s = "[换行]" || s = "换行" || s = "\n" || s = "`n" || s = "`r`n" || s = "\\n"
        return "`n"
    if s = "[制表符]" || s = "\t" || s = "`t" || s = "\\t"
        return "`t"
    return s
}

JoinPasteParts(parts, sep) {
    if !IsObject(parts) || parts.Length < 1
        return ""
    out := String(parts[1])
    if parts.Length < 2
        return out
    Loop parts.Length - 1 {
        out .= sep . String(parts[A_Index + 1])
    }
    return out
}

PasteItemsAreJoinableText(items) {
    if !IsObject(items) || items.Length < 2
        return false
    for it in items {
        if !IsObject(it) || (it.type != "text" && it.type != "link")
            return false
    }
    return true
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
        A_Clipboard := item.data
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
    global clips, viewTotal, wvCore, lastTxt, lastImg, recentFolders, viewTab, viewQuery, viewToday
    uid := Integer(uid)
    ; Recent-folder entries live outside clips NDJSON
    if IsObject(recentFolders) {
        ri := 0
        for i, c in recentFolders {
            if IsObject(c) && Integer(c.uid) = uid {
                ri := i
                break
            }
        }
        if ri > 0 {
            recentFolders.RemoveAt(ri)
            SaveRecentFolders()
            try CacheRecentFoldersView(false)
            try CacheRecentFoldersView(true)
            if viewTab = "recent"
                SetView("recent", viewQuery, viewToday ? "1" : "0")
            else
                RequestUiPush()
            return
        }
    }
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
    RequestUiPush()
    EnqueueDiskJob(PersistDeleteUid.Bind(uid, imgFile, itemType))
}

PinItem(uid) {
    global clips, viewTab, viewQuery, viewToday, wvCore, viewCache, recentFolders
    uid := Integer(uid)
    ; 最近文件夹：固定后不参与 20 条淘汰
    if IsObject(recentFolders) {
        for c in recentFolders {
            if !IsObject(c) || Integer(c.uid) != uid
                continue
            c.pinned := !(c.HasProp("pinned") && c.pinned)
            SaveRecentFolders()
            InvalidateRecentViewCaches()
            try CacheRecentFoldersView(false)
            try CacheRecentFoldersView(true)
            if viewTab = "recent"
                SetView("recent", viewQuery, viewToday ? "1" : "0")
            else
                RequestUiPush()
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
    InvalidatePinnedSearchPools()
    ; Persist async —sync disk + SetView made pin clicks hitch
    EnqueueDiskJob(DiskSetPinned.Bind(uid, newPin, pinAt))
    if viewTab = "pinned" || viewQuery != ""
        QueueSetView(viewTab, viewQuery, viewToday ? "1" : "0")
    else
        RequestUiPush()
}

MarkItemsPasted(uids) {
    global clips, viewCache, panelVisible
    want := Map()
    for uid in uids
        want[Integer(uid)] := true
    if !want.Count
        return
    ; Optimistic memory update —disk write is async (was blocking paste for seconds)
    for c in clips {
        if want.Has(c.uid)
            c.pasted := true
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
    if panelVisible
        SetTimer(() => PushClips(false), -80)
}

ClearPasted(uid) {
    global clips, viewCache, liveFront, panelVisible
    uid := Integer(uid)
    if uid < 1
        return
    want := Map()
    want[uid] := true
    ; Optimistic memory update —same path as MarkItemsPasted (disk async)
    for c in clips {
        if c.uid = uid
            c.pasted := false
    }
    for , entry in viewCache {
        if !IsObject(entry) || !entry.HasProp("items")
            continue
        for c in entry.items {
            if c.uid = uid
                c.pasted := false
        }
    }
    if IsObject(liveFront) {
        for c in liveFront {
            if IsObject(c) && c.uid = uid
                c.pasted := false
        }
    }
    EnqueueDiskJob(DiskSetPasted.Bind(want, false))
    if panelVisible
        SetTimer(() => PushClips(false), -40)
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
    ; 搜索池可能是另一份对象：必须同步 favTitle 并重建 _searchHay，否则搜标题永远 miss
    SyncSearchPoolsFavTitle(uid, title)
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
    SyncSearchPoolsFavGroup(uid, gid)
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
    global uiPinned
    path := Trim(String(path))
    if (SubStr(path, 1, 1) = '"' && SubStr(path, -1) = '"')
        || (SubStr(path, 1, 1) = "'" && SubStr(path, -1) = "'")
        path := Trim(SubStr(path, 2, -1))
    if path = ""
        return
    if FileExist(path) {
        try Run('explorer.exe /select,"' path '"')
        if !uiPinned
            HidePanel()
        return
    }
    SplitPath path, , &dir
    if dir != "" && DirExist(dir) {
        try Run('explorer.exe "' dir '"')
        if !uiPinned
            HidePanel()
    }
}

; Open a directory itself (recent-folder tab / Enter)
OpenFolderDir(path := "") {
    global uiPinned, qqSearchOn, qqQuery, viewQuery, viewTab, viewToday, wvCore
    path := Trim(String(path))
    if (SubStr(path, 1, 1) = '"' && SubStr(path, -1) = '"')
        || (SubStr(path, 1, 1) = "'" && SubStr(path, -1) = "'")
        path := Trim(SubStr(path, 2, -1))
    if path = ""
        return
    if !DirExist(path) {
        SplitPath path, , &dir
        if dir != "" && DirExist(dir)
            path := dir
        else
            return
    }
    ; 打开目录前清掉 ??xxx（编辑器里的字 + UI 搜索框）
    wasQQ := qqSearchOn
    eraseN := QQTypedEraseCount()
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
        if IsObject(wvCore)
            try wvCore.ExecuteScriptAsync("window.__clearQQSearch&&window.__clearQQSearch()")
    }
    try Run('explorer.exe "' path '"')
    ; 打开即记入「最近」（不依赖资源管理器轮询）
    try {
        global lastExplorerFolder
        RecordRecentFolder(path)
        lastExplorerFolder := NormalizeFolderPath(path)
    }
    if !uiPinned {
        HidePanel()
        return
    }
    if wasQQ
        SetTimer(() => SetView(viewTab, "", viewToday ? "1" : "0"), -40)
    SetTimer(RaiseClipboardPanel, -80)
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
    global viewTab, viewQuery, viewToday, lastTxt, lastImg, clips, viewTotal, liveFront
    tab := StrLower(Trim(String(tab)))
    scope := StrLower(Trim(String(scope)))
    if tab = "recent" {
        ClearRecentFolders()
        InvalidateViewCache()
        RequestUiPush()
        SetView("recent", viewQuery, viewToday ? "1" : "0")
        return
    }
    clearAllDates := (scope = "all")
    today := FormatTime(, "yyyy-MM-dd")
    ; 先清内存并立刻刷新 UI，磁盘清空丢后台（否则 3000+ 条会卡死面板）
    MemoryClearTab(tab, clearAllDates, today)
    InvalidateViewCache()
    if tab = "all" || tab = "text" || tab = "link"
        lastTxt := ""
    if tab = "all" || tab = "image"
        lastImg := ""
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

EnsureFileClipThumbByUid(uid) {
    global panelVisible, wvCore
    uid := Integer(uid)
    item := ResolveClip(uid)
    if !IsObject(item) || item.type != "file"
        return
    EnsureFileClipThumb(item)
    img := item.HasProp("imgFile") ? String(item.imgFile) : ""
    if img = ""
        return
    ApplyImgFileLocal(uid, img)
    if panelVisible && IsObject(wvCore)
        SetTimer(InjectStoreThumbNow.Bind(uid, img), -10)
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

; Remove all text-equal rows; return the best removed item (prefer pinned) for meta inherit
DiskRemoveTextEqual(text) {
    m := LoadManifest()
    pages := m["pages"]
    newPages := []
    changedAny := false
    best := ""
    for name in pages {
        items := ReadPageFile(name)
        kept := []
        changed := false
        for c in items {
            if c.type = "text" && c.data = text {
                if !IsObject(best) || (c.HasProp("pinned") && c.pinned && !(best.HasProp("pinned") && best.pinned))
                    best := c
                DeletePayloadFile(c)
                changed := true
                changedAny := true
            } else
                kept.Push(c)
        }
        if changed {
            if kept.Length {
                WritePageFile(name, kept)
                newPages.Push(name)
            } else {
                try FileDelete PagePath(name)
            }
        } else
            newPages.Push(name)
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
    if type = "recent" {
        return StrLower(String(c.HasProp("preview") ? c.preview : "") " "
            . String(c.HasProp("data") ? c.data : "") " " favTitle)
    }
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
    global tabTotals, searchPools
    tab := StrLower(Trim(String(tab)))
    if tab = "pinned"
        return QueryPinnedDiskPage(query, todayOnly, offset, limit)
    if tab = "recent"
        return QueryRecentFoldersPage(query, todayOnly, offset, limit)
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
    ; Fast path: paginate from warm search pool (no re-scan of NDJSON every load-more).
    try {
        poolTab := SearchPoolTab(tab)
        spKey := SearchPoolKey(poolTab, todayOnly)
        if IsObject(searchPools) && searchPools.Has(spKey) {
            pool := searchPools[spKey]
            if IsObject(pool) && pool.HasProp("items") && pool.items.Length {
                key := ViewCacheKey(tab, "", todayOnly)
                knownTotal := -1
                if IsObject(tabTotals) && tabTotals.Has(key)
                    knownTotal := Integer(tabTotals[key])
                ; Pool built for this exact tab (全部/收藏): O(page) index slice — never walk 4k rows
                if poolTab = tab {
                    total := knownTotal >= 0 ? knownTotal : pool.items.Length
                    if IsObject(tabTotals)
                        tabTotals[key] := total
                    items := []
                    i := Integer(offset) + 1
                    while i <= pool.items.Length && items.Length < limit {
                        items.Push(pool.items[i])
                        i += 1
                    }
                    return { items: items, total: total }
                }
                ; Sub-tab (text/image/…): stop once page filled; reuse knownTotal when available
                items := []
                matched := 0
                i := 1
                needCount := !(knownTotal >= 0)
                while i <= pool.items.Length {
                    c := pool.items[i]
                    i += 1
                    if !ItemMatchesTabToday(c, tab, todayOnly)
                        continue
                    if matched >= offset && items.Length < limit
                        items.Push(c)
                    matched += 1
                    if items.Length >= limit && !needCount
                        break
                }
                total := knownTotal >= 0 ? knownTotal : matched
                if IsObject(tabTotals)
                    tabTotals[key] := total
                return { items: items, total: total }
            }
        }
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
    else {
        ; Re-filter: pool may hold stale unpinned rows after async pin toggles
        all := []
        if IsObject(pool) && pool.HasProp("items") {
            for c in pool.items {
                if ItemMatchesTabToday(c, "pinned", todayOnly)
                    all.Push(c)
            }
        }
    }
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
    global clips, PAYLOAD_DIR
    uid := Integer(uid)
    if uid < 1
        return ""
    for c in clips {
        if c.uid = uid {
            EnsureClipBodyLoaded(c)
            return c
        }
    }
    m := LoadManifest()
    for name in m["pages"] {
        for c in ReadPageFile(name, false) {
            if c.uid = uid
                return c
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

; 收藏增删后丢弃 pinned 搜索池（下次搜索按磁盘重建）
InvalidatePinnedSearchPools(*) {
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

; 改标题后同步搜索池（对象可能不是同一份引用）
SyncSearchPoolsFavTitle(uid, title) {
    global searchPools
    uid := Integer(uid)
    title := String(title)
    if !IsObject(searchPools)
        return
    for , pool in searchPools {
        if !IsObject(pool) || !pool.HasProp("items")
            continue
        for c in pool.items {
            if Integer(c.uid) != uid
                continue
            c.favTitle := title
            c._searchHay := ClipSearchHay(c)
        }
        if !IsObject(pool.groups)
            continue
        for , members in pool.groups {
            for c in members {
                if Integer(c.uid) != uid
                    continue
                c.favTitle := title
                c._searchHay := ClipSearchHay(c)
            }
        }
    }
}

; 合并组变更后重建 groups 索引片段
SyncSearchPoolsFavGroup(uid, gid) {
    global searchPools
    uid := Integer(uid)
    gid := Trim(String(gid))
    if !IsObject(searchPools)
        return
    for , pool in searchPools {
        if !IsObject(pool) || !pool.HasProp("items")
            continue
        target := ""
        for c in pool.items {
            if Integer(c.uid) = uid {
                c.favGroup := gid
                c._searchHay := ClipSearchHay(c)
                target := c
                break
            }
        }
        if !IsObject(pool.groups)
            pool.groups := Map()
        ; rebuild: remove uid from all groups, then re-add
        for g, members in pool.groups {
            i := 1
            while i <= members.Length {
                if Integer(members[i].uid) = uid
                    members.RemoveAt(i)
                else
                    i += 1
            }
        }
        if gid != "" && IsObject(target) {
            if !pool.groups.Has(gid)
                pool.groups[gid] := []
            pool.groups[gid].Push(target)
        }
    }
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
        hay := c.HasProp("_searchHay") ? c._searchHay : ""
        ; 标题改过后旧 hay 可能缺词：发现不一致则现场重建
        if hay = "" || (favTitle != "" && !InStr(hay, StrLower(favTitle))) {
            hay := ClipSearchHay(c)
            c._searchHay := hay
        }
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
    ; Paste/drag in progress — disk maintenance waits
    if UiIsUrgent() {
        SetTimer(DrainDiskJobs, -80)
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
    global panelVisible, wvCore
    if !IsObject(item)
        return
    ClipLog("PersistNewItem begin uid=" (item.HasProp("uid") ? item.uid : 0) " type=" item.type)
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
    } else if item.type = "file" && FileClipLooksLikeImage(item) {
        EnsureFileClipThumb(item)
    }
    ; Remove old equals BEFORE spill — reused uid shares d_<uid>.txt with the old row
    if item.type = "text" {
        ; Disk may still hold a pinned copy even when memory didn't (other tab / cache miss)
        old := DiskRemoveTextEqual(item.data)
        InheritClipMeta(item, old)
    } else if item.type = "link" {
        ; Link may reuse the same uid — only delete payload when uid differs
        old := DiskTakeLinkEqual(item.data)
        if IsObject(old) {
            InheritClipMeta(item, old)
            if old.HasProp("linkTitle") && old.linkTitle != "" && !(item.HasProp("linkTitle") && item.linkTitle != "")
                item.linkTitle := old.linkTitle
            if old.uid != item.uid
                DeletePayloadFile(old)
        }
    }
    EnsureSpillPayload(item)
    ok := DiskInsertFront(item)
    ClipLog("PersistNewItem done uid=" item.uid " ok=" ok)
    if ok
        LiveFrontConfirmPersisted(item.uid)
    if item.type = "file" && item.HasProp("imgFile") && item.imgFile != "" {
        ApplyImgFileLocal(item.uid, item.imgFile)
        if panelVisible && IsObject(wvCore)
            SetTimer(InjectStoreThumbNow.Bind(Integer(item.uid), String(item.imgFile)), -10)
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
            ; Screenshots only: strip base64 from memory. File clips must keep path in data/preview.
            if c.type = "image"
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
                if c.type = "image"
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
    ; 收藏: never persist a window that contains non-pinned rows (LoadMore race)
    if viewTab = "pinned" {
        for c in clips {
            if IsObject(c) && !(c.HasProp("pinned") && c.pinned) {
                ClipLog("CacheCurrentView SKIP poisoned pinned n=" clips.Length " total=" viewTotal)
                return
            }
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
        CacheRecentFoldersView(todayFlag)
        ; Mid-preload already painted 全部 —skip second SetView/PushClips
        if !qqSearchOn && !allShown && buckets.Has("all")
            SetView("all", "", todayFlag ? "1" : "0")
    }
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

; 丢弃「最近」相关缓存（含带搜索关键字的），避免新目录被旧空结果挡住
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
        , qqSearchOn, qqQuery, qqAwaitKeyword, viewSwitchGuardUntil, viewApplyGen, viewApplying, tabTotals
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
            ; 收藏: LoadMore on 全部 can finish after tab switch and write 全部 into pinned key
            if !poisoned && viewTab = "pinned" && PinnedCacheLooksPoisoned(entry)
                poisoned := true
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
            if viewTab = "pinned" && IsObject(tabTotals) && tabTotals.Has(key)
                tabTotals.Delete(key)
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
    global clips, viewTab, viewQuery, viewToday, viewTotal, VIEW_PAGE_SIZE, lastAppendCount, wvCore, viewApplyGen
        , loadMoreDeferCount
    ; Brief yield if paste just clicked — but don't spin-defer (that stuck 定位 loadMore)
    if UiIsUrgent() {
        Sleep(-1)
        if UiIsUrgent() && loadMoreDeferCount < 8 {
            loadMoreDeferCount += 1
            SetTimer(LoadMoreView, -20)
            return
        }
    }
    loadMoreDeferCount := 0
    ; Snapshot view identity —QueryDiskPage yields (Sleep); SetView may switch tabs mid-flight
    tab := viewTab
    q := viewQuery
    today := viewToday
    gen := viewApplyGen
    startLen := 0
    try startLen := clips.Length
    if startLen >= viewTotal {
        lastAppendCount := 0
        if IsObject(wvCore)
            try wvCore.ExecuteScriptAsync("window.__loadMoreDone&&window.__loadMoreDone()")
        return
    }
    page := QueryDiskPage(tab, q, today, startLen, VIEW_PAGE_SIZE)
    Sleep(-1)
    if gen != viewApplyGen || viewTab != tab || viewQuery != q || viewToday != today {
        lastAppendCount := 0
        ClipLog("LoadMoreView DROP stale tab=" tab " now=" viewTab " gen=" gen "/" viewApplyGen)
        if IsObject(wvCore)
            try wvCore.ExecuteScriptAsync("window.__loadMoreDone&&window.__loadMoreDone()")
        return
    }
    viewTotal := page.total
    lastAppendCount := page.items.Length
    for c in page.items
        clips.Push(c)
    ; Don't full-clone clips every page (was O(n) and blocked paste while scrolling)
    BumpViewCacheAfterAppend()
    SetTimer(PushClipsAppendTick, -1)
}

PushClipsAppendTick(*) {
    Sleep(-1)  ; let paste/drag timers run first
    PushClips(true)
}

; Update total only (+ optional small window) — avoid cloning entire list on every load-more
BumpViewCacheAfterAppend(*) {
    global viewCache, clips, viewTab, viewQuery, viewToday, viewTotal, tabTotals, lastAppendCount, VIEW_PAGE_SIZE
    key := ViewCacheKey(viewTab, viewQuery, viewToday)
    if !viewCache.Has(key) {
        CacheCurrentView()
        return
    }
    entry := viewCache[key]
    entry.total := Integer(viewTotal)
    if viewQuery = "" && IsObject(tabTotals)
        tabTotals[key] := Integer(viewTotal)
    if !IsObject(entry.items)
        return
    maxRows := Max(VIEW_PAGE_SIZE * 2, 80)
    if entry.items.Length >= maxRows
        return
    start := Max(1, clips.Length - Integer(lastAppendCount) + 1)
    i := start
    while i <= clips.Length && entry.items.Length < maxRows {
        entry.items.Push(clips[i])
        i += 1
    }
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
            if c.type = "text" {
                lastTxt := c.data
                break
            }
        }
    }
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
SetTimer(WatchExplorerFolder, 700)
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

; ?? / ？？：不要注册 ~?（中文键盘布局没有独立问号键，会弹 AHK 提示且热键无效）
QQInstallSearchHotkeys()
StartCaretWatcher()
SetTimer(RememberGoodActiveWin, 400)
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
    SetTimer(ClipLogHeartbeat, 2000)
    ClipLog("ArmClipboardReady in 1000ms + heartbeat 2s")
}

ArmClipboardReady(*) {
    global clipReady
    clipReady := true
    ClipLog("clipReady=TRUE —accepting clipboard now")
}

ClipLogHeartbeat(*) {
    global clipReady, diskScanBusy, diskJobBusy, diskJobQueue, panelVisible, wvBuilding, clips
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
;  Recent Explorer folders (双击进入目录 →「最近」tab)
; =================================================
NormalizeFolderPath(path) {
    path := Trim(String(path))
    if path = ""
        return ""
    try path := RTrim(path, "\/")
    ; Prefer long path for stable dedupe
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
    ; Also skip shell:::{...} / special desktop views
    if InStr(p, "::{") = 1
        return true
    return false
}

; C:\ / D: / E:\ 这类盘符根目录不记
IsDriveRootFolderPath(path) {
    path := NormalizeFolderPath(path)
    if path = ""
        return true
    ; C: or C:\ or \\server\share (UNC root without subfolder)
    if RegExMatch(path, "i)^[a-z]:\\?$")
        return true
    if RegExMatch(path, "^\\\\[^\\]+\\[^\\]+$")
        return true
    return false
}

; 新路径是旧路径的子目录 → 删掉旧路径；旧路径是新路径的子目录 → 不重复插（保留更深的）
RecentPathIsParentOf(parent, child) {
    parent := StrLower(NormalizeFolderPath(parent))
    child := StrLower(NormalizeFolderPath(child))
    if parent = "" || child = "" || parent = child
        return false
    ; parent\ must be prefix of child\ (path segment boundary)
    return InStr(child "\", parent "\") = 1
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
        ; Lightweight parse: array of objects with uid/path/time/pinned
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

; 超出上限时只淘汰未固定项；已固定路径永不被挤出
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
        ; 同路径：去掉旧条，稍后插到最前（保留固定状态）
        if p = key {
            foundSame := true
            keptUid := Integer(c.uid)
            keptPinned := IsRecentFolderPinned(c)
            recentFolders.RemoveAt(i)
            continue
        }
        ; 新路径包含旧路径（进入子目录）→ 删掉更浅的父路径（已固定的父路径保留）
        if RecentPathIsParentOf(p, key) {
            if IsRecentFolderPinned(c) {
                i += 1
                continue
            }
            recentFolders.RemoveAt(i)
            continue
        }
        ; 新路径更短 / 旁支：照常保留旧的深路径，并继续记新路径
        i += 1
    }
    if !IsObject(recentFolders)
        recentFolders := []
    ; 新路径且已满且全是固定：无法腾位，不记
    if !foundSame && recentFolders.Length >= MAX_RECENT_FOLDERS && !RecentFoldersHasEvictable()
        return false
    if keptUid < 1
        keptUid := ++recentFolderUidSeq
    item := MakeRecentFolderItem(keptUid, path, "", keptPinned)
    recentFolders.InsertAt(1, item)
    TrimRecentFoldersToMax()
    SaveRecentFolders()
    ; 必须清掉带关键字的旧缓存，否则搜「新目录」仍命中旧的 0 条快照
    InvalidateRecentViewCaches()
    try CacheRecentFoldersView(false)
    try CacheRecentFoldersView(true)
    ; 当前在「最近」tab：立刻刷新，让新路径可搜到（不塞进全部）
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
    pinnedHits := []
    otherHits := []
    if IsObject(recentFolders) {
        for c in recentFolders {
            if !ItemMatchesView(c, "recent", query, todayOnly)
                continue
            if IsRecentFolderPinned(c)
                pinnedHits.Push(c)
            else
                otherHits.Push(c)
        }
    }
    all := []
    for c in pinnedHits
        all.Push(c)
    for c in otherHits
        all.Push(c)
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
