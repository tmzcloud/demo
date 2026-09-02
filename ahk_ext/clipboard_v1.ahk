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
VIEW_PAGE_SIZE := 20
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
eyB3aWR0aDogNHB4OyB9CiAgICAgICAgOjotd2Via2l0LXNjcm9sbGJhci10aHVtYiB7IGJhY2tncm91
bmQ6ICNkMGQzZGM7IGJvcmRlci1yYWRpdXM6IDJweDsgfQoKICAgICAgICAjYXBwIHsKICAgICAgICAg
ICAgaGVpZ2h0OiAxMDAlOyBkaXNwbGF5OiBmbGV4OyBmbGV4LWRpcmVjdGlvbjogY29sdW1uOwogICAg
ICAgICAgICBiYWNrZ3JvdW5kOiBsaW5lYXItZ3JhZGllbnQoMTgwZGVnLCAjZjdmOWZjIDAlLCAjZWVm
MWY2IDEwMCUpOwogICAgICAgICAgICAtd2Via2l0LWFwcC1yZWdpb246IGRyYWc7IGFwcC1yZWdpb246
IGRyYWc7CiAgICAgICAgICAgIHBvc2l0aW9uOiByZWxhdGl2ZTsKICAgICAgICAgICAgb3ZlcmZsb3c6
IGhpZGRlbjsKICAgICAgICB9CgogICAgICAgIC8qIOKUgOKUgCBSb3cgMSDilIDilIDilIDilIDilIDi
lIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDi
lIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIAgKi8KICAgICAgICAjaGRyIHsK
ICAgICAgICAgICAgZGlzcGxheTogZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsgZmxleC1zaHJpbms6
IDA7CiAgICAgICAgICAgIHBhZGRpbmc6IDVweCA2cHggNXB4IDhweDsgZ2FwOiA0cHg7CiAgICAgICAg
ICAgIGJhY2tncm91bmQ6ICNmMmY0Zjk7CiAgICAgICAgfQogICAgICAgICNoZWFydCB7IGZsZXgtc2hy
aW5rOiAwOyBsaW5lLWhlaWdodDogMTsgZGlzcGxheTpmbGV4OyBhbGlnbi1pdGVtczpjZW50ZXI7IH0K
ICAgICAgICAjaGVhcnQgc3ZnIHsgd2lkdGg6MTdweDsgaGVpZ2h0OjE3cHg7IGNvbG9yOiB2YXIoLS10
eHQyKTsgfQogICAgICAgICNoZHItZ3JvdyB7IGZsZXg6IDE7IG1pbi13aWR0aDogOHB4OyB9CgogICAg
ICAgIC8qIFNlYXJjaDogb3ZlcmxheSBleHBhbmQgKHRyYW5zZm9ybS9vcGFjaXR5IG9ubHkg4oCUIG5v
IHdpZHRoIGxheW91dCB0aHJhc2gpICovCiAgICAgICAgI3NlYXJjaC13cmFwIHsKICAgICAgICAgICAg
ZmxleDogMCAwIDI4cHg7CiAgICAgICAgICAgIHdpZHRoOiAyOHB4OwogICAgICAgICAgICBoZWlnaHQ6
IDI4cHg7CiAgICAgICAgICAgIHBvc2l0aW9uOiByZWxhdGl2ZTsKICAgICAgICAgICAgei1pbmRleDog
NjsKICAgICAgICAgICAgLXdlYmtpdC1hcHAtcmVnaW9uOiBuby1kcmFnOyBhcHAtcmVnaW9uOiBuby1k
cmFnOwogICAgICAgIH0KICAgICAgICAjYnRuLXNlYXJjaCB7CiAgICAgICAgICAgIHBvc2l0aW9uOiBh
YnNvbHV0ZTsgcmlnaHQ6IDA7IHRvcDogMDsKICAgICAgICAgICAgd2lkdGg6IDI4cHg7IGhlaWdodDog
MjhweDsKICAgICAgICAgICAgZGlzcGxheTogZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsganVzdGlm
eS1jb250ZW50OiBjZW50ZXI7CiAgICAgICAgICAgIGJvcmRlcjogbm9uZTsgYmFja2dyb3VuZDogbm9u
ZTsgY3Vyc29yOiBwb2ludGVyOwogICAgICAgICAgICBjb2xvcjogdmFyKC0tdHh0Myk7IGJvcmRlci1y
YWRpdXM6IHZhcigtLXIpOwogICAgICAgICAgICB6LWluZGV4OiAyOwogICAgICAgICAgICB0cmFuc2l0
aW9uOiBjb2xvciAwLjE1cyBlYXNlLCBiYWNrZ3JvdW5kIDAuMTVzIGVhc2UsIG9wYWNpdHkgMC4xNXMg
ZWFzZTsKICAgICAgICB9CiAgICAgICAgI2J0bi1zZWFyY2g6aG92ZXIgeyBjb2xvcjogdmFyKC0tYWNj
KTsgYmFja2dyb3VuZDogcmdiYSg5MSwxMTUsMjMyLC4xKTsgfQogICAgICAgICNidG4tc2VhcmNoIHN2
ZyB7IHdpZHRoOiAxNXB4OyBoZWlnaHQ6IDE1cHg7IGRpc3BsYXk6IGJsb2NrOyB9CiAgICAgICAgI3Nl
YXJjaC13cmFwLm9wZW4gI2J0bi1zZWFyY2ggewogICAgICAgICAgICBvcGFjaXR5OiAwOwogICAgICAg
ICAgICBwb2ludGVyLWV2ZW50czogbm9uZTsKICAgICAgICB9CgogICAgICAgICNzZWFyY2gtYm94IHsK
ICAgICAgICAgICAgdHJhbnNmb3JtLW9yaWdpbjogcmlnaHQgY2VudGVyOwogICAgICAgICAgICBwb3Np
dGlvbjogYWJzb2x1dGU7CiAgICAgICAgICAgIHJpZ2h0OiAwOwogICAgICAgICAgICB0b3A6IDA7CiAg
ICAgICAgICAgIHdpZHRoOiAxOTZweDsKICAgICAgICAgICAgaGVpZ2h0OiAyOHB4OwogICAgICAgICAg
ICBib3gtc2l6aW5nOiBib3JkZXItYm94OwogICAgICAgICAgICBwYWRkaW5nOiAwIDJweCAwIDJweDsK
ICAgICAgICAgICAgYmFja2dyb3VuZDogdHJhbnNwYXJlbnQ7CiAgICAgICAgICAgIGJvcmRlcjogbm9u
ZTsKICAgICAgICAgICAgYm9yZGVyLXJhZGl1czogMDsKICAgICAgICAgICAgb3BhY2l0eTogMDsKICAg
ICAgICAgICAgdHJhbnNmb3JtOiB0cmFuc2xhdGUzZCg4cHgsIDAsIDApIHNjYWxlKDAuOTg1KTsKICAg
ICAgICAgICAgcG9pbnRlci1ldmVudHM6IG5vbmU7CiAgICAgICAgICAgIGRpc3BsYXk6IGZsZXg7CiAg
ICAgICAgICAgIGFsaWduLWl0ZW1zOiBjZW50ZXI7CiAgICAgICAgICAgIGdhcDogNHB4OwogICAgICAg
ICAgICB3aWxsLWNoYW5nZTogdHJhbnNmb3JtLCBvcGFjaXR5OwogICAgICAgICAgICBiYWNrZmFjZS12
aXNpYmlsaXR5OiBoaWRkZW47CiAgICAgICAgICAgIHRyYW5zaXRpb246IG9wYWNpdHkgMC4xOHMgZWFz
ZSwgdHJhbnNmb3JtIDAuMjRzIGN1YmljLWJlemllcigwLjE2LCAxLCAwLjMsIDEpOwogICAgICAgIH0K
ICAgICAgICAjc2VhcmNoLXdyYXAub3BlbiAjc2VhcmNoLWJveCB7CiAgICAgICAgICAgIHRyYW5zZm9y
bS1vcmlnaW46IHJpZ2h0IGNlbnRlcjsKICAgICAgICAgICAgdHJhbnNmb3JtLW9yaWdpbjogcmlnaHQg
Y2VudGVyOwogICAgICAgICAgICBvcGFjaXR5OiAxOwogICAgICAgICAgICB0cmFuc2Zvcm06IHRyYW5z
bGF0ZTNkKDAsIDAsIDApOwogICAgICAgICAgICBwb2ludGVyLWV2ZW50czogYXV0bzsKICAgICAgICB9
CgogICAgICAgICNzZWFyY2ggewogICAgICAgICAgICBmbGV4OiAxOyBtaW4td2lkdGg6IDA7IGhlaWdo
dDogMjhweDsgYm9yZGVyOiBub25lOwogICAgICAgICAgICBib3JkZXItYm90dG9tOiAxcHggc29saWQg
dHJhbnNwYXJlbnQ7CiAgICAgICAgICAgIGJvcmRlci1yYWRpdXM6IDA7IGJhY2tncm91bmQ6IHRyYW5z
cGFyZW50OyBjb2xvcjogdmFyKC0tdHh0KTsgZm9udC1zaXplOiAxMnB4OwogICAgICAgICAgICBwYWRk
aW5nOiAwIDIycHggMCAycHg7IG91dGxpbmU6IG5vbmU7CiAgICAgICAgICAgIHRyYW5zaXRpb246IGJv
cmRlci1ib3R0b20tY29sb3IgMC4xOHMgZWFzZTsKICAgICAgICB9CiAgICAgICAgI3NlYXJjaC13cmFw
Lm9wZW4gI3NlYXJjaCB7CiAgICAgICAgICAgIGJvcmRlci1ib3R0b20tY29sb3I6ICNjNWNhZDY7CiAg
ICAgICAgfQogICAgICAgICNzZWFyY2gtd3JhcC5vcGVuICNzZWFyY2g6Zm9jdXMgewogICAgICAgICAg
ICBib3JkZXItYm90dG9tLWNvbG9yOiB2YXIoLS1hY2MpOwogICAgICAgIH0KICAgICAgICBtYXJrLnEt
aGwgewogICAgICAgICAgICBiYWNrZ3JvdW5kOiByZ2JhKDI1NSwgMTk2LCAwLCAuNDIpOwogICAgICAg
ICAgICBjb2xvcjogaW5oZXJpdDsKICAgICAgICAgICAgYm9yZGVyLXJhZGl1czogMnB4OwogICAgICAg
ICAgICBwYWRkaW5nOiAwIDFweDsKICAgICAgICAgICAgZGlzcGxheTogaW5saW5lOwogICAgICAgICAg
ICBib3gtZGVjb3JhdGlvbi1icmVhazogY2xvbmU7CiAgICAgICAgICAgIC13ZWJraXQtYm94LWRlY29y
YXRpb24tYnJlYWs6IGNsb25lOwogICAgICAgIH0KICAgICAgICAvKiBtYXJrIGJyZWFrcyAtd2Via2l0
LWxpbmUtY2xhbXA7IGtlZXAgZm9sZCB2aWEgbWF4LWhlaWdodCB3aGlsZSBzZWFyY2hpbmcgKi8KICAg
ICAgICAuaS1wcmV2Lmhhcy1obCwgLmktbmFtZS5oYXMtaGwsIC5tZy1ib2R5Lmhhcy1obCwKICAgICAg
ICAuaS1saW5rLXRpdGxlLmhhcy1obCwgLmktbGluay11cmwuaGFzLWhsLCAuaS1mYXYtdGl0bGUuaGFz
LWhsIHsKICAgICAgICAgICAgZGlzcGxheTogYmxvY2s7CiAgICAgICAgICAgIC13ZWJraXQtbGluZS1j
bGFtcDogdW5zZXQ7CiAgICAgICAgICAgIG92ZXJmbG93OiBoaWRkZW47CiAgICAgICAgfQogICAgICAg
IC5pLXByZXYuaGFzLWhsLCAubWctYm9keS5oYXMtaGwgeyBtYXgtaGVpZ2h0OiBjYWxjKDEuNDVlbSAq
IDUpOyB9CiAgICAgICAgLmktbmFtZS5oYXMtaGwgeyBtYXgtaGVpZ2h0OiBjYWxjKDEuNDVlbSAqIDIp
OyB9CiAgICAgICAgLmktbGluay11cmwuaGFzLWhsIHsgbWF4LWhlaWdodDogY2FsYygxLjQ1ZW0gKiAz
KTsgfQogICAgICAgIC5pLXByZXYuaGFzLWhsLmV4cGFuZGVkLCAuaS1uYW1lLmhhcy1obC5leHBhbmRl
ZCwKICAgICAgICAubWctYm9keS5oYXMtaGwuZXhwYW5kZWQsIC5pLWxpbmstdXJsLmhhcy1obC5leHBh
bmRlZCB7CiAgICAgICAgICAgIC8qIOWxleW8gOmrmOW6pueUsSBKUyDmjqfliLbvvJvku43oo4HliIfl
ubblnKjmnKvlsL7liqDjgIwgLi4u44CNICovCiAgICAgICAgICAgIG92ZXJmbG93OiBoaWRkZW47CiAg
ICAgICAgfQogICAgICAgIC5pLWV4cGFuZC1idG4sIC5pLW1ldGEgeyB1c2VyLXNlbGVjdDogbm9uZTsg
fQogICAgICAgICNzZWFyY2g6OnBsYWNlaG9sZGVyIHsgY29sb3I6IHZhcigtLXR4dDMpOyB9CiAgICAg
ICAgI3NlYXJjaC1jbHIgewogICAgICAgICAgICBwb3NpdGlvbjogYWJzb2x1dGU7IHJpZ2h0OiA0cHg7
IHRvcDogNTAlOyB0cmFuc2Zvcm06IHRyYW5zbGF0ZVkoLTUwJSk7CiAgICAgICAgICAgIGJvcmRlcjog
bm9uZTsgYmFja2dyb3VuZDogbm9uZTsgY29sb3I6IHZhcigtLXR4dDMpOyBjdXJzb3I6IHBvaW50ZXI7
CiAgICAgICAgICAgIGZvbnQtc2l6ZTogMTFweDsgZGlzcGxheTogbm9uZTsgcGFkZGluZzogMnB4Owog
ICAgICAgICAgICBvcGFjaXR5OiAwLjg1OwogICAgICAgICAgICB0cmFuc2l0aW9uOiBjb2xvciAwLjEy
cyBlYXNlLCBvcGFjaXR5IDAuMTJzIGVhc2U7CiAgICAgICAgICAgIC13ZWJraXQtYXBwLXJlZ2lvbjog
bm8tZHJhZzsgYXBwLXJlZ2lvbjogbm8tZHJhZzsKICAgICAgICB9CiAgICAgICAgI3NlYXJjaC1jbHI6
aG92ZXIgeyBjb2xvcjogdmFyKC0tYWNjKTsgb3BhY2l0eTogMTsgfQoKICAgICAgICAjYnRuLXRvZGF5
IHsKICAgICAgICAgICAgZGlzcGxheTogbm9uZTsKICAgICAgICAgICAgaGVpZ2h0OiAxOHB4OyBwYWRk
aW5nOiAwIDdweDsgZmxleC1zaHJpbms6IDA7CiAgICAgICAgICAgIGFsaWduLWl0ZW1zOiBjZW50ZXI7
IGp1c3RpZnktY29udGVudDogY2VudGVyOwogICAgICAgICAgICBib3JkZXI6IDFweCBzb2xpZCByZ2Jh
KDkxLDExNSwyMzIsLjIyKTsgYmFja2dyb3VuZDogcmdiYSg5MSwxMTUsMjMyLC4xMCk7CiAgICAgICAg
ICAgIGNvbG9yOiAjNmI4MmU4OyBib3JkZXItcmFkaXVzOiA5OTlweDsgZm9udC1zaXplOiA5cHg7IGZv
bnQtd2VpZ2h0OiA2MDA7CiAgICAgICAgICAgIGxpbmUtaGVpZ2h0OiAxOyB3aGl0ZS1zcGFjZTogbm93
cmFwOyBjdXJzb3I6IHBvaW50ZXI7CiAgICAgICAgICAgIC13ZWJraXQtYXBwLXJlZ2lvbjogbm8tZHJh
ZzsgYXBwLXJlZ2lvbjogbm8tZHJhZzsKICAgICAgICAgICAgdHJhbnNpdGlvbjogY29sb3IgdmFyKC0t
dHIpLCBiYWNrZ3JvdW5kIHZhcigtLXRyKSwgYm9yZGVyLWNvbG9yIHZhcigtLXRyKSwgb3BhY2l0eSB2
YXIoLS10cik7CiAgICAgICAgfQogICAgICAgICNzZWFyY2gtd3JhcC5vcGVuICNidG4tdG9kYXkgeyBk
aXNwbGF5OiBpbmxpbmUtZmxleDsgfQogICAgICAgICNidG4tdG9kYXk6aG92ZXIgeyBjb2xvcjogIzRh
NjJkNDsgYmFja2dyb3VuZDogcmdiYSg5MSwxMTUsMjMyLC4xNik7IH0KICAgICAgICAjYnRuLXRvZGF5
Lm9uIHsKICAgICAgICAgICAgY29sb3I6ICM1YjczZTg7CiAgICAgICAgICAgIGJhY2tncm91bmQ6IHJn
YmEoOTEsMTE1LDIzMiwuMTYpOwogICAgICAgICAgICBib3JkZXItY29sb3I6IHJnYmEoOTEsMTE1LDIz
MiwuMzIpOwogICAgICAgIH0KICAgICAgICAjYnRuLXRvZGF5Om5vdCgub24pIHsKICAgICAgICAgICAg
Y29sb3I6IHZhcigtLXR4dDMpOwogICAgICAgICAgICBiYWNrZ3JvdW5kOiByZ2JhKDAsMCwwLC4wNCk7
CiAgICAgICAgICAgIGJvcmRlci1jb2xvcjogcmdiYSgwLDAsMCwuMDYpOwogICAgICAgIH0KCiAgICAg
ICAgI2J0bi1waW4gewogICAgICAgICAgICB3aWR0aDogMjhweDsgaGVpZ2h0OiAyOHB4OyBmbGV4LXNo
cmluazogMDsKICAgICAgICAgICAgZGlzcGxheTogZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsganVz
dGlmeS1jb250ZW50OiBjZW50ZXI7CiAgICAgICAgICAgIGJvcmRlcjogMS41cHggc29saWQgdHJhbnNw
YXJlbnQ7IGJhY2tncm91bmQ6IG5vbmU7IGN1cnNvcjogcG9pbnRlcjsKICAgICAgICAgICAgY29sb3I6
IHZhcigtLXR4dDMpOyBib3JkZXItcmFkaXVzOiB2YXIoLS1yKTsKICAgICAgICAgICAgLXdlYmtpdC1h
cHAtcmVnaW9uOiBuby1kcmFnOyBhcHAtcmVnaW9uOiBuby1kcmFnOwogICAgICAgICAgICB0cmFuc2l0
aW9uOiBjb2xvciB2YXIoLS10ciksIGJhY2tncm91bmQgdmFyKC0tdHIpLCBib3JkZXItY29sb3IgdmFy
KC0tdHIpOwogICAgICAgIH0KICAgICAgICAjYnRuLXBpbjpob3ZlciB7IGNvbG9yOiB2YXIoLS1hY2Mp
OyBiYWNrZ3JvdW5kOiByZ2JhKDkxLDExNSwyMzIsLjEpOyB9CiAgICAgICAgI2J0bi1waW4ub24gIHsK
ICAgICAgICAgICAgY29sb3I6IHZhcigtLWFjYyk7CiAgICAgICAgICAgIGJhY2tncm91bmQ6IHJnYmEo
OTEsMTE1LDIzMiwuMTgpOwogICAgICAgICAgICBib3JkZXItY29sb3I6IHJnYmEoOTEsMTE1LDIzMiwu
NTUpOwogICAgICAgIH0KICAgICAgICAjYnRuLXBpbiBzdmcgeyB3aWR0aDogMTRweDsgaGVpZ2h0OiAx
NHB4OyBkaXNwbGF5OiBibG9jazsgfQoKICAgICAgICAjYnRuLWxvY2F0ZSB7CiAgICAgICAgICAgIHdp
ZHRoOiAyOHB4OyBoZWlnaHQ6IDI4cHg7IGZsZXgtc2hyaW5rOiAwOwogICAgICAgICAgICBkaXNwbGF5
OiBmbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBqdXN0aWZ5LWNvbnRlbnQ6IGNlbnRlcjsKICAgICAg
ICAgICAgYm9yZGVyOiBub25lOyBiYWNrZ3JvdW5kOiBub25lOyBjdXJzb3I6IHBvaW50ZXI7CiAgICAg
ICAgICAgIGNvbG9yOiB2YXIoLS10eHQzKTsgYm9yZGVyLXJhZGl1czogdmFyKC0tcik7CiAgICAgICAg
ICAgIC13ZWJraXQtYXBwLXJlZ2lvbjogbm8tZHJhZzsgYXBwLXJlZ2lvbjogbm8tZHJhZzsKICAgICAg
ICAgICAgdHJhbnNpdGlvbjogY29sb3IgdmFyKC0tdHIpLCBiYWNrZ3JvdW5kIHZhcigtLXRyKSwgb3Bh
Y2l0eSB2YXIoLS10cik7CiAgICAgICAgfQogICAgICAgICNidG4tbG9jYXRlOmhvdmVyOm5vdCg6ZGlz
YWJsZWQpIHsgY29sb3I6IHZhcigtLWFjYyk7IGJhY2tncm91bmQ6IHJnYmEoOTEsMTE1LDIzMiwuMSk7
IH0KICAgICAgICAjYnRuLWxvY2F0ZTpkaXNhYmxlZCB7IG9wYWNpdHk6IC4zNTsgY3Vyc29yOiBkZWZh
dWx0OyB9CiAgICAgICAgI2J0bi1sb2NhdGUuaGFzLXRhcmdldCB7IGNvbG9yOiB2YXIoLS1hY2MpOyB9
CiAgICAgICAgI2J0bi1sb2NhdGUub24gewogICAgICAgICAgICBjb2xvcjogdmFyKC0tYWNjKTsKICAg
ICAgICAgICAgYmFja2dyb3VuZDogcmdiYSg5MSwxMTUsMjMyLC4xOCk7CiAgICAgICAgfQogICAgICAg
ICNidG4tbG9jYXRlIHN2ZyB7IHdpZHRoOiAxNXB4OyBoZWlnaHQ6IDE1cHg7IGRpc3BsYXk6IGJsb2Nr
OyB9CiAgICAgICAgI2hkcjpoYXMoI3NlYXJjaC13cmFwLm9wZW4pICNidG4tbG9jYXRlIHsKICAgICAg
ICAgICAgZGlzcGxheTogbm9uZTsKICAgICAgICB9CgogICAgICAgIC8qIOKUgOKUgCBSb3cgMiDilIDi
lIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDi
lIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIAgKi8KICAg
ICAgICAjdGFicyB7CiAgICAgICAgICAgIHBvc2l0aW9uOiByZWxhdGl2ZTsKICAgICAgICAgICAgZGlz
cGxheTogZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsgZ2FwOiAwOyBmbGV4LXdyYXA6IG5vd3JhcDsK
ICAgICAgICAgICAgcGFkZGluZzogNXB4IDZweCA1cHggOHB4OyBmbGV4LXNocmluazogMDsKICAgICAg
ICAgICAgYmFja2dyb3VuZDogI2YyZjRmOTsKICAgICAgICB9CiAgICAgICAgI3RhYi1pbmsgewogICAg
ICAgICAgICBwb3NpdGlvbjogYWJzb2x1dGU7CiAgICAgICAgICAgIGxlZnQ6IDA7IHRvcDogMDsKICAg
ICAgICAgICAgaGVpZ2h0OiAyMnB4OwogICAgICAgICAgICBib3JkZXItcmFkaXVzOiA5OTlweDsKICAg
ICAgICAgICAgYmFja2dyb3VuZDogI2ZmZjsKICAgICAgICAgICAgYm94LXNoYWRvdzogMCAxcHggM3B4
IHJnYmEoMCwwLDAsLjA3KSwgMCAwIDAgMXB4IHJnYmEoOTEsMTE1LDIzMiwuMDYpOwogICAgICAgICAg
ICBwb2ludGVyLWV2ZW50czogbm9uZTsKICAgICAgICAgICAgei1pbmRleDogMDsKICAgICAgICAgICAg
dHJhbnNmb3JtOiB0cmFuc2xhdGUzZCgwLDAsMCkgc2NhbGVYKDEpOwogICAgICAgICAgICB0cmFuc2Zv
cm0tb3JpZ2luOiBjZW50ZXIgYm90dG9tOwogICAgICAgICAgICB0cmFuc2l0aW9uOgogICAgICAgICAg
ICAgICAgdHJhbnNmb3JtIDAuMzRzIGN1YmljLWJlemllcigwLjIyLCAxLjE4LCAwLjMyLCAxKSwKICAg
ICAgICAgICAgICAgIGhlaWdodCAwLjI0cyBlYXNlOwogICAgICAgICAgICB3aWxsLWNoYW5nZTogdHJh
bnNmb3JtLCBoZWlnaHQ7CiAgICAgICAgfQogICAgICAgICN0YWItaW5rLnNxdWFzaCB7CiAgICAgICAg
ICAgIHRyYW5zaXRpb246CiAgICAgICAgICAgICAgICB0cmFuc2Zvcm0gMC4zMHMgY3ViaWMtYmV6aWVy
KDAuMzQsIDEuMjgsIDAuNDQsIDEpLAogICAgICAgICAgICAgICAgaGVpZ2h0IDAuMjBzIGVhc2U7CiAg
ICAgICAgfQogICAgICAgIC50YWIgewogICAgICAgICAgICBwb3NpdGlvbjogcmVsYXRpdmU7CiAgICAg
ICAgICAgIHotaW5kZXg6IDE7CiAgICAgICAgICAgIHBhZGRpbmc6IDNweCA4cHg7IGZvbnQtc2l6ZTog
MTFweDsgY29sb3I6IHZhcigtLXR4dDIpOyBjdXJzb3I6IHBvaW50ZXI7CiAgICAgICAgICAgIGJvcmRl
ci1yYWRpdXM6IDk5OXB4OyB3aGl0ZS1zcGFjZTogbm93cmFwOwogICAgICAgICAgICBiYWNrZ3JvdW5k
OiB0cmFuc3BhcmVudDsKICAgICAgICAgICAgdHJhbnNpdGlvbjogY29sb3IgMC4yOHMgY3ViaWMtYmV6
aWVyKDAuMjIsIDEsIDAuMzYsIDEpLAogICAgICAgICAgICAgICAgICAgICAgICB0cmFuc2Zvcm0gMC4y
OHMgY3ViaWMtYmV6aWVyKDAuMjIsIDEsIDAuMzYsIDEpOwogICAgICAgICAgICAtd2Via2l0LWFwcC1y
ZWdpb246IG5vLWRyYWc7IGFwcC1yZWdpb246IG5vLWRyYWc7CiAgICAgICAgfQogICAgICAgIC50YWI6
aG92ZXIgeyBjb2xvcjogdmFyKC0tdHh0KTsgYmFja2dyb3VuZDogdHJhbnNwYXJlbnQ7IH0KICAgICAg
ICAudGFiOmFjdGl2ZSB7IHRyYW5zZm9ybTogc2NhbGUoMC45Nik7IH0KICAgICAgICAudGFiLm9uIHsg
Y29sb3I6IHZhcigtLWFjYyk7IGJhY2tncm91bmQ6IHRyYW5zcGFyZW50OyBib3gtc2hhZG93OiBub25l
OyBmb250LXdlaWdodDogNjAwOyB9CiAgICAgICAgLmJhZGdlIHsKICAgICAgICAgICAgZGlzcGxheTog
aW5saW5lLWZsZXg7IG1pbi13aWR0aDogMTRweDsgaGVpZ2h0OiAxNHB4OyBwYWRkaW5nOiAwIDNweDsK
ICAgICAgICAgICAgYWxpZ24taXRlbXM6IGNlbnRlcjsganVzdGlmeS1jb250ZW50OiBjZW50ZXI7CiAg
ICAgICAgICAgIGJhY2tncm91bmQ6IHZhcigtLWFjYyk7IGNvbG9yOiAjZmZmOyBmb250LXNpemU6IDlw
eDsgYm9yZGVyLXJhZGl1czogN3B4OyBmb250LXdlaWdodDogNzAwOwogICAgICAgIH0KICAgICAgICAj
dGFiLWFjdGlvbnMgewogICAgICAgICAgICBtYXJnaW4tbGVmdDogYXV0bzsgZGlzcGxheTogZmxleDsg
YWxpZ24taXRlbXM6IGNlbnRlcjsgZ2FwOiA0cHg7CiAgICAgICAgICAgIGNvbG9yOiB2YXIoLS10eHQz
KTsgZm9udC1zaXplOiAxMHB4OwogICAgICAgICAgICAtd2Via2l0LWFwcC1yZWdpb246IG5vLWRyYWc7
IGFwcC1yZWdpb246IG5vLWRyYWc7CiAgICAgICAgfQogICAgICAgICNiYXItdHh0IHsgd2hpdGUtc3Bh
Y2U6IG5vd3JhcDsgfQogICAgICAgICNidG4tY2xyIHsKICAgICAgICAgICAgZGlzcGxheTogZmxleDsg
YWxpZ24taXRlbXM6IGNlbnRlcjsganVzdGlmeS1jb250ZW50OiBjZW50ZXI7CiAgICAgICAgICAgIHdp
ZHRoOiAyNnB4OyBoZWlnaHQ6IDI2cHg7IGJvcmRlcjogbm9uZTsgYmFja2dyb3VuZDogbm9uZTsgY29s
b3I6IHZhcigtLXR4dDMpOwogICAgICAgICAgICBjdXJzb3I6IHBvaW50ZXI7IGJvcmRlci1yYWRpdXM6
IHZhcigtLXIpOwogICAgICAgICAgICAtd2Via2l0LWFwcC1yZWdpb246IG5vLWRyYWc7IGFwcC1yZWdp
b246IG5vLWRyYWc7CiAgICAgICAgICAgIHRyYW5zaXRpb246IGNvbG9yIHZhcigtLXRyKSwgYmFja2dy
b3VuZCB2YXIoLS10cik7CiAgICAgICAgfQogICAgICAgICNidG4tY2xyOmhvdmVyIHsgY29sb3I6ICNm
ZjdiOWM7IGJhY2tncm91bmQ6IHJnYmEoMjU1LDEyMywxNTYsLjA4KTsgfQogICAgICAgICNidG4tY2xy
IHN2ZyB7IHdpZHRoOiAxNHB4OyBoZWlnaHQ6IDE0cHg7IGRpc3BsYXk6IGJsb2NrOyB9CgogICAgICAg
IC8qIOKUgOKUgCBMaXN0IOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKU
gOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKU
gOKUgOKUgOKUgOKUgOKUgCAqLwogICAgICAgICNsaXN0IHsKICAgICAgICAgICAgZmxleDogMTsgb3Zl
cmZsb3cteTogYXV0bzsgb3ZlcmZsb3cteDogaGlkZGVuOyBwYWRkaW5nOiA2cHggOHB4IDZweCAxMHB4
OyBjdXJzb3I6IGRlZmF1bHQ7CiAgICAgICAgICAgIC13ZWJraXQtYXBwLXJlZ2lvbjogZHJhZzsgYXBw
LXJlZ2lvbjogZHJhZzsKICAgICAgICAgICAgbWluLWhlaWdodDogMDsKICAgICAgICB9CiAgICAgICAg
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
ICAgICAgICAgICBkaXNwbGF5OiBub25lOyBmbGV4LWRpcmVjdGlvbjogY29sdW1uOyBnYXA6IDhweDsK
ICAgICAgICAgICAgcGFkZGluZzogNHB4IDJweCAxMHB4OyAtd2Via2l0LWFwcC1yZWdpb246IGRyYWc7
IGFwcC1yZWdpb246IGRyYWc7CiAgICAgICAgfQogICAgICAgICNza2VsLm9uIHsgZGlzcGxheTogZmxl
eDsgfQogICAgICAgICNhcHAuYm9vdC1sb2FkaW5nICNza2VsIHsKICAgICAgICAgICAgZGlzcGxheTog
ZmxleCAhaW1wb3J0YW50OwogICAgICAgIH0KICAgICAgICAjYXBwLmJvb3QtbG9hZGluZyAjZW1wdHkg
ewogICAgICAgICAgICBkaXNwbGF5OiBub25lICFpbXBvcnRhbnQ7CiAgICAgICAgfQogICAgICAgIC5z
ay1yb3cgewogICAgICAgICAgICBkaXNwbGF5OiBmbGV4OyBhbGlnbi1pdGVtczogZmxleC1zdGFydDsg
Z2FwOiAxMHB4OwogICAgICAgICAgICBwYWRkaW5nOiAxMHB4IDhweDsgYm9yZGVyLXJhZGl1czogOHB4
OwogICAgICAgICAgICBiYWNrZ3JvdW5kOiByZ2JhKDI1NSwyNTUsMjU1LC43Mik7CiAgICAgICAgICAg
IGJvcmRlcjogMXB4IHNvbGlkIHJnYmEoMTcwLDE4MCwyMDAsLjQ1KTsKICAgICAgICAgICAgcG9zaXRp
b246IHJlbGF0aXZlOwogICAgICAgICAgICBvdmVyZmxvdzogaGlkZGVuOwogICAgICAgIH0KICAgICAg
ICAuc2stcm93OjphZnRlciB7CiAgICAgICAgICAgIGNvbnRlbnQ6ICcnOwogICAgICAgICAgICBwb3Np
dGlvbjogYWJzb2x1dGU7CiAgICAgICAgICAgIGluc2V0OiAwOwogICAgICAgICAgICBiYWNrZ3JvdW5k
OiBsaW5lYXItZ3JhZGllbnQoOTBkZWcsIHRyYW5zcGFyZW50IDAlLCByZ2JhKDI1NSwyNTUsMjU1LC43
MikgNDglLCB0cmFuc3BhcmVudCAxMDAlKTsKICAgICAgICAgICAgdHJhbnNmb3JtOiB0cmFuc2xhdGVY
KC0xMjAlKTsKICAgICAgICAgICAgYW5pbWF0aW9uOiBzay1zd2VlcCAwLjk1cyBlYXNlLWluLW91dCBp
bmZpbml0ZTsKICAgICAgICAgICAgcG9pbnRlci1ldmVudHM6IG5vbmU7CiAgICAgICAgfQogICAgICAg
IEBrZXlmcmFtZXMgc2stc3dlZXAgewogICAgICAgICAgICAxMDAlIHsgdHJhbnNmb3JtOiB0cmFuc2xh
dGVYKDEyMCUpOyB9CiAgICAgICAgfQogICAgICAgIC5zay1pY28sIC5zay1saW5lIHsKICAgICAgICAg
ICAgYmFja2dyb3VuZDogbGluZWFyLWdyYWRpZW50KDkwZGVnLCAjYjhjMmQ4IDAlLCAjZjBmNGZhIDM4
JSwgI2RjZTNmMCA1MiUsICNiOGMyZDggMTAwJSk7CiAgICAgICAgICAgIGJhY2tncm91bmQtc2l6ZTog
MjQwJSAxMDAlOwogICAgICAgICAgICBhbmltYXRpb246IHNrLXNoaW1tZXIgMC43MnMgZWFzZS1pbi1v
dXQgaW5maW5pdGU7CiAgICAgICAgICAgIHdpbGwtY2hhbmdlOiBiYWNrZ3JvdW5kLXBvc2l0aW9uOwog
ICAgICAgICAgICBib3JkZXItcmFkaXVzOiA2cHg7CiAgICAgICAgfQogICAgICAgIC5zay1pY28geyB3
aWR0aDogMzRweDsgaGVpZ2h0OiAzNHB4OyBmbGV4LXNocmluazogMDsgYm9yZGVyLXJhZGl1czogOHB4
OyB9CiAgICAgICAgLnNrLWJvZHkgeyBmbGV4OiAxOyBtaW4td2lkdGg6IDA7IGRpc3BsYXk6IGZsZXg7
IGZsZXgtZGlyZWN0aW9uOiBjb2x1bW47IGdhcDogOHB4OyBwYWRkaW5nLXRvcDogMnB4OyB9CiAgICAg
ICAgLnNrLWxpbmUgeyBoZWlnaHQ6IDEwcHg7IHdpZHRoOiAxMDAlOyB9CiAgICAgICAgLnNrLWxpbmUu
c2hvcnQgeyB3aWR0aDogNDIlOyB9CiAgICAgICAgLnNrLWxpbmUubWlkIHsgd2lkdGg6IDY4JTsgfQog
ICAgICAgIC5zay1yb3c6bnRoLWNoaWxkKDIpOjphZnRlciB7IGFuaW1hdGlvbi1kZWxheTogLjEyczsg
fQogICAgICAgIC5zay1yb3c6bnRoLWNoaWxkKDMpOjphZnRlciB7IGFuaW1hdGlvbi1kZWxheTogLjI0
czsgfQogICAgICAgIC5zay1yb3c6bnRoLWNoaWxkKDQpOjphZnRlciB7IGFuaW1hdGlvbi1kZWxheTog
LjM2czsgfQogICAgICAgIC5zay1yb3c6bnRoLWNoaWxkKDUpOjphZnRlciB7IGFuaW1hdGlvbi1kZWxh
eTogLjQ4czsgfQogICAgICAgIC5zay1yb3c6bnRoLWNoaWxkKDYpOjphZnRlciB7IGFuaW1hdGlvbi1k
ZWxheTogLjZzOyB9CiAgICAgICAgQGtleWZyYW1lcyBzay1zaGltbWVyIHsKICAgICAgICAgICAgMCUg
eyBiYWNrZ3JvdW5kLXBvc2l0aW9uOiAxMDAlIDA7IH0KICAgICAgICAgICAgMTAwJSB7IGJhY2tncm91
bmQtcG9zaXRpb246IC0xMDAlIDA7IH0KICAgICAgICB9CiAgICAgICAgLmxpc3QtbW9yZSB7CiAgICAg
ICAgICAgIHRleHQtYWxpZ246IGNlbnRlcjsgcGFkZGluZzogMTBweCA4cHggMTRweDsgZm9udC1zaXpl
OiAxMXB4OwogICAgICAgICAgICBjb2xvcjogdmFyKC0tdHh0Myk7IC13ZWJraXQtYXBwLXJlZ2lvbjog
bm8tZHJhZzsgYXBwLXJlZ2lvbjogbm8tZHJhZzsKICAgICAgICB9CiAgICAgICAgLmxpc3QtbW9yZS5k
b25lIHsgZGlzcGxheTogbm9uZTsgfQoKICAgICAgICAuaXRtIHsKICAgICAgICAgICAgZGlzcGxheTog
ZmxleDsgYWxpZ24taXRlbXM6IGZsZXgtc3RhcnQ7IGdhcDogOHB4OwogICAgICAgICAgICBwYWRkaW5n
OiA4cHg7IG1hcmdpbi1ib3R0b206IDVweDsKICAgICAgICAgICAgYmFja2dyb3VuZDogdmFyKC0tY2Fy
ZCk7IGJvcmRlci1yYWRpdXM6IHZhcigtLXIpOyBjdXJzb3I6IHBvaW50ZXI7CiAgICAgICAgICAgIGJv
eC1zaGFkb3c6IDAgMXB4IDNweCByZ2JhKDI0LDMyLDU2LC4wNik7CiAgICAgICAgICAgIC8qIGhvdmVy
LWxpbmUgKi8KICAgICAgICAgICAgcG9zaXRpb246IHJlbGF0aXZlOwogICAgICAgICAgICB0cmFuc2l0
aW9uOiBiYWNrZ3JvdW5kIC4ycyBlYXNlLCBib3gtc2hhZG93IC4ycyBlYXNlOwogICAgICAgICAgICAt
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
aGFkb3c6IDAgMnB4IDhweCByZ2JhKDI0LDMyLDU2LC4xKTsKICAgICAgICB9CiAgICAgICAgLml0bTpo
b3Zlcjo6YWZ0ZXIgewogICAgICAgICAgICB0cmFuc2Zvcm06IHNjYWxlWCgxKTsKICAgICAgICB9CiAg
ICAgICAgLml0bS5zZWwgewogICAgICAgICAgICBib3gtc2hhZG93OiAwIDAgMCAycHggcmdiYSg5MSwx
MTUsMjMyLC40NSksIDAgMnB4IDhweCByZ2JhKDkxLDExNSwyMzIsLjE4KTsKICAgICAgICAgICAgYmFj
a2dyb3VuZDogI2VkZjFmZjsKICAgICAgICB9CiAgICAgICAgLml0bS5tdWx0aSB7CiAgICAgICAgICAg
IGJveC1zaGFkb3c6IDAgMCAwIDEuNXB4IHJnYmEoOTEsMTE1LDIzMiwuNTUpLCAwIDJweCA2cHggcmdi
YSg5MSwxMTUsMjMyLC4xOCk7CiAgICAgICAgICAgIGJhY2tncm91bmQ6ICNlZWYyZmY7CiAgICAgICAg
fQogICAgICAgIC5pdG0ubXVsdGkuc2VsIHsKICAgICAgICAgICAgYm94LXNoYWRvdzogMCAwIDAgMnB4
IHJnYmEoOTEsMTE1LDIzMiwuNyksIDAgMnB4IDhweCByZ2JhKDkxLDExNSwyMzIsLjIyKTsKICAgICAg
ICB9CgogICAgICAgICNtdWx0aS1iYXIgewogICAgICAgICAgICBkaXNwbGF5OiBub25lOyBhbGlnbi1p
dGVtczogY2VudGVyOyBnYXA6IDFweDsgZmxleC1zaHJpbms6IDA7CiAgICAgICAgICAgIC13ZWJraXQt
YXBwLXJlZ2lvbjogbm8tZHJhZzsgYXBwLXJlZ2lvbjogbm8tZHJhZzsKICAgICAgICB9CiAgICAgICAg
I211bHRpLWJhci5vbiB7IGRpc3BsYXk6IGlubGluZS1mbGV4OyB9CgogICAgICAgICNtdWx0aS1jbnQg
ewogICAgICAgICAgICBkaXNwbGF5OiBpbmxpbmUtZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsganVz
dGlmeS1jb250ZW50OiBjZW50ZXI7CiAgICAgICAgICAgIGhlaWdodDogMjJweDsgcGFkZGluZzogMCA5
cHg7IGZsZXgtc2hyaW5rOiAwOwogICAgICAgICAgICBib3JkZXI6IG5vbmU7IGJvcmRlci1yYWRpdXM6
IDExcHg7IGN1cnNvcjogcG9pbnRlcjsKICAgICAgICAgICAgYmFja2dyb3VuZDogdmFyKC0tYWNjKTsg
Y29sb3I6ICNmZmY7CiAgICAgICAgICAgIGZvbnQtc2l6ZTogMTFweDsgZm9udC13ZWlnaHQ6IDcwMDsK
ICAgICAgICAgICAgYm94LXNoYWRvdzogMCAxcHggNHB4IHJnYmEoOTEsMTE1LDIzMiwuMjgpOwogICAg
ICAgICAgICAtd2Via2l0LWFwcC1yZWdpb246IG5vLWRyYWc7IGFwcC1yZWdpb246IG5vLWRyYWc7CiAg
ICAgICAgICAgIHRyYW5zaXRpb246IGJhY2tncm91bmQgdmFyKC0tdHIpLCBib3gtc2hhZG93IHZhcigt
LXRyKTsKICAgICAgICB9CiAgICAgICAgI211bHRpLWNudDpob3ZlciB7CiAgICAgICAgICAgIGJhY2tn
cm91bmQ6ICM0YTYyZDQ7CiAgICAgICAgICAgIGJveC1zaGFkb3c6IDAgMnB4IDZweCByZ2JhKDkxLDEx
NSwyMzIsLjM1KTsKICAgICAgICB9CgogICAgICAgIC5tdWx0aS1iYXItZG90IHsKICAgICAgICAgICAg
Y29sb3I6IHZhcigtLXR4dDMpOyBmb250LXNpemU6IDEwcHg7IG9wYWNpdHk6IC40NTsKICAgICAgICAg
ICAgdXNlci1zZWxlY3Q6IG5vbmU7IGxpbmUtaGVpZ2h0OiAxOyBwYWRkaW5nOiAwIDFweDsKICAgICAg
ICB9CgogICAgICAgICNwYXN0ZS1zZXAtd3JhcCB7CiAgICAgICAgICAgIHBvc2l0aW9uOiByZWxhdGl2
ZTsgZmxleC1zaHJpbms6IDA7CiAgICAgICAgfQogICAgICAgICNwYXN0ZS1zZXAtYnRuIHsKICAgICAg
ICAgICAgZGlzcGxheTogaW5saW5lLWZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGdhcDogMnB4Owog
ICAgICAgICAgICBoZWlnaHQ6IDIwcHg7IHBhZGRpbmc6IDAgNnB4OwogICAgICAgICAgICBib3JkZXI6
IG5vbmU7IGJvcmRlci1yYWRpdXM6IDEwcHg7IGN1cnNvcjogcG9pbnRlcjsKICAgICAgICAgICAgYmFj
a2dyb3VuZDogdHJhbnNwYXJlbnQ7IGNvbG9yOiB2YXIoLS10eHQzKTsKICAgICAgICAgICAgZm9udC1z
aXplOiAxMXB4OyBsaW5lLWhlaWdodDogMTsgZm9udC13ZWlnaHQ6IDcwMDsKICAgICAgICAgICAgZm9u
dC1mYW1pbHk6IHVpLW1vbm9zcGFjZSwgQ29uc29sYXMsICJDYXNjYWRpYSBNb25vIiwgbW9ub3NwYWNl
OwogICAgICAgICAgICBjb2xvcjogdmFyKC0tYWNjKTsKICAgICAgICAgICAgLXdlYmtpdC1hcHAtcmVn
aW9uOiBuby1kcmFnOyBhcHAtcmVnaW9uOiBuby1kcmFnOwogICAgICAgICAgICB0cmFuc2l0aW9uOiBi
YWNrZ3JvdW5kIHZhcigtLXRyKSwgY29sb3IgdmFyKC0tdHIpOwogICAgICAgIH0KICAgICAgICAjcGFz
dGUtc2VwLWJ0bjpob3ZlciwgI3Bhc3RlLXNlcC1idG4ub3BlbiB7CiAgICAgICAgICAgIGJhY2tncm91
bmQ6IHJnYmEoOTEsMTE1LDIzMiwuMDgpOyBjb2xvcjogdmFyKC0tdHh0Mik7CiAgICAgICAgfQoKICAg
ICAgICAjcGFzdGUtc2VwLW1lbnUgewogICAgICAgICAgICBkaXNwbGF5OiBub25lOyBwb3NpdGlvbjog
YWJzb2x1dGU7IHRvcDogY2FsYygxMDAlICsgNXB4KTsgbGVmdDogMDsKICAgICAgICAgICAgbWluLXdp
ZHRoOiAxMDhweDsgbWF4LXdpZHRoOiAxNjBweDsgbWF4LWhlaWdodDogMjQwcHg7CiAgICAgICAgICAg
IG92ZXJmbG93LXk6IGF1dG87IHotaW5kZXg6IDEyMDsKICAgICAgICAgICAgYmFja2dyb3VuZDogcmdi
YSgyNTAsMjUxLDI1NCwuOTcpOwogICAgICAgICAgICBib3JkZXI6IDFweCBzb2xpZCByZ2JhKDAsMCww
LC4wNSk7CiAgICAgICAgICAgIGJvcmRlci1yYWRpdXM6IDhweDsKICAgICAgICAgICAgYm94LXNoYWRv
dzogMCA2cHggMjBweCByZ2JhKDQ0LDQ2LDU0LC4xKTsKICAgICAgICAgICAgcGFkZGluZzogNHB4Owog
ICAgICAgICAgICBiYWNrZHJvcC1maWx0ZXI6IGJsdXIoOHB4KTsKICAgICAgICB9CiAgICAgICAgI3Bh
c3RlLXNlcC1tZW51Lm9uIHsgZGlzcGxheTogYmxvY2s7IH0KICAgICAgICAucGFzdGUtc2VwLWl0ZW0g
ewogICAgICAgICAgICBkaXNwbGF5OiBmbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBnYXA6IDZweDsK
ICAgICAgICAgICAgd2lkdGg6IDEwMCU7IHRleHQtYWxpZ246IGxlZnQ7CiAgICAgICAgICAgIHBhZGRp
bmc6IDVweCA4cHg7IGJvcmRlcjogbm9uZTsgYm9yZGVyLXJhZGl1czogNnB4OwogICAgICAgICAgICBi
YWNrZ3JvdW5kOiBub25lOyBjb2xvcjogdmFyKC0tdHh0Mik7CiAgICAgICAgICAgIGZvbnQtc2l6ZTog
MTBweDsgY3Vyc29yOiBwb2ludGVyOyB3aGl0ZS1zcGFjZTogbm93cmFwOwogICAgICAgICAgICBvdmVy
ZmxvdzogaGlkZGVuOwogICAgICAgICAgICB0cmFuc2l0aW9uOiBiYWNrZ3JvdW5kIHZhcigtLXRyKSwg
Y29sb3IgdmFyKC0tdHIpOwogICAgICAgIH0KICAgICAgICAucGFzdGUtc2VwLXN5bSB7CiAgICAgICAg
ICAgIGZsZXgtc2hyaW5rOiAwOyBtaW4td2lkdGg6IDMwcHg7CiAgICAgICAgICAgIGZvbnQtZmFtaWx5
OiB1aS1tb25vc3BhY2UsIENvbnNvbGFzLCAiQ2FzY2FkaWEgTW9ubyIsIG1vbm9zcGFjZTsKICAgICAg
ICAgICAgZm9udC1zaXplOiAxMnB4OyBmb250LXdlaWdodDogNzAwOyBjb2xvcjogdmFyKC0tYWNjKTsK
ICAgICAgICB9CiAgICAgICAgLnBhc3RlLXNlcC1zeW0ub25seSB7IG1pbi13aWR0aDogMDsgfQogICAg
ICAgIC5wYXN0ZS1zZXAtbmFtZSB7CiAgICAgICAgICAgIGZsZXg6IDE7IG1pbi13aWR0aDogMDsKICAg
ICAgICAgICAgZm9udC1zaXplOiAxMHB4OyBjb2xvcjogdmFyKC0tdHh0Myk7CiAgICAgICAgICAgIG92
ZXJmbG93OiBoaWRkZW47IHRleHQtb3ZlcmZsb3c6IGVsbGlwc2lzOwogICAgICAgIH0KICAgICAgICAu
cGFzdGUtc2VwLWl0ZW06aG92ZXIgeyBiYWNrZ3JvdW5kOiByZ2JhKDkxLDExNSwyMzIsLjA4KTsgfQog
ICAgICAgIC5wYXN0ZS1zZXAtaXRlbTpob3ZlciAucGFzdGUtc2VwLW5hbWUgeyBjb2xvcjogdmFyKC0t
dHh0Mik7IH0KICAgICAgICAucGFzdGUtc2VwLWl0ZW0uc2VsIHsgYmFja2dyb3VuZDogcmdiYSg5MSwx
MTUsMjMyLC4xMik7IH0KICAgICAgICAucGFzdGUtc2VwLWl0ZW0uc2VsIC5wYXN0ZS1zZXAtbmFtZSB7
IGNvbG9yOiB2YXIoLS1hY2MpOyBmb250LXdlaWdodDogNjAwOyB9CiAgICAgICAgLnBhc3RlLXNlcC1m
b290IHsKICAgICAgICAgICAgbWFyZ2luLXRvcDogM3B4OyBwYWRkaW5nLXRvcDogM3B4OwogICAgICAg
ICAgICBib3JkZXItdG9wOiAxcHggc29saWQgcmdiYSgwLDAsMCwuMDUpOwogICAgICAgIH0KICAgICAg
ICAjcGFzdGUtc2VwLWN1c3RvbSB7CiAgICAgICAgICAgIHdpZHRoOiAxMDAlOyBib3gtc2l6aW5nOiBi
b3JkZXItYm94OwogICAgICAgICAgICBoZWlnaHQ6IDIycHg7IHBhZGRpbmc6IDAgN3B4OwogICAgICAg
ICAgICBib3JkZXI6IG5vbmU7IGJvcmRlci1yYWRpdXM6IDVweDsKICAgICAgICAgICAgYmFja2dyb3Vu
ZDogcmdiYSg5MSwxMTUsMjMyLC4wNik7CiAgICAgICAgICAgIGNvbG9yOiB2YXIoLS10eHQyKTsgZm9u
dC1zaXplOiAxMHB4OwogICAgICAgICAgICAtd2Via2l0LWFwcC1yZWdpb246IG5vLWRyYWc7IGFwcC1y
ZWdpb246IG5vLWRyYWc7CiAgICAgICAgfQogICAgICAgICNwYXN0ZS1zZXAtY3VzdG9tOmZvY3VzIHsK
ICAgICAgICAgICAgb3V0bGluZTogbm9uZTsgYmFja2dyb3VuZDogcmdiYSg5MSwxMTUsMjMyLC4xKTsg
Y29sb3I6IHZhcigtLXR4dCk7CiAgICAgICAgfQogICAgICAgICNwYXN0ZS1zZXAtY3VzdG9tOjpwbGFj
ZWhvbGRlciB7IGNvbG9yOiB2YXIoLS10eHQzKTsgfQoKICAgICAgICAuaS1pY28gewogICAgICAgICAg
ICB3aWR0aDogMjhweDsgaGVpZ2h0OiAyOHB4OyBib3JkZXItcmFkaXVzOiB2YXIoLS1yKTsgZGlzcGxh
eTogZmxleDsKICAgICAgICAgICAgYWxpZ24taXRlbXM6IGNlbnRlcjsganVzdGlmeS1jb250ZW50OiBj
ZW50ZXI7IGZsZXgtc2hyaW5rOiAwOwogICAgICAgICAgICBiYWNrZ3JvdW5kOiAjZWRmMmZmOyBjb2xv
cjogdmFyKC0tYWNjKTsKICAgICAgICAgICAgcG9zaXRpb246IHJlbGF0aXZlOyBvdmVyZmxvdzogdmlz
aWJsZTsKICAgICAgICB9CiAgICAgICAgLmktaWNvIHN2ZyB7IHdpZHRoOiAxNnB4OyBoZWlnaHQ6IDE2
cHg7IGRpc3BsYXk6IGJsb2NrOyB9CiAgICAgICAgLmktaWNvLmZ0LWltZyB7IGNvbG9yOiAjN2FkN2Zm
OyB9CiAgICAgICAgLmktaWNvLmZ0LXZpZCB7IGNvbG9yOiAjYzA4NGZjOyB9CiAgICAgICAgLmktaWNv
LmZ0LXppcCB7IGNvbG9yOiAjOGFiNGZmOyB9CiAgICAgICAgLmktaWNvLmZ0LWRpciB7IGNvbG9yOiAj
ZmZkNTZhOyB9CiAgICAgICAgLmktaWNvLmZ0LWFoayB7IGNvbG9yOiAjNmRmZjlhOyB9CiAgICAgICAg
LmktaWNvLm1kIHsgY29sb3I6ICM2YjhjZmY7IH0KICAgICAgICAuaS1pY28ubWQgc3ZnIHsgd2lkdGg6
IDIwcHg7IGhlaWdodDogMjBweDsgfQogICAgICAgIC5pLWljby5mdC1sbmssIC5pLWljby5mdC1kb2Mg
eyBjb2xvcjogI2E5YmRkMDsgfQogICAgICAgIC5pLXVzZWQgewogICAgICAgICAgICBwb3NpdGlvbjog
YWJzb2x1dGU7IHJpZ2h0OiAwOyBib3R0b206IDA7CiAgICAgICAgICAgIHdpZHRoOiAxM3B4OyBoZWln
aHQ6IDEzcHg7IGJvcmRlci1yYWRpdXM6IDUwJTsKICAgICAgICAgICAgYmFja2dyb3VuZDogIzIyYzU1
ZTsgYm9yZGVyOiAxLjVweCBzb2xpZCAjZmZmOwogICAgICAgICAgICBkaXNwbGF5OiBmbGV4OyBhbGln
bi1pdGVtczogY2VudGVyOyBqdXN0aWZ5LWNvbnRlbnQ6IGNlbnRlcjsKICAgICAgICAgICAgcG9pbnRl
ci1ldmVudHM6IG5vbmU7IHotaW5kZXg6IDM7CiAgICAgICAgICAgIGJveC1zaGFkb3c6IDAgMXB4IDJw
eCByZ2JhKDAsMCwwLC4xNik7CiAgICAgICAgICAgIHRyYW5zZm9ybTogdHJhbnNsYXRlKDMwJSwgMzAl
KTsKICAgICAgICB9CiAgICAgICAgLmktdXNlZCBzdmcgeyB3aWR0aDogOXB4OyBoZWlnaHQ6IDlweDsg
Y29sb3I6ICNmZmY7IGRpc3BsYXk6IGJsb2NrOyB9CgogICAgICAgIC5pdG0uanVtcC1mbGFzaCB7CiAg
ICAgICAgICAgIGJveC1zaGFkb3c6IDAgMCAwIDJweCByZ2JhKDkxLDExNSwyMzIsLjU1KSwgMCAycHgg
MTBweCByZ2JhKDkxLDExNSwyMzIsLjIyKTsKICAgICAgICAgICAgYmFja2dyb3VuZDogI2U4ZWRmZjsK
ICAgICAgICAgICAgdHJhbnNpdGlvbjogYmFja2dyb3VuZCAuMzVzIGVhc2UsIGJveC1zaGFkb3cgLjM1
cyBlYXNlOwogICAgICAgIH0KCiAgICAgICAgLmktYm9keSB7IGZsZXg6IDE7IG1pbi13aWR0aDogMDsg
ZGlzcGxheTogZmxleDsgZmxleC1kaXJlY3Rpb246IGNvbHVtbjsgfQogICAgICAgIC5pLXByZXYsIC5p
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
Y2MpOyB9CiAgICAgICAgLnJmLXBhdGggewogICAgICAgICAgICBkaXNwbGF5OiBmbGV4OyBmbGV4LXdy
YXA6IHdyYXA7IGFsaWduLWl0ZW1zOiBjZW50ZXI7CiAgICAgICAgICAgIGdhcDogMDsgcm93LWdhcDog
MnB4OwogICAgICAgICAgICBmb250LXNpemU6IDEzcHg7IGZvbnQtd2VpZ2h0OiA1MDA7IGNvbG9yOiB2
YXIoLS10eHQpOwogICAgICAgICAgICBsaW5lLWhlaWdodDogMS40NTsgd29yZC1icmVhazogbm9ybWFs
OwogICAgICAgIH0KICAgICAgICAucmYtc2VnIHsKICAgICAgICAgICAgY29sb3I6IHZhcigtLWFjYyk7
CiAgICAgICAgICAgIGN1cnNvcjogcG9pbnRlcjsKICAgICAgICAgICAgcGFkZGluZzogMCAxcHg7CiAg
ICAgICAgICAgIGJvcmRlci1yYWRpdXM6IDNweDsKICAgICAgICAgICAgd2hpdGUtc3BhY2U6IG5vd3Jh
cDsKICAgICAgICAgICAgLXdlYmtpdC1hcHAtcmVnaW9uOiBuby1kcmFnOyBhcHAtcmVnaW9uOiBuby1k
cmFnOwogICAgICAgICAgICB0cmFuc2l0aW9uOiBiYWNrZ3JvdW5kIC4xMnMgZWFzZSwgY29sb3IgLjEy
cyBlYXNlOwogICAgICAgIH0KICAgICAgICAucmYtc2VnOmhvdmVyIHsKICAgICAgICAgICAgYmFja2dy
b3VuZDogcmdiYSg5MSwxMTUsMjMyLC4xMik7CiAgICAgICAgICAgIHRleHQtZGVjb3JhdGlvbjogdW5k
ZXJsaW5lOwogICAgICAgIH0KICAgICAgICAucmYtc2VwIHsKICAgICAgICAgICAgY29sb3I6IHZhcigt
LXR4dDMpOwogICAgICAgICAgICBwYWRkaW5nOiAwIDFweDsKICAgICAgICAgICAgdXNlci1zZWxlY3Q6
IG5vbmU7CiAgICAgICAgICAgIGZsZXgtc2hyaW5rOiAwOwogICAgICAgICAgICB3aGl0ZS1zcGFjZTog
bm93cmFwOwogICAgICAgIH0KICAgICAgICAuaS10aHVtYi13cmFwIHsKICAgICAgICAgICAgd2lkdGg6
IDEwMCU7IG1pbi1oZWlnaHQ6IDQ4cHg7IG1heC1oZWlnaHQ6IDE4MHB4OyBtYXJnaW4tYm90dG9tOiA0
cHg7CiAgICAgICAgICAgIGRpc3BsYXk6IGZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGp1c3RpZnkt
Y29udGVudDogY2VudGVyOwogICAgICAgICAgICBiYWNrZ3JvdW5kOiAjZjNmNWY5OyBib3JkZXItcmFk
aXVzOiB2YXIoLS1yKTsgb3ZlcmZsb3c6IGhpZGRlbjsKICAgICAgICB9CiAgICAgICAgLmktdGh1bWIt
d3JhcC53YWl0aW5nIHsKICAgICAgICAgICAgbWluLWhlaWdodDogODhweDsKICAgICAgICAgICAgYmFj
a2dyb3VuZDogbGluZWFyLWdyYWRpZW50KDkwZGVnLCAjZThlYmYyIDAlLCAjZjRmNmZhIDQ1JSwgI2U4
ZWJmMiAxMDAlKTsKICAgICAgICAgICAgYmFja2dyb3VuZC1zaXplOiAyMDAlIDEwMCU7CiAgICAgICAg
ICAgIGFuaW1hdGlvbjogdGh1bWJTaGltbWVyIDEuMDVzIGVhc2UtaW4tb3V0IGluZmluaXRlOwogICAg
ICAgIH0KICAgICAgICBAa2V5ZnJhbWVzIHRodW1iU2hpbW1lciB7CiAgICAgICAgICAgIDAlIHsgYmFj
a2dyb3VuZC1wb3NpdGlvbjogMTAwJSAwOyB9CiAgICAgICAgICAgIDEwMCUgeyBiYWNrZ3JvdW5kLXBv
c2l0aW9uOiAtMTAwJSAwOyB9CiAgICAgICAgfQogICAgICAgIC5pLXRodW1iIHsgbWF4LXdpZHRoOiAx
MDAlOyBtYXgtaGVpZ2h0OiAxODBweDsgd2lkdGg6IGF1dG87IGhlaWdodDogYXV0bzsgb2JqZWN0LWZp
dDogY29udGFpbjsgZGlzcGxheTogYmxvY2s7IH0KICAgICAgICAuaS10aHVtYi50aHVtYi1sb2FkaW5n
IHsgb3BhY2l0eTogMDsgd2lkdGg6IDFweDsgaGVpZ2h0OiAxcHg7IH0KCiAgICAgICAgLyogTWV0YSBi
YXI6IHRpbWUgbGVmdCB8IGV4cGFuZCBjZW50ZXIgfCB0YWdzIHJpZ2h0ICovCiAgICAgICAgLmktbWV0
YSB7CiAgICAgICAgICAgIGRpc3BsYXk6IGdyaWQ7CiAgICAgICAgICAgIGdyaWQtdGVtcGxhdGUtY29s
dW1uczogMWZyIGF1dG8gMWZyOwogICAgICAgICAgICBhbGlnbi1pdGVtczogY2VudGVyOwogICAgICAg
ICAgICBnYXA6IDRweDsKICAgICAgICAgICAgbWFyZ2luLXRvcDogNHB4OwogICAgICAgICAgICB3aWR0
aDogMTAwJTsKICAgICAgICB9CiAgICAgICAgLmktbWV0YSAuaS10aW1lIHsganVzdGlmeS1zZWxmOiBz
dGFydDsgfQogICAgICAgIC5pLW1ldGEtY2VudGVyIHsKICAgICAgICAgICAganVzdGlmeS1zZWxmOiBj
ZW50ZXI7CiAgICAgICAgICAgIGRpc3BsYXk6IGZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGp1c3Rp
ZnktY29udGVudDogY2VudGVyOwogICAgICAgICAgICBnYXA6IDRweDsKICAgICAgICAgICAgbWluLXdp
ZHRoOiAxcHg7IC8qIGtlZXAgY2VudGVyIGNvbHVtbiBldmVuIHdoZW4gZXhwYW5kIGlzIGhpZGRlbiAq
LwogICAgICAgIH0KICAgICAgICAuaS1tZXRhLXJpZ2h0IHsKICAgICAgICAgICAganVzdGlmeS1zZWxm
OiBlbmQ7CiAgICAgICAgICAgIGRpc3BsYXk6IGZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGdhcDog
NXB4OyBmbGV4LXdyYXA6IG5vd3JhcDsKICAgICAgICAgICAganVzdGlmeS1jb250ZW50OiBmbGV4LWVu
ZDsKICAgICAgICAgICAgbWluLXdpZHRoOiAwOwogICAgICAgIH0KICAgICAgICAuaS1tZXRhLXJpZ2h0
LnRleHQtbWV0YSB7CiAgICAgICAgICAgIGZsZXgtd3JhcDogbm93cmFwOwogICAgICAgICAgICBnYXA6
IDRweDsKICAgICAgICB9CiAgICAgICAgLmktc3JjLXRpdGxlIHsKICAgICAgICAgICAgZm9udC1zaXpl
OiAxMHB4OwogICAgICAgICAgICBjb2xvcjogdmFyKC0tdHh0Myk7CiAgICAgICAgICAgIG1heC13aWR0
aDogMTFlbTsKICAgICAgICAgICAgb3ZlcmZsb3c6IGhpZGRlbjsKICAgICAgICAgICAgdGV4dC1vdmVy
ZmxvdzogZWxsaXBzaXM7CiAgICAgICAgICAgIHdoaXRlLXNwYWNlOiBub3dyYXA7CiAgICAgICAgICAg
IG1pbi13aWR0aDogMDsKICAgICAgICAgICAgbGluZS1oZWlnaHQ6IDEuNDsKICAgICAgICB9CiAgICAg
ICAgLmktdGltZSwgLmktdGFnIHsgZm9udC1zaXplOiAxMHB4OyBjb2xvcjogdmFyKC0tdHh0Myk7IH0K
ICAgICAgICAuaS10YWcgewogICAgICAgICAgICBiYWNrZ3JvdW5kOiAjZjFmM2Y4OyBwYWRkaW5nOiAw
IDVweDsgYm9yZGVyLXJhZGl1czogM3B4OwogICAgICAgICAgICB3aGl0ZS1zcGFjZTogbm93cmFwOyBm
bGV4LXNocmluazogMDsgbGluZS1oZWlnaHQ6IDEuNDsKICAgICAgICB9CiAgICAgICAgLmktY2hhcnMg
ewogICAgICAgICAgICBmb250LXNpemU6IDEwcHg7IGNvbG9yOiB2YXIoLS10eHQzKTsKICAgICAgICAg
ICAgYmFja2dyb3VuZDogI2YxZjNmODsgcGFkZGluZzogMCA1cHg7IGJvcmRlci1yYWRpdXM6IDNweDsK
ICAgICAgICAgICAgZm9udC12YXJpYW50LW51bWVyaWM6IHRhYnVsYXItbnVtczsKICAgICAgICAgICAg
d2hpdGUtc3BhY2U6IG5vd3JhcDsKICAgICAgICAgICAgZGlzcGxheTogaW5saW5lLWZsZXg7IGFsaWdu
LWl0ZW1zOiBiYXNlbGluZTsgZ2FwOiAycHg7CiAgICAgICAgfQogICAgICAgIC5pLWNoYXJzIC5uIHsK
ICAgICAgICAgICAgZGlzcGxheTogaW5saW5lLWJsb2NrOwogICAgICAgICAgICBtaW4td2lkdGg6IDRj
aDsKICAgICAgICAgICAgdGV4dC1hbGlnbjogcmlnaHQ7CiAgICAgICAgICAgIGZvbnQtZmFtaWx5OiAn
Q2FzY2FkaWEgTW9ubycsICdDb25zb2xhcycsICdTYXJhc2EgTW9ubyBTQycsIHVpLW1vbm9zcGFjZSwg
bW9ub3NwYWNlOwogICAgICAgICAgICBmb250LXdlaWdodDogNjAwOwogICAgICAgICAgICBjb2xvcjog
dmFyKC0tdHh0Mik7CiAgICAgICAgfQogICAgICAgIC8qIHNyYy10aXRsZS10aXAgKi8KICAgICAgICAu
aS1zcmMtaWNvLCAubWctc3JjIHsgY3Vyc29yOiBwb2ludGVyOyB9CiAgICAgICAgI3NyYy10aXAgewog
ICAgICAgICAgICBwb3NpdGlvbjogZml4ZWQ7IHotaW5kZXg6IDk5OTk5OwogICAgICAgICAgICBtYXgt
d2lkdGg6IG1pbigyODBweCwgY2FsYygxMDB2dyAtIDE2cHgpKTsKICAgICAgICAgICAgcGFkZGluZzog
NnB4IDEwcHg7CiAgICAgICAgICAgIGJvcmRlci1yYWRpdXM6IDhweDsKICAgICAgICAgICAgYmFja2dy
b3VuZDogcmdiYSgzMiwzNiw0OCwuOTIpOyBjb2xvcjogI2ZmZjsKICAgICAgICAgICAgZm9udC1zaXpl
OiAxMnB4OyBsaW5lLWhlaWdodDogMS4zNTsKICAgICAgICAgICAgYm94LXNoYWRvdzogMCA2cHggMThw
eCByZ2JhKDAsMCwwLC4yMik7CiAgICAgICAgICAgIHBvaW50ZXItZXZlbnRzOiBub25lOwogICAgICAg
ICAgICBvcGFjaXR5OiAwOyB0cmFuc2Zvcm06IHRyYW5zbGF0ZVkoNHB4KTsKICAgICAgICAgICAgdHJh
bnNpdGlvbjogb3BhY2l0eSAuMnMgZWFzZSwgdHJhbnNmb3JtIC4yMnMgY3ViaWMtYmV6aWVyKC4yMiwx
LC4zNiwxKTsKICAgICAgICAgICAgd29yZC1icmVhazogYnJlYWstd29yZDsKICAgICAgICB9CiAgICAg
ICAgI3NyYy10aXAuc2hvdyB7IG9wYWNpdHk6IDE7IHRyYW5zZm9ybTogdHJhbnNsYXRlWSgwKTsgfQog
ICAgICAgIC5pLXNyYy1pY28gewogICAgICAgICAgICB3aWR0aDogMTRweDsgaGVpZ2h0OiAxNHB4OyBm
bGV4LXNocmluazogMDsKICAgICAgICAgICAgYm9yZGVyLXJhZGl1czogMnB4OyBvYmplY3QtZml0OiBj
b250YWluOwogICAgICAgICAgICBkaXNwbGF5OiBibG9jazsKICAgICAgICB9CiAgICAgICAgLmktbnVt
IHsKICAgICAgICAgICAgZGlzcGxheTogZmxleDsgZmxleC1kaXJlY3Rpb246IGNvbHVtbjsgYWxpZ24t
aXRlbXM6IGZsZXgtZW5kOwogICAgICAgICAgICBqdXN0aWZ5LWNvbnRlbnQ6IHNwYWNlLWJldHdlZW47
CiAgICAgICAgICAgIGFsaWduLXNlbGY6IHN0cmV0Y2g7CiAgICAgICAgICAgIGZvbnQtc2l6ZTogMTBw
eDsgY29sb3I6IHZhcigtLXR4dDMpOyBtaW4td2lkdGg6IDE2cHg7CiAgICAgICAgICAgIHRleHQtYWxp
Z246IHJpZ2h0OyBmbGV4LXNocmluazogMDsKICAgICAgICAgICAgcGFkZGluZy10b3A6IDJweDsKICAg
ICAgICB9CiAgICAgICAgLmktbnVtIC5pLXNyYy1pY28geyB3aWR0aDogMTZweDsgaGVpZ2h0OiAxNnB4
OyBtYXJnaW4tdG9wOiBhdXRvOyB9CgogICAgICAgIC5pLWV4cGFuZC1idG4gewogICAgICAgICAgICBi
b3JkZXI6IG5vbmU7IGJhY2tncm91bmQ6IG5vbmU7IGN1cnNvcjogcG9pbnRlcjsKICAgICAgICAgICAg
Y29sb3I6IHZhcigtLXR4dDMpOyBmb250LXNpemU6IDEycHg7IHBhZGRpbmc6IDNweCAxMHB4OwogICAg
ICAgICAgICBib3JkZXItcmFkaXVzOiA4cHg7IGRpc3BsYXk6IG5vbmU7IGFsaWduLWl0ZW1zOiBjZW50
ZXI7IGdhcDogNHB4OwogICAgICAgICAgICB0cmFuc2l0aW9uOiBjb2xvciB2YXIoLS10ciksIGJhY2tn
cm91bmQgdmFyKC0tdHIpOwogICAgICAgICAgICAtd2Via2l0LWFwcC1yZWdpb246IG5vLWRyYWc7IGFw
cC1yZWdpb246IG5vLWRyYWc7CiAgICAgICAgICAgIGxpbmUtaGVpZ2h0OiAxLjI7CiAgICAgICAgfQog
ICAgICAgIC5pLWV4cGFuZC1idG4gc3ZnIHsgd2lkdGg6IDE0cHg7IGhlaWdodDogMTRweDsgZmxleC1z
aHJpbms6IDA7IH0KICAgICAgICAuaS1leHBhbmQtYnRuLm9uIHsgZGlzcGxheTogaW5saW5lLWZsZXg7
IH0KICAgICAgICAuaS1leHBhbmQtYnRuOmhvdmVyIHsgY29sb3I6IHZhcigtLWFjYyk7IGJhY2tncm91
bmQ6IHJnYmEoOTEsMTE1LDIzMiwuMDgpOyB9CiAgICAgICAgLmktcHJldi5leHBhbmRlZCwgLmktbmFt
ZS5leHBhbmRlZCB7CiAgICAgICAgICAgIC13ZWJraXQtbGluZS1jbGFtcDogdW5zZXQ7CiAgICAgICAg
ICAgIGRpc3BsYXk6IGJsb2NrOwogICAgICAgICAgICBvdmVyZmxvdzogaGlkZGVuOwogICAgICAgICAg
ICAvKiDpq5jluqbnlLEgSlMg5oyJ5YiX6KGo5Y+v6KeG5Yy66K6+5a6a77ya57qm5Y2g5pW06KGo5bCR
5LiA6KGMICovCiAgICAgICAgfQogICAgICAgIC5pLXNyYy10aXRsZSB7IGRpc3BsYXk6IG5vbmUgIWlt
cG9ydGFudDsgfQogICAgICAgIC5pLWZpbGUtZGV0YWlsIHsKICAgICAgICAgICAgZGlzcGxheTogbm9u
ZTsKICAgICAgICAgICAgbWFyZ2luLXRvcDogNHB4OwogICAgICAgICAgICBwYWRkaW5nOiAwOwogICAg
ICAgICAgICBiYWNrZ3JvdW5kOiBub25lOwogICAgICAgICAgICBib3JkZXI6IG5vbmU7CiAgICAgICAg
fQogICAgICAgIC5pLWZpbGUtZGV0YWlsLm9uIHsgZGlzcGxheTogYmxvY2s7IH0KICAgICAgICAuZmQt
YmxvY2sgewogICAgICAgICAgICBkaXNwbGF5OiBmbGV4OyBmbGV4LWRpcmVjdGlvbjogY29sdW1uOyBn
YXA6IDZweDsKICAgICAgICB9CiAgICAgICAgLmZkLWJsb2NrICsgLmZkLWJsb2NrIHsgbWFyZ2luLXRv
cDogOHB4OyB9CiAgICAgICAgLmZkLXBhdGggewogICAgICAgICAgICB3aWR0aDogMTAwJTsKICAgICAg
ICAgICAgZm9udDogNjAwIDEycHgvMS41NSAnU2Vnb2UgVUkgVmFyaWFibGUgVGV4dCcsJ1NlZ29lIFVJ
JywnTWljcm9zb2Z0IFlhSGVpIFVJJyxzYW5zLXNlcmlmOwogICAgICAgICAgICBjb2xvcjogdmFyKC0t
dHh0Mik7CiAgICAgICAgICAgIGxldHRlci1zcGFjaW5nOiAuMDFlbTsKICAgICAgICAgICAgd29yZC1i
cmVhazogYnJlYWstYWxsOwogICAgICAgICAgICB1c2VyLXNlbGVjdDogdGV4dDsKICAgICAgICAgICAg
LXdlYmtpdC1hcHAtcmVnaW9uOiBuby1kcmFnOyBhcHAtcmVnaW9uOiBuby1kcmFnOwogICAgICAgIH0K
ICAgICAgICAuZmQtcGF0aC5saXZlIHsgY3Vyc29yOiBwb2ludGVyOyB9CiAgICAgICAgLmZkLXBhdGgu
bGl2ZTpob3ZlciB7IGNvbG9yOiB2YXIoLS1hY2MpOyB9CiAgICAgICAgLmZkLXBhdGguZGVhZCB7CiAg
ICAgICAgICAgIGNvbG9yOiAjOWFhMGIwOwogICAgICAgICAgICB0ZXh0LWRlY29yYXRpb246IGxpbmUt
dGhyb3VnaDsKICAgICAgICAgICAgdGV4dC1kZWNvcmF0aW9uLXRoaWNrbmVzczogMnB4OwogICAgICAg
ICAgICB0ZXh0LWRlY29yYXRpb24tY29sb3I6IHJnYmEoMTU0LCAxNjAsIDE3NiwgLjU1KTsKICAgICAg
ICAgICAgdGV4dC1kZWNvcmF0aW9uLXNraXAtaW5rOiBub25lOwogICAgICAgICAgICBjdXJzb3I6IGRl
ZmF1bHQ7CiAgICAgICAgfQogICAgICAgIC5mZC1hY3Rpb25zIHsKICAgICAgICAgICAgZGlzcGxheTog
ZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsganVzdGlmeS1jb250ZW50OiBmbGV4LWVuZDsKICAgICAg
ICAgICAgZ2FwOiA4cHg7IGZsZXgtd3JhcDogd3JhcDsKICAgICAgICB9CiAgICAgICAgLmZkLWJ0biB7
CiAgICAgICAgICAgIGJvcmRlcjogbm9uZTsgYmFja2dyb3VuZDogbm9uZTsgY3Vyc29yOiBwb2ludGVy
OwogICAgICAgICAgICBjb2xvcjogdmFyKC0tdHh0Myk7IGZvbnQtc2l6ZTogMTBweDsgZm9udC13ZWln
aHQ6IDYwMDsKICAgICAgICAgICAgcGFkZGluZzogMXB4IDJweDsgZGlzcGxheTogaW5saW5lLWZsZXg7
IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGdhcDogMnB4OwogICAgICAgICAgICB3aGl0ZS1zcGFjZTogbm93
cmFwOwogICAgICAgICAgICAtd2Via2l0LWFwcC1yZWdpb246IG5vLWRyYWc7IGFwcC1yZWdpb246IG5v
LWRyYWc7CiAgICAgICAgICAgIHRyYW5zaXRpb246IGNvbG9yIHZhcigtLXRyKTsKICAgICAgICB9CiAg
ICAgICAgLmZkLWJ0bjpob3ZlciB7IGNvbG9yOiB2YXIoLS1hY2MpOyB9CiAgICAgICAgLmZkLWJ0bi5v
ayB7IGNvbG9yOiAjMWY3YTU1OyB9CgogICAgICAgIC8qIOKUgOKUgCBDb250ZXh0IG1lbnUg4pSA4pSA
4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA
4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSAICovCiAgICAgICAgI2N0eCB7CiAgICAgICAgICAg
IHBvc2l0aW9uOiBmaXhlZDsgei1pbmRleDogOTk5OTsgbWluLXdpZHRoOiAxMzJweDsgZGlzcGxheTog
bm9uZTsgcGFkZGluZzogNHB4OwogICAgICAgICAgICBiYWNrZ3JvdW5kOiAjZmZmOyBib3JkZXItcmFk
aXVzOiB2YXIoLS1yKTsgYm94LXNoYWRvdzogMCA2cHggMTZweCByZ2JhKDAsMCwwLC4xNCk7CiAgICAg
ICAgICAgIC13ZWJraXQtYXBwLXJlZ2lvbjogbm8tZHJhZzsgYXBwLXJlZ2lvbjogbm8tZHJhZzsKICAg
ICAgICB9CiAgICAgICAgI2N0eC5vbiB7IGRpc3BsYXk6IGJsb2NrOyB9CiAgICAgICAgLmMtaXRlbSB7
CiAgICAgICAgICAgIGRpc3BsYXk6IGZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGdhcDogN3B4OyBw
YWRkaW5nOiA2cHggOXB4OwogICAgICAgICAgICBib3JkZXItcmFkaXVzOiB2YXIoLS1yKTsgY3Vyc29y
OiBwb2ludGVyOyBmb250LXNpemU6IDExcHg7IGNvbG9yOiB2YXIoLS10eHQpOwogICAgICAgIH0KICAg
ICAgICAuYy1pdGVtOmhvdmVyIHsgYmFja2dyb3VuZDogI2YyZjRmOTsgfQogICAgICAgIC5jLWl0ZW0u
ZGFuZ2VyIHsgY29sb3I6ICNmZjdiOWM7IH0KICAgICAgICAuYy1zZXAgeyBoZWlnaHQ6IDFweDsgYmFj
a2dyb3VuZDogI2VjZWZmNTsgbWFyZ2luOiAzcHggMDsgfQogICAgICAgIC5jLWljbyB7IHdpZHRoOiAx
NHB4OyB0ZXh0LWFsaWduOiBjZW50ZXI7IH0KCiAgICAgICAgLyog4pSA4pSAIENsZWFyIGNvbmZpcm0g
4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA
4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSAICovCiAgICAgICAgI2Nsci1kbGcgewogICAg
ICAgICAgICBkaXNwbGF5OiBub25lOyBwb3NpdGlvbjogZml4ZWQ7IGluc2V0OiAwOyB6LWluZGV4OiAx
MDAwMDsKICAgICAgICAgICAgYmFja2dyb3VuZDogcmdiYSgyMCwgMjIsIDM1LCAuNDIpOwogICAgICAg
ICAgICBhbGlnbi1pdGVtczogY2VudGVyOyBqdXN0aWZ5LWNvbnRlbnQ6IGNlbnRlcjsKICAgICAgICAg
ICAgLXdlYmtpdC1hcHAtcmVnaW9uOiBuby1kcmFnOyBhcHAtcmVnaW9uOiBuby1kcmFnOwogICAgICAg
IH0KICAgICAgICAjY2xyLWRsZy5vbiB7IGRpc3BsYXk6IGZsZXg7IH0KICAgICAgICAuY2xyLWJveCB7
CiAgICAgICAgICAgIHdpZHRoOiBtaW4oMjgwcHgsIGNhbGMoMTAwJSAtIDMycHgpKTsKICAgICAgICAg
ICAgYmFja2dyb3VuZDogI2ZmZjsgYm9yZGVyLXJhZGl1czogMTJweDsKICAgICAgICAgICAgYm94LXNo
YWRvdzogMCAxMnB4IDMycHggcmdiYSgwLDAsMCwuMTgpOwogICAgICAgICAgICBwYWRkaW5nOiAxNnB4
IDE2cHggMTRweDsgY29sb3I6IHZhcigtLXR4dCk7CiAgICAgICAgfQogICAgICAgIC5jbHItdGl0bGUg
eyBmb250LXNpemU6IDE0cHg7IGZvbnQtd2VpZ2h0OiA3MDA7IG1hcmdpbi1ib3R0b206IDZweDsgfQog
ICAgICAgIC5jbHItZGVzYyB7IGZvbnQtc2l6ZTogMTFweDsgY29sb3I6IHZhcigtLXR4dDMpOyBsaW5l
LWhlaWdodDogMS41OyBtYXJnaW4tYm90dG9tOiAxMnB4OyB9CiAgICAgICAgLmNsci1jaGVjayB7CiAg
ICAgICAgICAgIGRpc3BsYXk6IGZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGdhcDogN3B4OwogICAg
ICAgICAgICBmb250LXNpemU6IDEycHg7IGNvbG9yOiB2YXIoLS10eHQpOyBjdXJzb3I6IHBvaW50ZXI7
CiAgICAgICAgICAgIHVzZXItc2VsZWN0OiBub25lOyBtYXJnaW4tYm90dG9tOiAxNHB4OwogICAgICAg
IH0KICAgICAgICAuY2xyLWNoZWNrIGlucHV0IHsKICAgICAgICAgICAgd2lkdGg6IDE0cHg7IGhlaWdo
dDogMTRweDsgYWNjZW50LWNvbG9yOiB2YXIoLS1hY2MpOyBjdXJzb3I6IHBvaW50ZXI7CiAgICAgICAg
fQogICAgICAgIC5jbHItYnRucyB7IGRpc3BsYXk6IGZsZXg7IGdhcDogOHB4OyBqdXN0aWZ5LWNvbnRl
bnQ6IGZsZXgtZW5kOyB9CiAgICAgICAgLmNsci1idG5zIGJ1dHRvbiB7CiAgICAgICAgICAgIGJvcmRl
cjogbm9uZTsgYm9yZGVyLXJhZGl1czogOHB4OyBwYWRkaW5nOiA3cHggMTRweDsKICAgICAgICAgICAg
Zm9udC1zaXplOiAxMnB4OyBjdXJzb3I6IHBvaW50ZXI7IGZvbnQtd2VpZ2h0OiA2MDA7CiAgICAgICAg
ICAgIHRyYW5zaXRpb246IGJhY2tncm91bmQgdmFyKC0tdHIpLCBjb2xvciB2YXIoLS10cik7CiAgICAg
ICAgfQogICAgICAgICNjbHItY2FuY2VsIHsgYmFja2dyb3VuZDogI2YxZjNmODsgY29sb3I6IHZhcigt
LXR4dDIpOyB9CiAgICAgICAgI2Nsci1jYW5jZWw6aG92ZXIgeyBiYWNrZ3JvdW5kOiAjZTZlOWYyOyB9
CiAgICAgICAgI2Nsci1vayB7IGJhY2tncm91bmQ6IHJnYmEoMjU1LDEyMywxNTYsLjE0KTsgY29sb3I6
ICNlODVhN2E7IH0KICAgICAgICAjY2xyLW9rOmhvdmVyIHsgYmFja2dyb3VuZDogcmdiYSgyNTUsMTIz
LDE1NiwuMjQpOyB9CgogICAgICAgIC8qIOKUgOKUgCBGaWxlIHBhdGggdGlwIOKUgOKUgOKUgOKUgOKU
gOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKU
gOKUgOKUgOKUgOKUgOKUgOKUgCAqLwogICAgICAgICNwYXRoLXRpcCB7CiAgICAgICAgICAgIGRpc3Bs
YXk6IG5vbmU7IHBvc2l0aW9uOiBmaXhlZDsgei1pbmRleDogMTAwMDE7CiAgICAgICAgICAgIHdpZHRo
OiBtaW4oMzIwcHgsIGNhbGMoMTAwdncgLSAxNnB4KSk7CiAgICAgICAgICAgIG1heC1oZWlnaHQ6IG1p
bigyODBweCwgY2FsYygxMDB2aCAtIDI0cHgpKTsKICAgICAgICAgICAgb3ZlcmZsb3c6IGF1dG87CiAg
ICAgICAgICAgIHBhZGRpbmc6IDA7CiAgICAgICAgICAgIGJhY2tncm91bmQ6IGxpbmVhci1ncmFkaWVu
dCgxNjVkZWcsICNmZmZmZmYgMCUsICNmNmY4ZmMgMTAwJSk7CiAgICAgICAgICAgIGJvcmRlcjogMXB4
IHNvbGlkIHJnYmEoNzAsIDg0LCAxMjAsIC4xKTsKICAgICAgICAgICAgYm9yZGVyLXJhZGl1czogMTJw
eDsKICAgICAgICAgICAgYm94LXNoYWRvdzoKICAgICAgICAgICAgICAgIDAgNHB4IDZweCByZ2JhKDMw
LCA0MCwgNzAsIC4wNCksCiAgICAgICAgICAgICAgICAwIDE0cHggMzZweCByZ2JhKDMwLCA0MCwgNzAs
IC4xNik7CiAgICAgICAgICAgIGNvbG9yOiB2YXIoLS10eHQpOwogICAgICAgICAgICBwb2ludGVyLWV2
ZW50czogYXV0bzsKICAgICAgICAgICAgb3BhY2l0eTogMDsKICAgICAgICAgICAgdHJhbnNmb3JtOiB0
cmFuc2xhdGVZKDRweCkgc2NhbGUoLjk4KTsKICAgICAgICAgICAgdHJhbnNpdGlvbjogb3BhY2l0eSAu
MTRzIGVhc2UsIHRyYW5zZm9ybSAuMTRzIGVhc2U7CiAgICAgICAgICAgIC13ZWJraXQtYXBwLXJlZ2lv
bjogbm8tZHJhZzsgYXBwLXJlZ2lvbjogbm8tZHJhZzsKICAgICAgICB9CiAgICAgICAgI3BhdGgtdGlw
Lm9uIHsKICAgICAgICAgICAgZGlzcGxheTogYmxvY2s7CiAgICAgICAgICAgIG9wYWNpdHk6IDE7CiAg
ICAgICAgICAgIHRyYW5zZm9ybTogdHJhbnNsYXRlWSgwKSBzY2FsZSgxKTsKICAgICAgICB9CiAgICAg
ICAgLnB0LWhlYWQgewogICAgICAgICAgICBkaXNwbGF5OiBmbGV4OyBhbGlnbi1pdGVtczogY2VudGVy
OyBqdXN0aWZ5LWNvbnRlbnQ6IHNwYWNlLWJldHdlZW47CiAgICAgICAgICAgIGdhcDogMTBweDsgcGFk
ZGluZzogMTBweCAxMnB4IDhweDsKICAgICAgICAgICAgYm9yZGVyLWJvdHRvbTogMXB4IHNvbGlkIHJn
YmEoNzAsIDg0LCAxMjAsIC4wNyk7CiAgICAgICAgfQogICAgICAgIC5wdC10aXRsZSB7CiAgICAgICAg
ICAgIGZvbnQtc2l6ZTogMTFweDsgZm9udC13ZWlnaHQ6IDcwMDsgbGV0dGVyLXNwYWNpbmc6IC4wNGVt
OwogICAgICAgICAgICBjb2xvcjogdmFyKC0tdHh0Mik7IHRleHQtdHJhbnNmb3JtOiB1cHBlcmNhc2U7
CiAgICAgICAgICAgIGZsZXgtc2hyaW5rOiAwOwogICAgICAgIH0KICAgICAgICAucHQtaGVhZC1idG4g
ewogICAgICAgICAgICBmbGV4LXNocmluazogMDsgbWFyZ2luLWxlZnQ6IGF1dG87CiAgICAgICAgICAg
IGhlaWdodDogMjJweDsgcGFkZGluZzogMCA4cHg7IGRpc3BsYXk6IGlubGluZS1mbGV4OyBhbGlnbi1p
dGVtczogY2VudGVyOyBnYXA6IDRweDsKICAgICAgICAgICAgYm9yZGVyOiAxcHggc29saWQgcmdiYSgx
MDcsMTEyLDEyOCwuMjIpOyBib3JkZXItcmFkaXVzOiA2cHg7IGN1cnNvcjogcG9pbnRlcjsKICAgICAg
ICAgICAgYmFja2dyb3VuZDogcmdiYSgxMDcsMTEyLDEyOCwuMDYpOyBjb2xvcjogIzhhOTBhMDsgZm9u
dC1zaXplOiAxMXB4OyBmb250LXdlaWdodDogNjAwOwogICAgICAgICAgICB3aGl0ZS1zcGFjZTogbm93
cmFwOwogICAgICAgICAgICAtd2Via2l0LWFwcC1yZWdpb246IG5vLWRyYWc7IGFwcC1yZWdpb246IG5v
LWRyYWc7CiAgICAgICAgICAgIHRyYW5zaXRpb246IGJhY2tncm91bmQgdmFyKC0tdHIpLCBjb2xvciB2
YXIoLS10ciksIGJvcmRlci1jb2xvciB2YXIoLS10cik7CiAgICAgICAgfQogICAgICAgIC5wdC1oZWFk
LWJ0bjpob3ZlciB7CiAgICAgICAgICAgIGJhY2tncm91bmQ6IHJnYmEoMTA3LDExMiwxMjgsLjEyKTsg
Y29sb3I6IHZhcigtLXR4dDIpOwogICAgICAgICAgICBib3JkZXItY29sb3I6IHJnYmEoMTA3LDExMiwx
MjgsLjQpOwogICAgICAgIH0KICAgICAgICAucHQtbGlzdCB7IHBhZGRpbmc6IDZweCA4cHggOHB4OyBk
aXNwbGF5OiBmbGV4OyBmbGV4LWRpcmVjdGlvbjogY29sdW1uOyBnYXA6IDRweDsgfQogICAgICAgIC5w
dC1yb3cgewogICAgICAgICAgICBkaXNwbGF5OiBncmlkOyBncmlkLXRlbXBsYXRlLWNvbHVtbnM6IDhw
eCAxZnI7IGdhcDogOHB4OwogICAgICAgICAgICBwYWRkaW5nOiA4cHggOHB4OyBib3JkZXItcmFkaXVz
OiA4cHg7CiAgICAgICAgICAgIGJhY2tncm91bmQ6IHJnYmEoMjU1LDI1NSwyNTUsLjcpOwogICAgICAg
IH0KICAgICAgICAucHQtcm93LmRlYWQgeyBiYWNrZ3JvdW5kOiByZ2JhKDI1NSwgMTIzLCAxNTYsIC4w
Nik7IH0KICAgICAgICAucHQtZG90IHsKICAgICAgICAgICAgd2lkdGg6IDhweDsgaGVpZ2h0OiA4cHg7
IGJvcmRlci1yYWRpdXM6IDUwJTsgbWFyZ2luLXRvcDogNXB4OwogICAgICAgICAgICBiYWNrZ3JvdW5k
OiAjMmViNDc4OyBib3gtc2hhZG93OiAwIDAgMCAzcHggcmdiYSg0NiwgMTgwLCAxMjAsIC4xOCk7CiAg
ICAgICAgfQogICAgICAgIC5wdC1yb3cuZGVhZCAucHQtZG90IHsKICAgICAgICAgICAgYmFja2dyb3Vu
ZDogI2U4NWE3YTsgYm94LXNoYWRvdzogMCAwIDAgM3B4IHJnYmEoMjMyLCA5MCwgMTIyLCAuMTYpOwog
ICAgICAgIH0KICAgICAgICAucHQtbmFtZSB7CiAgICAgICAgICAgIGZvbnQtc2l6ZTogMTJweDsgZm9u
dC13ZWlnaHQ6IDY1MDsgY29sb3I6IHZhcigtLXR4dCk7CiAgICAgICAgICAgIGxpbmUtaGVpZ2h0OiAx
LjM7IHdvcmQtYnJlYWs6IGJyZWFrLWFsbDsKICAgICAgICB9CiAgICAgICAgLnB0LXBhdGggewogICAg
ICAgICAgICBtYXJnaW4tdG9wOiAzcHg7CiAgICAgICAgICAgIGZvbnQ6IDEwLjVweC8xLjQ1ICdDYXNj
YWRpYSBNb25vJywnQ29uc29sYXMnLCdNaWNyb3NvZnQgWWFIZWkgVUknLG1vbm9zcGFjZTsKICAgICAg
ICAgICAgY29sb3I6IHZhcigtLXR4dDIpOyB3b3JkLWJyZWFrOiBicmVhay1hbGw7CiAgICAgICAgICAg
IHVzZXItc2VsZWN0OiB0ZXh0OwogICAgICAgIH0KICAgICAgICAucHQtcGF0aC5saXZlIHsKICAgICAg
ICAgICAgY29sb3I6IHZhcigtLWFjYyk7IGN1cnNvcjogcG9pbnRlcjsKICAgICAgICB9CiAgICAgICAg
LnB0LXBhdGgubGl2ZTpob3ZlciB7IHRleHQtZGVjb3JhdGlvbjogdW5kZXJsaW5lOyB9CiAgICAgICAg
LnB0LXBhdGguZGVhZCB7CiAgICAgICAgICAgIGNvbG9yOiAjYzQzZDVjOwogICAgICAgICAgICB0ZXh0
LWRlY29yYXRpb246IGxpbmUtdGhyb3VnaDsKICAgICAgICAgICAgdGV4dC1kZWNvcmF0aW9uLXRoaWNr
bmVzczogMnB4OwogICAgICAgICAgICB0ZXh0LWRlY29yYXRpb24tY29sb3I6ICNlMTFkNDg7CiAgICAg
ICAgICAgIGN1cnNvcjogZGVmYXVsdDsKICAgICAgICB9CiAgICAgICAgLnB0LWFjdGlvbnMgewogICAg
ICAgICAgICBtYXJnaW4tdG9wOiA2cHg7CiAgICAgICAgICAgIGRpc3BsYXk6IGZsZXg7IGFsaWduLWl0
ZW1zOiBjZW50ZXI7IGdhcDogNnB4OyBmbGV4LXdyYXA6IHdyYXA7CiAgICAgICAgfQogICAgICAgIC5w
dC1jb3B5LWJ0biB7CiAgICAgICAgICAgIGhlaWdodDogMjJweDsgcGFkZGluZzogMCA4cHg7IGRpc3Bs
YXk6IGlubGluZS1mbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOwogICAgICAgICAgICBib3JkZXI6IDFw
eCBzb2xpZCByZ2JhKDEwNywxMTIsMTI4LC4yMik7IGJvcmRlci1yYWRpdXM6IDZweDsgY3Vyc29yOiBw
b2ludGVyOwogICAgICAgICAgICBiYWNrZ3JvdW5kOiByZ2JhKDEwNywxMTIsMTI4LC4wNik7IGNvbG9y
OiAjOGE5MGEwOyBmb250LXNpemU6IDExcHg7IGZvbnQtd2VpZ2h0OiA2MDA7CiAgICAgICAgICAgIC13
ZWJraXQtYXBwLXJlZ2lvbjogbm8tZHJhZzsgYXBwLXJlZ2lvbjogbm8tZHJhZzsKICAgICAgICAgICAg
dHJhbnNpdGlvbjogYmFja2dyb3VuZCB2YXIoLS10ciksIGNvbG9yIHZhcigtLXRyKSwgYm9yZGVyLWNv
bG9yIHZhcigtLXRyKTsKICAgICAgICB9CiAgICAgICAgLnB0LWNvcHktYnRuOmhvdmVyIHsKICAgICAg
ICAgICAgYmFja2dyb3VuZDogcmdiYSgxMDcsMTEyLDEyOCwuMTIpOyBjb2xvcjogdmFyKC0tdHh0Mik7
CiAgICAgICAgICAgIGJvcmRlci1jb2xvcjogcmdiYSgxMDcsMTEyLDEyOCwuNCk7CiAgICAgICAgfQog
ICAgICAgIC5wdC1jb3B5LWJ0bi5vayB7CiAgICAgICAgICAgIGNvbG9yOiAjMWY3YTU1OyBib3JkZXIt
Y29sb3I6IHJnYmEoNDYsIDE4MCwgMTIwLCAuMzUpOwogICAgICAgICAgICBiYWNrZ3JvdW5kOiByZ2Jh
KDQ2LCAxODAsIDEyMCwgLjEpOwogICAgICAgIH0KICAgICAgICAuaXRtLml0LWdyb3VwIHsKICAgICAg
ICAgICAgZmxleC1kaXJlY3Rpb246IGNvbHVtbjsKICAgICAgICAgICAgYWxpZ24taXRlbXM6IHN0cmV0
Y2g7CiAgICAgICAgICAgIGdhcDogMDsKICAgICAgICAgICAgcGFkZGluZzogNnB4IDhweCA0cHg7CiAg
ICAgICAgICAgIGN1cnNvcjogZGVmYXVsdDsKICAgICAgICB9CiAgICAgICAgLml0bS5pdC1ncm91cDpo
b3ZlciB7IGJhY2tncm91bmQ6IHZhcigtLWNhcmQpOyB9CiAgICAgICAgLm1nLWhlYWQgewogICAgICAg
ICAgICBkaXNwbGF5OiBmbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBnYXA6IDZweDsKICAgICAgICAg
ICAgZm9udC1zaXplOiAxMXB4OyBjb2xvcjogdmFyKC0tdHh0Myk7IGZvbnQtd2VpZ2h0OiA2MDA7CiAg
ICAgICAgICAgIHBhZGRpbmc6IDJweCAycHggNnB4OyB1c2VyLXNlbGVjdDogbm9uZTsKICAgICAgICB9
CiAgICAgICAgLm1nLWhlYWQgLm1nLXRhZyB7CiAgICAgICAgICAgIGRpc3BsYXk6IGlubGluZS1mbGV4
OyBhbGlnbi1pdGVtczogY2VudGVyOwogICAgICAgICAgICBoZWlnaHQ6IDE2cHg7IHBhZGRpbmc6IDAg
NnB4OyBib3JkZXItcmFkaXVzOiA4cHg7CiAgICAgICAgICAgIGJhY2tncm91bmQ6IHJnYmEoOTEsMTE1
LDIzMiwuMTIpOyBjb2xvcjogdmFyKC0tYWNjKTsgZm9udC1zaXplOiAxMHB4OwogICAgICAgIH0KICAg
ICAgICAubWctcm93IHsKICAgICAgICAgICAgcGFkZGluZzogN3B4IDZweDsgbWFyZ2luLWJvdHRvbTog
M3B4OwogICAgICAgICAgICBib3JkZXItcmFkaXVzOiA1cHg7IGN1cnNvcjogcG9pbnRlcjsKICAgICAg
ICAgICAgYm9yZGVyOiAxcHggc29saWQgdHJhbnNwYXJlbnQ7CiAgICAgICAgICAgIHRyYW5zaXRpb246
IGJhY2tncm91bmQgLjEycyBlYXNlLCBib3JkZXItY29sb3IgLjEycyBlYXNlOwogICAgICAgIH0KICAg
ICAgICAubWctcm93OmhvdmVyIHsgYmFja2dyb3VuZDogdmFyKC0tY2FyZC1oKTsgfQogICAgICAgIC5t
Zy1yb3cuc2VsIHsKICAgICAgICAgICAgYmFja2dyb3VuZDogI2VkZjFmZjsKICAgICAgICAgICAgYm9y
ZGVyLWNvbG9yOiByZ2JhKDkxLDExNSwyMzIsLjM1KTsKICAgICAgICAgICAgYm94LXNoYWRvdzogMCAw
IDAgMXB4IHJnYmEoOTEsMTE1LDIzMiwuMjUpOwogICAgICAgIH0KICAgICAgICAubWctcm93Lm11bHRp
IHsKICAgICAgICAgICAgYmFja2dyb3VuZDogI2VlZjJmZjsKICAgICAgICAgICAgYm9yZGVyLWNvbG9y
OiByZ2JhKDkxLDExNSwyMzIsLjQ1KTsKICAgICAgICB9CiAgICAgICAgLm1nLXRpdGxlIHsKICAgICAg
ICAgICAgZm9udC1zaXplOiAxM3B4OyBmb250LXdlaWdodDogNjAwOyBjb2xvcjogdmFyKC0tYWNjKTsK
ICAgICAgICAgICAgbWFyZ2luLWJvdHRvbTogMnB4OyBsaW5lLWhlaWdodDogMS4zNTsKICAgICAgICAg
ICAgZGlzcGxheTogLXdlYmtpdC1ib3g7IC13ZWJraXQtYm94LW9yaWVudDogdmVydGljYWw7IC13ZWJr
aXQtbGluZS1jbGFtcDogMjsKICAgICAgICAgICAgb3ZlcmZsb3c6IGhpZGRlbjsgd29yZC1icmVhazog
YnJlYWstd29yZDsKICAgICAgICB9CiAgICAgICAgLm1nLWJvZHkgewogICAgICAgICAgICBmb250LXNp
emU6IDEyLjVweDsgZm9udC13ZWlnaHQ6IDUwMDsgY29sb3I6IHZhcigtLXR4dCk7CiAgICAgICAgICAg
IHdoaXRlLXNwYWNlOiBwcmUtd3JhcDsgd29yZC1icmVhazogYnJlYWstYWxsOwogICAgICAgICAgICBk
aXNwbGF5OiAtd2Via2l0LWJveDsgLXdlYmtpdC1ib3gtb3JpZW50OiB2ZXJ0aWNhbDsgLXdlYmtpdC1s
aW5lLWNsYW1wOiA0OwogICAgICAgICAgICBvdmVyZmxvdzogaGlkZGVuOyBsaW5lLWhlaWdodDogMS40
OwogICAgICAgIH0KICAgICAgICAubWctYm9keS5pbWcgeyBjb2xvcjogdmFyKC0tdHh0Mik7IH0KICAg
ICAgICAubWctcm93LXRvcCB7CiAgICAgICAgICAgIGRpc3BsYXk6IGZsZXg7IGFsaWduLWl0ZW1zOiBm
bGV4LXN0YXJ0OyBnYXA6IDhweDsKICAgICAgICB9CiAgICAgICAgLm1nLXJvdy1tYWluIHsgZmxleDog
MTsgbWluLXdpZHRoOiAwOyB9CiAgICAgICAgLm1nLXNyYyB7CiAgICAgICAgICAgIHdpZHRoOiAxOHB4
OyBoZWlnaHQ6IDE4cHg7IGZsZXgtc2hyaW5rOiAwOyBtYXJnaW4tdG9wOiAycHg7CiAgICAgICAgICAg
IGJvcmRlci1yYWRpdXM6IDNweDsgb2JqZWN0LWZpdDogY29udGFpbjsKICAgICAgICAgICAgYmFja2dy
b3VuZDogcmdiYSgwLDAsMCwuMDQpOwogICAgICAgIH0KICAgICAgICAuaS1mYXYtdGl0bGUgewogICAg
ICAgICAgICBmb250LXNpemU6IDEzcHg7IGZvbnQtd2VpZ2h0OiA2MDA7IGNvbG9yOiB2YXIoLS1hY2Mp
OwogICAgICAgICAgICBtYXJnaW46IDAgMCAzcHg7IGxpbmUtaGVpZ2h0OiAxLjM1OwogICAgICAgICAg
ICBkaXNwbGF5OiAtd2Via2l0LWJveDsgLXdlYmtpdC1ib3gtb3JpZW50OiB2ZXJ0aWNhbDsgLXdlYmtp
dC1saW5lLWNsYW1wOiAyOwogICAgICAgICAgICBvdmVyZmxvdzogaGlkZGVuOyB3b3JkLWJyZWFrOiBi
cmVhay13b3JkOwogICAgICAgIH0KICAgICAgICAjdGl0bGUtZGxnIHsKICAgICAgICAgICAgZGlzcGxh
eTogbm9uZTsgcG9zaXRpb246IGZpeGVkOyBpbnNldDogMDsgei1pbmRleDogMTAwOwogICAgICAgICAg
ICBiYWNrZ3JvdW5kOiByZ2JhKDE1LDE4LDI4LC4zNSk7CiAgICAgICAgICAgIGFsaWduLWl0ZW1zOiBj
ZW50ZXI7IGp1c3RpZnktY29udGVudDogY2VudGVyOwogICAgICAgIH0KICAgICAgICAjdGl0bGUtZGxn
Lm9uIHsgZGlzcGxheTogZmxleDsgfQogICAgICAgICN0aXRsZS1kbGcgLnRpdGxlLWJveCB7CiAgICAg
ICAgICAgIHdpZHRoOiAyNjBweDsgcGFkZGluZzogMTZweCAxNnB4IDEycHg7CiAgICAgICAgICAgIGJh
Y2tncm91bmQ6IHZhcigtLWNhcmQpOyBib3JkZXItcmFkaXVzOiAxMHB4OwogICAgICAgICAgICBib3gt
c2hhZG93OiAwIDhweCAyOHB4IHJnYmEoMCwwLDAsLjE4KTsKICAgICAgICB9CiAgICAgICAgI3RpdGxl
LWlucHV0IHsKICAgICAgICAgICAgd2lkdGg6IDEwMCU7IGJveC1zaXppbmc6IGJvcmRlci1ib3g7IG1h
cmdpbjogOHB4IDAgMTJweDsKICAgICAgICAgICAgaGVpZ2h0OiAzMnB4OyBwYWRkaW5nOiAwIDEwcHg7
IGJvcmRlci1yYWRpdXM6IDZweDsKICAgICAgICAgICAgYm9yZGVyOiAxcHggc29saWQgI2Q1ZGFlNjsg
YmFja2dyb3VuZDogI2ZmZjsgY29sb3I6IHZhcigtLXR4dCk7CiAgICAgICAgICAgIGZvbnQtc2l6ZTog
MTNweDsgb3V0bGluZTogbm9uZTsKICAgICAgICB9CiAgICAgICAgI3RpdGxlLWlucHV0OmZvY3VzIHsg
Ym9yZGVyLWNvbG9yOiB2YXIoLS1hY2MpOyB9CgogICAgCiAgICAgICAgLyogdWktZ3JheS1iZy12MSAq
LwogICAgICAgIDpyb290IHsKICAgICAgICAgICAgLS1iZzogI2U0ZTdlZSAhaW1wb3J0YW50OwogICAg
ICAgIH0KICAgICAgICBodG1sLCBib2R5IHsKICAgICAgICAgICAgYmFja2dyb3VuZDogI2U0ZTdlZSAh
aW1wb3J0YW50OwogICAgICAgIH0KICAgICAgICAjYXBwIHsKICAgICAgICAgICAgYmFja2dyb3VuZDog
bGluZWFyLWdyYWRpZW50KDE4MGRlZywgI2U5ZWNmMyAwJSwgI2UwZTRlYyAxMDAlKSAhaW1wb3J0YW50
OwogICAgICAgIH0KICAgICAgICAjaGRyIHsKICAgICAgICAgICAgYmFja2dyb3VuZDogI2UyZTZlZSAh
aW1wb3J0YW50OwogICAgICAgIH0KICAgICAgICAjdGFicyB7CiAgICAgICAgICAgIGJhY2tncm91bmQ6
ICNlMmU2ZWUgIWltcG9ydGFudDsKICAgICAgICB9CiAgICAgICAgI2xpc3QsICNlbXB0eSwgI3NrZWws
ICNoZHItZ3JvdywgI3NlYXJjaC13cmFwIHsKICAgICAgICAgICAgYmFja2dyb3VuZDogdHJhbnNwYXJl
bnQgIWltcG9ydGFudDsKICAgICAgICB9CiAgICAgICAgI3NlYXJjaC1ib3ggewogICAgICAgICAgICB0
cmFuc2Zvcm0tb3JpZ2luOiByaWdodCBjZW50ZXI7CiAgICAgICAgICAgIGJhY2tncm91bmQ6IHRyYW5z
cGFyZW50ICFpbXBvcnRhbnQ7CiAgICAgICAgfQogICAgICAgIC5pdG0sIC5tZywgLm1nLXJvdywgLm1l
cmdlLWdyb3VwIHsKICAgICAgICAgICAgYmFja2dyb3VuZDogI2ZmZmZmZiAhaW1wb3J0YW50OwogICAg
ICAgIH0KICAgICAgICAuaXRtOmhvdmVyIHsKICAgICAgICAgICAgYmFja2dyb3VuZDogI2Y4ZjlmYyAh
aW1wb3J0YW50OwogICAgICAgIH0KICAgIAogICAgICAgIC8qIHNlbC10aW50LWJsdWUtdjEgKi8KICAg
ICAgICAuaXRtLnNlbCwKICAgICAgICAubWctcm93LnNlbCwKICAgICAgICAuaXRtLm11bHRpLAogICAg
ICAgIC5tZy1yb3cubXVsdGksCiAgICAgICAgLml0bS5tdWx0aS5zZWwsCiAgICAgICAgLml0LWdyb3Vw
LnNlbCwKICAgICAgICAuaXQtZ3JvdXAubXVsdGkgewogICAgICAgICAgICBiYWNrZ3JvdW5kOiAjZThl
ZmZmICFpbXBvcnRhbnQ7CiAgICAgICAgfQogICAgICAgIC5pdG0uc2VsOmhvdmVyLAogICAgICAgIC5p
dG0ubXVsdGk6aG92ZXIsCiAgICAgICAgLm1nLXJvdy5zZWw6aG92ZXIsCiAgICAgICAgLm1nLXJvdy5t
dWx0aTpob3ZlciB7CiAgICAgICAgICAgIGJhY2tncm91bmQ6ICNkZGU2ZmYgIWltcG9ydGFudDsKICAg
ICAgICB9CiAgICAKICAgICAgICAvKiBob3Zlci1ncmVlbi1yaXNlLXYyICovCiAgICAgICAgLyogaG92
ZXItYWNjZW50LXJpc2UtdjMgKi8KICAgICAgICAuaXRtIHsgcG9zaXRpb246IHJlbGF0aXZlICFpbXBv
cnRhbnQ7IG92ZXJmbG93OiBoaWRkZW4gIWltcG9ydGFudDsgfQogICAgICAgIC5pdG06OmJlZm9yZSB7
CiAgICAgICAgICAgIGNvbnRlbnQ6ICIiICFpbXBvcnRhbnQ7CiAgICAgICAgICAgIHBvc2l0aW9uOiBh
YnNvbHV0ZSAhaW1wb3J0YW50OwogICAgICAgICAgICBsZWZ0OiAwICFpbXBvcnRhbnQ7IHJpZ2h0OiAw
ICFpbXBvcnRhbnQ7IGJvdHRvbTogMCAhaW1wb3J0YW50OwogICAgICAgICAgICBoZWlnaHQ6IDAgIWlt
cG9ydGFudDsKICAgICAgICAgICAgcG9pbnRlci1ldmVudHM6IG5vbmUgIWltcG9ydGFudDsKICAgICAg
ICAgICAgei1pbmRleDogMCAhaW1wb3J0YW50OwogICAgICAgICAgICBib3JkZXItcmFkaXVzOiAwIDAg
dmFyKC0tciwgNHB4KSB2YXIoLS1yLCA0cHgpICFpbXBvcnRhbnQ7CiAgICAgICAgICAgIGJhY2tncm91
bmQ6IGxpbmVhci1ncmFkaWVudCh0byB0b3AsCiAgICAgICAgICAgICAgICByZ2JhKDkxLCAxMTUsIDIz
MiwgLjMyKSAwJSwKICAgICAgICAgICAgICAgIHJnYmEoOTEsIDExNSwgMjMyLCAuMTIpIDU1JSwKICAg
ICAgICAgICAgICAgIHJnYmEoOTEsIDExNSwgMjMyLCAwKSAxMDAlKSAhaW1wb3J0YW50OwogICAgICAg
ICAgICB0cmFuc2l0aW9uOiBoZWlnaHQgLjM0cyBjdWJpYy1iZXppZXIoLjIyLCAxLCAuMzYsIDEpICFp
bXBvcnRhbnQ7CiAgICAgICAgfQogICAgICAgIC5pdG06aG92ZXI6OmJlZm9yZSB7IGhlaWdodDogMzMu
MzMzJSAhaW1wb3J0YW50OyB9CiAgICAgICAgLml0bTo6YWZ0ZXIgewogICAgICAgICAgICBjb250ZW50
OiAiIiAhaW1wb3J0YW50OwogICAgICAgICAgICBwb3NpdGlvbjogYWJzb2x1dGUgIWltcG9ydGFudDsK
ICAgICAgICAgICAgbGVmdDogMCAhaW1wb3J0YW50OyByaWdodDogMCAhaW1wb3J0YW50OyBib3R0b206
IDAgIWltcG9ydGFudDsKICAgICAgICAgICAgaGVpZ2h0OiAycHggIWltcG9ydGFudDsKICAgICAgICAg
ICAgcG9pbnRlci1ldmVudHM6IG5vbmUgIWltcG9ydGFudDsKICAgICAgICAgICAgei1pbmRleDogMSAh
aW1wb3J0YW50OwogICAgICAgICAgICBiYWNrZ3JvdW5kOiByZ2JhKDkxLCAxMTUsIDIzMiwgLjkyKSAh
aW1wb3J0YW50OwogICAgICAgICAgICBib3JkZXItcmFkaXVzOiAxcHggIWltcG9ydGFudDsKICAgICAg
ICAgICAgdHJhbnNmb3JtOiBzY2FsZVgoMCkgIWltcG9ydGFudDsKICAgICAgICAgICAgdHJhbnNmb3Jt
LW9yaWdpbjogY2VudGVyICFpbXBvcnRhbnQ7CiAgICAgICAgICAgIHRyYW5zaXRpb246IHRyYW5zZm9y
bSAuM3MgY3ViaWMtYmV6aWVyKC4yMiwgMSwgLjM2LCAxKSAhaW1wb3J0YW50OwogICAgICAgIH0KICAg
ICAgICAuaXRtOmhvdmVyOjphZnRlciB7CiAgICAgICAgICAgIHRyYW5zZm9ybTogc2NhbGVYKDEpICFp
bXBvcnRhbnQ7CiAgICAgICAgICAgIGJhY2tncm91bmQ6IHJnYmEoOTEsIDExNSwgMjMyLCAuOTUpICFp
bXBvcnRhbnQ7CiAgICAgICAgfQogICAgICAgIC5pdG0gPiAqIHsgcG9zaXRpb246IHJlbGF0aXZlOyB6
LWluZGV4OiAyOyB9CiAgICAgICAgICAgIC8qIHBhbmVsLW91dGVyOiBEV00gQUEgY29ybmVycyArIENT
UyBjbGlwIH44cHggKi8KICAgICAgICBodG1sLCBib2R5IHsKICAgICAgICAgICAgYm9yZGVyOiBub25l
ICFpbXBvcnRhbnQ7CiAgICAgICAgICAgIG91dGxpbmU6IG5vbmUgIWltcG9ydGFudDsKICAgICAgICAg
ICAgYm94LXNoYWRvdzogbm9uZSAhaW1wb3J0YW50OwogICAgICAgICAgICBib3JkZXItcmFkaXVzOiA4
cHggIWltcG9ydGFudDsKICAgICAgICAgICAgb3ZlcmZsb3c6IGhpZGRlbiAhaW1wb3J0YW50OwogICAg
ICAgIH0KICAgICAgICAjYXBwIHsKICAgICAgICAgICAgYm9yZGVyOiBub25lICFpbXBvcnRhbnQ7CiAg
ICAgICAgICAgIG91dGxpbmU6IG5vbmUgIWltcG9ydGFudDsKICAgICAgICAgICAgYm94LXNoYWRvdzog
bm9uZSAhaW1wb3J0YW50OwogICAgICAgICAgICBib3JkZXItcmFkaXVzOiA4cHggIWltcG9ydGFudDsK
ICAgICAgICAgICAgYm94LXNpemluZzogYm9yZGVyLWJveCAhaW1wb3J0YW50OwogICAgICAgICAgICBv
dmVyZmxvdzogaGlkZGVuICFpbXBvcnRhbnQ7CiAgICAgICAgfQogICAgICAgIC5pdG0sIC5tZywgLm1n
LXJvdywgLm1lcmdlLWdyb3VwIHsKICAgICAgICAgICAgYm9yZGVyOiBub25lICFpbXBvcnRhbnQ7CiAg
ICAgICAgfQogICAgPC9zdHlsZT4KPC9oZWFkPgo8Ym9keT4KPGRpdiBpZD0iYXBwIj4KICAgIDxkaXYg
aWQ9ImhkciI+CiAgICAgICAgPGRpdiBpZD0iaGVhcnQiPgogICAgICAgICAgICA8c3ZnIHZpZXdCb3g9
IjAgMCAyNCAyNCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0cm9rZS13aWR0aD0i
MS44IgogICAgICAgICAgICAgICAgIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIgc3Ryb2tlLWxpbmVqb2lu
PSJyb3VuZCI+CiAgICAgICAgICAgICAgICA8cmVjdCB4PSI5IiB5PSIyIiB3aWR0aD0iNiIgaGVpZ2h0
PSI0IiByeD0iMSIvPgogICAgICAgICAgICAgICAgPHBhdGggZD0iTTE2IDRoMmEyIDIgMCAwIDEgMiAy
djE0YTIgMiAwIDAgMS0yIDJINmEyIDIgMCAwIDEtMi0yVjZhMiAyIDAgMCAxIDItMmgyIi8+CiAgICAg
ICAgICAgICAgICA8cGF0aCBkPSJNOSAxMmg2TTkgMTZoNCIvPgogICAgICAgICAgICA8L3N2Zz4KICAg
ICAgICA8L2Rpdj4KICAgICAgICA8ZGl2IGlkPSJoZHItZ3JvdyI+PC9kaXY+CiAgICAgICAgPGRpdiBp
ZD0ibXVsdGktYmFyIj4KICAgICAgICAgICAgPGJ1dHRvbiBpZD0ibXVsdGktY250IiB0eXBlPSJidXR0
b24iIHRpdGxlPSLlj5bmtojlpJrpgIkiPuW3sumAiTA8L2J1dHRvbj4KICAgICAgICAgICAgPHNwYW4g
Y2xhc3M9Im11bHRpLWJhci1kb3QiIGFyaWEtaGlkZGVuPSJ0cnVlIj7Ctzwvc3Bhbj4KICAgICAgICAg
ICAgPGRpdiBpZD0icGFzdGUtc2VwLXdyYXAiPgogICAgICAgICAgICAgICAgPGJ1dHRvbiBpZD0icGFz
dGUtc2VwLWJ0biIgdHlwZT0iYnV0dG9uIiB0aXRsZT0i57KY6LS05YiG6ZqU56ymIj4KICAgICAgICAg
ICAgICAgICAgICA8c3BhbiBpZD0icGFzdGUtc2VwLWxhYmVsIj7ikKM8L3NwYW4+CiAgICAgICAgICAg
ICAgICA8L2J1dHRvbj4KICAgICAgICAgICAgICAgIDxkaXYgaWQ9InBhc3RlLXNlcC1tZW51Ij48L2Rp
dj4KICAgICAgICAgICAgPC9kaXY+CiAgICAgICAgPC9kaXY+CiAgICAgICAgPGJ1dHRvbiBpZD0iYnRu
LWxvY2F0ZSIgdHlwZT0iYnV0dG9uIiB0aXRsZT0i5a6a5L2N5Yiw5LiK5qyh5L2/55So55qE5p2h55uu
IiBkaXNhYmxlZD4KICAgICAgICAgICAgPHN2ZyB2aWV3Qm94PSIwIDAgMjQgMjQiIGZpbGw9Im5vbmUi
IHN0cm9rZT0iY3VycmVudENvbG9yIiBzdHJva2Utd2lkdGg9IjIiCiAgICAgICAgICAgICAgICAgc3Ry
b2tlLWxpbmVjYXA9InJvdW5kIiBzdHJva2UtbGluZWpvaW49InJvdW5kIj4KICAgICAgICAgICAgICAg
IDxjaXJjbGUgY3g9IjEyIiBjeT0iMTIiIHI9IjgiLz4KICAgICAgICAgICAgICAgIDxjaXJjbGUgY3g9
IjEyIiBjeT0iMTIiIHI9IjMuNSIvPgogICAgICAgICAgICA8L3N2Zz4KICAgICAgICA8L2J1dHRvbj4K
ICAgICAgICA8ZGl2IGlkPSJzZWFyY2gtd3JhcCI+CiAgICAgICAgICAgIDxidXR0b24gaWQ9ImJ0bi1z
ZWFyY2giIHR5cGU9ImJ1dHRvbiIgdGl0bGU9IuaQnOe0oiI+CiAgICAgICAgICAgICAgICA8c3ZnIHZp
ZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0cm9rZS13
aWR0aD0iMiIKICAgICAgICAgICAgICAgICAgICAgc3Ryb2tlLWxpbmVjYXA9InJvdW5kIiBzdHJva2Ut
bGluZWpvaW49InJvdW5kIj4KICAgICAgICAgICAgICAgICAgICA8Y2lyY2xlIGN4PSIxMSIgY3k9IjEx
IiByPSI3Ii8+CiAgICAgICAgICAgICAgICAgICAgPHBhdGggZD0iTTIwIDIwbC0zLjUtMy41Ii8+CiAg
ICAgICAgICAgICAgICA8L3N2Zz4KICAgICAgICAgICAgPC9idXR0b24+CiAgICAgICAgICAgIDxkaXYg
aWQ9InNlYXJjaC1ib3giPgogICAgICAgICAgICAgICAgPGJ1dHRvbiBpZD0iYnRuLXRvZGF5IiB0eXBl
PSJidXR0b24iPuW9k+WkqTwvYnV0dG9uPgogICAgICAgICAgICAgICAgPGlucHV0IGlkPSJzZWFyY2gi
IHR5cGU9InRleHQiIHBsYWNlaG9sZGVyPSLmkJzntKLigKYg56m65qC85YiG6K+N6aG75ZCM5pe25YyF
5ZCrIMK3IGF8YiDliIbmrrUiIGF1dG9jb21wbGV0ZT0ib2ZmIiBzcGVsbGNoZWNrPSJmYWxzZSI+CiAg
ICAgICAgICAgICAgICA8YnV0dG9uIGlkPSJzZWFyY2gtY2xyIiB0eXBlPSJidXR0b24iPuKclTwvYnV0
dG9uPgogICAgICAgICAgICA8L2Rpdj4KICAgICAgICA8L2Rpdj4KICAgICAgICA8YnV0dG9uIGlkPSJi
dG4tcGluIiB0eXBlPSJidXR0b24iIHRpdGxlPSLpkonlnKjlsY/luZXkuIoiPgogICAgICAgICAgICA8
c3ZnIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0
cm9rZS13aWR0aD0iMiIKICAgICAgICAgICAgICAgICBzdHJva2UtbGluZWpvaW49InJvdW5kIiBzdHJv
a2UtbGluZWNhcD0icm91bmQiPgogICAgICAgICAgICAgICAgPGxpbmUgeDE9IjEyIiB5MT0iMTciIHgy
PSIxMiIgeTI9IjIyIi8+CiAgICAgICAgICAgICAgICA8cGF0aCBkPSJNNSAxN2gxNHYtMS43NmEyIDIg
MCAwIDAtMS4xMS0xLjc5bC0xLjc4LS45QTIgMiAwIDAgMSAxNSAxMC43NlY2aDFhMiAyIDAgMCAwIDAt
NEg4YTIgMiAwIDAgMCAwIDRoMXY0Ljc2YTIgMiAwIDAgMS0xLjExIDEuNzlsLTEuNzguOUEyIDIgMCAw
IDAgNSAxNS4yNFoiLz4KICAgICAgICAgICAgPC9zdmc+CiAgICAgICAgPC9idXR0b24+CiAgICA8L2Rp
dj4KCiAgICA8ZGl2IGlkPSJ0YWJzIj4KICAgICAgICA8ZGl2IGlkPSJ0YWItaW5rIiBhcmlhLWhpZGRl
bj0idHJ1ZSI+PC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0idGFiIG9uIiBkYXRhLXRhYj0iYWxsIj7l
hajpg6g8L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJ0YWIiIGRhdGEtdGFiPSJ0ZXh0Ij7mlofmnKw8
L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJ0YWIiIGRhdGEtdGFiPSJpbWFnZSI+5Zu+5YOPPC9kaXY+
CiAgICAgICAgPGRpdiBjbGFzcz0idGFiIiBkYXRhLXRhYj0iZmlsZSI+5paH5Lu2PC9kaXY+CiAgICAg
ICAgPGRpdiBjbGFzcz0idGFiIiBkYXRhLXRhYj0icmVjZW50Ij7mnIDov5E8L2Rpdj4KICAgICAgICA8
ZGl2IGNsYXNzPSJ0YWIiIGRhdGEtdGFiPSJwaW5uZWQiPuaUtuiXjyA8c3BhbiBjbGFzcz0iYmFkZ2Ui
IGlkPSJwaW4tY250IiBzdHlsZT0iZGlzcGxheTpub25lIj4wPC9zcGFuPjwvZGl2PgogICAgICAgIDxk
aXYgaWQ9InRhYi1hY3Rpb25zIj4KICAgICAgICAgICAgPHNwYW4gaWQ9ImJhci10eHQiPjA8L3NwYW4+
CiAgICAgICAgICAgIDxidXR0b24gaWQ9ImJ0bi1jbHIiIHR5cGU9ImJ1dHRvbiIgdGl0bGU9Iua4heep
uuWOhuWPsiI+CiAgICAgICAgICAgICAgICA8c3ZnIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0ibm9u
ZSIgc3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0cm9rZS13aWR0aD0iMiIKICAgICAgICAgICAgICAgICAg
ICAgc3Ryb2tlLWxpbmVjYXA9InJvdW5kIiBzdHJva2UtbGluZWpvaW49InJvdW5kIj4KICAgICAgICAg
ICAgICAgICAgICA8cG9seWxpbmUgcG9pbnRzPSIzIDYgNSA2IDIxIDYiLz4KICAgICAgICAgICAgICAg
ICAgICA8cGF0aCBkPSJNMTkgNmwtMSAxNGEyIDIgMCAwIDEtMiAySDhhMiAyIDAgMCAxLTItMkw1IDYi
Lz4KICAgICAgICAgICAgICAgICAgICA8cGF0aCBkPSJNMTAgMTF2Nk0xNCAxMXY2TTkgNlY0aDZ2MiIv
PgogICAgICAgICAgICAgICAgPC9zdmc+CiAgICAgICAgICAgIDwvYnV0dG9uPgogICAgICAgIDwvZGl2
PgogICAgPC9kaXY+CgogICAgPGRpdiBpZD0ibGlzdCI+CiAgICAgICAgPGRpdiBpZD0ic2tlbCIgYXJp
YS1oaWRkZW49InRydWUiPgogICAgICAgICAgICA8ZGl2IGNsYXNzPSJzay1yb3ciPjxkaXYgY2xhc3M9
InNrLWljbyI+PC9kaXY+PGRpdiBjbGFzcz0ic2stYm9keSI+PGRpdiBjbGFzcz0ic2stbGluZSBtaWQi
PjwvZGl2PjxkaXYgY2xhc3M9InNrLWxpbmUgc2hvcnQiPjwvZGl2PjwvZGl2PjwvZGl2PgogICAgICAg
ICAgICA8ZGl2IGNsYXNzPSJzay1yb3ciPjxkaXYgY2xhc3M9InNrLWljbyI+PC9kaXY+PGRpdiBjbGFz
cz0ic2stYm9keSI+PGRpdiBjbGFzcz0ic2stbGluZSI+PC9kaXY+PGRpdiBjbGFzcz0ic2stbGluZSBt
aWQiPjwvZGl2PjwvZGl2PjwvZGl2PgogICAgICAgICAgICA8ZGl2IGNsYXNzPSJzay1yb3ciPjxkaXYg
Y2xhc3M9InNrLWljbyI+PC9kaXY+PGRpdiBjbGFzcz0ic2stYm9keSI+PGRpdiBjbGFzcz0ic2stbGlu
ZSBtaWQiPjwvZGl2PjxkaXYgY2xhc3M9InNrLWxpbmUgc2hvcnQiPjwvZGl2PjwvZGl2PjwvZGl2Pgog
ICAgICAgICAgICA8ZGl2IGNsYXNzPSJzay1yb3ciPjxkaXYgY2xhc3M9InNrLWljbyI+PC9kaXY+PGRp
diBjbGFzcz0ic2stYm9keSI+PGRpdiBjbGFzcz0ic2stbGluZSI+PC9kaXY+PGRpdiBjbGFzcz0ic2st
bGluZSBtaWQiPjwvZGl2PjwvZGl2PjwvZGl2PgogICAgICAgICAgICA8ZGl2IGNsYXNzPSJzay1yb3ci
PjxkaXYgY2xhc3M9InNrLWljbyI+PC9kaXY+PGRpdiBjbGFzcz0ic2stYm9keSI+PGRpdiBjbGFzcz0i
c2stbGluZSBtaWQiPjwvZGl2PjxkaXYgY2xhc3M9InNrLWxpbmUgc2hvcnQiPjwvZGl2PjwvZGl2Pjwv
ZGl2PgogICAgICAgICAgICA8ZGl2IGNsYXNzPSJzay1yb3ciPjxkaXYgY2xhc3M9InNrLWljbyI+PC9k
aXY+PGRpdiBjbGFzcz0ic2stYm9keSI+PGRpdiBjbGFzcz0ic2stbGluZSI+PC9kaXY+PGRpdiBjbGFz
cz0ic2stbGluZSBzaG9ydCI+PC9kaXY+PC9kaXY+PC9kaXY+CiAgICAgICAgPC9kaXY+CiAgICAgICAg
PGRpdiBpZD0iZW1wdHkiPgogICAgICAgICAgICA8ZGl2IGNsYXNzPSJlLXR4dCIgaWQ9ImVtcHR5LXR4
dCI+5pqC5peg6K6w5b2V77yM5aSN5Yi25ZCO6Ieq5Yqo5Ye6546wPC9kaXY+CiAgICAgICAgPC9kaXY+
CiAgICA8L2Rpdj4KICAgIDxidXR0b24gaWQ9ImJ0bi10b3AiIHR5cGU9ImJ1dHRvbiIgdGl0bGU9IuWb
nuWIsOmhtumDqCIgYXJpYS1sYWJlbD0i5Zue5Yiw6aG26YOoIj4KICAgICAgICA8c3ZnIHZpZXdCb3g9
IjAgMCAyNCAyNCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0cm9rZS13aWR0aD0i
Mi4yIgogICAgICAgICAgICAgc3Ryb2tlLWxpbmVjYXA9InJvdW5kIiBzdHJva2UtbGluZWpvaW49InJv
dW5kIj4KICAgICAgICAgICAgPHBhdGggZD0iTTEyIDE5VjUiLz4KICAgICAgICAgICAgPHBhdGggZD0i
TTUgMTJsNy03IDcgNyIvPgogICAgICAgIDwvc3ZnPgogICAgPC9idXR0b24+CjwvZGl2PgoKPGRpdiBp
ZD0iY3R4Ij4KICAgIDxkaXYgY2xhc3M9ImMtaXRlbSIgaWQ9ImMtY29weSI+PHNwYW4gY2xhc3M9ImMt
aWNvIj7ijpg8L3NwYW4+5aSN5Yi2PC9kaXY+CiAgICA8ZGl2IGNsYXNzPSJjLWl0ZW0iIGlkPSJjLXBh
c3RlIj48c3BhbiBjbGFzcz0iYy1pY28iPuKPjjwvc3Bhbj7nspjotLQ8L2Rpdj4KICAgIDxkaXYgY2xh
c3M9ImMtc2VwIj48L2Rpdj4KICAgIDxkaXYgY2xhc3M9ImMtaXRlbSIgaWQ9ImMtcGluIj48c3BhbiBj
bGFzcz0iYy1pY28iPuKYhTwvc3Bhbj7mlLbol488L2Rpdj4KICAgIDxkaXYgY2xhc3M9ImMtaXRlbSIg
aWQ9ImMtdGl0bGUiIHN0eWxlPSJkaXNwbGF5Om5vbmUiPjxzcGFuIGNsYXNzPSJjLWljbyI+4pyOPC9z
cGFuPuiuvue9ruagh+mimDwvZGl2PgogICAgPGRpdiBjbGFzcz0iYy1pdGVtIiBpZD0iYy1tZXJnZSIg
c3R5bGU9ImRpc3BsYXk6bm9uZSI+PHNwYW4gY2xhc3M9ImMtaWNvIj7ip4k8L3NwYW4+5ZCI5bm2PC9k
aXY+CiAgICA8ZGl2IGNsYXNzPSJjLWl0ZW0iIGlkPSJjLXVubWVyZ2UiIHN0eWxlPSJkaXNwbGF5Om5v
bmUiPjxzcGFuIGNsYXNzPSJjLWljbyI+4oeEPC9zcGFuPuWPlua2iOWQiOW5tjwvZGl2PgogICAgPGRp
diBjbGFzcz0iYy1pdGVtIiBpZD0iYy10b3AiPjxzcGFuIGNsYXNzPSJjLWljbyI+4oaRPC9zcGFuPuen
u+WIsOmhtumDqDwvZGl2PgogICAgPGRpdiBjbGFzcz0iYy1pdGVtIiBpZD0iYy1jbGVhci1wYXN0ZWQi
IHN0eWxlPSJkaXNwbGF5Om5vbmUiPjxzcGFuIGNsYXNzPSJjLWljbyI+4pyTPC9zcGFuPua4hemZpOeK
tuaAgTwvZGl2PgogICAgPGRpdiBjbGFzcz0iYy1zZXAiPjwvZGl2PgogICAgPGRpdiBjbGFzcz0iYy1p
dGVtIGRhbmdlciIgaWQ9ImMtZGVsIj48c3BhbiBjbGFzcz0iYy1pY28iPuKclTwvc3Bhbj7liKDpmaQ8
L2Rpdj4KPC9kaXY+Cgo8ZGl2IGlkPSJjbHItZGxnIj4KICAgIDxkaXYgY2xhc3M9ImNsci1ib3giIHJv
bGU9ImRpYWxvZyIgYXJpYS1tb2RhbD0idHJ1ZSI+CiAgICAgICAgPGRpdiBjbGFzcz0iY2xyLXRpdGxl
IiBpZD0iY2xyLXRpdGxlIj7noa7orqTmuIXnqbrvvJ88L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJj
bHItZGVzYyIgaWQ9ImNsci1kZXNjIj7pu5jorqTku4XmuIXnqbrlvZPlpKnlhoXlrrnjgII8L2Rpdj4K
ICAgICAgICA8bGFiZWwgY2xhc3M9ImNsci1jaGVjayIgZm9yPSJjbHItYWxsIj4KICAgICAgICAgICAg
PGlucHV0IHR5cGU9ImNoZWNrYm94IiBpZD0iY2xyLWFsbCI+CiAgICAgICAgICAgIDxzcGFuPua4heep
uuaJgOaciTwvc3Bhbj4KICAgICAgICA8L2xhYmVsPgogICAgICAgIDxkaXYgY2xhc3M9ImNsci1idG5z
Ij4KICAgICAgICAgICAgPGJ1dHRvbiB0eXBlPSJidXR0b24iIGlkPSJjbHItY2FuY2VsIj7lj5bmtog8
L2J1dHRvbj4KICAgICAgICAgICAgPGJ1dHRvbiB0eXBlPSJidXR0b24iIGlkPSJjbHItb2siPua4heep
ujwvYnV0dG9uPgogICAgICAgIDwvZGl2PgogICAgPC9kaXY+CjwvZGl2PgoKPGRpdiBpZD0idGl0bGUt
ZGxnIj4KICAgIDxkaXYgY2xhc3M9InRpdGxlLWJveCIgcm9sZT0iZGlhbG9nIiBhcmlhLW1vZGFsPSJ0
cnVlIj4KICAgICAgICA8ZGl2IGNsYXNzPSJjbHItdGl0bGUiPuiuvue9ruagh+mimDwvZGl2PgogICAg
ICAgIDxkaXYgY2xhc3M9ImNsci1kZXNjIj7moIfpopjlj6/ooqvmkJzntKLmib7liLDvvIzku4XnlKjk
uo7mlLbol4/mlbTnkIbjgII8L2Rpdj4KICAgICAgICA8aW5wdXQgaWQ9InRpdGxlLWlucHV0IiB0eXBl
PSJ0ZXh0IiBtYXhsZW5ndGg9IjgwIiBwbGFjZWhvbGRlcj0i57uZ6L+Z5p2h5pS26JeP6LW35Liq5ZCN
5a2X4oCmIiBhdXRvY29tcGxldGU9Im9mZiIgc3BlbGxjaGVjaz0iZmFsc2UiPgogICAgICAgIDxkaXYg
Y2xhc3M9ImNsci1idG5zIj4KICAgICAgICAgICAgPGJ1dHRvbiB0eXBlPSJidXR0b24iIGlkPSJ0aXRs
ZS1jYW5jZWwiPuWPlua2iDwvYnV0dG9uPgogICAgICAgICAgICA8YnV0dG9uIHR5cGU9ImJ1dHRvbiIg
aWQ9InRpdGxlLW9rIj7kv53lrZg8L2J1dHRvbj4KICAgICAgICA8L2Rpdj4KICAgIDwvZGl2Pgo8L2Rp
dj4KPGRpdiBpZD0icGF0aC10aXAiIGFyaWEtaGlkZGVuPSJ0cnVlIj48L2Rpdj4KCjxzY3JpcHQ+Ci8q
IHNrZWwtZmFpbHNhZmU6IG9ubHkgaWYgbWFpbiBVSSBzY3JpcHQgbmV2ZXIgYm9vdGVkIOKAlG5ldmVy
IGludmVudCBlbXB0eS1zdGF0ZSAqLwooZnVuY3Rpb24oKXsKICBzZXRUaW1lb3V0KCgpID0+IHsKICAg
IHRyeSB7CiAgICAgIGlmICh3aW5kb3cuX191aUJvb3RlZCkgcmV0dXJuOwogICAgICB2YXIgYXBwID0g
ZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2FwcCcpOwogICAgICBpZiAoYXBwKSBhcHAuY2xhc3NMaXN0
LnJlbW92ZSgnYm9vdC1sb2FkaW5nJyk7CiAgICAgIHZhciBzID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5
SWQoJ3NrZWwnKTsKICAgICAgaWYgKHMpIHMuY2xhc3NMaXN0LnJlbW92ZSgnb24nKTsKICAgIH0gY2F0
Y2ggKGVycikge30KICB9LCAzMDAwKTsKfSkoKTsKPC9zY3JpcHQ+CjxzY3JpcHQ+CiAgICBsZXQgYWxs
Q2xpcHMgPSBbXSwgY3VyVGFiID0gJ2FsbCcsIHF1ZXJ5ID0gJycsIGN0eENsaXAgPSBudWxsLCBzZWxl
Y3RlZElkID0gMCwgcGlubmVkVUkgPSBmYWxzZTsKICAgIGNvbnN0IFRBQl9PUkRFUiA9IFsnYWxsJywg
J3RleHQnLCAnaW1hZ2UnLCAnZmlsZScsICdyZWNlbnQnLCAncGlubmVkJ107CiAgICBjb25zdCB2aWV3
TWVtID0gbmV3IE1hcCgpOwogICAgZnVuY3Rpb24gdmlld01lbUtleSh0YWIsIHEsIHRvZGF5KSB7CiAg
ICAgICAgcmV0dXJuIFN0cmluZyh0YWIgfHwgJ2FsbCcpICsgJ1x0JyArIFN0cmluZyhxIHx8ICcnKSAr
ICdcdCcgKyAodG9kYXkgPyAnMScgOiAnMCcpOwogICAgfQogICAgbGV0IHRhYlN3aXRjaEFuaW1EaXIg
PSAwOwogICAgbGV0IG11bHRpSWRzID0gW107CiAgICBsZXQgdG9kYXlPbmx5ID0gZmFsc2U7CiAgICBs
ZXQgZGlza1RvdGFsID0gMDsKICAgIGxldCBsb2FkaW5nTW9yZSA9IGZhbHNlOwogICAgLy8gRG9uJ3Qg
c2hvdyBza2VsZXRvbiBpbW1lZGlhdGVseSDigJRvbmx5IGFmdGVyIFNLRUxfREVMQVlfTVMgaWYgZGF0
YSBzdGlsbCBtaXNzaW5nCiAgICBsZXQgYm9vdExvYWRpbmcgPSBmYWxzZTsKICAgIGxldCB3YWl0aW5n
RGF0YSA9IGZhbHNlOwogICAgbGV0IGhvc3RQdXNoZWRPbmNlID0gZmFsc2U7IC8vIG9ubHkgdGhlbiBt
YXkgc2hvd+OAjOaaguaXoOiusOW9leOAjQogICAgbGV0IHNhd05vbkVtcHR5ID0gZmFsc2U7ICAgIC8v
IGlnbm9yZSBib290c3RyYXAgZW1wdHkgcHVzaGVzIGJlZm9yZSBmaXJzdCByZWFsIGxpc3QKICAgIGxl
dCBwaW5uZWRUb3RhbCA9IDA7ICAgICAgICAvLyBhdXRob3JpdGF0aXZlIOaUtuiXjyBjb3VudCBmcm9t
IEFISwogICAgY29uc3QgU0tFTF9ERUxBWV9NUyA9IDYwOwogICAgd2luZG93Ll9fZGF0YVJlYWR5ID0g
ZmFsc2U7CiAgICB3aW5kb3cuX191aUJvb3RlZCA9IHRydWU7CiAgICAvLyBPcGVuIHBhbmVsIHdpdGhv
dXQgcGFzdGluZyDihpIgYWx3YXlzIGxhbmQgb24gZmlyc3QgaXRlbSAoYWZ0ZXIgZGF0YSBhcnJpdmVz
KQogICAgbGV0IHNlbGVjdEZpcnN0T25TaG93ID0gZmFsc2U7CiAgICBsZXQgbGFzdFBhc3RlSWQgPSAw
OwogICAgbGV0IGxhc3RQYXN0ZVRhYiA9ICdhbGwnOwogICAgbGV0IGxvY2F0ZUFjdGl2ZSA9IGZhbHNl
OwogICAgdHJ5IHsgbGFzdFBhc3RlSWQgPSArbG9jYWxTdG9yYWdlLmdldEl0ZW0oJ2NsaXBMYXN0UGFz
dGVJZCcpIHx8IDA7IH0gY2F0Y2gge30KICAgIHRyeSB7CiAgICAgICAgY29uc3QgdCA9IGxvY2FsU3Rv
cmFnZS5nZXRJdGVtKCdjbGlwTGFzdFBhc3RlVGFiJykgfHwgJ2FsbCc7CiAgICAgICAgbGFzdFBhc3Rl
VGFiID0gWydhbGwnLCd0ZXh0JywnaW1hZ2UnLCdmaWxlJywncGlubmVkJ10uaW5jbHVkZXModCkgPyB0
IDogJ2FsbCc7CiAgICB9IGNhdGNoIHt9CiAgICAvLyBQcmVmZXIgc2FtZS1vcmlnaW4gdW5kZXIgY2xp
cHVpLmxvY2FsIChBUFBfSE9TVCDihpIgQ0xJUF9WMV9ESVIvY2xpcHNfc3RvcmUpLgogICAgLy8gY2xp
cHMuc3RvcmUgaXMgYSBkZWRpY2F0ZWQgbWFwcGluZyBmYWxsYmFjayB3aGVuIHNhbWUtb3JpZ2luIGZh
aWxzLgogICAgY29uc3QgU1RPUkVfQkFTRSA9IChsb2NhdGlvbi5vcmlnaW4gJiYgbG9jYXRpb24ub3Jp
Z2luLmluZGV4T2YoJ2h0dHBzOi8vJykgPT09IDApCiAgICAgICAgPyAobG9jYXRpb24ub3JpZ2luLnJl
cGxhY2UoL1wvJC8sICcnKSArICcvY2xpcHNfc3RvcmUvJykKICAgICAgICA6ICdodHRwczovL2NsaXB1
aS5sb2NhbC9jbGlwc19zdG9yZS8nOwogICAgY29uc3QgU1RPUkVfQkFTRV9GQUxMQkFDSyA9ICdodHRw
czovL2NsaXBzLnN0b3JlLyc7CiAgICBmdW5jdGlvbiBtZXRhQ2VudGVySHRtbChleHBhbmRJbm5lcikg
ewogICAgICAgIGlmIChleHBhbmRJbm5lciA9PSBudWxsIHx8IGV4cGFuZElubmVyID09PSBmYWxzZSkK
ICAgICAgICAgICAgcmV0dXJuIGA8c3BhbiBjbGFzcz0iaS1tZXRhLWNlbnRlciI+PC9zcGFuPmA7CiAg
ICAgICAgcmV0dXJuIGA8c3BhbiBjbGFzcz0iaS1tZXRhLWNlbnRlciI+PGJ1dHRvbiBjbGFzcz0iaS1l
eHBhbmQtYnRuJHtleHBhbmRJbm5lci5vbiA/ICcgb24nIDogJyd9IiB0eXBlPSJidXR0b24iIHRpdGxl
PSLlsZXlvIAv5pS26LW3Ij4ke2V4cGFuZElubmVyLmh0bWx9PC9idXR0b24+PC9zcGFuPmA7CiAgICB9
CgogICAgZnVuY3Rpb24gcmVtZW1iZXJMYXN0UGFzdGUoaWQpIHsKICAgICAgICBsYXN0UGFzdGVJZCA9
ICtpZCB8fCAwOwogICAgICAgIGxhc3RQYXN0ZVRhYiA9IGN1clRhYiB8fCAnYWxsJzsKICAgICAgICB0
cnkgewogICAgICAgICAgICBsb2NhbFN0b3JhZ2Uuc2V0SXRlbSgnY2xpcExhc3RQYXN0ZUlkJywgU3Ry
aW5nKGxhc3RQYXN0ZUlkKSk7CiAgICAgICAgICAgIGxvY2FsU3RvcmFnZS5zZXRJdGVtKCdjbGlwTGFz
dFBhc3RlVGFiJywgbGFzdFBhc3RlVGFiKTsKICAgICAgICB9IGNhdGNoIHt9CiAgICAgICAgdXBkYXRl
TG9jYXRlQnRuKCk7CiAgICB9CiAgICBmdW5jdGlvbiB1cGRhdGVMb2NhdGVCdG4oKSB7CiAgICAgICAg
Y29uc3QgYnRuID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2J0bi1sb2NhdGUnKTsKICAgICAgICBp
ZiAoIWJ0bikgcmV0dXJuOwogICAgICAgIGJ0bi5kaXNhYmxlZCA9ICFsYXN0UGFzdGVJZDsKICAgICAg
ICBidG4uY2xhc3NMaXN0LnRvZ2dsZSgnaGFzLXRhcmdldCcsICEhbGFzdFBhc3RlSWQpOwogICAgICAg
IGJ0bi5jbGFzc0xpc3QudG9nZ2xlKCdvbicsIGxvY2F0ZUFjdGl2ZSAmJiAhIWxhc3RQYXN0ZUlkKTsK
ICAgICAgICBidG4udGl0bGUgPSAhbGFzdFBhc3RlSWQKICAgICAgICAgICAgPyAn5pqC5peg5LiK5qyh
5L2/55So5L2N572uJwogICAgICAgICAgICA6IChsb2NhdGVBY3RpdmUgPyAn5Y+W5raI5a6a5L2N77yM
5Zue5Yiw56ys5LiA5p2hJyA6ICflrprkvY3liLDkuIrmrKHkvb/nlKjnmoTmnaHnm64nKTsKICAgIH0K
ICAgIGZ1bmN0aW9uIHNlbGVjdEZpcnN0SXRlbSgpIHsKICAgICAgICBsb2NhdGVBY3RpdmUgPSBmYWxz
ZTsKICAgICAgICB3aW5kb3cuX19wZW5kaW5nSnVtcElkID0gMDsKICAgICAgICB3aW5kb3cuX19qdW1w
TG9hZFRyaWVzID0gMDsKICAgICAgICBzZWxlY3RGaXJzdE9uU2hvdyA9IGZhbHNlOwogICAgICAgIGNv
bnN0IHZpcyA9IHZpc2libGVMaXN0KCk7CiAgICAgICAgaWYgKCF2aXMubGVuZ3RoKSB7CiAgICAgICAg
ICAgIHNlbGVjdGVkSWQgPSAwOwogICAgICAgICAgICBzeW5jSXRlbUhpZ2hsaWdodCgpOwogICAgICAg
ICAgICB1cGRhdGVMb2NhdGVCdG4oKTsKICAgICAgICAgICAgcmV0dXJuOwogICAgICAgIH0KICAgICAg
ICBzZWxlY3RlZElkID0gdmlzWzBdLmlkOwogICAgICAgIHJhbmdlQW5jaG9ySWQgPSBzZWxlY3RlZElk
OwogICAgICAgIHJhbmdlQW5jaG9yQ2xpY2tlZCA9IGZhbHNlOwogICAgICAgIGxpc3RFbC5zY3JvbGxU
b3AgPSAwOwogICAgICAgIHN5bmNJdGVtSGlnaGxpZ2h0KCk7CiAgICAgICAgY29uc3QgZWwgPSBsaXN0
RWwucXVlcnlTZWxlY3RvcignLml0bVtkYXRhLWlkPSInICsgc2VsZWN0ZWRJZCArICciXScpOwogICAg
ICAgIGlmIChlbCkgZWwuc2Nyb2xsSW50b1ZpZXcoeyBibG9jazogJ25lYXJlc3QnIH0pOwogICAgICAg
IHVwZGF0ZUxvY2F0ZUJ0bigpOwogICAgfQogICAgZnVuY3Rpb24ganVtcFRvTGFzdFBhc3RlKCkgewog
ICAgICAgIGlmICghbGFzdFBhc3RlSWQpIHJldHVybjsKICAgICAgICAvLyBBbHJlYWR5IGxvY2F0ZWQg
b24gbGFzdCBwYXN0ZSDihpIgY2FuY2VsIGFuZCBzZWxlY3QgZmlyc3QKICAgICAgICBpZiAobG9jYXRl
QWN0aXZlICYmICtzZWxlY3RlZElkID09PSArbGFzdFBhc3RlSWQpIHsKICAgICAgICAgICAgc2VsZWN0
Rmlyc3RJdGVtKCk7CiAgICAgICAgICAgIHJldHVybjsKICAgICAgICB9CiAgICAgICAgbG9jYXRlQWN0
aXZlID0gdHJ1ZTsKICAgICAgICBzZWxlY3RGaXJzdE9uU2hvdyA9IGZhbHNlOwogICAgICAgIC8vIENs
ZWFyIGZpbHRlcnMgc28gdGhlIGl0ZW0gaXMgZmluZGFibGUgb24gdGhlIHRhYiB3aGVyZSBpdCB3YXMg
dXNlZAogICAgICAgIHF1ZXJ5ID0gJyc7CiAgICAgICAgdG9kYXlPbmx5ID0gZmFsc2U7CiAgICAgICAg
dHJ5IHsKICAgICAgICAgICAgY29uc3Qgc3JjaCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzZWFy
Y2gnKTsKICAgICAgICAgICAgY29uc3Qgc2NsciA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzZWFy
Y2gtY2xyJyk7CiAgICAgICAgICAgIGNvbnN0IHdyYXAgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgn
c2VhcmNoLXdyYXAnKTsKICAgICAgICAgICAgY29uc3QgYnRuVG9kYXkgPSBkb2N1bWVudC5nZXRFbGVt
ZW50QnlJZCgnYnRuLXRvZGF5Jyk7CiAgICAgICAgICAgIGlmIChzcmNoKSB7IHNyY2gudmFsdWUgPSAn
Jzsgc3JjaC5jbGFzc0xpc3QucmVtb3ZlKCdoYXMtdmFsJyk7IH0KICAgICAgICAgICAgaWYgKHNjbHIp
IHNjbHIuc3R5bGUuZGlzcGxheSA9ICdub25lJzsKICAgICAgICAgICAgaWYgKHdyYXApIHdyYXAuY2xh
c3NMaXN0LnJlbW92ZSgnb3BlbicpOwogICAgICAgICAgICBpZiAoYnRuVG9kYXkpIGJ0blRvZGF5LmNs
YXNzTGlzdC5yZW1vdmUoJ29uJyk7CiAgICAgICAgfSBjYXRjaCB7fQogICAgICAgIGNvbnN0IHRhYiA9
IFsnYWxsJywndGV4dCcsJ2ltYWdlJywnZmlsZScsJ3JlY2VudCcsJ3Bpbm5lZCddLmluY2x1ZGVzKGxh
c3RQYXN0ZVRhYikKICAgICAgICAgICAgPyBsYXN0UGFzdGVUYWIgOiAnYWxsJzsKICAgICAgICBjb25z
dCBwcmV2VGFiID0gY3VyVGFiOwogICAgICAgIGN1clRhYiA9IHRhYjsKICAgICAgICBsb2FkaW5nTW9y
ZSA9IGZhbHNlOwogICAgICAgIG1hcmtUYWIodGFiKTsKICAgICAgICBjbGVhck11bHRpKCk7CiAgICAg
ICAgc2VsZWN0ZWRJZCA9IGxhc3RQYXN0ZUlkOwogICAgICAgIHdpbmRvdy5fX3BlbmRpbmdKdW1wSWQg
PSBsYXN0UGFzdGVJZDsKICAgICAgICB3aW5kb3cuX19qdW1wTG9hZFRyaWVzID0gMDsKICAgICAgICB3
aW5kb3cuX19qdW1wRmVsbEJhY2sgPSBmYWxzZTsKICAgICAgICB1cGRhdGVMb2NhdGVCdG4oKTsKICAg
ICAgICByZXF1ZXN0VmlldygpOwogICAgfQoKICAgIGZ1bmN0aW9uIHJlcXVlc3RWaWV3KCkgewogICAg
ICAgIGNvbnN0IHRhYiA9IGN1clRhYiwgcSA9IHF1ZXJ5LCB0b2RheSA9IHRvZGF5T25seSA/ICcxJyA6
ICcwJzsKICAgICAgICBpZiAod2luZG93Ll9fdmlld1JhZikgY2FuY2VsQW5pbWF0aW9uRnJhbWUod2lu
ZG93Ll9fdmlld1JhZik7CiAgICAgICAgd2luZG93Ll9fdmlld1JhZiA9IHJlcXVlc3RBbmltYXRpb25G
cmFtZSgoKSA9PiB7CiAgICAgICAgICAgIHdpbmRvdy5fX3ZpZXdSYWYgPSAwOwogICAgICAgICAgICBz
ZXRUaW1lb3V0KCgpID0+IGFoaygnc2V0VmlldycsIHRhYiwgcSwgdG9kYXkpLCAwKTsKICAgICAgICB9
KTsKICAgIH0KICAgIC8qKiBEZWJvdW5jZWQgQUhLIHN5bmMgYWZ0ZXIgdmlld01lbSBpbnN0YW50IHBh
aW50IOKAlGF2b2lkcyB0YWItc3dpdGNoIGRvdWJsZSBQdXNoQ2xpcHMgKi8KICAgIGZ1bmN0aW9uIHNv
ZnRSZXF1ZXN0VmlldygpIHsKICAgICAgICBpZiAod2luZG93Ll9fc29mdFZpZXdUKSBjbGVhclRpbWVv
dXQod2luZG93Ll9fc29mdFZpZXdUKTsKICAgICAgICB3aW5kb3cuX19zb2Z0Vmlld1QgPSBzZXRUaW1l
b3V0KCgpID0+IHsKICAgICAgICAgICAgd2luZG93Ll9fc29mdFZpZXdUID0gMDsKICAgICAgICAgICAg
cmVxdWVzdFZpZXcoKTsKICAgICAgICB9LCAzMjApOwogICAgfQogICAgZnVuY3Rpb24gcmVxdWVzdE1v
cmUoKSB7CiAgICAgICAgaWYgKGxvYWRpbmdNb3JlKSByZXR1cm47CiAgICAgICAgaWYgKGRpc2tUb3Rh
bCA+IDAgJiYgYWxsQ2xpcHMubGVuZ3RoID49IGRpc2tUb3RhbCkgcmV0dXJuOwogICAgICAgIGxvYWRp
bmdNb3JlID0gdHJ1ZTsKICAgICAgICBzZXRUaW1lb3V0KCgpID0+IGFoaygnbG9hZE1vcmUnKSwgMCk7
CiAgICB9CiAgICBjb25zdCBFTVBUWV9NU0cgPSB7CiAgICAgICAgYWxsOiAgICAn5pqC5peg6K6w5b2V
77yM5aSN5Yi25ZCO6Ieq5Yqo5Ye6546wJywKICAgICAgICB0ZXh0OiAgICfmmoLml6DmlofmnKwnLAog
ICAgICAgIGltYWdlOiAgJ+aaguaXoOWbvuWDjycsCiAgICAgICAgZmlsZTogICAn5pqC5peg5paH5Lu2
JywKICAgICAgICByZWNlbnQ6ICfmmoLml6DmnIDov5Hmlofku7blpLnvvIzlnKjotYTmupDnrqHnkIbl
majkuK3ov5vlhaXnm67lvZXlkI7lh7rnjrAnLAogICAgICAgIHBpbm5lZDogJ+aaguaXoOaUtuiXjycK
ICAgIH07CgogICAgZnVuY3Rpb24gYWhrSW52b2tlKG1ldGhvZCwgYXJncykgewogICAgICAgIHRyeSB7
CiAgICAgICAgICAgIGNvbnN0IGhvc3QgPSBjaHJvbWUud2Vidmlldy5ob3N0T2JqZWN0cy5zeW5jLmFo
azsKICAgICAgICAgICAgaWYgKCFob3N0KSByZXR1cm47CiAgICAgICAgICAgIGxldCBjYWxsZWQgPSBm
YWxzZTsKICAgICAgICAgICAgaWYgKHR5cGVvZiBob3N0LmNhbGwgPT09ICdmdW5jdGlvbicpIHsKICAg
ICAgICAgICAgICAgIHRyeSB7IGhvc3QuY2FsbChtZXRob2QsIC4uLmFyZ3MpOyBjYWxsZWQgPSB0cnVl
OyB9IGNhdGNoIHt9CiAgICAgICAgICAgIH0KICAgICAgICAgICAgaWYgKCFjYWxsZWQgJiYgdHlwZW9m
IGhvc3RbbWV0aG9kXSA9PT0gJ2Z1bmN0aW9uJykgewogICAgICAgICAgICAgICAgdHJ5IHsgaG9zdFtt
ZXRob2RdKC4uLmFyZ3MpOyBjYWxsZWQgPSB0cnVlOyB9IGNhdGNoIHt9CiAgICAgICAgICAgICAgICBp
ZiAoIWNhbGxlZCkgewogICAgICAgICAgICAgICAgICAgIHRyeSB7IGhvc3RbbWV0aG9kXSguLi5hcmdz
KTsgY2FsbGVkID0gdHJ1ZTsgfSBjYXRjaCB7fQogICAgICAgICAgICAgICAgfQogICAgICAgICAgICB9
CiAgICAgICAgICAgIGlmICghY2FsbGVkICYmIGhvc3RbbWV0aG9kXSAhPSBudWxsICYmIHR5cGVvZiBo
b3N0W21ldGhvZF0gIT09ICdmdW5jdGlvbicpIHsKICAgICAgICAgICAgICAgIHRyeSB7IHZvaWQgaG9z
dFttZXRob2RdOyB9IGNhdGNoIHt9CiAgICAgICAgICAgIH0KICAgICAgICB9IGNhdGNoIChlKSB7IGNv
bnNvbGUud2FybignYWhrLicgKyBtZXRob2QsIGUpOyB9CiAgICB9CiAgICBmdW5jdGlvbiBhaGsobWV0
aG9kLCAuLi5hcmdzKSB7CiAgICAgICAgYWhrSW52b2tlKG1ldGhvZCwgYXJncyk7CiAgICB9CgogICAg
Y29uc3QgU0VQX05FV0xJTkVfVE9LRU4gPSAnW+aNouihjF0nOwogICAgLy8gRml4ZWQgY29tbW9uIHNl
cGFyYXRvcnMgb25seSDigJQgY3VzdG9tIHZhbHVlcyBhcmUgbmV2ZXIgYWRkZWQgdG8gdGhpcyBsaXN0
CiAgICBjb25zdCBTRVBfTElTVCA9IFsnICcsIFNFUF9ORVdMSU5FX1RPS0VOLCAnLCcsICcsICcsICfj
gIEnLCAnfCddOwogICAgbGV0IHBhc3RlU2VwVmFsdWUgPSAnICc7CiAgICBsZXQgbXVsdGlCYXJXYXNP
biA9IGZhbHNlOwoKICAgIGZ1bmN0aW9uIG5vcm1hbGl6ZVNlcElucHV0KHJhdykgewogICAgICAgIGxl
dCBzID0gU3RyaW5nKHJhdyA/PyAnJyk7CiAgICAgICAgaWYgKHMgPT09ICcnKSByZXR1cm4gJyAnOwog
ICAgICAgIC8vIEFjY2VwdCBhbGlhc2VzIHR5cGVkIGluIHRoZSBjdXN0b20gYm94CiAgICAgICAgY29u
c3QgdCA9IHMudHJpbSgpOwogICAgICAgIGlmICh0ID09PSBTRVBfTkVXTElORV9UT0tFTiB8fCB0ID09
PSAn5o2i6KGMJyB8fCB0ID09PSAnXFxuJyB8fCB0ID09PSAnXG4nIHx8IHQgPT09ICdcclxuJykKICAg
ICAgICAgICAgcmV0dXJuIFNFUF9ORVdMSU5FX1RPS0VOOwogICAgICAgIGlmICh0ID09PSAnXFx0JyB8
fCB0ID09PSAnXHQnKSByZXR1cm4gJ1x0JzsKICAgICAgICByZXR1cm4gczsKICAgIH0KICAgIGZ1bmN0
aW9uIHNlcFRvQWN0dWFsKHJhdykgewogICAgICAgIGNvbnN0IHMgPSBub3JtYWxpemVTZXBJbnB1dChy
YXcpOwogICAgICAgIHJldHVybiBzID09PSBTRVBfTkVXTElORV9UT0tFTiA/ICdcbicgOiBzOwogICAg
fQogICAgLyoqIEJyaWRnZS1zYWZlIHNlcCBmb3IgQUhLIGhvc3RPYmplY3RzIChyZWFsIFxcbiBvZnRl
biBnZXRzIHN0cmlwcGVkKSAqLwogICAgZnVuY3Rpb24gc2VwVG9CcmlkZ2UocmF3KSB7CiAgICAgICAg
Y29uc3QgcyA9IG5vcm1hbGl6ZVNlcElucHV0KHJhdyk7CiAgICAgICAgaWYgKHMgPT09IFNFUF9ORVdM
SU5FX1RPS0VOIHx8IHMgPT09ICdcbicgfHwgcyA9PT0gJ1xyXG4nKSByZXR1cm4gU0VQX05FV0xJTkVf
VE9LRU47CiAgICAgICAgaWYgKHMgPT09ICdcdCcpIHJldHVybiAnW+WItuihqOespl0nOwogICAgICAg
IHJldHVybiBzOwogICAgfQogICAgZnVuY3Rpb24gc2VwRGlzcGxheVN5bWJvbChyYXcpIHsKICAgICAg
ICBjb25zdCBzID0gbm9ybWFsaXplU2VwSW5wdXQocmF3KTsKICAgICAgICBpZiAocyA9PT0gJyAnKSBy
ZXR1cm4gJ+KQoyc7CiAgICAgICAgaWYgKHMgPT09IFNFUF9ORVdMSU5FX1RPS0VOKSByZXR1cm4gJ+KG
tSc7CiAgICAgICAgaWYgKHMgPT09ICdcdCcpIHJldHVybiAn4oelJzsKICAgICAgICBpZiAocyA9PT0g
J1xuJykgcmV0dXJuICfihrUnOwogICAgICAgIGlmIChzID09PSAnXHJcbicpIHJldHVybiAn4oa1JzsK
ICAgICAgICBpZiAocyA9PT0gJywnKSByZXR1cm4gJywnOwogICAgICAgIGlmIChzID09PSAnLCAnKSBy
ZXR1cm4gJyzikKMnOwogICAgICAgIGlmIChzID09PSAn44CBJykgcmV0dXJuICfjgIEnOwogICAgICAg
IGlmIChzID09PSAnfCcpIHJldHVybiAnfCc7CiAgICAgICAgcmV0dXJuIHMKICAgICAgICAgICAgLnJl
cGxhY2UoL1xyXG4vZywgJ+KGtScpCiAgICAgICAgICAgIC5yZXBsYWNlKC9cbi9nLCAn4oa1JykKICAg
ICAgICAgICAgLnJlcGxhY2UoL1x0L2csICfih6UnKQogICAgICAgICAgICAucmVwbGFjZSgvXHIvZywg
JycpOwogICAgfQogICAgZnVuY3Rpb24gc2VwRGlzcGxheU5hbWUocmF3KSB7CiAgICAgICAgY29uc3Qg
cyA9IG5vcm1hbGl6ZVNlcElucHV0KHJhdyk7CiAgICAgICAgaWYgKHMgPT09ICcgJykgcmV0dXJuICfn
qbrmoLwnOwogICAgICAgIGlmIChzID09PSBTRVBfTkVXTElORV9UT0tFTiB8fCBzID09PSAnXG4nIHx8
IHMgPT09ICdcclxuJykgcmV0dXJuICfmjaLooYwnOwogICAgICAgIGlmIChzID09PSAnXHQnKSByZXR1
cm4gJ+WItuihqOespic7CiAgICAgICAgaWYgKHMgPT09ICcsJykgcmV0dXJuICfpgJflj7cnOwogICAg
ICAgIGlmIChzID09PSAnLCAnKSByZXR1cm4gJ+mAl+WPt+epuuagvCc7CiAgICAgICAgaWYgKHMgPT09
ICfjgIEnKSByZXR1cm4gJ+mhv+WPtyc7CiAgICAgICAgaWYgKHMgPT09ICd8JykgcmV0dXJuICfnq5bn
ur8nOwogICAgICAgIHJldHVybiAnJzsKICAgIH0KICAgIGZ1bmN0aW9uIHNlcERpc3BsYXlMYWJlbChy
YXcpIHsKICAgICAgICByZXR1cm4gc2VwRGlzcGxheVN5bWJvbChyYXcpOwogICAgfQogICAgZnVuY3Rp
b24gZmlsbFNlcE1lbnVJdGVtKGJ0biwgdikgewogICAgICAgIGJ0bi5pbm5lckhUTUwgPSAnJzsKICAg
ICAgICBjb25zdCBzeW0gPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdzcGFuJyk7CiAgICAgICAgc3lt
LmNsYXNzTmFtZSA9ICdwYXN0ZS1zZXAtc3ltJyArIChzZXBEaXNwbGF5TmFtZSh2KSA/ICcnIDogJyBv
bmx5Jyk7CiAgICAgICAgc3ltLnRleHRDb250ZW50ID0gc2VwRGlzcGxheVN5bWJvbCh2KTsKICAgICAg
ICBidG4uYXBwZW5kQ2hpbGQoc3ltKTsKICAgICAgICBjb25zdCBuYW1lID0gc2VwRGlzcGxheU5hbWUo
dik7CiAgICAgICAgaWYgKG5hbWUpIHsKICAgICAgICAgICAgY29uc3QgbGFiID0gZG9jdW1lbnQuY3Jl
YXRlRWxlbWVudCgnc3BhbicpOwogICAgICAgICAgICBsYWIuY2xhc3NOYW1lID0gJ3Bhc3RlLXNlcC1u
YW1lJzsKICAgICAgICAgICAgbGFiLnRleHRDb250ZW50ID0gbmFtZTsKICAgICAgICAgICAgYnRuLmFw
cGVuZENoaWxkKGxhYik7CiAgICAgICAgfQogICAgfQogICAgZnVuY3Rpb24gbG9hZFNlcExpc3QoKSB7
CiAgICAgICAgcmV0dXJuIFNFUF9MSVNULnNsaWNlKCk7CiAgICB9CiAgICBmdW5jdGlvbiB1cGRhdGVT
ZXBMYWJlbCgpIHsKICAgICAgICBjb25zdCBsYWIgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgncGFz
dGUtc2VwLWxhYmVsJyk7CiAgICAgICAgaWYgKGxhYikgbGFiLnRleHRDb250ZW50ID0gc2VwRGlzcGxh
eUxhYmVsKHBhc3RlU2VwVmFsdWUpOwogICAgfQogICAgZnVuY3Rpb24gYXBwbHlTZXBhcmF0b3IocmF3
LCBvcHRzID0ge30pIHsKICAgICAgICBjb25zdCBkb1Bhc3RlID0gb3B0cy5wYXN0ZSAhPSBudWxsID8g
b3B0cy5wYXN0ZSA6IG11bHRpSWRzLmxlbmd0aCA+IDA7CiAgICAgICAgcGFzdGVTZXBWYWx1ZSA9IG5v
cm1hbGl6ZVNlcElucHV0KHJhdyk7CiAgICAgICAgdXBkYXRlU2VwTGFiZWwoKTsKICAgICAgICBjbG9z
ZVNlcE1lbnUoKTsKICAgICAgICBpZiAoZG9QYXN0ZSkgcGFzdGVNdWx0aVNlbGVjdGlvbigpOwogICAg
fQogICAgZnVuY3Rpb24gY2xvc2VTZXBNZW51KCkgewogICAgICAgIGNvbnN0IG1lbnUgPSBkb2N1bWVu
dC5nZXRFbGVtZW50QnlJZCgncGFzdGUtc2VwLW1lbnUnKTsKICAgICAgICBjb25zdCBidG4gPSBkb2N1
bWVudC5nZXRFbGVtZW50QnlJZCgncGFzdGUtc2VwLWJ0bicpOwogICAgICAgIGlmIChtZW51KSBtZW51
LmNsYXNzTGlzdC5yZW1vdmUoJ29uJyk7CiAgICAgICAgaWYgKGJ0bikgYnRuLmNsYXNzTGlzdC5yZW1v
dmUoJ29wZW4nKTsKICAgIH0KICAgIGZ1bmN0aW9uIHJlbmRlclNlcE1lbnUoKSB7CiAgICAgICAgY29u
c3QgbWVudSA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdwYXN0ZS1zZXAtbWVudScpOwogICAgICAg
IGlmICghbWVudSkgcmV0dXJuOwogICAgICAgIG1lbnUuaW5uZXJIVE1MID0gJyc7CiAgICAgICAgZm9y
IChjb25zdCB2IG9mIGxvYWRTZXBMaXN0KCkpIHsKICAgICAgICAgICAgY29uc3QgYiA9IGRvY3VtZW50
LmNyZWF0ZUVsZW1lbnQoJ2J1dHRvbicpOwogICAgICAgICAgICBiLnR5cGUgPSAnYnV0dG9uJzsKICAg
ICAgICAgICAgYi5jbGFzc05hbWUgPSAncGFzdGUtc2VwLWl0ZW0nICsgKHYgPT09IHBhc3RlU2VwVmFs
dWUgPyAnIHNlbCcgOiAnJyk7CiAgICAgICAgICAgIGZpbGxTZXBNZW51SXRlbShiLCB2KTsKICAgICAg
ICAgICAgYi5vbmNsaWNrID0gZSA9PiB7CiAgICAgICAgICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigp
OwogICAgICAgICAgICAgICAgYXBwbHlTZXBhcmF0b3Iodik7CiAgICAgICAgICAgIH07CiAgICAgICAg
ICAgIG1lbnUuYXBwZW5kQ2hpbGQoYik7CiAgICAgICAgfQogICAgICAgIGNvbnN0IGZvb3QgPSBkb2N1
bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsKICAgICAgICBmb290LmNsYXNzTmFtZSA9ICdwYXN0ZS1z
ZXAtZm9vdCc7CiAgICAgICAgY29uc3QgaW5wID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnaW5wdXQn
KTsKICAgICAgICBpbnAuaWQgPSAncGFzdGUtc2VwLWN1c3RvbSc7CiAgICAgICAgaW5wLnR5cGUgPSAn
dGV4dCc7CiAgICAgICAgaW5wLnBsYWNlaG9sZGVyID0gJ+iHquWumuS5ieKApiBb5o2i6KGMXSc7CiAg
ICAgICAgaW5wLmF1dG9jb21wbGV0ZSA9ICdvZmYnOwogICAgICAgIGlucC5zcGVsbGNoZWNrID0gZmFs
c2U7CiAgICAgICAgaW5wLnZhbHVlID0gbG9hZFNlcExpc3QoKS5pbmNsdWRlcyhwYXN0ZVNlcFZhbHVl
KSA/ICcnIDogcGFzdGVTZXBWYWx1ZTsKICAgICAgICBpbnAub25tb3VzZWRvd24gPSBlID0+IHsKICAg
ICAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICAgICAgZS5wcmV2ZW50RGVmYXVsdCgp
OwogICAgICAgICAgICB0cnkgeyBhaGsoJ2ZvY3VzUGFuZWwnKTsgfSBjYXRjaCB7fQogICAgICAgICAg
ICBpbnAuZm9jdXMoKTsKICAgICAgICB9OwogICAgICAgIGlucC5vbmNsaWNrID0gZSA9PiBlLnN0b3BQ
cm9wYWdhdGlvbigpOwogICAgICAgIGlucC5vbmZvY3VzID0gKCkgPT4geyB0cnkgeyBhaGsoJ2ZvY3Vz
UGFuZWwnKTsgfSBjYXRjaCB7fSB9OwogICAgICAgIGlucC5vbmlucHV0ID0gZSA9PiBlLnN0b3BQcm9w
YWdhdGlvbigpOwogICAgICAgIGlucC5vbmtleWRvd24gPSBlID0+IHsKICAgICAgICAgICAgZS5zdG9w
UHJvcGFnYXRpb24oKTsKICAgICAgICAgICAgaWYgKGUua2V5ID09PSAnRW50ZXInKSB7CiAgICAgICAg
ICAgICAgICBlLnByZXZlbnREZWZhdWx0KCk7CiAgICAgICAgICAgICAgICBpZiAoaW5wLnZhbHVlICE9
PSAnJykgYXBwbHlTZXBhcmF0b3IoaW5wLnZhbHVlKTsKICAgICAgICAgICAgICAgIGVsc2UgY2xvc2VT
ZXBNZW51KCk7CiAgICAgICAgICAgIH0gZWxzZSBpZiAoZS5rZXkgPT09ICdFc2NhcGUnKSB7CiAgICAg
ICAgICAgICAgICBlLnByZXZlbnREZWZhdWx0KCk7CiAgICAgICAgICAgICAgICBjbG9zZVNlcE1lbnUo
KTsKICAgICAgICAgICAgfQogICAgICAgIH07CiAgICAgICAgZm9vdC5hcHBlbmRDaGlsZChpbnApOwog
ICAgICAgIG1lbnUuYXBwZW5kQ2hpbGQoZm9vdCk7CiAgICB9CiAgICBmdW5jdGlvbiByZXNldFBhc3Rl
U2VwRGVmYXVsdCgpIHsKICAgICAgICBwYXN0ZVNlcFZhbHVlID0gJyAnOwogICAgICAgIHVwZGF0ZVNl
cExhYmVsKCk7CiAgICAgICAgY2xvc2VTZXBNZW51KCk7CiAgICB9CiAgICBmdW5jdGlvbiBnZXRQYXN0
ZVNlcEFjdHVhbCgpIHsKICAgICAgICByZXR1cm4gc2VwVG9BY3R1YWwocGFzdGVTZXBWYWx1ZSk7CiAg
ICB9CiAgICBmdW5jdGlvbiBwYXN0ZU1hbnlXaXRoU2VwKGlkcywgcmVtZW1iZXIgPSB0cnVlKSB7CiAg
ICAgICAgYWhrKCdwYXN0ZU1hbnknLCBpZHMuam9pbignLCcpLCBzZXBUb0JyaWRnZShwYXN0ZVNlcFZh
bHVlKSk7CiAgICB9CiAgICBmdW5jdGlvbiBpbml0U2VwVWkoKSB7CiAgICAgICAgdXBkYXRlU2VwTGFi
ZWwoKTsKICAgICAgICByZW5kZXJTZXBNZW51KCk7CiAgICAgICAgY29uc3QgYnRuID0gZG9jdW1lbnQu
Z2V0RWxlbWVudEJ5SWQoJ3Bhc3RlLXNlcC1idG4nKTsKICAgICAgICBpZiAoYnRuKSB7CiAgICAgICAg
ICAgIGJ0bi5hZGRFdmVudExpc3RlbmVyKCdjbGljaycsIGUgPT4gewogICAgICAgICAgICAgICAgZS5z
dG9wUHJvcGFnYXRpb24oKTsKICAgICAgICAgICAgICAgIGNvbnN0IG1lbnUgPSBkb2N1bWVudC5nZXRF
bGVtZW50QnlJZCgncGFzdGUtc2VwLW1lbnUnKTsKICAgICAgICAgICAgICAgIGNvbnN0IG9wZW4gPSBt
ZW51ICYmIG1lbnUuY2xhc3NMaXN0LmNvbnRhaW5zKCdvbicpOwogICAgICAgICAgICAgICAgaWYgKG9w
ZW4pIHsKICAgICAgICAgICAgICAgICAgICBjb25zdCBpbnAgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJ
ZCgncGFzdGUtc2VwLWN1c3RvbScpOwogICAgICAgICAgICAgICAgICAgIGlmIChpbnAgJiYgaW5wLnZh
bHVlICE9PSAnJykgYXBwbHlTZXBhcmF0b3IoaW5wLnZhbHVlLCB7IHBhc3RlOiBtdWx0aUlkcy5sZW5n
dGggPiAwIH0pOwogICAgICAgICAgICAgICAgICAgIGVsc2UgY2xvc2VTZXBNZW51KCk7CiAgICAgICAg
ICAgICAgICAgICAgcmV0dXJuOwogICAgICAgICAgICAgICAgfQogICAgICAgICAgICAgICAgcmVuZGVy
U2VwTWVudSgpOwogICAgICAgICAgICAgICAgbWVudS5jbGFzc0xpc3QuYWRkKCdvbicpOwogICAgICAg
ICAgICAgICAgYnRuLmNsYXNzTGlzdC5hZGQoJ29wZW4nKTsKICAgICAgICAgICAgfSk7CiAgICAgICAg
fQogICAgICAgIGRvY3VtZW50LmFkZEV2ZW50TGlzdGVuZXIoJ21vdXNlZG93bicsIGUgPT4gewogICAg
ICAgICAgICBpZiAoZS50YXJnZXQuY2xvc2VzdCgnI3Bhc3RlLXNlcC13cmFwJykpIHJldHVybjsKICAg
ICAgICAgICAgY29uc3QgbWVudSA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdwYXN0ZS1zZXAtbWVu
dScpOwogICAgICAgICAgICBpZiAoIW1lbnUgfHwgIW1lbnUuY2xhc3NMaXN0LmNvbnRhaW5zKCdvbicp
KSByZXR1cm47CiAgICAgICAgICAgIGNvbnN0IGlucCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdw
YXN0ZS1zZXAtY3VzdG9tJyk7CiAgICAgICAgICAgIGlmIChpbnAgJiYgaW5wLnZhbHVlICE9PSAnJykg
ewogICAgICAgICAgICAgICAgYXBwbHlTZXBhcmF0b3IoaW5wLnZhbHVlKTsKICAgICAgICAgICAgICAg
IHJldHVybjsKICAgICAgICAgICAgfQogICAgICAgICAgICBjbG9zZVNlcE1lbnUoKTsKICAgICAgICB9
LCB0cnVlKTsKICAgIH0KCiAgICBmdW5jdGlvbiBhaGtSZXQobWV0aG9kLCAuLi5hcmdzKSB7CiAgICAg
ICAgdHJ5IHsKICAgICAgICAgICAgY29uc3QgaG9zdCA9IGNocm9tZS53ZWJ2aWV3Lmhvc3RPYmplY3Rz
LnN5bmMuYWhrOwogICAgICAgICAgICBpZiAoIWhvc3QpIHJldHVybiBudWxsOwogICAgICAgICAgICBs
ZXQgcmV0ID0gbnVsbDsKICAgICAgICAgICAgaWYgKHR5cGVvZiBob3N0LmNhbGwgPT09ICdmdW5jdGlv
bicpIHsKICAgICAgICAgICAgICAgIHRyeSB7IHJldCA9IGhvc3QuY2FsbChtZXRob2QsIC4uLmFyZ3Mp
OyB9IGNhdGNoIHt9CiAgICAgICAgICAgIH0KICAgICAgICAgICAgaWYgKHJldCA9PSBudWxsICYmIHR5
cGVvZiBob3N0W21ldGhvZF0gPT09ICdmdW5jdGlvbicpIHsKICAgICAgICAgICAgICAgIHRyeSB7IHJl
dCA9IGhvc3RbbWV0aG9kXSguLi5hcmdzKTsgfSBjYXRjaCB7fQogICAgICAgICAgICAgICAgaWYgKHJl
dCA9PSBudWxsKSB7CiAgICAgICAgICAgICAgICAgICAgdHJ5IHsgcmV0ID0gaG9zdFttZXRob2RdKC4u
LmFyZ3MpOyB9IGNhdGNoIHt9CiAgICAgICAgICAgICAgICB9CiAgICAgICAgICAgIH0KICAgICAgICAg
ICAgaWYgKHJldCA9PSBudWxsICYmIGhvc3RbbWV0aG9kXSAhPSBudWxsICYmIHR5cGVvZiBob3N0W21l
dGhvZF0gIT09ICdmdW5jdGlvbicpCiAgICAgICAgICAgICAgICByZXQgPSBob3N0W21ldGhvZF07CiAg
ICAgICAgICAgIGlmIChyZXQgPT0gbnVsbCkgcmV0dXJuIG51bGw7CiAgICAgICAgICAgIGlmICh0eXBl
b2YgcmV0ID09PSAnc3RyaW5nJyB8fCB0eXBlb2YgcmV0ID09PSAnbnVtYmVyJyB8fCB0eXBlb2YgcmV0
ID09PSAnYm9vbGVhbicpCiAgICAgICAgICAgICAgICByZXR1cm4gcmV0OwogICAgICAgICAgICB0cnkg
eyByZXR1cm4gU3RyaW5nKHJldCk7IH0gY2F0Y2ggeyByZXR1cm4gcmV0OyB9CiAgICAgICAgfSBjYXRj
aCAoZSkgeyBjb25zb2xlLndhcm4oJ2Foa1JldC4nICsgbWV0aG9kLCBlKTsgfQogICAgICAgIHJldHVy
biBudWxsOwogICAgfQoKICAgIC8vIEVhcmx5IEFISyBfX3NldFRodW1iIGNhbiBhcnJpdmUgYmVmb3Jl
IERPTSBub2RlcyBleGlzdCDigJQga2VlcCB1bnRpbCBiaW5kCiAgICBjb25zdCB0aHVtYkNhY2hlID0g
bmV3IE1hcCgpOwoKICAgIC8qKiBQcmVmZXIgY2FjaGUgLyBkYXRhLVVSTCwgdGhlbiB0aF8qLmpwZyB2
aWEgdmlydHVhbCBob3N0LCB0aGVuIG9yaWdpbmFsICovCiAgICBmdW5jdGlvbiBiaW5kU3RvcmVUaHVt
YihpbWcsIGZpbGUsIGlkLCBmYWxsYmFjaykgewogICAgICAgIGltZy5kYXRhc2V0LnRodW1iSWQgPSBT
dHJpbmcoaWQpOwogICAgICAgIGltZy5hbHQgPSAnJzsKICAgICAgICBpbWcuY2xhc3NMaXN0LmFkZCgn
dGh1bWItbG9hZGluZycpOwogICAgICAgIGNvbnN0IHdyYXAgPSBpbWcucGFyZW50RWxlbWVudDsKICAg
ICAgICBpZiAod3JhcCAmJiB3cmFwLmNsYXNzTGlzdC5jb250YWlucygnaS10aHVtYi13cmFwJykpCiAg
ICAgICAgICAgIHdyYXAuY2xhc3NMaXN0LmFkZCgnd2FpdGluZycpOwogICAgICAgIGNvbnN0IGNsZWFy
V2FpdCA9ICgpID0+IHsKICAgICAgICAgICAgaW1nLmNsYXNzTGlzdC5yZW1vdmUoJ3RodW1iLWxvYWRp
bmcnKTsKICAgICAgICAgICAgaWYgKHdyYXApIHdyYXAuY2xhc3NMaXN0LnJlbW92ZSgnd2FpdGluZycp
OwogICAgICAgICAgICBpZiAoaW1nLl9mYWlsVGltZXIpIHRyeSB7IGNsZWFyVGltZW91dChpbWcuX2Zh
aWxUaW1lcik7IH0gY2F0Y2gge30KICAgICAgICB9OwogICAgICAgIGNvbnN0IGZhaWxUaW1lciA9IHNl
dFRpbWVvdXQoKCkgPT4gewogICAgICAgICAgICBpZiAoIWltZy5zcmMgfHwgaW1nLm5hdHVyYWxXaWR0
aCA8IDEpCiAgICAgICAgICAgICAgICBpbWcuYWx0ID0gJ+aXoOazleWKoOi9vSc7CiAgICAgICAgICAg
IGNsZWFyV2FpdCgpOwogICAgICAgIH0sIDEyMDAwKTsKICAgICAgICBpbWcuX2ZhaWxUaW1lciA9IGZh
aWxUaW1lcjsKICAgICAgICBjb25zdCBwcmV2TG9hZCA9IGltZy5vbmxvYWQ7CiAgICAgICAgaW1nLm9u
bG9hZCA9IGUgPT4gewogICAgICAgICAgICBjbGVhcldhaXQoKTsKICAgICAgICAgICAgaW1nLmFsdCA9
ICcnOwogICAgICAgICAgICBpZiAodHlwZW9mIHByZXZMb2FkID09PSAnZnVuY3Rpb24nKSBwcmV2TG9h
ZC5jYWxsKGltZywgZSk7CiAgICAgICAgfTsKICAgICAgICBjb25zdCBiYXJlID0gZmlsZSA/IFN0cmlu
ZyhmaWxlKS5zcGxpdCgvW1xcL10vKS5wb3AoKSA6ICcnOwogICAgICAgIGNvbnN0IHRoTmFtZSA9IGJh
cmUgPyAoJ3RoXycgKyBiYXJlLnJlcGxhY2UoL1wuW14uXSskLywgJycpICsgJy5qcGcnKSA6ICcnOwog
ICAgICAgIGltZy5vbmVycm9yID0gKCkgPT4gewogICAgICAgICAgICBjb25zdCBzdGVwID0gTnVtYmVy
KGltZy5kYXRhc2V0LnN0ZXAgfHwgMCk7CiAgICAgICAgICAgIGlmIChzdGVwIDwgMiAmJiBiYXJlKSB7
CiAgICAgICAgICAgICAgICBpbWcuZGF0YXNldC5zdGVwID0gJzInOwogICAgICAgICAgICAgICAgaW1n
LnNyYyA9IFNUT1JFX0JBU0UgKyBlbmNvZGVVUklDb21wb25lbnQoYmFyZSk7CiAgICAgICAgICAgICAg
ICByZXR1cm47CiAgICAgICAgICAgIH0KICAgICAgICAgICAgaWYgKHN0ZXAgPCAzICYmICh0aE5hbWUg
fHwgYmFyZSkpIHsKICAgICAgICAgICAgICAgIGltZy5kYXRhc2V0LnN0ZXAgPSAnMyc7CiAgICAgICAg
ICAgICAgICBpbWcuc3JjID0gU1RPUkVfQkFTRV9GQUxMQkFDSyArIGVuY29kZVVSSUNvbXBvbmVudCh0
aE5hbWUgfHwgYmFyZSk7CiAgICAgICAgICAgICAgICByZXR1cm47CiAgICAgICAgICAgIH0KICAgICAg
ICAgICAgaWYgKHN0ZXAgPCA0ICYmIGJhcmUgJiYgdGhOYW1lKSB7CiAgICAgICAgICAgICAgICBpbWcu
ZGF0YXNldC5zdGVwID0gJzQnOwogICAgICAgICAgICAgICAgaW1nLnNyYyA9IFNUT1JFX0JBU0VfRkFM
TEJBQ0sgKyBlbmNvZGVVUklDb21wb25lbnQoYmFyZSk7CiAgICAgICAgICAgICAgICByZXR1cm47CiAg
ICAgICAgICAgIH0KICAgICAgICAgICAgLy8gS2VlcCBzaGltbWVyOyBBSEsgX19zZXRUaHVtYiB3aWxs
IGZpbGwgaW4KICAgICAgICAgICAgaW1nLnJlbW92ZUF0dHJpYnV0ZSgnc3JjJyk7CiAgICAgICAgICAg
IGltZy5jbGFzc0xpc3QuYWRkKCd0aHVtYi1sb2FkaW5nJyk7CiAgICAgICAgICAgIGlmICh3cmFwKSB3
cmFwLmNsYXNzTGlzdC5hZGQoJ3dhaXRpbmcnKTsKICAgICAgICB9OwogICAgICAgIGNvbnN0IGNhY2hl
ZCA9IHRodW1iQ2FjaGUuZ2V0KFN0cmluZyhpZCkpOwogICAgICAgIC8vIEFjY2VwdCBkYXRhLVVSTCBv
ciBob3N0IFVSTCBmcm9tIHByaW9yIF9fc2V0VGh1bWIgKHJlLXJlbmRlciBtdXN0IG5vdCBkcm9wIGl0
KQogICAgICAgIGlmIChjYWNoZWQgJiYgU3RyaW5nKGNhY2hlZCkubGVuZ3RoKSB7CiAgICAgICAgICAg
IGltZy5kYXRhc2V0LnN0ZXAgPSAnOSc7CiAgICAgICAgICAgIGltZy5zcmMgPSBTdHJpbmcoY2FjaGVk
KTsKICAgICAgICAgICAgcmV0dXJuOwogICAgICAgIH0KICAgICAgICBjb25zdCBkYXRhVXJsID0gKGZh
bGxiYWNrICYmIFN0cmluZyhmYWxsYmFjaykuc3RhcnRzV2l0aCgnZGF0YTonKSkKICAgICAgICAgICAg
PyBTdHJpbmcoZmFsbGJhY2spIDogJyc7CiAgICAgICAgaWYgKGRhdGFVcmwpIHsKICAgICAgICAgICAg
aW1nLmRhdGFzZXQuc3RlcCA9ICc5JzsKICAgICAgICAgICAgaW1nLnNyYyA9IGRhdGFVcmw7CiAgICAg
ICAgICAgIHJldHVybjsKICAgICAgICB9CiAgICAgICAgaWYgKGJhcmUpIHsKICAgICAgICAgICAgLy8g
UHJlZmVyIGxpc3QgdGh1bWIgSlBFRyAoc21hbGwpIG9uIGRlZGljYXRlZCBzdG9yZSBob3N0CiAgICAg
ICAgICAgIGltZy5kYXRhc2V0LnN0ZXAgPSAnMSc7CiAgICAgICAgICAgIGltZy5zcmMgPSBTVE9SRV9C
QVNFICsgZW5jb2RlVVJJQ29tcG9uZW50KHRoTmFtZSB8fCBiYXJlKTsKICAgICAgICB9IGVsc2Ugewog
ICAgICAgICAgICAvLyBObyBmaWxlIHlldCAoanVzdCBjb3BpZWQpIOKAlGtlZXAgc2hpbW1lcjsgSW5q
ZWN0TGl2ZUltYWdlVGh1bWIgLyBfX3NldFRodW1iIGZpbGxzIGluCiAgICAgICAgICAgIGltZy5jbGFz
c0xpc3QuYWRkKCd0aHVtYi1sb2FkaW5nJyk7CiAgICAgICAgICAgIGlmICh3cmFwKSB3cmFwLmNsYXNz
TGlzdC5hZGQoJ3dhaXRpbmcnKTsKICAgICAgICB9CiAgICB9CgogICAgd2luZG93Ll9fc2V0VGh1bWIg
PSAoaWQsIHVybCkgPT4gewogICAgICAgIGlmICghdXJsKSByZXR1cm47CiAgICAgICAgY29uc3Qga2V5
ID0gU3RyaW5nKGlkKTsKICAgICAgICB0aHVtYkNhY2hlLnNldChrZXksIHVybCk7CiAgICAgICAgY29u
c3QgYXBwbHkgPSBpbWcgPT4gewogICAgICAgICAgICBpZiAoaW1nLl9mYWlsVGltZXIpIHRyeSB7IGNs
ZWFyVGltZW91dChpbWcuX2ZhaWxUaW1lcik7IH0gY2F0Y2gge30KICAgICAgICAgICAgaW1nLm9uZXJy
b3IgPSBudWxsOwogICAgICAgICAgICBpbWcuYWx0ID0gJyc7CiAgICAgICAgICAgIGltZy5jbGFzc0xp
c3QucmVtb3ZlKCd0aHVtYi1sb2FkaW5nJyk7CiAgICAgICAgICAgIGNvbnN0IHdyYXAgPSBpbWcucGFy
ZW50RWxlbWVudDsKICAgICAgICAgICAgaWYgKHdyYXApIHdyYXAuY2xhc3NMaXN0LnJlbW92ZSgnd2Fp
dGluZycpOwogICAgICAgICAgICBpbWcuc3JjID0gdXJsOwogICAgICAgIH07CiAgICAgICAgbGV0IGhp
dCA9IDA7CiAgICAgICAgZG9jdW1lbnQucXVlcnlTZWxlY3RvckFsbCgnLml0bVtkYXRhLWlkPSInICsg
a2V5ICsgJyJdIGltZy5pLXRodW1iJykuZm9yRWFjaChpbWcgPT4gewogICAgICAgICAgICBhcHBseShp
bWcpOyBoaXQrKzsKICAgICAgICB9KTsKICAgICAgICBpZiAoIWhpdCkgewogICAgICAgICAgICBkb2N1
bWVudC5xdWVyeVNlbGVjdG9yQWxsKCdpbWcuaS10aHVtYltkYXRhLXRodW1iLWlkPSInICsga2V5ICsg
JyJdJykuZm9yRWFjaChhcHBseSk7CiAgICAgICAgfQogICAgfTsKCiAgICBmdW5jdGlvbiBpc0RyYWdF
eGNsdWRlKHQpIHsKICAgICAgICByZXR1cm4gISF0LmNsb3Nlc3QoJyNzZWFyY2gtd3JhcCwgI2J0bi1z
ZWFyY2gsICNidG4tbG9jYXRlLCAjYnRuLXRvZGF5LCAjYnRuLXBpbiwgI2J0bi1jbHIsICNtdWx0aS1i
YXIsICNtdWx0aS1jbnQsICNwYXN0ZS1zZXAtd3JhcCwgI3Bhc3RlLXNlcC1idG4sICNwYXN0ZS1zZXAt
bWVudSwgLnRhYiwgLml0bSwgI3RhYi1hY3Rpb25zLCAjY3R4LCAjY2xyLWRsZywgI3BhdGgtdGlwLCBi
dXR0b24sIGlucHV0LCBhJyk7CiAgICB9CiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYXBwJyku
YWRkRXZlbnRMaXN0ZW5lcignbW91c2Vkb3duJywgZSA9PiB7CiAgICAgICAgaWYgKGUuYnV0dG9uICE9
PSAwKSByZXR1cm47CiAgICAgICAgaWYgKGlzRHJhZ0V4Y2x1ZGUoZS50YXJnZXQpKSByZXR1cm47CiAg
ICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOwogICAgICAgIGFoaygnc3RhcnREcmFnJyk7CiAgICB9LCB0
cnVlKTsKCiAgICBjb25zdCBpc1VybCAgPSBzID0+IC9eaHR0cHM/OlwvXC8vaS50ZXN0KChzIHx8ICcn
KS50cmltKCkpOwoKICAgIGZ1bmN0aW9uIGFnbyhkYXRlU3RyKSB7CiAgICAgICAgdHJ5IHsKICAgICAg
ICAgICAgY29uc3QgZCA9IG5ldyBEYXRlKFN0cmluZyhkYXRlU3RyKS5yZXBsYWNlKCcgJywgJ1QnKSk7
CiAgICAgICAgICAgIGNvbnN0IHMgPSAoRGF0ZS5ub3coKSAtIGQpIC8gMTAwMCB8IDA7CiAgICAgICAg
ICAgIGlmIChzIDwgNjApIHJldHVybiAn5Yia5YiaJzsKICAgICAgICAgICAgaWYgKHMgPCAzNjAwKSBy
ZXR1cm4gKHMgLyA2MCB8IDApICsgJyDliIbpkp/liY0nOwogICAgICAgICAgICBpZiAocyA8IDg2NDAw
KSByZXR1cm4gKHMgLyAzNjAwIHwgMCkgKyAnIOWwj+aXtuWJjSc7CiAgICAgICAgICAgIHJldHVybiAo
cyAvIDg2NDAwIHwgMCkgKyAnIOWkqeWJjSc7CiAgICAgICAgfSBjYXRjaCB7IHJldHVybiBkYXRlU3Ry
OyB9CiAgICB9CgogICAgZnVuY3Rpb24gbm9ybVR5cGUodCkgewogICAgICAgIHQgPSBTdHJpbmcodCB8
fCAnJykudG9Mb3dlckNhc2UoKTsKICAgICAgICBpZiAodCA9PT0gJ2ltYWdlJyB8fCB0ID09PSAnaW1n
JyB8fCB0ID09PSAnYml0bWFwJykgcmV0dXJuICdpbWFnZSc7CiAgICAgICAgaWYgKHQgPT09ICdmaWxl
JyAgfHwgdCA9PT0gJ2ZpbGVzJykgcmV0dXJuICdmaWxlJzsKICAgICAgICBpZiAodCA9PT0gJ3JlY2Vu
dCcgfHwgdCA9PT0gJ2ZvbGRlcicgfHwgdCA9PT0gJ2RpcicpIHJldHVybiAncmVjZW50JzsKICAgICAg
ICByZXR1cm4gJ3RleHQnOwogICAgfQogICAgZnVuY3Rpb24gaXNQaW5uZWQoYykgewogICAgICAgIHJl
dHVybiBjLnBpbm5lZCA9PT0gdHJ1ZSB8fCBjLnBpbm5lZCA9PT0gMSB8fCBjLnBpbm5lZCA9PT0gJ3Ry
dWUnIHx8IGMucGlubmVkID09PSAnMSc7CiAgICB9CiAgICBmdW5jdGlvbiBpc1Bhc3RlZChjKSB7CiAg
ICAgICAgcmV0dXJuIGMucGFzdGVkID09PSB0cnVlIHx8IGMucGFzdGVkID09PSAxIHx8IGMucGFzdGVk
ID09PSAndHJ1ZScgfHwgYy5wYXN0ZWQgPT09ICcxJzsKICAgIH0KCiAgICBmdW5jdGlvbiBpc01hcmtk
b3duKHRleHQpIHsKICAgICAgICBpZiAoIXRleHQgfHwgdGV4dC5sZW5ndGggPCA0KSByZXR1cm4gZmFs
c2U7CiAgICAgICAgcmV0dXJuIC8oPzpefFxuKSN7MSw2fSB8XlstKitdIHxcKlwqW14qXG5dK1wqXCp8
X19bXl9cbl0rX198KD86Xnxcbik+IHxgYGB8YFteYFxuXStgfFxbW15cXV0rXF1cKFteKV0rXCl8XHwu
K1x8LitcfC9tLnRlc3QodGV4dCk7CiAgICB9CiAgICBmdW5jdGlvbiBjbGlwVXNlc01JY29uKGMpIHsK
ICAgICAgICBpZiAoIWMpIHJldHVybiBmYWxzZTsKICAgICAgICBpZiAoYy5pc01kID09PSB0cnVlIHx8
IGMuaXNNZCA9PT0gMSB8fCBjLmlzTWQgPT09ICd0cnVlJyB8fCBjLmlzTWQgPT09ICcxJykgcmV0dXJu
IHRydWU7CiAgICAgICAgaWYgKGMuaXNSaWNoID09PSB0cnVlIHx8IGMuaXNSaWNoID09PSAxIHx8IGMu
aXNSaWNoID09PSAndHJ1ZScgfHwgYy5pc1JpY2ggPT09ICcxJykgcmV0dXJuIHRydWU7CiAgICAgICAg
Y29uc3QgdCA9IFN0cmluZyhjLnR5cGUgfHwgJycpLnRvTG93ZXJDYXNlKCk7CiAgICAgICAgaWYgKHQg
JiYgdCAhPT0gJ3RleHQnICYmIHQgIT09ICdsaW5rJykgcmV0dXJuIGZhbHNlOwogICAgICAgIHJldHVy
biBpc01hcmtkb3duKGMuZGF0YSB8fCBjLnByZXZpZXcgfHwgJycpOwogICAgfQogICAgZnVuY3Rpb24g
ZXNjQXR0cihzKSB7CiAgICAgICAgcmV0dXJuIFN0cmluZyhzIHx8ICcnKQogICAgICAgICAgICAucmVw
bGFjZSgvJi9nLCAnJmFtcDsnKQogICAgICAgICAgICAucmVwbGFjZSgvIi9nLCAnJnF1b3Q7JykKICAg
ICAgICAgICAgLnJlcGxhY2UoLzwvZywgJyZsdDsnKQogICAgICAgICAgICAucmVwbGFjZSgvPi9nLCAn
Jmd0OycpOwogICAgfQoKICAgIGZ1bmN0aW9uIHRvZGF5UHJlZml4KCkgewogICAgICAgIGNvbnN0IGQg
PSBuZXcgRGF0ZSgpOwogICAgICAgIGNvbnN0IHAgPSBuID0+IFN0cmluZyhuKS5wYWRTdGFydCgyLCAn
MCcpOwogICAgICAgIHJldHVybiBkLmdldEZ1bGxZZWFyKCkgKyAnLScgKyBwKGQuZ2V0TW9udGgoKSAr
IDEpICsgJy0nICsgcChkLmdldERhdGUoKSk7CiAgICB9CiAgICBmdW5jdGlvbiBpc1RvZGF5Q2xpcChj
KSB7CiAgICAgICAgcmV0dXJuIFN0cmluZyhjLnRpbWUgfHwgJycpLnN0YXJ0c1dpdGgodG9kYXlQcmVm
aXgoKSk7CiAgICB9CgogICAgZnVuY3Rpb24gY2xpcEhheShjKSB7CiAgICAgICAgcmV0dXJuIFN0cmlu
ZyhjLnByZXZpZXcgfHwgJycpICsgJyAnICsgU3RyaW5nKGMuZGF0YSB8fCAnJykgKyAnICcKICAgICAg
ICAgICAgKyBTdHJpbmcoYy5saW5rVGl0bGUgfHwgJycpICsgJyAnICsgU3RyaW5nKGMuZmF2VGl0bGUg
fHwgJycpOwogICAgfQogICAgLyoqIE1hdGNoIEFISyBJdGVtTWF0Y2hlc1ZpZXcgbGlzdCBzZWFyY2gg
4oCUIHByZXZpZXcgKCsgc2hvcnQgYm9keSBmYWxsYmFjayksIG5vdCBmdWxsIGRhdGEgKi8KICAgIGZ1
bmN0aW9uIGNsaXBTZWFyY2hIYXkoYykgewogICAgICAgIGNvbnN0IHR5cGUgPSBTdHJpbmcoYy50eXBl
IHx8ICcnKS50b0xvd2VyQ2FzZSgpOwogICAgICAgIGlmICh0eXBlID09PSAnaW1hZ2UnKQogICAgICAg
ICAgICByZXR1cm4gU3RyaW5nKGMuZmF2VGl0bGUgfHwgJycpOwogICAgICAgIGlmICh0eXBlID09PSAn
cmVjZW50JyB8fCB0eXBlID09PSAnZm9sZGVyJyB8fCB0eXBlID09PSAnZGlyJykgewogICAgICAgICAg
ICByZXR1cm4gU3RyaW5nKGMucHJldmlldyB8fCAnJykgKyAnICcgKyBTdHJpbmcoYy5kYXRhIHx8ICcn
KSArICcgJwogICAgICAgICAgICAgICAgKyBTdHJpbmcoYy5mYXZUaXRsZSB8fCAnJyk7CiAgICAgICAg
fQogICAgICAgIGlmICh0eXBlID09PSAnZmlsZScpIHsKICAgICAgICAgICAgcmV0dXJuIFN0cmluZyhj
LnByZXZpZXcgfHwgJycpICsgJyAnICsgU3RyaW5nKGMuZGF0YSB8fCAnJykgKyAnICcKICAgICAgICAg
ICAgICAgICsgU3RyaW5nKGMuZmF2VGl0bGUgfHwgJycpOwogICAgICAgIH0KICAgICAgICBsZXQgcHJl
diA9IFN0cmluZyhjLnByZXZpZXcgfHwgJycpOwogICAgICAgIGlmICghcHJldiAmJiBjLmRhdGEpCiAg
ICAgICAgICAgIHByZXYgPSBTdHJpbmcoYy5kYXRhKS5zbGljZSgwLCA1MDApOwogICAgICAgIHJldHVy
biBwcmV2ICsgJyAnICsgU3RyaW5nKGMubGlua1RpdGxlIHx8ICcnKSArICcgJyArIFN0cmluZyhjLmZh
dlRpdGxlIHx8ICcnKTsKICAgIH0KICAgIGZ1bmN0aW9uIGNsaXBNYXRjaGVzU2VhcmNoKGMsIHRlcm1M
KSB7CiAgICAgICAgY29uc3QgdHlwZSA9IFN0cmluZyhjLnR5cGUgfHwgJycpLnRvTG93ZXJDYXNlKCk7
CiAgICAgICAgY29uc3QgaGF5ID0gKHR5cGUgPT09ICdpbWFnZScgPyBTdHJpbmcoYy5mYXZUaXRsZSB8
fCAnJykgOiBjbGlwU2VhcmNoSGF5KGMpKS50b0xvd2VyQ2FzZSgpOwogICAgICAgIHJldHVybiB0ZXJt
TC5ldmVyeSh0ID0+IGhheS5pbmNsdWRlcyh0KSk7CiAgICB9CiAgICBmdW5jdGlvbiBmaWx0ZXIoY2xp
cHMsIHRhYiwgcSkgewogICAgICAgIC8vIOS4u+acuuW3sui/h+a7pOaXtuS7jeWBmuWJjeerr+WFnOW6
le+8mumBv+WFjeernuaAgeaOqOadpeacquWRveS4reihjAogICAgICAgIGNvbnN0IHRlcm1zID0gcXVl
cnlUZXJtcyhxKTsKICAgICAgICBpZiAoIXRlcm1zLmxlbmd0aCkgcmV0dXJuIGNsaXBzOwogICAgICAg
IGNvbnN0IHRlcm1MID0gdGVybXMubWFwKHQgPT4gdC50b0xvd2VyQ2FzZSgpKTsKICAgICAgICBjb25z
dCBtYXRjaGVkR3JvdXBzID0gbmV3IFNldCgpOwogICAgICAgIGZvciAoY29uc3QgYyBvZiBjbGlwcykg
ewogICAgICAgICAgICBpZiAoIWNsaXBNYXRjaGVzU2VhcmNoKGMsIHRlcm1MKSkgY29udGludWU7CiAg
ICAgICAgICAgIGNvbnN0IGdpZCA9IFN0cmluZyhjICYmIGMuZmF2R3JvdXAgfHwgJycpLnRyaW0oKTsK
ICAgICAgICAgICAgaWYgKGdpZCkgbWF0Y2hlZEdyb3Vwcy5hZGQoZ2lkKTsKICAgICAgICB9CiAgICAg
ICAgLy8g5ZCI5bm257uE77ya5YWz6ZSu5a2X5Y+v6IO95YiG5pWj5Zyo5LiN5ZCM6KGM77yI5qCH6aKY
L+ato+aWh++8iQogICAgICAgIGNvbnN0IGJ5R3JvdXAgPSBuZXcgTWFwKCk7CiAgICAgICAgZm9yIChj
b25zdCBjIG9mIGNsaXBzKSB7CiAgICAgICAgICAgIGNvbnN0IGdpZCA9IFN0cmluZyhjICYmIGMuZmF2
R3JvdXAgfHwgJycpLnRyaW0oKTsKICAgICAgICAgICAgaWYgKCFnaWQpIGNvbnRpbnVlOwogICAgICAg
ICAgICBpZiAoIWJ5R3JvdXAuaGFzKGdpZCkpIGJ5R3JvdXAuc2V0KGdpZCwgW10pOwogICAgICAgICAg
ICBieUdyb3VwLmdldChnaWQpLnB1c2goYyk7CiAgICAgICAgfQogICAgICAgIGZvciAoY29uc3QgW2dp
ZCwgbWVtYmVyc10gb2YgYnlHcm91cCkgewogICAgICAgICAgICBpZiAobWF0Y2hlZEdyb3Vwcy5oYXMo
Z2lkKSkgY29udGludWU7CiAgICAgICAgICAgIGNvbnN0IHVuaW9uID0gbWVtYmVycy5tYXAoYyA9PiB7
CiAgICAgICAgICAgICAgICBjb25zdCB0eXBlID0gU3RyaW5nKGMudHlwZSB8fCAnJykudG9Mb3dlckNh
c2UoKTsKICAgICAgICAgICAgICAgIHJldHVybiAodHlwZSA9PT0gJ2ltYWdlJyA/IFN0cmluZyhjLmZh
dlRpdGxlIHx8ICcnKSA6IGNsaXBTZWFyY2hIYXkoYykpLnRvTG93ZXJDYXNlKCk7CiAgICAgICAgICAg
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
ICAgICAgIGxpc3QuZm9yRWFjaChpZCA9PiB7CiAgICAgICAgICAgIGNvbnN0IGMgPSBhbGxDbGlwcy5m
aW5kKHggPT4gK3guaWQgPT09ICtpZCk7CiAgICAgICAgICAgIGlmIChjKSBjLnBhc3RlZCA9IHRydWU7
CiAgICAgICAgICAgIGNvbnN0IGljbyA9IGxpc3RFbC5xdWVyeVNlbGVjdG9yKCcuaXRtW2RhdGEtaWQ9
IicgKyBpZCArICciXSAuaS1pY28nKTsKICAgICAgICAgICAgaWYgKGljbyAmJiAhaWNvLnF1ZXJ5U2Vs
ZWN0b3IoJy5pLXVzZWQnKSkgewogICAgICAgICAgICAgICAgY29uc3QgYmFkZ2UgPSBkb2N1bWVudC5j
cmVhdGVFbGVtZW50KCdzcGFuJyk7CiAgICAgICAgICAgICAgICBiYWRnZS5jbGFzc05hbWUgPSAnaS11
c2VkJzsKICAgICAgICAgICAgICAgIGJhZGdlLnRpdGxlID0gJ+W3sueymOi0tCc7CiAgICAgICAgICAg
ICAgICBiYWRnZS5pbm5lckhUTUwgPSBiYWRnZUh0bWw7CiAgICAgICAgICAgICAgICBpY28uYXBwZW5k
Q2hpbGQoYmFkZ2UpOwogICAgICAgICAgICB9CiAgICAgICAgfSk7CiAgICB9CgogICAgZnVuY3Rpb24g
Y2xlYXJQYXN0ZWRMb2NhbChpZCkgewogICAgICAgIGNvbnN0IGtleSA9IFN0cmluZyhpZCk7CiAgICAg
ICAgY29uc3QgYyA9IGFsbENsaXBzLmZpbmQoeCA9PiAreC5pZCA9PT0gK2lkKTsKICAgICAgICBpZiAo
YykgYy5wYXN0ZWQgPSBmYWxzZTsKICAgICAgICBkb2N1bWVudC5xdWVyeVNlbGVjdG9yQWxsKCcuaXRt
W2RhdGEtaWQ9IicgKyBrZXkgKyAnIl0gLmktdXNlZCcpLmZvckVhY2goZWwgPT4gewogICAgICAgICAg
ICB0cnkgeyBlbC5yZW1vdmUoKTsgfSBjYXRjaCB7fQogICAgICAgIH0pOwogICAgfQoKICAgIGZ1bmN0
aW9uIHBhc3RlTXVsdGlTZWxlY3Rpb24oKSB7CiAgICAgICAgaWYgKCFtdWx0aUlkcy5sZW5ndGgpIHJl
dHVybjsKICAgICAgICBjb25zdCBpZHMgPSBtdWx0aUlkcy5zbGljZSgpOwogICAgICAgIGNsZWFyTXVs
dGkoKTsKICAgICAgICBpZiAoaWRzLnNvbWUoaWQgPT4gewogICAgICAgICAgICBjb25zdCBpdCA9IGFs
bENsaXBzLmZpbmQoeCA9PiAreC5pZCA9PT0gK2lkKTsKICAgICAgICAgICAgcmV0dXJuIGl0ICYmIG5v
cm1UeXBlKGl0LnR5cGUpID09PSAncmVjZW50JzsKICAgICAgICB9KSkgewogICAgICAgICAgICBjb25z
dCBmaXJzdCA9IGFsbENsaXBzLmZpbmQoeCA9PiAreC5pZCA9PT0gK2lkc1swXSk7CiAgICAgICAgICAg
IGlmIChmaXJzdCkgYWN0aXZhdGVDbGlwSXRlbShmaXJzdCk7CiAgICAgICAgICAgIHJldHVybjsKICAg
ICAgICB9CiAgICAgICAgbWFya1Bhc3RlZExvY2FsKGlkcyk7CiAgICAgICAgaWYgKGlkcy5sZW5ndGgg
PiAxKSBwYXN0ZU1hbnlXaXRoU2VwKGlkcywgZmFsc2UpOwogICAgICAgIGVsc2UgYWhrKCdwYXN0ZScs
IFN0cmluZyhpZHNbMF0pKTsKICAgIH0KCiAgICBjb25zdCBsaXN0RWwgID0gZG9jdW1lbnQuZ2V0RWxl
bWVudEJ5SWQoJ2xpc3QnKTsKICAgIGNvbnN0IGVtcHR5RWwgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJ
ZCgnZW1wdHknKTsKICAgIGNvbnN0IHNrZWxFbCAgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc2tl
bCcpOwogICAgY29uc3QgYnRuVG9wICA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdidG4tdG9wJyk7
CiAgICBmdW5jdGlvbiBzZXRCb290TG9hZGluZyhvbikgewogICAgICAgIGJvb3RMb2FkaW5nID0gISFv
bjsKICAgICAgICBpZiAoYm9vdExvYWRpbmcpIHdpbmRvdy5fX3NrZWxTaW5jZSA9IERhdGUubm93KCk7
CiAgICAgICAgaWYgKHNrZWxFbCkgc2tlbEVsLmNsYXNzTGlzdC50b2dnbGUoJ29uJywgYm9vdExvYWRp
bmcpOwogICAgICAgIGlmIChib290TG9hZGluZyAmJiBlbXB0eUVsKSBlbXB0eUVsLmNsYXNzTGlzdC5y
ZW1vdmUoJ29uJyk7CiAgICAgICAgY29uc3QgYXBwID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2Fw
cCcpOwogICAgICAgIGlmIChhcHApIGFwcC5jbGFzc0xpc3QudG9nZ2xlKCdib290LWxvYWRpbmcnLCBi
b290TG9hZGluZyk7CiAgICB9CiAgICAvKiogV2FpdCBmb3IgaG9zdCBkYXRhLiBFbXB0eSBsaXN0IOKG
knNrZWxldG9uIG5vdyAobm8gYmxhbmspLiBIYXMgY29udGVudCDihpJkZWxheS4gKi8KICAgIGZ1bmN0
aW9uIHNjaGVkdWxlRGVsYXllZFNrZWwoKSB7CiAgICAgICAgd2FpdGluZ0RhdGEgPSB0cnVlOwogICAg
ICAgIHdpbmRvdy5fX2RhdGFSZWFkeSA9IGZhbHNlOwogICAgICAgIGlmIChlbXB0eUVsKSBlbXB0eUVs
LmNsYXNzTGlzdC5yZW1vdmUoJ29uJyk7CiAgICAgICAgaWYgKHdpbmRvdy5fX3BlbmRpbmdTa2VsVGlt
ZXIpIHsKICAgICAgICAgICAgY2xlYXJUaW1lb3V0KHdpbmRvdy5fX3BlbmRpbmdTa2VsVGltZXIpOwog
ICAgICAgICAgICB3aW5kb3cuX19wZW5kaW5nU2tlbFRpbWVyID0gMDsKICAgICAgICB9CiAgICAgICAg
d2luZG93Ll9fcGVuZGluZ1NrZWxTaW5jZSA9IERhdGUubm93KCk7CiAgICAgICAgY29uc3QgaGFzUGFp
bnQgPSAoYWxsQ2xpcHMgJiYgYWxsQ2xpcHMubGVuZ3RoID4gMCkKICAgICAgICAgICAgfHwgISEobGlz
dEVsICYmIGxpc3RFbC5xdWVyeVNlbGVjdG9yKCcuaXRtJykpOwogICAgICAgIGlmICghaGFzUGFpbnQp
IHsKICAgICAgICAgICAgLy8gTm90aGluZyBvbiBzY3JlZW4g4oCUc2hvdyBza2VsZXRvbiBpbW1lZGlh
dGVseSBzbyBwYW5lbCBpcyBuZXZlciBibGFuawogICAgICAgICAgICBzZXRCb290TG9hZGluZyh0cnVl
KTsKICAgICAgICAgICAgdHJ5IHsgcmVuZGVyKCk7IH0gY2F0Y2gge30KICAgICAgICAgICAgcmV0dXJu
OwogICAgICAgIH0KICAgICAgICAvLyBBbHJlYWR5IHNob3dpbmcgcm93cyDigJRvbmx5IHN3YXAgdG8g
c2tlbGV0b24gaWYgcmVmcmVzaCBpcyBzbG93CiAgICAgICAgd2luZG93Ll9fcGVuZGluZ1NrZWxUaW1l
ciA9IHNldFRpbWVvdXQoKCkgPT4gewogICAgICAgICAgICB3aW5kb3cuX19wZW5kaW5nU2tlbFRpbWVy
ID0gMDsKICAgICAgICAgICAgaWYgKHdhaXRpbmdEYXRhICYmICF3aW5kb3cuX19kYXRhUmVhZHkpIHsK
ICAgICAgICAgICAgICAgIHNldEJvb3RMb2FkaW5nKHRydWUpOwogICAgICAgICAgICAgICAgdHJ5IHsg
cmVuZGVyKCk7IH0gY2F0Y2gge30KICAgICAgICAgICAgfQogICAgICAgIH0sIFNLRUxfREVMQVlfTVMp
OwogICAgfQogICAgZnVuY3Rpb24gY2xlYXJXYWl0aW5nRGF0YSgpIHsKICAgICAgICB3YWl0aW5nRGF0
YSA9IGZhbHNlOwogICAgICAgIGlmICh3aW5kb3cuX19wZW5kaW5nU2tlbFRpbWVyKSB7CiAgICAgICAg
ICAgIGNsZWFyVGltZW91dCh3aW5kb3cuX19wZW5kaW5nU2tlbFRpbWVyKTsKICAgICAgICAgICAgd2lu
ZG93Ll9fcGVuZGluZ1NrZWxUaW1lciA9IDA7CiAgICAgICAgfQogICAgICAgIHdpbmRvdy5fX3BlbmRp
bmdTa2VsU2luY2UgPSAwOwogICAgICAgIHNldEJvb3RMb2FkaW5nKGZhbHNlKTsKICAgIH0KICAgIHdp
bmRvdy5zZXRCb290TG9hZGluZyA9IHNldEJvb3RMb2FkaW5nOwogICAgd2luZG93LmZvcmNlRW5kQm9v
dExvYWRpbmcgPSBmdW5jdGlvbigpIHsKICAgICAgICBjbGVhcldhaXRpbmdEYXRhKCk7CiAgICAgICAg
Ly8gRG8gbm90IGZha2XjgIzmmoLml6DorrDlvZXjgI1pZiBob3N0IG5ldmVyIHB1c2hlZAogICAgICAg
IGlmIChob3N0UHVzaGVkT25jZSkKICAgICAgICAgICAgd2luZG93Ll9fZGF0YVJlYWR5ID0gdHJ1ZTsK
ICAgICAgICB0cnkgeyByZW5kZXIoKTsgfSBjYXRjaCAoZSkge30KICAgIH07CiAgICAvLyBTYWZldHk6
IGRyb3Agc3R1Y2sgc2tlbGV0b247IHN0aWxsIG5ldmVyIGludmVudCBlbXB0eS1zdGF0ZSB3aXRob3V0
IGhvc3QgcHVzaAogICAgc2V0VGltZW91dCgoKSA9PiB7CiAgICAgICAgaWYgKGhvc3RQdXNoZWRPbmNl
IHx8IHdpbmRvdy5fX2RhdGFSZWFkeSkgcmV0dXJuOwogICAgICAgIGlmICghYm9vdExvYWRpbmcgJiYg
IXdhaXRpbmdEYXRhKSByZXR1cm47CiAgICAgICAgY2xlYXJXYWl0aW5nRGF0YSgpOwogICAgICAgIHRy
eSB7IHJlbmRlcigpOyB9IGNhdGNoIHt9CiAgICB9LCA4MDAwKTsKCiAgICBmdW5jdGlvbiB1cGRhdGVU
b3BCdG4oKSB7CiAgICAgICAgaWYgKCFidG5Ub3AgfHwgIWxpc3RFbCkgcmV0dXJuOwogICAgICAgIGJ0
blRvcC5jbGFzc0xpc3QudG9nZ2xlKCdvbicsIGxpc3RFbC5zY3JvbGxUb3AgPiA0OCk7CiAgICB9CiAg
ICBmdW5jdGlvbiBvbkxpc3RTY3JvbGwoKSB7CiAgICAgICAgaGlkZVBhdGhUaXAoKTsKICAgICAgICB1
cGRhdGVUb3BCdG4oKTsKICAgICAgICBpZiAobG9hZGluZ01vcmUpIHJldHVybjsKICAgICAgICAvLyDo
t53nprvlupXpg6ggMjQwcHgg6Kem5Y+R5Yqg6L295pu05aSa77yM5q+U5Y6f5p2lIDEwMHB4IOabtOeo
s++8m+W/q+mAn+a7muWKqOaXtuS4jeS8mgogICAgICAgIC8vIOi/nue7reinpuWPkSByZXF1ZXN0TW9y
Ze+8iOW3sueUqCBsb2FkaW5nTW9yZSDpmLLph43lhaXvvIzkvYbmraTlpITku43pgb/lhY3mipbliqjv
vInjgIIKICAgICAgICBpZiAobGlzdEVsLnNjcm9sbFRvcCArIGxpc3RFbC5jbGllbnRIZWlnaHQgPj0g
bGlzdEVsLnNjcm9sbEhlaWdodCAtIDI0MCkKICAgICAgICAgICAgcmVxdWVzdE1vcmUoKTsKICAgIH0K
ICAgIGxpc3RFbC5hZGRFdmVudExpc3RlbmVyKCdzY3JvbGwnLCBvbkxpc3RTY3JvbGwsIHsgcGFzc2l2
ZTogdHJ1ZSB9KTsKICAgIGJ0blRvcC5hZGRFdmVudExpc3RlbmVyKCdjbGljaycsIGUgPT4gewogICAg
ICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAgICAgbGlzdEVsLnNjcm9sbFRvKHsgdG9wOiAwLCBi
ZWhhdmlvcjogJ3Ntb290aCcgfSk7CiAgICB9KTsKCiAgICBmdW5jdGlvbiB2aXNpYmxlTGlzdCgpIHsK
ICAgICAgICBjb25zdCBxID0gU3RyaW5nKHF1ZXJ5IHx8ICcnKS50cmltKCk7CiAgICAgICAgLy8gSG9z
dCBhbHJlYWR5IGZpbHRlcmVkK2V4cGFuZGVkIGZvciB0aGlzIGV4YWN0IHF1ZXJ5IOKAlCBkb24ndCBy
ZS1maWx0ZXIgKGF2b2lkcyBmbGFzaCAvIGRyb3BwZWQgZmF2IGdyb3VwcykKICAgICAgICBpZiAocSAm
JiB3aW5kb3cuX19ob3N0RmlsdGVyZWQgJiYgd2luZG93Ll9faG9zdEZpbHRlclEgPT09IHEpCiAgICAg
ICAgICAgIHJldHVybiBhbGxDbGlwczsKICAgICAgICByZXR1cm4gZmlsdGVyKGFsbENsaXBzLCBjdXJU
YWIsIHF1ZXJ5KTsKICAgIH0KICAgIGZ1bmN0aW9uIGVzY0h0bWwocykgewogICAgICAgIHJldHVybiBT
dHJpbmcocyA/PyAnJykucmVwbGFjZSgvJi9nLCcmYW1wOycpLnJlcGxhY2UoLzwvZywnJmx0OycpLnJl
cGxhY2UoLz4vZywnJmd0OycpLnJlcGxhY2UoLyIvZywnJnF1b3Q7Jyk7CiAgICB9CiAgICBmdW5jdGlv
biBxdWVyeVRlcm1zKHEpIHsKICAgICAgICBjb25zdCBvdXQgPSBbXTsKICAgICAgICBmb3IgKGNvbnN0
IHNlZyBvZiBTdHJpbmcocSB8fCAnJykuc3BsaXQoJ3wnKSkgewogICAgICAgICAgICBjb25zdCBzID0g
c2VnLnRyaW0oKTsKICAgICAgICAgICAgaWYgKCFzKSBjb250aW51ZTsKICAgICAgICAgICAgY29uc3Qg
d29yZHMgPSBzLnNwbGl0KC9ccysvKS5maWx0ZXIoQm9vbGVhbik7CiAgICAgICAgICAgIGlmICh3b3Jk
cy5sZW5ndGgpIG91dC5wdXNoKC4uLndvcmRzKTsKICAgICAgICB9CiAgICAgICAgcmV0dXJuIG91dDsK
ICAgIH0KICAgIGZ1bmN0aW9uIGhsSHRtbCh0ZXh0KSB7CiAgICAgICAgY29uc3QgdGVybXMgPSBxdWVy
eVRlcm1zKHF1ZXJ5KTsKICAgICAgICBjb25zdCBzID0gU3RyaW5nKHRleHQgPz8gJycpOwogICAgICAg
IGlmICghdGVybXMubGVuZ3RoKSByZXR1cm4gZXNjSHRtbChzKTsKICAgICAgICBjb25zdCBsb3dlciA9
IHMudG9Mb3dlckNhc2UoKTsKICAgICAgICBjb25zdCB0ZXJtTCA9IHRlcm1zLm1hcCh0ID0+IHQudG9M
b3dlckNhc2UoKSk7CiAgICAgICAgbGV0IG91dCA9ICcnLCBpID0gMDsKICAgICAgICB3aGlsZSAoaSA8
IHMubGVuZ3RoKSB7CiAgICAgICAgICAgIGxldCBiZXN0SiA9IC0xLCBiZXN0TGVuID0gMDsKICAgICAg
ICAgICAgZm9yIChsZXQgdGkgPSAwOyB0aSA8IHRlcm1MLmxlbmd0aDsgdGkrKykgewogICAgICAgICAg
ICAgICAgY29uc3QgdCA9IHRlcm1MW3RpXTsKICAgICAgICAgICAgICAgIGlmICghdCkgY29udGludWU7
CiAgICAgICAgICAgICAgICBjb25zdCBqID0gbG93ZXIuaW5kZXhPZih0LCBpKTsKICAgICAgICAgICAg
ICAgIGlmIChqIDwgMCkgY29udGludWU7CiAgICAgICAgICAgICAgICBpZiAoYmVzdEogPCAwIHx8IGog
PCBiZXN0SiB8fCAoaiA9PT0gYmVzdEogJiYgdC5sZW5ndGggPiBiZXN0TGVuKSkgewogICAgICAgICAg
ICAgICAgICAgIGJlc3RKID0gajsgYmVzdExlbiA9IHQubGVuZ3RoOwogICAgICAgICAgICAgICAgfQog
ICAgICAgICAgICB9CiAgICAgICAgICAgIGlmIChiZXN0SiA8IDApIHsgb3V0ICs9IGVzY0h0bWwocy5z
bGljZShpKSk7IGJyZWFrOyB9CiAgICAgICAgICAgIG91dCArPSBlc2NIdG1sKHMuc2xpY2UoaSwgYmVz
dEopKTsKICAgICAgICAgICAgb3V0ICs9ICc8bWFyayBjbGFzcz0icS1obCI+JyArIGVzY0h0bWwocy5z
bGljZShiZXN0SiwgYmVzdEogKyBiZXN0TGVuKSkgKyAnPC9tYXJrPic7CiAgICAgICAgICAgIGkgPSBi
ZXN0SiArIE1hdGgubWF4KDEsIGJlc3RMZW4pOwogICAgICAgIH0KICAgICAgICByZXR1cm4gb3V0Owog
ICAgfQogICAgZnVuY3Rpb24gc2V0SGxUZXh0KGVsLCB0ZXh0KSB7CiAgICAgICAgaWYgKCFlbCkgcmV0
dXJuOwogICAgICAgIGNvbnN0IHEgPSBTdHJpbmcocXVlcnkgfHwgJycpLnRyaW0oKTsKICAgICAgICBp
ZiAoIXEpIHsKICAgICAgICAgICAgZWwuY2xhc3NMaXN0LnJlbW92ZSgnaGFzLWhsJyk7CiAgICAgICAg
ICAgIGVsLnRleHRDb250ZW50ID0gdGV4dCA9PSBudWxsID8gJycgOiBTdHJpbmcodGV4dCk7CiAgICAg
ICAgICAgIHJldHVybjsKICAgICAgICB9CiAgICAgICAgZWwuY2xhc3NMaXN0LmFkZCgnaGFzLWhsJyk7
CiAgICAgICAgZWwuaW5uZXJIVE1MID0gaGxIdG1sKHRleHQpOwogICAgfQoKCiAgICBmdW5jdGlvbiBh
cHBseVRhYlN3aXRjaEFuaW0oKSB7CiAgICAgICAgaWYgKCF0YWJTd2l0Y2hBbmltRGlyIHx8ICFsaXN0
RWwpIHJldHVybjsKICAgICAgICBpZiAoIWxpc3RFbC5xdWVyeVNlbGVjdG9yKCcuaXRtLCAjZW1wdHku
b24sICNsaXN0LW1vcmUnKSkKICAgICAgICAgICAgcmV0dXJuOwogICAgICAgIGNvbnN0IGRpciA9IHRh
YlN3aXRjaEFuaW1EaXI7CiAgICAgICAgdGFiU3dpdGNoQW5pbURpciA9IDA7CiAgICAgICAgbGlzdEVs
LmNsYXNzTGlzdC5yZW1vdmUoJ3RhYi1pbi1scicsICd0YWItaW4tcmwnKTsKICAgICAgICB2b2lkIGxp
c3RFbC5vZmZzZXRXaWR0aDsKICAgICAgICBsaXN0RWwuY2xhc3NMaXN0LmFkZChkaXIgPiAwID8gJ3Rh
Yi1pbi1scicgOiAndGFiLWluLXJsJyk7CiAgICAgICAgY2xlYXJUaW1lb3V0KGxpc3RFbC5fdGFiQW5p
bVRpbWVyKTsKICAgICAgICBsaXN0RWwuX3RhYkFuaW1UaW1lciA9IHNldFRpbWVvdXQoKCkgPT4gewog
ICAgICAgICAgICBsaXN0RWwuY2xhc3NMaXN0LnJlbW92ZSgndGFiLWluLWxyJywgJ3RhYi1pbi1ybCcp
OwogICAgICAgIH0sIDQwMCk7CiAgICB9CgogICAgZnVuY3Rpb24gdGFiSW5kZXgodGFiKSB7CiAgICAg
ICAgY29uc3QgaSA9IFRBQl9PUkRFUi5pbmRleE9mKHRhYik7CiAgICAgICAgcmV0dXJuIGkgPj0gMCA/
IGkgOiAwOwogICAgfQoKICAgIGZ1bmN0aW9uIG1vdmVUYWJJbmsoaW5zdGFudCwgdGFyZ2V0RWwpIHsK
ICAgICAgICBjb25zdCBpbmsgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgndGFiLWluaycpOwogICAg
ICAgIGNvbnN0IHRhYnMgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgndGFicycpOwogICAgICAgIGNv
bnN0IGVsID0gdGFyZ2V0RWwgfHwgZG9jdW1lbnQucXVlcnlTZWxlY3RvcignI3RhYnMgLnRhYi5vbicp
OwogICAgICAgIGlmICghaW5rIHx8ICF0YWJzIHx8ICFlbCkgcmV0dXJuOwogICAgICAgIGNvbnN0IHRy
ID0gdGFicy5nZXRCb3VuZGluZ0NsaWVudFJlY3QoKTsKICAgICAgICBjb25zdCByID0gZWwuZ2V0Qm91
bmRpbmdDbGllbnRSZWN0KCk7CiAgICAgICAgY29uc3QgeCA9IHIubGVmdCAtIHRyLmxlZnQ7CiAgICAg
ICAgY29uc3QgaCA9IE1hdGgubWF4KDIwLCBNYXRoLnJvdW5kKHIuaGVpZ2h0KSk7CiAgICAgICAgY29u
c3QgeSA9IHIudG9wIC0gdHIudG9wOwogICAgICAgIGNvbnN0IHcgPSBNYXRoLm1heCgyNCwgci53aWR0
aCk7CiAgICAgICAgY29uc3QgcG9zID0gJ3RyYW5zbGF0ZTNkKCcgKyB4ICsgJ3B4LCcgKyB5ICsgJ3B4
LDApJzsKICAgICAgICBpbmsuc3R5bGUudHJhbnNmb3JtT3JpZ2luID0gJ2NlbnRlciBib3R0b20nOwog
ICAgICAgIGluay5zdHlsZS53aWR0aCA9IHcgKyAncHgnOwogICAgICAgIGluay5zdHlsZS5oZWlnaHQg
PSBoICsgJ3B4JzsKICAgICAgICBpZiAoaW5zdGFudCkgewogICAgICAgICAgICBpbmsuc3R5bGUudHJh
bnNpdGlvbiA9ICdub25lJzsKICAgICAgICAgICAgaW5rLmNsYXNzTGlzdC5yZW1vdmUoJ3NxdWFzaCcp
OwogICAgICAgICAgICBpbmsuc3R5bGUudHJhbnNmb3JtID0gcG9zICsgJyBzY2FsZVgoMSknOwogICAg
ICAgICAgICBpbmsub2Zmc2V0SGVpZ2h0OwogICAgICAgICAgICBpbmsuc3R5bGUudHJhbnNpdGlvbiA9
ICcnOwogICAgICAgICAgICByZXR1cm47CiAgICAgICAgfQogICAgICAgIC8vIFNuYXAgdG8gaG92ZXJl
ZCB0YWIsIGV4cGFuZCBmcm9tIGJvdHRvbS1jZW50ZXIg4oCUIG5vIHNsaWRpbmcgYmV0d2VlbiB0YWJz
CiAgICAgICAgaW5rLnN0eWxlLnRyYW5zaXRpb24gPSAnbm9uZSc7CiAgICAgICAgaW5rLnN0eWxlLnRy
YW5zZm9ybSA9IHBvcyArICcgc2NhbGVYKDAuMDAxKSc7CiAgICAgICAgaW5rLm9mZnNldEhlaWdodDsK
ICAgICAgICBpbmsuc3R5bGUudHJhbnNpdGlvbiA9ICcnOwogICAgICAgIGluay5jbGFzc0xpc3QuYWRk
KCdzcXVhc2gnKTsKICAgICAgICBpbmsuc3R5bGUudHJhbnNmb3JtID0gcG9zICsgJyBzY2FsZVgoMSkn
OwogICAgICAgIGNsZWFyVGltZW91dChpbmsuX3NxdWFzaFRpbWVyKTsKICAgICAgICBpbmsuX3NxdWFz
aFRpbWVyID0gc2V0VGltZW91dCgoKSA9PiBpbmsuY2xhc3NMaXN0LnJlbW92ZSgnc3F1YXNoJyksIDM0
MCk7CiAgICB9CiAgICBmdW5jdGlvbiBtYXJrVGFiKHRhYiwgaW5zdGFudCkgewogICAgICAgIGRvY3Vt
ZW50LnF1ZXJ5U2VsZWN0b3JBbGwoJyN0YWJzIC50YWInKS5mb3JFYWNoKGVsID0+CiAgICAgICAgICAg
IGVsLmNsYXNzTGlzdC50b2dnbGUoJ29uJywgZWwuZGF0YXNldC50YWIgPT09IHRhYikpOwogICAgICAg
IG1vdmVUYWJJbmsoISFpbnN0YW50KTsKICAgIH0KICAgIGZ1bmN0aW9uIGJpbmRUYWJJbmtIb3Zlcigp
IHsKICAgICAgICBjb25zdCB0YWJzID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3RhYnMnKTsKICAg
ICAgICBpZiAoIXRhYnMgfHwgdGFicy5faW5rSG92ZXJCb3VuZCkgcmV0dXJuOwogICAgICAgIHRhYnMu
X2lua0hvdmVyQm91bmQgPSB0cnVlOwogICAgICAgIHRhYnMuYWRkRXZlbnRMaXN0ZW5lcigncG9pbnRl
cm92ZXInLCBlID0+IHsKICAgICAgICAgICAgY29uc3QgdGFiID0gZS50YXJnZXQuY2xvc2VzdCgnLnRh
YicpOwogICAgICAgICAgICBpZiAoIXRhYiB8fCAhdGFicy5jb250YWlucyh0YWIpKSByZXR1cm47CiAg
ICAgICAgICAgIG1vdmVUYWJJbmsoZmFsc2UsIHRhYik7CiAgICAgICAgfSk7CiAgICAgICAgdGFicy5h
ZGRFdmVudExpc3RlbmVyKCdwb2ludGVybGVhdmUnLCBlID0+IHsKICAgICAgICAgICAgaWYgKGUucmVs
YXRlZFRhcmdldCAmJiB0YWJzLmNvbnRhaW5zKGUucmVsYXRlZFRhcmdldCkpIHJldHVybjsKICAgICAg
ICAgICAgbW92ZVRhYkluayhmYWxzZSk7CiAgICAgICAgfSk7CiAgICB9CmZ1bmN0aW9uIHNldFRhYih0
YWIpIHsKICAgICAgICBpZiAodGFiID09PSBjdXJUYWIpIHJldHVybjsKICAgICAgICBjb25zdCBmcm9t
ID0gdGFiSW5kZXgoY3VyVGFiKTsKICAgICAgICBjb25zdCB0byA9IHRhYkluZGV4KHRhYik7CiAgICAg
ICAgdGFiU3dpdGNoQW5pbURpciA9IHRvID4gZnJvbSA/IDEgOiAodG8gPCBmcm9tID8gLTEgOiAwKTsK
ICAgICAgICBjdXJUYWIgPSB0YWI7CiAgICAgICAgbG9hZGluZ01vcmUgPSBmYWxzZTsKICAgICAgICBt
YXJrVGFiKHRhYik7CgogICAgICAgIC8vIEtlZXAgc2VhcmNoICJ0b2RheSIgZmlsdGVyIGluIHN5bmMg
d2hlbiBzZWFyY2ggaXMgb3BlbgogICAgICAgIHRyeSB7CiAgICAgICAgICAgIGNvbnN0IHdyYXAgPSBk
b2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc2VhcmNoLXdyYXAnKTsKICAgICAgICAgICAgY29uc3QgYnRu
VG9kYXkgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYnRuLXRvZGF5Jyk7CiAgICAgICAgICAgIGlm
ICh3cmFwICYmIHdyYXAuY2xhc3NMaXN0LmNvbnRhaW5zKCdvcGVuJykpIHsKICAgICAgICAgICAgICAg
IGNvbnN0IHdhbnRUb2RheSA9IGZhbHNlOwogICAgICAgICAgICAgICAgaWYgKHRvZGF5T25seSAhPT0g
d2FudFRvZGF5KSB7CiAgICAgICAgICAgICAgICAgICAgdG9kYXlPbmx5ID0gd2FudFRvZGF5OwogICAg
ICAgICAgICAgICAgICAgIGlmIChidG5Ub2RheSkgYnRuVG9kYXkuY2xhc3NMaXN0LnRvZ2dsZSgnb24n
LCB0b2RheU9ubHkpOwogICAgICAgICAgICAgICAgfQogICAgICAgICAgICB9CiAgICAgICAgfSBjYXRj
aCB7fQoKICAgICAgICBzZWxlY3RlZElkID0gbnVsbDsKICAgICAgICBtdWx0aUlkcyA9IFtdOwogICAg
ICAgIGxpc3RFbC5zY3JvbGxUb3AgPSAwOwogICAgICAgIGNvbnN0IGhpdCA9IHZpZXdNZW0uZ2V0KHZp
ZXdNZW1LZXkodGFiLCBxdWVyeSwgdG9kYXlPbmx5KSk7CiAgICAgICAgaWYgKGhpdCAmJiBBcnJheS5p
c0FycmF5KGhpdC5pdGVtcykgJiYgaGl0Lml0ZW1zLmxlbmd0aCkgewogICAgICAgICAgICBhbGxDbGlw
cyA9IGhpdC5pdGVtcy5zbGljZSgpOwogICAgICAgICAgICBkaXNrVG90YWwgPSBOdW1iZXIoaGl0LnRv
dGFsKSB8fCBoaXQuaXRlbXMubGVuZ3RoOwogICAgICAgICAgICB3aW5kb3cuX193YWl0aW5nVmlldyA9
IGZhbHNlOwogICAgICAgICAgICBjbGVhcldhaXRpbmdEYXRhKCk7CiAgICAgICAgICAgIHdpbmRvdy5f
X2RhdGFSZWFkeSA9IHRydWU7CiAgICAgICAgICAgIGhvc3RQdXNoZWRPbmNlID0gdHJ1ZTsKICAgICAg
ICAgICAgc2F3Tm9uRW1wdHkgPSB0cnVlOwogICAgICAgICAgICByZW5kZXIoKTsKICAgICAgICAgICAg
YXBwbHlUYWJTd2l0Y2hBbmltKCk7CiAgICAgICAgICAgIC8vIE1lbW9yeSBwYWludCBmaXJzdCDigJRi
YWNrZ3JvdW5kIHNvZnQtc3luYyBrZWVwcyBBSEsgaW4gc3RlcCB3aXRob3V0IGRvdWJsZSByZWRyYXcK
ICAgICAgICAgICAgc29mdFJlcXVlc3RWaWV3KCk7CiAgICAgICAgICAgIHJldHVybjsKICAgICAgICB9
CiAgICAgICAgYWxsQ2xpcHMgPSBbXTsKICAgICAgICBkaXNrVG90YWwgPSAwOwogICAgICAgIHdpbmRv
dy5fX3dhaXRpbmdWaWV3ID0gdHJ1ZTsKICAgICAgICBzY2hlZHVsZURlbGF5ZWRTa2VsKCk7CiAgICAg
ICAgcmVxdWVzdFZpZXcoKTsKICAgICAgICByZW5kZXIoKTsKICAgICAgICBhcHBseVRhYlN3aXRjaEFu
aW0oKTsKICAgIH0KCiAgICBtb3ZlVGFiSW5rKHRydWUpOwogICAgYmluZFRhYklua0hvdmVyKCk7CiAg
ICB0cnkgeyBuZXcgUmVzaXplT2JzZXJ2ZXIoKCkgPT4gbW92ZVRhYkluayh0cnVlKSkub2JzZXJ2ZShk
b2N1bWVudC5nZXRFbGVtZW50QnlJZCgndGFicycpKTsgfSBjYXRjaCB7fQogICAgd2luZG93LmFkZEV2
ZW50TGlzdGVuZXIoJ3Jlc2l6ZScsICgpID0+IG1vdmVUYWJJbmsodHJ1ZSkpOwoKICAgIGZ1bmN0aW9u
IHVwZGF0ZU1vcmVGb290ZXIodG90YWwpIHsKICAgICAgICBsZXQgbW9yZUVsID0gZG9jdW1lbnQuZ2V0
RWxlbWVudEJ5SWQoJ2xpc3QtbW9yZScpOwogICAgICAgIGNvbnN0IGxvYWRlZCA9IGFsbENsaXBzLmxl
bmd0aDsKICAgICAgICBpZiAobG9hZGVkID49IHRvdGFsKSB7CiAgICAgICAgICAgIGlmIChtb3JlRWwp
IG1vcmVFbC5yZW1vdmUoKTsKICAgICAgICAgICAgcmV0dXJuOwogICAgICAgIH0KICAgICAgICBpZiAo
IW1vcmVFbCkgewogICAgICAgICAgICBtb3JlRWwgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYn
KTsKICAgICAgICAgICAgbW9yZUVsLmlkID0gJ2xpc3QtbW9yZSc7CiAgICAgICAgICAgIG1vcmVFbC5j
bGFzc05hbWUgPSAnbGlzdC1tb3JlJzsKICAgICAgICAgICAgbGlzdEVsLmFwcGVuZENoaWxkKG1vcmVF
bCk7CiAgICAgICAgfQogICAgICAgIG1vcmVFbC50ZXh0Q29udGVudCA9ICfnu6fnu63kuIvmu5Hku47n
o4Hnm5jliqDovb3vvIgnICsgbG9hZGVkICsgJy8nICsgdG90YWwgKyAn77yJJzsKICAgIH0KCiAgICBm
dW5jdGlvbiBuYXZMaXN0KCkgewogICAgICAgIGNvbnN0IGJsb2NrcyA9IGJ1aWxkUGlubmVkQmxvY2tz
KHZpc2libGVMaXN0KCkpOwogICAgICAgIGNvbnN0IG91dCA9IFtdOwogICAgICAgIGZvciAoY29uc3Qg
YiBvZiBibG9ja3MpIHsKICAgICAgICAgICAgaWYgKCFiIHx8ICFiLml0ZW1zKSBjb250aW51ZTsKICAg
ICAgICAgICAgZm9yIChjb25zdCBjIG9mIGIuaXRlbXMpIG91dC5wdXNoKGMpOwogICAgICAgIH0KICAg
ICAgICByZXR1cm4gb3V0OwogICAgfQoKICAgIGZ1bmN0aW9uIHNlbGVjdEJ5SW5kZXgoaWR4KSB7CiAg
ICAgICAgY29uc3QgdmlzID0gbmF2TGlzdCgpOwogICAgICAgIGlmICghdmlzLmxlbmd0aCkgcmV0dXJu
OwogICAgICAgIGlkeCA9IE1hdGgubWF4KDAsIE1hdGgubWluKHZpcy5sZW5ndGggLSAxLCBpZHgpKTsK
ICAgICAgICBpZiAoaWR4ID49IHZpcy5sZW5ndGggLSAxICYmIGFsbENsaXBzLmxlbmd0aCA8IGRpc2tU
b3RhbCkKICAgICAgICAgICAgcmVxdWVzdE1vcmUoKTsKICAgICAgICBzZWxlY3RlZElkID0gdmlzW01h
dGgubWluKGlkeCwgdmlzLmxlbmd0aCAtIDEpXS5pZDsKICAgICAgICByYW5nZUFuY2hvcklkID0gc2Vs
ZWN0ZWRJZDsKICAgICAgICByYW5nZUFuY2hvckNsaWNrZWQgPSBmYWxzZTsKICAgICAgICBpZiAoK3Nl
bGVjdGVkSWQgIT09ICtsYXN0UGFzdGVJZCkKICAgICAgICAgICAgbG9jYXRlQWN0aXZlID0gZmFsc2U7
CiAgICAgICAgdXBkYXRlTG9jYXRlQnRuKCk7CiAgICAgICAgc3luY0l0ZW1IaWdobGlnaHQoKTsKICAg
ICAgICBjb25zdCBlbCA9IGxpc3RFbC5xdWVyeVNlbGVjdG9yKCcubWctcm93W2RhdGEtaWQ9IicgKyBz
ZWxlY3RlZElkICsgJyJdJykKICAgICAgICAgICAgfHwgbGlzdEVsLnF1ZXJ5U2VsZWN0b3IoJy5pdG1b
ZGF0YS1pZD0iJyArIHNlbGVjdGVkSWQgKyAnIl0nKTsKICAgICAgICBpZiAoZWwpIGVsLnNjcm9sbElu
dG9WaWV3KHsgYmxvY2s6ICduZWFyZXN0JyB9KTsKICAgIH0KCiAgICBmdW5jdGlvbiBzZWxlY3RlZElu
ZGV4KCkgewogICAgICAgIHJldHVybiBuYXZMaXN0KCkuZmluZEluZGV4KGMgPT4gYy5pZCA9PSBzZWxl
Y3RlZElkKTsKICAgIH0KCiAgICBmdW5jdGlvbiBzeW5jSXRlbUhpZ2hsaWdodCgpIHsKICAgICAgICBj
b25zdCBtdWx0aU9uID0gbXVsdGlJZHMubGVuZ3RoID4gMDsKICAgICAgICBjb25zdCBpbk11bHRpSWQg
PSBpZCA9PiBtdWx0aUlkcy5zb21lKHggPT4gK3ggPT09ICtpZCk7CiAgICAgICAgZG9jdW1lbnQucXVl
cnlTZWxlY3RvckFsbCgnLml0bScpLmZvckVhY2gobiA9PiB7CiAgICAgICAgICAgIGlmIChuLmNsYXNz
TGlzdC5jb250YWlucygnaXQtZ3JvdXAnKSkgewogICAgICAgICAgICAgICAgY29uc3Qgcm93cyA9IFsu
Li5uLnF1ZXJ5U2VsZWN0b3JBbGwoJy5tZy1yb3cnKV07CiAgICAgICAgICAgICAgICBjb25zdCBpZHMg
PSByb3dzLm1hcChyID0+ICtyLmRhdGFzZXQuaWQpOwogICAgICAgICAgICAgICAgY29uc3QgYW55U2Vs
ID0gbXVsdGlPbgogICAgICAgICAgICAgICAgICAgID8gaWRzLnNvbWUoaWQgPT4gaW5NdWx0aUlkKGlk
KSkKICAgICAgICAgICAgICAgICAgICA6IGlkcy5pbmNsdWRlcygrc2VsZWN0ZWRJZCk7CiAgICAgICAg
ICAgICAgICBuLmNsYXNzTGlzdC50b2dnbGUoJ3NlbCcsIGFueVNlbCk7CiAgICAgICAgICAgICAgICBu
LmNsYXNzTGlzdC50b2dnbGUoJ211bHRpJywgaWRzLnNvbWUoaWQgPT4gaW5NdWx0aUlkKGlkKSkpOwog
ICAgICAgICAgICAgICAgcm93cy5mb3JFYWNoKHIgPT4gewogICAgICAgICAgICAgICAgICAgIGNvbnN0
IGlkID0gK3IuZGF0YXNldC5pZDsKICAgICAgICAgICAgICAgICAgICBjb25zdCBpbk11bHRpID0gaW5N
dWx0aUlkKGlkKTsKICAgICAgICAgICAgICAgICAgICBjb25zdCBzaG93U2VsID0gbXVsdGlPbiA/IGlu
TXVsdGkgOiAoaWQgPT0gc2VsZWN0ZWRJZCk7CiAgICAgICAgICAgICAgICAgICAgci5jbGFzc0xpc3Qu
dG9nZ2xlKCdzZWwnLCBzaG93U2VsKTsKICAgICAgICAgICAgICAgICAgICByLmNsYXNzTGlzdC50b2dn
bGUoJ211bHRpJywgaW5NdWx0aSk7CiAgICAgICAgICAgICAgICB9KTsKICAgICAgICAgICAgICAgIHJl
dHVybjsKICAgICAgICAgICAgfQogICAgICAgICAgICBjb25zdCBpZCA9ICtuLmRhdGFzZXQuaWQ7CiAg
ICAgICAgICAgIGNvbnN0IGluTXVsdGkgPSBpbk11bHRpSWQoaWQpOwogICAgICAgICAgICBjb25zdCBz
aG93U2VsID0gbXVsdGlPbiA/IGluTXVsdGkgOiAoaWQgPT0gc2VsZWN0ZWRJZCk7CiAgICAgICAgICAg
IG4uY2xhc3NMaXN0LnRvZ2dsZSgnc2VsJywgc2hvd1NlbCk7CiAgICAgICAgICAgIG4uY2xhc3NMaXN0
LnRvZ2dsZSgnbXVsdGknLCBpbk11bHRpKTsKICAgICAgICB9KTsKICAgIH0KICAgIGZ1bmN0aW9uIHVw
ZGF0ZU11bHRpQmFkZ2UoKSB7CiAgICAgICAgY29uc3QgYmFyID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5
SWQoJ211bHRpLWJhcicpOwogICAgICAgIGNvbnN0IGVsID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQo
J211bHRpLWNudCcpOwogICAgICAgIGNvbnN0IG9uID0gbXVsdGlJZHMubGVuZ3RoID4gMDsKICAgICAg
ICBpZiAob24pIHsKICAgICAgICAgICAgaWYgKCFtdWx0aUJhcldhc09uKSByZXNldFBhc3RlU2VwRGVm
YXVsdCgpOwogICAgICAgICAgICBlbC50ZXh0Q29udGVudCA9ICflt7LpgIknICsgbXVsdGlJZHMubGVu
Z3RoOwogICAgICAgICAgICBiYXIuY2xhc3NMaXN0LmFkZCgnb24nKTsKICAgICAgICB9IGVsc2Ugewog
ICAgICAgICAgICBiYXIuY2xhc3NMaXN0LnJlbW92ZSgnb24nKTsKICAgICAgICAgICAgY2xvc2VTZXBN
ZW51KCk7CiAgICAgICAgfQogICAgICAgIG11bHRpQmFyV2FzT24gPSBvbjsKICAgICAgICBzeW5jSXRl
bUhpZ2hsaWdodCgpOwogICAgfQoKICAgIGZ1bmN0aW9uIGNsZWFyTXVsdGkocmVzdG9yZVRvQW5jaG9y
KSB7CiAgICAgICAgY29uc3QgYmFja0lkID0gK3JhbmdlQW5jaG9ySWQgfHwgMDsKICAgICAgICBtdWx0
aUlkcyA9IFtdOwogICAgICAgIGlmIChyZXN0b3JlVG9BbmNob3IgJiYgYmFja0lkKQogICAgICAgICAg
ICBzZWxlY3RlZElkID0gYmFja0lkOwogICAgICAgIHJhbmdlQW5jaG9ySWQgPSBzZWxlY3RlZElkIHx8
IDA7CiAgICAgICAgcmFuZ2VBbmNob3JDbGlja2VkID0gZmFsc2U7CiAgICAgICAgdXBkYXRlTXVsdGlC
YWRnZSgpOwogICAgICAgIGlmIChyZXN0b3JlVG9BbmNob3IgJiYgc2VsZWN0ZWRJZCkgewogICAgICAg
ICAgICBjb25zdCBlbCA9IGxpc3RFbC5xdWVyeVNlbGVjdG9yKCcubWctcm93W2RhdGEtaWQ9IicgKyBz
ZWxlY3RlZElkICsgJyJdJykKICAgICAgICAgICAgICAgIHx8IGxpc3RFbC5xdWVyeVNlbGVjdG9yKCcu
aXRtW2RhdGEtaWQ9IicgKyBzZWxlY3RlZElkICsgJyJdJyk7CiAgICAgICAgICAgIGlmIChlbCkgZWwu
c2Nyb2xsSW50b1ZpZXcoeyBibG9jazogJ25lYXJlc3QnIH0pOwogICAgICAgIH0KICAgIH0KCgogICAg
Lyogc2hpZnQtcmFuZ2Utc2VsZWN0LXYxICovCiAgICBsZXQgcmFuZ2VBbmNob3JJZCA9IDA7CiAgICBs
ZXQgcmFuZ2VBbmNob3JDbGlja2VkID0gZmFsc2U7CgogICAgZnVuY3Rpb24gZ2V0Rmlyc3RTZWxlY3Rl
ZExpc3RJZChsaXN0KSB7CiAgICAgICAgY29uc3QgcGlja2VkID0gbmV3IFNldCgpOwogICAgICAgIGlm
IChzZWxlY3RlZElkKSBwaWNrZWQuYWRkKCtzZWxlY3RlZElkKTsKICAgICAgICBmb3IgKGNvbnN0IGlk
IG9mIG11bHRpSWRzKSBwaWNrZWQuYWRkKCtpZCk7CiAgICAgICAgaWYgKCFwaWNrZWQuc2l6ZSkgcmV0
dXJuIDA7CiAgICAgICAgZm9yIChjb25zdCBjIG9mIGxpc3QpIHsKICAgICAgICAgICAgaWYgKHBpY2tl
ZC5oYXMoK2MuaWQpKSByZXR1cm4gK2MuaWQ7CiAgICAgICAgfQogICAgICAgIHJldHVybiAwOwogICAg
fQoKICAgIGZ1bmN0aW9uIHNlbGVjdFJhbmdlVG8oaWQpIHsKICAgICAgICBpZCA9ICtpZDsKICAgICAg
ICBjb25zdCBsaXN0ID0gKHR5cGVvZiBuYXZMaXN0ID09PSAnZnVuY3Rpb24nID8gbmF2TGlzdCgpIDog
dmlzaWJsZUxpc3QoKSk7CiAgICAgICAgY29uc3QgYiA9IGxpc3QuZmluZEluZGV4KGMgPT4gK2MuaWQg
PT09IGlkKTsKICAgICAgICBpZiAoYiA8IDApIHJldHVybjsKICAgICAgICBsZXQgYW5jaG9yID0gK3Jh
bmdlQW5jaG9ySWQ7CiAgICAgICAgbGV0IGEgPSBsaXN0LmZpbmRJbmRleChjID0+ICtjLmlkID09PSBh
bmNob3IpOwogICAgICAgIGlmIChhIDwgMCkgewogICAgICAgICAgICBhbmNob3IgPSBnZXRGaXJzdFNl
bGVjdGVkTGlzdElkKGxpc3QpIHx8ICtzZWxlY3RlZElkIHx8IGlkOwogICAgICAgICAgICBhID0gbGlz
dC5maW5kSW5kZXgoYyA9PiArYy5pZCA9PT0gYW5jaG9yKTsKICAgICAgICB9CiAgICAgICAgaWYgKGEg
PCAwKSB7CiAgICAgICAgICAgIHJhbmdlQW5jaG9ySWQgPSBpZDsgc2VsZWN0ZWRJZCA9IGlkOyBtdWx0
aUlkcyA9IFtpZF07IHVwZGF0ZU11bHRpQmFkZ2UoKTsgcmV0dXJuOwogICAgICAgIH0KICAgICAgICBy
YW5nZUFuY2hvcklkID0gK2xpc3RbYV0uaWQ7CiAgICAgICAgY29uc3QgbG8gPSBNYXRoLm1pbihhLCBi
KSwgaGkgPSBNYXRoLm1heChhLCBiKTsKICAgICAgICBtdWx0aUlkcyA9IFtdOwogICAgICAgIGZvciAo
bGV0IGkgPSBsbzsgaSA8PSBoaTsgaSsrKSBtdWx0aUlkcy5wdXNoKCtsaXN0W2ldLmlkKTsKICAgICAg
ICBzZWxlY3RlZElkID0gaWQ7CiAgICAgICAgdXBkYXRlTXVsdGlCYWRnZSgpOwogICAgICAgIGNvbnN0
IGVsID0gbGlzdEVsLnF1ZXJ5U2VsZWN0b3IoJy5tZy1yb3dbZGF0YS1pZD0iJyArIHNlbGVjdGVkSWQg
KyAnIl0nKSB8fCBsaXN0RWwucXVlcnlTZWxlY3RvcignLml0bVtkYXRhLWlkPSInICsgc2VsZWN0ZWRJ
ZCArICciXScpOwogICAgICAgIGlmIChlbCkgZWwuc2Nyb2xsSW50b1ZpZXcoeyBibG9jazogJ25lYXJl
c3QnIH0pOwogICAgfQogICAgZnVuY3Rpb24gc2hvd1NyY1RpcChhbmNob3IsIHRleHQpIHsKICAgICAg
ICB0ZXh0ID0gU3RyaW5nKHRleHQgfHwgJycpLnRyaW0oKTsKICAgICAgICBpZiAoIXRleHQpIHJldHVy
bjsKICAgICAgICBsZXQgdGlwID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NyYy10aXAnKTsKICAg
ICAgICBpZiAoIXRpcCkgewogICAgICAgICAgICB0aXAgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdk
aXYnKTsKICAgICAgICAgICAgdGlwLmlkID0gJ3NyYy10aXAnOwogICAgICAgICAgICBkb2N1bWVudC5i
b2R5LmFwcGVuZENoaWxkKHRpcCk7CiAgICAgICAgfQogICAgICAgIHRpcC50ZXh0Q29udGVudCA9IHRl
eHQ7CiAgICAgICAgdGlwLmNsYXNzTGlzdC5hZGQoJ3Nob3cnKTsKICAgICAgICBjb25zdCByID0gYW5j
aG9yLmdldEJvdW5kaW5nQ2xpZW50UmVjdCgpOwogICAgICAgIGNvbnN0IHR3ID0gdGlwLm9mZnNldFdp
ZHRoIHx8IDE2MDsKICAgICAgICBjb25zdCB0aCA9IHRpcC5vZmZzZXRIZWlnaHQgfHwgMjg7CiAgICAg
ICAgbGV0IGxlZnQgPSByLnJpZ2h0IC0gdHc7CiAgICAgICAgbGV0IHRvcCA9IHIudG9wIC0gdGggLSA4
OwogICAgICAgIGlmIChsZWZ0IDwgOCkgbGVmdCA9IDg7CiAgICAgICAgaWYgKGxlZnQgKyB0dyA+IHdp
bmRvdy5pbm5lcldpZHRoIC0gOCkgbGVmdCA9IHdpbmRvdy5pbm5lcldpZHRoIC0gdHcgLSA4OwogICAg
ICAgIGlmICh0b3AgPCA4KSB0b3AgPSByLmJvdHRvbSArIDg7CiAgICAgICAgdGlwLnN0eWxlLmxlZnQg
PSBsZWZ0ICsgJ3B4JzsKICAgICAgICB0aXAuc3R5bGUudG9wID0gdG9wICsgJ3B4JzsKICAgICAgICBj
bGVhclRpbWVvdXQodGlwLl9oaWRlVCk7CiAgICAgICAgdGlwLl9oaWRlVCA9IHNldFRpbWVvdXQoKCkg
PT4gdGlwLmNsYXNzTGlzdC5yZW1vdmUoJ3Nob3cnKSwgMjIwMCk7CiAgICB9CiAgICAvKiBpbWctaG92
ZXItcHJldmlldy12OCAqLwogICAgbGV0IF9faW1nSG92ZXJUaW1lciA9IDAsIF9faW1nSG92ZXJIaWRl
VGltZXIgPSAwLCBfX2ltZ0hvdmVyS2V5ID0gJyc7CiAgICBmdW5jdGlvbiBfX2ltZ0hvdmVyRW5zdXJl
KCkgewogICAgICAgIGxldCBib3ggPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnaW1nLWhvdmVyLXNp
ZGUnKTsKICAgICAgICBpZiAoIWJveCkgewogICAgICAgICAgICBib3ggPSBkb2N1bWVudC5jcmVhdGVF
bGVtZW50KCdkaXYnKTsgYm94LmlkID0gJ2ltZy1ob3Zlci1zaWRlJzsKICAgICAgICAgICAgY29uc3Qg
ZnJhbWUgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsgZnJhbWUuY2xhc3NOYW1lID0gJ2lo
cC1mcmFtZSc7CiAgICAgICAgICAgIGNvbnN0IGltID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnaW1n
Jyk7IGltLmFsdCA9ICcnOwogICAgICAgICAgICBmcmFtZS5hcHBlbmRDaGlsZChpbSk7IGJveC5hcHBl
bmRDaGlsZChmcmFtZSk7IGRvY3VtZW50LmJvZHkuYXBwZW5kQ2hpbGQoYm94KTsKICAgICAgICB9CiAg
ICAgICAgbGV0IHN0ID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2ltZy1ob3Zlci1zaWRlLWNzcycp
OwogICAgICAgIGlmICghc3QpIHsgc3QgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdzdHlsZScpOyBz
dC5pZCA9ICdpbWctaG92ZXItc2lkZS1jc3MnOyBkb2N1bWVudC5oZWFkLmFwcGVuZENoaWxkKHN0KTsg
fQogICAgICAgIHN0LnRleHRDb250ZW50ID0gIiNpbWctaG92ZXItc2lkZXtwb3NpdGlvbjpmaXhlZDt6
LWluZGV4OjEwMDAwMDtyaWdodDo2cHg7dG9wOjUwJTt0cmFuc2Zvcm06dHJhbnNsYXRlWSgtNTAlKTtw
b2ludGVyLWV2ZW50czpub25lO29wYWNpdHk6MDt2aXNpYmlsaXR5OmhpZGRlbjttYXgtd2lkdGg6bWlu
KDYyMHB4LDkydncpO21heC1oZWlnaHQ6bWluKDkydmgsOTIwcHgpfSNpbWctaG92ZXItc2lkZS5zaG93
e29wYWNpdHk6MTt2aXNpYmlsaXR5OnZpc2libGV9I2ltZy1ob3Zlci1zaWRlIC5paHAtZnJhbWV7cGFk
ZGluZzozcHg7YmFja2dyb3VuZDojZmZmO2JvcmRlcjoxcHggc29saWQgI0M1Q0REQztib3JkZXItcmFk
aXVzOjJweDtib3gtc2hhZG93OjAgNnB4IDE4cHggcmdiYSg0NCw0Niw1NCwuMTIpfSNpbWctaG92ZXIt
c2lkZSBpbWd7ZGlzcGxheTpibG9jazttYXgtd2lkdGg6bWluKDYxMnB4LDkwdncpO21heC1oZWlnaHQ6
bWluKDkwdmgsOTAwcHgpO3dpZHRoOmF1dG87aGVpZ2h0OmF1dG87b2JqZWN0LWZpdDpjb250YWluO2Jh
Y2tncm91bmQ6I2ZmZn0iOwogICAgICAgIHJldHVybiBib3g7CiAgICB9CiAgICB3aW5kb3cuX19pbWdI
b3ZlclNob3cgPSBmdW5jdGlvbihmaWxlLCBpZCkgewogICAgICAgIGNvbnN0IGJhcmUgPSBTdHJpbmco
ZmlsZSB8fCAnJykuc3BsaXQoL1tcXFxcL10vKS5wb3AoKTsgaWYgKCFiYXJlKSByZXR1cm47CiAgICAg
ICAgY29uc3QgYm94ID0gX19pbWdIb3ZlckVuc3VyZSgpOyBjb25zdCBpbWcgPSBib3gucXVlcnlTZWxl
Y3RvcignaW1nJyk7IGlmICghaW1nKSByZXR1cm47CiAgICAgICAgYm94LmNsYXNzTGlzdC5hZGQoJ3No
b3cnKTsKICAgICAgICBpbWcub25lcnJvciA9ICgpID0+IHsKICAgICAgICAgICAgaW1nLm9uZXJyb3Ig
PSAoKSA9PiB7IGltZy5vbmVycm9yID0gbnVsbDsgdHJ5IHsgY29uc3QgYyA9IHRodW1iQ2FjaGUgJiYg
dGh1bWJDYWNoZS5nZXQoU3RyaW5nKGlkKSk7IGlmIChjKSBpbWcuc3JjID0gYzsgfSBjYXRjaCAoZSkg
e30gfTsKICAgICAgICAgICAgaW1nLnNyYyA9IFNUT1JFX0JBU0UgKyAndGhfJyArIGJhcmUucmVwbGFj
ZSgvXC5bXi5dKyQvLCAnJykgKyAnLmpwZyc7CiAgICAgICAgfTsKICAgICAgICBpbWcub25sb2FkID0g
KCkgPT4geyBpbWcub25lcnJvciA9IG51bGw7IH07CiAgICAgICAgaW1nLmRhdGFzZXQuYmFyZSA9IGJh
cmU7IGltZy5zcmMgPSBTVE9SRV9CQVNFICsgYmFyZTsKICAgIH07CiAgICB3aW5kb3cuX19pbWdIb3Zl
ckNsZWFyVWkgPSBmdW5jdGlvbigpIHsKICAgICAgICBfX2ltZ0hvdmVyS2V5ID0gJyc7CiAgICAgICAg
aWYgKF9faW1nSG92ZXJUaW1lcikgeyBjbGVhclRpbWVvdXQoX19pbWdIb3ZlclRpbWVyKTsgX19pbWdI
b3ZlclRpbWVyID0gMDsgfQogICAgICAgIGlmIChfX2ltZ0hvdmVySGlkZVRpbWVyKSB7IGNsZWFyVGlt
ZW91dChfX2ltZ0hvdmVySGlkZVRpbWVyKTsgX19pbWdIb3ZlckhpZGVUaW1lciA9IDA7IH0KICAgICAg
ICBjb25zdCBib3ggPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnaW1nLWhvdmVyLXNpZGUnKTsgaWYg
KGJveCkgYm94LmNsYXNzTGlzdC5yZW1vdmUoJ3Nob3cnKTsKICAgICAgICBjb25zdCBpbWcgPSBib3gg
JiYgYm94LnF1ZXJ5U2VsZWN0b3IoJ2ltZycpOwogICAgICAgIGlmIChpbWcpIHsgaW1nLm9ubG9hZCA9
IG51bGw7IGltZy5vbmVycm9yID0gbnVsbDsgaW1nLnJlbW92ZUF0dHJpYnV0ZSgnc3JjJyk7IGRlbGV0
ZSBpbWcuZGF0YXNldC5iYXJlOyB9CiAgICB9OwogICAgd2luZG93Ll9faW1nSG92ZXJIaWRlID0gZnVu
Y3Rpb24oKSB7IHdpbmRvdy5fX2ltZ0hvdmVyQ2xlYXJVaSgpOyB9OwogICAgZnVuY3Rpb24gYmluZElt
Z0hvdmVyUHJldmlldyhlbCwgaWQsIGZpbGUpIHsKICAgICAgICBpZiAoIWVsKSByZXR1cm47CiAgICAg
ICAgY29uc3QgYmFyZSA9IFN0cmluZyhmaWxlIHx8ICcnKS5zcGxpdCgvW1xcXFwvXS8pLnBvcCgpOyBp
ZiAoIWJhcmUpIHJldHVybjsKICAgICAgICBjb25zdCBrZXkgPSBTdHJpbmcoaWQpICsgJ3wnICsgYmFy
ZTsKICAgICAgICBlbC5zdHlsZS5jdXJzb3IgPSAnem9vbS1pbic7CiAgICAgICAgZWwuYWRkRXZlbnRM
aXN0ZW5lcignbW91c2VlbnRlcicsICgpID0+IHsKICAgICAgICAgICAgaWYgKF9faW1nSG92ZXJIaWRl
VGltZXIpIHsgY2xlYXJUaW1lb3V0KF9faW1nSG92ZXJIaWRlVGltZXIpOyBfX2ltZ0hvdmVySGlkZVRp
bWVyID0gMDsgfQogICAgICAgICAgICBfX2ltZ0hvdmVyS2V5ID0ga2V5OwogICAgICAgICAgICBpZiAo
X19pbWdIb3ZlclRpbWVyKSBjbGVhclRpbWVvdXQoX19pbWdIb3ZlclRpbWVyKTsKICAgICAgICAgICAg
X19pbWdIb3ZlclRpbWVyID0gc2V0VGltZW91dCgoKSA9PiB7IGlmIChfX2ltZ0hvdmVyS2V5ID09PSBr
ZXkpIHRyeSB7IHdpbmRvdy5fX2ltZ0hvdmVyU2hvdyhiYXJlLCBpZCk7IH0gY2F0Y2ggKGUpIHt9IH0s
IDYwKTsKICAgICAgICB9KTsKICAgICAgICBlbC5hZGRFdmVudExpc3RlbmVyKCdtb3VzZWxlYXZlJywg
KCkgPT4gewogICAgICAgICAgICBpZiAoX19pbWdIb3ZlclRpbWVyKSB7IGNsZWFyVGltZW91dChfX2lt
Z0hvdmVyVGltZXIpOyBfX2ltZ0hvdmVyVGltZXIgPSAwOyB9CiAgICAgICAgICAgIF9faW1nSG92ZXJI
aWRlVGltZXIgPSBzZXRUaW1lb3V0KCgpID0+IHsgaWYgKCFfX2ltZ0hvdmVyS2V5IHx8IF9faW1nSG92
ZXJLZXkgPT09IGtleSkgd2luZG93Ll9faW1nSG92ZXJIaWRlKCk7IH0sIDcwKTsKICAgICAgICB9KTsK
ICAgIH0KICAgIGZ1bmN0aW9uIGhhbmRsZUl0ZW1DbGljayhlLCBjKSB7CiAgICAgICAgaWYgKGUuc2hp
ZnRLZXkpIHsKICAgICAgICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOyBlLnN0b3BQcm9wYWdhdGlvbigp
OwogICAgICAgICAgICBjb25zdCBsaXN0ID0gKHR5cGVvZiBuYXZMaXN0ID09PSAnZnVuY3Rpb24nID8g
bmF2TGlzdCgpIDogdmlzaWJsZUxpc3QoKSk7CiAgICAgICAgICAgIGNvbnN0IGZpcnN0U2VsID0gZ2V0
Rmlyc3RTZWxlY3RlZExpc3RJZChsaXN0KTsKICAgICAgICAgICAgaWYgKGZpcnN0U2VsKSByYW5nZUFu
Y2hvcklkID0gZmlyc3RTZWw7CiAgICAgICAgICAgIGVsc2UgaWYgKCFyYW5nZUFuY2hvcklkIHx8ICFs
aXN0LnNvbWUoeCA9PiAreC5pZCA9PT0gK3JhbmdlQW5jaG9ySWQpKQogICAgICAgICAgICAgICAgcmFu
Z2VBbmNob3JJZCA9IHNlbGVjdGVkSWQgfHwgYy5pZDsKICAgICAgICAgICAgcmFuZ2VBbmNob3JDbGlj
a2VkID0gdHJ1ZTsKICAgICAgICAgICAgc2VsZWN0UmFuZ2VUbyhjLmlkKTsKICAgICAgICAgICAgcmV0
dXJuIHRydWU7CiAgICAgICAgfQogICAgICAgIGlmIChlLmN0cmxLZXkgfHwgZS5tZXRhS2V5KSB7CiAg
ICAgICAgICAgIGUucHJldmVudERlZmF1bHQoKTsgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICAg
ICAgdG9nZ2xlTXVsdGkoYy5pZCk7CiAgICAgICAgICAgIHJldHVybiB0cnVlOwogICAgICAgIH0KICAg
ICAgICByYW5nZUFuY2hvcklkID0gYy5pZDsKICAgICAgICByYW5nZUFuY2hvckNsaWNrZWQgPSB0cnVl
OwogICAgICAgIHJldHVybiBmYWxzZTsKICAgIH0KICAgIGZ1bmN0aW9uIHRvZ2dsZU11bHRpKGlkKSB7
CiAgICAgICAgaWQgPSAraWQ7CiAgICAgICAgY29uc3QgaSA9IG11bHRpSWRzLmZpbmRJbmRleCh4ID0+
ICt4ID09PSBpZCk7CiAgICAgICAgaWYgKGkgPj0gMCkgewogICAgICAgICAgICBtdWx0aUlkcy5zcGxp
Y2UoaSwgMSk7CiAgICAgICAgICAgIGlmICgrc2VsZWN0ZWRJZCA9PT0gaWQpCiAgICAgICAgICAgICAg
ICBzZWxlY3RlZElkID0gbXVsdGlJZHMubGVuZ3RoID8gK211bHRpSWRzW211bHRpSWRzLmxlbmd0aCAt
IDFdIDogaWQ7CiAgICAgICAgfSBlbHNlIHsKICAgICAgICAgICAgaWYgKCFtdWx0aUlkcy5sZW5ndGgp
IHJhbmdlQW5jaG9ySWQgPSBpZDsKICAgICAgICAgICAgbXVsdGlJZHMucHVzaChpZCk7CiAgICAgICAg
ICAgIHNlbGVjdGVkSWQgPSBpZDsKICAgICAgICB9CiAgICAgICAgcmFuZ2VBbmNob3JDbGlja2VkID0g
dHJ1ZTsKICAgICAgICB1cGRhdGVNdWx0aUJhZGdlKCk7CiAgICB9CgogICAgZnVuY3Rpb24gcmVuZGVy
KCkgewogICAgICAgIGhpZGVQYXRoVGlwKCk7CgogICAgICAgIGNvbnN0IHZpc2libGUgPSB2aXNpYmxl
TGlzdCgpOwogICAgICAgIGNvbnN0IGxvYWRlZCA9IGFsbENsaXBzLmxlbmd0aDsKICAgICAgICBjb25z
dCBzaG93bkNvdW50ID0gdmlzaWJsZS5sZW5ndGg7CiAgICAgICAgLy8g5pS26JeP6KeS5qCH77ya55So
IEFISyDkuIvlj5HnmoTmgLvmlbDvvIzpgb/lhY3jgIzlvZPliY3pobXph4zmlbDlh7rmnaXnmoTjgI3l
kowgYmFyIOWvueS4jeS4igogICAgICAgIGxldCBwaW5uZWROID0gTnVtYmVyKHBpbm5lZFRvdGFsKSB8
fCAwOwogICAgICAgIGlmIChwaW5uZWROIDwgMSkgewogICAgICAgICAgICBpZiAoY3VyVGFiID09PSAn
cGlubmVkJykKICAgICAgICAgICAgICAgIHBpbm5lZE4gPSBNYXRoLm1heChOdW1iZXIoZGlza1RvdGFs
KSB8fCAwLCBsb2FkZWQpOwogICAgICAgICAgICBlbHNlCiAgICAgICAgICAgICAgICBwaW5uZWROID0g
YWxsQ2xpcHMuZmlsdGVyKGMgPT4gaXNQaW5uZWQoYykpLmxlbmd0aDsKICAgICAgICB9CiAgICAgICAg
Y29uc3QgcGluQ250ICA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdwaW4tY250Jyk7CiAgICAgICAg
cGluQ250LnRleHRDb250ZW50ICAgPSBwaW5uZWROOwogICAgICAgIHBpbkNudC5zdHlsZS5kaXNwbGF5
ID0gcGlubmVkTiA/ICcnIDogJ25vbmUnOwogICAgICAgIC8vIOaUtuiXjyB0YWLvvJpiYXIg5LiO6KeS
5qCH5ZCM5LiA5aWX5oC75pWw77yb5pyq5ruh6aG15pe25pi+56S6IOW3suWKoOi9vS/mgLvmlbAKICAg
ICAgICBsZXQgc2hvd1RvdGFsID0gZGlza1RvdGFsID4gMCA/IGRpc2tUb3RhbCA6IChsb2FkZWQgfHwg
MCk7CiAgICAgICAgaWYgKGN1clRhYiA9PT0gJ3Bpbm5lZCcgJiYgcGlubmVkTiA+IHNob3dUb3RhbCkK
ICAgICAgICAgICAgc2hvd1RvdGFsID0gcGlubmVkTjsKICAgICAgICBjb25zdCBxT24gPSBTdHJpbmco
cXVlcnkgfHwgJycpLnRyaW0oKS5sZW5ndGggPiAwOwogICAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRC
eUlkKCdiYXItdHh0JykudGV4dENvbnRlbnQgPSBxT24KICAgICAgICAgICAgPyAoc2hvd25Db3VudCAr
ICcg5p2hJykKICAgICAgICAgICAgOiAoc2hvd1RvdGFsID4gbG9hZGVkID8gKHNob3duQ291bnQgKyAn
IC8gJyArIHNob3dUb3RhbCArICcg5p2hJykgOiAoc2hvd1RvdGFsICsgJyDmnaEnKSk7CiAgICAgICAg
ZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2VtcHR5LXR4dCcpLnRleHRDb250ZW50ID0gRU1QVFlfTVNH
W2N1clRhYl0gfHwgRU1QVFlfTVNHLmFsbDsKCiAgICAgICAgY29uc3QgaWRTZXQgPSBuZXcgU2V0KGFs
bENsaXBzLm1hcChjID0+ICtjLmlkKSk7CiAgICAgICAgbXVsdGlJZHMgPSBtdWx0aUlkcy5maWx0ZXIo
aWQgPT4gaWRTZXQuaGFzKGlkKSk7CiAgICAgICAgdXBkYXRlTXVsdGlCYWRnZSgpOwoKICAgICAgICBj
b25zdCBzaG93biA9IHZpc2libGU7CgogICAgICAgIGxpc3RFbC5xdWVyeVNlbGVjdG9yQWxsKCcuaXRt
LCAjbGlzdC1tb3JlJykuZm9yRWFjaChlID0+IGUucmVtb3ZlKCkpOwogICAgICAgIGlmIChib290TG9h
ZGluZykgewogICAgICAgICAgICBpZiAoc2tlbEVsKSBza2VsRWwuY2xhc3NMaXN0LmFkZCgnb24nKTsK
ICAgICAgICAgICAgZW1wdHlFbC5jbGFzc0xpc3QucmVtb3ZlKCdvbicpOwogICAgICAgICAgICB1cGRh
dGVUb3BCdG4oKTsKICAgICAgICAgICAgcmV0dXJuOwogICAgICAgIH0KICAgICAgICAvLyBXYWl0aW5n
IGZvciBmaXJzdCBkYXRhLCBvciBob3N0IG5ldmVyIGNvbmZpcm1lZCDigJRkb24ndCBmbGFzaOOAjOaa
guaXoOiusOW9leOAjQogICAgICAgIGlmICgod2FpdGluZ0RhdGEgfHwgIWhvc3RQdXNoZWRPbmNlKSAm
JiAhdmlzaWJsZS5sZW5ndGgpIHsKICAgICAgICAgICAgLy8gS2VlcCBza2VsZXRvbiBpZiBhbHJlYWR5
IG9uOyBuZXZlciBzdHJpcCBpdCB3aGlsZSB3YWl0aW5nCiAgICAgICAgICAgIGlmIChza2VsRWwgJiYg
c2tlbEVsLmNsYXNzTGlzdC5jb250YWlucygnb24nKSkgewogICAgICAgICAgICAgICAgZW1wdHlFbC5j
bGFzc0xpc3QucmVtb3ZlKCdvbicpOwogICAgICAgICAgICAgICAgdXBkYXRlVG9wQnRuKCk7CiAgICAg
ICAgICAgICAgICByZXR1cm47CiAgICAgICAgICAgIH0KICAgICAgICAgICAgaWYgKHNrZWxFbCkgc2tl
bEVsLmNsYXNzTGlzdC5yZW1vdmUoJ29uJyk7CiAgICAgICAgICAgIGNvbnN0IHFXYWl0ID0gU3RyaW5n
KHF1ZXJ5IHx8ICcnKS50cmltKCkubGVuZ3RoID4gMDsKICAgICAgICAgICAgaWYgKHFXYWl0ICYmICFo
b3N0UHVzaGVkT25jZSkgewogICAgICAgICAgICAgICAgaWYgKHNrZWxFbCkgc2tlbEVsLmNsYXNzTGlz
dC5hZGQoJ29uJyk7CiAgICAgICAgICAgICAgICBlbXB0eUVsLmNsYXNzTGlzdC5yZW1vdmUoJ29uJyk7
CiAgICAgICAgICAgICAgICB1cGRhdGVUb3BCdG4oKTsKICAgICAgICAgICAgICAgIHJldHVybjsKICAg
ICAgICAgICAgfQogICAgICAgICAgICBlbXB0eUVsLmNsYXNzTGlzdC5yZW1vdmUoJ29uJyk7CiAgICAg
ICAgICAgIHVwZGF0ZVRvcEJ0bigpOwogICAgICAgICAgICByZXR1cm47CiAgICAgICAgfQogICAgICAg
IGlmIChza2VsRWwpIHNrZWxFbC5jbGFzc0xpc3QucmVtb3ZlKCdvbicpOwogICAgICAgIGlmICghdmlz
aWJsZS5sZW5ndGgpIHsKICAgICAgICAgICAgLy8gTmV2ZXIgc2hvd+OAjOaaguaXoOiusOW9leOAjXVu
dGlsIHdlIGhhdmUgc2VlbiBhIHJlYWwgbm9uLWVtcHR5IHB1c2gsCiAgICAgICAgICAgIC8vIG9yIGEg
Y29uZmlybWVkIGVtcHR5IGFmdGVyIHdhcm0gKHNhd05vbkVtcHR5IGNhbiBiZSBzZXQgYnkgZW1wdHkt
ZmFsbGJhY2spLgogICAgICAgICAgICAvLyBGaWx0ZXJlZCBzZWFyY2ggd2l0aCAwIGhpdHMgaXMgYWxs
b3dlZCBvbmNlIGhvc3QgcHVzaGVkLgogICAgICAgICAgICBjb25zdCBxT24gPSBTdHJpbmcocXVlcnkg
fHwgJycpLnRyaW0oKS5sZW5ndGggPiAwOwogICAgICAgICAgICBjb25zdCBhbGxvd0VtcHR5ID0gaG9z
dFB1c2hlZE9uY2UgJiYgc2F3Tm9uRW1wdHkgJiYgIXdhaXRpbmdEYXRhICYmICFib290TG9hZGluZwog
ICAgICAgICAgICAgICAgJiYgKHFPbiB8fCBkaXNrVG90YWwgPD0gMCk7CiAgICAgICAgICAgIGlmICgh
YWxsb3dFbXB0eSkgewogICAgICAgICAgICAgICAgZW1wdHlFbC5jbGFzc0xpc3QucmVtb3ZlKCdvbicp
OwogICAgICAgICAgICAgICAgLy8gUHJlZmVyIHNrZWxldG9uIG92ZXIgYmxhbmsgd2hpbGUgc3RpbGwg
Ym9vdHN0cmFwcGluZwogICAgICAgICAgICAgICAgaWYgKCFob3N0UHVzaGVkT25jZSB8fCB3YWl0aW5n
RGF0YSkgewogICAgICAgICAgICAgICAgICAgIGlmIChza2VsRWwpIHNrZWxFbC5jbGFzc0xpc3QuYWRk
KCdvbicpOwogICAgICAgICAgICAgICAgICAgIGNvbnN0IGFwcCA9IGRvY3VtZW50LmdldEVsZW1lbnRC
eUlkKCdhcHAnKTsKICAgICAgICAgICAgICAgICAgICBpZiAoYXBwKSBhcHAuY2xhc3NMaXN0LmFkZCgn
Ym9vdC1sb2FkaW5nJyk7CiAgICAgICAgICAgICAgICAgICAgYm9vdExvYWRpbmcgPSB0cnVlOwogICAg
ICAgICAgICAgICAgfQogICAgICAgICAgICAgICAgdXBkYXRlVG9wQnRuKCk7CiAgICAgICAgICAgICAg
ICByZXR1cm47CiAgICAgICAgICAgIH0KICAgICAgICAgICAgaWYgKHNlbGVjdEZpcnN0T25TaG93KSB7
CiAgICAgICAgICAgICAgICBzZWxlY3RGaXJzdE9uU2hvdyA9IGZhbHNlOwogICAgICAgICAgICAgICAg
c2VsZWN0ZWRJZCA9IDA7CiAgICAgICAgICAgICAgICBjbGVhck11bHRpKCk7CiAgICAgICAgICAgICAg
ICBsaXN0RWwuc2Nyb2xsVG9wID0gMDsKICAgICAgICAgICAgfQogICAgICAgICAgICBlbXB0eUVsLmNs
YXNzTGlzdC5hZGQoJ29uJyk7CiAgICAgICAgICAgIHVwZGF0ZVRvcEJ0bigpOwogICAgICAgICAgICBy
ZXR1cm47CiAgICAgICAgfQogICAgICAgIGVtcHR5RWwuY2xhc3NMaXN0LnJlbW92ZSgnb24nKTsKICAg
ICAgICBjb25zdCBmcmFnID0gZG9jdW1lbnQuY3JlYXRlRG9jdW1lbnRGcmFnbWVudCgpOwogICAgICAg
IGNvbnN0IGJsb2NrcyA9IGJ1aWxkUGlubmVkQmxvY2tzKHNob3duKTsKICAgICAgICBsZXQgbnVtID0g
MDsKICAgICAgICBibG9ja3MuZm9yRWFjaChiID0+IHsKICAgICAgICAgICAgbnVtICs9IDE7CiAgICAg
ICAgICAgIGlmIChiLmtpbmQgPT09ICdncm91cCcgJiYgYi5pdGVtcy5sZW5ndGggPiAxKQogICAgICAg
ICAgICAgICAgZnJhZy5hcHBlbmRDaGlsZChtYWtlR3JvdXBJdGVtKGIuaXRlbXMsIG51bSkpOwogICAg
ICAgICAgICBlbHNlCiAgICAgICAgICAgICAgICBmcmFnLmFwcGVuZENoaWxkKG1ha2VJdGVtKGIuaXRl
bXNbMF0sIG51bSkpOwogICAgICAgIH0pOwogICAgICAgIGxpc3RFbC5hcHBlbmRDaGlsZChmcmFnKTsK
ICAgICAgICB1cGRhdGVNb3JlRm9vdGVyKGRpc2tUb3RhbCk7CiAgICAgICAgaWYgKHNlbGVjdEZpcnN0
T25TaG93KSB7CiAgICAgICAgICAgIHNlbGVjdEZpcnN0T25TaG93ID0gZmFsc2U7CiAgICAgICAgICAg
IHNlbGVjdGVkSWQgPSB2aXNpYmxlWzBdLmlkOwogICAgICAgICAgICBjbGVhck11bHRpKCk7CiAgICAg
ICAgICAgIGxpc3RFbC5zY3JvbGxUb3AgPSAwOwogICAgICAgIH0gZWxzZSBpZiAoIXZpc2libGUuc29t
ZShjID0+IGMuaWQgPT0gc2VsZWN0ZWRJZCkpIHsKICAgICAgICAgICAgc2VsZWN0ZWRJZCA9IHZpc2li
bGVbMF0uaWQ7CiAgICAgICAgICAgIHJhbmdlQW5jaG9ySWQgPSBzZWxlY3RlZElkOwogICAgICAgICAg
ICByYW5nZUFuY2hvckNsaWNrZWQgPSBmYWxzZTsKICAgICAgICB9IGVsc2UgaWYgKCFyYW5nZUFuY2hv
cklkKSB7CiAgICAgICAgICAgIHJhbmdlQW5jaG9ySWQgPSBzZWxlY3RlZElkOwogICAgICAgIH0KICAg
ICAgICBzeW5jSXRlbUhpZ2hsaWdodCgpOwogICAgICAgIHVwZGF0ZVRvcEJ0bigpOwogICAgICAgIGlm
ICh3aW5kb3cuX19wZW5kaW5nSnVtcElkKSB7CiAgICAgICAgICAgIGNvbnN0IGppZCA9ICt3aW5kb3cu
X19wZW5kaW5nSnVtcElkOwogICAgICAgICAgICBjb25zdCBlbCA9IGxpc3RFbC5xdWVyeVNlbGVjdG9y
KCcubWctcm93W2RhdGEtaWQ9IicgKyBqaWQgKyAnIl0nKSB8fCBsaXN0RWwucXVlcnlTZWxlY3Rvcign
Lml0bVtkYXRhLWlkPSInICsgamlkICsgJyJdJyk7CiAgICAgICAgICAgIGlmIChlbCkgewogICAgICAg
ICAgICAgICAgd2luZG93Ll9fcGVuZGluZ0p1bXBJZCA9IDA7CiAgICAgICAgICAgICAgICB3aW5kb3cu
X19qdW1wTG9hZFRyaWVzID0gMDsKICAgICAgICAgICAgICAgIHNlbGVjdGVkSWQgPSBqaWQ7CiAgICAg
ICAgICAgICAgICByZXF1ZXN0QW5pbWF0aW9uRnJhbWUoKCkgPT4gewogICAgICAgICAgICAgICAgICAg
IGNvbnN0IG5vZGUgPSBsaXN0RWwucXVlcnlTZWxlY3RvcignLm1nLXJvd1tkYXRhLWlkPSInICsgamlk
ICsgJyJdJykgfHwgbGlzdEVsLnF1ZXJ5U2VsZWN0b3IoJy5pdG1bZGF0YS1pZD0iJyArIGppZCArICci
XScpOwogICAgICAgICAgICAgICAgICAgIGlmICghbm9kZSkgcmV0dXJuOwogICAgICAgICAgICAgICAg
ICAgIG5vZGUuc2Nyb2xsSW50b1ZpZXcoeyBibG9jazogJ2NlbnRlcicgfSk7CiAgICAgICAgICAgICAg
ICAgICAgbm9kZS5jbGFzc0xpc3QuYWRkKCdqdW1wLWZsYXNoJyk7CiAgICAgICAgICAgICAgICAgICAg
c2V0VGltZW91dCgoKSA9PiBub2RlLmNsYXNzTGlzdC5yZW1vdmUoJ2p1bXAtZmxhc2gnKSwgOTAwKTsK
ICAgICAgICAgICAgICAgICAgICBzeW5jSXRlbUhpZ2hsaWdodCgpOwogICAgICAgICAgICAgICAgfSk7
CiAgICAgICAgICAgIH0gZWxzZSBpZiAoYWxsQ2xpcHMubGVuZ3RoIDwgZGlza1RvdGFsICYmICh3aW5k
b3cuX19qdW1wTG9hZFRyaWVzIHx8IDApIDwgNDApIHsKICAgICAgICAgICAgICAgIHdpbmRvdy5fX2p1
bXBMb2FkVHJpZXMgPSAod2luZG93Ll9fanVtcExvYWRUcmllcyB8fCAwKSArIDE7CiAgICAgICAgICAg
ICAgICByZXF1ZXN0TW9yZSgpOwogICAgICAgICAgICB9IGVsc2UgaWYgKGN1clRhYiAhPT0gJ2FsbCcg
JiYgIXdpbmRvdy5fX2p1bXBGZWxsQmFjaykgewogICAgICAgICAgICAgICAgLy8gSXRlbSBnb25lIGZy
b20gdGhpcyB0YWIgKGUuZy4gdW5waW5uZWQpIOKAlCBmYWxsIGJhY2sgdG8g5YWo6YOoIG9uY2UKICAg
ICAgICAgICAgICAgIHdpbmRvdy5fX2p1bXBGZWxsQmFjayA9IHRydWU7CiAgICAgICAgICAgICAgICB3
aW5kb3cuX19qdW1wTG9hZFRyaWVzID0gMDsKICAgICAgICAgICAgICAgIGN1clRhYiA9ICdhbGwnOwog
ICAgICAgICAgICAgICAgbWFya1RhYignYWxsJyk7CiAgICAgICAgICAgICAgICByZXF1ZXN0Vmlldygp
OwogICAgICAgICAgICB9IGVsc2UgewogICAgICAgICAgICAgICAgd2luZG93Ll9fcGVuZGluZ0p1bXBJ
ZCA9IDA7CiAgICAgICAgICAgICAgICB3aW5kb3cuX19qdW1wTG9hZFRyaWVzID0gMDsKICAgICAgICAg
ICAgICAgIGlmIChhbGxDbGlwcy5zb21lKGMgPT4gK2MuaWQgPT09IGppZCkpCiAgICAgICAgICAgICAg
ICAgICAgc2VsZWN0ZWRJZCA9IGppZDsKICAgICAgICAgICAgICAgIHN5bmNJdGVtSGlnaGxpZ2h0KCk7
CiAgICAgICAgICAgIH0KICAgICAgICB9CiAgICAgICAgcmVxdWVzdEFuaW1hdGlvbkZyYW1lKCgpID0+
IHsKICAgICAgICAgICAgaWYgKGFsbENsaXBzLmxlbmd0aCA8IGRpc2tUb3RhbAogICAgICAgICAgICAg
ICAgJiYgbGlzdEVsLnNjcm9sbEhlaWdodCA8PSBsaXN0RWwuY2xpZW50SGVpZ2h0ICsgMjApCiAgICAg
ICAgICAgICAgICByZXF1ZXN0TW9yZSgpOwogICAgICAgICAgICBzY2hlZHVsZUZpbGVHb25lQ2hlY2so
KTsKICAgICAgICB9KTsKICAgIH0KCiAgICBjb25zdCBTVkcgPSB7CiAgICAgICAgdGV4dDogICBgPHN2
ZyB2aWV3Qm94PSIwIDAgMjQgMjQiIGZpbGw9Im5vbmUiIHN0cm9rZT0iY3VycmVudENvbG9yIiBzdHJv
a2Utd2lkdGg9IjIiPjxwYXRoIGQ9Ik00IDdWNGgxNnYzTTkgMjBoNk0xMiA0djE2Ii8+PC9zdmc+YCwK
ICAgICAgICBtZDogICAgIGA8c3ZnIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0iY3VycmVudENvbG9y
Ij48dGV4dCB4PSIxMiIgeT0iMTciIHRleHQtYW5jaG9yPSJtaWRkbGUiIGZvbnQtc2l6ZT0iMTUiIGZv
bnQtd2VpZ2h0PSI4MDAiIGZvbnQtZmFtaWx5PSJTZWdvZSBVSSxNaWNyb3NvZnQgWWFIZWksc2Fucy1z
ZXJpZiI+TTwvdGV4dD48L3N2Zz5gLAogICAgICAgIGltYWdlOiAgYDxzdmcgdmlld0JveD0iMCAwIDI0
IDI0IiBmaWxsPSJub25lIiBzdHJva2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIxLjgiPjxy
ZWN0IHg9IjMiIHk9IjUiIHdpZHRoPSIxOCIgaGVpZ2h0PSIxNCIgcng9IjIiLz48Y2lyY2xlIGN4PSI4
LjUiIGN5PSIxMCIgcj0iMS41IiBmaWxsPSJjdXJyZW50Q29sb3IiIHN0cm9rZT0ibm9uZSIvPjxwYXRo
IGQ9Ik0zIDE2bDUtNSA0IDQgMy0zIDYgNiIvPjwvc3ZnPmAsCiAgICAgICAgdmlkZW86ICBgPHN2ZyB2
aWV3Qm94PSIwIDAgMjQgMjQiIGZpbGw9Im5vbmUiIHN0cm9rZT0iY3VycmVudENvbG9yIiBzdHJva2Ut
d2lkdGg9IjEuOCI+PHJlY3QgeD0iMyIgeT0iNiIgd2lkdGg9IjE0IiBoZWlnaHQ9IjEyIiByeD0iMiIv
PjxwYXRoIGQ9Ik0xNyA5LjVsNC0yLjV2MTBsLTQtMi41VjkuNXoiIGZpbGw9ImN1cnJlbnRDb2xvciIg
c3Ryb2tlPSJub25lIi8+PHBhdGggZD0iTTguNSAxMC4ydjMuNmwzLjItMS44LTMuMi0xLjh6IiBmaWxs
PSJjdXJyZW50Q29sb3IiIHN0cm9rZT0ibm9uZSIvPjwvc3ZnPmAsCiAgICAgICAgZm9sZGVyOiBgPHN2
ZyB2aWV3Qm94PSIwIDAgMjQgMjQiIGZpbGw9ImN1cnJlbnRDb2xvciI+PHBhdGggZD0iTTEwIDRINGMt
MS4xIDAtMiAuOS0yIDJ2MTJjMCAxLjEuOSAyIDIgMmgxNmMxLjEgMCAyLS45IDItMlY4YzAtMS4xLS45
LTItMi0yaC04bC0yLTJ6Ii8+PC9zdmc+YCwKICAgICAgICB6aXA6ICAgIGA8c3ZnIHZpZXdCb3g9IjAg
MCAyNCAyNCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0cm9rZS13aWR0aD0iMS44
Ij48cGF0aCBkPSJNNiAzaDlsNSA1djEzYTEgMSAwIDAgMS0xIDFINmExIDEgMCAwIDEtMS0xVjRhMSAx
IDAgMCAxIDEtMXoiLz48cGF0aCBkPSJNMTQgM3Y2aDYiLz48L3N2Zz5gLAogICAgICAgIGFoazogICAg
YDxzdmcgdmlld0JveD0iMCAwIDI0IDI0IiBmaWxsPSJjdXJyZW50Q29sb3IiPjx0ZXh0IHg9IjEyIiB5
PSIxNyIgdGV4dC1hbmNob3I9Im1pZGRsZSIgZm9udC1zaXplPSIxNCIgZm9udC13ZWlnaHQ9IjcwMCI+
SDwvdGV4dD48L3N2Zz5gLAogICAgICAgIGxuazogICAgYDxzdmcgdmlld0JveD0iMCAwIDI0IDI0IiBm
aWxsPSJub25lIiBzdHJva2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIxLjgiPjxwYXRoIGQ9
Ik0xMCAxM2E1IDUgMCAwIDAgNy4wNyAwbDIuMTItMi4xMmE1IDUgMCAwIDAtNy4wNy03LjA3TDExIDUi
Lz48cGF0aCBkPSJNMTQgMTFhNSA1IDAgMCAwLTcuMDcgMEw0LjggMTMuMTJhNSA1IDAgMSAwIDcuMDcg
Ny4wN0wxMyAxOSIvPjwvc3ZnPmAsCiAgICAgICAgZG9jOiAgICBgPHN2ZyB2aWV3Qm94PSIwIDAgMjQg
MjQiIGZpbGw9Im5vbmUiIHN0cm9rZT0iY3VycmVudENvbG9yIiBzdHJva2Utd2lkdGg9IjEuOCI+PHBh
dGggZD0iTTcgM2g3bDUgNXYxM2ExIDEgMCAwIDEtMSAxSDdhMSAxIDAgMCAxLTEtMVY0YTEgMSAwIDAg
MSAxLTF6Ii8+PHBhdGggZD0iTTE0IDN2Nmg2Ii8+PC9zdmc+YCwKICAgICAgICBtdWx0aTogIGA8c3Zn
IHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0cm9r
ZS13aWR0aD0iMS44Ij48cmVjdCB4PSI3IiB5PSI3IiB3aWR0aD0iMTIiIGhlaWdodD0iMTQiIHJ4PSIx
LjUiLz48cGF0aCBkPSJNNSAxN1Y1YTEgMSAwIDAgMSAxLTFoMTAiLz48L3N2Zz5gCiAgICB9OwoKICAg
IGZ1bmN0aW9uIGZpbGVFeHQocGF0aCkgewogICAgICAgIGNvbnN0IGJhc2UgPSBTdHJpbmcocGF0aCB8
fCAnJykuc3BsaXQoL1tcXC9dLykucG9wKCkgfHwgJyc7CiAgICAgICAgY29uc3QgaSA9IGJhc2UubGFz
dEluZGV4T2YoJy4nKTsKICAgICAgICByZXR1cm4gaSA+IDAgPyBiYXNlLnNsaWNlKGkgKyAxKS50b0xv
d2VyQ2FzZSgpIDogJyc7CiAgICB9CiAgICBjb25zdCBpc0ltYWdlRXh0ID0gZSA9PiBbJ3BuZycsJ2pw
ZycsJ2pwZWcnLCdnaWYnLCd3ZWJwJywnYm1wJywnaWNvJywndGlmJywndGlmZicsJ3N2ZyddLmluY2x1
ZGVzKGUpOwogICAgY29uc3QgaXNWaWRlb0V4dCA9IGUgPT4gWydtcDQnLCdta3YnLCdhdmknLCdtb3Yn
LCd3bXYnLCdmbHYnLCd3ZWJtJywnbTR2JywnbXBlZycsJ21wZycsJ3RzJywnbTJ0cycsJzNncCcsJ3Jt
Jywncm12YiddLmluY2x1ZGVzKGUpOwogICAgY29uc3QgaXNaaXBFeHQgICA9IGUgPT4gWyd6aXAnLCdy
YXInLCc3eicsJ3RhcicsJ2d6JywnYnoyJ10uaW5jbHVkZXMoZSk7CgogICAgZnVuY3Rpb24gaWNvbkZv
ckZpbGVzKGZpbGVzKSB7CiAgICAgICAgaWYgKCFmaWxlcy5sZW5ndGgpICAgIHJldHVybiB7IGNsczog
J2ZpbGUgZnQtZG9jJywgc3ZnOiBTVkcuZG9jIH07CiAgICAgICAgaWYgKGZpbGVzLmxlbmd0aCA+IDEp
IHJldHVybiB7IGNsczogJ2ZpbGUgZnQtbG5rJywgc3ZnOiBTVkcubXVsdGkgfTsKICAgICAgICBjb25z
dCBleHQgPSBmaWxlRXh0KGZpbGVzWzBdKTsKICAgICAgICBpZiAoIWV4dCkgICAgICAgICAgICAgIHJl
dHVybiB7IGNsczogJ2ZpbGUgZnQtZGlyJywgc3ZnOiBTVkcuZm9sZGVyIH07CiAgICAgICAgaWYgKGlz
SW1hZ2VFeHQoZXh0KSkgICByZXR1cm4geyBjbHM6ICdmaWxlIGZ0LWltZycsIHN2ZzogU1ZHLmltYWdl
IH07CiAgICAgICAgaWYgKGlzVmlkZW9FeHQoZXh0KSkgICByZXR1cm4geyBjbHM6ICdmaWxlIGZ0LXZp
ZCcsIHN2ZzogKFNWRy52aWRlbyB8fCBTVkcuZG9jKSB9OwogICAgICAgIGlmIChpc1ppcEV4dChleHQp
KSAgICAgcmV0dXJuIHsgY2xzOiAnZmlsZSBmdC16aXAnLCBzdmc6IFNWRy56aXAgfTsKICAgICAgICBp
ZiAoZXh0ID09PSAnYWhrJykgICAgIHJldHVybiB7IGNsczogJ2ZpbGUgZnQtYWhrJywgc3ZnOiBTVkcu
YWhrIH07CiAgICAgICAgaWYgKGV4dCA9PT0gJ2xuaycpICAgICByZXR1cm4geyBjbHM6ICdmaWxlIGZ0
LWxuaycsIHN2ZzogU1ZHLmxuayB9OwogICAgICAgIHJldHVybiB7IGNsczogJ2ZpbGUgZnQtZG9jJywg
c3ZnOiBTVkcuZG9jIH07CiAgICB9CgogICAgZnVuY3Rpb24gc3JjV2luTGFiZWwoYykgewogICAgICAg
IGNvbnN0IHQgPSBTdHJpbmcoYyAmJiBjLnNyY1RpdGxlIHx8ICcnKS50cmltKCk7CiAgICAgICAgaWYg
KHQpIHJldHVybiB0OwogICAgICAgIHJldHVybiBTdHJpbmcoYyAmJiBjLnNyY0V4ZSB8fCAnJykucmVw
bGFjZSgvXC5leGUkL2ksICcnKTsKICAgIH0KICAgIGZ1bmN0aW9uIHNyY1RpdGxlSHRtbChjKSB7CiAg
ICAgICAgLy8g5YiX6KGo5Lit6Ze0L+WPs+S+p+S4jeWGjeaYvuekuueql+WPo+agh+mimO+8jOadpea6
kOWPquS/neeVmeWPs+S+p+Wbvuagh+aCrOWBnOaPkOekugogICAgICAgIHJldHVybiAnJzsKICAgIH0K
ICAgIGZ1bmN0aW9uIGV4cGFuZENoZXZyb24ob3BlbikgewogICAgICAgIHJldHVybiBvcGVuCiAgICAg
ICAgICAgID8gYDxzdmcgdmlld0JveD0iMCAwIDE2IDE2IiB3aWR0aD0iMTQiIGhlaWdodD0iMTQiIGZp
bGw9Im5vbmUiIHN0cm9rZT0iY3VycmVudENvbG9yIiBzdHJva2Utd2lkdGg9IjEuOCIgc3Ryb2tlLWxp
bmVjYXA9InJvdW5kIj48cG9seWxpbmUgcG9pbnRzPSI0IDEwIDggNiAxMiAxMCIvPjwvc3ZnPjxzcGFu
PuaUtui1tzwvc3Bhbj5gCiAgICAgICAgICAgIDogYDxzdmcgdmlld0JveD0iMCAwIDE2IDE2IiB3aWR0
aD0iMTQiIGhlaWdodD0iMTQiIGZpbGw9Im5vbmUiIHN0cm9rZT0iY3VycmVudENvbG9yIiBzdHJva2Ut
d2lkdGg9IjEuOCIgc3Ryb2tlLWxpbmVjYXA9InJvdW5kIj48cG9seWxpbmUgcG9pbnRzPSI0IDYgOCAx
MCAxMiA2Ii8+PC9zdmc+PHNwYW4+5bGV5byAPC9zcGFuPmA7CiAgICB9CiAgICBmdW5jdGlvbiBsaXN0
RXhwYW5kTWF4UHgoKSB7CiAgICAgICAgY29uc3QgaCA9IChsaXN0RWwgJiYgbGlzdEVsLmNsaWVudEhl
aWdodCkgfHwgMzYwOwogICAgICAgIC8vIOWHoOS5juWNoOa7oeWIl+ihqO+8jOW6lemDqOeVmee6puS4
gOihjAogICAgICAgIHJldHVybiBNYXRoLm1heCg5NiwgaCAtIDI4KTsKICAgIH0KICAgIGZ1bmN0aW9u
IGFwcGx5RXhwYW5kZWRQcmV2aWV3KHByZXYsIGZ1bGxUZXh0KSB7CiAgICAgICAgY29uc3QgbWF4SCA9
IGxpc3RFeHBhbmRNYXhQeCgpOwogICAgICAgIHByZXYuc3R5bGUubWF4SGVpZ2h0ID0gbWF4SCArICdw
eCc7CiAgICAgICAgcHJldi5jbGFzc0xpc3QuYWRkKCdleHBhbmRlZCcpOwogICAgICAgIHNldEhsVGV4
dChwcmV2LCBmdWxsVGV4dCk7CiAgICAgICAgLy8g5LuN5rqi5Ye677ya5oiq5pat5bm25Zyo5pyr5bC+
5Yqg44CMIC4uLuOAjQogICAgICAgIGlmIChwcmV2LnNjcm9sbEhlaWdodCA8PSBwcmV2LmNsaWVudEhl
aWdodCArIDIpCiAgICAgICAgICAgIHJldHVybjsKICAgICAgICBsZXQgbG8gPSAwLCBoaSA9IGZ1bGxU
ZXh0Lmxlbmd0aCwgYmVzdCA9IDA7CiAgICAgICAgd2hpbGUgKGxvIDw9IGhpKSB7CiAgICAgICAgICAg
IGNvbnN0IG1pZCA9IChsbyArIGhpKSA+PiAxOwogICAgICAgICAgICBzZXRIbFRleHQocHJldiwgZnVs
bFRleHQuc2xpY2UoMCwgbWlkKSArICcgLi4uJyk7CiAgICAgICAgICAgIGlmIChwcmV2LnNjcm9sbEhl
aWdodCA8PSBwcmV2LmNsaWVudEhlaWdodCArIDIpIHsKICAgICAgICAgICAgICAgIGJlc3QgPSBtaWQ7
CiAgICAgICAgICAgICAgICBsbyA9IG1pZCArIDE7CiAgICAgICAgICAgIH0gZWxzZSB7CiAgICAgICAg
ICAgICAgICBoaSA9IG1pZCAtIDE7CiAgICAgICAgICAgIH0KICAgICAgICB9CiAgICAgICAgc2V0SGxU
ZXh0KHByZXYsIGZ1bGxUZXh0LnNsaWNlKDAsIGJlc3QpICsgJyAuLi4nKTsKICAgIH0KICAgIGZ1bmN0
aW9uIGNvbGxhcHNlUHJldmlldyhwcmV2LCBmdWxsVGV4dCkgewogICAgICAgIHByZXYuY2xhc3NMaXN0
LnJlbW92ZSgnZXhwYW5kZWQnKTsKICAgICAgICBwcmV2LnN0eWxlLm1heEhlaWdodCA9ICcnOwogICAg
ICAgIHNldEhsVGV4dChwcmV2LCBmdWxsVGV4dCk7CiAgICB9CgogICAgZnVuY3Rpb24gZmF2R3JvdXBP
ZihjKSB7CiAgICAgICAgcmV0dXJuIFN0cmluZyhjICYmIGMuZmF2R3JvdXAgfHwgJycpLnRyaW0oKTsK
ICAgIH0KICAgIGZ1bmN0aW9uIGNsaXBDb250ZW50UHJldmlldyhjKSB7CiAgICAgICAgY29uc3QgdHlw
ZSA9IG5vcm1UeXBlKGMudHlwZSk7CiAgICAgICAgaWYgKHR5cGUgPT09ICdpbWFnZScpIHJldHVybiAn
W+WbvuWDj10nICsgKGMud2lkdGggJiYgYy5oZWlnaHQgPyAoJyAnICsgYy53aWR0aCArICfDlycgKyBj
LmhlaWdodCkgOiAnJyk7CiAgICAgICAgaWYgKHR5cGUgPT09ICdmaWxlJykgewogICAgICAgICAgICBj
b25zdCBmaWxlcyA9IFN0cmluZyhjLnByZXZpZXcgfHwgYy5kYXRhIHx8ICcnKS5zcGxpdCgvXHI/XG4v
KS5maWx0ZXIoQm9vbGVhbik7CiAgICAgICAgICAgIHJldHVybiBmaWxlcy5tYXAoZiA9PiBmLnNwbGl0
KC9bXFwvXS8pLnBvcCgpKS5qb2luKCcgwrcgJykgfHwgJ1vmlofku7ZdJzsKICAgICAgICB9CiAgICAg
ICAgbGV0IF9wID0gU3RyaW5nKGMucHJldmlldyB8fCBjLmRhdGEgfHwgJycpOwogICAgICAgIHsgY29u
c3QgX24gPSBOdW1iZXIoYy5jaGFyQ291bnQpIHx8IDA7IGlmIChfbiA+IF9wLmxlbmd0aCAmJiBfcC5s
ZW5ndGgpIF9wICs9ICcuLi4nOyB9CiAgICAgICAgcmV0dXJuIF9wOwogICAgfQogICAgZnVuY3Rpb24g
YnVpbGRQaW5uZWRCbG9ja3MobGlzdCkgewogICAgICAgIGNvbnN0IHVzZWQgPSBuZXcgU2V0KCk7CiAg
ICAgICAgY29uc3Qgb3V0ID0gW107CiAgICAgICAgZm9yIChjb25zdCBjIG9mIGxpc3QpIHsKICAgICAg
ICAgICAgaWYgKHVzZWQuaGFzKCtjLmlkKSkgY29udGludWU7CiAgICAgICAgICAgIGNvbnN0IGdpZCA9
IGZhdkdyb3VwT2YoYyk7CiAgICAgICAgICAgIGlmICghZ2lkKSB7CiAgICAgICAgICAgICAgICB1c2Vk
LmFkZCgrYy5pZCk7CiAgICAgICAgICAgICAgICBvdXQucHVzaCh7IGtpbmQ6ICdzaW5nbGUnLCBpdGVt
czogW2NdIH0pOwogICAgICAgICAgICAgICAgY29udGludWU7CiAgICAgICAgICAgIH0KICAgICAgICAg
ICAgY29uc3QgbWVtYmVycyA9IGxpc3QuZmlsdGVyKHggPT4gZmF2R3JvdXBPZih4KSA9PT0gZ2lkKTsK
ICAgICAgICAgICAgbWVtYmVycy5mb3JFYWNoKG0gPT4gdXNlZC5hZGQoK20uaWQpKTsKICAgICAgICAg
ICAgaWYgKG1lbWJlcnMubGVuZ3RoIDwgMikKICAgICAgICAgICAgICAgIG91dC5wdXNoKHsga2luZDog
J3NpbmdsZScsIGl0ZW1zOiBbbWVtYmVyc1swXSB8fCBjXSB9KTsKICAgICAgICAgICAgZWxzZQogICAg
ICAgICAgICAgICAgb3V0LnB1c2goeyBraW5kOiAnZ3JvdXAnLCBnaWQsIGl0ZW1zOiBtZW1iZXJzIH0p
OwogICAgICAgIH0KICAgICAgICByZXR1cm4gb3V0OwogICAgfQogICAgZnVuY3Rpb24gX19wcmVwUGFz
dGUoKSB7CiAgICAgICAgdHJ5IHsKICAgICAgICAgICAgY29uc3QgcyA9IGRvY3VtZW50LmdldEVsZW1l
bnRCeUlkKCdzZWFyY2gnKTsKICAgICAgICAgICAgaWYgKHMgJiYgZG9jdW1lbnQuYWN0aXZlRWxlbWVu
dCA9PT0gcykgdHJ5IHsgcy5ibHVyKCk7IH0gY2F0Y2gge30KICAgICAgICAgICAgaWYgKHdpbmRvdy5n
ZXRTZWxlY3Rpb24pIHdpbmRvdy5nZXRTZWxlY3Rpb24oKS5yZW1vdmVBbGxSYW5nZXMoKTsKICAgICAg
ICB9IGNhdGNoIHt9CiAgICB9CiAgICBmdW5jdGlvbiBhY3RpdmF0ZUNsaXBJdGVtKGMpIHsKICAgICAg
ICBpZiAoIWMpIHJldHVybjsKICAgICAgICBpZiAobm9ybVR5cGUoYy50eXBlKSA9PT0gJ3JlY2VudCcp
IHsKICAgICAgICAgICAgX19wcmVwUGFzdGUoKTsKICAgICAgICAgICAgc2VsZWN0ZWRJZCA9IGMuaWQ7
CiAgICAgICAgICAgIGlmIChtdWx0aUlkcy5sZW5ndGgpIGNsZWFyTXVsdGkoKTsKICAgICAgICAgICAg
c3luY0l0ZW1IaWdobGlnaHQoKTsKICAgICAgICAgICAgY29uc3QgcGF0aCA9IFN0cmluZyhjLmRhdGEg
fHwgYy5wcmV2aWV3IHx8ICcnKTsKICAgICAgICAgICAgaWYgKHBhdGgpIGFoaygnb3BlbkRpcicsIHBh
dGgpOwogICAgICAgICAgICByZXR1cm47CiAgICAgICAgfQogICAgICAgIG1hcmtQYXN0ZWRMb2NhbChj
LmlkKTsKICAgICAgICBhaGsoJ3Bhc3RlJywgU3RyaW5nKGMuaWQpKTsKICAgIH0KICAgIGZ1bmN0aW9u
IHBhc3RlT25lKGMpIHsKICAgICAgICBfX3ByZXBQYXN0ZSgpOwogICAgICAgIHNlbGVjdGVkSWQgPSBj
LmlkOwogICAgICAgIGlmIChtdWx0aUlkcy5sZW5ndGgpIGNsZWFyTXVsdGkoKTsKICAgICAgICBzeW5j
SXRlbUhpZ2hsaWdodCgpOwogICAgICAgIGFjdGl2YXRlQ2xpcEl0ZW0oYyk7CiAgICB9CiAgICBmdW5j
dGlvbiBpc0l0ZW1DaHJvbWVUYXJnZXQodCkgewogICAgICAgIHJldHVybiAhISh0ICYmIHQuY2xvc2Vz
dCAmJiB0LmNsb3Nlc3QoJy5pLWV4cGFuZC1idG4sIC5pLXNyYy1pY28sIC5tZy1zcmMsIC5mZC1idG4s
IC5mZC1wYXRoLCAucmYtc2VnLCBidXR0b24sIGEsIGlucHV0JykpOwogICAgfQogICAgZnVuY3Rpb24g
YmVnaW5QYXN0ZUZyb21JdGVtKGUsIGMpIHsKICAgICAgICBpZiAoZS5idXR0b24gIT0gbnVsbCAmJiBl
LmJ1dHRvbiAhPT0gMCkgcmV0dXJuOwogICAgICAgIGlmIChpc0l0ZW1DaHJvbWVUYXJnZXQoZS50YXJn
ZXQpKSByZXR1cm47CiAgICAgICAgaWYgKGhhbmRsZUl0ZW1DbGljayhlLCBjKSkKICAgICAgICAgICAg
cmV0dXJuOwogICAgICAgIF9fcHJlcFBhc3RlKCk7CiAgICAgICAgc2VsZWN0ZWRJZCA9IGMuaWQ7CiAg
ICAgICAgcmFuZ2VBbmNob3JJZCA9IGMuaWQ7CiAgICAgICAgaWYgKG11bHRpSWRzLmxlbmd0aCA+IDAg
JiYgbXVsdGlJZHMuaW5jbHVkZXMoK2MuaWQpKSB7CiAgICAgICAgICAgIGNvbnN0IGlkcyA9IG11bHRp
SWRzLnNsaWNlKCk7CiAgICAgICAgICAgIGNsZWFyTXVsdGkoKTsKICAgICAgICAgICAgaWYgKGlkcy5z
b21lKGlkID0+IHsKICAgICAgICAgICAgICAgIGNvbnN0IGl0ID0gYWxsQ2xpcHMuZmluZCh4ID0+ICt4
LmlkID09PSAraWQpOwogICAgICAgICAgICAgICAgcmV0dXJuIGl0ICYmIG5vcm1UeXBlKGl0LnR5cGUp
ID09PSAncmVjZW50JzsKICAgICAgICAgICAgfSkpIHsKICAgICAgICAgICAgICAgIGNvbnN0IGZpcnN0
ID0gYWxsQ2xpcHMuZmluZCh4ID0+ICt4LmlkID09PSAraWRzWzBdKTsKICAgICAgICAgICAgICAgIGlm
IChmaXJzdCkgYWN0aXZhdGVDbGlwSXRlbShmaXJzdCk7CiAgICAgICAgICAgICAgICByZXR1cm47CiAg
ICAgICAgICAgIH0KICAgICAgICAgICAgbWFya1Bhc3RlZExvY2FsKGlkcyk7CiAgICAgICAgICAgIGlm
IChpZHMubGVuZ3RoID4gMSkgcGFzdGVNYW55V2l0aFNlcChpZHMsIGZhbHNlKTsKICAgICAgICAgICAg
ZWxzZSBhaGsoJ3Bhc3RlJywgU3RyaW5nKGlkc1swXSkpOwogICAgICAgICAgICByZXR1cm47CiAgICAg
ICAgfQogICAgICAgIGlmIChtdWx0aUlkcy5sZW5ndGgpIGNsZWFyTXVsdGkoKTsKICAgICAgICBzeW5j
SXRlbUhpZ2hsaWdodCgpOwogICAgICAgIGFjdGl2YXRlQ2xpcEl0ZW0oYyk7CiAgICB9CiAgICBmdW5j
dGlvbiBtYWtlR3JvdXBJdGVtKGl0ZW1zLCBpZHgpIHsKICAgICAgICBjb25zdCBlbCA9IGRvY3VtZW50
LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOwogICAgICAgIGVsLmNsYXNzTmFtZSA9ICdpdG0gaXQtZ3JvdXAn
CiAgICAgICAgICAgICsgKGl0ZW1zLnNvbWUoYyA9PiArYy5pZCA9PT0gK3NlbGVjdGVkSWQpID8gJyBz
ZWwnIDogJycpCiAgICAgICAgICAgICsgKGl0ZW1zLnNvbWUoYyA9PiBtdWx0aUlkcy5pbmNsdWRlcygr
Yy5pZCkpID8gJyBtdWx0aScgOiAnJyk7CiAgICAgICAgZWwuZGF0YXNldC5ncm91cCA9IGZhdkdyb3Vw
T2YoaXRlbXNbMF0pIHx8ICcnOwogICAgICAgIGVsLmRhdGFzZXQuaWQgPSBpdGVtc1swXS5pZDsKCiAg
ICAgICAgY29uc3QgaGVhZCA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOwogICAgICAgIGhl
YWQuY2xhc3NOYW1lID0gJ21nLWhlYWQnOwogICAgICAgIGhlYWQuaW5uZXJIVE1MID0gJzxzcGFuIGNs
YXNzPSJtZy10YWciPuWQiOW5tjwvc3Bhbj48c3Bhbj4nICsgaXRlbXMubGVuZ3RoICsgJyDmnaEgwrcg
54K55Ye75Y2V5p2h57KY6LS0PC9zcGFuPic7CiAgICAgICAgZWwuYXBwZW5kQ2hpbGQoaGVhZCk7Cgog
ICAgICAgIGl0ZW1zLmZvckVhY2goYyA9PiB7CiAgICAgICAgICAgIGNvbnN0IHJvdyA9IGRvY3VtZW50
LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOwogICAgICAgICAgICByb3cuY2xhc3NOYW1lID0gJ21nLXJvdycK
ICAgICAgICAgICAgICAgICsgKCtzZWxlY3RlZElkID09PSArYy5pZCA/ICcgc2VsJyA6ICcnKQogICAg
ICAgICAgICAgICAgKyAobXVsdGlJZHMuaW5jbHVkZXMoK2MuaWQpID8gJyBtdWx0aScgOiAnJyk7CiAg
ICAgICAgICAgIHJvdy5kYXRhc2V0LmlkID0gYy5pZDsKCiAgICAgICAgICAgIGNvbnN0IHRvcCA9IGRv
Y3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOwogICAgICAgICAgICB0b3AuY2xhc3NOYW1lID0gJ21n
LXJvdy10b3AnOwogICAgICAgICAgICBjb25zdCBtYWluID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgn
ZGl2Jyk7CiAgICAgICAgICAgIG1haW4uY2xhc3NOYW1lID0gJ21nLXJvdy1tYWluJzsKCiAgICAgICAg
ICAgIGNvbnN0IHRpdGxlID0gU3RyaW5nKGMuZmF2VGl0bGUgfHwgJycpLnRyaW0oKTsKICAgICAgICAg
ICAgaWYgKHRpdGxlKSB7CiAgICAgICAgICAgICAgICBjb25zdCB0ID0gZG9jdW1lbnQuY3JlYXRlRWxl
bWVudCgnZGl2Jyk7CiAgICAgICAgICAgICAgICB0LmNsYXNzTmFtZSA9ICdtZy10aXRsZSc7CiAgICAg
ICAgICAgICAgICBzZXRIbFRleHQodCwgdGl0bGUpOwogICAgICAgICAgICAgICAgbWFpbi5hcHBlbmRD
aGlsZCh0KTsKICAgICAgICAgICAgfQogICAgICAgICAgICBjb25zdCBib2R5ID0gZG9jdW1lbnQuY3Jl
YXRlRWxlbWVudCgnZGl2Jyk7CiAgICAgICAgICAgIGJvZHkuY2xhc3NOYW1lID0gJ21nLWJvZHknICsg
KG5vcm1UeXBlKGMudHlwZSkgPT09ICdpbWFnZScgPyAnIGltZycgOiAnJyk7CiAgICAgICAgICAgIHNl
dEhsVGV4dChib2R5LCBjbGlwQ29udGVudFByZXZpZXcoYykpOwogICAgICAgICAgICBtYWluLmFwcGVu
ZENoaWxkKGJvZHkpOwogICAgICAgICAgICB0b3AuYXBwZW5kQ2hpbGQobWFpbik7CgogICAgICAgICAg
ICBjb25zdCBzcmNJY28gPSBTdHJpbmcoYy5zcmNJY29uIHx8ICcnKTsKICAgICAgICAgICAgY29uc3Qg
c3JjRXhlID0gU3RyaW5nKGMuc3JjRXhlIHx8ICcnKTsKICAgICAgICAgICAgY29uc3Qgc3JjVGl0bGUg
PSBTdHJpbmcoYy5zcmNUaXRsZSB8fCAnJyk7CiAgICAgICAgICAgIGlmIChzcmNJY28pIHsKICAgICAg
ICAgICAgICAgIGNvbnN0IGltZyA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2ltZycpOwogICAgICAg
ICAgICAgICAgaW1nLmNsYXNzTmFtZSA9ICdtZy1zcmMnOwogICAgICAgICAgICAgICAgaW1nLnNyYyA9
IFNUT1JFX0JBU0UgKyBlbmNvZGVVUklDb21wb25lbnQoc3JjSWNvKTsKICAgICAgICAgICAgICAgIGlt
Zy5hbHQgPSAnJzsKICAgICAgICAgICAgICAgIGNvbnN0IHRpcFR4dCA9IHNyY1RpdGxlIHx8IHNyY0V4
ZSB8fCAn5p2l5rqQJzsKICAgICAgICAgICAgICAgIGltZy50aXRsZSA9IHRpcFR4dDsKICAgICAgICAg
ICAgICAgIGltZy5vbmNsaWNrID0gZSA9PiB7IGUucHJldmVudERlZmF1bHQoKTsgZS5zdG9wUHJvcGFn
YXRpb24oKTsgc2hvd1NyY1RpcChpbWcsIHRpcFR4dCk7IH07CiAgICAgICAgICAgICAgICB0b3AuYXBw
ZW5kQ2hpbGQoaW1nKTsKICAgICAgICAgICAgfQogICAgICAgICAgICByb3cuYXBwZW5kQ2hpbGQodG9w
KTsKCiAgICAgICAgICAgIHJvdy5vbnBvaW50ZXJkb3duID0gZSA9PiB7CiAgICAgICAgICAgICAgICBp
ZiAoZS5idXR0b24gIT09IDApIHJldHVybjsKICAgICAgICAgICAgICAgIGUuc3RvcFByb3BhZ2F0aW9u
KCk7CiAgICAgICAgICAgICAgICBiZWdpblBhc3RlRnJvbUl0ZW0oZSwgYyk7CiAgICAgICAgICAgIH07
CiAgICAgICAgICAgIHJvdy5vbmNvbnRleHRtZW51ID0gZSA9PiB7CiAgICAgICAgICAgICAgICBlLnBy
ZXZlbnREZWZhdWx0KCk7CiAgICAgICAgICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgICAg
ICAgICAgICAgc2VsZWN0ZWRJZCA9IGMuaWQ7CiAgICAgICAgICAgICAgICBzaG93Q3R4KGUuY2xpZW50
WCwgZS5jbGllbnRZLCBjKTsKICAgICAgICAgICAgfTsKICAgICAgICAgICAgZWwuYXBwZW5kQ2hpbGQo
cm93KTsKICAgICAgICB9KTsKCiAgICAgICAgZWwub25jb250ZXh0bWVudSA9IGUgPT4gewogICAgICAg
ICAgICBpZiAoZS50YXJnZXQuY2xvc2VzdCgnLm1nLXJvdycpKSByZXR1cm47CiAgICAgICAgICAgIGUu
cHJldmVudERlZmF1bHQoKTsKICAgICAgICAgICAgc2VsZWN0ZWRJZCA9IGl0ZW1zWzBdLmlkOwogICAg
ICAgICAgICBzaG93Q3R4KGUuY2xpZW50WCwgZS5jbGllbnRZLCBpdGVtc1swXSk7CiAgICAgICAgfTsK
ICAgICAgICByZXR1cm4gZWw7CiAgICB9CgogICAgZnVuY3Rpb24gYnVpbGRSZWNlbnRQYXRoQ3J1bWJz
KGNvbnRhaW5lciwgZnVsbFBhdGgpIHsKICAgICAgICBpZiAoIWNvbnRhaW5lcikgcmV0dXJuOwogICAg
ICAgIGNvbnRhaW5lci5yZXBsYWNlQ2hpbGRyZW4oKTsKICAgICAgICBjb25zdCByYXcgPSBTdHJpbmco
ZnVsbFBhdGggfHwgJycpLnJlcGxhY2UoL1wvL2csICdcXCcpLnJlcGxhY2UoL1xcKyQvLCAnJyk7CiAg
ICAgICAgaWYgKCFyYXcpIHJldHVybjsKICAgICAgICBjb25zdCB1bmMgPSByYXcuc3RhcnRzV2l0aCgn
XFxcXCcpOwogICAgICAgIGxldCByZXN0ID0gdW5jID8gcmF3LnNsaWNlKDIpIDogcmF3OwogICAgICAg
IGNvbnN0IHBhcnRzID0gcmVzdC5zcGxpdCgnXFwnKS5maWx0ZXIoQm9vbGVhbik7CiAgICAgICAgaWYg
KCFwYXJ0cy5sZW5ndGgpIHsKICAgICAgICAgICAgY29uc3Qgb25seSA9IGRvY3VtZW50LmNyZWF0ZUVs
ZW1lbnQoJ3NwYW4nKTsKICAgICAgICAgICAgb25seS5jbGFzc05hbWUgPSAncmYtc2VnJzsKICAgICAg
ICAgICAgb25seS50ZXh0Q29udGVudCA9IHJhdzsKICAgICAgICAgICAgb25seS50aXRsZSA9IHJhdzsK
ICAgICAgICAgICAgb25seS5vbnBvaW50ZXJkb3duID0gZSA9PiB7CiAgICAgICAgICAgICAgICBlLnBy
ZXZlbnREZWZhdWx0KCk7IGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAgICAgICAgICAgICBhaGsoJ29w
ZW5EaXInLCByYXcpOwogICAgICAgICAgICB9OwogICAgICAgICAgICBjb250YWluZXIuYXBwZW5kQ2hp
bGQob25seSk7CiAgICAgICAgICAgIHJldHVybjsKICAgICAgICB9CiAgICAgICAgbGV0IGFjYyA9IHVu
YyA/ICdcXFxcJyArIHBhcnRzWzBdIDogcGFydHNbMF07CiAgICAgICAgLy8gZHJpdmUgcm9vdCBsaWtl
IEM6IOKAlCBvcGVuIHBhdGggbmVlZHMgdHJhaWxpbmcgXCwgbGFiZWwgZG9lcyBub3QKICAgICAgICBp
ZiAoIXVuYyAmJiAvXlthLXpBLVpdOiQvLnRlc3QocGFydHNbMF0pKQogICAgICAgICAgICBhY2MgPSBw
YXJ0c1swXSArICdcXCc7CiAgICAgICAgY29uc3QgYWRkU2VnID0gKGxhYmVsLCBvcGVuUGF0aCkgPT4g
ewogICAgICAgICAgICBpZiAoY29udGFpbmVyLmNoaWxkTm9kZXMubGVuZ3RoKSB7CiAgICAgICAgICAg
ICAgICBjb25zdCBzZXAgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdzcGFuJyk7CiAgICAgICAgICAg
ICAgICBzZXAuY2xhc3NOYW1lID0gJ3JmLXNlcCc7CiAgICAgICAgICAgICAgICBzZXAudGV4dENvbnRl
bnQgPSAnXFwnOwogICAgICAgICAgICAgICAgY29udGFpbmVyLmFwcGVuZENoaWxkKHNlcCk7CiAgICAg
ICAgICAgIH0KICAgICAgICAgICAgY29uc3Qgc2VnID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnc3Bh
bicpOwogICAgICAgICAgICBzZWcuY2xhc3NOYW1lID0gJ3JmLXNlZyc7CiAgICAgICAgICAgIHNldEhs
VGV4dChzZWcsIGxhYmVsKTsKICAgICAgICAgICAgc2VnLnRpdGxlID0gb3BlblBhdGg7CiAgICAgICAg
ICAgIHNlZy5vbnBvaW50ZXJkb3duID0gZSA9PiB7CiAgICAgICAgICAgICAgICBlLnByZXZlbnREZWZh
dWx0KCk7CiAgICAgICAgICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgICAgICAgICAgICAg
YWhrKCdvcGVuRGlyJywgb3BlblBhdGgpOwogICAgICAgICAgICB9OwogICAgICAgICAgICBjb250YWlu
ZXIuYXBwZW5kQ2hpbGQoc2VnKTsKICAgICAgICB9OwogICAgICAgIGFkZFNlZyhwYXJ0c1swXSwgYWNj
KTsKICAgICAgICBmb3IgKGxldCBpID0gMTsgaSA8IHBhcnRzLmxlbmd0aDsgaSsrKSB7CiAgICAgICAg
ICAgIGFjYyA9IGFjYy5yZXBsYWNlKC9cXCskLywgJycpICsgJ1xcJyArIHBhcnRzW2ldOwogICAgICAg
ICAgICBhZGRTZWcocGFydHNbaV0sIGFjYyk7CiAgICAgICAgfQogICAgfQoKICAgIGZ1bmN0aW9uIG1h
a2VJdGVtKGMsIGlkeCkgewogICAgICAgIGNvbnN0IHR5cGUgICA9IG5vcm1UeXBlKGMudHlwZSk7CiAg
ICAgICAgY29uc3QgcGlubmVkID0gaXNQaW5uZWQoYyk7CiAgICAgICAgY29uc3QgcGFzdGVkID0gaXNQ
YXN0ZWQoYyk7CiAgICAgICAgY29uc3QgZWwgICAgID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnZGl2
Jyk7CiAgICAgICAgZWwuY2xhc3NOYW1lICA9ICdpdG0nCiAgICAgICAgICAgICsgKHNlbGVjdGVkSWQg
PT0gYy5pZCA/ICcgc2VsJyA6ICcnKQogICAgICAgICAgICArIChtdWx0aUlkcy5pbmNsdWRlcygrYy5p
ZCkgPyAnIG11bHRpJyA6ICcnKTsKICAgICAgICBlbC5kYXRhc2V0LmlkID0gYy5pZDsKCiAgICAgICAg
Y29uc3QgaWNvICA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOwogICAgICAgIGNvbnN0IGJv
ZHkgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsKICAgICAgICBib2R5LmNsYXNzTmFtZSA9
ICdpLWJvZHknOwoKICAgICAgICBpZiAodHlwZSA9PT0gJ2ltYWdlJykgewogICAgICAgICAgICBpY28u
Y2xhc3NOYW1lID0gJ2ktaWNvIGltYWdlJzsKICAgICAgICAgICAgaWNvLmlubmVySFRNTCA9IFNWRy5p
bWFnZTsKICAgICAgICAgICAgYmluZEltZ0hvdmVyUHJldmlldyhpY28sIGMuaWQsIGMuaW1nRmlsZSk7
CiAgICAgICAgICAgIGNvbnN0IHdyYXAgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsKICAg
ICAgICAgICAgd3JhcC5jbGFzc05hbWUgPSAnaS10aHVtYi13cmFwJzsKICAgICAgICAgICAgY29uc3Qg
aW1nICA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2ltZycpOwogICAgICAgICAgICBpbWcuY2xhc3NO
YW1lID0gJ2ktdGh1bWInOwogICAgICAgICAgICBpbWcuYWx0ID0gJyc7CiAgICAgICAgICAgIGNvbnN0
IGZpbGUgPSBTdHJpbmcoYy5pbWdGaWxlIHx8ICcnKTsKICAgICAgICAgICAgbGV0IGZhbGxiYWNrID0g
U3RyaW5nKGMuZGF0YSB8fCAnJyk7CiAgICAgICAgICAgIC8vIE5ldmVyIHN5bmMtY2FsbCBBSEsgdGh1
bWIgaGVyZSDigJQgZnJlZXplcyB0YWIgc3dpdGNoZXM7IFB1c2hTdG9yZVRodW1icyBmaWxscyBhc3lu
YwogICAgICAgICAgICBpZiAoIWZhbGxiYWNrLnN0YXJ0c1dpdGgoJ2RhdGE6JykgJiYgdGh1bWJDYWNo
ZS5oYXMoU3RyaW5nKGMuaWQpKSkKICAgICAgICAgICAgICAgIGZhbGxiYWNrID0gU3RyaW5nKHRodW1i
Q2FjaGUuZ2V0KFN0cmluZyhjLmlkKSkpOwogICAgICAgICAgICBpbWcub25sb2FkID0gKCkgPT4gewog
ICAgICAgICAgICAgICAgY29uc3QgbXcgPSB3cmFwLmNsaWVudFdpZHRoIHx8IDMwMDsKICAgICAgICAg
ICAgICAgIGNvbnN0IG53ID0gaW1nLm5hdHVyYWxXaWR0aCAgfHwgMDsKICAgICAgICAgICAgICAgIGNv
bnN0IG5oID0gaW1nLm5hdHVyYWxIZWlnaHQgfHwgMDsKICAgICAgICAgICAgICAgIGlmICghbncgfHwg
IW5oKSByZXR1cm47CiAgICAgICAgICAgICAgICBjb25zdCBzY2FsZSA9IE1hdGgubWluKDEsIDE4MCAv
IG5oLCBtdyAvIG53KTsKICAgICAgICAgICAgICAgIGltZy5zdHlsZS53aWR0aCAgPSBNYXRoLnJvdW5k
KG53ICogc2NhbGUpICsgJ3B4JzsKICAgICAgICAgICAgICAgIGltZy5zdHlsZS5oZWlnaHQgPSBNYXRo
LnJvdW5kKG5oICogc2NhbGUpICsgJ3B4JzsKICAgICAgICAgICAgfTsKICAgICAgICAgICAgYmluZFN0
b3JlVGh1bWIoaW1nLCBmaWxlLCBjLmlkLCBmYWxsYmFjayk7CiAgICAgICAgICAgIHdyYXAuYXBwZW5k
Q2hpbGQoaW1nKTsKICAgICAgICAgICAgY29uc3QgbWV0YSA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQo
J2RpdicpOwogICAgICAgICAgICBtZXRhLmNsYXNzTmFtZSA9ICdpLW1ldGEnOwogICAgICAgICAgICBt
ZXRhLmlubmVySFRNTCAgPSBgPHNwYW4gY2xhc3M9ImktdGltZSI+JHthZ28oYy50aW1lKX08L3NwYW4+
JHttZXRhQ2VudGVySHRtbChmYWxzZSl9PGRpdiBjbGFzcz0iaS1tZXRhLXJpZ2h0Ij4ke2Mud2lkdGgg
PyBgPHNwYW4gY2xhc3M9ImktdGFnIj4ke2Mud2lkdGh9w5cke2MuaGVpZ2h0fSBweDwvc3Bhbj5gIDog
Jyd9PC9kaXY+YDsKICAgICAgICAgICAgYm9keS5hcHBlbmRDaGlsZCh3cmFwKTsKICAgICAgICAgICAg
Ym9keS5hcHBlbmRDaGlsZChtZXRhKTsKICAgICAgICB9IGVsc2UgaWYgKHR5cGUgPT09ICdyZWNlbnQn
KSB7CiAgICAgICAgICAgIGljby5jbGFzc05hbWUgPSAnaS1pY28gZmlsZSBmdC1kaXInOwogICAgICAg
ICAgICBpY28uaW5uZXJIVE1MID0gU1ZHLmZvbGRlcjsKICAgICAgICAgICAgY29uc3QgcGF0aCA9IFN0
cmluZyhjLmRhdGEgfHwgYy5wcmV2aWV3IHx8ICcnKTsKICAgICAgICAgICAgY29uc3QgY3J1bWJzID0g
ZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnZGl2Jyk7CiAgICAgICAgICAgIGNydW1icy5jbGFzc05hbWUg
PSAncmYtcGF0aCc7CiAgICAgICAgICAgIGJ1aWxkUmVjZW50UGF0aENydW1icyhjcnVtYnMsIHBhdGgp
OwogICAgICAgICAgICBjb25zdCBtZXRhID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnZGl2Jyk7CiAg
ICAgICAgICAgIG1ldGEuY2xhc3NOYW1lID0gJ2ktbWV0YSc7CiAgICAgICAgICAgIG1ldGEuaW5uZXJI
VE1MID0KICAgICAgICAgICAgICAgIGA8c3BhbiBjbGFzcz0iaS10aW1lIj4ke2FnbyhjLnRpbWUpfTwv
c3Bhbj5gICsKICAgICAgICAgICAgICAgIG1ldGFDZW50ZXJIdG1sKGZhbHNlKSArCiAgICAgICAgICAg
ICAgICBgPGRpdiBjbGFzcz0iaS1tZXRhLXJpZ2h0Ij4ke3Bpbm5lZCA/ICc8c3BhbiBjbGFzcz0iaS10
YWciPuWbuuWumjwvc3Bhbj4nIDogJyd9PC9kaXY+YDsKICAgICAgICAgICAgYm9keS5hcHBlbmRDaGls
ZChjcnVtYnMpOwogICAgICAgICAgICBib2R5LmFwcGVuZENoaWxkKG1ldGEpOwogICAgICAgIH0gZWxz
ZSBpZiAodHlwZSA9PT0gJ2ZpbGUnKSB7CiAgICAgICAgICAgIGNvbnN0IGZpbGVzID0gU3RyaW5nKGMu
cHJldmlldyB8fCBjLmRhdGEgfHwgJycpLnNwbGl0KC9ccj9cbi8pLmZpbHRlcihCb29sZWFuKTsKICAg
ICAgICAgICAgY29uc3QgaW1hZ2VQYXRocyA9IGZpbGVzLmZpbHRlcihmID0+IGlzSW1hZ2VFeHQoZmls
ZUV4dChmKSkpOwogICAgICAgICAgICBjb25zdCBpYyAgICA9IGljb25Gb3JGaWxlcyhmaWxlcyk7CiAg
ICAgICAgICAgIGljby5jbGFzc05hbWUgPSAnaS1pY28gJyArIGljLmNsczsKICAgICAgICAgICAgaWNv
LmlubmVySFRNTCA9IGljLnN2ZzsKCiAgICAgICAgICAgIGxldCB0aHVtYkZpbGUgPSBTdHJpbmcoYy5p
bWdGaWxlIHx8ICcnKTsKICAgICAgICAgICAgLyogZW5zdXJlRmlsZUltZyBkZWZlcnJlZDogYXZvaWQg
c3luYyBmcmVlemUgb24gZmlsZSB0YWIgKi8KCiAgICAgICAgICAgIC8vIEltYWdlLWZvcm1hdCBmaWxl
czogc2FtZSB0aHVtYm5haWwgcnVsZXMgYXMgc2NyZWVuc2hvdCBjbGlwcwogICAgICAgICAgICBpZiAo
dGh1bWJGaWxlIHx8IGltYWdlUGF0aHMubGVuZ3RoKSB7CiAgICAgICAgICAgICAgICBjb25zdCB3cmFw
ID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnZGl2Jyk7CiAgICAgICAgICAgICAgICB3cmFwLmNsYXNz
TmFtZSA9ICdpLXRodW1iLXdyYXAnOwogICAgICAgICAgICAgICAgY29uc3QgaW1nICA9IGRvY3VtZW50
LmNyZWF0ZUVsZW1lbnQoJ2ltZycpOwogICAgICAgICAgICAgICAgaW1nLmNsYXNzTmFtZSA9ICdpLXRo
dW1iJzsKICAgICAgICAgICAgICAgIGltZy5hbHQgPSAnJzsKICAgICAgICAgICAgICAgIGltZy5vbmxv
YWQgPSAoKSA9PiB7CiAgICAgICAgICAgICAgICAgICAgY29uc3QgbXcgPSB3cmFwLmNsaWVudFdpZHRo
IHx8IDMwMDsKICAgICAgICAgICAgICAgICAgICBjb25zdCBudyA9IGltZy5uYXR1cmFsV2lkdGggIHx8
IDA7CiAgICAgICAgICAgICAgICAgICAgY29uc3QgbmggPSBpbWcubmF0dXJhbEhlaWdodCB8fCAwOwog
ICAgICAgICAgICAgICAgICAgIGlmICghbncgfHwgIW5oKSByZXR1cm47CiAgICAgICAgICAgICAgICAg
ICAgY29uc3Qgc2NhbGUgPSBNYXRoLm1pbigxLCAxODAgLyBuaCwgbXcgLyBudyk7CiAgICAgICAgICAg
ICAgICAgICAgaW1nLnN0eWxlLndpZHRoICA9IE1hdGgucm91bmQobncgKiBzY2FsZSkgKyAncHgnOwog
ICAgICAgICAgICAgICAgICAgIGltZy5zdHlsZS5oZWlnaHQgPSBNYXRoLnJvdW5kKG5oICogc2NhbGUp
ICsgJ3B4JzsKICAgICAgICAgICAgICAgIH07CiAgICAgICAgICAgIC8qIGVuc3VyZUZpbGVJbWcgZGVm
ZXJyZWQ6IGF2b2lkIHN5bmMgZnJlZXplIG9uIGZpbGUgdGFiICovCiAgICAgICAgICAgICAgICBiaW5k
U3RvcmVUaHVtYihpbWcsIHRodW1iRmlsZSwgYy5pZCwgJycpOwogICAgICAgICAgICAgICAgd3JhcC5h
cHBlbmRDaGlsZChpbWcpOwogICAgICAgICAgICAgICAgYm9keS5hcHBlbmRDaGlsZCh3cmFwKTsKICAg
ICAgICAgICAgfQoKICAgICAgICAgICAgY29uc3QgbmFtZSA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQo
J2RpdicpOwogICAgICAgICAgICBuYW1lLmNsYXNzTmFtZSAgPSAnaS1uYW1lJzsKICAgICAgICAgICAg
c2V0SGxUZXh0KG5hbWUsIGZpbGVzLm1hcChmID0+IGYuc3BsaXQoL1tcXC9dLykucG9wKCkpLmpvaW4o
J1xuJykgfHwgJyjmlofku7YpJyk7CgogICAgICAgICAgICBlbC5fZmlsZVBhdGhzID0gZmlsZXM7Cgog
ICAgICAgICAgICBjb25zdCBkZXRhaWwgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsKICAg
ICAgICAgICAgZGV0YWlsLmNsYXNzTmFtZSA9ICdpLWZpbGUtZGV0YWlsJzsKCiAgICAgICAgICAgIGNv
bnN0IG1ldGEgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsKICAgICAgICAgICAgbWV0YS5j
bGFzc05hbWUgPSAnaS1tZXRhJzsKICAgICAgICAgICAgbGV0IHJpZ2h0ID0gJyc7CiAgICAgICAgICAg
IHJpZ2h0ICs9IGA8c3BhbiBjbGFzcz0iaS10YWciPiR7Yy5maWxlQ291bnQgfHwgZmlsZXMubGVuZ3Ro
IHx8IDF9IOS4quaWh+S7tjwvc3Bhbj5gOwogICAgICAgICAgICBpZiAoKHRodW1iRmlsZSB8fCBpbWFn
ZVBhdGhzLmxlbmd0aCkgJiYgYy53aWR0aCkKICAgICAgICAgICAgICAgIHJpZ2h0ICs9IGA8c3BhbiBj
bGFzcz0iaS10YWciPiR7Yy53aWR0aH3DlyR7Yy5oZWlnaHR9IHB4PC9zcGFuPmA7CiAgICAgICAgICAg
IGNvbnN0IGV4cGFuZEh0bWwgPSBleHBhbmRDaGV2cm9uKGZhbHNlKTsKICAgICAgICAgICAgY29uc3Qg
Y29sbGFwc2VIdG1sID0gZXhwYW5kQ2hldnJvbih0cnVlKTsKICAgICAgICAgICAgbWV0YS5pbm5lckhU
TUwgPQogICAgICAgICAgICAgICAgYDxzcGFuIGNsYXNzPSJpLXRpbWUiPiR7YWdvKGMudGltZSl9PC9z
cGFuPmAgKwogICAgICAgICAgICAgICAgbWV0YUNlbnRlckh0bWwoeyBvbjogdHJ1ZSwgaHRtbDogZXhw
YW5kSHRtbCB9KSArCiAgICAgICAgICAgICAgICBgPGRpdiBjbGFzcz0iaS1tZXRhLXJpZ2h0Ij4ke3Jp
Z2h0fTwvZGl2PmA7CgogICAgICAgICAgICBjb25zdCBleHBCdG4gPSBtZXRhLnF1ZXJ5U2VsZWN0b3Io
Jy5pLWV4cGFuZC1idG4nKTsKICAgICAgICAgICAgbGV0IGRldGFpbEJ1aWx0ID0gZmFsc2U7CiAgICAg
ICAgICAgIGV4cEJ0bi5vbmNsaWNrID0gZSA9PiB7CiAgICAgICAgICAgICAgICBlLnByZXZlbnREZWZh
dWx0KCk7CiAgICAgICAgICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgICAgICAgICAgICAg
Y29uc3Qgb3BlbiA9ICFkZXRhaWwuY2xhc3NMaXN0LmNvbnRhaW5zKCdvbicpOwogICAgICAgICAgICAg
ICAgaWYgKG9wZW4gJiYgIWRldGFpbEJ1aWx0KSB7CiAgICAgICAgICAgICAgICAgICAgY29uc3QgcGF0
aFJvd3MgPSBlbC5fcGF0aFJvd3MgfHwgY2hlY2tGaWxlUGF0aHMoZWwuX2ZpbGVQYXRocyB8fCBmaWxl
cyk7CiAgICAgICAgICAgICAgICAgICAgZmlsbEZpbGVEZXRhaWxQYW5lbChkZXRhaWwsIHBhdGhSb3dz
KTsKICAgICAgICAgICAgICAgICAgICBkZXRhaWxCdWlsdCA9IHRydWU7CiAgICAgICAgICAgICAgICB9
CiAgICAgICAgICAgICAgICBkZXRhaWwuY2xhc3NMaXN0LnRvZ2dsZSgnb24nLCBvcGVuKTsKICAgICAg
ICAgICAgICAgIGlmIChvcGVuKSB7CiAgICAgICAgICAgICAgICAgICAgZGV0YWlsLnN0eWxlLm1heEhl
aWdodCA9IGxpc3RFeHBhbmRNYXhQeCgpICsgJ3B4JzsKICAgICAgICAgICAgICAgICAgICBkZXRhaWwu
c3R5bGUub3ZlcmZsb3cgPSAnYXV0byc7CiAgICAgICAgICAgICAgICB9IGVsc2UgewogICAgICAgICAg
ICAgICAgICAgIGRldGFpbC5zdHlsZS5tYXhIZWlnaHQgPSAnJzsKICAgICAgICAgICAgICAgICAgICBk
ZXRhaWwuc3R5bGUub3ZlcmZsb3cgPSAnJzsKICAgICAgICAgICAgICAgIH0KICAgICAgICAgICAgICAg
IGV4cEJ0bi5pbm5lckhUTUwgPSBvcGVuID8gY29sbGFwc2VIdG1sIDogZXhwYW5kSHRtbDsKICAgICAg
ICAgICAgfTsKCiAgICAgICAgICAgIGJvZHkuYXBwZW5kQ2hpbGQobmFtZSk7CiAgICAgICAgICAgIGJv
ZHkuYXBwZW5kQ2hpbGQoZGV0YWlsKTsKICAgICAgICAgICAgYm9keS5hcHBlbmRDaGlsZChtZXRhKTsK
ICAgICAgICB9IGVsc2UgewogICAgICAgICAgICBjb25zdCB1c2VNID0gY2xpcFVzZXNNSWNvbihjKTsK
ICAgICAgICAgICAgaWNvLmNsYXNzTmFtZSA9IHVzZU0gPyAnaS1pY28gbWQnIDogJ2ktaWNvIHRleHQn
OwogICAgICAgICAgICBpY28uaW5uZXJIVE1MID0gdXNlTSA/IChTVkcubWQgfHwgU1ZHLnRleHQpIDog
U1ZHLnRleHQ7CiAgICAgICAgICAgIC8qIHBsYWluLWxpc3QtcHJldiAqLwogICAgICAgICAgICAvKiBw
cmV2aWV3LWVsbGlwc2lzICovCiAgICAgICAgICAgIGxldCB0eHQgID0gYy5wcmV2aWV3IHx8IGMuZGF0
YSB8fCAnJzsKICAgICAgICAgICAgeyBjb25zdCBfbiA9IE51bWJlcihjLmNoYXJDb3VudCkgfHwgMDsg
aWYgKF9uID4gdHh0Lmxlbmd0aCAmJiB0eHQubGVuZ3RoKSB0eHQgKz0gJy4uLic7IH0KICAgICAgICAg
ICAgY29uc3QgcHJldiA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOwogICAgICAgICAgICBw
cmV2LmNsYXNzTmFtZSAgPSAnaS1wcmV2JyArIChpc1VybCh0eHQpID8gJyB1cmwnIDogJycpOwogICAg
ICAgICAgICBzZXRIbFRleHQocHJldiwgdHh0KTsKCiAgICAgICAgICAgIGNvbnN0IG1ldGEgPSBkb2N1
bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsKICAgICAgICAgICAgbWV0YS5jbGFzc05hbWUgPSAnaS1t
ZXRhJzsKCiAgICAgICAgICAgIGNvbnN0IGNoYXJzID0gTnVtYmVyKGMuY2hhckNvdW50KSB8fCAwOwog
ICAgICAgICAgICBjb25zdCByaWdodEhUTUwgPSBgPHNwYW4gY2xhc3M9ImktY2hhcnMiPjxzcGFuIGNs
YXNzPSJuIj4ke2NoYXJzfTwvc3Bhbj4g5a2X56ymPC9zcGFuPmA7CgogICAgICAgICAgICBtZXRhLmlu
bmVySFRNTCA9CiAgICAgICAgICAgICAgICBgPHNwYW4gY2xhc3M9ImktdGltZSI+JHthZ28oYy50aW1l
KX08L3NwYW4+YCArCiAgICAgICAgICAgICAgICBtZXRhQ2VudGVySHRtbCh7CiAgICAgICAgICAgICAg
ICAgICAgb246IGZhbHNlLAogICAgICAgICAgICAgICAgICAgIGh0bWw6IGV4cGFuZENoZXZyb24oZmFs
c2UpCiAgICAgICAgICAgICAgICB9KSArCiAgICAgICAgICAgICAgICBgPGRpdiBjbGFzcz0iaS1tZXRh
LXJpZ2h0IHRleHQtbWV0YSI+JHtyaWdodEhUTUx9PC9kaXY+YDsKCiAgICAgICAgICAgIGJvZHkuYXBw
ZW5kQ2hpbGQocHJldik7CiAgICAgICAgICAgIGJvZHkuYXBwZW5kQ2hpbGQobWV0YSk7CgogICAgICAg
ICAgICBjb25zdCBleHBCdG4gPSBtZXRhLnF1ZXJ5U2VsZWN0b3IoJy5pLWV4cGFuZC1idG4nKTsKICAg
ICAgICAgICAgaWYgKGV4cEJ0bikgewogICAgICAgICAgICAgICAgZXhwQnRuLm9uY2xpY2sgPSBlID0+
IHsKICAgICAgICAgICAgICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgICAgICAgICAgICAg
ICAgIGNvbnN0IHdpbGxFeHBhbmQgPSAhcHJldi5jbGFzc0xpc3QuY29udGFpbnMoJ2V4cGFuZGVkJyk7
CiAgICAgICAgICAgICAgICAgICAgaWYgKHdpbGxFeHBhbmQpIHsKICAgICAgICAgICAgICAgICAgICAg
ICAgYXBwbHlFeHBhbmRlZFByZXZpZXcocHJldiwgdHh0KTsKICAgICAgICAgICAgICAgICAgICAgICAg
ZXhwQnRuLmlubmVySFRNTCA9IGV4cGFuZENoZXZyb24odHJ1ZSk7CiAgICAgICAgICAgICAgICAgICAg
ICAgIHRyeSB7IGVsLnNjcm9sbEludG9WaWV3KHsgYmxvY2s6ICduZWFyZXN0JyB9KTsgfSBjYXRjaCB7
fQogICAgICAgICAgICAgICAgICAgIH0gZWxzZSB7CiAgICAgICAgICAgICAgICAgICAgICAgIGNvbGxh
cHNlUHJldmlldyhwcmV2LCB0eHQpOwogICAgICAgICAgICAgICAgICAgICAgICBleHBCdG4uaW5uZXJI
VE1MID0gZXhwYW5kQ2hldnJvbihmYWxzZSk7CiAgICAgICAgICAgICAgICAgICAgfQogICAgICAgICAg
ICAgICAgfTsKICAgICAgICAgICAgICAgIGNvbnN0IGNoZWNrT3ZlcmZsb3cgPSAoKSA9PiB7CiAgICAg
ICAgICAgICAgICAgICAgY29uc3QgcGxhaW5MZW4gPSBTdHJpbmcoYy5wcmV2aWV3IHx8IGMuZGF0YSB8
fCAnJykubGVuZ3RoOwogICAgICAgICAgICAgICAgICAgIGNvbnN0IGZ1bGxOID0gTnVtYmVyKGMuY2hh
ckNvdW50KSB8fCAwOwogICAgICAgICAgICAgICAgICAgIGNvbnN0IHRydW5jID0gZnVsbE4gPiBwbGFp
bkxlbjsKICAgICAgICAgICAgICAgICAgICBpZiAocHJldi5zY3JvbGxIZWlnaHQgPiBwcmV2LmNsaWVu
dEhlaWdodCArIDIgfHwgdHJ1bmMpCiAgICAgICAgICAgICAgICAgICAgICAgIGV4cEJ0bi5jbGFzc0xp
c3QuYWRkKCdvbicpOwogICAgICAgICAgICAgICAgICAgIGVsc2UKICAgICAgICAgICAgICAgICAgICAg
ICAgZXhwQnRuLmNsYXNzTGlzdC5yZW1vdmUoJ29uJyk7CiAgICAgICAgICAgICAgICB9OwogICAgICAg
ICAgICAgICAgcmVxdWVzdEFuaW1hdGlvbkZyYW1lKGNoZWNrT3ZlcmZsb3cpOwogICAgICAgICAgICAg
ICAgc2V0VGltZW91dChjaGVja092ZXJmbG93LCA4MCk7CiAgICAgICAgICAgIH0KICAgICAgICB9Cgog
ICAgICAgIGNvbnN0IGZhdlQgPSBTdHJpbmcoYy5mYXZUaXRsZSB8fCAnJykudHJpbSgpOwogICAgICAg
IGlmIChmYXZUKSB7CiAgICAgICAgICAgIGNvbnN0IGZ0ID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgn
ZGl2Jyk7CiAgICAgICAgICAgIGZ0LmNsYXNzTmFtZSA9ICdpLWZhdi10aXRsZSc7CiAgICAgICAgICAg
IHNldEhsVGV4dChmdCwgZmF2VCk7CiAgICAgICAgICAgIGJvZHkuaW5zZXJ0QmVmb3JlKGZ0LCBib2R5
LmZpcnN0Q2hpbGQpOwogICAgICAgIH0KCiAgICAgICAgaWYgKHBhc3RlZCkgewogICAgICAgICAgICBj
b25zdCBiYWRnZSA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ3NwYW4nKTsKICAgICAgICAgICAgYmFk
Z2UuY2xhc3NOYW1lID0gJ2ktdXNlZCc7CiAgICAgICAgICAgIGJhZGdlLnRpdGxlID0gJ+W3sueymOi0
tCc7CiAgICAgICAgICAgIGJhZGdlLmlubmVySFRNTCA9IGA8c3ZnIHZpZXdCb3g9IjAgMCAxNiAxNiIg
ZmlsbD0ibm9uZSIgc3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0cm9rZS13aWR0aD0iMi40IiBzdHJva2Ut
bGluZWNhcD0icm91bmQiIHN0cm9rZS1saW5lam9pbj0icm91bmQiPjxwb2x5bGluZSBwb2ludHM9IjMu
NSA4LjUgNi41IDExLjUgMTIuNSA0LjUiLz48L3N2Zz5gOwogICAgICAgICAgICBpY28uYXBwZW5kQ2hp
bGQoYmFkZ2UpOwogICAgICAgIH0KCiAgICAgICAgY29uc3QgbnVtID0gZG9jdW1lbnQuY3JlYXRlRWxl
bWVudCgnZGl2Jyk7CiAgICAgICAgbnVtLmNsYXNzTmFtZSA9ICdpLW51bSc7CiAgICAgICAgY29uc3Qg
bnVtVHh0ID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnc3BhbicpOwogICAgICAgIG51bVR4dC50ZXh0
Q29udGVudCA9IGlkeDsKICAgICAgICBudW0uYXBwZW5kQ2hpbGQobnVtVHh0KTsKICAgICAgICBjb25z
dCBzcmNJY28gPSBTdHJpbmcoYy5zcmNJY29uIHx8ICcnKTsKICAgICAgICBjb25zdCBzcmNFeGUgPSBT
dHJpbmcoYy5zcmNFeGUgfHwgJycpOwogICAgICAgIGNvbnN0IHNyY1RpdGxlID0gU3RyaW5nKGMuc3Jj
VGl0bGUgfHwgJycpOwogICAgICAgIGlmIChzcmNJY28pIHsKICAgICAgICAgICAgY29uc3QgaW1nID0g
ZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnaW1nJyk7CiAgICAgICAgICAgIGltZy5jbGFzc05hbWUgPSAn
aS1zcmMtaWNvJzsKICAgICAgICAgICAgaW1nLnNyYyA9IFNUT1JFX0JBU0UgKyBlbmNvZGVVUklDb21w
b25lbnQoc3JjSWNvKTsKICAgICAgICAgICAgaW1nLmFsdCA9ICcnOwogICAgICAgICAgICBjb25zdCB0
aXBUeHQgPSBzcmNUaXRsZSB8fCBzcmNFeGUgfHwgJ+adpea6kCc7CiAgICAgICAgICAgIGltZy50aXRs
ZSA9IHRpcFR4dDsKICAgICAgICAgICAgaW1nLm9uY2xpY2sgPSBlID0+IHsgZS5wcmV2ZW50RGVmYXVs
dCgpOyBlLnN0b3BQcm9wYWdhdGlvbigpOyBzaG93U3JjVGlwKGltZywgdGlwVHh0KTsgfTsKICAgICAg
ICAgICAgbnVtLmFwcGVuZENoaWxkKGltZyk7CiAgICAgICAgfQoKICAgICAgICBlbC5hcHBlbmRDaGls
ZChpY28pOwogICAgICAgIGVsLmFwcGVuZENoaWxkKGJvZHkpOwogICAgICAgIGVsLmFwcGVuZENoaWxk
KG51bSk7CgogICAgICAgIGVsLm9ucG9pbnRlcmRvd24gPSBlID0+IHsKICAgICAgICAgICAgYmVnaW5Q
YXN0ZUZyb21JdGVtKGUsIGMpOwogICAgICAgIH07CiAgICAgICAgZWwub25jb250ZXh0bWVudSA9IGUg
PT4gewogICAgICAgICAgICBlLnByZXZlbnREZWZhdWx0KCk7CiAgICAgICAgICAgIHNlbGVjdGVkSWQg
PSBjLmlkOwogICAgICAgICAgICBzaG93Q3R4KGUuY2xpZW50WCwgZS5jbGllbnRZLCBjKTsKICAgICAg
ICB9OwoKICAgICAgICByZXR1cm4gZWw7CiAgICB9CgogICAgY29uc3QgcGF0aFRpcEVsID0gZG9jdW1l
bnQuZ2V0RWxlbWVudEJ5SWQoJ3BhdGgtdGlwJyk7CiAgICBsZXQgcGF0aFRpcFRpbWVyID0gMDsKICAg
IGxldCBwYXRoVGlwSGlkZVRpbWVyID0gMDsKICAgIGxldCBwYXRoVGlwVG9rZW4gPSAwOwogICAgbGV0
IHBhdGhUaXBBbmNob3JCdG4gPSBudWxsOwoKICAgIGZ1bmN0aW9uIGhpZGVQYXRoVGlwKCkgewogICAg
ICAgIGNsZWFyVGltZW91dChwYXRoVGlwVGltZXIpOwogICAgICAgIGNsZWFyVGltZW91dChwYXRoVGlw
SGlkZVRpbWVyKTsKICAgICAgICBwYXRoVGlwVG9rZW4rKzsKICAgICAgICBpZiAocGF0aFRpcEFuY2hv
ckJ0bikgewogICAgICAgICAgICBwYXRoVGlwQW5jaG9yQnRuLmNsYXNzTGlzdC5yZW1vdmUoJ29uJyk7
CiAgICAgICAgICAgIHBhdGhUaXBBbmNob3JCdG4gPSBudWxsOwogICAgICAgIH0KICAgICAgICBpZiAo
cGF0aFRpcEVsKSB7CiAgICAgICAgICAgIHBhdGhUaXBFbC5jbGFzc0xpc3QucmVtb3ZlKCdvbicpOwog
ICAgICAgICAgICBwYXRoVGlwRWwuc2V0QXR0cmlidXRlKCdhcmlhLWhpZGRlbicsICd0cnVlJyk7CiAg
ICAgICAgfQogICAgfQogICAgZnVuY3Rpb24gcGxhY2VQYXRoVGlwKGFuY2hvckVsKSB7CiAgICAgICAg
aWYgKCFwYXRoVGlwRWwgfHwgIWFuY2hvckVsKSByZXR1cm47CiAgICAgICAgY29uc3QgdGlwID0gcGF0
aFRpcEVsOwogICAgICAgIGNvbnN0IGFyID0gYW5jaG9yRWwuZ2V0Qm91bmRpbmdDbGllbnRSZWN0KCk7
CiAgICAgICAgY29uc3QgcGFkID0gODsKICAgICAgICB0aXAuc3R5bGUubGVmdCA9ICcwcHgnOwogICAg
ICAgIHRpcC5zdHlsZS50b3AgPSAnMHB4JzsKICAgICAgICB0aXAuY2xhc3NMaXN0LmFkZCgnb24nKTsK
ICAgICAgICBjb25zdCB0dyA9IHRpcC5vZmZzZXRXaWR0aDsKICAgICAgICBjb25zdCB0aCA9IHRpcC5v
ZmZzZXRIZWlnaHQ7CiAgICAgICAgbGV0IGxlZnQgPSBhci5sZWZ0OwogICAgICAgIGxldCB0b3AgPSBh
ci5ib3R0b20gKyA2OwogICAgICAgIGlmIChsZWZ0ICsgdHcgPiB3aW5kb3cuaW5uZXJXaWR0aCAtIHBh
ZCkKICAgICAgICAgICAgbGVmdCA9IE1hdGgubWF4KHBhZCwgd2luZG93LmlubmVyV2lkdGggLSB0dyAt
IHBhZCk7CiAgICAgICAgaWYgKGxlZnQgPCBwYWQpIGxlZnQgPSBwYWQ7CiAgICAgICAgaWYgKHRvcCAr
IHRoID4gd2luZG93LmlubmVySGVpZ2h0IC0gcGFkKQogICAgICAgICAgICB0b3AgPSBNYXRoLm1heChw
YWQsIGFyLnRvcCAtIHRoIC0gNik7CiAgICAgICAgdGlwLnN0eWxlLmxlZnQgPSBsZWZ0ICsgJ3B4JzsK
ICAgICAgICB0aXAuc3R5bGUudG9wID0gdG9wICsgJ3B4JzsKICAgIH0KICAgICAgICBmdW5jdGlvbiBj
aGVja0ZpbGVQYXRocyhwYXRocykgewogICAgICAgIGNvbnN0IGxpc3QgPSAocGF0aHMgfHwgW10pLm1h
cChwID0+IHsKICAgICAgICAgICAgbGV0IHBhdGggPSBTdHJpbmcocCB8fCAnJykudHJpbSgpOwogICAg
ICAgICAgICBpZiAoKHBhdGguc3RhcnRzV2l0aCgnIicpICYmIHBhdGguZW5kc1dpdGgoJyInKSkgfHwg
KHBhdGguc3RhcnRzV2l0aCgiJyIpICYmIHBhdGguZW5kc1dpdGgoIiciKSkpCiAgICAgICAgICAgICAg
ICBwYXRoID0gcGF0aC5zbGljZSgxLCAtMSkudHJpbSgpOwogICAgICAgICAgICByZXR1cm4gcGF0aDsK
ICAgICAgICB9KTsKICAgICAgICAvLyBPbmUgaG9zdCByb3VuZC10cmlwIGZvciB0aGUgd2hvbGUgbGlz
dCDigJQgTsOXIHBhdGhFeGlzdHMgZnJlZXplcyBmaWxlIHRhYgogICAgICAgIHRyeSB7CiAgICAgICAg
ICAgIGNvbnN0IHJhdyA9IGFoa1JldCgnY2hlY2tQYXRocycsIGxpc3Quam9pbignXG4nKSk7CiAgICAg
ICAgICAgIGlmIChyYXcpIHsKICAgICAgICAgICAgICAgIGNvbnN0IHBhcnNlZCA9IHR5cGVvZiByYXcg
PT09ICdzdHJpbmcnID8gSlNPTi5wYXJzZShyYXcpIDogcmF3OwogICAgICAgICAgICAgICAgaWYgKEFy
cmF5LmlzQXJyYXkocGFyc2VkKSAmJiBwYXJzZWQubGVuZ3RoKSB7CiAgICAgICAgICAgICAgICAgICAg
cmV0dXJuIGxpc3QubWFwKChwYXRoLCBpKSA9PiB7CiAgICAgICAgICAgICAgICAgICAgICAgIGNvbnN0
IHJvdyA9IHBhcnNlZFtpXSB8fCB7fTsKICAgICAgICAgICAgICAgICAgICAgICAgcmV0dXJuIHsKICAg
ICAgICAgICAgICAgICAgICAgICAgICAgIHBhdGg6IHBhdGggfHwgU3RyaW5nKHJvdy5wYXRoIHx8ICcn
KSwKICAgICAgICAgICAgICAgICAgICAgICAgICAgIGV4aXN0czogcm93LmV4aXN0cyA9PT0gdHJ1ZSB8
fCByb3cuZXhpc3RzID09PSAxIHx8IHJvdy5leGlzdHMgPT09ICcxJywKICAgICAgICAgICAgICAgICAg
ICAgICAgICAgIGlzRGlyOiAhIShyb3cuaXNEaXIgPT09IHRydWUgfHwgcm93LmlzRGlyID09PSAxIHx8
IHJvdy5pc0RpciA9PT0gJzEnKQogICAgICAgICAgICAgICAgICAgICAgICB9OwogICAgICAgICAgICAg
ICAgICAgIH0pOwogICAgICAgICAgICAgICAgfQogICAgICAgICAgICB9CiAgICAgICAgfSBjYXRjaCB7
fQogICAgICAgIHJldHVybiBsaXN0Lm1hcChwYXRoID0+IHsKICAgICAgICAgICAgaWYgKCFwYXRoKSBy
ZXR1cm4geyBwYXRoLCBleGlzdHM6IGZhbHNlLCBpc0RpcjogZmFsc2UgfTsKICAgICAgICAgICAgbGV0
IGV4aXN0cyA9IGZhbHNlOwogICAgICAgICAgICB0cnkgewogICAgICAgICAgICAgICAgY29uc3QgZmxh
ZyA9IFN0cmluZyhhaGtSZXQoJ3BhdGhFeGlzdHMnLCBwYXRoKSA/PyAnJykudHJpbSgpLnRvTG93ZXJD
YXNlKCk7CiAgICAgICAgICAgICAgICBleGlzdHMgPSAoZmxhZyA9PT0gJzEnIHx8IGZsYWcgPT09ICd0
cnVlJyk7CiAgICAgICAgICAgIH0gY2F0Y2gge30KICAgICAgICAgICAgcmV0dXJuIHsgcGF0aCwgZXhp
c3RzLCBpc0RpcjogZmFsc2UgfTsKICAgICAgICB9KTsKICAgIH0KICAgIGxldCBnb25lQ2hlY2tUaW1l
ciA9IDA7CiAgICBmdW5jdGlvbiBzY2hlZHVsZUZpbGVHb25lQ2hlY2soKSB7CiAgICAgICAgaWYgKGdv
bmVDaGVja1RpbWVyKSByZXR1cm47CiAgICAgICAgZ29uZUNoZWNrVGltZXIgPSBzZXRUaW1lb3V0KCgp
ID0+IHsKICAgICAgICAgICAgZ29uZUNoZWNrVGltZXIgPSAwOwogICAgICAgICAgICBjb25zdCBub2Rl
cyA9IFsuLi5saXN0RWwucXVlcnlTZWxlY3RvckFsbCgnLml0bScpXS5maWx0ZXIobiA9PiBuLl9maWxl
UGF0aHMgJiYgbi5fZmlsZVBhdGhzLmxlbmd0aCk7CiAgICAgICAgICAgIGlmICghbm9kZXMubGVuZ3Ro
KSByZXR1cm47CiAgICAgICAgICAgIGNvbnN0IHVuaXF1ZSA9IFtdOwogICAgICAgICAgICBjb25zdCBz
ZWVuID0gbmV3IFNldCgpOwogICAgICAgICAgICBub2Rlcy5mb3JFYWNoKG4gPT4gewogICAgICAgICAg
ICAgICAgbi5fZmlsZVBhdGhzLmZvckVhY2gocCA9PiB7CiAgICAgICAgICAgICAgICAgICAgY29uc3Qg
cGF0aCA9IFN0cmluZyhwIHx8ICcnKTsKICAgICAgICAgICAgICAgICAgICBpZiAoIXBhdGggfHwgc2Vl
bi5oYXMocGF0aCkpIHJldHVybjsKICAgICAgICAgICAgICAgICAgICBzZWVuLmFkZChwYXRoKTsKICAg
ICAgICAgICAgICAgICAgICB1bmlxdWUucHVzaChwYXRoKTsKICAgICAgICAgICAgICAgIH0pOwogICAg
ICAgICAgICB9KTsKICAgICAgICAgICAgY29uc3Qgcm93cyA9IGNoZWNrRmlsZVBhdGhzKHVuaXF1ZSk7
CiAgICAgICAgICAgIGNvbnN0IGJ5UGF0aCA9IG5ldyBNYXAoKTsKICAgICAgICAgICAgcm93cy5mb3JF
YWNoKHIgPT4gYnlQYXRoLnNldChTdHJpbmcoci5wYXRoIHx8ICcnKSwgcikpOwogICAgICAgICAgICBu
b2Rlcy5mb3JFYWNoKG4gPT4gewogICAgICAgICAgICAgICAgY29uc3QgcGF0aFJvd3MgPSBuLl9maWxl
UGF0aHMubWFwKHAgPT4gewogICAgICAgICAgICAgICAgICAgIGNvbnN0IGhpdCA9IGJ5UGF0aC5nZXQo
U3RyaW5nKHAgfHwgJycpKTsKICAgICAgICAgICAgICAgICAgICByZXR1cm4gaGl0IHx8IHsgcGF0aDog
cCwgZXhpc3RzOiB0cnVlLCBpc0RpcjogZmFsc2UgfTsKICAgICAgICAgICAgICAgIH0pOwogICAgICAg
ICAgICAgICAgbi5fcGF0aFJvd3MgPSBwYXRoUm93czsKICAgICAgICAgICAgICAgIGNvbnN0IGFsbEdv
bmUgPSBwYXRoUm93cy5sZW5ndGggPiAwICYmIHBhdGhSb3dzLmV2ZXJ5KHIgPT4gci5leGlzdHMgPT09
IGZhbHNlKTsKICAgICAgICAgICAgICAgIG4uY2xhc3NMaXN0LnRvZ2dsZSgnZ29uZScsIGFsbEdvbmUp
OwogICAgICAgICAgICB9KTsKICAgICAgICB9LCA0MDApOwogICAgfQogICAgZnVuY3Rpb24gZmlsbEZp
bGVEZXRhaWxQYW5lbChjb250YWluZXIsIHJvd3MpIHsKICAgICAgICBjb250YWluZXIuaW5uZXJIVE1M
ID0gJyc7CiAgICAgICAgaWYgKCFyb3dzLmxlbmd0aCkgewogICAgICAgICAgICBjb25zdCBlbXB0eSA9
IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOwogICAgICAgICAgICBlbXB0eS5jbGFzc05hbWUg
PSAnZmQtcGF0aCc7CiAgICAgICAgICAgIGVtcHR5LnRleHRDb250ZW50ID0gJ+aXoOi3r+W+hCc7CiAg
ICAgICAgICAgIGNvbnRhaW5lci5hcHBlbmRDaGlsZChlbXB0eSk7CiAgICAgICAgICAgIHJldHVybjsK
ICAgICAgICB9CiAgICAgICAgcm93cy5mb3JFYWNoKHIgPT4gewogICAgICAgICAgICBjb25zdCBwYXRo
ID0gU3RyaW5nKHIucGF0aCB8fCAnJyk7CiAgICAgICAgICAgIGNvbnN0IG1pc3NpbmcgPSByLmV4aXN0
cyA9PT0gZmFsc2U7CiAgICAgICAgICAgIGNvbnN0IGJsb2NrID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVu
dCgnZGl2Jyk7CiAgICAgICAgICAgIGJsb2NrLmNsYXNzTmFtZSA9ICdmZC1ibG9jayc7CgogICAgICAg
ICAgICBjb25zdCBwYXRoRWwgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsKICAgICAgICAg
ICAgcGF0aEVsLmNsYXNzTmFtZSA9ICdmZC1wYXRoJyArIChtaXNzaW5nID8gJyBkZWFkJyA6ICcgbGl2
ZScpOwogICAgICAgICAgICBwYXRoRWwudGV4dENvbnRlbnQgPSBwYXRoIHx8ICco56m66Lev5b6EKSc7
CiAgICAgICAgICAgIGlmICghbWlzc2luZykgewogICAgICAgICAgICAgICAgcGF0aEVsLm9uY2xpY2sg
PSBlID0+IHsKICAgICAgICAgICAgICAgICAgICBlLnByZXZlbnREZWZhdWx0KCk7CiAgICAgICAgICAg
ICAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICAgICAgICAgICAgICBhaGsoJ29wZW5Q
YXRoJywgcGF0aCk7CiAgICAgICAgICAgICAgICB9OwogICAgICAgICAgICB9CiAgICAgICAgICAgIGJs
b2NrLmFwcGVuZENoaWxkKHBhdGhFbCk7CgogICAgICAgICAgICBjb25zdCBhY3Rpb25zID0gZG9jdW1l
bnQuY3JlYXRlRWxlbWVudCgnZGl2Jyk7CiAgICAgICAgICAgIGFjdGlvbnMuY2xhc3NOYW1lID0gJ2Zk
LWFjdGlvbnMnOwoKICAgICAgICAgICAgY29uc3QgY29weUJ0biA9IGRvY3VtZW50LmNyZWF0ZUVsZW1l
bnQoJ2J1dHRvbicpOwogICAgICAgICAgICBjb3B5QnRuLnR5cGUgPSAnYnV0dG9uJzsKICAgICAgICAg
ICAgY29weUJ0bi5jbGFzc05hbWUgPSAnZmQtYnRuJzsKICAgICAgICAgICAgY29weUJ0bi5pbm5lckhU
TUwgPSAnPHNwYW4gY2xhc3M9ImZkLWljbyI+8J+Ulzwvc3Bhbj48c3BhbiBjbGFzcz0iZmQtdHh0Ij7l
pI3liLbot6/lvoQ8L3NwYW4+JzsKICAgICAgICAgICAgY29weUJ0bi5vbmNsaWNrID0gZSA9PiB7CiAg
ICAgICAgICAgICAgICBlLnByZXZlbnREZWZhdWx0KCk7CiAgICAgICAgICAgICAgICBlLnN0b3BQcm9w
YWdhdGlvbigpOwogICAgICAgICAgICAgICAgYWhrKCdjb3B5UGF0aCcsIHBhdGgpOwogICAgICAgICAg
ICAgICAgY29weUJ0bi5xdWVyeVNlbGVjdG9yKCcuZmQtdHh0JykudGV4dENvbnRlbnQgPSAn5bey5aSN
5Yi2JzsKICAgICAgICAgICAgICAgIGNvcHlCdG4uY2xhc3NMaXN0LmFkZCgnb2snKTsKICAgICAgICAg
ICAgICAgIHNldFRpbWVvdXQoKCkgPT4gewogICAgICAgICAgICAgICAgICAgIGNvcHlCdG4ucXVlcnlT
ZWxlY3RvcignLmZkLXR4dCcpLnRleHRDb250ZW50ID0gJ+WkjeWItui3r+W+hCc7CiAgICAgICAgICAg
ICAgICAgICAgY29weUJ0bi5jbGFzc0xpc3QucmVtb3ZlKCdvaycpOwogICAgICAgICAgICAgICAgfSwg
MTIwMCk7CiAgICAgICAgICAgIH07CiAgICAgICAgICAgIGFjdGlvbnMuYXBwZW5kQ2hpbGQoY29weUJ0
bik7CgogICAgICAgICAgICBjb25zdCBmb2xkZXJCdG4gPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdi
dXR0b24nKTsKICAgICAgICAgICAgZm9sZGVyQnRuLnR5cGUgPSAnYnV0dG9uJzsKICAgICAgICAgICAg
Zm9sZGVyQnRuLmNsYXNzTmFtZSA9ICdmZC1idG4nOwogICAgICAgICAgICBmb2xkZXJCdG4uaW5uZXJI
VE1MID0gJzxzcGFuIGNsYXNzPSJmZC1pY28iPvCfk4I8L3NwYW4+PHNwYW4gY2xhc3M9ImZkLXR4dCI+
5omT5byA5omA5Zyo5paH5Lu25aS5PC9zcGFuPic7CiAgICAgICAgICAgIGZvbGRlckJ0bi5vbmNsaWNr
ID0gZSA9PiB7CiAgICAgICAgICAgICAgICBlLnByZXZlbnREZWZhdWx0KCk7CiAgICAgICAgICAgICAg
ICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgICAgICAgICAgICAgYWhrKCdvcGVuRm9sZGVyJywgcGF0
aCk7CiAgICAgICAgICAgIH07CiAgICAgICAgICAgIGFjdGlvbnMuYXBwZW5kQ2hpbGQoZm9sZGVyQnRu
KTsKCiAgICAgICAgICAgIGJsb2NrLmFwcGVuZENoaWxkKGFjdGlvbnMpOwogICAgICAgICAgICBjb250
YWluZXIuYXBwZW5kQ2hpbGQoYmxvY2spOwogICAgICAgIH0pOwogICAgfQoKICAgIGNvbnN0IGN0eEVs
ID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2N0eCcpOwogICAgZnVuY3Rpb24gc2hvd0N0eCh4LCB5
LCBjKSB7CiAgICAgICAgY3R4Q2xpcCA9IGM7CiAgICAgICAgc2VsZWN0ZWRJZCA9IGMuaWQ7CiAgICAg
ICAgcmFuZ2VBbmNob3JJZCA9IGMuaWQ7CiAgICAgICAgcmFuZ2VBbmNob3JDbGlja2VkID0gdHJ1ZTsK
ICAgICAgICBjb25zdCBjbGVhckJ0biA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjLWNsZWFyLXBh
c3RlZCcpOwogICAgICAgIGlmIChjbGVhckJ0bikgY2xlYXJCdG4uc3R5bGUuZGlzcGxheSA9IGlzUGFz
dGVkKGMpID8gJycgOiAnbm9uZSc7CgogICAgICAgIGNvbnN0IHBpbkJ0biA9IGRvY3VtZW50LmdldEVs
ZW1lbnRCeUlkKCdjLXBpbicpOwogICAgICAgIGNvbnN0IGlzUmVjZW50ID0gbm9ybVR5cGUoYy50eXBl
KSA9PT0gJ3JlY2VudCcgfHwgY3VyVGFiID09PSAncmVjZW50JzsKICAgICAgICBpZiAocGluQnRuKSB7
CiAgICAgICAgICAgIHBpbkJ0bi5zdHlsZS5kaXNwbGF5ID0gJyc7CiAgICAgICAgICAgIGNvbnN0IG9u
ID0gaXNQaW5uZWQoYyk7CiAgICAgICAgICAgIGlmIChpc1JlY2VudCkgewogICAgICAgICAgICAgICAg
cGluQnRuLmlubmVySFRNTCA9IG9uCiAgICAgICAgICAgICAgICAgICAgPyAnPHNwYW4gY2xhc3M9ImMt
aWNvIj7imIU8L3NwYW4+5Y+W5raI5Zu65a6aJwogICAgICAgICAgICAgICAgICAgIDogJzxzcGFuIGNs
YXNzPSJjLWljbyI+4piFPC9zcGFuPuWbuuWumic7CiAgICAgICAgICAgIH0gZWxzZSB7CiAgICAgICAg
ICAgICAgICBwaW5CdG4uaW5uZXJIVE1MID0gb24KICAgICAgICAgICAgICAgICAgICA/ICc8c3BhbiBj
bGFzcz0iYy1pY28iPuKYhTwvc3Bhbj7lj5bmtojmlLbol48nCiAgICAgICAgICAgICAgICAgICAgOiAn
PHNwYW4gY2xhc3M9ImMtaWNvIj7imIU8L3NwYW4+5pS26JePJzsKICAgICAgICAgICAgfQogICAgICAg
IH0KICAgICAgICBjb25zdCBwYXN0ZUJ0biA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjLXBhc3Rl
Jyk7CiAgICAgICAgaWYgKHBhc3RlQnRuKSB7CiAgICAgICAgICAgIHBhc3RlQnRuLnN0eWxlLmRpc3Bs
YXkgPSAnJzsKICAgICAgICAgICAgcGFzdGVCdG4uaW5uZXJIVE1MID0gaXNSZWNlbnQKICAgICAgICAg
ICAgICAgID8gJzxzcGFuIGNsYXNzPSJjLWljbyI+8J+Tgjwvc3Bhbj7miZPlvIDmlofku7blpLknCiAg
ICAgICAgICAgICAgICA6ICc8c3BhbiBjbGFzcz0iYy1pY28iPvCfk4s8L3NwYW4+57KY6LS0JzsKICAg
ICAgICB9CiAgICAgICAgY29uc3QgdGl0bGVCdG4gPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYy10
aXRsZScpOwogICAgICAgIGlmICh0aXRsZUJ0bikgewogICAgICAgICAgICBjb25zdCBzaG93VGl0bGUg
PSAhaXNSZWNlbnQgJiYgKGlzUGlubmVkKGMpIHx8IGN1clRhYiA9PT0gJ3Bpbm5lZCcpOwogICAgICAg
ICAgICB0aXRsZUJ0bi5zdHlsZS5kaXNwbGF5ID0gc2hvd1RpdGxlID8gJycgOiAnbm9uZSc7CiAgICAg
ICAgICAgIGlmIChzaG93VGl0bGUpCiAgICAgICAgICAgICAgICB0aXRsZUJ0bi5pbm5lckhUTUwgPSAo
U3RyaW5nKGMuZmF2VGl0bGUgfHwgJycpLnRyaW0oKSA/ICc8c3BhbiBjbGFzcz0iYy1pY28iPuKcjjwv
c3Bhbj7nvJbovpHmoIfpopgnIDogJzxzcGFuIGNsYXNzPSJjLWljbyI+4pyOPC9zcGFuPuiuvue9ruag
h+mimCcpOwogICAgICAgIH0KICAgICAgICBjb25zdCBtZXJnZUJ0biA9IGRvY3VtZW50LmdldEVsZW1l
bnRCeUlkKCdjLW1lcmdlJyk7CiAgICAgICAgY29uc3QgdW5tZXJnZUJ0biA9IGRvY3VtZW50LmdldEVs
ZW1lbnRCeUlkKCdjLXVubWVyZ2UnKTsKICAgICAgICBjb25zdCBvblBpbm5lZCA9ICFpc1JlY2VudCAm
JiBjdXJUYWIgPT09ICdwaW5uZWQnOwogICAgICAgIGlmIChtZXJnZUJ0bikKICAgICAgICAgICAgbWVy
Z2VCdG4uc3R5bGUuZGlzcGxheSA9IChvblBpbm5lZCAmJiBtdWx0aUlkcy5sZW5ndGggPj0gMikgPyAn
JyA6ICdub25lJzsKICAgICAgICBpZiAodW5tZXJnZUJ0bikKICAgICAgICAgICAgdW5tZXJnZUJ0bi5z
dHlsZS5kaXNwbGF5ID0gKG9uUGlubmVkICYmIGZhdkdyb3VwT2YoYykpID8gJycgOiAnbm9uZSc7CiAg
ICAgICAgY29uc3QgdG9wQnRuID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2MtdG9wJyk7CiAgICAg
ICAgaWYgKHRvcEJ0bikgdG9wQnRuLnN0eWxlLmRpc3BsYXkgPSBpc1JlY2VudCA/ICdub25lJyA6ICcn
OwogICAgICAgIGNvbnN0IGNvcHlCdG4gPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYy1jb3B5Jyk7
CiAgICAgICAgaWYgKGNvcHlCdG4pIHsKICAgICAgICAgICAgY29weUJ0bi5zdHlsZS5kaXNwbGF5ID0g
Jyc7CiAgICAgICAgICAgIGNvcHlCdG4uaW5uZXJIVE1MID0gaXNSZWNlbnQKICAgICAgICAgICAgICAg
ID8gJzxzcGFuIGNsYXNzPSJjLWljbyI+8J+ThDwvc3Bhbj7lpI3liLbot6/lvoQnCiAgICAgICAgICAg
ICAgICA6ICc8c3BhbiBjbGFzcz0iYy1pY28iPvCfk4Q8L3NwYW4+5aSN5Yi2JzsKICAgICAgICB9CiAg
ICAgICAgY3R4RWwuY2xhc3NMaXN0LmFkZCgnb24nKTsKICAgICAgICBjdHhFbC5zdHlsZS5sZWZ0ID0g
eCArICdweCc7CiAgICAgICAgY3R4RWwuc3R5bGUudG9wICA9IHkgKyAncHgnOwogICAgICAgIHJlcXVl
c3RBbmltYXRpb25GcmFtZSgoKSA9PiB7CiAgICAgICAgICAgIGNvbnN0IHIgPSBjdHhFbC5nZXRCb3Vu
ZGluZ0NsaWVudFJlY3QoKTsKICAgICAgICAgICAgaWYgKHIucmlnaHQgID4gaW5uZXJXaWR0aCkgIGN0
eEVsLnN0eWxlLmxlZnQgPSAoeCAtIHIud2lkdGgpICArICdweCc7CiAgICAgICAgICAgIGlmIChyLmJv
dHRvbSA+IGlubmVySGVpZ2h0KSBjdHhFbC5zdHlsZS50b3AgID0gKHkgLSByLmhlaWdodCkgKyAncHgn
OwogICAgICAgIH0pOwogICAgfQogICAgZnVuY3Rpb24gaGlkZUN0eCgpIHsgY3R4RWwuY2xhc3NMaXN0
LnJlbW92ZSgnb24nKTsgY3R4Q2xpcCA9IG51bGw7IH0KICAgIHdpbmRvdy5fX2hpZGVDdHggPSBoaWRl
Q3R4OwoKICAgIGZ1bmN0aW9uIGRpc21pc3NDdHhVbmxlc3NJbnNpZGUoZSkgewogICAgICAgIGlmICgh
Y3R4RWwuY2xhc3NMaXN0LmNvbnRhaW5zKCdvbicpKSByZXR1cm47CiAgICAgICAgaWYgKGUudGFyZ2V0
LmNsb3Nlc3QoJyNjdHgnKSkgcmV0dXJuOwogICAgICAgIGhpZGVDdHgoKTsKICAgIH0KICAgIGRvY3Vt
ZW50LmFkZEV2ZW50TGlzdGVuZXIoJ21vdXNlZG93bicsIGRpc21pc3NDdHhVbmxlc3NJbnNpZGUsIHRy
dWUpOwogICAgZG9jdW1lbnQuYWRkRXZlbnRMaXN0ZW5lcignY2xpY2snLCBkaXNtaXNzQ3R4VW5sZXNz
SW5zaWRlLCB0cnVlKTsKICAgIGxpc3RFbC5hZGRFdmVudExpc3RlbmVyKCdzY3JvbGwnLCBoaWRlQ3R4
LCB7IHBhc3NpdmU6IHRydWUgfSk7CiAgICBkb2N1bWVudC5hZGRFdmVudExpc3RlbmVyKCdrZXlkb3du
JywgZSA9PiB7CiAgICAgICAgLy8gRXNjOiBhbHdheXMgY2xvc2UgcGFuZWwgKHNlYXJjaCBvciBub3Qp
OyBwaW4ga2VlcHMgcGFuZWwKICAgICAgICBpZiAoZS5rZXkgPT09ICdFc2NhcGUnKSB7CiAgICAgICAg
ICAgIGUucHJldmVudERlZmF1bHQoKTsKICAgICAgICAgICAgaGlkZUN0eCgpOwogICAgICAgICAgICBj
b25zdCB0ZCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd0aXRsZS1kbGcnKTsKICAgICAgICAgICAg
aWYgKHRkICYmIHRkLmNsYXNzTGlzdC5jb250YWlucygnb24nKSkgewogICAgICAgICAgICAgICAgdHJ5
IHsgY2xvc2VUaXRsZURsZygpOyB9IGNhdGNoIHsgdGQuY2xhc3NMaXN0LnJlbW92ZSgnb24nKTsgfQog
ICAgICAgICAgICAgICAgcmV0dXJuOwogICAgICAgICAgICB9CiAgICAgICAgICAgIGlmIChjbHJEbGcu
Y2xhc3NMaXN0LmNvbnRhaW5zKCdvbicpKSB7CiAgICAgICAgICAgICAgICBjbG9zZUNsZWFyRGxnKCk7
CiAgICAgICAgICAgICAgICByZXR1cm47CiAgICAgICAgICAgIH0KICAgICAgICAgICAgaWYgKCFwaW5u
ZWRVSSkgYWhrKCdoaWRlJyk7CiAgICAgICAgICAgIHJldHVybjsKICAgICAgICB9CiAgICAgICAgLy8g
V2hpbGUgdHlwaW5nIGluIHNlYXJjaDogQ3RybCtJL0sgYW5kIGFycm93cyBtb3ZlIGxpc3QsIGRvbid0
IGxlYXZlIHRoZSBib3gKICAgICAgICBpZiAoZG9jdW1lbnQuYWN0aXZlRWxlbWVudD8uaWQgPT09ICdz
ZWFyY2gnKSB7CiAgICAgICAgICAgIGlmICgoZS5jdHJsS2V5IHx8IGUubWV0YUtleSkgJiYgKGUua2V5
ID09PSAnaScgfHwgZS5rZXkgPT09ICdJJykpIHsKICAgICAgICAgICAgICAgIGUucHJldmVudERlZmF1
bHQoKTsgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICAgICAgICAgIHdpbmRvdy5fX25hdiAmJiB3
aW5kb3cuX19uYXYoJ3VwJyk7CiAgICAgICAgICAgICAgICByZXR1cm47CiAgICAgICAgICAgIH0KICAg
ICAgICAgICAgaWYgKChlLmN0cmxLZXkgfHwgZS5tZXRhS2V5KSAmJiAoZS5rZXkgPT09ICdrJyB8fCBl
LmtleSA9PT0gJ0snKSkgewogICAgICAgICAgICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOyBlLnN0b3BQ
cm9wYWdhdGlvbigpOwogICAgICAgICAgICAgICAgd2luZG93Ll9fbmF2ICYmIHdpbmRvdy5fX25hdign
ZG93bicpOwogICAgICAgICAgICAgICAgcmV0dXJuOwogICAgICAgICAgICB9CiAgICAgICAgICAgIGlm
IChlLmtleSA9PT0gJ0Fycm93RG93bicpIHsKICAgICAgICAgICAgICAgIGUucHJldmVudERlZmF1bHQo
KTsgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICAgICAgICAgIHdpbmRvdy5fX25hdiAmJiB3aW5k
b3cuX19uYXYoJ2Rvd24nKTsKICAgICAgICAgICAgICAgIHJldHVybjsKICAgICAgICAgICAgfQogICAg
ICAgICAgICBpZiAoZS5rZXkgPT09ICdBcnJvd1VwJykgewogICAgICAgICAgICAgICAgZS5wcmV2ZW50
RGVmYXVsdCgpOyBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgICAgICAgICAgICAgd2luZG93Ll9fbmF2
ICYmIHdpbmRvdy5fX25hdigndXAnKTsKICAgICAgICAgICAgICAgIHJldHVybjsKICAgICAgICAgICAg
fQogICAgICAgICAgICByZXR1cm47CiAgICAgICAgfQogICAgICAgIGNvbnN0IHZpcyA9ICh0eXBlb2Yg
bmF2TGlzdCA9PT0gJ2Z1bmN0aW9uJyA/IG5hdkxpc3QoKSA6IHZpc2libGVMaXN0KCkpOwogICAgICAg
IGlmICghdmlzLmxlbmd0aCkgcmV0dXJuOwogICAgICAgIGxldCBpZHggPSBzZWxlY3RlZEluZGV4KCk7
CiAgICAgICAgaWYgKGlkeCA8IDApIGlkeCA9IDA7CiAgICAgICAgaWYgICAgICAoZS5rZXkgPT09ICdB
cnJvd0Rvd24nKSB7IGUucHJldmVudERlZmF1bHQoKTsgZS5zdG9wUHJvcGFnYXRpb24oKTsgc2VsZWN0
QnlJbmRleChpZHggKyAxKTsgfQogICAgICAgIGVsc2UgaWYgKGUua2V5ID09PSAnQXJyb3dVcCcpICAg
eyBlLnByZXZlbnREZWZhdWx0KCk7IGUuc3RvcFByb3BhZ2F0aW9uKCk7IHNlbGVjdEJ5SW5kZXgoaWR4
IC0gMSk7IH0KICAgICAgICBlbHNlIGlmIChlLmtleSA9PT0gJ0VudGVyJykgewogICAgICAgICAgICBl
LnByZXZlbnREZWZhdWx0KCk7CiAgICAgICAgICAgIC8vIOWbuuWumuaXtuWbnui9puS4jeeymOi0tO+8
jOWPqueCueadoeebrueymOi0tAogICAgICAgICAgICBpZiAocGlubmVkVUkpIHJldHVybjsKICAgICAg
ICAgICAgaWYgKG11bHRpSWRzLmxlbmd0aCA+IDEpIHsKICAgICAgICAgICAgICAgIGNvbnN0IGlkcyA9
IG11bHRpSWRzLnNsaWNlKCk7CiAgICAgICAgICAgICAgICBjbGVhck11bHRpKCk7CiAgICAgICAgICAg
ICAgICBjb25zdCBmaXJzdCA9IGFsbENsaXBzLmZpbmQoeCA9PiAreC5pZCA9PT0gK2lkc1swXSk7CiAg
ICAgICAgICAgICAgICBpZiAoZmlyc3QgJiYgbm9ybVR5cGUoZmlyc3QudHlwZSkgPT09ICdyZWNlbnQn
KSB7CiAgICAgICAgICAgICAgICAgICAgYWN0aXZhdGVDbGlwSXRlbShmaXJzdCk7CiAgICAgICAgICAg
ICAgICAgICAgcmV0dXJuOwogICAgICAgICAgICAgICAgfQogICAgICAgICAgICAgICAgbWFya1Bhc3Rl
ZExvY2FsKGlkcyk7CiAgICAgICAgICAgICAgICBwYXN0ZU1hbnlXaXRoU2VwKGlkcyk7CiAgICAgICAg
ICAgICAgICByZXR1cm47CiAgICAgICAgICAgIH0KICAgICAgICAgICAgaWYgKG11bHRpSWRzLmxlbmd0
aCA9PT0gMSkgewogICAgICAgICAgICAgICAgY29uc3QgaWQgPSBtdWx0aUlkc1swXTsKICAgICAgICAg
ICAgICAgIGNsZWFyTXVsdGkoKTsKICAgICAgICAgICAgICAgIGNvbnN0IG9uZSA9IGFsbENsaXBzLmZp
bmQoeCA9PiAreC5pZCA9PT0gK2lkKSB8fCB7IGlkIH07CiAgICAgICAgICAgICAgICBhY3RpdmF0ZUNs
aXBJdGVtKG9uZSk7CiAgICAgICAgICAgICAgICByZXR1cm47CiAgICAgICAgICAgIH0KICAgICAgICAg
ICAgY29uc3QgYyA9IHZpc1tzZWxlY3RlZEluZGV4KCldOwogICAgICAgICAgICBpZiAoYykgYWN0aXZh
dGVDbGlwSXRlbShjKTsKICAgICAgICB9IGVsc2UgaWYgKC9eWzEtOV0kLy50ZXN0KGUua2V5KSkgewog
ICAgICAgICAgICBjb25zdCBjID0gdmlzWytlLmtleSAtIDFdOwogICAgICAgICAgICBpZiAoYykgYWN0
aXZhdGVDbGlwSXRlbShjKTsKICAgICAgICB9CiAgICB9KTsKCiAgICB3aW5kb3cuX19uYXYgPSBkaXIg
PT4gewogICAgICAgIGNvbnN0IHZpcyA9ICh0eXBlb2YgbmF2TGlzdCA9PT0gJ2Z1bmN0aW9uJyA/IG5h
dkxpc3QoKSA6IHZpc2libGVMaXN0KCkpOwogICAgICAgIGlmICghdmlzLmxlbmd0aCAmJiBkaXIgIT09
ICd0YWInICYmIGRpciAhPT0gJ3RhYlByZXYnKSByZXR1cm47CiAgICAgICAgbGV0IGlkeCA9IHNlbGVj
dGVkSW5kZXgoKTsKICAgICAgICBpZiAoaWR4IDwgMCkgaWR4ID0gMDsKICAgICAgICBpZiAoZGlyID09
PSAndXAnKSBzZWxlY3RCeUluZGV4KGlkeCAtIDEpOwogICAgICAgIGVsc2UgaWYgKGRpciA9PT0gJ2Rv
d24nKSBzZWxlY3RCeUluZGV4KGlkeCArIDEpOwogICAgICAgIGVsc2UgaWYgKGRpciA9PT0gJ2VudGVy
JykgewogICAgICAgICAgICBpZiAocGlubmVkVUkpIHJldHVybjsKICAgICAgICAgICAgX19wcmVwUGFz
dGUoKTsKICAgICAgICAgICAgaWYgKG11bHRpSWRzLmxlbmd0aCA+IDEpIHsKICAgICAgICAgICAgICAg
IGNvbnN0IGlkcyA9IG11bHRpSWRzLnNsaWNlKCk7CiAgICAgICAgICAgICAgICBjbGVhck11bHRpKCk7
CiAgICAgICAgICAgICAgICBjb25zdCBmaXJzdCA9IGFsbENsaXBzLmZpbmQoeCA9PiAreC5pZCA9PT0g
K2lkc1swXSk7CiAgICAgICAgICAgICAgICBpZiAoZmlyc3QgJiYgbm9ybVR5cGUoZmlyc3QudHlwZSkg
PT09ICdyZWNlbnQnKSB7CiAgICAgICAgICAgICAgICAgICAgYWN0aXZhdGVDbGlwSXRlbShmaXJzdCk7
CiAgICAgICAgICAgICAgICAgICAgcmV0dXJuOwogICAgICAgICAgICAgICAgfQogICAgICAgICAgICAg
ICAgbWFya1Bhc3RlZExvY2FsKGlkcyk7CiAgICAgICAgICAgICAgICBwYXN0ZU1hbnlXaXRoU2VwKGlk
cyk7CiAgICAgICAgICAgICAgICByZXR1cm47CiAgICAgICAgICAgIH0KICAgICAgICAgICAgaWYgKG11
bHRpSWRzLmxlbmd0aCA9PT0gMSkgewogICAgICAgICAgICAgICAgY29uc3QgaWQgPSBtdWx0aUlkc1sw
XTsKICAgICAgICAgICAgICAgIGNsZWFyTXVsdGkoKTsKICAgICAgICAgICAgICAgIGNvbnN0IG9uZSA9
IGFsbENsaXBzLmZpbmQoeCA9PiAreC5pZCA9PT0gK2lkKSB8fCB7IGlkIH07CiAgICAgICAgICAgICAg
ICBhY3RpdmF0ZUNsaXBJdGVtKG9uZSk7CiAgICAgICAgICAgICAgICByZXR1cm47CiAgICAgICAgICAg
IH0KICAgICAgICAgICAgY29uc3QgYyA9IHZpc1tzZWxlY3RlZEluZGV4KCldOwogICAgICAgICAgICBp
ZiAoYykgYWN0aXZhdGVDbGlwSXRlbShjKTsKICAgICAgICB9CiAgICB9OwoKICAgIC8vIEFISyBFbnRl
ciBob3RrZXkgbGFuZHMgaGVyZSAoV2ViVmlldyBtYXkgbm90IHJlY2VpdmUgdGhlIGtleSB3aGlsZSB1
bnBpbm5lZCkKICAgIHdpbmRvdy5fX2VkaXRUaXRsZSA9ICgpID0+IHsKICAgICAgICBsZXQgYyA9IG51
bGw7CiAgICAgICAgaWYgKHNlbGVjdGVkSWQpCiAgICAgICAgICAgIGMgPSBhbGxDbGlwcy5maW5kKHgg
PT4gK3guaWQgPT09ICtzZWxlY3RlZElkKSB8fCBudWxsOwogICAgICAgIGlmICghYyAmJiBjdHhDbGlw
KQogICAgICAgICAgICBjID0gY3R4Q2xpcDsKICAgICAgICBpZiAoIWMpIHsKICAgICAgICAgICAgY29u
c3QgdmlzID0gdmlzaWJsZUxpc3QoKTsKICAgICAgICAgICAgaWYgKHZpcy5sZW5ndGgpIGMgPSB2aXNb
MF07CiAgICAgICAgfQogICAgICAgIGlmICghYykgcmV0dXJuOwogICAgICAgIG9wZW5UaXRsZURsZyhj
KTsKICAgIH07CgogICAgd2luZG93Ll9fb25FbnRlciA9ICgpID0+IHsKICAgICAgICBjb25zdCB0ZCA9
IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd0aXRsZS1kbGcnKTsKICAgICAgICBpZiAodGQgJiYgdGQu
Y2xhc3NMaXN0LmNvbnRhaW5zKCdvbicpKSB7CiAgICAgICAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRC
eUlkKCd0aXRsZS1vaycpPy5jbGljaygpOwogICAgICAgICAgICByZXR1cm47CiAgICAgICAgfQogICAg
ICAgIGlmIChkb2N1bWVudC5hY3RpdmVFbGVtZW50Py5pZCA9PT0gJ3RpdGxlLWlucHV0JykgewogICAg
ICAgICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgndGl0bGUtb2snKT8uY2xpY2soKTsKICAgICAg
ICAgICAgcmV0dXJuOwogICAgICAgIH0KICAgICAgICAvLyBDdXN0b20gc2VwYXJhdG9yIGJveDogQUhL
IHN0ZWFscyBFbnRlciB3aGlsZSB1bnBpbm5lZCDigJQgYXBwbHkgaGVyZQogICAgICAgIGNvbnN0IHNl
cE1lbnUgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgncGFzdGUtc2VwLW1lbnUnKTsKICAgICAgICBj
b25zdCBzZXBJbnAgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgncGFzdGUtc2VwLWN1c3RvbScpOwog
ICAgICAgIGlmIChzZXBNZW51ICYmIHNlcE1lbnUuY2xhc3NMaXN0LmNvbnRhaW5zKCdvbicpICYmIHNl
cElucCkgewogICAgICAgICAgICBpZiAoU3RyaW5nKHNlcElucC52YWx1ZSB8fCAnJykgIT09ICcnKSBh
cHBseVNlcGFyYXRvcihzZXBJbnAudmFsdWUpOwogICAgICAgICAgICBlbHNlIGNsb3NlU2VwTWVudSgp
OwogICAgICAgICAgICByZXR1cm47CiAgICAgICAgfQogICAgICAgIC8vIOWbuuWumuaXtuWbnui9puS4
jeeymOi0tAogICAgICAgIGlmIChwaW5uZWRVSSkgcmV0dXJuOwogICAgICAgIC8vIFR5cGluZyBpbiBz
ZWFyY2g6IEVudGVyIHNob3VsZCBwYXN0ZSBzZWxlY3RlZCBpdGVtCiAgICAgICAgaWYgKGRvY3VtZW50
LmFjdGl2ZUVsZW1lbnQ/LmlkID09PSAnc2VhcmNoJykgewogICAgICAgICAgICB3aW5kb3cuX19uYXYg
JiYgd2luZG93Ll9fbmF2KCdlbnRlcicpOwogICAgICAgICAgICByZXR1cm47CiAgICAgICAgfQogICAg
ICAgIHdpbmRvdy5fX25hdiAmJiB3aW5kb3cuX19uYXYoJ2VudGVyJyk7CiAgICB9OwoKICAgIHdpbmRv
dy5fX2N5Y2xlVGFiID0gZGlyID0+IHsKICAgICAgICBjb25zdCBpID0gTWF0aC5tYXgoMCwgVEFCX09S
REVSLmluZGV4T2YoY3VyVGFiKSk7CiAgICAgICAgY29uc3QgbmV4dCA9IFRBQl9PUkRFUlsoaSArIChk
aXIgfCAwKSArIFRBQl9PUkRFUi5sZW5ndGggKiAxMCkgJSBUQUJfT1JERVIubGVuZ3RoXTsKICAgICAg
ICBzZXRUYWIobmV4dCk7CiAgICB9OwogICAgd2luZG93Ll9fb25QYW5lbFNob3cgPSAoa2VlcFNlYXJj
aCkgPT4gewogICAgICAgIC8vIERvIE5PVCBmb2N1cyBXZWJWaWV3IOKAlCBrZWVwIGVkaXRvciBjYXJl
dC9mb2N1cyAoQUhLIGhhbmRsZXMga2V5cyB2aWEgI0hvdElmKQogICAgICAgIC8vIFdpbitWOiBjb2xs
YXBzZSBzZWFyY2guID8/IHNlYXJjaDoga2VlcC9vcGVuIHNlYXJjaCBib3guCiAgICAgICAga2VlcFNl
YXJjaCA9ICEha2VlcFNlYXJjaDsKICAgICAgICB0cnkgeyBoaWRlQ3R4KCk7IH0gY2F0Y2gge30KICAg
ICAgICB0cnkgeyBjbG9zZVRpdGxlRGxnKCk7IH0gY2F0Y2gge30KICAgICAgICB0cnkgeyByZXNldFBh
c3RlU2VwRGVmYXVsdCgpOyB9IGNhdGNoIHt9CiAgICAgICAgdHJ5IHsKICAgICAgICAgICAgY29uc3Qg
d3JhcCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzZWFyY2gtd3JhcCcpOwogICAgICAgICAgICBj
b25zdCBzcmNoID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NlYXJjaCcpOwogICAgICAgICAgICBj
b25zdCBzY2xyID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NlYXJjaC1jbHInKTsKICAgICAgICAg
ICAgaWYgKCFrZWVwU2VhcmNoKSB7CiAgICAgICAgICAgICAgICBpZiAod3JhcCkgd3JhcC5jbGFzc0xp
c3QucmVtb3ZlKCdvcGVuJyk7CiAgICAgICAgICAgICAgICBpZiAoc3JjaCkgewogICAgICAgICAgICAg
ICAgICAgIHNyY2gudmFsdWUgPSAnJzsKICAgICAgICAgICAgICAgICAgICBzcmNoLmNsYXNzTGlzdC5y
ZW1vdmUoJ2hhcy12YWwnKTsKICAgICAgICAgICAgICAgICAgICB0cnkgeyBzcmNoLmJsdXIoKTsgfSBj
YXRjaCB7fQogICAgICAgICAgICAgICAgfQogICAgICAgICAgICAgICAgaWYgKHNjbHIpIHNjbHIuc3R5
bGUuZGlzcGxheSA9ICdub25lJzsKICAgICAgICAgICAgICAgIHF1ZXJ5ID0gJyc7CiAgICAgICAgICAg
ICAgICB3aW5kb3cuX19ob3N0RmlsdGVyZWQgPSBmYWxzZTsKICAgICAgICAgICAgICAgIHdpbmRvdy5f
X2hvc3RGaWx0ZXJRID0gJyc7CiAgICAgICAgICAgICAgICAvLyBXaW4rVu+8mueri+WIu+eUqOacqui/
h+a7pOe8k+WtmOmTuuWIl+ihqO+8jOmBv+WFjeWFiOmXqui/h+a7pOe7k+aenC/nqbrlo7Plho3nrYkg
U2V0VmlldwogICAgICAgICAgICAgICAgdHJ5IHsKICAgICAgICAgICAgICAgICAgICBjb25zdCBoaXQg
PSB2aWV3TWVtLmdldCh2aWV3TWVtS2V5KCdhbGwnLCAnJywgZmFsc2UpKTsKICAgICAgICAgICAgICAg
ICAgICBpZiAoaGl0ICYmIEFycmF5LmlzQXJyYXkoaGl0Lml0ZW1zKSAmJiBoaXQuaXRlbXMubGVuZ3Ro
KSB7CiAgICAgICAgICAgICAgICAgICAgICAgIGFsbENsaXBzID0gaGl0Lml0ZW1zLnNsaWNlKCk7CiAg
ICAgICAgICAgICAgICAgICAgICAgIGRpc2tUb3RhbCA9IE51bWJlcihoaXQudG90YWwpIHx8IGhpdC5p
dGVtcy5sZW5ndGg7CiAgICAgICAgICAgICAgICAgICAgICAgIHdpbmRvdy5fX2RhdGFSZWFkeSA9IHRy
dWU7CiAgICAgICAgICAgICAgICAgICAgICAgIGhvc3RQdXNoZWRPbmNlID0gdHJ1ZTsKICAgICAgICAg
ICAgICAgICAgICAgICAgc2F3Tm9uRW1wdHkgPSB0cnVlOwogICAgICAgICAgICAgICAgICAgICAgICBj
bGVhcldhaXRpbmdEYXRhKCk7CiAgICAgICAgICAgICAgICAgICAgfSBlbHNlIHsKICAgICAgICAgICAg
ICAgICAgICAgICAgc2NoZWR1bGVEZWxheWVkU2tlbCgpOwogICAgICAgICAgICAgICAgICAgIH0KICAg
ICAgICAgICAgICAgIH0gY2F0Y2ggewogICAgICAgICAgICAgICAgICAgIHNjaGVkdWxlRGVsYXllZFNr
ZWwoKTsKICAgICAgICAgICAgICAgIH0KICAgICAgICAgICAgfSBlbHNlIGlmICh3cmFwKSB7CiAgICAg
ICAgICAgICAgICB3cmFwLmNsYXNzTGlzdC5hZGQoJ29wZW4nKTsKICAgICAgICAgICAgICAgIGlmIChz
cmNoICYmIHNyY2gudmFsdWUpCiAgICAgICAgICAgICAgICAgICAgcXVlcnkgPSBzcmNoLnZhbHVlOwog
ICAgICAgICAgICAgICAgLy8gPz8g5pCc57Si77ya5Zyo5Li75py66L+H5ruk57uT5p6c5Yiw6L6+5YmN
77yM5YWI5oyJ5YWz6ZSu5a2X5pys5Zyw5ruk77yM56aB5q2i6Zeq5Ye644CM5YWo6YOo44CNCiAgICAg
ICAgICAgICAgICBpZiAoU3RyaW5nKHF1ZXJ5IHx8ICcnKS50cmltKCkpIHsKICAgICAgICAgICAgICAg
ICAgICB3aW5kb3cuX19ob3N0RmlsdGVyZWQgPSBmYWxzZTsKICAgICAgICAgICAgICAgICAgICB3aW5k
b3cuX19ob3N0RmlsdGVyUSA9ICcnOwogICAgICAgICAgICAgICAgfQogICAgICAgICAgICB9CiAgICAg
ICAgICAgIHRvZGF5T25seSA9IGZhbHNlOwogICAgICAgICAgICB0cnkgewogICAgICAgICAgICAgICAg
Y29uc3QgYnRuVG9kYXkgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYnRuLXRvZGF5Jyk7CiAgICAg
ICAgICAgICAgICBpZiAoYnRuVG9kYXkpIGJ0blRvZGF5LmNsYXNzTGlzdC5yZW1vdmUoJ29uJyk7CiAg
ICAgICAgICAgIH0gY2F0Y2gge30KICAgICAgICAgICAgY3VyVGFiID0gJ2FsbCc7CiAgICAgICAgICAg
IGxvYWRpbmdNb3JlID0gZmFsc2U7CiAgICAgICAgICAgIG1hcmtUYWIoJ2FsbCcpOwogICAgICAgICAg
ICAvLyDkuI3opoEgYWhrKCdibHVyUGFuZWwnKe+8muS8mui3nyBTaG93UGFuZWwg5oqi54Sm54K577yM
V2luK1YvPz8g6YO95a655piT6Zeq44CB5Lmx6LezCiAgICAgICAgICAgIHJlbmRlcigpOwogICAgICAg
ICAgICAvLyDlkIzmraXlvZPliY0gdGFiL3F1ZXJ5IOWIsCBBSEvvvIg/PyDmm77lj6rnlKggdmlld1Rh
YiDmkJzplJnpobXvvIkKICAgICAgICAgICAgcmVxdWVzdFZpZXcoKTsKICAgICAgICB9IGNhdGNoIHt9
CiAgICAgICAgc2VsZWN0Rmlyc3RPblNob3cgPSB0cnVlOwogICAgICAgIGxvY2F0ZUFjdGl2ZSA9IGZh
bHNlOwogICAgICAgIHVwZGF0ZUxvY2F0ZUJ0bigpOwogICAgICAgIGNsZWFyTXVsdGkoKTsKICAgICAg
ICBjb25zdCB2aXMgPSB2aXNpYmxlTGlzdCgpOwogICAgICAgIGlmICh2aXMubGVuZ3RoKSB7CiAgICAg
ICAgICAgIHNlbGVjdGVkSWQgPSB2aXNbMF0uaWQ7CiAgICAgICAgICAgIHJhbmdlQW5jaG9ySWQgPSBz
ZWxlY3RlZElkOwogICAgICAgICAgICByYW5nZUFuY2hvckNsaWNrZWQgPSBmYWxzZTsKICAgICAgICAg
ICAgbGlzdEVsLnNjcm9sbFRvcCA9IDA7CiAgICAgICAgfQogICAgICAgIHN5bmNJdGVtSGlnaGxpZ2h0
KCk7CiAgICB9OwoKICAgIGZ1bmN0aW9uIGN0eEJpbmQoaWQsIGZuKSB7CiAgICAgICAgZG9jdW1lbnQu
Z2V0RWxlbWVudEJ5SWQoaWQpLmFkZEV2ZW50TGlzdGVuZXIoJ2NsaWNrJywgZSA9PiB7CiAgICAgICAg
ICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAgICAgICAgIGlmIChjdHhDbGlwKSBmbihjdHhDbGlw
KTsKICAgICAgICAgICAgaGlkZUN0eCgpOwogICAgICAgIH0pOwogICAgfQogICAgY3R4QmluZCgnYy1j
b3B5JywgIGMgPT4gewogICAgICAgIGlmIChub3JtVHlwZShjLnR5cGUpID09PSAncmVjZW50JykKICAg
ICAgICAgICAgYWhrKCdjb3B5UGF0aCcsIFN0cmluZyhjLmRhdGEgfHwgYy5wcmV2aWV3IHx8ICcnKSk7
CiAgICAgICAgZWxzZQogICAgICAgICAgICBhaGsoJ2NvcHlCeUlkJywgU3RyaW5nKGMuaWQpKTsKICAg
IH0pOwogICAgY3R4QmluZCgnYy1wYXN0ZScsIGMgPT4gewogICAgICAgIGFjdGl2YXRlQ2xpcEl0ZW0o
Yyk7CiAgICB9KTsKICAgIGN0eEJpbmQoJ2MtcGluJywgICBjID0+IHsKICAgICAgICBpZiAobm9ybVR5
cGUoYy50eXBlKSA9PT0gJ3JlY2VudCcpIHsKICAgICAgICAgICAgdHJ5IHsKICAgICAgICAgICAgICAg
IGNvbnN0IG5leHQgPSAhaXNQaW5uZWQoYyk7CiAgICAgICAgICAgICAgICBjb25zdCBoaXQgPSBhbGxD
bGlwcy5maW5kKHggPT4gK3guaWQgPT09ICtjLmlkKTsKICAgICAgICAgICAgICAgIGlmIChoaXQpIGhp
dC5waW5uZWQgPSBuZXh0OwogICAgICAgICAgICAgICAgYy5waW5uZWQgPSBuZXh0OwogICAgICAgICAg
ICAgICAgcmVuZGVyKCk7CiAgICAgICAgICAgIH0gY2F0Y2gge30KICAgICAgICB9CiAgICAgICAgYWhr
KCdwaW4nLCBTdHJpbmcoYy5pZCkpOwogICAgfSk7CiAgICBjdHhCaW5kKCdjLXRvcCcsICAgYyA9PiBh
aGsoJ21vdmVUb1RvcCcsICAgICBTdHJpbmcoYy5pZCkpKTsKICAgIGN0eEJpbmQoJ2MtY2xlYXItcGFz
dGVkJywgYyA9PiB7CiAgICAgICAgdHJ5IHsgY2xlYXJQYXN0ZWRMb2NhbChjLmlkKTsgfSBjYXRjaCB7
fQogICAgICAgIGFoaygnY2xlYXJQYXN0ZWQnLCBTdHJpbmcoYy5pZCkpOwogICAgfSk7CiAgICBjdHhC
aW5kKCdjLWRlbCcsICAgYyA9PiB7CiAgICAgICAgLy8g5pys5Zyw5YWI5Yig77yM55WM6Z2i5LiN5Y2h
77ybQUhLIOWQjuWPsOiQveebmAogICAgICAgIHRyeSB7CiAgICAgICAgICAgIGNvbnN0IGlkID0gK2Mu
aWQ7CiAgICAgICAgICAgIGFsbENsaXBzID0gYWxsQ2xpcHMuZmlsdGVyKHggPT4gK3guaWQgIT09IGlk
KTsKICAgICAgICAgICAgZGlza1RvdGFsID0gTWF0aC5tYXgoMCwgKE51bWJlcihkaXNrVG90YWwpIHx8
IDApIC0gMSk7CiAgICAgICAgICAgIGlmICgrc2VsZWN0ZWRJZCA9PT0gaWQpIHNlbGVjdGVkSWQgPSBh
bGxDbGlwcy5sZW5ndGggPyBhbGxDbGlwc1swXS5pZCA6IDA7CiAgICAgICAgICAgIHJlbmRlcigpOwog
ICAgICAgIH0gY2F0Y2gge30KICAgICAgICBhaGsoJ2RlbGV0ZScsIFN0cmluZyhjLmlkKSk7CiAgICB9
KTsKICAgIGN0eEJpbmQoJ2MtdGl0bGUnLCBjID0+IG9wZW5UaXRsZURsZyhjKSk7CiAgICBjdHhCaW5k
KCdjLW1lcmdlJywgYyA9PiB7CiAgICAgICAgY29uc3QgaWRzID0gKG11bHRpSWRzLmxlbmd0aCA+PSAy
KSA/IG11bHRpSWRzLnNsaWNlKCkgOiBbXTsKICAgICAgICBpZiAoaWRzLmxlbmd0aCA8IDIpIHJldHVy
bjsKICAgICAgICBpZiAoIWlkcy5pbmNsdWRlcygrYy5pZCkpIGlkcy5wdXNoKCtjLmlkKTsKICAgICAg
ICBhaGsoJ21lcmdlRmF2JywgaWRzLmpvaW4oJywnKSk7CiAgICAgICAgY2xlYXJNdWx0aSgpOwogICAg
fSk7CiAgICBjdHhCaW5kKCdjLXVubWVyZ2UnLCBjID0+IHsKICAgICAgICBhaGsoJ3VubWVyZ2VGYXYn
LCBTdHJpbmcoYy5pZCkpOwogICAgICAgIGNsZWFyTXVsdGkoKTsKICAgIH0pOwoKICAgIGNvbnN0IHRp
dGxlRGxnID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3RpdGxlLWRsZycpOwogICAgY29uc3QgdGl0
bGVJbnB1dCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd0aXRsZS1pbnB1dCcpOwogICAgbGV0IHRp
dGxlRGxnQ2xpcCA9IG51bGw7CiAgICBmdW5jdGlvbiBjbG9zZVRpdGxlRGxnKCkgewogICAgICAgIGlm
ICh0aXRsZURsZykgdGl0bGVEbGcuY2xhc3NMaXN0LnJlbW92ZSgnb24nKTsKICAgICAgICB0aXRsZURs
Z0NsaXAgPSBudWxsOwogICAgfQogICAgZnVuY3Rpb24gb3BlblRpdGxlRGxnKGMpIHsKICAgICAgICBo
aWRlQ3R4KCk7CiAgICAgICAgdGl0bGVEbGdDbGlwID0gYzsKICAgICAgICBpZiAodGl0bGVJbnB1dCkg
dGl0bGVJbnB1dC52YWx1ZSA9IFN0cmluZyhjLmZhdlRpdGxlIHx8ICcnKS50cmltKCk7CiAgICAgICAg
aWYgKHRpdGxlRGxnKSB0aXRsZURsZy5jbGFzc0xpc3QuYWRkKCdvbicpOwogICAgICAgIGFoaygnZm9j
dXNQYW5lbCcpOwogICAgICAgIHJlcXVlc3RBbmltYXRpb25GcmFtZSgoKSA9PiB7CiAgICAgICAgICAg
IHRyeSB7IHRpdGxlSW5wdXQuZm9jdXMoKTsgdGl0bGVJbnB1dC5zZWxlY3QoKTsgfSBjYXRjaCB7fQog
ICAgICAgIH0pOwogICAgfQogICAgaWYgKHRpdGxlRGxnKSB7CiAgICAgICAgdGl0bGVEbGcuYWRkRXZl
bnRMaXN0ZW5lcignY2xpY2snLCBlID0+IHsKICAgICAgICAgICAgaWYgKGUudGFyZ2V0ID09PSB0aXRs
ZURsZykgY2xvc2VUaXRsZURsZygpOwogICAgICAgIH0pOwogICAgfQogICAgZG9jdW1lbnQuZ2V0RWxl
bWVudEJ5SWQoJ3RpdGxlLWNhbmNlbCcpPy5hZGRFdmVudExpc3RlbmVyKCdjbGljaycsIGUgPT4gewog
ICAgICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAgICAgY2xvc2VUaXRsZURsZygpOwogICAgICAg
IGFoaygnYmx1clBhbmVsJyk7CiAgICB9KTsKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd0aXRs
ZS1vaycpPy5hZGRFdmVudExpc3RlbmVyKCdjbGljaycsIGUgPT4gewogICAgICAgIGUuc3RvcFByb3Bh
Z2F0aW9uKCk7CiAgICAgICAgaWYgKCF0aXRsZURsZ0NsaXApIHJldHVybjsKICAgICAgICBjb25zdCB0
ID0gU3RyaW5nKHRpdGxlSW5wdXQ/LnZhbHVlIHx8ICcnKS50cmltKCkuc2xpY2UoMCwgODApOwogICAg
ICAgIGNvbnN0IGlkID0gU3RyaW5nKHRpdGxlRGxnQ2xpcC5pZCk7CiAgICAgICAgLy8gT3B0aW1pc3Rp
YyBsb2NhbCB1cGRhdGUKICAgICAgICBjb25zdCBoaXQgPSBhbGxDbGlwcy5maW5kKHggPT4gK3guaWQg
PT09ICtpZCk7CiAgICAgICAgaWYgKGhpdCkgaGl0LmZhdlRpdGxlID0gdDsKICAgICAgICB0aXRsZURs
Z0NsaXAuZmF2VGl0bGUgPSB0OwogICAgICAgIGNsb3NlVGl0bGVEbGcoKTsKICAgICAgICBhaGsoJ3Nl
dEZhdlRpdGxlJywgaWQsIHQpOwogICAgICAgIGFoaygnYmx1clBhbmVsJyk7CiAgICAgICAgcmVuZGVy
KCk7CiAgICB9KTsKICAgIHRpdGxlSW5wdXQ/LmFkZEV2ZW50TGlzdGVuZXIoJ2tleWRvd24nLCBlID0+
IHsKICAgICAgICBpZiAoZS5rZXkgPT09ICdFbnRlcicpIHsKICAgICAgICAgICAgZS5wcmV2ZW50RGVm
YXVsdCgpOwogICAgICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgICAgICAgICBlLnN0b3BJ
bW1lZGlhdGVQcm9wYWdhdGlvbigpOwogICAgICAgICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgn
dGl0bGUtb2snKT8uY2xpY2soKTsKICAgICAgICAgICAgcmV0dXJuOwogICAgICAgIH0KICAgICAgICBp
ZiAoZS5rZXkgPT09ICdFc2NhcGUnKSB7CiAgICAgICAgICAgIGUucHJldmVudERlZmF1bHQoKTsKICAg
ICAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICAgICAgY2xvc2VUaXRsZURsZygpOwog
ICAgICAgICAgICBhaGsoJ2JsdXJQYW5lbCcpOwogICAgICAgICAgICByZXR1cm47CiAgICAgICAgfQog
ICAgICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICB9LCB0cnVlKTsKCiAgICBkb2N1bWVudC5nZXRF
bGVtZW50QnlJZCgndGFicycpLmFkZEV2ZW50TGlzdGVuZXIoJ2NsaWNrJywgZSA9PiB7CiAgICAgICAg
Y29uc3QgdGFiID0gZS50YXJnZXQuY2xvc2VzdCgnLnRhYicpOwogICAgICAgIGlmICghdGFiIHx8IGUu
dGFyZ2V0LmNsb3Nlc3QoJyN0YWItYWN0aW9ucycpKSByZXR1cm47CiAgICAgICAgc2V0VGFiKHRhYi5k
YXRhc2V0LnRhYik7CiAgICB9KTsKCiAgICBjb25zdCBzcmNoV3JhcCA9IGRvY3VtZW50LmdldEVsZW1l
bnRCeUlkKCdzZWFyY2gtd3JhcCcpOwogICAgY29uc3QgYnRuU2VhcmNoID0gZG9jdW1lbnQuZ2V0RWxl
bWVudEJ5SWQoJ2J0bi1zZWFyY2gnKTsKICAgIGNvbnN0IGJ0bkxvY2F0ZSA9IGRvY3VtZW50LmdldEVs
ZW1lbnRCeUlkKCdidG4tbG9jYXRlJyk7CiAgICBjb25zdCBidG5Ub2RheSA9IGRvY3VtZW50LmdldEVs
ZW1lbnRCeUlkKCdidG4tdG9kYXknKTsKICAgIGNvbnN0IHNyY2ggPSBkb2N1bWVudC5nZXRFbGVtZW50
QnlJZCgnc2VhcmNoJyk7CiAgICBjb25zdCBzY2xyID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3Nl
YXJjaC1jbHInKTsKICAgIGxldCBkZWI7CgogICAgdXBkYXRlTG9jYXRlQnRuKCk7CiAgICBpZiAoYnRu
TG9jYXRlKSB7CiAgICAgICAgYnRuTG9jYXRlLmFkZEV2ZW50TGlzdGVuZXIoJ2NsaWNrJywgZSA9PiB7
CiAgICAgICAgICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAgICAgICAgIGp1bXBUb0xhc3RQYXN0
ZSgpOwogICAgICAgIH0pOwogICAgfQoKICAgIGJ0blRvZGF5LmFkZEV2ZW50TGlzdGVuZXIoJ21vdXNl
ZG93bicsIGUgPT4gewogICAgICAgIGUucHJldmVudERlZmF1bHQoKTsKICAgICAgICBlLnN0b3BQcm9w
YWdhdGlvbigpOwogICAgfSk7CiAgICBidG5Ub2RheS5hZGRFdmVudExpc3RlbmVyKCdjbGljaycsIGUg
PT4gewogICAgICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAgICAgZS5wcmV2ZW50RGVmYXVsdCgp
OwogICAgICAgIHRvZGF5T25seSA9ICF0b2RheU9ubHk7CiAgICAgICAgYnRuVG9kYXkuY2xhc3NMaXN0
LnRvZ2dsZSgnb24nLCB0b2RheU9ubHkpOwogICAgICAgIGxpc3RFbC5zY3JvbGxUb3AgPSAwOwogICAg
ICAgIHJlcXVlc3RWaWV3KCk7CiAgICAgICAgdHJ5IHsgc3JjaC5mb2N1cygpOyB9IGNhdGNoIHt9CiAg
ICB9KTsKCiAgICBmdW5jdGlvbiBvcGVuU2VhcmNoKCkgewogICAgICAgIGlmIChzcmNoV3JhcC5jbGFz
c0xpc3QuY29udGFpbnMoJ29wZW4nKSkgewogICAgICAgICAgICBhaGsoJ2ZvY3VzUGFuZWwnKTsKICAg
ICAgICAgICAgdHJ5IHsgc3JjaC5mb2N1cygpOyB9IGNhdGNoIHt9CiAgICAgICAgICAgIHJldHVybjsK
ICAgICAgICB9CiAgICAgICAgc3JjaFdyYXAuY2xhc3NMaXN0LmFkZCgnb3BlbicpOwogICAgICAgIC8v
IERlZmF1bHQ6IOaJgOaciemhteaJk+W8gOaQnOe0ouaXtum7mOiupOaQnOWFqOmDqAogICAgICAgIGNv
bnN0IHdhbnRUb2RheSA9IGZhbHNlOwogICAgICAgIGlmICh0b2RheU9ubHkgIT09IHdhbnRUb2RheSkg
ewogICAgICAgICAgICB0b2RheU9ubHkgPSB3YW50VG9kYXk7CiAgICAgICAgICAgIGJ0blRvZGF5LmNs
YXNzTGlzdC50b2dnbGUoJ29uJywgdG9kYXlPbmx5KTsKICAgICAgICAgICAgbGlzdEVsLnNjcm9sbFRv
cCA9IDA7CiAgICAgICAgICAgIHJlcXVlc3RWaWV3KCk7CiAgICAgICAgfSBlbHNlIHsKICAgICAgICAg
ICAgYnRuVG9kYXkuY2xhc3NMaXN0LnRvZ2dsZSgnb24nLCB0b2RheU9ubHkpOwogICAgICAgIH0KICAg
ICAgICBhaGsoJ2ZvY3VzUGFuZWwnKTsKICAgICAgICByZXF1ZXN0QW5pbWF0aW9uRnJhbWUoKCkgPT4g
ewogICAgICAgICAgICB0cnkgeyBzcmNoLmZvY3VzKCk7IH0gY2F0Y2gge30KICAgICAgICB9KTsKICAg
IH0KICAgIGZ1bmN0aW9uIGNsb3NlU2VhcmNoVWkoKSB7CiAgICAgICAgc3JjaFdyYXAuY2xhc3NMaXN0
LnJlbW92ZSgnb3BlbicpOwogICAgICAgIGlmICghc3JjaC52YWx1ZSkgewogICAgICAgICAgICBzcmNo
LmNsYXNzTGlzdC5yZW1vdmUoJ2hhcy12YWwnKTsKICAgICAgICAgICAgc2Nsci5zdHlsZS5kaXNwbGF5
ID0gJ25vbmUnOwogICAgICAgICAgICAvLyBMZWF2aW5nIHNlYXJjaCB3aXRoIGVtcHR5IHF1ZXJ5IOKG
kiBkcm9wIHRvZGF5IGZpbHRlcgogICAgICAgICAgICBpZiAodG9kYXlPbmx5KSB7CiAgICAgICAgICAg
ICAgICB0b2RheU9ubHkgPSBmYWxzZTsKICAgICAgICAgICAgICAgIGJ0blRvZGF5LmNsYXNzTGlzdC5y
ZW1vdmUoJ29uJyk7CiAgICAgICAgICAgICAgICByZXF1ZXN0VmlldygpOwogICAgICAgICAgICB9CiAg
ICAgICAgfQogICAgfQogICAgd2luZG93Ll9fb3BlblNlYXJjaCA9IG9wZW5TZWFyY2g7CiAgICB3aW5k
b3cuX19wcmVwVHlwZVNlYXJjaCA9ICgpID0+IHsKICAgICAgICB0cnkgewogICAgICAgICAgICBjb25z
dCB3cmFwID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NlYXJjaC13cmFwJyk7CiAgICAgICAgICAg
IGNvbnN0IHMgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc2VhcmNoJyk7CiAgICAgICAgICAgIGlm
ICh3cmFwICYmICF3cmFwLmNsYXNzTGlzdC5jb250YWlucygnb3BlbicpKSB7CiAgICAgICAgICAgICAg
ICB3cmFwLmNsYXNzTGlzdC5hZGQoJ29wZW4nKTsKICAgICAgICAgICAgICAgIHRyeSB7CiAgICAgICAg
ICAgICAgICAgICAgY29uc3Qgd2FudFRvZGF5ID0gZmFsc2U7CiAgICAgICAgICAgICAgICAgICAgaWYg
KHR5cGVvZiB0b2RheU9ubHkgIT09ICd1bmRlZmluZWQnICYmIHRvZGF5T25seSAhPT0gd2FudFRvZGF5
KSB7CiAgICAgICAgICAgICAgICAgICAgICAgIHRvZGF5T25seSA9IHdhbnRUb2RheTsKICAgICAgICAg
ICAgICAgICAgICAgICAgaWYgKHR5cGVvZiBidG5Ub2RheSAhPT0gJ3VuZGVmaW5lZCcgJiYgYnRuVG9k
YXkpIGJ0blRvZGF5LmNsYXNzTGlzdC50b2dnbGUoJ29uJywgdG9kYXlPbmx5KTsKICAgICAgICAgICAg
ICAgICAgICAgICAgaWYgKHR5cGVvZiBsaXN0RWwgIT09ICd1bmRlZmluZWQnICYmIGxpc3RFbCkgbGlz
dEVsLnNjcm9sbFRvcCA9IDA7CiAgICAgICAgICAgICAgICAgICAgICAgIGlmICh0eXBlb2YgcmVxdWVz
dFZpZXcgPT09ICdmdW5jdGlvbicpIHNldFRpbWVvdXQocmVxdWVzdFZpZXcsIDApOwogICAgICAgICAg
ICAgICAgICAgIH0gZWxzZSBpZiAodHlwZW9mIGJ0blRvZGF5ICE9PSAndW5kZWZpbmVkJyAmJiBidG5U
b2RheSkgewogICAgICAgICAgICAgICAgICAgICAgICBidG5Ub2RheS5jbGFzc0xpc3QudG9nZ2xlKCdv
bicsICEhdG9kYXlPbmx5KTsKICAgICAgICAgICAgICAgICAgICB9CiAgICAgICAgICAgICAgICB9IGNh
dGNoIHt9CiAgICAgICAgICAgIH0KICAgICAgICAgICAgLy8gPz8g6ZWc5YOP5pCc57Si77ya5LiN6KaB
IGZvY3Vz77yM6YG/5YWN5oqi6LWw5Y6f57yW6L6R5qGG5YWJ5qCHCiAgICAgICAgfSBjYXRjaCB7fQog
ICAgfTsKICAgIHdpbmRvdy5fX3R5cGVTZWFyY2ggPSAoY2gpID0+IHsKICAgICAgICB0cnkgewogICAg
ICAgICAgICB3aW5kb3cuX19wcmVwVHlwZVNlYXJjaCAmJiB3aW5kb3cuX19wcmVwVHlwZVNlYXJjaCgp
OwogICAgICAgICAgICBjb25zdCBzID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NlYXJjaCcpOwog
ICAgICAgICAgICBpZiAoIXMpIHJldHVybjsKICAgICAgICAgICAgcy52YWx1ZSA9IFN0cmluZyhzLnZh
bHVlIHx8ICcnKSArIFN0cmluZyhjaCA9PSBudWxsID8gJycgOiBjaCk7CiAgICAgICAgICAgIHMuY2xh
c3NMaXN0LnRvZ2dsZSgnaGFzLXZhbCcsICEhcy52YWx1ZSk7CiAgICAgICAgICAgIHMuZGlzcGF0Y2hF
dmVudChuZXcgRXZlbnQoJ2lucHV0JywgeyBidWJibGVzOiB0cnVlIH0pKTsKICAgICAgICB9IGNhdGNo
IHt9CiAgICB9OwogICAgd2luZG93Ll9fYmtzcFNlYXJjaCA9ICgpID0+IHsKICAgICAgICB0cnkgewog
ICAgICAgICAgICB3aW5kb3cuX19wcmVwVHlwZVNlYXJjaCAmJiB3aW5kb3cuX19wcmVwVHlwZVNlYXJj
aCgpOwogICAgICAgICAgICBjb25zdCBzID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NlYXJjaCcp
OwogICAgICAgICAgICBpZiAoIXMpIHJldHVybjsKICAgICAgICAgICAgY29uc3QgdiA9IFN0cmluZyhz
LnZhbHVlIHx8ICcnKTsKICAgICAgICAgICAgcy52YWx1ZSA9IHYubGVuZ3RoID8gdi5zbGljZSgwLCAt
MSkgOiAnJzsKICAgICAgICAgICAgcy5jbGFzc0xpc3QudG9nZ2xlKCdoYXMtdmFsJywgISFzLnZhbHVl
KTsKICAgICAgICAgICAgcy5kaXNwYXRjaEV2ZW50KG5ldyBFdmVudCgnaW5wdXQnLCB7IGJ1YmJsZXM6
IHRydWUgfSkpOwogICAgICAgIH0gY2F0Y2gge30KICAgIH07CiAgICB3aW5kb3cuX19zZXRTZWFyY2hR
dWVyeSA9IChxKSA9PiB7CiAgICAgICAgdHJ5IHsKICAgICAgICAgICAgY29uc3QgcyA9IGRvY3VtZW50
LmdldEVsZW1lbnRCeUlkKCdzZWFyY2gnKTsKICAgICAgICAgICAgaWYgKCFzKSByZXR1cm47CiAgICAg
ICAgICAgIGNvbnN0IG5leHQgPSBTdHJpbmcocSA9PSBudWxsID8gJycgOiBxKTsKICAgICAgICAgICAg
Y29uc3QgcHJldiA9IFN0cmluZyhzLnZhbHVlIHx8ICcnKTsKICAgICAgICAgICAgLy8g5ZCM5YWz6ZSu
5a2X6YeN5aSN5o6o6YCB77ya5Y+q5L+d6K+B5pCc57Si5qGG5byA552A77yM56aB5q2i5YaNIHJlcXVl
c3RWaWV377yI5Lya5q275b6q546v6Zeq77yJCiAgICAgICAgICAgIGlmIChwcmV2ID09PSBuZXh0ICYm
IFN0cmluZyhxdWVyeSB8fCAnJykgPT09IG5leHQpIHsKICAgICAgICAgICAgICAgIHRyeSB7CiAgICAg
ICAgICAgICAgICAgICAgY29uc3Qgd3JhcCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzZWFyY2gt
d3JhcCcpOwogICAgICAgICAgICAgICAgICAgIGlmICh3cmFwICYmICF3cmFwLmNsYXNzTGlzdC5jb250
YWlucygnb3BlbicpKQogICAgICAgICAgICAgICAgICAgICAgICB3cmFwLmNsYXNzTGlzdC5hZGQoJ29w
ZW4nKTsKICAgICAgICAgICAgICAgIH0gY2F0Y2gge30KICAgICAgICAgICAgICAgIHJldHVybjsKICAg
ICAgICAgICAgfQogICAgICAgICAgICAvLyDmiZPlrZfljbPml7bkuIrlsY/vvIzkuI7no4Hnm5jmkJzn
tKLop6PogKYKICAgICAgICAgICAgcy52YWx1ZSA9IG5leHQ7CiAgICAgICAgICAgIHMuY2xhc3NMaXN0
LnRvZ2dsZSgnaGFzLXZhbCcsICEhcy52YWx1ZSk7CiAgICAgICAgICAgIGNvbnN0IHNjbHIgPSBkb2N1
bWVudC5nZXRFbGVtZW50QnlJZCgnc2VhcmNoLWNscicpOwogICAgICAgICAgICBpZiAoc2Nscikgc2Ns
ci5zdHlsZS5kaXNwbGF5ID0gcy52YWx1ZSA/ICdibG9jaycgOiAnbm9uZSc7CiAgICAgICAgICAgIHF1
ZXJ5ID0gcy52YWx1ZTsKICAgICAgICAgICAgdHJ5IHsKICAgICAgICAgICAgICAgIGNvbnN0IHdyYXAg
PSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc2VhcmNoLXdyYXAnKTsKICAgICAgICAgICAgICAgIGlm
ICh3cmFwICYmICF3cmFwLmNsYXNzTGlzdC5jb250YWlucygnb3BlbicpKQogICAgICAgICAgICAgICAg
ICAgIHdpbmRvdy5fX3ByZXBUeXBlU2VhcmNoICYmIHdpbmRvdy5fX3ByZXBUeXBlU2VhcmNoKCk7CiAg
ICAgICAgICAgICAgICBlbHNlIGlmICh3cmFwKQogICAgICAgICAgICAgICAgICAgIHdyYXAuY2xhc3NM
aXN0LmFkZCgnb3BlbicpOwogICAgICAgICAgICB9IGNhdGNoIHt9CiAgICAgICAgICAgIHdpbmRvdy5f
X2hvc3RGaWx0ZXJlZCA9IGZhbHNlOwogICAgICAgICAgICB3aW5kb3cuX19ob3N0RmlsdGVyUSA9ICcn
OwogICAgICAgICAgICBpZiAoU3RyaW5nKHF1ZXJ5IHx8ICcnKS50cmltKCkpIHsKICAgICAgICAgICAg
ICAgIHdhaXRpbmdEYXRhID0gdHJ1ZTsKICAgICAgICAgICAgICAgIHdpbmRvdy5fX2RhdGFSZWFkeSA9
IGZhbHNlOwogICAgICAgICAgICB9CiAgICAgICAgICAgIHRyeSB7CiAgICAgICAgICAgICAgICBjb25z
dCBjbnQgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYmFyLXR4dCcpOwogICAgICAgICAgICAgICAg
aWYgKGNudCAmJiBTdHJpbmcocXVlcnkgfHwgJycpLnRyaW0oKSkKICAgICAgICAgICAgICAgICAgICBj
bnQudGV4dENvbnRlbnQgPSB2aXNpYmxlTGlzdCgpLmxlbmd0aCArICcg5p2hJzsKICAgICAgICAgICAg
fSBjYXRjaCB7fQogICAgICAgICAgICB0cnkgeyByZW5kZXIoKTsgfSBjYXRjaCB7fQogICAgICAgICAg
ICBjbGVhclRpbWVvdXQod2luZG93Ll9fcXFWaWV3RGViKTsKICAgICAgICAgICAgd2luZG93Ll9fcXFW
aWV3RGViID0gc2V0VGltZW91dCgoKSA9PiB7CiAgICAgICAgICAgICAgICB3aW5kb3cuX19xcVZpZXdE
ZWIgPSAwOwogICAgICAgICAgICAgICAgcmVxdWVzdFZpZXcoKTsKICAgICAgICAgICAgfSwgNzApOwog
ICAgICAgIH0gY2F0Y2gge30KICAgIH07CiAgICB3aW5kb3cuX19jbGVhclFRU2VhcmNoID0gKCkgPT4g
ewogICAgICAgIHRyeSB7CiAgICAgICAgICAgIHF1ZXJ5ID0gJyc7CiAgICAgICAgICAgIHdpbmRvdy5f
X2hvc3RGaWx0ZXJlZCA9IGZhbHNlOwogICAgICAgICAgICB3aW5kb3cuX19ob3N0RmlsdGVyUSA9ICcn
OwogICAgICAgICAgICBjb25zdCBzID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NlYXJjaCcpOwog
ICAgICAgICAgICBpZiAocykgewogICAgICAgICAgICAgICAgcy52YWx1ZSA9ICcnOwogICAgICAgICAg
ICAgICAgcy5jbGFzc0xpc3QucmVtb3ZlKCdoYXMtdmFsJyk7CiAgICAgICAgICAgICAgICB0cnkgeyBz
LmJsdXIoKTsgfSBjYXRjaCB7fQogICAgICAgICAgICB9CiAgICAgICAgICAgIGNvbnN0IHNjbHIgPSBk
b2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc2VhcmNoLWNscicpOwogICAgICAgICAgICBpZiAoc2Nscikg
c2Nsci5zdHlsZS5kaXNwbGF5ID0gJ25vbmUnOwogICAgICAgICAgICBjb25zdCB3cmFwID0gZG9jdW1l
bnQuZ2V0RWxlbWVudEJ5SWQoJ3NlYXJjaC13cmFwJyk7CiAgICAgICAgICAgIGlmICh3cmFwKSB3cmFw
LmNsYXNzTGlzdC5yZW1vdmUoJ29wZW4nKTsKICAgICAgICAgICAgdHJ5IHsgcmVuZGVyKCk7IH0gY2F0
Y2gge30KICAgICAgICB9IGNhdGNoIHt9CiAgICB9OwogICAgLy8gQ2FwdHVyZSBDdHJsK0YgaW5zaWRl
IFdlYlZpZXcgKENocm9taXVtIGZpbmQgaXMgZGlzYWJsZWQsIGJ1dCBzdGlsbCBoYW5kbGUgaGVyZSkK
ICAgIGRvY3VtZW50LmFkZEV2ZW50TGlzdGVuZXIoJ2tleWRvd24nLCBlID0+IHsKICAgICAgICBpZiAo
KGUuY3RybEtleSB8fCBlLm1ldGFLZXkpICYmICFlLmFsdEtleSAmJiAoZS5rZXkgPT09ICdmJyB8fCBl
LmtleSA9PT0gJ0YnKSkgewogICAgICAgICAgICBlLnByZXZlbnREZWZhdWx0KCk7CiAgICAgICAgICAg
IGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAgICAgICAgIG9wZW5TZWFyY2goKTsKICAgICAgICB9CiAg
ICB9LCB0cnVlKTsKICAgIGJ0blNlYXJjaC5hZGRFdmVudExpc3RlbmVyKCdjbGljaycsIGUgPT4gewog
ICAgICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAgICAgb3BlblNlYXJjaCgpOwogICAgfSk7CiAg
ICBsZXQgX19zcmNoQ29tcG9zaW5nID0gZmFsc2U7CiAgICBjb25zdCBfX2ZsdXNoU2VhcmNoSW5wdXQg
PSAoKSA9PiB7CiAgICAgICAgcXVlcnkgPSBzcmNoLnZhbHVlOwogICAgICAgIHNyY2guY2xhc3NMaXN0
LnRvZ2dsZSgnaGFzLXZhbCcsICEhcXVlcnkpOwogICAgICAgIHNjbHIuc3R5bGUuZGlzcGxheSA9IHF1
ZXJ5ID8gJ2Jsb2NrJyA6ICdub25lJzsKICAgICAgICBsaXN0RWwuc2Nyb2xsVG9wID0gMDsKICAgICAg
ICB3aW5kb3cuX19ob3N0RmlsdGVyZWQgPSBmYWxzZTsKICAgICAgICB3aW5kb3cuX19ob3N0RmlsdGVy
USA9ICcnOwogICAgICAgIHRyeSB7IHJlbmRlcigpOyB9IGNhdGNoIHt9CiAgICAgICAgY2xlYXJUaW1l
b3V0KGRlYik7CiAgICAgICAgZGViID0gc2V0VGltZW91dChyZXF1ZXN0VmlldywgODApOwogICAgfTsK
ICAgIHNyY2guYWRkRXZlbnRMaXN0ZW5lcignY29tcG9zaXRpb25zdGFydCcsICgpID0+IHsgX19zcmNo
Q29tcG9zaW5nID0gdHJ1ZTsgfSk7CiAgICBzcmNoLmFkZEV2ZW50TGlzdGVuZXIoJ2NvbXBvc2l0aW9u
ZW5kJywgKCkgPT4gewogICAgICAgIF9fc3JjaENvbXBvc2luZyA9IGZhbHNlOwogICAgICAgIF9fZmx1
c2hTZWFyY2hJbnB1dCgpOwogICAgfSk7CiAgICBzcmNoLmFkZEV2ZW50TGlzdGVuZXIoJ2lucHV0Jywg
KCkgPT4gewogICAgICAgIGlmIChfX3NyY2hDb21wb3NpbmcpIHsKICAgICAgICAgICAgcXVlcnkgPSBz
cmNoLnZhbHVlOwogICAgICAgICAgICBzcmNoLmNsYXNzTGlzdC50b2dnbGUoJ2hhcy12YWwnLCAhIXF1
ZXJ5KTsKICAgICAgICAgICAgc2Nsci5zdHlsZS5kaXNwbGF5ID0gcXVlcnkgPyAnYmxvY2snIDogJ25v
bmUnOwogICAgICAgICAgICByZXR1cm47CiAgICAgICAgfQogICAgICAgIF9fZmx1c2hTZWFyY2hJbnB1
dCgpOwogICAgfSk7CiAgICBzcmNoLmFkZEV2ZW50TGlzdGVuZXIoJ2ZvY3VzJywgKCkgPT4gewogICAg
ICAgIC8vIElkZW1wb3RlbnQgb24gQUhLIHNpZGUg4oCUIHNhZmUsIGJ1dCBhdm9pZCBzcGFtbWluZyBk
dXJpbmcgSU1FCiAgICAgICAgdHJ5IHsgYWhrKCdmb2N1c1BhbmVsJyk7IH0gY2F0Y2gge30KICAgIH0p
OwogICAgc3JjaC5hZGRFdmVudExpc3RlbmVyKCdibHVyJywgKCkgPT4gewogICAgICAgIHNldFRpbWVv
dXQoKCkgPT4gewogICAgICAgICAgICBpZiAoZG9jdW1lbnQuYWN0aXZlRWxlbWVudCA9PT0gc3JjaCkg
cmV0dXJuOwogICAgICAgICAgICBpZiAoZG9jdW1lbnQuYWN0aXZlRWxlbWVudCA9PT0gc2NsciB8fCAo
c2NsciAmJiBzY2xyLmNvbnRhaW5zKGRvY3VtZW50LmFjdGl2ZUVsZW1lbnQpKSkgcmV0dXJuOwogICAg
ICAgICAgICBpZiAoZG9jdW1lbnQuYWN0aXZlRWxlbWVudCA9PT0gYnRuVG9kYXkgfHwgKGJ0blRvZGF5
ICYmIGJ0blRvZGF5LmNvbnRhaW5zKGRvY3VtZW50LmFjdGl2ZUVsZW1lbnQpKSkgcmV0dXJuOwogICAg
ICAgICAgICAvLyBJTUUgY2FuZGlkYXRlIFVJIHN0ZWFscyBmb2N1cyBicmllZmx5IOKAlCBrZWVwIHNl
YXJjaCBpZiBzdGlsbCBjb21wb3NpbmcKICAgICAgICAgICAgaWYgKF9fc3JjaENvbXBvc2luZykgcmV0
dXJuOwogICAgICAgICAgICBjbG9zZVNlYXJjaFVpKCk7CiAgICAgICAgICAgIGFoaygnYmx1clBhbmVs
Jyk7CiAgICAgICAgfSwgMjgwKTsKICAgIH0pOwogICAgc3JjaC5hZGRFdmVudExpc3RlbmVyKCdrZXlk
b3duJywgZSA9PiB7CiAgICAgICAgLy8gQ3RybCtJIC8gQ3RybCtLOiBtb3ZlIGNsaXAgc2VsZWN0aW9u
IChub3QgaW5zZXJ0IGNoYXIgLyBicm93c2VyIHNob3J0Y3V0KQogICAgICAgIGlmICgoZS5jdHJsS2V5
IHx8IGUubWV0YUtleSkgJiYgKGUua2V5ID09PSAnaScgfHwgZS5rZXkgPT09ICdJJykpIHsKICAgICAg
ICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOwogICAgICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwog
ICAgICAgICAgICB3aW5kb3cuX19uYXYgJiYgd2luZG93Ll9fbmF2KCd1cCcpOwogICAgICAgICAgICBy
ZXR1cm47CiAgICAgICAgfQogICAgICAgIGlmICgoZS5jdHJsS2V5IHx8IGUubWV0YUtleSkgJiYgKGUu
a2V5ID09PSAnaycgfHwgZS5rZXkgPT09ICdLJykpIHsKICAgICAgICAgICAgZS5wcmV2ZW50RGVmYXVs
dCgpOwogICAgICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgICAgICAgICB3aW5kb3cuX19u
YXYgJiYgd2luZG93Ll9fbmF2KCdkb3duJyk7CiAgICAgICAgICAgIHJldHVybjsKICAgICAgICB9CiAg
ICAgICAgaWYgKGUua2V5ID09PSAnQXJyb3dEb3duJykgewogICAgICAgICAgICBlLnByZXZlbnREZWZh
dWx0KCk7CiAgICAgICAgICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAgICAgICAgIHdpbmRvdy5f
X25hdiAmJiB3aW5kb3cuX19uYXYoJ2Rvd24nKTsKICAgICAgICAgICAgcmV0dXJuOwogICAgICAgIH0K
ICAgICAgICBpZiAoZS5rZXkgPT09ICdBcnJvd1VwJykgewogICAgICAgICAgICBlLnByZXZlbnREZWZh
dWx0KCk7CiAgICAgICAgICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAgICAgICAgIHdpbmRvdy5f
X25hdiAmJiB3aW5kb3cuX19uYXYoJ3VwJyk7CiAgICAgICAgICAgIHJldHVybjsKICAgICAgICB9CiAg
ICAgICAgaWYgKGUua2V5ID09PSAnRXNjYXBlJykgewogICAgICAgICAgICBlLnByZXZlbnREZWZhdWx0
KCk7CiAgICAgICAgICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAgICAgICAgIC8vIEFsd2F5cyBk
aXNtaXNzIHRoZSB3aG9sZSBwYW5lbCAobm90IGp1c3QgdGhlIHNlYXJjaCBmaWVsZCkKICAgICAgICAg
ICAgaWYgKCFwaW5uZWRVSSkgYWhrKCdoaWRlJyk7CiAgICAgICAgICAgIHJldHVybjsKICAgICAgICB9
CiAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgIH0pOwogICAgc2Nsci5hZGRFdmVudExpc3Rl
bmVyKCdjbGljaycsIGUgPT4gewogICAgICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAgICAgc3Jj
aC52YWx1ZSA9IHF1ZXJ5ID0gJyc7CiAgICAgICAgc2Nsci5zdHlsZS5kaXNwbGF5ID0gJ25vbmUnOwog
ICAgICAgIHNyY2guY2xhc3NMaXN0LnJlbW92ZSgnaGFzLXZhbCcpOwogICAgICAgIHJlcXVlc3RWaWV3
KCk7CiAgICAgICAgYWhrKCdmb2N1c1BhbmVsJyk7CiAgICAgICAgc3JjaC5mb2N1cygpOwogICAgfSk7
CgogICAgY29uc3QgVEFCX05BTUVTID0geyBhbGw6ICflhajpg6gnLCB0ZXh0OiAn5paH5pysJywgaW1h
Z2U6ICflm77lg48nLCBmaWxlOiAn5paH5Lu2JywgcmVjZW50OiAn5pyA6L+RJywgcGlubmVkOiAn5pS2
6JePJyB9OwogICAgY29uc3QgY2xyRGxnID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2Nsci1kbGcn
KTsKICAgIGNvbnN0IGNsckFsbENiID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2Nsci1hbGwnKTsK
ICAgIGZ1bmN0aW9uIG9wZW5DbGVhckRsZygpIHsKICAgICAgICBjb25zdCBuYW1lID0gVEFCX05BTUVT
W2N1clRhYl0gfHwgJ+W9k+WJjSc7CiAgICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2Nsci10
aXRsZScpLnRleHRDb250ZW50ID0gJ+a4heepuuOAjCcgKyBuYW1lICsgJ+OAje+8nyc7CiAgICAgICAg
ZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2Nsci1kZXNjJykudGV4dENvbnRlbnQgPSBjdXJUYWIgPT09
ICdyZWNlbnQnCiAgICAgICAgICAgID8gJ+a4heepuuacquWbuuWumueahOacgOi/keaWh+S7tuWkue+8
m+W3suWbuuWumueahOi3r+W+hOS8muS/neeVmeOAgicKICAgICAgICAgICAgOiAoY3VyVGFiID09PSAn
cGlubmVkJwogICAgICAgICAgICA/ICfpu5jorqTku4XmuIXnqbrlvZPlpKnnmoTmlLbol4/pobnjgILl
i77pgInjgIzmuIXnqbrmiYDmnInjgI3lj6/muIXpmaTor6XpgInpobnljaHlhajpg6jlhoXlrrnjgIIn
CiAgICAgICAgICAgIDogJ+S7hea4heepuuW9k+WJjemAiemhueWNoeOAgum7mOiupOWPqua4heW9k+Wk
qe+8m+aUtuiXj+mhueS4jeS8muiiq+a4hemZpOOAguWLvumAieOAjOa4heepuuaJgOacieOAjeWPr+a4
hemZpOivpemAiemhueWNoeWFqOmDqOaXpeacn+OAgicpOwogICAgICAgIGNsckFsbENiLmNoZWNrZWQg
PSBmYWxzZTsKICAgICAgICBjbHJEbGcuY2xhc3NMaXN0LmFkZCgnb24nKTsKICAgIH0KICAgIGZ1bmN0
aW9uIGNsb3NlQ2xlYXJEbGcoKSB7CiAgICAgICAgY2xyRGxnLmNsYXNzTGlzdC5yZW1vdmUoJ29uJyk7
CiAgICB9CiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYnRuLWNscicpLmFkZEV2ZW50TGlzdGVu
ZXIoJ2NsaWNrJywgZSA9PiB7CiAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICBvcGVu
Q2xlYXJEbGcoKTsKICAgIH0pOwogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2Nsci1jYW5jZWwn
KS5hZGRFdmVudExpc3RlbmVyKCdjbGljaycsIGUgPT4gewogICAgICAgIGUuc3RvcFByb3BhZ2F0aW9u
KCk7CiAgICAgICAgY2xvc2VDbGVhckRsZygpOwogICAgfSk7CiAgICBjbHJEbGcuYWRkRXZlbnRMaXN0
ZW5lcignY2xpY2snLCBlID0+IHsKICAgICAgICBpZiAoZS50YXJnZXQgPT09IGNsckRsZykgY2xvc2VD
bGVhckRsZygpOwogICAgfSk7CiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnY2xyLW9rJykuYWRk
RXZlbnRMaXN0ZW5lcignY2xpY2snLCBlID0+IHsKICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwog
ICAgICAgIGNvbnN0IHNjb3BlID0gKGN1clRhYiA9PT0gJ3JlY2VudCcpID8gJ2FsbCcgOiAoY2xyQWxs
Q2IuY2hlY2tlZCA/ICdhbGwnIDogJ3RvZGF5Jyk7CiAgICAgICAgY2xvc2VDbGVhckRsZygpOwogICAg
ICAgIGFoaygnY2xlYXInLCBjdXJUYWIsIHNjb3BlKTsKICAgIH0pOwogICAgZG9jdW1lbnQuZ2V0RWxl
bWVudEJ5SWQoJ211bHRpLWNudCcpLmFkZEV2ZW50TGlzdGVuZXIoJ2NsaWNrJywgZSA9PiB7CiAgICAg
ICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICBjbGVhck11bHRpKHRydWUpOwogICAgfSk7CiAg
ICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYnRuLXBpbicpLmFkZEV2ZW50TGlzdGVuZXIoJ2NsaWNr
JywgZSA9PiB7CiAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICBwaW5uZWRVSSA9ICFw
aW5uZWRVSTsKICAgICAgICBlLmN1cnJlbnRUYXJnZXQuY2xhc3NMaXN0LnRvZ2dsZSgnb24nLCBwaW5u
ZWRVSSk7CiAgICAgICAgYWhrKCd0b2dnbGVQaW4nLCBwaW5uZWRVSSA/ICcxJyA6ICcwJyk7CiAgICB9
KTsKCiAgICB3aW5kb3cuX191cGRhdGVDbGlwcyA9IHBheWxvYWQgPT4gewogICAgICAgIC8vIEtlZXAg
cHJldmlvdXMgc2Nyb2xsIGZvciBsb2FkLW1vcmU7IHJlc2V0IHdoZW4gb3BlbmluZyBwYW5lbCB0byBm
aXJzdCBpdGVtCiAgICAgICAgY29uc3Qga2VlcFNjcm9sbCA9ICFzZWxlY3RGaXJzdE9uU2hvdzsKICAg
ICAgICBjb25zdCBzdCA9IGxpc3RFbC5zY3JvbGxUb3A7CiAgICAgICAgd2luZG93Ll9fd2FpdGluZ1Zp
ZXcgPSBmYWxzZTsKICAgICAgICBjb25zdCB3YXNBcHBlbmQgPSBwYXlsb2FkICYmIHBheWxvYWQuYXBw
ZW5kOwogICAgICAgIGxvYWRpbmdNb3JlID0gZmFsc2U7CiAgICAgICAgY29uc3QgcHJldkl0ZW1zID0g
YWxsQ2xpcHM7CiAgICAgICAgbGV0IG5leHRJdGVtcyA9IFtdOwogICAgICAgIGxldCBuZXh0VG90YWwg
PSAwOwogICAgICAgIGxldCBuZXh0RmlsdGVyZWQgPSBmYWxzZTsKICAgICAgICBsZXQgcFRhYiA9ICcn
OwogICAgICAgIGxldCBwUGlubmVkVG90YWwgPSAtMTsKICAgICAgICBpZiAoQXJyYXkuaXNBcnJheShw
YXlsb2FkKSkgewogICAgICAgICAgICBuZXh0SXRlbXMgPSBwYXlsb2FkOwogICAgICAgICAgICBuZXh0
VG90YWwgPSBwYXlsb2FkLmxlbmd0aDsKICAgICAgICAgICAgbmV4dEZpbHRlcmVkID0gZmFsc2U7CiAg
ICAgICAgfSBlbHNlIGlmIChwYXlsb2FkICYmIHR5cGVvZiBwYXlsb2FkID09PSAnb2JqZWN0Jykgewog
ICAgICAgICAgICBuZXh0VG90YWwgPSBOdW1iZXIocGF5bG9hZC50b3RhbCkgfHwgMDsKICAgICAgICAg
ICAgbmV4dEl0ZW1zID0gQXJyYXkuaXNBcnJheShwYXlsb2FkLml0ZW1zKSA/IHBheWxvYWQuaXRlbXMg
OiBbXTsKICAgICAgICAgICAgcFRhYiA9IHBheWxvYWQudGFiICE9IG51bGwgPyBTdHJpbmcocGF5bG9h
ZC50YWIpIDogJyc7CiAgICAgICAgICAgIGlmIChwYXlsb2FkLnBpbm5lZFRvdGFsICE9IG51bGwgJiYg
cGF5bG9hZC5waW5uZWRUb3RhbCAhPT0gJycpCiAgICAgICAgICAgICAgICBwUGlubmVkVG90YWwgPSBO
dW1iZXIocGF5bG9hZC5waW5uZWRUb3RhbCkgfHwgMDsKICAgICAgICAgICAgY29uc3QgcHEwID0gcGF5
bG9hZC5xdWVyeSAhPSBudWxsID8gU3RyaW5nKHBheWxvYWQucXVlcnkpIDogJyc7CiAgICAgICAgICAg
IG5leHRGaWx0ZXJlZCA9ICEhKHBheWxvYWQuZmlsdGVyZWQgfHwgKHBxMCAmJiBwcTAudHJpbSgpKSk7
CiAgICAgICAgICAgIGlmIChwYXlsb2FkLmFwcGVuZCkgewogICAgICAgICAgICAgICAgLy8gQXBwZW5k
IG9ubHkgYXBwbGllcyB0byB0aGUgdGFiIHdlJ3JlIGN1cnJlbnRseSB2aWV3aW5nCiAgICAgICAgICAg
ICAgICBpZiAocFRhYiAmJiBwVGFiICE9PSBjdXJUYWIpCiAgICAgICAgICAgICAgICAgICAgcmV0dXJu
OwogICAgICAgICAgICAgICAgY29uc3Qgc2VlbiA9IG5ldyBTZXQoYWxsQ2xpcHMubWFwKGMgPT4gK2Mu
aWQpKTsKICAgICAgICAgICAgICAgIGNvbnN0IG1lcmdlZCA9IGFsbENsaXBzLnNsaWNlKCk7CiAgICAg
ICAgICAgICAgICBuZXh0SXRlbXMuZm9yRWFjaChpdCA9PiB7CiAgICAgICAgICAgICAgICAgICAgaWYg
KCFzZWVuLmhhcygraXQuaWQpKSBtZXJnZWQucHVzaChpdCk7CiAgICAgICAgICAgICAgICB9KTsKICAg
ICAgICAgICAgICAgIG5leHRJdGVtcyA9IG1lcmdlZDsKICAgICAgICAgICAgICAgIG5leHRUb3RhbCA9
IE1hdGgubWF4KG5leHRUb3RhbCwgbmV4dEl0ZW1zLmxlbmd0aCk7CiAgICAgICAgICAgIH0KICAgICAg
ICAgICAgLy8g5pCc57Si5qGG5Lul5omT5a2X6ZWc5YOP5Li65YeG77yM57ud5LiN6KKr5rue5ZCO55qE
56OB55uY57uT5p6c5YaZ5Zue5pen5YWz6ZSu5a2XCiAgICAgICAgICAgIHRyeSB7CiAgICAgICAgICAg
ICAgICBjb25zdCBzID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NlYXJjaCcpOwogICAgICAgICAg
ICAgICAgaWYgKHMgJiYgU3RyaW5nKHMudmFsdWUgfHwgJycpLmxlbmd0aCkKICAgICAgICAgICAgICAg
ICAgICBxdWVyeSA9IHMudmFsdWU7CiAgICAgICAgICAgICAgICBlbHNlIGlmIChwcTAgIT09ICcnICYm
ICFTdHJpbmcocXVlcnkgfHwgJycpLnRyaW0oKSkKICAgICAgICAgICAgICAgICAgICBxdWVyeSA9IHBx
MDsKICAgICAgICAgICAgfSBjYXRjaCB7fQogICAgICAgIH0gZWxzZSB7CiAgICAgICAgICAgIG5leHRJ
dGVtcyA9IFtdOwogICAgICAgICAgICBuZXh0VG90YWwgPSAwOwogICAgICAgICAgICBuZXh0RmlsdGVy
ZWQgPSBmYWxzZTsKICAgICAgICB9CgogICAgICAgIGNvbnN0IGJveFEgPSBTdHJpbmcocXVlcnkgfHwg
JycpLnRyaW0oKTsKICAgICAgICBjb25zdCBwdXNoUSA9IChwYXlsb2FkICYmIHR5cGVvZiBwYXlsb2Fk
ID09PSAnb2JqZWN0JyAmJiBwYXlsb2FkLnF1ZXJ5ICE9IG51bGwpCiAgICAgICAgICAgID8gU3RyaW5n
KHBheWxvYWQucXVlcnkpLnRyaW0oKSA6ICcnOwoKICAgICAgICAvLyBBbHdheXMgcmVmcmVzaCDmlLbo
l48gYmFkZ2UgZnJvbSBob3N0IHdoZW4gcHJvdmlkZWQKICAgICAgICBpZiAocFBpbm5lZFRvdGFsID49
IDApCiAgICAgICAgICAgIHBpbm5lZFRvdGFsID0gcFBpbm5lZFRvdGFsOwoKICAgICAgICAvLyBTdGFs
ZSBzZWFyY2ggcHVzaCAoZS5nLiAic3F1YXJlIGxvZ2kiIGxhbmRzIGFmdGVyIHVzZXIgdHlwZWQgInNx
dWFyZSBsb2dpbiIpIOKAlGNhY2hlIG9ubHkKICAgICAgICBpZiAoIXdhc0FwcGVuZCAmJiBuZXh0Rmls
dGVyZWQgJiYgcHVzaFEgJiYgYm94USAmJiBwdXNoUSAhPT0gYm94USkgewogICAgICAgICAgICB2aWV3
TWVtLnNldCh2aWV3TWVtS2V5KHBUYWIgfHwgY3VyVGFiLCBwdXNoUSwgdG9kYXlPbmx5KSwgewogICAg
ICAgICAgICAgICAgaXRlbXM6IG5leHRJdGVtcy5zbGljZSgpLAogICAgICAgICAgICAgICAgdG90YWw6
IG5leHRUb3RhbAogICAgICAgICAgICB9KTsKICAgICAgICAgICAgcmV0dXJuOwogICAgICAgIH0KCiAg
ICAgICAgLy8gU3RhbGUgcHVzaCBmb3IgYW5vdGhlciB0YWI6IG9ubHkgcmVmcmVzaCB0aGF0IHRhYidz
IHZpZXdNZW0sIGRvbid0IGhpamFjayBVSQogICAgICAgIGlmICghd2FzQXBwZW5kICYmIHBUYWIgJiYg
cFRhYiAhPT0gY3VyVGFiKSB7CiAgICAgICAgICAgIGNvbnN0IG1lbVEgPSAocGF5bG9hZCAmJiB0eXBl
b2YgcGF5bG9hZCA9PT0gJ29iamVjdCcgJiYgcGF5bG9hZC5xdWVyeSAhPSBudWxsKQogICAgICAgICAg
ICAgICAgPyBTdHJpbmcocGF5bG9hZC5xdWVyeSkgOiAnJzsKICAgICAgICAgICAgdmlld01lbS5zZXQo
dmlld01lbUtleShwVGFiLCBtZW1RLCB0b2RheU9ubHkpLCB7CiAgICAgICAgICAgICAgICBpdGVtczog
bmV4dEl0ZW1zLnNsaWNlKCksCiAgICAgICAgICAgICAgICB0b3RhbDogbmV4dFRvdGFsCiAgICAgICAg
ICAgIH0pOwogICAgICAgICAgICAvLyBTdGlsbCB1cGRhdGUgcGluIGJhZGdlIGlmIGhvc3Qgc2VudCBp
dAogICAgICAgICAgICB0cnkgewogICAgICAgICAgICAgICAgY29uc3QgcGluQ250ID0gZG9jdW1lbnQu
Z2V0RWxlbWVudEJ5SWQoJ3Bpbi1jbnQnKTsKICAgICAgICAgICAgICAgIGlmIChwaW5DbnQgJiYgcGlu
bmVkVG90YWwgPiAwKSB7CiAgICAgICAgICAgICAgICAgICAgcGluQ250LnRleHRDb250ZW50ID0gcGlu
bmVkVG90YWw7CiAgICAgICAgICAgICAgICAgICAgcGluQ250LnN0eWxlLmRpc3BsYXkgPSAnJzsKICAg
ICAgICAgICAgICAgIH0KICAgICAgICAgICAgfSBjYXRjaCB7fQogICAgICAgICAgICAvLyBRUSDmkJzn
tKLmm77lm7rlrprmjqggYWxsIHRhYiDihpIg5b2T5YmNIHRhYiDkvJrkuIDnm7TpqqjmnrbvvJvooaXk
uIDmrKEgcmVxdWVzdFZpZXcKICAgICAgICAgICAgaWYgKHdhaXRpbmdEYXRhICYmIHB1c2hRID09PSBi
b3hRKSB7CiAgICAgICAgICAgICAgICBzZXRUaW1lb3V0KCgpID0+IHsKICAgICAgICAgICAgICAgICAg
ICBpZiAod2FpdGluZ0RhdGEgJiYgY3VyVGFiICE9PSBwVGFiKQogICAgICAgICAgICAgICAgICAgICAg
ICByZXF1ZXN0VmlldygpOwogICAgICAgICAgICAgICAgfSwgNDApOwogICAgICAgICAgICB9CiAgICAg
ICAgICAgIHJldHVybjsKICAgICAgICB9CgogICAgICAgIC8vIEJvb3RzdHJhcCByYWNlOiBBSEsgcHVz
aGVkIGVtcHR5IGJlZm9yZSBXYXJtQWxsVmlld3Mg4oCUa2VlcCBza2VsZXRvbiwgaWdub3JlCiAgICAg
ICAgY29uc3QgcU9uID0gU3RyaW5nKHF1ZXJ5IHx8ICcnKS50cmltKCkubGVuZ3RoID4gMDsKICAgICAg
ICBpZiAoIXdhc0FwcGVuZCAmJiAhbmV4dEl0ZW1zLmxlbmd0aCAmJiBuZXh0VG90YWwgPD0gMCAmJiAh
cU9uICYmICFuZXh0RmlsdGVyZWQgJiYgIXNhd05vbkVtcHR5KSB7CiAgICAgICAgICAgIGlmICghd2lu
ZG93Ll9fZW1wdHlGYWxsYmFja1QpIHsKICAgICAgICAgICAgICAgIHdpbmRvdy5fX2VtcHR5RmFsbGJh
Y2tUID0gc2V0VGltZW91dCgoKSA9PiB7CiAgICAgICAgICAgICAgICAgICAgd2luZG93Ll9fZW1wdHlG
YWxsYmFja1QgPSAwOwogICAgICAgICAgICAgICAgICAgIGlmIChzYXdOb25FbXB0eSkgcmV0dXJuOwog
ICAgICAgICAgICAgICAgICAgIC8vIFRydWx5IGVtcHR5IGluc3RhbGwgYWZ0ZXIgd2FpdAogICAgICAg
ICAgICAgICAgICAgIHNhd05vbkVtcHR5ID0gdHJ1ZTsKICAgICAgICAgICAgICAgICAgICBob3N0UHVz
aGVkT25jZSA9IHRydWU7CiAgICAgICAgICAgICAgICAgICAgd2luZG93Ll9fZGF0YVJlYWR5ID0gdHJ1
ZTsKICAgICAgICAgICAgICAgICAgICBhbGxDbGlwcyA9IFtdOwogICAgICAgICAgICAgICAgICAgIGRp
c2tUb3RhbCA9IDA7CiAgICAgICAgICAgICAgICAgICAgY2xlYXJXYWl0aW5nRGF0YSgpOwogICAgICAg
ICAgICAgICAgICAgIHRyeSB7IHJlbmRlcigpOyB9IGNhdGNoIHt9CiAgICAgICAgICAgICAgICB9LCA0
NTAwKTsKICAgICAgICAgICAgfQogICAgICAgICAgICB3YWl0aW5nRGF0YSA9IHRydWU7CiAgICAgICAg
ICAgIHdpbmRvdy5fX2RhdGFSZWFkeSA9IGZhbHNlOwogICAgICAgICAgICBob3N0UHVzaGVkT25jZSA9
IGZhbHNlOwogICAgICAgICAgICBzZXRCb290TG9hZGluZyh0cnVlKTsKICAgICAgICAgICAgdHJ5IHsg
cmVuZGVyKCk7IH0gY2F0Y2gge30KICAgICAgICAgICAgcmV0dXJuOwogICAgICAgIH0KCiAgICAgICAg
Y2xlYXJXYWl0aW5nRGF0YSgpOwogICAgICAgIGFsbENsaXBzID0gbmV4dEl0ZW1zOwogICAgICAgIGRp
c2tUb3RhbCA9IG5leHRUb3RhbDsKICAgICAgICAvLyBLZWVwIGJhciBjb25zaXN0ZW50IGlmIGxpc3Qg
Z3JldyBwYXN0IGEgc3RhbGUgdG90YWwKICAgICAgICBpZiAoYWxsQ2xpcHMubGVuZ3RoID4gZGlza1Rv
dGFsKQogICAgICAgICAgICBkaXNrVG90YWwgPSBhbGxDbGlwcy5sZW5ndGg7CiAgICAgICAgd2luZG93
Ll9faG9zdEZpbHRlcmVkID0gbmV4dEZpbHRlcmVkOwogICAgICAgIHdpbmRvdy5fX2hvc3RGaWx0ZXJR
ID0gKG5leHRGaWx0ZXJlZCAmJiBwdXNoUSkgPyBwdXNoUSA6ICcnOwogICAgICAgIC8vIEZpbHRlcmVk
IHNlYXJjaCB3aXRoIDAgaGl0cyDigJRtdXN0IGxlYXZlIHNrZWxldG9uIChob3N0IGRpZCByZXNwb25k
KQogICAgICAgIGlmICghd2FzQXBwZW5kICYmIG5leHRGaWx0ZXJlZCAmJiAhYWxsQ2xpcHMubGVuZ3Ro
ICYmIGRpc2tUb3RhbCA8PSAwKSB7CiAgICAgICAgICAgIGhvc3RQdXNoZWRPbmNlID0gdHJ1ZTsKICAg
ICAgICAgICAgc2F3Tm9uRW1wdHkgPSB0cnVlOwogICAgICAgIH0KICAgICAgICBpZiAoYWxsQ2xpcHMu
bGVuZ3RoIHx8IGRpc2tUb3RhbCA+IDApCiAgICAgICAgICAgIHNhd05vbkVtcHR5ID0gdHJ1ZTsKICAg
ICAgICBpZiAod2luZG93Ll9fZW1wdHlGYWxsYmFja1QpIHsKICAgICAgICAgICAgY2xlYXJUaW1lb3V0
KHdpbmRvdy5fX2VtcHR5RmFsbGJhY2tUKTsKICAgICAgICAgICAgd2luZG93Ll9fZW1wdHlGYWxsYmFj
a1QgPSAwOwogICAgICAgIH0KICAgICAgICBpZiAoIXdhc0FwcGVuZCkgewogICAgICAgICAgICBjb25z
dCBtZW1RID0gKHBheWxvYWQgJiYgdHlwZW9mIHBheWxvYWQgPT09ICdvYmplY3QnICYmIHBheWxvYWQu
cXVlcnkgIT0gbnVsbCkKICAgICAgICAgICAgICAgID8gU3RyaW5nKHBheWxvYWQucXVlcnkpIDogcXVl
cnk7CiAgICAgICAgICAgIHZpZXdNZW0uc2V0KHZpZXdNZW1LZXkoY3VyVGFiLCBtZW1RLCB0b2RheU9u
bHkpLCB7CiAgICAgICAgICAgICAgICBpdGVtczogYWxsQ2xpcHMuc2xpY2UoKSwKICAgICAgICAgICAg
ICAgIHRvdGFsOiBkaXNrVG90YWwKICAgICAgICAgICAgfSk7CiAgICAgICAgfQogICAgICAgIHdpbmRv
dy5fX2RhdGFSZWFkeSA9IHRydWU7CiAgICAgICAgaG9zdFB1c2hlZE9uY2UgPSB0cnVlOwogICAgICAg
IGNvbnN0IHdhc0Jvb3RMb2FkaW5nID0gYm9vdExvYWRpbmc7CiAgICAgICAgbGV0IHNhbWVQYWludCA9
IGZhbHNlOwogICAgICAgIGlmICghd2FzQXBwZW5kICYmICF3YXNCb290TG9hZGluZyAmJiBwcmV2SXRl
bXMgJiYgcHJldkl0ZW1zLmxlbmd0aCA9PT0gYWxsQ2xpcHMubGVuZ3RoICYmIHByZXZJdGVtcy5sZW5n
dGgpIHsKICAgICAgICAgICAgc2FtZVBhaW50ID0gdHJ1ZTsKICAgICAgICAgICAgZm9yIChsZXQgaSA9
IDA7IGkgPCBhbGxDbGlwcy5sZW5ndGg7IGkrKykgewogICAgICAgICAgICAgICAgaWYgKCtwcmV2SXRl
bXNbaV0uaWQgIT09ICthbGxDbGlwc1tpXS5pZCkgeyBzYW1lUGFpbnQgPSBmYWxzZTsgYnJlYWs7IH0K
ICAgICAgICAgICAgfQogICAgICAgICAgICBpZiAoc2FtZVBhaW50ICYmICFsaXN0RWwucXVlcnlTZWxl
Y3RvcignLml0bScpKSBzYW1lUGFpbnQgPSBmYWxzZTsKICAgICAgICB9CiAgICAgICAgY29uc3QgZmlu
aXNoVXBkYXRlID0gKCkgPT4gewogICAgICAgICAgICBjbGVhcldhaXRpbmdEYXRhKCk7CiAgICAgICAg
ICAgIGlmICghc2FtZVBhaW50KSB7CiAgICAgICAgICAgICAgICByZW5kZXIoKTsKICAgICAgICAgICAg
ICAgIGFwcGx5VGFiU3dpdGNoQW5pbSgpOwogICAgICAgICAgICB9IGVsc2UgewogICAgICAgICAgICAg
ICAgLy8gc2FtZSBpZHMg4oCUc3RpbGwgcmVmcmVzaCBjb3VudHMgKHBpbm5lZFRvdGFsIC8gZGlza1Rv
dGFsIG1heSBoYXZlIGNoYW5nZWQpCiAgICAgICAgICAgICAgICB0cnkgewogICAgICAgICAgICAgICAg
ICAgIGNvbnN0IHBpbkNudCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdwaW4tY250Jyk7CiAgICAg
ICAgICAgICAgICAgICAgaWYgKHBpbkNudCkgewogICAgICAgICAgICAgICAgICAgICAgICBjb25zdCBu
ID0gTnVtYmVyKHBpbm5lZFRvdGFsKSB8fCAoY3VyVGFiID09PSAncGlubmVkJyA/IGRpc2tUb3RhbCA6
IDApOwogICAgICAgICAgICAgICAgICAgICAgICBpZiAobiA+IDApIHsKICAgICAgICAgICAgICAgICAg
ICAgICAgICAgIHBpbkNudC50ZXh0Q29udGVudCA9IG47CiAgICAgICAgICAgICAgICAgICAgICAgICAg
ICBwaW5DbnQuc3R5bGUuZGlzcGxheSA9ICcnOwogICAgICAgICAgICAgICAgICAgICAgICB9CiAgICAg
ICAgICAgICAgICAgICAgfQogICAgICAgICAgICAgICAgICAgIGNvbnN0IGxvYWRlZCA9IGFsbENsaXBz
Lmxlbmd0aDsKICAgICAgICAgICAgICAgICAgICBsZXQgc2hvd1RvdGFsID0gZGlza1RvdGFsID4gMCA/
IGRpc2tUb3RhbCA6IGxvYWRlZDsKICAgICAgICAgICAgICAgICAgICBpZiAoY3VyVGFiID09PSAncGlu
bmVkJyAmJiBwaW5uZWRUb3RhbCA+IHNob3dUb3RhbCkKICAgICAgICAgICAgICAgICAgICAgICAgc2hv
d1RvdGFsID0gcGlubmVkVG90YWw7CiAgICAgICAgICAgICAgICAgICAgY29uc3QgcU9uMiA9IFN0cmlu
ZyhxdWVyeSB8fCAnJykudHJpbSgpLmxlbmd0aCA+IDA7CiAgICAgICAgICAgICAgICAgICAgZG9jdW1l
bnQuZ2V0RWxlbWVudEJ5SWQoJ2Jhci10eHQnKS50ZXh0Q29udGVudCA9IHFPbjIKICAgICAgICAgICAg
ICAgICAgICAgICAgPyAobG9hZGVkICsgJyDmnaEnKQogICAgICAgICAgICAgICAgICAgICAgICA6IChz
aG93VG90YWwgPiBsb2FkZWQgPyAobG9hZGVkICsgJyAvICcgKyBzaG93VG90YWwgKyAnIOadoScpIDog
KHNob3dUb3RhbCArICcg5p2hJykpOwogICAgICAgICAgICAgICAgfSBjYXRjaCB7fQogICAgICAgICAg
ICB9CiAgICAgICAgICAgIGlmIChrZWVwU2Nyb2xsKQogICAgICAgICAgICAgICAgbGlzdEVsLnNjcm9s
bFRvcCA9IHN0OwogICAgICAgICAgICBlbHNlIGlmICghc2FtZVBhaW50KQogICAgICAgICAgICAgICAg
bGlzdEVsLnNjcm9sbFRvcCA9IDA7CiAgICAgICAgfTsKICAgICAgICBpZiAod2FzQm9vdExvYWRpbmcp
IHsKICAgICAgICAgICAgY29uc3Qgc2luY2UgPSB3aW5kb3cuX19za2VsU2luY2UgfHwgMDsKICAgICAg
ICAgICAgY29uc3Qgd2FpdCA9IHNpbmNlID8gTWF0aC5tYXgoMCwgODAgLSAoRGF0ZS5ub3coKSAtIHNp
bmNlKSkgOiAwOwogICAgICAgICAgICBpZiAod2FpdCA+IDApCiAgICAgICAgICAgICAgICBzZXRUaW1l
b3V0KGZpbmlzaFVwZGF0ZSwgd2FpdCk7CiAgICAgICAgICAgIGVsc2UKICAgICAgICAgICAgICAgIGZp
bmlzaFVwZGF0ZSgpOwogICAgICAgIH0gZWxzZSB7CiAgICAgICAgICAgIGZpbmlzaFVwZGF0ZSgpOwog
ICAgICAgIH0KICAgIH07CiAgICB3aW5kb3cuX19zZXRQaW5uZWQgPSB2ID0+IHsKICAgICAgICBwaW5u
ZWRVSSA9ICEhdjsKICAgICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYnRuLXBpbicpLmNsYXNz
TGlzdC50b2dnbGUoJ29uJywgcGlubmVkVUkpOwogICAgfTsKICAgIHdpbmRvdy5fX2xvYWRNb3JlRG9u
ZSA9ICgpID0+IHsKICAgICAgICBsb2FkaW5nTW9yZSA9IGZhbHNlOwogICAgfTsKCiAgICBzY2hlZHVs
ZURlbGF5ZWRTa2VsKCk7CiAgICBpbml0U2VwVWkoKTsKICAgIHJlc2V0UGFzdGVTZXBEZWZhdWx0KCk7
CiAgICByZXF1ZXN0VmlldygpOwogICAgLy8gc2NoZWR1bGVEZWxheWVkU2tlbCBhbHJlYWR5IHJlbmRl
cigpJ2Qgd2hlbiBlbXB0eTsgc3RpbGwgcGFpbnQgb25jZSBmb3IgY2hyb21lCgogICAgPC9zY3JpcHQ+
CjwvYm9keT4KPC9odG1sPg==
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
        ; 立刻返回，避免 WebView 同步调用卡死界面
        SetTimer(DeleteItem.Bind(id), -1)
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
    budget := 3
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
        SetTimer(ProcessThumbPushQueue, madeJpeg ? -45 : -12)
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

; Bridge entry: leave WebView sync stack + debounce (click→抙ost.call re-entrancy = double paste)
RequestPaste(id) {
    global pasteLockUntil
    if A_TickCount < pasteLockUntil
        return
    pasteLockUntil := A_TickCount + 500
    pasteId := id
    SetTimer(() => PasteItem(pasteId), -10)
}

RequestPasteMany(ids, sep := " ") {
    global pasteLockUntil, pasteIds, pasteSep
    if A_TickCount < pasteLockUntil
        return
    pasteLockUntil := A_TickCount + 500
    pasteIds := ids
    pasteSep := NormalizePasteSep(sep)
    SetTimer(() => PasteMany(pasteIds, pasteSep), -10)
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
    global tabTotals
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
